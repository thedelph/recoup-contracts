// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
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

/// @title R51A02 - the over-realisation door on `LiquidationAuction`, costed
/// @notice Round 51, round-51 item 154 (the shared pot realised whole) and round-51 item 155 (the
///         dead `swept == 0` refusal and its shared selector). SELF-CONTAINED: this file builds its
///         own protocol in `setUp` rather than subclassing a repository fixture, so the replay tool
///         can patch it and it inherits no other suite's tests.
/// @dev Every scenario figure is derived from the live `RiskParams` rather than written as a
///      literal, and every risk-parameter read happens BEFORE any `vm.prank`, because a view in
///      argument position spends the prank.
///
///      This file must compile unchanged against three source states - the shipped tree, the O(n)
///      reserve patch and the O(1) reserve patch - so it never names a symbol the patches add.
contract R51A02OverRealisationDoorTest is Test {
    address internal constant ADMIN = address(0xA11CE0);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0xCAFE);
    address internal constant HARVESTER = address(0x8A72E5);
    address internal constant RELAYER = address(0x9E1A7);
    address internal constant YIELD_SINK = address(0x5217);

    uint256 internal constant NAV = 25.15e8; // USD, 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 200_000e6;

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal liquidity;

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
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), ADMIN
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), ADMIN
        );
        liquidity = new TreasuryLiquiditySource(usdc, ADMIN);

        vm.startPrank(ADMIN);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(HARVESTER);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        usdc.mint(RELAYER, 100_000e6);
        vm.prank(RELAYER);
        usdc.approve(address(auction), type(uint256).max);

        usdc.mint(HARVESTER, 100_000e6);
        vm.prank(HARVESTER);
        usdc.approve(address(credit), type(uint256).max);
    }

    // -- derivations, read live -------------------------------------------------

    function _maxLtvBps() internal view returns (uint256) {
        return riskParams.maxLtvBps();
    }

    function _maxBorrowOn(uint256 bonds) internal view returns (uint256) {
        return (bonds * NAV * _maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    /// @dev The NAV at which the whole lot is worth exactly the debt; half of it is the "crashed"
    ///      scenario, where even a 100%-of-NAV fill cannot cover the loan.
    function _crashedNavOn(uint256 bonds) internal view returns (uint256) {
        return ((_maxBorrowOn(bonds) * Config.USDC_TO_NAV_SCALE) / bonds) / 2;
    }

    function _seedBorrower(address who, uint256 bonds) internal {
        bond.mint(who, bonds);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    /// @dev Borrow at the ceiling under the healthy NAV, crash, liquidate, lapse, expire.
    ///      Every derivation is read BEFORE the prank.
    function _openWorkoutOn(address who, uint256 bonds) internal returns (uint256 id) {
        _seedBorrower(who, bonds);
        uint256 debt = _maxBorrowOn(bonds);
        uint256 crashed = _crashedNavOn(bonds);
        oracle.setNav(NAV);
        vm.prank(who);
        credit.borrow(debt);
        oracle.setNav(crashed);
        vm.prank(KEEPER);
        credit.liquidate(who);
        id = auction.auctionOf(who);
        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
    }

    function _openWorkout(address who) internal returns (uint256 id) {
        return _openWorkoutOn(who, BONDS);
    }

    function _runEpoch(uint256 amount) internal {
        vm.startPrank(HARVESTER);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
        vm.warp(block.timestamp + Config.YIELD_STREAM_DURATION + 1);
    }

    /// @dev Repay a workout's debt in full through the workout leg, so the close is clean. Exactly
    ///      the live debt, so no surplus appears and no penalty is charged, which keeps
    ///      `totalUnclaimedRewards` at zero and isolates the reserve arithmetic under test.
    function _repayWorkoutInFull(uint256 id, address who) internal returns (uint256 paid) {
        paid = credit.currentDebtOf(who);
        vm.prank(RELAYER);
        auction.workoutSettle(id, paid);
    }

    function _yieldOwed(uint256 id) internal view returns (uint256) {
        (,,,,,,,,,, uint256 owed) = auction.workouts(id);
        return owed;
    }

    /// @dev What a forced close socialised: the part of the residual no balance sheet was made
    ///      whole for. Added by round 55, item 215.
    function _writtenDown(uint256 id) internal view returns (uint256) {
        (,,,,,,, uint256 wd,,,) = auction.workouts(id);
        return wd;
    }

    function _bondCountOf(uint256 id) internal view returns (uint256) {
        (,,, uint256 n,,,,,,,) = auction.workouts(id);
        return n;
    }

    function _dump(string memory tag) internal view {
        console2.log(tag);
        console2.log("  auction usdc balance    ", usdc.balanceOf(address(auction)));
        console2.log("  totalUnclaimedRewards   ", auction.totalUnclaimedRewards());
        console2.log("  totalWorkoutYieldOwed   ", auction.totalWorkoutYieldOwed());
        console2.log("  claimableOf(auction)    ", credit.claimableOf(address(auction)));
        console2.log("  pendingYieldOf(auction) ", credit.pendingYieldOf(address(auction)));
        console2.log("  insuranceFund           ", credit.insuranceFund());
        console2.log("  openWorkoutCount        ", auction.openWorkoutCount());
    }

    // ==========================================================================
    // round-51 item 154 - the over-realisation door
    // ==========================================================================

    /// @notice CONTROL. Nobody sweeps: both borrowers are paid in full, even though A's claim
    ///         pulled the whole shared pot - B's half included - into the auction's raw balance.
    function test_R51_154_control_bothPaidWhenNobodySweeps() public {
        uint256 idA = _openWorkout(ALICE);
        uint256 idB = _openWorkout(BOB);
        assertEq(auction.openWorkoutCount(), 2, "two open workouts");

        _runEpoch(1_000e6);
        _repayWorkoutInFull(idA, ALICE);
        _repayWorkoutInFull(idB, BOB);

        auction.closeWorkout(idA);
        uint256 aliceBefore = usdc.balanceOf(ALICE);
        auction.claimWorkoutYield(idA);
        uint256 alicePaid = usdc.balanceOf(ALICE) - aliceBefore;
        _dump("[154 control] after claim A");

        auction.closeWorkout(idB);
        uint256 bobBefore = usdc.balanceOf(BOB);
        if (_yieldOwed(idB) != 0) auction.claimWorkoutYield(idB);
        uint256 bobPaid = usdc.balanceOf(BOB) - bobBefore;

        console2.log("[154 control] alice paid", alicePaid);
        console2.log("[154 control] bob paid  ", bobPaid);
        assertEq(alicePaid, 499_999_999, "A paid its own lot's share");
        assertEq(bobPaid, 499_999_999, "B paid its own lot's share");
    }

    /// @notice THE REGRESSION. RED on the shipped tree, GREEN with either reserve form.
    ///         A's own ordinary claim realises the whole shared pot; a stranger then sweeps B's
    ///         still-open backing into the insurance fund and B is paid nothing.
    function test_R51_154_regression_aStrangerCannotSweepAnOpenWorkoutsBacking() public {
        uint256 idA = _openWorkout(ALICE);
        uint256 idB = _openWorkout(BOB);
        _runEpoch(1_000e6);
        _repayWorkoutInFull(idA, ALICE);
        _repayWorkoutInFull(idB, BOB);

        auction.closeWorkout(idA);
        auction.claimWorkoutYield(idA);
        _dump("[154 regression] after claim A - B still OPEN");

        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(KEEPER);
        try auction.sweepFreeBalanceToInsurance() {
            console2.log("[154 regression] sweepFreeBalanceToInsurance SUCCEEDED, took",
                credit.insuranceFund() - insuranceBefore);
        } catch {
            console2.log("[154 regression] sweepFreeBalanceToInsurance reverted (the fix)");
        }
        _dump("[154 regression] after the stranger's sweep");

        auction.closeWorkout(idB);
        uint256 bobBefore = usdc.balanceOf(BOB);
        if (_yieldOwed(idB) != 0) {
            try auction.claimWorkoutYield(idB) {} catch {}
        }
        uint256 bobPaid = usdc.balanceOf(BOB) - bobBefore;
        console2.log("[154 regression] booked B", _yieldOwed(idB));
        console2.log("[154 regression] bob paid", bobPaid);

        // Shipped tree: 0. Either reserve form: 499999999, matching the control above.
        assertEq(bobPaid, 499_999_999, "an open workout's backing must survive a stranger's sweep");
    }

    /// @notice THE SECOND DOOR, with no claim in front of it. `sweepWorkoutYieldToInsurance` pulls
    ///         the whole claim itself and reserves only what is BOOKED, so it reaches an open
    ///         workout's backing directly. A fix on one door alone leaves this one standing.
    function test_R51_154_regression_theSiblingSweepReachesItWithNoClaimInFront() public {
        uint256 idA = _openWorkout(ALICE);
        uint256 idB = _openWorkout(BOB);
        _runEpoch(1_000e6);
        _repayWorkoutInFull(idA, ALICE);
        _repayWorkoutInFull(idB, BOB);

        // A closes; B stays open. No claim runs at all.
        auction.closeWorkout(idA);
        _dump("[154 sibling] after close A, before the sweep");

        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(KEEPER);
        try auction.sweepWorkoutYieldToInsurance() {
            console2.log("[154 sibling] sweepWorkoutYieldToInsurance took",
                credit.insuranceFund() - insuranceBefore);
        } catch {
            console2.log("[154 sibling] sweepWorkoutYieldToInsurance reverted (the fix)");
        }
        _dump("[154 sibling] after the sweep");

        auction.closeWorkout(idB);
        uint256 bobBefore = usdc.balanceOf(BOB);
        if (_yieldOwed(idB) != 0) {
            try auction.claimWorkoutYield(idB) {} catch {}
        }
        uint256 bobPaid = usdc.balanceOf(BOB) - bobBefore;
        console2.log("[154 sibling] booked B", _yieldOwed(idB));
        console2.log("[154 sibling] bob paid", bobPaid);

        assertEq(bobPaid, 499_999_999, "the sibling sweep must not reach an open workout's backing");
    }

    /// @notice The double-reservation question the fix raises: with the reserve in front of
    ///         `claimWorkoutYield`, does a closed workout's own claim get under-paid and stranded
    ///         while the sibling is still open? EXECUTED on whatever source state is compiled.
    ///         Records the numbers rather than asserting a shipped-tree figure.
    function test_R51_154_doubleReservation_theClaimConvergesOnceTheSiblingCloses() public {
        uint256 idA = _openWorkout(ALICE);
        uint256 idB = _openWorkout(BOB);
        _runEpoch(1_000e6);
        _repayWorkoutInFull(idA, ALICE);
        _repayWorkoutInFull(idB, BOB);

        auction.closeWorkout(idA);
        uint256 bookedA = _yieldOwed(idA);
        uint256 aliceBefore = usdc.balanceOf(ALICE);
        try auction.claimWorkoutYield(idA) {} catch {
            console2.log("[154 double] first claim A reverted");
        }
        uint256 firstPay = usdc.balanceOf(ALICE) - aliceBefore;
        console2.log("[154 double] booked A          ", bookedA);
        console2.log("[154 double] A paid first time ", firstPay);
        console2.log("[154 double] A still owed      ", _yieldOwed(idA));

        auction.closeWorkout(idB);
        uint256 bookedB = _yieldOwed(idB);
        console2.log("[154 double] booked B          ", bookedB);

        if (_yieldOwed(idA) != 0) {
            try auction.claimWorkoutYield(idA) {} catch {}
        }
        uint256 bobBefore = usdc.balanceOf(BOB);
        if (_yieldOwed(idB) != 0) {
            try auction.claimWorkoutYield(idB) {} catch {}
        }
        uint256 totalA = usdc.balanceOf(ALICE) - aliceBefore;
        uint256 totalB = usdc.balanceOf(BOB) - bobBefore;
        console2.log("[154 double] A paid in total   ", totalA);
        console2.log("[154 double] B paid in total   ", totalB);
        console2.log("[154 double] A residual owed   ", _yieldOwed(idA));
        console2.log("[154 double] B residual owed   ", _yieldOwed(idB));

        // Whatever the intermediate under-pay, nothing may be stranded once every sibling has
        // closed: both borrowers end whole and the aggregate counter is spent to zero.
        assertEq(totalA, 499_999_999, "A whole after the sibling closes");
        assertEq(totalB, 499_999_999, "B whole after the sibling closes");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "aggregate counter spent exactly");
    }

    /// @notice The reserve is a DEFERRAL, not a diversion. A workout that ends in a real default
    ///         books nothing, leaves the open queue, and its lot's yield reaches the insurance fund
    ///         exactly as round 22 finding 18 intends - just after the outcome is known rather than
    ///         racing it. PASSES on the shipped tree and under both reserve forms.
    /// @dev 🟥 **RE-FIXTURED BY ROUND 55, ITEM 215, AND STRENGTHENED TO WHAT ITS OWN DOCSTRING
    ///      ALWAYS CLAIMED.** As it stood it swept AFTER the close and asserted only `gained > 0`,
    ///      which the round-54 audit classified by assertion: the docstring says "the default's own
    ///      collateral must still pay the FUND DOWN", and paying the fund down after the fund has
    ///      been asked for this default and found empty is not that. It was green while every
    ///      forced close socialised the whole residual and banked the lot's yield against somebody
    ///      else's default. The snapshot has moved above the close, so the same money is measured
    ///      where it now moves, and the assertion is extended to what the write-down actually
    ///      socialised - the half that was missing.
    function test_R51_154_aForcedCloseStillGivesTheYieldToInsurance() public {
        uint256 id = _openWorkout(ALICE);
        _runEpoch(1_000e6);

        // No repayment: the debt stands, so the close is FORCED and writes the residual down.
        vm.warp(block.timestamp + Config.WORKOUT_MAX_DURATION + 1);
        uint256 residual = credit.currentDebtOf(ALICE);
        uint256 insuranceBefore = credit.insuranceFund();
        uint256 principalBefore = credit.pendingPrincipal();
        assertGt(residual, 0, "premise: this close is not forced");

        auction.closeWorkout(id);
        assertEq(_yieldOwed(id), 0, "a forced close books the borrower nothing");
        assertEq(auction.openWorkoutCount(), 0, "and it leaves the open queue");

        uint256 keptInFund = credit.insuranceFund() - insuranceBefore;
        uint256 spentOnThisDefault = credit.pendingPrincipal() - principalBefore;
        console2.log("[154 forced] insurance kept at the close   ", keptInFund);
        console2.log("[154 forced] spent on this default at close", spentOnThisDefault);
        console2.log("[154 forced] residual socialised           ", _writtenDown(id));
        assertGt(keptInFund + spentOnThisDefault, 0, "the default's own collateral must still pay the fund down");
        // The half that was missing: it must pay THIS default down first, so the funder is short by
        // less than the whole residual.
        assertGt(spentOnThisDefault, 0, "the fund was asked for this default and found empty");
        assertEq(_writtenDown(id) + spentOnThisDefault, residual, "socialised plus covered is the residual");
        assertLt(_writtenDown(id), residual, "the whole residual was socialised anyway");
    }

    /// @notice A dust workout is openable, so `_openWorkouts` is growable by a party who is willing
    ///         to be liquidated - but not cheaply and not unilaterally. EXECUTED.
    function test_R51_154_canAStrangerGrowTheOpenWorkoutArrayOnDust() public {
        address dust = address(0xD005);
        uint256 id = _openWorkoutOn(dust, 1);
        console2.log("[154 dust] bondCount of the dust workout", _bondCountOf(id));
        console2.log("[154 dust] openWorkoutCount             ", auction.openWorkoutCount());
        assertEq(_bondCountOf(id), 1, "a one-bond workout opens");
        assertEq(auction.openWorkoutCount(), 1, "and it lands in the open array");

        // The gate: nobody can borrow into an immediately-liquidatable position. A fresh borrower
        // at the CRASHED NAV is refused by `borrow`'s own max-LTV check long before liquidation.
        address late = address(0xD006);
        _seedBorrower(late, 1);
        uint256 want = _maxBorrowOn(1); // priced at the healthy NAV, deliberately
        vm.prank(late);
        vm.expectRevert();
        credit.borrow(want);
        console2.log("[154 dust] a fresh borrow at the crashed NAV is refused");
    }

    // -- gas probes -------------------------------------------------------------

    /// @dev Opens `n` dust-free workouts, streams one epoch, donates enough USDC that the sweep
    ///      succeeds under every source state, and measures `sweepFreeBalanceToInsurance`.
    function _sweepGasAt(uint256 n) internal returns (uint256 used) {
        for (uint256 i = 0; i < n; ++i) {
            _openWorkout(address(uint160(0x100000 + i)));
        }
        assertEq(auction.openWorkoutCount(), n, "n open workouts");
        _runEpoch(1_000e6);

        // A donation well above any reserve either form computes, so the sweep succeeds in all
        // three source states and the gas figures are comparable.
        usdc.mint(address(auction), 5_000e6);

        vm.prank(KEEPER);
        uint256 before = gasleft();
        auction.sweepFreeBalanceToInsurance();
        used = before - gasleft();
    }

    function test_R51_154_gas_sweepAt1OpenWorkout() public {
        console2.log("[154 gas] sweepFreeBalanceToInsurance, 1 open workout ", _sweepGasAt(1));
    }

    function test_R51_154_gas_sweepAt5OpenWorkouts() public {
        console2.log("[154 gas] sweepFreeBalanceToInsurance, 5 open workouts", _sweepGasAt(5));
    }

    function test_R51_154_gas_sweepAt20OpenWorkouts() public {
        console2.log("[154 gas] sweepFreeBalanceToInsurance, 20 open workouts", _sweepGasAt(20));
    }

    // ==========================================================================
    // round-51 item 155 - the dead `swept == 0` refusal and its shared selector
    // ==========================================================================

    /// @notice The two refusals `sweepWorkoutYieldToInsurance` can raise must be TELLABLE APART.
    ///         RED at `5a3fc90`, where both carry `0x969bf728` and a caller cannot tell "the live
    ///         manager owed nothing" - retry after an epoch - from "everything here is spoken for"
    ///         - retry after a close. GREEN with round-51 item 155's distinct error.
    /// @dev MEASURED on the shipped tree: both `0x969bf728`. Note that "spoken for" is raised by
    ///      this contract and "the manager owes nothing" is raised by `CreditManager._claimSurplus`
    ///      one frame down through a BARE call, so the collision is between two different
    ///      contracts' identically-named errors and no grep of either file finds it.
    function test_R51_155_theTwoRefusalsMustBeTellableApart() public {
        uint256 idA = _openWorkout(ALICE);
        _runEpoch(1_000e6);

        // State 1: the manager owes the auction nothing yet is not the case here, so provoke the
        // OTHER refusal first - everything realisable is spoken for by a booked workout.
        _repayWorkoutInFull(idA, ALICE);
        auction.closeWorkout(idA);
        bytes4 spokenForSelector;
        vm.prank(KEEPER);
        try auction.sweepWorkoutYieldToInsurance() {
            revert("expected a refusal");
        } catch (bytes memory reason) {
            spokenForSelector = bytes4(reason);
        }

        // State 2: drain the claim, then ask again - now the manager genuinely owes nothing.
        auction.claimWorkoutYield(idA);
        bytes4 nothingToClaimSelector;
        vm.prank(KEEPER);
        try auction.sweepWorkoutYieldToInsurance() {
            revert("expected a refusal");
        } catch (bytes memory reason) {
            nothingToClaimSelector = bytes4(reason);
        }

        console2.log("[155] 'everything is spoken for' selector");
        console2.logBytes4(spokenForSelector);
        console2.log("[155] 'the manager owes nothing' selector");
        console2.logBytes4(nothingToClaimSelector);
        assertTrue(
            spokenForSelector != nothingToClaimSelector,
            "the two refusals must not share a selector"
        );
    }

    /// @notice The `swept == 0` clause cannot be reached through a USDC that fails silently: the
    ///         auction's own `claimSurplus` call goes through `SafeERC20`, so a `transfer` returning
    ///         false reverts inside the manager rather than arriving here as a zero delta.
    function test_R51_155_theSweptZeroRefusalIsNotReachedBySilentTransferFailure() public {
        uint256 idA = _openWorkout(ALICE);
        _runEpoch(1_000e6);
        _repayWorkoutInFull(idA, ALICE);
        auction.closeWorkout(idA);

        usdc.setSilentlyFails(address(auction), true);
        vm.prank(KEEPER);
        try auction.sweepWorkoutYieldToInsurance() {
            revert("expected a refusal");
        } catch (bytes memory reason) {
            console2.log("[155] refusal selector under a silently failing transfer");
            console2.logBytes4(bytes4(reason));
            // NOT `NothingToClaim`: `SafeERC20FailedOperation` from inside the manager.
            assertTrue(bytes4(reason) != bytes4(keccak256("NothingToClaim()")), "not the dead clause");
        }
        usdc.setSilentlyFails(address(auction), false);
    }
}
