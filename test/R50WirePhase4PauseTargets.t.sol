// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {Config} from "../src/Config.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev The `ExposedWirePhase4` construction under this file's own name, so this file inherits no
///      other suite. Hermetic: both environment seams return their fallback and never `super`.
contract R50PauseTargetsExposed is WirePhase4 {
    /// @dev Round 57 (round-57 item 131, audit agent A6): the salt seam, hermetic, so a
    ///      `RECOUP_SWITCHOVER_ATTEMPT` in this box's `contracts/.env` cannot decide a case the day a
    ///      test here reaches `queuePause()` or `executeQueuedPause()`.
    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue) internal pure override returns (string memory) {
        return fallbackValue;
    }

    function exposedQueue(Deployed memory d, TimelockController timelock, GovParams memory p) external {
        _queue(d, timelock, p);
    }

    function exposedQueuePause(Deployed memory d, TimelockController timelock, bytes32 salt) external {
        _queuePause(d, timelock, salt);
    }

    function exposedExecuteQueuedPause(Deployed memory d, TimelockController timelock, bytes32 salt) external {
        _executeQueuedPause(d, timelock, salt);
    }

    function exposedPhase4PauseCalls(Deployed memory d)
        external
        pure
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        return _phase4PauseCalls(d);
    }
}

