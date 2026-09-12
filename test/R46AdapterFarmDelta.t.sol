// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Audit round 46, finding F1, and the falsifier for `DirectCallAdapter._farmDelta`.
///
///         `DirectCallAdapter` measured its own USDC balance either side of every farm call with a
///         BARE subtraction, while `_freeBalance()` on the same statement is saturating and its own
///         docstring says why: "an underflow here would revert `stake`, `unstake` and `mintBonds`
///         alike, which is to say every collateral path ... a token must never be able to do that."
///
///         The adapter carries no `ReentrancyGuard` - deliberately, and `flushYieldTo`'s docstring
///         gives the reason - and `flushYieldTo(address)` is permissionless and moves USDC OUT.
///         With a park standing in `owedToRecipient`, built by the documented and intended route,
///         a farm that re-enters it inside `deposit`/`withdraw` drops this contract's balance below
///         `balBefore`, the subtraction panics `0x11`, and every collateral path goes down with it.
///         Audit round 34 recorded the exposure for `_recoverTo` alone, where the window is an
///         owner-named recovery recipient and where a refusal is the correct answer; the farm
///         windows are DexFi's, nobody can un-choose them, and none of them was documented.
///
///         `IDexFiFarm` says to treat farm behaviour as mutable at DexFi's discretion. The hostile
///         farm below does exactly one thing a real MasterChef would not, and it is the whole
///         model: it makes one external call while it holds control.
contract R46FarmThatReenters is IDexFiFarm {
    DirectCallAdapter public adapter;
    MockUSDC public usdc;
    address public drainTarget;
    bool public armed;
    /// @notice USDC paid to the caller on any `deposit`/`withdraw`, as a MasterChef-style pool
    ///         settles the whole position's pending rewards on either.
    uint256 public payout;
    mapping(address => uint256) public stakedOf;

    constructor(MockUSDC usdc_) {
        usdc = usdc_;
    }

    function setPayout(uint256 amount) external {
        payout = amount;
    }

    function arm(DirectCallAdapter adapter_, address target) external {
        adapter = adapter_;
        drainTarget = target;
        armed = true;
    }

    function deposit(uint256 amount) external {
        stakedOf[msg.sender] += amount;
        _settleThenMaybeDrain();
    }

    function withdraw(uint256 amount) external {
        if (amount != 0 && stakedOf[msg.sender] >= amount) stakedOf[msg.sender] -= amount;
        _settleThenMaybeDrain();
    }

    function emergencyWithdraw() external {
        stakedOf[msg.sender] = 0;
    }

    function depositForAccount(address account, uint256 amount) external {
        stakedOf[account] += amount;
    }

    function pendingShare(address) external pure returns (uint256) {
        return 0;
    }

    function userInfo(address account) external view returns (uint256, uint256) {
        return (stakedOf[account], 0);
    }

    function poolEndTime() external view returns (uint256) {
        return block.timestamp + 365 days;
    }

    /// @dev The reward first, then the re-entry, which is the ordering that makes the under-report
    ///      measurable: real yield arrives inside the window and the drain then hides it. One shot,
    ///      so the path after a fired drain stays exercisable.
    function _settleThenMaybeDrain() private {
        if (payout != 0) usdc.transfer(msg.sender, payout);
        if (!armed) return;
        armed = false;
        adapter.flushYieldTo(drainTarget);
    }
}

