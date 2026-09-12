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

/// @title R56A02 - round-56 item 235: is `claimSurplusFor(auction)` on every detached bearer enough?
/// @notice Audit round 56, agent A2. Self-contained (the real `LenderPool` as source and loss sink on
///         each era, copied rather than inherited so no fixture suite rides along).
///
///         THE ROW: with two clean-close bookings on two bearers (A on the detached M1, B on the
///         live M2), `claimWorkoutYield(B)` pays B short while A's backing sits unpulled on M1, and
///         the zero-byte answer is the runbook line "`claimSurplusFor(auction)` on every detached
///         bearer before the later claimant is told to wait".
///
///         MEASURED here: the line is SUFFICIENT in every order executed, with two refinements the
///         runbook should carry - (1) a `NothingToClaim` from the detached bearer means its backing
///         is ALREADY here, not that the step failed, and B is payable in that order without it;
///         and (2) the runbook is not the only unwinder: A's own `claimWorkoutYield` pulls its
///         bearer (`bearer != cm`) and unwinds B too. It must be run on EVERY detached bearer: with
///         three eras, pulling only the first leaves B short by the second's booking.
contract R56A02_DetachedBearerRunbook is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal lender = makeAddr("lender");
    address internal keeper = makeAddr("keeper");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal m1;
    LiquidationAuction internal auction;
    LenderPool internal pool;
    RiskParams internal riskParams;

    uint256 internal eraNonce;

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
        m1 = _freshManager();
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(m1));
        vault.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(m1));
        pool.setEpochHarvester(harvester);
        m1.setLiquiditySource(address(pool));
        m1.setLenderPool(address(pool));
        m1.setEpochHarvester(harvester);
        m1.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(m1));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        _seat(alice);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _freshManager() internal returns (CreditManager) {
        return new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
    }

    function _seat(address who) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _debt() internal view returns (uint256) {
        return (BONDS * NAV * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    /// @dev Borrow, crash, liquidate, expire, stream `epoch` over the workout, repay in full through
    ///      the auction's tranche door, close clean, dispose the lot. Returns the booked id.
    function _bookCleanClose(address who, CreditManager cm, uint256 epoch) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = _debt();
        vm.prank(who);
        cm.borrow(debt);
        oracle.setNav(((debt * Config.USDC_TO_NAV_SCALE) / BONDS) / 2);
        vm.prank(keeper);
        cm.liquidate(who);
        id = auction.auctionOf(who);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        usdc.mint(harvester, epoch);
        vm.startPrank(harvester);
        usdc.approve(address(cm), epoch);
        cm.receiveYield(epoch);
        cm.distributeYield(epoch);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION);
        cm.accrueYield();

        uint256 payment = cm.currentDebtOf(who) * 2;
        usdc.mint(payer, payment);
        vm.startPrank(payer);
        usdc.approve(address(auction), payment);
        auction.workoutSettle(id, payment);
        vm.stopPrank();
        require(cm.currentDebtOf(who) == 0, "fixture: debt survived");

        vm.prank(stranger);
        auction.closeWorkout(id);
        require(_owed(id) != 0, "fixture: nothing booked");
        vm.prank(admin);
        auction.disposeWorkoutLot(id, stranger);
    }

    /// @dev A fresh era: manager, its own pool, wired on both sides, vault and auction repointed.
    function _migrate() internal returns (CreditManager m) {
        m = _freshManager();
        LenderPool p = new LenderPool(IERC20(address(usdc)), admin);
        address l = address(uint160(0xB0B0 + ++eraNonce));
        usdc.mint(l, LENDER_DEPOSIT);
        vm.startPrank(l);
        usdc.approve(address(p), type(uint256).max);
        p.deposit(LENDER_DEPOSIT, l);
        vm.stopPrank();
        vm.startPrank(admin);
        p.setCreditManager(address(m));
        p.setEpochHarvester(harvester);
        m.setLiquiditySource(address(p));
        m.setLenderPool(address(p));
        m.setEpochHarvester(harvester);
        vault.setCreditManager(address(m));
        auction.setCreditManager(address(m));
        m.setLiquidationAuction(address(auction));
        vm.stopPrank();
    }

    function _owed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _claim(uint256 id, address who) internal returns (uint256 paid) {
        uint256 before = usdc.balanceOf(who);
        vm.prank(stranger);
        try auction.claimWorkoutYield(id) {} catch {}
        paid = usdc.balanceOf(who) - before;
    }

    function _dust() internal view returns (uint256) {
        return usdc.balanceOf(address(auction)) - auction.totalUnclaimedRewards();
    }

    // ── CONTROL: the row as filed ────────────────────────────────────────────

    /// @notice CONTROL (the row reproduced, then the runbook). B is refused while A's backing sits
    ///         on the detached M1; one `claimSurplusFor(auction)` on M1 by a stranger and both are paid
    ///         their bookings exactly, the auction ending at rewards plus dust.
    function test_R56A02_235_control_theRunbookUnwindsTheTwoBearerWait() public {
        uint256 idA = _bookCleanClose(alice, m1, 400e6);
        CreditManager m2 = _migrate();
        _seat(bob);
        uint256 idB = _bookCleanClose(bob, m2, 400e6);
        uint256 owedA = _owed(idA);
        uint256 owedB = _owed(idB);
        emit log_named_uint("MEASURED owedA (bearer M1, detached)", owedA);
        emit log_named_uint("MEASURED owedB (bearer M2, live)", owedB);

        // The claim's own `available == 0` refusal, reached naturally (round-56 item 81's second
        // `NothingToClaim` line is live, not dead).
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(idB);
        uint256 early = _claim(idB, bob);
        emit log_named_uint("MEASURED B paid before the runbook", early);
        assertLt(early, owedB, "fixture: B was paid in full without the runbook, the row does not reproduce");

        vm.prank(stranger);
        m1.claimSurplusFor(address(auction));
        uint256 late = _claim(idB, bob);
        assertEq(early + late, owedB, "B was not paid its booking exactly after the runbook");
        assertEq(_claim(idA, alice), owedA, "A was not paid its booking exactly");
        emit log_named_uint("MEASURED dust beyond rewards after both claims", _dust());
        assertLe(_dust(), 2, "the auction holds more than rewards and dust");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a booking is still standing");
    }

    // ── the orders ──────────────────────────────────────────────────────────

    /// @notice ORDER: A's own claim first. `claimWorkoutYield(A)` pulls from its bearer M1 because
    ///         `bearer != cm`, so it is itself an unwinder: B is then paid in full with no runbook
    ///         step at all. The runbook is sufficient but not necessary.
    function test_R56A02_235_order_theEarlierBorrowersOwnClaimAlsoUnwindsIt() public {
        uint256 idA = _bookCleanClose(alice, m1, 400e6);
        CreditManager m2 = _migrate();
        _seat(bob);
        uint256 idB = _bookCleanClose(bob, m2, 400e6);
        uint256 owedA = _owed(idA);
        uint256 owedB = _owed(idB);
        assertEq(_claim(idA, alice), owedA, "A was not paid in full by her own claim");
        assertEq(m1.claimableOf(address(auction)), 0, "A's claim did not pull M1");
        assertEq(_claim(idB, bob), owedB, "B was not paid in full after A's claim");
        assertLe(_dust(), 2, "dust");
    }

    /// @notice ORDER: A's backing was pushed here BEFORE the migration (a stranger's
    ///         `claimSurplusFor(auction)` while M1 was live). The runbook step then REVERTS
    ///         `NothingToClaim` on M1 - which means "already here", not "failed" - and B is paid in
    ///         full without it.
    function test_R56A02_235_order_pushedBeforeTheRepointTheRunbookRevertsAndIsNotNeeded() public {
        uint256 idA = _bookCleanClose(alice, m1, 400e6);
        vm.prank(stranger);
        m1.claimSurplusFor(address(auction));
        CreditManager m2 = _migrate();
        _seat(bob);
        uint256 idB = _bookCleanClose(bob, m2, 400e6);
        uint256 owedA = _owed(idA);
        uint256 owedB = _owed(idB);
        vm.prank(stranger);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        m1.claimSurplusFor(address(auction));
        assertEq(_claim(idB, bob), owedB, "B was not paid in full with A's backing already here");
        assertEq(_claim(idA, alice), owedA, "A was not paid in full");
        assertLe(_dust(), 2, "dust");
    }

    /// @notice ORDER: B claims early and is PAID PART (a donation sits here, so the balance exceeds
    ///         what is reserved for A by less than B's booking); then the runbook; then B claims the
    ///         remainder. The two partial payments sum to the booking exactly.
    function test_R56A02_235_order_aPartialEarlyPaymentThenTheRunbookSumsExactly() public {
        uint256 idA = _bookCleanClose(alice, m1, 400e6);
        CreditManager m2 = _migrate();
        _seat(bob);
        uint256 idB = _bookCleanClose(bob, m2, 400e6);
        uint256 owedA = _owed(idA);
        uint256 owedB = _owed(idB);
        // A donation large enough that B's early claim is paid SOMETHING and not everything.
        usdc.mint(address(auction), owedA - owedB / 2);
        uint256 early = _claim(idB, bob);
        emit log_named_uint("MEASURED B early partial", early);
        assertGt(early, 0, "fixture: B was paid nothing early");
        assertLt(early, owedB, "fixture: B was paid in full early");
        vm.prank(stranger);
        m1.claimSurplusFor(address(auction));
        uint256 late = _claim(idB, bob);
        assertEq(early + late, owedB, "B's two payments do not sum to the booking");
        assertEq(_claim(idA, alice), owedA, "A was not paid in full");
    }

    /// @notice ORDER: three eras. A on M1 and C on M2 are both detached, B is live on M3. Pulling
    ///         ONLY M1 leaves B short by C's booking; pulling M2 as well pays everyone exactly. So the
    ///         runbook's "every detached bearer" is load-bearing, not a figure of speech.
    function test_R56A02_235_order_threeErasNeedEveryDetachedBearerPulled() public {
        uint256 idA = _bookCleanClose(alice, m1, 400e6);
        CreditManager m2 = _migrate();
        _seat(carol);
        uint256 idC = _bookCleanClose(carol, m2, 300e6);
        CreditManager m3 = _migrate();
        _seat(bob);
        uint256 idB = _bookCleanClose(bob, m3, 400e6);
        uint256 owedA = _owed(idA);
        uint256 owedB = _owed(idB);
        uint256 owedC = _owed(idC);

        vm.prank(stranger);
        m1.claimSurplusFor(address(auction));
        uint256 partial_ = _claim(idB, bob);
        emit log_named_uint("MEASURED B paid with only M1 pulled", partial_);
        emit log_named_uint("MEASURED owedB", owedB);
        emit log_named_uint("MEASURED owedC (still on detached M2)", owedC);
        assertLt(partial_, owedB, "B was paid in full with M2 still unpulled");

        vm.prank(stranger);
        m2.claimSurplusFor(address(auction));
        assertEq(partial_ + _claim(idB, bob), owedB, "B was not paid exactly after both pulls");
        assertEq(_claim(idA, alice), owedA, "A was not paid exactly");
        assertEq(_claim(idC, carol), owedC, "C was not paid exactly");
        assertLe(_dust(), 3, "dust");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "a booking still stands");
    }

    /// @notice ORDER: the owner ran `migrateReserves` on M1 as part of the migration. It leaves
    ///         `totalClaimable` behind by design, so A's backing survives and the runbook still works.
    function test_R56A02_235_order_migrateReservesOnTheDetachedBearerLeavesTheBackingBehind() public {
        uint256 idA = _bookCleanClose(alice, m1, 400e6);
        CreditManager m2 = _migrate();
        uint256 backingOnM1 = m1.claimableOf(address(auction));
        vm.prank(admin);
        bool migrated;
        try m1.migrateReserves() {
            migrated = true;
        } catch {}
        assertTrue(migrated, "fixture: migrateReserves did not run");
        assertEq(m1.claimableOf(address(auction)), backingOnM1, "migrateReserves took A's backing");
        _seat(bob);
        uint256 idB = _bookCleanClose(bob, m2, 400e6);
        uint256 owedA = _owed(idA);
        uint256 owedB = _owed(idB);
        vm.prank(stranger);
        m1.claimSurplusFor(address(auction));
        assertEq(_claim(idB, bob), owedB, "B not paid after the runbook");
        assertEq(_claim(idA, alice), owedA, "A not paid");
    }
}
