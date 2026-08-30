// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {MintAttemptReceiver} from "../src/MintAttemptReceiver.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice A6 / round 34, task 2. Costs the attempt-id nonce-bump grief end to end and probes
///         whether `MintAttemptAlreadyDeployed` is reachable by anyone but governance.
///         Standalone fixture on purpose: subclassing `CollateralVaultTest` would inherit its
///         whole suite and make the test count meaningless.
contract A6MintAttemptGriefTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;

    address internal admin = makeAddr("admin");
    address internal victim = makeAddr("victim");
    address internal griefer = makeAddr("griefer");
    address internal recoveryRecipient = makeAddr("recoveryRecipient");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    RiskParams internal riskParams;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);
        riskParams = _deployRiskParams(admin);
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
        vm.deal(victim, 100 ether);
        vm.deal(griefer, 100 ether);
    }

    function _mintData(address receiver, uint256 uuid, uint256 amountNfts, uint256 payment)
        internal
        view
        returns (IDexFiBond.MintDataInput memory)
    {
        return IDexFiBond.MintDataInput({
            uuid: uuid,
            nonce: 0,
            receiver: receiver,
            amountNfts: amountNfts,
            paymentAmount: payment,
            deadline: block.timestamp + 3 minutes, // DexFi's real payload window
            signature: ""
        });
    }

    // ── The grief, executed ──────────────────────────────────────────────────

    /// @notice THE POC. A griefer who learns (victim, attemptId) mints ONE bond to the victim's
    ///         derived receiver through DexFi's ordinary self-serve signed path. That bumps
    ///         `nonces[receiver]`, and the victim's `depositETH` is then permanently dead for
    ///         that attemptId.
    function test_A6_griefer_permanentlyBurnsOneAttemptId() public {
        bytes32 attemptId = keccak256("victim's CSPRNG output, leaked");
        address receiver = adapter.predictMintReceiver(victim, attemptId);

        // The griefer needs no Recoup permission and no DexFi key: `predictMintReceiver`
        // is a public view and DexFi's signing API takes an arbitrary `receiver`.
        assertEq(bond.nonces(receiver), 0, "attempt starts unused");

        vm.prank(griefer);
        bond.mint{value: 1 ether}(_mintData(receiver, uint256(keccak256("griefer uuid")), 1, 1 ether));

        assertEq(bond.nonces(receiver), 1, "GRIEF LANDED: the attempt receiver's nonce is burned");

        // The victim's deposit, with a correctly signed payload for the same attempt, is dead.
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1)
        );
        vault.depositETH{value: 5 ether}(
            attemptId, abi.encode(_mintData(receiver, uint256(attemptId), 40, 5 ether))
        );
    }

    /// @notice The cost side. The griefer's bond is auto-staked at the receiver, and governance
    ///         recovers the whole position - bond and farm yield - to an address of its choosing.
    ///         The grief is a donation.
    function test_A6_grief_isRecoveredByGovernance() public {
        bytes32 attemptId = keccak256("attempt");
        address receiver = adapter.predictMintReceiver(victim, attemptId);

        vm.prank(griefer);
        bond.mint{value: 1 ether}(_mintData(receiver, 1, 1, 1 ether));
        assertEq(farm.staked(receiver), 1, "griefer's bond is staked at the counterfactual receiver");

        farm.setPendingYield(receiver, 7e6); // $7 accrued while it sat there

        uint256 deliveredBefore = adapter.farmYieldDelivered();
        vm.prank(admin);
        (uint256 bonds, uint256 swept,,,,) =
            adapter.recoverMintAttempt(victim, attemptId, payable(recoveryRecipient));

        assertEq(bonds, 1, "the donated bond is recovered");
        assertEq(bond.bondBalance(recoveryRecipient), 1, "and it leaves for the governance recipient");
        assertEq(bond.bondBalance(address(adapter)), 0, "never pooled with credited collateral");
        assertGt(swept, 0, "and its farm yield is swept");
        assertEq(adapter.farmYieldDelivered() - deliveredBefore, swept, "watermark moves by the sweep");
        assertEq(farm.staked(receiver), 0, "position fully unwound");
    }

    /// @notice The victim's remedy costs one DexFi API round trip, not a lost deposit: a FRESH
    ///         attemptId derives a different receiver with an untouched nonce.
    function test_A6_victimRecoversWithAFreshAttemptId() public {
        bytes32 burned = keccak256("burned");
        address burnedReceiver = adapter.predictMintReceiver(victim, burned);
        vm.prank(griefer);
        bond.mint{value: 1 ether}(_mintData(burnedReceiver, 1, 1, 1 ether));

        bytes32 fresh = keccak256("fresh");
        address freshReceiver = adapter.predictMintReceiver(victim, fresh);
        assertTrue(freshReceiver != burnedReceiver, "a different attemptId is a different receiver");
        assertEq(bond.nonces(freshReceiver), 0, "untouched");

        vm.prank(victim);
        vault.depositETH{value: 5 ether}(
            fresh, abi.encode(_mintData(freshReceiver, uint256(fresh), 40, 5 ether))
        );
        assertEq(vault.bondCount(victim), 40, "deposit succeeds on the fresh attempt");
    }

    /// @notice The attemptId is bound to the beneficiary, so a griefer cannot poison an attempt
    ///         by front-running with the SAME id under their own address.
    function test_A6_attemptIdIsBoundToTheBeneficiary() public {
        bytes32 attemptId = keccak256("shared id");
        address victimReceiver = adapter.predictMintReceiver(victim, attemptId);
        address grieferReceiver = adapter.predictMintReceiver(griefer, attemptId);
        assertTrue(victimReceiver != grieferReceiver, "salt binds the beneficiary");

        vm.prank(griefer);
        bond.mint{value: 1 ether}(_mintData(grieferReceiver, 1, 1, 1 ether));
        assertEq(bond.nonces(victimReceiver), 0, "the victim's attempt is untouched");
    }

    // ── MintAttemptAlreadyDeployed reachability ──────────────────────────────

    /// @notice A stranger cannot put code at the receiver. `cloneDeterministic` is CREATE2 from
    ///         the ADAPTER, so the address is unreachable by any other deployer, and the only
    ///         alternative - CREATE from the address itself - needs a key nobody holds.
    function test_A6_strangerCannotDeployAtTheAttemptReceiver() public {
        bytes32 attemptId = keccak256("attempt");
        address receiver = adapter.predictMintReceiver(victim, attemptId);
        assertEq(receiver.code.length, 0, "counterfactual");

        // Deploying the same ERC-1167 from a different deployer with the same salt lands
        // somewhere else entirely: CREATE2 hashes the deployer in.
        vm.prank(griefer);
        address elsewhere = _cloneFrom(address(adapter.mintReceiverImplementation()), _salt(victim, attemptId));
        assertTrue(elsewhere != receiver, "a stranger's CREATE2 cannot reach the adapter's address");
        assertEq(receiver.code.length, 0, "receiver still has no code");
    }

    /// @notice Repeating a spent attempt hits AlreadyUsed, not AlreadyDeployed - the nonce check
    ///         is ordered first, so the deployed-clone guard is not the one that fires.
    function test_A6_repeatedAttemptHitsAlreadyUsedNotAlreadyDeployed() public {
        bytes32 attemptId = keccak256("attempt");
        address receiver = adapter.predictMintReceiver(victim, attemptId);
        vm.prank(victim);
        vault.depositETH{value: 5 ether}(
            attemptId, abi.encode(_mintData(receiver, uint256(attemptId), 40, 5 ether))
        );
        assertGt(receiver.code.length, 0, "clone deployed");

        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1)
        );
        vault.depositETH{value: 5 ether}(
            attemptId, abi.encode(_mintData(receiver, uint256(keccak256("second uuid")), 40, 5 ether))
        );
    }

    /// @notice The ONE reachable path to MintAttemptAlreadyDeployed, and it needs the owner key:
    ///         governance recovers a donated position at a receiver whose nonce is still zero
    ///         (only `mintSingle`, i.e. DexFi's owner, can create that state), which deploys the
    ///         clone; a later mint attempt on the same id then trips the code guard.
    function test_A6_alreadyDeployed_needsGovernanceFirst() public {
        bytes32 attemptId = keccak256("attempt");
        address receiver = adapter.predictMintReceiver(victim, attemptId);

        // DexFi's owner-only free mint: bonds at the receiver, nonce untouched.
        bond.mint(receiver, 1);
        assertEq(bond.nonces(receiver), 0, "nonce still zero - preflight would still pass");

        vm.prank(admin);
        adapter.recoverMintAttempt(victim, attemptId, payable(recoveryRecipient));
        assertGt(receiver.code.length, 0, "governance recovery deployed the clone");

        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyDeployed.selector, receiver)
        );
        vault.depositETH{value: 5 ether}(
            attemptId, abi.encode(_mintData(receiver, uint256(attemptId), 40, 5 ether))
        );
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _salt(address beneficiary, bytes32 attemptId) internal view returns (bytes32) {
        return keccak256(abi.encode(adapter.MINT_ATTEMPT_DOMAIN(), beneficiary, attemptId));
    }

    function _cloneFrom(address impl, bytes32 salt) internal returns (address deployed) {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", bytes20(impl), hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }

    // -- the retry window, which is where the "one block" prior fails --------

    /// @notice FALSIFIES the "needs an off-chain round trip inside one block" prior. A deposit
    ///         that REVERTS is still in a block and its calldata - including attemptId - is
    ///         public. The victim cannot rotate attemptId on retry without a new DexFi
    ///         signature, because the signed payload binds `receiver`, which IS the attemptId.
    ///         So the natural retry reuses a now-public id, and the griefer has the whole
    ///         remaining payload deadline (~3 minutes on DexFi, ~90 Base blocks) to burn it.
    function test_A6_revertedDepositLeaksTheAttemptIdAndTheRetryIsGriefable() public {
        bytes32 attemptId = keccak256("victim csprng");
        address receiver = adapter.predictMintReceiver(victim, attemptId);
        bytes memory payload = abi.encode(_mintData(receiver, uint256(attemptId), 40, 5 ether));

        // 1. The first attempt reverts for a reason unrelated to the attempt itself.
        //    (Pause is the cleanest model; an out-of-gas or a momentarily missing adapter
        //    whitelist entry - today's live mainnet state - leaks identically.)
        vm.prank(admin);
        vault.pause();
        vm.prank(victim);
        vm.expectRevert();
        vault.depositETH{value: 5 ether}(attemptId, payload);
        vm.prank(admin);
        vault.unpause();

        // 2. The attempt is still LIVE after the revert - which is exactly what makes the
        //    natural retry attractive, and exactly what the griefer needs.
        assertEq(bond.nonces(receiver), 0, "a reverted deposit consumes nothing");

        // 3. The griefer, having read attemptId out of the reverted transaction's calldata,
        //    burns it well inside the payload deadline.
        vm.warp(block.timestamp + 60);
        vm.prank(griefer);
        bond.mint{value: 1 ether}(_mintData(receiver, uint256(keccak256("g")), 1, 1 ether));

        // 4. The retry of the SAME payload - the only retry available without a new
        //    signature - is dead.
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1)
        );
        vault.depositETH{value: 5 ether}(attemptId, payload);
    }

    /// @notice CONTROL for the test above: with no griefer, the identical revert-then-retry
    ///         sequence succeeds. Without this the test above would pass even if the retry
    ///         were broken for some unrelated reason.
    function test_A6_control_revertThenRetrySucceedsWithNoGriefer() public {
        bytes32 attemptId = keccak256("victim csprng");
        address receiver = adapter.predictMintReceiver(victim, attemptId);
        bytes memory payload = abi.encode(_mintData(receiver, uint256(attemptId), 40, 5 ether));

        vm.prank(admin);
        vault.pause();
        vm.prank(victim);
        vm.expectRevert();
        vault.depositETH{value: 5 ether}(attemptId, payload);
        vm.prank(admin);
        vault.unpause();

        vm.warp(block.timestamp + 60);
        vm.prank(victim);
        vault.depositETH{value: 5 ether}(attemptId, payload);
        assertEq(vault.bondCount(victim), 40, "the retry works when nobody grieves it");
    }

    /// @notice The burn is PERMANENT and not even DexFi can undo it: their only nonce-rewriting
    ///         entry point, `setMintDataHistory`, is one-way locked on mainnet (asserted live in
    ///         test/fork/A6FarmAccessControl.fork.t.sol). Here: nothing in our own surface
    ///         un-burns an attempt either.
    function test_A6_aBurnedAttemptIsPermanent() public {
        bytes32 attemptId = keccak256("a");
        address receiver = adapter.predictMintReceiver(victim, attemptId);
        vm.prank(griefer);
        bond.mint{value: 1 ether}(_mintData(receiver, 1, 1, 1 ether));

        vm.prank(admin);
        adapter.recoverMintAttempt(victim, attemptId, payable(recoveryRecipient));

        // Even after a full governance recovery, the attempt stays dead.
        assertEq(bond.nonces(receiver), 1, "nonce is never reset");
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1)
        );
        vault.depositETH{value: 5 ether}(
            attemptId, abi.encode(_mintData(receiver, uint256(attemptId), 40, 5 ether))
        );
    }

    /// @notice Nothing on-chain requires attemptId ENTROPY. Only the zero id is rejected, so a
    ///         client that derives ids deterministically hands a griefer a pre-burnable list.
    ///         This is a client obligation stated only in NatSpec, with no client yet written.
    function test_A6_onlyTheZeroAttemptIdIsRejected() public {
        vm.expectRevert(DirectCallAdapter.InvalidAttemptId.selector);
        adapter.predictMintReceiver(victim, bytes32(0));

        // Everything else is accepted, including a trivially guessable counter.
        for (uint256 i = 1; i <= 5; i++) {
            address r = adapter.predictMintReceiver(victim, bytes32(i));
            assertTrue(r != address(0), "low-entropy attempt ids are accepted");
        }
    }
}
