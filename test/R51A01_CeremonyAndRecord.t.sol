// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Hermetic `WirePhase4`, the same construction `R50WirePhase4Record.t.sol` uses.
contract R51A01Ceremony is WirePhase4 {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    mapping(bytes32 => string) private _str;
    mapping(bytes32 => bool) private _strSet;

    function setEnvAddress(string memory key, address value) external {
        _addr[keccak256(bytes(key))] = value;
        _addrSet[keccak256(bytes(key))] = true;
    }

    function setEnvString(string memory key, string memory value) external {
        _str[keccak256(bytes(key))] = value;
        _strSet[keccak256(bytes(key))] = true;
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

    /// @dev The local chain, so `_deploymentRecord()` returns the empty string and this suite
    ///      depends on no committed file. The findings below are about the timelock and the
    ///      executor set, neither of which the record touches.
    function _readRecord() internal pure override returns (string memory) {
        return "";
    }

    /// @dev The seam the printed line is built from. `msg.sender` inside `_senderCanExecute` is
    ///      whoever called this contract, which is exactly what it is inside `_queue` and
    ///      `_queuePause`, so an external call from a test asks the same question a real run does.
    function exposedExecuteAudienceLine(TimelockController t) external view returns (string memory) {
        return _executeAudienceLine(t);
    }

    function exposedSenderCanExecute(TimelockController t) external view returns (bool) {
        return _senderCanExecute(t);
    }

    function exposedDelayLeavesNoWindow(uint256 delay) external pure returns (bool) {
        return _delayLeavesNoWindow(delay);
    }
}

/// @notice Round-51 item 170, A1's held-out row 5: `EXECUTOR_ROLE`'s open set is never read, and
///         both timelock entry points printed "sent by anyone" unconditionally.
///
/// @dev Every claim here is MEASURED at `196d4e7`, on the anvil chain id so the record seam is out
///      of the picture.
///
///      The closed executor set is a STATEMENT THE SCRIPT MAKES THAT CAN BE FALSE. "Anyone" is true
///      only while `EXECUTOR_ROLE` is held by `address(0)`, which is how `Governance.t.sol` and this
///      repository's fixtures deploy a `TimelockController` and is NOT a property of the contract.
///      With a closed set the script schedules happily, the operator waits out the maturity, and
///      `executeQueuedPause()` reverts from the broadcasting key.
///
///      The blast radius is the pause step, not the switchover: `queuePause()` is what an operator
///      runs FIRST and it is the step a wind-down depends on. A scheduled-but-unexecutable pause
///      leaves the operation `Ready` forever - `TimelockController` has no grace period - which is
///      the round-21 armed-replay shape reached by a role rather than by state.
///
///      The fix is a WARNING and not a refusal: a closed executor set is a legitimate governance
///      choice, and what was wrong is the sentence rather than the state.
contract R51A01CeremonyTest is Test, DeployBase {
    // `CONSOLE` is forge-std `CommonBase`'s own constant and is inherited through `Test`.
    // `vm.expectCall` against it is the only way to hold a printed LINE to the tree: `console.log`
    // is a `staticcall` that emits no event, so `vm.recordLogs` sees nothing.

    address internal treasury = makeAddr("r51a01.c.treasury");
    address internal keeper = makeAddr("r51a01.c.keeper");
    address internal navConfirmer = makeAddr("r51a01.c.navConfirmer");
    /// @dev A named executor that is neither `address(0)` nor the sender, which is the shape the
    ///      warning is about: a governance setup that grants execution to a committee.
    address internal committee = makeAddr("r51a01.c.committee");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    R51A01Ceremony internal script;

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
        vm.chainId(ANVIL_CHAIN_ID);
        // 🟥 **Not decoration.** Forge starts a test at `block.timestamp == 1`, and OZ's
        // `DONE_TIMESTAMP` IS 1 - so a `scheduleBatch(..., 0)` in the first block stores
        // `_timestamps[id] = 1` and `getOperationState` reads the operation as **Done** before it
        // has run. MEASURED: without this line the zero-delay test in this file reverts
        // `TimelockUnexpectedOperationState(id, 0x04)` at `executeQueuedPause()` with the id burned
        // forever. That is an artefact of the fixture's clock and not a property of any chain, so
        // the clock is moved to a realistic instant and the findings are measured on their own terms.
        vm.warp(1_788_000_000);
        script = new R51A01Ceremony();
    }

    function _externals() internal view returns (Externals memory) {
        return Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });
    }

    function _params(address owner_) internal view returns (GovParams memory) {
        return GovParams({
            owner: owner_,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: treasury,
            guardian: address(0)
        });
    }

    function _timelock(uint256 delay, bool openExecution) internal returns (TimelockController t) {
        return _timelockWith(delay, openExecution ? address(0) : address(this));
    }

    /// @dev The executor is a parameter because the warning is about `msg.sender`, not about the
    ///      role being closed - so the two questions need two different fixtures, and a single
    ///      `bool` would let one arm pass on the other's evidence.
    function _timelockWith(uint256 delay, address executor) internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = executor;
        t = new TimelockController(delay, proposers, executors, address(0));
    }

    function _installEnv(Deployed memory d, address owner_, TimelockController t) internal {
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
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", treasury);
        script.setEnvAddress("RECOUP_TIMELOCK", address(t));
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
    }

    string internal constant OPEN_LINE =
        "executeBatch calldata - ONE transaction, after the delay, sent by anyone (EXECUTOR_ROLE is open):";
    string internal constant CLOSED_LINE =
        "executeBatch calldata - ONE transaction, after the delay, sent by an EXECUTOR_ROLE holder (execution is NOT open):";

    function _assertLine(string memory got, string memory want, string memory what) internal pure {
        assertEq(keccak256(bytes(got)), keccak256(bytes(want)), what);
    }

    // ── the finding: the executor set is never read ──────────────────────────

    /// @notice THE FINDING. The script scheduled, the operator waited a full maturity, and the
    ///         broadcasting key could not execute - having been told "sent by anyone".
    /// @dev MEASURED. `executors = [address(this)]` is a CLOSED set: `hasRole(EXECUTOR_ROLE,
    ///      address(0))` is false, so `onlyRoleOrOpenRole` refuses `DEFAULT_SENDER`.
    function test_R51A01_170_aClosedExecutorSetStrandsThePauseAfterTheClock() public {
        TimelockController t = _timelock(Config.ADMIN_TIMELOCK, false);
        assertFalse(t.hasRole(t.EXECUTOR_ROLE(), address(0)), "premise: execution is NOT open");
        assertFalse(t.hasRole(t.EXECUTOR_ROLE(), DEFAULT_SENDER), "premise: nor does the broadcasting key hold it");

        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(t));
        _installEnv(d, address(t), t);

        script.queuePause();
        (address[] memory tg, uint256[] memory v, bytes[] memory pl) = _phase4PauseCalls(d);
        assertTrue(t.isOperationPending(t.hashOperationBatch(tg, v, pl, bytes32(0), bytes32(0))), "it is armed");

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, DEFAULT_SENDER, t.EXECUTOR_ROLE()
            )
        );
        script.executeQueuedPause();

        assertFalse(d.credit.paused(), "nothing was shut, a maturity after the operator committed");
    }

    /// @notice Control: the same closed set with the batch fired by a real executor works, so the
    ///         refusal above is the ROLE and not the batch.
    function test_R51A01_170_control_aRealExecutorRunsTheSameStrandedBatch() public {
        TimelockController t = _timelock(Config.ADMIN_TIMELOCK, false);
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(t));
        _installEnv(d, address(t), t);

        script.queuePause();
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        (address[] memory tg, uint256[] memory v, bytes[] memory pl) = _phase4PauseCalls(d);
        t.executeBatch(tg, v, pl, bytes32(0), bytes32(0));
        assertTrue(d.credit.paused(), "control: the pause lands from the address that holds the role");
    }

    // ── the fix: the printed line asks the timelock ──────────────────────────

    /// @notice THE FIX, measured on the seam the printed line is built from. Both directions,
    ///         because a line that is always the closed one is as wrong as a line that was always
    ///         the open one.
    /// @dev 🟥 **The obvious assertion does not work and this is the record of that measurement.**
    ///      `vm.expectCall(CONSOLE, abi.encodeWithSignature("log(string)", line))` reports
    ///      `called 0 times` against lines the run demonstrably printed - forge does not surface
    ///      forge-std's console `staticcall` to `expectCall` - and `console.log` emits no event, so
    ///      `vm.recordLogs` sees nothing either. Four arms written that way went red on a green fix.
    ///      Hence the predicate seam, asserted here directly.
    function test_R51A01_170_fix_theAudienceLineAsksTheTimelock() public {
        _assertLine(
            script.exposedExecuteAudienceLine(_timelock(Config.ADMIN_TIMELOCK, true)),
            OPEN_LINE,
            "an open executor set must say anyone"
        );
        _assertLine(
            script.exposedExecuteAudienceLine(_timelockWith(Config.ADMIN_TIMELOCK, committee)),
            CLOSED_LINE,
            "a closed executor set must say so"
        );
    }

    /// @notice The warning is about THIS KEY, not about the role being closed, so the three cases
    ///         are asserted apart.
    function test_R51A01_170_fix_theWarningIsAboutTheSenderAndNotTheRole() public {
        assertTrue(
            script.exposedSenderCanExecute(_timelock(Config.ADMIN_TIMELOCK, true)),
            "open execution: anybody can, so no warning"
        );
        assertTrue(
            script.exposedSenderCanExecute(_timelockWith(Config.ADMIN_TIMELOCK, address(this))),
            "closed execution, this key holds the role: no warning"
        );
        assertFalse(
            script.exposedSenderCanExecute(_timelockWith(Config.ADMIN_TIMELOCK, committee)),
            "closed execution, the committee holds it: this is the case that warns"
        );
    }

    /// @notice And the whole pause step runs over a closed set, warning and all, so the print path
    ///         is executed rather than only the predicate.
    /// @dev The switchover step carries the identical pair, because `_queue` printed the same
    ///      unconditional sentence and a fix in one entry point only would be half a fix. Driven
    ///      here end to end: pause, execute it as the committee, then `queue()`.
    function test_R51A01_170_fix_bothEntryPointsRunTheNewPrintPath() public {
        TimelockController closed = _timelockWith(Config.ADMIN_TIMELOCK, committee);
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(closed));
        _installEnv(d, address(closed), closed);
        assertFalse(script.exposedSenderCanExecute(closed), "premise: this key cannot fire what it schedules");

        script.queuePause();
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        (address[] memory tg, uint256[] memory v, bytes[] memory pl) = _phase4PauseCalls(d);
        vm.prank(committee);
        closed.executeBatch(tg, v, pl, bytes32(0), bytes32(0));

        script.queue();
        assertTrue(
            closed.isOperationPending(
                closed.hashOperationBatch(_targetsOf(d), _valuesOf(d), _payloadsOf(d), bytes32(0), bytes32(0))
            ),
            "the switchover is scheduled, and the operator was told who can fire it"
        );
    }

    // ── item 150 lead 1: getMinDelay() is read, printed and checked by nothing ─

    /// @notice THE FINDING. A `minDelay == 0` timelock runs the entire two-operation ceremony in one
    ///         block, and no line of `WirePhase4` said so.
    /// @dev MEASURED. Not one `vm.warp` in this test: `block.timestamp` is asserted unchanged at the
    ///      end, and the switchover has completed. The pause that round 21 moved out of the batch
    ///      protects exactly the zero duration round 20 measured it protecting.
    function test_R51A01_150_aZeroDelayTimelockCollapsesTheCeremonyIntoOneBlock() public {
        TimelockController t = _timelock(0, true);
        assertEq(t.getMinDelay(), 0, "premise: the timelock has no delay");

        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(t));
        _installEnv(d, address(t), t);

        uint256 startedAt = block.timestamp;
        script.queuePause();
        script.executeQueuedPause();
        script.queue();
        script.executeQueued();

        assertEq(block.timestamp, startedAt, "the whole ceremony fitted inside one block");
        assertEq(d.credit.liquiditySource(), address(d.pool), "and the switchover completed");
        assertFalse(d.credit.paused(), "with the doors reopened in the same block they shut");
    }

    /// @notice Control: at `Config.ADMIN_TIMELOCK` the same call sequence refuses without a warp, so
    ///         the test above is measuring the delay and not a broken fixture.
    function test_R51A01_150_control_theDefaultDelayRefusesAnImmediateExecution() public {
        TimelockController t = _timelock(Config.ADMIN_TIMELOCK, true);
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(t));
        _installEnv(d, address(t), t);

        script.queuePause();
        vm.expectRevert();
        script.executeQueuedPause();
    }

    /// @notice THE FIX, measured: zero is the only value that warns, so the warning is not a
    ///         disguised floor.
    /// @dev A refusal would be the wrong shape - `minDelay` is governance's parameter and a floor
    ///      would refuse a legitimate rehearsal or a testnet. What is not governance's opinion is
    ///      that this file printed the number and reasoned from a window it makes zero.
    function test_R51A01_150_fix_zeroIsTheOnlyValueThatWarns() public view {
        assertTrue(script.exposedDelayLeavesNoWindow(0), "the warning fires at zero");
        assertFalse(script.exposedDelayLeavesNoWindow(1), "and not at one second");
        assertFalse(script.exposedDelayLeavesNoWindow(Config.ADMIN_TIMELOCK), "nor at the default");
    }

    function _targetsOf(Deployed memory d) internal pure returns (address[] memory t) {
        (t,,) = _phase4Calls(d);
    }

    function _valuesOf(Deployed memory d) internal pure returns (uint256[] memory v) {
        (, v,) = _phase4Calls(d);
    }

    function _payloadsOf(Deployed memory d) internal pure returns (bytes[] memory p) {
        (,, p) = _phase4Calls(d);
    }
}

