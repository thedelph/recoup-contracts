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

/// @notice Phase-2 credit core: borrow, repay, yield application, surplus claims and
///         the LTV/cap/staleness gates (PRD §4.3, §6.1).
///
///         Fixture uses the real 2026-07-24 NAV snapshot so the numbers are the ones
///         the protocol will actually see: 100 bonds at $25.15 is $2,515 of collateral,
///         and 35% of that is exactly 880.25 USDC of borrowing power.
contract CreditManagerTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
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

    // ── applyYield ───────────────────────────────────────────────────────────

    function test_applyYield_reducesDebt() public {
        vm.prank(alice);
        credit.borrow(500e6);
        _deliverYield(200e6);

        vm.prank(harvester);
        credit.applyYield(alice, 200e6);

        assertEq(credit.debtOf(alice), 300e6);
        assertEq(credit.totalDebt(), 300e6);
        assertEq(credit.pendingPrincipal(), 200e6);
    }

    function test_applyYield_overflowGoesToClaimable() public {
        vm.prank(alice);
        credit.borrow(100e6);
        _deliverYield(250e6);

        vm.prank(harvester);
        credit.applyYield(alice, 250e6);

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.claimableOf(alice), 150e6);
        assertEq(credit.totalClaimable(), 150e6);
    }

    function test_applyYield_zeroDebtBorrowerGetsItAllAsClaimable() public {
        _deliverYield(50e6);
        vm.prank(harvester);
        credit.applyYield(alice, 50e6);
        assertEq(credit.claimableOf(alice), 50e6);
    }

    function test_applyYield_onlyEpochHarvester() public {
        vm.expectRevert(CreditManager.NotEpochHarvester.selector);
        credit.applyYield(alice, 1);
    }

    /// @dev Dust is normal in a pro-rata split across 200 positions; 200 empty events
    ///      are not.
    function test_applyYield_zeroAmountIsANoOp() public {
        vm.prank(harvester);
        credit.applyYield(alice, 0);
        assertEq(credit.claimableOf(alice), 0);
    }

    /// @dev The attack this closes: anything holding the harvester role crediting
    ///      claimable balances it never funded, then draining the contract.
    function test_applyYield_cannotDistributeUndeliveredYield() public {
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.YieldNotDelivered.selector, 1e6, 0));
        credit.applyYield(alice, 1e6);
    }

    // ── claimSurplus ─────────────────────────────────────────────────────────

    function test_claimSurplus_paysAndZeroes() public {
        _deliverYield(50e6);
        vm.prank(harvester);
        credit.applyYield(alice, 50e6);

        vm.prank(alice);
        credit.claimSurplus();

        assertEq(usdc.balanceOf(alice), 50e6);
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

    // ── helpers ──────────────────────────────────────────────────────────────

    function _giveCollateral(address who, uint256 bonds) private {
        bond.mint(who, bonds);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _deliverYield(uint256 amount) private {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        vm.stopPrank();
    }
}
