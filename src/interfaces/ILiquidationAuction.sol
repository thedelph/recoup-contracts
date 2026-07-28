// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ILiquidationAuction
/// @notice Dutch auction of a liquidated position's whole bond lot (PRD §4.5).
///         Linear decay from startPremium×NAV to floor over the auction duration;
///         expiry falls back to the DexFi manual-redemption workout path.
interface ILiquidationAuction {
    event AuctionStarted(
        uint256 indexed auctionId,
        address indexed borrower,
        address indexed caller,
        uint256 bondCount,
        uint256 startPrice
    );
    event AuctionFilled(uint256 indexed auctionId, address indexed winner, uint256 price, uint256 debtRepaid, uint256 surplusToBorrower);
    event AuctionCancelled(uint256 indexed auctionId, address indexed borrower);
    event AuctionExpiredToWorkout(uint256 indexed auctionId);

    /// @notice Open an auction for an unhealthy position. CreditManager only.
    /// @param caller Whoever called `CreditManager.liquidate`, who earns
    ///        `Config.LIQUIDATION_CALLER_SHARE_BPS` of the penalty if the lot sells.
    ///        Passed in rather than looked up because the reward belongs to the
    ///        trigger, not to the bidder, and the auction is the only place that
    ///        learns whether there was ever a surplus to pay it from.
    function start(address borrower, address caller) external returns (uint256 auctionId);

    /// @notice Close a live auction whose position is no longer liquidatable.
    /// @dev Permissionless. Yield streams continuously and anyone may `repayFor`, so a
    ///      position can heal mid-auction; leaving the auction live would sell
    ///      collateral that is no longer forfeit.
    function cancel(uint256 auctionId) external;

    /// @notice Buy the lot at the current Dutch price in USDC.
    function bid(uint256 auctionId) external;

    /// @notice After expiry unfilled: move bonds to the workout queue for DexFi
    ///         manual redemption; shortfall → insurance fund → socialised loss.
    function expireToWorkout(uint256 auctionId) external;

    /// @return price current Dutch price in USDC for the whole lot
    function currentPrice(uint256 auctionId) external view returns (uint256 price);

    /// @notice Auctions opened and not yet filled, cancelled, expired or superseded.
    /// @dev Exposed so the vault can refuse to repoint away from an auction that still
    ///      has work in flight. The outgoing auction is the only caller `seize` and
    ///      `reassign` accept, so a repoint over a live auction closes every exit it has.
    function liveAuctionCount() external view returns (uint256);

    /// @notice Workouts awaiting resolution.
    function openWorkoutCount() external view returns (uint256);

    /// @notice Open workouts against a borrower. Non-zero blocks new borrowing.
    function workoutsOpenFor(address borrower) external view returns (uint256);

    /// @notice The vault this auction is bound to. Checked on repoint, the same way the
    ///         custody adapter and credit manager are.
    function vault() external view returns (address);

    /// @notice The manager this auction settles against. `borrow` reads it to refuse
    ///         new debt during a migration window, when the three wiring pointers do
    ///         not yet agree and so nothing can open an auction to liquidate it.
    function creditManager() external view returns (address);
}
