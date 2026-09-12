// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";

/// @dev Answers `vault()` and nothing else: the shipped `SetterGuards` stub's shape.
contract R54A04VaultOnlyFB {
    address public immutable vault;

    constructor(address v) {
        vault = v;
    }
}

/// @dev Answers nothing at all (no fallback: every call reverts EMPTY).
contract R54A04NothingFB {}

/// @dev Answers `vault()` with a 32-byte word whose high 96 bits are set, and `stakedBalance()`
///      normally: the round-53 "wrong contract answering a colliding selector" shape.
contract R54A04DirtyVaultFB {
    uint256 private immutable _word;

    constructor(address v) {
        _word = uint256(uint160(v)) | (uint256(1) << 200);
    }

    function vault() external view returns (bytes32) {
        return bytes32(_word);
    }

    function stakedBalance() external pure returns (uint256) {
        return 0;
    }
}

/// @dev Answers `vault()` correctly and REVERTS from `stakedBalance()` with exactly 32 bytes of
///      returndata. This is the one shape `_probe`'s `!ok` arm catches and its length arm does
///      not, and it exists so that arm is load-bearing rather than decorative: every other stub
///      in this file reverts EMPTY, which the length check alone would already refuse.
contract R54A04ThirtyTwoByteRevertFB {
    address public immutable vault;

    constructor(address v) {
        vault = v;
    }

    function stakedBalance() external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0x00, 1)
            revert(0x00, 0x20)
        }
    }
}

/// @dev Answers both views correctly: the control.
contract R54A04CompleteFB {
    address public immutable vault;

    constructor(address v) {
        vault = v;
    }

    function stakedBalance() external pure returns (uint256) {
        return 0;
    }
}

/// @title R54A04 - `CollateralVault.setCustodyAdapter` names the selector that did not answer
/// @notice Round-54 item 223, FIXED in round 55 as form B. Both completeness probes used to be bare
///         high-level calls that died with EMPTY returndata on a stub missing either member, and the
///         shipped `SetterGuards` test could only pin that with the one bare `vm.expectRevert()` in
///         the file - which, because that stub answers `vault()`, was really pinning the SECOND
///         probe. Both now go through one `_probe(adapter, sel)` `staticcall` raising
///         `AdapterDoesNotAnswer(selector)`, with the `vault()` word range-checked the round-53
///         `AssertLocked._asAddress` way before it is narrowed.
///
/// @dev 🟩 **PROMOTED from round 54's bundle `fix-regressions/` directory, where these three
///      `_named_` cases were RED at `f16e6e6` by design.** The in-tree round-54 shape had three
///      `pinsOpen_` cases asserting the EMPTY revert; they are replaced here rather than corrected,
///      because a pin and its flip are the same assertion written from the two sides, and keeping
///      both would leave a red file in `contracts/test/` - the replay trap round 52 recorded.
///
///      Form A - naming only the `stakedBalance()` probe, leaving `vault()` bare - was costed at
///      `CollateralVault` runtime +135 against form B's +156 and REJECTED: twenty-one bytes is not
///      the reason to leave the first probe, the one an address answering nothing at all hits,
///      unable to say what happened. Re-derive both figures from the size gate.
///
///      Self-contained: a fresh vault whose oracle and risk-params pointers are never read on this
///      path (the outgoing-adapter read is skipped while `custodyAdapter` is zero).
contract R54A04VaultProbeNamedTest is Test {
    bytes4 internal constant DOES_NOT_ANSWER = bytes4(keccak256("AdapterDoesNotAnswer(bytes4)"));

    CollateralVault internal vault;

    function setUp() public {
        MockBond bond = new MockBond();
        vault = new CollateralVault(
            IDexFiBond(address(bond)),
            INAVOracle(makeAddr("r54a04.oracle")),
            IRiskParams(makeAddr("r54a04.riskParams")),
            address(this)
        );
    }

    function _install(address stub) internal returns (bool ok, bytes memory reason) {
        (ok, reason) = address(vault).call(abi.encodeCall(vault.setCustodyAdapter, (ICustodyAdapter(stub))));
    }

    function _named(bytes4 sel) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(DOES_NOT_ANSWER, sel);
    }

    /// @notice CONTROL: an adapter answering both views installs.
    function test_R54A04_198_control_aCompleteAdapterInstalls() public {
        address stub = address(new R54A04CompleteFB(address(vault)));
        (bool ok,) = _install(stub);
        assertTrue(ok, "installs");
        assertEq(address(vault.custodyAdapter()), stub);
    }

    /// @notice The shipped `SetterGuards` stub shape - answers `vault()`, not `stakedBalance()` - is
    ///         refused by NAME on the second probe. EMPTY before the fix.
    function test_R54A04_198_named_anAdapterMissingStakedBalanceIsNamedBySelector() public {
        (bool ok, bytes memory reason) = _install(address(new R54A04VaultOnlyFB(address(vault))));
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICustodyAdapter.stakedBalance.selector), "named, not empty");
    }

    /// @notice An adapter answering nothing is refused on the FIRST probe, `vault()`, which was also
    ///         a bare high-level call: the shipped `SetterGuards` stub never reaches it.
    function test_R54A04_198_named_anAdapterAnsweringNothingIsNamedOnVault() public {
        (bool ok, bytes memory reason) = _install(address(new R54A04NothingFB()));
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICustodyAdapter.vault.selector), "named, not empty");
    }

    /// @notice The round-53 shape, mirrored onto the vault: a 32-byte `vault()` answer with dirty
    ///         high bits used to die EMPTY inside `abi.decode`. The range check names it.
    function test_R54A04_198_named_aDirtyVaultWordIsNamedOnVault() public {
        (bool ok, bytes memory reason) = _install(address(new R54A04DirtyVaultFB(address(vault))));
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICustodyAdapter.vault.selector), "named, not empty");
    }

    /// @notice Round 55, and the reason `_probe` tests `!ok` as well as the returndata length. A
    ///         revert carrying exactly 32 bytes passes the length check, so without the success
    ///         flag it would decode as an answer. Every other stub here reverts EMPTY, which the
    ///         length arm alone already refuses - so this case is the only thing making the `!ok`
    ///         arm load-bearing, and a neuter that drops it goes red here and nowhere else.
    function test_R54A04_198_named_aThirtyTwoByteRevertIsNamedNotDecoded() public {
        (bool ok, bytes memory reason) = _install(address(new R54A04ThirtyTwoByteRevertFB(address(vault))));
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICustodyAdapter.stakedBalance.selector), "named by the success flag");
    }

    /// @notice Round 55, and the reason `_probe` does NOT copy the `code.length == 0` clause that
    ///         `AssertLocked._readAddress` carries. A `staticcall` to a codeless account SUCCEEDS
    ///         with empty returndata, so the length check already names it, with the same error and
    ///         the same selector a code check would have produced. The clause would be runtime bytes
    ///         no caller could tell apart. This test is what holds that claim, so a future reader
    ///         adding the clause "for symmetry" can see what it would buy: nothing.
    function test_R54A04_198_named_aCodelessAddressIsNamedOnVault() public {
        address codeless = makeAddr("r54a04.codeless");
        assertEq(codeless.code.length, 0, "premise: no code");
        (bool ok, bytes memory reason) = _install(codeless);
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICustodyAdapter.vault.selector), "named by the length check, not by a code check");
    }
}
