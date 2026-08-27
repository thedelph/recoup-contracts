// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round-23 finding 16: the pool's own address is the withdrawal queue's escrow, so a
///         share arriving there by any door other than `requestWithdrawal` mints principal-
///         accounting units that no queue entry claims and nothing can ever retire.
/// @dev **The finding named one door and there are four.** MEASURED on the pre-fix contract in
///      this worktree, from a 10,000.000000 book:
///
///      | door | escrow units with no entry behind them |
///      | --- | --- |
///      | `transfer(address(this), 25)` | 1 |
///      | `transferFrom(alice, address(this), 25)` | 1 |
///      | `deposit(1_000e6, address(this))` | 1,000,000,000 |
///      | `mint(1_000e9, address(this))` | 1,000,000,000 |
///
///      The ledger's bound of "one asset-wei per transaction" is a fact about the transfer door
///      alone. The two ERC-4626 doors are the same defect at arbitrary size - a lender can strand
///      the whole deposit cap in one call - so all four are shut, not the two that were named.
///
///      The direction is what makes it worth a revert rather than a tolerance. The orphaned units
///      hold `netDeposits`, and `netDeposits` is the sole input to `maxDeposit`, so the strand is
///      deposit-cap headroom that never comes back. That is the cap-BRICK direction, opposite to
///      all four residuals round-22 finding 3 discloses, and two bounded errors in opposite
///      directions do not cancel - they widen the band.
///
///      And it buys a detector. The only candidate fix still standing for audit round 23's open
///      finding on principal-unit growth turns `escrow units == sum of live request units` from an
///      equality into a bounded inequality, which is a weaker detector for exactly this bug. With
///      these doors shut, the only route into escrow is `requestWithdrawal`, so a future bound can
///      be derived from the live entries rather than picked to make the suite pass.
///
/// @dev **AND THERE WAS A FIFTH, found by audit round 24 and shut in the same idiom.** The four
///      above are all about a *share* reaching this address. `requestWithdrawal(shares, address(pool))`
///      is the same class one field along: the queue entry it writes names the escrow as its
///      **receiver**, so `serviceQueue` books real USDC under `claimable[address(pool)]`. That is
///      not stranded units, it is a strand in the *cash* accounting, and it moves the opposite way -
///      `_poolBalance()` subtracts `totalClaimable`, so the book under-reports until somebody calls
///      the permissionless `claimFor(address(pool))` and the whole strand rejoins the share price in
///      one block. MEASURED on the unguarded contract, in this file's own fixture:
///
///      | quantity | before the strand is collected | after |
///      | --- | --- | --- |
///      | `convertToAssets(1e9)` | 1.000000 | 1.999999 |
///      | a stranger's round trip, zero seconds of exposure | 6,000.000000 in | 11,999.999999 out |
///
///      The incumbent's loss and the stranger's gain agree to within 2 wei, which is what says this
///      is a transfer between lenders timed by a third party rather than a rounding residue. Same
///      remedy, same error, same reason: refuse, so that `claimable[address(pool)] == 0` is a
///      standing fact and the invariants can read it as one.
contract LenderPoolEscrowStrandTest is Test {
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
            usdc.mint(who[i], 100_000e6);
            vm.prank(who[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    /// @dev Walks the entries rather than reading a counter. A checker that read a counter the
    ///      contract also maintains would agree with it by construction.
    function _sumLiveQueueUnits() private view returns (uint256 sum) {
        uint256 length = pool.queueLength();
        for (uint256 i = 0; i < length; i++) {
            sum += pool.queueEntryPrincipalUnits(i);
        }
    }

    /// @dev Finding 16's signature: escrow units in excess of what the live entries claim.
    function _escrowGap() private view returns (uint256) {
        return pool.principalUnits(address(pool)) - _sumLiveQueueUnits();
    }

    function _seedAlice() private {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);
    }

    // -- the four doors, shut ------------------------------------------------

    function test_F16_theTransferDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.transfer(address(pool), 25);

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    function test_F16_theTransferFromDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        pool.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.transferFrom(alice, address(pool), 25);

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    function test_F16_theDepositDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.deposit(1_000e6, address(pool));

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    function test_F16_theMintDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.mint(1_000e9, address(pool));

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    /// @dev The cap counter is the thing the strand damages, so assert it directly rather than
    ///      only through the units. A refused door moves neither the counter nor the headroom.
    function test_F16_aRefusedDoorMovesNeitherTheCounterNorTheHeadroom() public {
        _seedAlice();
        uint256 netBefore = pool.netDeposits();
        uint256 roomBefore = pool.maxDeposit(alice);
        uint256 unitsBefore = pool.totalPrincipalUnits();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.deposit(1_000e6, address(pool));

        assertEq(pool.netDeposits(), netBefore, "netDeposits moved on a refused call");
        assertEq(pool.maxDeposit(alice), roomBefore, "headroom moved on a refused call");
        assertEq(pool.totalPrincipalUnits(), unitsBefore, "units moved on a refused call");
    }

    // -- and nothing legitimate is lost --------------------------------------

    /// @dev The half of the recorded measurement that is not about the strand: "with the queue
    ///      still servicing". `_requestWithdrawal` reaches escrow through the internal `_transfer`,
    ///      below the doors this change guards, so a full queue round trip is unaffected.
    function test_F16_theQueueStillServicesThroughTheShutDoor() public {
        _seedAlice();
        vm.prank(bob);
        pool.deposit(10_000e6, bob);

        // Reads before the prank: an external staticcall in argument position spends it.
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        assertEq(pool.queuedShares(), bobShares, "escrow did not take the shares");
        assertEq(_escrowGap(), 0, "requestWithdrawal left units with no entry behind them");
        assertGt(pool.principalUnits(address(pool)), 0, "escrow took no units at all");

        pool.serviceQueue(5);
        uint256 owed = pool.claimable(bob);
        assertGt(owed, 0, "the queue serviced nothing");

        vm.prank(bob);
        uint256 paid = pool.claim();
        assertEq(paid, owed, "claim paid something other than what was owed");
        assertEq(pool.queuedShares(), 0, "the queue did not drain");
        assertEq(_escrowGap(), 0, "the drained queue left units in escrow");
    }

    function test_F16_cancelStillReturnsTheSharesThroughTheShutDoor() public {
        _seedAlice();

        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        assertEq(_escrowGap(), 0, "requestWithdrawal left units with no entry behind them");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();

        assertEq(pool.balanceOf(alice), aliceShares, "cancel did not return the shares");
        assertEq(pool.balanceOf(address(pool)), 0, "escrow kept shares after a cancel");
        assertEq(_escrowGap(), 0, "cancel left units in escrow");
    }

    /// @dev The guard is on this contract's address and on nothing else. A holder who wants to
    ///      give shares away can still do it - including to the credit manager and the harvester,
    ///      neither of which is escrow.
    function test_F16_everyOtherDestinationStillWorks() public {
        _seedAlice();

        vm.prank(alice);
        pool.transfer(bob, 1_000);
        assertEq(pool.balanceOf(bob), 1_000, "actor-to-actor transfer refused");

        vm.prank(alice);
        pool.deposit(1_000e6, carol);
        assertGt(pool.balanceOf(carol), 0, "deposit to a third party refused");

        vm.prank(alice);
        pool.transfer(creditManager, 1_000);
        assertEq(pool.balanceOf(creditManager), 1_000, "transfer to the credit manager refused");
    }

    /// @dev A self-transfer is a no-op the ERC-20 standard allows and this guard must not catch:
    ///      the predicate is `to == address(this)`, not `to == msg.sender`.
    function test_F16_aHoldersSelfTransferIsNotThisDoor() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        vm.prank(alice);
        pool.transfer(alice, held);

        assertEq(pool.balanceOf(alice), held, "a self-transfer was refused or lost shares");
    }
    // -- and the bounded doors #262 added, covered by delegation -------------

    /// @dev **A dependency, not a coincidence, so it is asserted rather than assumed.** The
    ///      EIP-5143 overloads land on this branch by a merge: they were written against a tree
    ///      that had no escrow guard, and they reach escrow only through the two-argument doors
    ///      above, which is why they are shut without a line of their own. That is true of the
    ///      bodies as written and would stop being true the moment either overload called
    ///      `_deposit` directly to save a hop. These two tests are what would notice.
    function test_F16_theBoundedDepositDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.deposit(1_000e6, address(pool), 0);

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    function test_F16_theBoundedMintDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.mint(1_000e9, address(pool), type(uint256).max);

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    // -- the fifth door, one field along: the queue entry's RECEIVER ----------

    /// @dev The guard itself. The four above are about a share arriving at this address; this one
    ///      is about the entry naming this address as the party the money is set aside for.
    function test_A24_theWithdrawalReceiverDoorIsShut() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.requestWithdrawal(held, address(pool));

        assertEq(pool.queuedShares(), 0, "the escrow took shares for an entry it had to refuse");
        assertEq(pool.queueLength(), 0, "a refused request still landed in the queue");
        assertEq(pool.claimable(address(pool)), 0, "the escrow was booked as its own payee");
        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    /// @notice The finding as the executed trace rather than as the guard: a share-price step
    ///         somebody else times, taken by an address with no prior exposure.
    ///
    /// @dev **This is the test that goes red when the guard is neutered, and it is written to fail
    ///      on the harm rather than on the revert.** The request is offered inside a `try` and the
    ///      queue is serviced whatever it did, so with `EscrowIsNotAHolder` removed from
    ///      `_requestWithdrawal` the whole sequence executes and the assertions below are what
    ///      catches it - not a missing revert. NEUTERED and MEASURED in this worktree: with the
    ///      guard removed, `claimable(address(pool))` is 6,000.000000, `convertToAssets(1e9)` steps
    ///      from 1.000000 to 1.999999 in the block `claimFor` runs, and Bob - who deposits *after*
    ///      the strand exists and redeems in the same block it is collected - leaves with
    ///      11,999.999999 against the 6,000.000000 he brought.
    ///
    ///      Bob's leg matters as much as the price leg. A price that moves is not on its own a
    ///      finding; a price that moves at an instant a stranger chooses, in favour of somebody who
    ///      carried none of the risk, is. The step is a transfer to whoever holds shares in that
    ///      one block, and Bob decides which block that is. Alice loses her whole 6,000.000000
    ///      here because she is the only other party; MEASURED with a third lender of the same size
    ///      standing through it, the strand is split and Bob still leaves with 8,999.999999 for
    ///      6,000.000000 in, taking 2,999.999999 that would otherwise have gone to the lender who
    ///      held the risk. Neither number is a rounding residue.
    function test_A24_theEscrowCannotBeMadeItsOwnPayee() public {
        vm.prank(alice);
        pool.deposit(6_000e6, alice);

        uint256 priceAtPar = pool.convertToAssets(1e9);
        assertEq(priceAtPar, 1e6, "fixture: the book must start at par or the step is unreadable");

        // Arm it, or fail to. Either outcome is allowed here; what follows is not.
        uint256 held = pool.balanceOf(alice);
        vm.prank(alice);
        try pool.requestWithdrawal(held, address(pool)) {} catch {}
        try pool.serviceQueue(5) {} catch {}

        assertEq(pool.claimable(address(pool)), 0, "the queue set money aside for the escrow itself");
        assertEq(pool.totalClaimable(), 0, "the pool booked its own balance as owed to somebody");

        // The collection that would release the strand into the price. It has nothing to collect.
        vm.expectRevert(LenderPool.NothingToClaim.selector);
        pool.claimFor(address(pool));

        // And the stranger's round trip, which is where the money would actually have gone.
        vm.prank(bob);
        pool.deposit(6_000e6, bob);
        uint256 bobShares = pool.balanceOf(bob);

        vm.prank(bob);
        uint256 out = pool.redeem(bobShares, bob, bob);

        assertEq(pool.convertToAssets(1e9), priceAtPar, "the share price stepped inside one block");
        assertLe(out, 6_000e6, "a stranger with no prior exposure left with more than they brought");
    }

    /// @dev The half that must keep working, and the reason the guard names this address rather
    ///      than comparing the receiver with the owner: a queue entry may pay somebody other than
    ///      the lender who queued it, and the invariant campaign's USDC conservation check exists
    ///      to defend exactly that split.
    function test_A24_aRequestNamingAnyOtherReceiverStillWorks() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        vm.prank(alice);
        pool.requestWithdrawal(held, carol);

        assertEq(pool.queuedShares(), held, "a third-party receiver was refused");
        assertEq(_escrowGap(), 0, "the accepted request left units with no entry behind them");

        pool.serviceQueue(5);
        uint256 owed = pool.claimable(carol);
        assertGt(owed, 0, "the queue paid nothing to the named receiver");
        assertEq(pool.claimable(alice), 0, "the payout went to the owner rather than the receiver");

        vm.prank(carol);
        assertEq(pool.claim(), owed, "the named receiver could not collect");
    }

    // -- the four exit doors, shut: audit round 25 finding 1 -----------------

    /// @dev **The mirror the entry side already had, and it took three rounds to find.** Rounds 23
    ///      and 24 shut five doors by which the escrow could be handed a *share* or named as a
    ///      queue entry's payee. These four are the same address in the ERC-4626 `receiver` slot on
    ///      the way *out*: the shares burn, the USDC stays where it is, and the pool has bought
    ///      itself its own money. `_deposit` refuses the entry-side mirror of exactly this with
    ///      `ZeroAmount`, and `_update`'s comment states the rule - when a fix adds a guard, find
    ///      its mirror.
    ///
    ///      MEASURED on the unguarded contract in this fixture, one
    ///      `redeem(10_000e9, address(pool), bob)` from a 20,000.000000 book:
    ///
    ///      | quantity | before | after |
    ///      | --- | --- | --- |
    ///      | `usdc.balanceOf(pool)` | 20,000.000000 | 20,000.000000 |
    ///      | `totalSupply` | 20,000.000000000 | 10,000.000000000 |
    ///      | `convertToAssets(1e9)` | 1.000000 | 1.999999 |
    ///      | the honest incumbent's stake | 10,000.000000 | 19,999.999999 |
    ///
    ///      **Not extraction, and round 25's own finding 2 was refuted on that point end to end.**
    ///      The caller's PnL is -10,000.000000 and the incumbent's +9,999.999999, the two
    ///      agreeing to 1 wei: this is a donation, where the fifth door was a hidden subtraction a
    ///      stranger could time. It is
    ///      refused because a door that silently converts an exit into a gift is not a door.
    function test_A25F1_theWithdrawDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.withdraw(1_000e6, address(pool), alice);

        assertEq(pool.netDeposits(), 10_000e6, "a refused exit still debited the deposit cap");
        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    function test_A25F1_theRedeemDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.redeem(1_000e9, address(pool), alice);

        assertEq(pool.netDeposits(), 10_000e6, "a refused exit still debited the deposit cap");
        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    /// @dev **A dependency, not a coincidence, and the same assertion the two bounded entry doors
    ///      above carry.** The round-20 overloads reach the escrow only through the three-argument
    ///      doors, which is why two guard lines shut four doors and why the cost is +82 bytes and
    ///      not +164. That is true of the bodies as written and would stop being true the moment
    ///      either overload called `super.redeem` directly to save a hop. These two tests notice.
    function test_A25F1_theBoundedWithdrawDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.withdraw(1_000e6, address(pool), alice, type(uint256).max);

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    function test_A25F1_theBoundedRedeemDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.redeem(1_000e9, address(pool), alice, 0);

        assertEq(_escrowGap(), 0, "escrow units with no queue entry behind them");
    }

    /// @notice The finding as the executed trace rather than as the guard: a burn with no payout,
    ///         and the share-price step it hands to whoever is still holding.
    ///
    /// @dev **Written to fail on the harm rather than on the revert**, the same way
    ///      `test_A24_theEscrowCannotBeMadeItsOwnPayee` is. The redemption is offered inside a
    ///      `try`, so with `EscrowIsNotAHolder` removed from `redeem` the whole sequence executes
    ///      and the assertions below are what catches it. NEUTERED and MEASURED in this worktree:
    ///      the redemption returns 10,000.000000 having moved no USDC at all, `totalSupply` halves,
    ///      `convertToAssets(1e9)` goes 1.000000 -> 1.999999, and Bob - who did nothing - can take
    ///      19,999.999999 out for the 10,000.000000 he put in.
    ///
    ///      Alice's leg is the one that says this is not dust. She is not overcharged by a rounding
    ///      residue, she is paid **nothing**: her whole stake moves to the other side of the book in
    ///      one call, with the money never leaving the contract.
    function test_A25F1_anExitToTheEscrowBurnsTheSharesAndPaysNothing() public {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);
        vm.prank(bob);
        pool.deposit(10_000e6, bob);

        uint256 priceAtPar = pool.convertToAssets(1e9);
        assertEq(priceAtPar, 1e6, "fixture: the book must start at par or the step is unreadable");

        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        uint256 aliceCashBefore = usdc.balanceOf(alice);
        uint256 supplyBefore = pool.totalSupply();

        // Arm it, or fail to. Either outcome is allowed here; what follows is not.
        uint256 held = pool.balanceOf(alice);
        vm.prank(alice);
        try pool.redeem(held, address(pool), alice) {} catch {}

        assertEq(usdc.balanceOf(address(pool)), poolCashBefore, "shares burned and no USDC left the pool");
        assertEq(usdc.balanceOf(alice), aliceCashBefore, "the caller was paid, so this is a different trace");
        assertEq(pool.totalSupply(), supplyBefore, "the book shrank without paying anybody");
        assertEq(pool.balanceOf(alice), held, "the caller's stake was burned for nothing");
        assertEq(pool.convertToAssets(1e9), priceAtPar, "the share price stepped inside one call");

        // And the incumbent's round trip, which is where the money would actually have gone.
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        uint256 out = pool.redeem(bobShares, bob, bob);
        assertLe(out, 10_000e6, "an incumbent who did nothing left with more than they brought");
    }

    /// @notice The round-20 slippage bound is inert on this door and reports success.
    ///
    /// @dev **This is the second of the three things that make it the class rather than user
    ///      error, and it is the one a reader will not believe without executing it.** The bound
    ///      checks what the call *returned*, not what the caller *received*, so the strictest bound
    ///      expressible - `previewRedeem(shares)`, the exact quote, no slack at all - is satisfied
    ///      by a call that delivers zero. A caller using every protection this contract offers is
    ///      told their exit cleared at the quoted price.
    ///
    ///      NEUTERED and MEASURED: `redeem(10_000e9, address(pool), alice, previewRedeem(10_000e9))`
    ///      returns 10,000.000000, reverts nothing, and moves 0.000000 to anybody.
    ///
    ///      Asserted as the identity `returned == received` rather than as a revert, so it stays a
    ///      test about the bound and not about the guard. With the guard the call reverts, both
    ///      sides are zero, and the identity holds; without it the two disagree by the whole
    ///      redemption.
    function test_A25F1_theStrictestBoundExpressibleCannotSeeThisDoor() public {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);

        uint256 held = pool.balanceOf(alice);
        uint256 quote = pool.previewRedeem(held);
        assertGt(quote, 0, "fixture: the exit must be worth something or the bound proves nothing");

        uint256 escrowCashBefore = usdc.balanceOf(address(pool));

        uint256 reported;
        vm.prank(alice);
        try pool.redeem(held, address(pool), alice, quote) returns (uint256 assets) {
            reported = assets;
        } catch {}

        uint256 delivered = escrowCashBefore - usdc.balanceOf(address(pool));
        assertEq(reported, delivered, "the bound passed on a redemption that delivered less");
    }

    /// @notice The deposit-cap half, which is not self-harm and does not cancel round-23 finding 16.
    ///
    /// @dev **The third of the three, and the reason this is a protocol finding and not a footgun.**
    ///      `_burnPrincipalUnits` debits `netDeposits` whether or not an asset left, so an exit to
    ///      the escrow returns cap headroom the pool never gave back the money for. NEUTERED and
    ///      MEASURED: `netDeposits` 10,000.000000 -> 0 with the 10,000.000000 still in the
    ///      contract, `maxDeposit` restored to the full 25,000.000000 cap, and the next deposit
    ///      leaving this pool holding 35,000.000000 against a 25,000.000000 cap.
    ///
    ///      **That is the OPPOSITE direction to round-23 finding 16**, which stranded headroom and
    ///      bricked the cap. Two bounded errors in opposite directions do not cancel - they widen
    ///      the band from both ends, and a reader who nets them off gets a pool with no cap at all.
    function test_A25F1_anExitToTheEscrowDoesNotWidenTheDepositCap() public {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);

        uint256 cap = pool.depositCap();
        assertGt(cap, 10_000e6, "fixture: the cap must have headroom left or this proves nothing");

        uint256 held = pool.balanceOf(alice);
        vm.prank(alice);
        try pool.redeem(held, address(pool), alice) {} catch {}

        assertEq(pool.netDeposits(), 10_000e6, "the cap counter was credited for money that never left");
        assertEq(pool.maxDeposit(bob), cap - 10_000e6, "headroom came back without the money going out");

        // The consequence, executed: fill whatever headroom the pool now reports and weigh it.
        uint256 room = pool.maxDeposit(bob);
        vm.prank(bob);
        pool.deposit(room, bob);
        assertLe(usdc.balanceOf(address(pool)), cap, "the pool holds more lender capital than its cap allows");
    }

    // -- the whole door table, both directions -------------------------------

    /// @notice Every door on this contract that takes an address the escrow could be named in,
    ///         offered `address(pool)`, counted.
    ///
    /// @dev **A table of refusals is not a control, so this one is written to be run in both
    ///      directions and the other direction is recorded here.** With the guards in place it
    ///      reads 12 refused / 0 accepted. With round 25's two lines removed from `withdraw` and
    ///      `redeem` it reads **8 refused / 4 accepted** - the two three-argument exits and the two
    ///      round-20 overloads that delegate to them, which is the whole finding and also the proof
    ///      that the overloads carry no guard of their own.
    ///
    ///      **Eleven of the twelve refuse by a guard and the twelfth refuses by construction**, and
    ///      that distinction is worth the row. `claimFor(address(pool))` reverts `NothingToClaim`
    ///      because the `*For` family is pot-keyed: it can only pay out a balance some other writer
    ///      put in `claimable`, and round 24 shut the only writer that could put this address
    ///      there. There is deliberately no `EscrowIsNotAHolder` on it - a guard there would spend
    ///      bytecode defending a state that can no longer be created - but that closure is
    ///      inherited rather than local, so a future sibling that is *not* pot-keyed would not get
    ///      it. This row is where that is written down.
    ///
    ///      Each door is offered from a fresh snapshot, so an accepted door cannot change what the
    ///      next one is offered. Without that, neutering the guard burned Alice's shares on door 7
    ///      and doors 8 through 10 then had nothing to redeem - which would have reported the
    ///      accepted count as fewer than the four that are really open.
    function test_A25F1_theDoorTableRefusesTwelveAndAcceptsNone() public {
        _seedAlice();
        vm.prank(alice);
        pool.approve(bob, type(uint256).max);

        uint256 refused;
        uint256 accepted;
        uint256 refusedByTheGuard;
        uint256 refusedByConstruction;

        for (uint256 door = 0; door < 12; door++) {
            uint256 snapshot = vm.snapshotState();
            (bool doorAccepted, bytes4 selector) = _offerTheEscrowToDoor(door);
            vm.revertToState(snapshot);

            if (doorAccepted) {
                ++accepted;
                emit log_named_uint("door accepted the escrow", door);
            } else {
                ++refused;
                if (selector == LenderPool.EscrowIsNotAHolder.selector) {
                    ++refusedByTheGuard;
                } else {
                    assertEq(selector, LenderPool.NothingToClaim.selector, "door refused for an unrelated reason");
                    ++refusedByConstruction;
                }
            }
        }

        assertEq(accepted, 0, "a door accepted the escrow as receiver");
        assertEq(refused, 12, "the door table lost a door");
        assertEq(refusedByTheGuard, 11, "a door that should carry the guard refused for another reason");
        assertEq(refusedByConstruction, 1, "the pot-keyed row changed shape");
    }

    /// @dev The table itself, in one place so the count above and the count a reader makes by hand
    ///      cannot drift. Door order: the four round-23 share doors, the two round-23 bounded
    ///      entry doors, the round-24 queue receiver, the four round-25 exit doors, and the
    ///      pot-keyed collector.
    function _offerTheEscrowToDoor(uint256 door) private returns (bool, bytes4) {
        if (door == 0) {
            vm.prank(alice);
            try pool.transfer(address(pool), 25) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 1) {
            vm.prank(bob);
            try pool.transferFrom(alice, address(pool), 25) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 2) {
            vm.prank(alice);
            try pool.deposit(1_000e6, address(pool)) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 3) {
            vm.prank(alice);
            try pool.mint(1_000e9, address(pool)) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 4) {
            vm.prank(alice);
            try pool.deposit(1_000e6, address(pool), 0) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 5) {
            vm.prank(alice);
            try pool.mint(1_000e9, address(pool), type(uint256).max) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 6) {
            vm.prank(alice);
            try pool.requestWithdrawal(1_000e9, address(pool)) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 7) {
            vm.prank(alice);
            try pool.withdraw(1_000e6, address(pool), alice) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 8) {
            vm.prank(alice);
            try pool.redeem(1_000e9, address(pool), alice) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 9) {
            vm.prank(alice);
            try pool.withdraw(1_000e6, address(pool), alice, type(uint256).max) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else if (door == 10) {
            vm.prank(alice);
            try pool.redeem(1_000e9, address(pool), alice, 0) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        } else {
            // Pot-keyed and therefore permissionless, so the caller is deliberately a stranger.
            vm.prank(carol);
            try pool.claimFor(address(pool)) { return (true, bytes4(0)); }
            catch (bytes memory e) { return (false, bytes4(e)); }
        }
    }

    /// @dev The half that must keep working, and the reason the guard names this address rather
    ///      than comparing the receiver with the owner. An ERC-4626 exit paying somebody other than
    ///      the share owner is ordinary and is what `invariant_usdcIsConserved` defends; only this
    ///      one address is refused.
    function test_A25F1_anExitNamingAnyOtherReceiverStillWorks() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(alice);
        uint256 paid = pool.redeem(held / 2, carol, alice);
        assertGt(paid, 0, "a third-party receiver was paid nothing");
        assertEq(usdc.balanceOf(carol) - carolBefore, paid, "the payout did not reach the named receiver");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        pool.withdraw(100e6, bob, alice);
        assertEq(usdc.balanceOf(bob) - bobBefore, 100e6, "the withdraw door refused a third-party receiver");

        // And the bounded overloads, which is where a guard put in the wrong place would show up.
        vm.prank(alice);
        pool.redeem(1e9, carol, alice, 0);
        vm.prank(alice);
        pool.withdraw(1e6, bob, alice, type(uint256).max);
    }
}
