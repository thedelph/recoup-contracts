// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice `WirePhase4` with both environment seams and the record seam closed.
/// @dev Hermetic on the environment (return the fallback, never `super`) and on the record (an
///      inline string), the same construction `R50WirePhase4Record.t.sol` uses. The string seam is
///      settable as well as the address seam, because the three broadcast entry points are gated on
///      `RECOUP_SWITCHOVER_CONFIRM`.
contract R51A01Script is WirePhase4 {
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

    /// @dev `vm.expectRevert` reaches one call depth below the cheatcode and `_resolveParamsAgainstRecord`
    ///      is internal, so the deadlock arm needs a boundary of its own.
    function exposedResolveParamsAgainstRecord(address sender) external view returns (GovParams memory) {
        return _resolveParamsAgainstRecord(sender);
    }
}

/// @notice Round-51 item 144. `WirePhase4.assertOnly()` reads its parameters with `_readParams`, so
///         NONE of `_validateParams`' rules runs on the health-report path, and until this round
///         `_assertCoreGraph` re-derived exactly ONE of them from the chain - the guardian/owner
///         collapse. The three NAV-key rules were re-derived by nothing.
///
/// @dev Every claim in this file is MEASURED. The state is reached with `vm.store` on the oracle's
///      slot 1 and slot 2 (`forge inspect NAVOracle storage-layout`: `Ownable._owner` 0, `keeper` 1,
///      `navConfirmer` 2) because no sequence of oracle transactions reaches it - which is the point
///      of the control below, and the reason this is defence in depth rather than a live hole.
///
///      **The fix is three clauses in `DeployBase._assertCoreGraph`, anchored on the chain rather
///      than on `GovParams`.** Comparing `p.keeper` with `p.navConfirmer` would restate
///      `_validateParams` one indirection away, and this path exists precisely because `p` is
///      whatever the operator typed. Zero runtime bytes: `DeployBase` is a script.
contract R51A01HealthReportTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;

    /// @dev `forge inspect NAVOracle storage-layout`: `_owner` 0, `keeper` 1, `navConfirmer` 2.
    bytes32 internal constant KEEPER_SLOT = bytes32(uint256(1));
    bytes32 internal constant CONFIRMER_SLOT = bytes32(uint256(2));

    address internal treasury = makeAddr("r51a01.treasury");
    address internal feeWallet = makeAddr("r51a01.feeWallet");
    address internal keeper = makeAddr("r51a01.keeper");
    address internal navConfirmer = makeAddr("r51a01.navConfirmer");
    address internal guardian = makeAddr("r51a01.guardian");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    R51A01Script internal script;

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
        script = new R51A01Script();
    }

    function _externals() internal view returns (Externals memory) {
        return Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });
    }

    function _params(address owner_, address fee_) internal view returns (GovParams memory) {
        return GovParams({
            owner: owner_,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: fee_,
            guardian: guardian
        });
    }

    /// @dev A deployment made by this contract, switched over, still owned by this contract. The
    ///      guardian is named because `_validateNewDeployment` refuses a contract owner without one
    ///      off the local chain, and this file runs at 84532 on purpose.
    function _switchedOver() internal returns (Deployed memory d) {
        d = _deployProtocol(_externals(), _params(address(this), feeWallet), address(this));
        _wirePhase4(d);
        _assertPhase4Wiring(d, _params(address(this), feeWallet));
    }

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

    function _installEnv(Deployed memory d, address owner_, address fee_) internal {
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
        script.setEnvAddress("RECOUP_KEEPER", d.oracle.keeper());
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", d.oracle.navConfirmer());
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", fee_);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        script.setRecord(_recordFor(d, owner_));
    }

    // ── round-51 item 144: the three key rules, now re-derived from the chain ──

    /// @notice THE FINDING, flipped. Before the fix `assertOnly()` reported "Phase-4 wiring holds"
    ///         over an oracle whose two keys are one key; it now refuses by name.
    /// @dev MEASURED. `RECOUP_KEEPER` and `RECOUP_NAV_CONFIRMER` are installed from the oracle's own
    ///      reads AFTER the store, so `oracle.keeper() != p.keeper` above the new block passes and
    ///      the refusal is the new clause rather than the old one.
    function test_R51A01_144_theKeyCensusRefusesACollapsedNavKeyPair() public {
        Deployed memory d = _switchedOver();

        // The collapse, by storage, because no transaction can produce it.
        vm.store(address(d.oracle), KEEPER_SLOT, bytes32(uint256(uint160(navConfirmer))));
        assertEq(d.oracle.keeper(), d.oracle.navConfirmer(), "premise: the two keys are one key");

        _installEnv(d, address(this), feeWallet);

        vm.expectRevert(DeployBase.NavKeysMustDiffer.selector);
        script.assertOnly();
    }

    /// @notice The owner half of the same census: the oracle's owner IS the keeper.
    /// @dev Written as its own test because the three clauses are separate and one test would let
    ///      two of them pass on the third's evidence.
    function test_R51A01_144_theKeyCensusRefusesAKeeperThatIsTheOwner() public {
        Deployed memory d = _switchedOver();
        vm.store(address(d.oracle), KEEPER_SLOT, bytes32(uint256(uint160(address(this)))));
        assertEq(d.oracle.keeper(), d.oracle.owner(), "premise: the keeper is the owner");

        _installEnv(d, address(this), feeWallet);

        vm.expectRevert(DeployBase.KeeperMustDifferFromOwner.selector);
        script.assertOnly();
    }

    /// @notice The third clause, which is the one PRD §9's two-key guard is actually about: the key
    ///         that CONFIRMS a NAV move is the key that owns the graph.
    function test_R51A01_144_theKeyCensusRefusesAConfirmerThatIsTheOwner() public {
        Deployed memory d = _switchedOver();
        vm.store(address(d.oracle), CONFIRMER_SLOT, bytes32(uint256(uint160(address(this)))));
        assertEq(d.oracle.navConfirmer(), d.oracle.owner(), "premise: the confirmer is the owner");

        _installEnv(d, address(this), feeWallet);

        vm.expectRevert(DeployBase.NavConfirmerMustDifferFromOwner.selector);
        script.assertOnly();
    }

    /// @notice Control: the shipped `NAVOracle` refuses every door into that state, which is why
    ///         item 144 is defence in depth rather than a live hole - and why the three tests above
    ///         need `vm.store` at all.
    function test_R51A01_144_control_theOracleItselfRefusesEveryDoorIntoTheCollapse() public {
        Deployed memory d = _switchedOver();

        vm.expectRevert(NAVOracle.KeysMustDiffer.selector);
        d.oracle.setKeeper(navConfirmer);

        vm.expectRevert(NAVOracle.KeysMustDiffer.selector);
        d.oracle.setNavConfirmer(keeper);

        vm.expectRevert(NAVOracle.KeysMustDiffer.selector);
        d.oracle.setKeeper(address(this));

        vm.expectRevert(NAVOracle.KeysMustDiffer.selector);
        d.oracle.setNavConfirmer(address(this));

        vm.expectRevert(NAVOracle.KeysMustDiffer.selector);
        d.oracle.transferOwnership(keeper);
    }

    /// @notice Control for the fix: a healthy graph still passes, so the three clauses are not a
    ///         refusal of everything.
    function test_R51A01_144_control_ahealthyGraphPassesTheHealthReport() public {
        Deployed memory d = _switchedOver();
        _installEnv(d, address(this), feeWallet);
        script.assertOnly();
    }

    // ── the fee-wallet deadlock, and the clause move that clears it ───────────

    /// @notice THE OTHER FINDING, and this one needed no `vm.store`. A deployment whose protocol fee
    ///         wallet is its own owner used to pass the health report and be REFUSED by every
    ///         broadcast entry point, on a value neither side could change without the other
    ///         breaking. Both directions are asserted here now.
    /// @dev MEASURED. `EpochHarvester.setProtocolFeeWallet` refuses only `address(0)`, so this is
    ///      ONE ordinary owner transaction on a live deployment - and routing the protocol fee to
    ///      the governance Safe that owns the graph is a normal thing for an operator to do.
    ///
    ///      The two constraints, as they stood before this round:
    ///        - `_assertCoreGraph`: `harvester.protocolFeeWallet() != p.protocolFeeWallet` reverts,
    ///          so the environment MUST name the owner.
    ///        - `_validateParams`: `p.protocolFeeWallet == p.owner` reverted
    ///          `ProtocolFeeWalletCollision`, so the environment must NOT name the owner.
    ///
    ///      No value of one variable satisfies two constraints that disagree. Round 38 fixed exactly
    ///      this shape for the guardian rule by moving that rule out of `_validateParams` into
    ///      `_validateNewDeployment`; the four collision clauses are the same class of rule - they
    ///      are about the moment a deployment is MADE - and were left behind. They have moved.
    function test_R51A01_170_aFeeWalletThatIsTheOwnerNoLongerDeadlocksTheSwitchover() public {
        TimelockController timelock = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _params(address(this), feeWallet), address(this));
        _wirePhase4(d);

        // One owner transaction, refused by nothing in `src/`.
        d.harvester.setProtocolFeeWallet(address(timelock));
        assertEq(d.harvester.protocolFeeWallet(), address(timelock), "premise: the fee wallet is the incoming owner");

        _handOver(d, address(timelock));
        _installEnv(d, address(timelock), address(timelock));

        // The health report is happy, and `_assertCoreGraph` requires exactly this environment.
        script.assertOnly();

        // And the broadcast entry points now accept the environment the health report requires.
        GovParams memory p = script.exposedResolveParamsAgainstRecord(address(this));
        assertEq(p.protocolFeeWallet, address(timelock), "the resolution the collision clause used to refuse");
        assertEq(p.owner, address(timelock), "and it is the owner, which is the whole point");
    }

    /// @notice The amplifier, executed end to end. `queuePause()` skips `_resolveParams`, so the
    ///         operator shut `borrow` and `depositETH` FIRST and met the wall afterwards - with the
    ///         only scripted `unpause` inside the batch `queue()` would not build. The whole
    ///         ceremony now completes.
    /// @dev MEASURED. The neuter for this test is putting the four clauses back in
    ///      `_validateParams`: `queue()` then reverts
    ///      `ProtocolFeeWalletCollision(timelock, "owner")` with the protocol left paused.
    function test_R51A01_170_theWholeCeremonyCompletesWithTheFeeWalletAtTheOwner() public {
        TimelockController timelock = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _params(address(this), feeWallet), address(this));
        d.harvester.setProtocolFeeWallet(address(timelock));
        _handOver(d, address(timelock));
        _installEnv(d, address(timelock), address(timelock));
        script.setEnvAddress("RECOUP_TIMELOCK", address(timelock));

        script.queuePause();
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.executeQueuedPause();
        assertTrue(d.credit.paused(), "the book is shut");
        assertTrue(d.vault.paused(), "and so is depositETH");

        // Step two, which used to be unbuildable.
        script.queue();
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.executeQueued();

        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool funds the book");
        assertEq(d.harvester.lenderPool(), address(d.pool), "and is paid for carrying it");
        assertFalse(d.credit.paused(), "and the doors are open again");
        script.assertOnly();
    }

    /// @notice Control: move the fee wallet one address off the owner and the identical ceremony
    ///         completes, so the test above is measuring the collision clause and not the fixture.
    function test_R51A01_170_control_aDistinctFeeWalletQueuesAndExecutes() public {
        TimelockController timelock = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _params(address(this), feeWallet), address(this));
        _handOver(d, address(timelock));
        _installEnv(d, address(timelock), feeWallet);
        script.setEnvAddress("RECOUP_TIMELOCK", address(timelock));

        script.queuePause();
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.executeQueuedPause();
        script.queue();
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.executeQueued();

        assertEq(d.credit.liquiditySource(), address(d.pool), "control: the switchover completed");
        assertFalse(d.credit.paused(), "control: and the doors are open again");
    }

    /// @dev Both this contract and the broadcast sender hold `PROPOSER_ROLE`, for the reason
    ///      `R50WirePhase4PauseTargets.t.sol` states: the guard reads `msg.sender` and the schedule
    ///      is then broadcast from `DEFAULT_SENDER`.
    function _timelock() internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }
}
