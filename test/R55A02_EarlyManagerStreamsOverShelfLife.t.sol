// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R55A02 - a manager deployed early streams its first epoch over its whole shelf life
/// @notice Round-55 item 222, REPORT ONLY: `CreditManager` is frozen. The constructor stamps
///         `lastDistributeAt` at deployment and `distributeYield` sizes a stream as
///         `max(elapsed, YIELD_STREAM_DURATION, remaining)`, so a spare deployed 45 days before its
///         first epoch streams that epoch over 45 days, and - because a running stream is never
///         shortened - every later epoch re-rates the whole pot over what is left of those 45 days.
///
/// @dev MEASURED, green on both trees. The deploy-order mitigation and its two facts: deploy a
///      manager in the transaction sequence that wires it (DeployBase does; elapsed is seconds and
///      the stream is the five-day floor), and deploy a migration SPARE at migration time rather
///      than in advance. There is no owner lever: `lastDistributeAt` has no setter and a zero-pot
///      `distributeYield` returns before writing it.
contract R55A02_EarlyManagerStreamsOverShelfLife is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant SHELF = 45 days;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    function setUp() public {
        vm.warp(1_788_500_000);
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
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
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        treasury = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(100);
        vm.stopPrank();
    }

    function _newManager() internal returns (CreditManager m) {
        m = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        vm.startPrank(admin);
        m.setEpochHarvester(address(this));
        m.setLiquiditySource(address(treasury));
        vm.stopPrank();
    }

    function _attach(CreditManager m) internal {
        vm.prank(admin);
        vault.setCreditManager(address(m));
    }

    function _stream(CreditManager m, uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(m), amount);
        m.receiveYield(amount);
        m.distributeYield(amount);
    }

    function test_R55A02_222_measure_aSpareDeployedEarlyStreamsOverItsShelfLifeAndNeverRecovers() public {
        CreditManager early = _newManager();
        uint256 deployedAt = block.timestamp;
        vm.warp(deployedAt + SHELF);
        _attach(early);

        // No lever: a zero-pot distribute returns before the stamp moves.
        early.distributeYield(0);
        assertEq(early.lastDistributeAt(), deployedAt, "a zero-pot distributeYield does not re-stamp");

        _stream(early, EPOCH);
        uint256 window1 = early.streamEndsAt() - block.timestamp;
        emit log_named_uint("first epoch window on a 45-day-old spare (s)", window1);
        assertEq(window1, SHELF, "streams over the whole shelf life");

        // Five days later a second, ordinary epoch: the tail is never shortened, so the WHOLE pot
        // (old tail plus new money) is re-rated over what is left of the 45 days.
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION);
        uint256 endsBefore = early.streamEndsAt();
        _stream(early, EPOCH);
        emit log_named_uint("second epoch window (s)", early.streamEndsAt() - block.timestamp);
        assertEq(early.streamEndsAt(), endsBefore, "the throttle decays only with the calendar");
        assertEq(early.streamEndsAt() - block.timestamp, SHELF - Config.YIELD_STREAM_DURATION);
    }

    /// @notice The mitigation: a manager deployed in the block it is attached gets the floor.
    function test_R55A02_222_mitigation_deployTheSpareAtMigrationTime() public {
        CreditManager early = _newManager();
        vm.warp(block.timestamp + SHELF);
        _attach(early);
        CreditManager late = _newManager(); // deployed now, attached now
        _attach(late);
        _stream(late, EPOCH);
        uint256 window = late.streamEndsAt() - block.timestamp;
        emit log_named_uint("first epoch window on a just-deployed spare (s)", window);
        assertEq(window, Config.YIELD_STREAM_DURATION, "the five-day floor");
    }
}
