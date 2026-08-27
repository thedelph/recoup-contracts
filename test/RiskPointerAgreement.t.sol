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

/// @title RiskPointerAgreement
/// @notice All three risk readers must answer the same `RiskParams`, and the vault's answer is the
///         one they are all measured against.
/// @dev **Audit round 20's critical 3, and the reason it was a finding rather than an ops note.**
///      `RiskParams.sol`'s own header argues for its design because the three consumers "cannot
///      disagree about what the threshold is, even for one block", and rejects the alternative
///      because its only mitigation would be "a deploy-script assertion - a script-level answer to
///      a contract-level defect". `DeployBase._assertCoreGraph` **is** that assertion for this
///      shape, and it does not run on a migration: a migration is a bare owner transaction with no
///      script around it. Nothing decayed. The argument was wrong when it was written.
///
///      Measured before the fix, on this exact fixture: an ordinary zero-debt manager+auction
///      migration installed a second `RiskParams` with **no refusal at any of the seven wiring
///      calls**. A borrower at LTV 5400 - liquidatable under the auction's 5000, healthy under the
///      vault's ratcheted 5800 - then had every exit shut at once (`bid` and `expireToWorkout`
///      reverting `PositionNotLiquidatable`, `cancel` reverting `StillLiquidatable`, the re-strike
///      reverting `AuctionResetWindowClosed`), and the wiring welded behind it: `setLiquidationAuction`
///      reverted `AuctionHasLiveWork(1)` and `setCreditManager` reverted `CreditManagerHasDebt`.
///      The opposite direction produced a `cancel` that closes an underwater auction for free.
///
///      **Why the vault is the reference and not a symmetric check.** There is no
///      `setCollateralVault` anywhere and the vault pointer is `immutable` on both the manager and
///      the auction, so the vault is the only contract in the graph that cannot be replaced. Two
///      replaceable contracts checking each other can agree with each other while both disagree
///      with the collateral they are pricing.
///
///      **Why both a constructor check and a setter check.** The constructor makes an honest
///      deployment fail at deploy time under the deployer's own hand; the setter is what actually
///      closes the hazard, because a stub can answer the constructor however it likes, and because
///      `riskParams()` on an arbitrary address is not obliged to keep the same answer twice - see
///      `test_setter_catchesAPointerThatChangesItsAnswerAfterInstallation`.
contract RiskPointerAgreementTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 100_000e6;

    /// @dev The ratchet's agreed endpoint, and the value round 20 drove the vault to. Named rather
    ///      than repeated: it is the same endpoint `RiskParams`' hard ceiling names.
    uint256 internal constant RATCHETED_THRESHOLD_BPS = 5_800;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal liquidity;

    /// @dev The authority the vault is welded to, for good.
    RiskParams internal riskParams;
    /// @dev A second, legally-configured authority. Nothing is wrong with it except that it is not
    ///      the one the collateral is priced against, which is the entire finding.
    RiskParams internal foreign;

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
        foreign = _deployRiskParams(admin);

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

    function _ratchetVaultTo(uint256 thresholdBps) internal {
        IRiskParams.Params memory p = riskParams.params();
        p.liquidationThresholdBps = uint16(thresholdBps);
        vm.prank(admin);
        riskParams.setRiskParams(p);
        assertEq(riskParams.liquidationThresholdBps(), thresholdBps, "the vault's authority did not ratchet");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. The deployment leg: a mismatched reader cannot be built at all.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The round-20 migration cannot even be constructed now.
    /// @dev The first line of the fix, and the earliest possible refusal: `CreditManager` and
    ///      `LiquidationAuction` both take the vault as an `immutable` constructor argument, so the
    ///      reference is already in hand at the moment the mismatch would be introduced.
    function test_constructor_refusesAReaderThatDisagreesWithItsOwnVault() public {
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.RiskParamsVaultMismatch.selector, address(riskParams))
        );
        new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(foreign)), admin
        );

        vm.expectRevert(
            abi.encodeWithSelector(LiquidationAuction.RiskParamsVaultMismatch.selector, address(riskParams))
        );
        new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(foreign)), admin
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
        assertEq(address(m.riskParams()), address(vault.riskParams()), "manager");
        assertEq(address(a.riskParams()), address(vault.riskParams()), "auction");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. The four setters. These are what actually close the hazard: a manager or an
    //    auction nobody installs governs nothing, and a stub can answer a constructor
    //    however it likes.
    // ─────────────────────────────────────────────────────────────────────────

    function test_vaultSetCreditManager_refusesADisagreeingManager() public {
        LyingManager liar = new LyingManager(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerRiskParamsMismatch.selector, address(foreign))
        );
        vault.setCreditManager(address(liar));
    }

    function test_vaultSetLiquidationAuction_refusesADisagreeingAuction() public {
        LyingAuction liar = new LyingAuction(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.LiquidationAuctionRiskParamsMismatch.selector, address(foreign))
        );
        vault.setLiquidationAuction(address(liar));
    }

    function test_managerSetLiquidationAuction_refusesADisagreeingAuction() public {
        LyingAuction liar = new LyingAuction(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LiquidationAuctionRiskParamsMismatch.selector, address(foreign))
        );
        credit.setLiquidationAuction(address(liar));
    }

    /// @notice The fourth setter, and the one whose check is only reachable by a pointer that
    ///         changes its mind.
    /// @dev `LiquidationAuction.setCreditManager` refuses any manager that is not already the
    ///      vault's live one, and the vault's own setter has by then insisted the manager agrees.
    ///      So an honest-but-wrong manager can never reach this line. What can is an address whose
    ///      `riskParams()` is not a constant: it answers correctly for the vault's setter and
    ///      differently afterwards. The real `CreditManager` holds the pointer `immutable`, so this
    ///      guard is defence against the shape rather than against that contract - which is
    ///      precisely why it is worth having on a setter that installs an arbitrary address.
    function test_setter_catchesAPointerThatChangesItsAnswerAfterInstallation() public {
        TwoFacedManager liar = new TwoFacedManager(address(vault), address(riskParams));

        vm.prank(admin);
        vault.setCreditManager(address(liar));
        assertEq(vault.creditManager(), address(liar), "premise: an agreeing manager installs");

        liar.setRiskParams(address(foreign));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationAuction.CreditManagerRiskParamsMismatch.selector, address(foreign))
        );
        auction.setCreditManager(address(liar));

        // And the refusal is not a weld: telling the truth again is enough to proceed.
        liar.setRiskParams(address(riskParams));
        vm.prank(admin);
        auction.setCreditManager(address(liar));
        assertEq(auction.creditManager(), address(liar), "the remedy for the refusal was not available");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. The guard must not pin its own bug open. Round 6b's finding, and this repo has
    //    shipped that shape three times, so it is built and escaped rather than argued.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Every refusal above leaves the correct wiring immediately available.
    /// @dev A guard that can be entered and not left is worse than the state it prevents, and the
    ///      remedy has to be reachable from the refused state itself rather than from a fresh
    ///      deployment. Each leg here is exercised *after* its own refusal, in the same test.
    function test_theRefusalIsNeverAWeld() public {
        LyingManager liarM = new LyingManager(address(vault), address(foreign));
        LyingAuction liarA = new LyingAuction(address(vault), address(foreign));

        CreditManager honestM = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        LiquidationAuction honestA = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        vm.startPrank(admin);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerRiskParamsMismatch.selector, address(foreign))
        );
        vault.setCreditManager(address(liarM));
        vault.setCreditManager(address(honestM));
        assertEq(vault.creditManager(), address(honestM), "the vault's manager leg welded shut");

        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.LiquidationAuctionRiskParamsMismatch.selector, address(foreign))
        );
        vault.setLiquidationAuction(address(liarA));
        vault.setLiquidationAuction(address(honestA));
        assertEq(vault.liquidationAuction(), address(honestA), "the vault's auction leg welded shut");

        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LiquidationAuctionRiskParamsMismatch.selector, address(foreign))
        );
        honestM.setLiquidationAuction(address(liarA));
        honestM.setLiquidationAuction(address(honestA));
        assertEq(honestM.liquidationAuction(), address(honestA), "the manager's auction leg welded shut");

        honestA.setCreditManager(address(honestM));
        assertEq(honestA.creditManager(), address(honestM), "the auction's manager leg welded shut");

        vm.stopPrank();
    }

    /// @notice There is no pair of guards here that can only be satisfied one at a time.
    /// @dev The specific worry the round raised, stated so it can be re-run rather than re-argued:
    ///      a check on the risk pointer could in principle demand something the *other* checks on
    ///      the same setter forbid. It cannot, and the reason is structural rather than lucky - the
    ///      reference is a fixed address on a contract that can never be replaced, so "agrees with
    ///      the vault" is always satisfiable by construction, at any moment, by anyone who can
    ///      deploy. This walks a whole migration in the order the deploy script uses, at a
    ///      ratcheted threshold, to show all seven calls still land.
    function test_theWholeMigrationIsStillReachableAtARatchetedThreshold() public {
        _ratchetVaultTo(RATCHETED_THRESHOLD_BPS);

        CreditManager creditB = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        LiquidationAuction auctionB = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
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

        assertEq(address(vault.riskParams()), address(riskParams), "vault");
        assertEq(address(creditB.riskParams()), address(riskParams), "manager");
        assertEq(address(auctionB.riskParams()), address(riskParams), "auction");

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
    // 4. The end state the finding is about, asserted unreachable.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The exact state round 20 measured cannot be entered from any of the seven calls.
    /// @dev The band between two thresholds is what closes all three exits, so this asserts there
    ///      is no such band: whatever route is taken, every installed risk reader answers the
    ///      vault's authority, and therefore there is one answer to "is this position
    ///      liquidatable". The refusal lands on the very first call of the migration, which is why
    ///      the welded follow-on state (`AuctionHasLiveWork` on one setter, `CreditManagerHasDebt`
    ///      on the other) is never reached either.
    function test_theBandBetweenTwoThresholdsIsUnreachable() public {
        _ratchetVaultTo(RATCHETED_THRESHOLD_BPS);

        // The migration round 20 executed, in the order it executed it. It does not get past the
        // constructor now, and would not get past `setCreditManager` if it did.
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.RiskParamsVaultMismatch.selector, address(riskParams))
        );
        new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(foreign)), admin
        );

        LyingManager liar = new LyingManager(address(vault), address(foreign));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerRiskParamsMismatch.selector, address(foreign))
        );
        vault.setCreditManager(address(liar));

        // Nothing moved, and the graph still answers one authority.
        assertEq(vault.creditManager(), address(credit), "the vault's manager moved");
        assertEq(address(credit.riskParams()), address(vault.riskParams()), "manager disagrees with the vault");
        assertEq(address(auction.riskParams()), address(vault.riskParams()), "auction disagrees with the vault");
        assertEq(
            credit.riskParams().liquidationThresholdBps(),
            vault.riskParams().liquidationThresholdBps(),
            "two answers to one question"
        );

        // The position round 20 stranded is simply healthy here, under the one threshold there is.
        uint256 debt = _maxBorrow();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(_navAtLtv(debt, 5_400));
        uint256 ltv = credit.currentLtvBps(alice);
        assertGt(ltv, Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS, "premise: past the pre-ratchet threshold");
        assertLt(ltv, RATCHETED_THRESHOLD_BPS, "premise: short of the ratcheted threshold");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.PositionHealthy.selector, ltv));
        credit.liquidate(alice);
    }

    /// @notice The other route to "an open auction nothing can fill", and it is not a strand.
    /// @dev **Round 20's own lesson, applied to round 20's own fix: when you bound an attack, ask
    ///      what else produces the same end state.** The finding's end state is a live auction that
    ///      `bid`, `expireToWorkout` and `cancel` all refuse. The route it came in by was two
    ///      thresholds; a single authority reaches a position healthy mid-auction too, by the
    ///      threshold being ratcheted. It does *not* reach the same end state, and this pins why.
    ///
    ///      `bid` refuses, exactly as in the finding. `expireToWorkout` then resolves the auction
    ///      as a cancellation rather than refusing it, because its heal branch dispatches on
    ///      `riskParams.liquidationThresholdBps()` and that branch's own docstring calls itself
    ///      "the exact negation of `CollateralVault._requireLiquidatable`" - **which is a true
    ///      statement only while both contracts read the same `RiskParams`**. Under the divergence
    ///      this file's other tests are about, the position was liquidatable by the auction's
    ///      reading and healthy by the vault's, so the heal branch was skipped and the reassign
    ///      below it reverted. That is how a live auction defeated a fix designed to make this exit
    ///      total. The agreement enforced by the wiring setters is what restores it.
    ///
    ///      `cancel` is open here too, so the ratchet route leaves two exits rather than none.
    ///      `RiskParams.setRiskParams` documents that consequence in prose and nothing asserted it.
    function test_aMidAuctionRatchetLeavesTheExitsOpen() public {
        uint256 debt = _maxBorrow();
        vm.prank(alice);
        credit.borrow(debt);

        oracle.setNav(_navAtLtv(debt, 5_400));
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        assertGt(id, 0, "no auction opened");

        // One authority, moved once, in the only direction the ratchet allows.
        _ratchetVaultTo(RATCHETED_THRESHOLD_BPS);
        uint256 ltv = credit.currentLtvBps(alice);
        assertLt(ltv, RATCHETED_THRESHOLD_BPS, "premise: the ratchet did not heal the position");

        usdc.mint(bidder, 10_000e6);
        vm.prank(bidder);
        usdc.approve(address(auction), type(uint256).max);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, ltv));
        auction.bid(id);

        // The exit of last resort resolves rather than refusing, because with one authority its
        // heal branch really is the exact negation of the vault's check.
        vm.warp(block.timestamp + Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.auctionOf(alice), 0, "the lapsed, healed auction was not resolved");
        assertEq(auction.liveAuctionCount(), 0, "live work outstanding");
        assertEq(auction.openWorkoutCount(), 0, "a healed position must not open a workout");

        // And no lot moved: this is a cancellation, not a seizure.
        assertEq(vault.bondCount(alice), BONDS, "the collateral moved on a healed position");
    }

    /// @notice The same route, taking the other of the two open exits.
    /// @dev Asserted separately rather than after the call above, because `expireToWorkout` closes
    ///      the auction and a second exit cannot then be observed at all. Two tests is the only way
    ///      to show two exits.
    function test_aMidAuctionRatchetLeavesCancelOpenToo() public {
        uint256 debt = _maxBorrow();
        vm.prank(alice);
        credit.borrow(debt);

        oracle.setNav(_navAtLtv(debt, 5_400));
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);

        _ratchetVaultTo(RATCHETED_THRESHOLD_BPS);

        auction.cancel(id);
        assertEq(auction.auctionOf(alice), 0, "cancel did not close the auction");
        assertEq(auction.liveAuctionCount(), 0, "live work outstanding");
        assertEq(vault.bondCount(alice), BONDS, "the collateral moved on a healed position");
    }
}

