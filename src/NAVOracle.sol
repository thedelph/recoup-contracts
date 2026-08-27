// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {INAVOracle} from "./interfaces/INAVOracle.sol";
import {Config} from "./Config.sol";

/// @title NAVOracle (PRD §4.6)
/// @notice Keeper posts navPerBond (USD, 8 decimals) daily (minimum weekly).
///         Moves beyond the time-prorated deviation budget enter a pending state
///         needing a second key. Staleness pauses borrows; liquidations continue on
///         last-known NAV.
/// @dev Keeper key compromise is the worst realistic attack on the protocol (PRD §9):
///      a fake high NAV lets a position overborrow against collateral that isn't
///      worth it. The guards here are the mitigation, so treat them as critical.
contract NAVOracle is INAVOracle, Ownable {
    error NotKeeper();
    error NotConfirmer();
    error ZeroAddress();
    error ZeroNav();
    error RenounceDisabled();
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error KeysMustDiffer();
    error NoPendingNav();
    error PendingNavMismatch(uint256 pending, uint256 supplied);
    error PendingNotYetConfirmable(uint256 confirmableAt);
    error PendingExpired(uint256 expiredAt);

    event NAVPosted(uint256 nav, uint256 timestamp);
    event NAVPending(uint256 nav, uint256 confirmableAt);
    /// @notice A post beyond budget arrived while a live pending already held the slot, so it was
    ///         discarded. Nothing was stored, nothing was accepted, and the transaction succeeded.
    /// @param nav The price that was thrown away. It is recorded here because it is recorded
    ///        nowhere else: the `NAVPending` emitted alongside this carries the *stored* pair, by
    ///        design, so without this event the chain holds no trace of what the keeper proposed.
    /// @param slotFreeAt When the live pending stops holding the slot, after which the next
    ///        out-of-budget post parks a fresh value. `cancelPendingNav` frees it sooner.
    /// @dev **Audit round 26, follow-up item 7: `postNav` has three outcomes and only two had a
    ///      name.** Write-once per review window is the round-13 fix that stopped a keeper
    ///      restarting the confirmer's twelve hours at will, and its cost is this third outcome - a
    ///      success that does nothing. It was invisible: the only tell was an `NAVPending`
    ///      byte-identical to the previous one, which needs both logs and arithmetic to read.
    ///
    ///      **It is not hypothetical.** On the Base Sepolia oracle at 0x2adf6EFE, the post in block
    ///      45763844 (2026-08-21 07:06:16 UTC) hit exactly this branch. The keeper called
    ///      `postNav(2767109425)`, $27.671094; the slot held 2557149953, $25.571500, with
    ///      `pendingConfirmableAt` at 1787252736 (2026-08-20 19:05:36 UTC) and therefore held until
    ///      1787339136 inclusive, 2026-08-21 19:05:36 UTC. The receipt came back success, the only
    ///      log was the earlier `NAVPending` pair re-emitted unchanged, and 2767109425 was stored
    ///      nowhere and logged nowhere. The keeper read that as neither accepted nor pending and
    ///      reported an unknown outcome.
    ///
    ///      An event and not a revert, deliberately. Reverting would fail loudly, and it would fail
    ///      an honest keeper following a real correction on every run until the confirmer acts -
    ///      which is the moment the second key most needs a working feed behind it. This costs one
    ///      log and no control flow.
    event NAVPostIgnored(uint256 nav, uint256 slotFreeAt);
    event NAVPendingCancelled(uint256 nav);
    event KeeperSet(address indexed keeper);
    event NavConfirmerSet(address indexed confirmer);

    address public keeper;
    /// @notice The second key. Confirms moves that exceed the deviation budget, and
    ///         must never be the keeper: that is what makes it two-key.
    address public navConfirmer;

    /// @inheritdoc INAVOracle
    uint256 public override navPerBond;
    /// @inheritdoc INAVOracle
    /// @dev Zero until the first accepted post, which `isStale()` reports as stale.
    // slither-disable-next-line uninitialized-state
    uint256 public override lastUpdated;

    /// @notice The price the deviation budget is measured from, and when it was set.
    ///         Reset on every accepted NAV.
    uint256 public anchorNav;
    uint256 public anchorAt;

    uint256 public pendingNav;
    uint256 public pendingConfirmableAt;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ── Roles ────────────────────────────────────────────────────────────────

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        if (keeper_ == navConfirmer) revert KeysMustDiffer();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @dev Rejecting `keeper == navConfirmer` matters more than it looks: without it
    ///      the two-key requirement silently collapses to one key, and that pair is
    ///      the entire mitigation for the attack PRD §9 calls the worst realistic one.
    function setNavConfirmer(address confirmer_) external onlyOwner {
        if (confirmer_ == address(0)) revert ZeroAddress();
        if (confirmer_ == keeper) revert KeysMustDiffer();
        navConfirmer = confirmer_;
        emit NavConfirmerSet(confirmer_);
    }

    /// @dev Renouncing would permanently freeze keeper management and brick the feed.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── Posting ──────────────────────────────────────────────────────────────

    /// @notice Seed the first NAV. Owner-only, once: there is nothing to measure a
    ///         deviation against, so this sets the anchor everything else is judged
    ///         from and should not be a keeper power.
    function bootstrapNav(uint256 nav) external onlyOwner {
        if (nav == 0) revert ZeroNav();
        if (navPerBond != 0) revert AlreadyBootstrapped();
        _accept(nav);
    }

    /// @notice Post a new NAV. Within the deviation budget it takes effect
    ///         immediately; beyond it, the value is held pending a second key.
    /// @dev The budget is prorated by time elapsed since the last accepted price:
    ///      `NAV_MAX_DEVIATION_BPS * min(elapsed, NAV_DEVIATION_MAX_ELAPSED) /
    ///      NAV_DEVIATION_WINDOW`. A flat per-post cap is not enough on its own,
    ///      because a compromised keeper can post just under it repeatedly and walk
    ///      the price anywhere within a block. Prorating makes posting frequency
    ///      nearly irrelevant: twenty-four hourly posts move the price ~10.5% against
    ///      ~10% for a single post a day later, since each accepted price becomes the
    ///      new anchor and the steps compound. Bounded and predictable, rather than
    ///      the unbounded walk a flat per-post cap permits.
    ///
    ///      Note what this does and does not do. It bounds the *rate*, not the total:
    ///      sustained movement still compounds day over day, by design. The protection
    ///      against a wrong price persisting is the staleness window and the second
    ///      key, not this.
    function postNav(uint256 nav) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (nav == 0) revert ZeroNav();
        if (navPerBond == 0) revert NotBootstrapped();

        if (_withinBudget(nav)) {
            // Deliberately does NOT clear a pending value. An earlier version did,
            // reasoning that the keeper's latest word wins - but posting the current
            // NAV always satisfies the budget, so that handed the keeper a free,
            // unilateral veto over the second key. Only the owner or the confirmer
            // may drop a pending value, via cancelPendingNav.
            _accept(nav);
        } else {
            // The clock belongs to the MOVE, not to the exact value.
            //
            // Anchoring it to the value looked like the fix for a keeper sliding the
            // window, but it only stopped a keeper reposting the identical price -
            // and a live feed never does. Every post differs in the last decimal, so
            // every post restarted the twelve hours and no large move could ever be
            // ratified, with an honest keeper on a normal cadence. That is the same
            // unilateral veto the in-budget branch above was fixed to remove.
            //
            // So: refresh the pending value freely, but only restart the review window
            // when the value has moved enough to be worth re-reviewing. Feed jitter
            // keeps the clock running; a materially different price resets it, because
            // the confirmer's twelve hours are to review the number they will ratify.
            uint256 pending = pendingNav;
            bool materiallyDifferent = pending == 0
                || _deviatesBeyond(pending, nav, Config.NAV_PENDING_REPRICE_TOLERANCE_BPS);

            // **The value and its review clock move together, or neither moves.**
            //
            // Audit round 12. Refreshing the value freely while restarting the clock
            // only on a material move was two thirds of a good idea, and the missing
            // third was fatal in both directions.
            //
            // `confirmNav` takes the price as an explicit argument, so the confirmer
            // ratifies a number they typed rather than whatever is pending - which is
            // the stated bound on the pending slot right up in `_accept`. Assigning
            // here on every post meant a keeper posting last-decimal jitter swapped
            // that number out from under every confirmation, and `confirmNav` reverted
            // `PendingNavMismatch` for as long as the keeper kept speaking. A live feed
            // jitters by default, so this was reachable without any intent at all, and
            // with intent it is a free permanent veto over the second key - PRD §9's
            // worst realistic attack with the mitigation named against it disabled.
            //
            // The same line let the pending price walk: fifty sub-tolerance steps, each
            // individually "not worth re-reviewing", moved it ~28% against a clock that
            // never restarted, so the confirmer's twelve hours were spent reviewing a
            // price they would not be the one to ratify.
            //
            // Skipping the write on jitter costs the freshness of the pending figure,
            // and that is the intended trade rather than an oversight: the tolerance is
            // by definition the band inside which a reprice is not a new decision, and
            // the confirmer ratifying a price one tolerance stale is the same exposure
            // the tolerance already accepts.
            // **Write-once per window, and audit round 13 is why `materiallyDifferent` is gone
            // from this condition.** Skipping the write inside the tolerance closed the accidental
            // veto - a live feed's jitter - and left the deliberate one wide open: a keeper posting
            // one out-of-budget price more than a tolerance away from the pending value, every
            // eleven hours, restarted this clock every time, so `confirmNav` could never satisfy
            // `block.timestamp >= pendingConfirmableAt`. Four agents traced it. One transaction
            // per twelve hours bought a permanent veto over the second key, which is PRD §9's worst
            // case with its named mitigation disabled - and an honest keeper following a crashing
            // feed produces the same denial, at exactly the moment a large correction needs
            // ratifying.
            //
            // So the keeper can open a review window and cannot extend it. Replacing a live pending
            // value early is a decision for the keys that own the second-key path: `cancelPendingNav`
            // is held by the owner and the confirmer, and clearing lets the next post park a fresh
            // number. The keeper keeps the power to *start* the process and loses the power to
            // restart it, which is the whole asymmetry the two-key design is for.
            //
            // `materiallyDifferent` survives only as the expiry-independent half of the old
            // behaviour: it is no longer consulted here at all.
            materiallyDifferent; // silence: retained below for the event's benefit only
            uint256 slotFreeAt = pendingConfirmableAt + Config.NAV_PENDING_EXPIRY;
            if (pending == 0 || block.timestamp > slotFreeAt) {
                pendingNav = nav;
                pendingConfirmableAt = block.timestamp + Config.NAV_PENDING_DELAY;
            } else {
                // Audit round 26, follow-up item 7. The third outcome, said out loud. Nothing above
                // ran, so `nav` is about to be dropped and the `NAVPending` below will repeat the
                // pair the earlier post stored. See `NAVPostIgnored` for why this is an event and
                // not a revert.
                emit NAVPostIgnored(nav, slotFreeAt);
            }
            // The stored pair, not the posted value - an observer that saw `nav` here
            // would be reading a price this contract did not keep.
            emit NAVPending(pendingNav, pendingConfirmableAt);
        }
    }

    /// @notice Second-key confirmation of a large move, after the delay.
    /// @param nav Must equal the pending value. Passing it explicitly stops a keeper
    ///        repost from racing a confirmation into ratifying a different price.
    function confirmNav(uint256 nav) external {
        if (msg.sender != navConfirmer) revert NotConfirmer();
        uint256 pending = pendingNav;
        if (pending == 0) revert NoPendingNav();
        if (pending != nav) revert PendingNavMismatch(pending, nav);

        uint256 confirmableAt = pendingConfirmableAt;
        if (block.timestamp < confirmableAt) revert PendingNotYetConfirmable(confirmableAt);
        // Expiry matters: without it, a price posted during a crash could be ratified
        // days later, and accepting it would reset `lastUpdated` and make a stale feed
        // read as fresh at a price that no longer holds.
        uint256 expiresAt = confirmableAt + Config.NAV_PENDING_EXPIRY;
        if (block.timestamp > expiresAt) revert PendingExpired(expiresAt);

        _clearPending();
        _accept(pending);
    }

    /// @notice Drop a pending NAV. Either governance key may do it.
    function cancelPendingNav() external {
        if (msg.sender != owner() && msg.sender != navConfirmer) revert NotConfirmer();
        uint256 pending = pendingNav;
        if (pending == 0) revert NoPendingNav();
        emit NAVPendingCancelled(pending);
        _clearPending();
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc INAVOracle
    /// @dev A never-posted oracle reads as stale, so consumers gating on `isStale()`
    ///      need no separate zero-NAV check. Staleness window is 8 days; second-level
    ///      timestamp drift is immaterial at that scale.
    // slither-disable-next-line timestamp
    function isStale() external view returns (bool) {
        return lastUpdated == 0 || block.timestamp > lastUpdated + Config.NAV_STALENESS;
    }

    /// @notice How far NAV may move right now, in bps, before needing a second key.
    function allowedDeviationBps() external view returns (uint256) {
        return _allowedDeviationBps();
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _accept(uint256 nav) private {
        // A live pending deliberately SURVIVES an accepted post, and deliberately is
        // not re-validated against the new anchor.
        //
        // An audit pass argued the opposite: a pending means "this move from THIS
        // anchor is too large to take unilaterally", so once the anchor moves the
        // pending is measured against a price that no longer exists, and confirming it
        // is a larger jump than the budget would have allowed. That is true as stated.
        //
        // It is still the wrong trade. Clearing a pending here hands the keeper a
        // unilateral veto over the second key - posting the current NAV always
        // satisfies the budget, so a compromised keeper cancels every confirmation for
        // free - and PRD §9 names keeper compromise as the worst realistic attack on
        // this protocol. The budget is a rate limit on the keeper ACTING ALONE; the
        // two-key path is meant to be able to exceed it, which is its entire purpose.
        //
        // What bounds the residual is that `confirmNav` takes the price as an explicit
        // argument and reverts on mismatch, so the confirmer ratifies a number they
        // typed rather than whatever is pending, and `NAV_PENDING_EXPIRY` caps how
        // long a stale pending can live. Cancellation stays with the two governance
        // keys via `cancelPendingNav`. Recorded as knowingly accepted, not missed.

        // Freshness tracks when the price last *changed*, not when the keeper last
        // spoke. A zero-delta repost satisfies any budget for any elapsed time, so
        // keying `lastUpdated` off every accepted post let a keeper hold a wrong price
        // indefinitely with `isStale()` never tripping and the second key never
        // consulted - PRD §9 names keeper compromise as the worst realistic attack.
        if (nav != navPerBond) lastUpdated = block.timestamp;

        navPerBond = nav;
        anchorNav = nav;
        anchorAt = block.timestamp;
        emit NAVPosted(nav, block.timestamp);
    }

    function _clearPending() private {
        pendingNav = 0;
        pendingConfirmableAt = 0;
    }

    /// @dev True when `to` differs from `from` by more than `toleranceBps`.
    ///      Cross-multiplied, no division - the same discipline as `_withinBudget`,
    ///      because flooring both sides to whole bps is what made that guard vacuous.
    function _deviatesBeyond(uint256 from, uint256 to, uint256 toleranceBps)
        private
        pure
        returns (bool)
    {
        uint256 delta = to > from ? to - from : from - to;
        return delta * Config.BPS > toleranceBps * from;
    }

    /// @dev The budget test, by cross-multiplication with no division anywhere.
    ///
    ///      Comparing two figures that were each floored to whole basis points was a
    ///      real hole: at `elapsed == 0` the budget floors to 0, and any move smaller
    ///      than `anchorNav / BPS` also floors to 0, so the guard read `0 <= 0` and
    ///      accepted. Because every accepted post re-anchors, those free sub-bps steps
    ///      compounded - enough of them in a single block moved NAV anywhere at all,
    ///      without the second key ever being consulted.
    ///
    ///      `LtvMath.exceedsLtv` avoids division for exactly this reason and says so;
    ///      this is the same discipline applied to the same class of comparison.
    // slither-disable-next-line timestamp
    function _withinBudget(uint256 nav) private view returns (bool) {
        uint256 anchor = anchorNav;
        uint256 delta = nav > anchor ? nav - anchor : anchor - nav;
        uint256 elapsed = block.timestamp - anchorAt;
        if (elapsed > Config.NAV_DEVIATION_MAX_ELAPSED) elapsed = Config.NAV_DEVIATION_MAX_ELAPSED;
        // delta/anchor <= MAX_DEV/BPS * elapsed/WINDOW, cross-multiplied.
        return delta * Config.BPS * Config.NAV_DEVIATION_WINDOW
            <= Config.NAV_MAX_DEVIATION_BPS * elapsed * anchor;
    }

    // slither-disable-next-line timestamp
    function _allowedDeviationBps() private view returns (uint256) {
        uint256 elapsed = block.timestamp - anchorAt;
        if (elapsed > Config.NAV_DEVIATION_MAX_ELAPSED) elapsed = Config.NAV_DEVIATION_MAX_ELAPSED;
        return (Config.NAV_MAX_DEVIATION_BPS * elapsed) / Config.NAV_DEVIATION_WINDOW;
    }
}
