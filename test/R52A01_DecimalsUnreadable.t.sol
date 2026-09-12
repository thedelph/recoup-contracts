// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {DeployMainnet} from "../script/Deploy.s.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice `WirePhase4` with both environment seams and the record seam closed, the construction
///         `R51A01_HealthReport.t.sol` uses. Hermetic on the environment and on the record.
contract R52A01Script is WirePhase4 {
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

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    /// @dev `_assertCoreGraph` is internal; `vm.expectRevert` needs a call boundary.
    function exposedAssertCoreGraph(Deployed memory d, GovParams memory p) external view {
        _assertCoreGraph(d, p);
    }
}

/// @notice `DeployBase` with `_deployProtocol` behind a call boundary, so the DEPLOY site of the
///         decimals read can be driven under `vm.expectRevert`.
contract R52A01Deployer is DeployBase {
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

    function exposedDeployProtocol(Externals memory e, GovParams memory p, address deployer)
        external
        returns (Deployed memory)
    {
        return _deployProtocol(e, p, deployer);
    }
}

/// @notice `DeployMainnet` with both seams closed. The ONE `Deploy.s.sol` target whose settlement
///         token is an EXTERNAL address (`Config.USDC_BASE`) rather than a mock the script creates,
///         so it is the one target where an unreadable `decimals()` is reachable by an operator.
contract R52A01Mainnet is DeployMainnet {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    mapping(bytes32 => string) private _str;
    mapping(bytes32 => bool) private _strSet;

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
}

/// @notice The sign-check for the fix's SHAPE: a `try`/`catch` around `decimals()` catches a revert
///         and does NOT catch a token that answers with no data, so the try form is not the fix.
contract R52A01TryCatchProbe {
    error Caught(bytes reason);

    function viaTryCatch(address token) external view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch (bytes memory reason) {
            revert Caught(reason);
        }
    }
}

