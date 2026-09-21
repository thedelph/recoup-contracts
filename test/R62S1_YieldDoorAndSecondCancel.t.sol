// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {R60S2_H03LockBound} from "./R60S2_H03LockBound.t.sol";

/// @title The reviewers' two recovery qualifications on the post-loss lock (33audits #61,
///        comment 5734172519, 0x23r0, 2026-09-18), measured.
/// @notice Q1: an accepted yield delivery restores service on its own, with no repayment, deposit
///         or cancellation. Q2: with three floors of 100.000000 and 200.000000 lost, one cancel
///         leaves both remaining requests at `maxRequestRedeem == 0`. Both hold, and both follow
///         from one quantity: the SHORTFALL, `_floorTotal` less the executable cash `E`. Every
///         request's cap is `E - (floors - own floor)`, which is its own floor less the shortfall,
///         so every door reads 0 exactly while the shortfall is at least the largest live floor.
///         A service moves `E` and the floors down together and leaves the shortfall where it
///         was; a cancel lowers it by the cancelled floor; a repayment, a deposit or RELEASED
///         yield raises `E` and lowers it by that much. Yield is the fourth door, it is the only
///         one the protocol itself delivers, and it opens on a clock: an epoch is rated over at
///         least `Config.YIELD_STREAM_DURATION` and at most `Config.MAX_YIELD_STREAM_DURATION`,
///         and `E` excludes the unreleased part, so the doors open progressively as the stream
///         releases rather than at delivery.
/// @dev Inherits the reviewers' fixture through `R60S2_H03LockBound` (`_queueEqualFloors`,
///      `_loseCash`, `_holder`, `_capOf`) and the floor fixture's helpers beneath it. Figures
///      are six-decimal USDC base units. Every `MEASURED` line was read from a run before the
///      figure beside it was asserted.
contract R62S1_YieldDoorAndSecondCancel is R60S2_H03LockBound {
    /// @dev The floors less the executable cash, saturating: the quantity every door reads.
    function _shortfall() internal view returns (uint256) {
        uint256 floors = _floorTotal();
        uint256 executable = _executable();
        return floors > executable ? floors - executable : 0;
    }

    /// @dev An accepted epoch through the real path: the harvester role delivers `amount`.
    function _deliverYield(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.prank(harvester);
        pool.distributeYield(amount);
    }

    /// @dev A new lender's deposit of `amount`, the third door.
    function _depositFresh(uint256 amount) internal {
        _deposit(fresh, amount);
    }

    /// @dev Every holder's request door, in cash, logged under one label.
    function _logDoors(string memory label, uint256 count) internal view {
        for (uint256 i; i < count; ++i) {
            console2.log(label, i, _serviceable(_holder(i)));
        }
    }

    /// @dev Service one holder's request until it reaches no more cash, at most 128 calls. The
    ///      stop is zero CASH and not zero shares, for the reason `_drainEveryDoor` in
    ///      `R60S2_H03LockBound` gives: after a loss a door can read a few shares whose
    ///      `previewRedeem` is 0, and burning them pays nothing.
    function _drainToZeroCash(address who) internal returns (uint256 paid) {
        for (uint256 call; call < 128; ++call) {
            uint256 shares = pool.maxRequestRedeem(who);
            if (shares == 0 || pool.previewRedeem(shares) == 0) break;
            vm.prank(who);
            paid += pool.serviceWithdrawalRequest(who, shares, 0);
        }
    }

    /// @dev Each holder services her request to zero cash in turn, holder 0 first. Returns what
    ///      each drew and the total.
    function _drainInTurn(uint256 count) internal returns (uint256[] memory paid, uint256 total) {
        paid = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            paid[i] = _drainToZeroCash(_holder(i));
            total += paid[i];
        }
    }

    /// @dev Every holder's door reads zero cash.
    function _assertEveryDoorReadsZeroCash(uint256 count, string memory why) internal view {
        for (uint256 i; i < count; ++i) {
            assertEq(_serviceable(_holder(i)), 0, why);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Q1. Yield is a fourth door, and it opens over the stream
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three floors of 100.000000, 100.000000 lost, every door 0 and 200.000000 locked.
    ///         An accepted delivery of 100.000000 (the shortfall) is rated over exactly
    ///         `Config.YIELD_STREAM_DURATION`. At delivery nothing has released, `E` still reads
    ///         200.000000 and every door still reads 0. Half way through the stream 49.999999 has
    ///         released (the rate is floored) and every door reads 49.999998, of which the three
    ///         draw 149.999994 in turn and 100.000005 stays locked, the shortfall unmoved at
    ///         50.000001, until more releases. After the stream every door reads 100.000000 and
    ///         all three draw their whole 100.000000: the lock is gone with no repayment, deposit
    ///         or cancel, which is the reviewers' Q1.
    function test_R62S1_Q1_yieldEqualToTheShortfallReopensEveryDoorOverTheStream() public {
        uint256 count = 3;
        _queueEqualFloors(count, EACH);
        _loseCash(EACH);
        assertEq(_executable(), 200e6, "the cash left is not 200");
        assertEq(_shortfall(), EACH, "the shortfall is not the raw loss");
        for (uint256 i; i < count; ++i) {
            assertEq(pool.maxRequestRedeem(_holder(i)), 0, "a door is open before the delivery");
        }

        uint256 t0 = block.timestamp;
        _deliverYield(EACH);
        uint256 duration = pool.yieldStreamEndsAt() - t0;
        console2.log("MEASURED stream duration (s)                  ", duration);
        console2.log("MEASURED Config.YIELD_STREAM_DURATION (s)     ", Config.YIELD_STREAM_DURATION);
        console2.log("MEASURED Config.MAX_YIELD_STREAM_DURATION (s) ", Config.MAX_YIELD_STREAM_DURATION);
        console2.log("MEASURED at delivery: unreleased yield        ", pool.unreleasedYield());
        console2.log("MEASURED at delivery: E                       ", _executable());
        console2.log("MEASURED at delivery: shortfall               ", _shortfall());
        _logDoors("MEASURED at delivery: door of holder", count);
        assertEq(duration, Config.YIELD_STREAM_DURATION, "the epoch was not rated over the stream duration");
        assertEq(pool.unreleasedYield(), EACH, "the delivery released something at once");
        assertEq(_executable(), 200e6, "E moved at delivery");
        for (uint256 i; i < count; ++i) {
            assertEq(pool.maxRequestRedeem(_holder(i)), 0, "a door opened at delivery, before any release");
        }

        skip(duration / 2);
        console2.log("MEASURED at half release: unreleased yield    ", pool.unreleasedYield());
        console2.log("MEASURED at half release: E                   ", _executable());
        console2.log("MEASURED at half release: shortfall           ", _shortfall());
        _logDoors("MEASURED at half release: door of holder", count);
        assertEq(pool.unreleasedYield(), 50_000_001, "the unreleased half is not 50.000001");
        assertEq(_executable(), 249_999_999, "E at half release is not 249.999999");
        for (uint256 i; i < count; ++i) {
            assertEq(_serviceable(_holder(i)), 49_999_998, "a door at half release is not 49.999998");
        }

        uint256 half = vm.snapshotState();
        (uint256[] memory halfPaid, uint256 halfTotal) = _drainInTurn(count);
        for (uint256 i; i < count; ++i) {
            console2.log("MEASURED at half release: holder drew   ", i, halfPaid[i]);
        }
        console2.log("MEASURED at half release: drawn in total      ", halfTotal);
        console2.log("MEASURED at half release: E left              ", _executable());
        console2.log("MEASURED at half release: floors left         ", _floorTotal());
        console2.log("MEASURED at half release: shortfall left      ", _shortfall());
        _logDoors("MEASURED at half release, drained: door of holder", count);
        _assertEveryDoorReadsZeroCash(count, "a door reaches cash after the half-release draws");
        for (uint256 i; i < count; ++i) {
            assertEq(halfPaid[i], 49_999_998, "a holder drew other than 49.999998 at half release");
        }
        assertEq(halfTotal, 149_999_994, "the three drew other than 149.999994 at half release");
        assertEq(_executable(), 100_000_005, "the cash left after the half-release draws is not 100.000005");
        assertEq(_floorTotal(), 150_000_006, "the floors left after the half-release draws are not 150.000006");
        assertEq(_shortfall(), 50_000_001, "the half-release draws moved the shortfall");
        vm.revertToState(half);

        skip(duration - duration / 2 + 1);
        console2.log("MEASURED after the stream: unreleased yield   ", pool.unreleasedYield());
        console2.log("MEASURED after the stream: E                  ", _executable());
        console2.log("MEASURED after the stream: shortfall          ", _shortfall());
        _logDoors("MEASURED after the stream: door of holder", count);
        assertEq(pool.unreleasedYield(), 0, "the stream did not finish");
        assertEq(_executable(), 300e6, "E after the stream is not 300");
        assertEq(_shortfall(), 0, "the shortfall after the stream is not 0");
        for (uint256 i; i < count; ++i) {
            assertEq(_serviceable(_holder(i)), EACH, "a door after the stream is not the whole floor");
        }

        (uint256[] memory paid, uint256 total) = _drainInTurn(count);
        for (uint256 i; i < count; ++i) {
            console2.log("MEASURED after the stream: holder drew  ", i, paid[i]);
        }
        console2.log("MEASURED after the stream: drawn in total     ", total);
        console2.log("MEASURED after the stream: E left             ", _executable());
        console2.log("MEASURED after the stream: floors left        ", _floorTotal());
        console2.log("MEASURED after the stream: unreservedIdle     ", pool.unreservedIdle());
        _assertEveryDoorReadsZeroCash(count, "a door reaches cash after the full draw");
        for (uint256 i; i < count; ++i) {
            assertEq(paid[i], EACH, "a holder drew other than her whole floor after the stream");
        }
        assertEq(total, 300e6, "the three did not draw the whole 300 after the stream");
        assertEq(_executable(), 0, "cash is left after the full draw");
        assertEq(_floorTotal(), 0, "a floor survived the full draw");
    }

    /// @notice The same lock and three deliveries, each from the locked state and walked to the
    ///         end of its stream: 30.000000 (under the shortfall), 100.000000 (equal to it) and
    ///         200.000000 (over it). Yield under the shortfall DOES reopen the doors: each door
    ///         opens to the released amount, every holder draws that much in turn, the shortfall
    ///         is unchanged by their draws, and the doors close again with the rest still locked.
    ///         So 30.000000 of yield opens each door to 29.999999, lets 89.999997 out and leaves
    ///         140.000003 locked with the shortfall still 70.000000. 100.000000 lets all
    ///         300.000000 out. 200.000000 opens each door to 133.333332, her whole post-yield
    ///         share value; the three draw 133.333332, 133.333332 and 133.333334, 399.999998 in
    ///         all, and 2 wei of dust is left.
    function test_R62S1_Q1_yieldBelowEqualAndAboveTheShortfall() public {
        uint256 count = 3;
        uint256[3] memory deliveries = [uint256(30e6), 100e6, 200e6];
        uint256[3] memory expectedDoor = [uint256(29_999_999), 100e6, 133_333_332];
        uint256[3] memory expectedOut = [uint256(89_999_997), 300e6, 399_999_998];
        uint256[3] memory expectedLeft = [uint256(140_000_003), 0, 2];
        uint256[3] memory expectedShortfall = [uint256(70e6), 0, 0];
        _queueEqualFloors(count, EACH);
        _loseCash(EACH);
        uint256 locked = vm.snapshotState();

        for (uint256 k; k < deliveries.length; ++k) {
            vm.revertToState(locked);
            uint256 t0 = block.timestamp;
            _deliverYield(deliveries[k]);
            skip(pool.yieldStreamEndsAt() - t0 + 1);
            console2.log("MEASURED delivery                             ", deliveries[k]);
            console2.log("MEASURED after the stream: E                  ", _executable());
            console2.log("MEASURED after the stream: shortfall          ", _shortfall());
            _logDoors("MEASURED after the stream: door of holder", count);
            for (uint256 i; i < count; ++i) {
                assertEq(_serviceable(_holder(i)), expectedDoor[k], "a door after the stream read other than expected");
            }
            (uint256[] memory paid, uint256 total) = _drainInTurn(count);
            for (uint256 i; i < count; ++i) {
                console2.log("MEASURED holder drew                    ", i, paid[i]);
            }
            console2.log("MEASURED drawn in total                       ", total);
            console2.log("MEASURED E left (locked if every door is 0)   ", _executable());
            console2.log("MEASURED floors left                          ", _floorTotal());
            console2.log("MEASURED shortfall left                       ", _shortfall());
            _logDoors("MEASURED drained: door of holder", count);
            _assertEveryDoorReadsZeroCash(count, "a door reaches cash after the drain");
            assertEq(total, expectedOut[k], "the delivery let out other than expected");
            assertEq(_executable(), expectedLeft[k], "the delivery left other than expected");
            assertEq(_shortfall(), expectedShortfall[k], "the shortfall after the drain is not as expected");
        }
    }

    /// @notice The yield door on the shape a live pool is actually in, with principal out: three
    ///         holders of 100.000000, 150.000000 lent, three floors of 50.000000, 50.000000 lost
    ///         and 100.000000 locked (the repayment test's shape in `R60S2_H03LockBound`). An
    ///         epoch of 50.000000, the shortfall, walked to the end of its stream, reopens every
    ///         door with the loan still standing and nothing repaid. Measured, not derived, because
    ///         with principal out the entry-price reserve and the burnable clamp both sit on the
    ///         path.
    function test_R62S1_Q1_theYieldDoorOpensWithTheLoanStanding() public {
        uint256 count = 3;
        for (uint256 i; i < count; ++i) {
            _deposit(_holder(i), EACH);
        }
        _lend(150e6);
        for (uint256 i; i < count; ++i) {
            _requestAll(_holder(i));
        }
        _loseCash(50e6);
        assertEq(_executable(), 100e6, "the cash after the loss is not 100");
        for (uint256 i; i < count; ++i) {
            assertEq(pool.maxRequestRedeem(_holder(i)), 0, "a door is open before the delivery");
        }

        uint256 t0 = block.timestamp;
        _deliverYield(50e6);
        uint256 duration = pool.yieldStreamEndsAt() - t0;
        console2.log("MEASURED lent shape: stream duration (s)      ", duration);
        _logDoors("MEASURED lent shape, at delivery: door of holder", count);
        skip(duration + 1);
        console2.log("MEASURED lent shape, after the stream: E      ", _executable());
        console2.log("MEASURED lent shape, after the stream: floors ", _floorTotal());
        console2.log("MEASURED lent shape: outstanding principal    ", pool.outstandingPrincipal());
        _logDoors("MEASURED lent shape, after the stream: door of holder", count);
        (uint256[] memory paid, uint256 total) = _drainInTurn(count);
        for (uint256 i; i < count; ++i) {
            console2.log("MEASURED lent shape: holder drew        ", i, paid[i]);
        }
        console2.log("MEASURED lent shape: drawn in total           ", total);
        console2.log("MEASURED lent shape: E left                   ", _executable());
        assertEq(duration, Config.YIELD_STREAM_DURATION, "the lent-shape epoch was not rated over the stream duration");
        for (uint256 i; i < count; ++i) {
            assertEq(paid[i], 50e6, "a holder drew other than her whole floor of 50 with the loan standing");
        }
        assertEq(total, 150e6, "the three drew other than 150 with the loan standing");
        assertEq(_executable(), 0, "cash is left after the lent-shape draw");
        assertEq(pool.outstandingPrincipal(), 150e6, "the loan moved");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Q2. One cancel is not always enough: the count is floor(loss / floor)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three floors of 100.000000 and 200.000000 lost: 100.000000 of cash left, a shortfall
    ///         of 200.000000. One cancel takes the shortfall to 100.000000, still one whole floor,
    ///         so both remaining doors read 0, which is the reviewers' Q2. A second cancel takes
    ///         it to 0 and the last holder's door opens to her whole floor, of which she draws
    ///         33.333333, what her escrowed shares are worth at the post-loss price; the floors
    ///         reach 0 and 66.666667 is unreserved, where each canceller's `maxRedeem` reads
    ///         33.333333.
    function test_R62S1_Q2_twoHundredLostNeedsTwoCancels() public {
        uint256 count = 3;
        _queueEqualFloors(count, EACH);
        _loseCash(200e6);
        assertEq(_executable(), 100e6, "the cash left is not 100");
        console2.log("MEASURED before any cancel: E                 ", _executable());
        console2.log("MEASURED before any cancel: shortfall         ", _shortfall());
        _logDoors("MEASURED before any cancel: door of holder", count);
        for (uint256 i; i < count; ++i) {
            assertEq(pool.maxRequestRedeem(_holder(i)), 0, "a door is open before any cancel");
        }

        vm.prank(_holder(0));
        pool.cancelWithdrawalRequest();
        console2.log("MEASURED after one cancel: E                  ", _executable());
        console2.log("MEASURED after one cancel: floors             ", _floorTotal());
        console2.log("MEASURED after one cancel: shortfall          ", _shortfall());
        console2.log("MEASURED after one cancel: holder1 cap        ", _capOf(_holder(1), _executable()));
        console2.log("MEASURED after one cancel: holder2 cap        ", _capOf(_holder(2), _executable()));
        console2.log("MEASURED after one cancel: holder1 door       ", pool.maxRequestRedeem(_holder(1)));
        console2.log("MEASURED after one cancel: holder2 door       ", pool.maxRequestRedeem(_holder(2)));
        console2.log("MEASURED after one cancel: canceller maxRedeem", _syncable(_holder(0)));
        console2.log("MEASURED after one cancel: unreservedIdle     ", pool.unreservedIdle());
        assertEq(_shortfall(), EACH, "the shortfall after one cancel is not one floor");
        assertEq(pool.maxRequestRedeem(_holder(1)), 0, "holder 1's door opened after one cancel");
        assertEq(pool.maxRequestRedeem(_holder(2)), 0, "holder 2's door opened after one cancel");
        assertEq(_syncable(_holder(0)), 0, "the canceller reaches cash after one cancel");

        vm.prank(_holder(1));
        pool.cancelWithdrawalRequest();
        uint256 door = _serviceable(_holder(2));
        console2.log("MEASURED after two cancels: shortfall         ", _shortfall());
        console2.log("MEASURED after two cancels: holder2 cap       ", _capOf(_holder(2), _executable()));
        console2.log("MEASURED after two cancels: holder2 door      ", door);
        assertEq(_shortfall(), 0, "the shortfall after two cancels is not 0");
        assertEq(door, 33_333_333, "the last holder's door did not open to 33.333333");

        (uint256 paid, uint256 calls) = _serviceLoop(_holder(2));
        console2.log("MEASURED after two cancels: holder2 drew      ", paid);
        console2.log("MEASURED after two cancels: service calls     ", calls);
        console2.log("MEASURED after two cancels: floors left       ", _floorTotal());
        console2.log("MEASURED after two cancels: unreservedIdle    ", pool.unreservedIdle());
        console2.log("MEASURED after two cancels: holder0 maxRedeem ", _syncable(_holder(0)));
        console2.log("MEASURED after two cancels: holder1 maxRedeem ", _syncable(_holder(1)));
        assertEq(paid, 33_333_333, "the last holder drew other than 33.333333");
        assertEq(_floorTotal(), 0, "a floor survived the last holder's draw");
        assertEq(pool.unreservedIdle(), 66_666_667, "the cash unreserved after the draw is not 66.666667");
        assertEq(_syncable(_holder(0)), 33_333_333, "the first canceller's maxRedeem is not 33.333333");
        assertEq(_syncable(_holder(1)), 33_333_333, "the second canceller's maxRedeem is not 33.333333");
    }

    /// @notice The alternative after one cancel: with the shortfall at 100.000000 and both doors
    ///         at 0, a deposit of X or a released yield of X lowers the shortfall by X and opens
    ///         each remaining CAP by X. What the door then reads is the smaller of that cap and
    ///         what the holder's escrowed shares are worth: at X = 30.000000 both read 29.999999
    ///         either way; at X = 100.000000 a deposit opens them to 33.333333 (the depositor's
    ///         shares are priced into the same cash) and a released yield to 66.666666. A deposit
    ///         opens them at once, the yield only once its stream has released.
    function test_R62S1_Q2_afterOneCancelADepositOrAYieldOfXReopensByX() public {
        uint256 count = 3;
        _queueEqualFloors(count, EACH);
        _loseCash(200e6);
        vm.prank(_holder(0));
        pool.cancelWithdrawalRequest();
        assertEq(_shortfall(), EACH, "fixture: the shortfall after one cancel is not 100");
        uint256 oneCancel = vm.snapshotState();

        uint256[2] memory amounts = [uint256(30e6), 100e6];
        uint256[2] memory doorAfterDeposit = [uint256(29_999_999), 33_333_333];
        uint256[2] memory doorAfterYield = [uint256(29_999_999), 66_666_666];
        for (uint256 k; k < amounts.length; ++k) {
            uint256 x = amounts[k];

            vm.revertToState(oneCancel);
            _depositFresh(x);
            console2.log("MEASURED deposit of X                         ", x);
            console2.log("MEASURED after the deposit: shortfall         ", _shortfall());
            console2.log("MEASURED after the deposit: holder1 door      ", _serviceable(_holder(1)));
            console2.log("MEASURED after the deposit: holder2 door      ", _serviceable(_holder(2)));
            console2.log("MEASURED after the deposit: depositor maxRedeem", _syncable(fresh));
            assertEq(_shortfall(), EACH - x, "the deposit did not lower the shortfall by X");
            assertEq(_capOf(_holder(1), _executable()), x, "the deposit did not open holder 1's cap by X");
            assertEq(_capOf(_holder(2), _executable()), x, "the deposit did not open holder 2's cap by X");
            assertEq(_syncable(fresh), 0, "the depositor reaches cash while the floors hold it");
            assertEq(_serviceable(_holder(1)), doorAfterDeposit[k], "holder 1's door after the deposit is not as read");
            assertEq(_serviceable(_holder(2)), doorAfterDeposit[k], "holder 2's door after the deposit is not as read");

            vm.revertToState(oneCancel);
            uint256 t0 = block.timestamp;
            _deliverYield(x);
            console2.log("MEASURED yield of X                           ", x);
            console2.log("MEASURED at delivery: holder1 door            ", _serviceable(_holder(1)));
            console2.log("MEASURED at delivery: holder2 door            ", _serviceable(_holder(2)));
            assertEq(pool.maxRequestRedeem(_holder(1)), 0, "the yield opened a door before releasing");
            skip(pool.yieldStreamEndsAt() - t0 + 1);
            console2.log("MEASURED after the stream: shortfall          ", _shortfall());
            console2.log("MEASURED after the stream: holder1 door       ", _serviceable(_holder(1)));
            console2.log("MEASURED after the stream: holder2 door       ", _serviceable(_holder(2)));
            assertEq(_shortfall(), EACH - x, "the released yield did not lower the shortfall by X");
            assertEq(_capOf(_holder(1), _executable()), x, "the released yield did not open holder 1's cap by X");
            assertEq(_capOf(_holder(2), _executable()), x, "the released yield did not open holder 2's cap by X");
            assertEq(_serviceable(_holder(1)), doorAfterYield[k], "holder 1's door after the yield is not as read");
            assertEq(_serviceable(_holder(2)), doorAfterYield[k], "holder 2's door after the yield is not as read");
        }
    }

    /// @notice The general rule. N equal floors of F between 2 and 12 and a raw loss L strictly
    ///         inside the book: the lock (every door 0) holds exactly while the shortfall L is at
    ///         least F; each cancel lowers the shortfall by F; so the cancels that end it are
    ///         `floor(L / F)`, at most N - 1 because L is under N * F, and the first door to open
    ///         after them opens to `F - (L mod F)`. Pinned per cancel: every remaining door reads
    ///         0 before the count is reached, the shortfall reads `L - k * F`, and at the count the
    ///         next holder's door reads exactly the cap.
    function testFuzz_R62S1_Q2_theCancelsThatEndTheLockAreFloorOfLossOverFloor(uint8 rawCount, uint256 rawLoss) public {
        uint256 count = 2 + (uint256(rawCount) % 11);
        uint256 loss = 1 + (rawLoss % (count * EACH - 1));
        _runCancelCase(count, EACH, loss);
    }

    /// @notice The census for the fuzz above, at four fixed points: the reviewers' two rows
    ///         (loss 100 and 200 at N = 3), a loss that is not a whole number of floors, and one
    ///         under a floor, which never locks and needs no cancel.
    function test_R62S1_Q2_theFuzzBodyReachesZeroOneAndTwoCancels() public {
        uint256 clean = vm.snapshotState();
        uint256[4] memory counts = [uint256(3), 3, 5, 3];
        uint256[4] memory losses = [uint256(100e6), 200e6, 320e6, 50e6];
        uint256[4] memory expectedCancels = [uint256(1), 2, 3, 0];
        for (uint256 k; k < counts.length; ++k) {
            vm.revertToState(clean);
            (uint256 cancels, uint256 opened) = _runCancelCase(counts[k], EACH, losses[k]);
            console2.log("MEASURED census: N                            ", counts[k]);
            console2.log("MEASURED census: loss                         ", losses[k]);
            console2.log("MEASURED census: cancels that ended the lock  ", cancels);
            console2.log("MEASURED census: first door then reads        ", opened);
            assertEq(cancels, expectedCancels[k], "the census point needed other than the predicted cancels");
        }
    }

    /// @dev The fuzz's body: queue `count` floors of `each`, lose `loss`, cancel holders in order
    ///      until a remaining door reads non-zero, asserting the rule at every step. Returns the
    ///      cancels it took and what the first open door read in cash.
    function _runCancelCase(uint256 count, uint256 each, uint256 loss)
        internal
        returns (uint256 cancels, uint256 opened)
    {
        _queueEqualFloors(count, each);
        _loseCash(loss);
        uint256 predicted = loss / each;
        assertLe(predicted, count - 1, "the prediction leaves nobody queued");

        for (uint256 k; k <= count - 1; ++k) {
            uint256 executable = _executable();
            assertEq(_shortfall(), loss - k * each, "the shortfall is not the loss less the cancelled floors");
            // Which remaining doors are open: with the cap `each - shortfall`, none while the
            // shortfall is at least one floor, all otherwise.
            bool anyOpen;
            for (uint256 i = k; i < count; ++i) {
                uint256 shares = pool.maxRequestRedeem(_holder(i));
                assertEq(
                    shares,
                    _expectedRequestShares(_holder(i), executable),
                    "a door is not min(max(floor, slice), the cash the other floors leave)"
                );
                if (shares != 0) anyOpen = true;
            }
            if (anyOpen) {
                assertEq(k, predicted, "the lock ended after other than floor(loss / floor) cancels");
                uint256 cap = _capOf(_holder(k), executable);
                assertEq(cap, each - (loss - k * each), "the first open cap is not the floor less the shortfall");
                cancels = k;
                // Reported, not asserted: a cap of a wei or two converts to shares whose
                // `previewRedeem` can floor to 0 (the rounding fact `R60S2_H03LockBound` records).
                opened = _serviceable(_holder(k));
                return (cancels, opened);
            }
            assertLt(k, predicted, "every door reads 0 at the predicted count");
            vm.prank(_holder(k));
            pool.cancelWithdrawalRequest();
        }
        revert("the lock never ended, which the bound on the prediction rules out");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Q3. The same rule sizes every release: a deposit under the threshold joins the lock
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Round 62 seat A4's counterexample (`R62A4_DepositDoorEconomics`,
    ///         `test_R62A4_counterexampleADepositBelowTheThresholdJoinsTheLock`), pinned here with
    ///         its arithmetic copied so the figures are the same ones. A release of R reopens a
    ///         request only where `E + R` exceeds the floors the OTHER live requests are owed,
    ///         which with equal floors is `R > loss - one floor`. Five floors of 100.000000 and
    ///         201.940593 lost: `maxDeposit` quotes 249,701.940593 and says nothing about the
    ///         threshold of 101.940593; a deposit of 1.672435 lifts E from 298.059407 to
    ///         299.731842 against 400.000000 owed to the other four floors at every old door, so
    ///         every old door stays 0, her request is quoted a floor of 0, her request door and
    ///         sync door read 0, and her whole deposit is locked with theirs. Her shares are worth
    ///         1.672434 the block she buys them (entry and exit prices agree to a wei), so what the
    ///         lock costs her is time, not money: once every old holder cancels her door reads
    ///         1.672433 and she draws it. From the same state a deposit of 110.000000, over the
    ///         threshold, opens every old door at once.
    function test_R62S1_Q3_aDepositUnderTheThresholdJoinsTheLockWhole() public {
        uint256 count = 5;
        // A4's loss draw, verbatim.
        uint256 loss = 1 + (1359985862061957112126616385664337905031629854348 % (5 * EACH - 1));
        _queueEqualFloors(count, EACH);
        _loseCash(loss);
        uint256 eBefore = _executable();
        uint256 owedToOthers = _floorTotal() - EACH;
        uint256 threshold = owedToOthers - eBefore;
        console2.log("MEASURED loss                                 ", loss);
        console2.log("MEASURED E before the deposit                 ", eBefore);
        console2.log("MEASURED owed to the other four floors        ", owedToOthers);
        console2.log("MEASURED threshold (a deposit must exceed it) ", threshold);
        console2.log("MEASURED maxDeposit(fresh)                    ", pool.maxDeposit(fresh));
        assertEq(loss, 201_940_593, "the loss is not A4's 201.940593");
        assertEq(eBefore, 298_059_407, "E before the deposit is not 298.059407");
        assertEq(owedToOthers, 400e6, "the other four floors are not owed 400");
        assertEq(threshold, loss - EACH, "the threshold is not the loss less one floor");
        assertEq(pool.maxDeposit(fresh), 249_701_940_593, "maxDeposit is not 249,701.940593");

        uint256 clean = vm.snapshotState();

        // A4's amount draw, verbatim: 1 + (1672434 % maxDeposit).
        uint256 amount = 1 + (1_672_434 % pool.maxDeposit(fresh));
        uint256 exitShares = pool.previewWithdraw(amount);
        uint256 shares = _deposit(fresh, amount);
        console2.log("MEASURED deposit                              ", amount);
        console2.log("MEASURED shares minted / exit shares for it   ", shares, exitShares);
        console2.log("MEASURED her shares' worth at entry           ", pool.previewRedeem(shares));
        console2.log("MEASURED E after the deposit                  ", _executable());
        _logDoors("MEASURED after the deposit: old door of holder", count);
        assertEq(amount, 1_672_435, "the deposit is not A4's 1.672435");
        assertEq(shares, 2_805_539_698, "the shares minted are not 2,805,539,698");
        assertGe(shares + 1, exitShares, "she bought fewer shares than the exit price gives");
        assertEq(pool.previewRedeem(shares), 1_672_434, "her shares are not worth 1.672434 at entry");
        assertEq(_executable(), 299_731_842, "E after the deposit is not 299.731842");
        assertLe(_executable(), owedToOthers, "E cleared the other floors, which the threshold says it cannot");
        _assertEveryDoorReadsZeroCash(count, "an old door opened under the threshold");

        _requestAll(fresh);
        console2.log("MEASURED her quoted floor                     ", _floorOf(fresh));
        console2.log("MEASURED her request door / sync door         ", _serviceable(fresh), _syncable(fresh));
        uint256 reached = _drainEveryDoor(count) + _drainToZeroCash(fresh);
        console2.log("MEASURED cash any door reached after that     ", reached);
        assertEq(_floorOf(fresh), 0, "her request was quoted a positive floor");
        assertEq(_serviceable(fresh), 0, "her request door reaches cash under the threshold");
        assertEq(_syncable(fresh), 0, "her sync door reaches cash under the threshold");
        assertEq(reached, 0, "a door reached cash under the threshold");

        for (uint256 i; i < count; ++i) {
            vm.prank(_holder(i));
            pool.cancelWithdrawalRequest();
        }
        uint256 door = _serviceable(fresh);
        uint256 drew = _drainToZeroCash(fresh);
        console2.log("MEASURED floors after every old holder cancels", _floorTotal());
        console2.log("MEASURED her door after they cancel           ", door);
        console2.log("MEASURED she then drew                        ", drew);
        assertEq(_floorTotal(), 0, "a floor survived the cancels");
        assertEq(door, 1_672_433, "her door after the cancels is not 1.672433");
        assertEq(drew, 1_672_433, "she drew other than 1.672433");

        // The positive half of the same rule: a deposit over the threshold opens every old door
        // at once, to exactly E + R less the other floors.
        vm.revertToState(clean);
        uint256 over = 110e6;
        _deposit(fresh, over);
        uint256 cap = _executable() - owedToOthers;
        console2.log("MEASURED deposit over the threshold           ", over);
        console2.log("MEASURED E after it                           ", _executable());
        console2.log("MEASURED each old door's cap                  ", cap);
        _logDoors("MEASURED over the threshold: old door of holder", count);
        console2.log("MEASURED depositor's sync door                ", _syncable(fresh));
        assertEq(_executable(), 408_059_407, "E after the deposit over the threshold is not 408.059407");
        assertEq(cap, eBefore + over - owedToOthers, "the cap is not E + R less the other floors");
        assertEq(cap, 8_059_407, "the cap over the threshold is not 8.059407");
        for (uint256 i; i < count; ++i) {
            assertEq(_serviceable(_holder(i)), 8_059_406, "an old door over the threshold is not 8.059406");
        }
        assertEq(_syncable(fresh), 0, "the depositor reaches cash while the floors hold it");
    }
}
