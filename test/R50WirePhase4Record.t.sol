// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice `WirePhase4` with both of its seams closed: the environment answers from this object's
///         own storage, and the deployment record is a string this test hands it.
///
/// @dev Hermetic on both. The environment seam is round-49 item 136's discipline - return the
///      fallback, never `super`, so `contracts/.env` cannot decide a test. The record seam is
///      round-50 item 134's, and it is the same construction `AssertLocked`'s harness uses: the
///      base implementation reads the real disk and is exercised only on a real run, so the tests
///      depend on no committed file and a change to `deployments/base-sepolia.json` cannot turn
///      this suite red.
contract R50RecordWirePhase4 is WirePhase4 {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    string private _record;

    function setEnvAddress(string memory key, address value) external {
        bytes32 k = keccak256(bytes(key));
        _addr[k] = value;
        _addrSet[k] = true;
    }

    function setRecord(string memory json) external {
        _record = json;
    }

    function _envOrAddress(string memory key, address fallbackValue) internal view override returns (address) {
        bytes32 k = keccak256(bytes(key));
        return _addrSet[k] ? _addr[k] : fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue)
        internal
        pure
        override
        returns (string memory)
    {
        return fallbackValue;
    }

    /// @dev The empty string is how an ABSENT record reaches `_deploymentRecord`, so a test that
    ///      never calls `setRecord` is the missing-record case with nothing extra to arrange.
    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    function exposedResolveDeployed() external view returns (Deployed memory) {
        return _resolveDeployed();
    }

    function exposedResolveParamsAgainstRecord(address sender) external view returns (GovParams memory) {
        return _resolveParamsAgainstRecord(sender);
    }

    function exposedRequiredTimelock() external view returns (address) {
        return _requiredTimelock();
    }

    function exposedAssertCoreGraph(Deployed memory d, GovParams memory p) external view {
        _assertCoreGraph(d, p);
    }
}

