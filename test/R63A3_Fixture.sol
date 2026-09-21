// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Round 63 seat A3: the bare-pool fixture every R63A3 suite shares.
/// @notice The same shape as `R42S1_H03Floor` (a real `LenderPool` over `MockUSDC`, the manager
///         and the harvester as pranked roles, the raw loss simulated by a token transfer out of
///         the pool followed by `reconcileCashDeficit`), rewritten here as an abstract contract
///         with NO tests of its own so that a suite inheriting it runs only its own bodies.
/// @dev `_floorTotal` is slot 33 and a request's floor the fourth word of its
///      `WithdrawalRequest` (mapping at slot 25); the request-draw memory is the mapping at slot
///      32 (`_requestDraws`, declared just before `_floorTotal`). All three are read by `vm.load`
///      and `test_R63A3_theSlotsThisFixtureReads` in the dust suite checks them against
///      behaviour. Figures are six-decimal USDC base units.
abstract contract R63A3_Fixture is Test {
    uint256 internal constant FLOOR_TOTAL_SLOT = 33;
    uint256 internal constant REQUEST_DRAWS_SLOT = 32;
    uint256 internal constant WITHDRAWAL_REQUESTS_SLOT = 25;
    uint256 internal constant REQUEST_FLOOR_WORD = 3;

    uint256 internal constant EACH = 100e6;
    uint256 internal constant D = Config.YIELD_STREAM_DURATION;

    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal sink = makeAddr("cash-sink");
    address internal fresh = makeAddr("fresh");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
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

    // ── actors ───────────────────────────────────────────────────────────────

    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0x100000 + i));
    }

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

    function _request(address who, uint256 shares) internal {
        vm.prank(who);
        pool.requestWithdrawal(shares, who);
    }

    function _cancel(address who) internal {
        vm.prank(who);
        pool.cancelWithdrawalRequest();
    }

    function _service(address who, uint256 shares) internal returns (uint256 paid) {
        vm.prank(who);
        paid = pool.serviceWithdrawalRequest(who, shares, 0);
    }

    /// @dev The raw loss: cash leaves the pool to an external sink and the pool reconciles it.
    function _loseCash(uint256 amount) internal {
        vm.prank(address(pool));
        usdc.transfer(sink, amount);
        pool.reconcileCashDeficit();
    }

    /// @dev The raw loss with nobody reconciling it yet.
    function _loseCashUnreconciled(uint256 amount) internal {
        vm.prank(address(pool));
        usdc.transfer(sink, amount);
    }

    /// @dev An accepted epoch through the real path: the harvester role delivers `amount`.
    function _deliverYield(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.prank(harvester);
        pool.distributeYield(amount);
    }

    // ── reads ────────────────────────────────────────────────────────────────

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

    function _requestShares(address who) internal view returns (uint256 shares) {
        (,, shares,,) = pool.withdrawalRequest(who);
    }

    /// @dev The request-draw memory of a controller: shares burned and cash set aside.
    function _drawMemory(address who) internal view returns (uint256 shares, uint256 assets) {
        bytes32 base = keccak256(abi.encode(who, REQUEST_DRAWS_SLOT));
        shares = uint256(vm.load(address(pool), base));
        assets = uint256(vm.load(address(pool), bytes32(uint256(base) + 1)));
    }

    /// @dev The floors less the executable cash, saturating: the quantity every door reads.
    function _shortfall() internal view returns (uint256) {
        uint256 floors = _floorTotal();
        uint256 executable = _executable();
        return floors > executable ? floors - executable : 0;
    }

    function _capOf(address who) internal view returns (uint256) {
        uint256 executable = _executable();
        uint256 owedToOthers = _floorTotal() - _floorOf(who);
        return executable > owedToOthers ? executable - owedToOthers : 0;
    }

    // ── drains ───────────────────────────────────────────────────────────────

    /// @dev Service one holder's request until it reaches no more cash, at most 64 calls. The
    ///      stop is zero CASH, not zero shares (after a loss a door can read a few shares whose
    ///      `previewRedeem` is 0).
    function _drainToZeroCash(address who) internal returns (uint256 paid) {
        for (uint256 call; call < 64; ++call) {
            uint256 shares = pool.maxRequestRedeem(who);
            if (shares == 0 || pool.previewRedeem(shares) == 0) break;
            paid += _service(who, shares);
        }
    }

    /// @dev Every holder 0..count-1 drains in turn, in passes, until a whole pass pays nothing.
    function _drainAll(uint256 count) internal returns (uint256 paid) {
        for (uint256 pass; pass < 8; ++pass) {
            uint256 before = paid;
            for (uint256 i; i < count; ++i) {
                paid += _drainToZeroCash(_holder(i));
            }
            if (paid == before) break;
        }
    }

    function _queueEqualFloors(uint256 count, uint256 each) internal {
        for (uint256 i; i < count; ++i) {
            _deposit(_holder(i), each);
        }
        for (uint256 i; i < count; ++i) {
            _requestAll(_holder(i));
            assertEq(_floorOf(_holder(i)), each, "fixture: a queued floor is not the holder's whole deposit");
        }
    }

    function _logDoors(string memory label, uint256 count) internal view {
        for (uint256 i; i < count; ++i) {
            console2.log(label, i, _serviceable(_holder(i)));
        }
    }
}
