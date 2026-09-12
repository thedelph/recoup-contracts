// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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

/// @title R54A02 - `EpochHarvester.setCustodyAdapter` re-seeds only when the pointer MOVES
/// @notice Audit round 54 item 216, incidental, FIXED in round 55. The setter's re-seed is written
///         for a pointer that MOVES ("any state this contract carries about a wiring pointer has to
///         be re-derived when that pointer moves"). Called with the address already wired - an
///         idempotent re-wire, which is the shape a deploy or repair script produces - it USED TO
///         overwrite `lastCorroboratedYield` with the live counter and thereby discard the
///         corroboration of farm yield ALREADY SITTING IN THIS CONTRACT and not yet epoched, so the
///         next `harvest` declined `EpochDeclinedUncorroborated` over a real farm epoch until
///         another `Config.MIN_EPOCH_FARM_YIELD` of farm delivery landed. Nothing was lost; an
///         epoch was delayed by an owner call that changed no pointer. The shipped guard returns
///         on a non-move, after `CustodyAdapterSet` and before the re-seed.
/// @dev Self-contained fixture. 🟩 **THE FIX SHIPPED IN ROUND 55 and this file's pin was FLIPPED
///      in the same commit.** The round-54 shape - `test_R54A02_aSameAddressReWireDeclinesTheEpoch
///      AlreadyDelivered`, which asserted `EpochDeclinedUncorroborated` and `epochCount == 0` - was
///      green at `f16e6e6` and pinned the defect OPEN; it is replaced here by
///      `test_R54A02_fixed_*`, which asserts the decline is GONE, and joined by
///      `test_R54A02_fix_aSameAddressReWireLeavesTheWatermarkAlone`, promoted from round 54's
///      bundle, where it was red by design. A green run of either at `f16e6e6` is impossible, which
///      is the point: the flip is the clearance, not the green.
///
///      The shipped form reads `current` before the write and, after `CustodyAdapterSet`, returns
///      on `adapter == current` ahead of the re-seed and its own event. Round 54 MEASURED it on a
///      clean `out/` at `EpochHarvester` runtime **+24** (7,121 to 7,145) with `CreditManager`, the
///      binding arm, byte-identical at 22,211 / 2,365; re-derive from the size gate rather than
///      quoting that. `test_R54A02_negative_aRealMoveStillReSeeds` is green on both trees and is
///      the round-11 property the fix must keep.
contract R54A02_HarvesterReseedOnSameAdapter is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant FARM_PAYOUT = 500e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal feeWallet = makeAddr("feeWallet");
    address internal yieldSink = makeAddr("yieldSink");

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
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
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
        adapter.setYieldRecipient(address(harvester));
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

    /// @dev The farm pays the adapter; the owner's manual claim sweeps it to the harvester and moves
    ///      `farmYieldDelivered`. The USDC is now here and corroborated but not yet epoched.
    function _deliverFarmYield() internal {
        farm.setPendingYield(address(adapter), FARM_PAYOUT);
        vm.prank(admin);
        vault.harvestYield();
        assertEq(usdc.balanceOf(address(harvester)), FARM_PAYOUT, "fixture: yield not at the harvester");
        assertEq(adapter.farmYieldDelivered(), FARM_PAYOUT, "fixture: counter did not move");
    }

    /// @notice CONTROL. Without the re-wire the epoch runs.
    function test_R54A02_control_theEpochRunsWhenNobodyReWires() public {
        _deliverFarmYield();
        harvester.harvest();
        assertEq(harvester.epochCount(), 1, "epoch ran");
    }

    /// @notice THE FLIP of round 54's pin, which asserted the opposite of every line below and was
    ///         green at `f16e6e6`. An idempotent `setCustodyAdapter(current)` between the delivery
    ///         and the harvest no longer declines the epoch. Asserted at the EVENT level rather
    ///         than by `epochCount` alone, because the pin's own assertion was an `expectEmit` of
    ///         `EpochDeclinedUncorroborated` and the honest flip of an emit assertion is a search
    ///         of the log for that `topic0`, not its absence inferred from a counter.
    function test_R54A02_fixed_aSameAddressReWireNoLongerDeclinesTheEpochAlreadyDelivered() public {
        _deliverFarmYield();
        uint256 markBefore = harvester.lastCorroboratedYield();
        vm.prank(admin);
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        emit log_named_uint("MEASURED watermark before the same-address re-wire", markBefore);
        emit log_named_uint("MEASURED watermark after", harvester.lastCorroboratedYield());

        vm.recordLogs();
        harvester.harvest();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 declined = EpochHarvester.EpochDeclinedUncorroborated.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(harvester) && logs[i].topics[0] == declined) {
                fail("the epoch was declined after an idempotent re-wire");
            }
        }
        assertEq(harvester.epochCount(), 1, "the delivered epoch ran");
        // Not zero: the lender share stays here as `pendingLenderYield` until a pool takes it.
        // What matters is that the delivered yield was SPENT by an epoch rather than left whole by a
        // decline, which is exactly what the pin asserted the other way round.
        assertLt(usdc.balanceOf(address(harvester)), FARM_PAYOUT, "the epoch spent the delivered yield");
    }

    /// @notice PROMOTED from round 54's bundle, where it was RED at `f16e6e6` by design: under the
    ///         shipped fix a same-address call leaves the watermark alone and the epoch runs.
    function test_R54A02_fix_aSameAddressReWireLeavesTheWatermarkAlone() public {
        _deliverFarmYield();
        uint256 markBefore = harvester.lastCorroboratedYield();
        vm.prank(admin);
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        assertEq(harvester.lastCorroboratedYield(), markBefore, "watermark moved on a non-move");
        harvester.harvest();
        assertEq(harvester.epochCount(), 1, "the delivered epoch ran");
    }

    /// @notice INCIDENTAL, MEASURED, green everywhere (no fix proposed). The corroboration signal
    ///         `farmYieldDelivered` counts farm USDC delivered to WHOEVER `yieldRecipient` is, and
    ///         `harvest` never checks that the recipient is this contract. With the recipient pointed
    ///         elsewhere (an owner wiring order, or the pre-handover treasury sink) the farm's own
    ///         deliveries corroborate an epoch that THIS contract sizes from a stranger's donation -
    ///         round 11's $1.82 purchase of `lastDistributeAt`, reopened by wiring rather than code.
    /// @dev FLIPPED in round 55 (A2, item 219). This case pinned the open state - it asserted
    ///      `epochCount == 1` and a moved `lastDistributeAt` - and now asserts the closure: the
    ///      harvester corroborates on the adapter's `farmYieldDeliveredToHarvester`, which yield
    ///      forwarded elsewhere does not move, so the donated epoch is DECLINED. The new view is
    ///      read low-level so a neuter of the adapter still compiles this file.
    function test_R54A02_fixed_theCorroborationSignalIsBoundToTheRecipient() public {
        address elsewhere = makeAddr("elsewhere");
        vm.prank(admin);
        adapter.setYieldRecipient(elsewhere);

        // The farm pays; the counter moves; the USDC lands elsewhere.
        farm.setPendingYield(address(adapter), FARM_PAYOUT);
        vm.prank(admin);
        vault.harvestYield();
        assertEq(usdc.balanceOf(elsewhere), FARM_PAYOUT, "fixture: yield went elsewhere");
        assertEq(usdc.balanceOf(address(harvester)), 0, "fixture: none reached the harvester");

        // A stranger donates just over the dust floor and the harvester runs a corroborated epoch.
        uint256 donation = 1_818_182;
        usdc.mint(address(harvester), donation);
        uint256 distributeBefore = credit.lastDistributeAt();
        skip(1 hours);
        vm.expectEmit(true, false, false, true, address(harvester));
        emit EpochHarvester.EpochDeclinedUncorroborated(1, 0, donation);
        harvester.harvest();
        assertEq(harvester.epochCount(), 0, "the donated epoch is declined: nothing reached the harvester");
        assertEq(credit.lastDistributeAt(), distributeBefore, "and the anti-JIT window's input did not move");
        assertEq(adapter.farmYieldDelivered(), FARM_PAYOUT, "the round-11 counter still counts the payout");
        (bool okTo, bytes memory retTo) = address(adapter).staticcall(abi.encodeWithSignature("farmYieldDeliveredToHarvester()"));
        assertTrue(okTo && retTo.length == 32, "the harvester-bound counter exists");
        assertEq(abi.decode(retTo, (uint256)), 0, "and it does not count yield that went elsewhere");
    }

    /// @notice NEGATIVE, green everywhere: a REAL move still re-seeds, which is the round-11 property
    ///         the setter exists for.
    function test_R54A02_negative_aRealMoveStillReSeeds() public {
        _deliverFarmYield();
        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        vm.prank(admin);
        harvester.setCustodyAdapter(ICustodyAdapter(address(fresh)));
        assertEq(harvester.lastCorroboratedYield(), 0, "a fresh adapter's mark is its own zero counter");
        assertEq(address(harvester.custodyAdapter()), address(fresh), "pointer moved");
    }
}
