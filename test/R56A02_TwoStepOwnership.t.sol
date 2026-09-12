// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";

/// @title R56A02 - round-56 item 75: what a two-step ownership transfer costs the governance path
/// @notice Audit round 56, agent A2. COST ONLY; nothing here ships. Tree-agnostic on purpose: every
///         two-step member is reached through a low-level call, so the file compiles and runs on the
///         one-step tree (`8ab4d88`) and on a temporary `Ownable2Step` variant of `CollateralVault`,
///         and the same assertions report what each tree does.
///
///         Three questions: (1) does the G2 handover to a `TimelockController` still complete under
///         two-step, and what does it cost; (2) is `transferOwnership(0xdEaD)` still the terminal
///         state the tree relies on in place of `renounceOwnership`; (3) does the owner/guardian
///         separation (`GuardianMustDifferFromOwner`) survive a pending owner. The third is the one a
///         bare base-class swap BREAKS - see `test_R56A02_75_invariant_ownerIsNeverTheGuardian`.
contract R56A02_TwoStepOwnership is Test {
    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal successor = makeAddr("successor");

    CollateralVault internal vault;
    TimelockController internal timelock;

    function setUp() public {
        MockBond bond = new MockBond();
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
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    function _isTwoStep() internal view returns (bool) {
        (bool ok, bytes memory ret) = address(vault).staticcall(abi.encodeWithSignature("pendingOwner()"));
        return ok && ret.length == 32;
    }

    /// @notice (1) The G2 handover completes on either tree. One-step: one EOA call, effective at
    ///         once. Two-step: the EOA call makes the timelock PENDING, and the timelock must then
    ///         run `acceptOwnership()` as its own scheduled operation - one more proposal and one
    ///         more `ADMIN_TIMELOCK` (48 h), during which the EOA is STILL the owner.
    function test_R56A02_75_handover_theTimelockCanAcceptUnderEitherTree() public {
        uint256 t0 = block.timestamp;
        vm.prank(admin);
        vault.transferOwnership(address(timelock));
        uint256 extraOps;
        if (vault.owner() != address(timelock)) {
            assertTrue(_isTwoStep(), "one-step tree did not hand over at once");
            assertEq(vault.owner(), admin, "two-step: the EOA should still own during the pending window");
            bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
            vm.prank(proposer);
            timelock.schedule(address(vault), 0, accept, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
            skip(Config.ADMIN_TIMELOCK);
            timelock.execute(address(vault), 0, accept, bytes32(0), bytes32(0));
            extraOps = 1;
        }
        emit log_named_uint("MEASURED two-step tree (1 = yes)", _isTwoStep() ? 1 : 0);
        emit log_named_uint("MEASURED extra timelock operations", extraOps);
        emit log_named_uint("MEASURED seconds from transfer to effective ownership", block.timestamp - t0);
        assertEq(vault.owner(), address(timelock), "the timelock does not own the vault");
    }

    /// @notice (2) The terminal state. One-step: `transferOwnership(0xdEaD)` is final. Two-step: it
    ///         only makes `0xdEaD` pending, the owner keeps every power, and nothing can accept -
    ///         so the tree's substitute for `renounceOwnership` stops existing.
    function test_R56A02_75_terminal_theDeadTransferUnderEitherTree() public {
        vm.prank(admin);
        vault.transferOwnership(address(0xdEaD));
        emit log_named_uint("MEASURED two-step tree (1 = yes)", _isTwoStep() ? 1 : 0);
        emit log_named_address("MEASURED owner after transferOwnership(0xdEaD)", vault.owner());
        if (_isTwoStep()) assertEq(vault.owner(), admin, "two-step: the dead transfer took effect");
        else assertEq(vault.owner(), address(0xdEaD), "one-step: the dead transfer did not take effect");
    }

    /// @notice (3) The owner is never the guardian, across a handover. Holds on the one-step tree
    ///         (`transferOwnership` refuses the sitting guardian, and a new owner cannot be made
    ///         guardian because `setGuardian` refuses `owner()`). Under a BARE `Ownable2Step` swap the
    ///         sitting owner names X pending, then makes X guardian (X is not yet `owner()`, so
    ///         `setGuardian` admits it), and X accepts: owner == guardian, the configuration
    ///         `GuardianMustDifferFromOwner` exists to refuse.
    function test_R56A02_75_invariant_ownerIsNeverTheGuardian() public {
        vm.prank(admin);
        vault.transferOwnership(successor);
        vm.prank(admin);
        (bool setOk,) = address(vault).call(abi.encodeCall(vault.setGuardian, (successor)));
        vm.prank(successor);
        (bool accOk,) = address(vault).call(abi.encodeWithSignature("acceptOwnership()"));
        emit log_named_uint("MEASURED two-step tree (1 = yes)", _isTwoStep() ? 1 : 0);
        emit log_named_uint("MEASURED setGuardian(pending owner) admitted (1 = yes)", setOk ? 1 : 0);
        emit log_named_uint("MEASURED acceptOwnership by the guardian admitted (1 = yes)", accOk ? 1 : 0);
        assertFalse(
            vault.owner() == successor && vault.guardian() == successor,
            "owner == guardian: the separation did not survive the pending window"
        );
    }
}
