// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployReferralRegistry} from "../script/DeployReferral.s.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";

/// @notice Coverage for the referral deployment, which is deliberately separate from the protocol
///         deploy. The reserved-code seeding is one-shot and unrepeatable - once the address is
///         public, anything the script missed is claimable by anyone - so it runs in CI rather
///         than being trusted on the day.
contract DeployReferralTest is Test {
    uint256 internal constant ANVIL_CHAIN_ID = 31337;

    DeployReferralRegistry internal script;

    function setUp() public {
        script = new DeployReferralRegistry();
        vm.chainId(ANVIL_CHAIN_ID);
    }

    /// @dev Asserts the *owner*, not merely that someone owns it. The previous version of both the
    ///      script and this test checked `!= address(0)`, which is "claimed by anyone" - it passed
    ///      cleanly on a code a squatter had taken, the single outcome the check existed for. The
    ///      expected value is also derived from the contract's own constant rather than re-read
    ///      from the mapping under test, which is what made the old squatter test self-referential
    ///      and therefore vacuous.
    function test_deploy_claimsEveryReservedCodeToNonBindable() public {
        ReferralRegistry registry = script.run();
        address expected = registry.NON_BINDABLE();

        bytes32[16] memory reserved = [
            bytes32("RECOUP"),
            bytes32("RECOUPS"),
            bytes32("RECOUP-"),
            bytes32("-RECOUP"),
            bytes32("RECOUP_"),
            bytes32("_RECOUP"),
            bytes32("RECOUPFI"),
            bytes32("RECOUP-FI"),
            bytes32("RECOUP_FI"),
            bytes32("RECOUPFINANCE"),
            bytes32("RECOUP-FINANCE"),
            bytes32("RECOUP_FINANCE"),
            bytes32("OFFICIAL"),
            bytes32("SUPPORT"),
            bytes32("5UPPORT"),
            bytes32("ADMIN")
        ];

        for (uint256 i; i < reserved.length; ++i) {
            assertTrue(registry.isCanonical(reserved[i]), "a reserved code is malformed");
            assertEq(registry.referrerOf(reserved[i]), expected, "reserved code has the wrong owner");
        }
    }

    /// @dev Seeding happens in the constructor, so the registry is never live-and-unseeded. Done as
    ///      a loop of `register` calls inside a broadcast, those would be separate transactions
    ///      after the CREATE, against an address derivable from the deployer's nonce.
    function test_deploy_leavesNoWindowForASquatter() public {
        ReferralRegistry registry = script.run();
        address squatter = makeAddr("squatter");
        address nonBindable = registry.NON_BINDABLE();

        vm.expectRevert(
            abi.encodeWithSelector(ReferralRegistry.CodeTaken.selector, bytes32("RECOUP"), nonBindable)
        );
        vm.prank(squatter);
        registry.register(bytes32("RECOUP"));
    }

    /// @dev A user who guesses the obvious code does not silently burn their one-shot binding.
    function test_deploy_reservedCodesAreNotBindable() public {
        ReferralRegistry registry = script.run();
        address user = makeAddr("user");

        vm.expectRevert(
            abi.encodeWithSelector(ReferralRegistry.CodeNotBindable.selector, bytes32("OFFICIAL"))
        );
        vm.prank(user);
        registry.bind(bytes32("OFFICIAL"));
    }

    /// @dev DEXFI is deliberately absent. It is a counterparty's brand, ownership is permanent and
    ///      there is no transfer, so claiming it would mean the code bearing DexFi's name pays a
    ///      Recoup address forever - the exact arrangement the partner rule forbids.
    function test_deploy_doesNotClaimAPartnersBrand() public {
        ReferralRegistry registry = script.run();
        assertFalse(registry.isRegistered(bytes32("DEXFI")), "a partner brand was claimed");

        // And it remains claimable by the partner, to their own payout address.
        address dexfiPayout = makeAddr("dexfiPayout");
        vm.prank(dexfiPayout);
        registry.register(bytes32("DEXFI"));
        assertEq(registry.referrerOf(bytes32("DEXFI")), dexfiPayout);
    }

    /// @dev Unreserved codes stay open. The seeding is brand protection, not a land grab.
    function test_deploy_leavesTheRestOfTheNamespaceOpen() public {
        ReferralRegistry registry = script.run();
        address anyone = makeAddr("anyone");

        vm.prank(anyone);
        registry.register(bytes32("BERNARD"));
        assertEq(registry.referrerOf(bytes32("BERNARD")), anyone);
    }

    /// @dev The homoglyph family is closed by the charset, not by this list, so the list does not
    ///      need to grow combinatorially. Pins that the two mechanisms agree.
    function test_deploy_homoglyphsAreUnregisterableRatherThanReserved() public {
        ReferralRegistry registry = script.run();
        assertFalse(registry.isRegistered(bytes32("REC0UP")), "not reserved");
        assertFalse(registry.isCanonical(bytes32("REC0UP")), "and not registerable either");
    }

    /// @dev A stray `forge script` must not reach a public chain while the source design remains
    ///      open. Local construction stays available to the tests above.
    function test_deploy_refusesPublicChainWhileSourceDesignIsOpen() public {
        vm.chainId(84532);
        vm.expectRevert(DeployReferralRegistry.SourceDesignOpen.selector);
        script.run();
    }

    /// @dev Neuter-worthy guard: the exact legacy confirmation was previously sufficient to reach
    ///      broadcast. Removing the source-design check makes this call succeed and this test fail.
    ///      Calling the pure validator avoids `vm.setEnv`, whose process-global value leaks between
    ///      Foundry tests and made the old environment-driven test order-dependent.
    function test_deploy_legacyConfirmationCannotBypassOpenSourceDesign() public {
        vm.expectRevert(DeployReferralRegistry.SourceDesignOpen.selector);
        script.validateBroadcastApproval("RECOUP_DEPLOY_REFERRAL");
    }

    /// @dev Preserves the second gate's exact phrase for a future source-design disposition. Tests
    ///      it directly rather than through the process-global environment.
    function test_confirmation_acceptsOnlyTheExactPhrase() public view {
        assertTrue(script.isConfirmed("RECOUP_DEPLOY_REFERRAL"));
        assertFalse(script.isConfirmed(""));
        assertFalse(script.isConfirmed("recoup_deploy_referral"));
        assertFalse(script.isConfirmed("RECOUP_DEPLOY_REFERRAL "));
    }
}
