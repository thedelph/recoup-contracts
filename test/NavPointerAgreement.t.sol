// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @title NavPointerAgreement
/// @notice All three NAV readers must answer the same feed, and the vault's answer is the one they
///         are all measured against.
/// @dev **Audit round 21's headline, and the sibling of `RiskPointerAgreement` next to it.** Round
///      20 anchored `riskParams` at six wiring sites plus a script assertion. `navOracle` is the
///      identical shape - the other `immutable` constructor seed all three of the vault, the
///      manager and the auction carry - and it had **none** of it: no constructor check, no setter
///      check, nothing on any of the three interfaces, and not one line of
///      `DeployBase._assertCoreGraph`, which spends six lines on the risk readers and asserts
///      `oracle.keeper()` and `oracle.navConfirmer()` while never comparing the three nav readers.
///      It was therefore strictly weaker than `riskParams` had been *before* round 20, which at
///      least had the script assertion.
///
///      **Why the divergence is silent.** Each contract reads its own feed for a different,
///      non-overlapping job, so nothing anywhere compares two of them and nothing reverts. The
///      vault values collateral and decides liquidatability (`withdrawBonds`,
///      `_requireLiquidatable`, `collateralValue`); the manager reads its feed for `borrow`'s
///      `isStale()` gate and nothing else; the auction strikes the whole Dutch curve in `start`
///      and freezes it for the auction's life.
///
///      **Measured before the fix, on this repository's own `LiquidationAuctionTest` fixture:**
///      with the auction one order of magnitude behind the vault, a lot worth 943.125000 USDC sold
///      for 94.312500, 534.437500 of principal was written off and the bidder took the whole
///      100-bond lot for a net gain of 848.812500. The control - the identical liquidation on the
///      shipped single-feed wiring - paid 943.125000 and wrote off nothing. The ratio scales with
///      the divergence, so that is a sample and not a bound.
///
///      **Why the vault is the reference.** Same reason as the risk pointer: there is no
///      `setCollateralVault` anywhere and the vault pointer is `immutable` on both the manager and
///      the auction, so the vault is the only contract in the graph that cannot be replaced. Two
///      replaceable contracts checking each other can agree with each other while both disagree
///      with the collateral they are pricing.
///
///      **Why both a constructor check and a setter check.** The constructor makes an honest
///      deployment fail at deploy time under the deployer's own hand and means every honestly
///      built consumer in existence agrees with its vault; the setter is what closes the hazard,
///      because a stub can answer a constructor however it likes and because `navOracle()` on an
///      arbitrary address is not obliged to give the same answer twice - see
///      `test_setter_catchesAFeedThatChangesItsAnswerAfterInstallation`.
contract NavPointerAgreementTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal liquidity;
    RiskParams internal riskParams;

    /// @dev The feed the collateral is priced against, and the one the vault is welded to.
    MockNavOracle internal oracle;
    /// @dev A second, perfectly well-formed feed. Nothing is wrong with it except that it is not
    ///      the one the collateral is priced against, which is the entire finding.
    MockNavOracle internal foreign;

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
        foreign = new MockNavOracle(NAV);

        riskParams = _deployRiskParams(admin);

        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Borrowing power at the ceiling, read from the live authority rather than written down.
    function _maxBorrow() internal view returns (uint256) {
        return (BONDS * NAV * maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    /// @dev The NAV at which `debt` against `BONDS` sits at exactly `ltvBps`.
    function _navAtLtv(uint256 debt, uint256 ltvBps) internal pure returns (uint256) {
        return (debt * Config.BPS * Config.USDC_TO_NAV_SCALE) / (ltvBps * BONDS);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. The deployment leg: a reader on a second feed cannot be built at all.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The auction and the manager round 21 executed cannot even be constructed now.
    /// @dev Both take the vault as an `immutable` constructor argument, so the reference is already
    ///      in hand at the moment the divergence would be introduced.
    function test_constructor_refusesAReaderThatDisagreesWithItsOwnVault() public {
        vm.expectRevert(abi.encodeWithSelector(CreditManager.NavOracleVaultMismatch.selector, address(oracle)));
        new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(foreign)), IRiskParams(address(riskParams)), admin
        );

        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NavOracleVaultMismatch.selector, address(oracle)));
        new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(foreign)), IRiskParams(address(riskParams)), admin
        );
    }

    /// @notice And the matching pair still deploys, which is the half that makes the check useful.
    function test_constructor_admitsAReaderThatAgrees() public {
        CreditManager m = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        LiquidationAuction a = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        assertEq(address(m.navOracle()), address(vault.navOracle()), "manager");
        assertEq(address(a.navOracle()), address(vault.navOracle()), "auction");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. The four setters. These are what actually close the hazard: a consumer nobody
    //    installs prices nothing, and a stub can answer a constructor however it likes.
    // ─────────────────────────────────────────────────────────────────────────

    function test_vaultSetCreditManager_refusesADisagreeingManager() public {
        NavLyingManager liar = new NavLyingManager(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerNavOracleMismatch.selector, address(foreign))
        );
        vault.setCreditManager(address(liar));
    }

    function test_vaultSetLiquidationAuction_refusesADisagreeingAuction() public {
        NavLyingAuction liar = new NavLyingAuction(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.LiquidationAuctionNavOracleMismatch.selector, address(foreign))
        );
        vault.setLiquidationAuction(address(liar));
    }

    function test_managerSetLiquidationAuction_refusesADisagreeingAuction() public {
        NavLyingAuction liar = new NavLyingAuction(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LiquidationAuctionNavOracleMismatch.selector, address(foreign))
        );
        credit.setLiquidationAuction(address(liar));
    }

    /// @notice `CreditManager.setLiquidationAuction`'s own check does work no other clause does.
    /// @dev Written after the neuter run, because the neuter of that guard alone did **not** show
    ///      "did not revert as expected" - it showed `LiquidationAuctionIncomplete()`, because
    ///      `NavLyingAuction` deliberately answers none of the three `_impairmentFor` probes below
    ///      it. Red is red, but a guard whose only demonstration is a test that would fail on a
    ///      later clause anyway has not been shown to be load-bearing. This auction answers every
    ///      probe on the path, so the nav check is the only thing left that can refuse it.
    function test_managerSetLiquidationAuction_refusesAFullyFormedAuctionOnASecondFeed() public {
        CompleteNavLyingAuction liar = new CompleteNavLyingAuction(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LiquidationAuctionNavOracleMismatch.selector, address(foreign))
        );
        credit.setLiquidationAuction(address(liar));
    }

    /// @notice The fourth setter, and the one whose check is only reachable by a pointer that
    ///         changes its mind.
    /// @dev `LiquidationAuction.setCreditManager` refuses any manager that is not already the
    ///      vault's live one, and the vault's own setter has by then insisted the manager agrees.
    ///      So an honest-but-wrong manager can never reach this line. What can is an address whose
    ///      `navOracle()` is not a constant: it answers correctly for the vault's setter and
    ///      differently afterwards. The real `CreditManager` holds the pointer `immutable`, so this
    ///      guard is defence against the shape rather than against that contract - which is exactly
    ///      the point of a setter that installs an arbitrary address.
    function test_setter_catchesAFeedThatChangesItsAnswerAfterInstallation() public {
        TwoFacedNavManager liar = new TwoFacedNavManager(address(vault), address(riskParams), address(oracle));

        vm.prank(admin);
        vault.setCreditManager(address(liar));
        assertEq(vault.creditManager(), address(liar), "premise: an agreeing manager installs");

        liar.setNavOracle(address(foreign));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationAuction.CreditManagerNavOracleMismatch.selector, address(foreign))
        );
        auction.setCreditManager(address(liar));

        // And the refusal is not a weld: telling the truth again is enough to proceed.
        liar.setNavOracle(address(oracle));
        vm.prank(admin);
        auction.setCreditManager(address(liar));
        assertEq(auction.creditManager(), address(liar), "the remedy for the refusal was not available");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. The guard must not pin its own bug open, and it must not forbid a legal end
    //    state. Five of round 20's prescriptions failed the second of those, so it is
    //    built and executed rather than argued.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Every refusal above leaves the correct wiring immediately available.
    function test_theRefusalIsNeverAWeld() public {
        NavLyingManager liarM = new NavLyingManager(address(vault), address(foreign));
        NavLyingAuction liarA = new NavLyingAuction(address(vault), address(foreign));

        CreditManager honestM = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        LiquidationAuction honestA = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        vm.startPrank(admin);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerNavOracleMismatch.selector, address(foreign))
        );
        vault.setCreditManager(address(liarM));
        vault.setCreditManager(address(honestM));
        assertEq(vault.creditManager(), address(honestM), "the vault's manager leg welded shut");

        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.LiquidationAuctionNavOracleMismatch.selector, address(foreign))
        );
        vault.setLiquidationAuction(address(liarA));
        vault.setLiquidationAuction(address(honestA));
        assertEq(vault.liquidationAuction(), address(honestA), "the vault's auction leg welded shut");

        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LiquidationAuctionNavOracleMismatch.selector, address(foreign))
        );
        honestM.setLiquidationAuction(address(liarA));
        honestM.setLiquidationAuction(address(honestA));
        assertEq(honestM.liquidationAuction(), address(honestA), "the manager's auction leg welded shut");

        honestA.setCreditManager(address(honestM));
        assertEq(honestA.creditManager(), address(honestM), "the auction's manager leg welded shut");

        vm.stopPrank();
    }

    /// @notice The anchor forbids nothing that was reachable, before or after a full migration.
    /// @dev **The single most important test in this file.** Five of round 20's prescribed fixes
    ///      failed by making a legal end state unreachable, so the way this one could be wrong is
    ///      known in advance and is measured rather than asserted in prose. It cannot be wrong for
    ///      a structural reason: the reference is a fixed address on a contract that can never be
    ///      replaced, so "agrees with the vault" is satisfiable at any moment by anyone who can
    ///      deploy. This walks a whole manager+auction migration in the deploy script's own order
    ///      and then borrows and liquidates through the migrated graph, so the property being
    ///      checked is "the new protocol works", not "the new pointers are equal".
    function test_theWholeMigrationIsStillReachableAndTheMigratedGraphWorks() public {
        address anchor = address(vault.navOracle());
        assertEq(address(credit.navOracle()), anchor, "shipped wiring: manager disagrees");
        assertEq(address(auction.navOracle()), anchor, "shipped wiring: auction disagrees");

        CreditManager creditB = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(anchor), IRiskParams(address(riskParams)), admin
        );
        LiquidationAuction auctionB = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(anchor), IRiskParams(address(riskParams)), admin
        );

        vm.startPrank(admin);
        vault.setCreditManager(address(creditB));
        vault.setLiquidationAuction(address(auctionB));
        creditB.setLiquiditySource(address(liquidity));
        creditB.setEpochHarvester(harvester);
        creditB.setLiquidationAuction(address(auctionB));
        auctionB.setCreditManager(address(creditB));
        liquidity.setCreditManager(address(creditB));
        vm.stopPrank();

        assertEq(address(vault.navOracle()), anchor, "vault");
        assertEq(address(creditB.navOracle()), anchor, "post-migration: manager disagrees");
        assertEq(address(auctionB.navOracle()), anchor, "post-migration: auction disagrees");

        // And the migrated protocol is not a museum piece: a genuinely underwater position fills.
        uint256 debt = _maxBorrow();
        vm.prank(alice);
        creditB.borrow(debt);

        oracle.setNav(_navAtLtv(debt, 7_000));
        vm.prank(keeper);
        creditB.liquidate(alice);
        uint256 id = auctionB.auctionOf(alice);
        assertGt(id, 0, "no auction opened");

        usdc.mint(bidder, 10_000e6);
        vm.startPrank(bidder);
        usdc.approve(address(auctionB), type(uint256).max);
        auctionB.bid(id);
        vm.stopPrank();

        assertEq(auctionB.auctionOf(alice), 0, "the auction did not settle");
        assertEq(vault.bondCount(alice), 0, "the lot was not seized");
        assertEq(auctionB.liveAuctionCount(), 0, "live work outstanding");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. The end states the finding is about, asserted unreachable.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The lot sold at a tenth of its value cannot be staged, from either direction.
    /// @dev The measured attack was an auction whose feed was an order of magnitude behind the
    ///      vault's, filling a 943.125000 lot for 94.312500 and writing off 534.437500. There is no
    ///      such auction to fill from now: it is refused at its own constructor, and refused again
    ///      at both setters if something else manages to produce one.
    function test_theDivergentAuctionCannotBeStagedAtAll() public {
        foreign.setNav(NAV / 10);

        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NavOracleVaultMismatch.selector, address(oracle)));
        new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(foreign)), IRiskParams(address(riskParams)), admin
        );

        NavLyingAuction liar = new NavLyingAuction(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.LiquidationAuctionNavOracleMismatch.selector, address(foreign))
        );
        vault.setLiquidationAuction(address(liar));

        // Nothing moved, and the graph still prices off one feed.
        assertEq(vault.liquidationAuction(), address(auction), "the vault's auction moved");
        assertEq(address(auction.navOracle()), address(vault.navOracle()), "auction disagrees with the vault");
        assertEq(
            auction.navOracle().navPerBond(), vault.navOracle().navPerBond(), "two answers to one price"
        );
    }

    /// @notice The manager-side half, which is the quiet one: `borrow`'s staleness gate.
    /// @dev Measured before the fix: with the vault's feed stale and the manager's fresh, `borrow`
    ///      wrote a loan against a price `NAV_STALENESS` had already disowned; with the manager's
    ///      stale and the vault's fresh, `borrow` reverted `NavStale()` over a book nothing was
    ///      wrong with, repairable only by another migration. Neither state can be entered now, so
    ///      the assertion is that the divergence itself is unreachable and that staleness is one
    ///      fact about the protocol rather than two.
    function test_theStalenessGateCannotBeSplitInTwo() public {
        vm.expectRevert(abi.encodeWithSelector(CreditManager.NavOracleVaultMismatch.selector, address(oracle)));
        new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(foreign)), IRiskParams(address(riskParams)), admin
        );

        NavLyingManager liar = new NavLyingManager(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerNavOracleMismatch.selector, address(foreign))
        );
        vault.setCreditManager(address(liar));

        // One feed, so one answer. Staleness moves the whole protocol at once, in both directions.
        oracle.setStale(true);
        assertTrue(vault.navOracle().isStale(), "the vault's feed");
        assertTrue(credit.navOracle().isStale(), "the manager reads a different feed");
        uint256 debt = _maxBorrow();
        vm.expectRevert(CreditManager.NavStale.selector);
        vm.prank(alice);
        credit.borrow(debt);

        oracle.setStale(false);
        assertFalse(credit.navOracle().isStale(), "the manager stayed stale on a fresh feed");
        vm.prank(alice);
        credit.borrow(debt);
        assertEq(credit.debtOf(alice), debt, "borrowing did not resume with the feed");
    }
}

