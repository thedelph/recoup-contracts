// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title The #64 write-down prices a dust floor on the GROSS book while a mark stands.
/// @notice Built for a bug-bounty report received 2026-11-05 (classed Low, documentation), on the
///         report's shape: a 200,000 book, a requester owning 20,000 who files for all of it in an
///         idle book (floor 20,000), then 100,000 lent, then a mark, then a service down to dust.
///         Each test prints MEASURED lines; the assertions pin what was read. Disclosed in the
///         risk register under the #64 heading, "Under a mark, and after a loss".
contract S115_FloorWorthUnderAMark is R63A3_Fixture {
    address internal requester = makeAddr("requester");
    address internal dormant = makeAddr("dormant");
    address internal borrower = makeAddr("marked-borrower");

    uint256 internal constant BOOK = 200_000e6;
    uint256 internal constant OWN = 20_000e6;
    uint256 internal constant LENT = 100_000e6;

    function _build() internal {
        _deposit(requester, OWN);
        _deposit(dormant, BOOK - OWN);
        _requestAll(requester);
        _lend(LENT);
    }

    function _mark(uint256 amount) internal {
        vm.prank(manager);
        pool.impair(borrower, amount);
    }

    function _release() internal {
        vm.prank(manager);
        pool.releaseImpairment(borrower);
    }

    function _socialise(uint256 amount) internal {
        vm.prank(manager);
        pool.socialiseLoss(amount);
    }

    /// @dev The gross worth the contract writes a floor down to (convertToAssets rounded UP).
    function _grossWorth(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, pool.totalAssets() + 1, pool.totalSupply() + 1_000, Math.Rounding.Ceil);
    }

    /// @dev Service the request down to `dustBps` of the TOTAL supply left in escrow, in one call
    ///      (the door admits it: the floor binds and converts at the gross price).
    function _serviceToDust(uint256 dustBps) internal returns (uint256 dust) {
        dust = pool.totalSupply() * dustBps / 10_000;
        uint256 left = _requestShares(requester);
        require(left > dust, "dust larger than the request");
        uint256 door = pool.maxRequestRedeem(requester);
        require(door >= left - dust, "door does not admit the service");
        _service(requester, left - dust);
        dust = _requestShares(requester);
    }

    function _report(string memory label) internal view returns (uint256 floorLeft, uint256 drawable, uint256 excess) {
        uint256 dust = _requestShares(requester);
        floorLeft = _floorOf(requester);
        drawable = pool.previewRedeem(dust);
        excess = floorLeft > drawable ? floorLeft - drawable : 0;
        console2.log(label);
        console2.log("  MEASURED dust shares / supply           ", dust, pool.totalSupply());
        console2.log("  MEASURED floor left on dust             ", floorLeft);
        console2.log("  MEASURED gross worth (write-down target)", _grossWorth(dust));
        console2.log("  MEASURED previewRedeem(dust) (drawable) ", drawable);
        console2.log("  MEASURED excess over drawable           ", excess);
        console2.log("  MEASURED exitReserve / totalImpairment  ", pool.exitReserve(), pool.totalImpairment());
        console2.log("  MEASURED floorTotal / unreservedIdle    ", _floorTotal(), pool.unreservedIdle());
        console2.log("  MEASURED available()                    ", pool.available());
    }

    // 1. The report's headline: a 40,000 mark, 1% and 2% dust.
    function test_S115_1_reproduce_markAndDust() public {
        uint256[3] memory dusts = [uint256(100), 200, 500];
        for (uint256 i; i < dusts.length; ++i) {
            uint256 snap = vm.snapshotState();
            _build();
            _mark(40_000e6);
            _serviceToDust(dusts[i]);
            (uint256 floorLeft, uint256 drawable, uint256 excess) = _report(
                i == 0
                    ? "1% dust under a 40,000 mark"
                    : i == 1 ? "2% dust under a 40,000 mark" : "5% dust under a 40,000 mark"
            );
            uint256 dust = _requestShares(requester);
            // The stated bound: the excess is the mark pro-rated over the dust, plus rounding.
            uint256 bound = Math.mulDiv(pool.exitReserve(), dust, pool.totalSupply() + 1_000, Math.Rounding.Ceil) + 2;
            console2.log("  MEASURED mark * dust / supply (+2)      ", bound);
            assertGt(excess, 0, "no excess: the report does not reproduce");
            assertLe(excess, bound, "excess exceeds the mark pro-rated over the dust");
            assertLe(floorLeft, _grossWorth(dust), "floor left above the GROSS worth");
            assertGt(floorLeft, drawable);
            vm.revertToState(snap);
        }
    }

    // 2. The mark is released in full (the auction cleared the debt): the excess is gone.
    function test_S115_2_markReleasedInFull_nothingStranded() public {
        _build();
        _mark(40_000e6);
        _serviceToDust(100);
        (,, uint256 excessDuring) = _report("during the mark");
        _release();
        (uint256 floorLeft, uint256 drawable, uint256 excessAfter) = _report("after the mark is released in full");
        assertGt(excessDuring, 0);
        assertLe(floorLeft, drawable + 1, "a floor above the dust's worth outlived a fully released mark");
        assertLe(excessAfter, 1);
    }

    // 3. The auction clears SHORT: the loss is socialised and the mark released. Does the excess
    //    persist, and can anybody but the requester remove it?
    function test_S115_3_markEndsInALoss_excessPersists() public {
        _build();
        _mark(40_000e6);
        _serviceToDust(100);
        _report("during the mark");
        _socialise(40_000e6);
        _release();
        (uint256 floorLeft, uint256 drawable, uint256 excess) =
            _report("after a 40,000 loss is socialised and the mark released");
        console2.log("  MEASURED writeDownDeclined              ", pool.requestWriteDownDeclined(requester) ? 1 : 0);
        uint256 released = pool.trimRequestFloor(requester);
        console2.log("  MEASURED a stranger's trim releases     ", released);
        assertEq(released, 0, "the trim reached an unmarked request");
        assertGt(floorLeft, drawable);
        assertGt(excess, 1, "the loss left no excess");
        // The requester's own next service writes it down; completing or cancelling releases it.
        _service(requester, 1);
        (,, uint256 afterOwnService) = _report("after the requester's own one-share-wei service");
        assertLe(afterOwnService, 1, "her own service did not write it down");
    }

    // 4. The same loss, but the dust service happens BEFORE any mark: the excess is the same order,
    //    so the persistent residual of shape 3 does not need the reported pricing at all.
    function test_S115_4_dustBeforeTheMark_thenTheSameLoss() public {
        _build();
        _serviceToDust(100);
        (,, uint256 excessAtService) = _report("dust serviced with no mark standing");
        _mark(40_000e6);
        (,, uint256 excessUnderMark) = _report("then the mark");
        _socialise(40_000e6);
        _release();
        (,, uint256 excessAfterLoss) = _report("then a 40,000 loss socialised and the mark released");
        uint256 released = pool.trimRequestFloor(requester);
        console2.log("  MEASURED a stranger's trim releases     ", released);
        assertLe(excessAtService, 1);
        assertGt(excessUnderMark, 1);
        assertGt(excessAfterLoss, 1);
        assertEq(released, 0);
    }

    // 5. The guard-skip claim: an unspent floor between the impaired and the gross worth is not
    //    written down at all, but what it leaves is still at most the gross worth.
    function test_S115_5_guardSkip_staysUnderTheGrossWorth() public {
        // Filed AFTER the lending, so the floor is the cash slice (10,000), below the gross worth
        // (20,000): the guard has nothing to write down, before or after the service.
        _deposit(requester, OWN);
        _deposit(dormant, BOOK - OWN);
        _lend(LENT);
        _requestAll(requester);
        console2.log("  MEASURED floor filed after the lending  ", _floorOf(requester));
        _mark(40_000e6);
        uint256 left = _requestShares(requester);
        _service(requester, left / 2);
        (uint256 floorLeft, uint256 drawable,) = _report("filed after lending, half serviced under the mark");
        uint256 gross = _grossWorth(_requestShares(requester));
        console2.log("  MEASURED floor left <= gross worth      ", floorLeft <= gross ? 1 : 0);
        assertLe(floorLeft, gross);
        // Nothing stranded here: the floor was spent by what she drew and sits below her draw.
        assertLe(floorLeft, drawable);
    }

    // 6. The bound on leverage: what the dust holds back beyond its own draw, against what the
    //    dust itself is worth. M-06 (#64) was one share-wei holding a whole floor.
    function test_S115_6_leverage() public {
        _build();
        _mark(40_000e6);
        _serviceToDust(100);
        uint256 dust = _requestShares(requester);
        uint256 floorLeft = _floorOf(requester);
        uint256 drawable = pool.previewRedeem(dust);
        console2.log("MEASURED excess / drawable, bps          ", (floorLeft - drawable) * 10_000 / drawable);
        console2.log("MEASURED exitReserve / exitAssets, bps   ", pool.exitReserve() * 10_000 / pool.exitAssets());
        // The excess per unit of the dust's own worth is the mark over the impaired book.
        uint256 ratio = (floorLeft - drawable) * 10_000 / drawable;
        uint256 markOverExit = pool.exitReserve() * 10_000 / pool.exitAssets();
        assertApproxEqAbs(ratio, markOverExit, 1);
    }

    // 8. The comparison that decides "by design or defect": an honest request nobody has serviced
    //    at all, under the same mark. Floors are filing-time cash promises and no mark moves them,
    //    so every live request's floor stands above what its shares can draw while a mark stands.
    function test_S115_8_anUnservicedRequestUnderTheSameMark() public {
        _build();
        _mark(40_000e6);
        (uint256 floorLeft, uint256 drawable, uint256 excess) =
            _report("an unserviced 20,000 request under a 40,000 mark");
        assertEq(floorLeft, OWN);
        assertGt(excess, 0);
        console2.log("  MEASURED excess / drawable, bps         ", excess * 10_000 / drawable);
    }

    // 7. An honest requester, half serviced under the mark, then the ordinary door loop: does she
    //    complete? (The property the rounding-up comment defends.)
    function test_S115_7_honestCompletionUnderAMark() public {
        _build();
        _mark(40_000e6);
        uint256 half = _requestShares(requester) / 2;
        _service(requester, half);
        uint256 paid;
        uint256 calls;
        for (uint256 call; call < 32; ++call) {
            uint256 door = pool.maxRequestRedeem(requester);
            if (door == 0) break;
            paid += _service(requester, door);
            ++calls;
            if (_requestShares(requester) == 0) break;
        }
        console2.log("MEASURED honest loop: service calls / paid    ", calls, paid);
        uint256 sharesLeft = _requestShares(requester);
        console2.log("MEASURED honest loop: shares left / floor left", sharesLeft, _floorOf(requester));
        console2.log("MEASURED honest loop: door now               ", pool.maxRequestRedeem(requester));
        assertEq(sharesLeft, 0, "the honest loop did not complete under a mark");
    }
}