contract R46AdapterFarmDeltaTest is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant PARK = 1_000e6;
    uint256 internal constant FARM_PAYOUT = 7e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal sinkA = makeAddr("sinkA");
    address internal sinkB = makeAddr("sinkB");

    MockUSDC internal usdc;
    MockBond internal bond;
    R46FarmThatReenters internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new R46FarmThatReenters(usdc);
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
            IDexFiBond(address(bond)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, sinkA
        );
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        // The farm needs a float to pay rewards out of.
        usdc.mint(address(farm), 1_000_000e6);

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(100);
        vm.stopPrank();
    }

    /// @dev Build the one state `flushYieldTo` needs: a park against a former recipient. The
    ///      sequence is the documented, intended one - a recipient that cannot receive USDC,
    ///      followed by the owner repointing away from it - and is precisely what
    ///      `owedToRecipient` exists for. Nothing here needs a hostile owner.
    function _park(uint256 amount) internal {
        usdc.mint(address(adapter), amount);
        usdc.setBlocked(sinkA, true);
        vm.prank(admin);
        adapter.setYieldRecipient(sinkB);
        usdc.setBlocked(sinkA, false);
        assertEq(adapter.owedToRecipient(sinkA), amount, "park not created");
        assertEq(adapter.totalOwedToRecipients(), amount, "park total not created");
    }

    // -- the two windows the finding names -----------------------------------

    function test_R46_control_anOrdinaryExitIsUndisturbedByAParkedBalance() public {
        _park(PARK);
        uint256 before = bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID);
        vm.prank(alice);
        vault.withdrawBonds(10);
        assertEq(
            bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID),
            before + 10,
            "control: the exit works with a park standing and the farm quiescent"
        );
        assertEq(adapter.totalOwedToRecipients(), PARK, "control: the park is untouched");
    }

    function test_R46_aCollateralExitSurvivesAFarmThatReentersFlushYieldTo() public {
        _park(PARK);
        farm.arm(adapter, sinkA);

        // `withdrawBonds` -> `adapter.unstake` -> `farm.withdraw` -> `flushYieldTo(sinkA)`, which
        // takes the whole park out of the adapter inside the measurement window. Before
        // `_farmDelta` this panicked `0x11` and reverted the exit.
        uint256 before = bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID);
        vm.prank(alice);
        vault.withdrawBonds(10);

        assertEq(
            bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID),
            before + 10,
            "the collateral exit completed through the drained window"
        );
        assertEq(usdc.balanceOf(sinkA), PARK, "the park was paid to the recipient it was parked for");
        assertEq(adapter.totalOwedToRecipients(), 0, "the park is discharged, not double counted");
    }

    function test_R46_theSameWindowOnStakeSurvivesToo() public {
        _park(PARK);
        farm.arm(adapter, sinkA);

        // `depositBonds` -> `adapter.stake` -> `farm.deposit` -> `flushYieldTo(sinkA)`. `stake` is
        // the entry half of the same pair, so a bricked window here closes deposits as well as
        // exits - and `depositETH`, `seize` and `disposeTo` reach the same two functions.
        vm.prank(alice);
        vault.depositBonds(10);

        assertEq(vault.bondCount(alice), 110, "the deposit was credited through the drained window");
        assertEq(usdc.balanceOf(sinkA), PARK, "the park was paid to the recipient it was parked for");
    }

    /// @notice Audit round 48, finding 82: `seize` EXECUTED through the same drained window,
    ///         where round 46 had only read it off the vault. `seize` -> `adapter.unstake` ->
    ///         `farm.withdraw` -> `flushYieldTo(sinkA)`, the identical window `withdrawBonds`
    ///         takes; what differs is the caller, so this wires an auction stub and pranks as it.
    /// @dev    No credit manager is wired, so `_requireLiquidatable` returns early and
    ///         `_settlePosition` is a no-op - the test is about the custody window, not the health
    ///         test, which has its own suite. `disposeTo` is the one `unstake` call site still
    ///         confirmed by reading: it needs a lot parked under an auction's ledger entry, which
    ///         is a whole workout to build for a window this test already shows survives.
    function test_R48_seizeSurvivesTheSameDrainedWindow() public {
        MockLiquidationAuction auction = new MockLiquidationAuction();
        auction.setVault(address(vault));
        auction.setRiskParams(address(riskParams));
        auction.setNavOracle(address(oracle));
        vm.prank(admin);
        vault.setLiquidationAuction(address(auction));

        _park(PARK);
        farm.arm(adapter, sinkA);

        uint256 before = bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID);
        vm.prank(address(auction));
        uint256 seized = vault.seize(alice, alice);

        assertEq(seized, 100, "the whole position was seized through the drained window");
        assertEq(vault.bondCount(alice), 0, "the ledger cleared");
        assertEq(
            bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID),
            before + 100,
            "the seized lot reached its destination"
        );
        assertEq(usdc.balanceOf(sinkA), PARK, "the park was paid to the recipient it was parked for");
        assertEq(adapter.totalOwedToRecipients(), 0, "the park is discharged, not double counted");
    }

    /// @dev The asymmetry the fix removes, stated as a measurement rather than as a reading of the
    ///      source: the saturating `_freeBalance` helper always survived this identical drop, and
    ///      the bare subtraction one expression to its left did not. `_freeBalance` is private, so
    ///      it is exercised through `_trySweepUsdc`, which is what `setYieldRecipient` runs.
    function test_R46_theSaturatingHelperOnTheSameStatementAlwaysSurvivedThisDrop() public {
        _park(PARK);
        adapter.flushYieldTo(sinkA); // the same call the farm makes re-entrantly, from outside
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter emptied");
        assertEq(adapter.totalOwedToRecipients(), 0, "park discharged");

        vm.prank(alice);
        vault.withdrawBonds(10);
        assertEq(adapter.unreportedYield(), 0, "no phantom carried");
    }

    // -- the residual the fix accepts ----------------------------------------

    /// @dev **The under-report, pinned as a measurement rather than left as an argument.**
    ///      Saturating means a drained window reports `farmPaid = 0`, so `farmYieldDelivered`
    ///      under-counts the farm USDC that really arrived. `_settleFarmPayout`'s own docstring
    ///      already calls under-counting the safe direction for that watermark ("audit round 22
    ///      measured this counter recording as delivered a 1,000.000000 epoch that the recipient
    ///      never received"), and `EpochHarvester` holds a high-water mark against it, so it may
    ///      lag but must never lead.
    ///
    ///      The honest leg is not a constant typed in here: it is the same fixture with the same
    ///      payout and the farm quiescent, so if the settle path ever changes both legs move.
    function test_R46_theUnderReportIsBoundedAboveByTheHonestFigure() public {
        // The park is built first and the payout switched on after it, so `setYieldRecipient`'s
        // own `claimFarmRewards` does not fold a farm payout into the parked amount.
        _park(PARK);
        farm.setPayout(FARM_PAYOUT);
        uint256 deliveredBefore = adapter.farmYieldDelivered();

        // The honest window first: real farm yield, nobody re-entering.
        vm.prank(alice);
        vault.withdrawBonds(10);
        uint256 honest = adapter.farmYieldDelivered() - deliveredBefore;
        assertEq(honest, FARM_PAYOUT, "the honest window counts the whole payout");
        assertGt(honest, 0, "the comparison below is not vacuous");

        // The same window, drained from inside by the farm.
        uint256 deliveredBeforeHostile = adapter.farmYieldDelivered();
        uint256 recipientBefore = usdc.balanceOf(sinkB);
        farm.arm(adapter, sinkA);
        vm.prank(alice);
        vault.withdrawBonds(10);
        uint256 hostile = adapter.farmYieldDelivered() - deliveredBeforeHostile;

        assertLe(hostile, honest, "the watermark may lag the truth and must never lead it");
        assertEq(hostile, 0, "MEASURED: a fully drained window reports nothing at all");
        assertEq(
            usdc.balanceOf(sinkB) - recipientBefore,
            FARM_PAYOUT,
            "no money is lost: the payout still reaches the live recipient, only the count is short"
        );
    }
}
