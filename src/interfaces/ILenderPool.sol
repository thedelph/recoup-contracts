// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ILenderPool
/// @notice ERC-4626 USDC vault lending exclusively to CreditManager, with a FIFO
///         withdrawal queue when idle USDC is short (PRD §4.2).
interface ILenderPool is IERC4626 {
    event Lent(uint256 amount);
    event PrincipalRepaid(uint256 amount);
    event YieldDistributed(uint256 amount);
    event LossSocialised(uint256 amount);
    event WithdrawalQueued(address indexed lender, uint256 indexed queueIndex, uint256 assets);
    event QueuedWithdrawalServiced(address indexed lender, uint256 indexed queueIndex, uint256 assets);

    /// @notice Send USDC to CreditManager for a borrow. CreditManager only.
    function lend(uint256 amount) external;

    /// @notice Return principal (manual repayments / auction proceeds). CreditManager only.
    function repayPrincipal(uint256 amount) external;

    /// @notice Receive the lender share of harvested yield — raises share price.
    ///         EpochHarvester only.
    function distributeYield(uint256 amount) external;

    /// @notice Write a shortfall (post-auction, post-insurance) down against the pool.
    ///         Must be loud: PRD §4.2 requires prominent disclosure of socialised loss.
    function socialiseLoss(uint256 amount) external;

    /// @return index position in the FIFO queue (0 = next), remaining assets still owed
    function queuePosition(address lender) external view returns (uint256 index, uint256 remaining);
}
