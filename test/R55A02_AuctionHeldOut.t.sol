// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AuctionHandler} from "./LiquidationAuction.invariants.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
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
import {RiskParams} from "../src/RiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @title R55A02 - the held-out auction block, deterministic half: 246(b) and 246(d)
/// @notice Drives the campaign's own `AuctionHandler` from a COPY of `LiquidationAuctionInvariants`'
///         fixture rather than by inheritance, so this file carries no `invariant_` function and
///         adds no campaign to CI. Recipes are the handler's, so the states are the campaign's.
///
/// @dev 246(b), round-55 item 192: the dust deadlock is REACHED DETERMINISTICALLY outside the
///      campaign, with the grind count as the parameter, and the enumeration of what makes
///      `earned` exceed a lot's own pot is EXECUTED rather than read: every `_settle` of the
///      auction's position floors once, so the doors are `settle` (permissionless, unbounded),
///      `claimSurplusFor(auction)` (permissionless, unbounded while pending accrues), and the
///      bounded protocol settles - `reassign` at expiry, the clean close's own `settle`, a
///      `disposeTo`, a sweep's pull. `yieldAccruedOn` and `_pending` cannot open a gap by
///      themselves: both are one floor of the same accumulator delta. MEASURED: 87 hourly settles
///      opened 23 wei, `claimSurplusFor` opened the same 23, no grind opened 0.
///
///      246(d): gas of the bearer pull with N detached bearers is flat in N, because every pull
///      names one manager and `_fundInsuranceWithFree` reads the aggregate booking. MEASURED:
///      73,651 / 73,652 / 73,652 for the stranger pull and 117,855 x3 for the claim at N = 1, 2,
///      3; the forced close 291,247 with 0 and with 3.
contract R55A02_AuctionHeldOut is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant POOL_DEPOSIT = 20_000e6;
    uint256 internal constant SPARES = 3;

    AuctionHandler internal handler;
    CreditManager[] internal managers;
    LenderPool[] internal pools;
    CollateralVault internal vault;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    DirectCallAdapter internal adapter;
    LenderPool internal pool;
    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal harvester = makeAddr("harvester");

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    // ── the campaign's fixture, copied ───────────────────────────────────────

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, makeAddr("sink")
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(harvester);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), POOL_DEPOSIT);
        usdc.approve(address(pool), POOL_DEPOSIT);
        pool.deposit(POOL_DEPOSIT, address(this));

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        for (uint256 i = 0; i < actors.length; i++) {
            bond.mint(actors[i], 1_000);
            usdc.mint(actors[i], 100_000e6);
            vm.startPrank(actors[i]);
            bond.setApprovalForAll(address(vault), true);
            vault.depositBonds(100);
            vm.stopPrank();
        }

        managers.push(credit);
        pools.push(pool);
        for (uint256 i = 0; i < SPARES; i++) {
            _deploySpare();
        }

        handler = new AuctionHandler(
            vault, managers, auction, oracle, usdc, bond, pools, keeper, harvester, admin, actors
        );
    }

    function _deploySpare() internal {
        CreditManager m = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        LenderPool p = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        p.setCreditManager(address(m));
        p.setEpochHarvester(harvester);
        m.setLiquiditySource(address(p));
        m.setLenderPool(address(p));
        m.setEpochHarvester(harvester);
        m.setLiquidationAuction(address(auction));
        vm.stopPrank();
        usdc.mint(address(this), POOL_DEPOSIT);
        usdc.approve(address(p), POOL_DEPOSIT);
        p.deposit(POOL_DEPOSIT, address(this));
        managers.push(m);
        pools.push(p);
    }

    function _live() internal view returns (CreditManager) {
        return handler.credit();
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _cleanCloseOnTheLiveManager(uint256 actorIx, uint256 epochs, uint256 skips)
        internal
        returns (uint256 id)
    {
        address who = handler.actors(actorIx);
        uint256 closesBefore = handler.cleanClosesThatBookedYield();
        handler.moveNav(30e8);
        handler.borrow(actorIx, 620e6);
        assertGt(_live().currentDebtOf(who), 0, "the actor must be able to borrow on the live manager");
        handler.moveNav(1e8);
        handler.liquidate(actorIx);
        id = auction.auctionOf(who);
        assertGt(id, 0, "the position must be liquidatable on the live manager");
        handler.expireEligible(0);
        assertEq(auction.workoutsOpenFor(who), 1, "the workout must open");
        for (uint256 i = 0; i < epochs; i++) {
            uint256 landed = handler.yieldEpochsDistributed();
            handler.deliverYield(500e6);
            assertEq(handler.yieldEpochsDistributed(), landed + 1, "the epoch must reach the live accumulator");
            for (uint256 s = 0; s < skips; s++) {
                handler.passTime(3 days);
            }
        }
        handler.workoutSettle(_indexOf(id), 2_000e6);
        assertEq(_live().currentDebtOf(who), 0, "the settlement must clear the debt");
        handler.closeLiveWorkout(0);
        assertEq(handler.cleanClosesThatBookedYield(), closesBefore + 1, "the close must be clean and book yield");
    }

    function _indexOf(uint256 id) internal view returns (uint256) {
        uint256 n = handler.startedCount();
        for (uint256 j = 0; j < n; j++) {
            if (handler.startedAuctions(j) == id) return j;
        }
        revert("fixture: unknown auction id");
    }

    // ── 246(b): the dust deadlock, deterministically ─────────────────────────

    /// @dev Era one: alice books on manager 0 and her backing is PUSHED onto the auction from the
    ///      detached manager before bob's era. Era two: bob's lot on the live spare, ground `grind`
    ///      times through one of the two permissionless doors during the stream, then settled and
    ///      closed clean.
    function _reach(uint256 grind, bool viaClaimSurplus)
        internal
        returns (uint256 aliceId, uint256 bobId, uint256 earned, uint256 pot, uint256 pushed)
    {
        aliceId = _cleanCloseOnTheLiveManager(0, 1, 2);
        handler.disposeClosedLot(0);
        handler.migrate(0);
        assertEq(handler.migrations(), 1, "fixture: repointed");
        CreditManager detached = managers[0];
        assertTrue(address(detached) != address(_live()), "fixture: manager 0 is detached");

        uint256 before = usdc.balanceOf(address(auction));
        detached.claimSurplusFor(address(auction));
        pushed = usdc.balanceOf(address(auction)) - before;
        assertGt(pushed, 0, "fixture: alice's backing was pushed onto the auction");

        address bob = handler.actors(1);
        handler.moveNav(30e8);
        handler.borrow(1, 620e6);
        handler.moveNav(1e8);
        handler.liquidate(1);
        bobId = auction.auctionOf(bob);
        handler.expireEligible(0);
        assertEq(auction.workoutsOpenFor(bob), 1, "fixture: bob's workout is open");
        handler.deliverYield(500e6);
        for (uint256 k = 0; k < grind; k++) {
            skip(1 hours);
            if (viaClaimSurplus) {
                try _live().claimSurplusFor(address(auction)) {} catch {}
            } else {
                _live().settle(address(auction));
            }
        }
        handler.passTime(3 days);
        handler.passTime(3 days);
        handler.workoutSettle(_indexOf(bobId), 2_000e6);
        assertEq(_live().currentDebtOf(bob), 0, "fixture: bob's debt is cleared");

        (,,, uint256 bonds,,,,,, uint256 idx,) = auction.workouts(bobId);
        earned = _live().yieldAccruedOn(bonds, idx);
        // Bob's own pot on the live manager: what the auction's position there can still reach,
        // net of the pushed backing and the liquidation callers' reserved rewards.
        pot = (usdc.balanceOf(address(auction)) - pushed - auction.totalUnclaimedRewards())
            + _live().claimableOf(address(auction)) + _live().pendingYieldOf(address(auction));
        handler.closeLiveWorkout(0);
    }

    function _claimBoth(uint256 aliceId, uint256 bobId) internal returns (uint256 dust) {
        address alice = handler.actors(0);
        address bob = handler.actors(1);
        uint256 a0 = usdc.balanceOf(alice);
        uint256 b0 = usdc.balanceOf(bob);
        try auction.claimWorkoutYield(aliceId) {} catch {}
        try auction.claimWorkoutYield(bobId) {} catch {}
        emit log_named_uint("alice paid", usdc.balanceOf(alice) - a0);
        emit log_named_uint("bob paid", usdc.balanceOf(bob) - b0);
        dust = auction.totalWorkoutYieldOwed();
    }

    function test_R55A02_246b_theDustDeadlockIsReachedDeterministicallyBySettleGrind() public {
        (uint256 aliceId, uint256 bobId, uint256 earned, uint256 pot, uint256 pushed) = _reach(87, false);
        uint256 aliceBooked = _yieldOwed(aliceId);
        uint256 bobBooked = _yieldOwed(bobId);
        emit log_named_uint("pushed (alice's backing on the auction)", pushed);
        emit log_named_uint("alice booked", aliceBooked);
        emit log_named_uint("bob earned (one floor)", earned);
        emit log_named_uint("bob's own pot (sum of per-settle floors)", pot);
        emit log_named_uint("bob booked", bobBooked);
        assertGt(earned, pot, "the grind must open a gap");
        uint256 gap = earned - pot;
        emit log_named_uint("gap in wei", gap);
        assertEq(bobBooked, earned, "under the split bob is booked at earned, not clamped to the pot");

        uint256 dust = _claimBoth(aliceId, bobId);
        emit log_named_uint("dust bookings left standing", dust);
        assertGt(dust, 0, "the dust deadlock");
        assertLe(dust, 2 * gap, "each claim is short by at most the gap");
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(aliceId);
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(bobId);
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepFreeBalanceToInsurance();
    }

    /// @notice The SECOND permissionless door: `claimSurplusFor(auction)` settles the position
    ///         too, one floor per call, so the same gap opens with the settle selector never used.
    function test_R55A02_246b_enumerate_claimSurplusForIsASecondGrindDoor() public {
        (,, uint256 earned, uint256 pot,) = _reach(87, true);
        emit log_named_uint("bob earned", earned);
        emit log_named_uint("bob's own pot", pot);
        emit log_named_uint("gap via claimSurplusFor grind", earned > pot ? earned - pot : 0);
        assertGt(earned, pot, "claimSurplusFor grinds the same floor");
    }

    /// @notice With NO grind the protocol's own settles (reassign at expiry, the close's own
    ///         settle) bound the gap; MEASURED so the bound is a number rather than a claim.
    function test_R55A02_246b_enumerate_theUngroundGapIsBounded() public {
        (uint256 aliceId, uint256 bobId, uint256 earned, uint256 pot,) = _reach(0, false);
        uint256 gap = earned > pot ? earned - pot : 0;
        emit log_named_uint("bob earned, no grind", earned);
        emit log_named_uint("bob's own pot, no grind", pot);
        emit log_named_uint("gap with no grind (wei)", gap);
        assertLe(gap, 2, "at most one wei per protocol settle of the auction's position");
        uint256 dust = _claimBoth(aliceId, bobId);
        emit log_named_uint("dust bookings left standing, no grind", dust);
        assertLe(dust, 2 * gap);
    }

    // ── 246(d): gas of the bearer pull with N detached bearers ───────────────

    function test_R55A02_246d_gasOfTheBearerPullIsFlatInDetachedBearers() public {
        uint256[3] memory ids;
        uint256[3] memory gasPull;
        uint256[3] memory gasClaim;
        for (uint256 era = 0; era < 3; era++) {
            ids[era] = _cleanCloseOnTheLiveManager(era, 1, 2);
            handler.disposeClosedLot(0);
            handler.migrate(0);
            assertEq(handler.migrations(), era + 1, "fixture: repointed");
            uint256 g = gasleft();
            try managers[era].claimSurplusFor(address(auction)) {} catch {}
            gasPull[era] = g - gasleft();
            g = gasleft();
            auction.claimWorkoutYield(ids[era]);
            gasClaim[era] = g - gasleft();
            emit log_named_uint("N detached bearers", era + 1);
            emit log_named_uint("  gas: stranger pull of the oldest detached bearer", gasPull[era]);
            emit log_named_uint("  gas: claimWorkoutYield (cm pull + bearer pull)", gasClaim[era]);
        }
        assertLt(_spread(gasClaim), 5_000, "claim gas must not grow with N");
    }

    /// @notice The forced close under `_fundInsuranceWithFree` with three detached bearers'
    ///         bookings standing, against the same close with none.
    function test_R55A02_246d_gasOfTheForcedCloseWithThreeDetachedBearers() public {
        uint256 snap = vm.snapshotState();
        uint256 alone = _forcedCloseGas(2);
        vm.revertToState(snap);
        for (uint256 era = 0; era < 3; era++) {
            _cleanCloseOnTheLiveManager(era, 1, 2);
            handler.disposeClosedLot(0);
            handler.migrate(0);
        }
        assertGt(auction.totalWorkoutYieldOwed(), 0, "fixture: bookings stand on detached bearers");
        uint256 withThree = _forcedCloseGas(2);
        emit log_named_uint("gas: forced closeWorkout, no detached bearers", alone);
        emit log_named_uint("gas: forced closeWorkout, three detached bearers with bookings", withThree);
    }

    function _forcedCloseGas(uint256 actorIx) internal returns (uint256 used) {
        address who = handler.actors(actorIx);
        handler.moveNav(30e8);
        handler.borrow(actorIx, 620e6);
        handler.moveNav(1e8);
        handler.liquidate(actorIx);
        uint256 id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: liquidated");
        handler.expireEligible(0);
        assertEq(auction.workoutsOpenFor(who), 1, "fixture: workout open");
        handler.passTimeToRecognitionDeadline(0);
        uint256 g = gasleft();
        auction.closeWorkout(id);
        used = g - gasleft();
        (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
        assertGt(writtenDown, 0, "fixture: the close was forced");
    }

    function _spread(uint256[3] memory xs) internal pure returns (uint256) {
        uint256 lo = xs[0];
        uint256 hi = xs[0];
        for (uint256 i = 1; i < 3; i++) {
            if (xs[i] < lo) lo = xs[i];
            if (xs[i] > hi) hi = xs[i];
        }
        return hi - lo;
    }
}
