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

/// @title R56A02 - round-56 item 81: does `sweepWorkoutYieldToInsurance` defeat round-22 finding 18?
/// @notice Audit round 56, agent A2. Self-contained: deploys its own stack and inherits no fixture, so
///         no shipped campaign rides along with it.
///
///         THE LEAD (round-46 agents 04 L2 and 03 L2, carried unexecuted from round 47 to round 56):
///         "`sweepWorkoutYieldToInsurance` appears to defeat round-22 finding 18 for gas, and there is
///         a dead `NothingToClaim` line beside it". Finding 18's bound is that a clean workout close
///         books the lot's accrual to the borrower, clamped by money that exists, net of what is
///         already spoken for; "the same money counted twice from the other end" would be a sweep
///         funding insurance with money the close later books (or has booked).
///
///         THE ANSWER, by execution: a depth-3 exhaustive walk over eleven actions (every
///         permissionless door onto the auction's yield plus time, epochs, donations, a sibling's
///         clean close, forced close and disposal) from a state with two open workouts and a third
///         ordinary staker. For every one of the 1,331 sequences the target workout is then closed
///         clean and every booking is claimed. See `test_R56A02_81_negative_exhaustiveDepth3` for
///         the measured envelope.
///
///         The dead line: `if (swept == 0) revert NothingToClaim();` was deleted by round 51
///         (#454, `8b5fdfe`, item 155). The two `NothingToClaim` lines that remain in the auction's
///         workout-yield doors are both in `claimWorkoutYield`, and both are REACHED here.
contract R56A02_SweepVersusF18 is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 1_000_000e6;
    uint256 internal constant EPOCH = 1_000e6;
    uint256 internal constant ACTIONS = 11;

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

    uint256 internal aliceId;
    uint256 internal bobId;

    // Envelope, written by `_runSequence` and read by the walk.
    uint256 internal maxShortfallA;
    uint256 internal maxUnpaidA;
    uint256 internal maxUnpaidB;
    uint256 internal maxBackingDeficit;
    uint256 internal sweepsThatMoved;
    uint256 internal sequencesWithBobBooked;
    uint256 internal sequencesWithSweepBeforeClose;

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

        _seed(alice);
        _seed(bob);
        _seed(carol);

        aliceId = _openWorkout(alice);
        bobId = _openWorkout(bob);

        // One epoch delivered and HALF streamed, so every sequence starts with realised and
        // still-streaming yield under both open lots and under carol's ordinary position.
        _deliverEpoch(EPOCH);
        skip(Config.YIELD_STREAM_DURATION / 2);
    }

    // ── fixture helpers ──────────────────────────────────────────────────────

    function _seed(address who) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _openWorkout(address who) internal returns (uint256 id) {
        uint256 nav = oracle.navPerBond();
        uint256 debt = (BONDS * nav * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        vm.prank(who);
        credit.borrow(debt);
        uint256 restore = oracle.navPerBond();
        oracle.setNav(((debt * Config.USDC_TO_NAV_SCALE) / BONDS) / 2);
        vm.prank(keeper);
        credit.liquidate(who);
        id = auction.auctionOf(who);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        oracle.setNav(restore);
        require(auction.workoutsOpenFor(who) == 1, "fixture: no workout");
    }

    function _deliverEpoch(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
    }

    function _rescue(address who) internal {
        uint256 owed = credit.debtOf(who);
        if (owed == 0) return;
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(credit), owed);
        credit.repayFor(who, owed);
        vm.stopPrank();
    }

    function _terms(uint256 id)
        internal
        view
        returns (LiquidationAuction.WorkoutStatus status, uint256 bonds, uint256 index, uint256 owed)
    {
        (,, status, bonds,,,,,, index, owed) = auction.workouts(id);
    }

    /// @dev Restated from the public queue, not read out of the reserve under test.
    function _openAccrual() internal view returns (uint256 total) {
        uint256 n = auction.openWorkoutCount();
        for (uint256 i = 0; i < n; ++i) {
            (, uint256 b, uint256 idx,) = _terms(auction.openWorkoutAt(i));
            total += credit.yieldAccruedOn(b, idx);
        }
    }

    /// @dev What the auction can still reach, against what it is holding for named parties
    ///      (callers' rewards, booked clean-close yield, and every open lot's accrual). A sweep
    ///      that counted booked or open money as free would open a deficit here.
    function _backingDeficit() internal view returns (uint256) {
        uint256 backing = usdc.balanceOf(address(auction)) + credit.claimableOf(address(auction))
            + credit.pendingYieldOf(address(auction));
        uint256 owed = auction.totalUnclaimedRewards() + auction.totalWorkoutYieldOwed() + _openAccrual();
        return owed > backing ? owed - backing : 0;
    }

    // ── the action alphabet ──────────────────────────────────────────────────

    function _act(uint256 a) internal returns (bool moved) {
        if (a == 0) {
            uint256 ins = credit.insuranceFund();
            vm.prank(stranger);
            try auction.sweepWorkoutYieldToInsurance() {} catch {}
            moved = credit.insuranceFund() != ins;
        } else if (a == 1) {
            uint256 ins = credit.insuranceFund();
            vm.prank(stranger);
            try auction.sweepFreeBalanceToInsurance() {} catch {}
            moved = credit.insuranceFund() != ins;
        } else if (a == 2) {
            vm.prank(stranger);
            try credit.claimSurplusFor(address(auction)) {} catch {}
        } else if (a == 3) {
            vm.prank(stranger);
            try credit.settle(address(auction)) {} catch {}
        } else if (a == 4) {
            skip(1 days);
        } else if (a == 5) {
            (LiquidationAuction.WorkoutStatus s,,,) = _terms(bobId);
            if (s == LiquidationAuction.WorkoutStatus.Open) {
                _rescue(bob);
                vm.prank(stranger);
                auction.closeWorkout(bobId);
            }
        } else if (a == 6) {
            vm.prank(stranger);
            try auction.claimWorkoutYield(bobId) {} catch {}
        } else if (a == 7) {
            usdc.mint(address(auction), 1e6);
        } else if (a == 8) {
            _deliverEpoch(EPOCH);
        } else if (a == 9) {
            (LiquidationAuction.WorkoutStatus s,,,) = _terms(bobId);
            if (s == LiquidationAuction.WorkoutStatus.Open) {
                skip(Config.WORKOUT_MAX_DURATION);
                vm.prank(stranger);
                auction.closeWorkout(bobId);
            }
        } else if (a == 10) {
            (LiquidationAuction.WorkoutStatus s, uint256 b,,) = _terms(bobId);
            if (s == LiquidationAuction.WorkoutStatus.Closed && b != 0) {
                bond.setWhitelisted(bob, true);
                vm.prank(admin);
                auction.disposeWorkoutLot(bobId, bob);
            }
        }
    }

    /// @dev Replay `seq` from the snapshot, then close alice cleanly, claim every booking, and
    ///      fold the outcome into the envelope. Returns alice's shortfall against her uncapped
    ///      accrual at the close.
    function _runSequence(uint256[] memory seq) internal returns (uint256 shortfallA) {
        bool sweptBefore;
        for (uint256 i = 0; i < seq.length; ++i) {
            bool moved = _act(seq[i]);
            if (moved) {
                sweepsThatMoved++;
                sweptBefore = true;
            }
            uint256 d = _backingDeficit();
            if (d > maxBackingDeficit) maxBackingDeficit = d;
        }
        if (sweptBefore) sequencesWithSweepBeforeClose++;

        _rescue(alice);
        (, uint256 bA, uint256 iA,) = _terms(aliceId);
        uint256 earnedA = credit.yieldAccruedOn(bA, iA);
        vm.prank(stranger);
        auction.closeWorkout(aliceId);
        (,,, uint256 bookedA) = _terms(aliceId);
        shortfallA = earnedA > bookedA ? earnedA - bookedA : 0;
        if (shortfallA > maxShortfallA) maxShortfallA = shortfallA;

        // Claim alice.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(stranger);
        try auction.claimWorkoutYield(aliceId) {} catch {}
        uint256 paidA = usdc.balanceOf(alice) - before;
        uint256 unpaidA = bookedA - paidA;
        if (unpaidA > maxUnpaidA) maxUnpaidA = unpaidA;

        // Claim bob, if he was booked and not yet fully paid.
        (,,, uint256 owedB) = _terms(bobId);
        if (owedB != 0) {
            sequencesWithBobBooked++;
            before = usdc.balanceOf(bob);
            vm.prank(stranger);
            try auction.claimWorkoutYield(bobId) {} catch {}
            uint256 paidB = usdc.balanceOf(bob) - before;
            if (owedB - paidB > maxUnpaidB) maxUnpaidB = owedB - paidB;
        }

        uint256 d2 = _backingDeficit();
        if (d2 > maxBackingDeficit) maxBackingDeficit = d2;
    }

    // ── CONTROL ──────────────────────────────────────────────────────────────

    /// @notice CONTROL. No action between the snapshot and alice's clean close: she is booked her
    ///         lot's whole accrual (the uncapped `yieldAccruedOn` figure) and paid it in full.
    function test_R56A02_81_control_noActionBooksAndPaysTheWholeAccrual() public {
        uint256[] memory none = new uint256[](0);
        uint256 shortfall = _runSequence(none);
        (,,, uint256 left) = _terms(aliceId);
        emit log_named_uint("CONTROL alice shortfall against her accrual", shortfall);
        assertEq(shortfall, 0, "control: alice was not booked her whole accrual");
        assertEq(maxUnpaidA, 0, "control: alice was not paid in full");
        assertEq(left, 0, "control: a booking was left standing");
    }

    /// @notice CONTROL for the lead's own door. `sweepWorkoutYieldToInsurance` mid-workout MOVES
    ///         money (so it is not inert here), and alice is still booked and paid her whole accrual.
    ///         At round 46 (`8631498`, before round 51's open-accrual reserve) this sequence is the
    ///         one that took the open lot's accrual to insurance; it is the lead as filed.
    function test_R56A02_81_control_theSweepMovesAndTheBookingIsWhole() public {
        // A donation, so the sweep has something genuinely free to take and is observed MOVING.
        usdc.mint(address(auction), 7e6);
        uint256 ins = credit.insuranceFund();
        vm.prank(stranger);
        auction.sweepWorkoutYieldToInsurance();
        uint256 swept = credit.insuranceFund() - ins;
        emit log_named_uint("MEASURED swept to insurance mid-workout", swept);
        assertGe(swept, 7e6, "the sweep did not move the free donation");
        // It moved only what is free: the donation plus unattributed dust, never the open lots.
        assertLe(swept, 7e6 + 10, "the sweep took more than the donation plus rounding dust");

        uint256[] memory none = new uint256[](0);
        uint256 shortfall = _runSequence(none);
        emit log_named_uint("MEASURED alice shortfall after the sweep", shortfall);
        assertEq(shortfall, 0, "the sweep took alice's accrual: finding 18 defeated");
        assertEq(maxUnpaidA, 0, "alice was not paid in full after the sweep");
    }

    // ── NEGATIVE: the exhaustive walk ────────────────────────────────────────

    /// @dev One slice of the depth-3 exhaustive walk: every sequence whose FIRST action is `i`
    ///      (121 of the 1,331). Split eleven ways only because one test cannot hold the gas.
    function _walk(uint256 i) internal {
        uint256 snap = vm.snapshotState();
        uint256[] memory seq = new uint256[](3);
        uint256 n;
        uint256 worstSeq;
        uint256 worst;
        for (uint256 j = 0; j < ACTIONS; ++j) {
            for (uint256 k = 0; k < ACTIONS; ++k) {
                // The envelope lives in storage and the revert would erase it, so carry it.
                uint256[7] memory env = [
                    maxShortfallA, maxUnpaidA, maxUnpaidB, maxBackingDeficit, sweepsThatMoved,
                    sequencesWithBobBooked, sequencesWithSweepBeforeClose
                ];
                vm.revertToState(snap);
                (maxShortfallA, maxUnpaidA, maxUnpaidB, maxBackingDeficit) = (env[0], env[1], env[2], env[3]);
                (sweepsThatMoved, sequencesWithBobBooked, sequencesWithSweepBeforeClose) = (env[4], env[5], env[6]);
                seq[0] = i;
                seq[1] = j;
                seq[2] = k;
                uint256 s = _runSequence(seq);
                if (s > worst) {
                    worst = s;
                    worstSeq = i * 100 + j * 10 + k;
                }
                n++;
            }
        }
        emit log_named_uint("MEASURED first action", i);
        emit log_named_uint("MEASURED sequences walked", n);
        emit log_named_uint("MEASURED sweeps (either door) that moved insurance", sweepsThatMoved);
        emit log_named_uint("MEASURED sequences with a moving sweep before the close", sequencesWithSweepBeforeClose);
        emit log_named_uint("MEASURED sequences where bob was also booked", sequencesWithBobBooked);
        emit log_named_uint("MEASURED max alice shortfall vs uncapped accrual (wei)", maxShortfallA);
        emit log_named_uint("MEASURED worst sequence (i*100+j*10+k)", worstSeq);
        emit log_named_uint("MEASURED max alice unpaid after her claim (wei)", maxUnpaidA);
        emit log_named_uint("MEASURED max bob unpaid after his claim (wei)", maxUnpaidB);
        emit log_named_uint("MEASURED max backing deficit at any step (wei)", maxBackingDeficit);
        assertEq(n, ACTIONS * ACTIONS, "walk slice incomplete");
        assertLe(maxShortfallA, 8, "a sweep or sibling took alice's accrual beyond rounding: F18 defeated");
        assertLe(maxUnpaidA, 8, "alice's booking could not be met: a booking was counted twice");
        assertLe(maxUnpaidB, 8, "bob's booking could not be met: a booking was counted twice");
        assertLe(maxBackingDeficit, 8, "held-for-others exceeded reachable backing beyond rounding");
    }

    /// @notice NEGATIVE, the lead refuted by execution. Eleven slices of one depth-3 exhaustive walk
    ///         over the eleven-letter alphabet (1,331 sequences in all), each sequence followed by
    ///         alice's clean close and every claim. The assertions hold the envelope to the rounding
    ///         bound (one wei per settle of the auction's own position); the MEASURED envelope is in
    ///         the logs. Slice 0 is the lead's own door first.
    function test_R56A02_81_negative_walk00_sweepWorkoutYieldFirst() public {
        _walk(0);
    }

    function test_R56A02_81_negative_walk01_sweepFreeFirst() public {
        _walk(1);
    }

    function test_R56A02_81_negative_walk02_claimSurplusForFirst() public {
        _walk(2);
    }

    function test_R56A02_81_negative_walk03_settleFirst() public {
        _walk(3);
    }

    function test_R56A02_81_negative_walk04_oneDayFirst() public {
        _walk(4);
    }

    function test_R56A02_81_negative_walk05_bobCleanCloseFirst() public {
        _walk(5);
    }

    function test_R56A02_81_negative_walk06_claimBobFirst() public {
        _walk(6);
    }

    function test_R56A02_81_negative_walk07_donateFirst() public {
        _walk(7);
    }

    function test_R56A02_81_negative_walk08_epochFirst() public {
        _walk(8);
    }

    function test_R56A02_81_negative_walk09_bobForcedCloseFirst() public {
        _walk(9);
    }

    function test_R56A02_81_negative_walk10_disposeBobFirst() public {
        _walk(10);
    }

    // ── the "dead" NothingToClaim lines ──────────────────────────────────────

    /// @notice NEGATIVE for the dead-line half. `claimWorkoutYield`'s `owed == 0` refusal is LIVE:
    ///         a second claim on a paid-out booking reaches it.
    function test_R56A02_81_negative_owedZeroNothingToClaimIsReached() public {
        _rescue(alice);
        auction.closeWorkout(aliceId);
        auction.claimWorkoutYield(aliceId);
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(aliceId);
    }

    // The `available == 0` refusal is reached NATURALLY in R56A02_DetachedBearerRunbook.t.sol
    // (round-56 item 235): the later bearer's claim is refused while the earlier backing sits on
    // the detached manager.
}
