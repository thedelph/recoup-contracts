// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title #64: an honest request still completes after the write-down (the rounding of the worth).
/// @notice The #64 fix writes what is left of a floor down to what the remaining escrowed shares
///         are worth. Written down to the ROUNDED-DOWN worth, an honest requester who services
///         part of her request after a socialised loss and then runs the ordinary
///         `maxRequestRedeem` loop is left holding a few share-wei behind a door of 0: the floor
///         sits one wei under what the remaining shares' door needs, so the loop pays one wei less
///         than her worth and strands the rest, with a cancel as the only exit. Rounding the worth
///         UP keeps at most one wei per request above the exact worth, and the loop completes.
/// @dev Bare pool over `MockUSDC` (`R63A3_Fixture`). Book 100,000: two requesters of 20,000 filed
///      in an idle book, two dormant lenders of 30,000, 40,000 lent, then a 10,000 socialised
///      loss. No raw loss, so the floors sit inside the executable cash and the write-down
///      applies. Six-decimal USDC base units; every `MEASURED` line was read from a run before
///      the figure beside it was asserted. Sign: the wei of rounding goes to the requester (her
///      floor is at most one wei above her shares' exact worth); the other lenders lose at most
///      that wei of reach while her request stands.
contract Issue64_HonestCompletion is R63A3_Fixture {
    uint256 internal constant T = 100_000e6;

    address internal r0 = makeAddr("issue64-honest-requester");
    address internal r1 = makeAddr("issue64-other-requester");
    address internal d0 = makeAddr("issue64-dormant-0");
    address internal d1 = makeAddr("issue64-dormant-1");

    function _opening() internal {
        _deposit(r0, T / 5);
        _deposit(r1, T / 5);
        _deposit(d0, T * 3 / 10);
        _deposit(d1, T * 3 / 10);
        _requestAll(r0);
        _requestAll(r1);
        _lend(T * 2 / 5);
        vm.prank(manager);
        pool.socialiseLoss(10_000e6);
        assertLe(_floorTotal(), _executable(), "fixture: the floors are over the cash, the write-down is off");
    }

    /// @dev The gross worth of `shares` rounded UP, recomputed from the public views.
    function _ceilWorth(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, pool.totalAssets() + 1, pool.totalSupply() + 1_000, Math.Rounding.Ceil);
    }

    function _requestId(address who) internal view returns (uint256 id) {
        (id,,,,) = pool.withdrawalRequest(who);
    }

    /// @dev The ordinary loop a requester (or a front end) runs: service the door until the
    ///      request is gone or the door is shut.
    function _maxRequestRedeemLoop(address who) internal returns (uint256 paid, uint256 calls) {
        for (; calls < 32; ++calls) {
            if (_requestId(who) == 0) break;
            uint256 door = pool.maxRequestRedeem(who);
            if (door == 0) break;
            paid += _service(who, door);
        }
    }

    /// @notice Half her request serviced after the loss, then the `maxRequestRedeem` loop: the
    ///         request completes and no share-wei is left in escrow.
    function test_Issue64_halfServiceThenTheLoopCompletes() public {
        _opening();
        uint256 half = _requestShares(r0) / 2;
        uint256 paidHalf = _service(r0, half);
        uint256 left = _requestShares(r0);
        uint256 kept = _floorOf(r0);
        uint256 exactDown = pool.convertToAssets(left);
        console2.log("MEASURED half service paid / left shares / kept floor", paidHalf, left, kept);
        console2.log("MEASURED worth of the rest, rounded down / up        ", exactDown, _ceilWorth(left));
        assertEq(kept, _ceilWorth(left), "the floor left is not the rounded-up worth of the rest");
        assertLe(kept, exactDown + 1, "the floor left is more than one wei above the worth");
        // Measured: half paid 9,000.000000, the rest is worth 9,000.000000 rounded down and the
        // floor keeps 9,000.000001 (was 9,000.000000 with the worth rounded down).
        assertEq(kept, 9_000_000_001, "the floor left is not 9,000.000001");

        (uint256 paidRest, uint256 calls) = _maxRequestRedeemLoop(r0);
        console2.log("MEASURED the loop paid / calls / shares left in escrow", paidRest, calls, _requestShares(r0));
        assertEq(_requestId(r0), 0, "the maxRequestRedeem loop did not complete the request");
        assertEq(_requestShares(r0), 0, "share dust was stranded in escrow");
        assertEq(_floorOf(r0), 0, "a floor outlived the request");
        assertGe(paidRest + 1, exactDown, "the loop paid more than a wei under the worth of the rest");
        // Measured: one call pays 9,000.000000 and burns every share left (with the worth rounded
        // down it paid 8,999.999999 and left 13 share-wei behind a door of 0).
        assertEq(paidRest, 9_000_000_000, "the loop did not pay 9,000.000000");
        assertEq(calls, 1, "the loop took more than one call");
    }

    /// @notice One share-wei of dust after the loss: it keeps a floor of 1 wei (its worth, about a
    ///         thousandth of a wei, rounded up), which holds a door of one share-wei open, and the
    ///         completing one-wei service ends the request and releases the wei.
    function test_Issue64_oneShareWeiDustKeepsOneWeiAndCompletes() public {
        _opening();
        uint256 door = pool.maxRequestRedeem(r0);
        uint256 all = _requestShares(r0);
        assertGe(door, all, "fixture: her door does not reach her whole request");
        _service(r0, all - 1);
        uint256 floorsBefore = _floorTotal();
        console2.log(
            "MEASURED dust shares / kept floor / door", _requestShares(r0), _floorOf(r0), pool.maxRequestRedeem(r0)
        );
        assertEq(_requestShares(r0), 1, "fixture: she did not leave exactly one share-wei");
        assertEq(_floorOf(r0), 1, "one share-wei does not keep exactly its rounded-up worth, 1 wei");
        assertEq(pool.maxRequestRedeem(r0), 1, "the 1-wei floor does not hold her one share-wei's door");

        uint256 paid = _service(r0, 1);
        console2.log("MEASURED completing service paid / floors before / after", paid, floorsBefore, _floorTotal());
        assertEq(_requestId(r0), 0, "the completing one-wei service did not end the request");
        assertEq(floorsBefore - _floorTotal(), 1, "the completing service did not release the wei of floor");
    }
}
