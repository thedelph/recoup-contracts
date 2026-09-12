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

/// @title R56A02 - OFF-LIST: #491's `CustodyWouldBeInsolvent` versus round 21's `_outgoingStake` escape
/// @notice Audit round 56, agent A2, target 8 (read #491 adversarially for an owner who must repoint in
///         an emergency). `CollateralVault._outgoingStake` CATCHES a reverting `stakedBalance()` on the
///         outgoing adapter, and its docstring says why: "an adapter that genuinely holds a position,
///         whose farm is down, reads as idle and can be repointed away from. What it buys is the
///         repoint being possible at all". Round 55's clause `incoming < totalBondCount` now refuses
///         exactly that repoint whenever the ledger is non-empty, so the catch buys nothing in the
///         state it was written for; only a PRE-STAKED repair adapter passes, and `DirectCallAdapter`
///         cannot be pre-staked (`stake` is `onlyVault`).
///
/// @dev 🟥 **PINS-OPEN: `pin_` asserts the CURRENT behaviour (the repoint is refused by name while the
///      farm is down under a live position). A green run is not a clearance of anything; it is the
///      record that the round-21 escape and the round-55 clause disagree in this state, which is a
///      decision (the round-55 argument - an empty adapter over a non-empty ledger strands every exit -
///      may well be the right one) and a docstring that must say so.**
contract R56A02_DeadFarmRepoint is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        MockNavOracle oracle = new MockNavOracle(25.15e8);
        RiskParams rp = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            admin
        );
        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(rp)), admin);
        adapter = _adapter();
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        bond.setWhitelisted(address(farm), true);
        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(100);
        vm.stopPrank();
    }

    function _adapter() internal returns (DirectCallAdapter a) {
        a = new DirectCallAdapter(IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink);
        bond.setWhitelisted(address(a), true);
    }

    /// @dev The farm goes down under the LIVE adapter only: its `userInfo` read reverts, so the live
    ///      adapter's `stakedBalance()` reverts, exactly the state `_outgoingStake` catches.
    function _farmDownUnderTheLiveAdapter() internal {
        vm.mockCallRevert(address(farm), abi.encodeCall(IDexFiFarm.userInfo, (address(adapter))), "farm down");
        vm.expectRevert();
        adapter.stakedBalance();
    }

    /// @notice CONTROL. With an EMPTY ledger the catch does what its docstring says: a repoint away
    ///         from an adapter that cannot answer succeeds.
    function test_R56A02_off_control_anEmptyLedgerStillRepointsAwayFromADeadFarm() public {
        vm.prank(alice);
        vault.withdrawBonds(100);
        _farmDownUnderTheLiveAdapter();
        DirectCallAdapter fresh = _adapter();
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));
        assertEq(address(vault.custodyAdapter()), address(fresh), "the empty-ledger escape is closed");
    }

    /// @notice PIN (open, a decision). With a LIVE position under the dead farm, the round-21 catch
    ///         reads the outgoing stake as 0 and the round-55 clause then refuses the fresh adapter by
    ///         name: `CustodyWouldBeInsolvent(0, 100)`. Before #491 (`6b25ab2^`) this repoint was
    ///         admitted. `custodyIsSolvent()` meanwhile REVERTS (bare `stakedBalance()`), so every
    ///         `borrow` reverts for as long as the farm is down.
    function test_R56A02_off_pin_aLivePositionUnderADeadFarmCannotBeRepointedAway() public {
        _farmDownUnderTheLiveAdapter();
        DirectCallAdapter fresh = _adapter();
        vm.prank(admin);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(vault.setCustodyAdapter, (ICustodyAdapter(address(fresh)))));
        emit log_named_uint("MEASURED repoint away from the dead farm admitted (1 = yes)", ok ? 1 : 0);
        emit log_named_bytes("MEASURED refusal", ret);
        assertFalse(ok, "PINS-OPEN: the repoint is admitted again, re-read this pin and the docstrings");
        assertEq(
            keccak256(ret),
            keccak256(abi.encodeWithSelector(CollateralVault.CustodyWouldBeInsolvent.selector, uint256(0), uint256(100))),
            "refused, but not by the round-55 clause"
        );
        vm.expectRevert();
        vault.custodyIsSolvent();
    }

    /// @notice NEGATIVE. When the farm comes back the live adapter works again untouched, so the
    ///         refusal cost nothing permanent in this state: alice withdraws all 100.
    function test_R56A02_off_negative_theFarmRecoveringRestoresEverything() public {
        _farmDownUnderTheLiveAdapter();
        vm.clearMockedCalls();
        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(vault.bondCount(alice), 0, "alice could not withdraw after the farm recovered");
    }
}
