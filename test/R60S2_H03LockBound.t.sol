// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {R42S1_H03Floor} from "./R42S1_H03Floor.t.sol";

/// @title The bound on the cash a post-loss floor locks (33audits H-03, issue #47).
/// @notice The published disposition of H-03 said the locked amount was "bounded above by the raw
///         loss". It is not. `maxRequestRedeem` caps every request at the executable cash the
///         OTHER live requests are not owed, so with several equal floors and a raw loss no
///         request can reach anything and the WHOLE remaining cash is locked. The reviewers
///         (`0x23r0`, comment 5718920756 on issue #47) filed the falsifier: three floors of
///         100.000000 USDC with 100.000000 lost lock 200.000000, and one hundred floors lock
///         9,900.000000. Their two tests are kept here verbatim under their own names,
///         `test_AuditH03_threeFloorsLockMoreThanTheRawLoss` and
///         `test_AuditH03_oneHundredFloorsLockNinetyNineTimesTheRawLoss`, together with the
///         `_checkManyFloors` helper they wrote; they passed on their side with forge 1.7.1 and
///         are re-measured here on forge 1.8.1. The excess of the floors over the cash measures
///         the SHORTFALL, not the amount locked.
///
/// @dev This file extends the floor's own fixture, `R42S1_H03Floor.t.sol`, and reuses its
///      helpers (`_deposit`, `_requestAll`, `_floorOf`, `_floorTotal`, `_executable`,
///      `_serviceLoop`, `_serviceable`, `_repay`, and the sink transfer plus
///      `reconcileCashDeficit` that simulates the raw loss). Nothing here is a second fixture.
///      The additions state what IS true: a fuzz over N equal floors and a raw loss (the cap is
///      the other floors, the lock is at most the executable cash, and it is the whole of it
///      exactly when every request's other floors cover the cash), the two ways out (a floor
///      holder cancelling, and a repayment lifting the cash above the other floors), and the
///      zero every door and both repair doors read while the lock holds. Figures are
///      six-decimal USDC base units.
contract R60S2_H03LockBound is R42S1_H03Floor {
    /// @dev The reviewers' per-holder deposit and floor, 100.000000 USDC.
    uint256 internal constant EACH = 100e6;

    // ─────────────────────────────────────────────────────────────────────────
    // A. The reviewers' reproduction, kept verbatim
    // ─────────────────────────────────────────────────────────────────────────

    function _checkManyFloors(uint256 count) internal {
        uint256 each = 100e6;

        for (uint256 i; i < count; ++i) {
            _deposit(address(uint160(0x100000 + i)), each);
        }

        for (uint256 i; i < count; ++i) {
            address holder = address(uint160(0x100000 + i));
            _requestAll(holder);
            assertEq(_floorOf(holder), each, "floor must be exactly 100 USDC");
        }

        assertEq(_floorTotal(), count * each);
        assertEq(_executable(), count * each);
        assertEq(pool.outstandingPrincipal(), 0);

        // Same external-cash-loss simulation as the published floorF test.
        vm.prank(address(pool));
        usdc.transfer(sink, each);
        pool.reconcileCashDeficit();

        uint256 cashLeft = (count - 1) * each;

        assertEq(_executable(), cashLeft);
        assertEq(usdc.balanceOf(address(pool)), cashLeft);
        assertEq(_floorTotal(), count * each);
        assertEq(pool.totalClaimable(), 0);
        assertEq(pool.unreservedIdle(), 0);
        assertEq(pool.available(), 0);
        assertEq(pool.claimSolvencyDeficit(), 0);
        assertEq(pool.entryPriceDeficit(), 0);

        for (uint256 i; i < count; ++i) {
            address holder = address(uint160(0x100000 + i));
            assertEq(pool.maxRequestRedeem(holder), 0, "a request can reach the cash");
        }

        assertGt(cashLeft, each, "locked cash must exceed cash lost");

        emit log_named_uint("queued holders", count);
        emit log_named_uint("raw USDC lost", each);
        emit log_named_uint("remaining USDC locked", cashLeft);
        emit log_named_uint("floor over-reservation", _floorTotal() - _executable());
    }

    function test_AuditH03_threeFloorsLockMoreThanTheRawLoss() public {
        _checkManyFloors(3);
    }

    function test_AuditH03_oneHundredFloorsLockNinetyNineTimesTheRawLoss() public {
        _checkManyFloors(100);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers for the additions
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The reviewers' holder addressing, so every figure in this file names the same holder.
    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0x100000 + i));
    }

    /// @dev `count` holders deposit `each` and queue the lot. Every floor is exactly `each`: the
    ///      i-th holder is quoted `(E - reserved for the i earlier floors) * each / (count - i)
    ///      * ...`, which collapses to `each` while the pool holds one unit of cash per unit of
    ///      share.
    function _queueEqualFloors(uint256 count, uint256 each) internal {
        for (uint256 i; i < count; ++i) {
            _deposit(_holder(i), each);
        }
        for (uint256 i; i < count; ++i) {
            address holder = _holder(i);
            _requestAll(holder);
            assertEq(_floorOf(holder), each, "a queued floor is not the holder's whole deposit");
        }
        assertEq(_floorTotal(), count * each, "the floors do not sum to the whole book");
        assertEq(_executable(), count * each, "the executable cash is not the whole book");
        assertEq(pool.outstandingPrincipal(), 0, "the equal-floor shape lent something");
    }

    /// @dev The raw loss: cash leaves the pool to an external sink and the pool reconciles it.
    ///      The same simulation the published floorF test uses.
    function _loseCash(uint256 amount) internal {
        vm.prank(address(pool));
        usdc.transfer(sink, amount);
        pool.reconcileCashDeficit();
    }

    /// @dev The executable cash the other live requests are not owed: the cap `maxRequestRedeem`
    ///      applies, saturating at zero once the floors exceed the cash.
    function _capOf(address who, uint256 executable) internal view returns (uint256) {
        uint256 owedToOthers = _floorTotal() - _floorOf(who);
        return executable > owedToOthers ? executable - owedToOthers : 0;
    }

    /// @dev What `maxRequestRedeem` must answer for an undrawn request while nothing is lent:
    ///      `min(max(floor, live slice), cap)` in cash, converted to shares and held to the
    ///      shares the request escrowed.
    function _expectedRequestShares(address who, uint256 executable) internal view returns (uint256) {
        (,, uint256 requestedShares,,) = pool.withdrawalRequest(who);
        uint256 slice = Math.mulDiv(executable, requestedShares, pool.totalSupply(), Math.Rounding.Floor);
        uint256 floor = _floorOf(who);
        uint256 requestCash = slice > floor ? slice : floor;
        uint256 cap = _capOf(who, executable);
        if (requestCash > cap) requestCash = cap;
        uint256 cashFundedShares = pool.convertToShares(requestCash);
        return cashFundedShares < requestedShares ? cashFundedShares : requestedShares;
    }

    /// @dev Assert the cap identity for every request and report whether EVERY cap is zero, which
    ///      is the condition the total lock is claimed to be equivalent to.
    function _assertEveryCapIsTheOtherFloors(uint256 count, uint256 executable)
        internal
        view
        returns (bool everyCapZero)
    {
        everyCapZero = true;
        for (uint256 i; i < count; ++i) {
            address holder = _holder(i);
            assertEq(
                pool.maxRequestRedeem(holder),
                _expectedRequestShares(holder, executable),
                "a request door is not min(max(floor, slice), the cash the other floors leave)"
            );
            if (_capOf(holder, executable) != 0) everyCapZero = false;
        }
    }

    /// @dev Run every request door until none of them reaches another wei of cash, in passes,
    ///      stopping when a whole pass pays nothing. Returns the cash the doors reached.
    ///
    ///      This is the fixture's `_serviceLoop` with one difference that the fuzz forced: a door
    ///      can read a non-zero SHARE count whose `previewRedeem` is zero after a loss, and
    ///      `_serviceLoop` stops only at zero shares, so it would burn shares for no cash and
    ///      still leave the door reading non-zero. The cash a door can reach is what "locked"
    ///      is measured against, so the stop condition here is zero cash. Four passes of eight
    ///      calls is a BUDGET, not an assumption: the caller asserts afterwards that every door
    ///      reaches zero, which is what fails if the budget ever binds.
    function _drainEveryDoor(uint256 count) internal returns (uint256 paid) {
        for (uint256 pass; pass < 4; ++pass) {
            uint256 before = paid;
            for (uint256 i; i < count; ++i) {
                address holder = _holder(i);
                for (uint256 call; call < 8; ++call) {
                    uint256 shares = pool.maxRequestRedeem(holder);
                    if (shares == 0 || pool.previewRedeem(shares) == 0) break;
                    vm.prank(holder);
                    paid += pool.serviceWithdrawalRequest(holder, shares, 0);
                }
            }
            if (paid == before) break;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // B. The fuzz: the cap is the other floors, and the lock is not the raw loss
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice N equal floors between 2 and 40 and a raw loss strictly inside the book. Four
    ///         statements, none of which is the published bound:
    ///         1. every request's `maxRequestRedeem` is `min(max(its floor, its live slice),
    ///            max(0, E - the other live floors))`;
    ///         2. the locked cash is E less what the doors reach when every one of them is run
    ///            to exhaustion, and no door is left open afterwards;
    ///         3. the lock is at most E;
    ///         4. it is exactly E when, for every request, the other floors cover E - and in
    ///            that regime the lock is the WHOLE remaining cash, which exceeds the raw loss
    ///            whenever the loss is under half the book. That last arm is what falsifies
    ///            "bounded above by the raw loss", and the reviewers' two rows are two points of
    ///            it (N = 3 and N = 100, each floor 100.000000, loss 100.000000).
    /// @dev The body is `_runLockCase`, which `test_R60S2_theFuzzBodyReachesBothRegimes` calls at
    ///      two fixed points so the census of which arm is reached is a test result rather than an
    ///      assumption about the draws.
    ///
    ///      Two rounding facts the arms are written around, both MEASURED rather than assumed.
    ///      A drawn request converts its cash cap through the gross conversion and is paid
    ///      through `previewRedeem`, so what it actually takes is a wei or two under its cap and
    ///      the released floor does not match it exactly; there is therefore NO closed form for
    ///      the drained regime, and an earlier `min((N - 1) * L, E)` guess was falsified by the
    ///      fuzz at N = 35, L = 234 wei (locked 1 wei against a predicted 7,956). And a cap of a
    ///      few wei converts to shares that `previewRedeem` floors back to zero, so a positive
    ///      cap does not always reach cash: the "a positive cap reaches some of it" arm is
    ///      claimed only where the cap survives that round trip.
    function testFuzz_R60S2_theLockIsTheQueueNotTheRawLoss(uint8 rawCount, uint256 rawLoss) public {
        uint256 count = 2 + (uint256(rawCount) % 39);
        uint256 loss = 1 + (rawLoss % (count * EACH - 1));
        _runLockCase(count, EACH, loss);
    }

    /// @notice The census for the fuzz above: its body, run at two fixed points, reaches BOTH
    ///         regimes. A loss of one whole floor puts every request's other floors over the
    ///         cash, so nothing is drawable and the whole 200.000000 left is locked against a
    ///         raw loss of 100.000000 - the arm that falsifies the published bound. Half a floor
    ///         leaves every cap positive and the doors drain most of the cash instead.
    function test_R60S2_theFuzzBodyReachesBothRegimes() public {
        uint256 clean = vm.snapshotState();

        (bool totalLock, uint256 locked, uint256 executable) = _runLockCase(3, EACH, EACH);
        console2.log("MEASURED total-lock regime: locked            ", locked);
        console2.log("MEASURED total-lock regime: executable        ", executable);
        assertTrue(totalLock, "a loss of one whole floor is not the total-lock regime");
        assertEq(locked, 200e6, "the total-lock regime locked other than 200");
        assertEq(executable, 200e6, "the cash left in the total-lock regime is not 200");
        assertGt(locked, EACH, "the total-lock regime did not exceed the raw loss");

        vm.revertToState(clean);

        (bool totalLockHalf, uint256 lockedHalf, uint256 executableHalf) = _runLockCase(3, EACH, EACH / 2);
        console2.log("MEASURED drained regime: locked               ", lockedHalf);
        console2.log("MEASURED drained regime: executable           ", executableHalf);
        assertFalse(totalLockHalf, "a loss of half a floor is not the drained regime");
        assertLt(lockedHalf, executableHalf, "the drained regime reached none of the cash");
    }

    /// @dev The fuzz's body, shared with the census above. Returns whether every request's cap
    ///      read zero, the cash no door reached, and the executable cash it is measured against.
    function _runLockCase(uint256 count, uint256 each, uint256 loss)
        internal
        returns (bool everyCapZero, uint256 locked, uint256 executable)
    {
        _queueEqualFloors(count, each);
        _loseCash(loss);

        executable = _executable();
        assertEq(executable, count * each - loss, "E after the loss is not the cash that is left");
        assertEq(_floorTotal(), count * each, "the loss moved a floor");

        everyCapZero = _assertEveryCapIsTheOtherFloors(count, executable);
        uint256 reachableAssets = pool.previewRedeem(pool.convertToShares(_capOf(_holder(0), executable)));

        uint256 paid = _drainEveryDoor(count);
        // Asserted before the subtraction, so the message is read rather than an arithmetic panic.
        assertLe(paid, executable, "the doors paid out more than the executable cash");
        locked = executable - paid;

        assertEq(pool.unreservedIdle(), 0, "the drained state leaves cash at the sync door");
        assertEq(pool.available(), 0, "the drained state leaves cash for lend");
        for (uint256 i; i < count; ++i) {
            assertEq(_serviceable(_holder(i)), 0, "a request door still reaches cash after the drain");
        }

        if (everyCapZero) {
            assertEq(locked, executable, "every request's other floors cover the cash and yet a door reached it");
            if (executable > loss) {
                assertGt(locked, loss, "the locked cash is bounded above by the raw loss");
            }
        } else if (reachableAssets != 0) {
            assertLt(locked, executable, "a request whose cap converts back to cash reached none of it");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C. The way out, one: a floor holder cancels
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three floors of 100.000000 and 100.000000 lost: every door reads zero and
    ///         200.000000 is locked. One holder cancelling releases EXACTLY its floor,
    ///         100.000000, which is what the other two requests' caps gain: each cap goes from 0
    ///         to 100.000000. What the next holder can then DRAW is smaller and is measured
    ///         rather than derived: 99.999999 of cap is more than its escrowed shares are worth
    ///         after the loss, so its door pays 66.666666 in one call and the third holder is
    ///         left reading 66.666667. The holder who cancelled keeps shares, not cash, so this
    ///         is a release of the reservation and never a recovery of the loss.
    function test_R60S2_oneCancelReleasesExactlyItsFloorToTheOtherRequests() public {
        uint256 count = 3;
        _queueEqualFloors(count, EACH);
        _loseCash(EACH);

        assertEq(_executable(), 200e6, "the cash left is not 200");
        for (uint256 i; i < count; ++i) {
            assertEq(pool.maxRequestRedeem(_holder(i)), 0, "a request reaches the cash before the cancel");
        }

        assertEq(_capOf(_holder(1), _executable()), 0, "a cap is open before the cancel");
        assertEq(_capOf(_holder(2), _executable()), 0, "a cap is open before the cancel");

        uint256 floorsBefore = _floorTotal();
        vm.prank(_holder(0));
        pool.cancelWithdrawalRequest();
        uint256 released = floorsBefore - _floorTotal();

        uint256 capAfter = _capOf(_holder(1), _executable());
        uint256 openedTo = _serviceable(_holder(1));
        (uint256 paid, uint256 calls) = _serviceLoop(_holder(1));

        console2.log("MEASURED floors before the cancel             ", floorsBefore);
        console2.log("MEASURED floors after the cancel              ", _floorTotal());
        console2.log("MEASURED released by the cancel               ", released);
        console2.log("MEASURED next holder's cap after the cancel   ", capAfter);
        console2.log("MEASURED next holder's door after the cancel  ", openedTo);
        console2.log("MEASURED next holder drew                     ", paid);
        console2.log("MEASURED next holder's service calls          ", calls);
        console2.log("MEASURED executable cash left                 ", _executable());
        console2.log("MEASURED third holder's door                  ", _serviceable(_holder(2)));

        assertEq(released, EACH, "the cancel released other than the cancelling holder's floor");
        assertEq(capAfter, EACH, "the cancel did not move the next holder's cap by exactly its floor");
        assertEq(openedTo, 66_666_666, "the next holder's door did not open to 66.666666");
        assertEq(paid, 66_666_666, "the next holder drew other than 66.666666");
        assertEq(calls, 1, "the next holder needed other than one service call");
        assertEq(_executable(), 133_333_334, "the cash left after that draw is not 133.333334");
        assertEq(_serviceable(_holder(2)), 66_666_667, "the third holder's door is not 66.666667");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // D. The way out, two: a repayment lifts the cash above the other floors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three holders of 100.000000 with 150.000000 lent, all three queued: each floor is
    ///         50.000000 and the floors are exactly the executable cash. A raw loss of 50.000000
    ///         closes every door, and 100.000000 is locked against a loss of 50.000000. A
    ///         repayment of 30.000000 lifts E above the other two floors by 30.000000 and each
    ///         door reopens to that much. The repayment is the borrower's, not the pool's: there
    ///         is no privileged lever here and no guaranteed time at which one arrives.
    function test_R60S2_aRepaymentReopensTheDoorsTheLossClosed() public {
        uint256 count = 3;
        for (uint256 i; i < count; ++i) {
            _deposit(_holder(i), EACH);
        }
        _lend(150e6);
        for (uint256 i; i < count; ++i) {
            _requestAll(_holder(i));
            assertEq(_floorOf(_holder(i)), 50e6, "a floor under the loan is not 50");
        }
        assertEq(_floorTotal(), 150e6, "the floors under the loan are not 150");
        assertEq(_executable(), 150e6, "the executable cash under the loan is not 150");

        _loseCash(50e6);
        assertEq(_executable(), 100e6, "the cash after the loss is not 100");
        for (uint256 i; i < count; ++i) {
            assertEq(pool.maxRequestRedeem(_holder(i)), 0, "a door is open while the floors cover the cash");
        }
        assertEq(pool.unreservedIdle(), 0, "the sync door reaches the locked cash");
        assertEq(pool.available(), 0, "lend reaches the locked cash");

        _repay(30e6);
        uint256 reopened = _serviceable(_holder(0));
        console2.log("MEASURED E after repaying 30                  ", _executable());
        console2.log("MEASURED first holder's door after the repay  ", reopened);
        console2.log("MEASURED second holder's door after the repay ", _serviceable(_holder(1)));
        console2.log("MEASURED outstanding principal left           ", pool.outstandingPrincipal());

        assertEq(_executable(), 130e6, "E after the repayment is not 130");
        assertEq(reopened, 29_999_999, "the repayment reopened the door to other than 29.999999");
        assertEq(_serviceable(_holder(1)), 29_999_999, "the second door reopened to other than 29.999999");

        (uint256 paid,) = _serviceLoop(_holder(0));
        console2.log("MEASURED first holder drew                    ", paid);
        assertEq(paid, 29_999_999, "the reopened door paid other than 29.999999");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // E. The locked state reads zero at every door and at both repair doors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Five floors of 100.000000 with 100.000000 lost. 400.000000 of recognised
    ///         shareholder cash sits in the pool and NOTHING reaches it: not the sync door, not
    ///         `lend`, not any of the five requests, and neither repair door reports a deficit to
    ///         cover, because the cash is not missing - it is promised twice. That is the shape
    ///         the disposition has to state: no privileged path out, and no guaranteed recovery
    ///         time.
    /// @dev Which of these zeros are load-bearing, MEASURED by neutering rather than assumed. The
    ///      five request-door zeros are: deleting `maxRequestRedeem`'s other-floors cap on a
    ///      scratch copy turns every one of them red. The `unreservedIdle` and `available` zeros
    ///      are NOT specific to the floors here, and a second neuter is what showed it - dropping
    ///      the floors arm from `_queueCashReserve` left this test green while reddening seven of
    ///      the fixture's own tests. The reason is the shape: the total lock needs EVERY share
    ///      queued, and with `queuedShares == totalSupply()` the reserve's pro-rata arm already
    ///      holds the whole executable cash, so the sync door's zero is over-determined in this
    ///      state. The floors arm holding cash ON ITS OWN is the fixture's floorF case, where an
    ///      unqueued holder is present; it is not re-stated here.
    function test_R60S2_theLockedStateReadsZeroAtEveryDoorAndBothRepairs() public {
        uint256 count = 5;
        _queueEqualFloors(count, EACH);
        _loseCash(EACH);

        console2.log("MEASURED executable cash locked               ", _executable());
        console2.log("MEASURED floors outstanding                   ", _floorTotal());
        console2.log("MEASURED floor over-reservation               ", _floorTotal() - _executable());
        console2.log("MEASURED unreservedIdle                       ", pool.unreservedIdle());
        console2.log("MEASURED available                            ", pool.available());
        console2.log("MEASURED claimSolvencyDeficit                 ", pool.claimSolvencyDeficit());
        console2.log("MEASURED entryPriceDeficit                    ", pool.entryPriceDeficit());
        console2.log("MEASURED totalClaimable                       ", pool.totalClaimable());

        assertEq(_executable(), 400e6, "the cash locked is not 400");
        assertEq(_floorTotal() - _executable(), EACH, "the over-reservation is not the raw loss");
        assertEq(pool.unreservedIdle(), 0, "unreservedIdle does not read zero");
        assertEq(pool.available(), 0, "available does not read zero");
        assertEq(pool.claimSolvencyDeficit(), 0, "claimSolvencyDeficit does not read zero");
        assertEq(pool.entryPriceDeficit(), 0, "entryPriceDeficit does not read zero");
        assertEq(pool.totalClaimable(), 0, "totalClaimable does not read zero");
        for (uint256 i; i < count; ++i) {
            assertEq(pool.maxRequestRedeem(_holder(i)), 0, "a request door does not read zero");
        }
    }
}
