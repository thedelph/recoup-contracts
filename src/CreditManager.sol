// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICreditManager} from "./interfaces/ICreditManager.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {INAVOracle} from "./interfaces/INAVOracle.sol";

/// @title CreditManager (skeleton — PRD §4.3)
/// @notice Debt accounting. No borrow interest in v1: lender return comes from the
///         yield split, not from borrowers. Debt is monotonically non-increasing
///         absent new borrow() calls (a core invariant, PRD §8).
/// @dev TODO(phase-2): implement borrow/repay/applyYield; TODO(phase-3): liquidate.
contract CreditManager is ICreditManager, Ownable, Pausable, ReentrancyGuard {
    error NotImplemented();
    error NotEpochHarvester();

    IERC20 public immutable usdc;
    ICollateralVault public immutable vault;
    INAVOracle public immutable navOracle;
    address public lenderPool;
    address public epochHarvester;
    address public liquidationAuction;

    /// @inheritdoc ICreditManager
    mapping(address => uint256) public override debtOf;
    /// @notice Yield applied beyond debt, plus post-liquidation surplus, claimable in USDC.
    mapping(address => uint256) public claimableOf;
    /// @inheritdoc ICreditManager
    uint256 public override totalDebt;
    /// @notice USDC held here to absorb auction shortfalls first (PRD §4.4).
    uint256 public insuranceFund;

    constructor(IERC20 usdc_, ICollateralVault vault_, INAVOracle navOracle_, address initialOwner)
        Ownable(initialOwner)
    {
        usdc = usdc_;
        vault = vault_;
        navOracle = navOracle_;
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    function setLenderPool(address lenderPool_) external onlyOwner {
        lenderPool = lenderPool_;
    }

    function setEpochHarvester(address epochHarvester_) external onlyOwner {
        epochHarvester = epochHarvester_;
    }

    function setLiquidationAuction(address liquidationAuction_) external onlyOwner {
        liquidationAuction = liquidationAuction_;
    }

    // ── ICreditManager ───────────────────────────────────────────────────────

    /// @inheritdoc ICreditManager
    function borrow(uint256) external whenNotPaused nonReentrant {
        revert NotImplemented(); // TODO(phase-2): LTV check, caps, NAV staleness gate, pull from LenderPool
    }

    /// @inheritdoc ICreditManager
    function repay(uint256) external nonReentrant {
        revert NotImplemented(); // TODO(phase-2): always allowed, even when paused? decide + document
    }

    /// @inheritdoc ICreditManager
    function applyYield(address, uint256) external {
        if (msg.sender != epochHarvester) revert NotEpochHarvester();
        revert NotImplemented(); // TODO(phase-2): write down debt, overflow → claimableOf
    }

    /// @inheritdoc ICreditManager
    function claimSurplus() external nonReentrant {
        revert NotImplemented(); // TODO(phase-2)
    }

    /// @inheritdoc ICreditManager
    function liquidate(address) external nonReentrant {
        revert NotImplemented(); // TODO(phase-3): HF < 1 check, start auction, caller reward
    }

    /// @inheritdoc ICreditManager
    function currentLtvBps(address) external view returns (uint256) {
        revert NotImplemented(); // TODO(phase-2): debt × BPS / collateralValue (decimal-normalised)
    }

    /// @inheritdoc ICreditManager
    function healthFactor(address) external view returns (uint256) {
        revert NotImplemented(); // TODO(phase-2): liquidationThreshold × 1e18 / currentLTV
    }
}
