// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "./DeployBase.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";

/// @notice The Phase-4 switchover as a broadcastable operation: the LenderPool takes over funding
///         the book and takes on the losses that come with it, and the post-condition runs in the
///         same breath.
///
/// @dev **Audit round 16, seven agents: this file did not exist, and that made roughly eighteen
///      assertions unreachable outside CI.** `_wirePhase4` and `_assertPhase4Wiring` are `internal`
///      on an abstract contract, and a repo-wide grep found callers only in the test suite. All
///      three `Deploy.s.sol` targets call `_deployProtocol` and `_assertWiring` and neither Phase-4
///      function. So on mainnet the switchover was a handful of hand-sent owner transactions with
///      **no post-condition at all** - including every ownership check and `d.liquidity`, the
///      contract that has been missed twice while holding the lending float behind an uncapped
///      `onlyOwner` withdraw.
///
///      `DeployBase`'s own header names this exact class: "A switchover written as a runbook step
///      instead of as code would be the same class of defect as the one it fixes." Audit round 15
///      made the post-condition worth running and left it with nothing to run it.
///
///      **Addresses come from the environment rather than from a deployment record**, because by
///      the time this runs the deployment is history and the operator has the addresses in front of
///      them. Every one is required: there is no local fallback here, unlike `_resolveParams`,
///      because there is no such thing as a switchover on a protocol that was not deployed.
///
///      **The owner runs this, and by Phase 4 the owner is meant to be a Safe or a timelock.**
///      `run()` broadcasts the switchover directly and is the right entry point only while the
///      owner is still an EOA. **Under a timelock, use `queue()`** - and use nothing else.
///
///      **Audit round 20, finding 5, which is why `queue()` exists.** Round 19 closed the ordering
///      gap in `_wirePhase4` with a pause bracket. That is correct against the *operator* and is
///      defeated by the *timelock executor*: a `forge script` broadcast emits one transaction per
///      external call, so an operator reading `run()`'s emitted call list into a timelock UI
///      produces one scheduled operation per leg - and `TimelockController` as this repo deploys it
///      takes `executors[0] = address(0)`, open execution, with `predecessor = bytes32(0)` on each.
///      Once they mature, any stranger executes them in any order they like. `setLiquiditySource`
///      first and the pause not at all reopens round 19's gap byte for byte.
///
///      `queue()` schedules the whole list as a single `scheduleBatch` operation instead.
///      `executeBatch` runs the array in order, atomically, in one transaction, or reverts: there
///      is no window to reorder into and no subset that hashes to a scheduled id. `assertOnly()` is
///      still how the post-condition is checked afterwards - a timelocked switchover cannot assert
///      its own result in the same transaction, and an assertion that can only run in the same
///      transaction as the change is an assertion that never runs on the deployment that matters.
///
///      **Audit round 21, finding 2, which is why `queuePause()` exists.** Round 20's single batch
///      removed the ordering window and created a *precondition* window in its place: the legs that
///      shut `borrow` executed in the same transaction as the preconditions they were protecting,
///      so for the whole 48-hour maturity the door was open. MEASURED: one micro-USDC of debt,
///      borrowed by a stranger through the ordinary front door, makes `executeBatch` revert
///      `DebtOutstanding(1)` - and `TimelockController` has no grace period, so the refused
///      operation stays `Ready` (MEASURED at 365 days) as a live, stranger-executable replay.
///
///      So the pause is now its own, earlier operation. The order under a timelock is
///      **`queuePause()` -> wait -> `executeQueuedPause()` -> `queue()` -> wait ->
///      `executeQueued()` -> `assertOnly()`**, and `queue()` refuses outright while either contract
///      is unpaused. The switchover batch still ends with the two `unpause` legs, which carry OZ's
///      `whenPaused` - so if the pause is not in force when the batch fires, those legs revert
///      `ExpectedPause` and the atomic batch undoes itself. The precondition is checked at
///      generation time and enforced on chain at execution time.
///
///      **And the "unrecoverable" premise round 21 recorded is false, MEASURED against this repo's
///      own pinned OZ v5.6.1 and its own role wiring.** `cancel` does `delete _timestamps[id]`,
///      returning the id to `Unset`, and `_schedule` only rejects `isOperation(id)` - so cancelling
///      frees the id and the identical call set re-schedules with `SALT == bytes32(0)` intact.
///      `cancel` is not itself delayed and every proposer holds `CANCELLER_ROLE` by construction of
///      `TimelockController`'s constructor. A blocked switchover costs another 48 hours, not
///      permanence. Only a **Done** id is burned forever (`_timestamps[id] == 1`), which is why the
///      pause operation - the one here that may legitimately need to run more than once - takes a
///      salt and the switchover, which runs once, does not.
contract WirePhase4 is DeployBase {
    /// @notice `assertOnly` was asked for a health report with no owner named.
    /// @dev Its own error rather than a bare revert, because the failure it replaces looked
    ///      exactly like a real one: `OwnershipNotTransferred` against the correct owner, i.e.
    ///      a health report inventing a wiring failure out of an unset environment variable.
    error OwnerNotNamedForReport();

    error DeployedAddressMissing(string name);
    error SwitchoverConfirmationMissing();

    /// @dev Round 21, finding 2. Named rather than folded into a console warning: an operator who
    ///      queues an unprotected window learns about it forty-eight hours later, from a different
    ///      error, on a batch that then stays armed forever.
    error SwitchoverNotPaused(bool creditPaused, bool vaultPaused);

    /// @dev The same window, the other precondition. `setLiquiditySource` refuses while the book
    ///      carries debt, so a batch queued against a live book is scheduled already knowing it
    ///      will revert. With the pause in force before this check runs, `totalDebt` can only fall
    ///      from here - `borrow` is the only thing that raises it and it is shut - so zero at queue
    ///      time is zero at execution time.
    error SwitchoverBookNotFlat(uint256 totalDebt);

    /// @dev The third and last precondition the six legs actually evaluate. `setLiquiditySource`
    ///      and `setLenderPool` both refuse while a deferred loss is unplaced, and unlike the other
    ///      two this one can be non-zero on a book that is flat - it is a backlog, not a position.
    ///      Checked here so the set is complete: a batch `queue()` accepts is a batch
    ///      `executeBatch` executes.
    ///
    ///      **Stated rather than glossed: on a first switchover this cannot fire.**
    ///      `CreditManager._socialise` only defers a loss against a pool that is *also* the
    ///      liquidity source, and before Phase 4 the source is the treasury - `Deploy.t.sol`'s
    ///      round-19 test asserts exactly that ("and it was not even deferred"). It binds in the
    ///      register this script will actually be re-run in: a pool *migration*, where the outgoing
    ///      pool was both funder and sink and its backlog has to be flushed before the pointers can
    ///      move. There is no test driving it, because the state needs a completed switchover plus
    ///      a default plus a pool that refuses, and a fixture that faked it would be asserting
    ///      against a state the protocol cannot produce. It is one read, and a guard that is
    ///      unreachable today on a path that is explicitly re-runnable tomorrow is worth the read -
    ///      but it is not evidence of anything and should not be cited as such.
    error SwitchoverLossOutstanding(uint256 unsocialisedLoss);

    string internal constant CONFIRM_PHRASE = "RECOUP_WIRE_PHASE_4";

    /// @dev Both `bytes32(0)`, and both deliberately.
    ///
    ///      No predecessor, because there is nothing to chain to: the whole switchover is one
    ///      operation now, which is the entire point of `queue()`. Chaining was the other candidate
    ///      fix and it is strictly worse - `predecessor` orders two operations and does not stop a
    ///      third being scheduled beside them, so it would have had to be maintained across every
    ///      leg by hand, which is the failure mode being removed.
    ///
    ///      No salt, so the operation id is a pure function of the calls. An operator can recompute
    ///      it from the printed calldata without being told a nonce, and a re-run of `queue()`
    ///      produces the same id rather than a second pending switchover.
    ///
    ///      **Round 21 recorded that this makes a blocked batch unrecoverable. MEASURED, it does
    ///      not.** `TimelockController.cancel` does `delete _timestamps[id]`, which returns the id
    ///      to `Unset`, and `_schedule` only rejects `isOperation(id)` - so the identical call set
    ///      re-schedules afterwards with the salt still zero. `cancel` carries no delay of its own
    ///      and its constructor grants `CANCELLER_ROLE` to every proposer, so this is one immediate
    ///      transaction from the same key that queued. A per-attempt salt would buy nothing here and
    ///      would cost the recomputable id. `queuePause` is the exception and says why on itself:
    ///      only a **Done** id is burned forever, and that operation may legitimately run twice.
    ///
    ///      `PREDECESSOR` deliberately does not chain the switchover to the pause operation either.
    ///      Chaining would make the switchover unschedulable until the pause id existed, which
    ///      reads like a guarantee and is not one: both would then mature at the same instant and
    ///      the pause would still not have been in force for the window. The window is shut by
    ///      executing the pause first and refusing to queue until it is - see
    ///      `_requireSwitchoverWindowShut`.
    bytes32 internal constant PREDECESSOR = bytes32(0);
    bytes32 internal constant SALT = bytes32(0);

    /// @notice Wire the switchover, then assert the state it must leave behind.
    /// @dev **The EOA-owner entry point.** Every leg is broadcast as its own transaction from the
    ///      owning key, in `_phase4Calls` order, with the pause first - which is what makes the gap
    ///      unreachable in that register. Under a timelock this is the wrong function: use
    ///      `queue()`, and read finding 5 in this contract's header for why.
    function run() external {
        _requireConfirmation();
        Deployed memory d = _resolveDeployed();
        GovParams memory p = _resolveParams(msg.sender);

        vm.startBroadcast();
        _wirePhase4(d);
        vm.stopBroadcast();

        _assertPhase4Wiring(d, p);
        _log(d, p);
        console.log("Phase 4 wired: the pool funds the book and takes the losses.");
    }

    /// @notice The switchover as ONE timelock operation: schedule it, or print the single call that
    ///         does, plus the single call that later executes it.
    /// @dev Usage: forge script script/WirePhase4.s.sol:WirePhase4 --sig "queue()" --rpc-url base
    ///
    ///      **This is the only sanctioned way to put the switchover into a timelock.** Queueing the
    ///      legs individually is audit round 20's finding 5 and reopens round 19's critical 3; see
    ///      this contract's header. The calls come from `_phase4Calls`, which is the same list
    ///      `_wirePhase4` executes, so the queued operation and the tested one cannot drift.
    ///
    ///      It broadcasts when the sender holds `PROPOSER_ROLE` - true on anvil, on a testnet and
    ///      wherever the proposer is a key rather than a Safe - and otherwise prints the calldata
    ///      for whoever does. Either way it is **one** call to transcribe, not one per leg, and the
    ///      count is printed rather than written down anywhere.
    ///
    ///      **Audit round 22, finding 7: it resolves `GovParams` too now, and that is a real change
    ///      to what an operator must have in the environment before step two.** The full set -
    ///      `RECOUP_OWNER`, `RECOUP_KEEPER`, `RECOUP_NAV_CONFIRMER`, `RECOUP_PROTOCOL_FEE_WALLET`,
    ///      `RECOUP_YIELD_RECIPIENT` - was already required by `executeQueued()` and by
    ///      `assertOnly()`, so nothing new has to be discovered; it has to be correct forty-eight
    ///      hours earlier. `RECOUP_OWNER` must name the **timelock**, not the proposing key: the
    ///      batch executes as the owner, so a graph the timelock does not own cannot execute it,
    ///      and `_queue` is now where that is found out.
    function queue() external {
        _requireConfirmation();
        _queue(
            _resolveDeployed(),
            TimelockController(payable(_required("RECOUP_TIMELOCK"))),
            _resolveParams(msg.sender)
        );
    }

    /// @notice Shut `borrow` and the vault's two deposits as their OWN timelock operation, before
    ///         the switchover window opens. Step one of two.
    /// @dev Usage: forge script script/WirePhase4.s.sol:WirePhase4 --sig "queuePause()" --rpc-url base
    ///
    ///      **Round 21, finding 2.** These two legs used to be legs 1 and 2 of the switchover batch,
    ///      where they executed in the same transaction as the preconditions they were protecting -
    ///      a lock inside the room it was locking. Out here they are in force for the whole
    ///      maturity of the switchover operation, which is the only span in which anybody could
    ///      create the debt that blocks it.
    ///
    ///      **The salt, and why this operation has one when the switchover does not.** A `Done` id
    ///      is `_timestamps[id] == 1` forever - MEASURED: `cancel` refuses it and `scheduleBatch`
    ///      refuses it. The switchover runs once per deployment, so a fixed `SALT` costs nothing
    ///      and buys an id an operator can recompute from the printed calldata alone. A pause,
    ///      though, is legitimately repeatable: a switchover attempt abandoned and retried a month
    ///      later needs to pause again, and with a fixed salt that second pause would be
    ///      un-schedulable.
    ///
    ///      **Audit round 22, finding 7 narrows the recovery claim above rather than overturning
    ///      it: `cancel` frees a *pending* id and cannot touch a `Done` one, and a batch with a
    ///      codeless target reaches `Done` by succeeding.** That is why the census in `_queue` has
    ///      to run before `scheduleBatch` and not after `executeBatch` - the argument for
    ///      `SALT == bytes32(0)` covers a batch that reverts, and that batch does not revert.
    ///
    ///      `RECOUP_SWITCHOVER_ATTEMPT` is that discriminator, defaulting to
    ///      `bytes32(0)` for the first attempt. It is the one convention this file invents; OZ's
    ///      Governor has `bytes20(address(this)) ^ descriptionHash` and there is no equivalent for a
    ///      direct timelock caller.
    function queuePause() external {
        _requireConfirmation();
        _queuePause(
            _resolveDeployed(),
            TimelockController(payable(_required("RECOUP_TIMELOCK"))),
            vm.envOr("RECOUP_SWITCHOVER_ATTEMPT", bytes32(0))
        );
    }

    /// @dev Split from `queuePause()` for the reason `_queue` below gives.
    function _queuePause(Deployed memory d, TimelockController timelock, bytes32 salt) internal {
        // **Round 22, finding 7, the narrow half.** Same hazard as `_queue`'s: a codeless target
        // makes `executeBatch` succeed silently, so an operator can spend forty-eight hours
        // "pausing" nothing and only learn about it from a different error two steps later.
        // `_ownablesOf` reverts `DeployedMemberNotOwnable(i)` on a member with no code, and that
        // covers both of this batch's targets.
        //
        // **Deliberately the liveness census and NOT `_assertCoreGraph`, unlike `_queue`.** This
        // step is the one a wind-down depends on: it shuts `borrow` so that the debt standing
        // behind the door can be repaid. Gating it on the full graph would make it refusable over
        // a stale `RECOUP_KEEPER` - an address that is *meant* to rotate - and refusing to shut
        // the door because a rotated keeper does not match an environment variable is a worse
        // trade than the one it would buy. `queue()` is where the operator commits to a window,
        // and that is where the full census belongs.
        _ownablesOf(d);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4PauseCalls(d);
        uint256 delay = timelock.getMinDelay();

        console.log("Phase-4 pause, as its own timelock batch. Run this BEFORE queue().");
        console.log("timelock          ", address(timelock));
        console.log("legs in this batch", targets.length);
        console.log("minimum delay (s) ", delay);
        console.log("attempt salt:");
        console.logBytes32(salt);
        console.log("operation id:");
        console.logBytes32(timelock.hashOperationBatch(targets, values, payloads, PREDECESSOR, salt));
        console.log("scheduleBatch calldata - ONE transaction, sent by the proposer:");
        console.logBytes(
            abi.encodeCall(
                TimelockController.scheduleBatch, (targets, values, payloads, PREDECESSOR, salt, delay)
            )
        );
        console.log("executeBatch calldata - ONE transaction, after the delay, sent by anyone:");
        console.logBytes(
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, PREDECESSOR, salt))
        );

        if (timelock.hasRole(timelock.PROPOSER_ROLE(), msg.sender)) {
            vm.startBroadcast();
            timelock.scheduleBatch(targets, values, payloads, PREDECESSOR, salt, delay);
            vm.stopBroadcast();
            console.log("Scheduled. Run --sig \"executeQueuedPause()\" after the delay, then \"queue()\".");
        } else {
            console.log("Sender holds no PROPOSER_ROLE: hand the scheduleBatch calldata above to whoever does.");
        }
    }

    /// @notice Execute the queued pause, and assert it actually landed.
    /// @dev Usage: forge script script/WirePhase4.s.sol:WirePhase4 --sig "executeQueuedPause()" --rpc-url base
    ///      The post-condition is the whole point of running this through the script rather than
    ///      firing the printed calldata.
    ///
    ///      **It asserts the pause and NOT the flat book, and that distinction is load-bearing
    ///      rather than an omission.** This step is what makes a wind-down possible: the operator
    ///      shuts the door precisely so that the debt standing behind it can be repaid without new
    ///      debt arriving. Reusing `queue()`'s full precondition here would abort step one on every
    ///      protocol that has users, which is every protocol this step exists for. `queue()` is
    ///      where the book has to be flat, because that is where the operator commits to a window.
    function executeQueuedPause() external {
        _requireConfirmation();
        _executeQueuedPause(
            _resolveDeployed(),
            TimelockController(payable(_required("RECOUP_TIMELOCK"))),
            vm.envOr("RECOUP_SWITCHOVER_ATTEMPT", bytes32(0))
        );
    }

    /// @dev Split from `executeQueuedPause()` for the reason `_queue` below gives.
    function _executeQueuedPause(Deployed memory d, TimelockController timelock, bytes32 salt) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4PauseCalls(d);

        vm.startBroadcast();
        timelock.executeBatch(targets, values, payloads, PREDECESSOR, salt);
        vm.stopBroadcast();

        _requireBothPaused(d);
        console.log("Borrowing and deposits are shut. Wind the book down, then run queue().");
    }

    /// @dev The pause half on its own: `executeQueuedPause`'s post-condition and the first clause of
    ///      `queue()`'s precondition, written once so the two cannot drift apart.
    function _requireBothPaused(Deployed memory d) internal view {
        bool creditPaused = d.credit.paused();
        bool vaultPaused = d.vault.paused();
        if (!creditPaused || !vaultPaused) revert SwitchoverNotPaused(creditPaused, vaultPaused);
    }

    /// @dev The three reads that decide whether a switchover window is safe to open.
    ///
    ///      **This is a generation-time check, and saying so is the point.** Nothing here runs when
    ///      the batch executes. What makes that adequate rather than decorative is that the state it
    ///      reads cannot be moved by a stranger afterwards: unpausing is `onlyOwner`, so under a
    ///      timelock it is itself a 48-hour operation, and with the pause in force `totalDebt` has
    ///      no source. The execution-time half is in the batch already - the trailing `unpause` legs
    ///      carry `whenPaused`, so a batch that fires against an unpaused protocol reverts
    ///      `ExpectedPause` and, being atomic, undoes itself.
    ///
    ///      **Three reads, and they are the complete set of preconditions the six legs evaluate.**
    ///      `settlePrincipal` no-ops at zero since round 21; `setLiquiditySource` refuses on
    ///      `totalDebt`, on `pendingPrincipal` - which the settle leg zeroes immediately before it,
    ///      inside the same atomic batch - and on `unsocialisedLoss`; `setLenderPool` refuses on
    ///      `unsocialisedLoss` and on an outgoing pool, of which there is none before Phase 4;
    ///      `EpochHarvester.setLenderPool` likewise. So a batch this function accepts is a batch
    ///      `executeBatch` will execute, and none of the three can rise again during the window:
    ///      `borrow` is shut, `totalDebt` is its only source, and `unsocialisedLoss` only fills
    ///      through `writeDownLoss` on a live position.
    ///
    ///      That is a claim about *this* list. Anyone adding a leg here owes this function a read.
    ///
    ///      **And it is a claim about the legs' STATE, not about their targets - audit round 22,
    ///      finding 7 read the sentence above literally and found the gap on the other side of it.**
    ///      Four of these reads come off two of the eight operator-typed addresses; the remaining
    ///      six were never touched before the operator committed to a window, and a codeless one
    ///      makes `executeBatch` succeed silently. That is checked in `_queue`, immediately above
    ///      the call to this function, by `_assertCoreGraph`. Do not fold the two together: this
    ///      one is about a window that can shut, that one is about a graph that exists.
    function _requireSwitchoverWindowShut(Deployed memory d) internal view {
        _requireBothPaused(d);

        uint256 debt = d.credit.totalDebt();
        if (debt != 0) revert SwitchoverBookNotFlat(debt);

        uint256 backlog = d.credit.unsocialisedLoss();
        if (backlog != 0) revert SwitchoverLossOutstanding(backlog);
    }

    /// @dev Split from `queue()` so it can be reached without the process environment.
    ///      `vm.setEnv` writes one table shared by every test in the process and `forge test` runs
    ///      a suite's functions in parallel, so an env-driven test of this function both races its
    ///      siblings and poisons them - measured, four failures in five, before this split existed.
    ///      Everything that decides anything is below this line; the two resolutions above are
    ///      covered by `test_wirePhase4_namesTheAddressItIsMissing`.
    function _queue(Deployed memory d, TimelockController timelock, GovParams memory p) internal {
        // **Audit round 22, finding 7: the batch's TARGETS are checked here now, not only its
        // preconditions.** `_requireSwitchoverWindowShut` below reads four values off two of the
        // eight operator-typed addresses, and used to say of itself that those were "the complete
        // set of preconditions the six legs actually evaluate". That is still true and it is not
        // the same claim as "the six legs will do what they say", because the other six addresses
        // were never touched before the operator committed to a window.
        //
        // MEASURED, with `RECOUP_EPOCH_HARVESTER` mistyped to a codeless address: OZ 5.6.1's
        // `TimelockController._execute` uses `Address.verifyCallResult`, **not**
        // `verifyCallResultFromTarget`, so it never asks whether the target has code - and a call
        // to a codeless address returns success with empty returndata. `queue()` scheduled without
        // complaint, an outsider fired the printed calldata after maturity, it SUCCEEDED,
        // `isOperationDone` went true, and the end state was `harvester.lenderPool() == address(0)`
        // with the protocol unpaused: round 11's shipped state - the pool carrying the credit risk
        // with the lender share going nowhere - reproduced by one typo. `cancel(id)` then reverts
        // `TimelockUnexpectedOperationState`, because a Done id is burned forever, so the recorded
        // recovery in this contract's header does not apply. That recovery covers a *reverting*
        // batch. This one does not revert.
        //
        // **The fix is a relocation, not a new predicate.** `_executeQueued` already ran
        // `_assertPhase4Wiring` in the same transaction and it already caught exactly this input -
        // `_ownablesOf` reverts `DeployedMemberNotOwnable(7)` on a member with no code, and the
        // whole transaction unwound including the timelock's `Done` write. The check was on the
        // wrong side of the forty-eight hour window, and it only ever protected the operator who
        // used the sanctioned entry point rather than the stranger who may fire `executeBatch`.
        //
        // `_assertCoreGraph` rather than `_ownablesOf` alone, because it is precisely the half of
        // `_assertPhase4Wiring` that is *already true* at queue time - the switchover moves none of
        // it - so running it early costs nothing and catches more than the codeless case: a member
        // typed as some other live contract of ours, an ownership handover that never happened, and
        // since round 22's finding 13, a pool on the wrong settlement token. The half that cannot
        // move is the three pointers the switchover exists to set, and those stay in
        // `_assertPhase4Wiring` where they belong.
        _assertCoreGraph(d, p);

        // **Round 21, finding 2: refuse to commit to a window nothing is guarding.** Every escape
        // from a blocked switchover costs the operator another forty-eight hours, so the cheapest
        // place to fail is here, before the clock starts. `queuePause()` is what satisfies this.
        _requireSwitchoverWindowShut(d);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4Calls(d);
        uint256 delay = timelock.getMinDelay();

        console.log("Phase-4 switchover, as one timelock batch.");
        console.log("timelock          ", address(timelock));
        console.log("legs in this batch", targets.length);
        console.log("minimum delay (s) ", delay);
        console.log("operation id:");
        console.logBytes32(timelock.hashOperationBatch(targets, values, payloads, PREDECESSOR, SALT));
        console.log("scheduleBatch calldata - ONE transaction, sent by the proposer:");
        console.logBytes(
            abi.encodeCall(
                TimelockController.scheduleBatch, (targets, values, payloads, PREDECESSOR, SALT, delay)
            )
        );
        console.log("executeBatch calldata - ONE transaction, after the delay, sent by anyone:");
        console.logBytes(
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, PREDECESSOR, SALT))
        );

        if (timelock.hasRole(timelock.PROPOSER_ROLE(), msg.sender)) {
            vm.startBroadcast();
            timelock.scheduleBatch(targets, values, payloads, PREDECESSOR, SALT, delay);
            vm.stopBroadcast();
            console.log("Scheduled. Run --sig \"executeQueued()\" after the delay, then \"assertOnly()\".");
        } else {
            console.log("Sender holds no PROPOSER_ROLE: hand the scheduleBatch calldata above to whoever does.");
        }
    }

    /// @notice Execute the queued switchover, as one transaction.
    /// @dev Usage: forge script script/WirePhase4.s.sol:WirePhase4 --sig "executeQueued()" --rpc-url base
    ///      Deliberately callable by anyone, because `executeBatch` is: the executor set is open by
    ///      design (there is no privileged party to wait on), and what round 20 found is that open
    ///      execution is only safe when there is nothing left to *order*. There is not.
    ///
    ///      The list is re-derived here rather than remembered, and since round 21 that is a free
    ///      operation rather than a hazard: `_phase4Calls` is `pure`, so the re-derivation cannot
    ///      disagree with the one `queue()` scheduled no matter what happened in the window. It used
    ///      to read `pendingPrincipal` live, which meant a stranger spending 42,744 gas on the
    ///      permissionless `settlePrincipal` could make this compute a *different* batch whose id
    ///      nobody had scheduled - `TimelockUnexpectedOperationState`, with the queued array dead on
    ///      its own third leg at the same time. Both routes closed, from one line in
    ///      `CreditManager.settlePrincipal`.
    ///
    ///      If this does refuse, the recovery is `cancel` then re-schedule, not a new salt. MEASURED
    ///      against this repo's pinned OZ: `cancel` frees the id and the identical call set
    ///      re-schedules with `SALT == bytes32(0)` intact, and the proposer holds `CANCELLER_ROLE`
    ///      by construction. The cost is another forty-eight hours, not permanence.
    function executeQueued() external {
        _requireConfirmation();
        Deployed memory d = _resolveDeployed();
        _executeQueued(
            d, TimelockController(payable(_required("RECOUP_TIMELOCK"))), _resolveParams(msg.sender)
        );
    }

    /// @dev Split from `executeQueued()` for the reason `_queue` above gives.
    function _executeQueued(Deployed memory d, TimelockController timelock, GovParams memory p) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4Calls(d);

        vm.startBroadcast();
        timelock.executeBatch(targets, values, payloads, PREDECESSOR, SALT);
        vm.stopBroadcast();

        _assertPhase4Wiring(d, p);
        console.log("Phase 4 wired and asserted, in one operation.");
    }

    /// @notice The post-condition on its own, for the case the switchover was queued rather than
    ///         sent - which is the case this protocol is heading for.
    /// @dev Usage: forge script script/WirePhase4.s.sol:WirePhase4 --sig "assertOnly()" --rpc-url base
    ///      Reverts with the same named `WiringIncomplete` reason a broadcast run would, so a
    ///      half-executed switchover is a legible failure rather than a silent one. Deliberately
    ///      not gated on the confirmation phrase: reading state changes nothing and an operator
    ///      should never be discouraged from checking.
    function assertOnly() external view {
        // **`_readParams`, not `_resolveParams`, and the difference is the whole point of the
        // docstring above.** Resolving runs `_validateParams`, and a read that refuses to answer
        // in the case it exists for is not a read.
        //
        // 🟥 **The rule this comment used to name is no longer here, corrected in audit round 38.**
        // It said "resolving runs `_validateParams`, which since round 29 refuses a deployment
        // owned by a contract with no guardian named". #352 moved that rule OUT of
        // `_validateParams` and into `DeployBase._validateNewDeployment`, whose only caller is
        // `_deployProtocol`, so it does not run on this path at all any more - not through
        // `_resolveParams`, and not through `run()`, `queue()` or `executeQueued()`. The reason to
        // read rather than resolve stands on the other rules `_validateParams` still applies;
        // it no longer stands on the guardian rule, because that rule is gone from here.
        //
        // 🟥 **And "the values are still the real ones ... so they cannot be faked" is now only
        // half true: they can be ABSENT.** #352 also stopped `RECOUP_OWNER` defaulting to the
        // caller off-local, so with it unset `p.owner` reads `address(0)` and `_assertCoreGraph`
        // reverts `OwnershipNotTransferred` naming the real, correct owner - a health report
        // reporting a failure that does not exist.
        //
        // FIXED HERE, and the fix is the MESSAGE rather than the behaviour. Refusing to run when
        // `RECOUP_OWNER` is unset would be the wrong direction: this is a read-only health report
        // and it is the tool an operator reaches for when they are not sure what is set. What it
        // must not do is blame the chain for a gap in the environment. So it names the missing
        // variable and stops, instead of reporting a wiring failure that does not exist.
        //
        // Zero runtime bytes: this file is a script and is never deployed.
        GovParams memory p = _readParams(msg.sender);
        if (p.owner == address(0)) revert OwnerNotNamedForReport();

        _assertPhase4Wiring(_resolveDeployed(), p);
        console.log("Phase-4 wiring holds.");
    }

    /// @dev A stray `forge script` should not be able to move the funder and the loss sink by
    ///      accident, which is the same reason the mainnet deploy target carries one. No chain
    ///      guard, though: unlike a deployment this is legitimate on a testnet, on a fork and on
    ///      anvil, and a chain allow-list here would have to be edited every time it is exercised.
    function _requireConfirmation() internal view {
        if (keccak256(bytes(_envOrString("RECOUP_SWITCHOVER_CONFIRM", ""))) != keccak256(bytes(CONFIRM_PHRASE))) {
            revert SwitchoverConfirmationMissing();
        }
    }

    function _resolveDeployed() internal view returns (Deployed memory d) {
        d.oracle = NAVOracle(_required("RECOUP_NAV_ORACLE"));
        d.vault = CollateralVault(_required("RECOUP_COLLATERAL_VAULT"));
        d.adapter = DirectCallAdapter(_required("RECOUP_CUSTODY_ADAPTER"));
        d.credit = CreditManager(_required("RECOUP_CREDIT_MANAGER"));
        d.pool = LenderPool(_required("RECOUP_LENDER_POOL"));
        d.liquidity = TreasuryLiquiditySource(_required("RECOUP_LIQUIDITY_SOURCE"));
        d.harvester = EpochHarvester(_required("RECOUP_EPOCH_HARVESTER"));
        d.auction = LiquidationAuction(_required("RECOUP_LIQUIDATION_AUCTION"));
        // Derived rather than read from a ninth environment variable, deliberately. The pointer is
        // `immutable` on all three readers, so the deployment already knows the answer and asking
        // an operator to retype it would be inviting a typo that `_assertCoreGraph` would then
        // correctly refuse at the end of a switchover. One fewer address to transcribe is one fewer
        // way to get a switchover wrong.
        //
        // **Off the vault, and audit round 20 is why it moved.** It used to read the *manager*,
        // which made `_assertCoreGraph`'s "all three risk readers agree" assertion anchored to
        // whichever manager the operator named - so the one address the assertion could never
        // catch being wrong was the one it derived its expectation from. The vault is the only
        // contract in the graph with no setter anywhere and no replacement path, so anchoring
        // there is the one choice that cannot be moved by a bad environment variable.
        d.riskParams = RiskParams(address(d.vault.riskParams()));
    }

    /// @dev Named in the revert, because "one of the addresses is unset" is not an error message
    ///      anybody can act on.
    function _required(string memory name) internal view returns (address a) {
        a = _envOrAddress(name, address(0));
        if (a == address(0)) revert DeployedAddressMissing(name);
    }
}
