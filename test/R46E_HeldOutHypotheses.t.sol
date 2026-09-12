// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice The Phase-4 graph `Impairment.integration.t.sol` builds - the real `LenderPool` as both
///         funder and loss sink, the real auction - generalised to several borrowers. Copied rather
///         than subclassed, because a subclass inherits the fixture's whole suite and re-runs it.
abstract contract R46E_PoolGraph is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
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

    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    /// @dev Even a fill at 100% of NAV cannot cover the loan, so a workout recognises a loss.
    function _crashedNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS) / 2;
    }

    function setUp() public virtual {
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
    }

    /// @dev Deposit a lot and borrow at the ceiling. The derivation is read BEFORE the prank: it is
    ///      an external view call now that the parameters are storage, and `vm.prank` spends itself
    ///      on the next call, static or not.
    function _stageBorrower(address who) internal returns (uint256 debt) {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();

        debt = _maxBorrowAtCeiling();
        vm.prank(who);
        credit.borrow(debt);
    }

    function _liquidate(address who) internal returns (uint256 id) {
        vm.prank(keeper);
        credit.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: the auction did not open");
    }

    function _repayInFull(address who) internal {
        uint256 owed = credit.currentDebtOf(who);
        usdc.mint(payer, owed);
        vm.startPrank(payer);
        usdc.approve(address(credit), owed);
        credit.repayFor(who, owed);
        vm.stopPrank();
        assertEq(credit.currentDebtOf(who), 0, "fixture: the repayment did not clear the debt");
    }
}

