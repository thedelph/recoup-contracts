// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {Config} from "../src/Config.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {LtvMath} from "../src/LtvMath.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Drives the whole liquidation lifecycle in random order against a NAV that
///         moves under it, and checks the properties that must survive any sequence.
///
///         The important one is `invariant_everyLiveAuctionHasAReachableExit`. Individual
///         guards are tested in the unit suite; what cannot be tested there is that
///         their preconditions leave no gap between them. A state in which all three
///         exits revert is permanently stranded collateral, and only a fuzzer looking
///         for it will find it.
///
///         **Audit round 47, and the two identities below have teeth as a number rather than as a
///         claim.** Round 46 finding 08 found this file checking `totalBountyEscrowed`,
///         `totalBountyParked` and `totalBountyOwed` against their maps and checking neither
///         `totalClaimable` nor `totalOwedToSources` against theirs, though both are terms of
///         `invariant_creditManagerBalanceCoversEveryClaimOnIt` and that assertion is one-sided.
///         Four neuters, each this file unchanged against one changed line in `CreditManager.sol`,
///         all run with `FOUNDRY_PROFILE=neuter forge test --force`, all UNSEEDED at the
///         `foundry.toml` defaults of 256 runs x 500 depth = **128,000 calls per invariant**:
///
///         | | the one changed line | result |
///         |---|---|---|
///         | baseline | nothing | **0 of 16 fail** |
///         | N1 | `creditLiquidationProceeds`: `totalClaimable += toBorrower` deleted | **1 of 16 fail**: `invariant_theClaimableCounterEqualsItsMap`, `524567819 != 693536199` |
///         | N2 | `_refundBounty`: `totalClaimable += held` deleted | **1 of 16 fail**: the same identity, `197383072 != 222383072` |
///         | N3 | the repoint park: `totalOwedToSources += stranded` deleted | **1 of 16 fail**: `invariant_theOwedToSourcesCounterEqualsItsMap`, `0 != 400000000` |
///         | N4 | `flushPrincipalTo`: `totalOwedToSources -= amount` deleted | **1 of 16 fail**: the same identity, `400000000 != 0` |
///
///         **Read the failures, not just the count.** N2's gap is exactly 25.000000, which is
///         `LIQUIDATION_CALL_BOUNTY`, and N3 and N4 are the same 400.000000 in opposite directions:
///         each neuter's arithmetic signature names the site it broke, which is the difference
///         between an identity that is red and an identity that is red *for the right reason*. And
///         in all four the rest of the suite stayed green - `invariant_creditManagerBalanceCovers
///         EveryClaimOnIt` included, because a counter that drifts LOW leaves a one-sided bound
///         satisfied. That is what these two identities are for.
///
///         **N3 and N4 are caught by the deterministic checkpoints, not by the campaign, and the
///         campaign invariant is 0 == 0.** The reason is on
///         `invariant_theOwedToSourcesCounterEqualsItsMap` itself: `setLiquiditySource` is
///         admin-only and audit round 23 measured that a repointing handler action would make
///         `invariant_theBooksAgreeOnWhatIsOwed` **false** rather than non-vacuous. It is stated
///         here rather than left for a reader to find in a passing run.
///
///         **Audit round 54 added a repointing action, and it is not the one round 23 refused.**
///         `AuctionHandler.migrate` moves the VAULT'S manager pointer to a second manager with its
///         own pool; round 23 measured moving one manager's SOURCE to a treasury. The first leaves
///         every (pool, manager) identity true and is asserted per pair below; the second still
///         breaks it and is still not an action. The campaign now reaches the three sites round
///         53's variant A changed (round-54 item 191), which no single-manager walk can.
///
///         **Gas, because a neuter that cannot move gas is a neuter that did not reach the run.**
///         Under the neuter profile the pass figures are `test_R23_...` 2,458,929 and
///         `test_handlerCanReachEveryStateTheInvariantsCheck` 7,926,897. N3 fails it at 1,775,751
///         and N4 at 2,160,022; N1 moves the tripwire to 7,934,037. **N2 moves neither, and that
///         is worth writing down rather than hiding**: `_refundBounty` is not on either
///         deterministic path, so N2 is caught by the campaign alone - and the discriminator that
///         it reached the run at all is that N1 and N2 print *different* figures for the same
///         assertion.
contract AuctionHandler is Test {
    CollateralVault public immutable vault;
    /// @notice The manager the vault currently points at.
    /// @dev **Storage, not `immutable`, since audit round 54 - and still not a setter.** Round-54
    ///      item 191 measured that this campaign reached NONE of the three sites round 53's variant
    ///      A changed, because nothing here could move the vault's manager pointer. `migrate` below
    ///      moves it, and this slot follows it, so every other action keeps reading "the live
    ///      manager" the way it always did. The addresses it can ever hold are `managers`, injected
    ///      by the constructor; no fuzzed address reaches this slot, which is the whole argument the
    ///      `pool` docstring below makes and it is unchanged.
    CreditManager public credit;
    LiquidationAuction public immutable auction;
    MockNavOracle public immutable oracle;
    MockUSDC public immutable usdc;
    MockBond public immutable bond;
    address public immutable keeper;
    /// @notice The epoch harvester, so this fixture actually has a yield source.
    /// @dev **Audit round 22, finding 14: it had none at all.** The address existed in the runner
    ///      as a `makeAddr` that nothing ever pranked, `receiveYield` and `distributeYield` were
    ///      never called from anywhere in this file, and `MockFarm.setPendingYield` was never
    ///      called either - so `accYieldPerBond` was zero for the whole campaign and every position
    ///      here, including the workout lots parked under the auction, earned exactly nothing. See
    ///      `deliverYield` below for what that cost.
    address public immutable harvester;

    /// @notice The live risk parameters, so this handler's own predicates follow a parameter change
    ///         instead of pinning the launch defaults.
    /// @dev Read once from the manager in the constructor and held `immutable`, for the same reason
    ///      `pool` below is: `targetContract(address(handler))` fuzzes every external non-view
    ///      function, so a setter here would be a fuzz target. It is the same `RiskParams` the
    ///      fixture deployed and passed into all three contracts, so reading it through `credit`
    ///      cannot disagree with the authority the code under test uses - and using the live value
    ///      is not the same as copying the implementation. `hasReachableExit` still restates each
    ///      exit's precondition itself; only the number it compares against is read rather than
    ///      frozen, which is the whole point of the parameters being settable.
    IRiskParams public immutable riskParams;

    address[] public actors;
    uint256[] public startedAuctions;
    /// @dev Membership test for `startedAuctions`, so a re-strike cannot enter it twice. See
    ///      `liquidate` below.
    mapping(uint256 => bool) public seenAuction;
    /// @notice How many times a lapsed auction was re-struck in place rather than opened fresh.
    /// @dev A coverage ghost for audit round 19's re-strike branch. It is read by the tripwire
    ///      below: a campaign that never re-strikes leaves `AUCTION_RESET_WINDOW`, the deadline and
    ///      the "the park never moves" property quantified over a branch it never enters, which is
    ///      the vacuity shape this file has produced twice already.
    uint256 public reStrikes;

    /// @notice Coverage ghosts. Every action here is wrapped in `try`, so a fixture
    ///         that silently never reaches a liquidation would report six green
    ///         invariants having proved nothing at all.
    ///         `test_handlerCanReachEveryStateTheInvariantsCheck` reads these - not
    ///         `afterInvariant`, for the reason given on that test.
    uint256 public bidsFilled;
    uint256 public cancelsDone;
    uint256 public workoutsOpened;
    uint256 public workoutsClosed;
    uint256 public recoveriesPaid;
    /// @notice Times a tranche landed on a workout the forced close had already written off.
    /// @dev Audit round 21, finding 14. Its own ghost rather than sharing `recoveriesPaid`,
    ///      because the two reach different states: one pays down a live debt, the other pays a
    ///      write-off back to the balance sheet that bore it, with no debt in front of it at all. A
    ///      campaign that only ever reached the first would say nothing about the second.
    uint256 public lateRecoveriesPaid;

    /// @notice Times a liquidation actually put a reserve into the lender pool, and times a
    ///         terminal transition actually took one out.
    /// @dev **The denominators that did not exist, and audit round 16 found why.** This suite ran
    ///      on a treasury float and never called `credit.setLenderPool`, so `_setImpairment`
    ///      returned on its first line: every impairment invariant here would have been vacuous had
    ///      any existed, and none did. Counted from the pool's own storage rather than from the
    ///      call, because "the manager was asked" and "the pool was marked" are different claims
    ///      and only the second one is the mechanism.
    uint256 public impairmentsOpenedByAnAuction;
    uint256 public impairmentsReleasedByAnAuction;

    /// @notice The three branches the prepaid bounty can take, counted separately.
    /// @dev **One ghost per branch, and audit round eighteen is why it is not one ghost for the
    ///      mechanism.** `invariant_bountyOwedEqualsSumOfOwed` used to live in
    ///      `CreditManager.invariants.t.sol`, where `liquidate` is not a handler action and the
    ///      auction is a bare stub - so it compared 0 to 0 on every run of 128,000 calls, the
    ///      tenth distinct way a test in this repo has gone vacuous. Its sibling on the *charge*
    ///      side did have a reachability tripwire and was neuter-verified. Nobody asked whether
    ///      the *release* was reachable in the suite that declared it, and a tripwire proves only
    ///      the transition it names.
    ///
    ///      Counted from the manager's own storage rather than from "the call did not revert",
    ///      for the same reason `_countRelease` is: a bounty that was meant to move and a bounty
    ///      that moved are different claims, and only the second is the mechanism.
    uint256 public bountiesParked;
    uint256 public bountiesReleased;
    uint256 public bountiesReturned;

    /// @notice Every manager this fixture can ever point the vault at, with the pool wired to
    ///         each. Index 0 is the pair the campaign starts on; the rest are virgin spares.
    /// @dev Injected, never created by an action and never named by a fuzz argument: `migrate`
    ///      picks from this list by a seed, so the closed address universe
    ///      `_everyAddressThisFixtureCanName` relies on stays closed - it enumerates these arrays.
    CreditManager[] internal managers;
    LenderPool[] internal pools;
    mapping(address => LenderPool) internal poolOf;
    /// @notice The owner of every wiring setter, so `migrate` can move the pointers.
    address public immutable admin;
    /// @notice The next spare `migrate` will move to, and the manager it last moved away from.
    uint256 public nextSpare;
    address public previousManager;

    constructor(
        CollateralVault vault_,
        CreditManager[] memory managers_,
        LiquidationAuction auction_,
        MockNavOracle oracle_,
        MockUSDC usdc_,
        MockBond bond_,
        LenderPool[] memory pools_,
        address keeper_,
        address harvester_,
        address admin_,
        address[] memory actors_
    ) {
        vault = vault_;
        credit = managers_[0];
        riskParams = managers_[0].riskParams();
        auction = auction_;
        oracle = oracle_;
        usdc = usdc_;
        bond = bond_;
        pool = pools_[0];
        keeper = keeper_;
        harvester = harvester_;
        admin = admin_;
        actors = actors_;
        for (uint256 i = 0; i < managers_.length; i++) {
            managers.push(managers_[i]);
            pools.push(pools_[i]);
            poolOf[address(managers_[i])] = pools_[i];
        }
        nextSpare = 1;
    }

    function managerCount() external view returns (uint256) {
        return managers.length;
    }

    function managerAt(uint256 i) external view returns (CreditManager) {
        return managers[i];
    }

    function poolAt(uint256 i) external view returns (LenderPool) {
        return pools[i];
    }

    /// @dev The pool is read, never driven. Its state is the evidence that an impairment landed;
    ///      this handler has no business calling it, because only the manager may.
    ///
    /// @dev **`immutable`, and injected rather than set, because a setter here is a fuzz target.**
    ///      This used to be a plain storage slot behind `function setPool(LenderPool) external`.
    ///      `targetContract(address(handler))` targets every external non-view function on the
    ///      handler, so the fuzzer called that setter with a fuzzed - and therefore codeless -
    ///      address about 45 times per 500-call run. From the first such call onward, the
    ///      `pool.impairmentOf(...)` read inside `liquidate`'s `try` **success block** reverted on
    ///      the extcodesize check, and a revert in the success block of a try/catch is not caught
    ///      by `catch` - it propagates and rolls back the whole handler call, **including the
    ///      auction that had just opened**.
    ///
    ///      Measured on the tree that had it: `liquidate` reported 444 calls and **31 reverts**
    ///      per run while every other action reverted zero times, and `startedCount()` was 0. Those
    ///      31 were not failures to liquidate. They were successful liquidations being destroyed
    ///      one line later, roughly 370 of them across twelve runs. The suite was not failing to
    ///      reach auctions; it was erasing the ones it reached.
    ///
    ///      `bid` and `cancel` read the same pointer and reported zero reverts, which looks like a
    ///      contradiction and is the same fact: both return early on an empty `startedAuctions`,
    ///      and it was empty precisely because every push had been rolled back.
    ///
    ///      The setter arrived in audit round sixteen, the change that wired the real pool in so
    ///      the impairment lifecycle would stop being unreachable. **The fix for one vacuity built
    ///      the next one**, and it hid for three rounds because a vacuous suite reports green.
    ///
    ///      **Round 54: storage again, and the argument above still holds.** `migrate` writes this
    ///      slot, from `poolOf[manager]` over the constructor-injected `pools` - never from a fuzz
    ///      argument. What the round-16 setter got wrong was not being writable; it was being
    ///      writable WITH AN ADDRESS THE FUZZER CHOSE. No action here takes an address.
    LenderPool internal pool;

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function startedCount() external view returns (uint256) {
        return startedAuctions.length;
    }

    // ── actions ──────────────────────────────────────────────────────────────

    /// @dev **The upper bound has to sit above `MIN_BOUNTIED_DEBT`, not on it.** It used to be
    ///      exactly 500e6, which is the dust threshold, so a single draw charged the prepaid
    ///      bounty only when `bound` returned its maximum exactly - about one seed in five
    ///      hundred million - and reaching the threshold in two draws needs both to land while
    ///      NAV is high. Measured across 24,000 calls, `bountiesParked` was zero. Above the
    ///      threshold, roughly a fifth of successful draws arm a position, and `MAX_LTV_BPS`
    ///      still refuses anything the collateral cannot carry, so nothing is being forced.
    function borrow(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try credit.borrow(bound(amount, 1, 620e6)) {} catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        vm.startPrank(a);
        usdc.approve(address(credit), type(uint256).max);
        try credit.repay(bound(amount, 1, 500e6)) {} catch {}
        vm.stopPrank();
    }

    /// @dev The whole point of the suite: NAV has to move, or nothing is ever
    ///      liquidatable and every auction action is a no-op that passes.
    function moveNav(uint256 navSeed) external {
        oracle.setNav(bound(navSeed, 1e8, 30e8));
    }

    /// @notice Moves NAV to a price derived from one actor's own debt, so the walk can land
    ///         either side of that position's liquidation threshold on purpose.
    /// @dev **Added beside `moveNav`, never instead of it.** The fuzzed state space stays a strict
    ///      superset of the one every invariant in this file was previously proved over - a suite
    ///      that only ever visits liquidatable states has stopped testing the healthy ones, which
    ///      would be the same mistake one level up.
    ///
    ///      The pivot is inverted straight out of `LtvMath.exceedsLtv`'s own cross-multiplication,
    ///      `debt * USDC_TO_NAV_SCALE * BPS > thresholdBps * bondCount * nav`, so it is the NAV at
    ///      which this position sits exactly on the threshold. The draw spans 80% to 120% of it,
    ///      which puts both sides of the guard in reach of one action - and that is what makes the
    ///      heal-then-`cancel` path reachable from the same walk that opened the auction, instead
    ///      of needing a second lucky uniform draw.
    ///
    ///      **Why it was needed, measured rather than assumed.** With the pool pointer fixed (see
    ///      `pool` above) the uniform draw alone opened a mean of 2.0 auctions per 500-call run
    ///      across 20 seeds, and **2 of those 20 runs opened none at all**. That is enough to stop
    ///      the file being vacuous and not enough to explore the auction lifecycle, which is what
    ///      the file is for: only half the runs filled a single bid.
    ///
    ///      **What the bias costs, stated rather than left to be discovered.** At equal depth the
    ///      fuzzer now spends more of its budget near thresholds and proportionally less on NAVs
    ///      far from any of them. That is accepted because the far states are the ones where every
    ///      auction action is a no-op and the invariants are trivially true, and because uniform
    ///      `moveNav` is still a separate selector - so the metrics table shows the split rather
    ///      than hiding it.
    function moveNavNearThreshold(uint256 actorSeed, uint256 offsetSeed) external {
        address a = _actor(actorSeed);
        uint256 debt = credit.currentDebtOf(a);
        uint256 bonds = vault.bondCount(a);
        if (debt == 0 || bonds == 0) return;

        uint256 pivot =
            (debt * Config.USDC_TO_NAV_SCALE * Config.BPS) / (riskParams.liquidationThresholdBps() * bonds);
        if (pivot == 0) return;

        oracle.setNav(bound(offsetSeed, (pivot * 4) / 5, (pivot * 6) / 5));
        navsDrawnNearThreshold++;
    }

    /// @notice Times the biased draw actually fired, so the bias is measurable rather than assumed.
    uint256 public navsDrawnNearThreshold;

    /// @notice Deliver an epoch of borrower yield, so the positions in this fixture actually earn.
    /// @dev **Audit round 22, finding 14. The fixture had no yield source at all, and that is why
    ///      three of this file's recovery paths had never moved a single wei.** `harvester` was a
    ///      `makeAddr` nothing pranked; `receiveYield` and `distributeYield` were never called;
    ///      `MockFarm.setPendingYield` was never called. So `accYieldPerBond` stayed at zero for
    ///      the whole campaign, `claimableOf[auction]` was zero at **every** observation point of
    ///      128,000 calls, and forge's own call summary reported `recoverStrandedClaim` at 7,199
    ///      calls / 0 reverts and `sweepWorkoutYield` at 7,138 calls / 0 reverts while neither
    ///      moved any USDC, ever. **That is round 21's distinction landing in this file for the
    ///      first time: `watched` proves the observation RUNS, it does not prove the quantity
    ///      MOVES.** Five negative tripwires written against those paths all passed, and every one
    ///      of them passed because the state was unreachable rather than because the property held.
    ///
    ///      **The two-way control, so this line is evidence and not an assertion.** Neuter
    ///      `sweepFreeBalanceToInsurance` so it emits its event and moves nothing: the shipped
    ///      suite passes 12 of 12 at 256 runs / 128,000 calls, *including*
    ///      `test_handlerCanReachEveryStateTheInvariantsCheck`. The same neuter with this action
    ///      present goes red at run 8 on `121639744 != 0` - 121.639744 USDC stranded on an
    ///      immutable contract. The blindness was confined to this layer:
    ///      `Impairment.integration.t.sol` caught that neuter with four failures.
    ///
    ///      **The invariant was not weakened to make room for the new state, and that is the
    ///      finding's other half.** `invariant_auctionHoldsNothingButUnclaimedRewards` was carried
    ///      into the widened space verbatim and holds, as do all eight of its siblings.
    ///
    ///      Driven through the manager rather than through `MockFarm.setPendingYield`, because the
    ///      farm leg only reaches `CollateralVault`'s custody adapter and it is the manager's
    ///      accumulator that pays a workout lot. `distributeYield` is attempted only inside the
    ///      success block of `receiveYield`, since it reverts `YieldNotDelivered` above whatever
    ///      actually arrived.
    function deliverYield(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e6, 500e6);
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        try credit.receiveYield(amount) {
            try credit.distributeYield(amount) {
                yieldEpochsDistributed++;
            } catch {}
        } catch {}
        usdc.approve(address(credit), 0);
        vm.stopPrank();
    }

    /// @notice Epochs that reached the accumulator, the denominator behind every counter below.
    uint256 public yieldEpochsDistributed;
    /// @notice USDC that `claimSurplusFor(auction)` actually pushed onto the auction, and the
    ///         number of times `sweepFreeBalanceToInsurance` actually took some of it off again.
    /// @dev **Measured as money moved, never as a call that did not revert.** Both legs were being
    ///      called thousands of times per campaign and moving nothing, which is precisely the shape
    ///      a call-count denominator cannot see.
    uint256 public usdcPushedToTheAuction;
    uint256 public freeBalanceSweepsThatMoved;
    /// @notice Times `sweepWorkoutYieldToInsurance` actually raised the insurance fund.
    uint256 public workoutYieldSweepsThatMoved;
    /// @notice Clean closes that actually booked a borrower some yield, and claims that actually
    ///         spent one down. Audit round 22, finding 18.
    /// @dev Both measured on `totalWorkoutYieldOwed` moving rather than on the call succeeding. A
    ///      clean close whose lot earned nothing books nothing and is indistinguishable from a
    ///      close that forgot to, which is the whole state
    ///      `invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists` quantifies over.
    uint256 public cleanClosesThatBookedYield;
    uint256 public workoutYieldClaimsThatPaid;

    function liquidate(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 parkedBefore = credit.totalBountyParked();
        vm.prank(keeper);
        try credit.liquidate(a) {
            uint256 id = auction.auctionOf(a);
            // **Recorded once per id, and audit round 19 is why this is not a bare `push`.** A
            // lapsed auction is now re-struck in place rather than settled and replaced, so
            // `liquidate` succeeding twice over one position returns the *same* id. Pushing it
            // again made `invariant_everyPrepaidBountyIsInExactlyOnePot` sum one park twice and
            // read `25000000 != 50000000` - a defect in the checker, not in the ledger it checks.
            // The set that invariant quantifies over is "auction ids that have existed", and a
            // re-strike does not create one.
            if (!seenAuction[id]) {
                seenAuction[id] = true;
                startedAuctions.push(id);
            } else {
                reStrikes++;
            }
            if (pool.impairmentOf(a) != 0) impairmentsOpenedByAnAuction++;
            if (credit.totalBountyParked() > parkedBefore) bountiesParked++;
        } catch {}
    }

    function passTime(uint256 secondsSeed) external {
        skip(bound(secondsSeed, 1 minutes, 3 days));
    }

    /**
     * ── THE EXHAUSTIVE DRAWS, AND WHY A BOUNDED CLOCK AND A BLIND MODULO ARE NOT ONE ───────────
     *
     * **Audit round 50, item 137**, and the same class of defect `CanonicalCashModel.t.sol`'s
     * `redeemAll`/`serviceAll`/`destroyAllCash` block records one campaign over: an action whose
     * draw cannot select the end of its own range leaves everything past that end unreachable by
     * construction rather than by luck. Here the range is a CLOCK and the draw is a MODULO, but
     * the shape is identical.
     *
     * Three things had to line up for a workout to be recognised and none of them could be drawn
     * for. `passTime` is `skip(bound(seed, 1 minutes, 3 days))`, so reaching
     * `Config.WORKOUT_MAX_DURATION` past `w.openedAt` needs FIVE consecutive maximal draws with no
     * intervening action resetting the picture; `expire` needs `Config.AUCTION_DURATION` past
     * `a.startedAt`; and `expire`, `closeWorkout`, `workoutSettle` and `workoutSettleAfterClose`
     * all pick an id by `startedAuctions[seed % length]` - a blind modulo over EVERY auction that
     * has ever started, most of which are settled - so the chance of naming the one live workout
     * falls as the walk gets longer.
     *
     * MEASURED at 9d1e72d, 64 forced single runs, unseeded, depth 500, `cache/invariant` cleared
     * between runs, `afterInvariant` logging every ghost (the census instrument is generated,
     * thrown away and never committed). **The item's own "zero of 64" is right about the terminal
     * half and WRONG about the entry, and both halves are recorded rather than the convenient
     * one**: `workoutsOpened` reached 21 of 64 and `workoutsClosed` 2 of 64, while
     * `forcedClosesThatWroteDown` and `lateRecoveriesPaid` were **0 of 64** and
     * `cleanClosesThatBookedYield`, `workoutYieldClaimsThatPaid` and `workoutYieldSweepsThatMoved`
     * were each **1 of 64**. So the campaign opens workouts and almost never RESOLVES one, which
     * is worse than not reaching them at all: every property about a recognised loss was being
     * quantified over a state space that had roughly one instance of it in 32,000 calls, and every
     * one of those properties reported green.
     *
     * The three actions below draw for the state instead of hoping for it. Each picks from a LIVE
     * set - `openWorkoutCount`/`openWorkoutAt` for workouts, a scan of `startedAuctions` for an
     * unsettled auction - and each moves the clock to the exact instant the guard it is about
     * names, rather than to a bounded increment of it. They are ADDITIONS: `passTime`, `expire`
     * and `closeWorkout` all stay, so the fuzzed state space is a strict superset of the one every
     * invariant here was previously proved over, which is the same discipline `moveNavNearThreshold`
     * records for itself.
     *
     * The after-census, same instrument, same 64 forced runs, is the table on
     * `test_handlerCanReachEveryStateTheInvariantsCheck` below.
     *
     * **And the census found a defect in these very actions before they shipped, which is the
     * reason to run one rather than to argue from the shape of the code.** `expireEligible`
     * indexed `startedAuctions[(idSeed + k) % n]`, and `idSeed` is a full `uint256` draw: two runs
     * of 64 reported `expireEligible` with ONE revert against every other selector's zero - an
     * arithmetic panic in the handler frame, outside every `try`, which is exactly what
     * `invariant_theHandlerNeverDropsAFrame` exists to catch. See the comment on the loop.
     */
    function passTimeToRecognitionDeadline(uint256 idSeed) external {
        uint256 n = auction.openWorkoutCount();
        if (n == 0) return;
        uint256 id = auction.openWorkoutAt(idSeed % n);
        (, uint96 openedAt,,,,,,,,,) = auction.workouts(id);
        uint256 deadline = uint256(openedAt) + Config.WORKOUT_MAX_DURATION;
        // Counted on the POST-STATE rather than on the warp, so an action that arrives at a
        // deadline already passed is the same evidence as one that moves the clock to it: the
        // ghost's claim is "a live workout stood at or past its recognition deadline", which is
        // the precondition `closeWorkout`'s forced branch actually evaluates.
        if (block.timestamp < deadline) vm.warp(deadline);
        warpsToRecognitionDeadline++;
    }

    /// @notice Expire a LIVE auction, moving the clock to its own deadline first.
    /// @dev The two guards `expire` cannot draw for, taken together. It scans from the seed rather
    ///      than indexing by it, because `startedAuctions` is dominated by settled ids the moment
    ///      anything resolves - which is exactly what made the blind modulo a worse draw the
    ///      longer the walk ran.
    function expireEligible(uint256 idSeed) external {
        uint256 n = startedAuctions.length;
        if (n == 0) return;
        // 🟥 **`(idSeed + k) % n` stood here and it OVERFLOWED.** `idSeed` is a full `uint256` fuzz
        // draw, so a seed near the type maximum plus a scan offset panics - an arithmetic revert in
        // the handler frame itself, outside every `try`, which is precisely what
        // `invariant_theHandlerNeverDropsAFrame` exists to see. MEASURED by this row's own
        // before/after census before the fix: `expireEligible` at 24 calls and **1 revert** in run
        // 23 of 64, and again in run 50, while every other selector reverted zero times. Reducing
        // the seed FIRST keeps both operands under `n`, so the sum is at most `2n - 2`.
        for (uint256 k = 0; k < n; k++) {
            uint256 id = startedAuctions[(idSeed % n + k) % n];
            (, uint96 startedAt,, bool settled,,,,) = auction.auctions(id);
            if (settled) continue;
            uint256 finishesAt = uint256(startedAt) + Config.AUCTION_DURATION;
            if (block.timestamp <= finishesAt) vm.warp(finishesAt + 1);
            uint256 owedBefore = credit.bountyOwedTo(keeper);
            // Still wrapped, and still counted from the outcome rather than the call: a healed
            // position reverts here on `_requireLiquidatable`, which is the dispatch
            // `expireToWorkout` documents, and that is a legitimate no-op rather than a fixture
            // fault.
            try auction.expireToWorkout(id) {
                workoutsOpened++;
                expiriesFromEligible++;
                if (credit.bountyOwedTo(keeper) > owedBefore) bountiesReleased++;
            } catch {}
            return;
        }
    }

    /// @notice `closeWorkout`, drawn from the workouts that are actually OPEN.
    /// @dev The same call as `closeWorkout` above, with the id chosen from
    ///      `_openWorkouts` instead of from every auction that has ever started. Deliberately does
    ///      NOT move the clock: the clean-close branch needs no deadline at all, and folding the
    ///      warp in here would make every close a forced one and delete the state
    ///      `cleanClosesThatBookedYield` exists to record. `passTimeToRecognitionDeadline` is the
    ///      clock, and the pair is what reaches the forced branch.
    function closeLiveWorkout(uint256 idSeed) external {
        uint256 n = auction.openWorkoutCount();
        if (n == 0) return;
        uint256 id = auction.openWorkoutAt(idSeed % n);
        uint256 bookedBefore = auction.totalWorkoutYieldOwed();
        bool splitPot = bookedBefore != auction.workoutYieldOwedOn(address(credit));
        try auction.closeWorkout(id) {
            workoutsClosed++;
            closesFromLiveDraw++;
            if (auction.totalWorkoutYieldOwed() > bookedBefore) {
                cleanClosesThatBookedYield++;
                if (splitPot) cleanClosesBookedOnASplitPot++;
                if (bookedBefore != 0) bookingsMadeBesideAnother++;
            }
            (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
            if (writtenDown != 0) forcedClosesThatWroteDown++;
        } catch {}
        _drainOnceTheQueueIsEmpty();
    }

    /// @notice The three exhaustive draws' own ghosts, so each is asserted reachable on its own
    ///         rather than inferred from the counter it was added to raise.
    /// @dev One per action, for the reason the bounty branches have one each: a tripwire proves
    ///      only the transition it names, and `workoutsClosed` moving says nothing about WHICH of
    ///      the two closes moved it.
    uint256 public warpsToRecognitionDeadline;
    uint256 public expiriesFromEligible;
    uint256 public closesFromLiveDraw;

    /// @notice Clean closes that booked while another booking already stood: the STATE variant A's
    ///         reserve term `totalWorkoutYieldOwed - owed` needs before it can be non-zero.
    /// @dev **Round 54, and the one variant-A site this campaign still cannot reach, stated as a
    ///      number rather than left in a passing run.** A booking stands only until a claim lands,
    ///      and `claimWorkoutYield` plus `claimBookedWorkout` are two of about thirty selectors,
    ///      while a second clean close needs a liquidation, an expiry, an epoch, a settle and a
    ///      close inside that window. MEASURED with a census ghost on this counter's condition:
    ///      ZERO at 256 runs x 500 calls, three unseeded campaigns; ZERO at 64 runs x 2,000 calls;
    ///      and ZERO with a further draw that settled and closed every open workout in one frame
    ///      (reached once in 256 runs, and the second lot had earned nothing to book) - that draw
    ///      is preserved with round 54's bundle and deliberately NOT shipped, because a selector
    ///      that dilutes every other by a thirtieth has to buy reach, and it measured none. The
    ///      reserve term is therefore asserted DETERMINISTICALLY, in
    ///      `test_handlerCanReachEveryStateTheInvariantsCheck`, on this very counter and on the
    ///      partial payment it binds; the campaign's green is not evidence about it.
    uint256 public bookingsMadeBesideAnother;

    function bid(uint256 idSeed, uint256 actorSeed) external {
        if (startedAuctions.length == 0) return;
        uint256 id = startedAuctions[idSeed % startedAuctions.length];
        (address borrower,,,,,,,) = auction.auctions(id);
        uint256 markedBefore = pool.impairmentOf(borrower);
        address buyer = _actor(actorSeed);
        // **Funded, and this line is the difference between a suite that fills auctions and one
        // that only tries.** The buyer used to be an actor holding nothing but what they had
        // borrowed, which is by construction less than their own collateral is worth, so every
        // fuzzed bid failed the transfer and was swallowed by the `try`. Measured while adding
        // the bounty invariant: `bidsFilled`, `cancelsDone` and both bounty release counters were
        // **zero across 256 runs and 128,000 calls**, so every invariant in this file that talks
        // about a resolved auction was holding over a state space with no resolutions in it. The
        // deterministic tripwire below reached them and reported the suite healthy, which is
        // exactly how a fixture-level vacuity survives a reachability check.
        usdc.mint(buyer, 100_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(auction), type(uint256).max);
        uint256 owedBefore = credit.bountyOwedTo(keeper);
        try auction.bid(id, type(uint256).max) {
            bidsFilled++;
            _countRelease(borrower, markedBefore);
            if (credit.bountyOwedTo(keeper) > owedBefore) bountiesReleased++;
        } catch {}
        vm.stopPrank();
    }

    function cancel(uint256 idSeed) external {
        if (startedAuctions.length == 0) return;
        uint256 id = startedAuctions[idSeed % startedAuctions.length];
        (address borrower,,,,,,,) = auction.auctions(id);
        uint256 markedBefore = pool.impairmentOf(borrower);
        uint256 escrowBefore = credit.bountyEscrowOf(borrower);
        try auction.cancel(id) {
            cancelsDone++;
            _countRelease(borrower, markedBefore);
            if (credit.bountyEscrowOf(borrower) > escrowBefore) bountiesReturned++;
        } catch {}
    }

    /// @dev Measured as a transition rather than as a call, so a release that was notified and
    ///      swallowed by the manager's `try`/`catch` cannot read as one that landed.
    function _countRelease(address borrower, uint256 markedBefore) private {
        if (markedBefore != 0 && pool.impairmentOf(borrower) == 0) impairmentsReleasedByAnAuction++;
    }

    function expire(uint256 idSeed) external {
        if (startedAuctions.length == 0) return;
        uint256 owedBefore = credit.bountyOwedTo(keeper);
        try auction.expireToWorkout(startedAuctions[idSeed % startedAuctions.length]) {
            workoutsOpened++;
            if (credit.bountyOwedTo(keeper) > owedBefore) bountiesReleased++;
        } catch {}
    }

    function workoutSettle(uint256 idSeed, uint256 amount) external {
        if (startedAuctions.length == 0) return;
        uint256 id = startedAuctions[idSeed % startedAuctions.length];
        uint256 pay = bound(amount, 1, 2_000e6);
        usdc.mint(address(this), pay);
        usdc.approve(address(auction), pay);
        try auction.workoutSettle(id, pay) {
            recoveriesPaid++;
        } catch {}
    }

    /// @dev The late tranche. Permissionless, so the handler - which holds no role - drives it,
    ///      the same way it drives `workoutSettle`.
    function workoutSettleAfterClose(uint256 idSeed, uint256 amount) external {
        if (startedAuctions.length == 0) return;
        uint256 id = startedAuctions[idSeed % startedAuctions.length];
        uint256 pay = bound(amount, 1, 2_000e6);
        usdc.mint(address(this), pay);
        usdc.approve(address(auction), pay);
        (,,,,,,,, address bearer,,) = auction.workouts(id);
        try auction.workoutSettleAfterClose(id, pay) {
            lateRecoveriesPaid++;
            // Round 54: the tranche is delivered to `w.bearer`, which after `migrate` can be a
            // manager the vault has left - round 46 finding 1's `wasLiquidationAuction` path.
            if (bearer != address(credit)) lateRecoveriesToADetachedBearer++;
        } catch {}
        usdc.approve(address(auction), 0);
    }

    /// @notice Late tranches that reached a manager the vault no longer points at.
    uint256 public lateRecoveriesToADetachedBearer;

    /// @dev **The `forcedClosesThatWroteDown` ghost is audit round 23, finding 11.** That finding
    ///      measured `workoutSettleAfterClose` at 6,467 calls / 0 reverts per campaign with its
    ///      body not executing, because nothing the walk reached had written a workout down - so
    ///      `Workout.bearer` and `Workout.writtenDown` were read by nothing the fuzzer did. The
    ///      call count could not have shown that: every action here is wrapped in `try`, so "did
    ///      not revert" and "did something" are different claims and only the second is the
    ///      mechanism. This counts the second, from the workout's own storage.
    ///
    ///      **"Rare on the seeds measured", not "unreachable", and the distinction is load-bearing
    ///      here.** No fuzz seed is pinned anywhere in this repository - `foundry.toml` sets
    ///      `runs`, `depth` and `fail_on_revert` and no seed, and CI runs a bare `forge test` - so
    ///      every "0 of N" in the round-23 record is a statement about the seeds that happened to
    ///      run. Round 23's own reachability agent corrected three of its censuses from "never" to
    ///      "rare" once it ran the full campaign, and a fourth was a cached counterexample replayed
    ///      at one call. This ghost exists so the question is answered by a number next time
    ///      instead of by a sentence.
    ///
    ///      Counted here rather than in `workoutSettleAfterClose` because this is where the
    ///      precondition is created; a ghost on the settle would only say the settle was tried.
    function closeWorkout(uint256 idSeed) external {
        if (startedAuctions.length == 0) return;
        uint256 id = startedAuctions[idSeed % startedAuctions.length];
        uint256 bookedBefore = auction.totalWorkoutYieldOwed();
        bool splitPot = bookedBefore != auction.workoutYieldOwedOn(address(credit));
        try auction.closeWorkout(id) {
            workoutsClosed++;
            if (auction.totalWorkoutYieldOwed() > bookedBefore) {
                cleanClosesThatBookedYield++;
                if (splitPot) cleanClosesBookedOnASplitPot++;
                if (bookedBefore != 0) bookingsMadeBesideAnother++;
            }
            (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
            if (writtenDown != 0) forcedClosesThatWroteDown++;
        } catch {}
        _drainOnceTheQueueIsEmpty();
    }

    /// @dev **Audit round 51, and the same bundling argument `recoverStrandedClaim` makes one
    ///      screen down.** Both sweeps now reserve what still-OPEN workouts have earned, so USDC
    ///      pushed onto the auction while a workout stood cannot be drained at the moment it
    ///      arrives - and `invariant_auctionHoldsNothingButUnclaimedRewards` was always maintained
    ///      by draining at push time rather than by arithmetic. The close is the transition that
    ///      empties the queue, so the close is the transition that has to offer the drain.
    ///
    ///      Nothing is hidden by the bundling: the free-balance sweep reserves rewards, bookings
    ///      and open accrual before it moves a cent, so the sum
    ///      `invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists` measures cannot fall
    ///      below what is booked, and that is the assertion that would notice.
    function _drainOnceTheQueueIsEmpty() private {
        if (auction.openWorkoutCount() != 0) return;
        try auction.sweepFreeBalanceToInsurance() {
            freeBalanceSweepsThatMoved++;
        } catch {}
    }

    /// @notice Forced closes that actually recognised a loss - the precondition
    ///         `workoutSettleAfterClose` needs before its body can do anything at all.
    uint256 public forcedClosesThatWroteDown;

    /// @dev The drain on `Workout.yieldOwed`, and the same argument `claimBounty` below makes for
    ///      itself: without a claim action the figure only ever grows, so an accounting error on
    ///      the way out is never reached - and this is the way out that audit round 22 finding 18
    ///      built. Driven by the handler, which holds no role, because the call is permissionless
    ///      and pays the borrower rather than the caller.
    ///
    ///      Counted as money that moved, never as a call that did not revert: `claimWorkoutYield`
    ///      pulls from the manager before it pays, so a version that pulled and paid nothing would
    ///      succeed and prove nothing.
    ///
    ///      **The sweep runs with it, for exactly the reason `recoverStrandedClaim` bundles its two
    ///      legs, and that reason is worth restating rather than cross-referencing.**
    ///      `claimWorkoutYield` pulls the auction's *whole* claim from the manager and pays out only
    ///      the one workout's figure, so it leaves behind everything the other lots have earned -
    ///      USDC that no `rewardOf` and no `yieldOwed` claims, which is precisely the excess
    ///      `invariant_auctionHoldsNothingButUnclaimedRewards` forbids. Measured, before this line
    ///      existed: `42519718 > 0` on that upper bound, on a shrunk sequence ending in this call.
    ///      The state is reachable and drainable rather than stranded, and the drain is the
    ///      permissionless sweep bundled here.
    ///
    ///      **And here the bundling costs nothing, which is not true of `recoverStrandedClaim`.**
    ///      What bundling could hide is this call over-pulling or over-paying, and
    ///      `invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists` is measured on
    ///      `balance + claimableOf + pendingYieldOf` - a sum the pull does not move and the payment
    ///      moves by exactly what it books down. So the assertion that would notice is blind to the
    ///      bundling by construction rather than by luck.
    function claimWorkoutYield(uint256 idSeed) external {
        if (startedAuctions.length == 0) return;
        _claimAndCount(startedAuctions[idSeed % startedAuctions.length]);
    }

    /// @notice `claimWorkoutYield`, drawn from the workouts that are actually CLOSED WITH A BOOKING.
    /// @dev The same call as `claimWorkoutYield` above with the id chosen by a scan for a booked
    ///      workout instead of a blind modulo over every auction that ever started, and an ADDITION
    ///      beside it, for the reason `closeLiveWorkout` gives beside `closeWorkout`. MEASURED by
    ///      round 54's first census, 256 runs and 128,000 calls with `migrate` present and this
    ///      action absent: the bearer branch, the split-differs close and the detached pull were all
    ///      reached, and a paid claim WHILE ANOTHER BOOKING STOOD - the reserve term variant A
    ///      added - was reached ZERO times, because the blind draw lands on a booked workout about
    ///      as rarely as two bookings coexist. Scans from the reduced seed, for the reason
    ///      `expireEligible` gives.
    function claimBookedWorkout(uint256 idSeed) external {
        uint256 n = startedAuctions.length;
        if (n == 0) return;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = startedAuctions[(idSeed % n + k) % n];
            (,, LiquidationAuction.WorkoutStatus status,,,,,,,, uint256 owed) = auction.workouts(id);
            if (status != LiquidationAuction.WorkoutStatus.Closed || owed == 0) continue;
            targetedClaims++;
            _claimAndCount(id);
            return;
        }
    }

    /// @dev The counted claim both claim actions share, so the ghosts below mean one thing.
    ///      **Round 54: the three sites variant A changed, each counted on a claim that PAID.**
    ///      `bearer` is read before the call so a claim on a workout closed under a manager the
    ///      vault has since left is seen as such; `owedBefore` is this workout's own entry, so
    ///      `bookedBefore - owedBefore` is exactly the reserve term `claimWorkoutYield` computes.
    function _claimAndCount(uint256 id) private {
        uint256 bookedBefore = auction.totalWorkoutYieldOwed();
        (,,,,,,,, address bearer,, uint256 owedBefore) = auction.workouts(id);
        uint256 bearerPotBefore = bearer == address(0) ? 0 : CreditManager(bearer).claimableOf(address(auction));
        try auction.claimWorkoutYield(id) {
            if (auction.totalWorkoutYieldOwed() < bookedBefore) {
                workoutYieldClaimsThatPaid++;
                if (bookedBefore - owedBefore != 0) {
                    claimsPaidWithForeignBookingsReserved++;
                    (,,,,,,,,,, uint256 owedAfter) = auction.workouts(id);
                    if (owedAfter != 0) partialClaimsBoundByForeignBookings++;
                }
                if (bearer != address(credit)) {
                    claimsPaidFromADetachedBearer++;
                    if (bearerPotBefore != 0 && CreditManager(bearer).claimableOf(address(auction)) == 0) {
                        bearerPullsThatRealised++;
                    }
                }
            }
        } catch {}
        try auction.sweepFreeBalanceToInsurance() {} catch {}
    }

    /// @notice Times the booked-workout draw found one to claim.
    uint256 public targetedClaims;

    /// @notice Variant A's reach, counted on money that moved. Round-54 item 191.
    /// @dev One ghost per site, for the reason the bounty branches have one each. A campaign that
    ///      pays claims and reaches none of these is exactly what round 53 measured, and the shipped
    ///      tripwire below now asserts each of them reachable rather than inferring it from
    ///      `workoutYieldClaimsThatPaid`.
    uint256 public claimsPaidWithForeignBookingsReserved;
    uint256 public partialClaimsBoundByForeignBookings;
    uint256 public claimsPaidFromADetachedBearer;
    uint256 public bearerPullsThatRealised;
    uint256 public cleanClosesBookedOnASplitPot;

    function sweepWorkoutYield() external {
        uint256 insuranceBefore = credit.insuranceFund();
        try auction.sweepWorkoutYieldToInsurance() {
            if (credit.insuranceFund() > insuranceBefore) workoutYieldSweepsThatMoved++;
        } catch {}
    }

    function claimReward() external {
        vm.prank(keeper);
        try auction.claimReward() {} catch {}
    }

    /// @dev The drain on `bountyOwedTo`, and the reason the invariant that sums it is not just
    ///      watching a number go up. Without a claim action the map only ever grows, so an
    ///      accounting error on the way out would never be reached.
    function claimBounty() external {
        vm.prank(keeper);
        try credit.claimBounty() {} catch {}
    }

    /// @dev Audit round 21, finding 4: the two legs that make a claim stranded on a manager the
    ///      auction no longer points at reachable again. Driven here by the handler itself, an
    ///      address with no role at all, because both are permissionless.
    ///
    ///      **They are one action deliberately, and the reason is worth stating rather than
    ///      hiding.** Between the legs the auction is holding USDC that no `rewardOf` claims,
    ///      which is exactly the excess `invariant_auctionHoldsNothingButUnclaimedRewards`
    ///      forbids - so splitting them would trip that invariant on a state the invariant was
    ///      never written about. That state is reachable by any external actor, here and before
    ///      this commit alike (a plain `usdc.transfer` to the auction does it); what changed is
    ///      that it is now drainable instead of permanent. The legs are exercised separately,
    ///      with the intermediate balance asserted, in `Impairment.integration.t.sol`.
    ///
    ///      **The price of bundling them, written down here rather than left to be rediscovered.**
    ///      Because both legs run inside one action, the intermediate state - the auction holding a
    ///      pushed claim that nothing has swept yet - never exists at an observation point. So a
    ///      neuter of `claimSurplusFor` **alone** stays invisible to this suite: with nothing
    ///      pushed there is nothing free, `sweepFreeBalanceToInsurance` reverts `NothingToClaim`,
    ///      the frame is discarded and every invariant here is still true. Only the second leg is
    ///      discriminated, and `usdcPushedToTheAuction` is the ghost that says whether the first
    ///      one ran at all. The reason for bundling is sound and the cost is real; both are stated
    ///      so a reader is not left believing the pair is covered when one half of it is.
    function recoverStrandedClaim() external {
        uint256 held = usdc.balanceOf(address(auction));
        try credit.claimSurplusFor(address(auction)) {
            uint256 pushed = usdc.balanceOf(address(auction));
            if (pushed > held) usdcPushedToTheAuction += pushed - held;
        } catch {}
        uint256 betweenTheLegs = usdc.balanceOf(address(auction));
        try auction.sweepFreeBalanceToInsurance() {
            if (usdc.balanceOf(address(auction)) < betweenTheLegs) freeBalanceSweepsThatMoved++;
        } catch {}
    }

    /// @dev The third-party collectors for the other two pots. Same reason `claimBounty` above is
    ///      here: without a drain the maps only ever grow and an error on the way out is never
    ///      reached - and these are the drains a claimant who cannot call for themselves needs.
    function claimRewardForKeeper() external {
        try auction.claimRewardFor(keeper) {} catch {}
    }

    function claimBountyForKeeper() external {
        try credit.claimBountyFor(keeper) {} catch {}
    }

    /**
     * ── THE REPOINT, AND WHY THIS FILE COULD NOT SPEAK TO VARIANT A WITHOUT IT ─────────────────
     *
     * **Round-54 item 191.** Round 53 shipped variant A - `workoutYieldOwedOn[manager]`, the
     * per-bearer clamp in `closeWorkout`, the aggregate reserve and the bearer pull in
     * `claimWorkoutYield` - and this campaign ran green at 256 runs and 128,000 calls under it.
     * Four census ghosts then measured that the walk reached NONE of the three sites the variant
     * changes, because no action here could move the vault's manager pointer, so `w.bearer` equalled
     * `creditManager` on every close and `if (bearer != cm)` was dead. A green over a state space
     * that cannot contain the change is a no-regression statement, not evidence about the fix.
     *
     * **This action moves the pointer the way the owner does, drawing for the preconditions the
     * way `expireEligible` draws for its own.** `CollateralVault.setCreditManager` refuses while the
     * outgoing manager records debt, while any auction is live or any workout is open, and unless
     * the incoming manager is VIRGIN (`accYieldPerBond == 0` - the vault's one-way-detachment
     * rule). So: no live work, or return; then a rescuer clears the live book through the
     * permissionless `repayFor` (the same third-party cure `expireToWorkout`'s docstring names);
     * then the owner moves the vault and the auction, in that order, because the auction's setter
     * insists the incoming manager already be the vault's. A migration BACK to the previous manager
     * is attempted on an odd seed and is REFUSED by the vault whenever that manager ever
     * distributed yield; the refusal is counted rather than pre-filtered, so the census says how
     * often the one-way rule bites instead of the handler deciding it in advance.
     *
     * **What the walk gains, stated so the cost column is visible.** Every clean close after a
     * migration books against a pot the split now labels; every `claimWorkoutYield` on a booking
     * whose bearer the vault has left takes the pull branch; `workoutSettleAfterClose` can deliver
     * a tranche to a detached bearer; and `pullDetachedBearer` is the stranger's
     * `claimSurplusFor(auction)` on a manager nobody points at - the one permissionless unwind of
     * round-54 item 194's over-reserve. Three new selectors dilute every other by about a ninth,
     * and a migration resets every actor to zero debt on a manager that has never seen them.
     *
     * **The identity this file said a repointing action would make FALSE is a different lever.**
     * Audit round 23 measured `setLiquiditySource` - moving one manager's SOURCE to a treasury -
     * and that does break `invariant_theBooksAgreeOnWhatIsOwed`, which is why
     * `test_R23_theParkedTermOfThisIdentityIsReachableAndTheHandlerCannotReachIt` still asserts
     * it. Moving the VAULT to a second manager with its own pool does not: the identity holds per
     * (pool, manager) pair and is restated that way below, not weakened.
     *
     * **Why the pair, and not one door.** If the vault's setter takes and the auction's refuses,
     * the two pointers are split and `liquidate` refuses `AuctionPointerMismatch` for the rest of
     * the run. That cannot happen under the preconditions above (the auction checks a subset of
     * what the vault checked, plus that the incoming IS the vault's, which it now is), so the
     * second door is called BARE inside the success block: a revert there is a dropped handler
     * frame, which is exactly what `invariant_theHandlerNeverDropsAFrame` exists to report.
     */
    function migrate(uint256 seed) external {
        if (auction.liveAuctionCount() != 0 || auction.openWorkoutCount() != 0) return;
        // Round 55: the vault's manager door counts the parked LOT as well as the two queue
        // counters, so this precondition is the vault's own the same way the two above are.
        // Without it every draw taken over a closed-but-undisposed lot lands in
        // `migrationsRefusedOtherwise`, whose whole job is to be zero, and the campaign loses the
        // repoint state space rather than reporting news. `disposeClosedLot` is the action that
        // clears it, so the fuzzer still reaches a migration by drawing the two in order.
        if (vault.bondCount(address(auction)) != 0) return;

        bool goBack = (seed & 1) == 1 && previousManager != address(0);
        CreditManager target;
        if (goBack) {
            target = CreditManager(previousManager);
        } else {
            if (nextSpare >= managers.length) return;
            target = managers[nextSpare];
        }

        _clearTheLiveBook();
        if (credit.totalDebt() != 0) return;

        address outgoing = address(credit);
        vm.startPrank(admin);
        try vault.setCreditManager(address(target)) {
            auction.setCreditManager(address(target));
            vm.stopPrank();
            previousManager = outgoing;
            credit = target;
            pool = poolOf[address(target)];
            migrations++;
            if (goBack) migrationsBack++;
            else nextSpare++;
        } catch (bytes memory reason) {
            vm.stopPrank();
            if (goBack && _selectorOf(reason) == CollateralVault.CreditManagerNotVirgin.selector) {
                backMigrationsRefusedNotVirgin++;
            } else {
                migrationsRefusedOtherwise++;
            }
        }
    }

    /// @dev A rescuer clears every actor's debt on the live manager, so `totalDebt` can reach the
    ///      zero the vault's setter insists on. `repayFor` is permissionless and settles first;
    ///      a position whose pending yield already covers its stored debt is settled instead.
    function _clearTheLiveBook() private {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint256 live = credit.currentDebtOf(a);
            if (live != 0) {
                usdc.mint(address(this), live);
                usdc.approve(address(credit), live);
                try credit.repayFor(a, live) {
                    rescuesPaid++;
                } catch {}
                usdc.approve(address(credit), 0);
            } else if (credit.debtOf(a) != 0) {
                try credit.settle(a) {} catch {}
            }
        }
    }

    function _selectorOf(bytes memory reason) private pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(reason, 32))
        }
    }

    /// @notice Migrations that landed, how many of them went BACK to the previous manager, how
    ///         many back-attempts the vault's virgin rule refused, and every other refusal.
    /// @dev `migrationsRefusedOtherwise` should stay at zero: the preconditions above are the
    ///      vault's own, so a non-zero reading means the vault refuses something this file does not
    ///      know about, which is news rather than noise. Round 55 added the vault's third arm - the
    ///      parked lot - to that list, and it was found exactly this way.
    uint256 public migrations;
    uint256 public migrationsBack;
    uint256 public backMigrationsRefusedNotVirgin;
    uint256 public migrationsRefusedOtherwise;
    uint256 public rescuesPaid;

    /// @notice The stranger's `claimSurplusFor(auction)` on a manager the vault has LEFT.
    /// @dev `recoverStrandedClaim` above pulls the live manager; this pulls a detached one, which
    ///      is the only permissionless call that unwinds round-54 item 194's over-reserve (a
    ///      booking on a detached bearer that nobody pulled is reserved against every other
    ///      claimant until it arrives). Bundled with the free-balance sweep for the reason
    ///      `recoverStrandedClaim` gives: post-close padding on a detached manager arrives with the
    ///      pull unbooked, and that is excess `invariant_auctionHoldsNothingButUnclaimedRewards`
    ///      forbids at rest.
    function pullDetachedBearer(uint256 seed) external {
        CreditManager m = managers[seed % managers.length];
        if (address(m) == address(credit)) return;
        uint256 held = usdc.balanceOf(address(auction));
        try m.claimSurplusFor(address(auction)) {
            uint256 pushed = usdc.balanceOf(address(auction));
            if (pushed > held) {
                detachedPulls++;
                usdcPushedToTheAuction += pushed - held;
            }
        } catch {}
        uint256 betweenTheLegs = usdc.balanceOf(address(auction));
        try auction.sweepFreeBalanceToInsurance() {
            if (usdc.balanceOf(address(auction)) < betweenTheLegs) freeBalanceSweepsThatMoved++;
        } catch {}
    }

    /// @notice Detached pulls that actually moved USDC onto the auction.
    uint256 public detachedPulls;

    /// @notice The owner disposes a CLOSED workout's lot back to its borrower.
    /// @dev Without this the collateral of every workout the walk resolves stays parked under the
    ///      auction for the rest of the run, so after three workouts no actor holds a bond and no
    ///      auction can ever open again - which is why `test_handlerCanReachEveryStateTheInvariantsCheck`
    ///      could not open a fourth era without it. `disposeTo` settles the recipient on the LIVE
    ///      manager before the count moves, so after a migration this is also the first time the
    ///      new manager stamps that borrower's index. Scans from the seed rather than indexing by it,
    ///      for the reason `expireEligible` gives; the seed is reduced first, for the reason it
    ///      gives in red.
    function disposeClosedLot(uint256 idSeed) external {
        uint256 n = startedAuctions.length;
        if (n == 0) return;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = startedAuctions[(idSeed % n + k) % n];
            (address borrower,, LiquidationAuction.WorkoutStatus status, uint256 bonds,,,,,,,) = auction.workouts(id);
            if (status != LiquidationAuction.WorkoutStatus.Closed || bonds == 0) continue;
            vm.prank(admin);
            try auction.disposeWorkoutLot(id, borrower) {
                lotsDisposed++;
                // `disposeTo` UNSTAKES the lot and hands the raw tokens to the recipient, so the
                // bonds are out of the vault entirely until somebody deposits them again. The
                // borrower does, so the collateral re-enters the walk rather than leaving it.
                vm.prank(borrower);
                try vault.depositBonds(bonds) {} catch {}
            } catch {}
            return;
        }
    }

    /// @notice Closed lots handed back, so positions can re-enter the walk.
    uint256 public lotsDisposed;

    // ── views the invariants need ────────────────────────────────────────────

    /// @dev Restates each exit's precondition from the *spec*, not from the code, and
    ///      asks whether at least one holds. Deriving them independently is the whole
    ///      value: a checker that copied the implementation would agree with it by
    ///      construction and prove nothing.
    ///
    ///      The union has one hole in it, and finding out whether that hole is
    ///      reachable is the job. `liquidatable && bondCount == 0` satisfies none of the
    ///      three: `bid` refuses an empty lot, `cancel` refuses a position that is still
    ///      underwater, and `expireToWorkout` refuses an empty lot too. It *should* be
    ///      unreachable, because a borrower cannot withdraw collateral while breaching
    ///      LTV and nothing else empties a position - but "should be" is an argument,
    ///      and this is a test.
    ///
    ///      **A clock branch used to stand at the head of this function and it was
    ///      UNSOUND. Audit round 46 finding 08, executed; deleted in round 47.** It read:
    ///
    ///      ```
    ///      // expireToWorkout: needs only that the clock has run out.
    ///      if (block.timestamp >= uint256(startedAt) + Config.AUCTION_DURATION) return true;
    ///      ```
    ///
    ///      **The comment is the defect, and the reason it looked right is worth
    ///      keeping.** `expireToWorkout` does open with exactly that clock - it reverts
    ///      `AuctionStillRunning` on its first line and nothing else about it is timed -
    ///      so "needs only that the clock has run out" is a true reading of the *first*
    ///      guard and a false reading of the function. The guard that falsifies it is the
    ///      last one before the workout is written: `if (lot == 0) revert
    ///      NothingToAuction(borrower)`, which is there because a position emptied out
    ///      from under a live auction must not open a workout over nothing. So past
    ///      `AUCTION_DURATION` on an empty lot **all three exits revert, two of them with
    ///      the same error**, and this branch answered "reachable" over precisely the
    ///      strand the invariant exists to find. A predicate restated from the spec is
    ///      only as good as the spec it restates, and this one restated the docstring
    ///      rather than the code.
    ///
    ///      **What the deletion is, and what it is not.** Removing a `return true` can
    ///      only make this function answer true less often, so
    ///      `invariant_everyLiveAuctionHasAReachableExit` is strictly stronger afterwards
    ///      and nothing that used to be checked stops being checked. That sign is a
    ///      property of the edit rather than of a measurement, and it is the half a
    ///      measurement cannot establish. What the measurement adds is the other half:
    ///      the campaign still passes, so the branch was not holding up any state the
    ///      assertion needs.
    ///
    ///      **And the deletion is not a no-op, which is the third thing and the one a
    ///      green run cannot tell you.** A branch nothing ever takes could be deleted
    ///      with the same green result and would have changed nothing at all. MEASURED
    ///      with a throwaway invariant asserting `block.timestamp < startedAt +
    ///      AUCTION_DURATION` over every live auction: it fails, at **`1828574 >=
    ///      1606297`** - a live auction 222,277 seconds, two and a half days, past its
    ///      own expiry. So the campaign really does observe auctions on which the old
    ///      branch short-circuited, and on every one of them the remaining two arms are
    ///      now evaluated instead of skipped. Unseeded, 256 runs x 500 depth.
    ///
    ///      **The strand it admitted is unreachable through shipped code**, which is why
    ///      this was a defect in the instrument and not in the protocol: `_bid` and
    ///      `expireToWorkout` both set `a.settled` before they call `seize`/`reassign`,
    ///      so an auction whose lot has gone is an auction that is no longer live and the
    ///      first line here returns on it. That is an argument, and turning arguments
    ///      into assertions is what this file is for - so it is stated here and
    ///      deliberately not written into the predicate.
    function hasReachableExit(uint256 auctionId) external view returns (bool) {
        (address borrower,,, bool settled,,,,) = auction.auctions(auctionId);
        if (borrower == address(0) || settled) return true; // not live: nothing to strand

        uint256 debt = credit.currentDebtOf(borrower);
        uint256 collateral = vault.collateralValue(borrower);
        bool liquidatable = LtvMath.exceedsLtv(debt, collateral, riskParams.liquidationThresholdBps());

        // cancel: needs the position to have healed.
        if (!liquidatable) return true;

        // bid: needs the position still liquidatable AND a lot to actually sell.
        return vault.bondCount(borrower) != 0;
    }

    function sumBondCounts() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.bondCount(actors[i]);
        }
        sum += vault.bondCount(address(auction)); // workout positions are real positions
    }
}

