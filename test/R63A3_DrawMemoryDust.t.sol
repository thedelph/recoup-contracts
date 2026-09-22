// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title Round 63 seat A3, item 2: the request-draw memory and the floors under share DUST.
/// @notice Ledger row 374's unexecuted lead: `serviceWithdrawalRequest` deletes a controller's
///         request-draw memory only when her request is empty AND `balanceOf(controller) == 0`,
///         so a stranger's one share-wei keeps the memory alive. Measured here: what that costs
///         her, what it cannot do, and the dust shape that turned out to matter more, a
///         request serviced down to ONE share-wei keeping the rest of its floor.
/// @dev Every `MEASURED` line was read from a run before the figure beside it was asserted.
contract R63A3_DrawMemoryDust is R63A3_Fixture {
    address internal victim = makeAddr("victim");
    address internal other = makeAddr("other");
    address internal griefer = makeAddr("griefer");

    /// @dev One share-wei from the stranger, who buys it with one asset-wei (1,000 share-wei).
    function _dust(address to) internal {
        if (pool.balanceOf(stranger) == 0) _deposit(stranger, 1);
        vm.prank(stranger);
        pool.transfer(to, 1);
    }

    function test_R63A3_theSlotsThisFixtureReads() public {
        _deposit(victim, 10_000e6);
        _deposit(other, 10_000e6);
        _lend(15_000e6);
        _requestAll(victim);
        uint256 shares = pool.maxRequestRedeem(victim);
        uint256 paid = _service(victim, shares);
        (uint256 memShares, uint256 memAssets) = _drawMemory(victim);
        assertEq(memShares, shares, "slot 32 is not the request-draw memory (shares)");
        assertEq(memAssets, paid, "slot 32 is not the request-draw memory (assets)");
        assertEq(_floorTotal(), _floorOf(victim), "slot 33 is not the floor total");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Row 374's lead: a stranger's share-wei keeps the memory alive
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The victim's first cycle: 10,000 beside another 10,000 with 15,000 lent; she queues,
    ///      draws her 2,500 floor, the loan repays and she completes. `dusted` puts one
    ///      share-wei in her wallet before the completing service.
    function _firstCycle(bool dusted) internal {
        _deposit(victim, 10_000e6);
        _deposit(other, 10_000e6);
        _lend(15_000e6);
        _requestAll(victim);
        _drainToZeroCash(victim);
        _repay(15_000e6);
        if (dusted) _dust(victim);
        _drainToZeroCash(victim);
        assertEq(_requestShares(victim), 0, "fixture: the first cycle did not complete");
    }

    function test_R63A3_D1_aStrangersShareWeiKeepsTheMemoryAndUnderServesTheNextRequest() public {
        uint256 clean = vm.snapshotState();
        uint256[2] memory doorAtFloor;
        uint256[2] memory doorAfterHalfRepay;
        uint256[2] memory doorAfterFullRepay;
        for (uint256 k; k < 2; ++k) {
            vm.revertToState(clean);
            _firstCycle(k == 1);
            (uint256 memShares, uint256 memAssets) = _drawMemory(victim);
            console2.log("MEASURED dusted? / memory shares after the exit      ", k, memShares);
            console2.log("MEASURED dusted? / memory assets after the exit      ", k, memAssets);
            console2.log("MEASURED dusted? / her wallet shares                 ", k, pool.balanceOf(victim));

            // Second cycle, same address: she re-enters, the loan goes out again, she queues.
            _deposit(victim, 10_000e6);
            _lend(15_000e6);
            uint256 walletShares = pool.balanceOf(victim);
            _request(victim, walletShares);
            doorAtFloor[k] = _serviceable(victim);
            console2.log("MEASURED dusted? / her floor on the second request   ", k, _floorOf(victim));
            console2.log("MEASURED dusted? / her door, 15,000 lent             ", k, doorAtFloor[k]);
            _repay(7_500e6);
            doorAfterHalfRepay[k] = _serviceable(victim);
            console2.log("MEASURED dusted? / her door after 7,500 repaid       ", k, doorAfterHalfRepay[k]);
            uint256 half = vm.snapshotState();
            _repay(7_500e6);
            doorAfterFullRepay[k] = _serviceable(victim);
            console2.log("MEASURED dusted? / her door after all 15,000 repaid  ", k, doorAfterFullRepay[k]);

            if (k == 1) {
                // Her way out: cancel, move the shares to a fresh address, queue from there.
                vm.revertToState(half);
                _cancel(victim);
                uint256 all = pool.balanceOf(victim);
                vm.prank(victim);
                pool.transfer(fresh, all);
                _requestAll(fresh);
                console2.log("MEASURED dusted, moved to a fresh address: door      ", _serviceable(fresh));
                console2.log("MEASURED dusted, moved to a fresh address: floor     ", _floorOf(fresh));
            }
        }
        console2.log(
            "MEASURED under-service after 7,500 repaid            ", doorAfterHalfRepay[0] - doorAfterHalfRepay[1]
        );
        assertEq(doorAtFloor[0], doorAtFloor[1], "the dust moved the door the floor holds");
        assertGt(doorAfterHalfRepay[0], doorAfterHalfRepay[1], "the surviving memory did not under-serve her");
        assertGe(doorAfterHalfRepay[1], 2_500e6 - 1, "the under-served door fell below the fresh floor");
        assertEq(doorAfterHalfRepay[0], 6_250e6, "the clean door after 7,500 repaid is not 6,250");
        assertEq(doorAfterHalfRepay[1], 5_000e6, "the dusted door after 7,500 repaid is not 5,000");
        assertEq(doorAfterFullRepay[0], doorAfterFullRepay[1], "the memory still under-serves once the loan is home");
    }

    /// @notice What the stranger's dust canNOT do: it does not move her live door, it does not
    ///         write or reset anybody's memory, and dust sent AFTER she completed changes nothing.
    function test_R63A3_D2_whatAStrangersDustCannotDo() public {
        _deposit(victim, 10_000e6);
        _deposit(other, 10_000e6);
        _lend(15_000e6);
        _requestAll(victim);
        uint256 doorBefore = pool.maxRequestRedeem(victim);
        (uint256 s0, uint256 a0) = _drawMemory(victim);
        _dust(victim);
        (uint256 s1, uint256 a1) = _drawMemory(victim);
        console2.log(
            "MEASURED door before / after the dust (shares)        ", doorBefore, pool.maxRequestRedeem(victim)
        );
        assertEq(pool.maxRequestRedeem(victim), doorBefore, "a stranger's dust moved a live door");
        assertEq(s0, s1, "a stranger's dust wrote the memory (shares)");
        assertEq(a0, a1, "a stranger's dust wrote the memory (assets)");

        // A stranger cannot service, cancel or re-request for her.
        vm.prank(stranger);
        vm.expectRevert();
        pool.serviceWithdrawalRequest(victim, 1, 0);

        // Dust after completion: the memory is already gone and stays gone.
        vm.prank(victim);
        pool.transfer(sink, 1); // she sweeps the dust out first
        _drainToZeroCash(victim);
        _repay(15_000e6);
        _drainToZeroCash(victim);
        (uint256 s2,) = _drawMemory(victim);
        assertEq(s2, 0, "fixture: a clean completion did not clear the memory");
        _dust(victim);
        (uint256 s3,) = _drawMemory(victim);
        assertEq(s3, 0, "dust after completion revived the memory");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. The dust that matters: a request serviced down to one share-wei keeps its floor
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The raw-loss shape. Three floors of 100.000000, 50.000000 lost: each draws her
    ///         50.000000 cap and the three are left with floors of 50.000000 over shares worth
    ///         33.333333, 100.000000 of cash and every door at 0. Holder 1 cancels. HONEST:
    ///         holders 0 and 2 complete, every floor is released and the canceller walks out
    ///         with her 33.333333. GRIEF: holder 0 services all but ONE share-wei, takes the
    ///         same cash, and her request keeps the rest of its floor for ever.
    /// @dev #64 (round 63 seat A3's F1, a floor kept for ever on one share-wei). This test pinned
    ///      the finding as the tree stood; its dust-held-floor assertions are FLIPPED to the #64
    ///      fix, which writes the floor left on dust down to what the dust is worth while the
    ///      floors sit inside the executable cash.
    function test_R63A3_D3_aRequestServicedToOneShareWeiKeepsItsFloor_rawLoss() public {
        _queueEqualFloors(3, EACH);
        _loseCash(50e6);
        _drainAll(3);
        console2.log(
            "MEASURED D3: E / floors / shortfall after the draws   ", _executable(), _floorTotal(), _shortfall()
        );
        _cancel(_holder(1));
        uint256 afterCancel = vm.snapshotState();

        // Honest.
        uint256 honest0 = _drainToZeroCash(_holder(0));
        uint256 honest2 = _drainToZeroCash(_holder(2));
        uint256 honestSync = _syncable(_holder(1));
        console2.log("MEASURED D3 honest: holder 0 / holder 2 drew           ", honest0, honest2);
        console2.log("MEASURED D3 honest: floors left / canceller's sync door", _floorTotal(), honestSync);
        assertEq(_floorTotal(), 0, "the honest unwind left a floor");

        // Grief.
        vm.revertToState(afterCancel);
        uint256 door = pool.maxRequestRedeem(_holder(0));
        uint256 grief0 = _service(_holder(0), door - 1);
        console2.log("MEASURED D3 grief: holder 0 drew / shares she left     ", grief0, _requestShares(_holder(0)));
        console2.log("MEASURED D3 grief: the floor her one share-wei keeps   ", _floorOf(_holder(0)));
        uint256 grief2 = _drainToZeroCash(_holder(2));
        console2.log("MEASURED D3 grief: holder 2 drew                       ", grief2);
        console2.log("MEASURED D3 grief: E / floors                          ", _executable(), _floorTotal());
        console2.log(
            "MEASURED D3 grief: canceller's shares are worth        ", pool.previewRedeem(pool.balanceOf(_holder(1)))
        );
        console2.log("MEASURED D3 grief: canceller's sync door               ", _syncable(_holder(1)));
        console2.log("MEASURED D3 grief: holder 0's own door (cash)          ", _serviceable(_holder(0)));
        assertEq(_requestShares(_holder(0)), 1, "fixture: the griefer did not leave exactly one share-wei");
        assertGe(grief0 + 1, honest0, "the grief cost the griefer more than a wei");
        // #64 fix: the cancel put the floors back inside the cash, so the dust keeps no floor and
        // the canceller's door is her honest door to a wei (33.333333 against 33.333334).
        assertApproxEqAbs(_syncable(_holder(1)), honestSync, 1, "#64: the dust still shut the canceller out");
        assertEq(_floorOf(_holder(0)), 0, "#64: one share-wei still keeps a floor");
        assertEq(_syncable(_holder(1)), 33_333_333, "#64: the canceller's door is not 33.333333 of her 33.333335");
    }

    /// @notice The same dust on PROTOCOL paths, no raw loss: 10,000 queued beside 10,000
    ///         dormant with 10,000 lent (floor 5,000.000000); the dormant lender takes the
    ///         5,000.000000 of idle cash through `redeem`; the whole loan is then socialised
    ///         (`socialiseLoss`, the manager's call). The floors never exceed E (5,000 against
    ///         5,000), which is what round 62's campaign asserts, but the queued floor now
    ///         exceeds what her shares are WORTH (3,333.333333), and the excess is reserved
    ///         against the dormant lender until the request is completed or cancelled.
    /// @dev #64 (round 63 seat A3's F1, a floor kept for ever on one share-wei). This test pinned
    ///      the finding as the tree stood; its dust-held-floor assertions are FLIPPED to the #64
    ///      fix, which writes the floor left on dust down to what the dust is worth while the
    ///      floors sit inside the executable cash.
    function test_R63A3_D4_theSameDustOnProtocolPaths_socialisedLoss() public {
        _deposit(griefer, 10_000e6);
        _deposit(other, 10_000e6);
        _lend(10_000e6);
        _requestAll(griefer);
        console2.log("MEASURED D4: the queued floor                          ", _floorOf(griefer));
        uint256 idleShares = pool.maxRedeem(other);
        vm.prank(other);
        uint256 took = pool.redeem(idleShares, other, other);
        console2.log("MEASURED D4: the dormant lender took synchronously     ", took);
        vm.prank(manager);
        pool.socialiseLoss(10_000e6);
        console2.log(
            "MEASURED D4 after the loss: E / floors / shortfall     ", _executable(), _floorTotal(), _shortfall()
        );
        console2.log(
            "MEASURED D4 after the loss: queued shares are worth    ", pool.previewRedeem(_requestShares(griefer))
        );
        console2.log(
            "MEASURED D4 after the loss: dormant shares are worth   ", pool.previewRedeem(pool.balanceOf(other))
        );
        console2.log("MEASURED D4 after the loss: dormant sync door          ", _syncable(other));
        assertLe(_floorTotal(), _executable(), "the floors exceed E: this is the #61 lock after all");
        uint256 afterLoss = vm.snapshotState();

        // Honest: she completes, the whole floor is released.
        uint256 honest = _drainToZeroCash(griefer);
        uint256 honestOther = _syncable(other);
        console2.log("MEASURED D4 honest: she drew / floors left             ", honest, _floorTotal());
        console2.log("MEASURED D4 honest: dormant sync door                  ", honestOther);

        // Grief: all but one share-wei.
        vm.revertToState(afterLoss);
        uint256 door = pool.maxRequestRedeem(griefer);
        uint256 grief = _service(griefer, door - 1);
        uint256 kept = _floorOf(griefer);
        console2.log("MEASURED D4 grief: she drew / shares she left          ", grief, _requestShares(griefer));
        console2.log("MEASURED D4 grief: the floor her one share-wei keeps   ", kept);
        console2.log("MEASURED D4 grief: E / unreservedIdle                  ", _executable(), pool.unreservedIdle());
        console2.log(
            "MEASURED D4 grief: dormant shares are worth            ", pool.previewRedeem(pool.balanceOf(other))
        );
        console2.log("MEASURED D4 grief: dormant sync door                   ", _syncable(other));
        _requestAll(other);
        console2.log("MEASURED D4 grief: dormant lender's request floor/door ", _floorOf(other), _serviceable(other));
        console2.log("MEASURED D4 grief: available() to lend                 ", pool.available());
        assertGe(grief + 1, honest, "the grief cost the griefer more than a wei");
        // #64 fix: the dust keeps no floor, so the dormant lender reaches her honest door to a wei
        // (1,666.666665 against 1,666.666666), and available() is 0 only because her own request
        // floor now reserves that cash.
        assertApproxEqAbs(
            _syncable(other) + _serviceable(other), honestOther, 1, "#64: the dormant lender is still shut out"
        );
        assertEq(kept, 0, "#64: one share-wei still keeps a floor");
        assertEq(pool.available(), 0, "the dormant lender's own request floor does not reserve the cash");
        uint256 shut = vm.snapshotState();

        // The four doors against the kept floor.
        skip(365 days);
        console2.log("MEASURED D4 a year later: dormant request door         ", _serviceable(other));
        _deposit(fresh, 1_000e6);
        console2.log("MEASURED D4 after a 1,000 deposit: E / unreservedIdle  ", _executable(), pool.unreservedIdle());
        console2.log("MEASURED D4 after a 1,000 deposit: dormant door        ", _serviceable(other));
        console2.log("MEASURED D4 after a 1,000 deposit: depositor sync door ", _syncable(fresh));
        uint256 otherOut = _drainToZeroCash(other);
        console2.log("MEASURED D4 the dormant lender then drew               ", otherOut);
        console2.log(
            "MEASURED D4 depositor's shares worth / her sync door   ",
            pool.previewRedeem(pool.balanceOf(fresh)),
            _syncable(fresh)
        );
        console2.log("MEASURED D4 cash nobody but the griefer can release    ", _executable() - pool.unreservedIdle());

        // #64 fix: there is nothing left for her to end. Her one share-wei holds no floor and, with
        // the dormant lender's request floor reserving the cash, no door either, so only a cancel
        // removes it (was: her completing one-wei service released the kept floor).
        vm.revertToState(shut);
        assertEq(pool.maxRequestRedeem(griefer), 0, "#64: the dust holds a door without a floor");
        _cancel(griefer);
        console2.log("MEASURED D4 she cancels the dust: floors left          ", _floorTotal());
        console2.log("MEASURED D4 after her cancel: dormant door            ", _serviceable(other));
        assertEq(_floorTotal() - _floorOf(other), 0, "her completing service did not release the kept floor");
    }
}
