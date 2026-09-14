// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 60, S1: the auditor's harness for the request-draw memory, ported verbatim.
/// @notice 33audits (SDF) posted eight tests with the fix on issue #47 (H-03), all green on the
///         public `bf2528a6` with their three edits. This is that harness with each test renamed
///         under the `R60S1_` prefix and nothing else changed: their figures are the assertions.
///         The three split tests log only, as posted; `R60S1_H03Routes.t.sol` is where the split
///         is measured in the SEQUENTIAL form that the parallel form here does not reach.
/// @dev Fixture: the auditor's, two lenders of 10,000 with 15,000 lent and the second lender
///      queued. The pool is owned by this contract and capped at `GLOBAL_BORROW_CAP_MAX` so the
///      grid's larger deposits fit.
contract R60S1_H03RequestDraw is Test {
    address internal manager = makeAddr("manager");
    address internal attacker = makeAddr("attacker");
    address internal queued = makeAddr("queued");

    MockUSDC internal usdc;
    LenderPool internal pool;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), address(this));
        pool.setCreditManager(manager);
        pool.setEpochHarvester(makeAddr("harvester"));
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        uint256 s = pool.deposit(assets, who);
        vm.stopPrank();
        return s;
    }

    function _lend(uint256 amount) internal {
        vm.prank(manager);
        pool.lend(amount);
    }

    /// @dev `available()` withholds the reserve float, so a fixture cannot name any figure it likes.
    function _lendUpTo(uint256 wanted) internal {
        uint256 lendable = pool.available();
        uint256 amount = wanted < lendable ? wanted : lendable;
        if (amount != 0) _lend(amount);
    }

    /// @dev Two lenders of 10,000; 15,000 lent; the other lender queues everything and sits.
    function _state() internal returns (uint256 attackerShares) {
        attackerShares = _deposit(attacker, 10_000e6);
        uint256 queuedShares_ = _deposit(queued, 10_000e6);
        _lend(15_000e6);

        vm.prank(queued);
        pool.requestWithdrawal(queuedShares_, queued);
    }

    function test_R60S1_H03_theSyncDoorPaysTheProRataSlice() public {
        uint256 attackerShares = _state();

        uint256 maxShares = pool.maxRedeem(attacker);
        vm.prank(attacker);
        uint256 paid = pool.redeem(maxShares, attacker, attacker);

        console2.log("executable cash      ", pool.unreservedIdle() + pool.queueCashReserve());
        console2.log("one redeem pays      ", paid);
        console2.log("attacker shares left ", pool.balanceOf(attacker));
        assertLt(paid, attackerShares, "sync door is bounded by the queue reserve");
    }

    function test_R60S1_H03_theSteppedLoopOutPaysTheSyncDoor() public {
        uint256 attackerShares = _state();

        vm.prank(attacker);
        pool.requestWithdrawal(attackerShares, attacker);

        uint256 total;
        uint256 calls;
        for (uint256 i = 0; i < 512; i++) {
            uint256 serviceable = pool.maxRequestRedeem(attacker);
            if (serviceable == 0) break;
            vm.prank(attacker);
            total += pool.serviceWithdrawalRequest(attacker, serviceable, 0);
            calls++;
        }

        (,,, uint256 queuedServiceable,) = pool.withdrawalRequest(queued);

        console2.log("loop total           ", total);
        console2.log("calls                ", calls);
        console2.log("queued lender left   ", queuedServiceable);
        console2.log("previewRedeem thereof", pool.previewRedeem(queuedServiceable));

        assertEq(total, 2_500e6, "the loop must not out-pay the sync door");
        assertEq(calls, 1, "the slice is a budget, not a rate");
        assertEq(pool.previewRedeem(queuedServiceable), 1_428_571_428, "the queued lender keeps her cash");
    }

    /// @dev The behaviour a request-time-frozen entitlement loses: a lender who queues during a
    ///      drought must see her slice rise when a loan repays.
    function test_R60S1_H03_theEntitlementRisesWhenALoanRepays() public {
        uint256 aliceShares = _deposit(attacker, 10_000e6);
        _deposit(queued, 10_000e6);
        _lendUpTo(18_000e6);

        vm.prank(attacker);
        pool.requestWithdrawal(aliceShares, attacker);

        uint256 droughtSlice = pool.maxRequestRedeem(attacker);
        vm.prank(attacker);
        uint256 paidInDrought = pool.serviceWithdrawalRequest(attacker, droughtSlice, 0);
        assertEq(pool.maxRequestRedeem(attacker), 0, "the drought slice is spent");

        usdc.mint(manager, 9_000e6);
        vm.startPrank(manager);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayPrincipal(9_000e6);
        vm.stopPrank();

        uint256 afterRepay = pool.previewRedeem(pool.maxRequestRedeem(attacker));
        console2.log("serviced in drought  ", paidInDrought);
        console2.log("serviceable on repay ", afterRepay);
        assertGt(afterRepay, paidInDrought, "a frozen entitlement would still read zero here");
    }

    /// @dev thedelph measured 45 of 60 grid cells where the loop beat one redeem. None may remain.
    function test_R60S1_H03_noGridCellLetsTheLoopWin() public {
        uint256 wins;
        for (uint256 d = 1; d <= 6; d++) {
            for (uint256 l = 1; l <= 10; l++) {
                uint256 deposit = d * 5_000e6;
                uint256 lent = (deposit * 2 * l) / 11;
                uint256 sync = _syncDoor(deposit, lent);
                uint256 loop = _loopTotal(deposit, lent);
                if (loop > sync) wins++;
            }
        }
        assertEq(wins, 0, "no state may let the stepped loop out-pay the sync door");
    }

    /// @dev Does deleting the request on cancel hand back a fresh slice?
    function test_R60S1_H03_bypass_cancelAndRequestAgain() public {
        uint256 attackerShares = _state();
        vm.startPrank(attacker);
        pool.requestWithdrawal(attackerShares, attacker);
        uint256 total;
        uint256 rounds;
        for (uint256 i = 0; i < 64; i++) {
            uint256 svc = pool.maxRequestRedeem(attacker);
            if (svc != 0) total += pool.serviceWithdrawalRequest(attacker, svc, 0);
            (,, uint256 remaining,,) = pool.withdrawalRequest(attacker);
            if (remaining == 0) break;
            pool.cancelWithdrawalRequest();
            pool.requestWithdrawal(remaining, attacker);
            rounds++;
            if (svc == 0) break;
        }
        vm.stopPrank();
        console2.log("cancel/re-request total", total);
        console2.log("rounds                 ", rounds);
        assertEq(total, 2_500e6, "cancel must not mint a fresh slice");
    }

    /// @dev Shares are transferable. Does splitting the position across addresses restore the walk?
    function _split(uint256 n) internal returns (uint256 total) {
        uint256 attackerShares = _state();
        uint256 chunk = attackerShares / n;
        for (uint256 i = 0; i < n; i++) {
            address sock = address(uint160(0x50C00 + i));
            vm.prank(attacker);
            pool.transfer(sock, chunk);
            vm.startPrank(sock);
            pool.requestWithdrawal(chunk, sock);
            for (uint256 j = 0; j < 8; j++) {
                uint256 svc = pool.maxRequestRedeem(sock);
                if (svc == 0) break;
                total += pool.serviceWithdrawalRequest(sock, svc, 0);
            }
            vm.stopPrank();
        }
    }

    function test_R60S1_H03_bypass_split_040() public {
        console2.log("n=40  total", _split(40));
    }

    function test_R60S1_H03_bypass_split_200() public {
        console2.log("n=200 total", _split(200));
    }

    function test_R60S1_H03_bypass_split_600() public {
        console2.log("n=600 total", _split(600));
    }

    function _fresh() internal {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), address(this));
        pool.setCreditManager(manager);
        pool.setEpochHarvester(makeAddr("harvester"));
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
    }

    function _syncDoor(uint256 deposit, uint256 lent) internal returns (uint256) {
        _fresh();
        _deposit(attacker, deposit);
        uint256 qs = _deposit(queued, deposit);
        _lendUpTo(lent);
        vm.prank(queued);
        pool.requestWithdrawal(qs, queued);
        uint256 maxShares = pool.maxRedeem(attacker);
        if (maxShares == 0) return 0;
        vm.prank(attacker);
        return pool.redeem(maxShares, attacker, attacker);
    }

    function _loopTotal(uint256 deposit, uint256 lent) internal returns (uint256 total) {
        _fresh();
        uint256 as_ = _deposit(attacker, deposit);
        uint256 qs = _deposit(queued, deposit);
        _lendUpTo(lent);
        vm.prank(queued);
        pool.requestWithdrawal(qs, queued);
        vm.prank(attacker);
        pool.requestWithdrawal(as_, attacker);
        for (uint256 i = 0; i < 512; i++) {
            uint256 s = pool.maxRequestRedeem(attacker);
            if (s == 0) break;
            vm.prank(attacker);
            total += pool.serviceWithdrawalRequest(attacker, s, 0);
        }
    }
}
