// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R55A02 - the epoch corroboration signal is bound to the recipient
/// @notice Round-55 item 219. `harvest` rated an epoch as real when `adapter.farmYieldDelivered()`
///         moved, and that counter counts farm USDC forwarded to WHOEVER `yieldRecipient` is. With
///         the recipient elsewhere, the counter moves, the yield lands elsewhere, and a stranger's
///         donation to the harvester is run as epoch 1 - round 11 reopened by a wiring order.
///
/// @dev Fix, the form that survived the tree: the adapter keeps a SECOND counter,
///      `farmYieldDeliveredToHarvester`, moved only when the recipient the sweep paid IS the wired
///      harvester, and `EpochHarvester` seeds and corroborates on that one. `farmYieldDelivered`
///      keeps its round-11 meaning (every farm-touching path, whoever received it), which 27
///      shipped tests pin and which the first form of this fix - gating that counter itself -
///      broke. A harvester-side `yieldRecipient()` revert (form H, +154 on the harvester) was
///      also built and REFUTED by the handover residual below: it names the wrong recipient but
///      cannot see the counter moving under it. `fix_` is RED at 9a01996 (the epoch runs);
///      `control_` and `negative_` are green on both trees.
contract R55A02_HarvesterRecipientBinding is Test {
    bytes4 internal constant TO_HARVESTER = bytes4(keccak256("farmYieldDeliveredToHarvester()"));
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant FARM_PAYOUT = 500e6;
    uint256 internal constant DONATION = 10e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal feeWallet = makeAddr("feeWallet");
    address internal elsewhere = makeAddr("elsewhere");
    address internal donor = makeAddr("donor");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    EpochHarvester internal harvester;
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    function setUp() public {
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
            admin
        );
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, elsewhere
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        treasury = new TreasuryLiquiditySource(usdc, admin);
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        credit.setEpochHarvester(address(harvester));
        adapter.setHarvester(address(harvester));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        harvester.setProtocolFeeWallet(feeWallet);
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _bindRecipient() internal {
        vm.prank(admin);
        adapter.setYieldRecipient(address(harvester));
    }

    /// @dev Low-level so this file compiles at 9a01996, where the view does not exist: there it
    ///      answers 0, which is exactly what the fix_ cases then fail on.
    function _toHarvester() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(adapter).staticcall(abi.encodeWithSelector(TO_HARVESTER));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256));
    }

    function _donate() internal {
        usdc.mint(donor, DONATION);
        vm.prank(donor);
        usdc.transfer(address(harvester), DONATION);
    }

    function test_R55A02_219_fix_theBoundRecipientHarvestsAndIsCounted() public {
        _bindRecipient();
        farm.setPendingYield(address(adapter), FARM_PAYOUT);
        harvester.harvest();
        assertEq(harvester.epochCount(), 1, "epoch 1 ran");
        assertEq(adapter.farmYieldDelivered(), FARM_PAYOUT);
        assertEq(_toHarvester(), FARM_PAYOUT, "and the harvester-bound counter moved with it");
    }

    /// @notice The finding, then the fix. Recipient elsewhere (the pre-handover sink shape, with
    ///         the harvester's adapter already set), farm pays 500.000000 to it, the counter moves,
    ///         a stranger donates 10.000000 to the harvester. At 9a01996 `harvest` runs the donation
    ///         as epoch 1; under the fix the yield still goes elsewhere (the recipient is the
    ///         owner's choice) but corroborates nothing, and the epoch is DECLINED.
    function test_R55A02_219_fix_aMisPointedRecipientCannotCorroborate() public {
        assertEq(adapter.yieldRecipient(), elsewhere, "premise: recipient elsewhere");
        farm.setPendingYield(address(adapter), FARM_PAYOUT);
        _donate();

        uint256 distributeBefore = credit.lastDistributeAt();
        vm.expectEmit(true, false, false, true, address(harvester));
        emit EpochHarvester.EpochDeclinedUncorroborated(1, 0, DONATION);
        harvester.harvest();
        assertEq(harvester.epochCount(), 0, "no epoch was run on the donation");
        assertEq(credit.lastDistributeAt(), distributeBefore, "the anti-JIT input did not move");
        assertEq(usdc.balanceOf(elsewhere), FARM_PAYOUT, "the yield went where the owner pointed it");
        assertEq(adapter.farmYieldDelivered(), FARM_PAYOUT, "the round-11 counter still counts it");
        assertEq(_toHarvester(), 0, "the harvester-bound counter does not");
    }

    /// @notice MEASURED at 9a01996 (the pin, stated as a measurement rather than asserted, so this
    ///         file has no case that is red under the fix): with no binding the same call claims the
    ///         farm to `elsewhere`, moves the counter to 500.000000, and runs the 10.000000 donation
    ///         as epoch 1. Under the fix the call reverts before the claim.
    function test_R55A02_219_measure_whatTheUnboundEpochDoes() public {
        farm.setPendingYield(address(adapter), FARM_PAYOUT);
        _donate();
        (bool ok,) = address(harvester).call(abi.encodeCall(harvester.harvest, ()));
        emit log_named_uint("harvest() succeeded (1) or reverted (0)", ok ? 1 : 0);
        emit log_named_uint("epochCount after", harvester.epochCount());
        emit log_named_uint("usdc at elsewhere", usdc.balanceOf(elsewhere));
        emit log_named_uint("farmYieldDelivered", adapter.farmYieldDelivered());
        emit log_named_uint("farmYieldDeliveredToHarvester", _toHarvester());
    }

    /// @notice Repair is one owner call and the same epoch then lands, on both trees.
    function test_R55A02_219_negative_repairThenHarvest() public {
        _bindRecipient();
        farm.setPendingYield(address(adapter), FARM_PAYOUT);
        harvester.harvest();
        assertEq(harvester.epochCount(), 1, "the epoch ran once the recipient was bound");
        assertEq(usdc.balanceOf(elsewhere), 0, "nothing went elsewhere");
    }

    /// @notice THE HANDOVER RESIDUAL, found by the first form of this fix. `setYieldRecipient` settles
    ///         the farm and pays the pending yield to the OUTGOING recipient - correctly, it earned
    ///         it - and `_settleFarmPayout` counted that payout into `farmYieldDelivered`. So with
    ///         the harvester's watermark at 0, a repair from `elsewhere` to the harvester moved the
    ///         counter by 500.000000 that went elsewhere, and the next bound harvest ran a stranger's
    ///         10.000000 donation as epoch 1: a harvester-side recipient check alone cannot see it.
    ///         Closed on the ADAPTER: the harvester-bound counter only counts USDC forwarded to the
    ///         wired harvester. RED at 9a01996 and under form H alone; green under this form.
    function test_R55A02_219_fix_theHandoverSettleCannotCorroborateAnEpochElsewhere() public {
        farm.setPendingYield(address(adapter), FARM_PAYOUT);
        _donate();
        _bindRecipient(); // pays the 500.000000 to elsewhere; the counter must not move
        assertEq(usdc.balanceOf(elsewhere), FARM_PAYOUT, "premise: the handover paid the outgoing recipient");
        assertEq(adapter.farmYieldDelivered(), FARM_PAYOUT, "the round-11 counter counts the handover payout");
        assertEq(_toHarvester(), 0, "the harvester-bound counter does not");
        harvester.harvest();
        assertEq(harvester.epochCount(), 0, "the donation must not run as epoch 1");
    }

    /// @notice The wiring order that reaches the state: `setCustodyAdapter` still ACCEPTS an adapter
    ///         whose recipient is elsewhere (the check is per-epoch, not per-wire), on both trees.
    function test_R55A02_219_negative_theWireStillAcceptsAnUnboundAdapter() public {
        EpochHarvester fresh = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        vm.prank(admin);
        fresh.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        assertEq(address(fresh.custodyAdapter()), address(adapter), "wired");
    }
}
