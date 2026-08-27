// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";

/// @notice Proves the eventual move to timelocked governance is a pure ownership
///         transfer, without imposing one today.
///
///         Development deliberately runs with a plain EOA owner: pre-launch the
///         contracts hold no third-party funds, and a 48h wait on every fix while the
///         deployment shape is still moving would cost far more than it buys. The risk
///         in deferring is not the delay itself, it is *discovering at go-live* that
///         the handover does not work. These tests remove that risk now, and pin the
///         one thing the handover breaks (see the pause pair at the end).
contract GovernanceHandoverTest is Test {
    uint256 internal constant NAV = 25.15e8;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal proposer = makeAddr("proposer");
    address internal yieldSink = makeAddr("yieldSink");
    address internal newSink = makeAddr("newSink");
    /// @dev A third sink, so the round-20 replay test has two *distinct* pending operations
    ///      against one setter. Reusing a payload is not an option: an executed operation's id is
    ///      `Done` and `TimelockController` refuses to schedule it again.
    address internal laterSink = makeAddr("laterSink");
    address internal outsider = makeAddr("outsider");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    RiskParams internal riskParams;
    TimelockController internal timelock;

    function setUp() public {
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

        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        bond.mint(alice, 1_000);
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);

        // The shape we would actually deploy: one proposer (a Safe in production),
        // open execution, and no standalone admin so there is no delay-bypassing
        // backdoor to remember to renounce later.
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _handOver() internal {
        vm.startPrank(admin);
        vault.transferOwnership(address(timelock));
        adapter.transferOwnership(address(timelock));
        riskParams.transferOwnership(address(timelock));
        vm.stopPrank();
    }

    function _schedule(address target, bytes memory data) internal returns (bytes32 id) {
        vm.prank(proposer);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        id = timelock.hashOperation(target, 0, data, bytes32(0), bytes32(0));
    }

    function _execute(address target, bytes memory data) internal {
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    // ── the constant becomes load-bearing ────────────────────────────────────

    /// @dev Config.ADMIN_TIMELOCK is referenced by no contract. This is what stops it
    ///      reading as dead code and being deleted.
    function test_timelockMinDelayMatchesConfig() public view {
        assertEq(timelock.getMinDelay(), Config.ADMIN_TIMELOCK);
        assertEq(Config.ADMIN_TIMELOCK, 48 hours);
    }

    // ── the handover itself ──────────────────────────────────────────────────

    /// @dev The headline: no redeploy, no migration, no disturbance to live state.
    function test_handoverIsPureOwnershipTransfer() public {
        vm.prank(alice);
        vault.depositBonds(100);

        _handOver();

        assertEq(vault.owner(), address(timelock));
        assertEq(adapter.owner(), address(timelock));
        assertEq(riskParams.owner(), address(timelock));
        // Everything that matters is untouched.
        assertEq(vault.bondCount(alice), 100);
        assertEq(address(vault.custodyAdapter()), address(adapter));
        assertEq(adapter.yieldRecipient(), yieldSink);
        assertEq(adapter.stakedBalance(), 100);
        // The risk configuration survives the handover unchanged. It is the one piece of state a
        // handover could plausibly be expected to disturb, since the timelock now owns the only
        // thing that can write it.
        assertEq(riskParams.maxLtvBps(), Config.DEFAULT_MAX_LTV_BPS);
        assertEq(riskParams.liquidationThresholdBps(), Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS);
    }

    /// @notice The vault reads its LTV rule out of a pointer it cannot be made to change.
    /// @dev The reason `riskParams` is `immutable` on all three readers rather than a settable
    ///      pointer like `creditManager`. A settable one would mean the handover has a second
    ///      thing to get right, and a wrong value there is not a broken deployment - it is a
    ///      working deployment enforcing a risk configuration nobody chose.
    function test_theVaultsRiskPointerCannotBeRepointedByAnyone() public view {
        assertEq(address(vault.riskParams()), address(riskParams));
    }

    function test_afterHandover_oldOwnerLosesAuthority() public {
        _handOver();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        vault.setLiquidationAuction(outsider);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        adapter.setYieldRecipient(newSink);
    }

    /// @dev The proposer is not the owner. Scheduling is its only power, so governance
    ///      is genuinely delayed rather than nominally timelocked.
    function test_proposerCannotCallOwnerFunctionsDirectly() public {
        _handOver();

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, proposer));
        adapter.setYieldRecipient(newSink);
    }

    /// @dev Users are unaffected by the flip: no governance action needed to transact.
    function test_vaultLifecycleUnchangedAfterHandover() public {
        _handOver();

        vm.prank(alice);
        vault.depositBonds(100);
        assertEq(vault.bondCount(alice), 100);

        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), 1_000);
    }

    // ── a real governance operation, end to end ──────────────────────────────

    function test_queuedSetYieldRecipient_revertsBeforeDelay() public {
        _handOver();
        bytes memory data = abi.encodeCall(DirectCallAdapter.setYieldRecipient, (newSink));
        _schedule(address(adapter), data);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _execute(address(adapter), data);

        assertEq(adapter.yieldRecipient(), yieldSink);
    }

    function test_queuedSetYieldRecipient_executesAfterDelay() public {
        _handOver();
        bytes memory data = abi.encodeCall(DirectCallAdapter.setYieldRecipient, (newSink));
        _schedule(address(adapter), data);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _execute(address(adapter), data);

        assertEq(adapter.yieldRecipient(), newSink);
    }

    /// @dev Execution is permissionless after the delay, by choice: it removes the
    ///      "nobody available to press the button" failure mode, and the calldata has
    ///      been public for 48h by then. If that policy ever changes, this test should
    ///      fail rather than the change passing silently.
    function test_executeIsOpenAfterDelay() public {
        _handOver();
        bytes memory data = abi.encodeCall(DirectCallAdapter.setYieldRecipient, (newSink));
        _schedule(address(adapter), data);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.prank(outsider);
        _execute(address(adapter), data);

        assertEq(adapter.yieldRecipient(), newSink);
    }

    /// @dev The counterweight to open execution: the proposer holds CANCELLER_ROLE by
    ///      construction, so a mistaken operation can be pulled before it ripens.
    function test_proposerCanCancelBeforeExecution() public {
        _handOver();
        bytes memory data = abi.encodeCall(DirectCallAdapter.setYieldRecipient, (newSink));
        bytes32 id = _schedule(address(adapter), data);

        vm.prank(proposer);
        timelock.cancel(id);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _execute(address(adapter), data);
    }

    function test_scheduleRequiresProposerRole() public {
        _handOver();
        bytes memory data = abi.encodeCall(DirectCallAdapter.setYieldRecipient, (newSink));

        vm.prank(outsider);
        vm.expectRevert();
        timelock.schedule(address(adapter), 0, data, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
    }

    /// @dev No standalone admin was granted, so there is no backdoor to remember to
    ///      renounce. The timelock administers itself, through its own delay.
    function test_timelockHasNoStandaloneAdmin() public view {
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        assertTrue(timelock.hasRole(adminRole, address(timelock)));
        assertFalse(timelock.hasRole(adminRole, proposer));
        assertFalse(timelock.hasRole(adminRole, address(this)));
        assertFalse(timelock.hasRole(adminRole, admin));
    }

    /// @dev Governance cannot brick the protocol even deliberately.
    function test_renounceOwnershipStaysDisabledUnderTimelock() public {
        _handOver();
        bytes memory data = abi.encodeCall(Ownable.renounceOwnership, ());
        _schedule(address(vault), data);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.expectRevert();
        _execute(address(vault), data);

        assertEq(vault.owner(), address(timelock));
    }

    /// @dev TimelockController is an ERC1155Holder, so it can always receive bonds.
    ///      A Safe only can if its compatibility fallback handler is configured, which
    ///      is not something to find out during a break-glass.
    function test_timelockCanReceiveEmergencyUnstakedBonds() public {
        vm.prank(alice);
        vault.depositBonds(100);
        _handOver();

        bytes memory data = abi.encodeCall(DirectCallAdapter.emergencyUnstake, (address(timelock)));
        _schedule(address(adapter), data);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _execute(address(adapter), data);

        assertEq(bond.balanceOf(address(timelock), Config.DEXFI_BOND_TOKEN_ID), 100);
    }

    // ── audit round 20: a matured operation never expires ────────────────────

    /// @notice **The replay is a property of the timelock, not of `RiskParams`.** Every
    ///         `onlyOwner` setter in this protocol can be superseded and then un-superseded by a
    ///         stranger, because `TimelockController` has no grace period and execution is open.
    /// @dev Written specifically to refute a compare-and-swap argument on `setRiskParams`. Round 20
    ///      measured the replay there - a stale ratchet step undoing an emergency tightening on
    ///      three of four fields - and a nonce on that one setter would close that one instance
    ///      while reading like closure of the shape. This is the same replay on
    ///      `adapter.setYieldRecipient`, which is the "owner can redirect yield" power **the
    ///      audit accepted because the owner would be a timelock**. It is
    ///      strictly worse than the risk-parameter case: there is no transition check on any field
    ///      here, because there is only one field.
    ///
    ///      So the answer is operational and it is the one `test_proposerCanCancelBeforeExecution`
    ///      above already exercises the mechanism for: **cancel every pending operation against a
    ///      target before scheduling one that supersedes it**, and cancel first so no block has
    ///      both `Ready`. Recorded as a go-live operating rule rather than built into nine
    ///      contracts. `RiskParameters.t.sol` holds the measured instance and the cancel control.
    function test_aStaleProposalReplaysOnAnySetterNotOnlyRiskParams() public {
        _handOver();

        // A: route the yield somewhere, scheduled in the ordinary course of business.
        bytes memory superseded = abi.encodeCall(DirectCallAdapter.setYieldRecipient, (newSink));
        _schedule(address(adapter), superseded);

        // An hour later governance changes its mind and schedules B instead. Two live operations
        // against one setter is all it takes; neither has to be a mistake.
        vm.warp(block.timestamp + 1 hours);
        bytes memory intended = abi.encodeCall(DirectCallAdapter.setYieldRecipient, (laterSink));
        _schedule(address(adapter), intended);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _execute(address(adapter), intended);
        assertEq(adapter.yieldRecipient(), laterSink, "the latest decision lands");

        // A stranger replays the superseded one, in the same block, with no proposer involved.
        vm.prank(outsider);
        _execute(address(adapter), superseded);
        assertEq(adapter.yieldRecipient(), newSink, "MEASURED: the superseded routing came back");
    }

    // ── what the handover costs, in executable form ──────────────────────────

    /// @dev Today: a pause is one transaction per switch. This is the upside of the current EOA
    ///      owner and the reason deferring the timelock is defensible.
    ///
    ///      **This test used to pause the vault and assert `depositBonds` reverted.** It no longer
    ///      does, because the deposit gate was split off the pause (audit round 25, finding 1) -
    ///      `pause()` shuts `depositETH`, and the borrower's cure has its own owner-only switch.
    ///      Both halves are asserted here so the change is visible from this file rather than
    ///      only from `PausedMode.t.sol`.
    function test_pauseIsInstantUnderEoaOwner() public {
        vm.prank(admin);
        vault.pause();

        // The cure is NOT shut by `pause()`, which is the whole point of the split.
        vm.prank(alice);
        vault.depositBonds(100);
        assertEq(vault.bondCount(alice), 100, "a pause does not shut the borrower's cure");

        // Its own switch does, and it is one transaction too, while the owner is an EOA.
        vm.prank(admin);
        vault.setBondDepositsPaused(true);
        vm.prank(alice);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        vault.depositBonds(100);
    }

    /// @dev And the cost of the flip: an owner pause becomes a 48-hour advance notice, which is
    ///      worse than useless in an incident. `depositETH` keeps working for the entire wait.
    ///
    ///      **The sentence that used to end this docstring is spent.** It read that a guardian
    ///      role "has to land in the *same* change as the timelock, not after". The guardian now
    ///      exists - see `test_guardianPausesInstantlyUnderTimelock` below and go-live item G4 -
    ///      so the constraint that remains is the other direction: **G2 must not ship without G4**,
    ///      and G4 must not ship without the deposit split, which is why all three moved together.
    function test_pauseBecomesDelayedUnderTimelock() public {
        _handOver();
        bytes memory data = abi.encodeCall(CollateralVault.pause, ());
        _schedule(address(vault), data);

        // Half a day into an incident, still nothing anyone can do.
        vm.warp(block.timestamp + 12 hours);
        assertFalse(vault.paused());
        vm.prank(alice);
        vault.depositBonds(100);
        assertEq(vault.bondCount(alice), 100);

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        _execute(address(vault), data);
        assertTrue(vault.paused());
    }

    /// @notice **Go-live item G4, and the reason it exists: the guardian keeps the pause instant
    ///         after the handover makes the owner's pause a 48-hour operation.**
    /// @dev Installed BEFORE `_handOver`, because `setGuardian` is `onlyOwner` and after the
    ///      handover that is a scheduled operation too - so a protocol that hands over without a
    ///      guardian has to wait 48 hours to acquire one. That ordering is the deploy script's
    ///      job (`DeployBase._wire` calls `setGuardian` before `_handOver`) and it is asserted
    ///      here because it is the kind of ordering that reads as arbitrary until it bites.
    ///
    ///      Note what the guardian deliberately CANNOT do, both asserted below: reopen the
    ///      protocol, and reach the borrower's cure. The second is what makes handing this key
    ///      out safe at all - `Config.ADMIN_TIMELOCK / Config.AUCTION_DURATION` is 8, so a
    ///      guardian that could shut the cure would shut it for eight complete auction lifecycles
    ///      on a mis-fire, at exactly the cost of malice.
    function test_guardianPausesInstantlyUnderTimelock() public {
        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);
        _handOver();

        // One transaction, no schedule, no wait.
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused(), "the guardian paused instantly under a 48-hour owner");

        // And cannot undo it: `unpause` is owner-only, and the owner is now the timelock.
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();

        // Nor reach the cure's switch, which stays behind the full 48 hours.
        vm.prank(guardian);
        vm.expectRevert();
        vault.setBondDepositsPaused(true);
        assertFalse(vault.bondDepositsPaused(), "the cure is out of the guardian's reach");

        // So the borrower can still act while the guardian's pause stands.
        vm.prank(alice);
        vault.depositBonds(100);
        assertEq(vault.bondCount(alice), 100, "the cure is open throughout a guardian pause");
        assertTrue(vault.paused(), "and the pause never lifted to allow it");
    }
}
