// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {DeployTestnet} from "../script/Deploy.s.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {Config} from "../src/Config.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

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

    function test_deployHandsEverythingToTheConfiguredOwner() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));
        _assertWiring(d, _params());

        assertEq(d.vault.owner(), owner);
        assertEq(d.adapter.owner(), owner);
        assertEq(d.oracle.owner(), owner);
        assertEq(d.credit.owner(), owner);
        assertEq(d.pool.owner(), owner);
        assertEq(d.harvester.owner(), owner);
        assertEq(d.auction.owner(), owner);
        assertEq(d.liquidity.owner(), owner);
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
    function test_deployLeavesNothingOwnedByTheDeployer() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        assertTrue(d.vault.owner() != address(this));
        assertTrue(d.adapter.owner() != address(this));
        assertTrue(d.oracle.owner() != address(this));
        assertTrue(d.credit.owner() != address(this));
        assertTrue(d.pool.owner() != address(this));
        assertTrue(d.harvester.owner() != address(this));
        assertTrue(d.auction.owner() != address(this));
        // Round 10, finding 5. This list had seven entries and the deployment has eight `Ownable`
        // contracts. The missing one holds the whole lending float behind an uncapped
        // `onlyOwner withdraw(to, amount)` - so this test asserted "the deployer owns nothing"
        // while the deployer owned the money, and `_assertWiring` agreed with it.
        assertTrue(d.liquidity.owner() != address(this));
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
    function test_deploy_phase4SwitchoverWiresAllThreeLegsTogether() public {
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

        vm.startPrank(owner);
        vm.expectRevert();
        d.vault.renounceOwnership();
        vm.expectRevert();
        d.adapter.renounceOwnership();
        vm.expectRevert();
        d.oracle.renounceOwnership();
        vm.expectRevert();
        d.credit.renounceOwnership();
        vm.expectRevert();
        d.pool.renounceOwnership();
        vm.expectRevert();
        d.harvester.renounceOwnership();
        vm.expectRevert();
        d.auction.renounceOwnership();
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

        // The contracts must accept the script as their owner for its three calls to be
        // authorised, exactly as a real run is made by whoever owns them.
        script.run();

        assertEq(d.credit.liquiditySource(), address(d.pool), "the pool funds the book");
        assertEq(d.credit.lenderPool(), address(d.pool), "and takes the losses on it");
        assertEq(d.harvester.lenderPool(), address(d.pool), "and is paid for both");

        // And the read-only form answers on the state the run left, which is the shape a timelocked
        // switchover actually takes: three queued calls, then a separate check.
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
