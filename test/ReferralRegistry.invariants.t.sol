// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ReferralRegistry} from "../src/ReferralRegistry.sol";

/// @notice Randomised `register`/`bind` sequences across several actors. The contract has two
///         mutators and no arithmetic, so the unit tests already cover each path. What they cover
///         badly is the *global, permanence-shaped* claim the whole off-chain architecture rests
///         on: that no sequence of calls, by anyone, in any order, can change an attribution that
///         has already been recorded.
contract RegistryHandler is Test {
    ReferralRegistry public immutable registry;

    address[] public actors;

    /// @dev Ghosts: the first value ever observed, so an invariant can compare against it rather
    ///      than against the contract's current answer (which would be self-satisfying).
    mapping(bytes32 code => address) public ghostFirstOwner;
    mapping(address referee => bytes32) public ghostFirstCode;
    bytes32[] public knownCodes;
    address[] public boundActors;

    /// @dev Success counters. An invariant suite whose handler never reached the interesting state
    ///      reports every invariant green and proves nothing; `test_handlerCanReachEveryState`
    ///      below asserts these deterministically. Deliberately NOT `afterInvariant`, which fires
    ///      per-run against counters that reset per-run and so demands every random sequence hit
    ///      every state.
    uint256 public ghostRegistrations;
    uint256 public ghostBinds;
    uint256 public ghostRejectedRebinds;
    uint256 public ghostRejectedSelfReferrals;

    /// @dev The in-handler property record. Two fields, so a failure carries its own message
    ///      rather than only a count.
    ///
    ///      **Why these are recorded and not asserted, MEASURED 2026-09-09 on forge 1.8.1 against
    ///      this file's own pre-conversion commit.** A forge-std assertion inside a handler
    ///      reverts, and under the global `fail_on_revert = false` a reverting handler call is
    ///      DISCARDED - so the two assertions that used to stand in the two actions below could
    ///      fail invisibly for as long as this suite existed, while rolling back the frame that
    ///      tripped them. Measured at a REAL site rather than argued: flipping `register`'s
    ///      `assertEq(bytes4(err), ReferralRegistry.CodeTaken.selector, ...)` to `assertNotEq`
    ///      makes the property false on every contested registration, and
    ///      `invariant_aRegisteredCodeNeverChangesOwner` still reported
    ///      `[PASS] (runs: 256, calls: 128000, reverts: 62848)` - close to half the campaign's
    ///      frames thrown away and nothing red. With the recorder in place the same flip is red on
    ///      the first frame, carrying "unexpected register revert".
    ///
    ///      🟥 **THE BLANKET FORM OF THAT CLAIM IS FALSE, and the correction is worth more than the
    ///      claim.** forge 1.8.1 DOES report SOME in-handler assertion failures: a bare
    ///      `assertEq(uint256(1), uint256(2))` at the top of `register` turns this suite RED with
    ///      `[FAIL: assertion failed: 1 != 2] RegistryHandler::register`. **The discriminator is
    ///      the MESSAGE**, isolated by changing that one argument and nothing else at the same
    ///      site: `assertEq(uint256(1), uint256(2), "planted with a message")` is green again at
    ///      `(runs: 256, calls: 128000, reverts: 63994)`. A two-argument forge-std assertion
    ///      reverts with a string beginning "assertion failed", which forge picks out of the
    ///      discarded frame; a three-argument one reverts with the assertion's own message instead and
    ///      is indistinguishable from an ordinary business revert. **Both assertions this
    ///      conversion touched carried a message**, which is why the hazard was total here - and
    ///      why a session that probes it with a message-less one-liner will measure the opposite
    ///      and conclude there is nothing to fix. The message is a SUFFICIENT suppressor and not
    ///      the only one: that same message-LESS one-liner planted inside `register`'s catch block
    ///      rather than at the top of the function was not reported either,
    ///      `(runs: 256, calls: 128000, reverts: 62346)`. That reading is unexplained and is
    ///      recorded rather than smoothed over.
    ///
    ///      **The truncation half is what bites in THIS file, and it bites the permanence claim.**
    ///      Both assertions sit in a `catch`, on the residual branch left after the expected
    ///      refusals have been counted - so a wrong one does not merely fail quietly, it discards
    ///      the frame that reached the contested state. This handler draws codes from a six-entry
    ///      pool precisely so `CodeTaken` and contested registrations happen often, and every ghost
    ///      that records a contest (`ghostFirstOwner`, `knownCodes`, `ghostFirstCode`,
    ///      `boundActors`) dies with the frame. The invariants below are quantified over exactly
    ///      those ghosts, so a silent truncation here thins the set they read and leaves them
    ///      passing over less than they appear to.
    ///
    ///      Three repairs exist and this is the third. `assert(cond)` raises Panic(0x01), which
    ///      forge 1.8.1 DOES report as a `handler_assertion` failure naming the contract and the
    ///      offending selector - measured for `CollateralVault.invariants.t.sol` on 2026-09-09 and
    ///      recorded on `VaultHandler.firstBrokenProperty`, not re-measured here - but it discards
    ///      the frame and carries no message, and `bind`'s
    ///      residual branch is reached after two other selectors have already been peeled off, so
    ///      a nameless failure would not say which of the two actions raised it. `assertions_revert
    ///      = false` makes the whole `vm.assert*` family report, but it is a whole-suite semantic
    ///      change across every test in the tree and is not a test file's to take. Recording keeps
    ///      the message, keeps the frame, and is the idiom `RiskParams.invariants.t.sol::propose`
    ///      already documents in prose: "Counting it and asserting the count from the suite has
    ///      neither problem."
    ///
    ///      **The one hole, and why it is already covered.** A record written here is lost if the
    ///      SAME frame reverts later for an unrelated reason. That case is exactly a dropped frame,
    ///      and `invariant_theHandlerNeverDropsAFrame` is red on the first one - so the two guards
    ///      compose and neither has to be trusted alone.
    string public firstBrokenProperty;
    uint256 public brokenProperties;

    /// @dev Records rather than reverts. See `firstBrokenProperty`. The FIRST message is kept
    ///      because it is the one with a live counterexample behind it; later ones only add noise.
    ///
    ///      `private`, and non-view, on purpose. `targetContract(address(handler))` takes every
    ///      external non-view function as a fuzz action whether it was written to be one or not,
    ///      so a public recorder would let the fuzzer write the very field the suite reads.
    function _mustHold(bool ok, string memory what) private {
        if (ok) return;
        if (brokenProperties == 0) firstBrokenProperty = what;
        ++brokenProperties;
    }

    constructor(ReferralRegistry registry_) {
        registry = registry_;
        for (uint256 i; i < 5; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("refActor", i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function knownCodeCount() external view returns (uint256) {
        return knownCodes.length;
    }

    function boundActorCount() external view returns (uint256) {
        return boundActors.length;
    }

    /// @dev Codes are drawn from a small pool so collisions actually happen. A pool wide enough to
    ///      make every code unique would never exercise `CodeTaken` or a contested registration.
    function _code(uint256 seed) internal pure returns (bytes32) {
        bytes32[6] memory pool = [
            bytes32("ALPHA"),
            bytes32("BRAVO"),
            bytes32("CHARLIE"),
            bytes32("DELTA-3"),
            bytes32("ECHO_2"),
            bytes32("FOXTROT")
        ];
        return pool[seed % pool.length];
    }

    function register(uint256 actorSeed, uint256 codeSeed) external {
        address actor = actors[actorSeed % actors.length];
        bytes32 code = _code(codeSeed);

        vm.prank(actor);
        // Wrapped because a contested code SHOULD revert - that is the behaviour under test, not a
        // fixture failure. Only the expected reverts are swallowed; see the catch.
        try registry.register(code) {
            ++ghostRegistrations;
            if (ghostFirstOwner[code] == address(0)) {
                ghostFirstOwner[code] = actor;
                knownCodes.push(code);
            }
        } catch (bytes memory err) {
            _mustHold(bytes4(err) == ReferralRegistry.CodeTaken.selector, "unexpected register revert");
        }
    }

    function bind(uint256 actorSeed, uint256 codeSeed) external {
        address actor = actors[actorSeed % actors.length];
        bytes32 code = _code(codeSeed);

        vm.prank(actor);
        try registry.bind(code) {
            ++ghostBinds;
            if (ghostFirstCode[actor] == bytes32(0)) {
                ghostFirstCode[actor] = code;
                boundActors.push(actor);
            }
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == ReferralRegistry.AlreadyBound.selector) {
                ++ghostRejectedRebinds;
            } else if (sel == ReferralRegistry.SelfReferral.selector) {
                ++ghostRejectedSelfReferrals;
            } else {
                _mustHold(sel == ReferralRegistry.CodeNotRegistered.selector, "unexpected bind revert");
            }
        }
    }
}

contract ReferralRegistryInvariants is Test {
    ReferralRegistry internal registry;
    RegistryHandler internal handler;

    function setUp() public {
        registry = new ReferralRegistry(new bytes32[](0));
        handler = new RegistryHandler(registry);
        targetContract(address(handler));
    }

    /// @dev The reason there is no `transferCode`, made into a property. Code ownership being
    ///      write-once is also what lets `boundCode` store only the code and derive the referrer.
    /// @notice No handler call may revert. Every action in this handler wraps its interesting call
    ///         in `try`, or guards it, so a handler *frame* that dies is a fixture fault rather
    ///         than a meaningless random sequence.
    /// @dev **Added to all five suites at once, because the bug that prompted it was found in one
    ///      and existed in three.** `LiquidationAuction.invariants.t.sol` opened auctions at a
    ///      healthy rate and rolled every one of them back, for three audit rounds, because a
    ///      statement after the `try` reverted and `fail_on_revert = false` discards a reverting
    ///      frame. Nothing inside a handler can detect that - the ghost that would record it dies
    ///      with the frame. Only the runner, counting frames from outside, can.
    ///
    ///      Deterministic: a property of the handler's code rather than of the random walk, so it
    ///      cannot flake the way a per-run reachability floor does.
    ///
    ///      Empty body on purpose. The assertion is the config line, enforced by the runner. The
    ///      global `fail_on_revert = false` in `foundry.toml` stays correct for every other
    ///      invariant here and is what lets the `try`/`catch` idiom work at all.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    /// @notice Every property the two handler actions check held on every frame that ran.
    /// @dev **This invariant is the whole reason those two checks are worth anything.** They used
    ///      to be forge-std assertions inside the handler, which revert - and under
    ///      `fail_on_revert = false` a reverting handler call is DISCARDED, so each of them could
    ///      have been failing since the day it was written and this suite would have reported every
    ///      other invariant green over the top of it. `RegistryHandler.firstBrokenProperty` carries
    ///      the measurement and the two rejected repairs.
    ///
    ///      **It composes with the frame guard rather than duplicating it.** The guard says no
    ///      frame died; this says nothing a frame observed was wrong. A residual `catch` branch is
    ///      exactly where the two meet: before this line, a wrong selector reaching it produced a
    ///      dropped frame the guard would report and a message nobody would ever see.
    ///
    ///      Asserted from the suite rather than in the handler, which is the only place the check
    ///      both survives the frame and can carry its message. The message IS the original
    ///      assertion's message, moved rather than rewritten, so a failure here reads exactly as
    ///      the in-handler assertion would have.
    function invariant_everyInHandlerPropertyHeld() public view {
        assertEq(handler.brokenProperties(), 0, handler.firstBrokenProperty());
    }

    function invariant_aRegisteredCodeNeverChangesOwner() public view {
        uint256 n = handler.knownCodeCount();
        for (uint256 i; i < n; ++i) {
            bytes32 code = handler.knownCodes(i);
            assertEq(
                registry.referrerOf(code),
                handler.ghostFirstOwner(code),
                "a code changed hands after registration"
            );
        }
    }

    /// @dev **The whole point of the contract.** If a binding could move, the off-chain
    ///      calculator's re-run would disagree with an earlier one and the payouts would stop
    ///      being reproducible.
    function invariant_aBindingNeverChangesOnceSet() public view {
        uint256 n = handler.boundActorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.boundActors(i);
            assertEq(
                registry.boundCode(actor), handler.ghostFirstCode(actor), "a binding was overwritten"
            );
        }
    }

    function invariant_noAccountIsEverBoundToItself() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertTrue(registry.referrerFor(actor) != actor, "an account referred itself");
        }
    }

    /// @dev No dangling binding: the orphan-harvest attack as a global property. A binding whose
    ///      code resolves to nobody would mean someone could register that code afterwards and
    ///      inherit the referee.
    function invariant_everyBindingResolvesToARegisteredReferrer() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            bytes32 code = registry.boundCode(actor);
            if (code == bytes32(0)) continue;
            assertTrue(registry.referrerOf(code) != address(0), "binding points at an unowned code");
        }
    }

    /// @dev The tripwire. A handler that never registered or never bound would satisfy all four
    ///      invariants above vacuously and report green forever. This drives the sequence by hand
    ///      so the counters are asserted deterministically rather than left to the fuzzer's luck.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        // Two distinct registrations.
        handler.register(0, 0); // actor0 takes ALPHA
        handler.register(1, 1); // actor1 takes BRAVO
        assertEq(handler.ghostRegistrations(), 2, "registrations unreachable");

        // A contested registration, which must be refused without reverting the handler.
        handler.register(2, 0); // actor2 tries ALPHA
        assertEq(handler.ghostRegistrations(), 2, "a contested code was granted");

        // A real bind, and a second actor binding a different code.
        handler.bind(3, 0); // actor3 -> ALPHA
        handler.bind(4, 1); // actor4 -> BRAVO
        assertEq(handler.ghostBinds(), 2, "binds unreachable");

        // A rebind attempt, which must be refused.
        handler.bind(3, 1); // actor3 already bound
        assertEq(handler.ghostRejectedRebinds(), 1, "the rebind guard was never exercised");

        // A self-referral attempt, which must be refused.
        handler.bind(0, 0); // actor0 owns ALPHA
        assertEq(handler.ghostRejectedSelfReferrals(), 1, "the self-referral guard was never exercised");

        assertEq(handler.knownCodeCount(), 2);
        assertEq(handler.boundActorCount(), 2);
    }
}
