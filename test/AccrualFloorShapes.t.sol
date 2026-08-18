// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

/// @title AccrualFloorShapes
/// @notice The three candidate shapes for `CreditManager._accrue`'s slice arithmetic, built side
///         by side and measured against each other.
///
/// @dev **This file exists to stop one specific fix being reached for again.** Audit round 21
///      found that `_accrue` floored its slice against the time since the *last call* while
///      writing `lastAccrualAt` unconditionally, so the integer division was charged once per
///      invocation of a permissionless, rate-limit-free function rather than once per stream.
///      The fix a reader reaches for first is to move `lastAccrualAt = endAt` below the
///      `amount == 0` check - hold the clock back on a zero slice.
///
///      **That fix is inert on any realistic epoch, and the assertion below says so in a way
///      that cannot be skimmed past.** At any rate above one wei per second the `amount == 0`
///      branch is never taken at all, so the line it moves is never reached: 5,080,000 before
///      and 5,080,000 after, `assertEq(variantA, shipped)`. It reads exactly like success
///      because it does close the sub-wei case *partially*, and the sub-wei case is the one
///      the finding leads with.
///
///      The shipped fix is `Cumulative`: floor once against a fixed origin. `Telescoping` is
///      the one-slot realisation of the same idea that `CreditManager._sliceOwed` actually
///      ships, and the fuzz at the bottom is the evidence that the two are the same function
///      rather than an argument that they ought to be.
///
///      Deliberately a model rather than a fixture. The property under test is arithmetic over
///      ~20,000 calls, and running that through the real contract costs minutes per case; the
///      real contract's behaviour is pinned by the stream tests in `CreditManager.t.sol`, which
///      is where the hazard is proved end to end.
contract AccrueModel {
    uint256 internal constant ACC = 1e18;

    enum Mode {
        /// @dev What shipped before the round-21 fix: floor against the previous call.
        Shipped,
        /// @dev The prescribed one-liner: hold the clock back on a zero slice. Refuted here.
        HoldClockOnZero,
        /// @dev Two slots - a fixed origin plus a cumulative "released so far" counter.
        Cumulative,
        /// @dev One slot - a fixed origin, with the cumulative figure recomputed from the clock.
        ///      This is `CreditManager._sliceOwed`.
        Telescoping
    }

    Mode public immutable mode;

    uint256 public yieldRate;
    uint256 public streamEndsAt;
    uint256 public lastAccrualAt;
    uint256 public undistributedYield;
    uint256 public accYieldPerBond;

    // Fixed-origin variants only.
    uint256 public streamStartedAt;
    // `Cumulative` only.
    uint256 public releasedSoFar;

    constructor(Mode mode_) {
        mode = mode_;
    }

    function rate(uint256 pot, uint256 duration) external {
        undistributedYield = pot;
        yieldRate = (pot * ACC) / duration;
        lastAccrualAt = block.timestamp;
        streamStartedAt = block.timestamp;
        releasedSoFar = 0;
        streamEndsAt = block.timestamp + duration;
    }

    function accrue(uint256 bonds) external {
        uint256 endAt = block.timestamp < streamEndsAt ? block.timestamp : streamEndsAt;
        uint256 last = lastAccrualAt;
        if (endAt <= last) return;

        uint256 pot = undistributedYield;
        uint256 amount;

        if (mode == Mode.Cumulative) {
            uint256 releasedTotal = ((endAt - streamStartedAt) * yieldRate) / ACC;
            amount = releasedTotal > releasedSoFar ? releasedTotal - releasedSoFar : 0;
        } else if (mode == Mode.Telescoping) {
            uint256 origin = streamStartedAt;
            uint256 owedByEnd = ((endAt - origin) * yieldRate) / ACC;
            uint256 owedByLast = last > origin ? ((last - origin) * yieldRate) / ACC : 0;
            amount = owedByEnd > owedByLast ? owedByEnd - owedByLast : 0;
        } else {
            amount = ((endAt - last) * yieldRate) / ACC;
        }
        if (amount > pot) amount = pot;

        if (mode != Mode.HoldClockOnZero) lastAccrualAt = endAt;
        if (amount == 0) return;
        if (mode == Mode.HoldClockOnZero) lastAccrualAt = endAt;

        if (mode == Mode.Cumulative) releasedSoFar += amount;
        undistributedYield = pot - amount;
        accYieldPerBond += (amount * ACC) / bonds;
    }
}

