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
    // Floor must cover debt + liquidation penalty at the worst LTV that can first
    // trigger a liquidation - i.e. after one immediate NAV_MAX_DEVIATION_BPS drop:
    //   THRESHOLD/(1-maxDev) x (1+penalty) = 5800/0.9 x 1.05 = 6767 bps.
    // Set above that with margin; relation asserted in Config.t.sol.
    uint256 internal constant AUCTION_FLOOR_BPS = 6_800; // 68% of NAV
    uint256 internal constant AUCTION_DURATION = 6 hours;
    uint256 internal constant LIQUIDATION_PENALTY_BPS = 500; // of debt; split 50/50 caller/insurance
    /// @notice The liquidation caller's share of the penalty; the remainder, including
    ///         any odd wei, goes to the insurance fund.
    /// @dev PRD §4.5 says "split 50/50 caller reward / insurance fund". Named rather
    ///      than written as `penalty / 2` at the call site, because a bare `/ 2` is a
    ///      magic number that cannot be found when the split is retuned.
    uint256 internal constant LIQUIDATION_CALLER_SHARE_BPS = 5_000;

    // ── Workout queue (PRD §4.5, the expiry path) ────────────────────────────
    /// @notice How long a workout may stay open before anyone can force the residual
    ///         debt to be recognised as a loss.
    /// @dev DexFi's manual redemption is quoted at "48h+" and is an off-chain process
    ///      with no on-chain enforcement, so the honest bound is generous. It exists
    ///      because the alternative is bad debt sitting on the books indefinitely at
    ///      governance's discretion - loss recognition lagging the auction window is a
    ///      known hazard, and an unbounded workout is the worst version of it.
    uint256 internal constant WORKOUT_MAX_DURATION = 14 days;

    // ── Yield split (PRD §4.4) — must sum to BPS, enforced in tests ─────────
    uint256 internal constant SPLIT_BORROWER_BPS = 5_500;
    uint256 internal constant SPLIT_LENDER_BPS = 2_500;
    uint256 internal constant SPLIT_INSURANCE_BPS = 1_000;
    uint256 internal constant SPLIT_PROTOCOL_BPS = 1_000;

    // ── Epoch harvesting (PRD §4.4) ──────────────────────────────────────────
    uint256 internal constant MIN_EPOCH_GAP = 5 days;

    /// @notice Smallest borrower share that counts as a real epoch, USDC 6dp.
    /// @dev `EpochHarvester.harvest` sizes an epoch from its own USDC balance with no
    ///      sender attribution, so without a floor anyone can advance an epoch by
    ///      donating a couple of units - and advancing an epoch resets the window the
    ///      yield stream's anti-just-in-time defence is derived from. $1 is far below
    ///      any real epoch (the fund pays hundreds of USDC a week at current scale) and
    ///      far above what is worth donating repeatedly.
    uint256 internal constant MIN_EPOCH_YIELD = 1e6;

    /// @notice How long a harvested epoch's borrower share is streamed into the
    ///         yield accumulator rather than applied as a lump.
    /// @dev Equal to MIN_EPOCH_GAP so consecutive epochs tile end to end: the stream
    ///      from epoch N runs out exactly when epoch N+1 becomes harvestable, so
    ///      yield accrues continuously with no dead gap and no overlap.
    ///
    ///      Streaming is what makes just-in-time capture pointless. A lump credited
    ///      to whoever holds bonds at that instant can be taken by depositing a large
    ///      position in the same block as the harvest and withdrawing immediately
    ///      after; spread over the epoch, one block of holding earns one block of
    ///      yield. Same mechanism as Synthetix StakingRewards.
    uint256 internal constant YIELD_STREAM_DURATION = MIN_EPOCH_GAP;

    // ── NAV oracle guards (PRD §4.6) ─────────────────────────────────────────
    uint256 internal constant NAV_MAX_DEVIATION_BPS = 1_000;
    uint256 internal constant NAV_PENDING_DELAY = 12 hours; // large moves wait for 2nd key
    /// @dev A pending NAV is void this long after it becomes confirmable. Without an
    ///      expiry, a price posted during a crash could be confirmed days later and
    ///      would reset `lastUpdated`, making a stale feed read as fresh at a price
    ///      that no longer holds.
    uint256 internal constant NAV_PENDING_EXPIRY = 24 hours;

    /// @notice How far a repost may move the pending NAV before the confirmer's review
    ///         window restarts.
    /// @dev Exists because the review clock cannot key off the exact value. A live feed
    ///      posts a different 8-decimal price every time, so restarting on any
    ///      difference let a keeper slide the window indefinitely and no large move
    ///      could ever be ratified - a unilateral veto over the second key, with an
    ///      honest keeper. Jitter inside this band keeps the clock running; a move
    ///      beyond it is a different number and earns a fresh review.
    uint256 internal constant NAV_PENDING_REPRICE_TOLERANCE_BPS = 100; // 1%
    /// @dev The budget window for NAV movement. Allowed deviation from the last
    ///      accepted price is prorated by elapsed time over this window, so posting
    ///      more often buys no extra room and a compromised keeper cannot walk the
    ///      price by repeating small steps (the per-post-only check cannot stop that).
    uint256 internal constant NAV_DEVIATION_WINDOW = 24 hours;
    /// @dev Cap on the prorated allowance, so a long keeper outage inside the 8-day
    ///      staleness budget does not accrue an unbounded move for a single post.
    ///
    ///      **Must never exceed NAV_DEVIATION_WINDOW.** `AUCTION_FLOOR_BPS` below is
    ///      derived from NAV_MAX_DEVIATION_BPS as the worst single *unconfirmed* NAV
    ///      drop. Setting this to 3 days silently made that real bound 30% rather than
    ///      10%, which left a floor-price liquidation ~19% of NAV short of covering
    ///      debt plus penalty - with the guard test still passing, because it was
    ///      pinned to the constant rather than to the oracle's actual behaviour.
    ///      A larger move is still reachable; it just needs the second key.
    ///      The relation is asserted in Config.t.sol.
    uint256 internal constant NAV_DEVIATION_MAX_ELAPSED = NAV_DEVIATION_WINDOW;
    uint256 internal constant NAV_STALENESS = 8 days; // older ⇒ borrow paused
    uint8 internal constant NAV_DECIMALS = 8; // navPerBond posted in USD, 8 decimals
    uint256 internal constant USDC_TO_NAV_SCALE = 1e2; // 10^(NAV_DECIMALS − USDC's 6 dp)

    /// @dev Fixed-point scale for healthFactor. 1e18 == exactly at the liquidation
    ///      threshold; below it the position is liquidatable.
    uint256 internal constant HEALTH_FACTOR_SCALE = 1e18;

    // ── Governance (PRD §9) ──────────────────────────────────────────────────
    /// @dev Not read by any contract, by design. Ownership is a plain `address`, so
    ///      the owner can be an EOA while building and a TimelockController at
    ///      go-live with no contract change. This is the delay that timelock is
    ///      constructed with; `test/Governance.t.sol` deploys one at exactly this
    ///      value and proves the handover works. Do not delete as unused.
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    // Operator addresses (owner, treasury, keeper, protocol fee wallet) deliberately
    // do NOT live here. The no-magic-numbers rule covers protocol parameters and
    // verified external addresses, not per-deployment operator identities: those are
    // rotatable, differ per environment, and would be published in this repo's git
    // history before the contracts are even deployed. They are environment
    // parameters to the deploy script (see script/.env.example). Please do not
    // "fix" this by moving them in.

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
    /// @dev Chainlink ETH/USD reference feed, Base mainnet, 8 decimals. Informational:
    ///      consumed off-chain by the keeper and the webapp, deliberately not read by
    ///      any contract. Collateral is priced from the NAV oracle, not from ETH.
    address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    /// @dev The bond token id — the bond is a fungible ERC-1155 balance, not
    ///      distinct NFTs. "Bond count" everywhere means balanceOf(id 0).
    uint256 internal constant DEXFI_BOND_TOKEN_ID = 0;
}
