// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @dev The wiring both suites below share, less the liquidity source. Two subclasses supply that:
///      a `TreasuryLiquiditySource` (so a socialised residual is borne by never being repaid and a
///      recovery lands in `pendingPrincipal`) and a real `LenderPool` that both funds the book and
///      takes the losses (so `lossBearerOf` names a pool and the recovery is relayed to it). Both
///      halves of round 46's recovery finding need one of the two and neither needs both.
abstract contract R46RecoveryFixture is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD, 8dp
    uint256 internal constant BONDS = 100;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal relayer = makeAddr("relayer");
    address internal yieldSink = makeAddr("yieldSink");
    address internal feeWallet = makeAddr("feeWallet");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    RiskParams internal riskParams;
    EpochHarvester internal harvester;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    /// @dev Wire the liquidity source and the loss sink, and fund whatever lends.
    function _wireFunding() internal virtual;

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
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        harvester.setProtocolFeeWallet(feeWallet);
        adapter.setHarvester(address(harvester));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        _wireFunding();

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _crashedNav(uint256 debt) internal pure returns (uint256) {
        return _navAtDebtParity(debt, BONDS) / 2;
    }

    /// @dev Drive alice to a forced `closeWorkout` with a real residual, so the workout carries a
    ///      non-zero `writtenDown` and the manager has recorded who bore it.
    function _closedWorkoutWithResidual() internal returns (uint256 id) {
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(alice);
        credit.borrow(debt);

        oracle.setNav(_crashedNav(debt));
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: no auction opened");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(id);
    }

    /// @dev `Workout` has eleven members; only `writtenDown` (the eighth) is read here.
    function _writtenDown(uint256 id) internal view returns (uint256 writtenDown) {
        (,,,,,,, writtenDown,,,) = auction.workouts(id);
    }

    function _fundRelayer(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), amount);
    }

    function _freshAuction() internal returns (LiquidationAuction) {
        return new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
    }
}

