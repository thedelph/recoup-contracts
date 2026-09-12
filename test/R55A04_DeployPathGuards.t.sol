// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {DeployReferralRegistry} from "../script/DeployReferral.s.sol";
import {Config} from "../src/Config.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Hermetic `WirePhase4`: in-memory environment and record, the resolvers and both delay
///      predicates exposed.
contract R55A04EnvScript is WirePhase4 {
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

    function exposedRequiredTimelock() external view returns (address) {
        return _requiredTimelock();
    }

    function exposedResolveDeployed() external view returns (Deployed memory) {
        return _resolveDeployed();
    }

    function exposedDelayExceedsCeiling(uint256 delay) external pure returns (bool) {
        return _delayExceedsCeiling(delay);
    }

    function exposedDelayLeavesNoWindow(uint256 delay) external pure returns (bool) {
        return _delayLeavesNoWindow(delay);
    }
}

/// @dev Hermetic `AssertLocked`: the record is a string, the environment is the fallback.
contract R55A04LockedProbe is AssertMockStackLocked {
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

    /// @dev Round 56 (round-56 item 144): the salt seam, hermetic, so a `RECOUP_SWITCHOVER_ATTEMPT`
    ///      in this box's `contracts/.env` cannot decide a case here.
    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }
}

/// @dev `DeployReferralRegistry` with the phrase read through the round-55 seam, so the phrase-SET
///      arm of `run()` is reachable with no writer (round-55 item 246, sublead j).
contract R55A04ReferralHarness is DeployReferralRegistry {
    string private _phrase;
    bool private _phraseSet;

    function setPhrase(string memory phrase) external {
        _phrase = phrase;
        _phraseSet = true;
    }

    function _envOrString(string memory, string memory fallbackValue)
        internal
        view
        override
        returns (string memory)
    {
        return _phraseSet ? _phrase : fallbackValue;
    }
}

