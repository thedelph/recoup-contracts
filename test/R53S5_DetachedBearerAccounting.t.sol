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
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R53S5 - workout bookings split by the manager that backs them
/// @notice Audit round 53, round-53 item 178 (MEDIUM), shipped as round 52's variant A by Chris's
///         decision of 2026-09-05. Self-contained: this file deploys its own stack and inherits
///         nothing from the repository's fixtures.
///
/// @dev The fix has three parts and each test below holds one of them to the tree:
///      `closeWorkout`'s clean-branch clamp subtracts `workoutYieldOwedOn[cm]` rather than
///      `totalWorkoutYieldOwed`, so a booking backed on a DETACHED manager cannot clamp a close on
///      the LIVE one; `claimWorkoutYield` reserves every OTHER booking
///      (`totalWorkoutYieldOwed - owed`) so one closed borrower cannot be paid out of another's
///      realised pot; and `claimWorkoutYield` pulls the workout's recorded `bearer` as well as the
///      live manager, best-effort, so a claim realises its own backing.
///
///      The residual the fix leaves is asserted as what it IS rather than argued away: a booking on
///      a detached bearer that nobody has pulled is reserved without being in the balance, so an
///      unrelated claimant is under-paid by exactly that booking until it is pulled, and
///      `sweepFreeBalanceToInsurance` refuses in that state. Over-reservation, recoverable by any
///      stranger's `claimSurplusFor(auction)`, round-52 item 166's shape.
///
///      🟥 **NEUTER.** Put `closeWorkout`'s clamp back on the aggregate - change the one read
///      `workoutYieldOwedOn[cm]` in `spokenFor` to `totalWorkoutYieldOwed` - and run this file with
///      `forge test --force`: `test_R53S5_fix_theDetachedBookingDoesNotClampTheNextCleanClose` goes
///      red at "bob was not booked in full: the detached booking clamped his close: 500000000 !=
///      999999999", and `test_R53S5_residual_aThirdDetachedBearerOverReservesUntilPulled` goes red
///      at "carol was not booked in full: 500000000 != 999999999" on the same mechanism. MEASURED
///      by round 53's stream S5 at the tree that ships the fix, under `--force`, `src/` restored
///      from the index afterwards: **all four went red, 0 passed / 4 failed**, not the two this
///      note first predicted. The other two fail downstream of the clamp rather than on it - the
///      live claimant's short is no longer "exactly alice's booking" once his booking was clamped
///      by it (`NothingToClaim()` on his second claim), and the reverting-bearer case's refusal
///      never comes because the clamped booking is met from the live pot. A neuter that reddens
///      more than predicted is still a neuter; the prediction is corrected here rather than the
///      assertions widened to meet it.
contract R53S5_DetachedBearerAccounting is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;

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

    /// @dev Open a workout for `who` on `cm`, stream one epoch, rescue, close clean, dispose the
    ///      lot so it does not pad the next era's pot. Returns the auction id and the booking.
    function _closeCleanOn(CreditManager cm, address who) internal returns (uint256 id, uint256 booked, uint256 earned) {
        id = _openWorkoutOn(cm, who);
        _streamEpochOn(cm, EPOCH);
        earned = cm.yieldAccruedOn(BONDS, _yieldIndexAtOpen(id));
        _rescueDebtOn(cm, who);
        auction.closeWorkout(id);
        booked = _yieldOwed(id);
        assertGt(booked, 0, "fixture: nothing booked");
        assertEq(_bearer(id), address(cm), "fixture: bearer is not the closing manager");
        vm.prank(admin);
        auction.disposeWorkoutLot(id, who);
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

    function _claim(uint256 id, address who) internal returns (uint256 paid) {
        uint256 before = usdc.balanceOf(who);
        vm.prank(stranger);
        auction.claimWorkoutYield(id);
        paid = usdc.balanceOf(who) - before;
    }

    // ── 1. The finding under the fix ─────────────────────────────────────────

    /// @notice FIX. Alice closes clean on manager one and is booked there; the vault migrates;
    ///         bob closes clean on manager two. Under the aggregate clamp bob was booked
    ///         `earned - aliceBooked`; under the split he is booked `earned`. Then the claims, in
    ///         the order that used to misallocate (alice first): alice is paid from her own backing,
    ///         pulled off manager one by her own claim, bob's realised pot is reserved for bob and
    ///         bob is paid it in full, and neither sweep can take anything because nothing owed is
    ///         left unreserved.
    function test_R53S5_fix_theDetachedBookingDoesNotClampTheNextCleanClose() public {
        (uint256 aliceId, uint256 aliceBooked,) = _closeCleanOn(credit, alice);
        CreditManager fresh = _migrate();
        assertEq(credit.claimableOf(address(auction)), aliceBooked, "manager one holds alice's backing");
        assertEq(auction.workoutYieldOwedOn(address(credit)), aliceBooked, "alice's booking is split onto manager one");
        assertEq(auction.workoutYieldOwedOn(address(fresh)), 0, "manager two backs nothing yet");

        (uint256 bobId, uint256 bobBooked, uint256 bobEarned) = _closeCleanOn(fresh, bob);
        assertGt(bobEarned, aliceBooked, "fixture: bob must earn more than alice booked for the clamp to be visible");
        emit log_named_uint("MEASURED alice booked on manager one   ", aliceBooked);
        emit log_named_uint("MEASURED bob's lot earned on manager two", bobEarned);
        emit log_named_uint("MEASURED bob booked                    ", bobBooked);
        assertEq(bobBooked, bobEarned, "bob was not booked in full: the detached booking clamped his close");
        assertEq(auction.workoutYieldOwedOn(address(fresh)), bobBooked, "bob's booking is split onto manager two");
        assertEq(auction.totalWorkoutYieldOwed(), aliceBooked + bobBooked, "the split does not sum to the aggregate");

        uint256 alicePaid = _claim(aliceId, alice);
        assertEq(alicePaid, aliceBooked, "alice was not paid her booking in full");
        assertEq(credit.claimableOf(address(auction)), 0, "alice's claim did not pull her own backing");
        assertEq(fresh.claimableOf(address(auction)), 0, "alice's claim did not realise the live pot");
        assertEq(usdc.balanceOf(address(auction)), bobBooked, "bob's realised pot was not held whole for bob");
        assertEq(auction.workoutYieldOwedOn(address(credit)), 0, "alice's split was not cleared");

        uint256 bobPaid = _claim(bobId, bob);
        assertEq(bobPaid, bobEarned, "bob was not paid what his lot earned");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a booking remains after both were paid");
        assertEq(auction.workoutYieldOwedOn(address(fresh)), 0, "bob's split was not cleared");
        assertEq(usdc.balanceOf(address(auction)), 0, "the auction holds USDC after both claims");

        vm.expectRevert(CreditManager.NothingToClaim.selector);
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
    }

    // ── 2. The residual, asserted as what it is ──────────────────────────────

    /// @notice RESIDUAL (round-52 item 166's shape), asserted as what it IS. Three managers: alice
    ///         books on manager one, bob on manager two, carol on the live manager three, nobody
    ///         pulls either detached pot. Carol is booked in full (the clamp reads only manager
    ///         three's split), but her claim reserves alice's and bob's bookings against a balance
    ///         that holds only her own realised pot, so she is paid `earned - alice - bob`, short by
    ///         exactly the two unpulled bookings. In that state `sweepFreeBalanceToInsurance`
    ///         refuses `NothingUnreserved`. Each detached pot pulled by a stranger's
    ///         `claimSurplusFor(auction)` releases exactly its own booking to carol's next claim;
    ///         after both, everybody is paid in full and nothing reaches insurance.
    ///
    ///         Over-reservation, not misallocation: the money is never paid to the wrong person, it
    ///         is paid late until somebody runs a permissionless call. That is the safe direction
    ///         and the direction the shipped variant chose deliberately.
    function test_R53S5_residual_aThirdDetachedBearerOverReservesUntilPulled() public {
        _seed(carol, BONDS);
        (uint256 aliceId, uint256 aliceBooked,) = _closeCleanOn(credit, alice);
        CreditManager two = _migrate();
        (uint256 bobId, uint256 bobBooked,) = _closeCleanOn(two, bob);
        CreditManager three = _migrate();
        (uint256 carolId, uint256 carolBooked, uint256 carolEarned) = _closeCleanOn(three, carol);
        emit log_named_uint("MEASURED alice booked on manager one   ", aliceBooked);
        emit log_named_uint("MEASURED bob booked on manager two     ", bobBooked);
        emit log_named_uint("MEASURED carol earned on manager three ", carolEarned);
        emit log_named_uint("MEASURED carol booked                  ", carolBooked);
        assertEq(carolBooked, carolEarned, "carol was not booked in full");
        assertGt(carolEarned, aliceBooked + bobBooked, "fixture: carol must out-earn the two detached bookings");
        assertEq(auction.workoutYieldOwedOn(address(credit)), aliceBooked);
        assertEq(auction.workoutYieldOwedOn(address(two)), bobBooked);
        assertEq(auction.workoutYieldOwedOn(address(three)), carolBooked);

        // Carol claims with both detached pots unpulled: short by exactly those two bookings.
        uint256 carolPaid = _claim(carolId, carol);
        emit log_named_uint("MEASURED carol paid, both detached pots unpulled", carolPaid);
        assertEq(carolPaid, carolEarned - aliceBooked - bobBooked, "carol's short is not exactly the two unpulled bookings");
        assertEq(_yieldOwed(carolId), aliceBooked + bobBooked, "carol's remainder is not recorded");
        assertEq(usdc.balanceOf(address(auction)), aliceBooked + bobBooked, "the auction holds other than the reserved remainder");

        // The free-balance sweep refuses in that state: everything here is spoken for.
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();

        // Pull manager one only: carol's next claim releases exactly alice's booking.
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        uint256 carolPaid2 = _claim(carolId, carol);
        emit log_named_uint("MEASURED carol paid after manager one pulled", carolPaid2);
        assertEq(carolPaid2, aliceBooked, "pulling manager one did not release exactly alice's booking to carol");

        // Pull manager two: the rest.
        vm.prank(stranger);
        two.claimSurplusFor(address(auction));
        uint256 carolPaid3 = _claim(carolId, carol);
        assertEq(carolPaid3, bobBooked, "pulling manager two did not release exactly bob's booking to carol");
        assertEq(carolPaid + carolPaid2 + carolPaid3, carolEarned, "carol was not paid what her lot earned in total");
        assertEq(_yieldOwed(carolId), 0);

        // Alice and bob are whole; their backing was pulled and reserved for them throughout.
        assertEq(_claim(aliceId, alice), aliceBooked, "alice was not paid in full");
        assertEq(_claim(bobId, bob), bobBooked, "bob was not paid in full");
        assertEq(auction.totalWorkoutYieldOwed(), 0);
        assertEq(usdc.balanceOf(address(auction)), 0, "the auction holds USDC after every claim");
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
    }

    /// @notice RESIDUAL, the other claim order on two managers. Bob (live) claims BEFORE alice
    ///         (detached, unpulled): he is paid `earned - aliceBooked`, then alice's own claim pulls
    ///         her bearer and is paid in full, and bob's second claim collects the remainder. The
    ///         total each receives is the same in either order; only the timing moves.
    function test_R53S5_residual_theLiveClaimantIsShortUntilTheDetachedPotIsPulled() public {
        (uint256 aliceId, uint256 aliceBooked,) = _closeCleanOn(credit, alice);
        CreditManager fresh = _migrate();
        (uint256 bobId,, uint256 bobEarned) = _closeCleanOn(fresh, bob);

        uint256 bobPaid = _claim(bobId, bob);
        assertEq(bobPaid, bobEarned - aliceBooked, "bob's short is not exactly alice's unpulled booking");
        assertEq(credit.claimableOf(address(auction)), aliceBooked, "bob's claim pulled a bearer that is not his");

        uint256 alicePaid = _claim(aliceId, alice);
        assertEq(alicePaid, aliceBooked, "alice was not paid in full from her own backing");
        assertEq(credit.claimableOf(address(auction)), 0, "alice's claim did not pull her bearer");

        uint256 bobPaid2 = _claim(bobId, bob);
        assertEq(bobPaid + bobPaid2, bobEarned, "bob was not paid what his lot earned in total");
        assertEq(auction.totalWorkoutYieldOwed(), 0);
        assertEq(usdc.balanceOf(address(auction)), 0);
    }

    // ── 3. The bearer pull is best-effort ────────────────────────────────────

    /// @notice The `try ICreditManager(bearer).claimSurplus() {} catch {}` on a detached bearer that
    ///         REVERTS leaves the claim path alive. Alice's bearer is mocked to revert on
    ///         `claimSurplus()`. Her claim does not bubble that revert: the bearer pull is caught,
    ///         the live pull is made and reserved for bob, and with nothing of hers here the call
    ///         ends in the auction's own `NothingToClaim` rather than the bearer's revert data, and
    ///         that refusal rolls back cleanly. Bob's claim meanwhile is paid short by exactly
    ///         alice's unpulled booking, the residual above, and never out of it. Once the bearer
    ///         answers again alice is paid in full from it and bob collects his remainder. A
    ///         manager that cannot pay must not be able to hold up a payment, and a claim that is
    ///         refused for lack of money is not a claim that was lost.
    function test_R53S5_bearerPullIsBestEffort_aRevertingBearerDoesNotBlockTheClaim() public {
        (uint256 aliceId, uint256 aliceBooked,) = _closeCleanOn(credit, alice);
        CreditManager fresh = _migrate();
        (uint256 bobId,, uint256 bobEarned) = _closeCleanOn(fresh, bob);

        bytes memory bearerDown = abi.encodeWithSignature("Error(string)", "bearer down");
        vm.mockCallRevert(address(credit), abi.encodeWithSelector(ICreditManager.claimSurplus.selector), bearerDown);
        // The mock takes: a direct call sees the bearer's own revert.
        vm.expectRevert(bearerDown);
        vm.prank(address(auction));
        credit.claimSurplus();

        // Alice's claim: the bearer pull is caught, the live pull lands inside the call, bob's pot
        // is reserved against it, and with none of alice's backing here the refusal is the
        // auction's own `NothingToClaim`, not the bearer's revert data. The refusal rolls the live
        // pull back with it, so nothing has moved: bob's pot is still on manager two and alice's
        // booking is still recorded.
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        assertEq(fresh.claimableOf(address(auction)), bobEarned, "a refused claim moved bob's pot");
        assertEq(_yieldOwed(aliceId), aliceBooked, "alice's booking moved on a refused claim");

        // Bob claims through the same state: paid short by alice's unpulled booking (the residual
        // the test above measures), never out of it.
        uint256 bobPaid = _claim(bobId, bob);
        assertEq(bobPaid, bobEarned - aliceBooked, "bob's short beside a reverting bearer is not exactly alice's booking");

        // The bearer recovers; alice's claim pulls it and pays her in full, and bob's second claim
        // collects his remainder.
        vm.clearMockedCalls();
        assertEq(_claim(aliceId, alice), aliceBooked, "alice was not paid in full once her bearer answered");
        assertEq(credit.claimableOf(address(auction)), 0, "her backing was not pulled off the bearer");
        assertEq(bobPaid + _claim(bobId, bob), bobEarned, "bob was not paid what his lot earned in total");
        assertEq(auction.totalWorkoutYieldOwed(), 0);
        assertEq(usdc.balanceOf(address(auction)), 0);
    }
}