/// @title Round 46 finding 1: an auction repoint used to brick a closed workout's recovery leg.
/// @notice `LiquidationAuction.workoutSettleAfterClose` pays `Workout.bearer`, the manager recorded
///         at `closeWorkout`, so the auction's side of the leg survives a MANAGER migration - round
///         22 finding 8 built that deliberately. The mirror was not covered: the manager's
///         `recoverWrittenDownLoss` gated on `_requireAuction()`, a live read of
///         `liquidationAuction`, so an AUCTION migration killed the same leg from the other end.
///
///         The state the migration is permitted in is exactly the state a live recovery sits in.
///         After `closeWorkout` leaves `writtenDown > 0` and `disposeWorkoutLot` hands the lot to
///         the redemption desk, the outgoing auction reports no live auctions, no open workouts and
///         no held lot, so every clause of `CreditWiring.checkAuctionSwap` is satisfied.
///
///         `wasLiquidationAuction` is the fix, and it is the house pattern rather than a new one:
///         the outgoing party keeps its claim on this manager, as `owedToSource`,
///         `EpochHarvester.owedToPool`, `flushPrincipalTo` and `DirectCallAdapter.flushYieldTo` all
///         do. This fixture funds from a treasury, so nothing bears the loss as a pool and the
///         recovery lands in `pendingPrincipal` - the branch that makes the arithmetic legible.
contract R46AuctionRepointRecoveryTest is R46RecoveryFixture {
    uint256 internal constant FLOAT = 100_000e6;

    TreasuryLiquiditySource internal liquidity;

    function _wireFunding() internal override {
        liquidity = new TreasuryLiquiditySource(usdc, admin);
        vm.startPrank(admin);
        credit.setLiquiditySource(address(liquidity));
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);
    }

    /// @dev The migration itself: close a workout with a residual, dispose the lot the way a DexFi
    ///      redemption requires, then move the manager's pointer to a fresh auction. Every clause of
    ///      `checkAuctionSwap` is asserted satisfied rather than assumed.
    function _repointAfterClose() internal returns (uint256 id, LiquidationAuction fresh) {
        id = _closedWorkoutWithResidual();

        vm.prank(admin);
        auction.disposeWorkoutLot(id, makeAddr("dexfiRedemptionDesk"));
        assertEq(auction.liveAuctionCount(), 0, "fixture: no live auctions");
        assertEq(auction.openWorkoutCount(), 0, "fixture: no open workouts");
        assertEq(vault.bondCount(address(auction)), 0, "fixture: no held lot");

        fresh = _freshAuction();
        vm.prank(admin);
        credit.setLiquidationAuction(address(fresh));
        assertEq(credit.liquidationAuction(), address(fresh), "the manager moved on");
    }

    /// @notice CONTROL. With the pointer unmoved, the post-close recovery lands. This is the
    ///         behaviour the finding is measured against, not a claim about the fix.
    function test_R46_control_theRecoveryLandsWhileTheAuctionPointerIsUnmoved() public {
        uint256 id = _closedWorkoutWithResidual();
        uint256 writtenDown = _writtenDown(id);
        assertGt(writtenDown, 0, "control: there is a residual to recover");

        uint256 pendingBefore = credit.pendingPrincipal();
        _fundRelayer(relayer, writtenDown);
        vm.prank(relayer);
        auction.workoutSettleAfterClose(id, writtenDown);

        assertEq(
            credit.pendingPrincipal() - pendingBefore,
            writtenDown,
            "control: the recovery reached the balance sheet that bore it"
        );
        assertEq(_writtenDown(id), 0, "control: the write-down is discharged");
    }

    /// @notice THE FIX. After a legal repoint the former auction still delivers, and
    ///         `pendingPrincipal` rises by exactly `writtenDown`.
    /// @dev Neuter: restore `_requireAuction()` at the head of `recoverWrittenDownLoss` and this
    ///      goes red on `NotLiquidationAuction`, which is the revert the finding measured.
    function test_R46_theRecoveryLandsAfterALegalAuctionRepoint() public {
        (uint256 id, LiquidationAuction fresh) = _repointAfterClose();
        uint256 writtenDown = _writtenDown(id);
        assertGt(writtenDown, 0, "there is a residual to recover");

        assertTrue(credit.wasLiquidationAuction(address(auction)), "the outgoing auction is on the roll");
        assertTrue(credit.wasLiquidationAuction(address(fresh)), "and so is the incoming one");

        uint256 pendingBefore = credit.pendingPrincipal();
        _fundRelayer(relayer, writtenDown);
        vm.prank(relayer);
        auction.workoutSettleAfterClose(id, writtenDown);

        assertEq(
            credit.pendingPrincipal() - pendingBefore,
            writtenDown,
            "the recovery lands even though the manager has repointed"
        );
        assertEq(_writtenDown(id), 0, "the write-down is discharged");
        assertEq(usdc.balanceOf(relayer), 0, "the relayer paid for it, as always");
    }

    /// @notice The bound on the fix. A former auction reaches `recoverWrittenDownLoss` and no other
    ///         auction-gated leg: `writeDownLoss`, `creditLiquidationProceeds` and `resolveBounty`
    ///         still refuse it by name, so it can open no new work here.
    /// @dev The three are the whole of the `_requireAuction()` census in `CreditManager` besides
    ///      the recovery leg. Re-derive with `grep -n "_requireAuction()" src/CreditManager.sol`
    ///      before adding a fifth caller.
    function test_R46_aFormerAuctionReachesNoOtherAuctionGatedLeg() public {
        (uint256 id,) = _repointAfterClose();
        id; // the workout is not needed here; the pointer having moved is.

        address former = address(auction);

        vm.prank(former);
        vm.expectRevert(CreditManager.NotLiquidationAuction.selector);
        credit.writeDownLoss(alice, 1, 1e6);

        vm.prank(former);
        vm.expectRevert(CreditManager.NotLiquidationAuction.selector);
        credit.creditLiquidationProceeds(alice, 1e6, 0);

        vm.prank(former);
        vm.expectRevert(CreditManager.NotLiquidationAuction.selector);
        credit.resolveBounty(1, true);
    }

    /// @notice The negative the finding left INFERRED, executed. A former auction pushing USDC in
    ///         against an arbitrary borrower opens nothing: the destination is read from
    ///         `lossBearerOf` / `lossFunderOf`, never from the caller or the argument, and the
    ///         caller pays. It is a donation to the live source and nothing else.
    function test_R46_aFormerAuctionCannotOpenAnythingByPushingCashIn() public {
        (uint256 id,) = _repointAfterClose();
        id;

        address bob = makeAddr("bob");
        bond.mint(bob, 1_000);
        vm.startPrank(bob);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();

        // Bob has no write-down of any kind, so both records are the zero sentinel.
        assertEq(credit.lossBearerOf(bob), address(0), "bob bore nothing");
        assertEq(credit.lossFunderOf(bob), address(0), "and nothing was funded for him");

        address former = address(auction);
        uint256 push = 5_000e6;
        usdc.mint(former, push);
        vm.prank(former);
        usdc.approve(address(credit), push);

        uint256 pendingBefore = credit.pendingPrincipal();
        uint256 debtBefore = credit.debtOf(bob);
        uint256 bondsBefore = vault.bondCount(bob);

        vm.prank(former);
        credit.recoverWrittenDownLoss(bob, 999, push); // an id nothing was written down under

        // The caller paid, the money is spoken for by the live source, and bob gained nothing.
        assertEq(usdc.balanceOf(former), 0, "the caller paid");
        assertEq(credit.pendingPrincipal() - pendingBefore, push, "it is owed to the live source");
        assertEq(credit.debtOf(bob), debtBefore, "no debt was created or forgiven for bob");
        assertEq(vault.bondCount(bob), bondsBefore, "no collateral moved");
        assertEq(credit.insuranceFund(), 0, "and it did not become insurance either");
    }

    /// @notice RECORDED, now moot. The way back was refused `AuctionHasLiveWork` the moment the new
    ///         auction had one liquidation, which is what made the brick permanent rather than
    ///         awkward. The refusal is unchanged and deliberately so - it is the guard that stops a
    ///         repoint stranding live work - and it no longer strands anything, because the leg
    ///         above does not need the pointer moved back.
    function test_R46_theWayBackIsStillRefusedButTheRecoveryNoLongerNeedsIt() public {
        (uint256 id, LiquidationAuction fresh) = _repointAfterClose();
        uint256 writtenDown = _writtenDown(id);

        vm.prank(admin);
        vault.setLiquidationAuction(address(fresh));
        vm.prank(admin);
        fresh.setCreditManager(address(credit));

        // A second borrower goes underwater on the new auction.
        address bob = makeAddr("bob");
        bond.mint(bob, 1_000);
        vm.startPrank(bob);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();

        oracle.setNav(NAV);
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(bob);
        credit.borrow(debt);
        oracle.setNav(_crashedNav(debt));
        vm.prank(keeper);
        credit.liquidate(bob);

        // Reads first: `vm.prank` is spent by the next external call, a view in an `expectRevert`
        // argument list included.
        uint256 liveNow = fresh.liveAuctionCount();
        assertGt(liveNow, 0, "the new auction has live work");
        vm.expectRevert(abi.encodeWithSelector(CreditManager.AuctionHasLiveWork.selector, liveNow));
        vm.prank(admin);
        credit.setLiquidationAuction(address(auction));

        // And the recovery lands anyway, from the auction that is no longer named anywhere.
        _fundRelayer(relayer, writtenDown);
        vm.prank(relayer);
        auction.workoutSettleAfterClose(id, writtenDown);
        assertEq(_writtenDown(id), 0, "the write-down is discharged with the pointer still moved on");
    }
}

