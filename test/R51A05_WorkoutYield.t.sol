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

/// @title R51A05 - the workout-yield lifecycle, from the permissionless doors
/// @notice Audit round 51. Self-contained: this file deploys its own stack and inherits nothing
///         from the repository's fixtures, so the replay tool can patch it whole and no shipped
///         suite rides along with it.
///
/// @dev The subject is every path by which yield accrued to a bond position parked under an OPEN
///      workout becomes free balance, is claimed, is swept to insurance, or is paid to a borrower,
///      and who may order those paths.
contract R51A05_WorkoutYield is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
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

        _seed(alice);
        _seed(bob);
    }

    // ── fixture helpers ──────────────────────────────────────────────────────

    function _seed(address who) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _maxBorrow(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return (bonds * nav * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    function _navAtDebtParity(uint256 debt, uint256 bonds) internal pure returns (uint256) {
        return (debt * Config.USDC_TO_NAV_SCALE) / bonds;
    }

    /// @dev Borrow at the ceiling, crash NAV, liquidate, lapse the window, expire to a workout.
    function _openWorkout(address who) internal returns (uint256 id) {
        uint256 debt = _maxBorrow(BONDS, oracle.navPerBond());
        vm.prank(who);
        credit.borrow(debt);

        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);

        vm.prank(keeper);
        credit.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: no auction opened");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(who), 1, "fixture: no workout opened");
    }

    /// @dev One epoch of borrower-side yield, fully streamed and accrued.
    function _streamEpoch(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION + 1);
        credit.accrueYield();
    }

    /// @dev A third party clears the defaulted debt, which makes the close CLEAN.
    function _rescueDebt(address who) internal {
        uint256 owed = credit.currentDebtOf(who);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(credit), owed);
        credit.repayFor(who, owed);
        vm.stopPrank();
        assertEq(credit.debtOf(who), 0, "fixture: debt not cleared");
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _penaltyRemaining(uint256 id) internal view returns (uint256 p) {
        (,,,,,, p,,,,) = auction.workouts(id);
    }

    function _writtenDown(uint256 id) internal view returns (uint256 w) {
        (,,,,,,, w,,,) = auction.workouts(id);
    }

    // ── 1. CONTROL: the honest outcome ───────────────────────────────────────

    /// @notice CONTROL. Nobody touches anything between the repayment and the close, so the clean
    ///         close books the lot's whole accrual and `claimWorkoutYield` pays it to the borrower.
    function test_R51A05_control_aCleanCloseBooksAndPaysTheWholeLotYield() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);

        auction.closeWorkout(id);
        uint256 booked = _yieldOwed(id);
        emit log_named_uint("CONTROL booked to the borrower", booked);
        // Half the epoch, less the stream's rounding wei: the fixture stakes 200 bonds and this
        // workout's lot is 100 of them, so the accumulator pays the lot exactly its share.
        assertEq(booked, EPOCH / 2 - 1, "control: the close did not book the lot's whole share");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - before, booked, "control: the borrower was not paid");
        assertEq(auction.totalWorkoutYieldOwed(), 0);
    }

    // ── 2. THE MIRROR: a second, unguarded door onto the same strip ──────────

    /// @notice **FINDING (mirror).** The mid-workout strip does not need
    ///         `sweepWorkoutYieldToInsurance` at all. `CreditManager.claimSurplusFor(auction)` is
    ///         permissionless and pushes the auction's whole claim onto the auction as free USDC;
    ///         `LiquidationAuction.sweepFreeBalanceToInsurance` is permissionless and reserves only
    ///         `totalUnclaimedRewards + totalWorkoutYieldOwed` - neither of which an OPEN workout
    ///         contributes to - so it moves the lot on to insurance. Two transactions, by an
    ///         address with no role, and the later clean close books ZERO.
    ///
    ///         This matters because the hazard was recorded against
    ///         `sweepWorkoutYieldToInsurance` by name, in `LiquidationAuction.closeWorkout`'s own
    ///         comment and in `Impairment.integration.t.sol`. A guard written on that one function
    ///         would have been inert: this pair reaches the same state and does not call it.
    ///
    ///         **FLIPPED by round-51 item 154's fix, and this is what it buys.** Door one still
    ///         opens - `claimSurplusFor` is permissionless and its destination is not chooseable -
    ///         and door two is now shut, because both sweeps reserve what still-OPEN workouts have
    ///         earned. The borrower is booked and paid in full.
    function test_R51A05_strangerStripsAnOpenWorkoutsYieldWithoutTheWorkoutSweep() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);

        uint256 insuranceBefore = credit.insuranceFund();

        // Door one, on the manager: permissionless, destination not chooseable. It still opens.
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        uint256 pushed = usdc.balanceOf(address(auction));
        emit log_named_uint("MEASURED pushed onto the auction by claimSurplusFor", pushed);
        assertGt(pushed, 0, "claimSurplusFor pushed nothing");

        // Door two, on the auction. It USED to take the whole lot accrual. The open workout's
        // accrual is reserved now, so there is nothing above the reserve and the call is refused.
        vm.prank(stranger);
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepFreeBalanceToInsurance();
        assertEq(credit.insuranceFund(), insuranceBefore, "insurance took the open workout's backing");

        // And the close books the lot's whole accrual, which the strip used to take.
        _rescueDebt(alice);
        auction.closeWorkout(id);
        uint256 booked = _yieldOwed(id);
        emit log_named_uint("MEASURED booked to the borrower with the strip refused", booked);
        assertGt(booked, 0, "the close booked nothing, so the strip still happened");

        uint256 paidBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - paidBefore, booked, "the borrower was not paid in full");
    }

    /// @notice **FINDING (mirror, third door).** `claimWorkoutYield` itself pulls the auction's
    ///         WHOLE claim - including the accrual of lots whose workout is still open - and leaves
    ///         the remainder as free balance. So a workout that has already closed cleanly gives a
    ///         stranger a third route to realise an OPEN workout's yield onto the auction, where
    ///         `sweepFreeBalanceToInsurance` takes it.
    ///
    ///         Alice's workout closes clean and is paid. Bob's is still open. One `claimWorkoutYield`
    ///         on Alice's id still realises Bob's accrual onto the auction - which is why reserving
    ///         it in the SWEEPS is the bound that closes the door, rather than a guard on the claim.
    ///
    ///         **FLIPPED by round-51 item 154's fix, and the flip has a measured edge worth
    ///         stating.** The realisation still happens; what the sweep may now take is only what
    ///         is above the reserve, and that is DUST. MEASURED here: the claim realises
    ///         500000000 of Bob's lot onto the auction and the reserve reads 499999999, so exactly
    ///         1 unit is unattributed and sweepable. The reserve is `yieldAccruedOn` floored once
    ///         over the open queue, and the manager's own pot is not exactly the sum of those
    ///         floors - a wei can fall between them. It falls on the SAFE side: the sweep takes the
    ///         dust, Bob's booking survives whole and he is paid in full. The assertion is on the
    ///         bound rather than on a refusal, because a refusal here would be asserting a rounding
    ///         accident.
    function test_R51A05_claimWorkoutYieldRealisesAnOpenWorkoutsAccrualForTheSweep() public {
        uint256 aliceId = _openWorkout(alice);
        uint256 bobId = _openWorkout(bob);
        _streamEpoch(EPOCH);

        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        uint256 aliceBooked = _yieldOwed(aliceId);
        assertGt(aliceBooked, 0, "fixture: alice booked nothing");

        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);

        // The premise of the finding is unchanged: the whole shared pot IS realised onto the
        // auction, including the accrual of a lot whose workout is still open.
        uint256 leftBehind = usdc.balanceOf(address(auction));
        emit log_named_uint("MEASURED alice booked", aliceBooked);
        emit log_named_uint("MEASURED left on the auction after alice was paid", leftBehind);
        assertGt(leftBehind, 0, "nothing of bob's accrual was realised");

        // And the sweep that used to take the WHOLE of it can now reach only what is above the
        // reserve. MEASURED at 1 unit of a 500000000 realisation.
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        uint256 swept = credit.insuranceFund() - insuranceBefore;
        emit log_named_uint("MEASURED dust the sweep could still take", swept);
        assertLe(swept, 10, "the sweep reached past the aggregate-rounding dust into bob's backing");

        _rescueDebt(bob);
        auction.closeWorkout(bobId);
        uint256 bobBooked = _yieldOwed(bobId);
        emit log_named_uint("MEASURED bob booked with the strip refused", bobBooked);
        assertGt(bobBooked, 0, "bob's booking did not survive");

        uint256 bobBefore = usdc.balanceOf(bob);
        auction.claimWorkoutYield(bobId);
        assertEq(usdc.balanceOf(bob) - bobBefore, bobBooked, "bob was not paid in full");
    }

    /// @notice CONTROL for the two above: with nobody stripping, BOTH borrowers are booked and paid
    ///         their own lot's accrual, and the two figures add up to the epoch.
    function test_R51A05_control_twoWorkoutsBothBookTheirOwnLot() public {
        uint256 aliceId = _openWorkout(alice);
        uint256 bobId = _openWorkout(bob);
        _streamEpoch(EPOCH);

        _rescueDebt(alice);
        _rescueDebt(bob);
        auction.closeWorkout(aliceId);
        auction.closeWorkout(bobId);

        uint256 a = _yieldOwed(aliceId);
        uint256 b = _yieldOwed(bobId);
        emit log_named_uint("CONTROL alice booked", a);
        emit log_named_uint("CONTROL bob   booked", b);
        emit log_named_uint("CONTROL sum         ", a + b);
        assertGt(a, 0, "control: alice booked nothing");
        assertGt(b, 0, "control: bob booked nothing");

        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);
        auction.claimWorkoutYield(aliceId);
        auction.claimWorkoutYield(bobId);
        assertEq(usdc.balanceOf(alice) - aBefore, a, "control: alice underpaid");
        assertEq(usdc.balanceOf(bob) - bBefore, b, "control: bob underpaid");
    }

    // ── 3. The liquidation penalty on a clean close ──────────────────────────



    // ── 4. Negatives ─────────────────────────────────────────────────────────

    /// @notice NEGATIVE. `claimWorkoutYield` reserves only `totalUnclaimedRewards`, NOT the other
    ///         closed workouts' `yieldOwed` - so one borrower's claim is paid out of a pot shared
    ///         with every other claimant. It still cannot over-pay, because `pay` is clamped at
    ///         that workout's own booking, and the running total falls by exactly what it pays.
    ///         Tried to make alice take bob's booked yield; could not.
    function test_R51A05_negative_oneBorrowerCannotTakeAnothersBookedWorkoutYield() public {
        uint256 aliceId = _openWorkout(alice);
        uint256 bobId = _openWorkout(bob);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        _rescueDebt(bob);
        auction.closeWorkout(aliceId);
        auction.closeWorkout(bobId);

        uint256 a = _yieldOwed(aliceId);
        uint256 b = _yieldOwed(bobId);

        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        uint256 paid = usdc.balanceOf(alice) - aBefore;
        emit log_named_uint("MEASURED alice booked", a);
        emit log_named_uint("MEASURED alice paid  ", paid);
        assertEq(paid, a, "alice took more than her own booking");
        assertEq(auction.totalWorkoutYieldOwed(), b, "the running total did not fall by exactly the payment");

        // Bob is still whole.
        uint256 bBefore = usdc.balanceOf(bob);
        auction.claimWorkoutYield(bobId);
        assertEq(usdc.balanceOf(bob) - bBefore, b, "bob's booking was spent by alice");
    }

    /// @notice NEGATIVE. Once a clean close has BOOKED a figure, no permissionless door takes it:
    ///         both sweeps reserve `totalWorkoutYieldOwed`, so both refuse over the reserved cash.
    function test_R51A05_negative_noSweepTakesABookedFigure() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(id);
        uint256 booked = _yieldOwed(id);

        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));

        // Round-51 item 155: both refusals are `NothingUnreserved` now, which is the distinction
        // the shared `NothingToClaim` selector could not make - "the money is here and belongs to
        // somebody else" rather than "the manager owes nothing".
        vm.prank(stranger);
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepFreeBalanceToInsurance();

        // 🟥 **And this one is `NothingToClaim` raised by the MANAGER, not by the auction.** The
        // bare `claimSurplus()` at the top of `sweepWorkoutYieldToInsurance` reverts first, because
        // `claimSurplusFor` above already emptied the claim. That is item 155's third site for the
        // shared selector `0x969bf728`, and it is the one the fix deliberately leaves in place: the
        // ordering constraint the deleted `swept == 0` clause protected is protected here, one
        // frame down, by the manager's own revert. Round 52: the selector is named on the contract
        // that raises it. `LiquidationAuction.NothingToClaim.selector` is the same four bytes and
        // passed here for a round while naming the wrong contract.
        vm.prank(stranger);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        auction.sweepWorkoutYieldToInsurance();

        uint256 before = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - before, booked, "the booking was not met in full");
    }

    /// @notice **INCIDENTAL, executed.** `LiquidationAuction.closeWorkout`'s comment and
    ///         `R46WorkoutCloseSettles`'s docstring both justify the `try` around
    ///         `settle(address(this))` on the ground that "`settle` reaches `_pushUsdc`, so a USDC
    ///         that refuses a transfer to this contract would otherwise brick the exit of last
    ///         resort". MEASURED: `settle` moves no USDC at all. With the auction blocked on the
    ///         token, the close runs and books normally; the only revert `settle` has is
    ///         `whileAttached`, which is the ground the same comment dismisses as unreachable.
    function test_R51A05_settleMovesNoUsdcSoTheTrysStatedGroundIsFalse() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);

        // A blocked address cannot receive or send USDC on this token, which is the exact shape
        // the comment names.
        usdc.setBlocked(address(auction), true);

        // `settle` on the auction's own position succeeds regardless.
        credit.settle(address(auction));
        assertGt(credit.claimableOf(address(auction)), 0, "the settle did not run");

        // And so does the close, with the booking made against the settled term.
        auction.closeWorkout(id);
        uint256 booked = _yieldOwed(id);
        emit log_named_uint("MEASURED booked with the auction blocked on USDC", booked);
        assertEq(booked, EPOCH / 2 - 1, "the close behaved differently under a blocked token");

        // The payment leg is the one that actually needs USDC, and it is the one that reverts.
        usdc.setBlocked(address(auction), false);
    }

}
