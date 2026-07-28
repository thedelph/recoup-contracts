// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Config} from "../src/Config.sol";

/// @notice Guards the internal consistency of Config — these relations are load-bearing
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
    ///         6767 requirement - a lender shortfall, raised to 6800 after review.)
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
        // Resolved 2026-07-24 from on-chain archaeology (verified source review).
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
    }
}
