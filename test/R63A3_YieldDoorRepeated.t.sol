// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title Round 63 seat A3, item 1: the yield door under a REPEATED delivery sequence.
/// @notice Round 62 (S1) measured the fourth door, released yield, from ONE delivery into a lock
///         of equal floors. This suite measures what S1 said it did not reach: second and third
///         deliveries landing while a stream is still releasing (rule 2 of `_rateStream`, "never
///         shorten a running stream", and rule 1's floor of `YIELD_STREAM_DURATION` between them
///         re-rate the unfinished tail), unequal floors, a partially drained lock, dormant
///         holders, a claim liquidity deficit, a frozen pot, the non-epoch `repayPrincipal`
///         surplus after one cancel on the 200-loss shape, and the entry-price reserve where it
///         binds.
/// @dev Every `MEASURED` line was read from a run before the figure beside it was asserted.
contract R63A3_YieldDoorRepeated is R63A3_Fixture {
    uint256 internal constant DUST_EPOCH = 250_000; // a quarter of Config.MIN_EPOCH_YIELD, 0.25 USDC

    /// @dev The first instant, on a grid of `step` seconds from now, at which the shortfall reads
    ///      zero. Views only; the clock is restored. Returns 0 if it never clears inside `span`.
    function _firstClear(uint256 span, uint256 step) internal returns (uint256 at) {
        uint256 t0 = block.timestamp;
        for (uint256 t = t0; t <= t0 + span; t += step) {
            vm.warp(t);
            if (_shortfall() == 0) {
                at = t;
                break;
            }
        }
        vm.warp(t0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. A second and a third delivery mid-release, at flush spacing
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three floors of 100.000000, 100.000000 lost, 100.000000 delivered: the control
    ///         clears the shortfall at the end of its stream, `D` after delivery. Add a second
    ///         delivery of 0.250000 half way through and a third of 0.250000 at `D`: each is an
    ///         epoch rated over at least `D` (rule 1's floor), so each re-rates the unfinished
    ///         tail over a fresh `D` and the release of the FIRST delivery's money slows. The
    ///         spacing here (`D / 2`) is under `Config.MIN_EPOCH_GAP`, so on the wired graph it
    ///         is a `flushLenderYield` of a parked backlog, not two `harvest` calls.
    function test_R63A3_1a_aSmallSecondDeliveryMidReleaseSlowsTheFirst() public {
        _queueEqualFloors(3, EACH);
        _loseCash(EACH);
        uint256 locked = vm.snapshotState();
        uint256 t0 = block.timestamp;

        // Control: one delivery.
        _deliverYield(EACH);
        uint256 controlClear = _firstClear(3 * D, 3600);
        vm.warp(t0 + D / 2);
        uint256 controlEHalf = _executable();
        vm.warp(t0 + D);
        uint256 controlEAtD = _executable();
        uint256 controlDoorAtD = _serviceable(_holder(0));
        console2.log("MEASURED control: shortfall clears after (s)      ", controlClear - t0);
        console2.log("MEASURED control: E at D/2                         ", controlEHalf);
        console2.log("MEASURED control: E at D / door at D               ", controlEAtD, controlDoorAtD);

        // Variant: dust epochs at D/2 and at D.
        vm.revertToState(locked);
        _deliverYield(EACH);
        uint256 rate1 = pool.yieldRate();
        vm.warp(t0 + D / 2);
        uint256 tailBefore2 = pool.unreleasedYield();
        _deliverYield(DUST_EPOCH);
        uint256 rate2 = pool.yieldRate();
        console2.log("MEASURED 2nd delivery at D/2: tail before / pot     ", tailBefore2, pool.pendingYield());
        console2.log("MEASURED 2nd delivery: stream now ends after t0 (s) ", pool.yieldStreamEndsAt() - t0);
        console2.log("MEASURED 2nd delivery: rate before / after (1e18/s) ", rate1, rate2);
        vm.warp(t0 + D);
        uint256 eAtD = _executable();
        console2.log("MEASURED at D with the 2nd delivery: E / shortfall  ", eAtD, _shortfall());
        _logDoors("MEASURED at D with the 2nd delivery: door of holder", 3);
        uint256 twoClear = _firstClear(3 * D, 3600);
        console2.log("MEASURED two deliveries: shortfall clears after (s) ", twoClear - t0);

        uint256 tailBefore3 = pool.unreleasedYield();
        _deliverYield(DUST_EPOCH);
        console2.log("MEASURED 3rd delivery at D: tail before / pot       ", tailBefore3, pool.pendingYield());
        console2.log("MEASURED 3rd delivery: stream now ends after t0 (s) ", pool.yieldStreamEndsAt() - t0);
        console2.log("MEASURED 3rd delivery: rate after (1e18/s)          ", pool.yieldRate());
        uint256 threeClear = _firstClear(4 * D, 3600);
        console2.log("MEASURED three deliveries: shortfall clears after(s)", threeClear - t0);
        vm.warp(t0 + (3 * D) / 2);
        console2.log("MEASURED at 1.5 D with three: E / shortfall         ", _executable(), _shortfall());
        _logDoors("MEASURED at 1.5 D with three: door of holder", 3);

        assertEq(controlClear - t0, D, "the control did not clear at the end of its stream");
        assertEq(controlEAtD, 300e6, "the control's E at D is not 300");
        assertLt(rate2, rate1, "a dust epoch mid-release did not lower the release rate");
        assertLt(eAtD, controlEAtD, "E at D is not lower with the dust epoch than without it");
        assertGt(twoClear, controlClear, "the dust epoch did not delay the clearing");
        assertGt(threeClear, twoClear, "the third delivery did not delay it again");
    }

    /// @notice The same sequence with second and third deliveries that are NOT dust
    ///         (100.000000 each): the rate rises, E is never below the control at any sampled
    ///         instant and the shortfall clears EARLIER than the control.
    function test_R63A3_1b_aLargeSecondDeliveryMidReleaseSpeedsTheDoor() public {
        _queueEqualFloors(3, EACH);
        _loseCash(EACH);
        uint256 locked = vm.snapshotState();
        uint256 t0 = block.timestamp;

        uint256[9] memory control;
        _deliverYield(EACH);
        for (uint256 k; k < 9; ++k) {
            vm.warp(t0 + (k * D) / 4);
            control[k] = _executable();
        }

        vm.revertToState(locked);
        _deliverYield(EACH);
        bool everBelow;
        for (uint256 k; k < 9; ++k) {
            vm.warp(t0 + (k * D) / 4);
            if (k == 2 || k == 4) _deliverYield(EACH);
            uint256 e = _executable();
            console2.log("MEASURED k (quarter of D) / control E / stacked E", k, control[k], e);
            if (e < control[k]) everBelow = true;
        }
        vm.warp(t0 + D / 2);
        vm.revertToState(locked);
        _deliverYield(EACH);
        vm.warp(t0 + D / 2);
        _deliverYield(EACH);
        uint256 clear = _firstClear(3 * D, 3600);
        console2.log("MEASURED large 2nd delivery: stream ends after t0 (s)", pool.yieldStreamEndsAt() - t0);
        console2.log("MEASURED large 2nd delivery: shortfall clears after  ", clear - t0);
        assertFalse(everBelow, "a large second delivery put E below the control");
        assertLt(clear - t0, D, "a large second delivery did not clear the shortfall before D");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. The same, at spacings `harvest` itself allows (every gap >= MIN_EPOCH_GAP)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Gaps of 7 days then 5 days, both legal under `MIN_EPOCH_GAP`. The first epoch is
    ///         rated over its 7-day accrual window; the second lands with 2 days left, is rated
    ///         over 5 days, and rule 2 does not bind (5 > 2), so the last two sevenths of the
    ///         first delivery are re-rated over 5 days.
    function test_R63A3_2a_sevenDayThenFiveDayGaps() public {
        _queueEqualFloors(3, EACH);
        _loseCash(EACH);
        skip(7 days - (block.timestamp - pool.lastYieldDistributeAt()));
        uint256 t0 = block.timestamp;
        uint256 locked = vm.snapshotState();

        _deliverYield(EACH);
        uint256 d1 = pool.yieldStreamEndsAt() - t0;
        uint256 controlClear = _firstClear(40 days, 3600);
        console2.log("MEASURED 7d gap: first stream duration (s)          ", d1);
        console2.log("MEASURED 7d gap control: clears after (s)           ", controlClear - t0);

        vm.revertToState(locked);
        _deliverYield(EACH);
        vm.warp(t0 + 5 days);
        uint256 tail = pool.unreleasedYield();
        _deliverYield(DUST_EPOCH);
        uint256 clear = _firstClear(40 days, 3600);
        console2.log("MEASURED 5d later: tail before / stream ends after t0", tail, pool.yieldStreamEndsAt() - t0);
        console2.log("MEASURED 7d then 5d: clears after (s)               ", clear - t0);
        console2.log("MEASURED 7d then 5d: delay over the control (s)     ", clear - controlClear);
        assertEq(d1, 7 days, "the first epoch was not rated over its 7-day window");
        assertGt(clear, controlClear, "the second legal epoch did not delay the clearing");
    }

    /// @notice The ceiling shape. After a long outage the first epoch is rated over
    ///         `MAX_YIELD_STREAM_DURATION` (30 days). A second epoch 29 days later (legal) is
    ///         rated over 29 days with 1 day left on the first, so the last thirtieth of the
    ///         first delivery is re-rated over 29 more days: the shortfall a 100.000000 delivery
    ///         was due to clear 30 days after delivery clears LATER than `MAX` after it.
    function test_R63A3_2b_theThirtyDayCeilingIsNotABoundOnTheFirstDeliverysMoney() public {
        _queueEqualFloors(3, EACH);
        _loseCash(EACH);
        skip(45 days);
        uint256 t0 = block.timestamp;
        uint256 locked = vm.snapshotState();

        _deliverYield(EACH);
        uint256 d1 = pool.yieldStreamEndsAt() - t0;
        uint256 controlClear = _firstClear(70 days, 3600);
        console2.log("MEASURED outage: first stream duration (s) / MAX    ", d1, Config.MAX_YIELD_STREAM_DURATION);
        console2.log("MEASURED outage control: clears after (s)           ", controlClear - t0);

        vm.revertToState(locked);
        _deliverYield(EACH);
        vm.warp(t0 + 29 days);
        uint256 tail = pool.unreleasedYield();
        uint256 eBefore = _executable();
        _deliverYield(DUST_EPOCH);
        console2.log("MEASURED 29d later: tail before / E before           ", tail, eBefore);
        console2.log("MEASURED 29d later: stream now ends after t0 (s)     ", pool.yieldStreamEndsAt() - t0);
        vm.warp(t0 + 30 days);
        console2.log("MEASURED at MAX after the first delivery: E/shortfall", _executable(), _shortfall());
        _logDoors("MEASURED at MAX after the first delivery: door of holder", 3);
        vm.warp(t0 + 29 days);
        uint256 clear = _firstClear(70 days, 3600);
        console2.log("MEASURED outage then 29d: clears after (s)          ", clear - t0);
        console2.log("MEASURED outage then 29d: clears after (days, floor)", (clear - t0) / 1 days);
        assertEq(d1, Config.MAX_YIELD_STREAM_DURATION, "the first epoch was not rated over the ceiling");
        assertEq(controlClear - t0, Config.MAX_YIELD_STREAM_DURATION, "the control did not clear at the ceiling");
        assertGt(
            clear - t0, Config.MAX_YIELD_STREAM_DURATION, "the shortfall cleared inside MAX after the first delivery"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Unequal floors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Floors of 50, 100 and 150 and 100.000000 lost. Every cap is the floor less the
    ///         shortfall, so the lock is REGRESSIVE: the 150 floor draws 50 at once, the 100
    ///         and the 50 floors read 0, and what stays locked is `sum(min(floor, L)) - L`.
    ///         Released yield then opens the doors largest floor first.
    function test_R63A3_3_unequalFloorsOpenLargestFirst() public {
        uint256[3] memory sizes = [uint256(50e6), 100e6, 150e6];
        for (uint256 i; i < 3; ++i) {
            _deposit(_holder(i), sizes[i]);
        }
        for (uint256 i; i < 3; ++i) {
            _requestAll(_holder(i));
            console2.log("MEASURED unequal: floor of holder", i, _floorOf(_holder(i)));
        }
        _loseCash(EACH);
        console2.log("MEASURED unequal after the loss: E / shortfall       ", _executable(), _shortfall());
        _logDoors("MEASURED unequal after the loss: door of holder", 3);
        uint256 drawn = _drainAll(3);
        console2.log("MEASURED unequal drained: drawn / E locked           ", drawn, _executable());
        console2.log("MEASURED unequal drained: floors / shortfall         ", _floorTotal(), _shortfall());
        for (uint256 i; i < 3; ++i) {
            console2.log("MEASURED unequal drained: floor left of holder", i, _floorOf(_holder(i)));
        }
        assertEq(drawn, 49_999_999, "the largest floor drew other than 49.999999");
        assertEq(_executable(), 150_000_001, "the locked cash is not sum(min(floor, L)) - L = 150 (and the 1 wei)");

        uint256 t0 = block.timestamp;
        _deliverYield(EACH);
        uint256[3] memory openedAt;
        for (uint256 t = t0; t <= t0 + D; t += 3600) {
            vm.warp(t);
            for (uint256 i; i < 3; ++i) {
                if (openedAt[i] == 0 && _serviceable(_holder(i)) != 0) openedAt[i] = t;
            }
        }
        for (uint256 i; i < 3; ++i) {
            console2.log("MEASURED unequal: door first non-zero after (s), holder", i, openedAt[i] - t0);
        }
        vm.warp(t0 + D / 2);
        _logDoors("MEASURED unequal at half release: door of holder", 3);
        uint256 halfDrawn = _drainAll(3);
        console2.log("MEASURED unequal at half release: drawn / E left     ", halfDrawn, _executable());
        _logDoors("MEASURED unequal at half release, drained: door of holder", 3);
        vm.warp(t0 + D + 1);
        _logDoors("MEASURED unequal after the stream: door of holder", 3);
        uint256 endDrawn = _drainAll(3);
        console2.log("MEASURED unequal after the stream: drawn / E left    ", endDrawn, _executable());
        console2.log("MEASURED unequal after the stream: floors left       ", _floorTotal());
        assertEq(openedAt[2], openedAt[1], "the two floors the drain left at the shortfall did not open together");
        assertLt(openedAt[1], openedAt[0], "the 100 floor did not open before the 50 floor");
        assertEq(openedAt[0] - t0, 219_600, "the 50 floor did not open 219,600 s in (once 50 had released)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. A partially drained lock with a non-empty draw memory, and stacked deliveries
    // ─────────────────────────────────────────────────────────────────────────

    function test_R63A3_4_partiallyDrainedLockWithADrawMemory() public {
        _queueEqualFloors(3, EACH);
        _loseCash(50e6);
        uint256 first = _drainToZeroCash(_holder(0));
        (uint256 memShares, uint256 memAssets) = _drawMemory(_holder(0));
        console2.log("MEASURED partial: holder 0 drew / her memory assets  ", first, memAssets);
        console2.log("MEASURED partial: her memory shares                  ", memShares);
        console2.log(
            "MEASURED partial: E / floors / shortfall             ", _executable(), _floorTotal(), _shortfall()
        );
        _logDoors("MEASURED partial: door of holder", 3);

        uint256 t0 = block.timestamp;
        _deliverYield(40e6);
        vm.warp(t0 + D / 2);
        _deliverYield(10e6);
        console2.log("MEASURED partial: stream ends after t0 (s)           ", pool.yieldStreamEndsAt() - t0);
        vm.warp(t0 + D);
        console2.log("MEASURED partial at D: E / shortfall                 ", _executable(), _shortfall());
        _logDoors("MEASURED partial at D: door of holder", 3);
        vm.warp(pool.yieldStreamEndsAt() + 1);
        console2.log("MEASURED partial after the streams: E / shortfall    ", _executable(), _shortfall());
        _logDoors("MEASURED partial after the streams: door of holder", 3);
        uint256 out = _drainAll(3);
        console2.log("MEASURED partial after the streams: drawn / E left   ", out, _executable());
        console2.log("MEASURED partial after the streams: floors left      ", _floorTotal());
        assertEq(_shortfall(), 0, "a shortfall survived the streams");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Dormant holders: yield UNDER the shortfall can end the lock whole
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three queued floors of 100.000000 beside two dormant holders of 100.000000 and
    ///         300.000000 lost: E 200, floors 300, shortfall 100, every door 0, and a share is
    ///         worth 0.40. A door pays the smaller of its cap and what the escrowed shares are
    ///         worth, and a service that COMPLETES a request releases the rest of its floor, so
    ///         once the cap reaches a request's share value the request completes, its whole
    ///         floor leaves the shortfall and the next door opens wider.
    function test_R63A3_5_withDormantHoldersYieldUnderTheShortfallCascades() public {
        for (uint256 i; i < 5; ++i) {
            _deposit(_holder(i), EACH);
        }
        for (uint256 i; i < 3; ++i) {
            _requestAll(_holder(i));
        }
        console2.log("MEASURED dormant: floors / E before the loss         ", _floorTotal(), _executable());
        _loseCash(300e6);
        console2.log(
            "MEASURED dormant: E / floors / shortfall             ", _executable(), _floorTotal(), _shortfall()
        );
        _logDoors("MEASURED dormant: door of holder", 3);
        console2.log("MEASURED dormant: a dormant holder's sync door       ", _syncable(_holder(3)));
        uint256 locked = vm.snapshotState();

        uint256[4] memory deliveries = [uint256(30e6), 50e6, 60e6, 100e6];
        for (uint256 k; k < deliveries.length; ++k) {
            vm.revertToState(locked);
            uint256 t0 = block.timestamp;
            _deliverYield(deliveries[k]);
            vm.warp(t0 + D + 1);
            uint256 shortfallBefore = _shortfall();
            uint256 out = _drainAll(3);
            console2.log("MEASURED dormant: delivery / shortfall before drain  ", deliveries[k], shortfallBefore);
            console2.log("MEASURED dormant:   drawn by the queue / E left      ", out, _executable());
            console2.log("MEASURED dormant:   floors left / shortfall left     ", _floorTotal(), _shortfall());
            console2.log("MEASURED dormant:   dormant sync door (each)         ", _syncable(_holder(3)));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. While a claim liquidity deficit stands
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three holders of 100.000000, 150.000000 lent, three floors of 50.000000; holder 0
    ///         services her 50.000000 and does NOT collect it, so 50.000000 of fixed claim sits
    ///         in the pool. A raw loss of 120.000000 leaves 30.000000 of cash under 50.000000 of
    ///         claims: a claim LIQUIDITY deficit of 20.000000 with no solvency deficit (the loan
    ///         backs it). What each of the four doors does in that state, and what the yield's
    ///         cash does first.
    function test_R63A3_6_theYieldDoorWhileAClaimLiquidityDeficitStands() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(_holder(i), EACH);
        }
        _lend(150e6);
        for (uint256 i; i < 3; ++i) {
            _requestAll(_holder(i));
        }
        uint256 claimed = _drainToZeroCash(_holder(0));
        console2.log("MEASURED deficit: holder 0 serviced (uncollected)    ", claimed, pool.totalClaimable());
        _loseCash(120e6);
        console2.log(
            "MEASURED deficit: liquidity / solvency deficit       ",
            pool.claimLiquidityDeficit(),
            pool.claimSolvencyDeficit()
        );
        console2.log(
            "MEASURED deficit: E / floors / shortfall             ", _executable(), _floorTotal(), _shortfall()
        );
        _logDoors("MEASURED deficit: door of holder", 3);
        console2.log("MEASURED deficit: maxDeposit(fresh)                  ", pool.maxDeposit(fresh));
        usdc.mint(fresh, 500e6);
        vm.startPrank(fresh);
        usdc.approve(address(pool), type(uint256).max);
        try pool.deposit(200e6, fresh) {
            console2.log("MEASURED deficit: a 200 deposit was ACCEPTED");
        } catch (bytes memory err) {
            console2.log("MEASURED deficit: a 200 deposit REVERTED, selector   ");
            console2.logBytes4(bytes4(err));
        }
        vm.stopPrank();
        try pool.claimFor(_holder(0)) {
            console2.log("MEASURED deficit: claimFor paid during the deficit");
        } catch (bytes memory err) {
            console2.log("MEASURED deficit: claimFor REVERTED, selector        ");
            console2.logBytes4(bytes4(err));
        }

        // The yield door: 60.000000, of which 20.000000 is the claim hole.
        uint256 t0 = block.timestamp;
        _deliverYield(60e6);
        console2.log("MEASURED deficit, at delivery: liquidity deficit     ", pool.claimLiquidityDeficit());
        console2.log("MEASURED deficit, at delivery: unreleased / E        ", pool.unreleasedYield(), _executable());
        console2.log("MEASURED deficit, at delivery: stream duration (s)   ", pool.yieldStreamEndsAt() - t0);
        _logDoors("MEASURED deficit, at delivery: door of holder", 3);
        uint256 collected = pool.claimFor(_holder(0));
        console2.log("MEASURED deficit, at delivery: holder 0 collected    ", collected);
        console2.log("MEASURED deficit, after the claim: E / unreleased    ", _executable(), pool.unreleasedYield());
        vm.warp(t0 + D / 2);
        console2.log("MEASURED deficit, at half release: E / shortfall     ", _executable(), _shortfall());
        vm.warp(t0 + D + 1);
        console2.log("MEASURED deficit, after the stream: E / shortfall    ", _executable(), _shortfall());
        _logDoors("MEASURED deficit, after the stream: door of holder", 3);
        assertEq(collected, claimed, "the fixed claim was not collected whole at delivery");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. The non-epoch leg: a `repayPrincipal` surplus after ONE cancel on the 200-loss shape
    // ─────────────────────────────────────────────────────────────────────────

    function test_R63A3_7_aRepaySurplusAfterOneCancelOnTheTwoHundredLossShape() public {
        _queueEqualFloors(3, EACH);
        _loseCash(200e6);
        _cancel(_holder(0));
        console2.log("MEASURED surplus: shortfall after one cancel         ", _shortfall());
        uint256 oneCancel = vm.snapshotState();
        uint256 t0 = block.timestamp;

        // Cold: nothing running, so rule 1a rates it over the floor D.
        _repay(EACH);
        console2.log(
            "MEASURED surplus cold: outstandingPrincipal / pot    ", pool.outstandingPrincipal(), pool.pendingYield()
        );
        console2.log("MEASURED surplus cold: stream duration (s)           ", pool.yieldStreamEndsAt() - t0);
        console2.log(
            "MEASURED surplus cold, at delivery: door 1 / door 2  ", _serviceable(_holder(1)), _serviceable(_holder(2))
        );
        vm.warp(t0 + D / 2);
        console2.log(
            "MEASURED surplus cold, half: door 1 / door 2         ", _serviceable(_holder(1)), _serviceable(_holder(2))
        );
        vm.warp(t0 + D + 1);
        console2.log(
            "MEASURED surplus cold, end: door 1 / door 2          ", _serviceable(_holder(1)), _serviceable(_holder(2))
        );
        console2.log("MEASURED surplus cold, end: canceller's sync door    ", _syncable(_holder(0)));
        assertEq(pool.yieldStreamEndsAt() - t0, D, "a cold surplus was not rated over D");

        // Warm, rule 1b binding: an epoch of 100 half released, then a surplus of 10.
        vm.revertToState(oneCancel);
        _deliverYield(EACH);
        vm.warp(t0 + D / 2);
        uint256 rateBefore = pool.yieldRate();
        uint256 endBefore = pool.yieldStreamEndsAt();
        _repay(10e6);
        console2.log("MEASURED surplus warm: rate before / after           ", rateBefore, pool.yieldRate());
        console2.log(
            "MEASURED surplus warm: end before / after (s from t0)", endBefore - t0, pool.yieldStreamEndsAt() - t0
        );
        console2.log("MEASURED surplus warm: lastYieldDistributeAt - t0    ", pool.lastYieldDistributeAt() - t0);
        assertGe(pool.yieldRate(), rateBefore, "a non-epoch arrival lowered the release rate");
        vm.warp(t0 + D);
        console2.log("MEASURED surplus warm, at D: E / shortfall           ", _executable(), _shortfall());
        vm.warp(pool.yieldStreamEndsAt() + 1);
        console2.log(
            "MEASURED surplus warm, end: door 1 / door 2          ", _serviceable(_holder(1)), _serviceable(_holder(2))
        );

        // Warm, then a dust EPOCH after the surplus: the epoch leg is the one that can slow it.
        vm.revertToState(oneCancel);
        _repay(EACH);
        vm.warp(t0 + D / 2);
        uint256 surplusRate = pool.yieldRate();
        _deliverYield(DUST_EPOCH);
        console2.log("MEASURED surplus then dust epoch: rate before / after", surplusRate, pool.yieldRate());
        console2.log("MEASURED surplus then dust epoch: ends after t0 (s)  ", pool.yieldStreamEndsAt() - t0);
        assertLt(pool.yieldRate(), surplusRate, "a dust epoch did not slow the surplus stream");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. A frozen pot (`yieldRate == 0` with `pendingYield != 0`)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The pot freezes when real supply falls under `MIN_SUPPLY_FOR_YIELD` (1e7
    ///         share-wei) with a stream running. Built here by one holder exiting all but
    ///         5e6 share-wei in the delivery block; three lenders then enter (paying gross for
    ///         the frozen pot), queue, and a raw loss lands. The frozen pot absorbs the loss
    ///         before E does, and only the next accepted EPOCH thaws what is left.
    function test_R63A3_8_aFrozenPotAbsorbsTheRawLossAndThawsOnTheNextEpoch() public {
        address seed = makeAddr("seed");
        _deposit(seed, 1_000e6);
        _deliverYield(EACH);
        uint256 keep = 5e6;
        uint256 out = pool.balanceOf(seed) - keep;
        vm.prank(seed);
        pool.redeem(out, seed, seed);
        console2.log(
            "MEASURED frozen: supply / pendingYield / yieldRate   ",
            pool.totalSupply(),
            pool.pendingYield(),
            pool.yieldRate()
        );
        console2.log("MEASURED frozen: unreleasedYield                     ", pool.unreleasedYield());
        assertEq(pool.yieldRate(), 0, "fixture: the pot did not freeze");
        assertEq(pool.unreleasedYield(), EACH, "fixture: the frozen pot is not the whole delivery");

        for (uint256 i; i < 3; ++i) {
            _deposit(_holder(i), EACH);
        }
        for (uint256 i; i < 3; ++i) {
            _requestAll(_holder(i));
            console2.log("MEASURED frozen: floor of holder", i, _floorOf(_holder(i)));
        }
        console2.log("MEASURED frozen: E / floors before the loss          ", _executable(), _floorTotal());
        skip(10 days);
        console2.log("MEASURED frozen: unreleased 10 days later            ", pool.unreleasedYield());

        uint256 snap = vm.snapshotState();

        // (a) A loss inside the frozen pot moves E by nothing and leaves the rest frozen.
        _loseCash(40e6);
        console2.log(
            "MEASURED frozen, 40 lost: unreleased / E / shortfall ", pool.unreleasedYield(), _executable(), _shortfall()
        );
        console2.log("MEASURED frozen, 40 lost: yieldRate                  ", pool.yieldRate());
        assertEq(pool.unreleasedYield(), 60e6, "the frozen pot did not absorb the 40");
        uint256 eFrozen = _executable();
        skip(30 days);
        assertEq(_executable(), eFrozen, "a frozen pot released on its own");
        // The thaw: the next accepted EPOCH re-rates the whole pot (rule 3), over its own window.
        uint256 t0 = block.timestamp;
        _deliverYield(DUST_EPOCH);
        console2.log(
            "MEASURED thaw: pot / stream duration (s)             ", pool.pendingYield(), pool.yieldStreamEndsAt() - t0
        );
        vm.warp(pool.yieldStreamEndsAt() + 1);
        console2.log("MEASURED thaw, after the stream: E                   ", _executable());
        assertEq(_executable(), eFrozen + 60e6 + DUST_EPOCH, "the thaw did not release the frozen pot and the dust");

        // (b) A loss over the pot zeroes it, and only the excess reaches E: a frozen pot and
        //     the lock therefore never stand together.
        vm.revertToState(snap);
        _loseCash(260e6);
        console2.log(
            "MEASURED frozen, 260 lost: pending / rate / unreleased",
            pool.pendingYield(),
            pool.yieldRate(),
            pool.unreleasedYield()
        );
        console2.log(
            "MEASURED frozen, 260 lost: E / floors / shortfall    ", _executable(), _floorTotal(), _shortfall()
        );
        _logDoors("MEASURED frozen, 260 lost: door of holder", 3);
        assertEq(pool.pendingYield(), 0, "a frozen pot survived a loss larger than itself");
        assertGt(_shortfall(), 0, "fixture: the larger loss made no shortfall");
    }

    function test_R63A3_8b_theYieldDoorIsRefusedUnderTheSupplyFloor() public {
        address seed = makeAddr("seed");
        _deposit(seed, 1_000e6);
        uint256 out = pool.balanceOf(seed) - 5e6;
        vm.prank(seed);
        pool.redeem(out, seed, seed);
        usdc.mint(harvester, EACH);
        vm.prank(harvester);
        try pool.distributeYield(EACH) {
            console2.log("MEASURED under the supply floor: the epoch was ACCEPTED");
        } catch (bytes memory err) {
            console2.log("MEASURED under the supply floor: the epoch REVERTED, selector");
            console2.logBytes4(bytes4(err));
            assertEq(bytes4(err), bytes4(keccak256("NoSharesOutstanding()")), "refused for another reason");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. The lent shape where the entry-price reserve BINDS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `minimumEntryAssets()` is `ceil((supply + 1000) / 2^128) - 1`, zero for any supply a
    ///         pool reaches in ordinary life. It binds only once supply passes 2^128 share-wei,
    ///         built here the one way a bare pool gets there: three whole-book raw losses, each
    ///         followed by a deposit at the collapsed price. With principal then out, the reserve
    ///         sits senior to E, the unreleased tail's cash counts TOWARDS it, and so an epoch
    ///         lifts E by the reserve AT DELIVERY, before a second has released.
    function test_R63A3_9_whereTheEntryPriceReserveBindsTheYieldDoorOpensAtDelivery() public {
        address whale = makeAddr("whale");
        _deposit(whale, EACH);
        for (uint256 round; round < 3; ++round) {
            _loseCash(usdc.balanceOf(address(pool)) - 1);
            _deposit(whale, 200_000e6);
            console2.log("MEASURED reserve: round / supply                     ", round, pool.totalSupply());
        }
        console2.log("MEASURED reserve: minimumEntryAssets                 ", pool.minimumEntryAssets());
        _deposit(_holder(0), 1_000e6);
        _deposit(_holder(1), 1_000e6);
        _lend(100_000e6);
        console2.log("MEASURED reserve: entryPriceCashReserve with a loan  ", pool.entryPriceCashReserve());
        _requestAll(_holder(0));
        _requestAll(_holder(1));
        uint256 eBefore = _executable();
        uint256 reserve = pool.entryPriceCashReserve();
        uint256 t0 = block.timestamp;
        _deliverYield(EACH);
        console2.log("MEASURED reserve: E before / at delivery             ", eBefore, _executable());
        assertEq(_executable() - eBefore, reserve, "E did not rise by the reserve at delivery");
        assertEq(reserve, 296_812, "the binding reserve is not 0.296812");
        console2.log("MEASURED reserve: reserve before / at delivery       ", reserve, pool.entryPriceCashReserve());
        console2.log("MEASURED reserve: unreleased at delivery             ", pool.unreleasedYield());
        vm.warp(t0 + D + 1);
        console2.log(
            "MEASURED reserve: E / reserve after the stream       ", _executable(), pool.entryPriceCashReserve()
        );
        assertGt(reserve, 0, "fixture: the reserve does not bind");
    }
}
