// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

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

/// @notice Audit round 34 / agent A2. USDC accounting-identity probes for
///         `DirectCallAdapter.farmYieldDelivered`.
/// @dev Every test here is a measurement, not a production requirement. The two
///      exotic tokens below model shapes real USDC does not have today but which its
///      upgradeable proxy could ship tomorrow: a transfer that moves less than it was
///      asked for, and one that credits the recipient more than it was asked for.

/// @notice Moves only `value / 2` and still returns true. Fee-on-transfer / partial-
///         transfer shape. `DirectCallAdapter._trySweepUsdc`'s own comment names this
///         case explicitly as one it measures rather than trusts.
contract PartialUSDC is MockUSDC {
    bool public partialMode;

    function setPartial(bool value) external {
        partialMode = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (partialMode) return super.transfer(to, value / 2);
        return super.transfer(to, value);
    }
}

/// @notice Credits the recipient a one-shot bonus on top of the requested amount, so
///         a measured balance delta exceeds the amount asked for.
contract OverpayUSDC is MockUSDC {
    uint256 public bonus;

    function setBonus(uint256 value) external {
        bonus = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        if (ok && bonus != 0) {
            uint256 b = bonus;
            bonus = 0;
            _mint(to, b);
        }
        return ok;
    }
}

/// @notice Recovery recipient that reenters the adapter on the native forward and
///         drains a parked balance, shrinking the adapter's measured USDC delta below
///         what the child reported.
contract ReentrantRecoveryRecipient {
    DirectCallAdapter public adapter;
    address public flushFor;
    bool public armed;

    function arm(DirectCallAdapter adapter_, address flushFor_) external {
        adapter = adapter_;
        flushFor = flushFor_;
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        adapter.flushYieldTo(flushFor);
    }
}

/// @notice A token that drains the adapter's parked USDC from inside its own `transfer`, so the
///         movement happens between `_tryTransferUsdc`'s two balance reads rather than before them.
/// @dev    One-shot, because `flushYieldTo` itself transfers and would otherwise recurse.
contract ReentrantOnTransferUSDC is MockUSDC {
    DirectCallAdapter public adapter;
    address public flushFor;
    bool public armed;

    function arm(DirectCallAdapter adapter_, address flushFor_) external {
        adapter = adapter_;
        flushFor = flushFor_;
        armed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        if (ok && armed) {
            armed = false;
            adapter.flushYieldTo(flushFor);
        }
        return ok;
    }
}

