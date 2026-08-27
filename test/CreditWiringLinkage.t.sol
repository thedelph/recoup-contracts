// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {CreditWiring} from "../src/CreditWiring.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {ILiquiditySource} from "../src/interfaces/ILiquiditySource.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice A source that will lend but refuses to be repaid, and still names this manager as the
///         counterparty of its own principal book.
/// @dev Exists to reach the one state `flushPrincipalTo` was written for: an `owedToSource` entry
///      standing against a source that `sourceStillAnswersToUs` answers **yes** about. That is the
///      state where the difference between "the source took it", "the source refused it" and "the
///      source is gone" decides between a booked repayment, a retryable refusal and a bare transfer
///      that corrupts the source's ledger - three outcomes chosen by two library answers.
contract RefusingSource is ILiquiditySource {
    IERC20 public immutable usdc;
    address public creditManager;

    constructor(IERC20 usdc_, address creditManager_) {
        usdc = usdc_;
        creditManager = creditManager_;
    }

    function lend(uint256 amount) external {
        usdc.transfer(msg.sender, amount);
    }

    function repayPrincipal(uint256) external pure {
        revert("RefusingSource: no");
    }

    function available() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}

/// @notice A substitute library that attests `pullPrincipal` **honestly** and forges only
///         `sourceStillAnswersToUs`.
/// @dev **Audit round 26 follow-up item 3, carried to round 27 as item 3 and to round 28 as item 4:
///      `sourceStillAnswersToUs`'s attestation had no independent falsifier.** Every substitute in
///      this file until now forged the whole library at once - `STOP_BYTE`, `RETURNS_TWO_ZERO_WORDS`
///      and `ECHOES_AMOUNT` are all selector-blind, so whichever member `flushPrincipalTo` reaches
///      first is the one that refuses. That member is `pullPrincipal`, two statements earlier, so
///      the arms above are red with **both** neutered and green with **only `pullPrincipal`**
///      restored. The follow-up item's own words: *"a round that removes the `pullPrincipal`
///      assertion removes this one's test coverage silently."*
///
///      This one is selector-aware, which is what makes it a falsifier for exactly one assertion.
///      `pullPrincipal` hands back the **real** `WIRING_CHECKED` with a truthful `delivered = 0`, so
///      it passes `_requireWiringRan` and cannot be what refuses anything;
///      `sourceStillAnswersToUs` hands back a zero tag with `ours = false`, which is the answer that
///      routes a bare transfer. Nothing but that member's own assertion stands between the two.
///
///      A compiled contract rather than a hex constant, because a selector dispatcher is what the
///      job needs and hand-assembling one is the sort of thing that fails silently. If the
///      selectors did not line up the fake would revert with no returndata and the arms below would
///      fail with a different error, not pass - so it is self-validating in the same way
///      `_linkedWiring` is.
contract AttestsThePullAndForgesTheSourceQuestion {
    /// @dev **A LIBRARY'S EXTERNAL SIGNATURE DOES NOT NORMALISE A CONTRACT TYPE TO `address`, and
    ///      that is why one member here is a function and the other is a fallback.** Written as an
    ///      ordinary `function pullPrincipal(IERC20, address, uint256, bool)`, this substitute
    ///      compiled, etched, and reverted with **empty returndata** - which reads exactly like a
    ///      wrong-but-coded library and made the arms below fail for a reason that was not the one
    ///      under test. MEASURED from the two artifacts: `CreditWiring` publishes
    ///      `pullPrincipal(IERC20,address,uint256,bool)` = `0xc962b845`, while the same declaration
    ///      in a *contract* publishes `pullPrincipal(address,address,uint256,bool)` = `0x8237a84b`.
    ///      `sourceStillAnswersToUs(address)` has no user-defined type in it, so its selector is
    ///      `0x497d41c9` on both and it is declared normally below.
    ///
    ///      The constant is derived from the signature string rather than written as four bytes, so
    ///      a rename of the library member makes this test fail loudly on `unexpected selector`
    ///      rather than silently stop reaching the branch it exists to reach.
    bytes4 internal constant PULL_PRINCIPAL = bytes4(keccak256("pullPrincipal(IERC20,address,uint256,bool)"));

    function sourceStillAnswersToUs(address) external pure returns (bytes32, bool) {
        return (bytes32(0), false);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        require(bytes4(data) == PULL_PRINCIPAL, "substitute: unexpected selector");
        // The honest half: the real tag, and a truthful report that nothing was delivered.
        return abi.encode(CreditWiring.WIRING_CHECKED, uint256(0));
    }
}

