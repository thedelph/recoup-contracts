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
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Proves the six skeletons deploy and wire together, and that the few
///         implemented views behave. Business-logic tests arrive with each phase.
contract SkeletonsTest is RiskParamsFixture {
    address internal admin = makeAddr("admin");

    MockUSDC internal usdc;
    MockBond internal bond;
    NAVOracle internal oracle;
    CollateralVault internal vault;
    CreditManager internal credit;
    LenderPool internal pool;
    EpochHarvester internal harvester;
    LiquidationAuction internal auction;
    RiskParams internal riskParams;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        oracle = new NAVOracle(admin);
        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        credit = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        pool = new LenderPool(usdc, admin);
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        auction = new LiquidationAuction(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );

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

        // `LenderPool` used to be the remaining phase-4 stub *in this repository*, held back from
        // publication while findings were open against it. It was published on 2026-08-19, when the
        // Base Sepolia redeploy put it on chain and Basescan verification made the source public
        // anyway. So these two are no longer stubs, and the assertions are inverted: they prove the
        // published contract answers, which is what a reader of this file wants to know.
        (uint256 queueIndex, uint256 owed) = pool.queuePosition(address(this));
        assertEq(queueIndex, 0, "an address that has never queued is not in the queue");
        assertEq(owed, 0, "and is owed nothing");

        // `recoverLoss` is `onlyCreditManager`. Reverting for this caller is the guard doing its
        // job rather than a missing body, and naming the selector is what keeps those two apart: a
        // member added to `ILenderPool` and left unimplemented would revert with something else.
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.recoverLoss(1);

        // Deliberately *not* in this list: `exitReserve()`, `totalImpairment()` and
        // `impairedBorrowerCount()`. `CreditManager` probes all three when wiring - two of the
        // probes refuse a pool that cannot answer, and the third would read a reverting address as
        // "not a pool" about the pool itself - so the pool answers them rather than reverting.
        // Zero is the truth for a dormant pool with nothing lent, no marks against it and no
        // leavers to hold anything back from, not a placeholder standing in for missing work.
        assertEq(pool.exitReserve(), 0, "a dormant pool holds nothing back for leavers");
        assertEq(pool.totalImpairment(), 0);
        assertEq(pool.impairedBorrowerCount(), 0);
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
    // Two of the three tests that make the declaration observable are not in this repository
    // yet: one type-checks the implicit conversion that only compiles while
    // `LenderPool is ILenderPool`, and one reads a `YieldDistributed` log off a pool that actually
    // distributed something. Both went when the pool was held back from publication. The pool was
    // published on 2026-08-19 and does declare `is ILenderPool`, so what is left is a port that has
    // not happened. What survives the omission is the test below, which is the one that pins the
    // published ABI itself - it reads only the interface, so it holds the topics an indexer would
    // build against whether or not the implementation ships with it.

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
    ///
    ///      **One line per event the interface declares, and being exhaustive is the property.** An
    ///      event added to `ILenderPool` without a line here leaves this test green while it stops
    ///      covering the ABI, which is the same silence the drift lived in. `LossRecovered` is the
    ///      entry audit round 21 added, and it is here because the round that added the event is
    ///      the only round that will remember to.
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
        assertEq(
            ILenderPool.LossRecovered.selector,
            keccak256("LossRecovered(uint256,uint256)"),
            "two parameters: amount, lifetimeRecovered - not the arity of its counterpart LossSocialised"
        );
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
