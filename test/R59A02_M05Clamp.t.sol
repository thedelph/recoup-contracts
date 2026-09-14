// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 59, target 3: M-05's terminal-state clamp driven against the levers it does NOT
///        read, and the question of whether a backlog can strand a second way.
/// @notice The clamp shipped in #531 (`b997d88`) fires only when
///         `capital != 0 && depositCap == Config.GLOBAL_BORROW_CAP_MAX && depositCapUsage() >=
///         depositCap`, and only from inside the `liquidityDeficitBefore == 0 && streamable >
///         capital` arm. Everything below is measurement of shipped behaviour at `c9b5f95`.
///
/// @dev The predicate deliberately reads `depositCapUsage` rather than `maxDeposit`, on the stated
///      ground that a pause, a deficit or a price gate also zero `maxDeposit` and every one of
///      those is "a state something can still change". The tests here ask whether that is true of
///      each one in turn, and find one where it is not.
contract R59A02_M05Clamp is Test {
    uint256 internal constant MIN_SUPPLY_FOR_YIELD = (10 ** 3) * Config.BPS;
    uint256 internal constant CEILING = Config.GLOBAL_BORROW_CAP_MAX; // 250,000.000000

    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal manager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal whale = makeAddr("whale");
    address internal squatter = makeAddr("squatter");
    address internal newcomer = makeAddr("newcomer");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        pool.setCreditManager(manager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        shares = pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _offer(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(harvester);
        pool.distributeYield(amount);
    }

    /// @dev The terminal state the clamp was built for: the cap pinned at the constant and the
    ///      book consuming every wei of it.
    function _fullAtTheHardCeiling() internal {
        vm.prank(admin);
        pool.setDepositCap(CEILING);
        _deposit(whale, CEILING);
        assertEq(pool.depositCap(), CEILING, "fixture: cap not at the constant");
        assertGe(pool.depositCapUsage(), pool.depositCap(), "fixture: the book does not consume the cap");
        assertEq(pool.maxDeposit(newcomer), 0, "fixture: the door is not shut");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The clamp against each lever that is not in its predicate
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice PAUSE. `distributeYield` carries no `whenNotPaused`, so the clamp fires through a
    ///         pause exactly as it does without one, and a paused pool at the ceiling still drains
    ///         its backlog. Stated because a reader of the predicate's own comment could expect
    ///         the opposite.
    function test_R59A02_M05_theClampFiresThroughAPause() public {
        _fullAtTheHardCeiling();
        vm.prank(admin);
        pool.pause();
        assertTrue(pool.paused(), "fixture: not paused");
        assertEq(pool.maxDeposit(newcomer), 0, "fixture: the door is not shut");

        uint256 capital = pool.totalAssets();
        uint256 backlog = capital * 3;
        uint256 cashBefore = usdc.balanceOf(address(pool));
        _offer(backlog);

        emit log_named_uint("MEASURED capital                          ", capital);
        emit log_named_uint("MEASURED backlog offered                  ", backlog);
        emit log_named_uint("MEASURED pulled into the pool             ", usdc.balanceOf(address(pool)) - cashBefore);
        assertEq(usdc.balanceOf(address(pool)) - cashBefore, capital, "the clamp did not take exactly capital");
    }

    /// @notice BELOW THE CEILING the refusal is unchanged, and a pause does not make the pool look
    ///         terminal: a full pool under a partial cap still refuses the backlog, and raising the
    ///         cap to the constant is the lever that opens the clamp.
    function test_R59A02_M05_aPartialCapRefusesAndTheOwnerLeverOpensIt() public {
        vm.prank(admin);
        pool.setDepositCap(20_000e6);
        _deposit(whale, 20_000e6);
        assertEq(pool.maxDeposit(newcomer), 0, "fixture: the partial cap is not full");

        uint256 capital = pool.totalAssets();
        uint256 backlog = capital * 3;
        usdc.mint(harvester, backlog);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.YieldExceedsCapital.selector, backlog, capital));
        pool.distributeYield(backlog);

        // One wei under the constant is still a refusal: the predicate is an equality.
        vm.prank(admin);
        pool.setDepositCap(CEILING - 1);
        _deposit(whale, CEILING - 1 - 20_000e6);
        capital = pool.totalAssets();
        backlog = capital * 3;
        usdc.mint(harvester, backlog);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.YieldExceedsCapital.selector, backlog, capital));
        pool.distributeYield(backlog);
        emit log_named_uint("MEASURED cap one wei under the constant   ", pool.depositCap());
        emit log_named_uint("MEASURED refused backlog                  ", backlog);

        // Raise the cap the last wei and the same offer is clamped rather than refused.
        vm.prank(admin);
        pool.setDepositCap(CEILING);
        _deposit(whale, CEILING - pool.depositCapUsage());
        capital = pool.totalAssets();
        backlog = capital * 3;
        uint256 cashBefore = usdc.balanceOf(address(pool));
        _offer(backlog);
        emit log_named_uint("MEASURED clamped delivery at the constant ", usdc.balanceOf(address(pool)) - cashBefore);
        assertEq(usdc.balanceOf(address(pool)) - cashBefore, capital, "the clamp did not take exactly capital");
    }

    /// @notice RECONCILED EXTERNAL CASH LOSS. A loss of physical USDC drops `depositCapUsage`
    ///         below the cap, so the clamp stops firing and the backlog is refused again - which
    ///         is correct only if the reopened cap can actually be filled. Measured: it can.
    function test_R59A02_M05_aReconciledCashLossClosesTheClampAndReopensTheDoor() public {
        _fullAtTheHardCeiling();
        uint256 loss = 50_000e6;
        // An external loss of recognised cash: burn it out of the pool's balance.
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), loss);
        pool.reconcileCashDeficit();

        emit log_named_uint("MEASURED depositCapUsage after the loss   ", pool.depositCapUsage());
        emit log_named_uint("MEASURED depositCap                       ", pool.depositCap());
        emit log_named_uint("MEASURED maxDeposit after the loss        ", pool.maxDeposit(newcomer));
        assertLt(pool.depositCapUsage(), pool.depositCap(), "the usage did not fall");

        uint256 capital = pool.totalAssets();
        uint256 backlog = capital * 3;
        usdc.mint(harvester, backlog);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.YieldExceedsCapital.selector, backlog, capital));
        pool.distributeYield(backlog);

        // And the door the refusal relies on is genuinely open again.
        assertGt(pool.maxDeposit(newcomer), 0, "the door did not reopen, so the refusal strands");
    }

    /// @notice THE SECOND STRANDING, and the answer to the question the charge asks. A backlog can
    ///         be permanently undeliverable in a state the clamp does not cover, because the
    ///         refusal that fires is the OTHER one: `NoSharesOutstanding`, from the share-floor
    ///         guard above the clamp. Item 48's frozen sub-floor pool is that state: supply can
    ///         never return to `MIN_SUPPLY_FOR_YIELD` because entry pricing charges every entrant
    ///         for a pot that can never release, so `depositCapUsage() < depositCap` holds for ever
    ///         and the clamp's predicate is false for ever.
    function test_R59A02_M05_aFrozenSubFloorPoolStrandsTheBacklogWhereTheClampCannotReach() public {
        // The frozen sub-floor state (item 48's attacker route).
        _deposit(whale, 20e6);
        _offer(20e6);
        usdc.mint(squatter, 1_000e6);
        vm.startPrank(squatter);
        usdc.approve(address(pool), type(uint256).max);
        pool.mint(1, squatter);
        vm.stopPrank();
        uint256 whaleMax = pool.maxRedeem(whale);
        vm.prank(whale);
        pool.redeem(whaleMax, whale, whale);

        assertGt(pool.totalSupply(), 0, "fixture: supply reached zero");
        assertLt(pool.totalSupply(), MIN_SUPPLY_FOR_YIELD, "fixture: not in the sub-floor band");
        assertEq(pool.yieldRate(), 0, "fixture: the stream is not frozen");

        emit log_named_uint("MEASURED depositCap                       ", pool.depositCap());
        emit log_named_uint("MEASURED depositCapUsage                  ", pool.depositCapUsage());
        emit log_named_uint("MEASURED maxDeposit (the door LOOKS open) ", pool.maxDeposit(newcomer));
        emit log_named_uint(
            "MEASURED shares the whole cap would mint  ", pool.previewDeposit(pool.maxDeposit(newcomer))
        );
        emit log_named_uint("MEASURED the share floor it must reach    ", MIN_SUPPLY_FOR_YIELD);

        // The clamp's predicate is false here - the door is open on paper - and the refusal that
        // fires is the share-floor one, which the clamp never sees.
        assertLt(pool.depositCapUsage(), pool.depositCap(), "the usage already consumes the cap");
        uint256 backlog = 400_000e6;
        usdc.mint(harvester, backlog);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.NoSharesOutstanding.selector));
        pool.distributeYield(backlog);

        // And filling the whole remaining cap does not lift the pool over the floor, so the same
        // refusal stands after the only lever a reader would reach for.
        uint256 room = pool.maxDeposit(newcomer);
        usdc.mint(newcomer, room);
        vm.startPrank(newcomer);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(room, newcomer);
        vm.stopPrank();
        emit log_named_uint("MEASURED supply after the whole cap enters", pool.totalSupply());
        assertLt(pool.totalSupply(), MIN_SUPPLY_FOR_YIELD, "supply reached the floor after all");
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.NoSharesOutstanding.selector));
        pool.distributeYield(backlog);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Does the backlog actually drain?
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The drain, measured flush by flush at the ceiling: each clamped delivery makes the
    ///         pool larger by exactly what it took, so the next offer is capped higher. The series
    ///         is reported so the register can quote how many flushes a given backlog needs.
    function test_R59A02_M05_theBacklogDrainsGeometricallyOverSuccessiveFlushes() public {
        _fullAtTheHardCeiling();
        uint256 backlog = 2_000_000e6; // eight times the hard ceiling
        usdc.mint(harvester, backlog);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);

        uint256 remaining = backlog;
        uint256 flushes;
        for (uint256 i = 0; i < 16; i++) {
            uint256 capital = pool.totalAssets();
            if (capital == 0) break;
            uint256 before = usdc.balanceOf(address(pool));
            vm.prank(harvester);
            pool.distributeYield(remaining);
            uint256 took = usdc.balanceOf(address(pool)) - before;
            ++flushes;
            remaining -= took;
            emit log_named_uint("MEASURED flush took                      ", took);
            emit log_named_uint("MEASURED   backlog left                  ", remaining);
            if (remaining == 0) break;
            // Each flush's stream has to release before the next offer sees it as capital.
            vm.warp(pool.yieldStreamEndsAt() + 1);
        }
        emit log_named_uint("MEASURED flushes to drain 2,000,000      ", flushes);
        emit log_named_uint("MEASURED backlog still owed              ", remaining);
        assertEq(remaining, 0, "the backlog did not drain");
    }

    /// @notice The same drain with NO time passing between flushes, which is what a keeper hitting
    ///         a permissionless flush twice in one block would do. The unreleased pot is held out
    ///         of `capital`, so the second offer is clamped to a smaller figure and the drain is
    ///         slower rather than stalled.
    function test_R59A02_M05_backToBackFlushesInOneBlockStillMakeProgress() public {
        _fullAtTheHardCeiling();
        uint256 backlog = 2_000_000e6;
        usdc.mint(harvester, backlog);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);

        uint256 remaining = backlog;
        uint256 flushes;
        for (uint256 i = 0; i < 8; i++) {
            uint256 capital = pool.totalAssets();
            if (capital == 0) break;
            uint256 before = usdc.balanceOf(address(pool));
            vm.prank(harvester);
            pool.distributeYield(remaining);
            uint256 took = usdc.balanceOf(address(pool)) - before;
            ++flushes;
            remaining -= took;
            emit log_named_uint("MEASURED same-block flush took           ", took);
            emit log_named_uint("MEASURED   capital seen by that flush    ", capital);
            if (remaining == 0) break;
        }
        emit log_named_uint("MEASURED same-block flushes                ", flushes);
        emit log_named_uint("MEASURED backlog still owed               ", remaining);
    }
}
