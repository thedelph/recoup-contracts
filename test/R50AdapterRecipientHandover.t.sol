// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round-50 item 84: `DirectCallAdapter.setYieldRecipient` was the one farm-touching path
///         that delivered farm yield without going through `_settleFarmPayout`.
///
/// @dev Found by a round-50 fleet agent and sign-checked by execution. `setYieldRecipient`'s escape
///      hatch did `try this.claimFarmRewards() {} catch {}` followed by a bare
///      `if (_trySweepUsdc() != 0) unreportedYield = 0;`. `claimFarmRewards` is `farm.withdraw(0)`
///      and nothing else - it settles nothing - so the claimed USDC was forwarded to the outgoing
///      recipient with `farmYieldDelivered` unmoved, and any carried `unreportedYield` was zeroed
///      without ever being counted.
///
///      `farmYieldDelivered` is the harvester's CORROBORATION WATERMARK: `_settleFarmPayout`'s own
///      comment calls itself "the one funnel every farm-touching path goes through, so a NEW path
///      cannot deliver farm yield without also corroborating the epoch that pays it out". An OLD
///      path was outside it.
///
///      **The direction is an under-count and that is why it survived.** The harvester declines the
///      epoch as uncorroborated and the same USDC is counted by the next real one, so nobody is
///      paid money that does not exist. Where it bites is the Phase-3 handover, which IS a
///      `setYieldRecipient` over an epoch of accrual - the one moment the protocol makes this call
///      in anger.
///
///      Self-contained: this file builds its own graph in `setUp` rather than subclassing a repo
///      fixture, so it inherits no other suite's tests.
contract R50AdapterRecipientHandoverTest is Test {
    address internal constant ADMIN = address(0xA11CE0);
    address internal constant ALICE = address(0xA1);
    address internal constant YIELD_SINK = address(0x5217);
    address internal constant SINK2 = address(0x5218);
    address internal constant HARVESTER = address(0x8A72E5);

    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant PAYOUT = 100e6;

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;

    function setUp() public {
        vm.warp(1_780_000_000);

        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            ADMIN
        );
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), ADMIN
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), ADMIN, YIELD_SINK
        );
        credit = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            ADMIN
        );

        vm.startPrank(ADMIN);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        credit.setEpochHarvester(HARVESTER);
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        bond.mint(ALICE, 1_000);
        vm.startPrank(ALICE);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @notice CONTROL: an ordinary farm-touching path credits the watermark by what it moved.
    /// @dev This is the denominator. Without it, the two assertions below would be satisfied by an
    ///      adapter whose watermark never moves at all.
    function test_R50_84_control_anOrdinaryFarmPathCreditsTheWatermark() public {
        farm.setPendingYield(address(adapter), PAYOUT);
        uint256 markBefore = adapter.farmYieldDelivered();

        vm.prank(ALICE);
        vault.depositBonds(1);

        assertEq(adapter.farmYieldDelivered() - markBefore, PAYOUT, "the funnel counts what it moved");
        assertEq(usdc.balanceOf(YIELD_SINK), PAYOUT, "and the recipient received it");
    }

    /// @notice The repoint credits the watermark for the farm yield it shakes loose and forwards.
    /// @dev **RED before the fix, MEASURED:** the same `PAYOUT` reached the same recipient and
    ///      `farmYieldDelivered` did not move at all - `100000000 != 0` against the control's
    ///      `100000000`. Nothing was parked, because nothing failed; it was delivered and not
    ///      counted.
    function test_R50_84_theRepointCreditsTheYieldItShakesLooseAndForwards() public {
        farm.setPendingYield(address(adapter), PAYOUT);
        uint256 markBefore = adapter.farmYieldDelivered();

        vm.prank(ADMIN);
        adapter.setYieldRecipient(SINK2);

        assertEq(usdc.balanceOf(YIELD_SINK), PAYOUT, "the outgoing recipient received the farm yield");
        assertEq(adapter.farmYieldDelivered() - markBefore, PAYOUT, "and the watermark moved with it");
        assertEq(adapter.owedToRecipient(YIELD_SINK), 0, "nothing was parked - it was delivered");
        assertEq(adapter.unreportedYield(), 0, "and nothing is left carried");
    }

    /// @notice The repoint counts a CARRY it clears, instead of dropping it.
    /// @dev **RED before the fix, MEASURED:** the carry stood at the whole payout, the repoint
    ///      forwarded it to the outgoing recipient, cleared `unreportedYield` and left the
    ///      watermark where it was - and from that moment the amount is uncountable, because
    ///      nothing else remembers it.
    ///
    ///      The carry is built through an ordinary path with the sink blocked, so
    ///      `_settleFarmPayout` cannot sweep and parks the payout in `unreportedYield`. The sink is
    ///      then unblocked and the farm has nothing left to pay, so the self-called
    ///      `claimFarmRewards` shakes zero loose and only the carried money is in play - which is
    ///      what isolates the carry arm from the delivery arm above.
    function test_R50_84_theRepointCountsTheCarryItClears() public {
        usdc.setBlocked(YIELD_SINK, true);
        farm.setPendingYield(address(adapter), PAYOUT);
        vm.prank(ALICE);
        vault.depositBonds(1);

        usdc.setBlocked(YIELD_SINK, false);
        uint256 markBefore = adapter.farmYieldDelivered();
        uint256 carriedBefore = adapter.unreportedYield();
        assertEq(carriedBefore, PAYOUT, "premise: the carry stands at the whole payout");
        assertEq(markBefore, 0, "premise: a failed sweep counts nothing");

        vm.prank(ADMIN);
        adapter.setYieldRecipient(SINK2);

        assertEq(adapter.unreportedYield(), 0, "the repoint clears the carry");
        assertEq(usdc.balanceOf(YIELD_SINK), PAYOUT, "the money reached the outgoing recipient");
        assertEq(
            adapter.farmYieldDelivered() - markBefore, PAYOUT, "and the watermark now counts it exactly once"
        );
    }

    /// @notice The escape hatch is unchanged: a recipient that cannot receive still parks, and the
    ///         repoint still succeeds.
    /// @dev The property the old bare sweep existed for, asserted so the fix cannot be read as
    ///      having made the hatch mandatory. `_settleFarmPayout` performs the identical best-effort
    ///      sweep, so a blocked recipient still falls through to the park below it - and the
    ///      carried counter still goes with the money, which is what that park's own comment says
    ///      it does.
    function test_R50_84_aBlockedRecipientStillParksAndTheRepointStillSucceeds() public {
        farm.setPendingYield(address(adapter), PAYOUT);
        usdc.setBlocked(YIELD_SINK, true);

        vm.prank(ADMIN);
        adapter.setYieldRecipient(SINK2);

        assertEq(adapter.yieldRecipient(), SINK2, "the escape hatch still opens");
        assertEq(usdc.balanceOf(YIELD_SINK), 0, "the blocked recipient received nothing");
        assertEq(adapter.owedToRecipient(YIELD_SINK), PAYOUT, "and the whole payout is parked for it");
        assertEq(adapter.unreportedYield(), 0, "the carried counter went with the money");
        assertEq(adapter.farmYieldDelivered(), 0, "nothing delivered, nothing counted");
    }
}
