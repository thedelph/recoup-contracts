// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ICollateralVault} from "./ICollateralVault.sol";

/// @title ICreditManager
/// @notice Debt accounting: borrow, optional manual repay, yield-driven write-down,
///         liquidation trigger (PRD §4.3). No borrow interest in v1.
interface ICreditManager {
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount);
    event YieldApplied(address indexed borrower, uint256 debtReduced, uint256 overflowToClaimable);
    /// @param callerReward What the caller earns *if* the lot sells for more than the
    ///        debt. Not paid at trigger time: the penalty is taken from surplus, and
    ///        an auction that fills below the debt has none. An entitlement ceiling.
    event LiquidationTriggered(address indexed borrower, address indexed caller, uint256 callerReward);
    event SurplusClaimed(address indexed borrower, uint256 amount);

    /// @notice Borrow USDC against collateral. Reverts if post-borrow LTV > maxLTV,
    ///         NAV is stale, or a borrow cap is hit.
    function borrow(uint256 amount) external;

    /// @notice Optional manual repayment, always allowed.
    function repay(uint256 amount) external;

    /// @notice Repay on someone else's behalf; clamps at their outstanding debt.
    /// @dev Needed for rescue (a borrower who has lost keys or been blacklisted) and
    ///      by the auction, which pays a liquidated position's debt out of the sale.
    function repayFor(address borrower, uint256 amount) external;

    /// @notice Deliver an epoch's borrower share before distributing it, so the
    ///         accumulator can only ever promise USDC that has actually arrived.
    ///         EpochHarvester only; pulls against an allowance.
    function receiveYield(uint256 amount) external;

    /// @notice Add USDC to the insurance fund, which absorbs auction shortfalls before
    ///         any loss reaches lenders. Permissionless; pulls against an allowance.
    function fundInsurance(uint256 amount) external;

    /// @notice Spread an epoch's borrower share across every bond, in one write.
    ///         EpochHarvester only, and the USDC must already have been delivered.
    /// @dev Positions are not iterated. Each one works out its own share lazily from
    ///      the difference between the running yield-per-bond and its own recorded
    ///      index, which is what lets PRD §6.2's 200+ positions settle in one call.
    function distributeYield(uint256 amount) external;

    /// @notice Apply a position's accrued yield: debt first, remainder to claimable.
    ///         Permissionless - it can only help the position it settles.
    function settle(address borrower) external;

    /// @notice Settle before the vault changes a bond count. Vault only.
    /// @param currentBonds The balance BEFORE the change, since that is what earned.
    function settleForVault(address borrower, uint256 currentBonds) external;

    /// @return Yield this position has earned but not yet settled.
    function pendingYieldOf(address borrower) external view returns (uint256);

    /// @return Debt net of unsettled yield - what the borrower actually owes.
    ///         `debtOf` is the stored figure and can be stale between settlements.
    function currentDebtOf(address borrower) external view returns (uint256);

    /// @notice Claim yield accrued beyond debt (and post-liquidation surplus).
    function claimSurplus() external;

    /// @notice Start a Dutch auction for an unhealthy position. Callable by anyone
    ///         once the position is past the liquidation threshold; the caller earns a
    ///         share of the penalty if the lot sells for more than the debt.
    function liquidate(address borrower) external;

    /// @notice Book a liquidation's insurance cut and the borrower's surplus.
    ///         LiquidationAuction only.
    function creditLiquidationProceeds(address borrower, uint256 toInsurance, uint256 toBorrower) external;

    /// @notice Recognise unrecoverable debt: insurance first, then socialised to
    ///         lenders. LiquidationAuction only.
    function writeDownLoss(address borrower, uint256 amount) external;

    /// @notice Retry placing losses the lender pool could not accept. Permissionless.
    function flushSocialisedLoss() external;

    /// @notice Re-state the reserve the lender pool holds against a borrower, from auction and
    ///         vault state. Permissionless.
    /// @dev The auction calls this on every terminal transition, inside a `try`/`catch` - its exits
    ///      must survive a pool that reverts everything. Anyone may call it because that `catch`
    ///      means a release can be dropped, and a dropped release depresses the exit price for
    ///      every lender until somebody calls this.
    function refreshImpairment(address borrower) external;

    /// @return Losses recognised on the books but not yet accepted by the lender pool.
    function unsocialisedLoss() external view returns (uint256);

    /// @notice USDC held to absorb auction shortfalls before any loss reaches lenders.
    function insuranceFund() external view returns (uint256);

    function debtOf(address borrower) external view returns (uint256);

    function totalDebt() external view returns (uint256);

    /// @notice Delivered yield not yet moved into the accumulator. The vault checks it
    ///         before a manager swap, because it is value in flight that debt does not
    ///         account for.
    function undistributedYield() external view returns (uint256);

    /// @notice The running yield-per-bond accumulator. The vault reads it to refuse a
    ///         manager that has already been live: `_settle` does not stamp an index
    ///         while detached, so re-attaching one would let any position that moved in
    ///         the meantime claim the whole accumulator against a zero index. A manager
    ///         that has never been attached reports zero.
    function accYieldPerBond() external view returns (uint256);

    /// @notice The vault this manager is bound to. Exposed so the vault can refuse to
    ///         point at a manager bound elsewhere: `settleForVault` is caller-gated on
    ///         this, and the vault settles before every bond-count change, so a
    ///         mismatched pointer reverts every deposit, withdrawal and seizure.
    function vault() external view returns (ICollateralVault);

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
