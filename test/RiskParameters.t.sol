// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";

/// @notice The four negotiated risk parameters, as bounded storage rather than constants.
///
///         Two things are being tested here that a constant could never be tested for. The
///         relations used to be compile-time facts asserted in `Config.t.sol`; a `pure` assertion
///         about a constant says nothing about a stored value, so each one had to become a runtime
///         check and each runtime check needs both of its sides exercised. And the ratchet agreed
///         with DexFi is now something the protocol either can or cannot express - a question with
///         an answer, which is what the first test below asks.
contract RiskParametersTest is Test {
    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal outsider = makeAddr("outsider");

    RiskParams internal riskParams;
    TimelockController internal timelock;

    // The PRD's original launch figures, which are also the far end of the ratchet. Written out
    // here rather than read from the contract because this is the commitment being tested, and a
    // test that read the ceiling from the thing it is checking would agree with any ceiling.
    uint16 internal constant RATCHET_END_MAX_LTV = 3_500;
    uint16 internal constant RATCHET_END_THRESHOLD = 5_800;
    uint64 internal constant RATCHET_END_GLOBAL_CAP = 250_000e6;
    uint64 internal constant RATCHET_END_PER_ACCOUNT_CAP = 25_000e6;

    function setUp() public {
        riskParams = new RiskParams(_defaults(), admin);

        // The shape that would actually be deployed, matching the governance harness: one
        // proposer (a Safe in production), open execution, and no standalone admin.
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _defaults() internal pure returns (IRiskParams.Params memory) {
        return IRiskParams.Params({
            maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
            liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
            globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
            perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
        });
    }

    function _live() internal view returns (IRiskParams.Params memory) {
        return riskParams.params();
    }

    function _set(IRiskParams.Params memory p) internal {
        vm.prank(admin);
        riskParams.setRiskParams(p);
    }

    function _handOver() internal {
        vm.prank(admin);
        riskParams.transferOwnership(address(timelock));
    }

    /// @dev Returns the operation id, which `cancel` needs. Computed *after* the scheduling call,
    ///      not before: `vm.prank` is spent on the next call including a staticcall, so a
    ///      `hashOperation` read between the prank and the `schedule` would eat the prank and the
    ///      schedule would arrive unpranked. That trap is recorded in this repo twice.
    function _schedule(bytes memory data) internal returns (bytes32 id) {
        vm.prank(proposer);
        timelock.schedule(address(riskParams), 0, data, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        id = timelock.hashOperation(address(riskParams), 0, data, bytes32(0), bytes32(0));
    }

    function _execute(bytes memory data) internal {
        timelock.execute(address(riskParams), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev The smallest whole-bps auction floor that covers debt plus penalty at the worst LTV a
    ///      liquidation can first trigger at.
    ///
    ///      **An independent reference, and the previous version of this helper is the reason the
    ///      suite could not see round 20's finding.** It read "derived exactly as the contract
    ///      derives it" and it meant it literally: three integer divisions, in the same order, with
    ///      the same three floors. A reference that is a transcription of the implementation agrees
    ///      with a wrong implementation by construction, so every test built on it stayed green
    ///      while the contract admitted thresholds a floor-price fill could not cover.
    ///
    ///      This computes the same quantity a different way: every step is carried as an exact
    ///      fraction in the order the derivation is *written*, and the result is rounded exactly
    ///      once, at the end, upward. No algebra is shared with the contract - the contract clears
    ///      all three denominators into a single cross-multiplied comparison, this one composes the
    ///      three fractions and divides last. They agree only if both are right.
    ///
    ///        maxDrop  = MD * ME / W                                (fraction of collateral value)
    ///        worstLtv = threshold * BPS / (BPS - maxDrop)
    ///        required = worstLtv * (BPS + PENALTY) / BPS
    ///
    ///      Rounded up because the requirement is a lower bound on the floor: a requirement of
    ///      6766.67 bps is not satisfied by a floor of 6766.
    function _requiredFloorFor(uint256 thresholdBps) internal pure returns (uint256) {
        // maxDrop, as the exact fraction dropNum / dropDen.
        uint256 dropNum = Config.NAV_MAX_DEVIATION_BPS * Config.NAV_DEVIATION_MAX_ELAPSED;
        uint256 dropDen = Config.NAV_DEVIATION_WINDOW;

        // BPS - maxDrop, over the same denominator. Positive: `Config.t.sol` asserts both
        // `NAV_MAX_DEVIATION_BPS < BPS` and `NAV_DEVIATION_MAX_ELAPSED <= NAV_DEVIATION_WINDOW`.
        uint256 headroomNum = Config.BPS * dropDen - dropNum;

        // worstLtv = threshold * BPS / (headroomNum / dropDen), still exact.
        uint256 worstNum = thresholdBps * Config.BPS * dropDen;
        uint256 worstDen = headroomNum;

        // required = worstLtv * (BPS + PENALTY) / BPS, still exact.
        uint256 num = worstNum * (Config.BPS + Config.LIQUIDATION_PENALTY_BPS);
        uint256 den = worstDen * Config.BPS;

        // The one and only rounding, and it goes up.
        return (num + den - 1) / den;
    }

    /// @dev The helper this replaced, kept verbatim so the finding can be *demonstrated* rather
    ///      than described. It is never used as a reference again - only as the subject of
    ///      `test_theOldRequiredFloorHelperAgreedWithTheWrongAnswer`, which is the whole evidence
    ///      that a reference copied from the implementation cannot fail with it.
    function _requiredFloorFor_flooredCopy(uint256 thresholdBps) internal pure returns (uint256) {
        uint256 maxDropBps =
            (Config.NAV_MAX_DEVIATION_BPS * Config.NAV_DEVIATION_MAX_ELAPSED) / Config.NAV_DEVIATION_WINDOW;
        uint256 worstTriggerLtv = (thresholdBps * Config.BPS) / (Config.BPS - maxDropBps);
        return (worstTriggerLtv * (Config.BPS + Config.LIQUIDATION_PENALTY_BPS)) / Config.BPS;
    }

    // ── the ratchet ──────────────────────────────────────────────────────────

    /// @notice The whole ratchet lands as ONE scheduled timelock operation.
    /// @dev **Written before the setter, because it could have invalidated its design.** The five
    ///      relations must hold after every write. With one setter per field, a step that raises
    ///      both the ceiling and the threshold has no legal ordering - raise the ceiling first and
    ///      it crosses the old threshold, raise the threshold first and nothing refuses it but the
    ///      two moves are separate operations whose 48 hour windows an open executor set can run
    ///      in either order. A batched setter has no intermediate state to be illegal.
    ///
    ///      It lands the PRD's full end state rather than a token step, because that is the
    ///      commitment: four clean epochs raise the global cap, four more raise the borrow
    ///      ceiling, back towards 3500 / 5800 / 250k / 25k. A test that moved one parameter by one
    ///      basis point would prove the setter works and say nothing about whether the promise is
    ///      reachable.
    function test_theRatchetStepIsExpressibleAsOneScheduledOperation() public {
        _handOver();

        IRiskParams.Params memory end = IRiskParams.Params({
            maxLtvBps: RATCHET_END_MAX_LTV,
            liquidationThresholdBps: RATCHET_END_THRESHOLD,
            globalBorrowCap: RATCHET_END_GLOBAL_CAP,
            perAccountBorrowCap: RATCHET_END_PER_ACCOUNT_CAP
        });
        bytes memory data = abi.encodeCall(IRiskParams.setRiskParams, (end));

        _schedule(data);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _execute(data);

        IRiskParams.Params memory got = _live();
        assertEq(got.maxLtvBps, RATCHET_END_MAX_LTV, "max LTV did not reach the ratchet's end");
        assertEq(got.liquidationThresholdBps, RATCHET_END_THRESHOLD, "threshold did not reach the end");
        assertEq(got.globalBorrowCap, RATCHET_END_GLOBAL_CAP, "global cap did not reach the end");
        assertEq(got.perAccountBorrowCap, RATCHET_END_PER_ACCOUNT_CAP, "per-account cap did not reach the end");
    }

    /// @notice The ratchet's stated end state is inside every hard bound.
    /// @dev Separate from the test above on purpose. That one proves the *mechanism* can express
    ///      the step; this one proves the *bounds* admit the destination. A ceiling set one basis
    ///      point under the agreed figure would leave the first test passing right up until the
    ///      final step and then refuse it, forty-eight hours at a time.
    function test_theRatchetsEndStateIsAdmissible() public view {
        riskParams.checkRiskParams(
            IRiskParams.Params({
                maxLtvBps: RATCHET_END_MAX_LTV,
                liquidationThresholdBps: RATCHET_END_THRESHOLD,
                globalBorrowCap: RATCHET_END_GLOBAL_CAP,
                perAccountBorrowCap: RATCHET_END_PER_ACCOUNT_CAP
            })
        );
    }

    /// @notice Each ratchet step in turn is legal, in the order the agreement states.
    /// @dev The cap moves first, then the ceiling in two stages. Executed one after another
    ///      against live storage rather than checked in isolation, because the transition guard on
    ///      the threshold means a legal state is not the same thing as a reachable one.
    function test_everyRatchetStepIsLegalInTheAgreedOrder() public {
        IRiskParams.Params memory p = _live();

        p.globalBorrowCap = RATCHET_END_GLOBAL_CAP;
        p.perAccountBorrowCap = RATCHET_END_PER_ACCOUNT_CAP;
        _set(p);
        assertEq(_live().globalBorrowCap, RATCHET_END_GLOBAL_CAP, "cap raise refused");

        p.liquidationThresholdBps = RATCHET_END_THRESHOLD;
        _set(p);

        p.maxLtvBps = 3_000;
        _set(p);
        assertEq(_live().maxLtvBps, 3_000, "first ceiling step refused");

        p.maxLtvBps = RATCHET_END_MAX_LTV;
        _set(p);
        assertEq(_live().maxLtvBps, RATCHET_END_MAX_LTV, "second ceiling step refused");
    }

    // ── what the constructor wrote ───────────────────────────────────────────

    function test_deployedDefaultsEqualTheDeclaredDefaults() public view {
        IRiskParams.Params memory p = _live();
        assertEq(p.maxLtvBps, Config.DEFAULT_MAX_LTV_BPS, "max LTV seed");
        assertEq(p.liquidationThresholdBps, Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS, "threshold seed");
        assertEq(p.globalBorrowCap, Config.DEFAULT_GLOBAL_BORROW_CAP, "global cap seed");
        assertEq(p.perAccountBorrowCap, Config.DEFAULT_PER_ACCOUNT_BORROW_CAP, "per-account cap seed");
    }

    /// @dev The five relations, read from the deployed contract rather than from constants. This
    ///      is what the old `pure` versions could not say: that the *constructor* wrote a legal
    ///      set, not merely that the source declared one.
    function test_deployedRelationsHoldAtConstruction() public view {
        IRiskParams.Params memory p = _live();
        assertLt(p.maxLtvBps, p.liquidationThresholdBps, "A: ceiling must sit under the trigger");
        assertLt(p.liquidationThresholdBps, Config.AUCTION_FLOOR_BPS, "B: trigger must sit under the floor");
        assertGe(
            Config.AUCTION_FLOOR_BPS,
            _requiredFloorFor(p.liquidationThresholdBps),
            "C: floor must cover debt plus penalty at the worst first trigger"
        );
        assertLe(p.perAccountBorrowCap, p.globalBorrowCap, "D: per-account cannot exceed global");
        assertLe(Config.MIN_BOUNTIED_DEBT, p.perAccountBorrowCap, "E: the bounty must be reachable");
    }

    /// @dev A constructor that skipped validation could ship a live protocol in a state its own
    ///      setter would refuse, which is a difference nobody would notice until the first attempt
    ///      to change anything.
    function test_theConstructorRefusesAnIllegalSet() public {
        IRiskParams.Params memory bad = _defaults();
        // Out of bounds rather than relation-violating, because the bounds are the tighter
        // constraint - see the corner test above for why no relation is reachable on its own.
        bad.maxLtvBps = 3_501;
        vm.expectRevert(
            abi.encodeWithSelector(RiskParams.RiskParamOutOfBounds.selector, bytes32("maxLtvBps"), 3_501, 500, 3_500)
        );
        new RiskParams(bad, admin);
    }

    // ── which relations can actually fire, measured rather than assumed ──────

    /// @notice Four of the five relations cannot fire, because the hard bounds are strictly
    ///         tighter than they are. This asserts that, rather than pretending otherwise.
    /// @dev **Found by writing the boundary tests and watching them fail with the wrong error.**
    ///      The first drafts of this file tried to drive `maxLtvBps` up to the stored threshold to
    ///      trip relation (A). It never gets there: `maxLtvBps` is capped at 3500 and
    ///      `liquidationThresholdBps` floored at 5000, so the two ranges do not overlap and the
    ///      bound refuses first. The same is true of (B) and (C), which need a threshold above
    ///      5830-odd against a ceiling of 5800, and of (E), whose floor under `perAccountBorrowCap`
    ///      is the very quantity it compares against.
    ///
    ///      A test asserting "(A) rejects a ceiling at the threshold" would pass. It would pass
    ///      because a different check rejected it, several hundred basis points earlier, which is
    ///      a test about the wrong mechanism wearing the right name.
    ///
    ///      Keeping the relations is still correct: they are defence in depth against exactly one
    ///      thing, someone widening a bound later, and that is the day they stop being dormant.
    ///      So the property worth asserting is not either side of an unreachable boundary. It is
    ///      **that the admissible box implies every relation** - checked at all sixteen corners
    ///      below, which is where a box violates a linear relation if it violates one at all. Widen
    ///      any bound far enough and this fails, which is the signal to come back and write the
    ///      boundary tests that would by then be real.
    function test_everyAdmissibleCornerSatisfiesEveryRelation() public view {
        uint16[2] memory ltv = [uint16(500), uint16(3_500)];
        uint16[2] memory thr = [uint16(5_000), uint16(5_800)];
        uint64[2] memory glob = [uint64(Config.MIN_BOUNTIED_DEBT), uint64(Config.GLOBAL_BORROW_CAP_MAX)];
        uint64[2] memory acct = [uint64(Config.MIN_BOUNTIED_DEBT), uint64(25_000e6)];

        for (uint256 a = 0; a < 2; a++) {
            for (uint256 b = 0; b < 2; b++) {
                for (uint256 c = 0; c < 2; c++) {
                    for (uint256 d = 0; d < 2; d++) {
                        // The one corner the box admits and relation (D) does not: the largest
                        // per-account cap against the smallest global one. It is genuinely
                        // reachable, which is why (D) is the only relation with a real boundary
                        // test in this file.
                        if (acct[d] > glob[c]) continue;
                        riskParams.checkRiskParams(
                            IRiskParams.Params({
                                maxLtvBps: ltv[a],
                                liquidationThresholdBps: thr[b],
                                globalBorrowCap: glob[c],
                                perAccountBorrowCap: acct[d]
                            })
                        );
                    }
                }
            }
        }
    }

    /// @dev The specific subsumption, named so a future reader does not have to re-derive it: the
    ///      borrow ceiling's maximum sits below the liquidation trigger's minimum, so relation (A)
    ///      is unreachable for as long as that holds. If this ever fails, (A) has become live and
    ///      needs both sides of its boundary tested.
    function test_theBorrowCeilingsMaximumIsBelowTheTriggersMinimum() public pure {
        assertLt(uint256(3_500), uint256(5_000), "relation A is now reachable and needs a real boundary test");
    }

    /// @dev Same, for relation (E). The floor under `perAccountBorrowCap` *is* `MIN_BOUNTIED_DEBT`,
    ///      so no admissible cap can sit under it and (E) can never fire.
    function test_thePerAccountFloorIsTheBountyThresholdItself() public {
        IRiskParams.Params memory p = _live();
        p.perAccountBorrowCap = uint64(Config.MIN_BOUNTIED_DEBT);
        _set(p);
        assertEq(
            _live().perAccountBorrowCap,
            Config.MIN_BOUNTIED_DEBT,
            "relation E is now reachable and needs a real boundary test"
        );
    }

    /// @dev The other side of relation (A)'s intent, which the *transition* guard delivers rather
    ///      than the relation: a threshold-only move cannot walk down through the ceiling, because
    ///      it cannot walk down at all.
    function test_setThreshold_cannotBeLoweredThroughTheStoredCeiling() public {
        IRiskParams.Params memory p = _live();
        p.maxLtvBps = 3_000;
        p.liquidationThresholdBps = 5_200;
        _set(p);

        p.liquidationThresholdBps = 2_900; // under the ceiling, and downward
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskParams.RiskParamOutOfBounds.selector, bytes32("liquidationThresholdBps"), 2_900, 5_000, 5_800
            )
        );
        riskParams.setRiskParams(p);
    }

    // ── the threshold floor: the deliberate reduction of governance power ────

    /// @notice The liquidation threshold can be raised and never lowered.
    /// @dev The single most consequential rule in this contract. Lowering the threshold is the
    ///      only parameter move that makes a previously healthy position liquidatable in the same
    ///      block, with no grace period - `liquidate` is permissionless and the check is a pure
    ///      comparison, so there is nowhere to hang a per-position timestamp.
    function test_setThreshold_cannotBeLoweredEvenWithinBounds() public {
        IRiskParams.Params memory p = _live();
        p.liquidationThresholdBps = 5_400;
        _set(p);

        p.liquidationThresholdBps = 5_200; // still inside [5000, 5800], but downward
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RiskParams.LiquidationThresholdLowered.selector, 5_400, 5_200)
        );
        riskParams.setRiskParams(p);
    }

    function test_setThreshold_maySitStillWithoutBeingRefused() public {
        IRiskParams.Params memory p = _live();
        p.globalBorrowCap = 50_000e6;
        _set(p);
        assertEq(_live().liquidationThresholdBps, Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS, "a still threshold moved");
    }

    /// @dev The transition guard and the hard floor are deliberately redundant. The floor says
    ///      where the threshold may sit; the transition says which way it may travel. Keeping both
    ///      means the intent survives someone later editing one of them in isolation.
    function test_theFloorAndTheTransitionGuardAreBothLoadBearing() public {
        IRiskParams.Params memory p = _live();
        p.liquidationThresholdBps = uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS) - 1;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskParams.RiskParamOutOfBounds.selector,
                bytes32("liquidationThresholdBps"),
                Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS - 1,
                5_000,
                5_800
            )
        );
        riskParams.setRiskParams(p);
    }

    // ── relation C, and an honest account of whether it can fire ─────────────

    /// @notice The threshold's hard ceiling is itself covered by the auction floor.
    /// @dev **This is the test that makes relation (C) worth having, and it is not a boundary
    ///      test, because (C) cannot currently fire.** The bound admits at most
    ///      `THRESHOLD_BPS_MAX`; the floor covers rather more than that. So every value the bound
    ///      lets through, (C) also lets through, and no input reaches (C)'s revert.
    ///
    ///      Measured rather than asserted from the arithmetic in a comment: the numbers are
    ///      recomputed here from the same constants the contract uses. A test written as "rejects
    ///      a threshold at the auction floor" would pass, and would pass for the wrong reason -
    ///      the bound refuses it hundreds of basis points earlier, so the assertion would be about
    ///      a check it never reached.
    ///
    ///      What this asserts instead is the property that actually protects lenders: **the bound
    ///      can never admit a threshold the floor cannot cover.** It fails the moment somebody
    ///      raises the threshold ceiling or lowers `AUCTION_FLOOR_BPS`, which are exactly the two
    ///      edits that would make (C) reachable - and the second is live with DexFi right now,
    ///      since the floor has been offered to them as a raise and could come back as a cut.
    function test_theThresholdCeilingIsCoveredByTheAuctionFloor() public view {
        uint256 ceiling = 5_800; // RiskParams.THRESHOLD_BPS_MAX, restated so this test is the check
        // The ceiling is admissible, so the bound is the only thing refusing anything above it.
        riskParams.checkRiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(ceiling),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            })
        );

        uint256 required = _requiredFloorFor(ceiling);
        assertGe(
            Config.AUCTION_FLOOR_BPS,
            required,
            "the threshold ceiling admits a value the auction floor cannot cover"
        );
    }

    /// @notice The margin relation (C) leaves, at BOTH ends of the ratchet.
    /// @dev **This is the assertion three prose comments were standing in for, and they had
    ///      drifted to three different numbers for one quantity.** `Config`'s auction-floor header
    ///      claimed 967 bps of headroom "far clear of its bound", and `LiquidationAuction` twice
    ///      claimed 33 bps in the present tense. They are not contradicting each other about
    ///      arithmetic - they are quoting the margin at *different thresholds*, and neither said
    ///      which. The threshold is the one input designed to move, so the margin at today's value
    ///      is a fact with a shelf life and the margin at `THRESHOLD_BPS_MAX` is the one every
    ///      decision has to be made against.
    ///
    ///      Both ends are pinned here so that a change to `AUCTION_FLOOR_BPS`, to the penalty, or
    ///      to any of the three NAV deviation constants fails a test rather than staling a comment.
    ///      **The commercially urgent one is the second.** `AUCTION_FLOOR_BPS` has been offered to
    ///      DexFi as a raise and could come back as a cut. A cut of 33 bps lands the floor exactly
    ///      on the requirement and the endpoint survives; **34 puts the ratchet's agreed 5800
    ///      endpoint permanently out of reach** through `checkRiskParams`. That is the whole
    ///      margin, and it is why this is a test rather than a sentence.
    function test_relationCsMarginIsPinnedAtBothEndsOfTheRatchet() public pure {
        // Today's threshold, which is `THRESHOLD_BPS_MIN` and the seeded default.
        uint256 requiredAtFloor = _requiredFloorFor(5_000);
        assertEq(requiredAtFloor, 5_834, "the margin at the ratchet's start moved");
        assertEq(Config.AUCTION_FLOOR_BPS - requiredAtFloor, 966, "start-of-ratchet margin moved");

        // The ratchet's terminus, which is `THRESHOLD_BPS_MAX` and where the margin is actually
        // thin. Relation (C) is slack at both ends, but only just at this one.
        uint256 requiredAtCeiling = _requiredFloorFor(5_800);
        assertEq(requiredAtCeiling, 6_767, "the margin at the ratchet's terminus moved");
        assertEq(Config.AUCTION_FLOOR_BPS - requiredAtCeiling, 33, "end-of-ratchet margin moved");

        assertLt(requiredAtCeiling, Config.AUCTION_FLOOR_BPS, "relation C is now binding, not slack");
    }

    /// @notice The highest threshold relation (C) alone would admit, against today's floor.
    /// @dev The honest version of "(C) caps the threshold well above the ratchet's endpoint". It
    ///      does not: it caps it 28 bps above, which is inside the rounding error of a negotiation.
    ///      Asserted as the exact largest admissible value rather than as an inequality, because an
    ///      inequality would keep passing all the way down to 5801.
    function test_relationCAloneAdmitsOnly28BpsAboveTheRatchetTerminus() public view {
        uint256 highest = 5_828;
        assertTrue(
            riskParams.auctionFloorCoversThreshold(highest, Config.AUCTION_FLOOR_BPS),
            "the last threshold the floor covers moved down"
        );
        assertFalse(
            riskParams.auctionFloorCoversThreshold(highest + 1, Config.AUCTION_FLOOR_BPS),
            "the floor now covers a higher threshold than measured"
        );
        assertEq(highest - RATCHET_END_THRESHOLD, 28, "the room above the agreed endpoint moved");
    }

    /// @notice The guard, driven across a grid of thresholds and floors against an exact reference.
    /// @dev **Why a grid and not a boundary test.** Relation (C) cannot fire today - the hard bound
    ///      `THRESHOLD_BPS_MAX` refuses everything (C) would refuse, 28 bps earlier - so there is
    ///      no input to `checkRiskParams` that reaches its revert. That is exactly the shape in
    ///      which a wrong guard survives: the only way to measure it is to call the predicate
    ///      directly, across floors that are not today's floor. This is why
    ///      `auctionFloorCoversThreshold` takes the floor as a parameter.
    ///
    ///      40,851 points: every threshold in `[THRESHOLD_BPS_MIN, THRESHOLD_BPS_MAX]` against 51
    ///      floors from well below the requirement to well above it, so both branches are
    ///      exercised at every threshold. At each point three things must agree: the contract's
    ///      division-free comparison, the contract's ceiling-divided `minimumAuctionFloorFor`, and
    ///      an exact rational reference that shares no algebra with either.
    ///
    ///      Neuter check, run 2026-08-17: restoring any one of the three floors the old guard
    ///      performed turns this test red at the first threshold whose exact requirement is not a
    ///      whole number of basis points.
    function test_relationCAgreesWithAnExactReferenceAcrossTheWholeGrid() public view {
        uint256 checked;
        for (uint256 t = 5_000; t <= 5_800; ++t) {
            uint256 required = _requiredFloorFor(t);
            assertEq(riskParams.minimumAuctionFloorFor(t), required, "ceil-divided form disagrees with the reference");

            for (uint256 floorBps = 5_800; floorBps <= 6_900; floorBps += 22) {
                assertEq(
                    riskParams.auctionFloorCoversThreshold(t, floorBps),
                    floorBps >= required,
                    "the division-free guard disagrees with the exact requirement"
                );
                ++checked;
            }
        }
        assertEq(checked, 40_851, "the grid shrank; a passing grid check over fewer points proves less");
    }

    /// @notice The old reference agreed with the wrong answer. That is the finding.
    /// @dev The helper this suite used to derive relation (C) with was a verbatim copy of the
    ///      contract's three integer divisions, so it could not disagree with them however wrong
    ///      they were. Demonstrated rather than asserted in prose: over the admissible range the
    ///      copy understates the requirement at most thresholds, never overstates it, and every
    ///      understatement is an admitted threshold a floor-price fill cannot cover.
    ///
    ///      Understating is the unsafe direction, which is why "off by at most 2 bps" is not a
    ///      shrug. Round 20's witness: against a 6000 floor the copy admits 5144 where 5142 is the
    ///      last threshold exactly permitted.
    function test_theOldRequiredFloorHelperAgreedWithTheWrongAnswer() public pure {
        uint256 understated;
        uint256 overstated;
        uint256 worstGap;
        for (uint256 t = 5_000; t <= 5_800; ++t) {
            uint256 exact = _requiredFloorFor(t);
            uint256 copied = _requiredFloorFor_flooredCopy(t);
            if (copied < exact) {
                ++understated;
                if (exact - copied > worstGap) worstGap = exact - copied;
            } else if (copied > exact) {
                ++overstated;
            }
        }
        assertEq(understated, 756, "the old copy's understatement count moved");
        assertEq(overstated, 0, "the old copy never erred toward safety, and that is the point");
        assertEq(worstGap, 2, "the old copy's worst understatement moved");

        // The witness, at a floor the negotiation could plausibly land on: 5142 is the last
        // threshold a 6000 floor exactly covers, and the copy admitted two more.
        assertLe(_requiredFloorFor(5_142), 6_000, "5142 is the last threshold a 6000 floor covers");
        assertGt(_requiredFloorFor(5_143), 6_000, "the exact requirement refuses 5143 at a 6000 floor");
        assertLe(_requiredFloorFor_flooredCopy(5_144), 6_000, "the old copy admitted 5144 at a 6000 floor");
    }

    // ── relations D and E ────────────────────────────────────────────────────

    /// @dev `<=`, so equality is legal: one account may hold the entire book. A `<` bound would
    ///      wrongly refuse this, and every rejection test would still pass.
    function test_setCaps_acceptExactlyEqualCaps() public {
        IRiskParams.Params memory p = _live();
        p.perAccountBorrowCap = p.globalBorrowCap;
        _set(p);
        assertEq(_live().perAccountBorrowCap, _live().globalBorrowCap, "equal caps were refused");
    }

    /// @dev **Relation (D) is the only one of the five with a real boundary**, because the two
    ///      caps' admissible ranges overlap: the per-account ceiling is 25k and the global floor
    ///      is 500, so a set with the account cap above the global one is inside both bounds and
    ///      reaches (D). Both witnesses below are chosen inside the bounds for that reason - one
    ///      basis point over the *global* value would leave the bound firing first and this test
    ///      would be about the wrong check.
    function test_setCaps_rejectPerAccountOneAboveGlobal() public {
        IRiskParams.Params memory p = _live();
        p.globalBorrowCap = 1_000e6;
        p.perAccountBorrowCap = 1_000e6 + 1;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskParams.PerAccountCapAboveGlobal.selector, uint256(1_000e6 + 1), uint256(1_000e6)
            )
        );
        riskParams.setRiskParams(p);
    }

    function test_setGlobalCap_rejectsLoweringBelowTheStoredPerAccountCap() public {
        IRiskParams.Params memory p = _live();
        p.globalBorrowCap = uint64(p.perAccountBorrowCap) - 1;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskParams.PerAccountCapAboveGlobal.selector,
                uint256(p.perAccountBorrowCap),
                uint256(p.globalBorrowCap)
            )
        );
        riskParams.setRiskParams(p);
    }

    function test_setPerAccountCap_acceptsExactlyTheBountyThreshold() public {
        IRiskParams.Params memory p = _live();
        p.perAccountBorrowCap = uint64(Config.MIN_BOUNTIED_DEBT);
        _set(p);
        assertEq(_live().perAccountBorrowCap, Config.MIN_BOUNTIED_DEBT, "the smallest legal cap was refused");
    }

    /// @dev A vacuity guard rather than a safety one, and the more valuable of the two. Below this
    ///      no position could ever be bountied, every consumer of the bounty would ship untested,
    ///      and the suite would report green over a quantity that is always zero.
    function test_setPerAccountCap_rejectsACapUnderTheBountyThreshold() public {
        IRiskParams.Params memory p = _live();
        p.perAccountBorrowCap = uint64(Config.MIN_BOUNTIED_DEBT) - 1;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskParams.RiskParamOutOfBounds.selector,
                bytes32("perAccountBorrowCap"),
                Config.MIN_BOUNTIED_DEBT - 1,
                Config.MIN_BOUNTIED_DEBT,
                25_000e6
            )
        );
        riskParams.setRiskParams(p);
    }

    // ── the hard bounds, both sides of each ──────────────────────────────────

    function test_bounds_acceptEveryCeilingExactly() public {
        IRiskParams.Params memory p = IRiskParams.Params({
            maxLtvBps: 3_500,
            liquidationThresholdBps: 5_800,
            globalBorrowCap: 250_000e6,
            perAccountBorrowCap: 25_000e6
        });
        _set(p);
        IRiskParams.Params memory got = _live();
        assertEq(got.maxLtvBps, 3_500, "max LTV ceiling refused");
        assertEq(got.globalBorrowCap, 250_000e6, "global cap ceiling refused");
        assertEq(got.perAccountBorrowCap, 25_000e6, "per-account ceiling refused");
    }

    function test_bounds_rejectMaxLtvOneAboveItsCeiling() public {
        IRiskParams.Params memory p = _live();
        p.liquidationThresholdBps = 5_800;
        p.maxLtvBps = 3_501;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RiskParams.RiskParamOutOfBounds.selector, bytes32("maxLtvBps"), 3_501, 500, 3_500)
        );
        riskParams.setRiskParams(p);
    }

    function test_bounds_rejectMaxLtvOneBelowItsFloor() public {
        IRiskParams.Params memory p = _live();
        p.maxLtvBps = 499;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RiskParams.RiskParamOutOfBounds.selector, bytes32("maxLtvBps"), 499, 500, 3_500)
        );
        riskParams.setRiskParams(p);
    }

    function test_bounds_rejectThresholdOneAboveItsCeiling() public {
        IRiskParams.Params memory p = _live();
        p.liquidationThresholdBps = 5_801;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskParams.RiskParamOutOfBounds.selector, bytes32("liquidationThresholdBps"), 5_801, 5_000, 5_800
            )
        );
        riskParams.setRiskParams(p);
    }

    function test_bounds_rejectGlobalCapOneAboveItsCeiling() public {
        IRiskParams.Params memory p = _live();
        p.globalBorrowCap = uint64(Config.GLOBAL_BORROW_CAP_MAX) + 1;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskParams.RiskParamOutOfBounds.selector,
                bytes32("globalBorrowCap"),
                Config.GLOBAL_BORROW_CAP_MAX + 1,
                Config.MIN_BOUNTIED_DEBT,
                Config.GLOBAL_BORROW_CAP_MAX
            )
        );
        riskParams.setRiskParams(p);
    }

    function test_bounds_rejectZeroEverywhereItMatters() public {
        IRiskParams.Params memory p = _live();
        p.maxLtvBps = 0;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RiskParams.RiskParamOutOfBounds.selector, bytes32("maxLtvBps"), 0, 500, 3_500)
        );
        riskParams.setRiskParams(p);
    }

    /// @dev The hard ceiling on the global cap is the same number three contracts rely on:
    ///      `LenderPool.impair` and `LiquidationAuction._bid` clamp on it as a compile-time
    ///      constant, because neither may revert and so neither may read this contract. If the
    ///      bound here ever exceeded that constant, both clamps would start biting legitimate
    ///      values silently.
    function test_theGlobalCapCeilingIsTheSameNumberTheClampsUse() public pure {
        assertEq(Config.GLOBAL_BORROW_CAP_MAX, 250_000e6, "the shared ceiling moved");
    }

    // ── authority ────────────────────────────────────────────────────────────

    function test_onlyTheOwnerMaySet() public {
        IRiskParams.Params memory p = _live();
        p.maxLtvBps = 2_400;
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        riskParams.setRiskParams(p);
    }

    function test_renounceIsDisabled() public {
        vm.prank(admin);
        vm.expectRevert(RiskParams.RenounceDisabled.selector);
        riskParams.renounceOwnership();
    }

    // ── the timelock ─────────────────────────────────────────────────────────

    function test_queuedSetRevertsBeforeTheDelayAndSucceedsOnIt() public {
        _handOver();

        IRiskParams.Params memory p = _live();
        p.globalBorrowCap = 50_000e6;
        bytes memory data = abi.encodeCall(IRiskParams.setRiskParams, (p));
        _schedule(data);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _execute(data);

        vm.warp(block.timestamp + 1);
        _execute(data);
        assertEq(_live().globalBorrowCap, 50_000e6, "the move did not land on the delay");
    }

    function test_afterHandoverTheOldOwnerLosesAuthority() public {
        _handOver();
        IRiskParams.Params memory p = _live();
        p.maxLtvBps = 2_400;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        riskParams.setRiskParams(p);
    }

    /// @notice An illegal value schedules happily and reverts forty-eight hours later.
    /// @dev Pinned rather than discovered at go-live. `TimelockController` validates nothing at
    ///      schedule time - it hashes calldata and starts a clock - so the first sign of an
    ///      out-of-bounds parameter is a failed execution two days on, leaving an operation that
    ///      has to be cancelled before a corrected one can be queued under the same salt.
    ///
    ///      This is the whole reason `checkRiskParams` is on the external surface: a proposer can
    ///      `eth_call` it and find out in a second rather than in two days.
    function test_anIllegalParameterSchedulesFineAndRevertsAtExecute() public {
        _handOver();

        IRiskParams.Params memory bad = _live();
        bad.maxLtvBps = 9_000; // over its ceiling and over the threshold
        bytes memory data = abi.encodeCall(IRiskParams.setRiskParams, (bad));

        _schedule(data); // no revert: nothing has validated it

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(RiskParams.RiskParamOutOfBounds.selector, bytes32("maxLtvBps"), 9_000, 500, 3_500)
        );
        _execute(data);

        // And the pre-flight that makes the two-day surprise avoidable.
        vm.expectRevert(
            abi.encodeWithSelector(RiskParams.RiskParamOutOfBounds.selector, bytes32("maxLtvBps"), 9_000, 500, 3_500)
        );
        riskParams.checkRiskParams(bad);
    }

    // ── audit round 20: a matured proposal never expires ─────────────────────

    /// @dev The state one ratchet step in, which is where a real emergency would find this
    ///      protocol: caps already raised once, everything else at its launch value.
    function _oneRatchetStepIn() internal returns (IRiskParams.Params memory p) {
        p = _defaults();
        p.globalBorrowCap = 100_000e6;
        p.perAccountBorrowCap = 15_000e6;
        _set(p);
    }

    function _payload(uint16 maxLtv, uint16 threshold, uint64 globalCap, uint64 perAccount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            IRiskParams.setRiskParams,
            (
                IRiskParams.Params({
                    maxLtvBps: maxLtv,
                    liquidationThresholdBps: threshold,
                    globalBorrowCap: globalCap,
                    perAccountBorrowCap: perAccount
                })
            )
        );
    }

    function _executeBy(address who, bytes memory data) internal {
        vm.prank(who);
        timelock.execute(address(riskParams), 0, data, bytes32(0), bytes32(0));
    }

    /// @notice **A configuration this setter accepts need only be one governance *once* intended,
    ///         not the one it intends now** - and anybody may be the one to say so.
    /// @dev `TimelockController` never expires a matured operation and OpenZeppelin's has no grace
    ///      period, so two `setRiskParams` payloads are two ids that can both sit `Ready`
    ///      indefinitely. Execution is open, so a stranger chooses which, and in which order.
    ///
    ///      Only `liquidationThresholdBps` has a transition check. The other three fields have
    ///      bounds and relations, all of which a stale proposal satisfies - it was legal when it
    ///      was written. So the replay clears `checkRiskParams` cleanly and re-applies three
    ///      fields, undoing an emergency response with no proposer involvement at all.
    ///
    ///      **Per-field monotonicity is not the answer and must not be added.** A downward cap move
    ///      is this protocol's intended tightening lever; the second half of this test is that
    ///      lever working. The property is about recency, not direction.
    function test_aStaleMaturedProposalUndoesAnEmergencyTightening() public {
        // The step is taken before the handover only because the fixture's `_set` pranks as the
        // EOA owner. It is the same live state either way.
        IRiskParams.Params memory live = _oneRatchetStepIn();
        _handOver();
        assertEq(live.globalBorrowCap, 100_000e6, "premise: the caps have moved once already");

        // A: the next ratchet step, scheduled in the ordinary course of business.
        bytes memory loosen = _payload(RATCHET_END_MAX_LTV, 5_000, RATCHET_END_GLOBAL_CAP, RATCHET_END_PER_ACCOUNT_CAP);
        _schedule(loosen);

        // An hour later a risk event lands and governance schedules an emergency tightening,
        // back to the launch figures.
        vm.warp(block.timestamp + 1 hours);
        bytes memory tighten = _payload(2_500, 5_000, 25_000e6, 5_000e6);
        _schedule(tighten);

        // Both mature. The tightening executes - the latest decision, and it works.
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _executeBy(outsider, tighten);
        assertEq(_live().globalBorrowCap, 25_000e6, "the tightening lands");
        assertEq(_live().perAccountBorrowCap, 5_000e6, "the tightening lands");
        assertEq(_live().maxLtvBps, 2_500, "the tightening lands");

        // And the superseded loosening is still `Ready`. Anybody fires it, in the same block.
        _executeBy(outsider, loosen);
        assertEq(_live().globalBorrowCap, RATCHET_END_GLOBAL_CAP, "MEASURED: the tightening was undone");
        assertEq(_live().perAccountBorrowCap, RATCHET_END_PER_ACCOUNT_CAP, "MEASURED: and so was the account cap");
        assertEq(_live().maxLtvBps, RATCHET_END_MAX_LTV, "MEASURED: and the borrow ceiling was re-widened");
    }

    /// @notice THE CONTROL: the identical replay aimed at the threshold is refused, which is what
    ///         shows the difference is the transition check and not the timelock.
    /// @dev One field of four is protected. The test above is the other three.
    function test_control_theSameReplayAimedAtTheThresholdIsRefused() public {
        _oneRatchetStepIn();
        _handOver();

        bytes memory low = _payload(2_500, 5_000, 100_000e6, 15_000e6);
        _schedule(low);
        vm.warp(block.timestamp + 1 hours);
        bytes memory high = _payload(2_500, 5_400, 100_000e6, 15_000e6);
        _schedule(high);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _executeBy(outsider, high);
        assertEq(_live().liquidationThresholdBps, 5_400, "premise: the raise landed");

        vm.prank(outsider);
        vm.expectPartialRevert(RiskParams.LiquidationThresholdLowered.selector);
        timelock.execute(address(riskParams), 0, low, bytes32(0), bytes32(0));
        assertEq(_live().liquidationThresholdBps, 5_400, "the threshold held");
    }

    /// @notice The answer chosen, executable: `cancel` closes it, costs nothing, and the party who
    ///         schedules the superseding change already holds the role that can do it.
    /// @dev **Recorded as an operational rule with a test rather than built as a nonce on this
    ///      setter, and the reason is a measurement, not a preference.** The replay is not a
    ///      property of `RiskParams`: it is a property of `TimelockController`, which has no grace
    ///      period, and it therefore applies to *every* `onlyOwner` setter this protocol has.
    ///      `Governance.t.sol`'s `test_aStaleProposalReplaysOnAnySetterNotOnlyRiskParams` measures
    ///      the same replay against `adapter.setYieldRecipient` - the "owner can redirect yield"
    ///      power the audit accepted *because* the owner would be a timelock. A compare-and-swap
    ///      argument on `setRiskParams` would fix one of them and leave the shape open next door,
    ///      while reading like closure.
    ///
    ///      `cancel` is instant, has no delay of its own, and `TimelockController`'s constructor
    ///      grants `CANCELLER_ROLE` to every proposer - so the governance Safe can already do this
    ///      with no new wiring. The rule that goes with it, recorded in the go-live governance
    ///      checklist: **cancel every pending operation against a target before scheduling one that
    ///      supersedes it.** Cancel first, then schedule, so there is never a moment where both
    ///      are `Ready` and a stranger picks.
    function test_cancellingTheSupersededProposalIsWhatCloses() public {
        _oneRatchetStepIn();
        _handOver();

        bytes memory loosen = _payload(RATCHET_END_MAX_LTV, 5_000, RATCHET_END_GLOBAL_CAP, RATCHET_END_PER_ACCOUNT_CAP);
        bytes32 loosenId = _schedule(loosen);

        // Cancelled BEFORE the superseding change is scheduled, which is the order that matters:
        // it is legal at any point, and only this order leaves no block in which both are `Ready`.
        vm.prank(proposer);
        timelock.cancel(loosenId);

        vm.warp(block.timestamp + 1 hours);
        bytes memory tighten = _payload(2_500, 5_000, 25_000e6, 5_000e6);
        _schedule(tighten);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _executeBy(outsider, tighten);

        // The replay is now an id nobody scheduled.
        vm.prank(outsider);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(riskParams), 0, loosen, bytes32(0), bytes32(0));

        assertEq(_live().globalBorrowCap, 25_000e6, "the tightening held");
        assertEq(_live().perAccountBorrowCap, 5_000e6, "the tightening held");
        assertEq(_live().maxLtvBps, 2_500, "the tightening held");
    }

    // ── the event ────────────────────────────────────────────────────────────

    /// @dev An event is the only channel the webapp and the keeper have for noticing a move: both
    ///      mirror these values, and neither is called when governance acts.
    function test_setEmitsBothTheOldAndTheNewValues() public {
        IRiskParams.Params memory p = _live();
        uint256 previousCap = p.globalBorrowCap;
        p.globalBorrowCap = 50_000e6;

        vm.expectEmit(false, false, false, true, address(riskParams));
        emit RiskParams.RiskParamsSet(
            p.maxLtvBps,
            p.maxLtvBps,
            p.liquidationThresholdBps,
            p.liquidationThresholdBps,
            50_000e6,
            previousCap,
            p.perAccountBorrowCap,
            p.perAccountBorrowCap
        );
        _set(p);
    }
}
