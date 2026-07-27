// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {Config} from "../src/Config.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Proves the six skeletons deploy and wire together, and that the few
///         implemented views behave. Business-logic tests arrive with each phase.
contract SkeletonsTest is Test {
    address internal admin = makeAddr("admin");

    MockUSDC internal usdc;
    MockBond internal bond;
    NAVOracle internal oracle;
    CollateralVault internal vault;
    CreditManager internal credit;
    LenderPool internal pool;
    EpochHarvester internal harvester;
    LiquidationAuction internal auction;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        oracle = new NAVOracle(admin);
        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        pool = new LenderPool(usdc, admin);
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        auction =
            new LiquidationAuction(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);

        vm.startPrank(admin);
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(address(harvester));
        harvester.setLenderPool(address(pool));
        auction.setCreditManager(address(credit));
        vm.stopPrank();
    }

    function test_wiring() public view {
        assertEq(address(vault.navOracle()), address(oracle));
        assertEq(vault.creditManager(), address(credit));
        assertEq(credit.lenderPool(), address(pool));
        assertEq(pool.creditManager(), address(credit));
        assertEq(auction.creditManager(), address(credit));
        assertEq(harvester.lenderPool(), address(pool));
    }

    function test_lenderPoolIsErc4626OverUsdc() public view {
        assertEq(pool.asset(), address(usdc));
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.symbol(), "rcUSDC");
    }

    function test_freshOracleIsStale() public view {
        // lastUpdated == 0 ⇒ stale until first post; borrow() gates on this, which is
        // what stops a position being priced against a NAV of zero. No warp: the
        // point is that it reads stale immediately, not only once time has passed.
        assertTrue(oracle.isStale());
    }

    function test_freshOracleStaysStaleAfterTheWindow() public {
        vm.warp(Config.NAV_STALENESS + 1);
        assertTrue(oracle.isStale());
    }

    function test_stubsRevertNotImplemented() public {
        // liquidate() is the remaining phase-3 stub on CreditManager.
        vm.expectRevert(CreditManager.NotImplemented.selector);
        credit.liquidate(address(this));

        // harvestRange stays unimplemented on purpose: distributeYield settles every
        // position in one write, so there is no per-position iteration to paginate.
        vm.expectRevert(EpochHarvester.NotImplemented.selector);
        harvester.harvestRange(0, 1);
    }

    function test_borrowRefusesUntilLiquiditySourceIsWired() public {
        // A CreditManager with no funding source must refuse rather than half-work:
        // this fixture never wires one, unlike the deploy script.
        vm.expectRevert(CreditManager.LiquiditySourceUnset.selector);
        credit.borrow(1);
    }

    function test_vaultRequiresAdapterBeforeUse() public {
        // CollateralVault is implemented (phase 1); without a custody adapter
        // wired it must refuse to take deposits rather than strand funds.
        vm.expectRevert(CollateralVault.AdapterNotSet.selector);
        vault.depositBonds(1);
    }

    function test_onlyRoleGatesOnStubs() public {
        // yield distribution is EpochHarvester-only
        vm.expectRevert(CreditManager.NotEpochHarvester.selector);
        credit.distributeYield(1);

        // seize is LiquidationAuction-only
        vm.expectRevert(CollateralVault.NotLiquidationAuction.selector);
        vault.seize(address(this), address(this));

        // lend is CreditManager-only
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.lend(1);
    }
}