/// @notice Round 46, open item 76a: is `_impairedBorrowers` iterated on a hot path a borrower
///         can lengthen?
///
/// @dev The set lives in `LenderPool` (`_impairedBorrowers`, appended by `_trackImpaired` and
///      swap-popped by `_untrackImpaired`, both O(1)). The grep basis for "no hot path walks it",
///      taken at `8631498` over `contracts/src`: `impairedBorrowerAt` and `impairedBorrowerCount`
///      are read in exactly one function outside the pool's own getters,
///      `CreditManager.refreshImpairments(maxBorrowers)`, and nothing in `LenderPool.sol` indexes
///      the array except the getters and the swap-pop. `borrow`, `repay`, `liquidate`, `settle`,
///      `distributeYield` and every `LenderPool` door read `totalImpairment`, a single aggregate,
///      never the set. So the only loop is the permissionless sweep, and it is bounded by its
///      CALLER, not by the set: a borrower can lengthen the set (one entry per liquidated address,
///      and addresses are free), and what that buys them is more entries for a sweeper to choose
///      to visit, never a more expensive call for anybody who did not choose.
///
///      What is measured below rather than read, and how the first draft of it went red for the
///      right reason: `foundry.toml` sets `isolate = true`, so every top-level call from a test is
///      its own transaction with cold storage, and a one-entry set can only ever write
///      `impairmentCursor` from zero to zero while a larger set writes it to a non-zero index. The
///      first draft compared one mark against three and read the 19,596-gas difference - one
///      `SSTORE` from zero to non-zero - as growth. It is not, and the comparisons below are
///      arranged so both sides make the same class of cursor write: (1) `refreshImpairments(1)`
///      costs the same against two marks as against three, and the one-mark figure is logged with
///      the cursor-write reason beside it; (2) a ceiling borrow costs the same with one mark
///      standing as with three, and the no-mark figure is logged as the fixed cost of the reserve
///      arithmetic having anything to reserve at all.
contract R46E_ImpairedSetIsNotAHotPath is R46E_PoolGraph {
    address internal frank = makeAddr("frank");

    /// @dev Gas of one bounded sweep, call overhead included. Under `isolate = true` this is a
    ///      whole cold transaction, which is the same on both sides of every comparison below.
    function _sweepGas(uint256 maxBorrowers) private returns (uint256 used) {
        uint256 before = gasleft();
        credit.refreshImpairments(maxBorrowers);
        used = before - gasleft();
    }

    /// @dev Deposit a lot and borrow at the ceiling, returning the gas of the borrow alone.
    function _borrowGas(address who) private returns (uint256 used) {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(who);
        uint256 before = gasleft();
        credit.borrow(debt);
        used = before - gasleft();
    }

    function test_R46E_theBoundedSweepCostsTheSameAgainstTwoMarksAsAgainstThree() public {
        _stageBorrower(alice);
        _stageBorrower(bob);
        _stageBorrower(carol);
        oracle.setNav(_crashedNav());

        // One mark: the cursor can only be written 0 -> 0. Logged for the record, not compared.
        _liquidate(alice);
        assertEq(pool.impairedBorrowerCount(), 1, "premise: one mark");
        uint256 withOne = _sweepGas(1);
        assertEq(credit.impairmentCursor(), 0, "premise: a one-entry set leaves the cursor at zero");

        // Two marks, cursor at 0: the sweep wraps to 2, visits index 1, writes the cursor 0 -> 1.
        _liquidate(bob);
        assertEq(pool.impairedBorrowerCount(), 2, "premise: two marks");
        assertEq(credit.impairmentCursor(), 0, "premise: cursor at zero before the two-mark sweep");
        uint256 withTwo = _sweepGas(1);
        assertEq(credit.impairmentCursor(), 1, "premise: the two-mark sweep wrote a non-zero cursor");

        // Three marks, cursor reset to 0 by a sweep that visits the rest: the sweep wraps to 3,
        // visits index 2, writes the cursor 0 -> 2. Same visit count, same write class.
        _liquidate(carol);
        assertEq(pool.impairedBorrowerCount(), 3, "premise: three marks");
        credit.refreshImpairments(1); // cursor 1 -> 0
        assertEq(credit.impairmentCursor(), 0, "premise: cursor at zero before the three-mark sweep");
        uint256 withThree = _sweepGas(1);
        assertEq(credit.impairmentCursor(), 2, "premise: the three-mark sweep wrote a non-zero cursor");

        emit log_named_uint("refreshImpairments(1) gas, one mark standing (cursor 0 -> 0)", withOne);
        emit log_named_uint("refreshImpairments(1) gas, two marks standing (cursor 0 -> 1)", withTwo);
        emit log_named_uint("refreshImpairments(1) gas, three marks standing (cursor 0 -> 2)", withThree);
        // Two percent: what would fail this is a walk of the set, at least one cold SLOAD plus one
        // external `impairedBorrowerAt` call per extra entry, which is several thousand gas.
        assertLe(withThree, withTwo + withTwo / 50, "the bounded sweep grew with the set");
        assertGe(withThree + withThree / 50, withTwo, "the bounded sweep shrank with the set, which is also news");

        // The set's length costs something in exactly one place: a sweep the caller sized to it.
        credit.refreshImpairments(2); // cursor 2 -> 0, so the whole-set sweep below writes 0 -> 0
        assertEq(credit.impairmentCursor(), 0, "premise: cursor at zero before the whole-set sweep");
        uint256 whole = _sweepGas(3);
        emit log_named_uint("refreshImpairments(3) gas, three marks standing (cursor 0 -> 0)", whole);
        assertGt(whole, withThree, "premise: a wider sweep does more work");
    }

    function test_R46E_aCeilingBorrowCostsTheSameWithOneMarkStandingAsWithThree() public {
        _stageBorrower(alice);
        _stageBorrower(bob);
        _stageBorrower(carol);

        // One mark standing, then a ceiling borrow at the healthy NAV.
        oracle.setNav(_crashedNav());
        uint256 idA = _liquidate(alice);
        oracle.setNav(NAV);
        assertEq(pool.impairedBorrowerCount(), 1, "premise: one mark");
        uint256 withOne = _borrowGas(dave);

        // Three marks standing, the same borrow.
        oracle.setNav(_crashedNav());
        uint256 idB = _liquidate(bob);
        uint256 idC = _liquidate(carol);
        oracle.setNav(NAV);
        assertEq(pool.impairedBorrowerCount(), 3, "premise: three marks");
        uint256 withThree = _borrowGas(erin);

        // No mark standing: heal every position and release every mark, the same borrow again.
        vm.startPrank(stranger);
        auction.cancel(idA);
        auction.cancel(idB);
        auction.cancel(idC);
        vm.stopPrank();
        assertEq(pool.impairedBorrowerCount(), 0, "premise: every mark released");
        uint256 withNone = _borrowGas(frank);

        emit log_named_uint("borrow gas, one mark standing", withOne);
        emit log_named_uint("borrow gas, three marks standing", withThree);
        emit log_named_uint("borrow gas, no marks standing", withNone);
        assertLe(withThree, withOne + withOne / 50, "a borrow paid for the size of the impaired set");
        assertGe(withThree + withThree / 50, withOne, "a borrow got cheaper with more marks, which is also news");
    }
}

