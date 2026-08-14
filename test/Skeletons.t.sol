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
import {ILenderPool} from "../src/interfaces/ILenderPool.sol";
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
        // liquidate() is implemented as of phase 3. It reaches its own gate rather
        // than a stub - with no debt there is nothing to liquidate, and that is the
        // first thing it checks.
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.liquidate(address(this));

        // harvestRange stays unimplemented on purpose: distributeYield settles every
        // position in one write, so there is no per-position iteration to paginate.
        vm.expectRevert(EpochHarvester.NotImplemented.selector);
        harvester.harvestRange(0, 1);

        // The LenderPool's protocol flows are the remaining phase-4 stubs *in this repository*.
        // The pool is finished in the private tree; it is held back from publication while one
        // finding against it is open, so what ships here is still the dormant skeleton and
        // `queuePosition` still reverts.
        vm.expectRevert(LenderPool.NotImplemented.selector);
        pool.queuePosition(address(this));
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

    // ── ILenderPool conformance ──────────────────────────────────────────────
    //
    // Round 11: `LenderPool` implemented `ILenderPool` by intention alone, so nothing checked, and
    // both protocol call sites into the pool swallow a failed call in a `catch` - a drifted
    // signature would have shown up as a payment that silently never happened rather than as a
    // build failure. The declaration is the fix.
    //
    // Two of the three tests that make the declaration observable are not in this repository,
    // because both need the finished pool: one type-checks the implicit conversion that only
    // compiles while `LenderPool is ILenderPool`, and one reads a `YieldDistributed` log off a
    // pool that actually distributed something. The skeleton published here is deliberately not
    // `is ILenderPool` and cannot distribute. What survives the omission is the test below, which
    // is the one that pins the published ABI itself - it reads only the interface, so it holds the
    // topics an indexer would build against whether or not the implementation ships with it.

    /// @dev **The assertion the drift needed and did not have.** `ILenderPool` published
    ///      `YieldDistributed(uint256)` while the contract emitted three parameters. A different
    ///      arity is a different `topic0`, so every other test in this repo passed - they read
    ///      storage, or they match on the declaration they were compiled against, which is the one
    ///      that drifted. Only an indexer built from the published ABI would have noticed, by
    ///      seeing no yield events at all.
    ///
    ///      So this pins the topic against a **string literal**, not against the declaration. The
    ///      literal is the published ABI: changing the event's shape has to break this test on
    ///      purpose, which is the moment to think about who is already matching on the old topic.
    function test_lenderPoolEventTopicsMatchThePublishedAbi() public pure {
        assertEq(
            ILenderPool.YieldDistributed.selector,
            keccak256("YieldDistributed(uint256,uint256,uint256)"),
            "three parameters: amount, ratePerSecond, streamEndsAt"
        );

        assertEq(ILenderPool.Lent.selector, keccak256("Lent(uint256)"));
        assertEq(ILenderPool.PrincipalRepaid.selector, keccak256("PrincipalRepaid(uint256)"));
        assertEq(ILenderPool.PrincipalSurplusStreamed.selector, keccak256("PrincipalSurplusStreamed(uint256)"));
        assertEq(ILenderPool.Impaired.selector, keccak256("Impaired(address,uint256,uint256)"));
        assertEq(ILenderPool.ImpairmentReleased.selector, keccak256("ImpairmentReleased(address,uint256,uint256)"));
        assertEq(ILenderPool.LossReservesSet.selector, keccak256("LossReservesSet(uint256,uint256,uint256)"));
        assertEq(ILenderPool.LossSocialised.selector, keccak256("LossSocialised(uint256)"));
        assertEq(ILenderPool.WithdrawalQueued.selector, keccak256("WithdrawalQueued(address,uint256,uint256)"));
        assertEq(
            ILenderPool.QueuedWithdrawalServiced.selector,
            keccak256("QueuedWithdrawalServiced(address,uint256,uint256)")
        );
        assertEq(
            ILenderPool.WithdrawalRequestCancelled.selector,
            keccak256("WithdrawalRequestCancelled(address,uint256,uint256)")
        );
        assertEq(
            ILenderPool.QueuedWithdrawalReleasedAsDust.selector,
            keccak256("QueuedWithdrawalReleasedAsDust(address,uint256,uint256)")
        );
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
