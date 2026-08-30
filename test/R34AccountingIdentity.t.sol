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

    function setUp() public virtual {
        usdc = _deployUsdc();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
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

    /// @dev A successful sweep inside `setYieldRecipient` delivers real farm yield and
    ///      never touches `farmYieldDelivered`. Under-count, by design; recorded here
    ///      as an exact figure because the report quotes it.
    function test_R34_setYieldRecipientDeliversUncountedFarmYield() public {
        _setPending(address(adapter), 500e6);
        vm.prank(address(vault));
        adapter.claimYield();
        assertEq(adapter.farmYieldDelivered(), 500e6);

        // New farm yield sitting unclaimed; the repoint claims and sweeps it to the
        // outgoing recipient without counting a cent of it.
        _setPending(address(adapter), 700e6);
        address newSink = makeAddr("newSink");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);

        emit log_named_uint("MEASURED yieldSink balance", usdc.balanceOf(yieldSink));
        emit log_named_uint("MEASURED farmYieldDelivered", adapter.farmYieldDelivered());
        assertEq(usdc.balanceOf(yieldSink), 1_200e6, "the outgoing recipient got both epochs");
        assertEq(adapter.farmYieldDelivered(), 500e6, "the counter saw only the first");
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
