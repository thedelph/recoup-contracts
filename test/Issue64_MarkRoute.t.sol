// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {R62A3_GraphFixture} from "./R62A3_GraphFixture.sol";

/// @title #64 on the WIRED four-contract graph: the dust-held floor with NO loss of any kind (a
///         routine auction's mark, a 14-day workout's mark), and the window between a short fill
///         and the permissionless `settlePrincipal`.
/// @notice The no-loss mark route of #64. Written first (internal review round 64) to pin the
///         floor the old rule kept on one share-wei after a routine liquidation that clears in
///         full (W1), after a careless exit inside a workout that is then rescued in full (W2) and
///         after a short fill's socialised loss inside the cash (W5). The three dust-held-floor
///         assertions are FLIPPED to the #64 fix: the floor left on dust is at most one wei. Every
///         other assertion is unchanged. On a tree without the fix W1, W2 and W5 fail; W3 and W4,
///         the settle window, pass on both.
/// @dev Real `CreditManager`, `LiquidationAuction`, `CollateralVault`, `LenderPool` and adapter
///      over `MockUSDC` (`R62A3_GraphFixture`); a real ceiling borrow, a real `liquidate`, real
///      bids and a real rescue. Six-decimal USDC base units; every `MEASURED` line was read from a
///      run before the figure beside it was asserted.
contract Issue64_MarkRoute is R62A3_GraphFixture {
    address internal early = makeAddr("a4-early-filer");
    address internal dormant = makeAddr("a4-dormant");
    address internal fresh = makeAddr("a4-fresh");
    address internal rescuer = makeAddr("a4-rescuer");

    function setUp() public {
        _buildGraph(new MockUSDC());
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _requestShares(address who) internal view returns (uint256 shares) {
        (,, shares,,) = pool.withdrawalRequest(who);
    }

    function _service(address who, uint256 shares) internal returns (uint256 paid) {
        vm.prank(who);
        paid = pool.serviceWithdrawalRequest(who, shares, 0);
    }

    /// @dev Everything the door offers, stopping `leave` share-wei short of the end.
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

    /// @dev What a lender has and could have: wallet USDC, set-aside claims, and every share she
    ///      owns or has in escrow at the live exit price.
    function _wealth(address who) internal view returns (uint256) {
        return usdc.balanceOf(who) + pool.claimable(who) + pool.previewRedeem(pool.balanceOf(who) + _requestShares(who));
    }

    /// @dev The early filer queues her whole 1,000 in an IDLE book beside a dormant 1,000; then
    ///      the real ceiling borrow goes out. Returns the debt.
    function _idleFilingThenBorrow() internal returns (uint256 debt) {
        _lenderDeposit(early, 1_000e6);
        _lenderDeposit(dormant, 1_000e6);
        _requestAll(early);
        assertEq(_floorOf(early), 1_000e6, "fixture: an idle-book filing is not quoted its whole worth");
        _stakeBonds(alice, BONDS);
        debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
    }

    /// @dev The NAV slips just under the liquidation line: a ROUTINE liquidation, the lot worth
    ///      far more than the debt.
    function _routineLiquidation(uint256 debt) internal returns (uint256 id) {
        oracle.setNav(_navAtThreshold(debt, BONDS) * 99 / 100);
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: no auction opened");
    }

    function _fill(uint256 id) internal returns (uint256 price) {
        price = auction.currentPrice(id);
        bond.setWhitelisted(bidder, true);
        _fund(bidder, price);
        vm.prank(bidder);
        auction.bid(id);
    }

    // ───────────────────────────────────────────────────
    // 1. NO LOSS: a routine auction that clears the debt in full
    // ───────────────────────────────────────────────────

    function test_R64A4_W1_aRoutineAuctionThatClearsInFull_keepsAFloor_lossZero() public {
        uint256 debt = _idleFilingThenBorrow();
        uint256 id = _routineLiquidation(debt);
        console2.log(
            "MEASURED W1 debt / mark the pool carries / exit reserve     ",
            debt,
            pool.totalImpairment(),
            pool.exitReserve()
        );
        assertEq(pool.exitReserve(), debt, "W1: the auction's mark is not the whole debt");

        uint256 clean = vm.snapshotState();
        uint256[2] memory drew;
        uint256[2] memory kept;
        uint256[2] memory syncCash;
        uint256[2] memory lendable;
        uint256[2] memory dormantDoor;
        for (uint256 leave; leave < 2; ++leave) {
            vm.revertToState(clean);
            drew[leave] = _drain(early, leave);
            uint256 price = _fill(id);
            credit.settlePrincipal();
            kept[leave] = _floorTotal();
            syncCash[leave] = pool.unreservedIdle();
            lendable[leave] = pool.available();
            dormantDoor[leave] = pool.previewRedeem(pool.maxRedeem(dormant));
            console2.log("MEASURED W1 leave / she drew during the auction / fill price", leave, drew[leave], price);
            console2.log(
                "MEASURED W1 leave / floor kept / her request shares         ",
                leave,
                kept[leave],
                _requestShares(early)
            );
            console2.log(
                "MEASURED W1 leave / loss socialised / mark / principal out  ",
                pool.lifetimeSocialisedLoss(),
                pool.exitReserve(),
                pool.outstandingPrincipal()
            );
            console2.log(
                "MEASURED W1 leave / dormant worth / sync door / lendable    ",
                pool.previewRedeem(pool.balanceOf(dormant)),
                dormantDoor[leave],
                lendable[leave]
            );
            assertEq(pool.lifetimeSocialisedLoss(), 0, "W1: a loss was socialised; this is not the no-loss route");
            assertEq(pool.exitReserve(), 0, "W1: the mark outlived the fill");
            assertEq(pool.outstandingPrincipal(), 0, "W1: the loan did not clear in full");
        }
        assertEq(kept[0], 0, "W1: the honest twin kept a floor");
        assertEq(drew[0], drew[1], "W1: the careless exit drew a different amount");
        // Paper: r * T * (M / T - u0) = 1,000 * debt / 2,000.
        assertLe(kept[1], 1, "W1 (B-flipped): a floor was kept on dust after a no-loss mark");
        assertApproxEqAbs(
            dormantDoor[0] - dormantDoor[1], kept[1], 10, "W1: the dormant door is not short by the kept floor"
        );
    }

    // ───────────────────────────────────────────────────
    // 2. NO LOSS: the 14-day workout, rescued in full
    // ───────────────────────────────────────────────────

    function test_R64A4_W2_aCarelessExitInsideTheWorkout_thenAFullRescue_keepsAFloor_lossZero() public {
        uint256 debt = _idleFilingThenBorrow();
        uint256 id = _routineLiquidation(debt);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(7 days);
        console2.log(
            "MEASURED W2 day 7 of the workout: mark / her door (cash)    ", pool.exitReserve(), _serviceable(early)
        );

        uint256 drew = _drain(early, 1);
        uint256 owed = credit.currentDebtOf(alice);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();
        auction.closeWorkout(id);
        credit.settlePrincipal();

        console2.log(
            "MEASURED W2 she drew / floor kept / her request shares      ", drew, _floorTotal(), _requestShares(early)
        );
        console2.log(
            "MEASURED W2 loss socialised / mark / principal out          ",
            pool.lifetimeSocialisedLoss(),
            pool.exitReserve(),
            pool.outstandingPrincipal()
        );
        console2.log(
            "MEASURED W2 dormant worth / sync door / lendable            ",
            pool.previewRedeem(pool.balanceOf(dormant)),
            pool.previewRedeem(pool.maxRedeem(dormant)),
            pool.available()
        );
        assertEq(pool.lifetimeSocialisedLoss(), 0, "W2: a loss was socialised");
        assertEq(pool.exitReserve(), 0, "W2: the mark outlived the clean close");
        assertEq(_requestShares(early), 1, "W2: she did not end on one share-wei");
        assertLe(_floorTotal(), 1, "W2 (B-flipped): the workout's mark kept a floor on dust");

        // A year on nothing has moved, and the dormant lender cannot reach the kept floor.
        skip(365 days);
        uint256 worth = pool.previewRedeem(pool.balanceOf(dormant));
        uint256 door = pool.previewRedeem(pool.maxRedeem(dormant));
        console2.log("MEASURED W2 a year on: dormant worth / door / still kept    ", worth, door, _floorTotal());
        assertApproxEqAbs(worth - door, _floorTotal(), 10, "W2: the dormant lender is not short by the kept floor");
    }

    // ───────────────────────────────────────────────────
    // 3. The window between a SHORT fill and `settlePrincipal`
    // ───────────────────────────────────────────────────

    /// @dev Three lenders of 1,000 (one queued at filing, in a book already lent), a ceiling
    ///      borrow, then a fill that recovers about 80% of the debt. NOT settled.
    function _shortFillUnsettled() internal returns (uint256 debt, uint256 recovered) {
        _lenderDeposit(early, 1_000e6);
        _lenderDeposit(dormant, 1_000e6);
        _stakeBonds(alice, BONDS);
        debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        _requestAll(early);
        oracle.setNav(debt * 8_000 / Config.BPS * Config.USDC_TO_NAV_SCALE / BONDS);
        vm.prank(keeper);
        credit.liquidate(alice);
        recovered = _fill(auction.auctionOf(alice));
    }

    function _printDoors(string memory tag) internal {
        console2.log(tag);
        console2.log(
            "MEASURED   pending on the manager / principal out / E         ",
            credit.pendingPrincipal(),
            pool.outstandingPrincipal(),
            _executable()
        );
        console2.log(
            "MEASURED   totalAssets / price of 1e9 shares / loss socialised",
            pool.totalAssets(),
            pool.previewRedeem(1e9),
            pool.lifetimeSocialisedLoss()
        );
        console2.log(
            "MEASURED   queued door / dormant sync door / lendable         ",
            _serviceable(early),
            pool.previewRedeem(pool.maxRedeem(dormant)),
            pool.available()
        );
        console2.log(
            "MEASURED   shares for a 100.000000 deposit / maxDeposit       ",
            pool.previewDeposit(100e6),
            pool.maxDeposit(fresh)
        );
        uint256 snap = vm.snapshotState();
        _lenderDeposit(fresh, 1_000e6);
        _requestAll(fresh);
        console2.log(
            "MEASURED   a fresh 1,000 filed now: her floor / her door      ", _floorOf(fresh), _serviceable(fresh)
        );
        vm.revertToState(snap);
    }

    function test_R64A4_W3_theDoorsInsideTheWindow_andAfterIt() public {
        (uint256 debt, uint256 recovered) = _shortFillUnsettled();
        console2.log("MEASURED W3 debt / recovered by the fill                    ", debt, recovered);
        uint256 priceInside = pool.previewRedeem(1e9);
        uint256 assetsInside = pool.totalAssets();
        uint256 mintInside = pool.previewDeposit(100e6);
        assertGt(credit.pendingPrincipal(), 0, "W3: nothing is parked; there is no window");
        assertGt(pool.lifetimeSocialisedLoss(), 0, "W3: the loss was not socialised AT the fill");
        _printDoors("W3 INSIDE the window (filled, not settled)");

        vm.prank(stranger);
        credit.settlePrincipal();
        _printDoors("W3 AFTER a stranger's settlePrincipal");
        assertEq(credit.pendingPrincipal(), 0, "W3: a stranger could not settle");
        assertEq(pool.previewRedeem(1e9), priceInside, "W3: settling moved the exit price");
        assertEq(pool.totalAssets(), assetsInside, "W3: settling moved the book");
        assertEq(pool.previewDeposit(100e6), mintInside, "W3: settling moved the entry price");
    }

    /// @dev WHO BEARS THE LOSS. Each act is done once INSIDE the window and once AFTER the settle;
    ///      then everything is settled, a year passes, and each lender's wealth is read. If the
    ///      window let anybody move the loss, the two columns would differ.
    function test_R64A4_W4_noActInsideTheWindowMovesTheLossBetweenLenders() public {
        _shortFillUnsettled();
        uint256 clean = vm.snapshotState();
        for (uint256 act; act < 5; ++act) {
            uint256[2] memory wEarly;
            uint256[2] memory wDormant;
            uint256[2] memory wFresh;
            for (uint256 afterSettle; afterSettle < 2; ++afterSettle) {
                vm.revertToState(clean);
                if (afterSettle == 1) credit.settlePrincipal();
                _act(act);
                if (afterSettle == 0) credit.settlePrincipal();
                skip(30 days);
                wEarly[afterSettle] = _wealth(early);
                wDormant[afterSettle] = _wealth(dormant);
                wFresh[afterSettle] = _wealth(fresh);
            }
            console2.log("MEASURED W4 act / queued lender's wealth: inside, after      ", act, wEarly[0], wEarly[1]);
            console2.log("MEASURED W4 act / dormant lender's wealth: inside, after     ", act, wDormant[0], wDormant[1]);
            console2.log("MEASURED W4 act / fresh lender's wealth: inside, after       ", act, wFresh[0], wFresh[1]);
            assertApproxEqAbs(wEarly[0], wEarly[1], 2, "W4: the window moved the queued lender's wealth");
            assertApproxEqAbs(wDormant[0], wDormant[1], 2, "W4: the window moved the dormant lender's wealth");
            assertApproxEqAbs(wFresh[0], wFresh[1], 2, "W4: the window moved the fresh lender's wealth");
        }
    }

    /// @dev 0 a fresh deposit; 1 the dormant lender takes her whole sync door; 2 the queued lender
    ///      services her whole door; 3 a fresh deposit that is queued at once and serviced; 4 the
    ///      harvester delivers 50.000000 of lender yield.
    function _act(uint256 act) internal {
        if (act == 0 || act == 3) {
            _lenderDeposit(fresh, 1_000e6);
            if (act == 3) {
                _requestAll(fresh);
                _drain(fresh, 0);
            }
        } else if (act == 1) {
            uint256 shares = pool.maxRedeem(dormant);
            if (shares != 0) {
                vm.prank(dormant);
                pool.redeem(shares, dormant, dormant);
            }
        } else if (act == 2) {
            _drain(early, 0);
        } else {
            usdc.mint(harvester, 50e6);
            vm.startPrank(harvester);
            usdc.approve(address(pool), 50e6);
            pool.distributeYield(50e6);
            vm.stopPrank();
        }
    }

    /// @dev The dust-held floor INSIDE the window against after it: same floor either way.
    function test_R64A4_W5_theDustHeldFloorInsideTheWindowAgainstAfterIt() public {
        // The idle-book filing, so the short fill's loss alone keeps a floor (no sync exits).
        uint256 debt = _idleFilingThenBorrow();
        oracle.setNav(debt * 8_000 / Config.BPS * Config.USDC_TO_NAV_SCALE / BONDS);
        vm.prank(keeper);
        credit.liquidate(alice);
        _fill(auction.auctionOf(alice));
        uint256 loss = pool.lifetimeSocialisedLoss();

        uint256 clean = vm.snapshotState();
        uint256[2] memory kept;
        uint256[2] memory drew;
        for (uint256 afterSettle; afterSettle < 2; ++afterSettle) {
            vm.revertToState(clean);
            if (afterSettle == 1) credit.settlePrincipal();
            drew[afterSettle] = _drain(early, 1);
            if (afterSettle == 0) credit.settlePrincipal();
            kept[afterSettle] = _floorTotal();
            console2.log(
                "MEASURED W5 after settle? / she drew / floor kept / dust shares",
                afterSettle,
                drew[afterSettle],
                kept[afterSettle]
            );
        }
        console2.log("MEASURED W5 debt / loss socialised at the fill               ", debt, loss);
        assertLe(kept[1], 1, "W5 (B-flipped): a socialised loss inside the cash kept a floor on dust");
        assertEq(kept[0], kept[1], "W5: the window changed what is kept");
    }
}