/// @notice A manager that answers every incoming check the vault makes, and names a foreign risk
///         authority.
/// @dev Deliberately not a real `CreditManager`: the constructor check makes the real contract
///      unable to express this state, and the whole point of the setter check is that an arbitrary
///      address can. `accYieldPerBond` reads zero so the virgin check below the risk check would
///      pass - the test must fail on the clause it is about, not on a later one.
contract LyingManager {
    address public immutable vault;
    address public riskParams;
    /// @dev **Audit round 21 added the sibling check for the NAV feed**, which runs immediately
    ///      after the risk one. Agreed by construction so the clause this stub is about is still
    ///      the clause that fires: a stub that disagreed here would be refused a line later and
    ///      these tests would silently stop testing round 20's guard.
    address public immutable navOracle;
    uint256 public accYieldPerBond;
    uint256 public totalDebt;
    uint256 public totalBountyParked;

    constructor(address vault_, address riskParams_) {
        vault = vault_;
        riskParams = riskParams_;
        navOracle = address(ICollateralVault(vault_).navOracle());
    }
}

/// @notice The auction-shaped twin of `LyingManager`.
/// @dev Answers `vault()` and `riskParams()` only. The three `_impairmentFor` probes on
///      `CreditManager.setLiquidationAuction` sit *below* the risk check, so this must not answer
///      them: if it did, a regression that moved the risk check below the probes would still show
///      green here.
contract LyingAuction {
    address public immutable vault;
    address public riskParams;
    /// @dev See `LyingManager`: agreed by construction so the risk clause is the one that fires.
    address public immutable navOracle;
    uint256 public liveAuctionCount;
    uint256 public openWorkoutCount;

    constructor(address vault_, address riskParams_) {
        vault = vault_;
        riskParams = riskParams_;
        navOracle = address(ICollateralVault(vault_).navOracle());
    }
}

