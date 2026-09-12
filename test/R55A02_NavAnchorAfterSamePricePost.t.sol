// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {NAVOracle} from "../src/NAVOracle.sol";
import {Config} from "../src/Config.sol";

/// @title R55A02 - a same-price post resets the budget clock but not the freshness clock
/// @notice Round-55 item 246(e). `_accept` writes `anchorAt = block.timestamp` on EVERY accepted
///         post and `lastUpdated` only when `nav != navPerBond`. The keeper's min-age gate keys on
///         `lastUpdated`, so after a same-price post the keeper is still "due" on the next fire,
///         posts the same price again, and every such post re-anchors the deviation budget at zero.
///         The next REAL move is then measured over one cron interval rather than over the time
///         since the price last changed: with a four-hourly cron that is 166 bps, and four of the
///         seven accepted posts on Base Sepolia so far were larger than that.
///
/// @dev The fix moves `anchorAt` inside the same `nav != navPerBond` branch as `lastUpdated`, so a
///      zero-delta accept is indistinguishable from silence for the budget - which is the bound the
///      docstring already states, because the budget is capped at `NAV_DEVIATION_MAX_ELAPSED` and a
///      keeper that stays silent for a day gets exactly the same 1,000 bps. `fix_` cases are RED at
///      9a01996 and green under the fix; `control_` and `measure_` cases are green on both trees.
contract R55A02_NavAnchorAfterSamePricePost is Test {
    NAVOracle internal oracle;
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");

    uint256 internal constant FIRST = 2905932669; // the 2026-09-05 accepted post
    uint256 internal constant CRON = 4 hours;
    uint256 internal constant MIN_AGE = 20 hours; // RECOUP_NAV_MIN_AGE_HOURS default

    function setUp() public {
        vm.warp(1_788_500_000);
        oracle = new NAVOracle(owner);
        vm.startPrank(owner);
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(2_800_000_000);
        vm.stopPrank();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        oracle.postNav(FIRST);
        assertEq(oracle.navPerBond(), FIRST);
        assertEq(oracle.pendingNav(), 0);
    }

    function _post(uint256 nav) internal {
        vm.prank(keeper);
        oracle.postNav(nav);
    }

    function _bps(uint256 bps) internal pure returns (uint256) {
        return FIRST + (FIRST * bps) / Config.BPS;
    }

    /// @notice MEASURED on both trees: the budget in bps at +1 s, +60 s and +1 h after a same-price
    ///         repost, and the largest move the cross-multiplied test still accepts at +1 s.
    function test_R55A02_246e_measure_theBudgetAfterASamePriceRepost() public {
        vm.warp(block.timestamp + 24 hours);
        uint256 updatedBefore = oracle.lastUpdated();
        _post(FIRST);
        assertEq(oracle.lastUpdated(), updatedBefore, "zero-delta accept: lastUpdated unmoved");
        emit log_named_uint("anchorAt after the same-price repost (block.timestamp)", oracle.anchorAt());
        emit log_named_uint("block.timestamp", block.timestamp);
        emit log_named_uint("lastUpdated", oracle.lastUpdated());

        vm.warp(block.timestamp + 1);
        emit log_named_uint("allowedDeviationBps at +1s", oracle.allowedDeviationBps());
        // The largest accepted move at +1 s under a fresh anchor, cross-multiplied and not floored:
        // delta <= anchor * 1000 * 1 / (10_000 * 86_400) = anchor / 864_000.
        emit log_named_uint("largest accepted delta at +1s under a fresh anchor (8dp)", FIRST / 864_000);
        vm.warp(block.timestamp + 59);
        emit log_named_uint("allowedDeviationBps at +60s", oracle.allowedDeviationBps());
        vm.warp(block.timestamp + 3540);
        emit log_named_uint("allowedDeviationBps at +1h", oracle.allowedDeviationBps());
    }

    /// @notice The keeper-side stall shape, modelled on the live cron: `lastUpdated` never moves on
    ///         a same-price post, so the keeper's 20 h gate stays open and every delivered four-hourly
    ///         fire from 20 h on reposts the unchanged price. At 48 h DexFi's price moves +300 bps.
    ///         At 9a01996 that move is measured against the 44 h repost, gets 166 bps, and PARKS for
    ///         the second key; under the fix it is measured against the last CHANGE and lands.
    function test_R55A02_246e_fix_samePriceRepostsDoNotShrinkTheNextRealMovesBudget() public {
        uint256 accepted = block.timestamp;
        uint256 fires = 0;
        for (uint256 t = MIN_AGE; t <= 44 hours; t += CRON) {
            vm.warp(accepted + t);
            // The keeper's gate: age of `lastUpdated`, which a same-price post never advances.
            assertGe(block.timestamp - oracle.lastUpdated(), MIN_AGE, "premise: the keeper is due on every fire");
            _post(FIRST);
            fires++;
        }
        assertEq(fires, 7, "premise: seven same-price posts, 20h to 44h");
        assertEq(oracle.lastUpdated(), accepted, "premise: freshness never moved");

        vm.warp(accepted + 48 hours);
        emit log_named_uint("allowedDeviationBps at 48h after seven same-price reposts", oracle.allowedDeviationBps());
        assertEq(oracle.allowedDeviationBps(), Config.NAV_MAX_DEVIATION_BPS, "a day of same-price posts must not spend the budget");

        uint256 moved = _bps(300);
        _post(moved);
        assertEq(oracle.navPerBond(), moved, "the +300 bps move must land, as it would after a silent day");
        assertEq(oracle.pendingNav(), 0, "and not park");
        assertEq(oracle.lastUpdated(), accepted + 48 hours, "a real move advances freshness");
        assertEq(oracle.anchorAt(), accepted + 48 hours, "and re-anchors the budget");
    }

    /// @notice The bound a compromised keeper faces is unchanged by the fix: a real move re-anchors,
    ///         so an immediate second move of the same size still parks.
    function test_R55A02_246e_control_aRealMoveStillResetsTheAnchor() public {
        vm.warp(block.timestamp + 24 hours);
        _post(_bps(500));
        uint256 base = oracle.navPerBond();
        vm.warp(block.timestamp + 1);
        uint256 again = base + (base * 500) / Config.BPS;
        _post(again);
        assertEq(oracle.navPerBond(), base, "the second +500 bps one second later parks");
        assertEq(oracle.pendingNav(), again);
    }

    /// @notice A silent keeper and a reposting keeper get the SAME budget under the fix, and the
    ///         reposting one gets strictly less at 9a01996.
    function test_R55A02_246e_fix_silenceAndRepostingAreTheSameBudget() public {
        uint256 accepted = block.timestamp;
        uint256 snap = vm.snapshotState();

        vm.warp(accepted + 24 hours);
        uint256 silent = oracle.allowedDeviationBps();

        vm.revertToState(snap);
        vm.warp(accepted + 20 hours);
        _post(FIRST);
        vm.warp(accepted + 24 hours);
        uint256 reposting = oracle.allowedDeviationBps();

        emit log_named_uint("budget at 24h, silent keeper", silent);
        emit log_named_uint("budget at 24h, one same-price repost at 20h", reposting);
        assertEq(reposting, silent, "a same-price post must be indistinguishable from silence for the budget");
    }
}
