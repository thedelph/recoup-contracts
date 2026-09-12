// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
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

/// @notice TEST-ONLY: a DexFi treasury that runs code when `bond.mint` pays it, i.e. INSIDE the
///         handoff (after the attempt clone is deployed and the bonds are minted to the farm for it,
///         before the adapter measures the mint, releases the clone and the vault credits).
/// @dev `MockBond.treasury` models DexFi's owner-settable treasury; on Base it is an EOA today. Every
///      action is wrapped so the treasury itself never reverts (a reverting treasury only refuses the
///      mint, which DexFi's key can always do).
contract R57A02HostileTreasury {
    enum Mode {
        None,
        BondsToReceiver,
        BondsToAdapter,
        EthToReceiver,
        UsdcToReceiver,
        ReenterVault,
        FlushSameAttempt
    }

    Mode public mode;
    MockBond public immutable bond;
    MockUSDC public immutable usdc;
    CollateralVault public immutable vault;
    DirectCallAdapter public immutable adapter;
    address public receiver;
    address public beneficiary;
    bytes32 public attemptId;
    bool public innerOk;
    bytes public innerRet;

    constructor(MockBond bond_, MockUSDC usdc_, CollateralVault vault_, DirectCallAdapter adapter_) {
        bond = bond_;
        usdc = usdc_;
        vault = vault_;
        adapter = adapter_;
    }

    function arm(Mode m, address receiver_, address beneficiary_, bytes32 attemptId_) external {
        mode = m;
        receiver = receiver_;
        beneficiary = beneficiary_;
        attemptId = attemptId_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        Mode m = mode;
        if (m == Mode.None) return;
        mode = Mode.None;
        if (m == Mode.BondsToReceiver) {
            bond.safeTransferFrom(address(this), receiver, 0, 7, "");
        } else if (m == Mode.BondsToAdapter) {
            bond.safeTransferFrom(address(this), address(adapter), 0, 7, "");
        } else if (m == Mode.EthToReceiver) {
            (innerOk,) = payable(receiver).call{value: 1 wei}("");
        } else if (m == Mode.UsdcToReceiver) {
            usdc.transfer(receiver, 9e6);
        } else if (m == Mode.ReenterVault) {
            (innerOk, innerRet) = address(vault).call(abi.encodeCall(CollateralVault.depositBonds, (1)));
        } else if (m == Mode.FlushSameAttempt) {
            (innerOk, innerRet) = address(adapter)
                .call(abi.encodeCall(DirectCallAdapter.flushMintAttemptYield, (beneficiary, attemptId)));
        }
    }
}

