// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

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
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Audit round 46, Medium. Falsifier for the fix in
///         `LiquidationAuction.closeWorkout`.
///
///         `closeWorkout`'s clean branch bounds the borrower's booking by
///         `usdc.balanceOf(this) + claimableOf(this) + pendingYieldOf(this) - spokenFor`. Two of
///         those three terms are claims on the credit manager, and they are not equally durable:
///         `claimableOf` is named by the solvency invariant's `totalClaimable` term and by
///         `CreditManager.migrateReserves`'s `spokenFor` line, so a migration must leave it behind;
///         `pendingYieldOf` is named by nothing, and is exactly the "accrued but not settled"
///         balance `migrateReserves`'s own docstring says such a holder loses.
///
///         The auction is such a holder on purpose - `reassign` parks the lot under its ledger
///         entry and `disposeWorkoutLot` cannot run until after the close - so before the fix the
///         booking was made ENTIRELY against the destructible term in the ordinary case. A
///         sanctioned zero-debt migration then relabelled that money as the incoming manager's
///         insurance and left a permanent unbacked liability on an immutable contract.
///
///         The fix is one call, `try ICreditManager(cm).settle(address(this)) {} catch {}`,
///         immediately before the `earned` computation. The `try` is NOT there for the reason the
///         finding gave - see `test_R46_negative_neitherPointerCanBeDetachedWhileAWorkoutIsOpen`,
///         which measures that a detached manager is unreachable at that instant.
///
///         🟥 **AND THE REASON THIS FILE THEN GAVE WAS FALSE, refuted by execution in audit round
///         51.** It said the `try` is there "because `settle` reaches `_pushUsdc`, and
///         `closeWorkout` is the exit of last resort". `settle` reaches no `_pushUsdc` at all:
///         `settle` -> `_settleLive` -> `_settle` makes only vault reads plus two `try`/`catch`ed
///         internal calls, and every `_pushUsdc` site in the manager is in `borrow`,
///         `_claimSurplus`, `_claimBounty` or `flushPrincipalTo`. EXECUTED with the auction
///         `blocked` on the token: `settle(address(auction))` SUCCEEDS and the close books the
///         identical figure. The `try` stays on its ORIGINAL ground after all - `settle` carries
///         `whileAttached`, which is the one revert it has - and `closeWorkout` is the exit of
///         last resort, so it must not depend on the pointer it exists to unwind around.
///
///         Every assertion here describes the FIXED behaviour. NEUTER MEASURED: remove the settle
///         call from `closeWorkout` and three of the five go red - the migration case and the
///         negative at "the close did not settle the auction's position: 0 < 999999999", and the
///         sweep case with `NothingToClaim()`, the phantom refusing it over free USDC. The
///         `claimableOf` assertion catches it one statement before "paid == booked" does, which is
///         why it is stated rather than left implicit.
contract R46WorkoutCloseSettles is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
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
    TreasuryLiquiditySource internal treasury;
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
    }

    // -- helpers -------------------------------------------------------------

    /// @dev Borrow at the ceiling, crash NAV past debt parity, liquidate, let the six-hour window
    ///      lapse and take the exit of last resort. Leaves one open workout holding the whole lot.
    function _openWorkout() internal returns (uint256 id) {
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(alice);
        credit.borrow(debt);

        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);

        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: no auction opened");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(alice), 1, "fixture: no workout opened");
    }

    /// @dev Deliver one epoch of borrower-side yield and let the whole stream land. The auction
    ///      holds every bond by now, so the whole stream accrues to its position and none of it is
    ///      settled - which is the quantity under test.
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

    /// @dev A third party clears the defaulted debt with the permissionless `repayFor`, which is
    ///      what makes the close CLEAN: `residual == 0`, no time gate, nothing written down.
    function _rescueDebt() internal {
        uint256 owed = credit.currentDebtOf(alice);
        usdc.mint(rescuer, owed);
        vm.startPrank(rescuer);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 0, "fixture: debt not cleared");
    }

    /// @dev The sanctioned zero-debt manager migration: a virgin second manager on the same vault,
    ///      risk params and oracle, installed by the owner, then the reserve sweep. Nothing here is
    ///      adversarial.
    ///
    ///      🟥 **Round 55 made the disposal a step of it, and took the `id` for that reason.** The
    ///      sentence that used to end this docstring - "nothing in the protocol refuses any step of
    ///      it" - is no longer true of a lot still parked under the auction:
    ///      `CollateralVault.setCreditManager` now carries the `heldLot` arm both its siblings
    ///      already had, and refuses. `disposeWorkoutLot` is the owner-gated call the refusal
    ///      points at, it is reachable in exactly the refused state, and it is what a DexFi
    ///      redemption needs anyway - so the migration is one call longer and nothing this file
    ///      measures changes. Taking the `id` rather than hiding the disposal makes the extra step
    ///      visible at every call site.
    function _migrate(uint256 id) internal returns (CreditManager next) {
        next = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        vm.prank(admin);
        auction.disposeWorkoutLot(id, alice);
        assertEq(vault.bondCount(address(auction)), 0, "fixture: the closed lot is still parked");
        vm.prank(admin);
        vault.setCreditManager(address(next));
        vm.prank(admin);
        credit.migrateReserves();
    }

    // -- the falsifiers ------------------------------------------------------

    /// @notice THE FIX. A cleanly-closed workout's booking survives a manager migration, because
    ///         the close settles this contract's own position first and so books against the term
    ///         the sweep must leave behind rather than the one it destroys.
    ///
    ///         Neuter: delete the `try ... settle ...` line from `closeWorkout` and this goes red
    ///         at "the booking was met in full" with `paid == 0`, the incoming manager's insurance
    ///         holding the whole 999999999 instead of one wei of rounding dust.
    function test_R46_aCleanCloseSurvivesAManagerMigration() public {
        uint256 id = _openWorkout();
        _streamEpoch(EPOCH);

        assertEq(credit.claimableOf(address(auction)), 0, "fixture: the auction already held settled surplus");
        uint256 pendingBefore = credit.pendingYieldOf(address(auction));
        assertGt(pendingBefore, 0, "fixture: the workout lot earned nothing");

        _rescueDebt();
        auction.closeWorkout(id);

        uint256 booked = auction.totalWorkoutYieldOwed();
        assertGt(booked, 0, "the clean close booked nothing");

        // The close converted the unsettled claim into the NAMED `totalClaimable` term, which is
        // what makes the booking durable.
        assertGe(credit.claimableOf(address(auction)), booked, "the close did not settle the auction's position");

        CreditManager next = _migrate(id);

        uint256 paidBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        uint256 paid = usdc.balanceOf(alice) - paidBefore;

        emit log_named_uint("booked", booked);
        emit log_named_uint("paid  ", paid);
        emit log_named_uint("incoming manager insurance", next.insuranceFund());

        assertEq(paid, booked, "the booking was met in full");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "something is still reserved");
        // Only rounding dust the stream could not divide should have been swept.
        assertLt(next.insuranceFund(), booked, "the migration swept the borrower's yield");
    }

    /// @notice THE SIZE OF THE BOOKING IS UNCHANGED, which is the half of the sign check that
    ///         matters: `reachable` sums `claimableOf + pendingYieldOf`, and settling moves value
    ///         between those two terms without changing the sum. So the fix moves where the backing
    ///         lives, not how much is booked, and cannot regress audit round 22 finding 18 in the
    ///         under-booking direction.
    ///
    ///         The measured figure is pinned rather than asserted loosely: the whole epoch, less
    ///         the one wei of stream rounding, is booked either way.
    function test_R46_theCloseBooksTheWholeAccrualJustAsBefore() public {
        uint256 id = _openWorkout();
        _streamEpoch(EPOCH);

        uint256 pendingBefore = credit.pendingYieldOf(address(auction));
        _rescueDebt();
        auction.closeWorkout(id);

        uint256 booked = auction.totalWorkoutYieldOwed();
        emit log_named_uint("pending at close", pendingBefore);
        emit log_named_uint("booked          ", booked);
        assertEq(booked, pendingBefore, "the booking is no longer the whole accrual");
        assertEq(booked, EPOCH - 1, "the booking is not the epoch less its rounding wei");
    }

    /// @notice CONTROL, unchanged by the fix. Settling the auction's position by hand before the
    ///         migration - the permissionless call that used to be the whole difference - still
    ///         pays in full. It is now redundant rather than load-bearing, and a control that broke
    ///         would mean the fix had changed something other than the term the booking rests on.
    function test_R46_control_anExplicitSettleBeforeMigrationIsStillEnough() public {
        uint256 id = _openWorkout();
        _streamEpoch(EPOCH);
        _rescueDebt();
        auction.closeWorkout(id);

        uint256 booked = auction.totalWorkoutYieldOwed();
        assertGt(booked, 0, "fixture: the clean close booked nothing");

        credit.settle(address(auction));
        _migrate(id);

        uint256 paidBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - paidBefore, booked, "control: the booking was not met in full");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "control: something is still reserved");
    }

    /// @notice THE RESIDUAL HARM IS GONE. While the phantom stood it sat on the `spokenFor` line of
    ///         both insurance sweeps, so `sweepFreeBalanceToInsurance` was refused over USDC that
    ///         was genuinely free and any USDC arriving later at the immutable auction went to the
    ///         phantom's holder ahead of the fund it belonged to. With the booking paid down there
    ///         is nothing reserved, so the sweep runs and the arriving balance reaches insurance.
    function test_R46_arrivingUsdcReachesInsuranceRatherThanAPhantom() public {
        uint256 id = _openWorkout();
        _streamEpoch(EPOCH);
        _rescueDebt();
        auction.closeWorkout(id);
        uint256 booked = auction.totalWorkoutYieldOwed();
        _migrate(id);

        auction.claimWorkoutYield(id);
        assertEq(auction.totalWorkoutYieldOwed(), 0, "the booking outlived the claim");

        // The auction still points at the outgoing manager, which is the state the sweeps run in.
        uint256 arriving = booked / 2;
        usdc.mint(address(auction), arriving);

        uint256 insuranceBefore = credit.insuranceFund();
        auction.sweepFreeBalanceToInsurance();
        emit log_named_uint("swept to insurance", credit.insuranceFund() - insuranceBefore);
        assertEq(credit.insuranceFund() - insuranceBefore, arriving, "the free balance did not reach insurance");
        assertEq(usdc.balanceOf(address(auction)), 0, "the auction is still holding something");
    }

    /// @notice MEASURED NEGATIVE, and it corrects the finding's own justification for the `try`.
    ///         The report argued the `try` is required because `settle` is `whileAttached` and
    ///         `closeWorkout` must never be blockable. The first half does not hold at this tree:
    ///         BOTH doors to a detached manager refuse while an open workout stands, so the
    ///         detached state cannot be reached at the instant `closeWorkout` runs. Recorded here
    ///         rather than left as an argument, because a justification that names an unreachable
    ///         state is the shape this repository keeps re-finding.
    ///
    ///         🟥 **The ground this docstring then gave was itself false, and audit round 51
    ///         executed the refutation.** It read: "the `try` stays, on the narrower and true
    ///         ground: `settle` reaches `_pushUsdc`, so a real USDC that refuses a transfer to this
    ///         contract - a blocklist, the mutable proxy the repo already models - would otherwise
    ///         brick the exit of last resort". `settle` reaches no `_pushUsdc`: its call graph is
    ///         vault reads plus two `try`/`catch`ed internal calls, and every `_pushUsdc` site sits
    ///         in `borrow`, `_claimSurplus`, `_claimBounty` or `flushPrincipalTo`. EXECUTED with
    ///         the auction `blocked` on the token, transfers to and from it reverting: `settle`
    ///         SUCCEEDS, `claimableOf` becomes non-zero, and the close books the identical figure.
    ///
    ///         **So the `try` stays on the ORIGINAL ground, which this test narrows rather than
    ///         retires.** `settle` carries `whileAttached` and that is the only revert it has. This
    ///         test measures that neither pointer can be detached WHILE A WORKOUT IS OPEN, which is
    ///         a statement about today's two doors rather than about the modifier; `closeWorkout`
    ///         is the exit of last resort and must not depend on a pointer it exists to unwind
    ///         around. A justification that names an unreachable state is the shape this repository
    ///         keeps re-finding, and naming a NON-EXISTENT one is the same defect one step further.
    function test_R46_negative_neitherPointerCanBeDetachedWhileAWorkoutIsOpen() public {
        uint256 id = _openWorkout();
        _streamEpoch(EPOCH);
        _rescueDebt();

        CreditManager next = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        // Door one: the vault's own manager pointer.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AuctionHasLiveWork(uint256)", 1));
        vault.setCreditManager(address(next));

        // Door two: the auction's copy of it.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AuctionHasLiveWork(uint256)", 1));
        auction.setCreditManager(address(next));

        // So `settle` is attached and succeeds at the close, and the booking is durable.
        auction.closeWorkout(id);
        assertEq(auction.workoutsOpenFor(alice), 0, "the close did not complete");
        assertGe(
            credit.claimableOf(address(auction)),
            auction.totalWorkoutYieldOwed(),
            "the close did not settle the auction's position"
        );
    }
}
