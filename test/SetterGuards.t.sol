// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {ILiquiditySource} from "../src/interfaces/ILiquiditySource.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice An adapter answering `vault()` and nothing else - the entire incoming probe on
///         `CollateralVault.setCustodyAdapter` before audit round 21.
/// @dev Not a rug and not malicious: this is an operator installing a half-finished or wrong-ABI
///      adapter. Everything it does not answer reverts with no data, which is indistinguishable at
///      the call site from a missing selector.
contract VaultOnlyAdapter {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }
}

/// @notice An adapter answering both of the *view* selectors the vault calls on this pointer, and
///         none of the four state-changing ones - and able to stop answering afterwards.
/// @dev The `stopAnswering` flag is DexFi's farm going down under a genuine adapter, not a liar:
///      `DirectCallAdapter.stakedBalance()` forwards to the farm, so it is an external call that
///      can revert on an adapter that was entirely real when it was installed. That is the case
///      `CollateralVault._outgoingStake`'s `try`/`catch` exists for, and the only way to reach it.
contract TwoViewAdapter {
    address public immutable vault;
    bool public stopAnswering;

    constructor(address vault_) {
        vault = vault_;
    }

    function stakedBalance() external view returns (uint256) {
        require(!stopAnswering, "farm down");
        return 0;
    }

    function breakTheFarm() external {
        stopAnswering = true;
    }
}

/// @notice A credit manager answering exactly the four selectors `CollateralVault
///         .setCreditManager` probes on the INCOMING pointer, and not the one it reads on the
///         OUTGOING pointer.
/// @dev Audit round 21's own PoC for this used three selectors and **no longer installs**, because
///      PR #204 added `navOracle()` to the incoming list two commits before this one. A stub that
///      fails an older check makes a test red for the wrong reason, so this one is complete enough
///      to reach the line under test.
contract FourSelectorManager {
    address public immutable vault;
    address public immutable riskParams;
    address public immutable navOracle;

    constructor(address vault_, address riskParams_, address navOracle_) {
        vault = vault_;
        riskParams = riskParams_;
        navOracle = navOracle_;
    }

    function accYieldPerBond() external pure returns (uint256) {
        return 0;
    }
    // No totalDebt, no settleForVault, no debtOf, no currentDebtOf.
}

