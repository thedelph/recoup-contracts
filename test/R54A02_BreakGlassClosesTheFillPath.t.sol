// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R54A02 - after the break-glass exit the fill path is a revert, and the ledger is orphaned
/// @notice Audit round 54, trace recorded rather than claimed. `CollateralVault._requireLiquidatable`
///         and `collateralValue` say liquidation "keeps working after a break-glass exit", and
///         `CreditManager.liquidate` deliberately skips `custodyIsSolvent()`. Both are true of
///         OPENING an auction. FILLING one is not: `_bid` reaches `seize`, `seize` reaches
///         `adapter.unstake(amount)`, and after `emergencyUnstake` the farm holds nothing for the
///         adapter, so every bid reverts inside the farm. `expireToWorkout` still resolves (it moves
///         no bonds), but the workout lot can then never be disposed through the same unstake, and
///         `setCustodyAdapter` is ALLOWED past the empty outgoing adapter into one that holds nothing
///         either - so `bondCount` outlives custody for every borrower, with no on-chain way back.
/// @dev Self-contained fixture. Every test here is green on `f16e6e6`: this file measures the shipped
///      behaviour and proposes no `src/` change.
contract R54A02_BreakGlassClosesTheFillPath is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal rescueWallet = makeAddr("rescueWallet");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            admin
        );
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        treasury = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
        usdc.mint(address(treasury), TREASURY_FLOAT);

        _seed(alice, BONDS);
        _seed(bob, BONDS);
    }

    function _seed(address who, uint256 bonds) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _maxBorrow(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return (bonds * nav * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    function _openAuction(address who) internal returns (uint256 id) {
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(who);
        credit.borrow(debt);
        oracle.setNav((debt * Config.USDC_TO_NAV_SCALE) / BONDS / 2);
        vm.prank(keeper);
        credit.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: no auction");
    }

    /// @notice CONTROL: with custody intact the same bid fills.
    function test_R54A02_control_theBidFillsWithCustodyIntact() public {
        uint256 id = _openAuction(alice);
        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id);
        usdc.mint(bidder, price);
        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        auction.bid(id);
        vm.stopPrank();
        assertEq(bond.balanceOf(bidder, Config.DEXFI_BOND_TOKEN_ID), BONDS, "lot delivered");
    }

    /// @notice MEASURED. After `emergencyUnstake` a bid on a live auction reverts inside the farm;
    ///         `expireToWorkout` still resolves; the workout lot cannot be disposed; the vault
    ///         accepts a custody repoint that leaves every `bondCount` unbacked.
    function test_R54A02_breakGlass_theFillPathRevertsAndTheLedgerIsOrphaned() public {
        uint256 id = _openAuction(alice);

        vm.prank(admin);
        adapter.emergencyUnstake(rescueWallet);
        assertEq(bond.balanceOf(rescueWallet, Config.DEXFI_BOND_TOKEN_ID), 2 * BONDS, "bonds left custody");
        assertEq(adapter.stakedBalance(), 0, "adapter holds nothing");
        assertFalse(vault.custodyIsSolvent(), "ledger outlives custody");
        assertEq(vault.totalBondCount(), 2 * BONDS, "ledger unchanged");

        // (a) liquidation OPENING works - alice is still liquidatable on paper.
        assertGt(credit.currentLtvBps(alice), riskParams.liquidationThresholdBps(), "still liquidatable");

        // (b) FILLING does not: the seize reaches the farm for bonds that are not there.
        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id);
        usdc.mint(bidder, price);
        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, BONDS, 0));
        auction.bid(id);
        vm.stopPrank();

        // (c) The exit of last resort still resolves, because it moves no bonds.
        skip(1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(alice), 1, "workout opened");

        // (d) ...but the lot can never leave through `disposeTo`.
        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(id);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, BONDS, 0));
        auction.disposeWorkoutLot(id, rescueWallet);

        // (e) Bob's ordinary withdrawal is also a farm revert. FLIPPED in round 55 (A2, item 218):
        //     the vault used to let governance move custody to a fresh adapter that holds nothing;
        //     it now refuses by name, and admits only an adapter already staked to cover the ledger.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, BONDS, 0));
        vault.withdrawBonds(BONDS);

        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("CustodyWouldBeInsolvent(uint256,uint256)")), uint256(0), 2 * BONDS));
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));
        assertEq(address(vault.custodyAdapter()), address(adapter), "the repoint over an unbacked ledger is refused");
        assertFalse(vault.custodyIsSolvent(), "and custody is still not solvent: a break-glass exit is a redeploy");
    }

    // ── incidental: the `AuctionFilled.surplusToBorrower` field is gross of the penalty ────

    /// @notice MEASURED. `ILiquidationAuction.AuctionFilled` names its last field `surplusToBorrower`
    ///         and `_settleFill` emits `delivered - repaid`, which is the surplus BEFORE the
    ///         liquidation penalty is taken out of it. What the borrower is actually credited is
    ///         that figure less `min(surplus, 5% of debt)`. The community bot renders this field as
    ///         the surplus USD figure (its planner's `surplusUsd` field), so the message
    ///         overstates what the borrower received by exactly the penalty.
    function test_R54A02_incidental_AuctionFilledSurplusFieldIsGrossOfThePenalty() public {
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(alice);
        credit.borrow(debt);
        // Crash only far enough to cross the 50% line, so a fill at the start price has a surplus.
        uint256 nav = (debt * Config.USDC_TO_NAV_SCALE * Config.BPS) / (BONDS * 5_500);
        oracle.setNav(nav);
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);

        uint256 price = auction.currentPrice(id);
        uint256 penaltyDue = (credit.currentDebtOf(alice) * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        usdc.mint(bidder, price);
        uint256 claimableBefore = credit.claimableOf(alice);
        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        vm.recordLogs();
        auction.bid(id);
        vm.stopPrank();

        uint256 eventSurplus;
        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("AuctionFilled(uint256,address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(auction) && logs[i].topics[0] == sig) {
                (,, eventSurplus) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                seen = true;
            }
        }
        assertTrue(seen, "fixture: no AuctionFilled");
        uint256 credited = credit.claimableOf(alice) - claimableBefore;
        emit log_named_uint("MEASURED AuctionFilled.surplusToBorrower", eventSurplus);
        emit log_named_uint("MEASURED claimableOf[borrower] delta", credited);
        emit log_named_uint("MEASURED penalty taken", penaltyDue);
        assertGt(eventSurplus, credited, "the field overstates what the borrower received");
        assertEq(eventSurplus - credited, penaltyDue, "by exactly the liquidation penalty");
    }
}
