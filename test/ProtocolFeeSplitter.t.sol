// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {ProtocolFeeSplitter} from "../src/ProtocolFeeSplitter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice The on-chain 80/20 of Recoup's protocol fee with DexFi (agreed 2026-08-06).
///
///         The point of these tests is not that a percentage is computed correctly. It is
///         that the two properties the arrangement is *sold* on actually hold: that
///         neither party can redirect the other's leg **of what has arrived here**, and that
///         the two legs always sum to exactly what arrived.
///
///         **The emphasis is load-bearing and audit round 21 is why.** These tests can only
///         ever speak for money already at the splitter. The redirect that mattered happened
///         one hop upstream, in `EpochHarvester.setProtocolFeeWallet`, over a backlog that had
///         not been flushed here yet - MEASURED at 60.000000 of DexFi's money becoming 0 across
///         three epochs. That half of the guarantee is tested in `EpochHarvester.t.sol`, under
///         `test_setProtocolFeeWallet_leavesTheBacklogWithTheWalletThatEarnedIt`, and it has to
///         be, because nothing this contract can be asked will ever reveal it.
///
///         **Audit round 23, finding 8 added the third property, and it is the one the first two
///         were quietly costing.** Both legs used to be paid atomically, so one blocked
///         destination stranded the other party's money permanently on a contract with no owner,
///         no setter, no pause and no rescue. The `park` section below is that fix: a leg that
///         cannot take delivery is checkpointed against its own immutable address and paid later
///         by anybody. Every test there fails against the pre-fix contract, and the two
///         `discriminates` tests exist so a green run cannot be the fixture rather than the fix.
contract ProtocolFeeSplitterTest is Test {
    MockUSDC internal usdc;
    ProtocolFeeSplitter internal splitter;

    address internal recoupWallet = makeAddr("recoupWallet");
    address internal dexfiWallet = makeAddr("dexfiWallet");

    function setUp() public {
        usdc = new MockUSDC();
        splitter = new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, dexfiWallet);
    }

    // ── construction ─────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ProtocolFeeSplitter.ZeroAddress.selector);
        new ProtocolFeeSplitter(IERC20(address(0)), recoupWallet, dexfiWallet);

        vm.expectRevert(ProtocolFeeSplitter.ZeroAddress.selector);
        new ProtocolFeeSplitter(IERC20(address(usdc)), address(0), dexfiWallet);

        vm.expectRevert(ProtocolFeeSplitter.ZeroAddress.selector);
        new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, address(0));
    }

    function test_constructor_rejectsOneAddressOnBothLegs() public {
        vm.expectRevert(ProtocolFeeSplitter.WalletsMustDiffer.selector);
        new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, recoupWallet);
    }

    /// @dev The whole commercial argument for a contract over a monthly transfer. If any
    ///      of these existed, "neither of us can point it somewhere else" would be false.
    ///
    ///      `flushLegTo` is deliberately absent from this list and is checked in
    ///      `test_flushLegTo_grantsNoAuthorityOverWhereTheMoneyGoes` instead. It takes an address
    ///      and so *looks* like the thing this test forbids; it is not, because the address is a
    ///      mapping key rather than a destination and only the two immutable legs are ever keys.
    ///      That distinction is the whole reason the round-23 escape hatch did not have to bring
    ///      an owner with it, so it gets a test that measures it rather than a line in a list.
    ///
    ///      `reconcileDestroyedLegs` is absent for a stronger reason and is checked in
    ///      `test_A26_08_reconcileIsPermissionlessAndPaysItsCallerNothing`. It takes no argument
    ///      at all, so there is nothing for a caller to point anywhere, and the only state it
    ///      acts on is one this contract cannot put itself into.
    function test_hasNoOwnerAndNoWayToRedirectEitherLeg() public {
        assertEq(splitter.recoupWallet(), recoupWallet);
        assertEq(splitter.dexfiWallet(), dexfiWallet);

        // No `owner()`, no `setRecoupWallet`, no `setDexfiWallet`, no `pause`, no
        // `rescue`. Asserted by selector so that adding one later fails this test rather
        // than quietly weakening the guarantee the partner was given.
        string[6] memory forbidden =
            ["owner()", "setRecoupWallet(address)", "setDexfiWallet(address)", "pause()", "rescue(address)", "sweep()"];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(splitter).call(abi.encodeWithSignature(forbidden[i]));
            assertFalse(ok, forbidden[i]);
        }
    }

    // ── splitting ────────────────────────────────────────────────────────────

    function test_split_paysTheAgreedRatio() public {
        usdc.mint(address(splitter), 1_000e6);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(toRecoup, 800e6, "80% to Recoup");
        assertEq(toDexFi, 200e6, "20% to DexFi");
        assertEq(usdc.balanceOf(recoupWallet), 800e6);
        assertEq(usdc.balanceOf(dexfiWallet), 200e6);
        assertEq(usdc.balanceOf(address(splitter)), 0, "nothing left behind");
    }

    function test_split_isPermissionless() public {
        usdc.mint(address(splitter), 500e6);

        vm.prank(makeAddr("a passing keeper"));
        splitter.split();

        assertEq(usdc.balanceOf(dexfiWallet), 100e6);
    }

    function test_split_revertsOnAnEmptyBalance() public {
        vm.expectRevert(ProtocolFeeSplitter.NothingToSplit.selector);
        splitter.split();
    }

    /// @dev The invariant that matters more than the ratio: whatever arrives leaves, in
    ///      full, in one call. A dust remainder stranded here would accumulate forever,
    ///      because there is no rescue path by design.
    function testFuzz_split_alwaysDistributesTheWholeBalance(uint256 amount) public {
        amount = bound(amount, 1, 1e18);
        usdc.mint(address(splitter), amount);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(toRecoup + toDexFi, amount, "the legs must sum to what arrived");
        assertEq(usdc.balanceOf(address(splitter)), 0, "and nothing may be stranded");
        assertEq(usdc.balanceOf(recoupWallet), toRecoup);
        assertEq(usdc.balanceOf(dexfiWallet), toDexFi);
    }

    /// @dev DexFi's leg is never rounded up at Recoup's expense, and never silently
    ///      zeroed on a small amount either - both are things a partner would reasonably
    ///      check for themselves.
    function testFuzz_split_neverOverpaysEitherLeg(uint256 amount) public {
        amount = bound(amount, 1, 1e18);
        usdc.mint(address(splitter), amount);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertLe(toDexFi, (amount * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS + 1);
        assertGe(toRecoup, (amount * Config.PROTOCOL_FEE_RECOUP_BPS) / Config.BPS);
    }

    function test_split_accumulatesAcrossSeveralFlushes() public {
        usdc.mint(address(splitter), 100e6);
        splitter.split();
        usdc.mint(address(splitter), 100e6);
        splitter.split();

        assertEq(usdc.balanceOf(recoupWallet), 160e6);
        assertEq(usdc.balanceOf(dexfiWallet), 40e6);
    }

    // ── preview ──────────────────────────────────────────────────────────────

    function testFuzz_preview_matchesWhatSplitActuallyPays(uint256 amount) public {
        amount = bound(amount, 1, 1e18);
        (uint256 previewRecoup, uint256 previewDexFi) = splitter.preview(amount);

        usdc.mint(address(splitter), amount);
        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(previewRecoup, toRecoup);
        assertEq(previewDexFi, toDexFi);
    }

    // ── park and flush (audit round 23, finding 8) ───────────────────────────
    //
    // Every test in this section fails against the pre-fix contract, where `split()` was two
    // bare transfers in one transaction. There, a blocked leg reverts the whole call and the
    // assertion that the healthy party was paid is the one that goes red.

    /// @dev The finding itself. DexFi's wallet is blocked by a third party neither side controls;
    ///      Recoup's healthy 80% must still arrive, and DexFi's 20% must still be owed rather
    ///      than lost. Pre-fix, `split()` reverts `Blocked(dexfiWallet)` and Recoup gets nothing,
    ///      forever, because `split()` is the only call the contract has.
    function test_split_paysTheHealthyLegWhenTheOtherWalletIsBlocked() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(dexfiWallet, true);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(toRecoup, 800e6, "the split is unchanged");
        assertEq(toDexFi, 200e6);
        assertEq(usdc.balanceOf(recoupWallet), 800e6, "the healthy party is paid in full");
        assertEq(usdc.balanceOf(dexfiWallet), 0, "the blocked party is not");
        assertEq(splitter.owedToWallet(dexfiWallet), 200e6, "and is owed its leg instead");
        assertEq(splitter.totalOwedToWallets(), 200e6);
        assertEq(usdc.balanceOf(address(splitter)), 200e6, "which is still physically here");
    }

    /// @dev The mirror, because a fix that only survives a block on the counterparty's wallet
    ///      would be a fix for DexFi's risk and not for Recoup's.
    function test_split_paysDexFiWhenRecoupsOwnWalletIsBlocked() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(recoupWallet, true);

        splitter.split();

        assertEq(usdc.balanceOf(dexfiWallet), 200e6, "DexFi is paid");
        assertEq(splitter.owedToWallet(recoupWallet), 800e6, "Recoup's leg is parked");
        assertEq(splitter.owedToWallet(dexfiWallet), 0);
    }

    /// @dev The second well-known ERC-20 failure shape: `transfer` returns false and moves
    ///      nothing, without reverting. `ok` alone would read that as a payment, which is
    ///      exactly what audit round 17 caught `DirectCallAdapter._trySweepUsdc` doing. Only the
    ///      balance delta tells the two apart, so this test is the one that would fail if
    ///      `_payOrPark` were ever simplified to trust the boolean.
    function test_split_parksALegWhoseTransferSilentlyReturnsFalse() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setSilentlyFails(dexfiWallet, true);

        splitter.split();

        assertEq(usdc.balanceOf(recoupWallet), 800e6, "the healthy leg still lands");
        assertEq(splitter.owedToWallet(dexfiWallet), 200e6, "the silent failure is parked, not lost");
        assertEq(usdc.balanceOf(address(splitter)), 200e6);
    }

    /// @dev Both legs blocked at once. `split()` must still succeed, because the accrual is the
    ///      part that matters and the delivery is best-effort - and because reverting here would
    ///      leave the money uncredited, which is the pre-fix state under a different name.
    function test_split_parksBothLegsWhenNeitherWalletCanTakeDelivery() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(recoupWallet, true);
        usdc.setBlocked(dexfiWallet, true);

        splitter.split();

        assertEq(splitter.owedToWallet(recoupWallet), 800e6);
        assertEq(splitter.owedToWallet(dexfiWallet), 200e6);
        assertEq(splitter.totalOwedToWallets(), 1_000e6, "every wei is owed to somebody");
        assertEq(usdc.balanceOf(address(splitter)), 1_000e6, "and every wei is still here");
        assertEq(splitter.unsplitBalance(), 0, "none of it is splittable a second time");
    }

    /// @dev Recovery, by a stranger. The escape is worthless if it needs the party that benefits
    ///      from the block to cooperate - and here that party would be Recoup, since Recoup is
    ///      the one who would otherwise keep DexFi's share sitting in a contract it cannot open.
    function test_flushLegTo_paysAParkedLegOnceTheBlockLifts() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(dexfiWallet, true);
        splitter.split();

        usdc.setBlocked(dexfiWallet, false);
        vm.prank(makeAddr("a passing stranger"));
        splitter.flushLegTo(dexfiWallet);

        assertEq(usdc.balanceOf(dexfiWallet), 200e6, "paid in full");
        assertEq(splitter.owedToWallet(dexfiWallet), 0);
        assertEq(splitter.totalOwedToWallets(), 0);
        assertEq(usdc.balanceOf(address(splitter)), 0, "and nothing is left behind");
    }

    /// @dev The property that makes the escape safe: the argument is a mapping key, not a
    ///      destination. A caller cannot name their own address, cannot name DexFi's parked leg
    ///      into Recoup's wallet, and gets nothing for trying.
    function test_flushLegTo_grantsNoAuthorityOverWhereTheMoneyGoes() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(dexfiWallet, true);
        splitter.split();

        // expectRevert before prank, never after: a prank is spent by the next call, and this
        // suite has burned one on a cheatcode-shaped line before.
        address thief = makeAddr("thief");
        vm.expectRevert(ProtocolFeeSplitter.NothingToFlush.selector);
        vm.prank(thief);
        splitter.flushLegTo(thief);

        // Recoup has already been paid, so its key is empty too - there is no second call that
        // moves DexFi's parked leg anywhere except to DexFi.
        vm.expectRevert(ProtocolFeeSplitter.NothingToFlush.selector);
        splitter.flushLegTo(recoupWallet);

        assertEq(usdc.balanceOf(thief), 0);
        assertEq(splitter.owedToWallet(dexfiWallet), 200e6, "still owed to the wallet that earned it");
    }

    function test_flushLegTo_rejectsTheZeroAddressAndAnEmptyLeg() public {
        vm.expectRevert(ProtocolFeeSplitter.ZeroAddress.selector);
        splitter.flushLegTo(address(0));

        vm.expectRevert(ProtocolFeeSplitter.NothingToFlush.selector);
        splitter.flushLegTo(dexfiWallet);
    }

    /// @dev A flush into a wallet that is still blocked must revert and leave the checkpoint
    ///      standing. Silently re-parking would tell a caller who asked for exactly this payment
    ///      that it happened, which is the failure mode `CreditManager.flushPrincipalTo`'s
    ///      docstring refuses in the same words.
    function test_flushLegTo_revertsAndKeepsTheCheckpointWhileTheBlockStands() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(dexfiWallet, true);
        splitter.split();

        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, dexfiWallet));
        splitter.flushLegTo(dexfiWallet);

        assertEq(splitter.owedToWallet(dexfiWallet), 200e6, "the checkpoint survives the failed flush");
        assertEq(splitter.totalOwedToWallets(), 200e6);
    }

    /// @dev **The correctness question the park creates, and the one a naive fix gets wrong.**
    ///      A parked leg is physically still in this contract. If `split()` kept sizing itself
    ///      from the raw balance, the next split would divide DexFi's parked 200.000000 all over
    ///      again and hand 80% of it to Recoup - the exact redirect this contract exists to make
    ///      impossible, introduced by the fix for a different one.
    function test_split_neverResplitsAParkedLeg() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(dexfiWallet, true);
        splitter.split();

        // A second fee arrives while DexFi is still blocked.
        usdc.mint(address(splitter), 1_000e6);
        assertEq(splitter.unsplitBalance(), 1_000e6, "only the new money is splittable");

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(toRecoup, 800e6, "sized from the new fee alone");
        assertEq(toDexFi, 200e6);
        assertEq(usdc.balanceOf(recoupWallet), 1_600e6, "Recoup got its two legs and not a wei more");
        assertEq(splitter.owedToWallet(dexfiWallet), 400e6, "DexFi's parked legs accumulate intact");

        usdc.setBlocked(dexfiWallet, false);
        splitter.flushLegTo(dexfiWallet);
        assertEq(usdc.balanceOf(dexfiWallet), 400e6, "and are paid in full at the agreed ratio");
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    /// @dev A third call after recovery must not double-pay: `split()` reverts on an empty
    ///      unsplit balance even while a parked leg is sitting here, because a parked leg is not
    ///      unsplit money.
    function test_split_revertsWhileTheOnlyBalanceHereIsSomebodyElsesParkedLeg() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(dexfiWallet, true);
        splitter.split();

        assertEq(usdc.balanceOf(address(splitter)), 200e6, "there is a balance");
        vm.expectRevert(ProtocolFeeSplitter.NothingToSplit.selector);
        splitter.split();
    }

    /// @dev DISCRIMINATION CONTROL. With healthy wallets the fixed contract must produce exactly
    ///      the numbers the atomic one did, or every test above is measuring the rewrite rather
    ///      than the park.
    function test_split_discriminates_nothingParksOnTheHappyPath() public {
        usdc.mint(address(splitter), 1_000e6);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(toRecoup, 800e6);
        assertEq(toDexFi, 200e6);
        assertEq(usdc.balanceOf(recoupWallet), 800e6);
        assertEq(usdc.balanceOf(dexfiWallet), 200e6);
        assertEq(splitter.owedToWallet(recoupWallet), 0, "no park on either leg");
        assertEq(splitter.owedToWallet(dexfiWallet), 0);
        assertEq(splitter.totalOwedToWallets(), 0);
        assertEq(splitter.unsplitBalance(), 0);
    }

    /// @dev DISCRIMINATION CONTROL, the other way. `MockUSDC.setBlocked` really does stop a
    ///      transfer, so the parks above are not a mock that quietly does nothing.
    function test_split_discriminates_theBlockIsRealAndReverts() public {
        usdc.mint(address(this), 1e6);
        usdc.setBlocked(dexfiWallet, true);

        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, dexfiWallet));
        usdc.transfer(dexfiWallet, 1e6);
    }

    /// @dev The accounting invariant the park has to keep: this contract can never owe more than
    ///      it holds, whatever sequence of arrivals, blocks and flushes it is put through.
    ///
    ///      **`destroy` is audit round 25 F2's reconciliation of this test, and it is the reason
    ///      the invariant was worth less than it looked.** Before the write-down existed this
    ///      test could only ever run the side a burn does not break: nothing in it destroyed
    ///      USDC, so `balance >= totalOwedToWallets` held by construction and a suite that was
    ///      entirely green pinned the behaviour the finding was about. With a burn in the
    ///      sequence the invariant is now a claim rather than an identity - it holds because
    ///      `_realiseDestruction` charges the shortfall to the parked legs, and it is the
    ///      assertion that fails first if that stops happening.
    ///
    ///      The burn is placed where every party's money is parked and none has arrived since,
    ///      which is the one point at which the shortfall is attributable at all. The window
    ///      that closes is the subject of
    ///      `test_A26_08_aFeeArrivingBeforeAnybodyLooksStillSocialisesTheLoss`, and this test
    ///      deliberately does not wander into it: a fuzzer that sometimes hid the burn would
    ///      make the final conservation assertion below sometimes false and sometimes not.
    function testFuzz_park_neverOwesMoreThanItHolds(
        uint256 first,
        uint256 second,
        uint256 destroy,
        bool blockDexfi,
        bool blockRecoup
    ) public {
        first = bound(first, 1, 1e18);
        second = bound(second, 1, 1e18);

        usdc.mint(address(splitter), first);
        usdc.setBlocked(dexfiWallet, blockDexfi);
        usdc.setBlocked(recoupWallet, blockRecoup);
        splitter.split();
        assertLe(splitter.totalOwedToWallets(), usdc.balanceOf(address(splitter)));

        // Everything still here is parked - `split()` leaves no unsplit balance - so whatever
        // the issuer destroys now is parked money and belongs on the parked legs.
        destroy = bound(destroy, 0, usdc.balanceOf(address(splitter)));
        if (destroy != 0) {
            uint256 owedBefore = splitter.totalOwedToWallets();
            _destroy(destroy);
            assertEq(splitter.destroyedDeficit(), destroy, "the whole burn is visible while nothing has arrived");
            assertEq(splitter.reconcileDestroyedLegs(), destroy, "and the whole burn is charged to the legs");
            assertEq(splitter.totalOwedToWallets(), owedBefore - destroy, "not to the next fee");
            assertLe(splitter.totalOwedToWallets(), usdc.balanceOf(address(splitter)));
        }

        usdc.mint(address(splitter), second);
        splitter.split();
        assertLe(splitter.totalOwedToWallets(), usdc.balanceOf(address(splitter)));

        // Everything owed is payable once the blocks lift, and nothing else is left behind.
        usdc.setBlocked(dexfiWallet, false);
        usdc.setBlocked(recoupWallet, false);
        if (splitter.owedToWallet(dexfiWallet) != 0) splitter.flushLegTo(dexfiWallet);
        if (splitter.owedToWallet(recoupWallet) != 0) splitter.flushLegTo(recoupWallet);

        assertEq(splitter.totalOwedToWallets(), 0);
        assertEq(usdc.balanceOf(address(splitter)), 0, "the whole of both fees left");
        assertEq(
            usdc.balanceOf(recoupWallet) + usdc.balanceOf(dexfiWallet),
            first + second - destroy,
            "and the only USDC nobody received is the USDC that stopped existing"
        );
    }

    /// @dev The events are the only record either party has of a leg that did not land, so they
    ///      are asserted rather than assumed. `LegParked` reports the wallet's whole owed balance
    ///      alongside the increment, matching `EpochHarvester.ProtocolFeeParked`.
    function test_split_emitsTheParkAndTheLaterFlush() public {
        usdc.mint(address(splitter), 1_000e6);
        usdc.setBlocked(dexfiWallet, true);

        vm.expectEmit(true, false, false, true, address(splitter));
        emit ProtocolFeeSplitter.LegParked(dexfiWallet, 200e6, 200e6);
        splitter.split();

        usdc.setBlocked(dexfiWallet, false);
        vm.expectEmit(true, false, false, true, address(splitter));
        emit ProtocolFeeSplitter.LegFlushed(dexfiWallet, 200e6);
        splitter.flushLegTo(dexfiWallet);
    }

    // ── a destroyed parked leg (audit round 25, finding F2) ──────────────────
    //
    // The round-23 park gave a blocked leg somewhere to wait. It gave it no way to shrink, and
    // USDC's issuer can destroy a balance in place under the same policy that motivates the
    // park. The tests below are about who pays for that destruction. Before the fix the answer
    // was "both parties, 80/20", including the one whose leg was still intact.

    /// @dev USDC's issuer destroying a blocked balance in place, which is the case
    ///      `_unsplit`'s clamp names. `deal` with `adjust` moves the token's own total supply
    ///      too, so this is a destruction rather than a transfer somewhere else. The difference
    ///      does not change this contract's arithmetic, but it is the thing being modelled, and
    ///      a fixture that quietly did nothing would make every test below vacuous.
    ///      `test_A26_08_discriminates_theDestructionIsReal` is that check.
    function _destroy(uint256 amount) internal {
        uint256 balance = usdc.balanceOf(address(splitter));
        require(balance >= amount, "fixture: cannot destroy more than is here");
        deal(address(usdc), address(splitter), balance - amount, true);
    }

    /// @dev DISCRIMINATION CONTROL. The destruction really removes USDC, from this contract and
    ///      from the supply, rather than being a cheatcode that no-ops on this mock.
    function test_A26_08_discriminates_theDestructionIsReal() public {
        usdc.mint(address(splitter), 1_000e6);
        uint256 supplyBefore = usdc.totalSupply();

        _destroy(200e6);

        assertEq(usdc.balanceOf(address(splitter)), 800e6, "the balance really fell");
        assertEq(usdc.totalSupply(), supplyBefore - 200e6, "and so did the supply");
    }

    /// @dev THE FINDING, and the measurement it was filed on. 1,500.000000 of fee arrives in two
    ///      tranches with DexFi blocked throughout, and 200.000000 of DexFi's parked leg is
    ///      destroyed in place between them. The destroyed USDC was provably DexFi's - it was
    ///      the entire contents of this address at that moment - and the loss must fall there.
    ///
    ///      MEASURED against the pre-fix contract: Recoup was paid **1,040.000000** against a
    ///      1,200.000000 entitlement, DexFi 260.000000 against 300.000000, and the splitter
    ///      ended at 0. The 160.000000 Recoup lost is exactly 80% of the 200.000000 burn,
    ///      because the burn stayed inside `totalOwedToWallets`, was held back out of the next
    ///      split, and was therefore divided in the agreed ratio between the party that had
    ///      incurred it and the party that had not.
    function test_A26_08_aDestroyedParkedLegFallsOnTheLegItWasDestroyedFrom() public {
        usdc.setBlocked(dexfiWallet, true);

        usdc.mint(address(splitter), 1_000e6);
        splitter.split();
        assertEq(usdc.balanceOf(recoupWallet), 800e6, "first tranche: Recoup paid");
        assertEq(splitter.owedToWallet(dexfiWallet), 200e6, "first tranche: DexFi parked");
        assertEq(usdc.balanceOf(address(splitter)), 200e6, "and that park is the whole balance here");

        _destroy(200e6);
        assertEq(usdc.balanceOf(address(splitter)), 0);
        assertEq(splitter.destroyedDeficit(), 200e6, "the shortfall is visible before anything else arrives");

        // Anybody may record it, and it is recorded before the next fee lands.
        assertEq(splitter.reconcileDestroyedLegs(), 200e6);
        assertEq(splitter.owedToWallet(dexfiWallet), 0, "the whole loss fell on the leg it was destroyed from");
        assertEq(splitter.owedToWallet(recoupWallet), 0);
        assertEq(splitter.totalOwedToWallets(), 0);
        assertEq(splitter.destroyedDeficit(), 0);

        // The rest of the fee arrives and is split over nothing but itself.
        usdc.mint(address(splitter), 500e6);
        splitter.split();

        usdc.setBlocked(dexfiWallet, false);
        splitter.flushLegTo(dexfiWallet);

        assertEq(usdc.balanceOf(recoupWallet), 1_200e6, "Recoup's whole 80% of the 1,500.000000 that arrived");
        assertEq(usdc.balanceOf(dexfiWallet), 100e6, "DexFi's 20%, less the whole of its own destroyed leg");
        assertEq(usdc.balanceOf(address(splitter)), 0, "and nothing left here");
    }

    /// @dev THE LIMIT OF THE FIX, pinned rather than described, because a partial fix read as a
    ///      whole one is worse than none.
    ///
    ///      The write-down can only run while the shortfall is visible. If a fee arrives before
    ///      anybody calls `reconcileDestroyedLegs`, the shortfall is gone for good:
    ///      `balance - totalOwedToWallets` cannot tell 1,500.000000 arriving after a 200.000000
    ///      burn from 1,300.000000 arriving after no burn at all, and nothing this contract can
    ///      be asked distinguishes them. This is the same sequence as the test above with the
    ///      one call removed, and it still ends 1,040.000000 / 260.000000 - the pre-fix numbers.
    ///
    ///      Kept green deliberately. If a later change closes the window, this test fails and
    ///      the right response is to celebrate and rewrite it, not to loosen it.
    function test_A26_08_aFeeArrivingBeforeAnybodyLooksStillSocialisesTheLoss() public {
        usdc.setBlocked(dexfiWallet, true);

        usdc.mint(address(splitter), 1_000e6);
        splitter.split();

        _destroy(200e6);

        // Nobody looks. The fee lands first and hides the shortfall.
        usdc.mint(address(splitter), 500e6);
        assertEq(splitter.destroyedDeficit(), 0, "the burn is no longer distinguishable from a smaller fee");

        splitter.split();
        usdc.setBlocked(dexfiWallet, false);
        splitter.flushLegTo(dexfiWallet);

        assertEq(usdc.balanceOf(recoupWallet), 1_040e6, "still short by 160.000000, which is 80% of the burn");
        assertEq(usdc.balanceOf(dexfiWallet), 260e6);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    /// @dev The other half of the finding, and the one that needed no window. A leg whose USDC
    ///      was destroyed is owed a figure this contract can no longer transfer, so before the
    ///      fix `flushLegTo` reverted on every call - MEASURED as OpenZeppelin's
    ///      `ERC20InsufficientBalance`, permanently, on a contract with no owner and no rescue.
    ///      The leg was not merely short, it was bricked, and `split()` was bricked with it
    ///      until enough new fee arrived to cover a claim that no longer had money behind it.
    ///
    ///      Afterwards the leg reverts `NothingToFlush`, which is the truth: there is nothing
    ///      there. The write-down is what makes that true rather than merely reported.
    function test_A26_08_aDestroyedLegNoLongerBricksItsOwnFlushOrTheNextSplit() public {
        usdc.setBlocked(dexfiWallet, true);
        usdc.mint(address(splitter), 1_000e6);
        splitter.split();

        _destroy(200e6);
        usdc.setBlocked(dexfiWallet, false);

        assertEq(splitter.reconcileDestroyedLegs(), 200e6);

        vm.expectRevert(ProtocolFeeSplitter.NothingToFlush.selector);
        splitter.flushLegTo(dexfiWallet);

        // And the contract works again. MEASURED before the fix with exactly this 100.000000
        // sitting here: `unsplitBalance()` read 0 and `split()` reverted `NothingToSplit`,
        // because the clamp held the whole balance back against a claim with nothing behind it.
        // Both legs were stopped by the destruction of one.
        usdc.mint(address(splitter), 100e6);
        (uint256 toRecoup, uint256 toDexFi) = splitter.split();
        assertEq(toRecoup, 80e6);
        assertEq(toDexFi, 20e6);
        assertEq(usdc.balanceOf(dexfiWallet), 20e6, "and DexFi is paid again from the next fee");
    }

    /// @dev Both legs parked, so nothing here can say whose USDC was taken, and proportion is
    ///      the honest default. 333 wei is destroyed out of a 1,000.000000 pot parked 800/200:
    ///      DexFi's share floors to 66 and Recoup takes the remaining 267, so the sub-unit falls
    ///      on Recoup. That is `split()`'s rounding rule pointed the other way - the party
    ///      operating the contract takes the odd wei in both directions - and it is asserted
    ///      here rather than left to a comment because Floor and Ceil are one integer apart on
    ///      exactly the round figures this contract deals in.
    function test_A26_08_bothLegsParkedShareTheLossInProportionWithTheDustOnRecoup() public {
        usdc.setBlocked(dexfiWallet, true);
        usdc.setBlocked(recoupWallet, true);
        usdc.mint(address(splitter), 1_000e6);
        splitter.split();
        assertEq(splitter.owedToWallet(recoupWallet), 800e6);
        assertEq(splitter.owedToWallet(dexfiWallet), 200e6);

        _destroy(333);
        assertEq(splitter.reconcileDestroyedLegs(), 333);

        assertEq(splitter.owedToWallet(dexfiWallet), 200e6 - 66, "20% of 333 floors to 66");
        assertEq(splitter.owedToWallet(recoupWallet), 800e6 - 267, "and Recoup carries the remaining 267");
        assertEq(splitter.totalOwedToWallets(), 1_000e6 - 333, "the two cuts sum to the deficit exactly");
        assertEq(splitter.totalOwedToWallets(), usdc.balanceOf(address(splitter)));

        usdc.setBlocked(dexfiWallet, false);
        usdc.setBlocked(recoupWallet, false);
        splitter.flushLegTo(dexfiWallet);
        splitter.flushLegTo(recoupWallet);
        assertEq(usdc.balanceOf(dexfiWallet) + usdc.balanceOf(recoupWallet), 1_000e6 - 333);
        assertEq(usdc.balanceOf(address(splitter)), 0, "and no wei is left behind by the rounding");
    }

    /// @dev The write-down grants no authority, on the same terms as `flushLegTo` and for the
    ///      same reason: it takes no destination, no amount and no discretion. It cannot even be
    ///      made to run - the only state it acts on is a shortfall nothing inside this contract
    ///      can create, because `split()` credits only what is here and `flushLegTo` decrements
    ///      by exactly what it moved.
    function test_A26_08_reconcileIsPermissionlessAndPaysItsCallerNothing() public {
        usdc.setBlocked(dexfiWallet, true);
        usdc.mint(address(splitter), 1_000e6);
        splitter.split();
        _destroy(200e6);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        uint256 writtenDown = splitter.reconcileDestroyedLegs();

        assertEq(writtenDown, 200e6);
        assertEq(usdc.balanceOf(stranger), 0, "the caller gets nothing for calling");
        assertEq(splitter.recoupWallet(), recoupWallet, "and the legs are where they were");
        assertEq(splitter.dexfiWallet(), dexfiWallet);
    }

    /// @dev Reverts rather than no-opping when there is nothing to write down, on `flushLegTo`'s
    ///      reasoning: this is called by somebody who has read `destroyedDeficit` and wants the
    ///      write-down recorded. Telling them one happened when none did is how a stale figure
    ///      survives a reconciliation.
    function test_A26_08_reconcileRevertsWhenNothingWasDestroyed() public {
        vm.expectRevert(ProtocolFeeSplitter.NothingToReconcile.selector);
        splitter.reconcileDestroyedLegs();

        usdc.setBlocked(dexfiWallet, true);
        usdc.mint(address(splitter), 1_000e6);
        splitter.split();

        assertEq(splitter.destroyedDeficit(), 0, "a parked leg is not a shortfall");
        vm.expectRevert(ProtocolFeeSplitter.NothingToReconcile.selector);
        splitter.reconcileDestroyedLegs();
    }

    /// @dev The write-down inside `flushLegTo` earns its place here rather than in a separate
    ///      call: DexFi asks for its leg, and gets what is left of it, without having to know
    ///      that a write-down is a thing. MEASURED before the fix, in exactly this state: the
    ///      call reverted `ERC20InsufficientBalance(splitter, 150000000, 200000000)` and went on
    ///      doing so forever, so a leg that had lost a quarter of itself paid nothing at all.
    function test_A26_08_aPartlyDestroyedLegPaysWhatIsLeftWithoutASeparateCall() public {
        usdc.setBlocked(dexfiWallet, true);
        usdc.mint(address(splitter), 1_000e6);
        splitter.split();

        _destroy(50e6);
        usdc.setBlocked(dexfiWallet, false);

        splitter.flushLegTo(dexfiWallet);

        assertEq(usdc.balanceOf(dexfiWallet), 150e6, "what was left of the leg, and no more");
        assertEq(splitter.owedToWallet(dexfiWallet), 0);
        assertEq(splitter.totalOwedToWallets(), 0);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    /// @dev WHY THERE IS NO WRITE-DOWN INSIDE `split()`, asserted rather than asserted-in-a-
    ///      comment. Realising a destruction leaves `totalOwedToWallets == balance` by
    ///      construction, so the unsplit pot is empty by the time `split()` would size itself
    ///      and the call reverts `NothingToSplit` - taking its own write-down down with it.
    ///      A `_realiseDestruction()` at the top of `split()` therefore cannot ever persist an
    ///      effect, and a guard that only runs in calls that revert is worse than no guard,
    ///      because it reads like protection.
    ///
    ///      This is the state where it looked most useful: a shortfall is visible, and there is
    ///      new money here too. `reconcileDestroyedLegs` is the call that works, which is what
    ///      it is for.
    ///
    ///      It also prices the window in one line. 150.000000 is destroyed and 100.000000
    ///      arrives before anybody looks, so only **50.000000** of the burn is still
    ///      attributable and the other 100.000000 has already been absorbed into DexFi's claim
    ///      at Recoup's expense. The arrival hides the burn one-for-one.
    function test_A26_08_splitCannotRecordAWriteDownBecauseItWouldHaveNothingToSplit() public {
        usdc.setBlocked(dexfiWallet, true);
        usdc.mint(address(splitter), 1_000e6);
        splitter.split();

        _destroy(150e6);
        usdc.mint(address(splitter), 100e6);
        assertEq(splitter.destroyedDeficit(), 50e6, "still visible: the burn outran the arrival");

        vm.expectRevert(ProtocolFeeSplitter.NothingToSplit.selector);
        splitter.split();

        assertEq(splitter.totalOwedToWallets(), 200e6, "and nothing was recorded by trying");

        assertEq(splitter.reconcileDestroyedLegs(), 50e6, "only the part the arrival did not hide");
        assertEq(splitter.totalOwedToWallets(), 150e6);
        assertEq(splitter.destroyedDeficit(), 0);

        // Still nothing to split: a write-down always leaves the pot exactly covering the legs.
        vm.expectRevert(ProtocolFeeSplitter.NothingToSplit.selector);
        splitter.split();

        usdc.mint(address(splitter), 100e6);
        (uint256 toRecoup, uint256 toDexFi) = splitter.split();
        assertEq(toRecoup, 80e6, "and the next fee splits over itself alone");
        assertEq(toDexFi, 20e6);
    }

    /// @dev The event is the only record either party has that a claim was written off, so it is
    ///      asserted rather than assumed. `LegWrittenDown` reports what the wallet has left,
    ///      the way `LegParked` reports what it has just gained.
    function test_A26_08_emitsTheWriteDownAgainstTheLegThatBoreIt() public {
        usdc.setBlocked(dexfiWallet, true);
        usdc.mint(address(splitter), 1_000e6);
        splitter.split();
        _destroy(50e6);

        vm.expectEmit(true, false, false, true, address(splitter));
        emit ProtocolFeeSplitter.LegWrittenDown(dexfiWallet, 50e6, 150e6);
        splitter.reconcileDestroyedLegs();
    }

    // ── the integration it exists for ─────────────────────────────────────────
    //
    // Proved end to end in `EpochHarvester.t.sol`, not here:
    // `test_harvest_protocolFeeSplitsWithDexFiWhenTheSplitterIsTheFeeWallet` runs a real
    // epoch, flushes the fee into this contract and splits it. That belongs where the
    // full wiring already exists, and it is the test that would fail if the payout ever
    // became an approve-and-call the way the lender leg is.
}
