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
contract AuctionHandler is Test {
    CollateralVault public immutable vault;
    CreditManager public immutable credit;
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

    constructor(
        CollateralVault vault_,
        CreditManager credit_,
        LiquidationAuction auction_,
        MockNavOracle oracle_,
        MockUSDC usdc_,
        MockBond bond_,
        LenderPool pool_,
        address keeper_,
        address harvester_,
        address[] memory actors_
    ) {
        vault = vault_;
        credit = credit_;
        riskParams = credit_.riskParams();
        auction = auction_;
        oracle = oracle_;
        usdc = usdc_;
        bond = bond_;
        pool = pool_;
        keeper = keeper_;
        harvester = harvester_;
        actors = actors_;
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
    LenderPool internal immutable pool;

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
        try auction.workoutSettleAfterClose(id, pay) {
            lateRecoveriesPaid++;
        } catch {}
        usdc.approve(address(auction), 0);
    }

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
        try auction.closeWorkout(id) {
            workoutsClosed++;
            if (auction.totalWorkoutYieldOwed() > bookedBefore) cleanClosesThatBookedYield++;
            (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
            if (writtenDown != 0) forcedClosesThatWroteDown++;
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
        uint256 bookedBefore = auction.totalWorkoutYieldOwed();
        try auction.claimWorkoutYield(startedAuctions[idSeed % startedAuctions.length]) {
            if (auction.totalWorkoutYieldOwed() < bookedBefore) workoutYieldClaimsThatPaid++;
        } catch {}
        try auction.sweepFreeBalanceToInsurance() {} catch {}
    }

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

    // ── views the invariants need ────────────────────────────────────────────

    /// @dev Restates each exit's precondition from the *spec*, not from the code, and
    ///      asks whether at least one holds. Deriving them independently is the whole
    ///      value: a checker that copied the implementation would agree with it by
    ///      construction and prove nothing.
    ///
    ///      The union has one hole in it, and finding out whether that hole is
    ///      reachable is the job. `liquidatable && bondCount == 0 && the auction is
    ///      still running` satisfies none of the three: `bid` refuses an empty lot,
    ///      `cancel` refuses a position that is still underwater, and expiry has not
    ///      opened yet. It *should* be unreachable, because a borrower cannot withdraw
    ///      collateral while breaching LTV and nothing else empties a position - but
    ///      "should be" is an argument, and this is a test.
    function hasReachableExit(uint256 auctionId) external view returns (bool) {
        (address borrower, uint96 startedAt,, bool settled,,,,) = auction.auctions(auctionId);
        if (borrower == address(0) || settled) return true; // not live: nothing to strand

        // expireToWorkout: needs only that the clock has run out.
        if (block.timestamp >= uint256(startedAt) + Config.AUCTION_DURATION) return true;

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

    AuctionHandler internal handler;
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

        handler =
            new AuctionHandler(vault, credit, auction, oracle, usdc, bond, pool, keeper, harvester, actors);
        targetContract(address(handler));
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
    function invariant_auctionHoldsNothingButUnclaimedRewards() public view {
        assertGe(
            usdc.balanceOf(address(auction)),
            auction.totalUnclaimedRewards(),
            "rewards must always be backed"
        );
        assertLe(
            usdc.balanceOf(address(auction)),
            auction.totalUnclaimedRewards() + auction.totalWorkoutYieldOwed(),
            "and nothing else may accumulate"
        );
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
    function invariant_everyBookedWorkoutYieldIsBackedByMoneyThatExists() public view {
        uint256 held = usdc.balanceOf(address(auction));
        uint256 rewards = auction.totalUnclaimedRewards();
        uint256 free = held > rewards ? held - rewards : 0;
        uint256 backing =
            free + credit.claimableOf(address(auction)) + credit.pendingYieldOf(address(auction));
        assertGe(
            backing,
            auction.totalWorkoutYieldOwed(),
            "the auction booked workout yield it cannot pay"
        );
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
        uint256 escrowed;
        uint256 owed;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            escrowed += credit.bountyEscrowOf(handler.actors(i));
            owed += credit.bountyOwedTo(handler.actors(i));
        }
        owed += credit.bountyOwedTo(handler.keeper());

        uint256 parked;
        for (uint256 i = 0; i < handler.startedCount(); i++) {
            (,, uint256 amount) = credit.parkedBountyOf(handler.startedAuctions(i));
            parked += amount;
        }

        assertEq(credit.totalBountyEscrowed(), escrowed, "escrow counter must equal its map");
        assertEq(credit.totalBountyParked(), parked, "park counter must equal the live parks");
        assertEq(credit.totalBountyOwed(), owed, "owed counter must equal its map");
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
        assertEq(credit.totalBountyParked(), 0, "a park outlived every auction that could spend it");
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
        assertGe(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
                + credit.totalOwedToSources() + credit.insuranceFund() + credit.totalBountyEscrowed() + credit.totalBountyParked()
                + credit.totalBountyOwed(),
            "balance must cover every claim on it"
        );
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

        // And the flush, which is where finding 1 lived. Before the fix the pool kept the whole
        // 400.000000 on its own book while every manager-side term went to zero.
        usdc.setBlocked(address(pool), false);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        vm.prank(makeAddr("stranger")); // permissionless
        credit.flushPrincipalTo(address(pool));
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, loan, "the money must go home");
        assertEq(pool.outstandingPrincipal(), 0, "and the pool must stop counting it");
        invariant_theBooksAgreeOnWhatIsOwed();

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
    ///      **So the vacuity guard is deliberately split in two, and neither half is a campaign
    ///      floor.** This test proves every transition is reachable at all;
    ///      `invariant_theHandlerNeverDropsAFrame` proves the fuzzer is not silently discarding
    ///      the ones it reaches. The second is the half this file did not have, and it is the half
    ///      that mattered - a suite can pass a reachability tripwire and still fuzz nothing, which
    ///      is precisely what happened here for three audit rounds.
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
        handler.passTime(Config.AUCTION_DURATION + 1);
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
        handler.deliverYield(500e6);
        assertEq(handler.yieldEpochsDistributed(), 1, "an epoch must reach the accumulator");
        handler.passTime(3 days);

        handler.recoverStrandedClaim();
        assertGt(handler.usdcPushedToTheAuction(), 0, "claimSurplusFor must actually push the auction's claim");
        assertGt(handler.freeBalanceSweepsThatMoved(), 0, "and the free-balance sweep must actually move it");

        // A second epoch, because the pair above drained the first one. The live manager's own
        // claim route is a different call with a different failure mode, so it gets its own money.
        handler.deliverYield(500e6);
        handler.passTime(3 days);
        handler.sweepWorkoutYield();
        assertGt(handler.workoutYieldSweepsThatMoved(), 0, "the workout-yield sweep must actually fund insurance");

        handler.workoutSettle(2, 100e6);
        assertEq(handler.recoveriesPaid(), 1, "recoveries must be payable");

        // `passTime` is capped at three days a call, so the 14-day recognition window
        // takes a few of them - which is the point of the cap: a fuzzer must be able to
        // reach the forced close without one lucky jump doing all the work.
        for (uint256 i = 0; i < 5; i++) {
            handler.passTime(3 days);
        }
        handler.closeWorkout(2);
        assertEq(handler.workoutsClosed(), 1, "losses must be recognisable");

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
        handler.passTime(Config.AUCTION_DURATION + 1);
        handler.expire(3);
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
        handler.closeWorkout(3);
        assertEq(handler.workoutsClosed(), 2, "the clean close must land");
        assertEq(handler.cleanClosesThatBookedYield(), 1, "and it must book the borrower's yield");
        assertGt(auction.totalWorkoutYieldOwed(), 0, "and the running total must be real money");

        // And the drain. Without it the figure only ever grows and an error on the way out is never
        // reached - the same argument `claimBounty` carries.
        uint256 borrowerBefore = usdc.balanceOf(handler.actors(1));
        handler.claimWorkoutYield(3);
        assertEq(handler.workoutYieldClaimsThatPaid(), 1, "the borrower must be able to collect it");
        assertGt(usdc.balanceOf(handler.actors(1)), borrowerBefore, "and the USDC must actually arrive");
    }
}
