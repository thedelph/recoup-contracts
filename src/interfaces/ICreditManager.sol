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

    /// @return ltvBps debt / collateralValue in bps. Zero when there is no debt,
    ///         whatever the collateral; type(uint256).max when there is debt against
    ///         no collateral. The debt-first ordering matters: otherwise every empty
    ///         address reports maximum LTV and keeper scanners queue liquidations for
    ///         accounts that do not exist.
    function currentLtvBps(address borrower) external view returns (uint256 ltvBps);

    /// @return hf liquidationThreshold / currentLTV, 1e18 fixed point; < 1e18 ⇒ liquidatable.
    ///         A view for keepers and the UI only. It divides twice, so a position a
    ///         fraction of a bp past the threshold still reads as exactly 1e18: gate
    ///         liquidation on a direct comparison, not on this.
    function healthFactor(address borrower) external view returns (uint256 hf);
}
