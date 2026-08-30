// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Config} from "../src/Config.sol";
import {NAVOracle} from "../src/NAVOracle.sol";

/// @notice Randomised post / confirm / cancel / wait sequences against the live NAVOracle.
/// @dev **Why this file exists.** `NAVOracle` is the protocol's only price-forming mechanism and
///      every loan is sized against it, and until round 25 it had no invariant campaign at all -
///      only witness-picking unit tests. Unit tests prove the cases someone thought of. What the
///      oracle has to survive is arbitrary orderings of four operations across arbitrary elapsed
///      time, including the ones nobody would write down: a confirm racing an accepted post, a
///      cancel landing between a park and its window opening, a zero-delta repost arriving while
///      a pending is live.
///
///      Every action is wrapped in `try` because `foundry.toml` sets `fail_on_revert = false` and
///      most random sequences are meaningless. The consequence catalogued repeatedly in this repo
///      is that an action which always reverts is a silent no-op, so every branch this campaign
///      claims to cover has a ghost counter and
///      `test_handlerCanReachEveryStateTheInvariantsCheck` asserts each one non-zero.
///
///      **The observations live on the handler, not on the suite.** forge discards the state a
///      non-view `invariant_` writes, so a mirror kept on the invariant contract silently degrades
///      to its `setUp` value. Anything of the form "compare against what I saw last time" is
///      therefore recorded inside the handler call that saw it.
contract NavOracleHandler is Test {
    NAVOracle public immutable oracle;

    address public immutable admin;
    address public immutable keeper;
    address public immutable confirmer;

    // -- observations the invariants read -------------------------------------

    /// @notice `block.timestamp` of the last call that actually changed `navPerBond`.
    /// @dev The mirror for `lastUpdated`. Not "the last accepted post": `_accept` skips the write
    ///      when the value is unchanged, so the two differ on a zero-delta repost and that
    ///      difference is the whole content of the field.
    uint256 public lastNavChangeAt;

    /// @notice When the live pending slot was written, so `pendingConfirmableAt` can be checked to
    ///         be exactly `NAV_PENDING_DELAY` after it rather than merely "in the future".
    uint256 public pendingOpenedAt;

    // -- violation counters. Every one is asserted zero. ----------------------

    /// @notice Keeper posts that were ACCEPTED while further from the pre-call anchor than the
    ///         prorated budget allowed, recomputed here from `Config` rather than by asking the
    ///         contract the question it is being tested on.
    uint256 public keeperAcceptOverBudget;
    /// @notice Confirmations that succeeded while `block.timestamp` was outside
    ///         `[confirmableAt, confirmableAt + NAV_PENDING_EXPIRY]`.
    uint256 public confirmsOutsideWindow;
    /// @notice Times `pendingConfirmableAt` moved later while the pending VALUE was unchanged and
    ///         non-zero - a keeper extending the second key's review window, which round 13 found
    ///         was a permanent veto for one transaction every twelve hours.
    uint256 public windowExtensions;
    /// @notice Cancellations that moved the served price.
    uint256 public cancelChangedPrice;
    /// @notice Calls after which `isStale()` went true -> false without `navPerBond` changing.
    uint256 public staleClearedWithoutAChange;
    /// @notice Calls that changed `navPerBond` without `anchorNav` following it to the same value.
    uint256 public anchorDivergedFromPrice;

    // -- coverage ghosts. Every one is asserted NON-zero. ---------------------

    uint256 public keeperAccepts;
    uint256 public keeperZeroDeltaAccepts;
    uint256 public parksOpened;
    /// @notice Out-of-budget posts that the write-once rule refused to store. The live
    ///         2026-08-19..08-23 incident is made of these.
    uint256 public parksSkipped;
    uint256 public confirms;
    uint256 public confirmsRefusedEarly;
    uint256 public confirmsRefusedExpired;
    uint256 public confirmsRefusedMismatch;
    uint256 public cancels;
    uint256 public postsRefused;
    uint256 public wentStale;

    uint256 private constant BOOTSTRAP = 25.15e8; // USD 8dp, the real 2026-07-24 snapshot

    struct Snap {
        uint256 navPerBond;
        uint256 anchorNav;
        uint256 anchorAt;
        uint256 lastUpdated;
        uint256 pendingNav;
        uint256 pendingConfirmableAt;
        bool stale;
    }

    constructor() {
        admin = makeAddr("navAdmin");
        keeper = makeAddr("navKeeper");
        confirmer = makeAddr("navConfirmer");

        oracle = new NAVOracle(admin);
        vm.startPrank(admin);
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(BOOTSTRAP);
        vm.stopPrank();

        lastNavChangeAt = block.timestamp;
    }

    // -- actions --------------------------------------------------------------

    function post(uint256 navSeed, uint256 warpSeed) external {
        _warp(warpSeed);
        uint256 nav = _drawNav(navSeed);

        // Reads first, prank second, call third. A staticcall spends the prank.
        Snap memory s = _snap();

        vm.prank(keeper);
        try oracle.postNav(nav) {
            _observePost(nav, s);
        } catch {
            postsRefused++;
        }
        _observeCommon(s);
    }

    function confirm(uint256 navSeed, uint256 warpSeed) external {
        _warp(warpSeed);
        Snap memory s = _snap();
        // Mostly the honest value, sometimes a typo - both branches matter.
        uint256 nav = navSeed % 8 == 0 ? _drawNav(navSeed) : s.pendingNav;

        vm.prank(confirmer);
        try oracle.confirmNav(nav) {
            confirms++;
            uint256 expiresAt = s.pendingConfirmableAt + Config.NAV_PENDING_EXPIRY;
            if (block.timestamp < s.pendingConfirmableAt || block.timestamp > expiresAt) {
                confirmsOutsideWindow++;
            }
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            if (sel == NAVOracle.PendingNotYetConfirmable.selector) confirmsRefusedEarly++;
            else if (sel == NAVOracle.PendingExpired.selector) confirmsRefusedExpired++;
            else if (sel == NAVOracle.PendingNavMismatch.selector) confirmsRefusedMismatch++;
        }
        _observeCommon(s);
    }

    function cancel(uint256 warpSeed, bool asOwner) external {
        _warp(warpSeed);
        Snap memory s = _snap();

        vm.prank(asOwner ? admin : confirmer);
        try oracle.cancelPendingNav() {
            cancels++;
            if (oracle.navPerBond() != s.navPerBond) cancelChangedPrice++;
        } catch {}
        _observeCommon(s);
    }

    /// @notice Time alone. Staleness and the budget are both functions of it, so a campaign that
    ///         only moved the clock inside a write would never observe either crossing.
    function wait_(uint256 warpSeed) external {
        Snap memory s = _snap();
        _warp(warpSeed);
        _observeCommon(s);
    }

    // -- internals ------------------------------------------------------------

    function _snap() private view returns (Snap memory) {
        return Snap({
            navPerBond: oracle.navPerBond(),
            anchorNav: oracle.anchorNav(),
            anchorAt: oracle.anchorAt(),
            lastUpdated: oracle.lastUpdated(),
            pendingNav: oracle.pendingNav(),
            pendingConfirmableAt: oracle.pendingConfirmableAt(),
            stale: oracle.isStale()
        });
    }

    function _warp(uint256 warpSeed) private {
        // 0 seconds has to be reachable: a zero budget is where the sub-bps walk lived.
        uint256 dt = warpSeed % 8 == 0 ? 0 : (warpSeed % (3 days));
        if (dt != 0) vm.warp(block.timestamp + dt);
    }

    function _drawNav(uint256 seed) private view returns (uint256) {
        uint256 live = oracle.navPerBond();
        uint256 kind = seed % 4;
        if (kind == 0) {
            // Straddle the budget boundary: 85%..115% of live, in 1-bp steps.
            uint256 bps = 8_500 + (seed / 4) % 3_001;
            return live * bps / Config.BPS;
        }
        if (kind == 1) {
            // Large moves that must park.
            uint256 mult = 2 + (seed / 4) % 5;
            return (seed / 64) % 2 == 0 ? live * mult : live / mult;
        }
        if (kind == 2) {
            // Full width, and zero deliberately given real weight rather than left to a 1-in-1e13
            // draw. Zero is the input `ZeroNav` exists for, and a campaign that never posts it
            // proves only that the guard is never asked.
            uint256 v = (seed / 4) % 1e13;
            return v % 32 == 0 ? 0 : v;
        }
        return live; // the zero-delta repost
    }

    function _observePost(uint256 nav, Snap memory s) private {
        if (oracle.anchorAt() == block.timestamp && oracle.navPerBond() == nav) {
            // Accepted. Re-derive the budget from Config, cross-multiplied like the contract but
            // written out independently here, and check the move was inside it.
            keeperAccepts++;
            if (nav == s.navPerBond) keeperZeroDeltaAccepts++;

            uint256 delta = nav > s.anchorNav ? nav - s.anchorNav : s.anchorNav - nav;
            uint256 elapsed = block.timestamp - s.anchorAt;
            if (elapsed > Config.NAV_DEVIATION_MAX_ELAPSED) elapsed = Config.NAV_DEVIATION_MAX_ELAPSED;
            if (
                delta * Config.BPS * Config.NAV_DEVIATION_WINDOW
                    > Config.NAV_MAX_DEVIATION_BPS * elapsed * s.anchorNav
            ) {
                keeperAcceptOverBudget++;
            }
        } else if (oracle.pendingNav() == nav && oracle.pendingConfirmableAt() != s.pendingConfirmableAt) {
            parksOpened++;
            pendingOpenedAt = block.timestamp;
        } else {
            // Succeeded, stored nothing. The write-once rule refused to replace a live pending.
            parksSkipped++;
        }

        // The keeper must never be able to push the second key's deadline out.
        //
        // **`&& stillLive` is not decoration, and the campaign is what put it there.** The first
        // statement of this invariant omitted it and forge falsified it in a two-call sequence: a
        // pending whose window had EXPIRED, reposted at the identical value, moves
        // `pendingConfirmableAt` later while `pendingNav` reads the same number. That is a new
        // window rather than an extension - the confirmer had its full 24 hours and let them go -
        // so the property being asserted is about a window that is still confirmable.
        // `NAVOracleAttack.t.sol:test_repostingTheSameValueAfterExpiryOpensANewWindowRatherThanExtendingOne`
        // pins that reading deterministically, so this exclusion cannot quietly widen later.
        bool stillLive = block.timestamp <= s.pendingConfirmableAt + Config.NAV_PENDING_EXPIRY;
        if (
            s.pendingNav != 0 && stillLive && oracle.pendingNav() == s.pendingNav
                && oracle.pendingConfirmableAt() > s.pendingConfirmableAt
        ) {
            windowExtensions++;
        }
    }

    function _observeCommon(Snap memory s) private {
        uint256 navNow = oracle.navPerBond();
        if (navNow != s.navPerBond) lastNavChangeAt = block.timestamp;
        if (navNow != s.navPerBond && oracle.anchorNav() != navNow) anchorDivergedFromPrice++;

        bool staleNow = oracle.isStale();
        if (s.stale && !staleNow && navNow == s.navPerBond) staleClearedWithoutAChange++;
        if (!s.stale && staleNow) wentStale++;
    }

    function _selector(bytes memory err) private pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(err, 0x20))
        }
    }
}

