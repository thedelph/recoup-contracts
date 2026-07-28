// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {ILiquiditySource} from "../src/interfaces/ILiquiditySource.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice A liquidity source that under-delivers. Exists to prove `borrow` verifies
///         receipt rather than trusting the source: a short delivery would otherwise
///         be covered silently from the CreditManager's own balance, which belongs to
///         surplus claimants, undistributed yield and the insurance fund.
contract ShortLiquiditySource is ILiquiditySource {
    IERC20 public immutable usdc;
    uint256 public immutable shortfall;

    constructor(IERC20 usdc_, uint256 shortfall_) {
        usdc = usdc_;
        shortfall = shortfall_;
    }

    function lend(uint256 amount) external {
        usdc.transfer(msg.sender, amount - shortfall);
    }

    function repayPrincipal(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    function available() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}

/// @notice A liquidity source that settles a borrower from inside `repayPrincipal`.
///         Models the Phase-4 LenderPool, which will touch CreditManager during its
///         own bookkeeping: `settle` is the one value-moving path without
///         `nonReentrant`, and it increments `pendingPrincipal` via `_settle`.
///
///         Exists to pin the difference between assigning that counter from a pre-call
///         snapshot and decrementing it. Assignment silently erases anything that
///         landed during the call - or, in the other direction, leaves the counter
///         above what is owed so the next settlement pays the excess out of USDC
///         backing `totalClaimable` and the insurance fund.
contract ReentrantLiquiditySource is ILiquiditySource {
    IERC20 public immutable usdc;
    CreditManager public creditManager;
    address public settleTarget;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function wire(CreditManager credit_, address target) external {
        creditManager = credit_;
        settleTarget = target;
    }

    function lend(uint256 amount) external {
        usdc.transfer(msg.sender, amount);
    }

    function repayPrincipal(uint256 amount) external {
        // Re-enter before taking delivery, which is the window that matters.
        if (settleTarget != address(0)) creditManager.settle(settleTarget);
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    function available() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}

/// @notice Phase-2 credit core: borrow, repay, yield application, surplus claims and
///         the LTV/cap/staleness gates (PRD §4.3, §6.1).
///
///         Fixture uses the real 2026-07-24 NAV snapshot so the numbers are the ones
///         the protocol will actually see: 100 bonds at $25.15 is $2,515 of collateral,
///         and 35% of that is exactly 880.25 USDC of borrowing power.
contract CreditManagerTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;

    /// @notice Tolerance for figures that came through the yield stream.
    /// @dev A stream's rate is `pot * 1e18 / duration`, so running one to completion
    ///      delivers the pot short by at most 1 wei of USDC; two accrual steps in a
    ///      test can compound that to 2. Anything larger is a real accounting bug, so
    ///      this stays deliberately tight rather than being widened to make a test
    ///      pass. Exact-value assertions are kept wherever the stream is not involved.
    uint256 internal constant DUST = 2;
    uint256 internal constant MAX_BORROW = 880.25e6; // 100 × 25.15 × 35%, USDC 6dp
    uint256 internal constant FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");
    address internal auction = makeAddr("auction");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    TreasuryLiquiditySource internal liquidity;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(auction);
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        // Fund the lending float.
        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        // Alice deposits collateral.
        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    // ── borrow: the LTV boundary ─────────────────────────────────────────────

    function test_borrow_atExactMaxLtvSucceeds() public {
        vm.prank(alice);
        credit.borrow(MAX_BORROW);

        assertEq(credit.debtOf(alice), MAX_BORROW);
        assertEq(credit.totalDebt(), MAX_BORROW);
        assertEq(usdc.balanceOf(alice), MAX_BORROW);
        assertEq(credit.currentLtvBps(alice), Config.MAX_LTV_BPS);
    }

    /// @dev One USDC unit past the limit. With the old divide-then-compare formula
    ///      this rounded down to exactly maxLTV and was allowed; cross-multiplication
    ///      is what makes it revert.
    function test_borrow_oneUnitBeyondMaxLtvReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.ExceedsMaxLtv.selector, Config.MAX_LTV_BPS)
        );
        credit.borrow(MAX_BORROW + 1);
    }

    function test_borrow_secondBorrowCountsExistingDebt() public {
        vm.startPrank(alice);
        credit.borrow(MAX_BORROW - 100e6);
        vm.expectRevert();
        credit.borrow(101e6);
        vm.stopPrank();
    }

    function testFuzz_borrowNeverExceedsMaxLtv(uint256 amount) public {
        amount = bound(amount, 1, MAX_BORROW * 2);
        vm.prank(alice);
        try credit.borrow(amount) {
            uint256 debt = credit.debtOf(alice);
            uint256 collateral = vault.collateralValue(alice);
            // The post-state must satisfy the rule exactly, with no rounding slack.
            assertLe(
                debt * Config.USDC_TO_NAV_SCALE * Config.BPS,
                Config.MAX_LTV_BPS * collateral,
                "accepted borrow left LTV above the maximum"
            );
        } catch {}
    }

    // ── borrow: gates ────────────────────────────────────────────────────────

    function test_borrow_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(CreditManager.ZeroAmount.selector);
        credit.borrow(0);
    }

    function test_borrow_revertsOnStaleNav() public {
        oracle.setStale(true);
        vm.prank(alice);
        vm.expectRevert(CreditManager.NavStale.selector);
        credit.borrow(1e6);
    }

    function test_borrow_revertsWithNoCollateral() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.ExceedsMaxLtv.selector, type(uint256).max)
        );
        credit.borrow(1e6);
    }

    function test_borrow_revertsWhenPaused() public {
        vm.prank(admin);
        credit.pause();
        vm.prank(alice);
        vm.expectRevert();
        credit.borrow(1e6);
    }

    function test_borrow_revertsOnPerAccountCap() public {
        // Enough collateral that LTV is not the binding constraint.
        _giveCollateral(bob, 5_000);
        uint256 over = Config.PER_ACCOUNT_BORROW_CAP + 1;
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.PerAccountCapExceeded.selector, over, Config.PER_ACCOUNT_BORROW_CAP
            )
        );
        credit.borrow(over);
    }

    /// @dev Proves the global cap is not merely the per-account cap in disguise: ten
    ///      accounts each inside their own limit must still hit the protocol ceiling.
    function test_borrow_revertsOnGlobalCap() public {
        uint256 perAccount = Config.PER_ACCOUNT_BORROW_CAP;
        uint256 accounts = Config.GLOBAL_BORROW_CAP / perAccount;
        usdc.mint(address(this), Config.GLOBAL_BORROW_CAP);
        usdc.approve(address(liquidity), Config.GLOBAL_BORROW_CAP);
        liquidity.fund(Config.GLOBAL_BORROW_CAP);

        for (uint256 i; i < accounts; ++i) {
            address borrower = address(uint160(0xB0B0 + i));
            _giveCollateral(borrower, 5_000);
            vm.prank(borrower);
            credit.borrow(perAccount);
        }
        assertEq(credit.totalDebt(), Config.GLOBAL_BORROW_CAP);

        address extra = makeAddr("extra");
        _giveCollateral(extra, 5_000);
        vm.prank(extra);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.GlobalCapExceeded.selector,
                Config.GLOBAL_BORROW_CAP + 1e6,
                Config.GLOBAL_BORROW_CAP
            )
        );
        credit.borrow(1e6);
    }

    /// @dev The source is not trusted, it is verified. Without the delta check the
    ///      shortfall would come out of this contract's own reserves.
    function test_borrow_revertsIfSourceDeliversLess() public {
        ShortLiquiditySource short = new ShortLiquiditySource(usdc, 1);
        usdc.mint(address(short), FLOAT);
        vm.prank(admin);
        credit.setLiquiditySource(address(short));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LiquidityNotDelivered.selector, 100e6, 100e6 - 1)
        );
        credit.borrow(100e6);
    }

    // ── repay ────────────────────────────────────────────────────────────────

    function test_repay_clearsDebtAndQueuesPrincipal() public {
        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebt(), 0);
        assertEq(credit.pendingPrincipal(), 500e6);
    }

    /// @dev Overpayment is clamped *before* the pull, so the excess never enters the
    ///      contract as unbacked balance.
    function test_repay_overpaymentClampedAndOnlyClampedAmountPulled() public {
        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 800e6);
        credit.repay(800e6);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 0, "only the outstanding debt was pulled");
        assertEq(credit.pendingPrincipal(), 500e6);
    }

    function test_repay_worksWhilePaused() public {
        vm.prank(alice);
        credit.borrow(500e6);
        vm.prank(admin);
        credit.pause();

        vm.startPrank(alice);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 0);
    }

    /// @dev The reason settlement is deferred: a borrower must be able to clear their
    ///      debt even when the funding source cannot accept the money back.
    function test_repay_succeedsWhenLiquiditySourceIsBroken() public {
        vm.prank(alice);
        credit.borrow(500e6);

        // A source that reverts on any interaction.
        vm.etch(address(liquidity), hex"fe");

        vm.startPrank(alice);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 0);
    }

    function test_repay_revertsWithNoDebt() public {
        vm.prank(alice);
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.repay(1e6);
    }

    function test_repayFor_thirdPartyCanClearSomeoneElsesDebt() public {
        vm.prank(alice);
        credit.borrow(500e6);

        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(credit), 500e6);
        credit.repayFor(alice, 500e6);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 0);
    }

    function test_settlePrincipal_returnsMoneyToTheSource() public {
        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(address(liquidity));
        credit.settlePrincipal();
        assertEq(usdc.balanceOf(address(liquidity)) - before, 500e6);
        assertEq(credit.pendingPrincipal(), 0);
        assertEq(usdc.allowance(address(credit), address(liquidity)), 0, "no standing allowance");
    }

    // ── yield distribution (accumulator) ─────────────────────────────────────

    /// @dev Alice is the only holder in this fixture, so she receives the whole
    ///      distribution and the arithmetic stays checkable by hand.
    function test_distributeYield_reducesDebt() public {
        vm.prank(alice);
        credit.borrow(500e6);
        _distribute(200e6);
        credit.settle(alice);

        assertApproxEqAbs(credit.debtOf(alice), 300e6, DUST);
        assertApproxEqAbs(credit.totalDebt(), 300e6, DUST);
        assertApproxEqAbs(credit.pendingPrincipal(), 200e6, DUST);
    }

    /// @dev Debt is written down lazily, so the stored figure is stale until someone
    ///      settles. `currentDebtOf` is the one to trust in between.
    function test_currentDebtOfReflectsUnsettledYield() public {
        vm.prank(alice);
        credit.borrow(500e6);
        _distribute(200e6);

        assertEq(credit.debtOf(alice), 500e6, "stored figure is still pre-settlement");
        assertApproxEqAbs(credit.pendingYieldOf(alice), 200e6, DUST);
        assertApproxEqAbs(credit.currentDebtOf(alice), 300e6, DUST, "what she actually owes");
    }

    function test_distributeYield_overflowGoesToClaimable() public {
        vm.prank(alice);
        credit.borrow(100e6);
        _distribute(250e6);
        credit.settle(alice);

        assertEq(credit.debtOf(alice), 0);
        assertApproxEqAbs(credit.claimableOf(alice), 150e6, DUST);
        assertApproxEqAbs(credit.totalClaimable(), 150e6, DUST);
    }

    function test_distributeYield_zeroDebtHolderGetsItAllAsClaimable() public {
        _distribute(50e6);
        credit.settle(alice);
        assertApproxEqAbs(credit.claimableOf(alice), 50e6, DUST);
    }

    function test_distributeYield_onlyEpochHarvester() public {
        vm.expectRevert(CreditManager.NotEpochHarvester.selector);
        credit.distributeYield(1);
    }

    function test_distributeYield_cannotDistributeUndeliveredYield() public {
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.YieldNotDelivered.selector, 1e6, 0));
        credit.distributeYield(1e6);
    }

    /// @dev Splits pro-rata by bond count, not per head.
    function test_distributeYield_splitsProRataByBonds() public {
        _giveCollateral(bob, 300); // alice 100, bob 300
        _distribute(400e6);
        credit.settle(alice);
        credit.settle(bob);

        assertApproxEqAbs(credit.claimableOf(alice), 100e6, DUST);
        assertApproxEqAbs(credit.claimableOf(bob), 300e6, DUST);
    }

    /// @dev The property that makes lazy settlement safe: arriving after a
    ///      distribution must earn nothing from it. A new position's index starts at
    ///      the current accumulator rather than at zero.
    function test_distributeYield_lateJoinerEarnsNothingFromEarlierEpochs() public {
        _distribute(100e6);
        _giveCollateral(bob, 100);

        credit.settle(bob);
        assertEq(credit.claimableOf(bob), 0, "bob missed that epoch entirely");

        _distribute(200e6); // alice 100, bob 100 -> half each
        credit.settle(alice);
        credit.settle(bob);
        assertApproxEqAbs(credit.claimableOf(alice), 200e6, DUST, "100 from the first, 100 from the second");
        assertApproxEqAbs(credit.claimableOf(bob), 100e6, DUST);
    }

    /// @dev Leaving stops accrual. Yield distributed after a full withdrawal belongs
    ///      to whoever is still holding.
    function test_distributeYield_leaverEarnsNothingAfterwards() public {
        _giveCollateral(bob, 100);
        vm.prank(alice);
        vault.withdrawBonds(BONDS);

        _distribute(100e6);
        credit.settle(alice);
        credit.settle(bob);
        assertEq(credit.claimableOf(alice), 0);
        assertApproxEqAbs(credit.claimableOf(bob), 100e6, DUST, "the remaining holder takes all of it");
    }

    /// @dev A harvest that lands with nothing staked must not divide by zero, and must
    ///      not credit anyone. The slice goes to the insurance fund as it elapses -
    ///      see the capture test below for why it cannot simply be held.
    function test_distributeYield_withNoBondsStakedGoesToInsurance() public {
        vm.prank(alice);
        vault.withdrawBonds(BONDS);
        assertEq(vault.totalBondCount(), 0);

        _distribute(100e6);
        assertEq(credit.accYieldPerBond(), 0, "nothing to distribute across");
        assertApproxEqAbs(credit.insuranceFund(), 100e6, DUST, "absorbed, not held");
        assertLe(credit.undistributedYield(), DUST);
    }

    /// @dev Settling repeatedly must not pay twice.
    function test_settle_isIdempotent() public {
        _distribute(100e6);
        credit.settle(alice);
        uint256 after1 = credit.claimableOf(alice);
        credit.settle(alice);
        credit.settle(alice);
        assertEq(credit.claimableOf(alice), after1);
    }

    /// @dev Truncation below one wei-per-bond stays in the backing balance rather than
    ///      being counted as distributed, so the solvency identity holds.
    function testFuzz_distributionNeverPromisesMoreThanItHolds(uint256 amount) public {
        amount = bound(amount, 1, 10_000e6);
        _giveCollateral(bob, 337); // deliberately awkward denominator
        _distribute(amount);
        credit.settle(alice);
        credit.settle(bob);

        assertGe(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
                + credit.insuranceFund(),
            "distribution promised more than the contract holds"
        );
    }

    // ── claimSurplus ─────────────────────────────────────────────────────────

    function test_claimSurplus_paysAndZeroes() public {
        _distribute(50e6);
        credit.settle(alice);

        vm.prank(alice);
        credit.claimSurplus();

        assertApproxEqAbs(usdc.balanceOf(alice), 50e6, DUST);
        assertEq(credit.claimableOf(alice), 0);
        assertEq(credit.totalClaimable(), 0);
    }

    function test_claimSurplus_revertsWithNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        credit.claimSurplus();
    }

    // ── views ────────────────────────────────────────────────────────────────

    /// @dev Debt is checked before collateral. The other ordering makes every empty
    ///      address report maximum LTV, and keeper scanners would queue liquidations
    ///      for accounts that do not exist.
    function test_currentLtvBps_zeroDebtReturnsZeroEvenWithNoCollateral() public view {
        assertEq(credit.currentLtvBps(bob), 0);
        assertEq(credit.healthFactor(bob), type(uint256).max);
    }

    function test_healthFactor_aboveOneWhileWithinMaxLtv() public {
        vm.prank(alice);
        credit.borrow(MAX_BORROW);
        // At maxLTV (3500) against a 5800 threshold, HF = 5800/3500 ≈ 1.657.
        assertGt(credit.healthFactor(alice), Config.HEALTH_FACTOR_SCALE);
    }

    function test_views_keepWorkingOnStaleNav() public {
        vm.prank(alice);
        credit.borrow(500e6);
        oracle.setStale(true);
        // Liquidations must keep pricing on the last known NAV (PRD §4.6).
        assertGt(credit.currentLtvBps(alice), 0);
        assertGt(credit.healthFactor(alice), 0);
    }

    // ── liquidity source swap ────────────────────────────────────────────────

    /// @dev The Phase 4 hazard: repointing at the LenderPool with debt outstanding
    ///      would leave the old source unpaid and start the new one's principal
    ///      accounting from money it never lent, underflowing on the first repayment.
    function test_setLiquiditySource_revertsWithDebtOutstanding() public {
        vm.prank(alice);
        credit.borrow(500e6);

        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.DebtOutstanding.selector, 500e6));
        credit.setLiquiditySource(address(next));
    }

    function test_setLiquiditySource_allowedOnceSettled() public {
        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();
        credit.settlePrincipal();

        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        credit.setLiquiditySource(address(next));
        assertEq(credit.liquiditySource(), address(next));
    }

    // ── withdrawal shares the borrow formula ─────────────────────────────────

    /// @dev The same position must be judged identically whether the LTV moves because
    ///      debt went up or because collateral came out. That is why the formula lives
    ///      in LtvMath rather than being written twice.
    function test_withdrawalBoundaryMatchesBorrowBoundary() public {
        vm.prank(alice);
        credit.borrow(MAX_BORROW);

        // Already exactly at maxLTV, so releasing even one bond must fail.
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawBonds(1);
    }

    // ── audit regressions ────────────────────────────────────────────────────

    /// @dev The break-glass hatch empties custody without clearing the vault's ledger,
    ///      so collateralValue kept pricing bonds the protocol no longer held. Lending
    ///      against that is unrecoverable, because withdrawals revert for everyone.
    function test_borrow_refusedAfterEmergencyUnstakeEmptiesCustody() public {
        address rescue = makeAddr("rescue");
        bond.setWhitelisted(rescue, true);

        assertTrue(vault.custodyIsSolvent());
        vm.prank(admin);
        adapter.emergencyUnstake(rescue);
        assertFalse(vault.custodyIsSolvent(), "ledger now outlives the collateral");

        vm.prank(alice);
        vm.expectRevert(CreditManager.CustodyInsolvent.selector);
        credit.borrow(1e6);
    }

    /// @dev Liquidation must keep working in that state - it is how the protocol
    ///      recovers - so only new debt is gated, not the views.
    function test_viewsStillPriceAfterCustodyIsEmptied() public {
        vm.prank(alice);
        credit.borrow(500e6);

        address rescue = makeAddr("rescue");
        bond.setWhitelisted(rescue, true);
        vm.prank(admin);
        adapter.emergencyUnstake(rescue);

        assertGt(credit.currentLtvBps(alice), 0);
        assertGt(credit.healthFactor(alice), 0);
    }

    /// @dev A one-bond withdrawal settles the whole pooled position's farm rewards.
    ///      Reporting nothing let any depositor push an epoch's yield out through an
    ///      unmeasured path, leaving the accounted harvest at zero.
    function test_withdrawalReportsTheYieldItFlushesOutOfTheFarm() public {
        farm.setPendingYield(address(adapter), 10_000e6);

        vm.recordLogs();
        vm.prank(alice);
        vault.withdrawBonds(1);

        assertEq(usdc.balanceOf(yieldSink), 10_000e6, "the yield did leave");
        // And it was accounted for: the vault emits it rather than discarding it.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool reported;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("YieldHarvested(uint256)")) {
                assertEq(abi.decode(logs[i].data, (uint256)), 10_000e6);
                reported = true;
            }
        }
        assertTrue(reported, "swept yield must be reported, not silently forwarded");
    }

    /// @dev Repointing the debt book while loans are live made every borrower read
    ///      zero debt and withdraw all their collateral against the old book.
    function test_setCreditManager_refusedWhileDebtIsOutstanding() public {
        vm.prank(alice);
        credit.borrow(500e6);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerHasDebt.selector, 500e6)
        );
        vault.setCreditManager(makeAddr("freshManager"));
    }

    /// @dev And the incoming manager must be bound back to this vault, the same way
    ///      `setCustodyAdapter` checks its adapter. The vault settles a position
    ///      before every bond-count change, and `settleForVault` only accepts calls
    ///      from its own vault - so a manager bound elsewhere reverts every deposit,
    ///      withdrawal and seizure, with everyone's collateral already inside.
    function test_setCreditManager_refusedWhenBoundToAnotherVault() public {
        CollateralVault otherVault =
            new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        CreditManager foreign = new CreditManager(
            usdc, ICollateralVault(address(otherVault)), INAVOracle(address(oracle)), admin
        );

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVault.CreditManagerVaultMismatch.selector, address(otherVault)
            )
        );
        vault.setCreditManager(address(foreign));
    }

    /// @dev Both risk views price against `currentDebtOf`, not the stored `debtOf`.
    ///      Unsettled yield is already earned and already backed by USDC held here, so
    ///      reporting against the stale figure is how a keeper queues a liquidation
    ///      that a free, permissionless `settle` would have cleared.
    function test_riskViewsPriceAgainstDebtNetOfEarnedYield() public {
        vm.prank(alice);
        credit.borrow(MAX_BORROW);
        uint256 ltvBefore = credit.currentLtvBps(alice);
        uint256 hfBefore = credit.healthFactor(alice);

        _distribute(400e6); // earned, but nobody has settled

        assertEq(credit.debtOf(alice), MAX_BORROW, "still unsettled");
        assertLt(credit.currentLtvBps(alice), ltvBefore, "LTV reflects the write-down");
        assertGt(credit.healthFactor(alice), hfBefore, "and so does health");

        // Settling changes nothing the views had not already reported.
        uint256 ltvUnsettled = credit.currentLtvBps(alice);
        credit.settle(alice);
        assertEq(credit.currentLtvBps(alice), ltvUnsettled, "the views were not guessing");
    }

    /// @dev Claiming settles first. Without it a borrower whose debt is already
    ///      cleared has to call `settle` themselves before the overflow is visible,
    ///      and claiming looks like it lost them money when it merely ran early.
    function test_claimSurplus_settlesBeforePaying() public {
        vm.prank(alice);
        credit.borrow(100e6);
        _distribute(250e6);

        // Deliberately no settle() call here.
        assertEq(credit.claimableOf(alice), 0, "nothing booked yet");

        vm.prank(alice);
        credit.claimSurplus();
        assertApproxEqAbs(usdc.balanceOf(alice), 100e6 + 150e6, DUST, "borrowed plus the surplus");
        assertEq(credit.debtOf(alice), 0, "and the debt was cleared on the way");
    }

    // ── detachment ───────────────────────────────────────────────────────────

    /// @dev **The orphaned-manager regression.** Repointing the vault at a new
    ///      CreditManager left the old one fully live: `settle`, `accrueYield` and
    ///      `claimSurplus` stayed permissionless and kept reading the vault's live
    ///      bond counts, while the vault no longer settled into it. The invariant its
    ///      accumulator rests on - the vault settles before every bond-count change -
    ///      was severed, so anyone depositing after the swap held a zero index against
    ///      a non-zero historical accumulator and could claim the orphan's whole
    ///      balance, insurance fund included.
    ///
    ///      The swap guard passes at zero debt, which is the *normal* end state of a
    ///      self-repaying loan, so this was reachable through ordinary operation.
    function test_detachedManagerCannotPriceNewPositions() public {
        // Build up an accumulator and an insurance balance on the live manager.
        _distribute(400e6);
        usdc.mint(address(this), 200e6);
        usdc.approve(address(credit), 200e6);
        credit.fundInsurance(200e6);
        assertGt(credit.accYieldPerBond(), 0);
        assertGt(usdc.balanceOf(address(credit)), 0);

        // Alice clears out so the swap guard passes, then the owner migrates.
        credit.settle(alice);
        vm.prank(alice);
        credit.claimSurplus();
        assertEq(credit.totalDebt(), 0);

        CreditManager fresh =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        vm.prank(admin);
        vault.setCreditManager(address(fresh));

        // The attacker deposits into the vault, which now settles only into `fresh`,
        // leaving their index on the old manager at zero.
        address raider = makeAddr("raider");
        _giveCollateral(raider, BONDS * 5);

        // Every path that would price them against the stale accumulator now refuses.
        vm.expectRevert(abi.encodeWithSelector(CreditManager.Detached.selector, address(fresh)));
        credit.settle(raider);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.Detached.selector, address(fresh)));
        credit.accrueYield();
        vm.prank(raider);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.Detached.selector, address(fresh)));
        credit.borrow(1e6);

        vm.prank(raider);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        credit.claimSurplus();

        assertEq(credit.claimableOf(raider), 0, "no entitlement was minted");
        assertEq(credit.insuranceFund(), 200e6, "the insurance fund is untouched");
    }

    /// @dev Exits must survive a migration, so a detached manager still lets a
    ///      borrower repay and still pays out balances recorded while it was live.
    function test_detachedManagerStillHonoursExits() public {
        vm.prank(alice);
        credit.borrow(500e6);
        _distribute(700e6);
        credit.settle(alice); // debt cleared, surplus recorded while attached

        uint256 owed = credit.claimableOf(alice);
        assertGt(owed, 0);
        assertEq(credit.totalDebt(), 0);

        CreditManager fresh =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        vm.prank(admin);
        vault.setCreditManager(address(fresh));

        vm.prank(alice);
        credit.claimSurplus();
        assertEq(usdc.balanceOf(alice), 500e6 + owed, "recorded surplus still payable");
    }

    /// @dev **The counter-overwrite regression.** `settlePrincipal` snapshots
    ///      `pendingPrincipal`, makes an external call, then wrote back
    ///      `amount - delivered` - an assignment derived from a pre-call figure. Any
    ///      increment landing during that call was silently erased, and `settle` is
    ///      the one value-moving path without `nonReentrant`.
    ///
    ///      Here the source settles bob mid-call, writing his yield down against his
    ///      debt and pushing that principal onto the counter. All of it must survive.
    function test_settlePrincipal_survivesASourceThatSettlesMidCall() public {
        ReentrantLiquiditySource source = new ReentrantLiquiditySource(usdc);
        usdc.mint(address(source), FLOAT);

        // Fresh manager so the liquidity source can be swapped in at zero debt.
        CreditManager credit2 =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        vm.startPrank(admin);
        vault.setCreditManager(address(credit2));
        credit2.setLiquiditySource(address(source));
        credit2.setEpochHarvester(harvester);
        vm.stopPrank();

        _giveCollateral(bob, BONDS);
        vm.prank(alice);
        credit2.borrow(300e6);
        vm.prank(bob);
        credit2.borrow(300e6);

        // Deliver an epoch and let it stream, so both have yield to settle.
        usdc.mint(harvester, 400e6);
        vm.startPrank(harvester);
        usdc.approve(address(credit2), 400e6);
        credit2.receiveYield(400e6);
        credit2.distributeYield(400e6);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION);

        // Settle alice only; bob's write-down will land during the external call.
        credit2.settle(alice);
        uint256 queued = credit2.pendingPrincipal();
        assertGt(queued, 0);

        source.wire(credit2, bob);
        credit2.settlePrincipal();

        // Bob's principal was added mid-call and must still be owed, not erased.
        uint256 bobShare = 400e6 / 2;
        assertApproxEqAbs(
            credit2.pendingPrincipal(), bobShare, DUST, "the re-entrant increment survived"
        );
        // And the contract still covers every claim on it.
        assertGe(
            usdc.balanceOf(address(credit2)),
            credit2.totalClaimable() + credit2.undistributedYield() + credit2.pendingPrincipal()
                + credit2.insuranceFund(),
            "solvency held through the re-entrancy"
        );
    }

    // ── the accrual window ───────────────────────────────────────────────────

    /// @dev **The fixed-window regression.** Streaming closed same-block capture, but
    ///      the rate was always `pot / 5 days` even when the pot represented months of
    ///      accrual - so an attacker who deposited just before a long-delayed harvest
    ///      captured a share wildly out of proportion to the time they were staked.
    ///      The first epoch is the worst case: it skips the cooldown entirely, and
    ///      `harvest` is permissionless, so the attacker picks the block.
    ///
    ///      Rating the stream over the window the pot actually accrued over makes the
    ///      round trip cost what it earns, at any window length.
    function test_stream_longAccrualWindowIsNotJustInTimeCapturable() public {
        // Sixty days pass before the first epoch is ever harvested.
        skip(60 days);

        address jit = makeAddr("jit");
        _giveCollateral(jit, BONDS * 9); // 9x alice's stake, arriving at the last moment

        _deliver(1_000e6);

        // Five days in - a full YIELD_STREAM_DURATION - the attacker exits.
        skip(Config.YIELD_STREAM_DURATION);
        credit.settle(jit);
        uint256 captured = credit.claimableOf(jit);

        // Their entitlement is bounded by time staked, not by the size of the pot:
        // 5 days of a 60-day stream at 90% of the bonds is ~7.5% of the epoch.
        assertLt(captured, 100e6, "a fixed 5-day window would have paid them ~900e6");

        // And the rest is still there for the holders who stayed.
        assertGt(credit.undistributedYield(), 800e6, "the epoch is still being paid out");
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _giveCollateral(address who, uint256 bonds) private {
        bond.mint(who, bonds);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    /// @dev Deliver and distribute in one step, the way EpochHarvester does, then run
    ///      the stream to completion.
    ///
    ///      The warp is the point rather than a convenience: an epoch's share is
    ///      streamed over YIELD_STREAM_DURATION, so nothing is claimable the instant
    ///      it is distributed. These tests are about how a fully-elapsed epoch is
    ///      split between positions, so they let it elapse; the streaming behaviour
    ///      itself is covered separately below.
    function _distribute(uint256 amount) private {
        _deliver(amount);
        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();
    }

    /// @dev Deliver and start the stream without waiting for it.
    function _deliver(uint256 amount) private {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
    }

    // ── streaming ────────────────────────────────────────────────────────────

    /// @dev The reason distribution streams at all. A lump credited to whoever holds
    ///      bonds at the harvest instant is free money for anyone watching the
    ///      mempool: deposit big, settle, claim, withdraw, all in one transaction.
    ///      Here the attacker brings 9x alice's collateral and still leaves with
    ///      nothing, because they held it for zero seconds.
    function test_stream_justInTimeDepositEarnsNothing() public {
        address jit = makeAddr("jit");
        _giveCollateral(jit, BONDS * 9); // 900 bonds against alice's 100

        _deliver(550e6);

        // Same block as the distribution: settle, and try to take the epoch.
        credit.settle(jit);
        assertEq(credit.claimableOf(jit), 0, "nothing accrues in zero seconds");

        vm.prank(jit);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        credit.claimSurplus();

        // And the yield is still there for the holders who actually stay staked.
        skip(Config.YIELD_STREAM_DURATION);
        credit.settle(alice);
        assertApproxEqAbs(credit.claimableOf(alice), 55e6, DUST, "alice keeps her tenth");
    }

    /// @dev A position that leaves halfway through the stream keeps the half it was
    ///      staked for and no more. This is what the accumulator buys over a snapshot.
    function test_stream_accruesInProportionToTimeStaked() public {
        _deliver(100e6);

        skip(Config.YIELD_STREAM_DURATION / 2);
        credit.settle(alice);
        assertApproxEqAbs(credit.claimableOf(alice), 50e6, DUST, "half the stream, half the yield");

        skip(Config.YIELD_STREAM_DURATION / 2);
        credit.settle(alice);
        assertApproxEqAbs(credit.claimableOf(alice), 100e6, DUST, "the rest arrives by the end");
    }

    /// @dev Views must project the stream, not report the last written accumulator.
    ///      A keeper reading a debt the stream has already paid down would queue a
    ///      liquidation that a free, permissionless `settle` would have cleared.
    function test_stream_viewsProjectWithoutSettling() public {
        vm.prank(alice);
        credit.borrow(500e6);
        _deliver(100e6);

        skip(Config.YIELD_STREAM_DURATION / 2);
        assertApproxEqAbs(credit.pendingYieldOf(alice), 50e6, DUST, "visible before settling");
        assertApproxEqAbs(credit.currentDebtOf(alice), 450e6, DUST, "debt already partly paid");
        assertEq(credit.debtOf(alice), 500e6, "the stored figure has not moved");
    }

    /// @dev Nothing accrues past the end of the stream, so an epoch cannot pay out
    ///      more than was delivered however long nobody touches it.
    function test_stream_stopsAtTheEnd() public {
        _deliver(100e6);
        skip(Config.YIELD_STREAM_DURATION * 10);
        credit.settle(alice);
        assertApproxEqAbs(credit.claimableOf(alice), 100e6, DUST, "capped at what arrived");
        assertLe(credit.undistributedYield(), DUST, "and the pot is drained but for dust");
    }

    /// @dev **The zero-stake capture regression.** An earlier version advanced the
    ///      clock through an unstaked window but retained the money, on the reasoning
    ///      that holding it was kinder than burning it. It was not: the retained pot
    ///      was re-rated across whatever bond base existed at the *next* distribution,
    ///      so after a mass exit a single bond deposited before the next epoch
    ///      captured the entire previous cohort's yield.
    ///
    ///      The old test hid this by having the same holder return, which made a
    ///      full-value payout look correct instead of looking like a windfall.
    function test_stream_unstakedWindowCannotBeCapturedByALateArrival() public {
        // The whole cohort exits one second into the stream.
        _deliver(1_000e6);
        skip(1);
        vm.prank(alice);
        vault.withdrawBonds(BONDS);
        assertEq(vault.totalBondCount(), 0);

        // Alice keeps exactly the one second she was staked for, paid on her way out.
        uint256 aliceEarned = credit.claimableOf(alice);
        uint256 perSecond = (1_000e6 / Config.YIELD_STREAM_DURATION);
        assertApproxEqAbs(aliceEarned, perSecond, 2, "one second staked, one second paid");

        // The rest of the stream elapses with nobody staked.
        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();
        assertApproxEqAbs(
            credit.insuranceFund(),
            1_000e6 - aliceEarned,
            DUST,
            "everything she did not earn went to insurance, not into a capturable pot"
        );

        // An attacker arrives with a single bond and triggers a fresh epoch.
        address jit = makeAddr("jit");
        _giveCollateral(jit, 1);
        _distribute(1e6);
        credit.settle(jit);

        // They get their share of the new epoch only, not the abandoned cohort's.
        assertApproxEqAbs(credit.claimableOf(jit), 1e6, DUST, "only the epoch they were there for");
        assertLt(credit.claimableOf(jit), 2e6, "the previous cohort's yield was not capturable");
    }
}
