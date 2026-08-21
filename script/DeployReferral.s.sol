// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {ReferralRegistry} from "../src/ReferralRegistry.sol";

/// @title DeployReferralRegistry
/// @notice Deploys `ReferralRegistry` on its own, claiming the reserved brand codes in the same
///         transaction that creates it.
///
/// @dev **PUBLIC-CHAIN BROADCAST IS DISABLED WHILE THE SOURCE DESIGN IS OPEN.** The current
///      `registerFor` design can assign an unused code to an unspendable payee. `run()` therefore
///      rejects every chain ID other than 31337 before it reads the ordinary deployment
///      confirmation. Local construction remains available for tests and rehearsals. Settling the
///      design requires an explicit source change that removes this guard and updates its regression
///      test; documentation or the old
///      confirmation phrase alone cannot make this candidate deployable.
///
/// @dev **Why this is not part of the main protocol deploy.** The supported fix for a core defect
///      before launch is to redeploy the whole protocol set and move the bonds across. If the
///      registry were deployed alongside the core, every such redeploy would give it a new
///      address, and because bindings are immutable, address-scoped and non-portable, **every
///      existing referral binding would be orphaned permanently** with no owner able to repair it.
///      The registry's lifecycle has to outlive the protocol's.
///
///      Local rehearsal only while the source-design guard above remains:
///        forge script script/DeployReferral.s.sol:DeployReferralRegistry --rpc-url http://127.0.0.1:8901
///
/// @dev **Seeding is atomic, and the earlier version was not.** This script used to call
///      `register` in a loop inside the broadcast and claim it "closes that window entirely". A
///      broadcast emits one transaction per external call, so what it actually produced was a live
///      registry with an open `register`, followed by ten separate races for the brand codes -
///      against an address derivable from the deployer's nonce before the deploy was even sent.
///      The codes are now constructor arguments, so creation and reservation share one
///      transaction and any failure reverts the deployment.
///
///      The post-deploy checks below are still worth keeping but are **not** the safety net the
///      old ones pretended to be: `run()` executes entirely in forge's simulation and the recorded
///      transactions are broadcast after it returns, so nothing here can observe the chain. They
///      catch a bad constant. Atomicity is what catches a lost race, and that now lives in the
///      constructor.
contract DeployReferralRegistry is Script {
    error ConfirmationMissing();
    error SourceDesignOpen();
    error ReservedCodeNotClaimed(bytes32 code);
    error ReservedCodeWrongOwner(bytes32 code, address owner);

    uint256 internal constant ANVIL_CHAIN_ID = 31337;
    bool internal constant SOURCE_DESIGN_SETTLED = false;
    string internal constant CONFIRM_PHRASE = "RECOUP_DEPLOY_REFERRAL";

    /// @dev Brand strings and the confusable spellings the charset cannot rule out, so nobody can
    ///      publish a link that reads as official. One-shot and unrepeatable: anything missed here
    ///      is claimable by anyone the moment the address is public, and there is no way to
    ///      reclaim it.
    ///
    ///      Deliberately **not** here: `DEXFI`. It is a counterparty's brand, not Recoup's, and
    ///      code ownership is permanent with no transfer. Claiming it would mean the code bearing
    ///      DexFi's name pays a Recoup address forever, which is exactly the arrangement the
    ///      partner rule below forbids. If DexFi ever wants it, settle the registration design
    ///      first; this source is deliberately not broadcastable while that decision is open.
    ///
    ///      The `0`/`O` and `1`/`I` homoglyph family is absent because it is now impossible:
    ///      `isCanonical` excludes `0` and `1` from the alphabet entirely. What remains here is
    ///      the separator family and the weaker `5`/`S` substitution.
    function _reservedCodes() internal pure returns (bytes32[] memory codes) {
        codes = new bytes32[](16);
        codes[0] = bytes32("RECOUP");
        codes[1] = bytes32("RECOUPS");
        codes[2] = bytes32("RECOUP-");
        codes[3] = bytes32("-RECOUP");
        codes[4] = bytes32("RECOUP_");
        codes[5] = bytes32("_RECOUP");
        codes[6] = bytes32("RECOUPFI");
        codes[7] = bytes32("RECOUP-FI");
        codes[8] = bytes32("RECOUP_FI");
        codes[9] = bytes32("RECOUPFINANCE");
        codes[10] = bytes32("RECOUP-FINANCE");
        codes[11] = bytes32("RECOUP_FINANCE");
        codes[12] = bytes32("OFFICIAL");
        codes[13] = bytes32("SUPPORT");
        codes[14] = bytes32("5UPPORT"); // 5/S, the residual the charset still permits
        codes[15] = bytes32("ADMIN");
    }

    /// @notice Whether `provided` is the exact confirmation phrase.
    /// @dev Reading the environment and checking it are separate, the same split `DeployBase` uses
    ///      and for the same reason: a test that calls `vm.setEnv` to exercise this rule mutates
    ///      the real process environment for the whole `forge test` run, so the value leaks into
    ///      later tests and the confirmation test passes or fails on ordering. That is not
    ///      hypothetical - it happened here, and clearing the variable in `setUp` did not fix it,
    ///      because `vm.setEnv` with an empty value does not reliably clear. Exposed as a pure
    ///      function, both directions are testable and nothing touches the environment.
    function isConfirmed(string memory provided) public pure returns (bool) {
        return keccak256(bytes(provided)) == keccak256(bytes(CONFIRM_PHRASE));
    }

    /// @notice Applies the source-design gate before the ordinary one-command confirmation.
    /// @dev Public so the exact legacy confirmation can be regression-tested without mutating the
    ///      process environment via `vm.setEnv`, whose value leaks between Foundry tests.
    function validateBroadcastApproval(string memory provided) public pure {
        _requireSourceDesignSettled();
        if (!isConfirmed(provided)) revert ConfirmationMissing();
    }

    function run() external returns (ReferralRegistry registry) {
        // Current source is design-blocked, not merely awaiting an operator confirmation. A stray
        // command and the previously documented confirmation phrase must both fail off anvil.
        // Local chain-id 31337 runs need no ceremony so tests and local rehearsals can construct it.
        if (block.chainid != ANVIL_CHAIN_ID) {
            _requireSourceDesignSettled();
            if (!isConfirmed(vm.envOr("RECOUP_REFERRAL_CONFIRM", string("")))) revert ConfirmationMissing();
        }

        bytes32[] memory reserved = _reservedCodes();

        vm.startBroadcast();
        registry = new ReferralRegistry(reserved);
        vm.stopBroadcast();

        // Asserts the *right* predicate. The previous version checked `!= address(0)`, which is
        // "claimed by anyone" - it would have passed cleanly on a code a squatter had taken, which
        // is the single outcome it existed to catch.
        address expected = registry.NON_BINDABLE();
        for (uint256 i; i < reserved.length; ++i) {
            address owner = registry.referrerOf(reserved[i]);
            if (owner == address(0)) revert ReservedCodeNotClaimed(reserved[i]);
            if (owner != expected) revert ReservedCodeWrongOwner(reserved[i], owner);
        }

        console.log("ReferralRegistry  ", address(registry));
        console.log("reserved codes claimed:", reserved.length);
        console.log("Reserved codes are owned by NON_BINDABLE and cannot be bound to.");
        console.log("Next: record the address in the webapp env and docs. Nothing on-chain reads it.");
        console.log("Public-chain deployment remains disabled while the referral source design is open.");
    }

    function _requireSourceDesignSettled() internal pure {
        if (!SOURCE_DESIGN_SETTLED) revert SourceDesignOpen();
    }
}
