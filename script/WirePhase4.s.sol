// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "./DeployBase.sol";
import {Config} from "../src/Config.sol";
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
///      🟥 **"Addresses come from the environment rather than from a deployment record, because by
///      the time this runs the deployment is history and the operator has the addresses in front of
///      them" USED TO STAND HERE, and audit round 50 item 134 found it was the defect rather than
///      the design.** It is the right argument for a value that MOVES and the wrong one for a value
///      that identifies WHICH deployment this is. Every other check in this file is relative - it
///      asks whether the eight addresses agree with each other and with `GovParams` - and a
///      superseded generation agrees with itself perfectly, so a self-consistent stale set passed
///      `_assertCoreGraph`, `queuePause()` and `queue()` with everything green.
///
///      **The record is opened now** (`_resolveDeployed`, `_resolveParamsAgainstRecord`,
///      `_requiredTimelock`), the environment is an override that must AGREE, and a disagreeing
///      pair is refused by name with both values. Every address is still required: there is no
///      local fallback off anvil, unlike `_resolveParams`, because there is no such thing as a
///      switchover on a protocol that was not deployed - and since round 50 there is no such thing
///      as one on a deployment nobody recorded either.
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

    /// @dev Round-50 item 134. `_resolveDeployed` built the whole graph out of eight environment
    ///      variables and never opened the committed deployment record, so a SELF-CONSISTENT stale
    ///      generation - the 2026-08-03 set, say, whose nine addresses all point at each other -
    ///      passed `_assertCoreGraph`, `queuePause()` and `queue()` with every assertion green and
    ///      scheduled a switchover on the wrong deployment. Every check in this file is relative:
    ///      it asks whether the addresses agree WITH EACH OTHER, and a superseded generation agrees
    ///      with itself perfectly. The record is the one absolute the operator is not retyping.
    ///
    ///      The same shape as `AssertLocked`'s `KeeperEnvDisagreesWithRecord` (round-47 item 95),
    ///      and the same disposition: the record is the side asserted against, an environment value
    ///      is checked AGAINST it rather than read INSTEAD of it, an agreeing value is tolerated
    ///      because the documented commands run against one `.env` that forge auto-loads, and a
    ///      disagreeing one is named with both values so a stale `.env` reads as a stale `.env`
    ///      rather than as a wiring failure whose stated remedy is a redeploy.
    error DeployedEnvDisagreesWithRecord(string name, address env, address record);

    // `DeployedRecordRowMissing(string name, string jsonPath)` moved to `DeployBase` in round 54
    // so `AssertLocked` can raise it too; the docstring went with it. MEASURED: an inherited error
    // is NOT reachable as `WirePhase4.DeployedRecordRowMissing` (solc 9582), so tests qualify it
    // as `DeployBase.DeployedRecordRowMissing`.

    /// @dev Round 52, the mirror of round 51's `AssertLocked.NoCodeAt` on the switchover path, and
    ///      it is ONE ROW WIDE. `_assertCoreGraph` opens with `_ownablesOf`, which names a codeless
    ///      member `DeployedMemberNotOwnable(index)`, so seven of the eight resolved addresses fail
    ///      by name when they point at nothing. The eighth is the vault: `_resolveDeployed` derives
    ///      `riskParams` off it (`d.vault.riskParams()`) before any census runs, and a high-level
    ///      call expecting return data from a codeless address dies with an EMPTY revert. MEASURED:
    ///      a codeless `contracts.CollateralVault` row killed `assertOnly()` with no data at all,
    ///      while the same row for `contracts.CreditManager` was named by index. Carries the
    ///      `RECOUP_*` name and the address, the way `NoCodeAt` carries the JSON path, so the
    ///      operator is told which row and what it held. The remedy differs from every sibling
    ///      error here: not an unset variable, not a disagreement, not an incomplete record, but a
    ///      record row that names an address on the WRONG CHAIN or a contract that was never
    ///      deployed there.
    error DeployedAddressHasNoCode(string name, address target);

    /// @dev Round 53, the mirror of the round-52 vault dereference one function over: `RECOUP_TIMELOCK`
    ///      is dereferenced by every one of the four timelock entry points (`getMinDelay()`,
    ///      `hashOperationBatch`, `scheduleBatch`, `executeBatch`) and nothing asked whether the
    ///      address ANSWERS as a timelock. A codeless stranger was named `TimelockIsNotTheOwner`
    ///      by luck of ordering; the owner itself, named as the timelock while it is still an EOA
    ///      (the deployment that exists today), passed that check and died EMPTY on `getMinDelay()`.
    ///      A coded owner that is not a timelock - a Safe - is the same shape and is what this
    ///      error is for; the codeless case is `DeployedAddressHasNoCode("RECOUP_TIMELOCK", t)`.
    ///      One `staticcall`, the `_settlementDecimals` way, on the dereference's own selector.
    error TimelockDoesNotAnswer(address timelock);

    /// @dev The switchover has no meaning without the record it is a switchover OF. Local chains
    ///      are the one exception and `_deploymentRecord` states it explicitly.
    error DeploymentRecordMissing(string path);

    /// @dev The record names one network. Without this, a run on any other chain would compare a
    ///      live deployment against Base Sepolia's addresses and refuse every one of them with
    ///      `DeployedEnvDisagreesWithRecord` - a true statement about the wrong subject. Named
    ///      separately so the operator is told the record does not describe this chain rather than
    ///      that their environment is wrong. Same error, same reason, as `AssertLocked`'s.
    error RecordChainMismatch(uint256 recordChainId, uint256 actualChainId);

    /// @dev Round-49 finding. `RECOUP_TIMELOCK` was resolved and never compared with the owner of
    ///      the graph it was about to schedule on: both censuses compare the chain's owner with
    ///      `p.owner`, and neither asked whether the timelock IS that owner. So an environment
    ///      naming a timelock that owns nothing passed `queuePause()` and `queue()`, scheduled on
    ///      it, and the refusal arrived forty-eight hours later from `executeBatch` -
    ///      `NotOwnerOrGuardian()` on the pause batch, `OwnableUnauthorizedAccount(timelock)` on
    ///      the switchover - with the protocol left PAUSED by a correctly executed step one and
    ///      the correct re-queue costing a third maturity. Checked against `d.credit.owner()`,
    ///      the one member both batches touch, before anything is scheduled.
    error TimelockIsNotTheOwner(address timelock, address actualOwner);

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

    /// @notice The line that says who can fire the printed `executeBatch`, asked of the timelock
    ///         rather than assumed.
    /// @dev **Round-51 item 170. Both entry points printed "sent by anyone" UNCONDITIONALLY, and
    ///      that is a statement about `EXECUTOR_ROLE` that this file never read.** "Anyone" is true
    ///      only while the role is held by `address(0)`, which is how `Governance.t.sol` and every
    ///      fixture in this repository deploy a `TimelockController` and is NOT a property of the
    ///      contract: OZ's `onlyRoleOrOpenRole` falls back to the caller's own membership when the
    ///      open role is not granted. A closed set is one constructor argument away, and a
    ///      governance setup that grants execution to a named committee is an ordinary choice.
    ///
    ///      MEASURED with `executors = [someContract]`: `queuePause()` accepted, printed "sent by
    ///      anyone", `scheduleBatch` landed, and a full maturity later `executeQueuedPause()`
    ///      reverted `AccessControlUnauthorizedAccount(DEFAULT_SENDER, EXECUTOR_ROLE)` with nothing
    ///      paused and the operation `Ready` forever - `TimelockController` has no grace period.
    ///      That is round 21's armed-replay shape reached by a ROLE rather than by state.
    ///
    ///      **A warning and not a refusal, deliberately.** A closed executor set is a legitimate
    ///      governance choice and the batch is perfectly executable by whoever holds the role; what
    ///      was wrong is the sentence, not the state. Refusing here would refuse a correct setup.
    ///      One `staticcall`, zero runtime bytes.
    ///      **Written as a PREDICATE plus a string rather than as a `console.log` in place, and
    ///      that is not a style choice.** MEASURED: `vm.expectCall` does NOT observe forge-std's
    ///      console `staticcall` - four arms written that way reported `called 0 times` against
    ///      lines the run had printed - and `console.log` emits no event, so `vm.recordLogs` sees
    ///      nothing either. A printed line with no seam is a line no test can hold to the tree.
    ///      These two `internal view` members are that seam, and the tests assert them directly.
    function _executionIsOpen(TimelockController timelock) internal view returns (bool) {
        return timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0));
    }

    function _executeAudienceLine(TimelockController timelock) internal view returns (string memory) {
        if (_executionIsOpen(timelock)) {
            return "executeBatch calldata - ONE transaction, after the delay, sent by anyone (EXECUTOR_ROLE is open):";
        }
        return
            "executeBatch calldata - ONE transaction, after the delay, sent by an EXECUTOR_ROLE holder (execution is NOT open):";
    }

    /// @dev The half the operator needs before they commit to a maturity: whether the key in front
    ///      of them can fire what it is about to schedule. Asked with `msg.sender`, the same party
    ///      the `PROPOSER_ROLE` branch below asks about, so the two lines are about one key.
    function _senderCanExecute(TimelockController timelock) internal view returns (bool) {
        return _executionIsOpen(timelock) || timelock.hasRole(timelock.EXECUTOR_ROLE(), msg.sender);
    }

    /// @notice Whether the timelock's own minimum delay leaves any maturity window at all.
    /// @dev **Round-51 item 150, lead 1. `getMinDelay()` is read, printed, and checked by nothing -
    ///      while this file reasons in six docstring paragraphs from a window that at zero does not
    ///      exist.** "For the whole 48-hour maturity the door was open"; "the only span in which
    ///      anybody could have created the debt that blocks it"; the entire argument for splitting
    ///      the pause into its own earlier operation (round 21, finding 2) is an argument about a
    ///      DURATION. MEASURED with `minDelay == 0`: `queuePause()` -> `executeQueuedPause()` ->
    ///      `queue()` -> `executeQueued()` all land in ONE BLOCK, `block.timestamp` unmoved at the
    ///      end, and the pause operation protects a zero-length span - round 20's finding 5 restored
    ///      by configuration.
    ///
    ///      **A warning and not a refusal, and the distinction is where the defect actually is.**
    ///      `minDelay` is the owner's parameter; `TimelockController` permits zero by construction
    ///      and `updateDelay` is reachable only through the timelock itself, so the number is
    ///      whatever governance decided. A hard floor of `Config.ADMIN_TIMELOCK` would refuse a
    ///      legitimate rehearsal, a testnet, and any protocol that has deliberately chosen a shorter
    ///      delay. What is NOT a governance opinion is that this file prints the number that makes
    ///      its own paragraphs false and says nothing about it.
    ///
    ///      A predicate rather than a bare `console.log`, for the reason recorded above: forge does
    ///      not surface a console `staticcall` to `vm.expectCall`, so a printed line with no seam is
    ///      a line no test can hold to the tree.
    function _delayLeavesNoWindow(uint256 delay) internal pure returns (bool) {
        return delay == 0;
    }

    /// @dev Round 55 (round-54 item 197, costed as round-55 item 225(ii)): the OTHER end of the
    ///      same read. `k = 15`, so the ceiling is `15 * Config.ADMIN_TIMELOCK = 30 days`, and the
    ///      number is borrowed rather than invented: 30 days is Compound's `Timelock.MAXIMUM_DELAY`,
    ///      the widest ceiling a widely-deployed timelock enforces in code, and `TimelockController`
    ///      enforces none. Above it the operation cannot mature inside any switchover anybody would
    ///      plan, and because `updateDelay` is itself an operation under the same delay, neither
    ///      can the repair - a hundred-year delay is a hundred years to shorten it. A multiple of
    ///      `ADMIN_TIMELOCK` rather than a bare duration, so the ceiling moves with the protocol's
    ///      own delay if that constant ever does.
    ///
    ///      A WARNING and not a refusal, for the reason `_delayLeavesNoWindow` gives one function
    ///      up: `minDelay` is governance's parameter, and a refusal here would leave no repair path
    ///      through this script at all, since shortening the delay is the same kind of operation.
    ///      Zero runtime bytes, this file is never deployed.
    uint256 internal constant MAX_SENSIBLE_DELAY_MULTIPLE = 15;

    function _delayExceedsCeiling(uint256 delay) internal pure returns (bool) {
        return delay > MAX_SENSIBLE_DELAY_MULTIPLE * Config.ADMIN_TIMELOCK;
    }

    function _warnIfDelayLeavesNoWindow(uint256 delay) internal pure {
        if (_delayExceedsCeiling(delay)) {
            console.log("WARNING: this timelock's minimum delay exceeds the ceiling this script expects,");
            console.log("         which is", MAX_SENSIBLE_DELAY_MULTIPLE * Config.ADMIN_TIMELOCK, "seconds (30 days).");
            console.log("         The operation scheduled here cannot mature inside any switchover");
            console.log("         anybody would plan, and updateDelay is itself an operation under");
            console.log("         the same delay, so the repair waits just as long. A governance");
            console.log("         parameter and not an error - but check the number before scheduling.");
        }
        if (!_delayLeavesNoWindow(delay)) return;
        console.log("WARNING: this timelock's minimum delay is ZERO, so there is no maturity window.");
        console.log("         Both operations mature in the block they are scheduled in, and the");
        console.log("         pause this step puts in force ahead of the switchover protects a");
        console.log("         zero-length span. That is a governance parameter and not an error -");
        console.log("         but every timing argument in this script assumes a window, and at");
        console.log("         zero there is none.");
    }

    function _warnIfSenderCannotExecute(TimelockController timelock) internal view {
        if (_senderCanExecute(timelock)) return;
        console.log("WARNING: execution is NOT open and this sender holds no EXECUTOR_ROLE, so this");
        console.log("         key cannot fire the batch it is scheduling. Line up an executor BEFORE");
        console.log("         the delay runs out: a matured operation nobody can execute stays Ready");
        console.log("         forever, and TimelockController has no grace period.");
    }

    /// @notice Wire the switchover, then assert the state it must leave behind.
    /// @dev **The EOA-owner entry point.** Every leg is broadcast as its own transaction from the
    ///      owning key, in `_phase4Calls` order, with the pause first - which is what makes the gap
    ///      unreachable in that register. Under a timelock this is the wrong function: use
    ///      `queue()`, and read finding 5 in this contract's header for why.
    function run() external {
        _requireConfirmation();
        Deployed memory d = _resolveDeployed();
        GovParams memory p = _resolveParamsAgainstRecord(msg.sender);

        vm.startBroadcast();
        _wirePhase4(d);
        vm.stopBroadcast();

        _assertPhase4Wiring(d, p);
        _log(d, p);
        console.log("Phase 4 wired: the pool funds the book and takes the losses.");
        // **Round-51 item 149.** That sentence, and the assertion above it, are statements about
        // the SIMULATION. `forge script` executes `run()` exactly once, before a single transaction
        // is sent, so everything after `vm.stopBroadcast()` is after the broadcast in SOURCE ORDER
        // and nowhere else. `AssertLocked.s.sol`'s header carries the measurement, 3 of 3 against a
        // local anvil: with the transactions among those the node discarded, a script printed
        // `ONCHAIN EXECUTION COMPLETE and SUCCESSFUL`, exited 0, and the stack shipped open.
        //
        // Three DIFFERENT lines, one per broadcast entry point, because the right next command
        // differs and a shared sentence would be wrong on two of the three.
        console.log("VERIFY ON CHAIN: everything above ran in the SIMULATION. Once the transactions");
        console.log("                 are mined, re-run --sig \"assertOnly()\" with NO --broadcast.");
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
    ///      batch executes as the owner, so a graph the timelock does not own cannot execute it.
    ///      **Until round 49 nothing here found that out.** `_queue`'s census compares the chain's
    ///      owner with `p.owner` and never with `RECOUP_TIMELOCK`, so a timelock that owned
    ///      nothing was scheduled on and refused forty-eight hours later by `executeBatch`.
    ///      `TimelockIsNotTheOwner` is now the refusal, in `_queuePause` and `_queue` both,
    ///      before anything is scheduled.
    function queue() external {
        _requireConfirmation();
        _queue(
            _resolveDeployed(),
            TimelockController(payable(_requiredTimelock())),
            _resolveParamsAgainstRecord(msg.sender)
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
            TimelockController(payable(_requiredTimelock())),
            _envOrBytes32("RECOUP_SWITCHOVER_ATTEMPT", bytes32(0))
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
        // Round-49 finding: the liveness census says the members are live and says nothing about
        // WHO the batch will execute as. `pause()` is owner-or-guardian on both targets, so a
        // timelock that is not the owner schedules a batch that refuses at maturity.
        //
        // 🟥 **Round-50, and this line used to ask about ONE of the batch's TWO targets.** It read
        // `if (d.credit.owner() != address(timelock))`, while `_phase4PauseCalls` builds
        // `[credit.pause(), vault.pause()]`. In `_queue` that is redundant, because
        // `_assertCoreGraph` runs immediately above it and holds every member to `p.owner`. Here
        // there is no such census ON PURPOSE - this step is the one a wind-down depends on and
        // gating it on the full graph would make it refusable over a rotated keeper - so the one
        // place the line was load-bearing was the one place it covered half its batch. THREE audit
        // agents reached this independently. MEASURED: with the vault transferred away from the
        // timelock (an interrupted G2 handover, which is nine separate `transferOwnership`
        // transactions), `queuePause()` accepted, `scheduleBatch` landed, and forty-eight hours
        // later `executeBatch` refused `NotOwnerOrGuardian()` from the vault leg - atomically
        // undoing the credit leg that had succeeded, leaving nothing paused and the operation
        // `Ready` forever as an armed replay. That is round 21's shape, reproduced by the guard
        // that was added to prevent it.
        //
        // **DERIVED FROM THE BATCH, so it cannot fall behind `_phase4PauseCalls`.** A second
        // hand-written clause naming the vault would have been correct today and silently
        // incomplete the day a third leg is added; this asks the question of whatever the list
        // actually contains.
        //
        // **STRICT owner, and the guardian is deliberately NOT admitted - an accepted residual
        // rather than an oversight.** `pause()` is owner-or-guardian, so a timelock holding only
        // the guardian role COULD execute this batch and is refused here. Two measurements decided
        // it: `guardian()` REVERTS on all nine live Base Sepolia addresses, whose bytecode predates
        // the guardian pair, and `_queuePause` is the one entry point in this file that reads no
        // `guardian()` at all - so a tolerant form would make the wind-down step inoperable against
        // the deployment that exists. And nothing is lost downstream: `_assertCoreGraph` at
        // `queue()` holds the guardian to `p.guardian` two steps later regardless, so a
        // guardian-only timelock is refused there whatever this line says.
        for (uint256 i = 0; i < targets.length; ++i) {
            address targetOwner = Ownable(targets[i]).owner();
            if (targetOwner != address(timelock)) revert TimelockIsNotTheOwner(address(timelock), targetOwner);
        }

        uint256 delay = timelock.getMinDelay();

        console.log("Phase-4 pause, as its own timelock batch. Run this BEFORE queue().");
        console.log("timelock          ", address(timelock));
        console.log("legs in this batch", targets.length);
        console.log("minimum delay (s) ", delay);
        _warnIfDelayLeavesNoWindow(delay);
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
        console.log(_executeAudienceLine(timelock));
        console.logBytes(
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, PREDECESSOR, salt))
        );
        _warnIfSenderCannotExecute(timelock);

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
            TimelockController(payable(_requiredTimelock())),
            _envOrBytes32("RECOUP_SWITCHOVER_ATTEMPT", bytes32(0))
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
        // Round-51 item 149, and this is the one entry point where the obvious advice would be
        // WRONG. `_requireBothPaused` above ran in the SIMULATION like everything else, but
        // `assertOnly()` cannot be the verification here: the switchover pointers are still unset
        // and `_assertPhase4Wiring` refuses a paused protocol with `SwitchoverLeftPaused`. So this
        // one names the two reads that ARE true of this step.
        console.log("VERIFY ON CHAIN: that ran in the SIMULATION, and --sig \"assertOnly()\" will NOT");
        console.log("                 pass yet. Confirm the pause with cast call <credit> \"paused()\"");
        console.log("                 and cast call <vault> \"paused()\" before running queue().");
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
    ///      **Three reads, and they are the complete set of the six legs' STATE preconditions -
    ///      which is deliberately weaker than the claim that stood here until audit round 40,
    ///      item 7.** `settlePrincipal` no-ops at zero since round 21; `setLiquiditySource`
    ///      refuses on `totalDebt` and on `unsocialisedLoss`; `setLenderPool` refuses on
    ///      `unsocialisedLoss` and on an outgoing pool, of which there is none before Phase 4;
    ///      `EpochHarvester.setLenderPool` likewise. None of the three can rise again during the
    ///      window: `borrow` is shut, `totalDebt` is its only source, and `unsocialisedLoss` only
    ///      fills through `writeDownLoss` on a live position.
    ///
    ///      🟥 **"So a batch this function accepts is a batch `executeBatch` will execute" used
    ///      to close that paragraph. It is RETRACTED, and it has an executed counterexample.** It
    ///      rested on `setLiquiditySource` refusing on `pendingPrincipal` - "which the settle leg
    ///      zeroes immediately before it, inside the same atomic batch" - and PR #242 deleted
    ///      that clause on 2026-08-20. The setter **handles** that balance instead, best-effort
    ///      delivering it to the outgoing source and parking the residue as
    ///      `owedToSource[outgoing]`. The refusal that is left lives in the **settle leg**, which
    ///      is the hard delivery, and it turns on something no read in this function performs:
    ///      whether the OUTGOING source will accept USDC. Every completeness probe this protocol
    ///      runs on a swap is aimed at the INCOMING pointer.
    ///
    ///      MEASURED, with the outgoing `TreasuryLiquiditySource` blocked in `MockUSDC` on a book
    ///      carrying `totalDebt == 0` and `pendingPrincipal == 500000000`: this function
    ///      **accepted** the state and ran past `_assertCoreGraph` as well, and the committed
    ///      batch then reverted in the settle leg with `Blocked(...)`, leaving `liquiditySource`
    ///      unmoved, the protocol paused, and the timelock operation `Ready` - an armed replay,
    ///      the round-21 shape. The identical batch with the settle leg dropped executed clean.
    ///
    ///      That is a claim about *this* list. Anyone adding a leg here owes this function a read.
    ///      🟥 **And the inverse is the one that actually bit, so read it as the standing
    ///      warning: a leg's own PRECONDITION changed underneath it.** No leg was added, removed
    ///      or reordered. #242 corrected the source of truth in `CreditManager` and left four
    ///      prose copies standing, this being one of them, for three audit rounds.
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
        // Round-49 finding: the census above proves the chain's owner is `p.owner` and never asks
        // whether `timelock` is that owner. The six legs execute as the owner, so a timelock that
        // is not the owner schedules a batch `executeBatch` refuses at maturity - after step one
        // has already shut the protocol for a full maturity.
        if (d.credit.owner() != address(timelock)) revert TimelockIsNotTheOwner(address(timelock), d.credit.owner());

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
        _warnIfDelayLeavesNoWindow(delay);
        console.log("operation id:");
        console.logBytes32(timelock.hashOperationBatch(targets, values, payloads, PREDECESSOR, SALT));
        console.log("scheduleBatch calldata - ONE transaction, sent by the proposer:");
        console.logBytes(
            abi.encodeCall(
                TimelockController.scheduleBatch, (targets, values, payloads, PREDECESSOR, SALT, delay)
            )
        );
        console.log(_executeAudienceLine(timelock));
        console.logBytes(
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, PREDECESSOR, SALT))
        );
        _warnIfSenderCannotExecute(timelock);

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
            d, TimelockController(payable(_requiredTimelock())), _resolveParamsAgainstRecord(msg.sender)
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
        // Round-51 item 149. "Asserted" is true of the simulation; the batch itself is what the
        // node may or may not have mined, and `_assertPhase4Wiring` above cannot tell you which.
        console.log("VERIFY ON CHAIN: the assertion above ran in the SIMULATION. Once executeBatch is");
        console.log("                 mined, re-run --sig \"assertOnly()\" with NO --broadcast.");
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
        //
        // **Round-53 item 183: read AGAINST THE RECORD, not only the environment.** `_readParams`
        // alone reported an environment gap as a chain failure: a wrong `RECOUP_OWNER` as
        // `OwnershipNotTransferred` against a handover that succeeded, a stale `RECOUP_KEEPER` as
        // `WiringIncomplete("oracle.keeper")` over an oracle that agrees with the committed record.
        // The record fills an unset row and refuses a disagreeing one by name, so the report reads
        // "your `.env` is stale" where it used to read "the chain is mis-wired". A row the record
        // lacks still falls through to the environment, which is how an operator reports on a
        // deployment newer than the record - by saying so in the environment AND updating the
        // record, the same act `_resolveDeployed` asks for.
        GovParams memory p = _readParamsAgainstRecord(msg.sender);
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

    /// @dev **Round-50 item 134: the record is opened first, and the environment is checked
    ///      against it rather than read instead of it.** The docstring at the head of this
    ///      contract used to argue the other way - "addresses come from the environment rather
    ///      than from a deployment record, because by the time this runs the deployment is history
    ///      and the operator has the addresses in front of them" - and that argument is exactly
    ///      backwards for the failure it admits. Every other check here is RELATIVE: it asks
    ///      whether these eight addresses agree with each other and with `p`. A superseded
    ///      generation agrees with itself, so `_assertCoreGraph` passes, the window census passes,
    ///      and the batch is scheduled against the deployment that was replaced.
    ///
    ///      **`RECOUP_NAV_ORACLE` and the other seven are still read**, so a deployment newer than
    ///      the committed record can still be switched over - by an operator who says so in the
    ///      environment AND updates the record, which is one act rather than two. What is gone is
    ///      the silent case where the record was never consulted at all.
    function _resolveDeployed() internal view returns (Deployed memory d) {
        string memory j = _deploymentRecord();
        d.oracle = NAVOracle(_resolveOne("RECOUP_NAV_ORACLE", ".contracts.NAVOracle", j));
        d.vault = CollateralVault(_resolveOne("RECOUP_COLLATERAL_VAULT", ".contracts.CollateralVault", j));
        d.adapter = DirectCallAdapter(_resolveOne("RECOUP_CUSTODY_ADAPTER", ".contracts.DirectCallAdapter", j));
        d.credit = CreditManager(_resolveOne("RECOUP_CREDIT_MANAGER", ".contracts.CreditManager", j));
        d.pool = LenderPool(_resolveOne("RECOUP_LENDER_POOL", ".contracts.LenderPool", j));
        d.liquidity =
            TreasuryLiquiditySource(_resolveOne("RECOUP_LIQUIDITY_SOURCE", ".contracts.TreasuryLiquiditySource", j));
        d.harvester = EpochHarvester(_resolveOne("RECOUP_EPOCH_HARVESTER", ".contracts.EpochHarvester", j));
        d.auction =
            LiquidationAuction(_resolveOne("RECOUP_LIQUIDATION_AUCTION", ".contracts.LiquidationAuction", j));
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
        //
        // Round 52: the vault is dereferenced HERE, before `_assertCoreGraph`'s `_ownablesOf` has
        // had the chance to name a codeless member, so it is the one address a code check has to
        // guard in this function. The other seven are deliberately left to `_ownablesOf`, which
        // already names them by index; a check on all eight in `_resolveOne` would shadow that
        // error rather than add to it. The local path (`_required`) reaches this line too, so the
        // check sits on the dereference and not on the record read.
        if (address(d.vault).code.length == 0) {
            revert DeployedAddressHasNoCode("RECOUP_COLLATERAL_VAULT", address(d.vault));
        }
        d.riskParams = RiskParams(address(d.vault.riskParams()));
    }

    /// @dev Named in the revert, because "one of the addresses is unset" is not an error message
    ///      anybody can act on.
    function _required(string memory name) internal view returns (address a) {
        a = _envOrAddress(name, address(0));
        if (a == address(0)) revert DeployedAddressMissing(name);
    }

    // ── the record (audit round 50, item 134) ────────────────────────────────

    /// @dev Same path convention as `AssertLocked.RECORD`, and deliberately the same string rather
    ///      than a shared constant: the two files are read by different people at different times
    ///      and a shared constant would let one of them move the other's input silently.
    string internal constant RECORD = "deployments/base-sepolia.json";

    /// @dev The seam, for exactly the reason `AssertLocked._readRecord` is one: a harness overrides
    ///      it with an inline JSON string, so `forge test` touches no filesystem and depends on no
    ///      committed record, while a real run reads the file. `fs_permissions` in `foundry.toml`
    ///      already grants `read` on `deployments` for `AssertLocked`, so this needs no new grant.
    ///
    ///      **Returns the empty string for an ABSENT file rather than reverting**, so the absence
    ///      is refused by name one level up instead of by forge's own file error. The residual is
    ///      the same one `AssertLocked` records and accepts: the base implementation reads the real
    ///      disk and is exercised only on a real run.
    function _readRecord() internal view virtual returns (string memory) {
        if (!vm.exists(RECORD)) return "";
        return vm.readFile(RECORD);
    }

    /// @dev The record, or the empty string on a local chain - which is the ONE case where there is
    ///      nothing to check against, stated here rather than left implicit. Anvil has no committed
    ///      deployment and never will; every rehearsal builds its own graph in memory and passes it
    ///      in. Off-local the record is required, because a switchover is an operation ON a
    ///      recorded deployment and there is no such thing as one on a deployment nobody recorded.
    function _deploymentRecord() internal view returns (string memory j) {
        if (_isLocal()) return "";
        j = _readRecord();
        if (bytes(j).length == 0) revert DeploymentRecordMissing(RECORD);
        // Round 54: named before it is parsed, the `_resolveOne` way. A record with no `chainId`
        // died inside forge's JSON parser as `CheatcodeError(string)` - one row earlier than every
        // row `_resolveOne` guards, and the row every other check is keyed on.
        _requireRecordRow(j, "chainId", ".chainId");
        uint256 recordChain = vm.parseJsonUint(j, ".chainId");
        if (recordChain != block.chainid) revert RecordChainMismatch(recordChain, block.chainid);
    }

    /// @dev One address, resolved the round-47 item-95 way: the record is the side asserted
    ///      against, the environment is an override that must AGREE, and a disagreement is named
    ///      with both values. An empty `record` is the local case and falls back to the
    ///      environment-only path this function replaced.
    function _resolveOne(string memory name, string memory jsonPath, string memory record)
        internal
        view
        returns (address)
    {
        if (bytes(record).length == 0) return _required(name);
        // 🟥 **This line used to be `return _required(name);` and that was round-50 item 134's fix
        // switched off, silently, one member at a time.** The comment above it argued that a record
        // which does not name this contract "is the same failure as an unset variable and gets the
        // same error" - true only when the variable is also unset, and the case that matters is the
        // one where it is set. MEASURED: seven rows on the record and an eighth from the
        // environment naming a superseded generation resolved with no warning at all. An incomplete
        // record now fails LOUDLY, which is the whole disposition of item 134.
        if (!vm.keyExistsJson(record, jsonPath)) revert DeployedRecordRowMissing(name, jsonPath);
        // Round 55: through the checked door, so a wrong-checksum row is `AddressChecksumInvalid`
        // by name rather than an address the chain contradicts (round-55 item 225(i)).
        address fromRecord = _recordAddress(record, name, jsonPath);
        address fromEnv = _envOrAddress(name, fromRecord);
        if (fromEnv != fromRecord) revert DeployedEnvDisagreesWithRecord(name, fromEnv, fromRecord);
        if (fromRecord == address(0)) revert DeployedAddressMissing(name);
        return fromRecord;
    }

    /// @dev `_resolveParams` with the record folded in between its two halves (read, hold to the
    ///      record, validate; round 54 says why below), plus the one operator the record holds that
    ///      this file depends on.
    ///      `RECOUP_OWNER` is the address every census in `DeployBase` compares the chain against,
    ///      so an environment naming the wrong owner does not fail - it makes `_assertCoreGraph`
    ///      report a wiring failure that does not exist, which is the shape `assertOnly`'s own
    ///      `OwnerNotNamedForReport` was added for one variable over.
    function _resolveParamsAgainstRecord(address sender) internal view returns (GovParams memory p) {
        p = _readParams(sender);
        string memory j = _deploymentRecord();
        if (bytes(j).length == 0) {
            _validateParams(p, sender);
            return p;
        }
        // **Round 51: the key lookup `_resolveOne` and `_requiredTimelock` both have, and this line
        // did not.** MEASURED before it: a record whose `operators` object is empty died inside
        // forge's JSON parser rather than at a named error - the same class as
        // `OwnerNotNamedForReport`, which exists two functions away precisely because "a health
        // report inventing a wiring failure out of an unset variable" was judged worth its own
        // error. Unlike `_requiredTimelock`, an absent row here is a REFUSAL rather than a
        // tolerated gap: the record does carry `operators.owner`, and `RECOUP_OWNER` is the address
        // every census in `DeployBase` compares the chain against.
        if (!vm.keyExistsJson(j, ".operators.owner")) {
            revert DeployedRecordRowMissing("RECOUP_OWNER", ".operators.owner");
        }
        // **Round-53 item 183: the other four operator rows, held the same way.** This function
        // compared ONE of the five rows the record carries. A stale `RECOUP_KEEPER` is
        // `DeployedEnvDisagreesWithRecord("RECOUP_KEEPER", env, record)` before anything is
        // scheduled, where it used to be `WiringIncomplete("oracle.keeper")` from `_assertCoreGraph`
        // - the chain blamed for an environment that had rotted.
        //
        // **Round 54: read, hold to the record, THEN validate - the order this function had was
        // validate, then fill.** `_validateParams` ran inside `_resolveParams` above, BEFORE the
        // record filled anything, so a rule about a set of addresses was asked of a set that was
        // not yet the set. MEASURED: with `RECOUP_GUARDIAN` unset and an `operators.guardian` row
        // EQUAL TO THE OWNER, `GuardianMustDifferFromOwner` passed on zero and the fill then handed
        // back the owner as guardian with no error - the one configuration that rule exists to
        // refuse, caught only inside the timelock batch at `executeBatch`, where this script's
        // purpose is to refuse before scheduling. No record carries the row today; `_heldToRecord`
        // lists it so the row binds the day it is added, and on that day it bound past the rule.
        // The consequence stated rather than discovered: the fill arm of `_operatorAgainstRecord`
        // is now LIVE on this path, so an operator variable left unset is filled from the record
        // (the report path's disposition, and a committed record is not the silent inheritance
        // `_readParams` refuses - the disagreement arm still refuses a set variable that differs),
        // and `KeeperRequired` and its siblings fire only when neither side names the operator.
        // Round 54 ran every deploy harness with the old order and the new and exactly one test
        // moved: the one that pinned this defect.
        p = _heldToRecord(p, j);
        _validateParams(p, sender);
    }

    /// @dev `_readParams`, held to the record the way `_resolveParamsAgainstRecord` holds
    ///      `_resolveParams`. For readers, and there is exactly one: `assertOnly()`.
    ///
    ///      Round-53 item 183. The record carries `operators.owner`, `yieldRecipient`, `keeper`,
    ///      `navConfirmer` and `protocolFeeWallet`, and the health report opened none of them, so an
    ///      environment that disagreed with the record on any of the five was reported as the
    ///      CHAIN failing a census the chain was passing. Round 38 fixed the shape for one value
    ///      (`OwnerNotNamedForReport`, the UNSET owner); this is the WRONG value and the four
    ///      sibling rows.
    ///
    ///      **Fills and refuses, and the two arms are the report's whole disposition.** An unset
    ///      variable takes the record's value, because the report is the tool an operator reaches
    ///      for when they are not sure what is set and refusing to run would be the wrong
    ///      direction. A set variable that disagrees is refused by name with both values, because
    ///      obeying it silently is how round 38's failure looked. A row the record lacks (the
    ///      guardian, today) falls through to the environment, which keeps the report usable on a
    ///      deployment newer than the record. No `_validateParams` runs here, for the reason stated
    ///      on `_readParams`.
    function _readParamsAgainstRecord(address sender) internal view returns (GovParams memory p) {
        p = _readParams(sender);
        string memory j = _deploymentRecord();
        if (bytes(j).length == 0) return p;
        p = _heldToRecord(p, j);
    }

    /// @dev Every `operators.*` row the record may carry, in `GovParams` order. `guardian` is
    ///      listed although no record carries it today, so the row is binding the day it is added
    ///      rather than a fix somebody has to remember - the same reason `_requiredTimelock` looks
    ///      up `operators.timelock`.
    function _heldToRecord(GovParams memory p, string memory j) internal view returns (GovParams memory) {
        p.owner = _operatorAgainstRecord("RECOUP_OWNER", ".operators.owner", p.owner, j);
        p.yieldRecipient =
            _operatorAgainstRecord("RECOUP_YIELD_RECIPIENT", ".operators.yieldRecipient", p.yieldRecipient, j);
        p.keeper = _operatorAgainstRecord("RECOUP_KEEPER", ".operators.keeper", p.keeper, j);
        p.navConfirmer = _operatorAgainstRecord("RECOUP_NAV_CONFIRMER", ".operators.navConfirmer", p.navConfirmer, j);
        p.protocolFeeWallet =
            _operatorAgainstRecord("RECOUP_PROTOCOL_FEE_WALLET", ".operators.protocolFeeWallet", p.protocolFeeWallet, j);
        p.guardian = _operatorAgainstRecord("RECOUP_GUARDIAN", ".operators.guardian", p.guardian, j);
        return p;
    }

    /// @dev One operator row, resolved the `_resolveOne` way with one difference stated: an ABSENT
    ///      row is tolerated and falls through to the environment, where `_resolveOne` refuses one,
    ///      because the operator set is allowed to be recorded partially (no guardian row exists)
    ///      and the contract set is not. The zero-environment arm is the fill; `_envOrAddress`
    ///      cannot tell "unset" from "set to zero", so a row the record carries cannot be overridden
    ///      to zero from the environment, and that is stated rather than discovered.
    function _operatorAgainstRecord(string memory name, string memory jsonPath, address env, string memory j)
        internal
        view
        returns (address)
    {
        if (!vm.keyExistsJson(j, jsonPath)) return env;
        address fromRecord = _recordAddress(j, name, jsonPath);
        if (env == address(0)) {
            // Round 54. A row that is PRESENT and ZERO is named here, the way `_resolveOne` names
            // one, rather than filled as zero and left for `assertOnly()`'s census to blame the
            // CHAIN with `WiringIncomplete("oracle.keeper")` - the round-38 shape one row over.
            // MEASURED before this arm: `operators.keeper` present and zero with `RECOUP_KEEPER`
            // unset reported `WiringIncomplete` from the report path, while the broadcast path
            // already named it (`DeployedEnvDisagreesWithRecord(name, env, 0)`). Absence is still
            // tolerated one line up; a record that WRITES a zero row is a broken record, and that
            // holds for the guardian row too: "no guardian" is an absent row, which is how every
            // record to date has said it.
            if (fromRecord == address(0)) revert DeployedAddressMissing(name);
            return fromRecord;
        }
        if (env != fromRecord) revert DeployedEnvDisagreesWithRecord(name, env, fromRecord);
        return fromRecord;
    }

    /// @notice `RECOUP_TIMELOCK`, checked against the record only if the record holds one.
    /// @dev 🟥 **THE RECORD DOES NOT HOLD A TIMELOCK TODAY, and saying so is the point of this
    ///      function rather than an apology for it.** `operators` carries `owner`,
    ///      `yieldRecipient`, `keeper`, `navConfirmer` and `protocolFeeWallet`, and nothing else -
    ///      the deployment this record describes is owned by an EOA, so there is no timelock to
    ///      record. Round-50 item 134 asked for `RECOUP_TIMELOCK` to be held to the record the way
    ///      the other ten addresses now are, and the honest answer is that it CANNOT be until the
    ///      record grows an `operators.timelock` row at the G2 handover.
    ///
    ///      What stands in the meantime is not nothing: `_queuePause` and `_queue` both refuse a
    ///      timelock that cannot act on the graph, which is a stronger statement than agreeing with
    ///      a committed address, because it is read off the chain rather than off a file. The key
    ///      lookup below is what makes the row binding the day it is added, rather than a fix
    ///      somebody has to remember.
    function _requiredTimelock() internal view returns (address t) {
        t = _required("RECOUP_TIMELOCK");
        string memory j = _deploymentRecord();
        if (bytes(j).length != 0 && vm.keyExistsJson(j, ".operators.timelock")) {
            address recordTimelock = _recordAddress(j, "RECOUP_TIMELOCK", ".operators.timelock");
            if (t != recordTimelock) {
                revert DeployedEnvDisagreesWithRecord("RECOUP_TIMELOCK", t, recordTimelock);
            }
        }
        // Round 53: after the identity check, so a disagreement is still the message when both
        // apply, and before the first dereference on every entry point that reaches this function.
        if (t.code.length == 0) revert DeployedAddressHasNoCode("RECOUP_TIMELOCK", t);
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeCall(TimelockController.getMinDelay, ()));
        if (!ok || ret.length != 32) revert TimelockDoesNotAnswer(t);
        // Round 54: a second selector, so the probe is two wide rather than one. A coded owner
        // answering `getMinDelay()` with one word and nothing else passed the line above, passed
        // `TimelockIsNotTheOwner`, and died EMPTY on `hashOperationBatch` - MEASURED, and realistic
        // only by selector collision (`0xf27a0c92`), which is why it is one `staticcall` and not a
        // census of all four entry points. `hashOperationBatch` is pure on the timelock, so an
        // empty batch is a complete question and one word is the whole answer.
        (ok, ret) = t.staticcall(
            abi.encodeCall(
                TimelockController.hashOperationBatch,
                (new address[](0), new uint256[](0), new bytes[](0), PREDECESSOR, SALT)
            )
        );
        if (!ok || ret.length != 32) revert TimelockDoesNotAnswer(t);
    }
}
