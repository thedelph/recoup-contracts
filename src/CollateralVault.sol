// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Config} from "./Config.sol";
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

    event YieldHarvested(uint256 usdcAmount);

    IDexFiBond public immutable bond;
    INAVOracle public immutable navOracle;
    /// @notice Pluggable custody backend (direct-call vs Safe) — §4.1 config decision.
    ICustodyAdapter public custodyAdapter;
    address public creditManager;
    address public liquidationAuction;

    /// @inheritdoc ICollateralVault
    mapping(address => uint256) public override bondCount;

    constructor(IDexFiBond bond_, INAVOracle navOracle_, address initialOwner) Ownable(initialOwner) {
        bond = bond_;
        navOracle = navOracle_;
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    function setCustodyAdapter(ICustodyAdapter adapter) external onlyOwner {
        custodyAdapter = adapter;
    }

    function setCreditManager(address creditManager_) external onlyOwner {
        creditManager = creditManager_;
    }

    function setLiquidationAuction(address liquidationAuction_) external onlyOwner {
        liquidationAuction = liquidationAuction_;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ── ICollateralVault ─────────────────────────────────────────────────────

    /// @inheritdoc ICollateralVault
    function depositBonds(uint256 amount) external whenNotPaused nonReentrant {
        ICustodyAdapter adapter = _adapter();
        if (amount == 0) revert ZeroAmount();

        bondCount[msg.sender] += amount;
        emit BondsDeposited(msg.sender, amount);

        // Passes DexFi's whitelist iff the adapter is whitelisted (to-side).
        bond.safeTransferFrom(msg.sender, address(adapter), Config.DEXFI_BOND_TOKEN_ID, amount, "");
        adapter.stake(amount);
    }

    /// @inheritdoc ICollateralVault
    function depositETH(bytes calldata mintData) external payable whenNotPaused nonReentrant {
        ICustodyAdapter adapter = _adapter();
        if (msg.value == 0) revert ZeroAmount();

        // Mint via DexFi's keeper-signed payload; bonds auto-stake for the adapter.
        uint256 amount = adapter.mintBonds{value: msg.value}(mintData);
        if (amount == 0) revert NothingMinted();

        bondCount[msg.sender] += amount;
        emit ETHDeposited(msg.sender, msg.value, amount);
    }

    /// @inheritdoc ICollateralVault
    function withdrawBonds(uint256 amount) external nonReentrant {
        ICustodyAdapter adapter = _adapter();
        uint256 held = bondCount[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > held) revert InsufficientCollateral(amount, held);

        // Withdrawal rule (PRD §4.1): free when debt-clear, else the remaining
        // collateral must keep LTV within maxLTV.
        // TODO(phase-2): route this check through CreditManager once borrow() lands,
        // so the LTV formula lives in exactly one place.
        if (creditManager != address(0)) {
            uint256 debt = ICreditManager(creditManager).debtOf(msg.sender);
            if (debt > 0) {
                uint256 remainingValue = (held - amount) * navOracle.navPerBond(); // USD, 8dp
                uint256 debtNavScale = debt * Config.USDC_TO_NAV_SCALE; // USDC 6dp → 8dp
                if (remainingValue == 0) revert WithdrawalExceedsMaxLtv(type(uint256).max);
                uint256 postLtvBps = (debtNavScale * Config.BPS) / remainingValue;
                if (postLtvBps > Config.MAX_LTV_BPS) revert WithdrawalExceedsMaxLtv(postLtvBps);
            }
        }

        bondCount[msg.sender] = held - amount;
        emit BondsWithdrawn(msg.sender, amount);

        adapter.unstake(amount);
        adapter.transferBonds(msg.sender, amount);
    }

    /// @inheritdoc ICollateralVault
    function seize(address owner_, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != liquidationAuction) revert NotLiquidationAuction();
        ICustodyAdapter adapter = _adapter();

        amount = bondCount[owner_];
        if (amount == 0) return 0;
        bondCount[owner_] = 0;
        emit BondsSeized(owner_, to, amount);

        adapter.unstake(amount);
        adapter.transferBonds(to, amount);
    }

    /// @inheritdoc ICollateralVault
    function collateralValue(address owner_) external view returns (uint256) {
        return bondCount[owner_] * navOracle.navPerBond();
    }

    // ── Yield ────────────────────────────────────────────────────────────────

    /// @notice Pull accrued USDC from the farm into this vault.
    /// @dev TODO(phase-3): EpochHarvester becomes the caller and the USDC is split
    ///      per PRD §4.4; until then the owner triggers claims and funds accumulate
    ///      here untouched.
    function harvestYield() external onlyOwner returns (uint256 usdcAmount) {
        usdcAmount = _adapter().claimYield();
        emit YieldHarvested(usdcAmount);
    }

    function _adapter() internal view returns (ICustodyAdapter adapter) {
        adapter = custodyAdapter;
        if (address(adapter) == address(0)) revert AdapterNotSet();
    }
}
