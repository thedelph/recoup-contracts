// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
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
import {RiskParams} from "../src/RiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Round 55, agent A1 (redacted). The auction's workout lifecycle read from the contracts'
///         own text and executed: a forced close reconciled to the wei from the manager's own
///         events, two open lots with one forced, two clean-close bookings on two bearers, the
///         wiring doors under four lot states, a manager that satisfies every probe and lacks one
///         selector, the permissionless orderings between a close and a repoint, and gas.
///
/// @dev Fixture: the real `LenderPool` as both liquidity source and loss sink, so the funder's
///      side of every reconciliation is a real balance sheet rather than a treasury float that
///      clamps every reserve to zero. Copied rather than inherited: inheriting a fixture inherits
///      its whole suite, and this file's counts must be its own.
contract R55A01_WorkoutLifecycle is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal lender = makeAddr("lender");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");
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
    LenderPool internal pool;
    RiskParams internal riskParams;

    // Candidates for the door census, held in storage so the census stays under the stack limit.
    CreditManager internal m2x;
    LiquidationAuction internal a2x;
    EpochHarvester internal hx;
    DirectCallAdapter internal ad2x;

    bytes32 internal constant SIG_SWEPT = keccak256("WorkoutYieldSwept(uint256)");
    bytes32 internal constant SIG_FUNDED = keccak256("InsuranceFunded(address,uint256)");
    bytes32 internal constant SIG_WRITTEN = keccak256("LossWrittenDown(address,uint256,uint256,uint256)");
    bytes32 internal constant SIG_SOCIALISED = keccak256("LossSocialised(address,uint256)");

    bytes4 internal constant LIVE_WORK = bytes4(keccak256("AuctionHasLiveWork(uint256)"));
    bytes4 internal constant NOT_LIVE = bytes4(keccak256("CreditManagerNotLive(address)"));
    bytes4 internal constant HAS_DEBT = bytes4(keccak256("CreditManagerHasDebt(uint256)"));
    bytes4 internal constant ADAPTER_LIVE = bytes4(keccak256("AdapterHasLivePosition(uint256)"));
    bytes4 internal constant ADMITTED = bytes4(0);

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

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
        credit = _freshManager();
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

        usdc.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        _seat(alice);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _freshManager() internal returns (CreditManager) {
        return new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
    }

    function _secondAuction() internal returns (LiquidationAuction) {
        return new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
    }

    function _seat(address who) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    function _crashedNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS) / 2;
    }

    /// @dev Borrow at the ceiling as `who` at the healthy NAV, crash, liquidate. Returns the id.
    function _openAuctionFor(address who, CreditManager cm) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(who);
        cm.borrow(debt);
        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        cm.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: the auction did not open");
    }

    function _expire(uint256 id) internal {
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
    }

    function _stream(CreditManager cm, uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(cm), amount);
        cm.receiveYield(amount);
        cm.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION);
        cm.accrueYield();
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), type(uint256).max);
    }

    /// @dev Repay a workout in full through the auction's own tranche door, plus the fixed penalty.
    function _settleInFull(address who, CreditManager cm, uint256 id) internal {
        uint256 payment = cm.currentDebtOf(who) * 2;
        _fund(payer, payment);
        vm.prank(payer);
        auction.workoutSettle(id, payment);
        assertEq(cm.currentDebtOf(who), 0, "fixture: the debt survived the settlement");
    }

    /// @dev A stranger clears the debt directly on the manager, touching no workout state.
    function _repayInFullDirect(address who) internal {
        uint256 owed = credit.currentDebtOf(who);
        usdc.mint(payer, owed);
        vm.startPrank(payer);
        usdc.approve(address(credit), owed);
        credit.repayFor(who, owed);
        vm.stopPrank();
    }

    function _workout(uint256 id)
        internal
        view
        returns (
            LiquidationAuction.WorkoutStatus status,
            uint256 bondCount,
            uint256 recovered,
            uint256 writtenDown,
            address bearer,
            uint256 yieldOwed
        )
    {
        (,, status, bondCount,, recovered,, writtenDown, bearer,, yieldOwed) = auction.workouts(id);
    }

    function _indexAtOpen(uint256 id) internal view returns (uint256 idx) {
        (,,,,,,,,, idx,) = auction.workouts(id);
    }

    /// @dev Decode the forced close's own split from the logs it emitted, so the reconciliation
    ///      reads the figures the contracts wrote rather than figures this test re-derives.
    function _decodeForcedClose(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 swept, uint256 funded, uint256 loss, uint256 fromInsurance, uint256 socialised, uint256 pooled)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 t = logs[i].topics[0];
            if (t == SIG_SWEPT) {
                swept = abi.decode(logs[i].data, (uint256));
            } else if (t == SIG_FUNDED) {
                funded += abi.decode(logs[i].data, (uint256));
            } else if (t == SIG_WRITTEN) {
                (loss, fromInsurance, socialised) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            } else if (t == SIG_SOCIALISED) {
                pooled = abi.decode(logs[i].data, (uint256));
            }
        }
    }

    function _cmClaims(CreditManager cm) internal view returns (uint256) {
        return cm.totalClaimable() + cm.undistributedYield() + cm.pendingPrincipal() + cm.totalOwedToSources()
            + cm.insuranceFund() + cm.totalBountyEscrowed() + cm.totalBountyParked() + cm.totalBountyOwed();
    }

    /// @dev A second era: fresh manager, its own pool, wired on both sides, the vault and the
    ///      auction repointed. Requires no live work, no parked lot and zero debt on the outgoing.
    function _migrate() internal returns (CreditManager m2, LenderPool poolB) {
        m2 = _freshManager();
        poolB = new LenderPool(IERC20(address(usdc)), admin);
        address lenderB = makeAddr("lenderB");
        usdc.mint(lenderB, LENDER_DEPOSIT);
        vm.startPrank(lenderB);
        usdc.approve(address(poolB), type(uint256).max);
        poolB.deposit(LENDER_DEPOSIT, lenderB);
        vm.stopPrank();

        vm.startPrank(admin);
        poolB.setCreditManager(address(m2));
        poolB.setEpochHarvester(harvester);
        m2.setLiquiditySource(address(poolB));
        m2.setLenderPool(address(poolB));
        m2.setEpochHarvester(harvester);
        vault.setCreditManager(address(m2));
        auction.setCreditManager(address(m2));
        m2.setLiquidationAuction(address(auction));
        vm.stopPrank();
    }

    // ── 1. The forced close, to the wei ──────────────────────────────────────

    /// @notice Every wei of a forced close is accounted: the lot's own accrual reaches the fund,
    ///         the fund covers the residual as far as it reaches, the pool bears exactly the rest,
    ///         the borrower is credited nothing, the keeper keeps the prepaid bounty, and the
    ///         auction ends holding nothing beyond rewards. Then the late tranche repays exactly
    ///         what was socialised and not a wei more.
    struct Before {
        uint256 aliceCash;
        uint256 pot;
        uint256 residual;
        uint256 insurance;
        uint256 principal;
        uint256 poolOut;
        uint256 poolLoss;
        uint256 cmBalance;
    }

    struct Split {
        uint256 swept;
        uint256 funded;
        uint256 loss;
        uint256 fromInsurance;
        uint256 socialised;
        uint256 pooled;
    }

    Before internal b;

    function _snapshotBefore() internal {
        b.pot = credit.claimableOf(address(auction)) + credit.pendingYieldOf(address(auction));
        b.residual = credit.currentDebtOf(alice);
        b.insurance = credit.insuranceFund();
        b.principal = credit.pendingPrincipal();
        b.poolOut = pool.outstandingPrincipal();
        b.poolLoss = pool.lifetimeSocialisedLoss();
        b.cmBalance = usdc.balanceOf(address(credit));
    }

    function _forceClose(uint256 id) internal returns (Split memory s) {
        vm.recordLogs();
        vm.prank(stranger);
        auction.closeWorkout(id);
        (s.swept, s.funded, s.loss, s.fromInsurance, s.socialised, s.pooled) = _decodeForcedClose(vm.getRecordedLogs());
        emit log_named_uint("MEASURED lot pot before the close", b.pot);
        emit log_named_uint("MEASURED residual", b.residual);
        emit log_named_uint("MEASURED WorkoutYieldSwept", s.swept);
        emit log_named_uint("MEASURED LossWrittenDown.loss", s.loss);
        emit log_named_uint("MEASURED LossWrittenDown.fromInsurance", s.fromInsurance);
        emit log_named_uint("MEASURED LossWrittenDown.socialised", s.socialised);
    }

    function test_control_forcedCloseReconcilesToTheWei() public {
        uint256 id = _openAuctionFor(alice, credit);
        b.aliceCash = usdc.balanceOf(alice);
        assertEq(b.aliceCash, _maxBorrowAtCeiling() - Config.LIQUIDATION_CALL_BOUNTY, "borrower got debt less bounty");
        _expire(id);
        assertEq(
            credit.bountyOwedTo(keeper), Config.LIQUIDATION_CALL_BOUNTY, "expiry pays the keeper the parked bounty"
        );

        _stream(credit, 400e6);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        _snapshotBefore();
        assertEq(usdc.balanceOf(address(auction)), 0, "fixture: the auction holds nothing before the close");
        assertGt(b.pot, 0, "fixture: the lot earned nothing");
        assertGt(b.residual, 0, "fixture: nothing to force");

        Split memory s = _forceClose(id);

        assertEq(s.swept, b.pot, "the forced close swept something other than the lot's own pot");
        assertEq(s.funded, b.pot, "InsuranceFunded disagrees with the sweep");
        assertEq(s.loss, b.residual, "the write-down is not the residual");
        assertEq(s.fromInsurance + s.socialised, b.residual, "the split does not sum to the residual");
        uint256 fundAtWriteDown = b.insurance + b.pot;
        assertEq(
            s.fromInsurance, b.residual < fundAtWriteDown ? b.residual : fundAtWriteDown, "cover is min(residual, fund)"
        );
        assertEq(s.pooled, s.socialised, "the pool was charged something other than the socialised part");
        assertEq(pool.lifetimeSocialisedLoss() - b.poolLoss, s.socialised, "pool ledger disagrees");
        assertEq(b.poolOut - pool.outstandingPrincipal(), s.socialised, "outstandingPrincipal moved by something else");
        _assertWorkoutAfterForce(id, s.socialised);

        assertEq(credit.insuranceFund(), b.insurance + b.pot - s.fromInsurance, "insurance: +pot -cover");
        assertEq(credit.pendingPrincipal() - b.principal, s.fromInsurance, "funder: cover on its way home");
        assertEq(usdc.balanceOf(address(credit)), b.cmBalance, "no USDC left the manager: the write-down relabels");
        assertGe(usdc.balanceOf(address(credit)), _cmClaims(credit), "manager solvency");
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards(), "auction holds only rewards");
        assertEq(auction.totalUnclaimedRewards(), 0, "no fill, so no reward");
        assertEq(credit.claimableOf(address(auction)), 0, "pot fully pulled");
        assertEq(credit.pendingYieldOf(address(auction)), 0, "nothing pending on the lot at the close");
        assertEq(credit.claimableOf(alice), 0, "the defaulter was credited nothing");
        assertEq(usdc.balanceOf(alice), b.aliceCash, "the defaulter's cash did not move");
        assertEq(credit.debtOf(alice), 0, "the debt is gone");
        assertEq(vault.bondCount(alice), 0, "the lot is not the borrower's");
        assertEq(vault.bondCount(address(auction)), BONDS, "the lot is still parked");
        assertEq(pool.impairmentOf(alice), 0, "the mark is released");

        _lateTrancheExactly(id, s.socialised);
    }

    function _assertWorkoutAfterForce(uint256 id, uint256 socialised) internal view {
        (,, uint256 recovered, uint256 writtenDown, address bearer,) = _workout(id);
        assertEq(writtenDown, socialised, "writtenDown is not the socialised part");
        assertEq(recovered, 0, "nothing was recovered");
        assertEq(bearer, address(credit), "the bearer is the live manager");
    }

    function _lateTrancheExactly(uint256 id, uint256 socialised) internal {
        _fund(payer, socialised + 1);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, socialised + 1);
        assertEq(usdc.balanceOf(payer), 1, "the tranche was clamped to what was written down");
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, socialised, "the pool received the recovery");
        (,, uint256 recovered, uint256 writtenDown,,) = _workout(id);
        assertEq(writtenDown, 0, "nothing left written down");
        assertEq(recovered, socialised, "recovered records the tranche");
        _fund(payer, 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NothingLeftToRecover.selector, id));
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, 1);
    }

    // ── 2. Two open lots, one forced ─────────────────────────────────────────

    /// @notice A forced close spends its own lot's accrual and only that: the sibling lot's accrual
    ///         stays reserved against both sweeps, is booked to its borrower on a clean close and is
    ///         paid in full.
    function test_control_forcedCloseSpendsOnlyItsOwnLotBesideAnOpenSibling() public {
        _seat(bob);
        oracle.setNav(NAV);
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        vm.prank(bob);
        credit.borrow(debt);
        oracle.setNav(_crashedNav());
        vm.startPrank(keeper);
        credit.liquidate(alice);
        credit.liquidate(bob);
        vm.stopPrank();
        uint256 idA = auction.auctionOf(alice);
        uint256 idB = auction.auctionOf(bob);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(idA);
        auction.expireToWorkout(idB);
        assertEq(vault.bondCount(address(auction)), 2 * BONDS, "both lots parked");

        _stream(credit, 1_000e6);
        uint256 accrualA = credit.yieldAccruedOn(BONDS, _indexAtOpen(idA));
        uint256 accrualB = credit.yieldAccruedOn(BONDS, _indexAtOpen(idB));
        emit log_named_uint("MEASURED lot A accrual", accrualA);
        emit log_named_uint("MEASURED lot B accrual", accrualB);

        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepWorkoutYieldToInsurance();

        skip(Config.WORKOUT_MAX_DURATION + 1);
        uint256 insuranceBefore = credit.insuranceFund();
        vm.recordLogs();
        vm.prank(stranger);
        auction.closeWorkout(idA);
        (uint256 swept,,, uint256 fromInsurance,,) = _decodeForcedClose(vm.getRecordedLogs());
        emit log_named_uint("MEASURED swept by A's forced close", swept);
        assertLe(swept, accrualA + 2, "the forced close spent the sibling's backing");
        assertGe(swept + 2, accrualA, "the forced close left its own accrual behind");
        assertEq(
            credit.insuranceFund(),
            insuranceBefore + swept - fromInsurance,
            "insurance moved by the swept part net of cover"
        );

        assertGe(usdc.balanceOf(address(auction)) + 2, accrualB, "B's backing is not here after the pull");
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepFreeBalanceToInsurance();
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        auction.sweepWorkoutYieldToInsurance();

        _settleInFull(bob, credit, idB);
        auction.closeWorkout(idB);
        (,,,,, uint256 owedB) = _workout(idB);
        emit log_named_uint("MEASURED B booked", owedB);
        assertGe(owedB + 2, accrualB, "B was under-booked");
        assertLe(owedB, accrualB, "B was over-booked");
        uint256 bobBefore = usdc.balanceOf(bob);
        auction.claimWorkoutYield(idB);
        assertEq(usdc.balanceOf(bob) - bobBefore, owedB, "B was not paid its booking in full");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "nothing booked remains");
        uint256 dust = usdc.balanceOf(address(auction)) - auction.totalUnclaimedRewards();
        emit log_named_uint("MEASURED unbooked dust left on the auction", dust);
        assertLe(dust, 2, "the auction holds more than rewards and rounding dust");
    }

    // ── 3. Two bookings, two bearers ─────────────────────────────────────────

    /// @notice Two clean-close bookings on two managers coexist, each bearer's pot pays its own
    ///         booking, and the second borrower is refused until the first bearer's backing has
    ///         been pulled here by anyone.
    function test_control_twoBookingsOnTwoBearersEachPaidByItsOwnPot() public {
        uint256 idA = _openAuctionFor(alice, credit);
        _expire(idA);
        _stream(credit, 400e6);
        _settleInFull(alice, credit, idA);
        auction.closeWorkout(idA);
        (,,,,, uint256 owedA) = _workout(idA);
        assertGt(owedA, 0, "fixture: A booked nothing");
        vm.prank(admin);
        auction.disposeWorkoutLot(idA, stranger);
        assertGe(credit.claimableOf(address(auction)), owedA, "fixture: A's backing is not on M1");

        (CreditManager m2,) = _migrate();
        _seat(bob);
        uint256 idB = _openAuctionFor(bob, m2);
        _expire(idB);
        _stream(m2, 400e6);
        _settleInFull(bob, m2, idB);
        auction.closeWorkout(idB);
        (,,,, address bearerB, uint256 owedB) = _workout(idB);
        (,,,, address bearerA,) = _workout(idA);
        assertEq(bearerA, address(credit), "A's bearer is M1");
        assertEq(bearerB, address(m2), "B's bearer is M2");
        assertEq(auction.workoutYieldOwedOn(address(credit)), owedA, "split on M1");
        assertEq(auction.workoutYieldOwedOn(address(m2)), owedB, "split on M2");
        assertEq(auction.totalWorkoutYieldOwed(), owedA + owedB, "aggregate");
        emit log_named_uint("MEASURED owedA", owedA);
        emit log_named_uint("MEASURED owedB", owedB);

        // B first, with A's backing still on the detached M1: the reserve counts A's booking as
        // spoken for while its cash is not here, so B is refused or paid short.
        uint256 bobBefore = usdc.balanceOf(bob);
        try auction.claimWorkoutYield(idB) {} catch {}
        uint256 paidBEarly = usdc.balanceOf(bob) - bobBefore;
        emit log_named_uint("MEASURED B paid before M1 was pulled", paidBEarly);
        assertLt(paidBEarly, owedB, "B was paid in full while A's backing was unpulled (the reserve did not bind)");

        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        auction.claimWorkoutYield(idB);
        assertEq(usdc.balanceOf(bob) - bobBefore, owedB, "B was not paid its booking exactly");
        uint256 aliceBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(idA);
        assertEq(usdc.balanceOf(alice) - aliceBefore, owedA, "A was not paid its booking exactly");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "aggregate spent to zero");
        assertEq(auction.workoutYieldOwedOn(address(credit)), 0, "M1 split spent");
        assertEq(auction.workoutYieldOwedOn(address(m2)), 0, "M2 split spent");
        uint256 dust = usdc.balanceOf(address(auction)) - auction.totalUnclaimedRewards();
        emit log_named_uint("MEASURED dust beyond rewards after both claims", dust);
        assertLe(dust, 2, "the auction holds more than rewards and dust");
    }

    // ── 4. The wiring doors, under four lot states ───────────────────────────

    /// @dev One door, from a snapshot, as the owner: the selector it reverted with, or zero.
    function _door(address target, bytes memory data) internal returns (bytes4 s) {
        uint256 snap = vm.snapshotState();
        vm.prank(admin);
        (bool ok, bytes memory ret) = target.call(data);
        vm.revertToState(snap);
        if (ok) return ADMITTED;
        if (ret.length < 4) return bytes4(0xffffffff);
        assembly {
            s := mload(add(ret, 32))
        }
    }

    function _doorVaultCm() internal returns (bytes4) {
        return _door(address(vault), abi.encodeCall(vault.setCreditManager, (address(m2x))));
    }

    function _doorVaultAu() internal returns (bytes4) {
        return _door(address(vault), abi.encodeCall(vault.setLiquidationAuction, (address(a2x))));
    }

    function _doorAuCm() internal returns (bytes4) {
        return _door(address(auction), abi.encodeCall(auction.setCreditManager, (address(m2x))));
    }

    function _doorCmAu() internal returns (bytes4) {
        return _door(address(credit), abi.encodeCall(credit.setLiquidationAuction, (address(a2x))));
    }

    function _doorHarvesterCm() internal returns (bytes4) {
        return _door(address(hx), abi.encodeCall(hx.setCreditManager, (ICreditManager(address(m2x)))));
    }

    function _doorVaultAdapter() internal returns (bytes4) {
        return _door(address(vault), abi.encodeCall(vault.setCustodyAdapter, (ICustodyAdapter(address(ad2x)))));
    }

    function _assertDoors(string memory state, bytes4 vCm, bytes4 vAu, bytes4 aCm, bytes4 cAu, bytes4 hCm, bytes4 vAd)
        internal
    {
        assertEq(_doorVaultCm(), vCm, string.concat(state, ": vault.setCreditManager"));
        assertEq(_doorVaultAu(), vAu, string.concat(state, ": vault.setLiquidationAuction"));
        assertEq(_doorAuCm(), aCm, string.concat(state, ": auction.setCreditManager"));
        assertEq(_doorCmAu(), cAu, string.concat(state, ": credit.setLiquidationAuction"));
        assertEq(_doorHarvesterCm(), hCm, string.concat(state, ": harvester.setCreditManager"));
        assertEq(_doorVaultAdapter(), vAd, string.concat(state, ": vault.setCustodyAdapter"));
    }

    /// @notice Under a live auction, an open workout and a closed-but-parked lot every wiring
    ///         door refuses; the auction's own manager door does not count the parked lot itself
    ///         and is shielded by the vault's; once the lot is disposed a closed workout blocks
    ///         nothing, whatever it still carries.
    function test_negative_everyWiringDoorCountsTheLiveAuctionTheOpenWorkoutAndTheParkedLot() public {
        m2x = _freshManager();
        a2x = _secondAuction();
        hx = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        ad2x = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );

        // S1: a live auction, the debt cleared by a stranger so the debt arm is not what answers.
        uint256 id = _openAuctionFor(alice, credit);
        _assertDoors("S1 with debt", HAS_DEBT, LIVE_WORK, LIVE_WORK, LIVE_WORK, NOT_LIVE, ADAPTER_LIVE);
        _repayInFullDirect(alice);
        _assertDoors("S1 healed", LIVE_WORK, LIVE_WORK, LIVE_WORK, LIVE_WORK, NOT_LIVE, ADAPTER_LIVE);
        auction.cancel(id);

        // S2: an open workout.
        id = _openAuctionFor(alice, credit);
        _expire(id);
        _assertDoors("S2 with debt", HAS_DEBT, LIVE_WORK, LIVE_WORK, LIVE_WORK, NOT_LIVE, ADAPTER_LIVE);
        _repayInFullDirect(alice);
        _assertDoors("S2 repaid", LIVE_WORK, LIVE_WORK, LIVE_WORK, LIVE_WORK, NOT_LIVE, ADAPTER_LIVE);

        // S3: closed, the lot still parked.
        auction.closeWorkout(id);
        assertEq(vault.bondCount(address(auction)), BONDS, "fixture: the lot is parked");
        _assertDoors("S3 parked", LIVE_WORK, LIVE_WORK, NOT_LIVE, LIVE_WORK, NOT_LIVE, ADAPTER_LIVE);
        // The idempotent re-wire of the auction to the SAME manager is admitted here.
        vm.prank(admin);
        auction.setCreditManager(address(credit));

        // S4: disposed. The closed workout still exists and blocks nothing.
        vm.prank(admin);
        auction.disposeWorkoutLot(id, stranger);
        _assertDoors("S4 disposed", ADMITTED, ADMITTED, NOT_LIVE, ADMITTED, NOT_LIVE, ADMITTED);
    }

    // ── 5. A manager that satisfies every probe and lacks one selector ───────

    /// @notice A manager answering the five probed selectors, `totalDebt`, `accYieldPerBond`,
    ///         `debtOf`, `currentDebtOf` and `settleForVault` installs through both doors; once it
    ///         opens an auction through `start`, all three exits revert on the missing
    ///         `resolveBounty` and every wiring door is welded by `liveAuctionCount`.
    function test_negative_aProbeSatisfyingManagerWithoutResolveBountyStrandsALiveAuctionForGood() public {
        ProbeSatisfyingManager stub = new ProbeSatisfyingManager(address(vault), address(riskParams), address(oracle));
        vm.prank(admin);
        vault.setCreditManager(address(stub));
        // Planted through storage rather than the auction's door, so this measures the CONSEQUENCE of
        // such a pointer on both trees; whether the door admits it is `test_fix_...` below.
        _plantAuctionManager(address(stub));
        assertEq(auction.creditManager(), address(stub), "the stub is the auction's manager");

        uint256 id = stub.open(auction, alice, keeper);
        assertEq(auction.liveAuctionCount(), 1, "the stub opened an auction");

        vm.expectRevert(bytes(""));
        auction.cancel(id);

        _fund(bidder, 3_000e6);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, 0));
        auction.bid(id, type(uint256).max);

        skip(Config.AUCTION_DURATION + 1);
        vm.expectRevert(bytes(""));
        auction.expireToWorkout(id);
        assertEq(auction.liveAuctionCount(), 1, "MEASURED: all three exits revert and the auction stands");

        CreditManager m3 = _freshManager();
        LiquidationAuction a3 = _secondAuction();
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, 1));
        vault.setCreditManager(address(m3));
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionHasLiveWork.selector, 1));
        auction.setCreditManager(address(m3));
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, 1));
        vault.setLiquidationAuction(address(a3));
        vm.stopPrank();
    }

    /// @notice The same stub WITH `resolveBounty` resolves cleanly through `cancel`: that one
    ///         selector is the whole difference between a recoverable and a welded state.
    function test_control_theSameStubWithResolveBountyIsResolvable() public {
        ProbeSatisfyingManagerWithResolve stub =
            new ProbeSatisfyingManagerWithResolve(address(vault), address(riskParams), address(oracle));
        vm.startPrank(admin);
        vault.setCreditManager(address(stub));
        auction.setCreditManager(address(stub));
        vm.stopPrank();
        uint256 id = stub.open(auction, alice, keeper);
        auction.cancel(id);
        assertEq(auction.liveAuctionCount(), 0, "resolved");
        CreditManager m3 = _freshManager();
        vm.startPrank(admin);
        vault.setCreditManager(address(m3));
        auction.setCreditManager(address(m3));
        vm.stopPrank();
        assertEq(auction.creditManager(), address(m3), "repointed away from the stub");
    }

    /// @dev Finds the slot holding the current manager pointer by scanning the first sixteen slots
    ///      for the live manager's address, writes the stub there, and asserts by reading it back.
    function _plantAuctionManager(address m) internal {
        bytes32 want = bytes32(uint256(uint160(address(credit))));
        for (uint256 slot = 0; slot < 16; slot++) {
            if (vm.load(address(auction), bytes32(slot)) == want) {
                vm.store(address(auction), bytes32(slot), bytes32(uint256(uint160(m))));
                break;
            }
        }
        assertEq(auction.creditManager(), m, "fixture: the manager slot was not found");
    }

    bytes4 internal constant DOES_NOT_ANSWER = bytes4(keccak256("CreditManagerDoesNotAnswer(bytes4)"));

    /// @notice FIX: the auction's manager door refuses, by name, a manager that cannot answer
    ///         `resolveBounty`, the selector all three exits call bare. Red at the baseline, where
    ///         the door admits it.
    function test_fix_theManagerDoorRefusesAManagerWithoutResolveBountyByName() public {
        ProbeSatisfyingManager stub = new ProbeSatisfyingManager(address(vault), address(riskParams), address(oracle));
        vm.prank(admin);
        vault.setCreditManager(address(stub));
        vm.prank(admin);
        (bool ok, bytes memory ret) = address(auction).call(abi.encodeCall(auction.setCreditManager, (address(stub))));
        assertFalse(ok, "the door admitted a manager that cannot answer resolveBounty");
        assertEq(bytes4(ret), DOES_NOT_ANSWER, "refused, but not by name");
        bytes memory payload = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; i++) {
            payload[i - 4] = ret[i];
        }
        assertEq(abi.decode(payload, (bytes4)), ICreditManager.resolveBounty.selector, "the wrong selector is named");
        assertEq(auction.creditManager(), address(credit), "the pointer did not move");
    }

    /// @notice CONTROL: the genuine manager passes the probe in both wiring orders - before its own
    ///         `setLiquidationAuction` (the probe is refused by name and accepted) and after it
    ///         (the probe returns silently on the unissued id) - and no park is touched.
    function test_control_theGenuineManagerPassesTheProbeInBothWiringOrders() public {
        uint256 snap = vm.snapshotState();
        CreditManager m3 = _freshManager();
        vm.startPrank(admin);
        vault.setCreditManager(address(m3));
        auction.setCreditManager(address(m3)); // before m3.setLiquidationAuction: NotLiquidationAuction by name
        vm.stopPrank();
        assertEq(auction.creditManager(), address(m3), "order one admitted");
        assertEq(m3.totalBountyParked(), 0, "order one touched no park");

        vm.revertToState(snap);
        m3 = _freshManager();
        vm.startPrank(admin);
        vault.setCreditManager(address(m3));
        m3.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(m3)); // after: the unissued id returns silently
        vm.stopPrank();
        assertEq(auction.creditManager(), address(m3), "order two admitted");
        assertEq(m3.totalBountyParked(), 0, "order two touched no park");
    }

    // ── 6. Permissionless orderings between a close and a repoint ────────────

    /// @notice Whatever order the permissionless calls run in between a forced close and the
    ///         repoint, every wei of the lot's post-close accrual ends in an insurance fund, the
    ///         borrower gets none of it, and nothing is left on the auction or stranded on the
    ///         detached manager.
    function test_control_everyOrderBetweenACloseAndARepointEndsWithNothingStranded() public {
        uint256 id = _openAuctionFor(alice, credit);
        _expire(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        _stream(credit, 300e6);
        uint256 accrued = credit.pendingYieldOf(address(auction)) + credit.claimableOf(address(auction));
        assertGt(accrued, 0, "fixture: no post-close accrual");
        emit log_named_uint("MEASURED post-close accrual on the parked lot", accrued);
        uint256 snap = vm.snapshotState();

        // Order A: sweep on the live manager, then dispose, then repoint.
        uint256 insuranceM1Before = credit.insuranceFund();
        auction.sweepWorkoutYieldToInsurance();
        assertEq(credit.insuranceFund() - insuranceM1Before, accrued, "A: sweep delivered the accrual");
        vm.prank(admin);
        auction.disposeWorkoutLot(id, stranger);
        (CreditManager m2A,) = _migrate();
        assertEq(usdc.balanceOf(address(auction)), 0, "A: nothing on the auction");
        assertEq(credit.claimableOf(address(auction)), 0, "A: nothing on M1");
        assertEq(m2A.insuranceFund(), 0, "A: M2 got nothing, M1 kept it");
        assertEq(credit.claimableOf(alice), 0, "A: borrower nothing");

        // Order B: dispose (which settles), repoint, then the stranger's pull and the free sweep.
        vm.revertToState(snap);
        vm.prank(admin);
        auction.disposeWorkoutLot(id, stranger);
        assertEq(credit.claimableOf(address(auction)), accrued, "B: disposal settled the accrual onto M1");
        (CreditManager m2B,) = _migrate();
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        auction.sweepWorkoutYieldToInsurance();
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(usdc.balanceOf(address(auction)), accrued, "B: pulled here");
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        assertEq(m2B.insuranceFund(), accrued, "B: every wei reached the live fund");
        assertEq(usdc.balanceOf(address(auction)), 0, "B: nothing left here");
        assertEq(credit.claimableOf(alice), 0, "B: borrower nothing");
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(id);

        // Order C: settle only, then dispose, repoint, and the pull. Same terminal sums.
        vm.revertToState(snap);
        credit.settle(address(auction));
        vm.prank(admin);
        auction.disposeWorkoutLot(id, stranger);
        (CreditManager m2C,) = _migrate();
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        assertEq(m2C.insuranceFund(), accrued, "C: every wei reached the live fund");
        assertEq(usdc.balanceOf(address(auction)), 0, "C: nothing left here");
    }

    /// @notice A late tranche after a repoint follows the recorded bearer and reaches the pool that
    ///         bore the loss, both while that pool still recognises the bearer and after the pool
    ///         itself has moved to the new manager: `LenderPool.wasCreditManager` remembers the
    ///         retired manager on the recovery leg, the relayer pays, and the written-down figure
    ///         is spent down.
    /// @dev Arm two was a by-design negative (`NotCreditManager`, relayer keeps the money, nothing
    ///      spent down) until the pool learned to remember a former manager. The successor `m2` has
    ///      approved the pool nothing, so the arm also proves the pull comes from the caller.
    function test_regression_aLateTrancheAfterARepointFollowsTheBearerEvenAfterThePoolMovesOn() public {
        uint256 id = _openAuctionFor(alice, credit);
        _expire(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        (,,, uint256 writtenDown,,) = _workout(id);
        assertGt(writtenDown, 0, "fixture: nothing written down");
        vm.prank(admin);
        auction.disposeWorkoutLot(id, stranger);
        (CreditManager m2,) = _migrate();
        assertEq(auction.creditManager(), address(m2), "repointed");

        uint256 snap = vm.snapshotState();
        _fund(payer, writtenDown);
        uint256 poolBefore = usdc.balanceOf(address(pool));
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);
        assertEq(usdc.balanceOf(address(pool)) - poolBefore, writtenDown, "the bearer's pool received the tranche");

        vm.revertToState(snap);
        vm.prank(admin);
        pool.setCreditManager(address(m2));
        assertEq(usdc.allowance(address(m2), address(pool)), 0, "fixture: the successor approved nothing");
        _fund(payer, writtenDown);
        poolBefore = usdc.balanceOf(address(pool));
        uint256 recoveredBefore = pool.lifetimeLossRecovered();
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);
        assertEq(usdc.balanceOf(payer), 0, "the relayer paid");
        assertEq(usdc.balanceOf(address(pool)) - poolBefore, writtenDown, "the bearer's pool received the tranche");
        assertEq(pool.lifetimeLossRecovered() - recoveredBefore, writtenDown, "booked as a loss recovery");
        assertEq(usdc.balanceOf(address(m2)), 0, "the successor paid nothing");
        (,,, uint256 stillWritten,,) = _workout(id);
        assertEq(stillWritten, 0, "the write-down was spent down");
    }

    // ── 7. Gas on the permissionless paths ───────────────────────────────────

    function test_control_gasOnThePermissionlessWorkoutPaths() public {
        uint256 id = _openAuctionFor(alice, credit);
        skip(Config.AUCTION_DURATION + 1);
        uint256 g = gasleft();
        auction.expireToWorkout(id);
        emit log_named_uint("GAS expireToWorkout", g - gasleft());

        _stream(credit, 400e6);
        _fund(payer, 100e6);
        vm.prank(payer);
        g = gasleft();
        auction.workoutSettle(id, 100e6);
        emit log_named_uint("GAS workoutSettle (partial tranche)", g - gasleft());

        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        g = gasleft();
        auction.closeWorkout(id);
        emit log_named_uint("GAS closeWorkout forced, with a lot pot and a pool write-down", g - gasleft());

        (,,, uint256 writtenDown,,) = _workout(id);
        _fund(payer, writtenDown);
        vm.prank(payer);
        g = gasleft();
        auction.workoutSettleAfterClose(id, writtenDown);
        emit log_named_uint("GAS workoutSettleAfterClose", g - gasleft());

        vm.prank(admin);
        auction.disposeWorkoutLot(id, alice);
        vm.prank(alice);
        vault.depositBonds(BONDS);
        uint256 id2 = _openAuctionFor(alice, credit);
        _fund(bidder, 1_000e6);
        vm.prank(bidder);
        g = gasleft();
        auction.bid(id2, type(uint256).max);
        emit log_named_uint("GAS bid (short fill, write-down)", g - gasleft());
    }
}

