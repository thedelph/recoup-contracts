// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {R63A3_PoolDoorsHandler} from "./R63A3_PoolDoorsHandler.sol";

/// @title Round 63 seat A3: the one small stateful campaign, over a bare pool and its doors.
/// @notice UNSEEDED. Four violation ghosts, each beside a coverage ghost: a stranger's
///         share-wei never moves a live request door; a non-epoch arrival never lowers the
///         release rate (rule 1b); the floors never exceed the executable cash before a raw loss
///         (round 62's precondition, here with `socialiseLoss`, surpluses, epochs and dust in
///         play); no door promises more than the executable cash. The census ghosts count what
///         the deterministic suites found: a floor worth more than its escrowed shares, a floor
///         kept on dust, the epoch leg lowering the rate, a memory kept alive by dust, and row
///         369's shut-out frames.
/// @dev Reach: a forge campaign prints the ghosts of its LAST run only, so the campaign-wide
///      census is taken by `test_R63A3_census_aNamedPseudoRandomWalk`, which drives the same
///      handler from a NAMED keccak seed chain and prints exact totals. The unseeded campaign
///      is the violation search and the walk is the census.
contract R63A3_PoolDoorsInvariants is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;
    R63A3_PoolDoorsHandler internal handler;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), address(this));
        handler = new R63A3_PoolDoorsHandler(pool, usdc);
        // The handler stands in as the manager and the harvester: pool wiring, not a handler setter.
        pool.setCreditManager(address(handler));
        pool.setEpochHarvester(address(handler));
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    function invariant_everyInHandlerPropertyHeld() public view {
        assertEq(handler.dustMovedADoor(), 0, "a stranger's share-wei moved a live request door");
        assertEq(
            handler.nonEpochLoweredTheRate(), 0, "a non-epoch arrival lowered the rate by over a second of the window"
        );
        assertEq(handler.floorsOverEWithoutARawLoss(), 0, "the floors exceeded E with no raw loss");
        assertEq(handler.aDoorPromisedMoreThanE(), 0, "a request door promised more than the executable cash");
    }

    function afterInvariant() public view {
        console2.log("LAST-RUN CENSUS frames / refusals                       ", handler.frames(), handler.refusals());
        console2.log(
            "LAST-RUN CENSUS dusts / onto a live request             ",
            handler.dustsDone(),
            handler.dustsOntoALiveRequest()
        );
        console2.log(
            "LAST-RUN CENSUS kept-floor-on-dust frames / no raw loss ",
            handler.keptFloorOnDustFrames(),
            handler.keptFloorOnDustFramesWithoutARawLoss()
        );
        console2.log(
            "LAST-RUN CENSUS warm non-epoch arrivals / sub-second dips",
            handler.nonEpochWarmArrivals(),
            handler.nonEpochRateDipsInsideOneSecond()
        );
    }

    function _print() internal view {
        console2.log("MEASURED census: frames / refusals", handler.frames(), handler.refusals());
        console2.log(
            "MEASURED census: deposits / requests / cancels",
            handler.depositsDone(),
            handler.requestsDone(),
            handler.cancelsDone()
        );
        console2.log(
            "MEASURED census: services / leaving dust / completions",
            handler.servicesDone(),
            handler.dustServicesDone(),
            handler.completionsDone()
        );
        console2.log(
            "MEASURED census: redeems / claims / lends",
            handler.redeemsDone(),
            handler.claimsDone(),
            handler.lendsDone()
        );
        console2.log(
            "MEASURED census: repays / with a surplus / warm surplus",
            handler.repaysDone(),
            handler.surplusesDone(),
            handler.nonEpochWarmArrivals()
        );
        console2.log(
            "MEASURED census: epochs / mid-stream / that LOWERED the rate",
            handler.epochsDone(),
            handler.epochsMidStream(),
            handler.epochsThatLoweredTheRate()
        );
        console2.log(
            "MEASURED census: socialised / with a queue / raw losses",
            handler.socialisedDone(),
            handler.socialisedWithQueue(),
            handler.rawLossesDone()
        );
        console2.log(
            "MEASURED census: dusts / onto a live request / memory kept by dust",
            handler.dustsDone(),
            handler.dustsOntoALiveRequest(),
            handler.memoryKeptByDust()
        );
        console2.log(
            "MEASURED census: frames with a queue / with queue+stream+principal",
            handler.framesWithQueue(),
            handler.framesWithQueueStreamAndPrincipal()
        );
        console2.log(
            "MEASURED census: floors-over-E frames / before any raw loss",
            handler.floorsOverEFrames(),
            handler.floorsOverEWithoutARawLoss()
        );
        console2.log(
            "MEASURED census: excess-floor frames / before any raw loss",
            handler.excessFloorFrames(),
            handler.excessFloorFramesWithoutARawLoss()
        );
        console2.log(
            "MEASURED census: kept-floor-on-dust frames / before any raw loss",
            handler.keptFloorOnDustFrames(),
            handler.keptFloorOnDustFramesWithoutARawLoss()
        );
        console2.log("MEASURED census: largest floor kept on dust", handler.maxKeptFloorOnDust());
        console2.log(
            "MEASURED census: non-epoch rate dips inside one second", handler.nonEpochRateDipsInsideOneSecond()
        );
        console2.log(
            "MEASURED census: all-doors-shut-with-cash frames / max shut out",
            handler.allDoorsShutWithCashFrames(),
            handler.maxCashShutOut()
        );
    }

    function _violations() internal view returns (uint256) {
        return handler.dustMovedADoor() + handler.nonEpochLoweredTheRate() + handler.floorsOverEWithoutARawLoss()
            + handler.aDoorPromisedMoreThanE();
    }

    /// @notice Every state the ghosts are about, reached through the handler's own actions in one
    ///         deterministic sequence (the dust suite's D4 shape, then a raw loss).
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        handler.deposit(0, 5_000e6);
        handler.deposit(1, 5_000e6);
        handler.lend(5_000);
        assertEq(handler.lendsDone(), 1, "lend was never reached");
        handler.request(0, 10_000);
        assertEq(handler.requestsDone(), 1, "request was never reached");
        handler.strangerDust(0);
        assertEq(handler.dustsOntoALiveRequest(), 1, "dust never landed on a live request");
        handler.deliverEpoch(100e6);
        handler.passTime(uint32(2 days));
        handler.deliverEpoch(250_000);
        assertEq(handler.epochsMidStream(), 1, "no epoch landed mid-stream");
        assertEq(handler.epochsThatLoweredTheRate(), 1, "the dust epoch did not lower the rate");
        handler.repay(1, 8);
        assertEq(handler.surplusesDone(), 1, "no surplus was reached");
        assertEq(handler.nonEpochWarmArrivals(), 1, "no non-epoch arrival met a running stream");
        handler.passTime(uint32(10 days));
        handler.passTime(uint32(10 days));
        handler.deposit(2, 5_000e6);
        handler.lend(10_000);
        assertEq(handler.lendsDone(), 2, "the second loan was never made");
        assertGt(handler.framesWithQueue(), 0, "no frame had a queue");
        handler.redeemMax(1);
        handler.redeemMax(2);
        assertGt(handler.redeemsDone(), 0, "sync redeem was never reached");
        handler.socialise(10_000);
        assertEq(handler.socialisedWithQueue(), 1, "no loss was socialised with a queue");
        assertGt(handler.excessFloorFramesWithoutARawLoss(), 0, "no floor exceeded its shares' worth on protocol paths");
        handler.serviceAllButOneShareWei(0);
        assertEq(handler.dustServicesDone(), 1, "the dust service was never reached");
        // #64 fix: the same dust service keeps no floor of 1.000000 or more before a raw loss (was
        // > 0); it keeps its worth rounded up, 1 wei, under what this census counts.
        assertEq(handler.keptFloorOnDustFramesWithoutARawLoss(), 0, "#64: a floor was kept on dust before a raw loss");
        // An epoch streams before the completing service. The fix as first offered, with the worth
        // rounded down, needed it (its dust kept a floor of 0 and a door of 0); with the 1-wei floor
        // the door is open without it, and the rest of this walk is built on the state it leaves.
        handler.deliverEpoch(100e6);
        handler.passTime(uint32(7 days));
        handler.serviceMax(0);
        assertEq(handler.completionsDone(), 1, "no request completed");
        assertEq(handler.memoryKeptByDust(), 1, "the stranger's dust did not keep the memory alive");
        handler.claim(0);
        assertEq(handler.claimsDone(), 1, "claim was never reached");
        handler.request(2, 10_000);
        handler.cancel(2);
        assertEq(handler.cancelsDone(), 1, "cancel was never reached");
        handler.request(2, 10_000);
        handler.request(1, 10_000);
        handler.rawLoss(5_000, 4);
        assertEq(handler.rawLossesDone(), 1, "the raw loss was never reached");
        assertGt(handler.floorsOverEFrames(), 0, "the raw loss did not put the floors over E");
        assertEq(_violations(), 0, "a violation ghost moved");
        _print();
    }

    /// @notice The exact census: 40 walks of 400 handler calls each from the NAMED seed
    ///         keccak256(abi.encode("R63A3 census walk", walk)), every call drawn from the chain.
    ///         Seeded on purpose and said so: this is the census, the unseeded campaign is the
    ///         search. Four tests of ten walks each, because one test of forty runs out of the
    ///         test gas limit (measured: `OutOfGas` in the thirteenth walk of a 48-walk body).
    function test_R63A3_census_aNamedPseudoRandomWalk_00to09() public {
        _walks(0, 10);
    }

    function test_R63A3_census_aNamedPseudoRandomWalk_10to19() public {
        _walks(10, 20);
    }

    function test_R63A3_census_aNamedPseudoRandomWalk_20to29() public {
        _walks(20, 30);
    }

    function test_R63A3_census_aNamedPseudoRandomWalk_30to39() public {
        _walks(30, 40);
    }

    function _walks(uint256 from, uint256 to) internal {
        uint256 clean = vm.snapshotState();
        uint256[13] memory total;
        for (uint256 walk = from; walk < to; ++walk) {
            vm.revertToState(clean);
            bytes32 seed = keccak256(abi.encode("R63A3 census walk", walk));
            for (uint256 step; step < 400; ++step) {
                seed = keccak256(abi.encode(seed));
                _dispatch(uint256(seed));
            }
            _add(total);
        }
        console2.log("MEASURED WALK TOTAL (walks from / to, 400 calls each)", from, to);
        console2.log("MEASURED WALK TOTAL: frames / refusals", total[0], total[1]);
        console2.log("MEASURED WALK TOTAL: kept-floor-on-dust frames / before any raw loss", total[2], total[3]);
        console2.log("MEASURED WALK TOTAL: excess-floor frames before any raw loss", total[4]);
        console2.log("MEASURED WALK TOTAL: epochs mid-stream / that lowered the rate", total[6], total[5]);
        console2.log("MEASURED WALK TOTAL: warm non-epoch arrivals / memory kept by dust", total[11], total[7]);
        console2.log("MEASURED WALK TOTAL: all-doors-shut frames / floors-over-E frames", total[8], total[9]);
        console2.log("MEASURED WALK TOTAL: largest floor kept on dust / largest shut-out", total[10], total[12]);
        console2.log("MEASURED WALK TOTAL: violation ghosts (every walk required 0)", uint256(0));
        assertEq(total[0], (to - from) * 400, "a walk dropped a frame");
    }

    /// @dev Memory survives the state revert between walks and storage does not, so the totals
    ///      and the two running maxima ride in `total`.
    function _add(uint256[13] memory total) internal view {
        total[0] += handler.frames();
        total[1] += handler.refusals();
        total[2] += handler.keptFloorOnDustFrames();
        total[3] += handler.keptFloorOnDustFramesWithoutARawLoss();
        total[4] += handler.excessFloorFramesWithoutARawLoss();
        total[5] += handler.epochsThatLoweredTheRate();
        total[6] += handler.epochsMidStream();
        total[7] += handler.memoryKeptByDust();
        total[8] += handler.allDoorsShutWithCashFrames();
        total[9] += handler.floorsOverEFrames();
        if (handler.maxKeptFloorOnDust() > total[10]) total[10] = handler.maxKeptFloorOnDust();
        total[11] += handler.nonEpochWarmArrivals();
        if (handler.maxCashShutOut() > total[12]) total[12] = handler.maxCashShutOut();
        require(_violations() == 0, "a violation ghost moved on a census walk");
    }

    function _dispatch(uint256 r) internal {
        uint256 action = r % 14;
        uint256 x = r >> 8;
        uint256 y = uint256(keccak256(abi.encode(r)));
        if (action == 0) handler.deposit(x, y);
        else if (action == 1) handler.request(x, y);
        else if (action == 2) handler.cancel(x);
        else if (action == 3) handler.serviceMax(x);
        else if (action == 4) handler.serviceAllButOneShareWei(x);
        else if (action == 5) handler.redeemMax(x);
        else if (action == 6) handler.claim(x);
        else if (action == 7) handler.lend(x);
        else if (action == 8) handler.repay(x, y);
        else if (action == 9) handler.deliverEpoch(y);
        else if (action == 10) handler.socialise(x);
        else if (action == 11) handler.rawLoss(x, y);
        else if (action == 12) handler.passTime(uint32(y));
        else handler.strangerDust(x);
    }
}
