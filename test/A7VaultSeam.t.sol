// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
import {MockCreditManager} from "./mocks/MockCreditManager.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Stands in for DexFi's bond treasury. The live bond contract forwards the signed
///         payment with a bare `call`, so whoever `treasury()` names gets control mid-mint.
contract ReenteringTreasury {
    address public target;
    bytes public payload;
    bool public fired;
    bool public nestedOk;
    bytes4 public nestedSelector;

    function arm(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
        fired = false;
    }

    receive() external payable {
        if (fired || target == address(0)) return;
        fired = true;
        (bool ok, bytes memory err) = target.call(payload);
        nestedOk = ok;
        if (!ok && err.length >= 4) nestedSelector = bytes4(err);
    }
}

/// @notice Minimal adapter that satisfies `setCustodyAdapter`'s two-of-eight probe and
///         returns zero from `mintBonds`. Exists only to reach `NothingMinted`.
contract ZeroMintAdapter is ICustodyAdapter {
    address private immutable _vault;

    constructor(address vault_) {
        _vault = vault_;
    }

    function vault() external view returns (address) {
        return _vault;
    }

    function stakedBalance() external pure returns (uint256) {
        return 0;
    }

    function farmYieldDelivered() external pure returns (uint256) {
        return 0;
    }

    function mintBonds(address, bytes32, bytes calldata) external payable returns (uint256) {
        return 0;
    }

    function stake(uint256) external pure returns (uint256) {
        return 0;
    }

    function unstake(uint256) external pure returns (uint256) {
        return 0;
    }

    function claimYield() external pure returns (uint256) {
        return 0;
    }

    function transferBonds(address, uint256) external {}
}

