// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {Config} from "../src/Config.sol";
import {MintAttemptReceiver} from "../src/MintAttemptReceiver.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";

/// @notice The read-only half of `MockLockdown`, declared here rather than imported.
/// @dev `DeployBase` must not import `test/mocks/`: `WirePhase4` and `DeployReferral` inherit it
///      too, and neither has any business pulling the mock stack into its compilation unit. Three
///      selectors is the whole surface the post-condition below needs.
interface IMockLockdownView {
    function admin() external view returns (address);
    function operator() external view returns (address);
    function lockAuthority() external view returns (address);
}

/// @title DeployBase
/// @notice The deployment sequence, extracted so local, testnet and mainnet all run
///         the *same* wiring rather than three drifting copies, and so `Deploy.t.sol`
///         can execute it in CI. Previously only the local target wired anything and
///         the mainnet target reverted, which meant the wiring destined for mainnet
///         had never run.
/// @dev Operator addresses (owner, treasury, keeper) are environment parameters, not
///      constants in Config. Config holds protocol parameters and verified external
///      addresses; operator identities are per-deployment, rotatable, and must not be
///      committed. Keeping them here is also what makes the eventual move of `owner`
///      from an EOA to a Safe or timelock a config change rather than a code change.
///
/// @dev **`ReferralRegistry` is deliberately NOT deployed here, and must not be added.**
///      It has zero coupling in both directions, so `_assertWiring` would have nothing to
///      assert about it, and a `Deployed` field with no possible assertion is the shape of
///      audit-7 finding #6. The decisive reason is G9: the supported fix for a core defect
///      before launch is to redeploy this whole set and move the bonds across, and a
///      registry inside that set would take a new address every time. Bindings are
///      immutable, address-scoped and non-portable, so each redeploy would orphan every
///      referral binding permanently, with no owner able to repair it. The registry's
///      lifecycle has to outlive the protocol's. It ships via
///      `script/DeployReferral.s.sol`, once, on its own schedule.
abstract contract DeployBase is Script {
    /// @notice Per-deployment operator addresses. `owner` is deliberately a plain
    ///         address: an EOA while building, a Safe or TimelockController at
    ///         go-live, with no contract change in between.
    struct GovParams {
        address owner;
        address yieldRecipient;
        address keeper;
        address navConfirmer;
        address protocolFeeWallet;
        /// @dev Go-live item G4. **Optional, and zero is a legal, meaningful value**: it leaves
        ///      the role unfilled, which is the right answer while the owner is an EOA that can
        ///      already pause in one transaction. It becomes load-bearing at G2, when the owner
        ///      becomes a 48-hour timelock and `pause` stops being fast.
        address guardian;
    }

    /// @notice The DexFi side: mocks locally, the verified Config addresses on Base.
    struct Externals {
        IDexFiBond bond;
        IDexFiFarm farm;
        IERC20 usdc;
    }

    struct Deployed {
        NAVOracle oracle;
        RiskParams riskParams;
        CollateralVault vault;
        DirectCallAdapter adapter;
        CreditManager credit;
        LenderPool pool;
        TreasuryLiquiditySource liquidity;
        EpochHarvester harvester;
        LiquidationAuction auction;
    }

    error OwnerRequired();
    error YieldRecipientRequired();
    error KeeperRequired();
    error NavConfirmerRequired();
    error NavKeysMustDiffer();
    /// @dev Mirrors the check both contracts make. Catching it here means a misconfigured deploy
    ///      fails before it broadcasts rather than at the third wiring call.
    error GuardianMustDifferFromOwner();
    /// @dev **The rule `_assertWiring` cannot make, and round 29's open finding 1 is why it has to
    ///      be here rather than there.** `_assertWiring` compares the deployed guardian against the
    ///      PARAMETER, which is the stronger check and the right one - and zero equals zero, so a
    ///      guardian-less deployment satisfies every post-condition this script has. Nothing was
    ///      checking what was ASKED FOR.
    ///
    ///      Zero is a legal, meaningful value under an EOA owner: that key can already `pause()`
    ///      in one transaction, so the role adds nothing and an unfilled one costs nothing. It
    ///      stops being legal the moment the owner is a contract, because `_wire` calls
    ///      `setGuardian` BEFORE `_handOver` and the only remaining route to a guardian is then a
    ///      `setGuardian` the new owner has to schedule. Under a `TimelockController` at
    ///      `Config.ADMIN_TIMELOCK` that is a 48-hour operation, so the failure removes the tool
    ///      you would need in order to respond to the failure.
    ///
    ///      **`code.length` cannot tell a Safe from a timelock, and this refuses both on purpose.**
    ///      `GovParams.owner` names a Safe as a legitimate go-live shape, and a Safe can still
    ///      pause in one transaction, so for that case the rule is stricter than the harm strictly
    ///      requires. Probing for `getMinDelay()` would narrow it and was rejected: a `staticcall`
    ///      sniffing for an interface is a guess about what the owner IS, when the thing this rule
    ///      is actually about is that the owner is no longer the key in the operator's hand.
    ///      Naming a guardian costs one environment variable either way.
    ///
    ///      Carries the owner because at 3am the operator needs to see WHICH address it refused -
    ///      the same reason `YieldRecipientCollision` and `OwnershipNotTransferred` carry theirs.
    error GuardianRequiredForContractOwner(address owner);
    /// @notice A mock in the stack is still open to anybody.
    error MockNotLocked(address mock);

    /// @notice A mock is locked, but to the wrong second caller.
    /// @dev Its own error rather than a reuse of `MockNotLocked`, because the two failures need
    ///      different operator responses: `MockNotLocked` means re-run the deploy, this one means
    ///      the stack is closed but the epoch job cannot write to it.
    error MockOperatorWrong(address mock, address actual, address expected);

    error ProtocolFeeWalletRequired();
    error YieldRecipientCollision(address recipient, string collidesWith);
    error OwnershipNotTransferred(address contractAddr, address actualOwner);
    /// @dev Raised when `_ownablesOf` meets a `Deployed` member it cannot enumerate: one that is
    ///      not a live contract (so the struct has grown a dynamic field, whose ABI encoding is an
    ///      offset rather than a value) or one that is not `Ownable`. Loud on purpose. The
    ///      alternative is enumerating fewer contracts than the struct holds and reporting
    ///      success, which is the exact failure that function exists to end - and if a member is
    ///      ever legitimately not `Ownable`, the decision to exempt it belongs in this file, in
    ///      writing, rather than in an omission somewhere else.
    error DeployedMemberNotOwnable(uint256 index);
    /// @dev Raised when `_log`'s label list has fallen out of step with `Deployed`. Labels are
    ///      presentation, but a missing label is a contract whose address the operator is never
    ///      shown - which is what happened to `RiskParams`, the one holding the borrow ceiling and
    ///      the liquidation trigger for the whole book.
    error DeployedLabelsOutOfSync(uint256 labels, uint256 members);
    error WiringIncomplete(string what);
    /// @dev The mirror image of `WiringIncomplete`, and audit round 11 is why it has to exist as
    ///      its own error rather than as a missing check. A pointer that is set too early is not a
    ///      half-finished deployment, it is a finished deployment with a role nobody funds - so
    ///      "incomplete" would be the wrong word in the revert reason an operator reads at 3am.
    error LenderExposureWiredEarly(string what);
    /// @dev The Phase-4 post-condition that is about a relation rather than about an address.
    ///      `CreditManager._socialise` refuses to charge a pool that is not also the liquidity
    ///      source, so a deployment where these two disagree has a loss sink that can never be
    ///      charged - which is precisely the state round 11 found shipped.
    error LenderRolesDisagree(address liquiditySource, address lenderPool);

    /// @dev A switchover leg that reverts without data. Every leg in `_phase4Calls` is a call into
    ///      a contract of ours, so in practice the callee's own named revert is re-thrown instead
    ///      and this is the empty-returndata fallback: an out-of-gas or a call into a codeless
    ///      address. Named so that "the switchover failed" is never silent.
    error SwitchoverLegFailed(uint256 index, address target);

    /// @dev **Deleted in audit round 20, and the deletion is the finding.** This used to be
    ///      `SwitchoverNotPaused(string)`, raised by a `if (!d.credit.paused()) revert ...`
    ///      immediately below `d.credit.pause()`. OpenZeppelin's `_pause()` carries
    ///      `whenNotPaused`, so a `pause()` that *returns* has necessarily set the flag: the read
    ///      could only ever observe what the statement above it had just written, and the only
    ///      route to the branch was `vm.mockCall`. It had no test, because it had nothing to test.
    ///      A post-condition must read something the statement above it did not just write; this
    ///      one read as verification and was not. What actually holds the property is named where
    ///      it belongs - OZ's modifier on the broadcast path, and `executeBatch`'s atomicity on
    ///      the queued one. Do not reintroduce it.
    ///
    ///      **Round 21 added a `WirePhase4.SwitchoverNotPaused` and that is not this error coming
    ///      back, so the difference is written down rather than left to a name collision.** The
    ///      deleted one was unreachable because the line above it had just written the thing it
    ///      read. The new one is a *precondition* on a different operation: `queue()` reads a pause
    ///      that a separate, earlier timelock batch performed, which nothing in the same call
    ///      stack wrote, and which round 21 measured a stranger exploiting the absence of. It has
    ///      three tests and a neuter, and this deletion's rule - "a post-condition must read
    ///      something the statement above it did not just write" - is the rule it satisfies rather
    ///      than the rule it breaks. Reintroducing a `paused()` read immediately below a `pause()`
    ///      is still wrong.

    /// @dev The other end of the same problem: a switchover that half-ran and left the protocol
    ///      paused is a legible failure rather than a silent outage nobody is watching for.
    error SwitchoverLeftPaused(string what);

    uint256 internal constant ANVIL_CHAIN_ID = 31337;

    /// @dev Deterministic local stand-in for the treasury. Anything but the deployer:
    ///      defaulting `yieldRecipient` to `msg.sender` is exactly the footgun this
    ///      script exists to remove, and a local default that models the real shape
    ///      is worth more than one that merely runs.
    address internal constant LOCAL_TREASURY = address(uint160(uint256(keccak256("recoup.local.treasury"))));
    address internal constant LOCAL_KEEPER = address(uint160(uint256(keccak256("recoup.local.keeper"))));
    address internal constant LOCAL_NAV_CONFIRMER =
        address(uint160(uint256(keccak256("recoup.local.navConfirmer"))));

    function _isLocal() internal view returns (bool) {
        return block.chainid == ANVIL_CHAIN_ID;
    }

    // ── Parameters ───────────────────────────────────────────────────────────

    /// @notice The single door every script parameter comes through.
    /// @dev **`virtual` for exactly one reason, and it is not extensibility.** `vm.setEnv` writes
    ///      ONE table shared by the whole `forge test` process and forge runs a suite's functions
    ///      in parallel, so a test that sets a variable and a sibling that sets the same variable
    ///      are a race in real time, not in EVM state. That was measured in this repo at roughly
    ///      one run in eight - a plausible protocol revert in a test that was correct - and it was
    ///      green in five runs of five under `--threads 1`, which is what identified it as a race
    ///      rather than a defect. Two rounds of narrowing the blast radius (blank one variable, not
    ///      twenty; export on the line before the call that reads it) made it rarer and could not
    ///      make it go away, because the hazard is that a writer exists at all.
    ///
    ///      A test overrides this instead, backed by storage on the test contract. Forge isolates
    ///      EVM state per test function, so an override is private to the function that set it and
    ///      **no test in the process touches the environment**. The race is then absent by
    ///      construction rather than made unlikely.
    ///
    ///      **What that costs, stated rather than discovered later, because nothing else will say
    ///      it.** An overridden read no longer proves this file's `vm.envOr` call reaches the
    ///      process environment. It still proves the KEY: an override is keyed on the same string,
    ///      so a typo in a key name misses the override exactly as it would miss the environment,
    ///      and `_required` still reverts `DeployedAddressMissing` with the name.
    ///
    ///      The one claim left unproven is the body of the two functions below - that the base
    ///      implementation reads the environment at all - and there is **no test for it, on
    ///      purpose**. The only way to assert it from inside `forge test` is `vm.setEnv`, which is
    ///      the cheatcode being removed, and a key nobody else reads is not a safe exception:
    ///      `setenv` mutates a table other threads are inside `getenv` on, so the hazard is the
    ///      write and not the key. It is exercised on every real `forge script` run instead, and a
    ///      seam that stopped reading the environment would break a deploy rather than this suite.
    ///      Recorded as a residual rather than closed.
    ///
    ///      Zero bytecode cost: `DeployBase` is a script and is never deployed.
    function _envOrAddress(string memory key, address fallbackValue)
        internal
        view
        virtual
        returns (address)
    {
        return vm.envOr(key, fallbackValue);
    }

    /// @dev The string half of the same seam, for the confirmation phrases. Same reasoning.
    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        virtual
        returns (string memory)
    {
        return vm.envOr(key, fallbackValue);
    }

    /// @notice Resolve operator addresses from the environment, then validate them.
    /// @dev Reading and checking are separate so the rules can be tested directly,
    ///      without a test having to mutate process environment variables that would
    ///      then leak into every other test in the run.
    function _resolveParams(address deployer) internal view returns (GovParams memory p) {
        p = _readParams(deployer);
        _validateParams(p, deployer);
    }

    /// @notice The same addresses, read and not checked.
    /// @dev **For readers, and there is exactly one: `WirePhase4.assertOnly()`.** That function is
    ///      a post-condition report an operator runs to find out what a queued switchover actually
    ///      did, and its own docstring says it is deliberately ungated because "reading state
    ///      changes nothing and an operator should never be discouraged from checking". While the
    ///      contract-owner guardian rule sat in `_validateParams`, going through `_resolveParams`
    ///      would have made that false: a deployment owned by a contract with no guardian named is
    ///      precisely the state somebody would run the report to understand, and the report would
    ///      have answered with a parameter error instead of the wiring. That rule now lives on the
    ///      deploy path, in `_validateNewDeployment`, so the escape this function provided is no
    ///      longer the only one - but the reasoning above is unchanged and so is the caller.
    ///
    ///      **A zeroed struct is NOT a substitute and that was measured the hard way.**
    ///      `_assertPhase4Wiring` looks as though it ignores its `GovParams` - there is no
    ///      `p.<field>` anywhere in its body - but it hands them whole to `_assertCoreGraph`, which
    ///      reads `p.owner` for the ownership check. Passing a zeroed struct made it revert
    ///      `OwnershipNotTransferred` against `address(0)`. The values are needed; only the
    ///      refusal is not.
    ///
    ///      Nothing else may use this. A deployment must go through `_resolveParams`, because the
    ///      rules are the point.
    function _readParams(address deployer) internal view returns (GovParams memory p) {
        // **Zero, like every other operator address, and the fallback to `deployer` lives in the
        // local block below.** This key used to default to the broadcasting key on every
        // chain, which made it the only operator address a real deployment could inherit rather
        // than choose - and the inheritance was silent in both directions. `OwnerRequired()` was
        // unreachable on every script path, because `deployer` is never zero. `_handOver` was
        // skipped by `if (p.owner != deployer)`, so the deploying key kept all nine contracts,
        // including `TreasuryLiquiditySource` behind an uncapped `onlyOwner withdraw` and
        // `RiskParams`. And every `_requireOwner` post-condition then compared the chain against
        // that same defaulted value, so the check that exists to catch a failed handover was
        // asking `deployer == deployer` and certifying it.
        //
        // It also silently disarmed the contract-owner guardian rule: a defaulted owner is the
        // broadcasting EOA, so `p.owner.code.length` is zero and that rule cannot fire either.
        // Two rules disappeared together, and neither absence was visible from a green run.
        p.owner = _envOrAddress("RECOUP_OWNER", address(0));
        p.yieldRecipient = _envOrAddress("RECOUP_YIELD_RECIPIENT", address(0));
        p.keeper = _envOrAddress("RECOUP_KEEPER", address(0));
        p.navConfirmer = _envOrAddress("RECOUP_NAV_CONFIRMER", address(0));
        p.protocolFeeWallet = _envOrAddress("RECOUP_PROTOCOL_FEE_WALLET", address(0));
        // No local default, unlike every other member. Those default because a local run must need
        // zero setup; this one stays zero because an unfilled guardian is the correct default
        // everywhere, and inventing a local one would put a role in the logs that nobody chose.
        p.guardian = _envOrAddress("RECOUP_GUARDIAN", address(0));

        if (_isLocal()) {
            // The deployer fallback, kept and confined. A local run must need zero setup, and
            // locally the deploying key owning everything is the whole point rather than a
            // capture. Off this branch an unnamed owner is now `address(0)` and `OwnerRequired()`
            // is reachable, which is the only state in which that error means anything.
            if (p.owner == address(0)) p.owner = deployer;
            if (p.yieldRecipient == address(0)) p.yieldRecipient = LOCAL_TREASURY;
            if (p.keeper == address(0)) p.keeper = LOCAL_KEEPER;
            if (p.navConfirmer == address(0)) p.navConfirmer = LOCAL_NAV_CONFIRMER;
            if (p.protocolFeeWallet == address(0)) p.protocolFeeWallet = LOCAL_TREASURY;
        }

    }

    /// @notice The rules a real deployment must satisfy.
    /// @dev Permissive locally so `forge script ... DeployLocal` needs zero setup;
    ///      strict everywhere else so a real deployment cannot inherit a default.
    function _validateParams(GovParams memory p, address deployer) internal view {
        if (p.owner == address(0)) revert OwnerRequired();
        // Checked before the local early-return, unlike everything below it: the rules after this
        // point are about a real deployment having real operators, and are relaxed locally on
        // purpose. This one is not a completeness rule - it is the same rule both contracts
        // enforce in `setGuardian`, so a local deploy that broke it would revert mid-wiring with
        // no indication which of two roles was wrong.
        if (p.guardian != address(0) && p.guardian == p.owner) revert GuardianMustDifferFromOwner();
        if (_isLocal()) return;

        // **The contract-owner guardian rule is NOT here, and `_validateNewDeployment` below says
        // why.** It used to sit on this line. Everything left in this function is a rule about a
        // set of addresses, true or false whenever you ask it; that one is a rule about the act of
        // MAKING a deployment, and asking it of a deployment that already exists refuses an
        // operation without offering any way to satisfy it.
        if (p.yieldRecipient == address(0)) revert YieldRecipientRequired();
        if (p.keeper == address(0)) revert KeeperRequired();
        if (p.navConfirmer == address(0)) revert NavConfirmerRequired();
        // Two keys that are one key are not two keys. The oracle rejects this too;
        // catching it here means a misconfigured deploy fails before it broadcasts.
        if (p.navConfirmer == p.keeper) revert NavKeysMustDiffer();
        if (p.protocolFeeWallet == address(0)) revert ProtocolFeeWalletRequired();
        // A real treasury must be a distinct address. Routing harvested USDC to the
        // key that signed the deploy is the default that looks fine and is not
        // (PRD §4.4, and the yield-routing decision the audit locked in).
        //
        // **What these two rules actually protect, corrected in audit round 22 (F11-4).** They do
        // not decide where a finished deployment's yield goes: `_wire` repoints the adapter at the
        // `EpochHarvester` and `_assertCoreGraph` refuses any deployment that ends otherwise, so
        // the shipped sink is never this address. They protect the *interim* one. Every line of
        // `_deployProtocol` is a separate broadcast transaction, so between the adapter's
        // constructor and `_wire`'s last call this address is the live sink of a live adapter
        // already installed on the vault, and a deploy that stops part way through leaves it
        // there. `test_deploy_theOperatorsYieldRecipientIsTheInterimSinkOnly` measures both halves
        // of that. See the note at the constructor call site.
        if (p.yieldRecipient == deployer) revert YieldRecipientCollision(p.yieldRecipient, "deployer");
        if (p.yieldRecipient == p.owner) revert YieldRecipientCollision(p.yieldRecipient, "owner");
    }

    /// @notice `_validateParams`, plus the one rule that is about MAKING a deployment rather than
    ///         about a set of addresses. The deploy path uses this; nothing else may.
    /// @dev **Why the guardian rule is here and not in `_validateParams`, stated as a direction and
    ///      not as a preference.** The rule's own reasoning is that `_wire` calls `setGuardian`
    ///      BEFORE `_handOver`, so once a deployment exists the only remaining route to a guardian
    ///      is a `setGuardian` the new owner has to schedule - `Config.ADMIN_TIMELOCK` of waiting
    ///      for the tool you need in order to respond to the failure. That is an argument about the
    ///      moment a deployment is created, and it can only be acted on at that moment. It is the
    ///      deploy path's rule, and it was living one level up.
    ///
    ///      **What that cost, and it is a deadlock rather than a weakness.** `_validateParams` is
    ///      also a precondition of the Phase-4 switchover, through `_resolveParams` in
    ///      `WirePhase4`'s `run()`, `queue()` and `executeQueued()`. Take a deployment made in the
    ///      documented default - an EOA owner, `RECOUP_GUARDIAN` unset, which every line of this
    ///      file argues is correct - and hand it to a timelock at G2. Now:
    ///
    ///        - `RECOUP_GUARDIAN` unset: the rule refuses, because the owner is a contract.
    ///        - `RECOUP_GUARDIAN` set to anything: `_assertCoreGraph` refuses with
    ///          `WiringIncomplete("vault.guardian")`, because the chain holds zero and no
    ///          environment value can put a guardian onto a deployed contract.
    ///
    ///      No value of one variable satisfies two constraints that disagree, so the switchover was
    ///      unreachable on the shape this repository ships. The amplifier is what makes it a
    ///      HIGH rather than an inconvenience: `queuePause()` skips `_resolveParams`, so an
    ///      operator shuts `borrow` and `depositETH` first and meets the wall afterwards, and the
    ///      only scripted `unpause` is in the batch that cannot then be queued.
    ///
    ///      **The switchover loses nothing by this move**, which is the half worth checking rather
    ///      than asserting. It still goes through `_resolveParams`, so every other rule -
    ///      `OwnerRequired`, `GuardianMustDifferFromOwner`, the four required operators,
    ///      `NavKeysMustDiffer` and both yield-recipient collisions - still applies to it. And the
    ///      guardian is constrained there by something stronger than a parameter rule:
    ///      `_assertCoreGraph` requires the deployed guardian to EQUAL `p.guardian` on all three
    ///      contracts, so at switchover time the environment cannot claim a guardian the chain
    ///      does not have, nor omit one it does. The alternative fix - dropping the switchover to
    ///      `_readParams` - was rejected on exactly that comparison: it would have removed every
    ///      one of the other rules from the switchover in order to fix one.
    ///
    ///      Relaxed locally for the same measured reason the rule always was: under `forge test`
    ///      the owner is routinely a contract with no guardian, and `_readParams` resolves an
    ///      unnamed `RECOUP_OWNER` to the deployer on the anvil chain id, which in this suite is a
    ///      test contract. Enforced locally, CI turns red on fixtures that have nothing to do with
    ///      incident response.
    ///
    ///      Zero runtime bytes, like everything else in this file: `DeployBase` is a script and is
    ///      never deployed.
    ///
    /// @dev 🟥 **SAY WHAT THIS RULE IS NOT, because two runbooks read it as something it is not.**
    ///      This is a DEPLOY-TIME SPEED BUMP and it is not the Gate-2 backstop. It refuses a FRESH
    ///      DEPLOYMENT whose owner is already a contract and whose guardian is unset. It does not
    ///      and cannot refuse the G2 handover, which is where the risk actually is: the handover is
    ///      nine plain owner transactions with no script, so this function has no caller at the one
    ///      moment the owner becomes a contract. An open finding from that round; the guardian-sequencing analysis
    ///      still expects a revert here for the right verdict and a reason that stopped being true.
    ///
    /// @dev **The `> 0` predicate refuses an EIP-7702 delegated EOA, and that is deliberate.** A
    ///      delegated EOA carries 23 bytes of code, `0xef0100` followed by the delegate address, so
    ///      `code.length > 0` catches it. Relaxing to `> 23` to admit one was REFUSED on sign
    ///      check: it is strictly more permissive, and 7702 delegation is revocable by the EOA at
    ///      any time, so admitting it would let an owner that is a contract today be a bare key
    ///      tomorrow with no guardian named. Keep `> 0`.
    ///
    ///      **23 is the single length at which the two predicates disagree**, so every other
    ///      test in this repository passes under both and exactly one goes red if it is tried
    ///      again: `test_R38_aDelegatedEoaOwnerIsRefusedAndTwentyThreeBytesIsTheBoundary` in
    ///      `R36DeployPath.t.sol`. Measured: relaxing to `> 23` left 119 of 120 green across
    ///      the five deploy-related suites, and that one red. It is the only thing in the tree
    ///      that can see the change.
    function _validateNewDeployment(GovParams memory p, address deployer) internal view {
        _validateParams(p, deployer);
        if (_isLocal()) return;

        if (p.guardian == address(0) && p.owner.code.length > 0) {
            revert GuardianRequiredForContractOwner(p.owner);
        }
    }

    /// @notice Read the mock stack's lockdown back off whatever chain the caller is on.
    /// @dev **Lifted out of `DeployTestnet` by round-39 remediation, and the lift is the fix for
    ///      two findings rather than tidying.** `DeployLocal` had no such post-condition at all,
    ///      so deleting its three `lockTo` calls was green in two independent audit streams; and
    ///      the old copy read `admin()` only, so `usdc.lockTo(deployer, address(0))` and the bond
    ///      equivalent were BOTH green while only the farm's operator was asserted anywhere.
    ///      Round-38 neuters N18 and N19. Reading `operator()` on all three closes that.
    ///
    /// @dev 🟥 **This function verifies the PLAN, not the chain, whenever it is called from inside
    ///      a `forge script` run.** `forge script` executes `run()` exactly once, in the simulation
    ///      phase, before a single transaction is sent, so calling this after `vm.stopBroadcast()`
    ///      places it after the broadcast in SOURCE ORDER only. Measured 3 of 3 against a local
    ///      anvil: with the three `lockTo` transactions among those the node discarded, the script
    ///      printed `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` and exited 0 while `admin()` was
    ///      still zero on chain. **The thing that reads the real chain is
    ///      `script/AssertLocked.s.sol`, run WITHOUT `--broadcast` after the deploy.** This
    ///      function is the cheap in-run check that the script intended to lock; that one is the
    ///      evidence that it did.
    ///
    /// @dev Takes addresses rather than mock types so this file never imports `test/mocks/`.
    ///      Zero runtime bytes: `DeployBase` is a script and is never deployed.
    function _assertMockStackLocked(
        address usdc_,
        address bond_,
        address farm_,
        address expectedAdmin,
        address expectedOperator
    ) internal view {
        _assertOneMockLocked(usdc_, expectedAdmin, expectedOperator);
        _assertOneMockLocked(bond_, expectedAdmin, expectedOperator);
        _assertOneMockLocked(farm_, expectedAdmin, expectedOperator);
    }

    /// @dev Split out so the three calls above cannot drift into asserting different things about
    ///      different mocks, which is exactly how the operator argument came to be checked on one
    ///      of the three.
    function _assertOneMockLocked(address mock, address expectedAdmin, address expectedOperator)
        private
        view
    {
        if (IMockLockdownView(mock).admin() != expectedAdmin) revert MockNotLocked(mock);
        address actualOperator = IMockLockdownView(mock).operator();
        if (actualOperator != expectedOperator) {
            revert MockOperatorWrong(mock, actualOperator, expectedOperator);
        }
    }

    // ── Deployment ───────────────────────────────────────────────────────────

    /// @notice Deploy, wire, then hand ownership over. Callable from tests, which is
    ///         the point: this is the code path a mainnet deploy takes.
    /// @dev Construct with `address(this)` as owner so the same caller can perform
    ///      every wiring call, then transfer to `p.owner` last. This ordering is not
    ///      cosmetic: once `owner` is a timelock, wiring before the handover is the
    ///      difference between a one-transaction deploy and one delayed operation per
    ///      setter. `renounceOwnership` is disabled everywhere, but `transferOwnership`
    ///      is untouched, so the handover works.
    /// @dev `deployer` is passed in rather than read from `address(this)`: under
    ///      `vm.startBroadcast` the transactions originate from the broadcasting EOA,
    ///      not from this (ephemeral) script contract, so `address(this)` would name
    ///      an address that never holds authority. Scripts pass `msg.sender`; tests
    ///      pass `address(this)`.
    /// @dev **The rules run HERE, and round 30 is why.** Until then `_validateParams` was reachable
    ///      only through `_resolveParams` and through one external wrapper in the test suite, so
    ///      every deployment performed anywhere in this repository - all of CI - went through a
    ///      path that validated nothing. The three script targets do call `_resolveParams`, so the
    ///      broadcast path was covered; what was not covered is that the rules are a property of a
    ///      DEPLOYMENT rather than of an environment read, and the one caller that skipped them was
    ///      the only caller anybody ever exercises. That is the unreached-guard shape this file
    ///      keeps finding one level down, arriving one level up.
    ///
    ///      **It is a re-check, not a second gate.** `_validateParams` is `view`, idempotent and
    ///      free of side effects, so a script that already resolved runs it twice and nothing
    ///      changes. The direction is strictly more refusing: no parameter set that was accepted
    ///      before is rejected now, and sets that were never checked are.
    ///
    ///      **`_validateNewDeployment`, which is a superset of it, and that function carries the
    ///      argument.** This line is the only caller, on purpose: it is the only place in the
    ///      repository where a deployment comes into existence, and the extra rule is about that
    ///      act rather than about the addresses.
    function _deployProtocol(Externals memory e, GovParams memory p, address deployer)
        internal
        returns (Deployed memory d)
    {
        _validateNewDeployment(p, deployer);

        d.oracle = new NAVOracle(deployer);
        // Constructed before the three contracts that hold it, because they take it as an
        // `immutable`. Seeded from `Config`'s declared defaults, which `RiskParams` re-checks
        // through the same function every later write goes through - so a deployment cannot ship
        // a risk configuration that its own setter would refuse.
        d.riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            deployer
        );
        d.vault = new CollateralVault(
            e.bond, INAVOracle(address(d.oracle)), IRiskParams(address(d.riskParams)), deployer
        );
        // owner and yieldRecipient are distinct arguments and must stay visibly
        // distinct at the call site: they are unrelated roles.
        //
        // **`p.yieldRecipient` is the INTERIM sink, not the shipped one, and audit round 22's
        // F11-4 is why that is written down here.** `_wire` repoints it to the `EpochHarvester`
        // below and `_assertCoreGraph` then *requires* the harvester, so no completed deployment
        // can end with the operator's address in place - which read as a contradiction with
        // `_validateParams` refusing a deploy over a value it was about to discard.
        //
        // It is not discarded. Under `forge script --broadcast` every `new` and every external
        // call below is its own transaction (40 of them on the 2026-08-19 testnet deploy), so this
        // address is the adapter's live yield sink for the whole span between this line and
        // `_wire`'s last one - a span that includes `vault.setCustodyAdapter` and
        // `adapter.setHarvester`. A deploy that stops part way through leaves it standing on chain.
        // That is the state `_validateParams`' three rules are about, and it is the only state
        // they are about.
        d.adapter = new DirectCallAdapter(e.bond, e.farm, e.usdc, address(d.vault), deployer, p.yieldRecipient);
        d.credit = new CreditManager(
            e.usdc,
            ICollateralVault(address(d.vault)),
            INAVOracle(address(d.oracle)),
            IRiskParams(address(d.riskParams)),
            deployer
        );
        d.pool = new LenderPool(e.usdc, deployer);
        // Funds borrows until the LenderPool takes over in Phase 4. Without it,
        // `borrow` reverts `LiquiditySourceUnset` and the deployed protocol is a
        // read-only museum piece.
        d.liquidity = new TreasuryLiquiditySource(e.usdc, deployer);
        d.harvester = new EpochHarvester(e.usdc, ICreditManager(address(d.credit)), deployer);
        d.auction = new LiquidationAuction(
            e.usdc,
            ICollateralVault(address(d.vault)),
            INAVOracle(address(d.oracle)),
            IRiskParams(address(d.riskParams)),
            deployer
        );

        _wire(d, p);

        if (p.owner != deployer) _handOver(d, p.owner);
    }

    /// @dev Every wiring call the Phase-2/3 protocol needs, made by the deployer while it still
    ///      holds authority. **The two lender-share pointers are deliberately NOT among them** -
    ///      see `_wirePhase4`.
    function _wire(Deployed memory d, GovParams memory p) internal {
        d.vault.setCustodyAdapter(ICustodyAdapter(address(d.adapter)));
        d.vault.setCreditManager(address(d.credit));
        d.vault.setLiquidationAuction(address(d.auction));

        // Go-live item G4. Called unconditionally, including with zero, so that `_assertWiring`
        // can assert the deployed value **equals the parameter** rather than merely being
        // non-wrong - the distinction this file already draws about `adapter.yieldRecipient`,
        // where three checks ruled out the sinks that strand yield and every one of them passed
        // while 100% of it went to an EOA.
        //
        // Note what the contracts' own `guardian != owner()` check can and cannot see from here:
        // at this point the owner is still `deployer`, so a guardian equal to `p.owner` passes
        // all three calls and only collapses at `_handOver`. `_validateParams` is what catches that,
        // and `_assertWiring` re-checks it after the handover, when the state is observable.
        d.vault.setGuardian(p.guardian);
        d.credit.setGuardian(p.guardian);
        // The third holder of the same role, added with the lender pool's entry pause. It sits here
        // rather than beside the pool's own two graph pointers below because what it wires is G4,
        // not the pool graph - and a role installed on two of the three contracts that carry it is
        // the half-installed shape the assertion in `_assertWiring` already exists to refuse.
        d.pool.setGuardian(p.guardian);

        d.credit.setLiquiditySource(address(d.liquidity));
        d.credit.setEpochHarvester(address(d.harvester));
        d.credit.setLiquidationAuction(address(d.auction));

        d.liquidity.setCreditManager(address(d.credit));

        // The pool's own two graph pointers stay here, and only these two - its guardian is set
        // in the G4 block above with the other two halves of that role. They cost the protocol
        // nothing while the pool is dormant: they say who the pool would answer if it were ever
        // asked, not that anyone is asking. `setCreditManager` in particular refuses once the pool
        // has principal out, so wiring it now is what keeps it wirable at all later.
        d.pool.setCreditManager(address(d.credit));
        d.pool.setEpochHarvester(address(d.harvester));

        // **Audit round 11: the two calls that used to sit here paid the lender share for zero
        // credit exposure.** `credit.setLenderPool` and `harvester.setLenderPool` were made in the
        // same breath as `credit.setLiquiditySource(address(d.liquidity))` three lines up - so the
        // treasury funded every loan and absorbed every default while `EpochHarvester`, whose
        // `flushLenderYield` is permissionless, handed pool depositors `Config.SPLIT_LENDER_BPS`
        // of every epoch. Anyone could deposit into a pool that carried none of the risk and
        // collect a quarter of the yield for it, and nothing in the protocol could stop them
        // because nothing about it was a bug in a contract: it was two lines of the deploy script.
        //
        // It got worse rather than better when the socialisation fix landed in the same round.
        // `CreditManager._socialise` now offers a loss only to a pool that is also the liquidity
        // source, because a balance sheet that lent nothing cannot be charged for a default. Under
        // the old wiring the pool was therefore the *nominal* loss sink and could never actually
        // be charged - the script named a role it had made unperformable. A wiring that states a
        // relationship the code refuses to honour is worse than no wiring at all, because
        // `_assertWiring` was asserting it and reporting the deployment healthy.
        //
        // So the lender legs move out of the shipping path entirely and into `_wirePhase4`.
        //
        // That sentence used to end "which sets the liquidity source and the loss sink together or
        // not at all", and **audit round 19 measured it false**: a broadcast emits one transaction
        // per external call, so the legs are separate transactions and there is a gap between them.
        // The one-transaction-per-external-call fact was already written down elsewhere in this
        // codebase - `DeployReferral.s.sol` states it plainly - and the two facts had simply never
        // been put next to each other. Nothing here decayed; the contradiction shipped fully
        // formed, which is a different failure from prose going stale and is not the kind a grep
        // for staleness finds. `_wirePhase4` now pauses across the gap rather than claiming there
        // is not one.
        d.harvester.setCustodyAdapter(ICustodyAdapter(address(d.adapter)));
        d.harvester.setProtocolFeeWallet(p.protocolFeeWallet);

        d.auction.setCreditManager(address(d.credit));

        // Live code today, unlike the harvester setters above: NAVOracle.setKeeper
        // works even though postNav reverts, and an unset keeper blocks everyone.
        // Wiring it now means the address is already correct when Phase 2 lands.
        d.oracle.setKeeper(p.keeper);
        // The second key on large NAV moves. Must differ from the keeper, or the
        // two-key guard on the protocol's worst realistic attack (PRD §9) collapses
        // to one key; the oracle enforces that itself.
        d.oracle.setNavConfirmer(p.navConfirmer);

        // **The yield path, which round 7 found was never actually connected.**
        // This deferral used to say the harvester link "becomes load-bearing when the
        // EpochHarvester ships" - and it has shipped: it is constructed above and
        // wired on both the manager and the pool. The trigger fired and the comment
        // outlived it.
        //
        // Two calls are needed and the old note only ever named one. `setHarvester`
        // makes the harvester a permitted claimer, without which `harvest`'s
        // `try adapter.claimYield()` swallows a `NotClaimer` revert every epoch. But
        // the money moves on the second: `_trySweepUsdc` sends the adapter's whole USDC
        // balance to `yieldRecipient`, so while that stays the treasury the split never
        // runs, every epoch reports `ZeroYieldEpoch`, and no borrower's debt is ever
        // written down. The treasury still gets its share - through the harvester's
        // protocol-fee leg, which is where the split says it belongs.
        d.adapter.setHarvester(address(d.harvester));
        d.adapter.setYieldRecipient(address(d.harvester));
    }

    /// @notice The Phase-4 switchover: the LenderPool takes over funding the book, and takes on
    ///         the losses that come with it, in one operation.
    /// @dev Not called by `_deployProtocol`. A deployment ships with the treasury float funding
    ///      borrows and no lender exposure at all, and this is the separate, later transaction
    ///      that changes that - run by whoever owns the contracts at the time, which by then is
    ///      meant to be a Safe or a timelock rather than the deploying key.
    ///
    ///      **It lives here, and is `internal` rather than private, so the tests can execute it.**
    ///      That is the entire reason `DeployBase` exists: the mainnet wiring runs in CI before it
    ///      runs on mainnet. A switchover written as a runbook step instead of as code would be
    ///      the same class of defect as the one it fixes - the old script's mainnet target
    ///      reverted, so the wiring destined for mainnet had never executed anywhere.
    ///
    ///      The calls themselves, and why they are in that order, live in `_phase4Calls` below -
    ///      which is the list this executes and the list `WirePhase4.queue()` schedules, so there
    ///      is one of it.
    ///
    ///      **Audit round 19, critical 3: the "one operation" above was never true, and the pause
    ///      is what makes it true enough.** A `forge script` broadcast emits one transaction per
    ///      external call, so these legs are separate transactions for an EOA owner and separately
    ///      queued operations under the Safe or timelock this file's sibling script is written for.
    ///      In the gap after leg 2 the pool funds the book while `credit.lenderPool` is still zero,
    ///      so `CreditManager._socialise` finds no sink, emits `LossBorneByTheSource` and returns
    ///      **above** the line that would have deferred the loss - leaving the pool's
    ///      `outstandingPrincipal` standing against a loan that no longer exists, with no backlog
    ///      for `flushSocialisedLoss` to drain and no assertion in this file able to see it.
    ///      Measured: 500,000,000 stranded, `_assertPhase4Wiring` passing over it, and the pool
    ///      welded to that manager for good because `setCreditManager` then refuses.
    ///
    ///      **Why a pause is sufficient here, which is a narrower claim than it sounds.** Pausing
    ///      this protocol does not stop the dangerous paths in general: `liquidate`,
    ///      `writeDownLoss` and `flushSocialisedLoss` are all ungated, and `borrow` is the *only*
    ///      function in `CreditManager` carrying `whenNotPaused`. **This paragraph used to end
    ///      "and `LenderPool` is not `Pausable` at all", which stopped being true with round-28
    ///      item 10**: the pool carries its own `Pausable` over `deposit` and `mint` now. That
    ///      changes nothing here, because the pool's switch is a *third* switch and this operation
    ///      does not throw it - the same relationship `depositBonds` has to the vault's, two
    ///      paragraphs down. What it does change is what an operator has to send during an
    ///      incident, where the pause is now four transactions rather than three. It is enough because of what leg 2 already
    ///      demands: `setLiquiditySource` refuses while `totalDebt` or `pendingPrincipal` is
    ///      non-zero, so **no pre-existing position can be carried into the gap and defaulted
    ///      there** - and by the identity `outstandingPrincipal == pendingPrincipal + totalDebt`
    ///      that same precondition also pins the pool's own principal at zero on entry. A fresh
    ///      borrow is the only door into the gap, and the pause is the lock on that one door.
    ///      Do not "improve" this by relaxing leg 2's precondition; it is half the reason the
    ///      pause works.
    ///
    ///      The vault is paused for the same span. **That sentence used to continue "its
    ///      `depositBonds`/`depositETH` are the only other `whenNotPaused` functions in the
    ///      protocol", and since the round-27 remediation only `depositETH` is** - `depositBonds`
    ///      moved onto its own owner-only switch, which this operation deliberately does NOT
    ///      throw.
    ///
    ///      **That is a decision, not an oversight, and it is worth the paragraph.** The pause
    ///      here was precautionary rather than load-bearing on the collateral side: its own text
    ///      says new collateral arriving mid-switchover "is the same class of mistake even though
    ///      it is not the one that was measured", and the measured lock is `borrow` plus leg 2's
    ///      `outstandingPrincipal == 0` precondition. A bond deposit creates no debt and moves no
    ///      principal, so it cannot disturb either. Meanwhile a switchover sits behind a 48-hour
    ///      timelock, and shutting the borrower's cure for that span is **exactly** the harm audit
    ///      round 25 finding 1 measured and the round-27 remediation removed. Restoring it here
    ///      would re-create that finding inside a governance operation.
    ///
    ///      So the rule the rest of the protocol now follows applies to the switchover too: shut
    ///      what creates risk, never what resolves it.
    ///
    ///      **Audit round 20, finding 5: the pause is correct against the operator and is defeated
    ///      by the timelock executor, so the legs became a list.** Round 19's residual was written
    ///      as "an operator who transcribes the legs by hand can omit the pause". The measured route
    ///      is worse and needs no mistake at all: the operator transcribes *every* leg faithfully,
    ///      and still loses, because under `TimelockController` as `Governance.t.sol` and
    ///      `RiskParameters.t.sol` both deploy it - `executors[0] = address(0)`, open execution,
    ///      `predecessor = bytes32(0)` on every scheduled operation - **the execution order is not
    ///      the operator's to choose**. Once matured, any stranger runs them in any order. Executing
    ///      `setLiquiditySource` first and the pause not at all reopens exactly round 19's gap:
    ///      500,000,000 stranded, byte-identical, `_assertPhase4Wiring` passing over it.
    ///
    ///      The tell was already in the tree. `RiskParams.setRiskParams`' own docstring states this
    ///      hazard - "two scheduled operations' windows can be executed in either order once both
    ///      have matured" - and then explicitly contrasts itself with this function. Nothing
    ///      decayed; the two facts never met.
    ///
    ///      **The fix is `_phase4Calls`, and it removes the window rather than guarding it.** One
    ///      `scheduleBatch` is one operation with one id, and `executeBatch` runs the whole array in
    ///      order in a single transaction or reverts. There is no gap for an executor to reorder
    ///      into, no subset that is a schedulable id, and no leg that can be left unexecuted. See
    ///      `WirePhase4.queue()`, which is the only sanctioned way to put this operation into a
    ///      timelock.
    ///
    ///      **What this does NOT do, recorded rather than glossed - and it is a narrower residual
    ///      than round 19's.** Nothing on chain refuses eight separately scheduled operations. A
    ///      proposer who ignores `queue()` and hand-builds eight singles in a Safe UI reopens the
    ///      whole finding. What changed is that the correct thing to transcribe is now *one* call
    ///      with calldata the script prints, rather than eight the operator must order themselves.
    ///      In the pre-governance register the owner is an EOA, there is no timelock and nothing to
    ///      batch through: there the eight legs are eight sequential transactions from one key, the
    ///      pause is legs 1 and 2, and no third party can act between them except by paying to be
    ///      mined in between - which the pause is what closes. Batching buys the EOA case nothing
    ///      and costs it nothing.
    ///
    ///      **Audit round 21, finding 2: round 20's batch put the pause inside the room it was
    ///      locking.** Wrapping round 19's identical list in one `scheduleBatch` removes the gap the
    ///      pause was closing - so in that register the pause legs protect nothing - while moving
    ///      the precondition they were guarding (`totalDebt == 0 && pendingPrincipal == 0`) to
    ///      **forty-eight hours after the operator committed**, into a window where `borrow` is wide
    ///      open *precisely because* the pause that would close it is leg 1 of the batch being
    ///      blocked. MEASURED: one micro-USDC of debt - 0.000001 USDC, borrowed by a stranger who
    ///      simply deposits collateral through the front door - makes `executeBatch` revert
    ///      `DebtOutstanding(1)`, and `TimelockController` has no grace period, so the refused
    ///      operation stays `Ready` (MEASURED at 365 days) as a live stranger-executable replay of
    ///      the largest pointer move this protocol has.
    ///
    ///      **So the pause legs come out of the batch and are performed before the window opens.**
    ///      They are their own operation now (`_phase4PauseCalls`, and `WirePhase4.queuePause()`
    ///      under a timelock), executed first, and `queue()` refuses to schedule the switchover at
    ///      all while either contract is still unpaused. The stranger's borrow is then refused at
    ///      the door - `EnforcedPause` - instead of taking the whole batch down at execution time.
    ///
    ///      **Only the `pause` legs move. The `unpause` legs stay inside the batch**, and that is
    ///      not just the obvious "or the protocol is left shut": OZ's `_unpause()` carries
    ///      `whenPaused`, so if the pause is *not* in force when the batch executes those trailing
    ///      legs revert `ExpectedPause` and `executeBatch`, being all-or-nothing, undoes the whole
    ///      switchover. The precondition is therefore checked at generation time by `queue()` and
    ///      **enforced on chain at execution time by legs that were already there**. The same holds
    ///      for `queue()`'s other two reads without any new code: `setLiquiditySource` refuses on
    ///      `totalDebt` and `unsocialisedLoss` itself, when it runs.
    ///
    ///      **The residual, and it is what "decided at a different time from when it is enforced"
    ///      still buys.** Nothing on chain sequences the pause operation before the switchover
    ///      operation. `queue()` will not *create* the second while the first has not landed, so
    ///      the sanctioned path cannot produce an unguarded window - but a proposer hand-building
    ///      both in a Safe UI can schedule them together, and then they mature together and the
    ///      pause protects the same zero duration it did before. That is round 20's residual
    ///      unchanged in shape and one step narrower in size: the thing an operator must not do by
    ///      hand is now "schedule two operations at once" rather than "order eight legs". A
    ///      `predecessor` chain would not close it either - it forces the pause to execute first,
    ///      not earlier - which is why `WirePhase4.PREDECESSOR` stays `bytes32(0)` and says so.
    ///
    ///      Also two calls to transcribe now rather than one, which corrects the paragraph above:
    ///      `queuePause()` then `queue()`, each still one call with calldata the script prints.
    ///
    ///      The EOA register is unchanged: this function still performs pause legs first and the
    ///      switchover second, in one broadcast, in exactly the order it used to.
    function _wirePhase4(Deployed memory d) internal {
        (address[] memory pauseTargets,, bytes[] memory pausePayloads) = _phase4PauseCalls(d);
        _runLegs(pauseTargets, pausePayloads, 0);

        (address[] memory targets,, bytes[] memory payloads) = _phase4Calls(d);
        _runLegs(targets, payloads, pauseTargets.length);
    }

    /// @dev The offset keeps `SwitchoverLegFailed`'s index numbering continuous across the two
    ///      lists, so an operator reading a failure still counts legs the way the broadcast emits
    ///      them rather than restarting at zero half way through.
    function _runLegs(address[] memory targets, bytes[] memory payloads, uint256 offset) private {
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory ret) = targets[i].call(payloads[i]);
            if (!ok) _bubbleRevert(offset + i, targets[i], ret);
        }
    }

    /// @notice The two legs that must be in force *before* the switchover window opens, as data.
    /// @dev **Split out of `_phase4Calls` by audit round 21, finding 2.** Inside the batch these
    ///      executed in the same transaction as the preconditions they were meant to protect, which
    ///      is a zero-duration lock. Outside it they shut `borrow` and `depositBonds`/`depositETH`
    ///      for the whole 48-hour maturity window, which is the only span in which anybody could
    ///      have created the debt that blocks the switchover.
    ///
    ///      `CreditManager.borrow` is the only `whenNotPaused` function in that contract and the
    ///      vault's two deposits are the only ones in the protocol, which is why two legs is the
    ///      whole list. Pausing does not stop `liquidate`, `writeDownLoss`, `flushSocialisedLoss`
    ///      or any `LenderPool` entry point, and it is not meant to: resolution stays open, new
    ///      risk does not.
    ///
    ///      `pure`, like `_phase4Calls`, and for the same reason.
    function _phase4PauseCalls(Deployed memory d)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);

        targets[0] = address(d.credit);
        payloads[0] = abi.encodeCall(CreditManager.pause, ());

        targets[1] = address(d.vault);
        payloads[1] = abi.encodeCall(CollateralVault.pause, ());
    }

    /// @notice The switchover as data: every call it makes, in the order it makes them.
    /// @dev **The single definition of "the switchover", and both ways of performing one read it.**
    ///      `_wirePhase4` executes this list; `WirePhase4.queue()` hands the identical list to
    ///      `TimelockController.scheduleBatch`. That is deliberate and it is the answer to a second
    ///      round-20 item: the repo said "the three calls" in four places for an operation that is
    ///      eight, and the five it omitted were the entire round-19 fix - so the prose was
    ///      instructing an operator to skip it. **Nothing counts these by hand any more.** The count
    ///      is `_phase4Calls(...).length`, printed by `queue()` and asserted against the executed
    ///      sequence in `Deploy.t.sol`. Do not write the number down anywhere.
    ///
    ///      The order is load-bearing, top to bottom:
    ///
    ///      1. `settlePrincipal` before any pointer moves. `setLiquiditySource` refuses while
    ///         `pendingPrincipal` is non-zero, and the manager's own migration notes say the
    ///         principal becomes unreachable by every contract if the pointer moves before the
    ///         money does.
    ///      2. `setLiquiditySource` before `setLenderPool`, so the pool is the funder before it is
    ///         the sink. Never the reverse: a pool named as the loss sink while the treasury still
    ///         funds the book is exactly the shipped state round 11 found, and `_socialise` would
    ///         refuse to charge it anyway.
    ///      3. `harvester.setLenderPool` last, because it is the leg that starts paying. The
    ///         lender share is only earned once the pool is carrying the credit risk, and every
    ///         epoch harvested before this line stays accrued in `pendingLenderYield` and is
    ///         delivered whole by the first `flushLenderYield` after it. Nothing is lost by
    ///         waiting; something is given away by not.
    ///      4. `unpause` both, last, and `_assertPhase4Wiring` is what catches a run that never
    ///         reached them. They also carry `whenPaused`, which is what makes them the on-chain
    ///         check that the pause `_phase4PauseCalls` performs was still in force at execution
    ///         time - see `_wirePhase4`.
    ///
    ///      **There is no longer a data-dependent leg, and that is audit round 21, finding 3.**
    ///      `settlePrincipal` used to be written into the list only when `pendingPrincipal() != 0`,
    ///      read live at *generation* time, because the call reverted `NothingToSettle` at zero and
    ///      a switchover on a book that was already flat must not fail for being tidy. But
    ///      `settlePrincipal` is permissionless and free, so **a stranger chose the batch's shape**:
    ///      MEASURED, an eight-leg batch was queued, a griefer spent 42,744 gas zeroing the counter,
    ///      and both routes died - `executeBatch` of the queued array reverted `NothingToSettle`,
    ///      while `executeQueued()`'s re-derivation produced a seven-leg array whose id nobody had
    ///      ever scheduled (`TimelockUnexpectedOperationState`).
    ///
    ///      The root cause was the revert, not the branch. `settlePrincipal` now returns early at
    ///      zero, so the leg is unconditional, the leg count is a constant, and **this function
    ///      reads no mutable state at all - which the `pure` below is the compiler enforcing.**
    ///      Correctness does not move to the settle leg having found something: `setLiquiditySource`
    ///      independently refuses while `pendingPrincipal != 0`, and it runs immediately after the
    ///      settle inside the same atomic `executeBatch`. That makes the batch **immune** to the
    ///      front-run rather than defended against it.
    ///
    ///      Do not reintroduce a conditional leg here. A `view` on this function is the tell.
    function _phase4Calls(Deployed memory d)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        uint256 n = 6;
        targets = new address[](n);
        // Every leg is non-payable, so this array is all zeros. `scheduleBatch` requires it to
        // exist and to be the same length, which is the only reason it is returned.
        values = new uint256[](n);
        payloads = new bytes[](n);

        uint256 i;
        targets[i] = address(d.credit);
        payloads[i++] = abi.encodeCall(CreditManager.settlePrincipal, ());

        targets[i] = address(d.credit);
        payloads[i++] = abi.encodeCall(CreditManager.setLiquiditySource, (address(d.pool)));

        targets[i] = address(d.credit);
        payloads[i++] = abi.encodeCall(CreditManager.setLenderPool, (address(d.pool)));

        targets[i] = address(d.harvester);
        payloads[i++] = abi.encodeCall(EpochHarvester.setLenderPool, (address(d.pool)));

        targets[i] = address(d.vault);
        payloads[i++] = abi.encodeCall(CollateralVault.unpause, ());

        targets[i] = address(d.credit);
        payloads[i++] = abi.encodeCall(CreditManager.unpause, ());

        // **Weaker than it was, and said so rather than left looking the same.** While the leg
        // count was a ternary this compared two independent expressions of one decision. Round 21
        // removed the branch, so the only drift it can still catch is a leg *removed* without `n`
        // being lowered - which would otherwise ship a batch ending in a call to address zero with
        // empty calldata, and `scheduleBatch` would take it. The opposite mistake, a leg added
        // without raising `n`, is caught by the array write itself.
        assert(i == n);
    }

    /// @dev Re-throw the callee's own revert so a failed switchover names the failure in the terms
    ///      the operator will recognise (`DebtOutstanding`, `EnforcedPause`, `ExpectedPause`),
    ///      rather than flattening every leg into one anonymous failure. The typed calls this
    ///      replaced did that for free; a list of low-level calls has to do it on purpose.
    function _bubbleRevert(uint256 index, address target, bytes memory ret) private pure {
        if (ret.length == 0) revert SwitchoverLegFailed(index, target);
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /// @dev Ownership moves last, after everything is wired.
    ///      Every `Ownable` in `Deployed` belongs in this list. `d.liquidity` was missing from it,
    ///      and from `_assertWiring` below, and from the equivalent list in `test/Deploy.t.sol` -
    ///      so a deployment handing seven contracts to the governance Safe left the eighth with
    ///      the broadcasting EOA, and the post-condition check that exists to catch exactly this
    ///      reported success. The omitted one holds the whole lending float behind an uncapped
    ///      `onlyOwner withdraw(to, amount)`, and CI asserted "the deployer owns nothing" while
    ///      the deployer owned the money.
    function _handOver(Deployed memory d, address newOwner) internal {
        d.vault.transferOwnership(newOwner);
        d.adapter.transferOwnership(newOwner);
        d.oracle.transferOwnership(newOwner);
        d.credit.transferOwnership(newOwner);
        d.pool.transferOwnership(newOwner);
        d.harvester.transferOwnership(newOwner);
        d.auction.transferOwnership(newOwner);
        d.liquidity.transferOwnership(newOwner);
        // Added with `RiskParams` itself, in the same edit as `_assertWiring` and
        // `Deploy.t.sol`'s two ownership tests. `d.liquidity` was once missing from exactly these
        // three lists at once, and CI reported the deployment healthy while the deploying key
        // still owned the money.
        d.riskParams.transferOwnership(newOwner);
    }

    // ── Post-conditions ──────────────────────────────────────────────────────

    /// @notice Assert the deployment is actually usable. Reverting the whole script
    ///         is the point: a half-wired protocol should never be left on chain.
    function _assertWiring(Deployed memory d, GovParams memory p) internal view {
        _assertCoreGraph(d, p);

        // **The two legs that must be unset, and asserting that is not the same as dropping the
        // assertion.** These two lines used to require both pointers to name the pool, which is
        // how audit round 11 found a deployment paying `Config.SPLIT_LENDER_BPS` of every epoch to
        // depositors who funded no loan and could not be charged for a default. The temptation on
        // finding that is to delete the checks along with the wiring; this file's own comment
        // fifty lines down is why that is wrong - "ruling out wrong destinations is not the same
        // as asserting the right one", and for a pre-Phase-4 deployment the right one is nothing.
        //
        // Zero is a real, checkable post-condition here, not an absence. `CreditManager` treats an
        // unset `lenderPool` as "the source bears its own losses" and `EpochHarvester` refuses the
        // flush with `NotWired("lenderPool")` while accruing the share for whoever eventually
        // earns it, so both contracts have a defined and safe behaviour at zero. Asserting it is
        // what stops the two lines being quietly restored.
        if (d.credit.lenderPool() != address(0)) revert LenderExposureWiredEarly("credit.lenderPool");
        if (d.harvester.lenderPool() != address(0)) revert LenderExposureWiredEarly("harvester.lenderPool");

        // Without these two the protocol deploys but cannot lend a cent, which is the
        // failure mode worth catching in the script rather than in production. **Not shared with
        // the Phase-4 assertion**, because this is the one pointer the switchover genuinely moves:
        // afterwards the source is the pool, and asserting the treasury there would refuse the
        // deployment the switchover exists to produce.
        if (d.credit.liquiditySource() != address(d.liquidity)) {
            revert WiringIncomplete("credit.liquiditySource");
        }
        // `liquidity.creditManager` moved into `_assertCoreGraph` in audit round 16, because the
        // switchover does not touch it and that is the shared function's inclusion rule. It is not
        // restated here for the reason the whole consolidation exists: two hand-maintained copies
        // of one set is how the drift happened twice.
    }

    /// @notice Everything both wiring assertions must check, because the switchover does not move
    ///         any of it.
    /// @dev **Shared rather than restated, and the reason is the finding that produced it.** Audit
    ///      round 15 found `_assertWiring` testing four pointers for non-zero instead of for the
    ///      right address, in a file that says "ruling out wrong destinations is not the same as
    ///      asserting the right one" fifty lines further down, and found `_assertPhase4Wiring`
    ///      silently missing about eighteen of these including **every** ownership check. Two
    ///      hand-maintained copies of one set is how both happened, so there is now one copy.
    ///
    ///      What deliberately stays out: the two `LenderExposureWiredEarly` checks, which Phase 4
    ///      exists to invert, and the treasury liquidity source, which it replaces. Both are stated
    ///      in the callers rather than parameterised here, because a shared function branching on
    ///      "which phase" would have to be read twice to answer either question.
    ///
    ///      **`internal` rather than `private` since audit round 22, finding 7.** `WirePhase4`
    ///      calls it *before* `scheduleBatch` as well as after `executeBatch`, and it is the only
    ///      caller outside this file. The reason is in `WirePhase4._queue`: this function is
    ///      exactly the half of `_assertPhase4Wiring` that is already true at queue time, so
    ///      running it there costs nothing and moves every failure it can name from the far side
    ///      of a forty-eight hour window to the near side.
    function _assertCoreGraph(Deployed memory d, GovParams memory p) internal view {
        // **Derived from `Deployed`, never enumerated, and the third instance of one finding is
        // why.** This block was a hand-typed list of eight, and `d.riskParams` was the ninth. That
        // is round 10's finding exactly - `d.liquidity` was once missing from this list, from
        // `_handOver`, and from `test/Deploy.t.sol`'s ownership test at the same time - and the
        // comment fifty lines up in this very file describes that incident. Adding a ninth line
        // here would not be the fix; it is what was done last time, and it is what left the list
        // able to fall behind the struct again.
        //
        // The captured contract this time is worse than the last one. Measured with a control:
        // `riskParams.transferOwnership(stranger)` left both `_assertWiring` and
        // `_assertPhase4Wiring` passing, while the identical move on any of the other eight
        // reverted `OwnershipNotTransferred`. Whoever holds it can ratchet every parameter to its
        // terminus in one transaction, and the threshold half is irreversible by design - the
        // recovered rightful owner is refused with `LiquidationThresholdLowered`, and
        // `renounceOwnership` is disabled, so it cannot even be resolved by abdication. The repair
        // is redeploying `RiskParams` and the three contracts holding it `immutable`.
        //
        // So the list comes from the struct. A tenth contract joins it by existing.
        address[] memory ownables = _ownablesOf(d);
        for (uint256 i; i < ownables.length; ++i) {
            _requireOwner(ownables[i], Ownable(ownables[i]).owner(), p.owner);
        }

        // The pool's own two legs, which a shipping deployment does set. Each fails quietly rather
        // than loudly: a wrong `pool.epochHarvester` is swallowed by the harvester's best-effort
        // catch and the lender share accrues forever with no error at all. `_wire` set them and
        // this block checked neither, which is the shape audit-7 finding #6 named.
        if (d.pool.creditManager() != address(d.credit)) revert WiringIncomplete("pool.creditManager");
        if (d.pool.epochHarvester() != address(d.harvester)) revert WiringIncomplete("pool.epochHarvester");

        if (address(d.vault.custodyAdapter()) != address(d.adapter)) revert WiringIncomplete("vault.custodyAdapter");
        if (d.vault.creditManager() != address(d.credit)) revert WiringIncomplete("vault.creditManager");
        if (d.vault.liquidationAuction() != address(d.auction)) revert WiringIncomplete("vault.liquidationAuction");

        // The other two legs of the same triangle. Both are wired in `_wire` and
        // neither was asserted, so a deployment could reach production able to seize
        // collateral but unable to open an auction, or with an auction nothing would
        // accept settlement from. Now Phase 3 is real, that is not theoretical.
        if (d.credit.liquidationAuction() != address(d.auction)) {
            revert WiringIncomplete("credit.liquidationAuction");
        }
        if (d.auction.creditManager() != address(d.credit)) revert WiringIncomplete("auction.creditManager");

        // **All three risk readers must be reading the same contract.** The pointers are
        // `immutable`, so this cannot drift after deployment - but it can be got wrong *at*
        // deployment, by constructing one of them against a second `RiskParams`. Then the vault
        // would refuse a withdrawal against one ceiling while the manager approved a borrow
        // against another, and nothing else in the system would notice. This is the assertion
        // that makes the immutability worth having: it checks the one moment at which the graph
        // can still be built wrong.
        if (address(d.credit.riskParams()) != address(d.riskParams)) {
            revert WiringIncomplete("credit.riskParams");
        }
        if (address(d.vault.riskParams()) != address(d.riskParams)) {
            revert WiringIncomplete("vault.riskParams");
        }
        if (address(d.auction.riskParams()) != address(d.riskParams)) {
            revert WiringIncomplete("auction.riskParams");
        }

        // **And all three nav readers must be reading the same feed.** The block above was written
        // in round 20 about the risk pointer and every word of it applies unchanged to this one -
        // which is precisely the criticism audit round 21 made: six lines here compared the risk
        // readers and not one compared the nav readers, on the same three contracts, over the same
        // `immutable` shape. The two lines below it assert `oracle.keeper()` and
        // `oracle.navConfirmer()`, so this file was already asserting things *about* the oracle
        // while never asking whether the graph agreed on which oracle it was.
        //
        // As with the risk triple, these are `immutable`, so this cannot drift after deployment -
        // it can only be got wrong *at* deployment, and this is the assertion for that moment. The
        // contract-level guards added in the same change are what cover the migration, which has no
        // script around it.
        if (address(d.credit.navOracle()) != address(d.oracle)) {
            revert WiringIncomplete("credit.navOracle");
        }
        if (address(d.vault.navOracle()) != address(d.oracle)) {
            revert WiringIncomplete("vault.navOracle");
        }
        if (address(d.auction.navOracle()) != address(d.oracle)) {
            revert WiringIncomplete("auction.navOracle");
        }

        // **And the third shared immutable, which is the money, and which had neither a contract
        // guard nor a line here. Audit round 22, finding 13.** The two blocks above compare the
        // risk readers and the nav readers - three contracts each, six guards each in the
        // contracts themselves. `usdc` is held by *six* members of this struct and `bond` by two,
        // and until this block the census stopped at the two cheapest triples.
        //
        // MEASURED, with a control: a `LenderPool` constructed on a *second* USDC, wired exactly
        // as `_wire` wires one, went through the entire Phase-4 switchover with every leg
        // accepting, and `_assertPhase4Wiring` passed over it. The same substitution one field
        // over - a pool pointed at a second `CreditManager` - reverted `WiringIncomplete`, so the
        // assertion set was not blind in general. It was blind to the settlement token
        // specifically, because nothing in it ever asked.
        //
        // **What actually holds the money today, and it is not this line, so read it as defence in
        // depth rather than as the last thing standing.** MEASURED on the rogue pool: `borrow`
        // reverts `LiquidityNotDelivered(3000000000, 0)` and no real USDC moves, because
        // `CreditManager.borrow` measures its own balance either side of `lend()` and compares the
        // delta with the amount asked for. That balance bracket is a runtime asset-identity check
        // nobody had framed as one. It fails closed - a denial of service, not a drain - and it
        // fails at the first borrow rather than at deployment, which is the whole reason to have
        // the question asked here as well.
        //
        // Anchored on the manager because the manager is the contract that counts the delta above:
        // "the settlement token" is definitionally the one it measures itself in. A member that
        // disagrees with it is the member that is wrong, whichever member it is - and one wrong
        // address cannot pass this block by moving the anchor, because the other five would then
        // disagree with the anchor instead.
        address settlement = address(d.credit.usdc());
        if (address(d.auction.usdc()) != settlement) revert WiringIncomplete("auction.usdc");
        if (address(d.harvester.usdc()) != settlement) revert WiringIncomplete("harvester.usdc");
        if (address(d.liquidity.usdc()) != settlement) revert WiringIncomplete("liquidity.usdc");
        if (address(d.adapter.usdc()) != settlement) revert WiringIncomplete("adapter.usdc");
        if (d.pool.asset() != settlement) revert WiringIncomplete("pool.asset");

        // The collateral token, same finding, two holders. Anchored on the vault for the reason
        // `WirePhase4._resolveDeployed` derives `riskParams` off it: the vault is the one member of
        // this graph with no setter anywhere and no replacement path.
        address collateral = address(d.vault.bond());
        if (address(d.adapter.bond()) != collateral) revert WiringIncomplete("adapter.bond");

        // The receiver implementation is created inside the adapter constructor, so it is not a
        // separately owned or wired member of `Deployed`. It is still part of the immutable
        // custody graph and must be checked and printed: every per-attempt clone delegates to it.
        MintAttemptReceiver receiverImplementation = d.adapter.mintReceiverImplementation();
        if (address(receiverImplementation).code.length == 0) {
            revert WiringIncomplete("adapter.mintReceiverImplementation");
        }
        if (receiverImplementation.adapter() != address(d.adapter)) {
            revert WiringIncomplete("mintReceiver.adapter");
        }
        if (address(receiverImplementation.bond()) != address(d.adapter.bond())) {
            revert WiringIncomplete("mintReceiver.bond");
        }
        if (address(receiverImplementation.farm()) != address(d.adapter.farm())) {
            revert WiringIncomplete("mintReceiver.farm");
        }
        if (address(receiverImplementation.usdc()) != address(d.adapter.usdc())) {
            revert WiringIncomplete("mintReceiver.usdc");
        }

        // **`adapter.vault` deliberately has NO line here, and the reason is a measurement rather
        // than an omission.** The back-pointer on the same edge looks like the obvious companion
        // to `vault.custodyAdapter` twenty lines up, and a `WiringIncomplete("adapter.vault")` was
        // written, compiled, and found to be unreachable: `CollateralVault.setCustodyAdapter`
        // reads `adapter.vault()` and reverts `AdapterVaultMismatch` unless it is the installing
        // vault, and that setter is the pointer's only writer. So with the line above holding,
        // this one cannot fail. MEASURED: an adapter constructed against a different vault is
        // refused by `setCustodyAdapter` itself, before any of this runs.
        //
        // That is also what makes `adapter.bond` above the real gap rather than a matching pair.
        // The same setter guards the vault identity and does **not** guard the ERC-1155: an adapter
        // holding a different `MockBond` installs with no revert. That half is in `src/` and is
        // filed separately; this is only the deploy-time half of it, and a `setCustodyAdapter`
        // performed after the script has run is not reached by anything in this file.

        // **These four tested for non-zero rather than for the right address, and this file names
        // the rule it was breaking a few lines below: "ruling out wrong destinations is not the
        // same as asserting the right one". It said it and then broke it four times**, which is
        // what audit round 15 found.
        //
        // The cost is not cosmetic, and it is worst on the first. A harvester pointed at some
        // *other* live adapter passes a non-zero check, and then `harvest()` declines every epoch
        // forever with `EpochDeclinedUncorroborated`, because `lastCorroboratedYield` is seeded
        // from a counter on an adapter nothing else moves. Repair is `onlyOwner`, and by go-live
        // the owner is a timelock.
        //
        // All four are set from exactly these values in `_wire`, so the happy path is unchanged and
        // only a wrong deployment starts failing.
        if (address(d.harvester.custodyAdapter()) != address(d.adapter)) {
            revert WiringIncomplete("harvester.custodyAdapter");
        }
        if (d.harvester.protocolFeeWallet() != p.protocolFeeWallet) {
            revert WiringIncomplete("harvester.protocolFeeWallet");
        }
        if (d.oracle.keeper() != p.keeper) revert WiringIncomplete("oracle.keeper");
        if (d.oracle.navConfirmer() != p.navConfirmer) revert WiringIncomplete("oracle.navConfirmer");

        // Go-live item G4, all three halves of the role, asserted as equality rather than as
        // non-zero.
        if (d.vault.guardian() != p.guardian) revert WiringIncomplete("vault.guardian");
        if (d.credit.guardian() != p.guardian) revert WiringIncomplete("credit.guardian");
        if (d.pool.guardian() != p.guardian) revert WiringIncomplete("pool.guardian");
        // **The check neither contract can make for itself.** `setGuardian` compares against the
        // owner at call time, which during `_wire` is still the deployer - so a guardian equal to
        // the incoming owner passes there and collapses one `transferOwnership` later. This runs
        // after `_handOver`, which is the first moment the final pairing is observable on chain.
        if (p.guardian != address(0)) {
            if (d.vault.guardian() == d.vault.owner()) revert GuardianMustDifferFromOwner();
            if (d.credit.guardian() == d.credit.owner()) revert GuardianMustDifferFromOwner();
            if (d.pool.guardian() == d.pool.owner()) revert GuardianMustDifferFromOwner();
        }

        // The audit's finding #1 in assertion form: the vault has no USDC egress, so
        // routing yield there strands it permanently.
        address sink = d.adapter.yieldRecipient();
        if (sink == address(d.vault)) revert YieldRecipientCollision(sink, "vault");
        if (sink == address(d.adapter)) revert YieldRecipientCollision(sink, "adapter");
        if (sink == address(0)) revert YieldRecipientRequired();
        // The three checks above rule out the sinks that strand yield, and every one
        // of them passed while 100% of it went to an EOA and the whole split sat idle.
        // Ruling out wrong destinations is not the same as asserting the right one.
        if (sink != address(d.harvester)) revert WiringIncomplete("adapter.yieldRecipient");
        if (d.adapter.harvester() != address(d.harvester)) revert WiringIncomplete("adapter.harvester");
        if (d.credit.epochHarvester() != address(d.harvester)) revert WiringIncomplete("credit.epochHarvester");

        // **The two audit round 16 found missing, and neither was in the exclusions list**, so both
        // read as drift rather than intent - which is the two-hand-maintained-lists failure this
        // consolidation was written to end.
        //
        // `harvester.creditManager` is the only pointer in the graph that is constructor-set with a
        // live `onlyOwner` setter behind it, and its divergence bricks the permissionless
        // `harvest()` forever with an `onlyOwner` repair. Four agents.
        if (address(d.harvester.creditManager()) != address(d.credit)) {
            revert WiringIncomplete("harvester.creditManager");
        }
        // `liquidity.creditManager` was asserted only in `_assertWiring`, even though `_wirePhase4`
        // does not move it - and "everything the switchover does not change" is this function's own
        // stated inclusion rule. Three agents. The treasury source keeps this pointer after the
        // switchover: the pool becomes the funder, and the float it is being replaced as still
        // answers to the same manager for whatever is left to settle home.
        if (d.liquidity.creditManager() != address(d.credit)) {
            revert WiringIncomplete("liquidity.creditManager");
        }
    }

    /// @notice The post-condition for `_wirePhase4`, and the counterpart to `_assertWiring`'s two
    ///         "must still be zero" checks.
    /// @dev Deliberately a separate function rather than a flag on `_assertWiring`. The two
    ///      describe states that contradict each other on three pointers, and a single function
    ///      branching on a boolean would have to be read twice to answer either question. Run this
    ///      one immediately after the switchover transaction; `_assertWiring` no longer holds once
    ///      it has, because `credit.liquiditySource` is the pool rather than the treasury float.
    ///
    /// @param p **Looks unused and is not. KEPT, decided in audit round 30, with the mechanism
    ///        named here so the next grep does not have to re-find it.** There is no `p.<field>`
    ///        anywhere in this body, which is what a field-access grep measures - and this function
    ///        hands the struct WHOLE to `_assertCoreGraph`, which reads `p.owner` at every one of
    ///        its ownership checks. Passing a zeroed struct instead was tried and reverts
    ///        `OwnershipNotTransferred` against `address(0)`.
    ///        `test_assertPhase4Wiring_readsItsGovParamsAndAZeroedStructIsRefused` is that
    ///        measurement as an assertion, so the claim in this paragraph is executable rather than
    ///        remembered.
    ///
    ///        **Narrowing it to `address owner` was considered and refused.** Twenty call sites
    ///        pass the struct, `_assertCoreGraph` is shared with `_assertWiring` and with
    ///        `WirePhase4._queue`, and the parameter is the only route by which a future operator
    ///        field could ever be asserted after a switchover. Round 15's finding on this exact
    ///        function was assertions being DROPPED; narrowing the type is how the next one gets
    ///        dropped without anybody deciding to.
    function _assertPhase4Wiring(Deployed memory d, GovParams memory p) internal view {
        // **Everything `_assertWiring` checks that a switchover does not change, and audit round 15
        // is why it is here.** This function dropped roughly eighteen assertions, including every
        // ownership check - so nothing after the switchover re-verified that the eight contracts
        // were owned by anybody in particular, and `d.liquidity` is the one that has been missed
        // twice before while holding the lending float behind an uncapped `onlyOwner` withdraw.
        //
        // Shared rather than restated, because the drift between these two lists *is* the finding.
        // Two hand-maintained copies of one set is how the first one came to name a rule it broke
        // four times.
        _assertCoreGraph(d, p);

        // Every pointer the switchover moves, together. Half a switchover is the failure this
        // exists to catch: the pool funding borrows without being the loss sink means depositors
        // take the credit risk and the deferral counter never fills, and the sink without the
        // funding is round 11 all over again.
        if (d.credit.liquiditySource() != address(d.pool)) revert WiringIncomplete("credit.liquiditySource");
        if (d.credit.lenderPool() != address(d.pool)) revert WiringIncomplete("credit.lenderPool");
        if (d.harvester.lenderPool() != address(d.pool)) revert WiringIncomplete("harvester.lenderPool");

        // Redundant against the two lines above only for as long as both compare with the same
        // `d.pool`, and that is the point of stating it separately: this is the relation
        // `CreditManager._socialise` and `flushSocialisedLoss` actually evaluate at runtime, read
        // off the contract rather than off this struct. It stays a true statement of the intent
        // even if somebody rewrites what the assertions above compare against.
        address source = d.credit.liquiditySource();
        address sink = d.credit.lenderPool();
        if (source != sink) revert LenderRolesDisagree(source, sink);

        // The pool's own legs are as load-bearing after the switchover as before it - `lend` and
        // `repayPrincipal` are `onlyCreditManager`, so a pool pointing at the wrong manager funds
        // nothing and the first borrow reverts - and they are now asserted in `_assertCoreGraph`
        // above, along with everything else the switchover leaves alone.

        // **The pause has to come back off, and nothing else was watching for that.** `_wirePhase4`
        // pauses across the gap, which means a run that dies part-way - a reverted leg, a Safe
        // signer who stops signing, an operator who executed every leg of `_phase4Calls` except
        // the two `unpause`s at the end - leaves the
        // protocol unable to take a borrow or a deposit with no error anywhere saying so. Under an
        // EOA owner the fix is one transaction; under the timelock this protocol is heading for it
        // is a 48-hour wait, which is exactly the situation somebody needs to be told about rather
        // than left to discover. Asserted here because this is the check an operator runs after the
        // queued calls execute.
        //
        // **Round 21 moved the pause out of `_phase4Calls` and this assertion got MORE work, not
        // less.** The pause now happens in a separate, earlier operation, so "paused and never
        // unpaused" is no longer only a half-run batch - it is also an operator who ran
        // `queuePause()` and then abandoned the switchover. That state has no other detector, and
        // this is the line that names it.
        if (d.credit.paused()) revert SwitchoverLeftPaused("credit");
        if (d.vault.paused()) revert SwitchoverLeftPaused("vault");
    }

    function _requireOwner(address contractAddr, address actual, address expected) private pure {
        if (actual != expected) revert OwnershipNotTransferred(contractAddr, actual);
    }

    /// @notice Every `Ownable` in `Deployed`, enumerated from the struct itself.
    /// @dev **The anti-drift device, and it is the point of round 20's ownership finding.** Five
    ///      places in this repo needed "every contract the deploy script creates": `_handOver`,
    ///      `_assertCoreGraph`, `_log`, and three tests in `Deploy.t.sol`. Every one of them was a
    ///      list typed out by hand, and twice now a contract has been added to some of them and
    ///      not to others - `d.liquidity` in round 10, `d.riskParams` in round 20. Both times CI
    ///      certified the gap, because the tests were built from the same hand-typed list as the
    ///      thing they were checking.
    ///
    ///      `Deployed` holds contract references and nothing else, so its ABI encoding is exactly
    ///      one 32 byte word per member, and enumerating the encoding enumerates the struct. There
    ///      is no list to fall behind: a tenth contract added to `Deployed` is checked, logged and
    ///      asserted about by existing, and if it cannot be enumerated this reverts rather than
    ///      quietly covering one fewer contract than the struct holds.
    ///
    ///      **`_handOver` is deliberately still written out, and that is now safe rather than an
    ///      omission.** It performs state changes inside the broadcast, so it reads better as an
    ///      explicit sequence of transactions an operator can match against a block explorer. What
    ///      made it dangerous before was that the post-condition checking it was a second copy of
    ///      the same list, so the two could fall behind together - and they did, twice. The
    ///      post-condition is derived now, so a `_handOver` that misses a member fails
    ///      `OwnershipNotTransferred` in simulation, loudly, before anything is broadcast. The
    ///      check no longer agrees with the thing it checks by construction.
    ///
    ///      Read a word at a time without assembly. There is no assembly anywhere in this repo and
    ///      a deploy post-condition is the last place to introduce it; `Deployed` has single-digit
    ///      membership and this runs in a script simulation and in tests, never on a hot path.
    function _ownablesOf(Deployed memory d) internal view returns (address[] memory list) {
        bytes memory encoded = abi.encode(d);
        uint256 members = encoded.length / 32;
        list = new address[](members);

        for (uint256 i; i < members; ++i) {
            uint256 word;
            for (uint256 b; b < 32; ++b) {
                word = (word << 8) | uint8(encoded[i * 32 + b]);
            }
            address member = address(uint160(word));
            // A word that is not a plain address, or an address with no code, means the struct has
            // grown a member this cannot read - a dynamic field encodes as an offset, and an
            // offset is a small integer with nothing deployed at it.
            if (word >> 160 != 0 || member.code.length == 0) revert DeployedMemberNotOwnable(i);
            (bool ok, bytes memory ret) = member.staticcall(abi.encodeCall(Ownable.owner, ()));
            if (!ok || ret.length != 32) revert DeployedMemberNotOwnable(i);
            list[i] = member;
        }
    }

    /// @dev Labels for `_ownablesOf`'s output, in `Deployed` declaration order. Presentation only -
    ///      `_log` checks the length against the enumeration, so a member added without a label
    ///      fails loudly rather than going unprinted.
    function _deployedLabels() private pure returns (string[] memory labels) {
        labels = new string[](9);
        labels[0] = "NAVOracle         ";
        labels[1] = "RiskParams        ";
        labels[2] = "CollateralVault   ";
        labels[3] = "DirectCallAdapter ";
        labels[4] = "CreditManager     ";
        labels[5] = "LenderPool        ";
        labels[6] = "LiquiditySource   ";
        labels[7] = "EpochHarvester    ";
        labels[8] = "LiquidationAuction";
    }

    // ── Logging ──────────────────────────────────────────────────────────────

    function _log(Deployed memory d, GovParams memory p) internal view {
        console.log("owner             ", p.owner);
        console.log("yieldRecipient    ", p.yieldRecipient);
        console.log("keeper            ", p.keeper);
        console.log("protocolFeeWallet ", p.protocolFeeWallet);
        // **Two of six operator addresses were missing from this list, and one of them is the
        // guardian.** The comment on the contract enumeration below states the rule this broke -
        // "an address nobody prints is an address nobody verifies after a deploy" - and states it
        // about the CONTRACT list, which was derived from the struct to fix exactly this shape,
        // while the operator list above it went on printing four of six. Written as a pointer
        // rather than as "the comment N lines down": that count was wrong by five the day it was
        // typed, in a file whose own findings are mostly stale counts. `navConfirmer` is the second
        // key on the price feed and `guardian` is the whole of the fast incident response.
        console.log("navConfirmer      ", p.navConfirmer);
        if (p.guardian == address(0)) {
            // Zero is legal and is the shipped default under an EOA owner, so this is not a
            // refusal - `_validateNewDeployment` owns the one case that is refusable, which is a
            // contract owner at the moment a deployment is made. It is loud because it is the one parameter whose correct value flips silently:
            // right today, and "this protocol has no fast pause" the moment ownership moves to a
            // timelock, with nothing in between announcing the change. An operator reading a deploy
            // log has to be able to see which of those two deployments they just made.
            console.log("guardian           UNSET - no fast pause. Correct only while the owner is an EOA.");
        } else {
            console.log("guardian          ", p.guardian);
        }

        // Printed from the same enumeration `_assertCoreGraph` checks, rather than from a second
        // hand-typed list. `RiskParams` was absent from the old list, so the operator was never
        // shown the address of the contract holding the borrow ceiling and the liquidation trigger
        // - and an address nobody prints is an address nobody verifies after a deploy.
        address[] memory ownables = _ownablesOf(d);
        string[] memory labels = _deployedLabels();
        if (labels.length != ownables.length) revert DeployedLabelsOutOfSync(labels.length, ownables.length);
        for (uint256 i; i < ownables.length; ++i) {
            console.log(labels[i], ownables[i]);
        }
        console.log("MintReceiver impl  ", address(d.adapter.mintReceiverImplementation()));
        console.log("Post-deploy: fund the liquidity source and bootstrap the NAV oracle.");
        // Printed because the deployment is deliberately incomplete: the LenderPool above is
        // deployed and knows who its manager is, and is wired into nothing that pays it or
        // charges it. That is the safe shipping state, and it takes an explicit later operation
        // (`_wirePhase4`) to leave it.
        console.log("The LenderPool ships dormant. Phase 4 wires funding and losses together.");
    }
}
