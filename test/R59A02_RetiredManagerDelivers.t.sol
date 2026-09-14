// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 59, item 244's INFERRED composition, built.
/// @notice `recoverLoss` accepts a FORMER manager for ever (`wasCreditManager`, shipped in #531 for
///         L-01). Item 244 flagged, without building it, that this composes with item 48 / item
///         245's sub-floor freeze: a retired manager can deliver into a pool whose supply sits in
///         `0 < totalSupply < MIN_SUPPLY_FOR_YIELD` with a frozen pot, at any time, for ever.
///
/// @dev Everything here is measurement of SHIPPED behaviour at `c9b5f95`. No source is changed.
///      The fixture is the pool alone with EOA wiring, which is all `recoverLoss` and the freeze
///      need; the full-stack version of the same delivery is
///      `R46PoolRepointRecoveryTest::test_R46_theRecoveryLandsAfterALegalPoolRepoint`, and this
///      file exists to measure the state that one does not enter.
contract R59A02_RetiredManagerDelivers is Test {
    uint256 internal constant MIN_SUPPLY_FOR_YIELD = (10 ** 3) * Config.BPS; // 10,000,000 shares

    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal m1 = makeAddr("retiredManager");
    address internal m2 = makeAddr("liveManager");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice"); // the honest lender
    address internal squatter = makeAddr("squatter"); // item 48's one-wei mint
    address internal newcomer = makeAddr("newcomer");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        pool.setCreditManager(m1);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();
    }

    function _fundAndApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @dev Item 48's ATTACKER route, reproduced here because item 245 measured that the honest
    ///      route lands on supply ZERO (de-recognition) rather than in the band. `pot` is the
    ///      unreleased yield frozen over the dust.
    function _frozenSubFloorPool(uint256 deposit, uint256 pot) internal {
        _fundAndApprove(alice, deposit);
        vm.prank(alice);
        pool.deposit(deposit, alice);

        _fundAndApprove(harvester, pot);
        vm.prank(harvester);
        pool.distributeYield(pot);
        assertGt(pool.unreleasedYield(), 0, "fixture: no live stream");

        // One share for one wei, bought before the last honest lender leaves.
        _fundAndApprove(squatter, 1_000e6);
        vm.prank(squatter);
        pool.mint(1, squatter);

        // Read BEFORE the prank: a staticcall in argument position spends it.
        uint256 aliceMax = pool.maxRedeem(alice);
        vm.prank(alice);
        pool.redeem(aliceMax, alice, alice);

        uint256 supply = pool.totalSupply();
        assertGt(supply, 0, "fixture: supply reached zero, this is the de-recognition arm");
        assertLt(supply, MIN_SUPPLY_FOR_YIELD, "fixture: supply is not in the sub-floor band");
        assertEq(pool.yieldRate(), 0, "fixture: the stream is not frozen");
        assertGt(pool.unreleasedYield(), 0, "fixture: there is no frozen pot");
    }

    /// @notice THE COMPOSITION. A manager the pool retired delivers a recovery into the frozen
    ///         sub-floor state. The delivery is accepted, is added to the frozen pot, releases to
    ///         nobody ever, is charged to every later entrant through `_entryAssets`, and consumes
    ///         deposit-cap headroom that nothing gives back.
    function test_R59A02_aRetiredManagerCanDeliverIntoTheFrozenSubFloorPoolForEver() public {
        _frozenSubFloorPool(20e6, 20e6);

        // The pool moves on to a new manager. Both counters the setter guards on are zero.
        assertEq(pool.outstandingPrincipal(), 0, "fixture: nothing out on loan");
        assertEq(pool.totalImpairment(), 0, "fixture: no mark stands");
        vm.prank(admin);
        pool.setCreditManager(m2);
        assertTrue(pool.wasCreditManager(m1), "the retired manager is remembered for ever");
        assertEq(pool.creditManager(), m2, "and is no longer the live pointer");

        uint256 potBefore = pool.unreleasedYield();
        uint256 usageBefore = pool.depositCapUsage();
        uint256 maxDepositBefore = pool.maxDeposit(newcomer);
        uint256 sharesForTheWholeCapBefore = pool.previewDeposit(maxDepositBefore);
        uint256 squatterBefore = pool.previewRedeem(pool.balanceOf(squatter));
        uint256 exitBefore = pool.exitAssets();

        uint256 delivery = 5_000e6;
        _fundAndApprove(m1, delivery);
        vm.prank(m1);
        pool.recoverLoss(delivery);

        uint256 potAfter = pool.unreleasedYield();
        uint256 usageAfter = pool.depositCapUsage();
        uint256 maxDepositAfter = pool.maxDeposit(newcomer);
        uint256 sharesForTheWholeCapAfter = pool.previewDeposit(maxDepositAfter);
        uint256 squatterAfter = pool.previewRedeem(pool.balanceOf(squatter));

        emit log_named_uint("MEASURED frozen pot before the delivery   ", potBefore);
        emit log_named_uint("MEASURED frozen pot after  the delivery   ", potAfter);
        emit log_named_uint("MEASURED depositCapUsage before           ", usageBefore);
        emit log_named_uint("MEASURED depositCapUsage after            ", usageAfter);
        emit log_named_uint("MEASURED maxDeposit before                ", maxDepositBefore);
        emit log_named_uint("MEASURED maxDeposit after                 ", maxDepositAfter);
        emit log_named_uint("MEASURED shares the whole cap mints before", sharesForTheWholeCapBefore);
        emit log_named_uint("MEASURED shares the whole cap mints after ", sharesForTheWholeCapAfter);
        emit log_named_uint("MEASURED the share floor entry must reach ", MIN_SUPPLY_FOR_YIELD);
        emit log_named_uint("MEASURED squatter previewRedeem before    ", squatterBefore);
        emit log_named_uint("MEASURED squatter previewRedeem after     ", squatterAfter);
        emit log_named_uint("MEASURED exitAssets before                ", exitBefore);
        emit log_named_uint("MEASURED exitAssets after                 ", pool.exitAssets());
        emit log_named_uint("MEASURED lifetimeLossRecovered            ", pool.lifetimeLossRecovered());

        // The delivery landed, and landed in the frozen pot.
        assertEq(potAfter, potBefore + delivery, "the delivery did not join the frozen pot");
        assertEq(pool.yieldRate(), 0, "the delivery thawed the stream");
        assertEq(pool.lifetimeLossRecovered(), delivery, "booked as a recovery");
        // It consumed cap headroom that nothing returns.
        assertEq(usageAfter, usageBefore + delivery, "the delivery did not consume cap headroom");
        assertEq(maxDepositBefore - maxDepositAfter, delivery, "the cap did not shrink by the delivery");
        // And it reached nobody: the exit book is unchanged, so neither the squatter nor anyone
        // else can redeem a wei of it.
        assertEq(pool.exitAssets(), exitBefore, "the exit book moved");
        assertEq(squatterAfter, squatterBefore, "the squatter was paid some of the recovery");
    }

    /// @notice The pot stays frozen for ever after the delivery: time does not release it, and the
    ///         only two thaw doors stay shut because entry can no longer reach the share floor.
    function test_R59A02_theDeliveredRecoveryIsUnreachableByAnyone() public {
        _frozenSubFloorPool(20e6, 20e6);
        vm.prank(admin);
        pool.setCreditManager(m2);

        uint256 delivery = 5_000e6;
        _fundAndApprove(m1, delivery);
        vm.prank(m1);
        pool.recoverLoss(delivery);

        uint256 pot = pool.unreleasedYield();
        skip(400 days);
        assertEq(pool.unreleasedYield(), pot, "time released part of the frozen pot");

        // The whole remaining cap, deposited by a newcomer, still mints under the share floor, so
        // `lend` and `distributeYield` stay shut and nothing can ever rate this pot again.
        uint256 room = pool.maxDeposit(newcomer);
        _fundAndApprove(newcomer, room);
        vm.prank(newcomer);
        uint256 minted = pool.deposit(room, newcomer);
        emit log_named_uint("MEASURED the whole cap deposited          ", room);
        emit log_named_uint("MEASURED shares it minted                 ", minted);
        emit log_named_uint("MEASURED against the share floor          ", MIN_SUPPLY_FOR_YIELD);
        emit log_named_uint("MEASURED newcomer previewRedeem           ", pool.previewRedeem(minted));
        emit log_named_uint("MEASURED newcomer paid                    ", room);
        assertLt(pool.totalSupply(), MIN_SUPPLY_FOR_YIELD, "supply reached the floor after all");

        vm.prank(m2);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.NoSharesOutstanding.selector));
        pool.lend(1);

        _fundAndApprove(harvester, 1e6);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.NoSharesOutstanding.selector));
        pool.distributeYield(1e6);

        assertEq(pool.unreleasedYield(), pot, "the pot moved");
        emit log_named_uint("MEASURED frozen for ever, USDC            ", pot);
    }

    /// @notice The cost to the newcomer of the retired manager's delivery, measured against the
    ///         same pool with no delivery: the entrant pays the same cash and receives strictly
    ///         fewer shares and strictly less redeemable value, because `_entryAssets` charges
    ///         them for a pot that can never release.
    function test_R59A02_theDeliveryIsChargedToTheNextEntrant() public {
        _frozenSubFloorPool(20e6, 20e6);
        vm.prank(admin);
        pool.setCreditManager(m2);

        uint256 entry = 10_000e6;
        uint256 clean = vm.snapshotState();

        // Arm one: no delivery.
        _fundAndApprove(newcomer, entry);
        vm.prank(newcomer);
        uint256 sharesNoDelivery = pool.deposit(entry, newcomer);
        uint256 valueNoDelivery = pool.previewRedeem(sharesNoDelivery);

        // Arm two: the retired manager delivers 5,000 first.
        vm.revertToState(clean);
        uint256 delivery = 5_000e6;
        _fundAndApprove(m1, delivery);
        vm.prank(m1);
        pool.recoverLoss(delivery);
        _fundAndApprove(newcomer, entry);
        vm.prank(newcomer);
        uint256 sharesAfterDelivery = pool.deposit(entry, newcomer);
        uint256 valueAfterDelivery = pool.previewRedeem(sharesAfterDelivery);

        emit log_named_uint("MEASURED entrant cash paid, both arms     ", entry);
        emit log_named_uint("MEASURED shares, no delivery              ", sharesNoDelivery);
        emit log_named_uint("MEASURED shares, after the delivery       ", sharesAfterDelivery);
        emit log_named_uint("MEASURED previewRedeem, no delivery       ", valueNoDelivery);
        emit log_named_uint("MEASURED previewRedeem, after delivery    ", valueAfterDelivery);
        emit log_named_uint("MEASURED entrant's extra loss, USDC       ", valueNoDelivery - valueAfterDelivery);

        assertLt(sharesAfterDelivery, sharesNoDelivery, "the delivery did not raise the entry price");
        assertLt(valueAfterDelivery, valueNoDelivery, "the delivery did not cost the entrant");
    }

    /// @notice The same door in a HEALTHY pool, for the contrast the register needs: a retired
    ///         manager's delivery there streams to the sitting lenders, which is L-01's intended
    ///         behaviour. It also consumes deposit-cap headroom, which is the part that is a lever
    ///         rather than a gift.
    function test_R59A02_inAHealthyPoolTheSameDoorIsAGiftThatClosesTheDepositCap() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.deposit(10_000e6, alice);
        vm.prank(admin);
        pool.setCreditManager(m2);

        uint256 roomBefore = pool.maxDeposit(newcomer);
        uint256 aliceBefore = pool.previewRedeem(pool.balanceOf(alice));

        // A retired manager fills every wei of remaining cap room with donated USDC.
        _fundAndApprove(m1, roomBefore);
        vm.prank(m1);
        pool.recoverLoss(roomBefore);

        emit log_named_uint("MEASURED cap room before                  ", roomBefore);
        emit log_named_uint("MEASURED cap room after                   ", pool.maxDeposit(newcomer));
        emit log_named_uint("MEASURED alice previewRedeem before       ", aliceBefore);
        emit log_named_uint("MEASURED alice previewRedeem at once      ", pool.previewRedeem(pool.balanceOf(alice)));
        vm.warp(pool.yieldStreamEndsAt() + 1);
        emit log_named_uint("MEASURED alice previewRedeem after stream ", pool.previewRedeem(pool.balanceOf(alice)));

        assertEq(pool.maxDeposit(newcomer), 0, "the deposit door is still open");
        assertGt(pool.previewRedeem(pool.balanceOf(alice)), aliceBefore, "the sitting lender was not paid");
    }
}
