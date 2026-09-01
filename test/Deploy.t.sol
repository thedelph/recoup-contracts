// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {DeployMainnet, DeployTestnet} from "../script/Deploy.s.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {Config} from "../src/Config.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice The environment seam, backed by storage instead of by the process environment.
///
/// @dev **Audit round 30 closed the `vm.setEnv` race, and this is the whole of the fix.** The
///      hazard is not that a write "leaks into every other test in the run", which is how this file
///      used to describe it and which models it as poisoning whatever runs NEXT. It is worse:
///      `forge test` runs a suite's functions in parallel on one process, and `vm.setEnv` writes
///      one process-wide table, so a sibling's write lands in the MIDDLE of a test that is reading.
///      Measured before this change at roughly one run in eight, as
///      `OwnableUnauthorizedAccount(DEFAULT_SENDER)` or `OwnershipNotTransferred(..., DEFAULT_SENDER)`
///      - a plausible protocol revert in a test that is correct - and green in five runs of five
///      under `--threads 1`, which is what identifies it as a race rather than a defect.
///
///      Two rounds of narrowing the blast radius came before this one: blank one variable rather
///      than twenty, and export on the line immediately before the call that reads. Both made it
///      rarer. Neither could make it go away, because a race needs only one writer to exist, and
///      this file's own note said as much: the complete fix is "one test function in the process
///      touching the environment at all". The complete fix is actually zero, and it does not cost
///      the three named refusals that argument was weighing.
///
///      Forge isolates EVM state per test function, so these mappings are private to the function
///      that wrote them. `set()` is called on the object under test - a script instance, or `this`
///      - and `_envOrAddress`/`_envOrString` read it back. **Nothing overridden falls through to
///      the real `vm.envOr`**, so a test that installs nothing behaves exactly as it did.
///
///      **`forge test` in this repo now contains no `vm.setEnv` call at all.** Keep it that way:
///      one writer is enough to bring the race back, and it will come back as somebody else's test
///      failing.
abstract contract EnvOverridable is DeployBase {
    mapping(bytes32 => address) private _addressOverride;
    mapping(bytes32 => bool) private _addressOverridden;
    mapping(bytes32 => string) private _stringOverride;
    mapping(bytes32 => bool) private _stringOverridden;

    /// @dev Deliberately `external` rather than `internal`: the caller is usually a *different*
    ///      contract (the test installing values on a script instance), and the two-argument shape
    ///      keeps every call site reading like the `vm.setEnv` it replaces.
    function setEnvAddress(string memory key, address value) external {
        bytes32 k = keccak256(bytes(key));
        _addressOverride[k] = value;
        _addressOverridden[k] = true;
    }

    function setEnvString(string memory key, string memory value) external {
        bytes32 k = keccak256(bytes(key));
        _stringOverride[k] = value;
        _stringOverridden[k] = true;
    }

    function _envOrAddress(string memory key, address fallbackValue)
        internal
        view
        virtual
        override
        returns (address)
    {
        bytes32 k = keccak256(bytes(key));
        if (_addressOverridden[k]) return _addressOverride[k];
        return super._envOrAddress(key, fallbackValue);
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        virtual
        override
        returns (string memory)
    {
        bytes32 k = keccak256(bytes(key));
        if (_stringOverridden[k]) return _stringOverride[k];
        return super._envOrString(key, fallbackValue);
    }
}

/// @notice `WirePhase4` with its two timelock entry points reachable without the process
///         environment.
/// @dev `vm.setEnv` writes one table shared by every test in the process, and `forge test` runs a
///      suite's functions in parallel - so an env-driven test of `queue()` both raced its siblings
///      and made them fail. Measured: four failures in five, then a different test failing once
///      this one was made robust, and both green under `--threads 1`. The split in the script is
///      what this uses: `queue()` and `executeQueued()` resolve addresses and then delegate, and
///      everything that decides anything is below the delegation.
///
///      **The split stays, and round 30 did not make it redundant.** `EnvOverridable` removes the
///      race for the entry points that must read a resolution; this removes the resolution from the
///      tests that never needed one. A test that passes `Deployed` and `GovParams` in directly
///      cannot be wrong about them, which is a stronger statement than a test that installs them
///      correctly.
contract ExposedWirePhase4 is WirePhase4, EnvOverridable {
    /// @dev Solidity refuses an inherited function two bases define, even when one of them is an
    ///      override of the other's, so the disambiguation has to be written out. Both forward to
    ///      `EnvOverridable`, which is the whole point of the mixin - a forwarder that pointed at
    ///      `DeployBase` here would silently give this script back the process environment and put
    ///      the race back with nothing in the diff saying so.
    function _envOrAddress(string memory key, address fallbackValue)
        internal
        view
        override(DeployBase, EnvOverridable)
        returns (address)
    {
        return EnvOverridable._envOrAddress(key, fallbackValue);
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        override(DeployBase, EnvOverridable)
        returns (string memory)
    {
        return EnvOverridable._envOrString(key, fallbackValue);
    }

    /// @dev `GovParams` since audit round 22, finding 7: `_queue` runs `_assertCoreGraph` before it
    ///      schedules anything, and that needs the owner and the four operator addresses.
    function exposedQueue(Deployed memory d, TimelockController timelock, GovParams memory p)
        external
    {
        _queue(d, timelock, p);
    }

    function exposedExecuteQueued(Deployed memory d, TimelockController timelock, GovParams memory p)
        external
    {
        _executeQueued(d, timelock, p);
    }

    /// @dev Round 21, finding 2: step one of the two-step, exposed for the same reason the other
    ///      two are. A step the tests cannot reach is a step the deployment has never rehearsed.
    function exposedQueuePause(Deployed memory d, TimelockController timelock, bytes32 salt) external {
        _queuePause(d, timelock, salt);
    }

    function exposedExecuteQueuedPause(Deployed memory d, TimelockController timelock, bytes32 salt)
        external
    {
        _executeQueuedPause(d, timelock, salt);
    }
}

/// @notice `DeployMainnet` with its three preconditions reachable from a test.
///
/// @dev **Audit round 38 found the three gates were executed by nothing.** `DeployTestnet`
///      has both of its refusals run by this suite; `DeployMainnet` has three and had none. Its
///      `run()` body had never been entered by any test in the tree, so the guard set that stands
///      between a stray `forge script` and Base mainnet was read-only evidence - the exact shape
///      the note above `test_testnet_refusesAnyChainButBaseSepolia` calls out and then leaves
///      standing for the mainnet target.
///
/// @dev **No `vm.setEnv`, and that is why the harness exists at all rather than the tests calling
///      `new DeployMainnet()` directly.** Two of the three gates read the environment, and this
///      process contains zero `vm.setEnv` calls on purpose - see `EnvOverridable`, which records
///      the measured race that removed the last one. The subclass adds the storage-backed seam and
///      nothing else, so `run()` here is the real `run()`; it is the same construction
///      `ExposedWirePhase4` uses, for the same reason.
///
/// @dev **All three gates fire before `_resolveParams`**, so none of these tests needs a fork, a
///      funded key, or the live `Config.DEXFI_BOND_NFT` to exist. The `Externals` struct that names
///      the real Base addresses is built one statement after the parameter resolution that stops
///      every test here, which is what keeps this suite chain-free.
contract DeployMainnetHarness is DeployMainnet, EnvOverridable {
    /// @dev Solidity refuses an inherited function two bases define, even when one is an override
    ///      of the other's. Both forward to `EnvOverridable`; a forwarder pointing at `DeployBase`
    ///      would hand the script back the process environment with nothing in the diff saying so.
    function _envOrAddress(string memory key, address fallbackValue)
        internal
        view
        override(DeployBase, EnvOverridable)
        returns (address)
    {
        return EnvOverridable._envOrAddress(key, fallbackValue);
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        override(DeployBase, EnvOverridable)
        returns (string memory)
    {
        return EnvOverridable._envOrString(key, fallbackValue);
    }

    /// @notice The script's own two literals, read back rather than retyped in the tests.
    /// @dev A test that hardcodes `"RECOUP_DEPLOY_BASE_MAINNET"` still passes after somebody
    ///      changes the phrase in `Deploy.s.sol`: it would install a phrase the script no longer
    ///      wants, the gate would refuse, and `test_mainnet_requiresTheConfirmationPhrase` would go
    ///      on asserting a refusal for the wrong reason while the control that proves the gate is
    ///      passable is the one that breaks. Reading both constants off the contract under test
    ///      means the fixture cannot disagree with it.
    function confirmPhrase() external pure returns (string memory) {
        return CONFIRM_PHRASE;
    }

    function baseChainId() external pure returns (uint256) {
        return BASE_CHAIN_ID;
    }
}

/// @notice Coverage for the deployment path itself.
///
///         Until now `DeployLocal` wired the protocol and `DeployMainnet` reverted,
///         which meant the wiring destined for mainnet had never executed anywhere.
///         A correctly designed protocol that is incorrectly wired is worth nothing,
///         so the deploy sequence runs here on every CI run.
contract DeployTest is Test, EnvOverridable {
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal navConfirmer = makeAddr("navConfirmer");
    address internal owner = makeAddr("owner");
    /// @dev The two parties audit round 20's finding 5 is about: the proposer is governance, the
    ///      `outsider` is anybody at all - which is exactly who may call `execute` when the
    ///      executor set is `[address(0)]`, as both governance suites deploy it.
    address internal proposer = makeAddr("proposer");
    address internal outsider = makeAddr("outsider");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(ANVIL_CHAIN_ID);
    }

    /// @dev **`vm.setEnv` mutates one process-global table and `forge test` runs a suite's
    ///      functions in parallel, so a write by one test lands in the middle of another.** There
    ///      used to be a `_clearScriptEnv()` blanking twenty variables, called from `setUp()` -
    ///      which meant every one of the fifty-one tests here was a writer, racing the three that
    ///      read. MEASURED at `d8e2208`, before anything in this branch changed:
    ///      `test_wirePhase4_scriptEntrypointWiresAndAssertsInOneRun` failed roughly one run in
    ///      eight as `OwnableUnauthorizedAccount(DEFAULT_SENDER)` or
    ///      `OwnershipNotTransferred(..., DEFAULT_SENDER)` - a plausible protocol revert, in a test
    ///      that is correct - and was green in five runs of five under `--threads 1`, which is what
    ///      identifies it as a race rather than a defect. Three tests added in this branch took it
    ///      to two in eight, which is what made it this branch's problem to fix.
    ///
    ///      **CLOSED in audit round 30, and the paragraph that used to be here is kept above
    ///      because it is the measurement.** The rule then was "a test blanks exactly the variable
    ///      its own assertion is about, and restores it if it can", and it argued that the complete
    ///      fix - one test function in the process touching the environment at all - would cost
    ///      three named refusals merged into one. That was two things wrong at once. The complete
    ///      fix is ZERO writers, not one, because `vm.setEnv` calls `setenv` on a process whose
    ///      other threads are inside `getenv`, so even a key nobody else reads is a write into a
    ///      table being read concurrently. And it costs nothing at all: `EnvOverridable` at the top
    ///      of this file backs the seam with per-instance storage, which forge isolates per test
    ///      function, so the three refusals stay three and simply stop sharing anything.
    ///
    ///      **There is no `vm.setEnv` anywhere in `contracts/test` or `contracts/script` now.**
    ///      That is the property; one writer is enough to bring the race back, and it will come
    ///      back as somebody else's test failing.
    ///
    ///      **The residual, stated rather than left to be discovered.** The seam's base
    ///      implementation - the single `return vm.envOr(key, fallbackValue)` in `DeployBase` - is
    ///      no longer covered by any assertion, because the only way to assert it from inside
    ///      `forge test` is the cheatcode being removed. It is exercised on every real `forge
    ///      script` run and by nothing here. A test that installs no override still reaches it, so
    ///      a seam that stopped reading the environment would break a deploy and not this suite.
    ///
    ///      Every other test in this file passes `GovParams` and `Deployed` in directly and reads
    ///      no environment at all. Keep it that way; the two `_install*` helpers at the bottom
    ///      enumerate the full set for the tests that cannot.

    function _externals() internal view returns (Externals memory) {
        return Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });
    }

    function _params() internal view returns (GovParams memory) {
        return GovParams({
            owner: owner,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: treasury,
            // Go-live item G4, deliberately UNFILLED in this fixture: the deploy tests are about
            // wiring and ownership, and an unfilled role is the shipped default. The filled case
            // has its own test below, because zero and non-zero take different branches in
            // `_validateParams` and in `_assertWiring`.
            guardian: address(0)
        });
    }

    /// @dev External wrappers: `expectRevert` only catches reverts one call depth
    ///      below the cheatcode, and the functions under test are internal.
    function exposedValidateParams(GovParams memory p, address deployer) external view {
        _validateParams(p, deployer);
    }

    /// @dev The superset the deploy path uses. Separate from the wrapper above because the
    ///      difference between the two is itself a finding: one is a rule about a set of addresses
    ///      and the other is a rule about the act of MAKING a deployment, and having the second
    ///      live where the first does made the Phase-4 switchover unreachable on the shape this
    ///      repository ships.
    function exposedValidateNewDeployment(GovParams memory p, address deployer) external view {
        _validateNewDeployment(p, deployer);
    }

    function exposedAssertWiring(Deployed memory d, GovParams memory p) external view {
        _assertWiring(d, p);
    }

    /// @dev The deploy sequence itself, reachable from `expectRevert`. Audit round 30 put
    ///      `_validateParams` at the top of `_deployProtocol`, and a guard nothing can reach from
    ///      outside is the shape that change exists to close.
    function exposedDeployProtocol(Externals memory e, GovParams memory p, address deployer)
        external
        returns (Deployed memory)
    {
        return _deployProtocol(e, p, deployer);
    }

    /// @dev The Phase-4 switchover, reachable from `expectRevert`. It has to be a real external
    ///      call for the cheatcode to see the revert, and the contracts have to accept this test
    ///      contract as their owner for the calls inside it to be authorised - which is what
    ///      `_paramsOwnedHere` is for.
    function exposedWirePhase4(Deployed memory d) external {
        _wirePhase4(d);
    }

    function exposedAssertPhase4Wiring(Deployed memory d, GovParams memory p) external view {
        _assertPhase4Wiring(d, p);
    }

    // ── the deploy sequence ──────────────────────────────────────────────────

    /// @dev **This test used to enumerate eight of the nine, so CI certified the gap.** It listed
    ///      exactly what `_assertCoreGraph` listed, which is not a check - it is the same claim
    ///      written twice. `d.riskParams` was absent from both, and the deployment could hand eight
    ///      contracts to the governance Safe while the broadcasting EOA kept the ninth, with the
    ///      script's post-condition and this test agreeing that everything was fine.
    ///
    ///      Derived now, from `_ownablesOf`, so a tenth contract cannot be missed here either.
    function test_deployHandsEverythingToTheConfiguredOwner() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));
        _assertWiring(d, _params());

        address[] memory ownables = _ownablesOf(d);
        for (uint256 i; i < ownables.length; ++i) {
            assertEq(Ownable(ownables[i]).owner(), owner, "a deployed contract is not owned by the configured owner");
        }
    }

    /// @notice The enumeration reaches every member of `Deployed`, including the one it missed.
    /// @dev The regression witness, and the only place `d.riskParams` is named. Everything else
    ///      derives, so without this nothing would fail if the enumeration silently shrank - and a
    ///      list that quietly covers fewer contracts than it claims is precisely the failure being
    ///      fixed, one level up.
    function test_theOwnershipEnumerationReachesEveryDeployedContract() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        address[] memory ownables = _ownablesOf(d);
        assertEq(ownables.length, abi.encode(d).length / 32, "the enumeration is shorter than the struct");

        bool sawRiskParams;
        for (uint256 i; i < ownables.length; ++i) {
            if (ownables[i] == address(d.riskParams)) sawRiskParams = true;
        }
        assertTrue(sawRiskParams, "the contract that owns the borrow ceiling is not in the ownership list");
    }

    /// @notice A stranger holding any one deployed contract fails the script's post-condition.
    /// @dev **Measured with a control, and the control is the finding.** Before the enumeration,
    ///      moving `riskParams` to a stranger left `_assertWiring` passing, while the identical
    ///      move on any of the other eight reverted. This asserts the property for every member of
    ///      the struct rather than for a list, so it stays true of a tenth contract.
    function test_deployAssertionRefusesAnyContractHeldByAStranger() public {
        address stranger = makeAddr("stranger");
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));
        address[] memory ownables = _ownablesOf(d);

        for (uint256 i; i < ownables.length; ++i) {
            vm.prank(owner);
            Ownable(ownables[i]).transferOwnership(stranger);

            vm.expectRevert(
                abi.encodeWithSelector(DeployBase.OwnershipNotTransferred.selector, ownables[i], stranger)
            );
            this.exposedAssertWiring(d, _params());

            vm.prank(stranger);
            Ownable(ownables[i]).transferOwnership(owner);
        }
    }

    /// @dev Round 10, finding 10. `_wire` set these and `_assertWiring` checked none of them,
    ///      which is the shape audit-7 finding #6 named. Each fails quietly rather than loudly: a
    ///      wrong `pool.epochHarvester` is swallowed by the harvester's best-effort catch and the
    ///      lender share accrues forever with no error at all.
    ///
    ///      **Deliberate inversion, round 11.** The third line asserted
    ///      `credit.lenderPool() == address(d.pool)` - that a shipping deployment names the pool
    ///      as the sink for socialised losses. That was wrong, and the reason is the finding
    ///      below: the same script left the treasury as the liquidity source, so the pool bore no
    ///      credit risk while `flushLenderYield` paid its depositors a quarter of every epoch.
    ///      The pointer now belongs to `_wirePhase4`, and this test keeps only the two legs a
    ///      shipping deployment really does set. The zero is asserted in its own test rather than
    ///      here, because "the pool knows its manager" and "nobody is paying the pool yet" are
    ///      different claims and should fail with different names.
    function test_deployAssertsTheLenderTriangle() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        assertEq(d.pool.creditManager(), address(d.credit), "pool.creditManager");
        assertEq(d.pool.epochHarvester(), address(d.harvester), "pool.epochHarvester");
    }

    /// @dev The deployer is a hot key that signed one transaction. It should hold no
    ///      authority once the script finishes.
    ///      This one had all nine and still could not have caught round 20's finding, because it
    ///      is the weaker check: `!= address(this)` rules out a wrong destination without
    ///      asserting the right one, which is the rule this file states below. The positive
    ///      version above is the one that mattered, and that one was short. Both derive now.
    function test_deployLeavesNothingOwnedByTheDeployer() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        address[] memory ownables = _ownablesOf(d);
        for (uint256 i; i < ownables.length; ++i) {
            assertTrue(Ownable(ownables[i]).owner() != address(this), "the deployer still owns a deployed contract");
        }
    }

    /// @dev Closes the "deploy wiring is incomplete" item: these setters were never called by the
    ///      old script.
    ///
    ///      **Deliberate inversion, round 11.** This asserted
    ///      `harvester.lenderPool() == address(d.pool)` - that a shipping deployment points the
    ///      harvester's lender leg at the pool. It was added to close a gap where the setter was
    ///      never called at all, and it overshot: calling it is what made `flushLenderYield`
    ///      succeed for depositors carrying no credit risk, since the same script left the
    ///      treasury funding every loan. The line moves to `_wirePhase4` and the assertion moves
    ///      to `test_deploy_shipsWithNoLenderExposure`, which asserts the pointer is zero *and*
    ///      that the accrual it gates still happens - so the gap this test was written to close
    ///      cannot re-open unnoticed.
    function test_deployCompletesTheWiringThatWasMissing() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        assertEq(address(d.harvester.custodyAdapter()), address(d.adapter));
        assertEq(d.harvester.protocolFeeWallet(), treasury);
        assertEq(d.oracle.keeper(), keeper);
    }

    function test_deployWiresTheCoreGraph() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        assertEq(address(d.vault.custodyAdapter()), address(d.adapter));
        assertEq(d.vault.creditManager(), address(d.credit));
        assertEq(d.vault.liquidationAuction(), address(d.auction));
        assertEq(d.adapter.vault(), address(d.vault));
    }

    /// @dev adapter.harvester stays unset on purpose. Under an EOA owner the owner can
    ///      already call vault.harvestYield() directly, so wiring it buys nothing and
    ///      would hand a claim right to an address that cannot use it. It becomes
    ///      load-bearing only once the owner is slow, or the EpochHarvester ships.
    /// @dev Was `test_adapterHarvesterIsDeliberatelyUnset`. The deferral it asserted was
    ///      written before the EpochHarvester existed and outlived its own stated
    ///      trigger; leaving it unset meant `harvest` could never claim, so every epoch
    ///      silently reported zero yield.
    function test_adapterYieldPathReachesTheHarvester() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        // Permission to claim...
        assertEq(d.adapter.harvester(), address(d.harvester), "harvester may claim");
        // ...and the destination the claimed USDC actually sweeps to. The second is
        // the one that carries the money; wiring only the first still routes 100% of
        // yield past the split.
        assertEq(d.adapter.yieldRecipient(), address(d.harvester), "and it lands there");
    }

    /// @dev The end-to-end proof that the wiring produces a protocol that can actually
    ///      lend. Before Phase 2 the deploy script wired `lenderPool` and nothing else,
    ///      so a freshly deployed protocol would have reverted on every borrow.
    function test_deployedProtocolCanBorrow() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        // The two post-deploy steps the script prints as reminders.
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(d.liquidity), 10_000e6);
        d.liquidity.fund(10_000e6);
        vm.prank(owner);
        d.oracle.bootstrapNav(25.15e8);

        // Collateral, then a borrow well inside maxLTV.
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);
        address borrower = makeAddr("borrower");
        bond.mint(borrower, 100);
        vm.startPrank(borrower);
        bond.setApprovalForAll(address(d.vault), true);
        d.vault.depositBonds(100);
        d.credit.borrow(500e6);
        vm.stopPrank();

        // The disbursement is the loan less the prepaid liquidation bounty; the debt is the
        // whole loan. 500e6 is exactly the smallest bountied position, so this one is charged.
        assertEq(usdc.balanceOf(borrower), 500e6 - Config.LIQUIDATION_CALL_BOUNTY);
        assertEq(d.credit.bountyEscrowOf(borrower), Config.LIQUIDATION_CALL_BOUNTY);
        assertEq(d.credit.debtOf(borrower), 500e6);
    }

    // ── Phase 4: the pool takes the funding and the losses together ──────────

    uint256 internal constant FLOAT = 10_000e6;
    uint256 internal constant LOAN = 500e6;
    uint256 internal constant BONDS = 100;
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant EPOCH_YIELD = 1_000e6;

    /// @dev Same parameters, except this contract keeps ownership instead of handing it to
    ///      `owner`. The Phase-4 switchover is a set of `onlyOwner` calls made from inside
    ///      `_wirePhase4`, and a prank set on this contract does not follow through an
    ///      `this.exposedWirePhase4(...)` hop - the inner calls originate one depth further in and
    ///      arrive unpranked, so the tests would fail on ownership and prove nothing about the
    ///      guards they exist to exercise. Being the owner outright is the same code path: the
    ///      script itself skips `_handOver` whenever `RECOUP_OWNER` resolves to the deployer.
    function _paramsOwnedHere() internal view returns (GovParams memory p) {
        p = _params();
        p.owner = address(this);
    }

    /// @dev A deployment that can actually lend: the two post-deploy steps the script prints as
    ///      reminders, the whitelist DexFi controls on mainnet, and a collateralised borrower.
    ///      Everything below is about what happens once real money is moving, and a fixture that
    ///      only deploys would let every assertion pass against a protocol nobody could use.
    function _liveProtocol() internal returns (Deployed memory d, address borrower) {
        d = _deployProtocol(_externals(), _paramsOwnedHere(), address(this));

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(d.liquidity), FLOAT);
        d.liquidity.fund(FLOAT);
        d.oracle.bootstrapNav(NAV);

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);

        borrower = makeAddr("borrower");
        bond.mint(borrower, BONDS);
        vm.startPrank(borrower);
        bond.setApprovalForAll(address(d.vault), true);
        d.vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @notice **Audit round 11's finding, as a regression test.** A deployment must not pay the
    ///         lender share to depositors who carry none of the credit risk.
    /// @dev `_wire` set the treasury as liquidity source and the pool as loss sink on adjacent
    ///      lines, and `EpochHarvester.flushLenderYield` is permissionless - so anyone could
    ///      deposit into the pool and collect `Config.SPLIT_LENDER_BPS` of every epoch while the
    ///      treasury funded every loan and absorbed every default. The socialisation fix landing
    ///      in the same round made it strictly worse: `_socialise` will not charge a pool that is
    ///      not also the liquidity source, so the pool was a loss sink that could never be
    ///      charged, and `_assertWiring` was asserting that arrangement as correct.
    ///
    ///      Both halves are asserted here, and the second is the one that matters. Zero pointers
    ///      alone would also be satisfied by a harvester that had stopped accruing the lender
    ///      share at all, which would forfeit money owed to whoever eventually takes the risk.
    ///      The share must still be earned and still be owed - it simply has nowhere to go yet.

    /// @dev **Round 40, D7.** `DeployBase._wire` now ships the `LenderPool` PAUSED, so every
    ///      fixture below that seeds a lender has to open the door first, through the owner, the
    ///      way a real operator's seed-and-flush operation does. Idempotent on purpose: several
    ///      of these tests seed twice.
    ///
    ///      Deliberately NOT folded into the deploy helper. A fixture that silently unpauses
    ///      would hide the shipped state from every test in this file, which is the shape that
    ///      let "the LenderPool ships dormant" stand unexamined for five rounds.
    function _openPoolForLenders(LenderPool pool) internal {
        if (pool.paused()) pool.unpause();
    }

    function test_deploy_shipsWithNoLenderExposure() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _assertWiring(d, _paramsOwnedHere());

        assertEq(d.credit.lenderPool(), address(0), "no loss sink while the treasury funds the book");
        assertEq(d.harvester.lenderPool(), address(0), "and nobody to pay the lender share to");

        vm.prank(borrower);
        d.credit.borrow(LOAN);

        // A complete epoch, on the money the treasury's loan is earning.
        farm.setPendingYield(address(d.adapter), EPOCH_YIELD);
        d.harvester.harvest();

        uint256 toLenders = (EPOCH_YIELD * Config.SPLIT_LENDER_BPS) / Config.BPS;
        assertGt(toLenders, 0, "the split must actually pay lenders, or this test proves nothing");
        assertEq(d.harvester.pendingLenderYield(), toLenders, "accrued and owed, not forfeited");

        // The permissionless function that made the finding exploitable now has nowhere to send
        // it, and says so by name rather than by paying the wrong people.
        vm.expectRevert(abi.encodeWithSelector(EpochHarvester.NotWired.selector, "lenderPool"));
        d.harvester.flushLenderYield();
        assertEq(d.harvester.pendingLenderYield(), toLenders, "still owed after the refusal");
    }

    /// @notice The switchover, end to end: the pool becomes the funder and the loss sink in one
    ///         operation, and the protocol still works afterwards.
    /// @dev Composed on purpose. Three separate tests asserting "the pointer moved", "the guard
    ///      refuses" and "a borrow succeeds" would each pass in isolation against a contract whose
    ///      guards are mutually unsatisfiable, which is the failure this repository has shipped
    ///      twice. So this runs the whole sequence in one transaction and then spends real money
    ///      through it: a lender funds the pool, the pool funds a borrow, and the lender leg
    ///      finally has somewhere to deliver.
    function test_deploy_phase4SwitchoverWiresEveryLegTogether() public {
        (Deployed memory d, address borrower) = _liveProtocol();

        // Borrow and repay in full, so the switchover meets the state it will really meet: an
        // empty book with the treasury's principal sitting in `pendingPrincipal` waiting to go
        // home. `setLiquiditySource` refuses while that counter is non-zero, and the manager's own
        // migration notes say the money becomes unreachable by every contract if the pointer moves
        // first - which is why `_wirePhase4` settles before it repoints rather than after.
        vm.startPrank(borrower);
        d.credit.borrow(LOAN);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        assertEq(d.credit.pendingPrincipal(), LOAN, "the fixture must leave the treasury owed");

        this.exposedWirePhase4(d);

        _assertPhase4Wiring(d, _paramsOwnedHere());
        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool funds the book");
        assertEq(d.credit.lenderPool(), address(d.pool), "and takes the losses on it");
        assertEq(d.harvester.lenderPool(), address(d.pool), "and is paid for both");
        assertEq(d.credit.pendingPrincipal(), 0, "settled before the pointer moved");
        assertEq(usdc.balanceOf(address(d.liquidity)), FLOAT, "the treasury float came home whole");

        // Reachable end to end, which is the part three isolated tests could not show. A lender
        // funds the pool...
        address lender = makeAddr("lender");
        _openPoolForLenders(d.pool);
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();

        // ...the pool funds a borrow, so the exposure is real rather than nominal...
        vm.prank(borrower);
        d.credit.borrow(LOAN);
        assertEq(d.pool.outstandingPrincipal(), LOAN, "the pool now carries the credit risk");

        // ...and only now does the lender share have anywhere to land.
        farm.setPendingYield(address(d.adapter), EPOCH_YIELD);
        d.harvester.harvest();
        assertGt(d.harvester.pendingLenderYield(), 0, "an epoch has to have accrued something");
        d.harvester.flushLenderYield();
        assertEq(d.harvester.pendingLenderYield(), 0, "paid to a pool that is actually exposed");
    }

    /// @notice The switchover cannot run over a live book, and stops being refused the moment the
    ///         book is clear.
    /// @dev The refusal is what makes "whose money funded this loan" answerable from a single
    ///      pointer, which is the assumption the round-11 socialisation fix rests on: a source
    ///      that could change under a live loan would make the current pointer a statement about
    ///      today's configuration rather than about yesterday's money.
    ///
    ///      **Both halves in one test, deliberately.** A test that only asserts the refusal passes
    ///      just as happily against a switchover that can never happen at all, and this repository
    ///      has shipped a guard whose precondition its own escape hatch could not satisfy. So the
    ///      backlog is then resolved the way a real operator would resolve it, and the same call
    ///      is made again and must succeed.
    function test_deploy_phase4SwitchoverIsRefusedWhileABacklogIsUnresolved() public {
        (Deployed memory d, address borrower) = _liveProtocol();

        vm.prank(borrower);
        d.credit.borrow(LOAN);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.DebtOutstanding.selector, LOAN));
        this.exposedWirePhase4(d);

        // Nothing moved, so the treasury is still the funder and nobody is owed a lender share
        // against a book they have no stake in.
        assertEq(d.credit.liquiditySource(), address(d.liquidity), "a refused switchover must not half-run");
        assertEq(d.credit.lenderPool(), address(0));
        assertEq(d.harvester.lenderPool(), address(0));

        // The ordinary wind-down: the borrower repays. `_wirePhase4` settles the resulting
        // `pendingPrincipal` itself, so the operator does not have to know that the second clause
        // of the same guard is now the one blocking them.
        vm.startPrank(borrower);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        assertEq(d.credit.pendingPrincipal(), LOAN, "and the guard's other clause is now armed");

        this.exposedWirePhase4(d);
        _assertPhase4Wiring(d, _paramsOwnedHere());
    }

    // ── the gap inside the switchover (audit round 19, critical 3) ───────────

    /// @dev NAV low enough that a lot of `BONDS` cannot cover `LOAN` even at the auction floor,
    ///      so the position defaults for real rather than clearing. 100 bonds at $6.00 is $600 of
    ///      collateral against $500 of debt - an LTV of 8333 bps against a 5000 threshold - and
    ///      68% of $600 is $408, comfortably short of the debt.
    uint256 internal constant CRASHED_NAV = 6e8;

    /// @dev Crash the price through the real oracle rather than a mock, because this fixture runs
    ///      the shipped `NAVOracle` that `_deployProtocol` constructs. A drop this size is outside
    ///      the keeper's prorated budget by design, so it parks for the second key: post, wait out
    ///      `NAV_PENDING_DELAY`, confirm. That is the protocol's own path for a large move, not a
    ///      test-only shortcut.
    function _crashNav(Deployed memory d, uint256 nav) internal {
        vm.prank(keeper);
        d.oracle.postNav(nav);
        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(navConfirmer);
        d.oracle.confirmNav(nav);
        assertEq(d.oracle.navPerBond(), nav, "the crash has to actually land, or this proves nothing");
    }

    /// @dev Drive a position all the way to a written-down loss: liquidate, let the auction lapse
    ///      unbid, force the workout closed once `WORKOUT_MAX_DURATION` is up. The lapse path is
    ///      used rather than a short fill because it writes the *whole* debt down, which is what
    ///      makes the stuck figure below exactly `LOAN` and therefore unambiguous.
    function _defaultToWriteDown(Deployed memory d, address borrower) internal {
        d.credit.liquidate(borrower);
        uint256 auctionId = d.auction.auctionOf(borrower);
        assertGt(auctionId, 0, "premise: an auction must have opened");

        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);
        d.auction.expireToWorkout(auctionId);

        vm.warp(block.timestamp + Config.WORKOUT_MAX_DURATION + 1);
        d.auction.closeWorkout(auctionId);
        assertEq(d.credit.debtOf(borrower), 0, "premise: the forced close must have written the debt off");
    }

    /// @notice **Audit round 19, critical 3, now CLOSED - and closed by something else entirely.**
    ///         `_wirePhase4` is three transactions rather than one, and a borrow drawn between the
    ///         funding leg and the sink leg used to put real lender principal on a pool that was not
    ///         yet the loss sink: the default that followed was absorbed by nobody, the pool's
    ///         `outstandingPrincipal` was stuck at the loan permanently, and every wiring assertion
    ///         still reported success. There is no longer a gap to draw a borrow inside.
    /// @dev **This test was the hazard and is now the closure, and the history matters more than
    ///      either.** It was recorded open with a named remedy - "a `whenPaused` gate on
    ///      `setLiquiditySource` itself, 22 call sites across two invariant suites and the fork
    ///      tests" - and with the instruction to delete it only when that gate existed. That gate
    ///      was never built. What closed this was **audit round 21 finding 5**, a different finding
    ///      about a different harm: the funder and the loss sink are two pointers naming one
    ///      economic role, so `setLiquiditySource` now carries the sink with it. The gap has no
    ///      duration because there are no longer two transactions between which it exists.
    ///
    ///      Worth writing down, because a deferred item was carrying a size estimate for a design
    ///      nobody adopted: **the estimate was a hypothesis about one fix, and it kept re-deciding
    ///      the deferral.** The change that actually closed it touched none of those 22 call sites.
    ///
    ///      **What made the gap reachable at all was a fresh borrow, and nothing else.**
    ///      `setLiquiditySource` refuses while `totalDebt` is non-zero, so no pre-existing
    ///      position could be carried into the gap and defaulted there. That is still true and is
    ///      now belt to the braces below it.
    ///
    ///      🟥 **This passage used to put "or `pendingPrincipal`" into that guard AND re-affirm
    ///      the pair as "still true" - audit round 40, item 7.** PR #242 deleted the
    ///      `pendingPrincipal` clause on 2026-08-20; the setter **handles** that balance instead,
    ///      best-effort delivering it to the outgoing source and parking the residue as
    ///      `owedToSource[outgoing]`. The conclusion survives on the `totalDebt` half alone,
    ///      which is the half this test is about, so only the citation moved. Recorded rather
    ///      than quietly corrected because **re-affirming a deleted guard is worse than repeating
    ///      one**: "that is still true" reads as having been re-checked, and it had not been.
    ///
    ///      Kept, rather than deleted, for what it makes unreachable: it moves the pointers directly
    ///      rather than through `_wirePhase4`, which is exactly what an operator transcribing them
    ///      into a Safe does, and it is the only assertion in this file that the funding leg alone
    ///      leaves a consistent protocol behind it.
    function test_deploy_phase4FundingLegCarriesTheLossSinkSoThereIsNoGap() public {
        (Deployed memory d, address borrower) = _liveProtocol();

        // Leg one on its own. This is legal precisely because the book is flat.
        d.credit.setLiquiditySource(address(d.pool));
        assertEq(d.credit.lenderPool(), address(d.pool), "the funding leg must carry the loss sink with it");

        address lender = makeAddr("lender");
        _openPoolForLenders(d.pool);
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();

        // The same real loan the hazard used, drawn in the same place.
        vm.prank(borrower);
        d.credit.borrow(LOAN);
        assertEq(d.pool.outstandingPrincipal(), LOAN, "the pool is carrying the credit risk already");

        _crashNav(d, CRASHED_NAV);
        _defaultToWriteDown(d, borrower);

        // `_socialise` reads `lenderPool` and finds the pool that funded it, so the loss is charged
        // rather than reported as borne by a balance sheet that recorded nothing.
        assertEq(d.pool.lifetimeSocialisedLoss(), LOAN, "the loss must reach the lenders who funded it");
        assertEq(d.credit.unsocialisedLoss(), 0, "and it must not be left deferred either");
        assertEq(d.pool.outstandingPrincipal(), 0, "nothing may be stranded behind it");

        // Legs two and three still land, and are now no-ops on the pointer they name.
        d.credit.setLenderPool(address(d.pool));
        d.harvester.setLenderPool(address(d.pool));
        _assertPhase4Wiring(d, _paramsOwnedHere());

        assertEq(d.credit.totalDebt(), 0, "and the manager agrees there is no debt left");
    }

    /// @notice The other direction: with the switchover paused, the one door into the gap is shut.
    /// @dev The measurement that matters, and it is deliberately the *same* borrow the test above
    ///      uses. `_wirePhase4` pauses before it touches a pointer, so the borrow that stranded
    ///      500,000,000 there reverts here - and the protocol comes back unpaused, so the identical
    ///      borrow succeeds immediately afterwards and is charged correctly to a pool that is now
    ///      both funder and sink.
    ///
    ///      A test that only showed the revert would pass just as happily against a switchover that
    ///      pauses and never unpauses, which is its own outage. Both halves, in one test, for the
    ///      reason `test_deploy_phase4SwitchoverWiresEveryLegTogether` gives.
    function test_deploy_phase4PauseShutsTheOnlyDoorIntoTheGap() public {
        (Deployed memory d, address borrower) = _liveProtocol();

        address lender = makeAddr("lender");
        _openPoolForLenders(d.pool);
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();

        // Pause the way the switchover does, then try the borrow that did the damage.
        d.credit.pause();
        d.vault.pause();
        vm.prank(borrower);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.credit.borrow(LOAN);
        assertEq(d.pool.outstandingPrincipal(), 0, "no exposure can enter the gap at all");

        // **What the pause does NOT cover, asserted so nobody reads it as more than it is.** These
        // stay open throughout the switchover and are meant to: `liquidate` says so in its own
        // docstring - pause stops new risk, never resolution. The gap is safe because the only path
        // that can put *new* exposure on the pool is the one function above, not because pausing
        // shuts the protocol down. A future reader who believes otherwise will widen the gap
        // thinking they are narrowing it.
        //
        // **This comment used to add "and `LenderPool` is not `Pausable` at all", and round-28
        // item 10 made that false.** The pool has its own entry pause now, and the point survives
        // the correction intact rather than despite it: the pool's switch is a third switch, this
        // operation does not throw it, and the assertion below is what says so.
        //
        // `liquidate` refuses on its own terms rather than on the pause, which is the whole point:
        // the borrower has no debt because the borrow above was refused.
        vm.expectRevert(CreditManager.NoDebt.selector);
        d.credit.liquidate(borrower);

        // And the pool's own doors are untouched by a paused manager - the exit, and since
        // round-28 item 10 the entry too, because the pool's pause is a separate switch that this
        // operation deliberately leaves alone.
        assertFalse(d.pool.paused(), "the pool was shut by a switch that does not reach it");
        vm.prank(lender);
        d.pool.requestWithdrawal(1e6, lender);

        d.vault.unpause();
        d.credit.unpause();

        // The whole switchover, which pauses and unpauses on its own account.
        this.exposedWirePhase4(d);
        _assertPhase4Wiring(d, _paramsOwnedHere());
        assertFalse(d.credit.paused(), "the switchover must hand the protocol back open");
        assertFalse(d.vault.paused(), "both of them");

        // And the identical borrow now lands on a pool that is funder and sink together, so the
        // default that follows is charged rather than stranded.
        vm.prank(borrower);
        d.credit.borrow(LOAN);
        assertEq(d.pool.outstandingPrincipal(), LOAN, "the pool is exposed, and now properly so");

        _crashNav(d, CRASHED_NAV);
        _defaultToWriteDown(d, borrower);

        assertEq(d.pool.lifetimeSocialisedLoss(), LOAN, "the loss reached the lenders, in full");
        assertEq(d.pool.outstandingPrincipal(), 0, "and nothing is stranded behind it");
    }

    /// @notice A switchover that dies part-way and leaves the protocol paused is a named failure.
    /// @dev The cost the pause introduces, asserted rather than left as a comment. Under the
    ///      timelock this protocol is heading for, an unnoticed pause is a 48-hour outage.
    function test_deploy_phase4WiringRefusesAProtocolLeftPaused() public {
        (Deployed memory d,) = _liveProtocol();

        this.exposedWirePhase4(d);
        _assertPhase4Wiring(d, _paramsOwnedHere());

        d.credit.pause();
        vm.expectRevert(abi.encodeWithSelector(DeployBase.SwitchoverLeftPaused.selector, "credit"));
        this.exposedAssertPhase4Wiring(d, _paramsOwnedHere());

        d.credit.unpause();
        d.vault.pause();
        vm.expectRevert(abi.encodeWithSelector(DeployBase.SwitchoverLeftPaused.selector, "vault"));
        this.exposedAssertPhase4Wiring(d, _paramsOwnedHere());
    }

    // ── audit round 20, finding 5: the switchover under a timelock ───────────

    /// @dev The governance shape this protocol is heading for and the one both governance suites
    ///      already deploy: one proposer, **open execution** (`address(0)` == anybody), no
    ///      standalone admin. Open execution is the whole finding: it means the executor is a
    ///      stranger, not the operator.
    function _timelock() internal returns (TimelockController tl) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        tl = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    function _governanceTakesOver(Deployed memory d, address newOwner) internal {
        d.vault.transferOwnership(newOwner);
        d.adapter.transferOwnership(newOwner);
        d.oracle.transferOwnership(newOwner);
        d.credit.transferOwnership(newOwner);
        d.pool.transferOwnership(newOwner);
        d.harvester.transferOwnership(newOwner);
        d.auction.transferOwnership(newOwner);
        d.liquidity.transferOwnership(newOwner);
        d.riskParams.transferOwnership(newOwner);
    }

    function _paramsOwnedBy(address who) internal view returns (GovParams memory p) {
        p = _params();
        p.owner = who;
    }

    /// @dev **Audit round 21, finding 2: step one of the switchover, as its own timelock
    ///      operation.** The pause legs used to be legs 1 and 2 of the switchover batch, where they
    ///      executed in the same transaction as the preconditions they were protecting - so for the
    ///      whole forty-eight hour maturity `borrow` was open and one micro-USDC of debt could kill
    ///      the operation. Out here they are in force for the entire window.
    ///
    ///      Scheduled and executed through the real timelock rather than pranked as the owner,
    ///      because the cost of the second operation - a second forty-eight hours - is part of what
    ///      the fix costs and a fixture that prints over it would be lying about the price.
    ///
    ///      `warp`s, so a caller that also needs the switchover matured warps again afterwards.
    function _pauseForSwitchover(Deployed memory d, TimelockController timelock, address whoProposes)
        internal
    {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _phase4PauseCalls(d);
        vm.prank(whoProposes);
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.prank(outsider);
        timelock.executeBatch(t, v, p, bytes32(0), bytes32(0));
        assertTrue(d.credit.paused(), "the switchover window must open shut");
        assertTrue(d.vault.paused(), "both halves of it");
    }

    function _pauseForSwitchover(Deployed memory d, TimelockController timelock) internal {
        _pauseForSwitchover(d, timelock, proposer);
    }

    function _fundALender(Deployed memory d) internal returns (address lender) {
        lender = makeAddr("lender");
        _openPoolForLenders(d.pool);
        usdc.mint(lender, FLOAT);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), FLOAT);
        d.pool.deposit(FLOAT, lender);
        vm.stopPrank();
    }

    /// @notice **The reorder is still real; the harm it used to reach is not.** Round 19's pause is
    ///         correct against the operator and is defeated by the timelock executor: legs queued
    ///         one operation each can be executed in any order by anybody, so the pause happens last
    ///         or never. What that used to buy was round 19's gap, byte for byte. It no longer buys
    ///         it, because the funding leg carries the loss sink.
    /// @dev The operator here makes no mistake at all - every leg of `_phase4Calls` is queued,
    ///      faithfully, in order. What they cannot control is *execution* order, because
    ///      `executors[0]` is `address(0)` and `predecessor` is `bytes32(0)` on each. That half is
    ///      unchanged and is why the batch test below still matters: nothing on chain refuses eight
    ///      separately scheduled operations, `queue()` is what stops them being created.
    ///
    ///      **What changed is the consequence, and it changed under audit round 21 finding 5.**
    ///      `setLiquiditySource` now moves both pointers in one call, so a stranger who runs the
    ///      funding leg alone and unpaused hands the borrow that follows to a pool that is funder
    ///      and sink together. The default is charged in full. Kept for exactly that: it is the
    ///      assertion that reordering no longer reaches the harm, on the one path that used to.
    function test_deploy_phase4LegsQueuedSeparatelyCanBeReorderedButTheGapIsGone() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _fundALender(d);
        TimelockController timelock = _timelock();
        _governanceTakesOver(d, address(timelock));

        // **Round 21 note: the operator here transcribes the WHOLE switchover, pause legs
        // included.** Those two moved out of `_phase4Calls` into `_phase4PauseCalls`, so a fixture
        // that queued only the switchover list would be modelling an operator who skipped the
        // pause - a weaker hazard, and one the round-19 residual already covers. Concatenating the
        // two lists here keeps this measuring what it says: a faithful operator, defeated by the
        // execution order alone.
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _pauseThenSwitchover(d);
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(proposer);
            timelock.schedule(
                targets[i], values[i], payloads[i], bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK
            );
        }
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        // A stranger picks the funding leg and runs it first. The two pauses come in front of it,
        // so this index is found rather than assumed: the point is that the ORDER is not the
        // operator's, not that any particular number is.
        uint256 fundingLeg = _indexOf(targets, payloads, address(d.credit), CreditManager.setLiquiditySource.selector);
        vm.prank(outsider);
        timelock.execute(targets[fundingLeg], 0, payloads[fundingLeg], bytes32(0), bytes32(0));

        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool now funds the book");
        assertEq(d.credit.lenderPool(), address(d.pool), "and is the loss sink in the same call");
        assertFalse(d.credit.paused(), "and nothing is paused: the round-19 fix never ran");

        vm.prank(borrower);
        d.credit.borrow(LOAN);
        _crashNav(d, CRASHED_NAV);
        _defaultToWriteDown(d, borrower);

        assertEq(d.pool.lifetimeSocialisedLoss(), LOAN, "the loss must reach the pool that funded it");
        assertEq(d.credit.unsocialisedLoss(), 0, "and nothing may be left deferred");

        // The rest land, in any order the executor likes.
        for (uint256 i; i < targets.length; ++i) {
            if (i == fundingLeg) continue;
            vm.prank(outsider);
            timelock.execute(targets[i], 0, payloads[i], bytes32(0), bytes32(0));
        }

        // And every post-condition the protocol has reports success over a protocol whose books
        // now agree - which is the half that used to be missing, not the half that used to pass.
        this.exposedAssertPhase4Wiring(d, _paramsOwnedBy(address(timelock)));
        assertEq(d.pool.outstandingPrincipal(), 0, "nothing stranded: the loss came off the principal");
        assertEq(d.credit.totalDebt(), 0, "while the manager agrees there is no debt left");
        emit log_named_uint("MEASURED loss charged, legs queued singly (USDC 6dp)", d.pool.lifetimeSocialisedLoss());
    }

    /// @notice **THE FIX, measured against exactly that hazard.** The same legs, scheduled as one
    ///         `scheduleBatch`, cannot be reordered, cannot be run singly and cannot be run in
    ///         part. `executeBatch` is one transaction, so the gap has no duration to be observed
    ///         in and the identical default is charged to the lenders in full.
    /// @dev The three refusals are the measurement. A batch is one operation with one id computed
    ///      over the whole array, so a single leg and a truncated batch are simply ids nobody ever
    ///      scheduled - `TimelockController` refuses them as `Unset`. That is why this removes the
    ///      window rather than guarding it: there is no guard to defeat.
    function test_deploy_phase4BatchLeavesNoWindowForAnExecutorToReorder() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _fundALender(d);
        TimelockController timelock = _timelock();
        _governanceTakesOver(d, address(timelock));

        // Round 21, finding 2: step one, and the window is shut before it opens.
        _pauseForSwitchover(d, timelock);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4Calls(d);
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        // Named down to the id, rather than a bare `expectRevert`. A bare one would also be
        // satisfied by an ownership failure or by `Pausable` - which is to say by the fix not
        // being the reason. `TimelockUnexpectedOperationState(id, ...)` says specifically "*this*
        // id was never scheduled", which is the property a batch has and separate legs do not.
        //
        // **Every id is read before its `vm.prank`, and that ordering is load-bearing.** A prank is
        // spent on the next call *including a staticcall*, so a `hashOperation` evaluated inside the
        // `expectRevert` argument would eat it and the `execute` below would arrive as this contract
        // rather than as `outsider`. These three assertions would still pass - execution is open, so
        // the caller does not change the answer - which is exactly what makes it worth doing
        // properly: the test would be measuring something other than what it says. Reads, then
        // `expectRevert`, then `prank`, then the call.
        // Each case is its own block. That is not tidiness: holding all three sets of arrays and
        // their expected reverts live at once is stack-too-deep, and `--via-ir` for one test is a
        // worse trade than three braces.
        uint256 fundingLeg = _indexOf(targets, payloads, address(d.credit), CreditManager.setLiquiditySource.selector);

        // (1) The funding leg on its own is not a scheduled operation. **This is the exact call
        //     the hazard test above executes successfully.** Same leg, same actor, same maturity;
        //     the only difference is that it was scheduled inside a batch.
        {
            bytes memory expected = _notScheduled(
                timelock.hashOperation(targets[fundingLeg], 0, payloads[fundingLeg], bytes32(0), bytes32(0))
            );
            vm.expectRevert(expected);
            vm.prank(outsider);
            timelock.execute(targets[fundingLeg], 0, payloads[fundingLeg], bytes32(0), bytes32(0));
        }

        // (2) Neither is the same array reordered - the funding leg moved to the front.
        {
            (address[] memory rt, uint256[] memory rv, bytes[] memory rp) =
                _swapped(targets, values, payloads, 0, fundingLeg);
            bytes memory expected = _notScheduled(timelock.hashOperationBatch(rt, rv, rp, bytes32(0), bytes32(0)));
            vm.expectRevert(expected);
            vm.prank(outsider);
            timelock.executeBatch(rt, rv, rp, bytes32(0), bytes32(0));
        }

        // (3) Neither is a prefix of it, which is how round 20's "five of seven legs executed, the
        //     protocol left shut indefinitely" would have to look.
        {
            (address[] memory pt, uint256[] memory pv, bytes[] memory pp) =
                _prefix(targets, values, payloads, targets.length - 2);
            bytes memory expected = _notScheduled(timelock.hashOperationBatch(pt, pv, pp, bytes32(0), bytes32(0)));
            vm.expectRevert(expected);
            vm.prank(outsider);
            timelock.executeBatch(pt, pv, pp, bytes32(0), bytes32(0));
        }

        assertEq(d.credit.liquiditySource(), address(d.liquidity), "nothing moved: the treasury still funds");
        assertEq(d.credit.lenderPool(), address(0), "and there is still no sink");

        // The whole thing, atomically, by a stranger - which is what open execution is for.
        vm.prank(outsider);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        this.exposedAssertPhase4Wiring(d, _paramsOwnedBy(address(timelock)));
        assertFalse(d.credit.paused(), "and it hands the protocol back open");
        assertFalse(d.vault.paused(), "both of them");

        // The identical borrow and the identical default the hazard above stranded. Charged.
        vm.prank(borrower);
        d.credit.borrow(LOAN);
        _crashNav(d, CRASHED_NAV);
        _defaultToWriteDown(d, borrower);
        assertEq(d.pool.lifetimeSocialisedLoss(), LOAN, "the loss reached the lenders, in full");
        assertEq(d.pool.outstandingPrincipal(), 0, "and nothing is stranded behind it");
    }

    /// @notice The queued operation and the executed one are the same list, derived rather than
    ///         transcribed - which is the other half of this round's finding.
    /// @dev The repo said "the three calls" in four places for an operation that is eight, and the
    ///      five it omitted were the whole of round 19's fix, so the prose was instructing an
    ///      operator to skip it. This asserts the property that stops that recurring: the count is
    ///      whatever `_phase4Calls` returns, the batch is built from it, and executing that batch
    ///      reaches the same state as executing `_wirePhase4`. Nothing here writes a number down.
    function test_deploy_phase4CallListIsTheOperationBothPathsPerform() public {
        (Deployed memory d,) = _liveProtocol();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4Calls(d);

        assertEq(values.length, targets.length, "scheduleBatch requires all three arrays to agree");
        assertEq(payloads.length, targets.length, "scheduleBatch requires all three arrays to agree");
        for (uint256 i; i < values.length; ++i) {
            assertEq(values[i], 0, "no leg of a switchover moves value");
        }

        // **Round 21, finding 2: the pauses are no longer in this list, and asserting their
        // absence is the regression test.** They executed in the same transaction as the
        // preconditions they were guarding, which is a lock inside the room it locks. They live in
        // `_phase4PauseCalls` now and are performed as an earlier, separate operation.
        uint256 fundingLeg = _indexOf(targets, payloads, address(d.credit), CreditManager.setLiquiditySource.selector);
        assertFalse(
            _has(targets, payloads, address(d.credit), CreditManager.pause.selector),
            "the manager pause must not be a leg of the switchover batch"
        );
        assertFalse(
            _has(targets, payloads, address(d.vault), d.vault.pause.selector),
            "and neither must the vault's"
        );

        // The pause list is the two legs and nothing else, and both are `pause`.
        (address[] memory pt,, bytes[] memory pp) = _phase4PauseCalls(d);
        assertEq(pt.length, 2, "the pause operation is exactly the two doors the protocol has");
        assertTrue(_has(pt, pp, address(d.credit), CreditManager.pause.selector), "borrowing");
        assertTrue(_has(pt, pp, address(d.vault), d.vault.pause.selector), "and new collateral");

        // **The unpauses stay, and they are the execution-time half of the precondition.** OZ's
        // `_unpause()` carries `whenPaused`, so a batch fired against a protocol that is not paused
        // reverts `ExpectedPause` on these legs and, `executeBatch` being all-or-nothing, undoes
        // the whole switchover. Measured directly in
        // `test_deploy_phase4BatchRefusesIfThePauseLapsedDuringTheWindow`.
        assertTrue(_has(targets, payloads, address(d.vault), d.vault.unpause.selector), "vault reopens");
        assertTrue(_has(targets, payloads, address(d.credit), CreditManager.unpause.selector), "so does credit");

        assertLt(
            fundingLeg,
            _indexOf(targets, payloads, address(d.credit), CreditManager.setLenderPool.selector),
            "the pool funds the book before it is named as the sink"
        );

        // **The settle leg is unconditional now - round 21, finding 3.** It used to be written in
        // only when `pendingPrincipal() != 0` at generation time, and `settlePrincipal` is
        // permissionless, so a stranger chose the batch's shape for 42,744 gas. `_phase4Calls` is
        // `pure` now, which is the compiler making that class of defect unreachable, and this book
        // is flat - so the leg being present here is the property, not an accident of fixture state.
        assertEq(d.credit.pendingPrincipal(), 0, "premise: a flat book, where the old list omitted the leg");
        assertLt(
            _indexOf(targets, payloads, address(d.credit), CreditManager.settlePrincipal.selector),
            fundingLeg,
            "the principal goes home before the pointer that would strand it moves"
        );

        // And the two lists, executed in order, are the switchover: same post-condition, same end
        // state `_wirePhase4` reaches. If somebody adds a leg to one and not the other, this stops.
        (address[] memory both,, bytes[] memory bothPayloads) = _pauseThenSwitchover(d);
        for (uint256 i; i < both.length; ++i) {
            (bool ok,) = both[i].call(bothPayloads[i]);
            assertTrue(ok, "a leg of the switchover reverted");
        }
        _assertPhase4Wiring(d, _paramsOwnedHere());
    }

    // ── audit round 21, findings 2 and 3: the precondition window ────────────

    /// @notice **THE FIX for finding 2, measured against the hazard it closes.** One micro-USDC of
    ///         debt used to kill a queued switchover, because the pause that would have stopped the
    ///         borrow was leg 1 of the very batch being blocked. With the pause performed as its
    ///         own earlier operation the identical borrow is refused at the door.
    /// @dev The hazard, measured at `868edb4`: a stranger deposits collateral through the ordinary
    ///      front door, borrows **1** - 0.000001 USDC - during the forty-eight hour maturity, and
    ///      `executeBatch` reverts `DebtOutstanding(1)` for good, staying `Ready` indefinitely
    ///      because `TimelockController` has no grace period.
    ///
    ///      Here the same actor makes the same call in the same window and gets `EnforcedPause`.
    ///      The refusal is attributable because everything else is identical: same fixture, same
    ///      collateral, same amount, same block. What changed is *when* the pause happened.
    ///
    ///      The borrow is retried after the switchover so this cannot pass against a protocol left
    ///      shut, which is the failure mode the pause legs would otherwise introduce.
    function test_deploy_phase4TheMicroUsdcGriefIsRefusedAtTheDoor() public {
        (Deployed memory d,) = _liveProtocol();
        _fundALender(d);
        TimelockController timelock = _timelock();
        _governanceTakesOver(d, address(timelock));

        address griefer = makeAddr("microUsdcGriefer");
        bond.mint(griefer, 20);
        vm.startPrank(griefer);
        bond.setApprovalForAll(address(d.vault), true);
        d.vault.depositBonds(20);
        vm.stopPrank();

        _pauseForSwitchover(d, timelock);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4Calls(d);
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        // The attack, unchanged. It no longer reaches the book.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(griefer);
        d.credit.borrow(1);
        assertEq(d.credit.totalDebt(), 0, "MEASURED: the window cannot be poisoned");

        vm.prank(outsider);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        this.exposedAssertPhase4Wiring(d, _paramsOwnedBy(address(timelock)));
        assertEq(d.credit.liquiditySource(), address(d.pool), "the switchover completes");

        // And the protocol comes back open, so the same borrow now works. A test that stopped at
        // the revert would pass just as happily against a switchover that never unpauses.
        vm.prank(griefer);
        d.credit.borrow(1);
        assertEq(d.credit.totalDebt(), 1, "and the door reopens on the other side");
    }

    /// @notice **The residual finding 2 leaves, and what it costs to clear.** The pause stops NEW
    ///         debt; it cannot clear debt already standing. A position taken *before* step one and
    ///         never repaid holds the switchover hostage, because `setLiquiditySource` wants
    ///         `totalDebt == 0` and nothing forces a healthy borrower to repay.
    /// @dev Not a defect this stream could close, and not one that needed new code either: `repayFor`
    ///      is permissionless and unpaused, so anybody - governance, a keeper, a passer-by - clears
    ///      a hostage position by paying its face value. MEASURED here at the same 1 micro-USDC the
    ///      griefer risked, which is the whole point: the attack's cost and the defence's cost are
    ///      the same number, so a griefer buys nothing but the gas.
    ///
    ///      Written down rather than left implicit because the honest statement of the residual is
    ///      "a LARGE hostage position is expensive to clear", and that case is indistinguishable
    ///      from an ordinary borrower who has not repaid yet. Waiting is the answer there, and the
    ///      pause is what makes waiting terminate.
    function test_deploy_phase4AHostagePositionTakenBeforeThePauseIsClearedByAnyone() public {
        (Deployed memory d,) = _liveProtocol();
        _fundALender(d);
        TimelockController timelock = _timelock();

        address griefer = makeAddr("hostageGriefer");
        bond.mint(griefer, 20);
        vm.startPrank(griefer);
        bond.setApprovalForAll(address(d.vault), true);
        d.vault.depositBonds(20);
        d.credit.borrow(1);
        vm.stopPrank();

        _governanceTakesOver(d, address(timelock));
        _pauseForSwitchover(d, timelock);
        assertEq(d.credit.totalDebt(), 1, "the hostage survives the pause, by design");

        // The batch would still refuse, so the operator must not queue it - and `queue()` says so
        // rather than letting them find out in forty-eight hours.
        ExposedWirePhase4 script = new ExposedWirePhase4();
        vm.expectRevert(abi.encodeWithSelector(WirePhase4.SwitchoverBookNotFlat.selector, uint256(1)));
        script.exposedQueue(d, timelock, _paramsOwnedBy(address(timelock)));

        // Anyone clears it. No role, no delay, and the same 1 micro-USDC it cost to create.
        address passerBy = makeAddr("passerBy");
        usdc.mint(passerBy, 1);
        vm.startPrank(passerBy);
        usdc.approve(address(d.credit), 1);
        d.credit.repayFor(griefer, 1);
        vm.stopPrank();
        assertEq(d.credit.totalDebt(), 0, "MEASURED: a hostage costs its face value to release");

        (address[] memory t, uint256[] memory v, bytes[] memory p) = _phase4Calls(d);
        vm.prank(proposer);
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.prank(outsider);
        timelock.executeBatch(t, v, p, bytes32(0), bytes32(0));
        assertEq(d.credit.liquiditySource(), address(d.pool), "and the switchover then completes");
    }

    /// @notice The execution-time half of the same precondition, and it needed no new leg.
    /// @dev OZ's `_unpause()` carries `whenPaused`. The switchover batch still ends with both
    ///      `unpause` legs, so a batch that fires against a protocol which is **not** paused
    ///      reverts `ExpectedPause` on them - and `executeBatch` bubbles any leg's revert, so the
    ///      whole switchover undoes itself rather than half-landing.
    ///
    ///      This is why `_queue`'s `SwitchoverNotPaused` being a generation-time read is adequate
    ///      rather than decorative: the state it checks is re-checked on chain when the operation
    ///      fires. Modelled here by governance unpausing during the window, which is the only way
    ///      it can lapse - `unpause` is `onlyOwner`, so no stranger has this move.
    function test_deploy_phase4BatchRefusesIfThePauseLapsedDuringTheWindow() public {
        (Deployed memory d,) = _liveProtocol();
        _fundALender(d);
        TimelockController timelock = _timelock();
        _governanceTakesOver(d, address(timelock));

        _pauseForSwitchover(d, timelock);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4Calls(d);
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        vm.prank(address(timelock));
        d.credit.unpause();
        vm.prank(address(timelock));
        d.vault.unpause();

        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(outsider);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(d.credit.liquiditySource(), address(d.liquidity), "all or nothing: nothing moved");
        assertEq(d.credit.lenderPool(), address(0), "not even the leg before the failing one");
    }

    /// @notice `queue()` refuses to open a window nothing is guarding, and refuses to schedule a
    ///         switchover that is already known to be unsatisfiable.
    /// @dev Both refusals cost the operator nothing; learning the same two facts from
    ///      `executeBatch` costs another forty-eight hours each time. The second one is only a
    ///      *durable* guarantee because the first one holds: with `borrow` shut, `totalDebt` has no
    ///      source, so zero at generation time is still zero when the batch fires.
    function test_deploy_phase4QueueRefusesAnUnguardedWindowAndALiveBook() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _fundALender(d);

        // A local timelock rather than `_timelock()`, because `_queue` only broadcasts when
        // `msg.sender` holds `PROPOSER_ROLE` - and reached from a test `msg.sender` is this
        // contract. Without the role the accepted call would print calldata and schedule nothing,
        // so the last third of this test would assert the absence of a revert and call it a pass.
        // `DEFAULT_SENDER` holds it too, because everything inside `vm.startBroadcast()` originates
        // there while `msg.sender` at the `hasRole` branch is this contract - the same two-address
        // artefact `test_wirePhase4_queueSchedulesTheWholeSwitchoverAsOneOperation` explains.
        address[] memory proposers = new address[](3);
        proposers[0] = proposer;
        proposers[1] = address(this);
        proposers[2] = DEFAULT_SENDER;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock =
            new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
        ExposedWirePhase4 script = new ExposedWirePhase4();

        vm.prank(borrower);
        d.credit.borrow(LOAN);
        _governanceTakesOver(d, address(timelock));

        // Unpaused: refused on the window, before it even looks at the book.
        vm.expectRevert(abi.encodeWithSelector(WirePhase4.SwitchoverNotPaused.selector, false, false));
        script.exposedQueue(d, timelock, _paramsOwnedBy(address(timelock)));

        // Paused, but the book is live: refused on the debt, by its actual size.
        _pauseForSwitchover(d, timelock);
        vm.expectRevert(abi.encodeWithSelector(WirePhase4.SwitchoverBookNotFlat.selector, LOAN));
        script.exposedQueue(d, timelock, _paramsOwnedBy(address(timelock)));

        // Wound down - which the pause is what makes possible without a new borrow arriving - and
        // the same call is accepted. Without this half the two reverts above would be satisfied by
        // a `queue()` that refuses everything.
        vm.startPrank(borrower);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        script.exposedQueue(d, timelock, _paramsOwnedBy(address(timelock)));

        (address[] memory t, uint256[] memory v, bytes[] memory p) = _phase4Calls(d);
        assertTrue(
            timelock.isOperationPending(timelock.hashOperationBatch(t, v, p, bytes32(0), bytes32(0))),
            "the switchover is queued once its preconditions actually hold"
        );
    }

    /// @notice Step one must land on a book that still has users, because that is the whole reason
    ///         there is a step one.
    /// @dev The bug this stops: `executeQueuedPause` sharing `queue()`'s full precondition. The two
    ///      look like the same check and are not - the pause is what makes a wind-down possible, so
    ///      demanding a flat book to *apply* it would abort step one on every protocol that has
    ///      borrowers, which is every protocol this step exists for. Found by reading, not by a
    ///      failing test, so here is the failing test.
    function test_deploy_phase4PauseStepLandsOnALiveBookAndOnlyQueueDemandsAFlatOne() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _fundALender(d);

        address[] memory proposers = new address[](3);
        proposers[0] = proposer;
        proposers[1] = address(this);
        proposers[2] = DEFAULT_SENDER;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock =
            new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
        ExposedWirePhase4 script = new ExposedWirePhase4();

        vm.prank(borrower);
        d.credit.borrow(LOAN);
        _governanceTakesOver(d, address(timelock));
        assertEq(d.credit.totalDebt(), LOAN, "premise: an ordinary protocol, with a user in it");

        script.exposedQueuePause(d, timelock, bytes32(0));
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.exposedExecuteQueuedPause(d, timelock, bytes32(0));

        assertTrue(d.credit.paused(), "step one lands on a live book");
        assertTrue(d.vault.paused());
        assertEq(d.credit.totalDebt(), LOAN, "and does not require the book to be flat first");

        // `repay` is deliberately not `whenNotPaused`, so the wind-down the pause exists to protect
        // is still open. That is the sequence: shut the door, then let the room empty.
        vm.startPrank(borrower);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        script.exposedQueue(d, timelock, _paramsOwnedBy(address(timelock)));
    }

    /// @notice **THE FIX for finding 3.** The batch's composition no longer depends on state a
    ///         stranger can move, so the free `settlePrincipal` front-run changes nothing.
    /// @dev The hazard, measured at `868edb4`: eight legs queued against a book owed principal, a
    ///      griefer spent **42,744 gas** on the permissionless `settlePrincipal`, and both routes
    ///      died - the queued array reverted `NothingToSettle` on its own settle leg, and
    ///      `executeQueued()`'s re-derivation produced a seven-leg array whose id nobody had
    ///      scheduled.
    ///
    ///      The root cause was the revert, not the branch: `settlePrincipal` returning early at
    ///      zero is what lets the leg be unconditional. This asserts the property directly - the
    ///      id computed against a book owed principal equals the id computed after a stranger has
    ///      zeroed it - and then makes the same attacker call in the same window and executes.
    function test_deploy_phase4BatchCompositionSurvivesTheFreeSettleFrontRun() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _fundALender(d);
        TimelockController timelock = _timelock();

        // A book that has been used and repaid: the treasury is owed its float back, which is the
        // state that used to put an eighth leg in the list.
        vm.startPrank(borrower);
        d.credit.borrow(LOAN);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        assertEq(d.credit.pendingPrincipal(), LOAN, "premise: the counter the composition used to read");

        _governanceTakesOver(d, address(timelock));
        _pauseForSwitchover(d, timelock);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase4Calls(d);
        assertEq(targets.length, 6, "the leg count is a constant now");
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(0));

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        // The attack, unchanged and still free.
        address griefer = makeAddr("settleGriefer");
        uint256 gasBefore = gasleft();
        vm.prank(griefer);
        d.credit.settlePrincipal();
        emit log_named_uint("MEASURED attacker gas, unchanged", gasBefore - gasleft());
        assertEq(d.credit.pendingPrincipal(), 0, "the counter did move: the attack itself still works");

        // What it no longer buys: a different operation.
        (address[] memory nt, uint256[] memory nv, bytes[] memory np) = _phase4Calls(d);
        assertEq(nt.length, 6, "re-derivation after the attack is the same length");
        assertEq(
            timelock.hashOperationBatch(nt, nv, np, bytes32(0), bytes32(0)),
            id,
            "MEASURED: and the same operation id, which is what executeQueued() re-derives"
        );

        // And the queued array still executes, on its own now-empty settle leg.
        vm.prank(outsider);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        this.exposedAssertPhase4Wiring(d, _paramsOwnedBy(address(timelock)));
        assertEq(d.credit.liquiditySource(), address(d.pool), "the switchover completes through the front-run");
    }

    /// @notice The same property stated without an attacker: the list is identical whether or not
    ///         the book is owed principal.
    /// @dev The cheapest possible regression test for "do not reintroduce a conditional leg". A
    ///      `view` on `_phase4Calls` would be the tell; this is the assertion that goes red.
    function test_deploy_phase4CallListDoesNotDependOnTheBook() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _fundALender(d);

        (address[] memory flat,, bytes[] memory flatPayloads) = _phase4Calls(d);
        assertEq(d.credit.pendingPrincipal(), 0, "premise: nothing owed home");

        vm.startPrank(borrower);
        d.credit.borrow(LOAN);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        assertGt(d.credit.pendingPrincipal(), 0, "premise: now something is");

        (address[] memory owed,, bytes[] memory owedPayloads) = _phase4Calls(d);
        assertEq(owed.length, flat.length, "the same number of legs");
        for (uint256 i; i < owed.length; ++i) {
            assertEq(owed[i], flat[i], "the same targets");
            assertEq(keccak256(owedPayloads[i]), keccak256(flatPayloads[i]), "the same payloads");
        }
    }

    /// @notice The sanctioned recovery from a blocked switchover, MEASURED - because round 21
    ///         recorded that there was not one.
    /// @dev Round 21 wrote that `SALT == bytes32(0)` makes a blocked batch unrecoverable, since the
    ///      identical call set regenerates the identical id. Checked against this repo's pinned
    ///      OZ v5.6.1 that is **false**: `cancel` does `delete _timestamps[id]`, returning the id to
    ///      `Unset`, and `_schedule` only rejects `isOperation(id)`. `cancel` carries no delay of
    ///      its own and `TimelockController`'s constructor grants `CANCELLER_ROLE` to every
    ///      proposer, so this is one immediate transaction from the key that queued.
    ///
    ///      Kept even though finding 2's fix means a correctly-run switchover cannot be blocked
    ///      this way: the recovery is what an operator needs when something *else* goes wrong, and
    ///      it is the reason no per-attempt salt was added. A cost of forty-eight hours is not the
    ///      same as permanence, and the docstrings say so on the strength of this test.
    function test_deploy_phase4ABlockedBatchIsRecoveredByCancelThenReschedule() public {
        (Deployed memory d, address borrower) = _liveProtocol();
        _fundALender(d);
        TimelockController timelock = _timelock();
        _governanceTakesOver(d, address(timelock));

        // Queued the wrong way round on purpose: no pause, so the window is open. This is the
        // operator mistake `queue()` now refuses, staged directly against the timelock.
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _phase4Calls(d);
        bytes32 id = timelock.hashOperationBatch(t, v, p, bytes32(0), bytes32(0));
        vm.prank(proposer);
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        vm.prank(borrower);
        d.credit.borrow(1);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.DebtOutstanding.selector, uint256(1)));
        vm.prank(outsider);
        timelock.executeBatch(t, v, p, bytes32(0), bytes32(0));

        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer), "MEASURED: the proposer IS a canceller");
        vm.prank(proposer);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id), "MEASURED: cancel returns a salt-free id to Unset");

        // Done properly the second time: wind the book down, shut the door, re-schedule the
        // identical call set under the identical salt.
        vm.startPrank(borrower);
        usdc.approve(address(d.credit), 1);
        d.credit.repay(1);
        vm.stopPrank();
        _pauseForSwitchover(d, timelock);

        (address[] memory t2, uint256[] memory v2, bytes[] memory p2) = _phase4Calls(d);
        assertEq(timelock.hashOperationBatch(t2, v2, p2, bytes32(0), bytes32(0)), id, "the same id, reused");
        vm.prank(proposer);
        timelock.scheduleBatch(t2, v2, p2, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.prank(outsider);
        timelock.executeBatch(t2, v2, p2, bytes32(0), bytes32(0));

        assertEq(d.credit.liquiditySource(), address(d.pool), "MEASURED: recovered, for one more delay");
    }

    /// @notice Why the pause operation takes a salt when the switchover does not: a **Done** id is
    ///         burned forever, and a pause is legitimately repeatable.
    /// @dev `_afterCall` writes `_timestamps[id] = 1`. MEASURED: `cancel` refuses a Done id and
    ///      `scheduleBatch` refuses it, so unlike the blocked case above there is no way back. The
    ///      switchover runs once per deployment and can afford a fixed salt; a switchover attempt
    ///      abandoned and retried later has to pause again, and that second pause is the identical
    ///      two legs. `RECOUP_SWITCHOVER_ATTEMPT` is the discriminator.
    function test_deploy_phase4APauseOperationNeedsASaltToRunASecondTime() public {
        (Deployed memory d,) = _liveProtocol();
        TimelockController timelock = _timelock();
        _governanceTakesOver(d, address(timelock));

        (address[] memory t, uint256[] memory v, bytes[] memory p) = _phase4PauseCalls(d);
        bytes32 firstId = timelock.hashOperationBatch(t, v, p, bytes32(0), bytes32(0));
        _pauseForSwitchover(d, timelock);
        assertTrue(timelock.isOperationDone(firstId), "premise: attempt one is Done");
        assertEq(timelock.getTimestamp(firstId), 1, "MEASURED: _afterCall writes 1, not a timestamp");

        // The attempt is abandoned and the protocol reopened.
        vm.prank(address(timelock));
        d.credit.unpause();
        vm.prank(address(timelock));
        d.vault.unpause();

        // Attempt two, same salt: refused, and cancel cannot free it either.
        vm.expectRevert();
        vm.prank(proposer);
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.expectRevert();
        vm.prank(proposer);
        timelock.cancel(firstId);

        // Attempt two with its own salt: accepted, and it is a different operation.
        bytes32 attemptTwo = bytes32(uint256(2));
        assertTrue(
            timelock.hashOperationBatch(t, v, p, bytes32(0), attemptTwo) != firstId, "a salt is a new id"
        );
        vm.prank(proposer);
        timelock.scheduleBatch(t, v, p, bytes32(0), attemptTwo, Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.prank(outsider);
        timelock.executeBatch(t, v, p, bytes32(0), attemptTwo);
        assertTrue(d.credit.paused(), "the second pause landed");
    }

    /// @dev The revert `TimelockController` raises for an id nobody scheduled. The second field is
    ///      the *expected* state bitmap, and `execute` expects `Ready` - `1 << uint8(Ready)` with
    ///      `Ready == 2`, so 4. Derived here rather than pasted as a hex blob so the assertion says
    ///      what it means.
    function _notScheduled(bytes32 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1 << 2))
        );
    }

    /// @dev The full switchover as one flat list - the pause operation's legs followed by the
    ///      batch's - for the tests that model an operator transcribing every leg by hand.
    ///      Round 21 split the two lists in the script because they are two *operations* now; a
    ///      hand-transcribing operator still sees one sequence, and that is what this rebuilds.
    function _pauseThenSwitchover(Deployed memory d)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        (address[] memory pt, uint256[] memory pv, bytes[] memory pp) = _phase4PauseCalls(d);
        (address[] memory st, uint256[] memory sv, bytes[] memory sp) = _phase4Calls(d);

        targets = new address[](pt.length + st.length);
        values = new uint256[](targets.length);
        payloads = new bytes[](targets.length);
        for (uint256 i; i < pt.length; ++i) {
            (targets[i], values[i], payloads[i]) = (pt[i], pv[i], pp[i]);
        }
        for (uint256 i; i < st.length; ++i) {
            (targets[pt.length + i], values[pt.length + i], payloads[pt.length + i]) = (st[i], sv[i], sp[i]);
        }
    }

    /// @dev Find a leg by target and selector rather than by index. A test that hardcoded "leg 3"
    ///      would be the hand-maintained count this round is removing, one layer up.
    function _indexOf(address[] memory targets, bytes[] memory payloads, address target, bytes4 selector)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] != target) continue;
            if (bytes4(payloads[i]) == selector) return i;
        }
        revert("no such leg in _phase4Calls");
    }

    /// @dev The same lookup as a predicate, so a test can assert a leg is ABSENT. `_indexOf`
    ///      reverts on a miss, which is right when the leg must exist and useless when the property
    ///      under test is that it must not.
    function _has(address[] memory targets, bytes[] memory payloads, address target, bytes4 selector)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == target && bytes4(payloads[i]) == selector) return true;
        }
        return false;
    }

    /// @dev Copies before swapping. A memory array is a reference, so swapping in place would
    ///      reorder the caller's own arrays and the `executeBatch` further down the test would
    ///      then be executing a batch nobody scheduled - a test failing for the right reason by
    ///      accident, which is the same thing as passing for the wrong one.
    function _swapped(address[] memory t, uint256[] memory v, bytes[] memory p, uint256 a, uint256 b)
        internal
        pure
        returns (address[] memory nt, uint256[] memory nv, bytes[] memory np)
    {
        (nt, nv, np) = _prefix(t, v, p, t.length);
        (nt[a], nt[b]) = (nt[b], nt[a]);
        (nv[a], nv[b]) = (nv[b], nv[a]);
        (np[a], np[b]) = (np[b], np[a]);
    }

    function _prefix(address[] memory t, uint256[] memory v, bytes[] memory p, uint256 n)
        internal
        pure
        returns (address[] memory nt, uint256[] memory nv, bytes[] memory np)
    {
        nt = new address[](n);
        nv = new uint256[](n);
        np = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (nt[i], nv[i], np[i]) = (t[i], v[i], p[i]);
        }
    }

    // ── the yieldRecipient footgun ───────────────────────────────────────────

    /// @dev The regression that motivated this work: the old script passed `admin`
    ///      (i.e. msg.sender) as BOTH initialOwner and yieldRecipient, which on any
    ///      real chain routes every harvest and every unstake sweep to the key that
    ///      signed the deploy.
    function test_yieldRecipientIsNotTheDeployerOrOwner() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        // The sink is the harvester, which then splits to the treasury via its
        // protocol-fee leg. What still matters here is that it is never an address
        // that could quietly pocket the whole epoch.
        assertEq(d.adapter.yieldRecipient(), address(d.harvester));
        assertTrue(d.adapter.yieldRecipient() != treasury, "not straight to the treasury");
        assertTrue(d.adapter.yieldRecipient() != address(this));
        assertTrue(d.adapter.yieldRecipient() != owner);
    }

    /// @notice **Go-live item G4 wired by the script, on the branch `_params()` does not take.**
    /// @dev Every other test in this file deploys with `guardian: address(0)`, which is the
    ///      shipped default and the wrong thing to leave as the only coverage: zero and non-zero
    ///      take **different branches** in both `_validateParams` and `_assertWiring`, so the
    ///      filled path would otherwise have no test standing under it at all. That is the
    ///      unreached-guard shape this repository keeps catching, and it would have been created
    ///      by the same commit that added the guard.
    ///
    ///      Both halves are asserted, because a guardian on one contract and not the other is a
    ///      half-installed role and nothing else in the graph would notice.
    function test_deploy_theGuardianIsWiredOnBothContractsWhenOneIsNamed() public {
        address guardian = makeAddr("guardian");
        GovParams memory p = _params();
        p.guardian = guardian;

        Deployed memory d = _deployProtocol(_externals(), p, address(this));
        _assertWiring(d, p);

        assertEq(d.vault.guardian(), guardian, "the vault half is wired");
        assertEq(d.credit.guardian(), guardian, "and so is the manager half");
        // The pairing the contracts cannot check for themselves: `setGuardian` runs during `_wire`,
        // when the owner is still the deployer, so only a post-handover read sees the final pair.
        assertTrue(d.vault.guardian() != d.vault.owner(), "and it is a genuinely second key");
    }

    /// @notice The third holder of the same role, wired on the same branch.
    /// @dev **A separate test rather than an extra assertion in the one above, deliberately.** That
    ///      test is cited by name in the go-live checklist, and its name says "both contracts",
    ///      which was true when it was written and stopped being true the day the lender pool took
    ///      the role. Renaming it would break the citation; widening it silently would leave a
    ///      cited name describing something else. So the pool half is asserted here, under a name
    ///      that says what it covers.
    ///
    ///      `_assertWiring` is called first, because the pool leg it now carries is the thing most
    ///      likely to be forgotten in `_wire` - and an assertion helper that silently checks two of
    ///      three contracts is the half-installed shape this file already refuses elsewhere.
    function test_deploy_theLenderPoolGuardianIsWiredOnTheSameBranch() public {
        address guardian = makeAddr("guardian");
        GovParams memory p = _params();
        p.guardian = guardian;

        Deployed memory d = _deployProtocol(_externals(), p, address(this));
        _assertWiring(d, p);

        assertEq(d.pool.guardian(), guardian, "the pool half of the guardian role is not wired");
        assertTrue(d.pool.guardian() != d.pool.owner(), "and it is a genuinely second key");
        // 🟥 **This line asserted the OPPOSITE until round 40: "a deployment must not ship shut
        // to lenders".** It was written as a guard against wiring the pool's guardian by
        // accidentally pausing it, and what it actually pinned was round 36 finding D7 - a pool
        // open to public USDC from the block it is deployed, wired into nothing that charges it.
        // The capture is executed in `test/R40D7Capture.t.sol`; the profit is the entire parked
        // lender backlog. Shipping shut IS the fix, so this asserts it.
        assertTrue(d.pool.paused(), "a deployment must ship the pool shut - round 40, D7");
    }

    /// @dev The refusal, on the same branch. Caught before a broadcast rather than at the third
    ///      wiring call, which is the reason `_validateParams` mirrors a check the contracts also
    ///      make - and it is the check neither contract can make from inside `_wire`, because the
    ///      collapse only happens at `_handOver`.
    /// @notice **The operator rules run on the DEPLOY path, not only on the environment read.**
    /// @dev Audit round 30, follow-up item 8. `_validateParams` used to be reachable only through
    ///      `_resolveParams` and through `exposedValidateParams` in this file, so every deployment
    ///      performed anywhere in this repository went through a path that validated nothing. The
    ///      three script targets did resolve first, so the broadcast path was covered; what was
    ///      not covered is that the rules are a property of a deployment rather than of a read.
    ///
    ///      **Off the local chain deliberately, and that is the whole reason this test exists.**
    ///      `setUp` puts every other test in this file on chain 31337, where `_validateParams`
    ///      takes its local early-return after two rules - so a test on the local chain would
    ///      exercise the new call and reach eight of the ten rules not at all. MEASURED when the
    ///      call was added: **zero fixtures in this file broke**, against a prediction of eleven,
    ///      for exactly that reason. A change whose cost is zero because nothing reaches it is not
    ///      a closed finding, so the reach is asserted here rather than assumed.
    ///
    ///      The control is the first call: the same fixture, the same chain, deploys. So the
    ///      refusal below is caused by the one field that moved.
    function test_deploy_theOperatorRulesRunOnTheDeployPathOffTheLocalChain() public {
        vm.chainId(8453);
        GovParams memory p = _params();

        // Control: nine contracts deployed, wired and handed over, off the local chain.
        this.exposedDeployProtocol(_externals(), p, address(this));

        // **A rule NO contract mirrors, which is why this arm is the one that matters.** Nothing in
        // `src/` refuses a yield recipient that is the deploying key, so before this change the
        // whole nine-contract set deployed, wired, handed over and passed `_assertWiring` with the
        // operator's own address standing as the adapter's live sink for the span between the
        // adapter's constructor and `_wire`'s last call - forty transactions of it on the
        // 2026-08-19 broadcast. The falsifier for this line is that it does not revert at all.
        p.yieldRecipient = address(this);
        vm.expectRevert(
            abi.encodeWithSelector(YieldRecipientCollision.selector, address(this), "deployer")
        );
        this.exposedDeployProtocol(_externals(), p, address(this));

        // And a rule the contracts DO mirror, for the contrast. MEASURED with the deploy-path call
        // removed: the same parameters got as far as `new NAVOracle(...)` and died on the oracle's
        // own `KeysMustDiffer()` after 39,762,658 gas of contract creations, rather than on this
        // script's `NavKeysMustDiffer()` before the first one.
        p = _params();
        p.navConfirmer = p.keeper;
        vm.expectRevert(NavKeysMustDiffer.selector);
        this.exposedDeployProtocol(_externals(), p, address(this));
    }

    function test_deploy_aGuardianEqualToTheIncomingOwnerIsRefused() public {
        GovParams memory p = _params();
        p.guardian = p.owner;

        // Through the external wrapper, for the reason its own comment gives: `expectRevert` only
        // catches a revert one call depth below the cheatcode, and `_validateParams` is internal.
        vm.expectRevert(GuardianMustDifferFromOwner.selector);
        this.exposedValidateParams(p, address(this));
    }

    /// @dev Even the local default must model the right shape, or the footgun just
    ///      moves to whoever first runs the script against a real chain.
    ///
    ///      The operator variables have to be neutralised for the duration, because
    ///      forge auto-loads `contracts/.env` and a real deployment fills in exactly
    ///      these five. That means the local-default branch is unreachable on the one
    ///      machine where a deploy actually gets run, and this test asserted a value it
    ///      could not see - it failed the moment the Base Sepolia parameters landed in
    ///      `.env`, while CI stayed green because CI has no `.env`. Same mechanism the
    ///      confirmation-phrase note below describes, a different variable.
    ///
    ///      **Neutralised on THIS contract rather than in the process environment, and nothing to
    ///      restore.** It used to `vm.setEnv` all four to zero and set them back four lines later,
    ///      which put a writer of the same four keys `_installParams` writes into a suite that runs
    ///      its functions in parallel. `DeployTest` is itself an `EnvOverridable`, so the four
    ///      overrides live in this contract's storage, which forge isolates per test function.
    ///      `RECOUP_OWNER` is deliberately left alone, and the reason changed with the fix that
    ///      made `OwnerRequired` reachable. It used to default to the deployer on EVERY chain, so
    ///      zeroing it here would have proved nothing about the local branch. It now defaults to
    ///      zero and takes the deployer only inside `if (_isLocal())`, which
    ///      `test_R36_recoupOwnerNoLongerDefaultsToTheBroadcastingKey` pins on both chain ids
    ///      rather than folding a second subject into this test.
    function test_localDefaultsDoNotPointAtTheDeployer() public {
        string[4] memory keys;
        keys[0] = "RECOUP_YIELD_RECIPIENT";
        keys[1] = "RECOUP_KEEPER";
        keys[2] = "RECOUP_NAV_CONFIRMER";
        keys[3] = "RECOUP_PROTOCOL_FEE_WALLET";

        for (uint256 i = 0; i < keys.length; i++) {
            this.setEnvAddress(keys[i], address(0));
        }

        GovParams memory p = _resolveParams(address(this));

        assertTrue(p.yieldRecipient != address(this));
        assertTrue(p.keeper != address(this));
        assertEq(p.yieldRecipient, LOCAL_TREASURY);
        assertEq(p.keeper, LOCAL_KEEPER);
        assertEq(p.navConfirmer, LOCAL_NAV_CONFIRMER);
        assertEq(p.protocolFeeWallet, LOCAL_TREASURY);
    }

    /// @dev Audit finding #1 as an assertion: the vault has no USDC egress, so yield
    ///      routed there is stranded permanently.
    function test_assertWiringRejectsYieldRecipientOnTheVault() public {
        GovParams memory p = _params();
        Deployed memory d = _deployProtocol(_externals(), p, address(this));

        vm.prank(owner);
        d.adapter.setYieldRecipient(address(d.vault));

        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.YieldRecipientCollision.selector, address(d.vault), "vault")
        );
        this.exposedAssertWiring(d, p);
    }

    /// @notice The four pointers that used to be checked for non-zero rather than for the right
    ///         address, each proved to bite by pointing it somewhere else that is not zero.
    /// @dev **Audit round 15, and the shape is the whole finding.** A non-zero check passes on
    ///      every wrong address as readily as on the right one, so the only test that can tell the
    ///      two versions apart is one where the pointer is set to a plausible live wrong thing.
    ///      All four cases below passed before the change.
    ///
    ///      `harvester.custodyAdapter` gets a second *real* adapter rather than an arbitrary
    ///      address, because that is the realistic mistake: two deployments in flight and the wrong
    ///      one wired. It is also the expensive one. The deployment passes, and then `harvest()`
    ///      declines every epoch forever with `EpochDeclinedUncorroborated`, because
    ///      `lastCorroboratedYield` is seeded from a counter on an adapter nothing else moves -
    ///      repairable only by an owner who is a timelock by then.
    function test_assertWiringRejectsPointersThatAreSetButWrong() public {
        GovParams memory p = _params();

        Deployed memory d = _deployProtocol(_externals(), p, address(this));
        DirectCallAdapter other = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(d.vault), owner, p.yieldRecipient
        );
        vm.prank(owner);
        d.harvester.setCustodyAdapter(ICustodyAdapter(address(other)));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "harvester.custodyAdapter"));
        this.exposedAssertWiring(d, p);

        d = _deployProtocol(_externals(), p, address(this));
        vm.prank(owner);
        d.harvester.setProtocolFeeWallet(makeAddr("someoneElsesFeeWallet"));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "harvester.protocolFeeWallet"));
        this.exposedAssertWiring(d, p);

        d = _deployProtocol(_externals(), p, address(this));
        vm.prank(owner);
        d.oracle.setKeeper(makeAddr("someoneElsesKeeper"));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "oracle.keeper"));
        this.exposedAssertWiring(d, p);

        d = _deployProtocol(_externals(), p, address(this));
        vm.prank(owner);
        d.oracle.setNavConfirmer(makeAddr("someoneElsesConfirmer"));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "oracle.navConfirmer"));
        this.exposedAssertWiring(d, p);
    }

    /// @notice **The `pool.paused` post-condition refuses its own absence** - round 36 finding D7,
    ///         closed in round 40.
    ///
    /// @dev 🟥 **This test exists because the assertion shipped with NO coverage and the audit
    ///      caught it.** Deleting `if (!d.pool.paused()) revert WiringIncomplete("pool.paused");`
    ///      from `_assertWiring` left the whole suite green at 253 passed, 0 failed. Every other
    ///      `WiringIncomplete` label in that function has a `vm.expectRevert` test here - sixteen
    ///      of them - and this one did not, so it was the one line a tidy-up could delete in
    ///      silence.
    ///
    ///      `test_R40_D7_theDeployPathNowShutsTheWindow` in `R40D7Capture.t.sol` is not this
    ///      test and does not replace it: it calls `exposedAssertWiring` only in the state where
    ///      the pool IS paused, so it proves the assertion TOLERATES the fix and never that it
    ///      REFUSES its absence. Those are different claims and only the second one keeps the
    ///      line alive.
    ///
    ///      The unpaused state reached here is the exact shipping state D7 found: a pool bearing
    ///      no credit risk, wired into nothing that pays or charges it, and open to public USDC.
    ///      `R40D7Capture.t.sol` follows the money from there.
    function test_assertWiringRejectsAnOpenLenderPool() public {
        GovParams memory p = _params();
        Deployed memory d = _deployProtocol(_externals(), p, address(this));

        // The control first, so a green arm cannot be a refusal of everything.
        this.exposedAssertWiring(d, p);
        assertTrue(d.pool.paused(), "the deploy path ships it shut");

        vm.prank(owner);
        d.pool.unpause();
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "pool.paused"));
        this.exposedAssertWiring(d, p);

        // And it recovers, so the label is about the state rather than about the deployment
        // having been touched at all.
        vm.prank(owner);
        d.pool.pause();
        this.exposedAssertWiring(d, p);
    }

    /// @notice The three nav-reader lines audit round 21 added, and they are not decoration.
    /// @dev **The contract-level guards added in the same change cannot see this state.** Those
    ///      anchor every consumer on `vault.navOracle()`, so a graph built entirely on one feed
    ///      satisfies all six of them - including one built on a feed that is not the oracle the
    ///      deployment record names and `_wire` set the keeper and `navConfirmer` on. The keeper
    ///      would then post NAV to a contract nothing reads, and every price in the protocol would
    ///      sit at its constructor value forever.
    ///
    ///      Modelled by moving the record rather than the graph, which is the same comparison from
    ///      the other side and needs no mutation of the script. Measured directly too, by building
    ///      the whole graph on a shadow oracle inside `_deployProtocol`: `WiringIncomplete
    ///      ("credit.navOracle")`, with every contract-level guard passing.
    function test_assertWiringRejectsAGraphOnAFeedTheRecordDoesNotName() public {
        GovParams memory p = _params();

        Deployed memory d = _deployProtocol(_externals(), p, address(this));

        // Fully wired and correctly owned, so no other clause in `_assertCoreGraph` has anything
        // to say about it. Without that, the substitution is caught by `oracle.keeper` two lines
        // further down and this test proves nothing about the lines it is named after - which is
        // exactly what the first version of it did.
        NAVOracle record = new NAVOracle(owner);
        vm.startPrank(owner);
        record.setKeeper(p.keeper);
        record.setNavConfirmer(p.navConfirmer);
        vm.stopPrank();
        d.oracle = record;

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "credit.navOracle"));
        this.exposedAssertWiring(d, p);
    }

    /// @notice The Phase-4 assertion checks ownership, and it did not until audit round 15.
    /// @dev It had dropped roughly eighteen assertions, **including every ownership check**, so
    ///      nothing after the switchover verified that the eight contracts belonged to anybody in
    ///      particular. `d.liquidity` is the one probed here: it has been missed twice before, and
    ///      it holds the lending float behind an uncapped `onlyOwner` withdraw.
    function test_assertPhase4WiringStillChecksOwnership() public {
        (Deployed memory d,) = _liveProtocol();
        this.exposedWirePhase4(d);
        this.exposedAssertPhase4Wiring(d, _paramsOwnedHere());

        // Only the liquidity source moves, so the revert has to name it rather than whichever
        // contract happens to be checked first. Probing the whole set at once would have passed on
        // the vault and told us nothing about the one that keeps being left out.
        address stranger = makeAddr("somebodyElse");
        d.liquidity.transferOwnership(stranger);

        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.OwnershipNotTransferred.selector, address(d.liquidity), stranger)
        );
        this.exposedAssertPhase4Wiring(d, _paramsOwnedHere());
    }

    // ── validation off the local chain ───────────────────────────────────────

    function test_validateRequiresATreasuryOffLocalChain() public {
        vm.chainId(8453);
        GovParams memory p = _params();
        p.yieldRecipient = address(0);

        vm.expectRevert(DeployBase.YieldRecipientRequired.selector);
        this.exposedValidateParams(p, address(this));
    }

    function test_validateRequiresAKeeperOffLocalChain() public {
        vm.chainId(8453);
        GovParams memory p = _params();
        p.keeper = address(0);

        vm.expectRevert(DeployBase.KeeperRequired.selector);
        this.exposedValidateParams(p, address(this));
    }

    function test_validateRejectsTreasuryEqualToDeployer() public {
        vm.chainId(8453);
        GovParams memory p = _params();
        p.yieldRecipient = address(this);

        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.YieldRecipientCollision.selector, address(this), "deployer")
        );
        this.exposedValidateParams(p, address(this));
    }

    function test_validateRejectsTreasuryEqualToOwner() public {
        vm.chainId(8453);
        GovParams memory p = _params();
        p.yieldRecipient = owner;

        vm.expectRevert(abi.encodeWithSelector(DeployBase.YieldRecipientCollision.selector, owner, "owner"));
        this.exposedValidateParams(p, address(this));
    }

    /// @notice **Round 29's open finding 1: the deployment that reports itself healthy with no
    ///         fast pause at all.**
    /// @dev `_wire` sets the guardian BEFORE `_handOver`, and `_assertWiring` asserts the deployed
    ///      value EQUALS the parameter - so zero equals zero and every post-condition passes over a
    ///      protocol whose only remaining route to a guardian is a `setGuardian` the new owner has
    ///      to schedule. Under the timelock that is 48 hours. Nothing was checking the PARAMETER,
    ///      which is the half no post-condition can reach, because a post-condition can only ask
    ///      whether the chain matches what it was told.
    /// @dev **Through `_validateNewDeployment`, not `_validateParams`, and the second assertion
    ///      below is the whole reason the rule moved.** The rule is about the act of MAKING a
    ///      deployment - `_wire` installs the guardian before `_handOver`, so after that moment the
    ///      only route to one is a timelocked `setGuardian`. Asking it of a deployment that already
    ///      exists refuses an operation nothing can then satisfy, which is what made the Phase-4
    ///      switchover unreachable. `_validateParams` therefore accepts these same parameters now,
    ///      and that acceptance is asserted rather than left implied.
    function test_validate_refusesAGuardianlessDeployUnderAContractOwner() public {
        TimelockController timelock = _timelock();
        vm.chainId(8453);
        GovParams memory p = _paramsOwnedBy(address(timelock));
        assertEq(p.guardian, address(0), "premise: the shipped default is an unfilled role");
        assertGt(address(timelock).code.length, 0, "premise: the incoming owner is a contract");

        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.GuardianRequiredForContractOwner.selector, address(timelock))
        );
        this.exposedValidateNewDeployment(p, address(this));

        // The address rules alone accept it, which is what lets an ALREADY deployed protocol be
        // switched over. The guardian is still constrained there, by `_assertCoreGraph` comparing
        // the deployed value against the parameter on all three contracts.
        this.exposedValidateParams(p, address(this));
    }

    /// @dev The control. Without it the refusal above would be satisfied by a rule that refuses
    ///      every contract owner, which would make G2 unshippable rather than guarded.
    function test_validate_acceptsAContractOwnerWhenAGuardianIsNamed() public {
        TimelockController timelock = _timelock();
        vm.chainId(8453);
        GovParams memory p = _paramsOwnedBy(address(timelock));
        p.guardian = makeAddr("guardian");

        this.exposedValidateNewDeployment(p, address(this));
    }

    /// @notice **The regression guard, and it is the point of the rule rather than an exception to
    ///         it.** An EOA owner can `pause()` in one transaction, so an unfilled guardian is
    ///         genuinely correct there - it is the shipped default, and `_resolveParams` refuses to
    ///         invent a local value for it on purpose.
    /// @dev Off the local chain, so this is the STRICT branch accepting it and not the early
    ///      return. Delete this test and the guard silently becomes "no contract may ever own
    ///      this protocol without a guardian named at deploy time", which is a different rule.
    function test_validate_stillAcceptsAGuardianlessDeployUnderAnEoaOwner() public {
        vm.chainId(8453);
        GovParams memory p = _params();
        assertEq(p.guardian, address(0), "premise: unfilled");
        assertEq(p.owner.code.length, 0, "premise: the owner is a key, not a contract");

        this.exposedValidateNewDeployment(p, address(this));
    }

    /// @notice The placement, pinned. **Not a coverage test - a test of WHERE the guard sits.**
    /// @dev Locally the owner is routinely a contract with no guardian: `_paramsOwnedHere()` makes
    ///      this test contract the owner in every Phase-4 fixture, and
    ///      `test_localDefaultsDoNotPointAtTheDeployer` resolves `RECOUP_OWNER` to `address(this)`
    ///      through `_resolveParams`, because it zeroes the other four keys and leaves that one
    ///      alone. MEASURED: a guard placed above `if (_isLocal()) return;` reverts that test in
    ///      CI, where there is no `contracts/.env` to supply an EOA. This test breaks first, and
    ///      under a name that says why.
    ///
    ///      **The rule has since moved down a level, to `_validateNewDeployment`, and this test
    ///      moved with it.** The local relaxation is the same relaxation and exists for the same
    ///      measured reason, so both calls are made here: the second is the one that pins the
    ///      placement now, and the first pins that the rule did not get left behind as well.
    function test_validate_theContractOwnerRuleIsRelaxedLocally() public view {
        GovParams memory p = _paramsOwnedBy(address(this));
        assertGt(address(this).code.length, 0, "premise: this fixture's owner is a contract");
        assertEq(p.guardian, address(0), "premise: with no guardian");

        this.exposedValidateParams(p, address(this));
        this.exposedValidateNewDeployment(p, address(this));
    }

    /// @dev Locally the same params are fine, so day-to-day work needs no setup.
    function test_validateIsPermissiveLocally() public view {
        GovParams memory p = _params();
        p.yieldRecipient = address(this);
        this.exposedValidateParams(p, address(this));
    }

    // ── stub hardening ───────────────────────────────────────────────────────

    /// @dev The three stubs are deployed by the script today, so they carry the same
    ///      authority footgun as the live contracts and get the same protection.
    function test_renounceOwnershipDisabledOnEveryDeployedContract() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        // **`d.liquidity` was once missing from this list, and it is the round-10 shape one door
        // along.** That finding was about `test_deployLeavesNothingOwnedByTheDeployer` above,
        // where the same contract was the eighth `Ownable` and the only one absent. The fix went
        // into that list and not into this one, so the contract holding the entire lending float
        // had its renounce guard shipped untested. Derived now, like the other three lists, so
        // that a hand-typed list cannot fall behind the struct here either.
        address[] memory ownables = _ownablesOf(d);
        vm.startPrank(owner);
        for (uint256 i; i < ownables.length; ++i) {
            vm.expectRevert();
            Ownable(ownables[i]).renounceOwnership();
        }
        vm.stopPrank();
    }

    // ── testnet target gates ─────────────────────────────────────────────────

    /// @dev `DeployLocal` and `DeployMainnet` have `run()` bodies that no test has ever
    ///      invoked, so their gates were only ever read rather than executed. The
    ///      testnet target does not inherit that: both of its refusals run here.
    ///
    ///      What is deliberately not tested is the success path. It needs a real
    ///      broadcast and an environment variable, and `vm.setEnv` leaks into every
    ///      other test in the run. The body it would exercise - `_deployProtocol`,
    ///      `_resolveParams`, `_assertWiring` - is already covered above, so the gates
    ///      are the only part unique to this contract.
    function test_testnet_refusesAnyChainButBaseSepolia() public {
        DeployTestnet script = new DeployTestnet();

        // setUp leaves us on anvil, which is the realistic slip: a testnet script run
        // against a local node, or against mainnet by a stale --rpc-url.
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.WrongChain.selector, ANVIL_CHAIN_ID));
        script.run();

        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.WrongChain.selector, uint256(8453)));
        script.run();
    }

    /// @dev The phrase must be absent for this to mean anything, which is why
    ///      `script/.env.example` documents passing it inline rather than storing it:
    ///      forge auto-loads `.env`, so a stored phrase would be present on every
    ///      invocation and this test would fail while the guard silently stopped
    ///      guarding anything.
    function test_testnet_requiresTheConfirmationPhrase() public {
        DeployTestnet script = new DeployTestnet();

        vm.chainId(84532);
        vm.expectRevert(DeployTestnet.TestnetConfirmationMissing.selector);
        script.run();
    }

    // ── mainnet target gates (audit round 38) ─────────────────

    /// @notice **`DeployMainnet` has three preconditions and no test had ever entered its `run()`.**
    /// @dev The note above the testnet pair says `DeployLocal` and `DeployMainnet` "have `run()`
    ///      bodies that no test has ever invoked, so their gates were only ever read rather than
    ///      executed", and then closes the testnet ones and leaves the mainnet ones exactly as it
    ///      found them. These three close that.
    ///
    ///      This is the outermost of the three and the one a slip actually reaches: a mainnet
    ///      script pointed at a local node by a copied command line, or at Base Sepolia by an
    ///      `--rpc-url` that was right for the previous run. Both ids are asserted because they
    ///      fail for different reasons downstream - 31337 is `_isLocal()`, where every parameter
    ///      rule relaxes, and 84532 is not - and a chain gate that only refused one of them would
    ///      still look correct from either single test.
    ///
    ///      The revert carries the chain id, so the assertion is on the argument too: a guard that
    ///      reported the id it wanted rather than the id it found would tell an operator nothing.
    function test_mainnet_refusesAnyChainButBase() public {
        DeployMainnetHarness script = new DeployMainnetHarness();

        // setUp leaves us on anvil.
        vm.expectRevert(abi.encodeWithSelector(DeployMainnet.WrongChain.selector, ANVIL_CHAIN_ID));
        script.run();

        vm.chainId(84532);
        vm.expectRevert(abi.encodeWithSelector(DeployMainnet.WrongChain.selector, uint256(84532)));
        script.run();

        // The control, and it is what makes the two above a statement about the CHAIN rather than
        // about `run()` reverting on every input: on Base the chain gate passes and the next gate
        // is the one that speaks.
        vm.chainId(script.baseChainId());
        vm.expectRevert(DeployMainnet.MainnetConfirmationMissing.selector);
        script.run();
    }

    /// @notice The confirmation phrase, absent and wrong.
    /// @dev **The wrong-phrase arm is the one that carries the weight.** Absent alone is satisfied
    ///      by any comparison that happens to reject the empty string, so a comparison inverted to
    ///      `==` would still refuse an unset variable - it would refuse a CORRECT one instead, and
    ///      the gate would have become a gate against the operator who followed the runbook. The
    ///      third arm is the control: install what `Deploy.s.sol` actually asks for and the script
    ///      moves on to the custody decision, which is the only way to show this gate is passable
    ///      as well as closable.
    ///
    ///      `script/.env.example` documents passing the phrase inline rather than storing it, and
    ///      that matters here: forge auto-loads `.env`, so a stored phrase would be present on
    ///      every invocation and the absent arm would fail while the guard silently stopped
    ///      guarding anything. Nothing in this test touches the process environment either way -
    ///      the phrase is installed on the script object. See `EnvOverridable`.
    function test_mainnet_requiresTheConfirmationPhrase() public {
        DeployMainnetHarness script = new DeployMainnetHarness();
        vm.chainId(script.baseChainId());

        vm.expectRevert(DeployMainnet.MainnetConfirmationMissing.selector);
        script.run();

        script.setEnvString("RECOUP_MAINNET_CONFIRM", "RECOUP_DEPLOY_BASE_SEPOLIA");
        vm.expectRevert(DeployMainnet.MainnetConfirmationMissing.selector);
        script.run();

        script.setEnvString("RECOUP_MAINNET_CONFIRM", script.confirmPhrase());
        vm.expectRevert(DeployMainnet.CustodyDecisionUnrecorded.selector);
        script.run();
    }

    /// @notice The custody decision, unrecorded and recorded wrong.
    /// @dev The decision - direct-call adapter against a Safe-based backend - depends on DexFi's
    ///      whitelist answer, so the script refuses to infer it. `"direct"` is the only accepted
    ///      value today, which makes the second arm the one worth having: a plausible near-miss
    ///      like `"safe"` is what an operator who HAS made the decision would type, and it has to
    ///      be refused by the same named error rather than fall through to a deployment that used
    ///      the other adapter.
    ///
    ///      **The last arm is the control for all three gates at once.** With the chain, the
    ///      phrase and the custody value all satisfied, `run()` reaches `_resolveParams` and stops
    ///      on `OwnerRequired()` - a parameter rule, not a gate. That is the assertion that says
    ///      the three refusals above are a gate set that can be satisfied rather than a wall, and
    ///      it also pins the ORDER: the custody check is the last thing that runs before the
    ///      script starts resolving operators. Nothing is deployed, because the resolution reverts
    ///      one statement before the `Externals` struct that names the live Base addresses.
    function test_mainnet_requiresTheCustodyDecisionToBeRecorded() public {
        DeployMainnetHarness script = new DeployMainnetHarness();
        vm.chainId(script.baseChainId());
        script.setEnvString("RECOUP_MAINNET_CONFIRM", script.confirmPhrase());

        vm.expectRevert(DeployMainnet.CustodyDecisionUnrecorded.selector);
        script.run();

        script.setEnvString("RECOUP_CUSTODY_ADAPTER", "safe");
        vm.expectRevert(DeployMainnet.CustodyDecisionUnrecorded.selector);
        script.run();

        script.setEnvString("RECOUP_CUSTODY_ADAPTER", "direct");
        vm.expectRevert(DeployBase.OwnerRequired.selector);
        script.run();
    }

    // -- the Phase-4 switchover entrypoint (audit round 16) ------------------

    /// @notice **The switchover has a broadcastable entrypoint, and it runs the post-condition.**
    /// @dev Audit round 16, seven agents. `_wirePhase4` and `_assertPhase4Wiring` had callers only
    ///      in this file, so audit round 15's roughly eighteen restored assertions - every
    ///      ownership check and `d.liquidity` among them - could only ever execute in CI. On
    ///      mainnet the switchover was three hand-sent owner transactions with no post-condition,
    ///      which is the class `DeployBase`'s own header says it exists to prevent.
    ///
    ///      This drives the real script object through its real `run()`, addresses and all, rather
    ///      than calling `_wirePhase4` again from a wrapper. A test of the internal function is
    ///      what already existed; the finding was that nothing reached it from outside.
    function test_wirePhase4_scriptEntrypointWiresAndAssertsInOneRun() public {
        // The deployment has to be made with the parameters the script will resolve, or the
        // post-condition would fail on a mismatch this test invented rather than on the wiring.
        // The owner is the broadcast sender because that is who signs a real switchover.
        //
        // **Built directly rather than read back out of the environment, and that is the fix for
        // this test's flake.** Resolving it through `_resolveParams` meant a sibling could blank
        // `RECOUP_OWNER` in the gap, and the *deployment* would then be made owned by this contract
        // while `run()` broadcast as `DEFAULT_SENDER` - `OwnableUnauthorizedAccount`, six runs in
        // twenty. These are the same five values `_installParams` installs, so the script still has to
        // resolve them correctly for `run()` to succeed; it just cannot corrupt the fixture on its
        // way past.
        GovParams memory p = _paramsOwnedBy(DEFAULT_SENDER);

        (Deployed memory d, address borrower) = _liveProtocolOwnedBy(p);

        // Leave the book in the state a real switchover meets: the treasury owed its float back.
        vm.startPrank(borrower);
        d.credit.borrow(LOAN);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();

        // `ExposedWirePhase4` rather than `WirePhase4`, and `run()` on it is the real `run()` -
        // the subclass adds the storage-backed environment seam and nothing else. See
        // `EnvOverridable`.
        ExposedWirePhase4 script = new ExposedWirePhase4();
        _installDeployed(script, d);
        _installParams(script, DEFAULT_SENDER);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");

        // The contracts must accept the script as their owner for the legs of `_phase4Calls` to be
        // authorised, exactly as a real run is made by whoever owns them.
        script.run();

        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool funds the book");
        assertEq(d.credit.lenderPool(), address(d.pool), "and takes the losses on it");
        assertEq(d.harvester.lenderPool(), address(d.pool), "and is paid for both");

        // And the read-only form answers on the state the run left, which is the shape a timelocked
        // switchover actually takes: one queued batch, then a separate check.
        //
        // **No re-install between the two calls, and the deletion is the point.** There used to be
        // a second `_exportParams`/`_exportDeployed` pair here, because `run()` is a long call and
        // the process environment is global, so a sibling could blank a variable in the gap. The
        // overrides live in this script object's storage now, so there is no gap and nothing to
        // re-write. A test that has to restate its own fixture halfway through is a test sharing
        // something it should not be sharing.
        script.assertOnly();
    }

    /// @dev The guard must bite, or a stray `forge script` moves the funder and the loss sink.
    function test_wirePhase4_requiresTheConfirmationPhrase() public {
        ExposedWirePhase4 script = new ExposedWirePhase4();
        // **Blank, on this instance only, and nothing to restore.** This used to blank the
        // process-wide variable and set it back straight after the call. That made it the one test
        // in the process wanting the phrase ABSENT while two others wanted it present, which is the
        // collision that made the race unavoidable however narrow the window got. The override
        // lives in this script object's storage, which forge isolates per test function, so the
        // other two are not in the same universe as this one. See `EnvOverridable`.
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "");

        vm.expectRevert(WirePhase4.SwitchoverConfirmationMissing.selector);
        script.run();
    }

    /// @notice `queue()` end to end: one scheduled operation, executed by a stranger after the
    ///         delay, and the post-condition holds.
    /// @dev **The fix's shipped artefact, exercised rather than argued.** Round 16's finding was
    ///      that `_wirePhase4` and `_assertPhase4Wiring` had no caller outside CI, which made
    ///      roughly eighteen assertions unreachable on the deployment that mattered. `queue()` is a
    ///      new entry point on the same file and would have the same problem: everything below the
    ///      `hasRole` branch runs only if something calls it.
    ///
    ///      The whole switchover is one `schedule` and one `execute` here, against a real
    ///      `TimelockController` owning all nine contracts. That is the property, and it is the
    ///      thing an operator has to be able to do without ordering anything themselves.
    function test_wirePhase4_queueSchedulesTheWholeSwitchoverAsOneOperation() public {
        // Built before the deployment, because the deployment hands it ownership.
        //
        // **Two proposers, and the second one is a test artefact rather than a shape anybody would
        // deploy.** `queue()` checks `PROPOSER_ROLE` against `msg.sender` and then broadcasts, and
        // in a real `forge script` run those are one address - the `--sender`. Reached from a test
        // they are two: `msg.sender` is this contract, and everything inside `vm.startBroadcast()`
        // originates from `DEFAULT_SENDER`. Pranking instead is not available - foundry refuses a
        // broadcast under an active prank - so both addresses hold the role and the branch under
        // test is the real one.
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock =
            new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));

        // **Addresses passed in, not exported through the environment - and that is a measurement,
        // not a preference.** This file's own note says `vm.setEnv` "outlives the test that called
        // it", which models the hazard as poisoning whatever runs *next*. It is worse than that:
        // `forge test` runs the functions of a suite in parallel and the environment is one
        // process-wide table, so writes land *during* a sibling. Written env-first, this test
        // failed four runs in five on another test's `RECOUP_OWNER`, and once it was made robust it
        // began failing `test_wirePhase4_scriptEntrypointWiresAndAssertsInOneRun` instead - a fifth
        // writer is enough to make the existing four unreliable. Both passed under `--threads 1`.
        // `queue()` and `executeQueued()` are split around exactly this line so the deciding half
        // is reachable without touching the environment at all.
        GovParams memory p = _paramsOwnedBy(address(timelock));
        (Deployed memory d,) = _liveProtocolOwnedBy(p);
        ExposedWirePhase4 script = new ExposedWirePhase4();

        // **Round 21, finding 2: step one, through the script's own entry points.** `queue()`
        // refuses while either contract is unpaused, so the pause is scheduled and executed as its
        // own operation first - which is the whole fix: the door is shut for the entire maturity of
        // the switchover rather than in the same transaction as the thing it was meant to protect.
        // Two forty-eight hour waits instead of one, and that cost is the fixture's to show.
        script.exposedQueuePause(d, timelock, bytes32(0));
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        script.exposedExecuteQueuedPause(d, timelock, bytes32(0));
        assertTrue(d.credit.paused(), "step one leaves borrowing shut");
        assertTrue(d.vault.paused(), "and deposits with it");

        script.exposedQueue(d, timelock, p);

        // Nothing has moved yet: scheduling is not doing.
        assertEq(d.credit.liquiditySource(), address(d.liquidity), "queue() must not touch the chain state");
        assertEq(d.credit.lenderPool(), address(0), "queue() must not touch the chain state");

        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);

        // One call, no ordering decision to make, and no executor role required - which is what an
        // open executor set is for, and is now safe because there is nothing left to order. That a
        // total stranger can run it is measured next door, where `outsider` executes the batch.
        script.exposedExecuteQueued(d, timelock, p);

        _assertPhase4Wiring(d, p);
        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool funds the book");
        assertEq(d.credit.lenderPool(), address(d.pool), "and takes the losses on it");
        assertEq(d.harvester.lenderPool(), address(d.pool), "and is paid for both");
    }

    /// @dev And an unset address is named rather than reverting somewhere unhelpful eight calls in.
    function test_wirePhase4_namesTheAddressItIsMissing() public {
        ExposedWirePhase4 script = new ExposedWirePhase4();
        // **One variable, not the set.** `_resolveDeployed` reads the oracle first, so zeroing that
        // one alone makes it the address named whatever the other seven happen to hold. Zeroing it
        // on this instance rather than in the process environment is what stops that being a race
        // with every other environment-reading test - see `EnvOverridable`.
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(0));

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressMissing.selector, "RECOUP_NAV_ORACLE")
        );
        script.run();
    }

    // -- the two pointers `_assertCoreGraph` did not check (audit round 16) --

    /// @notice `harvester.creditManager` diverging is caught, and it is the only pointer in the
    ///         graph that is constructor-set with a live `onlyOwner` setter behind it.
    /// @dev Four agents. Its divergence bricks the permissionless `harvest()` forever, with an
    ///      `onlyOwner` repair that by go-live is a timelock. It appeared in neither assertion and
    ///      in neither exclusions list, so it read as drift rather than as intent.
    ///
    ///      **Mocked rather than driven through the setter, and the reason is worth recording:
    ///      `EpochHarvester.setCreditManager` refuses any manager the vault is not already pointing
    ///      at, so the divergence this assertion guards against cannot be reached through the
    ///      setter at all.** Moving both together leaves `vault.creditManager` wrong too, and that
    ///      is checked first, so the revert would name the wrong pointer and this test would pass
    ///      without ever reaching the line it is about.
    ///
    ///      What remains reachable is a deployment that *constructs* the harvester against the
    ///      wrong manager, which is a deploy-time defect and exactly what a deploy-time assertion
    ///      is for - plus whatever a future edit to that setter's guard makes possible. So the
    ///      assertion is not redundant, and the honest way to test it is to isolate the read.
    function test_assertWiring_catchesAHarvesterPointedAtTheWrongManager() public {
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedHere(), address(this));

        // Sanity first, so a mock that silently failed to apply cannot read as the guard working.
        assertEq(address(d.harvester.creditManager()), address(d.credit), "fixture: wired correctly to start");

        vm.mockCall(
            address(d.harvester),
            abi.encodeWithSignature("creditManager()"),
            abi.encode(makeAddr("someOtherManager"))
        );

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "harvester.creditManager"));
        this.exposedAssertWiring(d, _paramsOwnedHere());
        vm.clearMockedCalls();
    }

    // ── the mint-receiver implementation graph ───────────────────────────────

    /// @notice The five `mintReceiverImplementation` post-conditions PR #339 added to
    ///         `_assertCoreGraph`, each proved to be individually reachable and individually
    ///         load-bearing.
    /// @dev **#339 shipped the five clauses and no tests for them, so not one of them had ever
    ///      been observed to fail.** `grep -rn "mintReceiver\|MintReceiver"` over this file
    ///      returned nothing until these landed: five assertions certified by nothing.
    ///
    ///      MEASURED (audit round 34, tree `bb7bc90`, forge 1.8.1): **5 PASS with the clauses
    ///      present in `_assertCoreGraph`, and 5 FAIL - "next call did not revert as expected" -
    ///      with all five deleted** (the `d.adapter.mintReceiverImplementation()` call left in
    ///      place so nothing else shifted). So each one is reached, and each one is the only
    ///      thing standing between this deployment and the state it names.
    ///
    ///      Two shaping notes, both load-bearing. Every case calls `exposedAssertWiring`
    ///      UNMOCKED first, through `_mintReceiverGraph`, as a control - without it a test would
    ///      pass just as happily if the fixture reverted for an unrelated reason. And
    ///      `vm.expectRevert` is given the FULLY ENCODED `WiringIncomplete(string)` payload
    ///      rather than the bare selector, so a pass identifies the individual clause instead of
    ///      merely proving that something reverted somewhere inside `_assertCoreGraph`.
    ///
    ///      `vm.mockCall` rather than a substituted contract because every binding involved is an
    ///      immutable set in a constructor - `mintReceiverImplementation` on the adapter, and
    ///      `adapter`, `bond`, `farm` and `usdc` on the implementation. There is no setter to
    ///      misuse.
    function _mintReceiverGraph() internal returns (Deployed memory d, GovParams memory p, address impl) {
        p = _params();
        d = _deployProtocol(_externals(), p, address(this));
        impl = address(d.adapter.mintReceiverImplementation());
        // Control: the untouched graph passes, so any revert below is the mutation.
        this.exposedAssertWiring(d, p);
    }

    function test_assertWiring_catchesAMintReceiverImplementationWithNoCode() public {
        (Deployed memory d, GovParams memory p,) = _mintReceiverGraph();
        address codeless = makeAddr("codelessImplementation");
        assertEq(codeless.code.length, 0, "fixture: stand-in must be codeless");
        vm.mockCall(
            address(d.adapter),
            abi.encodeWithSignature("mintReceiverImplementation()"),
            abi.encode(codeless)
        );
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "adapter.mintReceiverImplementation")
        );
        this.exposedAssertWiring(d, p);
    }

    function test_assertWiring_catchesAMintReceiverPointedAtAnotherAdapter() public {
        (Deployed memory d, GovParams memory p, address impl) = _mintReceiverGraph();
        vm.mockCall(impl, abi.encodeWithSignature("adapter()"), abi.encode(makeAddr("otherAdapter")));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "mintReceiver.adapter"));
        this.exposedAssertWiring(d, p);
    }

    function test_assertWiring_catchesAMintReceiverBuiltOnAnotherBond() public {
        (Deployed memory d, GovParams memory p, address impl) = _mintReceiverGraph();
        vm.mockCall(impl, abi.encodeWithSignature("bond()"), abi.encode(makeAddr("otherBond")));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "mintReceiver.bond"));
        this.exposedAssertWiring(d, p);
    }

    function test_assertWiring_catchesAMintReceiverBuiltOnAnotherFarm() public {
        (Deployed memory d, GovParams memory p, address impl) = _mintReceiverGraph();
        vm.mockCall(impl, abi.encodeWithSignature("farm()"), abi.encode(makeAddr("otherFarm")));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "mintReceiver.farm"));
        this.exposedAssertWiring(d, p);
    }

    function test_assertWiring_catchesAMintReceiverBuiltOnAnotherUsdc() public {
        (Deployed memory d, GovParams memory p, address impl) = _mintReceiverGraph();
        vm.mockCall(impl, abi.encodeWithSignature("usdc()"), abi.encode(makeAddr("otherUsdc")));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "mintReceiver.usdc"));
        this.exposedAssertWiring(d, p);
    }

    /// @notice And `liquidity.creditManager` is checked after the switchover too, not only before.
    /// @dev Three agents. `_wirePhase4` does not move this pointer, and "everything the switchover
    ///      does not change" is the shared function's own inclusion rule - so it was being checked
    ///      in one of the two places that must both hold.
    function test_assertPhase4Wiring_catchesALiquiditySourcePointedAtTheWrongManager() public {
        (Deployed memory d,) = _liveProtocol();
        this.exposedWirePhase4(d);

        d.liquidity.setCreditManager(makeAddr("someOtherManager"));

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "liquidity.creditManager"));
        this.exposedAssertPhase4Wiring(d, _paramsOwnedHere());
    }

    /// @notice **`_assertPhase4Wiring`'s `GovParams` is not dead, and this is the measurement that
    ///         says so rather than a comment claiming it.**
    /// @dev Audit round 30, follow-up item 9. The parameter looks unused - there is no `p.<field>`
    ///      anywhere in that function's body, which is exactly what a field-access grep measures -
    ///      and it is handed WHOLE to `_assertCoreGraph`, which reads `p.owner` at every one of its
    ///      ownership checks. A grep measured the wrong thing here once and the parameter was very
    ///      nearly deleted from twenty call sites.
    ///
    ///      The control is the first line, and it is what makes the revert mean something: the
    ///      identical call with the REAL parameters passes over the identical deployment. So the
    ///      failure below is caused by the struct being zeroed and by nothing else.
    ///
    ///      `d.oracle` is named in the revert because it is the first member of `Deployed`, and
    ///      `_assertCoreGraph` walks `_ownablesOf` in declaration order. That is pinned deliberately
    ///      rather than caught with a bare `expectRevert()`: a bare one would also pass if the
    ///      function reverted for some entirely unrelated reason, which is the failure mode this
    ///      test exists to rule out.
    function test_assertPhase4Wiring_readsItsGovParamsAndAZeroedStructIsRefused() public {
        (Deployed memory d,) = _liveProtocol();
        this.exposedWirePhase4(d);

        // The control: real parameters, same deployment, no revert.
        this.exposedAssertPhase4Wiring(d, _paramsOwnedHere());

        GovParams memory zeroed;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.OwnershipNotTransferred.selector, address(d.oracle), address(this)
            )
        );
        this.exposedAssertPhase4Wiring(d, zeroed);
    }

    // -- helpers for the entrypoint tests -------------------------------------

    /// @dev Installed ON the script instance rather than written to the process environment; the
    ///      note on `EnvOverridable` is the reason. Every address `_resolveDeployed` reads, in one
    ///      call, so a caller cannot install seven and reach the eighth by accident.
    function _installDeployed(EnvOverridable script, Deployed memory d) internal {
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
    }

    // ── audit round 22, finding 7: the batch with no code at the far end ─────

    /// @dev A plausible typo rather than an obviously silly address: eight characters of hex an
    ///      operator could paste into `RECOUP_EPOCH_HARVESTER` and not look at twice. Nothing is
    ///      deployed there, which is the whole property.
    address internal constant CODELESS = address(0x0BADC0DE);

    /// @dev `cancel`'s expected-state bitmap. OZ refuses any id that is not *pending*, so it
    ///      accepts `Waiting | Ready`, and the enum is `Unset, Waiting, Ready, Done` - so those are
    ///      `1 << 1` and `1 << 2`, not `1 << 0`. MEASURED: the first version of this said 5 and OZ
    ///      answered 6. Derived rather than pasted as a hex blob, like `_notScheduled` above it,
    ///      which uses the same `Ready == 2`.
    function _notCancellable(bytes32 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector,
            id,
            bytes32(uint256(1 << 1) | uint256(1 << 2))
        );
    }

    /// @notice **THE FIX for audit round 22, finding 7.** `queue()` refuses a batch whose targets
    ///         are not the contracts it thinks they are, before the forty-eight hour clock starts.
    /// @dev The hazard, measured at `d8e2208` and re-measured in the second half of this test:
    ///      OZ 5.6.1's `TimelockController._execute` calls `Address.verifyCallResult` and not
    ///      `verifyCallResultFromTarget`, so it never asks whether the target has code - and a call
    ///      to a codeless address returns success with empty returndata. One mistyped
    ///      `RECOUP_EPOCH_HARVESTER` therefore scheduled without complaint, matured, was executed
    ///      by a stranger, **succeeded**, and left `harvester.lenderPool() == address(0)` with the
    ///      protocol unpaused and the pool funding the book: round 11's shipped state, reproduced
    ///      by a typo. `cancel` cannot undo it, because a `Done` id is burned forever.
    ///
    ///      `_requireSwitchoverWindowShut` reads four values off two of the eight operator-typed
    ///      addresses and says of itself that those are "the complete set of preconditions the six
    ///      legs actually evaluate". True, and a claim about the legs' *state* - the other six
    ///      addresses were never touched before the operator committed to a window.
    ///
    ///      **The fix is a relocation.** `_executeQueued` already caught this exact input, through
    ///      `_assertPhase4Wiring` -> `_assertCoreGraph` -> `_ownablesOf`, in the same transaction,
    ///      so the whole thing unwound including the timelock's `Done` write. It was on the wrong
    ///      side of the window, and it only ever protected the operator who used the sanctioned
    ///      entry point rather than the stranger who may fire `executeBatch`. `_queue` runs
    ///      `_assertCoreGraph` up front now. Both arms are here: the mistyped set is refused and
    ///      schedules nothing, and the honest set queues on the very next line.
    function test_wirePhase4_queueRefusesABatchWithACodelessTarget() public {
        address[] memory proposers = new address[](3);
        proposers[0] = proposer;
        proposers[1] = address(this);
        proposers[2] = DEFAULT_SENDER;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock =
            new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));

        GovParams memory p = _paramsOwnedBy(address(timelock));
        (Deployed memory d,) = _liveProtocolOwnedBy(p);
        ExposedWirePhase4 script = new ExposedWirePhase4();
        _pauseForSwitchover(d, timelock);

        // Written out as a literal rather than copied and mutated: `Deployed memory` is a
        // reference, so `Deployed memory typo = d; typo.harvester = ...` would clobber `d` too and
        // the control arm below would be testing the same broken set twice. The literal is also
        // compiler-checked against the struct, so a tenth member cannot be forgotten here.
        Deployed memory typo = Deployed({
            oracle: d.oracle,
            riskParams: d.riskParams,
            vault: d.vault,
            adapter: d.adapter,
            credit: d.credit,
            pool: d.pool,
            liquidity: d.liquidity,
            harvester: EpochHarvester(CODELESS),
            auction: d.auction
        });
        assertEq(CODELESS.code.length, 0, "premise: the typo names an address with no code");
        assertEq(address(typo.harvester), CODELESS, "premise: the harvester is the mistyped member");
        assertTrue(address(d.harvester) != CODELESS, "premise: and the honest set is untouched");

        // THE FIX. Index 7 is the harvester's position in `Deployed`, which is not written down
        // anywhere - it is where the struct puts it.
        vm.expectRevert(abi.encodeWithSelector(DeployBase.DeployedMemberNotOwnable.selector, uint256(7)));
        script.exposedQueue(typo, timelock, p);

        (address[] memory tt, uint256[] memory tv, bytes[] memory tp) = _phase4Calls(typo);
        bytes32 typoId = timelock.hashOperationBatch(tt, tv, tp, bytes32(0), bytes32(0));
        assertFalse(timelock.isOperation(typoId), "the refused batch must not be scheduled");

        // CONTROL: the same call, one address different, still queues. Without this the revert
        // above would be satisfied by a `queue()` that refuses everything.
        script.exposedQueue(d, timelock, p);
        (address[] memory ht, uint256[] memory hv, bytes[] memory hp) = _phase4Calls(d);
        assertTrue(
            timelock.isOperationPending(timelock.hashOperationBatch(ht, hv, hp, bytes32(0), bytes32(0))),
            "the honest switchover still queues"
        );

        // THE HAZARD, re-measured, and the reason the refusal has to happen before the clock starts
        // rather than after it. Scheduled by hand here - which is what the pre-fix `queue()` did,
        // and what a proposer building the batch in a Safe UI still does - then executed by a total
        // stranger.
        vm.prank(proposer);
        timelock.scheduleBatch(tt, tv, tp, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        vm.warp(block.timestamp + Config.ADMIN_TIMELOCK);
        vm.prank(outsider);
        timelock.executeBatch(tt, tv, tp, bytes32(0), bytes32(0));

        assertTrue(timelock.isOperationDone(typoId), "MEASURED: the codeless leg SUCCEEDS");
        assertEq(d.harvester.lenderPool(), address(0), "MEASURED: the leg that pays lenders reached nobody");
        assertEq(d.credit.lenderPool(), address(d.pool), "while the pool took the credit risk");
        assertFalse(d.credit.paused(), "and the doors were reopened over the top of it");
        assertFalse(d.vault.paused());

        // And the recorded recovery does not reach it: `cancel` frees a *pending* id and this one
        // is `Done`. That is why the argument for `SALT == bytes32(0)` had to be narrowed rather
        // than left as written.
        vm.expectRevert(_notCancellable(typoId));
        vm.prank(proposer);
        timelock.cancel(typoId);
    }

    // ── audit round 22, finding 13: the settlement token nobody compared ─────

    /// @notice **THE FIX for finding 13.** A `LenderPool` on a different USDC is refused by the
    ///         script's own post-condition, before and after the switchover.
    /// @dev The hazard, measured at `d8e2208`: a pool constructed on a *second* `MockUSDC` and
    ///      wired exactly as `_wire` wires one went through the **entire** Phase-4 switchover -
    ///      every leg accepted - and `_assertPhase4Wiring` passed over it. `usdc` is held as an
    ///      immutable by six members of `Deployed` and `bond` by two, and the census compared
    ///      neither, while comparing `riskParams` across three and `navOracle` across three.
    ///
    ///      **The negative result is the more useful half.** The expected outcome was a drain and
    ///      the measured one is a denial of service: `borrow` reverts `LiquidityNotDelivered` and
    ///      no real USDC moves, because `CreditManager.borrow` brackets `lend()` with its own
    ///      balance either side and compares the delta with the amount asked for. That bracket is a
    ///      runtime asset-identity check nobody had framed as one, and **it is what holds the money
    ///      today** - the assertion added here is defence in depth that arrives earlier, not the
    ///      only thing standing between a mismatch and a loss.
    function test_deploy_theCensusReachesTheSettlementToken() public {
        (Deployed memory d, address borrower) = _liveProtocol();

        MockUSDC other = new MockUSDC();
        LenderPool rogue = new LenderPool(IERC20(address(other)), address(this));
        rogue.setCreditManager(address(d.credit));
        rogue.setEpochHarvester(address(d.harvester));

        Deployed memory swapped = Deployed({
            oracle: d.oracle,
            riskParams: d.riskParams,
            vault: d.vault,
            adapter: d.adapter,
            credit: d.credit,
            pool: rogue,
            liquidity: d.liquidity,
            harvester: d.harvester,
            auction: d.auction
        });

        // CONTROL: the honest deployment passes the same assertion, so the revert below is about
        // the token and not about the fixture.
        this.exposedAssertWiring(d, _paramsOwnedHere());

        // Pre-switchover. `pool.asset` is the first census line the rogue fails: `pool.creditManager`
        // and `pool.epochHarvester` are checked above it and both hold, which is the point - the
        // pool is wired correctly in every way anything used to look at.
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "pool.asset"));
        this.exposedAssertWiring(swapped, _paramsOwnedHere());

        // Post-switchover, which is where it was measured passing. Every leg still accepts: nothing
        // in the protocol refuses a funder on the wrong token.
        this.exposedWirePhase4(swapped);
        assertEq(d.credit.liquiditySource(), address(rogue), "the switchover itself raises no objection");
        assertEq(d.credit.lenderPool(), address(rogue));
        assertEq(d.harvester.lenderPool(), address(rogue));

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "pool.asset"));
        this.exposedAssertPhase4Wiring(swapped, _paramsOwnedHere());

        // THE NEGATIVE RESULT, carried rather than summarised. The rogue pool is funded so that
        // `lend` itself succeeds and the failure is unambiguously the balance bracket rather than
        // an empty pool: it moves `other` USDC, the manager counts real USDC, the delta is zero.
        address lender = makeAddr("otherLender");
        other.mint(lender, FLOAT);
        vm.startPrank(lender);
        other.approve(address(rogue), FLOAT);
        rogue.deposit(FLOAT, lender);
        vm.stopPrank();

        uint256 realBalanceBefore = usdc.balanceOf(address(d.credit));
        vm.expectRevert(abi.encodeWithSelector(CreditManager.LiquidityNotDelivered.selector, LOAN, 0));
        vm.prank(borrower);
        d.credit.borrow(LOAN);
        assertEq(usdc.balanceOf(address(d.credit)), realBalanceBefore, "and no real USDC moved");
    }

    /// @notice The other half of the same census: the collateral token. And the control that says
    ///         which half of the adapter edge is actually unguarded.
    /// @dev Kept separate from the settlement-token test because "the money" and "the collateral"
    ///      fail for different reasons and should say so.
    ///
    ///      **The sibling of this finding lives in `src/` and is NOT fixed here:**
    ///      `CollateralVault.setCustodyAdapter` never asks whether the incoming adapter holds the
    ///      same ERC-1155, and the second assertion below is that measurement - a real adapter on a
    ///      different `MockBond` installs with no revert. What `DeployBase` covers is the
    ///      deploy-time half only: an adapter swapped in after the script has run is not reached by
    ///      anything in it.
    ///
    ///      **The control is the last third, and it is why there is no `adapter.vault` line in
    ///      `_assertCoreGraph`.** The same setter that ignores the bond *does* read
    ///      `adapter.vault()` and reverts `AdapterVaultMismatch`, and it is that pointer's only
    ///      writer - so a `WiringIncomplete("adapter.vault")` next to the bond line would be
    ///      unreachable given the `vault.custodyAdapter` assertion above it. Written, compiled,
    ///      measured inert, removed. The asymmetry between the two reads is the finding.
    function test_deploy_theCensusReachesTheCollateralTokenAndTheAdapterBackPointer() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        MockBond otherBond = new MockBond();
        MockFarm otherFarm = new MockFarm(otherBond, usdc);
        otherBond.setRewardPool(address(otherFarm));
        DirectCallAdapter wrongBond = new DirectCallAdapter(
            IDexFiBond(address(otherBond)),
            IDexFiFarm(address(otherFarm)),
            IERC20(address(usdc)),
            address(d.vault),
            owner,
            address(d.harvester)
        );
        vm.prank(owner);
        d.vault.setCustodyAdapter(ICustodyAdapter(address(wrongBond)));
        assertEq(
            address(d.vault.custodyAdapter()),
            address(wrongBond),
            "MEASURED: the vault installs an adapter holding a different ERC-1155 with no revert"
        );

        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "adapter.bond"));
        this.exposedAssertWiring(_withAdapter(d, wrongBond), _params());

        // THE CONTROL. Right bond, wrong vault: refused by the setter itself, which is the read the
        // ERC-1155 does not get. `boundVault` is the address the rogue adapter names, not the
        // vault, so this asserts that the guard fired on the value it was given.
        address otherVault = makeAddr("someOtherVault");
        DirectCallAdapter wrongVaultAdapter = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(farm)),
            IERC20(address(usdc)),
            otherVault,
            owner,
            address(d.harvester)
        );
        bytes memory mismatch =
            abi.encodeWithSelector(CollateralVault.AdapterVaultMismatch.selector, otherVault);
        vm.expectRevert(mismatch);
        vm.prank(owner);
        d.vault.setCustodyAdapter(ICustodyAdapter(address(wrongVaultAdapter)));
    }

    /// @dev `Deployed memory` is a reference, so this returns a fresh struct rather than mutating
    ///      the caller's. Written as a literal so the compiler refuses it if `Deployed` grows.
    function _withAdapter(Deployed memory d, DirectCallAdapter a)
        internal
        pure
        returns (Deployed memory)
    {
        return Deployed({
            oracle: d.oracle,
            riskParams: d.riskParams,
            vault: d.vault,
            adapter: a,
            credit: d.credit,
            pool: d.pool,
            liquidity: d.liquidity,
            harvester: d.harvester,
            auction: d.auction
        });
    }

    // ── audit round 22, F11-4: what RECOUP_YIELD_RECIPIENT actually is ───────

    /// @notice The operator's `RECOUP_YIELD_RECIPIENT` is the **interim** sink. It is live on chain
    ///         for the span of a deploy, and no completed deployment keeps it.
    /// @dev The contradiction this resolves: the variable is required and validated against three
    ///      rules, `_deployProtocol` hands it to the adapter's constructor, `_wire` overwrites it
    ///      with the harvester five lines later, and `_assertCoreGraph` then *requires* the
    ///      harvester - so no successful deployment can end with the operator's value in place,
    ///      which read as a gate on nothing. The deploy runbook listed the refusal among its
    ///      exercised gates without saying which state it was about.
    ///
    ///      It is a gate on a real state. Under `forge script --broadcast` every `new` and every
    ///      external call in `_deployProtocol` is its own transaction - 40 of them on the
    ///      2026-08-19 testnet deploy - so the constructor's value is the adapter's live yield sink
    ///      from the moment it is deployed until `_wire`'s last call, a span that already includes
    ///      `vault.setCustodyAdapter`. A deploy that stops part way leaves it standing. Both halves
    ///      are asserted here so the rules in `_validateParams` are visibly about something.
    function test_deploy_theOperatorsYieldRecipientIsTheInterimSinkOnly() public {
        GovParams memory p = _params();

        // Half one: constructed exactly as `_deployProtocol` constructs it, and the operator's
        // address is what it answers with.
        DirectCallAdapter interim = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(farm)),
            IERC20(address(usdc)),
            makeAddr("someVault"),
            address(this),
            p.yieldRecipient
        );
        assertEq(interim.yieldRecipient(), p.yieldRecipient, "the interim sink is the operator's address");

        // Half two: and a finished deployment never keeps it.
        Deployed memory d = _deployProtocol(_externals(), p, address(this));
        assertEq(d.adapter.yieldRecipient(), address(d.harvester), "the shipped sink is the harvester");
        assertTrue(p.yieldRecipient != address(d.harvester), "which is never the operator's address");
        _assertWiring(d, p);
    }

    /// @dev Everything a `WirePhase4` entry point reads, in one call, so it can sit on the line
    ///      immediately before the script call it feeds. The environment is process-global and
    ///      `forge test` runs a suite's functions in parallel, so any gap between an export and its
    ///      use is a window for a sibling's blanking write - measured, not theorised.
    /// @dev The script resolves governance parameters the same way a deploy does, and it runs off
    ///      anvil here, so they have to be supplied rather than defaulted.
    /// @dev **`RECOUP_OWNER` belongs in here, and audit round 22 is why it moved.** It used to be
    ///      set once, twenty lines and a whole borrow-and-repay sequence before the `run()` that
    ///      reads it, while the other four were re-exported immediately beforehand - so it had by
    ///      far the widest window for a sibling to blank it. Exported with the other four now, on
    ///      the line before the call that reads them. See the note on `setUp`.
    function _installParams(EnvOverridable script, address owner_) internal {
        script.setEnvAddress("RECOUP_OWNER", owner_);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", treasury);
    }

    /// @dev `_liveProtocol` hard-codes ownership here so its own fixture calls work. The
    ///      switchover is made by whoever owns the contracts, so this variant deploys owned by the
    ///      broadcast sender and reaches back in with a prank for the two fixture calls that need
    ///      the owner - which is also the honest shape: the script never assumes it deployed
    ///      anything, and a real run signs as the owner rather than as the deployer.
    function _liveProtocolOwnedBy(GovParams memory p) internal returns (Deployed memory d, address borrower) {
        d = _deployProtocol(_externals(), p, address(this));

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(d.liquidity), FLOAT);
        d.liquidity.fund(FLOAT);
        vm.prank(p.owner);
        d.oracle.bootstrapNav(NAV);

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);

        borrower = makeAddr("borrower");
        bond.mint(borrower, BONDS);
        vm.startPrank(borrower);
        bond.setApprovalForAll(address(d.vault), true);
        d.vault.depositBonds(BONDS);
        vm.stopPrank();
    }
}
