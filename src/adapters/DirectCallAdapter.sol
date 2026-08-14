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

    event YieldRecipientSet(address indexed recipient);
    event HarvesterSet(address indexed harvester);
    event EmergencyUnstaked(address indexed to, uint256 amount);

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

    /// @dev Settles to the outgoing recipient before repointing. Rewards accrue
    ///      continuously inside the farm, so a bare repoint hands an epoch of
    ///      already-earned borrower/lender/insurance yield to the new address - and
    ///      that is the *planned* Phase 3 handover, not just a malicious one.
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
        }
        yieldRecipient = recipient;
        emit YieldRecipientSet(recipient);
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
        farmYieldDelivered += swept;
    }

    /// @dev Best-effort USDC sweep that never reverts the calling transaction.
    /// @return swept The amount that actually left, so the caller can account for it.
    ///         Zero when the transfer failed, which is the case the whole low-level
    ///         call exists to tolerate.
    function _trySweepUsdc() internal returns (uint256 swept) {
        uint256 amount = usdc.balanceOf(address(this));
        if (amount == 0) return 0;
        // Low-level call so a reverting transfer (pause/blacklist) cannot brick exits.
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = address(usdc).call(abi.encodeCall(IERC20.transfer, (yieldRecipient, amount)));
        // Not ignored any more: exits still succeed either way, but the amount has to
        // be reported or it leaves the protocol's accounting silently.
        swept = ok ? amount : 0;
    }
}
