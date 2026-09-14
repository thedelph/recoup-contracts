// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 59, target 4: the H-03 counter-case the reply on issue #47 asked the auditor for.
/// @notice The posted reply disputes the benchmark, not the arithmetic: one synchronous
///         `redeem(maxRedeem)` is said to reach at least what the stepped request-service loop
///         reaches, from the same state, for the same shares. It then names the one state that
///         would overturn that - "a queue from another lender holding the reserve, say" - and says
///         it has not been found.
///
/// @dev **It exists.** The two doors read DIFFERENT cash bases and that is the whole of it:
///
///      - `_maxRedeem` bounds a holder by `_unreservedIdle = executable - ceil(executable *
///        queuedShares / supply)`, where `queuedShares` is EVERY live request, including other
///        lenders'.
///      - `maxRequestRedeem` bounds a requester by `executable * ownRequestShares / supply`,
///        computed on the FULL executable cash with no deduction for anybody else's queue.
///
///      So a second lender's standing request shrinks the sync door and leaves the request door
///      untouched, and the loop then compounds on top. Everything here is measurement of SHIPPED
///      behaviour at `c9b5f95`; no source is changed. The pool is wired to EOAs because
///      `lend`/`impair` are all this needs and a controllable principal is the point.
///
///      **These tests ASSERTED THE DEFECT and went red the day the fix landed, as designed.**
///      Round 60 shipped the reviewers' request-draw memory (`LenderPool._requestDraws`), and
///      `test_R59A02_H03_aSecondLendersQueueMakesTheLoopBeatTheSyncDoor` and
///      `test_R59A02_H03_gridSearchForTheBestCounterCase` now assert the CLOSED state: the loop
///      2,500.000000 in one call against one sync redeem of 2,500.000000, and 0 of 60 grid
///      cells. The shipped-tree figures they used to assert are kept in each docstring as
///      history: 4,999.999998 over 53 calls, 45 of 60 cells, best excess 3,999.999995.
///      `test_R59A02_H03_theExcessComesOutOfTheQueuedLendersOwnReserve` stays GREEN under the
///      memory, deliberately: after the attacker's ONE permitted draw the blocker's serviceable
///      figure still falls from 2,500.000000 to 1,428.571428, because the reserve was never a
///      cash guarantee. And the closed state is one route of three: `R60S1_H03Routes.t.sol`
///      measures the stepped sync door and the sequential address split at the same total.
contract R59A02_H03CounterCase is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");

    address internal attacker = makeAddr("attacker");
    address internal blocker = makeAddr("blocker"); // the other lender, holding the reserve
    address internal bystander = makeAddr("bystander");
    address internal borrower = makeAddr("borrower");

    /// @dev The first call's slice, recorded by `_loopRequest` so the fair single-shot figure is
    ///      read AFTER the request exists rather than before it.
    uint256 internal lastFairFirstSlice;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        pool.setCreditManager(manager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _lend(uint256 amount) internal {
        vm.prank(manager);
        pool.lend(amount);
    }

    /// @dev One synchronous `redeem` at the sync door's own maximum. Returns what it paid.
    function _syncOnce(address who) internal returns (uint256 paid) {
        uint256 shares = pool.maxRedeem(who); // read before the prank
        if (shares == 0) return 0;
        vm.prank(who);
        paid = pool.redeem(shares, who, who);
    }

    /// @dev Queue every share and service until the door reads zero. Returns the total captured
    ///      and the number of paying calls.
    function _loopRequest(address who) internal returns (uint256 captured, uint256 calls) {
        uint256 shares = pool.balanceOf(who);
        vm.prank(who);
        pool.requestWithdrawal(shares, who);
        lastFairFirstSlice = pool.previewRedeem(pool.maxRequestRedeem(who));
        for (uint256 i = 0; i < 128; i++) {
            uint256 serviceable = pool.maxRequestRedeem(who);
            if (serviceable == 0) break;
            vm.prank(who);
            captured += pool.serviceWithdrawalRequest(who, serviceable, 0);
            ++calls;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The counter-case
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice THE ANSWER TO #47, CLOSED on the request door. Another lender's standing request
    ///         holds the reserve; the sync door subtracts that whole reserve and the request
    ///         door did not subtract it at all, so on the shipped tree the loop captured
    ///         4,999.999998 over 53 calls against one `redeem` of 2,500.000000. Under the
    ///         request-draw memory the loop captures exactly the sync door's 2,500.000000 in
    ///         one call, and this test asserts that equality.
    /// @dev Both arms run from one `vm.snapshotState`, so the comparison is on identical state.
    function test_R59A02_H03_aSecondLendersQueueMakesTheLoopBeatTheSyncDoor() public {
        // 10,000 each, 15,000 lent out. Executable cash is what is left after the 15% float is
        // NOT applied to exits (the float bounds `available()`, not `maxRedeem`).
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(15_000e6);
        assertGt(pool.outstandingPrincipal(), 0, "fixture: no principal at risk");

        // The other lender queues everything and simply sits there.
        uint256 blockerShares = pool.balanceOf(blocker);
        vm.prank(blocker);
        pool.requestWithdrawal(blockerShares, blocker);

        uint256 executable = pool.totalAssets() - pool.outstandingPrincipal();
        emit log_named_uint("MEASURED pool cash at rest               ", usdc.balanceOf(address(pool)));
        emit log_named_uint("MEASURED outstandingPrincipal            ", pool.outstandingPrincipal());
        emit log_named_uint("MEASURED queueCashReserve (blocker's)    ", pool.queueCashReserve());
        emit log_named_uint("MEASURED unreservedIdle                  ", pool.unreservedIdle());
        executable;

        uint256 clean = vm.snapshotState();

        // Arm one: the sync door, once, as the reply benchmarks it.
        uint256 syncShares = pool.maxRedeem(attacker);
        uint256 syncQuoted = pool.previewRedeem(syncShares);
        uint256 syncPaid = _syncOnce(attacker);
        uint256 syncSharesLeft = pool.balanceOf(attacker);

        // Arm two: the request door, stepped.
        vm.revertToState(clean);
        (uint256 captured, uint256 calls) = _loopRequest(attacker);
        uint256 fairOnce = lastFairFirstSlice;

        emit log_named_uint("MEASURED one sync redeem, shares         ", syncShares);
        emit log_named_uint("MEASURED one sync redeem, quoted         ", syncQuoted);
        emit log_named_uint("MEASURED one sync redeem, PAID           ", syncPaid);
        emit log_named_uint("MEASURED shares left after the sync door ", syncSharesLeft);
        emit log_named_uint("MEASURED fair single-shot request slice  ", fairOnce);
        emit log_named_uint("MEASURED stepped service, CAPTURED       ", captured);
        emit log_named_uint("MEASURED stepped service calls           ", calls);
        if (captured > syncPaid) {
            emit log_named_uint("MEASURED the loop's EXCESS over one redeem", captured - syncPaid);
        }

        assertEq(syncPaid, syncQuoted, "the sync door paid other than it quoted");
        assertEq(captured, syncPaid, "the request loop and one sync redeem parted company again");
        assertEq(calls, 1, "the request loop paid on more than one call");
        assertEq(captured, fairOnce, "the request loop reached other than its single slice");
    }

    /// @notice The same state with the blocker's queue REMOVED, as the control that isolates the
    ///         cause: without another lender's request the two doors agree and the shipped pin's
    ///         relationship holds.
    function test_R59A02_H03_control_withNoOtherQueueTheSyncDoorStillDominates() public {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(15_000e6);

        uint256 clean = vm.snapshotState();
        uint256 syncPaid = _syncOnce(attacker);

        vm.revertToState(clean);
        (uint256 captured,) = _loopRequest(attacker);

        emit log_named_uint("MEASURED one sync redeem, PAID           ", syncPaid);
        emit log_named_uint("MEASURED stepped service, CAPTURED       ", captured);
        assertLe(captured, syncPaid, "the control moved: the loop beat the sync door with no other queue");
    }

    /// @notice The damage the excess does, stated in the only terms that matter: the cash the loop
    ///         took out of the shared junior pot is exactly what the lender who queued honestly
    ///         and waited can no longer be paid. The blocker's own serviceable figure is measured
    ///         before and after the attacker's loop.
    function test_R59A02_H03_theExcessComesOutOfTheQueuedLendersOwnReserve() public {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(15_000e6);

        uint256 blockerShares = pool.balanceOf(blocker);
        vm.prank(blocker);
        pool.requestWithdrawal(blockerShares, blocker);

        uint256 blockerServiceableBefore = pool.previewRedeem(pool.maxRequestRedeem(blocker));
        uint256 reserveBefore = pool.queueCashReserve();

        (uint256 captured,) = _loopRequest(attacker);

        uint256 blockerServiceableAfter = pool.previewRedeem(pool.maxRequestRedeem(blocker));

        emit log_named_uint("MEASURED blocker's reserve before        ", reserveBefore);
        emit log_named_uint("MEASURED blocker serviceable before      ", blockerServiceableBefore);
        emit log_named_uint("MEASURED attacker captured               ", captured);
        emit log_named_uint("MEASURED blocker serviceable after       ", blockerServiceableAfter);
        emit log_named_uint(
            "MEASURED blocker's loss of serviceable   ", blockerServiceableBefore - blockerServiceableAfter
        );
        assertLt(blockerServiceableAfter, blockerServiceableBefore, "the reserved lender lost nothing");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A bounded enumeration, so the answer is a search result rather than one lucky fixture
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A small exhaustive grid over the three parameters that move the two doors apart:
    ///         the blocker's stake, the attacker's stake and how much principal is out. Every cell
    ///         runs both arms from one snapshot and the best excess is reported. Under the
    ///         request-draw memory no cell lets the loop win; the shipped tree gave 45 of 60.
    /// @dev 4 x 4 x 4 = 64 cells, each two full arms. Deposits are kept inside the 25,000 default
    ///      cap. The cell with no blocker queue is included as the in-grid control.
    struct Cell {
        uint256 blockerStake;
        uint256 attackerStake;
        uint256 lent;
        uint256 syncPaid;
        uint256 captured;
    }

    /// @dev One cell, run from a snapshot the caller restores. Split out because the three-deep
    ///      loop with every figure inline is stack-too-deep on solc 0.8.24 without via-ir.
    function _runCell(uint256 blockerStake, uint256 attackerStake, uint256 lentBpsOfBook)
        internal
        returns (Cell memory c)
    {
        c.blockerStake = blockerStake;
        c.attackerStake = attackerStake;

        _deposit(blocker, blockerStake);
        _deposit(attacker, attackerStake);
        uint256 lendable = pool.available();
        uint256 want = ((blockerStake + attackerStake) * lentBpsOfBook) / Config.BPS;
        c.lent = want > lendable ? lendable : want;
        if (c.lent != 0) _lend(c.lent);

        uint256 bShares = pool.balanceOf(blocker);
        vm.prank(blocker);
        pool.requestWithdrawal(bShares, blocker);

        uint256 cell = vm.snapshotState();
        c.syncPaid = _syncOnce(attacker);
        vm.revertToState(cell);
        (c.captured,) = _loopRequest(attacker);
    }

    function test_R59A02_H03_gridSearchForTheBestCounterCase() public {
        uint256[4] memory blockerStakes = [uint256(1_000e6), 5_000e6, 10_000e6, 18_000e6];
        uint256[4] memory attackerStakes = [uint256(1_000e6), 3_000e6, 6_000e6, 10_000e6];
        uint256[4] memory lentBps = [uint256(0), 3_000, 6_000, 8_000];

        Cell memory best;
        uint256 bestExcess;
        uint256 cellsWithExcess;
        uint256 cellsRun;

        for (uint256 b = 0; b < 4; b++) {
            for (uint256 a = 0; a < 4; a++) {
                for (uint256 l = 0; l < 4; l++) {
                    if (blockerStakes[b] + attackerStakes[a] > 24_000e6) continue;
                    uint256 root = vm.snapshotState();
                    Cell memory c = _runCell(blockerStakes[b], attackerStakes[a], lentBps[l]);
                    ++cellsRun;
                    if (c.captured > c.syncPaid) {
                        ++cellsWithExcess;
                        if (c.captured - c.syncPaid > bestExcess) {
                            bestExcess = c.captured - c.syncPaid;
                            best = c;
                        }
                    }
                    vm.revertToState(root);
                }
            }
        }

        emit log_named_uint("MEASURED cells run                       ", cellsRun);
        emit log_named_uint("MEASURED cells where the loop beat sync  ", cellsWithExcess);
        emit log_named_uint("MEASURED best excess, USDC               ", bestExcess);
        emit log_named_uint("MEASURED   at blocker stake              ", best.blockerStake);
        emit log_named_uint("MEASURED   at attacker stake             ", best.attackerStake);
        emit log_named_uint("MEASURED   with principal lent           ", best.lent);
        emit log_named_uint("MEASURED   loop captured                 ", best.captured);
        emit log_named_uint("MEASURED   one sync redeem paid          ", best.syncPaid);
        // 45 of 60 on the shipped tree, best excess 3,999.999995 at 10,000 / 10,000 with 12,000
        // lent; 0 of 60 under the request-draw memory.
        assertEq(cellsWithExcess, 0, "the grid found a cell where the request loop beats one sync redeem");
    }

    /// @notice The second lever asked about: an impairment arriving BETWEEN the loop's calls. The
    ///         attacker services once, the manager marks the book down, and the attacker services
    ///         again. Measured against one sync redeem taken before the mark and one taken after.
    /// @dev `impair` is manager-only and raises `exitReserve`, so the exit price falls mid-loop.
    ///      This is the "impairment between calls" arm of the ask on #47.
    function test_R59A02_H03_anImpairmentBetweenCallsDoesNotBeatTheSyncDoor() public {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(15_000e6);
        uint256 clean = vm.snapshotState();

        uint256 syncBeforeMark = _syncOnce(attacker);

        vm.revertToState(clean);
        uint256 shares = pool.balanceOf(attacker);
        vm.prank(attacker);
        pool.requestWithdrawal(shares, attacker);
        uint256 captured;
        uint256 first = pool.maxRequestRedeem(attacker);
        vm.prank(attacker);
        captured += pool.serviceWithdrawalRequest(attacker, first, 0);
        // The mark lands between the calls.
        vm.prank(manager);
        pool.impair(borrower, 5_000e6);
        for (uint256 i = 0; i < 64; i++) {
            uint256 serviceable = pool.maxRequestRedeem(attacker);
            if (serviceable == 0) break;
            vm.prank(attacker);
            captured += pool.serviceWithdrawalRequest(attacker, serviceable, 0);
        }

        emit log_named_uint("MEASURED one sync redeem before the mark ", syncBeforeMark);
        emit log_named_uint("MEASURED loop with a mark between calls  ", captured);
        emit log_named_uint("MEASURED totalImpairment at the end      ", pool.totalImpairment());
    }
}
