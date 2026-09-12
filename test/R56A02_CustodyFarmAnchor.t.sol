// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R56A02 - round-56 item 131: `setCustodyAdapter` has no farm anchor (PINS-OPEN)
/// @notice Audit round 56, agent A2. `CollateralVault.setCustodyAdapter` has no contract-side
///         mirror of the deploy-time `adapter.farm() == bond.rewardPool()` anchor, so an adapter
///         built on a FOREIGN farm installs, takes deposits into that farm, and
///         `custodyIsSolvent()` reads true over a yield stream the harvester never sees.
///
/// @dev 🟥 **The `pin_` tests below PIN AN OPEN STATE and say so: a farm anchor on
///      `setCustodyAdapter` must turn them red.** A2 BUILT and SIGN-CHECKED the anchor as a candidate
///      (commit `4985f7c`, `AdapterFarmMismatch(adapterFarm, rewardPool)` after round 55's insolvency
///      clause, CollateralVault +257 runtime / +264 initcode on a clean `out/`), and on 2026-09-10
///      Chris decided it does NOT ship: item 131 is CARRIED, not built. The candidate's diff is
///      preserved in the round-56 bundle as `diffs/A2-item131-candidate-4985f7c.patch`.
///
///      **Why it was not shipped is the `pin_aDexFiPoolMove...` case.** The anchor reads
///      `bond.rewardPool()`, which DexFi's owner EOA can move: after such a move every adapter on the
///      farm the protocol's bonds actually sit in is refused, the break-glass repair included, and
///      with the pool set to zero no adapter can ever be installed. It also broke four existing
///      complete-for-their-probes adapter stubs and flipped one Deploy pin, all of which are green
///      again on this tree without edits.
///
///      The `control_` and `negative_` cases are green on this tree and would stay green under the
///      candidate. Installing a foreign-farm adapter is an owner act, so the severity is Info and
///      the DexFi-mutable read is the decision; a green run of this file is not a clearance.
contract R56A02_CustodyFarmAnchor is Test {
    uint256 internal constant NAV = 25.15e8;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockFarm internal foreignFarm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    RiskParams internal riskParams;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        foreignFarm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);
        riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            admin
        );
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(foreignFarm), true);
        bond.mint(alice, 1_000);
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);
    }

    function _adapterOn(MockFarm f) internal returns (DirectCallAdapter a) {
        a = new DirectCallAdapter(IDexFiBond(address(bond)), IDexFiFarm(address(f)), usdc, address(vault), admin, yieldSink);
        bond.setWhitelisted(address(a), true);
    }

    function _staked(MockFarm f, address who) internal view returns (uint256 amount) {
        (amount,) = f.userInfo(who);
    }

    function _install(DirectCallAdapter a) internal returns (bool ok, bytes memory ret) {
        vm.prank(admin);
        (ok, ret) = address(vault).call(abi.encodeCall(vault.setCustodyAdapter, (ICustodyAdapter(address(a)))));
    }

    // ── CONTROL ──────────────────────────────────────────────────────────────

    /// @notice CONTROL. The genuine adapter, on the bond's reward pool, installs and custody works.
    function test_R56A02_131_control_theRewardPoolAdapterInstalls() public {
        DirectCallAdapter a = _adapterOn(farm);
        (bool ok,) = _install(a);
        assertTrue(ok, "the genuine adapter was refused");
        vm.prank(alice);
        vault.depositBonds(50);
        assertEq(_staked(farm, address(a)), 50, "the deposit did not reach the reward pool");
        assertTrue(vault.custodyIsSolvent(), "custody reads insolvent");
    }

    // ── PINS: the open state ─────────────────────────────────────────────────

    /// @notice PINS AN OPEN STATE. An adapter built on a foreign farm INSTALLS, takes a 50-bond
    ///         deposit into the foreign farm (reward-pool stake 0), and `custodyIsSolvent()` reads
    ///         true - the row as measured at `73b474a` and again at `8ab4d88`. Under the anchor it is
    ///         refused `AdapterFarmMismatch(foreignFarm, rewardPool)` and this goes red.
    function test_R56A02_131_pin_aForeignFarmAdapterInstallsAndReadsSolvent() public {
        DirectCallAdapter a = _adapterOn(foreignFarm);
        (bool ok,) = _install(a);
        assertTrue(ok, "a foreign-farm adapter was refused: the anchor has shipped, retire this pin");
        vm.prank(alice);
        vault.depositBonds(50);
        assertEq(_staked(foreignFarm, address(a)), 50, "the deposit did not reach the foreign farm");
        assertEq(_staked(farm, address(a)), 0, "the reward pool holds a stake it should not");
        assertTrue(vault.custodyIsSolvent(), "custody read insolvent over the foreign farm");
    }

    /// @notice PINS AN OPEN STATE, composed with #491's `CustodyWouldBeInsolvent` on the same setter.
    ///         A PRE-STAKED repair adapter (the one repair round 55 admits) built on the foreign farm
    ///         installs after the break-glass hatch. Under the anchor it is refused by name.
    function test_R56A02_131_pin_aPreStakedRepairOnTheWrongFarmInstalls() public {
        DirectCallAdapter live = _adapterOn(farm);
        _install(live);
        vm.prank(alice);
        vault.depositBonds(50);
        vm.prank(admin);
        live.emergencyUnstake(admin);

        DirectCallAdapter wrongRepair = _adapterOn(foreignFarm);
        foreignFarm.seedStakeFor(address(wrongRepair), 50);
        (bool ok,) = _install(wrongRepair);
        assertTrue(ok, "a pre-staked repair on the foreign farm was refused: the anchor has shipped");
        assertTrue(vault.custodyIsSolvent(), "custody read insolvent over the foreign-farm repair");
        assertEq(_staked(farm, address(wrongRepair)), 0, "the reward pool holds a stake it should not");
    }

    /// @notice PINS AN OPEN STATE. An adapter with no `farm()` at all installs over an empty ledger:
    ///         it answers the two probed views (`vault()`, `stakedBalance()`) and nothing asks for a
    ///         third. Under the anchor it is refused `AdapterDoesNotAnswer(farm())`.
    function test_R56A02_131_pin_anAdapterWithoutFarmInstalls() public {
        NoFarmAdapter a = new NoFarmAdapter(address(vault));
        vm.prank(admin);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.setCustodyAdapter, (ICustodyAdapter(address(a)))));
        assertTrue(ok, "an adapter without farm() was refused: the anchor has shipped");
        assertEq(address(vault.custodyAdapter()), address(a), "the pointer did not move");
    }

    /// @notice PINS AN OPEN STATE, and it is the reason the anchor did not ship. After DexFi's owner
    ///         EOA moves `bond.rewardPool()`, a pre-staked repair on the farm the protocol's bonds are
    ///         actually in is still admitted, and so it is with the pool set to zero. MEASURED under
    ///         the `4985f7c` candidate: both installs are refused, so a DexFi-mutable read would sit
    ///         on the owner's only custody door, the break-glass repair included.
    function test_R56A02_131_pin_aDexFiPoolMoveDoesNotRefuseTheRepair() public {
        DirectCallAdapter live = _adapterOn(farm);
        _install(live);
        vm.prank(alice);
        vault.depositBonds(50);
        vm.prank(admin);
        live.emergencyUnstake(admin);

        DirectCallAdapter repair = _adapterOn(farm);
        farm.seedStakeFor(address(repair), 50);

        MockFarm newPool = new MockFarm(bond, usdc);
        bond.setRewardPool(address(newPool));
        uint256 snap = vm.snapshotState();
        (bool ok,) = _install(repair);
        assertTrue(ok, "the repair on the old farm was refused after a DexFi pool move");
        vm.revertToState(snap);

        bond.setRewardPool(address(0));
        (bool ok0,) = _install(repair);
        assertTrue(ok0, "the repair was refused with rewardPool = 0");
    }

    // ── NEGATIVE: the composition order ──────────────────────────────────────

    /// @notice NEGATIVE, order. An EMPTY foreign-farm adapter over a non-empty ledger is named
    ///         `CustodyWouldBeInsolvent` (#491). The candidate anchor sat after that clause, so it
    ///         would not have renamed this refusal either; green on this tree and under the candidate.
    function test_R56A02_131_negative_insolvencyIsStillNamedFirst() public {
        DirectCallAdapter live = _adapterOn(farm);
        _install(live);
        vm.prank(alice);
        vault.depositBonds(50);
        vm.prank(admin);
        live.emergencyUnstake(admin);
        DirectCallAdapter emptyForeign = _adapterOn(foreignFarm);
        (bool ok, bytes memory ret) = _install(emptyForeign);
        assertFalse(ok, "installed");
        assertEq(
            keccak256(ret),
            keccak256(abi.encodeWithSelector(CollateralVault.CustodyWouldBeInsolvent.selector, uint256(0), uint256(50))),
            "the insolvency refusal changed name or figures"
        );
    }
}

/// @dev Answers `vault()` and `stakedBalance()` and nothing else.
contract NoFarmAdapter {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function stakedBalance() external pure returns (uint256) {
        return 0;
    }
}
