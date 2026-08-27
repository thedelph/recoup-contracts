// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Config} from "../src/Config.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";

/// @notice Drives `setRiskParams` with unconstrained input and asserts the stored set is always
///         legal, and that the liquidation threshold never travels downward.
/// @dev **Why an invariant campaign and not more unit tests.** The unit tests in
///      `RiskParameters.t.sol` pick witnesses, and a witness only proves the thing it was chosen
///      to prove. What the setter actually has to survive is arbitrary calldata arriving through
///      a timelock over a long life, including sets nobody would think to write down. The handler
///      draws from the full width of each field rather than `bound()`ing into the legal region -
///      bounding would prove only that the guard is never *asked*, which is the shape of a
///      vacuous suite this repo has catalogued thirteen times.
///
///      **The campaign's own reach was measured, not assumed, because a tripwire does not settle
///      it.** The thirteenth vacuity shape found here was a branch whose ghost the tripwire read
///      and whose random walk still entered it zero times in forty of forty runs. So the accept
///      path was probed the same way: a temporary invariant asserting `accepted == 0` fails
///      immediately, one asserting `accepted < 100` fails, and one asserting `accepted < 500`
///      passes. The campaign accepts somewhere between 100 and 500 proposals per run over 128,000
///      calls - real coverage of the write path rather than one lucky draw. That is what
///      `proposeNearby` is for; without it a uniform `uint16` draw would essentially never land
///      inside a legal window three hundred basis points wide.
contract RiskParamsHandler is Test {
    RiskParams public immutable riskParams;
    address internal immutable owner;

    /// @notice Coverage ghosts. Every one is asserted non-zero by the tripwire.
    /// @dev A raise and a lower are different transitions with different failure modes, so they
    ///      get different counters. `foundry.toml` sets `fail_on_revert = false`, which means an
    ///      action that always reverts is silently a no-op - a ghost that stayed at zero while the
    ///      suite reported green is exactly how a branch goes untested here.
    uint256 public accepted;
    uint256 public refusedByBound;
    uint256 public refusedByRelation;
    uint256 public refusedAsALoweredThreshold;
    uint256 public thresholdRaises;
    uint256 public capRaises;
    uint256 public capReductions;
    uint256 public ceilingMoves;

    /// @notice Accepted writes that set the threshold below the value it held immediately before
    ///         that same write. The ratchet's entire content, counted per write.
    /// @dev **A handler ghost rather than a `lastThreshold` field on the invariant contract, and
    ///      that is a correctness requirement rather than a style choice.** forge reverts the state
    ///      a non-view `invariant_` function writes: the journal from the invariant call is
    ///      discarded before the next handler call, so a mirror kept on the suite is restored to
    ///      its `setUp` value every time. An invariant written as "compare against what I saw last
    ///      time" therefore degrades silently into "compare against the deploy seed" - which is the
    ///      defect this file was found to have, arrived at a second way.
    ///
    ///      Measured on forge 1.7.1 with a purpose-built probe: an `invariant_` that increments a
    ///      counter and asserts it stays under three passes over 128,000 evaluations. Handler
    ///      storage is part of the fuzzed state and does persist, so the observation must be
    ///      recorded here, where the write happens, and only read from the suite.
    uint256 public thresholdRegressions;
    /// @notice The highest threshold any accepted write has ever set, seeded from the deployed
    ///         value. This is the "previously observed value" the ratchet is quantified against.
    uint256 public highestThresholdAccepted;

    constructor(RiskParams riskParams_, address owner_) {
        riskParams = riskParams_;
        owner = owner_;
        highestThresholdAccepted = riskParams_.liquidationThresholdBps();
    }

    /// @dev Unbounded on purpose. The whole point is that the setter, not the handler, decides
    ///      what is legal.
    function propose(uint16 ltv, uint16 threshold, uint64 global_, uint64 perAccount) external {
        IRiskParams.Params memory before = riskParams.params();
        IRiskParams.Params memory p = IRiskParams.Params({
            maxLtvBps: ltv,
            liquidationThresholdBps: threshold,
            globalBorrowCap: global_,
            perAccountBorrowCap: perAccount
        });

        vm.prank(owner);
        try riskParams.setRiskParams(p) {
            accepted++;
            // The ratchet, observed per accepted write against the value in storage a moment
            // earlier. Recorded rather than asserted: a forge-std assertion inside a handler
            // reverts, and under `fail_on_revert = false` a reverting handler call is discarded -
            // so an in-handler assertion can fail invisibly and truncate the state space at the
            // same time. Counting it and asserting the count from the suite has neither problem.
            if (threshold < before.liquidationThresholdBps) thresholdRegressions++;
            if (threshold > highestThresholdAccepted) highestThresholdAccepted = threshold;
            if (threshold > before.liquidationThresholdBps) thresholdRaises++;
            if (global_ > before.globalBorrowCap || perAccount > before.perAccountBorrowCap) capRaises++;
            if (global_ < before.globalBorrowCap || perAccount < before.perAccountBorrowCap) capReductions++;
            if (ltv != before.maxLtvBps) ceilingMoves++;
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            if (selector == RiskParams.RiskParamOutOfBounds.selector) {
                refusedByBound++;
            } else if (selector == RiskParams.LiquidationThresholdLowered.selector) {
                refusedAsALoweredThreshold++;
            } else {
                // The relation errors. Grouped rather than counted separately because only one of
                // the five is reachable at all - see
                // `RiskParametersTest.test_everyAdmissibleCornerSatisfiesEveryRelation` for the
                // measurement and for which bound subsumes each of the others.
                refusedByRelation++;
            }
        }
    }

    /// @dev A second action that proposes *near* the live values, because a uniform draw over the
    ///      whole `uint16` range almost never lands inside a 300-wide legal window. Without this
    ///      the campaign would refuse essentially everything and `accepted` would sit at zero
    ///      while every invariant passed - green over a setter that was never once exercised.
    function proposeNearby(uint8 nudge, bool up, uint8 which) external {
        IRiskParams.Params memory p = riskParams.params();
        uint256 step = uint256(nudge) + 1;
        if (which % 4 == 0) {
            p.maxLtvBps = up ? _addU16(p.maxLtvBps, step) : _subU16(p.maxLtvBps, step);
        } else if (which % 4 == 1) {
            p.liquidationThresholdBps = up
                ? _addU16(p.liquidationThresholdBps, step)
                : _subU16(p.liquidationThresholdBps, step);
        } else if (which % 4 == 2) {
            p.globalBorrowCap = up ? _addU64(p.globalBorrowCap, step * 1e6) : _subU64(p.globalBorrowCap, step * 1e6);
        } else {
            p.perAccountBorrowCap =
                up ? _addU64(p.perAccountBorrowCap, step * 1e6) : _subU64(p.perAccountBorrowCap, step * 1e6);
        }
        this.propose(p.maxLtvBps, p.liquidationThresholdBps, p.globalBorrowCap, p.perAccountBorrowCap);
    }

    function _addU16(uint16 a, uint256 b) private pure returns (uint16) {
        uint256 sum = uint256(a) + b;
        return sum > type(uint16).max ? type(uint16).max : uint16(sum);
    }

    function _subU16(uint16 a, uint256 b) private pure returns (uint16) {
        return b >= a ? 0 : uint16(uint256(a) - b);
    }

    function _addU64(uint64 a, uint256 b) private pure returns (uint64) {
        uint256 sum = uint256(a) + b;
        return sum > type(uint64).max ? type(uint64).max : uint64(sum);
    }

    function _subU64(uint64 a, uint256 b) private pure returns (uint64) {
        return b >= a ? 0 : uint64(uint256(a) - b);
    }
}