/// @title Round 46 finding 2, CLOSED: the pool leg of the same recovery, across a MANAGER migration.
/// @notice Reached independently by three fleet agents from three directions in one round, and held
///         under the audit freeze until the external reviewers filed it as their L-01. The bearer
///         recorded at loss time is a snapshot - which is round 22 finding 9, and right - while
///         `LenderPool.recoverLoss` used to check `msg.sender` against the pool's own LIVE manager.
///         So a sanctioned manager migration left this manager calling a pool that refused it: the
///         revert propagated out of `workoutSettleAfterClose` and `writtenDown` was never paid down.
///
///         `CreditWiring.checkLenderPoolSwap` cannot cover it: it runs when the manager's
///         `lenderPool` pointer moves, not when the pool's manager pointer does, and its own comment
///         treats `NotCreditManager()` as a pass. The remedy the manager's docstring once named -
///         "retry once the pointer is repaired" - is not one either: repairing means pointing the
///         pool back at a manager it deliberately migrated off, and once the replacement has made
///         one ordinary borrow that repair reverts `LenderPool.PrincipalOutstanding`.
///
/// @dev **The fix is `LenderPool.wasCreditManager`**, stamped in `setCreditManager` and read by
///      `recoverLoss` alone, the mirror of `CreditManager.wasLiquidationAuction`. The pull and the
///      `ClaimDeficitCovered` event name `msg.sender`, because a gate change alone leaves the pool
///      pulling from the LIVE pointer and the former manager's delivery reverts
///      `ERC20InsufficientAllowance` against a successor that never approved anything. The tests
///      below were the known-gap pins that asserted the broken behaviour; they are the regressions
///      now. Three manager-side fixes were built first and all three are refused, each by a
///      different agent's execution rather than by argument:
///
///      - park into `owedToSource`, drain with `flushPrincipalTo`. **+140 runtime bytes.** Refused
///        twice: it breaks `pool.outstandingPrincipal == pendingPrincipal + owedToSource +
///        totalDebt` for the whole life of a park nothing bounds (measured, left 0 against right
///        628750000), and its drain falls through to a bare push the pool never recognises - 314.375000 USDC arriving with `totalAssets()`, `previewRedeem` and
///        `lifetimeLossRecovered` all unmoved, while `w.writtenDown` spends down anyway. A permanent
///        refusal becomes a permanent loss.
///      - a pot of its own, `owedToBearer` plus a permissionless `flushRecoveryTo`. **+561 runtime
///        bytes as built, +484 for a leaner variant.** Refused on reachability: the drain calls
///        `recoverLoss` from the retired manager, so the park is dischargeable only by pointing the
///        pool back, which the replacement's first borrow makes impossible. In the live case it
///        takes a relayer's USDC into a contract that can never deliver it.
///
///      **This is a different failure from finding 1 and its fix does not touch it.** The auction
///      side never reads the pool's gate: `wasLiquidationAuction` closes an auction repoint and can
///      close nothing here, which is why the two shipped separately.
contract R46PoolRepointRecoveryTest is R46RecoveryFixture {
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;

    address internal lender = makeAddr("lender");
    LenderPool internal pool;

    function _wireFunding() internal override {
        pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(address(harvester));
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        harvester.setLenderPool(address(pool));
        adapter.setYieldRecipient(address(harvester));
        vm.stopPrank();

        usdc.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();
    }

    /// @notice CONTROL. While the pool still names this manager, the recovery lands and is booked as
    ///         a loss recovery. The regression below shows the same delivery after the repoint.
    function test_R46_control_theRecoveryLandsWhileThePoolStillNamesThisManager() public {
        uint256 id = _closedWorkoutWithResidual();
        uint256 writtenDown = _writtenDown(id);
        assertGt(writtenDown, 0, "control: there is a residual to recover");
        assertEq(credit.lossBearerOf(alice), address(pool), "the pool is the recorded bearer");

        _fundRelayer(relayer, writtenDown);
        vm.prank(relayer);
        auction.workoutSettleAfterClose(id, writtenDown);

        assertEq(pool.lifetimeLossRecovered(), writtenDown, "control: booked as a loss recovery");
        assertEq(_writtenDown(id), 0, "control: the write-down is discharged");
    }

    /// @notice REGRESSION, formerly the known-gap pin. A whole manager migration - vault, pool and
    ///         auction all pointed at a replacement - and the closed workout's recovery still lands
    ///         on the pool that bore it, booked as a loss recovery, with the write-down discharged.
    /// @dev Before the fix this asserted `LenderPool.NotCreditManager` on the same call: the pool
    ///      refusing a caller it no longer recognised. Both counters `LenderPool.setCreditManager`
    ///      guards on are already zero after the forced close, so the pool does not refuse the
    ///      migration. That is what makes this reachable rather than exotic: it is the ordinary
    ///      migration, taken at the ordinary moment.
    ///
    ///      `CollateralVault.setCreditManager` refuses while the closed lot is still parked, so the
    ///      migration below disposes first - which is exactly what `_repointAfterClose` above
    ///      already does, and what a DexFi redemption requires regardless.
    ///
    ///      The pull comes from the FORMER manager's own allowance, never the successor's: the
    ///      replacement has approved the pool nothing, and the delivery lands anyway.
    function test_R46_theRecoveryLandsAfterALegalPoolRepoint() public {
        uint256 id = _closedWorkoutWithResidual();
        uint256 writtenDown = _writtenDown(id);
        assertGt(writtenDown, 0, "there is a residual to recover");
        assertEq(credit.lossBearerOf(alice), address(pool), "the pool is the recorded bearer");

        // The replacement, and the migration nothing refuses.
        CreditManager replacement = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        assertEq(pool.outstandingPrincipal(), 0, "fixture: nothing left out on loan");
        assertEq(pool.totalImpairment(), 0, "fixture: the close released the mark");
        vm.startPrank(admin);
        auction.disposeWorkoutLot(id, makeAddr("dexfiRedemptionDesk"));
        vault.setCreditManager(address(replacement));
        pool.setCreditManager(address(replacement));
        auction.setCreditManager(address(replacement));
        vm.stopPrank();
        assertEq(pool.creditManager(), address(replacement), "fixture: the pool moved on");
        assertTrue(pool.wasCreditManager(address(credit)), "the outgoing manager is remembered");
        assertTrue(pool.wasCreditManager(address(replacement)), "and so is the live one");
        assertEq(usdc.allowance(address(replacement), address(pool)), 0, "the successor approved nothing");

        // The workout still names the manager that bore the loss (round 22 finding 8). That
        // manager still names the pool that bore it (round 22 finding 9). The pool now remembers
        // the manager it migrated off, and that is the whole of the fix.
        _fundRelayer(relayer, writtenDown);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        uint256 assetsBefore = pool.totalAssets();
        vm.prank(relayer);
        auction.workoutSettleAfterClose(id, writtenDown);

        assertEq(_writtenDown(id), 0, "the write-down is discharged");
        assertEq(usdc.balanceOf(relayer), 0, "the relayer paid");
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, writtenDown, "the bearer received the tranche");
        assertEq(pool.lifetimeLossRecovered(), writtenDown, "booked as a loss recovery");
        assertEq(usdc.balanceOf(address(replacement)), 0, "the successor paid nothing");
        // Rated as a stream for the lenders who bore the loss, not de-recognised: flat at the
        // instant of delivery, and the whole tranche a full stream later.
        assertEq(pool.totalAssets(), assetsBefore, "the recovery is streamed, not stepped");
        vm.warp(pool.yieldStreamEndsAt() + 1);
        assertEq(pool.totalAssets(), assetsBefore + writtenDown, "the lenders who bore the loss are reached");
    }

    /// @notice The one route into that money is the auction's return leg, and it is open: a relayer
    ///         cannot bypass the auction, and does not need to.
    /// @dev `writeDownLoss` already cleared the debt, so `repayFor` reverts `NoDebt`; and
    ///      `workoutSettleAfterClose` is the only writer of `Workout.writtenDown`, so a relayer
    ///      cannot deliver to the manager directly either. Before the fix this test ended with the
    ///      write-down still standing; it now ends with the auction route discharging it.
    function test_R46_theOnlyRouteIntoTheRecoveryIsTheAuctionAndItIsOpen() public {
        uint256 id = _closedWorkoutWithResidual();
        uint256 writtenDown = _writtenDown(id);
        vm.prank(admin);
        pool.setCreditManager(makeAddr("replacement"));

        assertEq(credit.debtOf(alice), 0, "the write-down cleared the book");
        usdc.mint(relayer, writtenDown);
        vm.startPrank(relayer);
        usdc.approve(address(credit), writtenDown);
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.repayFor(alice, writtenDown);

        vm.expectRevert(CreditManager.NotLiquidationAuction.selector);
        credit.recoverWrittenDownLoss(alice, id, writtenDown);
        vm.stopPrank();
        assertEq(_writtenDown(id), writtenDown, "neither bypass discharged it");

        _fundRelayer(relayer, writtenDown);
        vm.prank(relayer);
        auction.workoutSettleAfterClose(id, writtenDown);
        assertEq(_writtenDown(id), 0, "the auction route discharged it");
        assertEq(pool.lifetimeLossRecovered(), writtenDown, "and the pool booked it");
    }

    /// @notice A former manager reaches no other manager-gated leg of the pool. Every
    ///         `NotCreditManager` site is enumerated and called as the retired manager after the
    ///         repoint: `lend`, `repayPrincipal`, `socialiseLoss`, `impair`, `releaseImpairment`
    ///         and `setLossReserves` all refuse. `recoverLoss` is the one door that opens, and it
    ///         only takes the caller's own money.
    /// @dev The mirror of `test_R46_aFormerAuctionReachesNoOtherAuctionGatedLeg`. The six refusals
    ///      are the bound `wasCreditManager` states for itself; a seventh `NotCreditManager` site
    ///      added to the pool without a line here is what this test exists to catch.
    function test_R46_aFormerManagerReachesNoOtherManagerGatedLeg() public {
        uint256 id = _closedWorkoutWithResidual();
        vm.startPrank(admin);
        auction.disposeWorkoutLot(id, makeAddr("dexfiRedemptionDesk"));
        pool.setCreditManager(makeAddr("replacement"));
        vm.stopPrank();

        address former = address(credit);
        assertTrue(pool.wasCreditManager(former), "fixture: the former manager is remembered");
        assertTrue(pool.creditManager() != former, "fixture: and is no longer live");

        vm.prank(former);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.lend(1e6);

        vm.prank(former);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.repayPrincipal(1e6);

        vm.prank(former);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.socialiseLoss(1e6);

        vm.prank(former);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.impair(alice, 1e6);

        vm.prank(former);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.releaseImpairment(alice);

        vm.prank(former);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.setLossReserves(1e6, 1e6);

        // The one open door, and it takes only the caller's own USDC.
        usdc.mint(former, 1e6);
        uint256 formerBefore = usdc.balanceOf(former);
        vm.prank(former);
        usdc.approve(address(pool), 1e6);
        vm.prank(former);
        pool.recoverLoss(1e6);
        assertEq(formerBefore - usdc.balanceOf(former), 1e6, "the former manager paid");
        assertEq(pool.lifetimeLossRecovered(), 1e6, "and the pool booked a recovery");

        // A stranger the pool never named is still refused on that door.
        address never = makeAddr("neverAManager");
        assertFalse(pool.wasCreditManager(never), "fixture: never wired");
        vm.prank(never);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.recoverLoss(1e6);
    }
}
