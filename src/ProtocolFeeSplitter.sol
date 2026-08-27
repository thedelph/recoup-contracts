// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Config} from "./Config.sol";

/// @title ProtocolFeeSplitter
/// @notice Splits Recoup's protocol fee between Recoup and DexFi on-chain, in the
///         `PROTOCOL_FEE_RECOUP_BPS` / `PROTOCOL_FEE_DEXFI_BPS` ratio agreed on
///         2026-08-06.
/// @dev Installed as `EpochHarvester.protocolFeeWallet`. That is the whole integration:
///      `flushProtocolFee` pays the fee out with a plain `safeTransfer`, so the fee
///      arrives here as an ordinary ERC-20 balance and **no core contract changes**.
///      A splitter is not the only way to honour the agreement - the alternative is
///      Chris sending DexFi a share every month - but a monthly transfer is a promise
///      and this is not. Both destinations are immutable and both shares are compiled
///      in, so **money that has arrived here cannot be redirected by either party**.
///
///      **Read that sentence narrowly, because the wider version of it was written here
///      first and audit round 21 refuted it by measurement.** It used to say "once
///      deployed neither party can redirect the other's leg, and neither needs to trust
///      the other to remember". The first half binds only the balance already at this
///      address; the second half was simply false. The fee accrues in
///      `EpochHarvester.pendingProtocolFee` and stays there until somebody calls
///      `flushProtocolFee` - deliberately, so a blacklisted wallet cannot stop an epoch -
///      and until that call lands, the money is behind `setProtocolFeeWallet`. MEASURED
///      over three 1,000.000000 epochs: with this splitter installed DexFi is paid
///      60.000000; a repoint followed by a flush, both fitting in one block, paid DexFi
///      **0** and sent 300.000000 elsewhere.
///
///      That gap is closed on the harvester rather than here, and it had to be: this
///      contract has no owner, no setter and no view of the counter, which is the whole
///      of its value. `EpochHarvester.setProtocolFeeWallet` now checkpoints the accrued
///      backlog into `owedProtocolFee[outgoing]`, and anybody may call
///      `flushProtocolFeeTo(thisSplitter)` to bring it here afterwards. So the honest
///      statement of the guarantee is in two parts: **what has arrived cannot be
///      redirected, and what has accrued cannot be redirected either - but only because
///      the harvester remembers, not because this contract can.**
///
///      There is deliberately **no owner, no setter, no pause and no rescue**. An owner
///      is exactly the thing that would make the guarantee above untrue, and a contract
///      whose only job is to forward a fixed ratio to two fixed addresses has nothing an
///      owner could usefully do. The cost is that a token sent here by mistake is stuck;
///      that is accepted, and it is why `split()` is USDC-only rather than taking an
///      arbitrary token - a general sweep would be a way to move value that the fixed
///      ratio was meant to constrain.
///
///      **Audit round 23, finding 8: having no owner made one failure permanent, and the
///      fix is the park-and-flush this protocol already ships four times.** `split()` used
///      to pay both legs with two bare `safeTransfer`s in one transaction, and its own
///      NatSpec presented the resulting all-or-nothing revert as a protection - "a
///      blacklisted or reverting destination cannot be used to strand the other party's
///      share in a partially-executed split". True as written and worthless in practice:
///      what it bought was that *neither* party was paid, forever, on a contract with no
///      owner, no setter, no pause and no rescue to recover with. USDC has a blocklist, so
///      the trigger is a decision by a third party neither Recoup nor DexFi controls.
///      MEASURED, by running the round-23 PoC against both trees: with DexFi's
///      wallet blocked, the old contract delivered Recoup's healthy 80% leg of a
///      1,000.000000 fee as **0**, and still 0 after 365 days, because `split()` was the
///      only call the contract had; against this one the same PoC's strand assertions no
///      longer reproduce and Recoup is paid 800.000000 with DexFi's 200.000000 still owed.
///
///      **Not a new finding, and that is the point.** It was raised in round 12 on
///      2026-08-11 and carried open through rounds 21, 22 and 23 as the cheap fix nobody
///      had a reason to do first. Round 23's framing is what moved it: the escape had by
///      then been built four times elsewhere, so this stopped being a design question and
///      became the one terminal pot in the protocol that had been left out of a pattern.
///
///      Each leg is now attempted independently and whatever a leg could not take is
///      checkpointed against **that leg's own immutable address**, drainable afterwards by
///      the permissionless `flushLegTo`. Two counts of this family are in circulation and
///      they do not actually disagree: the round-23 note says the escape was "built four
///      times", counting `CreditManager.flushSocialisedLoss`, while `flushPrincipalTo`'s
///      own docstring calls itself "the third member" because that one retries placing a
///      loss rather than paying a parked balance to a destination. This is the fourth of
///      the ones that pay, after `EpochHarvester.flushLenderYieldTo`, `flushProtocolFeeTo`
///      and `CreditManager.flushPrincipalTo`, and it inherits their reasoning verbatim:
///      the destination is a **mapping key, never an argument**, so the escape grants no
///      authority over the money, only over the timing of a payment already owed. Only
///      `recoupWallet` and `dexfiWallet` can ever be keys, so there is still no destination
///      for anybody to choose and still nothing for an owner to do. The guarantee in the
///      first paragraph is unchanged; what changes is that one blocked destination can no
///      longer take the other party's money down with it.
///
///      **Audit round 25, finding F2: the park that fix created had no way to shrink,
///      so a destroyed leg became a claim on future fees that both parties paid.** USDC may be
///      destroyed in place under the same blocklist policy that motivated the park, and
///      `totalOwedToWallets` went on counting money that no longer existed. Nothing could
///      reduce it, so the next `split()` held the destroyed amount back out of the fee and
///      divided the rest 80/20 - charging Recoup 80% of a loss that had fallen on DexFi's leg.
///      MEASURED over 1,500.000000 of fee with DexFi blocked and 200.000000 burned: Recoup was
///      paid 1,040.000000 against a 1,200.000000 entitlement, short by 160.000000, which is
///      exactly 80% of the burn. `flushLegTo` was bricked in the same state, because it owed a
///      figure this contract could no longer transfer. `_realiseDestruction` charges the
///      shortfall to the parked legs instead - at every entry point, and permissionlessly
///      through `reconcileDestroyedLegs()`. The limit on when the shortfall is visible at all
///      is stated on that function rather than hidden behind this paragraph.
contract ProtocolFeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error WalletsMustDiffer();
    error NothingToSplit();
    error NothingToFlush();
    error NothingToReconcile();

    event FeeSplit(uint256 total, uint256 toRecoup, uint256 toDexFi);

    /// @notice A leg that could not take delivery, checkpointed against its own address.
    /// @param owed The wallet's whole parked balance after this credit, not just the increment.
    event LegParked(address indexed wallet, uint256 amount, uint256 owed);

    /// @notice A parked leg delivered later, by anybody.
    event LegFlushed(address indexed wallet, uint256 amount);

    /// @notice A parked leg written down because the USDC standing behind it was destroyed.
    /// @param wallet The leg the loss was charged to.
    /// @param amount How much of that leg was written off.
    /// @param owed What that wallet still has parked afterwards.
    event LegWrittenDown(address indexed wallet, uint256 amount, uint256 owed);

    IERC20 public immutable usdc;

    /// @notice Recoup's leg. Referral rewards and the borrower rebate are funded from
    ///         this one alone, which is the promise `/refer` publishes.
    address public immutable recoupWallet;

    /// @notice DexFi's leg.
    address public immutable dexfiWallet;

    /// @notice USDC that has been split to a wallet but could not be delivered to it.
    /// @dev Only `recoupWallet` and `dexfiWallet` are ever written, and each is only ever
    ///      credited from its own leg of a split. Nothing else can become a key, which is
    ///      why `flushLegTo` needs no access control and no owner: there is no destination
    ///      to choose.
    mapping(address => uint256) public owedToWallet;

    /// @notice Sum of `owedToWallet`. Held out of the next split, so a parked leg is never
    ///         re-split and never handed a second time to the other party.
    /// @dev The pair is `LenderPool.claimable`/`totalClaimable`, for the same reason that one
    ///      exists: a credited balance is physically indistinguishable from an uncredited one, so
    ///      the total has to be tracked separately or the next sizing counts it twice.
    uint256 public totalOwedToWallets;

    constructor(IERC20 usdc_, address recoupWallet_, address dexfiWallet_) {
        if (address(usdc_) == address(0) || recoupWallet_ == address(0) || dexfiWallet_ == address(0)) {
            revert ZeroAddress();
        }
        // Not paranoia: with one address on both legs the event would report a split
        // that did not happen, and the on-chain record is the only evidence either
        // party has that the agreement was honoured.
        if (recoupWallet_ == dexfiWallet_) revert WalletsMustDiffer();

        usdc = usdc_;
        recoupWallet = recoupWallet_;
        dexfiWallet = dexfiWallet_;
    }

    /// @notice Split the unsplit balance between the two wallets in the agreed ratio, paying
    ///         each leg that can take delivery and parking each leg that cannot.
    /// @dev Permissionless, and sized from this contract's own balance rather than from
    ///      an argument, so it cannot be told a figure that differs from what arrived.
    ///      Same reasoning as `EpochHarvester.harvest`, which sizes an epoch from the
    ///      adapter's balance for exactly this reason.
    ///
    ///      **Sized from the balance net of `totalOwedToWallets`, not from the raw balance.**
    ///      A parked leg is physically still here and is already somebody's money; splitting
    ///      over it again would hand 80% of DexFi's parked leg to Recoup on the next call,
    ///      which is the redirect this contract exists to make impossible. `_unsplit` is the
    ///      one place that subtraction happens.
    ///
    ///      DexFi's leg is computed from the bps and Recoup's takes the remainder, so
    ///      the two always sum to precisely the unsplit balance and no dust is ever stranded
    ///      unaccounted-for. The direction of that rounding is worth one sentence: at most one
    ///      wei of USDC per split, and it goes to the party operating the contract, which
    ///      mirrors how `EpochHarvester` already hands the protocol slice the remainder
    ///      of the four-way split.
    ///
    ///      Reverts rather than no-opping on an empty unsplit balance, because a caller who
    ///      explicitly asked for a flush wants to know it did nothing - the same choice
    ///      `flushProtocolFee` makes.
    ///
    ///      Does **not** revert when a leg fails to deliver, which is the round-23 change and
    ///      the opposite of what the old comment on this function claimed to want. The accrual
    ///      is the part that matters and it always happens; delivery is best-effort here and
    ///      loud in `flushLegTo`, exactly the division `EpochHarvester.harvest` and
    ///      `flushLenderYield` already draw. A caller is not left guessing: a leg that did not
    ///      land emits `LegParked` and shows up in `owedToWallet`.
    ///
    ///      **There is deliberately no `_realiseDestruction()` at the top of this function, and
    ///      the first draft of the round-25 F2 fix had one.** It could never have persisted an
    ///      effect: a write-down leaves `totalOwedToWallets == balance` by construction, so the
    ///      unsplit pot is empty by the time this sizes itself, and the `NothingToSplit` below
    ///      rolls the write-down back along with everything else. A guard that only ever runs
    ///      inside a call that reverts is worse than no guard, because it reads as protection.
    ///      `reconcileDestroyedLegs` is the call that works in that state, and
    ///      `test_A26_08_splitCannotRecordAWriteDownBecauseItWouldHaveNothingToSplit` measures
    ///      the claim rather than restating it.
    ///
    /// @return toRecoup Recoup's leg of this split. Credited, and delivered if it could be.
    /// @return toDexFi DexFi's leg of this split, on the same terms.
    function split() external nonReentrant returns (uint256 toRecoup, uint256 toDexFi) {
        uint256 total = _unsplit();
        if (total == 0) revert NothingToSplit();

        toDexFi = (total * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS;
        toRecoup = total - toDexFi;

        emit FeeSplit(total, toRecoup, toDexFi);

        // DexFi's leg first, and the order no longer decides anything: neither leg can revert
        // the other now. Kept in this order only so the event stream reads the way it always did.
        _payOrPark(dexfiWallet, toDexFi);
        _payOrPark(recoupWallet, toRecoup);
    }

    /// @notice Deliver a leg that was parked because its wallet could not take it. Permissionless.
    /// @dev The destination is the mapping key, never an argument, so this grants no authority
    ///      over the money - only the timing of a payment that wallet was always owed. Same
    ///      property, for the same reason, as `EpochHarvester.flushProtocolFeeTo` and
    ///      `CreditManager.flushPrincipalTo`. And because anybody may call it, DexFi's leg does
    ///      not depend on Recoup cooperating in paying it, which is the whole point of there
    ///      being no owner here.
    ///
    ///      No "is this one of the two wallets" guard, deliberately. The mapping is the guard:
    ///      only the two immutable legs are ever written, so any other address reads zero and
    ///      gets `NothingToFlush`. A second check would restate the invariant rather than add one.
    ///
    ///      Reverts rather than returning early at zero, unlike `split()`. That one is a
    ///      permissionless accrual anybody may drive; this one is only ever called by somebody
    ///      who has looked at `owedToWallet` and wants the money moved, and telling them a
    ///      payment happened when none did is how an ordering constraint hides.
    ///
    ///      Effects before the transfer, and a bare `safeTransfer` rather than the measured
    ///      best-effort push `split()` uses: this caller asked for exactly this payment, so a
    ///      wallet that is still blocked must revert the whole call and leave the checkpoint
    ///      standing, not silently re-park it.
    function flushLegTo(address wallet) external nonReentrant {
        if (wallet == address(0)) revert ZeroAddress();

        // Before reading the checkpoint, not after. A leg whose USDC was destroyed is owed a
        // figure this contract cannot transfer, so without this the call reverts every time and
        // the leg is bricked rather than merely short.
        _realiseDestruction();

        uint256 amount = owedToWallet[wallet];
        if (amount == 0) revert NothingToFlush();

        owedToWallet[wallet] = 0;
        totalOwedToWallets -= amount;
        emit LegFlushed(wallet, amount);
        usdc.safeTransfer(wallet, amount);
    }

    /// @notice Charge a destroyed parked leg to the leg it was destroyed from. Permissionless.
    /// @dev The counterpart to `flushLegTo` for the failure `flushLegTo` cannot handle: not a
    ///      wallet that will not take delivery, but USDC that is no longer here to deliver.
    ///
    ///      Grants no authority over anything, for the same reason `flushLegTo` does not: it
    ///      takes no destination, no amount and no discretion. It can only ever do work when
    ///      this contract holds less USDC than it has already credited, which nothing inside
    ///      this contract can bring about - `split()` credits only what is here and `flushLegTo`
    ///      decrements by exactly what it moved - so the shortfall is always the token issuer's
    ///      doing.
    ///
    ///      Reverts rather than no-opping when there is nothing to write down, on the same
    ///      reasoning as `flushLegTo`: this is called by somebody who has read
    ///      `destroyedDeficit` and wants the write-down recorded, and telling them one happened
    ///      when none did is how a stale figure survives.
    ///
    /// @return writtenDown The deficit charged to the parked legs.
    function reconcileDestroyedLegs() external nonReentrant returns (uint256 writtenDown) {
        writtenDown = _realiseDestruction();
        if (writtenDown == 0) revert NothingToReconcile();
    }

    /// @notice USDC this contract has credited to a wallet but no longer physically holds.
    /// @dev Non-zero only after the token issuer has destroyed a balance in place. Published
    ///      because the write-down above is worth nothing if neither party can see that it is
    ///      owed: this is the number that says `reconcileDestroyedLegs` should be called, and
    ///      called **before** the next fee arrives.
    function destroyedDeficit() external view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 owed = totalOwedToWallets;
        return owed > balance ? owed - balance : 0;
    }

    /// @notice What a given amount would split into, without moving anything.
    /// @dev For the app and for DexFi's own reconciliation. Deliberately pure and
    ///      derived from the same expression `split` uses, so the two cannot disagree.
    function preview(uint256 amount) external pure returns (uint256 toRecoup, uint256 toDexFi) {
        toDexFi = (amount * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS;
        toRecoup = amount - toDexFi;
    }

    /// @notice Balance that has arrived and not yet been split, i.e. what the next `split()`
    ///         would divide.
    /// @dev Published because DexFi reconciles against this contract and the raw ERC-20
    ///      balance stopped answering the question the moment a leg could be parked.
    function unsplitBalance() external view returns (uint256) {
        return _unsplit();
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Clamped, not just subtracted. `totalOwedToWallets` can only ever be credited out
    ///      of USDC physically here and is only ever decremented by a delivery that happened,
    ///      so `balance >= totalOwedToWallets` holds against any ordinary token. It does not
    ///      hold against a token whose issuer can destroy a balance in place - which USDC's
    ///      blocklist policy explicitly allows - and an underflow there would revert `split()`
    ///      permanently, recreating by arithmetic the exact strand this change removes.
    ///      `EpochHarvester._push` carries the same clamp for the same class of reason.
    ///
    ///      **The clamp is where audit round 25 finding F2 lived, and clamping is not the fix.**
    ///      It stops the revert and stops nothing else: the destroyed amount stays inside
    ///      `totalOwedToWallets`, is quietly held back out of the next arrival, and the loss is
    ///      then shared 80/20 with a party that did not incur it. Every state-changing entry
    ///      point now calls `_realiseDestruction` first, so by the time this runs the clamp is
    ///      defence in depth rather than the mechanism. It is kept because this is also the
    ///      `view` behind `unsplitBalance()`, which cannot write.
    function _unsplit() private view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 owed = totalOwedToWallets;
        return balance > owed ? balance - owed : 0;
    }

    /// @dev Charge USDC destroyed in place to the parked legs it was destroyed from, so that a
    ///      burn is not repaid out of the next fee.
    ///
    ///      **The defect this closes is a socialisation, not a shortfall.** MEASURED before the
    ///      change, over 1,500.000000 of fee arriving in two tranches with DexFi blocked and
    ///      200.000000 of DexFi's parked leg destroyed between them: Recoup was paid
    ///      1,040.000000 against a 1,200.000000 entitlement and DexFi 260.000000 against
    ///      300.000000. The 160.000000 Recoup lost is exactly 80% of the burn - the burn had
    ///      been left inside `totalOwedToWallets`, held back out of the next split, and so
    ///      divided in the agreed ratio between one party who lost money and one who did not.
    ///
    ///      **Pro-rata to what each leg has parked, because that is the only attribution this
    ///      contract can make honestly.** With one leg parked - the realistic case, and the
    ///      measured one - pro-rata puts the whole loss on that leg, which is right for a
    ///      reason stronger than proportion: its parked balance was the entire contents of this
    ///      address, so the destroyed USDC provably was that leg's. With both parked, nothing
    ///      here can say whose was taken and proportion is the honest default.
    ///
    ///      Rounding: DexFi's share of the loss floors and Recoup takes the remainder, which is
    ///      `split()`'s rule pointed the other way. The sub-unit falls on the party operating
    ///      the contract in both directions, and the two cuts sum to the deficit exactly, so no
    ///      wei is created or destroyed by choosing which side to compute first. A remainder
    ///      can only arise when both legs are parked at once.
    ///
    ///      **The limit, stated because a partial fix read as a whole one is worse than none.**
    ///      This can only run while the shortfall is visible, and a fee arriving before anybody
    ///      calls it hides the shortfall for good: `balance - totalOwedToWallets` cannot tell
    ///      1,500.000000 arriving after a 200.000000 burn from 1,300.000000 arriving after no
    ///      burn at all. Nothing this contract can be asked distinguishes them, because it has
    ///      no hook on an incoming `transfer` and deliberately no view of the harvester's
    ///      counter. So the window is real, `destroyedDeficit()` exists to make it observable,
    ///      and `reconcileDestroyedLegs()` is permissionless so the party standing to lose can
    ///      close it without needing the other to cooperate. Removing the window entirely means
    ///      holding each parked leg where a burn is attributable by address - one immutable
    ///      escrow per leg, deployed here in the constructor - which is a second deployed
    ///      contract and a second failure mode, because an escrow that is itself blocked cannot
    ///      be parked into and the mapping would have to stay as a fallback regardless.
    ///      Recorded, not taken.
    ///
    /// @return deficit How much was written down, zero when there was nothing to write down.
    function _realiseDestruction() private returns (uint256 deficit) {
        uint256 owed = totalOwedToWallets;
        if (owed == 0) return 0;

        uint256 balance = usdc.balanceOf(address(this));
        if (balance >= owed) return 0;

        deficit = owed - balance;

        // Floor on DexFi, remainder on Recoup. `owedToWallet` sums to `owed` over exactly these
        // two keys and nothing else can ever become a key, so the two cuts sum to the deficit
        // and neither can exceed the leg it is charged to.
        uint256 dexfiCut = (deficit * owedToWallet[dexfiWallet]) / owed;
        uint256 recoupCut = deficit - dexfiCut;

        if (dexfiCut != 0) _writeDown(dexfiWallet, dexfiCut);
        if (recoupCut != 0) _writeDown(recoupWallet, recoupCut);

        totalOwedToWallets = balance;
    }

    /// @dev One leg of a write-down. Split out only so the event can report what that wallet
    ///      still has parked, the way `LegParked` reports what it has just gained.
    function _writeDown(address wallet, uint256 amount) private {
        uint256 remaining = owedToWallet[wallet] - amount;
        owedToWallet[wallet] = remaining;
        emit LegWrittenDown(wallet, amount, remaining);
    }

    /// @dev Attempt one leg, and checkpoint whatever it could not take against its own address.
    ///
    ///      Low-level, and the result read as `ok && delta`, not as `ok` alone. Two different
    ///      failure shapes have to survive this: a token that **reverts** on a blocked recipient,
    ///      as USDC does, and a token that **returns false** and moves nothing, which is what
    ///      audit round 17 caught `DirectCallAdapter._trySweepUsdc` reading as success. Only the
    ///      balance delta tells those apart from a payment.
    ///
    ///      Clamped above `amount` as well as below zero. A token that pushes USDC *in* during
    ///      the call would otherwise make this credit a delivery larger than the leg, and a clamp
    ///      at one end only is one refactor away from being no clamp at all -
    ///      `CreditManager._deliverPrincipal` states the same rule.
    function _payOrPark(address wallet, uint256 amount) private {
        if (amount == 0) return;

        uint256 balanceBefore = usdc.balanceOf(address(this));
        // A wallet that reverts must not be able to trap the other party's leg - the whole
        // of round-23 finding 8.
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = address(usdc).call(abi.encodeCall(IERC20.transfer, (wallet, amount)));
        uint256 balanceAfter = usdc.balanceOf(address(this));

        uint256 delivered = ok && balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (delivered > amount) delivered = amount;

        if (delivered < amount) {
            uint256 parked = amount - delivered;
            uint256 owed = owedToWallet[wallet] + parked;
            owedToWallet[wallet] = owed;
            totalOwedToWallets += parked;
            emit LegParked(wallet, parked, owed);
        }
    }
}