/// @notice A manager that answers every incoming check the vault makes and names a foreign feed.
/// @dev Deliberately not a real `CreditManager`: the constructor check makes the real contract
///      unable to express this state, and the whole point of the setter check is that an arbitrary
///      address can. `riskParams` is taken from the vault so it agrees - the risk check sits one
///      line above the nav check, and this stub has to fail on the clause it is about.
///      `accYieldPerBond` reads zero so the virgin check below would pass too.
contract NavLyingManager {
    address public immutable vault;
    address public immutable riskParams;
    address public navOracle;
    uint256 public accYieldPerBond;
    uint256 public totalDebt;
    uint256 public totalBountyParked;

    constructor(address vault_, address navOracle_) {
        vault = vault_;
        riskParams = address(ICollateralVault(vault_).riskParams());
        navOracle = navOracle_;
    }
}

/// @notice The auction-shaped twin of `NavLyingManager`.
/// @dev Answers `vault()`, `riskParams()` and `navOracle()` only. The three `_impairmentFor` probes
///      on `CreditManager.setLiquidationAuction` sit *below* the nav check, so this must not answer
///      them: if it did, a regression that moved the nav check below the probes would still show
///      green here.
contract NavLyingAuction {
    address public immutable vault;
    address public immutable riskParams;
    address public navOracle;
    uint256 public liveAuctionCount;
    uint256 public openWorkoutCount;

    constructor(address vault_, address navOracle_) {
        vault = vault_;
        riskParams = address(ICollateralVault(vault_).riskParams());
        navOracle = navOracle_;
    }
}

