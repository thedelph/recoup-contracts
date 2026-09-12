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

/// @notice A token that burns `feeBps` of every transfer INTO `sink`, whoever sends it. The repo's own
///         round-34 premise (`R34AccountingIdentity.t.sol`): USDC sits behind a mutable proxy that
///         could start taking a fee.
contract R56FeeIntoSinkUSDC is MockUSDC {
    address public sink;
    uint256 public feeBps;

    function setFee(address sink_, uint256 bps) external {
        sink = sink_;
        feeBps = bps;
    }

    function transfer(address to, uint256 value) public override returns (bool ok) {
        ok = super.transfer(to, value);
        _charge(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool ok) {
        ok = super.transferFrom(from, to, value);
        _charge(to, value);
    }

    function _charge(address to, uint256 value) private {
        if (feeBps != 0 && to == sink) _burn(to, (value * feeBps) / 10_000);
    }
}

/// @title R56A02 - round-56 item 74: six inbound legs on `CreditManager` book the NOMINAL amount
/// @notice Audit round 56, agent A2. `CreditManager` is read-only this round, so nothing is fixed.
///
/// @dev 🟥 **PINS-OPEN. Every `pin_` test below pins an OPEN state and says so: a fix that makes a
///      leg book what ARRIVED must turn its pin red, and a green run of this file is not a
///      clearance.** Each pin measures, under a token delivering 1% short into the manager, the
///      counter the leg writes against the USDC that actually reached the manager, and asserts the
///      manager's USDC balance falls short of the sum of its own claim counters by exactly the fee.
///      The `control_` test is the leg that already measures: `borrow` refuses `LiquidityNotDelivered`
///      on the same token. Inert for USDC today; the severity is the round-55 row's LOW.
contract R56A02_NominalInboundLegs is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant FEE_BPS = 100;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    R56FeeIntoSinkUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    function setUp() public {
        usdc = new R56FeeIntoSinkUSDC();
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
        bond.setWhitelisted(bidder, true);
        usdc.mint(address(treasury), 100_000e6);
        _seat(alice);
        _seat(carol);
    }

    function _seat(address who) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @dev Everything the manager's own counters say it holds for somebody. `migrateReserves`'s
    ///      `spokenFor` plus the three terms it deliberately sweeps, i.e. the solvency invariant.
    function _claims() internal view returns (uint256) {
        return credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
            + credit.totalOwedToSources() + credit.insuranceFund() + credit.totalBountyEscrowed()
            + credit.totalBountyParked() + credit.totalBountyOwed();
    }

    function _gap() internal view returns (int256) {
        return int256(usdc.balanceOf(address(credit))) - int256(_claims());
    }

    function _feeOn() internal {
        usdc.setFee(address(credit), FEE_BPS);
    }

    function _report(string memory leg, uint256 booked, uint256 arrived, int256 gapBefore) internal {
        emit log_named_string("LEG", leg);
        emit log_named_uint("  MEASURED booked (counter delta)", booked);
        emit log_named_uint("  MEASURED arrived (balance delta)", arrived);
        emit log_named_int("  MEASURED solvency gap before", gapBefore);
        emit log_named_int("  MEASURED solvency gap after", _gap());
    }

    function _maxDebt() internal pure returns (uint256) {
        return (BONDS * NAV * Config.DEFAULT_MAX_LTV_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    // ── CONTROL: the leg that already measures ───────────────────────────────

    /// @notice CONTROL. `borrow` measures the source's delivery and refuses a short one by name.
    function test_R56A02_74_control_borrowRefusesAShortDelivery() public {
        _feeOn();
        uint256 amount = 400e6;
        uint256 short = amount - (amount * FEE_BPS) / 10_000;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.LiquidityNotDelivered.selector, amount, short));
        credit.borrow(amount);
    }

    // ── PINS-OPEN: the six nominal legs ──────────────────────────────────────

    /// @notice PIN (open). `receiveYield`: `undistributedYield += amount`, whatever arrived.
    function test_R56A02_74_pin_receiveYieldBooksNominal() public {
        _feeOn();
        uint256 amount = 1_000e6;
        usdc.mint(harvester, amount);
        int256 g0 = _gap();
        uint256 u0 = credit.undistributedYield();
        uint256 b0 = usdc.balanceOf(address(credit));
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        vm.stopPrank();
        uint256 booked = credit.undistributedYield() - u0;
        uint256 arrived = usdc.balanceOf(address(credit)) - b0;
        _report("receiveYield", booked, arrived, g0);
        assertEq(booked, amount, "the leg stopped booking nominal");
        assertEq(g0 - _gap(), int256(booked - arrived), "gap did not open by exactly the fee");
        assertGt(booked, arrived, "PINS-OPEN: the leg now books what arrived, flip this pin");
    }

    /// @notice PIN (open). `fundInsurance`, PERMISSIONLESS: `insuranceFund += amount`.
    function test_R56A02_74_pin_fundInsuranceBooksNominal() public {
        _feeOn();
        uint256 amount = 100e6;
        usdc.mint(stranger, amount);
        int256 g0 = _gap();
        uint256 i0 = credit.insuranceFund();
        uint256 b0 = usdc.balanceOf(address(credit));
        vm.startPrank(stranger);
        usdc.approve(address(credit), amount);
        credit.fundInsurance(amount);
        vm.stopPrank();
        uint256 booked = credit.insuranceFund() - i0;
        uint256 arrived = usdc.balanceOf(address(credit)) - b0;
        _report("fundInsurance", booked, arrived, g0);
        assertGt(booked, arrived, "PINS-OPEN: the leg now books what arrived, flip this pin");
        assertEq(g0 - _gap(), int256(booked - arrived), "gap did not open by exactly the fee");
    }

    /// @notice PIN (open). `fundBounty`: `bountyEscrowOf += amount`, and the escrow is later
    ///         refunded or paid in FULL out of other claimants' USDC.
    function test_R56A02_74_pin_fundBountyBooksNominal() public {
        vm.prank(carol);
        credit.borrow(400e6); // under MIN_BOUNTIED_DEBT, so no escrow was withheld
        _feeOn();
        uint256 amount = Config.LIQUIDATION_CALL_BOUNTY;
        usdc.mint(carol, amount);
        int256 g0 = _gap();
        uint256 e0 = credit.totalBountyEscrowed();
        uint256 b0 = usdc.balanceOf(address(credit));
        vm.startPrank(carol);
        usdc.approve(address(credit), amount);
        credit.fundBounty(carol, amount);
        vm.stopPrank();
        uint256 booked = credit.totalBountyEscrowed() - e0;
        uint256 arrived = usdc.balanceOf(address(credit)) - b0;
        _report("fundBounty", booked, arrived, g0);
        assertGt(booked, arrived, "PINS-OPEN: the leg now books what arrived, flip this pin");
        assertEq(g0 - _gap(), int256(booked - arrived), "gap did not open by exactly the fee");
    }

    /// @notice PIN (open). `_repay` (through `repay`): the debt falls and `pendingPrincipal` rises by
    ///         `paid`, while `paid - fee` arrived.
    function test_R56A02_74_pin_repayBooksNominal() public {
        vm.prank(carol);
        credit.borrow(400e6);
        _feeOn();
        uint256 amount = 100e6;
        usdc.mint(carol, amount);
        int256 g0 = _gap();
        uint256 p0 = credit.pendingPrincipal();
        uint256 b0 = usdc.balanceOf(address(credit));
        vm.startPrank(carol);
        usdc.approve(address(credit), amount);
        credit.repay(amount);
        vm.stopPrank();
        uint256 booked = credit.pendingPrincipal() - p0;
        uint256 arrived = usdc.balanceOf(address(credit)) - b0;
        _report("repay", booked, arrived, g0);
        assertGt(booked, arrived, "PINS-OPEN: the leg now books what arrived, flip this pin");
        assertEq(g0 - _gap(), int256(booked - arrived), "gap did not open by exactly the fee");
    }

    /// @notice PIN (open). `creditLiquidationProceeds` (and `repayFor`, the same fill): a fill with a
    ///         surplus pays the manager twice from the auction, both nominal. The auction's own
    ///         `delivered` measure (round 46) sees only the bidder's leg into the AUCTION; the hop
    ///         into the manager is charged again and booked whole. This is the leg whose split
    ///         (insurance's penalty cut against the borrower's surplus) needs a decision.
    function test_R56A02_74_pin_aFillBooksNominalProceeds() public {
        uint256 debt = _maxDebt();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(11.64e8); // 54% LTV: liquidatable, and a fill covers debt plus penalty
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        uint256 price = auction.currentPrice(id);
        usdc.mint(bidder, price);
        vm.prank(bidder);
        usdc.approve(address(auction), price);

        _feeOn();
        int256 g0 = _gap();
        uint256 ins0 = credit.insuranceFund();
        uint256 cl0 = credit.totalClaimable();
        uint256 pp0 = credit.pendingPrincipal();
        uint256 b0 = usdc.balanceOf(address(credit));
        vm.prank(bidder);
        auction.bid(id, BONDS, price);
        uint256 insurance = credit.insuranceFund() - ins0;
        uint256 surplus = credit.totalClaimable() - cl0;
        uint256 principal = credit.pendingPrincipal() - pp0;
        uint256 booked = insurance + surplus + principal;
        uint256 arrived = usdc.balanceOf(address(credit)) - b0;
        emit log_named_uint("  MEASURED insurance leg booked", insurance);
        emit log_named_uint("  MEASURED borrower surplus booked", surplus);
        emit log_named_uint("  MEASURED principal (repayFor) booked", principal);
        _report("fill: repayFor + creditLiquidationProceeds", booked, arrived, g0);
        assertGt(booked, arrived, "PINS-OPEN: the fill now books what arrived, flip this pin");
        assertEq(g0 - _gap(), int256(booked - arrived), "gap did not open by exactly the fees");
    }

    /// @notice PIN (open). `recoverWrittenDownLoss`: a late tranche after a forced close books
    ///         `pendingPrincipal += amount` (treasury-funded book) while `amount - fee` arrived. The
    ///         auction's side measures `received` and spends `w.writtenDown` by it; the manager hop
    ///         is charged a second time and booked whole.
    function test_R56A02_74_pin_aLateTrancheBooksNominal() public {
        uint256 debt = _maxDebt();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(((debt * Config.USDC_TO_NAV_SCALE) / BONDS) / 2);
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(id);
        (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
        assertGt(writtenDown, 0, "fixture: nothing written down");

        _feeOn();
        uint256 tranche = writtenDown / 2;
        usdc.mint(relayer, tranche);
        vm.prank(relayer);
        usdc.approve(address(auction), tranche);
        int256 g0 = _gap();
        uint256 pp0 = credit.pendingPrincipal();
        uint256 os0 = credit.totalOwedToSources();
        uint256 b0 = usdc.balanceOf(address(credit));
        vm.prank(relayer);
        auction.workoutSettleAfterClose(id, tranche);
        uint256 booked = (credit.pendingPrincipal() - pp0) + (credit.totalOwedToSources() - os0);
        uint256 arrived = usdc.balanceOf(address(credit)) - b0;
        _report("recoverWrittenDownLoss", booked, arrived, g0);
        assertGt(booked, arrived, "PINS-OPEN: the leg now books what arrived, flip this pin");
        assertEq(g0 - _gap(), int256(booked - arrived), "gap did not open by exactly the fee");
    }
}
