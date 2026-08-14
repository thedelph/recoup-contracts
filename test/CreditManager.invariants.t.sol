// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Drives randomised borrow / repay / yield / withdraw sequences across a
///         small set of actors.
contract CreditHandler is Test {
    MockUSDC public usdc;
    MockNavOracle public oracle;
    CollateralVault public vault;
    CreditManager public credit;
    TreasuryLiquiditySource public liquidity;

    address public harvester;
    address[3] public actors;

    /// @notice Incremented whenever a borrow succeeds, so the monotonicity invariant
    ///         can tell a legitimate increase from debt appearing out of nowhere.
    uint256 public borrowCount;

    /// @notice Coverage ghosts, which `borrowCount` above is not - it exists to serve
    ///         `invariant_debtOnlyRisesOnABorrow`, and happens to double as evidence a
    ///         borrow is reachable. Nothing counted the rest. The interesting actions
    ///         here are wrapped in `try`, which they have to be, so a fixture that could
    ///         never reach a surplus claim would report seven green invariants having
    ///         exercised nothing.
    ///         `test_handlerCanReachEveryStateTheInvariantsCheck` asserts these.
    uint256 public repaysDone;
    uint256 public yieldDistributions;
    uint256 public debtWriteDowns;
    uint256 public surplusClaimsDone;
    uint256 public principalSettlementsDone;
    uint256 public withdrawsDone;
    uint256 public withdrawsRefusedByLtv;

    constructor(
        MockUSDC usdc_,
        MockNavOracle oracle_,
        CollateralVault vault_,
        CreditManager credit_,
        TreasuryLiquiditySource liquidity_,
        address harvester_,
        address[3] memory actors_
    ) {
        usdc = usdc_;
        oracle = oracle_;
        vault = vault_;
        credit = credit_;
        liquidity = liquidity_;
        harvester = harvester_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 5_000e6);
        vm.prank(a);
        try credit.borrow(amount) {
            borrowCount++;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 5_000e6);
        uint256 debt = credit.debtOf(a);
        if (debt == 0) return;
        uint256 paid = amount > debt ? debt : amount;
        usdc.mint(a, paid);
        vm.startPrank(a);
        usdc.approve(address(credit), paid);
        // `_repay` settles before reading the debt, so a position whose streamed yield
        // has just cleared it reverts `NoDebt` between this handler's read and the call.
        // That is a real state, not a fixture fault, and it is the only one expected.
        try credit.repay(amount) {
            ++repaysDone;
        } catch (bytes memory err) {
            assertEq(bytes4(err), CreditManager.NoDebt.selector, "unexpected repay revert");
        }
        vm.stopPrank();
    }

    /// @dev Settles every actor afterwards so later actions start from a clean
    ///      position rather than a pile of unaccrued entitlement.
    function distributeYield(uint256 amount) external {
        amount = bound(amount, 1, 2_000e6);
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
        ++yieldDistributions;

        for (uint256 i; i < actors.length; ++i) {
            credit.settle(actors[i]);
        }
    }

    /// @dev Without this the fuzzer never moves the clock, and an epoch's share is
    ///      streamed over YIELD_STREAM_DURATION - so every distribution would accrue
    ///      exactly nothing and the whole yield path would go unexercised. The range
    ///      deliberately straddles the stream: shorter jumps land mid-stream, longer
    ///      ones run it past the end and re-rate a leftover pot.
    ///      Accrual alone moves no debt - it only advances the accumulator.
    function passTime(uint256 seconds_) external {
        skip(bound(seconds_, 1 hours, Config.YIELD_STREAM_DURATION * 2));
        credit.accrueYield();
    }

    /// @dev Counts only settles that moved debt. A settle against an empty accumulator
    ///      is a no-op, and a suite in which every settle was one would have proved
    ///      nothing about the write-down path the whole protocol exists for.
    function settle(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 before = credit.debtOf(a);
        credit.settle(a);
        if (credit.debtOf(a) < before) ++debtWriteDowns;
    }

    function claimSurplus(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try credit.claimSurplus() {
            ++surplusClaimsDone;
        } catch (bytes memory err) {
            assertEq(bytes4(err), CreditManager.NothingToClaim.selector, "unexpected claimSurplus revert");
        }
    }

    function settlePrincipal() external {
        try credit.settlePrincipal() {
            ++principalSettlementsDone;
        } catch (bytes memory err) {
            assertEq(bytes4(err), CreditManager.NothingToSettle.selector, "unexpected settlePrincipal revert");
        }
    }

    function withdraw(uint256 actorSeed, uint256 bonds) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        if (held == 0) return;
        bonds = bound(bonds, 1, held);
        vm.prank(a);
        try vault.withdrawBonds(bonds) {
            ++withdrawsDone;
        } catch (bytes memory err) {
            // The withdrawal rule is the only guard that should ever refuse here: the
            // amount is bounded to the balance and this fixture's NAV is never stale.
            assertEq(
                bytes4(err),
                CollateralVault.WithdrawalExceedsMaxLtv.selector,
                "unexpected withdrawBonds revert"
            );
            ++withdrawsRefusedByLtv;
        }
    }

    function moveNav(uint256 nav) external {
        oracle.setNav(bound(nav, 1e8, 100e8));
    }

}

