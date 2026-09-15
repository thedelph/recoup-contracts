// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Session 42, S1: the cash floor a queued lender is owed (33audits H-03, issue #47).
/// @notice `LenderPool` quotes every withdrawal request a cash floor when it is filed
///         (`_freshFloor`: the executable cash not reserved for the requests already live, pro
///         rata over the shares not yet queued), holds the sum of the live floors
///         (`_floorTotal`, slot 33) in the reserve against `lend` and the synchronous doors, and
///         pays each request `max(floor, live slice)` capped at the cash the OTHER requests are
///         not owed. This file is the floor's own suite: the probes the design record
///         (the session-42 floor-versus-fraction record, sections 3, 4 and 8)
///         measured on a scratch copy, re-measured on the tree, plus the record's NOT-EXECUTED
///         list: the loss lock against the two repair doors, a mark and a yield release with two
///         floors, and a fuzz over the sum of every door's quote.
///
/// @dev The floor is read at slot 33 and a request's floor at the fourth word of its
///      `WithdrawalRequest` (mapping at slot 25) by `vm.load`; `LenderPoolFormulaPins` pins both.
///      Base fixture (`_counterCase`): blocker 10,000, attacker 10,000, 15,000 lent, blocker
///      queued. E = 5,000, S = 20,000, q = 10,000, price 1, the blocker's floor 2,500.000000.
///      The three-lender fixture (`_threeLenders`): blocker 10,000, attacker 10,000, bystander
///      5,000, 20,000 lent, blocker queued. E = 5,000, S = 25,000, the blocker's floor
///      2,000.000000. Figures are six-decimal USDC; every one logged as MEASURED was read from
///      the run that pins it, on this tree with forge 1.8.1.
contract R42S1_H03Floor is Test {
    uint256 internal constant FLOOR_TOTAL_SLOT = 33;
    uint256 internal constant WITHDRAWAL_REQUESTS_SLOT = 25;
    uint256 internal constant REQUEST_FLOOR_WORD = 3;

    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal borrower = makeAddr("borrower");
    address internal sink = makeAddr("cash-sink");
    address internal repairer = makeAddr("repairer");

    address internal attacker = makeAddr("attacker");
    address internal blocker = makeAddr("blocker");
    address internal bystander = makeAddr("bystander");
    address internal fresh = makeAddr("fresh");

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
        vm.prank(repairer);
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

    function _requestAll(address who) internal {
        uint256 shares = pool.balanceOf(who);
        vm.prank(who);
        pool.requestWithdrawal(shares, who);
    }

    function _counterCase() internal {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(15_000e6);
        _requestAll(blocker);
        assertEq(pool.queueCashReserve(), 2_500e6, "fixture: the blocker's reserve is not 2,500");
    }

    function _threeLenders() internal {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _deposit(bystander, 5_000e6);
        _lend(20_000e6);
        _requestAll(blocker);
        assertEq(_floorOf(blocker), 2_000e6, "fixture: the blocker's floor is not 2,000");
    }

    function _serviceable(address who) internal view returns (uint256) {
        return pool.previewRedeem(pool.maxRequestRedeem(who));
    }

    function _syncable(address who) internal view returns (uint256) {
        return pool.previewRedeem(pool.maxRedeem(who));
    }

    function _executable() internal view returns (uint256) {
        return pool.unreservedIdle() + pool.queueCashReserve();
    }

    function _floorTotal() internal view returns (uint256) {
        return uint256(vm.load(address(pool), bytes32(FLOOR_TOTAL_SLOT)));
    }

    function _floorOf(address who) internal view returns (uint256) {
        bytes32 base = keccak256(abi.encode(who, WITHDRAWAL_REQUESTS_SLOT));
        return uint256(vm.load(address(pool), bytes32(uint256(base) + REQUEST_FLOOR_WORD)));
    }

    /// @dev Request every share and service the maximum once. Returns what it paid.
    function _drawOnce(address who) internal returns (uint256 paid) {
        _requestAll(who);
        uint256 serviceable = pool.maxRequestRedeem(who);
        if (serviceable != 0) {
            vm.prank(who);
            paid = pool.serviceWithdrawalRequest(who, serviceable, 0);
        }
    }

    /// @dev Service the maximum until the door reads zero, at most 128 calls.
    function _serviceLoop(address who) internal returns (uint256 total, uint256 calls) {
        for (uint256 i = 0; i < 128; i++) {
            uint256 shares = pool.maxRequestRedeem(who);
            if (shares == 0) break;
            vm.prank(who);
            total += pool.serviceWithdrawalRequest(who, shares, 0);
            ++calls;
        }
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

    /// @dev Request all, service the maximum, cancel, request the remainder again, until the door
    ///      reads zero. Returns what it paid and the rounds it took.
    function _cancelAndRequestLoop(address who) internal returns (uint256 total, uint256 rounds) {
        _requestAll(who);
        for (uint256 i = 0; i < 64; i++) {
            uint256 shares = pool.maxRequestRedeem(who);
            if (shares == 0) break;
            vm.prank(who);
            total += pool.serviceWithdrawalRequest(who, shares, 0);
            ++rounds;
            (,, uint256 remaining,,) = pool.withdrawalRequest(who);
            if (remaining == 0) break;
            vm.startPrank(who);
            pool.cancelWithdrawalRequest();
            pool.requestWithdrawal(remaining, who);
            vm.stopPrank();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A. The counter-case: a floor is quoted, held, and the sync door closes in one call
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The blocker is quoted `E * q / S` = 2,500.000000 when she queues, the reserve is
    ///         her floor, one sync `redeem` pays the other 2,500.000000 and then the sync door
    ///         reads ZERO while she still reads her floor. Servicing her request spends the floor
    ///         to nothing and `_floorTotal` with it.
    function test_R42S1_floorA_theCounterCaseQuotesAFloorTheSyncDoorCannotReach() public {
        _counterCase();
        assertEq(_floorOf(blocker), 2_500e6, "the blocker's floor is not 2,500");
        assertEq(_floorTotal(), 2_500e6, "_floorTotal is not the blocker's floor");
        assertEq(pool.unreservedIdle(), 2_500e6, "the sync door does not read the other 2,500");

        uint256 paid = redeem(pool.maxRedeem(attacker), attacker, attacker);
        console2.log("MEASURED one sync redeem paid                 ", paid);
        console2.log("MEASURED unreservedIdle after                 ", pool.unreservedIdle());
        console2.log("MEASURED queueCashReserve after               ", pool.queueCashReserve());
        console2.log("MEASURED blocker serviceable after            ", _serviceable(blocker));
        assertEq(paid, 2_500e6, "one sync redeem paid other than 2,500");
        assertEq(pool.unreservedIdle(), 0, "the sync door stayed open on the blocker's floor");
        assertEq(pool.maxRedeem(attacker), 0, "the attacker can still redeem");
        assertEq(pool.queueCashReserve(), 2_500e6, "the reserve is not the floor");
        assertEq(_serviceable(blocker), 2_500e6, "the blocker's figure moved");

        (uint256 serviced, uint256 calls) = _serviceLoop(blocker);
        console2.log("MEASURED blocker serviced / calls             ", serviced);
        console2.log("MEASURED blocker service calls                ", calls);
        console2.log("MEASURED blocker's shares still queued        ", pool.queuedShares());
        // Her cash is 2,500 of a 10,000-share request (15,000 is lent), so the request stays live
        // with 7,500 shares and a floor spent to nothing; `_floorTotal` goes with it.
        assertEq(serviced, 2_500e6, "the blocker was paid other than her floor");
        assertEq(calls, 1, "the blocker's floor took more than one call");
        assertEq(pool.queuedShares(), 7_500e9, "the unfunded shares did not stay queued");
        assertEq(_floorOf(blocker), 0, "the service did not spend the floor");
        assertEq(_floorTotal(), 0, "_floorTotal survived the spent floor");
        assertEq(pool.queueCashReserve(), 0, "a reserve survives with no cash and no floor");
    }

    /// @notice The attacker redeems with `vm.prank` inside `redeem`'s own frame: the helper above
    ///         reads `maxRedeem` first so the prank is not spent on the view.
    function redeem(uint256 shares, address receiver, address owner) internal returns (uint256) {
        vm.prank(owner);
        return pool.redeem(shares, receiver, owner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // B. The mixed route: one draw, cancel, the sync door reads zero
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice One permitted draw of 2,500.000000, cancel, then the sync door: ZERO calls. The
    ///         attacker's own floor was spent by his draw, so his cancel releases nothing, and
    ///         `_floorTotal` is the blocker's 2,500.000000 throughout.
    function test_R42S1_floorB_theMixedRouteReadsZeroAtTheSyncDoor() public {
        _counterCase();
        uint256 drawn = _drawOnce(attacker);
        uint256 attackerFloorAfterDraw = _floorOf(attacker);
        vm.prank(attacker);
        pool.cancelWithdrawalRequest();
        (uint256 syncTotal, uint256 syncCalls) = _syncLoop(attacker);

        console2.log("MEASURED one permitted draw                   ", drawn);
        console2.log("MEASURED attacker's floor after the draw      ", attackerFloorAfterDraw);
        console2.log("MEASURED sync door after cancel, total        ", syncTotal);
        console2.log("MEASURED sync door after cancel, calls        ", syncCalls);
        console2.log("MEASURED _floorTotal                          ", _floorTotal());
        assertEq(drawn, 2_500e6, "the one permitted draw paid other than 2,500");
        assertEq(attackerFloorAfterDraw, 0, "the draw did not spend the attacker's floor");
        assertEq(syncTotal + syncCalls, 0, "the sync door paid after the draw");
        assertEq(_floorTotal(), 2_500e6, "_floorTotal is not the blocker's floor alone");
        assertEq(_serviceable(blocker), 2_500e6, "the blocker's figure moved");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C. A later request is priced out of the cash nobody is owed
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After the draw, a fresh address holding the attacker's 7,500 shares requests them
    ///         and is quoted a floor of 0: the cash not owed to the blocker is `E - 2,500 = 0`.
    ///         A plain `E * shares / S` would have quoted 1,071.428571 and pushed `_floorTotal`
    ///         above `E`. The attacker's own request, filed BEFORE his draw, was quoted the other
    ///         2,500.000000, so `_floorTotal` read exactly `E` with both live.
    function test_R42S1_floorC_aLaterRequestIsPricedOutOfTheCashNotOwed() public {
        _counterCase();
        _requestAll(attacker);
        uint256 attackerFloor = _floorOf(attacker);
        uint256 bothLive = _floorTotal();
        vm.startPrank(attacker);
        pool.serviceWithdrawalRequest(attacker, pool.maxRequestRedeem(attacker), 0);
        pool.cancelWithdrawalRequest();
        pool.transfer(fresh, pool.balanceOf(attacker));
        vm.stopPrank();

        uint256 executable = _executable();
        uint256 plainSlice = (executable * pool.balanceOf(fresh)) / pool.totalSupply();
        _requestAll(fresh);

        console2.log("MEASURED attacker's floor, filed first        ", attackerFloor);
        console2.log("MEASURED _floorTotal with both live           ", bothLive);
        console2.log("MEASURED E after the draw                     ", executable);
        console2.log("MEASURED a plain E * shares / S would quote   ", plainSlice);
        console2.log("MEASURED the fresh address's floor            ", _floorOf(fresh));
        console2.log("MEASURED the fresh address's serviceable      ", _serviceable(fresh));
        assertEq(attackerFloor, 2_500e6, "the attacker's floor is not the other 2,500");
        assertEq(bothLive, 5_000e6, "_floorTotal with both requests live is not E");
        assertEq(executable, 2_500e6, "E after the draw is not 2,500");
        assertEq(plainSlice, 1_071_428_571, "the plain slice is not 1,071.428571");
        assertEq(_floorOf(fresh), 0, "the fresh address was quoted a floor out of the blocker's cash");
        assertEq(_serviceable(fresh), 0, "the fresh address can draw the blocker's cash");
        assertEq(_floorTotal(), 2_500e6, "_floorTotal moved on a zero-floor request");
        assertLe(_floorTotal(), executable, "_floorTotal exceeds E at request time");
    }

    /// @notice Three lenders of any size, any principal out, and requests filed in any order:
    ///         `_floorTotal` never exceeds the executable cash at request time, every floor is
    ///         at most the cash not already owed, and every request's serviceable cash is at most
    ///         `E` less the other floors.
    function testFuzz_R42S1_floorC_theFloorTotalNeverExceedsTheCashAtRequestTime(
        uint96 a,
        uint96 b,
        uint96 c,
        uint16 lentBps,
        uint8 order
    ) public {
        uint256 da = bound(uint256(a), 1e6, 80_000e6);
        uint256 db = bound(uint256(b), 1e6, 80_000e6);
        uint256 dc = bound(uint256(c), 1e6, 80_000e6);
        _deposit(blocker, da);
        _deposit(attacker, db);
        _deposit(bystander, dc);
        uint256 want = ((da + db + dc) * bound(uint256(lentBps), 0, Config.BPS)) / Config.BPS;
        uint256 lendable = pool.available();
        if (want > lendable) want = lendable;
        if (want != 0) _lend(want);

        address[3] memory who = [blocker, attacker, bystander];
        uint256 first = order % 3;
        for (uint256 k = 0; k < 3; k++) {
            address lender = who[(first + k) % 3];
            uint256 executable = _executable();
            uint256 owedBefore = _floorTotal();
            _requestAll(lender);
            uint256 floor = _floorOf(lender);
            assertLe(
                floor,
                executable - (owedBefore > executable ? executable : owedBefore),
                "a floor exceeded the cash not owed"
            );
            assertLe(_floorTotal(), executable, "_floorTotal exceeded E at request time");
            assertEq(_floorTotal(), owedBefore + floor, "_floorTotal did not rise by the floor");
        }
        uint256 executableNow = _executable();
        for (uint256 k = 0; k < 3; k++) {
            uint256 othersOwed = _floorTotal() - _floorOf(who[k]);
            uint256 reachable = executableNow > othersOwed ? executableNow - othersOwed : 0;
            assertLe(_serviceable(who[k]), reachable, "a request can reach cash owed to another");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // D. An unqueued bystander's share is what the attacker reaches, through either door
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three lenders, the blocker queued at a floor of 2,000.000000. One sync redeem pays
    ///         3,000.000000 (E less the floor), further stepped redeems pay 0, and the blocker
    ///         keeps 2,000. From the same state the cancel-and-re-request loop reaches
    ///         2,999.999999 over 27 rounds, the blocker still keeps 2,000, and what the bystander's
    ///         sync door reads after is 0.000001: the UNQUEUED holder's share is what the attacker
    ///         took, through the request door slowly or the sync door at once. That is the
    ///         known-risks item on the non-requester's exposure, unchanged by the floor. The
    ///         fraction's figures: 1,999.999999 more over 31 sync steps, the blocker left 0.
    function test_R42S1_floorD_theUnqueuedBystanderIsWhatTheAttackerReaches() public {
        _threeLenders();
        uint256 clean = vm.snapshotState();

        uint256 firstSync = redeem(pool.maxRedeem(attacker), attacker, attacker);
        (uint256 moreSync, uint256 moreCalls) = _syncLoop(attacker);
        uint256 blockerAfterSync = _serviceable(blocker);

        vm.revertToState(clean);
        (uint256 loopTotal, uint256 rounds) = _cancelAndRequestLoop(attacker);
        uint256 blockerAfterLoop = _serviceable(blocker);
        uint256 bystanderAfterLoop = _syncable(bystander);

        console2.log("MEASURED one sync redeem by the attacker      ", firstSync);
        console2.log("MEASURED further stepped sync redeems         ", moreSync);
        console2.log("MEASURED further stepped sync calls           ", moreCalls);
        console2.log("MEASURED blocker after the sync walk          ", blockerAfterSync);
        console2.log("MEASURED cancel-and-re-request loop, total    ", loopTotal);
        console2.log("MEASURED cancel-and-re-request loop, rounds   ", rounds);
        console2.log("MEASURED blocker after that loop              ", blockerAfterLoop);
        console2.log("MEASURED bystander's sync door after that loop", bystanderAfterLoop);
        assertEq(firstSync, 3_000e6, "one sync redeem paid other than 3,000");
        assertEq(moreSync + moreCalls, 0, "the stepped sync door paid past the floor");
        assertEq(blockerAfterSync, 2_000e6, "the sync walk moved the blocker's floor");
        // 26 paying services; the record's harness counted 27 rounds because it counted the
        // cancel-and-re-request that preceded the service reading zero.
        assertEq(loopTotal, 2_999_999_999, "the loop reached other than 2,999.999999");
        assertEq(rounds, 26, "the loop paid on other than 26 services");
        assertEq(blockerAfterLoop, 2_000e6, "the loop moved the blocker's floor");
        assertEq(bystanderAfterLoop, 1, "the bystander's sync door reads other than one wei");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // E. Cancel releases the floor and reopens the doors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice With both lenders queued `_floorTotal` is `E` and both the sync door and `lend`
    ///         read zero. Each cancel releases exactly that request's floor.
    function test_R42S1_floorE_cancelReleasesTheFloorAndReopensTheDoors() public {
        _counterCase();
        _requestAll(attacker);
        assertEq(_floorTotal(), 5_000e6, "both floors are not E");
        assertEq(pool.unreservedIdle(), 0, "the sync door is open with every share queued");
        assertEq(pool.available(), 0, "lend is open with every share queued");

        vm.prank(attacker);
        pool.cancelWithdrawalRequest();
        console2.log("MEASURED after the attacker cancels: floors   ", _floorTotal());
        console2.log("MEASURED after the attacker cancels: idle     ", pool.unreservedIdle());
        assertEq(_floorTotal(), 2_500e6, "the attacker's cancel released other than his floor");
        assertEq(pool.unreservedIdle(), 2_500e6, "the sync door did not reopen by the released floor");

        vm.prank(blocker);
        pool.cancelWithdrawalRequest();
        console2.log("MEASURED after the blocker cancels: floors    ", _floorTotal());
        console2.log("MEASURED after the blocker cancels: idle      ", pool.unreservedIdle());
        console2.log("MEASURED after the blocker cancels: available ", pool.available());
        assertEq(_floorTotal(), 0, "the blocker's cancel left a floor");
        assertEq(pool.queueCashReserve(), 0, "a reserve survives with nothing queued");
        assertEq(pool.unreservedIdle(), 5_000e6, "the sync door does not read the whole E");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F. A loss with two floors: the over-promise is LOCKED, and the repair doors do not free it
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Two floors of 3,000.000000 against 2,500.000000 of cash after a raw loss of 2,500:
    ///         each request is capped at `E` minus the other's floor (1,499.999999 and
    ///         499.999999), both are paid that, and the 500.000002 the floors over-promise is
    ///         cash no door reaches: not the sync door, not `lend`, not either request. Then the
    ///         record's NOT-EXECUTED question: the two repair doors, `coverClaimDeficit` and
    ///         `coverEntryPriceDeficit`, are offered whatever deficit they report, and whether
    ///         they release the lock is measured. A full repayment does.
    function test_R42S1_floorF_aLossWithTwoFloorsLocksTheOverPromise() public {
        _threeLenders();
        _requestAll(bystander);
        assertEq(_floorOf(bystander), 1_000e6, "the bystander's floor is not (5,000 - 2,000) * 5,000 / 15,000");
        assertEq(_floorTotal(), 3_000e6, "the two floors are not 3,000");

        vm.prank(address(pool));
        usdc.transfer(sink, 2_500e6);
        // The views reconcile lazily; a service reconciles on the way in. Read the state after
        // the first door has, so every figure below is post-reconciliation.
        (uint256 blockerPaid, uint256 blockerCalls) = _serviceLoop(blocker);
        uint256 executableAfterLoss = blockerPaid + _executable();
        (uint256 bystanderPaid, uint256 bystanderCalls) = _serviceLoop(bystander);

        console2.log("MEASURED E after the loss                     ", executableAfterLoss);
        console2.log("MEASURED floors outstanding before service    ", uint256(3_000e6));
        console2.log("MEASURED blocker serviced to zero             ", blockerPaid);
        console2.log("MEASURED blocker service calls                ", blockerCalls);
        console2.log("MEASURED then the bystander                   ", bystanderPaid);
        console2.log("MEASURED bystander service calls              ", bystanderCalls);
        console2.log("MEASURED both request doors after: blocker    ", _serviceable(blocker));
        console2.log("MEASURED both request doors after: bystander  ", _serviceable(bystander));
        console2.log("MEASURED executable cash left                 ", _executable());
        console2.log("MEASURED floors left                          ", _floorTotal());
        console2.log("MEASURED unreservedIdle                       ", pool.unreservedIdle());
        console2.log("MEASURED attacker's maxRedeem, in USDC        ", _syncable(attacker));
        console2.log("MEASURED available()                          ", pool.available());
        assertEq(executableAfterLoss, 2_500e6, "E after the loss is not 2,500");
        assertEq(blockerPaid, 1_499_999_999, "the blocker was paid other than E less the bystander's floor");
        assertEq(bystanderPaid, 499_999_999, "the bystander was paid other than E less the blocker's floor");
        assertEq(_serviceable(blocker) + _serviceable(bystander), 0, "a request door is still open");
        assertEq(_executable(), 500_000_002, "the executable cash left is not the over-promise");
        assertEq(pool.unreservedIdle(), 0, "the locked cash reached the sync door");
        assertEq(pool.maxRedeem(attacker), 0, "the locked cash reached the attacker");
        assertEq(pool.available(), 0, "the locked cash reached lend");
        assertGt(_floorTotal(), _executable(), "the floors do not exceed the cash: no lock");

        // The repair doors. Whatever each reports as its deficit is paid in by a repairer, and
        // the lock is read again. The record left this unmeasured.
        uint256 claimDeficit = pool.claimSolvencyDeficit();
        uint256 priceDeficit = pool.entryPriceDeficit();
        console2.log("MEASURED claimSolvencyDeficit                 ", claimDeficit);
        console2.log("MEASURED entryPriceDeficit                    ", priceDeficit);
        usdc.mint(repairer, 2e6);
        if (claimDeficit != 0) {
            usdc.mint(repairer, claimDeficit);
            vm.prank(repairer);
            pool.coverClaimDeficit(claimDeficit);
        } else {
            // Neither claims nor the entry price are in deficit: the locked cash is recognised
            // shareholder cash that the floors have promised twice, not a shortfall either
            // repair door is built for, so both refuse a single wei.
            vm.prank(repairer);
            vm.expectRevert(abi.encodeWithSelector(LenderPool.ClaimDeficitExceeded.selector, 1, 0));
            pool.coverClaimDeficit(1);
        }
        if (priceDeficit != 0) {
            usdc.mint(repairer, priceDeficit);
            vm.prank(repairer);
            pool.coverEntryPriceDeficit(priceDeficit);
        } else {
            vm.prank(repairer);
            vm.expectRevert(abi.encodeWithSelector(LenderPool.EntryPriceDeficitExceeded.selector, 1, 0));
            pool.coverEntryPriceDeficit(1);
        }
        console2.log("MEASURED after the repair doors: executable   ", _executable());
        console2.log("MEASURED after the repair doors: idle         ", pool.unreservedIdle());
        console2.log("MEASURED after the repair doors: blocker      ", _serviceable(blocker));
        console2.log("MEASURED after the repair doors: bystander    ", _serviceable(bystander));
        console2.log("MEASURED after the repair doors: available    ", pool.available());
        uint256 releasedByRepairs =
            pool.unreservedIdle() + _serviceable(blocker) + _serviceable(bystander) + pool.available();
        console2.log("MEASURED released by the repair doors         ", releasedByRepairs);
        assertEq(releasedByRepairs, 0, "a repair door released the locked cash");
        assertEq(_executable(), 500_000_002, "the repair doors moved the locked cash");

        // A repayment lifts E above the floors and every door reopens.
        _repay(20_000e6);
        console2.log("MEASURED after repaying 20,000: blocker       ", _serviceable(blocker));
        console2.log("MEASURED after repaying 20,000: bystander     ", _serviceable(bystander));
        console2.log("MEASURED after repaying 20,000: available     ", pool.available());
        assertEq(_serviceable(blocker), 7_499_999_965, "the blocker after the repayment is not 7,499.999965");
        assertEq(_serviceable(bystander), 3_999_999_925, "the bystander after the repayment is not 3,999.999925");
        assertEq(pool.available(), 7_650_000_095, "available() after the repayment is not 7,650.000095");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // G. The floor against lending, and the parked request
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice In the counter-case `available()` is 0 with the blocker queued; after a full
    ///         repayment it is 8,500.000000 (the fraction exceeds the floor, which does not bind),
    ///         and after re-lending it the blocker's live slice is 5,750.000000 above her floor.
    ///         Where the floor BINDS it binds `lend` too: after the attacker's one sync redeem
    ///         the reserve is her floor, 2,500 against a fraction of 2,000, and a partial
    ///         repayment of 1,000 still lends nothing until she cancels.
    function test_R42S1_floorG_theFloorHoldsAgainstLendingUntilRepaidOrCancelled() public {
        _counterCase();
        assertEq(pool.available(), 0, "lend is open with the blocker queued");
        uint256 clean = vm.snapshotState();

        _repay(15_000e6);
        uint256 afterRepay = pool.available();
        uint256 blockerLifted = _serviceable(blocker);
        _lend(afterRepay);
        uint256 blockerAfterLend = _serviceable(blocker);
        console2.log("MEASURED available() after a full repayment   ", afterRepay);
        console2.log("MEASURED blocker after the repayment          ", blockerLifted);
        console2.log("MEASURED blocker after re-lending             ", blockerAfterLend);
        assertEq(afterRepay, 8_500e6, "available() after the repayment is not 8,500");
        assertEq(blockerLifted, 10_000e6, "the blocker's live slice after the repayment is not 10,000");
        assertEq(blockerAfterLend, 5_750e6, "the blocker's live slice after re-lending is not 5,750");
        assertEq(_floorOf(blocker), 2_500e6, "the floor moved with the repayment");

        vm.revertToState(clean);
        redeem(pool.maxRedeem(attacker), attacker, attacker);
        _repay(1_000e6);
        uint256 fraction = (_executable() * pool.queuedShares() + pool.totalSupply() - 1) / pool.totalSupply();
        console2.log("MEASURED after the sync redeem and 1,000 repaid: E", _executable());
        console2.log("MEASURED fraction arm of the reserve          ", fraction);
        console2.log("MEASURED queueCashReserve                     ", pool.queueCashReserve());
        console2.log("MEASURED available() with the floor binding   ", pool.available());
        assertEq(_executable(), 3_500e6, "E is not 3,500");
        assertEq(fraction, 2_000e6, "the fraction arm is not 2,000");
        assertEq(pool.queueCashReserve(), 2_500e6, "the reserve is not the floor");
        assertEq(pool.available(), 0, "lend reached the blocker's floor");

        vm.prank(blocker);
        pool.cancelWithdrawalRequest();
        console2.log("MEASURED available() after her cancel         ", pool.available());
        assertGt(pool.available(), 0, "her cancel did not reopen lend");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H. The upward re-derivation is a fraction
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After a repayment of 5,000 the blocker's live slice is 5,000.000000 above her
    ///         floor of 2,500. The attacker's sync door re-slices that lift: one redeem pays
    ///         5,000.000000, the stepped door 7,500.000000 over 4 calls, and the blocker is left
    ///         at her floor, 2,500.000000. The fraction's figures: 9,922.480600 over 128 calls,
    ///         the blocker left 76.923096.
    function test_R42S1_floorH_theUpwardRederivationIsAFractionTheSyncDoorReslices() public {
        _counterCase();
        _repay(5_000e6);
        uint256 lifted = _serviceable(blocker);
        uint256 first = redeem(pool.maxRedeem(attacker), attacker, attacker);
        (uint256 more, uint256 calls) = _syncLoop(attacker);

        console2.log("MEASURED blocker after repaying 5,000         ", lifted);
        console2.log("MEASURED attacker's one sync redeem           ", first);
        console2.log("MEASURED stepped sync door, total             ", first + more);
        console2.log("MEASURED stepped sync door, calls             ", 1 + calls);
        console2.log("MEASURED blocker after the stepped door       ", _serviceable(blocker));
        assertEq(lifted, 5_000e6, "the blocker's live slice after the repayment is not 5,000");
        assertEq(first, 5_000e6, "one sync redeem paid other than 5,000");
        assertEq(first + more, 7_500e6, "the stepped sync door reached other than 7,500");
        assertEq(1 + calls, 4, "the stepped sync door took other than 4 calls");
        assertEq(_serviceable(blocker), 2_500e6, "the blocker was left other than her floor");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I. A drought floor does not ratchet up
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice 17,000 of 20,000 lent, the attacker queues: floor 1,500.000000, serviceable
    ///         1,500.000000. A repayment of 9,000 lifts the live slice to 6,000.000000 while the
    ///         floor stays 1,500; the manager lends `available()` again and the slice is
    ///         4,050.000000. The floor is what she was quoted and the lift is a fraction.
    function test_R42S1_floorI_aDroughtFloorDoesNotRatchetUp() public {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(17_000e6);
        _requestAll(attacker);
        uint256 droughtFloor = _floorOf(attacker);
        uint256 droughtSlice = _serviceable(attacker);
        _repay(9_000e6);
        uint256 lifted = _serviceable(attacker);
        uint256 floorAfterRepay = _floorOf(attacker);
        _lend(pool.available());
        uint256 afterLend = _serviceable(attacker);

        console2.log("MEASURED drought floor / serviceable          ", droughtFloor);
        console2.log("MEASURED drought serviceable                  ", droughtSlice);
        console2.log("MEASURED after repaying 9,000                 ", lifted);
        console2.log("MEASURED floor after the repayment            ", floorAfterRepay);
        console2.log("MEASURED after lending available() again      ", afterLend);
        assertEq(droughtFloor, 1_500e6, "the drought floor is not 1,500");
        assertEq(droughtSlice, 1_500e6, "the drought slice is not 1,500");
        assertEq(lifted, 6_000e6, "the lift is not 6,000");
        assertEq(floorAfterRepay, 1_500e6, "the floor ratcheted up");
        assertEq(afterLend, 4_050e6, "the slice after re-lending is not 4,050");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // J. A mark and a yield release with two floors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Two floors live (2,000 and 1,000). A mark of 5,000 lowers the exit price and not
    ///         the cash: both floors are unchanged, each request reads its floor at the marked
    ///         price, and the sum of both request doors and the sync door stays inside E. The
    ///         release restores the price. Then a yield of 1,000 released: E rises, the floors
    ///         are unchanged, both live slices rise above the floors' share of the old cash, and
    ///         the sum stays inside E.
    function test_R42S1_floorJ_aMarkAndAYieldReleaseWithTwoFloors() public {
        _threeLenders();
        _requestAll(bystander);
        uint256 floorsBefore = _floorTotal();

        vm.prank(manager);
        pool.impair(borrower, 5_000e6);
        uint256 blockerMarked = _serviceable(blocker);
        uint256 bystanderMarked = _serviceable(bystander);
        uint256 attackerMarked = _syncable(attacker);
        uint256 executableMarked = _executable();
        console2.log("MEASURED under the mark: E                    ", executableMarked);
        console2.log("MEASURED under the mark: blocker              ", blockerMarked);
        console2.log("MEASURED under the mark: bystander            ", bystanderMarked);
        console2.log("MEASURED under the mark: attacker's sync door ", attackerMarked);
        console2.log("MEASURED under the mark: floors               ", _floorTotal());
        assertEq(_floorTotal(), floorsBefore, "the mark moved the floors");
        assertLt(blockerMarked, 2_000e6, "the mark did not lower the blocker's figure through the price");
        assertLe(
            blockerMarked + bystanderMarked + attackerMarked,
            executableMarked + 2,
            "the doors over-promise under the mark"
        );

        vm.prank(manager);
        pool.releaseImpairment(borrower);
        assertEq(_serviceable(blocker), 2_000e6, "the release did not restore the blocker's floor");

        usdc.mint(harvester, 1_000e6);
        vm.prank(harvester);
        pool.distributeYield(1_000e6);
        skip(Config.MAX_YIELD_STREAM_DURATION + 1);
        uint256 executableAfterYield = _executable();
        uint256 blockerAfterYield = _serviceable(blocker);
        uint256 bystanderAfterYield = _serviceable(bystander);
        uint256 attackerAfterYield = _syncable(attacker);
        console2.log("MEASURED after the yield: E                   ", executableAfterYield);
        console2.log("MEASURED after the yield: blocker             ", blockerAfterYield);
        console2.log("MEASURED after the yield: bystander           ", bystanderAfterYield);
        console2.log("MEASURED after the yield: attacker's sync door", attackerAfterYield);
        console2.log("MEASURED after the yield: floors              ", _floorTotal());
        assertEq(_floorTotal(), floorsBefore, "the yield moved the floors");
        assertGe(blockerAfterYield, 2_000e6, "the blocker reads below her floor after the yield");
        assertLe(
            blockerAfterYield + bystanderAfterYield + attackerAfterYield,
            executableAfterYield + 2,
            "the doors over-promise after the yield"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K. The sum of every quote against the cash: what holds and what does not
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Three lenders, principal out, two or three requests filed, then a socialised loss
    ///         and a sync exit between them. Every request's quote is at most `E` less the other
    ///         floors, and what the doors PAY when walked to zero one after another never
    ///         exceeds the cash that existed when the walk began. The instantaneous sum of the
    ///         quotes plus the sync door is logged as MEASURED and reported, not asserted: a
    ///         floor-bound request reads its floor while a live-bound one reads its slice of the
    ///         same cash, and those two readings can overlap by the cash the sync door shows.
    function testFuzz_R42S1_floorK_whatTheDoorsPayNeverExceedsTheCash(
        uint96 a,
        uint96 b,
        uint96 c,
        uint16 lentBps,
        uint16 lossBps,
        uint8 order
    ) public {
        uint256 da = bound(uint256(a), 10e6, 80_000e6);
        uint256 db = bound(uint256(b), 10e6, 80_000e6);
        uint256 dc = bound(uint256(c), 10e6, 80_000e6);
        _deposit(blocker, da);
        _deposit(attacker, db);
        _deposit(bystander, dc);
        uint256 want = ((da + db + dc) * bound(uint256(lentBps), 1, Config.BPS)) / Config.BPS;
        uint256 lendable = pool.available();
        if (want > lendable) want = lendable;
        if (want != 0) _lend(want);

        address[3] memory who = [blocker, attacker, bystander];
        uint256 first = order % 3;
        _requestAll(who[first]);
        uint256 loss = (pool.outstandingPrincipal() * bound(uint256(lossBps), 0, Config.BPS / 2)) / Config.BPS;
        if (loss != 0) {
            vm.prank(manager);
            pool.socialiseLoss(loss);
        }
        _requestAll(who[(first + 1) % 3]);
        address unqueued = who[(first + 2) % 3];
        uint256 half = pool.maxRedeem(unqueued) / 2;
        if (half != 0) redeem(half, unqueued, unqueued);
        if (order % 2 == 0) _requestAll(unqueued);

        uint256 executable = _executable();
        uint256 quotes;
        for (uint256 k = 0; k < 3; k++) {
            uint256 othersOwed = _floorTotal() - _floorOf(who[k]);
            uint256 reachable = executable > othersOwed ? executable - othersOwed : 0;
            uint256 quote = _serviceable(who[k]);
            assertLe(quote, reachable, "a quote exceeds E less the other floors");
            quotes += quote;
        }
        uint256 syncQuote = order % 2 == 0 ? 0 : _syncable(unqueued);
        if (quotes + syncQuote > executable) {
            console2.log("MEASURED quotes plus the sync door exceed E by", quotes + syncQuote - executable);
        }

        uint256 paid;
        for (uint256 k = 0; k < 3; k++) {
            (uint256 got,) = _serviceLoop(who[(first + k) % 3]);
            paid += got;
        }
        if (order % 2 != 0) {
            (uint256 got,) = _syncLoop(unqueued);
            paid += got;
        }
        assertLe(paid, executable, "the doors paid more than the cash that existed");
    }
}
