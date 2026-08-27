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
import {ILenderPool} from "../src/interfaces/ILenderPool.sol";
import {MockLenderPool} from "./mocks/MockLenderPool.sol";
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

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
///         the protocol will actually see: 100 bonds at $25.15 is $2,515 of collateral.
///
///         `_maxBorrow()` is derived from the live risk parameters rather than written
///         down. It was the literal 880.25e6 (35% of $2,515) until the capped-beta
///         parameters landed on 2026-08-07 and broke fourteen tests at the fixture rather
///         than in the code under test. The ratchet agreed with DexFi moves the borrow
///         ceiling at least twice more, so the fixture reads the parameter instead of
///         restating it - and reads it on every call, because the parameter now lives in
///         `RiskParams` storage and a test may move it partway through.
contract CreditManagerTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;

    /// @notice Tolerance for figures that came through the yield stream.
    /// @dev A stream's rate is `pot * 1e18 / duration`, so running one to completion
    ///      delivers the pot short by at most 1 wei of USDC, and a test that crosses two
    ///      streams can carry that to 2. Anything larger is a real accounting bug, so this
    ///      stays deliberately tight rather than being widened to make a test pass.
    ///      Exact-value assertions are kept wherever the stream is not involved.
    ///
    ///      **This used to say "two accrual steps in a test can compound that to 2", and
    ///      audit round 21 measured that false.** It was a property of a stream accrued once
    ///      or twice, not of the code: `_accrue` floored every slice against the previous
    ///      call, so the residual grew with the number of calls and nothing bounded that -
    ///      80 wei at an hourly cadence, 12,592 at one call per second, and the entire pot
    ///      where the rate fell below one wei per second. It is a property of the code again
    ///      only because `CreditManager._sliceOwed` now floors once per stream; the tolerance
    ///      is meaningless without that, and `test_stream_perSecondAccrualDeliversWhatOneCallWould`
    ///      is what keeps it honest.
    uint256 internal constant DUST = 2;
    uint256 internal constant FLOAT = 100_000e6;

    /// @dev The NAV the liquidation-boundary tests crash to. The debt that sits exactly on
    ///      the threshold once they do is `_debtAtThreshold()` below - derived, because the
    ///      property under test is "one unit past the threshold" and that is only true of a
    ///      literal for as long as the threshold does not move. It was 580_000_001 against a
    ///      5,800 bps threshold; at 5,000 the same literal is 16% past the line and the test
    ///      would have been asserting something else entirely.
    uint256 internal constant BOUNDARY_NAV = 10e8;

    /// @dev Borrowing power at the ceiling: BONDS x NAV x maxLTV, in USDC 6dp.
    /// @dev **A function and not a `constant`, and not a variable cached in `setUp` either.**
    ///      A Solidity `constant` cannot read storage, which is where the ceiling now lives;
    ///      a cache would let a test that moves the parameter partway through compute its
    ///      expected figures from a snapshot taken before the move and pass against the old
    ///      one. That is the exact failure the settable parameters exist to make visible, so
    ///      this re-reads on every call. See `RiskParamsFixture`.
    function _maxBorrow() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    /// @dev The debt that sits exactly on the liquidation threshold for the seeded lot once
    ///      NAV has crashed to `BOUNDARY_NAV`. Re-read per call for the same reason.
    function _debtAtThreshold() internal view returns (uint256) {
        return _debtAtThreshold(BONDS, BOUNDARY_NAV);
    }

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");
    MockLiquidationAuction internal auctionMock;
    address internal auction;

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    TreasuryLiquiditySource internal liquidity;
    RiskParams internal riskParams;

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
        auctionMock = new MockLiquidationAuction();
        auction = address(auctionMock);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        auctionMock.setVault(address(vault));
        // Audit round 20: the setters also check the risk authority agrees with the vault's.
        auctionMock.setRiskParams(address(riskParams));
        // Audit round 21: and the NAV feed, anchored on the vault's answer.
        auctionMock.setNavOracle(address(vault.navOracle()));
        // `borrow` now refuses while the three wiring pointers disagree, so the mock
        // has to report the aligned state the fixture is in.
        auctionMock.setCreditManager(address(credit));
        // Deliberately NOT wired here. An auction the vault names while this manager
        // does not is a half-finished migration, and `borrow` now refuses in it - so a
        // fixture that wired only the vault's side would put every borrow test in a
        // state the protocol rejects. `_wireAuction` sets both; until it runs, this is
        // the honest Phase-2 shape, with no auction anywhere.
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
        // **Read before the prank, and every test below does the same.** A single-shot
        // `vm.prank` is spent on the next call the test contract makes, and since the ceiling
        // moved into `RiskParams` storage the derivation is an external staticcall - so
        // `vm.prank(alice); credit.borrow(_maxBorrow());` spends the prank on the parameter
        // read and sends the borrow from this contract, which owns no collateral.
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        assertEq(credit.debtOf(alice), loan);
        assertEq(credit.totalDebt(), loan);
        // The disbursement is the loan less the prepaid liquidation bounty; the debt, and so
        // the LTV, are the full loan. That asymmetry is the whole reason the bounty is held
        // off the debt ledger, and this is the test that pins it.
        assertEq(usdc.balanceOf(alice), loan - Config.LIQUIDATION_CALL_BOUNTY);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY);
        assertEq(credit.currentLtvBps(alice), maxLtvBps());
    }

    /// @dev One USDC unit past the limit. With the old divide-then-compare formula
    ///      this rounded down to exactly maxLTV and was allowed; cross-multiplication
    ///      is what makes it revert.
    function test_borrow_oneUnitBeyondMaxLtvReverts() public {
        // **Two separate things spend a single-shot prank here, and the order below survives
        // both.** `vm.expectRevert` is itself a call this contract makes, and it consumes a
        // pending prank - that is the repo's existing rule and it has not changed. What the
        // parameters moving into storage added is a second way to lose it: every derivation is
        // now an external staticcall, so a read left inline, or inside the
        // `abi.encodeWithSelector` arguments, would spend the prank before `borrow` ever ran.
        // Reads first, then the expectation, then the prank, then the call.
        uint256 overTheCeiling = _maxBorrow() + 1;
        uint256 ceilingBps = maxLtvBps();
        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsMaxLtv.selector, ceilingBps, ceilingBps));
        vm.prank(alice);
        credit.borrow(overTheCeiling);
    }

    function test_borrow_secondBorrowCountsExistingDebt() public {
        vm.startPrank(alice);
        credit.borrow(_maxBorrow() - 100e6);
        vm.expectRevert();
        credit.borrow(101e6);
        vm.stopPrank();
    }

    function testFuzz_borrowNeverExceedsMaxLtv(uint256 amount) public {
        amount = bound(amount, 1, _maxBorrow() * 2);
        vm.prank(alice);
        try credit.borrow(amount) {
            uint256 debt = credit.debtOf(alice);
            uint256 collateral = vault.collateralValue(alice);
            // The post-state must satisfy the rule exactly, with no rounding slack.
            assertLe(
                debt * Config.USDC_TO_NAV_SCALE * Config.BPS,
                maxLtvBps() * collateral,
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
        uint256 ceilingBps = maxLtvBps();
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.ExceedsMaxLtv.selector, type(uint256).max, ceilingBps)
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
        uint256 cap = perAccountBorrowCap();
        uint256 over = cap + 1;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.PerAccountCapExceeded.selector, over, cap));
        credit.borrow(over);
    }

    /// @dev Proves the global cap is not merely the per-account cap in disguise: enough
    ///      accounts each inside their own limit must still hit the protocol ceiling. The
    ///      count is derived from the live caps rather than written down, so a ratchet step
    ///      moves the loop instead of breaking it.
    function test_borrow_revertsOnGlobalCap() public {
        uint256 perAccount = perAccountBorrowCap();
        uint256 globalCap = globalBorrowCap();
        uint256 accounts = globalCap / perAccount;
        // Both premises stated rather than assumed, now that both caps are settable and the
        // relation between them is only checked as `perAccount <= global`. An uneven division
        // leaves the loop short of the ceiling so the refusal never fires, and a single
        // account filling the whole book is the very state this test exists to distinguish
        // itself from.
        assertEq(globalCap % perAccount, 0, "the caps no longer divide evenly");
        assertGt(accounts, 1, "one account fills the book, so nothing here is about the global cap");

        usdc.mint(address(this), globalCap);
        usdc.approve(address(liquidity), globalCap);
        liquidity.fund(globalCap);

        for (uint256 i; i < accounts; ++i) {
            address borrower = address(uint160(0xB0B0 + i));
            _giveCollateral(borrower, 5_000);
            vm.prank(borrower);
            credit.borrow(perAccount);
        }
        assertEq(credit.totalDebt(), globalCap);

        address extra = makeAddr("extra");
        _giveCollateral(extra, 5_000);
        vm.prank(extra);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.GlobalCapExceeded.selector, globalCap + 1e6, globalCap)
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

    /// @notice **Audit round 21, finding 3: a no-op at zero, not a revert.**
    /// @dev This function used to open `if (amount == 0) revert NothingToSettle();`, and that
    ///      revert was the only reason `DeployBase._phase4Calls` had to write the settle leg
    ///      *conditionally* on `pendingPrincipal() != 0`. Because the call is permissionless and
    ///      free - MEASURED at 42,744 gas - the conditionality made a stranger the author of a
    ///      queued switchover batch's shape: zero the counter during the delay and the operation
    ///      either reverts on a leg that is now empty or re-derives to an id nobody scheduled.
    ///
    ///      Three things asserted here rather than one, because "it stopped reverting" is not the
    ///      property. It must also move nothing and emit nothing - a `PrincipalSettled(0)` would
    ///      let an indexer count a stranger's free call as a settlement.
    function test_settlePrincipal_isANoOpAtZeroRatherThanARevert() public {
        assertEq(credit.pendingPrincipal(), 0, "premise: nothing owed home");
        uint256 sourceBefore = usdc.balanceOf(address(liquidity));
        uint256 managerBefore = usdc.balanceOf(address(credit));

        vm.recordLogs();
        vm.prank(makeAddr("anyStranger"));
        credit.settlePrincipal();

        assertEq(vm.getRecordedLogs().length, 0, "an empty settlement is not an event");
        assertEq(usdc.balanceOf(address(liquidity)), sourceBefore, "and moves nothing");
        assertEq(usdc.balanceOf(address(credit)), managerBefore);
        assertEq(credit.pendingPrincipal(), 0);

        // The loaded path is unchanged, which is what stops this reading as "settlement was
        // switched off". Same call, same caller, money moves.
        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();

        // Snapshotted here, not above: the borrow itself pulled the float out of the source, so a
        // delta measured across the whole loan would be zero and this assertion would pass over a
        // settlement that never happened.
        uint256 sourceBeforeSettle = usdc.balanceOf(address(liquidity));
        vm.prank(makeAddr("anyStranger"));
        credit.settlePrincipal();
        assertEq(usdc.balanceOf(address(liquidity)) - sourceBeforeSettle, 500e6, "the real settlement still settles");
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
                + credit.insuranceFund() + credit.totalBountyEscrowed() + credit.totalBountyParked()
                + credit.totalBountyOwed(),
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
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        // At the LTV ceiling against the liquidation threshold, HF = threshold/maxLTV.
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

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 22, finding 5. A blacklisted liquidity source used to freeze the
    // principal and the escape from it together.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The state the finding is about, with no operator error in it: a full repayment, and a
    ///      source that has since become unable to receive USDC. `repayPrincipal` ends in
    ///      `safeTransferFrom(creditManager, address(this), amount)` on both implementations, and
    ///      real USDC reverts on a blacklisted destination - which `MockUSDC` models precisely
    ///      because, in its own words, "several paths exist purely to survive it".
    function _repayIntoABlockedSource() private returns (uint256 owedHome) {
        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();

        owedHome = credit.pendingPrincipal();
        assertEq(credit.totalDebt(), 0, "premise: the book is flat");
        assertEq(owedHome, 500e6, "premise: the principal is waiting to go home");
        usdc.setBlocked(address(liquidity), true);
    }

    /// @notice **The deadlock, measured.** The only drain of `pendingPrincipal` runs through the
    ///         source pointer, and the only escape from the source pointer used to run through
    ///         `pendingPrincipal`.
    /// @dev MEASURED before the fix, on the real `TreasuryLiquiditySource` as `DeployBase` ships it:
    ///      `settlePrincipal()` reverted `Blocked(treasury)`, `setLiquiditySource(other)` reverted
    ///      `DebtOutstanding(0)` - reporting the clause it was not refused on - and `borrow(1)`
    ///      reverted `Blocked(treasury)` as well, so the protocol could never lend through this
    ///      manager again. Identical at +365 days. The ceiling is the whole outstanding book,
    ///      because `CollateralVault.setCreditManager` requires `totalDebt == 0` and so a migration
    ///      out requires every loan repaid into the broken manager first.
    ///
    ///      Neither of the two obvious patches was shipped, and both were measured inert first.
    ///      A `try`/`catch` around the repay changes nothing: `pendingPrincipal` is decremented by a
    ///      *measured balance delta*, so a source that refuses delivers 0 and the counter does not
    ///      move either way. A selector probe on `setLiquiditySource` changes nothing **for this
    ///      finding** either, because the break is dynamic - the source answered perfectly until
    ///      Circle froze it.
    ///
    ///      🟥 **Read as a general refutation, that last sentence cost two rounds.** Round 27 item 2
    ///      found `setLiquiditySource` probing nothing at all, and it was still open at round 28 as
    ///      item 3. A *frozen* source and a *wrong pointer* are different failures: the second is
    ///      wrong on the day it is written and is visible nowhere but the setter. There is a probe
    ///      now (`CreditWiring.checkLiquiditySourceSwap`), and
    ///      `test_R28_control_theProbeDoesNotReopenTheFrozenSourceFinding` in `SetterGuards.t.sol`
    ///      pins that it does **not** refuse the complete-but-frozen source this test is about.
    function test_R22_aBlockedSourceNoLongerFreezesThePrincipalAndTheEscapeTogether() public {
        uint256 owedHome = _repayIntoABlockedSource();

        // The drain still cannot run. That half is the token's doing and is not fixable here.
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, address(liquidity)));
        credit.settlePrincipal();
        assertEq(credit.pendingPrincipal(), owedHome, "the counter cannot be cleared");

        // The escape does run now, and the undeliverable principal is checkpointed against the
        // source that lent it rather than blocking the repoint.
        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        credit.setLiquiditySource(address(next));
        assertEq(credit.liquiditySource(), address(next), "the repoint is still refused");
        assertEq(credit.pendingPrincipal(), 0, "the counter did not move with the pointer");
        assertEq(credit.owedToSource(address(liquidity)), owedHome, "not parked against the lender");
        assertEq(credit.totalOwedToSources(), owedHome, "and the sum has to move with it");

        // Lending works again through the new source, which is the whole point: before this the
        // protocol could never lend through this manager again.
        usdc.mint(admin, 10_000e6);
        vm.startPrank(admin);
        usdc.approve(address(next), 10_000e6);
        next.fund(10_000e6);
        next.setCreditManager(address(credit));
        vm.stopPrank();
        vm.prank(alice);
        credit.borrow(1e6);
        assertEq(credit.debtOf(alice), 1e6, "the protocol still cannot lend");

        // And the parked principal goes home, permissionlessly, once the block lifts.
        usdc.setBlocked(address(liquidity), false);
        uint256 sourceBefore = usdc.balanceOf(address(liquidity));
        vm.prank(makeAddr("stranger")); // no role at all
        credit.flushPrincipalTo(address(liquidity));
        emit log_named_uint(
            "MEASURED principal recovered by the source that lent it", usdc.balanceOf(address(liquidity)) - sourceBefore
        );
        assertEq(usdc.balanceOf(address(liquidity)) - sourceBefore, owedHome, "the money never went home");
        assertEq(credit.owedToSource(address(liquidity)), 0);
        assertEq(credit.totalOwedToSources(), 0);
    }

    /// @notice The guard that is left reports the clause it was actually refused on.
    /// @dev **A separate defect on the same line.** The guard used to read
    ///      `if (totalDebt != 0 || pendingPrincipal != 0) revert DebtOutstanding(totalDebt)`, so a
    ///      repoint refused for pending principal reported `DebtOutstanding(0)` - an operator told
    ///      the book is not flat by a number saying it is. Every other two-clause guard in the file
    ///      was deliberately split into distinct errors for exactly this reason. It is fixed by
    ///      *removal* rather than by a second error: the pending-principal clause is the deadlock
    ///      above, so what is left is one clause reporting its own quantity.
    function test_R22_theSwapGuardReportsTheClauseItRefusedOn() public {
        vm.prank(alice);
        credit.borrow(500e6);
        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.DebtOutstanding.selector, 500e6));
        credit.setLiquiditySource(address(next));
    }

    /// @notice CONTROL: a source that can receive is settled, not parked. The ordinary migration is
    ///         unchanged, and nothing accumulates in the checkpoint on the happy path.
    function test_R22_control_aHealthySourceIsPaidRatherThanParked() public {
        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();

        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        uint256 sourceBefore = usdc.balanceOf(address(liquidity));
        vm.prank(admin);
        credit.setLiquiditySource(address(next));

        assertEq(usdc.balanceOf(address(liquidity)) - sourceBefore, 500e6, "the settle leg stopped running");
        assertEq(credit.owedToSource(address(liquidity)), 0, "a healthy source was parked instead of paid");
        assertEq(credit.totalOwedToSources(), 0);
        assertEq(credit.pendingPrincipal(), 0);
    }

    /// @notice The parked balance is not free money: it stays spoken for, so the migration sweep
    ///         cannot take it to the incoming manager as insurance.
    function test_R22_parkedPrincipalIsSpokenForAgainstTheMigrationSweep() public {
        uint256 owedHome = _repayIntoABlockedSource();
        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        credit.setLiquiditySource(address(next));
        assertEq(credit.owedToSource(address(liquidity)), owedHome, "premise: parked");

        // Detach, then sweep. The balance backing the park must survive it.
        CreditManager fresh = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        vm.startPrank(admin);
        vault.setCreditManager(address(fresh));
        vm.expectRevert(CreditManager.ZeroAmount.selector);
        credit.migrateReserves();
        vm.stopPrank();
        assertGe(usdc.balanceOf(address(credit)), owedHome, "the sweep took the parked principal");
    }

    // ── the flush against a source that keeps a principal book ───────────────
    //
    // **Audit round 23, finding 1, and the reason the defect survived a whole round is in this
    // heading.** Every test above drives `flushPrincipalTo` against `TreasuryLiquiditySource`,
    // the one source for which a bare push is harmless - its `outstandingPrincipal` is
    // book-keeping nothing reads. MEASURED by the auditor: that was the *only* test of the
    // function in the tree. A pool's counter is priced into `totalAssets()` and gates two
    // repoints, so the same push leaves it counting the money twice, forever.

    /// @dev The same park the round-22 tests build, with a source that keeps a real principal
    ///      book on the funding leg instead of a treasury. `setCreditManager` is set here and
    ///      nowhere else in this file: it is what makes the mock answer the question the flush now
    ///      asks before it decides whether a bare push is safe.
    function _parkAgainstAPoolThatFundedTheBook() internal returns (MockLenderPool pool) {
        pool = _poolFundsTheBook();
        pool.setCreditManager(address(credit));

        vm.startPrank(alice);
        credit.borrow(500e6);
        usdc.approve(address(credit), 500e6);
        credit.repay(500e6);
        vm.stopPrank();
        assertEq(credit.totalDebt(), 0, "premise: the book is flat");
        assertEq(credit.pendingPrincipal(), 500e6, "premise: the principal is waiting to go home");
        assertEq(pool.outstandingPrincipal(), 500e6, "premise: the pool still records the loan");

        // The condition the park exists for, and the one round 22 measured on real USDC.
        usdc.setBlocked(address(pool), true);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, address(pool)));
        credit.settlePrincipal();

        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        credit.setLiquiditySource(address(next));
        assertEq(credit.owedToSource(address(pool)), 500e6, "premise: parked against the pool that lent it");
        usdc.setBlocked(address(pool), false);
    }

    /// @notice **The finding.** A flush to a source that still answers to this manager goes through
    ///         that source's own books, so the money and the counter move together.
    /// @dev MEASURED before the fix, on the real Phase-4 wiring and against a `settlePrincipal`
    ///      control: identical USDC delivered, `outstandingPrincipal` 500000000 against 0 and
    ///      `totalAssets()` +500000000 against unchanged. The overstatement never comes down,
    ///      because nothing else in the protocol can move that counter.
    function test_R23_01_theFlushGoesThroughTheSourcesOwnBooks() public {
        MockLenderPool pool = _parkAgainstAPoolThatFundedTheBook();
        uint256 poolCashBefore = usdc.balanceOf(address(pool));

        vm.prank(makeAddr("stranger")); // permissionless, exactly as before
        credit.flushPrincipalTo(address(pool));

        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, 500e6, "the money still goes home");
        assertEq(pool.outstandingPrincipal(), 0, "DEFECT: the pool went on counting the same principal");
        assertEq(credit.owedToSource(address(pool)), 0, "the park is spent");
        assertEq(credit.totalOwedToSources(), 0, "and the sum with it");
        assertEq(usdc.allowance(address(credit), address(pool)), 0, "no standing allowance");
    }

    /// @notice A source that still answers to this manager and refuses is TOLD, not paid by a route
    ///         that would corrupt it - and the park survives the refusal intact.
    /// @dev The re-park is the half that matters. `owedToSource` has one drain, no owner rescue and
    ///      is excluded from `sweepFreeBalanceToInsurance`, so a fix that zeroed the entry and then
    ///      failed to deliver would strand the money harder than the defect it replaced. Asserted
    ///      on all three of the counter, the sum and the balance, because a revert alone would not
    ///      distinguish "nothing happened" from "the state was rolled back for another reason".
    function test_R23_01_aRefusingAttachedSourceIsRefusedRatherThanCorrupted() public {
        MockLenderPool pool = _parkAgainstAPoolThatFundedTheBook();
        pool.setRefusingPrincipal(true);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));

        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.PrincipalRefused.selector, address(pool), uint256(500e6))
        );
        vm.prank(makeAddr("stranger"));
        credit.flushPrincipalTo(address(pool));

        assertEq(credit.owedToSource(address(pool)), 500e6, "the park must survive a refusal");
        assertEq(credit.totalOwedToSources(), 500e6, "and so must the sum");
        assertEq(usdc.balanceOf(address(pool)), poolCashBefore, "nothing may leave on a refusal");
        assertEq(pool.outstandingPrincipal(), 500e6, "and the source's own book is untouched");

        // Retryable forever: the refusal is a state, not a verdict.
        pool.setRefusingPrincipal(false);
        vm.prank(makeAddr("stranger"));
        credit.flushPrincipalTo(address(pool));
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, 500e6, "the retry must deliver");
        assertEq(pool.outstandingPrincipal(), 0, "through the source's books, as before");
    }

    /// @notice CONTROL: the round-22 escape is intact. A source that has repointed away cannot run
    ///         its own bookkeeping call, and the bare push is still what delivers it.
    /// @dev This is the case the original `Not repayPrincipal` docstring was written about, and it
    ///      is real - `TreasuryLiquiditySource.setCreditManager` carries no guard at all, so a
    ///      detached treasury is one owner call away at any time. Without this control the fix
    ///      above would be indistinguishable from one that simply refuses every hard case.
    function test_R23_01_control_aDetachedSourceStillGetsTheBarePush() public {
        uint256 owedHome = _repayIntoABlockedSource();
        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.startPrank(admin);
        credit.setLiquiditySource(address(next));
        // The outgoing treasury moves on. `repayPrincipal` from this manager is gone for good.
        liquidity.setCreditManager(makeAddr("someOtherManager"));
        vm.stopPrank();
        usdc.setBlocked(address(liquidity), false);

        uint256 sourceBefore = usdc.balanceOf(address(liquidity));
        vm.prank(makeAddr("stranger"));
        credit.flushPrincipalTo(address(liquidity));

        assertEq(usdc.balanceOf(address(liquidity)) - sourceBefore, owedHome, "the escape stopped working");
        assertEq(credit.owedToSource(address(liquidity)), 0, "and the park must still clear");
        assertEq(credit.totalOwedToSources(), 0);
    }

    /// @notice CONTROL: an address that cannot answer `creditManager()` at all is treated as not
    ///         ours, so a third-party source that never had the pointer keeps the round-22 escape.
    /// @dev The fail-open direction of the probe, stated as a test rather than as a comment. An
    ///      unset pointer and a missing one are the same answer by design - `address(0)` is not
    ///      this manager, and neither is silence - so this is the branch every other fixture in
    ///      the file, and every third-party source, lands on.
    function test_R23_01_control_aSourceThatCannotAnswerIsStillPushedTo() public {
        MockLenderPool pool = _parkAgainstAPoolThatFundedTheBook();
        // Never told who its manager is, which is every other fixture in this file.
        pool.setCreditManager(address(0));
        pool.setRefusingPrincipal(true);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));

        vm.prank(makeAddr("stranger"));
        credit.flushPrincipalTo(address(pool));

        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, 500e6, "the bare push must still run");
        assertEq(credit.owedToSource(address(pool)), 0, "and clear the park");
    }

    // ── withdrawal shares the borrow formula ─────────────────────────────────

    /// @dev The same position must be judged identically whether the LTV moves because
    ///      debt went up or because collateral came out. That is why the formula lives
    ///      in LtvMath rather than being written twice.
    function test_withdrawalBoundaryMatchesBorrowBoundary() public {
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

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
        CollateralVault otherVault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        CreditManager foreign = new CreditManager(
            usdc,
            ICollateralVault(address(otherVault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
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
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        uint256 ltvBefore = credit.currentLtvBps(alice);
        uint256 hfBefore = credit.healthFactor(alice);

        _distribute(400e6); // earned, but nobody has settled

        assertEq(credit.debtOf(alice), loan, "still unsettled");
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

        CreditManager fresh = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
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
        // The settle that cleared the debt also handed the prepaid bounty back, because a
        // debt-free position has nothing left for it to insure.
        assertEq(credit.bountyEscrowOf(alice), 0, "bounty refunded when yield cleared the debt");

        CreditManager fresh = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        vm.prank(admin);
        vault.setCreditManager(address(fresh));

        vm.prank(alice);
        credit.claimSurplus();
        // Alice is square on the loan itself: she received the disbursement, the debt was
        // cleared by yield, and everything recorded as hers, refunded bounty included, paid out.
        assertEq(
            usdc.balanceOf(alice),
            500e6 - Config.LIQUIDATION_CALL_BOUNTY + owed,
            "recorded surplus still payable"
        );
    }

    /// @dev A third party clearing the debt refunds the escrow rather than consuming it. The
    ///      tail settlement is gated on the borrower paying for themselves, so `repayFor`
    ///      cannot spend money that is not the payer's - it goes back to the borrower who
    ///      prepaid it, as claimable.
    function test_repayFor_refundsTheEscrowRatherThanSpendingIt() public {
        vm.prank(alice);
        credit.borrow(500e6);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY);
        uint256 bobBefore = 500e6;

        usdc.mint(bob, bobBefore);
        vm.startPrank(bob);
        usdc.approve(address(credit), bobBefore);
        credit.repayFor(alice, 500e6);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 0);
        // Bob paid the whole debt in cash. None of it came out of alice's escrow.
        assertEq(usdc.balanceOf(bob), 0, "no part of the debt was met from the escrow");
        assertEq(credit.bountyEscrowOf(alice), 0);
        assertEq(credit.totalBountyEscrowed(), 0);
        assertEq(
            credit.claimableOf(alice),
            Config.LIQUIDATION_CALL_BOUNTY,
            "the prepaid bounty went back to the borrower who prepaid it"
        );
    }

    // ── The prepaid liquidation bounty ───────────────────────────────────────

    /// @dev The dust guard. A position under the threshold is never charged, so the smallest
    ///      borrows this contract permits keep disbursing to the wei - which matters, because
    ///      a floor on borrow size would have been a risk-parameter change touching fixtures
    ///      all over this suite, and the mechanism does not need one.
    function test_borrow_belowTheDustThresholdIsNotCharged() public {
        vm.prank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT - 1);

        assertEq(usdc.balanceOf(alice), Config.MIN_BOUNTIED_DEBT - 1, "disbursed in full");
        assertEq(credit.bountyEscrowOf(alice), 0);
        assertEq(credit.totalBountyEscrowed(), 0);
    }

    /// @dev The guard keys on the debt a borrow results in, not on the amount borrowed.
    ///      Keying on the amount would make the charge opt-out: a borrower could walk to the
    ///      per-account cap in slices that are each under the threshold and never pay it.
    function test_borrow_crossingTheThresholdInSlicesIsStillCharged() public {
        uint256 slice = Config.MIN_BOUNTIED_DEBT / 2;
        vm.startPrank(alice);
        credit.borrow(slice);
        assertEq(credit.bountyEscrowOf(alice), 0, "under the threshold, nothing charged yet");

        credit.borrow(slice); // now at MIN_BOUNTIED_DEBT
        vm.stopPrank();

        assertEq(credit.debtOf(alice), Config.MIN_BOUNTIED_DEBT);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "charged on the crossing");
        assertEq(usdc.balanceOf(alice), Config.MIN_BOUNTIED_DEBT - Config.LIQUIDATION_CALL_BOUNTY);
    }

    /// @dev Topped up to the constant rather than accumulated, so a borrower who draws
    ///      repeatedly pays for one bounty and not one per draw.
    function test_borrow_repeatedDrawsTopUpRatherThanAccumulate() public {
        vm.startPrank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT);
        credit.borrow(60e6);
        credit.borrow(60e6);
        vm.stopPrank();

        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "charged exactly once");
        assertEq(
            usdc.balanceOf(alice),
            Config.MIN_BOUNTIED_DEBT + 120e6 - Config.LIQUIDATION_CALL_BOUNTY
        );
    }

    /// @dev The one transaction-wide cliff: existing debt just under the threshold, and a
    ///      borrow small enough to cross it without funding the charge. Refused by name rather
    ///      than clamped, because an under-funded escrow would pay a smaller bounty than the
    ///      constant advertises and the caller would have no way to know before spending gas.
    function test_borrow_revertsWhenTheCrossingDrawCannotFundTheBounty() public {
        vm.startPrank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT - 1);

        uint256 tooSmall = Config.LIQUIDATION_CALL_BOUNTY - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BorrowBelowBounty.selector, tooSmall, Config.LIQUIDATION_CALL_BOUNTY
            )
        );
        credit.borrow(tooSmall);
        vm.stopPrank();
    }

    /// @notice Anyone may arm anyone's position, capped at the charge.
    /// @dev **Audit round eighteen: `BorrowBelowBounty` and `PerAccountCapExceeded` have no
    ///      shared feasibility check.** A borrower whose debt sits within
    ///      `LIQUIDATION_CALL_BOUNTY` of the per-account cap would be refused for drawing too
    ///      little to fund the charge and refused again for drawing enough, so no borrow re-arms
    ///      them. The arithmetic hole is unchanged and is asserted below.
    ///
    ///      **What did change is its reachability, and that is worth recording rather than
    ///      quietly banking.** The only executed route into that state was the strip - liquidate,
    ///      cure, cancel - and parking the escrow closed it: the round-eighteen PoC for the band
    ///      now fails on its own premise, `escrow emptied: 25000000 != 0`. No other route into it
    ///      was found. So this function has **no demonstrated trigger today**. It is kept because
    ///      the hole is arithmetic rather than incidental, and because the two caps it sits
    ///      between are **now** admin-settable and expected to ratchet - `RiskParams` shipped
    ///      them into storage, so a cap that moves down past a live position reopens exactly this
    ///      band, with no code change to notice it. The premise below therefore reads the live
    ///      cap rather than a constant: it is the assertion that fails first if a move ever makes
    ///      the band bigger than the charge it is measured against.
    ///
    ///      Permissionless for the same reason `fundInsurance` is: whoever expects to profit from
    ///      liquidating a position can arm it themselves for less than the reward.
    /// @notice Lowering the per-account cap onto a live position does NOT reopen the un-armable
    ///         band, and this is where that is settled rather than argued about.
    /// @dev **The deferral this test was written for, moved out of a docstring and made to run.**
    ///      The round-19 remediation asked the new setter to refuse a downward move of `PER_ACCOUNT_BORROW_CAP`
    ///      that "drops the band onto positions already open". Building it turned up two reasons
    ///      not to, and the second is the one that matters.
    ///
    ///      First, the check is not expressible. It asks whether any open position has
    ///      `debtOf > newCap - LIQUIDATION_CALL_BOUNTY`, and this contract has no borrower
    ///      enumeration: `debtOf` is a bare mapping and the only aggregate is `totalDebt`.
    ///      Building one means an on-chain holder list, which the single-write yield accumulator
    ///      exists specifically to avoid.
    ///
    ///      Second, and decisively: **a cap move cannot create the band.** Read `borrow` again.
    ///      `bountyDue` is `LIQUIDATION_CALL_BOUNTY - held`, so it is zero whenever the escrow is
    ///      already full - and any position that has ever crossed `MIN_BOUNTIED_DEBT` has a full
    ///      escrow, because that is when the charge was taken. Below the threshold no charge is
    ///      due at all. So the band needs a *depleted* escrow at a debt above the threshold, and
    ///      the only thing that empties an escrow is a liquidation consuming it. Moving a cap
    ///      empties nothing.
    ///
    ///      That is what this test measures: the cap drops under a live armed position, and the
    ///      borrower is refused for the honest reason (they are over the new cap) rather than
    ///      trapped between two errors. The premise behind that request was corrected after it was made.
    function test_loweringThePerAccountCapDoesNotStrandAnArmedPosition() public {
        uint256 loan = Config.MIN_BOUNTIED_DEBT + 100e6;
        vm.prank(alice);
        credit.borrow(loan);
        assertEq(
            credit.bountyEscrowOf(alice),
            Config.LIQUIDATION_CALL_BOUNTY,
            "premise: crossing the threshold arms the escrow, so no further charge can be due"
        );

        // Drop the cap to just above the live debt: the band, if a cap move could create one,
        // would sit exactly here - within one bounty of the ceiling.
        uint64 tightened = uint64(loan + Config.LIQUIDATION_CALL_BOUNTY / 2);
        IRiskParams.Params memory p = riskParams.params();
        p.perAccountBorrowCap = tightened;
        vm.prank(admin);
        riskParams.setRiskParams(p);

        // The escrow is untouched by the cap move, so nothing further is owed and the dust guard
        // cannot fire. The only limit left is the cap itself, which is the honest one.
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "the cap move emptied an escrow");

        uint256 headroom = tightened - loan;
        vm.prank(alice);
        credit.borrow(headroom);
        assertEq(credit.debtOf(alice), tightened, "the borrower could not draw their remaining headroom");

        // And one unit past it is refused by the cap, by name, not by an unsatisfiable pair.
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.PerAccountCapExceeded.selector, uint256(tightened) + 1, tightened)
        );
        vm.prank(alice);
        credit.borrow(1);
    }

    /// @notice The band's real precondition, pinned so the cause is not mislaid again.
    /// @dev With a full escrow the charge is zero at every cap value, so no ordering of the two
    ///      guards can be unsatisfiable. This is the algebra the test above demonstrates, asserted
    ///      directly so that a change to `borrow`'s charging rule breaks it here rather than
    ///      somewhere three sessions later.
    function test_theUnsatisfiableBandNeedsADepletedEscrowNotACapMove() public {
        vm.prank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "armed at the threshold");

        // Whatever the cap becomes, `bountyDue` is zero for this position, so `BorrowBelowBounty`
        // is unreachable for it and only the cap can refuse a draw.
        for (uint64 cap = 1_000e6; cap <= 20_000e6; cap += 6_000e6) {
            IRiskParams.Params memory p = riskParams.params();
            p.globalBorrowCap = cap > p.globalBorrowCap ? cap : p.globalBorrowCap;
            p.perAccountBorrowCap = cap;
            vm.prank(admin);
            riskParams.setRiskParams(p);
            assertEq(
                credit.bountyEscrowOf(alice),
                Config.LIQUIDATION_CALL_BOUNTY,
                "an escrow that is already full stays full whatever the cap does"
            );
        }
    }

    function test_fundBounty_armsAPositionNoBorrowAmountCouldArm() public {
        // The arithmetic, stated where a parameter move would break it: any position whose
        // headroom is under the charge has an empty feasible band.
        assertLt(
            Config.LIQUIDATION_CALL_BOUNTY,
            perAccountBorrowCap(),
            "premise: the charge fits inside the cap at all"
        );

        // A reachable unarmed position: under the dust threshold, so never charged.
        vm.prank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT - 1);
        assertEq(credit.bountyEscrowOf(alice), 0, "premise: unarmed, and legitimately so");
        assertEq(usdc.balanceOf(alice), Config.MIN_BOUNTIED_DEBT - 1, "the whole draw disbursed");

        // Funded by the borrower herself: since round 21 that is the only funder this accepts,
        // and it is the funder every case in `fundBounty`'s own docstring describes.
        usdc.mint(alice, 2 * Config.LIQUIDATION_CALL_BOUNTY);
        uint256 heldBefore = usdc.balanceOf(address(credit));

        vm.startPrank(alice);
        usdc.approve(address(credit), 2 * Config.LIQUIDATION_CALL_BOUNTY);
        credit.fundBounty(alice, Config.LIQUIDATION_CALL_BOUNTY);

        // Capped at the charge, and refused rather than clamped: a clamp would take more USDC
        // than it credited.
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BountyFundingOverflows.selector,
                Config.LIQUIDATION_CALL_BOUNTY + 1,
                Config.LIQUIDATION_CALL_BOUNTY
            )
        );
        credit.fundBounty(alice, 1);
        vm.stopPrank();

        assertEq(
            credit.bountyEscrowOf(alice),
            Config.LIQUIDATION_CALL_BOUNTY,
            "armed through the route no borrow amount could reach"
        );
        assertEq(credit.totalBountyEscrowed(), Config.LIQUIDATION_CALL_BOUNTY);
        assertEq(
            usdc.balanceOf(address(credit)) - heldBefore,
            Config.LIQUIDATION_CALL_BOUNTY,
            "and the USDC actually arrived, so the escrow is funded and not just recorded"
        );
    }

    /// @notice Only the borrower may write their own escrow. Audit round 21, finding 15.
    /// @dev **The hazard, then the refusal.** `borrow` withholds the bounty from the borrower's
    ///      own disbursement, so `_repay`'s escrow settlement is exactly neutral - it hands back
    ///      money the same borrower already paid. `fundBounty` wrote the same slot out of a
    ///      stranger's wallet, and `_repay`'s gate is `payer == borrower && paid == debt` with
    ///      nothing in it about provenance. MEASURED at `868edb4` on exactly this fixture: a
    ///      stranger funds 25.000000 for a borrower under `MIN_BOUNTIED_DEBT`, the borrower
    ///      simply repays, and spends **474.999999 against a debt of 499.999999** - net
    ///      +25.000000 to the borrower, -25.000000 to the stranger, no liquidation and no work
    ///      done. Solvency was never touched (`held == spokenFor` throughout), which is why it
    ///      is a theft from the funder rather than from the protocol.
    ///
    ///      **The path was deleted rather than policed**, and the alternative was priced first:
    ///      recording the funder means a per-borrower ledger of mixed ownership - `borrow` writes
    ///      this slot too - threaded through `_repay`'s netting, `_refundBounty`, `liquidate`'s
    ///      park and `ParkedBounty`, to preserve a path the finding shows is never rational.
    ///      `test_fundBounty_armsAPositionNoBorrowAmountCouldArm` above is the evidence that
    ///      nothing `fundBounty`'s docstring claims was lost: every case it names is a borrower
    ///      arming their own position.
    function test_fundBounty_refusesAnyFunderButTheBorrower() public {
        vm.prank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT - 1);
        assertEq(credit.bountyEscrowOf(alice), 0, "premise: unarmed, and legitimately so");

        address funder = makeAddr("funder");
        usdc.mint(funder, Config.LIQUIDATION_CALL_BOUNTY);
        vm.startPrank(funder);
        usdc.approve(address(credit), Config.LIQUIDATION_CALL_BOUNTY);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.BountyFundingForAnother.selector, alice));
        credit.fundBounty(alice, Config.LIQUIDATION_CALL_BOUNTY);
        vm.stopPrank();

        assertEq(credit.bountyEscrowOf(alice), 0, "the escrow was written anyway");
        assertEq(usdc.balanceOf(funder), Config.LIQUIDATION_CALL_BOUNTY, "the funder was charged anyway");
    }

    /// @notice The borrower's cash cost of clearing a debt is the debt, whoever else is around.
    /// @dev The arithmetic half of the finding, kept as a live assertion rather than a figure in
    ///      a comment. Before the refusal above this read 474.999999 against a debt of
    ///      499.999999 once a stranger had paid in; the self-funded control was exactly neutral
    ///      and still is. **Neuter check: delete the `msg.sender != borrower` line and this test
    ///      stays green** - it is the refusal test that catches that, which is why both are here.
    function test_repay_theSelfFundedEscrowIsExactlyNeutral() public {
        uint256 debt = Config.MIN_BOUNTIED_DEBT - 1;
        vm.prank(alice);
        credit.borrow(debt);

        usdc.mint(alice, Config.LIQUIDATION_CALL_BOUNTY);
        uint256 held = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(credit), Config.LIQUIDATION_CALL_BOUNTY);
        credit.fundBounty(alice, Config.LIQUIDATION_CALL_BOUNTY);
        vm.stopPrank();

        usdc.mint(alice, debt);
        vm.startPrank(alice);
        usdc.approve(address(credit), debt);
        credit.repay(debt);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 0, "the debt did not clear");
        assertEq(held + debt - usdc.balanceOf(alice), debt, "self-funding is not neutral");
        assertEq(credit.bountyEscrowOf(alice), 0, "the escrow outlived the debt");
    }

    /// @notice An escrow insures a debt, so `fundBounty` refuses where there is none.
    /// @dev The finding's second face: there was no `debtOf != 0` guard here while
    ///      `_refundBounty` keys on `debtOf == 0`, so an escrow written against a debt-free
    ///      position was withdrawable through `claimSurplus` the moment it landed - measured at
    ///      25.000000 out and 25.000000 straight back. Harmless once the funder must be the
    ///      borrower, and closed anyway: the state has no meaning to give a later reader.
    function test_fundBounty_refusesAPositionWithNoDebt() public {
        assertEq(credit.debtOf(alice), 0, "premise: no debt at all");

        usdc.mint(alice, Config.LIQUIDATION_CALL_BOUNTY);
        vm.startPrank(alice);
        usdc.approve(address(credit), Config.LIQUIDATION_CALL_BOUNTY);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.BountyFundingWithoutDebt.selector, alice));
        credit.fundBounty(alice, Config.LIQUIDATION_CALL_BOUNTY);
        vm.stopPrank();

        assertEq(credit.bountyEscrowOf(alice), 0, "an escrow with nothing to insure");
        assertEq(credit.totalBountyEscrowed(), 0, "and the total moved with it");
    }

    /// @dev **The borrower's cash cost of a loan is the loan.** They receive the draw less the
    ///      bounty, and the bounty settles the last slice of the debt on the way out, so they
    ///      never have to find money they were not given. Without this rule a fully repaid
    ///      position would require the borrower to source the bounty from somewhere else and
    ///      claim it back afterwards, which is a real defect and not a convenience.
    function test_repay_theEscrowSettlesTheTailSoNoExtraCashIsNeeded() public {
        vm.startPrank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT);
        uint256 received = usdc.balanceOf(alice);
        assertEq(received, Config.MIN_BOUNTIED_DEBT - Config.LIQUIDATION_CALL_BOUNTY);

        // Holding only what was disbursed, and approving only that.
        usdc.approve(address(credit), received);
        credit.repay(Config.MIN_BOUNTIED_DEBT);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 0, "the whole debt is cleared");
        assertEq(usdc.balanceOf(alice), 0, "every disbursed wei went back and no more");
        assertEq(credit.pendingPrincipal(), Config.MIN_BOUNTIED_DEBT, "the source is owed the full loan");
        assertEq(credit.bountyEscrowOf(alice), 0);
        assertEq(credit.totalBountyEscrowed(), 0);
        assertEq(credit.claimableOf(alice), 0, "consumed by the debt, not handed back twice");
    }

    /// @dev A partial repayment must not disarm the bounty. The position is still live and
    ///      still liquidatable, so the prepayment still has something to insure.
    function test_repay_partialRepaymentLeavesTheEscrowIntact() public {
        vm.startPrank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT);
        usdc.approve(address(credit), 100e6);
        credit.repay(100e6);
        vm.stopPrank();

        assertGt(credit.debtOf(alice), 0);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "still armed");
    }

    /// @dev The passive path. Yield alone can take a debt to zero with no transaction from the
    ///      borrower, and when it does the bounty has nothing left to insure. The refund is
    ///      lazy, like `claimableOf` itself, so it lands on whichever settle gets there first.
    function test_settle_refundsTheEscrowWhenYieldClearsTheDebt() public {
        vm.prank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT);

        _distribute(700e6);
        credit.settle(alice);

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.bountyEscrowOf(alice), 0, "refunded by the settle that cleared the debt");
        assertEq(credit.totalBountyEscrowed(), 0);
        assertGe(
            credit.claimableOf(alice),
            Config.LIQUIDATION_CALL_BOUNTY,
            "and it is claimable rather than stranded"
        );
    }

    /// @dev A debt that reached zero passively but has not been refunded yet is still armed,
    ///      so re-borrowing against it costs nothing. The escrow that would have come back is
    ///      still sitting there and still doing its job.
    function test_borrow_afterAPassiveZeroDoesNotChargeTwice() public {
        vm.prank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT);

        _distribute(700e6);
        credit.settle(alice); // debt cleared and the escrow refunded

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.borrow(Config.MIN_BOUNTIED_DEBT);

        // Refunded, so this is a fresh position and it pays again - which is correct.
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY);
        assertEq(
            usdc.balanceOf(alice),
            balanceBefore + Config.MIN_BOUNTIED_DEBT - Config.LIQUIDATION_CALL_BOUNTY
        );
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
        CreditManager credit2 = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
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

    // ── streaming: the per-call floor (audit round 21, finding 12) ────────────

    /// @dev Walk the stream one second at a time. The point of the fixture is that the
    ///      *number of calls* is not a protocol parameter: `accrueYield()` is permissionless
    ///      and free of any cooldown, and every borrow, repay, deposit and withdrawal
    ///      reaches the same code through `_settle`. A hostile caller and an ordinary busy
    ///      market drive it identically, which is why the finding needed no attacker.
    function _walk(uint256 secondsToWalk) private {
        for (uint256 i = 0; i < secondsToWalk; ++i) {
            skip(1);
            credit.accrueYield();
        }
    }

    /// @notice Accruing every second delivers exactly what accruing once would have.
    /// @dev **The round-21 finding, closed.** `_accrue` used to floor
    ///      `(elapsed x rate) / ACC_PRECISION` against the time since the *last call* while
    ///      writing `lastAccrualAt` unconditionally, so the integer division was charged once
    ///      per invocation instead of once per stream. MEASURED before the fix on this exact
    ///      fixture: 5,080,000 delivered against 5,092,592 owed, 12,592 wei short over 20,000
    ///      seconds of a 110 USDC stream. The pot is not destroyed - it stays in
    ///      `undistributedYield` and rolls into the next stream - but it is deferred by an
    ///      amount any stranger can choose, and it moves `currentDebtOf`, which is what
    ///      `liquidate`, `cancel` and `_impairmentFor` price on.
    ///
    ///      Asserted against the one-call control rather than a literal, so the test states
    ///      the property - call cadence does not change what a stream pays - rather than a
    ///      number a parameter change would falsify.
    function test_stream_perSecondAccrualDeliversWhatOneCallWould() public {
        uint256 pot = 110e6;
        uint256 window = 20_000;

        _deliver(pot);
        uint256 snapshot = vm.snapshotState();

        _walk(window);
        uint256 walked = pot - credit.undistributedYield();

        vm.revertToState(snapshot);
        skip(window);
        credit.accrueYield();
        uint256 oneCall = pot - credit.undistributedYield();

        assertGt(oneCall, 0, "control delivered nothing - the fixture is not streaming");
        assertEq(walked, oneCall, "the per-call floor is still being charged");
    }

    /// @notice A pot whose wei count is below the stream's second count still pays out.
    /// @dev **The sharp case, and it needs no attacker.** `distributeYield` rates a pot over
    ///      `max(elapsed, 5 days, remaining)` and its own comment names the ordinary causes of
    ///      a long `elapsed` - a keeper outage, a run of declined epochs, the gap before the
    ///      harvester is wired at all. `Config.MIN_EPOCH_YIELD` is 1 USDC, so a 1 USDC
    ///      borrower share rated over 30 days is a legal epoch whose `yieldRate` is below
    ///      `ACC_PRECISION`. Every per-second slice then floored to zero while the clock ran
    ///      on: MEASURED before the fix this delivered **0** where 1,929 was owed, a 100%
    ///      suppression for as long as anybody kept calling.
    function test_stream_aSubWeiRateIsNotSuppressedByPerSecondAccrual() public {
        skip(30 days); // the harvester is wired in `setUp`; nothing has been distributed yet
        uint256 pot = Config.MIN_EPOCH_YIELD;
        _deliver(pot);
        assertLt(credit.yieldRate(), 1e18, "rate is not sub-wei-per-second; the case is not set up");

        uint256 window = 5_000;
        uint256 snapshot = vm.snapshotState();

        _walk(window);
        uint256 walked = pot - credit.undistributedYield();

        vm.revertToState(snapshot);
        skip(window);
        credit.accrueYield();
        uint256 oneCall = pot - credit.undistributedYield();

        assertGt(oneCall, 0, "control delivered nothing - the fixture is not streaming");
        assertEq(walked, oneCall, "a sub-wei rate is still suppressed by per-second accrual");
    }

    /// @notice The suppression reached the borrower's debt, and no longer does.
    /// @dev `currentDebtOf` projects the stream on top of the stored figure, so a slice the
    ///      accumulator never received is a write-down the borrower never got. MEASURED before
    ///      the fix: 628,750,000 under per-second accrual against 628,748,071 left alone -
    ///      1,929 wei of write-down suppressed, on the debt three liquidation paths price
    ///      against.
    function test_stream_perSecondAccrualDoesNotSuppressTheBorrowersWriteDown() public {
        // `_maxBorrow()` reads `RiskParams` through an external call, and an external view in
        // argument position spends the prank. Read first, then prank, then call.
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        skip(30 days);
        _deliver(Config.MIN_EPOCH_YIELD);
        assertLt(credit.yieldRate(), 1e18, "rate is not sub-wei-per-second");

        uint256 stored = credit.debtOf(alice);
        uint256 snapshot = vm.snapshotState();
        _walk(5_000);
        uint256 debtWalked = credit.currentDebtOf(alice);

        vm.revertToState(snapshot);
        skip(5_000);
        uint256 debtLeftAlone = credit.currentDebtOf(alice);

        assertLt(debtLeftAlone, stored, "control: the stream wrote nothing down");
        assertEq(debtWalked, debtLeftAlone, "per-second accrual still suppresses the write-down");
    }

    /// @notice The unstaked branch has the same floor and got the same fix.
    /// @dev **The sibling in the same commit.** `_accrue`'s `bonds == 0` arm routes the skipped
    ///      slice to `insuranceFund` with arithmetic that was character-for-character the shape
    ///      the accumulator arm had. Fixing one and not the other would have left the defect
    ///      standing on the path that runs when nothing is staked, which is the path nobody
    ///      watches - and `_pushLossReserves` mirrors that fund into the pool's exit pricing,
    ///      so a short insurance fund is a lender-facing number.
    function test_stream_theUnstakedSliceIsNotShortChangedByPerSecondAccrual() public {
        skip(30 days);
        _deliver(Config.MIN_EPOCH_YIELD);
        assertLt(credit.yieldRate(), 1e18, "rate is not sub-wei-per-second");

        vm.prank(alice);
        vault.withdrawBonds(BONDS);
        assertEq(vault.totalBondCount(), 0, "the unstaked branch is not the one under test");

        uint256 window = 5_000;
        uint256 opening = credit.insuranceFund();
        uint256 snapshot = vm.snapshotState();

        _walk(window);
        uint256 walked = credit.insuranceFund() - opening;

        vm.revertToState(snapshot);
        skip(window);
        credit.accrueYield();
        uint256 oneCall = credit.insuranceFund() - opening;

        assertGt(oneCall, 0, "control routed nothing to insurance - the fixture is not streaming");
        assertEq(walked, oneCall, "the unstaked slice is still floored per call");
    }

    /// @notice A re-rate moves the origin the slice is floored against, and the stream still
    ///         cannot outrun its pot.
    /// @dev **The sibling `distributeYield` owed the fix.** Its four-line reset gained a fifth
    ///      field, and `_sliceOwed` is only exact because `owedByLast` is exactly zero on a
    ///      stream's first call - which is true only while the origin IS the rating instant.
    ///
    ///      Leave the origin behind and the arithmetic still telescopes, which is why this is
    ///      worth a test rather than a comment: it looks fine. What breaks is subtler and worse.
    ///      `floor(a) - floor(b)` can exceed `floor(a - b)` by one, so a stream rated against a
    ///      stale origin releases **one wei more than its rate owes** and the `amount > pot`
    ///      clamp starts binding - a line whose own comment says the rate "can never outrun" the
    ///      pot and which is clamped only "rather than let rounding underflow the counter".
    ///      MEASURED with the origin left at zero: a 100 USDC stream run to completion leaves a
    ///      residual of **0** against the **1** the rate actually owes. That is a documented-dead
    ///      guard quietly becoming the thing holding the accounting up, which is a shape this
    ///      protocol has now been bitten by twice.
    function test_stream_aReRateMovesTheOriginAndTheStreamCannotOutrunItsPot() public {
        uint256 pot = 100e6;
        _deliver(pot);

        // No `elapsed` has built up in this fixture, so the stream is rated over the floor.
        uint256 duration = Config.YIELD_STREAM_DURATION;
        assertEq(credit.streamEndsAt(), block.timestamp + duration, "unexpected stream window");
        uint256 owedByTheRate = (duration * credit.yieldRate()) / 1e18;

        // The money assertion first, deliberately: it is the one that goes red when the origin
        // is left behind, and a mechanism assertion in front of it would mask that.
        skip(duration);
        credit.accrueYield();
        assertEq(pot - credit.undistributedYield(), owedByTheRate, "the stream released more than its rate owed");
        assertLe(credit.undistributedYield(), 1, "the residual over a full stream is above one wei");
        assertEq(credit.streamStartedAt(), credit.streamEndsAt() - duration, "the origin is not the rating instant");

        // And a fresh epoch starts from the new instant rather than paying out its history.
        uint256 carried = credit.undistributedYield();
        _deliver(pot);
        assertEq(credit.streamStartedAt(), block.timestamp, "the origin did not move with the re-rate");
        assertEq(credit.undistributedYield(), carried + pot, "the re-rate paid something out as it ran");

        skip(1);
        credit.accrueYield();
        uint256 firstSlice = (carried + pot) - credit.undistributedYield();
        assertApproxEqAbs(
            firstSlice, credit.yieldRate() / 1e18, 1, "the new stream's first slice is not one second's worth"
        );
    }

    // ── liquidate: the gate ──────────────────────────────────────────────────

    /// @dev Wires a recording auction so `liquidate` can reach the line past its own
    ///      gate. A typed call to an address with no code reverts, so an EOA will not
    ///      do here.
    /// @dev Wires the *same* auction the vault already honours. `liquidate` now refuses
    ///      to open an auction the vault will not accept, because such an auction has no
    ///      reachable exit - so a fixture pointing the two at different mocks no longer
    ///      models anything real.
    function _wireAuction() internal returns (MockLiquidationAuction a) {
        a = auctionMock;
        vm.startPrank(admin);
        vault.setLiquidationAuction(address(a));
        credit.setLiquidationAuction(address(a));
        vm.stopPrank();
    }

    /// @notice New debt is refused while the wiring pointers disagree.
    /// @dev `liquidate` already refused in exactly these states - it carries an
    ///      `AuctionPointerMismatch` check - but `borrow` checked neither, so the
    ///      protocol's only risk-reduction mechanism was offline while its risk-taking
    ///      one stayed open. A manager migration cannot be atomic across two contracts,
    ///      so every one passes through this window, and it is unbounded in wall-clock
    ///      time because it ends only when the owner sends the second transaction.
    ///
    ///      The state is self-camouflaging: the auction's own `liveAuctionCount == 0`
    ///      precondition reads as "nothing in flight" precisely *because* nothing can
    ///      open an auction.
    function test_borrow_refusedWhileTheAuctionPointersDisagree() public {
        MockLiquidationAuction a = _wireAuction();

        // The auction still names the manager it was wired to: borrowing is fine.
        vm.prank(alice);
        credit.borrow(100e6);

        // Mid-migration: the auction now settles against a different manager.
        address otherManager = makeAddr("otherManager");
        a.setCreditManager(otherManager);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.AuctionPointerMismatch.selector, otherManager, address(credit)
            )
        );
        credit.borrow(100e6);

        // Repaying is never blocked - the guard must not trap anyone inside a position.
        vm.startPrank(alice);
        usdc.approve(address(credit), 100e6);
        credit.repay(100e6);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 0, "the exit stays open");

        // And it reopens the moment the migration completes.
        a.setCreditManager(address(credit));
        vm.prank(alice);
        credit.borrow(100e6);
        assertEq(credit.debtOf(alice), 100e6, "the hatch is reachable");
    }

    /// @notice The same guard, from the side the first version of it missed.
    /// @dev Round 8 caught this. The guard originally read `liquidationAuction` off
    ///      `this`, which is zero on a freshly deployed incoming manager - so on the
    ///      migration order the code actually requires (vault first, then auction) it
    ///      skipped itself in precisely the window it existed to close, and only bit if
    ///      the auction happened to be pre-wired. From the manager, Phase 2 and a
    ///      half-finished migration look identical; from the vault they do not, so the
    ///      vault is what it asks now.
    function test_borrow_refusedOnAFreshManagerWhileTheVaultAlreadyHasAnAuction() public {
        _wireAuction();

        CreditManager next = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        vm.startPrank(admin);
        next.setLiquiditySource(address(liquidity));
        next.setEpochHarvester(harvester);
        vault.setCreditManager(address(next));
        liquidity.setCreditManager(address(next));
        vm.stopPrank();

        // `next.liquidationAuction` is still zero, so `next.liquidate` cannot open an
        // auction at all. Debt drawn here would be unliquidatable until the owner sends
        // the second transaction, and nothing bounds how long that takes.
        assertEq(next.liquidationAuction(), address(0));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.AuctionPointerMismatch.selector, address(0), address(auctionMock)
            )
        );
        next.borrow(100e6);

        // Finishing the wiring opens it, so this never traps a migration.
        auctionMock.setCreditManager(address(next));
        vm.prank(admin);
        next.setLiquidationAuction(address(auctionMock));
        vm.prank(alice);
        next.borrow(100e6);
        assertEq(next.debtOf(alice), 100e6, "and the hatch is reachable");
    }

    function test_liquidate_revertsWithNoDebt() public {
        _wireAuction();
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.liquidate(alice);
    }

    function test_liquidate_revertsWhileHealthy() public {
        _wireAuction();
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.PositionHealthy.selector, maxLtvBps()));
        credit.liquidate(alice);
    }

    /// @notice The whole reason `LtvMath.exceedsLtv` exists.
    /// @dev 100 bonds at BOUNDARY_NAV is exactly $1,000 of collateral, so the threshold
    ///      sits at exactly `_debtAtThreshold()`. One extra unit of debt puts the position
    ///      genuinely past it - but `ltvBps` floors, so the view still reports the
    ///      threshold and
    ///      `healthFactor` still reports exactly 1e18 "healthy". A gate that read the
    ///      view would refuse the first position that ever becomes liquidatable.
    ///
    ///      Both halves are asserted here rather than in two tests, because the point
    ///      is precisely that they disagree.
    function test_liquidate_oneUnitPastThresholdIsLiquidatableThoughHealthFactorReadsExactlyOne() public {
        MockLiquidationAuction a = _wireAuction();

        uint256 onePastTheLine = _debtAtThreshold() + 1;
        vm.prank(alice);
        credit.borrow(onePastTheLine);
        oracle.setNav(BOUNDARY_NAV);

        assertEq(credit.currentLtvBps(alice), liquidationThresholdBps(), "the view floors to the threshold");
        assertEq(credit.healthFactor(alice), Config.HEALTH_FACTOR_SCALE, "and reports exactly healthy");

        credit.liquidate(alice);
        assertEq(a.startCalls(), 1, "but the position is genuinely past it");
        assertEq(a.lastBorrower(), alice);
        assertEq(a.lastCaller(), address(this), "the trigger, not the bidder, earns the reward");
    }

    /// @dev A position liquidatable on stored debt that a free `settle` would have
    ///      cured must survive. Settling first is what makes the gate honest.
    function test_liquidate_settlesBeforeGating() public {
        _wireAuction();
        uint256 onePastTheLine = _debtAtThreshold() + 1;
        vm.prank(alice);
        credit.borrow(onePastTheLine);
        oracle.setNav(BOUNDARY_NAV);

        // An epoch's yield lands and streams; enough of it clears the position.
        _distribute(700e6);
        skip(Config.YIELD_STREAM_DURATION);

        assertGt(credit.debtOf(alice), 0, "stored debt still says she is underwater");
        assertEq(credit.currentDebtOf(alice), 0, "but the yield already earned has cleared it");

        // Settling is what the gate does first, so it must reach `NoDebt` rather than
        // liquidating against the stale figure.
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.liquidate(alice);
    }

    /// @notice PRD §4.6: staleness pauses borrowing, never liquidation.
    function test_liquidate_worksOnStaleNavAndWhilePaused() public {
        MockLiquidationAuction a = _wireAuction();
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        oracle.setNav(BOUNDARY_NAV);
        oracle.setStale(true);
        vm.prank(admin);
        credit.pause();

        // Composed deliberately: a protocol that pauses or goes stale its way out of
        // liquidating underwater positions has only converted them into bad debt.
        credit.liquidate(alice);
        assertEq(a.startCalls(), 1);

        vm.prank(alice);
        vm.expectRevert();
        credit.borrow(1);
    }

    function test_liquidate_revertsWhenAuctionUnset() public {
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        oracle.setNav(BOUNDARY_NAV);

        vm.expectRevert(CreditManager.LiquidationAuctionUnset.selector);
        credit.liquidate(alice);
    }

    // ── proceeds, write-downs and socialisation ──────────────────────────────

    /// @dev A contract, not an EOA: `borrow` now asks the auction whether the borrower
    ///      has an open workout, and a typed call to an address with no code reverts.
    function _asAuction() internal returns (address a) {
        a = address(auctionMock);
        vm.prank(admin);
        credit.setLiquidationAuction(a);
        usdc.mint(a, 100_000e6);
        vm.prank(a);
        usdc.approve(address(credit), type(uint256).max);
    }

    function test_creditLiquidationProceeds_onlyAuction() public {
        _asAuction();
        vm.expectRevert(CreditManager.NotLiquidationAuction.selector);
        credit.creditLiquidationProceeds(alice, 1e6, 1e6);
    }

    function test_creditLiquidationProceeds_creditsBothLegsFromOnePull() public {
        address a = _asAuction();
        uint256 before = usdc.balanceOf(address(credit));

        vm.prank(a);
        credit.creditLiquidationProceeds(alice, 12e6, 30e6);

        assertEq(credit.insuranceFund(), 12e6);
        assertEq(credit.claimableOf(alice), 30e6);
        assertEq(credit.totalClaimable(), 30e6);
        assertEq(usdc.balanceOf(address(credit)) - before, 42e6, "one pull, both legs");
    }

    /// @notice Surplus is credited, never pushed - so a blacklisted borrower cannot
    ///         make every bid on their own position revert.
    function test_creditLiquidationProceeds_survivesABlacklistedBorrower() public {
        address a = _asAuction();
        usdc.setBlocked(alice, true);

        vm.prank(a);
        credit.creditLiquidationProceeds(alice, 0, 30e6);
        assertEq(credit.claimableOf(alice), 30e6, "the liquidation completed regardless");

        // Their own claim still fails, which is their liveness problem and recoverable.
        vm.prank(alice);
        vm.expectRevert();
        credit.claimSurplus();
    }

    function test_writeDownLoss_drawsInsuranceFirstAndKeepsPrincipalHonest() public {
        address a = _asAuction();
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        usdc.mint(address(this), 500e6);
        usdc.approve(address(credit), 500e6);
        credit.fundInsurance(500e6);

        uint256 principalBefore = credit.pendingPrincipal();
        vm.prank(a);
        credit.writeDownLoss(alice, 200e6);

        assertEq(credit.debtOf(alice), loan - 200e6);
        assertEq(credit.totalDebt(), loan - 200e6);
        assertEq(credit.insuranceFund(), 300e6, "insurance absorbed it");
        assertEq(credit.pendingPrincipal() - principalBefore, 200e6, "and the source is still owed it");
        assertEq(credit.unsocialisedLoss(), 0, "nothing had to reach lenders");
    }

    function test_writeDownLoss_clampsToOutstandingDebt() public {
        address a = _asAuction();
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        vm.prank(a);
        credit.writeDownLoss(alice, loan * 10);
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebt(), 0);
    }

    /// @notice The migration paths both refuse while `totalDebt != 0`, so a default
    ///         written off in narrative but not in storage bricks Phase 4 permanently.
    function test_writeDownLoss_leavesTheLiquiditySourceSwappable() public {
        address a = _asAuction();
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        usdc.mint(address(this), loan);
        usdc.approve(address(credit), loan);
        credit.fundInsurance(loan);

        vm.prank(a);
        credit.writeDownLoss(alice, loan);
        // Insurance covered it, so the source is owed the principal back and both
        // migration guards stay armed until it is actually returned.
        assertEq(credit.pendingPrincipal(), loan);
        credit.settlePrincipal();

        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.startPrank(admin);
        next.setCreditManager(address(credit));
        credit.setLiquiditySource(address(next));
        vm.stopPrank();
        assertEq(credit.liquiditySource(), address(next), "bad debt must not block the Phase-4 swap");
    }

    /// @dev Put the pool on both sides of the ledger: the source that funds the loan and the
    ///      sink that takes the loss when it defaults.
    ///
    ///      Audit round 11 made that the only wiring in which a loss can be deferred at all.
    ///      `_socialise` offers a loss to `lenderPool` only while it is also `liquiditySource`,
    ///      because the treasury bears a default by simply never being repaid - so recording the
    ///      same loss against a pool that had lent nothing was a double count, and the counter
    ///      it filled was a bearer claim that `flushSocialisedLoss` would let anyone point at
    ///      whoever held shares later. Every test below is about what happens to a loss the
    ///      lenders really did fund, so every one of them has to say so in the wiring.
    ///
    ///      This has to run before any borrow, and not merely because it reads better there:
    ///      `setLiquiditySource` refuses while `totalDebt` or `pendingPrincipal` is non-zero.
    ///      That guard is precisely what makes the current pointer a sound answer to "whose
    ///      money funded this", which is what the round-11 fix leans on, so a fixture that
    ///      swapped the source out from under a live loan would be proving something about a
    ///      state the protocol does not permit.
    function _poolFundsTheBook() internal returns (MockLenderPool pool) {
        pool = new MockLenderPool(usdc);
        usdc.mint(address(pool), FLOAT);
        vm.startPrank(admin);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        vm.stopPrank();
    }

    /// @dev A pool wired as the **loss sink only**, with the treasury still funding the book. That
    ///      is the state `DeployBase` ships, and since audit round 21 it is also the only state in
    ///      which the sink may be moved at all: `setLenderPool` refuses to leave a funder that is
    ///      itself a lender pool, so the three outgoing clauses this file tests are reachable
    ///      through this configuration and no longer through the converged one. Written as its own
    ///      helper rather than inlined, because "which door is this clause still reachable at" is
    ///      the question a reader of those tests now has to answer first.
    function _poolIsTheSinkWhileTheTreasuryFunds() internal returns (MockLenderPool pool) {
        pool = new MockLenderPool(usdc);
        usdc.mint(address(pool), FLOAT);
        vm.prank(admin);
        credit.setLenderPool(address(pool));
    }

    /// @notice **Audit round 11's executed PoC, as a regression test.** A loss banked while the
    ///         treasury funded the book must never become chargeable to pool depositors.
    /// @dev The original turned 5,000e6 into 6,250e6 with an exactly matching loss to an honest
    ///      lender. The mechanism was that `unsocialisedLoss` recorded an amount and not whose
    ///      principal funded it: the treasury era filled the counter, the switchover pointed a new
    ///      balance sheet at it, and `flushSocialisedLoss` is permissionless, so an attacker chose
    ///      the block in which depositors were charged for a loan none of their money funded.
    ///
    ///      The fix is narrower than blocking the switchover. `TreasuryLiquiditySource` has no
    ///      `socialiseLoss` at all, so the treasury already bore this default by never being
    ///      repaid - filling the counter as well was a double count. So there is nothing to
    ///      migrate, nothing to write off, and no deadlock: the counter simply never fills.
    ///
    ///      Asserted at the counter rather than at an attacker's balance because the counter is
    ///      the bearer instrument itself. With nothing in it there is nothing to point anywhere,
    ///      and every downstream step of the PoC becomes unreachable rather than merely unprofitable.
    function test_socialisedLoss_bankedAgainstTheTreasuryIsNeverChargeableToAPool() public {
        address a = _asAuction();

        // Treasury era: the float funds the book, and no pool is wired as the sink yet.
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        vm.prank(a);
        credit.writeDownLoss(alice, loan);

        assertEq(credit.unsocialisedLoss(), 0, "a treasury-funded default must leave nothing to place");

        // The switchover. It is only legal at an empty book, which is what makes "who funded this"
        // unambiguous - the source cannot move under a live loan.
        assertEq(credit.totalDebt(), 0, "the write-down must have cleared the book");
        MockLenderPool pool = _poolFundsTheBook();

        // And there is nothing for the permissionless flush to point at the new depositors.
        vm.expectRevert(CreditManager.NothingToSettle.selector);
        credit.flushSocialisedLoss();
        assertEq(pool.socialisedTotal(), 0, "the pool was charged for a loan it never funded");
    }

    /// @dev The other half of the same guard: a backlog that IS the pool's cannot be left behind by
    ///      pointing the source somewhere else. Always satisfiable, because the counter only ever
    ///      holds loss the pool funded - flush it first - so this blocks the bearer instrument
    ///      re-forming without creating the deadlock that an unconditional guard would.
    function test_setLiquiditySource_refusedWhileTheDeferredLossIsStillThePools() public {
        address a = _asAuction();
        MockLenderPool pool = _poolFundsTheBook();

        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        pool.setAccepting(false); // the default, stated so the test does not rest on it

        vm.prank(a);
        credit.writeDownLoss(alice, loan);
        assertGt(credit.unsocialisedLoss(), 0, "the fixture must leave a genuine pool-funded backlog");

        // `expectRevert` before `prank`, because the expected-error arguments contain a read.
        // A pending single-shot prank is spent on the next call this contract makes, and
        // `credit.unsocialisedLoss()` below is one - so under the other order the prank goes to
        // the read and the guarded call arrives from this contract, failing on ownership
        // instead of on the guard.
        //
        // **Both mechanisms are real, and the original comment was right.** This note briefly
        // said the staticcall in the arguments was the whole explanation and the cheatcode was
        // not. That was a re-diagnosis made without running anything, and running it refutes it:
        // `test_borrow_oneUnitBeyondMaxLtvReverts` fails with the guarded call arriving from this
        // contract even when every read is already hoisted into a local, and passes on nothing but
        // swapping `expectRevert` ahead of `prank`. So `vm.expectRevert` does consume a pending
        // prank, exactly as this file always said - and the staticcall is a *second*, newer way to
        // lose it that arrived with the risk parameters moving into storage. The ordering below
        // survives both, which is why it is the ordering to copy.
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LossOutstanding.selector, credit.unsocialisedLoss())
        );
        vm.prank(admin);
        credit.setLiquiditySource(address(liquidity));
    }

    /// @notice **Audit round 11: `setLenderPool` had `onlyOwner` and nothing else.** A backlog
    ///         banked against the outgoing pool must not become settleable against the incoming
    ///         one.
    /// @dev The same bearer instrument the round's PoC monetised, reached through the other
    ///      pointer. `_socialise` closed the route that moved the *source* out from under a
    ///      counter; this closes the route that moves the *sink* onto a fresh balance sheet. The
    ///      counter records an amount and not whose principal funded it, and
    ///      `flushSocialisedLoss` is permissionless, so whoever holds shares in the incoming pool
    ///      would be charged for a default they never funded, in a block an attacker picks.
    ///
    ///      Reuses `LossOutstanding` rather than inventing an error, because it is the identical
    ///      clause `setLiquiditySource` already carries and an operator reading the revert should
    ///      recognise it as the same problem with the same fix: call the flush first.
    ///
    ///      **Audit round 21 SUBSUMED this clause on this door, and the test says so rather than
    ///      being quietly repointed.** The counter can only fill against a pool that is also the
    ///      funder, and the sink may no longer be moved off a pool funder at all - so the refusal
    ///      an operator now meets here is `LossSinkMustBeTheFunder`, one line earlier and for a
    ///      broader reason. The round-11 property has not gone anywhere: it is asserted below at
    ///      `setLiquiditySource`, under the original error, which is the door the migration
    ///      actually goes through now. Both halves are in this one test on purpose, because
    ///      splitting them would leave a reader thinking the clause was deleted.
    function test_setLenderPool_refusedWhileTheOutgoingPoolsBacklogIsUnplaced() public {
        address a = _asAuction();
        MockLenderPool pool = _poolFundsTheBook();

        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        pool.setAccepting(false); // the default, stated so the test does not rest on it

        vm.prank(a);
        credit.writeDownLoss(alice, loan);
        assertGt(credit.unsocialisedLoss(), 0, "the fixture must leave a genuine pool-funded backlog");

        MockLenderPool incoming = new MockLenderPool(usdc);
        // `expectRevert` before `prank`, because the expected-error arguments contain a read.
        // A pending single-shot prank is spent on the next call this contract makes, and
        // `credit.unsocialisedLoss()` below is one - so under the other order the prank goes to
        // the read and the guarded call arrives from this contract, failing on ownership
        // instead of on the guard.
        //
        // **Both mechanisms are real, and the original comment was right.** This note briefly
        // said the staticcall in the arguments was the whole explanation and the cheatcode was
        // not. That was a re-diagnosis made without running anything, and running it refutes it:
        // `test_borrow_oneUnitBeyondMaxLtvReverts` fails with the guarded call arriving from this
        // contract even when every read is already hoisted into a local, and passes on nothing but
        // swapping `expectRevert` ahead of `prank`. So `vm.expectRevert` does consume a pending
        // prank, exactly as this file always said - and the staticcall is a *second*, newer way to
        // lose it that arrived with the risk parameters moving into storage. The ordering below
        // survives both, which is why it is the ordering to copy.
        uint256 backlog = credit.unsocialisedLoss();
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.LossSinkMustBeTheFunder.selector, address(pool), address(incoming)
            )
        );
        vm.prank(admin);
        credit.setLenderPool(address(incoming));

        // And the clause this test was written for, at the door the migration now uses.
        vm.expectRevert(abi.encodeWithSelector(CreditManager.LossOutstanding.selector, backlog));
        vm.prank(admin);
        credit.setLiquiditySource(address(incoming));
    }

    /// @notice The guard's second clause: the outgoing pool must not still have money out on loan.
    /// @dev `outstandingPrincipal` is written down by exactly two things, `repayPrincipal` and
    ///      `socialiseLoss`, and once this pointer moves away only the first can still reach it.
    ///      A default on a loan the outgoing pool funded would then be reported as
    ///      `LossBorneByTheSource` and its principal counter would never come down - so its
    ///      `totalAssets` would overstate the book permanently and its lenders would keep exiting
    ///      at a price that had stopped being true. That is round-10 finding 7's disease with no
    ///      auction to end it.
    ///
    ///      Asserted with `unsocialisedLoss` explicitly at zero, because a test that let both
    ///      clauses be armed at once would pass on whichever fired first and prove nothing about
    ///      this one.
    ///
    ///      **Driven with the treasury as the funder since audit round 21, and that is not a
    ///      fixture convenience.** The sink may no longer be moved off a pool funder at all, so on
    ///      the converged wiring `LossSinkMustBeTheFunder` fires one line earlier and this clause
    ///      is never reached. It still binds, and this is the configuration it binds in - the one
    ///      `DeployBase` ships. The principal is armed on the mock directly rather than through a
    ///      borrow, because a treasury-funded borrow puts the principal on the treasury.
    function test_setLenderPool_refusedWhileTheOutgoingPoolStillHasPrincipalOut() public {
        MockLenderPool pool = _poolIsTheSinkWhileTheTreasuryFunds();

        uint256 loan = _maxBorrow();
        pool.lend(loan);
        assertEq(pool.outstandingPrincipal(), loan, "the outgoing pool really is carrying principal");
        assertEq(credit.unsocialisedLoss(), 0, "the other clause must not be what bites here");
        assertTrue(credit.liquiditySource() != address(pool), "and the round-21 clause must not either");

        MockLenderPool incoming = new MockLenderPool(usdc);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.PoolPrincipalOutstanding.selector, address(pool), loan)
        );
        vm.prank(admin);
        credit.setLenderPool(address(incoming));
    }

    /// @notice **The composed proof that the new guard did not brick the migration it guards.**
    /// @dev Three tests that each pass in isolation say nothing about whether the states they
    ///      assert are mutually reachable, and this repository has shipped two guards whose only
    ///      escape hatch was gated on the thing they refused to release - `EpochHarvester`'s
    ///      `setLenderPool` spends twenty lines on one of them. The honest question here is that
    ///      the sole drain for `unsocialisedLoss` is `flushSocialisedLoss`, which itself refuses
    ///      unless the pool is still the liquidity source, so the drain does depend on the pointer
    ///      this guard refuses to move. That makes the guard necessary rather than circular: what
    ///      it forbids never unlocked anything, since `setLiquiditySource` carries the identical
    ///      clause and a lone sink repoint would leave the loss permanently unplaceable.
    ///
    ///      So this runs the whole thing in order, from a pool that refuses to take its own loss
    ///      through to a successor funding a fresh book and absorbing a fresh default. Every state
    ///      the two tests above assert appears here as a step that is then escaped.
    function test_setLenderPool_theWholePoolMigrationIsStillReachable() public {
        address a = _asAuction();
        MockLenderPool outgoing = _poolFundsTheBook();

        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        // A default the pool will not take yet: both clauses of the guard are now armed.
        vm.prank(a);
        credit.writeDownLoss(alice, loan);
        assertEq(credit.unsocialisedLoss(), loan, "remembered, not swallowed");
        assertEq(outgoing.outstandingPrincipal(), loan, "and still recorded as lent");

        // The drain the guard points an operator at, and the only one there is.
        outgoing.setAccepting(true);
        credit.flushSocialisedLoss();
        assertEq(credit.unsocialisedLoss(), 0, "the backlog placed where it was funded");
        assertEq(outgoing.outstandingPrincipal(), 0, "which is also what clears the second clause");

        // Both pointers now move, in the order the deployment script uses: funder first, sink
        // second, so the pool is never the loss sink for a book it does not fund.
        MockLenderPool incoming = new MockLenderPool(usdc);
        usdc.mint(address(incoming), FLOAT);
        vm.startPrank(admin);
        credit.setLiquiditySource(address(incoming));
        credit.setLenderPool(address(incoming));
        vm.stopPrank();
        assertEq(credit.liquiditySource(), address(incoming));
        assertEq(credit.lenderPool(), address(incoming));

        // And the successor is a working balance sheet, not just a stored address: it funds a
        // fresh loan and absorbs the default on it.
        incoming.setAccepting(true);
        vm.prank(alice);
        credit.borrow(loan);
        assertEq(incoming.outstandingPrincipal(), loan, "the incoming pool funds the book");

        vm.prank(a);
        credit.writeDownLoss(alice, loan);
        assertEq(incoming.socialisedTotal(), loan, "and takes the loss on what it funded");
        assertEq(outgoing.socialisedTotal(), loan, "while the outgoing one keeps only its own");
    }

    /// @notice The three socialisation states, composed. A refusing pool is not an edge
    ///         case: it is the only pool that exists before Phase 4, and asserting
    ///         "the flush reverts while the pool refuses" on its own would pass forever
    ///         while every liquidation was bricked.
    /// @dev The pool funds the loan here as well as sinking the loss. Before round 11 it only
    ///      sank the loss while the treasury float funded the book, and the deferral this test
    ///      asserts happened anyway - which was the bug, not the fixture. See
    ///      `_poolFundsTheBook`. Nothing else about the test moved: the states it composes, and
    ///      the amounts, are the ones it always asserted.
    function test_socialisedLoss_isRememberedWhileThePoolRefusesAndDeliveredOnceItCannot() public {
        address a = _asAuction();
        MockLenderPool pool = _poolFundsTheBook();

        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        // Insurance is empty, so the whole loss has to reach lenders - and cannot.
        vm.prank(a);
        credit.writeDownLoss(alice, loan);
        assertEq(credit.unsocialisedLoss(), loan, "remembered, not swallowed");
        assertEq(credit.debtOf(alice), 0, "and the liquidation still completed");

        // An explicit flush still fails loudly, and leaves the counter intact.
        vm.expectRevert(abi.encodeWithSelector(CreditManager.SocialisationRejected.selector, loan));
        credit.flushSocialisedLoss();
        assertEq(credit.unsocialisedLoss(), loan, "a failed flush must not lose the loss");

        // Phase 4 arrives: the same counter drains with no redeploy.
        pool.setAccepting(true);
        credit.flushSocialisedLoss();
        assertEq(credit.unsocialisedLoss(), 0);
        assertEq(pool.socialisedTotal(), loan);
    }

    /// @dev Round 10, finding 1 - the one the whole round turned on, and the reason this mock now
    ///      has a third state. A pool clamps a write-down to what it has actually lent, so it can
    ///      accept a call and absorb none of it. That is not an edge case: the deploy script wires
    ///      the pool as the loss sink while the treasury is still the liquidity source, so the
    ///      pool's `outstandingPrincipal` is zero and *every* loss absorbed nothing. `_socialise`
    ///      read "did not revert" as "fully placed" and the remainder existed on no ledger at all -
    ///      not in `unsocialisedLoss`, not in `lifetimeSocialisedLoss`, nowhere.
    ///
    ///      Before the pool had a body it reverted `NotImplemented`, which made the `catch` fire
    ///      and the loss visible. Building the pool is what broke the deferral, and no test could
    ///      see it because this mock only ever reverted or absorbed in full.
    ///
    ///      **Round 11 closed the deploy-script route described above, and partial absorption is
    ///      still reachable without it.** A pool that is not the liquidity source is no longer
    ///      offered the loss at all, so "outstandingPrincipal is zero because the treasury funds
    ///      the book" cannot happen any more. But the pool clamps to its own book-level
    ///      `outstandingPrincipal`, and the loss is sized from one borrower's debt, and those two
    ///      numbers are maintained independently: `repayPrincipal` clamps the counter at zero
    ///      rather than underflowing when yield carries a repayment past principal, and an
    ///      earlier socialisation has already written it down for money that is not coming back.
    ///      So the pool can still accept a call and absorb less than it was asked for, and the
    ///      caller must still not read "did not revert" as "fully placed".
    function test_socialisedLoss_partialAbsorptionIsDeferredNotDiscarded() public {
        address a = _asAuction();
        // The pool funds the book as well as sinking the loss - see `_poolFundsTheBook`.
        MockLenderPool pool = _poolFundsTheBook();
        pool.setAccepting(true);
        // Accepts the call, absorbs a quarter of it, and says so.
        uint256 loan = _maxBorrow();
        pool.setAbsorbCap(loan / 4);

        vm.prank(alice);
        credit.borrow(loan);

        vm.prank(a);
        credit.writeDownLoss(alice, loan);

        assertEq(pool.socialisedTotal(), loan / 4, "the pool took what it could");
        assertEq(credit.unsocialisedLoss(), loan - loan / 4, "the rest must be remembered, not erased");
        assertEq(credit.debtOf(alice), 0, "and the liquidation still completed");
    }

    /// @dev The same hole in the explicit path. `flushSocialisedLoss` zeroed the counter before the
    ///      call and only restored it in the `catch`, so a partial acceptance wiped the difference
    ///      on a call that reported success.
    ///
    ///      Since round 11 the flush also refuses outright unless the pool is the liquidity
    ///      source, so this fixture is the only one in which the function has any work to do -
    ///      see `_poolFundsTheBook`.
    function test_flushSocialisedLoss_keepsWhatThePoolWouldNotTake() public {
        address a = _asAuction();
        MockLenderPool pool = _poolFundsTheBook();

        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);
        vm.prank(a);
        credit.writeDownLoss(alice, loan);
        assertEq(credit.unsocialisedLoss(), loan);

        pool.setAccepting(true);
        pool.setAbsorbCap(loan / 2);
        credit.flushSocialisedLoss();

        assertEq(pool.socialisedTotal(), loan / 2);
        assertEq(credit.unsocialisedLoss(), loan - loan / 2, "the flush ate the remainder");
    }

    function test_flushSocialisedLoss_revertsWithNothingToDo() public {
        vm.expectRevert(CreditManager.NothingToSettle.selector);
        credit.flushSocialisedLoss();
    }

    /// @notice A second epoch must not compress the first epoch's unfinished tail.
    /// @dev The regression that the existing long-window test misses **by stopping one
    ///      epoch too early.** Rating a genesis pot over its true 60-day accrual window
    ///      is correct, and that test proves it - but the pot is still 55/60 undrained
    ///      five days later, and the next `distributeYield` used to re-rate the whole
    ///      thing over the 5-day gap. That handed months of other people's accrual to
    ///      whoever deposited at that moment, which is exactly what the streaming
    ///      design exists to prevent. The stream's end is now a floor, never pulled in.
    function test_stream_aSecondEpochDoesNotCompressTheFirstEpochsTail() public {
        // A genesis epoch representing 60 days of accrual.
        skip(60 days);
        _deliver(6_000e6);
        uint256 endAfterGenesis = credit.streamEndsAt();
        assertEq(endAfterGenesis, block.timestamp + 60 days, "rated over its real window");

        // Five days in, a just-in-time depositor arrives at nine times the honest base.
        skip(5 days);
        address jit = makeAddr("jit");
        _giveCollateral(jit, BONDS * 9);

        // ...and triggers a second, tiny epoch.
        _deliver(10e6);
        assertGe(credit.streamEndsAt(), endAfterGenesis, "the tail keeps its schedule");

        skip(Config.YIELD_STREAM_DURATION);
        credit.settle(jit);
        credit.settle(alice);

        // Five days of a sixty-day stream, at 90% of the bonds, is about 450 USDC.
        // Before the fix this was ~5,400: the whole remaining pot rated over five days.
        assertLt(credit.claimableOf(jit), 700e6, "five days of staking earns five days of yield");
    }

    // ── the two setter guards (audit round 16) ───────────────────────────────

    /// @notice **The mirror of `LenderPool.setCreditManager`'s own refusal, which had never been
    ///         built on this side.** A pool must not be repointed away from while it still carries
    ///         marks nothing will ever be able to clear.
    ///
    /// @dev Audit round 16, executed, owner-sequenced with no attacker. `LenderPool` refuses to
    ///      change its manager while `totalImpairment != 0` and spends eighteen lines explaining
    ///      why a stale per-borrower reserve is invisible at the swap. This function checked the
    ///      outgoing pool's principal and its own backlog and said nothing about the impairment, so
    ///      **the rule was enforced on one side of one pointer pair.**
    ///
    ///      Afterwards `_setImpairment` targets the *new* pool, so nothing can clear the old one's
    ///      map and the old pool can never be repointed either. It is recoverable, by pointing back
    ///      and refreshing, and that recovery appeared in no comment and no test while the one the
    ///      file did prescribe was wrong.
    ///
    ///      **`exitReserve()` cannot be the detector**, which is why this needed a new view rather
    ///      than a new clause: it clamps to `outstandingPrincipal`, and the clause immediately
    ///      above has just forced that to zero. The interface's only impairment-shaped number reads
    ///      zero in exactly the state that matters.
    ///
    ///      The other two clauses are asserted at zero, so this cannot pass on whichever fires
    ///      first - the same discipline the two tests above already use.
    ///
    ///      **Treasury-funded since audit round 21**, for the reason given on the principal clause
    ///      above: on the converged wiring the sink cannot be moved at all, so this clause is only
    ///      reachable from the configuration `DeployBase` ships.
    function test_setLenderPool_refusedWhileTheOutgoingPoolStillCarriesAMark() public {
        MockLenderPool pool = _poolIsTheSinkWhileTheTreasuryFunds();
        pool.setImpairment(alice, 1_000e6);

        assertEq(pool.outstandingPrincipal(), 0, "the principal clause must not be what bites here");
        assertEq(credit.unsocialisedLoss(), 0, "nor the backlog clause");
        assertTrue(credit.liquiditySource() != address(pool), "nor the round-21 one");
        assertEq(pool.exitReserve(), 0, "and the blinded detector must read zero, which is the finding");

        MockLenderPool incoming = new MockLenderPool(usdc);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.PoolImpairmentOutstanding.selector, address(pool), 1_000e6)
        );
        vm.prank(admin);
        credit.setLenderPool(address(incoming));
    }

    /// @notice And the guard does not brick the migration it guards: the mark is clearable without
    ///         moving the pointer.
    /// @dev The companion that stops this becoming the fourth mutually-unsatisfiable pair in this
    ///      file. Unlike `unsocialisedLoss`, whose only drain depends on the very pointer its guard
    ///      refuses to move, a mark's drains work on the *outgoing* pool right up to the
    ///      assignment. **Audit round 17 corrected the reason this used to give** - it said the
    ///      drains "touch neither pointer", and both `refreshImpairment` and `refreshImpairments`
    ///      read `lenderPool`. The conclusion is unchanged and the escape below still runs: the
    ///      guard forbids nothing that was previously reachable, because clearing the mark first is
    ///      a step the owner can always take.
    ///
    ///      **And it now calls the function its own docstring names.** Round 17 also caught this
    ///      body calling the single-borrower `refreshImpairment(alice)` while the text cited the
    ///      bounded `refreshImpairments(n)`. Both are drains, so it exercises each.
    ///
    ///      **Treasury-funded since audit round 21**, same reason: the escape this test proves is
    ///      an escape from the mark clause, and the mark clause is now only reachable from the
    ///      sink-only configuration. The escape out of the converged configuration is a different
    ///      one and lives in `test_setLenderPool_theWholePoolMigrationIsStillReachable`.
    function test_setLenderPool_theMarkIsClearableWithoutMovingThePointer() public {
        MockLenderPool pool = _poolIsTheSinkWhileTheTreasuryFunds();
        pool.setImpairment(alice, 1_000e6);
        pool.setImpairment(bob, 500e6);

        // No auction is wired, so the derived figure is zero and the refresh releases. Made by a
        // stranger, because that is the property: the remedy needs no privilege.
        vm.prank(makeAddr("anybody"));
        credit.refreshImpairment(alice);
        assertEq(pool.impairmentOf(alice), 0, "the single-borrower drain left the mark standing");

        vm.prank(makeAddr("anybody else"));
        assertEq(credit.refreshImpairments(8), 1, "the bounded drain reported the wrong count");
        assertEq(pool.totalImpairment(), 0, "the mark survived a refresh that could see it");

        MockLenderPool incoming = new MockLenderPool(usdc);
        vm.prank(admin);
        credit.setLenderPool(address(incoming));
        assertEq(credit.lenderPool(), address(incoming), "the migration is still reachable");
    }

    /// @notice **An auction that cannot answer the new selector is refused at wiring time, under
    ///         the owner's hand, rather than inside the repayment path.**
    ///
    /// @dev Audit round 16, six agents. `_impairmentFor` makes a bare, un-`try`ed
    ///      `recognisedRecoveryOf` call, and it is reached unguarded from `_repay` - the path this
    ///      codebase repeatedly promises is never blockable and deliberately not `whenNotPaused`.
    ///      The setter validated only `vault()`, so an auction answering that and not the new
    ///      member would brick **every repayment for every borrower under liquidation**.
    ///
    ///      `EpochHarvester.setCustodyAdapter` already implements exactly this pattern and states
    ///      the reason: fail at wiring time under the owner's hand, not inside a permissionless
    ///      call. The rule was written into one file and not applied when a new interface member
    ///      landed on the repayment path.
    ///
    ///      Probed at `address(0)`, which no auction can have a live recovery for, so the probe
    ///      reads a value it can ignore and is testing only that the call answers at all.
    function test_setLiquidationAuction_refusesAnAuctionThatCannotAnswerTheRecoveryProbe() public {
        HalfAnAuction incomplete = new HalfAnAuction(address(vault));

        // It answers the check the setter already made, which is the whole point: the old guard
        // passes it.
        assertEq(incomplete.vault(), address(vault), "fixture: this must clear the existing check");

        vm.expectRevert(CreditManager.LiquidationAuctionIncomplete.selector);
        vm.prank(admin);
        credit.setLiquidationAuction(address(incomplete));
    }

    /// @notice **The guard above covered one of the three selectors, and not the one called
    ///         first.** Audit round 17, seven agents, executed.
    ///
    /// @dev The auction here answers `vault()`, `recognisedRecoveryOf`, `liveAuctionCount` and
    ///      `openWorkoutCount` - everything the setter looked at - and does not answer
    ///      `workoutsOpenFor`, which `_impairmentFor` reaches **first and unconditionally for
    ///      every borrower**. `recognisedRecoveryOf` is only reached when `auctionOf` is non-zero,
    ///      which on a freshly wired auction is nobody, so the probe that existed tested the one
    ///      call that could not be made.
    ///
    ///      The state it let through is unrecoverable. `setLiquidationAuction` reads
    ///      `liveAuctionCount()` on the pointer it has just broken, and
    ///      `CollateralVault.setCreditManager` needs a zero total debt that repayment can no
    ///      longer reach. There is no way back, so this test is the whole of the defence.
    function test_setLiquidationAuction_refusesTheAuctionThatPassedTheOldProbe() public {
        TwoThirdsOfAnAuction incomplete = new TwoThirdsOfAnAuction(address(vault));

        // Every check the previous version of the guard made, passed.
        assertEq(incomplete.vault(), address(vault), "fixture: clears the vault-binding check");
        assertEq(incomplete.recognisedRecoveryOf(address(0)), 0, "fixture: clears the round-16 probe");

        vm.expectRevert(CreditManager.LiquidationAuctionIncomplete.selector);
        vm.prank(admin);
        credit.setLiquidationAuction(address(incomplete));
    }

    /// @notice And the middle selector is required on its own account too.
    /// @dev One test per member, deliberately, rather than one test over a mock missing all three.
    ///      A mock answering none of them trips whichever probe runs first and says nothing about
    ///      the other two - which is how the guard came to cover one of three in the first place.
    ///      If `_impairmentFor` gains a fourth external call it gains a fourth probe and a fourth
    ///      test here.
    function test_setLiquidationAuction_refusesAnAuctionThatCannotAnswerAuctionOf() public {
        NoAuctionOf incomplete = new NoAuctionOf(address(vault));

        assertEq(incomplete.workoutsOpenFor(address(0)), 0, "fixture: answers the first probe");
        assertEq(incomplete.recognisedRecoveryOf(address(0)), 0, "fixture: answers the third probe");

        vm.expectRevert(CreditManager.LiquidationAuctionIncomplete.selector);
        vm.prank(admin);
        credit.setLiquidationAuction(address(incomplete));
    }

    /// @notice The same rule, one pointer over: a pool that cannot be enumerated is refused.
    /// @dev Audit round 17. `refreshImpairments` calls `impairedBorrowerCount` and
    ///      `impairedBorrowerAt` bare, and both arrived in the round that built the walk - the same
    ///      commit range that applied this rule to the auction pointer next door.
    ///
    ///      Lower stakes than the auction probe, and the guard says so: both drains reach the pool
    ///      through `_setImpairment`, which `try`s each leg, so a pool that cannot answer strands
    ///      the bulk sweep rather than bricking repayment. Refused at wiring time anyway, because
    ///      the sweep is the only bounded way to clear a stale mark and a frozen queue is what a
    ///      stale mark costs.
    function test_setLenderPool_refusesAPoolThatCannotBeEnumerated() public {
        UncountablePool incomplete = new UncountablePool();

        vm.expectRevert(CreditManager.LenderPoolIncomplete.selector);
        vm.prank(admin);
        credit.setLenderPool(address(incomplete));
    }

    /// @notice **A bounded sweep reaches the oldest mark, which is the one that matters.**
    ///         Audit round 17, eight agents, executed.
    /// @dev The walk restarted at `count - 1` on every call, so any bound below the set size
    ///      re-visited the same tail forever. Marks append, so the oldest - the one the clock has
    ///      had longest to make stale, and therefore the one holding the queue shut - sits nearest
    ///      index 0 and was reached last or never.
    ///
    ///      **The fixture has to hold the set still, and getting that wrong makes this test
    ///      vacuous.** The first version let each visit release its mark, which shrinks the set, so
    ///      the tail moved down by one every call and even the cursorless walk reached index 0 in
    ///      three calls - it passed against the defect. The stale-mark state the finding is about
    ///      is one where the visited entry *stays*, which is the fixed point the old NatSpec's
    ///      "always make progress" missed. Refusing the write reproduces that with no auction
    ///      wiring: the set is constant at three, so a cursorless walk visits the tail three times.
    ///
    ///      Observed as the attempted call rather than as cleared state, for the same reason - the
    ///      write is refused, so the only evidence the oldest was reached is that it was asked.
    function test_refreshImpairments_boundedCallsReachTheOldestMark() public {
        MockLenderPool pool = _poolFundsTheBook();
        address oldest = makeAddr("oldest");
        pool.setImpairment(oldest, 1_000e6);
        pool.setImpairment(alice, 1_000e6);
        pool.setImpairment(bob, 1_000e6);
        assertEq(pool.impairedBorrowerAt(0), oldest, "fixture: the oldest mark must sit at index 0");

        // No auction is wired, so every derived figure is zero and every visit attempts a release.
        // Refusing them keeps the set at three entries for the whole test.
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(ILenderPool.releaseImpairment.selector), bytes(""));
        vm.expectCall(address(pool), abi.encodeCall(ILenderPool.releaseImpairment, (oldest)));

        for (uint256 i; i < 3; ++i) {
            vm.prank(makeAddr("sweeper"));
            credit.refreshImpairments(1);
        }

        assertEq(pool.impairedBorrowerCount(), 3, "fixture: the set must not have shrunk");
    }

    /// @notice The count it returns is writes that landed, not borrowers it looked at.
    /// @dev Audit round 17. `refreshed` incremented once per iteration while every write is
    ///      `try`-swallowed, so a pool refusing all of them reported a full sweep. The return value
    ///      is what an operator reads to decide whether to call again, so reporting a visit as a
    ///      refresh tells them to stop exactly when they should not.
    function test_refreshImpairments_reportsWritesThatLandedNotBorrowersVisited() public {
        MockLenderPool pool = _poolFundsTheBook();
        pool.setImpairment(alice, 1_000e6);
        pool.setImpairment(bob, 1_000e6);

        // Only the write refuses. The enumeration still answers, deliberately: a pool that cannot
        // even be counted reverts the sweep outright at the bare `impairedBorrowerCount` call, and
        // `setLenderPool` now refuses to wire one in the first place. The state worth testing is
        // the one `_setImpairment`'s `try`/`catch` exists for - the pool declining a write while
        // the manager carries on, which is exactly how a mark comes to be stale.
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(ILenderPool.releaseImpairment.selector), bytes(""));

        vm.prank(makeAddr("sweeper"));
        assertEq(credit.refreshImpairments(2), 0, "a sweep that wrote nothing reported refreshes");
        assertEq(pool.totalImpairment(), 2_000e6, "fixture: the writes really must have been refused");
    }

    /// @notice A refresh that lands on the value already stored is not a refresh, and must not be
    ///         counted as one.
    /// @dev **Audit round 19, and it is a defect in round 17's own fix** - the test directly above
    ///      pins that fix and passes throughout, which is why this needed its own name rather than
    ///      an extra assertion up there. PR #159 moved the count from iterations to calls that
    ///      landed; `impair` returns early and *silently* when `amount == previous`, so the `try`
    ///      succeeded, the call had "landed", and a no-op was counted.
    ///
    ///      Why it matters rather than being a cosmetic count: `refreshImpairments` is the operator
    ///      remedy the `QueueHeldByReserve` refusal points at. The measured trace was five
    ///      consecutive calls each returning 1, zero `Impaired` events, `exitReserve` unmoved, and
    ///      the withdrawal queue shut over idle cash the whole time. The number told whoever was
    ///      watching that the sweep was working on precisely the occasion it could not work - the
    ///      mark was correct rather than stale, so there was nothing for a refresh to recompute.
    function test_refreshImpairments_doesNotCountAMarkThatWasAlreadyRight() public {
        MockLenderPool pool = _poolFundsTheBook();
        _wireAuction();

        uint256 onePastTheLine = _debtAtThreshold() + 1;
        vm.prank(alice);
        credit.borrow(onePastTheLine);
        oracle.setNav(BOUNDARY_NAV);

        // Opening the liquidation writes the mark, and that write is a real one.
        credit.liquidate(alice);
        uint256 mark = pool.impairmentOf(alice);
        assertGt(mark, 0, "fixture: alice has to actually be marked, or every sweep below is trivial");

        // Nothing about the position changes from here, so `_impairmentFor` keeps deriving exactly
        // the figure already stored. Every one of these is a genuine no-op, and the count must say
        // so - this is the state `QueueHeldByReserve` sends an operator to `refreshImpairments` in.
        uint256 totalBefore = pool.totalImpairment();
        for (uint256 i; i < 5; ++i) {
            vm.prank(makeAddr("sweeper"));
            assertEq(credit.refreshImpairments(1), 0, "a sweep that changed nothing reported a refresh");
        }

        assertEq(pool.impairmentOf(alice), mark, "and the mark is exactly where it started");
        assertEq(pool.totalImpairment(), totalBefore, "as is the book-level total it feeds");
    }

    /// @notice An empty set still refreshes the two book-level terms of the reserve.
    /// @dev Audit round 17. `count == 0` returned before reaching `_pushLossReserves`, so the two
    ///      terms of `exitReserve` that are not per-borrower went unrefreshed in exactly the state
    ///      where nothing else was going to refresh them - no marks means no other call into this
    ///      function does any work either.
    function test_refreshImpairments_refreshesTheBookTermsOnAnEmptySet() public {
        MockLenderPool pool = _poolFundsTheBook();
        assertEq(pool.impairedBorrowerCount(), 0, "fixture: the set has to be empty");

        // Asserted as the call rather than as pool state, because `MockLenderPool.setLossReserves`
        // is a deliberate no-op - it exists so the manager's push has somewhere to land, not so a
        // test can read it back. What is being pinned is that the push happens at all.
        vm.expectCall(
            address(pool), abi.encodeCall(ILenderPool.setLossReserves, (credit.unsocialisedLoss(), credit.insuranceFund()))
        );

        vm.prank(makeAddr("sweeper"));
        assertEq(credit.refreshImpairments(5), 0, "an empty set cannot refresh a borrower");
    }

    /// @notice The walk survives the set shrinking underneath it, swap-pop and all.
    /// @dev **Untested everywhere in this repo until audit round 17**, because `MockLenderPool`
    ///      tracked additions and never removals, and the only real-pool exercise of the sweep runs
    ///      a one-element set where `_untrackImpaired`'s `index != last` branch is unreachable. So
    ///      the one interaction the downward walk exists to survive had no coverage at all.
    ///
    ///      Round 17 attacked the direction from six angles and it held; the mock is what could not
    ///      express the attack. Fixed there, pinned here.
    ///
    ///      **This one passes against the pre-cursor walk too, and that is the correct result.** It
    ///      is not a regression test for the cursor - it is the coverage the downward walk never
    ///      had. The direction was always right; what was missing was any test that could tell.
    function test_refreshImpairments_survivesASwapPopMidWalk() public {
        MockLenderPool pool = _poolFundsTheBook();
        address[3] memory marked = [makeAddr("first"), makeAddr("second"), makeAddr("third")];
        for (uint256 i; i < 3; ++i) {
            pool.setImpairment(marked[i], 1_000e6);
        }
        assertEq(pool.impairedBorrowerCount(), 3, "fixture: three marks to walk");

        // One call across the whole set. Each release swap-pops, so the array mutates under the
        // cursor on every iteration - which is the case the direction was chosen for.
        vm.prank(makeAddr("sweeper"));
        assertEq(credit.refreshImpairments(3), 3, "the walk skipped an entry the swap-pop moved");

        assertEq(pool.impairedBorrowerCount(), 0, "an entry outlived a walk that spanned the set");
        assertEq(pool.totalImpairment(), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(pool.impairmentOf(marked[i]), 0, "a mark survived the sweep");
        }
    }
}