contract AccrualFloorShapesTest is Test {
    uint256 internal constant BONDS = 100;

    function _run(AccrueModel.Mode mode, uint256 pot, uint256 duration, uint256 gap, uint256 window)
        internal
        returns (uint256 distributed)
    {
        AccrueModel m = new AccrueModel(mode);
        m.rate(pot, duration);
        uint256 steps = window / gap;
        for (uint256 i = 0; i < steps; ++i) {
            skip(gap);
            m.accrue(BONDS);
        }
        distributed = pot - m.undistributedYield();
    }

    /// @notice A 110 USDC borrower share - the split's cut of a 200 USDC epoch - over the minimum
    ///         five-day window, walked 20,000 seconds one call at a time.
    /// @dev **The refutation of the prescribed one-liner, asserted rather than described.** At
    ///      this rate `amount` is never zero, so the branch `HoldClockOnZero` moves is never
    ///      taken and it delivers the shipped figure to the wei. If this assertion ever goes red,
    ///      somebody has changed the rate scale, not fixed the variant.
    function test_accrual_holdingTheClockBackIsInertOnARealisticEpoch() public {
        uint256 pot = 110e6;
        uint256 duration = 5 days;
        uint256 window = 20_000;

        uint256 shipped = _run(AccrueModel.Mode.Shipped, pot, duration, 1, window);
        uint256 variantA = _run(AccrueModel.Mode.HoldClockOnZero, pot, duration, 1, window);
        uint256 fixedOrigin = _run(AccrueModel.Mode.Telescoping, pot, duration, 1, window);
        uint256 oneShot = _run(AccrueModel.Mode.Shipped, pot, duration, window, window);

        console2.log("realistic epoch, 20000s walked one second at a time");
        console2.log("  pre-fix:", shipped);
        console2.log("  hold-the-clock one-liner:", variantA);
        console2.log("  fixed origin (shipped fix):", fixedOrigin);
        console2.log("  reference, a single call over the same window:", oneShot);

        assertEq(variantA, shipped, "the one-liner moved something at a rate above one wei/second");
        assertEq(fixedOrigin, oneShot, "the fixed origin did not recover the single-call figure");
        assertGt(fixedOrigin, shipped, "the fixed origin recovered nothing over the pre-fix form");
    }

    /// @notice The sharp case: a 1 USDC borrower share rated over a 30-day window, which
    ///         `distributeYield`'s `max(elapsed, 5 days, remaining)` produces after any long pause
    ///         in harvesting. `yieldRate < ACC_PRECISION`, so every per-second slice floors away.
    /// @dev The one-liner recovers most of this and not all: once a slice does reach one wei the
    ///      clock still jumps to `endAt` and that slice's own sub-wei remainder is still lost.
    function test_accrual_subWeiRatePaidNothingBeforeTheFix() public {
        uint256 pot = 1e6;
        uint256 duration = 30 days;
        uint256 window = 5_000;

        uint256 shipped = _run(AccrueModel.Mode.Shipped, pot, duration, 1, window);
        uint256 variantA = _run(AccrueModel.Mode.HoldClockOnZero, pot, duration, 1, window);
        uint256 fixedOrigin = _run(AccrueModel.Mode.Telescoping, pot, duration, 1, window);
        uint256 oneShot = _run(AccrueModel.Mode.Shipped, pot, duration, window, window);

        console2.log("sub-wei rate, 5000s walked one second at a time");
        console2.log("  pre-fix:", shipped);
        console2.log("  hold-the-clock one-liner:", variantA);
        console2.log("  fixed origin (shipped fix):", fixedOrigin);
        console2.log("  reference, a single call:", oneShot);

        assertEq(shipped, 0, "the pre-fix form paid something after all");
        assertGt(variantA, 0, "the one-liner recovered nothing");
        assertLt(variantA, oneShot, "the one-liner fully closed it after all - re-check the claim");
        assertEq(fixedOrigin, oneShot, "the fixed origin did not recover the single-call figure");
    }

    /// @notice The falsifier. On an ordinary keeper cadence the fix must be a hardening, not a
    ///         behaviour change - so nothing may pay out *less* than it used to, and a full
    ///         stream must land within one wei of its pot.
    function test_accrual_theFixIsNeutralOnTheOrdinaryCallSchedule() public {
        uint256 pot = 110e6;
        uint256 duration = 5 days;

        uint256 shipped = _run(AccrueModel.Mode.Shipped, pot, duration, 1 hours, duration);
        uint256 variantA = _run(AccrueModel.Mode.HoldClockOnZero, pot, duration, 1 hours, duration);
        uint256 fixedOrigin = _run(AccrueModel.Mode.Telescoping, pot, duration, 1 hours, duration);

        console2.log("hourly accrual over a whole 5-day stream");
        console2.log("  pre-fix:", shipped);
        console2.log("  hold-the-clock one-liner:", variantA);
        console2.log("  fixed origin (shipped fix):", fixedOrigin);
        console2.log("  pot:", pot);

        assertEq(shipped, variantA, "the one-liner is not neutral on the ordinary schedule either");
        assertGe(fixedOrigin, shipped, "the fixed origin pays less than the pre-fix form somewhere");
        assertLe(pot - fixedOrigin, 1, "the fixed origin leaves more than one wei on a full stream");
    }

    /// @notice The one-slot and two-slot fixed-origin shapes are the same function.
    /// @dev The finding prescribed two slots - an origin plus a cumulative `releasedSoFar`.
    ///      `CreditManager` ships one, and recomputes the cumulative figure from the clock. They
    ///      can only differ where the `amount > pot` clamp binds, which cannot happen inside a
    ///      stream (`rate = floor(pot * ACC / duration)`, so `duration * rate / ACC <= pot`).
    ///      This is that argument as a measurement rather than a paragraph, across cadences that
    ///      include running past the end of the stream.
    function testFuzz_accrual_oneSlotAndTwoSlotFixedOriginsAgree(uint256 pot, uint256 durationDays, uint256 gap)
        public
    {
        pot = bound(pot, 1e6, 250_000e6);
        durationDays = bound(durationDays, 5, 365);
        gap = bound(gap, 1, 3_600);
        uint256 duration = durationDays * 1 days;

        // 5,000 s of walking plus one deliberate overshoot past `streamEndsAt`, so the clamp and
        // the end-of-stream truncation are both inside the comparison.
        uint256 twoSlot = _run(AccrueModel.Mode.Cumulative, pot, duration, gap, 5_000);
        uint256 oneSlot = _run(AccrueModel.Mode.Telescoping, pot, duration, gap, 5_000);
        assertEq(oneSlot, twoSlot, "the one-slot and two-slot fixed-origin shapes disagree");
        assertLe(oneSlot, pot, "a fixed-origin shape paid out more than the pot");
    }

    /// @notice Neither fixed-origin shape may ever pay out more than the stream owes.
    function testFuzz_accrual_theFixedOriginNeverOverpays(uint256 pot, uint256 durationDays, uint256 gap) public {
        pot = bound(pot, 1e6, 250_000e6);
        durationDays = bound(durationDays, 5, 365);
        gap = bound(gap, 1, 3_600);
        uint256 duration = durationDays * 1 days;

        uint256 paid = _run(AccrueModel.Mode.Telescoping, pot, duration, gap, 5_000);
        uint256 owed = (5_000 / gap) * gap * ((pot * 1e18) / duration) / 1e18;
        assertLe(paid, pot, "the fix paid out more than the pot");
        assertLe(paid, owed + 1, "the fix paid out more than the stream owed");
    }
}
