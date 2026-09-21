// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title Round 63 seat A3, items 3 and 4: row 369's shut-out cash as a distribution with its
///        repayment way out, and row 373's deposit threshold with a stream running or principal
///        out.
/// @dev Bare pool, the manager and harvester as pranked roles. Row 369 was found on the wired
///      graph; its mechanism (a request's draw burns fewer shares than its slice covered while
///      principal is out, and the request-draw memory then holds both controllers under the
///      slice of a base that has moved) lives wholly in `LenderPool`, so the distribution is
///      taken here where 81 points cost milliseconds. Every `MEASURED` line was read from a run
///      before the figure beside it was asserted.
contract R63A3_ShutOutAndDepositDoor is R63A3_Fixture {
    address internal a = makeAddr("lender-a");
    address internal b = makeAddr("lender-b");

    struct Point {
        uint256 depositA;
        uint256 depositB;
        uint256 lentBps;
        uint256 yieldBps;
        uint256 elapsedBps;
        bool bDrawsFirst;
    }

    /// @dev Two lenders, a loan of `lentBps` of the book, both queue everything, an epoch of
    ///      `yieldBps` of the book, `elapsedBps` of the stream elapses, both service to zero
    ///      cash (a first). Returns the released yield and the cash no door then reaches.
    function _shutOut(Point memory p) internal returns (uint256 released, uint256 shut, uint256 eBeforeDraws) {
        _deposit(a, p.depositA);
        _deposit(b, p.depositB);
        uint256 book = p.depositA + p.depositB;
        _lend((book * p.lentBps) / 10_000);
        _requestAll(a);
        _requestAll(b);
        uint256 eAtRequest = _executable();
        _deliverYield((book * p.yieldBps) / 10_000);
        skip((D * p.elapsedBps) / 10_000 + (p.elapsedBps == 10_000 ? 1 : 0));
        eBeforeDraws = _executable();
        released = eBeforeDraws - eAtRequest;
        // Two statements, never one sum: Solidity does not fix the evaluation order of `+`, and
        // WHO DRAWS FIRST is the variable this measures (the first run of this file summed the
        // two calls, the compiler evaluated the right one first, and the figures were b-first).
        for (uint256 pass; pass < 6; ++pass) {
            uint256 first = _drainToZeroCash(p.bDrawsFirst ? b : a);
            uint256 second = _drainToZeroCash(p.bDrawsFirst ? a : b);
            if (first + second == 0) break;
        }
        shut = _executable();
        assertEq(pool.unreservedIdle(), 0, "the sync door reaches the shut-out cash");
        assertEq(_serviceable(a) + _serviceable(b), 0, "a request door still reaches cash");
    }

    /// @dev The smallest repayment, to 0.01 USDC, after which either request door reads
    ///      non-zero cash. Bisected on a snapshot.
    function _repaymentThatReopens(uint256 ceiling) internal returns (uint256 threshold) {
        uint256 snap = vm.snapshotState();
        uint256 lo = 0;
        uint256 hi = ceiling;
        _repay(hi);
        if (_serviceable(a) + _serviceable(b) == 0) {
            vm.revertToState(snap);
            return type(uint256).max;
        }
        while (hi - lo > 1e4) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(snap);
            _repay(mid);
            if (_serviceable(a) + _serviceable(b) == 0) lo = mid;
            else hi = mid;
        }
        vm.revertToState(snap);
        threshold = hi;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Row 369: the shut-out cash, measured as a distribution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice One point read closely: 10,000 and 10,000, half the book lent, a 1% epoch fully
    ///         released. Then the two ways out: a cancel, and a repayment, which has a size
    ///         threshold of its own.
    function test_R63A3_S1_onePointReadClosely() public {
        Point memory p = Point(10_000e6, 10_000e6, 5_000, 100, 10_000, false);
        (uint256 released, uint256 shut, uint256 eBefore) = _shutOut(p);
        console2.log("MEASURED S1: E before the draws / released since filing", eBefore, released);
        console2.log("MEASURED S1: cash no door reaches                      ", shut);
        console2.log(
            "MEASURED S1: floors left / queued over supply (1e6)    ",
            _floorTotal(),
            (pool.queuedShares() * 1e6) / pool.totalSupply()
        );
        console2.log("MEASURED S1: outstanding principal                     ", pool.outstandingPrincipal());
        uint256 snap = vm.snapshotState();

        uint256 threshold = _repaymentThatReopens(pool.outstandingPrincipal());
        console2.log("MEASURED S1: smallest repayment that reopens a door    ", threshold);
        _repay(threshold / 2);
        console2.log("MEASURED S1: doors after HALF that repayment (a / b)   ", _serviceable(a), _serviceable(b));
        console2.log("MEASURED S1: cash no door reaches after half of it     ", _executable());
        vm.revertToState(snap);
        _repay(pool.outstandingPrincipal());
        uint256 out = _drainToZeroCash(a);
        out += _drainToZeroCash(b);
        console2.log("MEASURED S1: the whole loan repaid: drawn / E left     ", out, _executable());

        vm.revertToState(snap);
        _cancel(a);
        console2.log("MEASURED S1: a cancels: her sync door / b's door       ", _syncable(a), _serviceable(b));
        assertGt(shut, 0, "the point shut nothing out");
        assertGt(threshold, 0, "any repayment reopens a door");
    }

    struct Tally {
        uint256 points;
        uint256 withShutOut;
        uint256 overOneUsdc;
        uint256 maxShut;
        uint256 maxOfReleasedBps;
        uint256 minOfReleasedBps;
        uint256 sumOfReleasedBps;
        uint256 maxOfEBps;
    }

    /// @notice The grid: splits 1:1, 9:1 and 1:9, 25% / 50% / 85% lent, an epoch of 0.1% / 1% /
    ///         5% of the book, a quarter, half and all of it released: 81 points, each in both
    ///         draw orders (A first, then B first), 162 in all.
    function test_R63A3_S2_theGrid() public {
        Tally memory t;
        t.minOfReleasedBps = type(uint256).max;
        for (uint256 n; n < 162; ++n) {
            uint256 snap = vm.snapshotState();
            _gridPoint(t, n);
            vm.revertToState(snap);
        }
        console2.log(
            "MEASURED grid: points / with cash shut out / with >= 1 USDC", t.points, t.withShutOut, t.overOneUsdc
        );
        console2.log("MEASURED grid: largest shut-out (USDC wei)             ", t.maxShut);
        console2.log(
            "MEASURED grid: shut-out over released, bps min/mean/max",
            t.minOfReleasedBps,
            t.sumOfReleasedBps / t.points,
            t.maxOfReleasedBps
        );
        console2.log("MEASURED grid: shut-out over E before the draws, max bps", t.maxOfEBps);
        assertEq(t.points, 162, "the grid is not 81 points in both draw orders");
    }

    /// @dev One grid point. The tally lives in MEMORY, which a state revert does not touch.
    function _gridPoint(Tally memory t, uint256 n) internal {
        uint256[3] memory splitA = [uint256(10_000e6), 18_000e6, 2_000e6];
        uint256[3] memory lent = [uint256(2_500), 5_000, 8_500];
        uint256[3] memory yields = [uint256(10), 100, 500];
        uint256[3] memory elapsed = [uint256(2_500), 5_000, 10_000];
        Point memory p = Point(
            splitA[n % 3],
            20_000e6 - splitA[n % 3],
            lent[(n / 3) % 3],
            yields[(n / 9) % 3],
            elapsed[(n / 27) % 3],
            n >= 81
        );
        (uint256 released, uint256 shut, uint256 eBefore) = _shutOut(p);
        uint256 ofReleased = (shut * 10_000) / released;
        if ((n / 27) % 3 == 2) {
            console2.log(
                p.bDrawsFirst
                    ? "MEASURED grid row, B FIRST: deposit of A / lent bps / yield bps"
                    : "MEASURED grid row, A FIRST: deposit of A / lent bps / yield bps",
                p.depositA / 1e6,
                p.lentBps,
                p.yieldBps
            );
            console2.log("MEASURED grid row:   released / shut out / bps of released   ", released, shut, ofReleased);
        }
        ++t.points;
        if (shut != 0) ++t.withShutOut;
        if (shut >= 1e6) ++t.overOneUsdc;
        if (shut > t.maxShut) t.maxShut = shut;
        t.sumOfReleasedBps += ofReleased;
        if (ofReleased > t.maxOfReleasedBps) t.maxOfReleasedBps = ofReleased;
        if (ofReleased < t.minOfReleasedBps) t.minOfReleasedBps = ofReleased;
        if ((shut * 10_000) / eBefore > t.maxOfEBps) t.maxOfEBps = (shut * 10_000) / eBefore;
    }

    /// @notice The repayment way out across the fully released third of the grid: the smallest
    ///         repayment that reopens either door, as basis points of the loan.
    function test_R63A3_S3_theRepaymentWayOutHasAThreshold() public {
        uint256[3] memory splitA = [uint256(10_000e6), 18_000e6, 2_000e6];
        uint256[3] memory lent = [uint256(2_500), 5_000, 8_500];
        uint256 clean = vm.snapshotState();
        uint256 maxBps;
        uint256 minBps = type(uint256).max;
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                vm.revertToState(clean);
                Point memory p = Point(splitA[i], 20_000e6 - splitA[i], lent[j], 100, 10_000, false);
                (, uint256 shut,) = _shutOut(p);
                uint256 loan = pool.outstandingPrincipal();
                uint256 threshold = _repaymentThatReopens(loan);
                uint256 bps = threshold == type(uint256).max ? type(uint256).max : (threshold * 10_000) / loan;
                console2.log("MEASURED way out: splitA / lent bps / shut out          ", splitA[i] / 1e6, lent[j], shut);
                console2.log("MEASURED way out:   smallest reopening repayment / bps  ", threshold, bps);
                if (bps > maxBps) maxBps = bps;
                if (bps < minBps) minBps = bps;
            }
        }
        console2.log("MEASURED way out: threshold as bps of the loan, min / max", minBps, maxBps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Row 373: the deposit door's threshold with a stream running or principal out
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Every old door opens exactly where E exceeds the floors the OTHERS are owed.
    function _assertThresholdIdentity(uint256 count) internal view returns (uint256 open) {
        uint256 e = _executable();
        for (uint256 i; i < count; ++i) {
            uint256 owedToOthers = _floorTotal() - _floorOf(_holder(i));
            bool shouldOpen = e > owedToOthers;
            bool isOpen = pool.maxRequestRedeem(_holder(i)) != 0;
            // A cap of a wei or two converts to zero shares; nothing else may disagree.
            if (shouldOpen && !isOpen) assertLe(e - owedToOthers, 2, "a door with a cap over 2 wei reads 0");
            if (!shouldOpen) assertFalse(isOpen, "a door is open where E does not clear the other floors");
            if (isOpen) ++open;
        }
    }

    /// @notice A stream RUNNING when the loss lands: five floors of 100.000000, 100.000000
    ///         delivered and half released, then A4's 201.940593 lost. The released half had
    ///         already lifted E 49.999999 over the floors and the unreleased half absorbs
    ///         50.000001 of the loss before E does, so the shortfall is 101.940593, not the loss,
    ///         and the deposit threshold is 1.940593, not "the loss less one floor" (101.940593).
    ///         The inequality itself (E + R over the floors the others are owed) is exact.
    function test_R63A3_T1_aStreamRunningAtTheLossLowersTheThreshold() public {
        _queueEqualFloors(5, EACH);
        uint256 t0 = block.timestamp;
        _deliverYield(EACH);
        vm.warp(t0 + D / 2);
        uint256 tail = pool.unreleasedYield();
        uint256 loss = 201_940_593;
        _loseCash(loss);
        uint256 shortfall = _shortfall();
        console2.log("MEASURED T1: tail at the loss / tail after it          ", tail, pool.unreleasedYield());
        console2.log("MEASURED T1: loss / shortfall                          ", loss, shortfall);
        console2.log("MEASURED T1: threshold by the rule / 'loss less a floor'", shortfall - EACH, loss - EACH);
        console2.log("MEASURED T1: maxDeposit(fresh)                         ", pool.maxDeposit(fresh));
        assertEq(shortfall, 101_940_593, "the shortfall is not the loss less the 100 the stream had brought");
        uint256 locked = vm.snapshotState();

        _deposit(fresh, 3e6);
        uint256 open = _assertThresholdIdentity(5);
        console2.log("MEASURED T1: a 3.000000 deposit (far under 101.94): doors open", open);
        _logDoors("MEASURED T1: after the 3.000000 deposit: door of holder", 5);
        assertEq(open, 5, "a deposit over the true threshold did not open every door");

        vm.revertToState(locked);
        _deposit(fresh, 1_500_000);
        open = _assertThresholdIdentity(5);
        console2.log("MEASURED T1: a 1.500000 deposit (under 1.94): doors open ", open);
        assertEq(open, 0, "a deposit under the true threshold opened a door");
    }

    /// @notice A stream delivered INTO the lock: the threshold falls as it releases, so a deposit
    ///         that joins the lock at delivery is released by the clock; and with a tail
    ///         outstanding the depositor pays the GROSS entry price, so her shares are worth less
    ///         than she paid the block she buys them.
    function test_R63A3_T2_aStreamIntoTheLockMovesTheThresholdAndTheEntryPrice() public {
        _queueEqualFloors(5, EACH);
        _loseCash(201_940_593);
        uint256 t0 = block.timestamp;
        _deliverYield(EACH);
        console2.log("MEASURED T2 at delivery: shortfall / threshold         ", _shortfall(), _shortfall() - EACH);
        uint256 shares = _deposit(fresh, 60e6);
        uint256 worth = pool.previewRedeem(shares);
        console2.log("MEASURED T2: she pays 60.000000, her shares are worth  ", worth);
        console2.log("MEASURED T2: doors open at delivery after her deposit  ", _assertThresholdIdentity(5));
        _requestAll(fresh);
        console2.log(
            "MEASURED T2: her floor / request door / sync door      ",
            _floorOf(fresh),
            _serviceable(fresh),
            _syncable(fresh)
        );
        uint256 openedAfter;
        for (uint256 t = t0; t <= t0 + D; t += 3600) {
            vm.warp(t);
            if (_serviceable(_holder(0)) != 0) {
                openedAfter = t - t0;
                break;
            }
        }
        console2.log("MEASURED T2: the old doors first open after (s)        ", openedAfter);
        vm.warp(t0 + D + 1);
        console2.log(
            "MEASURED T2 after the stream: her shares are worth     ", pool.previewRedeem(_requestShares(fresh))
        );
        _logDoors("MEASURED T2 after the stream: door of holder", 5);
        console2.log("MEASURED T2 after the stream: her request door         ", _serviceable(fresh));
        assertLt(worth, 60e6 - 1e6, "with a tail outstanding she did not pay over the exit price");
        assertGt(openedAfter, 0, "the doors were open at delivery");
    }

    /// @notice Principal out: three holders of 100.000000, 150.000000 lent, floors of 50.000000,
    ///         120.000000 of the 150.000000 of cash lost. The threshold is the shortfall less a
    ///         floor (70.000000) and the deposit's cash is not lendable while the floors hold it.
    function test_R63A3_T3_theThresholdWithPrincipalOut() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(_holder(i), EACH);
        }
        _lend(150e6);
        for (uint256 i; i < 3; ++i) {
            _requestAll(_holder(i));
        }
        _loseCash(120e6);
        console2.log(
            "MEASURED T3: E / floors / shortfall / threshold         ", _executable(), _floorTotal(), _shortfall()
        );
        console2.log(
            "MEASURED T3: maxDeposit(fresh) / available()            ", pool.maxDeposit(fresh), pool.available()
        );
        uint256 locked = vm.snapshotState();

        uint256 shares = _deposit(fresh, 60e6);
        console2.log(
            "MEASURED T3: 60 deposited, worth / doors open           ",
            pool.previewRedeem(shares),
            _assertThresholdIdentity(3)
        );
        console2.log("MEASURED T3: 60 deposited: her sync door / available()  ", _syncable(fresh), pool.available());
        assertEq(_assertThresholdIdentity(3), 0, "a deposit under the threshold opened a door with principal out");

        vm.revertToState(locked);
        _deposit(fresh, 80e6);
        console2.log("MEASURED T3: 80 deposited: doors open                   ", _assertThresholdIdentity(3));
        _logDoors("MEASURED T3: 80 deposited: door of holder", 3);
        console2.log("MEASURED T3: 80 deposited: her sync door / available()  ", _syncable(fresh), pool.available());
        assertEq(_assertThresholdIdentity(3), 3, "a deposit over the threshold did not open every door");
    }

    /// @notice The identity under fuzz with both a stream and principal in play: N floors, a loan,
    ///         an epoch part released, a raw loss, then a deposit of any size up to `maxDeposit`.
    ///         Unseeded; the census below reaches both regimes in both shapes.
    function testFuzz_R63A3_T4_theThresholdIdentityWithAStreamAndPrincipalOut(
        uint8 rawCount,
        uint16 rawLent,
        uint32 rawYield,
        uint32 rawElapsed,
        uint256 rawLoss,
        uint256 rawDeposit
    ) public {
        _thresholdCase(rawCount, rawLent, rawYield, rawElapsed, rawLoss, rawDeposit);
    }

    function _thresholdCase(
        uint256 rawCount,
        uint256 rawLent,
        uint256 rawYield,
        uint256 rawElapsed,
        uint256 rawLoss,
        uint256 rawDeposit
    ) internal returns (uint256 openBefore, uint256 openAfter, bool streamLive, bool lentOut) {
        uint256 count = 2 + (rawCount % 6);
        for (uint256 i; i < count; ++i) {
            _deposit(_holder(i), EACH);
        }
        uint256 lentAmount = ((count * EACH) * (rawLent % 8_501)) / 10_000;
        if (lentAmount != 0) _lend(lentAmount);
        for (uint256 i; i < count; ++i) {
            _requestAll(_holder(i));
        }
        uint256 cash = usdc.balanceOf(address(pool));
        _loseCash(1 + (rawLoss % cash));
        uint256 yieldAmount = rawYield % (50e6 + 1);
        // An epoch INTO the locked state, part released. `distributeYield` refuses an epoch
        // larger than the capital left, so the draw is held under it.
        if (yieldAmount != 0 && yieldAmount <= pool.totalAssets()) {
            _deliverYield(yieldAmount);
            skip(rawElapsed % D);
        }
        streamLive = pool.unreleasedYield() != 0;
        lentOut = pool.outstandingPrincipal() != 0;
        openBefore = _assertThresholdIdentity(count);
        uint256 room = pool.maxDeposit(fresh);
        if (room == 0) return (openBefore, openBefore, streamLive, lentOut);
        uint256 amount = 1 + (rawDeposit % (room > 1_000e6 ? 1_000e6 : room));
        if (pool.previewDeposit(amount) == 0) return (openBefore, openBefore, streamLive, lentOut);
        uint256 eBefore = _executable();
        _deposit(fresh, amount);
        assertEq(_executable(), eBefore + amount, "a deposit did not raise E by exactly itself");
        openAfter = _assertThresholdIdentity(count);
    }

    function test_R63A3_T4_census() public {
        uint256 clean = vm.snapshotState();
        // (count-2, lent bps, yield, elapsed, loss, deposit): joined and opened, with a live
        // stream and with principal out.
        uint256[6][6] memory rows = [
            [uint256(3), 0, 50e6, D / 4, 300e6 - 1, 10e6 - 1],
            [uint256(3), 0, 50e6, D / 4, 300e6 - 1, 400e6 - 1],
            [uint256(1), 5_000, 20e6, D / 2, 120e6 - 1, 40e6 - 1],
            [uint256(1), 5_000, 20e6, D / 2, 120e6 - 1, 80e6 - 1],
            [uint256(1), 5_000, 0, 0, 120e6 - 1, 60e6 - 1],
            [uint256(1), 5_000, 0, 0, 120e6 - 1, 80e6 - 1]
        ];
        for (uint256 k; k < rows.length; ++k) {
            vm.revertToState(clean);
            (uint256 before, uint256 afterDeposit, bool streamLive, bool lentOut) =
                _thresholdCase(rows[k][0], rows[k][1], rows[k][2], rows[k][3], rows[k][4], rows[k][5]);
            console2.log("MEASURED T4 census row / doors open before / after      ", k, before, afterDeposit);
            console2.log("MEASURED T4 census row: stream live / principal out     ", streamLive, lentOut);
        }
    }
}
