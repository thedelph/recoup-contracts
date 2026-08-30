// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FrozenMintPlan} from "./FrozenMintPlan.sol";
import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R34DeterminismTest
/// @notice The frozen DexFi mint-attempt address plan, asserted with NO fork and in under
///         two milliseconds.
///
/// @dev **What this catches, and why it has to exist separately from the fork proof.**
///
///      `test/fork/DexFiMintAttempt.fork.t.sol` already asserts this whole plan, and it is
///      the only other place in the tree that does. `EXPECTED_ADAPTER`,
///      `EXPECTED_RECEIVER_IMPLEMENTATION`, `EXPECTED_RECEIVER` and
///      `EXPECTED_MINT_ATTEMPT_SALT` are declared in `FrozenMintPlan.sol` and nowhere else,
///      and a repository-wide CI check holds that: exactly one declaration of each of the
///      fourteen names there, and zero in this file or the fork proof. 🟥 **This sentence
///      read "appear in that file and nowhere else" and had been FALSE since round 37** - the
///      constants were retyped in both files, uncoupled, which is audit round 39's item 33.
///      The checkable version is the one written above. **That file runs
///      ZERO tests under ordinary CI.** Its `setUp` returns immediately unless
///      `RUN_DEXFI_MINT_PROOF` is set, both of its tests then `vm.skip`, and a plain
///      `forge test` reports `0 passed; 0 failed; 2 skipped`. So the address a third party
///      is asked to sign against is, today, protected by nothing that runs.
///
///      MEASURED (audit round 34): with one extra `new MintAttemptReceiver(...)` inserted
///      before the real one in the `DirectCallAdapter` constructor - the single most
///      ordinary edit that invalidates a DexFi signature - the receiver moves from
///      `0xB726...e378` to `0x58e0...3982`, and **125 tests across the three suites that use
///      `predictMintReceiver` all PASS** (`MintAttemptReceiver.t.sol`, `CollateralVault.t.sol`
///      and `Deploy.t.sol`) while the fork proof reports two skips. They pass because every
///      one of them computes its expectation from the live contract, so both sides of the
///      comparison move together. This test hardcodes the far side instead.
///
///      **The nonce-1 CREATE inside the `DirectCallAdapter` constructor is load-bearing on
///      an address frozen with a third party.** `mintReceiverImplementation` is created at
///      the first CREATE the adapter itself issues; CREATE hashes `RLP(sender, nonce)` and
///      nothing else, so inserting any `new` ahead of it in that constructor silently
///      relocates every future mint receiver and invalidates any payload DexFi has already
///      signed. Nothing about that edit looks dangerous at the call site.
///
///      **The externals here are deliberately MOCKS, not the live Base addresses, and that
///      is part of what the test proves.** CREATE derives from `(sender, nonce)` alone and
///      CREATE2 from `(deployer, salt, keccak(clone creation code))`, so the plan is
///      independent of every constructor argument, of the compiler, and of the chain. All of
///      the constants this test asserts were re-derived outside Solidity with `cast keccak`,
///      `cast compute-address` and hand-built RLP and CREATE2 preimages, and agree. 🟥 **This
///      said "all eight constants below" and there are now fourteen, INHERITED rather than
///      below** - the count and the word "below" were both wrong, so neither is restated: the
///      constants live in `FrozenMintPlan.sol` and the count is derived there.
///
///      🟥 **THE PLAN IS A MECHANISM FIXTURE, NOT A PRODUCTION ADDRESS COMMITMENT.** It pins a
///      DERIVATION, and nothing should be signed against these addresses. `PROOF_DEPLOYER` is
///      at nonce 0 with a zero balance and appears only in fixtures, while the deploy key every
///      operator document names is at nonce 96; on the real `DeployTestnet` artefact the
///      adapter lands at a LATER nonce and derives a different receiver - it was 8, the
///      round-39 lock reorder made it **11**, and the durable statement is the OFFSET rather
///      than either number: the adapter is the fourth contract `_deployProtocol` creates.
///      The production receiver is
///      derived at deploy time from the real deployer's real nonce and the DexFi payload is
///      re-signed against it then, via `/sign-mint-and-apply`. A failure here means the
///      DERIVATION moved - which is the thing worth catching. Full statement in
///      `FrozenMintPlan.sol`.
///
///      **What this test does NOT catch** - it hardcodes its own fixture, so anything the
///      fixture itself fixes can move underneath it while this stays green:
///
///        1. **A different deployer EOA.** `PROOF_DEPLOYER` is a constant here. Broadcasting
///           the real deployment from any other address moves the whole plan.
///        2. **A non-zero deployer nonce, or an EIP-7702 delegation, at broadcast time.**
///           `vm.resetNonce` and `vm.etch` make the counterfactual true locally; only the
///           live chain can make it true in production.
///        3. **A transaction forge inserts AHEAD of the script body.** This fixture hand-rolls
///           four CREATEs and never calls `_deployProtocol`, so it cannot see one. It used to
///           say the adapter "lands on nonce 3 either way and the frozen receiver survives";
///           that was FALSE, and it was false for a reason no amount of reading
///           `_deployProtocol` could find. `CreditWiring` is a deploy-time-linked library, and
///           forge emits its deployment as a CREATE2 to the deterministic factory at
///           `0x4e59b448...` at the HEAD of the broadcast. It is a transaction from the
///           deploying key, so it spends nonce 0 even though its own address is not
///           nonce-derived. MEASURED 2026-08-30 from a real `DeployLocal --broadcast`
///           artefact: 38 transactions, 1 CREATE2 / 12 CREATE / 25 CALL, index 0 the library at
///           nonce 0x0. The production ladder is therefore library(0), NAVOracle(1),
///           RiskParams(2), CollateralVault(3), **DirectCallAdapter(4)** - and note that
///           `_deployProtocol` builds the oracle BEFORE the risk parameters, the reverse of the
///           order below, so slots 1 and 2 carry the opposite names to this fixture. Only slot 4
///           matters to the receiver.
///           A separate off-chain check covers it, by reading a real broadcast artefact and
///           re-deriving the ladder from what the script actually emitted. No Solidity test can,
///           because `vm.startBroadcast` inside a
///           `forge test` frame does not model `forge script`'s broadcast head. What remains
///           uncovered BY THIS FIXTURE is now covered next door: adding a contract ahead of the
///           adapter inside `_deployProtocol` moves the receiver, and
///           `test_R37_theAdapterIsTheFourthContractDeployProtocolCreates` calls the real
///           function and asserts the adapter's OFFSET rather than its address, so it fails on
///           exactly that. What no Solidity test can reach is the head insertion above.
///        4. **A future OpenZeppelin bump that changes the ERC-1167 bytes.** This test WOULD
///           fail, because `predictMintReceiver` routes through `Clones`. But
///           `DirectCallAdapter._mintReceiverRuntimeCodeHash()` hardcodes the 45 bytes and
///           does not track `Clones`, and it is enforced only by `flushMintAttemptYield` and
///           the recovery path - never on the mint path. So an OZ bytecode change would let
///           minting continue while bricking yield flush and recovery with
///           `InvalidMintReceiverCode`. Keep the hardcode and the library version together.
///
///      Vendored OZ when this was written: **v5.6.1** (`contracts/proxy/Clones.sol`, header
///      "last updated v5.5.0"), whose 45-byte runtime matches the hardcode exactly.
contract R34DeterminismTest is Test, FrozenMintPlan {
    /// @notice Reproduce the whole frozen plan off-chain, off-fork, with mock externals.
    function test_frozenAddressPlanIsChainlessAndArgumentIndependent() public {
        // Mocks on purpose. If any of these entered a CREATE or CREATE2 input, the constants
        // below could not hold against the live Base addresses the fork fixture passes - so a
        // pass here IS the argument-independence claim, not merely a convenience.
        MockUSDC usdc = new MockUSDC();
        MockBond bond = new MockBond();
        MockFarm farm = new MockFarm(bond, usdc);

        vm.etch(PROOF_DEPLOYER, "");
        vm.resetNonce(PROOF_DEPLOYER);
        vm.deal(PROOF_DEPLOYER, 1 ether);
        assertEq(vm.getNonce(PROOF_DEPLOYER), 0, "proof nonce reset failed");

        // Nonce 0 is spent before the script body runs, and NOT by a contract. `CreditWiring`
        // is a deploy-time-linked library, so forge emits a CREATE2 to the deterministic
        // factory at the head of the broadcast; it is a transaction from this key. MEASURED
        // 2026-08-30 from a real `DeployLocal --broadcast` artefact, index 0, nonce 0x0.
        // Modelling it as a bare nonce rather than as a deployment is deliberate: its address
        // is CREATE2-derived and plays no part in the ladder below. Only the nonce it burns does.
        //
        // 🟥 This was the bare literal `1` until audit round 39, which made it the FIFTH
        // uncoupled copy of the frozen plan, and the head offset is precisely the fact #354
        // moved. It now reads the same constant the fork proof does.
        vm.setNonce(PROOF_DEPLOYER, PROOF_DEPLOYER_START_NONCE);

        // `startBroadcast(address)` makes CREATE derive from the fixed EOA. A prank would not:
        // the CREATE would still be issued by this test contract.
        vm.startBroadcast(PROOF_DEPLOYER);
        // Oracle BEFORE risk parameters, mirroring `DeployBase._deployProtocol`. This
        // fixture used to build them the other way round, so slots 1 and 2 carried each
        // other's names while the values stayed right - a mislabelling nobody noticed because
        // the assertions all passed.
        MockNavOracle navOracle = new MockNavOracle(PROOF_NAV);
        RiskParams riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            PROOF_DEPLOYER
        );
        CollateralVault vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(navOracle)), riskParams, PROOF_DEPLOYER
        );
        DirectCallAdapter adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(farm)),
            IERC20(address(usdc)),
            address(vault),
            PROOF_DEPLOYER,
            PROOF_YIELD_RECIPIENT
        );
        vm.stopBroadcast();

        assertEq(vm.getNonce(PROOF_DEPLOYER), 5, "frozen deploy order moved");
        assertEq(address(navOracle), EXPECTED_NAV_ORACLE, "NAV CREATE address moved");
        assertEq(address(riskParams), EXPECTED_RISK_PARAMS, "risk CREATE address moved");
        assertEq(address(vault), EXPECTED_VAULT, "vault CREATE address moved");
        assertEq(address(adapter), EXPECTED_ADAPTER, "adapter CREATE address moved");

        // The load-bearing one: the first CREATE the adapter itself issues.
        assertEq(
            address(adapter.mintReceiverImplementation()),
            EXPECTED_RECEIVER_IMPLEMENTATION,
            "implementation CREATE moved - an extra CREATE in the adapter constructor?"
        );

        assertEq(adapter.MINT_ATTEMPT_DOMAIN(), EXPECTED_MINT_ATTEMPT_DOMAIN, "salt domain moved");
        assertEq(
            keccak256(abi.encode(adapter.MINT_ATTEMPT_DOMAIN(), PROOF_BENEFICIARY, PROOF_ATTEMPT_ID)),
            EXPECTED_MINT_ATTEMPT_SALT,
            "attempt salt moved"
        );

        // Routes through `Clones.predictDeterministicAddress`, so this arm also fails on an
        // OpenZeppelin bump that changes the ERC-1167 bytes.
        assertEq(
            adapter.predictMintReceiver(PROOF_BENEFICIARY, PROOF_ATTEMPT_ID),
            EXPECTED_RECEIVER,
            "CREATE2 receiver moved - any DexFi payload signed against it is now invalid"
        );
    }
}
