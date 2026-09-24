// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title #64 trim: who may pick the moment, what a re-trim moves, and what it never moves.
/// @notice `writeDownDeclined` is set by a service that declines the #64 write-down and is cleared
///         only with the request, so a request trimmed once is trimmed again, by anyone, after any
///         later price fall. These tests measure what that re-trim moves: the requester's
///         liquidity priority (how much cash is held for her ahead of lending and sync exits),
///         never the value of her shares. Same book as `Issue64_FloorTrim`: 100,000, two
///         requesters of 20,000 filed in an idle book, two dormant lenders of 30,000, 40,000 lent,
///         a 10,000 socialised loss, then a 25,000 raw loss (reconciled); the honest requester is
///         serviced half-way under that shortfall (and marked), and the other requester's exit
///         ends it.
/// @dev Bare pool over `MockUSDC` (`R63A3_Fixture`); six-decimal USDC base units; every
///      `MEASURED` line was read from a run before the figure beside it was asserted.
contract Issue64_TrimTiming is R63A3_Fixture {
    uint256 internal constant T = 100_000e6;
    uint256 internal constant LATER_LOSS = 3_000e6;

    address internal r0 = makeAddr("dust-requester");
    address internal r1 = makeAddr("honest-requester");
    address internal d0 = makeAddr("dormant-0");
    address internal d1 = makeAddr("dormant-1-last-out");

    /// @dev The worth `trimRequestFloor` and the service path write a floor down to, recomputed
    ///      from the public views (offset 3, rounded UP), never read from the pool.
    function _ceilWorth(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, pool.totalAssets() + 1, pool.totalSupply() + 1_000, Math.Rounding.Ceil);
    }

    function _trim(address who) internal returns (uint256 released) {
        vm.prank(stranger);
        released = pool.trimRequestFloor(who);
    }

    function _drainLeaving(address who, uint256 leave) internal returns (uint256 paid) {
        for (uint256 call; call < 96; ++call) {
            uint256 door = pool.maxRequestRedeem(who);
            uint256 left = _requestShares(who);
            if (door == 0 || left <= leave) break;
            if (door >= left) {
                paid += _service(who, left - leave);
                break;
            }
            if (pool.previewRedeem(door) == 0) break;
            paid += _service(who, door);
        }
    }

    function _syncExit(address who) internal returns (uint256 got) {
        for (uint256 call; call < 16; ++call) {
            uint256 shares = pool.maxRedeem(who);
            if (shares == 0) break;
            vm.prank(who);
            got += pool.redeem(shares, who, who);
        }
    }

    function _book() internal {
        _deposit(r0, T / 5);
        _deposit(r1, T / 5);
        _deposit(d0, T * 3 / 10);
        _deposit(d1, T * 3 / 10);
        _requestAll(r0);
        _requestAll(r1);
        _lend(T * 2 / 5);
        vm.prank(manager);
        pool.socialiseLoss(10_000e6);
    }

    /// @dev r1 half-serviced under the shortfall (marked), then r0 leaves and the shortfall ends.
    function _markedHonestHalf() internal {
        _book();
        _loseCash(25_000e6);
        _service(r1, _requestShares(r1) / 2);
        assertTrue(pool.requestWriteDownDeclined(r1), "setup: r1 not marked");
        _drainLeaving(r0, 0);
        assertEq(_shortfall(), 0, "setup: the shortfall did not end");
    }

    /// @notice The mark survives a trim, so after a later price fall anyone trims the same request
    ///         again, and she still completes.
    function test_trimTiming_theMarkSurvivesATrimSoALaterFallIsTrimmedAgain() public {
        _markedHonestHalf();
        uint256 first = _trim(r1);
        uint256 floorAfterFirst = _floorOf(r1);
        console2.log("MEASURED first trim: released / floor after", first, floorAfterFirst);
        assertEq(first, 6_999_999_999, "first trim");
        assertEq(floorAfterFirst, 6_500_000_001, "floor after the first trim");
        assertTrue(pool.requestWriteDownDeclined(r1), "the mark was cleared by the trim");

        vm.prank(manager);
        pool.socialiseLoss(LATER_LOSS);
        uint256 worthNow = _ceilWorth(_requestShares(r1));
        console2.log("MEASURED after the later loss: floors / executable cash", _floorTotal(), _executable());
        uint256 second = _trim(r1);
        console2.log("MEASURED second trim released", second);
        assertEq(second, floorAfterFirst - worthNow, "the second trim is not the new excess");
        assertEq(second, 428_571_429, "second trim");

        _drainLeaving(r1, 0);
        assertEq(_requestShares(r1), 0, "r1 cannot complete after two trims");
    }

    /// @notice What a stranger choosing the moment can do to her: trim at a trough that a
    ///         recovery then reverses, before the cash is lent out and a sync holder exits first.
    ///         Measured against the same sequence with nobody trimming. Her value is the same
    ///         either way (to 1 wei); what moves is how much of it she can draw at once.
    function test_trimTiming_aStrangerTrimAtATroughMovesPriorityNeverValue() public {
        _markedHonestHalf();
        vm.prank(manager);
        pool.socialiseLoss(LATER_LOSS);
        uint256 snap = vm.snapshotState();

        uint256[5] memory a = _recoverThenDrought(false);
        assertTrue(vm.revertToState(snap), "snapshot");
        uint256[5] memory b = _recoverThenDrought(true);

        console2.log("MEASURED floor untrimmed / trimmed", a[0], b[0]);
        console2.log("MEASURED untrimmed: lent / d0 sync took / r1 drew now", a[1], a[2], a[3]);
        console2.log("MEASURED trimmed:   lent / d0 sync took / r1 drew now", b[1], b[2], b[3]);
        console2.log("MEASURED r1 worth still escrowed: untrimmed / trimmed", a[4], b[4]);
        assertEq(a[0], 13_500_000_000, "untrimmed floor");
        assertEq(b[0], 6_071_428_572, "trimmed floor");
        assertEq(a[1], 200_000_000, "lent, untrimmed");
        assertEq(b[1], 6_514_285_714, "lent, trimmed");
        assertEq(a[3], 6_500_000_002, "r1 drew at once, untrimmed");
        assertEq(b[3], 6_071_428_571, "r1 drew at once, trimmed");
        assertEq(b[4], 428_571_430, "r1 worth left escrowed, trimmed");
        assertApproxEqAbs(a[3] + a[4], b[3] + b[4], 1, "the trim moved r1's value, not only her liquidity");
    }

    function _recoverThenDrought(bool trimAtTrough) internal returns (uint256[5] memory m) {
        if (trimAtTrough) _trim(r1);
        m[0] = _floorOf(r1);
        usdc.mint(manager, LATER_LOSS);
        vm.prank(manager);
        pool.recoverLoss(LATER_LOSS);
        vm.warp(block.timestamp + D + 1);
        // Drought: the manager lends everything it may.
        uint256 lendable = pool.available();
        if (lendable != 0) _lend(lendable);
        m[1] = lendable;
        m[2] = _syncExit(d0);
        m[3] = _drainLeaving(r1, 0);
        m[4] = pool.convertToAssets(_requestShares(r1));
    }

    /// @notice A trim then a service applies the write-down once: the trimmed floor is the
    ///         rounded-up worth and never below what the shares pay, a later partial service does
    ///         not write it down again, a second trim releases nothing, and `_floorTotal` returns
    ///         to exactly 0 when the request is gone.
    function test_trimTiming_aTrimThenAServiceNeverDoubleApplies() public {
        _markedHonestHalf();
        _trim(r1);
        uint256 left = _requestShares(r1);
        assertEq(_floorOf(r1), _ceilWorth(left), "trimmed floor is not the rounded-up worth");
        assertGe(_floorOf(r1), pool.previewRedeem(left), "trimmed floor below what the shares pay");
        _service(r1, left / 3);
        uint256 leftAfter = _requestShares(r1);
        assertGe(_floorOf(r1) + 1, pool.previewRedeem(leftAfter), "floor fell below payout after a service");
        assertEq(_trim(r1), 0, "a trim after the service released again");
        _drainLeaving(r1, 0);
        assertEq(_requestShares(r1), 0, "r1 did not complete");
        assertEq(_floorTotal(), 0, "a floor is left behind with no live request");
    }

    /// @notice A trim is inert under an unreconciled raw loss that puts the floors over the cash:
    ///         the executable cash it compares against reads the raw balance, so nobody trims
    ///         through a loss the book has not yet recognised.
    function test_trimTiming_aTrimIsInertUnderAnUnreconciledRawLoss() public {
        _markedHonestHalf();
        uint256 floorBefore = _floorOf(r1);
        _loseCashUnreconciled(_executable());
        assertEq(_trim(r1), 0, "a trim wrote down through an unreconciled raw loss");
        assertEq(_floorOf(r1), floorBefore, "floor moved");
    }
}