contract RiskParamsInvariants is StdInvariant, Test {
    address internal admin = makeAddr("admin");

    RiskParams internal riskParams;
    RiskParamsHandler internal handler;

    uint256 internal startingThreshold;

    function setUp() public {
        riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            admin
        );
        startingThreshold = riskParams.liquidationThresholdBps();

        handler = new RiskParamsHandler(riskParams, admin);
        targetContract(address(handler));
    }

    /// @notice No handler call may revert. Every action here wraps its interesting call in `try`,
    ///         so a handler *frame* that dies is a fixture fault rather than a meaningless random
    ///         sequence.
    /// @dev **This suite shipped without it and the metric that counts it never noticed.** The
    ///      other five invariant suites have carried this since the round that added it, for the
    ///      reason four of them still state verbatim: a reverting handler frame is discarded, the
    ///      ghost that would have recorded it dies with the frame, and only the runner counting
    ///      frames from outside can see it. The repository's documentation check keyed its coverage
    ///      number on the reachability tripwire alone, so it read six of six on a tree where five
    ///      of six carried the guard - and this suite, the first created after the doctrine
    ///      shipped, is the one it missed. The checker now counts this function too, and rejects it
    ///      if the config line below is not attached to it.
    ///
    ///      Honest note on what it bought here: nothing yet. The campaign was measured at 0 reverts
    ///      and 0 discards over 128,000 calls before this was added, so no frame was being dropped.
    ///      It is here to stop that changing without anyone seeing it, not because it caught
    ///      something.
    ///
    ///      **Verified to take, in this file, rather than assumed from the idiom.** An
    ///      always-reverting action was added to the handler above and the suite run twice, with
    ///      only the config line differing: with it, this fails on the first dropped frame while
    ///      the other three invariants pass over 42,546 reverts; without it, this passes over
    ///      42,598 reverts and reports nothing. A guard that silently does not take is worse than
    ///      none, so that check now rejects the function without the line.
    ///
    ///      Empty body on purpose. The assertion is the config line, enforced by the runner. The
    ///      global `fail_on_revert = false` in `foundry.toml` stays correct for every other
    ///      invariant here and is what lets the `try`/`catch` idiom work at all.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    /// @notice Whatever is stored sits inside the four hard bounds this protocol shipped, and
    ///         inside the two relations that can be stated without restating the auction floor.
    /// @dev **This was a TAUTOLOGY until round-26 remediation, and the docstring that stood here
    ///      argued for the shape that made it one.** It ran `riskParams.checkRiskParams(
    ///      riskParams.params())`: the contract's own validator, against the contract's own
    ///      storage. Both writers run that same validator before assigning, so the assertion
    ///      reduced to "the setter calls the function it calls" and could not fail for any
    ///      definition of legal the validator itself held. Audit round 25, finding 1 executed the
    ///      consequence rather than arguing it: a mutant of `RiskParams` with the `maxLtvBps`
    ///      bound deleted stores `maxLtvBps = 4000` against a shipped ceiling of 3,500 and **all
    ///      four invariants in this file stay green**.
    ///
    ///      The old claim that "a relation added to the validator is covered here for free" was
    ///      the argument for that shape and it is exactly backwards. What a validator run against
    ///      its own output covers for free is itself. It is deleted rather than softened.
    ///
    ///      **So the bounds are literals.** They are the ceilings and floors named in `Config`'s
    ///      risk header and committed to DexFi on 2026-08-06 - 3,500 / 5,800 / 250k / 25k, with
    ///      `Config.MIN_BOUNTIED_DEBT` under both caps - not a reading of `RiskParams`' own
    ///      constants. Those constants are `internal` and cannot be read from here at all, which
    ///      is the accident that keeps this honest: there is no way to write the tautology back in
    ///      by naming a symbol.
    ///
    ///      **What would have to be true for this to pass without measuring anything**: a campaign
    ///      in which no proposal is ever accepted, so storage never leaves the deploy seed and
    ///      every comparison below is evaluated once, at a set the constructor already validated.
    ///      That is the fifteen-times-catalogued shape and it is guarded from outside:
    ///      `test_handlerCanReachEveryStateTheInvariantsCheck` asserts `accepted > 0`, asserts a
    ///      ceiling move, and asserts the high-water threshold rises above the seed.
    ///
    ///      **What is deliberately NOT restated, so nobody reads this as covering the validator.**
    ///      Relations (B), (C) and (E) are absent. Each is implied by the four literal bounds at
    ///      today's `Config.AUCTION_FLOOR_BPS` and `Config.MIN_BOUNTIED_DEBT`: (B) because 5,800 is
    ///      under the 6,800 floor, (C) with 33 bps of margin at that same ceiling, and (E) because
    ///      the per-account floor below **is** `MIN_BOUNTIED_DEBT`. The margin in (C) is pinned in
    ///      `test/RiskParameters.t.sol::test_relationCsMarginIsPinnedAtBothEndsOfTheRatchet`, which
    ///      is where a cut to the auction floor goes red. It would not go red here, and saying so
    ///      is the point: the previous shape claimed coverage of all five and delivered none.
    function invariant_theStoredSetIsAlwaysLegal() public view {
        IRiskParams.Params memory p = riskParams.params();

        // The four hard bounds, as literals. `RiskParams.MAX_LTV_BPS_MIN` and its seven siblings
        // are internal; these are the same numbers written out, which is what makes a mutation to
        // any one of them visible here rather than invisible.
        assertGe(p.maxLtvBps, 500, "stored maxLtvBps fell under the shipped floor of 500");
        assertLe(p.maxLtvBps, 3_500, "stored maxLtvBps passed the shipped ceiling of 3,500");
        assertGe(
            p.liquidationThresholdBps, 5_000, "stored liquidationThresholdBps fell under the shipped floor of 5,000"
        );
        assertLe(
            p.liquidationThresholdBps, 5_800, "stored liquidationThresholdBps passed the ratchet terminus of 5,800"
        );
        assertGe(p.globalBorrowCap, 500e6, "stored globalBorrowCap fell under MIN_BOUNTIED_DEBT");
        assertLe(p.globalBorrowCap, 250_000e6, "stored globalBorrowCap passed the shipped ceiling of 250k");
        assertGe(p.perAccountBorrowCap, 500e6, "stored perAccountBorrowCap fell under MIN_BOUNTIED_DEBT");
        assertLe(p.perAccountBorrowCap, 25_000e6, "stored perAccountBorrowCap passed the shipped ceiling of 25k");

        // Relation (A). A position that is liquidatable the instant it opens is not a loan.
        assertLt(p.maxLtvBps, p.liquidationThresholdBps, "the borrow ceiling reached the liquidation threshold");

        // Relation (D). Equality is legal: one account may hold the entire book.
        assertLe(p.perAccountBorrowCap, p.globalBorrowCap, "the per-account cap passed the global cap");
    }

    /// @notice The liquidation threshold never travels downward, whatever is proposed.
    /// @dev The one guard in this contract that gives up governance power on purpose, so it is
    ///      the one worth quantifying over a campaign rather than a handful of witnesses.
    ///      Lowering it is the only parameter move that makes a healthy position liquidatable in
    ///      the same block.
    ///
    ///      **It used to assert `stored >= startingThreshold`, and that assertion could not fail.**
    ///      `startingThreshold` is `Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS`, which is 5,000, and
    ///      `RiskParams.THRESHOLD_BPS_MIN` is *also* 5,000 - enforced by `checkRiskParams` as a
    ///      bound, before the transition guard ever runs. The bound implied the assertion, so the
    ///      ratchet went unquantified while the docstring above claimed it was the thing being
    ///      quantified. Neuter-verified: a copy of `RiskParams` with exactly the
    ///      `LiquidationThresholdLowered` revert removed passed all three shipped invariants over
    ///      128,000 calls with 0 reverts and 0 discards.
    ///
    ///      **The latent trap, written down because nothing else in the tree carries it.** That old
    ///      assertion was not merely weak, it was weak *by coincidence*. Raise
    ///      `Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS` toward the 5,800 ratchet endpoint - which is
    ///      the whole point of the ratchet, and is expected to happen at least twice - and the
    ///      deploy seed rises above the floor, at which point the old assertion silently acquires
    ///      teeth for the first time. A test whose meaning depends on two unrelated files holding
    ///      the same number is a test nobody can reason about, in either direction.
    ///
    ///      So this asserts the transition instead: per accepted write, against the value storage
    ///      held immediately before that write, recorded by the handler because forge discards
    ///      suite-side writes made from an invariant (see `thresholdRegressions`). The second
    ///      assertion catches a fall produced by any writer, not just by this handler; the
    ///      high-water mark it compares against is proven to rise above the seed by the tripwire.
    function invariant_theLiquidationThresholdNeverFalls() public view {
        assertEq(
            handler.thresholdRegressions(),
            0,
            "an accepted write set the threshold below the value it had a moment earlier"
        );
        assertGe(
            riskParams.liquidationThresholdBps(),
            handler.highestThresholdAccepted(),
            "the threshold fell below a level this campaign had already seen it reach"
        );
    }

    /// @notice The stored caps stay inside the ceilings three other contracts clamp on.
    /// @dev `LenderPool.impair` and `LiquidationAuction._bid` clamp on
    ///      `Config.GLOBAL_BORROW_CAP_MAX` as a compile-time constant, because neither may revert
    ///      and so neither may read this contract. That is only sound while the live cap cannot
    ///      exceed it. This is the assertion that keeps it sound.
    /// @dev **Weak in a way the sibling above no longer is, and the difference is worth stating.**
    ///      `checkRiskParams` enforces `GLOBAL_CAP_MAX`, which *is* `Config.GLOBAL_BORROW_CAP_MAX`,
    ///      as a bound twenty lines above the transition guard - so this cannot fail while the
    ///      setter is the only writer. It is kept as the statement of a cross-contract dependency
    ///      that lives in three files and is enforced in one: if the bound in `RiskParams` is ever
    ///      relaxed away from the constant the other two clamp on, this is what goes red.
    ///
    ///      It overlaps `invariant_theStoredSetIsAlwaysLegal`'s literal `250_000e6` ceiling on
    ///      purpose and the two are not the same assertion. That one says the stored cap is inside
    ///      the number this protocol shipped; this one says it is inside the symbol
    ///      `LenderPool.impair` and `LiquidationAuction._bid` compile against. They are equal
    ///      today. A change to `Config.GLOBAL_BORROW_CAP_MAX` moves this one and leaves that one
    ///      standing, which is the direction that matters: the literal is the commitment, the
    ///      symbol is the clamp.
    function invariant_theLiveCapNeverExceedsTheClampTheOthersUse() public view {
        assertLe(
            riskParams.globalBorrowCap(),
            Config.GLOBAL_BORROW_CAP_MAX,
            "the live cap passed the constant two other contracts clamp on"
        );
    }

    /// @notice The campaign reaches every transition the invariants above quantify over.
    /// @dev Without this the three invariants are green on a setter that refused everything. Each
    ///      ghost is a distinct transition, not a total: an accepted raise and an accepted
    ///      reduction fail differently, and a refusal by bound tells you nothing about a refusal
    ///      by the downward-threshold guard.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        // Drive the shapes directly rather than hoping the fuzzer finds them, then assert the
        // ghosts. A campaign that happens to reach these is not the same as a proof that they are
        // reachable at all.
        IRiskParams.Params memory p = riskParams.params();

        handler.propose(9_999, 9_999, type(uint64).max, type(uint64).max); // out of bounds
        handler.propose(uint16(p.maxLtvBps), 5_400, 50_000e6, 10_000e6); // accepted, raises
        handler.propose(uint16(p.maxLtvBps), 5_200, 50_000e6, 10_000e6); // lowered threshold
        handler.propose(3_000, 5_400, 50_000e6, 5_000e6); // accepted, cap reduction + ceiling move
        handler.propose(3_000, 5_400, 1_000e6, 2_000e6); // per-account above global: relation D

        assertGt(handler.accepted(), 0, "no proposal was ever accepted");
        assertGt(handler.refusedByBound(), 0, "no proposal was refused by a bound");
        assertGt(handler.refusedByRelation(), 0, "relation D was never reached");
        assertGt(handler.refusedAsALoweredThreshold(), 0, "the downward-threshold guard never fired");
        assertGt(handler.thresholdRaises(), 0, "the threshold was never raised");
        assertGt(handler.capRaises(), 0, "no cap was ever raised");
        assertGt(handler.capReductions(), 0, "no cap was ever reduced");
        assertGt(handler.ceilingMoves(), 0, "the borrow ceiling never moved");

        // The ratchet assertion compares against a high-water mark, so it is only worth anything
        // while that mark can leave the deploy seed behind. Asserted here rather than trusted:
        // if it could never rise, `invariant_theLiquidationThresholdNeverFalls` would be the old
        // seed comparison again under a new name.
        assertGt(
            handler.highestThresholdAccepted(),
            startingThreshold,
            "the observed high-water threshold never rose above the deploy seed"
        );
        assertEq(handler.thresholdRegressions(), 0, "a lowering was accepted while driving the shapes");
    }
}