/// @notice Round 46, open item 70: is the bare push in `CreditManager.flushPrincipalTo` reachable
///         against a `LenderPool` that no longer names this manager?
///
/// @dev The arm fires only when `owedToSource[pool] != 0`, the pull through `repayPrincipal`
///      delivered nothing, and `CreditWiring.sourceStillAnswersToUs(pool)` is false - which for a
///      `LenderPool` means `pool.creditManager() != this`, and `LenderPool.setCreditManager` refuses
///      while `outstandingPrincipal != 0`. So the question is whether the pool's `outstandingPrincipal`
///      can reach zero while this manager still holds a park for it. MEASURED here, on the real
///      Phase-4 graph, with the park staged by the one refusal that is real-world shaped, a USDC
///      blocklist on the pool (the accepted round-22 receiver case):
///
///        1. the park leaves the pool's book carrying exactly what it is owed, so the pool cannot
///           repoint (`PrincipalOutstanding`);
///        2. while the pool still refuses, the flush re-parks and reverts `PrincipalRefused` - it
///           does not push bare, because the pool still answers to this manager;
///        3. the one route that lowers the pool's book without this manager delivering - a
///           socialised loss, offered only while the pool is funder AND sink - is bounded by that
///           later loan's own debt and cannot eat into the park;
///        4. once the pool can take delivery the flush goes through `repayPrincipal`, the book
///           closes to zero with `unmanagedSurplus() == 0`, and only then can the pool repoint.
///
///      The identity behind all four, asserted after every step: the pool's `outstandingPrincipal`
///      is never below what this manager still owes it. That is a measured negative for item 70 on
///      the routes CreditManager can drive; it is not a proof over every source, and the bare arm
///      remains the designed escape for a detached `TreasuryLiquiditySource`.
contract R46E_BarePushToARepointedPool is R46E_PoolGraph {
    TreasuryLiquiditySource internal treasury;

    function setUp() public override {
        super.setUp();
        treasury = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        treasury.setCreditManager(address(credit));
    }

    function _assertThePoolIsNeverOwedLessThanItsBook(string memory step) private view {
        assertGe(
            pool.outstandingPrincipal(),
            credit.owedToSource(address(pool)) + credit.pendingPrincipal(),
            string.concat(step, ": the pool's book fell below what this manager still owes it")
        );
    }

    function test_R46E_aParkedPoolPrincipalPinsThePoolToThisManagerSoTheBareArmNeverFires() public {
        uint256 loan = _stageBorrower(alice);
        assertEq(pool.outstandingPrincipal(), loan, "premise: the pool funded the loan");
        _repayInFull(alice);
        uint256 owed = credit.pendingPrincipal();
        assertEq(owed, loan, "premise: the whole principal is waiting to go home");
        _assertThePoolIsNeverOwedLessThanItsBook("repaid");

        // The pool cannot take delivery, and the funder is moved off it: the residue parks.
        usdc.setBlocked(address(pool), true);
        vm.prank(admin);
        credit.setLiquiditySource(address(treasury));
        assertEq(credit.owedToSource(address(pool)), owed, "premise: the residue parked against the pool");
        assertEq(credit.pendingPrincipal(), 0);
        assertEq(pool.outstandingPrincipal(), loan, "the pool's book still carries what it is owed");
        _assertThePoolIsNeverOwedLessThanItsBook("parked");

        // 1. The pool cannot repoint, by name.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.PrincipalOutstanding.selector, loan));
        pool.setCreditManager(stranger);

        // 2. While the pool refuses, the flush is refused, not pushed bare.
        uint256 poolBefore = usdc.balanceOf(address(pool));
        vm.expectRevert(abi.encodeWithSelector(CreditManager.PrincipalRefused.selector, address(pool), owed));
        credit.flushPrincipalTo(address(pool));
        assertEq(credit.owedToSource(address(pool)), owed, "the park did not survive the refusal");
        assertEq(usdc.balanceOf(address(pool)), poolBefore, "USDC reached a pool that refused it");

        // 3. The only book-lowering route without delivery: put the pool back as funder, let a
        //    second borrower default outright, and force the workout so the loss is socialised.
        usdc.setBlocked(address(pool), false);
        vm.prank(admin);
        credit.setLiquiditySource(address(pool));
        assertEq(credit.lenderPool(), address(pool), "premise: the pool is sink");
        assertEq(credit.liquiditySource(), address(pool), "premise: and funder again");

        uint256 loanB = _stageBorrower(bob);
        assertEq(pool.outstandingPrincipal(), loan + loanB, "premise: the pool funded bob too");
        oracle.setNav(_crashedNav());
        uint256 id = _liquidate(bob);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(id);
        assertGt(pool.lifetimeSocialisedLoss(), 0, "premise: the forced close socialised a loss");
        assertEq(pool.outstandingPrincipal(), loan, "the socialised loss ate only bob's own principal");
        _assertThePoolIsNeverOwedLessThanItsBook("socialised");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.PrincipalOutstanding.selector, loan));
        pool.setCreditManager(stranger);

        // 4. Delivered through the pool's own book, never bare.
        oracle.setNav(NAV);
        uint256 assetsBefore = pool.totalAssets();
        credit.flushPrincipalTo(address(pool));
        assertEq(credit.owedToSource(address(pool)), 0, "the park was not spent");
        assertEq(credit.totalOwedToSources(), 0);
        assertEq(pool.outstandingPrincipal(), 0, "the pool's book did not close");
        assertEq(pool.unmanagedSurplus(), 0, "USDC arrived outside the pool's book");
        assertEq(pool.totalAssets(), assetsBefore, "a principal repayment moved the pool's value");
        _assertThePoolIsNeverOwedLessThanItsBook("flushed");

        // And only now is the pool free to leave.
        assertEq(pool.totalImpairment(), 0, "premise: no mark outlived its workout");
        vm.prank(admin);
        pool.setCreditManager(stranger);
        assertEq(pool.creditManager(), stranger, "the pool could not repoint with nothing owed");
    }
}
