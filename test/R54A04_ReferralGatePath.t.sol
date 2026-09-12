// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployReferralRegistry} from "../script/DeployReferral.s.sol";

/// @notice Round-54 item 200: `validateBroadcastApproval` was dead code that `run()` never called, and
///         the shipped `test_deploy_legacyConfirmationCannotBypassLiveDeploymentDisable` pinned the
///         duplicate rather than `run()`'s path. `run()` now CALLS it, so the pure validator is the
///         path a broadcast takes, and this file pins that the two agree: the same refusal, by the
///         same name, from `run()` off-anvil and from the validator, on both public chains.
///
/// @dev **Why there is no `vm.setEnv` here, and what the missing arm is.** The one arm this file
///      cannot hold without a writer is `run()` with the exact phrase IN the process environment
///      (a raw `Script` read of `RECOUP_REFERRAL_CONFIRM`, no `DeployBase` seam). Round 54's deploy
///      auditor MEASURED that arm with `vm.setEnv` in the audit worktree - `LiveDeploymentDisabled`
///      on 84532 and on 8453 under the fix, "did not revert" with the gate deleted - and it stays
///      in round 54's bundle, because the ungated environment census (round-49 item 136, in the
///      repository's detector suite) refuses `vm.setEnv` in any test by design, and the same
///      measurement showed why: with the phrase written into the process-global table, a REORDER
///      of `run()`'s two old gate lines left the shipped chain-84532 test green, since the leaked
///      phrase satisfied the confirmation the reorder put first. A writer that proves one thing
///      hides another. What is left is enough to bite: with the gate deleted from its now-single
///      site, `run()` unset and `validateBroadcastApproval("")` both fall through to
///      `ConfirmationMissing`, so the two public-chain tests below and the two shipped pins go red
///      (MEASURED, four red), and a reorder inside the validator is the legacy pin's own case.
contract R54A04ReferralGatePathTest is Test {
    DeployReferralRegistry internal script;

    function setUp() public {
        script = new DeployReferralRegistry();
    }

    /// @notice `run()` on Base mainnet, nothing set, is `LiveDeploymentDisabled` - the shipped chain
    ///         test holds the same on 84532; this is the 8453 arm. Under a `run()` whose single gate
    ///         is deleted this is `ConfirmationMissing` instead.
    function test_R54A04_200_runOnMainnetIsLiveDeploymentDisabledBeforeAnyPhraseIsRead() public {
        vm.chainId(8453);
        vm.expectRevert(DeployReferralRegistry.LiveDeploymentDisabled.selector);
        script.run();
    }

    /// @notice The validator with an EMPTY phrase - which is what `run()` hands it when the variable
    ///         is unset - refuses by the gate's name, not the phrase's. This is the path `run()` takes,
    ///         and the phrase is not consulted before the gate.
    function test_R54A04_200_theValidatorRefusesAnEmptyPhraseByTheGatesName() public {
        vm.chainId(84532);
        vm.expectRevert(DeployReferralRegistry.LiveDeploymentDisabled.selector);
        script.validateBroadcastApproval("");
    }

    /// @notice CONTROL: anvil needs no phrase and constructs the registry.
    function test_R54A04_200_control_anvilNeedsNoPhrase() public {
        vm.chainId(31337);
        script.run();
    }
}
