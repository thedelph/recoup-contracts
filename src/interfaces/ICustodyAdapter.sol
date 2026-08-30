// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ICustodyAdapter
/// @notice Pluggable custody backend for CollateralVault (PRD §4.1). Two planned
///         implementations, chosen once before mainnet based on Phase 0 findings:
///         - DirectCallAdapter: vault contract calls DexFi mint/stake/claim itself.
///           (Phase 0 verdict: farm calls are contract-callable; bond transfers
///           need DexFi to whitelist the adapter; mint needs a DexFi-signed
///           EIP-712 payload passed through from the frontend.)
///         - SafeAdapter: custody sits in a 3-of-4 Gnosis Safe; vault is
///           accounting-only.
/// @dev Bonds are fungible ERC-1155 units (id 0), so all quantities are amounts.
interface ICustodyAdapter {
    /// @notice Mint new bonds from ETH via DexFi's signature-gated purchase flow.
    /// @param beneficiary Vault depositor whose independently salted attempt this is.
    /// @param attemptId Fresh random identifier used to derive the attempt receiver.
    /// @param mintData ABI-encoded IDexFiBond.MintDataInput obtained from DexFi's
    ///        backend (keeper-signed) by the frontend.
    function mintBonds(address beneficiary, bytes32 attemptId, bytes calldata mintData)
        external
        payable
        returns (uint256 amount);

    /// @notice Stake bond units into the DexFi farm.
    /// @return swept USDC the farm paid out alongside the stake and that was forwarded
    ///         onward. The farm is MasterChef-style, so `deposit` settles the whole
    ///         staked position's pending rewards exactly as `withdraw` does - meaning
    ///         a deposit can flush a whole epoch of every borrower's yield. Same
    ///         accounting obligation as `unstake`: report it or it leaves silently.
    function stake(uint256 amount) external returns (uint256 swept);

    /// @notice Unstake bond units from the farm (withdrawal / liquidation path).
    /// @return swept USDC the farm paid out alongside the unstake and that was
    ///         forwarded onward. The farm settles the whole staked position's pending
    ///         rewards on any withdrawal, so this is protocol-wide yield, not the
    ///         caller's share, and it must be accounted for rather than discarded.
    function unstake(uint256 amount) external returns (uint256 swept);

    /// @notice Claim accrued USDC yield from the farm (farm's `withdraw(0)`).
    /// @return usdcAmount The amount forwarded to the yield recipient. Implementations
    ///         must report exactly what they transfer.
    function claimYield() external returns (uint256 usdcAmount);

    /// @notice Transfer bond units out of custody (withdrawal to owner, or auction
    ///         winner). Requires the adapter to be on DexFi's transfer whitelist.
    function transferBonds(address to, uint256 amount) external;

    /// @notice Running total of USDC this adapter has measured arriving *from the farm*
    ///         and forwarded on to the yield recipient. Never decreases.
    /// @dev The corroboration signal an epoch is rated against. `EpochHarvester.harvest`
    ///      sizes an epoch from its own USDC balance - it has to, because farm yield
    ///      reaches it through several paths that report nothing - and a balance has no
    ///      sender attribution, so the harvester needs a second number to tell an epoch
    ///      the farm funded from one a stranger funded with a transfer.
    ///
    ///      Implementations MUST count only what they measured the farm pay, and MUST NOT
    ///      count a raw balance or a swept amount that could include a donation. Audit
    ///      round 11 priced what an implementation that conflates the two gives away:
    ///      ~$1.82 of donated USDC bought a write to `CreditManager.lastDistributeAt`,
    ///      the anti-just-in-time window's only input, and repeating that purchase at
    ///      `Config.YIELD_STREAM_DURATION` intervals stopped a long accrual window from
    ///      ever forming - turning a $495 just-in-time take into $5,940.
    ///
    ///      It counts every farm-touching path, not just `claimYield`. That is the whole
    ///      reason it is a counter rather than a boolean: this farm is MasterChef-style,
    ///      so `stake`, `unstake` and `mintBonds` settle the position too, and a signal
    ///      that only noticed claims would read a wholly legitimate epoch as
    ///      uncorroborated whenever a bond moved in the same block.
    function farmYieldDelivered() external view returns (uint256);

    /// @notice The CollateralVault this adapter is bound to. The vault reads this
    ///         to reject a custody swap to an adapter wired for a different vault.
    function vault() external view returns (address);

    /// @notice Bond units currently held in custody (staked in the farm). The vault
    ///         reads this to reject a swap that would orphan a live position.
    function stakedBalance() external view returns (uint256);
}
