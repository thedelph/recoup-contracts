// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 59, target 5: M-04's two sides. The ceiling SHIPPED, and this suite now reads it.
/// @notice A2 wrote this at `c9b5f95`, where there was no ceiling, and measured BOTH sides without
///         changing a byte of source: a pot of `P` rated over 30 days is the same stream whether the
///         30 came from a 30-day gap or from a 180-day gap clamped to 30, so the "with" arm was
///         reproduced by a 30-day gap and the "without" arm by a 180-day one.
///
/// @dev **What changed, and why the shape of this file had to.** Chris took the decision A2
///      recommended and `Config.MAX_YIELD_STREAM_DURATION = 30 days` now clamps `_rateStream`'s
///      epoch leg, so the 180-day arm rates over 30 days too and the "without" arm is no longer
///      reachable from source. Three of the five tests asserted the two arms DIFFER and went red on
///      exactly that (`the uncapped window is not the gap: 2592000 != 15552000`), which is the
///      ceiling working. So the arm EXECUTED here is now the shipped one, on the reviewers' own
///      180-day fixture, and the no-ceiling figures are retained below as named constants.
///
///      **Every retained figure was MEASURED, not derived.** A2 measured them at `c9b5f95`; they
///      were re-measured on 2026-09-12 at `7f54acc` plus this branch's two commits with the clamp
///      alone reverted (`git checkout 7f54acc -- contracts/src/LenderPool.sol`, then `forge test
///      --force`), where this suite passed 5 of 5 and printed each one to the wei. The capped
///      figures below are executed on every run.
contract R59A02_M04WhichSide is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("creditManager");
    address internal harvester = makeAddr("epochHarvester");

    address internal incumbentA = makeAddr("incumbentA");
    address internal incumbentB = makeAddr("incumbentB");
    address internal newcomer = makeAddr("newcomer");
    address internal jit = makeAddr("justInTime");

    uint256 internal constant POT = 1_000e6;
    uint256 internal constant DROUGHT = 180 days;
    uint256 internal constant CEILING = 30 days;

    // -- the no-ceiling column, MEASURED at the uncapped tree, not derived -----
    //
    // Reverting the clamp and nothing else reproduces each of these exactly. They are the reason
    // this file can still state a trade now that only one side of it executes, and a reader who
    // wants them again reverts the clamp and runs this suite, which is two commands and two seconds.
    uint256 internal constant UNCAPPED_WINDOW = DROUGHT; // 15,552,000 s against the ceiling's 2,592,000
    uint256 internal constant UNCAPPED_LEAVER_AT_30 = 583_333332; // of which 83.333332 is yield
    uint256 internal constant UNCAPPED_STAYERS_BOOK = 583_333333;
    uint256 internal constant UNCAPPED_NEWCOMER_AT_30 = 2_499_999999; // whole only at day 210
    uint256 internal constant UNCAPPED_JIT_AT_30 = 1_083_333332; // 83.333332 of profit on 1,000.000000
    uint256 internal constant UNCAPPED_SAME_BLOCK_EXIT = 1_000_000000; // no profit, either way

    function setUp() public {
        // PREMISE for every pinned figure in this file: they are the arithmetic of a 30-day ceiling,
        // so a retune of the constant must fail here loudly rather than silently re-rate them. The
        // relationships survive a retune; the literals do not.
        assertEq(Config.MAX_YIELD_STREAM_DURATION, CEILING, "the shipped ceiling moved: re-measure this file");

        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        pool.setCreditManager(manager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();
        usdc.mint(harvester, 10_000_000e6);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        shares = pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _flush(uint256 amount) internal {
        vm.prank(harvester);
        pool.distributeYield(amount);
    }

    function _exit(address who) internal returns (uint256 paid) {
        uint256 shares = pool.maxRedeem(who);
        vm.prank(who);
        paid = pool.redeem(shares, who, who);
    }

    // -------------------------------------------------------------------------
    // Side one: what the uncapped window cost an honest holder and a newcomer
    // -------------------------------------------------------------------------

    /// @notice Two equal holders through a 180-day drought, one epoch flushed, one of them leaves at
    ///         day 30. EXECUTED under the shipped ceiling; the uncapped column is the constant.
    function test_R59A02_M04_whatAnIncumbentLeavingAtDayThirtyTakes() public {
        _deposit(incumbentA, 500e6);
        _deposit(incumbentB, 500e6);
        skip(DROUGHT);
        _flush(POT);
        uint256 window = pool.yieldStreamEndsAt() - block.timestamp;

        skip(CEILING);
        uint256 take = _exit(incumbentA);
        uint256 stayersBook = pool.previewRedeem(pool.balanceOf(incumbentB));

        emit log_named_uint("MEASURED window, SHIPPED, s              ", window);
        emit log_named_uint("MEASURED window, no ceiling, s           ", UNCAPPED_WINDOW);
        emit log_named_uint("MEASURED leaver at day 30, SHIPPED       ", take);
        emit log_named_uint("MEASURED leaver at day 30, no ceiling    ", UNCAPPED_LEAVER_AT_30);
        emit log_named_uint("MEASURED stayer's book after, SHIPPED    ", stayersBook);
        emit log_named_uint("MEASURED stayer's book after, no ceiling ", UNCAPPED_STAYERS_BOOK);
        emit log_named_uint("MEASURED the leaver's gain from ceiling  ", take - UNCAPPED_LEAVER_AT_30);

        assertEq(window, CEILING, "a 180-day gap is no longer rated over 180 days");
        assertEq(take, 999_999999, "the leaver's take under the ceiling moved");
        assertEq(stayersBook, 1_000_000000, "the stayer's book under the ceiling moved");
        assertGt(take, UNCAPPED_LEAVER_AT_30, "the ceiling pays the day-30 leaver more, which is the trade");
        assertEq(take - UNCAPPED_LEAVER_AT_30, 416_666667, "the size of the transfer the ceiling makes");
    }

    /// @notice The reviewers' own case: a newcomer entering straight after the flush pays gross for
    ///         the whole pot and is under water on arrival by the same amount under either window.
    ///         What the window decides is how long they stay under water - 30 days now, 210 before.
    function test_R59A02_M04_theNewcomerIsUnderWaterForTheWholeWindow() public {
        _deposit(incumbentA, 500e6);
        _deposit(incumbentB, 500e6);
        skip(DROUGHT);
        _flush(POT);

        uint256 paid = 3_000e6;
        uint256 shares = _deposit(newcomer, paid);
        uint256 atOnce = pool.previewRedeem(shares);

        skip(CEILING);
        uint256 at30 = pool.previewRedeem(pool.balanceOf(newcomer));

        emit log_named_uint("MEASURED newcomer paid                   ", paid);
        emit log_named_uint("MEASURED redeemable at once              ", atOnce);
        emit log_named_uint("MEASURED under water on arrival, bps     ", ((paid - atOnce) * Config.BPS) / paid);
        emit log_named_uint("MEASURED redeemable at day 30, SHIPPED   ", at30);
        emit log_named_uint("MEASURED redeemable at day 30, no ceiling", UNCAPPED_NEWCOMER_AT_30);
        emit log_named_uint("MEASURED days under water, SHIPPED       ", CEILING / 1 days);
        emit log_named_uint("MEASURED days under water, no ceiling    ", (DROUGHT + CEILING) / 1 days);

        assertEq(atOnce, 2_400_000000, "entry pricing is unchanged: the newcomer still pays gross");
        assertEq(((paid - atOnce) * Config.BPS) / paid, 2_000, "2,000 bps under water on arrival, either way");
        assertEq(at30, 2_999_999999, "the newcomer is whole at day 30 under the ceiling");
        assertGt(at30, UNCAPPED_NEWCOMER_AT_30, "the ceiling did not shorten the newcomer's hole");
        assertGe(at30 + 1, paid, "and whole means whole, to the wei");
    }

    // -------------------------------------------------------------------------
    // Side two: what the ceiling costs, the mirror case it opens
    // -------------------------------------------------------------------------

    /// @notice THE PRICE OF THE CEILING, executed rather than argued. `flushLenderYield` is
    ///         permissionless, so a depositor can pick the block: enter immediately BEFORE the
    ///         flush, pay nothing for a pot that does not exist yet, then hold for the window and
    ///         take a pro-rata slice of an epoch accrued over 180 days. The ceiling shortens the
    ///         hold that grind needs from 180 days to 30, and pays it 416.666667 more at day 30.
    function test_R59A02_M04_theCeilingShortensTheJustInTimeGrindsRequiredHold() public {
        _deposit(incumbentA, 1_000e6);
        skip(DROUGHT);
        uint256 jitPaid = 1_000e6;
        _deposit(jit, jitPaid); // in the block before the flush
        _flush(POT);

        skip(CEILING);
        uint256 out = _exit(jit);

        emit log_named_uint("MEASURED JIT paid                        ", jitPaid);
        emit log_named_uint("MEASURED JIT out at day 30, SHIPPED      ", out);
        emit log_named_uint("MEASURED JIT out at day 30, no ceiling   ", UNCAPPED_JIT_AT_30);
        emit log_named_uint("MEASURED JIT profit at day 30, SHIPPED   ", out - jitPaid);
        emit log_named_uint("MEASURED JIT profit at day 30, no ceiling", UNCAPPED_JIT_AT_30 - jitPaid);
        emit log_named_uint("MEASURED days of capital the grind needs ", CEILING / 1 days);

        assertEq(out, 1_499_999999, "the grinder's take at day 30 under the ceiling moved");
        assertGt(out, UNCAPPED_JIT_AT_30, "the ceiling did not accelerate the grind");
        assertEq(out - UNCAPPED_JIT_AT_30, 416_666667, "the same transfer, seen from the other side");
    }

    /// @notice SAME-BLOCK capture is defeated under BOTH windows, which is the half the trade does
    ///         not touch: the `YIELD_STREAM_DURATION` floor is what stops it, not the gap length.
    ///         Both gap lengths executed under the shipped clamp; the uncapped column was measured
    ///         identical (1,000.000000 out of 1,000.000000 in, no profit).
    function test_R59A02_M04_sameBlockCaptureIsDefeatedEitherWay() public {
        uint256 clean = vm.snapshotState();

        _deposit(incumbentA, 1_000e6);
        skip(DROUGHT);
        _deposit(jit, 1_000e6);
        _flush(POT);
        uint256 afterDrought = _exit(jit);

        vm.revertToState(clean);
        _deposit(incumbentA, 1_000e6);
        skip(CEILING);
        _deposit(jit, 1_000e6);
        _flush(POT);
        uint256 afterCeilingGap = _exit(jit);

        emit log_named_uint("MEASURED same-block exit, 180-day gap    ", afterDrought);
        emit log_named_uint("MEASURED same-block exit, 30-day gap     ", afterCeilingGap);
        emit log_named_uint("MEASURED same-block exit, no ceiling     ", UNCAPPED_SAME_BLOCK_EXIT);

        assertLe(afterDrought, 1_000e6, "same-block capture paid a profit after a long gap");
        assertLe(afterCeilingGap, 1_000e6, "same-block capture paid a profit after a ceiling-length gap");
        assertEq(afterDrought, UNCAPPED_SAME_BLOCK_EXIT, "the ceiling moved the same-block case after all");
    }

    /// @notice What the ceiling actually bounds. The pool seeds `lastYieldDistributeAt` in its
    ///         constructor, so the FIRST epoch after wiring is rated over the whole pre-wiring gap:
    ///         before the ceiling, 1/30/90/180/365-day gaps gave 5/30/90/180/365-day windows and the
    ///         only bound was the pool's own age. EXECUTED at the same five gaps under the ceiling,
    ///         where they give 5/30/30/30/30, and the ordinary five-day epoch is untouched.
    function test_R59A02_M04_theWindowIsNowBoundedByTheCeilingNotThePoolsAge() public {
        uint256[5] memory gaps = [uint256(1 days), 30 days, 90 days, 180 days, 365 days];
        // MEASURED at the uncapped tree, in days, against those same five gaps.
        uint256[5] memory uncappedDays = [uint256(5), 30, 90, 180, 365];

        for (uint256 i = 0; i < gaps.length; i++) {
            uint256 clean = vm.snapshotState();
            _deposit(incumbentA, 1_000e6);
            skip(gaps[i]);
            _flush(POT);
            uint256 window = pool.yieldStreamEndsAt() - block.timestamp;

            emit log_named_uint("MEASURED gap, days                       ", gaps[i] / 1 days);
            emit log_named_uint("MEASURED   window now, days               ", window / 1 days);
            emit log_named_uint("MEASURED   window before the ceiling, days", uncappedDays[i]);

            uint256 expected = gaps[i] > Config.YIELD_STREAM_DURATION ? gaps[i] : Config.YIELD_STREAM_DURATION;
            if (expected > Config.MAX_YIELD_STREAM_DURATION) expected = Config.MAX_YIELD_STREAM_DURATION;
            assertEq(window, expected, "window != min(max(gap, D), MAX)");
            assertLe(window, uncappedDays[i] * 1 days, "the ceiling lengthened a window");
            vm.revertToState(clean);
        }

        // And the floor holds under the ceiling's own value: an ordinary five-day epoch never meets
        // a 30-day cap, so nothing about normal operation moved.
        uint256 clean2 = vm.snapshotState();
        _deposit(incumbentA, 1_000e6);
        skip(Config.MIN_EPOCH_GAP);
        _flush(POT);
        emit log_named_uint(
            "MEASURED ordinary 5-day epoch window, days", (pool.yieldStreamEndsAt() - block.timestamp) / 1 days
        );
        assertEq(pool.yieldStreamEndsAt() - block.timestamp, Config.YIELD_STREAM_DURATION, "the floor moved");
        vm.revertToState(clean2);
    }
}