// ── item 150 lead 2: AssertLocked never asked whether the record's contracts hold code ─────────

/// @notice `AssertMockStackLocked` with the record seam closed, and both base environment reads
///         returned as their fallback so `contracts/.env` cannot decide a test.
contract R51A01LockedProbe is AssertMockStackLocked {
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

    /// @dev 🟥 **This override is NOT decoration and `R39AssertLockedHarness` does not have it.**
    ///      `AssertMockStackLocked` inherits `DeployBase`, so it inherits the raw `vm.envOr` string
    ///      seam, and round-49 item 136's census credits a door when ANY contract in the same FILE
    ///      makes a qualified call to a reader ("a qualified call cannot be attributed without
    ///      types, so it credits every door in the file"). MEASURED: without this override, the
    ///      `script.queuePause()` calls in the other contract in this file made this probe a REACHED
    ///      door and turned the census red. Hermetic here, and the census is green.
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

/// @notice Round-51 item 150, lead 2. `AssertLocked._readStack` parses `.contracts.CollateralVault`
///         and `.contracts.DirectCallAdapter` off the record and used them ONLY as arguments to
///         `bond.whitelistContains(...)` and `usdc.blocked(...)`. It never asked whether either
///         address held code, so a record row naming nothing at all passed the entrypoint green -
///         and `usdc.blocked(address(0))` is `false`, so even the zero address passed.
///
/// @dev **The shipped suite already demonstrated this and nobody read it as a finding.**
///      `R39AssertLocked.t.sol` set `VAULT = address(0xFA017)` and `ADAPTER = address(0xADA97E)`,
///      two literals with no code, and `test_R39_theEntrypointPassesOverACorrectlyLockedStack` was
///      green. Both are deployed contracts now, in the same change, because a fixture that cannot
///      tell the two states apart cannot be the evidence that they are told apart.
///
///      **Severity LOW, and the reason is worth stating rather than assuming.** A wrong
///      `contracts.*` row does not make the mock stack less locked. What it costs is the OTHER
///      direction, and that is measured below: a mistyped adapter row used to fail
///      `_assertConfigurationPristine` as "the adapter is not whitelisted - an unfinished broadcast
///      (try --resume) or a tamper", which is the exact misdiagnosis that function's own docstring
///      says it was rewritten to avoid one cause over.
contract R51A01AssertLockedRecordTest is Test {
    R51A01LockedProbe internal probe;
    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant NOTHING = address(0xDEADBEEF);

    function setUp() public {
        probe = new R51A01LockedProbe();
        usdc = new MockUSDC();
        usdc.lockTo(address(this), KEEPER);
        bond = new MockBond();
        bond.lockTo(address(this), KEEPER);
        farm = new MockFarm(bond, usdc);
        farm.lockTo(address(this), KEEPER);
        bond.setRewardPool(address(farm));
        bond.setWhitelisted(address(farm), true);
    }

    function _json(address vault_, address adapter_) internal view returns (string memory) {
        return string.concat(
            '{"chainId":31337,',
            '"deployer":"', vm.toString(address(this)), '",',
            '"operators":{"keeper":"', vm.toString(KEEPER), '"},',
            '"mocks":{"MockUSDC":"', vm.toString(address(usdc)),
            '","MockBond":"', vm.toString(address(bond)),
            '","MockFarm":"', vm.toString(address(farm)), '"},',
            '"contracts":{"CollateralVault":"', vm.toString(vault_),
            '","DirectCallAdapter":"', vm.toString(adapter_), '"},',
            '"seededPosition":{"bonds":0}}'
        );
    }

    /// @notice THE FINDING, flipped. Both `contracts.*` rows name codeless addresses; before the fix
    ///         the whole entrypoint was green and printed "no configuration value has moved".
    function test_R51A01_150_theEntrypointRefusesCodelessContractRows() public {
        bond.setWhitelisted(NOTHING, true);
        probe.setRecord(_json(NOTHING, NOTHING));
        assertEq(NOTHING.code.length, 0, "premise: the row names nothing");

        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.NoCodeAt.selector, "contracts.CollateralVault", NOTHING)
        );
        probe.assertLockedOnChain();
    }

    /// @notice And the zero address is refused too. It used to pass, because `blocked(0)` is `false`
    ///         and the adapter clause was the only one that would have noticed.
    function test_R51A01_150_theZeroAddressIsRefusedRatherThanPassingTheVaultClauses() public {
        bond.setWhitelisted(address(0), true);
        probe.setRecord(_json(address(0), address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.NoCodeAt.selector, "contracts.CollateralVault", address(0)
            )
        );
        probe.assertLockedOnChain();
    }

    /// @notice The adapter row is asked separately, so a vault row that is fine does not carry it.
    function test_R51A01_150_theAdapterRowIsAskedOnItsOwn() public {
        address real = address(new NoCodeProbeStandIn());
        bond.setWhitelisted(NOTHING, true);
        probe.setRecord(_json(real, NOTHING));

        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.NoCodeAt.selector, "contracts.DirectCallAdapter", NOTHING)
        );
        probe.assertLockedOnChain();
    }

    /// @notice Control: two addresses that DO hold code pass, so the census is not a refusal of
    ///         everything. The mocks stand in for the two rows - what the census asks is whether the
    ///         record points at a contract, not which one.
    function test_R51A01_150_control_recordedContractsThatHoldCodePass() public {
        bond.setWhitelisted(address(usdc), true);
        probe.setRecord(_json(address(bond), address(usdc)));
        probe.assertLockedOnChain();
    }

    /// @notice The misdiagnosis, executed with the new clause removed from the picture: a mistyped
    ///         adapter row used to read as a TAMPER.
    /// @dev This is why the two `EXTCODESIZE` reads are worth their lines and why they run BEFORE
    ///      `_assertConfigurationPristine`. The message named an unfinished broadcast and an attack,
    ///      and the cause was a typo in a committed file. Asserted here by asking
    ///      `_assertConfigurationPristine`'s question directly, which is what the old entrypoint did.
    function test_R51A01_150_theMisdiagnosisTheNewClauseReplaces() public view {
        assertFalse(
            bond.whitelistContains(NOTHING),
            "a codeless adapter row is not whitelisted, which is what used to be reported as a tamper"
        );
        assertFalse(usdc.blocked(address(0)), "and blocked(0) is false, which is why the zero row passed");
    }
}

/// @dev Any contract will do: the census asks whether the row names code, not which code.
contract NoCodeProbeStandIn {
    uint256 public something;
}
