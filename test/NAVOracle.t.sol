// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {NAVOracle} from "../src/NAVOracle.sol";

/// @notice The NAV feed's guards. PRD §9 names keeper key compromise as the worst
///         realistic attack on the protocol - a fake high NAV lets a position borrow
///         against collateral that is not worth it - so these are the tests that
///         matter most in Phase 2.
contract NAVOracleTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp, real 2026-07-24 snapshot

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");
    address internal outsider = makeAddr("outsider");

    NAVOracle internal oracle;

    function setUp() public {
        oracle = new NAVOracle(admin);
        vm.startPrank(admin);
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(NAV);
        vm.stopPrank();
    }

    function _post(uint256 nav) private {
        vm.prank(keeper);
        oracle.postNav(nav);
    }

    // ── roles ────────────────────────────────────────────────────────────────

    /// @dev Two keys that are the same key are one key, and the pair is the entire
    ///      mitigation for the attack PRD §9 calls the worst realistic one.
    function test_setKeeper_rejectsTheConfirmer() public {
        vm.prank(admin);
        vm.expectRevert(NAVOracle.KeysMustDiffer.selector);
        oracle.setKeeper(confirmer);
    }

    function test_setNavConfirmer_rejectsTheKeeper() public {
        vm.prank(admin);
        vm.expectRevert(NAVOracle.KeysMustDiffer.selector);
        oracle.setNavConfirmer(keeper);
    }

    function test_postNav_onlyKeeper() public {
        vm.prank(outsider);
        vm.expectRevert(NAVOracle.NotKeeper.selector);
        oracle.postNav(NAV);
    }

    // ── bootstrap ────────────────────────────────────────────────────────────

    /// @dev Owner-only and once. It sets the anchor every later post is judged
    ///      against, so it should not be a keeper power.
    function test_bootstrap_isOwnerOnlyAndOnce() public {
        NAVOracle fresh = new NAVOracle(admin);
        vm.prank(keeper);
        vm.expectRevert();
        fresh.bootstrapNav(NAV);

        vm.startPrank(admin);
        fresh.bootstrapNav(NAV);
        vm.expectRevert(NAVOracle.AlreadyBootstrapped.selector);
        fresh.bootstrapNav(NAV);
        vm.stopPrank();
    }

    function test_postNav_revertsBeforeBootstrap() public {
        NAVOracle fresh = new NAVOracle(admin);
        vm.startPrank(admin);
        fresh.setKeeper(keeper);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(NAVOracle.NotBootstrapped.selector);
        fresh.postNav(NAV);
    }

    /// @dev A zero NAV would make every position instantly liquidatable and block
    ///      every collateralised withdrawal.
    function test_postNav_rejectsZero() public {
        vm.prank(keeper);
        vm.expectRevert(NAVOracle.ZeroNav.selector);
        oracle.postNav(0);
    }

    // ── the deviation budget ─────────────────────────────────────────────────

    function test_allowedDeviation_accruesWithTime() public {
        assertEq(oracle.allowedDeviationBps(), 0, "no time elapsed, no budget");
        vm.warp(block.timestamp + 12 hours);
        assertEq(oracle.allowedDeviationBps(), Config.NAV_MAX_DEVIATION_BPS / 2);
        vm.warp(block.timestamp + 12 hours);
        assertEq(oracle.allowedDeviationBps(), Config.NAV_MAX_DEVIATION_BPS);
    }

    function test_allowedDeviation_isCappedForLongOutages() public {
        // Seven days of keeper silence sits inside the 8-day staleness budget, so
        // without a cap it would buy an unbounded move on the next post.
        vm.warp(block.timestamp + 7 days);
        assertEq(
            oracle.allowedDeviationBps(),
            (Config.NAV_MAX_DEVIATION_BPS * Config.NAV_DEVIATION_MAX_ELAPSED)
                / Config.NAV_DEVIATION_WINDOW
        );
    }

    function test_postNav_withinBudgetTakesEffect() public {
        vm.warp(block.timestamp + 1 days);
        uint256 next = NAV * 105 / 100; // +5%, inside a full day's 10%
        _post(next);
        assertEq(oracle.navPerBond(), next);
        assertEq(oracle.lastUpdated(), block.timestamp);
        assertEq(oracle.pendingNav(), 0);
    }

    function test_postNav_beyondBudgetGoesPending() public {
        vm.warp(block.timestamp + 1 days);
        uint256 next = NAV * 120 / 100; // +20%
        _post(next);

        assertEq(oracle.navPerBond(), NAV, "live NAV unchanged");
        assertEq(oracle.pendingNav(), next);
        assertEq(oracle.pendingConfirmableAt(), block.timestamp + Config.NAV_PENDING_DELAY);
    }

    /// @dev The whole point of prorating. A flat per-post cap lets a compromised
    ///      keeper post just under the limit over and over inside one block; here the
    ///      second post in the same second has no budget at all.
    function test_postNav_repeatedPostsCannotWalkThePrice() public {
        vm.warp(block.timestamp + 1 days);
        uint256 next = NAV * 109 / 100; // +9%, accepted
        _post(next);
        assertEq(oracle.navPerBond(), next);

        // Immediately again: budget is zero, so anything but a no-op goes pending.
        _post(next * 109 / 100);
        assertEq(oracle.navPerBond(), next, "second walk-up did not take effect");
        assertGt(oracle.pendingNav(), 0);
    }

    /// @dev Documents honestly what the design does buy: frequent small posts move
    ///      the price slightly more than one large one, because each accepted price
    ///      becomes the new anchor. Bounded and predictable, not unbounded.
    function test_postNav_frequentPostsCompoundOnlyMarginally() public {
        uint256 nav = NAV;
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 1 hours);
            nav = nav * 10041 / 10000; // ~41.6 bps, one hour's budget
            _post(nav);
        }
        assertEq(oracle.navPerBond(), nav);
        // ~10.5% over the day against ~10% for a single daily post.
        assertLt(nav, NAV * 111 / 100);
        assertGt(nav, NAV * 110 / 100);
    }

    // ── the pending path ─────────────────────────────────────────────────────

    /// @dev Triples the price. The budget accrues with time and is capped at
    ///      NAV_DEVIATION_MAX_ELAPSED / NAV_DEVIATION_WINDOW × NAV_MAX_DEVIATION_BPS
    ///      (30%), so a 200% jump is beyond it no matter how long the gap has been.
    function _goPending() private returns (uint256 pending) {
        vm.warp(block.timestamp + 1 days);
        pending = NAV * 3;
        _post(pending);
    }

    function test_confirm_requiresTheDelay() public {
        uint256 pending = _goPending();
        // Read before the prank: a view call would otherwise consume it.
        uint256 confirmableAt = oracle.pendingConfirmableAt();

        vm.prank(confirmer);
        vm.expectRevert(
            abi.encodeWithSelector(NAVOracle.PendingNotYetConfirmable.selector, confirmableAt)
        );
        oracle.confirmNav(pending);
    }

    function test_confirm_takesEffectAfterTheDelay() public {
        uint256 pending = _goPending();
        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(confirmer);
        oracle.confirmNav(pending);

        assertEq(oracle.navPerBond(), pending);
        assertEq(oracle.pendingNav(), 0);
        assertEq(oracle.anchorNav(), pending, "anchor follows the confirmed price");
    }

    /// @dev Without an expiry, a price posted during a crash could be ratified days
    ///      later. Accepting it would reset lastUpdated and make a stale feed read as
    ///      fresh at a price that no longer holds.
    function test_confirm_revertsOncePendingHasExpired() public {
        uint256 pending = _goPending();
        uint256 confirmableAt = oracle.pendingConfirmableAt();
        vm.warp(confirmableAt + Config.NAV_PENDING_EXPIRY + 1);

        vm.prank(confirmer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NAVOracle.PendingExpired.selector, confirmableAt + Config.NAV_PENDING_EXPIRY
            )
        );
        oracle.confirmNav(pending);
    }

    function test_confirm_onlyConfirmerAndNotTheKeeper() public {
        uint256 pending = _goPending();
        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);

        vm.prank(keeper);
        vm.expectRevert(NAVOracle.NotConfirmer.selector);
        oracle.confirmNav(pending);
    }

    /// @dev The value is passed explicitly so a keeper repost cannot race a
    ///      confirmation into ratifying a different price.
    function test_confirm_rejectsAMismatchedValue() public {
        uint256 pending = _goPending();
        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);

        vm.prank(confirmer);
        vm.expectRevert(
            abi.encodeWithSelector(NAVOracle.PendingNavMismatch.selector, pending, pending + 1)
        );
        oracle.confirmNav(pending + 1);
    }

    /// @dev The keeper must NOT be able to drop a pending value. Posting the current
    ///      NAV always satisfies the budget, so letting an accepted post clear the
    ///      pending slot handed the keeper a free, unilateral veto over the second key
    ///      - defeating the whole point of having one. Only the owner or the confirmer
    ///      can cancel, and NAV_PENDING_EXPIRY bounds how long a stale pending lives.
    function test_pending_survivesAnAcceptedPostByTheKeeper() public {
        uint256 pending = _goPending();
        vm.warp(block.timestamp + 1 days);
        _post(NAV * 103 / 100);

        assertEq(oracle.pendingNav(), pending, "keeper must not be able to cancel");
    }

    /// @dev And the keeper cannot stall it either: reposting the same value leaves the
    ///      original deadline in place, so the confirmer's window still arrives.
    function test_pending_deadlineDoesNotSlideOnRepost() public {
        uint256 pending = _goPending();
        uint256 confirmableAt = oracle.pendingConfirmableAt();

        for (uint256 i; i < 11; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _post(pending);
        }
        assertEq(oracle.pendingConfirmableAt(), confirmableAt, "deadline must not move");

        vm.warp(confirmableAt);
        vm.prank(confirmer);
        oracle.confirmNav(pending);
        assertEq(oracle.navPerBond(), pending);
    }

    /// @dev The regression for the truncation hole: sub-1-bps steps used to floor to
    ///      zero deviation and pass a zero budget, and each accepted post re-anchored,
    ///      so a keeper could walk NAV anywhere inside one block. The previous test
    ///      probed a +9% step, ~900x too large to reach the branch.
    function test_postNav_subBpsStepsCannotWalkThePrice() public {
        uint256 start = oracle.navPerBond();
        uint256 step = start / Config.BPS - 1; // deliberately under one basis point

        for (uint256 i; i < 50; ++i) {
            uint256 next = oracle.navPerBond() + step; // read before the prank
            vm.prank(keeper);
            oracle.postNav(next);
        }
        assertEq(oracle.navPerBond(), start, "no time elapsed means no movement at all");
        assertGt(oracle.pendingNav(), 0, "the move was routed to the second key instead");
    }

    function test_cancelPendingNav_byOwnerOrConfirmer() public {
        _goPending();
        vm.prank(admin);
        oracle.cancelPendingNav();
        assertEq(oracle.pendingNav(), 0);

        _goPending();
        vm.prank(confirmer);
        oracle.cancelPendingNav();
        assertEq(oracle.pendingNav(), 0);
    }

    function test_confirm_resetsTheAnchorSoNormalPostingResumes() public {
        uint256 pending = _goPending();
        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(confirmer);
        oracle.confirmNav(pending);

        // If the anchor had not moved with it, the next ordinary post would be
        // measured against a now-distant price and the feed would brick.
        vm.warp(block.timestamp + 1 days);
        _post(pending * 105 / 100);
        assertEq(oracle.navPerBond(), pending * 105 / 100);
    }

    // ── staleness ────────────────────────────────────────────────────────────

    function test_isStale_trueWhenNeverPosted() public {
        NAVOracle fresh = new NAVOracle(admin);
        assertTrue(fresh.isStale(), "a never-posted oracle must read stale immediately");
    }

    function test_isStale_falseAfterAPostAndTrueAfterTheWindow() public {
        assertFalse(oracle.isStale());
        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(oracle.isStale());
    }

    // ── config relations ─────────────────────────────────────────────────────

    /// @dev These have to hold for the guards to make sense together: a large move
    ///      must be confirmable well inside the window it is measured against, and
    ///      both must be comfortably inside the staleness budget.
    function test_configRelationsHold() public pure {
        assertLt(Config.NAV_PENDING_DELAY, Config.NAV_DEVIATION_WINDOW);
        assertLt(Config.NAV_DEVIATION_WINDOW, Config.NAV_STALENESS);
        assertLe(Config.NAV_DEVIATION_MAX_ELAPSED, Config.NAV_STALENESS);
        // The reprice tolerance has to sit well inside the budget, or a repost that
        // keeps the review clock running could itself be a material move.
        assertLt(Config.NAV_PENDING_REPRICE_TOLERANCE_BPS, Config.NAV_MAX_DEVIATION_BPS);
    }

    // ── the confirmation window ──────────────────────────────────────────────

    /// @dev **The sliding-window regression.** A previous fix anchored the review clock
    ///      to the pending *value*, so it only restarted when the value changed. That
    ///      reads as safe and is not: a live price feed posts a different 8-decimal
    ///      figure every time, so every repost restarted the twelve hours and no large
    ///      move could ever be ratified - with an honest keeper on the documented
    ///      cadence, not a compromised one.
    ///
    ///      Here the keeper reposts a crashed NAV on a 6h cadence with realistic
    ///      jitter. The confirmation must become available on schedule.
    ///
    ///      **Amended by audit round 12.** This used to assert that the *latest* posted
    ///      price was the pending one, and then confirm that. Both halves passed against
    ///      the veto bug below, because a test that always ratifies whatever is currently
    ///      pending can never notice that the pending value moved - it re-reads the
    ///      answer instead of holding one. The clock property this test exists for is
    ///      unchanged and still asserted; what it confirms is now the price the confirmer
    ///      was shown.
    function test_pending_jitteringRepostsDoNotSlideTheWindow() public {
        uint256 crashed = (NAV * 70) / 100; // -30%, well outside the budget
        _post(crashed);
        uint256 confirmableAt = oracle.pendingConfirmableAt();

        // Two reposts inside the delay, each a hair different, as a real feed would.
        skip(6 hours);
        _post(crashed + 1);
        skip(6 hours);
        _post(crashed + 2);

        assertEq(oracle.pendingConfirmableAt(), confirmableAt, "the clock did not slide");
        assertEq(oracle.pendingNav(), crashed, "and the value under review held still");

        vm.prank(confirmer);
        oracle.confirmNav(crashed);
        assertEq(oracle.navPerBond(), crashed, "the crash was ratifiable on schedule");
    }

    /// @notice The keeper can open a review window and cannot extend one.
    /// @dev **This asserted the opposite until audit round 13, and the thing it asserted was the
    ///      attack.** "A materially different price is a different decision, so it earns a fresh
    ///      review window" sounds like care and is a permanent veto: a keeper oscillating between
    ///      two out-of-budget prices more than the reprice tolerance apart, once every eleven
    ///      hours, restarted this clock every time, so `confirmNav` could never satisfy
    ///      `block.timestamp >= pendingConfirmableAt`. Six of twelve agents traced it. The
    ///      round-12 tolerance fix had closed only the sub-tolerance half of the same hole.
    ///
    ///      The pending slot is now write-once per window. Replacing a live pending value early is
    ///      a decision for the keys that own the second-key path - `cancelPendingNav` is held by
    ///      the owner and the confirmer - so the keeper keeps the power to start the process and
    ///      loses the power to restart it.
    function test_pending_aMaterialRepriceCannotExtendTheWindow() public {
        _post((NAV * 70) / 100);
        uint256 first = oracle.pendingConfirmableAt();
        uint256 parked = oracle.pendingNav();

        skip(6 hours);
        _post((NAV * 50) / 100); // another 20% down, well past the reprice tolerance

        assertEq(oracle.pendingConfirmableAt(), first, "the keeper must not buy a fresh 12h");
        assertEq(oracle.pendingNav(), parked, "nor swap the number under review");

        // And the window still arrives: the confirmer ratifies on the original schedule.
        vm.warp(first);
        vm.prank(confirmer);
        oracle.confirmNav(parked);
        assertEq(oracle.navPerBond(), parked);
    }

    /// @dev The escape hatch that makes the write-once rule liveable: the second key can drop a
    ///      pending value it does not want, and the next post parks a fresh one with a fresh clock.
    ///      Without this the keeper could park a number and neither side could move on.
    function test_pending_cancellingLetsTheKeeperParkAFreshNumber() public {
        _post((NAV * 70) / 100);

        vm.prank(confirmer);
        oracle.cancelPendingNav();

        skip(1 hours);
        uint256 replacement = (NAV * 50) / 100;
        _post(replacement);
        assertEq(oracle.pendingNav(), replacement, "a cleared slot accepts the next post");
        assertEq(oracle.pendingConfirmableAt(), block.timestamp + Config.NAV_PENDING_DELAY);
    }

    /// @dev **Audit round 12: the permanent second-key veto.** `confirmNav` takes the
    ///      price explicitly - deliberately, so the confirmer ratifies a number they
    ///      typed rather than whatever happens to be pending. That guard is only worth
    ///      anything if the pending value holds still long enough to be typed.
    ///
    ///      It did not. `postNav` assigned `pendingNav` on every out-of-budget post
    ///      while restarting the review clock only on a *material* move, so a keeper
    ///      posting last-decimal jitter swapped the value out from under every
    ///      confirmation and `confirmNav` reverted `PendingNavMismatch` forever. PRD §9
    ///      names keeper compromise as the worst realistic attack on this protocol, and
    ///      this is that attack with its stated mitigation switched off - by a keeper
    ///      that only has to behave like a live price feed.
    ///
    ///      The confirmer here reads the pending value once, as a human would, and then
    ///      tries to ratify it while the keeper keeps posting.
    function test_pending_jitterCannotVetoTheSecondKey() public {
        uint256 crashed = (NAV * 70) / 100; // -30%, well outside the budget
        _post(crashed);

        // What the confirmer sees, and the number they will type.
        uint256 seen = oracle.pendingNav();
        uint256 confirmableAt = oracle.pendingConfirmableAt();

        // The keeper keeps speaking, every value a hair off the last, none of them
        // material. A real feed does exactly this.
        for (uint256 i = 1; i <= 12; ++i) {
            skip(1 hours);
            _post(crashed + i);
        }

        assertEq(oracle.pendingNav(), seen, "jitter must not move the value under review");

        vm.warp(confirmableAt);
        vm.prank(confirmer);
        oracle.confirmNav(seen);
        assertEq(oracle.navPerBond(), seen, "the second key must be able to ratify what it was shown");
    }

    /// @dev The same line let the pending price *walk*. Each sub-tolerance repost
    ///      overwrote `pendingNav` without restarting the clock, so twelve hours after
    ///      the first post the confirmer could be handed a price arbitrarily far from
    ///      the one whose review window they had been waiting out - ratifying, in one
    ///      signature, a move no single post was ever allowed to make.
    ///
    ///      Each step here is under `NAV_PENDING_REPRICE_TOLERANCE_BPS` against the
    ///      value before it, so every one of them is individually "not worth
    ///      re-reviewing", which is the whole point.
    function test_pending_subToleranceStepsCannotWalkThePendingPrice() public {
        uint256 crashed = (NAV * 70) / 100;
        _post(crashed);

        uint256 seen = oracle.pendingNav();
        uint256 confirmableAt = oracle.pendingConfirmableAt();

        // Half the tolerance per step, compounding, for fifty steps: enough to move the
        // pending price by roughly a fifth if the walk lands.
        for (uint256 i; i < 50; ++i) {
            uint256 next = oracle.pendingNav();
            next += (next * (Config.NAV_PENDING_REPRICE_TOLERANCE_BPS / 2)) / Config.BPS;
            skip(1 minutes);
            _post(next);
        }

        assertEq(oracle.pendingNav(), seen, "a walk of immaterial steps is still a material move");
        assertEq(oracle.pendingConfirmableAt(), confirmableAt, "and it must not have touched the clock");
    }

    // ── freshness ────────────────────────────────────────────────────────────

    /// @dev **The frozen-price regression.** A zero-delta post satisfies the deviation
    ///      budget for any elapsed time, so keying `lastUpdated` off every accepted
    ///      post let a keeper hold a stale price indefinitely: `isStale()` never
    ///      tripped, `borrow` stayed open, and the second key was never consulted.
    ///      Freshness now tracks when the price last *changed*.
    function test_repostingTheSameNavDoesNotRefreshStaleness() public {
        // The keeper reposts the identical price for longer than the staleness window.
        for (uint256 i; i < 10; ++i) {
            skip(1 days);
            _post(NAV);
        }

        assertTrue(oracle.isStale(), "an unchanging price is a stale price");
    }

    /// @dev And a price that genuinely moves keeps the feed fresh, so the check above
    ///      cannot be satisfied by simply never updating `lastUpdated`.
    function test_aMovingNavStaysFresh() public {
        for (uint256 i; i < 10; ++i) {
            skip(1 days);
            _post(NAV + i + 1);
        }
        assertFalse(oracle.isStale(), "a live feed reads fresh");
    }
}
