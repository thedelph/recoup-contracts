// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Hermetic `WirePhase4` with an in-memory environment and record, plus the two resolvers exposed.
contract R54A04EnvScript is WirePhase4 {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    mapping(bytes32 => string) private _str;
    mapping(bytes32 => bool) private _strSet;
    string private _record;

    function setEnvAddress(string memory key, address value) external {
        bytes32 k = keccak256(bytes(key));
        _addr[k] = value;
        _addrSet[k] = true;
    }

    function setEnvString(string memory key, string memory value) external {
        bytes32 k = keccak256(bytes(key));
        _str[k] = value;
        _strSet[k] = true;
    }

    function setRecord(string memory json) external {
        _record = json;
    }

    function _envOrAddress(string memory key, address fallbackValue) internal view override returns (address) {
        bytes32 k = keccak256(bytes(key));
        return _addrSet[k] ? _addr[k] : fallbackValue;
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        override
        returns (string memory)
    {
        bytes32 k = keccak256(bytes(key));
        return _strSet[k] ? _str[k] : fallbackValue;
    }

    /// @dev Round 56 (round-56 item 144): the salt seam, hermetic, so a `RECOUP_SWITCHOVER_ATTEMPT`
    ///      in this box's `contracts/.env` cannot decide a case here.
    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    function exposedResolveParamsAgainstRecord(address sender) external view returns (GovParams memory) {
        return _resolveParamsAgainstRecord(sender);
    }
}

/// @dev Answers `getMinDelay()` with SIXTY-FOUR bytes: the wrong width.
contract R54A04WideDelay {
    function getMinDelay() external pure {
        assembly {
            mstore(0, 1)
            mstore(32, 0)
            return(0, 64)
        }
    }
}

/// @dev Answers `getMinDelay()` with exactly one word and NOTHING else: a contract that passes the
///      round-53 probe by selector collision and is not a timelock.
contract R54A04OnlyDelay {
    function getMinDelay() external pure returns (uint256) {
        return 1;
    }
}

/// @notice The round-53 script fixes' first audit, EXECUTED: the checksummed-versus-lowercase case
///         question through forge's two address parsers (NEGATIVE, neither parser validates
///         EIP-55); a guardian row filled from the record AFTER `_validateParams` ran; a present-zero
///         operator row blamed on the chain by the report path; and `TimelockDoesNotAnswer`'s width
///         arm plus its one-selector residual.
/// @dev The three defects this file found were BUILT in the same wave, script-only and zero `src/`
///      bytes, and the tests that pinned them open are flipped to `fixed_`: `_resolveParamsAgainstRecord`
///      reads, holds to the record, THEN validates (with two `reorder_` tests holding the stated
///      consequence, a record-filled keeper on the broadcast path and `KeeperRequired` when neither
///      side names one); `_operatorAgainstRecord`'s fill arm names a present-zero row
///      `DeployedAddressMissing(name)`; and `_requiredTimelock` probes `hashOperationBatch` beside
///      `getMinDelay()`. Nothing here pins open any longer.
contract R54A04ScriptFirstAuditTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal treasury = makeAddr("r54a04.audit.treasury");
    address internal feeWallet = makeAddr("r54a04.audit.feeWallet");
    address internal keeper = makeAddr("r54a04.audit.keeper");
    address internal navConfirmer = makeAddr("r54a04.audit.navConfirmer");
    address internal guardian = makeAddr("r54a04.audit.guardian");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

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

    /// @dev Round 56 (round-56 item 144): the salt seam, hermetic, so a `RECOUP_SWITCHOVER_ATTEMPT`
    ///      in this box's `contracts/.env` cannot decide a case here.
    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(BASE_SEPOLIA);
        vm.warp(1_788_000_000);
    }

    // ── 1. CASE: checksummed record against a lowercase environment ──────────────────────────────

    function _lowerHex(address a) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 0; i < 20; ++i) {
            uint8 b = uint8(v >> (8 * (19 - i)));
            out[2 + i * 2] = alphabet[b >> 4];
            out[3 + i * 2] = alphabet[b & 0x0f];
        }
        return string(out);
    }

    /// @dev Flips the case of the first alphabetic hex digit, producing a string that is neither
    ///      lowercase nor a valid EIP-55 checksum.
    function _wrongChecksum(string memory checksummed) internal pure returns (string memory) {
        bytes memory b = bytes(checksummed);
        for (uint256 i = 2; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x61 && c <= 0x66) {
                b[i] = bytes1(c - 32);
                return string(b);
            }
            if (c >= 0x41 && c <= 0x46) {
                b[i] = bytes1(c + 32);
                return string(b);
            }
        }
        revert("no letter in address");
    }

    function exposedParseAddress(string memory s) external pure returns (address) {
        return vm.parseAddress(s);
    }

    function exposedParseJsonAddress(string memory json) external pure returns (address) {
        return vm.parseJsonAddress(json, ".a");
    }

    /// @notice A lowercase string and a checksummed record row parse to the SAME `address`, so
    ///         `_operatorAgainstRecord`'s `env != fromRecord` cannot see case at all.
    /// @dev **The environment half of this question is held in round 54's bundle, not here.** The
    ///      deploy auditor MEASURED `vm.envOr(key, address(0))` on the same strings through
    ///      `vm.setEnv`, and the ungated environment census (round-49 item 136) refuses `vm.setEnv`
    ///      and a direct `vm.envOr` in any test by design, so the string parser stands in:
    ///      `vm.parseAddress` is, INFERRED and not verified in forge's source this round, the same
    ///      string-to-address parse the environment cheatcodes run on a value they read. What is
    ///      MEASURED here is the string parser and the JSON parser against each other.
    function test_R54A04_case_lowercaseStringAndChecksummedRecordAgree() public {
        address a = keeper;
        string memory checksummed = vm.toString(a);
        string memory lower = _lowerHex(a);
        assertTrue(keccak256(bytes(checksummed)) != keccak256(bytes(lower)), "premise: toString is checksummed");

        assertEq(vm.parseAddress(lower), a, "parseAddress parses lowercase");
        assertEq(vm.parseAddress(checksummed), a, "parseAddress parses checksummed");
        assertEq(vm.parseJsonAddress(string.concat('{"a":"', checksummed, '"}'), ".a"), a, "json parses checksummed");
        assertEq(vm.parseJsonAddress(string.concat('{"a":"', lower, '"}'), ".a"), a, "json parses lowercase");
    }

    /// @notice A WRONG-checksum mixed-case string: whether either parser refuses it. MEASURED, both
    ///         directions recorded in the assertions below rather than assumed.
    function test_R54A04_case_aWrongChecksumIsParsedOrRefusedTheSameWayByBothParsers() public {
        address a = keeper;
        string memory bad = _wrongChecksum(vm.toString(a));

        (bool strOk, bytes memory strRet) = address(this).call(abi.encodeCall(this.exposedParseAddress, (bad)));
        (bool jsonOk, bytes memory jsonRet) =
            address(this).call(abi.encodeCall(this.exposedParseJsonAddress, (string.concat('{"a":"', bad, '"}'))));

        // MEASURED (forge 1.8.1): BOTH parsers ACCEPT a wrong-checksum mixed-case string and return
        // the same address; the environment cheatcode did the same in the bundle's trace. Neither
        // side validates EIP-55, so a record row and an environment value can never be refused on
        // one side and accepted on the other.
        assertTrue(strOk, "parseAddress accepts a wrong checksum");
        assertTrue(jsonOk, "parseJsonAddress accepts a wrong checksum");
        assertEq(abi.decode(strRet, (address)), a, "string: same address");
        assertEq(abi.decode(jsonRet, (address)), a, "json: same address");
    }

    // ── 2. The guardian row is filled from the record AFTER validation ───────────────────────────

    function _installOperators(R54A04EnvScript script, address owner_) internal {
        script.setEnvAddress("RECOUP_OWNER", owner_);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
    }

    function _recordWithGuardian(address owner_, address guardian_) internal pure returns (string memory) {
        return string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_),
            '","guardian":"', vm.toString(guardian_), '"}}'
        );
    }

    /// @notice CONTROL: the environment naming the OWNER as guardian is refused by `_validateParams`
    ///         as `GuardianMustDifferFromOwner`, on the broadcast-path resolver.
    function test_R54A04_183_control_anEnvGuardianEqualToTheOwnerIsRefused() public {
        address owner_ = makeAddr("r54a04.audit.owner");
        R54A04EnvScript script = new R54A04EnvScript();
        _installOperators(script, owner_);
        script.setEnvAddress("RECOUP_GUARDIAN", owner_);
        script.setRecord(_recordWithGuardian(owner_, owner_));

        vm.expectRevert(DeployBase.GuardianMustDifferFromOwner.selector);
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice FIXED in round 54 (was PINS OPEN, LOW, forward-looking). `_resolveParamsAgainstRecord`
    ///         used to VALIDATE first and fill from the record second, so an `operators.guardian` row
    ///         equal to the owner, with `RECOUP_GUARDIAN` unset, passed validation as zero and was
    ///         then filled to the owner - the one configuration `GuardianMustDifferFromOwner` exists
    ///         to refuse - with no error (MEASURED before the reorder: the fill returned the owner).
    ///         Now it reads, holds to the record, then validates, and the same record is refused by
    ///         name. No record carries a guardian row today; `_heldToRecord` lists it "so the row
    ///         binds the day it is added", and it now binds INSIDE the rule.
    function test_R54A04_183_fixed_aRecordGuardianEqualToTheOwnerIsRefusedAfterTheFill() public {
        address owner_ = makeAddr("r54a04.audit.owner");
        R54A04EnvScript script = new R54A04EnvScript();
        _installOperators(script, owner_);
        script.setRecord(_recordWithGuardian(owner_, owner_));

        vm.expectRevert(DeployBase.GuardianMustDifferFromOwner.selector);
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    function _recordWithKeeper(address owner_, address keeper_) internal pure returns (string memory) {
        return string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_),
            '","keeper":"', vm.toString(keeper_), '"}}'
        );
    }

    function _installOperatorsButTheKeeper(R54A04EnvScript script, address owner_) internal {
        script.setEnvAddress("RECOUP_OWNER", owner_);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
    }

    /// @notice The consequence of the reorder, stated and pinned rather than discovered: the fill
    ///         arm is now LIVE on the broadcast path. `RECOUP_KEEPER` unset and an `operators.keeper`
    ///         row present is FILLED from the record and then validated, where the old order refused
    ///         it as `KeeperRequired` before the record was opened. Round 54 ran every deploy harness
    ///         under both orders and no shipped test held the old behaviour; this one holds the new.
    function test_R54A04_183_reorder_anUnsetKeeperIsFilledFromTheRecordOnTheBroadcastPath() public {
        address owner_ = makeAddr("r54a04.audit.owner");
        R54A04EnvScript script = new R54A04EnvScript();
        _installOperatorsButTheKeeper(script, owner_);
        script.setRecord(_recordWithKeeper(owner_, keeper));

        GovParams memory p = script.exposedResolveParamsAgainstRecord(address(this));
        assertEq(p.keeper, keeper, "the record's keeper row fills an unset variable");
    }

    /// @notice And the rule the reorder must keep: with the keeper named on NEITHER side, the
    ///         broadcast path is still `KeeperRequired`, from `_validateParams` after the hold.
    function test_R54A04_183_reorder_aKeeperNamedNowhereIsStillKeeperRequired() public {
        address owner_ = makeAddr("r54a04.audit.owner");
        R54A04EnvScript script = new R54A04EnvScript();
        _installOperatorsButTheKeeper(script, owner_);
        script.setRecord(_recordWithGuardian(owner_, guardian));

        vm.expectRevert(DeployBase.KeeperRequired.selector);
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    // ── 3. `TimelockDoesNotAnswer`: the width arm, and the one-selector residual ─────────────────

    function _externals() internal view returns (Externals memory) {
        return Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
    }

    function _params(address owner_) internal view returns (GovParams memory) {
        return GovParams({
            owner: owner_,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: feeWallet,
            guardian: guardian
        });
    }

    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', vm.toString(value), last ? '"' : '",');
    }

    function _record(Deployed memory d, address owner_) internal pure returns (string memory) {
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_), '"},'
        );
        string memory first = string.concat(
            '"contracts":{',
            _row("NAVOracle", address(d.oracle), false),
            _row("CollateralVault", address(d.vault), false),
            _row("DirectCallAdapter", address(d.adapter), false),
            _row("CreditManager", address(d.credit), false)
        );
        string memory second = string.concat(
            _row("LenderPool", address(d.pool), false),
            _row("TreasuryLiquiditySource", address(d.liquidity), false),
            _row("EpochHarvester", address(d.harvester), false),
            _row("LiquidationAuction", address(d.auction), true),
            "}}"
        );
        return string.concat(head, first, second);
    }

    function _installGraph(R54A04EnvScript script, Deployed memory d, address owner_, address timelock_) internal {
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
        _installOperators(script, owner_);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setEnvAddress("RECOUP_TIMELOCK", timelock_);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        script.setRecord(_record(d, owner_));
    }

    /// @dev The graph record with an `operators.keeper` row that is PRESENT and ZERO.
    function _recordWithZeroKeeper(Deployed memory d, address owner_) internal pure returns (string memory) {
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_),
            '","keeper":"', vm.toString(address(0)), '"},'
        );
        string memory first = string.concat(
            '"contracts":{',
            _row("NAVOracle", address(d.oracle), false),
            _row("CollateralVault", address(d.vault), false),
            _row("DirectCallAdapter", address(d.adapter), false),
            _row("CreditManager", address(d.credit), false)
        );
        string memory second = string.concat(
            _row("LenderPool", address(d.pool), false),
            _row("TreasuryLiquiditySource", address(d.liquidity), false),
            _row("EpochHarvester", address(d.harvester), false),
            _row("LiquidationAuction", address(d.auction), true),
            "}}"
        );
        return string.concat(head, first, second);
    }

    /// @notice FIXED in round 54. Round-54 item 181 says a ZERO row is named on both paths; that was
    ///         `_resolveOne`'s `DeployedAddressMissing`, and `_operatorAgainstRecord` had no such arm:
    ///         on the REPORT path a present-zero `operators.keeper` row with `RECOUP_KEEPER` unset
    ///         filled ZERO silently and the report blamed the chain (MEASURED before the arm:
    ///         `WiringIncomplete`). The fill arm now names the row, with the environment variable
    ///         the operator would set, before any census runs.
    function test_R54A04_183_fixed_aPresentZeroKeeperRowOnTheReportPathIsNamed() public {
        address owner_ = makeAddr("r54a04.audit.owner");
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, owner_);
        R54A04EnvScript script = new R54A04EnvScript();
        _installGraph(script, d, owner_, owner_);
        script.setEnvAddress("RECOUP_KEEPER", address(0));
        script.setRecord(_recordWithZeroKeeper(d, owner_));

        vm.expectRevert(abi.encodeWithSelector(WirePhase4.DeployedAddressMissing.selector, "RECOUP_KEEPER"));
        script.assertOnly();
    }

    /// @notice The width arm bites: a timelock answering `getMinDelay()` with 64 bytes is
    ///         `TimelockDoesNotAnswer(t)`, named, before any owner check.
    function test_R54A04_timelock_aSixtyFourByteDelayAnswerIsNamed() public {
        R54A04WideDelay wide = new R54A04WideDelay();
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(wide));
        R54A04EnvScript script = new R54A04EnvScript();
        _installGraph(script, d, address(wide), address(wide));

        vm.expectRevert(abi.encodeWithSelector(WirePhase4.TimelockDoesNotAnswer.selector, address(wide)));
        script.queuePause();
    }

    /// @notice FIXED in round 54 (was PINS OPEN, INFO). The probe was ONE selector wide: a coded
    ///         owner that answers `getMinDelay()` with one word and nothing else passed it, passed
    ///         the owner check, and died EMPTY on `hashOperationBatch` (MEASURED before the second
    ///         probe: revert data `0x`). `_requiredTimelock` now asks `hashOperationBatch` of an
    ///         empty batch as well, so the same owner is `TimelockDoesNotAnswer(t)`, named, before
    ///         the owner check. Realistic only by selector collision; the width is a measured fact.
    function test_R54A04_timelock_fixed_anOwnerAnsweringOnlyGetMinDelayIsNamed() public {
        R54A04OnlyDelay only = new R54A04OnlyDelay();
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(only));
        R54A04EnvScript script = new R54A04EnvScript();
        _installGraph(script, d, address(only), address(only));

        vm.expectRevert(abi.encodeWithSelector(WirePhase4.TimelockDoesNotAnswer.selector, address(only)));
        script.queuePause();
    }
}
