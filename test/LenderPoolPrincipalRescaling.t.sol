// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev The renormalisation ceiling, lowered so a fuzzer can reach a shift.
///
///      **The drift bound `_renormaliseUnits` states is a claim about the rule, and at the shipped
///      `2**128` ceiling no fuzz sequence of ordinary deposits can make the rule fire even once.**
///      A fuzz that cannot reach the branch measures its own reach and reports a bound nobody
///      earned. Round 23's design pass measured its drift on a patched copy of `src/LenderPool.sol`
///      which it then deleted; the seam keeps the same measurement inside the tree, where it runs on
///      every CI job and rots loudly rather than silently.
///
///      Nothing but the ceiling is overridden, and `test_thePrincipalUnitCeilingIsTheShippedValue`
///      pins what the real pool uses.
contract LowCeilingPool is LenderPool {
    uint256 private _ceiling = 1 << 40;

    constructor(IERC20 usdc_, address initialOwner) LenderPool(usdc_, initialOwner) {}

    /// @dev Movable, so a trace can arm the next issuance to renormalise at a chosen moment rather
    ///      than having to steer the whole pool into the ceiling. Some of the states worth looking
    ///      at - a shift landing between a queue request and its partial fill - are otherwise
    ///      reachable only by a fixture that has to fight the deposit cap and the queue's liquidity
    ///      holdback at the same time.
    function setCeiling(uint256 ceiling) external {
        _ceiling = ceiling;
    }

    function principalUnitCeiling() public view override returns (uint256) {
        return _ceiling;
    }
}

