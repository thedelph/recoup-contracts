// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MintAttemptReceiver} from "../src/MintAttemptReceiver.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev A DexFi farm that, once, from inside `withdraw`, calls the adapter's permissionless
///      `flushMintAttemptYield`. `IDexFiFarm`'s own docstring says farm behaviour is mutable at
///      DexFi's discretion, and the adapter carries no `ReentrancyGuard` by design. The inner call
///      is wrapped so the test can read whether it went through; the outer measurement is what
///      the finding is about.
contract R49CloneFlushingFarm is MockFarm {
    DirectCallAdapter public adapter;
    address public beneficiary;
    bytes32 public attemptId;
    bool public armed;
    bool public fired;
    bool public innerOk;
    bytes public innerRevert;

    constructor(MockBond bond_, MockUSDC usdc_) MockFarm(bond_, usdc_) {}

    function armFlushMintAttempt(DirectCallAdapter adapter_, address beneficiary_, bytes32 attemptId_) external {
        adapter = adapter_;
        beneficiary = beneficiary_;
        attemptId = attemptId_;
        armed = true;
        fired = false;
    }

    function withdraw(uint256 amount) external override {
        _maybeReenter();
        // `MockFarm.withdraw`, verbatim: an external function cannot be reached through `super`.
        if (revertOnWithdraw) revert FarmDown();
        if (amount > staked[msg.sender]) revert InsufficientStake(amount, staked[msg.sender]);
        uint256 pending = pendingYield[msg.sender];
        pendingYield[msg.sender] = 0;
        if (pending > 0) {
            pending += userDebt[msg.sender];
            userDebt[msg.sender] = 0;
            usdc.mint(msg.sender, pending);
        }
        if (amount > 0) {
            staked[msg.sender] -= amount;
            bond.safeTransferFrom(address(this), msg.sender, bond.TOKEN_ID(), amount, "");
        }
    }

    function _maybeReenter() private {
        if (armed && !fired) {
            fired = true;
            try adapter.flushMintAttemptYield(beneficiary, attemptId) {
                innerOk = true;
            } catch (bytes memory err) {
                innerRevert = err;
            }
        }
    }
}