/// @title SetterGuards
/// @notice Audit round 21, findings 9 and 10: what the wiring setters read on the pointers they are
///         replacing, and the one sibling that is deliberately left alone.
///
/// @dev Three groups of tests, and they are not the same kind of thing.
///
///      **Regressions.** Finding 10's split (`CreditManager.setLiquidationAuction` succeeding where
///      the vault's twin refuses) and finding 9's two bare reads were each reproduced in this tree
///      first, at `1e7fce2`, before a line of the fix was written.
///
///      **Controls.** Every `try`/`catch` added here is checked against a genuine outgoing pointer
///      that answers, so catching is shown not to have loosened the guard it wraps.
///
///      **A sign check.** `test_signCheck_theAuctionsReturnLegMustNotCountTheParkedLot` passes
///      before and after this commit, deliberately: it exists to assert that the guard finding 10
///      asks for on the third sibling would move the protocol the wrong way, which is why that
///      sibling is unchanged.
contract SetterGuardsTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal harvesterAddr = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal liquidity;
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
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvesterAddr);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Borrowing power at the ceiling, read from the live authority rather than written down.
    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    /// @dev A NAV low enough that even a fill at 100% of it cannot cover the loan, so the auction
    ///      runs to expiry and the workout closes with a real residual to write down.
    function _crashedNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS) / 2;
    }

    function _freshAuction() private returns (LiquidationAuction) {
        return new LiquidationAuction(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
    }

    /// @dev Drives a liquidation all the way to a forced `closeWorkout`, which pops the queue and
    ///      leaves the lot parked under the auction's ledger entry until `disposeWorkoutLot` moves
    ///      it. Both counters the two sibling setters read then say zero over collateral that is
    ///      still there - which is the whole of finding 10.
    function _parkAClosedWorkoutLot() private returns (uint256 id, uint256 heldLot) {
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: the auction did not open");

        skip(Config.AUCTION_DURATION + 1);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);

        assertEq(auction.liveAuctionCount(), 0, "fixture: the queue the two siblings read is empty");
        assertEq(auction.openWorkoutCount(), 0, "fixture: and so is the other one");
        heldLot = vault.bondCount(address(auction));
        assertGt(heldLot, 0, "fixture: the lot was already disposed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Finding 10. The lot, not the queue - on both pointers that must agree.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The manager's setter now refuses the state the vault's setter already refuses, so
    ///         the two auction pointers cannot be split by a repoint over an undisposed lot.
    /// @dev Before this commit the second call below succeeded. MEASURED at `1e7fce2`: the vault
    ///      refused `AuctionHasLiveWork(100)`, the manager repointed, and `borrow` and `liquidate`
    ///      then both reverted `AuctionPointerMismatch` - every new loan and every liquidation in
    ///      the protocol offline until two further owner transactions repaired it.
    function test_theManagerRefusesToRepointOverAnUndisposedWorkoutLot() public {
        (, uint256 heldLot) = _parkAClosedWorkoutLot();
        LiquidationAuction auctionB = _freshAuction();

        // The vault has refused this since round 20.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, heldLot));
        vault.setLiquidationAuction(address(auctionB));

        // Round 21: so does the manager.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.AuctionHasLiveWork.selector, heldLot));
        credit.setLiquidationAuction(address(auctionB));

        assertEq(credit.liquidationAuction(), address(auction), "the manager did not move");
        assertEq(vault.liquidationAuction(), address(auction), "and neither did the vault");
    }

    /// @notice CONTROL, and the deadlock check: the disposal that clears the refusal is reachable
    ///         in exactly the refused state, and once the lot is gone both setters move together.
    ///         The new clause forbids nothing that was reachable before it.
    function test_control_disposingTheLotUnblocksBothSettersTogether() public {
        (uint256 id,) = _parkAClosedWorkoutLot();
        LiquidationAuction auctionB = _freshAuction();

        vm.startPrank(admin);
        auction.disposeWorkoutLot(id, stranger);
        assertEq(vault.bondCount(address(auction)), 0, "the lot left the ledger");
        credit.setLiquidationAuction(address(auctionB));
        vault.setLiquidationAuction(address(auctionB));
        auctionB.setCreditManager(address(credit));
        vm.stopPrank();

        assertEq(credit.liquidationAuction(), address(auctionB), "the manager followed");
        assertEq(vault.liquidationAuction(), address(auctionB), "and so did the vault");

        // And the pair being in step is what `borrow` reads: no `AuctionPointerMismatch`.
        oracle.setNav(NAV);
        vm.startPrank(alice);
        vault.depositBonds(BONDS);
        uint256 amount = _maxBorrowAtCeiling() / 10;
        credit.borrow(amount);
        vm.stopPrank();
        assertGt(credit.debtOf(alice), 0, "a new loan is possible again");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Finding 10, the sign check: the THIRD sibling must not get this guard.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `LiquidationAuction.setCreditManager` is the third setter finding 10 names, and it
    ///         is deliberately unchanged. The guard would move the protocol the wrong way.
    /// @dev The other two install the same pointer and have to agree with each other. This one is
    ///      the return leg, and it can only ever *follow* the vault - `CreditManagerNotLive`
    ///      requires the incoming manager to be the one the vault already names. A `bondCount`
    ///      clause here would therefore not prevent a split; it would **create** one, by refusing
    ///      the follow after the vault has moved. And `start` is gated on this pointer, so an
    ///      auction that cannot follow is an auction on which the live manager can never open a
    ///      liquidation at all.
    ///
    ///      Asserted rather than argued, in three parts: the state the proposed guard would read is
    ///      genuinely present; refusing the follow leaves `start` shut against the manager the
    ///      vault names; and the follow succeeds today.
    ///
    ///      **This test passes before this commit as well as after it.** It is a sign check on a
    ///      change that was considered and not made, not a regression on one that was.
    ///
    ///      **Audit round 22, finding 8, engaged with rather than worked around.** That finding is
    ///      about money leaving with the pointer this test insists must be free to move: the state
    ///      it drives the manager pointer over carries a non-zero `w.writtenDown`, and the tranche
    ///      that pays it used to follow the pointer instead of the balance sheet. The conclusion
    ///      here is unchanged and the fix is the reason - it records the bearer at the close rather
    ///      than refusing the follow - so part 4 below asserts both halves at once: the follow still
    ///      succeeds, and the closed workout still names the manager that actually bore its loss.
    function test_signCheck_theAuctionsReturnLegMustNotCountTheParkedLot() public {
        (uint256 parkedId, uint256 heldLot) = _parkAClosedWorkoutLot();
        assertGt(heldLot, 0, "part 1: the proposed guard's precondition is present");

        CreditManager managerB = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        assertEq(credit.totalDebt(), 0, "fixture: the write-down cleared the book");

        // The vault's manager pointer moves over a parked lot: it reads the two queue counters,
        // not the ledger, and round 21 did not ask it to change.
        vm.prank(admin);
        vault.setCreditManager(address(managerB));
        assertEq(vault.creditManager(), address(managerB), "the vault moved");

        // Part 2, taken BEFORE the follow: while the auction still names the old manager, the
        // manager the vault names cannot open a liquidation at all. That is the cost of a guard
        // here, and it is the same cost finding 10 charges the manager's setter for.
        vm.prank(address(managerB));
        vm.expectRevert(LiquidationAuction.NotCreditManager.selector);
        auction.start(alice, keeper);

        // Part 3: the follow is available, and a `bondCount` clause here would have refused it on
        // the same non-zero `heldLot` the other two setters now refuse on.
        assertEq(vault.bondCount(address(auction)), heldLot, "the lot is still parked at the follow");
        vm.prank(admin);
        auction.setCreditManager(address(managerB));
        assertEq(auction.creditManager(), address(managerB), "the return leg followed, as it must");

        // Part 4, audit round 22 finding 8: the follow is safe because the workout remembers who
        // bore its write-off. Read back after the repoint, which is the only moment at which the
        // two answers can differ.
        (,,,,,,, uint256 writtenDown, address bearer,,) = auction.workouts(parkedId);
        assertGt(writtenDown, 0, "part 4: the fixture wrote nothing off, so there is nothing to misdirect");
        assertEq(bearer, address(credit), "the closed workout followed the pointer instead of the bearer");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Finding 9. The custody adapter: one probe of six, and a bare read out.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The measured stub no longer installs: `stakedBalance()` is probed on the way in.
    function test_anAdapterThatCannotAnswerStakedBalanceIsRefusedAtWiringTime() public {
        vm.prank(alice);
        vault.withdrawBonds(BONDS);
        assertEq(adapter.stakedBalance(), 0, "premise: the outgoing adapter is empty");

        VaultOnlyAdapter stub = new VaultOnlyAdapter(address(vault));

        vm.prank(admin);
        vm.expectRevert();
        vault.setCustodyAdapter(ICustodyAdapter(address(stub)));

        assertEq(address(vault.custodyAdapter()), address(adapter), "the pointer did not move");

        // And nothing downstream was touched: the vault still answers and still takes deposits.
        assertTrue(vault.custodyIsSolvent(), "custody still answers");
        vm.prank(alice);
        vault.depositBonds(BONDS);
        assertEq(vault.bondCount(alice), BONDS, "deposits still work");
    }

    /// @notice The way back survives an outgoing adapter that stops answering. This is the part of
    ///         the fix the probe cannot do, because a probe only ever sees install time.
    function test_anOutgoingAdapterThatStopsAnsweringDoesNotWeldTheVaultShut() public {
        vm.prank(alice);
        vault.withdrawBonds(BONDS);

        TwoViewAdapter flaky = new TwoViewAdapter(address(vault));
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(flaky)));
        assertEq(address(vault.custodyAdapter()), address(flaky), "it answers both views, so it installs");

        // The farm goes down under it. Its `stakedBalance()` now reverts, exactly as a real
        // adapter's would - that read forwards to DexFi.
        flaky.breakTheFarm();

        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        assertEq(address(vault.custodyAdapter()), address(adapter), "the escape hatch still opens");
    }

    /// @notice CONTROL for that `try`/`catch`: a genuine adapter holding a genuine position is
    ///         still refused, so catching did not loosen the guard it wraps.
    function test_control_aLiveOutgoingPositionIsStillRefused() public {
        assertEq(adapter.stakedBalance(), BONDS, "premise: the outgoing adapter is holding");

        TwoViewAdapter incoming = new TwoViewAdapter(address(vault));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AdapterHasLivePosition.selector, BONDS));
        vault.setCustodyAdapter(ICustodyAdapter(address(incoming)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Finding 9, related: the bare `totalDebt()` on the outgoing manager.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A manager that clears the four incoming checks and cannot answer `totalDebt()` no
    ///         longer welds shut the function this file calls the escape from every other
    ///         unrecoverable state in the vault.
    function test_anOutgoingManagerThatCannotAnswerTotalDebtDoesNotWeldTheHatchShut() public {
        assertEq(credit.totalDebt(), 0, "premise: nothing outstanding");

        FourSelectorManager stub = new FourSelectorManager(address(vault), address(riskParams), address(oracle));

        vm.prank(admin);
        vault.setCreditManager(address(stub));
        assertEq(vault.creditManager(), address(stub), "the stub installed on the four it answers");

        // Round 21: the first statement of this function used to revert on the pointer it had just
        // accepted, permanently, on an immutable contract holding third-party collateral.
        vm.prank(admin);
        vault.setCreditManager(address(credit));
        assertEq(vault.creditManager(), address(credit), "the hatch still opens");

        vm.prank(alice);
        vault.withdrawBonds(1);
        assertEq(vault.bondCount(alice), BONDS - 1, "and the vault works again");
    }

    /// @notice CONTROL for that `try`/`catch`: a real outgoing manager carrying real debt is still
    ///         refused. Catching cannot make a genuine refusal go away.
    function test_control_aRealOutgoingManagerWithDebtIsStillRefused() public {
        uint256 debt = _maxBorrowAtCeiling() / 10;
        vm.prank(alice);
        credit.borrow(debt);
        uint256 outstanding = credit.totalDebt();
        assertGt(outstanding, 0, "premise: the outgoing manager records debt");

        CreditManager managerB = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.CreditManagerHasDebt.selector, outstanding));
        vault.setCreditManager(address(managerB));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 22, finding 21. The fourth round running that a selector reached
    // a never-blockable path without its probe - and the first time the list is
    // counted from the type rather than from the diff.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A pool that answers every other member of `ILenderPool` and not `recoverLoss` is
    ///         refused at wiring time rather than at the payment.
    /// @dev MEASURED before the fix: the stub below installed with no complaint as both funder and
    ///      sink, and `recoverWrittenDownLoss` then reverted with **returndata length 0** - a
    ///      missing selector, with no error to diagnose it by. `recoverLoss` was added to the
    ///      interface by round 21's own remediation and called bare; nothing extended the probe.
    ///
    ///      **`recoverLoss(0)` is not shipped as a success probe**, which was the obvious form and
    ///      is wrong: a conforming pool refuses zero with `ZeroAmount()`, so a success probe would
    ///      reject the real contract. The probe reads the *shape* of the failure instead - empty
    ///      returndata means the selector is absent, any returndata means it is present and
    ///      refused. Both arms are asserted here, which is the only way to tell the two apart.
    function test_R22_aPoolMissingRecoverLossIsRefusedAtWiringTime() public {
        PoolWithoutRecoverLoss stub = new PoolWithoutRecoverLoss();
        vm.prank(admin);
        vm.expectRevert(CreditManager.LenderPoolIncomplete.selector);
        credit.setLenderPool(address(stub));
        assertEq(credit.lenderPool(), address(0), "the incomplete pool installed anyway");
    }

    /// @notice The same for `impairedBorrowerAt`, which this file used to record as unprobeable.
    /// @dev The objection was real and is retired rather than ignored: an incoming pool has an empty
    ///      set, so index 0 reverts with a `Panic`, and under a bare `catch` that is
    ///      indistinguishable from a missing selector. A `Panic` carries returndata and a missing
    ///      selector does not, so a probe that reads the shape of the failure tells them apart. The
    ///      control below is the arm that matters: the real pool, whose set is empty, still installs.
    function test_R22_aPoolMissingImpairedBorrowerAtIsRefusedAtWiringTime() public {
        PoolWithoutImpairedBorrowerAt stub = new PoolWithoutImpairedBorrowerAt();
        vm.prank(admin);
        vm.expectRevert(CreditManager.LenderPoolIncomplete.selector);
        credit.setLenderPool(address(stub));
    }

    /// @notice **CONTROL, and the arm a probe of this shape most needs.** The shipped `LenderPool`
    ///         installs, with an empty impairment set and a `recoverLoss` that refuses zero.
    /// @dev Run against the real contract rather than a stub on purpose: the failure mode of a
    ///      returndata-shape probe is refusing the thing it was written to accept, and only the real
    ///      thing can rule that out. A `STATICCALL` version of the `recoverLoss` probe was tried
    ///      first and fails exactly here - `nonReentrant` writes a slot before the body runs, so a
    ///      static call reverts with empty returndata against a perfectly good pool.
    function test_R22_control_theShippedLenderPoolStillInstalls() public {
        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);
        assertEq(pool.impairedBorrowerCount(), 0, "premise: the incoming set is empty");

        vm.prank(admin);
        credit.setLenderPool(address(pool));
        assertEq(credit.lenderPool(), address(pool), "the probe refused the real contract");

        // And it installs before the pool has been pointed back at this manager, which is a legal
        // wiring order and the one that makes `recoverLoss(0)` answer `NotCreditManager` rather than
        // `ZeroAmount`. Either answer is returndata, which is the whole of the test.
        assertEq(pool.creditManager(), address(0), "premise: the pointer back is not set yet");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 27 item 2, carried as round 28 item 3: `setLiquiditySource`
    // probed NOTHING at all, while `borrow` calls `lend` on that pointer bare.
    //
    // The reason it survived two rounds is a sentence in the file it is in.
    // `CreditManager.owedToSource` says "a selector probe on `setLiquiditySource`
    // does nothing either, because the break is dynamic: the source answered
    // perfectly until it was frozen". True, and about round 22's blacklisted
    // treasury. A pointer that is WRONG ON THE DAY IT IS WRITTEN is a different
    // failure with a different remedy, and it is the one these tests are about.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A funder that answers `repayPrincipal` and `available` but not `lend` is refused at
    ///         wiring time rather than at the first borrow.
    /// @dev MEASURED with the `_requireWiringRan(CreditWiring.checkLiquiditySourceSwap(...))` line
    ///      commented out of `setLiquiditySource`, which is the pre-fix contract: the stub below
    ///      **installed with no complaint**, `credit.liquiditySource()` read the stub, and
    ///      `borrow(2515000000)` then reverted with **returndata length 0** - a missing selector,
    ///      with no error to diagnose it by. Not one borrower, every borrower: `borrow` is the only
    ///      caller and the pointer is protocol-wide.
    ///
    ///      That is the same evidence and the same shape round 22's finding 21 measured one pointer
    ///      over on `recoverLoss`, which is the point - this pointer was left out of a rule this
    ///      file has now applied four times.
    function test_R28_aFunderMissingLendIsRefusedAtWiringTime() public {
        SourceWithoutLend stub = new SourceWithoutLend();
        address before_ = credit.liquiditySource();

        vm.prank(admin);
        vm.expectRevert(CreditManager.LiquiditySourceIncomplete.selector);
        credit.setLiquiditySource(address(stub));

        assertEq(credit.liquiditySource(), before_, "the incomplete funder installed anyway");
    }

    /// @notice The same for `repayPrincipal`, which `settlePrincipal` calls bare through
    ///         `pullPrincipal`'s non-`bestEffort` branch.
    /// @dev The second of the two bare selectors, and it is probed for its own reasons rather than
    ///      as a freebie: a funder missing this one lends perfectly and then strands every repaid
    ///      principal, because `settlePrincipal` is the hard branch and reverts.
    function test_R28_aFunderMissingRepayPrincipalIsRefusedAtWiringTime() public {
        SourceWithoutRepayPrincipal stub = new SourceWithoutRepayPrincipal();

        vm.prank(admin);
        vm.expectRevert(CreditManager.LiquiditySourceIncomplete.selector);
        credit.setLiquiditySource(address(stub));
    }

    /// @notice **PREMISE.** The absent selector really does carry no returndata, and a present one
    ///         that refuses really does carry four bytes - which is the whole basis of the probe.
    /// @dev Asserted directly against the stubs rather than inferred from the setter's behaviour.
    ///      A probe that reads the *shape* of a failure is only as good as that distinction, and
    ///      this is the one arm that measures it rather than assuming it. It is also what `borrow`
    ///      would surface to a borrower against a wrongly-pointed funder: `ok == false` with
    ///      nothing to decode.
    function test_R28_shape_theAbsentSelectorCarriesNoReturndataAndARefusalCarriesFour() public {
        SourceWithoutLend absent = new SourceWithoutLend();
        RefusingButCompleteSource present = new RefusingButCompleteSource();

        (bool okAbsent, bytes memory absentData) = address(absent).call(abi.encodeCall(ILiquiditySource.lend, (1)));
        (bool okPresent, bytes memory presentData) = address(present).call(abi.encodeCall(ILiquiditySource.lend, (1)));

        emit log_named_uint("MEASURED returndata bytes, selector absent", absentData.length);
        emit log_named_uint("MEASURED returndata bytes, selector present and refusing", presentData.length);

        assertFalse(okAbsent, "premise: the absent selector must revert");
        assertEq(absentData.length, 0, "an absent selector must carry no returndata");
        assertFalse(okPresent, "premise: this stub refuses");
        assertEq(presentData.length, 4, "a refusal must carry its error selector");
    }

    /// @notice **CONTROL, and the arm this probe most needs.** A funder that answers both selectors
    ///         and *refuses* both of them installs. Success is not required and must not be.
    /// @dev The failure mode of a returndata-shape probe is refusing the thing it was written to
    ///      accept. Both in-tree sources gate both members on `onlyCreditManager`, and the legal
    ///      wiring order installs the funder here **before** pointing it back at this manager - so
    ///      `NotCreditManager()` is the ordinary answer at the probe and a success probe would have
    ///      rejected the real contracts outright.
    function test_R28_control_aFunderThatRefusesBothProbesStillInstalls() public {
        RefusingButCompleteSource stub = new RefusingButCompleteSource();

        vm.prank(admin);
        credit.setLiquiditySource(address(stub));

        assertEq(credit.liquiditySource(), address(stub), "the probe refused a complete funder");
    }

    /// @notice **CONTROL against the real contract**, which is the only thing that can rule out a
    ///         probe that refuses what it was written to accept.
    /// @dev Two arms, because the two in-tree sources answer the probes differently and both have
    ///      to pass. A fresh `TreasuryLiquiditySource` has no pointer back yet, so both probes
    ///      answer `NotCreditManager()`. A fresh `LenderPool` is the same on `repayPrincipal` and
    ///      also has to clear `checkLenderPoolSwap`, since a pool funder carries the sink with it.
    function test_R28_control_theShippedSourcesStillInstall() public {
        TreasuryLiquiditySource fresh = new TreasuryLiquiditySource(usdc, admin);
        assertEq(fresh.creditManager(), address(0), "premise: the pointer back is not set yet");

        vm.prank(admin);
        credit.setLiquiditySource(address(fresh));
        assertEq(credit.liquiditySource(), address(fresh), "the probe refused the shipped treasury");

        LenderPool pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.prank(admin);
        credit.setLiquiditySource(address(pool));
        assertEq(credit.liquiditySource(), address(pool), "the probe refused the shipped pool");
        assertEq(credit.lenderPool(), address(pool), "and the sink must still be carried with it");
    }

    /// @notice **CONTROL for the sentence that nearly stopped this probe being written.** Round
    ///         22's finding is untouched: a source that answers both selectors and later refuses
    ///         to be repaid still parks its principal rather than blocking the repoint.
    /// @dev The distinction stated as an executable rather than as prose. `RefusingButCompleteSource`
    ///      is *complete* and *broken*, which is exactly the round-22 shape - the source that
    ///      "answered perfectly until it was frozen" - and this probe waves it through, because no
    ///      probe of any shape can see a freeze that has not happened yet. If a later round makes
    ///      this test red by tightening the probe into a conformance suite, the round-22 escape has
    ///      been closed by accident and the money can be stranded again.
    function test_R28_control_theProbeDoesNotReopenTheFrozenSourceFinding() public {
        RefusingButCompleteSource frozen = new RefusingButCompleteSource();
        vm.prank(admin);
        credit.setLiquiditySource(address(frozen));

        // Straight back out again, which is the escape audit round 22 finding 5 installed.
        vm.prank(admin);
        credit.setLiquiditySource(address(liquidity));
        assertEq(credit.liquiditySource(), address(liquidity), "the repoint away from a broken source was blocked");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // The round-24 remediation, follow-up item 6: the three silent wiring setters.
    //
    // Until this commit `CollateralVault`'s three setters were the only ones in `src/` that moved
    // a pointer without announcing it, on the one contract in the graph that cannot be replaced.
    // Every test below moves a pointer that is ALREADY SET: `setUp`'s deploy path has already made
    // all three zero-to-something moves, and a first wiring is not the case the finding is about.
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice `setCustodyAdapter` announces the move.
    /// @dev Withdrawing first is not incidental: `AdapterHasLivePosition` refuses a repoint over a
    ///      live stake, so an idle outgoing adapter is the only state in which this setter reaches
    ///      its assignment at all.
    function test_R25_theVaultAnnouncesACustodyAdapterMove() public {
        vm.prank(alice);
        vault.withdrawBonds(BONDS);

        TwoViewAdapter incoming = new TwoViewAdapter(address(vault));
        assertTrue(address(vault.custodyAdapter()) != address(incoming), "premise: this is a move");

        vm.expectEmit(true, false, false, true, address(vault));
        emit CollateralVault.CustodyAdapterSet(address(incoming));
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(incoming)));

        assertEq(address(vault.custodyAdapter()), address(incoming), "premise: the pointer moved");
    }

    /// @notice `setCreditManager` announces the move.
    function test_R25_theVaultAnnouncesACreditManagerMove() public {
        CreditManager incoming = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        assertEq(vault.creditManager(), address(credit), "premise: this is a move, not a first wiring");

        vm.expectEmit(true, false, false, true, address(vault));
        emit CollateralVault.CreditManagerSet(address(incoming));
        vm.prank(admin);
        vault.setCreditManager(address(incoming));

        assertEq(vault.creditManager(), address(incoming), "premise: the pointer moved");
    }

    /// @notice `setLiquidationAuction` announces the move - the half of the divergence that was
    ///         invisible.
    function test_R25_theVaultAnnouncesALiquidationAuctionMove() public {
        LiquidationAuction incoming = _freshAuction();
        assertEq(vault.liquidationAuction(), address(auction), "premise: this is a move");

        vm.expectEmit(true, false, false, true, address(vault));
        emit CollateralVault.LiquidationAuctionSet(address(incoming));
        vm.prank(admin);
        vault.setLiquidationAuction(address(incoming));

        assertEq(vault.liquidationAuction(), address(incoming), "premise: the pointer moved");
    }

    /// @notice The property the whole finding rests on, asserted rather than assumed: ONE
    ///         `eth_getLogs` topic filter catches both halves of the auction-pointer pair.
    /// @dev `CreditManager.borrow` reverts `AuctionPointerMismatch` when this contract's
    ///      `liquidationAuction` and the manager's disagree, and before this commit only the
    ///      manager's half was on chain. Emitting *something* is not enough to close that: an
    ///      event's `topic0` is its name AND arity, so a vault-side
    ///      `LiquidationAuctionSet(address,address)` - the shape that would also carry the outgoing
    ///      address - would sit under a different `topic0` from the manager's and the one whole-
    ///      protocol subscription that catches a divergence would still see one side only. This is
    ///      the test that makes that a checked property instead of a comment, and it is the reason
    ///      the new events match the tree's arity rather than the more informative shape.
    function test_R25_bothHalvesOfTheAuctionPointerShareOneTopic0() public {
        bytes32 signature = keccak256("LiquidationAuctionSet(address)");
        LiquidationAuction incoming = _freshAuction();

        vm.recordLogs();
        vm.startPrank(admin);
        vault.setLiquidationAuction(address(incoming));
        credit.setLiquidationAuction(address(incoming));
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool fromVault;
        bool fromManager;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != signature) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(incoming)))), "wrong pointer logged");
            if (logs[i].emitter == address(vault)) fromVault = true;
            if (logs[i].emitter == address(credit)) fromManager = true;
        }
        assertTrue(fromVault, "the vault's move is invisible to the shared filter");
        assertTrue(fromManager, "premise: the manager's move is visible to the shared filter");
    }

    /// @notice The same shared-filter property for the manager pointer, which four contracts hold.
    /// @dev `CollateralVault.creditManager` is the reference every one of those four is checked
    ///      against - `LiquidationAuction.setCreditManager` reads it by name to refuse a manager
    ///      the vault has never used - and it was the only one of the five that moved silently.
    function test_R25_theVaultsManagerMoveSharesOneTopic0WithTheOtherHolders() public {
        bytes32 signature = keccak256("CreditManagerSet(address)");
        CreditManager incoming = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        vm.recordLogs();
        vm.startPrank(admin);
        vault.setCreditManager(address(incoming));
        liquidity.setCreditManager(address(incoming));
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool fromVault;
        bool fromSource;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != signature) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(incoming)))), "wrong pointer logged");
            if (logs[i].emitter == address(vault)) fromVault = true;
            if (logs[i].emitter == address(liquidity)) fromSource = true;
        }
        assertTrue(fromVault, "the vault's move is invisible to the shared filter");
        assertTrue(fromSource, "premise: the treasury source's move is visible to the shared filter");
    }
    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 24, follow-up item 3. `borrow`'s bare `creditManager()`.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **THE REGRESSION.** An auction answering every selector both setters probe, and not
    ///         `creditManager()`, used to install through both - and every borrow in the protocol
    ///         then reverted.
    /// @dev `CreditManager.borrow` reads `ILiquidationAuction(auction).creditManager()` bare inside
    ///      its `vaultAuction != address(0)` branch and reverts `AuctionPointerMismatch` on the
    ///      answer. Nothing probed that selector. MEASURED at round 24 with the eight-selector stub
    ///      below: it installed cleanly, every subsequent `borrow` reverted, reproduced for a second
    ///      borrower, and recovery was repointing both pointers - two 48-hour timelock operations
    ///      with all borrowing offline in between.
    ///
    ///      `CreditWiring.checkAuctionSwap`'s own comment predicted this: "if that function gains a
    ///      fourth external call, it gains a fourth probe here in the same commit". It was already
    ///      owed, because the fourth bare call is not `_impairmentFor`'s - it is `borrow`'s. The
    ///      rule has to be read as every selector the protocol calls bare on this pointer, not every
    ///      selector one function does; the per-function reading is what let it through four rounds
    ///      running.
    ///
    ///      The assertion is that the *manager's* setter refuses, which is sufficient: the brick
    ///      needs the manager's pointer to be the stub, and with the vault's pointer alone moved
    ///      `borrow` stops at `AuctionPointerMismatch` in the ordinary migration-window state that
    ///      moving both pointers repairs.
    function test_R24_anAuctionMissingCreditManagerIsRefusedAtWiringTime() public {
        EightSelectorAuction stub = new EightSelectorAuction(address(vault), address(riskParams), address(oracle));

        vm.prank(admin);
        vm.expectRevert(CreditManager.LiquidationAuctionIncomplete.selector);
        credit.setLiquidationAuction(address(stub));

        assertEq(credit.liquidationAuction(), address(auction), "the incomplete auction installed anyway");
    }

    /// @notice The premise, asserted rather than argued: the stub clears every other clause on this
    ///         path, so the new probe is the only thing refusing it.
    /// @dev Without this arm the test above could be green because the stub fails an older check -
    ///      the trap round 21's own PoC fell into, which this file already records once. The vault's
    ///      twin setter probes `vault()`, `riskParams()` and `navOracle()` and nothing else, so it
    ///      accepts the stub outright, and that acceptance is the measurement.
    function test_R24_premise_theStubClearsEveryOtherClauseAndTheVaultAcceptsIt() public {
        EightSelectorAuction stub = new EightSelectorAuction(address(vault), address(riskParams), address(oracle));

        assertEq(stub.vault(), address(vault), "premise: the vault clause passes");
        assertEq(stub.riskParams(), address(riskParams), "premise: the riskParams clause passes");
        assertEq(stub.navOracle(), address(oracle), "premise: the navOracle clause passes");
        assertEq(stub.workoutsOpenFor(address(0)), 0, "premise: the first completeness probe passes");
        assertEq(stub.auctionOf(address(0)), 0, "premise: the second completeness probe passes");
        assertEq(stub.recognisedRecoveryOf(address(0)), 0, "premise: the third completeness probe passes");

        vm.prank(admin);
        vault.setLiquidationAuction(address(stub));
        assertEq(vault.liquidationAuction(), address(stub), "premise: the vault's probe list accepts it");
    }

    /// @notice **CONTROL, and the sign check on the shape of the fix.** The shipped
    ///         `LiquidationAuction` installs while its own `creditManager` is still `address(0)`.
    /// @dev The obvious stronger form - requiring `creditManager() == address(this)` - was refused,
    ///      and this is the measurement that refuses it. `LiquidationAuction.creditManager` is a
    ///      plain public `address` starting at zero, and its `setCreditManager` carries a
    ///      `CreditManagerNotLive` clause requiring the vault to already name the incoming manager.
    ///      So the only legal order is this setter first and the auction's return leg second, which
    ///      is what `DeployBase.sol`, this file's own `setUp` and every other fixture in the tree do.
    ///      An equality assertion would refuse that order and weld the pair shut - the
    ///      mutually-unsatisfiable window this codebase has already shipped three times. Existence
    ///      is the whole of the question, and this arm is what keeps the fix at existence.
    function test_R24_control_aFreshAuctionInstallsBeforeItsReturnLegIsWired() public {
        LiquidationAuction auctionB = _freshAuction();
        assertEq(auctionB.creditManager(), address(0), "premise: the pointer back is not set yet");

        vm.startPrank(admin);
        credit.setLiquidationAuction(address(auctionB));
        vault.setLiquidationAuction(address(auctionB));
        auctionB.setCreditManager(address(credit));
        vm.stopPrank();

        assertEq(credit.liquidationAuction(), address(auctionB), "the probe refused the real contract");
        assertEq(auctionB.creditManager(), address(credit), "and the return leg still follows");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 25 F4. `liquidate`'s bare `start(address,address)`.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **THE REGRESSION.** An auction answering the nine selectors both setters otherwise
    ///         probe, and not `start`, used to install through both - and every liquidation in the
    ///         protocol then reverted with no error to diagnose it by.
    /// @dev `CreditManager.liquidate` reads `ILiquidationAuction(auction).start(borrower,
    ///      msg.sender)` bare and captures its return value as the key the bounty escrow parks
    ///      against. Nothing probed that selector. MEASURED at round 25 with the ten-selector stub
    ///      below: it installed through both setters, and on a genuinely liquidatable position
    ///      `liquidate(alice)` reverted with empty returndata for two independent callers. Recovery
    ///      is repointing both pointers - two 48-hour timelock operations with liquidation offline
    ///      in between, and an underwater position that cannot be seized for the whole of it.
    ///
    ///      This is the fifth bare selector and the round after the fourth. Round 24 rewrote the
    ///      rule into "every selector the protocol calls bare on this pointer, not every selector
    ///      one function does" and then enumerated the set one short; `CreditWiring
    ///      .checkAuctionSwap` now writes the enumeration out from the type rather than leaving it
    ///      to be re-derived.
    function test_R25_anAuctionMissingStartIsRefusedAtWiringTime() public {
        TenSelectorAuction stub =
            new TenSelectorAuction(address(vault), address(riskParams), address(oracle), address(credit));

        vm.prank(admin);
        vm.expectRevert(CreditManager.LiquidationAuctionIncomplete.selector);
        credit.setLiquidationAuction(address(stub));

        assertEq(credit.liquidationAuction(), address(auction), "the incomplete auction installed anyway");
    }

    /// @notice The premise, asserted rather than argued: the stub clears every other clause on this
    ///         path, so the new probe is the only thing refusing it.
    /// @dev Without this arm the test above could be green because the stub fails an older check -
    ///      the trap round 21's own PoC fell into, and round 24's stub had to be widened for twice.
    ///      The stub answers `creditManager()` as well as the eight round 24's did, because that
    ///      probe now sits one block above the new one and would otherwise be what refuses it.
    function test_R25_premise_theStubClearsEveryOtherClauseAndTheVaultAcceptsIt() public {
        TenSelectorAuction stub =
            new TenSelectorAuction(address(vault), address(riskParams), address(oracle), address(credit));

        assertEq(stub.vault(), address(vault), "premise: the vault clause passes");
        assertEq(stub.riskParams(), address(riskParams), "premise: the riskParams clause passes");
        assertEq(stub.navOracle(), address(oracle), "premise: the navOracle clause passes");
        assertEq(stub.workoutsOpenFor(address(0)), 0, "premise: the first completeness probe passes");
        assertEq(stub.auctionOf(address(0)), 0, "premise: the second completeness probe passes");
        assertEq(stub.recognisedRecoveryOf(address(0)), 0, "premise: the third completeness probe passes");
        assertEq(stub.creditManager(), address(credit), "premise: round 24's probe passes too");

        vm.prank(admin);
        vault.setLiquidationAuction(address(stub));
        assertEq(vault.liquidationAuction(), address(stub), "premise: the vault's probe list accepts it");
    }

    /// @notice **CONTROL, arm one of two.** A freshly deployed real auction, whose own
    ///         `creditManager` is still zero, installs - the probe reads its `NotCreditManager()`
    ///         as proof the selector exists.
    /// @dev This is the arm that stops the probe from rejecting the shipped contract in the only
    ///      wiring order that works. `LiquidationAuction.setCreditManager` requires the vault to
    ///      already name the incoming manager, so this setter always runs first and the auction's
    ///      return leg second - the order `DeployBase.sol` and every fixture in this tree use. A
    ///      probe shipped as a *success* test, or one that read only the `ZeroAddress()` arm, would
    ///      refuse exactly that order.
    function test_R25_control_aFreshAuctionInstallsOnTheNotCreditManagerArm() public {
        LiquidationAuction auctionB = _freshAuction();
        assertEq(auctionB.creditManager(), address(0), "premise: this auction is on the first arm");

        vm.prank(admin);
        credit.setLiquidationAuction(address(auctionB));

        assertEq(credit.liquidationAuction(), address(auctionB), "the probe refused a real auction");
    }

    /// @notice **CONTROL, arm two of two.** An auction already pointed back at this manager installs
    ///         - the probe reads its `ZeroAddress()` instead, and that is a different four bytes.
    /// @dev Reached by re-pointing at the auction `setUp` already wired, which is the state every
    ///      re-point onto an existing auction is in. Both arms need their own test: a probe that
    ///      accepted only one of them would refuse half the legal wiring states, and which arm a
    ///      given auction answers is decided by whether its return leg has run yet - not by
    ///      anything this setter can see.
    function test_R25_control_anAlreadyWiredAuctionInstallsOnTheZeroAddressArm() public {
        assertEq(auction.creditManager(), address(credit), "premise: this auction is on the second arm");

        vm.prank(admin);
        credit.setLiquidationAuction(address(auction));

        assertEq(credit.liquidationAuction(), address(auction), "the probe refused a wired auction");
    }

    /// @notice The measurement the cost claim rests on: both refusal arms carry four bytes, the
    ///         missing selector carries none, and neither arm writes anything.
    /// @dev The probe reads the SHAPE of the failure, not its success, so what matters is that the
    ///      real contract's two refusals are distinguishable from an absent selector. `start`
    ///      refuses in the order `msg.sender != creditManager` then a zero `borrower` or `caller`,
    ///      and both are reached before any write - which is what makes it safe to call a
    ///      state-changing selector as a probe at all. `liveAuctionCount()` is asserted after each
    ///      arm because "reverts before any write" is the whole of that safety argument and is
    ///      cheaper to measure than to reason about.
    function test_R25_shape_bothRefusalArmsCarryFourBytesAndTheAbsentSelectorCarriesNone() public {
        bytes memory probe = abi.encodeWithSignature("start(address,address)", address(0), address(0));

        LiquidationAuction fresh = _freshAuction();
        (bool okFresh, bytes memory freshReason) = address(fresh).call(probe);
        assertFalse(okFresh, "the probe opened an auction on an unwired contract");
        assertEq(freshReason.length, 4, "the first arm did not carry four bytes");
        assertEq(bytes4(freshReason), LiquidationAuction.NotCreditManager.selector, "wrong error on the first arm");
        assertEq(fresh.liveAuctionCount(), 0, "the first arm wrote an auction");

        vm.prank(address(credit));
        (bool okWired, bytes memory wiredReason) = address(auction).call(probe);
        assertFalse(okWired, "the probe opened an auction on a wired contract");
        assertEq(wiredReason.length, 4, "the second arm did not carry four bytes");
        assertEq(bytes4(wiredReason), LiquidationAuction.ZeroAddress.selector, "wrong error on the second arm");
        assertEq(auction.liveAuctionCount(), 0, "the second arm wrote an auction");

        TenSelectorAuction stub =
            new TenSelectorAuction(address(vault), address(riskParams), address(oracle), address(credit));
        (bool okStub, bytes memory stubReason) = address(stub).call(probe);
        assertFalse(okStub, "the stub answered a selector it does not have");
        assertEq(stubReason.length, 0, "the absent selector answered with data, so the probe cannot see it");
    }

    /// @notice **WHY THE VAULT'S TWIN SETTER DOES NOT GET THIS PROBE, MEASURED RATHER THAN ARGUED.**
    ///         With the stub installed on the vault's pointer alone, `liquidate` stops at a named
    ///         `AuctionPointerMismatch` and one call to the vault's own setter puts it back.
    /// @dev The finding notes that the stub installs through *both* setters, which is true and is
    ///      how the measured state was reached. It does not follow that both setters owe the probe.
    ///      `start` is called on `CreditManager.liquidationAuction` and on nothing else -
    ///      `CollateralVault` never calls it, and uses its own pointer only as a `msg.sender`
    ///      comparison in `seize`, `reassign` and `creditLiquidationProceeds`. So with the probe on
    ///      the manager's setter the manager's pointer can never name an address that cannot answer
    ///      `start`, and the bare call has nowhere left to land.
    ///
    ///      What the vault-only install leaves behind is measured below and is a different animal
    ///      from the finding's state: the two pointers disagree, which is the ordinary
    ///      migration-window condition `liquidate` already refuses **by name**, giving an operator
    ///      the diagnosis the empty revert denied them - and the repair is one timelock operation
    ///      on the vault, not two with liquidation offline in between. Adding a second copy of the
    ///      probe would buy a marginally earlier refusal on a recoverable state, at the price of a
    ///      second enumeration of the auction's call set that can drift from this one. This
    ///      codebase has already paid for two lists that were meant to agree and did not.
    function test_R25_theVaultOnlyInstallIsDiagnosableAndRecoverableInOneOperation() public {
        TenSelectorAuction stub =
            new TenSelectorAuction(address(vault), address(riskParams), address(oracle), address(credit));

        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(_crashedNav());

        // The manager's setter refuses it; only the vault's accepts.
        vm.prank(admin);
        vm.expectRevert(CreditManager.LiquidationAuctionIncomplete.selector);
        credit.setLiquidationAuction(address(stub));
        vm.prank(admin);
        vault.setLiquidationAuction(address(stub));
        assertEq(vault.liquidationAuction(), address(stub), "premise: the vault took the stub");
        assertEq(credit.liquidationAuction(), address(auction), "premise: the manager did not");

        // Liquidation is refused, and refused by name rather than with empty returndata.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.AuctionPointerMismatch.selector, address(auction), address(stub))
        );
        credit.liquidate(alice);

        // One operation on the one setter that moved puts it back, and the position is seizable.
        vm.prank(admin);
        vault.setLiquidationAuction(address(auction));
        vm.prank(keeper);
        credit.liquidate(alice);
        assertEq(auction.auctionOf(alice), 1, "the position could not be liquidated after the repair");
    }
}

