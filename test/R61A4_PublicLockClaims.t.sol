// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {LenderPool} from "../src/LenderPool.sol";
import {R60S2_H03LockBound} from "./R60S2_H03LockBound.t.sol";

/// @title Round 61 seat A4: the public #61 / KNOWN_RISKS present-tense claims, executed.
/// @notice Every test here reads the public tree at 0f49e61 and logs MEASURED lines. None
///         asserts a figure the auditor has not first read from a run: the assertions are the
///         published claims, so a red here is a claim that DIFFERS.
contract R61A4_PublicLockClaims is R60S2_H03LockBound {
    /// @dev Claim (#61 issue body, KNOWN_RISKS #61 heading): `coverClaimDeficit(1)` and
    ///      `coverEntryPriceDeficit(1)` revert in the locked state. The public tree pins that only
    ///      in floorF, inside an `else` arm chosen by the deficit reading; nothing executes it in
    ///      the reviewers' multi-floor states. Here it is executed at N = 3, 5 and 100.
    function test_R61A4_coverDoorsRefuseOneWeiInEveryMultiFloorLock() public {
        uint256[3] memory counts = [uint256(3), 5, 100];
        uint256 clean = vm.snapshotState();
        for (uint256 k; k < counts.length; ++k) {
            _queueEqualFloors(counts[k], EACH);
            _loseCash(EACH);
            usdc.mint(repairer, 2);
            console2.log("MEASURED N                                   ", counts[k]);
            console2.log("MEASURED claimSolvencyDeficit                ", pool.claimSolvencyDeficit());
            console2.log("MEASURED entryPriceDeficit                   ", pool.entryPriceDeficit());
            vm.prank(repairer);
            vm.expectRevert(abi.encodeWithSelector(LenderPool.ClaimDeficitExceeded.selector, 1, 0));
            pool.coverClaimDeficit(1);
            vm.prank(repairer);
            vm.expectRevert(abi.encodeWithSelector(LenderPool.EntryPriceDeficitExceeded.selector, 1, 0));
            pool.coverEntryPriceDeficit(1);
            vm.revertToState(clean);
        }
    }

    /// @dev Claim (KNOWN_RISKS): "one cancel moves EACH remaining cap from 0 to 100.000000, of
    ///      which the next holder draws 66.666666"; (#61): "leaving 66.666667 for the third".
    ///      The public test reads holder 1's cap only, through a helper defined in the test file.
    ///      Here both remaining doors are read through the POOL before any draw, and the third
    ///      holder is drained, so the cash that stays locked after the cancel is measured.
    function test_R61A4_afterOneCancelBothRemainingDoorsAndWhatStaysLocked() public {
        _queueEqualFloors(3, EACH);
        _loseCash(EACH);
        vm.prank(_holder(0));
        pool.cancelWithdrawalRequest();

        uint256 e = _executable();
        console2.log("MEASURED E after cancel                      ", e);
        console2.log("MEASURED holder1 cap (helper)                ", _capOf(_holder(1), e));
        console2.log("MEASURED holder2 cap (helper)                ", _capOf(_holder(2), e));
        console2.log("MEASURED holder1 door (pool)                 ", _serviceable(_holder(1)));
        console2.log("MEASURED holder2 door (pool)                 ", _serviceable(_holder(2)));
        assertEq(_capOf(_holder(2), e), EACH, "holder 2's cap did not move to 100 as well");

        (uint256 p1,) = _serviceLoop(_holder(1));
        (uint256 p2,) = _serviceLoop(_holder(2));
        console2.log("MEASURED holder1 drew                        ", p1);
        console2.log("MEASURED holder2 drew                        ", p2);
        console2.log("MEASURED executable left                     ", _executable());
        console2.log("MEASURED floors left                         ", _floorTotal());
        console2.log("MEASURED unreservedIdle                      ", pool.unreservedIdle());
        console2.log("MEASURED holder0 (cancelled) maxRedeem USDC  ", _syncable(_holder(0)));
        assertEq(p1, 66_666_666, "the next holder drew other than 66.666666");
        assertEq(p2, 66_666_667, "the third holder drew other than 66.666667");
    }

    /// @dev Claim (KNOWN_RISKS): "in the reviewers' own regression on this source, one controller
    ///      cancelling restores 500.000000 of serviceable cash to the other request". No public
    ///      test carries that regression. Executed from the floorF state after both service loops,
    ///      in both cancel orders.
    function test_R61A4_floorF_oneCancelRestoresToTheOtherRequest() public {
        uint256 clean;
        for (uint256 order; order < 2; ++order) {
            if (order == 0) clean = vm.snapshotState();
            else vm.revertToState(clean);
            _threeLenders();
            _requestAll(bystander);
            vm.prank(address(pool));
            usdc.transfer(sink, 2_500e6);
            _serviceLoop(blocker);
            _serviceLoop(bystander);
            assertEq(_executable(), 500_000_002, "fixture: floorF's locked figure moved");
            address canceller = order == 0 ? blocker : bystander;
            address other = order == 0 ? bystander : blocker;
            console2.log("MEASURED order (0 blocker cancels, 1 bystander)", order);
            console2.log("MEASURED canceller's floor left before cancel ", _floorOf(canceller));
            console2.log("MEASURED other's floor left before cancel     ", _floorOf(other));
            vm.prank(canceller);
            pool.cancelWithdrawalRequest();
            uint256 restored = _serviceable(other);
            console2.log("MEASURED other's door after the cancel        ", restored);
            console2.log("MEASURED canceller's maxRedeem USDC after     ", _syncable(canceller));
            console2.log("MEASURED unreservedIdle after                 ", pool.unreservedIdle());
            (uint256 paid,) = _serviceLoop(other);
            console2.log("MEASURED other drew                           ", paid);
            console2.log("MEASURED executable left                      ", _executable());
        }
    }

    /// @dev Is a DEPOSIT a third release? The published recovery conditions are exactly two, a
    ///      repayment or a floor holder's cancel ("Two doors", #61). A new lender's deposit also
    ///      raises executable cash. Measured: what the old doors read after it, and what the
    ///      depositor herself can reach, synchronously and through a request.
    function test_R61A4_aDepositIntoTheLockedPool() public {
        _queueEqualFloors(3, EACH);
        _loseCash(EACH);
        console2.log("MEASURED maxDeposit(fresh) in the lock        ", pool.maxDeposit(fresh));

        uint256 shares = _deposit(fresh, EACH);
        console2.log("MEASURED fresh shares minted                  ", shares);
        console2.log("MEASURED fresh shares worth                   ", pool.previewRedeem(shares));
        console2.log("MEASURED E after the deposit                  ", _executable());
        console2.log("MEASURED fresh maxRedeem USDC                 ", _syncable(fresh));
        console2.log("MEASURED unreservedIdle                       ", pool.unreservedIdle());
        for (uint256 i; i < 3; ++i) {
            console2.log("MEASURED old holder door after deposit        ", _serviceable(_holder(i)));
        }

        _requestAll(fresh);
        console2.log("MEASURED fresh's quoted floor                 ", _floorOf(fresh));
        console2.log("MEASURED fresh's request door                 ", _serviceable(fresh));

        uint256 oldPaid;
        for (uint256 i; i < 3; ++i) {
            (uint256 p,) = _serviceLoop(_holder(i));
            oldPaid += p;
        }
        console2.log("MEASURED old holders drew in total            ", oldPaid);
        console2.log("MEASURED fresh's request door after they drew ", _serviceable(fresh));
        (uint256 fp,) = _serviceLoop(fresh);
        console2.log("MEASURED fresh drew                           ", fp);
        console2.log("MEASURED executable left                      ", _executable());
        console2.log("MEASURED floors left                          ", _floorTotal());
    }

    /// @dev Claim (KNOWN_RISKS): "a request filed in the locked state is quoted a floor of 0".
    ///      Executed with the one unqueued holder floorF has, the attacker, after the loss and both
    ///      service loops.
    function test_R61A4_aRequestFiledInTheLockIsQuotedFloorZero() public {
        _threeLenders();
        _requestAll(bystander);
        vm.prank(address(pool));
        usdc.transfer(sink, 2_500e6);
        _serviceLoop(blocker);
        _serviceLoop(bystander);
        uint256 floorsBefore = _floorTotal();
        _requestAll(attacker);
        console2.log("MEASURED attacker's quoted floor              ", _floorOf(attacker));
        console2.log("MEASURED floors before / after                ", floorsBefore, _floorTotal());
        console2.log("MEASURED attacker's request door              ", _serviceable(attacker));
        assertEq(_floorOf(attacker), 0, "a request filed in the lock was quoted a positive floor");
    }
}
