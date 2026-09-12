// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Hermetic `AssertLocked`: the record is a string, the environment is the fallback.
contract R54A04LockedProbe is AssertMockStackLocked {
    string private _record;

    function setRecord(string memory json) external {
        _record = json;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue)
        internal
        pure
        override
        returns (string memory)
    {
        return fallbackValue;
    }
}

/// @dev Hermetic `WirePhase4`, exposing `_deploymentRecord` alone.
contract R54A04WireScript is WirePhase4 {
    string private _record;

    function setRecord(string memory json) external {
        _record = json;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue)
        internal
        pure
        override
        returns (string memory)
    {
        return fallbackValue;
    }

    function exposedDeploymentRecord() external view returns (string memory) {
        return _deploymentRecord();
    }
}

/// @notice Round-54 item 196: `.chainId` in `WirePhase4._deploymentRecord` and the NINE rows of
///         `AssertLocked._readStack` (the brief said eight; count them) are named
///         `DeployedRecordRowMissing(name, jsonPath)` when ABSENT, where they used to die inside
///         forge's JSON parser as an unnamed `CheatcodeError(string)` before a line printed.
///
/// @dev The error is referenced by its SIGNATURE rather than by `Contract.Error.selector`, so this
///      file compiles against the scripts before and after the fix and can be run on both sides of
///      the neuter: before, every `named_` test is red with `CheatcodeError(string)`; after, green.
///      The two round-53 `184_pinsOpen` tests in `R53A02_DeployPathFacts` are the mirror and go red.
///      Self-contained: repo mocks only, no repo fixture subclassed.
contract R54A04RecordRowsNamedTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84532;
    bytes4 internal constant CHEATCODE_ERROR = bytes4(keccak256("CheatcodeError(string)"));
    bytes4 internal constant ROW_MISSING = bytes4(keccak256("DeployedRecordRowMissing(string,string)"));
    uint256 internal constant ROWS = 9;

    address internal lockKeeper = address(0xC0FFEE);

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        usdc.lockTo(address(this), lockKeeper);
        bond.lockTo(address(this), lockKeeper);
        farm.lockTo(address(this), lockKeeper);
        bond.setRewardPool(address(farm));
        bond.setWhitelisted(address(farm), true);
        vm.chainId(BASE_SEPOLIA);
    }

    // ── record builder: the nine rows in `_readStack` order, any one of them omitted ─────────────

    function _rowName(uint256 i) internal pure returns (string memory) {
        string[ROWS] memory names = [
            "chainId",
            "deployer",
            "RECOUP_KEEPER",
            "MockUSDC",
            "MockBond",
            "MockFarm",
            "CollateralVault",
            "DirectCallAdapter",
            "seededPosition.bonds"
        ];
        return names[i];
    }

    function _rowPath(uint256 i) internal pure returns (string memory) {
        string[ROWS] memory paths = [
            ".chainId",
            ".deployer",
            ".operators.keeper",
            ".mocks.MockUSDC",
            ".mocks.MockBond",
            ".mocks.MockFarm",
            ".contracts.CollateralVault",
            ".contracts.DirectCallAdapter",
            ".seededPosition.bonds"
        ];
        return paths[i];
    }

    function _q(string memory k, string memory v) internal pure returns (string memory) {
        return string.concat('"', k, '":', v);
    }

    function _qa(string memory k, address v) internal pure returns (string memory) {
        return string.concat('"', k, '":"', vm.toString(v), '"');
    }

    /// @dev Joins the non-empty parts with commas.
    function _join(string[] memory parts) internal pure returns (string memory out) {
        bool first = true;
        for (uint256 i; i < parts.length; ++i) {
            if (bytes(parts[i]).length == 0) continue;
            out = first ? parts[i] : string.concat(out, ",", parts[i]);
            first = false;
        }
    }

    function _obj(string memory k, string[] memory parts) internal pure returns (string memory) {
        return string.concat('"', k, '":{', _join(parts), "}");
    }

    /// @dev The full locked-stack record with row `skip` omitted; `skip == ROWS` omits nothing.
    function _recordWithout(uint256 skip) internal view returns (string memory) {
        string[] memory mocks = new string[](3);
        mocks[0] = skip == 3 ? "" : _qa("MockUSDC", address(usdc));
        mocks[1] = skip == 4 ? "" : _qa("MockBond", address(bond));
        mocks[2] = skip == 5 ? "" : _qa("MockFarm", address(farm));
        string[] memory contracts_ = new string[](2);
        contracts_[0] = skip == 6 ? "" : _qa("CollateralVault", address(farm));
        contracts_[1] = skip == 7 ? "" : _qa("DirectCallAdapter", address(farm));
        string[] memory ops = new string[](1);
        ops[0] = skip == 2 ? "" : _qa("keeper", lockKeeper);
        string[] memory seeded = new string[](1);
        seeded[0] = skip == 8 ? "" : _q("bonds", "0");

        string[] memory top = new string[](6);
        top[0] = skip == 0 ? "" : _q("chainId", vm.toString(BASE_SEPOLIA));
        top[1] = skip == 1 ? "" : _qa("deployer", address(this));
        top[2] = _obj("operators", ops);
        top[3] = _obj("mocks", mocks);
        top[4] = _obj("contracts", contracts_);
        top[5] = _obj("seededPosition", seeded);
        return string.concat("{", _join(top), "}");
    }

    function _named(string memory name, string memory path) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ROW_MISSING, name, path);
    }

    // ── control ──────────────────────────────────────────────────────────────────────────────────

    /// @notice CONTROL: the complete record runs `assertLockedOnChain()` to its OK line, so every
    ///         red below is about the one row removed and nothing else.
    function test_R54A04_196_control_theCompleteRecordPassesTheWholeCheck() public {
        R54A04LockedProbe probe = new R54A04LockedProbe();
        probe.setRecord(_recordWithout(ROWS));
        probe.assertLockedOnChain();
    }

    // ── `AssertLocked._readStack`: nine rows ─────────────────────────────────────────────────────

    /// @notice Each of the nine rows, absent on its own, is named with its own field and path, in
    ///         `_readStack` order, before a single line is printed.
    function test_R54A04_196_everyOneOfTheNineLockedStackRowsIsNamedWhenAbsent() public {
        for (uint256 i; i < ROWS; ++i) {
            R54A04LockedProbe probe = new R54A04LockedProbe();
            probe.setRecord(_recordWithout(i));
            (bool ok, bytes memory reason) = address(probe).call(abi.encodeCall(probe.assertLockedOnChain, ()));
            assertFalse(ok, string.concat("premise: row ", _rowName(i), " absent reverts"));
            assertEq(reason, _named(_rowName(i), _rowPath(i)), string.concat("row ", _rowName(i), " is named"));
        }
    }

    /// @notice The round-53 pin's own case (no `seededPosition` at all) is named, not
    ///         `CheatcodeError(string)`.
    function test_R54A04_196_aLockedRecordWithNoSeededPositionIsNamed() public {
        R54A04LockedProbe probe = new R54A04LockedProbe();
        probe.setRecord(_recordWithout(8));
        (bool ok, bytes memory reason) = address(probe).call(abi.encodeCall(probe.assertLockedOnChain, ()));
        assertFalse(ok, "premise");
        assertTrue(bytes4(reason) != CHEATCODE_ERROR, "no longer dies inside the parser");
        assertEq(reason, _named("seededPosition.bonds", ".seededPosition.bonds"));
    }

    // ── `WirePhase4._deploymentRecord`: `.chainId` ───────────────────────────────────────────────

    /// @notice A record with no `chainId` row is `DeployedRecordRowMissing("chainId", ".chainId")`.
    function test_R54A04_196_aRecordWithNoChainIdRowIsNamed() public {
        R54A04WireScript script = new R54A04WireScript();
        script.setRecord('{"operators":{"owner":"0x0000000000000000000000000000000000000001"}}');
        (bool ok, bytes memory reason) = address(script).staticcall(abi.encodeCall(script.exposedDeploymentRecord, ()));
        assertFalse(ok, "premise");
        assertEq(reason, _named("chainId", ".chainId"));
    }

    /// @notice CONTROL: a present `chainId` that disagrees is still `RecordChainMismatch`, unchanged.
    function test_R54A04_196_control_aPresentWrongChainIdIsStillRecordChainMismatch() public {
        R54A04WireScript script = new R54A04WireScript();
        script.setRecord('{"chainId":8453}');
        vm.expectRevert(abi.encodeWithSelector(WirePhase4.RecordChainMismatch.selector, 8453, BASE_SEPOLIA));
        script.exposedDeploymentRecord();
    }

    // ── the stated residual: ABSENCE only ────────────────────────────────────────────────────────

    /// @notice PINS the residual round-54 item 181 states: a row that is PRESENT and malformed still
    ///         dies inside the parser. `keyExistsJson` answers presence, not shape.
    function test_R54A04_196_residual_aPresentMalformedChainIdStillDiesInTheParser() public {
        R54A04WireScript script = new R54A04WireScript();
        script.setRecord('{"chainId":"not a number"}');
        (bool ok, bytes memory reason) = address(script).staticcall(abi.encodeCall(script.exposedDeploymentRecord, ()));
        assertFalse(ok, "premise");
        assertEq(bytes4(reason), CHEATCODE_ERROR, "present-malformed is the parser's, by design");
    }
}
