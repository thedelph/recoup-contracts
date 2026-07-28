// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../../src/Config.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {NAVOracle} from "../../src/NAVOracle.sol";
import {TreasuryLiquiditySource} from "../../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";

/// @notice PRD §12's Phase 2 exit criterion: borrow, repay and yield-application on a
///         mainnet fork. Run with:
///           RUN_FORK_TESTS=true BASE_RPC_URL=<rpc> forge test --mc CreditCoreFork -vv
///
///         Everything here is the real thing except the price and the lending float:
///         real DexFi bond and farm contracts, real streamed USDC, the real NAVOracle
///         with its deviation budget and second key. NAV is seeded from the 2026-07-24
///         snapshot because DexFi publishes no on-chain NAV - that gap is exactly what
///         the keeper exists to close, and why its figure must be independently
///         reconciled rather than read from DexFi.
contract CreditCoreForkTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 50_000e6;

    IDexFiBond internal bond = IDexFiBond(Config.DEXFI_BOND_NFT);
    IDexFiFarm internal farm = IDexFiFarm(Config.DEXFI_FARM);
    IERC20 internal usdc = IERC20(Config.USDC_BASE);

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");
    address internal harvester = makeAddr("harvester");

    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
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

        oracle = new NAVOracle(admin);
        vault = new CollateralVault(bond, INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(bond, farm, usdc, address(vault), admin, harvester);
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(makeAddr("auction"));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        liquidity.setCreditManager(address(credit));
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(NAV);
        vm.stopPrank();

        // §14 ask #5, impersonated: DexFi whitelists the custody adapter.
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

        // Fund the lending float with real USDC.
        deal(Config.USDC_BASE, address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);
    }

    /// @dev The Phase 2 exit criterion end to end, on live state.
    function test_depositBorrowHarvestApplyRepay() public {
        vm.skip(!run);

        // 1. Deposit real bonds; they stake into the live farm.
        vm.prank(alice);
        vault.depositBonds(BONDS);
        assertEq(adapter.stakedBalance(), BONDS, "staked in the live farm");
        assertTrue(vault.custodyIsSolvent());

        // 2. Borrow against them. 100 bonds x $25.15 x 35% = 880.25 USDC.
        uint256 maxBorrow = 880.25e6;
        vm.prank(alice);
        credit.borrow(maxBorrow);
        assertEq(usdc.balanceOf(alice), maxBorrow, "USDC received same block");
        assertEq(credit.currentLtvBps(alice), Config.MAX_LTV_BPS, "sits exactly at maxLTV");
        assertGt(credit.healthFactor(alice), Config.HEALTH_FACTOR_SCALE, "healthy at maxLTV");

        // 3. Let real rewards stream, then harvest them out of the live farm.
        vm.warp(block.timestamp + 7 days);
        assertGt(farm.pendingShare(address(adapter)), 0, "farm accrued real USDC");
        vm.prank(admin);
        uint256 harvested = vault.harvestYield();
        assertGt(harvested, 0, "a week of streamed rewards on 100 bonds");
        assertEq(usdc.balanceOf(harvester), harvested, "reported figure matches what moved");

        // 4. Apply that real yield against the debt, the way EpochHarvester will.
        //    The share is streamed over an epoch rather than credited at once - that
        //    is what makes depositing in the harvest block pointless - so the clock
        //    has to run before any of it has actually been earned.
        uint256 debtBefore = credit.debtOf(alice);
        vm.startPrank(harvester);
        usdc.approve(address(credit), harvested);
        credit.receiveYield(harvested);
        credit.distributeYield(harvested);
        vm.stopPrank();

        credit.settle(alice);
        assertEq(credit.debtOf(alice), debtBefore, "nothing is earned in the harvest block");

        // To the end of the stream, which is not a fixed five days: the pot is rated
        // over the window it accrued across, and this epoch represents the seven days
        // warped above. That is what stops a late depositor capturing a long window.
        vm.warp(credit.streamEndsAt());
        credit.settle(alice);
        // At most 1 wei of USDC is left behind by the stream rate's truncation.
        assertApproxEqAbs(credit.debtOf(alice), debtBefore - harvested, 1, "debt fell by the yield");
        assertLt(credit.currentLtvBps(alice), Config.MAX_LTV_BPS, "self-repaid, LTV improved");

        // 5. Repay the remainder and exit with the bonds.
        uint256 remaining = credit.debtOf(alice);
        deal(Config.USDC_BASE, alice, remaining);
        vm.startPrank(alice);
        usdc.approve(address(credit), remaining);
        credit.repay(remaining);
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebt(), 0);

        vault.withdrawBonds(BONDS);
        vm.stopPrank();
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), BONDS, "collateral returned");

        // 6. Principal finds its way home, and the float is whole again.
        credit.settlePrincipal();
        assertEq(credit.pendingPrincipal(), 0);
        assertGe(usdc.balanceOf(address(liquidity)), FLOAT, "lender float repaid in full");
    }

    /// @dev Borrowing must refuse while the price is unposted or stale, against the
    ///      real oracle rather than a mock with a settable flag.
    function test_borrowRefusedOnStaleNav() public {
        vm.skip(!run);
        vm.prank(alice);
        vault.depositBonds(BONDS);

        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(oracle.isStale());

        vm.prank(alice);
        vm.expectRevert(CreditManager.NavStale.selector);
        credit.borrow(1e6);
    }

    /// @dev The deviation budget and the second key, exercised against real state:
    ///      a large move waits, and the keeper cannot wave it through alone.
    function test_largeNavMoveNeedsTheSecondKey() public {
        vm.skip(!run);

        vm.warp(block.timestamp + 1 days);
        uint256 crashed = NAV / 2; // -50%, far beyond a day's budget

        vm.prank(keeper);
        oracle.postNav(crashed);
        assertEq(oracle.navPerBond(), NAV, "not accepted unilaterally");
        assertEq(oracle.pendingNav(), crashed, "parked for the second key");

        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(confirmer);
        oracle.confirmNav(crashed);
        assertEq(oracle.navPerBond(), crashed, "second key ratified it");
    }
}
