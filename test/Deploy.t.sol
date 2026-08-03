// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {DeployTestnet} from "../script/Deploy.s.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
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
    }

    /// @dev Closes the "deploy wiring is incomplete" item: these four setters were
    ///      never called by the old script.
    function test_deployCompletesTheWiringThatWasMissing() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));

        assertEq(address(d.harvester.custodyAdapter()), address(d.adapter));
        assertEq(d.harvester.lenderPool(), address(d.pool));
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

        assertEq(usdc.balanceOf(borrower), 500e6);
        assertEq(d.credit.debtOf(borrower), 500e6);
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
}
