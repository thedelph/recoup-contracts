// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ILiquiditySource
/// @notice Where `CreditManager.borrow` gets its USDC, and where repaid principal
///         goes back to (PRD §4.3).
/// @dev The signatures deliberately match the ones `ILenderPool` already declares, so
///      the Phase 4 swap is `ILenderPool is IERC4626, ILiquiditySource` with the
///      duplicate declarations dropped.
///
///      The PRD has `borrow` pulling straight from the LenderPool, but the pool's
///      lending functions are Phase 4 and its ERC-4626 accounting carries two known
///      deferred issues (share-price manipulation on an unset decimals offset, and
///      loss recognition lagging the auction window) that are harmless only while it
///      cannot lend. This seam lets Phase 2 borrow against a plain treasury float and
///      keeps those dormant until the phase that fixes them.
///
///      **Token movement is pull-based in both directions, and each receiver verifies
///      its own receipt:**
///      - `lend`: the source transfers USDC to the CreditManager, which measures the
///        balance delta and rejects a short delivery.
///      - `repayPrincipal`: the CreditManager approves exactly `amount` and the source
///        pulls it, so the transfer and the bookkeeping cannot come apart. A bare
///        transfer with no call would otherwise look like idle capital to the source
///        and leave its principal accounting overstated.
interface ILiquiditySource {
    /// @notice Send `amount` USDC to the CreditManager to fund a borrow.
    ///         CreditManager only.
    function lend(uint256 amount) external;

    /// @notice Pull `amount` of returned principal from the CreditManager, which has
    ///         approved exactly that much, and book it. CreditManager only.
    function repayPrincipal(uint256 amount) external;

    /// @return USDC currently available to lend. Advisory, for keepers and the UI;
    ///         `borrow` does not trust it, it verifies delivery instead.
    function available() external view returns (uint256);
}
