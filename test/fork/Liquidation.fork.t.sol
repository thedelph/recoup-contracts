// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../../src/Config.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {LiquidationAuction} from "../../src/LiquidationAuction.sol";
import {NAVOracle} from "../../src/NAVOracle.sol";
import {TreasuryLiquiditySource} from "../../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";

/// @notice PRD §12's Phase 3 exit criterion and §6.3's acceptance criterion: the full
///         liquidation lifecycle, including the expiry to workout path, against live
///         Base state. Run with:
///           RUN_FORK_TESTS=true BASE_RPC_URL=<rpc> forge test --mc LiquidationFork -vv
///
///         The load-bearing thing this proves, which no mock can: **a real DexFi bond
///         moves from the custody adapter to an arbitrary auction winner with only the
///         adapter whitelisted.** That single fact is what makes the no-escrow design
///         work, and it is the difference between needing one address whitelisted by
///         DexFi and needing two.
contract LiquidationForkTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp, 2026-07-24 snapshot
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 50_000e6;
    /// @dev 100 bonds at $25.15 is $2,515 of collateral; 35% of that is the ceiling.
    uint256 internal constant MAX_BORROW = 880.25e6;

    IDexFiBond internal bond = IDexFiBond(Config.DEXFI_BOND_NFT);
    IDexFiFarm internal farm = IDexFiFarm(Config.DEXFI_FARM);
    IERC20 internal usdc = IERC20(Config.USDC_BASE);

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper"); // NAV keeper and liquidation caller
    address internal confirmer = makeAddr("confirmer");
    address internal harvester = makeAddr("harvester");
    address internal winner = makeAddr("winner");

    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    NAVOracle internal oracle;
    TreasuryLiquiditySource internal liquidity;

    bool internal run;

    function setUp() public {
        run = vm.envOr("RUN_FORK_TESTS", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));

        // makeAddr keys are public and some carry EIP-7702 delegations on Base, which
        // then fail ERC-1155 receiver checks. Strip them so these behave as plain EOAs.
        vm.etch(alice, "");
        vm.etch(admin, "");
        vm.etch(harvester, "");
        vm.etch(winner, "");

        oracle = new NAVOracle(admin);
        vault = new CollateralVault(bond, INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(bond, farm, usdc, address(vault), admin, harvester);
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        auction = new LiquidationAuction(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        liquidity.setCreditManager(address(credit));
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(NAV);
        vm.stopPrank();

        // §14 ask #5, impersonated: DexFi whitelists the custody adapter. This is the
        // ONLY whitelist entry granted anywhere in this file - the winner is not
        // whitelisted, and does not need to be.
        address[] memory accounts = new address[](1);
        accounts[0] = address(adapter);
        vm.prank(Config.DEXFI_TREASURY_EOA);
        bond.addWhitelist(accounts);

        // Real bond units for alice. The farm holds the staked supply and is
        // whitelisted, so a farm-originated transfer passes the gate.
        vm.prank(Config.DEXFI_FARM);
        bond.safeTransferFrom(Config.DEXFI_FARM, alice, Config.DEXFI_BOND_TOKEN_ID, BONDS, "");
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);

        deal(Config.USDC_BASE, address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);
    }

    /// @dev Drop the price far enough to put a max-LTV position past the liquidation
    ///      threshold. One post is capped at roughly a tenth per day, and LTV has to
    ///      travel from 3,500 bps to past 5,800, so this has to go through the second
    ///      key - the same path `test_largeNavMoveNeedsTheSecondKey` pins in the Phase-2
    ///      fork suite, used here in anger.
    function _crashNavTo(uint256 nav) internal {
        vm.prank(keeper);
        oracle.postNav(nav);
        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(confirmer);
        oracle.confirmNav(nav);
        assertEq(oracle.navPerBond(), nav, "the second key ratified the crash");
    }

    function _openPosition() internal {
        vm.startPrank(alice);
        vault.depositBonds(BONDS);
        credit.borrow(MAX_BORROW);
        vm.stopPrank();
    }

    /// @notice PRD §6.3, on live state: ETH drops, health goes under, anyone calls
    ///         `liquidate`, a keeper buys at 82% of NAV, the debt is repaid, the surplus
    ///         goes to the borrower and the bonds go to the winner.
    function test_fullAuctionLifecycleFillsAtEightyTwoPercentOfNav() public {
        vm.skip(!run);
        _openPosition();

        // $15.00 a bond: past the threshold at 5,868 bps, but still worth more than the
        // loan, so a mid-auction fill leaves a real surplus to split.
        _crashNavTo(15e8);

        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        assertGt(id, 0, "an auction is live");

        // Nothing has moved yet. The lot is still staked, still earning.
        assertEq(vault.bondCount(alice), BONDS, "no escrow");
        assertEq(bond.balanceOf(address(auction), Config.DEXFI_BOND_TOKEN_ID), 0);

        // Decay to exactly 82% of NAV, the figure the PRD names.
        uint256 elapsed = ((Config.AUCTION_START_PREMIUM_BPS - 8_200) * Config.AUCTION_DURATION)
            / (Config.AUCTION_START_PREMIUM_BPS - Config.AUCTION_FLOOR_BPS);
        vm.warp(block.timestamp + elapsed);
        assertEq(auction.currentPremiumBps(id), 8_200);

        uint256 price = auction.currentPrice(id);
        assertEq(price, 1_230e6, "100 bonds at $15.00, 82% of NAV");

        uint256 stakedBefore = adapter.stakedBalance();
        deal(Config.USDC_BASE, winner, price);
        vm.startPrank(winner);
        usdc.approve(address(auction), price);
        auction.bid(id);
        vm.stopPrank();

        // **The proof.** A real DexFi bond reached an address DexFi has never heard of,
        // through the one whitelist entry granted in `setUp`.
        assertEq(bond.balanceOf(winner, Config.DEXFI_BOND_TOKEN_ID), BONDS, "winner holds real bonds");
        assertEq(vault.bondCount(alice), 0);
        assertEq(adapter.stakedBalance(), stakedBefore - BONDS, "and they were unstaked from the real farm");

        // The debt is gone and nothing was socialised.
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebt(), 0);
        assertEq(credit.unsocialisedLoss(), 0);

        // Penalty split 50/50, surplus to the borrower, claimable rather than pushed.
        uint256 penalty = (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(auction.rewardOf(keeper), penalty / 2, "the trigger, not the bidder");
        assertEq(credit.insuranceFund(), penalty - penalty / 2);
        // Real streamed USDC arrived during the warps and paid part of the loan down,
        // so the borrower's surplus is at least the arithmetic figure, never less.
        assertGe(credit.claimableOf(alice), price - MAX_BORROW - penalty, "surplus to the borrower");

        // Every wei accounted for: the auction keeps only the unclaimed reward.
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());

        // The float is made whole through the existing permissionless path.
        credit.settlePrincipal();
        assertGe(usdc.balanceOf(address(liquidity)), FLOAT, "lender float repaid in full");

        vm.prank(keeper);
        auction.claimReward();
        assertEq(usdc.balanceOf(address(auction)), 0, "nothing left at rest");
    }

    /// @notice PRD §6.3's other half: the auction expires unfilled and falls back to the
    ///         workout queue, which must move no tokens at all.
    function test_expiryToWorkoutOnLiveState() public {
        vm.skip(!run);
        _openPosition();
        _crashNavTo(15e8);

        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);

        uint256 stakedBefore = adapter.stakedBalance();
        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);

        auction.expireToWorkout(id); // permissionless

        // The claim moved and the lot did not. This is what makes the expiry path
        // immune to anything DexFi does to the transfer whitelist.
        assertEq(vault.bondCount(alice), 0);
        assertEq(vault.bondCount(address(auction)), BONDS, "the protocol holds the claim");
        assertEq(adapter.stakedBalance(), stakedBefore, "still staked in the real farm");
        assertEq(bond.balanceOf(address(auction), Config.DEXFI_BOND_TOKEN_ID), 0, "nothing escrowed");
        assertEq(auction.openWorkoutCount(), 1);

        // The debt stands until recovery is actually known.
        assertGt(credit.debtOf(alice), 0);
        assertEq(credit.unsocialisedLoss(), 0, "nothing guessed at lenders' expense");

        // DexFi redeems at 90% of NAV and an operator relays the proceeds. That rate is
        // DexFi's quote, not a protocol parameter - nothing on chain uses it or can
        // enforce it, which is exactly why the workout is a manual process with a
        // forced-recognition deadline rather than a formula.
        uint256 recovery = (BONDS * 15e8 * 9_000) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        deal(Config.USDC_BASE, address(this), recovery);
        usdc.approve(address(auction), recovery);
        auction.workoutSettle(id, recovery);

        assertEq(credit.debtOf(alice), 0, "the redemption cleared it");
        assertEq(credit.unsocialisedLoss(), 0);

        auction.closeWorkout(id);
        assertEq(auction.openWorkoutCount(), 0);
    }

    /// @dev PRD §4.6, against the real oracle: staleness pauses borrowing and leaves
    ///      liquidation running on the last known price. Both halves in one test,
    ///      because a protocol that stops liquidating when its feed goes quiet has only
    ///      converted underwater positions into bad debt.
    function test_liquidationSurvivesAStaleFeedThatStopsBorrowing() public {
        vm.skip(!run);
        _openPosition();
        _crashNavTo(15e8);

        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(oracle.isStale());

        vm.prank(alice);
        vm.expectRevert(CreditManager.NavStale.selector);
        credit.borrow(1e6);

        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        assertGt(id, 0, "liquidation continues on the last known price");

        uint256 price = auction.currentPrice(id);
        deal(Config.USDC_BASE, winner, price);
        vm.startPrank(winner);
        usdc.approve(address(auction), price);
        auction.bid(id);
        vm.stopPrank();

        assertEq(bond.balanceOf(winner, Config.DEXFI_BOND_TOKEN_ID), BONDS);
        assertEq(credit.debtOf(alice), 0);
    }
}
