// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";

/// @dev A minimal smart-wallet call forwarder. A Safe performs the same registry calls from its
///      own address after applying its own authorization policy, which is outside this registry.
contract WalletAccount {
    function registerCode(ReferralRegistry registry, bytes32 code) external {
        registry.register(code);
    }

    function bindTo(ReferralRegistry registry, bytes32 code) external {
        registry.bind(code);
    }
}

contract ReferralRegistryTest is Test {
    ReferralRegistry internal registry;

    address internal alice = makeAddr("alice"); // referrer
    address internal bob = makeAddr("bob"); // referee
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant CODE = bytes32("BERNARD");
    bytes32 internal constant OTHER = bytes32("CAROL2");

    event CodeRegistered(bytes32 indexed code, address indexed referrer);
    event Bound(address indexed referee, bytes32 indexed code, address indexed referrer);

    function setUp() public {
        registry = new ReferralRegistry(new bytes32[](0));
    }

    function _register(address who, bytes32 code) internal {
        vm.prank(who);
        registry.register(code);
    }

    // ── Registration ─────────────────────────────────────────────────────────

    function test_register_assignsTheCodeToTheSender() public {
        _register(alice, CODE);
        assertEq(registry.referrerOf(CODE), alice);
        assertTrue(registry.isRegistered(CODE));
    }

    /// @dev `bytes32(0)` is the "unclaimed" sentinel. If it were registrable then
    ///      `referrerOf[0] != 0`, and every lookup of a code nobody owns would resolve to a real
    ///      payee - including `referrerFor` on every unbound account in existence.
    function test_register_rejectsTheZeroCode() public {
        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.MalformedCode.selector, bytes32(0)));
        vm.prank(alice);
        registry.register(bytes32(0));

        assertEq(registry.referrerOf(bytes32(0)), address(0));
        assertEq(registry.referrerFor(carol), address(0), "an unbound account must resolve to zero");
    }

    function test_register_isFirstComeAndRevertsOnACollision() public {
        _register(alice, CODE);

        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.CodeTaken.selector, CODE, alice));
        vm.prank(attacker);
        registry.register(CODE);

        assertEq(registry.referrerOf(CODE), alice, "the incumbent keeps it");
    }

    /// @dev Must revert, not silently succeed. A no-op that re-emits would put two registrations
    ///      of one code into the log, and the calculator would have to decide which is real.
    function test_register_revertsWhenTheOwnerReRegistersTheirOwnCode() public {
        _register(alice, CODE);

        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.CodeTaken.selector, CODE, alice));
        vm.prank(alice);
        registry.register(CODE);
    }

    /// @dev Pins the deliberate *absence* of a one-code-per-referrer rule, so a later pass does
    ///      not "fix" it. Partner integrations want a code per channel to measure with, and a
    ///      second address defeats such a rule for free anyway.
    function test_register_allowsOneReferrerToHoldManyCodes() public {
        _register(alice, CODE);
        _register(alice, bytes32("BERNARD-X"));
        _register(alice, bytes32("BERNARD_TG"));

        assertEq(registry.referrerOf(CODE), alice);
        assertEq(registry.referrerOf(bytes32("BERNARD-X")), alice);
        assertEq(registry.referrerOf(bytes32("BERNARD_TG")), alice);
    }

    function test_register_acceptsTheFullLegalCharset() public {
        _register(alice, bytes32("AZ29-_"));
        assertEq(registry.referrerOf(bytes32("AZ29-_")), alice);
    }

    /// @dev The case-collision entry is the security-relevant one: if `bernard` and `BERNARD` were
    ///      distinct codes, registering the variant of a partner's code would collect from
    ///      everyone who typed the other spelling.
    function test_register_rejectsNonCanonicalCodes() public {
        bytes32[9] memory bad = [
            bytes32("bernard"), // lowercase
            bytes32("BER NARD"), // space
            bytes32("BERNARD!"), // punctuation outside the charset
            bytes32("BERNARD."),
            bytes32(bytes.concat(bytes8("BERNARD"), bytes1(uint8(0x80)))), // high byte after the null
            bytes32("AB"), // under the minimum
            bytes32("ABCDEFGHIJKLMNOPQ"), // 17 bytes, over the maximum
            bytes32(0), // empty
            bytes32(uint256(1)) // right-aligned: leading nulls, not a left-aligned string
        ];

        for (uint256 i; i < bad.length; ++i) {
            assertFalse(registry.isCanonical(bad[i]), "isCanonical accepted a malformed code");
            vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.MalformedCode.selector, bad[i]));
            vm.prank(alice);
            registry.register(bad[i]);
        }
    }

    /// @dev The padding trap. `bytes32("AB\x00C")` prints as "AB" in any tool that stops at the
    ///      terminator, but is a different 32 bytes from `bytes32("AB")`. Allowing it would give
    ///      two distinct codes that are indistinguishable to a human reading the log.
    function test_register_rejectsInteriorNulls() public {
        bytes32 sneaky = bytes32(bytes.concat(bytes3("ABC"), bytes1(0), bytes3("DEF")));
        assertFalse(registry.isCanonical(sneaky));

        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.MalformedCode.selector, sneaky));
        vm.prank(alice);
        registry.register(sneaky);
    }

    function test_isCanonical_acceptsExactlyTheBoundaryLengths() public view {
        assertFalse(registry.isCanonical(bytes32("AB")), "min - 1");
        assertTrue(registry.isCanonical(bytes32("ABC")), "min");
        assertTrue(registry.isCanonical(bytes32("ABCDEFGHIJKLMNOP")), "max (16)");
        assertFalse(registry.isCanonical(bytes32("ABCDEFGHIJKLMNOPQ")), "max + 1");
    }

    /// @notice **Audit round 23, finding 22(b).** `isCanonical`'s NatSpec stated the charset twice
    ///         and the two statements disagreed: "uppercase `A-Z`, digits `0-9`, `-` and `_`"
    ///         against "`0` and `1` are deliberately excluded, leaving 36 symbols". The code
    ///         implements the second. The first is the sentence a frontend copies.
    ///
    /// @dev The expectation is the docstring **transcribed**, not the implementation restated. A
    ///      test that recomputed `0x41-0x5A || 0x32-0x39 || 0x2D || 0x5F` would agree with whatever
    ///      charset the code happened to have, which is the tautology this exists instead of - so
    ///      the literal below is the alphabet the prose names, character for character, and it is
    ///      load-bearing: MEASURED, putting `0` and `1` back into it alone fails this test at
    ///      `38 != 36` with the contract untouched.
    ///
    ///      **What it cannot catch, stated because the finding it closes is a prose defect.** This
    ///      pins the *code* to the transcription. Editing the source docstring back to "digits
    ///      `0-9`" without touching the loop was applied and the whole suite stayed green: no test
    ///      here reads the contract's source text, and `foundry.toml` sets no `fs_permissions`, so
    ///      none can. The prose side wants a doc-claim check outside Foundry.
    ///
    ///      Every byte 0x01-0xFF is tried in all three positions of a minimum-length code, so a
    ///      rule that happened to be position-dependent could not hide in the middle of one.
    function test_isCanonical_theAcceptedAlphabetIsExactlyTheThirtySix() public {
        bytes memory documented = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZ23456789-_");
        assertEq(documented.length, 36, "the docstring's own count, spelled out");

        uint256 accepted;
        for (uint256 c = 1; c < 256; ++c) {
            bytes1 b = bytes1(uint8(c));

            bool inDocumentedAlphabet;
            for (uint256 j; j < documented.length; ++j) {
                if (documented[j] == b) inDocumentedAlphabet = true;
            }

            bool first = registry.isCanonical(bytes32(bytes.concat(b, "AA")));
            bool middle = registry.isCanonical(bytes32(bytes.concat("A", b, "A")));
            bool last = registry.isCanonical(bytes32(bytes.concat("AA", b)));

            assertEq(first, inDocumentedAlphabet, "byte accepted in position 0 disagrees with the docstring");
            assertEq(middle, inDocumentedAlphabet, "byte accepted in position 1 disagrees with the docstring");
            assertEq(last, inDocumentedAlphabet, "byte accepted in position 2 disagrees with the docstring");

            if (first) accepted++;
        }

        emit log_named_uint("MEASURED distinct byte values the code accepts", accepted);
        assertEq(accepted, 36, "the '36 symbols' half of the docstring is the accurate half");
    }

    /// @dev The frontend uses `isCanonical` to tell "you typed it wrong" apart from "that code
    ///      does not exist", so the view and the enforcement must never disagree. Derived rather
    ///      than asserted: the property is checked against `register`'s actual behaviour.
    function testFuzz_isCanonical_agreesWithWhatRegisterAccepts(bytes32 code) public {
        bool canonical = registry.isCanonical(code);

        vm.prank(alice);
        try registry.register(code) {
            assertTrue(canonical, "register accepted a code isCanonical rejects");
        } catch (bytes memory err) {
            // Only MalformedCode proves non-canonicality; nothing else can revert on a fresh
            // registry with a fresh code.
            assertEq(bytes4(err), ReferralRegistry.MalformedCode.selector);
            assertFalse(canonical, "register rejected a code isCanonical accepts");
        }
    }

    // ── Binding ──────────────────────────────────────────────────────────────

    function test_bind_recordsTheCodeAndResolvesTheReferrer() public {
        _register(alice, CODE);

        vm.prank(bob);
        registry.bind(CODE);

        assertEq(registry.boundCode(bob), CODE);
        assertEq(registry.referrerFor(bob), alice);
    }

    /// @dev **The highest-value attack this contract can have, and the check that closes it.**
    ///      If binding to an unowned code were permitted, an attacker could watch for binds to
    ///      unregistered codes and register them afterwards, capturing an entire downstream they
    ///      did nothing to earn.
    function test_bind_revertsForAnUnregisteredCode() public {
        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.CodeNotRegistered.selector, CODE));
        vm.prank(bob);
        registry.bind(CODE);

        assertEq(registry.boundCode(bob), bytes32(0), "no binding was recorded");
    }

    /// @dev The residual of the above, and it does **not** simply "fail safe" as first written
    ///      here. Nobody is retroactively mis-attributed, which is the good half. The bad half is
    ///      that the reverting transaction is still mined with the code readable in its calldata,
    ///      so a failed bind publicly advertises an unclaimed code that a real user is actively
    ///      trying to use - a free targeting signal for a squatter, who then registers it and
    ///      collects the retry. This test pins that sequence rather than a reassurance: the
    ///      operational rule is claim-before-you-publish, not rely-on-the-revert.
    function test_bind_afterAFailedAttempt_attributesToWhoeverRegisteredItInTheMeantime() public {
        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.CodeNotRegistered.selector, CODE));
        vm.prank(bob);
        registry.bind(CODE);

        _register(attacker, CODE);
        assertEq(registry.referrerFor(bob), address(0), "the failed bind left nothing behind");

        vm.prank(bob);
        registry.bind(CODE);
        assertEq(registry.referrerFor(bob), attacker, "attribution follows the register, not the attempt");
    }

    /// @dev Stops the honest accident of pasting your own link. It is explicitly NOT sybil
    ///      resistance - see the companion test below.
    function test_bind_revertsOnSelfReferral() public {
        _register(alice, CODE);

        vm.expectRevert(ReferralRegistry.SelfReferral.selector);
        vm.prank(alice);
        registry.bind(CODE);
    }

    /// @dev Pins the *limit* of the check above so nobody mistakes it for a defence. A second
    ///      address defeats it for free, and the programme is designed on that assumption:
    ///      nothing is paid upfront, so the worst case is a capped rebate on a fee the user's own
    ///      capital genuinely generated.
    function test_bind_selfReferralIsDefeatedByASecondAddress() public {
        address aliceSecondWallet = makeAddr("aliceSecondWallet");
        _register(alice, CODE);

        vm.prank(aliceSecondWallet);
        registry.bind(CODE);

        assertEq(registry.referrerFor(aliceSecondWallet), alice, "documented, not prevented");
    }

    /// @dev Exercised under repetition rather than once per branch, per the standing lesson that
    ///      three round-2 findings were one mechanism missed because each branch ran exactly once.
    function test_bind_isOnceOnlyIncludingARebindToTheSameCode() public {
        _register(alice, CODE);
        _register(carol, OTHER);

        vm.prank(bob);
        registry.bind(CODE);

        for (uint256 i; i < 3; ++i) {
            // A different code.
            vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.AlreadyBound.selector, CODE));
            vm.prank(bob);
            registry.bind(OTHER);

            // And the identical code, which must also revert rather than no-op.
            vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.AlreadyBound.selector, CODE));
            vm.prank(bob);
            registry.bind(CODE);
        }

        assertEq(registry.referrerFor(bob), alice, "the original binding is untouched");
    }

    /// @dev Pins the absence of any `bindFor`/`bindWithSig`. Such a function would let anyone
    ///      permanently bind an address that has never touched the protocol, with no undo.
    function test_bind_cannotBeDoneOnBehalfOfAnother() public {
        _register(alice, CODE);

        vm.prank(attacker);
        registry.bind(CODE);

        assertEq(registry.referrerFor(attacker), alice, "the caller bound themselves");
        assertEq(registry.boundCode(bob), bytes32(0), "and nobody else");
    }

    function test_bind_worksForAContractAccount() public {
        _register(alice, CODE);
        WalletAccount wallet = new WalletAccount();

        wallet.bindTo(registry, CODE);

        assertEq(registry.referrerFor(address(wallet)), alice);
    }

    function test_referrerFor_returnsZeroForAnUnboundAccount() public view {
        assertEq(registry.referrerFor(bob), address(0));
        assertEq(registry.boundCode(bob), bytes32(0));
        assertFalse(registry.isRegistered(CODE));
    }

    // ── Events: these are the product ────────────────────────────────────────

    function test_register_emitsCodeRegistered() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit CodeRegistered(CODE, alice);
        vm.prank(alice);
        registry.register(CODE);
    }

    /// @dev All three fields indexed. The calculator joins on exactly these topics; de-indexing
    ///      any one of them forces it to scan every log in every block.
    function test_bind_emitsBoundWithAllThreeFieldsIndexed() public {
        _register(alice, CODE);

        vm.expectEmit(true, true, true, false, address(registry));
        emit Bound(bob, CODE, alice);
        vm.prank(bob);
        registry.bind(CODE);
    }

    /// @dev **The load-bearing test of the whole architecture.** Rewards are computed off-chain
    ///      from these logs alone, so if any state change were ever unlogged, the calculator would
    ///      silently disagree with the chain and nobody could reproduce the payouts. Replays the
    ///      recorded logs into local mappings and asserts they match contract storage exactly.
    function test_eventsAloneReconstructTheFullState() public {
        vm.recordLogs();

        _register(alice, CODE);
        _register(carol, OTHER);
        _register(alice, bytes32("SECOND"));
        vm.prank(bob);
        registry.bind(CODE);
        vm.prank(attacker);
        registry.bind(OTHER);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 registeredSig = keccak256("CodeRegistered(bytes32,address)");
        bytes32 boundSig = keccak256("Bound(address,bytes32,address)");

        bytes32[3] memory codes = [CODE, OTHER, bytes32("SECOND")];
        address[2] memory referees = [bob, attacker];

        // Rebuild code -> referrer purely from CodeRegistered.
        uint256 seenRegistrations;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != registeredSig) continue;
            ++seenRegistrations;
            bytes32 code = logs[i].topics[1];
            address referrer = address(uint160(uint256(logs[i].topics[2])));
            assertEq(registry.referrerOf(code), referrer, "replayed owner disagrees with storage");
        }
        assertEq(seenRegistrations, codes.length, "a registration went unlogged");

        // Rebuild referee -> code and referee -> referrer purely from Bound.
        uint256 seenBinds;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != boundSig) continue;
            ++seenBinds;
            address referee = address(uint160(uint256(logs[i].topics[1])));
            bytes32 code = logs[i].topics[2];
            address referrer = address(uint160(uint256(logs[i].topics[3])));
            assertEq(registry.boundCode(referee), code, "replayed code disagrees with storage");
            assertEq(registry.referrerFor(referee), referrer, "the denormalised referrer is wrong");
        }
        assertEq(seenBinds, referees.length, "a bind went unlogged");
    }

    // ── Permanence ───────────────────────────────────────────────────────────

    /// @dev Pins the absence of expiry. The 52-week window is a calculator rule applied over these
    ///      events; the binding itself never lapses, so a late re-run of the accrual script must
    ///      resolve attribution exactly as an early one did.
    function test_attributionResolvesIdenticallyAYearLater() public {
        _register(alice, CODE);
        vm.prank(bob);
        registry.bind(CODE);

        address before = registry.referrerFor(bob);
        vm.warp(block.timestamp + Config.REFERRAL_REFERRER_DURATION + 520 weeks);
        vm.roll(block.number + 5_000_000);

        assertEq(registry.referrerFor(bob), before, "attribution must be time-invariant");
        assertEq(registry.referrerOf(CODE), alice);
    }

    /// @dev Makes the no-owner decision executable. If a later pass adds `Ownable`, a pause, or
    ///      any admin setter, this fails and forces the author to justify deleting it. An owner
    ///      power over this registry is a power over who gets paid.
    function test_registryHasNoPrivilegedFunctions() public view {
        string[6] memory forbidden =
            ["owner()", "pause()", "unpause()", "paused()", "transferOwnership(address)", "renounceOwnership()"];

        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok,) = address(registry).staticcall(abi.encodeWithSignature(forbidden[i]));
            assertFalse(ok, "the registry grew a privileged function");
        }
    }

    // ── Homoglyphs: 0 and 1 are not in the alphabet ──────────────────────────

    /// @dev The whole reason `0` and `1` are barred. With them legal, `REC0UP` would be a distinct
    ///      claimable code rendering as the brand in a capitals-only string, and no reserved list
    ///      could ever cover the combinatorial substitution set. Barring two characters closes the
    ///      class by construction instead of by enumeration.
    function test_register_rejectsZeroAndOneAsLetterHomoglyphs() public {
        bytes32[6] memory lookalikes = [
            bytes32("REC0UP"), // 0 for O
            bytes32("0FFICIAL"),
            bytes32("ADM1N"), // 1 for I
            bytes32("RECOUPF1"),
            bytes32("SUPP0RT"),
            bytes32("REC0UP-F1")
        ];

        for (uint256 i; i < lookalikes.length; ++i) {
            assertFalse(registry.isCanonical(lookalikes[i]), "a homoglyph code was accepted");
            vm.expectRevert(
                abi.encodeWithSelector(ReferralRegistry.MalformedCode.selector, lookalikes[i])
            );
            vm.prank(attacker);
            registry.register(lookalikes[i]);
        }
    }

    /// @dev Digits 2-9 survive, so campaign codes keep their numbers.
    function test_register_acceptsDigitsTwoThroughNine() public {
        _register(alice, bytes32("SUMMER24"));
        assertEq(registry.referrerOf(bytes32("SUMMER24")), alice);
        assertFalse(registry.isCanonical(bytes32("SUMMER10")), "10 contains barred characters");
    }

    // ── Reserved codes are not bindable ──────────────────────────────────────

    /// @dev Reserved brand codes are exactly the strings an unreferred user guesses, and a binding
    ///      is one-shot and permanent. If they were owned by a normal address, anyone could publish
    ///      `/r/OFFICIAL` and every borrower who followed it would permanently burn their single
    ///      lifetime binding on a relationship the programme pays nothing for, locking out the real
    ///      referrer. `NON_BINDABLE` turns that silent permanent burn into an explainable revert.
    function test_bind_refusesAReservedCode() public {
        bytes32[] memory reserved = new bytes32[](1);
        reserved[0] = bytes32("OFFICIAL");
        ReferralRegistry seeded = new ReferralRegistry(reserved);

        assertEq(seeded.referrerOf(bytes32("OFFICIAL")), seeded.NON_BINDABLE());

        vm.expectRevert(
            abi.encodeWithSelector(ReferralRegistry.CodeNotBindable.selector, bytes32("OFFICIAL"))
        );
        vm.prank(bob);
        seeded.bind(bytes32("OFFICIAL"));

        assertEq(seeded.boundCode(bob), bytes32(0), "the one-shot binding is still available");
    }

    /// @dev And the refusal must not consume the binding: the user can still bind to a real code.
    function test_bind_afterARefusedReservedCode_theRealBindingStillWorks() public {
        bytes32[] memory reserved = new bytes32[](1);
        reserved[0] = bytes32("OFFICIAL");
        ReferralRegistry seeded = new ReferralRegistry(reserved);

        vm.prank(bob);
        try seeded.bind(bytes32("OFFICIAL")) {
            revert("should have reverted");
        } catch {}

        vm.prank(alice);
        seeded.register(CODE);
        vm.prank(bob);
        seeded.bind(CODE);

        assertEq(seeded.referrerFor(bob), alice);
    }

    // ── Constructor seeding ──────────────────────────────────────────────────

    /// @dev Seeding is in the constructor so creation and reservation are ONE transaction. Done as
    ///      a loop of `register` calls in a deploy broadcast, they are separate transactions
    ///      against an address derivable from the deployer's nonce, leaving a live registry with an
    ///      open `register` in between.
    function test_constructor_claimsEveryReservedCodeAtomically() public {
        bytes32[] memory reserved = new bytes32[](3);
        reserved[0] = bytes32("RECOUP");
        reserved[1] = bytes32("OFFICIAL");
        reserved[2] = bytes32("SUPPORT");

        ReferralRegistry seeded = new ReferralRegistry(reserved);

        for (uint256 i; i < reserved.length; ++i) {
            assertEq(seeded.referrerOf(reserved[i]), seeded.NON_BINDABLE());
        }
        // And nothing else was claimed.
        assertFalse(seeded.isRegistered(bytes32("BERNARD")));
    }

    function test_constructor_revertsOnADuplicateInTheList() public {
        bytes32[] memory reserved = new bytes32[](2);
        reserved[0] = bytes32("RECOUP");
        reserved[1] = bytes32("RECOUP");

        vm.expectRevert(
            abi.encodeWithSelector(
                ReferralRegistry.CodeTaken.selector,
                bytes32("RECOUP"),
                address(uint160(uint256(keccak256("recoup.referral.nonBindable"))))
            )
        );
        new ReferralRegistry(reserved);
    }

    /// @dev A malformed entry reverts the whole deployment rather than leaving a live registry with
    ///      part of a one-shot namespace unclaimed.
    function test_constructor_revertsOnAMalformedEntry() public {
        bytes32[] memory reserved = new bytes32[](2);
        reserved[0] = bytes32("RECOUP");
        reserved[1] = bytes32("rec0up");

        vm.expectRevert(
            abi.encodeWithSelector(ReferralRegistry.MalformedCode.selector, bytes32("rec0up"))
        );
        new ReferralRegistry(reserved);
    }

    // ── Partner self-registration ────────────────────────────────────────────

    /// @dev Pins the removed method by its literal selector so it cannot return under a renamed
    ///      interface or an accidentally restored ABI. With no fallback, an unknown selector
    ///      reverts with empty data and cannot write either one-shot mapping.
    function test_removedRegisterForSelector_revertsEmptyAndWritesNothing() public {
        address partner = makeAddr("partner");
        bytes memory callData = abi.encodeWithSelector(bytes4(0x791d1a9e), CODE, partner);

        vm.prank(attacker);
        (bool ok, bytes memory revertData) = address(registry).call(callData);

        assertFalse(ok, "the removed selector unexpectedly succeeded");
        assertEq(revertData.length, 0, "the removed selector did not hit the empty fallback revert");
        assertEq(registry.referrerOf(CODE), address(0), "the removed selector assigned a payee");
        assertEq(registry.boundCode(attacker), bytes32(0), "the caller's binding changed");
        assertEq(registry.boundCode(partner), bytes32(0), "the named payee's binding changed");
    }

    /// @dev Partner payout accounts need not be EOAs. A contract wallet calls `register` from its
    ///      own address and is therefore the immutable owner and resolved payee.
    function test_register_contractWalletSelfRegistersAsPayee() public {
        WalletAccount payoutWallet = new WalletAccount();

        payoutWallet.registerCode(registry, CODE);
        assertEq(registry.referrerOf(CODE), address(payoutWallet), "the wallet does not own the code");

        vm.prank(bob);
        registry.bind(CODE);
        assertEq(registry.boundCode(bob), CODE, "the referee did not bind to the wallet's code");
        assertEq(registry.referrerFor(bob), address(payoutWallet), "the wallet is not the payee");
    }
}