/// @notice A manager whose `riskParams()` is not a constant.
/// @dev The only shape that can reach `LiquidationAuction.setCreditManager`'s risk check, because
///      that setter refuses any manager the vault has not already accepted. It exists to show that
///      check is live rather than dead code: `riskParams()` is `immutable` on the real
///      `CreditManager`, but a setter that installs an arbitrary address cannot assume that of the
///      address it is installing.
contract TwoFacedManager {
    address public immutable vault;
    address public riskParams;
    /// @dev See `LyingManager`: agreed by construction so the risk clause is the one that fires.
    address public immutable navOracle;
    uint256 public accYieldPerBond;
    uint256 public totalDebt;
    uint256 public totalBountyParked;

    constructor(address vault_, address riskParams_) {
        vault = vault_;
        riskParams = riskParams_;
        navOracle = address(ICollateralVault(vault_).navOracle());
    }

    function setRiskParams(address riskParams_) external {
        riskParams = riskParams_;
    }

    /// @dev Audit round 22 finding 18 added `yieldAccruedOn` to the tail probes on this pointer.
    ///      A stub that fails an OLDER check makes a test red for the wrong reason, which is the
    ///      note `FourSelectorManager` in `SetterGuards.t.sol` already carries.
    function yieldAccruedOn(uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}
