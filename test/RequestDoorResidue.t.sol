// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {LenderPool} from "../src/LenderPool.sol";
import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title The request door after an honest two-step exit from a lent book with yield running.
/// @notice A requester of 20,000 in a book of 100,000, half of it lent, a 5,000 yield delivery a
///         third of the way through its stream. She services half her request, then runs the
///         ordinary `maxRequestRedeem` loop. Two things are left, and neither loses anyone money:
///         1. A floor residue of 1 wei. Spending a floor rounds DOWN twice (the loop's last call
///            pays `previewRedeem(convertToShares(floor))`, one wei under the floor it was sized
///            from), so at most 1 wei of floor stays per live request, and the door it holds open
///            is 983 share-wei whose `previewRedeem` is 0.
///         2. Her yield above her floor. Her floor was spent at the first two steps; what her
///            remaining shares earned since is paid only by her live slice of the executable
///            cash, net of what she has already drawn, so while the cash stays lent it waits, and
///            it is paid once the cash comes back. A cancel then a synchronous redeem pays it in
///            full at once.
/// @dev Bare pool over `MockUSDC` (`R63A3_Fixture`); six-decimal USDC base units; every
///      `MEASURED` line was read from a run before the figure beside it was asserted.
contract RequestDoorResidue is R63A3_Fixture {
    uint256 internal constant T = 100_000e6;
    uint256 internal constant EPOCH_YIELD = 5_000e6;
    uint256 internal constant LEFT_AFTER_TWO_STEPS = 327_868_851_802;
    uint256 internal constant RESIDUE_DOOR = 983;

    address internal r0 = makeAddr("requester");
    address internal d0 = makeAddr("dormant");

    function _open() internal {
        _deposit(r0, T / 5);
        _deposit(d0, T * 4 / 5);
        _requestAll(r0);
        _lend(T / 2);
        _deliverYield(EPOCH_YIELD);
        vm.warp(block.timestamp + D / 3);
    }

    /// @dev The ordinary loop: stops on a door of 0 or a door that pays 0.
    function _drain(address who) internal returns (uint256 paid) {
        for (uint256 call; call < 96; ++call) {
            uint256 door = pool.maxRequestRedeem(who);
            uint256 left = _requestShares(who);
            if (door == 0 || left == 0) break;
            if (pool.previewRedeem(door) == 0) break;
            paid += _service(who, door >= left ? left : door);
        }
    }

    function _twoSteps() internal {
        _open();
        _service(r0, _requestShares(r0) / 2);
        _drain(r0);
    }

    /// @notice The door left open is the 1-wei floor residue, not a slice, and it pays 0: a step
    ///         at it with `minAssetsOut = 1` is refused, and with 0 it burns her own share-wei.
    function test_requestDoor_theOneWeiFloorResidueOpensADoorThatPaysZero() public {
        _twoSteps();
        uint256 left = _requestShares(r0);
        uint256 door = pool.maxRequestRedeem(r0);
        console2.log("MEASURED shares left / door / floor", left, door, _floorOf(r0));
        assertEq(left, LEFT_AFTER_TWO_STEPS, "shares left after two steps");
        assertEq(_floorOf(r0), 1, "the floor residue is not one wei");
        assertEq(door, RESIDUE_DOOR, "door");
        assertEq(door, pool.convertToShares(1), "the door is not the one-wei residue's shares");
        assertEq(pool.previewRedeem(door), 0, "the residue's door pays");

        uint256 snap = vm.snapshotState();
        // The falsifier of the mechanism: with the residue zeroed the door is 0.
        bytes32 base = keccak256(abi.encode(r0, WITHDRAWAL_REQUESTS_SLOT));
        vm.store(address(pool), bytes32(uint256(base) + REQUEST_FLOOR_WORD), bytes32(uint256(0)));
        vm.store(address(pool), bytes32(FLOOR_TOTAL_SLOT), bytes32(_floorTotal() - 1));
        assertEq(pool.maxRequestRedeem(r0), 0, "the door is not the floor residue");
        assertTrue(vm.revertToState(snap), "snapshot");

        vm.prank(r0);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, 0, 1));
        pool.serviceWithdrawalRequest(r0, door, 1);
        vm.prank(r0);
        assertEq(pool.serviceWithdrawalRequest(r0, door, 0), 0, "a step at the residue's door paid");
        assertEq(_requestShares(r0), left - door, "the zero-paying step did not burn the door's share-wei");
    }

    /// @notice Her yield above her floor waits for the cash: with 50,000 still lent and 5,000 of
    ///         yield an epoch, her remaining shares grow in worth for nine epochs while the loop
    ///         pays none of it, and it is paid in the tenth.
    function test_requestDoor_yieldAboveTheFloorIsPaidOnlyOnceTheCashIsBack() public {
        _twoSteps();
        uint256 worthFirst;
        uint256 worthNinth;
        for (uint256 e = 1; e <= 10; ++e) {
            _deliverYield(EPOCH_YIELD);
            vm.warp(block.timestamp + D);
            _drain(r0);
            uint256 left = _requestShares(r0);
            uint256 worth = pool.convertToAssets(left);
            console2.log("MEASURED epoch / shares left / worth left", e, left, worth);
            if (e == 1) worthFirst = worth;
            if (e == 9) worthNinth = worth;
            if (e < 10) assertEq(left, LEFT_AFTER_TWO_STEPS, "the loop paid her yield while the cash was lent");
        }
        assertEq(worthFirst, 367_346_938, "worth left after epoch 1");
        assertEq(worthNinth, 530_612_243, "worth left after epoch 9");
        assertEq(_requestShares(r0), 0, "not paid once the cash came back");
    }

    /// @notice The same remainder exits at once, at its full worth, by cancel then redeem.
    function test_requestDoor_cancelThenRedeemPaysTheRemainderAtOnce() public {
        _twoSteps();
        uint256 worth = pool.previewRedeem(_requestShares(r0));
        _cancel(r0);
        uint256 shares = pool.maxRedeem(r0);
        vm.prank(r0);
        uint256 got = pool.redeem(shares, r0, r0);
        console2.log("MEASURED cancel then redeem: paid / worth before the cancel", got, worth);
        assertEq(got, worth, "cancel then redeem did not pay the remainder's worth");
        assertEq(pool.balanceOf(r0), 0, "shares left after the redeem");
    }
}
