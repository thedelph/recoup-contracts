// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
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
import {RiskParams} from "../src/RiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @title Who can actually move the entry price, executed through the real call graph
/// @notice **This file exists because a report stated reachability as MEASURED when it had only
///         been read.** PR #262 closed round-23 finding 3 with the EIP-5143 entry bound, and its
///         evidence file `LenderPoolEntryPricing.t.sol` drives all three legs by pranking the
///         pool's own privileged counterparty: `epochHarvester` for `distributeYield`,
///         `creditManager` for `recoverLoss` and `repayPrincipal`. That is a sound measurement of
///         the POOL BOUNDARY and it says nothing about who can reach it. The accompanying claim
///         that all three legs are "permissionlessly reachable", and the 9,090 bps attached to the
///         recovery leg, were read off the upstream source rather than executed.
///
///         Everything below is driven from an address holding no role, through
///         `EpochHarvester.harvest()`, `EpochHarvester.flushLenderYield()`,
///         `CreditManager.settlePrincipal()` and `LiquidationAuction.workoutSettleAfterClose()`.
///         No protocol contract is pranked anywhere in this file.
///
/// @dev **Three results, and two of them correct that report.**
///
///      **A. The epoch leg is reachable, and the step is not attacker-sized.** A stranger with no
///      role and no capital calls `harvest()` and then `flushLenderYield()`, and the entry quote
///      moves. What arrives is `pendingLenderYield`, which is `Config.SPLIT_LENDER_BPS` of an epoch
///      the farm actually produced. The caller chooses the BLOCK. Nobody chooses the AMOUNT, and
///      the caller commits no money. Class (ii): permissionless in effect, through gates that check
///      no identity.
///
///      **B. The principal leg is reachable as a CALL and inert as a STEP, which corrects the
///      earlier report's 909 bps.** `CreditManager.settlePrincipal()` checks no identity and
///      anybody can pay for it, but it does not move the entry quote: `repayPrincipal` transfers
///      `amount` in and takes `amount` off `outstandingPrincipal`, and `totalAssets()` is the sum
///      of exactly those two, so an ordinary settlement is neutral to the wei. The quote moves only
///      through the `surplus` branch, which needs `pendingPrincipal > outstandingPrincipal`, and
///      **no state constructed here reaches it**. The protocol maintains
///      `outstandingPrincipal == pendingPrincipal + totalDebt` - the identity
///      `LiquidationAuction.invariants.t.sol` asserts - and the loss path preserves it: a write-down
///      takes `loss` off `totalDebt`, adds `fromInsurance` to `pendingPrincipal` and takes
///      `loss - fromInsurance` off `outstandingPrincipal`, which nets to zero. The one route that
///      used to break it - a recovery on a loss no pool bore, landing on `pendingPrincipal` and
///      paid to whatever `liquiditySource` pointed at by then - is what audit round 23 finding 5
///      closed by parking against the recorded funder. Executed below rather than argued.
///      **Downgraded: the leg is reachable, the step is not.**
///
///      **C. The recovery leg is the strong one, and its step is bounded by `w.writtenDown`, which
///      corrects the other half of that report.** `workoutSettleAfterClose(auctionId, amountUsdc)`
///      carries no identity check at all, and the caller supplies the money and names the amount,
///      so it is class (i): arbitrary EOA, own capital, own amount, own block. But
///      `take = min(amountUsdc, w.writtenDown)`, so the reachable step is bounded by the loss
///      actually written down on that workout and not by anything the caller picks. The earlier
///      9,090 bps came from `recoverLoss(10 * totalAssets())` sent by a pranked manager; it is a
///      pool-boundary figure and not a reachable one. Executed here at ten times the written-down
///      amount, with the caller funded for all of it.
///
///      **And what class (i) costs the attacker, since somebody has to pay for it.** The griefer's
///      USDC goes into the pool and raises the price for everyone, including the entrant they were
///      trying to disadvantage. Measured below as a net USDC position for a griefer who is also an
///      incumbent lender, which is the most favourable case for them.
///
///      **Neuter verification is reported in the PR body rather than here**, because five of the
///      nine tests below are neutered by changes to `src/` that this file cannot describe in a
///      sentence, and one of them is a whole-file revert.
contract EntryStepReachabilityTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp, the 2026-07-24 reading the other suites use
    uint256 internal constant BONDS = 100;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;
    uint256 internal constant GRIEFER_DEPOSIT = 5_000e6;
    uint256 internal constant ENTRY = 5_000e6;
    uint256 internal constant EPOCH_YIELD = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // borrower
    address internal lender = makeAddr("lender");
    address internal keeper = makeAddr("keeper");
    address internal feeWallet = makeAddr("feeWallet");

    /// @dev The whole point of the file. Neither holds a role on any contract here, and
    ///      `test_reach_theUnprivilegedCallersReallyHoldNoRole` executes that rather than taking
    ///      it from how the fixture was built.
    address internal stranger = makeAddr("stranger");
    address internal payer = makeAddr("payer");

    address internal griefer = makeAddr("griefer");
    address internal entrant = makeAddr("entrant");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    LenderPool internal pool;
    EpochHarvester internal harvester;
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

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        pool = new LenderPool(IERC20(address(usdc)), admin);
        // A real harvester CONTRACT, not an EOA standing in for one. Every other suite that touches
        // `distributeYield` uses an EOA, which is exactly why none of them can answer the question
        // this file is about.
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        // And the adapter sweeps farm yield to the harvester rather than to a sink address, which
        // is the Phase 3 wiring and the only one where `harvest()` finds anything.
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        // Both roles on the pool, which is the Phase 4 wiring and the only one where the pool has
        // exposure to lose and therefore a written-down loss for a recovery to land on.
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(address(harvester));
        // Out of the way, so the cap decides nothing below. It has its own tests.
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        harvester.setProtocolFeeWallet(feeWallet);
        harvester.setLenderPool(address(pool));
        adapter.setHarvester(address(harvester));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        _lend(lender, LENDER_DEPOSIT);

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();

        usdc.mint(entrant, 1_000_000e6);
        vm.prank(entrant);
        usdc.approve(address(pool), type(uint256).max);
    }

    // -- fixture helpers ------------------------------------------------------

    function _lend(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    function _debtParityNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS);
    }

    function _crashedNav() internal view returns (uint256) {
        return _debtParityNav() / 2;
    }

    /// @dev Borrow at the ceiling, crash NAV, liquidate. **Read before the prank, never from inside
    ///      an argument list.** The derivation is an external view now the risk parameters are
    ///      storage, and a `vm.prank` is spent by a staticcall in argument position.
    function _openAuctionAtCrashedNav() internal returns (uint256 id) {
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: the auction did not open");
    }

    /// @dev A forced close with the pool as both funder and sink, so the pool genuinely bears the
    ///      loss and there is a real bearer for a recovery to find.
    function _forceCloseOntoThePool() internal returns (uint256 id, uint256 writtenDown) {
        id = _openAuctionAtCrashedNav();
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        writtenDown = pool.lifetimeSocialisedLoss();
        assertGt(writtenDown, 0, "fixture: the pool did not bear the loss");
    }

    function _fundForAuction(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), type(uint256).max);
    }

    function _bpsDrop(uint256 before_, uint256 after_) internal pure returns (uint256) {
        return ((before_ - after_) * Config.BPS) / before_;
    }

    /// @dev The assertion this whole file exists to reach: after a step arrives, a caller holding
    ///      the pre-step quote is refused by the bounded door, and the same call without the bound
    ///      goes through at the worse price.
    function _assertTheBoundRefusesTheStep(uint256 quotedBefore) internal {
        uint256 nowQuote = pool.previewDeposit(ENTRY);
        assertLt(nowQuote, quotedBefore, "no step: the leg did not move the entry quote");

        vm.expectRevert(abi.encodeWithSelector(LenderPool.SharesBelowMinimum.selector, nowQuote, quotedBefore));
        vm.prank(entrant);
        pool.deposit(ENTRY, entrant, quotedBefore);
        assertEq(pool.balanceOf(entrant), 0, "the refused deposit minted shares");

        vm.prank(entrant);
        uint256 minted = pool.deposit(ENTRY, entrant);
        assertEq(minted, nowQuote, "the unbounded door minted something other than the re-quote");
    }

    // -- 0. the premise: the callers below really are unprivileged ------------

    /// @notice PREMISE, MEASURED. `stranger` and `payer` cannot reach any of the three pool-side
    ///         writers directly. Without this the rest of the file proves nothing: a fixture that
    ///         quietly granted a role would report reachability that does not exist.
    /// @dev Executed as reverts rather than asserted from the wiring, because the wiring is what
    ///      would be wrong. Reads first, then `expectRevert`, then `prank`, then the call.
    function test_reach_theUnprivilegedCallersReallyHoldNoRole() public {
        assertTrue(stranger != admin && payer != admin, "premise: the callers must not be the owner");
        assertEq(pool.epochHarvester(), address(harvester), "premise: the harvester role is the contract");
        assertEq(pool.creditManager(), address(credit), "premise: the manager role is the contract");

        vm.expectRevert(LenderPool.NotEpochHarvester.selector);
        vm.prank(stranger);
        pool.distributeYield(1e6);

        vm.expectRevert(LenderPool.NotCreditManager.selector);
        vm.prank(stranger);
        pool.recoverLoss(1e6);

        vm.expectRevert(LenderPool.NotCreditManager.selector);
        vm.prank(stranger);
        pool.repayPrincipal(1e6);

        vm.expectRevert(CreditManager.NotLiquidationAuction.selector);
        vm.prank(payer);
        credit.recoverWrittenDownLoss(alice, 1e6);
    }

    // -- A. the epoch leg ----------------------------------------------------

    /// @notice **LEG A, MEASURED: reachable, class (ii).** An address with no role calls
    ///         `harvest()` and then `flushLenderYield()` on the real harvester, and the entry quote
    ///         moves. The bound refuses the step and the unbounded door accepts it.
    function test_reach_A_anUnprivilegedEoaMovesTheEntryQuoteThroughTheHarvester() public {
        farm.setPendingYield(address(adapter), EPOCH_YIELD);

        vm.prank(stranger);
        harvester.harvest();
        uint256 owedToLenders = harvester.pendingLenderYield();
        assertGt(owedToLenders, 0, "premise: the harvest must leave a lender share to flush");

        uint256 quoted = pool.previewDeposit(ENTRY);

        vm.prank(stranger);
        harvester.flushLenderYield();

        assertEq(pool.pendingYield(), owedToLenders, "the flush did not reach the pool");
        emit log_named_uint("A: lender share flushed        ", owedToLenders);
        emit log_named_uint("A: quote before                ", quoted);
        emit log_named_uint("A: quote after                 ", pool.previewDeposit(ENTRY));
        emit log_named_uint("A: REACHABLE step, bps of quote", _bpsDrop(quoted, pool.previewDeposit(ENTRY)));

        _assertTheBoundRefusesTheStep(quoted);
    }

    /// @notice **LEG A, MEASURED: the caller picks the block and nothing else.** The amount is
    ///         `Config.SPLIT_LENDER_BPS` of an epoch the farm produced, and the caller commits no
    ///         capital on either call. That is what makes this class (ii) rather than class (i).
    function test_reach_A_theCallerChoosesTheBlockAndNeitherTheAmountNorPaysForIt() public {
        farm.setPendingYield(address(adapter), EPOCH_YIELD);
        uint256 strangerCashBefore = usdc.balanceOf(stranger);

        vm.prank(stranger);
        harvester.harvest();
        vm.prank(stranger);
        harvester.flushLenderYield();

        assertEq(usdc.balanceOf(stranger), strangerCashBefore, "the caller paid for the step after all");
        assertEq(strangerCashBefore, 0, "premise: the caller starts with no USDC at all");
        assertEq(
            pool.pendingYield(),
            (EPOCH_YIELD * Config.SPLIT_LENDER_BPS) / Config.BPS,
            "the step is not the lender split of the epoch"
        );
    }

    // -- B. the principal leg ------------------------------------------------

    /// @notice **LEG B, MEASURED: the call is reachable and the step is not.**
    ///         `CreditManager.settlePrincipal()` checks no identity, so a stranger can drive a full
    ///         repayment into `LenderPool.repayPrincipal`. The entry quote does not move by one
    ///         wei, because the cash in and the principal out are the same number and
    ///         `totalAssets()` is their sum.
    /// @dev This is the assertion that corrects the 909 bps the earlier report attributed to this
    ///      leg. That figure came from `repayPrincipal` called by a pranked manager with an amount
    ///      above `outstandingPrincipal`; the control at the foot of this file shows that branch is
    ///      live code, and this test shows the real call graph does not reach it.
    function test_reach_B_aStrangerCanSettlePrincipalAndTheEntryQuoteDoesNotMove() public {
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);

        usdc.mint(alice, debt);
        vm.startPrank(alice);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(debt);
        vm.stopPrank();

        uint256 pending = credit.pendingPrincipal();
        assertGt(pending, 0, "premise: there must be principal waiting to settle");
        uint256 outstanding = pool.outstandingPrincipal();
        uint256 quoted = pool.previewDeposit(ENTRY);

        vm.prank(stranger);
        credit.settlePrincipal();

        emit log_named_uint("B: pendingPrincipal settled  ", pending);
        emit log_named_uint("B: pool outstandingPrincipal ", outstanding);
        emit log_named_uint("B: quote before              ", quoted);
        emit log_named_uint("B: quote after               ", pool.previewDeposit(ENTRY));

        assertLe(pending, outstanding, "premise: a surplus would need the settlement to exceed the book");
        assertEq(pool.previewDeposit(ENTRY), quoted, "an ordinary settlement moved the entry quote");
        assertEq(pool.pendingYield(), 0, "an ordinary settlement started a yield stream");
        assertEq(pool.yieldRate(), 0, "an ordinary settlement rated a stream");
    }

    /// @notice **LEG B, MEASURED: the one route that used to reach the surplus branch is closed.**
    ///         A loss borne by a treasury that is never repaid, the legal Phase-4 switchover to the
    ///         pool, and then a permissionless recovery. Audit round 23 finding 5 parks that money
    ///         against the recorded funder instead of leaving it on the live-pointer counter, so a
    ///         stranger's `settlePrincipal` afterwards moves nothing and the entry quote is
    ///         untouched.
    /// @dev The negative is asserted three ways so it cannot pass for the wrong reason:
    ///      `pendingPrincipal` is zero, the money is on `owedToSource` for the treasury, and the
    ///      quote is byte-identical across the stranger's call.
    function test_reach_B_theSurplusRouteRound23ClosedStaysClosed() public {
        TreasuryLiquiditySource treasury = new TreasuryLiquiditySource(usdc, admin);
        usdc.mint(admin, LENDER_DEPOSIT);
        vm.startPrank(admin);
        treasury.setCreditManager(address(credit));
        usdc.approve(address(treasury), LENDER_DEPOSIT);
        treasury.fund(LENDER_DEPOSIT);
        credit.setLiquiditySource(address(treasury));
        vm.stopPrank();

        uint256 id = _openAuctionAtCrashedNav();
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
        assertGt(writtenDown, 0, "fixture: nothing was written down");
        assertEq(pool.lifetimeSocialisedLoss(), 0, "premise: the pool bore none of this");

        // The legal switchover: the funder pointer moves to the pool.
        vm.startPrank(admin);
        credit.settlePrincipal();
        credit.setLiquiditySource(address(pool));
        vm.stopPrank();

        uint256 quoted = pool.previewDeposit(ENTRY);
        _fundForAuction(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);

        assertEq(credit.pendingPrincipal(), 0, "the recovery landed on the live-pointer counter");
        assertEq(credit.owedToSource(address(treasury)), writtenDown, "it was not parked against the funder");

        vm.prank(stranger);
        credit.settlePrincipal();

        emit log_named_uint("B: written down under the treasury", writtenDown);
        emit log_named_uint("B: quote before the whole sequence", quoted);
        emit log_named_uint("B: quote after                    ", pool.previewDeposit(ENTRY));
        assertEq(pool.previewDeposit(ENTRY), quoted, "the closed route moved the entry quote after all");
        assertEq(pool.pendingYield(), 0, "the closed route rated a stream into the pool");
    }

    // -- C. the recovery leg -------------------------------------------------

    /// @notice **LEG C, MEASURED: reachable, class (i).** `workoutSettleAfterClose` carries no
    ///         identity check, the caller supplies the USDC and names the amount, and the entry
    ///         quote moves. The bound refuses it.
    function test_reach_C_anUnprivilegedEoaMovesTheEntryQuoteThroughTheAuction() public {
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();

        uint256 quoted = pool.previewDeposit(ENTRY);
        _fundForAuction(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);

        assertEq(pool.lifetimeLossRecovered(), writtenDown, "the recovery did not reach the pool");
        emit log_named_uint("C: written down                ", writtenDown);
        emit log_named_uint("C: quote before                ", quoted);
        emit log_named_uint("C: quote after                 ", pool.previewDeposit(ENTRY));
        emit log_named_uint("C: REACHABLE step, bps of quote", _bpsDrop(quoted, pool.previewDeposit(ENTRY)));

        _assertTheBoundRefusesTheStep(quoted);
    }

    /// @notice **LEG C, MEASURED: the reachable step is clamped to `w.writtenDown`.** This is the
    ///         falsifier for "unbounded by the pool's own size". A caller funded for ten times the
    ///         written-down loss, asking for all of it, moves exactly the written-down loss and
    ///         keeps the rest.
    /// @dev The clamp is `take = min(amountUsdc, w.writtenDown)` inside
    ///      `LiquidationAuction.workoutSettleAfterClose`. `LenderPool.recoverLoss` really does have
    ///      no `YieldExceedsCapital` guard, deliberately, and that remains true; it is simply not
    ///      what decides how large a step a stranger can put through this door.
    function test_reach_C_theReachableStepIsClampedToWhatWasActuallyWrittenDown() public {
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();

        uint256 greedy = 10 * writtenDown;
        _fundForAuction(payer, greedy);
        uint256 payerCashBefore = usdc.balanceOf(payer);
        uint256 quoted = pool.previewDeposit(ENTRY);

        vm.prank(payer);
        auction.workoutSettleAfterClose(id, greedy);

        uint256 spent = payerCashBefore - usdc.balanceOf(payer);
        emit log_named_uint("C: amount the caller asked for", greedy);
        emit log_named_uint("C: amount the clamp allowed   ", spent);
        emit log_named_uint("C: step at the clamp, bps     ", _bpsDrop(quoted, pool.previewDeposit(ENTRY)));
        assertEq(spent, writtenDown, "the clamp did not bind: a caller took more than was written down");
        assertEq(pool.lifetimeLossRecovered(), writtenDown, "the pool booked more than was written down");

        // And a second attempt on the same workout has nothing left to recover, so the step cannot
        // be repeated for a bigger total either.
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NothingLeftToRecover.selector, id));
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);
    }

    /// @notice **LEG C, MEASURED: what the class (i) step costs the party who places it.** The
    ///         griefer here is an incumbent lender, which is the most favourable case for them:
    ///         their own money comes partly back through their own shares. It still does not pay.
    /// @dev Two arms of one fixture. In both, an entrant deposits `ENTRY` and everybody exits once
    ///      the stream has run; the only difference is whether the griefer front-runs the entrant
    ///      with the recovery. Net USDC is measured for the griefer across the whole trace,
    ///      including the outlay.
    function test_reach_C_theGrieferPaysForTheStepAndDoesNotGetItBack() public {
        _lend(griefer, GRIEFER_DEPOSIT);
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();
        _fundForAuction(griefer, writtenDown);

        uint256 snap = vm.snapshotState();

        // ARM 1: the griefer does nothing. The entrant enters at the un-stepped price.
        uint256 cashBefore1 = usdc.balanceOf(griefer);
        vm.prank(entrant);
        pool.deposit(ENTRY, entrant);
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);
        // **Read the balance BEFORE the prank.** `balanceOf` in argument position is an external
        // staticcall and spends it, so the redeem would run as this contract and revert on the
        // allowance. That is the trap this whole file is about not falling into, in reverse.
        uint256 sharesIdle = pool.balanceOf(griefer);
        vm.prank(griefer);
        pool.redeem(sharesIdle, griefer, griefer);
        int256 grieferIdle = int256(usdc.balanceOf(griefer)) - int256(cashBefore1);

        vm.revertToState(snap);

        // ARM 2: the griefer pays the recovery in front of the entrant, then exits the same way.
        uint256 cashBefore2 = usdc.balanceOf(griefer);
        vm.prank(griefer);
        auction.workoutSettleAfterClose(id, writtenDown);
        vm.prank(entrant);
        pool.deposit(ENTRY, entrant);
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);
        uint256 sharesAttacking = pool.balanceOf(griefer);
        vm.prank(griefer);
        pool.redeem(sharesAttacking, griefer, griefer);
        int256 grieferAttacking = int256(usdc.balanceOf(griefer)) - int256(cashBefore2);

        emit log_named_uint("C: griefer stake                 ", GRIEFER_DEPOSIT);
        emit log_named_uint("C: outlay to place the step      ", writtenDown);
        emit log_named_int("C: griefer net, does nothing     ", grieferIdle);
        emit log_named_int("C: griefer net, places the step  ", grieferAttacking);
        emit log_named_int("C: cost of attacking             ", grieferIdle - grieferAttacking);

        assertLt(grieferAttacking, grieferIdle, "placing the step must not pay the party who places it");
    }

    // -- the control that keeps the pool-boundary claim honest ----------------

    /// @notice CONTROL. The surplus branch leg B cannot reach is live code, not dead code, and this
    ///         is the exact call `LenderPoolEntryPricing.t.sol` makes: the manager itself, with an
    ///         amount above `outstandingPrincipal`. It fires, and it steps the entry quote.
    /// @dev Kept so that "not reachable" is never read as "not there". The prank here is of
    ///      `address(credit)`, and it is the only prank of a protocol contract in this file - which
    ///      is the point being made, so it is labelled rather than hidden.
    function test_reach_control_theSurplusBranchIsLiveCodeAtThePoolBoundary() public {
        uint256 outstanding = pool.outstandingPrincipal();
        assertEq(outstanding, 0, "premise: nothing is out on loan in this fixture");

        uint256 surplus = 1_000e6;
        usdc.mint(address(credit), surplus);
        uint256 quoted = pool.previewDeposit(ENTRY);

        vm.startPrank(address(credit));
        usdc.approve(address(pool), surplus);
        pool.repayPrincipal(surplus);
        vm.stopPrank();

        emit log_named_uint("control: quote before          ", quoted);
        emit log_named_uint("control: quote after           ", pool.previewDeposit(ENTRY));
        emit log_named_uint("control: pool-boundary step bps", _bpsDrop(quoted, pool.previewDeposit(ENTRY)));
        assertEq(pool.pendingYield(), surplus, "the surplus branch did not rate the money as a stream");
        assertLt(pool.previewDeposit(ENTRY), quoted, "the surplus branch did not step the entry quote");
    }
}
