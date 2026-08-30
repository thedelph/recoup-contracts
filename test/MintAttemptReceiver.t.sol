// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

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

contract RejectNativeRecovery {
    receive() external payable {
        revert("native refused");
    }
}

/// @notice Adversarial coverage for the fresh CREATE2 receiver used by one signed
///         DexFi mint attempt. The suite keeps user credit, canonical farm custody,
///         farm-yield corroboration and donation recovery as separate quantities.
contract MintAttemptReceiverTest is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant PAYMENT = 1 ether;
    uint256 internal constant MINT_AMOUNT = 40;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal recoveryRecipient = makeAddr("recoveryRecipient");
    address internal yieldSink = makeAddr("yieldSink");
    address internal treasury = makeAddr("treasury");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    struct DonationCase {
        bytes32 attemptId;
        address receiver;
        uint256 childAutoDepositYield;
        uint256 childWithdrawYield;
        uint256 adapterRestakeYield;
        uint256 adapterUsdcDonation;
        uint256 childUsdcDonation;
        uint256 childBondDonation;
        uint256 childStakedDonation;
        uint256 adapterLooseDonation;
        uint256 adapterStakedDonation;
        uint256 childNativeDonation;
        uint256 adapterNativeDonation;
    }

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

        // The farm is already on DexFi's list; the adapter is the one Recoup ask.
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
    }

    function test_mockBondModelsGlobalUuidPerReceiverNonceDeadlineAndMinimumPayment() public {
        vm.warp(2 days);
        IDexFiBond.MintDataInput memory expired =
            _input(1001, 0, alice, 1, PAYMENT, block.timestamp - 1);
        vm.deal(attacker, PAYMENT);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MockBond.DeadlineExpired.selector, expired.deadline));
        bond.mint{value: PAYMENT}(expired);
        assertFalse(bond.uuidUsed(expired.uuid));

        IDexFiBond.MintDataInput memory first = _input(1002, 0, alice, 1, PAYMENT);
        vm.deal(attacker, PAYMENT + 1);
        vm.prank(attacker);
        bond.mint{value: PAYMENT + 1}(first);
        assertTrue(bond.uuidUsed(first.uuid));
        assertEq(bond.nonces(alice), 1);
        assertEq(treasury.balance, PAYMENT, "only the signed payment reaches treasury");
        assertEq(address(bond).balance, 1, "the live >= trap retains the overpayment");

        IDexFiBond.MintDataInput memory reusedUuid = _input(1002, 0, bob, 1, PAYMENT);
        vm.deal(attacker, PAYMENT);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MockBond.UUIDAlreadyExist.selector, first.uuid));
        bond.mint{value: PAYMENT}(reusedUuid);

        IDexFiBond.MintDataInput memory staleNonce = _input(1003, 0, alice, 1, PAYMENT);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(MockBond.InvalidNonce.selector, alice, uint256(1), uint256(0))
        );
        bond.mint{value: PAYMENT}(staleNonce);
        assertFalse(bond.uuidUsed(staleNonce.uuid));
    }

    function test_sameAttemptIdIsBeneficiaryBoundAndBothReceiversConsumeNonceZero() public {
        bytes32 attemptId = bytes32(uint256(1));
        address aliceReceiver = adapter.predictMintReceiver(alice, attemptId);
        address bobReceiver = adapter.predictMintReceiver(bob, attemptId);

        assertEq(adapter.predictMintReceiver(alice, attemptId), aliceReceiver, "prediction drifted");
        assertTrue(aliceReceiver != bobReceiver, "beneficiaries shared a nonce domain");
        assertEq(aliceReceiver.code.length, 0);
        assertEq(bobReceiver.code.length, 0);

        _deposit(alice, attemptId, 1101, MINT_AMOUNT, PAYMENT);
        _deposit(bob, attemptId, 1102, MINT_AMOUNT + 1, PAYMENT);

        assertEq(bond.nonces(aliceReceiver), 1);
        assertEq(bond.nonces(bobReceiver), 1);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertEq(vault.bondCount(bob), MINT_AMOUNT + 1);
        assertEq(farm.staked(address(adapter)), MINT_AMOUNT * 2 + 1);
    }

    function test_rewardPoolUnsetFallsBackToLooseMintAndStillConsolidatesExactly() public {
        bytes32 attemptId = bytes32(uint256(18));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        bond.setRewardPool(address(0));

        _deposit(alice, attemptId, 1151, MINT_AMOUNT, PAYMENT);

        assertEq(receiver.code.length, 45, "attempt receiver was not the expected clone");
        assertEq(bond.nonces(receiver), 1);
        assertEq(bond.balanceOf(receiver, 0), 0, "loose mint remained at the receiver");
        assertEq(bond.balanceOf(address(adapter), 0), 0, "loose mint remained at the adapter");
        assertEq(farm.staked(receiver), 0);
        assertEq(farm.staked(address(adapter)), MINT_AMOUNT);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertEq(vault.totalBondCount(), MINT_AMOUNT);
        assertEq(treasury.balance, PAYMENT);
    }

    function test_zeroAttemptIdAndSuccessfulAttemptReuseAreRejected() public {
        vm.expectRevert(DirectCallAdapter.InvalidAttemptId.selector);
        adapter.predictMintReceiver(alice, bytes32(0));

        bytes memory arbitrary = _encoded(1161, 0, alice, MINT_AMOUNT, PAYMENT);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(DirectCallAdapter.InvalidAttemptId.selector);
        vault.depositETH{value: PAYMENT}(bytes32(0), arbitrary);
        assertEq(alice.balance, PAYMENT, "zero-id rejection retained ETH");

        bytes32 attemptId = bytes32(uint256(19));
        address receiver = _deposit(alice, attemptId, 1162, MINT_AMOUNT, PAYMENT);
        uint256 supplyAfterFirst = bond.totalSupply(0);
        uint256 treasuryAfterFirst = treasury.balance;

        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, uint256(1)
            )
        );
        vault.depositETH{value: PAYMENT}(
            attemptId, _encoded(1163, 0, receiver, MINT_AMOUNT, PAYMENT)
        );

        assertEq(alice.balance, PAYMENT, "reused-attempt rejection retained ETH");
        assertEq(bond.totalSupply(0), supplyAfterFirst);
        assertEq(treasury.balance, treasuryAfterFirst);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertFalse(bond.uuidUsed(1163));
    }

    function test_reusedUuidAndExpiredPayloadRollBackFreshVaultAttempts() public {
        bytes32 firstAttempt = bytes32(uint256(20));
        uint256 reusedUuid = 1171;
        _deposit(alice, firstAttempt, reusedUuid, MINT_AMOUNT, PAYMENT);
        uint256 supplyBaseline = bond.totalSupply(0);
        uint256 stakeBaseline = farm.staked(address(adapter));
        uint256 treasuryBaseline = treasury.balance;

        bytes32 reusedAttempt = bytes32(uint256(21));
        address reusedReceiver = adapter.predictMintReceiver(alice, reusedAttempt);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockBond.UUIDAlreadyExist.selector, reusedUuid));
        vault.depositETH{value: PAYMENT}(
            reusedAttempt, _encoded(reusedUuid, 0, reusedReceiver, MINT_AMOUNT, PAYMENT)
        );
        assertEq(reusedReceiver.code.length, 0);
        assertEq(bond.nonces(reusedReceiver), 0);
        assertEq(alice.balance, PAYMENT);

        bytes32 expiredAttempt = bytes32(uint256(22));
        uint256 expiredUuid = 1172;
        address expiredReceiver = adapter.predictMintReceiver(alice, expiredAttempt);
        uint256 expiredDeadline = block.timestamp - 1;
        bytes memory expiredData = abi.encode(
            _input(expiredUuid, 0, expiredReceiver, MINT_AMOUNT, PAYMENT, expiredDeadline)
        );
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MockBond.DeadlineExpired.selector, expiredDeadline)
        );
        vault.depositETH{value: PAYMENT}(expiredAttempt, expiredData);

        assertEq(expiredReceiver.code.length, 0);
        assertEq(bond.nonces(expiredReceiver), 0);
        assertFalse(bond.uuidUsed(expiredUuid));
        assertEq(alice.balance, PAYMENT);
        assertEq(bond.totalSupply(0), supplyBaseline);
        assertEq(farm.staked(address(adapter)), stakeBaseline);
        assertEq(treasury.balance, treasuryBaseline);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertEq(vault.totalBondCount(), MINT_AMOUNT);
    }

    function test_copiedPayloadCannotRedirectCreditAndDoesNotConsumeTheVictimAttempt() public {
        bytes32 attemptId = bytes32(uint256(2));
        address victimReceiver = adapter.predictMintReceiver(alice, attemptId);
        address attackerReceiver = adapter.predictMintReceiver(attacker, attemptId);
        bytes memory mintData = _encoded(1201, 0, victimReceiver, MINT_AMOUNT, PAYMENT);

        vm.deal(attacker, PAYMENT);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.MintReceiverMismatch.selector, attackerReceiver, victimReceiver
            )
        );
        vault.depositETH{value: PAYMENT}(attemptId, mintData);

        assertEq(attackerReceiver.code.length, 0);
        assertFalse(bond.uuidUsed(1201));
        _callDeposit(alice, attemptId, mintData, PAYMENT);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
        assertEq(vault.bondCount(attacker), 0);
    }

    function test_nonzeroNonceAndZeroMintAreRejectedBeforeDeploymentOrPayment() public {
        bytes32 attemptId = bytes32(uint256(3));
        address receiver = adapter.predictMintReceiver(alice, attemptId);

        bytes memory nonzeroNonce = _encoded(1301, 1, receiver, MINT_AMOUNT, PAYMENT);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintNonceMustBeZero.selector, uint256(1))
        );
        vault.depositETH{value: PAYMENT}(attemptId, nonzeroNonce);

        bytes memory zeroAmount = _encoded(1302, 0, receiver, 0, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(DirectCallAdapter.ZeroMintAmount.selector);
        vault.depositETH{value: PAYMENT}(attemptId, zeroAmount);

        assertEq(receiver.code.length, 0);
        assertEq(bond.nonces(receiver), 0);
        assertFalse(bond.uuidUsed(1301));
        assertFalse(bond.uuidUsed(1302));
        assertEq(treasury.balance, 0);
    }

    function test_adapterPreservesExactEthEvenThoughUpstreamAcceptsOverpayment() public {
        bytes32 attemptId = bytes32(uint256(4));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        bytes memory mintData = _encoded(1401, 0, receiver, MINT_AMOUNT, PAYMENT);

        vm.deal(alice, PAYMENT + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.PaymentMismatch.selector, PAYMENT, PAYMENT + 1
            )
        );
        vault.depositETH{value: PAYMENT + 1}(attemptId, mintData);

        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.PaymentMismatch.selector, PAYMENT, PAYMENT / 2)
        );
        vault.depositETH{value: PAYMENT / 2}(attemptId, mintData);

        assertEq(receiver.code.length, 0);
        assertFalse(bond.uuidUsed(1401));
        assertEq(treasury.balance, 0);
        _callDeposit(alice, attemptId, mintData, PAYMENT);
        assertEq(treasury.balance, PAYMENT);
        assertEq(address(bond).balance, 0, "adapter let no excess reach the bond");
    }

    function test_whitelistPreflightAndPostMintFarmFailureAreAtomicAndRetryable() public {
        bytes32 attemptId = bytes32(uint256(5));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        bytes memory mintData = _encoded(1501, 0, receiver, MINT_AMOUNT, PAYMENT);

        bond.setWhitelisted(address(adapter), false);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(DirectCallAdapter.AdapterNotWhitelisted.selector);
        vault.depositETH{value: PAYMENT}(attemptId, mintData);
        _assertUnusedAttempt(receiver, 1501);

        bond.setWhitelisted(address(adapter), true);
        farm.setRevertOnWithdraw(true);
        vm.prank(alice);
        vm.expectRevert(MockFarm.FarmDown.selector);
        vault.depositETH{value: PAYMENT}(attemptId, mintData);
        _assertUnusedAttempt(receiver, 1501);
        assertEq(treasury.balance, 0, "upstream payment survived a downstream revert");

        farm.setRevertOnWithdraw(false);
        vm.prank(alice);
        vault.depositETH{value: PAYMENT}(attemptId, mintData);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
    }

    function test_revocationDuringMintRollsBackEveryDeltaAndLeavesTheAttemptRetryable() public {
        bytes32 attemptId = bytes32(uint256(17));
        uint256 uuid = 1551;
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        bytes memory mintData = _encoded(uuid, 0, receiver, MINT_AMOUNT, PAYMENT);
        uint256 supplyBefore = bond.totalSupply(0);

        bond.setRevokeDuringMint(address(adapter));
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockBond.AddressesNotWhitelisted.selector, receiver, receiver, address(adapter)
            )
        );
        vault.depositETH{value: PAYMENT}(attemptId, mintData);

        assertTrue(bond.whitelistContains(address(adapter)), "revocation did not roll back");
        assertEq(receiver.code.length, 0, "clone deployment survived the revert");
        assertEq(bond.nonces(receiver), 0, "receiver nonce survived the revert");
        assertFalse(bond.uuidUsed(uuid), "UUID survived the revert");
        assertEq(bond.totalSupply(0), supplyBefore, "minted supply survived the revert");
        assertEq(treasury.balance, 0, "treasury payment survived the revert");
        assertEq(address(bond).balance, 0, "ETH remained at the upstream bond");
        assertEq(address(adapter).balance, 0, "ETH remained at the adapter");
        assertEq(address(vault).balance, 0, "ETH remained at the vault");
        assertEq(alice.balance, PAYMENT, "payer was not refunded atomically");
        assertEq(farm.staked(receiver), 0, "receiver stake survived the revert");
        assertEq(farm.staked(address(adapter)), 0, "adapter stake survived the revert");
        assertEq(bond.balanceOf(receiver, 0), 0, "receiver bonds survived the revert");
        assertEq(bond.balanceOf(address(adapter), 0), 0, "adapter bonds survived the revert");
        assertEq(vault.bondCount(alice), 0, "vault credit survived the revert");
        assertEq(vault.totalBondCount(), 0, "vault total survived the revert");

        bond.setRevokeDuringMint(address(0));
        vm.prank(alice);
        vault.depositETH{value: PAYMENT}(attemptId, mintData);
        assertEq(vault.bondCount(alice), MINT_AMOUNT, "rolled-back attempt was not retryable");
    }

    function test_rewardDeltasAndDonationsStayInSeparateAccountingDomains() public {
        DonationCase memory c;
        c.attemptId = bytes32(uint256(6));
        c.receiver = adapter.predictMintReceiver(alice, c.attemptId);
        c.childAutoDepositYield = 11e6;
        c.childWithdrawYield = 12e6;
        c.adapterRestakeYield = 13e6;
        c.adapterUsdcDonation = 17e6;
        c.childUsdcDonation = 7e6;
        c.childBondDonation = 3;
        c.childStakedDonation = 2;
        c.adapterLooseDonation = 5;
        c.adapterStakedDonation = 6;
        c.childNativeDonation = 9 wei;
        c.adapterNativeDonation = 10 wei;

        bond.mint(c.receiver, c.childBondDonation);
        // The staked donation is installed directly rather than deposited by the receiver.
        // Nothing may originate a transaction from a counterfactual CREATE2 address: under
        // forge 1.8.x `vm.prank` increments the pranked account's nonce, and CREATE2 into a
        // non-zero-nonce account fails EIP-684 with `FailedDeployment()`. That is a harness
        // artefact, not a vector - a nonce is not a donation, and an attacker holds no key for
        // a predicted address. The donation this test is about is unchanged: the pool really
        // holds the bonds, and the credited stake is identical to what a deposit would leave.
        bond.mint(address(farm), c.childStakedDonation);
        farm.seedStakeFor(c.receiver, c.childStakedDonation);
        bond.mint(address(adapter), c.adapterLooseDonation + c.adapterStakedDonation);
        vm.prank(address(adapter));
        farm.deposit(c.adapterStakedDonation);
        usdc.mint(c.receiver, c.childUsdcDonation);
        usdc.mint(address(adapter), c.adapterUsdcDonation);
        vm.deal(c.receiver, c.childNativeDonation);
        vm.deal(address(adapter), c.adapterNativeDonation);
        farm.setPendingYield(c.receiver, c.childAutoDepositYield);
        farm.setYieldAfterAutoDeposit(c.receiver, c.childWithdrawYield);
        farm.setPendingYield(address(adapter), c.adapterRestakeYield);

        vm.recordLogs();
        _deposit(alice, c.attemptId, 1601, MINT_AMOUNT, PAYMENT);
        (uint256 eventCount, uint256 reportedYield) = _yieldHarvested();

        uint256 realFarmYield =
            c.childAutoDepositYield + c.childWithdrawYield + c.adapterRestakeYield;
        assertEq(vault.bondCount(alice), MINT_AMOUNT, "a loose donation was credited");
        assertEq(vault.totalBondCount(), MINT_AMOUNT);
        assertEq(farm.staked(address(adapter)), c.adapterStakedDonation + MINT_AMOUNT);
        assertEq(farm.staked(c.receiver), c.childStakedDonation, "baseline child stake was absorbed");
        assertEq(bond.balanceOf(c.receiver, 0), c.childBondDonation, "baseline bond was absorbed");
        assertEq(
            bond.balanceOf(address(adapter), 0), c.adapterLooseDonation, "adapter donation was staked"
        );
        assertEq(usdc.balanceOf(c.receiver), c.childUsdcDonation, "raw child USDC was called yield");
        assertEq(c.receiver.balance, c.childNativeDonation, "native prefunding blocked clone deployment");
        assertEq(address(adapter).balance, c.adapterNativeDonation, "adapter native donation moved");
        assertEq(adapter.farmYieldDelivered(), realFarmYield);
        assertEq(usdc.balanceOf(yieldSink), c.adapterUsdcDonation + realFarmYield);
        assertEq(eventCount, 1);
        assertEq(reportedYield, realFarmYield);

        _assertDonationRecovery(c, realFarmYield);
    }

    function test_revertingAndFalseChildUsdcTransfersDoNotBrickMintAndFlushExactlyOnce() public {
        uint256 firstYield = 21e6;
        bytes32 firstAttempt = bytes32(uint256(7));
        address firstReceiver = adapter.predictMintReceiver(alice, firstAttempt);
        farm.setPendingYield(firstReceiver, firstYield);
        usdc.setBlocked(address(adapter), true);

        _deposit(alice, firstAttempt, 1701, MINT_AMOUNT, PAYMENT);
        assertEq(vault.bondCount(alice), MINT_AMOUNT, "blocked USDC bricked collateral credit");
        assertEq(farm.staked(address(adapter)), MINT_AMOUNT);
        assertEq(MintAttemptReceiver(payable(firstReceiver)).parkedFarmYield(), firstYield);
        assertEq(usdc.balanceOf(firstReceiver), firstYield);
        assertEq(adapter.farmYieldDelivered(), 0);

        usdc.setBlocked(address(adapter), false);
        vm.prank(attacker);
        assertEq(adapter.flushMintAttemptYield(alice, firstAttempt), firstYield);
        assertEq(adapter.farmYieldDelivered(), firstYield);
        assertEq(usdc.balanceOf(yieldSink), firstYield);
        assertEq(MintAttemptReceiver(payable(firstReceiver)).parkedFarmYield(), 0);
        assertEq(adapter.flushMintAttemptYield(alice, firstAttempt), 0, "yield delivered twice");

        uint256 secondYield = 22e6;
        bytes32 secondAttempt = bytes32(uint256(8));
        address secondReceiver = adapter.predictMintReceiver(alice, secondAttempt);
        farm.setPendingYield(secondReceiver, secondYield);
        usdc.setSilentlyFails(address(adapter), true);

        _deposit(alice, secondAttempt, 1702, MINT_AMOUNT, PAYMENT);
        assertEq(vault.bondCount(alice), MINT_AMOUNT * 2, "false return bricked mint");
        assertEq(MintAttemptReceiver(payable(secondReceiver)).parkedFarmYield(), secondYield);
        assertEq(adapter.farmYieldDelivered(), firstYield);

        usdc.setSilentlyFails(address(adapter), false);
        assertEq(adapter.flushMintAttemptYield(alice, secondAttempt), secondYield);
        assertEq(adapter.farmYieldDelivered(), firstYield + secondYield);
        assertEq(usdc.balanceOf(yieldSink), firstYield + secondYield);
    }

    function test_receiverCountsYieldPaidOnItsWithdrawNotOnlyOnBondAutoDeposit() public {
        bytes32 attemptId = bytes32(uint256(9));
        address receiver = _deposit(alice, attemptId, 1801, MINT_AMOUNT, PAYMENT);
        uint256 secondMint = 2;
        IDexFiBond.MintDataInput memory data =
            _input(1802, 1, receiver, secondMint, PAYMENT);
        vm.deal(attacker, PAYMENT);
        vm.prank(attacker);
        bond.mint{value: PAYMENT}(data);

        uint256 withdrawYield = 31e6;
        farm.setPendingYield(receiver, withdrawYield);
        usdc.setBlocked(address(adapter), true);
        vm.prank(address(adapter));
        assertEq(
            MintAttemptReceiver(payable(receiver)).releaseMint(secondMint, secondMint, 0),
            0
        );

        assertEq(farm.staked(receiver), 0);
        assertEq(MintAttemptReceiver(payable(receiver)).parkedFarmYield(), withdrawYield);
        assertEq(usdc.balanceOf(receiver), withdrawYield);
        assertEq(bond.balanceOf(address(adapter), 0), secondMint);

        usdc.setBlocked(address(adapter), false);
        assertEq(adapter.flushMintAttemptYield(alice, attemptId), withdrawYield);
        assertEq(adapter.farmYieldDelivered(), withdrawYield);
        assertEq(usdc.balanceOf(yieldSink), withdrawYield);
    }

    function test_directPayloadFrontRunIsUncreditedAndRecoveredToExplicitRecipient() public {
        bytes32 compromisedAttempt = bytes32(uint256(10));
        address receiver = adapter.predictMintReceiver(alice, compromisedAttempt);
        bytes memory mintData = _encoded(1901, 0, receiver, MINT_AMOUNT, PAYMENT);

        vm.deal(attacker, PAYMENT);
        vm.prank(attacker);
        bond.mint{value: PAYMENT}(
            abi.decode(mintData, (IDexFiBond.MintDataInput))
        );
        bond.mint(receiver, 3);
        usdc.mint(receiver, 7e6);
        vm.deal(receiver, 9 wei);
        farm.setPendingYield(receiver, 11e6);

        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, uint256(1)
            )
        );
        vault.depositETH{value: PAYMENT}(compromisedAttempt, mintData);
        assertEq(vault.bondCount(alice), 0);

        vm.prank(admin);
        (
            uint256 recoveredBonds,
            uint256 swept,
            uint256 rawForwarded,
            uint256 rawRemaining,
            uint256 nativeForwarded,
            uint256 nativeRemaining
        ) = adapter.recoverMintAttempt(alice, compromisedAttempt, payable(recoveryRecipient));

        assertEq(recoveredBonds, MINT_AMOUNT + 3);
        assertEq(swept, 11e6);
        assertEq(rawForwarded, 7e6);
        assertEq(rawRemaining, 0);
        assertEq(nativeForwarded, 9 wei);
        assertEq(nativeRemaining, 0);
        assertEq(bond.balanceOf(recoveryRecipient, 0), MINT_AMOUNT + 3);
        assertEq(usdc.balanceOf(recoveryRecipient), 7e6);
        assertEq(recoveryRecipient.balance, 9 wei);
        assertEq(usdc.balanceOf(yieldSink), 11e6);
        assertEq(adapter.farmYieldDelivered(), 11e6);
        assertEq(farm.staked(address(adapter)), 0, "uncredited recovery entered canonical stake");
        assertEq(bond.balanceOf(address(adapter), 0), 0, "recovered bonds rested at adapter");
        assertEq(vault.bondCount(alice), 0);

        // Retrying means a fresh attempt and a fresh nonce-zero receiver.
        bytes32 retryAttempt = bytes32(uint256(11));
        address retryReceiver = _deposit(alice, retryAttempt, 1902, MINT_AMOUNT, PAYMENT);
        assertTrue(retryReceiver != receiver);
        assertEq(bond.nonces(retryReceiver), 1);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
    }

    function test_pendingOnlyCounterfactualPositionIsClaimedWithWithdrawZero() public {
        bytes32 attemptId = bytes32(uint256(12));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        uint256 pending = 41e6;
        farm.setPendingYield(receiver, pending);

        vm.prank(admin);
        (
            uint256 recoveredBonds,
            uint256 swept,
            uint256 rawForwarded,
            uint256 rawRemaining,
            uint256 nativeForwarded,
            uint256 nativeRemaining
        ) = adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));

        assertEq(recoveredBonds, 0);
        assertEq(swept, pending);
        assertEq(rawForwarded, 0);
        assertEq(rawRemaining, 0);
        assertEq(nativeForwarded, 0);
        assertEq(nativeRemaining, 0);
        assertEq(farm.pendingYield(receiver), 0, "withdraw(0) was skipped");
        assertEq(usdc.balanceOf(yieldSink), pending);
        assertEq(adapter.farmYieldDelivered(), pending);
        assertGt(receiver.code.length, 0);

        bytes memory staleAttempt = _encoded(2001, 0, receiver, MINT_AMOUNT, PAYMENT);
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyDeployed.selector, receiver)
        );
        vault.depositETH{value: PAYMENT}(attemptId, staleAttempt);
    }

    function test_rawUsdcAndNativeRecoveryFailuresRemainAtCloneAndCanRetry() public {
        bytes32 attemptId = bytes32(uint256(13));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        uint256 raw = 51e6;
        uint256 nativeAmount = 0.25 ether;
        RejectNativeRecovery rejecting = new RejectNativeRecovery();
        usdc.mint(receiver, raw);
        vm.deal(receiver, nativeAmount);
        usdc.setBlocked(address(rejecting), true);

        vm.prank(admin);
        (
            uint256 recoveredBonds,
            uint256 swept,
            uint256 rawForwarded,
            uint256 rawRemaining,
            uint256 nativeForwarded,
            uint256 nativeRemaining
        ) = adapter.recoverMintAttempt(alice, attemptId, payable(address(rejecting)));

        assertEq(recoveredBonds, 0);
        assertEq(swept, 0);
        assertEq(rawForwarded, 0);
        assertEq(rawRemaining, raw);
        assertEq(nativeForwarded, 0);
        assertEq(nativeRemaining, nativeAmount);
        assertEq(usdc.balanceOf(receiver), raw);
        assertEq(receiver.balance, nativeAmount);
        assertEq(adapter.farmYieldDelivered(), 0);

        usdc.setBlocked(address(rejecting), false);
        vm.prank(admin);
        (,, rawForwarded, rawRemaining, nativeForwarded, nativeRemaining) =
            adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));
        assertEq(rawForwarded, raw);
        assertEq(rawRemaining, 0);
        assertEq(nativeForwarded, nativeAmount);
        assertEq(nativeRemaining, 0);
        assertEq(usdc.balanceOf(recoveryRecipient), raw);
        assertEq(recoveryRecipient.balance, nativeAmount);
    }

    function test_emergencyRecoveryWorksWithFarmWithdrawBrokenAndWhitelistRevoked() public {
        bytes32 attemptId = bytes32(uint256(14));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory data = _input(2101, 0, receiver, MINT_AMOUNT, PAYMENT);
        vm.deal(attacker, PAYMENT);
        vm.prank(attacker);
        bond.mint{value: PAYMENT}(data);
        usdc.mint(receiver, 61e6);
        vm.deal(receiver, 0.5 ether);
        farm.setPendingYield(receiver, 71e6);
        farm.setRevertOnWithdraw(true);
        bond.setWhitelisted(address(adapter), false);

        vm.prank(admin);
        (
            uint256 bondsAtReceiver,
            uint256 swept,
            uint256 rawRemaining,
            uint256 nativeRemaining
        ) = adapter.emergencyRecoverMintAttempt(alice, attemptId);

        assertEq(bondsAtReceiver, MINT_AMOUNT);
        assertEq(swept, 0);
        assertEq(rawRemaining, 61e6);
        assertEq(nativeRemaining, 0.5 ether);
        assertEq(farm.staked(receiver), 0);
        assertEq(farm.pendingYield(receiver), 0, "emergency exit did not forfeit rewards");
        assertEq(bond.balanceOf(receiver, 0), MINT_AMOUNT);
        assertEq(usdc.balanceOf(receiver), 61e6);
        assertEq(receiver.balance, 0.5 ether);
        assertEq(vault.bondCount(alice), 0);

        vm.prank(admin);
        vm.expectRevert(DirectCallAdapter.AdapterNotWhitelisted.selector);
        adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));

        bond.setWhitelisted(address(adapter), true);
        farm.setRevertOnWithdraw(false);
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));
        assertEq(bond.balanceOf(recoveryRecipient, 0), MINT_AMOUNT);
        assertEq(usdc.balanceOf(recoveryRecipient), 61e6);
        assertEq(recoveryRecipient.balance, 0.5 ether);
        assertEq(bond.balanceOf(address(adapter), 0), 0);
        assertEq(farm.staked(address(adapter)), 0);
        assertEq(adapter.farmYieldDelivered(), 0, "forfeited/raw USDC was reported as farm yield");
    }

    function test_emptyRecoveryDoesNotDeployAndAdapterCannotBeRecoveryRecipient() public {
        bytes32 attemptId = bytes32(uint256(15));
        address receiver = adapter.predictMintReceiver(alice, attemptId);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.NothingToRecover.selector, receiver)
        );
        adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));
        assertEq(receiver.code.length, 0);

        vm.deal(receiver, 1 wei);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectCallAdapter.InvalidRecoveryRecipient.selector, address(adapter)
            )
        );
        adapter.recoverMintAttempt(alice, attemptId, payable(address(adapter)));
        assertEq(receiver.code.length, 0, "reverting recovery left a clone deployed");

        vm.prank(admin);
        adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));
        assertEq(recoveryRecipient.balance, 1 wei);
    }

    /// @notice A clone holding nothing but donated USDC and donated native recovers while DexFi
    ///         has the adapter de-whitelisted.
    /// @dev **Recorded round-34 Low 2.** `recoverMintAttempt`'s whitelist preflight was
    ///      unconditional, so this recovery - which never moves an ERC-1155 at all - was refused
    ///      for want of a permission it does not use, and the money sat at a counterfactual
    ///      address behind a third party's list. `farmYieldDelivered` is asserted unchanged
    ///      alongside it: raw donated USDC leaves for the recovery recipient and must never be
    ///      reported as farm yield.
    function test_donationOnlyCloneRecoversWhileTheAdapterIsDeWhitelisted() public {
        bytes32 attemptId = bytes32(uint256(23));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        uint256 raw = 81e6;
        uint256 nativeAmount = 0.75 ether;
        usdc.mint(receiver, raw);
        vm.deal(receiver, nativeAmount);
        bond.setWhitelisted(address(adapter), false);
        uint256 deliveredBefore = adapter.farmYieldDelivered();

        // The premise, asserted rather than assumed: nothing here needs the bond path.
        (uint256 stakedAtReceiver,) = farm.userInfo(receiver);
        assertEq(stakedAtReceiver, 0, "premise: the clone holds no stake");
        assertEq(bond.balanceOf(receiver, 0), 0, "premise: and no loose bonds");
        assertFalse(
            bond.whitelistContains(address(adapter)), "premise: the adapter is de-whitelisted"
        );

        vm.prank(admin);
        (
            uint256 recoveredBonds,
            uint256 swept,
            uint256 rawForwarded,
            uint256 rawRemaining,
            uint256 nativeForwarded,
            uint256 nativeRemaining
        ) = adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));

        assertEq(recoveredBonds, 0, "a donation-only clone recovered bonds");
        assertEq(swept, 0);
        assertEq(rawForwarded, raw);
        assertEq(rawRemaining, 0);
        assertEq(nativeForwarded, nativeAmount);
        assertEq(nativeRemaining, 0);
        assertEq(usdc.balanceOf(recoveryRecipient), raw);
        assertEq(recoveryRecipient.balance, nativeAmount);
        assertEq(usdc.balanceOf(receiver), 0);
        assertEq(receiver.balance, 0);
        assertEq(
            adapter.farmYieldDelivered(),
            deliveredBefore,
            "donated USDC was reported as farm yield"
        );
    }

    /// @notice A staked clone still refuses recovery while the adapter is de-whitelisted.
    /// @dev **This is the assertion the loose-bond-only proposal fails, and it is the whole reason
    ///      the condition reads the stake.** `MintAttemptReceiver.recoverAll` withdraws from the
    ///      farm FIRST and reads its own bond balance afterwards, so at preflight time this clone
    ///      reads ZERO loose bonds and needs the bond path one call later. A gate that looked only
    ///      at loose bonds would let this call through, and it would die inside DexFi's `_update`
    ///      with an opaque error instead of `AdapterNotWhitelisted`.
    ///
    ///      The second half is the fixture's own proof: the stake has to be real, or the neuter
    ///      that reintroduces the loose-bond-only condition would leave this test green and it
    ///      would be evidence of nothing. `seedStakeFor` only bumps the farm's ledger, so the pool
    ///      is minted the bonds it is about to hand back; without that first line `farm.withdraw`
    ///      reverts on a balance the pool does not have.
    function test_stakedCloneStillRefusesRecoveryWhileTheAdapterIsDeWhitelisted() public {
        bytes32 attemptId = bytes32(uint256(24));
        address receiver = adapter.predictMintReceiver(alice, attemptId);

        bond.mint(address(farm), MINT_AMOUNT);
        farm.seedStakeFor(receiver, MINT_AMOUNT);
        bond.setWhitelisted(address(adapter), false);

        // The premise: exactly the shape a loose-bond-only condition cannot see.
        (uint256 stakedAtReceiver,) = farm.userInfo(receiver);
        assertEq(stakedAtReceiver, MINT_AMOUNT, "premise: the clone is staked");
        assertEq(bond.balanceOf(receiver, 0), 0, "premise: and holds no loose bonds at preflight");

        vm.prank(admin);
        vm.expectRevert(DirectCallAdapter.AdapterNotWhitelisted.selector);
        adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));

        // CONTROL, and the fixture check: with the list restored the same position recovers
        // through the bond path, which it can only do if the stake was physically backed.
        bond.setWhitelisted(address(adapter), true);
        vm.prank(admin);
        (uint256 recoveredBonds,,,,,) =
            adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));
        assertEq(recoveredBonds, MINT_AMOUNT, "the seeded stake was not physically backed");
        assertEq(bond.balanceOf(recoveryRecipient, 0), MINT_AMOUNT);
        assertEq(farm.staked(receiver), 0);
    }

    /// @notice A pending-only clone recovers while the adapter is de-whitelisted.
    /// @dev Tightness in the other direction, and the reason `pendingShare` is deliberately not
    ///      one of the terms. `recoverAll` claims a pending-only position with `farm.withdraw(0)`,
    ///      which moves no bond at all, so demanding the bond whitelist for it would strand yield
    ///      for a transfer that never happens. Neuter: OR `farm.pendingShare(receiver) != 0` into
    ///      `needsBondPath` and this test goes red while the two above stay green.
    function test_pendingOnlyCloneRecoversWhileTheAdapterIsDeWhitelisted() public {
        bytes32 attemptId = bytes32(uint256(25));
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        uint256 pending = 91e6;
        farm.setPendingYield(receiver, pending);
        bond.setWhitelisted(address(adapter), false);

        (uint256 stakedAtReceiver,) = farm.userInfo(receiver);
        assertEq(stakedAtReceiver, 0, "premise: the clone holds no stake");
        assertEq(bond.balanceOf(receiver, 0), 0, "premise: and no loose bonds");
        assertEq(farm.pendingShare(receiver), pending, "premise: pending yield and nothing else");

        vm.prank(admin);
        (uint256 recoveredBonds, uint256 swept,,,,) =
            adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));

        assertEq(recoveredBonds, 0);
        assertEq(swept, pending);
        assertEq(farm.pendingYield(receiver), 0, "withdraw(0) was skipped");
        assertEq(usdc.balanceOf(yieldSink), pending);
        assertEq(adapter.farmYieldDelivered(), pending);
    }

    function test_clonesHaveImmutableBindingsAndImplementationCannotReceiveOrExecute() public {
        MintAttemptReceiver implementation = adapter.mintReceiverImplementation();
        assertEq(implementation.adapter(), address(adapter));
        assertEq(address(implementation.bond()), address(bond));
        assertEq(address(implementation.farm()), address(farm));
        assertEq(address(implementation.usdc()), address(usdc));

        vm.prank(address(adapter));
        vm.expectRevert(MintAttemptReceiver.ImplementationCall.selector);
        implementation.releaseMint(0, 0, 0);

        vm.deal(attacker, 1 wei);
        vm.prank(attacker);
        (bool ok, bytes memory reason) = payable(address(implementation)).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(_selector(reason), MintAttemptReceiver.ImplementationCall.selector);
        assertEq(address(implementation).balance, 0);

        bytes32 attemptId = bytes32(uint256(16));
        address receiver = _deposit(alice, attemptId, 2201, MINT_AMOUNT, PAYMENT);
        MintAttemptReceiver child = MintAttemptReceiver(payable(receiver));
        assertEq(child.adapter(), address(adapter));
        assertEq(address(child.bond()), address(bond));
        assertEq(address(child.farm()), address(farm));
        assertEq(address(child.usdc()), address(usdc));
        assertTrue(child.supportsInterface(type(IERC165).interfaceId));
        assertTrue(child.supportsInterface(type(IERC1155Receiver).interfaceId));

        vm.prank(attacker);
        vm.expectRevert(MintAttemptReceiver.NotAdapter.selector);
        child.flushFarmYield();

        vm.deal(attacker, 1 wei);
        vm.prank(attacker);
        (ok,) = payable(receiver).call{value: 1 wei}("");
        assertTrue(ok, "a clone refused recoverable native dust");
        assertEq(receiver.balance, 1 wei);
    }

    /// @notice The zero-beneficiary namespace is closed on every path that can reach a
    ///         counterfactual receiver, and this is the first test to say so: before round
    ///         34 `InvalidBeneficiary` appeared nowhere in `test/`, so the guard was argued
    ///         and never measured.
    /// @dev What deletion measures. The credit path cannot reach this guard at all -
    ///      `mintBonds` is `onlyVault` against an immutable `vault`, and
    ///      `CollateralVault.depositETH`'s single call site passes `msg.sender`, which the
    ///      EVM never sets to the zero address. There the guard is defence-in-depth. It is
    ///      the only thing standing on the four entry points asserted below, and what it
    ///      buys is a CLOSED namespace rather than a prevented loss: with the guard deleted,
    ///      a donation to `predictMintReceiver(address(0), id)` was measured fully
    ///      recoverable by governance (5 bonds, 3e6 USDC and 2 wei all reached the
    ///      recipient). With the guard in place that address can never be minted into and
    ///      never recovered from, so anything donated there is stranded. Closing the
    ///      namespace is the deliberate trade, and this test is what pins it.
    ///
    ///      Each of the four is individually load-bearing, MEASURED with the guard deleted:
    ///      `predictMintReceiver` returns an address and does not revert at all;
    ///      `flushMintAttemptYield` falls through to `InvalidMintReceiverCode` (0x8e6ccceb)
    ///      only because the zero namespace can never have been deployed into; and both
    ///      recovery doors fall through to `NothingToRecover` (0x86d9d035) only while the
    ///      address is empty - donate to it first and `recoverMintAttempt` succeeds. So no
    ///      one of these four is redundant against the other three.
    ///
    ///      Raw calls rather than `vm.expectRevert` so the selector is asserted rather than
    ///      merely the fact of a revert. `assertFalse`/`assertEq` still revert on the first
    ///      mismatch, so a neutered run reports the earliest failing path, not all four.
    function test_zeroBeneficiaryIsRejectedOnEveryPathThatCanReachIt() public {
        bytes32 attemptId = bytes32(uint256(77));

        _assertZeroBeneficiaryRefused(
            abi.encodeCall(DirectCallAdapter.predictMintReceiver, (address(0), attemptId)),
            address(this),
            "predictMintReceiver"
        );
        // Permissionless, so an attacker reaches this one directly.
        _assertZeroBeneficiaryRefused(
            abi.encodeCall(DirectCallAdapter.flushMintAttemptYield, (address(0), attemptId)),
            attacker,
            "flushMintAttemptYield"
        );
        // Owner-only, so the ownership check shadows the guard for anybody else.
        _assertZeroBeneficiaryRefused(
            abi.encodeCall(
                DirectCallAdapter.recoverMintAttempt,
                (address(0), attemptId, payable(recoveryRecipient))
            ),
            admin,
            "recoverMintAttempt"
        );
        _assertZeroBeneficiaryRefused(
            abi.encodeCall(
                DirectCallAdapter.emergencyRecoverMintAttempt, (address(0), attemptId)
            ),
            admin,
            "emergencyRecoverMintAttempt"
        );

        // The attempt id is not what is being refused: the same id still mints for a real
        // beneficiary, so the guard closes one namespace and costs the borrower nothing.
        address live = _deposit(alice, attemptId, 7701, MINT_AMOUNT, PAYMENT);
        assertTrue(live != address(0));
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _assertZeroBeneficiaryRefused(bytes memory payload, address caller, string memory label)
        internal
    {
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(adapter).call(payload);
        assertFalse(ok, string.concat(label, " accepted a zero beneficiary"));
        assertEq(
            _selector(reason),
            DirectCallAdapter.InvalidBeneficiary.selector,
            string.concat(label, " did not revert InvalidBeneficiary")
        );
    }

    function _assertDonationRecovery(DonationCase memory c, uint256 realFarmYield) internal {
        vm.prank(admin);
        (
            uint256 recoveredBonds,
            uint256 swept,
            uint256 rawForwarded,
            uint256 rawRemaining,
            uint256 nativeForwarded,
            uint256 nativeRemaining
        ) = adapter.recoverMintAttempt(alice, c.attemptId, payable(recoveryRecipient));

        assertEq(recoveredBonds, c.childBondDonation + c.childStakedDonation);
        assertEq(swept, 0, "a raw donation became farm yield on recovery");
        assertEq(rawForwarded, c.childUsdcDonation);
        assertEq(rawRemaining, 0);
        assertEq(nativeForwarded, c.childNativeDonation);
        assertEq(nativeRemaining, 0);
        assertEq(
            bond.balanceOf(recoveryRecipient, 0), c.childBondDonation + c.childStakedDonation
        );
        assertEq(usdc.balanceOf(recoveryRecipient), c.childUsdcDonation);
        assertEq(recoveryRecipient.balance, c.childNativeDonation);
        assertEq(
            farm.staked(address(adapter)),
            c.adapterStakedDonation + MINT_AMOUNT,
            "recovery restaked a donation"
        );
        assertEq(bond.balanceOf(address(adapter), 0), c.adapterLooseDonation);
        assertEq(address(adapter).balance, c.adapterNativeDonation);
        assertEq(adapter.farmYieldDelivered(), realFarmYield);
        assertEq(vault.bondCount(alice), MINT_AMOUNT);
    }

    function _deposit(
        address beneficiary,
        bytes32 attemptId,
        uint256 uuid,
        uint256 amount,
        uint256 payment
    ) internal returns (address receiver) {
        receiver = adapter.predictMintReceiver(beneficiary, attemptId);
        _callDeposit(
            beneficiary,
            attemptId,
            _encoded(uuid, 0, receiver, amount, payment),
            payment
        );
    }

    function _callDeposit(
        address beneficiary,
        bytes32 attemptId,
        bytes memory mintData,
        uint256 payment
    ) internal {
        vm.deal(beneficiary, payment);
        vm.prank(beneficiary);
        vault.depositETH{value: payment}(attemptId, mintData);
    }

    function _encoded(
        uint256 uuid,
        uint256 nonce,
        address receiver,
        uint256 amount,
        uint256 payment
    ) internal view returns (bytes memory) {
        return abi.encode(_input(uuid, nonce, receiver, amount, payment));
    }

    function _input(
        uint256 uuid,
        uint256 nonce,
        address receiver,
        uint256 amount,
        uint256 payment
    ) internal view returns (IDexFiBond.MintDataInput memory) {
        return _input(uuid, nonce, receiver, amount, payment, block.timestamp + 1 days);
    }

    function _input(
        uint256 uuid,
        uint256 nonce,
        address receiver,
        uint256 amount,
        uint256 payment,
        uint256 deadline
    ) internal pure returns (IDexFiBond.MintDataInput memory) {
        return IDexFiBond.MintDataInput({
            uuid: uuid,
            nonce: nonce,
            receiver: receiver,
            amountNfts: amount,
            paymentAmount: payment,
            deadline: deadline,
            signature: ""
        });
    }

    function _assertUnusedAttempt(address receiver, uint256 uuid) internal view {
        assertEq(receiver.code.length, 0);
        assertEq(bond.nonces(receiver), 0);
        assertFalse(bond.uuidUsed(uuid));
        assertEq(farm.staked(receiver), 0);
        assertEq(bond.balanceOf(receiver, 0), 0);
        assertEq(vault.bondCount(alice), 0);
    }

    function _yieldHarvested() internal returns (uint256 count, uint256 reported) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("YieldHarvested(uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != signature) continue;
            ++count;
            reported = abi.decode(logs[i].data, (uint256));
        }
    }

    function _selector(bytes memory reason) internal pure returns (bytes4 result) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            result := mload(add(reason, 0x20))
        }
    }
}
