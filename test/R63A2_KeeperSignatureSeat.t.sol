// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

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
import {R63A2_SigningBond} from "./R63A2_SigningBond.sol";

/// @dev A receiver that, on its ERC-1155 acceptance callback, tries to push a SECOND mint through the
///      bond it is being minted by. Works against either bond because both expose the same selector.
contract R63A2_ReentrantReceiver is IERC1155Receiver {
    address public bond;
    bytes public nested;
    bool public nestedOk;
    bytes public nestedRevert;

    function arm(address bond_, bytes calldata nestedCall) external {
        bond = bond_;
        nested = nestedCall;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (nested.length != 0) {
            bytes memory call_ = nested;
            delete nested;
            (nestedOk, nestedRevert) = bond.call(call_);
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice Audit round 63, seat A2 (COLD): the DexFi keeper's signature seat at mint. Every test runs
///         Recoup's real `CollateralVault` and `DirectCallAdapter` against `R63A2_SigningBond`, a
///         port of the live bond's `mint` that KEEPS the EIP-712 check `MockBond` elides. The keeper
///         here is a test key; the fork suite `R63A2_RealBondFork` repeats the attacks on the real
///         bytecode. Each test says whether the answer is a property of the MOCK, of Recoup, or of
///         DexFi's contract.
contract R63A2_KeeperSignatureSeat is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant PRICE = 13_754_468_936_004_571; // wei per bond, the figure round 60 read
    uint256 internal constant KEEPER_PK = 0xA11CE5EED;
    uint256 internal constant STRANGER_PK = 0xBADBAD;
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant MINT_TYPEHASH = keccak256(
        "MintDataInput(uint256 uuid,uint256 nonce,address receiver,uint256 amountNfts,uint256 paymentAmount,uint256 deadline)"
    );
    // secp256k1 group order, for the malleability probe.
    uint256 internal constant SECP_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address internal admin = makeAddr("admin");
    address internal dexfiOwner = makeAddr("dexfiOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal watcher = makeAddr("watcher");
    address internal yieldSink = makeAddr("yieldSink");
    address internal treasury = makeAddr("dexfiTreasury");
    address internal keeperAddr;

    MockUSDC internal usdc;
    R63A2_SigningBond internal bond;
    MockFarm internal farm;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function setUp() public {
        keeperAddr = vm.addr(KEEPER_PK);
        usdc = new MockUSDC();
        vm.prank(dexfiOwner);
        bond = new R63A2_SigningBond(keeperAddr, treasury);
        farm = new MockFarm(MockBond(address(bond)), usdc);
        vm.startPrank(dexfiOwner);
        bond.updateRewardPool(address(farm));
        bond.setWhitelisted(address(farm), true);
        vm.stopPrank();

        MockNavOracle oracle = new MockNavOracle(NAV);
        RiskParams riskParams = new RiskParams(
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
        vm.prank(dexfiOwner);
        bond.setWhitelisted(address(adapter), true);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(watcher, 10 ether);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────

    function _domainSeparator(address verifying, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("NFT_BOND"), keccak256("1"), chainId, verifying));
    }

    function _digest(address verifying, uint256 chainId, IDexFiBond.MintDataInput memory d)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(MINT_TYPEHASH, d.uuid, d.nonce, d.receiver, d.amountNfts, d.paymentAmount, d.deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(verifying, chainId), structHash));
    }

    function _signed(uint256 pk, uint256 uuid, uint256 nonce, address receiver, uint256 bonds, uint256 payment)
        internal
        view
        returns (IDexFiBond.MintDataInput memory d)
    {
        d = IDexFiBond.MintDataInput({
            uuid: uuid,
            nonce: nonce,
            receiver: receiver,
            amountNfts: bonds,
            paymentAmount: payment,
            deadline: block.timestamp + 3 minutes,
            signature: ""
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(address(bond), block.chainid, d));
        d.signature = abi.encodePacked(r, s, v);
    }

    // ── 1. What is signed, and the happy path with the check switched ON ─────────────────────

    function test_R63A2_whatIsSigned_andTheWholeDepositPathPassesARealSignatureCheck() public {
        assertEq(
            bond.domainSeparator(),
            _domainSeparator(address(bond), block.chainid),
            "domain = name,version,chainId,verifyingContract"
        );
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 72, 72 * PRICE);

        vm.prank(alice);
        vault.depositETH{value: 72 * PRICE}(attemptId, abi.encode(d));

        assertEq(vault.bondCount(alice), 72);
        assertEq(treasury.balance, 72 * PRICE);
        assertEq(bond.nonces(receiver), 1, "the RECEIVER's nonce moved, nobody else's");
        assertEq(bond.nonces(alice), 0);
        assertEq(bond.nonces(address(adapter)), 0);
        assertEq(bond.nonces(address(vault)), 0);
        console2.log("R63A2 MEASURED signed fields: uuid, nonce, receiver, amountNfts, paymentAmount, deadline");
        console2.log(
            "R63A2 MEASURED NOT signed: msg.sender, tx.origin, beneficiary, attemptId, referral code, msg.value"
        );
        console2.log("R63A2 MEASURED receiver nonce after mint:", bond.nonces(receiver));
    }

    // ── 2. A signature for X's receiver, carried by Y ────────────────────────────────────────

    /// @notice Y cannot take X's mint through Recoup: the adapter derives the receiver from
    ///         `msg.sender`, so X's payload names a receiver Y's deposit does not derive. RECOUP's
    ///         property (`MintReceiverMismatch`), independent of the bond.
    function test_R63A2_payloadForAlice_throughBobsDeposit_isRefusedByRecoup() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address aliceReceiver = adapter.predictMintReceiver(alice, attemptId);
        address bobReceiver = adapter.predictMintReceiver(bob, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, aliceReceiver, 10, 10 * PRICE);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintReceiverMismatch.selector, bobReceiver, aliceReceiver)
        );
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(d));
        assertEq(bob.balance, 10 ether, "bob keeps his ETH");
    }

    /// @notice Y cannot REDIRECT either: rewriting `receiver` changes the digest, so the recovered
    ///         signer is a stranger. DEXFI's property; the MOCK accepts the rewritten payload.
    function test_R63A2_rewritingTheReceiver_recoversAStranger_andTheMockWouldHaveMintedIt() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address aliceReceiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, aliceReceiver, 10, 10 * PRICE);
        d.receiver = watcher;

        vm.prank(watcher);
        (bool ok, bytes memory ret) = address(bond).call{value: 10 * PRICE}(abi.encodeCall(R63A2_SigningBond.mint, (d)));
        assertFalse(ok);
        assertEq(bytes4(ret), R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector);

        // The same rewritten payload against MockBond: minted to the watcher, no questions asked.
        MockBond mock = new MockBond();
        vm.prank(watcher);
        mock.mint{value: 10 * PRICE}(d);
        assertEq(mock.balanceOf(watcher, 0), 10, "MOCK: a redirected payload mints");
        console2.log(
            "R63A2 MEASURED redirect: signing bond refuses (MintSignerNotOwnerOrKeeper), MockBond mints",
            mock.balanceOf(watcher, 0)
        );
    }

    /// @notice The bearer half. `msg.sender` is not in the digest, so the watcher CAN land alice's
    ///         payload at the bond directly. He pays the whole signed price, the bonds stake for
    ///         alice's counterfactual receiver, and alice's deposit then reverts with her ETH intact.
    ///         DEXFI's property (no caller binding) meeting RECOUP's nonce-zero rule.
    function test_R63A2_watcherLandsAlicesPayloadDirectly_paysForIt_andBurnsHerAttempt() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);

        vm.prank(watcher);
        bond.mint{value: 10 * PRICE}(d);
        assertEq(watcher.balance, 10 ether - 10 * PRICE, "the watcher paid the full signed price");
        assertEq(farm.staked(receiver), 10, "staked for a codeless address only the adapter can deploy");
        assertEq(farm.staked(watcher), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1));
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(d));
        assertEq(alice.balance, 10 ether, "alice loses gas only");
        console2.log("R63A2 MEASURED grief cost to watcher (wei):", 10 * PRICE);
    }

    // ── 3. Wrong amount, wrong price ─────────────────────────────────────────────────────────

    function test_R63A2_tamperedAmountOrPrice_isADifferentDigest() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);

        IDexFiBond.MintDataInput memory more = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);
        more.amountNfts = 1000;
        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call{value: 10 * PRICE}(abi.encodeCall(vault.depositETH, (attemptId, abi.encode(more))));
        assertFalse(ok);
        assertEq(bytes4(ret), R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector, "more bonds for the same money");

        IDexFiBond.MintDataInput memory cheaper = _signed(KEEPER_PK, 2, 0, receiver, 10, 10 * PRICE);
        cheaper.paymentAmount = 1;
        vm.prank(alice);
        (ok, ret) = address(vault).call{value: 1}(abi.encodeCall(vault.depositETH, (attemptId, abi.encode(cheaper))));
        assertFalse(ok);
        assertEq(bytes4(ret), R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector, "same bonds for one wei");

        // MockBond takes both.
        MockBond mock = new MockBond();
        vm.prank(alice);
        mock.mint{value: 1}(cheaper);
        assertEq(mock.balanceOf(receiver, 0), 10, "MOCK: ten bonds for one wei");
    }

    // ── 4. The three-minute deadline ─────────────────────────────────────────────────────────

    function test_R63A2_deadline_lastValidSecondAndTheFirstDeadOne_andTheErrorTheUserGets() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);

        uint256 snap = vm.snapshotState();
        vm.warp(d.deadline); // deadline == block.timestamp is still valid on both bonds
        vm.prank(alice);
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(d));
        assertEq(vault.bondCount(alice), 10);
        vm.revertToState(snap);

        vm.warp(d.deadline + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(R63A2_SigningBond.SignatureTimeExpired.selector, d.deadline, d.deadline + 1)
        );
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(d));
        assertEq(alice.balance, 10 ether, "nothing left her wallet");
        assertEq(receiver.code.length, 0, "the clone deployment rolled back, so the same attempt id is reusable");
        assertEq(bond.nonces(receiver), 0);

        // The selectors a wallet would hand the webapp. The app's error map was written against
        // MockBond's names; these are the live bond's.
        console2.log("R63A2 MEASURED live SignatureTimeExpired(uint256,uint256):");
        console2.logBytes4(R63A2_SigningBond.SignatureTimeExpired.selector);
        console2.log("R63A2 MEASURED mock DeadlineExpired(uint256):");
        console2.logBytes4(MockBond.DeadlineExpired.selector);
        console2.log("R63A2 MEASURED live MintIncorrectReceiverNonce(address,uint256,uint256):");
        console2.logBytes4(R63A2_SigningBond.MintIncorrectReceiverNonce.selector);
        console2.log("R63A2 MEASURED mock InvalidNonce(address,uint256,uint256):");
        console2.logBytes4(MockBond.InvalidNonce.selector);
        console2.log("R63A2 MEASURED live SentValueLtPaymentAmount(uint256,uint256):");
        console2.logBytes4(R63A2_SigningBond.SentValueLtPaymentAmount.selector);
        console2.log("R63A2 MEASURED live MintSignerNotOwnerOrKeeper(address,address,address):");
        console2.logBytes4(R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector);

        // A fresh signature for the SAME attempt lands: expiry costs a round trip, not an attempt id.
        IDexFiBond.MintDataInput memory again = _signed(KEEPER_PK, 2, 0, receiver, 10, 10 * PRICE);
        vm.prank(alice);
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(again));
        assertEq(vault.bondCount(alice), 10);
    }

    // ── 5. Whose nonce is it (the shared-nonce question, PRD section 7 and the old ask #10) ──

    /// @notice On THIS tree the receiver is one clone per (beneficiary, attemptId), so the nonce DexFi
    ///         signs is that clone's and is always zero. Two users' pending payloads, and one user's
    ///         two pending attempts, land in any order. RECOUP's property.
    function test_R63A2_pendingMintsOfTwoUsers_andTwoAttemptsOfOne_landInAnyOrder() public {
        bytes32 a1 = keccak256("alice attempt 1");
        bytes32 a2 = keccak256("alice attempt 2");
        bytes32 b1 = keccak256("bob attempt 1");
        IDexFiBond.MintDataInput memory pa1 =
            _signed(KEEPER_PK, 1, 0, adapter.predictMintReceiver(alice, a1), 3, 3 * PRICE);
        IDexFiBond.MintDataInput memory pb1 =
            _signed(KEEPER_PK, 2, 0, adapter.predictMintReceiver(bob, b1), 5, 5 * PRICE);
        IDexFiBond.MintDataInput memory pa2 =
            _signed(KEEPER_PK, 3, 0, adapter.predictMintReceiver(alice, a2), 7, 7 * PRICE);

        // Signed in the order a1, b1, a2; landed a2, b1, a1.
        vm.prank(alice);
        vault.depositETH{value: 7 * PRICE}(a2, abi.encode(pa2));
        vm.prank(bob);
        vault.depositETH{value: 5 * PRICE}(b1, abi.encode(pb1));
        vm.prank(alice);
        vault.depositETH{value: 3 * PRICE}(a1, abi.encode(pa1));

        assertEq(vault.bondCount(alice), 10);
        assertEq(vault.bondCount(bob), 5);
        assertEq(bond.nonces(address(adapter)), 0, "the shared counter the PRD worries about never moves");
        console2.log(
            "R63A2 MEASURED three pending payloads, all nonce 0, landed in reverse order: alice, bob =",
            vault.bondCount(alice),
            vault.bondCount(bob)
        );
    }

    /// @notice The COUNTERFACTUAL the PRD sentence still describes: one shared receiver. Two users'
    ///         payloads are both signed at the receiver's current nonce; whichever lands second is
    ///         dead, and a later-signed payload cannot land before an earlier one. DEXFI's property,
    ///         and it is why the per-attempt clone exists.
    function test_R63A2_counterfactual_sharedReceiver_secondPendingPayloadDies_andOrderIsForced() public {
        address shared = makeAddr("one shared receiver");
        IDexFiBond.MintDataInput memory forAlice = _signed(KEEPER_PK, 1, 0, shared, 3, 3 * PRICE);
        IDexFiBond.MintDataInput memory forBob = _signed(KEEPER_PK, 2, 0, shared, 5, 5 * PRICE);
        IDexFiBond.MintDataInput memory next = _signed(KEEPER_PK, 3, 1, shared, 7, 7 * PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(R63A2_SigningBond.MintIncorrectReceiverNonce.selector, shared, 0, 1));
        bond.mint{value: 7 * PRICE}(next); // signed at nonce 1, cannot go first

        vm.prank(bob);
        bond.mint{value: 5 * PRICE}(forBob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(R63A2_SigningBond.MintIncorrectReceiverNonce.selector, shared, 1, 0));
        bond.mint{value: 3 * PRICE}(forAlice); // bob landed first; alice's signature is dead for good
        assertEq(alice.balance, 10 ether);
    }

    // ── 6. Malleability, ecrecover zero, junk signatures ─────────────────────────────────────

    function test_R63A2_malleableCompactZeroAndStrangerSignatures_allRefused() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEEPER_PK, _digest(address(bond), block.chainid, d));

        // (a) the high-s twin of a valid signature
        bytes32 sHigh = bytes32(SECP_N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        d.signature = abi.encodePacked(r, sHigh, vFlip);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        bond.mint{value: 10 * PRICE}(d);

        // (b) EIP-2098 compact form, 64 bytes
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        d.signature = abi.encodePacked(r, vs);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        bond.mint{value: 10 * PRICE}(d);

        // (c) v in {0,1}
        d.signature = abi.encodePacked(r, s, uint8(v - 27));
        vm.prank(alice);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        bond.mint{value: 10 * PRICE}(d);

        // (d) sixty-five zero bytes: ecrecover answers the zero address, which must not pass as anyone
        d.signature = new bytes(65);
        vm.prank(alice);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        bond.mint{value: 10 * PRICE}(d);

        // (e) empty, which is what every MockBond fixture in this tree sends
        d.signature = "";
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        bond.mint{value: 10 * PRICE}(d);

        // (f) a well-formed signature by somebody who is not the keeper
        IDexFiBond.MintDataInput memory byStranger = _signed(STRANGER_PK, 1, 0, receiver, 10, 10 * PRICE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector, vm.addr(STRANGER_PK), dexfiOwner, keeperAddr
            )
        );
        bond.mint{value: 10 * PRICE}(byStranger);

        // The original still lands after all six: none of them spent the uuid or the nonce.
        d.signature = abi.encodePacked(r, s, v);
        vm.prank(alice);
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(d));
        assertEq(vault.bondCount(alice), 10);
    }

    // ── 7. Replay across chains and across contracts ─────────────────────────────────────────

    function test_R63A2_replayOnAnotherChainOrAnotherBond_recoversAStranger() public {
        address receiver = makeAddr("eoa receiver");
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);

        // Same contract address, another chain id (a fork of the chain, or a redeploy at the same
        // address elsewhere). OpenZeppelin's EIP712 rebuilds the separator when chainid moves.
        uint256 snap = vm.snapshotState();
        vm.chainId(84532);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(bond).call{value: 10 * PRICE}(abi.encodeCall(bond.mint, (d)));
        assertFalse(ok);
        assertEq(bytes4(ret), R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector);
        vm.revertToState(snap);

        // Same chain, a second bond with the same keeper (DexFi's "Migration" naming says this exists).
        vm.prank(dexfiOwner);
        R63A2_SigningBond other = new R63A2_SigningBond(keeperAddr, treasury);
        vm.prank(alice);
        (ok, ret) = address(other).call{value: 10 * PRICE}(abi.encodeCall(other.mint, (d)));
        assertFalse(ok);
        assertEq(bytes4(ret), R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector);

        vm.prank(alice);
        bond.mint{value: 10 * PRICE}(d);
        assertEq(farm.staked(receiver), 10, "and it is good exactly where it was signed for");
    }

    // ── 8. ETH value mismatch and the refund path ────────────────────────────────────────────

    function test_R63A2_valueMismatch_directOverpaymentStrands_recoupRefusesBothDirections() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.PaymentMismatch.selector, 10 * PRICE, 10 * PRICE + 1));
        vault.depositETH{value: 10 * PRICE + 1}(attemptId, abi.encode(d));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.PaymentMismatch.selector, 10 * PRICE, 10 * PRICE - 1));
        vault.depositETH{value: 10 * PRICE - 1}(attemptId, abi.encode(d));
        assertEq(alice.balance, 10 ether);

        // Bare bond, the path a wallet not using Recoup takes: no refund, no rescue function.
        address eoa = makeAddr("eoa receiver");
        IDexFiBond.MintDataInput memory bare = _signed(KEEPER_PK, 2, 0, eoa, 10, 10 * PRICE);
        vm.prank(bob);
        bond.mint{value: 10 * PRICE + 0.5 ether}(bare);
        assertEq(address(bond).balance, 0.5 ether, "DEXFI: the excess stays at the bond");
        assertEq(treasury.balance, 10 * PRICE);
    }

    // ── 9. Reentrancy on the acceptance callback ─────────────────────────────────────────────

    /// @notice With a reward pool set (the live state) the bond never calls the receiver at all, so
    ///         there is no acceptance callback to reenter from. With the pool UNSET (one owner call
    ///         at DexFi) the receiver's hook runs mid-mint. The live bond is `nonReentrant`;
    ///         `MockBond` is not, so the mock accepts a nested mint the live bond refuses.
    function test_R63A2_acceptanceCallback_nestedMintRefusedByTheGuard_acceptedByTheMock() public {
        vm.prank(dexfiOwner);
        bond.updateRewardPool(address(0));
        R63A2_ReentrantReceiver evil = new R63A2_ReentrantReceiver();
        IDexFiBond.MintDataInput memory outer = _signed(KEEPER_PK, 1, 0, address(evil), 1, PRICE);
        IDexFiBond.MintDataInput memory inner = _signed(KEEPER_PK, 2, 1, address(evil), 1, 0);
        evil.arm(address(bond), abi.encodeCall(R63A2_SigningBond.mint, (inner)));
        vm.prank(watcher);
        bond.mint{value: PRICE}(outer);
        assertFalse(evil.nestedOk(), "signing bond: nested mint refused");
        assertEq(bytes4(evil.nestedRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(bond.balanceOf(address(evil), 0), 1);

        MockBond mock = new MockBond();
        R63A2_ReentrantReceiver evil2 = new R63A2_ReentrantReceiver();
        IDexFiBond.MintDataInput memory mOuter = outer;
        mOuter.receiver = address(evil2);
        IDexFiBond.MintDataInput memory mInner = inner;
        mInner.receiver = address(evil2);
        // The mock bumps the nonce BEFORE the callback too, so the nested payload carries nonce 1 (as signed).
        evil2.arm(
            address(mock),
            abi.encodeWithSignature("mint((uint256,uint256,address,uint256,uint256,uint256,bytes))", mInner)
        );
        vm.prank(watcher);
        mock.mint{value: PRICE}(mOuter);
        assertTrue(evil2.nestedOk(), "MOCK: the nested mint went through");
        assertEq(mock.balanceOf(address(evil2), 0), 2);
        console2.log(
            "R63A2 MEASURED nested mint from the acceptance hook: signing bond refused, MockBond minted",
            mock.balanceOf(address(evil2), 0)
        );
    }

    /// @notice The same pool-unset state through Recoup: the clone's hook is `view` and accepts only
    ///         the bond, the units land loose at the clone and the hand-off still completes.
    function test_R63A2_poolUnset_looseMintAtTheClone_stillCompletesUnderARealSignature() public {
        vm.prank(dexfiOwner);
        bond.updateRewardPool(address(0));
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);
        vm.prank(alice);
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(d));
        assertEq(vault.bondCount(alice), 10);
        assertEq(farm.staked(address(adapter)), 10);
        assertEq(bond.balanceOf(receiver, 0), 0);
    }

    // ── 10. A pause at DexFi, and a keeper rotation, as the depositor meets them ─────────────

    function test_R63A2_dexfiPause_andKeeperRotation_bubbleThroughDepositETH() public {
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 10, 10 * PRICE);

        uint256 snap = vm.snapshotState();
        vm.prank(dexfiOwner);
        bond.pause();
        vm.prank(alice);
        // The SAME selector Recoup's own vault raises when Recoup is paused.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositETH{value: 10 * PRICE}(attemptId, abi.encode(d));
        assertFalse(vault.paused(), "Recoup is NOT paused; the revert came from DexFi's bond");
        vm.revertToState(snap);

        vm.prank(dexfiOwner);
        bond.updateKeeper(makeAddr("rotated keeper"));
        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call{value: 10 * PRICE}(abi.encodeCall(vault.depositETH, (attemptId, abi.encode(d))));
        assertFalse(ok);
        assertEq(
            bytes4(ret),
            R63A2_SigningBond.MintSignerNotOwnerOrKeeper.selector,
            "an in-flight payload dies with the old keeper"
        );
    }

    // ── 11. What the keeper's key is worth to Recoup ─────────────────────────────────────────

    /// @notice Nothing in Recoup looks at `paymentAmount` beyond `msg.value == paymentAmount`, and
    ///         the vault credits `amountNfts` at NAV. So whoever holds the KEEPER key (a hot key: it
    ///         signs on demand behind a public API, and on chain it has never sent a transaction)
    ///         turns one wei into collateral. Trust in DexFi, but in a different key from the owner
    ///         EOA the risk register names.
    function test_R63A2_aKeeperSignedOneWeiPayload_isFullCollateralAtNav() public {
        bytes32 attemptId = keccak256("thief attempt");
        address receiver = adapter.predictMintReceiver(watcher, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(KEEPER_PK, 1, 0, receiver, 1_000_000, 1);
        vm.prank(watcher);
        vault.depositETH{value: 1}(attemptId, abi.encode(d));
        assertEq(vault.bondCount(watcher), 1_000_000);
        uint256 value = vault.collateralValue(watcher);
        console2.log("R63A2 MEASURED one wei bought bonds:", vault.bondCount(watcher));
        console2.log("R63A2 MEASURED collateralValue (USDC 6dp):", value);
        console2.log(
            "R63A2 MEASURED per-account borrow cap (USDC 6dp):", uint256(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
        );
        console2.log("R63A2 MEASURED global borrow cap (USDC 6dp):", uint256(Config.DEFAULT_GLOBAL_BORROW_CAP));
        assertGt(value, uint256(Config.DEFAULT_GLOBAL_BORROW_CAP), "one payload outruns the global cap");
    }
}