/// @notice An auction answering every selector both `setLiquidationAuction` setters probe - three on
///         the vault's list, six on the manager's, eight distinct - and not `creditManager()`.
/// @dev Not a rug: this is an operator installing an auction built against the interface as it stood
///      before `borrow` started reading the pointer back, or one whose ABI has drifted by a single
///      member. Everything it does not answer reverts with no data, which is what the probe reads.
///
///      The two outgoing counters are here as well as the six incoming members, because once it has
///      installed it becomes the *outgoing* pointer and the repoint that would undo the damage reads
///      them. An auction that cannot answer those is round 19's finding, not this one, and this stub
///      deliberately fails exactly the one clause under test.
contract EightSelectorAuction {
    address public immutable vault;
    address public immutable riskParams;
    address public immutable navOracle;

    constructor(address vault_, address riskParams_, address navOracle_) {
        vault = vault_;
        riskParams = riskParams_;
        navOracle = navOracle_;
    }

    function liveAuctionCount() external pure returns (uint256) {
        return 0;
    }

    function openWorkoutCount() external pure returns (uint256) {
        return 0;
    }

    function workoutsOpenFor(address) external pure returns (uint256) {
        return 0;
    }

    function auctionOf(address) external pure returns (uint256) {
        return 0;
    }

    function recognisedRecoveryOf(address) external pure returns (uint256) {
        return 0;
    }

    // No creditManager().
}

