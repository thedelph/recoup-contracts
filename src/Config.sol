// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title Config
/// @notice Single source of truth for every protocol parameter and external address.
///         PRD rule: no magic numbers anywhere else — all bps values use the 10_000
///         denominator (`BPS`). Initial values from PRD §5 (risk) and §4.4 (yield split);
///         at deployment these seed admin-tunable storage behind a 48h timelock.
library Config {
    uint256 internal constant BPS = 10_000;

    // ── Risk parameters (PRD §5) ─────────────────────────────────────────────
    uint256 internal constant MAX_LTV_BPS = 3_500;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 5_800;
    uint256 internal constant GLOBAL_BORROW_CAP = 250_000e6; // USDC, 6 decimals
    uint256 internal constant PER_ACCOUNT_BORROW_CAP = 25_000e6;
    uint256 internal constant RESERVE_RATIO_BPS = 1_500; // LenderPool hot float target
    uint256 internal constant INSURANCE_FUND_TARGET_BPS = 500; // ≥5% of outstanding debt per cap raise
    uint256 internal constant UNDERWRITING_APR_BPS = 2_500; // UI/modelling only, never marketed

    // ── Liquidation auction (PRD §4.5) ───────────────────────────────────────
    uint256 internal constant AUCTION_START_PREMIUM_BPS = 10_000; // 100% of NAV
    uint256 internal constant AUCTION_FLOOR_BPS = 6_500; // 65% of NAV
    uint256 internal constant AUCTION_DURATION = 6 hours;
    uint256 internal constant LIQUIDATION_PENALTY_BPS = 500; // of debt; split 50/50 caller/insurance

    // ── Yield split (PRD §4.4) — must sum to BPS, enforced in tests ─────────
    uint256 internal constant SPLIT_BORROWER_BPS = 5_500;
    uint256 internal constant SPLIT_LENDER_BPS = 2_500;
    uint256 internal constant SPLIT_INSURANCE_BPS = 1_000;
    uint256 internal constant SPLIT_PROTOCOL_BPS = 1_000;

    // ── Epoch harvesting (PRD §4.4) ──────────────────────────────────────────
    uint256 internal constant MIN_EPOCH_GAP = 5 days;

    // ── NAV oracle guards (PRD §4.6) ─────────────────────────────────────────
    uint256 internal constant NAV_MAX_DEVIATION_BPS = 1_000;
    uint256 internal constant NAV_PENDING_DELAY = 12 hours; // large moves wait for 2nd key
    uint256 internal constant NAV_STALENESS = 8 days; // older ⇒ borrow paused
    uint8 internal constant NAV_DECIMALS = 8; // navPerBond posted in USD, 8 decimals
    uint256 internal constant USDC_TO_NAV_SCALE = 1e2; // 10^(NAV_DECIMALS − USDC's 6 dp)

    // ── Governance (PRD §9) ──────────────────────────────────────────────────
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    // ── External addresses (PRD §7) ──────────────────────────────────────────
    // Resolved and verified 2026-07-24 via Blockscout source review of the live contracts.
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant DEXFI_TREASURY_EOA = 0xd4ec4E5b7625Fed3c40Bfeec206E49396F02Dd54;

    /// @dev "NFTBondsMigration": ERC-1155, single TOKEN_ID = 0, verified, immutable
    ///      (no proxy). Wallet↔wallet transfers whitelist-gated; owner = treasury EOA.
    ///      This contract is ALSO the mint entrypoint (payable `mint` gated by an
    ///      EIP-712 signature from DexFi's keeper/owner — no on-chain referral param).
    address internal constant DEXFI_BOND_NFT = 0x969C6eCF97c256846029cBCBB865824E505E006f;
    address internal constant DEXFI_MINT_ENTRYPOINT = DEXFI_BOND_NFT;
    /// @dev "RewardPoolBondsMigration" behind an ERC1967/UUPS proxy (impl
    ///      0xdfb45A77…9A10, upgradeable by the treasury EOA). deposit/withdraw are
    ///      permissionless and NOT EOA-gated; withdraw(0) claims USDC rewards.
    address internal constant DEXFI_FARM = 0x0251cbB9a752331D29031eEc88c5a8BCbcDafFfa;
    /// @dev EIP-712 signer for bond mints (informational — mint flow needs DexFi's
    ///      backend to co-sign).
    address internal constant DEXFI_MINT_KEEPER = 0xBbBBBA31F7fD7E1ACAcAb33d905941f1F3A6ad91;
    /// @dev Chainlink ETH/USD reference feed, Base mainnet, 8 decimals.
    address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    /// @dev The bond token id — the bond is a fungible ERC-1155 balance, not
    ///      distinct NFTs. "Bond count" everywhere means balanceOf(id 0).
    uint256 internal constant DEXFI_BOND_TOKEN_ID = 0;
}