contract LiquidationAuctionInvariants is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant FLOAT = 1_000_000e6;

    /// @dev Bounded by `LENDER_POOL_DEPOSIT_CAP`, unlike the treasury float this replaced, which
    ///      had no cap at all. Ample for this suite: three actors hold 100 bonds each at 25.15, so
    ///      the whole book cannot exceed about 1,886 USDC at the 25% ceiling.
    uint256 internal constant POOL_DEPOSIT = 20_000e6;

    /// @dev Virgin managers the handler's `migrate` can move the vault to, each with its own pool
    ///      wired on both sides and funded like the first. Three, because the vault's one-way rule
    ///      means a manager that ever distributed yield is never re-attachable, so the number of
    ///      forward migrations a run can make is bounded by this and every one of them is a spare
    ///      the census can name. Round-54 item 191.
    uint256 internal constant SPARES = 3;

    AuctionHandler internal handler;
    /// @dev `managers[0]`/`pools[0]` are `credit`/`pool` below, the pair the walk starts on; the
    ///      deterministic tests that predate the repoint read those two fields and are unchanged.
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
        // **The real pool, on both sides, and audit round 16 is why.** This suite ran on
        // `TreasuryLiquiditySource` and never called `credit.setLenderPool`, so `_setImpairment`
        // returned on its first line and **the entire impairment lifecycle was unreachable** - in
        // the one suite that opens real auctions. Every round-15 contract finding lived in that
        // gap, which made it larger than any of the six test defects that round listed.
        //
        // Both roles rather than the sink alone: `CreditManager._socialise` refuses to charge a
        // pool that is not also the liquidity source, because a balance sheet that lent nothing
        // cannot be charged for a default. A pool wired as sink only would reach `impair` and never
        // reach a realised loss, which is the vacuity this is meant to end rather than relocate.
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

        // Deposited rather than donated: `outstandingPrincipal` has to move when the pool funds a
        // borrow, and every reserve in this pool clamps to that figure. A pool that never lent is
        // a pool that can never be marked, which is the same vacuity one level down.
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
        targetContract(address(handler));
    }

    /// @dev A spare manager, wired exactly as the first one is above, minus the vault's pointer:
    ///      its pool on both sides, the harvester, the auction. `CreditWiring.checkAuctionSwap`
    ///      with no outgoing auction checks only the incoming pair, so a manager the vault does not
    ///      point at yet can be wired to the auction in advance; `migrate` then moves the vault and
    ///      the auction and nothing else. Funded through `deposit` for the reason the first pool is.
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

    /// @dev The manager the vault points at NOW, read off the handler, which is the one place the
    ///      repoint is recorded. Every property about live work reads this; every property about
    ///      a ledger reads all of `managers`.
    function _live() internal view returns (CreditManager) {
        return handler.credit();
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    /// @notice No handler call may revert. Every action in `AuctionHandler` wraps its interesting
    ///         call in `try`, so a handler *frame* that dies is always a fixture fault rather than
    ///         a meaningless random sequence.
    /// @dev **This is the assertion that would have caught the defect this file was rewritten for,
    ///      and no assertion inside the handler could have.** When the fuzzer was rewiring `pool`
    ///      to a random address, `liquidate` reported 444 calls and 31 reverts per run - those 31
    ///      were successful liquidations dying one line later, taking the auction and any counter
    ///      that recorded it down with them. A ghost cannot see that, because the ghost is rolled
    ///      back too. Only the runner, counting frames from outside, can.
    ///
    ///      Deterministic: it is a property of the handler's code, not of the random walk, so
    ///      unlike a per-run reachability floor it cannot flake.
    ///
    ///      Empty body on purpose - the assertion is the config line above it, and it is enforced
    ///      by the runner. This is the one place in the repo where `fail_on_revert` is true; the
    ///      global `false` in `foundry.toml` is still correct for every other suite and is what
    ///      lets the `try`/`catch` idiom work at all.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    /// @notice The auction holds nothing at rest but the rewards it owes. Round-1 finding #1's
    ///         exact shape.
    /// @dev **Swept in audit round 16: the first assertion is subsumed by the second** and cannot
    ///      fail while it holds. Kept, because the two failure modes want different messages and
    ///      the severe one is the under-backing, which is the one this line names. Recorded rather
    ///      than left silent: an assertion that cannot fail beside a stricter neighbour reads as
    ///      two checks and is one, and the round-15 instruction is to sweep for that shape.
    ///
    ///      **"Is stranded forever" was the premise of this invariant's own title and it is no
    ///      longer true.** Audit round 21 finding 4 added `sweepFreeBalanceToInsurance`, so an
    ///      excess is now recoverable rather than permanent. That does not weaken the assertion
    ///      below, which is about what the protocol's own paths leave here **at rest** - and it
    ///      never was a guarantee against an external actor, who could always break the equality
    ///      with a bare `usdc.transfer`. What changed is only what happens next. See
    ///      `recoverStrandedClaim` on the handler for why the two recovery legs are driven as one
    ///      action.
    ///
    ///      **Audit round 22, finding 18 gave this contract a second named claimant, and the
    ///      equality had to become a bound.** `totalWorkoutYieldOwed` is USDC held on behalf of the
    ///      borrowers of cleanly-closed workouts; both sweeps reserve it exactly as they have always
    ///      reserved `totalUnclaimedRewards`, so a sweep now deliberately leaves it behind and
    ///      `balance == totalUnclaimedRewards` is false **by design** rather than by defect.
    ///
    ///      **This is a weakening and it is worth saying so plainly, because round 22's
    ///      follow-up item 6 was decided the other way** - there the answer to "the assertion fails"
    ///      was to feed the fixture, not to loosen the assertion, and that decision was right. It
    ///      does not apply here: nothing about the fixture can make an equality true that the
    ///      *contract* is written to break. What the weakening buys back is that the bound
    ///      degenerates to the old equality whenever `totalWorkoutYieldOwed` is zero, which is every
    ///      state this file could reach before finding 18 - so no behaviour that used to be caught
    ///      stops being caught.
    ///
    ///      **What an attacker gains from the slack, and why it is nothing.** The only room the
    ///      upper bound now allows is USDC up to a figure the contract itself booked, and
    ///      `invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists` below is what stops that
    ///      figure being invented: it holds the booked total against money that demonstrably exists.
    ///      Without that sibling the slack would indeed be a hiding place, since a large enough
    ///      phantom liability would admit any balance at all. The pair is strictly stronger than the
    ///      equality it replaces, which said nothing whatever about whether an obligation could be
    ///      honoured.
    ///      **Audit round 51 gave this contract a THIRD named claimant, by the identical argument
    ///      and with the identical consequence.** The reserve that closes round-51 item 154 holds
    ///      what the lots of still-OPEN workouts have already earned, and that figure is booked
    ///      nowhere - `totalWorkoutYieldOwed` counts closes only - so both sweeps now deliberately
    ///      leave it behind and the two-term bound is false by design in exactly the way the
    ///      one-term equality was. MEASURED against the two-term bound: `157425429 > 0`.
    ///
    ///      **It is DERIVED from the public queue rather than read out of a new accessor**, which
    ///      is the same choice `invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists` below
    ///      already made and it costs the contract no bytes. It is also the stronger form: a
    ///      getter would be the implementation asserting about itself, while this restates the
    ///      quantity from `openWorkoutCount`, `openWorkoutAt`, `workouts` and the manager's own
    ///      `yieldAccruedOn` - so a maintenance error in the contract's running sums fails here.
    ///
    ///      The bound still degenerates to the two-term one whenever no workout is open, and to
    ///      the original equality whenever nothing is booked either. The slack the third term adds
    ///      is again bounded by a figure the contract cannot invent: it is priced off the
    ///      manager's accumulator over bond counts the vault holds, neither of which the auction
    ///      writes.
    ///
    ///      🟥 **THE UPPER BOUND IS ALSO NOW GATED ON AN EMPTY QUEUE, AND THAT IS A SECOND,
    ///      LARGER WEAKENING WHICH SHOULD BE READ AS A COST OF THE FIX RATHER THAN AS BOOKKEEPING.**
    ///      The two-term bound never held on its own arithmetic: it held because every handler
    ///      action that can push USDC onto this contract BUNDLES a `sweepFreeBalanceToInsurance`
    ///      behind it, which is stated in `recoverStrandedClaim`'s own note. A reserve that stops
    ///      money leaving while a workout is open necessarily stops that bundled drain too, so
    ///      between a FORCED close - which books nothing and leaves its lot's yield for insurance -
    ///      and the moment the last workout closes, this contract legitimately holds USDC that is
    ///      neither a reward, nor booked, nor an open lot's accrual. MEASURED against the ungated
    ///      three-term bound: `856220144 > 0`.
    ///
    ///      What is NOT weakened, and is why this is a gate rather than a deletion: the lower
    ///      bound is unconditional, the upper bound is asserted in every state where the money has
    ///      somewhere to go, and
    ///      `invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists` - the sibling that stops
    ///      the booked figure being invented, which is what made the round-22 weakening safe - is
    ///      unconditional and unchanged. Any fix that closes round-51 item 154 pays this price;
    ///      it is not particular to the form chosen, because "the money may not leave while a
    ///      workout is open" is the property itself.
    function invariant_auctionHoldsNothingButUnclaimedRewards() public view {
        assertGe(
            usdc.balanceOf(address(auction)),
            auction.totalUnclaimedRewards(),
            "rewards must always be backed"
        );
        if (auction.openWorkoutCount() != 0) return;
        assertLe(
            usdc.balanceOf(address(auction)),
            auction.totalUnclaimedRewards() + auction.totalWorkoutYieldOwed() + _openWorkoutAccrual(),
            "and nothing else may accumulate"
        );
    }

    /// @dev What the lots of still-open workouts have earned, restated from the auction's public
    ///      queue and the manager's public pricing view rather than read back out of the reserve
    ///      under test. Audit round 51.
    function _openWorkoutAccrual() internal view returns (uint256 total) {
        uint256 n = auction.openWorkoutCount();
        for (uint256 i = 0; i < n; ++i) {
            (,, uint256 bonds, uint256 indexAtOpen) = _openWorkoutTerms(auction.openWorkoutAt(i));
            // The LIVE manager: an open workout can only exist on it, because both repoint doors
            // refuse while one stands (`AuctionHasLiveWork`), and `migrate` returns before them.
            total += _live().yieldAccruedOn(bonds, indexAtOpen);
        }
    }

    /// @dev Split out only because the `workouts` tuple is eleven fields wide and destructuring it
    ///      twice inline is where a position slips.
    function _openWorkoutTerms(uint256 id)
        internal
        view
        returns (address borrower, uint256 openedAt, uint256 bonds, uint256 indexAtOpen)
    {
        uint96 openedAt_;
        (borrower, openedAt_,, bonds,,,,,, indexAtOpen,) = auction.workouts(id);
        openedAt = openedAt_;
    }

    /// @notice Every USDC the auction has **booked** as owed to a cleanly-closed workout's borrower
    ///         is backed by money that actually exists somewhere it can still reach.
    /// @dev **Audit round 22, finding 18, and the assertion that keeps its book entry honest.**
    ///      `closeWorkout` records `Workout.yieldOwed` without pulling the cash - deliberately, since
    ///      the close is permissionless and anything it *did* would be new work a stranger could
    ///      time - so at rest the money behind the entry may be in any of three places: held here
    ///      above the liquidation callers' reserve, settled and waiting in `claimableOf[auction]`,
    ///      or still accruing as `pendingYieldOf[auction]`. All three are reachable by a
    ///      permissionless call, and no path can move any of them past this contract without
    ///      reserving what is booked, so their sum is the honest denominator. Restated from those
    ///      properties rather than copied out of `closeWorkout`.
    ///
    ///      **The defect this was written against, measured.** `sweepWorkoutYieldToInsurance` is
    ///      permissionless and takes the whole realisable claim, while `yieldIndexAtOpen` is never
    ///      advanced when it does - so before the bound in `closeWorkout`, a stranger sweeping
    ///      mid-workout left the close booking 999.999999 against a reachable balance of **zero**.
    ///      The executed PoC is `Impairment.integration.t.sol::
    ///      test_R22_aSweepBeforeTheCloseCannotBookMoneyTheProtocolCannotPay`.
    ///
    ///      **It is not made true by that bound alone, and that is the reason it is an invariant
    ///      rather than a comment on it.** The bound is one statement at one instant; this holds
    ///      over every sequence afterwards, and the sequences are where it could go wrong - both
    ///      sweeps move money past a reserve that has to include this figure, `claimWorkoutYield`
    ///      spends it down against a balance shared with every other claimant, and
    ///      `disposeWorkoutLot` removes the very bonds whose accrual is backing it.
    ///
    ///      **DO NOT DELETE THIS: it is one of only two things that see
    ///      `sweepFreeBalanceToInsurance`'s reservation at all.** Audit round 23, finding 19 called
    ///      it the *sole* guard, measured at `622465b` as the rest of the suite passing 769/0/13
    ///      under the neuter. **RE-MEASURED here and that word is wrong.** Drop
    ///      `totalWorkoutYieldOwed` from the sweep's `owed` line and exactly two assertions in the
    ///      repository go red: this one, at `0 < 38544777`, and
    ///      `Impairment.integration.t.sol::test_R22_theInsuranceSweepCannotTakeACleanClosesYield`,
    ///      which predates the round. Everything else in this file and in
    ///      `LiquidationAuction.t.sol` stays green. Two is still nearly none, and the standing is
    ///      unchanged: this exists for what it makes unreachable rather than for what it has
    ///      caught, the same standing `invariant_theBooksAgreeOnWhatIsOwed` records for itself two
    ///      properties down. The correction is recorded rather than quietly absorbed, because a
    ///      count of guards is the sort of figure the next editor reasons from.
    ///
    ///      Note how that failure prints: `[FAIL: the auction booked workout yield it cannot pay]`
    ///      with **no test name on the line**, because forge does not put one there for an
    ///      invariant. A triage parser anchored on names reports a clean run over it.
    ///
    ///      **It is also the aggregate form of the bound audit round 23 finding 4 found wrong in
    ///      `closeWorkout`.** That clamp netted the spoken-for claims off the held balance only,
    ///      while this nets them off the whole denominator - which is why the two disagreed the
    ///      moment a second workout closed cleanly. The clamp is now written the way this is; if
    ///      either is ever edited, the other is the specification.
    ///
    ///      **This property CAN catch finding 4 on its own, and it is a lottery whether it does -
    ///      which is worse than a flaky failure, because it is a flaky PASS over a real defect.**
    ///      MEASURED: against the defective clamp it reported `48808394 < 97616788` at run 215,
    ///      exactly 2x, which is the arity the finding predicts. But that run was
    ///      `A23_10_AuctionProbes`, a round-23 probe contract that *inherits this one* and declares
    ///      six more campaigns; the shipped contract on the same `--fuzz-seed 0x1111` explored
    ///      128,000 calls and found nothing. **Forge's exploration depends on the enclosing
    ///      contract, not on the seed alone**, so adding or removing a single campaign here changes
    ///      what every other one visits - re-measured on this branch, where the neutered clamp
    ///      passes at 0x1111 in that same probe contract because this file gained a test function.
    ///      No seed is pinned anywhere in this repository, either.
    ///
    ///      The consequence is a rule, not a caveat: **this property is corroboration for finding 4
    ///      and never the proof.** The proof is deterministic and opens two workouts -
    ///      `Impairment.integration.t.sol::test_R23_04_twoCleanClosesCannotBookTheSameClaimTwice`,
    ///      which reports `800000000 > 400000000` against the defective clamp every single time.
    ///
    ///      **Round 54, restated over every manager the vault has pointed at, and the two terms
    ///      are NOT treated alike.** A booking closed under a manager the vault has since left is
    ///      backed by that manager's `claimableOf(auction)`, which `claimSurplusFor` and variant A's
    ///      bearer pull can still reach - so every manager's settled claim is summed. Its
    ///      `pendingYieldOf(auction)` is NOT summed: `CreditManager._settle` returns on its first
    ///      line once detached, so that figure is a projection over the vault's LIVE bond count
    ///      against a frozen accumulator that no call can ever realise (READ, and it is the reason
    ///      `closeWorkout` settles its own position before it books - audit round 46). Only the
    ///      live manager's pending is money that exists. Counting a detached pending would make
    ///      this property weaker than the shipped one; counting only the live one keeps it exactly
    ///      the shipped statement whenever the vault has never moved.
    function invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists() public view {
        uint256 held = usdc.balanceOf(address(auction));
        uint256 rewards = auction.totalUnclaimedRewards();
        uint256 free = held > rewards ? held - rewards : 0;
        uint256 backing = free + _live().pendingYieldOf(address(auction));
        uint256 n = handler.managerCount();
        for (uint256 i = 0; i < n; i++) {
            backing += handler.managerAt(i).claimableOf(address(auction));
        }
        assertGe(
            backing,
            auction.totalWorkoutYieldOwed(),
            "the auction booked workout yield it cannot pay"
        );
    }

    /// @notice `totalWorkoutYieldOwed` equals the sum of `workoutYieldOwedOn` over every address.
    /// @dev Round-54 item 191. The counter-equals-map identity variant A created and nothing
    ///      checked, stated the way the two round-46 identities below are: over the whole closed
    ///      address universe, so a key outside `managers` reads as a failure rather than as a
    ///      narrower sum that happens to balance.
    function invariant_theSplitSumsToTheAggregate() public view {
        address[] memory all = _everyAddressThisFixtureCanName();
        uint256 sum;
        for (uint256 i = 0; i < all.length; i++) {
            sum += auction.workoutYieldOwedOn(all[i]);
        }
        assertEq(auction.totalWorkoutYieldOwed(), sum, "the split must sum to the aggregate");
    }

    /// @notice Every manager's split equals the bookings of the closed workouts that name it as
    ///         bearer, and every closed workout names a manager this fixture deployed.
    /// @dev The per-bearer half of the identity above. `workoutYieldOwedOn[bearer]` is decremented
    ///      by `claimWorkoutYield` on the workout's recorded bearer and incremented by `closeWorkout`
    ///      on the manager it read into `cm`; the mapping docstring argues the two cannot diverge,
    ///      and this holds that argument to the ledger over every sequence the walk produces,
    ///      migrations included. Quantified over every auction that ever started, which is the
    ///      whole domain of `workouts`.
    function invariant_everyBearersSplitIsItsOwnClosedBookings() public view {
        uint256 m = handler.managerCount();
        uint256 n = handler.startedCount();
        for (uint256 i = 0; i < m; i++) {
            address bearer = address(handler.managerAt(i));
            uint256 sum;
            for (uint256 j = 0; j < n; j++) {
                uint256 id = handler.startedAuctions(j);
                (,, LiquidationAuction.WorkoutStatus status,,,,,, address b,, uint256 owed) = auction.workouts(id);
                if (status != LiquidationAuction.WorkoutStatus.Closed) continue;
                assertTrue(b != address(0), "a closed workout must name its bearer");
                if (b == bearer) sum += owed;
            }
            assertEq(auction.workoutYieldOwedOn(bearer), sum, "a bearer's split must equal its own closed bookings");
        }
    }

    /// @notice Nothing is escrowed, ever. If a bond unit ever rests here, some path is
    ///         moving tokens that should only be moving claims.
    function invariant_auctionEscrowsNoBonds() public view {
        assertEq(bond.bondBalance(address(auction)), 0);
    }

    function invariant_atMostOneLiveAuctionPerBorrower() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            uint256 id = auction.auctionOf(handler.actors(i));
            if (id == 0) continue;
            (address borrower,,, bool settled,,,,) = auction.auctions(id);
            assertEq(borrower, handler.actors(i), "the registry and the record must agree");
            assertFalse(settled, "a settled auction must not still be registered as live");
        }
    }

    /// @notice **The property, not the guards.** No sequence may produce a live auction
    ///         that none of bid, cancel or expireToWorkout can close.
    function invariant_everyLiveAuctionHasAReachableExit() public view {
        for (uint256 i = 0; i < handler.startedCount(); i++) {
            assertTrue(handler.hasReachableExit(handler.startedAuctions(i)), "stranded auction");
        }
    }

    /// @notice Every USDC of prepaid bounty is in exactly one of the three pots, and each
    ///         counter agrees with the map or the parks it claims to total.
    /// @dev **This invariant lived in `CreditManager.invariants.t.sol` and compared 0 to 0 on
    ///      every run**, because `liquidate` is not a handler action there and cannot be. It is
    ///      here because this is the suite that reaches the transitions it is about: `liquidate`
    ///      parks, `_bid` and `expireToWorkout` release, `cancel` returns, `claimBounty` drains.
    ///
    ///      **`assertEq`, not `assertGe`, and that is the whole point of it.** The solvency bound
    ///      below is one-sided, so a counter that drifted *low* would leave it green while
    ///      quietly narrowing what it claims - the exact failure this file already records
    ///      against the escrow counter one round earlier.
    ///
    ///      The parked leg is summed over the auctions the handler actually started, so an id
    ///      that was parked against and never resolved is caught rather than assumed away.
    ///
    ///      **This used to say the fuzzer opened zero auctions across 24,000 calls, and it was
    ///      right.** The cause was not reachability and was not the two fixture blockers fixed
    ///      before it - a borrow bound sitting on the dust threshold and an unfunded bidder, both
    ///      real and neither sufficient. It was `setPool`, and the whole diagnosis is on the `pool`
    ///      field above. Auctions were being opened at a healthy rate and destroyed one line later.
    ///
    ///      Measured after the fix, one run of depth 500 per seed, twenty seeds:
    ///
    ///      | fixture | auctions per run | runs opening none |
    ///      |---|---|---|
    ///      | `setPool` present | 0.00 | 20 of 20 |
    ///      | pool injected | 2.00 | 2 of 20 |
    ///      | + `moveNavNearThreshold` | 3.45 | 0 of 20 |
    ///
    ///      Bids follow the same shape: 0 of 20 runs, then 10, then 13.
    function invariant_everyPrepaidBountyIsInExactlyOnePot() public view {
        // Round 54: per manager. Each manager keeps its own three pots; a migration resolves every
        // park first (no live auction may stand) and leaves the escrow and owed maps behind, still
        // claimable (`claimBounty` is open while detached), so the identity holds on each ledger.
        uint256 m = handler.managerCount();
        for (uint256 k = 0; k < m; k++) {
            CreditManager cm = handler.managerAt(k);
            uint256 escrowed;
            uint256 owed;
            for (uint256 i = 0; i < handler.actorCount(); i++) {
                escrowed += cm.bountyEscrowOf(handler.actors(i));
                owed += cm.bountyOwedTo(handler.actors(i));
            }
            owed += cm.bountyOwedTo(handler.keeper());

            uint256 parked;
            for (uint256 i = 0; i < handler.startedCount(); i++) {
                (,, uint256 amount) = cm.parkedBountyOf(handler.startedAuctions(i));
                parked += amount;
            }

            assertEq(cm.totalBountyEscrowed(), escrowed, "escrow counter must equal its map");
            assertEq(cm.totalBountyParked(), parked, "park counter must equal the live parks");
            assertEq(cm.totalBountyOwed(), owed, "owed counter must equal its map");
        }
    }

    /// @notice With no auction live, no bounty is parked against one.
    /// @dev **Audit round 19 asked for this by name, and it is the discriminator the invariant
    ///      above cannot be.** That one sums `parkedBountyOf` over the very set that produced
    ///      `totalBountyParked`, so a park that was never unwound at an auction's close still
    ///      balances against itself perfectly. This states the terminal condition instead: every
    ///      exit that clears `liveAuctionCount` must also have resolved the park in the same frame.
    ///
    ///      Today that is a three-hop argument - all four `liveAuctionCount--` sites pair with a
    ///      bare `resolveBounty`, therefore the implication holds - and three setters gate on that
    ///      counter while trusting the conclusion. An argument holding up three setters should be
    ///      an assertion. It also guards the change this round made: re-striking an auction in
    ///      place deliberately does *not* resolve the park, which is only safe because it does not
    ///      clear the counter either.
    function invariant_noParkSurvivesTheLastLiveAuction() public view {
        if (auction.liveAuctionCount() != 0) return;
        uint256 m = handler.managerCount();
        for (uint256 k = 0; k < m; k++) {
            assertEq(handler.managerAt(k).totalBountyParked(), 0, "a park outlived every auction that could spend it");
        }
    }

    /// @notice What the pool believes it has lent equals what the manager believes is owed.
    /// @dev **The identity audit round 19 derived and then measured at six checkpoints, asserted
    ///      here for the first time.** `outstandingPrincipal == pendingPrincipal + totalDebt` held
    ///      exactly through a 628,750,000 borrow, a yield stream, a crash to half NAV, a short fill
    ///      and a forced `closeWorkout`.
    ///
    ///      It is stated in this suite and nowhere else, and that is not a preference. The
    ///      `CreditManager` suite wires the pool as loss sink only, so `outstandingPrincipal` is
    ///      pinned at zero by construction and the equation would fail on the first borrow; the
    ///      `LenderPool` suite has no `CreditManager` at all, its manager being a bare EOA. This is
    ///      the only fixture where the pool both funds the book and takes the losses, which is also
    ///      the wiring `_wirePhase4` produces.
    ///
    ///      **What it is worth knowing for is what it makes unreachable**, not what it protects.
    ///      It kills `repayPrincipal`'s surplus branch, `unsocialisedLoss`, `flushSocialisedLoss`,
    ///      `unplacedLoss`, `exitReserve()`'s backlog term, both `LossOutstanding` guards and
    ///      `_socialise`'s partial-acceptance path - which is round 10's own fix. None of that is
    ///      deleted, deliberately: switching a dormant quantity back on is a change to every one of
    ///      those consumers at once rather than to one of them. If this assertion ever fails, the
    ///      failure is the news - it means one of them just became live.
    function invariant_theBooksAgreeOnWhatIsOwed() public view {
        // **Round 54: one identity per (pool, manager) pair, and this is a RESTATEMENT rather
        // than the weakening the paragraph below warns against.** The paragraph is about
        // `setLiquiditySource` - moving one manager's FUNDER to a treasury - and it is still
        // right: that lever makes this identity false. `AuctionHandler.migrate` moves the VAULT to
        // a second manager funded by its own pool, which is a different lever, and under it each
        // pair's identity holds on its own: the detached manager's pool still holds the principal
        // it lent, the detached manager still holds the same figure parked in `pendingPrincipal`
        // (the rescuer's `repayFor` put it there and only `settlePrincipal` or a source swap moves
        // it home), and the live pair is the shipped statement over the loans it funds.
        uint256 m = handler.managerCount();
        for (uint256 k = 0; k < m; k++) {
            CreditManager cm = handler.managerAt(k);
            LenderPool lp = handler.poolAt(k);
            assertEq(
                lp.outstandingPrincipal(),
                cm.pendingPrincipal() + cm.owedToSource(address(lp)) + cm.totalDebt(),
                "the pool's lending and the manager's debt have to be the same money"
            );
        }
        assertEq(
            pool.outstandingPrincipal(),
            // `owedToSource` is the third term and it arrived with audit round 22 finding 5. A
            // repoint away from a source that cannot take delivery moves principal out of
            // `pendingPrincipal` into a per-source checkpoint, and the pool's own
            // `outstandingPrincipal` does not come down until `flushPrincipalTo` pays it.
            //
            // **The handler still does not repoint, and audit round 23 finding 11 asked for one.
            // It cannot have one, MEASURED.** This identity is true only while the pool is the
            // sole funder of the book: repointing to a treasury leaves the term at whatever was
            // parked while `totalDebt` then counts loans the treasury funded, so the left side
            // stays at P and the right side becomes P + X on the very next borrow. A handler
            // action would therefore make this property **false**, not non-vacuous - and the
            // fuzzer would report a defect that is not there, which is exactly the trap the file's
            // own history is full of. The measurement is in
            // `test_R23_theParkedTermOfThisIdentityIsReachableAndTheHandlerCannotReachIt`, which
            // reaches the term deterministically instead and asserts this identity through the
            // park and the flush. That test is what stops the term being stated and never checked.
            credit.pendingPrincipal() + credit.owedToSource(address(pool)) + credit.totalDebt(),
            "the pool's lending and the manager's debt have to be the same money"
        );
    }

    /// @notice The vault ledger still equals what is actually staked, with liquidations
    ///         and workouts moving positions around underneath it.
    function invariant_accountingSurvivesLiquidation() public view {
        (uint256 staked,) = farm.userInfo(address(adapter));
        assertEq(staked, handler.sumBondCounts(), "sum(bondCount) == farm stake");
    }

    /// @notice The Phase-2 solvency invariant, now proved over a state space that has
    ///         auctions in it. `writeDownLoss` is the only function that moves money
    ///         between its terms, so it was previously untested by construction.
    function invariant_creditManagerBalanceCoversEveryClaimOnIt() public view {
        // Round 54: every manager, the detached ones included - detachment freezes a manager's
        // accumulator and its unsettled entitlements, and it must not un-back a claim it recorded.
        uint256 m = handler.managerCount();
        for (uint256 k = 0; k < m; k++) {
            CreditManager cm = handler.managerAt(k);
            assertGe(
                usdc.balanceOf(address(cm)),
                cm.totalClaimable() + cm.undistributedYield() + cm.pendingPrincipal() + cm.totalOwedToSources()
                    + cm.insuranceFund() + cm.totalBountyEscrowed() + cm.totalBountyParked() + cm.totalBountyOwed(),
                "balance must cover every claim on it"
            );
        }
    }

    /// @notice Every address this fixture can name, so the two identities below are equalities
    ///         over a domain that is **provably** complete rather than a plausible one.
    /// @dev A counter-equals-map identity is only as good as the set it sums over: a key outside
    ///      the domain makes the counter read high and the assertion fail on a ledger that is
    ///      correct, and - worse, because it is silent - a *narrow* domain paired with a `assertGe`
    ///      would pass over a counter that had drifted. So this enumerates the whole address
    ///      universe instead of the addresses the maps are expected to use.
    ///
    ///      **It is closed, and that is a property of the fixture rather than an assumption.**
    ///      Every actor is drawn by `AuctionHandler._actor`, which is `actors[seed % length]` - no
    ///      fuzzed address ever reaches a call as an account, which is the same reason the `pool`
    ///      pointer had to stop being a setter. So the only addresses that exist here are the ones
    ///      `setUp` created, and they are all below.
    ///
    ///      Zero terms are deliberate. `claimableOf` has three writers and every one of them names
    ///      either an auction record's borrower or an account `_settleYield` was run for, so its
    ///      support is the actors plus the auction; `owedToSource` has two writers and both name
    ///      an *outgoing* liquidity source, which here can only ever be the pool. Including the
    ///      other eleven costs a few thousand gas an observation and buys the difference between
    ///      "the keys I thought of balance" and "the ledger balances".
    function _everyAddressThisFixtureCanName() internal view returns (address[] memory all) {
        uint256 n = handler.actorCount();
        // Round 54: every manager and every pool, the spares included, in place of the one pair.
        // `migrate` only ever installs an address from these two lists, so the universe is still
        // closed; it is just wider than one manager and one pool.
        uint256 m = handler.managerCount();
        all = new address[](n + 9 + 2 * m);
        for (uint256 i = 0; i < n; i++) {
            all[i] = handler.actors(i);
        }
        all[n] = address(auction);
        all[n + 1] = address(vault);
        all[n + 2] = address(adapter);
        all[n + 3] = address(farm);
        all[n + 4] = address(handler);
        all[n + 5] = admin;
        all[n + 6] = keeper;
        all[n + 7] = harvester;
        all[n + 8] = address(this); // the runner holds every pool's deposit
        for (uint256 k = 0; k < m; k++) {
            all[n + 9 + 2 * k] = address(handler.managerAt(k));
            all[n + 10 + 2 * k] = address(handler.poolAt(k));
        }
    }

    /// @notice `totalClaimable` equals the sum of `claimableOf`.
    /// @dev **Audit round 46 finding 08: the counter had no mirror.** `totalClaimable` is a term of
    ///      `invariant_creditManagerBalanceCoversEveryClaimOnIt` above, which is a one-sided bound -
    ///      so a counter that drifted **low** left that bound green while quietly narrowing what it
    ///      claims, and a counter that drifted low is a claimant who cannot be paid. That is the
    ///      identical argument `invariant_everyPrepaidBountyIsInExactlyOnePot` makes for using
    ///      `assertEq` rather than `assertGe`, one pot over; the bounty pots got it in round 18 and
    ///      these two never did.
    ///
    ///      Stated here rather than in `CreditManager.invariants.t.sol` for the reason round 18
    ///      recorded about the bounty counter: three of the four writers are on paths this suite
    ///      reaches and that one does not. `creditLiquidationProceeds` needs a filled bid,
    ///      `_refundBounty` needs a bounty that was parked by a real `liquidate`, and
    ///      `_settleYield`'s overflow branch needs a workout lot earning under the auction. A suite
    ///      with a stub auction can reach none of them, which is how the bounty sibling spent a
    ///      round comparing 0 to 0.
    function invariant_theClaimableCounterEqualsItsMap() public view {
        address[] memory all = _everyAddressThisFixtureCanName();
        uint256 m = handler.managerCount();
        for (uint256 k = 0; k < m; k++) {
            CreditManager cm = handler.managerAt(k);
            uint256 sum;
            for (uint256 i = 0; i < all.length; i++) {
                sum += cm.claimableOf(all[i]);
            }
            assertEq(cm.totalClaimable(), sum, "claimable counter must equal its map");
        }
    }

    /// @notice `totalOwedToSources` equals the sum of `owedToSource`.
    /// @dev **Audit round 46 finding 08, the sibling above's other half - and it is 0 == 0 in this
    ///      campaign, which is stated plainly rather than discovered later.** The only writers of
    ///      `owedToSource` are on the repoint path, `setLiquiditySource` is admin-only, and the
    ///      handler holds no role - so the fuzzer cannot move either side. That is not an oversight
    ///      to be fixed with a handler action: audit round 23 finding 11 asked for exactly one and
    ///      it was refused **by measurement**, because a repoint makes
    ///      `invariant_theBooksAgreeOnWhatIsOwed` false by arithmetic rather than non-vacuous. The
    ///      refusal is asserted at the foot of
    ///      `test_R23_theParkedTermOfThisIdentityIsReachableAndTheHandlerCannotReachIt`.
    ///
    ///      **So the content is in that deterministic test, which calls this at three checkpoints:
    ///      before the park, with `owedToSource[pool]` holding the whole 400.000000, and after the
    ///      flush.** What it is worth as an invariant is the state space it covers *afterwards* -
    ///      it is the standing statement, so the first handler action that can ever move a source
    ///      pointer inherits it rather than needing it written. The same standing
    ///      `invariant_theBooksAgreeOnWhatIsOwed` records for itself two properties up.
    function invariant_theOwedToSourcesCounterEqualsItsMap() public view {
        address[] memory all = _everyAddressThisFixtureCanName();
        uint256 m = handler.managerCount();
        for (uint256 k = 0; k < m; k++) {
            CreditManager cm = handler.managerAt(k);
            uint256 sum;
            for (uint256 i = 0; i < all.length; i++) {
                sum += cm.owedToSource(all[i]);
            }
            assertEq(cm.totalOwedToSources(), sum, "owed-to-sources counter must equal its map");
        }
    }

    /// @notice The `owedToSource` term of `invariant_theBooksAgreeOnWhatIsOwed` is reachable, the
    ///         identity survives the park **and the flush** - and a handler action could not have
    ///         proved either, because it would make the identity false.
    /// @dev **Audit round 23, findings 1 and 11.** The invariant's own comment used to say the
    ///      handler never repoints "so the term reads zero throughout", which is a mechanism
    ///      asserted and then declared unchecked in the same breath. Finding 1 lived in exactly
    ///      that gap: `flushPrincipalTo` paid the pool with a bare transfer, the pool's
    ///      `outstandingPrincipal` never came down, and this identity was false from the flush
    ///      onwards with nothing in the repository able to see it.
    ///
    ///      This is the only fixture where the pool both funds the book and takes the losses -
    ///      `_wirePhase4`'s wiring - so it is the only place the identity means anything, which is
    ///      why the test lives here rather than in a unit suite.
    ///
    ///      **The final block is the measurement behind the refusal.** Finding 11 prescribed a
    ///      repointing handler action. Once the funder is a treasury, `totalDebt` counts loans the
    ///      pool did not fund while `pool.outstandingPrincipal()` cannot move, so the identity is
    ///      false by arithmetic on the next borrow rather than by any defect. The numbers are
    ///      asserted below rather than argued, so a future reader can see the refusal was measured.
    function test_R23_theParkedTermOfThisIdentityIsReachableAndTheHandlerCannotReachIt() public {
        address alice = handler.actors(0);
        uint256 loan = 400e6; // under `MIN_BOUNTIED_DEBT`, so nothing is withheld from the draw

        vm.startPrank(alice);
        credit.borrow(loan);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(loan);
        vm.stopPrank();
        assertEq(credit.totalDebt(), 0, "premise: the book is flat");
        assertEq(pool.outstandingPrincipal(), loan, "premise: the pool still records the loan");
        invariant_theBooksAgreeOnWhatIsOwed();
        invariant_theOwedToSourcesCounterEqualsItsMap();

        // The pool cannot take delivery. This is the round-22 state, on the funding leg that
        // matters, and it is the only way the third term is ever non-zero.
        usdc.setBlocked(address(pool), true);
        TreasuryLiquiditySource treasury = new TreasuryLiquiditySource(usdc, admin);
        vm.startPrank(admin);
        credit.setLiquiditySource(address(treasury));
        treasury.setCreditManager(address(credit));
        vm.stopPrank();
        assertEq(credit.owedToSource(address(pool)), loan, "the term this identity states must be reachable");
        assertEq(credit.pendingPrincipal(), 0, "and the money must have left the other counter");
        invariant_theBooksAgreeOnWhatIsOwed();
        invariant_theOwedToSourcesCounterEqualsItsMap();

        // And the flush, which is where finding 1 lived. Before the fix the pool kept the whole
        // 400.000000 on its own book while every manager-side term went to zero.
        usdc.setBlocked(address(pool), false);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        vm.prank(makeAddr("stranger")); // permissionless
        credit.flushPrincipalTo(address(pool));
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, loan, "the money must go home");
        assertEq(pool.outstandingPrincipal(), 0, "and the pool must stop counting it");
        invariant_theBooksAgreeOnWhatIsOwed();
        invariant_theOwedToSourcesCounterEqualsItsMap();

        // ── why finding 11's prescription is refused, MEASURED ────────────────
        //
        // The identity is a statement about a pool that funds everything. Fund the treasury,
        // borrow through it, and the two sides part company with nothing wrong anywhere.
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(treasury), 10_000e6);
        treasury.fund(10_000e6);
        vm.prank(alice);
        credit.borrow(loan);

        assertEq(pool.outstandingPrincipal(), 0, "the pool funded none of this");
        assertEq(credit.totalDebt(), loan, "the treasury funded all of it");
        assertTrue(
            pool.outstandingPrincipal()
                != credit.pendingPrincipal() + credit.owedToSource(address(pool)) + credit.totalDebt(),
            "a repointing handler action would make this identity FALSE, not non-vacuous"
        );
    }

    /// @notice Proves the fixture above is not vacuous.
    /// @dev Every handler action is wrapped in `try`, which it has to be - most random
    ///      call sequences are meaningless and must not fail a run. The cost is that a
    ///      handler which could never reach a liquidation at all would still report
    ///      green invariants, having exercised nothing.
    ///
    ///      This drives the handler deterministically through every state the
    ///      invariants are supposed to be checking, and asserts each counter moved. It
    ///      is a normal test rather than `afterInvariant` on purpose: `afterInvariant`
    ///      fires once per run against counters that reset each run, so it would demand
    ///      that all six behaviours occur in *every* random 500-call sequence, and fail
    ///      on the first unlucky one.
    ///
    ///      **And that is not a guess. It was tried and measured.** With the fixture as it now
    ///      stands, `afterInvariant` asserting nothing more than `startedCount() > 0` failed a
    ///      256-run campaign with `0 <= 0` - one unlucky run in 256, which is exactly the flake
    ///      rate the paragraph above predicted. There is no cross-run accumulator available
    ///      either: the runner reverts to the post-`setUp` snapshot between runs, so nothing in
    ///      EVM state survives to be totalled.
    ///
    ///      **THE REACH TABLE, and it is a measurement of the CAMPAIGN rather than of this test.**
    ///      Audit round 50, item 137. Both columns are `N of 64` at 64 FORCED SINGLE RUNS,
    ///      unseeded, depth 500, `cache/invariant` cleared between runs, an `afterInvariant`
    ///      override logging every handler ghost (the instrument is generated into a scratch copy,
    ///      read, and never committed). BEFORE is `9d1e72d`; AFTER is the same tree with
    ///      `passTimeToRecognitionDeadline`, `expireEligible` and `closeLiveWorkout` added and
    ///      nothing else changed.
    ///
    ///      | ghost | before | after |
    ///      |---|---|---|
    ///      | `workoutsOpened` | 21 | **27** |
    ///      | `workoutsClosed` | 2 | **12** |
    ///      | `recoveriesPaid` | 2 | **8** |
    ///      | `lateRecoveriesPaid` | **0** | **4** |
    ///      | `forcedClosesThatWroteDown` | **0** | **4** |
    ///      | `cleanClosesThatBookedYield` | 1 | 4 |
    ///      | `workoutYieldClaimsThatPaid` | 1 | 3 |
    ///      | `workoutYieldSweepsThatMoved` | 1 | **11** |
    ///      | `usdcPushedToTheAuction` | 2 | **11** |
    ///      | `freeBalanceSweepsThatMoved` | 2 | **11** |
    ///      | `impairmentsOpenedByAnAuction` | 44 | 44 |
    ///      | `impairmentsReleasedByAnAuction` | 34 | 19 |
    ///      | `bidsFilled` | 20 | 10 |
    ///      | `cancelsDone` | 20 | 11 |
    ///      | `bountiesParked` | 21 | 17 |
    ///      | `bountiesReleased` | 9 | 11 |
    ///      | `bountiesReturned` | 9 | 1 |
    ///      | `reStrikes` | 2 | **0** |
    ///      | `navsDrawnNearThreshold` | 64 | 64 |
    ///      | `yieldEpochsDistributed` | 64 | 64 |
    ///      | `warpsToRecognitionDeadline` | - | 10 |
    ///      | `expiriesFromEligible` | - | 25 |
    ///      | `closesFromLiveDraw` | - | 5 |
    ///
    ///      **The item this closes said the workout lifecycle was reached in ZERO of 64 runs, and
    ///      that is right about the terminal half and wrong about the entry.** Workouts were being
    ///      OPENED in a third of runs and almost never resolved, which is worse than not reaching
    ///      them: every property about a recognised loss was quantified over a state space holding
    ///      about one instance of it in 32,000 calls, and every one of them reported green.
    ///
    ///      🟥 **AND THE TABLE HAS A COST COLUMN IN IT, which is why the whole census is printed
    ///      rather than the rows that improved.** Three new actions dilute every other selector by
    ///      about an eighth, and more auctions now end in a workout rather than in a fill or a
    ///      cancel: `bidsFilled` and `cancelsDone` halve, `bountiesReturned` falls from 9 to 1, and
    ///      **`reStrikes` falls from 2 of 64 to 0 of 64**. That last one is a real loss - the
    ///      round-19 re-strike branch is now unreached by the campaign, and the only thing standing
    ///      over it is the deterministic block in this test. It is recorded here rather than
    ///      absorbed, because the next reader of this file needs to know which of these numbers are
    ///      evidence and which are the price of the evidence.
    ///
    ///      **So the vacuity guard is deliberately split in two, and neither half is a campaign
    ///      floor.** This test proves every transition is reachable at all;
    ///      `invariant_theHandlerNeverDropsAFrame` proves the fuzzer is not silently discarding
    ///      the ones it reaches. The second is the half this file did not have, and it is the half
    ///      that mattered - a suite can pass a reachability tripwire and still fuzz nothing, which
    ///      is precisely what happened here for three audit rounds.
    ///
    ///      **ROUND 54's CENSUS, under the repointing action, and what it says the campaign's
    ///      green is and is not evidence about.** Round-54 item 191 measured that without
    ///      `migrate` the walk reached NONE of the three sites variant A changed. With it, three
    ///      unseeded censuses at 256 runs x 500 calls (the round-53 instrument reinstalled as a
    ///      diff, `cache/invariant` cleared, every member its own campaign) reached a migration
    ///      and a migration BACK in run 1 of every census, and reached the bearer pull
    ///      (`bearer != live` on a paid claim) and the per-bearer clamp (`split != aggregate`
    ///      before a close) in runs 20 and 29, then 154 and 154, then in NEITHER - a lottery
    ///      across runs, the same shape round 51 recorded about this file. The third site, the
    ///      reserve term `totalWorkoutYieldOwed - owed`, was reached in ZERO runs of all three
    ///      censuses, ZERO at 64 runs x 2,000 calls, and ZERO with an unshipped draw that closed
    ///      every open workout in one frame (`bookingsMadeBesideAnother`'s docstring has why). So
    ///      the campaign's `(runs: 256, calls: 128000)` green corroborates the bearer pull and
    ///      the clamp and says NOTHING about the reserve term; that term is asserted
    ///      DETERMINISTICALLY below, in `_repointEraTwo`: `bookingsMadeBesideAnother == 1`, and
    ///      bob paid exactly `499,999,999 - 298,459,777` with carol's booking still standing.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        handler.borrow(0, 500e6); // alice, at a healthy LTV
        handler.borrow(1, 500e6); // bob
        handler.borrow(2, 500e6); // carol

        // The biased draw has to be shown firing, not just present. Its guard returns early on a
        // position with no debt or no bonds, so a version that silently never fired would leave
        // the uniform walk doing all the work and this file back where it started.
        handler.moveNavNearThreshold(0, 0);
        assertEq(handler.navsDrawnNearThreshold(), 1, "the biased NAV draw must actually fire");

        handler.moveNav(8e8); // everyone is now underwater
        handler.liquidate(0);
        handler.liquidate(1);
        handler.liquidate(2);
        assertEq(handler.startedCount(), 3, "auctions must be openable");

        // **The reachability audit round 16 found this suite had never had.** Until the real pool
        // was wired on both sides, `_setImpairment` returned on its first line and the whole
        // impairment lifecycle was unreachable here - in the one suite that opens real auctions.
        // Asserted on the pool's own storage, so "the manager was asked" cannot pass for "the pool
        // was marked".
        assertEq(handler.impairmentsOpenedByAnAuction(), 3, "a liquidation must reserve in the pool");
        assertGt(pool.totalImpairment(), 0, "and the summed reserve must be real");
        assertGt(pool.exitReserve(), 0, "and it must reach the price a leaver is paid at");

        // **A ghost per bounty branch, because a tripwire proves only the transition it names.**
        // The round-eighteen finding was a bounty invariant declared in a suite that could not
        // reach a liquidation at all, sitting beside a sibling that had been neuter-verified. So
        // each of the three branches is asserted reachable on its own, and `assertGt` on the
        // parked total is what stops the whole set passing over a charge that never happened.
        assertEq(handler.bountiesParked(), 3, "opening an auction must park the escrow");
        assertGt(credit.totalBountyParked(), 0, "and the parked total must be real money");

        // **The re-strike branch, audit round 19.** A lapsed auction is re-struck in place rather
        // than replaced, so it must be reachable here or every property that quantifies over it -
        // the deadline, and the fact that the park never changes hands - is asserted over a branch
        // the campaign may never enter. Asserted on the *outcomes* rather than only on the ghost:
        // the id must not move, and the park must still belong to whoever opened it.
        uint256 idBefore = auction.auctionOf(handler.actors(0));
        (address claimantBefore,, uint256 parkedBefore) = credit.parkedBountyOf(idBefore);
        // 🟥 **`handler.passTime(Config.AUCTION_DURATION + 1)` used to stand here and on the
        // second workout below, and the argument did not mean what it read.** `passTime` takes a
        // SEED and does `skip(bound(seed, 1 minutes, 3 days))`. It happened to be correct - 21,601
        // lies inside that range, so `bound` returns it unchanged and the skip really was
        // `AUCTION_DURATION + 1` - and it was correct by ARITHMETIC COINCIDENCE rather than by
        // construction: raise `AUCTION_DURATION` past three days, or lower `passTime`'s ceiling,
        // and the same line silently skips a different interval while still reading like a
        // deadline. Audit round 50, item 137. A deterministic walk that wants a specific instant
        // says so directly.
        skip(Config.AUCTION_DURATION + 1);
        handler.liquidate(0);
        assertEq(handler.reStrikes(), 1, "a lapsed auction must be re-strikeable");
        assertEq(auction.auctionOf(handler.actors(0)), idBefore, "re-striking must not mint a new id");
        (address claimantAfter,, uint256 parkedAfter) = credit.parkedBountyOf(idBefore);
        assertEq(claimantAfter, claimantBefore, "nor hand the park to whoever re-struck it");
        assertEq(parkedAfter, parkedBefore, "nor move the money");

        // One is bought.
        handler.bid(0, 1);
        assertEq(handler.bidsFilled(), 1, "auctions must be fillable");
        assertEq(handler.bountiesReleased(), 1, "and a fill must earn the escrow");

        // One heals and is cancelled.
        handler.moveNav(30e8);
        handler.cancel(1);
        assertGt(handler.impairmentsReleasedByAnAuction(), 0, "a terminal transition must release");
        assertEq(handler.cancelsDone(), 1, "auctions must be cancellable");
        assertEq(handler.bountiesReturned(), 1, "and a cancel must give the escrow back");

        // One runs out of time, is partly recovered, then written off.
        handler.moveNav(8e8);
        handler.passTime(3 days);
        handler.expire(2);
        assertEq(handler.workoutsOpened(), 1, "the workout path must be reachable");

        // ── the yield source this fixture never had ──────────────────────────
        //
        // **Audit round 22, finding 14.** The auction is now holding a workout lot - staked,
        // earning, with no debt in front of it - which is the exact state
        // `CreditManager.claimSurplusFor`, `LiquidationAuction.sweepFreeBalanceToInsurance` and
        // `sweepWorkoutYieldToInsurance` were all built for. With no epoch ever delivered that lot
        // earned nothing, so all three ran thousands of times per campaign and moved zero USDC.
        // Every assertion in this block was unreachable before `deliverYield` existed, and each is
        // asserted on **money that moved** rather than on a call that failed to revert.
        assertGt(vault.bondCount(address(auction)), 0, "the workout lot must be parked under the auction");
        // 🟥 **Audit round 55, item 215: the two PRE-close epochs are deliberately small, and the
        // post-close ones are not.** These two exist to give the refusals below something real to
        // refuse, and any non-zero amount does that. Since the forced close now spends the lot's
        // accrual on its own residual before writing anything down, a large pre-close epoch covers
        // the residual entirely, `writeDownLoss` returns zero, and `workoutSettleAfterClose`
        // returns without reaching its body - which would silently retire round-23 finding 11's
        // census state further down. They were 500.000000 each until this round.
        handler.deliverYield(50e6);
        assertEq(handler.yieldEpochsDistributed(), 1, "an epoch must reach the accumulator");
        handler.passTime(3 days);

        handler.recoverStrandedClaim();
        assertGt(handler.usdcPushedToTheAuction(), 0, "claimSurplusFor must actually push the auction's claim");
        // **Audit round 51 moved the two sweep assertions behind the close, and asserts the
        // negative here rather than deleting the attempt.** Both sweeps now reserve what the lots
        // of still-OPEN workouts have earned, and while workout 2 is the only lot the auction
        // holds that reserve is the whole of what the push just delivered. So the money arrives
        // and stays, which is the entire point of round-51 item 154's fix - and if a later change
        // ever lets a sweep take it again, this line is what goes red.
        assertEq(handler.freeBalanceSweepsThatMoved(), 0, "no sweep may take an open workout's backing");

        // A second epoch. The live manager's own claim route is a different call with a different
        // failure mode, so it gets its own money - and it is refused for the same reason. Small for
        // the reason stated on the first one; it was 500.000000 until round 55.
        handler.deliverYield(50e6);
        handler.passTime(3 days);
        handler.sweepWorkoutYield();
        assertEq(handler.workoutYieldSweepsThatMoved(), 0, "nor may the sibling sweep, for the same reason");

        handler.workoutSettle(2, 100e6);
        assertEq(handler.recoveriesPaid(), 1, "recoveries must be payable");

        // **`passTime` is capped at three days a call, which is what makes the 14-day recognition
        // window unreachable for the CAMPAIGN rather than merely slow, and audit round 50 item 137
        // measured the cost.** Five consecutive maximal draws with nothing in between is not a
        // sequence a bounded uniform draw produces: over 64 forced runs of 500 calls,
        // `forcedClosesThatWroteDown` was 0 of 64. The cap is still right - one lucky jump doing
        // all the work is the failure it prevents - so the fix is a sibling action that draws for
        // the deadline exactly, never a wider `passTime`.
        //
        // Driven through that action here rather than through five `passTime` calls, so the
        // deterministic walk exercises the thing the campaign now relies on instead of a hand-rolled
        // equivalent of it.
        handler.passTimeToRecognitionDeadline(0);
        assertEq(handler.warpsToRecognitionDeadline(), 1, "the recognition deadline must be reachable");
        handler.closeWorkout(2);
        assertEq(handler.workoutsClosed(), 1, "losses must be recognisable");

        // ── both sweeps, now that the outcome is known ───────────────────────
        //
        // **Audit round 51, and this pair is the whole behavioural change the reserve makes.**
        // Workout 2 ran out of time and wrote a residual down, so its lot's yield really is the
        // insurance fund's by round 22 finding 18 - which is a fact the protocol could not know
        // while the workout was open, and which the two refusals above are waiting for. With the
        // open queue empty the reserve is zero and both routes move money again, so nothing that
        // used to be reachable has stopped being reachable; it has moved behind the close.
        //
        // Ordered rather than arbitrary: `recoverStrandedClaim` bundles `claimSurplusFor` with the
        // free-balance sweep and would otherwise leave the sibling nothing to claim - which would
        // reach `sweepWorkoutYieldToInsurance`'s `swept == 0` refusal, and that clause is round-51
        // item 155's dead one, so a census must not start depending on it.
        //
        // 🟥 **Audit round 55, item 215: the free-balance leg now needs its OWN epoch, exactly the
        // way the sibling leg below already did.** The forced close claims and sweeps this
        // contract's whole free balance into the fund before it writes anything down, so the
        // accrual this leg used to find sitting here was spent one call earlier by
        // `handler.closeWorkout(2)`. Without a fresh epoch this leg would move zero and the
        // tripwire would go red on the state it exists to prove reachable - which is the honest
        // outcome and is why the fix is an epoch rather than a weaker assertion. The lot stays
        // parked and earning until it is disposed of, so a post-close epoch reaches the same claim
        // by the same route.
        uint256 epochsBeforeTheFreeBalanceLeg = handler.yieldEpochsDistributed();
        handler.deliverYield(500e6);
        assertGt(handler.yieldEpochsDistributed(), epochsBeforeTheFreeBalanceLeg, "the free-balance leg needs an epoch");
        handler.passTime(3 days);
        handler.recoverStrandedClaim();
        assertGt(handler.freeBalanceSweepsThatMoved(), 0, "and the free-balance sweep must actually move it");

        uint256 epochsBeforeTheSiblingSweep = handler.yieldEpochsDistributed();
        handler.deliverYield(500e6);
        assertGt(handler.yieldEpochsDistributed(), epochsBeforeTheSiblingSweep, "the sibling sweep needs its own epoch");
        handler.passTime(3 days);
        handler.sweepWorkoutYield();
        assertGt(handler.workoutYieldSweepsThatMoved(), 0, "the workout-yield sweep must actually fund insurance");

        // And the redemption comes good after the close. Audit round 21, finding 14: this is the
        // state the campaign could not reach before, because there was no call that could reach
        // it - the money had nowhere to go but the insurance fund.
        handler.workoutSettleAfterClose(2, 50e6);
        assertEq(handler.lateRecoveriesPaid(), 1, "a late tranche must still be payable");
        // **Audit round 23, finding 11.** The precondition asserted rather than assumed: without a
        // workout that actually wrote something down, `workoutSettleAfterClose` returns without
        // reaching its body, and the assertion above would be measuring the `try` rather than the
        // mechanism. The finding is that the *campaign* rarely reaches this state; this
        // deterministic walk always does, and the ghost is what tells the two apart.
        assertEq(handler.forcedClosesThatWroteDown(), 1, "the late tranche needs a written-down workout");

        // ── the clean close, and the entry it books ──────────────────────────
        //
        // **Audit round 22, finding 18.** Every close this test had reached until here was a
        // *forced* one, which books nothing and pays nobody - so `totalWorkoutYieldOwed`,
        // `claimWorkoutYield` and the invariant that holds the two together were quantifying over
        // a state this tripwire could not produce. That is the vacuity shape the file is built to
        // refuse, and it arrived with a finding rather than with a fixture.
        //
        // Actor 1's auction healed and was cancelled far above, so its position is the one still
        // standing. It is borrowed against afresh before being liquidated again, and that is not
        // fixture noise: the two epochs already delivered settled into that position and took its
        // debt to **1 USDC-wei**, at which point no NAV this oracle can post makes it unhealthy. A
        // bare `liquidate` here would have been swallowed by the handler's `try` and this whole
        // block would have proved nothing - the failure mode the file exists to refuse, arriving
        // one more time. MEASURED while writing it: `startedCount` stuck at 3.
        //
        // The workout that follows is settled in full rather than run out of time, which is the
        // only difference that makes a close clean.
        handler.moveNav(30e8);
        handler.borrow(1, 620e6);
        handler.moveNav(1e8);
        handler.liquidate(1);
        assertEq(handler.startedCount(), 4, "a re-borrowed position must be liquidatable again");
        // Through the eligible-draw action rather than through `passTime` plus a blind modulo, so
        // both halves of what the campaign now depends on are exercised deterministically: the
        // scan finds the one unsettled auction (ids 1, 2 and 3 are filled, cancelled and expired
        // by this point) and moves the clock to its own deadline before expiring it.
        handler.expireEligible(0);
        assertEq(handler.expiriesFromEligible(), 1, "the eligible-auction draw must actually expire one");
        assertEq(handler.workoutsOpened(), 2, "the second workout must open");

        // Its own epoch, delivered while the workout is open, so the lot earns something for the
        // close to book. Asserted on the auction's claim rather than on the call.
        handler.deliverYield(500e6);
        handler.passTime(3 days);
        assertGt(
            credit.claimableOf(address(auction)) + credit.pendingYieldOf(address(auction)),
            0,
            "the workout lot must have earned something for the close to book"
        );

        handler.workoutSettle(3, 2_000e6);
        assertEq(credit.currentDebtOf(handler.actors(1)), 0, "the settlement must clear the debt");
        // The live draw, on the clean branch, and with NO warp in front of it - which is the whole
        // reason `closeLiveWorkout` does not fold the clock in. `residual` is zero here, so
        // `closeWorkout` never evaluates the recognition deadline, and a version of this action
        // that warped first would have made every close in the campaign a forced one and deleted
        // this state.
        handler.closeLiveWorkout(0);
        assertEq(handler.closesFromLiveDraw(), 1, "the live-workout draw must actually close one");
        assertEq(handler.workoutsClosed(), 2, "the clean close must land");
        assertEq(handler.cleanClosesThatBookedYield(), 1, "and it must book the borrower's yield");
        assertGt(auction.totalWorkoutYieldOwed(), 0, "and the running total must be real money");

        // And the drain. Without it the figure only ever grows and an error on the way out is never
        // reached - the same argument `claimBounty` carries.
        uint256 borrowerBefore = usdc.balanceOf(handler.actors(1));
        handler.claimWorkoutYield(3);
        assertEq(handler.workoutYieldClaimsThatPaid(), 1, "the borrower must be able to collect it");
        assertGt(usdc.balanceOf(handler.actors(1)), borrowerBefore, "and the USDC must actually arrive");

        // ── the repoint, and the three sites variant A changes ──────────────
        //
        // **Round-54 item 191.** Everything above happened under one manager, which is the only
        // state space this file could reach until `migrate` existed - and round 53 measured that
        // in that space `workoutYieldOwedOn[live] == totalWorkoutYieldOwed` at every instant, the
        // per-bearer clamp subtracts exactly what the aggregate did, the reserve term
        // `totalWorkoutYieldOwed - owed` is zero on every paid claim, and the bearer pull is dead
        // code. So each of the three is driven here, deterministically, and asserted on the
        // handler's own ghosts, the same way every earlier round's blind spot was.
        _repointEraTwo();
        _repointEraThree();
        assertEq(handler.migrationsRefusedOtherwise(), 0, "the vault refused a repoint this walk does not understand");
    }

    /// @dev Era two: a booking left UNCLAIMED on the original manager, the vault moved to a spare,
    ///      a clean close on the spare booked in FULL (the round-53 finding under its fix), and
    ///      the two claim orders that exercise the reserve term and the bearer pull.
    function _repointEraTwo() internal {
        // Both lots the walk above parked go back to their borrowers, or nobody holds a bond and
        // no auction can open again; the disposal path itself is new to this suite.
        handler.disposeClosedLot(0);
        handler.disposeClosedLot(0);
        assertEq(handler.lotsDisposed(), 2, "both closed lots must be disposable");
        assertEq(vault.bondCount(address(auction)), 0, "nothing may stay parked under the auction");

        uint256 carolId = _cleanCloseOnTheLiveManager(2, 1, 1);
        uint256 carolBooked = _yieldOwed(carolId);
        assertGt(carolBooked, 0, "carol's clean close must book yield on the original manager");
        assertEq(auction.workoutYieldOwedOn(address(credit)), carolBooked, "and split it onto that manager");

        // Round 55: the vault's manager door now refuses while carol's closed lot is still parked,
        // so this disposal - which used to FOLLOW the repoint - has to precede it. The half of the
        // old assertion that is lost here ("the disposal must settle the recipient on the NEW
        // manager") is not lost from the walk: bob's era-two lot is closed on the spare and
        // disposed at the top of era three, which is that same shape one era along.
        handler.disposeClosedLot(0);
        assertEq(handler.lotsDisposed(), 3, "carol's closed lot must be disposable before the repoint");
        assertEq(vault.bondCount(address(auction)), 0, "nothing may stay parked under the auction at a repoint");

        handler.migrate(0);
        assertEq(handler.migrations(), 1, "the vault must be repointable once the book is clear");
        assertTrue(address(handler.credit()) != address(credit), "the walk must have LEFT the original manager");
        assertEq(vault.creditManager(), address(handler.credit()), "the handler must follow the vault");
        assertEq(auction.creditManager(), address(handler.credit()), "and so must the auction");
        assertEq(credit.claimableOf(address(auction)), carolBooked, "her backing stays settled on the detached manager");

        // Bob closes clean on the spare with a bigger pot than carol's booking, so the reserve
        // term below is a PARTIAL payment rather than a refusal.
        uint256 bobId = _cleanCloseOnTheLiveManager(1, 2, 10);
        assertEq(handler.cleanClosesBookedOnASplitPot(), 1, "the split must differ from the aggregate at a close after a repoint");
        assertEq(handler.bookingsMadeBesideAnother(), 1, "bob's booking must be made while carol's still stands");
        uint256 bobBooked = _yieldOwed(bobId);
        {
            (,,, uint256 bonds,,,,,, uint256 idx,) = auction.workouts(bobId);
            assertEq(bobBooked, _live().yieldAccruedOn(bonds, idx), "bob was clamped by a booking the live pot does not hold");
        }
        assertGt(bobBooked, carolBooked, "fixture: bob must out-earn carol's booking");
        assertEq(auction.workoutYieldOwedOn(address(_live())), bobBooked, "bob's booking is split onto the spare");
        assertEq(auction.totalWorkoutYieldOwed(), carolBooked + bobBooked, "the split does not sum to the aggregate");

        // Bob first: carol's booking is reserved against him and unpulled, so he is paid short by
        // exactly it. The reserve term, non-zero and BINDING.
        uint256 bobBefore = usdc.balanceOf(handler.actors(1));
        // Through the booked-workout draw, so the action the campaign relies on to reach this
        // term is the one exercised here; carol's claim below goes through the blind one.
        handler.claimBookedWorkout(_indexOf(bobId));
        assertEq(handler.targetedClaims(), 1, "the booked-workout draw must find bob's booking");
        assertEq(handler.claimsPaidWithForeignBookingsReserved(), 1, "the reserve term must be reachable");
        assertEq(handler.partialClaimsBoundByForeignBookings(), 1, "and it must be able to BIND a payment");
        assertEq(usdc.balanceOf(handler.actors(1)) - bobBefore, bobBooked - carolBooked, "bob's short is not exactly the unpulled booking");

        // Carol second: her bearer is the manager the vault left, so her claim takes the pull
        // branch and realises her own backing off it.
        uint256 carolBefore = usdc.balanceOf(handler.actors(2));
        handler.claimWorkoutYield(_indexOf(carolId));
        assertEq(handler.claimsPaidFromADetachedBearer(), 1, "the bearer branch must be reachable");
        assertEq(handler.bearerPullsThatRealised(), 1, "and the pull must actually realise the detached pot");
        assertEq(usdc.balanceOf(handler.actors(2)) - carolBefore, carolBooked, "carol must be paid in full from her own bearer");

        // Bob's remainder, now that her pull left his money unreserved.
        handler.claimWorkoutYield(_indexOf(bobId));
        assertEq(usdc.balanceOf(handler.actors(1)) - bobBefore, bobBooked, "bob must be whole in total");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a booking survived both claims");
        assertEq(auction.workoutYieldOwedOn(address(credit)) + auction.workoutYieldOwedOn(address(_live())), 0, "a split survived both claims");
    }

    /// @dev Era three: a booking left on the spare, a BACK-migration refused by the vault's virgin
    ///      rule, a second forward migration, the stranger's pull on the detached bearer, and a late
    ///      tranche delivered to a bearer the vault has left.
    function _repointEraThree() internal {
        // Only bob's era-two lot is still parked; carol's went back before his era began.
        handler.disposeClosedLot(0);
        assertEq(handler.lotsDisposed(), 4, "bob's era-two lot must be disposable");
        assertEq(vault.bondCount(address(auction)), 0, "nothing may stay parked under the auction");

        uint256 carolId = _cleanCloseOnTheLiveManager(2, 1, 1);
        uint256 carolBooked = _yieldOwed(carolId);
        address spareOne = address(_live());

        // Round 55: her close parks her lot again, and the vault's manager door refuses over it,
        // so it goes back to her before EITHER move below. Both draws in this era are about the
        // manager pointer and neither loses anything by the lot being gone - her booking is
        // recorded against her bearer, not against the collateral.
        handler.disposeClosedLot(0);
        assertEq(handler.lotsDisposed(), 5, "carol's era-three lot must be disposable before the repoint");
        assertEq(vault.bondCount(address(auction)), 0, "nothing may stay parked under the auction at a repoint");

        // Odd seed: asks to go back to the original manager, which distributed yield in era one.
        // The vault decides, not the handler.
        handler.migrate(1);
        assertEq(handler.backMigrationsRefusedNotVirgin(), 1, "the one-way rule must be the thing that refuses a return");
        assertEq(handler.migrations(), 1, "and nothing must have moved");
        assertEq(vault.creditManager(), spareOne, "the vault must still point at the spare");

        // A live borrow on the spare, so the second forward move has a book to clear: the vault's
        // door insists on `totalDebt == 0`, and the rescuer's permissionless `repayFor` inside
        // `migrate` is the only thing that gets this walk through it with a debt standing.
        handler.moveNav(30e8);
        handler.borrow(1, 100e6);
        assertGt(_live().currentDebtOf(handler.actors(1)), 0, "bob must be able to borrow on the spare before the repoint");
        handler.migrate(0);
        assertEq(handler.rescuesPaid(), 1, "the rescuer must have cleared bob's live debt before the vault admitted the move");
        assertEq(handler.migrations(), 2, "a second forward migration must land");
        assertTrue(address(_live()) != spareOne, "onto a fresh spare");

        // The stranger pulls the detached bearer: money moves, and the bundled sweep must leave it
        // alone because every wei of it is booked.
        uint256 sweepsBefore = handler.freeBalanceSweepsThatMoved();
        handler.pullDetachedBearer(1);
        assertEq(handler.detachedPulls(), 1, "the stranger's pull on a detached bearer must move money");
        assertEq(handler.freeBalanceSweepsThatMoved(), sweepsBefore, "and the sweep must not take a booked pot");

        uint256 carolBefore = usdc.balanceOf(handler.actors(2));
        handler.claimWorkoutYield(_indexOf(carolId));
        assertEq(handler.claimsPaidFromADetachedBearer(), 2, "a claim on an already-pulled bearer still takes the branch");
        assertEq(handler.bearerPullsThatRealised(), 1, "but has nothing left to realise");
        assertEq(usdc.balanceOf(handler.actors(2)) - carolBefore, carolBooked, "carol must be paid the pulled pot in full");

        // The late tranche on carol's FORCED workout from era one is delivered to its bearer, the
        // original manager, which the vault left two migrations ago.
        (,,,,,,, uint256 outstanding, address bearer,,) = auction.workouts(3);
        assertGt(outstanding, 0, "fixture: the era-one write-down must still be recoverable");
        assertEq(bearer, address(credit), "fixture: its bearer is the original manager");
        handler.workoutSettleAfterClose(_indexOf(3), 50e6);
        assertEq(handler.lateRecoveriesToADetachedBearer(), 1, "a late tranche must reach a detached bearer");

        // The three remaining `migrate` counters, read here so none is an unread ghost. Two forward
        // moves consumed spares one and two in order. This walk never ADMITS a return: every
        // manager it leaves has distributed yield, so the vault's one-way rule refuses each (ghost
        // 1 above), and the accepted return - to a spare that never streamed - is driven
        // deterministically in `R54A01_RepointLeads` lead 1 and was reached by the campaign in run
        // 1 of all three round-54 censuses. The rescuer's `repayFor` cleared live debt ahead of a
        // repoint exactly this many times, MEASURED by this line when it was written.
        assertEq(handler.nextSpare(), 3, "two forward migrations must have consumed two spares in order");
        assertEq(handler.migrationsBack(), 0, "this walk admits no return; lead 1 and the census hold that branch");
        assertEq(handler.rescuesPaid(), 1, "the rescuer cleared the book exactly once, ahead of the era-three move");
    }

    /// @dev Borrow at the cap on the live manager, crash, liquidate, expire, `epochs` epochs of
    ///      yield, settle the debt through the workout, and close it CLEAN by the live draw.
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
        // `skips` three-day draws per epoch. A spare deployed in `setUp` and installed weeks of
        // simulated time later streams its first epoch over that whole shelf life
        // (`distributeYield`'s `duration = max(elapsed since lastDistributeAt, ...)`, round-54
        // item 70's drought re-rating, MEASURED here at 86,805,399 for two epochs over six days
        // against about 360,000,000 on a five-day stream), so an era on a fresh spare needs time,
        // not more epochs, to earn.
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

    /// @dev The handler's id-taking actions index `startedAuctions[seed % length]`; this is the
    ///      seed that names `id`.
    function _indexOf(uint256 id) internal view returns (uint256) {
        uint256 n = handler.startedCount();
        for (uint256 j = 0; j < n; j++) {
            if (handler.startedAuctions(j) == id) return j;
        }
        revert("fixture: unknown auction id");
    }
}
