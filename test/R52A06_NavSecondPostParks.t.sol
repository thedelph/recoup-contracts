// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {NAVOracle} from "../src/NAVOracle.sol";
import {Config} from "../src/Config.sol";

/// Round-52 finding on the keeper NAV path, held as a MEASUREMENT rather than a fix: what `postNav`
/// does with a SECOND post seconds after the first, the shape two late GitHub fires delivered
/// minutes apart would produce if the `nav-keeper` concurrency group did not serialise them. It
/// does not revert and it does not land - it PARKS, and the parked value then holds the pending
/// slot for `NAV_PENDING_EXPIRY` while the feed carries on. The cost of the race is therefore one
/// red keeper run and a parked slot, never a second accepted price. Nothing in `src/` changes for
/// this; the suite exists so the behaviour the keeper's concurrency group is relied on to prevent
/// stays written down in an assertion. Self-contained: its own oracle, no repo fixture.
contract R52A06_NavSecondPostParks is Test {
    NAVOracle oracle;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address confirmer = makeAddr("confirmer");

    uint256 constant FIRST = 2905932669; // the 2026-09-05 accepted post

    function setUp() public {
        vm.warp(1_788_500_000);
        oracle = new NAVOracle(owner);
        vm.startPrank(owner);
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(2_800_000_000);
        vm.stopPrank();
        // A day later the keeper posts the first price inside the budget.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        oracle.postNav(FIRST);
        assertEq(oracle.navPerBond(), FIRST);
        assertEq(oracle.pendingNav(), 0);
    }

    /// A second post 90 seconds later, 2 bps away, does not revert and does not land: it PARKS.
    function test_secondPostNinetySecondsLaterTwoBpsAwayParks() public {
        uint256 firstUpdated = oracle.lastUpdated();
        uint256 second = FIRST + (FIRST * 2) / Config.BPS;
        vm.warp(block.timestamp + 90);
        assertEq(oracle.allowedDeviationBps(), 1, "budget at 90s is 1 bps");

        vm.prank(keeper);
        oracle.postNav(second);

        assertEq(oracle.navPerBond(), FIRST, "the accepted price did not move");
        assertEq(oracle.lastUpdated(), firstUpdated, "the staleness clock did not move");
        assertEq(oracle.pendingNav(), second, "the second value is parked");
        assertEq(oracle.pendingConfirmableAt(), block.timestamp + Config.NAV_PENDING_DELAY);
    }

    /// An identical second value is accepted (within any budget) and refreshes nothing.
    function test_identicalSecondPostIsAcceptedAndDoesNotResetTheClock() public {
        uint256 firstUpdated = oracle.lastUpdated();
        vm.warp(block.timestamp + 60);
        vm.prank(keeper);
        oracle.postNav(FIRST);
        assertEq(oracle.navPerBond(), FIRST);
        assertEq(oracle.lastUpdated(), firstUpdated, "zero-delta accept: lastUpdated unmoved");
        assertEq(oracle.pendingNav(), 0);
    }

    /// The parked second value then holds the slot for 36 hours: a THIRD out-of-budget post is
    /// discarded (`NAVPostIgnored`), while an in-budget post the next day is still accepted.
    function test_parkedSecondValueHoldsTheSlotButNotTheFeed() public {
        uint256 second = FIRST + (FIRST * 2) / Config.BPS;
        vm.warp(block.timestamp + 90);
        vm.prank(keeper);
        oracle.postNav(second);

        // Third post, 60s later, 5 bps away: beyond budget, slot held, ignored.
        uint256 third = FIRST + (FIRST * 5) / Config.BPS;
        vm.warp(block.timestamp + 60);
        vm.prank(keeper);
        oracle.postNav(third);
        assertEq(oracle.pendingNav(), second, "the third value was discarded, the slot still holds the second");

        // Next day's ordinary post, 50 bps away, is inside the accrued budget and lands.
        uint256 next = FIRST + (FIRST * 50) / Config.BPS;
        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        oracle.postNav(next);
        assertEq(oracle.navPerBond(), next, "the feed carried on despite the parked value");
        assertEq(oracle.pendingNav(), second, "and the parked value survives the accept, by design");
    }
}
