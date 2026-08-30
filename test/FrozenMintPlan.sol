// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FrozenMintPlan
/// @notice The single declaration of the frozen DexFi mint-attempt address plan.
///
/// @dev **WHY THIS FILE EXISTS: THERE WERE THREE UNCOUPLED COPIES.** MEASURED 2026-08-30
///      (audit round 39, item 33). The same constants stood, retyped, in
///      `test/R34Determinism.t.sol` and in `test/fork/DexFiMintAttempt.fork.t.sol`, and a
///      fifth copy of the head-offset fact stood as the literal `1` in
///      `vm.setNonce(PROOF_DEPLOYER, 1)`. Nothing compared any of them. A value corrected in
///      one file and not the other left two green suites disagreeing about the address a
///      third party is asked to sign against, and #354 moved every one of these values at
///      once - which is exactly the edit that leaves copies behind.
///
///      🟥 **THE PRESCRIBED FIX FOR THIS FINDING IS REFUSED, AND IT IS THE TWENTY-FIRST
///      PRESCRIPTION REFUSED - THE FIRST REFUSED BEFORE IT WAS BUILT.** It said to read the
///      five machine-readable constants out of both Solidity files and assert field
///      equality between them. MEASURED:
///      **13 constants are shared between the two files and that reader returns 5.** The eight
///      it cannot see include `EXPECTED_VAULT` = `0xE3B53c9e68dE7e6Ee3f254B8bDEFE56B7892A318`,
///      which is the exact trap address: under the nonce-4 ladder the vault landed on the
///      address that was frozen until #354 as the ADAPTER, so a stale copy of that one value
///      is internally consistent at every step while pointing at the wrong contract. Worse,
///      the round-38 neuter that would have validated the prescription happened to pick
///      `EXPECTED_RECEIVER`, which IS one of the five - so the prescription passes its own
///      neuter and misses the finding. A five-of-thirteen comparison is not a coupling; a
///      single declaration is.
///
///      **Inheritance rather than a `library`.** A library would rewrite roughly thirty call
///      sites in the two most sensitive test files in the tree, and every assertion line in
///      both of those files is evidence. Inheriting an abstract contract of constants leaves
///      every one of them byte-identical.
///
///      ---
///
///      🟥 **THIS PLAN IS A MECHANISM FIXTURE, NOT A PRODUCTION ADDRESS COMMITMENT.** It pins
///      a DERIVATION - that the mint receiver is
///      `CREATE2(adapter, salt, keccak(ERC-1167 clone of CREATE(adapter, 1)))`, that the salt
///      is `keccak(domain, beneficiary, attemptId)`, and that the adapter sits at a known
///      offset in the deploying key's nonce ladder. It does NOT commit the protocol to
///      deploying at these addresses, and nothing should be signed against them.
///
///      The measured basis, 2026-08-30: `PROOF_DEPLOYER` `0x463aBa37...` is at nonce 0 with a
///      zero balance and appears only in fixtures, while the deploy key every operator
///      document names, `0xE61B6087...`, is at nonce **96**; and on the real `DeployTestnet`
///      artefact the testnet ladder puts the adapter at a LATER nonce and derives a different
///      receiver. 🟥 **Do not write that nonce down. It has moved twice.** It was 8, and the
///      round-39 lock reorder put three `lockTo` CALLs ahead of `_deployProtocol` and made it
///      **11** (measured 2026-08-30 from a real artefact). What is stable is the OFFSET: the
///      adapter is the fourth contract `_deployProtocol` creates, whatever precedes it. The
///      broadcast checker derives the nonce from the artefact and prints it; read that.
///      The frozen constants below remain the MAINNET-path derivation, and are not
///      `0xc809bC75...`. The production receiver is derived at deploy time from the real
///      deployer's real nonce, and the DexFi payload is re-signed against it then, via
///      `/sign-mint-and-apply` - `/bonds/sign-mint` is broken and returns an identical 422 for
///      a correct signature and for garbage.
///
///      So a failure of any assertion below means the DERIVATION moved, which is the thing
///      worth catching: an extra `new` in the `DirectCallAdapter` constructor, a contract
///      inserted ahead of the adapter, a changed salt domain, or an OpenZeppelin bump that
///      changes the ERC-1167 bytes. It does not mean a deployment is at the wrong address.
///
///      ---
///
///      **An off-chain guard parses five of these constants straight out of this file rather
///      than carrying its own copy of them**, so this file is the only place any of them may
///      be declared. A repository-wide CI check holds exactly that: one declaration of each of
///      the fourteen names here, and zero in either consuming file.
abstract contract FrozenMintPlan {
    /// @dev The frozen fixture key. Nonce 0, zero balance, fixtures only - see the note above.
    address internal constant PROOF_DEPLOYER = 0x463aBa37BD744f14Fa84A2A0148ef75DE4B88a86;
    address internal constant PROOF_BENEFICIARY = 0x6f06e39F209d0eB2c584324d6e77E2C39BE30c2E;
    address internal constant PROOF_YIELD_RECIPIENT = 0xef080ac2353e383bA61f683D1F800Dec9b2C8458;
    bytes32 internal constant PROOF_ATTEMPT_ID =
        0xc7a776ace3e8c46601d87cebc6354d7e36f5358d292d27f0f153c0adf8a09311;
    uint256 internal constant PROOF_NAV = 25.15e8;

    /// @dev ONE, not zero, and the one is not a contract. `CreditWiring` is a deploy-time-linked
    ///      library, so forge emits its CREATE2 to the deterministic factory at the HEAD of the
    ///      broadcast, ahead of the script body. That is a transaction from the deploying key and
    ///      it spends nonce 0. MEASURED 2026-08-30 from a real `DeployLocal --broadcast` artefact:
    ///      38 transactions, 1 CREATE2 / 12 CREATE / 25 CALL, index 0 the library at nonce 0x0.
    ///
    ///      This was the FIFTH uncoupled copy of the plan: `R34Determinism.t.sol` carried it as
    ///      the bare literal `1` inside `vm.setNonce`, so the head-offset fact - the one #354
    ///      moved - could be corrected here and left wrong there with both suites green.
    uint64 internal constant PROOF_DEPLOYER_START_NONCE = 1;

    // Independently derived from the frozen CREATE/CREATE2 inputs above, outside Solidity, with
    // `cast keccak`, `cast compute-address` and hand-built RLP and CREATE2 preimages. The
    // on-chain predictor remains the authority; these constants make any fixture drift fail
    // before somebody derives a receiver from a fixture that has quietly moved.
    address internal constant EXPECTED_NAV_ORACLE = 0x8D415dCD7f672657124C2116129Fb74887bFE052;
    address internal constant EXPECTED_RISK_PARAMS = 0x4a3952A03189351f42E711c6EEc81334a66d8530;
    /// @dev 🟥 Under the nonce-4 ladder the VAULT holds `0xE3B53c9e...`, which was frozen as the
    ///      ADAPTER until #354. Any prose or fixture still carrying it as the adapter is stale.
    address internal constant EXPECTED_VAULT = 0xE3B53c9e68dE7e6Ee3f254B8bDEFE56B7892A318;
    address internal constant EXPECTED_ADAPTER = 0xEd9a6f3196ec5785ae264e9C6B7822da4519a6A2;
    address internal constant EXPECTED_RECEIVER_IMPLEMENTATION =
        0x7836202E676B49Cc567c63204e49172a08a1ACDb;
    address internal constant EXPECTED_RECEIVER = 0xc809bC75A023449C6ebb42Fb3B37C57f6C1E7D25;
    bytes32 internal constant EXPECTED_MINT_ATTEMPT_DOMAIN =
        0x626ce3d268d83453b9fa29747853053daff17551aeb4326875835b8b6334aa1e;
    bytes32 internal constant EXPECTED_MINT_ATTEMPT_SALT =
        0x54cbf2206af515f829be016cc4120175b590923df92defdbcf2fddeea579dcd3;
}