/// @notice An auction answering every selector both `setLiquidationAuction` setters probe as of
///         round 24 - three on the vault's list, nine distinct across the two - and not
///         `start(address,address)`.
/// @dev Round 25's stub is round 24's plus `creditManager()`, because that probe now stands one
///      block above the one under test and would otherwise be what refuses this. A stub that fails
///      an older clause makes a test green for the wrong reason, which this file has recorded twice
///      and is the reason each of these stubs is one selector short of complete rather than
///      several.
///
///      Not a rug. This is an operator installing an auction built against the interface as it
///      stood before the bounty escrow made `start` return an id, or one whose ABI has drifted by a
///      single member. Everything it does not answer reverts with no data, which is what the probe
///      reads.
///
///      `creditManager` is a constructor argument rather than a settable pointer because this stub
///      is never wired back to anything: it exists to be refused, and the value only has to be
///      whatever makes round 24's probe pass so that round 25's is the clause under test.
contract TenSelectorAuction {
    address public immutable vault;
    address public immutable riskParams;
    address public immutable navOracle;
    address public immutable creditManager;

    constructor(address vault_, address riskParams_, address navOracle_, address creditManager_) {
        vault = vault_;
        riskParams = riskParams_;
        navOracle = navOracle_;
        creditManager = creditManager_;
    }

    function liveAuctionCount() external pure returns (uint256) {
        return 0;
    }

    function openWorkoutCount() external pure returns (uint256) {
        return 0;
    }

    function workoutsOpenFor(address) external pure returns (uint256) {
        return 0;
    }

    function auctionOf(address) external pure returns (uint256) {
        return 0;
    }

    function recognisedRecoveryOf(address) external pure returns (uint256) {
        return 0;
    }

    // No start(address,address).
}

