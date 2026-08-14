// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IDexFiFarm
/// @notice DexFi bond staking pool - "RewardPoolBondsMigration" behind the ERC1967
///         proxy at Config.DEXFI_FARM. Verified source reviewed on-chain 2026-07-24.
///         MasterChef-style accounting; rewards paid in USDC.
///
///         Integration-critical behaviours found in source:
///         - `deposit`/`withdraw` are **permissionless and not EOA-gated** - our
///           vault can stake, unstake, and claim directly.
///         - `withdraw(0)` pays out pending USDC rewards without unstaking - this
///           is the claim primitive for EpochHarvester.
///         - Staking custodies the ERC-1155 balance in the pool (transfer passes
///           the bond whitelist because the pool is whitelisted).
///         - **UUPS-upgradeable by the treasury EOA**, which can also
///           `setUsersDebt` (rewrite reward accounting) and `recover` tokens.
///           Treat farm behaviour as mutable at DexFi's discretion.
interface IDexFiFarm {
    /// @notice Stake `amount` bond units (requires ERC-1155 approval to the pool).
    function deposit(uint256 amount) external;

    /// @notice Unstake `amount` bond units and receive any pending USDC rewards.
    ///         `withdraw(0)` = claim rewards only.
    function withdraw(uint256 amount) external;

    /// @notice Unstake everything, forfeiting pending rewards.
    function emergencyWithdraw() external;

    /// @notice Stake `amount` on behalf of `account`. This is how bonds auto-stake
    ///         on mint: the bond contract mints to the pool and credits the buyer.
    function depositForAccount(address account, uint256 amount) external;

    /// @return Pending (unclaimed) USDC rewards for `account`.
    function pendingShare(address account) external view returns (uint256);

    /// @return amount staked bond units, rewardDebt MasterChef reward debt
    function userInfo(address account) external view returns (uint256 amount, uint256 rewardDebt);

    function poolEndTime() external view returns (uint256);
}