/// @notice Audit round 34, agent A7. Executable checks on the `depositETH` vault seam.
contract A7VaultSeamTest is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant PAYMENT = 1 ether;
    uint256 internal constant MINT_AMOUNT = 40;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    MockCreditManager internal credit;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    ReenteringTreasury internal treasury;

    event YieldHarvested(uint256 usdcAmount);
    event MintAttemptYieldFlushed(
        address indexed beneficiary,
        bytes32 indexed attemptId,
        address indexed receiver,
        uint256 corroborated,
        uint256 swept
    );

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        treasury = new ReenteringTreasury();
        bond.setTreasury(payable(address(treasury)));
        oracle = new MockNavOracle(NAV);
        credit = new MockCreditManager();
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
        credit.setVault(address(vault));
        credit.setRiskParams(address(riskParams));
        credit.setNavOracle(address(oracle));
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vm.stopPrank();
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
    }

    // -- Task 1: ordering -----------------------------------------------------

    /// @notice `_settlePosition` must see the OLD bond count, not the credited one.
    function test_a7_settleRunsAgainstTheOldBondCount() public {
        _deposit(alice, bytes32(uint256(1)), 101, MINT_AMOUNT, PAYMENT);
        assertEq(vault.bondCount(alice), MINT_AMOUNT, "credit landed");
        assertEq(credit.settleCalls(), 1, "settled exactly once");
        assertEq(credit.settledAtBonds(alice), 0, "first settle must price the OLD (zero) balance");

        _deposit(alice, bytes32(uint256(2)), 102, 25, PAYMENT);
        assertEq(vault.bondCount(alice), MINT_AMOUNT + 25, "second credit landed");
        assertEq(credit.settleCalls(), 2);
        assertEq(credit.settledAtBonds(alice), MINT_AMOUNT, "second settle prices the OLD balance");
    }

    // -- Task 1: the sweep window ---------------------------------------------

    /// @notice The vault's own `nonReentrant` does hold: a nested `depositETH` is refused.
    function test_a7_vaultNonReentrantRefusesANestedDepositETH() public {
        bytes32 attempt = bytes32(uint256(11));
        address receiver = adapter.predictMintReceiver(alice, attempt);
        treasury.arm(
            address(vault),
            abi.encodeCall(
                CollateralVault.depositETH,
                (bytes32(uint256(12)), _encoded(999, 0, receiver, 1, 0))
            )
        );
        _deposit(alice, attempt, 201, MINT_AMOUNT, PAYMENT);
        assertTrue(treasury.fired(), "the treasury callback must have run");
        assertFalse(treasury.nestedOk(), "the nested depositETH must be refused");
        assertEq(
            treasury.nestedSelector(),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "refused by the reentrancy guard"
        );
    }

    /// @notice The `farmYieldDelivered` delta is NOT confined to this call's sweep.
    ///         `DirectCallAdapter` has no reentrancy guard and `flushMintAttemptYield` is
    ///         permissionless, so a callback inside the mint moves the counter inside the
    ///         window the vault measures.
    function test_a7_theSweepDeltaPicksUpAnotherPathsSettlement() public {
        // 1. Park yield at a first clone by blocking the adapter's USDC.
        uint256 parked = 21e6;
        bytes32 first = bytes32(uint256(21));
        address firstReceiver = adapter.predictMintReceiver(alice, first);
        farm.setPendingYield(firstReceiver, parked);
        usdc.setBlocked(address(adapter), true);
        _deposit(alice, first, 301, MINT_AMOUNT, PAYMENT);
        usdc.setBlocked(address(adapter), false);
        assertEq(MintAttemptReceiver(payable(firstReceiver)).parkedFarmYield(), parked, "parked");
        assertEq(adapter.farmYieldDelivered(), 0, "nothing delivered yet");

        // 2. A second deposit whose own sweep is a different, known number.
        uint256 own = 5e6;
        bytes32 second = bytes32(uint256(22));
        address secondReceiver = adapter.predictMintReceiver(alice, second);
        farm.setPendingYield(secondReceiver, own);

        // 3. DexFi's treasury re-enters the ADAPTER (not the vault) during the mint.
        treasury.arm(
            address(adapter),
            abi.encodeCall(DirectCallAdapter.flushMintAttemptYield, (alice, first))
        );

        vm.recordLogs();
        _deposit(alice, second, 302, MINT_AMOUNT, PAYMENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(treasury.fired(), "callback ran");
        assertTrue(treasury.nestedOk(), "the adapter has no guard, so the nested flush SUCCEEDS");

        uint256 reportedByVault;
        uint256 flushes;
        uint256 reportedByFlush;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == YieldHarvested.selector) {
                reportedByVault = abi.decode(logs[i].data, (uint256));
            }
            if (
                logs[i].emitter == address(adapter)
                    && logs[i].topics[0] == MintAttemptYieldFlushed.selector
            ) {
                ++flushes;
                (, uint256 swept) = abi.decode(logs[i].data, (uint256, uint256));
                reportedByFlush = swept;
            }
        }
        assertEq(flushes, 1, "the nested flush emitted its own event");
        assertEq(reportedByFlush, parked, "the flush reported the parked money");
        assertEq(
            reportedByVault,
            own + parked,
            "the vault's YieldHarvested reports the other path's settlement too"
        );
        assertEq(adapter.farmYieldDelivered(), own + parked, "counter moved by both");
        assertEq(usdc.balanceOf(yieldSink), own + parked, "the money itself moved only once");
    }

    /// @notice Control for the test above: with no callback armed, the vault reports only
    ///         its own sweep and the parked money stays parked. The delta is confined
    ///         exactly as the docstring claims - right up until something re-enters.
    function test_a7_control_withoutReentrancyTheDeltaIsConfined() public {
        uint256 parked = 21e6;
        bytes32 first = bytes32(uint256(21));
        address firstReceiver = adapter.predictMintReceiver(alice, first);
        farm.setPendingYield(firstReceiver, parked);
        usdc.setBlocked(address(adapter), true);
        _deposit(alice, first, 301, MINT_AMOUNT, PAYMENT);
        usdc.setBlocked(address(adapter), false);

        uint256 own = 5e6;
        bytes32 second = bytes32(uint256(22));
        farm.setPendingYield(adapter.predictMintReceiver(alice, second), own);
        // Deliberately NOT armed.

        vm.recordLogs();
        _deposit(alice, second, 302, MINT_AMOUNT, PAYMENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(treasury.fired(), "no callback armed");
        uint256 reportedByVault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == YieldHarvested.selector) {
                reportedByVault = abi.decode(logs[i].data, (uint256));
            }
        }
        assertEq(reportedByVault, own, "confined to this call sweep");
        assertEq(MintAttemptReceiver(payable(firstReceiver)).parkedFarmYield(), parked, "still parked");
    }

    // -- Task 1: dead branches ------------------------------------------------

    /// @notice `ZeroAmount` is NOT dead. It is the only thing refusing a zero-payment mint;
    ///         the adapter alone would accept one.
    function test_a7_zeroValueIsRefusedByTheVaultAndAcceptedByTheAdapter() public {
        bytes32 attempt = bytes32(uint256(31));
        address receiver = adapter.predictMintReceiver(alice, attempt);
        bytes memory data = _encoded(401, 0, receiver, MINT_AMOUNT, 0);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.depositETH{value: 0}(attempt, data);

        // Same payload straight at the adapter, from the vault, with no ETH: it mints.
        vm.prank(address(vault));
        uint256 minted = adapter.mintBonds{value: 0}(alice, attempt, data);
        assertEq(minted, MINT_AMOUNT, "the adapter has no zero-payment guard of its own");
    }

    /// @notice `NothingMinted` is unreachable behind `DirectCallAdapter`: the adapter
    ///         refuses `amountNfts == 0` first, and returns that same field on success.
    function test_a7_nothingMintedIsUnreachableThroughTheShippedAdapter() public {
        bytes32 attempt = bytes32(uint256(41));
        address receiver = adapter.predictMintReceiver(alice, attempt);
        bytes memory data = _encoded(501, 0, receiver, 0, PAYMENT);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(DirectCallAdapter.ZeroMintAmount.selector);
        vault.depositETH{value: PAYMENT}(attempt, data);
    }

    /// @notice ...but it is reachable across the `ICustodyAdapter` seam, which is a settable
    ///         pointer. The guard is defensive against the interface, not dead code.
    function test_a7_nothingMintedIsReachableAcrossTheAdapterSeam() public {
        ZeroMintAdapter stub = new ZeroMintAdapter(address(vault));
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(stub)));
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(CollateralVault.NothingMinted.selector);
        vault.depositETH{value: PAYMENT}(bytes32(uint256(51)), "");
    }

    // -- Task 1: the pause asymmetry ------------------------------------------

    /// @notice The guardian may shut the ETH door and may not shut the bond door.
    function test_a7_guardianReachesTheEthDoorOnly() public {
        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);

        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert();
        vault.depositETH{value: PAYMENT}(bytes32(uint256(61)), "");

        // The cure stays open.
        assertFalse(vault.bondDepositsPaused(), "guardian cannot reach the third switch");
        vm.prank(guardian);
        vm.expectRevert();
        vault.setBondDepositsPaused(true);
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();
    }

    // -- Task 3: the local-path gas figure ------------------------------------

    function test_a7_measureLocalDepositEthGas() public {
        bytes32 attempt = bytes32(uint256(71));
        address receiver = adapter.predictMintReceiver(alice, attempt);
        bytes memory data = _encoded(601, 0, receiver, MINT_AMOUNT, PAYMENT);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        uint256 g0 = gasleft();
        vault.depositETH{value: PAYMENT}(attempt, data);
        emit log_named_uint("A7 MEASURED depositETH gas, mock path, first", g0 - gasleft());

        bytes32 attempt2 = bytes32(uint256(72));
        address receiver2 = adapter.predictMintReceiver(alice, attempt2);
        bytes memory data2 = _encoded(602, 0, receiver2, MINT_AMOUNT, PAYMENT);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        uint256 g1 = gasleft();
        vault.depositETH{value: PAYMENT}(attempt2, data2);
        emit log_named_uint("A7 MEASURED depositETH gas, mock path, second", g1 - gasleft());
    }

    // -- helpers --------------------------------------------------------------

    function _deposit(address who, bytes32 attemptId, uint256 uuid, uint256 amount, uint256 payment)
        internal
        returns (address receiver)
    {
        receiver = adapter.predictMintReceiver(who, attemptId);
        vm.deal(who, payment);
        vm.prank(who);
        vault.depositETH{value: payment}(attemptId, _encoded(uuid, 0, receiver, amount, payment));
    }

    function _encoded(uint256 uuid, uint256 nonce, address receiver, uint256 amount, uint256 payment)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            IDexFiBond.MintDataInput({
                uuid: uuid,
                nonce: nonce,
                receiver: receiver,
                amountNfts: amount,
                paymentAmount: payment,
                deadline: block.timestamp + 365 days,
                signature: ""
            })
        );
    }
}
