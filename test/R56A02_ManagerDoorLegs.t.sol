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

/// @notice A REAL `CreditManager` minus exactly one member. Every call delegates to a byte copy of
///         the genuine manager's runtime (immutables included), in this address's storage, with
///         `msg.sender` preserved - except `removed`, which reverts with EMPTY returndata, the exact
///         shape of a stub that does not carry the member. Internal immutables only, so the proxy
///         adds no selector of its own. With `swallow_` set (round-56 wave), `removed` instead
///         SUCCEEDS silently with one zero word: the shape of a stub whose fallback answers every
///         selector, which the door's non-view shape probe must refuse as well.
contract MinusOneManager {
    address internal immutable _impl;
    bytes4 internal immutable _removed;
    bool internal immutable _swallow;

    constructor(address impl_, bytes4 removed_, bool swallow_) {
        _impl = impl_;
        _removed = removed_;
        _swallow = swallow_;
    }

    fallback() external payable {
        if (msg.sig == _removed) {
            if (_swallow) {
                assembly {
                    mstore(0, 0)
                    return(0, 32)
                }
            }
            revert();
        }
        address impl = _impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @title R56A02 - round-56 item 236: which unprobed members of the auction's manager door strand work
/// @notice Audit round 56, agent A2. The door (`LiquidationAuction.setCreditManager`) probed four
///         members since #491. For each member the row names, plus two it does not (`debtOf`,
///         `accYieldPerBond`), this file installs a genuine manager MINUS THAT ONE MEMBER through
///         BOTH doors and drives the lifecycle into the path that calls it.
///
/// @dev **The four STRAND members are probed on the door since the round-56 wave, and their cases
///      are `fix_` cases.** At `8ab4d88` the door ADMITTED a manager missing `writeDownLoss`,
///      `claimableOf`, `pendingYieldOf` or `accYieldPerBond`, and the exit that reads it then
///      reverted EMPTY with `liveAuctionCount` or `openWorkoutCount` welding every wiring door (each
///      case's docstring keeps the strand as A2 measured it). Under the probe the door refuses each
///      by name, `CreditManagerDoesNotAnswer(selector)`, before any work can exist; the `fix_` cases
///      are red at `8ab4d88` and green under the probe (LiquidationAuction +369 runtime / +369
///      initcode on a clean `out/`, CreditManager byte-identical).
///
///      🟥 **The `degrade_` and `cosmetic_` tests still PIN AN OPEN STATE, deliberately and by
///      decision (2026-09-10): those members are NOT probed.** The `degrade_` members (`repayFor`,
///      `creditLiquidationProceeds`, `fundInsurance`, `debtOf`) cost a path when absent but strand
///      nothing, because another exit still ends the work, so the door still admits a manager
///      missing one of them. The `cosmetic_` test is the three pointer legs, whose absence the door
///      already refuses, only with empty returndata. A probe of any of them must turn its case red,
///      and a green run of this file is not a clearance.
contract R56A02_ManagerDoorLegs is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal rescuer = makeAddr("rescuer");
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
    /// @dev When set, the planted proxy answers `removed` with a silent success instead of an empty
    ///      revert (see `MinusOneManager`).
    bool internal swallowRemoved;

    function _build(bytes4 removed) internal returns (bool doorAdmitted, bytes memory doorRet) {
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

        // The genuine manager's runtime, copied aside; the manager's own address becomes a
        // delegating proxy that lacks exactly `removed`. Storage (owner, pointers) stays in place.
        if (removed != bytes4(0)) {
            address implCopy = makeAddr("impl-copy");
            vm.etch(implCopy, address(credit).code);
            MinusOneManager proxy = new MinusOneManager(implCopy, removed, swallowRemoved);
            vm.etch(address(credit), address(proxy).code);
        }

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        (doorAdmitted, doorRet) = address(auction).call(abi.encodeCall(auction.setCreditManager, (address(credit))));
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

    function _openAuction() internal returns (uint256 id) {
        uint256 debt = (BONDS * NAV * Config.DEFAULT_MAX_LTV_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        id = _openAuctionAt(((debt * Config.USDC_TO_NAV_SCALE) / BONDS) / 2);
    }

    /// @dev Open at a chosen crash NAV. 11.64e8 is 54% LTV: liquidatable, and a fill covers debt plus
    ///      penalty, so the proceeds leg is reached.
    function _openAuctionAt(uint256 crashNav) internal returns (uint256 id) {
        uint256 debt = (BONDS * NAV * Config.DEFAULT_MAX_LTV_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(crashNav);
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        require(id != 0, "fixture: no auction");
    }

    function _stream(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION);
    }

    function _rescue() internal {
        uint256 owed = credit.debtOf(alice);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();
    }

    function _assertDoorAdmitted(bool admitted, bytes memory ret, bytes4 member) internal {
        emit log_named_bytes("door returndata (empty = admitted)", ret);
        assertTrue(
            admitted,
            string.concat("door: the auction's manager door refused a manager lacking ", vm.toString(abi.encodePacked(member)))
        );
    }

    /// @dev The round-56 shipped shape: the door refuses the stub BY NAME, naming the missing
    ///      selector, and the auction's pointer never moves, so no auction can be opened through it
    ///      and nothing exists to weld.
    function _assertDoorRefusedByName(bool admitted, bytes memory ret, bytes4 member) internal view {
        assertFalse(
            admitted,
            string.concat("door: the auction's manager door ADMITTED a manager lacking ", vm.toString(abi.encodePacked(member)))
        );
        assertEq(
            ret,
            abi.encodeWithSelector(LiquidationAuction.CreditManagerDoesNotAnswer.selector, member),
            "door: refused, but not by CreditManagerDoesNotAnswer(member)"
        );
        assertEq(auction.creditManager(), address(0), "door: the auction's pointer moved");
    }

    // ── FIX: the absence USED to weld live work; the door now refuses it ─────

    /// @notice FIX (the row's named case). No `writeDownLoss`: refused at the door by name. At
    ///         `8ab4d88` the door admitted it, an auction expired to a workout, and the FORCED close at
    ///         14 days reverted EMPTY for good; the work could end only if a third party repaid the
    ///         whole defaulted debt (making the close clean), and `AuctionHasLiveWork(1)` welded both
    ///         wiring doors meanwhile.
    function test_R56A02_236_fix_withoutWriteDownLossTheDoorRefusesByName() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.writeDownLoss.selector);
        _assertDoorRefusedByName(ok, ret, ICreditManager.writeDownLoss.selector);
    }

    /// @notice FIX, the other arm of the same shape probe: a manager whose `writeDownLoss` SUCCEEDS
    ///         silently (a fallback that answers every selector) is refused by name too, because the
    ///         genuine manager never succeeds on the probe's zero amount. At `8ab4d88` it installed.
    function test_R56A02_236_fix_aWriteDownLossThatSucceedsSilentlyIsRefusedByName() public {
        swallowRemoved = true;
        (bool ok, bytes memory ret) = _build(ICreditManager.writeDownLoss.selector);
        _assertDoorRefusedByName(ok, ret, ICreditManager.writeDownLoss.selector);
    }

    /// @notice FIX (OFF the row's list of six as a strand, and the worst of them): no `claimableOf`,
    ///         refused at the door by name. At `8ab4d88`, once any yield had accrued to the lot and
    ///         anybody - a permissionless `repayFor` sufficed - cleared the debt, the close was CLEAN
    ///         (`residual == 0`), the clean branch read `claimableOf` bare and reverted EMPTY, and the
    ///         forced branch was unreachable because there was no residual: a PERMANENT weld a
    ///         stranger could cause.
    function test_R56A02_236_fix_withoutClaimableOfTheDoorRefusesByName() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.claimableOf.selector);
        _assertDoorRefusedByName(ok, ret, ICreditManager.claimableOf.selector);
    }

    /// @notice FIX, the twin of the above through the other bare view on the same line: no
    ///         `pendingYieldOf`, refused at the door by name. At `8ab4d88` the same weld.
    function test_R56A02_236_fix_withoutPendingYieldOfTheDoorRefusesByName() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.pendingYieldOf.selector);
        _assertDoorRefusedByName(ok, ret, ICreditManager.pendingYieldOf.selector);
    }

    /// @notice FIX (OFF the row's list entirely): no `accYieldPerBond`, refused at the door by name.
    ///         At `8ab4d88` `expireToWorkout` read it bare after `reassign`, so an unfilled, unhealed
    ///         auction could never expire; once the 48-hour re-strike window closed `liquidate`
    ///         refused too and `liveAuctionCount` stayed 1.
    function test_R56A02_236_fix_withoutAccYieldPerBondTheDoorRefusesByName() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.accYieldPerBond.selector);
        _assertDoorRefusedByName(ok, ret, ICreditManager.accYieldPerBond.selector);
    }

    // ── DEGRADE: a path is lost, another exit still ends the work ────────────
    //
    // These four members are DELIBERATELY UNPROBED by decision (2026-09-10): their absence loses a
    // path but strands nothing, so the door still admits a manager missing one of them and these
    // cases still pin that it does.

    /// @notice DEGRADE. No `repayFor`: every bid reverts (the fill repays through it), but the
    ///         auction expires to a workout and the forced close ends it. Nothing stranded.
    function test_R56A02_236_degrade_withoutRepayForNoFillButTheForcedCloseEndsIt() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.repayFor.selector);
        _assertDoorAdmitted(ok, ret, ICreditManager.repayFor.selector);
        uint256 id = _openAuction();
        usdc.mint(bidder, 10_000e6);
        vm.startPrank(bidder);
        usdc.approve(address(auction), type(uint256).max);
        vm.expectRevert(bytes(""));
        auction.bid(id, type(uint256).max);
        vm.stopPrank();
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(id);
        assertEq(auction.openWorkoutCount(), 0, "the forced close did not end it");
        assertEq(auction.liveAuctionCount(), 0, "live work left");
    }

    /// @notice DEGRADE. No `creditLiquidationProceeds`: a fill with a surplus reverts, the lot
    ///         expires to a workout and the forced close ends it. Nothing stranded.
    function test_R56A02_236_degrade_withoutCreditLiquidationProceedsTheForcedCloseEndsIt() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.creditLiquidationProceeds.selector);
        _assertDoorAdmitted(ok, ret, ICreditManager.creditLiquidationProceeds.selector);
        uint256 id = _openAuctionAt(11.64e8);
        usdc.mint(bidder, 10_000e6);
        vm.startPrank(bidder);
        usdc.approve(address(auction), type(uint256).max);
        vm.expectRevert(bytes(""));
        auction.bid(id, type(uint256).max);
        vm.stopPrank();
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(id);
        assertEq(auction.openWorkoutCount(), 0, "the forced close did not end it");
    }

    /// @notice DEGRADE. No `fundInsurance`: both sweeps revert, but the forced close CATCHES its
    ///         funding leg (`try this.fundInsuranceWithFree`) and still ends the workout.
    function test_R56A02_236_degrade_withoutFundInsuranceOnlyTheSweepsAreLost() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.fundInsurance.selector);
        _assertDoorAdmitted(ok, ret, ICreditManager.fundInsurance.selector);
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        _stream(1_000e6);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(id);
        assertEq(auction.openWorkoutCount(), 0, "the forced close did not end it");
        usdc.mint(address(auction), 5e6);
        vm.expectRevert(bytes(""));
        auction.sweepFreeBalanceToInsurance();
    }

    /// @notice DEGRADE (OFF the row's list). No `debtOf`: `start` reads it bare, so the manager's own
    ///         `liquidate` reverts and no auction ever opens. Nothing is stranded on the auction; the
    ///         cost is that the position cannot be liquidated at all.
    function test_R56A02_236_degrade_withoutDebtOfNothingOpens() public {
        (bool ok, bytes memory ret) = _build(ICreditManager.debtOf.selector);
        _assertDoorAdmitted(ok, ret, ICreditManager.debtOf.selector);
        uint256 debt = (BONDS * NAV * Config.DEFAULT_MAX_LTV_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(((debt * Config.USDC_TO_NAV_SCALE) / BONDS) / 2);
        vm.prank(keeper);
        vm.expectRevert();
        credit.liquidate(alice);
        assertEq(auction.liveAuctionCount(), 0, "an auction opened");
    }

    // ── COSMETIC: the door already refuses, only unnamed ─────────────────────
    //
    // The three pointer legs are DELIBERATELY UNPROBED by decision (2026-09-10): the door already
    // refuses a manager missing one of them, so naming it would buy the operator a better message
    // and nothing else.

    /// @notice COSMETIC. The three pointer legs ahead of the probes: a manager without `vault()`,
    ///         `riskParams()` or `navOracle()` is REFUSED by the door already - with EMPTY returndata
    ///         at the base, so the operator is told nothing. Nothing installs, nothing strands.
    function test_R56A02_236_cosmetic_thePointerLegsRefuseButEmpty() public {
        bytes4[3] memory legs =
            [ICreditManager.vault.selector, ICreditManager.riskParams.selector, ICreditManager.navOracle.selector];
        for (uint256 i = 0; i < 3; i++) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _buildDoorOnly(legs[i]);
            assertFalse(ok, "a manager without a pointer leg installed");
            emit log_named_bytes("MEASURED door returndata", ret);
            assertEq(ret.length, 0, "PINS-OPEN: the pointer-leg refusal is now named, flip this pin");
            vm.revertToState(snap);
        }
    }

    /// @dev The door alone, for a member the vault's own door ALSO reads (so the stub is planted
    ///      after the vault door and before the auction's).
    function _buildDoorOnly(bytes4 removed) internal returns (bool ok, bytes memory ret) {
        _build(bytes4(0));
        address implCopy = makeAddr("impl-copy-2");
        vm.etch(implCopy, address(credit).code);
        MinusOneManager proxy = new MinusOneManager(implCopy, removed, false);
        vm.etch(address(credit), address(proxy).code);
        // Re-open the door: the fixture already installed the genuine manager, so move the
        // auction's pointer through the door again (the idempotent re-wire the setter admits).
        vm.prank(admin);
        (ok, ret) = address(auction).call(abi.encodeCall(auction.setCreditManager, (address(credit))));
    }

    /// @notice CONTROL. The genuine manager (no member removed) through the same fixture: every
    ///         path above completes.
    function test_R56A02_236_control_theGenuineManagerEndsEveryPath() public {
        (bool ok,) = _build(bytes4(0));
        assertTrue(ok, "control: the genuine manager was refused");
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        _stream(1_000e6);
        _rescue();
        auction.closeWorkout(id);
        assertEq(auction.openWorkoutCount(), 0, "control: the clean close did not end it");
    }
}