/// @title R57A02 - arrivals at a MintAttemptReceiver attempt address DURING the handoff
/// @notice Audit round 57, agent A2, target 4(b): round-56 A1's INFERRED lead, executed. The only
///         external code that gets control between `adapter.mintBonds`' clone deployment and the
///         vault's credit is DexFi's (the bond, its farm, its treasury) and the protocol's own; a
///         stranger holds no window (READ: `DirectCallAdapter._mintAndConsolidate`,
///         `MintAttemptReceiver.releaseMint`, `CollateralVault.depositETH`). So the adversary here is
///         DexFi's treasury running code mid-mint, the strongest party the window admits, and each
///         arrival is measured:
///         - bonds to the clone mid-mint: the whole deposit REVERTS `MintAmountMismatch` (fails closed);
///         - bonds to the adapter mid-mint: credited exactly the signed amount, the extras sit LOOSE and
///           uncredited, stake equals ledger;
///         - ETH to the clone mid-mint: the deposit succeeds and the wei sits at the clone;
///         - USDC to the clone mid-mint: counted as FARM YIELD - the recorded round-34 Low 1 exception,
///           executed here through the treasury leg rather than read;
///         - re-entering the vault mid-mint: refused by the vault's reentrancy guard;
///         - flushing the same attempt mid-mint: moves nothing.
///         The CREATE2 front-run (a stranger deploying at the attempt address) is covered by
///         `A6MintAttemptGrief.test_A6_strangerCannotDeployAtTheAttemptReceiver`; the pre-state
///         donations by `MintAttemptReceiverTest.test_rewardDeltasAndDonationsStayInSeparateAccountingDomains`.
contract R57A02_HandoffArrivals is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant MINT_AMOUNT = 40;
    uint256 internal constant PAYMENT = 1 ether;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    R57A02HostileTreasury internal treasury;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
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

        treasury = new R57A02HostileTreasury(bond, usdc, vault, adapter);
        bond.setTreasury(payable(address(treasury)));
        bond.setWhitelisted(address(treasury), true); // DexFi's own treasury is on DexFi's list
        bond.mint(address(treasury), 100);
        usdc.mint(address(treasury), 100e6);
        vm.deal(address(treasury), 1 ether);
    }

    function _mintData(bytes32 attemptId) internal view returns (bytes memory) {
        return abi.encode(
            IDexFiBond.MintDataInput({
                uuid: uint256(attemptId),
                nonce: 0,
                receiver: adapter.predictMintReceiver(alice, attemptId),
                amountNfts: MINT_AMOUNT,
                paymentAmount: PAYMENT,
                deadline: block.timestamp + 1 hours,
                signature: ""
            })
        );
    }

    function _deposit(bytes32 attemptId, R57A02HostileTreasury.Mode m) internal returns (bool ok, bytes memory ret) {
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        treasury.arm(m, receiver, alice, attemptId);
        bytes memory data = _mintData(attemptId);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        (ok, ret) = address(vault).call{value: PAYMENT}(abi.encodeCall(CollateralVault.depositETH, (attemptId, data)));
    }

    /// @notice CONTROL: an inert treasury, the ordinary mint. Credited 40, staked 40.
    function test_R57A02_handoff_control_anInertTreasuryMintsNormally() public {
        (bool ok,) = _deposit(keccak256("control"), R57A02HostileTreasury.Mode.None);
        assertTrue(ok, "control deposit failed");
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertEq(adapter.stakedBalance(), vault.totalBondCount(), "stake != ledger");
    }

    function test_R57A02_handoff_negative_bondsToTheCloneMidMintFailClosed() public {
        (bool ok, bytes memory ret) = _deposit(keccak256("a"), R57A02HostileTreasury.Mode.BondsToReceiver);
        assertFalse(ok, "a deposit with 7 bonds arriving at the clone mid-mint was accepted");
        assertEq(
            keccak256(ret),
            keccak256(
                abi.encodeWithSelector(DirectCallAdapter.MintAmountMismatch.selector, MINT_AMOUNT, MINT_AMOUNT + 7)
            ),
            "refused, but not by the adapter's mint measurement"
        );
        assertEq(vault.bondCount(alice), 0, "credited");
    }

    function test_R57A02_handoff_negative_bondsToTheAdapterMidMintStayUncredited() public {
        (bool ok,) = _deposit(keccak256("b"), R57A02HostileTreasury.Mode.BondsToAdapter);
        assertTrue(ok, "deposit failed");
        assertEq(vault.bondCount(alice), MINT_AMOUNT, "alice credited other than the signed amount");
        assertEq(bond.balanceOf(address(adapter), 0), 7, "the extras did not stay loose at the adapter");
        assertEq(adapter.stakedBalance(), vault.totalBondCount(), "the extras were staked or credited");
    }

    function test_R57A02_handoff_negative_ethToTheCloneMidMintSitsAtTheClone() public {
        bytes32 id = keccak256("c");
        address receiver = adapter.predictMintReceiver(alice, id);
        (bool ok,) = _deposit(id, R57A02HostileTreasury.Mode.EthToReceiver);
        assertTrue(ok, "deposit failed");
        assertTrue(treasury.innerOk(), "the clone refused the wei");
        assertEq(receiver.balance, 1, "the wei is not at the clone");
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
    }

    /// @notice MEASURED, and it is the round-34 Low 1 exception reached through the treasury leg:
    ///         USDC the treasury sends to the clone inside `bond.mint` is inside `autoDepositPaid`'s
    ///         window and is reported as farm yield. 9.000000 here. Needs DexFi's treasury key.
    function test_R57A02_handoff_measure_usdcToTheCloneMidMintIsCountedAsFarmYield() public {
        uint256 before = adapter.farmYieldDelivered();
        (bool ok,) = _deposit(keccak256("d"), R57A02HostileTreasury.Mode.UsdcToReceiver);
        assertTrue(ok, "deposit failed");
        uint256 counted = adapter.farmYieldDelivered() - before;
        emit log_named_uint("MEASURED farmYieldDelivered moved by a treasury USDC transfer mid-mint", counted);
        assertEq(counted, 9e6, "the treasury's USDC was not counted as farm yield");
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
    }

    function test_R57A02_handoff_negative_reenteringTheVaultMidMintIsRefused() public {
        (bool ok,) = _deposit(keccak256("e"), R57A02HostileTreasury.Mode.ReenterVault);
        assertTrue(ok, "deposit failed");
        assertFalse(treasury.innerOk(), "the vault accepted a re-entrant deposit mid-mint");
        assertEq(
            bytes4(treasury.innerRet()),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "refused for another reason"
        );
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertEq(vault.bondCount(address(treasury)), 0);
    }

    function test_R57A02_handoff_negative_flushingTheSameAttemptMidMintMovesNothing() public {
        uint256 before = usdc.balanceOf(yieldSink);
        (bool ok,) = _deposit(keccak256("f"), R57A02HostileTreasury.Mode.FlushSameAttempt);
        assertTrue(ok, "deposit failed");
        emit log_named_uint(
            "MEASURED mid-mint flush of the same attempt succeeded (1 = yes)", treasury.innerOk() ? 1 : 0
        );
        assertEq(usdc.balanceOf(yieldSink), before, "a mid-mint flush moved money");
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertEq(adapter.stakedBalance(), vault.totalBondCount(), "stake != ledger");
    }
}
