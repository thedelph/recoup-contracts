// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 60, S1: adversarial probes on the request-draw memory (33audits H-03, issue #47).
/// @notice Every probe runs on the tree that carries the memory. Where a figure differs on the
///         shipped tree (`68ac048`, before the memory) the docstring says what it read there, so
///         the file states what the fix changed and what it left alone.
///
/// @dev The memory is `mapping(address => RequestDraw) private _requestDraws` at slot 32 with no
///      getter; `_draw` reads it through `vm.load` and probe 10 pins that slot by writing through
///      the door and reading the same figure back, so a layout move fails here loudly.
///
///      Base fixture (`_counterCase`): blocker 10,000, attacker 10,000, 15,000 lent, blocker queued.
///      E = 5,000, S = 20,000, q = 10,000, price 1. `_drawOnce` is the attacker's one permitted
///      draw under the memory: request all, service `maxRequestRedeem` once, 2,500.000000.
contract R60S1_H03Probes is Test {
    uint256 internal constant REQUEST_DRAWS_SLOT = 32;

    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal borrower = makeAddr("borrower");
    address internal sink = makeAddr("cash-sink");

    address internal attacker = makeAddr("attacker");
    address internal blocker = makeAddr("blocker");
    address internal bystander = makeAddr("bystander");
    address internal carol = makeAddr("carol");
    address internal fresh = makeAddr("fresh");
    address internal operator = makeAddr("operator");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        pool.setCreditManager(manager);
        pool.setEpochHarvester(harvester);
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
        vm.stopPrank();
        vm.prank(manager);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(harvester);
        usdc.approve(address(pool), type(uint256).max);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        shares = pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _lend(uint256 amount) internal {
        vm.prank(manager);
        pool.lend(amount);
    }

    function _repay(uint256 amount) internal {
        usdc.mint(manager, amount);
        vm.prank(manager);
        pool.repayPrincipal(amount);
    }

    function _counterCase() internal {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(15_000e6);
        uint256 blockerShares = pool.balanceOf(blocker);
        vm.prank(blocker);
        pool.requestWithdrawal(blockerShares, blocker);
        assertEq(pool.queueCashReserve(), 2_500e6, "fixture: the blocker's reserve is not 2,500");
    }

    /// @dev Request every share and service the maximum once. Returns what it paid.
    function _drawOnce(address who) internal returns (uint256 paid) {
        uint256 shares = pool.balanceOf(who);
        vm.startPrank(who);
        pool.requestWithdrawal(shares, who);
        uint256 serviceable = pool.maxRequestRedeem(who);
        if (serviceable != 0) paid = pool.serviceWithdrawalRequest(who, serviceable, 0);
        vm.stopPrank();
    }

    function _serviceable(address who) internal view returns (uint256) {
        return pool.previewRedeem(pool.maxRequestRedeem(who));
    }

    function _executable() internal view returns (uint256) {
        return pool.unreservedIdle() + pool.queueCashReserve();
    }

    function _draw(address who) internal view returns (uint256 shares, uint256 assets) {
        bytes32 base = keccak256(abi.encode(who, REQUEST_DRAWS_SLOT));
        shares = uint256(vm.load(address(pool), base));
        assets = uint256(vm.load(address(pool), bytes32(uint256(base) + 1)));
    }

    /// @dev The entitlement a controller with NO memory would read for `shares` requested now.
    function _freshSlice(uint256 shares) internal view returns (uint256) {
        return (_executable() * shares) / pool.totalSupply();
    }

    function _syncLoop(address who) internal returns (uint256 total, uint256 calls) {
        for (uint256 i = 0; i < 128; i++) {
            uint256 shares = pool.maxRedeem(who);
            if (shares == 0) break;
            vm.prank(who);
            total += pool.redeem(shares, who, who);
            ++calls;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1 and 2. The two routes the memory does not see, and the mixed route
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The stepped sync door is untouched by the memory: 4,999.999998 over 53 calls, the
    ///         shipped tree's figure to the wei (`R60S1_H03Routes`). And the MIXED route - one
    ///         permitted draw, cancel, then walk the returned shares through the sync door -
    ///         reaches the same total, so the memory closes the same-controller request loop
    ///         and nothing beside it.
    function test_R60S1_probe01_theSyncLoopIsUnchangedAndTheMixedRouteDrainsToo() public {
        _counterCase();
        uint256 clean = vm.snapshotState();

        (uint256 syncTotal, uint256 syncCalls) = _syncLoop(attacker);

        vm.revertToState(clean);
        uint256 drawn = _drawOnce(attacker);
        vm.prank(attacker);
        pool.cancelWithdrawalRequest();
        (uint256 mixedSync, uint256 mixedCalls) = _syncLoop(attacker);

        console2.log("MEASURED sync loop under the memory, total  ", syncTotal);
        console2.log("MEASURED sync loop under the memory, calls  ", syncCalls);
        console2.log("MEASURED mixed route, one draw              ", drawn);
        console2.log("MEASURED mixed route, sync loop after       ", mixedSync);
        console2.log("MEASURED mixed route, total                 ", drawn + mixedSync);
        console2.log("MEASURED mixed route, sync calls            ", mixedCalls);
        console2.log("MEASURED blocker serviceable after mixed    ", _serviceable(blocker));

        assertEq(syncTotal, 4_999_999_998, "the memory moved the sync loop");
        assertEq(syncCalls, 53, "the memory moved the sync loop's call count");
        assertEq(drawn, 2_500e6, "the one permitted draw paid other than 2,500");
        assertGt(drawn + mixedSync, 4_999e6, "the mixed route did not drain the queued lender");
    }

    /// @notice The sequential address split under the memory: identical to the shipped tree,
    ///         because every fresh controller reads an empty memory. Forty addresses, one draw
    ///         each, cancel, move the remainder on.
    function test_R60S1_probe02_theSequentialAddressSplitIsUnchanged() public {
        _counterCase();
        uint256 total;
        address holder = attacker;
        for (uint256 i = 0; i < 40; i++) {
            uint256 shares = pool.balanceOf(holder);
            if (shares == 0) break;
            vm.startPrank(holder);
            pool.requestWithdrawal(shares, holder);
            uint256 serviceable = pool.maxRequestRedeem(holder);
            if (serviceable != 0) total += pool.serviceWithdrawalRequest(holder, serviceable, 0);
            (,, uint256 remaining,,) = pool.withdrawalRequest(holder);
            if (remaining != 0) pool.cancelWithdrawalRequest();
            address next = address(uint160(0x60520000 + i));
            uint256 left = pool.balanceOf(holder);
            if (left != 0) pool.transfer(next, left);
            vm.stopPrank();
            (uint256 memShares,) = _draw(holder);
            assertGt(memShares, 0, "the drained controller's memory was cleared with shares moved out");
            holder = next;
        }
        console2.log("MEASURED sequential split under the memory  ", total);
        console2.log("MEASURED blocker serviceable after          ", _serviceable(blocker));
        assertEq(total, 4_999_999_773, "the memory moved the sequential split");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. The phantom reserve
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After the attacker's one permitted draw its remaining 7,500 queued shares are
    ///         entitled to NOTHING more, yet `queueCashReserve` still counts them: the reserve
    ///         reads 2,500 while the sum of every controller's serviceable cash is 1,428.571428.
    ///         The difference is cash nobody can draw: not the blocker, not the sync door, not
    ///         `lend`. A full repayment restores E/S to the ratio at the draw and the phantom
    ///         closes; a partial one does not.
    function test_R60S1_probe03_thePhantomReserve() public {
        _counterCase();
        uint256 drawn = _drawOnce(attacker);

        uint256 reserve = pool.queueCashReserve();
        uint256 sum = _serviceable(blocker) + _serviceable(attacker);
        console2.log("MEASURED one permitted draw                 ", drawn);
        console2.log("MEASURED queueCashReserve after the draw    ", reserve);
        console2.log("MEASURED blocker serviceable                ", _serviceable(blocker));
        console2.log("MEASURED attacker serviceable (drawn)       ", _serviceable(attacker));
        console2.log("MEASURED sum of serviceable cash            ", sum);
        console2.log("MEASURED PHANTOM: reserve minus the sum     ", reserve - sum);
        console2.log("MEASURED unreservedIdle                     ", pool.unreservedIdle());
        console2.log("MEASURED available()                        ", pool.available());

        assertEq(reserve, 2_500e6, "the reserve after the draw is not 2,500");
        assertEq(sum, 1_428_571_428, "the serviceable sum is not 1,428.571428");
        assertEq(reserve - sum, 1_071_428_572, "the phantom is not 1,071.428572");
        assertEq(pool.unreservedIdle(), 0, "the phantom left the sync door open");

        // A full repayment: E / S returns to 1, the ratio at the draw, and the phantom closes.
        _repay(15_000e6);
        uint256 reserveAfter = pool.queueCashReserve();
        uint256 sumAfter = _serviceable(blocker) + _serviceable(attacker);
        console2.log("MEASURED after repaying 15,000: reserve     ", reserveAfter);
        console2.log("MEASURED after repaying 15,000: blocker     ", _serviceable(blocker));
        console2.log("MEASURED after repaying 15,000: attacker    ", _serviceable(attacker));
        console2.log("MEASURED after repaying 15,000: phantom     ", reserveAfter - sumAfter);
        assertEq(reserveAfter - sumAfter, 0, "a full repayment did not close the phantom");
    }

    /// @notice The phantom seen by a third lender: with the attacker's spent queue still counted,
    ///         the bystander's `maxRedeem` and the manager's `available()` are both smaller than
    ///         the cash nobody is entitled to would allow. Three lenders, 20,000 lent.
    function test_R60S1_probe03b_thePhantomShutsTheBystanderOut() public {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _deposit(bystander, 5_000e6);
        _lend(20_000e6);
        uint256 blockerShares = pool.balanceOf(blocker);
        vm.prank(blocker);
        pool.requestWithdrawal(blockerShares, blocker);

        uint256 bystanderBefore = pool.previewRedeem(pool.maxRedeem(bystander));
        uint256 drawn = _drawOnce(attacker);
        uint256 reserve = pool.queueCashReserve();
        uint256 sum = _serviceable(blocker) + _serviceable(attacker);
        uint256 bystanderAfter = pool.previewRedeem(pool.maxRedeem(bystander));

        console2.log("MEASURED bystander maxRedeem before         ", bystanderBefore);
        console2.log("MEASURED one permitted draw                 ", drawn);
        console2.log("MEASURED reserve / serviceable sum / phantom", reserve);
        console2.log("MEASURED serviceable sum                    ", sum);
        console2.log("MEASURED phantom                            ", reserve - sum);
        console2.log("MEASURED bystander maxRedeem after          ", bystanderAfter);
        console2.log("MEASURED available()                        ", pool.available());
        assertGt(reserve, sum, "no phantom in the three-lender state");
        assertLt(bystanderAfter, _executable() - sum, "the bystander could reach the un-entitled cash");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. The never-cleared memory, from the lender's side
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A controller who requested HALF her position and was fully serviced keeps the
    ///         memory (her balance is non-zero). When E / S later falls below the ratio she drew
    ///         at, her next request is under-paid against a fresh address holding the same shares:
    ///         `(S - req)(E * dS - S * dA) / (S (S + dS))`, negative here. And a sync exit to zero
    ///         does NOT clear the memory, so it follows her into a re-deposit.
    function test_R60S1_probe04_theMemoryOutlivesThePositionItPriced() public {
        _deposit(carol, 10_000e6);
        _deposit(bystander, 10_000e6);

        // Half her shares, fully serviced at price 1: memory (5,000 shares, 5,000 assets).
        vm.startPrank(carol);
        pool.requestWithdrawal(5_000e9, carol);
        uint256 first = pool.serviceWithdrawalRequest(carol, pool.maxRequestRedeem(carol), 0);
        vm.stopPrank();
        (uint256 dS, uint256 dA) = _draw(carol);
        assertEq(first, 5_000e6, "fixture: the half request was not fully serviced");
        assertEq(dS, 5_000e9, "the memory did not record the shares");
        assertEq(dA, 5_000e6, "the memory did not record the assets");
        assertEq(pool.balanceOf(carol), 5_000e9, "fixture: carol should hold half");

        // E / S falls below dA / dS: the manager lends what it can and the book stays at price 1
        // but executable cash per share falls.
        _lend(pool.available());
        uint256 E = _executable();
        uint256 S = pool.totalSupply();
        console2.log("MEASURED executable cash E                  ", E);
        console2.log("MEASURED supply S                           ", S);

        vm.prank(carol);
        pool.requestWithdrawal(5_000e9, carol);
        uint256 carolNow = _serviceable(carol);
        uint256 freshNow = _freshSlice(5_000e9);
        console2.log("MEASURED carol's second request, serviceable", carolNow);
        console2.log("MEASURED a fresh 5,000-share holder's slice ", freshNow);
        console2.log("MEASURED carol's UNDER-PAY                  ", freshNow - carolNow);
        // (S - req)(S * dA - E * dS) / (S (S + dS)), the sign flipped so it is the under-pay.
        uint256 predicted = ((S - 5_000e9) * (S * dA - E * dS)) / (S * (S + dS));
        console2.log("MEASURED predicted under-pay, unclamped     ", predicted);
        // The door clamps the entitlement at zero, so the under-pay cannot exceed the fresh
        // slice: here the formula says 2,125.000000 and carol is under-paid the whole 750.000000.
        if (predicted > freshNow) predicted = freshNow;
        assertLt(carolNow, freshNow, "the memory did not under-pay carol against a fresh holder");
        assertApproxEqAbs(freshNow - carolNow, predicted, 2, "the under-pay is not the formula's");
        assertEq(carolNow, 0, "carol reads other than ZERO with the ratio below her draw");

        // She cancels, the loan repays so the sync door can pay her whole balance, she
        // sync-redeems to ZERO, and the memory is still there.
        vm.prank(carol);
        pool.cancelWithdrawalRequest();
        _repay(pool.outstandingPrincipal());
        (uint256 syncOut,) = _syncLoop(carol);
        console2.log("MEASURED carol's sync exit paid             ", syncOut);
        assertEq(pool.balanceOf(carol), 0, "carol could not sync-exit to zero");
        (dS, dA) = _draw(carol);
        console2.log("MEASURED memory after the sync exit: shares ", dS);
        console2.log("MEASURED memory after the sync exit: assets ", dA);
        assertEq(dS, 5_000e9, "the sync exit cleared the memory (it must not, per the shape)");

        // The manager lends again so cash per share is below the ratio the memory holds; she
        // re-deposits, and her first request on the NEW position is priced with the OLD memory.
        _lend(pool.available());
        uint256 reShares = _deposit(carol, 5_000e6);
        vm.prank(carol);
        pool.requestWithdrawal(reShares, carol);
        uint256 carolRe = _serviceable(carol);
        uint256 freshRe = _freshSlice(reShares);
        console2.log("MEASURED re-deposit request, carol          ", carolRe);
        console2.log("MEASURED re-deposit request, fresh holder   ", freshRe);
        assertLt(carolRe, freshRe, "the stale memory did not follow carol into her re-deposit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Shares transferred IN to a controller holding a draw
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A controller with a live memory receives shares and requests the lot. The
    ///         reconstruction prices the whole request, incoming shares included, as if they had
    ///         been part of the drawn position: the incoming shares' slice is `E * s / S` fresh
    ///         and less than that here. Not a route to more cash; a route to less.
    function test_R60S1_probe05_sharesTransferredInAreRepricedByTheMemory() public {
        _counterCase();
        _deposit(bystander, 5_000e6);
        _drawOnce(attacker);
        vm.prank(attacker);
        pool.cancelWithdrawalRequest();

        vm.prank(bystander);
        pool.transfer(attacker, 5_000e9);
        uint256 all = pool.balanceOf(attacker);
        vm.prank(attacker);
        pool.requestWithdrawal(all, attacker);

        uint256 withMemory = _serviceable(attacker);
        uint256 freshAll = _freshSlice(all);
        uint256 freshIncoming = _freshSlice(5_000e9);
        console2.log("MEASURED request of 12,500 with the memory  ", withMemory);
        console2.log("MEASURED a fresh 12,500 holder's slice      ", freshAll);
        console2.log("MEASURED a fresh 5,000 holder's slice       ", freshIncoming);
        assertLe(withMemory, freshAll, "transferring shares in reached MORE than a fresh holder");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6, 7, 8. Loss, yield and supply moving between draws: bounded and never reverting
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A socialised loss and then a raw cash deficit between draws. The reconstructed
    ///         base can fall below the draw; the answer clamps to zero and the request cash never
    ///         exceeds the executable cash. Nothing reverts.
    function test_R60S1_probe06_lossBetweenDrawsClampsAndNeverReverts() public {
        _counterCase();
        _drawOnce(attacker);

        vm.prank(manager);
        pool.socialiseLoss(5_000e6);
        uint256 exec = _executable();
        console2.log("MEASURED after socialiseLoss: executable    ", exec);
        console2.log("MEASURED after socialiseLoss: attacker      ", _serviceable(attacker));
        console2.log("MEASURED after socialiseLoss: blocker       ", _serviceable(blocker));
        assertLe(_serviceable(attacker) + _serviceable(blocker), exec + 1, "request cash exceeded executable cash");

        // A raw deficit: cash leaves the contract with no book entry. The pool holds 5,000 raw of
        // which 2,500 is claimable, so 1,000 out leaves the claims covered: E falls by the loss
        // once reconciled and both entitlements fall with it, nothing reverts.
        vm.prank(address(pool));
        usdc.transfer(sink, 1_000e6);
        uint256 execAfterLoss = _executable();
        console2.log("MEASURED after a 1,000 raw deficit: executable", execAfterLoss);
        console2.log("MEASURED after a 1,000 raw deficit: attacker", _serviceable(attacker));
        console2.log("MEASURED after a 1,000 raw deficit: blocker ", _serviceable(blocker));
        assertEq(pool.claimLiquidityDeficit(), 0, "fixture: 1,000 out should leave the claims covered");
        assertLe(
            _serviceable(attacker) + _serviceable(blocker), execAfterLoss + 1, "request cash exceeded executable cash"
        );
        // Another 2,000 out: 2,000 raw against 2,500 of claims is a claim-liquidity deficit, and
        // both doors read zero, memory or none.
        vm.prank(address(pool));
        usdc.transfer(sink, 2_000e6);
        console2.log("MEASURED after 3,000 out: claimLiquidityDeficit", pool.claimLiquidityDeficit());
        assertGt(pool.claimLiquidityDeficit(), 0, "fixture: 3,000 out should uncover the claims");
        assertEq(pool.maxRequestRedeem(attacker), 0, "the request door stayed open across a claim deficit");
        assertEq(pool.maxRequestRedeem(blocker), 0, "the request door stayed open across a claim deficit");
    }

    /// @notice Yield delivered between draws, then the stream released. The drawn controller's
    ///         entitlement rises with E, the blocker's too, and neither exceeds executable cash.
    function test_R60S1_probe07_yieldBetweenDrawsIsFollowed() public {
        _counterCase();
        _drawOnce(attacker);
        uint256 attackerBefore = _serviceable(attacker);
        uint256 blockerBefore = _serviceable(blocker);

        usdc.mint(harvester, 1_000e6);
        vm.prank(harvester);
        pool.distributeYield(1_000e6);
        skip(Config.MAX_YIELD_STREAM_DURATION + 1);

        uint256 exec = _executable();
        console2.log("MEASURED executable after the stream        ", exec);
        console2.log("MEASURED attacker before / after            ", attackerBefore);
        console2.log("MEASURED attacker after                     ", _serviceable(attacker));
        console2.log("MEASURED blocker before                     ", blockerBefore);
        console2.log("MEASURED blocker after                      ", _serviceable(blocker));
        assertGt(_serviceable(attacker), attackerBefore, "the drawn controller did not follow the yield");
        assertGt(_serviceable(blocker), blockerBefore, "the blocker did not follow the yield");
        assertLe(_serviceable(attacker) + _serviceable(blocker), exec + 1, "request cash exceeded executable cash");
    }

    /// @notice Supply moved by a deposit and a sync exit between draws: no underflow in the
    ///         reconstruction and no entitlement above executable cash.
    function test_R60S1_probe08_supplyMovingBetweenDrawsNeverUnderflowsOrInflates() public {
        _counterCase();
        _drawOnce(attacker);

        _deposit(bystander, 5_000e6);
        uint256 afterDeposit = _serviceable(attacker);
        (uint256 out,) = _syncLoop(bystander);
        uint256 afterExit = _serviceable(attacker);
        uint256 exec = _executable();
        console2.log("MEASURED attacker after a 5,000 deposit     ", afterDeposit);
        console2.log("MEASURED bystander sync exit paid           ", out);
        console2.log("MEASURED attacker after the exit            ", afterExit);
        console2.log("MEASURED executable                         ", exec);
        assertLe(afterExit + _serviceable(blocker), exec + 1, "request cash exceeded executable cash");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Dust service
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice One share-wei pays zero assets (`previewRedeem(1) == 0`). A thousand such
    ///         services add a thousand shares and nothing to the memory, and the reconstruction
    ///         adds them straight back, so the entitlement does not drift.
    function test_R60S1_probe09_dustServiceDoesNotDriftTheEntitlement() public {
        _counterCase();
        assertEq(pool.previewRedeem(1), 0, "fixture: one share-wei pays something");
        uint256 attackerShares = pool.balanceOf(attacker);
        vm.prank(attacker);
        pool.requestWithdrawal(attackerShares, attacker);
        uint256 before = _serviceable(attacker);

        vm.startPrank(attacker);
        for (uint256 i = 0; i < 1_000; i++) {
            pool.serviceWithdrawalRequest(attacker, 1, 0);
        }
        vm.stopPrank();
        (uint256 dS, uint256 dA) = _draw(attacker);
        uint256 afterDust = _serviceable(attacker);
        console2.log("MEASURED memory shares / assets after dust  ", dS);
        console2.log("MEASURED memory assets after dust           ", dA);
        console2.log("MEASURED entitlement before / after         ", before);
        console2.log("MEASURED entitlement after                  ", afterDust);
        assertEq(dS, 1_000, "the memory did not count the dust shares");
        assertEq(dA, 0, "dust service paid assets");
        assertApproxEqAbs(afterDust, before, 1, "dust service drifted the entitlement");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. The operator path and the slot pin
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice An operator services; the memory lands under the CONTROLLER and nothing under the
    ///         operator. This also pins slot 32: the figure written through the door is read
    ///         back through `vm.load` at the slot `_draw` computes.
    function test_R60S1_probe10_theMemoryIsKeyedToTheControllerAndSlot32IsPinned() public {
        _counterCase();
        vm.startPrank(attacker);
        pool.requestWithdrawal(pool.balanceOf(attacker), attacker);
        pool.setRequestOperator(operator, true);
        vm.stopPrank();

        uint256 serviceable = pool.maxRequestRedeem(attacker);
        vm.prank(operator);
        uint256 paid = pool.serviceWithdrawalRequest(attacker, serviceable, 0);

        (uint256 cS, uint256 cA) = _draw(attacker);
        (uint256 oS, uint256 oA) = _draw(operator);
        assertEq(cS, serviceable, "the controller's memory did not record the operator's service");
        assertEq(cA, paid, "the controller's memory did not record the cash");
        assertEq(oS + oA, 0, "the operator acquired a memory");
        assertEq(pool.maxRequestRedeem(attacker), 0, "the operator's service left a second slice");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. The "rises on repay" cash can be lent away before it is serviced
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After the draw a repayment lifts the drawn controller's entitlement. The manager
    ///         may then lend `available()` and the lift is gone before anybody services it. The
    ///         entitlement is live in both directions: that is the design the memory keeps.
    function test_R60S1_probe11_theRepayLiftCanBeLentAwayBeforeService() public {
        // Three lenders so that not every share is queued: with the whole supply in requests
        // the reserve is the whole cash and `available()` is zero after the repayment.
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _deposit(bystander, 5_000e6);
        _lend(20_000e6);
        uint256 blockerShares = pool.balanceOf(blocker);
        vm.prank(blocker);
        pool.requestWithdrawal(blockerShares, blocker);
        _drawOnce(attacker);
        uint256 spent = _serviceable(attacker);

        _repay(20_000e6);
        uint256 lifted = _serviceable(attacker);
        uint256 lendable = pool.available();
        assertGt(lendable, 0, "fixture: nothing lendable after the repayment");
        _lend(lendable);
        uint256 afterLend = _serviceable(attacker);

        console2.log("MEASURED after the draw: attacker           ", spent);
        console2.log("MEASURED after repaying 20,000: attacker    ", lifted);
        console2.log("MEASURED available() then lent              ", lendable);
        console2.log("MEASURED after the lend: attacker           ", afterLend);
        console2.log("MEASURED the lift lent away                 ", lifted - afterLend);
        assertEq(spent, 0, "the one permitted draw left a slice");
        assertGt(lifted, 0, "the repayment did not lift the entitlement");
        assertLt(afterLend, lifted, "the lend did not take the lift back");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. An impairment mid-loop, then its release
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A mark between two service calls lowers the exit price, not the cash. The
    ///         reconstruction is cash-denominated, so the second call reads the same zero it
    ///         would have without the mark, and the release changes nothing on the request door.
    function test_R60S1_probe12_anImpairmentMidLoopThenItsRelease() public {
        _counterCase();
        uint256 drawn = _drawOnce(attacker);

        vm.prank(manager);
        pool.impair(borrower, 5_000e6);
        uint256 marked = _serviceable(attacker);
        uint256 blockerMarked = _serviceable(blocker);
        vm.prank(manager);
        pool.releaseImpairment(borrower);
        uint256 released = _serviceable(attacker);

        console2.log("MEASURED one permitted draw                 ", drawn);
        console2.log("MEASURED attacker under the mark            ", marked);
        console2.log("MEASURED blocker under the mark             ", blockerMarked);
        console2.log("MEASURED attacker after the release         ", released);
        assertEq(marked, 0, "the mark reopened the drawn controller's slice");
        assertEq(released, 0, "the release reopened the drawn controller's slice");
    }
}
