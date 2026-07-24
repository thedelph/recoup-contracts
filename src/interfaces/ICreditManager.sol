// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ICreditManager
/// @notice Debt accounting: borrow, optional manual repay, yield-driven write-down,
///         liquidation trigger (PRD §4.3). No borrow interest in v1.
interface ICreditManager {
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount);
    event YieldApplied(address indexed borrower, uint256 debtReduced, uint256 overflowToClaimable);
    event LiquidationTriggered(address indexed borrower, address indexed caller, uint256 callerReward);
    event SurplusClaimed(address indexed borrower, uint256 amount);

    /// @notice Borrow USDC against collateral. Reverts if post-borrow LTV > maxLTV,
    ///         NAV is stale, or a borrow cap is hit.
    function borrow(uint256 amount) external;

    /// @notice Optional manual repayment, always allowed.
    function repay(uint256 amount) external;

    /// @notice Reduce a borrower's debt from harvested yield; overflow beyond debt
    ///         accrues to their claimable USDC balance. EpochHarvester only.
    function applyYield(address borrower, uint256 amount) external;

    /// @notice Claim yield accrued beyond debt (and post-liquidation surplus).
    function claimSurplus() external;

    /// @notice Start a Dutch auction for an unhealthy position. Callable by anyone
    ///         when health factor < 1.0; caller earns a small reward.
    function liquidate(address borrower) external;

    function debtOf(address borrower) external view returns (uint256);

    function totalDebt() external view returns (uint256);

    /// @return ltvBps debt / collateralValue in bps; type(uint256).max if no collateral
    function currentLtvBps(address borrower) external view returns (uint256 ltvBps);

    /// @return hf liquidationThreshold / currentLTV, 1e18 fixed point; < 1e18 ⇒ liquidatable
    function healthFactor(address borrower) external view returns (uint256 hf);
}