/// @notice A farm that drains the adapter's parked USDC from inside `emergencyWithdraw`, so the
///         adapter's measured delta across `emergencyRecoverAll()` comes out BELOW what the child
///         reports it forwarded.
/// @dev    The FARM rather than a recovery recipient, and that is a reachability result rather than
///         a choice of convenience. On the emergency path there is no recovery recipient at all -
///         `emergencyRecoverMintAttempt` takes no address and the only call out of the adapter is
///         into an ERC-1167 clone whose codehash `_requireMintReceiverCode` has just checked - so
///         the window holds no arbitrary external call. The child then calls only `farm`, `bond`
///         and `usdc`, which are immutable bindings this repository nevertheless treats as mutable
///         because all three are owned or upgradeable by somebody else.
///
///         Of those three, a re-entrant USDC cannot reach the clamp: `_tryTransferUsdc` reads the
///         adapter's balance immediately before and after the transfer, so a drain performed by the
///         token shrinks the child's own report by the same amount and the two stay equal. The
///         reachable window runs from the adapter's `usdcBefore` to that read, and the only code
///         that gets control inside it is `farm.emergencyWithdraw()` and the ERC-1155 transfer that
///         function makes.
contract ReentrantEmergencyFarm is MockFarm {
    DirectCallAdapter public adapter;
    address public flushFor;
    bool public armed;
    bool public armedOnWithdraw;

    constructor(MockBond bond_, MockUSDC usdc_) MockFarm(bond_, usdc_) {}

    function arm(DirectCallAdapter adapter_, address flushFor_) external {
        adapter = adapter_;
        flushFor = flushFor_;
        armed = true;
    }

    /// @dev The ordinary-deposit twin. `MintAttemptReceiver.releaseMint` calls `farm.withdraw`
    ///      before it forwards anything, so a drain here also lands inside the adapter's window and
    ///      outside the child's. Armed separately, because every fixture in this file reaches
    ///      `withdraw` on its way to anything else.
    function armOnWithdraw(DirectCallAdapter adapter_, address flushFor_) external {
        adapter = adapter_;
        flushFor = flushFor_;
        armedOnWithdraw = true;
    }

    function withdraw(uint256 amount) external override {
        if (armedOnWithdraw) {
            armedOnWithdraw = false;
            adapter.flushYieldTo(flushFor);
        }
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

    function emergencyWithdraw() external override {
        if (armed) {
            armed = false;
            // Permissionless, takes its destination from storage, and moves USDC OUT of the
            // adapter. Exactly the call `_recoverTo`'s docstring names as re-enterable from its own
            // three windows; this is the fourth, and it is the only one the emergency path has.
            adapter.flushYieldTo(flushFor);
        }
        uint256 amount = staked[msg.sender];
        staked[msg.sender] = 0;
        pendingYield[msg.sender] = 0;
        bond.safeTransferFrom(address(this), msg.sender, bond.TOKEN_ID(), amount, "");
    }
}

abstract contract R34Base is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant PAYMENT = 1 ether;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");
    address internal treasury = makeAddr("treasury");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function _deployUsdc() internal virtual returns (MockUSDC) {
        return new MockUSDC();
    }

    /// @dev The farm's twin of `_deployUsdc`, added in round 43 so a suite can substitute a
    ///      re-entrant farm without a second copy of this fixture. Default behaviour unchanged.
    function _deployFarm(MockBond bond_, MockUSDC usdc_) internal virtual returns (MockFarm) {
        return new MockFarm(bond_, usdc_);
    }

    function setUp() public virtual {
        usdc = _deployUsdc();
        bond = new MockBond();
        farm = _deployFarm(bond, usdc);
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

    function _input(uint256 uuid, address receiver, uint256 amount, uint256 payment)
        internal
        view
        returns (IDexFiBond.MintDataInput memory)
    {
        return IDexFiBond.MintDataInput({
            uuid: uuid,
            nonce: 0,
            receiver: receiver,
            amountNfts: amount,
            paymentAmount: payment,
            deadline: block.timestamp + 1 days,
            signature: ""
        });
    }

    function _deposit(address who, bytes32 attemptId, uint256 uuid, uint256 amount)
        internal
        returns (address receiver)
    {
        receiver = adapter.predictMintReceiver(who, attemptId);
        vm.deal(who, PAYMENT);
        vm.prank(who);
        vault.depositETH{value: PAYMENT}(attemptId, abi.encode(_input(uuid, receiver, amount, PAYMENT)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Case E: the partial sweep. `_settleFarmPayout` throws away the amount
// `_trySweepUsdc` measured and credits `farmPaid + unreportedYield` regardless.
// ─────────────────────────────────────────────────────────────────────────────
contract R34PartialSweepTest is R34Base {
    function _deployUsdc() internal override returns (MockUSDC) {
        return new PartialUSDC();
    }

    function test_R34_partialSweepOverCountsFarmYieldDelivered() public {
        PartialUSDC token = PartialUSDC(address(usdc));
        farm.setPendingYield(address(adapter), 1_000e6);
        token.setPartial(true);

        vm.prank(address(vault));
        uint256 reported = adapter.claimYield();

        emit log_named_uint("MEASURED farmYieldDelivered", adapter.farmYieldDelivered());
        emit log_named_uint("MEASURED yieldSink actually received", usdc.balanceOf(yieldSink));
        emit log_named_uint("MEASURED stranded at the adapter", usdc.balanceOf(address(adapter)));
        emit log_named_uint("MEASURED unreportedYield", adapter.unreportedYield());
        emit log_named_uint("MEASURED claimYield return", reported);

        assertEq(adapter.farmYieldDelivered(), 1_000e6, "counter credits the full farm payout");
        assertEq(usdc.balanceOf(yieldSink), 500e6, "the recipient received half of it");
        assertEq(usdc.balanceOf(address(adapter)), 500e6, "the other half never left");
        assertEq(adapter.unreportedYield(), 0, "and the carry counter was cleared anyway");
        assertGt(
            adapter.farmYieldDelivered(),
            usdc.balanceOf(yieldSink),
            "IDENTITY BROKEN: the harvester's watermark exceeds delivered USDC"
        );
    }

    /// @dev The residue is now free balance that no counter claims. The next farm
    ///      payout sweeps it onward and never counts it: the over-count is followed
    ///      by an equal-and-opposite under-count, so the error is timing, not total -
    ///      but the harvester rates an epoch on the instantaneous figure.
    function test_R34_partialSweepResidueIsSweptButNeverCounted() public {
        PartialUSDC token = PartialUSDC(address(usdc));
        farm.setPendingYield(address(adapter), 1_000e6);
        token.setPartial(true);
        vm.prank(address(vault));
        adapter.claimYield();

        token.setPartial(false);
        farm.setPendingYield(address(adapter), 0);
        vm.prank(address(vault));
        adapter.claimYield();

        emit log_named_uint("MEASURED farmYieldDelivered after second claim", adapter.farmYieldDelivered());
        emit log_named_uint("MEASURED yieldSink total", usdc.balanceOf(yieldSink));
        assertEq(usdc.balanceOf(yieldSink), 1_000e6, "all of it eventually arrives");
        assertEq(adapter.farmYieldDelivered(), 1_000e6, "and the total is right in the end");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Case A: `_tryTransferUsdc`'s `forwarded > amount` clamp.
// ─────────────────────────────────────────────────────────────────────────────
contract R34OverCreditTest is R34Base {
    function _deployUsdc() internal override returns (MockUSDC) {
        return new OverpayUSDC();
    }

    function test_R34_overCreditedForwardIsClampedAndTheBonusIsNeverCounted() public {
        OverpayUSDC token = OverpayUSDC(address(usdc));
        bytes32 attemptId = keccak256("A");
        address receiver = adapter.predictMintReceiver(alice, attemptId);

        // The clone is paid 300.000000 by the farm's auto-deposit hook.
        farm.setPendingYield(receiver, 300e6);
        // The token credits the adapter 77.000000 more than the clone asked it to move.
        token.setBonus(77e6);

        _deposit(alice, attemptId, 9001, 40);

        emit log_named_uint("MEASURED farmYieldDelivered", adapter.farmYieldDelivered());
        emit log_named_uint("MEASURED yieldSink balance", usdc.balanceOf(yieldSink));
        emit log_named_uint("MEASURED clone parkedFarmYield", MintAttemptReceiver(payable(receiver)).parkedFarmYield());

        assertEq(MintAttemptReceiver(payable(receiver)).parkedFarmYield(), 0, "clamp keeps the park from underflowing");
        assertEq(adapter.farmYieldDelivered(), 300e6, "only the corroborated farm payout is counted");
        assertEq(usdc.balanceOf(yieldSink), 377e6, "the bonus is forwarded as an uncounted donation");
        assertLe(adapter.farmYieldDelivered(), usdc.balanceOf(yieldSink), "identity holds, under-counting");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Case B: `reported > received` in `_recoverTo` (clamp 664), via a reentrant
// owner-chosen recovery recipient that drains a parked balance mid-call.
// ─────────────────────────────────────────────────────────────────────────────
contract R34ReentrantRecoveryTest is R34Base {
    ReentrantRecoveryRecipient internal recipient;

    function setUp() public override {
        super.setUp();
        recipient = new ReentrantRecoveryRecipient();
    }

    /// @dev Builds a park of 100.000000 owed to `yieldSink`, then recovers a clone
    ///      holding 400.000000 of farm yield with a recipient that flushes the park
    ///      from inside the native forward.
    function _park(uint256 amount) internal {
        farm.setPendingYield(address(adapter), amount);
        usdc.setBlocked(yieldSink, true);
        vm.prank(address(vault));
        adapter.claimYield();
        assertEq(adapter.unreportedYield(), amount, "premise: carried");
        vm.prank(admin);
        adapter.setYieldRecipient(makeAddr("newSink"));
        assertEq(adapter.owedToRecipient(yieldSink), amount, "premise: parked");
        usdc.setBlocked(yieldSink, false);
    }

    function test_R34_reentrantRecoveryMakesReportedExceedReceived() public {
        _park(100e6);

        bytes32 attemptId = keccak256("R");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setPendingYield(receiver, 400e6);
        vm.deal(receiver, 1 ether);

        recipient.arm(adapter, yieldSink);
        uint256 deliveredBefore = adapter.farmYieldDelivered();

        vm.prank(admin);
        adapter.recoverMintAttempt(alice, attemptId, payable(address(recipient)));

        uint256 counted = adapter.farmYieldDelivered() - deliveredBefore;
        emit log_named_uint("MEASURED farm USDC the clone actually forwarded", 400e6);
        emit log_named_uint("MEASURED counted by farmYieldDelivered", counted);
        emit log_named_uint("MEASURED flushed to the parked recipient mid-call", usdc.balanceOf(yieldSink));

        assertEq(usdc.balanceOf(yieldSink), 100e6, "the park was flushed inside the window");
        assertEq(counted, 300e6, "the clamp under-counts by exactly the flushed park");
        assertLt(counted, 400e6, "clamp 664 fires: reported 400.000000 > received 300.000000");
    }

    /// @dev The same reentrancy with a park larger than the recovered farm yield
    ///      makes the adapter's raw delta negative and panics on the subtraction.
    function test_R34_reentrantRecoveryLargerParkPanicsOnTheDelta() public {
        _park(400e6);

        bytes32 attemptId = keccak256("R2");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setPendingYield(receiver, 100e6);
        vm.deal(receiver, 1 ether);
        recipient.arm(adapter, yieldSink);

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        adapter.recoverMintAttempt(alice, attemptId, payable(address(recipient)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Case B': `reported > received` in `_emergencyRecover`, which is the TWIN of case B
// and was the last of the five `min` clamps with no test at all.
//
// Audit round 42 bisected the five and found `_recoverTo`'s red under case B while the
// other four stayed green, then left the emergency twin open as "the only uncovered
// clamp whose outer window holds an arbitrary external call". Round 43 built it, and
// that premise is REFUTED while the clamp is confirmed: the window holds no
// arbitrary external call. `emergencyRecoverMintAttempt` takes no recipient address, and
// `_prepareRecovery` either deploys the clone itself or checks `receiver.codehash`
// against the exact 45-byte ERC-1167 runtime for `mintReceiverImplementation`, so the
// only callee is code this contract wrote. The clamp is still load-bearing, through the
// farm.
// ─────────────────────────────────────────────────────────────────────────────
contract R34EmergencyClampTest is R34Base {
    address internal newSink = makeAddr("newSink");

    function _deployFarm(MockBond bond_, MockUSDC usdc_) internal override returns (MockFarm) {
        return new ReentrantEmergencyFarm(bond_, usdc_);
    }

    /// @notice The clamp in `_emergencyRecover` fires, and the direction it fires in is the one
    ///         that keeps `farmYieldDelivered` from crediting money that never arrived.
    /// @dev    THE SIGN CHECK, stated rather than assumed. The clamp only ever binds when
    ///         `reportedFarm > received`, and dropping it would raise `farmYieldDelivered` above
    ///         the USDC the adapter actually gained. That counter is `EpochHarvester`'s
    ///         corroboration watermark, so an over-report there rates an epoch against money the
    ///         protocol does not hold - the exact defect round 11 built the counter to close and
    ///         round 22 measured it failing. Under-counting is the safe direction and is what this
    ///         test asserts: 250.000000 forwarded by the child, 150.000000 counted, and the
    ///         100.000000 difference is real money that went to a real destination inside the same
    ///         transaction. Nothing is lost; the watermark simply does not claim it.
    ///
    ///         The arithmetic, in full, because "conserved" is a claim and not a measurement:
    ///         the clone parks 250.000000 during a deposit the adapter could not receive; the
    ///         adapter separately carries 100.000000 owed to a former recipient; the farm flushes
    ///         that 100.000000 to `yieldSink` mid-call, then the clone forwards its 250.000000. The
    ///         adapter's delta is 150.000000, its free balance is then 250.000000 and all of it is
    ///         swept to `newSink`. 100 + 250 = 350 = the park plus the clone's yield.
    function test_R43_emergencyRecoverClampFiresWhenTheFarmDrainsMidCall() public {
        // 1. Park 250.000000 of farm yield at the clone: the adapter cannot receive USDC while the
        //    auto-stake hook pays, so `releaseMint`'s forward fails and the child holds it.
        bytes32 attemptId = keccak256("E");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setPendingYield(receiver, 250e6);
        usdc.setBlocked(address(adapter), true);
        _deposit(alice, attemptId, 4301, 40);
        usdc.setBlocked(address(adapter), false);
        assertEq(
            MintAttemptReceiver(payable(receiver)).parkedFarmYield(), 250e6, "premise: parked at the clone"
        );

        // 2. Give the adapter 100.000000 owed to a former yield recipient, which is what the
        //    permissionless `flushYieldTo` pays down.
        farm.setPendingYield(address(adapter), 100e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(address(vault));
        adapter.claimYield();
        assertEq(adapter.unreportedYield(), 100e6, "premise: carried");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        assertEq(adapter.owedToRecipient(yieldSink), 100e6, "premise: parked at the adapter");
        usdc.setBlocked(yieldSink, false);

        // 3. `emergencyRecoverAll` calls `farm.emergencyWithdraw()` only when the clone has a stake
        //    or a pending share. One micro-USDC of pending is enough, and the emergency exit
        //    forfeits it, so it never becomes yield and cannot muddy the arithmetic above.
        farm.setPendingYield(receiver, 1);
        ReentrantEmergencyFarm(address(farm)).arm(adapter, yieldSink);

        uint256 deliveredBefore = adapter.farmYieldDelivered();
        vm.prank(admin);
        (, uint256 swept,,) = adapter.emergencyRecoverMintAttempt(alice, attemptId);
        uint256 counted = adapter.farmYieldDelivered() - deliveredBefore;

        emit log_named_uint("MEASURED farm USDC the clone reported forwarding", 250e6);
        emit log_named_uint("MEASURED counted by farmYieldDelivered", counted);
        emit log_named_uint("MEASURED flushed to the former recipient mid-call", usdc.balanceOf(yieldSink));
        emit log_named_uint("MEASURED swept to the current recipient", usdc.balanceOf(newSink));

        assertEq(usdc.balanceOf(yieldSink), 100e6, "the park was flushed inside the window");
        assertEq(counted, 150e6, "the clamp under-counts by exactly the flushed park");
        assertEq(swept, 150e6, "and the returned figure is the clamped one, not the child's report");
        assertLt(counted, 250e6, "THE CLAMP FIRES: reported 250.000000 > received 150.000000");
        assertEq(usdc.balanceOf(newSink), 250e6, "every USDC left the adapter; only the count is short");
        assertEq(usdc.balanceOf(address(adapter)), 0, "nothing stranded");
        assertLe(
            adapter.farmYieldDelivered(),
            usdc.balanceOf(newSink) + usdc.balanceOf(yieldSink),
            "IDENTITY HOLDS, under-counting: the watermark never exceeds delivered USDC"
        );
    }

    /// @notice The control. With the farm behaving, the same recovery counts the child's whole
    ///         report, so the test above is measuring the reentrancy and not the fixture.
    function test_R43_emergencyRecoverCountsEverythingWhenNothingDrains() public {
        bytes32 attemptId = keccak256("E2");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setPendingYield(receiver, 250e6);
        usdc.setBlocked(address(adapter), true);
        _deposit(alice, attemptId, 4302, 40);
        usdc.setBlocked(address(adapter), false);

        farm.setPendingYield(receiver, 1);
        // Deliberately NOT armed.
        uint256 deliveredBefore = adapter.farmYieldDelivered();
        vm.prank(admin);
        (, uint256 swept,,) = adapter.emergencyRecoverMintAttempt(alice, attemptId);

        assertEq(adapter.farmYieldDelivered() - deliveredBefore, 250e6, "the whole report is counted");
        assertEq(swept, 250e6);
        assertEq(usdc.balanceOf(yieldSink), 250e6, "and it reached the recipient");
    }

    /// @notice `_releaseFromReceiver`'s clamp fires too, on the ORDINARY deposit path, through the
    ///         same farm reentrancy - which round 42 classified as structurally unreachable.
    /// @dev    🟥 THIS CORRECTS THE ROUND-42 BISECTION. That round put this clamp in the group where
    ///         "`received` is measured over a window that strictly contains the window `reported` is
    ///         measured over, and nothing inside removes USDC from the adapter, so `received >=
    ///         reported` is structural". The containment is right; the second clause is not.
    ///         `MintAttemptReceiver.releaseMint` calls `farm.withdraw(stakedAmount)` FIRST and
    ///         forwards LAST, so the farm holds control inside the adapter's window and before the
    ///         child's, and `flushYieldTo` is permissionless and moves USDC out of the adapter. Two
    ///         of the five clamps have a reachable window on a mutable farm, not one, and this is
    ///         the one that sits on the ordinary borrower deposit rather than on a governance
    ///         recovery.
    ///
    ///         Same sign as its siblings: the clamp keeps `farmYieldDelivered` from crediting money
    ///         the adapter did not gain, and under-counting is the safe direction.
    function test_R43_releaseMintClampFiresWhenTheFarmDrainsMidWithdraw() public {
        // The adapter carries 100.000000 owed to a former recipient.
        farm.setPendingYield(address(adapter), 100e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(address(vault));
        adapter.claimYield();
        assertEq(adapter.unreportedYield(), 100e6, "premise: carried");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        assertEq(adapter.owedToRecipient(yieldSink), 100e6, "premise: parked at the adapter");
        usdc.setBlocked(yieldSink, false);

        // 250.000000 of farm yield lands on the child's own `farm.withdraw`, not on the auto-stake
        // hook, which is what puts it inside `releaseMint` rather than before it.
        bytes32 attemptId = keccak256("W");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setYieldAfterAutoDeposit(receiver, 250e6);
        ReentrantEmergencyFarm(address(farm)).armOnWithdraw(adapter, yieldSink);

        uint256 deliveredBefore = adapter.farmYieldDelivered();
        _deposit(alice, attemptId, 4304, 40);
        uint256 counted = adapter.farmYieldDelivered() - deliveredBefore;

        emit log_named_uint("MEASURED farm USDC the child reported forwarding", 250e6);
        emit log_named_uint("MEASURED counted by farmYieldDelivered", counted);
        emit log_named_uint("MEASURED flushed to the former recipient mid-withdraw", usdc.balanceOf(yieldSink));

        assertEq(vault.bondCount(alice), 40, "the deposit still succeeded");
        assertEq(usdc.balanceOf(yieldSink), 100e6, "the park was flushed inside the window");
        assertEq(counted, 150e6, "THE CLAMP FIRES: reported 250.000000 > received 150.000000");
        assertEq(usdc.balanceOf(newSink), 250e6, "every USDC left the adapter; only the count is short");
        assertLe(
            adapter.farmYieldDelivered(),
            usdc.balanceOf(newSink) + usdc.balanceOf(yieldSink),
            "IDENTITY HOLDS, under-counting"
        );
    }

    /// @notice Audit round 48, finding 82: the SEVENTH farm window, and the falsifier the row
    ///         said was owed before it could be changed. Round 46 (#407) put six windows behind
    ///         the saturating `_farmDelta` and left `_emergencyRecover`'s bare, so a farm that
    ///         drains MORE out of the adapter than the clone forwards back panicked `0x11` and
    ///         refused the emergency recovery outright.
    /// @dev    The two R43 tests above never reach this: both mint first, so the clone forwards
    ///         250.000000 against a 100.000000 drain and the delta stays positive. Here nothing is
    ///         minted. A pending share of one micro-USDC on the predicted receiver is enough for
    ///         `_prepareRecovery` to proceed and for `emergencyRecoverAll` to call
    ///         `farm.emergencyWithdraw()`, the clone forwards nothing, and the farm's re-entrant
    ///         `flushYieldTo` takes the whole 100.000000 park out of the adapter inside the window.
    ///         `received` is then `0 - 100e6`.
    ///
    ///         Why this window is saturated and `_recoverTo`'s is not, in one sentence each: the
    ///         emergency path has no recovery recipient, so the only party that can hold control
    ///         inside its window is DexFi's farm, which nobody can un-choose; `_recoverTo`'s window
    ///         is an owner-named recipient the owner can un-name, so a panic there is a correct
    ///         refusal. The round-34 refusal recorded on `_recoverTo` stands and does not reach here.
    ///
    ///         RED BEFORE the fix with panic 0x11 on this exact line; GREEN after
    ///         `received = _farmDelta(usdcBefore)`. The park is paid to the recipient it was parked
    ///         for, the watermark does not move, and the event reports what was measured: zero.
    function test_R48_emergencyRecoverySurvivesAFarmThatDrainsMoreThanTheCloneForwards() public {
        // 1. A pending share of 1 on the predicted receiver, and NO mint: the clone does not exist
        //    yet, will be deployed by `_prepareRecovery`, and will have nothing to forward.
        bytes32 attemptId = keccak256("E3");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setPendingYield(receiver, 1);
        assertEq(receiver.code.length, 0, "premise: no clone yet");

        // 2. 100.000000 parked at the adapter, owed to a former recipient - the same build as the
        //    R43 pair above, and it is the adapter's WHOLE balance.
        farm.setPendingYield(address(adapter), 100e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(address(vault));
        adapter.claimYield();
        assertEq(adapter.unreportedYield(), 100e6, "premise: carried");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        assertEq(adapter.owedToRecipient(yieldSink), 100e6, "premise: parked at the adapter");
        usdc.setBlocked(yieldSink, false);
        assertEq(usdc.balanceOf(address(adapter)), 100e6, "premise: the park is the whole balance");

        // 3. The farm drains the park from inside `emergencyWithdraw`, which the clone reaches
        //    because its pending share is non-zero.
        ReentrantEmergencyFarm(address(farm)).arm(adapter, yieldSink);
        uint256 deliveredBefore = adapter.farmYieldDelivered();

        vm.expectEmit(true, true, true, true, address(adapter));
        emit DirectCallAdapter.MintAttemptRecovered(
            alice, attemptId, receiver, address(0), 0, 0, 0, 0, 0, 0, true
        );
        vm.prank(admin);
        (uint256 bonds, uint256 swept, uint256 rawRemaining, uint256 nativeRemaining) =
            adapter.emergencyRecoverMintAttempt(alice, attemptId);

        emit log_named_uint("MEASURED drained out of the adapter inside the window", 100e6);
        emit log_named_uint("MEASURED forwarded by the clone", 0);
        emit log_named_uint("MEASURED swept", swept);

        assertEq(bonds, 0, "nothing was minted, so nothing sits at the clone");
        assertEq(swept, 0, "the drained window reports nothing, and nothing is invented");
        assertEq(rawRemaining, 0);
        assertEq(nativeRemaining, 0);
        assertEq(adapter.farmYieldDelivered(), deliveredBefore, "the watermark did not move");
        assertEq(usdc.balanceOf(yieldSink), 100e6, "the park was paid to the recipient it was parked for");
        assertEq(adapter.owedToRecipient(yieldSink), 0, "the park is discharged");
        assertEq(adapter.totalOwedToRecipients(), 0, "and not double counted");
        assertEq(usdc.balanceOf(address(adapter)), 0, "nothing stranded");
        assertEq(farm.pendingShare(receiver), 0, "the emergency exit forfeited the pending share");
    }

    /// @notice The drain-exceeds-inflow variant of `test_R43_releaseMintClampFiresWhenTheFarm
    ///         DrainsMidWithdraw`, executed rather than read: `_releaseFromReceiver` has sat
    ///         behind `_farmDelta` since #407, and this pins that the ordinary deposit survives
    ///         when the farm takes MORE out of the adapter than the child hands back, not only
    ///         when the delta stays positive.
    /// @dev    Same park, same arm, and a child forwarding 40.000000 against a 100.000000 drain.
    ///         The saturated delta is 0, `min(reported, 0)` is 0, and the 40.000000 the child
    ///         really forwarded is swept on to the live recipient by the stake that follows in the
    ///         same deposit - `_settleFarmPayout` sweeps the whole free balance - so no money is
    ///         lost and none of it is counted. MEASURED: the first draft of this test asserted the
    ///         40.000000 waited at the adapter, and it did not; it is the under-report
    ///         `_farmDelta`'s docstring accepts, in the direction it calls safe.
    function test_R48_releaseMintSurvivesAFarmThatDrainsMoreThanTheChildForwards() public {
        farm.setPendingYield(address(adapter), 100e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(address(vault));
        adapter.claimYield();
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        assertEq(adapter.owedToRecipient(yieldSink), 100e6, "premise: parked at the adapter");
        usdc.setBlocked(yieldSink, false);

        bytes32 attemptId = keccak256("W2");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setYieldAfterAutoDeposit(receiver, 40e6);
        ReentrantEmergencyFarm(address(farm)).armOnWithdraw(adapter, yieldSink);

        uint256 deliveredBefore = adapter.farmYieldDelivered();
        _deposit(alice, attemptId, 4305, 40);
        uint256 counted = adapter.farmYieldDelivered() - deliveredBefore;

        assertEq(vault.bondCount(alice), 40, "the deposit succeeded through a window drained past zero");
        assertEq(usdc.balanceOf(yieldSink), 100e6, "the park was flushed inside the window");
        assertEq(counted, 0, "MEASURED: a window drained past zero reports nothing at all");
        assertEq(usdc.balanceOf(address(adapter)), 0, "nothing stranded");
        assertEq(
            usdc.balanceOf(newSink),
            40e6,
            "the child's 40.000000 really arrived and was swept on by the stake that followed, uncounted"
        );
        assertLe(
            adapter.farmYieldDelivered(),
            usdc.balanceOf(newSink) + usdc.balanceOf(yieldSink),
            "IDENTITY HOLDS, under-counting"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The other side of the same window. The suite above establishes that the farm can
// reach the emergency clamp; this one establishes that the TOKEN cannot, which is what
// narrows the residual from "any of the three DexFi bindings" to "the farm".
// ─────────────────────────────────────────────────────────────────────────────
contract R34EmergencyTokenReentrancyTest is R34Base {
    address internal newSink = makeAddr("newSink");

    function _deployUsdc() internal override returns (MockUSDC) {
        return new ReentrantOnTransferUSDC();
    }

    /// @notice A token that drains the adapter during the child's own forward does NOT reach the
    ///         clamp: the child measures the same window, so its report falls by the same amount
    ///         and the two arms of the `min` are equal.
    /// @dev    This is the discriminator, and it is a measurement rather than an argument. Under
    ///         the round-43 neuter of `_emergencyRecover`'s clamp - `result.farmForwarded =
    ///         reportedFarm;` - the farm test above goes RED and this one stays GREEN, which is
    ///         what says the reachable window ends at `_tryTransferUsdc`'s first balance read.
    ///         `MintAttemptReceiver._tryTransferUsdc` returns the measured DELTA rather than the
    ///         amount asked for, and that is the line doing the work.
    function test_R43_aTokenDrainingItsOwnTransferWindowCannotReachTheClamp() public {
        bytes32 attemptId = keccak256("T");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        farm.setPendingYield(receiver, 250e6);
        usdc.setBlocked(address(adapter), true);
        _deposit(alice, attemptId, 4303, 40);
        usdc.setBlocked(address(adapter), false);
        assertEq(MintAttemptReceiver(payable(receiver)).parkedFarmYield(), 250e6, "premise: parked");

        farm.setPendingYield(address(adapter), 100e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(address(vault));
        adapter.claimYield();
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        assertEq(adapter.owedToRecipient(yieldSink), 100e6, "premise: parked at the adapter");
        usdc.setBlocked(yieldSink, false);

        farm.setPendingYield(receiver, 1);
        ReentrantOnTransferUSDC(address(usdc)).arm(adapter, yieldSink);

        uint256 deliveredBefore = adapter.farmYieldDelivered();
        vm.prank(admin);
        (, uint256 swept,,) = adapter.emergencyRecoverMintAttempt(alice, attemptId);
        uint256 counted = adapter.farmYieldDelivered() - deliveredBefore;

        emit log_named_uint("MEASURED counted by farmYieldDelivered", counted);
        emit log_named_uint("MEASURED flushed by the token mid-transfer", usdc.balanceOf(yieldSink));

        assertEq(usdc.balanceOf(yieldSink), 100e6, "the token really did drain the adapter");
        assertEq(counted, 150e6, "the CHILD already reported 150.000000; the clamp had nothing to do");
        assertEq(swept, 150e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Case C/D: the identity across a park, a flush, and an overlapping mint, with a
// well-behaved token. The running `farmOriginated` total below is the arithmetic every
// figure in this contract is checked against.
// ─────────────────────────────────────────────────────────────────────────────
contract R34IdentityLedgerTest is R34Base {
    /// @dev Total farm-originated USDC minted in this test, tracked by hand.
    uint256 internal farmOriginated;

    function _setPending(address who, uint256 amount) internal {
        farm.setPendingYield(who, amount);
        farmOriginated += amount;
    }

    function test_R34_parkAcrossTwoCallsThenFlushOverlappingWithAMint() public {
        // 1. Attempt A parks farm yield at its clone because the adapter cannot receive.
        bytes32 a = keccak256("A");
        address rcvA = adapter.predictMintReceiver(alice, a);
        _setPending(rcvA, 250e6);
        usdc.setBlocked(address(adapter), true);
        _deposit(alice, a, 1, 40);
        usdc.setBlocked(address(adapter), false);

        assertEq(MintAttemptReceiver(payable(rcvA)).parkedFarmYield(), 250e6, "parked at the clone");
        assertEq(adapter.farmYieldDelivered(), 0, "nothing counted yet");

        // 2. A second mint settles the adapter's own pool rewards while A is still parked.
        bytes32 b = keccak256("B");
        address rcvB = adapter.predictMintReceiver(alice, b);
        _setPending(address(adapter), 90e6);
        _deposit(alice, b, 2, 10);

        assertEq(adapter.farmYieldDelivered(), 90e6, "only the adapter's own settle is counted");
        assertEq(MintAttemptReceiver(payable(rcvA)).parkedFarmYield(), 250e6, "A's park is untouched");
        assertEq(MintAttemptReceiver(payable(rcvB)).parkedFarmYield(), 0);

        // 3. Flush A. Counted exactly once.
        uint256 swept = adapter.flushMintAttemptYield(alice, a);
        assertEq(swept, 250e6);
        assertEq(adapter.farmYieldDelivered(), 340e6);

        // 4. Flushing again moves and counts nothing.
        assertEq(adapter.flushMintAttemptYield(alice, a), 0, "no second count");
        assertEq(adapter.farmYieldDelivered(), 340e6);

        emit log_named_uint("MEASURED farm-originated USDC", farmOriginated);
        emit log_named_uint("MEASURED farmYieldDelivered", adapter.farmYieldDelivered());
        emit log_named_uint("MEASURED yieldSink balance", usdc.balanceOf(yieldSink));
        assertEq(usdc.balanceOf(yieldSink), farmOriginated, "every farm dollar reached the recipient");
        assertEq(adapter.farmYieldDelivered(), farmOriginated, "and each was counted exactly once");
    }

    /// @dev A donation to the adapter and to the counterfactual clone address, made by
    ///      a stranger who read `predictMintReceiver`, must move the recipient's
    ///      balance and not the counter.
    function test_R34_donationsMoveTheRecipientNotTheCounter() public {
        bytes32 a = keccak256("D");
        address rcv = adapter.predictMintReceiver(alice, a);
        usdc.mint(address(adapter), 40e6);
        usdc.mint(rcv, 15e6);
        _setPending(rcv, 60e6);

        _deposit(alice, a, 1, 40);

        emit log_named_uint("MEASURED farmYieldDelivered", adapter.farmYieldDelivered());
        emit log_named_uint("MEASURED yieldSink balance", usdc.balanceOf(yieldSink));
        emit log_named_uint("MEASURED clone residual USDC", usdc.balanceOf(rcv));
        assertEq(adapter.farmYieldDelivered(), 60e6, "only the farm delta");
        assertEq(usdc.balanceOf(yieldSink), 100e6, "the adapter donation rides along uncounted");
        assertEq(usdc.balanceOf(rcv), 15e6, "the clone donation is not swept as yield");
    }

    /// @notice A successful sweep inside `setYieldRecipient` counts what it delivers.
    /// @dev 🟥 **THIS TEST ASSERTED THE OPPOSITE UNTIL ROUND 50, AND THAT IS MOST OF WHY THE DEFECT
    ///      SURVIVED.** Its docstring read, in full: "A successful sweep inside `setYieldRecipient`
    ///      delivers real farm yield and never touches `farmYieldDelivered`. Under-count, by
    ///      design; recorded here as an exact figure because the report quotes it." Round 34
    ///      measured the behaviour exactly right and then wrote it down as DESIGN, and from that
    ///      moment the tree carried a green assertion saying the settlement funnel had a hole in
    ///      it. A measurement recorded as an intention is worse than no measurement, because the
    ///      next reader has to argue with a passing test.
    ///
    ///      Round-50 item 84 closed the hole: `setYieldRecipient` routes its claim through
    ///      `_settleFarmPayout`, like every other farm-touching path, so the second epoch is
    ///      delivered AND counted. `_settleFarmPayout`'s own comment already said it is "the one
    ///      funnel every farm-touching path goes through", so that "a NEW path cannot deliver farm
    ///      yield without also corroborating the epoch that pays it out" - and this was an OLD one
    ///      standing outside it.
    ///
    ///      **Only the last line moved.** The outgoing recipient still gets both epochs,
    ///      1,200.000000, and the counter now reads 1,200.000000 instead of 500.000000. This test
    ///      is the neuter of its own fix: restore the bare sweep and it goes red at
    ///      `1200000000 != 500000000` - which is how it was found, by the fix turning it red in a
    ///      suite the finding's own regression sweep had not listed.
    function test_R34_setYieldRecipientDeliversUncountedFarmYield() public {
        _setPending(address(adapter), 500e6);
        vm.prank(address(vault));
        adapter.claimYield();
        assertEq(adapter.farmYieldDelivered(), 500e6);

        // New farm yield sitting unclaimed. The repoint claims it, sweeps it to the outgoing
        // recipient, and since round-50 item 84 counts it on the way past.
        _setPending(address(adapter), 700e6);
        address newSink = makeAddr("newSink");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);

        emit log_named_uint("MEASURED yieldSink balance", usdc.balanceOf(yieldSink));
        emit log_named_uint("MEASURED farmYieldDelivered", adapter.farmYieldDelivered());
        assertEq(usdc.balanceOf(yieldSink), 1_200e6, "the outgoing recipient got both epochs");
        assertEq(adapter.farmYieldDelivered(), 1_200e6, "and the counter saw both of them");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Task 2 evidence. The clone-side farm-yield park is NOT reachable only through a
// DexFi-privileged state. `recoverAll` is its second producer, and a front-run mint
// is the unprivileged way to create the staked clone it recovers. No test in the
// tree combines a recovery-path park with the permissionless flush that clears it.
// ─────────────────────────────────────────────────────────────────────────────
contract R34RecoveryParkFlushTest is R34Base {
    address internal attacker = makeAddr("attacker");
    address internal recoveryRecipient = makeAddr("recoveryRecipient");

    function test_R34_frontRunRecoveryParksFarmYieldAndAPermissionlessFlushDeliversIt() public {
        bytes32 attemptId = keccak256("FR");
        address receiver = adapter.predictMintReceiver(alice, attemptId);

        // An unprivileged front-runner mints the victim's counterfactual payload. The
        // bond's auto-stake hook is the only route to a clone farm stake that does not
        // need a DexFi handler key, and it is open to anyone holding a keeper signature.
        vm.deal(attacker, PAYMENT);
        vm.prank(attacker);
        bond.mint{value: PAYMENT}(_input(4242, receiver, 40, PAYMENT));
        assertEq(farm.staked(receiver), 40, "the front-run staked the counterfactual clone");

        // That staked clone accrues ordinary MasterChef rewards while it waits.
        farm.setPendingYield(receiver, 123e6);

        // Governance recovers it in a window where USDC cannot reach the adapter.
        usdc.setBlocked(address(adapter), true);
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));
        usdc.setBlocked(address(adapter), false);

        assertEq(
            MintAttemptReceiver(payable(receiver)).parkedFarmYield(),
            123e6,
            "the park was created by the RECOVERY path, not by releaseMint"
        );
        assertEq(adapter.farmYieldDelivered(), 0, "nothing counted while it is parked");
        assertEq(bond.balanceOf(recoveryRecipient, 0), 40, "bonds went to the governance recipient");

        // A stranger clears it. This is the state `flushMintAttemptYield` exists for.
        vm.prank(makeAddr("stranger"));
        assertEq(adapter.flushMintAttemptYield(alice, attemptId), 123e6);
        assertEq(adapter.farmYieldDelivered(), 123e6, "counted exactly once, on delivery");
        assertEq(usdc.balanceOf(yieldSink), 123e6, "farm yield is protocol yield, not the donor's");
        assertEq(usdc.balanceOf(recoveryRecipient), 0, "and it is not paid to the recovery recipient");
    }
}