/// @notice A pool answering every `ILenderPool` member this manager calls, except `recoverLoss`.
/// @dev Not a rug: this is an operator installing a pool built against the interface as it stood
///      before audit round 21 added the member. Everything it does not answer reverts with no data,
///      which is what the probe looks for.
contract PoolWithoutRecoverLoss {
    function exitReserve() external pure returns (uint256) {
        return 0;
    }

    function outstandingPrincipal() external pure returns (uint256) {
        return 0;
    }

    function totalImpairment() external pure returns (uint256) {
        return 0;
    }

    function impairedBorrowerCount() external pure returns (uint256) {
        return 0;
    }

    function impairedBorrowerAt(uint256) external pure returns (address) {
        return address(0);
    }

    function setLossReserves(uint256, uint256) external {}
    // No recoverLoss.
}

/// @notice The same, missing `impairedBorrowerAt` instead.
contract PoolWithoutImpairedBorrowerAt {
    error ZeroAmount();

    function exitReserve() external pure returns (uint256) {
        return 0;
    }

    function outstandingPrincipal() external pure returns (uint256) {
        return 0;
    }

    function totalImpairment() external pure returns (uint256) {
        return 0;
    }

    function impairedBorrowerCount() external pure returns (uint256) {
        return 0;
    }

    function recoverLoss(uint256) external pure {
        revert ZeroAmount();
    }

    function setLossReserves(uint256, uint256) external {}
    // No impairedBorrowerAt.
}

