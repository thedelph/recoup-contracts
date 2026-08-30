// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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

/// @notice Round 34 / A4. A recovery recipient that actually re-enters the adapter
///         during MintAttemptReceiver._tryForwardNative. One mode per attempt.
contract ReentrantRecipient {
    enum Mode {
        NONE,
        FLUSH_MINT_ATTEMPT_YIELD,
        FLUSH_YIELD_TO,
        DONATE_BOND,
        DONATE_USDC,
        RECOVER_SAME_ATTEMPT
    }

    DirectCallAdapter public adapter;
    MockBond public bond;
    MockUSDC public usdc;
    Mode public mode;

    address public beneficiary;
    bytes32 public attemptId;
    address public parkedRecipient;
    uint256 public donation;

    bool public fired;
    bool public innerSucceeded;
    bytes public innerRevert;

    function arm(
        DirectCallAdapter adapter_,
        MockBond bond_,
        MockUSDC usdc_,
        Mode mode_,
        address beneficiary_,
        bytes32 attemptId_,
        address parkedRecipient_,
        uint256 donation_
    ) external {
        adapter = adapter_;
        bond = bond_;
        usdc = usdc_;
        mode = mode_;
        beneficiary = beneficiary_;
        attemptId = attemptId_;
        parkedRecipient = parkedRecipient_;
        donation = donation_;
    }

    receive() external payable {
        if (fired || mode == Mode.NONE) return;
        fired = true;
        if (mode == Mode.FLUSH_MINT_ATTEMPT_YIELD) {
            try adapter.flushMintAttemptYield(beneficiary, attemptId) {
                innerSucceeded = true;
            } catch (bytes memory err) {
                innerRevert = err;
            }
        } else if (mode == Mode.FLUSH_YIELD_TO) {
            try adapter.flushYieldTo(parkedRecipient) {
                innerSucceeded = true;
            } catch (bytes memory err) {
                innerRevert = err;
            }
        } else if (mode == Mode.DONATE_BOND) {
            bond.safeTransferFrom(address(this), address(adapter), 0, donation, "");
            innerSucceeded = true;
        } else if (mode == Mode.DONATE_USDC) {
            usdc.transfer(address(adapter), donation);
            innerSucceeded = true;
        } else if (mode == Mode.RECOVER_SAME_ATTEMPT) {
            try adapter.recoverMintAttempt(beneficiary, attemptId, payable(address(this))) {
                innerSucceeded = true;
            } catch (bytes memory err) {
                innerRevert = err;
            }
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

/// @notice A recipient that re-enters from the ERC-1155 ACCEPTANCE HOOK instead of the
///         native forward. That window sits inside `_recoverTo` itself, after the bond
///         equality check and before the USDC subtraction, and it opens even when the
///         clone holds no native balance at all.
contract ReentrantOnBondReceipt {
    DirectCallAdapter public adapter;
    address public parkedRecipient;
    bool public fired;
    bool public innerSucceeded;

    constructor(DirectCallAdapter adapter_, address parkedRecipient_) {
        adapter = adapter_;
        parkedRecipient = parkedRecipient_;
    }

    receive() external payable {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (!fired) {
            fired = true;
            try adapter.flushYieldTo(parkedRecipient) {
                innerSucceeded = true;
            } catch {}
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

/// @notice A farm whose pendingShare is a phantom: nonzero forever, pays nothing on
///         withdraw, never cleared. Models DexFi owner-only setUsersDebt rewriting
///         reward accounting for a zero-stake, nonce-0 address.
/// @dev Purpose-built rather than a MockFarm edit: MockFarm is a shared fixture and
///      its members are not virtual.
contract PhantomPendingFarm is IDexFiFarm {
    mapping(address => uint256) public phantom;
    uint256 public poolEndTime;

    constructor() {
        poolEndTime = block.timestamp + 365 days;
    }

    function setPhantom(address account, uint256 amount) external {
        phantom[account] = amount;
    }

    bool public revertOnWithdraw;

    function setRevertOnWithdraw(bool v) external {
        revertOnWithdraw = v;
    }

    function deposit(uint256) external {}

    function withdraw(uint256 amount) external view {
        require(!revertOnWithdraw, "phantom: reward math underflow");
        require(amount == 0, "phantom: nothing staked");
    }

    function emergencyWithdraw() external {}

    function depositForAccount(address, uint256) external {}

    function pendingShare(address account) external view returns (uint256) {
        return phantom[account];
    }

    function userInfo(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

contract R34RecoveryReentrancyTest is Test {
    uint256 internal constant NAV = 25.15e8;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");
    address internal treasury = makeAddr("treasury");
    address internal recoveryRecipient = makeAddr("recoveryRecipient");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function setUp() public {
        usdc = new MockUSDC();
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
            IDexFiBond(address(bond)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(farm)),
            usdc,
            address(vault),
            admin,
            yieldSink
        );
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
    }

    // -- Task 1 --------------------------------------------------------------

    /// A: re-enter the permissionless flushMintAttemptYield for the SAME attempt.
    function test_A_reenterFlushSameAttempt() public {
        ReentrantRecipient r = new ReentrantRecipient();
        bytes32 id = bytes32(uint256(0xA));
        address receiver = adapter.predictMintReceiver(alice, id);
        farm.setPendingYield(receiver, 30e6);
        vm.deal(receiver, 1 ether);
        r.arm(
            adapter,
            bond,
            usdc,
            ReentrantRecipient.Mode.FLUSH_MINT_ATTEMPT_YIELD,
            alice,
            id,
            address(0),
            0
        );

        vm.prank(admin);
        (uint256 bonds, uint256 swept,,, uint256 nativeFwd,) =
            adapter.recoverMintAttempt(alice, id, payable(address(r)));

        emit log_named_uint("A bonds", bonds);
        emit log_named_uint("A swept", swept);
        emit log_named_uint("A nativeForwarded", nativeFwd);
        emit log_named_uint("A yieldSink usdc", usdc.balanceOf(yieldSink));
        emit log_named_uint("A farmYieldDelivered", adapter.farmYieldDelivered());
        emit log_named_uint("A adapter usdc", usdc.balanceOf(address(adapter)));
        assertTrue(r.fired(), "recipient never re-entered");
        emit log_named_string("A inner succeeded", r.innerSucceeded() ? "yes" : "no");
        emit log_named_bytes("A inner revert", r.innerRevert());
    }

    /// B: re-enter flushMintAttemptYield for a DIFFERENT attempt carrying parked farm
    ///    yield. The inner settle sweeps the outer not-yet-measured farm USDC.
    function test_B_reenterFlushOtherAttemptUndercountsDeliveredYield() public {
        bytes32 idB = bytes32(uint256(0xB));
        address recvB = adapter.predictMintReceiver(alice, idB);
        uint256 P = 7e6;
        farm.setPendingYield(recvB, P);
        usdc.setBlocked(address(adapter), true);
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, idB, payable(recoveryRecipient));
        usdc.setBlocked(address(adapter), false);
        assertEq(MintAttemptReceiver(payable(recvB)).parkedFarmYield(), P, "B not parked");
        assertEq(adapter.farmYieldDelivered(), 0);

        bytes32 idA = bytes32(uint256(0xA1));
        address recvA = adapter.predictMintReceiver(alice, idA);
        uint256 F = 41e6;
        farm.setPendingYield(recvA, F);
        vm.deal(recvA, 1 ether);
        ReentrantRecipient r = new ReentrantRecipient();
        r.arm(
            adapter,
            bond,
            usdc,
            ReentrantRecipient.Mode.FLUSH_MINT_ATTEMPT_YIELD,
            alice,
            idB,
            address(0),
            0
        );

        vm.prank(admin);
        (, uint256 swept,,,,) = adapter.recoverMintAttempt(alice, idA, payable(address(r)));

        emit log_named_uint("B outer swept (reported)", swept);
        emit log_named_uint("B yieldSink usdc (actually delivered)", usdc.balanceOf(yieldSink));
        emit log_named_uint("B farmYieldDelivered (watermark)", adapter.farmYieldDelivered());
        emit log_named_uint("B adapter unreportedYield", adapter.unreportedYield());
        emit log_named_uint("B adapter usdc at rest", usdc.balanceOf(address(adapter)));
        assertTrue(r.fired());
    }

    /// B-control: identical, recipient inert, park flushed afterwards.
    function test_B_control_noReentrancy() public {
        bytes32 idB = bytes32(uint256(0xB));
        address recvB = adapter.predictMintReceiver(alice, idB);
        uint256 P = 7e6;
        farm.setPendingYield(recvB, P);
        usdc.setBlocked(address(adapter), true);
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, idB, payable(recoveryRecipient));
        usdc.setBlocked(address(adapter), false);

        bytes32 idA = bytes32(uint256(0xA1));
        address recvA = adapter.predictMintReceiver(alice, idA);
        uint256 F = 41e6;
        farm.setPendingYield(recvA, F);
        vm.deal(recvA, 1 ether);
        ReentrantRecipient r = new ReentrantRecipient();
        r.arm(adapter, bond, usdc, ReentrantRecipient.Mode.NONE, alice, idB, address(0), 0);

        vm.prank(admin);
        (, uint256 swept,,,,) = adapter.recoverMintAttempt(alice, idA, payable(address(r)));
        adapter.flushMintAttemptYield(alice, idB);

        emit log_named_uint("Bctl outer swept (reported)", swept);
        emit log_named_uint("Bctl yieldSink usdc (actually delivered)", usdc.balanceOf(yieldSink));
        emit log_named_uint("Bctl farmYieldDelivered (watermark)", adapter.farmYieldDelivered());
    }

    /// C: re-enter the permissionless flushYieldTo and drain the adapter parked
    ///    balance mid-call, below the _recoverTo pre-snapshot.
    function test_C_reenterFlushYieldToUnderflowsRecoverTo() public {
        uint256 K = 100e6;
        usdc.mint(address(adapter), K);
        usdc.setBlocked(yieldSink, true);
        address newSink = makeAddr("newSink");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        usdc.setBlocked(yieldSink, false);
        assertEq(adapter.owedToRecipient(yieldSink), K, "park not created");
        assertEq(usdc.balanceOf(address(adapter)), K);

        bytes32 id = bytes32(uint256(0xC));
        address receiver = adapter.predictMintReceiver(alice, id);
        farm.setPendingYield(receiver, 1e6);
        vm.deal(receiver, 1 ether);
        ReentrantRecipient r = new ReentrantRecipient();
        r.arm(adapter, bond, usdc, ReentrantRecipient.Mode.FLUSH_YIELD_TO, alice, id, yieldSink, 0);

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        adapter.recoverMintAttempt(alice, id, payable(address(r)));
    }

    /// C-control: same park, recipient inert.
    function test_C_control_parkDoesNotBlockRecovery() public {
        uint256 K = 100e6;
        usdc.mint(address(adapter), K);
        usdc.setBlocked(yieldSink, true);
        address newSink = makeAddr("newSink");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        usdc.setBlocked(yieldSink, false);

        bytes32 id = bytes32(uint256(0xC));
        address receiver = adapter.predictMintReceiver(alice, id);
        farm.setPendingYield(receiver, 1e6);
        vm.deal(receiver, 1 ether);
        ReentrantRecipient r = new ReentrantRecipient();
        r.arm(adapter, bond, usdc, ReentrantRecipient.Mode.NONE, alice, id, yieldSink, 0);

        vm.prank(admin);
        (, uint256 swept,,, uint256 nativeFwd,) =
            adapter.recoverMintAttempt(alice, id, payable(address(r)));
        emit log_named_uint("Cctl swept", swept);
        emit log_named_uint("Cctl nativeForwarded", nativeFwd);
        assertEq(adapter.owedToRecipient(yieldSink), K, "park survived");
    }

    /// D: move the adapter BOND balance between the two snapshots (donate 1 unit).
    function test_D_reenterDonateBondBlocksRecovery() public {
        bytes32 id = bytes32(uint256(0xD));
        address receiver = adapter.predictMintReceiver(alice, id);
        bond.mint(receiver, 5);
        vm.deal(receiver, 1 ether);

        ReentrantRecipient r = new ReentrantRecipient();
        bond.mint(address(r), 1);
        r.arm(adapter, bond, usdc, ReentrantRecipient.Mode.DONATE_BOND, alice, id, address(0), 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.MintAmountMismatch.selector, uint256(5), uint256(6)
            )
        );
        adapter.recoverMintAttempt(alice, id, payable(address(r)));
    }

    /// E: move the adapter USDC balance UP between the two snapshots.
    function test_E_reenterDonateUsdcCannotOverCredit() public {
        bytes32 id = bytes32(uint256(0xE));
        address receiver = adapter.predictMintReceiver(alice, id);
        uint256 F = 12e6;
        farm.setPendingYield(receiver, F);
        vm.deal(receiver, 1 ether);

        ReentrantRecipient r = new ReentrantRecipient();
        uint256 D = 500e6;
        usdc.mint(address(r), D);
        r.arm(adapter, bond, usdc, ReentrantRecipient.Mode.DONATE_USDC, alice, id, address(0), D);

        vm.prank(admin);
        (, uint256 swept,,,,) = adapter.recoverMintAttempt(alice, id, payable(address(r)));

        emit log_named_uint("E reported farm F", F);
        emit log_named_uint("E donation D", D);
        emit log_named_uint("E swept (reported)", swept);
        emit log_named_uint("E farmYieldDelivered", adapter.farmYieldDelivered());
        emit log_named_uint("E yieldSink usdc", usdc.balanceOf(yieldSink));
    }

    /// F: owner-chosen recipient IS the owner and re-enters recoverMintAttempt.
    function test_F_ownerRecipientReentersRecovery() public {
        ReentrantRecipient r = new ReentrantRecipient();
        DirectCallAdapter owned = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(farm)),
            usdc,
            address(vault),
            address(r),
            yieldSink
        );
        bond.setWhitelisted(address(owned), true);

        bytes32 id = bytes32(uint256(0xF));
        address receiver = owned.predictMintReceiver(alice, id);
        bond.mint(receiver, 4);
        usdc.mint(receiver, 3e6);
        vm.deal(receiver, 1 ether);
        usdc.setBlocked(address(r), true);
        r.arm(owned, bond, usdc, ReentrantRecipient.Mode.RECOVER_SAME_ATTEMPT, alice, id, address(0), 0);

        vm.recordLogs();
        vm.prank(address(r));
        (uint256 bonds,,, uint256 rawRemaining, uint256 nativeFwd,) =
            owned.recoverMintAttempt(alice, id, payable(address(r)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 recovered;
        bytes32 sig = keccak256(
            "MintAttemptRecovered(address,bytes32,address,address,uint256,uint256,uint256,uint256,uint256,uint256,bool)"
        );
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) ++recovered;
        }
        emit log_named_uint("F outer bonds", bonds);
        emit log_named_uint("F rawRemaining", rawRemaining);
        emit log_named_uint("F nativeForwarded", nativeFwd);
        emit log_named_uint("F MintAttemptRecovered events", recovered);
        emit log_named_uint("F bonds at recipient", bond.balanceOf(address(r), 0));
        emit log_named_string("F inner recover succeeded", r.innerSucceeded() ? "yes" : "no");
        emit log_named_bytes("F inner revert", r.innerRevert());
    }

    /// J: the SECOND window. Re-enter from the ERC-1155 acceptance hook, with the clone
    ///    holding no native balance at all, so `_tryForwardNative` never fires.
    function test_J_reenterFromBondAcceptanceHook() public {
        uint256 K = 100e6;
        usdc.mint(address(adapter), K);
        usdc.setBlocked(yieldSink, true);
        vm.prank(admin);
        adapter.setYieldRecipient(makeAddr("newSink"));
        usdc.setBlocked(yieldSink, false);
        assertEq(adapter.owedToRecipient(yieldSink), K, "park not created");

        bytes32 id = bytes32(uint256(0x1A));
        address receiver = adapter.predictMintReceiver(alice, id);
        bond.mint(receiver, 5);
        farm.setPendingYield(receiver, 1e6);
        assertEq(receiver.balance, 0, "clone must hold no native");

        ReentrantOnBondReceipt r = new ReentrantOnBondReceipt(adapter, yieldSink);
        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        adapter.recoverMintAttempt(alice, id, payable(address(r)));
    }

    /// J-control: identical, ordinary EOA recipient.
    function test_J_control_bondAcceptanceHookInert() public {
        uint256 K = 100e6;
        usdc.mint(address(adapter), K);
        usdc.setBlocked(yieldSink, true);
        vm.prank(admin);
        adapter.setYieldRecipient(makeAddr("newSink"));
        usdc.setBlocked(yieldSink, false);

        bytes32 id = bytes32(uint256(0x1A));
        address receiver = adapter.predictMintReceiver(alice, id);
        bond.mint(receiver, 5);
        farm.setPendingYield(receiver, 1e6);

        vm.prank(admin);
        (uint256 bonds, uint256 swept,,,,) =
            adapter.recoverMintAttempt(alice, id, payable(recoveryRecipient));
        emit log_named_uint("Jctl bonds", bonds);
        emit log_named_uint("Jctl swept", swept);
        assertEq(adapter.owedToRecipient(yieldSink), K, "park survived");
    }

    // -- Task 3 --------------------------------------------------------------

    /// G: the codehash arm of _requireMintReceiverCode, on both of its call sites.
    function test_G_foreignCodeAtPredictedAddressBricksFlushAndRecovery() public {
        bytes32 id = bytes32(uint256(0x6));
        address receiver = adapter.predictMintReceiver(alice, id);
        vm.etch(receiver, hex"60006000fd");
        bytes32 expected = keccak256(
            abi.encodePacked(
                hex"363d3d373d3d3d363d73",
                bytes20(address(adapter.mintReceiverImplementation())),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        emit log_named_bytes32("G actual codehash", receiver.codehash);
        emit log_named_bytes32("G expected codehash", expected);

        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.InvalidMintReceiverCode.selector,
                receiver,
                receiver.codehash,
                expected
            )
        );
        adapter.flushMintAttemptYield(alice, id);

        usdc.mint(receiver, 1e6);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.InvalidMintReceiverCode.selector,
                receiver,
                receiver.codehash,
                expected
            )
        );
        adapter.recoverMintAttempt(alice, id, payable(recoveryRecipient));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.InvalidMintReceiverCode.selector,
                receiver,
                receiver.codehash,
                expected
            )
        );
        adapter.emergencyRecoverMintAttempt(alice, id);
    }

    /// H: MintAttemptRecovered.bonds means two different things.
    function test_H_bondsFieldMeansTwoThings() public {
        bytes32 sig = keccak256(
            "MintAttemptRecovered(address,bytes32,address,address,uint256,uint256,uint256,uint256,uint256,uint256,bool)"
        );

        bytes32 idN = bytes32(uint256(0x11));
        address recvN = adapter.predictMintReceiver(alice, idN);
        bond.mint(recvN, 9);
        vm.recordLogs();
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, idN, payable(recoveryRecipient));
        (uint256 bondsN, bool emergencyN) = _decodeBonds(vm.getRecordedLogs(), sig);
        emit log_named_uint("H normal event bonds", bondsN);
        emit log_named_string("H normal emergency flag", emergencyN ? "true" : "false");
        emit log_named_uint("H normal bonds at clone", bond.balanceOf(recvN, 0));
        emit log_named_uint("H normal bonds at recipient", bond.balanceOf(recoveryRecipient, 0));

        bytes32 idE = bytes32(uint256(0x12));
        address recvE = adapter.predictMintReceiver(alice, idE);
        bond.mint(recvE, 9);
        vm.recordLogs();
        vm.prank(admin);
        adapter.emergencyRecoverMintAttempt(alice, idE);
        (uint256 bondsE, bool emergencyE) = _decodeBonds(vm.getRecordedLogs(), sig);
        emit log_named_uint("H emergency event bonds", bondsE);
        emit log_named_string("H emergency emergency flag", emergencyE ? "true" : "false");
        emit log_named_uint("H emergency bonds at clone", bond.balanceOf(recvE, 0));
        emit log_named_uint("H emergency bonds at adapter", bond.balanceOf(address(adapter), 0));
    }

    function _decodeBonds(Vm.Log[] memory logs, bytes32 sig)
        internal
        pure
        returns (uint256 bonds, bool emergency)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != sig) continue;
            (, bonds,,,,,, emergency) = abi.decode(
                logs[i].data,
                (address, uint256, uint256, uint256, uint256, uint256, uint256, bool)
            );
        }
    }

    /// I: a phantom pendingShare on a zero-stake, nonce-0 address.
    function test_I_phantomPendingShareBurnsTheAttemptId() public {
        PhantomPendingFarm phantom = new PhantomPendingFarm();
        DirectCallAdapter ad = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(phantom)),
            usdc,
            address(vault),
            admin,
            yieldSink
        );
        bond.setWhitelisted(address(ad), true);

        bytes32 id = bytes32(uint256(0x99));
        address receiver = ad.predictMintReceiver(alice, id);
        assertEq(receiver.code.length, 0, "clone pre-exists");
        assertEq(bond.nonces(receiver), 0, "nonce touched");
        phantom.setPhantom(receiver, 123e6);

        vm.prank(admin);
        (uint256 bonds, uint256 swept, uint256 rawF, uint256 rawR, uint256 natF, uint256 natR) =
            ad.recoverMintAttempt(alice, id, payable(recoveryRecipient));
        emit log_named_uint("I bonds", bonds);
        emit log_named_uint("I swept", swept);
        emit log_named_uint("I rawFwd", rawF);
        emit log_named_uint("I rawRem", rawR);
        emit log_named_uint("I natFwd", natF);
        emit log_named_uint("I natRem", natR);
        emit log_named_uint("I clone code length", receiver.code.length);
        emit log_named_uint("I farmYieldDelivered", ad.farmYieldDelivered());

        vm.prank(admin);
        ad.recoverMintAttempt(alice, id, payable(recoveryRecipient));
        emit log_named_uint("I phantom still", phantom.pendingShare(receiver));

        vm.prank(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.MintAttemptAlreadyDeployed.selector, receiver
            )
        );
        // (mintBonds call follows)
        ad.mintBonds(
            alice,
            id,
            abi.encode(
                IDexFiBond.MintDataInput({
                    uuid: 7777,
                    nonce: 0,
                    receiver: receiver,
                    amountNfts: 1,
                    paymentAmount: 0,
                    deadline: block.timestamp + 1 days,
                    signature: ""
                })
            )
        );
    }

    /// I2: the sharper phantom - `pendingShare != 0` AND `withdraw` reverts, which is
    ///     the shape a rewritten `userDebt` produces in MasterChef reward math.
    function test_I2_phantomWithRevertingWithdrawBricksNormalRecovery() public {
        PhantomPendingFarm phantom = new PhantomPendingFarm();
        DirectCallAdapter ad = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(phantom)),
            usdc,
            address(vault),
            admin,
            yieldSink
        );
        bond.setWhitelisted(address(ad), true);

        bytes32 id = bytes32(uint256(0xAA));
        address receiver = ad.predictMintReceiver(alice, id);
        phantom.setPhantom(receiver, 55e6);
        phantom.setRevertOnWithdraw(true);

        vm.prank(admin);
        vm.expectRevert(bytes("phantom: reward math underflow"));
        ad.recoverMintAttempt(alice, id, payable(recoveryRecipient));
        assertEq(receiver.code.length, 0, "clone deploy rolled back with the revert");

        vm.prank(admin);
        (uint256 bonds,,,) = ad.emergencyRecoverMintAttempt(alice, id);
        emit log_named_uint("I2 emergency bonds", bonds);
        emit log_named_uint("I2 clone code length after emergency", receiver.code.length);
        emit log_named_uint("I2 phantom still", phantom.pendingShare(receiver));
    }
}