/// @notice Round 55, audit agent A4: the deploy path's four script-only guards, EXECUTED.
///         (1) round-55 item 225(i), the EIP-55 door `DeployBase._parseCheckedAddress` in front of
///         every record row and every environment address, which refuses the wrong-checksum string
///         both forge parsers accept; (2) round-55 item 225(ii), the `minDelay` ceiling warning at
///         both `getMinDelay()` sites; (3) round-55 item 246(j), the referral phrase read through a
///         seam so the phrase-set arm of `run()` is pinned without `vm.setEnv`; (4) round-55 item
///         246 lead 4, the record that passes both node guards and fails the entrypoint.
///         Then the companions to #474's three leads that the shipped pins did not carry.
/// @dev `control_` cases are green on both sides of every fix; `fix_` cases are red at 9a01996
///      (they name a function or an error that does not exist there, so they fail to COMPILE at
///      that tree - the sign-check in the round-55 report is a semantic neuter of the shipped
///      file instead); `negative_` cases record what the guards deliberately accept.
contract R55A04DeployPathGuardsTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant BASE_MAINNET = 8453;
    string internal constant REFERRAL_PHRASE = "RECOUP_DEPLOY_REFERRAL";

    address internal treasury = makeAddr("r55a04.treasury");
    address internal feeWallet = makeAddr("r55a04.feeWallet");
    address internal keeper = makeAddr("r55a04.keeper");
    address internal navConfirmer = makeAddr("r55a04.navConfirmer");
    address internal guardian = makeAddr("r55a04.guardian");
    address internal lockKeeper = address(0xC0FFEE);

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
        // Forge's default timestamp is 1, OZ's DONE sentinel is 1: any zero-delay timelock test at
        // the default timestamp measures the sentinel (R53A02_DeployPathFacts says why).
        vm.warp(1_788_000_000);
    }

    // ── text helpers ─────────────────────────────────────────────────────────────────────────────

    function _hex(address a, bool upper) internal pure returns (string memory) {
        bytes memory alphabet = upper ? bytes("0123456789ABCDEF") : bytes("0123456789abcdef");
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

    /// @dev Flips the case of the first hex letter: neither single-case nor a valid checksum.
    ///      Returns the input unchanged when the address has no letter at all (a fuzz can draw one).
    function _wrongChecksum(string memory checksummed) internal pure returns (string memory) {
        // A COPY: `bytes(s)` on a memory string is a reference, and the first run of this file
        // mutated its own input in place (MEASURED: "the flip changed the text" compared a string
        // with itself).
        bytes memory src = bytes(checksummed);
        bytes memory b = new bytes(src.length);
        for (uint256 i = 0; i < src.length; ++i) {
            b[i] = src[i];
        }
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
        return checksummed;
    }

    function _hasLetter(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        for (uint256 i = 2; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if ((c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)) return true;
        }
        return false;
    }

    /// @dev External wrappers, so a revert from the pure door can be caught by `expectRevert`.
    function exposedParseChecked(string memory name, string memory raw) external pure returns (address) {
        return _parseCheckedAddress(name, raw);
    }

    function exposedAddressFromRaw(string memory name, string memory raw, address fb) external pure returns (address) {
        return _addressFromRaw(name, raw, fb);
    }

    // ── 1. round-55 item 225(i): the EIP-55 door ─────────────────────────────────────────────────

    /// @notice CONTROL: lowercase, uppercase and a correct checksum all pass the door to the same
    ///         address, so the committed record (lowercase contracts, checksummed operators) needs
    ///         no edit and the round-54 case fact - both sides agree - still holds under the fix.
    function test_R55A04_225i_control_singleCaseAndCorrectChecksumAllPassTheDoor() public view {
        address a = keeper;
        string memory checksummed = vm.toString(a);
        assertTrue(_hasLetter(checksummed), "premise: the fixture address has a letter to checksum");
        assertEq(this.exposedParseChecked("x", _hex(a, false)), a, "lowercase");
        assertEq(this.exposedParseChecked("x", _hex(a, true)), a, "uppercase");
        assertEq(this.exposedParseChecked("x", checksummed), a, "checksummed");
        assertTrue(_isEip55(_hex(a, false)) && _isEip55(_hex(a, true)) && _isEip55(checksummed));
    }

    /// @notice FIX: the wrong-checksum string that BOTH forge parsers accept (re-measured here, the
    ///         round-54 fact) is refused by name at the door. This is what the guard refuses that
    ///         the parser does not.
    function test_R55A04_225i_fix_aWrongChecksumIsRefusedByNameWhereBothParsersAccept() public {
        address a = keeper;
        string memory bad = _wrongChecksum(vm.toString(a));
        assertTrue(keccak256(bytes(bad)) != keccak256(bytes(vm.toString(a))), "premise: the case moved");
        assertEq(vm.parseAddress(bad), a, "the string parser still accepts it");
        assertEq(vm.parseJsonAddress(string.concat('{"a":"', bad, '"}'), ".a"), a, "the JSON parser still accepts it");
        assertFalse(_isEip55(bad), "the recompute sees it");

        vm.expectRevert(abi.encodeWithSelector(DeployBase.AddressChecksumInvalid.selector, "RECOUP_KEEPER", bad));
        this.exposedParseChecked("RECOUP_KEEPER", bad);
    }

    /// @notice FIX: a malformed string is named rather than parsed or silently defaulted, and the
    ///         empty string is still "unset" and takes the fallback, the way `vm.envOr` did.
    function test_R55A04_225i_fix_aMalformedValueIsNamedAndAnEmptyOneIsTheFallback() public {
        assertEq(this.exposedAddressFromRaw("RECOUP_KEEPER", "", keeper), keeper, "empty is unset");
        vm.expectRevert(abi.encodeWithSelector(DeployBase.AddressMalformed.selector, "RECOUP_KEEPER", "0xtypo"));
        this.exposedAddressFromRaw("RECOUP_KEEPER", "0xtypo", keeper);
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.AddressMalformed.selector, "RECOUP_KEEPER", "0XE61B6087Bc2dFD22ddB382832c1F8aeeFbef1e6a")
        );
        this.exposedAddressFromRaw("RECOUP_KEEPER", "0XE61B6087Bc2dFD22ddB382832c1F8aeeFbef1e6a", keeper);
    }

    function _isMixedCase(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bool upper;
        bool lower;
        for (uint256 i = 2; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x41 && c <= 0x46) upper = true;
            if (c >= 0x61 && c <= 0x66) lower = true;
        }
        return upper && lower;
    }

    /// @notice The recompute agrees with forge's own checksummed `toString` on every fuzzed address,
    ///         and disagrees with that string once one letter's case is flipped AND the result is
    ///         still mixed-case. This is what makes the Solidity EIP-55 implementation trustworthy:
    ///         forge is the second implementation.
    /// @dev MEASURED on the first two runs, counterexamples `0x...3d85` and `0x...14cF`: a flip that
    ///      leaves the string SINGLE-CASE (the one-letter address; or every other letter already
    ///      holding the case the flip produces) is accepted, because single-case encodes no checksum.
    ///      That is EIP-55's tolerant reading, which ethers, viem and this door share, and it is the
    ///      floor the negative below pins. Every flip that leaves the string mixed-case is caught.
    function testFuzz_R55A04_225i_theRecomputeAgreesWithForgeOnEveryAddress(address a) public pure {
        string memory checksummed = vm.toString(a);
        assertTrue(_isEip55(checksummed), "forge's toString is a valid checksum");
        assertEq(vm.parseAddress(checksummed), a);
        string memory flipped = _wrongChecksum(checksummed);
        vm.assume(_isMixedCase(flipped));
        assertFalse(_isEip55(flipped), "one flipped letter breaks it");
    }

    /// @notice NEGATIVE, the fuzz's own counterexamples pinned: an address whose flip leaves the
    ///         text single-case survives it, because single-case is "no checksum". `0x...3d85` has
    ///         one letter; `0x...14cF` has two whose checksum cases differ, so flipping the first
    ///         makes them agree. Neither can be checksum-protected, and the door does not pretend to.
    function test_R55A04_225i_negative_aFlipThatLeavesSingleCaseIsAcceptedTheTolerantFloor() public pure {
        address[2] memory floor = [address(0x3D85), address(0x14CF)];
        for (uint256 i = 0; i < 2; ++i) {
            string memory checksummed = vm.toString(floor[i]);
            string memory flipped = _wrongChecksum(checksummed);
            assertTrue(keccak256(bytes(flipped)) != keccak256(bytes(checksummed)), "premise: the flip changed the text");
            assertFalse(_isMixedCase(flipped), "premise: the flip left it single-case");
            assertTrue(_isEip55(flipped), "single-case after the flip, so accepted - the tolerant rule's floor");
            assertEq(vm.parseAddress(flipped), floor[i], "and it still parses to the same address");
        }
    }

    function _rowRaw(string memory name, string memory raw, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', raw, last ? '"' : '",');
    }

    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return _rowRaw(name, vm.toString(value), last);
    }

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

    function _installOperators(R55A04EnvScript script, address owner_) internal {
        script.setEnvAddress("RECOUP_OWNER", owner_);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
    }

    /// @dev The graph record with the NAVOracle row written as `oracleRaw` and the keeper row as
    ///      `keeperRaw`, so one builder serves the checksum tests and the lead companions.
    function _graphRecord(Deployed memory d, address owner_, string memory oracleRaw, string memory keeperRaw)
        internal
        pure
        returns (string memory)
    {
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_), '","keeper":"',
            keeperRaw, '"},'
        );
        string memory first = string.concat(
            '"contracts":{',
            _rowRaw("NAVOracle", oracleRaw, false),
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

    function _ceremony(address newOwner) internal returns (R55A04EnvScript script, Deployed memory d) {
        d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, newOwner);
        script = new R55A04EnvScript();
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
        _installOperators(script, newOwner);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setEnvAddress("RECOUP_TIMELOCK", newOwner);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        script.setRecord(_graphRecord(d, newOwner, vm.toString(address(d.oracle)), vm.toString(keeper)));
    }

    /// @notice FIX: an `operators.keeper` row with a wrong checksum is refused BY NAME on the
    ///         switchover path, before the row parses to an address the environment then agrees
    ///         with. At 9a01996 the same record resolved clean.
    function test_R55A04_225i_fix_aWrongChecksumOperatorRowIsRefusedOnTheSwitchoverPath() public {
        address owner_ = makeAddr("r55a04.owner");
        (R55A04EnvScript script, Deployed memory d) = _ceremony(owner_);
        string memory bad = _wrongChecksum(vm.toString(keeper));
        script.setRecord(_graphRecord(d, owner_, vm.toString(address(d.oracle)), bad));

        vm.expectRevert(abi.encodeWithSelector(DeployBase.AddressChecksumInvalid.selector, "RECOUP_KEEPER", bad));
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice FIX: a `contracts.NAVOracle` row with a wrong checksum is refused by name on the
    ///         report path, carrying the environment variable the operator would set.
    function test_R55A04_225i_fix_aWrongChecksumContractRowIsRefusedOnTheReportPath() public {
        address owner_ = makeAddr("r55a04.owner");
        (R55A04EnvScript script, Deployed memory d) = _ceremony(owner_);
        string memory bad = _wrongChecksum(vm.toString(address(d.oracle)));
        script.setRecord(_graphRecord(d, owner_, bad, vm.toString(keeper)));

        vm.expectRevert(abi.encodeWithSelector(DeployBase.AddressChecksumInvalid.selector, "RECOUP_NAV_ORACLE", bad));
        script.assertOnly();
    }

    /// @notice CONTROL: the same ceremony with a LOWERCASE oracle row and a checksummed environment
    ///         resolves clean, so the door refuses case that is WRONG and not case that DIFFERS.
    function test_R55A04_225i_control_aLowercaseRowAgainstAChecksummedEnvironmentStillAgrees() public {
        address owner_ = makeAddr("r55a04.owner");
        (R55A04EnvScript script, Deployed memory d) = _ceremony(owner_);
        script.setRecord(_graphRecord(d, owner_, _hex(address(d.oracle), false), _hex(keeper, false)));
        // Both resolvers, not `assertOnly()`: the health report also asserts Phase-4 wiring, which
        // this ceremony never ran (MEASURED on the first run, `WiringIncomplete("credit.liquiditySource")`).
        Deployed memory r = script.exposedResolveDeployed();
        assertEq(address(r.oracle), address(d.oracle), "the lowercase oracle row resolved to the deployed oracle");
        GovParams memory p = script.exposedResolveParamsAgainstRecord(address(this));
        assertEq(p.keeper, keeper, "the lowercase keeper row agreed with the checksummed environment");
    }

    // ── the locked-stack record, for the AssertLocked arm and for lead 4 ─────────────────────────

    function _lockedRecord(string memory bondRaw, address keeperRow, string memory lockStateBlock)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"deployer":"', vm.toString(address(this)),
            '","operators":{"keeper":"', vm.toString(keeperRow), '"},"mocks":{',
            _row("MockUSDC", address(usdc), false),
            _rowRaw("MockBond", bondRaw, false),
            _row("MockFarm", address(farm), true),
            '},"contracts":{',
            _row("CollateralVault", address(farm), false),
            _row("DirectCallAdapter", address(farm), true),
            '},"seededPosition":{"bonds":0}',
            lockStateBlock,
            "}"
        );
    }

    function _lockTheStack() internal {
        usdc.lockTo(address(this), lockKeeper);
        bond.lockTo(address(this), lockKeeper);
        farm.lockTo(address(this), lockKeeper);
        bond.setWhitelisted(address(farm), true);
    }

    /// @notice CONTROL: the locked stack against a correct record passes the whole entrypoint.
    function test_R55A04_lock_control_theLockedStackPassesTheEntrypoint() public {
        _lockTheStack();
        R55A04LockedProbe probe = new R55A04LockedProbe();
        probe.setRecord(_lockedRecord(vm.toString(address(bond)), lockKeeper, ""));
        probe.assertLockedOnChain();
    }

    /// @notice FIX: a `mocks.MockBond` row with a wrong checksum is refused by name before a single
    ///         chain read, where at 9a01996 it parsed to the right address and passed.
    function test_R55A04_225i_fix_aWrongChecksumMockRowIsRefusedBeforeAnyChainRead() public {
        _lockTheStack();
        R55A04LockedProbe probe = new R55A04LockedProbe();
        string memory bad = _wrongChecksum(vm.toString(address(bond)));
        probe.setRecord(_lockedRecord(bad, lockKeeper, ""));

        vm.expectRevert(abi.encodeWithSelector(DeployBase.AddressChecksumInvalid.selector, "MockBond", bad));
        probe.assertLockedOnChain();
    }

    /// @notice CONTROL: the committed record, row by row, passes the door - thirteen contract and
    ///         mock rows, five operator rows and the deployer. The one test in this file that reads
    ///         the disk (`fs_permissions` grants `deployments` read for `AssertLocked`), because the
    ///         claim "the live record needs no edit" is about the live record. A record that does
    ///         not publish the deployer and operator rows is checked over the rows it does carry.
    function test_R55A04_225i_control_theCommittedRecordPassesTheDoorRowByRow() public view {
        string memory j = vm.readFile("deployments/base-sepolia.json");
        string[19] memory paths = [
            ".deployer",
            ".operators.owner",
            ".operators.yieldRecipient",
            ".operators.keeper",
            ".operators.navConfirmer",
            ".operators.protocolFeeWallet",
            ".contracts.NAVOracle",
            ".contracts.RiskParams",
            ".contracts.CollateralVault",
            ".contracts.DirectCallAdapter",
            ".contracts.CreditManager",
            ".contracts.TreasuryLiquiditySource",
            ".contracts.LenderPool",
            ".contracts.EpochHarvester",
            ".contracts.LiquidationAuction",
            ".contracts.ReferralRegistry",
            ".mocks.MockUSDC",
            ".mocks.MockBond",
            ".mocks.MockFarm"
        ];
        uint256 mixedCase;
        uint256 present;
        for (uint256 i = 0; i < paths.length; ++i) {
            if (!vm.keyExistsJson(j, paths[i])) continue;
            present++;
            string memory raw = vm.parseJsonString(j, paths[i]);
            assertEq(_recordAddress(j, paths[i], paths[i]), vm.parseJsonAddress(j, paths[i]), paths[i]);
            if (keccak256(bytes(raw)) != keccak256(bytes(_hex(vm.parseAddress(raw), false)))) mixedCase++;
        }
        assertGe(present, 13, "the thirteen contract and mock rows are always in the record");
        // The operators block and the deployer are checksummed today and the contracts block is
        // lowercase, so the door actually CHECKED something on at least the six mixed-case rows
        // when the record carries them, and on at least one (the carried-over registry) when not.
        assertGe(
            mixedCase,
            present == paths.length ? 6 : 1,
            "at least one committed row carries a checksum the door recomputed"
        );
    }

    // ── 2. round-55 item 225(ii): the minDelay ceiling ───────────────────────────────────────────

    function _timelock(uint256 minDelay) internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(minDelay, proposers, executors, address(0));
    }

    /// @notice FIX: the ceiling predicate holds above `15 * ADMIN_TIMELOCK` (30 days) and is quiet
    ///         at the ceiling itself, at the protocol's own delay, and at zero (the other predicate's
    ///         case). `k = 15` because 15 x 48 h is Compound's `Timelock.MAXIMUM_DELAY`.
    function test_R55A04_225ii_fix_theCeilingIsThirtyDaysAndTheLastQuietSecondIsOnIt() public {
        R55A04EnvScript script = new R55A04EnvScript();
        uint256 ceiling = 15 * Config.ADMIN_TIMELOCK;
        assertEq(ceiling, 30 days, "the ceiling is 30 days");
        assertFalse(script.exposedDelayExceedsCeiling(0));
        assertFalse(script.exposedDelayExceedsCeiling(Config.ADMIN_TIMELOCK));
        assertFalse(script.exposedDelayExceedsCeiling(ceiling), "on the ceiling is quiet");
        assertTrue(script.exposedDelayExceedsCeiling(ceiling + 1), "one second over is warned");
        assertTrue(script.exposedDelayExceedsCeiling(100 * 365 days));
        // The two predicates are disjoint: nothing is both zero and over the ceiling.
        assertFalse(script.exposedDelayLeavesNoWindow(ceiling + 1));
    }

    /// @notice A WARNING and not a refusal, at BOTH sites: a delay one second over the ceiling is
    ///         still scheduled by `queuePause()`, and after it matures `queue()` schedules too.
    ///         The console block cannot be asserted (forge does not surface a console staticcall to
    ///         `expectCall`), so this holds the predicate and the non-refusal, the seam the file
    ///         already documents for the zero case.
    function test_R55A04_225ii_negative_overTheCeilingIsWarnedAtBothSitesAndRefusedAtNeither() public {
        uint256 delay = 15 * Config.ADMIN_TIMELOCK + 1;
        TimelockController timelock = _timelock(delay);
        (R55A04EnvScript script, Deployed memory d) = _ceremony(address(timelock));
        assertTrue(script.exposedDelayExceedsCeiling(delay));

        script.queuePause();
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _phase4PauseCalls(d);
        bytes32 pauseId = timelock.hashOperationBatch(t, v, p, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationPending(pauseId), "scheduled despite the warning");

        vm.warp(block.timestamp + delay);
        script.executeQueuedPause();
        script.queue();
        (t, v, p) = _phase4Calls(d);
        assertTrue(timelock.isOperationPending(timelock.hashOperationBatch(t, v, p, bytes32(0), bytes32(0))));
    }

    // ── 3. round-55 item 246(j): the referral phrase through a seam ──────────────────────────────

    /// @notice FIX: with the EXACT phrase in front of `run()`, both public chains are still
    ///         `LiveDeploymentDisabled`. This is the arm only a writer could reach before the seam,
    ///         and it is the arm that catches a `run()` letting the phrase BYPASS the live gate -
    ///         the shipped legacy pin asks the validator, not `run()`, and stays green under that
    ///         neuter.
    function test_R55A04_246j_fix_thePhraseSetArmOfRunIsStillLiveDeploymentDisabledOnBothPublicChains() public {
        R55A04ReferralHarness script = new R55A04ReferralHarness();
        script.setPhrase(REFERRAL_PHRASE);
        assertTrue(script.isConfirmed(REFERRAL_PHRASE), "premise: the harness holds the exact phrase");

        vm.chainId(BASE_MAINNET);
        vm.expectRevert(DeployReferralRegistry.LiveDeploymentDisabled.selector);
        script.run();

        vm.chainId(BASE_SEPOLIA);
        vm.expectRevert(DeployReferralRegistry.LiveDeploymentDisabled.selector);
        script.run();
    }

    /// @notice The unset arm through the same seam refuses by the GATE's name on 8453, not the
    ///         phrase's - a reorder of the two gates turns this `ConfirmationMissing`.
    function test_R55A04_246j_theUnsetArmOfRunRefusesByTheGatesNameOn8453() public {
        R55A04ReferralHarness script = new R55A04ReferralHarness();
        vm.chainId(BASE_MAINNET);
        vm.expectRevert(DeployReferralRegistry.LiveDeploymentDisabled.selector);
        script.run();
    }

    /// @notice CONTROL: anvil constructs with the phrase set and with it unset, so the seam did not
    ///         put a gate in front of the local rehearsal.
    function test_R55A04_246j_control_anvilConstructsWithAndWithoutThePhrase() public {
        vm.chainId(31337);
        R55A04ReferralHarness withPhrase = new R55A04ReferralHarness();
        withPhrase.setPhrase(REFERRAL_PHRASE);
        withPhrase.run();
        R55A04ReferralHarness without = new R55A04ReferralHarness();
        without.run();
    }

    /// @notice What the seam does NOT change, stated: `LIVE_DEPLOYMENT_ENABLED` is a constant, so
    ///         the "phrase-set arm broadcasts" half is unreachable by construction while it is
    ///         false; the validator with the exact phrase is the live gate's refusal, as shipped.
    function test_R55A04_246j_negative_theExactPhraseThroughTheValidatorIsStillTheLiveGate() public {
        R55A04ReferralHarness script = new R55A04ReferralHarness();
        vm.expectRevert(DeployReferralRegistry.LiveDeploymentDisabled.selector);
        script.validateBroadcastApproval(REFERRAL_PHRASE);
    }

    // ── 4. round-55 item 246 lead 4: the record both node guards pass and the entrypoint fails ───

    /// @notice The `lockState` row is COMPLETE and SELF-CONSISTENT (three mocks agree, admin equals
    ///         lockAuthority, status CLOSED, provenance present) and its `admin` is what the chain
    ///         reads, so the repository's lock-state guard at 9a01996 and the bytecode gate's `admin()`
    ///         arm both pass it - and `operators.keeper` names a different key from the row's
    ///         `operator`, so the entrypoint refuses `MockOperatorNotKeeper`. MEASURED here on the
    ///         forge side; the node side is the lock-state guard's own falsifier L13, red at 9a01996.
    function test_R55A04_lock_aSelfConsistentLockStateRowCanStillContradictOperatorsKeeper() public {
        _lockTheStack();
        address strangerKeeper = makeAddr("r55a04.strangerKeeper");
        string memory lockRow = string.concat(
            ',"lockState":{"status":"CLOSED","verifiedBy":"forge script","verifiedAtUtc":"2026-09-07T00:00:00Z",',
            '"verifiedAtTree":"9a01996","verifiedAtBlock":1,',
            '"MockUSDC":{"admin":"', vm.toString(address(this)), '","operator":"', vm.toString(lockKeeper),
            '","lockAuthority":"', vm.toString(address(this)), '"},',
            '"MockBond":{"admin":"', vm.toString(address(this)), '","operator":"', vm.toString(lockKeeper),
            '","lockAuthority":"', vm.toString(address(this)), '"},',
            '"MockFarm":{"admin":"', vm.toString(address(this)), '","operator":"', vm.toString(lockKeeper),
            '","lockAuthority":"', vm.toString(address(this)), '"}}'
        );
        R55A04LockedProbe probe = new R55A04LockedProbe();
        probe.setRecord(_lockedRecord(vm.toString(address(bond)), strangerKeeper, lockRow));

        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.MockOperatorNotKeeper.selector, "MockUSDC", lockKeeper, strangerKeeper
            )
        );
        probe.assertLockedOnChain();
    }

    // ── 5. companions to #474's three leads, which the shipped pins did not carry ────────────────

    function _recordWithOperators(address owner_, string memory extraRows) internal pure returns (string memory) {
        return string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_), '"', extraRows, "}}"
        );
    }

    function _installAllButKeeperAndConfirmer(R55A04EnvScript script, address owner_) internal {
        script.setEnvAddress("RECOUP_OWNER", owner_);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
    }

    /// @notice Lead (a), the two sibling rules the shipped guardian pin does not cover: a record
    ///         `navConfirmer` row EQUAL TO THE OWNER, with the variable unset, is refused after the
    ///         fill. Under the pre-#474 order (validate, then fill) it passed on zero and filled.
    function test_R55A04_224a_negative_aRecordConfirmerRowEqualToTheOwnerIsRefusedAfterTheFill() public {
        address owner_ = makeAddr("r55a04.owner");
        R55A04EnvScript script = new R55A04EnvScript();
        _installAllButKeeperAndConfirmer(script, owner_);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setRecord(_recordWithOperators(owner_, string.concat(',"navConfirmer":"', vm.toString(owner_), '"')));

        vm.expectRevert(DeployBase.NavConfirmerMustDifferFromOwner.selector);
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice Lead (a), the third sibling: keeper and confirmer rows that are ONE key, both unset
    ///         in the environment, are `NavKeysMustDiffer` after the fill.
    function test_R55A04_224a_negative_aRecordKeeperRowEqualToTheConfirmerRowIsRefusedAfterTheFill() public {
        address owner_ = makeAddr("r55a04.owner");
        R55A04EnvScript script = new R55A04EnvScript();
        _installAllButKeeperAndConfirmer(script, owner_);
        script.setRecord(
            _recordWithOperators(
                owner_, string.concat(',"keeper":"', vm.toString(keeper), '","navConfirmer":"', vm.toString(keeper), '"')
            )
        );

        vm.expectRevert(DeployBase.NavKeysMustDiffer.selector);
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice Lead (b), the owner row: a PRESENT and ZERO `operators.owner` with `RECOUP_OWNER`
    ///         unset is `DeployedAddressMissing("RECOUP_OWNER")` on the report path, not
    ///         `OwnerNotNamedForReport` - the shipped pin covered the keeper row only.
    function test_R55A04_224b_negative_aPresentZeroOwnerRowOnTheReportPathIsNamedAsTheRow() public {
        address owner_ = makeAddr("r55a04.owner");
        (R55A04EnvScript script, Deployed memory d) = _ceremony(owner_);
        script.setEnvAddress("RECOUP_OWNER", address(0));
        script.setRecord(_graphRecord(d, address(0), vm.toString(address(d.oracle)), vm.toString(keeper)));

        vm.expectRevert(abi.encodeWithSelector(WirePhase4.DeployedAddressMissing.selector, "RECOUP_OWNER"));
        script.assertOnly();
    }

    /// @notice Lead (c), the ORDER the shipped pins do not hold: an `operators.timelock` row that
    ///         disagrees with a codeless `RECOUP_TIMELOCK` is named as the DISAGREEMENT, and the
    ///         agreeing codeless value is named as codeless - identity before the two probes.
    function test_R55A04_224c_ordering_aTimelockRowDisagreementIsNamedBeforeTheCodeProbe() public {
        address owner_ = makeAddr("r55a04.owner");
        (R55A04EnvScript script, Deployed memory d) = _ceremony(owner_);
        address recordTimelock = makeAddr("r55a04.recordTimelock");
        address envTimelock = makeAddr("r55a04.envTimelock");
        string memory withTimelock = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_), '","timelock":"',
            vm.toString(recordTimelock), '"},"contracts":{', _row("NAVOracle", address(d.oracle), true), "}}"
        );
        script.setRecord(withTimelock);

        script.setEnvAddress("RECOUP_TIMELOCK", envTimelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector, "RECOUP_TIMELOCK", envTimelock, recordTimelock
            )
        );
        script.exposedRequiredTimelock();

        script.setEnvAddress("RECOUP_TIMELOCK", recordTimelock);
        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressHasNoCode.selector, "RECOUP_TIMELOCK", recordTimelock)
        );
        script.exposedRequiredTimelock();
    }
}