/// @notice Round-22 finding 3 and round-23 findings 6 and 7: the principal-unit basis, its loss
///         debit, and the bound on the quotient the two of them share.
///
/// @dev **These are two halves of one mechanism and they had to be fixed as a pair. Re-derive both
///      before changing anything this file asserts.**
///
///      The mechanism. `netDeposits` (**N**) is asset-denominated and is the only input to
///      `maxDeposit`. `totalPrincipalUnits` (**U**) is dimensionless. A deposit is issued at
///      `ceil(assets * U / N)`, so **q = U / N** is the price of admission. A loss used to lower N
///      by the whole absorbed amount and leave U alone, which is the design working - later
///      depositors must not inherit an earlier loss - and is also the whole problem, because
///      nothing lowered q except `_reduceNetDeposits`'s total wipe.
///
///      **Finding 6** was that the wipe fired while the book was intact. Two lenders at
///      5,000.000000, an epoch of 10,000.000000 delivered and released, the first lender out at
///      9,999.999999, then an ordinary 5,000.000000 loss: `netDeposits` reached **zero** with
///      5,000.000001 still standing, `maxDeposit` handed back the whole 25,000.000000 cap, and the
///      refill left `totalAssets()` at 30,000.000001 against it. The control, one asset-wei
///      smaller, left the counter at 1 and the cap spent - nothing but the size of the loss
///      differed. And it repeated with **no further loss**, because each cohort's full exit wiped
///      the counter and re-gifted the cap to the next.
///
///      **Finding 7** was the other side of the same wipe. Nine loss-and-full-recovery cycles, in
///      which no lender was ever down a cent, drove q past `type(uint256).max`; `deposit` then
///      reverted `Panic(0x11)` out of `Math.mulDiv` while `maxDeposit` still advertised
///      24,999.999999 of room. OpenZeppelin 5.6.1 replaced `MathOverflowedMulDiv` with a bare
///      panic, so anyone triaging that from the selector looks for an unchecked `+` and does not
///      find one. On an immutable contract with no sweep that is the deposit door shut for good.
///
///      **Why the pair.** The obvious repair for 6 - stop wiping - deletes 7's only brake, and the
///      literal two-line version (deleting `totalPrincipalUnits = 0` and `++_principalGeneration`)
///      was MEASURED during design to fix nothing, brick at cycle 2, and make
///      `netDeposits == 0 && totalPrincipalUnits != 0` reachable so that `Math.mulDiv` divides by
///      zero: `Panic(0x11)` becomes `Panic(0x12)`, in **one** ordinary loss rather than nine
///      cycles. Round 23's own PoC proved that state unreachable on the shipped code and called the
///      predicate safe; it was safe **because of** the two lines that repair deletes.
///
///      What shipped instead, and only as a pair:
///
///      - **(A) a yield-first loss debit** in `socialiseLoss`. The counter falls to
///        `min(N, totalAssets() + unreleasedYield())`, so it reaches zero only when the assets have.
///        Alone this closes 6 and opens a crush-and-recover route to 7 on which q multiplies by
///        2.5e10 per cycle - **strictly worse than shipping nothing**, seven cycles against nine.
///      - **(B) lazy binary renormalisation** at `PRINCIPAL_UNIT_CEILING`. Every stored unit figure
///        carries the exponent it was written at and is read shifted, so one `O(1)` write divides
///        the aggregate, every holder and every queue entry by the same power of two. This bounds q
///        rather than rate-limiting it, which is the difference between a fix and a delay.
///
///      Three designs were refused during the same pass and are recorded here so nobody rebuilds
///      them: an index-based basis (Aave's index
///      **rises** and its scaled balances shrink; Recoup's markdown index falls and they grow, so
///      it is the shipped design with the reciprocal stored), a units-free pro-rata basis
///      (MEASURED to ratchet the counter up 2,222.222223 per rotation, which is finding 3's
///      original High through the front door), and a floor-triggered generation roll (buys cycles,
///      and cycles are not a bound on an immutable contract).
contract LenderPoolPrincipalRescalingTest is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal creditManager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint256 internal constant CEILING = 1 << 128;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);
        _wire(pool);
    }

    // ── fixture ──────────────────────────────────────────────────────────────

    function _wire(LenderPool target) internal {
        vm.startPrank(admin);
        target.setCreditManager(creditManager);
        target.setEpochHarvester(harvester);
        vm.stopPrank();

        address[4] memory lenders = [alice, bob, carol, dave];
        for (uint256 i = 0; i < lenders.length; i++) {
            usdc.mint(lenders[i], 10_000_000e6);
            vm.prank(lenders[i]);
            usdc.approve(address(target), type(uint256).max);
        }
    }

    /// @dev Tracks every account credited with units in the current generation, which is the `h`
    ///      the drift bound is written against. **It is NOT the number of accounts reading a
    ///      non-zero figure, and the fuzz found the difference on run 3**: a holder whose units have
    ///      floored all the way to zero still contributed its floor to the drift, so counting only
    ///      the visible holders reported `h = 1` against a real drift of 1 and failed a bound that
    ///      is true. Reset when a generation roll clears the ledger.
    mapping(address account => bool credited) internal _credited;
    uint256 internal _creditedHolders;

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        if (assets == 0) return 0;
        vm.prank(who);
        shares = pool.deposit(assets, who);
        _markCredited(who);
    }

    function _markCredited(address who) internal {
        if (_credited[who]) return;
        _credited[who] = true;
        ++_creditedHolders;
    }

    function _forgetCreditedHoldersIfTheGenerationRolled() internal {
        if (pool.totalPrincipalUnits() != 0) return;
        address[5] memory holders = [alice, bob, carol, dave, address(pool)];
        for (uint256 i = 0; i < holders.length; i++) {
            _credited[holders[i]] = false;
        }
        _creditedHolders = 0;
    }

    /// @dev Read every view into a local before any `vm.prank`: an external staticcall in argument
    ///      position spends the prank, and the revert it produces is a plausible protocol error
    ///      rather than a tooling one.
    function _lendAll() internal returns (uint256 lent) {
        lent = pool.available();
        if (lent == 0) return 0;
        vm.prank(creditManager);
        pool.lend(lent);
    }

    function _socialise(uint256 amount) internal returns (uint256 absorbed) {
        if (amount == 0) return 0;
        vm.prank(creditManager);
        return pool.socialiseLoss(amount);
    }

    function _recover(uint256 amount) internal {
        if (amount == 0) return;
        usdc.mint(creditManager, amount);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.recoverLoss(amount);
        vm.stopPrank();
    }

    function _distributeYield(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(pool), amount);
        pool.distributeYield(amount);
        vm.stopPrank();
    }

    /// @dev Finding 7's executed PoC, one cycle. Lend everything, destroy all but one asset-wei of
    ///      the counter, hand every cent straight back as a recovery so no lender is ever short,
    ///      and let the recovery stream finish. The counter ends at one and the units do not.
    function _counterCrushCycle() internal {
        _lendAll();
        uint256 counter = pool.netDeposits();
        uint256 exposure = pool.outstandingPrincipal();
        if (counter < 2 || exposure == 0) return;
        uint256 absorbed = _socialise(Math.min(counter - 1, exposure));
        _recover(absorbed);
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);
    }

    /// @dev The **other** route to finding 7, and the one the yield-first debit opens by itself.
    ///      Rather than crushing the counter, crush the lender **assets** to nothing, which forces
    ///      the counter down with them, then restore the assets through `recoverLoss` - booked as a
    ///      gain, which by design never restores the counter - and refill towards the cap.
    ///
    ///      One `socialiseLoss` cannot reach the book: `available()` withholds
    ///      `RESERVE_RATIO_BPS` of `totalAssets()`, so the first draft of this helper capped its
    ///      target at the current cycle's lend, crushed nothing, and reported a clean pass. It has
    ///      to lend and lose repeatedly until nothing more can be lent.
    function _crushAndRecoverCycle(uint256 refill) internal {
        uint256 crushed;
        for (uint256 i = 0; i < 64; i++) {
            _lendAll();
            uint256 exposure = pool.outstandingPrincipal();
            // **One asset-wei short, and the whole construction turns on it.** Taking the last wei
            // as well empties the pool, the clamp fires on merit, the generation rolls and the
            // quotient resets to one - which is the shipped contract's accidental brake and is
            // exactly the state this loop must not reach. Leaving a wei keeps the counter alive at
            // one, so the refill below is issued at a quotient of `U`, not of `U / N`.
            if (exposure < 2) break;
            crushed += _socialise(exposure - 1);
        }
        _recover(crushed);
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);

        _deposit(alice, Math.min(pool.maxDeposit(alice), refill));
    }

    /// @dev A cycle that grows the quotient **gently** - by a factor of sixteen - rather than by the
    ///      ten orders of magnitude a full crush produces.
    ///
    ///      **This exists because the shift size decides what is observable, which is not obvious
    ///      and cost a neuter to find.** A full crush leaves the counter at one asset-wei, so the
    ///      next refill multiplies the aggregate by about `1e10` and the renormalisation that
    ///      follows shifts by thirty-odd bits at once. Every stale holder then floors straight to
    ///      zero, having lost far less than one post-shift unit each - so the integer drift is
    ///      zero, and so is every per-holder rounding effect a test might want to look at. Taking
    ///      fifteen sixteenths and refilling it multiplies the aggregate by sixteen instead, which
    ///      crosses the ceiling in a two-bit shift and leaves stale holders holding real figures.
    ///
    ///      Sixteen rather than two, and the difference was MEASURED: at a factor of two the
    ///      deposit cap throttles the refill before the ceiling is reached, and the aggregate
    ///      converges on 1.805e11 - four bits short of `2**40` - however many cycles are run.
    function _gentleCrushCycle() internal {
        uint256 assets = pool.totalAssets();
        uint256 target = assets - assets / 16;
        uint256 crushed;
        for (uint256 i = 0; i < 8 && crushed < target; i++) {
            _lendAll();
            uint256 exposure = pool.outstandingPrincipal();
            if (exposure == 0) break;
            crushed += _socialise(Math.min(exposure, target - crushed));
        }
        _recover(crushed);
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);

        _deposit(alice, Math.min(pool.maxDeposit(alice), crushed));
    }

    /// @dev Sum of every holder's live units. The actor set is exhaustive for this fixture, and the
    ///      pool itself is a holder whenever a share is escrowed.
    function _sumHolderUnits() internal view returns (uint256 sum) {
        address[5] memory holders = [alice, bob, carol, dave, address(pool)];
        for (uint256 i = 0; i < holders.length; i++) {
            sum += pool.principalUnits(holders[i]);
        }
    }

    function _holdersWithUnits() internal view returns (uint256 count) {
        address[5] memory holders = [alice, bob, carol, dave, address(pool)];
        for (uint256 i = 0; i < holders.length; i++) {
            if (pool.principalUnits(holders[i]) != 0) ++count;
        }
    }

    // ── the ceiling itself ───────────────────────────────────────────────────

    /// @notice The production ceiling is the derived value, not whatever a harness overrides it to.
    function test_thePrincipalUnitCeilingIsTheShippedValue() public {
        assertEq(pool.principalUnitCeiling(), CEILING, "the shipped ceiling must be 2**128");
        assertEq(new LowCeilingPool(IERC20(address(usdc)), admin).principalUnitCeiling(), 1 << 40, "harness seam");
    }

    // ── finding 6: the loss debit ────────────────────────────────────────────

    /// @notice An ordinary loss no longer zeroes the cap counter while the book is intact.
    /// @dev The trace round 23 filed the finding on, re-run against the yield-first debit. The
    ///      NEUTER is `_reduceNetDeposits(absorbed)` back at `socialiseLoss`: with it restored this
    ///      test reports `netDeposits` 0, `maxDeposit` the full cap, and a post-refill counter
    ///      above it. It was run and it went red before this fix was believed.
    function test_A23_06_anOrdinaryLossNoLongerZeroesTheCounterWhileTheBookIsIntact() public {
        _deposit(alice, 5_000e6);
        _deposit(bob, 5_000e6);
        _lendAll();
        _distributeYield(10_000e6);
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);

        // Alice leaves at the raised price, which is what leaves the counter smaller than the book.
        uint256 redeemable = Math.min(pool.balanceOf(alice), pool.maxRedeem(alice));
        vm.prank(alice);
        pool.redeem(redeemable, alice, alice);

        uint256 counterBefore = pool.netDeposits();
        uint256 assetsBefore = pool.totalAssets();
        assertGt(assetsBefore, counterBefore, "fixture: the book must be larger than the counter");

        uint256 exposure = pool.outstandingPrincipal();
        uint256 absorbed = _socialise(Math.min(counterBefore, exposure));
        assertGt(absorbed, 0, "fixture: the loss must land");

        assertEq(
            pool.netDeposits(),
            Math.min(counterBefore, assetsBefore - absorbed),
            "the counter must fall to what the pool still holds, not by the whole loss"
        );
        assertEq(pool.netDeposits(), counterBefore, "the retained yield covered this loss in full");
        assertGt(pool.netDeposits(), 0, "an ordinary loss must not clear admitted principal");
        assertGt(pool.totalPrincipalUnits(), 0, "an ordinary loss must not roll the generation");
        assertLt(pool.maxDeposit(bob), pool.depositCap(), "the whole cap must not be handed back");

        // The consequence the finding was actually about. Refill to the advertised headroom and the
        // pool must not end up having admitted more than the cap allows.
        _deposit(carol, pool.maxDeposit(carol));
        assertLe(pool.netDeposits(), pool.depositCap(), "the refill crossed the deposit cap");
    }

    /// @notice CONTROL. When the assets really have gone, the clamp still fires and the generation
    ///         still rolls. The repair narrows the branch; it does not delete it.
    function test_A23_06_control_aLossThatTakesEverythingStillRollsTheGeneration() public {
        _deposit(alice, 10_000e6);

        for (uint256 i = 0; i < 32; i++) {
            _lendAll();
            uint256 exposure = pool.outstandingPrincipal();
            if (exposure == 0) break;
            _socialise(exposure);
        }

        assertEq(pool.totalAssets(), 0, "fixture: the write-off must reach every asset");
        assertEq(pool.netDeposits(), 0, "a genuinely total loss must still clear admitted principal");
        assertEq(pool.totalPrincipalUnits(), 0, "a genuinely total loss must still roll the generation");
        assertEq(pool.principalUnits(alice), 0, "old shares must carry no basis after a total loss");

        _deposit(bob, 1_000e6);
        assertEq(pool.netDeposits(), 1_000e6, "new principal must start at par");
        assertEq(pool.totalPrincipalUnits(), 1_000e6, "only the new generation may count");
    }

    /// @notice The one open question the design pass could not settle: `totalAssets()` is
    ///         time-varying, and the loss debit reads it.
    ///
    /// @dev **MEASURED, at five points across one yield stream, and the reading that shipped is
    ///      exactly invariant while the alternative moves by the whole undelivered tail.**
    ///
    ///      `_poolBalance()` subtracts `unreleasedYield()`, so `totalAssets()` alone grows through a
    ///      stream as delivered money is released. A loss timed at the head of a stream would then
    ///      see a **smaller** cushion, take a **larger** debit, and free more cap headroom than the
    ///      same loss timed at the tail - which is the loosening direction, and is the lever a
    ///      caller who picks the block would reach for. Adding `unreleasedYield()` back cancels the
    ///      term: delivered-but-unreleased yield is lender money and belongs in the cushion.
    ///
    ///      The assertion is written both ways round on purpose. Equality alone would also pass on
    ///      a fixture where the stream happened not to matter, so the alternative reading is
    ///      computed on the same states and asserted to **differ**. That is what makes the first
    ///      half a statement about the choice rather than about the fixture.
    function test_A23_06_theLossDebitIsIndependentOfWhereInAStreamTheLossLands() public {
        uint256[5] memory fractions = [uint256(0), 25, 50, 75, 100];
        uint256[5] memory shipped;
        uint256[5] memory alternative;

        for (uint256 i = 0; i < fractions.length; i++) {
            pool = new LenderPool(IERC20(address(usdc)), admin);
            _wire(pool);

            _deposit(alice, 10_000e6);
            _lendAll();
            _distributeYield(1_000e6);
            vm.warp(block.timestamp + (Config.YIELD_STREAM_DURATION * fractions[i]) / 100);

            uint256 counterBefore = pool.netDeposits();
            uint256 exposure = pool.outstandingPrincipal();
            _socialise(exposure);

            shipped[i] = pool.netDeposits();
            // What `min(N, totalAssets())` would have left, computed on the same post-loss state.
            alternative[i] = Math.min(counterBefore, pool.totalAssets());
        }

        for (uint256 i = 1; i < fractions.length; i++) {
            assertEq(shipped[i], shipped[0], "the shipped debit moved with the position in the stream");
        }

        assertLt(alternative[0], alternative[4], "control: the `totalAssets()`-only reading must vary");
        assertEq(
            alternative[4] - alternative[0],
            1_000e6,
            "control: it must vary by the whole delivered-but-unreleased tail"
        );
        assertEq(alternative[4], shipped[4], "at the end of a stream the two readings must agree");
        assertLt(alternative[0], shipped[0], "and at the head the alternative must be the looser one");
    }

    // ── finding 7: the bound on the quotient ─────────────────────────────────

    /// @notice Fifteen fully-recovered counter-crush cycles no longer brick the deposit door.
    /// @dev The executed finding-7 PoC, run half again as long as the nine cycles that bricked the
    ///      shipped contract. `deposit` reverted `Panic(0x11)` at cycle nine out of `Math.mulDiv`,
    ///      not out of the units addition - `totalPrincipalUnits` stood at 1.6666666783666667e73.
    ///      The assertion is that a real deposit still executes, because that is the harm.
    function test_A23_07_recoveredLossCyclesNoLongerBrickTheDepositDoor() public {
        _deposit(alice, 1_500e6);

        for (uint256 cycle = 0; cycle < 15; cycle++) {
            _counterCrushCycle();
            assertLt(pool.totalPrincipalUnits(), CEILING, "the aggregate left the ceiling during a counter crush");
            if (pool.maxDeposit(bob) >= 1_000e6) _deposit(bob, 1_000e6);
        }

        // The harm, stated as the harm: the door is still open.
        uint256 finalRoom = pool.maxDeposit(carol);
        assertGt(finalRoom, 0, "fifteen recovered cycles left no headroom to test the door with");
        vm.prank(carol);
        assertGt(pool.deposit(Math.min(finalRoom, 100e6), carol), 0, "the deposit door is shut");
    }

    /// @notice The route the yield-first debit opens on its own, and the one the ceiling closes.
    /// @dev **This is the falsifier that fired against the loss debit during design and is the
    ///      reason the two changes ship together.** With (A) alone the aggregate ran
    ///      2.5000e20, 6.2500e30, 1.5625e41 over the first three cycles - a clean multiplicative
    ///      regime at 2.5e10 per cycle, which reaches `type(uint256).max` in seven from a fresh
    ///      pool, against nine on the shipped code. With the ceiling in place the same construction
    ///      settles into a band and stays there.
    ///
    ///      `unitExponent` moving is asserted, not assumed. A test that only checked the aggregate
    ///      stayed under the ceiling would pass on a pool that never went near it, which is how a
    ///      bound gets confused with a fixture that cannot reach one.
    function test_A23_07_theCrushAndRecoverRouteIsBoundedByTheCeiling() public {
        _deposit(alice, 10_000e6);

        uint256 highWater;
        for (uint256 cycle = 0; cycle < 12; cycle++) {
            _crushAndRecoverCycle(10_000e6);
            uint256 total = pool.totalPrincipalUnits();
            if (total > highWater) highWater = total;
            assertLt(total, CEILING, "the aggregate left the ceiling on a crush-and-recover cycle");
        }

        assertGt(pool.unitExponent(), 0, "the construction never reached the ceiling, so it measured nothing");
        assertGt(highWater, CEILING >> 8, "the construction never came near the ceiling either");

        uint256 room = pool.maxDeposit(bob);
        assertGt(room, 0, "twelve crush-and-recover cycles left no headroom to test the door with");
        vm.prank(bob);
        assertGt(pool.deposit(Math.min(room, 100e6), bob), 0, "the deposit door is shut");
    }

    /// @notice A renormalisation divides every figure by the same power of two and moves no ratio.
    /// @dev The property that makes a shift safe where a generation roll is not: it destroys no
    ///      basis, it only loses low-order bits. Three holders, a shift driven by the crush
    ///      construction, and the marked-down bases compared against the counter they reconstruct.
    function test_aRenormalisationPreservesEveryHoldersAssetBasis() public {
        _deposit(alice, 4_000e6);
        _deposit(bob, 3_000e6);
        _deposit(carol, 2_000e6);

        for (uint256 i = 0; i < 24 && pool.unitExponent() == 0; i++) {
            _crushAndRecoverCycle(9_000e6);
        }
        assertGt(pool.unitExponent(), 0, "fixture: no shift happened, so nothing was measured");

        uint256 basisSum = pool.principalBasis(alice) + pool.principalBasis(bob) + pool.principalBasis(carol)
            + pool.principalBasis(dave) + pool.principalBasis(address(pool));
        uint256 net = pool.netDeposits();

        assertGe(basisSum, net, "holder bases stopped reconstructing admitted principal across a shift");
        assertLe(
            basisSum - net, _holdersWithUnits(), "holder-basis rounding across a shift exceeded one wei per holder"
        );
    }

    /// @notice A partial exit after a shift leaves the remainder at today's exponent, not yesterday's.
    ///
    /// @dev **This test exists because a neuter found nothing.** `_update` writes
    ///      `_principalUnits[from] = heldUnits - movedUnits`, and `heldUnits` came back from a
    ///      **normalising** read, so the stamp beside it has to move to the current exponent in the
    ///      same breath. Deleting that one line broke no test in the repository: every other trace
    ///      here either exits in full or exits an account that was re-stamped by its own deposit
    ///      moments earlier, and neither notices. The bug it hides is a holder silently losing the
    ///      shift again on everything they did not move - their basis, and therefore the cap
    ///      headroom their principal is holding, quietly evaporating on a partial transfer.
    ///
    ///      It needs a **stale** holder and a **small** shift, which is what `_gentleCrushCycle`
    ///      and the lowered ceiling are for. Bob deposits once and is never touched again, so his
    ///      stamp is as old as the pool by the time he moves half his shares.
    function test_aPartialExitAfterAShiftKeepsTheRemainderAtTheCurrentScale() public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        _deposit(alice, 4_000e6);
        _deposit(bob, 3_000e6);
        _deposit(carol, 2_000e6);

        for (uint256 i = 0; i < 24 && pool.unitExponent() == 0; i++) {
            _gentleCrushCycle();
        }
        assertGt(pool.unitExponent(), 0, "fixture: no shift happened, so nothing was measured");

        uint256 bobUnitsBefore = pool.principalUnits(bob);
        assertGt(bobUnitsBefore, 1, "fixture: the stale holder must still carry a real figure");

        uint256 bobShares = pool.balanceOf(bob);
        uint256 moved = bobShares / 2;
        uint256 expectedMovedUnits = Math.mulDiv(bobUnitsBefore, moved, bobShares, Math.Rounding.Ceil);

        vm.prank(bob);
        pool.transfer(dave, moved);
        _markCredited(dave);

        assertEq(
            pool.principalUnits(bob),
            bobUnitsBefore - expectedMovedUnits,
            "the remainder was re-shifted, so the stamp did not follow the write"
        );
        assertEq(pool.principalUnits(dave), expectedMovedUnits, "the receiver did not take the moved units");
        _assertDriftIsBounded();
    }

    /// @notice A partially filled queue entry keeps its remainder at today's exponent too.
    ///
    /// @dev **The queue's copy of the same defect, and the same neuter found nothing here either.**
    ///      `serviceQueue`'s partial-fill branch writes `request.principalUnits = requestUnits -
    ///      unitsToBurn` out of a normalising read, so the entry's stamp has to move with it. With
    ///      the stamp left behind, the remainder is shifted a second time on the next read: the
    ///      entry stops accounting for escrow the pool is holding on its behalf, and the escrow
    ///      equality that finding 16's detector rests on breaks by far more than the drift bound
    ///      allows for.
    ///
    ///      The shift has to land **between** the request and the fill. `requestWithdrawal` stamps
    ///      the entry at the exponent of the moment it is pushed, so a fill in the same epoch reads
    ///      identically with or without the re-stamp and proves nothing.
    function test_aPartiallyFilledQueueEntryKeepsItsRemainderAtTheCurrentScale() public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        _deposit(alice, 4_000e6);
        _deposit(bob, 3_000e6);
        _deposit(carol, 2_000e6);

        // Lend the float away **before** the request, and the order is the whole fixture. Once an
        // entry stands, `available()` holds back what the queue is owed, so every later lend leaves
        // at least that much idle behind and `serviceQueue` fills the head in full every time.
        _lendAll();

        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        _markCredited(address(pool));

        // Arm the next issuance to shift, then make the smallest deposit that will trigger one.
        // A one-USDC deposit moves the float by nothing, which is what keeps the fill partial.
        LowCeilingPool(address(pool)).setCeiling(pool.totalPrincipalUnits());
        uint256 exponentAtRequest = pool.unitExponent();
        _deposit(alice, 1e6);
        assertGt(pool.unitExponent(), exponentAtRequest, "fixture: no shift landed between request and fill");

        assertGt(pool.queueEntryPrincipalUnits(0), 1, "fixture: the entry must still carry a real figure");

        vm.prank(carol);
        pool.serviceQueue(1);

        (,, uint256 sharesLeft) = pool.queueEntry(0);
        assertGt(sharesLeft, 0, "fixture: the fill must be partial, not a full exit");
        assertLt(sharesLeft, bobShares, "fixture: the fill must actually have paid something");

        assertEq(
            pool.queueEntryPrincipalUnits(0),
            pool.principalUnits(address(pool)),
            "the partially filled entry stopped accounting for the escrow behind it"
        );
        _assertDriftIsBounded();
    }

    // ── the price of (B): the drift, and its bound ───────────────────────────

    /// @notice The storage identity a lazy shift breaks, and the bound that replaces it.
    ///
    /// @dev `sum over holders == totalPrincipalUnits` is **not** preserved by a lazy shift, because
    ///      each holder floors independently and `sum(floor) <= floor(sum)`. Round 23's design pass
    ///      found this by fuzzing after a three-holder hand-written trace measured a drift of zero,
    ///      which is the "right in the singular, wrong in the plural" trap wearing a disguise.
    ///
    ///      The replacement is an inequality with a derivation rather than a slack constant. With
    ///      `D` the drift before a shift of `k`, `S` the sum of the reads and `h` the number of
    ///      them, `floor((S+D)/2**k) - sum(floor(r_i/2**k)) <= D/2**k + h*(1 - 2**-k)`, which is
    ///      strictly under `h` whenever `D <= h - 1`. `D` starts at zero, so `D <= h - 1` is
    ///      inductive and holds across any number of shifts of any size. The aggregate therefore
    ///      **over**-counts, never under-counts, which is the direction every subtraction against
    ///      it needs: no holder's units can exceed it and no burn can underflow it.
    ///
    ///      The neuter is the bound written at `h - 2`: MEASURED to go red, which is what says this
    ///      assertion is tight rather than roomy.
    function test_theAggregateOverCountsByAtMostHoldersMinusOne() public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        _deposit(alice, 4_000e6);
        _deposit(bob, 3_000e6);
        _deposit(carol, 2_000e6);
        _deposit(dave, 1_000e6);

        for (uint256 cycle = 0; cycle < 6; cycle++) {
            _crushAndRecoverCycle(5_000e6);
            _deposit(bob, Math.min(pool.maxDeposit(bob), 777e6));
            _assertDriftIsBounded();
        }

        assertGt(pool.unitExponent(), 0, "no renormalisation fired, so the bound measured nothing");
    }

    /// @notice The same bound, fuzzed over deposit sizes rather than asserted on one trace.
    /// @dev At the shipped ceiling a fuzzer cannot reach a single shift, so this runs on the
    ///      lowered-ceiling harness. See `LowCeilingPool` for why that seam exists.
    function testFuzz_theDriftNeverExceedsHoldersMinusOne(uint256 a, uint256 b, uint256 c, uint256 top) public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        _deposit(alice, bound(a, 1e6, 8_000e6));
        _deposit(bob, bound(b, 1e6, 8_000e6));
        _deposit(carol, bound(c, 1e6, 8_000e6));

        for (uint256 cycle = 0; cycle < 4; cycle++) {
            _crushAndRecoverCycle(bound(top, 1e6, 9_000e6));
            _assertDriftIsBounded();
        }
    }

    function _assertDriftIsBounded() internal {
        _forgetCreditedHoldersIfTheGenerationRolled();

        uint256 total = pool.totalPrincipalUnits();
        uint256 sum = _sumHolderUnits();
        uint256 holders = _creditedHolders;

        assertLe(sum, total, "the sum of holder units rose above the aggregate");
        if (holders == 0) {
            assertEq(total, 0, "an aggregate stood with no credited holder behind it");
        } else {
            assertLe(total - sum, holders - 1, "the drift exceeded one unit per credited-holder boundary");
        }
    }

    /// @notice A generation roll clears the ledger and leaves the exponent exactly where it was.
    ///
    /// @dev **The measurement pass that sized this design listed "decide explicitly whether the
    ///      exponent resets with the generation, and measure it either way" as the first thing it
    ///      could not settle. The decision is that it does NOT reset, and this is the measurement.**
    ///
    ///      The two mechanisms are orthogonal and keeping them so is the whole reason a shift is
    ///      cheap. A generation is about **whose** units are live; an exponent is about **what scale**
    ///      a live figure is quoted at. Resetting the exponent on a roll would mean every stale
    ///      stamp in storage - held by accounts the roll has just invalidated, and by dead queue
    ///      entries - suddenly out-ranking the global counter, so `unitExponent - stamp` would
    ///      underflow and revert on the first read of any of them. Monotonicity is what makes that
    ///      subtraction safe, and it is asserted here rather than left to a reader of `_update`.
    ///
    ///      What the roll does do is clear the drift, because it clears both sides of the identity.
    function test_aGenerationRollLeavesTheExponentAloneAndClearsTheDrift() public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        _deposit(alice, 4_000e6);
        _deposit(bob, 3_000e6);
        _deposit(carol, 2_000e6);

        uint256 drift;
        for (uint256 i = 0; i < 24 && drift == 0; i++) {
            _gentleCrushCycle();
            _deposit(bob, Math.min(pool.maxDeposit(bob), 333e6));
            drift = pool.totalPrincipalUnits() - _sumHolderUnits();
        }
        assertGt(drift, 0, "fixture: there must be a drift for the roll to clear");

        uint256 exponentBefore = pool.unitExponent();
        assertGt(exponentBefore, 0, "fixture: a shift must have happened for this to say anything");

        for (uint256 i = 0; i < 32; i++) {
            _lendAll();
            uint256 exposure = pool.outstandingPrincipal();
            if (exposure == 0) break;
            _socialise(exposure);
        }

        assertEq(pool.totalAssets(), 0, "fixture: the roll needs a genuinely total loss");
        assertEq(pool.totalPrincipalUnits(), 0, "the roll must clear the aggregate");
        assertEq(_sumHolderUnits(), 0, "the roll must clear every holder, so the drift goes with it");
        assertEq(pool.unitExponent(), exponentBefore, "a generation roll must not move the exponent");

        // The new generation starts at par **at today's exponent**, not at the one the pool was
        // deployed with. This is the assertion that fails if `_creditPrincipalUnits` forgets to
        // stamp on the fresh-generation branch: the holder would be read `exponentBefore` bits down.
        _deposit(dave, 1_000e6);
        assertEq(pool.totalPrincipalUnits(), 1_000e6, "the new generation must start at par");
        assertEq(pool.principalUnits(dave), 1_000e6, "the fresh holder must be stamped at today's exponent");
        assertEq(pool.principalBasis(dave), 1_000e6, "the fresh holder must reconstruct their own principal");
        assertEq(pool.unitExponent(), exponentBefore, "a fresh generation must not move the exponent either");
    }

    /// @notice The residue a drift could leave in the cap counter after everybody has gone.
    ///
    /// @dev **Round 23's design pass declined to recommend a `totalSupply() == 0 => netDeposits = 0`
    ///      drain hook on the sole ground that no trace needing it could be constructed, and handed
    ///      the question to whoever implemented the renormalisation. This is that trace, built and
    ///      executed - and the answer is that the hook is not needed, for a reason stronger than a
    ///      failure to find a counterexample.**
    ///
    ///      With the aggregate over-counting by `D`, a last exit takes `ceil(N * u / U)` with
    ///      `u = U - D`, which is `N - floor(N * D / U)`. The residue is therefore `floor(N * D / U)`
    ///      - and `netDeposits <= totalPrincipalUnits` holds unconditionally (it is asserted as
    ///      `invariant_principalUnitsConserveNetDeposits`), so `N <= U` and the residue is bounded
    ///      by `D` itself, which is bounded by `holders - 1`. **At most one asset-wei of stranded
    ///      cap headroom per credited holder**, which is the same order as the ceiling-rounding
    ///      residuals finding 3 already discloses at one asset-wei per completed boundary. There is
    ///      no unbounded strand for a hook to catch.
    ///
    ///      This runs on the lowered-ceiling harness, and **that is not a convenience - at the
    ///      shipped ceiling the integer drift on this construction is exactly zero.** MEASURED:
    ///      `unitExponent` reaches 5 and `totalPrincipalUnits - sum` is 0, because a crush shift is
    ///      enormous relative to a stale holder's units, so every stale holder floors to exactly
    ///      zero having lost far less than one post-shift unit. A drift big enough to see needs
    ///      holders of comparable size and a shift of a few bits, which is what the harness gives.
    ///      The production-ceiling half of the question is the test below this one.
    function test_aFullUnwindStrandsAtMostOneAssetWeiPerHolder() public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        _deposit(alice, 4_000e6);
        _deposit(bob, 3_000e6);
        _deposit(carol, 2_000e6);

        uint256 drift;
        for (uint256 i = 0; i < 24 && drift == 0; i++) {
            _crushAndRecoverCycle(9_000e6);
            _deposit(bob, Math.min(pool.maxDeposit(bob), 777e6));
            drift = pool.totalPrincipalUnits() - _sumHolderUnits();
        }

        // **The reach check, and without it this test measures nothing.** A drift of zero going
        // into the unwind leaves a residue of zero for a reason unrelated to the question asked.
        assertGt(drift, 0, "fixture: the aggregate must actually be over-counting before the unwind");
        emit log_named_uint("MEASURED drift going into the unwind", drift);

        _unwindEverybody();

        emit log_named_uint("MEASURED netDeposits residue after the unwind", pool.netDeposits());
        assertLe(
            pool.netDeposits(),
            _creditedHolders - 1,
            "the unwind stranded more cap headroom than one asset-wei per credited holder"
        );
    }

    /// @notice The same unwind at the shipped ceiling: the counter reaches exactly zero.
    /// @dev The half of the drain-hook question that runs on the real contract. It reaches a real
    ///      renormalisation and then empties the pool, and the counter and the unit aggregate both
    ///      land on zero - so there is nothing for a `totalSupply() == 0` hook to clear, and
    ///      `totalSupply()` does not reach zero anyway. The last thousand share-wei are worth
    ///      under one asset-wei, so `previewRedeem` floors them to nothing and they are
    ///      unredeemable dust. That is the same wall the design pass's falsifier hit, which is why
    ///      it was declared inconclusive - and it is why this test reads the counter directly
    ///      rather than inferring anything from the supply.
    function test_aFullUnwindAtTheShippedCeilingLeavesNoResidueAtAll() public {
        _deposit(alice, 4_000e6);
        _deposit(bob, 3_000e6);
        _deposit(carol, 2_000e6);

        for (uint256 i = 0; i < 24 && pool.unitExponent() == 0; i++) {
            _crushAndRecoverCycle(9_000e6);
        }
        assertGt(pool.unitExponent(), 0, "fixture: no shift happened, so nothing was measured");

        _unwindEverybody();

        emit log_named_uint("MEASURED totalSupply after the unwind", pool.totalSupply());
        emit log_named_uint("MEASURED totalAssets after the unwind", pool.totalAssets());
        assertEq(pool.netDeposits(), 0, "a full unwind left admitted principal behind with nobody holding it");
        assertEq(pool.totalPrincipalUnits(), 0, "a full unwind left units behind with nobody holding them");
        assertEq(pool.maxDeposit(alice), pool.depositCap(), "a full unwind left cap headroom stranded");
    }

    /// @dev Everybody leaves, repeatedly, until nothing redeemable is left anywhere. Repeated
    ///      because `maxRedeem` is bounded by unreserved idle, so one pass rarely clears a holder.
    function _unwindEverybody() internal {
        address[4] memory holders = [alice, bob, carol, dave];
        for (uint256 round = 0; round < 8; round++) {
            for (uint256 i = 0; i < holders.length; i++) {
                uint256 redeemable = Math.min(pool.balanceOf(holders[i]), pool.maxRedeem(holders[i]));
                if (redeemable == 0) continue;
                vm.prank(holders[i]);
                pool.redeem(redeemable, holders[i], holders[i]);
            }
        }
    }

    // ── the escrow's own residue: audit round 24 ─────────────────────────────

    /// @notice The escrow's unit figure is floored once **as a sum**; each queue entry is floored
    ///         **independently**. So every entry can leave carrying exactly its own read and still
    ///         leave a residue held by an address with no shares and no entry.
    ///
    /// @dev **Audit round 24 found three shipped invariants asserting this could not happen.**
    ///      `invariant_noPrincipalUnitsOutliveShares` required `principalUnits(pool) == 0` whenever
    ///      the escrow held no shares, and `invariant_principalUnitsConserveNetDeposits` bounded the
    ///      escrow's excess by the entries that are live **now** - which is zero once they have all
    ///      gone. Both are false the moment a shift lands with more than one entry standing. No
    ///      campaign could see it: at the shipped `2**128` ceiling `unitExponent` never moved, so
    ///      every relaxed bound was being evaluated at drift zero.
    ///
    ///      This is the trace, armed rather than searched for. `setCeiling` puts the ceiling exactly
    ///      at the current aggregate, so the next issuance renormalises by **one bit** and no more -
    ///      a bigger shift would floor both entries to zero and the residue would vanish for a
    ///      reason unrelated to the question, which is the same trap `_gentleCrushCycle` exists for.
    ///      Both lenders hold an **odd** number of units, so each entry loses a half on the floor
    ///      while the escrow, holding their sum, loses nothing:
    ///      `floor((a+b)/2) - floor(a/2) - floor(b/2) == 1` for odd `a` and `b`. That 1 is the whole
    ///      finding, and it is the figure round 24 measured by hand.
    ///
    ///      **The bound that is true is `H - 1`, with `H` the number of entries live at the shift**,
    ///      by the same induction as `_renormaliseUnits`'s holder bound, one level in. The NEUTER is
    ///      that bound written at `H - 2`: with `H == 2` it asserts the residue is zero and this
    ///      test goes red. It was run and it went red before the campaign's version was believed.
    function test_A24_theEscrowKeepsAFlooringResidueAfterEveryEntryHasGone() public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        // Odd, so each entry loses a half on the floor and the escrow holding their sum does not.
        _deposit(alice, 4_000_000_001);
        _deposit(bob, 3_000_000_001);
        assertEq(pool.principalUnits(alice) % 2, 1, "fixture: alice's units must be odd");
        assertEq(pool.principalUnits(bob) % 2, 1, "fixture: bob's units must be odd");

        uint256 aliceUnits = pool.principalUnits(alice);
        uint256 bobUnits = pool.principalUnits(bob);

        // Read before the prank: an external staticcall in argument position spends it.
        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        assertEq(pool.principalUnits(address(pool)), aliceUnits + bobUnits, "fixture: escrow holds both entries");
        assertEq(pool.queueEntryPrincipalUnits(0), aliceUnits, "fixture: alice's entry carries her own units");
        assertEq(pool.queueEntryPrincipalUnits(1), bobUnits, "fixture: bob's entry carries his own units");

        // Arm exactly one bit. The aggregate is put at the ceiling, so the next issuance - however
        // small - crosses it and `_renormaliseUnits` halves once and stops.
        LowCeilingPool(address(pool)).setCeiling(pool.totalPrincipalUnits());
        _deposit(carol, 1);
        assertEq(pool.unitExponent(), 1, "fixture: the shift must be exactly one bit");

        // The signature, before anybody moves: the escrow reads one more than its entries claim.
        uint256 escrowAfterTheShift = pool.principalUnits(address(pool));
        uint256 entriesAfterTheShift = pool.queueEntryPrincipalUnits(0) + pool.queueEntryPrincipalUnits(1);
        emit log_named_uint("MEASURED escrow units after the shift", escrowAfterTheShift);
        emit log_named_uint("MEASURED entry units after the shift", entriesAfterTheShift);
        assertEq(escrowAfterTheShift - entriesAfterTheShift, 1, "the sum-versus-parts residue did not form");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        vm.prank(bob);
        pool.cancelWithdrawalRequest();

        assertEq(pool.balanceOf(address(pool)), 0, "the escrow kept shares after both entries left");
        assertEq(pool.queuedShares(), 0, "the queue did not drain");
        emit log_named_uint("MEASURED escrow units with no shares and no entry", pool.principalUnits(address(pool)));
        assertEq(pool.principalUnits(address(pool)), 1, "the residue is not the one the finding measured");

        // The bound, tight. `H` is 2, so `H - 1` is 1 and `H - 2` is 0 - which is the neuter.
        uint256 entriesAtTheShift = 2;
        assertLe(
            pool.principalUnits(address(pool)),
            entriesAtTheShift - 1,
            "the residue exceeded one unit per entry boundary"
        );
    }

    /// @notice CONTROL. One entry, and there is no residue to have: a sum of one is its own part.
    /// @dev Without this the test above reads as "a shift strands a unit", which is not what
    ///      happens. The residue is the difference between flooring a sum and flooring its terms, so
    ///      it needs at least two terms - which is why the bound is `H - 1` rather than `H`, and why
    ///      the campaign's version has to record `H` **at the shift** rather than read it now.
    function test_A24_control_aSingleEntryLeavesNoResidue() public {
        pool = new LowCeilingPool(IERC20(address(usdc)), admin);
        _wire(pool);

        _deposit(alice, 4_000_000_001);
        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);

        LowCeilingPool(address(pool)).setCeiling(pool.totalPrincipalUnits());
        _deposit(carol, 1);
        assertEq(pool.unitExponent(), 1, "fixture: the shift must be exactly one bit");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();

        assertEq(pool.balanceOf(address(pool)), 0, "the escrow kept shares after the entry left");
        assertEq(pool.principalUnits(address(pool)), 0, "a single entry left a residue it cannot have");
    }

    // ── the tripwire this file started as ────────────────────────────────────

    /// @notice The clamp now fires only when the assets have gone, and it is no longer the only
    ///         thing that rescales the quotient.
    ///
    /// @dev **This test used to assert the opposite of what it asserts now, and that is the point
    ///      of keeping it.** Before round 23's fix it read
    ///      `test_theExactLossClampIsTheOnlyQuotientRescaling`: ten cycles of a loss equal to
    ///      exactly `netDeposits`, each fully recovered, ending with `U == N` because every cycle
    ///      entered the clamp, zeroed the units and rolled the generation. That green was the
    ///      contract committing finding 6 ten times over, and the test existed to stop anyone
    ///      deleting the clamp without a replacement for the brake it provided.
    ///
    ///      The replacement shipped. The clamp is still there and still rolls the generation, but
    ///      its predicate is now honest - `netDeposits` reaches zero only when `totalAssets()` has -
    ///      so a loss that leaves a book standing no longer takes it. `_renormaliseUnits` is what
    ///      bounds the quotient now, and it does so without invalidating anybody.
    function test_theClampNowFiresOnlyWhenTheAssetsHaveGone() public {
        _deposit(alice, 10_000e6);

        for (uint256 i = 0; i < 10; i++) {
            _lendAll();
            uint256 counter = pool.netDeposits();
            uint256 exposure = pool.outstandingPrincipal();
            uint256 absorbed = _socialise(Math.min(counter, exposure));
            _recover(absorbed);
            vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);

            assertEq(pool.netDeposits() == 0, pool.totalAssets() == 0, "the clamp and the assets disagree");

            if (pool.maxDeposit(alice) >= 1_000e6) _deposit(alice, 1_000e6);
        }

        assertGt(pool.netDeposits(), 0, "ten recovered cycles must leave a live counter to divide by");
        assertGt(pool.totalAssets(), 0, "ten recovered cycles must leave a live book");
        assertLt(pool.totalPrincipalUnits(), CEILING, "the quotient left the ceiling");
    }

    /// @notice CONTROL. One asset-wei of book standing is enough to keep the counter alive and the
    ///         generation intact, however far the quotient has been driven up.
    /// @dev Nothing but the last asset-wei differs between this and the total-loss control above,
    ///      which is what makes either of them a statement about the predicate rather than the loop.
    function test_control_oneWeiOfBookStandingKeepsTheCounterAlive() public {
        _deposit(alice, 10_000e6);

        for (uint256 i = 0; i < 64; i++) {
            _lendAll();
            uint256 exposure = pool.outstandingPrincipal();
            if (exposure < 2) break;
            _socialise(exposure - 1);
        }

        assertEq(pool.totalAssets(), 1, "fixture: exactly one asset-wei of book must survive");
        assertEq(pool.netDeposits(), 1, "one asset-wei of book must leave one asset-wei admitted");
        assertGt(pool.totalPrincipalUnits(), pool.netDeposits(), "the quotient must be left above one");
        assertGt(pool.principalUnits(alice), 0, "the generation must not have rolled");
    }
}
