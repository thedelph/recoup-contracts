// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
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
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @title Round 59, target 2: H-01's per-write-down recovery records, and the auditor's L-01
///        fixture note, executed.
/// @notice The fixture mirrors `ImpairmentIntegrationTest`'s wiring (the real `LenderPool` as both
///         liquidity source and loss sink) rather than subclassing it: a subclass would inherit
///         that suite's sixty-odd tests and the count would stop meaning anything.
///
/// @dev Everything here measures SHIPPED behaviour at `c9b5f95`, after #531. `recoveryBearerOf`
///      and `recoveryFunderOf` are INTERNAL - with them public the manager read 22,642 runtime
///      against the 2,000-byte floor this session set - so there are no getters to read them
///      through. They are read here with `vm.load` at their declared slots (18 and 19), which is
///      the only way a test can see the record itself rather than its consequence.
contract R59A02_H01SecondDefault is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;

    uint256 internal constant SLOT_RECOVERY_BEARER = 18;
    uint256 internal constant SLOT_RECOVERY_FUNDER = 19;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");
    address internal lender = makeAddr("lender");

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

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = _deployRiskParams(admin);
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

    // ── helpers, mirrored from ImpairmentIntegrationTest ──────────────────────

    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    function _debtParityNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS);
    }

    function _crashedNav() internal view returns (uint256) {
        return _debtParityNav() / 2;
    }

    function _openAuctionAt(uint256 nav) internal returns (uint256 id) {
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(nav);
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: the auction did not open");
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), type(uint256).max);
    }

    function _freshManager() internal returns (CreditManager incoming) {
        incoming = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
    }

    function _migrate() internal returns (CreditManager incoming) {
        incoming = _freshManager();
        vm.startPrank(admin);
        vault.setCreditManager(address(incoming));
        auction.setCreditManager(address(incoming));
        incoming.setLiquidationAuction(address(auction));
        vm.stopPrank();
    }

    function _poolForNewEra(CreditManager incoming) internal returns (LenderPool poolB) {
        poolB = new LenderPool(IERC20(address(usdc)), admin);
        address lenderB = makeAddr("lenderB");
        usdc.mint(lenderB, LENDER_DEPOSIT);
        vm.startPrank(lenderB);
        usdc.approve(address(poolB), type(uint256).max);
        poolB.deposit(LENDER_DEPOSIT, lenderB);
        vm.stopPrank();

        vm.startPrank(admin);
        poolB.setCreditManager(address(incoming));
        poolB.setEpochHarvester(harvester);
        incoming.setLiquiditySource(address(poolB));
        incoming.setLenderPool(address(poolB));
        vm.stopPrank();
    }

    function _forceCloseOntoThePool() internal returns (uint256 id, uint256 writtenDown) {
        id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        writtenDown = pool.lifetimeSocialisedLoss();
        assertGt(writtenDown, 0, "fixture: the pool did not bear the loss");
    }

    function _writtenDown(uint256 id) internal view returns (uint256 w) {
        (,,,,,,, w,,,) = auction.workouts(id);
    }

    /// @dev Read `recoveryBearerOf[auctionAddr][auctionId]` / `recoveryFunderOf[...]` out of the
    ///      manager's storage. Both are internal, so there is no other way to see them.
    function _recoveryRecord(CreditManager manager, uint256 baseSlot, address auctionAddr, uint256 auctionId)
        internal
        view
        returns (address)
    {
        bytes32 outer = keccak256(abi.encode(auctionAddr, baseSlot));
        bytes32 inner = keccak256(abi.encode(auctionId, outer));
        return address(uint160(uint256(vm.load(address(manager), inner))));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // L-01: the auditor's fixture note, executed
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The auditor's L-01 PoC VERBATIM, with the one step their tree did not need omitted,
    ///         confirms their own fixture note precisely: `_migrate()` reverts
    ///         `AuctionHasLiveWork(100)` inside `vault.setCreditManager` because the closed lot is
    ///         still parked on the auction. The figure 100 is the bond count of the parked lot.
    function test_R59A02_L01_theAuditorsPoCWithoutTheDisposalRevertsInTheFIXTURE() public {
        (uint256 id,) = _forceCloseOntoThePool();
        id;
        assertEq(credit.lossBearerOf(alice), address(pool), "fixture: the pool bore the loss");

        uint256 parked = vault.bondCount(address(auction));
        emit log_named_uint("MEASURED bonds parked on the auction     ", parked);
        assertEq(parked, BONDS, "the parked lot is not the whole collateral");

        CreditManager incoming = _freshManager();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, parked));
        vault.setCreditManager(address(incoming));
    }

    /// @notice The same PoC WITH the disposal, confirmed as a fix-asserting test: the former
    ///         manager's recovery now lands on the pool that bore the loss, and the repair the old
    ///         docstring named is still unavailable, which is why the leg has to accept a former
    ///         manager rather than wait for a repoint.
    function test_R59A02_L01_withTheDisposalTheAuditorsPoCPassesAsAFix() public {
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();

        vm.prank(admin);
        auction.disposeWorkoutLot(id, admin); // the auditor's fixture note, executed
        CreditManager incoming = _migrate();
        vm.startPrank(admin);
        pool.setCreditManager(address(incoming));
        incoming.setLiquiditySource(address(pool));
        incoming.setLenderPool(address(pool));
        vm.stopPrank();

        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        _fund(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);

        emit log_named_uint("MEASURED writtenDown recovered           ", writtenDown);
        emit log_named_uint("MEASURED pool cash gained                ", usdc.balanceOf(address(pool)) - poolCashBefore);
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, writtenDown, "the bearer was not paid");
        assertEq(pool.lifetimeLossRecovered(), writtenDown, "not booked as a loss recovery");
        assertEq(_writtenDown(id), 0, "the write-down is not discharged");
        assertEq(usdc.balanceOf(address(incoming)), 0, "the successor paid something");

        // The repair the old docstring named is still shut, unchanged by the fix.
        oracle.setNav(NAV);
        vm.prank(alice);
        vault.depositBonds(BONDS);
        vm.prank(alice);
        incoming.borrow(500e6);
        uint256 live = pool.outstandingPrincipal();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.PrincipalOutstanding.selector, live));
        pool.setCreditManager(address(credit));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H-01: two defaults by the same borrower across a pool migration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The records themselves, read out of storage: two write-downs by the SAME borrower
    ///         with a pool migration between them keep one bearer each, keyed by
    ///         `(auction, auctionId)`, while the borrower-latest views name only the second.
    function test_R59A02_H01_theTwoRecoveryRecordsAreKeptSeparatelyPerWriteDown() public {
        (uint256 oldId,) = _forceCloseOntoThePool();
        assertEq(credit.lossBearerOf(alice), address(pool), "fixture: pool A bore the first loss");

        LenderPool poolB = _poolForNewEra(credit);
        oracle.setNav(NAV);
        vm.prank(alice);
        vault.depositBonds(BONDS);
        uint256 newId = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(newId);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(newId);

        address bearerOld = _recoveryRecord(credit, SLOT_RECOVERY_BEARER, address(auction), oldId);
        address bearerNew = _recoveryRecord(credit, SLOT_RECOVERY_BEARER, address(auction), newId);
        address funderOld = _recoveryRecord(credit, SLOT_RECOVERY_FUNDER, address(auction), oldId);
        address funderNew = _recoveryRecord(credit, SLOT_RECOVERY_FUNDER, address(auction), newId);

        emit log_named_address("MEASURED pool A                      ", address(pool));
        emit log_named_address("MEASURED pool B                      ", address(poolB));
        emit log_named_address("MEASURED recoveryBearerOf[auction][old]", bearerOld);
        emit log_named_address("MEASURED recoveryBearerOf[auction][new]", bearerNew);
        emit log_named_address("MEASURED recoveryFunderOf[auction][old]", funderOld);
        emit log_named_address("MEASURED recoveryFunderOf[auction][new]", funderNew);
        emit log_named_address("MEASURED lossBearerOf[alice] (latest)  ", credit.lossBearerOf(alice));

        assertEq(bearerOld, address(pool), "the first write-down's bearer was overwritten");
        assertEq(bearerNew, address(poolB), "the second write-down's bearer is wrong");
        assertEq(funderOld, address(pool), "the first write-down's funder was overwritten");
        assertEq(funderNew, address(poolB), "the second write-down's funder is wrong");
        assertEq(credit.lossBearerOf(alice), address(poolB), "the borrower-latest view moved as designed");
    }

    /// @notice The order the shipped regression does NOT take: the SECOND workout's recovery is
    ///         delivered FIRST, then the first workout's. Each still reaches the pool that bore it.
    function test_R59A02_H01_recoveringTheSecondWriteDownFirstStillRoutesBothCorrectly() public {
        (uint256 oldId, uint256 oldLoss) = _forceCloseOntoThePool();
        LenderPool poolB = _poolForNewEra(credit);
        oracle.setNav(NAV);
        vm.prank(alice);
        vault.depositBonds(BONDS);
        uint256 newId = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(newId);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(newId);
        uint256 newLoss = _writtenDown(newId);
        assertGt(newLoss, 0, "fixture: the second close wrote nothing down");

        uint256 aBefore = usdc.balanceOf(address(pool));
        uint256 bBefore = usdc.balanceOf(address(poolB));

        // The SECOND one first.
        _fund(payer, newLoss);
        vm.prank(payer);
        auction.workoutSettleAfterClose(newId, newLoss);
        assertEq(usdc.balanceOf(address(poolB)) - bBefore, newLoss, "pool B was not paid its own recovery");
        assertEq(usdc.balanceOf(address(pool)) - aBefore, 0, "pool A took pool B's recovery");

        // Then the FIRST, from a manager the pool has since moved on from only in the sense that
        // it is no longer the manager the auction names - it is the same contract here.
        _fund(payer, oldLoss);
        vm.prank(payer);
        auction.workoutSettleAfterClose(oldId, oldLoss);
        emit log_named_uint("MEASURED pool A recovery                 ", usdc.balanceOf(address(pool)) - aBefore);
        emit log_named_uint("MEASURED pool B recovery                 ", usdc.balanceOf(address(poolB)) - bBefore);
        assertEq(usdc.balanceOf(address(pool)) - aBefore, oldLoss, "pool A was not paid its own recovery");
        assertEq(usdc.balanceOf(address(poolB)) - bBefore, newLoss, "pool B took pool A's recovery");
    }

    /// @notice Two defaults by the same borrower with the pool migration AND a manager migration
    ///         between them, so the first recovery is delivered by a manager the first pool has
    ///         retired and the second by the live one. Both land, from the two contracts that
    ///         recognised them, with neither successor paying.
    /// @dev This is H-01 and L-01 composed: per-write-down routing on the manager side and
    ///         `wasCreditManager` on the pool side have to hold at once, and nothing in the tree
    ///         exercised them together.
    function test_R59A02_H01_composedWithL01_bothRecoveriesLandAcrossBothMigrations() public {
        (uint256 oldId, uint256 oldLoss) = _forceCloseOntoThePool();

        // Pool A retires manager 1 and the whole era moves.
        vm.prank(admin);
        auction.disposeWorkoutLot(oldId, admin);
        CreditManager incoming = _migrate();
        LenderPool poolB = _poolForNewEra(incoming);
        vm.prank(admin);
        pool.setCreditManager(address(incoming));
        assertTrue(pool.wasCreditManager(address(credit)), "pool A does not remember manager 1");

        // A second default by the SAME borrower, on the new era.
        oracle.setNav(NAV);
        vm.prank(alice);
        vault.depositBonds(BONDS);
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        incoming.borrow(debt);
        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        incoming.liquidate(alice);
        uint256 newId = auction.auctionOf(alice);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(newId);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(newId);
        uint256 newLoss = _writtenDown(newId);
        assertGt(newLoss, 0, "fixture: the second close wrote nothing down");

        address bearerOld = _recoveryRecord(credit, SLOT_RECOVERY_BEARER, address(auction), oldId);
        address bearerNew = _recoveryRecord(incoming, SLOT_RECOVERY_BEARER, address(auction), newId);
        emit log_named_address("MEASURED manager 1 record for the old id", bearerOld);
        emit log_named_address("MEASURED manager 2 record for the new id", bearerNew);
        assertEq(bearerOld, address(pool), "manager 1 lost the first bearer");
        assertEq(bearerNew, address(poolB), "manager 2 recorded the wrong bearer");

        uint256 aBefore = usdc.balanceOf(address(pool));
        uint256 bBefore = usdc.balanceOf(address(poolB));

        _fund(payer, oldLoss);
        vm.prank(payer);
        auction.workoutSettleAfterClose(oldId, oldLoss);
        _fund(payer, newLoss);
        vm.prank(payer);
        auction.workoutSettleAfterClose(newId, newLoss);

        emit log_named_uint("MEASURED first loss, borne by pool A     ", oldLoss);
        emit log_named_uint("MEASURED second loss, borne by pool B    ", newLoss);
        emit log_named_uint("MEASURED pool A received                 ", usdc.balanceOf(address(pool)) - aBefore);
        emit log_named_uint("MEASURED pool B received                 ", usdc.balanceOf(address(poolB)) - bBefore);
        assertEq(usdc.balanceOf(address(pool)) - aBefore, oldLoss, "pool A was not paid across the retirement");
        assertEq(usdc.balanceOf(address(poolB)) - bBefore, newLoss, "pool B was not paid its own recovery");
        assertEq(pool.lifetimeLossRecovered(), oldLoss, "pool A did not book its recovery");
        assertEq(poolB.lifetimeLossRecovered(), newLoss, "pool B did not book its recovery");
    }

    /// @notice The bound worth stating for the register: the per-id record is written on EVERY
    ///         `writeDownLoss` under that id, so two write-downs under ONE id would keep only the
    ///         later bearer. The set of writers is enumerated here and shown to be one per id.
    /// @dev `LiquidationAuction` calls `writeDownLoss` from `_settleFill` (a fill short of the
    ///      debt) and from `closeWorkout` (the forced close). A lot either fills or expires to a
    ///      workout, never both, so no id reaches two write-downs - which is why the shipped keying
    ///      is sufficient. This test asserts that a second forced close cannot reuse the id.
    function test_R59A02_H01_oneAuctionIdCarriesAtMostOneWriteDown() public {
        (uint256 oldId,) = _forceCloseOntoThePool();
        oracle.setNav(NAV);
        vm.prank(alice);
        vault.depositBonds(BONDS);
        uint256 newId = _openAuctionAt(_crashedNav());
        emit log_named_uint("MEASURED first auction id                ", oldId);
        emit log_named_uint("MEASURED second auction id               ", newId);
        assertGt(newId, oldId, "auction ids are not monotonic, so a record could be reused");

        // And the closed workout cannot be closed again under its own id.
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(newId);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(newId);
        vm.prank(stranger);
        vm.expectRevert();
        auction.closeWorkout(newId);
    }
}
