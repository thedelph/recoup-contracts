// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ILiquiditySource
/// @notice Where `CreditManager.borrow` gets its USDC, and where repaid principal
///         goes back to (PRD §4.3).
/// @dev The signatures deliberately match the ones `ILenderPool` already declares, so
///      the Phase 4 swap is `ILenderPool is IERC4626, ILiquiditySource` with the
///      duplicate declarations dropped.
///
///      The PRD has `borrow` pulling straight from the LenderPool. This seam lets Phase 2
///      borrow against a plain treasury float instead, which is still the wiring the deploy
///      script ships.
///
///      It used to name two deferred issues in the pool's ERC-4626 accounting that were
///      "harmless only while it cannot lend". The first, share-price manipulation on an unset
///      decimals offset, was closed when the pool was built - the offset is 3. The second, loss
///      recognition lagging the auction window, was round-10 finding 7, and it took three attempts
///      to close: a gate refusing the ERC-4626 exits while an auction or workout was live (round 11
///      found it left the withdrawal queue open, which is a self-service exit), the same gate
///      extended over the queue, and finally the gate deleted outright in favour of impairment
///      pricing. `CreditManager` now marks the expected shortfall into `LenderPool` the moment an
///      auction opens, every terminal transition of the auction releases it, and exits price on
///      `exitAssets()` while entries stay on `totalAssets()` - so a leaver already carries the
///      expected loss and an entrant cannot buy the discount. Nothing is refused and nothing is
///      routed anywhere; the price simply stopped being stale.
///
///      **Do not read that as "the swap is safe now."** Round 11 left further open items against
///      this seam, recorded in the private security notes rather than here. The swap still waits.
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
