// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LenderPool} from "../src/LenderPool.sol";
import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title #64's residual closed by `trimRequestFloor`, and the residual the trim itself leaves.
/// @notice A service that declines the #64 write-down because the floors stand over the executable
///         cash marks the request (`requestWriteDownDeclined`), and the permissionless
///         `trimRequestFloor` applies the same write-down, on the same predicate, once
///         `_floorTotal` is back inside the executable cash. Same shape as
///         `Issue64_DustUnderShortfall` and `Issue64_KeptFloorAfterShortfall`: book 100,000, two
///         requesters of 20,000 filed in an idle book, two dormant lenders of 30,000, 40,000 lent,
///         a 10,000 socialised loss, then a 25,000 raw loss (reconciled).
/// @dev Four properties and one residual: the kept floor is refused under the shortfall and
///      released after it (and the last lender out is whole); an UNSERVICED request is never
///      trimmed, so a price fall never moves an honest requester's filing-time reservation; a trim
///      takes no cash from the requester it applies to (trimmed or not she draws the same and
///      completes); a request with nothing marked, or no request, returns 0; and a SECOND
///      raw loss that lands before anyone trims holds the kept floor as a #61 lock until the cash
///      covers it again. Bare pool over `MockUSDC` (`R63A3_Fixture`); six-decimal USDC base units;
///      every `MEASURED` line was read from a run before the figure beside it was asserted.
contract Issue64_FloorTrim is R63A3_Fixture {
    uint256 internal constant T = 100_000e6;

    address internal r0 = makeAddr("dust-requester");
    address internal r1 = makeAddr("honest-requester");
    address internal d0 = makeAddr("dormant-0");
    address internal d1 = makeAddr("dormant-1-last-out");

    function _worth(address who) internal view returns (uint256) {
        return pool.previewRedeem(pool.balanceOf(who) + _requestShares(who));
    }

    /// @dev The worth `trimRequestFloor` and the service path write a floor down to: the gross
    ///      conversion `convertToAssets` uses (offset 3, so 10**3 virtual shares and 1 virtual
    ///      asset), rounded UP. Recomputed from the public views, never read from the pool.
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

    /// @notice The dust floor is refused under the shortfall and released after it, by anyone.
    function test_trim_releasesTheKeptFloorOnceTheCashIsBack() public {
        _book();
        _loseCash(25_000e6);
        uint256 drew = _drainLeaving(r0, 1);
        uint256 kept = _floorOf(r0);
        console2.log(
            "MEASURED after dust service: drew / kept / marked", drew, kept, pool.requestWriteDownDeclined(r0) ? 1 : 0
        );
        assertEq(_requestShares(r0), 1, "setup: she did not reach one share-wei");
        assertTrue(pool.requestWriteDownDeclined(r0), "the declined write-down did not mark the request");
        assertEq(kept, 7_000e6, "the kept floor is not the 7,000 the fix declined to write down");

        // Under the standing shortfall the trim is refused: the #61 lock keeps its figures.
        uint256 floorsBefore = _floorTotal();
        uint256 shortfall = _shortfall();
        assertGt(shortfall, 0, "setup: no shortfall stands");
        vm.recordLogs();
        assertEq(_trim(r0), 0, "a trim wrote a floor down under the #61 lock");
        assertEq(vm.getRecordedLogs().length, 0, "a refused trim emitted");
        assertEq(_floorTotal(), floorsBefore, "a refused trim moved the floors");
        assertEq(_floorOf(r0), kept, "a refused trim moved her floor");
        console2.log("MEASURED trim under the shortfall: released / shortfall", uint256(0), shortfall);

        // The honest requester completes and the shortfall ends; now anyone may trim.
        uint256 r1Drew = _drainLeaving(r1, 0);
        console2.log("MEASURED honest requester drew", r1Drew);
        console2.log("MEASURED before trim: E / floors / her floor", _executable(), _floorTotal(), _floorOf(r0));
        uint256 worth = _ceilWorth(_requestShares(r0));
        floorsBefore = _floorTotal();
        (uint256 requestId,,,,) = pool.withdrawalRequest(r0);
        vm.expectEmit(true, true, false, true, address(pool));
        emit LenderPool.RequestFloorTrimmed(r0, requestId, kept - worth);
        uint256 released = _trim(r0);
        console2.log("MEASURED trim: released / her floor after / her dust worth", released, _floorOf(r0), worth);
        assertEq(released, kept - worth, "the trim did not release the floor's excess over the dust's worth");
        assertEq(_floorOf(r0), worth, "the trimmed floor is not the dust's worth");
        assertEq(_floorTotal(), floorsBefore - released, "the floor total did not fall by exactly the release");
        assertEq(_trim(r0), 0, "a second trim released again");

        _repay(pool.outstandingPrincipal());
        uint256 d0Got = _syncExit(d0);
        uint256 d1Worth = _worth(d1);
        uint256 d1Got = _syncExit(d1);
        uint256 stranded = _worth(d1);
        console2.log("MEASURED first dormant took", d0Got);
        console2.log("MEASURED last lender out: worth / took / left behind", d1Worth, d1Got, stranded);
        assertLe(stranded, 1, "the last lender out is still short after the trim");
        console2.log("VERDICT CLOSED: the kept floor is released once the floors are back inside the cash");
    }

    /// @notice The trim's event topic, pinned against its string signature rather than the
    ///         declaration, so a change of shape is a deliberate break for any indexer.
    function test_trim_eventTopicMatchesItsSignature() public pure {
        assertEq(LenderPool.RequestFloorTrimmed.selector, keccak256("RequestFloorTrimmed(address,uint256,uint256)"));
    }

    /// @notice An UNSERVICED request whose floor exceeds its worth after a price fall is never
    ///         touched, so no honest requester loses her filing-time reservation to a trim.
    function test_trim_neverTouchesAnUnservicedRequest() public {
        _book();
        uint256 worth = _ceilWorth(_requestShares(r0));
        uint256 floor = _floorOf(r0);
        console2.log("MEASURED unserviced: floor / worth / E", floor, worth, _executable());
        assertGt(floor, worth, "setup: the price fall did not put her floor over her worth");
        assertLe(_floorTotal(), _executable(), "setup: the floors are not inside the cash");
        assertFalse(pool.requestWriteDownDeclined(r0), "an unserviced request is marked");
        assertEq(_trim(r0), 0, "an unserviced request was trimmed");
        assertEq(_floorOf(r0), floor, "an unserviced floor moved");
        console2.log("VERDICT UNSERVICED UNTOUCHED: floor kept", floor);
    }

    /// @notice A controller with no request, or with a request whose floor is not above its
    ///         worth, gets 0 and no revert.
    function test_trim_returnsZeroWhereThereIsNothingToRelease() public {
        assertEq(_trim(r0), 0, "a trim of no request released something");
        assertFalse(pool.requestWriteDownDeclined(r0), "no request, yet marked");
        _deposit(r0, T / 5);
        _deposit(d0, T * 4 / 5);
        _requestAll(r0);
        uint256 floor = _floorOf(r0);
        assertEq(_trim(r0), 0, "a trim of an unmarked request at par released something");
        assertEq(_floorOf(r0), floor, "an unmarked floor at par moved");
    }

    /// @notice A trim takes no cash from the requester it applies to. An honest requester serviced
    ///         HALF under the shortfall is marked; trimmed or not, she then draws the same total and
    ///         her request completes.
    function test_trim_takesNoCashFromTheTrimmedRequester() public {
        _book();
        _loseCash(25_000e6);
        uint256 half = _requestShares(r1) / 2;
        uint256 first = _service(r1, half);
        console2.log(
            "MEASURED half service: paid / floor left / marked",
            first,
            _floorOf(r1),
            pool.requestWriteDownDeclined(r1) ? 1 : 0
        );
        assertTrue(pool.requestWriteDownDeclined(r1), "setup: the half service was not declined under the shortfall");
        // The shortfall ends when r0 leaves in full.
        _drainLeaving(r0, 0);
        assertEq(_shortfall(), 0, "setup: the shortfall did not end");

        uint256 snap = vm.snapshotState();
        uint256 untrimmed = _drainLeaving(r1, 0);
        assertTrue(vm.revertToState(snap), "snapshot");
        uint256 released = _trim(r1);
        uint256 trimmed = _drainLeaving(r1, 0);
        uint256 leftShares = _requestShares(r1);
        uint256 leftWorth = pool.convertToAssets(leftShares);
        console2.log("MEASURED honest half: released / drew untrimmed / drew trimmed", released, untrimmed, trimmed);
        console2.log(
            "MEASURED honest half, trimmed: shares left in the request / their worth / door",
            leftShares,
            leftWorth,
            pool.maxRequestRedeem(r1)
        );
        assertGt(released, 0, "setup: the trim released nothing");
        // The trimmed floor is the worth rounded UP, the figure the service path writes to, so the
        // ordinary loop draws exactly what it would have untrimmed and completes: no share-wei is
        // left behind a door of 0.
        assertEq(trimmed, untrimmed, "the trim changed what the trimmed requester draws");
        assertEq(leftShares, 0, "the trim left share dust in the trimmed request");
        assertEq(leftWorth, 0, "value left behind in the trimmed request");
        if (leftShares != 0) {
            _cancel(r1);
            console2.log("MEASURED honest half, after cancel: shares back / worth", pool.balanceOf(r1), _worth(r1));
        }
        console2.log("VERDICT NO VALUE TAKEN: trimmed or not, she draws the same and completes");
    }

    /// @notice The residual of the trim, measured: the trim waits for the floors (hers included) to
    ///         sit inside the cash, so a SECOND raw loss that lands before anyone trims turns her
    ///         kept floor into a #61 lock held by one share-wei, and the trim refuses it until the
    ///         cash covers the floors again.
    function test_trim_residual_aSecondRawLossBeforeAnyTrim() public {
        _book();
        _loseCash(25_000e6);
        _drainLeaving(r0, 1);
        _drainLeaving(r1, 0);
        uint256 kept = _floorOf(r0);
        console2.log("MEASURED after both requesters: E / floors / kept", _executable(), _floorTotal(), kept);
        // Nobody trims. A second raw loss takes the cash below her kept floor.
        _loseCash(3_000e6);
        uint256 e = _executable();
        console2.log("MEASURED after a second raw loss: E / floors / shortfall", e, _floorTotal(), _shortfall());
        uint256 d0Door = _syncable(d0);
        uint256 d1Door = _syncable(d1);
        uint256 released = _trim(r0);
        console2.log("MEASURED dormant doors / trim released", d0Door, d1Door, released);
        assertGt(_shortfall(), 0, "setup: the second loss did not open a shortfall");
        assertEq(released, 0, "the trim wrote a floor down under a standing shortfall");
        assertEq(d0Door + d1Door, 0, "a dormant door opened under the lock");
        // What ends it: cash back above her kept floor, then anyone trims.
        _repay(5_000e6);
        released = _trim(r0);
        console2.log("MEASURED after a 5,000 repayment: trim released / dormant door", released, _syncable(d0));
        assertEq(released, kept - _ceilWorth(_requestShares(r0)), "the trim did not release after the cash came back");
        console2.log(
            "VERDICT RESIDUAL: a kept floor caught by a second raw loss before any trim is held as a #61 lock until the cash covers it"
        );
    }
}