/// @notice Round-49 finding: the clone's own farm window in `MintAttemptReceiver.recoverAll`.
///
/// @dev Round 48 counted the adapter's farm windows - seven saturated through `_farmDelta`, one
///      (`_recoverTo`) deliberately bare - and the clone has a bare window of its own inside that
///      recovery that the census did not name. `recoverAll` measured `farm.withdraw` with a bare
///      `usdc.balanceOf(address(this)) - beforeBalance`. The only thing that moves USDC out of a
///      clone is `_tryTransferUsdc`, reachable through the adapter's PERMISSIONLESS
///      `flushMintAttemptYield` - so the farm, from inside the window, has the adapter make the
///      clone forward its park, the clone's balance drops below `beforeBalance`, and the clone
///      panics `0x11`. The adapter's own `_recoverTo` window never sees it: the flush brings USDC
///      in and sweeps it out again, netting zero there. Found, sign-checked and executed in
///      audit round 49 with an INERT recipient, so every drain here is the farm's; the fix is
///      the saturating subtraction the same file already uses in
///      `emergencyRecoverAll` and `_tryForwardRawUsdc`.
contract R49CloneFarmWindowTest is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant CLONE_PARK = 7e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");
    address internal treasury = makeAddr("treasury");
    /// @dev A plain EOA. It has no code, so it cannot re-enter anything.
    address payable internal recipient = payable(makeAddr("inertRecoveryRecipient"));

    MockUSDC internal usdc;
    MockBond internal bond;
    R49CloneFlushingFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new R49CloneFlushingFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        bond.setTreasury(payable(treasury));
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
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
    }

    /// @dev The documented route to a park at a CLONE: farm yield the clone could not forward
    ///      because the adapter could not receive at that moment. Same build as
    ///      `R34RecoveryReentrancyTest.test_B_*`.
    function _parkAtClone(bytes32 id, uint256 amount) internal returns (address receiver) {
        receiver = adapter.predictMintReceiver(alice, id);
        farm.setPendingYield(receiver, amount);
        usdc.setBlocked(address(adapter), true);
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, id, recipient);
        usdc.setBlocked(address(adapter), false);
        assertEq(MintAttemptReceiver(payable(receiver)).parkedFarmYield(), amount, "premise: parked at the clone");
        assertEq(usdc.balanceOf(receiver), amount, "premise: the park is the clone's whole balance");
    }

    /// @dev Control: a clone carrying parked yield is recovered again by a quiet farm, and the
    ///      park is forwarded on the way.
    function test_R49_control_aParkedCloneIsRecoveredAgainByAQuietFarm() public {
        bytes32 id = keccak256("R49-clone");
        address receiver = _parkAtClone(id, CLONE_PARK);
        // A phantom pending share, so `recoverAll` enters its farm window at all. The real farm
        // would report this after any later stake for the clone; a mutable one reports what it likes.
        farm.setPendingYield(receiver, 1);

        vm.prank(admin);
        (, uint256 swept,,,,) = adapter.recoverMintAttempt(alice, id, recipient);
        assertEq(MintAttemptReceiver(payable(receiver)).parkedFarmYield(), 0, "control: the park was forwarded");
        assertEq(swept, CLONE_PARK + 1, "control: park plus the fresh wei, swept");
    }

    /// @notice The finding, inverted into the recovery that now goes through.
    /// @dev RED before the saturation, MEASURED at `73b474a`: the owner's recovery reverted
    ///      `panic: arithmetic underflow or overflow (0x11)` out of the clone's bare window, with
    ///      the farm's inner flush having succeeded. Saturated, the window reports 0 for the wei
    ///      the farm paid - the same under-count `_farmDelta` accepts on the adapter - and the
    ///      recovery completes with nothing left on the clone.
    function test_R49_theClonesFarmWindowSurvivesTheFarmFlushingItsParkedYield() public {
        bytes32 id = keccak256("R49-clone");
        address receiver = _parkAtClone(id, CLONE_PARK);
        farm.setPendingYield(receiver, 1);
        farm.armFlushMintAttempt(adapter, alice, id);

        vm.prank(admin);
        adapter.recoverMintAttempt(alice, id, recipient);

        assertTrue(farm.fired(), "the farm did re-enter");
        assertTrue(farm.innerOk(), "and its inner flush went through, moving the park mid-window");
        assertEq(MintAttemptReceiver(payable(receiver)).parkedFarmYield(), 0, "the park left through the flush");
        assertEq(usdc.balanceOf(receiver), 0, "and the clone holds nothing afterwards");
    }

    /// @dev The bound, as for the adapter: anybody can discharge the clone's park first through
    ///      the same permissionless door, and then the armed farm finds nothing to move. Green
    ///      before and after the fix; here so the finding's shape is bracketed on both sides.
    function test_R49_dischargingTheClonesParkFirstLeavesTheArmedFarmNothingToMove() public {
        bytes32 id = keccak256("R49-clone");
        address receiver = _parkAtClone(id, CLONE_PARK);
        adapter.flushMintAttemptYield(alice, id);
        assertEq(MintAttemptReceiver(payable(receiver)).parkedFarmYield(), 0);

        farm.setPendingYield(receiver, 1);
        farm.armFlushMintAttempt(adapter, alice, id);
        vm.prank(admin);
        (, uint256 swept,,,,) = adapter.recoverMintAttempt(alice, id, recipient);
        assertEq(swept, 1, "recovery went through");
        assertTrue(farm.fired(), "the farm did re-enter");
        assertTrue(farm.innerOk(), "its inner flush succeeded and moved nothing");
    }
}
