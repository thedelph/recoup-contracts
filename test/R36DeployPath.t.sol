// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R36DeployPath - audit round 36, stream D. The deploy path and the wiring it establishes.
/// @notice Executable demonstrations for the round-36 deploy-path sweep. Every claim in the report
///         is one of these, run rather than read.
/// @dev Chain id is pinned to **84532** in `setUp`, not to 31337. `DeployBase._isLocal()` keys on
///      31337 and `_validateParams` early-returns on it, so a deploy test written on the anvil id
///      exercises the permissive half of every rule. The redeploy this round is about is Base
///      Sepolia, so these run on Base Sepolia's id.
contract R36DeployPathTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;

    /// @dev A library substitute whose fallback returns one zero word. The ABI decoder is satisfied
    ///      and `CreditManager._requireWiringRan` is what refuses it. Same constant as
    ///      `CreditWiringLinkage.t.sol`, redeclared because that fixture is not reusable from here.
    bytes internal constant RETURNS_A_ZERO_WORD = hex"60206000f3";

    address internal owner = makeAddr("r36.owner");
    address internal deployer = address(this);
    address internal treasury = makeAddr("r36.treasury");
    address internal keeper = makeAddr("r36.keeper");
    address internal navConfirmer = makeAddr("r36.navConfirmer");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(BASE_SEPOLIA);
    }

    function _externals() internal view returns (Externals memory) {
        return Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });
    }

    /// @dev The shipped shape: a real EOA owner, a distinct treasury, two distinct NAV keys, and
    ///      the guardian unfilled - which is what `contracts/deployments/base-sepolia.json` records
    ///      the 2026-08-19 run as having used.
    function _params() internal view returns (GovParams memory) {
        return GovParams({
            owner: owner,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: treasury,
            guardian: address(0)
        });
    }

    /// @dev `expectRevert` only reaches one call depth below the cheatcode, and the functions under
    ///      test are internal.
    function exposedValidateParams(GovParams memory p, address who) external view {
        _validateParams(p, who);
    }

    function exposedDeployProtocol(Externals memory e, GovParams memory p, address who)
        external
        returns (Deployed memory)
    {
        return _deployProtocol(e, p, who);
    }

    function exposedAssertPhase4Wiring(Deployed memory d, GovParams memory p) external view {
        _assertPhase4Wiring(d, p);
    }

    /// @dev The deploy path's rule set: `_validateParams` plus the one rule that is about MAKING a
    ///      deployment. For inputs that break only that rule it is byte-for-byte what
    ///      `_validateParams` used to do, which is what lets the deadlock still be executed rather
    ///      than described.
    function exposedValidateNewDeployment(GovParams memory p, address who) external view {
        _validateNewDeployment(p, who);
    }

    /// @dev G2 as it actually happens: nine ordinary owner transactions, no script around them.
    ///      `_handOver` is the deploy script's own list, so a tenth contract cannot be missed here.
    function _handOverTo(Deployed memory d, address newOwner) internal {
        vm.startPrank(owner);
        _handOver(d, newOwner);
        vm.stopPrank();
    }

    /// @dev The exact shape the switchover finding is about: deployed in the documented default -
    ///      EOA owner, `RECOUP_GUARDIAN` unset - and then handed to a timelock.
    function _shippedThenHandedToATimelock()
        internal
        returns (Deployed memory d, TimelockController timelock)
    {
        d = _deployProtocol(_externals(), _params(), deployer);
        assertEq(d.vault.guardian(), address(0), "premise: shipped with the role unfilled");

        address[] memory none = new address[](0);
        timelock = new TimelockController(48 hours, none, none, address(this));
        _handOverTo(d, address(timelock));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Standing claim 1 - "the `CreditWiring` link is verified by nothing".
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **The compensating control round 24 said did not exist now exists AND is exercised
    ///         by the deploy script itself.** `_wire` calls `credit.setLiquiditySource` and
    ///         `credit.setLiquidationAuction`, and both reach an attested `CreditWiring` member
    ///         unconditionally - so a wrong-but-coded library at the linker's placeholder takes the
    ///         whole deployment down in simulation, before a single transaction is broadcast.
    /// @dev The substitute returns a well-formed zero word, which is precisely the shape an
    ///      `EXTCODESIZE` guard and a returndata-length check both wave through. The revert is
    ///      `WiringLibraryUnverified(0)` bubbling out of `_wire`.
    function test_R36_aWrongButCodedWiringLibraryTakesTheWholeDeployDownInSimulation() public {
        Deployed memory clean = _deployProtocol(_externals(), _params(), deployer);
        address wiring = _linkedWiring(address(clean.credit));
        assertGt(wiring.code.length, 1_000, "premise: the linked library is real code");

        vm.etch(wiring, RETURNS_A_ZERO_WORD);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.WiringLibraryUnverified.selector, bytes32(0)));
        this.exposedDeployProtocol(_externals(), _params(), deployer);
    }

    /// @notice And the control: on the real library the same deployment completes and every
    ///         post-condition passes. Without this arm the test above proves only that something
    ///         reverted.
    function test_R36_control_theRealWiringLibraryLetsTheDeployComplete() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), deployer);
        _assertWiring(d, _params());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Standing claim 2 - "a guardian-less deploy is indistinguishable from a correct one".
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **The tree DOES carry the check, for the case where zero is actually harmful, and it
    ///         is on the path that MAKES a deployment.** A contract owner with no guardian is
    ///         refused by `_deployProtocol` on a real chain, named, with the owner's address in the
    ///         revert - and refused before the first contract is created, so a broadcast that would
    ///         have shipped a protocol with no fast pause dies in simulation.
    /// @dev **Through `exposedDeployProtocol` rather than a validator wrapper, on purpose.** The
    ///      rule moved out of `_validateParams` because sitting there made it a precondition of the
    ///      Phase-4 switchover as well, which is a deadlock rather than a guard. A rule moved into
    ///      a helper nobody calls is the failure that move could have caused, so what is asserted
    ///      here is the deploy sequence refusing, not the helper.
    function test_R36_claim2_aContractOwnerWithNoGuardianIsRefusedOnTheDeployPath() public {
        address[] memory none = new address[](0);
        TimelockController timelock = new TimelockController(48 hours, none, none, address(this));

        GovParams memory p = _params();
        p.owner = address(timelock);
        assertEq(p.guardian, address(0), "premise: unfilled");
        assertGt(address(timelock).code.length, 0, "premise: the owner is a contract");

        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.GuardianRequiredForContractOwner.selector, address(timelock))
        );
        this.exposedDeployProtocol(_externals(), p, deployer);

        // The control, and it is what makes this a rule about the guardian rather than about
        // contract owners: name one and the same deployment completes and asserts clean.
        p.guardian = makeAddr("r36.claim2.guardian");
        Deployed memory d = _deployProtocol(_externals(), p, deployer);
        _assertWiring(d, p);
    }

    /// @notice **And the residual half is still true, deliberately: under an EOA owner a
    ///         guardian-less deploy completes and passes every post-condition.** Recorded as a
    ///         measurement rather than as a finding - `_log` prints an explicit UNSET warning and
    ///         the source argues the case - but it is what an operator gets with `RECOUP_GUARDIAN`
    ///         unset today, on the chain this redeploy targets.
    function test_R36_claim2_anEoaOwnerWithNoGuardianStillCompletesAndAssertsClean() public {
        GovParams memory p = _params();
        assertEq(p.guardian, address(0), "premise: unfilled");
        assertEq(owner.code.length, 0, "premise: the owner is an EOA");

        Deployed memory d = _deployProtocol(_externals(), p, deployer);
        _assertWiring(d, p);

        assertEq(d.vault.guardian(), address(0), "the vault has no fast pause");
        assertEq(d.credit.guardian(), address(0), "nor the manager");
        assertEq(d.pool.guardian(), address(0), "nor the pool");
    }

    /// @notice **A 7702-delegated EOA has 23 bytes of code, so the contract-owner rule refuses it -
    ///         and this test exists so that RELAXING the rule goes red.**
    ///
    /// @dev EIP-7702 is live on Base. An EOA that has signed a delegation carries exactly 23 bytes
    ///      of code, `0xef0100 || address`, and `_validateNewDeployment` asks
    ///      `p.owner.code.length > 0`. So an owner that is a smart account - a very ordinary way to
    ///      own a protocol in 2026 - is refused unless a guardian is named, and it is refused as
    ///      `GuardianRequiredForContractOwner` rather than as anything about delegation.
    ///
    ///      **Audit round 38 REFUSED the prescription to relax that predicate to `> 23`** on a sign
    ///      check: it is strictly more permissive, and what it would permit is precisely the owner
    ///      whose code is a delegation to arbitrary logic that can be re-signed at any time. The
    ///      refusal was recorded and nothing held it. `> 0` and `> 23` agree on every input the
    ///      suite had - an EOA at 0 bytes and a `TimelockController` at thousands - so the relaxed
    ///      predicate passed every existing test, and the next session to reach for the same idea
    ///      would have crossed the boundary with nothing going red. **This test is that boundary,
    ///      and it is its whole job.** 23 is the only length at which the two predicates disagree.
    ///
    ///      **`vm.etch` with a real designator, MEASURED rather than assumed.** EIP-3541 rejects
    ///      `0xEF`-prefixed code from CREATE and CREATE2, and it was an open question whether the
    ///      cheatcode inherits that. It does not: measured on forge 1.8.1, `vm.etch` installs the
    ///      23 bytes verbatim and `code.length` reads 23. `vm.signAndAttachDelegation` was measured
    ///      on the same executor and produces an identical 23 bytes from a real signed
    ///      authorisation; `vm.etch` is used here because it lets the fixture name the owner
    ///      address rather than inherit one from a key, and because the predicate under test never
    ///      follows the delegation - it reads a length. The designator points at a contract that
    ///      really exists in this fixture so that nothing can be attributed to a dangling target.
    ///
    ///      Both halves of the assertion matter. The premise pins the EIP-7702 encoding itself, so
    ///      a reader does not have to take 23 on trust; the control names a guardian and shows the
    ///      same owner is then accepted, which keeps this a statement about the guardian rule
    ///      rather than about delegated accounts.
    function test_R38_aDelegatedEoaOwnerIsRefusedAndTwentyThreeBytesIsTheBoundary() public {
        address delegated = makeAddr("r38.delegated.owner");
        bytes memory designator = abi.encodePacked(hex"ef0100", address(usdc));

        assertEq(designator.length, 23, "premise: an EIP-7702 designator is 0xef0100 plus 20 bytes");
        vm.etch(delegated, designator);
        assertEq(delegated.code.length, 23, "premise: the delegated EOA carries exactly 23 bytes");
        assertEq(delegated.code, designator, "premise: those bytes are the designator, not a stub");

        GovParams memory p = _params();
        p.owner = delegated;
        assertEq(p.guardian, address(0), "premise: unfilled");

        // `> 0` refuses this. `> 23` does not, and that is the refused prescription: 23 is the one
        // length at which the two predicates disagree, so this line is the only thing in the tree
        // that can tell them apart.
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.GuardianRequiredForContractOwner.selector, delegated)
        );
        this.exposedValidateNewDeployment(p, deployer);

        // The control: name a guardian and the same 23-byte owner is accepted, which is what makes
        // this a rule about the guardian rather than about who may own the protocol.
        p.guardian = makeAddr("r38.delegated.guardian");
        this.exposedValidateNewDeployment(p, deployer);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FINDING - the guardian may be the deploying key, and nothing says so.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **REFUTED, and the refutation is the point.** `guardian == deployer` looked like the
    ///         same hole as `yieldRecipient == deployer`, which `_validateParams` refuses by name.
    ///         It is not: it is caught, but by nothing in this script. `_wire` calls
    ///         `setGuardian` while the DEPLOYER still owns the contracts, so the vault's own
    ///         `guardian_ == owner()` rule fires on the transient owner and takes the deploy down.
    ///
    ///         What survives is a legibility defect, not a security one. `_validateParams` says in
    ///         writing that it hoists the guardian/owner rule above the local early-return so a
    ///         breach cannot "revert mid-wiring with no indication which of two roles was wrong" -
    ///         and this case does exactly that: the operator is told
    ///         `GuardianMustDifferFromOwner()` from inside `_wire`, about an owner
    ///         (`p.owner`) that the value does not in fact collide with.
    /// @dev The assertion is deliberately on the SELECTOR and on where it comes from, so a future
    ///      edit that adds a named deployer rule to `_validateParams` fails here and is read.
    function test_R36_refuted_theGuardianCannotBeTheDeployingKeyButTheErrorNamesTheWrongRole()
        public
    {
        GovParams memory yr = _params();
        yr.yieldRecipient = deployer;
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.YieldRecipientCollision.selector, deployer, "deployer")
        );
        this.exposedValidateParams(yr, deployer);

        GovParams memory g = _params();
        g.guardian = deployer;
        assertTrue(g.guardian != g.owner, "premise: the guardian does NOT collide with the named owner");

        // `_validateParams` accepts it - there is no deployer rule for the guardian.
        this.exposedValidateParams(g, deployer);

        // And it dies anyway, inside `_wire`, under a name about a collision that is not the one
        // the operator made.
        vm.expectRevert(abi.encodeWithSelector(DeployBase.GuardianMustDifferFromOwner.selector));
        this.exposedDeployProtocol(_externals(), g, deployer);
    }

    /// @notice The same hole one field over: the guardian may be the keeper, or the NAV confirmer -
    ///         the two keys PRD section 9's two-key guard is built out of.
    /// @dev `_validateParams` has exactly one distinctness rule among the operator keys
    ///      (`navConfirmer != keeper`) and one collision family for the treasury. The guardian is in
    ///      neither.
    function test_R36_theGuardianMayAlsoBeTheKeeperOrTheNavConfirmer() public {
        GovParams memory a = _params();
        a.guardian = keeper;
        this.exposedValidateParams(a, deployer);
        Deployed memory da = _deployProtocol(_externals(), a, deployer);
        _assertWiring(da, a);
        assertEq(da.credit.guardian(), da.oracle.keeper(), "one key is the keeper and the fast pause");

        GovParams memory b = _params();
        b.guardian = navConfirmer;
        this.exposedValidateParams(b, deployer);
        Deployed memory db = _deployProtocol(_externals(), b, deployer);
        _assertWiring(db, b);
        assertEq(db.credit.guardian(), db.oracle.navConfirmer(), "and one is the confirmer and the fast pause");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FINDING - no chain-reading post-condition exists for the shipping state.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **`WirePhase4.assertOnly()` is the repository's only tool that reads the deployed
    ///         graph off a real chain and asserts it, and it cannot be run against the state this
    ///         redeploy will leave.** It calls `_assertPhase4Wiring`, whose first switchover clause
    ///         requires `credit.liquiditySource == lenderPool`. A shipping deployment points it at
    ///         the treasury float on purpose, so the tool reverts on a perfectly healthy protocol.
    /// @dev The consequence is in the report: `_assertWiring` runs inside the script's own
    ///      simulation, and there is nothing an operator can run afterwards to ask the CHAIN
    ///      whether the graph it actually got is the graph the simulation certified.
    function test_R36_theOnlyChainReadingAssertionRefusesTheShippingState() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), deployer);
        // Healthy by the post-condition the deploy script itself runs.
        _assertWiring(d, _params());

        // And refused by the only post-condition that has a chain-reading entry point.
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "credit.liquiditySource")
        );
        this.exposedAssertPhase4Wiring(d, _params());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CLOSED - the Phase-4 switchover on the deployment the tree ships.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **The deadlock, executed on the shape that had it, with the real rule.** A deployment
    ///         shipped in the documented default state - EOA owner, `RECOUP_GUARDIAN` unset - and
    ///         then handed to a timelock at G2 could not run `WirePhase4.queue()`,
    ///         `executeQueued()` or `run()`, because all three resolve their `GovParams` through
    ///         `_resolveParams` and the contract-owner guardian rule was inside it:
    ///
    ///         - `RECOUP_GUARDIAN` unset: the rule reverts `GuardianRequiredForContractOwner`.
    ///         - `RECOUP_GUARDIAN` set to anything: `_assertCoreGraph` reverts
    ///           `WiringIncomplete("vault.guardian")`, because the chain holds zero and no
    ///           environment value can install a guardian onto a deployed contract.
    ///
    ///         Two constraints on one variable, with no common solution.
    /// @dev **The first arm runs against `_validateNewDeployment`, which IS the old
    ///      `_validateParams` for these inputs.** That function is `_validateParams` plus the moved
    ///      rule, so the only difference from the old shape is which error surfaces when two rules
    ///      are broken at once - and here exactly one is. So this is the historical deadlock run,
    ///      not a description of it, and it will keep being run: an edit that puts the rule back on
    ///      the switchover's path makes the companion test below red while leaving this one green,
    ///      which is the pair a reader needs.
    ///
    ///      The amplifier is why this was a HIGH rather than an inconvenience: `queuePause()` skips
    ///      `_resolveParams` entirely, so an operator shuts `borrow` and `depositETH` first and
    ///      meets the wall afterwards - and the only scripted `unpause` is legs 5 and 6 of the
    ///      batch that cannot then be queued.
    function test_R36_theOldPlacementDeadlockedBothArmsOfTheSwitchover() public {
        (Deployed memory d, TimelockController timelock) = _shippedThenHandedToATimelock();

        GovParams memory now_ = _params();
        now_.owner = address(timelock);

        // Arm 1 - RECOUP_GUARDIAN unset, against the deploy-time rule set.
        assertEq(now_.guardian, address(0), "arm 1 premise");
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.GuardianRequiredForContractOwner.selector, address(timelock))
        );
        this.exposedValidateNewDeployment(now_, deployer);

        // Arm 2 - RECOUP_GUARDIAN set to anything at all. The graph assertion refuses, and this arm
        // is UNCHANGED by the fix: it is the constraint that is correct and stays.
        now_.guardian = makeAddr("r36.anyGuardian");
        this.exposedValidateNewDeployment(now_, deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "vault.guardian"));
        this.exposedAssertCoreGraph(d, now_);
    }

    /// @notice **And the switchover the deadlock made unreachable, reached.** With the rule moved to
    ///         the deploy path, the same G2 deployment resolves its parameters with
    ///         `RECOUP_GUARDIAN` unset, passes `_assertCoreGraph`, wires Phase 4 and satisfies
    ///         `_assertPhase4Wiring`. That is the whole of `run()` minus the broadcast.
    /// @dev **What the switchover did NOT lose, asserted rather than argued.** It still goes through
    ///      `_resolveParams`, so every other rule still applies to it - three of them are executed
    ///      below against the same parameters, chosen because each was a separate finding in an
    ///      earlier round. Dropping these three is what the alternative fix, moving the switchover
    ///      to `_readParams`, would have cost.
    ///
    ///      `_wirePhase4` is driven as the owner rather than through the timelock: the timelock's
    ///      maturity is exercised elsewhere and what is under test here is the parameter gate, not
    ///      `scheduleBatch`. Ownership therefore goes to this contract, which is a contract owner
    ///      with no guardian - exactly the shape the old rule refused.
    function test_R36_theSwitchoverNowCompletesWithTheGuardianUnset() public {
        GovParams memory p = _params();
        Deployed memory d = _deployProtocol(_externals(), p, deployer);
        assertEq(d.vault.guardian(), address(0), "premise: shipped with the role unfilled");
        _handOverTo(d, deployer);
        assertGt(deployer.code.length, 0, "premise: the new owner is a contract");

        GovParams memory now_ = _params();
        now_.owner = deployer;
        assertEq(now_.guardian, address(0), "premise: RECOUP_GUARDIAN still unset, as shipped");

        // The gate that used to refuse.
        this.exposedValidateParams(now_, deployer);
        this.exposedAssertCoreGraph(d, now_);

        // The switchover itself, then its post-condition.
        _wirePhase4(d);
        _assertPhase4Wiring(d, now_);
        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool funds the book");
        assertEq(d.harvester.lenderPool(), address(d.pool), "and is paid for carrying it");
        assertFalse(d.credit.paused(), "and the pause bracket was reopened");

        // The rules the switchover keeps. Each was its own finding once, and dropping the three of
        // them is what the alternative fix would have cost. Built from `_params()` every time
        // rather than from a copy: `GovParams memory a = b` aliases one struct in memory, so a
        // "copy" mutated here would have quietly rewritten the parameters asserted above.
        GovParams memory bad = _params();
        bad.owner = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployBase.OwnerRequired.selector));
        this.exposedValidateParams(bad, deployer);

        bad = _params();
        bad.navConfirmer = bad.keeper;
        vm.expectRevert(abi.encodeWithSelector(DeployBase.NavKeysMustDiffer.selector));
        this.exposedValidateParams(bad, deployer);

        bad = _params();
        bad.yieldRecipient = bad.owner;
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.YieldRecipientCollision.selector, bad.owner, "owner")
        );
        this.exposedValidateParams(bad, deployer);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CLOSED - RECOUP_OWNER no longer defaults to the broadcasting key.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **All six operator addresses now fail loudly when unset off a local chain, and the
    ///         sixth is the one that did not.** `RECOUP_OWNER` used to resolve to the broadcasting
    ///         key on every chain, which made `OwnerRequired()` unreachable on every script path -
    ///         `deployer` is never zero. `_handOver` was then skipped by `if (p.owner != deployer)`
    ///         and all nine `_requireOwner` post-conditions compared the chain against that same
    ///         defaulted value, so a protocol the deploy key owned outright - including
    ///         `TreasuryLiquiditySource`, whose `withdraw(to, amount)` is `onlyOwner` and uncapped,
    ///         and `RiskParams` - certified itself healthy.
    /// @dev `_readParams` is exercised through an override that returns every fallback, which is
    ///      exactly what an empty environment does.
    /// @dev **The broadcasting key is an EOA on a real run, and that is load-bearing here rather
    ///      than cosmetic.** `address(this)` is a contract, so using it as the deployer would let
    ///      the contract-owner guardian rule fire and hide the rule under test - a test-harness
    ///      artefact that would report the wrong revert. It also sharpens what the defect was: on a
    ///      real broadcast the defaulted owner is an EOA, so `GuardianRequiredForContractOwner` was
    ///      unreachable too. Both rules disappeared together, and both come back together.
    /// @dev **Both chain ids, in one test, because the fix is a placement rather than a value.**
    ///      Moving the fallback inside `if (_isLocal())` is only correct if the local branch still
    ///      needs no setup, so the local half is asserted rather than assumed.
    function test_R36_recoupOwnerNoLongerDefaultsToTheBroadcastingKey() public {
        address eoaDeployer = makeAddr("r36.broadcastingKey");
        assertEq(eoaDeployer.code.length, 0, "premise: a real broadcasting key is an EOA");
        _emptyEnvironment = true;

        GovParams memory p = _readParams(eoaDeployer);
        assertEq(p.owner, address(0), "RECOUP_OWNER unset resolves to zero, like the other five");
        assertEq(p.yieldRecipient, address(0), "yieldRecipient");
        assertEq(p.keeper, address(0), "keeper");
        assertEq(p.navConfirmer, address(0), "navConfirmer");
        assertEq(p.protocolFeeWallet, address(0), "protocolFeeWallet");
        assertEq(p.guardian, address(0), "guardian");

        // `OwnerRequired()` is the first rule in `_validateParams`, so it is now what an empty
        // environment meets - rather than the fourth rule, over a silently captured deployment.
        vm.expectRevert(abi.encodeWithSelector(DeployBase.OwnerRequired.selector));
        this.exposedValidateParams(p, eoaDeployer);

        // Filling the other four does not rescue it. This is the arm that used to pass.
        p.yieldRecipient = treasury;
        p.keeper = keeper;
        p.navConfirmer = navConfirmer;
        p.protocolFeeWallet = treasury;
        vm.expectRevert(abi.encodeWithSelector(DeployBase.OwnerRequired.selector));
        this.exposedValidateParams(p, eoaDeployer);

        // And the deploy path refuses it as well, before the first contract is created.
        vm.expectRevert(abi.encodeWithSelector(DeployBase.OwnerRequired.selector));
        this.exposedDeployProtocol(_externals(), p, eoaDeployer);

        // The local half: a run on the anvil chain id still needs zero setup, and there the
        // deploying key owning everything is the intent rather than a capture.
        vm.chainId(31337);
        GovParams memory local = _readParams(eoaDeployer);
        assertEq(local.owner, eoaDeployer, "locally the fallback is kept, and it is the only place it lives");
        this.exposedValidateParams(local, eoaDeployer);
        vm.chainId(BASE_SEPOLIA);

        // The residual, stated as a measurement rather than left implied: an operator may still
        // NAME the broadcasting key as the owner, and then `_handOver` is skipped and every
        // ownership assertion passes over a protocol that key owns. That is now a choice somebody
        // typed into the environment, which is the whole of what this fix changes.
        _emptyEnvironment = false;
        GovParams memory q = _params();
        q.owner = deployer;
        q.guardian = makeAddr("r36.g");
        Deployed memory d = _deployProtocol(_externals(), q, deployer);
        _assertWiring(d, q);
        assertEq(d.liquidity.owner(), deployer, "the lending float is owned by the deploying key");
        assertEq(d.riskParams.owner(), deployer, "and so are the risk parameters");
        assertEq(d.credit.owner(), deployer, "and the manager");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FINDING D4, CLOSED IN ROUND 40 - transferOwnership was the unguarded writer
    // of the guardian/owner pair.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **`setGuardian` refuses `guardian_ == owner()`, and `transferOwnership` writes the
    ///         other half of that same pair.** Until round 40 it refused nothing, so an ordinary
    ///         handover to the guardian's address collapsed the two-key model with no revert and
    ///         no event saying so, and the single key then satisfied both `_requireOwnerOrGuardian`
    ///         and `onlyOwner` - the exact state `unpause`'s `onlyOwner` exists to prevent.
    ///
    /// @dev 🟥 **THIS TEST USED TO ASSERT THE DEFECT AND PASSED FOR THREE ROUNDS.** It performed
    ///      the transfer, asserted `owner() == guardian()`, and then asserted the single key could
    ///      both `pause()` and `unpause()`. It is inverted here rather than deleted, because the
    ///      collapse is a property that must be able to go red again: what it asserts now is that
    ///      all three pausable contracts refuse the transfer, and that the pair is still two keys
    ///      afterwards.
    ///
    ///      The control is `NAVOracle`, which has always guarded its own two-key pair from BOTH
    ///      writers: `setKeeper` refuses the confirmer and `setNavConfirmer` refuses the keeper.
    ///      Asserted here so the closure is a comparison rather than an opinion.
    function test_R36_transferOwnershipRefusesTheGuardianOnAllThreePausableContracts() public {
        address g = makeAddr("r36.guardian");
        GovParams memory p = _params();
        p.guardian = g;
        Deployed memory d = _deployProtocol(_externals(), p, deployer);
        _assertWiring(d, p);

        // The rule, from the writer that always had it.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.GuardianMustDifferFromOwner.selector));
        d.vault.setGuardian(owner);

        // The same rule, from the writer that did not have it. All three contracts, because all
        // three carried the same `setGuardian` clause and the same omission beside it.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.GuardianMustDifferFromOwner.selector));
        d.vault.transferOwnership(g);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.GuardianMustDifferFromOwner.selector));
        d.credit.transferOwnership(g);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.GuardianMustDifferFromOwner.selector));
        d.pool.transferOwnership(g);

        assertEq(d.vault.owner(), owner, "ownership did not move");
        assertEq(d.vault.guardian(), g, "and the guardian is still a different key");
        assertTrue(d.vault.owner() != d.vault.guardian(), "the two-key model is still two keys");
        assertTrue(d.credit.owner() != d.credit.guardian(), "on the manager too");
        assertTrue(d.pool.owner() != d.pool.guardian(), "and on the pool");

        // And the guardian cannot reopen what it shut, which is the property that was traded away.
        vm.prank(g);
        d.vault.pause();
        vm.prank(g);
        vm.expectRevert();
        d.vault.unpause();
        vm.prank(owner);
        d.vault.unpause();

        // The control: NAVOracle guards its two-key pair from both writers.
        vm.prank(owner);
        vm.expectRevert();
        d.oracle.setKeeper(navConfirmer);
        vm.prank(owner);
        vm.expectRevert();
        d.oracle.setNavConfirmer(keeper);
    }

    /// @notice The sanctioned handover to an address that is currently the guardian is two calls,
    ///         not one, and the round-40 clause does not block it - it sequences it.
    /// @dev The point of the control. A rule that closed the G2 handover altogether would be a
    ///      worse defect than the one it closed, so this asserts the whole legitimate sequence:
    ///      move the guardian off the incoming owner, transfer, then re-install a distinct
    ///      guardian and check it still works from both sides.
    function test_R36_theHandoverStillWorksWhenTheGuardianIsMovedFirst() public {
        address g = makeAddr("r36.guardian");
        address incoming = makeAddr("r36.incomingOwner");
        address g2 = makeAddr("r36.guardian2");
        GovParams memory p = _params();
        p.guardian = g;
        Deployed memory d = _deployProtocol(_externals(), p, deployer);

        // An ordinary handover to a third party was never in question and still is not.
        vm.prank(owner);
        d.vault.transferOwnership(incoming);
        assertEq(d.vault.owner(), incoming, "a handover to a non-guardian is untouched");

        // Now the case the clause governs: hand the manager to the address that is the guardian.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.GuardianMustDifferFromOwner.selector));
        d.credit.transferOwnership(g);

        vm.prank(owner);
        d.credit.setGuardian(g2);
        vm.prank(owner);
        d.credit.transferOwnership(g);
        assertEq(d.credit.owner(), g, "the handover lands once the guardian has moved off it");
        assertEq(d.credit.guardian(), g2, "and the second key is still a second key");

        // Both halves of the pair still behave, from the new owner and the new guardian.
        vm.prank(g2);
        d.credit.pause();
        vm.prank(g2);
        vm.expectRevert();
        d.credit.unpause();
        vm.prank(g);
        d.credit.unpause();
        assertFalse(d.credit.paused(), "the owner reopened it and the guardian could not");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FINDING - "the LenderPool ships dormant" is printed, not established.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice **Round 36 finding D7, CLOSED in round 40: the pool now ships shut.**
    ///
    /// @dev 🟥 **This test asserted the finding and passed for four rounds.** It read: "`_log`
    ///      prints 'The LenderPool ships dormant' and nothing in `_wire` or `_assertWiring`
    ///      establishes it", and it proved the point by having a stranger deposit into the
    ///      freshly deployed pool, take 100% of supply, and watch `_assertWiring` pass over the
    ///      top of it. What it never did was follow the money, which is why it sat as a finding
    ///      rather than a fix for four rounds. Round 40 followed it: `test/R40D7Capture.t.sol`
    ///      executes the chain end to end and the stranger's profit is the whole parked lender
    ///      backlog, 999.999999 on 1,200.000000 posted.
    ///
    ///      Inverted rather than deleted. The original observation is still the load-bearing one -
    ///      `_assertWiring` still positively REQUIRES `harvester.lenderPool() == 0`, the state in
    ///      which `EpochHarvester` accrues a lender share for a pool bearing no risk - so what
    ///      changed is only that the door into that state is now shut and asserted shut.
    ///
    ///      MEASURED on the live Base Sepolia set 2026-08-29 by `cast call`, and this is the
    ///      deployment the fix does NOT reach because it predates it:
    ///      `EpochHarvester.pendingLenderYield()` = 124885415, `EpochHarvester.lenderPool()` = 0,
    ///      `LenderPool.totalSupply()` = 0. The backlog is real and the pool on chain is open.
    function test_R36_theLenderPoolNowShipsShutToDepositors() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), deployer);
        _assertWiring(d, _params());

        assertTrue(d.pool.paused(), "the pool the log calls dormant is now actually shut");
        assertEq(d.harvester.lenderPool(), address(0), "and the assertion set still REQUIRES it bears no risk");
        assertEq(d.pool.maxDeposit(makeAddr("r36.stranger")), 0, "so no stranger may deposit into it");

        address stranger = makeAddr("r36.stranger");
        usdc.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(d.pool), 1_000e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.pool.deposit(1_000e6, stranger);
        vm.stopPrank();

        assertEq(d.pool.totalSupply(), 0, "nobody holds a share of a pool wired into nothing");

        // And the deployment asserts clean, now including the pool's own switch.
        _assertWiring(d, _params());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fixture
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Backs the `_envOrAddress` seam with storage instead of the process environment, so this
    ///      suite reads no `.env` and sets none. `vm.setEnv` writes one table shared by the whole
    ///      `forge test` process, which is the race round 30 removed; see `EnvOverridable` in
    ///      `Deploy.t.sol`. When true, every read returns its fallback - which is what an empty
    ///      environment does, and is the state the owner-default finding is about.
    bool internal _emptyEnvironment;

    function _envOrAddress(string memory key, address fallbackValue)
        internal
        view
        virtual
        override
        returns (address)
    {
        if (_emptyEnvironment) return fallbackValue;
        return super._envOrAddress(key, fallbackValue);
    }

    function exposedAssertCoreGraph(Deployed memory d, GovParams memory p) external view {
        _assertCoreGraph(d, p);
    }

    /// @dev The linked `CreditWiring` address, recovered from `CreditManager`'s runtime rather than
    ///      written down: the most-repeated `PUSH20` immediate that has code behind it. Six link
    ///      sites, so the library address is pushed six times and nothing else in that bytecode is.
    ///      Lifted from `CreditWiringLinkage.t.sol`'s `_linkedWiring`, whose docstring carries the
    ///      argument for why it is derived and not a literal.
    function _linkedWiring(address linked) internal view returns (address found) {
        bytes memory code = linked.code;
        address[] memory candidates = new address[](32);
        uint256[] memory hits = new uint256[](32);
        uint256 n;

        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0x73 && i + 21 <= code.length) {
                address candidate;
                assembly {
                    candidate := shr(96, mload(add(add(code, 0x20), add(i, 1))))
                }
                if (candidate.code.length != 0) {
                    uint256 slot = type(uint256).max;
                    for (uint256 j; j < n; j++) {
                        if (candidates[j] == candidate) {
                            slot = j;
                            break;
                        }
                    }
                    if (slot == type(uint256).max && n < candidates.length) {
                        slot = n++;
                        candidates[slot] = candidate;
                    }
                    if (slot != type(uint256).max) hits[slot]++;
                }
                i += 21;
            } else if (op >= 0x60 && op <= 0x7f) {
                i += uint256(op) - 0x5f + 1;
            } else {
                i += 1;
            }
        }

        uint256 best;
        for (uint256 j; j < n; j++) {
            if (hits[j] > best) {
                best = hits[j];
                found = candidates[j];
            }
        }
        require(best >= 2, "fixture: no repeated linked-library address");
    }

    /// @notice The adapter is the FOURTH contract `_deployProtocol` creates, asserted through the
    ///         real function instead of a hand-rolled fixture.
    ///
    /// @dev    Round 34 listed, among the things its determinism fixture could NOT catch: "adding
    ///         one contract ahead of the adapter in `_deployProtocol` moves the production receiver
    ///         and leaves this test green". That is true of any fixture that hand-rolls four
    ///         CREATEs and never calls `_deployProtocol`, and both frozen-plan guards do exactly
    ///         that. This one calls it.
    ///
    ///         It asserts an OFFSET, never an absolute address, and the distinction is the whole
    ///         design. The frozen plan's addresses belong to a different deployer starting from a
    ///         different nonce, so they cannot be checked here without importing that deployer's
    ///         whole world. What DOES transfer is the shape: how many contracts this function
    ///         creates before the adapter. The mint receiver is CREATE2 from the adapter, so if
    ///         that count moves the receiver moves with it, wherever the ladder is anchored.
    ///
    ///         What it still cannot see, and the docstring in the determinism fixture says so
    ///         too: a transaction forge inserts AHEAD of the script body. `CreditWiring`'s CREATE2
    ///         is one, and no Solidity test can observe it, because `vm.startBroadcast` in a
    ///         `forge test` frame does not model `forge script`'s broadcast head. That half is
    ///         covered off-chain by reading a real broadcast artefact.
    function test_R37_theAdapterIsTheFourthContractDeployProtocolCreates() public {
        uint256 start = vm.getNonce(deployer);
        Deployed memory d = _deployProtocol(_externals(), _params(), deployer);

        assertEq(
            address(d.oracle), vm.computeCreateAddress(deployer, start), "the oracle is not slot 0"
        );
        assertEq(
            address(d.riskParams),
            vm.computeCreateAddress(deployer, start + 1),
            "the risk parameters are not slot 1"
        );
        assertEq(
            address(d.vault), vm.computeCreateAddress(deployer, start + 2), "the vault is not slot 2"
        );

        // The load-bearing one. Anything created ahead of the adapter inside `_deployProtocol`
        // fails here and nowhere else.
        assertEq(
            address(d.adapter),
            vm.computeCreateAddress(deployer, start + 3),
            "THE ADAPTER MOVED: it is no longer the fourth contract _deployProtocol creates, so the frozen mint receiver has moved and any DexFi-signed payload bound to it is dead"
        );
    }
}
