// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Config} from "../src/Config.sol";

/// @notice Guards the internal consistency of Config - these relations are load-bearing
///         assumptions elsewhere in the protocol (PRD §5, §4.4, §4.5).
contract ConfigTest is Test {
    function test_yieldSplitSumsToBps() public pure {
        assertEq(
            Config.SPLIT_BORROWER_BPS + Config.SPLIT_LENDER_BPS + Config.SPLIT_INSURANCE_BPS
                + Config.SPLIT_PROTOCOL_BPS,
            Config.BPS,
            "YieldSplit must sum to 10000 bps"
        );
    }

    function test_ltvOrdering() public pure {
        // Borrow ceiling sits well below the liquidation trigger…
        assertLt(Config.MAX_LTV_BPS, Config.LIQUIDATION_THRESHOLD_BPS);
        // …and the liquidation trigger below the auction floor recovery, so a
        // floor-price fill still covers debt at the threshold.
        assertLt(Config.LIQUIDATION_THRESHOLD_BPS, Config.AUCTION_FLOOR_BPS);
    }

    /// @notice A floor-price fill must cover debt + liquidation penalty even at the
    ///         worst LTV that can first trigger a liquidation. That worst case is one
    ///         immediate NAV_MAX_DEVIATION_BPS drop applied to a position sitting at
    ///         the threshold, i.e. LTV = THRESHOLD / (1 - maxDev). (Was 6500 vs a
    ///         6767 requirement - a lender shortfall; see the private security notes.)
    function test_auctionFloorCoversDebtAndPenaltyAtWorstTrigger() public pure {
        // Derive the worst drop from what NAVOracle actually accepts without a second
        // key, not from NAV_MAX_DEVIATION_BPS directly. Those were the same number
        // until NAV_DEVIATION_MAX_ELAPSED was introduced, at which point the real
        // bound tripled and this test kept passing because it was pinned to the
        // assumption rather than to the behaviour.
        uint256 maxDropBps = (Config.NAV_MAX_DEVIATION_BPS * Config.NAV_DEVIATION_MAX_ELAPSED)
            / Config.NAV_DEVIATION_WINDOW;
        uint256 worstTriggerLtv =
            (Config.LIQUIDATION_THRESHOLD_BPS * Config.BPS) / (Config.BPS - maxDropBps);
        uint256 requiredFloor =
            (worstTriggerLtv * (Config.BPS + Config.LIQUIDATION_PENALTY_BPS)) / Config.BPS;
        assertGe(
            Config.AUCTION_FLOOR_BPS,
            requiredFloor,
            "auction floor must cover debt + penalty at the first-triggerable LTV"
        );
    }

    function test_auctionDecaysDownward() public pure {
        assertGt(Config.AUCTION_START_PREMIUM_BPS, Config.AUCTION_FLOOR_BPS);
    }

    function test_capsOrdering() public pure {
        assertLe(Config.PER_ACCOUNT_BORROW_CAP, Config.GLOBAL_BORROW_CAP);
    }

    /// @dev The penalty split must be exhaustive and the caller must never be able to
    ///      take all of it: the insurance fund's share is what makes liquidating a
    ///      position net-positive for the protocol rather than merely for the keeper.
    function test_penaltySplitLeavesTheInsuranceFundAShare() public pure {
        assertLt(Config.LIQUIDATION_CALLER_SHARE_BPS, Config.BPS);
        assertGt(Config.LIQUIDATION_CALLER_SHARE_BPS, 0);
    }

    /// @dev **Derived, not asserted**, in the style of the referral outflow test below. The
    ///      prepaid bounty exists precisely because the penalty-funded reward pays zero when
    ///      an auction fills short of the debt. If it were worth less than the best case the
    ///      penalty route could ever pay, the fix would be smaller than the hole it was
    ///      written for - and nothing else in the tree ties the two together, so retuning
    ///      `LIQUIDATION_PENALTY_BPS` could make that true silently.
    function test_liquidationBountyIsPayableAndAffordable() public pure {
        assertGt(Config.LIQUIDATION_CALL_BOUNTY, 0);

        // A bounty larger than the position it is charged on cannot come out of the
        // disbursement. This relation is what makes `borrow`'s subtraction safe rather
        // than merely untested.
        assertLt(Config.LIQUIDATION_CALL_BOUNTY, Config.MIN_BOUNTIED_DEBT);

        // A threshold above the per-account cap would make the mechanism unreachable: no
        // position could ever be bountied, every consumer would ship untested, and the
        // suite would report green over a quantity that is always zero.
        assertLe(Config.MIN_BOUNTIED_DEBT, Config.PER_ACCOUNT_BORROW_CAP);

        uint256 bestCasePenaltyReward = (
            ((Config.MIN_BOUNTIED_DEBT * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS)
                * Config.LIQUIDATION_CALLER_SHARE_BPS
        ) / Config.BPS;
        assertGe(
            Config.LIQUIDATION_CALL_BOUNTY,
            bestCasePenaltyReward,
            "the prepaid bounty must beat the penalty route it exists to backstop"
        );
    }

    /// @dev A workout must be allowed to run longer than DexFi's own quoted redemption
    ///      turnaround, or the force-close would recognise a loss on debt that was
    ///      about to be paid. `AUCTION_DURATION` bounds it from the other side: the
    ///      workout only starts once the auction has run its course.
    function test_workoutOutlastsTheAuctionAndTheRedemptionQuote() public pure {
        assertGt(Config.WORKOUT_MAX_DURATION, Config.AUCTION_DURATION);
        // DexFi quote their manual redemption at "48h+"; the bound has to clear it
        // with room, because there is nothing on-chain that enforces their timeline.
        assertGt(Config.WORKOUT_MAX_DURATION, 48 hours * 3);
    }

    function test_externalAddressesResolved() public pure {
        // Resolved 2026-07-24 from on-chain archaeology against the verified source.
        assertTrue(Config.USDC_BASE != address(0));
        assertTrue(Config.DEXFI_TREASURY_EOA != address(0));
        assertTrue(Config.DEXFI_BOND_NFT != address(0));
        assertTrue(Config.DEXFI_FARM != address(0));
        assertTrue(Config.CHAINLINK_ETH_USD != address(0));
        // The bond contract is its own mint entrypoint (signature-gated payable mint).
        assertEq(Config.DEXFI_MINT_ENTRYPOINT, Config.DEXFI_BOND_NFT);
    }

    /// @dev The NAV guards only make sense in this order: a large move must be
    ///      confirmable well inside the window it is measured against, and both must
    ///      sit comfortably inside the staleness budget. Getting this wrong is silent -
    ///      the feed keeps working and just stops protecting anything.
    function test_navGuardRelations() public pure {
        assertLt(Config.NAV_PENDING_DELAY, Config.NAV_DEVIATION_WINDOW);
        assertLt(Config.NAV_DEVIATION_WINDOW, Config.NAV_STALENESS);
        assertLt(Config.NAV_MAX_DEVIATION_BPS, Config.BPS);
        // The one that bit: a clamp wider than the window raises the largest
        // single-key NAV move above NAV_MAX_DEVIATION_BPS, which is the figure the
        // auction floor is sized against.
        assertLe(
            Config.NAV_DEVIATION_MAX_ELAPSED,
            Config.NAV_DEVIATION_WINDOW,
            "a wider clamp silently breaks the auction floor's coverage guarantee"
        );
    }

    /// @dev Nothing reads these yet - the reserve ratio and insurance fund target land
    ///      with the LenderPool queue and the harvester. Asserting them here is what
    ///      stops them being deleted as dead constants before their phase arrives.
    function test_unusedParametersStaySane() public pure {
        assertGt(Config.RESERVE_RATIO_BPS, 0);
        assertLt(Config.RESERVE_RATIO_BPS, Config.BPS);
        assertGt(Config.INSURANCE_FUND_TARGET_BPS, 0);
        assertLt(Config.INSURANCE_FUND_TARGET_BPS, Config.BPS);
        assertEq(Config.HEALTH_FACTOR_SCALE, 1e18);

        // The referral constants are consumed off-chain (the accrual calculator) and by the
        // Phase 4 distributor. Same reason as above: assert them so they survive to their phase.
        assertGt(Config.REFERRAL_MIN_QUALIFYING_DEBT, 0);
        assertGt(Config.REFERRAL_MIN_CLAIM, 0);
        assertLt(
            Config.REFERRAL_MIN_CLAIM,
            Config.REFERRAL_MIN_QUALIFYING_DEBT,
            "a claim floor above the debt floor would make qualifying positions unpayable"
        );
    }

    /// @dev **Derived, not asserted.** The previous referral design claimed a 30% cap while
    ///      specifying legs that summed to 45% of the protocol fee, and nothing caught it because
    ///      no test computed the sum. This is the same failure as audit-2 finding #2: a constant
    ///      sized against a bound that nothing enforced. Compute the outflow from the legs and
    ///      compare it to the declared cap, so the two cannot diverge again silently.
    function test_referralOutflowFitsTheDeclaredCap() public pure {
        uint256 outflow = Config.REFERRAL_REFERRER_SHARE_BPS + Config.REFERRAL_REFEREE_SHARE_BPS;
        assertLe(
            outflow,
            Config.REFERRAL_MAX_OUTFLOW_BPS,
            "referral legs exceed the cap the approved design promises"
        );
    }

    /// @dev The protocol fee is itself split with DexFi, so it must be exhaustive and must leave
    ///      Recoup a majority - the referral programme, the borrower rebate and every running cost
    ///      are funded from Recoup's leg alone.
    function test_protocolFeeSplitSumsToBps() public pure {
        assertEq(
            Config.PROTOCOL_FEE_RECOUP_BPS + Config.PROTOCOL_FEE_DEXFI_BPS,
            Config.BPS,
            "protocol fee split must sum to 10000 bps"
        );
        assertGt(
            Config.PROTOCOL_FEE_RECOUP_BPS,
            Config.PROTOCOL_FEE_DEXFI_BPS,
            "Recoup must retain the majority of its own fee"
        );
    }

    /// @dev Both legs are shares of *Recoup's share* of the protocol fee, so neither may exceed it,
    ///      and the two together cannot take all of it. If either ever did, the referral programme
    ///      would be paying out of the 55/25/10 promised to borrowers, lenders and insurance, or out
    ///      of DexFi's 20%, rather than out of Recoup's own slice - which is the promise the design
    ///      rests on and the one DexFi restated on 2026-08-07.
    function test_referralIsFundedEntirelyFromRecoupsShareOfTheFee() public pure {
        uint256 outflow = Config.REFERRAL_REFERRER_SHARE_BPS + Config.REFERRAL_REFEREE_SHARE_BPS;
        assertLe(outflow, Config.BPS, "referral cannot take more than the whole of Recoup's share");

        // What the programme costs at full tilt, as a share of gross yield: the protocol fee, times
        // Recoup's share of it, times the outflow. Derived through both hops rather than assumed,
        // because the base moved once already and the published copy moved with it.
        uint256 recoupBps = (Config.SPLIT_PROTOCOL_BPS * Config.PROTOCOL_FEE_RECOUP_BPS) / Config.BPS;
        uint256 grossBps = (recoupBps * outflow) / Config.BPS;
        assertLt(
            grossBps,
            recoupBps,
            "Recoup must retain some of its own share while a referral is live"
        );
        assertLt(
            grossBps,
            Config.SPLIT_PROTOCOL_BPS,
            "referral outflow must stay inside the protocol fee"
        );
    }

    /// @dev The referee's rebate is a launch sweetener and the referrer's share is the standing
    ///      income stream; the sweetener outlasting the income stream would invert the programme.
    function test_referralDurationsOrdering() public pure {
        assertLt(
            Config.REFERRAL_REFEREE_DURATION,
            Config.REFERRAL_REFERRER_DURATION,
            "the referee boost must expire before the referrer's share"
        );
        assertGt(
            Config.REFERRAL_REFEREE_DURATION,
            Config.MIN_EPOCH_GAP,
            "a reward window shorter than an epoch gap could pay nothing at all"
        );
    }

    /// @dev The minimum being non-zero is **load-bearing for correctness**, not just for namespace
    ///      economics. `ReferralRegistry.referrerFor` reads `referrerOf[boundCode[x]]`, and an
    ///      unbound account reads `referrerOf[bytes32(0)]`. That resolves to nobody only because
    ///      the zero code fails `isCanonical` on length. At a minimum of zero, one `register` would
    ///      make the caller the recorded referrer of every unbound account in existence.
    function test_referralCodeLengthBoundsAreSane() public pure {
        assertGt(Config.REFERRAL_CODE_MIN_LENGTH, 0, "zero-length codes would break the unbound sentinel");
        assertGt(Config.REFERRAL_CODE_MIN_LENGTH, 2, "a 2-character namespace is pure landgrab");
        assertLt(Config.REFERRAL_CODE_MIN_LENGTH, Config.REFERRAL_CODE_MAX_LENGTH);
        // Strictly under 32, not `<= 32`. `isCanonical` states "a code filling all 32 bytes is over
        // the maximum anyway" as settled fact, and a `<= 32` bound admitted the one value that
        // falsifies it. Client-side encoders are the other reason: ethers' `encodeBytes32String`
        // caps at 31 bytes, so a 32-character code would be un-enterable from a standard client.
        assertLt(Config.REFERRAL_CODE_MAX_LENGTH, 32, "a code must fit in one bytes32 with a terminator");
    }
}
