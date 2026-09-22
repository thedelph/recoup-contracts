// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 63 seat A3: the stateful handler over a bare `LenderPool`'s doors.
/// @notice Four lenders, a stranger holding share dust, and this contract standing in as BOTH the
///         credit manager and the epoch harvester (the suite wires the pool to it), so every
///         pool-level flow a wired graph can produce is an action here: deposit, request, cancel,
///         service (whole, and all but one share-wei), sync redeem, claim, lend, repay (with a
///         surplus), an epoch, a socialised loss, a raw loss, time, and a stranger's dust.
/// @dev Rules this handler follows (the repository's invariant-handler conventions):
///      every external non-view function IS a fuzz action, so there is no setter and the wiring
///      arrives through the constructor; no action reverts (each outward call is pre-checked or
///      wrapped in `try`, a refusal is COUNTED); in-handler properties are recorded into ghosts
///      and asserted from the suite, each beside a coverage ghost.
contract R63A3_PoolDoorsHandler is Test {
    uint256 internal constant FLOOR_TOTAL_SLOT = 33;
    uint256 internal constant WITHDRAWAL_REQUESTS_SLOT = 25;
    uint256 internal constant REQUEST_DRAWS_SLOT = 32;
    uint256 internal constant LENDERS = 4;

    LenderPool public immutable pool;
    MockUSDC public immutable usdc;
    address public immutable sink;
    address public immutable stranger;
    address[LENDERS] public lenders;

    // ── coverage ghosts ──────────────────────────────────────────────────────
    uint256 public frames;
    uint256 public refusals;
    uint256 public depositsDone;
    uint256 public requestsDone;
    uint256 public cancelsDone;
    uint256 public servicesDone;
    uint256 public dustServicesDone;
    uint256 public completionsDone;
    uint256 public redeemsDone;
    uint256 public claimsDone;
    uint256 public lendsDone;
    uint256 public repaysDone;
    uint256 public surplusesDone;
    uint256 public epochsDone;
    uint256 public epochsMidStream;
    uint256 public socialisedDone;
    uint256 public socialisedWithQueue;
    uint256 public rawLossesDone;
    uint256 public timeAdvances;
    uint256 public dustsDone;
    uint256 public dustsOntoALiveRequest;
    uint256 public nonEpochWarmArrivals;

    // ── violation ghosts (asserted == 0 by the suite, beside the coverage above) ─────────────
    uint256 public dustMovedADoor;
    uint256 public nonEpochLoweredTheRate;
    uint256 public floorsOverEWithoutARawLoss;
    uint256 public aDoorPromisedMoreThanE;

    // ── census ghosts (reported, not asserted) ───────────────────────────────
    uint256 public framesWithQueue;
    uint256 public framesWithQueueStreamAndPrincipal;
    uint256 public floorsOverEFrames;
    uint256 public epochsThatLoweredTheRate;
    uint256 public nonEpochRateDipsInsideOneSecond;
    uint256 public memoryKeptByDust;
    uint256 public excessFloorFrames;
    uint256 public excessFloorFramesWithoutARawLoss;
    uint256 public keptFloorOnDustFrames;
    uint256 public keptFloorOnDustFramesWithoutARawLoss;
    uint256 public maxKeptFloorOnDust;
    uint256 public allDoorsShutWithCashFrames;
    uint256 public maxCashShutOut;

    constructor(LenderPool pool_, MockUSDC usdc_) {
        pool = pool_;
        usdc = usdc_;
        sink = makeAddr("r63a3-sink");
        stranger = makeAddr("r63a3-stranger");
        for (uint256 i; i < LENDERS; ++i) {
            lenders[i] = address(uint160(0xA3000 + i));
            vm.prank(lenders[i]);
            usdc_.approve(address(pool_), type(uint256).max);
        }
        vm.prank(stranger);
        usdc_.approve(address(pool_), type(uint256).max);
        usdc_.approve(address(pool_), type(uint256).max);
    }

    // ── reads ────────────────────────────────────────────────────────────────

    function executable() public view returns (uint256) {
        return pool.unreservedIdle() + pool.queueCashReserve();
    }

    function floorTotal() public view returns (uint256) {
        return uint256(vm.load(address(pool), bytes32(FLOOR_TOTAL_SLOT)));
    }

    function floorOf(address who) public view returns (uint256) {
        bytes32 base = keccak256(abi.encode(who, WITHDRAWAL_REQUESTS_SLOT));
        return uint256(vm.load(address(pool), bytes32(uint256(base) + 3)));
    }

    function requestSharesOf(address who) public view returns (uint256 shares) {
        (,, shares,,) = pool.withdrawalRequest(who);
    }

    function memorySharesOf(address who) public view returns (uint256) {
        return uint256(vm.load(address(pool), keccak256(abi.encode(who, REQUEST_DRAWS_SLOT))));
    }

    function _lender(uint256 seed) internal view returns (address) {
        return lenders[seed % LENDERS];
    }

    // ── actions ──────────────────────────────────────────────────────────────

    function deposit(uint256 seed, uint256 amount) external {
        address who = _lender(seed);
        amount = bound(amount, 1e6, 5_000e6);
        if (pool.cashDeficit() != 0 || pool.maxDeposit(who) < amount || pool.previewDeposit(amount) == 0) {
            ++refusals;
            return _observe();
        }
        usdc.mint(who, amount);
        vm.prank(who);
        pool.deposit(amount, who);
        ++depositsDone;
        _observe();
    }

    function request(uint256 seed, uint256 bps) external {
        address who = _lender(seed);
        uint256 balance = pool.balanceOf(who);
        bps = bound(bps, 1, 10_000);
        uint256 shares = bps > 9_000 ? balance : (balance * bps) / 10_000;
        if (shares == 0 || requestSharesOf(who) != 0) {
            ++refusals;
            return _observe();
        }
        vm.prank(who);
        pool.requestWithdrawal(shares, who);
        ++requestsDone;
        _observe();
    }

    function cancel(uint256 seed) external {
        address who = _lender(seed);
        if (requestSharesOf(who) == 0) {
            ++refusals;
            return _observe();
        }
        vm.prank(who);
        pool.cancelWithdrawalRequest();
        ++cancelsDone;
        _observe();
    }

    function serviceMax(uint256 seed) external {
        _serviceDoor(_lender(seed), 0);
    }

    /// @dev The dust action: everything the door offers less ONE share-wei.
    function serviceAllButOneShareWei(uint256 seed) external {
        _serviceDoor(_lender(seed), 1);
    }

    function _serviceDoor(address who, uint256 leave) internal {
        uint256 door = pool.maxRequestRedeem(who);
        if (door <= leave) {
            ++refusals;
            return _observe();
        }
        uint256 before = requestSharesOf(who);
        vm.prank(who);
        try pool.serviceWithdrawalRequest(who, door - leave, 0) {
            ++servicesDone;
            if (leave != 0) ++dustServicesDone;
            if (before == door - leave) {
                ++completionsDone;
                if (memorySharesOf(who) != 0) ++memoryKeptByDust;
            }
        } catch {
            ++refusals;
        }
        _observe();
    }

    function redeemMax(uint256 seed) external {
        address who = _lender(seed);
        uint256 shares = pool.maxRedeem(who);
        if (shares == 0) {
            ++refusals;
            return _observe();
        }
        vm.prank(who);
        try pool.redeem(shares, who, who) {
            ++redeemsDone;
        } catch {
            ++refusals;
        }
        _observe();
    }

    function claim(uint256 seed) external {
        address who = _lender(seed);
        if (pool.claimable(who) == 0 || pool.claimLiquidityDeficit() != 0 || pool.cashDeficit() != 0) {
            ++refusals;
            return _observe();
        }
        pool.claimFor(who);
        ++claimsDone;
        _observe();
    }

    function lend(uint256 bps) external {
        uint256 lendable = pool.cashDeficit() == 0 ? pool.available() : 0;
        uint256 amount = (lendable * bound(bps, 1, 10_000)) / 10_000;
        if (amount == 0) {
            ++refusals;
            return _observe();
        }
        try pool.lend(amount) {
            ++lendsDone;
        } catch {
            ++refusals;
        }
        _observe();
    }

    /// @dev A repayment of up to the whole loan; one call in eight carries a surplus of up to
    ///      100.000000 over it, which is the non-epoch stream leg.
    function repay(uint256 bps, uint256 surplusSeed) external {
        uint256 outstanding = pool.outstandingPrincipal();
        uint256 amount = (outstanding * bound(bps, 1, 10_000)) / 10_000;
        bool withSurplus = surplusSeed % 8 == 0;
        if (withSurplus) amount = outstanding + 1 + (surplusSeed % 100e6);
        if (amount == 0) {
            ++refusals;
            return _observe();
        }
        bool warm = withSurplus && pool.unreleasedYield() != 0 && pool.yieldRate() != 0
            && pool.yieldStreamEndsAt() > block.timestamp;
        uint256 rateBefore = pool.yieldRate();
        uint256 endBefore = pool.yieldStreamEndsAt();
        uint256 remainingBefore = endBefore > block.timestamp ? endBefore - block.timestamp : 0;
        usdc.mint(address(this), amount);
        try pool.repayPrincipal(amount) {
            ++repaysDone;
            if (withSurplus) ++surplusesDone;
            if (warm && pool.cashDeficit() == 0 && pool.yieldRate() != 0) {
                ++nonEpochWarmArrivals;
                // Rule 1b as the source states it is "a non-epoch arrival can never reduce the
                // release rate". The first unseeded run of this campaign refuted that TO THE
                // WEI: after a raw loss `_writeYieldState` CEILS the shortened window, rule 2
                // then keeps that ceiled second, and the re-rated pot divides over it. So the
                // violation here is a dip of more than one second of the running window, and
                // the sub-second dips are COUNTED beside it.
                uint256 rateAfter = pool.yieldRate();
                if (rateAfter < rateBefore) {
                    ++nonEpochRateDipsInsideOneSecond;
                    if (remainingBefore <= 1 || rateAfter * remainingBefore < rateBefore * (remainingBefore - 1)) {
                        ++nonEpochLoweredTheRate;
                        --nonEpochRateDipsInsideOneSecond;
                    }
                    if (pool.yieldStreamEndsAt() > endBefore && remainingBefore > 1) {
                        // A later end with a lower rate would be the grief rule 1b exists to stop.
                        ++nonEpochLoweredTheRate;
                    }
                }
            }
        } catch {
            ++refusals;
        }
        _observe();
    }

    function deliverEpoch(uint256 amount) external {
        amount = bound(amount, 250_000, 200e6);
        bool midStream = pool.unreleasedYield() != 0 && pool.yieldRate() != 0;
        uint256 rateBefore = pool.yieldRate();
        usdc.mint(address(this), amount);
        try pool.distributeYield(amount) {
            ++epochsDone;
            if (midStream) {
                ++epochsMidStream;
                if (pool.yieldRate() < rateBefore) ++epochsThatLoweredTheRate;
            }
        } catch {
            ++refusals;
        }
        _observe();
    }

    function socialise(uint256 bps) external {
        uint256 amount = (pool.outstandingPrincipal() * bound(bps, 1, 10_000)) / 10_000;
        if (amount == 0) {
            ++refusals;
            return _observe();
        }
        pool.socialiseLoss(amount);
        ++socialisedDone;
        if (pool.queuedShares() != 0) ++socialisedWithQueue;
        _observe();
    }

    /// @dev The raw loss: a token transfer out of the pool, then the permissionless reconcile.
    ///      One call in four only (the other three are refusals), so most runs stay raw-loss free
    ///      long enough for the protocol-path censuses to mean something.
    function rawLoss(uint256 bps, uint256 gate) external {
        uint256 cash = usdc.balanceOf(address(pool));
        uint256 amount = (cash * bound(bps, 1, 5_000)) / 10_000;
        if (gate % 4 != 0 || amount == 0) {
            ++refusals;
            return _observe();
        }
        vm.prank(address(pool));
        usdc.transfer(sink, amount);
        pool.reconcileCashDeficit();
        ++rawLossesDone;
        _observe();
    }

    function passTime(uint32 secs) external {
        skip(bound(uint256(secs), 1, 10 days));
        ++timeAdvances;
        _observe();
    }

    /// @dev Row 374's lead: the stranger sends ONE share-wei to a lender. The in-handler
    ///      property: it never moves that lender's live request door.
    function strangerDust(uint256 seed) external {
        address who = _lender(seed);
        if (pool.balanceOf(stranger) == 0) {
            if (pool.cashDeficit() != 0 || pool.maxDeposit(stranger) < 1e6 || pool.previewDeposit(1e6) == 0) {
                ++refusals;
                return _observe();
            }
            usdc.mint(stranger, 1e6);
            vm.prank(stranger);
            pool.deposit(1e6, stranger);
        }
        uint256 doorBefore = pool.maxRequestRedeem(who);
        vm.prank(stranger);
        pool.transfer(who, 1);
        ++dustsDone;
        if (requestSharesOf(who) != 0) ++dustsOntoALiveRequest;
        if (pool.maxRequestRedeem(who) != doorBefore) ++dustMovedADoor;
        _observe();
    }

    // ── the per-frame census ─────────────────────────────────────────────────

    function _observe() internal {
        ++frames;
        if (pool.cashDeficit() != 0) return; // an unreconciled instant: no action leaves one
        uint256 e = executable();
        uint256 floors = floorTotal();
        bool queue = pool.queuedShares() != 0;
        if (queue) ++framesWithQueue;
        if (queue && pool.unreleasedYield() != 0 && pool.outstandingPrincipal() != 0) {
            ++framesWithQueueStreamAndPrincipal;
        }
        if (floors > e) {
            ++floorsOverEFrames;
            if (rawLossesDone == 0) ++floorsOverEWithoutARawLoss;
        }

        bool anyDoor;
        bool excess;
        uint256 kept;
        for (uint256 i; i < LENDERS; ++i) {
            address who = lenders[i];
            uint256 shares = requestSharesOf(who);
            if (shares == 0) continue;
            uint256 doorCash = pool.previewRedeem(pool.maxRequestRedeem(who));
            if (doorCash != 0) anyDoor = true;
            if (doorCash > e) ++aDoorPromisedMoreThanE;
            uint256 floor = floorOf(who);
            if (floor > pool.convertToAssets(shares) + 2) excess = true;
            if (shares <= 1_000 && floor >= 1e6 && floor > kept) kept = floor;
        }
        if (excess) {
            ++excessFloorFrames;
            if (rawLossesDone == 0) ++excessFloorFramesWithoutARawLoss;
        }
        if (kept != 0) {
            ++keptFloorOnDustFrames;
            if (rawLossesDone == 0) ++keptFloorOnDustFramesWithoutARawLoss;
            if (kept > maxKeptFloorOnDust) maxKeptFloorOnDust = kept;
        }
        if (queue && !anyDoor && e >= 1e6 && floors <= e && pool.unreservedIdle() == 0) {
            ++allDoorsShutWithCashFrames;
            if (e > maxCashShutOut) maxCashShutOut = e;
        }
    }
}