/// @notice Round-50: `WirePhase4._queuePause`'s round-49 timelock guard asked about ONE of the two
///         contracts its batch pauses.
///
/// @dev **Found by round-50 fleet agents A1, A2 and A3, independently.** Round 49 added
///      `TimelockIsNotTheOwner` to `_queuePause` and to `_queue` as the identical line,
///      `if (d.credit.owner() != address(timelock)) revert ...`, and its own comment names the
///      failure it closes: "`pause()` is owner-or-guardian on BOTH TARGETS, so a timelock that is
///      not the owner schedules a batch that refuses at maturity". It then asked the question of
///      one target.
///
///      `DeployBase._phase4PauseCalls` builds `[credit.pause(), vault.pause()]`. In `_queue` the
///      line is redundant - `_assertCoreGraph` runs immediately above it and holds EVERY member of
///      `Deployed` to `p.owner` - so the one place it was load-bearing was `_queuePause`, which
///      deliberately runs the liveness census and NOT the full graph, because gating a wind-down on
///      a rotated keeper would be a worse trade. `_ownablesOf` collects each member's owner and
///      compares it with nothing.
///
///      The consequence is the one round 49 wrote the error for, on the other leg: `queuePause()`
///      accepts, `scheduleBatch` lands, and forty-eight hours later `executeBatch` reverts
///      `CollateralVault.NotOwnerOrGuardian()` on the vault leg - atomically undoing the credit leg
///      that succeeded. Nothing is paused, the operation stays `Ready` as an armed replay (there is
///      no grace period), and the correct re-queue costs another maturity.
///
///      **RED BEFORE THE FIX** is the finding tests below PASSING as findings: at 9d1e72d each of
///      them scheduled the batch without complaint and reached the maturity-time refusal. Under the
///      fix they refuse at generation time, which is what they now assert.
///
///      The fix is derived from `_phase4PauseCalls` rather than hand-written per target, so a third
///      leg cannot outrun it. It is STRICT on `owner()`; the guardian residual is
///      `test_R50_147_theStrictFormRefusesAGuardianThatCouldHaveExecuted` below.
contract R50WirePhase4PauseTargetsTest is Test, DeployBase {
    address internal treasury = makeAddr("r50.147.treasury");
    address internal keeper = makeAddr("r50.147.keeper");
    address internal navConfirmer = makeAddr("r50.147.navConfirmer");
    address internal strayOwner = makeAddr("r50.147.strayOwner");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    R50PauseTargetsExposed internal script;

    /// @dev Round 57 (round-57 item 131, audit agent A6): one of three inheritors the round-49 row did not name, open on all three seams at 82679aa.
    ///      Hermetic on all three seams - the fallback, never `super` - so the first reader added to
    ///      this contract cannot hand `contracts/.env` a vote. Nothing here reads a seam today; the
    ///      repository's environment census printed it `direct` on every one.
    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue) internal pure override returns (string memory) {
        return fallbackValue;
    }

    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(ANVIL_CHAIN_ID);
        script = new R50PauseTargetsExposed();
    }

    function _externals() internal view returns (Externals memory) {
        return
            Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
    }

    function _paramsOwnedBy(address who) internal view returns (GovParams memory) {
        return GovParams({
            owner: who,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: treasury,
            guardian: address(0)
        });
    }

    /// @dev Both this contract and the broadcast sender hold `PROPOSER_ROLE`: `_queuePause` checks
    ///      `msg.sender` (this contract) and then broadcasts `scheduleBatch` from `DEFAULT_SENDER`.
    function _timelock() internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    function _pauseId(Deployed memory d, TimelockController t, bytes32 salt) internal view returns (bytes32) {
        (address[] memory tg, uint256[] memory v, bytes[] memory pl) = script.exposedPhase4PauseCalls(d);
        return t.hashOperationBatch(tg, v, pl, bytes32(0), salt);
    }

    // ── route one: the G2 handover stopped after the credit manager (fleet A2) ───────────────

    /// @notice A hand-sent handover that moved the manager and not the vault is refused before the
    ///         clock starts.
    /// @dev **RED before the fix, MEASURED:** this call was ACCEPTED, `isOperationPending` was
    ///      true, and forty-eight hours later `executeQueuedPause` reverted
    ///      `CollateralVault.NotOwnerOrGuardian()` with nothing paused and the operation still
    ///      `Ready`.
    ///
    ///      The G2 handover is nine separate `transferOwnership` transactions with no script in the
    ///      path - `CollateralVault.transferOwnership`'s own docstring says so - and this
    ///      repository has a measured record of a broadcast completing partially while its script
    ///      exited 0. Stopping after the first is not a contrived state.
    function test_R50_147_queuePauseRefusesAHandoverThatStoppedAtTheManager() public {
        TimelockController timelock = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(this)), address(this));

        d.credit.transferOwnership(address(timelock));
        assertEq(d.credit.owner(), address(timelock), "premise: the credit manager has moved");
        assertEq(d.vault.owner(), address(this), "premise: the vault has not");
        assertEq(d.vault.guardian(), address(0), "premise: and no guardian stands in for it");

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.TimelockIsNotTheOwner.selector, address(timelock), address(this))
        );
        script.exposedQueuePause(d, timelock, bytes32(0));

        assertFalse(timelock.isOperationPending(_pauseId(d, timelock, bytes32(0))), "nothing was scheduled");
        assertFalse(d.credit.paused(), "and nothing was touched");
    }

    /// @notice Control: the same batch, with the vault handed over too, schedules and executes.
    /// @dev Without this the refusal above would be satisfied by a guard that refuses everything.
    function test_R50_147_control_theSameBatchExecutesOnceTheVaultHasMovedToo() public {
        TimelockController timelock = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(this)), address(this));

        d.credit.transferOwnership(address(timelock));
        d.vault.transferOwnership(address(timelock));

        script.exposedQueuePause(d, timelock, bytes32(0));
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.exposedExecuteQueuedPause(d, timelock, bytes32(0));

        assertTrue(d.credit.paused(), "control: borrow is shut");
        assertTrue(d.vault.paused(), "control: and deposits with it");
    }

    /// @notice Control, the other direction: round 49's own case still refuses, so this change is a
    ///         widening of that guard rather than a replacement of it.
    function test_R50_147_control_theRound49CaseStillRefusesAStrangerTimelock() public {
        TimelockController timelock = _timelock();
        TimelockController stranger = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(this)), address(this));
        d.credit.transferOwnership(address(timelock));
        d.vault.transferOwnership(address(timelock));

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.TimelockIsNotTheOwner.selector, address(stranger), address(timelock))
        );
        script.exposedQueuePause(d, stranger, bytes32(0));
    }

    // ── route two: a governance migration that moved the vault away (fleet A1 and A3) ────────

    /// @dev The mirror state, reached the other way round: the graph is deployed OWNED by the
    ///      timelock and the vault is then transferred out. Kept beside route one because the two
    ///      are different operator stories - an interrupted handover and a partial migration - and
    ///      a guard that covered only one of them would look complete.
    function _splitTheVaultOff(Deployed memory d, address timelockOwner) internal {
        vm.prank(timelockOwner);
        d.vault.transferOwnership(strayOwner);
        assertEq(d.vault.owner(), strayOwner, "premise: the vault answers to somebody else");
        assertEq(d.credit.owner(), timelockOwner, "premise: the manager still answers to the timelock");
        assertEq(d.vault.guardian(), address(0), "premise: the vault has no guardian either");
    }

    /// @notice The same refusal from the migration side, with the batch's shape asserted.
    /// @dev **RED before the fix, MEASURED:** accepted and scheduled, then
    ///      `CollateralVault.NotOwnerOrGuardian()` at maturity with the operation left `Ready`
    ///      forever. The two legs are asserted by index here so the finding's premise - that the
    ///      guard read leg 0 and the batch also has a leg 1 - is a measurement rather than a claim.
    function test_R50_147_queuePauseRefusesASplitVaultBeforeTheClockStarts() public {
        TimelockController owning = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(owning)), address(this));
        _splitTheVaultOff(d, address(owning));

        (address[] memory t,,) = script.exposedPhase4PauseCalls(d);
        assertEq(t.length, 2, "the batch has two targets");
        assertEq(t[0], address(d.credit), "leg 0 is the manager, which the round-49 guard asked about");
        assertEq(t[1], address(d.vault), "leg 1 is the vault, which it did not");

        vm.expectRevert(abi.encodeWithSelector(WirePhase4.TimelockIsNotTheOwner.selector, address(owning), strayOwner));
        script.exposedQueuePause(d, owning, bytes32(0));

        assertFalse(owning.isOperationPending(_pauseId(d, owning, bytes32(0))), "nothing was scheduled");
    }

    /// @notice The asymmetry that made this a mirror rather than a second opinion: `queue()` always
    ///         caught the very split `queuePause()` accepted.
    /// @dev In `_queue` the round-49 line is redundant because `_assertCoreGraph` holds all nine
    ///      members to `p.owner`; in `_queuePause` it was the only owner-shaped check there was.
    ///      This test passed before the fix and passes after it, which is the point.
    function test_R50_147_queueAlwaysRefusedTheSplitThatQueuePauseAccepted() public {
        TimelockController owning = _timelock();
        GovParams memory p = _paramsOwnedBy(address(owning));
        Deployed memory d = _deployProtocol(_externals(), p, address(this));
        _splitTheVaultOff(d, address(owning));

        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.OwnershipNotTransferred.selector, address(d.vault), strayOwner)
        );
        script.exposedQueue(d, owning, p);
    }

    /// @notice Control: an unsplit graph owned by the timelock queues the pause and executes it.
    function test_R50_147_control_anUnsplitGraphQueuesAndExecutesThePause() public {
        TimelockController owning = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(owning)), address(this));

        script.exposedQueuePause(d, owning, bytes32(0));
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.exposedExecuteQueuedPause(d, owning, bytes32(0));

        assertTrue(d.credit.paused(), "control: borrow shut");
        assertTrue(d.vault.paused(), "control: deposits shut");
    }

    // ── the accepted residual ────────────────────────────────────────────────

    /// @notice THE COST OF THE STRICT FORM, executed rather than argued: a timelock that is the
    ///         vault's GUARDIAN could have executed the batch and is refused at generation.
    /// @dev `pause()` is owner-OR-guardian on both targets, so this state really is executable -
    ///      proved below by pranking the guardian directly, since `queuePause()` now refuses to
    ///      schedule it. The refusal is therefore a FALSE refusal that fails CLOSED, and it is
    ///      accepted rather than fixed. Two measurements decided that:
    ///
    ///        - `guardian()` REVERTS on all nine live Base Sepolia addresses, whose bytecode
    ///          predates the guardian pair, and `_queuePause` is the one `WirePhase4` entry point
    ///          that reads no `guardian()` at all. A tolerant form would take the last step that
    ///          works against the live deployment out with it - and this is the step a wind-down
    ///          depends on.
    ///        - Nothing is lost downstream: `_assertCoreGraph` at `queue()` holds the guardian to
    ///          `p.guardian` and the owner to `p.owner`, so a guardian-only timelock is refused
    ///          two steps later regardless.
    ///
    ///      Note the shape the fixture is forced into, because it is the reason the question has to
    ///      be asked per target: `setGuardian` is `onlyOwner` and `transferOwnership` refuses a
    ///      handover to the sitting guardian, so one address cannot be both owner and guardian of
    ///      one contract.
    function test_R50_147_theStrictFormRefusesAGuardianThatCouldHaveExecuted() public {
        TimelockController second = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(this)), address(this));
        d.vault.setGuardian(address(second));
        d.credit.transferOwnership(address(second));
        assertEq(d.vault.owner(), address(this), "premise: the vault is owned elsewhere");
        assertEq(d.vault.guardian(), address(second), "premise: and guarded by the timelock");

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.TimelockIsNotTheOwner.selector, address(second), address(this))
        );
        script.exposedQueuePause(d, second, bytes32(0));

        // And the state really is executable, so the line above is a false refusal rather than a
        // correct one. Both legs, from the timelock, in the roles it actually holds.
        vm.startPrank(address(second));
        d.credit.pause();
        d.vault.pause();
        vm.stopPrank();
        assertTrue(d.credit.paused() && d.vault.paused(), "the refused batch would have executed");
    }
}
