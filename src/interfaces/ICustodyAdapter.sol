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
    /// @param mintData ABI-encoded IDexFiBond.MintDataInput obtained from DexFi's
    ///        backend (keeper-signed) by the frontend.
    function mintBonds(bytes calldata mintData) external payable returns (uint256 amount);

    /// @notice Stake bond units into the DexFi farm.
    function stake(uint256 amount) external;

    /// @notice Unstake bond units from the farm (withdrawal / liquidation path).
    function unstake(uint256 amount) external;

    /// @notice Claim accrued USDC yield from the farm (farm's `withdraw(0)`).
    function claimYield() external returns (uint256 usdcAmount);

    /// @notice Transfer bond units out of custody (withdrawal to owner, or auction
    ///         winner). Requires the adapter to be on DexFi's transfer whitelist.
    function transferBonds(address to, uint256 amount) external;
}
