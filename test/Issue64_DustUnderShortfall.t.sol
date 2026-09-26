// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title #64's disclosed residual: the dust-held floor while a SHORTFALL stands. Low.
/// @notice `R64A4_DustFloorCurve`'s C7 shows that under a raw loss that puts the floors over the
///         executable cash, neither requester reaches share dust: each is capped at the cash less
///         the other's floor. This suite builds the shape C7 does not: a request that DOES reach
///         dust after a socialised loss, while `_floorTotal` exceeds the executable cash both
///         before and after that service. The #64 fix writes a dust-held floor down only while the
///         floors sit inside the executable cash, so the #61 lock keeps its figures; here they do
///         not, the fix declines, and she keeps her floor exactly as the rule before the fix did.
///         The kept floor then OUTLIVES the shortfall: the loan repays in full and the last lender
///         out still leaves the kept floor behind, until she completes or cancels, or until
///         anyone calls `trimRequestFloor` once the shortfall has ended. This suite calls no
///         trim, so its figures are the ones nobody acting leaves; `Issue64_FloorTrim` is the same
///         shape with the trim.
/// @dev THIS SUITE PINS A DISCLOSED LOW RESIDUAL, NOT A PROPERTY THE FIX WANTS. It asserts the fix's
///      CURRENT behaviour (kept 7,000.000000; the last lender out short 7,000.000001) so that any
///      later change to it is a visible, deliberate one. Low because it needs an external event
///      first: a raw cash loss that puts the floors over the executable cash.
///      Bare pool over `MockUSDC` (`R63A3_Fixture`). Book 100,000: two requesters of 20,000 filed
///      in an idle book (so each is quoted her whole worth), two dormant lenders of 30,000, then
///      40,000 lent, a 10,000 socialised loss and a 25,000 raw loss (reconciled). Floors 40,000
///      against executable cash 35,000. Six-decimal USDC base units; every `MEASURED` line was
///      read from a run before the figure beside it was asserted.
contract Issue64_DustUnderShortfall is R63A3_Fixture {
    uint256 internal constant T = 100_000e6;

    address internal r0 = makeAddr("r66a4-dust-requester");
    address internal r1 = makeAddr("r66a4-honest-requester");
    address internal d0 = makeAddr("r66a4-dormant-0");
    address internal d1 = makeAddr("r66a4-dormant-1-last-out");

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

    /// @dev The shape, up to and including the dust service. Returns what she drew.
    function _shape() internal returns (uint256 drew) {
        _deposit(r0, T / 5);
        _deposit(r1, T / 5);
        _deposit(d0, T * 3 / 10);
        _deposit(d1, T * 3 / 10);
        _requestAll(r0);
        _requestAll(r1);
        assertEq(_floorOf(r0), T / 5, "fixture: an idle-book filing is not quoted its whole worth");
        _lend(T * 2 / 5);
        vm.prank(manager);
        pool.socialiseLoss(10_000e6);
        _loseCash(25_000e6);
        console2.log(
            "MEASURED S5 before: E / floors / shortfall                   ", _executable(), _floorTotal(), _shortfall()
        );
        console2.log("MEASURED S5 before: her worth / her door (cash)              ", _worth(r0), _serviceable(r0));
        assertGt(_shortfall(), 0, "fixture: no shortfall stands before the service");
        drew = _drainLeaving(r0, 1);
        console2.log(
            "MEASURED S5 after her dust service: drew / kept / dust shares", drew, _floorOf(r0), _requestShares(r0)
        );
        console2.log(
            "MEASURED S5 after her dust service: E / floors / shortfall   ", _executable(), _floorTotal(), _shortfall()
        );
    }

    function test_S5_theDustRequestUnderAStandingShortfall_keepsItsFloor_disclosedLow() public {
        uint256 drew = _shape();
        uint256 kept = _floorOf(r0);
        assertEq(_requestShares(r0), 1, "S5: she did not reach one share-wei of dust");

        // The honest requester leaves in full, then the book unwinds: the loan repays and both
        // dormant lenders take their sync doors, the second one last.
        uint256 r1Drew = _drainLeaving(r1, 0);
        uint256 d0Mid = _syncExit(d0);
        uint256 d1Mid = _syncExit(d1);
        console2.log("MEASURED S5 honest requester drew / dormants' doors mid-book", r1Drew, d0Mid, d1Mid);
        _repay(pool.outstandingPrincipal());
        uint256 d0Got = _syncExit(d0);
        uint256 d1Worth = _worth(d1);
        uint256 d1Got = _syncExit(d1);
        uint256 stranded = _worth(d1);
        console2.log("MEASURED S5 after repay: first dormant out took              ", d0Got);
        console2.log("MEASURED S5 last lender out: worth / took / left behind    ", d1Worth, d1Got, stranded);
        console2.log(
            "MEASURED S5 end: her kept floor / her dust worth / pool cash ",
            kept,
            _worth(r0),
            usdc.balanceOf(address(pool))
        );

        // The service left the floors over the cash, which is exactly where the #64 fix declines
        // the write-down, so she keeps her floor as the rule before the fix did. Disclosed Low.
        assertApproxEqAbs(kept, T / 5 - drew, 2, "S5: the kept floor is not her floor less what she drew");
        assertApproxEqAbs(kept, 7_000e6, 2, "S5: the kept floor is not the measured 7,000.000000");
        // MEASURED: the last lender out leaves 7,000.000001 behind after the loan repays in full.
        assertApproxEqAbs(stranded, kept, 10, "S5: the last lender out is not short by the whole kept floor");
    }
}
