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

/// @title R52A02 - the round-51 reserve, one round on
/// @notice Audit round 52. Self-contained: this file deploys its own stack and inherits nothing
///         from the repository's fixtures.
///
/// @dev The subject is the three-term reserve that round 51 put in front of both insurance sweeps
///      (`totalUnclaimedRewards + totalWorkoutYieldOwed + _openWorkoutAccrual`), its two-term
///      mirror in `claimWorkoutYield`, and the one door those terms do not see: a booking whose
///      backing sits on a manager the auction no longer points at.
///
///      🟥 **One of the eight tests PINS AN OPEN FINDING and says so. It asserts the DEFECTIVE
///      behaviour, a fix must turn it red, and a green run of it is not a clearance.** A second
///      used to, and was FLIPPED by round 53:
///
///      1. `test_R52A02_fix_aBookingOnADetachedManagerNoLongerClampsTheNextCleanClose` (was
///         `finding_`, MEDIUM, round-52 item 165's "migration-detached shortfall" lead, executed;
///         round-53 item 178). A fix was BUILT in two variants in round 52, each SIGN-CHECKED (the
///         finding test went red at its first assertion, the other seven stayed green), each
///         MEASURED on a clean `out/` against `LiquidationAuction`'s 19,948 runtime at `99bb4cf`:
///         variant C splits `totalWorkoutYieldOwed` by backing manager (`workoutYieldOwedOn[cm]`)
///         and reserves the other bookings in `claimWorkoutYield`, **+206 runtime bytes**; variant A
///         adds to C a pull from the recorded `bearer` when it differs from the live manager,
///         **+295** (20,243 / 4,333). **Round 53 SHIPPED variant A**, by Chris's decision of
///         2026-09-05, gated on `LiquidationAuction.invariants.t.sol` running green under it. The
///         finding test therefore went red at "bob was booked in full, the clamp did not bite:
///         999999999 >= 999999999" and was rewritten to assert the fix; the regression suite
///         `R53S5_DetachedBearerAccounting.t.sol` carries the residual and the neuter.
///
///      2. `test_R52A02_pin_aCleanCloseByRepayForChargesNoneOfThePenalty` (round-52 item 162). The
///         behavioural alternative - charging `min(penaltyRemaining, earned)` out of the booking on
///         a clean close - was BUILT and MEASURED at **+101 runtime bytes** (20,049 / 4,527) and
///         moves 16 tests, 11 of them shipped (`R46WorkoutCloseSettles` x2,
///         `R51A02_OverRealisationDoor` x5 including `test_R51_155_theTwoRefusalsMustBeTellableApart`,
///         `R51A05_WorkoutYield` x4), so it is a behaviour change in its own right and NOT applied.
///         Round 52 shipped the DOCSTRING correction on `Workout.penaltyRemaining` only; this pin
///         holds the behaviour the docstring now describes.
///
///      The remaining six are controls, negatives and an incidental, each green on the shipped tree
///      because the shipped tree is what they describe. None of the six moved under variant A.
contract R52A02_WorkoutReserve is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant DILUTION_BONDS = 37;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal rescuer = makeAddr("rescuer");
    address internal donor = makeAddr("donor");
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

    // ── fixture helpers ──────────────────────────────────────────────────────

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

    function _navAtDebtParity(uint256 debt, uint256 bonds) internal pure returns (uint256) {
        return (debt * Config.USDC_TO_NAV_SCALE) / bonds;
    }

    /// @dev Borrow at the ceiling on `cm`, crash NAV, liquidate, lapse the window, expire.
    function _openWorkoutOn(CreditManager cm, address who) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(who);
        cm.borrow(debt);

        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);

        vm.prank(keeper);
        cm.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: no auction opened");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(who), 1, "fixture: no workout opened");
    }

    function _openWorkout(address who) internal returns (uint256 id) {
        return _openWorkoutOn(credit, who);
    }

    /// @dev One epoch of borrower-side yield on `cm`, fully streamed and accrued.
    function _streamEpochOn(CreditManager cm, uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(cm), amount);
        cm.receiveYield(amount);
        cm.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION + 1);
        cm.accrueYield();
    }

    function _streamEpoch(uint256 amount) internal {
        _streamEpochOn(credit, amount);
    }

    /// @dev Start a stream on `cm` without running it to the end; the caller advances the clock.
    function _startStreamOn(CreditManager cm, uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(cm), amount);
        cm.receiveYield(amount);
        cm.distributeYield(amount);
        vm.stopPrank();
    }

    /// @dev A third party clears the defaulted debt on `cm`, which makes the close CLEAN.
    function _rescueDebtOn(CreditManager cm, address who) internal {
        uint256 owed = cm.currentDebtOf(who);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(cm), owed);
        cm.repayFor(who, owed);
        vm.stopPrank();
        assertEq(cm.debtOf(who), 0, "fixture: debt not cleared");
    }

    function _rescueDebt(address who) internal {
        _rescueDebtOn(credit, who);
    }

    /// @dev The ordinary zero-debt migration: a replacement manager with its own treasury, every
    ///      pointer moved, the outgoing manager left detached with its `claimableOf` intact.
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
        assertEq(vault.creditManager(), address(fresh), "fixture: vault not repointed");
        assertEq(auction.creditManager(), address(fresh), "fixture: auction not repointed");
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _yieldIndexAtOpen(uint256 id) internal view returns (uint256 idx) {
        (,,,,,,,,, idx,) = auction.workouts(id);
    }

    function _bearer(uint256 id) internal view returns (address b) {
        (,,,,,,,, b,,) = auction.workouts(id);
    }

    function _penaltyRemaining(uint256 id) internal view returns (uint256 p) {
        (,,,,,, p,,,,) = auction.workouts(id);
    }

    function _donate(uint256 amount) internal {
        usdc.mint(donor, amount);
        vm.prank(donor);
        usdc.transfer(address(auction), amount);
    }

    // ── 1. FIX (was FINDING): a booking backed on a detached manager no longer clamps the next clean close ──

    /// @notice **FLIPPED BY ROUND 53 (round-53 item 178, variant A shipped). This test asserted the
    ///         defect until the fix landed and went red at its first assertion, "bob was booked in
    ///         full, the clamp did not bite: 999999999 >= 999999999"; it now asserts the fix.** The
    ///         defect it pinned: `closeWorkout`'s clean branch bounded the booking by
    ///         `reachable - spokenFor`, where `reachable` is this contract's balance plus what the
    ///         LIVE manager owes it, and `spokenFor` was `totalUnclaimedRewards + totalWorkoutYieldOwed`
    ///         over EVERY booking, whichever manager backed it. A booking made before a migration is
    ///         backed by `claimableOf(auction)` on the DETACHED manager - left behind by design,
    ///         reachable through the permissionless `claimSurplusFor(auction)` - and until somebody
    ///         ran that call it sat in `spokenFor` and not in `reachable`. So the first clean close
    ///         on the new manager was clamped by the old booking, and the borrower whose lot earned
    ///         the difference was booked less than it earned.
    ///
    ///         Then `claimWorkoutYield` finished the misallocation: the first borrower's claim asked
    ///         the LIVE manager (never the recorded `bearer`), realised the second borrower's whole
    ///         accrual, reserved only `totalUnclaimedRewards + _openWorkoutAccrual`, and paid the
    ///         first borrower out of it. The first borrower's own backing, still on the detached
    ///         manager, was later pushed here by `claimSurplusFor` with no booking left to reserve
    ///         it and went to insurance.
    ///
    ///         Under the fix: `spokenFor` reads `workoutYieldOwedOn[cm]`, so bob is booked in full;
    ///         alice's claim pulls her recorded `bearer` as well as the live manager and reserves
    ///         every other booking, so she is paid from her own backing and manager two's pot stays
    ///         whole for bob; nothing that was owed reaches insurance. Round-52 item 165 named this
    ///         lead as "the migration-detached shortfall"; this executed it, and now holds the fix.
    function test_R52A02_fix_aBookingOnADetachedManagerNoLongerClampsTheNextCleanClose() public {
        // Era one: alice's workout closes clean and books her lot's accrual on manager one.
        uint256 aliceId = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        uint256 aliceBooked = _yieldOwed(aliceId);
        assertGt(aliceBooked, 0, "fixture: alice booked nothing");
        assertEq(_bearer(aliceId), address(credit), "fixture: bearer is manager one");
        assertEq(credit.claimableOf(address(auction)), aliceBooked, "fixture: the booking is backed on manager one");

        // The lot leaves custody so it does not pad the second era's pot. Ordinary owner action.
        vm.prank(admin);
        auction.disposeWorkoutLot(aliceId, alice);

        // The ordinary zero-debt migration. Nothing refuses it: no debt, no live auction, no open
        // workout. Alice's booking stays on manager one, unclaimed, exactly as round 21 intends.
        CreditManager fresh = _migrate();
        assertEq(credit.claimableOf(address(auction)), aliceBooked, "manager one still holds alice's backing");
        assertEq(auction.totalWorkoutYieldOwed(), aliceBooked, "and the auction still books it");

        // Era two: bob's workout on the new manager, one epoch, clean close.
        uint256 bobId = _openWorkoutOn(fresh, bob);
        _streamEpochOn(fresh, EPOCH);
        uint256 bobEarned = fresh.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        assertGt(bobEarned, aliceBooked, "fixture: bob must earn more than alice booked for the clamp to be visible");
        _rescueDebtOn(fresh, bob);

        auction.closeWorkout(bobId);
        uint256 bobBooked = _yieldOwed(bobId);
        emit log_named_uint("MEASURED alice booked on manager one   ", aliceBooked);
        emit log_named_uint("MEASURED bob's lot earned on manager two", bobEarned);
        emit log_named_uint("MEASURED bob booked                    ", bobBooked);
        assertEq(bobBooked, bobEarned, "bob was not booked in full: the detached booking clamped his close");
        assertEq(auction.workoutYieldOwedOn(address(credit)), aliceBooked, "alice's booking is split onto manager one");
        assertEq(auction.workoutYieldOwedOn(address(fresh)), bobBooked, "bob's booking is split onto manager two");
        assertEq(auction.totalWorkoutYieldOwed(), aliceBooked + bobBooked, "the split sums to the aggregate");

        // Alice claims first. Her claim pulls the LIVE manager (bob's pot) AND her recorded bearer
        // (her own backing), reserves bob's booking, and pays her out of what is left: hers.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        uint256 alicePaid = usdc.balanceOf(alice) - aliceBefore;
        assertEq(alicePaid, aliceBooked, "alice was not paid her booking in full");
        assertEq(credit.claimableOf(address(auction)), 0, "alice's claim did not pull her own backing off manager one");
        assertEq(auction.workoutYieldOwedOn(address(credit)), 0, "alice's split was not cleared");
        assertEq(usdc.balanceOf(address(auction)), bobBooked, "bob's realised pot was not left whole for bob");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(stranger);
        auction.claimWorkoutYield(bobId);
        uint256 bobPaid = usdc.balanceOf(bob) - bobBefore;
        emit log_named_uint("MEASURED alice paid                    ", alicePaid);
        emit log_named_uint("MEASURED bob paid                      ", bobPaid);
        assertEq(bobPaid, bobEarned, "bob was not paid what his lot earned");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a booking is left after both were paid");
        assertEq(auction.workoutYieldOwedOn(address(fresh)), 0, "bob's split was not cleared");

        // Nothing that was owed is left for either sweep. The detached manager has nothing to push
        // and the auction holds nothing unreserved, so both refuse.
        assertEq(usdc.balanceOf(address(auction)), 0, "the auction holds USDC after both claims");
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        uint256 insuranceBefore = fresh.insuranceFund();
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        assertEq(fresh.insuranceFund(), insuranceBefore, "insurance gained yield that was owed to a borrower");
    }

    /// @notice CONTROL for the finding: the identical sequence with one permissionless call in a
    ///         different place. A stranger pushes alice's backing from the detached manager BEFORE
    ///         bob's close, and bob is booked and paid in full.
    function test_R52A02_control_pushingTheDetachedBackingFirstBooksTheNextCloseInFull() public {
        uint256 aliceId = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        uint256 aliceBooked = _yieldOwed(aliceId);

        vm.prank(admin);
        auction.disposeWorkoutLot(aliceId, alice);
        CreditManager fresh = _migrate();

        uint256 bobId = _openWorkoutOn(fresh, bob);
        _streamEpochOn(fresh, EPOCH);
        uint256 bobEarned = fresh.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        _rescueDebtOn(fresh, bob);

        // The one difference.
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));

        auction.closeWorkout(bobId);
        uint256 bobBooked = _yieldOwed(bobId);
        emit log_named_uint("CONTROL bob earned", bobEarned);
        emit log_named_uint("CONTROL bob booked", bobBooked);
        assertEq(bobBooked, bobEarned, "control: bob was not booked in full");

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        auction.claimWorkoutYield(aliceId);
        auction.claimWorkoutYield(bobId);
        assertEq(usdc.balanceOf(alice) - aliceBefore, aliceBooked, "control: alice underpaid");
        assertEq(usdc.balanceOf(bob) - bobBefore, bobBooked, "control: bob underpaid");
    }

    // ── 2. The mirror under ONE manager ──────────────────────────────────────

    /// @notice NEGATIVE, with the dust measured. `claimWorkoutYield` reserves
    ///         `totalUnclaimedRewards + _openWorkoutAccrual` and NOT the other closed workouts'
    ///         bookings. Under one manager that cannot pay one closed borrower out of another's
    ///         booking beyond dust, because each booking was clamped at its close to
    ///         `reachable - spokenFor` over the same pot, and the pot has only floored per settle
    ///         since. Two clean closes with a third workout still open, claimed in both orders:
    ///         the shortfall the LAST claimant absorbs is the dust, and the dust is what is printed.
    function test_R52A02_negative_theMirrorCannotTakeAnotherBookingBeyondDustUnderOneManager() public {
        _seed(carol, DILUTION_BONDS);
        _seed(dave, BONDS);
        uint256 aliceId = _openWorkout(alice);
        uint256 bobId = _openWorkout(bob);
        uint256 daveId = _openWorkout(dave);
        _streamEpoch(EPOCH);

        _rescueDebt(alice);
        _rescueDebt(bob);
        auction.closeWorkout(aliceId);
        auction.closeWorkout(bobId);
        uint256 a = _yieldOwed(aliceId);
        uint256 b = _yieldOwed(bobId);
        uint256 daveAccrual = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(daveId));
        assertGt(a, 0);
        assertGt(b, 0);
        assertGt(daveAccrual, 0);

        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        uint256 aPaid = usdc.balanceOf(alice) - aBefore;

        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(stranger);
        auction.claimWorkoutYield(bobId);
        uint256 bPaid = usdc.balanceOf(bob) - bBefore;

        emit log_named_uint("MEASURED alice booked", a);
        emit log_named_uint("MEASURED alice paid  ", aPaid);
        emit log_named_uint("MEASURED bob booked  ", b);
        emit log_named_uint("MEASURED bob paid    ", bPaid);
        emit log_named_uint("MEASURED bob's shortfall (the dust)", b - bPaid);
        assertEq(aPaid, a, "alice took more or less than her own booking");
        assertLe(b - bPaid, 4, "bob's shortfall exceeds rounding dust: alice was paid out of bob's booking");

        // Dave is still whole: his accrual was reserved against both claims.
        _rescueDebt(dave);
        auction.closeWorkout(daveId);
        uint256 d = _yieldOwed(daveId);
        emit log_named_uint("MEASURED dave accrual", daveAccrual);
        emit log_named_uint("MEASURED dave booked ", d);
        assertLe(daveAccrual - d, 4, "dave's booking was spent by an earlier claim");
    }

    // ── 3. Round-52 item 166's rounding cost, refined: it is per SETTLE, not per unit ───────

    /// @notice **INCIDENTAL, executed.** Round-52 item 166 records the reserve as rounding "up by
    ///         one unit on the safe side". The reserve floors ONCE against the global accumulator;
    ///         the manager's pot for the auction's position floors once per SETTLE of that position,
    ///         and `settle(auction)` is permissionless. So the pot's deficit against the exact accrual
    ///         grows by up to one wei per settle while workouts stay open, and it is the closed
    ///         borrowers' claims that absorb it. The grind is the same one `CreditManager.settle`'s
    ///         docstring bounds at "about 1,500x the damage in gas"; this measures its size on the
    ///         shared position rather than re-arguing the economics.
    function test_R52A02_incidental_thePotFloorsOncePerSettleAndTheReserveDoesNot() public {
        _seed(carol, DILUTION_BONDS);
        uint256 aliceId = _openWorkout(alice);
        uint256 bobId = _openWorkout(bob);

        // A stream, ground by a stranger at one settle per hour.
        _startStreamOn(credit, EPOCH);
        uint256 settles;
        uint256 hourly = 1 hours;
        for (uint256 t = hourly; t <= Config.YIELD_STREAM_DURATION; t += hourly) {
            skip(hourly);
            vm.prank(stranger);
            credit.settle(address(auction));
            settles++;
        }
        skip(1);
        credit.accrueYield();

        uint256 exact = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(aliceId))
            + credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        uint256 pot = credit.claimableOf(address(auction)) + credit.pendingYieldOf(address(auction));
        emit log_named_uint("MEASURED settles ground on the shared position", settles);
        emit log_named_uint("MEASURED exact accrual of the two open lots   ", exact);
        emit log_named_uint("MEASURED manager's pot for the position       ", pot);
        emit log_named_uint("MEASURED pot deficit against exact (wei)      ", exact > pot ? exact - pot : 0);
        emit log_named_uint("MEASURED pot excess over exact (wei)          ", pot > exact ? pot - exact : 0);
        assertLe(exact > pot ? exact - pot : 0, settles + 2, "the deficit outran one wei per settle");
    }

    /// @notice CONTROL for the settle grind: with nobody settling, the pot and the exact accrual
    ///         differ by the two floors round 51's docstring names, and no more.
    function test_R52A02_control_withNoGrindThePotAndTheReserveDifferByTheTwoFloors() public {
        _seed(carol, DILUTION_BONDS);
        uint256 aliceId = _openWorkout(alice);
        uint256 bobId = _openWorkout(bob);
        _streamEpoch(EPOCH);

        uint256 exact = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(aliceId))
            + credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        uint256 pot = credit.claimableOf(address(auction)) + credit.pendingYieldOf(address(auction));
        emit log_named_uint("CONTROL exact", exact);
        emit log_named_uint("CONTROL pot  ", pot);
        uint256 gap = exact > pot ? exact - pot : pot - exact;
        assertLe(gap, 2, "control: the gap is more than the two floors");
    }

    // ── 4. Negatives on the queue ────────────────────────────────────────────

    /// @notice NEGATIVE. `disposeWorkoutLot` cannot drop an OPEN workout's terms from the reserve:
    ///         it refuses anything but a Closed workout, so `bondCount` is constant across the
    ///         interval the two running sums are maintained over.
    function test_R52A02_negative_disposeRefusesAnOpenWorkoutSoTheSumsCannotDrift() public {
        uint256 id = _openWorkout(alice);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.WorkoutNotClosed.selector, id));
        vm.prank(admin);
        auction.disposeWorkoutLot(id, alice);
    }

    /// @notice NEGATIVE. One workout closes clean while another stays open: the closed one's
    ///         accrual moves from the open-accrual term to `totalWorkoutYieldOwed` and is not
    ///         counted twice. With the pot realised onto the auction, a donation is swept in full
    ///         (to dust); a double count would refuse or short it by the closed booking.
    function test_R52A02_negative_theReserveDoesNotDoubleCountAClosedWorkoutBesideAnOpenOne() public {
        uint256 aliceId = _openWorkout(alice);
        uint256 bobId = _openWorkout(bob);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        uint256 a = _yieldOwed(aliceId);
        assertGt(a, 0);
        assertGt(auction.openWorkoutCount(), 0, "fixture: bob is not open");

        // Realise the whole shared pot onto the auction, then add a donation on top.
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        uint256 donation = 250e6;
        _donate(donation);

        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        uint256 swept = credit.insuranceFund() - insuranceBefore;
        emit log_named_uint("MEASURED donation", donation);
        emit log_named_uint("MEASURED swept   ", swept);
        uint256 gap = swept > donation ? swept - donation : donation - swept;
        assertLe(gap, 2, "the sweep took more or less than the donation: a term is counted twice or missing");

        // Bob's booking then survives whole.
        _rescueDebt(bob);
        auction.closeWorkout(bobId);
        uint256 b = _yieldOwed(bobId);
        uint256 bobEarned = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        assertLe(bobEarned - b, 2, "bob's booking was clipped by the donation sweep");
        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);
        auction.claimWorkoutYield(aliceId);
        auction.claimWorkoutYield(bobId);
        assertEq(usdc.balanceOf(alice) - aBefore, a);
        assertEq(usdc.balanceOf(bob) - bBefore, b);
    }

    // ── 5. Round-52 item 162, pinned rather than found ───────────────────────

    /// @notice PIN of current behaviour (round-52 item 162, Chris's decision, docstring fix only).
    ///         A clean close reached by `repayFor` charges NONE of `penaltyRemaining`: the field is
    ///         untouched, no caller reward accrues, insurance receives nothing at the close. The
    ///         struct docstring now says so; before round 52 its "charged once" described the
    ///         `workoutSettle` tranche path and read as though it covered every exit. The +101-byte
    ///         behavioural alternative flips this pin (31,437,500 to 0) and is NOT applied.
    function test_R52A02_pin_aCleanCloseByRepayForChargesNoneOfThePenalty() public {
        uint256 id = _openWorkout(alice);
        uint256 penaltyAtExpiry = _penaltyRemaining(id);
        assertGt(penaltyAtExpiry, 0, "fixture: no penalty was fixed at expiry");
        _streamEpoch(EPOCH);
        _rescueDebt(alice);

        uint256 rewardsBefore = auction.totalUnclaimedRewards();
        uint256 insuranceBefore = credit.insuranceFund();
        auction.closeWorkout(id);

        emit log_named_uint("MEASURED penaltyRemaining fixed at expiry", penaltyAtExpiry);
        emit log_named_uint("MEASURED penaltyRemaining after the clean close", _penaltyRemaining(id));
        assertEq(_penaltyRemaining(id), penaltyAtExpiry, "the clean close charged part of the penalty");
        assertEq(auction.totalUnclaimedRewards(), rewardsBefore, "the clean close accrued a caller reward");
        assertEq(credit.insuranceFund(), insuranceBefore, "the clean close funded insurance");
        assertGt(_yieldOwed(id), 0, "and the lot's whole yield is the borrower's");
    }
}
