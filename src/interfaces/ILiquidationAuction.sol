// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {INAVOracle} from "./INAVOracle.sol";
import {IRiskParams} from "./IRiskParams.sol";

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
    /// @dev Total once the auction's clock has run out, and audit round 20 is why. If the position
    ///      healed during the window there is nothing to seize, so this resolves the auction the
    ///      way `cancel` does - same body, same zero payment - instead of reverting on the vault's
    ///      liquidatable check and leaving a caller who has no other legal move.
    function expireToWorkout(uint256 auctionId) external;

    /// @return price current Dutch price in USDC for the whole lot
    function currentPrice(uint256 auctionId) external view returns (uint256 price);

    /// @notice The live auction against a borrower, or 0. One at a time.
    /// @dev Read by `CreditManager` to size the impairment a live liquidation carries in the
    ///      lender pool. Zero is unambiguous: ids are pre-incremented so none is ever issued.
    function auctionOf(address borrower) external view returns (uint256 auctionId);

    /// @notice USDC an in-flight fill has already paid in against this borrower's loan.
    /// @dev Non-zero only inside a `bid`, between the winner's payment landing and the first
    ///      statement that applies that payment to `debtOf`. `CreditManager` nets it off the mark
    ///      so the recovery is recognised before the winner's ERC-1155 callback can spend the
    ///      un-netted figure on a third party. Zero at rest, and zero for every borrower with no
    ///      fill in flight.
    ///
    ///      **The window ends at the debt reduction, not at the write-down**, and audit round 16 is
    ///      the difference. This sentence used to say "the debt being written down", which is a
    ///      wider window: the repayment leg reduces `debtOf` and re-derives the mark well before
    ///      any loss is booked, so a slot still standing there let the same fill be subtracted
    ///      twice. The implementation now matches this description; it did not before.
    function recognisedRecoveryOf(address borrower) external view returns (uint256 recovered);

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

    /// @notice The risk configuration this auction reads.
    /// @dev **Audit round 20.** `cancel` decides whether a position has healed and `bid` reaches
    ///      the vault's own `seize` check; the completeness of the three exits rests on those two
    ///      predicates being exact complements, which they only are while both contracts read one
    ///      authority. Exposed so the setters that install this auction can require exactly that.
    function riskParams() external view returns (IRiskParams);

    /// @notice The NAV feed this auction prices from.
    /// @dev **Audit round 21.** `start` fixes the whole Dutch curve off this feed and the curve is
    ///      then frozen for the auction's life, while the debt it settles, the health gate it
    ///      passed and the write-down it triggers are all computed off the vault's. An auction on a
    ///      second feed therefore sells the collateral at a price nothing else in the protocol
    ///      agrees with, and no comparison anywhere notices. Exposed so the setters that install
    ///      this auction can require the feeds to be the same one.
    function navOracle() external view returns (INAVOracle);
}
