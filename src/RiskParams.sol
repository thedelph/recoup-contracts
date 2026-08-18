// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRiskParams} from "./interfaces/IRiskParams.sol";
import {Config} from "./Config.sol";

/// @title RiskParams (PRD §5, §9)
/// @notice The four negotiated risk parameters, in bounded storage behind the owner.
/// @dev **Why this contract exists.** The four used to be `internal constant` in `Config`, so
///      changing one meant redeploying every contract that read it. That is the wrong shape for
///      mainnet and it was committed to DexFi on 2026-08-06: settable storage, hard limits baked
///      in, behind a 48 hour timelock, with the setter enforcing the relations rather than
///      trusting anyone to remember them. The ratchet is what makes it load-bearing - four clean
///      epochs with the insurance fund at `Config.INSURANCE_FUND_TARGET_BPS` of debt raises the
///      global cap, four more raises the borrow ceiling - so these values are *designed* to move
///      at least twice more.
///
///      **Why a separate contract rather than storage on `CreditManager`.** Every consumer holds
///      this as an `immutable`, so no consumer can be repointed at a different authority mid-life.
///      Had `CreditManager` owned the storage, a replacement manager would arrive carrying its own
///      constructor seeds - so after a ratchet had moved the book to the PRD figures, a
///      `vault.setCreditManager(B)` would silently revert the entire risk configuration to B's
///      defaults. Rounds 7 and 8 were both two contracts disagreeing about what a pointer meant.
///
///      **This paragraph used to end by rejecting that alternative because its only mitigation
///      "was a deploy-script assertion - a script-level answer to a contract-level defect", and
///      audit round 20 pointed out that the shipped design had exactly that mitigation and nothing
///      else.** `DeployBase._assertCoreGraph` checks all three readers name this contract, and it
///      is a script assertion, so it does not run on a migration - a migration is a bare owner
///      transaction with no script around it. The immutability above binds each consumer to *an*
///      authority; on its own it never bound them to the *same* one, and an ordinary zero-debt
///      manager+auction migration installed a second `RiskParams` through all seven wiring calls
///      with no refusal. Nothing decayed: the objection applied to what shipped from the day it
///      was written, which is the check to run whenever a docstring argues against an alternative.
///
///      The contract-level answer is now in place and is not here: `CollateralVault`'s two wiring
///      setters, `CreditManager.setLiquidationAuction`, `LiquidationAuction.setCreditManager` and
///      the two consumer constructors all refuse a reader that answers a different authority to
///      the vault's. The vault is the reference because it is the only contract in the graph with
///      no replacement path at all. Pinned in `test/RiskPointerAgreement.t.sol`.
///
///      The price of that choice, stated rather than discovered: this contract cannot be fixed
///      without redeploying the three that hold it. Four slots, one setter and five comparisons
///      is a small enough surface to make that bargain on, and it is the same bargain
///      `LiquidationAuction`'s own immutable vault pointer already made.
///
///      **There is no delay in here, deliberately.** The 48 hours comes entirely from the owner
///      being a `TimelockController` constructed with `Config.ADMIN_TIMELOCK`. Ownership is a
///      plain address, so the owner is an EOA while building and a timelock at go-live with no
///      change to this code - `test/Governance.t.sol` proves that handover is a pure
///      `transferOwnership`. A second delay built in here would double the wait and buy nothing.
contract RiskParams is IRiskParams, Ownable {
    error RenounceDisabled();
    error RiskParamOutOfBounds(bytes32 what, uint256 given, uint256 lo, uint256 hi);
    error MaxLtvNotBelowThreshold(uint256 maxLtvBps_, uint256 thresholdBps);
    error ThresholdNotBelowAuctionFloor(uint256 thresholdBps, uint256 floorBps);
    error AuctionFloorCannotCoverThreshold(uint256 requiredFloorBps, uint256 floorBps);
    error PerAccountCapAboveGlobal(uint256 perAccount, uint256 global);
    error PerAccountCapBelowBountiedDebt(uint256 perAccount, uint256 minBountiedDebt);
    error LiquidationThresholdLowered(uint256 from, uint256 to);

    event RiskParamsSet(
        uint256 maxLtvBps,
        uint256 previousMaxLtvBps,
        uint256 liquidationThresholdBps,
        uint256 previousLiquidationThresholdBps,
        uint256 globalBorrowCap,
        uint256 previousGlobalBorrowCap,
        uint256 perAccountBorrowCap,
        uint256 previousPerAccountBorrowCap
    );

    // ── Hard bounds ──────────────────────────────────────────────────────────
    //
    // These are the "hard limits baked in" half of the commitment, and they are not settable by
    // anyone. They live here rather than in `Config` because they are this setter's validation
    // domain rather than protocol parameters: nothing else reads them, and `Config` is the file
    // the webapp's mirror check parses, so adding eight names there would widen that surface for
    // no benefit. `CreditManager.ACC_PRECISION` sets the same precedent.
    //
    // **The ceilings are the ratchet's terminus, in bytecode.** `Config`'s risk header names
    // 3500 / 5800 / 250k / 25k as the PRD's original figures and the destination the capped-beta
    // settings expand back towards. Governance can walk the whole path and cannot walk past it:
    // going beyond what was agreed with DexFi needs a redeploy, which is a conversation rather
    // than a transaction, and it is checkable by them from the bytecode.

    uint256 internal constant MAX_LTV_BPS_MIN = 500;
    uint256 internal constant MAX_LTV_BPS_MAX = 3_500;

    /// @dev **The floor is the load-bearing bound, and it is a deliberate reduction of governance
    ///      power.** The threshold may be raised and never lowered.
    ///
    ///      Lowering it is the only parameter move in this protocol that makes a previously
    ///      healthy position liquidatable in the same block, with no grace period and no notice.
    ///      `liquidate` is permissionless and the check is a pure comparison, so there is nowhere
    ///      to hang a per-position timestamp; a grace mechanism would be a design of its own.
    ///
    ///      It costs governance nothing it actually needs. This protocol separates the borrow
    ///      ceiling from the liquidation trigger - the same separation Compound III makes for
    ///      exactly this reason - so every tightening lever sits on the borrow side, where
    ///      lowering `maxLtvBps` or either cap refuses new debt and, through
    ///      `CollateralVault.withdrawBonds`, refuses collateral withdrawals, but cannot seize
    ///      anyone. Aave lowers thresholds under governance and accepts the liquidations; this
    ///      protocol has no mechanism to soften that and should not pretend otherwise.
    ///
    ///      If a lower threshold is ever genuinely needed, it is a redeploy. A risk change that
    ///      instantly liquidates users should cost more than forty-eight hours.
    uint256 internal constant THRESHOLD_BPS_MIN = 5_000;
    uint256 internal constant THRESHOLD_BPS_MAX = 5_800;

    /// @dev Floored at `MIN_BOUNTIED_DEBT` rather than at zero, and the reason is a vacuity one
    ///      rather than a safety one. `Config.t.sol` already records it: a cap under that
    ///      threshold means no position can ever be bountied, every consumer of the bounty ships
    ///      untested, and the suite reports green over a quantity that is always zero.
    /// @dev The ceiling is `Config.GLOBAL_BORROW_CAP_MAX` rather than a literal here, because
    ///      `LenderPool.impair` and `LiquidationAuction._bid` clamp on the same number and must do
    ///      so as a compile-time constant - neither may revert, so neither may read this contract.
    ///      One definition, enforced here as a bound and used there as an overflow guard.
    uint256 internal constant GLOBAL_CAP_MIN = Config.MIN_BOUNTIED_DEBT;
    uint256 internal constant GLOBAL_CAP_MAX = Config.GLOBAL_BORROW_CAP_MAX;

    uint256 internal constant PER_ACCOUNT_CAP_MIN = Config.MIN_BOUNTIED_DEBT;
    uint256 internal constant PER_ACCOUNT_CAP_MAX = 25_000e6;

    Params private _p;

    /// @dev Seeded from `Config`'s declared defaults by the deploy script, then validated by the
    ///      same function every later write goes through. A constructor that skipped the check
    ///      could ship a live protocol in a state its own setter would refuse.
    constructor(Params memory initial, address initialOwner) Ownable(initialOwner) {
        checkRiskParams(initial);
        _p = initial;
        emit RiskParamsSet(
            initial.maxLtvBps,
            0,
            initial.liquidationThresholdBps,
            0,
            initial.globalBorrowCap,
            0,
            initial.perAccountBorrowCap,
            0
        );
    }

    // ── Reads ────────────────────────────────────────────────────────────────

    /// @inheritdoc IRiskParams
    function params() external view returns (Params memory) {
        return _p;
    }

    /// @inheritdoc IRiskParams
    function maxLtvBps() external view returns (uint256) {
        return _p.maxLtvBps;
    }

    /// @inheritdoc IRiskParams
    function liquidationThresholdBps() external view returns (uint256) {
        return _p.liquidationThresholdBps;
    }

    /// @inheritdoc IRiskParams
    function globalBorrowCap() external view returns (uint256) {
        return _p.globalBorrowCap;
    }

    /// @inheritdoc IRiskParams
    function perAccountBorrowCap() external view returns (uint256) {
        return _p.perAccountBorrowCap;
    }

    // ── Validation ───────────────────────────────────────────────────────────

    /// @inheritdoc IRiskParams
    /// @dev The five relations `test/Config.t.sol` used to assert about constants. They were
    ///      compile-time facts; the moment the values moved into storage every one of them became
    ///      a runtime check that did not exist. This is that check.
    function checkRiskParams(Params memory p) public pure {
        if (p.maxLtvBps < MAX_LTV_BPS_MIN || p.maxLtvBps > MAX_LTV_BPS_MAX) {
            revert RiskParamOutOfBounds("maxLtvBps", p.maxLtvBps, MAX_LTV_BPS_MIN, MAX_LTV_BPS_MAX);
        }
        if (p.liquidationThresholdBps < THRESHOLD_BPS_MIN || p.liquidationThresholdBps > THRESHOLD_BPS_MAX) {
            revert RiskParamOutOfBounds(
                "liquidationThresholdBps", p.liquidationThresholdBps, THRESHOLD_BPS_MIN, THRESHOLD_BPS_MAX
            );
        }
        if (p.globalBorrowCap < GLOBAL_CAP_MIN || p.globalBorrowCap > GLOBAL_CAP_MAX) {
            revert RiskParamOutOfBounds("globalBorrowCap", p.globalBorrowCap, GLOBAL_CAP_MIN, GLOBAL_CAP_MAX);
        }
        if (p.perAccountBorrowCap < PER_ACCOUNT_CAP_MIN || p.perAccountBorrowCap > PER_ACCOUNT_CAP_MAX) {
            revert RiskParamOutOfBounds(
                "perAccountBorrowCap", p.perAccountBorrowCap, PER_ACCOUNT_CAP_MIN, PER_ACCOUNT_CAP_MAX
            );
        }

        // (A) A position that is liquidatable the instant it opens is not a loan. Checked here
        //     rather than in a per-field setter because either field can cross the other, and a
        //     guard on only one of them lets the second walk down through it.
        if (p.maxLtvBps >= p.liquidationThresholdBps) {
            revert MaxLtvNotBelowThreshold(p.maxLtvBps, p.liquidationThresholdBps);
        }

        // (B) A floor-price fill must at least reach the trigger. Strictly weaker than (C) below,
        //     and kept anyway: it is the relation a reader expects to find, and its absence would
        //     read as an omission rather than as a consequence.
        if (p.liquidationThresholdBps >= Config.AUCTION_FLOOR_BPS) {
            revert ThresholdNotBelowAuctionFloor(p.liquidationThresholdBps, Config.AUCTION_FLOOR_BPS);
        }

        // (C) The relation `Config`'s own header warns about: a floor-price fill must cover debt
        //     plus the liquidation penalty even at the worst LTV that can first trigger a
        //     liquidation, which is one immediate maximum NAV drop applied to a position sitting
        //     on the threshold.
        //
        //     **Derived, never hardcoded.** `Config`'s auction-floor header used to work this
        //     through to a single figure (5833) against the values of the day; it now states the
        //     derivation and nothing else, for the reason below. The worst drop is what `NAVOracle`
        //     actually accepts without a second key, which is the deviation budget prorated over
        //     the maximum elapsed window - not `NAV_MAX_DEVIATION_BPS` directly. Those were the
        //     same number until `NAV_DEVIATION_MAX_ELAPSED` was introduced, at which point the real
        //     bound tripled and the guard test kept passing because it was pinned to the
        //     assumption rather than to the behaviour. `Config.t.sol` records that; this derives it
        //     for the same reason.
        //
        //     **How much room there actually is, as a derivation rather than as a number.** The
        //     margin is `AUCTION_FLOOR_BPS - minimumAuctionFloorFor(threshold)`, and the threshold
        //     is the one input that is *designed to move*, so the margin has to be read at the
        //     ratchet's terminus (`THRESHOLD_BPS_MAX`) and not at whatever the book happens to sit
        //     on today. Reading it at today's value is how three sites in this repo came to state
        //     three different figures for one quantity. Both ends are pinned in
        //     `test/RiskParameters.t.sol`, so the numbers live where a change makes them fail
        //     rather than in prose where a change makes them stale.
        //
        //     Note this binds in both directions. Against the current 6800 floor the highest
        //     threshold this clause alone admits is only a little above `THRESHOLD_BPS_MAX`, so
        //     the endpoint is reachable but not comfortably - and `AUCTION_FLOOR_BPS` is under
        //     live negotiation with DexFi and has been offered to them as a *raise*. A modest
        //     *reduction* would put the agreed endpoint permanently out of reach through this
        //     function. Nothing else in the tree connects those two decisions.
        if (!auctionFloorCoversThreshold(p.liquidationThresholdBps, Config.AUCTION_FLOOR_BPS)) {
            revert AuctionFloorCannotCoverThreshold(
                minimumAuctionFloorFor(p.liquidationThresholdBps), Config.AUCTION_FLOOR_BPS
            );
        }

        // (D) Equality is legal: one account may hold the entire book.
        if (p.perAccountBorrowCap > p.globalBorrowCap) {
            revert PerAccountCapAboveGlobal(p.perAccountBorrowCap, p.globalBorrowCap);
        }

        // (E) The vacuity guard again, as a relation rather than a bound. Both are kept because
        //     they fail for different reasons and a reader should be able to see which.
        if (Config.MIN_BOUNTIED_DEBT > p.perAccountBorrowCap) {
            revert PerAccountCapBelowBountiedDebt(p.perAccountBorrowCap, Config.MIN_BOUNTIED_DEBT);
        }
    }

    // ── Relation (C), as its own predicate ───────────────────────────────────

    /// @notice True when a floor-price fill at `floorBps` covers debt plus the liquidation penalty
    ///         at the worst LTV a liquidation can first trigger at, for `thresholdBps`.
    /// @dev **Cross-multiplied, no division anywhere, and that is the whole point of this
    ///      function.** The requirement is
    ///
    ///        maxDrop  = MD * ME / W                                  (fraction of collateral)
    ///        worstLtv = threshold * BPS / (BPS - maxDrop)
    ///        required = worstLtv * (BPS + PENALTY) / BPS
    ///
    ///      and the version this replaced evaluated it as written, in three integer steps. Every
    ///      one of those steps floored, and every floor moved the requirement *down* - the unsafe
    ///      direction, because a smaller requirement admits a higher threshold. Measured over the
    ///      admissible range: it understated at **756 of 801** thresholds, by up to **1.833 bps**
    ///      against the exact real requirement (2 whole bps once that is rounded up to a floor a
    ///      constant can actually hold), and it **never** overstated. Against a 6000 floor it
    ///      admitted 5144 where 5142 is the last threshold exactly permitted, and a floor-price
    ///      fill at 5144 leaves the debt short. Both figures re-derived here rather than
    ///      transcribed, and both reproduced round 20's to the digit.
    ///
    ///      Substituting and clearing every denominator gives, exactly:
    ///
    ///        floorBps * (BPS * W - MD * ME)  >=  threshold * (BPS + PENALTY) * W
    ///
    ///      Both sides stay under 1e13 at every legal value, so there is nothing to overflow and
    ///      nothing to round. `LtvMath.exceedsLtv` and `NAVOracle._withinBudget` are the same
    ///      discipline applied to the same class of comparison, and both say why: flooring both
    ///      sides of a comparison to whole basis points is what made one of them vacuous.
    ///
    ///      `BPS * W - MD * ME` cannot underflow. It is a constant expression, and `Config.t.sol`
    ///      asserts both facts that keep it positive - `NAV_MAX_DEVIATION_BPS < BPS` and
    ///      `NAV_DEVIATION_MAX_ELAPSED <= NAV_DEVIATION_WINDOW`.
    ///
    /// @dev **The floor is a parameter rather than read from `Config`, deliberately.** The guard
    ///      itself is only ever called with `Config.AUCTION_FLOOR_BPS`, but the floor is under live
    ///      negotiation with DexFi and could come back as a cut, and this clause binds in both
    ///      directions. A predicate that hardcoded today's floor could not be measured against
    ///      tomorrow's without a second copy of it existing somewhere - and a second copy of this
    ///      arithmetic agreeing with itself is exactly why the flooring above survived a full
    ///      suite. There is one implementation, and the tests drive it across a grid of floors.
    function auctionFloorCoversThreshold(uint256 thresholdBps, uint256 floorBps) public pure returns (bool) {
        uint256 denominator = Config.BPS * Config.NAV_DEVIATION_WINDOW
            - Config.NAV_MAX_DEVIATION_BPS * Config.NAV_DEVIATION_MAX_ELAPSED;
        uint256 numerator =
            thresholdBps * (Config.BPS + Config.LIQUIDATION_PENALTY_BPS) * Config.NAV_DEVIATION_WINDOW;
        return floorBps * denominator >= numerator;
    }

    /// @notice The smallest whole-bps auction floor that satisfies relation (C) at `thresholdBps`.
    /// @dev Reported in `AuctionFloorCannotCoverThreshold` so the revert names the value that would
    ///      have worked, and public because modelling a floor change is a live commercial question
    ///      rather than a hypothetical one.
    ///
    ///      Rounded **up**, exactly once. A requirement of 6766.67 bps is not met by a floor of
    ///      6766, so the ceiling is the answer and the floor is the bug this pair was written to
    ///      close. `floorBps >= minimumAuctionFloorFor(t)` and `auctionFloorCoversThreshold(t,
    ///      floorBps)` are therefore the same predicate in two shapes; `RiskParameters.t.sol`
    ///      asserts they agree, and agree with an exact rational reference, at every point of a
    ///      40,851 point grid - which is what stops the division here drifting away from the
    ///      division-free comparison above.
    function minimumAuctionFloorFor(uint256 thresholdBps) public pure returns (uint256) {
        uint256 denominator = Config.BPS * Config.NAV_DEVIATION_WINDOW
            - Config.NAV_MAX_DEVIATION_BPS * Config.NAV_DEVIATION_MAX_ELAPSED;
        uint256 numerator =
            thresholdBps * (Config.BPS + Config.LIQUIDATION_PENALTY_BPS) * Config.NAV_DEVIATION_WINDOW;
        return (numerator + denominator - 1) / denominator;
    }

    // ── The setter ───────────────────────────────────────────────────────────

    /// @notice Replace the whole risk configuration.
    /// @dev **One batched setter rather than four, and the reason is ordering.** Every relation
    ///      must hold after each individual write, so with per-field setters some legal end states
    ///      are unreachable except through an illegal intermediate: a ratchet step that raises the
    ///      ceiling and the threshold together must raise the threshold first, or (A) refuses.
    ///      Under a timelock that ordering is not something the caller controls - the governance
    ///      harness deploys with an open executor set, so two scheduled operations' windows can be
    ///      executed in either order once both have matured. A single call has no intermediate.
    ///
    ///      It also means one event, one atomic state, and one proposal whose calldata shows the
    ///      entire risk surface to anyone reviewing it during the forty-eight hours. Restating all
    ///      four on every move is a feature under a timelock, not a cost.
    ///
    ///      **No pause bracket.** `_wirePhase4` in the deploy script brackets its switchover
    ///      because a broadcast emits one transaction per external call, so a three-call pointer
    ///      move has a real gap for something to observe half of. This is one transaction writing
    ///      one slot, and all three consumers read this contract, so they cannot disagree even for
    ///      a block. **That last clause is a property of the wiring, not of this function** - it
    ///      holds because the wiring setters enforce it (see the header, and audit round 20), not
    ///      because a single `SSTORE` implies it. Nor is there a live-work guard: refusing while an
    ///      auction is open would be
    ///      unsatisfiable-shaped, because nobody can be compelled to `cancel`, so a stranger
    ///      holding one lot open would hold governance shut indefinitely. That deadlock has been
    ///      hit three times in this codebase and is recorded rather than rebuilt.
    ///
    ///      One consequence is documented rather than guarded: raising the threshold makes
    ///      currently liquidatable positions healthy, so a bid already in flight reverts when
    ///      `seize` re-checks. The whole transaction reverts, no funds move, the bidder loses gas,
    ///      and `cancel` - permissionless, and it returns the borrower's prepaid bounty - becomes
    ///      the correct exit. That is the right outcome: the position is genuinely healthy.
    function setRiskParams(Params calldata p) external onlyOwner {
        Params memory prev = _p;

        checkRiskParams(p);

        // A transition check, not a bound, and it is deliberately redundant with
        // `THRESHOLD_BPS_MIN`. The bound says where the threshold may sit; this says which way it
        // may travel. Keeping both means the intent survives someone later editing the constant
        // for a reason that looks good in isolation.
        if (p.liquidationThresholdBps < prev.liquidationThresholdBps) {
            revert LiquidationThresholdLowered(prev.liquidationThresholdBps, p.liquidationThresholdBps);
        }

        _p = p;

        emit RiskParamsSet(
            p.maxLtvBps,
            prev.maxLtvBps,
            p.liquidationThresholdBps,
            prev.liquidationThresholdBps,
            p.globalBorrowCap,
            prev.globalBorrowCap,
            p.perAccountBorrowCap,
            prev.perAccountBorrowCap
        );
    }

    /// @dev Renouncing would freeze the risk configuration at whatever it happened to hold, on a
    ///      contract three immutable pointers depend on. There would be no way back short of
    ///      redeploying the protocol.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
