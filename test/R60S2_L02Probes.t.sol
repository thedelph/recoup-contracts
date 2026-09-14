// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

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

/// @title R60S2 - L-02 (33audits #54) closed by the reviewers' shape, probed
/// @notice Session 2026-09-14, stream S2. Self-contained, the `R53A01_VariantSplit` stack: a
///         `TreasuryLiquiditySource`, three 100-bond actors, the real vault, manager and auction.
///
///         The fix under probe: on a path that does not move the bond count, `_settle` advances
///         `yieldIndexOf` by `owed * ACC_PRECISION / bonds` instead of stamping it at the
///         accumulator, so the floored remainder stays in the index gap and is paid once it reaches
///         a base unit. `settleForVault` still stamps, because the count is about to change.
///
/// @dev What the nine probes here establish, each MEASURED at `f38a57c` on forge 1.8.1:
///
///      1. the retained gap is bounded: `bonds x (acc - idx) < ACC_PRECISION + bonds` after every
///         settle at 1, 7, 100 and 1,000,000 bonds, and the position is never short-changed and
///         never over-credited by more than the accumulator's own slack (0 or 1 wei);
///      2. conservation: the grind destroys nothing, a top-up's stamp destroys under one base
///         unit, and `claimable + debt reductions + undistributed` never exceeds the pot;
///      3. every count-changing path (`depositBonds`, `withdrawBonds`, `reassign`, `disposeTo`,
///         `seize`) DESTROYS the gap it finds and never re-prices it at the new count;
///      4. no path touches a count without `settleForVault(..., true)` in front of it, and the
///         four non-moving doors (`borrow`, `claimSurplus`, `liquidate`, `writeDownLoss`) retain the
///         gap and leave the count alone; a manager migration freezes the gap on the detached
///         manager as a phantom `pendingYieldOf` priced at the live count, which no call can realise
///         and which nothing in `contracts/src` reads through `currentDebtOf` (the auction and the
///         vault both read their own live pointer, and both pointers are pinned together while any
///         auction or workout stands);
///      5. the reviewers' `bonds == 0` arm is redundant: a zero-bond position owes nothing on the
///         non-moving path, and the vault stamps it at count 0 before its first deposit lands;
///      6. the shipped variant decides by the call site, not the sender: a vault-sent `settle` retains
///         the remainder like any other, and only `settleForVault` stamps;
///      7. the dust deadlock (round-55 246(b), round-57 item 177) is no longer reachable by the
///         grind: two lots ground hourly for a whole stream, both closed clean, both paid in full,
///         `earned` never above the pot;
///      8. and it IS still reachable through count changes alone: N liquidations reassigned into
///         the auction's pooled position mid-stream each stamp that position and destroy under one
///         base unit, so `sum(earned) - pot` is positive and at most N. That is the residual the fix
///         leaves, and the number beside it.
contract R60S2_L02Probes is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant DILUTION_BONDS = 37;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;
    uint256 internal constant ACC = 1e18;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal rescuer = makeAddr("rescuer");
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

    // ── fixture helpers (the R53A01_VariantSplit set) ────────────────────────

    function _seed(address who, uint256 bonds) internal {
        bond.mint(who, bonds < 1_000 ? 1_000 : bonds);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _maxBorrow(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return (bonds * nav * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    function _navAtDebtParity(uint256 debt, uint256 bonds) internal pure returns (uint256) {
        return (debt * Config.USDC_TO_NAV_SCALE) / bonds;
    }

    /// @dev Borrow at the ceiling, drop the NAV, liquidate; the auction is LIVE on return.
    function _liquidateOn(CreditManager cm, address who) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(who);
        cm.borrow(debt);
        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);
        vm.prank(keeper);
        cm.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: no auction opened");
    }

    function _openWorkoutOn(CreditManager cm, address who) internal returns (uint256 id) {
        id = _liquidateOn(cm, who);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
    }

    function _startStreamOn(CreditManager cm, uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(cm), amount);
        cm.receiveYield(amount);
        cm.distributeYield(amount);
        vm.stopPrank();
    }

    function _streamEpochOn(CreditManager cm, uint256 amount) internal {
        _startStreamOn(cm, amount);
        skip(Config.YIELD_STREAM_DURATION + 1);
        cm.accrueYield();
    }

    function _rescueDebtOn(CreditManager cm, address who) internal {
        uint256 owed = cm.currentDebtOf(who);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(cm), owed);
        cm.repayFor(who, owed);
        vm.stopPrank();
    }

    function _migrate() internal returns (CreditManager fresh) {
        fresh = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        TreasuryLiquiditySource freshTreasury = new TreasuryLiquiditySource(usdc, admin);
        usdc.mint(address(freshTreasury), TREASURY_FLOAT);
        vm.startPrank(admin);
        vault.setCreditManager(address(fresh));
        freshTreasury.setCreditManager(address(fresh));
        fresh.setLiquiditySource(address(freshTreasury));
        fresh.setEpochHarvester(harvester);
        fresh.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(fresh));
        vm.stopPrank();
    }

    function _era(CreditManager cm, address who, uint256 amount) internal returns (uint256 id, uint256 booked) {
        id = _openWorkoutOn(cm, who);
        _streamEpochOn(cm, amount);
        _rescueDebtOn(cm, who);
        auction.closeWorkout(id);
        booked = _yieldOwed(id);
        assertGt(booked, 0, "fixture: nothing booked");
        vm.prank(admin);
        auction.disposeWorkoutLot(id, who);
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _yieldIndexAtOpen(uint256 id) internal view returns (uint256 idx) {
        (,,,,,,,,, idx,) = auction.workouts(id);
    }

    function _pot(CreditManager cm) internal view returns (uint256) {
        return cm.claimableOf(address(auction)) + cm.pendingYieldOf(address(auction));
    }

    /// @dev The retained gap in ATTO-wei: `bonds x (acc - idx)` against `ACC_PRECISION`. Read
    ///      straight after a settle, so the stored accumulator IS the projected one.
    function _gapAtto(CreditManager cm, address who) internal view returns (uint256) {
        return vault.bondCount(who) * (cm.accYieldPerBond() - cm.yieldIndexOf(who));
    }

    function _isStamped(CreditManager cm, address who) internal view returns (bool) {
        return cm.yieldIndexOf(who) == cm.accYieldPerBond();
    }

    /// @dev Grind `who` with per-second settles until a sub-unit remainder is left in the gap, and
    ///      return it. The stream is chosen so a small position's per-second slice floors to zero.
    function _grindToAGap(CreditManager cm, address who, uint256 seconds_) internal returns (uint256 gap) {
        for (uint256 i = 0; i < seconds_; i++) {
            skip(1);
            vm.prank(stranger);
            cm.settle(who);
        }
        gap = _gapAtto(cm, who);
        assertGt(gap, 0, "fixture: the grind left no remainder in the gap");
        assertLt(gap, ACC, "fixture: the gap is a whole base unit, which the settle would have paid");
    }

    // ── 1. the gap is bounded, at every count ───────────────────────────────

    function _gapBoundAt(uint256 bonds) internal {
        address v = makeAddr(string.concat("victim-", vm.toString(bonds)));
        _seed(v, bonds);
        _startStreamOn(credit, 1e6);
        credit.settle(v);
        uint256 idx0 = credit.yieldIndexOf(v);
        uint256 worst;
        for (uint256 i = 0; i < 240; i++) {
            skip(1);
            vm.prank(stranger);
            credit.settle(v);
            uint256 gap = _gapAtto(credit, v);
            assertLt(gap, ACC + bonds, "the retained gap reached a base unit plus the slack");
            if (gap > worst) worst = gap;
        }
        uint256 exactFloor = (bonds * (credit.accYieldPerBond() - idx0)) / ACC;
        uint256 credited = credit.claimableOf(v) + credit.pendingYieldOf(v);
        emit log_named_uint("bonds", bonds);
        emit log_named_uint("  worst retained gap, atto-wei (bound is 1e18 + bonds)", worst);
        emit log_named_uint("  exact entitlement floored", exactFloor);
        emit log_named_uint("  credited + pending", credited);
        assertGe(credited, exactFloor, "the position was short-changed by the grind");
        assertLe(credited, exactFloor + 1, "over-credited by more than the accumulator's slack");
        emit log_named_uint("  over-credit from accumulator slack, wei", credited - exactFloor);
    }

    function test_R60S2_probe1_theRetainedGapIsBoundedAtOneBond() public {
        _gapBoundAt(1);
    }

    function test_R60S2_probe1_theRetainedGapIsBoundedAtSevenBonds() public {
        _gapBoundAt(7);
    }

    function test_R60S2_probe1_theRetainedGapIsBoundedAtAHundredBonds() public {
        _gapBoundAt(100);
    }

    function test_R60S2_probe1_theRetainedGapIsBoundedAtAMillionBonds() public {
        _gapBoundAt(1_000_000);
    }

    // ── 2. conservation ─────────────────────────────────────────────────────

    /// @notice The L-02 pin's fixture with a debtor beside it, and the accounting closed to the
    ///         atto-wei: what was streamed equals what was credited, written off debt, left
    ///         undistributed, retained in the three index gaps, destroyed by the top-up's one stamp,
    ///         and lost to the accumulator's own per-accrual floor (under `totalBondCount` atto each).
    function test_R60S2_probe2_theGrindDestroysNothingAndTheTopUpDestroysUnderOneUnit() public {
        oracle.setNav(NAV);
        // Sized before the prank: `_maxBorrow` reads the risk authority, and a single-shot prank is
        // spent on that read if it comes first (the ordering trap `CreditHandler.borrow` records).
        uint256 half = _maxBorrow(BONDS, NAV) / 2;
        vm.prank(alice);
        credit.borrow(half);
        address victim = makeAddr("victim");
        _seed(victim, 1);

        uint256 pot = 1e6;
        _startStreamOn(credit, pot);
        credit.settle(victim);
        credit.settle(alice);
        credit.settle(bob);
        uint256 accruals;
        for (uint256 i = 0; i < 60; i++) {
            skip(1);
            vm.prank(stranger);
            credit.settle(victim);
            accruals++;
        }
        uint256 gapAtTopUp = _gapAtto(credit, victim);
        emit log_named_uint("MEASURED credited to the victim by the grind", credit.claimableOf(victim));
        emit log_named_uint("MEASURED retained in the victim's gap at the top-up, atto-wei", gapAtTopUp);
        assertGt(gapAtTopUp, 0, "fixture: the grind left nothing to destroy");

        vm.prank(victim);
        vault.depositBonds(999);
        accruals++;
        assertTrue(_isStamped(credit, victim), "the top-up did not stamp");

        vm.warp(credit.streamEndsAt() + 1);
        credit.settle(victim);
        credit.settle(alice);
        credit.settle(bob);
        accruals++;

        uint256 credited = credit.totalClaimable();
        uint256 reductions = credit.pendingPrincipal();
        uint256 undistributed = credit.undistributedYield();
        uint256 gaps = _gapAtto(credit, victim) + _gapAtto(credit, alice) + _gapAtto(credit, bob);
        emit log_named_uint("MEASURED pot streamed", pot);
        emit log_named_uint("MEASURED credited (claimable)", credited);
        emit log_named_uint("MEASURED debt written off by yield", reductions);
        emit log_named_uint("MEASURED still undistributed", undistributed);
        emit log_named_uint("MEASURED retained in the three gaps, atto-wei", gaps);
        assertLe(credited + reductions + undistributed, pot, "credited more than was streamed");
        uint256 unaccountedAtto = (pot - credited - reductions - undistributed) * ACC - gaps;
        emit log_named_uint("MEASURED unaccounted after the gaps, atto-wei", unaccountedAtto);
        emit log_named_uint("MEASURED destroyed by the top-up stamp, atto-wei", gapAtTopUp);
        assertGe(unaccountedAtto, gapAtTopUp, "the accounting closed below the stamp's destruction");
        assertLt(
            unaccountedAtto - gapAtTopUp,
            (accruals + 1) * vault.totalBondCount(),
            "more was lost than the accumulator's per-accrual floor explains: something else destroys"
        );
        assertLe(pot - credited - reductions - undistributed, 2, "more than a wei of remainder is outside the ledger");
    }

    // ── 3. every count-changing path destroys the gap, none re-prices it ─────

    function _assertDestroyedNotRepriced(address who, uint256 gapBefore, uint256 claimableBefore) internal {
        assertTrue(_isStamped(credit, who), "the count change did not stamp");
        assertEq(credit.pendingYieldOf(who), 0, "a remainder survived the count change");
        assertEq(credit.claimableOf(who), claimableBefore, "the stamp paid a remainder that was under a base unit");
        // And nothing re-prices it later: one second on, the credit is exactly the new count's
        // slice of the new accrual, with the destroyed remainder nowhere in it.
        uint256 accAtStamp = credit.accYieldPerBond();
        uint256 countNow = vault.bondCount(who);
        skip(1);
        credit.settle(who);
        uint256 newSlice = (countNow * (credit.accYieldPerBond() - accAtStamp)) / ACC;
        assertEq(
            credit.claimableOf(who) - claimableBefore,
            newSlice,
            "the settle after the count change paid more than the new count's own accrual: the gap was re-priced"
        );
        emit log_named_uint("  gap destroyed, atto-wei", gapBefore);
        emit log_named_uint("  next settle paid, wei", newSlice);
    }

    function test_R60S2_probe3_depositBondsDestroysTheGap() public {
        address v = makeAddr("victim");
        _seed(v, 1);
        _startStreamOn(credit, 1e6);
        credit.settle(v);
        uint256 gap = _grindToAGap(credit, v, 60);
        uint256 claimable = credit.claimableOf(v);
        vm.prank(v);
        vault.depositBonds(999);
        emit log_string("depositBonds");
        _assertDestroyedNotRepriced(v, gap, claimable);
    }

    function test_R60S2_probe3_withdrawBondsDestroysTheGap() public {
        address v = makeAddr("victim");
        _seed(v, 2);
        _startStreamOn(credit, 1e6);
        credit.settle(v);
        uint256 gap = _grindToAGap(credit, v, 60);
        uint256 claimable = credit.claimableOf(v);
        vm.prank(v);
        vault.withdrawBonds(1);
        emit log_string("withdrawBonds");
        _assertDestroyedNotRepriced(v, gap, claimable);
    }

    /// @dev The auction's pooled position: bob's lot is in workout, carol's liquidation expires into
    ///      the same position, and `reassign`'s `_settlePosition(to)` stamps it.
    function test_R60S2_probe3_reassignIntoThePooledPositionDestroysTheGap() public {
        _seed(carol, BONDS);
        // A 37-bond diluter, so the pooled lot's share of the accumulator is not an exact third:
        // without it 100 of 300 bonds divides every slice evenly and there is no remainder to find.
        _seed(makeAddr("diluter"), DILUTION_BONDS);
        _openWorkoutOn(credit, bob);
        _startStreamOn(credit, EPOCH);
        uint256 carolId = _liquidateOn(credit, carol);
        skip(Config.AUCTION_DURATION + 1);
        vm.prank(stranger);
        credit.settle(address(auction));
        uint256 gap = _gapAtto(credit, address(auction));
        assertGt(gap, 0, "fixture: no remainder on the pooled position");
        uint256 claimable = credit.claimableOf(address(auction));
        auction.expireToWorkout(carolId);
        assertEq(vault.bondCount(address(auction)), 2 * BONDS, "fixture: carol's lot did not pool");
        emit log_string("reassign (expireToWorkout)");
        _assertDestroyedNotRepriced(address(auction), gap, claimable);
    }

    function test_R60S2_probe3_disposeToDestroysTheGap() public {
        _seed(carol, BONDS);
        uint256 bobId = _openWorkoutOn(credit, bob);
        _openWorkoutOn(credit, carol);
        _startStreamOn(credit, EPOCH);
        skip(1 days);
        _rescueDebtOn(credit, bob);
        auction.closeWorkout(bobId);
        skip(1 hours);
        vm.prank(stranger);
        credit.settle(address(auction));
        uint256 gap = _gapAtto(credit, address(auction));
        assertGt(gap, 0, "fixture: no remainder on the pooled position");
        uint256 claimable = credit.claimableOf(address(auction));
        vm.prank(admin);
        auction.disposeWorkoutLot(bobId, bob);
        assertEq(vault.bondCount(address(auction)), BONDS, "fixture: the lot did not leave");
        emit log_string("disposeTo (disposeWorkoutLot)");
        _assertDestroyedNotRepriced(address(auction), gap, claimable);
    }

    /// @dev `seize` settles the BORROWER's position before zeroing it, so the gap that dies is carol's.
    function test_R60S2_probe3_seizeDestroysTheGap() public {
        _seed(carol, BONDS);
        _startStreamOn(credit, EPOCH);
        uint256 id = _liquidateOn(credit, carol);
        skip(1 hours);
        vm.prank(stranger);
        credit.settle(carol);
        uint256 gap = _gapAtto(credit, carol);
        assertGt(gap, 0, "fixture: no remainder on carol's position");
        uint256 price = auction.currentPrice(id);
        address bidder = makeAddr("bidder");
        usdc.mint(bidder, price);
        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        auction.bid(id);
        vm.stopPrank();
        assertEq(vault.bondCount(carol), 0, "fixture: the lot was not seized");
        assertTrue(_isStamped(credit, carol), "seize did not stamp");
        assertEq(credit.pendingYieldOf(carol), 0, "a remainder survived the seize");
        emit log_string("seize (bid fill)");
        emit log_named_uint("  gap destroyed, atto-wei", gap);
    }

    // ── 4. the doors that do not move a count retain the gap; migration freezes it ──

    function test_R60S2_probe4_borrowRetainsTheGapAndMovesNoCount() public {
        _startStreamOn(credit, 1e6);
        credit.settle(alice);
        uint256 gap = _grindToAGap(credit, alice, 30);
        oracle.setNav(NAV);
        uint256 half = _maxBorrow(BONDS, NAV) / 2;
        vm.prank(alice);
        credit.borrow(half);
        assertEq(vault.bondCount(alice), BONDS, "borrow moved a count");
        assertEq(_gapAtto(credit, alice), gap, "borrow destroyed or re-priced the gap");
    }

    function test_R60S2_probe4_claimSurplusRetainsTheGapAndMovesNoCount() public {
        _startStreamOn(credit, EPOCH);
        skip(1 hours);
        credit.settle(alice);
        assertGt(credit.claimableOf(alice), 0, "fixture: nothing to claim");
        uint256 gap = _gapAtto(credit, alice);
        assertGt(gap, 0, "fixture: no remainder");
        vm.prank(alice);
        credit.claimSurplus();
        assertEq(vault.bondCount(alice), BONDS, "claimSurplus moved a count");
        assertEq(_gapAtto(credit, alice), gap, "claimSurplus destroyed or re-priced the gap");
        vm.prank(stranger);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        credit.claimSurplusFor(alice);
        assertEq(_gapAtto(credit, alice), gap, "claimSurplusFor's settle destroyed the gap before it reverted");
    }

    function test_R60S2_probe4_liquidateRetainsTheGapAndMovesNoCount() public {
        _seed(carol, BONDS);
        _startStreamOn(credit, EPOCH);
        oracle.setNav(NAV);
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(carol);
        credit.borrow(debt);
        skip(1 hours);
        credit.settle(carol);
        uint256 gap = _gapAtto(credit, carol);
        assertGt(gap, 0, "fixture: no remainder");
        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);
        vm.prank(keeper);
        credit.liquidate(carol);
        assertGt(auction.auctionOf(carol), 0, "fixture: not liquidated");
        assertEq(vault.bondCount(carol), BONDS, "liquidate moved a count");
        assertEq(_gapAtto(credit, carol), gap, "liquidate destroyed or re-priced the gap");
    }

    function test_R60S2_probe4_writeDownLossRetainsTheGapAndMovesNoCount() public {
        _seed(carol, BONDS);
        _startStreamOn(credit, EPOCH);
        uint256 id = _liquidateOn(credit, carol);
        skip(1 hours);
        credit.settle(carol);
        uint256 gap = _gapAtto(credit, carol);
        assertGt(gap, 0, "fixture: no remainder");
        vm.prank(address(auction));
        credit.writeDownLoss(carol, id, 1e6);
        assertEq(vault.bondCount(carol), BONDS, "writeDownLoss moved a count");
        assertEq(_gapAtto(credit, carol), gap, "writeDownLoss destroyed or re-priced the gap");
    }

    /// @notice A gap left on the outgoing manager becomes a phantom `pendingYieldOf` priced at the
    ///         LIVE vault count, the same shape any unsettled accrual already had before the fix
    ///         (round-54's reading of `_settle`'s detached bail-out). Nothing can realise it: the
    ///         detached `_settle` returns on its first line, `settle` reverts `Detached`, and
    ///         `claimSurplusFor` finds nothing new. Measured so the size is a number.
    function test_R60S2_probe4_migrationFreezesTheGapAsAnUnrealisablePhantom() public {
        _startStreamOn(credit, 1e6);
        credit.settle(alice);
        uint256 gap = _grindToAGap(credit, alice, 30);
        if (credit.claimableOf(alice) != 0) {
            vm.prank(alice);
            credit.claimSurplus();
        }
        uint256 claimableBefore = credit.claimableOf(alice);
        assertEq(_gapAtto(credit, alice), gap, "fixture: the claim moved the gap");
        CreditManager two = _migrate();
        assertEq(credit.pendingYieldOf(alice), 0, "under a base unit at the old count");

        // The live count moves (on manager two, which stamps a virgin index); the detached manager
        // prices its frozen gap at the new count.
        vm.prank(alice);
        vault.depositBonds(900);
        uint256 phantom = credit.pendingYieldOf(alice);
        emit log_named_uint("MEASURED gap frozen on the detached manager, atto-wei", gap);
        emit log_named_uint("MEASURED phantom pendingYieldOf at the live count (1,000 bonds)", phantom);
        assertEq(phantom, (1_000 * gap / BONDS) / ACC, "the phantom is the gap re-priced at the live count");
        assertLt(phantom, 1_000 / BONDS + 1, "a phantom above one wei per unit of count ratio");

        vm.expectRevert();
        credit.settle(alice);
        vm.prank(stranger);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        credit.claimSurplusFor(alice);
        assertEq(credit.claimableOf(alice), claimableBefore, "the phantom was realised");
        assertEq(two.pendingYieldOf(alice), 0, "the incoming manager saw the old gap");
        assertTrue(_isStamped(two, alice), "the incoming manager did not stamp alice at her first count change");
    }

    // ── 5. the `bonds == 0` arm is redundant ─────────────────────────────────

    function test_R60S2_probe5_aZeroBondPositionNeedsNoStampOnTheNonMovingPath() public {
        _startStreamOn(credit, EPOCH);
        skip(1 days);
        address virgin = makeAddr("virgin");
        // Never seen: settles without reverting and without writing.
        credit.settle(virgin);
        assertEq(credit.yieldIndexOf(virgin), 0, "a non-moving settle wrote a zero-bond index");
        assertGt(credit.accYieldPerBond(), 0, "fixture: the accumulator has not moved");
        // The vault stamps it at count 0 before the first deposit lands, so no history is claimable.
        _seed(virgin, BONDS);
        assertTrue(_isStamped(credit, virgin), "the first deposit did not stamp at count 0");
        assertEq(credit.pendingYieldOf(virgin), 0, "a first deposit claimed the historical accumulator");
        uint256 accAtDeposit = credit.accYieldPerBond();
        vm.warp(credit.streamEndsAt() + 1);
        credit.settle(virgin);
        assertEq(
            credit.claimableOf(virgin),
            (BONDS * (credit.accYieldPerBond() - accAtDeposit)) / ACC,
            "the newcomer was paid for a period before their deposit"
        );
        // Emptied: the withdraw stamps, and a later non-moving settle at zero bonds is a no-op.
        vm.prank(virgin);
        vault.withdrawBonds(BONDS);
        uint256 idx = credit.yieldIndexOf(virgin);
        credit.settle(virgin);
        assertEq(credit.yieldIndexOf(virgin), idx, "a zero-bond settle wrote the index");
    }

    // ── 6. the call site decides, not the sender ─────────────────────────────

    /// @notice Only `settleForVault` is reachable with the vault as sender (`CollateralVault` makes
    ///         exactly one non-view call into the manager, `_settlePosition`'s), and the shipped
    ///         variant keys on the call site rather than on `msg.sender`: a vault-sent `settle`
    ///         retains the remainder like any other caller's, and `settleForVault` stamps whoever
    ///         the bonds belong to. The `msg.sender == vault` derivation (variant (e), +28 bytes
    ///         dearer) would have stamped on the first call below.
    function test_R60S2_probe6_theCallSiteDecidesNotTheSender() public {
        _startStreamOn(credit, 1e6);
        credit.settle(alice);
        uint256 gap = _grindToAGap(credit, alice, 30);
        vm.prank(address(vault));
        credit.settle(alice);
        assertEq(_gapAtto(credit, alice), gap, "a vault-sent settle stamped: the sender decided");
        vm.prank(stranger);
        vm.expectRevert(CreditManager.NotVault.selector);
        credit.settleForVault(alice, BONDS);
        vm.prank(address(vault));
        credit.settleForVault(alice, BONDS);
        assertTrue(_isStamped(credit, alice), "settleForVault did not stamp");
    }

    // ── 7. the dust deadlock is no longer reachable by the grind ─────────────

    /// @notice Two lots in one pooled position, ground hourly through the whole stream through BOTH
    ///         permissionless doors, closed clean, claimed: `earned` never exceeds the pot, both are
    ///         paid in full, nothing stands. This is `R52A02`'s incidental and `R55A02`'s 246(b)
    ///         reacher with the fix under them.
    function test_R60S2_probe7_twoLotsGroundAllStreamCloseAndPayInFull() public {
        _seed(carol, DILUTION_BONDS);
        uint256 aliceId = _openWorkoutOn(credit, alice);
        uint256 bobId = _openWorkoutOn(credit, bob);
        _startStreamOn(credit, EPOCH);
        uint256 held0 = usdc.balanceOf(address(auction));
        uint256 settles;
        for (uint256 t = 1 hours; t <= Config.YIELD_STREAM_DURATION; t += 1 hours) {
            skip(1 hours);
            vm.prank(stranger);
            if (settles % 2 == 0) {
                credit.settle(address(auction));
            } else {
                try credit.claimSurplusFor(address(auction)) {} catch {}
            }
            settles++;
        }
        skip(1);
        credit.accrueYield();
        uint256 earnedA = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(aliceId));
        uint256 earnedB = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        uint256 pot = _pot(credit) + (usdc.balanceOf(address(auction)) - held0);
        emit log_named_uint("MEASURED settles ground on the pooled position", settles);
        emit log_named_uint("MEASURED earned, alice's lot (one floor)", earnedA);
        emit log_named_uint("MEASURED earned, bob's lot (one floor)", earnedB);
        emit log_named_uint("MEASURED the position's reach (pot + pulled)", pot);
        assertLe(earnedA + earnedB, pot, "the grind opened a gap: earned exceeds the pot");
        emit log_named_uint("MEASURED pot - earned (the floors' slack)", pot - earnedA - earnedB);
        assertLe(pot - earnedA - earnedB, 2, "the pot exceeds the two one-floor figures by more than two floors");

        _rescueDebtOn(credit, alice);
        auction.closeWorkout(aliceId);
        _rescueDebtOn(credit, bob);
        auction.closeWorkout(bobId);
        assertEq(_yieldOwed(aliceId), earnedA, "alice was clamped");
        assertEq(_yieldOwed(bobId), earnedB, "bob was clamped");
        uint256 a0 = usdc.balanceOf(alice);
        uint256 b0 = usdc.balanceOf(bob);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        vm.prank(stranger);
        auction.claimWorkoutYield(bobId);
        assertEq(usdc.balanceOf(alice) - a0, earnedA, "alice was paid short");
        assertEq(usdc.balanceOf(bob) - b0, earnedB, "bob was paid short");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a dust booking stands");
    }

    // ── 8. and it is still reachable through count changes alone ─────────────

    uint256 internal constant EXTRA_LOTS = 8;

    /// @notice The residual the fix leaves, reached deterministically and bounded. Alice's booking
    ///         is pushed onto the auction from the detached manager (the round-55 shape); bob's lot
    ///         is in workout on the live manager with a stream running; NO grind - instead eight
    ///         more borrowers are liquidated and expire into the auction's pooled position an hour
    ///         apart, and every `reassign` stamps that position. Each stamp destroys under one base
    ///         unit, so the lots' one-floor `earned` figures sum to more than the position can reach,
    ///         by at most one wei per count change. Every workout closes clean, every booking is made
    ///         in full against alice's pushed backing, and the last claims come up short: the dust
    ///         deadlock, with count changes as the only door left.
    function test_R60S2_probe8_theDeadlockIsReachedThroughCountChangesAloneAndBoundedByTheirNumber() public {
        (uint256 aliceId, uint256 a) = _era(credit, alice, EPOCH);
        CreditManager two = _migrate();
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(usdc.balanceOf(address(auction)), a, "fixture: alice's backing was not pushed");

        address[EXTRA_LOTS] memory extra;
        uint256[EXTRA_LOTS] memory ids;
        for (uint256 k = 0; k < EXTRA_LOTS; k++) {
            extra[k] = makeAddr(string.concat("lot-", vm.toString(k)));
            _seed(extra[k], BONDS);
        }
        uint256 bobId = _openWorkoutOn(two, bob);
        _startStreamOn(two, EPOCH);
        // Each extra lot pools for an hour and leaves again: two count changes (the `reassign` in,
        // the `disposeTo` out), one booking. No `settle(auction)` is ever called by hand.
        uint256 countChanges;
        uint256 earned;
        for (uint256 k = 0; k < EXTRA_LOTS; k++) {
            skip(1 hours);
            uint256 before = vault.bondCount(address(auction));
            ids[k] = _openWorkoutOn(two, extra[k]);
            assertEq(vault.bondCount(address(auction)), before + BONDS, "fixture: the lot did not pool");
            countChanges++;
            skip(1 hours);
            _rescueDebtOn(two, extra[k]);
            auction.closeWorkout(ids[k]);
            uint256 lotEarned = two.yieldAccruedOn(BONDS, _yieldIndexAtOpen(ids[k]));
            assertEq(_yieldOwed(ids[k]), lotEarned, "a mid-stream close was clamped");
            earned += lotEarned;
            vm.prank(admin);
            auction.disposeWorkoutLot(ids[k], extra[k]);
            assertEq(vault.bondCount(address(auction)), before, "fixture: the lot did not leave");
            countChanges++;
        }
        skip(1);
        two.accrueYield();
        earned += two.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));

        uint256 pot = _pot(two);
        uint256 gap = earned > pot ? earned - pot : 0;
        emit log_named_uint("MEASURED count changes of the pooled position mid-stream", countChanges);
        emit log_named_uint("MEASURED sum of the lots' one-floor earned figures", earned);
        emit log_named_uint("MEASURED manager two's pot for the position", pot);
        emit log_named_uint("MEASURED earned - pot (the count-change residual, wei)", gap);
        assertGt(gap, 0, "fixture: the count changes destroyed under one base unit in total");
        assertLe(gap, countChanges, "more than one wei destroyed per count change");

        _rescueDebtOn(two, bob);
        auction.closeWorkout(bobId);
        uint256 booked = _yieldOwed(bobId);
        for (uint256 k = 0; k < EXTRA_LOTS; k++) {
            booked += _yieldOwed(ids[k]);
        }
        assertEq(booked, earned, "a close was clamped: alice's pushed backing did not cover the residual");

        vm.prank(stranger);
        try auction.claimWorkoutYield(aliceId) {} catch {}
        vm.prank(stranger);
        try auction.claimWorkoutYield(bobId) {} catch {}
        for (uint256 k = 0; k < EXTRA_LOTS; k++) {
            vm.prank(stranger);
            try auction.claimWorkoutYield(ids[k]) {} catch {}
        }
        uint256 dust = auction.totalWorkoutYieldOwed();
        emit log_named_uint("MEASURED dust bookings left standing after every claim", dust);
        assertGt(dust, 0, "no deadlock: every claim paid in full");
        assertLe(dust, (EXTRA_LOTS + 2) * gap, "the standing dust exceeds one residual per claimant");
        vm.prank(stranger);
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepFreeBalanceToInsurance();
    }
}
