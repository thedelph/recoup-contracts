// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice The clock `LenderPool._rateStream` rates a pot over, and the price of moving it.
///
///         Audit round 23 filed four findings against one fact: `_rateStream`'s rule 1 reads
///         `lastYieldDistributeAt`, which only a delivered epoch advances, and the two non-epoch
///         legs read it anyway. Round-22 finding 11 (a recovery rated over a 180-day epoch
///         drought), round-23 finding 14 (the same stretch deciding how long a fresh depositor
///         sits at the #247 entry discount), round-22 finding 6a (every re-rate lengthens the
///         tail) and round-23 finding 2, the Med/High (one asset-wei, permissionlessly, sixteen
///         times in a block) are the same sentence read four ways.
///
///         The fix is two halves and they are tested as two halves, because they fail
///         independently:
///
///           1a. a non-epoch arrival is rated over `YIELD_STREAM_DURATION`, not over a clock that
///               describes somebody else's money;
///           1b. the window may only be pushed past where the stream already ends as far as the
///               arriving money funds at the rate already running.
///
///         Half 1a alone still lets a wei reset the window to a fresh five days, so the tail
///         decays `exp(-t/D)` under repeated pokes - finding 6a exactly. Half 1b alone would leave
///         the drought.
///
///         **Three neuters, MEASURED, so that "these tests have teeth" is a number and not a
///         claim.** Each is this file, unchanged, against one changed thing:
///
///           A. `LenderPool.sol` reverted to `ff7c5b5`, the shipped rule: **12 of 21 fail**,
///              including the F6a re-derivation at 191,773,152 withheld and both droughts at
///              15,552,000 seconds.
///           B. half 1b replaced by round 23's refuted candidate,
///              `if (remaining != 0) duration = remaining`: **3 of 21 fail** - it rates the late
///              400.000000 recovery over 3,600 seconds, which is round 23's own refutation figure
///              reproduced, and pushes the release rate to 4.2x the ceiling.
///           C. half 1b deleted and half 1a kept: **7 of 21 fail**, F6a among them at the same
///              191,773,152. Half 1a fixes the drought and does nothing at all for the dust lever,
///              which is why there are two halves.
///
///         Fixture note: `creditManager` and `epochHarvester` are plain EOAs, as in
///         `LenderPool.t.sol`. Nothing in `LenderPool` calls back into either, so pranking them
///         reproduces the pool-side effect of every upstream caller exactly. That the non-epoch
///         legs are permissionlessly reachable is established elsewhere - round 23 drove them from
///         an address holding no role, through `LiquidationAuction.workoutSettleAfterClose`.
contract YieldStreamClockTest is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal creditManager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DEPOSIT = 10_000e6;
    uint256 internal constant EPOCH = 550e6;

    /// @dev Mirrors `LenderPool.ACC_PRECISION`, which is private. Only the two-sided bound test
    ///      needs it, and it would break loudly rather than silently if it ever diverged: the
    ///      funded window it computes would stop matching the contract's by orders of magnitude.
    uint256 internal constant ACC_PRECISION = 1e18;

    function setUp() public {
        // A non-zero start, so the constructor's `lastYieldDistributeAt` stamp is not block zero
        // and none of the arithmetic below is accidentally testing the genesis edge.
        vm.warp(1_800_000_000);

        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();

        for (uint256 i = 0; i < 2; i++) {
            address who = [alice, bob][i];
            usdc.mint(who, 1_000_000e6);
            vm.prank(who);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    // -- fixture helpers ------------------------------------------------------

    function _deposit(address who, uint256 assets) internal returns (uint256) {
        vm.prank(who);
        return pool.deposit(assets, who);
    }

    /// @dev The epoch leg: the only caller that owns the accrual clock.
    function _epoch(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(pool), amount);
        pool.distributeYield(amount);
        vm.stopPrank();
    }

    /// @dev The pool-side effect of `LiquidationAuction.workoutSettleAfterClose` ->
    ///      `CreditManager.recoverWrittenDownLoss` -> `LenderPool.recoverLoss`.
    function _recover(uint256 amount) internal {
        usdc.mint(creditManager, amount);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.recoverLoss(amount);
        vm.stopPrank();
    }

    /// @dev The pool-side effect of `CreditManager.settlePrincipal` / `flushPrincipalTo`. With
    ///      nothing lent, the whole repayment is surplus and takes the streaming branch.
    function _repaySurplus(uint256 amount) internal {
        usdc.mint(creditManager, amount);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.repayPrincipal(amount);
        vm.stopPrank();
    }

    function _window() internal view returns (uint256) {
        uint256 endsAt = pool.yieldStreamEndsAt();
        return endsAt > block.timestamp ? endsAt - block.timestamp : 0;
    }

    // -- half 1a: the non-epoch legs stop reading the epoch clock -------------

    /// @notice TEETH. Round-22 finding 11, and the driver of round-23 finding 14. No epoch has ever
    ///         been delivered, which is the state the deployed pool is in today, so
    ///         `lastYieldDistributeAt` is still the constructor stamp and rule 1 rated a recovery
    ///         over the whole drought.
    /// @dev MEASURED before the fix: 15,552,000 seconds. After: 432,000.
    function test_clock_aRecoveryIsNotRatedOverTheEpochDrought() public {
        _deposit(alice, DEPOSIT);
        skip(180 days);

        _recover(400e6);

        assertEq(_window(), Config.YIELD_STREAM_DURATION, "a recovery is rated over its own floor");
        assertEq(pool.lastYieldDistributeAt(), 1_800_000_000, "and does not touch the accrual clock");
    }

    /// @notice TEETH. The same on the other non-epoch leg, which is the one the `flushPrincipalTo`
    ///         routing arrives on.
    function test_clock_aPrincipalSurplusIsNotRatedOverTheEpochDrought() public {
        _deposit(alice, DEPOSIT);
        skip(180 days);

        _repaySurplus(400e6);

        assertEq(_window(), Config.YIELD_STREAM_DURATION, "a surplus is rated over its own floor");
    }

    /// @notice TEETH. Round-23 finding 14 as the depositor feels it: #247 makes an entrant pay for
    ///         the whole live tail, and rule 1 decided how long they had to wait to get it back.
    ///         Leaving during the stretch forfeited it permanently.
    /// @dev MEASURED before the fix: 8.10% of a 1,000.000000 entry, against a free control.
    function test_clock_anExiterIsNotStrandedByADroughtRatedRecovery() public {
        _deposit(alice, DEPOSIT);
        skip(180 days);
        _recover(1_000e6);

        uint256 shares = _deposit(bob, 1_000e6);
        skip(Config.YIELD_STREAM_DURATION);

        uint256 balanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pool.redeem(shares, bob, bob);
        uint256 realised = usdc.balanceOf(bob) - balanceBefore;

        emit log_named_uint("bob paid", 1_000e6);
        emit log_named_uint("bob realised on a five-day exit", realised);
        assertGe(realised, 1_000e6 - 1_000, "a five-day exit is near-free once the drought is gone");
    }

    /// @notice GUARD, not teeth. The epoch leg keeps rule 1, deliberately: `EpochHarvester.harvest`
    ///         holds it `Config.MIN_EPOCH_GAP` apart and the clock really is the accrual window of
    ///         the money being rated. This is round-11's anti-just-in-time pin, and the fix must
    ///         not have taken it out with the rest.
    function test_clock_signCheck_theEpochLegStillRatesOverItsOwnAccrualWindow() public {
        _deposit(alice, DEPOSIT);
        skip(60 days);

        _epoch(EPOCH);

        assertEq(_window(), 60 days, "the epoch leg still rates over the window it accrued across");
        assertEq(pool.lastYieldDistributeAt(), block.timestamp, "and it still owns the clock");
    }

    /// @notice GUARD. Rule 2 is unchanged and still absolute: a later arrival on either leg can
    ///         never bring a running stream's end date forward.
    function test_clock_signCheck_ruleTwoStillRefusesToShortenARunningStream() public {
        _deposit(alice, DEPOSIT);
        skip(60 days);
        _epoch(EPOCH);
        uint256 endsAt = pool.yieldStreamEndsAt();

        skip(Config.YIELD_STREAM_DURATION);
        _epoch(EPOCH);
        assertEq(pool.yieldStreamEndsAt(), endsAt, "a second epoch keeps the first tail's window");

        _recover(1);
        assertEq(pool.yieldStreamEndsAt(), endsAt, "and so does a recovery");

        _repaySurplus(1);
        assertEq(pool.yieldStreamEndsAt(), endsAt, "and so does a principal surplus");
    }

    // -- half 1b: the extension has to be paid for ----------------------------

    /// @notice TEETH. Round-23 finding 2 in one call: a wei of USDC moved the stream terms.
    function test_clock_oneWeiCannotMoveTheStreamTerms() public {
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(2 days);

        uint256 endsAt = pool.yieldStreamEndsAt();
        uint256 rate = pool.yieldRate();

        _recover(1);

        assertEq(pool.yieldStreamEndsAt(), endsAt, "one wei must not extend the stream");
        assertGe(pool.yieldRate(), rate, "and must not slow the payout");
    }

    /// @notice TEETH. Sixteen re-rates still fit in one block and there is still no cooldown; what
    ///         the fix removes is the reason to want one. All sixteen are accepted, none moves the
    ///         end date, and the pot grows by exactly what was paid in.
    function test_clock_sixteenReRatesInOneBlockCannotHoldTheTailBack() public {
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(1 days);

        uint256 endsAt = pool.yieldStreamEndsAt();
        uint256 pot = pool.unreleasedYield();
        uint256 t = block.timestamp;

        for (uint256 i = 0; i < 16; i++) {
            _recover(1);
        }

        assertEq(block.timestamp, t, "all sixteen landed in the same block");
        assertEq(pool.yieldStreamEndsAt(), endsAt, "and none of them moved the end date");
        assertEq(pool.unreleasedYield(), pot + 16, "the pot grew by the sixteen wei and nothing else");
    }

    /// @notice TEETH. Round-22 finding 6a, re-derived. Ten one-wei re-rates at twelve hours sent
    ///         191.773143 of a 550.000000 pot past the end of its own window, matching `0.9^10` to
    ///         eight figures. The pot must be delivered on the schedule it was rated with.
    function test_clock_tenDustReRatesAtTwelveHoursDeliverTheWholePot() public {
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);

        for (uint256 i = 0; i < 10; i++) {
            skip(12 hours);
            _recover(1);
        }

        // Five days of wall clock: the whole window. Only the last poke's own wei may survive it,
        // because that one landed exactly on the end date and cold-started a stream of its own.
        emit log_named_uint("withheld at t=D after ten dust re-rates", pool.unreleasedYield());
        assertLe(pool.unreleasedYield(), 10, "the pot reached the book on its own schedule");
        assertGe(pool.totalAssets(), DEPOSIT + EPOCH, "and the cohort is not short of its epoch");
    }

    /// @notice TEETH. Thirty days of hourly one-wei calls against a control that does nothing. The
    ///         separation measured before the fix was 129x in the attacker's favour; the sign is
    ///         now the other way, because the only thing a poke does is donate its own wei.
    function test_clock_thirtyDaysOfHourlyDustLeavesTheCohortBetterOff() public {
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        uint256 snap = vm.snapshotState();

        skip(30 days);
        uint256 controlBook = pool.totalAssets();
        uint256 controlWithheld = pool.unreleasedYield();
        vm.revertToState(snap);

        for (uint256 i = 0; i < 24 * 30; i++) {
            skip(1 hours);
            _recover(1);
        }

        emit log_named_uint("CONTROL withheld after 30 days", controlWithheld);
        emit log_named_uint("ATTACK  withheld after 30 days", pool.unreleasedYield());
        emit log_named_uint("CONTROL totalAssets", controlBook);
        emit log_named_uint("ATTACK  totalAssets", pool.totalAssets());

        assertEq(controlWithheld, 0, "CONTROL: the epoch landed in full");
        assertGe(pool.totalAssets(), controlBook, "720 wei of spam cannot cost the cohort a wei");
    }

    /// @notice TEETH, as a law rather than a schedule. A non-epoch arrival may never reduce the
    ///         release rate: one wei buys one wei's worth of extension, so holding the tail back
    ///         means funding it at the speed it was already running.
    function testFuzz_clock_aNonEpochArrivalNeverReducesTheReleaseRate(uint96 amount, uint32 offset) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        offset = uint32(bound(offset, 1, uint32(Config.YIELD_STREAM_DURATION) - 1));

        // A CURRENT epoch clock, deliberately. With a stale one the epoch's own window is longer
        // than the floor, rule 2 alone holds the end date, and the shipped rule passes this test
        // for a reason that has nothing to do with the property - which is what the first version
        // of this fixture measured. `remaining < D` at the arrival is what makes it discriminate.
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(offset);

        uint256 rate = pool.yieldRate();
        uint256 endsAt = pool.yieldStreamEndsAt();

        _recover(amount);

        assertGe(pool.yieldRate(), rate, "a non-epoch arrival must never slow the payout");
        assertGe(pool.yieldStreamEndsAt(), endsAt, "and rule 2 still forbids shortening");
    }

    /// @notice TEETH. The artifact bound: a non-epoch arrival can never leave the pot ending more
    ///         than one `YIELD_STREAM_DURATION` from now, or later than it already ended. Before
    ///         the fix the end date grew with `block.timestamp - lastYieldDistributeAt`, unbounded.
    function testFuzz_clock_aNonEpochArrivalNeverPushesTheEndPastTheFloor(uint96 amount, uint32 drought) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        drought = uint32(bound(drought, 0, 400 days));

        _deposit(alice, DEPOSIT);
        skip(drought);

        uint256 endsAtBefore = pool.yieldStreamEndsAt();
        _recover(amount);

        uint256 ceiling = block.timestamp + Config.YIELD_STREAM_DURATION;
        if (endsAtBefore > ceiling) ceiling = endsAtBefore;
        assertLe(pool.yieldStreamEndsAt(), ceiling, "the window is the floor, or the running tail");
    }

    /// @notice The design law, both directions, on one call. The chosen window is never longer than
    ///         the anti-compression floor and never shorter than what the arrival funds.
    /// @dev The upper bound has teeth against the shipped rule, which used the epoch clock. The
    ///      lower bound has teeth against round 23's refuted candidate
    ///      (`if (!isEpoch && remaining != 0) duration = remaining`), which ignores what the
    ///      arrival is worth and hands a large late recovery whatever seconds are left.
    function testFuzz_clock_theWindowIsBoundedBothWays(uint96 amount, uint32 offset) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        offset = uint32(bound(offset, 1, uint32(Config.YIELD_STREAM_DURATION) - 1));

        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(offset);

        uint256 remaining = _window();
        uint256 rate = pool.yieldRate();
        uint256 pot = pool.unreleasedYield() + amount;

        _recover(amount);
        uint256 chosen = _window();

        uint256 upper = remaining > Config.YIELD_STREAM_DURATION ? remaining : Config.YIELD_STREAM_DURATION;
        assertLe(chosen, upper, "never longer than the anti-compression floor");

        uint256 funded = (pot * ACC_PRECISION) / rate;
        uint256 lower = funded < Config.YIELD_STREAM_DURATION ? funded : Config.YIELD_STREAM_DURATION;
        if (lower < remaining) lower = remaining;
        assertGe(chosen, lower, "never shorter than the arrival funds at the running rate");
    }

    /// @notice SIGN CHECK on half 1b, and the residual it buys with, stated as a number rather than
    ///         as a claim. Round 23's refuted one-liner
    ///         (`if (!isEpoch && remaining != 0) duration = remaining`) rated a 400.000000 recovery
    ///         over the 3,600 seconds that happened to be left, and was thrown out for it. This
    ///         rule does not do that - but nor does it give the arrival the whole five-day floor.
    ///         It gives it what the arrival funds at the speed already running.
    /// @dev MEASURED: 317,781 seconds, against 3,600 for the refuted clause and 432,000 for the
    ///      floor on its own. **This is the one place the fix is deliberately shorter than the
    ///      floor, and it is not free.** What half 1b preserves is the payout RATE and not the
    ///      window, and the rate is the unit just-in-time capture is actually measured in: a
    ///      sandwicher's take is their share times the rate times the blocks they hold.
    ///      `testFuzz_clock_theReleaseRateIsBoundedBothWays` states that bound in general and
    ///      `test_clock_signCheck_aSandwichAroundTheCompressedWindow` prices this exact case. The
    ///      figure is pinned here so a future edit has to argue with it rather than rediscover it.
    function test_clock_signCheck_aLargeLateArrivalIsNotDumpedIntoTheHourThatIsLeft() public {
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(Config.YIELD_STREAM_DURATION - 1 hours);

        assertEq(_window(), 1 hours, "fixture: one hour left on the stream");
        uint256 rate = pool.yieldRate();
        uint256 pot = pool.unreleasedYield() + 400e6;

        _recover(400e6);

        emit log_named_uint("seconds a 400.000000 recovery is streamed over", _window());
        assertEq(_window(), (pot * ACC_PRECISION) / rate, "the window is what the arrival funds");
        assertGt(_window(), 87 hours, "and it is nothing like the hour the refuted clause gave it");
        assertLt(_window(), Config.YIELD_STREAM_DURATION, "shorter than the floor: the residual, named");
    }

    /// @notice The residual above, priced, and the assertion this test carries is NOT the one it
    ///         started with. An entrant present at a delivery shares that delivery pro rata: that is
    ///         the design, measured by round 23 as its own negative
    ///         (`enteringBeforeOrAfterADeliveryIsWorthTheSame` asserts a strict gain, bounded by the
    ///         pro-rata slice). Asserting a sandwicher cannot beat a later entrant would therefore
    ///         have been asserting something false about the shipped contract, and it failed for
    ///         exactly that reason before it was corrected. **MEASURED: 100,361.827227 out against
    ///         100,000.000000, on 100,000.000000 of a 110,000.000000 pool taking its 90.9% of a
    ///         400.000000 recovery.**
    /// @dev What the window rule can change is not that total but how FAST it is taken, so that is
    ///      what is bounded here: over any holding period a sandwicher takes no more than their
    ///      share of what the stream released while they were in. Compose that with
    ///      `testFuzz_clock_theReleaseRateIsBoundedBothWays` and the compression cannot buy an
    ///      attacker anything the pool was not already paying out at.
    function test_clock_signCheck_aSandwichIsBoundedByWhatTheStreamReleasesWhileItIsIn() public {
        vm.prank(admin);
        pool.setDepositCap(250_000e6);
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(Config.YIELD_STREAM_DURATION - 1 hours);

        uint256 snap = vm.snapshotState();

        // The whole-window sandwich, for the total. In one block before the recovery, out at the
        // end of the compressed window.
        uint256 shares = _deposit(bob, 100_000e6);
        _recover(400e6);
        skip(_window());
        uint256 balanceBefore = usdc.balanceOf(bob);
        uint256 slice = (400e6 * shares) / pool.totalSupply();
        vm.prank(bob);
        pool.redeem(shares, bob, bob);
        uint256 sandwich = usdc.balanceOf(bob) - balanceBefore;

        emit log_named_uint("whole-window sandwich, out", sandwich);
        emit log_named_uint("their pro-rata slice of the recovery", slice);
        // Stated without a subtraction: on the shipped rule the same sandwich comes out BELOW what
        // it put in, and `sandwich - 100_000e6` underflows rather than reporting it.
        assertLe(sandwich, 100_000e6 + slice, "the total is bounded by the pro-rata slice, as designed");

        vm.revertToState(snap);

        // The part the window rule governs: one hour of holding, and what it yields.
        shares = _deposit(bob, 100_000e6);
        _recover(400e6);
        uint256 withheldIn = pool.unreleasedYield();
        skip(1 hours);
        uint256 releasedWhileIn = withheldIn - pool.unreleasedYield();
        uint256 shareOfRelease = (releasedWhileIn * shares) / pool.totalSupply();

        balanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pool.redeem(shares, bob, bob);
        uint256 hourly = usdc.balanceOf(bob) - balanceBefore;

        emit log_named_uint("one-hour sandwich, out", hourly);
        emit log_named_uint("their share of what the stream released in that hour", shareOfRelease);
        assertLe(hourly, 100_000e6 + shareOfRelease + 1, "a sandwich takes only its share of the release");
    }

    /// @notice TEETH on half 1b in its own units. The release rate after a non-epoch arrival is
    ///         never below the rate already running - that is what stops a poke holding the tail
    ///         back - and never above the greater of that rate and the whole pot over a full floor,
    ///         which is what stops the compression above turning into a capture window.
    /// @dev The upper bound carries a factor of two for one rounding edge and nothing else: when
    ///      the funded window floors to a single second the pot is paid in that second, and
    ///      `pot * ACC / 1` can be up to twice the rate that produced a funded window of 1. That
    ///      needs `remaining <= 1` and an arrival smaller than one second of the running rate.
    function testFuzz_clock_theReleaseRateIsBoundedBothWays(uint96 amount, uint32 offset) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        offset = uint32(bound(offset, 1, uint32(Config.YIELD_STREAM_DURATION) - 1));

        // A current epoch clock, for the reason given on the sibling above: `remaining < D` at the
        // moment of arrival is the only state in which this property can be violated.
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(offset);

        uint256 rate = pool.yieldRate();
        uint256 pot = pool.unreleasedYield() + amount;

        _recover(amount);

        assertGe(pool.yieldRate(), rate, "the payout may never slow");
        uint256 floorRate = (pot * ACC_PRECISION) / Config.YIELD_STREAM_DURATION;
        uint256 ceiling = 2 * rate > floorRate ? 2 * rate : floorRate;
        assertLe(pool.yieldRate(), ceiling, "and may never exceed what was already sanctioned");
    }

    /// @notice TEETH, though only by a second, and the second is the point. With nothing running
    ///         there is no rate to preserve and the arrival takes the floor. The shipped rule gave
    ///         it 432,001 seconds here rather than 432,000, because even a cold arrival was rated
    ///         over `now - lastYieldDistributeAt`. One second on this fixture; a drought on a real
    ///         one, which is the sibling test above.
    function test_clock_signCheck_aColdNonEpochArrivalGetsTheFullFloor() public {
        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(Config.YIELD_STREAM_DURATION + 1);
        assertEq(_window(), 0, "fixture: the stream has run dry");

        _recover(400e6);
        assertEq(_window(), Config.YIELD_STREAM_DURATION, "a cold arrival gets the whole floor");
    }

    // -- the gate is a no-op or a deferral, never a revert --------------------

    /// @notice The hard constraint the principal-flush path depends on.
    ///         `CreditManager.flushPrincipalTo` routes through `repayPrincipal`, whose surplus
    ///         branch is one of the two sites gated here, and `owedToSource` has exactly one drain
    ///         and no rescue. A refused re-rate would strand that money permanently, so nothing
    ///         added here may revert: both halves only ever choose a duration.
    /// @dev The adverse states are the ones where the arithmetic could bite - a re-rate in the same
    ///      block the stream started, one second left on a very large stream, the exact instant the
    ///      window closes, and one second past it.
    function test_clock_theGateIsANoOpOrADeferralAndNeverARevert() public {
        vm.prank(admin);
        pool.setDepositCap(250_000e6);
        _deposit(alice, 200_000e6);
        _epoch(150_000e6);

        _recover(1);
        _repaySurplus(1);

        vm.warp(pool.yieldStreamEndsAt() - 1);
        assertEq(_window(), 1, "fixture: one second left");
        _recover(1);
        _repaySurplus(1);
        assertGe(_window(), 1, "the rule-2 floor keeps the duration at one second or more");

        vm.warp(pool.yieldStreamEndsAt());
        _recover(1);
        vm.warp(pool.yieldStreamEndsAt() + 1);
        _repaySurplus(1);

        // And a long hammering, alternating legs, which is the shape finding 2's driver has.
        for (uint256 i = 0; i < 200; i++) {
            skip(1 hours);
            _recover(1);
            _repaySurplus(1);
        }
        assertGt(pool.yieldRate(), 0, "a live pot still has a live rate");
    }

    /// @notice The same constraint on the leg that carries the stranding risk: a surplus arriving
    ///         through the principal door is streamed, never refused, in every stream state.
    function testFuzz_clock_aPrincipalSurplusIsNeverRefused(uint96 amount, uint32 offset) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        offset = uint32(bound(offset, 0, 400 days));

        _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(offset);

        uint256 balanceBefore = usdc.balanceOf(address(pool));
        _repaySurplus(amount);
        assertEq(usdc.balanceOf(address(pool)), balanceBefore + amount, "the surplus was taken, not refused");
    }

    // -- round-23 finding 23 is still inert -----------------------------------

    /// @notice RE-VERIFICATION, not an assumption. Finding 23 sits in the do-not-re-file block
    ///         because the two frozen-pot branches - `repayPrincipal`'s and `recoverLoss`'s - do not
    ///         need to crystallise a running stream: a low but non-zero supply reaches them only
    ///         after `_update` has already frozen it. The fix here touches neither the freeze block
    ///         nor either branch, but "does not touch" is an argument and this is a measurement.
    /// @dev The claim measured is deliberately about the low but non-zero band. At exactly zero
    ///      supply canonical cash de-recognises the terminal tail so a future cohort cannot inherit
    ///      it. `MIN_SUPPLY_FOR_YIELD` is private, so its derived value is repeated in the fixture.
    function test_clock_f23_theUncrystallisedBranchesAreStillInert() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _epoch(EPOCH);
        skip(2 days);

        uint256 liveTail = pool.unreleasedYield();
        assertGt(liveTail, 0, "fixture: a live tail exists to be frozen");

        uint256 unsafeSupply = (10 ** 3) * Config.BPS - 1;
        vm.prank(alice);
        pool.redeem(shares - unsafeSupply, alice, alice);
        assertEq(pool.totalSupply(), unsafeSupply, "the exact low-supply fixture was not reached");
        assertGt(pool.totalSupply(), 0, "the low-supply cohort was emptied");
        assertLt(pool.totalSupply(), (10 ** 3) * Config.BPS, "the supply did not cross the yield floor");

        // `_update` got there first in the live low-supply band. This is finding 23's inertness.
        assertEq(pool.yieldRate(), 0, "the stream is already frozen before either branch is reached");
        assertEq(pool.pendingYield(), liveTail, "and the live tail was crystallised on the way out");

        // Branch one: `recoverLoss`.
        uint256 pot = pool.pendingYield();
        _recover(123e6);
        assertEq(pool.yieldRate(), 0, "recoverLoss took the frozen branch");
        assertEq(pool.pendingYield(), pot + 123e6, "and lost nothing by not crystallising");
        assertEq(pool.unreleasedYield(), pot + 123e6, "the whole pot is still withheld");

        // Branch two: `repayPrincipal`'s surplus.
        pot = pool.pendingYield();
        _repaySurplus(77e6);
        assertEq(pool.yieldRate(), 0, "repayPrincipal took the frozen branch");
        assertEq(pool.pendingYield(), pot + 77e6, "and lost nothing by not crystallising");
        assertEq(pool.unreleasedYield(), pot + 77e6, "the whole pot is still withheld");

        // And the pot is not stranded: the next epoch folds it in under rule 3.
        pot = pool.pendingYield();
        _deposit(bob, DEPOSIT);
        _epoch(1e6);
        assertGt(pool.yieldRate(), 0, "the next epoch re-rates the frozen pot");
        assertEq(pool.pendingYield(), pot + 1e6, "with nothing left behind");
    }

    // -- what the fix does not change -----------------------------------------

    /// @notice REGRESSION. `unreleasedYield()` is a pure function of the stream terms, and later
    ///         work is building an entry-price bound on top of that. The fix changes the terms and
    ///         not the function, so the round-23 result it rests on must still hold: the entry
    ///         quote is exactly time-invariant across a live stream, because `_entryAssets` adds
    ///         back the same `unreleasedYield()` that `_poolBalance` subtracts.
    function test_clock_theEntryQuoteIsStillFlatAcrossALiveStream() public {
        _deposit(alice, DEPOSIT);
        skip(90 days); // a stale epoch clock, so the fix is in play
        _recover(EPOCH);

        uint256 quote = pool.previewDeposit(1_000e6);
        uint256 endsAt = pool.yieldStreamEndsAt();
        for (uint256 i = 1; i < 9; i++) {
            vm.warp(block.timestamp + (endsAt - block.timestamp) / 2);
            assertEq(pool.previewDeposit(1_000e6), quote, "the entry quote moved with the clock");
        }
    }

    /// @notice REGRESSION. Nothing above may leave money outside the book. Whatever has been
    ///         delivered plus whatever is still withheld is the pot, after any mix of legs.
    function test_clock_everyWeiDeliveredOrWithheldIsAccountedFor() public {
        _deposit(alice, DEPOSIT);
        // A current epoch clock, so the epoch's own window is the five-day floor and the two
        // stream durations skipped at the end really do outrun it. With a drought here the epoch
        // leg would still rate over the drought - correctly, and this test would be measuring that
        // instead of the thing it is for.
        skip(1 days);
        _epoch(EPOCH);

        uint256 paidIn = EPOCH;
        for (uint256 i = 0; i < 24; i++) {
            skip(5 hours);
            _recover(3);
            _repaySurplus(7);
            paidIn += 10;
        }

        skip(Config.YIELD_STREAM_DURATION * 2);
        assertEq(pool.unreleasedYield(), 0, "the stream finished");
        assertEq(pool.totalAssets(), DEPOSIT + paidIn, "and every wei paid in reached the book");
    }
}