/// @notice The auction shape audit round 17 executed: everything the old probe looked at, and
///         neither of the two selectors the repayment path always calls.
/// @dev `_impairmentFor` calls `workoutsOpenFor`, then `auctionOf`, then `recognisedRecoveryOf`.
///      This answers only the last, plus the two counters the setter reads off the *outgoing*
///      pointer - so it cleared every check the setter made and bricked repayment anyway.
contract TwoThirdsOfAnAuction {
    address public immutable vault;
    /// @dev **Audit round 20 added a fourth incoming check ahead of the three probes**, so a stub
    ///      that disagreed about the risk authority would be refused before the probe under test
    ///      could fire - and this file would then be asserting round 20's guard three times over
    ///      while round 17's went untested. Taken from the vault so it is right by construction.
    address public immutable riskParams;
    /// @dev **Audit round 21 added a fifth incoming check**, the sibling of the risk one above.
    ///      Agreed on purpose, for exactly the same reason: the probe under test has to be the one
    ///      that fires. Taken from the vault so it is right by construction.
    address public immutable navOracle;

    constructor(address vault_) {
        vault = vault_;
        riskParams = address(ICollateralVault(vault_).riskParams());
        navOracle = address(ICollateralVault(vault_).navOracle());
    }

    function recognisedRecoveryOf(address) external pure returns (uint256) {
        return 0;
    }

    function liveAuctionCount() external pure returns (uint256) {
        return 0;
    }

    function openWorkoutCount() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Answers the first and third probes and not the middle one.
contract NoAuctionOf {
    address public immutable vault;
    /// @dev See `TwoThirdsOfAnAuction`: agreed on purpose, so the probe under test is the one that
    ///      fires rather than round 20's risk check.
    address public immutable riskParams;
    /// @dev **Audit round 21 added a fifth incoming check**, the sibling of the risk one above.
    ///      Agreed on purpose, for exactly the same reason: the probe under test has to be the one
    ///      that fires. Taken from the vault so it is right by construction.
    address public immutable navOracle;

    constructor(address vault_) {
        vault = vault_;
        riskParams = address(ICollateralVault(vault_).riskParams());
        navOracle = address(ICollateralVault(vault_).navOracle());
    }

    function workoutsOpenFor(address) external pure returns (uint256) {
        return 0;
    }

    function recognisedRecoveryOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice A pool that answers every clause `setLenderPool` already had, and cannot be walked.
contract UncountablePool {
    function outstandingPrincipal() external pure returns (uint256) {
        return 0;
    }

    function totalImpairment() external pure returns (uint256) {
        return 0;
    }
}

/// @notice An auction that answers `vault()` and nothing else on the impairment surface.
/// @dev Deliberately not built on `MockLiquidationAuction`, which implements
///      `recognisedRecoveryOf` and so cannot express the state this is about. The finding is a
///      *partial* implementation passing a *partial* check.
contract HalfAnAuction {
    address public immutable vault;
    /// @dev See `TwoThirdsOfAnAuction`: agreed on purpose, so the probe under test is the one that
    ///      fires rather than round 20's risk check.
    address public immutable riskParams;
    /// @dev **Audit round 21 added a fifth incoming check**, the sibling of the risk one above.
    ///      Agreed on purpose, for exactly the same reason: the probe under test has to be the one
    ///      that fires. Taken from the vault so it is right by construction.
    address public immutable navOracle;

    constructor(address vault_) {
        vault = vault_;
        riskParams = address(ICollateralVault(vault_).riskParams());
        navOracle = address(ICollateralVault(vault_).navOracle());
    }
}
