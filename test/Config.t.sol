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

    function test_auctionDecaysDownward() public pure {
        assertGt(Config.AUCTION_START_PREMIUM_BPS, Config.AUCTION_FLOOR_BPS);
    }

    function test_capsOrdering() public pure {
        assertLe(Config.PER_ACCOUNT_BORROW_CAP, Config.GLOBAL_BORROW_CAP);
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
}
