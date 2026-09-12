// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {RiskParams} from "../src/RiskParams.sol";
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

/// @title R51A05 - the mid-workout strip PAID the caller, and this is the file that closes it
/// @notice Audit round 51. Self-contained: deploys its own stack, inherits nothing.
///
/// @dev The repository records the mid-workout strip as a hazard a stranger can perform "for the
///      price of one transaction", which reads as griefing - a cost to the attacker and a loss to
///      the borrower with no beneficiary who can act on it. This file measures the other half.
///
///      `fundInsurance` calls `_pushLossReserves`, which writes `LenderPool.insuranceCover`, and
///      `exitReserve()` is `max(totalImpairment - insuranceCover, 0)` clamped to
///      `outstandingPrincipal`. An OPEN workout marks the borrower's whole live debt, so the
///      reserve is live for exactly as long as the strip is available. Moving the workout lot's
///      yield into insurance therefore RAISES every lender's redemption price, and the lender can
///      make that move themselves.
contract R51A05_StripPaysTheLender is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal lender = makeAddr("lender");
    address internal keeper = makeAddr("keeper");
    address internal rescuer = makeAddr("rescuer");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    LenderPool internal pool;
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
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(harvester);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _maxBorrow(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return (bonds * nav * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    function _openWorkout() internal returns (uint256 id) {
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(alice);
        credit.borrow(debt);

        oracle.setNav((debt * Config.USDC_TO_NAV_SCALE) / BONDS / 2);

        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: no auction opened");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(alice), 1, "fixture: no workout opened");
    }

    function _streamEpoch(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION + 1);
        credit.accrueYield();
    }

    function _rescueDebt() internal {
        uint256 owed = credit.currentDebtOf(alice);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    /// @notice **FINDING.** The lender is paid for stripping the workout lot's yield. Two calls,
    ///         both permissionless, neither of which is `sweepWorkoutYieldToInsurance`.
    /// @dev **FLIPPED by round-51 item 154's fix, and the flip is the whole point of the file.**
    ///      Before it, this test MEASURED the lender's redemption price moving 19,371.25 to
    ///      20,000.00 - a gain of 628.75 USDC - against 999.999999 the borrower lost, with the
    ///      lender able to make the move themselves in two permissionless transactions and no
    ///      capital. That is what turned "a stranger can grief a borrower for the price of one
    ///      transaction" into a beneficiary with a reason to act.
    ///
    ///      The fix reserves what still-OPEN workouts have earned in BOTH sweeps, so door two is
    ///      refused, the reserve is never lifted and the lender gains NOTHING. The exit value is
    ///      asserted unchanged to the wei, which is the assertion that would go red if the reserve
    ///      were ever relaxed.
    function test_R51A05_theLenderIsPaidNothingForTryingToStripAnOpenWorkoutsYield() public {
        uint256 id = _openWorkout();
        _streamEpoch(EPOCH);

        uint256 shares = pool.balanceOf(lender);
        uint256 before = pool.previewRedeem(shares);
        emit log_named_uint("MEASURED lender exit value before the attempt", before);
        emit log_named_uint("MEASURED exitReserve before", pool.exitReserve());
        assertGt(pool.exitReserve(), 0, "fixture: the open workout is not marked, there would be nothing to gain");

        // The lender tries it themselves. No role, no capital, two transactions. Door one still
        // opens; door two is refused, because the open workout's accrual is reserved.
        vm.prank(lender);
        credit.claimSurplusFor(address(auction));
        vm.prank(lender);
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepFreeBalanceToInsurance();

        uint256 afterAttempt = pool.previewRedeem(shares);
        emit log_named_uint("MEASURED lender exit value after the attempt", afterAttempt);
        emit log_named_uint("MEASURED exitReserve after ", pool.exitReserve());
        assertEq(afterAttempt, before, "the refused strip still paid the lender");

        // And the borrower's clean close books the whole lot accrual, which is where it went.
        _rescueDebt();
        auction.closeWorkout(id);
        uint256 booked = _yieldOwed(id);
        emit log_named_uint("MEASURED booked to the borrower", booked);
        assertGt(booked, 0, "the borrower was still stripped");

        uint256 paidBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - paidBefore, booked, "the borrower was not paid in full");
    }

    /// @notice CONTROL. Nobody strips: the lender's exit value is unchanged by the workout's yield
    ///         and the borrower is booked the whole lot accrual.
    function test_R51A05_control_withoutTheStripTheLenderGainsNothingAndTheBorrowerKeepsIt() public {
        uint256 id = _openWorkout();
        _streamEpoch(EPOCH);

        uint256 shares = pool.balanceOf(lender);
        uint256 before = pool.previewRedeem(shares);

        // Nothing done at the instant the strip was available: the exit value does not move.
        assertEq(pool.previewRedeem(shares), before, "control: the exit value moved on its own");

        _rescueDebt();
        auction.closeWorkout(id);
        uint256 booked = _yieldOwed(id);
        emit log_named_uint("CONTROL booked to the borrower", booked);
        assertGt(booked, 0, "control: the close booked nothing");

        emit log_named_uint("CONTROL lender exit value before", before);
        emit log_named_uint("CONTROL lender exit value after ", pool.previewRedeem(shares));

        uint256 paidBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - paidBefore, booked, "control: the borrower was not paid");
    }
}
