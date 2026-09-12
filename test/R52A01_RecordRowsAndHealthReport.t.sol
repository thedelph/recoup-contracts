// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice `WirePhase4` with both environment seams and the record seam closed.
contract R52A01RecordScript is WirePhase4 {
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

    function unsetEnvAddress(string memory key) external {
        _addrSet[keccak256(bytes(key))] = false;
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

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    function exposedResolveDeployed() external view returns (Deployed memory) {
        return _resolveDeployed();
    }

    function exposedResolveParamsAgainstRecord(address sender) external view returns (GovParams memory) {
        return _resolveParamsAgainstRecord(sender);
    }
}

/// @notice `AssertMockStackLocked` with the record seam closed and both environment reads hermetic.
contract R52A01LockedProbe is AssertMockStackLocked {
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

/// @notice First audit of round 51's deploy-path changes (#454), the mirror rule applied to each.
///
/// @dev Three groups, every claim MEASURED. 🟥 **Group 2 PINS AN OPEN FINDING and says so: its
///      tests assert the defective behaviour, a fix must turn them red, and a green run of them is
///      not a clearance.** Group 3 is FIXED in round 52 and its test is the regression for the fix.
///      Group 1 is FIXED in round 53 (round-53 item 183): see the correction at the end of it.
///
///      1. **FIXED in round 53. The health report never read the record's operator rows.** Round 51 made
///         `_resolveParamsAgainstRecord` refuse an absent `operators.owner` by name, and round 50
///         made the record the side asserted against for the eight contracts. `assertOnly()` reads
///         its parameters with `_readParams`, which is environment-only, so on the ONE entry point
///         that exists for an operator who is not sure what is set, a wrong `RECOUP_OWNER`, a stale
///         `RECOUP_KEEPER` or an unset `RECOUP_GUARDIAN` is reported as a WIRING failure of the
///         chain - `OwnershipNotTransferred`, `WiringIncomplete("oracle.keeper")`,
///         `WiringIncomplete("vault.guardian")` - while the committed record holds the right answer
///         for four of the five and is not consulted. Round 38 fixed exactly this shape for ONE
///         value (`OwnerNotNamedForReport`, the unset owner) and this is the same shape for a WRONG
///         one and for the four sibling rows.
///
///         A fix (a `_readParamsAgainstRecord` for `assertOnly()` taking each present `operators.*`
///         row from the record) was proposed here and NOT built; this header then said "the three
///         `health_a...` tests must flip". 🟥 **That was wrong about two of them, and round 53
///         measured it when it BUILT the fix.** This fixture's record carries ONLY `operators.owner`
///         (`_healthyRecord`), so the stale-keeper pin has no keeper row to be held to and the
///         unset-guardian pin is the residual the fix states (the record cannot fill a row it
///         lacks). Under the shipped fix EXACTLY ONE test flipped, the owner one, now
///         `test_R52A01_health_aWrongEnvOwnerIsRefusedAgainstTheRecord`; the other two stay green
///         and pin a record shape the committed record does not have. The falsifier over the
///         committed shape (five operator rows, no guardian) is `R53A02_HealthReportRecordRows.t.sol`,
///         17 tests, 6 / 11 at `a9ae1f4` and 17 / 0 under the fix.
///
///      2. **OPEN. The record's missing-row refusal is about ABSENCE only.** A row that is present and
///         malformed - the empty string, `null`, a non-address string - still dies inside forge's
///         JSON parser rather than at a named error, on `contracts.*` and on `operators.owner`
///         alike. The zero-address row IS named (`DeployedAddressMissing` on a contract,
///         `DeployedEnvDisagreesWithRecord` on the owner). Same class as the `operators.owner`
///         absence round 51 closed; the presence case was not asked.
///
///      3. **FIXED. The code check round 51 added to `AssertLocked` has a mirror in `WirePhase4` and
///         it was one row wide.** `_assertCoreGraph` opens with `_ownablesOf`, which names a codeless
///         member `DeployedMemberNotOwnable(i)`, so seven of the eight record rows fail by name when
///         they name nothing. The eighth, `contracts.CollateralVault`, is dereferenced FIRST in
///         `_resolveDeployed` (`d.vault.riskParams()`) and died with an empty revert; it is now
///         refused `DeployedAddressHasNoCode("RECOUP_COLLATERAL_VAULT", target)` on the dereference.
///         A codeless address with nonce history is still refused by
///         `_assertRecordedContractsHaveCode`: `EXTCODESIZE` does not read the nonce.
contract R52A01RecordRowsAndHealthReportTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal treasury = makeAddr("r52a01.r.treasury");
    address internal feeWallet = makeAddr("r52a01.r.feeWallet");
    address internal keeper = makeAddr("r52a01.r.keeper");
    address internal navConfirmer = makeAddr("r52a01.r.navConfirmer");
    address internal guardian = makeAddr("r52a01.r.guardian");
    address internal stranger = makeAddr("r52a01.r.stranger");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    R52A01RecordScript internal script;

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

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(BASE_SEPOLIA);
        script = new R52A01RecordScript();
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

    function _switchedOver() internal returns (Deployed memory d) {
        d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _wirePhase4(d);
        _assertPhase4Wiring(d, _params(address(this)));
    }

    /// @dev A row whose VALUE is supplied raw, so the same builder can write an address, `""`, `null`
    ///      or an arbitrary string.
    function _rawRow(string memory name, string memory rawValue, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":', rawValue, last ? "" : ",");
    }

    function _q(address a) internal pure returns (string memory) {
        return string.concat('"', vm.toString(a), '"');
    }

    /// @param ownerRaw the raw JSON value for `operators.owner`.
    /// @param oracleRaw the raw JSON value for `contracts.NAVOracle`.
    /// @param vaultRaw the raw JSON value for `contracts.CollateralVault`.
    /// @param creditRaw the raw JSON value for `contracts.CreditManager`.
    function _recordWith(
        Deployed memory d,
        string memory ownerRaw,
        string memory oracleRaw,
        string memory vaultRaw,
        string memory creditRaw
    ) internal pure returns (string memory) {
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{', _rawRow("owner", ownerRaw, true), "},"
        );
        string memory first = string.concat(
            '"contracts":{',
            _rawRow("NAVOracle", oracleRaw, false),
            _rawRow("CollateralVault", vaultRaw, false),
            _rawRow("DirectCallAdapter", _q(address(d.adapter)), false),
            _rawRow("CreditManager", creditRaw, false)
        );
        string memory second = string.concat(
            _rawRow("LenderPool", _q(address(d.pool)), false),
            _rawRow("TreasuryLiquiditySource", _q(address(d.liquidity)), false),
            _rawRow("EpochHarvester", _q(address(d.harvester)), false),
            _rawRow("LiquidationAuction", _q(address(d.auction)), true),
            "}}"
        );
        return string.concat(head, first, second);
    }

    function _healthyRecord(Deployed memory d, address owner_) internal pure returns (string memory) {
        return _recordWith(d, _q(owner_), _q(address(d.oracle)), _q(address(d.vault)), _q(address(d.credit)));
    }

    function _installEnv(Deployed memory d, address owner_) internal {
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
        script.setEnvAddress("RECOUP_OWNER", owner_);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        script.setRecord(_healthyRecord(d, owner_));
    }

    // ── 1. the health report blames the chain for an environment gap the record could fill ──────

    /// @notice Control first: a correct environment over a healthy graph passes the health report.
    function test_R52A01_health_control_aCorrectEnvironmentPasses() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.assertOnly();
    }

    /// @notice FLIPPED by round 53 (round-53 item 183). A WRONG `RECOUP_OWNER` - the record names
    ///         the right one - used to be reported as the chain having failed its handover
    ///         (`OwnershipNotTransferred`), because `_readParams` never opened the record. The health
    ///         report now reads `_readParamsAgainstRecord`, which holds every operator row the record
    ///         carries, so the same environment is refused by name with both values before any
    ///         wiring is read. Same disposition as the other three entry points, one test down.
    function test_R52A01_health_aWrongEnvOwnerIsRefusedAgainstTheRecord() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_OWNER", stranger);

        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector, "RECOUP_OWNER", stranger, address(this)
            )
        );
        script.assertOnly();
    }

    /// @notice And the same gap on the OTHER three entry points is refused by name against the
    ///         record, which is the disposition the report should share.
    function test_R52A01_health_theOtherEntryPointsNameTheDisagreement() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_OWNER", stranger);

        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector, "RECOUP_OWNER", stranger, address(this)
            )
        );
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice A STALE `RECOUP_KEEPER` is reported as the oracle being mis-wired. The record's
    ///         `operators.keeper` row exists on the committed record and is read by nothing here.
    function test_R52A01_health_aStaleEnvKeeperIsReportedAsAWiringFailure() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_KEEPER", stranger);

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "oracle.keeper"));
        script.assertOnly();
    }

    /// @notice An UNSET `RECOUP_GUARDIAN` over a graph that has one is reported as the vault being
    ///         mis-wired. The guardian has no record row at all, so this one the record cannot fill.
    function test_R52A01_health_anUnsetGuardianIsReportedAsAWiringFailure() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.unsetEnvAddress("RECOUP_GUARDIAN");
        assertEq(d.vault.guardian(), guardian, "premise: the chain names a guardian");

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "vault.guardian"));
        script.assertOnly();
    }

    // ── 2. a PRESENT but malformed record row still dies inside the parser ───────────────────────

    function _isNamedRecordError(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 sel = bytes4(reason);
        return sel == DeployBase.DeployedRecordRowMissing.selector || sel == WirePhase4.DeployedAddressMissing.selector
            || sel == WirePhase4.DeployedEnvDisagreesWithRecord.selector
            || sel == WirePhase4.DeploymentRecordMissing.selector || sel == WirePhase4.RecordChainMismatch.selector;
    }

    /// @dev Runs `_resolveDeployed` and returns the revert data, failing the test if it did not revert.
    function _resolveDeployedReason() internal view returns (bytes memory reason) {
        try script.exposedResolveDeployed() returns (Deployed memory) {
            revert("premise: expected a revert");
        } catch (bytes memory r) {
            return r;
        }
    }

    function _resolveOwnerReason() internal view returns (bytes memory reason) {
        try script.exposedResolveParamsAgainstRecord(address(this)) returns (GovParams memory) {
            revert("premise: expected a revert");
        } catch (bytes memory r) {
            return r;
        }
    }

    /// @notice `contracts.NAVOracle: ""` - present, so `DeployedRecordRowMissing` does not fire; not an
    ///         address, so the named path is never reached.
    function test_R52A01_record_anEmptyStringContractRowIsNotNamed() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setRecord(_recordWith(d, _q(address(this)), '""', _q(address(d.vault)), _q(address(d.credit))));

        bytes memory reason = _resolveDeployedReason();
        emit log_named_bytes("revert data for an empty-string row", reason);
        assertFalse(_isNamedRecordError(reason), "an empty-string row dies inside the parser, not at a named error");
    }

    /// @notice `contracts.NAVOracle: null` - the same.
    function test_R52A01_record_aNullContractRowIsNotNamed() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setRecord(_recordWith(d, _q(address(this)), "null", _q(address(d.vault)), _q(address(d.credit))));

        bytes memory reason = _resolveDeployedReason();
        emit log_named_bytes("revert data for a null row", reason);
        assertFalse(_isNamedRecordError(reason), "a null row dies inside the parser, not at a named error");
    }

    /// @notice `contracts.NAVOracle: "0xabc"` - a truncated paste, the realistic typo.
    function test_R52A01_record_aTruncatedAddressRowIsNotNamed() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setRecord(_recordWith(d, _q(address(this)), '"0xabc"', _q(address(d.vault)), _q(address(d.credit))));

        bytes memory reason = _resolveDeployedReason();
        emit log_named_bytes("revert data for a truncated row", reason);
        assertFalse(_isNamedRecordError(reason), "a truncated row dies inside the parser, not at a named error");
    }

    /// @notice Negative, recorded: the ZERO address in a contract row IS named.
    function test_R52A01_record_negative_aZeroContractRowIsNamed() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.unsetEnvAddress("RECOUP_NAV_ORACLE");
        script.setRecord(_recordWith(d, _q(address(this)), _q(address(0)), _q(address(d.vault)), _q(address(d.credit))));

        vm.expectRevert(abi.encodeWithSelector(WirePhase4.DeployedAddressMissing.selector, "RECOUP_NAV_ORACLE"));
        script.exposedResolveDeployed();
    }

    /// @notice `operators.owner: ""` - round 51 named the ABSENT row; the present-but-empty row is
    ///         still the parser's death, one function over from the fix.
    function test_R52A01_record_anEmptyStringOwnerRowIsNotNamed() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setRecord(_recordWith(d, '""', _q(address(d.oracle)), _q(address(d.vault)), _q(address(d.credit))));

        bytes memory reason = _resolveOwnerReason();
        emit log_named_bytes("revert data for an empty-string owner row", reason);
        assertFalse(_isNamedRecordError(reason), "an empty-string owner row dies inside the parser");
    }

    /// @notice Negative, recorded: a ZERO owner row is named as a disagreement carrying both values.
    function test_R52A01_record_negative_aZeroOwnerRowIsNamed() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setRecord(_recordWith(d, _q(address(0)), _q(address(d.oracle)), _q(address(d.vault)), _q(address(d.credit))));

        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector, "RECOUP_OWNER", address(this), address(0)
            )
        );
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    // ── 3. the code-check mirror on the switchover path ──────────────────────────────────────────

    /// @notice FIXED in round 52. A codeless `contracts.CollateralVault` row used to kill
    ///         `assertOnly()` with an EMPTY revert, because `_resolveDeployed` dereferences the vault
    ///         (`riskParams()`) before any census runs; it is now refused by name with the row's
    ///         `RECOUP_*` name and the address it held.
    /// @dev The neuter is the `code.length` check in `_resolveDeployed` removed: this assertion
    ///      then fails `Error != expected error: <empty> != DeployedAddressHasNoCode(...)`, and no
    ///      other assertion in this file moves, which is why the check sits on the vault's
    ///      dereference rather than in `_resolveOne` - a check on all eight rows would also flip
    ///      the credit-row negative below from `DeployedMemberNotOwnable` to this error.
    function test_R52A01_codeless_theVaultRowIsNamed() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        address nothing = makeAddr("r52a01.codeless.vault");
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", nothing);
        script.setRecord(_recordWith(d, _q(address(this)), _q(address(d.oracle)), _q(nothing), _q(address(d.credit))));

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressHasNoCode.selector, "RECOUP_COLLATERAL_VAULT", nothing)
        );
        script.assertOnly();
    }

    /// @notice Negative, recorded: a codeless row for any OTHER member is named by `_ownablesOf`
    ///         before anything dereferences it (`DeployedMemberNotOwnable(index)`).
    function test_R52A01_codeless_negative_theCreditRowIsNamedByIndex() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        address nothing = makeAddr("r52a01.codeless.credit");
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", nothing);
        script.setRecord(_recordWith(d, _q(address(this)), _q(address(d.oracle)), _q(address(d.vault)), _q(nothing)));

        vm.expectPartialRevert(DeployBase.DeployedMemberNotOwnable.selector);
        script.assertOnly();
    }

    /// @notice The locked-stack code check refuses a codeless address WITH nonce history: `EXTCODESIZE`
    ///         reads code, not the nonce, so "has sent transactions" does not pass it.
    function test_R52A01_locked_aCodelessAddressWithNonceHistoryIsStillRefused() public {
        R52A01LockedProbe probe = new R52A01LockedProbe();
        MockUSDC u = new MockUSDC();
        MockBond b = new MockBond();
        MockFarm f = new MockFarm(b, u);
        address lockKeeper = address(0xC0FFEE);
        u.lockTo(address(this), lockKeeper);
        b.lockTo(address(this), lockKeeper);
        f.lockTo(address(this), lockKeeper);
        b.setRewardPool(address(f));
        b.setWhitelisted(address(f), true);

        address busyEoa = makeAddr("r52a01.busy.eoa");
        vm.setNonce(busyEoa, 41);
        assertEq(busyEoa.code.length, 0, "premise: nonce history and no code");
        b.setWhitelisted(busyEoa, true);

        probe.setRecord(
            string.concat(
                '{"chainId":', vm.toString(BASE_SEPOLIA), ',"deployer":"', vm.toString(address(this)), '",',
                '"operators":{"keeper":"', vm.toString(lockKeeper), '"},',
                '"mocks":{"MockUSDC":"', vm.toString(address(u)), '","MockBond":"', vm.toString(address(b)),
                '","MockFarm":"', vm.toString(address(f)), '"},',
                '"contracts":{"CollateralVault":"', vm.toString(busyEoa), '","DirectCallAdapter":"',
                vm.toString(busyEoa), '"},"seededPosition":{"bonds":0}}'
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.NoCodeAt.selector, "contracts.CollateralVault", busyEoa)
        );
        probe.assertLockedOnChain();
    }
}
