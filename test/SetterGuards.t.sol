// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
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
    function test_signCheck_theAuctionsReturnLegMustNotCountTheParkedLot() public {
        (, uint256 heldLot) = _parkAClosedWorkoutLot();
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
}
