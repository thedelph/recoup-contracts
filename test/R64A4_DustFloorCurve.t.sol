// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {R63A3_Fixture} from "./R63A3_Fixture.sol";

/// @title Round 64 seat A4, item 1: the THRESHOLD CURVE of the dust-held floor (round-64 row 392).
/// @notice Round 63 measured three points (75% of the debt in a symmetric book, 14.5% in one
///         lopsided book, 100% at a forced close). This suite maps the curve on the bare pool:
///         a book of `T` with requesters owning `r` of it who FILED when `u0` of the book was
///         lent, after which `dLent` more was lent and the dormant lenders took `X` out through
///         the sync door, and then a price fall `L` (a socialised loss, an impairment MARK that is
///         later released in full, or a raw loss). Every requester then services her door down to
///         one share-wei.
/// @dev The closed form every row is held to, derived on paper and then executed:
///        a floor is kept  <=>  L / (T - X) > u0          (the fall per remaining book dollar
///                                                          exceeds the utilisation AT FILING)
///        floor kept       =   r * T * (L / (T - X) - u0)
///      so lending AFTER filing lowers the threshold as a share of the debt to `u0 * (T - X) /
///      (u0 * T + dLent)`, and a request filed in an idle book (u0 = 0) keeps a floor at ANY
///      fall, a mark included. Six-decimal USDC base units; every `MEASURED` line was read from a
///      run before the figure beside it was asserted.
///      #64: this suite mapped the curve as the tree stood. Its dust-held-floor assertions are
///      FLIPPED to the #64 fix, which writes the floor left on dust down to what the dust is worth
///      while the floors sit inside the executable cash: every socialised-loss and mark row now
///      keeps nothing at any fall (the threshold is NONE), and C7, the #61 lock under a raw loss,
///      is unchanged.
contract R64A4_DustFloorCurve is R63A3_Fixture {
    uint256 internal constant T = 100_000e6;
    uint256 internal constant BPS = 10_000;

    uint256 internal constant SOCIALISED = 0;
    uint256 internal constant MARK_THEN_RELEASED = 1;
    uint256 internal constant RAW = 2;

    address internal borrower = makeAddr("marked-borrower");

    struct Shape {
        uint256 requesterBps; // r: what the requesters own of the book, together
        uint256 requesters; // how many split r equally
        uint256 dormants; // how many split the rest equally
        uint256 lentAtFilingBps; // u0
        uint256 lentAfterBps; // dLent / T
        uint256 exitBps; // how much of its sync door each dormant lender takes after the filing
    }

    struct Result {
        uint256 principal; // outstanding when the fall lands
        uint256 book; // T - X when the fall lands
        uint256 floorsFiled;
        uint256 drawn; // what the requesters took, together
        uint256 kept; // floors left on share dust
        uint256 dustShares;
        uint256 dormantWorth;
        uint256 syncCash; // `unreservedIdle()`: the cash every sync door shares
        uint256 lendable;
    }

    function _requester(uint256 i) internal pure returns (address) {
        return address(uint160(0x200000 + i));
    }

    function _dormant(uint256 i) internal pure returns (address) {
        return address(uint160(0x300000 + i));
    }

    function _build(Shape memory s) internal {
        uint256 requesterEach = T * s.requesterBps / BPS / s.requesters;
        uint256 dormantEach = (T - requesterEach * s.requesters) / s.dormants;
        for (uint256 i; i < s.requesters; ++i) {
            _deposit(_requester(i), requesterEach);
        }
        for (uint256 i; i < s.dormants; ++i) {
            _deposit(_dormant(i), dormantEach);
        }
        if (s.lentAtFilingBps != 0) _lend(T * s.lentAtFilingBps / BPS);
        for (uint256 i; i < s.requesters; ++i) {
            _requestAll(_requester(i));
        }
        if (s.lentAfterBps != 0) _lend(T * s.lentAfterBps / BPS);
        if (s.exitBps != 0) {
            for (uint256 i; i < s.dormants; ++i) {
                address who = _dormant(i);
                uint256 shares = pool.maxRedeem(who) * s.exitBps / BPS;
                if (shares == 0) continue;
                vm.prank(who);
                pool.redeem(shares, who, who);
            }
        }
    }

    function _fall(uint256 kind, uint256 amount) internal {
        if (amount == 0) return;
        if (kind == SOCIALISED) {
            vm.prank(manager);
            pool.socialiseLoss(amount);
        } else if (kind == MARK_THEN_RELEASED) {
            vm.prank(manager);
            pool.impair(borrower, amount);
        } else {
            _loseCash(amount);
        }
    }

    /// @dev Everything her door offers, call after call, stopping `leave` share-wei short of the
    ///      end. `leave == 0` is her honest twin.
    function _drain(address who, uint256 leave) internal returns (uint256 paid) {
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

    function _run(Shape memory s, uint256 kind, uint256 fall, uint256 leave) internal returns (Result memory r) {
        _build(s);
        r.principal = pool.outstandingPrincipal();
        r.book = pool.totalAssets();
        r.floorsFiled = _floorTotal();
        _fall(kind, fall);
        for (uint256 i; i < s.requesters; ++i) {
            r.drawn += _drain(_requester(i), leave);
        }
        if (kind == MARK_THEN_RELEASED && fall != 0) {
            vm.prank(manager);
            pool.releaseImpairment(borrower);
        }
        for (uint256 i; i < s.requesters; ++i) {
            r.dustShares += _requestShares(_requester(i));
        }
        r.kept = _floorTotal();
        for (uint256 i; i < s.dormants; ++i) {
            r.dormantWorth += pool.previewRedeem(pool.balanceOf(_dormant(i)));
        }
        r.lendable = pool.available();
        r.syncCash = pool.unreservedIdle();
    }

    function _keptAt(Shape memory s, uint256 kind, uint256 fall) internal returns (uint256 kept) {
        uint256 snap = vm.snapshotState();
        kept = _run(s, kind, fall, 1).kept;
        vm.revertToState(snap);
    }

    function _principalOf(Shape memory s) internal returns (uint256 principal) {
        uint256 snap = vm.snapshotState();
        _build(s);
        principal = pool.outstandingPrincipal();
        vm.revertToState(snap);
    }

    /// @dev The smallest fall at which the floors kept on dust reach `atLeast`, by bisection over
    ///      [0, principal]. Returns `type(uint256).max` when even the whole debt keeps less.
    function _threshold(Shape memory s, uint256 kind, uint256 atLeast) internal returns (uint256 lo) {
        uint256 hi = _principalOf(s);
        if (_keptAt(s, kind, hi) < atLeast) return type(uint256).max;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_keptAt(s, kind, mid) >= atLeast) hi = mid;
            else lo = mid + 1;
        }
    }

    /// @dev The paper figure: `u0 * (T - X)`, read from the built book rather than typed.
    function _paperThreshold(Shape memory s) internal returns (uint256 paper) {
        uint256 snap = vm.snapshotState();
        _build(s);
        paper = pool.totalAssets() * s.lentAtFilingBps / BPS;
        vm.revertToState(snap);
    }

    function _row(string memory label, Shape memory s, uint256 kind) internal returns (uint256 measured) {
        measured = _threshold(s, kind, 1e6);
        uint256 paper = _paperThreshold(s);
        uint256 principal = _principalOf(s);
        console2.log(label);
        console2.log(
            "MEASURED   r / u0 / lent after (bps of the book)         ",
            s.requesterBps,
            s.lentAtFilingBps,
            s.lentAfterBps
        );
        console2.log("MEASURED   sync door taken (bps) / requesters / dormants ", s.exitBps, s.requesters, s.dormants);
        console2.log("MEASURED   principal out / paper threshold u0*(T-X)      ", principal, paper);
        if (measured == type(uint256).max) {
            console2.log("MEASURED   smallest fall keeping 1.000000: NONE at the whole debt");
        } else {
            console2.log(
                "MEASURED   smallest fall keeping 1.000000 / bps of debt  ", measured, measured * BPS / principal
            );
        }
    }

    // ───────────────────────────────────────────────────
    // 1. A book that does not move after the filing never keeps a floor
    // ───────────────────────────────────────────────────

    function test_R64A4_C1_aStationaryBookNeverKeepsAFloor_evenAtTheWholeDebt() public {
        uint16[4] memory u0 = [uint16(1_000), 2_500, 5_000, 8_000];
        for (uint256 k; k < u0.length; ++k) {
            Shape memory s = Shape(2_500, 1, 3, u0[k], 0, 0);
            uint256 snap = vm.snapshotState();
            Result memory r = _run(s, SOCIALISED, T * u0[k] / BPS, 1);
            vm.revertToState(snap);
            console2.log("MEASURED C1 u0 bps / whole debt lost / kept on dust      ", u0[k], r.principal, r.kept);
            assertLe(r.kept, 1, "a stationary book kept a floor: the paper rule (fall per book dollar > u0) is wrong");
        }
    }

    // ───────────────────────────────────────────────────
    // 2. Lending AFTER the filing: the threshold is u0 / u1 of the debt, and ZERO for u0 = 0
    // ───────────────────────────────────────────────────

    function test_R64A4_C2_lendingAfterTheFilingLowersTheThreshold_toAnyLossAtAllFromAnIdleBook() public {
        uint16[4] memory u0 = [uint16(0), 1_000, 2_500, 5_000];
        uint256[4] memory measured;
        for (uint256 k; k < u0.length; ++k) {
            // r = 10%, lent up to 70% of the book in all, nobody exits.
            Shape memory s = Shape(1_000, 1, 3, u0[k], 7_000 - u0[k], 0);
            measured[k] = _row("C2 lent up to 70% after the filing", s, SOCIALISED);
            // #64 fix: no fall up to the whole debt keeps 1.000000 on dust (was paper + 10.000000).
            assertEq(measured[k], type(uint256).max, "#64: some fall still keeps a floor on dust");
        }
        Shape memory idle = Shape(1_000, 1, 3, 0, 7_000, 0);
        uint256 snap = vm.snapshotState();
        Result memory r = _run(idle, SOCIALISED, 3_500e6, 1);
        vm.revertToState(snap);
        console2.log("MEASURED C2 idle filing, 5% of the debt lost: drew / kept ", r.drawn, r.kept);
        console2.log(
            "MEASURED C2   dormant worth / sync cash / lendable        ", r.dormantWorth, r.syncCash, r.lendable
        );
        // #64 fix: the idle-book filing keeps nothing (was r * L = 350.000000).
        assertLe(r.kept, 1, "#64: an idle-book filing kept a floor on dust");
    }

    // ───────────────────────────────────────────────────
    // 3. Sync exits AFTER the filing: threshold 1 - x(1-r)(1-u0) of the debt
    // ───────────────────────────────────────────────────

    function test_R64A4_C3_syncExitsAfterTheFiling_theGridRound63TookThreePointsOf() public {
        uint16[3] memory u0 = [uint16(1_000), 2_500, 5_000];
        uint16[3] memory rr = [uint16(100), 500, 5_000];
        for (uint256 a; a < u0.length; ++a) {
            for (uint256 b; b < rr.length; ++b) {
                Shape memory s = Shape(rr[b], 1, 2, u0[a], 0, BPS);
                uint256 measured = _row("C3 every dormant lender takes her whole sync door", s, SOCIALISED);
                // #64 fix: no fall keeps a floor on dust (was the paper threshold u0 * (T - X)).
                assertEq(measured, type(uint256).max, "#64: some fall still keeps a floor on dust");
            }
        }
        // Round 63's two executed points, recovered from the rule: 75% and 14.5% of the debt.
        Shape memory d4 = Shape(5_000, 1, 1, 5_000, 0, BPS);
        assertApproxEqAbs(_paperThreshold(d4) * BPS / (T / 2), 7_500, 1, "C3: round 63's D4 point is not 75%");
        Shape memory s61 = Shape(500, 1, 1, 1_000, 0, BPS);
        assertApproxEqAbs(_paperThreshold(s61) * BPS / (T / 10), 1_450, 1, "C3: S-61's lopsided point is not 14.5%");
    }

    function test_R64A4_C3b_partialExits() public {
        uint16[3] memory x = [uint16(2_500), 5_000, 7_500];
        for (uint256 k; k < x.length; ++k) {
            Shape memory s = Shape(500, 1, 2, 2_500, 0, x[k]);
            uint256 measured = _row("C3b the dormant lenders take part of their sync door", s, SOCIALISED);
            // #64 fix: no fall keeps a floor on dust (was the paper threshold u0 * (T - X)).
            assertEq(measured, type(uint256).max, "#64: some fall still keeps a floor on dust");
        }
    }

    // ───────────────────────────────────────────────────
    // 4. The NO-LOSS route: an impairment mark, released in full afterwards
    // ───────────────────────────────────────────────────

    function test_R64A4_C4_aMarkThatIsLaterReleasedInFullKeepsAFloor_noLossOfAnyKind() public {
        // r = 10% filed in an idle book; 60,000 lent after; ONE 5,000 loan goes to auction and the
        // manager marks its whole debt (`_impairmentFor` returns `currentDebtOf`). She exits during
        // the auction; the auction clears the debt in full and the mark is released.
        Shape memory s = Shape(1_000, 1, 3, 0, 6_000, 0);
        uint256 snap = vm.snapshotState();
        Result memory honest = _run(s, MARK_THEN_RELEASED, 5_000e6, 0);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        Result memory grief = _run(s, MARK_THEN_RELEASED, 5_000e6, 1);
        console2.log(
            "MEASURED C4 lifetime socialised loss / raw deficit        ",
            pool.lifetimeSocialisedLoss(),
            pool.cashDeficit()
        );
        console2.log("MEASURED C4 honest: drew / floors left                    ", honest.drawn, honest.kept);
        console2.log("MEASURED C4 careless: drew / dust shares                  ", grief.drawn, grief.dustShares);
        console2.log("MEASURED C4 careless: floor kept after the mark is gone   ", grief.kept);
        console2.log(
            "MEASURED C4 careless: dormant worth / sync cash / lendable",
            grief.dormantWorth,
            grief.syncCash,
            grief.lendable
        );
        console2.log(
            "MEASURED C4 honest:   dormant worth / sync cash / lendable",
            honest.dormantWorth,
            honest.syncCash,
            honest.lendable
        );
        assertEq(pool.lifetimeSocialisedLoss(), 0, "C4: a loss was socialised; this is not the no-loss route");
        assertEq(pool.exitReserve(), 0, "C4: the mark is still standing");
        assertEq(honest.kept, 0, "C4: the honest twin kept a floor");
        assertEq(grief.dustShares, 1, "C4: she did not end on one share-wei");
        // #64 fix: the no-loss mark keeps nothing on dust (was r * M = 500.000000), at any mark.
        assertLe(grief.kept, 1, "#64: a released mark kept a floor on dust");
        vm.revertToState(snap);
        uint256 threshold = _row("C4 the same shape, the mark swept", s, MARK_THEN_RELEASED);
        assertEq(threshold, type(uint256).max, "#64: some mark still keeps a floor on dust");
    }

    // ───────────────────────────────────────────────────
    // 5. Several requesters: the kept floors ADD, and they need not collude
    // ───────────────────────────────────────────────────

    function test_R64A4_C5_severalRequesters_theKeptFloorsAdd() public {
        uint8[4] memory n = [1, 3, 10, 30];
        uint256 first;
        for (uint256 k; k < n.length; ++k) {
            // 30% of the book, split n ways, filed idle; lent to 50%; 12% of the debt lost.
            Shape memory s = Shape(3_000, n[k], 4, 0, 5_000, 0);
            uint256 snap = vm.snapshotState();
            Result memory r = _run(s, SOCIALISED, 6_000e6, 1);
            vm.revertToState(snap);
            console2.log("MEASURED C5 requesters / drew together / kept together ", n[k], r.drawn, r.kept);
            console2.log(
                "MEASURED C5   dormant worth / sync cash / lendable     ", r.dormantWorth, r.syncCash, r.lendable
            );
            if (k == 0) first = r.kept;
            // #64 fix: nothing is kept however the requesters are split (was R * L = 1,800.000000).
            assertLe(r.kept, n[k], "#64: a requester kept a floor on dust");
            assertEq(r.dustShares, n[k], "C5: a requester did not end on one share-wei");
        }
        assertLe(first, 1, "#64: one requester kept a floor on dust");
    }

    /// @dev What a growing share of careless idle filers costs the dormant lenders. They are shut out
    ///      WHOLE once R * L >= (1 - R) * (T - L), which the 15% float keeps out of reach at this loss.
    function test_R64A4_C5b_theDormantLendersAreShortByExactlyTheKeptFloors() public {
        uint16[3] memory rBps = [uint16(3_000), 6_000, 8_000];
        for (uint256 k; k < rBps.length; ++k) {
            Shape memory s = Shape(rBps[k], 5, 4, 0, 1_500, 0);
            uint256 snap = vm.snapshotState();
            // The whole 15,000 debt is lost, so no repayment is pending and the cash is final.
            Result memory r = _run(s, SOCIALISED, 15_000e6, 1);
            console2.log("MEASURED C5b R bps / kept / dormant worth              ", rBps[k], r.kept, r.dormantWorth);
            console2.log("MEASURED C5b   dormant sync door, no debt left         ", r.syncCash);
            assertApproxEqAbs(
                r.syncCash + r.kept,
                r.dormantWorth,
                100,
                "C5b: the dormant lenders are not short by exactly the kept floors"
            );
            // #64 fix: nothing is kept, so the dormant lenders are short by nothing (was R * L).
            assertLe(r.kept, 5, "#64: the requesters kept a floor on dust");
            vm.revertToState(snap);
        }
    }

    /// @dev Requests filed at DIFFERENT utilisations: each keeps by its own `u0`, in either order of
    ///      service. One filed idle, one filed with 40% lent, then lent to 60% and 30,000 lost.
    function test_R64A4_C5c_filingTimeDecidesPerRequest_orderOfServiceDoesNot() public {
        address early = _requester(0);
        address late = _requester(1);
        _deposit(early, 10_000e6);
        _deposit(late, 10_000e6);
        _deposit(_dormant(0), 80_000e6);
        _requestAll(early);
        _lend(40_000e6);
        _requestAll(late);
        _lend(20_000e6);
        console2.log("MEASURED C5c floors filed: idle / at 40% lent               ", _floorOf(early), _floorOf(late));
        vm.prank(manager);
        pool.socialiseLoss(30_000e6);
        uint256 snap = vm.snapshotState();
        uint256[2] memory keptEarly;
        uint256[2] memory keptLate;
        for (uint256 order; order < 2; ++order) {
            vm.revertToState(snap);
            uint256 drewEarly;
            uint256 drewLate;
            if (order == 0) {
                drewEarly = _drain(early, 1);
                drewLate = _drain(late, 1);
            } else {
                drewLate = _drain(late, 1);
                drewEarly = _drain(early, 1);
            }
            keptEarly[order] = _floorOf(early);
            keptLate[order] = _floorOf(late);
            console2.log(
                "MEASURED C5c order / idle filer drew / kept                 ", order, drewEarly, keptEarly[order]
            );
            console2.log(
                "MEASURED C5c order / 40% filer drew / kept                  ", order, drewLate, keptLate[order]
            );
        }
        // Paper: fall per book dollar 30%; the idle filer keeps 10,000 * 0.30, the 40% filer nothing.
        // #64 fix: the idle filer keeps nothing either (was r * T * (l - 0) = 3,000.000000).
        assertLe(keptEarly[0], 1, "#64: the idle filer kept a floor on dust");
        assertLe(keptLate[0], 1, "C5c: a request filed at 40% lent kept a floor at a 30% fall");
        assertApproxEqAbs(keptEarly[0], keptEarly[1], 10, "C5c: order of service moved the idle filer's kept floor");
        assertApproxEqAbs(keptLate[0], keptLate[1], 10, "C5c: order of service moved the late filer's kept floor");
    }

    /// @dev What one requester can hold RELATIVE TO WHAT SHE TAKES OUT: `(l - u0) / (1 - l)`, which
    ///      passes 1 once the fall per book dollar passes `(1 + u0) / 2`.
    function test_R64A4_C5d_keptOverDrawn() public {
        uint16[4] memory lostBpsOfDebt = [uint16(500), 2_500, 7_500, 10_000];
        for (uint256 k; k < lostBpsOfDebt.length; ++k) {
            Shape memory s = Shape(1_000, 1, 3, 0, 7_500, 0);
            uint256 snap = vm.snapshotState();
            uint256 loss = 75_000e6 * uint256(lostBpsOfDebt[k]) / BPS;
            Result memory r = _run(s, SOCIALISED, loss, 1);
            vm.revertToState(snap);
            console2.log(
                "MEASURED C5d bps of a 75,000 debt lost / drew / kept        ", lostBpsOfDebt[k], r.drawn, r.kept
            );
            console2.log("MEASURED C5d   kept per 10,000 drawn                        ", r.kept * BPS / r.drawn);
            // #64 fix: nothing is kept (was r * L); she still draws her floor less r * L, the
            // worth of her shares, exactly as before.
            assertLe(r.kept, 1, "#64: a floor was kept on dust");
            assertApproxEqAbs(r.drawn + loss / 10, 10_000e6, 10, "C5d: she did not draw her floor less r * L");
        }
    }

    /// @dev The accident with NO "minus one" in it: ONE honest call of
    ///      `serviceWithdrawalRequest(maxRequestRedeem())` and nothing after. Measured across the
    ///      three falls, for an idle-book filing: what that single call leaves behind.
    function test_R64A4_C5e_oneHonestMaxCallAndNothingAfter() public {
        for (uint256 kind; kind < 2; ++kind) {
            Shape memory s = Shape(1_000, 1, 3, 0, 6_000, 0);
            uint256 snap = vm.snapshotState();
            _build(s);
            _fall(kind, 5_000e6);
            address who = _requester(0);
            uint256 door = pool.maxRequestRedeem(who);
            uint256 before = _requestShares(who);
            uint256 paid = _service(who, door);
            console2.log("MEASURED C5e kind / shares requested / the door offered       ", kind, before, door);
            console2.log(
                "MEASURED C5e kind / paid / shares left / floor left           ",
                paid,
                _requestShares(who),
                _floorOf(who)
            );
            uint256 second = pool.maxRequestRedeem(who);
            console2.log("MEASURED C5e kind / a second call would offer (shares)        ", kind, second);
            assertEq(_requestShares(who), 0, "C5e: one honest max call did not complete an idle-book request");
            assertEq(_floorOf(who), 0, "C5e: one honest max call kept a floor");
            vm.revertToState(snap);
        }
    }

    /// @dev The accident that needs no intent and no "minus one": an integrator that thinks in
    ///      ASSETS. She reads what her request is worth, and services `previewWithdraw` of that
    ///      figure. The 10^3 share offset means a whole asset-wei is about a thousand share-wei,
    ///      so the round trip can leave share dust behind, and the dust keeps the floor.
    function test_R64A4_C5f_anAssetDenominatedIntegratorLeavesDust() public {
        uint256 keptSomewhere;
        uint256 tried;
        for (uint256 lossUnits = 4_000; lossUnits < 4_012; ++lossUnits) {
            Shape memory s = Shape(1_000, 1, 3, 0, 6_000, 0);
            uint256 snap = vm.snapshotState();
            _build(s);
            // An uneven loss, so the share price is not a round number.
            _fall(SOCIALISED, lossUnits * 1e6 + 333_333);
            address who = _requester(0);
            uint256 left = _requestShares(who);
            uint256 worth = pool.previewRedeem(left);
            uint256 shares = pool.previewWithdraw(worth);
            if (shares > pool.maxRequestRedeem(who)) shares = pool.maxRequestRedeem(who);
            uint256 paid = _service(who, shares);
            ++tried;
            if (_requestShares(who) != 0 && _floorOf(who) >= 1e6) ++keptSomewhere;
            console2.log(
                "MEASURED C5f loss / paid / share dust left                    ",
                lossUnits * 1e6 + 333_333,
                paid,
                _requestShares(who)
            );
            console2.log(
                "MEASURED C5f   floor kept on that dust / her door on it (cash)", _floorOf(who), _serviceable(who)
            );
            vm.revertToState(snap);
        }
        console2.log("MEASURED C5f shapes tried / shapes that kept a floor of 1.000000 or more", tried, keptSomewhere);
        // #64 fix: the asset-denominated round trip still leaves share dust, but no dust keeps a
        // floor (was every one of the twelve shapes).
        assertEq(keptSomewhere, 0, "#64: an asset-denominated service left a floor on dust");
    }

    // ───────────────────────────────────────────────────
    // 6. How long, and who can release it
    // ───────────────────────────────────────────────────

    function test_R64A4_C6_howLongAndWhoReleases() public {
        Shape memory s = Shape(1_000, 1, 3, 0, 7_000, 0);
        Result memory r = _run(s, SOCIALISED, 3_500e6, 1);
        address griefer = _requester(0);
        uint256 kept = r.kept;

        // The rest of the debt repays and a year passes: the cash is all there and the floor stands.
        _repay(pool.outstandingPrincipal());
        vm.warp(block.timestamp + 365 days);
        uint256 worth;
        uint256 door;
        for (uint256 i; i < s.dormants; ++i) {
            worth += pool.previewRedeem(pool.balanceOf(_dormant(i)));
            door += _syncable(_dormant(i));
        }
        console2.log("MEASURED C6 a year on, debt repaid: kept / worth / 1 door ", kept, worth, door / s.dormants);
        assertEq(_floorTotal(), kept, "C6: the floor moved by itself");

        // Everybody leaves as far as they can: the last of them is left holding the kept floor.
        uint256 took;
        for (uint256 i; i < s.dormants; ++i) {
            address who = _dormant(i);
            uint256 shares = pool.maxRedeem(who);
            if (shares == 0) continue;
            vm.prank(who);
            took += pool.redeem(shares, who, who);
        }
        uint256 stranded;
        for (uint256 i; i < s.dormants; ++i) {
            stranded += pool.previewRedeem(pool.balanceOf(_dormant(i)));
        }
        address last = _dormant(s.dormants - 1);
        console2.log("MEASURED C6 everybody leaves: took / stranded / last door ", took, stranded, _syncable(last));
        // #64 fix: the dust keeps only its worth rounded UP, 1 wei (was 0 under the rounded-down
        // worth), so nothing is stranded but rounding and that wei (was the kept floor, with the
        // last lender's door at 0). The requester keeps the wei; the last lender loses at most it.
        assertEq(kept, 1, "#64: the dust keeps more than its rounded-up worth");
        assertLe(stranded, 10, "#64: the last lender out was stranded");
        assertApproxEqAbs(stranded, kept, 10, "C6: what is stranded is not the kept floor");

        // A request from the stranded lender does not reach it either; the owner has no lever.
        _requestAll(last);
        console2.log("MEASURED C6 the stranded lender's request floor / door    ", _floorOf(last), _serviceable(last));
        // #64 fix: her request reaches everything that is left, the rounding (was 0).
        assertEq(_serviceable(last), stranded, "#64: the stranded lender's request does not reach the rest");
        _cancel(last);

        // A stranger cannot end it; she can, in either of two ways.
        vm.prank(stranger);
        vm.expectRevert();
        pool.serviceWithdrawalRequest(griefer, 1, 0);

        uint256 snap = vm.snapshotState();
        _cancel(griefer);
        console2.log("MEASURED C6 she cancels: floors / last lender's door      ", _floorTotal(), _syncable(last));
        assertEq(_floorTotal(), 0, "C6: her cancel did not release the floor");
        assertApproxEqAbs(_syncable(last), stranded, 10, "C6: the release did not reopen the door");
        vm.revertToState(snap);

        // #64 fix: her one share-wei holds a floor of 1 wei, which keeps a door of one share-wei
        // open, so a completing one-wei service is her other way out: it pays 0 and releases the
        // wei of floor.
        assertEq(pool.maxRequestRedeem(griefer), 1, "#64: the 1-wei floor does not hold her one share-wei's door");
        uint256 paid = _service(griefer, 1);
        console2.log("MEASURED C6 she burns the last share-wei: paid / floors   ", paid, _floorTotal());
        assertEq(paid, 0, "C6: the last share-wei paid cash");
        assertEq(_floorTotal(), 0, "C6: the completing service did not release the floor");
    }

    // ───────────────────────────────────────────────────
    // 7. Order of service, where it matters: floors over the cash (a raw loss)
    // ───────────────────────────────────────────────────

    function test_R64A4_C7_orderOfService_underARawLoss() public {
        // Two requesters of 20% each filed idle, 40% lent after, then 30,000 of CASH is lost.
        Shape memory s = Shape(4_000, 2, 2, 0, 4_000, 0);
        _build(s);
        _fall(RAW, 30_000e6);
        console2.log(
            "MEASURED C7 E / floors / shortfall after the raw loss     ", _executable(), _floorTotal(), _shortfall()
        );
        uint256 a0 = _drain(_requester(0), 1);
        uint256 b0 = _drain(_requester(1), 1);
        uint256 a1 = _drain(_requester(0), 1);
        console2.log("MEASURED C7 first / second / first again                  ", a0, b0, a1);
        console2.log(
            "MEASURED C7 kept by each                                  ",
            _floorOf(_requester(0)),
            _floorOf(_requester(1))
        );
        console2.log(
            "MEASURED C7 dust shares of each                           ",
            _requestShares(_requester(0)),
            _requestShares(_requester(1))
        );
        console2.log(
            "MEASURED C7 E left / dormant sync doors together          ",
            _executable(),
            _syncable(_dormant(0)) + _syncable(_dormant(1))
        );
        // Floors over the cash: this is the #61 lock, not the dust shape. Each draws her cap (E less the
        // other floor), neither reaches share dust, and what is left is shut to everybody.
        assertEq(a0, b0, "C7: order of service paid the two equal requesters differently");
        assertEq(a1, 0, "C7: the first requester reached more cash on a second pass");
        assertGt(_requestShares(_requester(0)), 1_000, "C7: a requester reached share dust under a raw loss");
        assertEq(_syncable(_dormant(0)) + _syncable(_dormant(1)), 0, "C7: a dormant door reached the locked cash");
    }
}
