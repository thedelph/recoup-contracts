// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 60, stream S3: the M-04 ceiling's curve, measured at whatever the constant says.
/// @notice The external reviewers (33audits, issue #51) answered the which-side question with a
///         harness of their own - two 10,000.000000 holders, a 1,000.000000 pot after a 180-day
///         gap - and a claim: the ceiling never changes what a timed staker TAKES, only how long
///         they wait, so the absolute capture is 499.999999 at every setting and only the
///         annualised rate moves. This file is that harness, reproduced in shape, with every
///         expectation DERIVED from `Config.MAX_YIELD_STREAM_DURATION` rather than typed, so it is
///         honest at 30 days (shipped), at 60, 90 or 120, and with no ceiling at all
///         (`type(uint256).max`). The per-setting figures were taken by building this file in a
///         scratch copy of `contracts/` per setting; the research note for 2026-09-14 holds the
///         table.
/// @dev What each test measures, in the order the reply needs them:
///        (a) two equal holders, one leaves at day 30: the leaver's and the stayer's share of the pot;
///        (b) a staker arriving one block before the flush, paying no tail, holding to the window's
///            end: captured and annualised, beside the honest incumbent's own annualised rate;
///        (c) the reviewers' 3,000.000000 newcomer: redeemable on arrival, and the day they are whole;
///        (e) the overlap case: a second epoch funded INSIDE the window. Rule 2 (never shorten a
///            running stream) gives the second epoch the first window's end, so the clamp does not
///            compound and the timed staker's take is the pro-rata half of each pot, at any setting.
///      `LenderPool.distributeYield` is reached directly as the harvester; `EpochHarvester.harvest`
///      would hold two epochs `Config.MIN_EPOCH_GAP` apart, which is the gap (e) uses.
contract R60S3_M04Curve is Test {
    address internal manager = makeAddr("manager");
    address internal harvester = makeAddr("harvester");
    address internal leaver = makeAddr("leaver");
    address internal stayer = makeAddr("stayer");
    address internal newcomer = makeAddr("newcomer");

    MockUSDC internal usdc;
    LenderPool internal pool;

    uint256 internal constant STAKE = 10_000e6;
    uint256 internal constant POT = 1_000e6;
    uint256 internal constant GAP = 180 days;
    uint256 internal constant LEAVE_AT = 30 days;
    uint256 internal constant NEWCOMER_STAKE = 3_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), address(this));
        pool.setCreditManager(manager);
        pool.setEpochHarvester(harvester);
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);

        emit log_named_uint("SETTING ceiling, days (0 = none)     ", _ceilingDays());
    }

    // -- helpers ---------------------------------------------------------------

    /// @dev `Config.MAX_YIELD_STREAM_DURATION` in days, or 0 when it is set so high it never binds.
    function _ceilingDays() internal pure returns (uint256) {
        return Config.MAX_YIELD_STREAM_DURATION > 3650 days ? 0 : Config.MAX_YIELD_STREAM_DURATION / 1 days;
    }

    /// @dev Rule 1 with its ceiling: `min(max(gap, YIELD_STREAM_DURATION), MAX_YIELD_STREAM_DURATION)`.
    function _windowFor(uint256 gap) internal pure returns (uint256) {
        uint256 w = gap > Config.YIELD_STREAM_DURATION ? gap : Config.YIELD_STREAM_DURATION;
        return w > Config.MAX_YIELD_STREAM_DURATION ? Config.MAX_YIELD_STREAM_DURATION : w;
    }

    /// @dev Annualised basis points of `gain` on `principal` over `span` seconds, floored.
    function _annualisedBps(uint256 gain, uint256 principal, uint256 span) internal pure returns (uint256) {
        return (gain * 10_000 * 365 days) / (principal * span);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        shares = pool.deposit(assets, who);
        vm.stopPrank();
    }

    function _flush(uint256 pot) internal {
        usdc.mint(harvester, pot);
        vm.startPrank(harvester);
        usdc.approve(address(pool), pot);
        pool.distributeYield(pot);
        vm.stopPrank();
    }

    function _exit(address who) internal returns (uint256) {
        uint256 shares = pool.balanceOf(who);
        vm.prank(who);
        return pool.redeem(shares, who, who);
    }

    // -- (a) two equal holders, one leaves at day 30 ----------------------------

    /// @notice The reviewers' scenario. What the leaver takes is half of what had RELEASED by day
    ///         30, `POT * min(30 days, window) / window / 2`; the stayer collects the rest. The
    ///         ceiling decides the window and therefore the split; the pot is exhausted either way.
    function test_R60S3_a_twoEqualHolders_oneLeavesAtDayThirty() public {
        _deposit(leaver, STAKE);
        _deposit(stayer, STAKE);

        skip(GAP);
        _flush(POT);
        uint256 window = pool.yieldStreamEndsAt() - block.timestamp;
        assertEq(window, _windowFor(GAP), "premise: the window is min(max(gap, D), MAX)");

        skip(LEAVE_AT);
        uint256 leaverShare = _exit(leaver) - STAKE;

        skip(700 days);
        uint256 stayerShare = _exit(stayer) - STAKE;

        uint256 releasedAtExit = LEAVE_AT >= window ? POT : (POT * LEAVE_AT) / window;

        emit log_named_uint("MEASURED (a) window, days             ", window / 1 days);
        emit log_named_uint("MEASURED (a) leaver pot share         ", leaverShare);
        emit log_named_uint("MEASURED (a) stayer pot share         ", stayerShare);
        emit log_named_uint("DERIVED  (a) released by day 30       ", releasedAtExit);

        assertApproxEqAbs(leaverShare, releasedAtExit / 2, 2, "the leaver takes half of what had released by day 30");
        assertApproxEqAbs(leaverShare + stayerShare, POT, 4, "the pot is exhausted between the two");
    }

    // -- (b) the timed staker: fixed take, moving lockup --------------------------

    /// @notice Rule 1's worry, executed. A staker arrives one block before the flush, pays no tail
    ///         (nothing is unreleased yet, so entry is at par), and holds to `yieldStreamEndsAt`.
    ///         Their take is the delivered cohort's pro-rata half of the pot AT EVERY SETTING; the
    ///         ceiling moves only the window they must hold for, and so only the annualised rate.
    ///         Printed beside it: the honest incumbent's own annualised rate on the same pot over
    ///         the gap plus the window, and the multiple between the two, which is `gap / window`.
    function test_R60S3_b_aStakerArrivingOneBlockBeforeTheFlush_takesHalfThePotAtEverySetting() public {
        _deposit(stayer, STAKE); // held throughout the outage
        skip(GAP);
        _deposit(leaver, STAKE); // one block before the flush
        _flush(POT);

        uint256 window = pool.yieldStreamEndsAt() - block.timestamp;
        assertEq(window, _windowFor(GAP), "premise: the window is min(max(gap, D), MAX)");

        skip(window);
        uint256 captured = _exit(leaver) - STAKE;
        uint256 stayerShare = _exit(stayer) - STAKE;

        uint256 timedBps = _annualisedBps(captured, STAKE, window);
        uint256 honestBps = _annualisedBps(stayerShare, STAKE, GAP + window);

        emit log_named_uint("MEASURED (b) window, days             ", window / 1 days);
        emit log_named_uint("MEASURED (b) captured                 ", captured);
        emit log_named_uint("MEASURED (b) annualised bps, timed    ", timedBps);
        emit log_named_uint("MEASURED (b) honest stayer's share    ", stayerShare);
        emit log_named_uint("MEASURED (b) annualised bps, honest   ", honestBps);
        emit log_named_uint("DERIVED  (b) gap / window, x100       ", (GAP * 100) / window);

        assertApproxEqAbs(
            captured, POT / 2, 2, "the timed staker's take is the cohort's pro-rata half, whatever the window"
        );
        assertApproxEqAbs(stayerShare, POT / 2, 2, "and so is the incumbent's");
        assertEq(
            timedBps,
            _annualisedBps(captured, STAKE, _windowFor(GAP)),
            "the rate is the take over the window and nothing else"
        );
    }

    // -- (c) the reviewers' newcomer ------------------------------------------------

    /// @notice A 3,000.000000 newcomer entering straight after the flush pays gross for the pot
    ///         (round 22 F10, deliberate) and is under water on arrival by the same amount at every
    ///         setting. They are whole at `yieldStreamEndsAt` and not the day before; the ceiling
    ///         is the day they are whole.
    function test_R60S3_c_theNewcomerIsUnderWaterOnArrivalAndWholeAtTheWindowsEnd() public {
        _deposit(leaver, STAKE);
        _deposit(stayer, STAKE);
        skip(GAP);
        _flush(POT);
        uint256 t0 = block.timestamp;
        uint256 window = pool.yieldStreamEndsAt() - t0;
        assertEq(window, _windowFor(GAP), "premise: the window is min(max(gap, D), MAX)");

        uint256 shares = _deposit(newcomer, NEWCOMER_STAKE);
        uint256 atOnce = pool.previewRedeem(shares);

        emit log_named_uint("MEASURED (c) window, days             ", window / 1 days);
        emit log_named_uint("MEASURED (c) paid                     ", NEWCOMER_STAKE);
        emit log_named_uint("MEASURED (c) redeemable on arrival    ", atOnce);
        emit log_named_uint("MEASURED (c) under water on arrival   ", NEWCOMER_STAKE - atOnce);

        uint256[5] memory checkpoints = [uint256(30 days), 60 days, 90 days, 120 days, 180 days];
        for (uint256 i = 0; i < checkpoints.length; i++) {
            vm.warp(t0 + checkpoints[i]);
            emit log_named_uint("MEASURED (c)   at day                 ", checkpoints[i] / 1 days);
            emit log_named_uint("MEASURED (c)   redeemable             ", pool.previewRedeem(shares));
        }

        vm.warp(t0 + window - 1 days);
        uint256 dayBefore = pool.previewRedeem(shares);
        vm.warp(t0 + window);
        uint256 atEnd = pool.previewRedeem(shares);

        emit log_named_uint("MEASURED (c) redeemable the day before", dayBefore);
        emit log_named_uint("MEASURED (c) redeemable at window end ", atEnd);
        emit log_named_uint("MEASURED (c) whole at day             ", window / 1 days);

        assertLt(atOnce, NEWCOMER_STAKE, "gross entry pricing: under water on arrival");
        assertLt(dayBefore + 100_000, NEWCOMER_STAKE, "not whole the day before the window ends");
        assertGe(atEnd + 2, NEWCOMER_STAKE, "whole, to the wei, once the window has run");
    }

    // -- (e) the overlap: a second epoch funded inside the window --------------------

    /// @notice Does the clamp compound? A second epoch lands `Config.MIN_EPOCH_GAP` into the first
    ///         window. Its own rule-1 window is the floor, the clamp is a no-op on it, and rule 2
    ///         (never shorten a running stream) hands it the first window's end. So the end date
    ///         does not move, the timed staker's hold is unchanged, and their take is the pro-rata
    ///         half of BOTH pots. What the ceiling changes here is how far an honest five-day epoch
    ///         is spread when it lands inside a stretched window: the remainder of the ceiling, not
    ///         the remainder of the gap.
    function test_R60S3_e_aSecondEpochInsideTheWindowDoesNotCompoundTheClamp() public {
        _deposit(stayer, STAKE);
        skip(GAP);
        _deposit(leaver, STAKE); // one block before the first flush
        _flush(POT);
        uint256 t0 = block.timestamp;
        uint256 endsAt1 = pool.yieldStreamEndsAt();
        assertEq(endsAt1 - t0, _windowFor(GAP), "premise: the first window is min(max(gap, D), MAX)");

        skip(Config.MIN_EPOCH_GAP);
        _flush(POT);
        uint256 endsAt2 = pool.yieldStreamEndsAt();
        uint256 secondSpread = endsAt2 - block.timestamp;

        vm.warp(endsAt2);
        uint256 captured = _exit(leaver) - STAKE;
        uint256 stayerShare = _exit(stayer) - STAKE;

        emit log_named_uint("MEASURED (e) first window, days       ", (endsAt1 - t0) / 1 days);
        emit log_named_uint("MEASURED (e) second epoch spread, days", secondSpread / 1 days);
        emit log_named_uint("MEASURED (e) end moved by, seconds    ", endsAt2 - endsAt1);
        emit log_named_uint("MEASURED (e) captured, two pots       ", captured);
        emit log_named_uint("MEASURED (e) annualised bps, timed    ", _annualisedBps(captured, STAKE, endsAt2 - t0));
        emit log_named_uint("MEASURED (e) honest stayer's share    ", stayerShare);

        assertEq(
            endsAt2, endsAt1, "rule 2: the second epoch inherits the first window's end, so the clamp does not compound"
        );
        assertEq(secondSpread, _windowFor(GAP) - Config.MIN_EPOCH_GAP, "the second epoch is spread over the remainder");
        assertApproxEqAbs(captured, POT, 3, "two pots, the timed staker's half of each, whatever the window");
        assertApproxEqAbs(stayerShare, POT, 3, "and the incumbent's half of each");
    }

    /// @notice The late overlap: a second epoch lands one day before the first window ends. Its own
    ///         rule-1 window (its accrual, `window - 1 day`) is longer than the one day remaining,
    ///         so the end MOVES, to the second flush plus its own window - which is what rule 1 is
    ///         for, and is not the clamp compounding: the end is never more than the ceiling past
    ///         the LATEST flush. The timed staker who arrived before the first flush must now hold
    ///         `2 * window - 1 day` to collect both halves, and collects exactly both halves.
    function test_R60S3_e_aLateSecondEpochMovesTheEndByItsOwnWindowAndNoFurther() public {
        _deposit(stayer, STAKE);
        skip(GAP);
        _deposit(leaver, STAKE); // one block before the first flush
        _flush(POT);
        uint256 t0 = block.timestamp;
        uint256 window = pool.yieldStreamEndsAt() - t0;

        skip(window - 1 days);
        _flush(POT);
        uint256 t1 = block.timestamp;
        uint256 endsAt2 = pool.yieldStreamEndsAt();

        vm.warp(endsAt2);
        uint256 captured = _exit(leaver) - STAKE;
        uint256 stayerShare = _exit(stayer) - STAKE;

        emit log_named_uint("MEASURED (e2) first window, days      ", window / 1 days);
        emit log_named_uint("MEASURED (e2) end past the 2nd flush, days", (endsAt2 - t1) / 1 days);
        emit log_named_uint("MEASURED (e2) total hold, days        ", (endsAt2 - t0) / 1 days);
        emit log_named_uint("MEASURED (e2) captured, two pots      ", captured);
        emit log_named_uint("MEASURED (e2) annualised bps, timed   ", _annualisedBps(captured, STAKE, endsAt2 - t0));
        emit log_named_uint("MEASURED (e2) honest stayer's share   ", stayerShare);

        assertEq(endsAt2, t1 + _windowFor(window - 1 days), "the end is the second flush plus its own rule-1 window");
        assertLe(endsAt2 - t1, Config.MAX_YIELD_STREAM_DURATION, "never more than the ceiling past the latest flush");
        assertApproxEqAbs(captured, POT, 3, "two pots, the timed staker's half of each, whatever the window");
        assertApproxEqAbs(stayerShare, POT, 3, "and the incumbent's half of each");
    }

    /// @notice The rule over every offset inside the window, as a property: a second flush at
    ///         offset `o` ends at `max(firstEnd, now + min(max(o, D), MAX))`. Rule 2 keeps the first
    ///         end when the second epoch's own window is shorter than the tail; rule 1 rates it
    ///         over its own accrual when it is longer; and nothing puts the end more than the
    ///         ceiling past the latest flush, so no sequence of flushes compounds the clamp.
    function testFuzz_R60S3_e_aFlushInsideTheWindowEndsAtTheLaterOfTheTwoWindows(uint32 seed) public {
        _deposit(stayer, STAKE);
        skip(GAP);
        _flush(POT);
        uint256 endsAt1 = pool.yieldStreamEndsAt();
        uint256 window = endsAt1 - block.timestamp;

        uint256 offset = bound(uint256(seed), 1, window - 1);
        skip(offset);
        _flush(POT);

        uint256 own = block.timestamp + _windowFor(offset);
        uint256 expected = own > endsAt1 ? own : endsAt1;
        assertEq(pool.yieldStreamEndsAt(), expected, "end != max(first end, now + min(max(o, D), MAX))");
        assertLe(
            pool.yieldStreamEndsAt() - block.timestamp,
            Config.MAX_YIELD_STREAM_DURATION,
            "the end sits more than the ceiling past the latest flush"
        );
    }
}