/// @notice A funder answering `repayPrincipal` and `available` and not `lend`.
/// @dev Not a rug: this is an operator pointing the funder at a contract built against an earlier
///      shape of the interface, or at the wrong address entirely. Everything it does not answer
///      reverts with no data, which is what the probe looks for - and, before the probe existed,
///      what every borrower got out of `borrow`.
contract SourceWithoutLend {
    error NotCreditManager();

    function repayPrincipal(uint256) external pure {
        revert NotCreditManager();
    }

    function available() external pure returns (uint256) {
        return 0;
    }
    // No lend.
}

/// @notice The same, missing `repayPrincipal` instead - the selector `settlePrincipal` calls bare.
contract SourceWithoutRepayPrincipal {
    error NotCreditManager();

    function lend(uint256) external pure {
        revert NotCreditManager();
    }

    function available() external pure returns (uint256) {
        return 0;
    }
    // No repayPrincipal.
}

/// @notice A funder that answers both bare selectors and refuses both of them.
/// @dev **The control the probe most needs, and the round-22 shape.** Both in-tree sources gate
///      `lend` and `repayPrincipal` on `onlyCreditManager`, so at a legal wiring order the ordinary
///      answer to both probes is a refusal - and a refusal carries four bytes, which is what proves
///      the selector is there. It is also a stand-in for the source that "answered perfectly until
///      it was frozen": complete, broken, and correctly waved through.
contract RefusingButCompleteSource {
    error NotCreditManager();

    function lend(uint256) external pure {
        revert NotCreditManager();
    }

    function repayPrincipal(uint256) external pure {
        revert NotCreditManager();
    }

    function available() external pure returns (uint256) {
        return 0;
    }
}
