// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title #64's residual, read at the instant the shortfall ENDS: a floor kept on one share-wei
///        outlives the shortfall that made the service decline it, and nothing re-examines it
///        unless somebody calls `trimRequestFloor`.
/// @notice The shape of `Issue64_DustUnderShortfall` (book 100,000; two requesters of 20,000 filed
///         in an idle book; 40,000 lent; a 10,000 socialised loss; a 25,000 raw loss), read at
///         three instants: after her dust service, after the honest requester's completing
///         service ends the shortfall, and after the loan repays in full. The point this adds to
///         `Issue64_DustUnderShortfall`: the shortfall ends BEFORE any repayment, when the honest
///         requester completes, and from that instant the fix's own predicate (floors inside the
///         executable cash) holds with her kept floor counted. Had she serviced then, the fix
///         would have written her floor down. A service does not come, so without a trim the kept
///         floor stays, and the last lender out is short by it.
/// @dev Asserts the behaviour with NO trim called, so it pins what `trimRequestFloor` exists to
///      end; `Issue64_FloorTrim` is the same shape with the trim. Bare pool over `MockUSDC`
///      (`R63A3_Fixture`); six-decimal USDC base units; every `MEASURED` line was read from a run
///      before the figure beside it was asserted.
contract Issue64_KeptFloorAfterShortfall is R63A3_Fixture {
    uint256 internal constant T = 100_000e6;

    address internal r0 = makeAddr("dust-requester");
    address internal r1 = makeAddr("honest-requester");
    address internal d0 = makeAddr("dormant-0");
    address internal d1 = makeAddr("dormant-1-last-out");

    function _worth(address who) internal view returns (uint256) {
        return pool.previewRedeem(pool.balanceOf(who) + _requestShares(who));
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

    function _shapeToDust() internal returns (uint256 drew) {
        _deposit(r0, T / 5);
        _deposit(r1, T / 5);
        _deposit(d0, T * 3 / 10);
        _deposit(d1, T * 3 / 10);
        _requestAll(r0);
        _requestAll(r1);
        _lend(T * 2 / 5);
        vm.prank(manager);
        pool.socialiseLoss(10_000e6);
        _loseCash(25_000e6);
        console2.log("MEASURED before dust service: E / floors / shortfall", _executable(), _floorTotal(), _shortfall());
        drew = _drainLeaving(r0, 1);
        console2.log("MEASURED after dust service: drew / kept / dust shares", drew, _floorOf(r0), _requestShares(r0));
        console2.log("MEASURED after dust service: E / floors / shortfall", _executable(), _floorTotal(), _shortfall());
    }

    function test_withoutATrim_theKeptFloorOutlivesTheShortfall() public {
        _shapeToDust();
        uint256 kept = _floorOf(r0);
        assertEq(_requestShares(r0), 1, "setup: she did not reach one share-wei");
        assertGt(_shortfall(), 0, "setup: her dust service was not made under a standing shortfall");
        assertTrue(pool.requestWriteDownDeclined(r0), "the declined write-down did not mark her request");

        // The honest requester completes: her whole floor goes, and with it the shortfall.
        uint256 r1Drew = _drainLeaving(r1, 0);
        console2.log("MEASURED honest requester drew", r1Drew);
        console2.log("MEASURED after honest exit: E / floors / shortfall", _executable(), _floorTotal(), _shortfall());
        assertEq(_shortfall(), 0, "the shortfall still stands after the honest requester left");
        // The fix's own predicate now holds, with the kept floor counted: had she serviced here,
        // the write-down would have been taken. Nothing but a trim takes it.
        assertLe(_floorTotal(), _executable(), "the predicate does not hold after the honest exit");
        assertEq(_floorOf(r0), kept, "something other than a trim re-examined the kept floor");

        _repay(pool.outstandingPrincipal());
        console2.log(
            "MEASURED after full repay: E / floors / her kept floor", _executable(), _floorTotal(), _floorOf(r0)
        );
        console2.log("MEASURED after full repay: her dust worth", pool.convertToAssets(_requestShares(r0)));
        assertEq(_floorOf(r0), kept, "the repay re-examined the kept floor");

        uint256 d0Got = _syncExit(d0);
        uint256 d1Worth = _worth(d1);
        uint256 d1Got = _syncExit(d1);
        uint256 stranded = _worth(d1);
        console2.log("MEASURED first dormant took", d0Got);
        console2.log("MEASURED last lender out: worth / took / left behind", d1Worth, d1Got, stranded);
        assertApproxEqAbs(kept, 7_000e6, 2, "the kept floor is not the measured 7,000");
        assertApproxEqAbs(stranded, kept, 10, "the last lender out is not short by the kept floor");
        console2.log("VERDICT KEPT: with no trim, a floor kept on one share-wei outlives the shortfall");
    }
}
