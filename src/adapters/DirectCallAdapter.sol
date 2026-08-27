// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Config} from "../Config.sol";
import {ICustodyAdapter} from "../interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../interfaces/IDexFiFarm.sol";

/// @title DirectCallAdapter (PRD §4.1)
/// @notice Custody backend where the protocol itself holds and works the DexFi
///         position: this contract is the farm staker and the address DexFi must
///         add to the bond transfer whitelist (§14 ask #5). Holds no USDC at rest -
///         every claim is forwarded to `yieldRecipient` in the same call.
/// @dev Vault-only for the custody hot path; owner-only (the governance timelock) for
///      the yield-routing config and the emergency hatch. `yieldRecipient` and
///      `harvester` are settable so the immutable adapter can be pointed at the
///      EpochHarvester once it ships, without a redeploy/migration.
contract DirectCallAdapter is ICustodyAdapter, ERC1155Holder, Ownable {
    using SafeERC20 for IERC20;

    error NotVault();
    error NotClaimer();
    error ReceiverMustBeAdapter(address receiver);
    error PaymentMismatch(uint256 expected, uint256 actual);
    error MintAmountMismatch(uint256 expected, uint256 actual);
    error ZeroAddress();
    error RenounceDisabled();
    error NothingToFlush();

    event YieldRecipientSet(address indexed recipient);
    event HarvesterSet(address indexed harvester);
    event EmergencyUnstaked(address indexed to, uint256 amount);
    event YieldParked(address indexed recipient, uint256 amount, uint256 totalOwed);
    event YieldFlushed(address indexed recipient, uint256 amount);

    IDexFiBond public immutable bond;
    IDexFiFarm public immutable farm;
    IERC20 public immutable usdc;
    address public immutable vault;

    /// @notice Where claimed/swept USDC is sent. Defaults to a treasury sink at
    ///         deploy; repointed to the EpochHarvester when Phase 3 lands.
    address public yieldRecipient;
    /// @notice Additional address permitted to trigger a claim (the EpochHarvester),
    ///         so harvesting need not route through the owner-only vault path.
    address public harvester;

    /// @notice Farm yield that has been received but not yet reported to the vault -
    ///         a deposit-time settlement, or a payout left behind by a sweep that
    ///         failed. Carried so the next successful claim reports it rather than the
    ///         money leaving the protocol's accounting silently.
    uint256 public unreportedYield;

    /// @notice Farm yield that accrued while a given address was the yield recipient and which that
    ///         address could not take when it was repointed away from. Payable to it forever.
    /// @dev **Audit round 22, finding 4.** `setYieldRecipient` validated `!= address(0)` and nothing
    ///      else, and what it carries is **gross** yield - the whole pot, before the 55/25/10/10
    ///      split. The only protection was the best-effort drain below, which does nothing on
    ///      precisely the condition the setter exists for: a blacklist, a pause. MEASURED:
    ///      1,000.000000 gross accrued, the drain inert, and the next ordinary `depositBonds(1)` -
    ///      **called by a lender, not the owner** - delivered the whole 1,000.000000 to the incoming
    ///      address and 0 to the recipient that earned it, while `farmYieldDelivered` recorded it as
    ///      delivered. CONTROL: a recipient able to receive means the drain works and nothing parks.
    ///
    ///      **The fix is copied from `EpochHarvester`, which parks per recipient twice.**
    ///      `owedToPool` since round 11 and `owedProtocolFee` since round 21, each drained by a
    ///      permissionless `flush...To(address)` that takes its destination from the mapping key.
    ///      The reasoning transplants line for line, and `setProtocolFeeWallet` had already
    ///      **rejected "drain first"** for the same pot one contract downstream: draining hands the
    ///      outgoing recipient a veto over its own replacement, which is the trap this setter was
    ///      built to escape. So the drain stays best-effort, and whatever it could not move is
    ///      checkpointed here instead of being left free for the next sweep to hand onward.
    ///
    ///      A mapping cannot be summed and `_trySweepUsdc` sizes its transfer from this contract's
    ///      raw balance, so `totalOwedToRecipients` exists beside it and that sweep subtracts it.
    ///      Without that, a parked balance would be swept to the incoming recipient on the very
    ///      next farm-touching call and still be owed here.
    mapping(address => uint256) public owedToRecipient;

    /// @notice Sum of `owedToRecipient`. The USDC sitting here that is not this contract's to
    ///         forward - the same role `EpochHarvester.totalOwedToPools` plays one contract down.
    uint256 public totalOwedToRecipients;

    /// @inheritdoc ICustodyAdapter
    /// @dev Monotonic, and the reason it can be trusted is that `_settleFarmPayout` is handed a
    ///      *measured farm delta* rather than this contract's balance. `_trySweepUsdc` moves
    ///      everything sitting here, donations included, but only what the farm paid is ever added
    ///      to this counter. So a stranger can raise this contract's balance, and the harvester's,
    ///      and move this number by nothing.
    ///
    ///      Audit round 11 is why it exists, and the shape of that finding is why it lives here
    ///      rather than in the harvester. `EpochHarvester.harvest` treats the farm claim as
    ///      best-effort but treated the epoch as real regardless, so ~$1.82 of donated USDC bought
    ///      a write to `CreditManager.lastDistributeAt` - the sole record of how long an epoch's
    ///      money took to earn. The sharper signal that closes it was already being computed on
    ///      every farm-touching path and thrown away: `stake`, `unstake`, `mintBonds` and
    ///      `claimYield` all return it and `CollateralVault` emits it and drops it. Accumulating
    ///      it costs one SSTORE on paths that are already writing storage.
    ///
    ///      Never decreases, so the harvester can hold a high-water mark against it. A fresh
    ///      adapter starts at zero, which is exactly why `EpochHarvester.setCustodyAdapter`
    ///      re-seeds that mark instead of carrying it across a custody swap: a stale mark against
    ///      a zeroed counter would decline every epoch forever.
    uint256 public farmYieldDelivered;

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @dev Vault or the wired harvester may claim yield.
    modifier onlyClaimer() {
        if (msg.sender != vault && msg.sender != harvester) revert NotClaimer();
        _;
    }

    constructor(
        IDexFiBond bond_,
        IDexFiFarm farm_,
        IERC20 usdc_,
        address vault_,
        address initialOwner,
        address yieldRecipient_
    ) Ownable(initialOwner) {
        if (
            address(bond_) == address(0) || address(farm_) == address(0)
                || address(usdc_) == address(0) || vault_ == address(0)
                || yieldRecipient_ == address(0)
        ) revert ZeroAddress();
        bond = bond_;
        farm = farm_;
        usdc = usdc_;
        vault = vault_;
        yieldRecipient = yieldRecipient_;
        // Standing approval so stake() can move bond units into the farm.
        bond_.setApprovalForAll(address(farm_), true);
    }

    // ── Yield routing config (owner = governance timelock) ───────────────────

    /// @dev Settles to the outgoing recipient before repointing, and **checkpoints whatever the
    ///      settlement could not deliver against that same recipient**. Rewards accrue continuously
    ///      inside the farm, so a bare repoint hands an epoch of already-earned
    ///      borrower/lender/insurance yield to the new address - and that is the *planned* Phase 3
    ///      handover, not just a malicious one.
    ///
    ///      **Audit round 22, finding 4, and the full argument is on `owedToRecipient`.** The drain
    ///      below is best-effort and therefore does nothing on exactly the condition this setter
    ///      exists for; without the park, the yield it failed to deliver simply sat here as free
    ///      balance until the next farm-touching call swept it to the incoming address. That call is
    ///      an ordinary `depositBonds` by any lender, so the redirection did not even need the owner
    ///      to make it happen twice.
    ///
    ///      **No precondition, deliberately, and no new failure mode.** The only branch below
    ///      decides whether a park *happened*: the pointer moves on every call, in every state, and
    ///      there is nothing here a stranger can flip to make it revert. Nor is the park a state
    ///      anyone can be stuck in - `flushYieldTo` is permissionless and takes its destination from
    ///      the mapping key. Both properties are lifted verbatim from
    ///      `EpochHarvester.setProtocolFeeWallet`, which reached them by having the two obvious
    ///      alternatives - drain first, or refuse while a backlog stands - fail on it first.
    function setYieldRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        address outgoing = yieldRecipient;
        if (outgoing != address(0) && recipient != outgoing) {
            // Best-effort, not mandatory. This is the designated escape from a
            // recipient that can no longer receive USDC - a Circle blacklist, a pause -
            // and an earlier version made the escape itself a hard `safeTransfer` to
            // that same address. It reverted on precisely the condition it existed to
            // fix, so the recipient could never be repointed and every dollar of farm
            // yield was trapped in an immutable contract, growing with each exit.
            //
            // `_trySweepUsdc` targets the *outgoing* recipient because the flip below
            // has not happened yet, and `unreportedYield` is cleared only when the
            // sweep actually moved the money it was tracking.
            try this.claimFarmRewards() {} catch {}
            if (_trySweepUsdc() != 0) unreportedYield = 0;

            // Read after the drain, exactly as `EpochHarvester.setLenderPool` reads its residue
            // after the delivery attempt: what is still free is precisely the part the outgoing
            // recipient could not take. Everything free here accrued while `outgoing` was wired -
            // anything owed to an earlier recipient was parked by its own repoint and is excluded
            // by `_freeBalance` - so the whole residue belongs to `outgoing`.
            //
            // The *whole* free balance, donations included, and that is not an oversight: the drain
            // it replaces sends the whole free balance too, so this parks exactly what the outgoing
            // recipient would have received had it been able to receive. A donation is a gift to the
            // recipient rather than yield owed to borrowers, which is what `_settleFarmPayout`
            // already says about the same dollars.
            uint256 stranded = _freeBalance();
            if (stranded != 0) {
                // The carried counter goes with the money. Left standing it is a claim on a balance
                // this contract can no longer forward, so the next successful sweep would report
                // the parked amount to the vault as freshly delivered yield - the same reasoning
                // that clears it on the successful branch above, for the opposite reason.
                unreportedYield = 0;
                owedToRecipient[outgoing] += stranded;
                totalOwedToRecipients += stranded;
                emit YieldParked(outgoing, stranded, totalOwedToRecipients);
            }
        }
        yieldRecipient = recipient;
        emit YieldRecipientSet(recipient);
    }

    /// @notice Deliver a parked balance to the recipient it was parked for. Permissionless.
    /// @dev The destination is the mapping key, never an argument, so this grants no authority over
    ///      the money - only the timing of a transfer that address was always owed. Exactly
    ///      `EpochHarvester.flushProtocolFeeTo`, which is the same shape one contract downstream.
    ///
    ///      **A hard `safeTransfer`, unlike the sweep.** The sweep is best-effort because a
    ///      collateral exit must never be blockable by a token; nothing waits on this call, and a
    ///      caller who explicitly asked for a flush wants to know it did not happen. Same split
    ///      `EpochHarvester` draws between `harvest` and its two `flush` functions.
    ///
    ///      State is written before the transfer, so a token with a callback cannot re-enter into a
    ///      second payment of the same balance. This contract has no reentrancy guard and does not
    ///      need one for that reason.
    function flushYieldTo(address recipient) external {
        uint256 amount = owedToRecipient[recipient];
        if (amount == 0) revert NothingToFlush();
        owedToRecipient[recipient] = 0;
        totalOwedToRecipients -= amount;
        emit YieldFlushed(recipient, amount);
        usdc.safeTransfer(recipient, amount);
    }

    /// @notice Pull pending farm rewards into this contract without forwarding them.
    /// @dev External only so `setYieldRecipient` can wrap it in try/catch - Solidity
    ///      has no try around an internal call. Self-call gated, so it is not a new
    ///      entry point. Exists because a farm that reverts must not block a repoint.
    function claimFarmRewards() external {
        if (msg.sender != address(this)) revert NotVault();
        farm.withdraw(0); // withdraw(0) = claim, verified on-chain behaviour
    }

    function setHarvester(address harvester_) external onlyOwner {
        if (harvester_ == address(0)) revert ZeroAddress();
        harvester = harvester_;
        emit HarvesterSet(harvester_);
    }

    /// @dev Renouncing would permanently freeze yield routing and the emergency hatch.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── ICustodyAdapter ──────────────────────────────────────────────────────

    /// @inheritdoc ICustodyAdapter
    /// @dev Slither unused-return: only the staked amount from userInfo is needed;
    ///      rewardDebt is MasterChef bookkeeping this contract does not consume.
    // slither-disable-next-line unused-return
    function mintBonds(bytes calldata mintData) external payable onlyVault returns (uint256 amount) {
        IDexFiBond.MintDataInput memory data = abi.decode(mintData, (IDexFiBond.MintDataInput));
        // Bonds auto-stake for the receiver on mint; custody must land here.
        if (data.receiver != address(this)) revert ReceiverMustBeAdapter(data.receiver);
        // Strict equality is deliberate and load-bearing: the bond takes
        // `msg.value >= paymentAmount`, forwards only `paymentAmount` to its treasury,
        // and exposes no native-withdrawal path, so any overpayment is burned with no
        // recovery by anyone. Relaxing this to `>=` would turn a revert into a silent,
        // permanent loss of the depositor's ETH.
        if (msg.value != data.paymentAmount) revert PaymentMismatch(data.paymentAmount, msg.value);

        (uint256 stakedBefore,) = farm.userInfo(address(this));
        uint256 looseBefore = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        // Measured across the mint itself, not just the fallback stake below. On the
        // auto-stake path `bond.mint` drives the farm's `depositForAccount` hook for
        // this adapter, and a MasterChef-style pool settles the whole position's
        // pending rewards on any deposit - so an ETH mint can flush an epoch of every
        // borrower's yield in here with nothing measuring it. That is the same leak
        // `_settleFarmPayout` was factored out to close, and this was the one
        // farm-touching path still outside it.
        uint256 usdcBefore = usdc.balanceOf(address(this));

        bond.mint{value: msg.value}(data);

        (uint256 stakedAfter,) = farm.userInfo(address(this));
        uint256 looseAfter = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);

        // Units from THIS mint appear either as staked growth (auto-stake path) or
        // as newly-loose units (no-reward-pool fallback). Pre-existing loose bonds
        // (donations/mis-sends) are excluded, so credit can never absorb them and
        // the credited amount is pinned to DexFi's signed `amountNfts`.
        uint256 newlyLoose = looseAfter - looseBefore;
        uint256 minted = (stakedAfter - stakedBefore) + newlyLoose;
        if (minted != data.amountNfts) revert MintAmountMismatch(data.amountNfts, minted);

        // Same measurement `stake()` performs, for the same reason: this is a
        // MasterChef-style farm, so `deposit` settles the whole adapter position's
        // pending rewards. Unmeasured, an epoch of every borrower's yield would sit
        // here uncounted until some later sweep pushed it out as an untracked
        // donation. Only the fallback path reaches this - on the auto-stake path
        // `newlyLoose` is zero and `bond.mint` has already staked - but the fallback
        // is the one that fires if DexFi ever unsets the reward pool.
        if (newlyLoose > 0) farm.deposit(newlyLoose);

        // One settle covering both branches, so the auto-stake path is measured too.
        // The return is discarded rather than reported: this path already returns the
        // minted bond count, and the yield still reaches borrowers because the
        // harvester sizes an epoch from its own balance, not from a reported figure.
        _settleFarmPayout(usdc.balanceOf(address(this)) - usdcBefore);
        amount = data.amountNfts;
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Measures any USDC the farm settles on deposit, then forwards it, mirroring
    ///      `unstake` exactly. MasterChef-style pools pay pending rewards on `deposit`
    ///      as well as `withdraw`; unmeasured, that money would later be swept out
    ///      without ever being counted as yield, and unswept it would sit here at rest
    ///      against this contract's stated design.
    ///
    ///      The sweep stays best-effort for the same reason it does on the way out: a
    ///      USDC pause or blacklist must never block a deposit. Un-swept USDC is
    ///      carried in `unreportedYield` and reported by the next successful claim.
    function stake(uint256 amount) external onlyVault returns (uint256 swept) {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.deposit(amount);
        swept = _settleFarmPayout(usdc.balanceOf(address(this)) - balBefore);
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Returns the USDC swept, which the vault must account for. The farm is
    ///      MasterChef-style, so `withdraw(amount)` settles the pending rewards of the
    ///      entire adapter position - which is every borrower's pooled yield, not just
    ///      the caller's. Reporting nothing meant any depositor could withdraw a single
    ///      bond unit and push a whole epoch's yield out through an unmeasured path,
    ///      leaving the accounted harvest at zero and nobody's debt written down.
    ///
    ///      The sweep stays best-effort: a USDC pause or blacklist must never brick a
    ///      collateral exit. Un-swept USDC stays claimable via claimYield.
    function unstake(uint256 amount) external onlyVault returns (uint256 swept) {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.withdraw(amount);
        // On a failed sweep (USDC paused, recipient blacklisted) the exit still
        // succeeds and the yield is carried to the next successful claim.
        swept = _settleFarmPayout(usdc.balanceOf(address(this)) - balBefore);
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Reports real farm yield - this claim's payout plus anything a previous
    ///      failed sweep or a deposit-time settlement left behind - while still
    ///      excluding donations, so neither problem is traded for the other. A
    ///      donation is transferred onward but never counted, because it is a gift to
    ///      the recipient rather than yield owed to borrowers and lenders.
    ///      Routes through the same best-effort settle as `stake` and `unstake`, so a
    ///      recipient that cannot receive carries the yield forward instead of
    ///      reverting. A hard transfer here meant a blacklisted recipient bricked
    ///      every epoch as well as trapping the money.
    function claimYield() external onlyClaimer returns (uint256 usdcAmount) {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.withdraw(0); // withdraw(0) = claim, verified on-chain behaviour
        usdcAmount = _settleFarmPayout(usdc.balanceOf(address(this)) - balBefore);
    }

    /// @inheritdoc ICustodyAdapter
    function transferBonds(address to, uint256 amount) external onlyVault {
        bond.safeTransferFrom(address(this), to, Config.DEXFI_BOND_TOKEN_ID, amount, "");
    }

    /// @inheritdoc ICustodyAdapter
    // slither-disable-next-line unused-return
    function stakedBalance() external view returns (uint256 staked) {
        (staked,) = farm.userInfo(address(this));
    }

    // ── Emergency (owner = governance timelock) ──────────────────────────────

    /// @notice Break-glass exit if the farm stops honouring withdraw(): pull all
    ///         bonds via the farm's reward-forfeiting escape hatch and hand them to
    ///         a governance-controlled address for redistribution.
    function emergencyUnstake(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        farm.emergencyWithdraw();
        uint256 bal = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        if (bal > 0) bond.safeTransferFrom(address(this), to, Config.DEXFI_BOND_TOKEN_ID, bal, "");
        emit EmergencyUnstaked(to, bal);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev What every farm interaction does with the USDC it shook loose: forward it
    ///      and report it, or - if the transfer cannot go through - carry it in
    ///      `unreportedYield` so the next successful claim picks it up.
    ///
    ///      Shared by `stake`, `unstake` and `mintBonds` because all three call into a
    ///      MasterChef-style farm, and every one of those calls settles the pending
    ///      rewards of the entire adapter position. Having it in one place is what
    ///      stops a new farm-touching path quietly reintroducing the leak.
    /// @param farmPaid USDC measured as arriving from the farm during the call.
    /// @return swept Total forwarded onward, including any previously carried amount.
    ///         Zero when the sweep could not go through.
    function _settleFarmPayout(uint256 farmPaid) private returns (uint256 swept) {
        if (_trySweepUsdc() == 0) {
            unreportedYield += farmPaid;
            return 0;
        }
        swept = farmPaid + unreportedYield;
        unreportedYield = 0;
        // Counted here rather than at the four call sites, for the same reason the sweep itself
        // lives here: this is the one funnel every farm-touching path goes through, so a fifth
        // path cannot deliver farm yield without also corroborating the epoch that pays it out.
        // That is what stops a new path quietly reintroducing round 11's finding, the same way
        // this helper stops one reintroducing the leak it was factored out to close.
        //
        // Counted on the swept branch only, and never on the failed one. A sweep that did not go
        // through has delivered nothing to the harvester yet, so counting it there would let the
        // harvester rate an epoch against money it has not received; `unreportedYield` carries the
        // amount instead and the next successful sweep counts it exactly once.
        //
        // **A parked balance is never counted here, and `flushYieldTo` does not count it either.**
        // Audit round 22 measured this counter recording as delivered a 1,000.000000 epoch that the
        // recipient never received, so under-counting is the direction to be wrong in. The cost of
        // never counting it is bounded and small: `EpochHarvester` needs only
        // `Config.MIN_EPOCH_FARM_YIELD` - one dollar - of subsequent farm delivery before an epoch
        // that includes the flushed money can run, and the fund pays hundreds of dollars a week.
        // Counting it at the flush instead would let a donation move this number, which is the one
        // property round 11 built it for.
        farmYieldDelivered += swept;
    }

    /// @dev Best-effort USDC sweep that never reverts the calling transaction.
    /// @return swept The amount that actually left, so the caller can account for it.
    ///         Zero when the transfer failed, which is the case the whole low-level
    ///         call exists to tolerate.
    function _trySweepUsdc() internal returns (uint256 swept) {
        uint256 amount = _freeBalance();
        if (amount == 0) return 0;
        // Low-level call so a reverting transfer (pause/blacklist) cannot brick exits.
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = address(usdc).call(abi.encodeCall(IERC20.transfer, (yieldRecipient, amount)));
        // Not ignored any more: exits still succeed either way, but the amount has to
        // be reported or it leaves the protocol's accounting silently.
        //
        // **Measured, not inferred.** `ok` says only that the call did not revert. The
        // return value is discarded, so a token that returns `false` without reverting
        // satisfies it while moving nothing - and this figure feeds `farmYieldDelivered`,
        // the harvester's corroboration watermark, so an over-report there rates an epoch
        // against money that never arrived. This is the one raw token call in a repo that
        // uses `SafeERC20` everywhere else, which is why it was worth checking.
        //
        // The balance delta is used rather than decoding the return value, because it is
        // right for both failure shapes - a `false` return and a partial transfer - and
        // because measuring rather than trusting an external call is already the rule in
        // four other places here.
        // The *free* balance on both sides of the transfer, not the raw one. `totalOwedToRecipients`
        // cannot move inside this call, so the delta is identical either way - but reading the raw
        // balance here beside a free-balance `amount` above would be two different quantities in one
        // subtraction, which is one refactor away from a wrong number.
        uint256 remaining = _freeBalance();
        swept = ok && amount > remaining ? amount - remaining : 0;
    }

    /// @dev This contract's USDC less what is parked for a former recipient. Every path that moves
    ///      USDC out of here reads this rather than `balanceOf`, so a park cannot be swept onward.
    ///      `flushYieldTo` is the single exception and is the function that pays the park down.
    ///
    ///      Saturating rather than a bare subtraction. The two counters move together on every write
    ///      and the park can only ever be a subset of the balance, so this can only underflow if the
    ///      token itself takes money out of this contract - and an underflow here would revert
    ///      `stake`, `unstake` and `mintBonds` alike, which is to say every collateral path. The
    ///      whole point of the sweep being best-effort is that a token must never be able to do that.
    function _freeBalance() private view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 owed = totalOwedToRecipients;
        return balance > owed ? balance - owed : 0;
    }
}
