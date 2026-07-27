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
///         add to the bond transfer whitelist (§14 ask #5). Holds no USDC at rest —
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
            farm.withdraw(0); // claim, so nothing in-flight belongs to the new address
            uint256 bal = usdc.balanceOf(address(this));
            if (bal != 0) usdc.safeTransfer(outgoing, bal);
        }
        yieldRecipient = recipient;
        emit YieldRecipientSet(recipient);
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

        if (newlyLoose > 0) farm.deposit(newlyLoose);
        amount = data.amountNfts;
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Measures any USDC the farm settles on deposit. MasterChef-style pools pay
    ///      pending rewards on `deposit` as well as `withdraw`; unmeasured, that money
    ///      would later be swept out without ever being counted as yield.
    function stake(uint256 amount) external onlyVault {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.deposit(amount);
        unreportedYield += usdc.balanceOf(address(this)) - balBefore;
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
        uint256 farmPaid = usdc.balanceOf(address(this)) - balBefore;

        if (_trySweepUsdc() == 0) {
            // Sweep failed (USDC paused or the recipient blacklisted). The exit still
            // succeeds; the yield stays here and is reported by the next successful
            // claim rather than being forgotten.
            unreportedYield += farmPaid;
            return 0;
        }
        swept = farmPaid + unreportedYield;
        unreportedYield = 0;
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Reports real farm yield - this claim's payout plus anything a previous
    ///      failed sweep or a deposit-time settlement left behind - while still
    ///      excluding donations, so neither problem is traded for the other. A
    ///      donation is transferred onward but never counted, because it is a gift to
    ///      the recipient rather than yield owed to borrowers and lenders.
    function claimYield() external onlyClaimer returns (uint256 usdcAmount) {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.withdraw(0); // withdraw(0) = claim, verified on-chain behaviour
        uint256 farmPaid = usdc.balanceOf(address(this)) - balBefore;

        usdcAmount = farmPaid + unreportedYield;
        unreportedYield = 0;

        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) usdc.safeTransfer(yieldRecipient, bal);
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