/// @notice A manager whose `navOracle()` is not a constant.
/// @dev The only shape that can reach `LiquidationAuction.setCreditManager`'s nav check, because
///      that setter refuses any manager the vault has not already accepted. It exists to show the
///      check is live rather than dead code: `navOracle` is `immutable` on the real `CreditManager`,
///      but a setter that installs an arbitrary address cannot assume that of the address it is
///      installing.
contract TwoFacedNavManager {
    address public immutable vault;
    address public riskParams;
    address public navOracle;
    uint256 public accYieldPerBond;
    uint256 public totalDebt;
    uint256 public totalBountyParked;

    constructor(address vault_, address riskParams_, address navOracle_) {
        vault = vault_;
        riskParams = riskParams_;
        navOracle = navOracle_;
    }

    function setNavOracle(address navOracle_) external {
        navOracle = navOracle_;
    }
}

/// @notice `NavLyingAuction` with the whole impairment surface answered.
/// @dev Exists so `CreditManager.setLiquidationAuction`'s nav check can be shown to refuse
///      something no other clause on that path would. Answering the probes is the entire
///      difference: `NavLyingAuction` must stay bare, because a regression moving the nav check
///      below the probes has to show red somewhere, and that is the test it shows red in.
contract CompleteNavLyingAuction {
    address public immutable vault;
    address public immutable riskParams;
    address public navOracle;
    uint256 public liveAuctionCount;
    uint256 public openWorkoutCount;

    constructor(address vault_, address navOracle_) {
        vault = vault_;
        riskParams = address(ICollateralVault(vault_).riskParams());
        navOracle = navOracle_;
    }

    function workoutsOpenFor(address) external pure returns (uint256) {
        return 0;
    }

    function auctionOf(address) external pure returns (uint256) {
        return 0;
    }

    function recognisedRecoveryOf(address) external pure returns (uint256) {
        return 0;
    }
}