/// @title CreditWiringLinkage
/// @notice Audit round 24, follow-up item 2: what `CreditManager` can tell about the library it
///         `DELEGATECALL`s, and what it could not tell before this commit.
///
/// @dev **The finding, in one sentence.** `CreditWiring` is reached at an address the linker writes
///      into `CreditManager`'s bytecode, which nothing on chain verifies; two of its five members
///      returned nothing; so for those two "the delegatecall did not revert" was read as "every
///      clause passed", and `CreditManager.setLiquidationAuction` has no clause of its own. Eight
///      of twelve agents found it independently.
///
///      **What the defect is NOT, because it was measured last round and re-deriving it wastes a
///      round.** A *missing* library address fails CLOSED, and always did: solc 0.8.24 emitted an
///      `EXTCODESIZE` guard ahead of exactly the two void-returning delegatecalls. The residual is
///      a **wrong-but-coded** address - a stale library carried across a redeploy, which is the
///      mistake this project already made once with `ReferralRegistry` in round 22. Any code at all
///      passes an `EXTCODESIZE` guard, and with a void return there was nothing left to check.
///      `test_R24_anEmptyLibraryAddressStillFailsClosed` keeps the settled half settled, because
///      the fix moves *why* it holds from a compiler emission to a returndata decode.
///
///      **How the tests reach it.** `vm.etch` at the linked library address, which is recovered
///      from `CreditManager`'s own runtime code by `_linkedWiring` below. The three substitutes are
///      the shapes a wrong-but-coded address actually takes: no code at all; a bare `STOP`, which
///      is what the finding was measured with and is any contract whose fallback does nothing; and
///      five bytes that return one zero word, which is any contract whose fallback returns
///      something. The first two are caught by the ABI decoder now that there is a value to decode,
///      the third by `CreditManager._requireWiringRan` comparing it to `CreditWiring
///      .WIRING_CHECKED`.
///
///      **`_linkedWiring` is self-validating and does not need to be trusted.** If it returned the
///      wrong address, etching over it would change no behaviour and every test here would fail
///      rather than pass - and `test_control_theRealLibraryStillInstallsBothPointers` restores the
///      saved code and requires both setters to work again, so a false positive cannot hide.
///
///      **AUDIT ROUND 25, FINDINGS 1 (HIGH), 3 AND 5 - THE OTHER THREE MEMBERS.** Round 24's fix
///      stopped at the two members that returned nothing, on the argument that "the three that
///      already returned a value always had their returndata checked". That is a claim about the
///      answer being **decodable**, and the question is whether the real body **ran** - the same
///      substitution round 24 found one level up. The substitutes below make the difference
///      concrete: `ECHOES_AMOUNT` is eleven bytes that report full delivery of whatever was asked
///      for while moving nothing, and its answer decodes perfectly.
///
///      The three arms named `test_R25_...` are the finding as executed, with a control beside each
///      one, and they are what the round-25 ledger entry was measured with. What they check is not
///      only that the call reverts but that the **counters and balances are where they started**:
///      the defect in every case is a number moving without money moving, or money moving without a
///      number, and a test that only asserts a revert cannot tell those apart.
contract CreditWiringLinkageTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant FLOAT = 100_000e6;

    /// @dev One `STOP`. The substitute the finding was measured with: a delegatecall to it succeeds
    ///      and returns nothing at all.
    bytes internal constant STOP_BYTE = hex"00";

    /// @dev `PUSH1 0x20 PUSH1 0x00 RETURN` - returns thirty-two zero bytes. Any wrong contract
    ///      whose fallback returns *something* looks like this to the caller, and it is the shape
    ///      an `EXTCODESIZE` guard and a returndata-length check both wave through.
    bytes internal constant RETURNS_A_ZERO_WORD = hex"60206000f3";

    /// @dev `PUSH1 0x40 PUSH1 0x00 RETURN` - sixty-four zero bytes, which is the same shape one word
    ///      wider. Needed because the three members attested in round 25 return a *pair*, so a
    ///      32-byte answer is now refused by the ABI decoder before the attestation is ever compared.
    ///      Using it is what keeps those arms testing `_requireWiringRan` rather than the decoder.
    bytes internal constant RETURNS_TWO_ZERO_WORDS = hex"60406000f3";

    /// @dev `PUSH1 0x44 CALLDATALOAD PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN` - eleven bytes
    ///      that read `pullPrincipal`'s third argument straight out of calldata and hand it back as
    ///      `delivered`, having moved nothing.
    ///
    ///      **This is the substitute audit round 25's High was measured with, and it is the shape
    ///      the round-24 argument could not see.** It is not malformed, not empty and not a zero
    ///      word. It is a well-formed, entirely plausible answer to the question "how much arrived",
    ///      invented by code that made no transfer - which is why "the returndata was always
    ///      checked" was never an answer. Against the pre-fix contract it took `pendingPrincipal`
    ///      5,000,000,000 to 0 with every balance in the system unchanged.
    bytes internal constant ECHOES_AMOUNT = hex"60443560005260206000f3";

    /// @dev The same echo, one word further into memory, so the pair `(bytes32, uint256)` decodes as
    ///      `(0, amount)`. The 32-byte version above is refused by the decoder once `pullPrincipal`
    ///      returns a pair, so it can no longer reach the attestation; this one can, and is
    ///      therefore the arm that proves `_requireWiringRan` is doing the work rather than solc.
    bytes internal constant ATTESTS_ZERO_AND_ECHOES_AMOUNT = hex"60443560205260406000f3";

    /// @dev A 5,000.000000 loan, which is exactly `Config.DEFAULT_PER_ACCOUNT_BORROW_CAP` and the
    ///      figure the round-25 finding was measured at.
    uint256 internal constant LOAN = 5_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");
    address internal harvesterAddr = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal liquidity;

    /// @dev The linked library, and the code that was there before a test etched over it.
    address internal wiring;
    bytes internal realWiringCode;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvesterAddr);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        wiring = _linkedWiring(address(credit));
        realWiringCode = wiring.code;
    }

    // ── locating the link ────────────────────────────────────────────────────

    /// @dev Walks `linked`'s runtime code opcode by opcode and returns the most-repeated `PUSH20`
    ///      operand that has code deployed at it. `CreditManager` delegatecalls `CreditWiring` from
    ///      five sites, so the library address is pushed five times; nothing else in that bytecode
    ///      is an address with code behind it. Immutables are 32-byte pushes and cannot collide.
    ///
    ///      Deliberately derived rather than written down. A hard-coded address, or forge's
    ///      library-deployer nonce, is exactly the kind of literal this repo has watched go stale -
    ///      and the address moves whenever anything above it in `setUp` changes.
    function _linkedWiring(address linked) internal returns (address found) {
        bytes memory code = linked.code;
        address[] memory candidates = new address[](32);
        uint256[] memory hits = new uint256[](32);
        uint256 n;

        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0x73 && i + 21 <= code.length) {
                address candidate;
                assembly {
                    candidate := shr(96, mload(add(add(code, 0x20), add(i, 1))))
                }
                if (candidate.code.length != 0) {
                    uint256 slot = type(uint256).max;
                    for (uint256 j; j < n; j++) {
                        if (candidates[j] == candidate) {
                            slot = j;
                            break;
                        }
                    }
                    if (slot == type(uint256).max && n < candidates.length) {
                        slot = n++;
                        candidates[slot] = candidate;
                    }
                    if (slot != type(uint256).max) hits[slot]++;
                }
                i += 21;
            } else if (op >= 0x60 && op <= 0x7f) {
                i += uint256(op) - 0x5f + 1;
            } else {
                i += 1;
            }
        }

        uint256 best;
        for (uint256 j; j < n; j++) {
            if (hits[j] > best) {
                best = hits[j];
                found = candidates[j];
            }
        }
        assertGe(best, 2, "fixture: no repeated linked-library address in CreditManager's runtime");
        assertTrue(found != address(0), "fixture: no linked library found");
    }

    /// @notice The fixture's own premise, asserted rather than assumed: the address recovered from
    ///         the bytecode is a real deployment and is not one of the protocol contracts. And the
    ///         attestation tag is not the zero word, which is what makes the third substitute below
    ///         a real test rather than a coincidence.
    function test_fixture_theLinkedLibraryIsFoundAndIsNotAProtocolContract() public view {
        assertTrue(CreditWiring.WIRING_CHECKED != bytes32(0), "a zero tag would be forged by any fallback");
        assertTrue(CreditWiring.WIRING_CHECKED != bytes32(uint256(1)), "and so would a boolean one");
        assertGt(wiring.code.length, 1_000, "the linked library has no substantial code");
        assertTrue(wiring != address(credit), "that is the manager, not the library");
        assertTrue(wiring != address(vault), "that is the vault");
        assertTrue(wiring != address(auction), "that is the auction");
        assertTrue(wiring != address(riskParams), "that is the risk parameters");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Follow-up item 2. `setLiquidationAuction`, the member with no clause of its own.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **THE REGRESSION.** With one `STOP` byte at the library address, the manager used to
    ///         install a bare EOA as the liquidation auction and report success. It now refuses.
    /// @dev MEASURED at round 24 across five independent executions, and this is that measurement
    ///      as a test. The old `checkAuctionSwap` returned nothing, so the whole guard body -
    ///      zero-address refusal, outgoing-work guard, three agreement clauses, three completeness
    ///      probes - collapsed into "the delegatecall did not revert". After the pointer moved,
    ///      `repay` reverted for every borrower and repointing at a freshly deployed real auction
    ///      reverted too: unrecoverable.
    ///
    ///      There is no `WiringLibraryUnverified` here on purpose. A `STOP` returns no data at all,
    ///      so the ABI decoder refuses before the attestation can be compared - which is the point
    ///      of giving the function a return value in the first place. The next test is the arm
    ///      where the comparison is what does the work.
    function test_R24_aStopByteAtTheLibraryAddressCannotInstallAnEoaAsTheAuction() public {
        vm.etch(wiring, STOP_BYTE);

        vm.prank(admin);
        vm.expectRevert();
        credit.setLiquidationAuction(stranger);

        assertEq(credit.liquidationAuction(), address(auction), "an EOA installed as the auction");
    }

    /// @notice And an address with **no code at all** still fails closed, which is the half of the
    ///         claim that stopped being a compiler fact and became a behavioural one.
    /// @dev Before this commit that was true because solc emitted an `EXTCODESIZE` guard ahead of
    ///      exactly the two void-returning delegatecalls. It now emits none at any of the five link
    ///      sites, because for a value-returning call the returndata-length check subsumes it -
    ///      measured on the shipped runtime: no `0x3b` byte within 120 bytes either side of any of
    ///      the five link-reference offsets. That is a compiler-version-dependent measurement, so
    ///      this arm asserts the property the protocol actually needs, in a way no compiler change
    ///      can quietly falsify. **Re-run and re-measure if `solc_version` moves.**
    function test_R24_anEmptyLibraryAddressStillFailsClosed() public {
        vm.etch(wiring, hex"");
        assertEq(wiring.code.length, 0, "premise: the library address holds no code");

        vm.prank(admin);
        vm.expectRevert();
        credit.setLiquidationAuction(stranger);

        assertEq(credit.liquidationAuction(), address(auction), "an EOA installed as the auction");
    }

    /// @notice The wrong-but-coded case the finding actually turns on: a library whose fallback
    ///         returns a word. The decoder is satisfied and the attestation is what refuses it.
    /// @dev This is the shape an `EXTCODESIZE` guard cannot see and a returndata-length check
    ///      cannot see either. It is also why the tag is a domain-separated `keccak256` and not a
    ///      bare `true`: the substitute below returns the zero word, and a great deal of accidental
    ///      code returns one.
    function test_R24_codeThatMerelyReturnsAWordCannotInstallAnEoaAsTheAuction() public {
        vm.etch(wiring, RETURNS_A_ZERO_WORD);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.setLiquidationAuction(stranger);

        assertEq(credit.liquidationAuction(), address(auction), "an EOA installed as the auction");
    }

    /// @notice And the same substitute cannot walk a *plausible* wrong pointer past the guard
    ///         either - a real, fully conforming auction bound to a different vault.
    /// @dev The EOA above is the loudest case; this is the realistic one. A second `CollateralVault`
    ///      with its own auction is what a migration half-done looks like, and
    ///      `LiquidationAuctionVaultMismatch` is the clause that catches it - a clause that lives
    ///      entirely inside the library and therefore stopped existing when the library did.
    function test_R24_aWrongLibraryCannotWalkAnAuctionOnAnotherVaultPastTheGuard() public {
        CollateralVault otherVault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        LiquidationAuction foreign = new LiquidationAuction(
            usdc,
            ICollateralVault(address(otherVault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );

        // The real library refuses it, which is the clause being protected.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LiquidationAuctionVaultMismatch.selector, address(otherVault))
        );
        credit.setLiquidationAuction(address(foreign));

        // And a substituted library cannot turn that refusal into a success.
        vm.etch(wiring, RETURNS_A_ZERO_WORD);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.setLiquidationAuction(address(foreign));

        assertEq(credit.liquidationAuction(), address(auction), "the foreign auction installed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Follow-up item 2. `setLenderPool`, the other void member.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The second void member, reached through `setLenderPool`.
    /// @dev `setLenderPool` calls two library members: `fundsAsALenderPool`, which always returned
    ///      a value and so always had its returndata checked, and `checkLenderPoolSwap`, which did
    ///      not. The substitute here answers the first one's decoder - a zero word reads as `false`,
    ///      which is what a treasury funder answers anyway - and is caught at the second. That
    ///      ordering is the reason this arm needs the word-returning substitute rather than the
    ///      `STOP`: under a `STOP` the setter would fail at the *first* call and prove nothing about
    ///      the second.
    ///
    ///      **Round 25 changed which of the two refuses, and the comment above is left standing as
    ///      the record of why it used to be the second.** `fundsAsALenderPool` is attested now, so
    ///      it returns a pair, so the one-word substitute no longer decodes at the *first* call and
    ///      the setter never reaches the second. The revert is therefore the ABI decoder's, with no
    ///      data - a bare `expectRevert`, and strictly earlier than before. The arm below carries
    ///      the original intent forward with a substitute wide enough to get past the decoder.
    function test_R24_aWrongLibraryCannotSkipTheLenderPoolSwapClauses() public {
        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.etch(wiring, RETURNS_A_ZERO_WORD);

        vm.prank(admin);
        vm.expectRevert();
        credit.setLenderPool(address(pool));

        assertEq(credit.lenderPool(), address(0), "the pool installed without its clauses running");
    }

    /// @notice The same claim with a substitute the decoder accepts, so the attestation is what
    ///         refuses rather than solc.
    /// @dev Worth having as its own arm rather than as an edit to the one above. A test that passes
    ///      because the returndata was the wrong *length* is testing the compiler, and the whole of
    ///      round 25's finding 1 is that length is not the property anybody needed. Sixty-four zero
    ///      bytes decode as `(bytes32(0), false)` at `fundsAsALenderPool` and as `bytes32(0)` at
    ///      `checkLenderPoolSwap`, so both members are reachable and `_requireWiringRan` is the only
    ///      thing standing in the way.
    function test_R25_aWideEnoughSubstituteIsStoppedByTheAttestationNotTheDecoder() public {
        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.etch(wiring, RETURNS_TWO_ZERO_WORDS);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.setLenderPool(address(pool));

        assertEq(credit.lenderPool(), address(0), "the pool installed without its clauses running");
    }

    /// @notice And with the guard body neutralised, `address(0)` used to be installable as the loss
    ///         sink - `ZeroAddress` is a library clause too.
    /// @dev Worth its own arm because it is the clause a reader most expects to be in the setter.
    ///      Every clause `setLenderPool` owes is in the library, including this one.
    ///
    ///      Widened to `RETURNS_TWO_ZERO_WORDS` in round 25 for the reason the arm above records:
    ///      `fundsAsALenderPool` now returns a pair and runs first, so a one-word substitute is
    ///      refused by the decoder before the attestation is consulted. The wider one keeps this
    ///      arm's subject the attestation.
    function test_R24_aWrongLibraryCannotInstallTheZeroAddressAsTheLossSink() public {
        vm.etch(wiring, RETURNS_TWO_ZERO_WORDS);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.setLenderPool(address(0));

        assertEq(credit.lenderPool(), address(0), "premise: the pointer was never set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 25, finding 1 (High). `pullPrincipal`, which returns a measurement
    // of money rather than a verdict - and `flushPrincipalTo`, which is worse.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Borrow the round's figure against collateral and repay it, leaving `pendingPrincipal`
    ///      at 5,000.000000 and the same amount of USDC sitting in `CreditManager` waiting to go
    ///      home. That pair - a counter and a balance that must move together - is the whole subject
    ///      of the finding, so both are read before and after in every arm below.
    function _parkPendingPrincipal() internal {
        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(1_000);
        credit.borrow(LOAN);
        usdc.approve(address(credit), LOAN);
        credit.repay(LOAN);
        vm.stopPrank();
    }

    /// @dev The other counter, `owedToSource`, which is the one with a single drain, no owner rescue
    ///      and an explicit exclusion from `sweepFreeBalanceToInsurance`. Reaching a parked entry
    ///      means routing a loan through a source that will not take its principal back: park
    ///      against the treasury, move the pointer to a refusing source, borrow and repay again, then
    ///      move it back. The second repoint cannot deliver, so it checkpoints.
    function _parkOwedToSource() internal returns (RefusingSource refuser) {
        _parkPendingPrincipal();
        refuser = new RefusingSource(IERC20(address(usdc)), address(credit));
        usdc.mint(address(refuser), LOAN);

        vm.prank(admin);
        credit.setLiquiditySource(address(refuser)); // settles the treasury on the way past

        vm.startPrank(alice);
        credit.borrow(LOAN);
        usdc.approve(address(credit), LOAN);
        credit.repay(LOAN);
        vm.stopPrank();

        vm.prank(admin);
        credit.setLiquiditySource(address(liquidity)); // the refuser cannot take it: parked

        assertEq(credit.owedToSource(address(refuser)), LOAN, "fixture: nothing was parked");
    }

    /// @notice **THE HIGH, AS MEASURED.** A library that reports full delivery and moves nothing
    ///         used to take `pendingPrincipal` from 5,000.000000 to zero while every balance in the
    ///         system stood still. It now refuses, and the counter and the balance are both intact.
    /// @dev The pre-fix numbers, which this arm is the regression for: `pendingPrincipal`
    ///      5,000,000,000 -> **0**; `CreditManager` USDC unchanged at 5,000,000,000;
    ///      `TreasuryLiquiditySource` unchanged at 95,000,000,000. The control below moves the
    ///      5,000,000,000 and empties the manager, which is what the counter going to zero is
    ///      supposed to mean.
    ///
    ///      `settlePrincipal` is permissionless and takes no arguments, so this is not an
    ///      owner-only path like the round-24 arms: anybody could have called it in the window where
    ///      a wrong library was linked, and the counter recording what the funder is owed would have
    ///      been destroyed by a stranger for the price of the gas.
    ///
    ///      The revert here is the ABI decoder's, because `ECHOES_AMOUNT` returns one word against a
    ///      pair. That is deliberate and it is the *original* substitute rather than a widened one:
    ///      this arm's job is to reproduce the finding's own measurement and show it refused. The
    ///      arm after it is the one that proves the attestation, not the decoder, is load-bearing.
    function test_R25_aSubstituteReportingFullDeliveryCannotZeroPendingPrincipal() public {
        _parkPendingPrincipal();
        assertEq(credit.pendingPrincipal(), LOAN, "premise: the source is owed the loan");
        assertEq(usdc.balanceOf(address(credit)), LOAN, "premise: and the money is here to send");
        uint256 treasuryBefore = usdc.balanceOf(address(liquidity));

        vm.etch(wiring, ECHOES_AMOUNT);
        vm.expectRevert();
        credit.settlePrincipal();

        assertEq(credit.pendingPrincipal(), LOAN, "the counter was cleared without money moving");
        assertEq(usdc.balanceOf(address(credit)), LOAN, "the manager's balance moved");
        assertEq(usdc.balanceOf(address(liquidity)), treasuryBefore, "the treasury's balance moved");
    }

    /// @notice And a substitute wide enough for the new decoder is refused by the attestation
    ///         itself, naming the forged word.
    /// @dev `(bytes32(0), amount)`. Everything about this answer is well-formed: right arity, right
    ///      types, and a `delivered` figure that is exactly what a successful settlement would have
    ///      reported. It is refused because `bytes32(0)` is not `WIRING_CHECKED`, which is the only
    ///      property of the answer that a fallback cannot manufacture.
    function test_R25_aWellFormedForgedDeliveryIsRefusedByTheAttestation() public {
        _parkPendingPrincipal();
        uint256 treasuryBefore = usdc.balanceOf(address(liquidity));

        vm.etch(wiring, ATTESTS_ZERO_AND_ECHOES_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.settlePrincipal();

        assertEq(credit.pendingPrincipal(), LOAN, "the counter was cleared without money moving");
        assertEq(usdc.balanceOf(address(credit)), LOAN, "the manager's balance moved");
        assertEq(usdc.balanceOf(address(liquidity)), treasuryBefore, "the treasury's balance moved");
    }

    /// @notice **CONTROL.** The real library moves the money and clears the counter together.
    /// @dev The failure mode this rules out is an attestation that refuses everything, in which case
    ///      the two arms above would pass for a reason that has nothing to do with the finding.
    function test_control_theRealLibrarySettlesPrincipalForReal() public {
        _parkPendingPrincipal();
        uint256 treasuryBefore = usdc.balanceOf(address(liquidity));

        credit.settlePrincipal();

        assertEq(credit.pendingPrincipal(), 0, "the counter did not clear");
        assertEq(usdc.balanceOf(address(credit)), 0, "the manager kept the principal");
        assertEq(usdc.balanceOf(address(liquidity)), treasuryBefore + LOAN, "the source was not paid");
    }

    /// @notice `flushPrincipalTo` is the same shape and worse, which the finding asserted by
    ///         inspection and this arm executes: the same substitute burns a parked entry outright.
    /// @dev Worse for a reason about the counter rather than about the code. `flushPrincipalTo`
    ///      zeroes `owedToSource[source]` *before* it calls, and re-parks only `amount - delivered`
    ///      afterwards - so a forged full delivery re-parks nothing. And `owedToSource` has exactly
    ///      one drain, no owner rescue, and is excluded from `sweepFreeBalanceToInsurance`, so there
    ///      is no second route to the money once the entry is gone.
    ///
    ///      MEASURED pre-fix: `owedToSource` 5,000,000,000 -> **0**, `totalOwedToSources` likewise,
    ///      `PrincipalFlushed` emitted, and **not one unit of USDC moved anywhere**. Compare the
    ///      `pendingPrincipal` case above, where the money at least stayed in a contract that still
    ///      had a counter for it.
    function test_R25_aSubstituteReportingFullDeliveryCannotBurnAParkedEntry() public {
        RefusingSource refuser = _parkOwedToSource();
        uint256 creditBefore = usdc.balanceOf(address(credit));

        vm.etch(wiring, ECHOES_AMOUNT);
        vm.expectRevert();
        credit.flushPrincipalTo(address(refuser));

        assertEq(credit.owedToSource(address(refuser)), LOAN, "the park was burnt");
        assertEq(credit.totalOwedToSources(), LOAN, "the total was burnt");
        assertEq(usdc.balanceOf(address(credit)), creditBefore, "the manager's balance moved");
        assertEq(usdc.balanceOf(address(refuser)), 0, "the refuser was paid");
    }

    /// @notice The second forged answer on the same path: a substitute that says nothing was
    ///         delivered *and* that the source no longer answers to this manager pays it by bare
    ///         transfer - audit round 23's finding 1, reconstituted out of two lies.
    /// @dev This is why `sourceStillAnswersToUs` is attested rather than left to be covered by the
    ///      `pullPrincipal` assertion two statements earlier. Both members are forged here by the
    ///      same one address, and the outcome is the route `LenderPool.repayPrincipal`'s own
    ///      docstring says "would look like idle capital and leave `outstandingPrincipal`
    ///      overstated" - the overstatement that welds a pool to a manager for good.
    ///
    ///      MEASURED pre-fix: `owedToSource` 5,000,000,000 -> 0 and **5,000,000,000 USDC transferred
    ///      bare** to a source whose `creditManager()` still names this manager.
    function test_R25_aForgedNotOursCannotBareTransferToASourceThatStillAnswers() public {
        RefusingSource refuser = _parkOwedToSource();
        assertEq(refuser.creditManager(), address(credit), "premise: the source still answers to us");
        uint256 creditBefore = usdc.balanceOf(address(credit));

        vm.etch(wiring, RETURNS_TWO_ZERO_WORDS);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.flushPrincipalTo(address(refuser));

        assertEq(credit.owedToSource(address(refuser)), LOAN, "the park was burnt");
        assertEq(usdc.balanceOf(address(credit)), creditBefore, "the manager's balance moved");
        assertEq(usdc.balanceOf(address(refuser)), 0, "a source that still answers to us was paid bare");
    }

    /// @notice **PREMISE for the falsifier below, and the half that makes it independent.** Under
    ///         the selector-aware substitute, `pullPrincipal`'s attestation is genuine and is
    ///         accepted: `settlePrincipal` reaches that member and no other, and it does not revert.
    /// @dev Without this arm the falsifier is only *probably* independent. `settlePrincipal` runs
    ///      `_deliverPrincipal` -> `_pullPrincipal` -> `_requireWiringRan`, and nothing else in that
    ///      call touches the library - so a substitute whose `pullPrincipal` tag were wrong would
    ///      revert `WiringLibraryUnverified` right here. It does not, which is the fact the next
    ///      test needs and cannot observe from inside itself.
    ///
    ///      The `delivered = 0` is honest rather than forged: the fake moves no money and says so,
    ///      which is why the counter and both balances stand still. That is deliberately **not** the
    ///      round-25 High - `ECHOES_AMOUNT` is the substitute that lies about the measurement, and
    ///      it is tested above. This one lies about exactly one thing.
    function test_R28_premise_theSelectorAwareSubstitutesPullAttestationIsAccepted() public {
        _parkPendingPrincipal();
        uint256 treasuryBefore = usdc.balanceOf(address(liquidity));
        uint256 creditBefore = usdc.balanceOf(address(credit));

        vm.etch(wiring, address(new AttestsThePullAndForgesTheSourceQuestion()).code);

        // No `expectRevert`. The point of the arm is that this call goes through.
        credit.settlePrincipal();

        assertEq(credit.pendingPrincipal(), LOAN, "an honest delivery of nothing moved the counter");
        assertEq(usdc.balanceOf(address(credit)), creditBefore, "the manager's balance moved");
        assertEq(usdc.balanceOf(address(liquidity)), treasuryBefore, "the treasury's balance moved");
    }

    /// @notice **Audit round 26 follow-up item 3, carried through rounds 27 and 28 (item 4): the
    ///         attestation on `sourceStillAnswersToUs` now has a falsifier that does not run through
    ///         the `pullPrincipal` assertion.**
    /// @dev The follow-up item, in its own words: *"it is pinned as defence in depth only - red with
    ///      both neutered, green with only it restored"*, and *"a round that removes the
    ///      `pullPrincipal` assertion removes this one's test coverage silently"*. That was true of
    ///      every substitute in this file, because all of them are selector-blind and
    ///      `flushPrincipalTo` reaches `pullPrincipal` first and unconditionally.
    ///
    ///      `AttestsThePullAndForgesTheSourceQuestion` forges **one** member. The test above proves
    ///      its `pullPrincipal` tag is accepted, so the only assertion left that can refuse this
    ///      flush is `_sourceStillAnswersToUs`'s own.
    ///
    ///      MEASURED with **only** the `_requireWiringRan` line deleted from
    ///      `CreditManager._sourceStillAnswersToUs` and everything else in the tree untouched:
    ///      `owedToSource[refuser]` **5,000,000,000 -> 0**, `totalOwedToSources` 5,000,000,000 -> 0,
    ///      and **5,000.000000 USDC transferred bare** out of the manager to a source whose
    ///      `creditManager()` still names it - audit round 23's finding 1 reconstituted out of a
    ///      **single** lie rather than two. With the line restored the flush reverts
    ///      `WiringLibraryUnverified(0)` and every one of those three figures is unmoved.
    ///
    ///      This is the arm to keep if the file is ever pruned. The round-25 arm above it can pass
    ///      for a reason that has nothing to do with this member; this one cannot.
    function test_R28_theSourceQuestionsAttestationHasAnIndependentFalsifier() public {
        RefusingSource refuser = _parkOwedToSource();
        assertEq(refuser.creditManager(), address(credit), "premise: the source still answers to us");
        uint256 creditBefore = usdc.balanceOf(address(credit));

        vm.etch(wiring, address(new AttestsThePullAndForgesTheSourceQuestion()).code);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.flushPrincipalTo(address(refuser));

        assertEq(credit.owedToSource(address(refuser)), LOAN, "the park was burnt");
        assertEq(credit.totalOwedToSources(), LOAN, "the total was burnt");
        assertEq(usdc.balanceOf(address(credit)), creditBefore, "the manager's balance moved");
        assertEq(usdc.balanceOf(address(refuser)), 0, "a source that still answers to us was paid bare");
    }

    /// @notice **CONTROL.** With the real library the same flush is refused loudly, by name, and
    ///         nothing moves - which is the behaviour round 23 finding 1 installed.
    /// @dev The distinction the arms above would be worthless without: `PrincipalRefused` leaves the
    ///      park intact and the flush retryable forever, whereas both forged answers destroyed it.
    ///      A revert is not the property being tested; *which* revert, and what survives it, is.
    function test_control_theRealLibraryRefusesAndKeepsThePark() public {
        RefusingSource refuser = _parkOwedToSource();
        uint256 creditBefore = usdc.balanceOf(address(credit));

        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.PrincipalRefused.selector, address(refuser), LOAN)
        );
        credit.flushPrincipalTo(address(refuser));

        assertEq(credit.owedToSource(address(refuser)), LOAN, "the park did not survive the refusal");
        assertEq(usdc.balanceOf(address(credit)), creditBefore, "the manager's balance moved");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 25, finding 3. An attested call gated by an unattested one.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `setLiquiditySource` reaches its attested clause set only inside
    ///         `if (... && _fundsAsALenderPool(...))`. A forged `false` used to skip the branch, so
    ///         the attested call was never made and the pointer pair came apart.
    /// @dev MEASURED pre-fix with a real `LenderPool` and a one-word substitute: `liquiditySource` =
    ///      the pool, `lenderPool` = `address(0)`. That is the funder/sink split
    ///      `LossSinkMustBeTheFunder` exists to forbid, and the state round 21 measured as leaving a
    ///      314.375000 hole with `lifetimeSocialisedLoss` and `unsocialisedLoss` both zero and no way
    ///      back.
    ///
    ///      The general shape, which is the reason this is its own finding rather than a footnote to
    ///      the one above: **an attested call reached only through an unattested condition is not
    ///      attested.** Counting the attested members tells you nothing until you have asked what
    ///      decides whether each one runs.
    function test_R25_anUnattestedGateCannotSkipTheAttestedLenderPoolClauses() public {
        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.etch(wiring, RETURNS_TWO_ZERO_WORDS);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.setLiquiditySource(address(pool));

        assertEq(credit.liquiditySource(), address(liquidity), "the funder moved");
        assertEq(credit.lenderPool(), address(0), "premise: the sink was never set");
    }

    /// @notice **CONTROL.** The real library takes the branch and carries the sink with the funder.
    /// @dev Without this, the arm above passes just as well against a library that answers `false`
    ///      for everything - which is the state the finding is about, not a fix for it.
    function test_control_theRealLibraryCarriesTheSinkWithTheFunder() public {
        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.prank(admin);
        credit.setLiquiditySource(address(pool));

        assertEq(credit.liquiditySource(), address(pool), "the funder did not move");
        assertEq(credit.lenderPool(), address(pool), "the sink was left behind");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 25, finding 5. What `fundsAsALenderPool` does on a codeless address.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The docstring used to say this probe fails open on an address that cannot answer. On
    ///         an address with **no code** it does not: it reverts, with empty returndata, from
    ///         solc's `EXTCODESIZE` check ahead of the call and outside the `try`.
    /// @dev **The sentence was corrected and the code was deliberately left alone, which is the
    ///      opposite of what the finding prescribed.** The prescription was built and run before
    ///      being refused: with a `who.code.length` guard in place, `setLiquiditySource(EOA)`
    ///      **succeeds** and installs a bare EOA as the protocol's funder, after which `borrow`
    ///      reverts for everybody. So the contradiction the finding names is the only thing standing
    ///      between an operator typo and that state, and closing it would have removed a live
    ///      protection to tidy up a case that cannot be reached.
    ///
    ///      Unreachable by construction: `who` is always `liquiditySource` or the address about to
    ///      become it, and a codeless address cannot become `liquiditySource` because this very
    ///      probe reverts on it, while the branch that skips the probe requires
    ///      `lenderPool == liquiditySource_` and `lenderPool` cannot be codeless either -
    ///      `checkLenderPoolSwap`'s three completeness probes revert on it the same way.
    ///
    ///      This arm exists so the corrected sentence has something holding it in place. If somebody
    ///      later makes the probe fail open, this test is what tells them what they have done.
    function test_R26_aCodelessFunderRevertsRatherThanFailingOpen() public {
        address eoa = makeAddr("anEoa");
        assertEq(eoa.code.length, 0, "premise: no code at all");

        vm.prank(admin);
        vm.expectRevert();
        credit.setLiquiditySource(eoa);

        assertEq(credit.liquiditySource(), address(liquidity), "an EOA installed as the funder");
    }

    /// @notice And `address(0)` is still answered `false` rather than reverting, which is the
    ///         fresh-deployment state and has to stay legal.
    /// @dev The clause the arm above must not be "fixed" into swallowing. `setLenderPool` probes
    ///      `liquiditySource`, which is `address(0)` on a manager whose funder has not been set yet,
    ///      and a revert there would make the two setters mutually unsatisfiable in exactly the way
    ///      this repository has already shipped three times.
    function test_R26_theZeroAddressFunderIsAnsweredRatherThanReverted() public {
        CreditManager fresh = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        assertEq(fresh.liquiditySource(), address(0), "premise: no funder yet");

        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.prank(admin);
        fresh.setLenderPool(address(pool));

        assertEq(fresh.lenderPool(), address(pool), "a fresh manager could not be given a loss sink");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Controls.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **CONTROL, and the one that makes `_linkedWiring` trustworthy.** Restore the code the
    ///         fixture saved and both setters work again, so the address really is the library and
    ///         the attestation does not refuse the genuine one.
    /// @dev The failure mode of an attestation is refusing the thing it was written to accept, and
    ///      the failure mode of a bytecode scan is finding an address that changes nothing. This
    ///      arm rules out both at once: it etches the broken substitute, proves the setter refuses,
    ///      restores, and proves it stops refusing.
    function test_control_theRealLibraryStillInstallsBothPointers() public {
        LiquidationAuction auctionB = new LiquidationAuction(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.etch(wiring, RETURNS_A_ZERO_WORD);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        credit.setLiquidationAuction(address(auctionB));

        vm.etch(wiring, realWiringCode);

        vm.startPrank(admin);
        credit.setLiquidationAuction(address(auctionB));
        credit.setLenderPool(address(pool));
        vm.stopPrank();

        assertEq(credit.liquidationAuction(), address(auctionB), "the attestation refused the real library");
        assertEq(credit.lenderPool(), address(pool), "the attestation refused the real library");
    }

    /// @notice The three members that already returned a value are unchanged, and still fail closed
    ///         against a substituted library.
    /// @dev Not a new guarantee - solc has always emitted the returndata check for these - but the
    ///      fix moves the two void members into this same class, so it is worth having the class
    ///      itself pinned. `_sourceStillAnswersToUs` is reached from `flushPrincipalTo`;
    ///      `fundsAsALenderPool` from `setLiquiditySource`.
    ///
    ///      **AUDIT ROUND 25 FOUND THE ARGUMENT ABOVE TO BE THE ROUND'S ONE HIGH, and it is left
    ///      standing rather than rewritten because the error is the useful part.** "Still fail
    ///      closed" is true of this arm and false as a general claim, and the gap between the two is
    ///      the finding. A `STOP` returns *nothing*, so the decoder refuses it - that is all this
    ///      test ever showed. It says nothing whatever about a substitute that returns a
    ///      well-formed answer, which is what `ECHOES_AMOUNT` does and what the `test_R25_...` arms
    ///      above measure. Decodable was read as "the real body ran", which is the same
    ///      substitution round 24 caught one level up and did not carry through to its own
    ///      exemption list.
    function test_control_theValueReturningMembersAlsoFailClosed() public {
        vm.etch(wiring, STOP_BYTE);

        vm.prank(admin);
        vm.expectRevert();
        credit.setLiquiditySource(address(liquidity));
    }
}
