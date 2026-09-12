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

/// @title R57A02 - round-57 item 177: the settle grind beyond round 56's depth-3 walk, across TWO
///        managers
/// @notice Audit round 57, agent A2, target 2. Self-contained, the `R53A01_VariantSplit` stack.
///
///         Round 56's depth-3 walk (`R56A02_SweepVersusF18`) ran on ONE manager, so it could not
///         reach the state round-57 item 177 describes: a booking made on a DETACHED bearer whose
///         backing a stranger has pushed onto the auction before the next era's clean close. This
///         file starts from that era boundary - alice's clean-close booking on manager one, the
///         vault migrated to manager two, bob's workout OPEN on manager two with a stream running and
///         a 37-bond dilution staker so the per-settle floor actually bites - and walks every
///         sequence of length four over a twelve-letter alphabet (20,736 sequences, split twelve
///         ways), then a random-sequence campaign of length-16 sequences from an UNSEEDED draw.
///
///         Every sequence is followed by the same drain: close bob cleanly if still open, pull both
///         managers for the auction, claim both bookings twice. Measured per step and per sequence:
///         the backing deficit (what the auction holds for named parties against what it can still
///         reach, detached manager's `claimableOf` included and its phantom `pendingYieldOf`
///         excluded), each borrower's unpaid booking after the drain, and bob's `earned - pot`.
///
/// @dev The action alphabet, with the auction-position SETTLE events marked (*), since every
///      settle of the auction's own position floors once and `earned` is floored once:
///       0 (*) stranger `settle(auction)` on the live manager (the grind)
///       1     skip one hour
///       2     `claimSurplusFor(auction)` on the DETACHED manager (push alice's backing)
///       3 (*) `claimSurplusFor(auction)` on the live manager
///       4 (*) `claimWorkoutYield(alice)` (pulls live, then the bearer)
///       5 (*) bob's workout closed clean (rescuer `repayFor`, then `closeWorkout`, which settles)
///       6 (*) `claimWorkoutYield(bob)`
///       7     `sweepFreeBalanceToInsurance`
///       8 (*) `sweepWorkoutYieldToInsurance` (live `claimSurplus`)
///       9     one wei donated to the auction
///      10     a fresh epoch on the live manager
///      11 (*) bob's workout FORCE-closed (skip the workout window, `closeWorkout`)
contract R57A02_GrindTwoManagers is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant DILUTION_BONDS = 37;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;
    uint256 internal constant ACTIONS = 12;
    uint256 internal constant PRE_GRIND_HOURS = 60;

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
    CreditManager internal one;
    CreditManager internal two;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    uint256 internal aliceId;
    uint256 internal bobId;
    uint256 internal bookedA;

    // Envelope, carried across `revertToState` in memory by the walks.
    struct Env {
        uint256 sequences;
        uint256 maxDeficit;
        uint256 maxStuck;
        uint256 maxShortA;
        uint256 maxShortB;
        uint256 maxGrind;
        uint256 deadlocks;
        uint256 bobBookedSeq;
        uint256 worstSeq;
    }

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
        one = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        treasury = new TreasuryLiquiditySource(usdc, admin);
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(one));
        vault.setLiquidationAuction(address(auction));
        treasury.setCreditManager(address(one));
        one.setLiquiditySource(address(treasury));
        one.setEpochHarvester(harvester);
        one.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(one));
        vm.stopPrank();
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
        usdc.mint(address(treasury), TREASURY_FLOAT);

        _seed(alice, BONDS);
        _seed(bob, BONDS);

        // Era one: alice's clean-close booking on manager one, her lot disposed.
        aliceId = _openWorkoutOn(one, alice);
        _streamEpochOn(one, EPOCH);
        _rescueDebtOn(one, alice);
        auction.closeWorkout(aliceId);
        bookedA = _yieldOwed(aliceId);
        require(bookedA > 0, "fixture: alice not booked");
        vm.prank(admin);
        auction.disposeWorkoutLot(aliceId, alice);

        // Migrate; era two: a dilution staker, bob's workout open, a stream running, a pre-grind.
        two = _migrate();
        _seed(carol, DILUTION_BONDS);
        bobId = _openWorkoutOn(two, bob);
        _startStreamOn(two, EPOCH);
        for (uint256 h = 0; h < PRE_GRIND_HOURS; ++h) {
            skip(1 hours);
            vm.prank(stranger);
            two.settle(address(auction));
        }
    }

    // ── fixture helpers ──────────────────────────────────────────────────────

    function _seed(address who, uint256 bonds) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _openWorkoutOn(CreditManager cm, address who) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = (BONDS * NAV * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        vm.prank(who);
        cm.borrow(debt);
        oracle.setNav(((debt * Config.USDC_TO_NAV_SCALE) / BONDS) / 2);
        vm.prank(keeper);
        cm.liquidate(who);
        id = auction.auctionOf(who);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        oracle.setNav(NAV);
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
        if (owed == 0) return;
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

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _status(uint256 id) internal view returns (LiquidationAuction.WorkoutStatus s) {
        (,, s,,,,,,,,) = auction.workouts(id);
    }

    function _index(uint256 id) internal view returns (uint256 idx) {
        (,,,,,,,,, idx,) = auction.workouts(id);
    }

    /// @dev Held for named parties against what can still be reached. The detached manager's
    ///      `pendingYieldOf(auction)` is NOT counted: `_settle` early-returns on a detached manager,
    ///      so that figure is a phantom nobody can realise (round 54's finding, restated in
    ///      `CollateralVault.setCreditManager`).
    function _deficit() internal view returns (uint256) {
        uint256 openAccrual;
        if (_status(bobId) == LiquidationAuction.WorkoutStatus.Open) {
            openAccrual = two.yieldAccruedOn(BONDS, _index(bobId));
        }
        uint256 owed = auction.totalUnclaimedRewards() + auction.totalWorkoutYieldOwed() + openAccrual;
        uint256 reach = usdc.balanceOf(address(auction)) + two.claimableOf(address(auction))
            + two.pendingYieldOf(address(auction)) + one.claimableOf(address(auction));
        return owed > reach ? owed - reach : 0;
    }

    /// @dev bob's `earned - pot` while his workout is open (0 once it has closed).
    function _grind() internal view returns (uint256) {
        if (_status(bobId) != LiquidationAuction.WorkoutStatus.Open) return 0;
        uint256 earned = two.yieldAccruedOn(BONDS, _index(bobId));
        uint256 pot = two.claimableOf(address(auction)) + two.pendingYieldOf(address(auction));
        return earned > pot ? earned - pot : 0;
    }

    // ── the alphabet ─────────────────────────────────────────────────────────

    function _act(uint256 a) internal {
        if (a == 0) {
            vm.prank(stranger);
            try two.settle(address(auction)) {} catch {}
        } else if (a == 1) {
            skip(1 hours);
        } else if (a == 2) {
            vm.prank(stranger);
            try one.claimSurplusFor(address(auction)) {} catch {}
        } else if (a == 3) {
            vm.prank(stranger);
            try two.claimSurplusFor(address(auction)) {} catch {}
        } else if (a == 4) {
            vm.prank(stranger);
            try auction.claimWorkoutYield(aliceId) {} catch {}
        } else if (a == 5) {
            if (_status(bobId) == LiquidationAuction.WorkoutStatus.Open) {
                _rescueDebtOn(two, bob);
                vm.prank(stranger);
                try auction.closeWorkout(bobId) {} catch {}
            }
        } else if (a == 6) {
            vm.prank(stranger);
            try auction.claimWorkoutYield(bobId) {} catch {}
        } else if (a == 7) {
            vm.prank(stranger);
            try auction.sweepFreeBalanceToInsurance() {} catch {}
        } else if (a == 8) {
            vm.prank(stranger);
            try auction.sweepWorkoutYieldToInsurance() {} catch {}
        } else if (a == 9) {
            usdc.mint(address(auction), 1);
        } else if (a == 10) {
            _startStreamOn(two, EPOCH);
        } else if (a == 11) {
            if (_status(bobId) == LiquidationAuction.WorkoutStatus.Open) {
                skip(Config.WORKOUT_MAX_DURATION);
                vm.prank(stranger);
                try auction.closeWorkout(bobId) {} catch {}
            }
        }
    }

    /// @dev Replay `seq`, drain, fold into `e`. Returns the stuck bookings after the drain.
    function _run(uint256[] memory seq, Env memory e) internal returns (uint256 stuck) {
        uint256 g = _grind();
        if (g > e.maxGrind) e.maxGrind = g;
        for (uint256 i = 0; i < seq.length; ++i) {
            _act(seq[i]);
            uint256 d = _deficit();
            if (d > e.maxDeficit) e.maxDeficit = d;
        }

        // Drain.
        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);
        uint256 aOwedStart = _yieldOwed(aliceId);
        if (_status(bobId) == LiquidationAuction.WorkoutStatus.Open) {
            _rescueDebtOn(two, bob);
            vm.prank(stranger);
            auction.closeWorkout(bobId);
        }
        uint256 bOwedStart = _yieldOwed(bobId);
        if (bOwedStart != 0) e.bobBookedSeq++;
        for (uint256 r = 0; r < 2; ++r) {
            vm.startPrank(stranger);
            try one.claimSurplusFor(address(auction)) {} catch {}
            try two.claimSurplusFor(address(auction)) {} catch {}
            try auction.claimWorkoutYield(aliceId) {} catch {}
            try auction.claimWorkoutYield(bobId) {} catch {}
            vm.stopPrank();
        }
        uint256 d2 = _deficit();
        if (d2 > e.maxDeficit) e.maxDeficit = d2;
        uint256 paidA = usdc.balanceOf(alice) - aBefore;
        uint256 paidB = usdc.balanceOf(bob) - bBefore;
        uint256 shortA = aOwedStart > paidA ? aOwedStart - paidA : 0;
        uint256 shortB = bOwedStart > paidB ? bOwedStart - paidB : 0;
        if (shortA > e.maxShortA) e.maxShortA = shortA;
        if (shortB > e.maxShortB) e.maxShortB = shortB;
        stuck = auction.totalWorkoutYieldOwed();
        if (stuck != 0) e.deadlocks++;
        e.sequences++;
    }

    function _log(string memory label, Env memory e) internal {
        emit log_string(label);
        emit log_named_uint("MEASURED sequences walked", e.sequences);
        emit log_named_uint("MEASURED sequences with bookings stuck after the drain", e.deadlocks);
        emit log_named_uint("MEASURED max stuck bookings after the drain (wei)", e.maxStuck);
        emit log_named_uint("MEASURED worst sequence (base-12 digits, first action most significant)", e.worstSeq);
        emit log_named_uint("MEASURED max backing deficit at any step (wei)", e.maxDeficit);
        emit log_named_uint("MEASURED max alice unpaid after the drain (wei)", e.maxShortA);
        emit log_named_uint("MEASURED max bob unpaid after the drain (wei)", e.maxShortB);
        emit log_named_uint("MEASURED bob earned - pot at the start of each sequence (wei)", e.maxGrind);
        emit log_named_uint("MEASURED sequences where bob was booked", e.bobBookedSeq);
    }

    /// @dev The bound this file holds every sequence to, and why it is not zero: the pre-grind is
    ///      sixty stranger settles, and every auction-position settle floors at most one wei, so a
    ///      deficit or stuck booking of up to one wei per settle event is round-57 item 177's
    ///      documented dust. Sixty pre-grind settles plus at most four walk settles plus the drain's
    ///      settles (one clean close and four pulls or claims per round, two rounds) is under 80.
    uint256 internal constant DUST_BOUND = 80;

    // ── CONTROL ──────────────────────────────────────────────────────────────

    /// @notice CONTROL. The drain alone, with nothing in front of it: bob closes cleanly, both are
    ///         paid, and the envelope reads what round-57 item 177's row predicts for the order
    ///         "bob closes, then anyone pulls" (no pushed foreign backing at bob's close), namely
    ///         nothing stuck.
    function test_R57A02_177_control_theDrainAloneLeavesNothingStuck() public {
        Env memory e;
        uint256[] memory none = new uint256[](0);
        uint256 stuck = _run(none, e);
        _log("CONTROL: drain only", e);
        assertEq(stuck, 0, "control: a booking was left standing with nothing pushed first");
        assertEq(e.maxShortA, 0, "control: alice unpaid");
        assertEq(e.maxShortB, 0, "control: bob unpaid");
    }

    /// @notice The row's own state, reproduced on this fixture: push alice's backing FIRST, then the
    ///         drain closes bob against it. The pre-grind has opened `earned - pot`, so both are paid
    ///         short by that grind and the two dust bookings stand.
    function test_R57A02_177_measure_pushFirstReproducesTheDustDeadlock() public {
        Env memory e;
        uint256[] memory seq = new uint256[](1);
        seq[0] = 2;
        uint256 grindAtPush = _grind();
        uint256 stuck = _run(seq, e);
        _log("MEASURE: push alice's backing, then drain", e);
        emit log_named_uint("MEASURED bob earned - pot at the push (wei)", grindAtPush);
        emit log_named_uint("MEASURED stuck bookings (wei)", stuck);
        assertGt(grindAtPush, 0, "fixture: the pre-grind opened no gap");
        assertEq(stuck, 2 * grindAtPush, "the stuck dust is not two grinds");
        assertLe(stuck, 2 * DUST_BOUND, "stuck beyond the dust bound");
    }

    /// @notice REFUTES the letter of round-57 item 177's "only the settle grind can make `earned`
    ///         exceed a lot's pot": any permissionless call that SETTLES the auction's own position is a
    ///         grind step, and `settle` is only one of them. Here the grind is done with 40 hourly
    ///         `claimSurplusFor(auction)` on the LIVE manager (a stranger pulling the auction's own
    ///         surplus to it, which settles first) and never a bare `settle`. bob's `earned` then
    ///         exceeds what the auction can reach for him (the manager's pot plus everything the
    ///         pulls moved onto the auction) by more than the pre-grind, one wei at most per pull.
    function test_R57A02_177_measure_aPullIsAGrindStepToo() public {
        uint256 g0 = _grind();
        uint256 held0 = usdc.balanceOf(address(auction));
        uint256 pulls;
        for (uint256 h = 0; h < 40; ++h) {
            skip(1 hours);
            vm.prank(stranger);
            try two.claimSurplusFor(address(auction)) {
                pulls++;
            } catch {}
        }
        uint256 earned = two.yieldAccruedOn(BONDS, _index(bobId));
        uint256 reach = two.claimableOf(address(auction)) + two.pendingYieldOf(address(auction))
            + (usdc.balanceOf(address(auction)) - held0);
        uint256 gap = earned > reach ? earned - reach : 0;
        emit log_named_uint("MEASURED gap before (60 settles in setUp)", g0);
        emit log_named_uint("MEASURED pulls that moved money", pulls);
        emit log_named_uint("MEASURED gap after 40 hourly pulls, no settle", gap);
        assertGt(pulls, 0, "fixture: no pull moved");
        assertGt(gap, g0, "the pulls did not grind: only settle grinds after all");
        assertLe(gap - g0, pulls, "more than one wei per pull");
    }

    // ── the exhaustive depth-4 walk ──────────────────────────────────────────

    function _walk(uint256 first) internal returns (Env memory e) {
        vm.pauseGasMetering();
        uint256 snap = vm.snapshotState();
        uint256[] memory seq = new uint256[](4);
        uint256 worst;
        for (uint256 j = 0; j < ACTIONS; ++j) {
            for (uint256 k = 0; k < ACTIONS; ++k) {
                for (uint256 l = 0; l < ACTIONS; ++l) {
                    vm.revertToState(snap);
                    seq[0] = first;
                    seq[1] = j;
                    seq[2] = k;
                    seq[3] = l;
                    uint256 stuck = _run(seq, e);
                    if (stuck > worst) {
                        worst = stuck;
                        e.maxStuck = stuck;
                        e.worstSeq = first * 1728 + j * 144 + k * 12 + l;
                    }
                }
            }
        }
        vm.revertToState(snap);
        _log(string.concat("WALK depth 4, first action ", vm.toString(first)), e);
        assertEq(e.sequences, ACTIONS ** 3, "walk slice incomplete");
        assertLe(e.maxDeficit, DUST_BOUND, "a backing deficit beyond one wei per settle: not the dust of item 177");
        assertLe(e.maxStuck, 2 * DUST_BOUND, "bookings stuck beyond two grinds");
        vm.resumeGasMetering();
    }

    function test_R57A02_177_walk_a00() public {
        _walk(0);
    }

    function test_R57A02_177_walk_a01() public {
        _walk(1);
    }

    function test_R57A02_177_walk_a02() public {
        _walk(2);
    }

    function test_R57A02_177_walk_a03() public {
        _walk(3);
    }

    function test_R57A02_177_walk_a04() public {
        _walk(4);
    }

    function test_R57A02_177_walk_a05() public {
        _walk(5);
    }

    function test_R57A02_177_walk_a06() public {
        _walk(6);
    }

    function test_R57A02_177_walk_a07() public {
        _walk(7);
    }

    function test_R57A02_177_walk_a08() public {
        _walk(8);
    }

    function test_R57A02_177_walk_a09() public {
        _walk(9);
    }

    function test_R57A02_177_walk_a10() public {
        _walk(10);
    }

    function test_R57A02_177_walk_a11() public {
        _walk(11);
    }

    // ── the random-sequence campaign ─────────────────────────────────────────

    /// @dev UNSEEDED: the draw is `vm.randomUint()`, which forge derives from the run's fuzz seed, so
    ///      each invocation walks a different set and the seed is printed so a failure reproduces
    ///      with `--fuzz-seed`. Length 16, 400 sequences per test, four tests.
    function _campaign(uint256 salt) internal returns (Env memory e) {
        vm.pauseGasMetering();
        uint256 seed = uint256(keccak256(abi.encode(vm.randomUint(), salt)));
        emit log_named_uint("MEASURED campaign seed", seed);
        uint256 snap = vm.snapshotState();
        uint256[] memory seq = new uint256[](16);
        uint256 worst;
        for (uint256 s = 0; s < 400; ++s) {
            vm.revertToState(snap);
            uint256 acc;
            for (uint256 i = 0; i < 16; ++i) {
                seed = uint256(keccak256(abi.encode(seed)));
                seq[i] = seed % ACTIONS;
                acc = acc * 12 + seq[i];
            }
            uint256 stuck = _run(seq, e);
            if (stuck > worst) {
                worst = stuck;
                e.maxStuck = stuck;
                e.worstSeq = acc;
            }
        }
        vm.revertToState(snap);
        _log(string.concat("CAMPAIGN salt ", vm.toString(salt)), e);
        assertEq(e.sequences, 400, "campaign incomplete");
        assertLe(e.maxDeficit, DUST_BOUND, "a backing deficit beyond one wei per settle");
        assertLe(e.maxStuck, 2 * DUST_BOUND, "bookings stuck beyond two grinds");
        vm.resumeGasMetering();
    }

    function test_R57A02_177_campaign_c0() public {
        _campaign(0);
    }

    function test_R57A02_177_campaign_c1() public {
        _campaign(1);
    }

    function test_R57A02_177_campaign_c2() public {
        _campaign(2);
    }

    function test_R57A02_177_campaign_c3() public {
        _campaign(3);
    }
}