/// @notice The Phase 2 invariants named in PRD §8, fuzzed.
contract CreditManagerInvariantsTest is StdInvariant, Test {
    uint256 internal constant NAV = 25.15e8;

    address internal admin = makeAddr("admin");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    TreasuryLiquiditySource internal liquidity;
    LenderPool internal pool;
    CreditHandler internal handler;

    address[3] internal actors;

    /// @notice Highest accumulator value seen so far, for the monotonicity check.
    uint256 internal lastAcc;
    /// @notice Previous observations, for the debt-monotonicity check.
    uint256 internal lastTotalDebt;
    uint256 internal lastBorrowCount;

    function setUp() public {
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];

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
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        // The vault refuses an auction pointer that is not a contract bound back to it,
        // so suites that never run a liquidation still need a stand-in.
        //
        // **All three lines are load-bearing, and for six days only the first two were
        // here.** Audit round 6 gave `borrow` a guard that reads the *vault's* auction
        // pointer and, when it is set, requires this manager to agree with it and the
        // auction to point back. Half-wired, that guard reverted every single borrow
        // with `AuctionPointerMismatch(0x0, vault)` - and because the handler wraps
        // `borrow` in `try`, the suite reported seven green invariants over a protocol
        // in which no debt had ever existed. The tripwire below found it on its first
        // run. Wire both directions, or wire neither.
        MockLiquidationAuction auctionStub = new MockLiquidationAuction();
        auctionStub.setVault(address(vault));
        auctionStub.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auctionStub));
        credit.setLiquidationAuction(address(auctionStub));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        liquidity.setCreditManager(address(credit));
        // **A real pool as the loss sink, and audit round 16 is why.** This suite never called
        // `setLenderPool`, so `_setImpairment` returned on its first line and every notification
        // this manager sends was a no-op the fuzzer could not tell from a working one. That matters
        // here specifically because `_repay` and `_settle` both end in that call: the refresh audit
        // round 13 put on the first, and the one audit round 16 added to the second, were
        // unreachable in the suite that fuzzes them.
        //
        // **Sink only, not also the liquidity source, and that is deliberate.** The treasury still
        // funds the book here, which is the state `DeployBase` actually ships, so
        // `outstandingPrincipal` stays zero and every reserve in the pool clamps to it. The
        // notifications land; the prices do not move. Marking the pool as a real funder as well
        // would make this a second copy of the auction suite's fixture rather than coverage of
        // this manager's own paths - and `LiquidationAuction.invariants.t.sol` is where the priced
        // lifecycle now lives.
        credit.setLenderPool(address(pool));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(harvester);
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(liquidity), 1_000_000e6);
        liquidity.fund(1_000_000e6);

        for (uint256 i; i < actors.length; ++i) {
            bond.mint(actors[i], 10_000);
            vm.startPrank(actors[i]);
            bond.setApprovalForAll(address(vault), true);
            vault.depositBonds(5_000);
            vm.stopPrank();
        }

        handler = new CreditHandler(usdc, oracle, vault, credit, liquidity, harvester, actors);
        targetContract(address(handler));
    }

    /// @dev PRD §8: "Sum of user debts == CreditManager total debt."
    function invariant_totalDebtEqualsSumOfDebts() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += credit.debtOf(actors[i]);
        }
        assertEq(credit.totalDebt(), sum);
    }

    /// @dev PRD §8: "Debt is monotonically non-increasing absent a borrow." This is
    ///      the property a self-repaying loan lives or dies on - nothing but an
    ///      explicit borrow may ever increase what someone owes.
    ///
    ///      It replaces an earlier handler-side tally of each actor's debt. That tally
    ///      could not survive lazy accrual: yield now streams continuously, so any
    ///      action that touches a position settles it and writes debt down, and a
    ///      mirror updated only on explicit settles drifts by design rather than by
    ///      bug. This checks the real property instead of a bookkeeping duplicate.
    function invariant_debtOnlyRisesOnABorrow() public {
        uint256 debtNow = credit.totalDebt();
        uint256 borrows = handler.borrowCount();
        if (borrows == lastBorrowCount) {
            assertLe(debtNow, lastTotalDebt, "debt rose with no borrow behind it");
        }
        lastTotalDebt = debtNow;
        lastBorrowCount = borrows;
    }

    /// @dev Solvency. Every USDC this contract holds is spoken for exactly once:
    ///      surplus owed to borrowers, yield not yet allocated, principal owed back to
    ///      the funding source, and the insurance fund. Borrowed principal is never
    ///      held here - it passes straight through.
    function invariant_balanceCoversEveryClaimOnIt() public view {
        assertGe(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
                + credit.insuranceFund()
        );
    }

    /// @dev PRD §8: "No path mints borrower USDC without proportional debt."
    function invariant_totalDebtNeverExceedsGlobalCap() public view {
        assertLe(credit.totalDebt(), Config.GLOBAL_BORROW_CAP);
    }

    function invariant_noPositionExceedsPerAccountCap() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(credit.debtOf(actors[i]), Config.PER_ACCOUNT_BORROW_CAP);
        }
    }

    /// @dev The accumulator only ever moves up. Every position's entitlement is the
    ///      difference between it and a recorded index, so a decrease would underflow
    ///      `_pending` and revert every settlement - including the ones inside
    ///      withdrawals, which would trap collateral.
    function invariant_accumulatorNeverDecreases() public {
        uint256 acc = credit.accYieldPerBond();
        assertGe(acc, lastAcc);
        lastAcc = acc;
    }

    /// @dev A stream can only ever pay out USDC that was actually delivered. If the
    ///      accumulator could outrun the pot, `settle` would credit debt write-downs
    ///      and claimable balances against money the contract does not hold - which is
    ///      the solvency invariant failing one step later, from a cause that is much
    ///      harder to read at that point.
    function invariant_streamNeverPromisesMoreThanWasDelivered() public view {
        assertLe(credit.undistributedYield(), usdc.balanceOf(address(credit)));
    }

    /// @notice Proves the fixture above is not vacuous.
    /// @dev The interesting handler actions are wrapped in `try`, which they have to be -
    ///      most random call sequences are meaningless and must not fail a run. The cost
    ///      is that a handler which never reached a surplus claim, or never let a settle
    ///      write debt down, would still report seven green invariants having exercised
    ///      nothing. Several of them are trivially satisfiable in that state:
    ///      `invariant_balanceCoversEveryClaimOnIt` compares four counters that are all
    ///      zero until yield flows, and `invariant_accumulatorNeverDecreases` holds
    ///      vacuously against an accumulator that never moved.
    ///
    ///      It is a normal test rather than `afterInvariant` on purpose: `afterInvariant`
    ///      fires once per run against counters that reset each run, so it would demand
    ///      that every one of these behaviours occur in *every* random 500-call
    ///      sequence, and fail on the first unlucky one.
    ///
    ///      No liquidation is asserted, and that is deliberate rather than an omission:
    ///      `MockLiquidationAuction` here is a bare stub wired only to satisfy the
    ///      vault's pointer check, so a liquidation is not reachable in this fixture at
    ///      all. `LiquidationAuction.invariants.t.sol` is where that lives.
    ///
    ///      **A real `LenderPool` is wired as the loss sink since audit round 16**, so the
    ///      `_setImpairment` call at the tail of `_repay` and `_settle` reaches a contract rather
    ///      than returning on its first line. It cannot be asserted non-zero here for the same
    ///      reason a liquidation cannot: with a stub auction `_impairmentFor` answers zero for
    ///      everyone, so what this buys is that the notification path executes, not that a mark
    ///      lands. The priced lifecycle is asserted in the auction suite, which is the one that can
    ///      reach it. Said out loud so a later reader does not add a non-zero assertion here and
    ///      find it unsatisfiable.
    ///
    ///      Each actor starts with 5,000 bonds staked at 25.15e8, so $125,750 of
    ///      collateral, and `borrow` is bounded to $5,000 a call.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        handler.borrow(0, 5_000e6);
        assertEq(handler.borrowCount(), 1, "borrowing must be possible");
        assertEq(credit.totalDebt(), 5_000e6, "the borrow must have landed");

        // An epoch arrives. Nothing is payable at the instant of distribution - the
        // borrower's share streams over YIELD_STREAM_DURATION, which is the whole
        // anti-just-in-time design - so the clock has to move before a settle can do
        // anything.
        handler.distributeYield(2_000e6);
        assertEq(handler.yieldDistributions(), 1, "yield distribution must be reachable");
        assertEq(handler.debtWriteDowns(), 0, "an epoch paid out at the instant it was distributed");

        handler.passTime(Config.YIELD_STREAM_DURATION);
        handler.settle(0);
        assertEq(handler.debtWriteDowns(), 1, "the debt write-down path was never exercised");
        assertLt(credit.debtOf(actors[0]), 5_000e6, "settling must reduce what is owed");

        // Releasing 4,900 of 5,000 bonds would leave $2,515 of collateral against a
        // debt still in the thousands, so the withdrawal rule must refuse it.
        handler.withdraw(0, 4_900);
        assertEq(handler.withdrawsRefusedByLtv(), 1, "the LTV withdrawal guard was never exercised");
        assertEq(handler.withdrawsDone(), 0, "a withdrawal that breaches max LTV was allowed");

        // Repaid in full. `repay` caps at the debt, so overshooting is safe.
        handler.repay(0, 5_000e6);
        assertEq(handler.repaysDone(), 1, "repayment must be possible");
        assertEq(credit.debtOf(actors[0]), 0, "the position must clear");

        // Principal owed back to the funding source, accumulated by the repayment and by
        // the yield that wrote the debt down before it.
        assertGt(credit.pendingPrincipal(), 0, "repaid principal must be recorded");
        handler.settlePrincipal();
        assertEq(handler.principalSettlementsDone(), 1, "principal settlement must be reachable");

        // A debt-free position keeps earning, and its share becomes claimable surplus
        // rather than a write-down. This is the other half of `_settle` and the only
        // thing that makes `totalClaimable` non-zero.
        handler.distributeYield(2_000e6);
        handler.passTime(Config.YIELD_STREAM_DURATION);
        handler.claimSurplus(0);
        assertEq(handler.surplusClaimsDone(), 1, "surplus must be claimable");

        // And with no debt left, collateral comes back out.
        handler.withdraw(0, 1_000);
        assertEq(handler.withdrawsDone(), 1, "a debt-free withdrawal must be possible");
    }
}
