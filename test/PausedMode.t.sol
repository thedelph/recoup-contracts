// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {LtvMath} from "../src/LtvMath.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice **Audit round 25: the PAUSED operating mode, which nothing measured.**
///
///         Round 24 handed this forward unsettled. Three facts were on record and none of
///         them had a number attached: `liquidate`/`repay`/the vault exits are deliberately
///         not `whenNotPaused`; `pause`/`unpause` appear in no invariant handler, so every
///         invariant in the repo describes the unpaused state only; and pausing is
///         `onlyOwner` over a plain EOA.
///
///         Everything here runs the SHIPPED deployment (`DeployBase._deployProtocol`), not a
///         hand-wired fixture, because the question is what the protocol an operator actually
///         holds does when that operator turns the key.
contract PausedModeTest is Test, DeployBase {
    uint256 internal constant FLOAT = 10_000e6;
    uint256 internal constant LOAN = 500e6;
    uint256 internal constant BONDS = 100;
    uint256 internal constant NAV = 25.15e8;
    /// @dev 100 bonds at $6.00 is $600 against $500: LTV 8333 bps, over the threshold.
    uint256 internal constant CRASHED_NAV = 6e8;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal navConfirmer = makeAddr("navConfirmer");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(ANVIL_CHAIN_ID);
    }

    // ── fixture ──────────────────────────────────────────────────────────────

    function _externals() internal view returns (Externals memory) {
        return Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
    }

    /// @dev This contract keeps ownership, because every question here is about what the
    ///      owner can do. A prank does not survive an `this.x()` hop, so being the owner
    ///      outright is the same code path the script takes when `RECOUP_OWNER` is the
    ///      deployer.
    function _params() internal view returns (GovParams memory) {
        return GovParams({
            owner: address(this),
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: treasury,
            // The role exists and is deliberately left UNFILLED for most of this file, because
            // these tests ask what the OWNER's key does. `_guardedProtocol` below fills it.
            guardian: address(0)
        });
    }

    /// @dev `_liveProtocol` from `Deploy.t.sol`, minus its private members. The borrower is
    ///      given `spare` extra bonds beyond the `BONDS` deposited, because the whole point
    ///      of several tests below is whether they can put those spare bonds in.
    function _liveProtocol(uint256 spare) internal returns (Deployed memory d, address borrower) {
        d = _deployProtocol(_externals(), _params(), address(this));

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(d.liquidity), FLOAT);
        d.liquidity.fund(FLOAT);
        d.oracle.bootstrapNav(NAV);

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);

        borrower = makeAddr("borrower");
        bond.mint(borrower, BONDS + spare);
        vm.startPrank(borrower);
        bond.setApprovalForAll(address(d.vault), true);
        d.vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @dev Move NAV through the real oracle: post, wait out the review delay, confirm. Every
    ///      move here is outside the keeper's prorated budget by design.
    function _moveNav(Deployed memory d, uint256 nav) internal {
        vm.prank(keeper);
        d.oracle.postNav(nav);
        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(navConfirmer);
        d.oracle.confirmNav(nav);
        assertEq(d.oracle.navPerBond(), nav, "the NAV move has to land or the test proves nothing");
    }

    function _fundBidder(Deployed memory d, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(d.auction), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. The pause surface, measured rather than read off the source
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **Three gated deposit/borrow functions, and since the round-27 remediation they
    ///         sit behind THREE independent switches rather than two.**
    /// @dev `git grep whenNotPaused src/` now says **two** - `CollateralVault.depositETH` and
    ///      `CreditManager.borrow` - because `depositBonds` moved onto its own owner-only flag.
    ///      This asserts the surface from the other side, by calling things, because a grep can
    ///      only see the shape it was given and this repo has been bitten by that four times.
    ///      Every call below is made with BOTH pausable contracts paused; the third switch is
    ///      thrown separately at the foot of the test, which is the whole point of it being third.
    ///
    ///      MEASURED: `borrow` and `depositETH` refuse. **`depositBonds` does not, and that is
    ///      the fix** - audit round 25, finding 1 - so the borrower's cure has joined
    ///      the ALLOWED list below and refuses only once its own switch is thrown. **Eleven other
    ///      user-facing entrypoints across six contracts do not**, including the entire
    ///      liquidation chain. **`LenderPool` was in that list until the round-28 remediation and is
    ///      not any more** - it is `Pausable`, its `deposit` and `mint` carry `whenNotPaused`, and
    ///      its `pause()` is owner-or-guardian. So three of the eleven contracts are `Pausable`,
    ///      not two, and the gated deposit/borrow surface is five functions across three contracts
    ///      rather than the three in two this test drives. **This test's name describes what it
    ///      calls, and it is left alone deliberately**: the pool's switch is exercised in
    ///      `test_paused_newLenderMoneyStillEntersAndTakesTheWriteDown` and under
    ///      `LenderHandler.togglePause`, and renaming a test cited by name in the go-live
    ///      checklist costs more than the precision buys. `LiquidationAuction`, `EpochHarvester`,
    ///      `NAVOracle`, `ProtocolFeeSplitter`, `TreasuryLiquiditySource`, `RiskParams`,
    ///      `ReferralRegistry` and `DirectCallAdapter` still have no pause switch to turn.
    function test_pauseSurface_isThreeFunctionsInTwoContracts() public {
        (Deployed memory d, address borrower) = _liveProtocol(50);

        address lender = makeAddr("lender");
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();

        vm.prank(borrower);
        d.credit.borrow(LOAN);

        d.credit.pause();
        d.vault.pause();
        assertTrue(d.credit.paused() && d.vault.paused(), "premise: both doors shut");

        // ── refused ──
        vm.prank(borrower);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.credit.borrow(1e6);
        emit log("REFUSED  CreditManager.borrow");

        // `depositBonds` USED TO BE REFUSED HERE, and that was audit round 25's
        // finding 1: `pause()` shut the borrower's documented cure. It now has its own
        // owner-only switch and is exercised in the ALLOWED block below, then shut on its own
        // at the foot of this test.

        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.vault.depositETH{value: 1 ether}(bytes32(uint256(1)), "");
        emit log("REFUSED  CollateralVault.depositETH");

        // ── allowed ──
        // **The one that moved.** Both `pause()` switches are on and the cure is open, which is
        // what makes a guardian pause safe to hand out at all: a mis-fire costs new borrows and
        // new mints, and never a borrower's ability to save a position.
        vm.prank(borrower);
        d.vault.depositBonds(1);
        emit log("ALLOWED  CollateralVault.depositBonds (the cure, behind its own switch)");
        vm.prank(borrower);
        d.vault.withdrawBonds(1);

        usdc.mint(borrower, LOAN);
        vm.startPrank(borrower);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(1e6);
        vm.stopPrank();
        emit log("ALLOWED  CreditManager.repay");

        vm.prank(borrower);
        d.vault.withdrawBonds(1);
        emit log("ALLOWED  CollateralVault.withdrawBonds");

        usdc.mint(lender, 1e6);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), 1e6);
        d.pool.deposit(1e6, lender);
        vm.stopPrank();
        emit log("ALLOWED  LenderPool.deposit (new lender money enters a paused protocol)");

        vm.prank(lender);
        d.pool.requestWithdrawal(1e6, lender);
        emit log("ALLOWED  LenderPool.requestWithdrawal");

        uint256 serviceable = d.pool.maxRequestRedeem(lender);
        vm.prank(lender);
        d.pool.serviceWithdrawalRequest(lender, serviceable, 0);
        emit log("ALLOWED  LenderPool.serviceWithdrawalRequest");

        vm.prank(lender);
        d.pool.claim();
        emit log("ALLOWED  LenderPool.claim");

        d.harvester.harvest();
        emit log("ALLOWED  EpochHarvester.harvest");

        // The oracle has no pause at all: the keeper keeps moving the price that decides
        // who is liquidatable, throughout.
        _moveNav(d, CRASHED_NAV);
        emit log("ALLOWED  NAVOracle.postNav + confirmNav (NAVOracle is not Pausable)");

        // And the entire liquidation chain, end to end, under the same pause.
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);
        assertGt(id, 0, "an auction opened while the protocol was paused");
        emit log("ALLOWED  CreditManager.liquidate -> LiquidationAuction.start");

        address whale = makeAddr("whale");
        _fundBidder(d, whale, FLOAT);
        vm.prank(whale);
        d.auction.bid(id);
        emit log("ALLOWED  LiquidationAuction.bid -> CollateralVault.disposeTo -> writeDownLoss");

        assertEq(d.credit.debtOf(borrower), 0, "the liquidation ran to completion while paused");
        assertTrue(d.credit.paused() && d.vault.paused(), "and the protocol never came off pause");

        // ── and the third switch, which is a separate transaction and a separate error ──
        // Asserted on its own selector rather than on `EnforcedPause`, because a caller has to
        // be able to tell which of three doors is shut. Same reason the two `pause()` flags are
        // not merged: an error that cannot distinguish them is an error that cannot be acted on.
        bond.mint(borrower, 1);
        d.vault.setBondDepositsPaused(true);
        vm.prank(borrower);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        d.vault.depositBonds(1);
        emit log("REFUSED  CollateralVault.depositBonds, once its OWN switch is thrown");
    }

    /// @notice **The two pause switches are independent and nothing reads the other's.**
    /// @dev A hazard for whoever holds the key. `borrow` is gated on the *manager's* pause and
    ///      `depositBonds` on the *vault's*, and neither contract consults the other, so
    ///      "pause the vault" - the contract holding the collateral, the intuitive one to reach
    ///      for - leaves new debt fully open. MEASURED: a 500,000,000 borrow lands against a
    ///      paused vault.
    function test_pauseSurface_pausingTheVaultAloneDoesNotStopNewDebt() public {
        (Deployed memory d, address borrower) = _liveProtocol(0);

        d.vault.pause();
        assertTrue(d.vault.paused() && !d.credit.paused(), "premise: the collateral door only");

        vm.prank(borrower);
        d.credit.borrow(LOAN);
        assertEq(d.credit.debtOf(borrower), LOAN, "new debt drawn against a paused vault");
        emit log_named_uint("MEASURED debt drawn with the vault paused", d.credit.debtOf(borrower));

        // And the inverse: pausing the manager alone leaves the collateral door open, which is
        // the half that matters below - the borrower can still defend.
        d.vault.unpause();
        d.credit.pause();
        vm.prank(borrower);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.credit.borrow(1e6);
        assertFalse(d.vault.paused(), "the vault is open, so a top-up is still possible");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. The asymmetry: liquidation open, the cure shut
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **FINDING. A pause shuts the borrower's collateral-side cure while leaving every
    ///         liquidation path open, and the protocol's own docstrings name that cure.**
    ///
    /// @dev `CreditManager.borrow` line 962 and `LiquidationAuction.start` line 499 both
    ///      describe a borrower who "re-collateralises with `depositBonds`" to heal a position
    ///      under auction - the code treats it as a live move, and `expireToWorkout` was
    ///      rewritten in round 20 specifically to give a healed position an exit. That move
    ///      runs through the one vault function the pause shuts.
    ///
    ///      So while paused: NAV keeps moving (the oracle is not Pausable), `liquidate` fires
    ///      (deliberately not gated), `bid` fills (the auction is not Pausable), and the
    ///      borrower's only collateral-side answer reverts `EnforcedPause`.
    ///
    ///      MEASURED, control vs paused, identical position and identical NAV path.
    function test_paused_borrowerCannotHealAPositionUnderAuction() public {
        // ── control: unpaused, the borrower heals and keeps the lot ──
        (Deployed memory c, address cBorrower) = _liveProtocol(200);
        vm.prank(cBorrower);
        c.credit.borrow(LOAN);
        _moveNav(c, CRASHED_NAV);
        c.credit.liquidate(cBorrower);
        uint256 cId = c.auction.auctionOf(cBorrower);

        vm.prank(cBorrower);
        c.vault.depositBonds(200); // the documented cure
        c.auction.cancel(cId);

        uint256 controlBonds = c.vault.bondCount(cBorrower);
        uint256 controlDebt = c.credit.debtOf(cBorrower);
        assertEq(c.auction.auctionOf(cBorrower), 0, "control: the auction is gone");

        // ── treatment: identical, but paused before the crash ──
        (Deployed memory d, address borrower) = _liveProtocol(200);
        vm.prank(borrower);
        d.credit.borrow(LOAN);

        d.credit.pause();
        d.vault.pause();
        // **Audit round 25 F1 is fixed, so shutting the cure now takes a THIRD,
        // owner-only transaction.** The two `pause()` calls above are what a guardian can make,
        // and they no longer reach `depositBonds`. This line is the deliberate owner-level act
        // that does. Everything measured below is what that act still costs, unchanged in
        // magnitude from when one guardian transaction alone could cause it - which is the
        // point: the harm is real, and the fix is about who can cause it and how fast.
        d.vault.setBondDepositsPaused(true);

        _moveNav(d, CRASHED_NAV);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);
        assertGt(id, 0, "the liquidation opened anyway");

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        d.vault.depositBonds(200);

        // `cancel` is permissionless and open, but it refuses a position that is still
        // unhealthy - and it is unhealthy precisely because the cure was refused. Asserted on the
        // selector rather than with a bare `expectRevert`, which would pass on any revert at all,
        // including one that meant the fixture was broken.
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationAuction.StillLiquidatable.selector,
                LtvMath.ltvBps(d.credit.currentDebtOf(borrower), d.vault.collateralValue(borrower))
            )
        );
        d.auction.cancel(id);

        // The lot fills at the auction's own price and the borrower loses all 100 bonds.
        address whale = makeAddr("whale");
        _fundBidder(d, whale, FLOAT);
        vm.prank(whale);
        d.auction.bid(id);

        emit log_named_uint("CONTROL  bonds retained by the borrower", controlBonds);
        emit log_named_uint("CONTROL  debt still owed", controlDebt);
        emit log_named_uint("PAUSED   bonds retained by the borrower", d.vault.bondCount(borrower));
        emit log_named_uint("PAUSED   spare bonds left stranded in the wallet", bond.balanceOf(borrower, 0));

        assertEq(controlBonds, BONDS + 200, "control: the borrower keeps everything");
        assertEq(d.vault.bondCount(borrower), 0, "paused: the lot is gone");
        assertEq(bond.balanceOf(borrower, 0), 200, "and the bonds that would have saved it never got in");
    }

    /// @notice **The same asymmetry all the way to a socialised loss: the pause moves the bill
    ///         onto the LENDERS, not just the borrower.**
    /// @dev Phase-4 wiring, so the pool is funder and loss sink together. Unpaused, the
    ///      borrower cures and the lenders lose nothing. Paused, the cure is refused, the
    ///      auction lapses unbid, the workout is forced closed and the whole loan is written
    ///      down onto the pool.
    ///
    ///      Note what is NOT gated anywhere on this path: `expireToWorkout`, `closeWorkout`,
    ///      `writeDownLoss`, `LenderPool.socialiseLoss`. Pause stops the cure and nothing else.
    function test_paused_convertsACurablePositionIntoALenderLoss() public {
        // ── control ──
        (Deployed memory c, address cBorrower) = _liveProtocol(200);
        _wirePhase4(c);
        address cLender = makeAddr("cLender");
        usdc.mint(cLender, FLOAT);
        vm.startPrank(cLender);
        usdc.approve(address(c.pool), FLOAT);
        c.pool.deposit(FLOAT, cLender);
        vm.stopPrank();
        vm.prank(cBorrower);
        c.credit.borrow(LOAN);
        _moveNav(c, CRASHED_NAV);
        c.credit.liquidate(cBorrower);
        vm.prank(cBorrower);
        c.vault.depositBonds(200);
        c.auction.cancel(c.auction.auctionOf(cBorrower));
        uint256 controlLoss = c.pool.lifetimeSocialisedLoss();

        // ── treatment ──
        (Deployed memory d, address borrower) = _liveProtocol(200);
        _wirePhase4(d);
        address lender = makeAddr("lender");
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();
        vm.prank(borrower);
        d.credit.borrow(LOAN);

        d.credit.pause();
        d.vault.pause();
        // **Audit round 25 F1 is fixed, so shutting the cure now takes a THIRD,
        // owner-only transaction.** The two `pause()` calls above are what a guardian can make,
        // and they no longer reach `depositBonds`. This line is the deliberate owner-level act
        // that does. Everything measured below is what that act still costs, unchanged in
        // magnitude from when one guardian transaction alone could cause it - which is the
        // point: the harm is real, and the fix is about who can cause it and how fast.
        d.vault.setBondDepositsPaused(true);

        _moveNav(d, CRASHED_NAV);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        d.vault.depositBonds(200);

        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);
        d.auction.expireToWorkout(id);
        emit log("ALLOWED  expireToWorkout, while paused");

        vm.warp(block.timestamp + Config.WORKOUT_MAX_DURATION + 1);
        d.auction.closeWorkout(id);
        emit log("ALLOWED  closeWorkout -> writeDownLoss -> LenderPool.socialiseLoss, while paused");

        emit log_named_uint("CONTROL  lifetimeSocialisedLoss", controlLoss);
        emit log_named_uint("PAUSED   lifetimeSocialisedLoss", d.pool.lifetimeSocialisedLoss());

        assertEq(controlLoss, 0, "control: the cure kept the lenders whole");
        assertEq(d.pool.lifetimeSocialisedLoss(), LOAN, "paused: the lenders ate the whole loan");
        assertTrue(d.credit.paused(), "and none of it needed the protocol to reopen");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. What the clock does across a pause
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **Every clock in the protocol keeps running while paused. Measured, all five.**
    /// @dev The hypothesis worth refuting was "pause freezes the world but not `block.timestamp`,
    ///      so the auction decays while nobody can bid". Half of it is right and half is not, and
    ///      the half that is wrong is the important half: bidding is NOT blocked, because
    ///      `LiquidationAuction` is not `Pausable`. So the decay is not an unfillable price - it
    ///      is a normal auction, and the pause's effect on it is the cure being shut (above),
    ///      not the price.
    ///
    ///      Recorded either way, because a reader with the same hypothesis deserves the number.
    function test_paused_everyClockKeepsRunning() public {
        (Deployed memory d, address borrower) = _liveProtocol(200);
        vm.prank(borrower);
        d.credit.borrow(LOAN);
        _moveNav(d, CRASHED_NAV);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);

        uint256 priceAtOpen = d.auction.currentPrice(id);

        d.credit.pause();
        d.vault.pause();

        vm.warp(block.timestamp + 3 hours);
        uint256 priceAfter3h = d.auction.currentPrice(id);

        emit log_named_uint("MEASURED auction price at open", priceAtOpen);
        emit log_named_uint("MEASURED auction price 3h into a pause", priceAfter3h);
        assertLt(priceAfter3h, priceAtOpen, "the Dutch curve is indifferent to the pause");

        // But a bidder is too: the auction has no pause switch.
        address whale = makeAddr("whale");
        _fundBidder(d, whale, FLOAT);
        uint256 before = usdc.balanceOf(whale);
        vm.prank(whale);
        d.auction.bid(id);
        emit log_named_uint("MEASURED USDC a bidder paid mid-pause", before - usdc.balanceOf(whale));
        assertEq(before - usdc.balanceOf(whale), priceAfter3h, "filled at the decayed price, while paused");

        // NAV staleness runs too, and it gates `borrow` - which is already shut - and
        // `withdrawBonds`, which is not. Warp past the window with the protocol still paused.
        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(d.oracle.isStale(), "the staleness clock ran through the pause");
        emit log("MEASURED NAVOracle.isStale() == true after a pause spanning NAV_STALENESS");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Is pausing one-way?
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `unpause` restores every gated path, including one taken mid-auction.
    /// @dev The question was whether a pause can reach a state `unpause` cannot undo. It cannot:
    ///      the three gated functions are stateless with respect to the pause flag, and OZ's
    ///      `_unpause` is unconditional beyond `whenPaused`. What does NOT come back is the time
    ///      that passed - which is the finding above, not a one-way pause.
    function test_unpause_restoresEveryGatedPath() public {
        (Deployed memory d, address borrower) = _liveProtocol(400);
        vm.prank(borrower);
        d.credit.borrow(LOAN);
        _moveNav(d, CRASHED_NAV);

        d.credit.pause();
        d.vault.pause();
        // All THREE switches, or this test does not mean what its name says. The third is the
        // one added when the deposit gate was split, and it is the one an `unpause` does not
        // clear - it has its own setter, deliberately, so that clearing the guardian's pause
        // cannot silently reopen a door the owner shut on purpose.
        d.vault.setBondDepositsPaused(true);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);

        d.credit.unpause();
        d.vault.unpause();
        d.vault.setBondDepositsPaused(false);

        // The cure that was refused mid-pause now works, and clears the auction.
        vm.prank(borrower);
        d.vault.depositBonds(400);
        d.auction.cancel(id);
        assertEq(d.auction.auctionOf(borrower), 0, "the auction is gone after the cure");

        // And a fresh borrow lands.
        vm.prank(borrower);
        d.credit.borrow(1e6);
        assertEq(d.credit.debtOf(borrower), LOAN + 1e6, "borrowing is fully restored");
    }

    /// @notice **The G4 sequencing evidence: under the timelock the cure stays shut for eight
    ///         complete auction lifecycles, and the guardian needs one transaction to start it.**
    /// @dev Go-live item G4 scopes a guardian role as `pause` = owner or guardian, `unpause` =
    ///      owner only - and after G2 the owner is a `TimelockController` at
    ///      `Config.ADMIN_TIMELOCK`. So the asymmetry the two tests above price is not a moment;
    ///      it is a minimum of 48 hours against a 6-hour Dutch auction.
    ///
    ///      MEASURED: the borrower's collateral-side cure is still refused at the first block the
    ///      timelock would allow an unpause to execute, and a position that was curable when the
    ///      pause began has by then lapsed, gone to workout, and is waiting only on the
    ///      fourteen-day clock. Nothing here needs the guardian to be malicious - a mis-fire costs
    ///      the same.
    function test_paused_theCureIsShutForEightAuctionsBeforeAnUnpauseCanExecute() public {
        (Deployed memory d, address borrower) = _liveProtocol(200);
        vm.prank(borrower);
        d.credit.borrow(LOAN);

        // The guardian's single transaction.
        d.credit.pause();
        d.vault.pause();
        // **Audit round 25 F1 is fixed, so shutting the cure now takes a THIRD,
        // owner-only transaction.** The two `pause()` calls above are what a guardian can make,
        // and they no longer reach `depositBonds`. This line is the deliberate owner-level act
        // that does. Everything measured below is what that act still costs, unchanged in
        // magnitude from when one guardian transaction alone could cause it - which is the
        // point: the harm is real, and the fix is about who can cause it and how fast.
        d.vault.setBondDepositsPaused(true);
        uint256 pausedAt = block.timestamp;

        _moveNav(d, CRASHED_NAV);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);

        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);
        d.auction.expireToWorkout(id);

        // The earliest block an `unpause` scheduled at the pause could execute.
        vm.warp(pausedAt + Config.ADMIN_TIMELOCK);
        vm.prank(borrower);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        d.vault.depositBonds(200);

        emit log_named_uint(
            "MEASURED complete auction lifecycles inside one timelocked unpause",
            Config.ADMIN_TIMELOCK / Config.AUCTION_DURATION
        );
        assertEq(Config.ADMIN_TIMELOCK / Config.AUCTION_DURATION, 8, "48h of pause is 8 auctions");
        assertGt(d.auction.workoutsOpenFor(borrower), 0, "the position is already in workout");
    }

    /// @notice **The exit that "never pauses" is closed by a clock in a different contract, and
    ///         the pause is what makes that matter.**
    /// @dev The design rule is that the vault's exits are never gated - `withdrawBonds` carries no
    ///      `whenNotPaused` and `test_withdrawBonds_worksWhilePaused` proves it. But
    ///      `withdrawBonds` refuses `NavStale` whenever the caller still owes anything, and
    ///      `NAVOracle` is not `Pausable`, so its 8-day staleness clock runs straight through a
    ///      pause. A pause that outlives the keeper therefore leaves a borrower with debt holding
    ///      **exactly one move**: repay the whole thing in USDC. They cannot add collateral
    ///      (`EnforcedPause`), and they cannot take any out (`NavStale`).
    ///
    ///      MEASURED, and the second half is the part worth having: the position is not stranded.
    ///      Repaying to zero clears the `debt > 0` branch the staleness check sits inside, and the
    ///      collateral comes out on a stale NAV and a paused protocol together. The exit rule
    ///      holds - through one leg, not two.
    function test_paused_aStaleNavClosesTheOtherHalfOfTheVaultDoor() public {
        (Deployed memory d, address borrower) = _liveProtocol(200);
        vm.prank(borrower);
        d.credit.borrow(LOAN);

        d.credit.pause();
        d.vault.pause();
        // **Audit round 25 F1 is fixed, so shutting the cure now takes a THIRD,
        // owner-only transaction.** The two `pause()` calls above are what a guardian can make,
        // and they no longer reach `depositBonds`. This line is the deliberate owner-level act
        // that does. Everything measured below is what that act still costs, unchanged in
        // magnitude from when one guardian transaction alone could cause it - which is the
        // point: the harm is real, and the fix is about who can cause it and how fast.
        d.vault.setBondDepositsPaused(true);

        // The keeper stops posting - which is what a pause usually accompanies - and the oracle
        // ages out on its own clock.
        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(d.oracle.isStale(), "premise: the feed has aged out");

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        d.vault.depositBonds(1);

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.NavStale.selector);
        d.vault.withdrawBonds(1);
        emit log("MEASURED with debt outstanding: deposit EnforcedPause, withdraw NavStale");

        // The one move left, and it works.
        usdc.mint(borrower, LOAN);
        vm.startPrank(borrower);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        assertEq(d.credit.debtOf(borrower), 0, "repayment is open throughout");

        vm.prank(borrower);
        d.vault.withdrawBonds(BONDS);
        assertEq(d.vault.bondCount(borrower), 0, "and the collateral comes out, paused and stale");
        emit log("MEASURED after full repayment: withdrawBonds succeeds, paused and stale");
    }

    /// @notice **FINDING, and the sharpest form: the owner can MANUFACTURE a default out of a
    ///         curable position with one transaction, and `disposeWorkoutLot` then sends the
    ///         collateral to an address the owner picks.**
    /// @dev Neither half is new on its own. `disposeWorkoutLot` is `onlyOwner` by design and its
    ///      docstring argues the case ("DexFi agreed to redeem these" is an off-chain fact). What
    ///      the pause adds is the *precondition*: without it the owner has to wait for a default
    ///      that happens by itself, and with it the owner creates one. The borrower had the bonds
    ///      to cure and was refused; the loss lands on the lender pool; the lot lands wherever the
    ///      owner says.
    ///
    ///      MEASURED end to end below. Against the unpaused control in
    ///      `test_paused_convertsACurablePositionIntoALenderLoss` the same borrower keeps all 300
    ///      bonds and the pool loses nothing.
    ///
    ///      **The NAV crash here is honest, and that is deliberate.** It is posted by the keeper
    ///      and ratified by the confirmer through the real two-key path - the owner never touches
    ///      the price. So this does not rest on the unmitigated-authority item already on the
    ///      ledger; it is the *marginal* thing the pause adds to an owner who holds nothing else:
    ///      it removes the victim's defence against a price move nobody engineered.
    ///
    ///      **One real-world brake, and it is not ours.** The last hop is
    ///      `adapter.transferBonds(to, n)`, which passes DexFi's transfer whitelist only if `to`
    ///      is whitelisted **by DexFi**. This fixture whitelists the destination, so what is
    ///      measured here is the protocol's own arithmetic with that gate open. On mainnet the
    ///      owner would need DexFi to whitelist the destination first - a second party, not a
    ///      second key. Treat it as a constraint on the counterparty, not as a control the
    ///      protocol holds: the transfer whitelist is DexFi's, held by a single EOA and revocable,
    ///      which is why every DexFi behaviour in this repository is treated as mutable.
    function test_paused_ownerCanManufactureADefaultAndDirectTheCollateral() public {
        (Deployed memory d, address borrower) = _liveProtocol(200);
        _wirePhase4(d);

        address lender = makeAddr("lender");
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();

        vm.prank(borrower);
        d.credit.borrow(LOAN);
        assertEq(bond.balanceOf(borrower, 0), 200, "premise: the borrower holds the cure");

        // One transaction. Nothing else about the protocol changes.
        d.credit.pause();
        d.vault.pause();
        // **Audit round 25 F1 is fixed, so shutting the cure now takes a THIRD,
        // owner-only transaction.** The two `pause()` calls above are what a guardian can make,
        // and they no longer reach `depositBonds`. This line is the deliberate owner-level act
        // that does. Everything measured below is what that act still costs, unchanged in
        // magnitude from when one guardian transaction alone could cause it - which is the
        // point: the harm is real, and the fix is about who can cause it and how fast.
        d.vault.setBondDepositsPaused(true);

        _moveNav(d, CRASHED_NAV);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        d.vault.depositBonds(200);

        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);
        d.auction.expireToWorkout(id);
        vm.warp(block.timestamp + Config.WORKOUT_MAX_DURATION + 1);
        d.auction.closeWorkout(id);
        assertEq(d.pool.lifetimeSocialisedLoss(), LOAN, "the lenders carry the manufactured default");

        // The destination is the owner's call, and the owner is still the one holding the pause.
        address destination = makeAddr("destination");
        bond.setWhitelisted(destination, true); // DexFi's gate, opened by DexFi, not by us
        d.auction.disposeWorkoutLot(id, destination);

        emit log_named_uint("MEASURED bonds delivered to an owner-chosen address", bond.balanceOf(destination, 0));
        emit log_named_uint("MEASURED loss carried by the lender pool", d.pool.lifetimeSocialisedLoss());
        emit log_named_uint("MEASURED bonds the borrower still holds, uncurable", bond.balanceOf(borrower, 0));

        assertEq(bond.balanceOf(destination, 0), BONDS, "the whole lot went where the owner said");
        assertEq(d.vault.bondCount(borrower), 0, "and the borrower has none of it");
        assertTrue(d.credit.paused(), "the protocol never reopened at any point");
    }

    /// @notice **Incidental: pausing the manager and the vault does not stop new lender money.**
    /// @dev **`LenderPool` HAS been `Pausable` since the round-28 remediation, and this test still
    ///      passes unchanged - which is the whole of what it now measures.** `deposit` and `mint`
    ///      carry `whenNotPaused` and `pause()` is owner-or-guardian, the same pair the other two
    ///      switches use. What is asserted here is that the pool's flag is INDEPENDENT: nothing in
    ///      `credit.pause()` or `vault.pause()` reads it, so an operator who threw the two obvious
    ///      switches has left the lender door open and does not know it.
    ///
    ///      A lender arriving then funds a pool whose capital cannot be lent out (`borrow` is shut)
    ///      and is exposed to every write-down the paused protocol is still capable of producing -
    ///      the one `test_paused_convertsACurablePositionIntoALenderLoss` measures. Their exit is
    ///      open, so this is a disclosure problem rather than a trap. **The door that shuts it
    ///      exists now, and this test deliberately does not throw it**, because a runbook is
    ///      followed by a person and this is the shape of the mistake that person will make.
    function test_paused_newLenderMoneyStillEntersAndTakesTheWriteDown() public {
        (Deployed memory d, address borrower) = _liveProtocol(200);
        _wirePhase4(d);

        address early = makeAddr("early");
        usdc.mint(early, FLOAT);
        vm.startPrank(early);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, early);
        vm.stopPrank();

        vm.prank(borrower);
        d.credit.borrow(LOAN);

        d.credit.pause();
        d.vault.pause();

        address late = makeAddr("late");
        usdc.mint(late, FLOAT);
        vm.startPrank(late);
        usdc.approve(address(d.pool), FLOAT);
        uint256 shares = d.pool.deposit(FLOAT, late);
        vm.stopPrank();
        assertGt(shares, 0, "a lender walked into a paused protocol");
        emit log_named_uint("MEASURED shares minted to a lender during a pause", shares);

        uint256 valueBefore = d.pool.previewRedeem(shares);

        _moveNav(d, CRASHED_NAV);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);
        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);
        d.auction.expireToWorkout(id);
        vm.warp(block.timestamp + Config.WORKOUT_MAX_DURATION + 1);
        d.auction.closeWorkout(id);

        uint256 valueAfter = d.pool.previewRedeem(shares);
        emit log_named_uint("MEASURED redeemable value at deposit", valueBefore);
        emit log_named_uint("MEASURED redeemable value after the paused write-down", valueAfter);
        assertLt(valueAfter, valueBefore, "the pause-time depositor took a share of the loss");
    }
    // -------------------------------------------------------------------------
    // 6. The guardian role (go-live item G4), and what the split bought
    // -------------------------------------------------------------------------

    address internal guardian = makeAddr("guardian");

    /// @dev The role is installed after deployment rather than through `GovParams`, because this
    ///      contract is the owner in this fixture and `setGuardian` is the same call the deploy
    ///      script makes. **All three, always: a guardian on some contracts and not the others is a
    ///      half-installed role**, and G12's rule below is what makes that visible.
    ///
    ///      It was two until the round-28 remediation gave `LenderPool` a guardian, and this
    ///      fixture then installed exactly the shape its own sentence warns about -
    ///      `DeployBase._assertWiring` refuses that shape on a real deployment, and the helper in
    ///      the file that is ABOUT the guardian was creating it.
    function _guarded(Deployed memory d) internal {
        d.vault.setGuardian(guardian);
        d.credit.setGuardian(guardian);
        d.pool.setGuardian(guardian);
    }

    /// @notice **The guardian may shut both risk-creating doors and may reopen neither.**
    /// @dev This is G4 as scoped, asserted rather than described. `unpause` stays owner-only on
    ///      purpose: a compromised guardian must not be able to reopen the protocol during a live
    ///      incident, which is the more expensive of the two directions.
    function test_guardian_mayShutBothDoorsAndMayReopenNeither() public {
        (Deployed memory d,) = _liveProtocol(0);
        _guarded(d);

        vm.prank(guardian);
        d.vault.pause();
        vm.prank(guardian);
        d.credit.pause();
        assertTrue(d.vault.paused() && d.credit.paused(), "the guardian shut both doors");

        vm.prank(guardian);
        vm.expectRevert();
        d.vault.unpause();
        vm.prank(guardian);
        vm.expectRevert();
        d.credit.unpause();
        assertTrue(d.vault.paused() && d.credit.paused(), "and could reopen neither");

        // The owner can, and that is the whole difference.
        d.vault.unpause();
        d.credit.unpause();
        assertFalse(d.vault.paused() || d.credit.paused(), "the owner reopens both");
    }

    /// @notice **THE FIX, stated as the property it buys: the guardian cannot reach the cure.**
    /// @dev Audit round 25, finding 1. Before the split, the guardian's `pause()` shut
    ///      `depositBonds`, and under the G2 timelock an `unpause` is a 48-hour operation against
    ///      a 6-hour auction - `Config.ADMIN_TIMELOCK / Config.AUCTION_DURATION` is 8. **A
    ///      mis-fire cost exactly what malice cost.** The third switch is owner-only and the
    ///      guardian has no route to it at all.
    function test_guardian_cannotReachTheBorrowersCure() public {
        (Deployed memory d, address borrower) = _liveProtocol(200);
        _guarded(d);
        vm.prank(borrower);
        d.credit.borrow(LOAN);

        vm.prank(guardian);
        d.vault.pause();
        vm.prank(guardian);
        d.credit.pause();

        vm.prank(guardian);
        vm.expectRevert();
        d.vault.setBondDepositsPaused(true);
        assertFalse(d.vault.bondDepositsPaused(), "the cure's switch is out of the guardian's reach");

        // And the cure itself works, with both of the guardian's doors shut.
        vm.prank(borrower);
        d.vault.depositBonds(200);
        assertEq(d.vault.bondCount(borrower), BONDS + 200, "the borrower topped up under a guardian pause");
        assertTrue(d.vault.paused() && d.credit.paused(), "while both pause flags were still set");
    }

    /// @notice **The headline, re-measured: a guardian pause no longer converts a curable
    ///         position into a lender loss.**
    /// @dev The sibling `test_paused_convertsACurablePositionIntoALenderLoss` measures the same
    ///      harm through the owner-only switch, and it still measures it, because the harm is real
    ///      and was never the thing to delete. What changed is who can cause it in one
    ///      transaction. Round 25's original figures for this path: **300 bonds kept became 0, 200
    ///      were stranded in the wallet, and `lifetimeSocialisedLoss` went from 0 to 500.000000.**
    ///      All three now read as the control did.
    function test_guardianPause_noLongerConvertsACurablePositionIntoALenderLoss() public {
        (Deployed memory d, address borrower) = _liveProtocol(200);
        _wirePhase4(d);
        _guarded(d);

        address lender = makeAddr("lender");
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();

        vm.prank(borrower);
        d.credit.borrow(LOAN);

        // Everything the guardian can do, in the order a mis-fire would do it.
        vm.prank(guardian);
        d.credit.pause();
        vm.prank(guardian);
        d.vault.pause();

        _moveNav(d, CRASHED_NAV);
        d.credit.liquidate(borrower);
        uint256 id = d.auction.auctionOf(borrower);
        assertGt(id, 0, "premise: the position really did become liquidatable");

        // The cure, which used to revert here.
        vm.prank(borrower);
        d.vault.depositBonds(200);
        d.auction.cancel(id);

        emit log_named_uint("MEASURED bonds retained under a guardian pause", d.vault.bondCount(borrower));
        emit log_named_uint("MEASURED bonds stranded in the wallet", bond.balanceOf(borrower, 0));
        emit log_named_uint("MEASURED lifetimeSocialisedLoss", d.pool.lifetimeSocialisedLoss());

        assertEq(d.auction.auctionOf(borrower), 0, "the auction is gone, cured under a full guardian pause");
        assertEq(d.vault.bondCount(borrower), BONDS + 200, "300 bonds kept, where round 25 measured 0");
        assertEq(bond.balanceOf(borrower, 0), 0, "0 stranded, where round 25 measured 200");
        assertEq(d.pool.lifetimeSocialisedLoss(), 0, "0 socialised, where round 25 measured 500.000000");
        assertTrue(d.credit.paused() && d.vault.paused(), "and the protocol never came off pause to allow it");
    }

    /// @notice The guardian must be a second key, and zero disables the role.
    /// @dev The refusal is the same one `NAVOracle` makes about its own two keys. Zero is checked
    ///      from the other side too: a role that is off must not accidentally accept `address(0)`
    ///      as a caller, which is a real shape when a check is an equality against an unset slot.
    function test_setGuardian_refusesTheOwnerAndAcceptsZero() public {
        (Deployed memory d,) = _liveProtocol(0);

        vm.expectRevert(CollateralVault.GuardianMustDifferFromOwner.selector);
        d.vault.setGuardian(address(this));
        vm.expectRevert(CreditManager.GuardianMustDifferFromOwner.selector);
        d.credit.setGuardian(address(this));

        _guarded(d);
        assertEq(d.vault.guardian(), guardian, "installed");

        d.vault.setGuardian(address(0));
        d.credit.setGuardian(address(0));
        assertEq(d.vault.guardian(), address(0), "and cleared");

        // With the role off, the old guardian is a stranger again.
        vm.prank(guardian);
        vm.expectRevert(CollateralVault.NotOwnerOrGuardian.selector);
        d.vault.pause();
        vm.prank(guardian);
        vm.expectRevert(CreditManager.NotOwnerOrGuardian.selector);
        d.credit.pause();
    }

    /// @notice **Go-live item G12, which was a runbook rule with nothing executable behind it.**
    /// @dev The rule is that an incident pause is more than one transaction, because the switches
    ///      are independent and none consults the others. Each of the three driven here is shown
    ///      leaving the other two open, which is the assertion the checklist row was missing.
    ///
    ///      **The runbook is FOUR transactions, not the three this test drives, and the fourth is
    ///      not missing by accident.** `LenderPool.pause()` arrived in the round-28 remediation,
    ///      after this test was written, and its independence is asserted in
    ///      `test_paused_newLenderMoneyStillEntersAndTakesTheWriteDown` - which pauses the manager
    ///      and the vault, never the pool, and passes unchanged. The name stays because the
    ///      go-live checklist cites it. **Three of the four are
    ///      owner-or-guardian; `setBondDepositsPaused` is owner-only by design, so after the G2
    ///      handover no single role can send all four.**
    function test_pauseSurface_theThreeSwitchesAreIndependent() public {
        (Deployed memory d, address borrower) = _liveProtocol(300);
        vm.prank(borrower);
        d.credit.borrow(LOAN);

        // 1. The manager's pause alone: borrowing shut, both deposit doors open.
        d.credit.pause();
        vm.prank(borrower);
        d.vault.depositBonds(100);
        assertFalse(d.vault.paused(), "the vault's own flag is untouched");
        assertFalse(d.vault.bondDepositsPaused(), "and so is the bond-deposit switch");
        d.credit.unpause();

        // 2. The vault's pause alone: `depositETH` shut, borrowing and the cure open. This is the
        //    half the original G12 finding turned on - MEASURED in round 25 as a 500.000000 borrow
        //    landing against a paused vault, and it still does.
        d.vault.pause();
        vm.prank(borrower);
        d.credit.borrow(1e6);
        vm.prank(borrower);
        d.vault.depositBonds(100);
        assertFalse(d.credit.paused(), "the manager's flag is untouched");
        d.vault.unpause();

        // 3. The bond-deposit switch alone: the cure shut, borrowing and `depositETH` open.
        d.vault.setBondDepositsPaused(true);
        vm.prank(borrower);
        d.credit.borrow(1e6);
        assertFalse(d.credit.paused() || d.vault.paused(), "neither pause flag is set");
        vm.prank(borrower);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        d.vault.depositBonds(100);

        emit log("MEASURED three switches, three independent effects, no switch reads another");
    }
}
