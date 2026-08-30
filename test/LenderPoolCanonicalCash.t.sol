// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract BurnableCanonicalCashUSDC is MockUSDC {
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract CanonicalCashLenderPoolHarness is LenderPool {
    constructor(IERC20 asset_, address owner_) LenderPool(asset_, owner_) {}

    function exposedBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract LenderPoolCanonicalCashTest is Test {
    uint256 internal constant MIN_SUPPLY = (10 ** 3) * Config.BPS;
    uint256 internal constant MAX_CAP = Config.GLOBAL_BORROW_CAP_MAX;
    uint256 internal constant MAX_SHARES_PER_ASSET = Config.MAX_LENDER_SHARES_PER_ASSET;

    address internal manager = makeAddr("manager");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal receiverOne = makeAddr("receiverOne");
    address internal receiverTwo = makeAddr("receiverTwo");
    address internal stranger = makeAddr("stranger");

    BurnableCanonicalCashUSDC internal usdc;
    CanonicalCashLenderPoolHarness internal pool;

    function setUp() public {
        (usdc, pool) = _newPool();
        _fundAndApprove(usdc, pool, alice, 50_000e6);
        _fundAndApprove(usdc, pool, bob, 50_000e6);
        _fundAndApprove(usdc, pool, carol, 50_000e6);
        _fundAndApprove(usdc, pool, harvester, 50_000e6);
        _fundAndApprove(usdc, pool, manager, 50_000e6);
    }

    function _newPool() internal returns (BurnableCanonicalCashUSDC token, CanonicalCashLenderPoolHarness lenderPool) {
        token = new BurnableCanonicalCashUSDC();
        lenderPool = new CanonicalCashLenderPoolHarness(IERC20(address(token)), address(this));
        lenderPool.setCreditManager(manager);
        lenderPool.setEpochHarvester(harvester);
    }

    function _fundAndApprove(
        BurnableCanonicalCashUSDC token,
        CanonicalCashLenderPoolHarness lenderPool,
        address account,
        uint256 amount
    ) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(lenderPool), type(uint256).max);
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        vm.prank(account);
        shares = pool.deposit(assets, account);
    }

    function _deposit(CanonicalCashLenderPoolHarness lenderPool, address account, uint256 assets)
        internal
        returns (uint256 shares)
    {
        vm.prank(account);
        shares = lenderPool.deposit(assets, account);
    }

    function _lend(uint256 amount) internal {
        vm.prank(manager);
        pool.lend(amount);
    }

    function _deliver(uint256 amount) internal {
        vm.prank(harvester);
        pool.distributeYield(amount);
    }

    function _serviceFullAliceClaim() internal returns (uint256 claim) {
        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 serviceable = pool.maxRequestRedeem(alice);
        vm.prank(alice);
        claim = pool.serviceWithdrawalRequest(alice, serviceable, 0);
    }

    function _makeSolventLiquidityDeficit() internal {
        _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        assertEq(_serviceFullAliceClaim(), 1_000e6, "claim fixture");
        _lend(850e6);
        usdc.burn(address(pool), 500e6);
        pool.reconcileCashDeficit();
        assertEq(pool.claimLiquidityDeficit(), 350e6, "liquidity fixture");
        assertEq(pool.claimSolvencyDeficit(), 0, "solvency fixture");
    }

    function _seedMaximumPool() internal {
        pool.setDepositCap(MAX_CAP);
        usdc.mint(alice, MAX_CAP);
        _deposit(alice, MAX_CAP);
    }

    function _loseAndRefill(uint256 amount) internal {
        _lend(amount);
        vm.prank(manager);
        assertEq(pool.socialiseLoss(amount), amount, "loss was not absorbed");

        uint256 refill = pool.maxDeposit(alice);
        assertGt(refill, 0, "loss exposed no refill headroom");
        usdc.mint(alice, refill);
        _deposit(alice, refill);
        assertEq(pool.entryPriceDeficit(), 0, "fair refill broke the quotient bound");
    }

    function _reachMaterialPriceReserve() internal returns (uint256 lent) {
        _seedMaximumPool();

        for (uint256 i; i < 128; ++i) {
            lent = pool.available();
            assertGt(lent, 0, "lending stopped before the reserve fixture");
            _lend(lent);
            if (pool.entryPriceCashReserve() >= MAX_CAP / 4) return lent;

            vm.prank(manager);
            pool.socialiseLoss(lent);
            uint256 refill = pool.maxDeposit(alice);
            assertGt(refill, 0, "reserve fixture lost refill headroom");
            usdc.mint(alice, refill);
            _deposit(alice, refill);
        }

        fail("price reserve fixture was unreachable");
        return 0;
    }

    function test_donationIsInertAcrossEveryCanonicalCashConsumer() public {
        _deposit(alice, 1_000e6);

        uint256 assetsBefore = pool.totalAssets();
        uint256 entryBefore = pool.previewDeposit(100e6);
        uint256 capUsageBefore = pool.depositCapUsage();
        uint256 capBefore = pool.maxDeposit(bob);
        uint256 lendableBefore = pool.available();

        uint256 donation = 5_000e6;
        usdc.mint(stranger, donation);
        vm.prank(stranger);
        usdc.transfer(address(pool), donation);

        assertEq(pool.unmanagedSurplus(), donation, "donation not isolated");
        assertEq(pool.totalAssets(), assetsBefore, "donation changed NAV");
        assertEq(pool.previewDeposit(100e6), entryBefore, "donation changed entry price");
        assertEq(pool.depositCapUsage(), capUsageBefore, "donation consumed cap");
        assertEq(pool.maxDeposit(bob), capBefore, "donation changed cap headroom");
        assertEq(pool.available(), lendableBefore, "donation became lendable");

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(LenderPool.InsufficientLiquidity.selector, lendableBefore + 1, lendableBefore)
        );
        pool.lend(lendableBefore + 1);

        _lend(lendableBefore);
        assertEq(pool.outstandingPrincipal(), lendableBefore, "canonical cash was not lent");
        assertEq(pool.unmanagedSurplus(), donation, "lending consumed the donation");
    }

    function test_cashDeficitClosesEntryUntilExplicitReconciliation() public {
        _deposit(alice, 1_000e6);
        usdc.burn(address(pool), 100e6);

        assertEq(pool.cashDeficit(), 100e6, "deficit view");
        assertEq(pool.maxDeposit(bob), 0, "entry remained open");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.CashDeficitOutstanding.selector, 100e6));
        pool.deposit(1e6, bob);

        (uint256 lost, uint256 yieldWrittenOff) = pool.reconcileCashDeficit();
        assertEq(lost, 100e6, "wrong recognised loss");
        assertEq(yieldWrittenOff, 0, "ordinary cash was called yield");
        assertEq(pool.cashDeficit(), 0, "deficit did not clear");
        assertGt(pool.maxDeposit(bob), 0, "entry did not reopen");

        vm.prank(bob);
        assertGt(pool.deposit(1e6, bob), 0, "post-reconcile entry failed");
    }

    function test_activeStreamReconciliationPreservesRateAndProjectedNav() public {
        _deposit(alice, 1_000e6);
        _deliver(100e6);
        vm.warp(block.timestamp + 1 days);

        uint256 rateBefore = pool.yieldRate();
        uint256 endBefore = pool.yieldStreamEndsAt();
        uint256 unreleasedBefore = pool.unreleasedYield();
        uint256 navBefore = pool.totalAssets();
        uint256 loss = 20e6;
        assertGt(unreleasedBefore, loss, "stream fixture too small");

        usdc.burn(address(pool), loss);
        uint256 projectedNav = pool.totalAssets();
        assertEq(projectedNav, navBefore, "tail did not absorb the projected loss");

        (uint256 lost, uint256 yieldWrittenOff) = pool.reconcileCashDeficit();
        assertEq(lost, loss, "wrong cash loss");
        assertEq(yieldWrittenOff, loss, "tail did not absorb first");
        assertEq(pool.yieldRate(), rateBefore, "reconciliation changed the rate");
        assertLt(pool.yieldStreamEndsAt(), endBefore, "reconciliation did not shorten the end");
        assertEq(pool.unreleasedYield(), unreleasedBefore - loss, "wrong remaining tail");
        assertEq(pool.totalAssets(), projectedNav, "reconciliation stepped projected NAV");
    }

    function test_claimLiquidityAndSolvencyDeficitsHaveDifferentCoverRules() public {
        _makeSolventLiquidityDeficit();

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.ClaimDeficitExceeded.selector, 1, 0));
        pool.coverClaimDeficit(1);

        vm.prank(manager);
        assertEq(pool.socialiseLoss(600e6), 600e6, "principal loss fixture");
        assertEq(pool.claimLiquidityDeficit(), 350e6, "liquidity deficit moved with principal");
        assertEq(pool.claimSolvencyDeficit(), 100e6, "solvency deficit not exposed");

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.ClaimDeficitExceeded.selector, 100e6 + 1, 100e6));
        pool.coverClaimDeficit(100e6 + 1);

        vm.prank(carol);
        assertEq(pool.coverClaimDeficit(100e6), 0, "exact cover left insolvency");
        assertEq(pool.claimSolvencyDeficit(), 0, "solvency cover did not clear");
        assertEq(pool.claimLiquidityDeficit(), 250e6, "solvency cover gifted liquidity");
    }

    function test_gainStreamsInFullWhenClaimsAreIlliquidButSolvent() public {
        _makeSolventLiquidityDeficit();
        uint256 navBefore = pool.totalAssets();

        _deliver(100e6);

        assertEq(pool.pendingYield(), 100e6, "liquidity deficit swallowed gain");
        assertEq(pool.unreleasedYield(), 100e6, "full gain was not held out");
        assertGt(pool.yieldRate(), 0, "gain did not stream");
        assertEq(pool.totalAssets(), navBefore, "gain stepped NAV");
        assertEq(pool.claimLiquidityDeficit(), 250e6, "gain did not add physical liquidity");
        assertEq(pool.claimSolvencyDeficit(), 0, "gain created insolvency");
    }

    function test_gainRecognisesExactlySolvencyCoverAndStreamsOnlyTheRemainder() public {
        _makeSolventLiquidityDeficit();
        vm.prank(manager);
        pool.socialiseLoss(600e6);
        assertEq(pool.claimSolvencyDeficit(), 100e6, "solvency fixture");
        uint256 navBefore = pool.totalAssets();

        _deliver(150e6);

        assertEq(pool.pendingYield(), 50e6, "wrong streamable remainder");
        assertEq(pool.unreleasedYield(), 50e6, "wrong live remainder");
        assertGt(pool.yieldRate(), 0, "remainder did not stream");
        assertEq(pool.claimSolvencyDeficit(), 0, "gain did not cover insolvency");
        assertEq(pool.claimLiquidityDeficit(), 200e6, "wrong remaining liquidity deficit");
        assertEq(pool.totalAssets(), navBefore, "solvency restoration created shareholder NAV");
    }

    function test_owedYieldRepairsTerminalClaimsWithoutPullingTheExcess() public {
        _deposit(alice, 1_000e6);
        uint256 claim = _serviceFullAliceClaim();
        assertEq(pool.totalSupply(), 0, "terminal claim retained shares");
        assertEq(claim, 1_000e6, "terminal claim fixture");

        uint256 deficit = 100e6;
        usdc.burn(address(pool), deficit);
        pool.reconcileCashDeficit();
        assertEq(pool.claimSolvencyDeficit(), deficit, "terminal deficit fixture");

        uint256 offered = 150e6;
        vm.warp(block.timestamp + 7 days);
        uint256 distributeClockBefore = pool.lastYieldDistributeAt();
        uint256 harvesterBefore = usdc.balanceOf(harvester);
        _deliver(offered);

        assertEq(harvesterBefore - usdc.balanceOf(harvester), deficit, "delivery pulled more than the repair");
        assertEq(pool.lastYieldDistributeAt(), distributeClockBefore, "partial pull consumed the epoch clock");
        assertEq(pool.claimSolvencyDeficit(), 0, "owed yield did not restore the fixed claim");
        assertEq(pool.claimLiquidityDeficit(), 0, "restored claim remained illiquid");
        assertEq(pool.pendingYield(), 0, "claim repair became shareholder yield");
        assertEq(pool.totalAssets(), 0, "claim repair created shareholder NAV");

        assertEq(pool.claimFor(alice), claim, "restored terminal claim was not payable");
    }

    function test_terminalClaimRepairClosesTheClockWhenItConsumesTheWholeEpoch() public {
        _deposit(alice, 1_000e6);
        _serviceFullAliceClaim();

        uint256 deficit = 100e6;
        usdc.burn(address(pool), deficit);
        pool.reconcileCashDeficit();
        vm.warp(block.timestamp + 7 days);

        _deliver(deficit);

        assertEq(pool.claimSolvencyDeficit(), 0, "whole epoch did not repair the claim");
        assertEq(pool.lastYieldDistributeAt(), block.timestamp, "whole epoch left the accrual clock stale");
    }

    function test_lowNonzeroSupplyEpochPullsOnlyClaimDeficitAndMovesClockOnlyOnFullAcceptance() public {
        uint256 shares = _deposit(alice, 20_000);
        vm.prank(alice);
        pool.redeem(shares - (MIN_SUPPLY - 1), alice, alice);
        assertEq(pool.totalSupply(), MIN_SUPPLY - 1, "low-supply fixture");

        uint256 requested = pool.balanceOf(alice) / 2;
        vm.prank(alice);
        pool.requestWithdrawal(requested, alice);
        uint256 serviceable = pool.maxRequestRedeem(alice);
        assertGt(serviceable, 0, "low-supply request was not serviceable");
        vm.prank(alice);
        uint256 claim = pool.serviceWithdrawalRequest(alice, serviceable, 0);
        assertGt(pool.totalSupply(), 0, "request consumed the low-supply cohort");
        assertLt(pool.totalSupply(), MIN_SUPPLY, "request escaped the low-supply branch");
        assertGt(claim, 2, "claim fixture was too small");

        uint256 firstDeficit = claim / 2;
        uint256 raw = usdc.balanceOf(address(pool));
        usdc.burn(address(pool), raw - (claim - firstDeficit));
        pool.reconcileCashDeficit();
        assertEq(pool.claimLiquidityDeficit(), firstDeficit, "first liquidity deficit fixture");
        assertEq(pool.claimSolvencyDeficit(), firstDeficit, "first solvency deficit fixture");

        vm.warp(block.timestamp + 7 days);
        uint256 clockBefore = pool.lastYieldDistributeAt();
        uint256 harvesterBefore = usdc.balanceOf(harvester);
        uint256 excess = 123;
        _deliver(firstDeficit + excess);

        assertEq(harvesterBefore - usdc.balanceOf(harvester), firstDeficit, "partial epoch pulled its excess");
        assertEq(pool.lastYieldDistributeAt(), clockBefore, "partial epoch consumed the delivery clock");
        assertEq(pool.claimLiquidityDeficit(), 0, "partial epoch left the claim illiquid");
        assertEq(pool.claimSolvencyDeficit(), 0, "partial epoch left the claim insolvent");
        assertEq(pool.pendingYield(), 0, "partial claim repair became shareholder yield");
        assertEq(pool.totalAssets(), 0, "partial claim repair created shareholder NAV");

        usdc.burn(address(pool), 1);
        pool.reconcileCashDeficit();
        assertEq(pool.claimLiquidityDeficit(), 1, "second liquidity deficit fixture");
        assertEq(pool.claimSolvencyDeficit(), 1, "second solvency deficit fixture");

        vm.warp(block.timestamp + 1 days);
        harvesterBefore = usdc.balanceOf(harvester);
        _deliver(1);

        assertEq(harvesterBefore - usdc.balanceOf(harvester), 1, "full epoch pulled the wrong amount");
        assertEq(pool.lastYieldDistributeAt(), block.timestamp, "full epoch did not advance the delivery clock");
        assertEq(pool.claimLiquidityDeficit(), 0, "full epoch left the claim illiquid");
        assertEq(pool.claimSolvencyDeficit(), 0, "full epoch left the claim insolvent");
        assertEq(pool.pendingYield(), 0, "full claim repair became shareholder yield");
        assertEq(pool.totalAssets(), 0, "full claim repair created shareholder NAV");
    }

    function test_underfundingBlocksEveryClaimAsOneClass() public {
        _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);

        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, receiverOne);
        vm.prank(alice);
        uint256 claimOne = pool.serviceWithdrawalRequest(alice, 100e9, 0);

        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, receiverTwo);
        vm.prank(bob);
        uint256 claimTwo = pool.serviceWithdrawalRequest(bob, 100e9, 0);

        uint256 claims = claimOne + claimTwo;
        assertEq(pool.totalClaimable(), claims, "claim fixture");
        usdc.burn(address(pool), usdc.balanceOf(address(pool)) - (claims - 1));

        vm.expectRevert(abi.encodeWithSelector(LenderPool.ClaimsUnderfunded.selector, claims, claims - 1));
        pool.claimFor(receiverOne);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.ClaimsUnderfunded.selector, claims, claims - 1));
        pool.claimFor(receiverTwo);

        assertEq(pool.claimable(receiverOne), claimOne, "first claim changed");
        assertEq(pool.claimable(receiverTwo), claimTwo, "second claim changed");
        assertEq(usdc.balanceOf(receiverOne), 0, "first receiver was preferred");
        assertEq(usdc.balanceOf(receiverTwo), 0, "second receiver was preferred");
    }

    function test_claimPayThenPrincipalLossDoesNotResurrectTheOldTail() public {
        _deposit(alice, 1_000e6);
        _lend(850e6);

        uint256 allShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(allShares, alice);
        uint256 serviceable = pool.maxRequestRedeem(alice);
        vm.prank(alice);
        uint256 fixedClaim = pool.serviceWithdrawalRequest(alice, serviceable, 0);
        assertEq(fixedClaim, 150e6, "hot-float claim fixture");
        pool.claimFor(alice);
        assertEq(usdc.balanceOf(address(pool)), 0, "claim did not consume the hot float");

        vm.prank(manager);
        pool.socialiseLoss(850e6);
        uint256 oldEscrowShares = pool.balanceOf(address(pool));
        assertEq(pool.totalAssets(), 0, "principal loss left old NAV");
        assertGt(oldEscrowShares, 0, "old cohort fixture");

        uint256 bobShares = _deposit(bob, 1_000e6);
        assertEq(pool.previewRedeem(oldEscrowShares), 0, "fresh cash resurrected old shares");
        assertEq(pool.maxRequestRedeem(alice), 0, "fresh cash serviced the destroyed request");
        assertGe(pool.previewRedeem(bobShares), 1_000e6 - 1, "fresh depositor funded old shares");
        assertLe(pool.previewRedeem(bobShares), 1_000e6, "fresh depositor gained old value");
    }

    function test_minimumSupplySeparatesNoLenderStateFromThePrincipalFloor() public {
        uint256 shares = _deposit(alice, 20_000);
        vm.prank(alice);
        pool.redeem(shares - MIN_SUPPLY, alice, alice);
        assertEq(pool.totalSupply(), MIN_SUPPLY, "minimum fixture");
        assertGt(pool.available(), 0, "minimum supply was treated as empty");

        _lend(1);
        assertEq(pool.outstandingPrincipal(), 1, "minimum supply could not lend");
        assertEq(pool.maxRedeem(alice), 0, "maxRedeem crossed the principal floor");

        vm.expectRevert(abi.encodeWithSelector(LenderPool.MinimumShareSupply.selector, MIN_SUPPLY - 1, MIN_SUPPLY));
        pool.exposedBurn(alice, 1);

        uint256 remainingShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(remainingShares, alice);
        assertEq(pool.maxRequestRedeem(alice), 0, "request service crossed the principal floor");

        (BurnableCanonicalCashUSDC tokenTwo, CanonicalCashLenderPoolHarness poolTwo) = _newPool();
        _fundAndApprove(tokenTwo, poolTwo, alice, 20_000);
        uint256 sharesTwo = _deposit(poolTwo, alice, 20_000);
        vm.prank(alice);
        poolTwo.redeem(sharesTwo - (MIN_SUPPLY - 1), alice, alice);
        assertEq(poolTwo.totalSupply(), MIN_SUPPLY - 1, "below-minimum fixture");
        assertEq(poolTwo.available(), 0, "below-minimum supply became lendable");

        vm.prank(manager);
        vm.expectRevert(LenderPool.NoSharesOutstanding.selector);
        poolTwo.lend(1);
    }

    function test_repeatedLossRefillTapersLendingBeforeShareArithmeticCanOverflow() public {
        _seedMaximumPool();

        bool tapered;
        for (uint256 i; i < 128; ++i) {
            uint256 lendable = pool.available();
            if (lendable == 0) {
                tapered = true;
                break;
            }

            _loseAndRefill(lendable);
            assertLe(pool.totalSupply(), pool.maximumShareSupply(), "hard share ceiling");
            assertLe(
                pool.totalSupply() + 10 ** 3,
                MAX_SHARES_PER_ASSET * (pool.depositCapUsage() + 1),
                "bounded share quotient"
            );
        }

        assertTrue(tapered, "lending did not taper inside 128 losses");
        assertEq(pool.available(), 0, "terminal risk boundary still lent");
        assertEq(pool.entryPriceDeficit(), 0, "tapering closed fair entry");
        assertEq(pool.maxDeposit(alice), 0, "full cap quote changed at the boundary");
        assertEq(pool.maxMint(alice), 0, "full cap mint quote changed at the boundary");
    }

    function test_priceReserveIsSeniorToSynchronousExitBeforePrincipalLoss() public {
        uint256 lent = _reachMaterialPriceReserve();
        uint256 reserveBefore = pool.entryPriceCashReserve();
        assertGe(reserveBefore, MAX_CAP / 4, "reserve fixture");

        uint256 redeemable = pool.maxRedeem(alice);
        assertGt(redeemable, 0, "no executable exit cash");
        vm.prank(alice);
        pool.redeem(redeemable, alice, alice);

        vm.prank(manager);
        pool.socialiseLoss(lent);
        assertEq(pool.entryPriceDeficit(), 0, "exit spent the future-loss reserve");
    }

    function test_priceReserveIsSeniorToRequestServiceBeforePrincipalLoss() public {
        uint256 lent = _reachMaterialPriceReserve();

        uint256 requested = pool.balanceOf(alice) / 2;
        vm.prank(alice);
        pool.requestWithdrawal(requested, alice);
        uint256 serviceable = pool.maxRequestRedeem(alice);
        assertGt(serviceable, 0, "no executable request cash");
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, serviceable, 0);

        vm.prank(manager);
        pool.socialiseLoss(lent);
        assertEq(pool.entryPriceDeficit(), 0, "request service spent the future-loss reserve");
    }

    function test_externalCashLossNeedsExactRecognisedPriceCover() public {
        uint256 lent = _reachMaterialPriceReserve();
        vm.prank(manager);
        pool.socialiseLoss(lent);

        uint256 refill = pool.maxDeposit(alice);
        usdc.mint(alice, refill);
        _deposit(alice, refill);

        uint256 requiredCash = pool.minimumEntryAssets();
        uint256 physicalCash = usdc.balanceOf(address(pool));
        assertGt(physicalCash, requiredCash, "cash-loss fixture");
        uint256 externalLoss = physicalCash - requiredCash + 1;
        usdc.burn(address(pool), externalLoss);
        assertEq(pool.maxDeposit(bob), 0, "projected cash loss left entry open");
        pool.reconcileCashDeficit();

        uint256 deficit = pool.entryPriceDeficit();
        assertGt(deficit, 0, "external loss did not cross the price floor");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.EntryPriceDeficitExceeded.selector, deficit + 1, deficit));
        pool.coverEntryPriceDeficit(deficit + 1);

        vm.prank(carol);
        assertEq(pool.coverEntryPriceDeficit(deficit), 0, "exact price cover left a shortfall");
        assertEq(pool.entryPriceDeficit(), 0, "recognised cover did not reopen entry pricing");
        assertGt(pool.maxDeposit(bob), 0, "recognised cover did not reopen headroom");
    }

    function test_extremeConversionInputsSaturateInsteadOfReverting() public view {
        uint256 maximum = type(uint256).max;
        assertEq(pool.convertToShares(maximum), maximum, "share conversion did not saturate");
        assertEq(pool.previewDeposit(maximum), maximum, "deposit preview did not saturate");
        assertEq(pool.previewWithdraw(maximum), maximum, "withdraw preview did not saturate");
        assertGt(pool.convertToAssets(maximum), 0, "asset conversion became zero");
        assertGt(pool.previewMint(maximum), 0, "mint preview became zero");
    }

    function test_allMaximumViewsReturnZeroWhenTheAssetBalanceProbeFails() public {
        _deposit(alice, 1_000e6);
        bytes memory balanceCall = abi.encodeCall(IERC20.balanceOf, (address(pool)));
        vm.mockCallRevert(address(usdc), balanceCall, bytes("balance read failed"));

        assertEq(pool.maxDeposit(alice), 0, "deposit maximum reverted or stayed open");
        assertEq(pool.maxMint(alice), 0, "mint maximum reverted or stayed open");
        assertEq(pool.maxRedeem(alice), 0, "redeem maximum reverted or stayed open");
        assertEq(pool.maxWithdraw(alice), 0, "withdraw maximum reverted or stayed open");

        vm.clearMockedCalls();
    }

    function test_zeroSupplyDerecognisesResidualAcrossTwoExactCohorts() public {
        uint256 aliceShares = _deposit(alice, 10_000);
        assertEq(aliceShares, MIN_SUPPLY, "first minimum cohort");
        _deliver(10_000);

        vm.prank(alice);
        pool.redeem(aliceShares, alice, alice);

        assertEq(pool.totalSupply(), 0, "first cohort remained");
        assertEq(pool.totalAssets(), 0, "residual stayed recognised");
        assertEq(pool.pendingYield(), 0, "old stream remained recyclable");
        assertEq(pool.yieldRate(), 0, "old stream remained live");
        assertEq(pool.depositCapUsage(), 0, "old residual consumed cap");
        assertEq(pool.unmanagedSurplus(), 10_000, "old residual was not made inert");

        uint256 bobShares = _deposit(bob, 10_000);
        assertEq(bobShares, MIN_SUPPLY, "second minimum cohort");
        assertEq(pool.totalAssets(), 10_000, "old residual entered Bob's NAV");
        assertEq(pool.unmanagedSurplus(), 10_000, "Bob's deposit recognised old residual");

        _deliver(10_000);
        assertEq(pool.pendingYield(), 10_000, "new stream included the old residual");
        assertEq(pool.depositCapUsage(), 20_000, "active cohort cap usage");
        vm.warp(pool.yieldStreamEndsAt());
        assertEq(pool.totalAssets(), 20_000, "two cohorts were merged");
        assertApproxEqAbs(pool.previewRedeem(bobShares), 20_000, 1, "Bob captured the first cohort residual");
        assertEq(pool.unmanagedSurplus(), 10_000, "old residual stopped being inert");
    }

    function test_frozenTailWithLiveSupplyStillPricesEntryAndConsumesCap() public {
        uint256 shares = _deposit(alice, 20_000);
        _deliver(10_000);

        vm.prank(alice);
        pool.redeem(shares - (MIN_SUPPLY - 1), alice, alice);

        assertEq(pool.totalSupply(), MIN_SUPPLY - 1, "live frozen fixture");
        assertEq(pool.yieldRate(), 0, "tail did not freeze");
        assertEq(pool.pendingYield(), 10_000, "frozen tail changed");
        assertEq(pool.depositCapUsage(), 20_000, "frozen live tail escaped the cap");

        uint256 depositAssets = 10_000;
        uint256 grossEntryAssets = pool.totalAssets() + pool.pendingYield();
        uint256 expectedShares =
            Math.mulDiv(depositAssets, pool.totalSupply() + 10 ** 3, grossEntryAssets + 1, Math.Rounding.Floor);
        assertEq(pool.previewDeposit(depositAssets), expectedShares, "frozen tail escaped entry pricing");
    }

    function test_lateSurplusAndRecoveryAtZeroSupplyBecomeUnmanaged() public {
        vm.prank(manager);
        pool.repayPrincipal(100e6);
        assertEq(pool.totalAssets(), 0, "empty-pool surplus became NAV");
        assertEq(pool.pendingYield(), 0, "empty-pool surplus became a backlog");
        assertEq(pool.depositCapUsage(), 0, "empty-pool surplus consumed cap");
        assertEq(pool.unmanagedSurplus(), 100e6, "empty-pool surplus remained recognised");

        (BurnableCanonicalCashUSDC tokenTwo, CanonicalCashLenderPoolHarness poolTwo) = _newPool();
        _fundAndApprove(tokenTwo, poolTwo, manager, 100e6);
        vm.prank(manager);
        poolTwo.recoverLoss(100e6);
        assertEq(poolTwo.totalAssets(), 0, "empty-pool recovery became NAV");
        assertEq(poolTwo.pendingYield(), 0, "empty-pool recovery became a backlog");
        assertEq(poolTwo.depositCapUsage(), 0, "empty-pool recovery consumed cap");
        assertEq(poolTwo.unmanagedSurplus(), 100e6, "empty-pool recovery remained recognised");
    }
}
