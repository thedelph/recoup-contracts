// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title Config
/// @notice Single source of truth for every protocol parameter and external address.
///         PRD rule: no magic numbers anywhere else - all bps values use the 10_000
///         denominator (`BPS`). Values from PRD §5 (risk) and §4.4 (yield split).
/// @dev    Every member here is an `internal constant`, inlined into each consumer at
///         compile time. Changing one means redeploying the contracts that read it.
///
///         **The exception, and it is the important one: the four negotiated risk
///         parameters are no longer read by any contract at runtime.** They live in
///         `RiskParams` as bounded storage behind the owner, per PRD §4 and §9, and
///         what remains here are the `DEFAULT_*` values the deploy script seeds that
///         contract with. Changing one below changes what a *fresh deployment* starts
///         at; it does nothing to a chain that is already live, where the live values
///         are whatever `RiskParams.params()` returns.
///
///         They are still declared here, under names that say what they are, for a
///         reason that is not inertia: the webapp mirrors this file, and the check that
///         holds the mirror to it parses these declarations. What that check guarantees
///         has narrowed - from "the UI matches the protocol" to "the UI matches the
///         launch defaults" - and that narrowing is a known gap, tracked with the
///         webapp's chain-read work, rather than a passing check that has quietly
///         stopped meaning anything.
///
///         The relations between those four are enforced in `RiskParams.checkRiskParams`
///         and no longer only in `test/Config.t.sol`. The one worth knowing about here:
///         the auction floor has to keep covering debt plus the liquidation penalty
///         after a worst-case NAV move, which ties the liquidation threshold to
///         `AUCTION_FLOOR_BPS` below.
library Config {
    uint256 internal constant BPS = 10_000;

    // ── Risk parameters (PRD §5) ─────────────────────────────────────────────
    /// The four values below are the capped-beta settings agreed with DexFi on
    /// 2026-08-07, not the PRD's original launch figures (3500 / 5800 / 250k / 25k).
    /// They are deliberately tighter than the protocol requires: at a 25% ceiling and
    /// a 50% threshold a bond has to lose half its value before a position is even
    /// liquidatable, and the caps bound the whole book to a size where a total loss is
    /// survivable. The expansion back towards the PRD figures is scheduled against
    /// observable data rather than renegotiated - four clean epochs with the insurance
    /// fund at INSURANCE_FUND_TARGET_BPS of debt raises the global cap, four more
    /// raises the borrow ceiling.
    ///
    /// **These are seeds, not the live values.** They are what `DeployBase` constructs
    /// `RiskParams` with, and nothing else reads them. `RiskParams` re-checks them
    /// through the same function every later write goes through, so a set that its own
    /// setter would refuse cannot be deployed. The `DEFAULT_` prefix is the point of the
    /// name: reading one of these and believing it describes a live chain is the mistake
    /// the prefix exists to prevent.
    uint256 internal constant DEFAULT_MAX_LTV_BPS = 2_500;
    uint256 internal constant DEFAULT_LIQUIDATION_THRESHOLD_BPS = 5_000;
    uint256 internal constant DEFAULT_GLOBAL_BORROW_CAP = 25_000e6; // USDC, 6 decimals
    uint256 internal constant DEFAULT_PER_ACCOUNT_BORROW_CAP = 5_000e6;
    uint256 internal constant RESERVE_RATIO_BPS = 1_500; // LenderPool hot float target

    /// @notice Seed for the ceiling on total deposits into the LenderPool.
    /// @dev A yield figure rather than a risk one. A lender's return is 25% of the yield on
    ///      collateral worth four times the debt, so at the LTV ceiling a fully deployed pool
    ///      earns the bond fund's own yield rate. Idle USDC earns nothing and dilutes that rate
    ///      for everyone in the pool, so a pool materially larger than the debt it can fund pays
    ///      everyone less for no extra safety.
    ///
    ///      **It used to be `= GLOBAL_BORROW_CAP`, and that alias had to go.** A Solidity constant
    ///      cannot be defined in terms of storage, so the moment the global cap became settable
    ///      this would have silently frozen at 25k through every ratchet step - in an ERC-4626
    ///      `maxDeposit` override, which the standard forbids from reverting, on a contract with
    ///      no sweep and no owner rescue. It was also an alias tying a lender-return decision to a
    ///      credit-risk decision by `=`, with nothing in the tree saying so. The pool now owns this
    ///      as its own settable `depositCap`. The ratchet still moves both together; it now does so
    ///      by naming both, which is one extra call in a proposal that already takes 48 hours.
    uint256 internal constant DEFAULT_LENDER_POOL_DEPOSIT_CAP = 25_000e6;

    /// @notice The absolute ceiling the settable global borrow cap may never exceed.
    /// @dev Lives here rather than only in `RiskParams` because three contracts need it as a
    ///      compile-time constant. `RiskParams` enforces it as a bound; `LenderPool.impair` and
    ///      `LiquidationAuction._bid` use it as an overflow clamp on a measured balance delta.
    ///
    ///      Both of those clamps *must* stay constant rather than reading the live cap. Neither
    ///      function may revert - `impair` is reached by the auction's exits of last resort, and
    ///      an exit that can fail while holding somebody else's collateral is not an exit - so
    ///      neither can afford an external call. It is a guard against arithmetic that should be
    ///      impossible, not a policy limit.
    ///
    ///      **The two clamps clamp two different kinds of quantity, and only one of them is a
    ///      debt.** Round 20 found both sites carrying the same justification - "no borrower can
    ///      owe more than the live cap, the live cap can never exceed this, so the clamp cannot
    ///      bite" - and it does not cover both:
    ///
    ///      - `LenderPool.impair` clamps a *mark*: an expected shortfall on one borrower, which
    ///        `CreditManager._impairmentFor` computes as `debt - recovered`. A shortfall cannot
    ///        exceed the debt it is a shortfall of, so the debt argument covers this one exactly
    ///        and the clamp is genuinely unreachable.
    ///      - `LiquidationAuction._bid` clamps `credited`: the USDC actually received for a
    ///        winning bid. **That is a price, not a debt.** Nothing bounds what a bidder pays by
    ///        what the borrower owes - a fill above the debt is the ordinary outcome, which is why
    ///        there is a surplus path at all. The first strike does bound it, at one remove: a
    ///        liquidation requires the position to be at or past the threshold, and the lot opens
    ///        at `AUCTION_START_PREMIUM_BPS` of NAV and only decays, so the price is at most the
    ///        collateral value at strike, at most `BPS / threshold` times the debt, at most twice
    ///        it. A *re-strike* does not: it re-reads the lot and the NAV without re-checking that
    ///        the position is still liquidatable, so a borrower who has deposited collateral or
    ///        whose NAV has recovered can be re-struck at a price bounded by neither.
    ///
    ///      So the clamp at `_bid` can bite, and it is still correct - for a reason nothing in the
    ///      tree stated. `recognisedRecoveryOf` is only ever consumed as `debt > recovered ? debt
    ///      - recovered : 0`, and this ceiling is at least any debt the protocol can carry, so
    ///      every value at or above the debt produces the same answer: no mark. The clamp is
    ///      chosen so that biting is *harmless*, not so that biting is *impossible*, and those are
    ///      different guarantees with different failure modes if the consumer ever changes.
    ///      **A wrong reason licenses a wrong edit**, which is why this is written down rather
    ///      than left as a conclusion that happened to survive.
    ///
    ///      It is the PRD's original launch figure, which is also the far end of the ratchet
    ///      agreed with DexFi. Going beyond it is a redeploy, deliberately.
    uint256 internal constant GLOBAL_BORROW_CAP_MAX = 250_000e6;
    uint256 internal constant INSURANCE_FUND_TARGET_BPS = 500; // ≥5% of outstanding debt per cap raise
    uint256 internal constant UNDERWRITING_APR_BPS = 2_500; // UI/modelling only, never marketed

    // ── Liquidation auction (PRD §4.5) ───────────────────────────────────────
    uint256 internal constant AUCTION_START_PREMIUM_BPS = 10_000; // 100% of NAV
    // Floor must cover debt + liquidation penalty at the worst LTV that can first trigger a
    // liquidation - one immediate maximum *unconfirmed* NAV drop applied to a position sitting
    // exactly on the threshold. The requirement, never a literal:
    //
    //   maxDrop  = NAV_MAX_DEVIATION_BPS * NAV_DEVIATION_MAX_ELAPSED / NAV_DEVIATION_WINDOW
    //   required = THRESHOLD * (BPS + LIQUIDATION_PENALTY_BPS) / (BPS - maxDrop)
    //
    // Enforced at runtime by `RiskParams.checkRiskParams` relation (C), which evaluates it
    // cross-multiplied and division-free, and exposes it as `minimumAuctionFloorFor(threshold)`
    // so a floor change can be modelled before it is agreed. It binds in BOTH directions now the
    // threshold can move: a *reduction* here lowers the ceiling on how high the threshold may be
    // ratcheted.
    //
    // **Read the margin at the ratchet's terminus, not at today's threshold.** The threshold is
    // the one input designed to move - `RiskParams`' hard ceiling is 5800 and that endpoint is
    // the commitment made to DexFi - so `AUCTION_FLOOR_BPS - required(today)` is a fact with a
    // shelf life, and quoting it here is how one margin came to have three different values in
    // three files. Both ends are asserted in
    // `RiskParameters.t.sol:test_relationCsMarginIsPinnedAtBothEndsOfTheRatchet`, which is where
    // the numbers belong: a change to this constant, to the penalty or to any of the three NAV
    // deviation constants fails a test instead of staling a comment. At the terminus the room is
    // tens of basis points, not hundreds.
    //
    // **Commercially urgent, and the reason this paragraph is here rather than in a doc.**
    // This floor is under live negotiation with DexFi and has been offered to them as a *raise*
    // (80-85%), conditional on their liquidation backstop being pre-funded - a high floor with
    // nothing standing behind it pushes lots that cannot clear into the workout queue, which is
    // the one path that truly redeems bonds out of their fund. A raise is safe here; the danger
    // is the counter-offer. **A reduction of a few tens of basis points puts the agreed 5800
    // endpoint permanently out of reach through `checkRiskParams`**, and no ratchet step could
    // then reach it: this is a compile-time constant, so recovering the endpoint would mean
    // redeploying `RiskParams` and the three contracts that hold it `immutable`. Run
    // `minimumAuctionFloorFor(5800)` against any number they name before agreeing to it. Left at
    // 6800 until they name a level.
    uint256 internal constant AUCTION_FLOOR_BPS = 6_800; // 68% of NAV
    uint256 internal constant AUCTION_DURATION = 6 hours;

    /// @notice How long after a position's first liquidation a lapsed auction may still be re-struck
    ///         at a fresh price. After this, the only move left is the workout.
    /// @dev **Audit round 19, critical 2.** Re-striking a lapsed auction is necessary - a frozen
    ///      `startNav` left to block becomes a perpetual call option struck at an arbitrarily old
    ///      price - but the re-strike was free, permissionless and *unbounded*, and it re-opened the
    ///      auction's liveness register every time. `CreditManager._impairmentFor` keys the lender
    ///      pool's mark on that register, so an attacker holding no capital at all could keep a
    ///      position perpetually live and hold the whole withdrawal queue shut over idle cash.
    ///      Measured: 30 re-strikes over 7 days, 30 of 30 `serviceQueue` calls refused, 19,371 USDC
    ///      idle, the lender paid nothing, and `openWorkoutCount` never leaving zero - so the
    ///      forced close that bounds every *other* path was never armed at all.
    ///
    ///      This is the bound. Once it passes, `start` refuses to re-strike and the only legal move
    ///      on a lapsed auction is the permissionless `expireToWorkout`, which arms
    ///      `WORKOUT_MAX_DURATION` and its forced close. The mark can therefore stand for at most
    ///      this window plus that one, rather than for as long as somebody keeps paying gas.
    ///
    ///      **That sentence was false when it was written, and audit round 20 is what made it
    ///      true.** This window bounds the *re-strike*; the mark is keyed on
    ///      `auctionOf[borrower] != 0`, which a lapse does not clear. A position that HEALED under
    ///      a lapsed auction - by a permissionless `repayFor`, by the borrower depositing
    ///      collateral to save it, by the yield stream alone, or by a `liquidationThresholdBps`
    ///      raise - failed `expireToWorkout` on `reassign`'s liquidatable check, so the "only legal
    ///      move" was not legal and nothing here bounded anything. Measured at all four routes:
    ///      the mark unchanged at +365 days, `openWorkoutCount` 0, `refreshImpairments` reporting
    ///      0. `expireToWorkout` now dispatches that case into the `cancel` body, which releases
    ///      the mark on the spot - so the bound above holds on the still-forfeit branch and is
    ///      beaten on the healed one.
    ///
    ///      **48 hours is eight full auction cycles, and the derivation matters because the first
    ///      draft of this got it wrong in the expensive direction.** It was written as 14 days, to
    ///      match `WORKOUT_MAX_DURATION`, and the round-19 proof-of-concept - 30 re-strikes over 7.5
    ///      days - **still passed against it**. A bound longer than the attack is not a bound. The
    ///      two constants also answer different questions: this one asks how long we keep trying to
    ///      *sell*, and `WORKOUT_MAX_DURATION` asks how long an off-chain *redemption* may take. Only
    ///      the second is pinned to DexFi's quoted "48h+".
    ///
    ///      The trade-off, both directions stated because neither is free. Too short pushes a lot
    ///      that would have sold into a workout, which is a real redemption and removes a bond from
    ///      DexFi's fund - the outcome both sides least want - and gives the borrower a worse
    ///      recovery. Too long leaves the lender pool's withdrawal queue shut for that whole period
    ///      at the price of gas. Reaching the workout does **not** end the mark, so the worst case is
    ///      this window *plus* `WORKOUT_MAX_DURATION`; at 14 days that was 28, and the second half is
    ///      unavoidable while the first is not.
    ///
    ///      Eight cycles is generous against the thing re-striking exists for: each one restarts at
    ///      100% of *current* NAV and decays to `AUCTION_FLOOR_BPS`, so a lot that has failed to
    ///      clear eight successive floors at eight successive prices is not being mispriced, it is
    ///      unsaleable, and the workout is the correct answer rather than a failure.
    ///
    ///      **The value is a judgement, not a measurement**, the same admission
    ///      `LIQUIDATION_CALL_BOUNTY` makes: nobody has observed how many re-strikes a real falling
    ///      market needs. Must exceed `AUCTION_DURATION` or no re-strike is ever reachable;
    ///      asserted in `Config.t.sol`.
    uint256 internal constant AUCTION_RESET_WINDOW = 48 hours;

    uint256 internal constant LIQUIDATION_PENALTY_BPS = 500; // of debt; split 50/50 caller/insurance
    /// @notice The liquidation caller's share of the penalty; the remainder, including
    ///         any odd wei, goes to the insurance fund.
    /// @dev PRD §4.5 says "split 50/50 caller reward / insurance fund". Named rather
    ///      than written as `penalty / 2` at the call site, because a bare `/ 2` is a
    ///      magic number that cannot be found when the split is retuned.
    uint256 internal constant LIQUIDATION_CALLER_SHARE_BPS = 5_000;

    /// @notice Prepaid by the borrower and released to whoever opens their liquidation
    ///         auction. USDC, 6dp.
    /// @dev The penalty split above pays the caller out of `surplus`, and a fill short of
    ///      the debt leaves no surplus, so on exactly the liquidations that matter most the
    ///      caller earns nothing. Until somebody volunteers, the lender pool carries no
    ///      mark and every exit is priced before the loss. This constant is what pays the
    ///      volunteer.
    ///
    ///      Liquity's shape: charged at `borrow`, escrowed, refunded if the position never
    ///      goes bad. The payer is the party whose position caused the work, which keeps it
    ///      off the lenders and out of the insurance fund - drawing on insurance would raise
    ///      `exitReserve` through `insuranceCover` and lower every lender's exit price, so
    ///      that funding route is partly circular.
    ///
    ///      **The value is a judgement, not a measurement.** Nobody has measured what a
    ///      liquidation bot on Base actually needs to show up for a position of this size.
    ///      It is set large against gas (a `liquidate` costs cents) because what it buys is
    ///      attention and a contested ordering slot, not gas. 25 USDC is 5% of the smallest
    ///      bountied position; Liquity's 200 LUSD against a 2000 LUSD minimum is 10%.
    uint256 internal constant LIQUIDATION_CALL_BOUNTY = 25e6;

    /// @notice The smallest resulting debt that carries a bounty. USDC, 6dp.
    /// @dev Maker's dust guard: a position too small to be worth the payment does not get
    ///      one. Keyed on the debt a borrow *results in* rather than on the amount borrowed,
    ///      because keying on the amount makes the charge opt-out - twenty borrows of just
    ///      under the threshold reach the per-account cap having paid nothing, for a few
    ///      cents of gas on Base.
    ///
    ///      Deliberately low enough that most of the existing suite is charged. A threshold
    ///      set high enough to miss the tests would ship the whole mechanism dormant, with
    ///      every consumer untested and the suite reporting green over a quantity that is
    ///      always zero.
    uint256 internal constant MIN_BOUNTIED_DEBT = 500e6;

    // ── Workout queue (PRD §4.5, the expiry path) ────────────────────────────
    /// @notice How long a workout may stay open before anyone can force the residual
    ///         debt to be recognised as a loss.
    /// @dev DexFi's manual redemption is quoted at "48h+" and is an off-chain process
    ///      with no on-chain enforcement, so the honest bound is generous. It exists
    ///      because the alternative is bad debt sitting on the books indefinitely at
    ///      governance's discretion, which is the "loss recognition lags the auction
    ///      window" deferral, recorded open rather than closed.
    uint256 internal constant WORKOUT_MAX_DURATION = 14 days;

    // ── Yield split (PRD §4.4) - must sum to BPS, enforced in tests ─────────
    uint256 internal constant SPLIT_BORROWER_BPS = 5_500;
    uint256 internal constant SPLIT_LENDER_BPS = 2_500;
    uint256 internal constant SPLIT_INSURANCE_BPS = 1_000;
    uint256 internal constant SPLIT_PROTOCOL_BPS = 1_000;

    // ── Protocol fee split (agreed with DexFi 2026-08-06) - must sum to BPS ──
    //
    // Shares **of SPLIT_PROTOCOL_BPS**, not of gross yield. DexFi asked for a cut in return for
    // backing the integration; the total fee stays at 10% rather than rising to the 12% they
    // offered, because the four-way split above must sum to BPS, so those two points would have
    // come off the borrower's 55% write-down - the one number the product is judged on.
    //
    // Not read by any contract yet, and deliberately so: `EpochHarvester.flushProtocolFee` pays
    // the whole fee out with a plain `safeTransfer` to `protocolFeeWallet`, so the split is done
    // by an immutable splitter installed at that address rather than by changing the core. Both
    // destinations and both shares fixed at its construction, so neither party can redirect what
    // has arrived there. Blocked on DexFi naming their receiving address.
    //
    // **That guarantee used to be written one word wider - "neither party can redirect it" - and
    // audit rounds 13 and 21 both found the same gap under it.** The splitter is immutable; the
    // hop in front of it was not. The fee accrues in `EpochHarvester.pendingProtocolFee` until
    // somebody calls `flushProtocolFee`, and `setProtocolFeeWallet` used to repoint the
    // destination over that backlog with no checkpoint and no event: MEASURED at three
    // 1,000.000000 epochs, DexFi's 60.000000 became 0. Closed in round 21 by checkpointing the
    // backlog into `EpochHarvester.owedProtocolFee[outgoing]`, which anybody can then deliver.
    // The claim is true again, and it is true of two contracts rather than one.
    uint256 internal constant PROTOCOL_FEE_RECOUP_BPS = 8_000;
    uint256 internal constant PROTOCOL_FEE_DEXFI_BPS = 2_000;

    // ── Referral programme v1 (design approved 2026-07-30) ───────────────────
    //
    // NOT READ BY ANY CONTRACT, by design, and `ReferralRegistry` reads only the two code-length
    // bounds. Everything here is consumed by the off-chain accrual calculator and, at Phase 4, by
    // whatever computes the Merkle root. They live in Config anyway, per the no-magic-numbers rule
    // and because the calculator and the UI must not each carry their own copy. Same policy as
    // ADMIN_TIMELOCK below: do not delete as unused.
    //
    // All three share figures are percentages **of Recoup's own share of the protocol fee**
    // (SPLIT_PROTOCOL_BPS x PROTOCOL_FEE_RECOUP_BPS), not of gross yield and not of the whole fee.
    // On $100 of harvested yield the split stays 55/25/10/10; the $10 fee splits $8 Recoup / $2
    // DexFi; and it is Recoup's $8 that becomes $1.60 referrer + $0.80 referred borrower + $5.60
    // retained during the first 12 weeks, then $1.60 + $6.40 to week 52, then $8.
    //
    // The base moved from the whole fee to Recoup's share of it on 2026-08-07, when DexFi confirmed
    // "Recoup's referral rewards and borrower rebates come from Recoup's 80%". Rebasing rather than
    // widening the bps is deliberate: the alternative holds the referrer's absolute payout constant
    // by taking a larger slice of a smaller pot, which quietly makes the 30% cap a 37.5% one. The
    // published copy on /refer and /r/[code] moved in the same change, and the timing is the whole
    // point - payouts are Phase 4 and switched off, so nothing has accrued against the old wording.
    // Once an accrual exists this stops being an edit and becomes a promise broken after the fact.
    //
    // The programme is **borrower-only**. A lender leg was rejected because the borrower's referrer
    // and the lender's referrer would both be paid out of the protocol fee on the *same* harvest,
    // so two independently-applied 30% caps could spend 60% of one dollar.
    uint256 internal constant REFERRAL_REFERRER_SHARE_BPS = 2_000; // 20% of Recoup's share of the fee
    uint256 internal constant REFERRAL_REFEREE_SHARE_BPS = 1_000; // 10% of it, paid as a USDC rebate

    /// @dev The referee reward is a **rebate**, never an adjustment to the yield split. A per-user
    ///      split is not implementable: `EpochHarvester` applies SPLIT_BORROWER_BPS to the whole
    ///      claimed amount and `CreditManager` distributes through a single yield-per-bond
    ///      accumulator with no per-position differentiation - which is exactly what settles 200+
    ///      positions in one storage write (PRD §6.2). An earlier design specified "+2.5pp on the
    ///      borrower's split"; it was both unbuildable and 45% of the fee against a claimed 30% cap.
    uint256 internal constant REFERRAL_REFERRER_DURATION = 52 weeks;
    uint256 internal constant REFERRAL_REFEREE_DURATION = 12 weeks;

    /// @notice Hard ceiling on combined referral outflow, as a share of Recoup's share of the fee.
    /// @dev Asserted against the two legs in `Config.t.sol` rather than trusted. The previous
    ///      design claimed this cap while specifying figures that summed to 45%, which is the same
    ///      failure as audit-2 finding #2: a constant sized against a bound nothing enforced.
    uint256 internal constant REFERRAL_MAX_OUTFLOW_BPS = 3_000;

    /// @notice Floors that stop dust spam in the calculator and the distributor, USDC 6dp.
    /// @dev A position below the qualifying debt accrues nothing, and an accrual below the claim
    ///      floor is carried rather than published into a Merkle root, where its claim would cost
    ///      more gas than it pays. Both must be settled before the programme is activated.
    uint256 internal constant REFERRAL_MIN_QUALIFYING_DEBT = 100e6;
    uint256 internal constant REFERRAL_MIN_CLAIM = 10e6;

    /// @notice Bounds on a referral code, in bytes. The only constants `ReferralRegistry` reads.
    /// @dev A 1-character namespace is 38 entries and a 2-character one is 1,444; both are pure
    ///      landgrab on day one. Three is still short enough to say out loud. The maximum keeps a
    ///      code inside one `bytes32` with room to spare and keeps links readable.
    uint256 internal constant REFERRAL_CODE_MIN_LENGTH = 3;
    uint256 internal constant REFERRAL_CODE_MAX_LENGTH = 16;

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

    /// @notice Smallest amount of farm-attributed USDC that must have reached the protocol
    ///         since the last accepted epoch for `harvest` to treat this one as real, USDC 6dp.
    /// @dev **A different question from `MIN_EPOCH_YIELD`, asked of a different quantity, even
    ///      though the two happen to be the same number today.** `MIN_EPOCH_YIELD` asks "is this
    ///      epoch worth running": it is measured against the *borrower share* of `claimed`, and
    ///      `claimed` is a raw USDC balance with no sender attribution, so anyone can move it.
    ///      This one asks "did the farm actually fund it": it is measured against the increase in
    ///      `ICustodyAdapter.farmYieldDelivered`, a monotonic count of USDC the adapter measured
    ///      arriving *from the farm*, which a donation cannot move by a single unit.
    ///
    ///      Because the quantity is unforgeable, this is not a price an attacker pays - it is a
    ///      dust threshold on real yield. It exists because the DexFi farm is MasterChef-style, so
    ///      any bond movement settles the whole adapter position: without a floor, a one-unit
    ///      deposit made a block after the last epoch would deliver a few units of genuine yield
    ///      and with it a write to `CreditManager.lastDistributeAt`, which is the anti-just-in-time
    ///      window's only input. Audit round 11 measured what pinning that is worth: eleven pins
    ///      one `YIELD_STREAM_DURATION` apart turned a $495 just-in-time take into $5,940 out of a
    ///      $6,600 epoch, and left a holder staked for the whole sixty days with $671 of it.
    ///
    ///      $1 gross, for the same reason $1 net is right next door: the fund pays hundreds of
    ///      USDC a week at current scale, so a real epoch clears this by three orders of magnitude,
    ///      and no honest epoch is ever delayed by it. The two must not be aliased to each other,
    ///      though - retuning `SPLIT_BORROWER_BPS` moves what `MIN_EPOCH_YIELD` means in gross
    ///      terms and leaves this one exactly where it is.
    uint256 internal constant MIN_EPOCH_FARM_YIELD = 1e6;

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
    // Resolved 2026-07-24 on-chain, from a real mint transaction traced through
    // Blockscout and confirmed against each contract's verified source.
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant DEXFI_TREASURY_EOA = 0xd4ec4E5b7625Fed3c40Bfeec206E49396F02Dd54;

    /// @dev "NFTBondsMigration": ERC-1155, single TOKEN_ID = 0, verified, immutable
    ///      (no proxy). Wallet↔wallet transfers whitelist-gated; owner = treasury EOA.
    ///      This contract is ALSO the mint entrypoint (payable `mint` gated by an
    ///      EIP-712 signature from DexFi's keeper/owner - no on-chain referral param).
    address internal constant DEXFI_BOND_NFT = 0x969C6eCF97c256846029cBCBB865824E505E006f;
    address internal constant DEXFI_MINT_ENTRYPOINT = DEXFI_BOND_NFT;
    /// @dev "RewardPoolBondsMigration" behind an ERC1967/UUPS proxy (impl
    ///      0xdfb45A77…9A10, upgradeable by the treasury EOA). deposit/withdraw are
    ///      permissionless and NOT EOA-gated; withdraw(0) claims USDC rewards.
    address internal constant DEXFI_FARM = 0x0251cbB9a752331D29031eEc88c5a8BCbcDafFfa;
    /// @dev EIP-712 signer for bond mints (informational - mint flow needs DexFi's
    ///      backend to co-sign).
    address internal constant DEXFI_MINT_KEEPER = 0xBbBBBA31F7fD7E1ACAcAb33d905941f1F3A6ad91;
    /// @dev Chainlink ETH/USD reference feed, Base mainnet, 8 decimals. Informational:
    ///      consumed off-chain by the keeper and the webapp, deliberately not read by
    ///      any contract. Collateral is priced from the NAV oracle, not from ETH.
    address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    /// @dev The bond token id - the bond is a fungible ERC-1155 balance, not
    ///      distinct NFTs. "Bond count" everywhere means balanceOf(id 0).
    uint256 internal constant DEXFI_BOND_TOKEN_ID = 0;
}
