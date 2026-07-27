// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ICollateralVault
/// @notice Holds bond collateral (fungible ERC-1155 units, id 0), tracks per-owner
///         balances, delegates DexFi interaction to an ICustodyAdapter (PRD §4.1).
interface ICollateralVault {
    event BondsDeposited(address indexed owner, uint256 amount);
    event ETHDeposited(address indexed owner, uint256 ethAmount, uint256 bondAmount);
    event BondsWithdrawn(address indexed owner, uint256 amount);
    event BondsSeized(address indexed owner, address indexed to, uint256 amount);

    /// @notice Deposit existing bond units as collateral; vault stakes them into
    ///         the farm. Requires the depositor↔vault transfer to pass DexFi's
    ///         whitelist (vault must be whitelisted).
    function depositBonds(uint256 amount) external;

    /// @notice Deposit ETH; vault mints new bonds via the custody adapter using a
    ///         DexFi keeper-signed mint payload, and stakes them.
    function depositETH(bytes calldata mintData) external payable;

    /// @notice Withdraw bond units. Only allowed when debt is zero or resulting
    ///         LTV ≤ maxLTV.
    function withdrawBonds(uint256 amount) external;

    /// @notice Move a liquidated position's bonds to the auction winner / workout
    ///         queue. LiquidationAuction only.
    function seize(address owner, address to) external returns (uint256 amount);

    function bondCount(address owner) external view returns (uint256);

    /// @return value bondCount(owner) × navPerBond, in USD 8 decimals
    function collateralValue(address owner) external view returns (uint256 value);

    /// @notice True when custody holds at least as many bonds as the ledger records.
    /// @dev Gate new debt on this. The emergency custody exit empties the farm
    ///      position without clearing per-owner balances, so the ledger can outlive
    ///      the collateral behind it.
    function custodyIsSolvent() external view returns (bool);
}