/// @notice The invariants `NAVOracle` should have had since it was written.
contract NAVOracleInvariants is StdInvariant, Test {
    NavOracleHandler internal handler;
    NAVOracle internal oracle;

    function setUp() public {
        handler = new NavOracleHandler();
        oracle = handler.oracle();
        targetContract(address(handler));
    }

    // -- structure ------------------------------------------------------------

    /// @notice The served price and the price the budget is measured from are the same number.
    /// @dev Adopted in place of the weaker "`anchorNav` is always a price that was actually
    ///      accepted": `_accept` writes both in the same statement, so the strong form is
    ///      checkable and rules out every ordering in which the anchor and the served price could
    ///      disagree.
    function invariant_anchorIsTheServedPrice() public view {
        assertEq(oracle.anchorNav(), oracle.navPerBond(), "anchor drifted from the served price");
    }

    function invariant_theServedPriceIsNeverZeroOnceBootstrapped() public view {
        assertGt(oracle.navPerBond(), 0, "the feed went back to un-bootstrapped");
    }

    /// @notice The pending value and its clock are set and cleared together.
    function invariant_thePendingSlotsAgree() public view {
        assertEq(
            oracle.pendingNav() == 0,
            oracle.pendingConfirmableAt() == 0,
            "half a pending: one slot set without the other"
        );
    }

    function invariant_theClocksNeverRunAhead() public view {
        assertLe(oracle.anchorAt(), block.timestamp, "anchorAt in the future");
        assertLe(oracle.lastUpdated(), block.timestamp, "lastUpdated in the future");
    }

    /// @notice A live pending is always confirmable exactly `NAV_PENDING_DELAY` after it opened.
    function invariant_theReviewDelayIsExactlyTheConfiguredOne() public view {
        if (oracle.pendingNav() == 0) return;
        assertEq(
            oracle.pendingConfirmableAt(),
            handler.pendingOpenedAt() + Config.NAV_PENDING_DELAY,
            "the review window is not the configured delay after it opened"
        );
    }

    // -- behaviour ------------------------------------------------------------

    /// @notice `lastUpdated` is when the PRICE last changed, not when the keeper last spoke.
    /// @dev The candidate phrased as "`lastUpdated` moves if and only if a price was accepted" is
    ///      REJECTED: it is false in the direction that matters, because `_accept` deliberately
    ///      skips the write when `nav == navPerBond`. This is the true statement, and it is the
    ///      one a compromised keeper is bounded by - a zero-delta repost cannot buy freshness.
    function invariant_lastUpdatedIsWhenThePriceLastChanged() public view {
        assertEq(
            oracle.lastUpdated(), handler.lastNavChangeAt(), "lastUpdated is not the last price change"
        );
    }

    /// @notice No post the keeper makes alone moves the served price further than the prorated
    ///         budget, recomputed from `Config` rather than from the contract's own predicate.
    /// @dev The candidate "an accepted price is always within the deviation budget" is adopted
    ///      only for the keeper path. It is REJECTED for `confirmNav`, which exists precisely to
    ///      exceed the budget and is documented as doing so - asserting it there would encode the
    ///      opposite of the design.
    function invariant_theKeeperAloneStaysInsideTheProratedBudget() public view {
        assertEq(handler.keeperAcceptOverBudget(), 0, "an unconfirmed post exceeded the budget");
    }

    /// @notice A pending price cannot be ratified before its delay or after its expiry.
    function invariant_confirmationOnlyInsideItsWindow() public view {
        assertEq(handler.confirmsOutsideWindow(), 0, "a confirmation landed outside its window");
    }

    /// @notice The keeper may OPEN a review window and may never extend it.
    /// @dev Round 13's finding, held open. One out-of-budget post every eleven hours used to
    ///      restart the clock forever, which is a permanent unilateral veto over the second key.
    function invariant_theKeeperCannotExtendAReviewWindow() public view {
        assertEq(handler.windowExtensions(), 0, "the keeper pushed the confirmer's deadline out");
    }

    function invariant_cancellingNeverMovesTheServedPrice() public view {
        assertEq(handler.cancelChangedPrice(), 0, "cancelPendingNav moved the price");
    }

    /// @notice Staleness is monotone in time between price changes: once true it stays true until
    ///         a new price is actually accepted. Nothing else may clear it.
    function invariant_stalenessOnlyClearsOnARealPriceChange() public view {
        assertEq(handler.staleClearedWithoutAChange(), 0, "a stale feed read fresh without a new price");
    }

    function invariant_theAnchorFollowsEveryPriceChange() public view {
        assertEq(handler.anchorDivergedFromPrice(), 0, "the price moved and the anchor did not");
    }

    // -- reachability ---------------------------------------------------------

    /// @notice Every branch the invariants above claim to cover, reached at least once.
    /// @dev Without this the suite would report twelve green invariants having exercised a handler
    ///      whose every action reverted. `fail_on_revert = false` makes that silent.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        uint256 seed;
        for (uint256 i; i < 3_000; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 pick = seed % 10;
            if (pick < 5) handler.post(seed, seed >> 8);
            else if (pick < 7) handler.confirm(seed, seed >> 8);
            else if (pick < 8) handler.cancel(seed >> 8, seed % 2 == 0);
            else handler.wait_(seed >> 8);
        }

        assertGt(handler.keeperAccepts(), 0, "no post was ever accepted");
        assertGt(handler.keeperZeroDeltaAccepts(), 0, "no zero-delta repost");
        assertGt(handler.parksOpened(), 0, "no pending was ever opened");
        assertGt(handler.parksSkipped(), 0, "the write-once refusal was never reached");
        assertGt(handler.confirms(), 0, "no confirmation ever succeeded");
        assertGt(handler.confirmsRefusedEarly(), 0, "the delay was never enforced");
        assertGt(handler.confirmsRefusedExpired(), 0, "expiry was never enforced");
        assertGt(handler.confirmsRefusedMismatch(), 0, "the value check was never enforced");
        assertGt(handler.cancels(), 0, "nothing was ever cancelled");
        assertGt(handler.postsRefused(), 0, "no post was ever refused");
        assertGt(handler.wentStale(), 0, "the feed never went stale");
    }
    // -- the frame guard ------------------------------------------------------

    /// @notice No handler call is ever discarded by a revert.
    /// @dev **Added when this campaign was promoted into the tree; as first written in audit
    ///      round 25 it did not carry one.** Every
    ///      action above wraps its call in `try`/`catch` so that meaningless random sequences do
    ///      not abort the campaign, and the global `fail_on_revert = false` in `foundry.toml` is
    ///      what makes that idiom work. The cost of both is that a frame dropped OUTSIDE the
    ///      `try` - in `_warp`, `_snap`, `_drawNav` or any ghost write - vanishes silently, and
    ///      every ghost that would have recorded it dies with it. So the reachability test above
    ///      cannot see that failure: its counters are exactly the thing a dropped frame destroys.
    ///
    ///      Empty body on purpose. The assertion IS the config line below, enforced by the
    ///      runner, and it must sit immediately above this declaration - forge attaches an inline
    ///      `forge-config` to a DECLARATION, not to an inherited symbol, so a subclass that
    ///      inherited this guard would run it under the global `fail_on_revert = false` and report
    ///      PASS over every dropped frame. A repository check rejects this function when the line
    ///      is missing, for that reason.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}
}
