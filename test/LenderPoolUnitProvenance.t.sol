// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round-22 finding 3, the boundaries residual (iv) left behind: the four places where a
///         principal-unit rounding moves `netDeposits` by more or less than the money that moved.
///
/// @dev **The ledger attributed three of these four.** `netDeposits` (**N**) is asset-denominated
///      and is the sole input to `maxDeposit`; `totalPrincipalUnits` (**U**) is dimensionless.
///      Four roundings connect them, and every one of them was a ceiling before this file:
///
///      | site | expression | what it decides |
///      | --- | --- | --- |
///      | `_deposit` | `ceil(assets * U / N)` | units issued for an entry |
///      | `_update` | `ceil(heldUnits * value / fromBalance)` | units that follow a share transfer |
///      | `serviceQueue` | `ceil(requestUnits * sharesToBurn / shares)` | units a partial fill retires |
///      | `_burnPrincipalUnits` | `ceil(N * units / U)` | the asset-wei an exit takes off the counter |
///
///      **Each trace below was executed before any change was made, and each is stated with its
///      sign against the deposit cap.** The two directions are not interchangeable: LOOSEN lets
///      `maxDeposit` advertise headroom the pool has not earned, which is round-22 finding 3's
///      original High; BRICK strands headroom permanently, which is round-23 finding 16's
///      direction and the direction this finding's own headline defect ran in. **A fix that
///      over-corrects turns one High into the other, so every candidate here was sign-checked
///      before it was believed.**
///
///      | boundary | MEASURED, before | sign | status |
///      | --- | --- | --- | --- |
///      | no-loss dust split then zero-asset redeem | counter 10 to **0** in ten cycles, all ten assets still in the pool | LOOSEN | **CLOSED**, `_update` floors |
///      | a queue entry paid in slices | **one asset-wei per slice**, +401 over 400 fills | LOOSEN | **OPEN**, and the floor was refused on a sign change |
///      | post-loss one-asset-wei round trip | **1** asset-wei per completed round trip | LOOSEN | **OPEN**, and priced below |
///      | ERC-20 merge then split of two differently priced lots | **33.333334 USDC** released ahead of schedule | LOOSEN | **OPEN and unclosable by a per-holder scalar** |
///
///      **ONE rounding flip shipped, and two candidates were refuted. The refutations are the
///      deliverable.** What shipped is `_update`'s share-to-unit move, `Ceil` to `Floor`, at
///      **-1 byte and -42 gas on a warm ERC-20 transfer**, which closes the first boundary
///      outright rather than bounding it.
///
///      **Refuted 1: flooring `serviceQueue`'s partial-fill unit debit.** It looks like the same
///      change one screen along and it is not. Measured against the honest debit it takes the
///      error from +401 / +123 / +2 to +1 / **-23** / +1: an order of magnitude smaller and
///      **sign-unstable**, and the negative one is admitted principal stranded against the cap,
///      which is the brick direction and this finding's own headline defect. Round-23 finding 12
///      picked that ceiling deliberately and its one-wei-wide test is what discriminates it. A
///      bounded error of known sign beats a smaller error of unknown sign, so the ceiling stays.
///      (Finding 12's stated *reason* is wrong on the sign - it calls the floor "cap-loosening"
///      when a floor leaves the counter high, which is less headroom, not more - and the choice
///      survives anyway.)
///
///      **Refuted 2: the per-holder recorded basis.** Round 23's design pass concluded that "the
///      only rule that survives both traces is a per-holder principal basis", and round-22
///      finding 3 has carried that prescription ever since. It was **built** while this file was
///      being written - a fourth per-holder mapping recording what each account admitted through
///      `_deposit`, moved pro rata with the shares, and read as a cap on the exit debit - and
///      MEASURED:
///
///      - it **closes** the post-loss round trip exactly: the counter is flat at 9,000,000 over
///        five cycles where the shipped contract loses one asset-wei on each;
///      - it is **INERT** on the queue-fill boundary and on the merge/split boundary. Both numbers
///        were identical to the wei with and without it. After any realised loss the marked-down
///        debit `ceil(N*u/U)` is strictly *below* the recorded figure, so the cap never binds on
///        exactly the paths that leak; and a merge carries the recorded figure along with the
///        units, so there is nothing left for it to disagree with;
///      - it costs **+238 bytes** and **+11,385 gas on a warm ERC-20 transfer, +28,373 cold,
///        +6,225 on a partial redeem and +5,180 on a deposit** - a permanent tax on the hottest
///        path in the contract, to close one boundary worth one asset-wei per round trip.
///
///      It is not refused on principle: it is refused at that price, and the shape that would make
///      it affordable is packing `_principalUnits`, `_principalUnitExponent`,
///      `_principalUnitGeneration` and the recorded figure into one 256-bit slot instead of adding
///      a fourth mapping beside three. That is one SSTORE where the contract already spends two.
contract LenderPoolUnitProvenanceTest is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal creditManager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();

        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    // -- fixture -------------------------------------------------------------

    /// @dev Read every view into a local before any `vm.prank`. An external staticcall in argument
    ///      position spends the prank, and what comes back is a plausible protocol revert rather
    ///      than a tooling error.
    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        return pool.deposit(assets, who);
    }

    function _redeemAll(address who) internal returns (uint256 assets) {
        uint256 shares = pool.balanceOf(who);
        if (shares == 0) return 0;
        vm.prank(who);
        return pool.redeem(shares, who, who);
    }

    function _lendAll() internal returns (uint256 lent) {
        lent = pool.available();
        if (lent == 0) return 0;
        vm.prank(creditManager);
        pool.lend(lent);
    }

    function _socialise(uint256 amount) internal returns (uint256) {
        vm.prank(creditManager);
        return pool.socialiseLoss(amount);
    }

    function _repay(uint256 amount) internal {
        usdc.mint(creditManager, amount);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.repayPrincipal(amount);
        vm.stopPrank();
    }

    function _distributeYield(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(pool), amount);
        pool.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION + 1);
    }

    // -- boundary 1: the no-loss dust split. CLOSED. --------------------------

    /// @notice A dust share split followed by a zero-asset redemption no longer moves the cap.
    ///
    /// @dev **This trace is the one that used to zero the counter.** `_decimalsOffset()` is three,
    ///      so ten asset-wei mints 10,000 share-wei against ten principal units. Under the ceiling
    ///      that was in `_update`, transferring **one share-wei** - a ten-thousandth of the
    ///      position - moved a whole unit; that one-share position then redeemed for zero assets
    ///      because the exit conversion floors, and the unit burn still took one asset-wei off
    ///      `netDeposits`. Ten cycles: counter ten to zero, `maxDeposit` back at the full
    ///      25,000.000000, and every one of the ten assets still sitting in the contract.
    ///
    ///      With the floor the same twelve cycles move **nothing at all**: the moved units round to
    ///      zero, so no unit reaches the dust position and its redemption burns nothing. This is a
    ///      closure, not a bound - there is no per-cycle residue left to disclose.
    ///
    ///      The reason it does not simply reverse into the brick direction is the `value ==
    ///      fromBalance` branch beside it, which is still exact. A floored remainder always stays
    ///      with an account that still holds the shares it belongs to, and the last share out of
    ///      any balance carries every unit left. Under the ceiling the units detached from the
    ///      shares, which is what made a zero-asset burn possible at all.
    function test_R22F3_aDustSplitAndZeroAssetRedeemNoLongerLoosensTheCap() public {
        uint256 aliceShares = _deposit(alice, 10);
        assertEq(aliceShares, 10_000, "fixture: the virtual offset must mint one thousand shares per asset-wei");

        uint256 assetsBefore = usdc.balanceOf(address(pool));
        uint256 headroomBefore = pool.maxDeposit(bob);
        assertEq(pool.netDeposits(), 10, "fixture: ten asset-wei must be admitted");
        assertEq(pool.principalUnits(alice), 10, "fixture: ten units must be issued at par");

        for (uint256 i = 0; i < 12; i++) {
            vm.prank(alice);
            pool.transfer(bob, 1);

            assertEq(pool.principalUnits(bob), 0, "a dust split must move no principal unit at all");
            assertEq(pool.previewRedeem(1), 0, "fixture: each one-share position must redeem for zero assets");

            vm.prank(bob);
            uint256 assetsOut = pool.redeem(1, bob, bob);

            assertEq(assetsOut, 0, "fixture: each boundary must pay no assets");
            assertEq(usdc.balanceOf(address(pool)), assetsBefore, "fixture: no asset may leave the pool");
            assertEq(pool.totalPrincipalUnits(), 10, "a zero-asset exit must burn no units");
            assertEq(pool.netDeposits(), 10, "a zero-asset exit must not loosen the cap");
            assertEq(pool.maxDeposit(bob), headroomBefore, "cap headroom must not move when no asset moves");
        }

        assertEq(pool.principalUnits(alice), 10, "the sender must keep every unit the floor left behind");
    }

    /// @notice The floored remainder is released in full when the sender's own balance empties.
    /// @dev The brick-direction control for the flip above, and the one that gets forgotten. A
    ///      floor under-moves, so the question a sign check has to ask is whether the units it
    ///      holds back can be stranded. They cannot: `value == fromBalance` is exact, so the last
    ///      share out carries every unit left and the counter reaches zero on merit.
    function test_R22F3_theFlooredRemainderIsNotStranded() public {
        _deposit(alice, 10);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            pool.transfer(bob, 1);
        }
        assertEq(pool.principalUnits(alice), 10, "fixture: the floor must have held every unit back");

        _redeemAll(alice);
        _redeemAll(bob);

        assertEq(pool.totalPrincipalUnits(), 0, "a full unwind must retire every unit");
        assertEq(pool.netDeposits(), 0, "a full unwind must release the whole cap counter");
        assertEq(pool.maxDeposit(carol), pool.depositCap(), "no headroom may be stranded by the floor");
    }

    // -- boundary 2: the queue partial fill. THE FOURTH, and it was unattributed. --

    /// @notice Known residual: a sliced queue fill loosens the cap by up to one asset-wei per
    ///         slice, and it never strands admitted principal instead.
    ///
    /// @dev **This is the rounding the ledger never attributed.** Round-22 finding 3 names three
    ///      sites; `serviceQueue`'s partial-fill unit debit is a fourth. It is a ceiling, and it
    ///      buys a second ceiling in `_burnPrincipalUnits` on every slice.
    ///
    ///      Measured against the **honest** debit rather than against another rounding: the
    ///      escrow's marked-down basis is a fixed number of asset-wei per escrowed share while an
    ///      entry is being paid - a repay moves neither `netDeposits` nor the units - so the
    ///      honest counter debit for a fill is that rate times the shares it burned.
    ///
    ///      | trace | counter debit against honest |
    ///      | --- | --- |
    ///      | 400 fills of one asset-wei | **+401** |
    ///      | 199 fills of 1.000003 | **+123** |
    ///      | one fill of the same total | **+2** |
    ///
    ///      One asset-wei per fill, always in the same direction. `serviceQueue` is permissionless,
    ///      so how many slices an entry is paid in is nobody's choice but the caller's, and the
    ///      residual is therefore gas-bound rather than lender-bound.
    ///
    ///      **The two-sided assertion is the whole test, and the lower half is the one that
    ///      matters.** Flipping this rounding to `Floor` was built and measured in the same tree:
    ///      it takes the three figures to +1, **-23** and +1. An order of magnitude smaller, and
    ///      **sign-unstable** - on the middle trace it stops over-debiting and starts stranding
    ///      admitted principal against the cap, which is the brick direction and round-22 finding
    ///      3's own headline defect. `assertGe` below goes RED at -23 under that flip, which is the
    ///      refutation. Round-23 finding 12 chose this ceiling and its deterministic one-wei-wide
    ///      test discriminates the rounding directly; this one discriminates it from the cap's side.
    function test_R22F3_knownResidual_aSlicedQueueFillOnlyEverOverDebitsTheCounter() public {
        _assertFillRoundingIsBoundedAndOneSided(1, 400);
        _assertFillRoundingIsBoundedAndOneSided(1_000_003, 199);
        _assertFillRoundingIsBoundedAndOneSided(1_000_003 * 199, 1);
    }

    /// @dev Builds a fresh pool, marks it down so `netDeposits != totalPrincipalUnits` - at par the
    ///      exit debit is exact and the boundary cannot be reached at all - queues one entry, pays
    ///      it in `rounds` slices of `drip`, and compares what the counter did against what the
    ///      shares that actually left were worth. A second holder is seeded so the escrow is never
    ///      the whole aggregate: `_burnPrincipalUnits` takes an exact branch when it is, and a
    ///      first draft of this fixture measured that branch and reported no drift at all.
    ///
    ///      The `+ 2` in the upper bound is this fixture's own two floors, not slack in the rule:
    ///      the reference basis and the pro-rata share of it are both computed with `Floor` here,
    ///      while the contract ceils, so the honest figure is understated by at most two.
    function _assertFillRoundingIsBoundedAndOneSided(uint256 drip, uint256 rounds) internal {
        uint256 snapshot = vm.snapshotState();

        _deposit(alice, 1_000e6);
        _lendAll();
        _socialise(333e6);
        _deposit(bob, 7e6);

        assertLt(pool.netDeposits(), pool.totalPrincipalUnits(), "fixture: the book must be marked down");

        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        uint256 counterBefore = pool.netDeposits();
        uint256 escrowUnits = pool.principalUnits(address(pool));
        uint256 escrowShares = pool.balanceOf(address(pool));
        uint256 totalUnits = pool.totalPrincipalUnits();

        for (uint256 i = 0; i < rounds; i++) {
            _repay(drip);
            vm.prank(carol);
            pool.serviceQueue(1);
        }

        uint256 sharesBurned = escrowShares - pool.balanceOf(address(pool));
        assertGt(sharesBurned, 0, "fixture: the fills must actually have paid the entry");
        assertGt(pool.balanceOf(address(pool)), 0, "fixture: the entry must still be partly unpaid");

        uint256 debited = counterBefore - pool.netDeposits();
        uint256 escrowBasis = Math.mulDiv(counterBefore, escrowUnits, totalUnits, Math.Rounding.Floor);
        uint256 honest = Math.mulDiv(escrowBasis, sharesBurned, escrowShares, Math.Rounding.Floor);

        assertGe(debited, honest, "a sliced fill stranded admitted principal instead of releasing it");
        assertLe(debited - honest, rounds + 2, "a sliced fill loosened the cap by more than one asset-wei per fill");

        vm.revertToState(snapshot);
    }

    // -- boundary 3: the post-loss round trip. STILL OPEN, and priced. --------

    /// @notice Known residual: a post-loss one-asset-wei round trip loosens the cap by one
    ///         asset-wei, every time, and the money never leaves.
    ///
    /// @dev **The entry ceiling is the cause and the exit ceiling is only the messenger.** At
    ///      `U = 10,000,000` over `N = 9,000,000` a one-asset-wei deposit is issued
    ///      `ceil(1 * U / N) = 2` units for 1.111 units of admission, and the exit faithfully pays
    ///      two asset-wei back for them. Five executed round trips, MEASURED: the counter falls
    ///      9,000,000 to 8,999,995 while the pool's USDC balance **rises** 1,500,000 to 1,500,005,
    ///      because each depositor's asset-wei stays behind. `maxDeposit` therefore diverges from
    ///      the honest headroom by two asset-wei per cycle, not one.
    ///
    ///      **Not fixable by flipping the entry to `Floor`**, which is the obvious repair and the
    ///      wrong one: it under-credits every ordinary deposit and ratchets the counter *up*, the
    ///      cap-BRICK direction, which is round-23 finding 16's direction and this finding's own
    ///      headline defect. **Fixable by a recorded per-holder basis**, which was built and
    ///      measured in this worktree: this trace goes flat at 9,000,000 under it. It is refused at
    ///      its measured price; the file header carries the numbers.
    ///
    ///      Gas-bound at one asset-wei per round trip, so closing a 25,000.000000 cap needs 2.5e10
    ///      transactions. That is what makes it a disclosed residual rather than the original
    ///      114-wei ratchet.
    function test_R22F3_knownResidual_aPostLossRoundTripLoosensTheCapByOneAssetWei() public {
        _deposit(alice, 10e6);
        _lendAll();
        _socialise(1e6);

        assertEq(pool.netDeposits(), 9e6, "fixture: the loss must leave nine USDC admitted");
        assertEq(pool.totalPrincipalUnits(), 10e6, "fixture: the units must survive the loss");

        uint256 counterBefore = pool.netDeposits();
        uint256 balanceBefore = usdc.balanceOf(address(pool));

        for (uint256 i = 0; i < 5; i++) {
            uint256 shares = _deposit(bob, 1);
            assertEq(pool.principalUnits(bob), 2, "the entry ceiling must issue two units for one asset-wei");

            vm.prank(bob);
            uint256 assetsOut = pool.redeem(shares, bob, bob);
            assertEq(assetsOut, 0, "the round trip must return nothing at all");

            assertEq(pool.netDeposits(), counterBefore - (i + 1), "known residual: one asset-wei of cap per cycle");
            assertEq(usdc.balanceOf(address(pool)), balanceBefore + i + 1, "the asset-wei must stay in the pool");
        }

        assertEq(pool.netDeposits(), 8_999_995, "five cycles must cost exactly five asset-wei of counter");
        assertEq(usdc.balanceOf(address(pool)), balanceBefore + 5, "and the pool must be five asset-wei richer");
    }

    // -- boundary 4: the merge/split. OPEN, and larger than the ledger implies. --

    /// @notice Known residual: merging two differently priced lots and splitting them again
    ///         releases 33.333334 USDC of deposit-cap headroom ahead of schedule.
    ///
    /// @dev **The ledger records this boundary with no direction, alongside two worth one
    ///      asset-wei. MEASURED, it is neither.** Alice admits 100.000000 at par; a 100.000000
    ///      yield epoch is delivered and released, doubling the share price; Bob then admits
    ///      100.000000 for half the shares. Both hold 100,000,000 units, so the two lots carry
    ///      different units per share - which is the whole precondition, and a realised loss cannot
    ///      supply it because a loss moves `netDeposits` and `totalAssets()` together.
    ///
    ///      Bob sends his whole balance to Alice and Alice sends the same share count back. Units
    ///      are conserved to the wei and neither `N` nor `U` moves - but the **provenance** is
    ///      gone: Alice comes out holding 133,333,334 units against her 100,000,000 of admission
    ///      and Bob 66,666,666 against his.
    ///
    ///      The cap effect is not in the swap, it is in who leaves first, and it is not bounded by
    ///      a wei:
    ///
    ///      | after the unit-gainer exits | `netDeposits` | `maxDeposit` |
    ///      | --- | --- | --- |
    ///      | control, no swap | 100,000,000 | 24,900.000000 |
    ///      | after the merge and split | **66,666,666** | **24,933.333334** |
    ///
    ///      Bob's 100.000000 is still in the book and the counter now says 66.666666 of it was
    ///      admitted, so the pool will accept 33.333334 more than it has room for and will keep
    ///      accepting it for as long as Bob holds. It self-cancels only on a complete unwind, which
    ///      no lender is obliged to perform.
    ///
    ///      **Unclosable by any per-holder scalar, and the recorded basis was built to check.** A
    ///      merge carries the recorded figure along with the units - Alice legitimately receives
    ///      Bob's admission with Bob's shares - so a cap at the recorded figure never binds, and
    ///      the measurement is identical to the wei with and without it. Closing this needs per-lot
    ///      provenance, which one scalar ERC-20 balance cannot carry. `principalBasis`'s own
    ///      NatSpec says exactly that, and this is the executed price of that sentence.
    function test_R22F3_knownResidual_anErc20MergeAndSplitReleasesTheCapAheadOfSchedule() public {
        uint256 withoutTheSwap = _twoLotUnwind(false);
        uint256 withTheSwap = _twoLotUnwind(true);

        assertEq(withoutTheSwap, 100_000_000, "control: the counter must still hold the remaining lender's admission");
        assertEq(withTheSwap, 66_666_666, "known residual: the merge/split releases the counter ahead of schedule");
        assertEq(
            withoutTheSwap - withTheSwap,
            33_333_334,
            "known residual: 33.333334 USDC of cap headroom, not one asset-wei"
        );
    }

    /// @dev Builds the two differently priced lots and returns `netDeposits` after the account
    ///      holding the merged units has exited, with and without the round trip through Alice.
    function _twoLotUnwind(bool swap) internal returns (uint256 counterAfterTheGainerLeaves) {
        uint256 snapshot = vm.snapshotState();

        _deposit(alice, 100e6);
        _distributeYield(100e6);
        _deposit(bob, 100e6);

        assertEq(pool.principalUnits(alice), 100_000_000, "fixture: both lots must admit the same principal");
        assertEq(pool.principalUnits(bob), 100_000_000, "fixture: both lots must admit the same principal");
        assertLt(pool.balanceOf(bob), pool.balanceOf(alice), "fixture: the lots must be priced differently");

        if (swap) {
            uint256 bobShares = pool.balanceOf(bob);
            vm.prank(bob);
            pool.transfer(alice, bobShares);
            assertEq(pool.principalUnits(alice), 200_000_000, "fixture: the merge must be additive");

            vm.prank(alice);
            pool.transfer(bob, bobShares);
            assertEq(pool.principalUnits(alice), 133_333_334, "the split must average what the merge blended");
            assertEq(pool.principalUnits(bob), 66_666_666, "the split must average what the merge blended");
            assertEq(pool.totalPrincipalUnits(), 200_000_000, "a transfer must conserve principal units");
            assertEq(pool.netDeposits(), 200_000_000, "a transfer must not move admitted principal");
        }

        _redeemAll(alice);
        counterAfterTheGainerLeaves = pool.netDeposits();

        // And it does cancel on a complete unwind, which is why this is a residual and not the
        // original High. Nothing obliges the second holder to perform it.
        _redeemAll(bob);
        assertEq(pool.netDeposits(), 0, "a complete unwind must still release the whole counter");

        vm.revertToState(snapshot);
    }
}
