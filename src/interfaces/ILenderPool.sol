// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILiquiditySource} from "./ILiquiditySource.sol";

/// @title ILenderPool
/// @notice ERC-4626 USDC vault lending exclusively to CreditManager, with a FIFO
///         withdrawal queue when idle USDC is short (PRD §4.2).
interface ILenderPool is IERC4626, ILiquiditySource {
    event Lent(uint256 amount);
    event PrincipalRepaid(uint256 amount);
    /// @param amount The epoch's newly delivered lender share.
    /// @param ratePerSecond Release rate, scaled by the implementation's fixed-point precision.
    /// @param streamEndsAt When the pot currently being released runs dry.
    /// @dev Carries the stream terms, not just the amount, because the lender share is released
    ///      over a window rather than credited at once - so the amount alone does not describe
    ///      what happens to the share price.
    ///
    ///      **This signature was wrong here until an internal audit round caught it**, and the
    ///      shape of the mistake is worth leaving on the record: this line said `(uint256)` while
    ///      the Phase-4 implementation emits three parameters. A different signature is a
    ///      different `topic0`, so an indexer built from the published ABI would have matched on
    ///      an event the chain never emits and reported no yield at all - failing silently, which
    ///      is the worst way for a published interface to be wrong. The implementation now
    ///      declares `is ILenderPool` so the compiler holds the two together.
    event YieldDistributed(uint256 amount, uint256 ratePerSecond, uint256 streamEndsAt);
    event LossSocialised(uint256 amount);
    event WithdrawalQueued(address indexed lender, uint256 indexed queueIndex, uint256 assets);
    event QueuedWithdrawalServiced(address indexed lender, uint256 indexed queueIndex, uint256 assets);

    // `lend`, `repayPrincipal` and `available` come from ILiquiditySource, which the
    // Phase 2 treasury float also implements. That is the whole point of the seam:
    // swapping the pool in behind CreditManager needs no change to CreditManager.

    /// @notice Receive the lender share of harvested yield - raises share price.
    ///         EpochHarvester only.
    function distributeYield(uint256 amount) external;

    /// @notice Write a shortfall (post-auction, post-insurance) down against the pool.
    ///         Must be loud: PRD §4.2 requires prominent disclosure of socialised loss.
    function socialiseLoss(uint256 amount) external;

    /// @return index position in the FIFO queue (0 = next), remaining assets still owed
    function queuePosition(address lender) external view returns (uint256 index, uint256 remaining);
}
