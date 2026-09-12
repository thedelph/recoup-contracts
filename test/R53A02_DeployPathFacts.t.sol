// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {DeployReferralRegistry} from "../script/DeployReferral.s.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {Config} from "../src/Config.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Reverts `WithArgs(uint256)`, for the `vm.expectRevert(selector)` measurement.
contract R53A02Reverter {
    error WithArgs(uint256 value);

    function boom() external pure {
        revert WithArgs(7);
    }
}

contract R53A02FactsLockedProbe is AssertMockStackLocked {
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

contract R53A02FactsScript is WirePhase4 {
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

    function exposedDeploymentRecord() external view returns (string memory) {
        return _deploymentRecord();
    }

    function exposedDelayLeavesNoWindow(uint256 delay) external pure returns (bool) {
        return _delayLeavesNoWindow(delay);
    }

    function exposedDelayExceedsCeiling(uint256 delay) external pure returns (bool) {
        return _delayExceedsCeiling(delay);
    }
}

/// @notice Round-53 items 184 and 185 confirmed by execution, the two re-filed deploy-path leads
///         executed, and `DeployReferral.s.sol`'s refusal read by execution. One test each, cheap.
///
/// @dev Every claim MEASURED. Tests marked PINS OPEN assert the shipped behaviour and a fix must
///      turn them red. Promoted to a regression suite by round 53's contracts wave, which shipped
///      the timelock probe (`DeployedAddressHasNoCode("RECOUP_TIMELOCK", t)` then
///      `TimelockDoesNotAnswer(t)`): the two timelock tests at the end were rewritten to assert the
///      named errors. The `184_pinsOpen` pair (a record with no `chainId`, a locked record with no
///      `seededPosition`) were FLIPPED by round 54 (round-54 item 196: `_requireRecordRow` on
///      `.chainId` and the nine `_readStack` rows, `DeployedRecordRowMissing` now declared on
///      `DeployBase`); the hundred-year-delay pin was FLIPPED by round 55 (`_delayExceedsCeiling`,
///      a warning at both `getMinDelay()` sites, round-55 item 225(ii)).
contract R53A02DeployPathFactsTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant BASE_MAINNET = 8453;
    bytes4 internal constant CHEATCODE_ERROR = bytes4(keccak256("CheatcodeError(string)"));

    address internal treasury = makeAddr("r53a02.facts.treasury");
    address internal feeWallet = makeAddr("r53a02.facts.feeWallet");
    address internal keeper = makeAddr("r53a02.facts.keeper");
    address internal navConfirmer = makeAddr("r53a02.facts.navConfirmer");
    address internal guardian = makeAddr("r53a02.facts.guardian");

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
        // MEASURED, and the reason this line exists: forge's default `block.timestamp` is 1 and OZ's
        // `DONE_TIMESTAMP` sentinel is 1, so a ZERO-delay operation scheduled at the default
        // timestamp lands at `_timestamps[id] == 1` and is born DONE - `executeBatch` refuses it
        // `TimelockUnexpectedOperationState(id, Ready)` in the same block it was scheduled in. Any
        // zero-delay timelock test at the default timestamp measures the sentinel, not the delay.
        vm.warp(1_788_000_000);
    }

    // ── round-53 item 185: two facts about forge ─────────────────────────────────────────────────

    /// @notice 185(1) CONFIRMED: `vm.mockCallRevert` on an address with no code etches code there, and
    ///         so does `vm.mockCall`. A "codeless" probe after either is not codeless.
    function test_R53A02_185_1_mockCallRevertAndMockCallEtchCodeOnACodelessAddress() public {
        address a = makeAddr("r53a02.etch.revert");
        address b = makeAddr("r53a02.etch.call");
        assertEq(a.code.length, 0, "premise a");
        assertEq(b.code.length, 0, "premise b");

        bytes memory anyCalldata = hex"";
        bytes memory reason = bytes("nope");
        vm.mockCallRevert(a, anyCalldata, reason);
        vm.mockCall(b, anyCalldata, anyCalldata);

        assertGt(a.code.length, 0, "mockCallRevert etched code");
        assertGt(b.code.length, 0, "mockCall etched code");
    }

    /// @notice 185(2) CONFIRMED, the positive half here and the negative half measured as a red test in
    ///         the round's copy-out directory: `vm.expectRevert(WithArgs.selector)` does NOT match
    ///         `WithArgs(7)` (it failed `Error != expected error: WithArgs(7) != custom error 0x...`),
    ///         while the encoded form and `expectPartialRevert` both do.
    function test_R53A02_185_2_theEncodedFormAndThePartialFormMatchARevertWithArguments() public {
        R53A02Reverter r = new R53A02Reverter();

        vm.expectRevert(abi.encodeWithSelector(R53A02Reverter.WithArgs.selector, 7));
        r.boom();

        vm.expectPartialRevert(R53A02Reverter.WithArgs.selector);
        r.boom();
    }

    // ── round-53 item 184(1)'s mirror: the rows with no `keyExistsJson` at all ───────────────────

    /// @notice FIXED in round 54 (was PINS OPEN, asserting `CheatcodeError(string)`). `_deploymentRecord`
    ///         parsed `.chainId` with no key check, so a record with no `chainId` row died inside the
    ///         parser rather than at a named error - the same shape as 184(1), one row earlier than
    ///         every row it guards. Now `DeployedRecordRowMissing("chainId", ".chainId")`.
    function test_R53A02_184_fixed_aRecordWithNoChainIdRowIsNamed() public {
        R53A02FactsScript script = new R53A02FactsScript();
        script.setRecord('{"operators":{"owner":"0x0000000000000000000000000000000000000001"}}');

        (bool ok, bytes memory reason) = address(script).staticcall(abi.encodeCall(script.exposedDeploymentRecord, ()));
        assertFalse(ok, "premise: it reverts");
        assertEq(
            reason,
            abi.encodeWithSelector(DeployBase.DeployedRecordRowMissing.selector, "chainId", ".chainId"),
            "named, not the parser's"
        );
    }

    /// @notice FIXED in round 54 (was PINS OPEN, asserting `CheatcodeError(string)`). `AssertLocked.
    ///         _readStack` parsed NINE rows (this docstring said eight) with no key check on any of
    ///         them: a record with no `seededPosition` died inside the parser, unnamed, before a single
    ///         line had been printed. Now `DeployedRecordRowMissing("seededPosition.bonds",
    ///         ".seededPosition.bonds")`; `R54A04_RecordRowsNamed` covers all nine.
    function test_R53A02_184_fixed_aLockedRecordWithNoSeededPositionIsNamed() public {
        R53A02FactsLockedProbe probe = new R53A02FactsLockedProbe();
        probe.setRecord(
            string.concat(
                '{"chainId":', vm.toString(BASE_SEPOLIA), ',"deployer":"', vm.toString(address(this)), '",',
                '"operators":{"keeper":"', vm.toString(keeper), '"},',
                '"mocks":{"MockUSDC":"', vm.toString(address(usdc)), '","MockBond":"', vm.toString(address(bond)),
                '","MockFarm":"', vm.toString(address(farm)), '"},',
                '"contracts":{"CollateralVault":"', vm.toString(address(farm)), '","DirectCallAdapter":"',
                vm.toString(address(farm)), '"}}'
            )
        );

        (bool ok, bytes memory reason) = address(probe).call(abi.encodeCall(probe.assertLockedOnChain, ()));
        assertFalse(ok, "premise: it reverts");
        assertEq(
            reason,
            abi.encodeWithSelector(
                DeployBase.DeployedRecordRowMissing.selector, "seededPosition.bonds", ".seededPosition.bonds"
            ),
            "named, not the parser's"
        );
    }

    // ── round-52 item 146's lead (3): `_readStack` and the wrong `--sender` ──────────────────────

    /// @notice CONFIRMED, and it failed CLOSED and loudly: a stack locked to one deployer while the
    ///         record's `.deployer` names another WAS `MockAdminWrong("MockUSDC", actual, expected)`.
    ///         The message said "wrong admin" and not "wrong sender", which was the whole of the lead.
    /// @dev 🟩 **FLIPPED TO FIXED in round 56 (round-56 item 145 lead 3, audit agent A6).** All three
    ///      mocks here are created AND locked by this test contract, so `admin` and `lockAuthority`
    ///      agree on one key across the stack - the fingerprint `AssertLocked` now names as
    ///      `StackDeployedByAnotherKey(chainKey, recordDeployer)`. Renamed from `...AsAWrongAdmin`.
    ///      The partial shapes that must stay `MockAdminWrong` are pinned in `R56A06_WrongSender.t.sol`.
    function test_R53A02_lead_aLockedStackFromTheWrongSenderIsNamedAsTheWrongKey() public {
        R53A02FactsLockedProbe probe = new R53A02FactsLockedProbe();
        MockUSDC u = new MockUSDC();
        MockBond b = new MockBond();
        MockFarm f = new MockFarm(b, u);
        address lockKeeper = address(0xC0FFEE);
        address intended = makeAddr("r53a02.intended.deployer");
        u.lockTo(address(this), lockKeeper);
        b.lockTo(address(this), lockKeeper);
        f.lockTo(address(this), lockKeeper);
        probe.setRecord(
            string.concat(
                '{"chainId":', vm.toString(BASE_SEPOLIA), ',"deployer":"', vm.toString(intended), '",',
                '"operators":{"keeper":"', vm.toString(lockKeeper), '"},',
                '"mocks":{"MockUSDC":"', vm.toString(address(u)), '","MockBond":"', vm.toString(address(b)),
                '","MockFarm":"', vm.toString(address(f)), '"},',
                '"contracts":{"CollateralVault":"', vm.toString(address(f)), '","DirectCallAdapter":"',
                vm.toString(address(f)), '"},"seededPosition":{"bonds":0}}'
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.StackDeployedByAnotherKey.selector, address(this), intended)
        );
        probe.assertLockedOnChain();
    }

    // ── `DeployReferral.s.sol`, read by execution ────────────────────────────────────────────────

    /// @notice On Base MAINNET `run()` is refused `LiveDeploymentDisabled()`, four bytes, and the chain
    ///         is named nowhere in it; the confirmation phrase is never consulted because the gate
    ///         precedes the read. On anvil it needs no confirmation at all.
    function test_R53A02_referral_theLiveGateNamesNoChainAndPrecedesThePhrase() public {
        DeployReferralRegistry script = new DeployReferralRegistry();
        vm.chainId(BASE_MAINNET);

        (bool ok, bytes memory reason) = address(script).call(abi.encodeCall(script.run, ()));
        assertFalse(ok, "premise: refused");
        assertEq(reason.length, 4, "the refusal carries no chain id and no phrase");
        assertEq(bytes4(reason), DeployReferralRegistry.LiveDeploymentDisabled.selector, "wrong error");

        vm.chainId(ANVIL_CHAIN_ID);
        script.run();
    }

    // ── round-52 item 145's lead (1), re-filed: `getMinDelay()` read and never checked ──────────

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

    function _timelock(uint256 minDelay) internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(minDelay, proposers, executors, address(0));
    }

    /// @dev A deployment handed to `newOwner`, with the environment and record installed on a script.
    function _ceremony(address newOwner) internal returns (R53A02FactsScript script, Deployed memory d) {
        d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, newOwner);
        script = new R53A02FactsScript();
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
        script.setEnvAddress("RECOUP_OWNER", newOwner);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setEnvAddress("RECOUP_TIMELOCK", newOwner);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(newOwner), '"},'
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
        script.setRecord(string.concat(head, first, second));
    }

    /// @notice CONFIRMED (round 51 measured it first): under `minDelay == 0` the whole four-step ceremony
    ///         lands in ONE block with `block.timestamp` unmoved, and the shipped predicate is what
    ///         warns; it is a warning and not a refusal.
    function test_R53A02_lead_aZeroDelayCeremonyCompletesInOneBlockAndOnlyWarns() public {
        TimelockController timelock = _timelock(0);
        (R53A02FactsScript script, Deployed memory d) = _ceremony(address(timelock));
        uint256 t0 = block.timestamp;

        script.queuePause();
        script.executeQueuedPause();
        script.queue();
        script.executeQueued();

        assertEq(block.timestamp, t0, "no time passed");
        assertEq(d.credit.liquiditySource(), address(d.pool), "the switchover completed");
        assertTrue(script.exposedDelayLeavesNoWindow(0), "the warning predicate holds at zero");
    }

    /// @notice FIXED in round 55 (was PINS OPEN; round-54 item 197, costed as round-55 item 225(ii)).
    ///         An ABSURD delay - one hundred years - is still accepted by `queuePause()` and
    ///         scheduled, because `minDelay` is governance's parameter and a refusal would leave no
    ///         repair path (`updateDelay` sits behind the same delay). It is now WARNED about: the
    ///         second predicate, `_delayExceedsCeiling`, holds above `15 * Config.ADMIN_TIMELOCK`
    ///         (30 days, Compound's `Timelock.MAXIMUM_DELAY`), and `_warnIfDelayLeavesNoWindow`
    ///         prints the ceiling block at both call sites. The zero predicate stays silent here,
    ///         which is the reason the second one exists.
    function test_R53A02_lead_fixed_aHundredYearDelayIsScheduledAndWarnedAbout() public {
        TimelockController timelock = _timelock(100 * 365 days);
        (R53A02FactsScript script, Deployed memory d) = _ceremony(address(timelock));

        script.queuePause();

        assertFalse(script.exposedDelayLeavesNoWindow(100 * 365 days), "the zero predicate is silent, as before");
        assertTrue(script.exposedDelayExceedsCeiling(100 * 365 days), "the ceiling predicate holds");
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4PauseCalls(d);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationPending(id), "scheduled");
        assertFalse(timelock.isOperationReady(id), "and not ready");
        vm.warp(block.timestamp + 50 * 365 days);
        assertFalse(timelock.isOperationReady(id), "not ready fifty years on either");
    }

    /// @notice CONFIRMED: `type(uint256).max` as the delay is refused, but by OZ's own arithmetic
    ///         (`block.timestamp + delay` overflows in `_schedule`, Panic 0x11), not by this script.
    ///         Loud, and unnamed.
    function test_R53A02_lead_aMaximalDelayIsRefusedByArithmeticNotByTheScript() public {
        TimelockController timelock = _timelock(type(uint256).max);
        (R53A02FactsScript script,) = _ceremony(address(timelock));

        vm.expectRevert(stdError.arithmeticError);
        script.queuePause();
    }

    // ── the mirror of round-52 item 167 on the TIMELOCK dereference ─────────────────────────────

    /// @notice FIXED in round 53 (was PINS OPEN, asserting an EMPTY revert). `RECOUP_TIMELOCK` naming
    ///         the EOA that owns the graph - which is the shape of the deployment that exists today -
    ///         passed `TimelockIsNotTheOwner` (it IS the owner) and died EMPTY on
    ///         `timelock.getMinDelay()`, a high-level call to an address with no code. Round 52
    ///         named the vault's dereference `DeployedAddressHasNoCode`; the timelock's dereference
    ///         is the same shape one function over and is now named the same way, from
    ///         `_requiredTimelock`, before the first dereference on every timelock entry point.
    function test_R53A02_mirror_anEoaOwnerNamedAsTheTimelockIsNamedHasNoCode() public {
        address eoaOwner = makeAddr("r53a02.eoa.owner");
        (R53A02FactsScript script,) = _ceremony(eoaOwner);
        assertEq(eoaOwner.code.length, 0, "premise: the owner is an EOA");

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressHasNoCode.selector, "RECOUP_TIMELOCK", eoaOwner)
        );
        script.queuePause();
    }

    /// @notice Negative, recorded, and MOVED by the round-53 probe: `RECOUP_TIMELOCK` naming a
    ///         codeless stranger used to be named `TimelockIsNotTheOwner` by luck of ordering, so
    ///         only the "is the owner and has no code" case died empty. The probe runs in
    ///         `_requiredTimelock`, before `_queuePause`'s owner check, so the stranger is now
    ///         `DeployedAddressHasNoCode("RECOUP_TIMELOCK", stranger)` - a precedence change and
    ///         the more precise diagnosis, stated rather than accidental.
    function test_R53A02_mirror_negative_aCodelessStrangerAsTheTimelockIsNamed() public {
        TimelockController timelock = _timelock(Config.ADMIN_TIMELOCK);
        (R53A02FactsScript script,) = _ceremony(address(timelock));
        address nobody = makeAddr("r53a02.nobody");
        script.setEnvAddress("RECOUP_TIMELOCK", nobody);

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressHasNoCode.selector, "RECOUP_TIMELOCK", nobody)
        );
        script.queuePause();
    }
}
