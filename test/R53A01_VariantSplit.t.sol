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

/// @title R53A01 - what the `workoutYieldOwedOn` split of round-53 item 178 does and costs
/// @notice Audit round 53. Self-contained, same stack as `R53A01_AuctionLeads.t.sol`.
///
/// @dev The subject is the fix Chris authorised for this round's wave (variant A: a per-bearer
///      split of `totalWorkoutYieldOwed`, the other bookings reserved in `claimWorkoutYield`, and a
///      pull from the recorded `bearer` when it is not the live manager) and its smaller sibling
///      (variant C, the split without the bearer pull). The mapping is probed by selector, which
///      let this file compile at the pre-fix tree `a9ae1f4` while it was a PoC; there the two
///      variant-only tests SKIPPED. **Promoted to a regression suite by round 53's contracts wave,
///      which ships variant A**: the probe now ASSERTS the mapping is present, so a tree that loses
///      it goes red here rather than skipping. "Shipped tree" below means `a9ae1f4`, before the fix.
///
///      Three tests:
///      1. a deterministic TRIPWIRE for the new mapping - the per-bearer entries sum to the
///         aggregate through three eras and drain to zero;
///      2. the residual both variants carry (round-53 item 178's row names it): a booking on a
///         THIRD detached bearer that nobody has pulled is over-reserved until it is pulled, and
///         `sweepFreeBalanceToInsurance` refuses throughout;
///      3. the one thing the split CHANGES that the round-52 report did not name: `closeWorkout`'s
///         clamp no longer nets a foreign bearer's booking off the balance, so backing that was
///         pushed here from a detached manager backs the NEXT clean close as though it were a
///         donation. Only the settle grind can make a lot's `earned` exceed its own pot, so the
///         exposure is dust; measured rather than argued, on all three trees.
contract R53A01_VariantSplit is Test {
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

    // ── fixture helpers ──────────────────────────────────────────────────────

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
    }

    function _startStreamOn(CreditManager cm, uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(cm), amount);
        cm.receiveYield(amount);
        cm.distributeYield(amount);
        vm.stopPrank();
    }

    function _streamEpochOn(CreditManager cm, uint256 amount) internal {
        _startStreamOn(cm, amount);
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

    /// @dev One whole era on `cm`: `who`'s workout, one epoch of `amount`, a clean close, the lot
    ///      disposed so it does not pad the next era's pot. Returns the id and the booking.
    function _era(CreditManager cm, address who, uint256 amount) internal returns (uint256 id, uint256 booked) {
        id = _openWorkoutOn(cm, who);
        _streamEpochOn(cm, amount);
        _rescueDebtOn(cm, who);
        auction.closeWorkout(id);
        booked = _yieldOwed(id);
        assertGt(booked, 0, "fixture: nothing booked");
        vm.prank(admin);
        auction.disposeWorkoutLot(id, who);
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _yieldIndexAtOpen(uint256 id) internal view returns (uint256 idx) {
        (,,,,,,,,, idx,) = auction.workouts(id);
    }

    function _pot(CreditManager cm) internal view returns (uint256) {
        return cm.claimableOf(address(auction)) + cm.pendingYieldOf(address(auction));
    }

    function _splitOn(address cm) internal view returns (bool present, uint256 value) {
        (bool ok, bytes memory ret) =
            address(auction).staticcall(abi.encodeWithSignature("workoutYieldOwedOn(address)", cm));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev Was a `vm.skip(true)` while this file was a PoC at the pre-fix tree; round 53's wave
    ///      promoted it and the tree ships the mapping, so its absence is now a failure.
    function _requireSplit() internal view {
        (bool present,) = _splitOn(address(credit));
        assertTrue(present, "workoutYieldOwedOn(address) is not on this tree: the round-53 item 178 split is gone");
    }

    // ── 1. tripwire for the new mapping ──────────────────────────────────────

    /// @notice TRIPWIRE (skipped at the pre-fix tree; asserts here). Through three eras on three
    ///         managers the per-bearer entries equal each bearer's booking and sum to the aggregate;
    ///         every claim decrements the entry of the BEARER (`w.bearer`, written on both branches
    ///         of `closeWorkout`), never the live manager's; everything drains to zero.
    function test_R53A01_split_theLedgerSumsToTheAggregateAcrossThreeBearersAndDrainsToZero() public {
        _requireSplit();
        (uint256 aliceId, uint256 a) = _era(credit, alice, EPOCH);
        CreditManager two = _migrate();
        (uint256 bobId, uint256 b) = _era(two, bob, EPOCH);
        CreditManager three = _migrate();
        _seed(carol, BONDS);
        (uint256 carolId, uint256 c) = _era(three, carol, EPOCH);

        (, uint256 onOne) = _splitOn(address(credit));
        (, uint256 onTwo) = _splitOn(address(two));
        (, uint256 onThree) = _splitOn(address(three));
        emit log_named_uint("MEASURED on manager one  ", onOne);
        emit log_named_uint("MEASURED on manager two  ", onTwo);
        emit log_named_uint("MEASURED on manager three", onThree);
        emit log_named_uint("MEASURED aggregate        ", auction.totalWorkoutYieldOwed());
        assertEq(onOne, a, "manager one's entry is not alice's booking");
        assertEq(onTwo, b, "manager two's entry is not bob's booking");
        assertEq(onThree, c, "manager three's entry is not carol's booking");
        assertEq(onOne + onTwo + onThree, auction.totalWorkoutYieldOwed(), "the split does not sum to the aggregate");

        // Push the two detached backings (variant C needs this; variant A does not, and then the
        // push reverts NothingToClaim because the claim already pulled it - either is fine).
        vm.prank(stranger);
        try credit.claimSurplusFor(address(auction)) {} catch {}
        vm.prank(stranger);
        try two.claimSurplusFor(address(auction)) {} catch {}

        vm.prank(stranger);
        auction.claimWorkoutYield(carolId);
        (, onThree) = _splitOn(address(three));
        (, onTwo) = _splitOn(address(two));
        assertEq(onThree, 0, "carol's claim did not decrement HER bearer's entry");
        assertEq(onTwo, b, "carol's claim decremented somebody else's entry");

        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        vm.prank(stranger);
        auction.claimWorkoutYield(bobId);
        (, onOne) = _splitOn(address(credit));
        (, onTwo) = _splitOn(address(two));
        assertEq(onOne + onTwo + onThree, 0, "an entry survived its claim");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "the aggregate survived the claims");
    }

    // ── 2. the residual both variants carry: a third detached bearer ─────────

    /// @notice MEASUREMENT (skipped at the pre-fix tree; asserts here). Alice books A on manager
    ///         one, bob books B > A on manager two, the protocol migrates to manager three, and
    ///         NOBODY has pulled manager one. Bob
    ///         claims: under variant A the bearer pull realises B, the reserve holds alice's A
    ///         against a balance that holds none of it, and bob is paid `B - A`; under variant C
    ///         there is no bearer pull and bob's claim reverts `NothingToClaim`. Either way
    ///         `sweepFreeBalanceToInsurance` refuses throughout (the safe direction), one
    ///         permissionless `claimSurplusFor(auction)` on manager one unwinds it, and both are
    ///         then paid in full. The over-reservation is round-53 item 178's stated residual;
    ///         this puts a number on it and shows the sweep cannot take the difference.
    function test_R53A01_split_aThirdDetachedBearerOverReservesUntilItIsPulled() public {
        _requireSplit();
        (uint256 aliceId, uint256 a) = _era(credit, alice, EPOCH / 2);
        CreditManager two = _migrate();
        (uint256 bobId, uint256 b) = _era(two, bob, EPOCH);
        assertGt(b, a, "fixture: B must exceed A for the partial payment to be visible");
        CreditManager three = _migrate();
        assertEq(credit.claimableOf(address(auction)), a, "fixture: manager one still holds A");
        assertEq(two.claimableOf(address(auction)), b, "fixture: manager two still holds B");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(stranger);
        try auction.claimWorkoutYield(bobId) {
            uint256 paid = usdc.balanceOf(bob) - bobBefore;
            emit log_named_uint("MEASURED bob's booking (B) on manager two ", b);
            emit log_named_uint("MEASURED alice's booking (A) on manager one, unpulled", a);
            emit log_named_uint("MEASURED bob paid on his first claim      ", paid);
            emit log_named_uint("MEASURED bob short by (A, the over-reservation)", b - paid);
            assertEq(b - paid, a, "the over-reservation is not exactly the unpulled booking (variant A)");
            assertEq(two.claimableOf(address(auction)), 0, "the bearer pull did not run (variant A)");
        } catch (bytes memory err) {
            assertEq(bytes4(err), LiquidationAuction.NothingToClaim.selector, "an unexpected revert");
            emit log_string("MEASURED bob's first claim reverted NothingToClaim: no bearer pull on this tree (variant C)");
            assertEq(two.claimableOf(address(auction)), b, "manager two was pulled after all");
        }

        // The sweep cannot take the difference: the reserve holds it.
        vm.prank(stranger);
        try auction.sweepFreeBalanceToInsurance() {
            fail("the free-balance sweep moved money while a booking stood unpaid");
        } catch (bytes memory err) {
            assertEq(bytes4(err), LiquidationAuction.NothingUnreserved.selector, "the sweep refused for the wrong reason");
        }
        assertEq(three.insuranceFund(), 0, "insurance received something");

        // The permissionless door unwinds it.
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        vm.prank(stranger);
        try two.claimSurplusFor(address(auction)) {} catch {}
        vm.prank(stranger);
        auction.claimWorkoutYield(bobId);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(stranger);
        auction.claimWorkoutYield(aliceId);
        assertEq(usdc.balanceOf(bob) - bobBefore, b, "bob was not made whole");
        assertEq(usdc.balanceOf(alice) - aliceBefore, a, "alice was not made whole");
        assertEq(auction.totalWorkoutYieldOwed(), 0);
    }

    // ── 3. what the split changes in the clamp: foreign backing reads as a donation ──

    /// @notice MEASUREMENT on every tree. Alice's booking A is made on manager one, the protocol
    ///         migrates, and a stranger PUSHES A here with `claimSurplusFor(auction)` before bob's
    ///         era on manager two. Bob's lot is ground by hourly settles, so its `earned` exceeds
    ///         manager two's pot by up to one wei per settle. At the close:
    ///
    ///         - shipped tree: `spokenFor` nets alice's A off `reachable` (which holds it), so bob
    ///           is booked `min(earned, pot)` and the grind is absorbed by his booking;
    ///         - under the split: `spokenFor` is `workoutYieldOwedOn[two]` = 0, alice's A stays in
    ///           `reachable` as though it were a donation, bob is booked `earned`, and the excess
    ///           over the pot is paid out of alice's A. Alice's later claim reserves bob's booking
    ///           and comes up short by the grind; bob's claim then reserves alice's remainder and
    ///           comes up short by the same amount; the two dust bookings stand until any later
    ///           unbooked money arrives here.
    ///
    ///         Dust by construction (only the grind can make `earned` exceed the lot's own pot),
    ///         measured so the split's one cost has a number beside it. Both branches assert.
    function test_R53A01_split_pushedForeignBackingBacksTheNextCloseLikeADonation() public {
        (uint256 aliceId, uint256 a) = _era(credit, alice, EPOCH);
        CreditManager two = _migrate();
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(usdc.balanceOf(address(auction)), a, "fixture: alice's backing is not here");

        _seed(carol, DILUTION_BONDS);
        uint256 bobId = _openWorkoutOn(two, bob);
        _startStreamOn(two, EPOCH);
        uint256 settles;
        for (uint256 t = 1 hours; t <= Config.YIELD_STREAM_DURATION; t += 1 hours) {
            skip(1 hours);
            vm.prank(stranger);
            two.settle(address(auction));
            settles++;
        }
        skip(1);
        two.accrueYield();
        uint256 earned = two.yieldAccruedOn(BONDS, _yieldIndexAtOpen(bobId));
        uint256 pot = _pot(two);
        _rescueDebtOn(two, bob);
        auction.closeWorkout(bobId);
        uint256 booked = _yieldOwed(bobId);
        uint256 grind = earned > pot ? earned - pot : 0;

        (bool split,) = _splitOn(address(credit));
        emit log_named_string("tree", split ? "split present (variant C or A)" : "shipped a9ae1f4");
        emit log_named_uint("MEASURED settles ground on bob's position", settles);
        emit log_named_uint("MEASURED bob earned (one floor)          ", earned);
        emit log_named_uint("MEASURED manager two's pot for bob       ", pot);
        emit log_named_uint("MEASURED earned - pot (the grind)        ", grind);
        emit log_named_uint("MEASURED bob booked                      ", booked);
        assertGt(grind, 0, "fixture: the grind produced no gap, nothing to measure");

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(stranger);
        try auction.claimWorkoutYield(aliceId) {} catch {}
        vm.prank(stranger);
        try auction.claimWorkoutYield(bobId) {} catch {}
        uint256 alicePaid = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobPaid = usdc.balanceOf(bob) - bobBefore;
        emit log_named_uint("MEASURED alice paid                      ", alicePaid);
        emit log_named_uint("MEASURED alice short by                  ", a - alicePaid);
        emit log_named_uint("MEASURED bob paid                        ", bobPaid);
        emit log_named_uint("MEASURED bob short of his booking by     ", booked - bobPaid);
        emit log_named_uint("MEASURED bookings still standing         ", auction.totalWorkoutYieldOwed());

        if (!split) {
            assertEq(booked, pot, "shipped tree: the clamp did not absorb the grind into bob's booking");
            assertEq(alicePaid, a, "shipped tree: alice was short");
            assertEq(bobPaid, booked, "shipped tree: bob was short of his booking");
            assertEq(auction.totalWorkoutYieldOwed(), 0, "shipped tree: a booking stood");
        } else {
            assertEq(booked, earned, "split: bob was clamped after all");
            assertEq(a - alicePaid, grind, "split: alice's shortfall is not the grind");
            assertEq(booked - bobPaid, grind, "split: bob's shortfall is not the grind");
            assertEq(auction.totalWorkoutYieldOwed(), 2 * grind, "split: the standing dust is not two grinds");
            // The two dust bookings deadlock each other until any later unbooked money arrives.
            vm.prank(stranger);
            vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
            auction.claimWorkoutYield(aliceId);
            // And the sweep is refused over them (the safe direction).
            vm.prank(stranger);
            vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
            auction.sweepFreeBalanceToInsurance();
        }
    }
}
