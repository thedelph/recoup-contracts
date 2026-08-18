// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {DeployTestnet} from "../script/Deploy.s.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {Config} from "../src/Config.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice `WirePhase4` with its two timelock entry points reachable without the process
///         environment.
/// @dev `vm.setEnv` writes one table shared by every test in the process, and `forge test` runs a
///      suite's functions in parallel - so an env-driven test of `queue()` both raced its siblings
///      and made them fail. Measured: four failures in five, then a different test failing once
///      this one was made robust, and both green under `--threads 1`. The split in the script is
///      what this uses: `queue()` and `executeQueued()` resolve addresses and then delegate, and
///      everything that decides anything is below the delegation.
contract ExposedWirePhase4 is WirePhase4 {
    function exposedQueue(Deployed memory d, TimelockController timelock) external {
        _queue(d, timelock);
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

/// @notice Coverage for the deployment path itself.
///
///         Until now `DeployLocal` wired the protocol and `DeployMainnet` reverted,
///         which meant the wiring destined for mainnet had never executed anywhere.
///         A correctly designed protocol that is incorrectly wired is worth nothing,
///         so the deploy sequence runs here on every CI run.
contract DeployTest is Test, DeployBase {
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
        _clearScriptEnv();
    }

    /// @dev **`vm.setEnv` mutates the process environment and outlives the test that called it.**
    ///      One test exporting a deployment left `test_localDefaultsDoNotPointAtTheDeployer`
    ///      asserting against another test's treasury. Cleared here rather than at the end of each
    ///      exporting test, because a test that reverts part-way would never reach its own cleanup
    ///      and would poison whatever ran next in a way that looks like a real failure somewhere
    ///      else entirely.
    function _clearScriptEnv() internal {
        string[9] memory names = [
            "RECOUP_OWNER",
            "RECOUP_YIELD_RECIPIENT",
            "RECOUP_KEEPER",
            "RECOUP_NAV_CONFIRMER",
            "RECOUP_PROTOCOL_FEE_WALLET",
            "RECOUP_SWITCHOVER_CONFIRM",
            "RECOUP_NAV_ORACLE",
            "RECOUP_COLLATERAL_VAULT",
            "RECOUP_CUSTODY_ADAPTER"
        ];
        for (uint256 i; i < names.length; ++i) {
            vm.setEnv(names[i], "");
        }
        vm.setEnv("RECOUP_CREDIT_MANAGER", "");
        vm.setEnv("RECOUP_LENDER_POOL", "");
        vm.setEnv("RECOUP_LIQUIDITY_SOURCE", "");
        vm.setEnv("RECOUP_EPOCH_HARVESTER", "");
        vm.setEnv("RECOUP_LIQUIDATION_AUCTION", "");
        vm.setEnv("RECOUP_TIMELOCK", "");
    }

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
            protocolFeeWallet: treasury
        });
    }

    /// @dev External wrappers: `expectRevert` only catches reverts one call depth
    ///      below the cheatcode, and the functions under test are internal.
    function exposedValidateParams(GovParams memory p, address deployer) external view {
        _validateParams(p, deployer);
    }

    function exposedAssertWiring(Deployed memory d, GovParams memory p) external view {
        _assertWiring(d, p);
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
    ///      twice. So this runs the whole sequence in one transaction rather than in three.
    ///
    ///      **The second half of it is not in this repository.** The version in the private tree
    ///      then spends real money through the wiring - a lender funds the pool, the pool funds a
    ///      borrow, and the lender leg finally has somewhere to deliver - and none of that is
    ///      possible against the skeleton published here, which refuses deposits and cannot lend.
    ///      What survives is the switchover itself and its post-condition, which is the part that
    ///      is about the deploy script rather than about the pool.
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
    ///      `setLiquiditySource` refuses while `totalDebt` or `pendingPrincipal` is non-zero, so no
    ///      pre-existing position could be carried into the gap and defaulted there.
    ///
    ///      Kept, rather than deleted, for what it makes unreachable: it moves the pointers directly
    ///      rather than through `_wirePhase4`, which is exactly what an operator transcribing them
    ///      into a Safe does, and it is the only assertion in this file that the funding leg alone
    ///      leaves a consistent protocol behind it.
    ///
    ///      **The half that drives a default through it is not in this repository.** In the private
    ///      tree a lender funds the pool, the borrow is drawn on the funding leg alone, the NAV is
    ///      crashed and the position written down, and the loss is then measured arriving at the
    ///      pool that funded it. None of that runs against the skeleton published here, which
    ///      refuses deposits, cannot lend and keeps no socialised-loss book. What survives is the
    ///      pointer property itself - that the funding leg carries the sink with it - which is the
    ///      part an operator transcribing legs into a Safe depends on.
    function test_deploy_phase4FundingLegCarriesTheLossSinkSoThereIsNoGap() public {
        (Deployed memory d,) = _liveProtocol();

        // Leg one on its own. This is legal precisely because the book is flat.
        d.credit.setLiquiditySource(address(d.pool));
        assertEq(d.credit.lenderPool(), address(d.pool), "the funding leg must carry the loss sink with it");

        // Legs two and three still land, and are now no-ops on the pointer they name.
        d.credit.setLenderPool(address(d.pool));
        d.harvester.setLenderPool(address(d.pool));
        _assertPhase4Wiring(d, _paramsOwnedHere());

        assertEq(d.credit.totalDebt(), 0, "and the manager agrees there is no debt left");
    }

    // **`test_deploy_phase4PauseShutsTheOnlyDoorIntoTheGap` is not in this repository.** It is the
    // other direction of the same property: with the switchover paused, the borrow that stranded
    // the principal reverts; the protocol comes back open; and the identical borrow is then charged
    // correctly to a pool that is funder and sink together. Every one of those steps needs a pool
    // that takes deposits, lends and keeps a socialised-loss book, and the skeleton published here
    // does none of them - a borrow drawn after the switchover reverts `NotImplemented()` inside the
    // pool rather than landing on it. What that test says about the deploy script alone, that the
    // switchover pauses and hands the protocol back open, is asserted immediately below and again
    // in the timelock tests, where the pause legs are scheduled and executed as their own
    // operation.
    //
    // `_crashNav` and `_defaultToWriteDown`, and the crashed-NAV constant they price against, went
    // with it: they exist only to drive those pool-funded defaults.

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

    // **`_fundALender` is not in this repository.** Every test below called it to put a real
    // lender behind the pool before the switchover ran, and the skeleton published here refuses
    // deposits - the fixture would revert rather than fund anything. None of what survives needs
    // it: the book is funded by the treasury right up until the switchover moves the pointer, and
    // nothing here borrows afterwards.

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
    ///
    ///      **The measurement of that charge is not in this repository.** The private tree draws
    ///      the borrow on the reordered funding leg, crashes the NAV, writes the position down and
    ///      asserts the whole loss arriving at the pool. The skeleton here cannot lend, so what
    ///      survives is the half that is about the deploy script and the timelock: legs queued one
    ///      operation each can be executed in any order by anybody, and the funding leg run alone
    ///      still leaves both pointers consistent.
    function test_deploy_phase4LegsQueuedSeparatelyCanBeReorderedButTheGapIsGone() public {
        (Deployed memory d,) = _liveProtocol();
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

        // The borrow, the crash and the written-down default that used to be measured here belong
        // to the pool, and the pool is not in this repository. What can still be said on this side
        // of the seam is that the reordered leg left nothing inconsistent behind it.
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
        assertEq(d.pool.outstandingPrincipal(), 0, "nothing is stranded on the pool");
        assertEq(d.credit.totalDebt(), 0, "while the manager agrees there is no debt left");
    }

    /// @notice **THE FIX, measured against exactly that hazard.** The same legs, scheduled as one
    ///         `scheduleBatch`, cannot be reordered, cannot be run singly and cannot be run in
    ///         part. `executeBatch` is one transaction, so the gap has no duration to be observed
    ///         in and the identical default is charged to the lenders in full.
    /// @dev The three refusals are the measurement. A batch is one operation with one id computed
    ///      over the whole array, so a single leg and a truncated batch are simply ids nobody ever
    ///      scheduled - `TimelockController` refuses them as `Unset`. That is why this removes the
    ///      window rather than guarding it: there is no guard to defeat.
    ///
    ///      **The last clause of the notice above is not in this repository.** Charging the
    ///      identical default to the lenders needs a pool that takes deposits and lends, and the
    ///      skeleton published here does neither. The three refusals are the fix and they are all
    ///      here; what is missing is the closing measurement that the batch reaches the same end
    ///      state the hazard test above reached by accident.
    function test_deploy_phase4BatchLeavesNoWindowForAnExecutorToReorder() public {
        (Deployed memory d,) = _liveProtocol();
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

        // **The identical borrow and the identical default, charged in full, are not in this
        // repository.** That is the half that closes the loop on the hazard test above, and it
        // needs a pool that lends and can be charged. The three refusals are the fix itself and
        // they are all here: a batch is one operation with one id, so a single leg, a reordered
        // array and a truncated array are ids nobody ever scheduled.
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
    ///      **The retry after the switchover is not in this repository.** The private tree makes
    ///      the same borrow again once the batch has landed, so the test cannot pass against a
    ///      protocol left shut - which is the failure mode the pause legs would otherwise
    ///      introduce. Against the skeleton published here that borrow would draw on a pool that
    ///      cannot lend, so the reopening is asserted on the two pause flags directly instead.
    function test_deploy_phase4TheMicroUsdcGriefIsRefusedAtTheDoor() public {
        (Deployed memory d,) = _liveProtocol();
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

        // And the protocol comes back open. A test that stopped at the revert would pass just as
        // happily against a switchover that never unpauses.
        assertFalse(d.credit.paused(), "and the door reopens on the other side");
        assertFalse(d.vault.paused(), "both halves of it");
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
        script.exposedQueue(d, timelock);

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
        script.exposedQueue(d, timelock);

        // Paused, but the book is live: refused on the debt, by its actual size.
        _pauseForSwitchover(d, timelock);
        vm.expectRevert(abi.encodeWithSelector(WirePhase4.SwitchoverBookNotFlat.selector, LOAN));
        script.exposedQueue(d, timelock);

        // Wound down - which the pause is what makes possible without a new borrow arriving - and
        // the same call is accepted. Without this half the two reverts above would be satisfied by
        // a `queue()` that refuses everything.
        vm.startPrank(borrower);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();
        script.exposedQueue(d, timelock);

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
        script.exposedQueue(d, timelock);
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
    ///      Restored immediately after, because `vm.setEnv` leaks into every other test
    ///      in the run. `RECOUP_OWNER` is deliberately left alone: it defaults to the
    ///      deployer rather than to zero, so zeroing it would trip `OwnerRequired`
    ///      instead of reaching a default.
    function test_localDefaultsDoNotPointAtTheDeployer() public {
        string[4] memory keys;
        keys[0] = "RECOUP_YIELD_RECIPIENT";
        keys[1] = "RECOUP_KEEPER";
        keys[2] = "RECOUP_NAV_CONFIRMER";
        keys[3] = "RECOUP_PROTOCOL_FEE_WALLET";

        address[4] memory prior;
        for (uint256 i = 0; i < keys.length; i++) {
            prior[i] = vm.envOr(keys[i], address(0));
            vm.setEnv(keys[i], vm.toString(address(0)));
        }

        GovParams memory p = _resolveParams(address(this));

        for (uint256 i = 0; i < keys.length; i++) {
            vm.setEnv(keys[i], vm.toString(prior[i]));
        }

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
        // `RECOUP_OWNER` is the broadcast sender because that is who signs a real switchover.
        _exportParams();
        vm.setEnv("RECOUP_OWNER", vm.toString(DEFAULT_SENDER));
        GovParams memory p = _resolveParams(address(this));

        (Deployed memory d, address borrower) = _liveProtocolOwnedBy(p);

        // Leave the book in the state a real switchover meets: the treasury owed its float back.
        vm.startPrank(borrower);
        d.credit.borrow(LOAN);
        usdc.approve(address(d.credit), LOAN);
        d.credit.repay(LOAN);
        vm.stopPrank();

        WirePhase4 script = new WirePhase4();
        _exportDeployed(d);
        _exportParams();
        vm.setEnv("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");

        // The contracts must accept the script as their owner for the legs of `_phase4Calls` to be
        // authorised, exactly as a real run is made by whoever owns them.
        script.run();

        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool funds the book");
        assertEq(d.credit.lenderPool(), address(d.pool), "and takes the losses on it");
        assertEq(d.harvester.lenderPool(), address(d.pool), "and is paid for both");

        // And the read-only form answers on the state the run left, which is the shape a timelocked
        // switchover actually takes: one queued batch, then a separate check.
        script.assertOnly();
        _clearScriptEnv();
    }

    /// @dev The guard must bite, or a stray `forge script` moves the funder and the loss sink.
    function test_wirePhase4_requiresTheConfirmationPhrase() public {
        WirePhase4 script = new WirePhase4();
        // Cleared explicitly. `vm.setEnv` is process-wide and outlives the test that set it, so a
        // sibling test's phrase would leave this asserting nothing - which is the same "passes for
        // a reason that is not the reason" shape the deploy targets' own phrase tests warn about.
        vm.setEnv("RECOUP_SWITCHOVER_CONFIRM", "");

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

        script.exposedQueue(d, timelock);

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
        WirePhase4 script = new WirePhase4();
        vm.setEnv("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        vm.setEnv("RECOUP_NAV_ORACLE", "0x0000000000000000000000000000000000000000");

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressMissing.selector, "RECOUP_NAV_ORACLE")
        );
        script.run();
        _clearScriptEnv();
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

    // -- helpers for the entrypoint tests -------------------------------------

    function _exportDeployed(Deployed memory d) internal {
        vm.setEnv("RECOUP_NAV_ORACLE", vm.toString(address(d.oracle)));
        vm.setEnv("RECOUP_COLLATERAL_VAULT", vm.toString(address(d.vault)));
        vm.setEnv("RECOUP_CUSTODY_ADAPTER", vm.toString(address(d.adapter)));
        vm.setEnv("RECOUP_CREDIT_MANAGER", vm.toString(address(d.credit)));
        vm.setEnv("RECOUP_LENDER_POOL", vm.toString(address(d.pool)));
        vm.setEnv("RECOUP_LIQUIDITY_SOURCE", vm.toString(address(d.liquidity)));
        vm.setEnv("RECOUP_EPOCH_HARVESTER", vm.toString(address(d.harvester)));
        vm.setEnv("RECOUP_LIQUIDATION_AUCTION", vm.toString(address(d.auction)));
    }

    /// @dev Everything a `WirePhase4` entry point reads, in one call, so it can sit on the line
    ///      immediately before the script call it feeds. The environment is process-global and
    ///      `forge test` runs a suite's functions in parallel, so any gap between an export and its
    ///      use is a window for a sibling's `_clearScriptEnv` - measured, not theorised.
    /// @dev The script resolves governance parameters the same way a deploy does, and it runs off
    ///      anvil here, so they have to be supplied rather than defaulted.
    function _exportParams() internal {
        vm.setEnv("RECOUP_YIELD_RECIPIENT", vm.toString(treasury));
        vm.setEnv("RECOUP_KEEPER", vm.toString(keeper));
        vm.setEnv("RECOUP_NAV_CONFIRMER", vm.toString(navConfirmer));
        vm.setEnv("RECOUP_PROTOCOL_FEE_WALLET", vm.toString(treasury));
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
