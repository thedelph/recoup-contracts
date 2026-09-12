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

/// @notice `WirePhase4` with both environment seams and the record seam closed. Built here rather
///         than borrowed so this file is self-contained for the replay tool.
contract R53A02RecordScript is WirePhase4 {
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

    function exposedResolveParamsAgainstRecord(address sender) external view returns (GovParams memory) {
        return _resolveParamsAgainstRecord(sender);
    }
}

/// @notice Round-53 item 183, the falsifier for its fix: the health report opens the record's
///         operator rows, fills an unset variable from them, and refuses a disagreeing one BY NAME
///         with both values, instead of reporting the chain as mis-wired.
///
/// @dev Every claim MEASURED. The fixture's record carries the FIVE operator rows the committed
///      `deployments/base-sepolia.json` carries (`owner`, `yieldRecipient`, `keeper`,
///      `navConfirmer`, `protocolFeeWallet`) and NO guardian row, which is also the committed
///      shape. That matters: `R52A01_RecordRowsAndHealthReport.t.sol`'s record carries only
///      `operators.owner`, so of its three `health_a...` pins only the owner one can flip under any
///      fix that reads the record - the keeper pin's record has no keeper row to read.
///
///      Before the fix (`WirePhase4.assertOnly()` reading `_readParams`, environment only), the
///      tests marked BEFORE below were red with the error each names (6 passed / 11 failed at
///      `a9ae1f4`); after it they are green. Round 53's contracts wave shipped the fix and promoted
///      this file as its regression suite.
contract R53A02HealthReportRecordRowsTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal treasury = makeAddr("r53a02.treasury");
    address internal feeWallet = makeAddr("r53a02.feeWallet");
    address internal keeper = makeAddr("r53a02.keeper");
    address internal navConfirmer = makeAddr("r53a02.navConfirmer");
    address internal guardian = makeAddr("r53a02.guardian");
    address internal stranger = makeAddr("r53a02.stranger");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    R53A02RecordScript internal script;

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
        script = new R53A02RecordScript();
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

    /// @dev A deployment made by this contract, switched over, still owned by this contract. The
    ///      guardian is named because `_validateNewDeployment` refuses a contract owner without one
    ///      off the local chain.
    function _switchedOver() internal returns (Deployed memory d) {
        d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _wirePhase4(d);
        _assertPhase4Wiring(d, _params(address(this)));
    }

    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', vm.toString(value), last ? '"' : '",');
    }

    /// @param withOwnerRow whether `operators.owner` is written at all (round 51 refuses its absence
    ///        on the broadcast paths; the report tolerates it).
    /// @param guardianRow zero writes NO guardian row, the committed shape; non-zero writes one.
    function _record(Deployed memory d, address owner_, bool withOwnerRow, address guardianRow)
        internal
        view
        returns (string memory)
    {
        // `yieldRecipient` is the interim sink and is repointed to the harvester by `_wire`, so the
        // record row is whatever the operator named; the fixture names `_recordTreasury()` in both
        // the record and the environment, as the committed record names the treasury's address.
        string memory ops = string.concat(
            '{"chainId":',
            vm.toString(BASE_SEPOLIA),
            ',"operators":{',
            withOwnerRow ? _row("owner", owner_, false) : "",
            '"yieldRecipient":"',
            vm.toString(_recordTreasury()),
            '",'
        );
        ops = string.concat(
            ops,
            '"keeper":"',
            vm.toString(d.oracle.keeper()),
            '","navConfirmer":"',
            vm.toString(d.oracle.navConfirmer()),
            '","protocolFeeWallet":"',
            vm.toString(d.harvester.protocolFeeWallet()),
            '"',
            guardianRow == address(0) ? "" : string.concat(',"guardian":"', vm.toString(guardianRow), '"'),
            "},"
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
        return string.concat(ops, first, second);
    }

    /// @dev The yield-recipient row the record carries. `_wire` repoints the adapter's sink to the
    ///      harvester, so the row is a statement about what the operator NAMED rather than about
    ///      the chain, and the fixture names this address in both the record and the environment.
    function _recordTreasury() internal pure returns (address) {
        return address(uint160(uint256(keccak256("r53a02.treasury.row"))));
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
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", _recordTreasury());
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        script.setRecord(_record(d, owner_, true, address(0)));
    }

    function _disagrees(string memory name, address env, address rec) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(WirePhase4.DeployedEnvDisagreesWithRecord.selector, name, env, rec);
    }

    // ── the health report, item 183's four paths ─────────────────────────────────────────────────

    /// @notice Control: a correct environment over a healthy graph and an agreeing record passes.
    function test_R53A02_183_control_aCorrectEnvironmentAndAnAgreeingRecordPass() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.assertOnly();
    }

    /// @notice BEFORE: `OwnershipNotTransferred(<each contract>, this)` - the chain blamed for a
    ///         handover that succeeded. AFTER: the environment is refused by name with both values.
    function test_R53A02_183_aWrongEnvOwnerIsRefusedAgainstTheRecordByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_OWNER", stranger);

        vm.expectRevert(_disagrees("RECOUP_OWNER", stranger, address(this)));
        script.assertOnly();
    }

    /// @notice BEFORE: `WiringIncomplete("oracle.keeper")` - an oracle that agrees with the committed
    ///         record reported as mis-wired. AFTER: the stale variable is named.
    function test_R53A02_183_aStaleEnvKeeperIsRefusedAgainstTheRecordByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_KEEPER", stranger);

        vm.expectRevert(_disagrees("RECOUP_KEEPER", stranger, keeper));
        script.assertOnly();
    }

    /// @notice BEFORE: `WiringIncomplete("oracle.keeper")`. AFTER: the record fills the unset row and
    ///         the report passes. This is the case the report exists for - an operator who is not
    ///         sure what is set.
    function test_R53A02_183_anUnsetKeeperIsFilledFromTheRecord() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.unsetEnvAddress("RECOUP_KEEPER");
        script.assertOnly();
    }

    /// @notice BEFORE: `OwnerNotNamedForReport()`, round 38's refusal. AFTER: the record's
    ///         `operators.owner` fills it and the report runs.
    function test_R53A02_183_anUnsetOwnerIsFilledFromTheRecord() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.unsetEnvAddress("RECOUP_OWNER");
        script.assertOnly();
    }

    /// @notice The re-filed lead: a WRONG `RECOUP_NAV_CONFIRMER`. BEFORE:
    ///         `WiringIncomplete("oracle.navConfirmer")`. AFTER: named against the record.
    function test_R53A02_lead_aWrongEnvConfirmerIsRefusedAgainstTheRecordByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", stranger);

        vm.expectRevert(_disagrees("RECOUP_NAV_CONFIRMER", stranger, navConfirmer));
        script.assertOnly();
    }

    /// @notice The row the census never compared. BEFORE: a wrong `RECOUP_YIELD_RECIPIENT` PASSED the
    ///         report silently, because `_assertCoreGraph` reads `p.yieldRecipient` nowhere (the
    ///         adapter's sink is held to the harvester, not to `p`). AFTER: refused by name, so the
    ///         one operator row nothing on chain could check is at least held to the record.
    function test_R53A02_183_aWrongEnvYieldRecipientWasSilentAndIsNowRefusedByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", stranger);

        vm.expectRevert(_disagrees("RECOUP_YIELD_RECIPIENT", stranger, _recordTreasury()));
        script.assertOnly();
    }

    /// @notice BEFORE: `WiringIncomplete("harvester.protocolFeeWallet")`. AFTER: named.
    function test_R53A02_183_aWrongEnvFeeWalletIsRefusedAgainstTheRecordByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", stranger);

        vm.expectRevert(_disagrees("RECOUP_PROTOCOL_FEE_WALLET", stranger, feeWallet));
        script.assertOnly();
    }

    /// @notice PINS THE RESIDUAL, green before and after: the record carries no guardian row, so an
    ///         unset `RECOUP_GUARDIAN` still falls through to the environment and the chain's
    ///         guardian is reported as `WiringIncomplete("vault.guardian")`. The record cannot fill
    ///         a row it does not have; the remedy is the row, and the test below shows it binds.
    function test_R53A02_183_residual_anUnsetGuardianOverARecordWithNoGuardianRowStillBlamesTheChain() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.unsetEnvAddress("RECOUP_GUARDIAN");
        assertEq(d.vault.guardian(), guardian, "premise: the chain names a guardian");

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "vault.guardian"));
        script.assertOnly();
    }

    /// @notice BEFORE: `WiringIncomplete("vault.guardian")`. AFTER: a guardian row, the day the record
    ///         grows one, fills the unset variable - binding by existing, the `_requiredTimelock` way.
    function test_R53A02_183_aGuardianRowInTheRecordFillsAnUnsetGuardian() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.unsetEnvAddress("RECOUP_GUARDIAN");
        script.setRecord(_record(d, address(this), true, guardian));
        script.assertOnly();
    }

    /// @notice A row present in the record and DISAGREEING with the environment is refused even for
    ///         the guardian, whose zero is otherwise a legal value: a set, non-zero, wrong variable
    ///         is the case round 38 named.
    function test_R53A02_183_aGuardianRowThatDisagreesWithTheEnvironmentIsRefusedByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setRecord(_record(d, address(this), true, stranger));

        vm.expectRevert(_disagrees("RECOUP_GUARDIAN", guardian, stranger));
        script.assertOnly();
    }

    /// @notice Round 38's refusal is still reachable, and nothing else in the tree pins it: a record
    ///         with NO owner row and an unset `RECOUP_OWNER` is `OwnerNotNamedForReport()`, green
    ///         before and after. (Locally the owner defaults to the caller, so the error is
    ///         reachable only off the local chain.)
    function test_R53A02_183_control_noOwnerRowAndNoEnvOwnerIsStillOwnerNotNamedForReport() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.unsetEnvAddress("RECOUP_OWNER");
        script.setRecord(_record(d, address(this), false, address(0)));

        vm.expectRevert(WirePhase4.OwnerNotNamedForReport.selector);
        script.assertOnly();
    }

    // ── the three broadcast entry points, the same five rows ────────────────────────────────────

    /// @notice BEFORE: `_resolveParamsAgainstRecord` compared `operators.owner` only, so a stale
    ///         `RECOUP_KEEPER` resolved cleanly and was refused later by `_assertCoreGraph` as
    ///         `WiringIncomplete("oracle.keeper")` - inside `queue()`, after `_resolveDeployed`, and
    ///         blaming the chain. AFTER: named at resolution, before anything is scheduled.
    function test_R53A02_183_theBroadcastPathsRefuseAStaleKeeperByNameAtResolution() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_KEEPER", stranger);

        vm.expectRevert(_disagrees("RECOUP_KEEPER", stranger, keeper));
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice The re-filed lead on the broadcast paths: a wrong confirmer used to resolve cleanly.
    function test_R53A02_lead_theBroadcastPathsRefuseAWrongConfirmerByNameAtResolution() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", stranger);

        vm.expectRevert(_disagrees("RECOUP_NAV_CONFIRMER", stranger, navConfirmer));
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice Control, unchanged: round 51's absent-owner-row refusal on the broadcast paths stands.
    function test_R53A02_183_control_theBroadcastPathsStillRefuseAnAbsentOwnerRow() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.setRecord(_record(d, address(this), false, address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.DeployedRecordRowMissing.selector, "RECOUP_OWNER", ".operators.owner")
        );
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice Control, unchanged: an agreeing environment resolves on the broadcast paths.
    function test_R53A02_183_control_anAgreeingEnvironmentResolvesOnTheBroadcastPaths() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        GovParams memory p = script.exposedResolveParamsAgainstRecord(address(this));
        assertEq(p.keeper, keeper, "keeper");
        assertEq(p.navConfirmer, navConfirmer, "navConfirmer");
        assertEq(p.protocolFeeWallet, feeWallet, "protocolFeeWallet");
        assertEq(p.owner, address(this), "owner");
    }

    /// @notice Local chain, unchanged: there is no record, so the environment is the only source and
    ///         a disagreeing "record" cannot exist. The report runs on the environment alone.
    function test_R53A02_183_control_onTheLocalChainTheEnvironmentIsTheOnlySource() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        vm.chainId(ANVIL_CHAIN_ID);
        script.setRecord("");
        script.assertOnly();
    }
}
