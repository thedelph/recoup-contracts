// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ILiquidationAuction
/// @notice Dutch auction of a liquidated position's whole bond lot (PRD §4.5).
///         Linear decay from startPremium×NAV to floor over the auction duration;
///         expiry falls back to the DexFi manual-redemption workout path.
interface ILiquidationAuction {
    event AuctionStarted(uint256 indexed auctionId, address indexed borrower, uint256 bondCount, uint256 startPrice);
    event AuctionFilled(uint256 indexed auctionId, address indexed winner, uint256 price, uint256 debtRepaid, uint256 surplusToBorrower);
    event AuctionExpiredToWorkout(uint256 indexed auctionId);

    /// @notice Open an auction for an unhealthy position. CreditManager only.
    function start(address borrower) external returns (uint256 auctionId);

    /// @notice Buy the lot at the current Dutch price in USDC.
    function bid(uint256 auctionId) external;

    /// @notice After expiry unfilled: move bonds to the workout queue for DexFi
    ///         manual redemption; shortfall → insurance fund → socialised loss.
    function expireToWorkout(uint256 auctionId) external;

    /// @return price current Dutch price in USDC for the whole lot
    function currentPrice(uint256 auctionId) external view returns (uint256 price);
}
