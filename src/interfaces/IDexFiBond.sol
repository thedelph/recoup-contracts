// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title IDexFiBond
/// @notice DexFi Treasury Bond - "NFTBondsMigration" at Config.DEXFI_BOND_NFT.
///         Verified source reviewed on-chain 2026-07-24.
///
///         Reality vs the PRD's original assumption: this is an **ERC-1155 with a
///         single fungible id (TOKEN_ID = 0)**, not an ERC-721. "Bond count" is
///         `balanceOf(account, 0)`. Bonds auto-stake on mint: the contract mints to
///         itself and calls `rewardPool.depositForAccount(receiver, amount)`.
///
///         Integration-critical behaviours found in source:
///         - **Transfer whitelist**: wallet↔wallet transfers require msg.sender,
///           from, or to to be in an owner-managed whitelist (currently the farm +
///           six DexFi addresses). Our vault/auction must be whitelisted by DexFi
///           for any transfer-based flow (blocker - see §14 asks).
///         - **Signature-gated mint**: `mint` is payable and requires an EIP-712
///           payload signed by DexFi's keeper/owner (uuid, nonce, receiver,
///           amountNfts, paymentAmount, deadline). No on-chain referral param.
///           Not EOA-gated - a contract can mint if DexFi's backend signs for it.
///         - **Owner powers** (owner = treasury EOA, no multisig/timelock):
///           pause, whitelist management, free unlimited `mintSingle`, treasury and
///           rewardPool replacement.
interface IDexFiBond is IERC1155 {
    struct MintDataInput {
        uint256 uuid;
        uint256 nonce;
        address receiver;
        uint256 amountNfts;
        uint256 paymentAmount;
        uint256 deadline;
        bytes signature;
    }

    function TOKEN_ID() external view returns (uint256);

    /// @notice Mint bonds for ETH. Requires a DexFi keeper/owner EIP-712 signature.
    ///         When a reward pool is set, bonds are auto-staked for `data.receiver`.
    function mint(MintDataInput memory data) external payable;

    function totalSupply(uint256 id) external view returns (uint256);

    function whitelistContains(address account) external view returns (bool);

    /// @notice Owner-only (treasury EOA). The §14 ask #5 is one call to this with
    ///         our custody adapter's address. Kept in the interface for fork tests
    ///         that impersonate the owner to prove the whitelisted lifecycle.
    function addWhitelist(address[] calldata accounts) external;

    function keeper() external view returns (address);

    function treasury() external view returns (address);

    function rewardPool() external view returns (address);

    function paused() external view returns (bool);

    function nonces(address owner) external view returns (uint256);
}
