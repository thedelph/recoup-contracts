// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {Config} from "../src/Config.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round-49 finding, `RECOUP_TIMELOCK` against the graph's owner.
///
/// @dev `WirePhase4` resolved `RECOUP_TIMELOCK` and never compared it with the owner of the graph
///      it was about to schedule on. `_queuePause` ran the liveness census and `_queue` the full
///      graph census - both of which compare the chain's owner with `p.owner` - and neither asked
///      whether the TIMELOCK was that owner. So an environment naming a timelock that owns
///      nothing passed both, scheduled on it, and the refusal arrived forty-eight hours later
///      from `executeBatch` (`NotOwnerOrGuardian()` on the pause batch, since `pause()` is
///      owner-or-guardian; `OwnableUnauthorizedAccount(thatTimelock)` on the switchover batch),
///      with the protocol left PAUSED by a correctly executed step one. The `queue()` docstring
///      said `_queue` was "where that is found out". It was not. Sign-checked and executed as an
///      acceptance in audit round 49; these are the refusals.
///
///      The harness is the `ExposedWirePhase4` construction from `Deploy.t.sol`, redeclared so
///      this file does not inherit that suite, and hermetic: the environment seam returns its
///      fallback and never `super` (round-49 item 136).
contract R49ExposedWirePhase4 is WirePhase4 {
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

    function exposedExecuteQueued(Deployed memory d, TimelockController timelock, GovParams memory p) external {
        _executeQueued(d, timelock, p);
    }

    function exposedQueuePause(Deployed memory d, TimelockController timelock, bytes32 salt) external {
        _queuePause(d, timelock, salt);
    }

    function exposedExecuteQueuedPause(Deployed memory d, TimelockController timelock, bytes32 salt) external {
        _executeQueuedPause(d, timelock, salt);
    }

    function exposedPhase4Calls(Deployed memory d)
        external
        pure
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        return _phase4Calls(d);
    }

    function exposedPhase4PauseCalls(Deployed memory d)
        external
        pure
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        return _phase4PauseCalls(d);
    }
}

contract R49WirePhase4TimelockTest is Test, DeployBase {
    address internal treasury = makeAddr("r49.treasury");
    address internal keeper = makeAddr("r49.keeper");
    address internal navConfirmer = makeAddr("r49.navConfirmer");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    R49ExposedWirePhase4 internal script;

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
        script = new R49ExposedWirePhase4();
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

    /// @dev Both the broadcast sender and this contract hold PROPOSER_ROLE, for the reason
    ///      `Deploy.t.sol` gives: `_queue` checks `msg.sender` (this contract) and then broadcasts
    ///      `scheduleBatch` from `DEFAULT_SENDER`.
    function _timelock() internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    /// @dev Step one of the sanctioned two-step, on the timelock that really owns the graph.
    function _pauseThrough(Deployed memory d, TimelockController owning) internal {
        script.exposedQueuePause(d, owning, bytes32(0));
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.exposedExecuteQueuedPause(d, owning, bytes32(0));
        assertTrue(d.credit.paused(), "premise: borrow shut");
        assertTrue(d.vault.paused(), "premise: deposits shut");
    }

    /// @notice `queuePause()` refuses a timelock that does not own the graph, before scheduling.
    /// @dev RED before the guard, MEASURED at `73b474a`: `next call did not revert as expected` -
    ///      the pause passed `_ownablesOf`, scheduled on the stranger, and forty-eight hours later
    ///      `executeBatch` refused `NotOwnerOrGuardian()` with nothing paused.
    function test_R49_queuePauseRefusesATimelockThatDoesNotOwnTheGraph() public {
        TimelockController owning = _timelock();
        TimelockController stranger = _timelock();
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(owning)), address(this));
        assertEq(d.credit.owner(), address(owning), "premise: the graph is owned by `owning`");
        assertTrue(address(stranger) != address(owning), "premise: two distinct timelocks");

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.TimelockIsNotTheOwner.selector, address(stranger), address(owning))
        );
        script.exposedQueuePause(d, stranger, bytes32(0));

        (address[] memory t, uint256[] memory v, bytes[] memory p) = script.exposedPhase4PauseCalls(d);
        bytes32 id = stranger.hashOperationBatch(t, v, p, bytes32(0), bytes32(0));
        assertFalse(stranger.isOperationPending(id), "nothing was scheduled on the timelock that owns nothing");
        assertFalse(d.credit.paused(), "and nothing was touched");
    }

    /// @notice `queue()` refuses the same timelock after the full census, so a correctly executed
    ///         step one is not followed by forty-eight hours scheduled on the wrong contract.
    /// @dev RED before the guard, MEASURED at `73b474a`: `next call did not revert as expected` -
    ///      `_assertCoreGraph` passed (the chain's owner is `p.owner`), the window was shut, the
    ///      switchover scheduled on the stranger, and after another maturity `executeBatch` refused
    ///      `OwnableUnauthorizedAccount(stranger)` with `borrow` and `depositETH` still shut and
    ///      the correct re-queue costing a third forty-eight hours.
    function test_R49_queueRefusesATimelockThatDoesNotOwnTheGraph() public {
        TimelockController owning = _timelock();
        TimelockController stranger = _timelock();
        GovParams memory p = _paramsOwnedBy(address(owning));
        Deployed memory d = _deployProtocol(_externals(), p, address(this));

        // Step one, done correctly on the owning timelock: 48 hours.
        _pauseThrough(d, owning);

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.TimelockIsNotTheOwner.selector, address(stranger), address(owning))
        );
        script.exposedQueue(d, stranger, p);

        (address[] memory t, uint256[] memory v, bytes[] memory pl) = script.exposedPhase4Calls(d);
        bytes32 id = stranger.hashOperationBatch(t, v, pl, bytes32(0), bytes32(0));
        assertFalse(stranger.isOperationPending(id), "nothing was scheduled on the wrong timelock");
        assertEq(d.credit.liquiditySource(), address(d.liquidity), "and the switchover has not moved");
    }

    /// @notice The control: the same batch on the OWNING timelock schedules and executes.
    function test_R49_control_theOwningTimelockQueuesAndExecutesTheSameBatch() public {
        TimelockController owning = _timelock();
        GovParams memory p = _paramsOwnedBy(address(owning));
        Deployed memory d = _deployProtocol(_externals(), p, address(this));
        _pauseThrough(d, owning);

        script.exposedQueue(d, owning, p);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.exposedExecuteQueued(d, owning, p);
        assertEq(d.credit.liquiditySource(), address(d.pool), "control: the right timelock switches over");
        assertFalse(d.credit.paused(), "and reopens");
    }
}
