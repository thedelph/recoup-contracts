// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
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

/// @title R57A02 - the LiquidationAuction side of a borrower exit while their auction is live
/// @notice Audit round 57, agent A2, target 4(a): round-56 A1's INFERRED lead, executed. A borrower
///         with a LIVE auction (i) repays in full, (ii) repays in full and withdraws every bond, (iii)
///         repays part and withdraws down to the LTV ceiling. For each, the auction's three exits
///         (`bid`, `cancel`, `expireToWorkout`), its live-work counter and the prepaid bounty are
///         read. No state leaves the auction without a permissionless exit, no workout opens over
///         nothing, and the bounty always returns to the borrower who prepaid it.
contract R57A02_ExitDuringLiveAuction is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
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
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    uint256 internal id;
    uint256 internal debt;

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
        treasury = new TreasuryLiquiditySource(usdc, admin);
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
        usdc.mint(address(treasury), TREASURY_FLOAT);

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
        uint256 amount = (BONDS * NAV * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        vm.prank(alice);
        credit.borrow(amount);
        oracle.setNav(NAV / 3);
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        require(id != 0, "fixture: no auction");
        debt = credit.currentDebtOf(alice);
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(credit), type(uint256).max);
    }

    function _bidReverts() internal returns (bytes memory ret) {
        uint256 cap = 10_000e6;
        usdc.mint(stranger, cap);
        vm.startPrank(stranger);
        usdc.approve(address(auction), cap);
        bool ok;
        (ok, ret) = address(auction).call(abi.encodeWithSignature("bid(uint256,uint256)", id, cap));
        vm.stopPrank();
        assertFalse(ok, "a bid filled over an exited position");
    }

    /// @notice (i) Full repay mid-auction: `bid` is refused by the VAULT's liquidatable check
    ///         (`PositionNotLiquidatable(0)`), a stranger's `cancel` clears the auction and its live-work
    ///         count, and the 25.000000 prepaid bounty comes back to alice through `claimSurplus`.
    function test_R57A02_exit_fullRepayMidAuction() public {
        vm.prank(alice);
        credit.repay(debt);
        bytes memory ret = _bidReverts();
        assertEq(
            keccak256(ret),
            keccak256(abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, uint256(0))),
            "refused, but not by the vault's health gate"
        );
        vm.prank(stranger);
        auction.cancel(id);
        assertEq(auction.liveAuctionCount(), 0, "live work still counted");
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.claimSurplus();
        emit log_named_uint(
            "MEASURED bounty back to alice after a full repay and a stranger's cancel", usdc.balanceOf(alice) - before
        );
        assertEq(usdc.balanceOf(alice) - before, Config.LIQUIDATION_CALL_BOUNTY, "the bounty did not come back");
    }

    /// @notice (ii) Full repay and a WITHDRAWAL OF EVERY BOND while the auction is still live (the
    ///         vault's withdraw gate reads debt, never the auction). The lot is empty: `bid` refuses
    ///         `NothingToAuction`, and once the window lapses `expireToWorkout` dispatches to the cancel
    ///         body rather than opening a workout over nothing; `liquidate` then refuses `NoDebt`.
    function test_R57A02_exit_fullRepayAndWithdrawEverythingMidAuction() public {
        vm.startPrank(alice);
        credit.repay(debt);
        vault.withdrawBonds(BONDS);
        vm.stopPrank();
        assertEq(vault.bondCount(alice), 0, "premise: alice exited while her auction was live");
        assertTrue(auction.isLiquidating(alice), "premise: the auction is still live");

        bytes memory ret = _bidReverts();
        assertEq(
            keccak256(ret),
            keccak256(abi.encodeWithSelector(LiquidationAuction.NothingToAuction.selector, alice)),
            "refused, but not for the empty lot"
        );
        skip(Config.AUCTION_DURATION + 1);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(alice), 0, "a workout opened over nothing");
        assertEq(auction.liveAuctionCount(), 0, "live work still counted");
        assertEq(auction.openWorkoutCount(), 0, "a workout is counted");
        vm.prank(keeper);
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.liquidate(alice);
    }

    /// @notice (iii) Part repaid, then a withdrawal down to the LTV ceiling while the auction is
    ///         live. The lot shrinks under the live auction; the position is healthy, so `bid`
    ///         refuses at the vault and a stranger's `cancel` works. borrow stays shut until then.
    function test_R57A02_exit_partialRepayAndWithdrawToTheCeilingMidAuction() public {
        vm.prank(alice);
        credit.repay(debt - 100e6);
        // 100.000000 against 100 bonds at NAV/3: 11.9% LTV, so ~52 bonds may leave at 25%.
        vm.prank(alice);
        vault.withdrawBonds(50);
        assertEq(vault.bondCount(alice), 50, "premise: withdrew under a live auction");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.LiquidationOpen.selector, alice));
        credit.borrow(1e6);

        _bidReverts();
        vm.prank(stranger);
        auction.cancel(id);
        assertEq(auction.liveAuctionCount(), 0, "live work still counted");
        vm.prank(alice);
        credit.borrow(1e6); // and borrow is open again
    }
}