/// @notice Round-50 item 134: the switchover was built entirely out of the environment and never
///         opened the committed deployment record, so a SELF-CONSISTENT STALE GENERATION passed
///         every check in the file.
///
/// @dev Every other assertion `WirePhase4` makes is RELATIVE. `_assertCoreGraph` asks whether the
///      eight addresses point at each other and at `GovParams`; `_requireSwitchoverWindowShut` asks
///      whether the book behind them is flat; the round-49 timelock guard asks whether the timelock
///      owns them. A superseded generation satisfies all three, because it was correct when it was
///      deployed and nothing about it has changed since. The record is the one ABSOLUTE available -
///      the statement of which generation is the live one - and it was the one input the script did
///      not read.
///
///      The disposition is round-47 item 95's, taken from `AssertLocked` one file over: the record
///      is the side asserted against, the environment is an override that must AGREE, an agreeing
///      value is tolerated because the documented commands run against one `.env` that forge
///      auto-loads, and a disagreeing pair is named with both values.
contract R50WirePhase4RecordTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant BASE_MAINNET = 8453;

    address internal treasury = makeAddr("r50.134.treasury");
    address internal feeWallet = makeAddr("r50.134.feeWallet");
    address internal owner = makeAddr("r50.134.owner");
    address internal keeper = makeAddr("r50.134.keeper");
    address internal navConfirmer = makeAddr("r50.134.navConfirmer");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    R50RecordWirePhase4 internal script;

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
        script = new R50RecordWirePhase4();
    }

    function _externals() internal view returns (Externals memory) {
        return Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });
    }

    function _params() internal view returns (GovParams memory) {
        return GovParams({
            owner: owner,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: feeWallet,
            guardian: address(0)
        });
    }

    function exposedDeployProtocol(Externals memory e, GovParams memory p, address deployer)
        external
        returns (Deployed memory)
    {
        return _deployProtocol(e, p, deployer);
    }

    /// @dev One whole generation of the protocol. Two of these is what makes the finding executable
    ///      rather than arguable: the point is not that the environment is wrong, it is that the
    ///      wrong environment is INTERNALLY CONSISTENT.
    function _generation() internal returns (Deployed memory) {
        return this.exposedDeployProtocol(_externals(), _params(), address(this));
    }

    /// @dev A record naming one generation, in the shape the real one has. Only the fields the
    ///      script reads are present: a record is a JSON document and `vm.parseJsonAddress` takes a
    ///      path, so a fixture that reproduced the whole 185-line file would be testing the fixture.
    ///
    ///      Assembled through `_row` in three steps rather than as one `string.concat` of
    ///      seventeen arguments, and that is not a style preference: solc 0.8.24 without `via-ir`
    ///      reports `Stack too deep` on the single-expression form. MEASURED while writing this
    ///      file, and recorded here because this is the only place in the tree that builds a
    ///      deployment record by hand.
    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', vm.toString(value), last ? '"' : '",');
    }

    function _recordFor(Deployed memory d, uint256 chainId, address recordOwner)
        internal
        pure
        returns (string memory)
    {
        string memory head = string.concat(
            '{"chainId":', vm.toString(chainId), ',"operators":{"owner":"', vm.toString(recordOwner), '"},'
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

    function _installEnv(Deployed memory d) internal {
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
    }

    // ── the finding ──────────────────────────────────────────────────────────

    /// @notice THE FINDING. A superseded generation is self-consistent, so every relative check in
    ///         the file passes on it, and only the record can tell it from the live one.
    /// @dev **RED before the fix, MEASURED at 9d1e72d:** `_resolveDeployed` returned the stale
    ///      generation without complaint, and the second half of this test - `_assertCoreGraph` over
    ///      that generation - passed then and passes now, which is the whole point. The premise is
    ///      asserted rather than argued precisely because it is the surprising half: the check that
    ///      is SUPPOSED to catch a wrong address cannot catch a wrong GENERATION, because a
    ///      generation is wrong only relative to a statement of which one is live.
    function test_R50_134_aStaleButSelfConsistentEnvironmentIsRefusedByName() public {
        Deployed memory stale = _generation();
        Deployed memory live = _generation();
        assertTrue(address(stale.credit) != address(live.credit), "premise: two distinct generations");

        // PREMISE, and the reason the record had to be read at all: the stale generation passes the
        // full graph census. Nothing relative can see anything wrong with it.
        script.exposedAssertCoreGraph(stale, _params());

        script.setRecord(_recordFor(live, BASE_SEPOLIA, owner));
        _installEnv(stale);

        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector,
                "RECOUP_NAV_ORACLE",
                address(stale.oracle),
                address(live.oracle)
            )
        );
        script.exposedResolveDeployed();
    }

    /// @notice Control: an environment that AGREES with the record resolves, and resolves to the
    ///         record's addresses.
    /// @dev Without this the refusal above would be satisfied by a resolver that refuses
    ///      everything, and the documented `deploy && assert` command - which runs both halves
    ///      against one `.env` that forge auto-loads into the run - would have stopped working.
    function test_R50_134_control_anAgreeingEnvironmentResolves() public {
        Deployed memory live = _generation();
        script.setRecord(_recordFor(live, BASE_SEPOLIA, owner));
        _installEnv(live);

        Deployed memory got = script.exposedResolveDeployed();
        assertEq(address(got.credit), address(live.credit), "control: the manager resolves");
        assertEq(address(got.pool), address(live.pool), "control: and the pool");
        assertEq(address(got.riskParams), address(live.riskParams), "control: and the derived risk params");
    }

    /// @notice With nothing in the environment at all, the record IS the answer.
    /// @dev The half that makes the change worth having rather than merely safe: the eight
    ///      addresses an operator used to retype are now optional, and a typo in one of them is a
    ///      named refusal rather than a switchover on a contract nobody meant.
    function test_R50_134_anUnsetEnvironmentResolvesFromTheRecord() public {
        Deployed memory live = _generation();
        script.setRecord(_recordFor(live, BASE_SEPOLIA, owner));

        Deployed memory got = script.exposedResolveDeployed();
        assertEq(address(got.oracle), address(live.oracle), "the record answers on its own");
        assertEq(address(got.auction), address(live.auction), "all eight of them");
    }

    /// @notice A missing record on a real chain is refused by name.
    /// @dev There is no such thing as a switchover on a deployment nobody recorded, and forge's own
    ///      file error is not a sentence an operator can act on.
    function test_R50_134_aMissingRecordOffLocalIsRefused() public {
        Deployed memory live = _generation();
        _installEnv(live);
        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeploymentRecordMissing.selector, "deployments/base-sepolia.json")
        );
        script.exposedResolveDeployed();
    }

    /// @notice A record describing another network is refused as such, not as an environment fault.
    /// @dev Without this arm the fix would be a defect of its own: run on Base mainnet, the Base
    ///      Sepolia record would refuse all eight addresses with `DeployedEnvDisagreesWithRecord` -
    ///      eight true statements about the wrong subject, whose stated remedy is to change the
    ///      environment, which cannot help.
    function test_R50_134_aRecordForAnotherChainIsRefusedAsSuch() public {
        Deployed memory live = _generation();
        script.setRecord(_recordFor(live, BASE_MAINNET, owner));
        _installEnv(live);

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.RecordChainMismatch.selector, BASE_MAINNET, BASE_SEPOLIA)
        );
        script.exposedResolveDeployed();
    }

    /// @notice Local chains keep the environment-only path, explicitly.
    /// @dev Anvil has no committed deployment and never will: every rehearsal builds its own graph
    ///      in memory. Stated as a test rather than as a comment because it is the one exception,
    ///      and an exception nothing exercises is an exception somebody deletes.
    function test_R50_134_localChainsStillResolveFromTheEnvironmentAlone() public {
        vm.chainId(ANVIL_CHAIN_ID);
        Deployed memory live = _generation();
        _installEnv(live);

        Deployed memory got = script.exposedResolveDeployed();
        assertEq(address(got.credit), address(live.credit), "local runs need no record");

        // And the missing address is still named on that path, so nothing was lost by keeping it.
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(0));
        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressMissing.selector, "RECOUP_NAV_ORACLE")
        );
        script.exposedResolveDeployed();
    }

    // ── the owner ────────────────────────────────────────────────────────────

    /// @notice `RECOUP_OWNER` is held to the record too, and a disagreement is named as one.
    /// @dev It is the address every census in `DeployBase` compares the CHAIN against, so an
    ///      environment naming the wrong owner does not fail - it makes `_assertCoreGraph` report
    ///      an `OwnershipNotTransferred` that names the real, correct owner. That is the exact
    ///      shape `assertOnly`'s `OwnerNotNamedForReport` was added for one variable over: a health
    ///      report inventing a wiring failure out of the environment.
    function test_R50_134_theOwnerIsHeldToTheRecordAsWell() public {
        Deployed memory live = _generation();
        address stranger = makeAddr("r50.134.strangerOwner");
        script.setRecord(_recordFor(live, BASE_SEPOLIA, owner));

        script.setEnvAddress("RECOUP_OWNER", stranger);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);

        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector, "RECOUP_OWNER", stranger, owner
            )
        );
        script.exposedResolveParamsAgainstRecord(address(this));

        // Control: the recorded owner resolves, and the other four still come from the environment.
        script.setEnvAddress("RECOUP_OWNER", owner);
        GovParams memory p = script.exposedResolveParamsAgainstRecord(address(this));
        assertEq(p.owner, owner, "control: an agreeing owner resolves");
        assertEq(p.keeper, keeper, "control: and the operators are still the environment's");
    }

    // ── the timelock ─────────────────────────────────────────────────────────

    /// @dev A timelock that holds code and answers `getMinDelay()`, which is what round 53's probe
    ///      in `_requiredTimelock` asks of any address named as one. Proposers and executors are
    ///      irrelevant here: nothing is scheduled, only resolved.
    function _realTimelock() internal returns (TimelockController t) {
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    /// @notice `RECOUP_TIMELOCK` is NOT held to the record, because the record holds no timelock -
    ///         and it becomes binding the day one is added, without anybody remembering to.
    /// @dev 🟥 **Stated as a test rather than as a comment, because "we checked ten of eleven" is
    ///      exactly the half-statement this repository keeps re-finding.** `operators` in the live
    ///      record carries `owner`, `yieldRecipient`, `keeper`, `navConfirmer` and
    ///      `protocolFeeWallet`. The deployment it describes is owned by an EOA, so there is no
    ///      timelock to record; the row appears at the G2 handover and not before. The key lookup
    ///      in `_requiredTimelock` is what makes the row binding on the day it lands, and both arms
    ///      of it are exercised here so neither can rot silently.
    ///
    ///      Round 53: the two timelocks are real `TimelockController`s rather than `makeAddr`
    ///      literals, because `_requiredTimelock` now refuses a codeless address as
    ///      `DeployedAddressHasNoCode("RECOUP_TIMELOCK", t)` and one that does not answer
    ///      `getMinDelay()` as `TimelockDoesNotAnswer(t)`, after the record check this test is about.
    function test_R50_134_theTimelockIsCheckedOnlyOnceTheRecordCarriesOne() public {
        Deployed memory live = _generation();
        address envTimelock = address(_realTimelock());
        address recordTimelock = address(_realTimelock());

        // Arm one: today's record shape. No `operators.timelock`, so the environment stands alone.
        script.setRecord(_recordFor(live, BASE_SEPOLIA, owner));
        script.setEnvAddress("RECOUP_TIMELOCK", envTimelock);
        assertEq(
            script.exposedRequiredTimelock(),
            envTimelock,
            "with no recorded timelock the environment is the only source there is"
        );

        // Arm two: the record after G2. The same environment value is now a disagreement.
        script.setRecord(
            string.concat(
                '{"chainId":',
                vm.toString(BASE_SEPOLIA),
                ',"operators":{"owner":"',
                vm.toString(owner),
                '","timelock":"',
                vm.toString(recordTimelock),
                '"},"contracts":{}}'
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector,
                "RECOUP_TIMELOCK",
                envTimelock,
                recordTimelock
            )
        );
        script.exposedRequiredTimelock();

        // And the agreeing value passes, so arm two is a check rather than a wall.
        script.setEnvAddress("RECOUP_TIMELOCK", recordTimelock);
        assertEq(script.exposedRequiredTimelock(), recordTimelock, "an agreeing timelock resolves");
    }
}
