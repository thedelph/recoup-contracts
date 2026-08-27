// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title What an entry costs when a stranger picks the block, executed rather than argued
/// @notice Audit round 23 finding 3, converged on independently by two agents. PR #247 made the
///         ENTRY price a function of `pendingYield` and `yieldRate` - `_entryAssets()` adds a live
///         stream's projected tail back on, so a newcomer pays for value the delivered cohort is
///         owed rather than diluting it. That was the right change. What came with it was a
///         steppable entry quote and, unlike the exits, no door through which a caller could
///         decline the step. Round 20 had already put that door on `withdraw` and `redeem`; this
///         file is the entry-side mirror and the evidence for it.
///
/// @dev **The four things measured here, and which is which.**
///
///      **1. The bound that was missing, and now is not.** A depositor reads `previewDeposit`,
///      sends `deposit`, and a stranger's permissionless `flushLenderYield` lands in between. The
///      shares they are minted fall and nothing in the ERC-4626 surface let them decline it. The
///      EIP-5143 overloads `deposit(uint256,address,uint256)` and `mint(uint256,address,uint256)`
///      are what fixes it, and the tests below hold the bound in both directions: it refuses the
///      front-run, and it does not refuse an honest entry.
///
///      **2. The size of what remains after PR #259, leg by leg.** #259 stopped the two non-epoch
///      legs rating their money over the epoch accrual clock. That changed the WINDOW an entrant
///      then waits out; it changed no AMOUNT. MEASURED here, on a 10,000.000000 book with a
///      5,000.000000 entry: all three writers of the entry basis still step the quote - 909 bps for
///      a 1,000.000000 epoch, 909 bps for the same principal surplus, 9,090 bps for a recovery ten
///      times the book - and only the epoch leg still stretches the window, 15,552,000 seconds
///      against the 432,000-second floor the other two now get. So the bound is sized against the
///      STEP, and what #259 bounded is the consequence rather than the exposure.
///
///      **Every figure in the paragraph above is a POOL-BOUNDARY measurement, and calling them
///      reachable was a mistake this file used to make.** All three helpers here prank the pool's
///      own privileged counterparty, so what they measure is what the pool accepts from its manager
///      or its harvester, not what a stranger can place. `EntryStepReachability.t.sol` drives the
///      same three legs from an address with no role, through the real upstream contracts, and two
///      of the three figures move: a reachable recovery is clamped to `w.writtenDown` by
///      `LiquidationAuction.workoutSettleAfterClose`, and the principal-surplus step was not
///      reachable at all. Read the numbers here as boundary behaviour and that file for exposure.
///
///      **3. Round-23 finding 14, answered by measurement rather than by argument, because the
///      open findings require anyone shipping this bound to say whether it also closes it. IT DOES
///      NOT.** Finding 14 is about how LONG an entrant sits at the #247 discount. The entry quote
///      is a function of the SIZE of the unreleased pot and not of the window it unwinds over, so
///      the same 1,000.000000 epoch delivered over five days and over a 180-day drought mints the
///      identical share count and passes the identical `minShares`. There is no calldata field on
///      either door that can express an opinion about the window, and adding one would be a
///      different fix. `test_theEntryBoundCannotSeeTheStretchFinding14IsAbout` executes both
///      halves on one fixture: 4,545,454,545,495 shares minted either way against the same bound,
///      and a five-day exit that forfeits 1 wei under the floor and 303.819445 USDC under the
///      drought, out of a 5,000.000000 entry.
///
///      **4. What round 23 counted, inverted rather than deleted.** Its probe
///      `test_A23_03_theEntryDoorsCarryNoBound` asserted the two selectors were ABSENT, from the
///      type rather than from the diff, with a positive and a negative control. That assertion is
///      now false, which is the point, so it is turned round here with its controls intact. The
///      original round-23 probe is left as it was: an artefact recording a defect, not a test of
///      this tree.
///
///      **Neuter verification, MEASURED, so that "these tests have teeth" is a number and not a
///      claim.** Each is this file, unchanged, against one changed thing in `src/LenderPool.sol`.
///      Every one of the eleven tests below is turned red by at least one of them:
///
///        A. the two comparisons deleted, so both new doors accept anything: **6 of 11 fail** -
///           the two front-run tests, the fuzz, and all three sizing tests, each of which ends by
///           holding the bound to the step it just measured. The honest-path test, the finding-14
///           test, the presence probe, the cap-ordering test and the return-value test pass, all
///           correctly: none of them is about the bound firing.
///        B. both comparisons inverted, so both doors always revert: **9 of 11 fail** - the
///           honest-path, finding-14 and return-value tests join. This is the direction that
///           catches a bound written as a refusal, which is what audit round 10 shipped on the
///           exit side and what rounds 10 and 11 overturned.
///        C. `_rateStream`'s non-epoch branch put back on the epoch clock, PR #259 undone:
///           **2 of 11 fail** - exactly the recovery and principal-surplus sizing tests, each on
///           its window, 15,552,000 against 432,000. Nothing else moves, which is the point: #259
///           changed windows and no amounts.
///        D. `_rateStream`'s epoch branch floored at `YIELD_STREAM_DURATION` instead of rated over
///           its accrual window, which is roughly what closing finding 14 in general would have to
///           look like: **2 of 11 fail** - the epoch sizing test and the finding-14 test, both on
///           the premise that the drought still stretches. Those are the two assertions that would
///           tell a later reader finding 14 had moved.
///        E. `src/LenderPool.sol` reverted wholesale to the round-23 state: **the file does not
///           compile**, because `SharesBelowMinimum` does not exist there. That is the neuter for
///           the presence probe, and it is why the probe is worth keeping even though it looks
///           tautological from inside a tree that has the doors.
///        F. the `DepositCapExceeded` check deleted from the two-argument doors: **1 of 11 fails**
///           - the cap-ordering test, which then sees OpenZeppelin's `ERC4626ExceededMaxDeposit`
///           instead. That test is a guard on which revert arrives first and this is what gives it
///           teeth.
contract LenderPoolEntryPricingTest is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal creditManager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant EPOCH = 1_000e6;
    uint256 internal constant ENTRY = 5_000e6;

    /// @dev The epoch drought round-22 finding 11 and round-23 finding 14 are both filed against,
    ///      and the state the Base Sepolia pool is in today: no epoch has ever been delivered, so
    ///      `lastYieldDistributeAt` is still the constructor stamp.
    uint256 internal constant DROUGHT = 180 days;

    function setUp() public {
        // A non-zero start, so the constructor's `lastYieldDistributeAt` stamp is not block zero
        // and nothing below is accidentally testing the genesis edge.
        vm.warp(1_800_000_000);

        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(harvester);
        // Deliberately out of the way. The deposit cap is a real gate and it has its own tests;
        // here it would only decide which of two reverts arrives first, which is the subject of
        // exactly one test below and a confound in all the others.
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
        vm.stopPrank();

        for (uint256 i = 0; i < 2; i++) {
            address who = [alice, bob][i];
            usdc.mint(who, 1_000_000e6);
            vm.prank(who);
            usdc.approve(address(pool), type(uint256).max);
        }

        vm.prank(alice);
        pool.deposit(SEED, alice);
    }

    // -- fixture helpers ------------------------------------------------------

    /// @dev The epoch leg, reached from `EpochHarvester.flushLenderYield()`, which needs no
    ///      authority. It is the only leg that owns the accrual clock.
    function _epoch(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(pool), amount);
        pool.distributeYield(amount);
        vm.stopPrank();
    }

    /// @dev The pool-side effect of `LiquidationAuction.workoutSettleAfterClose()` ->
    ///      `CreditManager.recoverWrittenDownLoss` -> `LenderPool.recoverLoss`. Anyone may fund
    ///      that auction exit, so this leg is permissionlessly reachable too.
    function _recover(uint256 amount) internal {
        usdc.mint(creditManager, amount);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.recoverLoss(amount);
        vm.stopPrank();
    }

    /// @dev The pool-side effect of `CreditManager.settlePrincipal()`. With nothing lent, the
    ///      whole repayment is surplus and takes the streaming branch.
    function _repaySurplus(uint256 amount) internal {
        usdc.mint(creditManager, amount);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.repayPrincipal(amount);
        vm.stopPrank();
    }

    function _window() internal view returns (uint256) {
        uint256 endsAt = pool.yieldStreamEndsAt();
        return endsAt > block.timestamp ? endsAt - block.timestamp : 0;
    }

    function _exit(address who, uint256 shares) internal returns (uint256) {
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        pool.redeem(shares, who, who);
        return usdc.balanceOf(who) - before;
    }

    /// @dev True when the selector is implemented. A contract with no fallback reverts with zero
    ///      returndata for an unknown selector; every implemented path here either succeeds or
    ///      reverts with a non-empty ABI-encoded error. Copied in shape from round 23's own probe
    ///      so that the inversion below is measured the same way the finding was.
    function _present(bytes memory payload) private returns (bool) {
        (bool ok, bytes memory ret) = address(pool).call(payload);
        if (ok) return true;
        return ret.length != 0;
    }

    // -- 1. the bound refuses the front-run, and refuses nothing else ---------

    /// @notice TEETH. The trace round 23 measured: the victim's own quote, a stranger's
    ///         permissionless delivery in front of it, and a mint that comes up short. The bounded
    ///         door declines it; the unbounded door, same block and same money, does not.
    function test_aBoundedDepositRefusesTheFrontRunTheUnboundedDoorAccepts() public {
        uint256 quoted = pool.previewDeposit(ENTRY);

        _epoch(EPOCH);
        assertEq(pool.unreleasedYield(), EPOCH, "fixture: the whole pot must still be unreleased");

        uint256 requoted = pool.previewDeposit(ENTRY);
        assertLt(requoted, quoted, "no step: the delivery did not move the entry quote");
        emit log_named_uint("quoted before the delivery", quoted);
        emit log_named_uint("quote after the delivery  ", requoted);
        emit log_named_uint("shortfall bps of the quote", ((quoted - requoted) * 10_000) / quoted);

        uint256 cashBefore = usdc.balanceOf(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.SharesBelowMinimum.selector, requoted, quoted));
        vm.prank(bob);
        pool.deposit(ENTRY, bob, quoted);
        assertEq(pool.balanceOf(bob), 0, "the refused deposit minted shares");
        assertEq(usdc.balanceOf(bob), cashBefore, "the refused deposit took money");

        // The unbounded door, same block, same money: it accepts the step without a word.
        vm.prank(bob);
        uint256 minted = pool.deposit(ENTRY, bob);
        assertEq(minted, requoted, "the unbounded door minted something other than the re-quote");
        assertLt(minted, quoted, "the unbounded door did not take the step");
    }

    /// @notice TEETH. The exact-share half. The step runs the other way here - a fixed share count
    ///         costs MORE after the delivery - so the bound is a maximum and the comparison is
    ///         inverted. A bound written the same way round as the deposit's would be inert.
    function test_aBoundedMintRefusesAnAssetCostAboveTheQuote() public {
        // Derived from the deposit rather than written down, so it is a share count this fixture
        // can afford on both sides of the delivery.
        uint256 shares = pool.previewDeposit(ENTRY);
        uint256 quotedCost = pool.previewMint(shares);

        _epoch(EPOCH);

        uint256 nowCost = pool.previewMint(shares);
        assertGt(nowCost, quotedCost, "no step: the delivery did not move the cost of a fixed share count");
        emit log_named_uint("cost quoted before the delivery", quotedCost);
        emit log_named_uint("cost after the delivery        ", nowCost);
        emit log_named_uint("excess bps of the quote        ", ((nowCost - quotedCost) * 10_000) / quotedCost);

        uint256 cashBefore = usdc.balanceOf(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsAboveMaximum.selector, nowCost, quotedCost));
        vm.prank(bob);
        pool.mint(shares, bob, quotedCost);
        assertEq(pool.balanceOf(bob), 0, "the refused mint minted shares");
        assertEq(usdc.balanceOf(bob), cashBefore, "the refused mint took money");

        vm.prank(bob);
        uint256 paid = pool.mint(shares, bob);
        assertEq(paid, nowCost, "the unbounded door paid something other than the re-quote");
        assertEq(cashBefore - usdc.balanceOf(bob), nowCost, "the unbounded door moved a different amount");
    }

    /// @notice A bound the book can meet is not a refusal. Both doors go through untouched.
    /// @dev The other direction of the same guard. A check that always reverted would pass both
    ///      tests above and would have made the pool impossible to enter through the new doors.
    function test_aBoundedEntryAtTheCurrentPriceGoesStraightThrough() public {
        _epoch(EPOCH);

        uint256 quote = pool.previewDeposit(ENTRY);
        vm.prank(bob);
        uint256 minted = pool.deposit(ENTRY, bob, quote);
        assertEq(minted, quote, "the bounded deposit minted something other than the quote");

        uint256 shares = 1_000_000_000;
        uint256 cost = pool.previewMint(shares);
        uint256 cashBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.mint(shares, alice, cost);
        assertEq(paid, cost, "the bounded mint paid something other than the quote");
        assertEq(cashBefore - usdc.balanceOf(alice), cost, "the bounded mint moved a different amount");
    }

    /// @notice Any bound at or below what the pool would mint is accepted; anything above is not.
    /// @dev Fuzzed over the delivery as well as over the bound, so the property is about the guard
    ///      and not about one book. Unseeded, like every campaign in this repo: `foundry.toml`
    ///      pins no seed and CI runs a bare `forge test`, so a green run here is 256 draws from
    ///      whatever seed that invocation chose and not a proof over the space.
    function testFuzz_anEntryBoundIsExactlyTheQuoteAndNothingElse(uint96 epochRaw, uint96 boundRaw) public {
        uint256 epoch = uint256(epochRaw) % (pool.totalAssets() + 1);
        if (epoch != 0) _epoch(epoch);

        uint256 quote = pool.previewDeposit(ENTRY);
        assertGt(quote, 0, "fixture: the quote must be non-zero or the bound says nothing");
        uint256 bound = uint256(boundRaw) % (2 * quote);

        if (bound > quote) {
            vm.expectRevert(abi.encodeWithSelector(LenderPool.SharesBelowMinimum.selector, quote, bound));
            vm.prank(bob);
            pool.deposit(ENTRY, bob, bound);
            assertEq(pool.balanceOf(bob), 0, "a refused deposit minted shares");
        } else {
            vm.prank(bob);
            uint256 minted = pool.deposit(ENTRY, bob, bound);
            assertEq(minted, quote, "an accepted bound changed what was minted");
        }
    }

    /// @notice The cap still speaks first. A bound cannot turn a capped deposit into a bound
    ///         failure, because the inner door runs before the comparison.
    /// @dev Ordering, not arithmetic: `DepositCapExceeded` is the honest answer to "you cannot put
    ///      this much in", and `SharesBelowMinimum` would tell an integrator to retry with a lower
    ///      bound, which would never work.
    function test_theCapStillSpeaksFirstThroughTheBoundedDoors() public {
        vm.prank(admin);
        pool.setDepositCap(SEED + ENTRY / 2);

        uint256 remaining = pool.maxDeposit(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.DepositCapExceeded.selector, ENTRY, remaining));
        vm.prank(bob);
        pool.deposit(ENTRY, bob, 0);

        uint256 remainingShares = pool.maxMint(bob);
        uint256 tooMany = remainingShares + 1;
        vm.expectRevert(abi.encodeWithSelector(LenderPool.DepositCapExceeded.selector, tooMany, remainingShares));
        vm.prank(bob);
        pool.mint(tooMany, bob, type(uint256).max);
    }

    // -- 2. the size of what remains after PR #259 ----------------------------

    /// @notice SIZING. The epoch leg after a drought: it steps the quote AND stretches the window.
    ///         This is the one case #259 deliberately left, and it is what "sized so that only an
    ///         epoch drought feeds the stretch" means when it is executed.
    function test_sizing_theEpochLegStepsTheQuoteAndStillStretchesTheWindow() public {
        skip(DROUGHT);
        uint256 before = pool.previewDeposit(ENTRY);

        _epoch(EPOCH);

        uint256 after_ = pool.previewDeposit(ENTRY);
        assertLt(after_, before, "the epoch leg no longer steps the entry quote");
        assertEq(_window(), DROUGHT, "the epoch leg must still be rated over its own accrual window");
        emit log_named_uint("epoch leg: shortfall bps ", ((before - after_) * 10_000) / before);
        emit log_named_uint("epoch leg: window seconds", _window());

        // And the bound refuses it, which is the whole point of sizing it.
        vm.expectRevert(abi.encodeWithSelector(LenderPool.SharesBelowMinimum.selector, after_, before));
        vm.prank(bob);
        pool.deposit(ENTRY, bob, before);
    }

    /// @notice SIZING, **AT THE POOL BOUNDARY AND NOT END TO END. The name says so because this
    ///         figure was quoted as an end-to-end step once already.** `recoverLoss` really does
    ///         carry no `YieldExceedsCapital` guard, unlike `distributeYield`, and deliberately so,
    ///         so its own manager may send it any amount - which is what this measures. It is
    ///         **not** how large a step a stranger can put through the door.
    /// @dev The only path into `recoverLoss` is `CreditManager.recoverWrittenDownLoss`, itself
    ///      reachable only from `LiquidationAuction.workoutSettleAfterClose`, which clamps
    ///      `take = min(amountUsdc, w.writtenDown)` and makes the caller fund it out of their own
    ///      pocket. The REACHABLE step is therefore bounded by the loss actually written down on
    ///      that workout. Executed in `EntryStepReachability.t.sol`, which is where the end-to-end
    ///      figure lives. Read the 9,090 bps below as "what the pool accepts from its own manager"
    ///      and nothing wider.
    function test_sizing_atThePoolBoundaryARecoveryStepIsUncappedButItsWindowIsTheFloor() public {
        skip(DROUGHT);
        uint256 before = pool.previewDeposit(ENTRY);

        // Ten times the pool's entire book. `distributeYield` would revert `YieldExceedsCapital`.
        uint256 oversized = 10 * pool.totalAssets();
        _recover(oversized);

        uint256 after_ = pool.previewDeposit(ENTRY);
        assertLt(after_, before / 5, "the pool refused an amount above its own book after all");
        assertEq(_window(), Config.YIELD_STREAM_DURATION, "a recovery must be rated over its own floor");
        assertEq(pool.lastYieldDistributeAt(), 1_800_000_000, "a recovery must not touch the accrual clock");
        emit log_named_uint("recovery: amount            ", oversized);
        emit log_named_uint("recovery: shortfall bps     ", ((before - after_) * 10_000) / before);
        emit log_named_uint("recovery: window seconds    ", _window());

        vm.expectRevert(abi.encodeWithSelector(LenderPool.SharesBelowMinimum.selector, after_, before));
        vm.prank(bob);
        pool.deposit(ENTRY, bob, before);
    }

    /// @notice SIZING, **AT THE POOL BOUNDARY, and the same caveat as the test above.** The third
    ///         leg: a surplus arriving on `repayPrincipal` streams, so it steps the entry quote,
    ///         and it is rated over the floor rather than over somebody else's clock.
    /// @dev **This one is not merely a boundary figure, it is a step that was NOT reachable at all
    ///      in any state `EntryStepReachability.t.sol` could construct**, and an earlier report
    ///      quoted its 909 bps as though a stranger could place it. `CreditManager.settlePrincipal`
    ///      is indeed permissionless, but an ordinary settlement is exactly neutral to
    ///      `totalAssets()` - the cash in equals the principal off - and the surplus branch needs
    ///      `pendingPrincipal > outstandingPrincipal`, which the identity
    ///      `outstandingPrincipal == pendingPrincipal + totalDebt` forbids. Kept, because the
    ///      branch is live code that a future wiring could reach, and because a bound is worth
    ///      having in front of code that is one pointer change away from firing.
    function test_sizing_atThePoolBoundaryAPrincipalSurplusStepsTheQuoteButNotTheWindow() public {
        skip(DROUGHT);
        uint256 before = pool.previewDeposit(ENTRY);

        _repaySurplus(EPOCH);

        uint256 after_ = pool.previewDeposit(ENTRY);
        assertLt(after_, before, "the principal surplus no longer steps the entry quote");
        assertEq(_window(), Config.YIELD_STREAM_DURATION, "a surplus must be rated over its own floor");
        emit log_named_uint("surplus: shortfall bps ", ((before - after_) * 10_000) / before);
        emit log_named_uint("surplus: window seconds", _window());

        vm.expectRevert(abi.encodeWithSelector(LenderPool.SharesBelowMinimum.selector, after_, before));
        vm.prank(bob);
        pool.deposit(ENTRY, bob, before);
    }

    // -- 3. round-23 finding 14, which this does NOT close --------------------

    /// @notice **THE FINDING-14 ANSWER, MEASURED.** The round-24 open findings require anyone
    ///         shipping an entry-side bound to say whether it also closes finding 14, because both
    ///         live in this door. It does not, and this is why.
    /// @dev Two runs of one fixture differing in exactly one thing: how long the epoch clock has
    ///      been stale when an identical 1,000.000000 epoch is delivered. Rule 1 rates the epoch
    ///      over its own accrual window, so the same pot streams over five days in one and over
    ///      180 days in the other.
    ///
    ///      `_entryAssets()` adds back `unreleasedYield()`, which immediately after a delivery is
    ///      the whole pot in both cases. The quote is therefore identical, the minted share count
    ///      is identical, and **the SAME `minShares` value is accepted by both**. A bound on the
    ///      shares cannot express an opinion about the window, and there is no calldata field on
    ///      either door that could. Closing finding 14 means a duration bound or a shorter epoch
    ///      window; it is a different change and this is not it.
    ///
    ///      What the window costs is measured on the other side: an identical five-day exit is
    ///      free under the floor and forfeits real principal under the drought.
    function test_theEntryBoundCannotSeeTheStretchFinding14IsAbout() public {
        uint256 snap = vm.snapshotState();

        // A. the epoch clock is exactly current, so rule 1 rates this epoch over the floor.
        skip(Config.YIELD_STREAM_DURATION);
        _epoch(EPOCH);
        uint256 shortWindow = _window();
        uint256 shortQuote = pool.previewDeposit(ENTRY);
        vm.prank(bob);
        uint256 shortShares = pool.deposit(ENTRY, bob, shortQuote);
        skip(Config.YIELD_STREAM_DURATION);
        uint256 shortRealised = _exit(bob, shortShares);

        vm.revertToState(snap);

        // B. identical in every respect except that no epoch has landed for 180 days. The SAME
        //    bound the control accepted is passed here, unchanged, and it is accepted here too.
        skip(DROUGHT);
        _epoch(EPOCH);
        uint256 longWindow = _window();
        uint256 longQuote = pool.previewDeposit(ENTRY);
        vm.prank(bob);
        uint256 longShares = pool.deposit(ENTRY, bob, shortQuote);
        skip(Config.YIELD_STREAM_DURATION);
        uint256 longRealised = _exit(bob, longShares);

        // Premises, so a later reader can see which half moved if this ever changes.
        assertEq(shortWindow, Config.YIELD_STREAM_DURATION, "premise: the control must be the floor");
        assertEq(longWindow, DROUGHT, "premise: the epoch leg must still stretch to the drought");

        // THE ANSWER. The quote is blind to the window, so no `minShares` tells the two apart.
        assertEq(longQuote, shortQuote, "the entry quote saw the window after all");
        assertEq(longShares, shortShares, "the two entries minted different share counts");

        // And what the window costs, which is the thing the bound cannot refuse.
        assertLe(ENTRY - shortRealised, 1_000, "control: a five-day exit under the floor is near-free");
        assertGt(ENTRY - longRealised, 100e6, "the drought exit must forfeit real principal");
        emit log_named_uint("window, control (seconds)", shortWindow);
        emit log_named_uint("window, drought (seconds)", longWindow);
        emit log_named_uint("shares minted, control   ", shortShares);
        emit log_named_uint("shares minted, drought   ", longShares);
        emit log_named_uint("five-day forfeit, control", ENTRY - shortRealised);
        emit log_named_uint("five-day forfeit, drought", ENTRY - longRealised);
    }

    // -- 4. the surface round 23 counted, inverted -----------------------------

    /// @notice Round 23 counted the entry doors as absent from the TYPE rather than from the diff,
    ///         with a positive and a negative control. Its assertion is now false, so it is turned
    ///         round here rather than dropped: a test that asserts a defect has to be inverted when
    ///         the defect goes, or it becomes a test that forbids the fix.
    /// @dev The probe is a real `call` with correctly encoded arguments. A missing selector reverts
    ///      with EMPTY returndata; a present one either succeeds or reverts with a decodable
    ///      payload. Both controls are asserted so the positive cannot pass for the wrong reason.
    function test_bothEntryDoorsArePresentAndCarryTheEip5143Signatures() public {
        assertTrue(
            _present(abi.encodeWithSignature("deposit(uint256,address,uint256)", uint256(1), bob, uint256(0))),
            "the bounded deposit is missing"
        );
        assertTrue(
            _present(abi.encodeWithSignature("mint(uint256,address,uint256)", uint256(1), bob, type(uint256).max)),
            "the bounded mint is missing"
        );

        // Positive controls: round 20's exit pair is untouched by this change.
        assertTrue(
            _present(
                abi.encodeWithSignature("redeem(uint256,address,address,uint256)", uint256(0), bob, bob, uint256(0))
            ),
            "positive control: the bounded redeem is missing"
        );
        assertTrue(
            _present(
                abi.encodeWithSignature(
                    "withdraw(uint256,address,address,uint256)", uint256(0), bob, bob, type(uint256).max
                )
            ),
            "positive control: the bounded withdraw is missing"
        );

        // Negative control: a selector that certainly does not exist must read as absent.
        assertFalse(_present(abi.encodeWithSignature("definitelyNotAFunctionOnThisPool()")), "negative control failed");
    }

    /// @notice The two new doors return what the two-argument doors return, so an integrator
    ///         reading the bounded variant's return value is reading the same number.
    function test_theBoundedDoorsReturnWhatTheUnboundedDoorsReturn() public {
        uint256 snap = vm.snapshotState();

        vm.prank(bob);
        uint256 plainShares = pool.deposit(ENTRY, bob);
        vm.prank(alice);
        uint256 plainCost = pool.mint(1_000_000_000, alice);

        vm.revertToState(snap);

        vm.prank(bob);
        uint256 boundedShares = pool.deposit(ENTRY, bob, 0);
        vm.prank(alice);
        uint256 boundedCost = pool.mint(1_000_000_000, alice, type(uint256).max);

        assertEq(boundedShares, plainShares, "the bounded deposit returned a different share count");
        assertEq(boundedCost, plainCost, "the bounded mint returned a different cost");
    }
}