/// @dev Answers every selector the two wiring doors probe (the round-56 four included), the two
///      views the vault reads on a non-first install, and what `start`, `cancel` and the vault's
///      `reassign` need. Not `resolveBounty`.
contract ProbeSatisfyingManager {
    address internal immutable v;
    address internal immutable r;
    address internal immutable n;

    constructor(address v_, address r_, address n_) {
        v = v_;
        r = r_;
        n = n_;
    }

    function vault() external view returns (address) {
        return v;
    }

    function riskParams() external view returns (address) {
        return r;
    }

    function navOracle() external view returns (address) {
        return n;
    }

    function totalBountyParked() external pure returns (uint256) {
        return 0;
    }

    function yieldAccruedOn(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function accYieldPerBond() external pure returns (uint256) {
        return 0;
    }

    function totalDebt() external pure returns (uint256) {
        return 0;
    }

    function debtOf(address) external pure returns (uint256) {
        return 0;
    }

    function currentDebtOf(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Round 56 (item 236) probes the four members whose absence strands work on the
    ///      auction's door (`accYieldPerBond` is above). `writeDownLoss` is not a view, so the door
    ///      reads its SHAPE: it must refuse by name, as the genuine manager's zero-amount call does.
    ///      Probed AFTER `resolveBounty`, so `test_fix_...WithoutResolveBountyByName` still names
    ///      `resolveBounty` against this stub.
    error ZeroAmount();

    function writeDownLoss(address, uint256, uint256) external pure returns (uint256) {
        revert ZeroAmount();
    }

    function claimableOf(address) external pure returns (uint256) {
        return 0;
    }

    function pendingYieldOf(address) external pure returns (uint256) {
        return 0;
    }

    function settleForVault(address, uint256) external {}

    function refreshImpairment(address) external {}

    function open(LiquidationAuction a, address borrower, address caller) external returns (uint256) {
        return a.start(borrower, caller);
    }
}

contract ProbeSatisfyingManagerWithResolve is ProbeSatisfyingManager {
    constructor(address v_, address r_, address n_) ProbeSatisfyingManager(v_, r_, n_) {}

    function resolveBounty(uint256, bool) external {}
}
