// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../../src/Config.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {RiskParams} from "../../src/RiskParams.sol";
import {DirectCallAdapter} from "../../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../../src/interfaces/IRiskParams.sol";
import {MockNavOracle} from "../mocks/MockNavOracle.sol";

interface IR63A2_LiveBond is IDexFiBond {
    function owner() external view returns (address);
    function updateKeeper(address keeper_) external;
    function pause() external;
    function uuidsContains(uint256 uuid) external view returns (bool);
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}

/// @notice Audit round 63, seat A2. The keeper-signature attacks of `R63A2_KeeperSignatureSeat`, run
///         against DexFi's REAL bond bytecode and REAL farm on a Base-mainnet fork.
///
/// @dev HOW A FORK GETS PAST A SIGNATURE IT CANNOT PRODUCE. It does not forge one. The fork pranks
///      the bond's owner (the treasury EOA) into `updateKeeper(testKeeper)`, which moves ONE storage
///      slot. Everything that then judges the signature is the deployed bytecode: the cached EIP-712
///      domain separator, `MINT_TYPEHASH`, `ECDSA.recover`, the owner-or-keeper comparison, the
///      nonce, the uuid set, the farm hand-off. `test_R63A2F_control_...` is the neuter of the
///      technique itself: with the keeper NOT swapped the same signature is refused, naming the live
///      keeper. What this cannot prove is anything about DexFi's BACKEND (what it will sign, for
///      whom, at what price, with which referral code), which only `DexFiMintAttempt.fork.t.sol`
///      touches, with one real payload for one frozen receiver.
///
///      Env-gated like its siblings: `RUN_FORK_TESTS=true`, `BASE_RPC_URL` optional. Read-only
///      against the chain; nothing is broadcast. Unpinned block on purpose (the public endpoint
///      does not serve old state); every run prints the block it read.
contract R63A2_RealBondFork is Test {
    IR63A2_LiveBond internal constant BOND = IR63A2_LiveBond(Config.DEXFI_BOND_NFT);
    IDexFiFarm internal constant FARM = IDexFiFarm(Config.DEXFI_FARM);
    IERC20 internal constant USDC = IERC20(Config.USDC_BASE);

    uint256 internal constant KEEPER_PK = 0xA11CE5EED;
    uint256 internal constant PRICE = 13_754_468_936_004_571;
    uint256 internal constant SECP_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant MINT_TYPEHASH = keccak256(
        "MintDataInput(uint256 uuid,uint256 nonce,address receiver,uint256 amountNfts,uint256 paymentAmount,uint256 deadline)"
    );

    // The live bond's errors, from its verified source.
    bytes4 internal constant SIG_EXPIRED = bytes4(keccak256("SignatureTimeExpired(uint256,uint256)"));
    bytes4 internal constant SIGNER_NOT_KEEPER =
        bytes4(keccak256("MintSignerNotOwnerOrKeeper(address,address,address)"));
    bytes4 internal constant BAD_NONCE = bytes4(keccak256("MintIncorrectReceiverNonce(address,uint256,uint256)"));
    bytes4 internal constant VALUE_LT = bytes4(keccak256("SentValueLtPaymentAmount(uint256,uint256)"));
    bytes4 internal constant UUID_EXISTS = bytes4(keccak256("UUIDAlreadyExist(uint256)"));
    bytes4 internal constant ECDSA_S = bytes4(keccak256("ECDSAInvalidSignatureS(bytes32)"));
    bytes4 internal constant ECDSA_LEN = bytes4(keccak256("ECDSAInvalidSignatureLength(uint256)"));
    bytes4 internal constant ECDSA_BAD = bytes4(keccak256("ECDSAInvalidSignature()"));
    bytes4 internal constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal watcher = makeAddr("watcher");
    address internal yieldSink = makeAddr("yieldSink");
    address internal recoveryRecipient = makeAddr("recoveryRecipient");

    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    bool internal run;
    uint256 internal uuidBase;

    function setUp() public {
        run = vm.envOr("RUN_FORK_TESTS", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        console2.log("R63A2F fork block:", block.number);
        console2.log("R63A2F fork timestamp:", block.timestamp);

        MockNavOracle oracle = new MockNavOracle(25.15e8);
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
            IDexFiBond(address(BOND)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(IDexFiBond(address(BOND)), FARM, USDC, address(vault), admin, yieldSink);
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));

        vm.deal(alice, 10 ether);
        vm.deal(watcher, 10 ether);
        // uuids are global and single-use on the live contract; start far from anything a backend issues.
        uuidBase = uint256(keccak256("R63A2 fork uuid base"));
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────

    function _swapKeeper() internal {
        vm.prank(BOND.owner());
        BOND.updateKeeper(vm.addr(KEEPER_PK));
    }

    function _whitelistAdapter() internal {
        address[] memory a = new address[](1);
        a[0] = address(adapter);
        vm.prank(BOND.owner());
        BOND.addWhitelist(a);
    }

    function _digest(uint256 chainId, IDexFiBond.MintDataInput memory d) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("NFT_BOND"), keccak256("1"), chainId, address(BOND))
        );
        bytes32 structHash = keccak256(
            abi.encode(MINT_TYPEHASH, d.uuid, d.nonce, d.receiver, d.amountNfts, d.paymentAmount, d.deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signed(uint256 uuid, uint256 nonce, address receiver, uint256 bonds, uint256 payment)
        internal
        view
        returns (IDexFiBond.MintDataInput memory d)
    {
        d = IDexFiBond.MintDataInput({
            uuid: uuidBase + uuid,
            nonce: nonce,
            receiver: receiver,
            amountNfts: bonds,
            paymentAmount: payment,
            deadline: block.timestamp + 3 minutes,
            signature: ""
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEEPER_PK, _digest(block.chainid, d));
        d.signature = abi.encodePacked(r, s, v);
    }

    function _mintAs(address who, uint256 value, IDexFiBond.MintDataInput memory d)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(who);
        (ok, ret) = address(BOND).call{value: value}(abi.encodeCall(IDexFiBond.mint, (d)));
    }

    function _staked(address who) internal view returns (uint256 amount) {
        (amount,) = FARM.userInfo(who);
    }

    // ── 0. The domain, read from the chain ───────────────────────────────────────────────────

    function test_R63A2F_domainIsNameVersionChainAndContract_noSalt() public {
        vm.skip(!run);
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt,) =
            BOND.eip712Domain();
        assertEq(fields, hex"0f", "name, version, chainId, verifyingContract; no salt, no extensions");
        assertEq(name, "NFT_BOND");
        assertEq(version, "1");
        assertEq(chainId, 8453);
        assertEq(verifying, address(BOND));
        assertEq(salt, bytes32(0));
        assertEq(BOND.keeper(), Config.DEXFI_MINT_KEEPER, "live keeper is the one Config names");
        console2.log("R63A2F live keeper:", BOND.keeper());
        console2.log("R63A2F live owner :", BOND.owner());
        console2.log("R63A2F live paused:", BOND.paused());
    }

    // ── 1. The control: the technique does not forge anything ────────────────────────────────

    function test_R63A2F_control_withoutTheKeeperSwap_theSameSignatureIsRefusedNamingTheLiveKeeper() public {
        vm.skip(!run);
        address receiver = makeAddr("eoa receiver");
        IDexFiBond.MintDataInput memory d = _signed(1, BOND.nonces(receiver), receiver, 2, 2 * PRICE);
        (bool ok, bytes memory ret) = _mintAs(alice, 2 * PRICE, d);
        assertFalse(ok);
        assertEq(
            ret, abi.encodeWithSelector(SIGNER_NOT_KEEPER, vm.addr(KEEPER_PK), BOND.owner(), Config.DEXFI_MINT_KEEPER)
        );

        _swapKeeper();
        (ok, ret) = _mintAs(alice, 2 * PRICE, d);
        assertTrue(ok, "after the one-slot swap the REAL bytecode accepts a digest built from the published domain");
        assertEq(_staked(receiver), 2, "auto-staked for the receiver at the real farm");
        assertEq(BOND.nonces(receiver), 1);
        assertEq(BOND.nonces(alice), 0, "the caller's nonce is untouched: the nonce is the RECEIVER's");
        assertTrue(BOND.uuidsContains(d.uuid));
        console2.log(
            "R63A2F MEASURED real bytecode accepted a test-keeper signature; staked for receiver:", _staked(receiver)
        );
    }

    // ── 2. Redirect, amount, price ───────────────────────────────────────────────────────────

    function test_R63A2F_rewrittenReceiverAmountOrPrice_refusedByTheRealBond() public {
        vm.skip(!run);
        _swapKeeper();
        address receiver = makeAddr("eoa receiver");

        IDexFiBond.MintDataInput memory d = _signed(1, 0, receiver, 2, 2 * PRICE);
        d.receiver = watcher;
        (bool ok, bytes memory ret) = _mintAs(watcher, 2 * PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), SIGNER_NOT_KEEPER, "redirect");

        d = _signed(1, 0, receiver, 2, 2 * PRICE);
        d.amountNfts = 2000;
        (ok, ret) = _mintAs(watcher, 2 * PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), SIGNER_NOT_KEEPER, "amount");

        d = _signed(1, 0, receiver, 2, 2 * PRICE);
        d.paymentAmount = 1;
        (ok, ret) = _mintAs(watcher, 1, d);
        assertFalse(ok);
        assertEq(bytes4(ret), SIGNER_NOT_KEEPER, "price");

        d = _signed(1, 0, receiver, 2, 2 * PRICE);
        d.deadline += 1 days;
        (ok, ret) = _mintAs(watcher, 2 * PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), SIGNER_NOT_KEEPER, "deadline stretch");
        console2.log(
            "R63A2F MEASURED receiver, amountNfts, paymentAmount and deadline are each bound on the real bytecode"
        );
    }

    // ── 3. Deadline ──────────────────────────────────────────────────────────────────────────

    function test_R63A2F_deadlineBoundaryOnTheRealBond() public {
        vm.skip(!run);
        _swapKeeper();
        address receiver = makeAddr("eoa receiver");
        IDexFiBond.MintDataInput memory d = _signed(1, 0, receiver, 1, PRICE);

        uint256 snap = vm.snapshotState();
        vm.warp(d.deadline);
        (bool ok,) = _mintAs(alice, PRICE, d);
        assertTrue(ok, "deadline == block.timestamp is valid");
        vm.revertToState(snap);

        vm.warp(d.deadline + 1);
        bytes memory ret;
        (ok, ret) = _mintAs(alice, PRICE, d);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(SIG_EXPIRED, d.deadline, d.deadline + 1));
        console2.log("R63A2F MEASURED real bond expiry error selector:");
        console2.logBytes4(bytes4(ret));
    }

    // ── 4. Malleability ──────────────────────────────────────────────────────────────────────

    function test_R63A2F_malleableCompactAndZeroSignatures_refusedByTheRealBond() public {
        vm.skip(!run);
        _swapKeeper();
        address receiver = makeAddr("eoa receiver");
        IDexFiBond.MintDataInput memory d = _signed(1, 0, receiver, 1, PRICE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEEPER_PK, _digest(block.chainid, d));

        d.signature = abi.encodePacked(r, bytes32(SECP_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        (bool ok, bytes memory ret) = _mintAs(alice, PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), ECDSA_S, "high-s twin");

        d.signature = abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
        (ok, ret) = _mintAs(alice, PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), ECDSA_LEN, "EIP-2098 compact");

        d.signature = new bytes(65);
        (ok, ret) = _mintAs(alice, PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), ECDSA_BAD, "ecrecover zero");

        d.signature = abi.encodePacked(r, s, v);
        (ok,) = _mintAs(alice, PRICE, d);
        assertTrue(ok, "none of the refusals spent the uuid or the nonce");
        (ok, ret) = _mintAs(alice, PRICE, d);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(UUID_EXISTS, d.uuid), "replay of the landed payload");
    }

    // ── 5. Chain replay ──────────────────────────────────────────────────────────────────────

    function test_R63A2F_aSignatureForAnotherChainId_isRefusedByTheRealBond() public {
        vm.skip(!run);
        _swapKeeper();
        address receiver = makeAddr("eoa receiver");
        IDexFiBond.MintDataInput memory d = _signed(1, 0, receiver, 1, PRICE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEEPER_PK, _digest(84532, d));
        d.signature = abi.encodePacked(r, s, v);
        (bool ok, bytes memory ret) = _mintAs(alice, PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), SIGNER_NOT_KEEPER, "a Base Sepolia digest does not verify on Base");

        // And the live bytecode REBUILDS its separator if the chain id moves under it (a chain split).
        d = _signed(2, 0, receiver, 1, PRICE); // signed for 8453
        vm.chainId(1);
        (ok, ret) = _mintAs(alice, PRICE, d);
        assertFalse(ok);
        assertEq(bytes4(ret), SIGNER_NOT_KEEPER, "an 8453 digest does not verify once chainid is 1");
    }

    // ── 6. The shared-receiver nonce, on the real bytecode ───────────────────────────────────

    function test_R63A2F_sharedReceiver_secondPendingPayloadDiesOnTheRealBond() public {
        vm.skip(!run);
        _swapKeeper();
        address shared = makeAddr("one shared receiver");
        IDexFiBond.MintDataInput memory a = _signed(1, 0, shared, 1, PRICE);
        IDexFiBond.MintDataInput memory b = _signed(2, 0, shared, 1, PRICE);
        (bool ok,) = _mintAs(watcher, PRICE, b);
        assertTrue(ok);
        bytes memory ret;
        (ok, ret) = _mintAs(alice, PRICE, a);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BAD_NONCE, shared, 1, 0));
        console2.log(
            "R63A2F MEASURED real bond: second pending payload for one receiver dies, MintIncorrectReceiverNonce(shared,1,0)"
        );
    }

    // ── 7. Value mismatch on the real bond ───────────────────────────────────────────────────

    function test_R63A2F_overpaymentStrandsAtTheRealBond_underpaymentIsRefused() public {
        vm.skip(!run);
        _swapKeeper();
        address receiver = makeAddr("eoa receiver");
        IDexFiBond.MintDataInput memory d = _signed(1, 0, receiver, 1, PRICE);
        (bool ok, bytes memory ret) = _mintAs(alice, PRICE - 1, d);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(VALUE_LT, PRICE - 1, PRICE));

        uint256 bondBefore = address(BOND).balance;
        uint256 treasuryBefore = BOND.treasury().balance;
        (ok,) = _mintAs(alice, PRICE + 0.25 ether, d);
        assertTrue(ok);
        assertEq(
            address(BOND).balance - bondBefore, 0.25 ether, "the excess stays at the bond, which has no native rescue"
        );
        assertEq(BOND.treasury().balance - treasuryBefore, PRICE);
        console2.log("R63A2F MEASURED real bond ETH balance before the probe (wei):", bondBefore);
    }

    // ── 8. Recoup's whole path on the real bond and the real farm ────────────────────────────

    function test_R63A2F_depositETH_onTheRealBondAndFarm_underATestKeeper_andTheWatchersFrontRun() public {
        vm.skip(!run);
        _swapKeeper();
        _whitelistAdapter();

        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(1, 0, receiver, 5, 5 * PRICE);

        // (a) clean
        uint256 snap = vm.snapshotState();
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vault.depositETH{value: 5 * PRICE}(attemptId, abi.encode(d));
        console2.log(
            "R63A2F MEASURED depositETH gas on the real bond and farm (test-side gasleft delta):", gasBefore - gasleft()
        );
        assertEq(vault.bondCount(alice), 5);
        assertEq(_staked(address(adapter)), 5, "consolidated under the adapter at the real farm");
        assertEq(_staked(receiver), 0);
        assertEq(BOND.balanceOf(receiver, 0), 0);
        assertEq(BOND.nonces(receiver), 1);
        vm.revertToState(snap);

        // (b) the watcher carries alice's payload to the bond first
        (bool ok,) = _mintAs(watcher, 5 * PRICE, d);
        assertTrue(ok, "msg.sender is not in the digest");
        assertEq(_staked(receiver), 5, "staked for a codeless address");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1));
        vault.depositETH{value: 5 * PRICE}(attemptId, abi.encode(d));
        assertEq(alice.balance, 10 ether);

        // (c) and governance collects what the watcher paid for
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, attemptId, payable(recoveryRecipient));
        console2.log(
            "R63A2F MEASURED after recovery: recipient loose bonds, adapter stake:",
            BOND.balanceOf(recoveryRecipient, 0),
            _staked(address(adapter))
        );
        assertEq(_staked(receiver), 0);
    }

    // ── 9. A DexFi pause reaches the depositor as Recoup's own selector ──────────────────────

    function test_R63A2F_aDexFiPauseSurfacesAsEnforcedPauseThroughDepositETH() public {
        vm.skip(!run);
        _swapKeeper();
        _whitelistAdapter();
        bytes32 attemptId = keccak256("alice attempt 1");
        address receiver = adapter.predictMintReceiver(alice, attemptId);
        IDexFiBond.MintDataInput memory d = _signed(1, 0, receiver, 5, 5 * PRICE);
        vm.prank(BOND.owner());
        BOND.pause();
        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call{value: 5 * PRICE}(abi.encodeCall(vault.depositETH, (attemptId, abi.encode(d))));
        assertFalse(ok);
        assertEq(bytes4(ret), ENFORCED_PAUSE);
        assertFalse(vault.paused(), "Recoup is not paused");
    }
}
