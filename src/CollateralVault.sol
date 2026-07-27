// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Config} from "./Config.sol";
import {LtvMath} from "./LtvMath.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ICreditManager} from "./interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "./interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "./interfaces/IDexFiBond.sol";
import {INAVOracle} from "./interfaces/INAVOracle.sol";

/// @title CollateralVault (PRD §4.1)
/// @notice Accounting home for bond collateral (fungible ERC-1155 units, id 0).
///         Custody and all DexFi interaction are delegated to a pluggable
///         ICustodyAdapter, so the direct-call vs Safe decision (pending the §14
///         whitelist answer) swaps the backend without touching balances here.
/// @dev Bond units move depositor → adapter directly (one hop, so DexFi whitelisting
///      the adapter alone is sufficient). Deposits pause with the contract; exits
///      (withdraw/seize) intentionally never pause.
contract CollateralVault is ICollateralVault, Ownable, Pausable, ReentrancyGuard {
    error NotLiquidationAuction();
    error AdapterNotSet();
    error ZeroAmount();
    error InsufficientCollateral(uint256 requested, uint256 available);
    error WithdrawalExceedsMaxLtv(uint256 postLtvBps);
    error NothingMinted();
    error ZeroAddress();
    error AdapterHasLivePosition(uint256 staked);
    error AdapterVaultMismatch(address adapterVault);
    error NavStale();
    error RenounceDisabled();
    error CreditManagerHasDebt(uint256 outstanding);

    event YieldHarvested(uint256 usdcAmount);

    IDexFiBond public immutable bond;
    INAVOracle public immutable navOracle;
    /// @notice Pluggable custody backend (direct-call vs Safe) — §4.1 config decision.
    ICustodyAdapter public custodyAdapter;
    address public creditManager;
    address public liquidationAuction;

    /// @inheritdoc ICollateralVault
    mapping(address => uint256) public override bondCount;

    /// @notice Sum of every `bondCount`. Exists so the ledger can be checked against
    ///         what custody actually holds - without it there is no on-chain way to
    ///         notice the two have diverged.
    uint256 public totalBondCount;

    constructor(IDexFiBond bond_, INAVOracle navOracle_, address initialOwner) Ownable(initialOwner) {
        if (address(bond_) == address(0) || address(navOracle_) == address(0)) revert ZeroAddress();
        bond = bond_;
        navOracle = navOracle_;
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    /// @dev A swap must not orphan a live position: reject unless the outgoing
    ///      adapter holds nothing in custody, and require the incoming adapter to be
    ///      bound to this vault. Migrating a live position requires unstaking first
    ///      (or an explicit migration path), never a bare re-point.
    function setCustodyAdapter(ICustodyAdapter adapter) external onlyOwner {
        if (address(adapter) == address(0)) revert ZeroAddress();
        ICustodyAdapter current = custodyAdapter;
        if (address(current) != address(0)) {
            uint256 staked = current.stakedBalance();
            if (staked != 0) revert AdapterHasLivePosition(staked);
        }
        address boundVault = adapter.vault();
        if (boundVault != address(this)) revert AdapterVaultMismatch(boundVault);
        custodyAdapter = adapter;
    }

    /// @dev Refuses to repoint while the outgoing manager still records debt.
    ///      `withdrawBonds` reads its entire LTV rule out of this pointer, so a swap
    ///      over live debt makes every borrower read zero and withdraw all of their
    ///      collateral against a loan the old manager still holds. Both structural
    ///      siblings - `setCustodyAdapter` here and `setLiquiditySource` on
    ///      CreditManager - already guard their own live state; this one did not.
    function setCreditManager(address creditManager_) external onlyOwner {
        if (creditManager_ == address(0)) revert ZeroAddress();
        address current = creditManager;
        if (current != address(0)) {
            uint256 outstanding = ICreditManager(current).totalDebt();
            if (outstanding != 0) revert CreditManagerHasDebt(outstanding);
        }
        creditManager = creditManager_;
    }

    function setLiquidationAuction(address liquidationAuction_) external onlyOwner {
        if (liquidationAuction_ == address(0)) revert ZeroAddress();
        liquidationAuction = liquidationAuction_;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Renouncing would permanently disable all wiring and the pause switch.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── ICollateralVault ─────────────────────────────────────────────────────

    /// @inheritdoc ICollateralVault
    function depositBonds(uint256 amount) external whenNotPaused nonReentrant {
        ICustodyAdapter adapter = _adapter();
        if (amount == 0) revert ZeroAmount();

        bondCount[msg.sender] += amount;
        totalBondCount += amount;
        emit BondsDeposited(msg.sender, amount);

        // Passes DexFi's whitelist iff the adapter is whitelisted (to-side).
        bond.safeTransferFrom(msg.sender, address(adapter), Config.DEXFI_BOND_TOKEN_ID, amount, "");
        adapter.stake(amount);
    }

    /// @inheritdoc ICollateralVault
    /// @dev Slither reentrancy-benign: bondCount is written after the external mint
    ///      because the minted amount cannot be known before it; guarded by
    ///      nonReentrant and the adapter is immutable protocol code.
    // slither-disable-next-line reentrancy-benign
    function depositETH(bytes calldata mintData) external payable whenNotPaused nonReentrant {
        ICustodyAdapter adapter = _adapter();
        if (msg.value == 0) revert ZeroAmount();

        // Mint via DexFi's keeper-signed payload; bonds auto-stake for the adapter.
        uint256 amount = adapter.mintBonds{value: msg.value}(mintData);
        if (amount == 0) revert NothingMinted();

        bondCount[msg.sender] += amount;
        totalBondCount += amount;
        emit ETHDeposited(msg.sender, msg.value, amount);
    }

    /// @inheritdoc ICollateralVault
    function withdrawBonds(uint256 amount) external nonReentrant {
        ICustodyAdapter adapter = _adapter();
        uint256 held = bondCount[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > held) revert InsufficientCollateral(amount, held);

        // Withdrawal rule (PRD §4.1): free when debt-clear, else the remaining
        // collateral must keep LTV within maxLTV. The formula lives in LtvMath so
        // borrowing and withdrawing can never disagree about what is safe.
        if (creditManager != address(0)) {
            uint256 debt = ICreditManager(creditManager).debtOf(msg.sender);
            if (debt > 0) {
                // Releasing collateral raises LTV exactly as borrowing does, so it
                // must not price against a stale NAV (PRD §4.6).
                if (navOracle.isStale()) revert NavStale();
                uint256 remainingValue = LtvMath.collateralValue(held - amount, navOracle.navPerBond());
                if (LtvMath.exceedsLtv(debt, remainingValue, Config.MAX_LTV_BPS)) {
                    revert WithdrawalExceedsMaxLtv(LtvMath.ltvBps(debt, remainingValue));
                }
            }
        }

        bondCount[msg.sender] = held - amount;
        totalBondCount -= amount;
        emit BondsWithdrawn(msg.sender, amount);

        // The farm settles the whole position's pending USDC on any withdrawal, so
        // this path moves protocol-wide yield. Surface it, or an epoch's yield can
        // leave through here with the accounted harvest reading zero.
        uint256 swept = adapter.unstake(amount);
        if (swept != 0) emit YieldHarvested(swept);
        adapter.transferBonds(msg.sender, amount);
    }

    /// @inheritdoc ICollateralVault
    function seize(address owner_, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != liquidationAuction) revert NotLiquidationAuction();
        ICustodyAdapter adapter = _adapter();

        amount = bondCount[owner_];
        if (amount == 0) return 0;
        bondCount[owner_] = 0;
        totalBondCount -= amount;
        emit BondsSeized(owner_, to, amount);

        // The farm settles the whole position's pending USDC on any withdrawal, so
        // this path moves protocol-wide yield. Surface it, or an epoch's yield can
        // leave through here with the accounted harvest reading zero.
        uint256 swept = adapter.unstake(amount);
        if (swept != 0) emit YieldHarvested(swept);
        adapter.transferBonds(to, amount);
    }

    /// @inheritdoc ICollateralVault
    /// @dev Deliberately ungated on staleness: liquidations must keep pricing on the
    ///      last known NAV (PRD §4.6). Callers that gate state changes must check
    ///      `navOracle.isStale()` themselves, as `withdrawBonds` and
    ///      `CreditManager.borrow` do. Likewise ungated on `custodyIsSolvent()`, so
    ///      liquidation keeps working after a break-glass exit.
    function collateralValue(address owner_) external view returns (uint256) {
        return LtvMath.collateralValue(bondCount[owner_], navOracle.navPerBond());
    }

    /// @notice True when custody holds at least as many bonds as the ledger records.
    /// @dev `DirectCallAdapter.emergencyUnstake` empties the farm position without
    ///      touching `bondCount`, so after a break-glass exit the ledger prices
    ///      collateral that is no longer held. Withdrawals revert on their own (there
    ///      is nothing to unstake), but nothing stopped *new borrowing* against it,
    ///      which is unrecoverable. `CreditManager.borrow` gates on this.
    ///
    ///      Reads live farm state, so it is also the honest version of the check
    ///      `setCustodyAdapter` makes: `stakedBalance() == 0` proves nothing while the
    ///      ledger is non-empty.
    function custodyIsSolvent() public view returns (bool) {
        ICustodyAdapter adapter = custodyAdapter;
        if (address(adapter) == address(0)) return false;
        return adapter.stakedBalance() >= totalBondCount;
    }

    // ── Yield ────────────────────────────────────────────────────────────────

    /// @notice Pull accrued USDC from the farm into this vault.
    /// @dev TODO(phase-3): EpochHarvester becomes the caller and the USDC is split
    ///      per PRD §4.4; until then the owner triggers claims and funds accumulate
    ///      here untouched.
    // slither-disable-next-line reentrancy-events
    function harvestYield() external onlyOwner returns (uint256 usdcAmount) {
        usdcAmount = _adapter().claimYield();
        emit YieldHarvested(usdcAmount);
    }

    function _adapter() internal view returns (ICustodyAdapter adapter) {
        adapter = custodyAdapter;
        if (address(adapter) == address(0)) revert AdapterNotSet();
    }
}
