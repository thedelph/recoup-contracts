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

/// @title R54A01 - the workout lifecycle across a manager repoint, the deterministic leads
/// @notice Audit round 54, the companion of the repointing handler action added to
///         `LiquidationAuction.invariants.t.sol` (round-54 item 191). Self-contained: this file
///         deploys its own stack and inherits nothing from the repository's fixtures.
///
/// @dev Five leads, each executed rather than argued:
///      1. A migration BACK to a manager the vault has left is admissible only while that manager
///         is VIRGIN, and under it two bearers' bookings stay split and both borrowers are whole
///         (no double count).
///      2. Both repoint doors refuse while an auction is live and while a workout is open, and
///         since round 55 the vault's manager door also refuses over a CLOSED lot still parked
///         under the auction. The owner-gated disposal that clears it is the control.
///      3. That parked-lot repoint used to strand the post-close accrual on the detached manager.
///         Round 55's arm refuses it, and the disposal settles the accrual onto the outgoing
///         manager's own book. What survives is the READ: a detached manager's
///         `pendingYieldOf(auction)` still prices the vault's LIVE bond count against a frozen
///         accumulator, so it reads non-zero over an empty book. The booking itself was always
///         safe, because round 46 made `closeWorkout` settle before it books.
///      4. A bearer with NO CODE makes `claimWorkoutYield` revert in the auction's own frame; the
///         `try` does not see the EXTCODESIZE check. Unreachable through shipped code (the bearer
///         is always the manager that was live at the close), recorded as the SHAPE only.
///      5. A spare manager deployed in advance streams its first epoch over its whole shelf life,
///         round-54 item 70's drought re-rating on a fresh manager.
contract R54A01_RepointLeads is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
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
        credit = _newManager();
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

    // ── fixture helpers ──────────────────────────────────────────────────────

    function _newManager() internal returns (CreditManager m) {
        m = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
    }

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

    function _liquidate(CreditManager cm, address who) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(who);
        cm.borrow(debt);
        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);
        vm.prank(keeper);
        cm.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: no auction opened");
    }

    function _openWorkoutOn(CreditManager cm, address who) internal returns (uint256 id) {
        id = _liquidate(cm, who);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(who), 1, "fixture: no workout opened");
    }

    function _streamEpochOn(CreditManager cm, uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(cm), amount);
        cm.receiveYield(amount);
        cm.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION + 1);
        cm.accrueYield();
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

    /// @dev Clean close WITHOUT disposing the lot, so the parked lot can be the subject.
    function _closeCleanParked(CreditManager cm, address who) internal returns (uint256 id, uint256 booked) {
        id = _openWorkoutOn(cm, who);
        _streamEpochOn(cm, EPOCH);
        _rescueDebtOn(cm, who);
        auction.closeWorkout(id);
        booked = _yieldOwed(id);
        assertGt(booked, 0, "fixture: nothing booked");
    }

    function _dispose(uint256 id, address to) internal {
        vm.prank(admin);
        auction.disposeWorkoutLot(id, to);
    }

    function _wireFresh(CreditManager fresh) internal {
        TreasuryLiquiditySource freshTreasury = new TreasuryLiquiditySource(usdc, admin);
        usdc.mint(address(freshTreasury), TREASURY_FLOAT);
        vm.startPrank(admin);
        freshTreasury.setCreditManager(address(fresh));
        fresh.setLiquiditySource(address(freshTreasury));
        fresh.setEpochHarvester(harvester);
        fresh.setLiquidationAuction(address(auction));
        vm.stopPrank();
    }

    function _repoint(CreditManager target) internal {
        vm.startPrank(admin);
        vault.setCreditManager(address(target));
        auction.setCreditManager(address(target));
        vm.stopPrank();
        assertEq(vault.creditManager(), address(target), "fixture: vault not repointed");
        assertEq(auction.creditManager(), address(target), "fixture: auction not repointed");
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _bearer(uint256 id) internal view returns (address b) {
        (,,,,,,,, b,,) = auction.workouts(id);
    }

    function _claim(uint256 id, address who) internal returns (uint256 paid) {
        uint256 before = usdc.balanceOf(who);
        vm.prank(stranger);
        auction.claimWorkoutYield(id);
        paid = usdc.balanceOf(who) - before;
    }

    // ── 1. A migration BACK to a virgin manager ──────────────────────────────

    /// @notice NEGATIVE. The vault admits a return only to a manager that never distributed yield,
    ///         and under it nothing is counted twice: alice's booking stays split onto the manager
    ///         she closed on, bob's onto the one he closed on, each claim pulls its own bearer and
    ///         both are paid in full.
    function test_R54A01_lead1_aReturnToAVirginManagerDoublesNothing() public {
        // Manager one never distributes yield, so it stays virgin. Move to two before any epoch.
        CreditManager two = _newManager();
        _wireFresh(two);
        _repoint(two);
        assertEq(credit.accYieldPerBond(), 0, "fixture: manager one must be virgin");

        // Alice closes clean on two; her lot goes back to her so nothing pads the next era.
        (uint256 aliceId, uint256 aliceBooked) = _closeCleanParked(two, alice);
        _dispose(aliceId, alice);
        vm.prank(alice);
        vault.depositBonds(BONDS);
        assertEq(_bearer(aliceId), address(two));

        // Back to one: the vault allows it because one is virgin. Two is now non-virgin forever.
        _repoint(credit);
        assertEq(auction.workoutYieldOwedOn(address(two)), aliceBooked, "alice's split follows her bearer, not the pointer");
        assertEq(auction.workoutYieldOwedOn(address(credit)), 0);

        // Bob closes clean on one.
        (uint256 bobId, uint256 bobBooked) = _closeCleanParked(credit, bob);
        assertEq(_bearer(bobId), address(credit));
        assertEq(auction.workoutYieldOwedOn(address(credit)), bobBooked);
        assertEq(auction.totalWorkoutYieldOwed(), aliceBooked + bobBooked, "the split does not sum");

        // Round 55: bob's lot is still parked, and the vault's manager door now refuses on that
        // before the virgin arm is ever reached. Record the refusal in its own right, then dispose
        // the lot - which is the owner-gated call the refusal points at - so the assertion below
        // still measures the arm it was written for.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, BONDS));
        vault.setCreditManager(address(two));
        _dispose(bobId, bob);

        // And a return to two is refused: it distributed yield.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.CreditManagerNotVirgin.selector, address(two)));
        vault.setCreditManager(address(two));

        // Claims in the order that once misallocated: alice (detached bearer) first, then bob.
        assertEq(_claim(aliceId, alice), aliceBooked, "alice was not paid in full from her detached bearer");
        assertEq(two.claimableOf(address(auction)), 0, "her claim did not pull her own bearer");
        assertEq(_claim(bobId, bob), bobBooked, "bob was not paid in full from the live manager");
        assertEq(auction.totalWorkoutYieldOwed(), 0);
        assertEq(auction.workoutYieldOwedOn(address(two)) + auction.workoutYieldOwedOn(address(credit)), 0);
        assertEq(usdc.balanceOf(address(auction)), 0, "the auction holds USDC after both claims");
    }

    // ── 2. What the two doors refuse, and what they do not ──────────────────

    /// @notice MEASURED, and FLIPPED at round 55. Live auction: both doors refuse
    ///         `AuctionHasLiveWork`. Open workout: both refuse. Closed workout with its lot still
    ///         PARKED: the vault's manager door used to admit it, because its `heldLot` arm was on
    ///         `setLiquidationAuction` only and counting queue entries is not counting assets. It
    ///         now refuses, naming the lot - which is what lead 3 measures the value of - and the
    ///         owner-gated disposal that clears the refusal is the control at the end of this test.
    function test_R54A01_lead2_theDoorsRefuseLiveWorkAndAdmitAParkedClosedLot() public {
        CreditManager two = _newManager();
        _wireFresh(two);

        // Live auction: the vault refuses (debt first, then live work); the auction refuses.
        uint256 id = _liquidate(credit, alice);
        _rescueDebtOn(credit, alice); // clears the debt so the live-work arm is the one that fires
        assertEq(auction.liveAuctionCount(), 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, 1));
        vault.setCreditManager(address(two));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionHasLiveWork.selector, 1));
        auction.setCreditManager(address(two));

        // The healed position cancels; open a workout on bob instead.
        auction.cancel(id);
        uint256 bobId = _openWorkoutOn(credit, bob);
        _rescueDebtOn(credit, bob);
        assertEq(auction.openWorkoutCount(), 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, 1));
        vault.setCreditManager(address(two));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionHasLiveWork.selector, 1));
        auction.setCreditManager(address(two));

        // Closed, lot parked. Round 55: the vault's manager door refuses this too, by amount.
        auction.closeWorkout(bobId);
        assertEq(vault.bondCount(address(auction)), BONDS, "fixture: the closed lot is still parked");
        assertEq(auction.liveAuctionCount(), 0, "fixture: the queue counters both read zero over it");
        assertEq(auction.openWorkoutCount(), 0, "fixture: and so does the other one");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, BONDS));
        vault.setCreditManager(address(two));
        assertEq(vault.creditManager(), address(credit), "the vault did not move");

        // CONTROL, and the deadlock check the new arm owes: the disposal that clears the refusal is
        // `onlyOwner` and reachable in exactly the refused state, and once the lot is gone the pair
        // moves together. The arm forbids nothing that was reachable before it.
        _dispose(bobId, bob);
        assertEq(vault.bondCount(address(auction)), 0, "the lot left the ledger");
        _repoint(two);
    }

    // ── 3. The detached manager's phantom pending ────────────────────────────

    /// @notice MEASURED, and RE-ESTABLISHED at round 55, because the arm this round put on
    ///         `CollateralVault.setCreditManager` closes the half of this lead that cost money.
    ///         Alice closes clean on one, her lot stays parked, and a second epoch streams: that
    ///         post-close accrual is the insurance fund's, and it used to strand on the detached
    ///         manager. The vault's manager door now REFUSES the repoint while the lot is parked,
    ///         and the owner-gated disposal that clears the refusal SETTLES the accrual onto
    ///         manager one's own book, where `claimSurplusFor` reaches it. Measured here rather
    ///         than argued.
    ///
    ///         What survives the arm is a pure READ artefact, kept in this file so nobody re-finds
    ///         it as a loss: a detached manager still prices `pendingYieldOf` off the vault's LIVE
    ///         bond count against its own frozen accumulator, so once a later lot parks under the
    ///         auction on two, manager one reads non-zero again - over a book that is already
    ///         empty, and with `settle` reverting `Detached`. The booking itself was never at risk
    ///         (round 46's settle-before-book) and alice is paid in full either way.
    function test_R54A01_lead3_aDetachedManagersPendingIsAPhantomAndTheBookingIsNot() public {
        (uint256 aliceId, uint256 aliceBooked) = _closeCleanParked(credit, alice);
        assertEq(credit.claimableOf(address(auction)), aliceBooked, "the close settled the booking into claimable");
        assertEq(credit.pendingYieldOf(address(auction)), 0, "nothing pending at the close");

        // A second epoch streams while the lot is still parked: post-close accrual, unbooked.
        _streamEpochOn(credit, EPOCH);
        uint256 postClosePending = credit.pendingYieldOf(address(auction));
        assertGt(postClosePending, 0, "fixture: the parked lot keeps earning after the close");
        emit log_named_uint("MEASURED post-close accrual pending on manager one at the repoint", postClosePending);

        CreditManager two = _newManager();
        _wireFresh(two);

        // ROUND 55, and the reason this lead was re-established rather than deleted. The repoint
        // that used to strand the accrual above is refused, by name and by the amount parked.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, BONDS));
        vault.setCreditManager(address(two));

        // The disposal the refusal points at settles that accrual onto manager one's OWN book,
        // which is the whole value of the arm: claimable rather than stranded behind a detached
        // pointer. This is the assertion the round-54 version of this test could not make.
        _dispose(aliceId, alice);
        assertEq(credit.pendingYieldOf(address(auction)), 0, "the disposal settled the parked accrual");
        assertEq(
            credit.claimableOf(address(auction)),
            aliceBooked + postClosePending,
            "the post-close accrual is on the book rather than behind a detached pointer"
        );

        // One more epoch streams on manager one while the auction holds nothing. Its accumulator
        // moves past the index the disposal stamped, and the auction is owed nothing by it.
        _streamEpochOn(credit, EPOCH);
        assertEq(credit.pendingYieldOf(address(auction)), 0, "the auction holds no bonds, so it earns nothing");

        _repoint(two);

        // What survives the arm is the READ. A detached manager prices the vault's LIVE bond count
        // against its own frozen accumulator, so a lot parked under the auction on TWO makes ONE
        // read non-zero again.
        uint256 bobId = _openWorkoutOn(two, bob);
        assertEq(vault.bondCount(address(auction)), BONDS, "fixture: bob's lot is parked under the auction on two");
        uint256 phantom = credit.pendingYieldOf(address(auction));
        emit log_named_uint("MEASURED the surviving phantom READ on the detached manager one", phantom);
        assertGt(phantom, 0, "the detached manager prices a lot it never governed");

        // And there is nothing behind it: the pull moves the whole book - alice's booking plus the
        // accrual the disposal rescued - and leaves the phantom exactly where it was.
        uint256 held = usdc.balanceOf(address(auction));
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(
            usdc.balanceOf(address(auction)) - held,
            aliceBooked + postClosePending,
            "the pull moved the whole book, booking and rescued accrual together"
        );
        assertEq(credit.pendingYieldOf(address(auction)), phantom, "the pull did not touch the phantom");
        vm.expectRevert(abi.encodeWithSelector(CreditManager.Detached.selector, address(two)));
        credit.settle(address(auction));

        // Alice is whole; the phantom still reaches nobody, which is now all it can cost.
        assertEq(_claim(aliceId, alice), aliceBooked, "alice was not paid her booking in full");
        assertEq(auction.workoutsOpenFor(bob), 1);
        assertEq(bobId != 0, true);
    }

    // ── 4. A bearer with no code ─────────────────────────────────────────────

    /// @notice SHAPE ONLY, unreachable through shipped code. `w.bearer` is written from the live
    ///         `creditManager` at the close and a live manager has code. If it ever did not, the
    ///         `try ICreditManager(bearer).claimSurplus()` would not catch anything: solc's
    ///         EXTCODESIZE check runs in the AUCTION's frame before the call, and its revert takes
    ///         the whole claim with it. So a codeless bearer is a bricked claim, not an under-paid
    ///         one - the opposite of round-54 item 192's caught-pull shape.
    function test_R54A01_lead4_aCodelessBearerBricksTheClaimRatherThanUnderPayingIt() public {
        (uint256 aliceId, uint256 aliceBooked) = _closeCleanParked(credit, alice);
        _dispose(aliceId, alice);
        CreditManager two = _newManager();
        _wireFresh(two);
        _repoint(two);
        assertEq(_bearer(aliceId), address(credit));
        assertGt(aliceBooked, 0);

        // Strip the bearer's code. Nothing in the protocol can do this; it is the probe.
        vm.etch(address(credit), "");
        assertEq(address(credit).code.length, 0, "fixture: the bearer is codeless");

        vm.prank(stranger);
        vm.expectRevert();
        auction.claimWorkoutYield(aliceId);
        assertEq(_yieldOwed(aliceId), aliceBooked, "the booking is untouched by the refused claim");
    }

    // ── 5. A spare deployed in advance ───────────────────────────────────────

    /// @notice MEASURED. `distributeYield` sizes a stream as
    ///         `max(elapsed since lastDistributeAt, YIELD_STREAM_DURATION, remaining)`, and the
    ///         constructor stamps `lastDistributeAt` at deployment. So a manager deployed `shelf`
    ///         seconds before its first epoch streams that epoch over `shelf`, not over five days.
    ///         Round-54 item 70's drought re-rating, on a manager that never had a stream to be in
    ///         drought from. Reported for the record; the deploy path wires in one session.
    function test_R54A01_lead5_aSpareDeployedInAdvanceStreamsItsFirstEpochOverItsShelfLife() public {
        CreditManager two = _newManager();
        _wireFresh(two);
        uint256 shelf = 45 days;
        skip(shelf);
        _repoint(two);

        usdc.mint(harvester, EPOCH);
        vm.startPrank(harvester);
        usdc.approve(address(two), EPOCH);
        two.receiveYield(EPOCH);
        two.distributeYield(EPOCH);
        vm.stopPrank();
        uint256 duration = two.streamEndsAt() - block.timestamp;
        emit log_named_uint("MEASURED first stream duration on a 45-day-old spare, seconds", duration);
        assertEq(duration, shelf, "the first epoch streams over the shelf life, not YIELD_STREAM_DURATION");
        assertGt(duration, Config.YIELD_STREAM_DURATION, "and that is longer than a stream");
    }
}
