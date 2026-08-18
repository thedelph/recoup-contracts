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
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Drives randomised borrow / repay / yield / withdraw sequences across a
///         small set of actors.
contract CreditHandler is Test {
    MockUSDC public usdc;
    MockNavOracle public oracle;
    CollateralVault public vault;
    CreditManager public credit;
    TreasuryLiquiditySource public liquidity;
    /// @notice The live risk configuration, so the borrow bound below is not a literal.
    /// @dev A handler cannot inherit `RiskParamsFixture` - it is not a test contract - so it holds
    ///      the authority directly and reads it per call. Bound to the interface rather than the
    ///      implementation for the same reason the fixture is: the authority can move without
    ///      touching this. Kept `public`, like every other field here; the getter it generates is
    ///      `view`, and the invariant runner only targets non-view functions.
    IRiskParams public riskParams;
    /// @notice The account that may move the risk parameters, so this handler can move them.
    address public riskParamsOwner;

    address public harvester;
    address[3] public actors;

    /// @notice Incremented whenever a borrow succeeds, so `watched` can tell a legitimate
    ///         increase from debt appearing out of nowhere.
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
    /// @notice Borrows that actually withheld a liquidation bounty. Read by the reachability
    ///         tripwire, because a dust threshold set wrong would make the two bounty
    ///         invariants above pass over a quantity that is always zero.
    uint256 public bountiesCharged;
    /// @notice Accepted risk-parameter writes that lowered a cap, and that raised one. Two
    ///         counters because they are different transitions: a tightening is the lever PR #189
    ///         introduced and the one that can leave the book above its own ceiling, and a
    ///         loosening only makes the ceiling slack.
    uint256 public capTightenings;
    uint256 public capLoosenings;

    /// @notice Observations recorded by `watched`. Both are asserted zero by an invariant.
    /// @dev **These used to be `lastAcc` / `lastTotalDebt` / `lastBorrowCount` fields on the
    ///      invariant contract, and in that shape they could not work.** forge discards the state a
    ///      non-view `invariant_` function writes: the journal from the invariant call is reverted
    ///      before the next handler call, so every one of those mirrors was restored to its `setUp`
    ///      value on every read. `invariant_accumulatorNeverDecreases` was therefore comparing the
    ///      accumulator against zero, and `invariant_debtOnlyRisesOnABorrow` only ever evaluated
    ///      its branch while `borrowCount` was still zero.
    ///
    ///      Measured on forge 1.7.1 with a purpose-built probe: an `invariant_` that increments a
    ///      counter and asserts it stays under three passes over 128,000 evaluations. Handler
    ///      storage is part of the fuzzed state and does persist, which is why the observation is
    ///      taken here, per action, and only read from the suite.
    uint256 public accumulatorRegressions;
    uint256 public debtRoseWithNoBorrow;

    constructor(
        MockUSDC usdc_,
        MockNavOracle oracle_,
        CollateralVault vault_,
        CreditManager credit_,
        TreasuryLiquiditySource liquidity_,
        IRiskParams riskParams_,
        address riskParamsOwner_,
        address harvester_,
        address[3] memory actors_
    ) {
        usdc = usdc_;
        oracle = oracle_;
        vault = vault_;
        credit = credit_;
        liquidity = liquidity_;
        riskParams = riskParams_;
        riskParamsOwner = riskParamsOwner_;
        harvester = harvester_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Wraps every action, and records the two properties that have to be observed *across* a
    ///      state change rather than at a single instant. A standing invariant cannot do this here,
    ///      because the only place to keep "what it was last time" is the invariant contract and
    ///      forge throws those writes away. See `accumulatorRegressions` above.
    ///
    ///      Counters rather than assertions, deliberately: a forge-std assertion inside a handler
    ///      reverts, and under `fail_on_revert = false` a reverting handler call is discarded - so
    ///      the failure would be invisible *and* would truncate the state space. Counting is free
    ///      of both, at the cost of the failure being reported one invariant call later.
    modifier watched() {
        uint256 accBefore = credit.accYieldPerBond();
        uint256 debtBefore = credit.totalDebt();
        uint256 borrowsBefore = borrowCount;
        _;
        if (credit.accYieldPerBond() < accBefore) ++accumulatorRegressions;
        if (borrowCount == borrowsBefore && credit.totalDebt() > debtBefore) ++debtRoseWithNoBorrow;
    }

    /// @dev The upper bound is the live per-account cap, not the 5,000e6 literal it used to be.
    ///      The two are the same number at the launch defaults, which is exactly why the literal
    ///      was dangerous: a ratchet step would leave the fuzzer unable to reach the cap it is
    ///      bounded by, and the per-account assertion below would go slack without anything going
    ///      red. That reasoning was written about a cap moving *up*, which is the harmless
    ///      direction; a cap moving *down* is the one that broke the two invariants this file used
    ///      to carry, and `moveCaps` now drives both. Read before the prank, deliberately - a
    ///      single-shot `vm.prank` is spent on the next call this contract makes, and the read is
    ///      one.
    ///
    /// @dev **The two cap assertions live here, at the borrow, and not in a standing invariant.**
    ///      `CreditManager.borrow` enforces both caps *at borrow time* and never afterwards. Since
    ///      PR #189 a downward cap move is legal and is the protocol's intended tightening lever
    ///      (the `THRESHOLD_BPS_MIN` docstring in `RiskParams.sol` names it as such, and names the borrow
    ///      side as where every tightening lever sits), so `totalDebt > globalBorrowCap()` is a
    ///      **correct** state: existing debt is not called in, new debt is refused. Two invariants
    ///      here used to assert that state impossible, and passed only because nothing in any
    ///      campaign with a live protocol ever moved a parameter. Measured before the fix: borrow
    ///      at the cap, tighten the global cap to 500e6, and both went red at
    ///      `5000000000 > 500000000` while `borrow(1)` correctly reverted. The protocol was right
    ///      and the assertions were wrong.
    ///
    ///      A guard that binds at an event has to be asserted at that event.
    ///      The pool's own invariant suite already does exactly this at the deposit, for the same
    ///      reason, and the shape is copied from there including the live read of the ceiling.
    ///      That suite is one of the files held back with the pool, so it is not in this
    ///      repository to compare against.
    function borrow(uint256 actorSeed, uint256 amount) external watched {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, riskParams.perAccountBorrowCap());
        uint256 escrowBefore = credit.bountyEscrowOf(a);
        vm.prank(a);
        try credit.borrow(amount) {
            borrowCount++;
            if (credit.bountyEscrowOf(a) > escrowBefore) ++bountiesCharged;
            assertLe(credit.totalDebt(), riskParams.globalBorrowCap(), "a borrow crossed the global cap");
            assertLe(credit.debtOf(a), riskParams.perAccountBorrowCap(), "a borrow crossed the per-account cap");
        } catch {}
    }

    /// @dev Moves the two borrow caps under a live book, which is the behaviour PR #189 introduced
    ///      and which nothing anywhere quantified over: `setRiskParams` was a handler action in no
    ///      campaign that had a protocol behind it. Only the caps move, so every relation
    ///      `checkRiskParams` enforces between the ceiling and the threshold is untouched and the
    ///      ratchet is not tested here - `RiskParams.invariants.t.sol` owns that.
    ///
    ///      The per-account draw is bounded by the global draw and by nothing else. It could be
    ///      bounded by this contract's own per-account ceiling instead, and deliberately is not:
    ///      that number is `RiskParams`' private business, and reproducing it here would couple two
    ///      files through a shared literal - the exact coincidence that made
    ///      `RiskParams.invariants.t.sol`'s ratchet assertion vacuous. Draws above it are refused
    ///      by the setter and caught, which is the correct division of labour and still leaves
    ///      roughly a third of draws accepted.
    function moveCaps(uint256 globalSeed, uint256 perAccountSeed) external watched {
        IRiskParams.Params memory next = riskParams.params();
        // Scalars, not a second `Params memory`. A memory struct assigned to another memory
        // variable is an alias rather than a copy, so `prev = next` followed by a write to `next`
        // silently moves both and every direction test below reads equal. Measured: the first
        // version of this action recorded zero tightenings while the trace showed the cap moving
        // from 25,000e6 to 500e6.
        uint256 prevGlobal = next.globalBorrowCap;
        uint256 prevPerAccount = next.perAccountBorrowCap;

        next.globalBorrowCap = uint64(bound(globalSeed, Config.MIN_BOUNTIED_DEBT, Config.GLOBAL_BORROW_CAP_MAX));
        next.perAccountBorrowCap =
            uint64(bound(perAccountSeed, Config.MIN_BOUNTIED_DEBT, uint256(next.globalBorrowCap)));

        vm.prank(riskParamsOwner);
        try riskParams.setRiskParams(next) {
            if (next.globalBorrowCap < prevGlobal || next.perAccountBorrowCap < prevPerAccount) ++capTightenings;
            if (next.globalBorrowCap > prevGlobal || next.perAccountBorrowCap > prevPerAccount) ++capLoosenings;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external watched {
        address a = _actor(actorSeed);
        // The largest debt a position can carry, so a repayment can always clear one outright.
        amount = bound(amount, 1, riskParams.perAccountBorrowCap());
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
    function distributeYield(uint256 amount) external watched {
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
    function passTime(uint256 seconds_) external watched {
        skip(bound(seconds_, 1 hours, Config.YIELD_STREAM_DURATION * 2));
        credit.accrueYield();
    }

    /// @dev Counts only settles that moved debt. A settle against an empty accumulator
    ///      is a no-op, and a suite in which every settle was one would have proved
    ///      nothing about the write-down path the whole protocol exists for.
    function settle(uint256 actorSeed) external watched {
        address a = _actor(actorSeed);
        uint256 before = credit.debtOf(a);
        credit.settle(a);
        if (credit.debtOf(a) < before) ++debtWriteDowns;
    }

    function claimSurplus(uint256 actorSeed) external watched {
        address a = _actor(actorSeed);
        vm.prank(a);
        try credit.claimSurplus() {
            ++surplusClaimsDone;
        } catch (bytes memory err) {
            assertEq(bytes4(err), CreditManager.NothingToClaim.selector, "unexpected claimSurplus revert");
        }
    }

    /// @dev **Round 21, finding 3: `settlePrincipal` no longer reverts at zero, so the counter has
    ///      to be earned rather than granted.** The old body counted a *call* and tolerated one
    ///      revert; a no-op at zero would now increment on every empty poke, and
    ///      `test_handlerCanReachEveryStateTheInvariantsCheck`'s
    ///      `principalSettlementsDone == 1` tripwire would pass without a settlement ever having
    ///      happened. Counting only a call that moved the counter keeps the quantity meaning what
    ///      the tripwire reads it as - and it is strictly stronger than the version it replaces,
    ///      which also counted a call that delivered nothing through the clamp branch.
    ///
    ///      No `try` any more, deliberately. With the zero case a no-op the only remaining reverts
    ///      are `LiquiditySourceUnset` and a source that refuses the pull, and this fixture has a
    ///      live source throughout - so a revert here is a real failure and should stop the
    ///      campaign rather than be swallowed by a `catch` that asserts an error which can no
    ///      longer be raised on this path.
    function settlePrincipal() external watched {
        uint256 owedBefore = credit.pendingPrincipal();
        credit.settlePrincipal();
        if (credit.pendingPrincipal() < owedBefore) ++principalSettlementsDone;
    }

    function withdraw(uint256 actorSeed, uint256 bonds) external watched {
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

    function moveNav(uint256 nav) external watched {
        oracle.setNav(bound(nav, 1e8, 100e8));
    }

}

/// @notice The Phase 2 invariants named in PRD §8, fuzzed.
contract CreditManagerInvariantsTest is StdInvariant, RiskParamsFixture {
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
    RiskParams internal riskParams;
    CreditHandler internal handler;

    address[3] internal actors;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function setUp() public {
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];

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
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
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
        // Audit round 20: the setters also check the risk authority agrees with the vault's.
        auctionStub.setRiskParams(address(riskParams));
        // Audit round 21: and the NAV feed, anchored on the vault's answer.
        auctionStub.setNavOracle(address(vault.navOracle()));
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

        handler = new CreditHandler(
            usdc, oracle, vault, credit, liquidity, IRiskParams(address(riskParams)), admin, harvester, actors
        );
        targetContract(address(handler));
    }

    /// @dev PRD §8: "Sum of user debts == CreditManager total debt."
    /// @notice No handler call may revert. Every action in this handler wraps its interesting call
    ///         in `try`, or guards it, so a handler *frame* that dies is a fixture fault rather
    ///         than a meaningless random sequence.
    /// @dev **Added to all five suites at once, because the bug that prompted it was found in one
    ///      and existed in three.** `LiquidationAuction.invariants.t.sol` opened auctions at a
    ///      healthy rate and rolled every one of them back, for three audit rounds, because a
    ///      statement after the `try` reverted and `fail_on_revert = false` discards a reverting
    ///      frame. Nothing inside a handler can detect that - the ghost that would record it dies
    ///      with the frame. Only the runner, counting frames from outside, can.
    ///
    ///      Deterministic: a property of the handler's code rather than of the random walk, so it
    ///      cannot flake the way a per-run reachability floor does.
    ///
    ///      Empty body on purpose. The assertion is the config line, enforced by the runner. The
    ///      global `fail_on_revert = false` in `foundry.toml` stays correct for every other
    ///      invariant here and is what lets the `try`/`catch` idiom work at all.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

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
    ///
    ///      **The observation moved into the handler and the reason is not style.** This used to
    ///      keep `lastTotalDebt` and `lastBorrowCount` here and compare against them. forge
    ///      discards the state an `invariant_` function writes, so both were restored to zero
    ///      before every read: the branch was only ever entered while no borrow had happened yet,
    ///      and it then asserted that debt was at most zero, which it was. The property in the
    ///      docstring was not being checked at all. `CreditHandler.watched` now takes the reading
    ///      either side of every action, where the state persists.
    function invariant_debtOnlyRisesOnABorrow() public view {
        assertEq(handler.debtRoseWithNoBorrow(), 0, "debt rose across an action with no borrow behind it");
    }

    /// @dev The prepaid liquidation bounty is real money held here, so the counter that
    ///      speaks for it in the solvency assertion has to agree with the map it claims to
    ///      total. Without this the counter is a ghost: `assertGe` below would keep passing
    ///      against a total that had drifted low, because a lower figure only makes the
    ///      solvency bound easier to clear.
    function invariant_bountyEscrowEqualsSumOfEscrows() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += credit.bountyEscrowOf(actors[i]);
        }
        assertEq(credit.totalBountyEscrowed(), sum);
    }

    /// **`invariant_bountyOwedEqualsSumOfOwed` used to sit here and it compared 0 to 0 on every
    /// run**, across 128,000 measured calls, because `liquidate` is not one of this handler's
    /// actions and cannot be: `MockLiquidationAuction` here is a bare stub wired only to satisfy
    /// the vault's pointer check, and the file already said so twenty lines further down. Its
    /// docstring claimed "the handler is the only caller of `liquidate` in this suite"; the
    /// handler never called it at all. Audit round eighteen found it - the tenth distinct way a
    /// test in this repo has gone vacuous, and the sibling of the one directly above, which does
    /// have a reachability tripwire and was neuter-verified.
    ///
    /// It now lives in `LiquidationAuction.invariants.t.sol`, which reaches `liquidate`,
    /// `cancel`, `expireToWorkout` and `claimBounty`, with a ghost per branch behind it. **The
    /// lesson is not "move the invariant" but "an invariant belongs in the suite that can reach
    /// its subject", and a tripwire on one transition says nothing about its sibling.**

    /// @dev Solvency. Every USDC this contract holds is spoken for exactly once:
    ///      surplus owed to borrowers, yield not yet allocated, principal owed back to
    ///      the funding source, the insurance fund, and the two liquidation-bounty pots.
    ///      Borrowed principal is never held here - it passes straight through, less the
    ///      bounty withheld from the disbursement, which is why the last two terms exist.
    function invariant_balanceCoversEveryClaimOnIt() public view {
        assertGe(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
                + credit.insuranceFund() + credit.totalBountyEscrowed() + credit.totalBountyParked()
                + credit.totalBountyOwed()
        );
    }

    /// PRD §8's "no path mints borrower USDC without proportional debt" used to be spelled here as
    /// `invariant_totalDebtNeverExceedsGlobalCap` and `invariant_noPositionExceedsPerAccountCap`,
    /// **and both named a property this protocol deliberately does not have.** They read the cap
    /// live out of `RiskParams` while `CreditManager.borrow` enforces it only at borrow time, so
    /// once PR #189 made a downward cap move legal - and it is the intended tightening lever, named
    /// as such by the `THRESHOLD_BPS_MIN` docstring in `RiskParams.sol` - `totalDebt > globalBorrowCap()` became a *correct*
    /// state that both of them asserted was impossible. Measured: borrow at the cap, tighten to
    /// 500e6, and both fail `5000000000 > 500000000`, while `borrow(1)` in that same state
    /// correctly reverts. The docstring that used to sit here argued for the live read on the
    /// grounds that a pinned snapshot would be too weak; the live read is what made the assertion
    /// false, and the choice was never between those two.
    ///
    /// They now sit in `CreditHandler.borrow`, asserted at the borrow, the way
    /// the pool's own suite asserts its deposit cap at the deposit. **A guard that binds at an
    /// event must be asserted at that event and never as a standing comparison against a mutable
    /// ceiling.**
    ///
    /// They passed for as long as they did only because `setRiskParams` was a handler action in no
    /// campaign that had a live protocol behind it - so nothing anywhere quantified over "the
    /// protocol behaves correctly when a risk parameter moves under it", which is the whole of what
    /// PR #189 introduced. `CreditHandler.moveCaps` is that action.

    /// @dev The accumulator only ever moves up. Every position's entitlement is the
    ///      difference between it and a recorded index, so a decrease would underflow
    ///      `_pending` and revert every settlement - including the ones inside
    ///      withdrawals, which would trap collateral.
    ///
    ///      Observed per action by `CreditHandler.watched`, not against a `lastAcc` field here.
    ///      That field was reset to zero before every read, because forge discards the state an
    ///      `invariant_` function writes, so this assertion was `acc >= 0` on every one of 128,000
    ///      calls.
    function invariant_accumulatorNeverDecreases() public view {
        assertEq(handler.accumulatorRegressions(), 0, "the yield accumulator moved backwards");
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
    ///      collateral, and `borrow` is bounded to the live per-account cap a call - $5,000 at
    ///      the launch defaults, and the binding constraint here, since the LTV ceiling would
    ///      allow far more against that much collateral.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        // **Round 21, finding 3, and this line is what stops the settlement tripwire below going
        // vacuous.** `settlePrincipal` returns early at zero now instead of reverting, so a handler
        // that counted calls rather than *movements* would score an empty poke - and the
        // `principalSettlementsDone() == 1` assertion further down would then prove only that
        // somebody called the function. Asserted here, at the one moment in this sequence when the
        // counter is genuinely empty.
        assertEq(credit.pendingPrincipal(), 0, "premise: nothing owed home yet");
        handler.settlePrincipal();
        assertEq(handler.principalSettlementsDone(), 0, "an empty settle is not a settlement");

        uint256 cap = perAccountBorrowCap();
        handler.borrow(0, cap);
        assertEq(handler.borrowCount(), 1, "borrowing must be possible");
        assertEq(credit.totalDebt(), cap, "the borrow must have landed");

        // The prepaid liquidation bounty has to be reachable here or both bounty invariants
        // are checking a quantity that is always zero, and would report green over a dust
        // threshold set above anything this fixture can borrow.
        assertEq(handler.bountiesCharged(), 1, "the bounty charge was never exercised");
        assertEq(credit.totalBountyEscrowed(), Config.LIQUIDATION_CALL_BOUNTY, "and it is held");
        assertEq(credit.debtOf(actors[0]), cap, "the bounty is withheld from cash, not added to debt");

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
        assertLt(credit.debtOf(actors[0]), cap, "settling must reduce what is owed");

        // Releasing 4,900 of 5,000 bonds would leave $2,515 of collateral against a
        // debt still in the thousands, so the withdrawal rule must refuse it.
        handler.withdraw(0, 4_900);
        assertEq(handler.withdrawsRefusedByLtv(), 1, "the LTV withdrawal guard was never exercised");
        assertEq(handler.withdrawsDone(), 0, "a withdrawal that breaches max LTV was allowed");

        // Repaid in full. `repay` caps at the debt, so overshooting is safe.
        handler.repay(0, cap);
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

        // ── the risk parameters moving under a live book ─────────────────────
        //
        // The behaviour PR #189 introduced, and until now the behaviour nothing quantified over.
        // Driven here rather than left to the fuzzer for the usual reason: a campaign that happens
        // to reach a state is not a proof that the state is reachable.
        handler.borrow(1, cap);
        uint256 debtHeld = credit.debtOf(actors[1]);
        assertGt(debtHeld, 0, "the second borrow must land");

        // Tighten both caps under that debt. This is legal, and it is the lever the protocol
        // documents as its tightening lever: existing debt is not called in, only new debt is
        // refused. It is also exactly the state the two deleted invariants asserted was impossible.
        handler.moveCaps(Config.MIN_BOUNTIED_DEBT, Config.MIN_BOUNTIED_DEBT);
        assertEq(handler.capTightenings(), 1, "the tightening lever was never exercised");
        assertEq(perAccountBorrowCap(), Config.MIN_BOUNTIED_DEBT, "the per-account cap did not move");
        assertEq(credit.debtOf(actors[1]), debtHeld, "a cap move called in existing debt");
        assertGt(credit.totalDebt(), globalBorrowCap(), "a book above its own live ceiling is the correct state");

        // And the guard that actually binds still binds, at the event it binds at.
        uint256 borrowsBefore = handler.borrowCount();
        handler.borrow(1, cap);
        assertEq(handler.borrowCount(), borrowsBefore, "a borrow above a tightened cap was allowed");

        handler.moveCaps(Config.GLOBAL_BORROW_CAP_MAX, Config.MIN_BOUNTIED_DEBT * 2);
        assertEq(handler.capLoosenings(), 1, "no cap was ever raised");

        // `accumulatorRegressions` and `debtRoseWithNoBorrow` are deliberately NOT asserted here.
        // They are violation counters rather than coverage ghosts, so asserting them zero in a
        // sequence that is meant to be clean is 0 == 0 and evidence of nothing. Their invariants
        // read them; what makes those invariants non-vacuous is that `watched` wraps every action
        // in this handler, which is a property of the code rather than of a run.
    }
}
