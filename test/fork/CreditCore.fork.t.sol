// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockLiquidationAuction} from "../mocks/MockLiquidationAuction.sol";
import {Config} from "../../src/Config.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {NAVOracle} from "../../src/NAVOracle.sol";
import {TreasuryLiquiditySource} from "../../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";
import {RiskParams} from "../../src/RiskParams.sol";
import {IRiskParams} from "../../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "../helpers/RiskParamsFixture.sol";

/// @notice PRD §12's Phase 2 exit criterion: borrow, repay and yield-application on a
///         mainnet fork. Run with:
///           RUN_FORK_TESTS=true BASE_RPC_URL=<rpc> forge test --mc CreditCoreFork -vv
///
///         Everything here is the real thing except the price and the lending float:
///         real DexFi bond and farm contracts, real streamed USDC, the real NAVOracle
///         with its deviation budget and second key. NAV is seeded from the 2026-07-24
///         snapshot because DexFi publishes no on-chain NAV - that gap is exactly what
///         the keeper exists to close, and why its figure must be independently
///         reconciled rather than read from DexFi.
contract CreditCoreForkTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 50_000e6;

    /// @dev Borrowing power at the ceiling, derived rather than written down.
    ///
    ///      **This was the literal `880.25e6` - 35% of $2,515 - and it went on being 35% after the
    ///      ceiling moved to 25% on 2026-08-07.** That change derived the same figure in 53 unit
    ///      tests and 14 CreditManager tests, and missed the fork suite entirely, so these four
    ///      tests had been reverting `ExceedsMaxLtv` ever since while the README went on
    ///      claiming ten green fork tests. Fork tests are skipped unless `RUN_FORK_TESTS=true` and
    ///      CI does not set it, so nothing said otherwise.
    ///
    ///      The ratchet is expected to move the LTV ceiling at least twice more, which is exactly
    ///      why this must not be a number - and, since that ceiling became storage on `RiskParams`,
    ///      why it can no longer even be a `constant`: a Solidity constant cannot read a storage
    ///      slot. It is a `view` call through the fixture instead, re-read every time, so a test
    ///      that moves the parameter partway through still computes against the live figure.
    function _scenarioMaxBorrow() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    IDexFiBond internal bond = IDexFiBond(Config.DEXFI_BOND_NFT);
    IDexFiFarm internal farm = IDexFiFarm(Config.DEXFI_FARM);
    IERC20 internal usdc = IERC20(Config.USDC_BASE);

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");
    address internal harvester = makeAddr("harvester");

    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    NAVOracle internal oracle;
    TreasuryLiquiditySource internal liquidity;
    RiskParams internal riskParams;

    bool internal run;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    /// @dev `address(0)` skips the inherited fixture-decay detector, matching how every test in
    ///      this file self-skips without `RUN_FORK_TESTS`: the detector needs a live setter owner
    ///      and there is no deployed `RiskParams` at all until the fork is selected.
    function _riskParamsOwner() internal view override returns (address) {
        return address(0);
    }

    function setUp() public {
        run = vm.envOr("RUN_FORK_TESTS", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));

        // makeAddr keys are public and some carry EIP-7702 delegations on Base, which
        // then fail ERC-1155 receiver checks. Strip them so these behave as plain EOAs.
        vm.etch(alice, "");
        vm.etch(admin, "");
        vm.etch(harvester, "");

        oracle = new NAVOracle(admin);
        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(bond, INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin);
        adapter = new DirectCallAdapter(bond, farm, usdc, address(vault), admin, harvester);
        credit = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        // The vault refuses an auction pointer that is not a contract bound back to it,
        // so suites that never run a liquidation still need a stand-in.
        MockLiquidationAuction auctionStub = new MockLiquidationAuction();
        auctionStub.setVault(address(vault));
        // Audit round 20: the setters also check the risk authority agrees with the vault's.
        auctionStub.setRiskParams(address(riskParams));
        // Audit round 21: and the NAV feed, anchored on the vault's answer.
        auctionStub.setNavOracle(address(vault.navOracle()));
        auctionStub.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auctionStub));
        // Both sides. An auction the vault names while the manager does not is a
        // half-finished migration, and `borrow` refuses in it.
        credit.setLiquidationAuction(address(auctionStub));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        liquidity.setCreditManager(address(credit));
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(NAV);
        vm.stopPrank();

        // §14 ask #5, impersonated: DexFi whitelists the custody adapter.
        address[] memory accounts = new address[](1);
        accounts[0] = address(adapter);
        vm.prank(Config.DEXFI_TREASURY_EOA);
        bond.addWhitelist(accounts);

        // Real bond units for alice. The farm holds the staked supply and is
        // whitelisted, so a farm-originated transfer passes the gate.
        vm.prank(Config.DEXFI_FARM);
        bond.safeTransferFrom(Config.DEXFI_FARM, alice, Config.DEXFI_BOND_TOKEN_ID, BONDS, "");
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);

        // Fund the lending float with real USDC.
        deal(Config.USDC_BASE, address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);
    }

    /// @dev The Phase 2 exit criterion end to end, on live state.
    function test_depositBorrowHarvestApplyRepay() public {
        vm.skip(!run);

        // 1. Deposit real bonds; they stake into the live farm.
        vm.prank(alice);
        vault.depositBonds(BONDS);
        assertEq(adapter.stakedBalance(), BONDS, "staked in the live farm");
        assertTrue(vault.custodyIsSolvent());

        // 2. Borrow against them, at the ceiling `RiskParams` holds today.
        uint256 maxBorrow = _scenarioMaxBorrow();
        vm.prank(alice);
        credit.borrow(maxBorrow);
        // **The disbursement is the loan less the prepaid liquidation bounty, and the debt is the
        // full loan.** That asymmetry is the point of holding the bounty off the debt ledger.
        //
        // This line asserted the borrower received `maxBorrow` and had been **failing since the
        // caller bounty landed**, on `origin/main`, with exactly this arithmetic: 603,750,000
        // against an expected 628,750,000, a difference of the 25 USDC charge. Nothing noticed,
        // because CI never sets `RUN_FORK_TESTS` and the fork suite self-skips without it - so
        // `forge test` has reported ten green fork tests while one of them could not run and would
        // not have passed. Verified as pre-existing by running this same test on a pristine
        // `origin/main` worktree before touching it, rather than assuming this change was innocent.
        assertEq(
            usdc.balanceOf(alice),
            maxBorrow - Config.LIQUIDATION_CALL_BOUNTY,
            "USDC received same block, less the prepaid bounty"
        );
        assertEq(credit.debtOf(alice), maxBorrow, "the debt is the full loan, bounty or no bounty");
        assertEq(
            credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "the charge is escrowed, not spent"
        );
        assertEq(credit.currentLtvBps(alice), maxLtvBps(), "sits exactly at maxLTV");
        assertGt(credit.healthFactor(alice), Config.HEALTH_FACTOR_SCALE, "healthy at maxLTV");

        // 3. Let real rewards stream, then harvest them out of the live farm.
        vm.warp(block.timestamp + 7 days);
        assertGt(farm.pendingShare(address(adapter)), 0, "farm accrued real USDC");
        vm.prank(admin);
        uint256 harvested = vault.harvestYield();
        assertGt(harvested, 0, "a week of streamed rewards on 100 bonds");
        assertEq(usdc.balanceOf(harvester), harvested, "reported figure matches what moved");

        // 4. Apply that real yield against the debt, the way EpochHarvester will.
        //    The share is streamed over an epoch rather than credited at once - that
        //    is what makes depositing in the harvest block pointless - so the clock
        //    has to run before any of it has actually been earned.
        uint256 debtBefore = credit.debtOf(alice);
        vm.startPrank(harvester);
        usdc.approve(address(credit), harvested);
        credit.receiveYield(harvested);
        credit.distributeYield(harvested);
        vm.stopPrank();

        credit.settle(alice);
        assertEq(credit.debtOf(alice), debtBefore, "nothing is earned in the harvest block");

        // To the end of the stream, which is not a fixed five days: the pot is rated
        // over the window it accrued across, and this epoch represents the seven days
        // warped above. That is what stops a late depositor capturing a long window.
        vm.warp(credit.streamEndsAt());
        credit.settle(alice);
        // At most 1 wei of USDC is left behind by the stream rate's truncation.
        assertApproxEqAbs(credit.debtOf(alice), debtBefore - harvested, 1, "debt fell by the yield");
        assertLt(credit.currentLtvBps(alice), maxLtvBps(), "self-repaid, LTV improved");

        // 5. Repay the remainder and exit with the bonds.
        uint256 remaining = credit.debtOf(alice);
        deal(Config.USDC_BASE, alice, remaining);
        vm.startPrank(alice);
        usdc.approve(address(credit), remaining);
        credit.repay(remaining);
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebt(), 0);

        vault.withdrawBonds(BONDS);
        vm.stopPrank();
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), BONDS, "collateral returned");

        // 6. Principal finds its way home, and the float is whole again.
        credit.settlePrincipal();
        assertEq(credit.pendingPrincipal(), 0);
        assertGe(usdc.balanceOf(address(liquidity)), FLOAT, "lender float repaid in full");
    }

    /// @dev Borrowing must refuse while the price is unposted or stale, against the
    ///      real oracle rather than a mock with a settable flag.
    function test_borrowRefusedOnStaleNav() public {
        vm.skip(!run);
        vm.prank(alice);
        vault.depositBonds(BONDS);

        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(oracle.isStale());

        vm.prank(alice);
        vm.expectRevert(CreditManager.NavStale.selector);
        credit.borrow(1e6);
    }

    /// @dev The deviation budget and the second key, exercised against real state:
    ///      a large move waits, and the keeper cannot wave it through alone.
    function test_largeNavMoveNeedsTheSecondKey() public {
        vm.skip(!run);

        vm.warp(block.timestamp + 1 days);
        uint256 crashed = NAV / 2; // -50%, far beyond a day's budget

        vm.prank(keeper);
        oracle.postNav(crashed);
        assertEq(oracle.navPerBond(), NAV, "not accepted unilaterally");
        assertEq(oracle.pendingNav(), crashed, "parked for the second key");

        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(confirmer);
        oracle.confirmNav(crashed);
        assertEq(oracle.navPerBond(), crashed, "second key ratified it");
    }
}
