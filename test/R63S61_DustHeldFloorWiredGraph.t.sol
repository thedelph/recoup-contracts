// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {R62A3_GraphFixture} from "./R62A3_GraphFixture.sol";

/// @title Round 63, reply seat S-61: seat A3's F1 (a floor kept on one share-wei) on the WIRED graph.
/// @notice A3 measured F1 on a bare `LenderPool` with the manager pranked. This suite asks whether
///         the same state is reachable when every loss is one the real `CreditManager` socialises:
///         a real borrower at the ceiling, a real `liquidate`, a real short fill through
///         `LiquidationAuction.bid` (the loss fraction is chosen by the NAV the mock oracle reads
///         at the fill, bid at the start price) or a real forced `closeWorkout` with nothing
///         recovered (the 100% point). Nothing here pranks the manager or the harvester, and no
///         cash leaves the pool except through its own doors.
/// @dev Every figure is 6-dp USDC, printed as a `MEASURED` line. The threshold on paper for a
///      griefer of `g`, a dormant lender of `o`, `T = g + o` and a loan `X`, where the dormant
///      lender takes every unreserved unit synchronously before the loss:
///      `loss / X > 1 - (T - X) * o / T^2`. With g = o = X that is 75% (A3's D4 shape); with
///      g = X / 2, o = 9.5 X it is 14.5%.
///      #64 (round 63 seat A3's F1; this is its wired half). This suite pinned the finding as the
///      tree stood; its dust-held-floor assertions are FLIPPED to the #64 fix, which writes the
///      floor left on dust down to what the dust is worth while the floors sit inside the
///      executable cash. Every point here is a socialised loss inside the cash, so no point keeps
///      a floor any more and the dormant lender reaches her whole worth to a wei or two.
contract R63S61_DustHeldFloorWiredGraph is R62A3_GraphFixture {
    address internal griefer = makeAddr("s61-griefer");
    address internal dormant = makeAddr("s61-dormant");
    address internal fresh = makeAddr("s61-fresh");

    uint256 internal constant FORCED_CLOSE = type(uint256).max;

    function setUp() public {
        _buildGraph(new MockUSDC());
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _syncable(address who) internal view returns (uint256) {
        return pool.previewRedeem(pool.maxRedeem(who));
    }

    function _requestShares(address who) internal view returns (uint256 shares) {
        (,, shares,,) = pool.withdrawalRequest(who);
    }

    function _service(address who, uint256 shares) internal returns (uint256 paid) {
        vm.prank(who);
        paid = pool.serviceWithdrawalRequest(who, shares, 0);
    }

    /// @dev The honest twin: service whatever the door offers until the request is gone or the
    ///      door is shut, a zero-cash last share-wei included.
    function _complete(address who) internal returns (uint256 paid) {
        for (uint256 call; call < 16; ++call) {
            uint256 shares = pool.maxRequestRedeem(who);
            if (shares == 0) break;
            paid += _service(who, shares);
        }
    }

    /// @dev The grief: everything the door offers, never the last share-wei of the request.
    function _allButOneShareWei(address who) internal returns (uint256 paid) {
        for (uint256 call; call < 16; ++call) {
            uint256 door = pool.maxRequestRedeem(who);
            uint256 left = _requestShares(who);
            uint256 shares = door < left ? door : left - 1;
            if (shares == 0) break;
            paid += _service(who, shares);
        }
    }

    /// @dev Deposits, a real ceiling borrow, the griefer queues everything, the dormant lender
    ///      takes every unreserved unit through the synchronous door.
    function _shape(uint256 griefDeposit, uint256 dormantDeposit) internal returns (uint256 debt, uint256 took) {
        _lenderDeposit(griefer, griefDeposit);
        _lenderDeposit(dormant, dormantDeposit);
        _stakeBonds(alice, BONDS);
        debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        _requestAll(griefer);
        uint256 idleShares = pool.maxRedeem(dormant);
        vm.prank(dormant);
        took = pool.redeem(idleShares, dormant, dormant);
    }

    /// @dev A real loss of about `lossBps` of the debt: the NAV is set so the lot's START price is
    ///      the rest, the keeper liquidates and the bidder fills at once. `FORCED_CLOSE` is the
    ///      100% point: nobody bids, the auction lapses to a workout, nothing is recovered and the
    ///      permissionless forced close writes the whole debt down.
    function _realLoss(uint256 debt, uint256 lossBps) internal returns (uint256 socialised) {
        uint256 before = pool.lifetimeSocialisedLoss();
        if (lossBps == FORCED_CLOSE) {
            oracle.setNav(_crashedNav());
            vm.prank(keeper);
            credit.liquidate(alice);
            uint256 workoutId = auction.auctionOf(alice);
            skip(Config.AUCTION_DURATION + 1);
            auction.expireToWorkout(workoutId);
            skip(Config.WORKOUT_MAX_DURATION);
            auction.closeWorkout(workoutId);
        } else {
            uint256 proceeds = debt * (Config.BPS - lossBps) / Config.BPS;
            oracle.setNav(proceeds * Config.USDC_TO_NAV_SCALE / BONDS);
            vm.prank(keeper);
            credit.liquidate(alice);
            uint256 id = auction.auctionOf(alice);
            uint256 price = auction.currentPrice(id);
            bond.setWhitelisted(bidder, true);
            _fund(bidder, price);
            vm.prank(bidder);
            auction.bid(id);
            // The fill parks the recovered principal on the manager; the permissionless settle
            // delivers it to the pool. Without it the loan reads open and the cash is not in E.
            credit.settlePrincipal();
        }
        socialised = pool.lifetimeSocialisedLoss() - before;
    }

    struct Point {
        uint256 socialised;
        uint256 floor;
        uint256 worth;
        uint256 honestDrew;
        uint256 honestDormantDoor;
        uint256 griefDrew;
        uint256 kept;
        uint256 dormantWorth;
        uint256 dormantSyncDoor;
        uint256 dormantRequestDoor;
        uint256 yearLaterSync;
        uint256 yearLaterRequest;
        uint256 availableToLend;
        uint256 firstDoorShares;
        uint256 requestShares;
    }

    function _measure(uint256 debt, uint256 lossBps) internal returns (Point memory p) {
        uint256 clean = vm.snapshotState();
        p.socialised = _realLoss(debt, lossBps);
        p.floor = _floorOf(griefer);
        p.worth = pool.previewRedeem(_requestShares(griefer));
        assertLe(_floorTotal(), _executable(), "the floors exceed E: this would be the #61 lock, not F1");
        assertEq(pool.outstandingPrincipal(), 0, "the loan did not close");
        uint256 afterLoss = vm.snapshotState();

        p.firstDoorShares = pool.maxRequestRedeem(griefer);
        p.requestShares = _requestShares(griefer);
        p.honestDrew = _complete(griefer);
        assertEq(_requestShares(griefer), 0, "the honest twin did not complete");
        assertEq(_floorTotal(), 0, "the honest twin left a floor");
        p.honestDormantDoor = _syncable(dormant);

        vm.revertToState(afterLoss);
        p.griefDrew = _allButOneShareWei(griefer);
        assertEq(_requestShares(griefer), 1, "the grief did not stop at one share-wei");
        p.kept = _floorOf(griefer);
        p.dormantWorth = pool.previewRedeem(pool.balanceOf(dormant));
        p.dormantSyncDoor = _syncable(dormant);
        p.availableToLend = pool.available();
        uint256 shut = vm.snapshotState();
        _requestAll(dormant);
        p.dormantRequestDoor = _serviceable(dormant);
        vm.revertToState(shut);
        skip(365 days);
        p.yearLaterSync = _syncable(dormant);
        _requestAll(dormant);
        p.yearLaterRequest = _serviceable(dormant);

        vm.revertToState(clean);
    }

    function _print(string memory tag, uint256 debt, Point memory p) internal pure {
        console2.log(
            string.concat("MEASURED ", tag, ": socialised loss / of debt (bps)          "),
            p.socialised,
            p.socialised * 10_000 / debt
        );
        console2.log(string.concat("MEASURED ", tag, ": griefer floor / her shares are worth     "), p.floor, p.worth);
        console2.log(
            string.concat("MEASURED ", tag, ": honest drew / dormant sync door after    "),
            p.honestDrew,
            p.honestDormantDoor
        );
        console2.log(
            string.concat("MEASURED ", tag, ": grief drew / floor kept on 1 share-wei   "), p.griefDrew, p.kept
        );
        console2.log(
            string.concat("MEASURED ", tag, ": dormant worth / sync door / request door "),
            p.dormantWorth,
            p.dormantSyncDoor,
            p.dormantRequestDoor
        );
        console2.log(
            string.concat("MEASURED ", tag, ": a year later sync / request door         "),
            p.yearLaterSync,
            p.yearLaterRequest
        );
        console2.log(string.concat("MEASURED ", tag, ": available() to lend                      "), p.availableToLend);
        console2.log(
            string.concat("MEASURED ", tag, ": first door (shares) / request shares         "),
            p.firstDoorShares,
            p.requestShares
        );
    }

    function _tag(string memory shape, uint256 lossBps) internal pure returns (string memory) {
        if (lossBps == FORCED_CLOSE) return string.concat("[", shape, " forced close]");
        return string.concat("[", shape, " ", vm.toString(lossBps), " bps]");
    }

    // ── W1: A3's D4 shape (griefer = dormant = the loan), threshold 75% on paper ─────────────

    function test_R63S61_W1_d4ShapeOnTheWiredGraph_threePointsEitherSideOf75Percent() public {
        uint256 debt = _maxBorrowAtCeiling();
        (uint256 borrowed, uint256 took) = _shape(debt, debt);
        assertEq(borrowed, debt);
        console2.log(
            "MEASURED [W1] debt / maxLtvBps / liquidationThresholdBps   ", debt, maxLtvBps(), liquidationThresholdBps()
        );
        console2.log("MEASURED [W1] griefer floor at filing / dormant took sync  ", _floorOf(griefer), took);
        console2.log(
            "MEASURED [W1] E / floors / principal before the loss       ",
            _executable(),
            _floorTotal(),
            pool.outstandingPrincipal()
        );

        uint256[7] memory points = [uint256(5_000), 6_500, 7_400, 7_600, 8_500, 9_500, FORCED_CLOSE];
        for (uint256 i; i < points.length; ++i) {
            Point memory p = _measure(debt, points[i]);
            _print(_tag("W1", points[i]), debt, p);
            // The griefer never pays for it: she draws what her honest twin draws, to a wei.
            assertGe(p.griefDrew + 1, p.honestDrew, "the grief cost the griefer more than a wei");
            if (points[i] < 7_500) {
                assertEq(p.kept, 0, "under the threshold a floor was kept on dust");
                assertGe(p.dormantSyncDoor + 2, p.dormantWorth, "under the threshold the dormant lender is shut out");
            } else {
                // #64 fix: over the old threshold the dust keeps no floor and shuts nothing out.
                assertEq(p.kept, 0, "#64: over the old threshold a floor was still kept on dust");
                assertGt(p.floor, p.worth, "fixture: this point no longer puts the floor over the worth");
                assertLe(p.dormantWorth - p.dormantSyncDoor, 2, "#64: the dormant lender is still shut out");
                assertEq(p.yearLaterSync, p.dormantSyncDoor, "a year moved the sync door");
                assertEq(p.yearLaterRequest, p.dormantRequestDoor, "a year moved the request door");
            }
        }
    }

    /// @notice The 100% point end to end, with the ways out: only the griefer's own last service.
    function test_R63S61_W2_forcedCloseThenTheDoors() public {
        uint256 debt = _maxBorrowAtCeiling();
        _shape(debt, debt);
        uint256 socialised = _realLoss(debt, FORCED_CLOSE);
        console2.log("MEASURED [W2] socialised by the real forced close / debt   ", socialised, debt);
        console2.log(
            "MEASURED [W2] E / floors / griefer shares worth            ",
            _executable(),
            _floorTotal(),
            pool.previewRedeem(_requestShares(griefer))
        );
        uint256 drew = _allButOneShareWei(griefer);
        uint256 kept = _floorOf(griefer);
        console2.log("MEASURED [W2] grief drew / kept floor / shares left        ", drew, kept, _requestShares(griefer));
        console2.log(
            "MEASURED [W2] dormant worth / sync door                    ",
            pool.previewRedeem(pool.balanceOf(dormant)),
            _syncable(dormant)
        );
        console2.log(
            "MEASURED [W2] griefer's own door on the dust (shares, cash)",
            pool.maxRequestRedeem(griefer),
            _serviceable(griefer)
        );
        // #64 fix: the dust keeps no floor, so the dormant lender reaches her worth to two wei.
        assertEq(kept, 0, "#64: one share-wei still keeps a floor");
        assertApproxEqAbs(
            _syncable(dormant), pool.previewRedeem(pool.balanceOf(dormant)), 2, "#64: the dormant lender is shut out"
        );
        // #64 fix: no floor is kept, so the pool can lend again (was 0 against the kept floor).
        assertGt(pool.available(), 0, "#64: the pool still cannot lend");

        // A stranger and the dormant lender cannot service or cancel for her.
        vm.prank(dormant);
        (bool ok,) = address(pool).call(abi.encodeCall(pool.serviceWithdrawalRequest, (griefer, 1, 0)));
        assertFalse(ok, "a stranger serviced her request");

        // A new borrower cannot draw the reserved cash either.
        uint256 shut = vm.snapshotState();
        address bob = makeAddr("s61-bob");
        _stakeBonds(bob, BONDS);
        oracle.setNav(NAV);
        vm.prank(bob);
        (ok,) = address(credit).call(abi.encodeCall(credit.borrow, (1e6)));
        console2.log("MEASURED [W2] a fresh 1.000000 borrow against the kept floor succeeds", ok);
        vm.revertToState(shut);

        // A deposit passes the parcel.
        _lenderDeposit(fresh, debt);
        console2.log("MEASURED [W2] after a deposit of the debt: dormant sync door", _syncable(dormant));
        uint256 out = pool.maxRedeem(dormant);
        vm.prank(dormant);
        pool.redeem(out, dormant, dormant);
        console2.log(
            "MEASURED [W2] depositor worth / her sync door after dormant left",
            pool.previewRedeem(pool.balanceOf(fresh)),
            _syncable(fresh)
        );
        console2.log(
            "MEASURED [W2] cash only the griefer can release             ", _executable() - pool.unreservedIdle()
        );
        vm.revertToState(shut);

        // #64 fix: there is nothing left for her to end. Her one share-wei holds no floor, and her
        // draw memory has spent her slice, so her door on it is 0 and only a cancel removes it
        // (was: her completing one-wei service released the kept floor).
        assertEq(pool.maxRequestRedeem(griefer), 0, "#64: the dust holds a door without a floor");
        vm.prank(griefer);
        pool.cancelWithdrawalRequest();
        console2.log(
            "MEASURED [W2] she cancels the dust: floors / dormant sync door", _floorTotal(), _syncable(dormant)
        );
        assertEq(_floorTotal(), 0);
        assertGt(_syncable(dormant), 0);
    }

    // ── W3: a small griefer beside a large dormant lender at 10% utilisation: 14.5% on paper ──

    function test_R63S61_W3_smallGrieferLowUtilisation_thresholdFarUnder75Percent() public {
        uint256 debt = _maxBorrowAtCeiling();
        (, uint256 took) = _shape(debt / 2, debt * 19 / 2);
        console2.log("MEASURED [W3] debt / griefer deposit / dormant deposit     ", debt, debt / 2, debt * 19 / 2);
        console2.log("MEASURED [W3] griefer floor at filing / dormant took sync  ", _floorOf(griefer), took);

        uint256[7] memory points = [uint256(500), 1_000, 1_400, 1_500, 2_000, 3_000, 5_000];
        for (uint256 i; i < points.length; ++i) {
            Point memory p = _measure(debt, points[i]);
            _print(_tag("W3", points[i]), debt, p);
            assertGe(p.griefDrew + 1, p.honestDrew, "the grief cost the griefer more than a wei");
            if (points[i] < 1_450) {
                assertEq(p.kept, 0, "under the threshold a floor was kept on dust");
            } else {
                // #64 fix: over the old threshold the dust keeps no floor and shuts nothing out.
                assertEq(p.kept, 0, "#64: over the old threshold a floor was still kept on dust");
                assertLe(p.dormantWorth - p.dormantSyncDoor, 2, "#64: the dormant lender is still shut out");
            }
        }
    }
}