/// @notice Round-52 item 167. Both `IERC20Metadata(...).decimals()` reads in `DeployBase` - the
///         deploy site in `_deployProtocol` and the census site in `_assertCoreGraph` - were bare
///         high-level calls. A token whose `decimals()` reverts, or answers with no data, or is a
///         codeless address, killed the script with an EMPTY revert instead of a named refusal, on
///         every one of the five entry points that reach them. FIXED in round 52: both sites now go
///         through `DeployBase._settlementDecimals`, a low-level `staticcall` that refuses every one
///         of the three shapes with `UsdcDecimalsUnreadable(token)`. This file is the regression
///         suite for that fix.
///
/// @dev Every claim in this file is MEASURED. With the two call sites reverted to the bare
///      `IERC20Metadata(...).decimals()` (the neuter, run with `forge test --force`), every
///      `expectRevert` below that names `UsdcDecimalsUnreadable` fails with
///      `Error != expected error: <empty> != <selector>`; the trace shows `[Revert] EvmError: Revert`
///      with no data under the `decimals()` frame. The round-51 pin of the same defect,
///      `R51A01RecordGapsTest.test_R51A01_mirror_aTokenThatWillNotAnswerDecimalsTakesTheWholeCensusDown`,
///      now asserts the named error too; its bare `vm.expectRevert()` would have stayed green through
///      the fix and through its removal alike.
///
///      **Why a named sibling and not `UsdcDecimalsWrong(token, 0)`.** Zero is an answer a real
///      token can give - zero-decimal tokens exist - so `Wrong(token, 0)` would report a measurement
///      the token never made. The two remedies also differ: `Wrong` says this is a token of the
///      wrong scale, `Unreadable` says this address is not a token at all (a typo, a proxy with no
///      implementation, a fork or RPC pointed at the wrong chain). The shipped tests assert `Wrong`
///      carries the measured value, and that property is kept.
///
///      **Why a low-level `staticcall` rather than `try`/`catch`.** `test_R52A01_167_signCheck_...`
///      below executes the alternative: Solidity's `try` catches the external call's revert and does
///      NOT catch a return-data decoding failure, so a token answering with no data still dies with
///      an empty revert under `try`. The `staticcall` form reads `ok` and `ret.length` itself.
contract R52A01DecimalsUnreadableTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;
    bytes internal constant DECIMALS = abi.encodeWithSignature("decimals()");

    address internal treasury = makeAddr("r52a01.treasury");
    address internal feeWallet = makeAddr("r52a01.feeWallet");
    address internal keeper = makeAddr("r52a01.keeper");
    address internal navConfirmer = makeAddr("r52a01.navConfirmer");
    address internal guardian = makeAddr("r52a01.guardian");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    R52A01Script internal script;
    R52A01Deployer internal deployer;

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
        script = new R52A01Script();
        deployer = new R52A01Deployer();
    }

    function _externals(address token) internal view returns (Externals memory) {
        return Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(token)});
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

    function _unreadable(address token) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(DeployBase.UsdcDecimalsUnreadable.selector, token);
    }

    // ── the DEPLOY site: `_deployProtocol`, reached by every `Deploy.s.sol` target ──────────────

    /// @notice A settlement token whose `decimals()` REVERTS is refused by name before the first `new`.
    function test_R52A01_167_deploySite_aRevertingDecimalsIsRefusedByName() public {
        vm.mockCallRevert(address(usdc), DECIMALS, "");
        vm.expectRevert(_unreadable(address(usdc)));
        deployer.exposedDeployProtocol(_externals(address(usdc)), _params(address(this)), address(this));
        vm.clearMockedCalls();
    }

    /// @notice A token that answers `decimals()` with NO DATA is refused by name too. This is the
    ///         case `try`/`catch` cannot reach.
    function test_R52A01_167_deploySite_aNoDataDecimalsIsRefusedByName() public {
        vm.mockCall(address(usdc), DECIMALS, "");
        vm.expectRevert(_unreadable(address(usdc)));
        deployer.exposedDeployProtocol(_externals(address(usdc)), _params(address(this)), address(this));
        vm.clearMockedCalls();
    }

    /// @notice A CODELESS settlement address - the typo case - is refused by name, not by `EvmError`.
    function test_R52A01_167_deploySite_aCodelessTokenIsRefusedByName() public {
        address nothing = makeAddr("r52a01.codeless");
        assertEq(nothing.code.length, 0, "premise: no code");
        vm.expectRevert(_unreadable(nothing));
        deployer.exposedDeployProtocol(_externals(nothing), _params(address(this)), address(this));
    }

    /// @notice A 32-byte answer above `type(uint8).max` is not a `uint8` and is refused as unreadable
    ///         rather than truncated into a wrong `actual`.
    function test_R52A01_167_deploySite_anOverwideAnswerIsUnreadableNotTruncated() public {
        vm.mockCall(address(usdc), DECIMALS, abi.encode(uint256(262)));
        vm.expectRevert(_unreadable(address(usdc)));
        deployer.exposedDeployProtocol(_externals(address(usdc)), _params(address(this)), address(this));
        vm.clearMockedCalls();
    }

    /// @notice Control: the shipped `UsdcDecimalsWrong` still carries the measured value.
    function test_R52A01_167_deploySite_control_aWrongScaleStillReportsTheMeasuredValue() public {
        vm.mockCall(address(usdc), DECIMALS, abi.encode(uint8(18)));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.UsdcDecimalsWrong.selector, address(usdc), uint8(18)));
        deployer.exposedDeployProtocol(_externals(address(usdc)), _params(address(this)), address(this));
        vm.clearMockedCalls();
    }

    /// @notice The `Deploy` entry point an operator can actually reach this from: `DeployMainnet.run()`
    ///         on a chain where `Config.USDC_BASE` holds no code (a fork or RPC on the wrong chain).
    /// @dev `DeployLocal` and `DeployTestnet` create their own `MockUSDC`, whose `decimals()` is
    ///      `pure` and six, so the guard has no reachable party on those two targets. This one reads
    ///      `Config.USDC_BASE` off whatever chain it is pointed at. Chain id 8453 satisfies the target's
    ///      own gate; the bare test EVM is the wrong chain, so the token is codeless - the premise is
    ///      asserted rather than assumed. BEFORE the fix this died empty inside `vm.startBroadcast`.
    function test_R52A01_167_deployEntryPoint_DeployMainnetOnTheWrongChainRefusesByName() public {
        vm.chainId(8453);
        R52A01Mainnet mainnet = new R52A01Mainnet();
        mainnet.setEnvString("RECOUP_MAINNET_CONFIRM", "RECOUP_DEPLOY_BASE_MAINNET");
        mainnet.setEnvString("RECOUP_CUSTODY_MODE", "direct");
        mainnet.setEnvAddress("RECOUP_OWNER", makeAddr("r52a01.mainnet.owner"));
        mainnet.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        mainnet.setEnvAddress("RECOUP_KEEPER", keeper);
        mainnet.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        mainnet.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        assertEq(Config.USDC_BASE.code.length, 0, "premise: this EVM is not Base, so the token is codeless");

        vm.expectRevert(_unreadable(Config.USDC_BASE));
        mainnet.run();
    }

    /// @notice Incidental, MEASURED while building the test above: `vm.mockCallRevert` on an address
    ///         that holds no code ETCHES code there, so a mock installed on a contract's FUTURE
    ///         `CREATE` address makes that `CREATE` collide and revert empty. A before-measurement
    ///         written that way passed for the wrong reason.
    function test_R52A01_167_incidental_aMockOnACodelessAddressEtchesCode() public {
        address future = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertEq(future.code.length, 0, "premise: nothing there yet");
        vm.mockCallRevert(future, DECIMALS, "");
        assertGt(future.code.length, 0, "the mock etched code onto the address");
        vm.clearMockedCalls();
    }

    // ── the CENSUS site: `_assertCoreGraph`, reached by all four `WirePhase4` entry points ──────

    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', vm.toString(value), last ? '"' : '",');
    }

    function _recordFor(Deployed memory d, address recordOwner) internal pure returns (string memory) {
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(recordOwner), '"},'
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
        script.setRecord(_recordFor(d, owner_));
    }

    function _timelock(address proposer) internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    /// @dev A deployment made by this contract and still owned by it, switched over in memory.
    function _switchedOver() internal returns (Deployed memory d) {
        d = _deployProtocol(_externals(address(usdc)), _params(address(this)), address(this));
        _wirePhase4(d);
        _assertPhase4Wiring(d, _params(address(this)));
    }

    /// @notice `assertOnly()` - the health report - names the unreadable token instead of dying.
    function test_R52A01_167_assertOnly_refusesARevertingDecimalsByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));
        script.assertOnly(); // control: the untouched graph passes

        vm.mockCallRevert(address(usdc), DECIMALS, "");
        vm.expectRevert(_unreadable(address(usdc)));
        script.assertOnly();
        vm.clearMockedCalls();
    }

    /// @notice And the no-data answer, on the same entry point.
    function test_R52A01_167_assertOnly_refusesANoDataDecimalsByName() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this));

        vm.mockCall(address(usdc), DECIMALS, "");
        vm.expectRevert(_unreadable(address(usdc)));
        script.assertOnly();
        vm.clearMockedCalls();
    }

    /// @notice `queue()` - the timelock entry point - refuses before it schedules anything.
    function test_R52A01_167_queue_refusesARevertingDecimalsByName() public {
        TimelockController timelock = _timelock(address(this));
        Deployed memory d = _deployProtocol(_externals(address(usdc)), _params(address(timelock)), address(this));
        _installEnv(d, address(timelock));
        script.setEnvAddress("RECOUP_TIMELOCK", address(timelock));

        vm.mockCallRevert(address(usdc), DECIMALS, "");
        vm.expectRevert(_unreadable(address(usdc)));
        script.queue();
        vm.clearMockedCalls();
    }

    /// @notice `executeQueued()` - the post-maturity entry point - refuses by name too.
    function test_R52A01_167_executeQueued_refusesARevertingDecimalsByName() public {
        TimelockController timelock = _timelock(address(this));
        Deployed memory d = _deployProtocol(_externals(address(usdc)), _params(address(timelock)), address(this));
        _installEnv(d, address(timelock));
        script.setEnvAddress("RECOUP_TIMELOCK", address(timelock));

        // Round 51 measured the ceremony end to end; here the pause half is skipped and the
        // switchover batch is scheduled directly, because the subject is the census inside
        // `_executeQueued`, and `queue()` refuses a live window before it schedules.
        vm.prank(address(timelock));
        d.credit.pause();
        vm.prank(address(timelock));
        d.vault.pause();
        script.queue();
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK + 1);

        vm.mockCallRevert(address(usdc), DECIMALS, "");
        vm.expectRevert(_unreadable(address(usdc)));
        script.executeQueued();
        vm.clearMockedCalls();
    }

    /// @notice `run()` - the EOA-owner entry point - reaches the census after its legs and refuses
    ///         by name.
    /// @dev Under `forge test` a `vm.startBroadcast()` with no argument sends from `DEFAULT_SENDER`,
    ///      so the graph is owned by that address and the legs are accepted.
    function test_R52A01_167_run_refusesARevertingDecimalsByName() public {
        Deployed memory d = _deployProtocol(_externals(address(usdc)), _params(DEFAULT_SENDER), address(this));
        _installEnv(d, DEFAULT_SENDER);

        vm.mockCallRevert(address(usdc), DECIMALS, "");
        vm.expectRevert(_unreadable(address(usdc)));
        script.run();
        vm.clearMockedCalls();
    }

    /// @notice The census site on its own, all six members agreeing on a CODELESS settlement address.
    /// @dev Six `usdc()`/`asset()` reads are mocked to one codeless address so the agreement arm
    ///      passes and the decimals arm is the one asked. Before the fix: `EvmError: Revert`, empty.
    function test_R52A01_167_census_aCodelessSettlementIsRefusedByName() public {
        Deployed memory d = _switchedOver();
        address nothing = makeAddr("r52a01.codeless.settlement");
        bytes memory answer = abi.encode(nothing);
        vm.mockCall(address(d.credit), abi.encodeWithSignature("usdc()"), answer);
        vm.mockCall(address(d.auction), abi.encodeWithSignature("usdc()"), answer);
        vm.mockCall(address(d.harvester), abi.encodeWithSignature("usdc()"), answer);
        vm.mockCall(address(d.liquidity), abi.encodeWithSignature("usdc()"), answer);
        vm.mockCall(address(d.adapter), abi.encodeWithSignature("usdc()"), answer);
        vm.mockCall(address(d.pool), abi.encodeWithSignature("asset()"), answer);

        vm.expectRevert(_unreadable(nothing));
        script.exposedAssertCoreGraph(d, _params(address(this)));
        vm.clearMockedCalls();
    }

    // ── the sign-check on the fix's shape ───────────────────────────────────────────────────────

    /// @notice `try`/`catch` catches the REVERT and not the NO-DATA answer, which is why the fix is
    ///         a low-level `staticcall` and not a `try`.
    /// @dev MEASURED: the reverting token lands in `catch` (`Caught("")`); the no-data token does
    ///      NOT - Solidity's return-data decoding failure is raised in the caller and is not caught -
    ///      so the probe dies with the same empty revert the shipped code did.
    function test_R52A01_167_signCheck_tryCatchDoesNotCatchTheNoDataCase() public {
        R52A01TryCatchProbe probe = new R52A01TryCatchProbe();

        vm.mockCallRevert(address(usdc), DECIMALS, "");
        vm.expectRevert(abi.encodeWithSelector(R52A01TryCatchProbe.Caught.selector, bytes("")));
        probe.viaTryCatch(address(usdc));
        vm.clearMockedCalls();

        vm.mockCall(address(usdc), DECIMALS, "");
        vm.expectRevert(bytes(""));
        probe.viaTryCatch(address(usdc));
        vm.clearMockedCalls();

        // And a codeless address has the same shape as no data: `try` does not reach `catch`.
        address nothing = makeAddr("r52a01.codeless.probe");
        vm.expectRevert(bytes(""));
        probe.viaTryCatch(nothing);
    }
}
