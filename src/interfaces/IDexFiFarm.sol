// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IDexFiFarm
/// @notice DexFi bond staking pool - "RewardPoolBondsMigration" behind the ERC1967
///         proxy at Config.DEXFI_FARM. MasterChef-style accounting; rewards paid in
///         USDC. First reviewed on-chain 2026-07-24; **re-read in audit round 34 from
///         the resolved proxy implementation's verified source on Base mainnet, which
///         falsified two of the access-control claims that stood here.**
///
///         Access control, as measured rather than as assumed:
///         - `deposit(uint256)` **is** permissionless, but it credits `msg.sender` and
///           only `msg.sender`. It cannot seed another address.
///         - `withdraw(uint256)` is permissionless and **strictly self-scoped**: there
///           is no account parameter, so a caller can only ever unstake and claim its
///           own position. `withdraw(0)` pays out pending USDC without unstaking, and
///           is the claim primitive for EpochHarvester.
///         - `depositForAccount(address,uint256)` and `depositForAccounts(address[],
///           uint256[])` are **`onlyHandler`**, which is
///           `require(isHandler[msg.sender], CallerNotHandler(msg.sender))`. The
///           docstring that used to stand here described them as having no access
///           control at all, and that was measurably false.
///         - **Four live handlers, and every one of them is a DexFi key**: the bond
///           contract, the DexFi treasury EOA (which is also `owner()` of both
///           contracts), an `Affiliate` proxy, and one EOA carrying an EIP-7702
///           delegation. A fifth was revoked. So the credit-somebody-else door is a
///           DexFi-only door, not an open one.
///         - `_deposit` pulls the bonds with `safeTransferFrom(msg.sender, ...)`, so
///           **even a handler must itself own the bonds and have approved the farm.**
///           Handler status buys the right to name the credited account, not the
///           ability to move somebody else's balance.
///         - Staking custodies the ERC-1155 balance in the pool (transfer passes the
///           bond whitelist because the pool is whitelisted).
///         - **UUPS-upgradeable by the treasury EOA**, which can also `setUsersDebt`
///           (rewrite reward accounting), add or remove handlers, and `recover`
///           tokens. Treat farm behaviour as mutable at DexFi's discretion.
///
///         **`userDebt` is a third reward component and our model denies it exists.**
///         It is written by the owner, `pendingShare` adds it in unconditionally, but
///         `withdraw` only pays it inside `if (_pending > 0)` and otherwise never
///         clears it. So `pendingShare` can report a balance that `withdraw` will
///         never pay, permanently. Nothing downstream of this interface may treat
///         `pendingShare` as a promise of cash.
///
///         **This interface is deliberately partial.** It does not declare `userDebt`,
///         `isHandler`, `setUsersDebt`, `depositForAccounts` or
///         `depositFundsForInterval`, so none of them is reachable through it. Read the
///         live implementation, not this file, before reasoning about any of them.
///
///         **`test/mocks/MockFarm.sol` models a narrower rule than reality**: it gates
///         the credit-another-account path with an `onlyBond` check, where the live
///         farm gates it with `onlyHandler` over a four-member set. Every negative test
///         written against the mock is therefore evidence about a stricter world than
///         the one we deploy into.
interface IDexFiFarm {
    /// @notice Stake `amount` bond units (requires ERC-1155 approval to the pool).
    ///         Permissionless, and credits `msg.sender` only.
    function deposit(uint256 amount) external;

    /// @notice Unstake `amount` bond units and receive any pending USDC rewards.
    ///         `withdraw(0)` = claim rewards only. Permissionless and self-scoped:
    ///         there is no account parameter.
    function withdraw(uint256 amount) external;

    /// @notice Unstake everything, forfeiting pending rewards.
    function emergencyWithdraw() external;

    /// @notice Stake `amount` on behalf of `account`. This is how bonds auto-stake
    ///         on mint: the bond contract mints to the pool and credits the buyer.
    /// @dev **`onlyHandler` on the live farm**, over the four-member DexFi-controlled
    ///      set described above, and the bonds still come from `msg.sender`. We are not
    ///      a handler, so this is documented for reading DexFi's behaviour rather than
    ///      for calling.
    function depositForAccount(address account, uint256 amount) external;

    /// @return Pending (unclaimed) USDC rewards for `account`.
    /// @dev Includes the owner-written `userDebt` component unconditionally, which
    ///      `withdraw` may never pay. See the note on the interface.
    function pendingShare(address account) external view returns (uint256);

    /// @return amount staked bond units, rewardDebt MasterChef reward debt
    function userInfo(address account) external view returns (uint256 amount, uint256 rewardDebt);

    function poolEndTime() external view returns (uint256);
}
