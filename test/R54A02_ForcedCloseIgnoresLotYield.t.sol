// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

/// @title R54A02 - a forced workout close socialises a loss the lot's own yield is sitting here to cover
/// @notice Audit round 54, finding on `LiquidationAuction.closeWorkout`'s forced branch. Self-contained:
///         this file deploys its own stack and inherits nothing from the repository's fixtures (the
///         fixture is the shape `R53A01_AuctionLeads.t.sol` uses, so the two measure the same stack).
///
/// @dev **The mechanism.** A workout lot stays staked and earns for up to `WORKOUT_MAX_DURATION`,
///      and that accrual lands on the auction's own ledger entry. The design premise for routing it
///      to the insurance fund ("the side of the ledger the default actually damaged") is that it
///      offsets the default. It cannot: since round 51 both sweeps RESERVE every open workout's
///      accrual, so there is no order of permissionless calls in which the lot's yield reaches the
///      fund before `closeWorkout`'s forced branch calls `writeDownLoss`, and `writeDownLoss` spends
///      `insuranceFund` as it stands at that instant. The write-down therefore socialises the whole
///      residual to the funder, and one block later `sweepWorkoutYieldToInsurance` banks the lot's
///      yield as insurance against SOMEBODY ELSE's future default. The funder is short by exactly
///      `min(lotYield, residual)` and the protocol holds that figure.
///
///      The shipped `test_R51_154_aForcedCloseStillGivesTheYieldToInsurance` asserts only that the
///      fund gains something after the close; it never asserts what the write-down socialised, so it
///      does not pin the property this file measures.
///
///      🟩 **CLOSED BY ROUND 55, ITEM 215. This file no longer pins an open state.** The pin that
///      asserted the socialisation to the wei was flipped in the commit that shipped the fix, and
///      the two fix-asserting tests round 54 held back until it shipped were promoted here beside it.
///      The fix: the forced branch takes the closing lot off the open-accrual sums (moved ahead of
///      the branch), `try cm.claimSurplus()`, and hands the auction's whole FREE balance - less
///      liquidation callers' rewards, less booked clean-close yield, less every still-open lot's
///      accrual - to `fundInsurance` best-effort before `writeDownLoss`, with the three-term reserve
///      hoisted into one private `_fundInsuranceWithFree` shared with both sweeps.
///
///      **What it measured, on `f16e6e6` before and after.** Before: `writtenDown` 628,750,000,
///      `fromInsurance` 0, and 499,999,999 banked as insurance one block later out of the same lot.
///      After: `writtenDown` 128,750,001, `fromInsurance` 499,999,999, and the later sweep finds
///      nothing. Sizes on a clean `out/`: `LiquidationAuction` runtime -82 (20,243 to 20,161,
///      margin 4,415), initcode -103; `CreditManager`, the binding arm, byte-identical.
///
///      Nine shipped tests sweep or claim AFTER a forced close and were re-fixtured in the same
///      commit rather than weakened - six in `Impairment.integration.t.sol`,
///      `LiquidationAuction.t.sol::test_sweepWorkoutYieldToInsurance`,
///      `R51A02_OverRealisationDoor.t.sol::test_R51_154_aForcedCloseStillGivesTheYieldToInsurance`,
///      and the campaign tripwire's free-balance-sweep leg.
contract R54A02_ForcedCloseIgnoresLotYield is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");
    address internal donor = makeAddr("donor");

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

        _seed(alice, BONDS);
        _seed(bob, BONDS);
    }

    // ── fixture helpers ──────────────────────────────────────────────────────

    function _seed(address who, uint256 bonds) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _maxBorrow(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return (bonds * nav * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    function _navAtDebtParity(uint256 debt, uint256 bonds) internal pure returns (uint256) {
        return (debt * Config.USDC_TO_NAV_SCALE) / bonds;
    }

    function _openWorkout(address who) internal returns (uint256 id) {
        oracle.setNav(NAV);
        uint256 debt = _maxBorrow(BONDS, NAV);
        vm.prank(who);
        credit.borrow(debt);
        oracle.setNav(_navAtDebtParity(debt, BONDS) / 2);
        vm.prank(keeper);
        credit.liquidate(who);
        id = auction.auctionOf(who);
        assertGt(id, 0, "fixture: no auction opened");
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(who), 1, "fixture: no workout opened");
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

    function _writtenDown(uint256 id) internal view returns (uint256 wd) {
        (,,,,,,, wd,,,) = auction.workouts(id);
    }

    function _yieldOwed(uint256 id) internal view returns (uint256 owed) {
        (,,,,,,,,,, owed) = auction.workouts(id);
    }

    function _yieldIndexAtOpen(uint256 id) internal view returns (uint256 idx) {
        (,,,,,,,,, idx,) = auction.workouts(id);
    }

    function _bondCountOf(uint256 id) internal view returns (uint256 n) {
        (,,, n,,,,,,,) = auction.workouts(id);
    }

    function _debtAtExpiry(uint256 id) internal view returns (uint256 d) {
        (,,,, d,,,,,,) = auction.workouts(id);
    }

    // ── 1. THE CLOSED PROPERTY, and why it has to live in the close ──────────

    /// @notice The lot's own accrual cannot reach the fund before the forced write-down by ANY
    ///         order of permissionless calls, which is why the fix is inside `closeWorkout` rather
    ///         than a keeper ordering rule. Both pre-close doors are still refused here; the close
    ///         itself now spends the lot's yield on its own default, and there is nothing left for
    ///         a later sweep to bank against somebody else's.
    /// @dev **This is the round-54 pin, FLIPPED by round 55 item 215 in the commit that shipped the
    ///      fix.** As it stood it asserted the defect to the wei on `f16e6e6`: `writtenDown` equal
    ///      to the whole residual 628.750000, `fromInsurance` zero, and `sweepWorkoutYieldToInsurance`
    ///      one block later handing the fund 499.999999 out of the very lot that had just been
    ///      written off. Those figures are the finding and are kept in the docstring because the
    ///      body can no longer produce them. What survives unchanged in the body is the half that
    ///      made the finding structural rather than an ordering race: both sweeps are refused while
    ///      the workout is open, so no honest keeper sequence could have done this from outside.
    function test_R55_215_theCloseIsTheOnlyInstantTheLotsYieldCanReachTheFund() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION); // the epoch already skipped 5 days; total > 14 days

        uint256 lotYield = credit.yieldAccruedOn(_bondCountOf(id), _yieldIndexAtOpen(id));
        uint256 residual = credit.currentDebtOf(alice);
        emit log_named_uint("MEASURED lot accrual during the workout", lotYield);
        emit log_named_uint("MEASURED residual debt at the forced close", residual);
        assertGt(lotYield, 0, "fixture: the lot earned nothing");
        assertLt(lotYield, residual, "fixture: the lot must not cover the whole residual here");
        assertEq(credit.insuranceFund(), 0, "fixture: the fund is empty before the close");

        // (a) UNCHANGED BY THE FIX, and the reason the fix is where it is: round 51's reserve holds
        //     an OPEN workout's accrual back from both doors, so no pre-close call reaches it.
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepWorkoutYieldToInsurance();
        vm.expectRevert(LiquidationAuction.NothingUnreserved.selector);
        auction.sweepFreeBalanceToInsurance();

        // (b) The close takes the lot off the open-accrual sums, claims, funds the fund with what
        //     is now free, and only then writes down what is left.
        uint256 principalBefore = credit.pendingPrincipal();
        auction.closeWorkout(id);
        uint256 writtenDown = _writtenDown(id);
        uint256 fromInsurance = credit.pendingPrincipal() - principalBefore;
        emit log_named_uint("MEASURED writtenDown (socialised to the funder)", writtenDown);
        emit log_named_uint("MEASURED fromInsurance (funder made whole)", fromInsurance);
        // To a wei on both sides: `yieldAccruedOn` floors on the index and the pot floors again
        // when it is realised (round 52), so the two readings can differ by dust.
        assertGe(fromInsurance + 2, lotYield, "the funder was not made whole out of the lot's yield");
        assertLe(writtenDown, residual - lotYield + 2, "more than the uncovered part was socialised");
        assertGt(writtenDown, 0, "fixture: this close was not forced");

        // (c) And nothing is left over for a later sweep to bank against a stranger's default. The
        //     close already pulled the pot, so the sweep dies at the MANAGER's `NothingToClaim`
        //     (same selector as this contract's, so it is named on the contract it comes from).
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        auction.sweepWorkoutYieldToInsurance();
    }

    /// @notice CONTROL. Money that IS in the fund at the close is spent first, so the only thing
    ///         wrong is the ordering: the fund works, the lot's yield is just not in it yet.
    function test_R54A02_control_aBalanceAlreadyInTheFundIsSpentBeforeSocialising() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION);

        uint256 topUp = 100e6;
        usdc.mint(donor, topUp);
        vm.startPrank(donor);
        usdc.approve(address(credit), topUp);
        credit.fundInsurance(topUp);
        vm.stopPrank();

        uint256 residual = credit.currentDebtOf(alice);
        uint256 principalBefore = credit.pendingPrincipal();
        auction.closeWorkout(id);
        // `<=` / `>=` rather than equality, so this control is green on the shipped tree (exactly
        // `topUp` is spent) AND under the fix (the lot's yield is spent as well).
        assertLe(_writtenDown(id), residual - topUp, "the fund covered at least its balance first");
        assertGe(credit.pendingPrincipal() - principalBefore, topUp, "and the funder was repaid at least it");
        emit log_named_uint("MEASURED writtenDown with 100.000000 already in the fund", _writtenDown(id));
    }

    /// @notice NEGATIVE. A CLEAN close is untouched by this finding: the lot's yield is the
    ///         borrower's (round 22 finding 18), nothing is written down, insurance gains nothing.
    ///         Recorded so the fix can be checked against it.
    function test_R54A02_negative_aCleanCloseStillBooksTheYieldToTheBorrower() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        uint256 owed = credit.currentDebtOf(alice);
        usdc.mint(stranger, owed);
        vm.startPrank(stranger);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();

        uint256 fundBefore = credit.insuranceFund();
        auction.closeWorkout(id);
        assertEq(_writtenDown(id), 0, "clean close wrote nothing down");
        assertGt(_yieldOwed(id), 0, "clean close booked the borrower");
        assertEq(credit.insuranceFund(), fundBefore, "clean close funded no insurance");
    }

    // ── 2. THE FIX, promoted from audit round 54 ────────────────────────

    /// @notice The forced branch spends the lot's own accrual on the lot's own default before
    ///         `writeDownLoss` reads the fund, so only the uncovered remainder is socialised.
    /// @dev Written for audit round 54, where it was RED at `f16e6e6` by design at
    ///      `628750000 > 128750003` and held back until the fix shipped. Under the shipped fix it
    ///      MEASURES `writtenDown` 128,750,001 and `fromInsurance` 499,999,999 out of a 628.750000
    ///      residual and a 499.999999 lot accrual. Its assertions are unchanged from round 54; only
    ///      the `fix_` prefix is gone, because the fix it asserts is now the tree.
    function test_R55_215_aForcedCloseSpendsTheLotsOwnYieldBeforeSocialising() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION);

        uint256 lotYield = credit.yieldAccruedOn(_bondCountOf(id), _yieldIndexAtOpen(id));
        uint256 residual = credit.currentDebtOf(alice);
        uint256 principalBefore = credit.pendingPrincipal();

        auction.closeWorkout(id);

        uint256 writtenDown = _writtenDown(id);
        uint256 fromInsurance = credit.pendingPrincipal() - principalBefore;
        emit log_named_uint("MEASURED writtenDown under the fix", writtenDown);
        emit log_named_uint("MEASURED fromInsurance under the fix", fromInsurance);
        // To a wei: the accrual read here is one floor and the pot is another (round 52).
        assertLe(residual - lotYield, writtenDown, "socialised at least residual - lotYield");
        assertLe(writtenDown, residual - lotYield + 2, "socialised no more than that plus dust");
        assertGe(fromInsurance + 2, lotYield, "the funder was made whole out of the lot's yield");

        // And nothing is left for the sweep to bank against a stranger's future default: the close
        // already pulled the pot, so the sweep's bare `claimSurplus` dies at the MANAGER's
        // `NothingToClaim` (same selector as the auction's, named here on the contract it comes from).
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        auction.sweepWorkoutYieldToInsurance();
    }

    /// @notice A SIBLING open workout's accrual is still reserved through the forced close of
    ///         another: the pre-write-down sweep must not fund insurance with a live borrower's
    ///         backing (round 51's property). Green on the shipped tree before the fix too, because
    ///         that tree funded nothing at the close.
    /// @dev **This is the test that catches the decrement in the wrong order**, which is the one
    ///      mistake the shape of this fix invites. Move `_openWorkoutBonds -= w.bondCount` back into
    ///      `closeWorkout`'s tail and the fix goes inert; take the whole pair out and A's close
    ///      funds insurance out of B's still-open backing and this goes red on the first assertion.
    ///      Promoted from audit round 54 with its assertions unchanged; only the `fix_` prefix
    ///      is gone.
    function test_R55_215_negative_aSiblingOpenWorkoutsBackingIsNotSpentByTheForcedClose() public {
        uint256 idA = _openWorkout(alice);
        uint256 idB = _openWorkout(bob);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION);

        uint256 bobAccrual = credit.yieldAccruedOn(_bondCountOf(idB), _yieldIndexAtOpen(idB));
        uint256 aliceAccrual = credit.yieldAccruedOn(_bondCountOf(idA), _yieldIndexAtOpen(idA));

        auction.closeWorkout(idA);
        uint256 fundAfterA = credit.insuranceFund();
        emit log_named_uint("MEASURED insurance after A's forced close", fundAfterA);
        assertLe(fundAfterA, aliceAccrual + 2, "A's close spent at most A's own accrual");

        // Bob's lot is still open; its accrual must still be reachable by a clean close.
        uint256 owedB = credit.currentDebtOf(bob);
        usdc.mint(stranger, owedB);
        vm.startPrank(stranger);
        usdc.approve(address(credit), owedB);
        credit.repayFor(bob, owedB);
        vm.stopPrank();
        auction.closeWorkout(idB);
        assertGe(_yieldOwed(idB) + 2, bobAccrual, "B's clean close still books B's whole accrual");
        auction.claimWorkoutYield(idB);
        assertEq(_yieldOwed(idB), 0, "and B is paid it in full");
    }

    /// @notice A delivery that CANNOT be made does not brick the exit of last resort: with the
    ///         auction blacklisted on the token, both new legs fail closed and the forced close
    ///         still recognises the loss.
    /// @dev This originally falsified the funding-only `bestEffort` arm added after audit round 54.
    ///      The Astra review extends the catch to the whole funding subcall, including approvals;
    ///      this remains the transfer-failure control. It is an important boundary because
    ///      `closeWorkout` is the only way this protocol recognises a loss without asking anybody's
    ///      permission, and `fundInsurance` reaches a `safeTransferFrom` on real USDC, which has a
    ///      blacklist.
    ///
    ///      The claim is realised onto the auction while transfers still work, so the auction is
    ///      HOLDING the money when the blacklist lands. Then `claimSurplus` reverts (nothing left to
    ///      claim), the delivery reverts (the transfer out is blocked), and the close writes the
    ///      whole residual down exactly as it would have with no yield at all.
    function test_R55_215_aBlockedDeliveryDoesNotBrickTheForcedClose() public {
        uint256 id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION);

        // Realise the lot's accrual onto the auction while the token still allows it.
        credit.claimSurplusFor(address(auction));
        uint256 held = usdc.balanceOf(address(auction));
        assertGt(held, 0, "fixture: the auction is not holding the lot's yield");

        usdc.setBlocked(address(auction), true);
        uint256 residual = credit.currentDebtOf(alice);
        uint256 principalBefore = credit.pendingPrincipal();

        auction.closeWorkout(id); // must not revert: this is the exit of last resort

        assertEq(_writtenDown(id), residual, "a failed delivery must not have covered anything");
        assertEq(credit.pendingPrincipal(), principalBefore, "the fund paid out money it never received");
        assertEq(usdc.balanceOf(address(auction)), held, "the money left despite the blacklist");
        assertEq(usdc.allowance(address(auction), address(credit)), 0, "a standing allowance was left behind");

        // CONTROL: the same close with the blacklist lifted delivers, and the funder is made whole.
        usdc.setBlocked(address(auction), false);
        uint256 id2 = _openWorkout(bob);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION);
        uint256 residual2 = credit.currentDebtOf(bob);
        uint256 principalBefore2 = credit.pendingPrincipal();
        auction.closeWorkout(id2);
        assertLt(_writtenDown(id2), residual2, "control: nothing was delivered with the token open either");
        assertGt(credit.pendingPrincipal(), principalBefore2, "control: the funder was not made whole");
    }

    // USDC v2.2 permits approvals from blacklisted accounts, but refuses them while paused.
    // The existing blacklist test therefore never exercised either forceApprove failure.
    // These tests mock that dependency boundary without changing the shared token fixture.
    function test_astra_pausedUsdcCannotBlockForcedClose() public {
        (uint256 id, uint256 held) = _prepareForcedCloseWithCash();
        bytes memory reason = _pauseReason();
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.approve.selector), reason);
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), reason);
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transferFrom.selector), reason);

        _assertForcedCloseWithoutFunding(id, held);
        assertEq(auction.openWorkoutCount(), 0);
    }

    // A cleanup failure is a defensive token-boundary case, not a claim that USDC can pause
    // halfway through a transaction. The funding transfer must roll back with its approval.
    function test_astra_revokeFailureRollsBackFundingBeforeForcedClose() public {
        (uint256 id, uint256 held) = _prepareForcedCloseWithCash();
        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20.approve, (address(credit), 0)), _pauseReason());
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(credit), held)));
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.transferFrom, (address(auction), address(credit), held)));

        _assertForcedCloseWithoutFunding(id, held);
    }

    // These two read failures test the optional subcall boundary defensively. USDC's pause does
    // not refuse balanceOf, and the supported manager's accrual view does not normally revert.
    function test_astra_failedBalanceReadCannotBlockForcedClose() public {
        (uint256 id, uint256 held) = _prepareForcedCloseWithCash();
        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20.balanceOf, (address(auction))), _pauseReason());

        _assertForcedCloseWithoutFunding(id, held);
    }

    function test_astra_failedOpenAccrualReadCannotBlockForcedClose() public {
        uint256 id = _openWorkout(alice);
        _openWorkout(bob);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION);
        credit.claimSurplusFor(address(auction));
        uint256 held = usdc.balanceOf(address(auction));
        assertGt(held, 0);
        assertEq(auction.openWorkoutCount(), 2);
        vm.mockCallRevert(
            address(credit), abi.encodeWithSelector(ICreditManager.yieldAccruedOn.selector), _pauseReason()
        );

        _assertForcedCloseWithoutFunding(id, held);
        assertEq(auction.openWorkoutCount(), 1, "the sibling must remain open");
        assertEq(auction.workoutsOpenFor(bob), 1);
    }

    function test_astra_onlySelfFundingDoorRejectsEveryExternalCaller() public {
        bytes memory callData = abi.encodeWithSignature("fundInsuranceWithFree(address)", address(credit));
        bytes memory expected = abi.encodeWithSignature("NotSelf()");
        vm.prank(stranger);
        (bool strangerOk, bytes memory strangerReason) = address(auction).call(callData);
        assertFalse(strangerOk);
        assertEq(strangerReason, expected);
        vm.prank(admin);
        (bool ownerOk, bytes memory ownerReason) = address(auction).call(callData);
        assertFalse(ownerOk);
        assertEq(ownerReason, expected);
    }

    function test_astra_zeroFreeBalanceDoesNotNeedTokenApproval() public {
        uint256 id = _openWorkout(alice);
        skip(Config.WORKOUT_MAX_DURATION);
        assertEq(usdc.balanceOf(address(auction)), 0);
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.approve.selector), _pauseReason());

        _assertForcedCloseWithoutFunding(id, 0);
    }

    function test_astra_publicSweepsStillRefuseApprovalFailure() public {
        uint256 id = _openWorkout(alice);
        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(id);
        _streamEpoch(EPOCH); // A closed lot keeps earning until its owner disposes it.
        bytes memory reason = _pauseReason();
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.approve.selector), reason);

        vm.expectRevert(reason);
        auction.sweepWorkoutYieldToInsurance();
        assertEq(usdc.balanceOf(address(auction)), 0, "the failed sweep's claim must roll back");
        credit.claimSurplusFor(address(auction));
        uint256 held = usdc.balanceOf(address(auction));
        assertGt(held, 0);
        vm.expectRevert(reason);
        auction.sweepFreeBalanceToInsurance();
        assertEq(usdc.balanceOf(address(auction)), held);
        assertEq(usdc.allowance(address(auction), address(credit)), 0);
    }

    function _prepareForcedCloseWithCash() internal returns (uint256 id, uint256 held) {
        id = _openWorkout(alice);
        _streamEpoch(EPOCH);
        skip(Config.WORKOUT_MAX_DURATION);
        credit.claimSurplusFor(address(auction));
        held = usdc.balanceOf(address(auction));
        assertGt(held, 0, "the approval path needs cash already held by the auction");
        assertEq(auction.totalUnclaimedRewards(), 0);
        assertEq(auction.totalWorkoutYieldOwed(), 0);
        assertEq(auction.openWorkoutCount(), 1, "closing this lot must remove the entire open reserve");
    }

    function _assertForcedCloseWithoutFunding(uint256 id, uint256 held) internal {
        uint256 residual = credit.currentDebtOf(alice);
        uint256 insuranceBefore = credit.insuranceFund();
        uint256 principalBefore = credit.pendingPrincipal();
        assertGt(residual, 0, "this must exercise the forced branch");
        assertEq(insuranceBefore, 0, "the fixture must have no existing cover");
        assertEq(usdc.allowance(address(auction), address(credit)), 0);

        auction.closeWorkout(id);

        // Clear only after the close: the failing balance probe must not mask the cash assertion.
        vm.clearMockedCalls();
        assertEq(_writtenDown(id), residual);
        assertEq(credit.currentDebtOf(alice), 0);
        assertEq(auction.workoutsOpenFor(alice), 0);
        assertEq(credit.insuranceFund(), insuranceBefore);
        assertEq(credit.pendingPrincipal(), principalBefore);
        assertEq(usdc.balanceOf(address(auction)), held);
        assertEq(usdc.allowance(address(auction), address(credit)), 0);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.WorkoutNotOpen.selector, id));
        auction.closeWorkout(id);
    }

    function _pauseReason() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "Pausable: paused");
    }
}
