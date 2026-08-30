// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FrozenMintPlan} from "../FrozenMintPlan.sol";
import {Config} from "../../src/Config.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {DirectCallAdapter} from "../../src/adapters/DirectCallAdapter.sol";
import {MintAttemptReceiver} from "../../src/MintAttemptReceiver.sol";
import {RiskParams} from "../../src/RiskParams.sol";
import {ICustodyAdapter} from "../../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../../src/interfaces/IRiskParams.sol";
import {MockNavOracle} from "../mocks/MockNavOracle.sol";

/// @title DexFiMintAttemptForkProof
/// @notice Gated Base-mainnet proof for a real DexFi keeper signature bound to one
///         frozen, deterministic mint-attempt receiver.
///
/// @dev This file has two deliberately different modes:
///
///      1. Address preparation. Set only `RUN_DEXFI_MINT_PROOF=true` and
///         `BASE_RPC_URL`. The preparation test prints the exact receiver to give
///         DexFi. The signed-payload test records an explicit skip.
///      2. Acceptance proof. In an ignored local `contracts/.env`, additionally set
///         `DEXFI_MINT_PROOF_BLOCK`, `DEXFI_MINT_RECEIVER`, `DEXFI_MINT_UUID`,
///         `DEXFI_MINT_AMOUNT`, `DEXFI_MINT_PAYMENT_WEI`, `DEXFI_MINT_DEADLINE` and
///         `DEXFI_MINT_SIGNATURE`.
///
///      🟥 **BOTH MODES REQUIRE `--no-isolate` ON FORGE 1.8 AND LATER.** `--isolate` became
///      forge's default in 1.8.0, and under it this fixture's deployer consumes one nonce more
///      than the frozen ladder expects: `setUp` fails with `frozen deploy order moved: 6 != 5`
///      before either test body runs. MEASURED 2026-08-30 on forge 1.8.1: `--no-isolate` passes,
///      `--no-dynamic-test-linking` alone does NOT, so isolation is the cause and dynamic linking
///      is exonerated. The frozen plan itself is unaffected, because it is derived from a real
///      `forge script` broadcast rather than from a test, and isolation is a `forge test` mode.
///      This test is env-gated, so a bare `forge test` skips it and nothing in CI would tell you.
///
///      Never pass the signature on the command line, run this proof with verbose
///      traces, or log the payload struct. A failed verbose trace can contain call
///      data. This test logs only the derived receiver and a one-way payload digest.
///      The signature and every other secret-bearing input stay outside the tree.
///
///      The receiver-driving fixture is frozen here rather than inherited from the
///      broad fork fixture. Its proof deployer starts at `PROOF_DEPLOYER_START_NONCE`,
///      which is **ONE, not zero**: a deploy-time-linked library's CREATE2 goes to the
///      deterministic factory at the head of the broadcast, and that is a transaction from
///      the deploying key, so it spends nonce 0. The fixture then makes exactly four
///      CREATEs, in this order, mirroring `DeployBase._deployProtocol`:
///
///        nonce 1: MockNavOracle
///        nonce 2: RiskParams
///        nonce 3: CollateralVault
///        nonce 4: DirectCallAdapter
///
///      🟥 **This block stated the superseded nonce-3 plan - start nonce zero, and the
///      oracle and risk parameters the wrong way round - until audit round 38.** Round 37
///      re-derived the plan at nonce 4 and corrected the inline comment beside
///      `PROOF_DEPLOYER_START_NONCE`, the constants below, and the sibling fixture in
///      `R34Determinism.t.sol`, but not this prose block, which is the operator-facing
///      statement of the whole plan. The order matters twice over: under the shifted ladder
///      the **vault** lands on `0xE3B53c9e...`, the address frozen until 2026-08-30 as the
///      *adapter*, so a reader working from the old block stays internally consistent at
///      every step while pointing at the wrong contract.
///
///      DirectCallAdapter then creates its MintAttemptReceiver implementation from
///      the adapter's own first CREATE nonce. Changing any address, nonce, ordering,
///      constructor argument, salt domain, beneficiary or attempt id invalidates the
///      frozen receiver and requires a new DexFi payload.
///
///      **The constants themselves live in `test/FrozenMintPlan.sol` and this fixture inherits
///      them.** They were retyped here and in `test/R34Determinism.t.sol` until audit round 39,
///      uncoupled, with nothing comparing the two copies - which is why #354 could move a value
///      in one file and leave the other green and stale.
///
///      🟥 **THIS PLAN IS A MECHANISM FIXTURE, NOT A PRODUCTION ADDRESS COMMITMENT.** It pins a
///      DERIVATION - the CREATE2-from-CREATE(adapter, 1) shape of the receiver and the adapter's
///      offset in the deploying key's nonce ladder - and nothing should be signed against these
///      addresses. MEASURED 2026-08-30: `PROOF_DEPLOYER` is at nonce 0 with a zero balance and
///      appears only in fixtures, the deploy key every operator document names is at nonce 96,
///      and on the real `DeployTestnet` artefact the testnet ladder puts the adapter at a LATER nonce and derives a different
///      receiver. 🟥 **Do not write that nonce down. It has moved twice.** It was 8, and the
///      round-39 lock reorder put three `lockTo` CALLs ahead of `_deployProtocol` and made it
///      **11** (measured 2026-08-30 from a real artefact). What is stable is the OFFSET: the
///      adapter is the fourth contract `_deployProtocol` creates, whatever precedes it. The
///      broadcast checker derives the nonce from the artefact and prints it; read that.
///      It derives a
///      different receiver. The production receiver is derived at deploy time from the real
///      deployer's real nonce, and the payload is re-signed against it then, through
///      `/sign-mint-and-apply` - `/bonds/sign-mint` is broken and returns an identical 422 for a
///      correct signature and for garbage. So "requires a new DexFi payload" above is a
///      statement about the DERIVATION moving, which is real, and never a claim that production
///      will deploy at `EXPECTED_ADAPTER`. Full statement in `FrozenMintPlan.sol`.
contract DexFiMintAttemptForkProof is Test, FrozenMintPlan {
    IDexFiBond internal constant BOND = IDexFiBond(Config.DEXFI_BOND_NFT);
    IDexFiFarm internal constant FARM = IDexFiFarm(Config.DEXFI_FARM);
    IERC20 internal constant USDC = IERC20(Config.USDC_BASE);

    /// @dev ERC1967 implementation slot, read only to make a live farm upgrade
    ///      visible in the proof transcript.
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant MINT_ATTEMPT_EVENT_SIGNATURE =
        keccak256("MintAttemptExecuted(address,bytes32,address,uint256,uint256)");

    struct ProofSnapshot {
        uint256 treasuryEth;
        uint256 supply;
        uint256 beneficiaryCredit;
        uint256 totalCredit;
        uint256 adapterLoose;
        uint256 receiverLoose;
        uint256 receiverUsdc;
        uint256 recipientUsdc;
        uint256 delivered;
        uint256 adapterStake;
        uint256 receiverStake;
        uint256 beneficiaryEth;
    }

    RiskParams internal riskParams;
    MockNavOracle internal navOracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    address internal receiver;
    address internal farmImplementation;

    bool internal runProof;
    bool internal payloadPresent;
    uint256 internal pinnedBlock;

    function setUp() public {
        runProof = vm.envOr("RUN_DEXFI_MINT_PROOF", false);
        if (!runProof) return;

        bytes memory signature = vm.envOr("DEXFI_MINT_SIGNATURE", bytes(""));
        payloadPresent = signature.length != 0;
        pinnedBlock = vm.envOr("DEXFI_MINT_PROOF_BLOCK", uint256(0));

        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        if (payloadPresent) {
            require(pinnedBlock != 0, "real proof requires DEXFI_MINT_PROOF_BLOCK");
            vm.createSelectFork(rpc, pinnedBlock);
            assertEq(block.number, pinnedBlock, "fork did not select the pinned block");
        } else {
            // Preparation may use latest state because the fork block does not enter
            // either CREATE or CREATE2 address derivation. The accepted proof pins it.
            vm.createSelectFork(rpc);
        }

        _assertLiveDexFiBindings();
        _deployFrozenFixture();
    }

    /// @notice Print the exact receiver before requesting a real signed payload.
    /// @dev No payload is read or fabricated here. This remains explicitly skipped
    ///      in ordinary CI because `setUp` does no work unless the proof gate is set.
    function test_prepareExactReceiverForDexFiPayload() public {
        vm.skip(!runProof);

        assertEq(block.chainid, 8453, "not Base mainnet");
        assertEq(receiver.code.length, 0, "attempt receiver is not fresh");
        assertEq(BOND.nonces(receiver), 0, "attempt receiver nonce is not zero");
        assertFalse(BOND.whitelistContains(address(adapter)), "fixture adapter unexpectedly whitelisted");
        assertFalse(BOND.whitelistContains(receiver), "attempt receiver must not be whitelisted");

        address implementation = address(adapter.mintReceiverImplementation());
        assertEq(implementation, EXPECTED_RECEIVER_IMPLEMENTATION, "implementation CREATE address moved");
        assertEq(adapter.MINT_ATTEMPT_DOMAIN(), EXPECTED_MINT_ATTEMPT_DOMAIN, "salt domain moved");
        assertEq(
            keccak256(abi.encode(adapter.MINT_ATTEMPT_DOMAIN(), PROOF_BENEFICIARY, PROOF_ATTEMPT_ID)),
            EXPECTED_MINT_ATTEMPT_SALT,
            "attempt salt moved"
        );
        assertGt(implementation.code.length, 0, "receiver implementation missing");
        MintAttemptReceiver implementationContract = MintAttemptReceiver(payable(implementation));
        assertEq(implementationContract.adapter(), address(adapter), "implementation adapter binding");
        assertEq(address(implementationContract.bond()), address(BOND), "implementation bond binding");
        assertEq(address(implementationContract.farm()), address(FARM), "implementation farm binding");
        assertEq(address(implementationContract.usdc()), address(USDC), "implementation USDC binding");

        emit log_named_uint("Base fork block used for preparation only", block.number);
        emit log_named_address("frozen proof deployer", PROOF_DEPLOYER);
        emit log_named_uint("frozen proof deployer start nonce", PROOF_DEPLOYER_START_NONCE);
        emit log_named_address("frozen beneficiary", PROOF_BENEFICIARY);
        emit log_named_bytes32("frozen attempt id", PROOF_ATTEMPT_ID);
        emit log_named_address("frozen vault", address(vault));
        emit log_named_address("frozen adapter", address(adapter));
        emit log_named_address("frozen receiver implementation", implementation);
        emit log_named_address("EXACT RECEIVER FOR DEXFI", receiver);
        emit log_named_address("live farm implementation", farmImplementation);
        emit log_named_bytes32("live farm implementation codehash", farmImplementation.codehash);
        emit log_named_bytes32("live bond codehash", address(BOND).codehash);
    }

    /// @notice Execute the complete live path using one genuine receiver-bound payload:
    ///         mint -> transient receiver -> custody handoff -> adapter stake -> vault credit.
    function test_realSignedPayloadCompletesMintHandoff() public {
        vm.skip(!runProof);
        vm.skip(!payloadPresent);

        IDexFiBond.MintDataInput memory data = _loadPayload();
        // 2026-08-30: the address plan moved from nonce 3 to nonce 4, so a payload signed before
        // then IS bound to a different receiver and this line is where it says so. That is the
        // designed outcome, not a regression - the EIP-712 digest binds `receiver`, so the old
        // payload cannot be redirected and has to be re-signed against the derived address this
        // fixture prints. Requesting one is self-serve; pin a fresh Base block when you do.
        assertEq(
            data.receiver,
            receiver,
            "payload is bound to a different receiver - re-sign against the receiver above"
        );
        assertEq(data.nonce, 0, "proof accepts only a fresh receiver nonce");
        assertEq(BOND.nonces(receiver), 0, "live receiver nonce changed before proof");
        assertEq(receiver.code.length, 0, "clone already exists before proof");
        assertGt(data.amountNfts, 0, "zero bond payload");
        assertGt(data.paymentAmount, 0, "zero payment payload");
        assertGe(data.deadline, block.timestamp, "payload expired at pinned block");

        // The only live permission mutation in the fork. The transient receiver is
        // deliberately not whitelisted: farm -> receiver succeeds because the farm
        // is whitelisted, then receiver -> adapter succeeds because the adapter is.
        address[] memory accounts = new address[](1);
        accounts[0] = address(adapter);
        vm.prank(Config.DEXFI_TREASURY_EOA);
        BOND.addWhitelist(accounts);
        assertTrue(BOND.whitelistContains(address(adapter)), "adapter whitelist did not land");
        assertFalse(BOND.whitelistContains(receiver), "receiver must remain unwhitelisted");

        address dexFiTreasury = BOND.treasury();
        vm.deal(PROOF_BENEFICIARY, data.paymentAmount);
        ProofSnapshot memory beforeProof = _snapshot(dexFiTreasury);

        vm.recordLogs();
        // Measured, not budgeted. The accepted design costed the structural overhead of this path
        // at roughly 60k to 75k - a clone deploy plus a fresh receiver nonce slot going zero to
        // non-zero - and said the farm operations would dominate and were the figure that
        // mattered. Nothing had measured it against the live contracts until this ran. The number
        // is emitted rather than asserted: a bound would pin one fork block's gas schedule, and
        // DexFi can change the callees inside the window. The braces are load-bearing - without
        // them these two locals put this function over solc's stack limit.
        {
            uint256 gasBefore = gasleft();
            vm.prank(PROOF_BENEFICIARY);
            vault.depositETH{value: data.paymentAmount}(PROOF_ATTEMPT_ID, abi.encode(data));
            emit log_named_uint("depositETH gas, whole path, live DexFi contracts", gasBefore - gasleft());
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(PROOF_BENEFICIARY.balance, beforeProof.beneficiaryEth - data.paymentAmount, "payer ETH delta");
        assertEq(dexFiTreasury.balance, beforeProof.treasuryEth + data.paymentAmount, "treasury ETH delta");
        assertEq(
            BOND.totalSupply(Config.DEXFI_BOND_TOKEN_ID), beforeProof.supply + data.amountNfts, "bond supply delta"
        );
        assertEq(BOND.nonces(receiver), 1, "receiver nonce did not advance exactly once");
        assertEq(
            vault.bondCount(PROOF_BENEFICIARY),
            beforeProof.beneficiaryCredit + data.amountNfts,
            "beneficiary credit"
        );
        assertEq(vault.totalBondCount(), beforeProof.totalCredit + data.amountNfts, "total credit");
        assertTrue(vault.custodyIsSolvent(), "credited bonds are not in canonical custody");

        assertEq(receiver.code.length, 45, "receiver is not the expected ERC-1167 clone");
        MintAttemptReceiver attempt = MintAttemptReceiver(payable(receiver));
        assertEq(attempt.adapter(), address(adapter), "clone adapter binding");
        assertEq(address(attempt.bond()), address(BOND), "clone bond binding");
        assertEq(address(attempt.farm()), address(FARM), "clone farm binding");
        assertEq(address(attempt.usdc()), address(USDC), "clone USDC binding");
        assertEq(attempt.parkedFarmYield(), 0, "farm yield stranded at receiver");

        (uint256 adapterStakeAfter,) = FARM.userInfo(address(adapter));
        (uint256 receiverStakeAfter,) = FARM.userInfo(receiver);
        assertEq(adapterStakeAfter, beforeProof.adapterStake + data.amountNfts, "adapter stake delta");
        assertEq(receiverStakeAfter, beforeProof.receiverStake, "receiver stake not fully handed off");
        assertEq(
            BOND.balanceOf(address(adapter), Config.DEXFI_BOND_TOKEN_ID),
            beforeProof.adapterLoose,
            "adapter retained loose minted bonds"
        );
        assertEq(
            BOND.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID),
            beforeProof.receiverLoose,
            "receiver retained loose minted bonds"
        );
        assertEq(USDC.balanceOf(receiver), beforeProof.receiverUsdc, "receiver retained USDC");

        uint256 delivered = adapter.farmYieldDelivered() - beforeProof.delivered;
        assertEq(
            USDC.balanceOf(PROOF_YIELD_RECIPIENT) - beforeProof.recipientUsdc,
            delivered,
            "farm delivery counter disagrees with recipient balance"
        );
        assertTrue(BOND.whitelistContains(address(adapter)), "adapter lost whitelist during mint");
        assertFalse(BOND.whitelistContains(receiver), "receiver was whitelisted during mint");
        _assertMintAttemptEvent(logs, data.paymentAmount, data.amountNfts);

        bytes32 payloadDigest = keccak256(
            abi.encode(
                data.uuid,
                data.nonce,
                data.receiver,
                data.amountNfts,
                data.paymentAmount,
                data.deadline,
                keccak256(data.signature)
            )
        );
        emit log_named_uint("accepted Base fork block", block.number);
        emit log_named_address("accepted mint receiver", receiver);
        emit log_named_bytes32("accepted payload digest", payloadDigest);
    }

    function _deployFrozenFixture() private {
        // Strip any Base EIP-7702 delegation and reset the sole CREATE address
        // driver. These are local fork mutations only; no transaction is broadcast.
        vm.etch(PROOF_DEPLOYER, "");
        vm.etch(PROOF_BENEFICIARY, "");
        vm.etch(PROOF_YIELD_RECIPIENT, "");
        vm.resetNonce(PROOF_DEPLOYER);
        vm.setNonce(PROOF_DEPLOYER, PROOF_DEPLOYER_START_NONCE);
        vm.deal(PROOF_DEPLOYER, 1 ether);
        assertEq(vm.getNonce(PROOF_DEPLOYER), PROOF_DEPLOYER_START_NONCE, "proof nonce reset failed");

        // `startBroadcast(address)` makes CREATE addresses derive from the fixed
        // EOA. A prank changes constructor `msg.sender` but is not an address-plan
        // primitive: CREATE would still be issued by this test contract.
        vm.startBroadcast(PROOF_DEPLOYER);
        // Oracle BEFORE risk parameters, mirroring `DeployBase._deployProtocol`. This fixture built
        // them the other way round, so slots carried each other's names while the values stayed
        // right.
        navOracle = new MockNavOracle(PROOF_NAV);
        riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            PROOF_DEPLOYER
        );
        vault = new CollateralVault(BOND, INAVOracle(address(navOracle)), riskParams, PROOF_DEPLOYER);
        adapter = new DirectCallAdapter(
            BOND,
            FARM,
            USDC,
            address(vault),
            PROOF_DEPLOYER,
            PROOF_YIELD_RECIPIENT
        );
        vm.stopBroadcast();

        vm.prank(PROOF_DEPLOYER);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        receiver = adapter.predictMintReceiver(PROOF_BENEFICIARY, PROOF_ATTEMPT_ID);
        _assertFrozenAddressPlan();

        vm.label(PROOF_DEPLOYER, "frozen proof deployer");
        vm.label(PROOF_BENEFICIARY, "frozen proof beneficiary");
        vm.label(PROOF_YIELD_RECIPIENT, "frozen proof yield recipient");
        vm.label(address(vault), "frozen proof vault");
        vm.label(address(adapter), "frozen proof adapter");
        vm.label(receiver, "frozen mint attempt receiver");
    }

    function _assertFrozenAddressPlan() private view {
        assertEq(vm.getNonce(PROOF_DEPLOYER), 5, "frozen deploy order moved");
        assertEq(address(navOracle), EXPECTED_NAV_ORACLE, "NAV CREATE address moved");
        assertEq(address(riskParams), EXPECTED_RISK_PARAMS, "risk CREATE address moved");
        assertEq(address(vault), EXPECTED_VAULT, "vault CREATE address moved");
        assertEq(address(adapter), EXPECTED_ADAPTER, "adapter CREATE address moved");
        assertEq(
            address(adapter.mintReceiverImplementation()),
            EXPECTED_RECEIVER_IMPLEMENTATION,
            "implementation CREATE address moved"
        );
        assertEq(adapter.MINT_ATTEMPT_DOMAIN(), EXPECTED_MINT_ATTEMPT_DOMAIN, "salt domain moved");
        assertEq(
            keccak256(abi.encode(adapter.MINT_ATTEMPT_DOMAIN(), PROOF_BENEFICIARY, PROOF_ATTEMPT_ID)),
            EXPECTED_MINT_ATTEMPT_SALT,
            "attempt salt moved"
        );
        assertEq(receiver, EXPECTED_RECEIVER, "CREATE2 receiver moved");
    }

    function _assertLiveDexFiBindings() private {
        assertEq(block.chainid, 8453, "not Base mainnet");
        assertGt(address(BOND).code.length, 0, "live bond code missing");
        assertGt(address(FARM).code.length, 0, "live farm proxy code missing");
        assertGt(address(USDC).code.length, 0, "live USDC code missing");
        assertEq(BOND.TOKEN_ID(), Config.DEXFI_BOND_TOKEN_ID, "live bond token id changed");
        assertEq(BOND.rewardPool(), address(FARM), "live bond reward pool changed");
        assertEq(BOND.keeper(), Config.DEXFI_MINT_KEEPER, "live mint keeper changed");
        assertEq(BOND.treasury(), Config.DEXFI_TREASURY_EOA, "live DexFi treasury changed");
        assertFalse(BOND.paused(), "live bond is paused");

        bytes32 implementationWord = vm.load(address(FARM), ERC1967_IMPLEMENTATION_SLOT);
        farmImplementation = address(uint160(uint256(implementationWord)));
        assertTrue(farmImplementation != address(0), "live farm implementation is zero");
        assertGt(farmImplementation.code.length, 0, "live farm implementation code missing");
    }

    function _loadPayload() private view returns (IDexFiBond.MintDataInput memory data) {
        bytes memory signature = vm.envOr("DEXFI_MINT_SIGNATURE", bytes(""));
        address signedReceiver = vm.envOr("DEXFI_MINT_RECEIVER", address(0));
        require(signature.length == 65, "DEXFI_MINT_SIGNATURE must be 65 bytes");
        require(signedReceiver != address(0), "DEXFI_MINT_RECEIVER is required");

        data = IDexFiBond.MintDataInput({
            uuid: vm.envOr("DEXFI_MINT_UUID", uint256(0)),
            nonce: 0,
            receiver: signedReceiver,
            amountNfts: vm.envOr("DEXFI_MINT_AMOUNT", uint256(0)),
            paymentAmount: vm.envOr("DEXFI_MINT_PAYMENT_WEI", uint256(0)),
            deadline: vm.envOr("DEXFI_MINT_DEADLINE", uint256(0)),
            signature: signature
        });
        require(data.uuid != 0, "DEXFI_MINT_UUID is required");
    }

    function _snapshot(address dexFiTreasury) private view returns (ProofSnapshot memory snap) {
        snap.treasuryEth = dexFiTreasury.balance;
        snap.supply = BOND.totalSupply(Config.DEXFI_BOND_TOKEN_ID);
        snap.beneficiaryCredit = vault.bondCount(PROOF_BENEFICIARY);
        snap.totalCredit = vault.totalBondCount();
        snap.adapterLoose = BOND.balanceOf(address(adapter), Config.DEXFI_BOND_TOKEN_ID);
        snap.receiverLoose = BOND.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID);
        snap.receiverUsdc = USDC.balanceOf(receiver);
        snap.recipientUsdc = USDC.balanceOf(PROOF_YIELD_RECIPIENT);
        snap.delivered = adapter.farmYieldDelivered();
        (snap.adapterStake,) = FARM.userInfo(address(adapter));
        (snap.receiverStake,) = FARM.userInfo(receiver);
        snap.beneficiaryEth = PROOF_BENEFICIARY.balance;
    }

    function _assertMintAttemptEvent(
        Vm.Log[] memory logs,
        uint256 expectedPayment,
        uint256 expectedAmount
    ) private view {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(adapter) || entry.topics.length != 4
                    || entry.topics[0] != MINT_ATTEMPT_EVENT_SIGNATURE
            ) continue;

            assertEq(entry.topics[1], bytes32(uint256(uint160(PROOF_BENEFICIARY))), "event beneficiary");
            assertEq(entry.topics[2], PROOF_ATTEMPT_ID, "event attempt id");
            assertEq(entry.topics[3], bytes32(uint256(uint160(receiver))), "event receiver");
            (uint256 paymentAmount, uint256 bondAmount) = abi.decode(entry.data, (uint256, uint256));
            assertEq(paymentAmount, expectedPayment, "event payment");
            assertEq(bondAmount, expectedAmount, "event amount");
            found = true;
            break;
        }
        assertTrue(found, "MintAttemptExecuted event missing");
    }
}
