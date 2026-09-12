// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R53A01 - the four auction leads of round-53 item 179, executed
/// @notice Audit round 53. Self-contained: this file deploys its own stack and inherits nothing
///         from the repository's fixtures. The fixture is a copy of the one
///         `R52A02_WorkoutReserve.t.sol` built, so the two files measure the same stack.
///
/// @dev Every test here runs at the pre-fix tree `a9ae1f4` AND under either fix variant of
///      round-53 item 178 (variant C, the `workoutYieldOwedOn` split; variant A, the split plus a
///      pull from the recorded bearer). Nothing here names `workoutYieldOwedOn`, so the file
///      compiles on all three trees. **Promoted to a regression suite by round 53's contracts
///      wave, which ships variant A**; "shipped tree" below means `a9ae1f4`, before the fix, and
///      every test here is green on the tree that carries this file.
///
///      🟥 **One test is FIX-ASSERTING and was RED at the pre-fix tree by design**:
///      `test_R53A01_lead5_bothBorrowersArePaidInFullOnceTheDetachedBackingIsPushed` asserts the
///      property round-53 item 178's fix restores (bob booked and paid what his lot earned). At
///      `a9ae1f4` it fails on bob's booking; under variant C and variant A it passes, and it prints
///      which path alice's first claim took, which is the whole of lead (5).
///
///      The other four are negatives or measurements, green on every tree.
contract R53A01_AuctionLeads is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant DILUTION_BONDS = 37;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal rescuer = makeAddr("rescuer");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            admin
        );

        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        treasury = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(treasury), TREASURY_FLOAT);

        _seed(alice, BONDS);
        _seed(bob, BONDS);
    }

    // ── fixture helpers (copied from R52A02, same stack) ─────────────────────

    function _seed(address who, uint256 bonds) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _maxBorrow(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return (bonds * nav * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    function _navAtDebtParity(uint256 debt, uint256 bonds) internal pure returns (uint256) {
        return (debt * Config.USDC_TO_NAV_SCALE) / bonds;
    }

    function _openWorkoutOn(CreditManager cm, address who) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(who);
        cm.borrow(debt);
        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);
        vm.prank(keeper);
        cm.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: no auction opened");
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(who), 1, "fixture: no workout opened");
    }

    function _openWorkout(address who) internal returns (uint256 id) {
        return _openWorkoutOn(credit, who);
    }

    function _streamEpochOn(CreditManager cm, uint256 amount) internal {
        _startStreamOn(cm, amount);
        skip(Config.YIELD_STREAM_DURATION + 1);
        cm.accrueYield();
    }

    function _streamEpoch(uint256 amount) internal {
        _streamEpochOn(credit, amount);
    }

    function _startStreamOn(CreditManager cm, uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(cm), amount);
        cm.receiveYield(amount);
        cm.distributeYield(amount);
        vm.stopPrank();
    }

    function _rescueDebtOn(CreditManager cm, address who) internal {
        uint256 owed = cm.currentDebtOf(who);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(cm), owed);
        cm.repayFor(who, owed);
        vm.stopPrank();
        assertEq(cm.debtOf(who), 0, "fixture: debt not cleared");
    }

    function _rescueDebt(address who) internal {
        _rescueDebtOn(credit, who);
    }

    function _migrate() internal returns (CreditManager fresh) {
        fresh = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        TreasuryLiquiditySource freshTreasury = new TreasuryLiquiditySource(usdc, admin);
        usdc.mint(address(freshTreasury), TREASURY_FLOAT);
        vm.startPrank(admin);
        vault.setCreditManager(address(fresh));
        freshTreasury.setCreditManager(address(fresh));
        fresh.setLiquiditySource(address(freshTreasury));
        fresh.setEpochHarvester(harvester);
        fresh.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(fresh));
        vm.stopPrank();
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _yieldIndexAtOpen(uint256 id) internal view returns (uint256 idx) {
        (,,,,,,,,, idx,) = auction.workouts(id);
    }

    function _bearer(uint256 id) internal view returns (address b) {
        (,,,,,,,, b,,) = auction.workouts(id);
    }

    function _pot(CreditManager cm) internal view returns (uint256) {
        return cm.claimableOf(address(auction)) + cm.pendingYieldOf(address(auction));
    }

    /// @dev `workoutYieldOwedOn(address)` exists only under a fix variant. Probed by selector so the
    ///      file compiles on the shipped tree; `present` is false there.
    function _splitOn(address cm) internal view returns (bool present, uint256 value) {
        (bool ok, bytes memory ret) =
            address(auction).staticcall(abi.encodeWithSignature("workoutYieldOwedOn(address)", cm));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    // ── lead (2): the settle grind on the shared position, ONE lot ───────────

    /// @notice MEASUREMENT, green everywhere. Round-53 item 179 lead (2). `closeWorkout` computes
    ///         `earned` with ONE floor over the lot (`yieldAccruedOn`), while the manager's pot for
    ///         the auction's position is a sum of per-settle floors, and `settle(auction)` is
    ///         permissionless. With a single open lot and a stranger grinding hourly settles the
    ///         pot falls short of `earned` by up to one wei per settle. The question the lead
    ///         carried: does the `reachable` clamp absorb that on a single lot, so the booking never
    ///         exceeds the money? Answer, measured: yes - the booking is `min(earned, pot)`, the
    ///         borrower is paid the booking in full, and nothing is left unbacked.
    function test_R53A01_lead2_theSettleGrindOnASingleLotIsAbsorbedByTheReachableClamp() public {
        _seed(carol, DILUTION_BONDS);
        uint256 id = _openWorkout(alice);

        _startStreamOn(credit, EPOCH);
        uint256 settles;
        for (uint256 t = 1 hours; t <= Config.YIELD_STREAM_DURATION; t += 1 hours) {
            skip(1 hours);
            vm.prank(stranger);
            credit.settle(address(auction));
            settles++;
        }
        skip(1);
        credit.accrueYield();

        uint256 exact = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(id));
        uint256 potBefore = _pot(credit);
        _rescueDebt(alice);
        auction.closeWorkout(id);
        uint256 booked = _yieldOwed(id);
        uint256 potAfter = _pot(credit);

        emit log_named_uint("MEASURED settles ground on the single-lot position", settles);
        emit log_named_uint("MEASURED earned (one floor, closeWorkout's figure)  ", exact);
        emit log_named_uint("MEASURED pot before the close (per-settle floors)   ", potBefore);
        emit log_named_uint("MEASURED pot after the close                        ", potAfter);
        emit log_named_uint("MEASURED booked                                     ", booked);
        emit log_named_uint("MEASURED earned - booked (the grind, absorbed)      ", exact > booked ? exact - booked : 0);

        // The clamp: the booking never exceeds what exists, whatever the grind did.
        assertLe(booked, potAfter, "the booking exceeds the pot: the clamp did not absorb the grind");
        assertLe(exact - booked, settles + 2, "the shortfall outran one wei per settle");

        // And the borrower is paid the booking in full, with nothing left over or short.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - before, booked, "alice was not paid her booking");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a booking survived the claim");
        // What the pull realised beyond the booking is dust and is unreserved, so the free-balance
        // sweep either refuses (nothing above the reserve) or moves at most that dust.
        uint256 insBefore = credit.insuranceFund();
        vm.prank(stranger);
        try auction.sweepFreeBalanceToInsurance() {} catch {}
        assertLe(credit.insuranceFund() - insBefore, 2, "more than dust was left unbooked by the clamp");
    }

    // ── lead (3): an owner-timed dispose against an unpaid booking ───────────

    /// @notice NEGATIVE, green everywhere. Round-53 item 179 lead (3). A clean close books alice's
    ///         yield; the lot stays parked and keeps earning post-close padding as
    ///         `pendingYieldOf(auction)`; the owner then disposes the lot at the worst-looking
    ///         moment, mid-stream with bob's workout still open on the same position. `disposeTo`
    ///         settles the auction's position BEFORE the count moves, so the padding lands in
    ///         `claimableOf`, alice's booking stays backed, bob's open accrual is untouched, and
    ///         alice is paid in full afterwards.
    function test_R53A01_lead3_anOwnerTimedDisposeCannotUnbackAnUnpaidBooking() public {
        uint256 aliceId = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        uint256 a = _yieldOwed(aliceId);
        assertGt(a, 0);
        assertEq(credit.claimableOf(address(auction)), a, "fixture: the booking is settled and waiting");

        // Bob's workout opens on the same position; a second stream runs HALF way.
        uint256 bobId = _openWorkoutOn(credit, bob);
        _startStreamOn(credit, EPOCH);
        skip(Config.YIELD_STREAM_DURATION / 2);
        uint256 bobAccrualBefore = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        uint256 pendingBefore = credit.pendingYieldOf(address(auction));
        assertGt(pendingBefore, 0, "fixture: nothing unsettled at the moment of the dispose");

        // The owner disposes alice's lot mid-stream.
        vm.prank(admin);
        auction.disposeWorkoutLot(aliceId, alice);

        uint256 claimableAfter = credit.claimableOf(address(auction));
        emit log_named_uint("MEASURED alice booked                       ", a);
        emit log_named_uint("MEASURED pendingYieldOf(auction) before dispose", pendingBefore);
        emit log_named_uint("MEASURED claimableOf(auction) after dispose    ", claimableAfter);
        assertGe(claimableAfter, a + pendingBefore, "the dispose dropped the unsettled half on the floor");
        assertEq(_yieldOwed(aliceId), a, "the dispose touched the booking");
        assertEq(
            credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId)),
            bobAccrualBefore,
            "the dispose moved bob's open accrual"
        );

        // Finish the stream; alice is paid in full out of the realised pot with bob reserved.
        skip(Config.YIELD_STREAM_DURATION / 2 + 2);
        credit.accrueYield();
        uint256 before = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        assertEq(usdc.balanceOf(alice) - before, a, "alice was under-paid after the dispose");

        // Bob is still whole at his own close.
        uint256 bobEarned = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        _rescueDebt(bob);
        auction.closeWorkout(bobId);
        assertLe(bobEarned - _yieldOwed(bobId), 2, "bob's booking was clipped by the dispose");
    }

    // ── lead (4): a caught pull still reserves the live accrual ──────────────

    /// @notice MEASUREMENT, green everywhere, and it records an over-reservation. Round-53 item 179
    ///         lead (4). Alice's backing has already been pushed HERE (a stranger's
    ///         `claimSurplusFor(auction)`), bob's workout has since accrued B on the manager, and
    ///         then the manager cannot pay (blacklisted on USDC, so `claimSurplus` reverts and the
    ///         `try` catches it). `claimWorkoutYield` reserves `_openWorkoutAccrual(live)` = B
    ///         against a balance that holds NONE of B, so alice is paid `A - B` and the rest waits
    ///         until the pull succeeds. Recoverable (the block lifts, the pull lands, the remainder
    ///         pays), safe-side, and the same shape under both fix variants. MEASURED here so the
    ///         residual is a number rather than a sentence.
    function test_R53A01_lead4_aCaughtPullReservesAnOpenAccrualThatIsNotHere() public {
        uint256 aliceId = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        uint256 a = _yieldOwed(aliceId);
        vm.prank(admin);
        auction.disposeWorkoutLot(aliceId, alice);

        // Alice's backing is pushed onto the auction; the manager owes it nothing now.
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(usdc.balanceOf(address(auction)), a, "fixture: alice's backing is not here");
        assertEq(credit.claimableOf(address(auction)), 0, "fixture: the manager still owes something");

        // Bob's lot accrues B on the manager: a SMALLER epoch, so A > B and the partial payment is
        // visible rather than a bare NothingToClaim.
        uint256 bobId = _openWorkoutOn(credit, bob);
        _streamEpoch(EPOCH / 4);
        uint256 b = credit.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        assertGt(b, 0);
        assertLt(b, a, "fixture: B must be smaller than A");

        // The manager cannot pay: `_pushUsdc` reverts, `claimSurplus` reverts, the `try` catches it.
        usdc.setBlocked(address(credit), true);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        uint256 paid = usdc.balanceOf(alice) - before;
        emit log_named_uint("MEASURED alice booked (A), already on the auction", a);
        emit log_named_uint("MEASURED bob's open accrual (B), still on the manager", b);
        emit log_named_uint("MEASURED alice paid with the pull caught         ", paid);
        emit log_named_uint("MEASURED alice short by                          ", a - paid);
        assertEq(a - paid, b, "the caught pull did not reserve exactly the accrual that is not here");
        assertEq(_yieldOwed(aliceId), b, "the remainder is not recorded");

        // Recoverable: lift the block, claim again, the remainder pays out of the realised pull.
        usdc.setBlocked(address(credit), false);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        assertEq(usdc.balanceOf(alice) - before, a, "alice was not made whole once the pull landed");
        assertEq(_yieldOwed(aliceId), 0);
        // And bob's accrual is realised and reserved, not paid to alice.
        assertGe(usdc.balanceOf(address(auction)), b, "bob's backing was paid out to alice");
    }

    // ── lead (5): under C alice waits for `claimSurplusFor`; under A she does not ──

    /// @notice 🟥 **FIX-ASSERTING: RED at `a9ae1f4` by design, GREEN under variant C and variant A.**
    ///         Round-53 item 179 lead (5), executed rather than inferred. The round-53 item 178
    ///         sequence: alice books A on manager one, the protocol migrates, bob's lot earns X on
    ///         manager two and closes clean. Then alice claims FIRST, before anybody has pushed her
    ///         backing off the detached manager.
    ///
    ///         The test prints which of three things alice's first claim did - paid in full (variant
    ///         A: the bearer pull realises her own backing), refused `NothingToClaim` (variant C: bob's
    ///         realised X is reserved against a balance of X), or paid out of bob's pot (the shipped
    ///         tree, the finding) - and then asserts the property every fix must restore: once the
    ///         permissionless `claimSurplusFor(auction)` has run on the detached manager, BOTH
    ///         borrowers hold exactly what their lots earned. At the shipped tree that fails on bob.
    function test_R53A01_lead5_bothBorrowersArePaidInFullOnceTheDetachedBackingIsPushed() public {
        uint256 aliceId = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        uint256 a = _yieldOwed(aliceId);
        vm.prank(admin);
        auction.disposeWorkoutLot(aliceId, alice);

        CreditManager fresh = _migrate();
        assertEq(credit.claimableOf(address(auction)), a, "manager one holds alice's backing");
        assertEq(_bearer(aliceId), address(credit));

        uint256 bobId = _openWorkoutOn(fresh, bob);
        _streamEpochOn(fresh, EPOCH);
        uint256 bobEarned = fresh.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        _rescueDebtOn(fresh, bob);
        auction.closeWorkout(bobId);
        uint256 bobBooked = _yieldOwed(bobId);
        (bool split, uint256 onOne) = _splitOn(address(credit));
        emit log_named_string("variant mapping present", split ? "yes (C or A)" : "no (shipped tree)");
        if (split) {
            (, uint256 onTwo) = _splitOn(address(fresh));
            emit log_named_uint("MEASURED workoutYieldOwedOn[manager one]", onOne);
            emit log_named_uint("MEASURED workoutYieldOwedOn[manager two]", onTwo);
            assertEq(onOne + onTwo, auction.totalWorkoutYieldOwed(), "the split does not sum to the aggregate");
        }
        emit log_named_uint("MEASURED alice booked on manager one ", a);
        emit log_named_uint("MEASURED bob earned on manager two   ", bobEarned);
        emit log_named_uint("MEASURED bob booked                  ", bobBooked);

        // Alice's FIRST claim, before anybody pushes her backing.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(stranger);
        try auction.claimWorkoutYield(aliceId) {
            uint256 got = usdc.balanceOf(alice) - aliceBefore;
            emit log_named_uint("MEASURED alice's first claim PAID", got);
            if (credit.claimableOf(address(auction)) == 0) {
                emit log_string("  ... and her own backing on manager one is GONE: the bearer pull realised it (variant A)");
            } else {
                emit log_string("  ... while her own backing STILL sits on manager one: paid out of bob's pot (shipped tree)");
            }
        } catch (bytes memory err) {
            emit log_named_bytes("MEASURED alice's first claim REVERTED", err);
            assertEq(bytes4(err), LiquidationAuction.NothingToClaim.selector, "an unexpected revert");
            emit log_string("  ... NothingToClaim: bob's realised pot is reserved against a balance of the same size (variant C)");
        }

        // The permissionless door round 21 built. Reverts NothingToClaim if alice's claim already
        // pulled it (variant A), which is exactly the state that makes the call unnecessary.
        vm.prank(stranger);
        try credit.claimSurplusFor(address(auction)) {} catch {}

        vm.prank(stranger);
        try auction.claimWorkoutYield(aliceId) {} catch {}
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(stranger);
        auction.claimWorkoutYield(bobId);

        uint256 alicePaid = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobPaid = usdc.balanceOf(bob) - bobBefore;
        emit log_named_uint("MEASURED alice paid in total", alicePaid);
        emit log_named_uint("MEASURED bob paid in total  ", bobPaid);
        assertEq(alicePaid, a, "alice did not end up with her booking");
        assertEq(bobPaid, bobEarned, "bob did not end up with what his lot earned (the round-53 item 178 clamp)");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a booking survived both claims");
    }

    // ── incidental: blocking the AUCTION on USDC bricks the payout, not just the pull ──

    /// @notice NEGATIVE, green everywhere, recorded because lead (4)'s wording names "the auction
    ///         blocked on USDC" as a way the pull is caught. It is, and it is also the way the
    ///         PAYOUT reverts: the same blacklist stops `safeTransfer(w.borrower, pay)`, so a blocked
    ///         auction cannot under-pay anybody - it pays nobody, which is round-53 item 181's
    ///         `claimWorkoutYieldTo` question and not this lead's.
    function test_R53A01_negative_aBlockedAuctionRevertsTheClaimRatherThanUnderPayingIt() public {
        uint256 aliceId = _openWorkout(alice);
        _streamEpoch(EPOCH);
        _rescueDebt(alice);
        auction.closeWorkout(aliceId);
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        usdc.setBlocked(address(auction), true);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, address(auction)));
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
    }
}
