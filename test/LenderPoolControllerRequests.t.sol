// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {ILenderPool} from "../src/interfaces/ILenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

interface IControllerCanonicalCashPool {
    function depositCapUsage() external view returns (uint256);
}

contract LenderPoolControllerRequestsTest is Test {
    address internal manager = makeAddr("manager");
    address internal borrower = makeAddr("borrower");
    address internal victim = makeAddr("victim");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    address internal receiver = makeAddr("receiver");

    function _newPool() internal returns (MockUSDC token, LenderPool pool) {
        token = new MockUSDC();
        pool = new LenderPool(IERC20(address(token)), address(this));
        pool.setCreditManager(manager);
        pool.setEpochHarvester(makeAddr("harvester"));
    }

    function _deposit(MockUSDC token, LenderPool pool, address account, uint256 assets)
        internal
        returns (uint256 shares)
    {
        token.mint(account, assets);
        vm.startPrank(account);
        token.approve(address(pool), type(uint256).max);
        shares = pool.deposit(assets, account);
        vm.stopPrank();
    }

    function _lend(LenderPool pool, uint256 amount) internal {
        vm.prank(manager);
        pool.lend(amount);
    }

    function _poolBalance(MockUSDC token, LenderPool pool) internal view returns (uint256) {
        uint256 rawBalance = token.balanceOf(address(pool));
        uint256 excluded = pool.totalClaimable() + pool.unreleasedYield();
        return rawBalance > excluded ? rawBalance - excluded : 0;
    }

    function _depositCapUsage(LenderPool pool) internal view returns (uint256) {
        return IControllerCanonicalCashPool(address(pool)).depositCapUsage();
    }

    function _book(uint256 book, uint256 cash, uint256 aliceAssets, uint256 bobAssets)
        internal
        returns (MockUSDC token, LenderPool pool)
    {
        (token, pool) = _newPool();
        _deposit(token, pool, victim, book - aliceAssets - bobAssets);
        if (aliceAssets != 0) _deposit(token, pool, alice, aliceAssets);
        if (bobAssets != 0) _deposit(token, pool, bob, bobAssets);
        if (book != cash) _lend(pool, book - cash);
        assertEq(pool.totalAssets(), book, "fixture book");
        assertEq(_poolBalance(token, pool), cash, "fixture cash");
    }

    function _assertRequestBounds(MockUSDC token, LenderPool pool) internal view {
        uint256 idle = _poolBalance(token, pool);
        assertLe(pool.queuedShares(), pool.totalSupply(), "requested shares exceed supply");
        assertLe(pool.queueCashReserve(), idle, "cash reserve exceeds idle");
    }

    function test_queueCashReserve_tracksCashOwnershipAcrossTheLeverageSweep() public {
        uint256[6] memory books = [uint256(1_500e6), 2_000e6, 3_000e6, 4_000e6, 5_000e6, 6_000e6];

        for (uint256 i = 0; i < books.length; i++) {
            uint256 book = books[i];
            uint256 requestorAssets = book / 10;
            (MockUSDC token, LenderPool pool) = _book(book, 1_000e6, requestorAssets, 0);

            uint256 shares = pool.balanceOf(alice);
            vm.prank(alice);
            pool.requestWithdrawal(shares, alice);

            uint256 idle = _poolBalance(token, pool);
            uint256 expected = Math.mulDiv(idle, shares, pool.totalSupply(), Math.Rounding.Ceil);
            assertEq(pool.queueCashReserve(), expected, "reserve is not the request's cash share");
            assertApproxEqAbs(pool.queueCashReserve(), idle / 10, 1, "reserve changed with leverage");
            _assertRequestBounds(token, pool);
        }
    }

    function test_oneSixthRequestLeavesFiveSixthsOfCashForTheUnqueuedLender() public {
        (MockUSDC token, LenderPool pool) = _book(6_000e6, 1_000e6, 1_000e6, 0);
        uint256 shares = pool.balanceOf(alice);

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        assertApproxEqAbs(pool.queueCashReserve(), uint256(1_000e6) / 6, 1, "one sixth cash reserve");
        assertApproxEqAbs(pool.unreservedIdle(), uint256(5_000e6) / 6, 1, "five sixths cash remainder");
        assertGt(pool.maxWithdraw(victim), 0, "majority lender was zeroed");
        _assertRequestBounds(token, pool);
    }

    function test_onePointSixSevenPercentRequestNoLongerHaltsBorrowingAtSixTimesLeverage() public {
        (MockUSDC token, LenderPool pool) = _book(6_000e6, 1_000e6, 100e6, 0);
        uint256 shares = pool.balanceOf(alice);

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        assertGt(pool.available(), 80e6, "a 166 bps book claim still halted borrowing");
        _assertRequestBounds(token, pool);
    }

    function test_available_usesPostRequestBookForTheHotFloat() public {
        (MockUSDC token, LenderPool pool) = _book(6_000e6, 1_000e6, 600e6, 0);
        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        uint256 idle = _poolBalance(token, pool);
        uint256 reserve = pool.queueCashReserve();
        uint256 assets = pool.totalAssets();
        uint256 floatAfterRequest = ((assets - reserve) * Config.RESERVE_RATIO_BPS) / Config.BPS;
        uint256 expected = idle > reserve + floatAfterRequest ? idle - reserve - floatAfterRequest : 0;
        assertEq(pool.available(), expected, "post-request hot float identity");

        uint256 oldDoubleCount = idle > reserve + (assets * Config.RESERVE_RATIO_BPS) / Config.BPS
            ? idle - reserve - (assets * Config.RESERVE_RATIO_BPS) / Config.BPS
            : 0;
        uint256 oldMaximum = reserve > (assets * Config.RESERVE_RATIO_BPS) / Config.BPS
            ? idle - reserve
            : idle - (assets * Config.RESERVE_RATIO_BPS) / Config.BPS;
        assertNotEq(pool.available(), oldDoubleCount, "old double-count formula survived");
        assertNotEq(pool.available(), oldMaximum, "old maximum formula survived");
    }

    function test_serviceLeavesThePostRequestHotFloatFundedWhenTheFixtureHasCapacity() public {
        (MockUSDC token, LenderPool pool) = _book(2_000e6, 1_000e6, 200e6, 0);
        uint256 requestShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(requestShares, alice);

        uint256 serviceShares = pool.maxRequestRedeem(alice);
        uint256 serviceQuote = pool.previewRedeem(serviceShares);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, serviceShares, serviceQuote);

        uint256 idle = _poolBalance(token, pool);
        uint256 reserve = pool.queueCashReserve();
        uint256 floatAfterRequest = ((pool.totalAssets() - reserve) * Config.RESERVE_RATIO_BPS) / Config.BPS;
        assertGe(idle - reserve, floatAfterRequest, "service consumed the post-request hot float");
        _assertRequestBounds(token, pool);
    }

    function test_twoRequestsRemainIndependentAfterAnUnqueuedMaximumExit() public {
        (MockUSDC token, LenderPool pool) = _book(6_000e6, 1_000e6, 300e6, 300e6);
        uint256 aliceShares = pool.balanceOf(alice);
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        uint256 victimMaximum = pool.maxRedeem(victim);
        vm.prank(victim);
        pool.redeem(victimMaximum, victim, victim);

        assertGt(pool.maxRequestRedeem(alice), 0, "first request lost serviceability");
        assertGt(pool.maxRequestRedeem(bob), 0, "second request lost serviceability");

        (uint256 bobIdBefore, address bobReceiverBefore, uint256 bobSharesBefore,,) = pool.withdrawalRequest(bob);
        uint256 aliceService = pool.maxRequestRedeem(alice);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, aliceService, 0);
        (uint256 bobIdAfter, address bobReceiverAfter, uint256 bobSharesAfter, uint256 bobServiceAfter,) =
            pool.withdrawalRequest(bob);

        assertEq(bobIdAfter, bobIdBefore, "another controller changed the request id");
        assertEq(bobReceiverAfter, bobReceiverBefore, "another controller changed the receiver");
        assertEq(bobSharesAfter, bobSharesBefore, "another controller changed stored shares");
        assertGt(bobServiceAfter, 0, "shared cash and supply erased the other request");
        _assertRequestBounds(token, pool);
    }

    function test_authorizationRevocationFixedReceiverAndSlippageAreAtomic() public {
        (MockUSDC token, LenderPool pool) = _book(1_000e6, 1_000e6, 400e6, 0);
        uint256 requestShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(requestShares, receiver);

        uint256 serviceShares = requestShares / 4;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.UnauthorizedRequestOperator.selector, alice, stranger));
        pool.serviceWithdrawalRequest(alice, serviceShares, 0);

        uint256 quoted = pool.previewRedeem(serviceShares);
        uint256 queuedBefore = pool.queuedShares();
        uint256 escrowBefore = pool.balanceOf(address(pool));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, quoted, quoted + 1));
        pool.serviceWithdrawalRequest(alice, serviceShares, quoted + 1);
        assertEq(pool.queuedShares(), queuedBefore, "slippage revert changed queued shares");
        assertEq(pool.balanceOf(address(pool)), escrowBefore, "slippage revert burned escrow");
        assertEq(pool.claimable(receiver), 0, "slippage revert made a claim");

        vm.prank(alice);
        assertTrue(pool.setRequestOperator(operator, true), "operator approval failed");
        vm.prank(operator);
        pool.serviceWithdrawalRequest(alice, serviceShares, quoted);
        assertEq(pool.claimable(receiver), quoted, "operator redirected or lost the payout");

        vm.prank(alice);
        pool.setRequestOperator(operator, false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.UnauthorizedRequestOperator.selector, alice, operator));
        pool.serviceWithdrawalRequest(alice, serviceShares, 0);
        _assertRequestBounds(token, pool);
    }

    function test_requestOperatorApprovalPersistsAcrossRequestLifecyclesUntilRevoked() public {
        (MockUSDC token, LenderPool pool) = _book(1_000e6, 1_000e6, 400e6, 0);
        uint256 shares = pool.balanceOf(alice);

        vm.prank(alice);
        pool.setRequestOperator(operator, true);
        vm.prank(alice);
        pool.requestWithdrawal(shares / 2, receiver);
        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertTrue(pool.isRequestOperator(alice, operator), "cancel revoked the standing operator");

        vm.prank(alice);
        pool.requestWithdrawal(shares / 2, receiver);
        uint256 fullService = pool.maxRequestRedeem(alice);
        assertEq(fullService, shares / 2, "fixture request is not fully serviceable");
        uint256 fullServiceQuote = pool.previewRedeem(fullService);
        vm.prank(operator);
        pool.serviceWithdrawalRequest(alice, fullService, fullServiceQuote);
        (uint256 completedId,,,,) = pool.withdrawalRequest(alice);
        assertEq(completedId, 0, "full service left the request live");
        assertTrue(pool.isRequestOperator(alice, operator), "full service revoked the standing operator");

        uint256 remainingShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(remainingShares, receiver);
        assertTrue(pool.isRequestOperator(alice, operator), "new request lost the standing operator");
        uint256 partialService = pool.maxRequestRedeem(alice) / 2;
        assertGt(partialService, 0, "new request is not serviceable");
        vm.prank(operator);
        pool.serviceWithdrawalRequest(alice, partialService, 0);

        vm.prank(alice);
        pool.setRequestOperator(operator, false);
        assertFalse(pool.isRequestOperator(alice, operator), "explicit revoke did not clear approval");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.UnauthorizedRequestOperator.selector, alice, operator));
        pool.serviceWithdrawalRequest(alice, 1, 0);
        _assertRequestBounds(token, pool);
    }

    function test_requestLifecycleEventsIndexControllerRequestReceiverAndOperator() public {
        (, LenderPool pool) = _book(1_000e6, 1_000e6, 400e6, 0);
        uint256 shares = pool.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ILenderPool.WithdrawalRequested(alice, 1, receiver, shares);
        vm.prank(alice);
        pool.requestWithdrawal(shares, receiver);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILenderPool.RequestOperatorSet(alice, operator, true);
        vm.prank(alice);
        pool.setRequestOperator(operator, true);

        uint256 serviceShares = shares / 2;
        uint256 assetsOut = pool.previewRedeem(serviceShares);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ILenderPool.WithdrawalRequestServiced(alice, 1, receiver, serviceShares, assetsOut);
        vm.prank(operator);
        pool.serviceWithdrawalRequest(alice, serviceShares, assetsOut);

        vm.expectEmit(true, false, false, true, address(pool));
        emit ILenderPool.WithdrawalClaimed(receiver, assetsOut);
        vm.prank(stranger);
        pool.claimFor(receiver);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ILenderPool.WithdrawalRequestCancelled(alice, 1, receiver, shares - serviceShares);
        vm.prank(alice);
        pool.cancelWithdrawalRequest();
    }

    function test_cancelThenRequestAgainReturnsExactSharesAndUsesAMonotonicId() public {
        (MockUSDC token, LenderPool pool) = _book(1_000e6, 1_000e6, 400e6, 0);
        uint256 shares = pool.balanceOf(alice);
        uint256 usageBefore = _depositCapUsage(pool);

        vm.prank(alice);
        pool.requestWithdrawal(shares, receiver);
        (uint256 firstId,,,,) = pool.withdrawalRequest(alice);
        assertEq(pool.balanceOf(address(pool)), shares, "request did not escrow the exact shares");
        assertEq(_depositCapUsage(pool), usageBefore, "request creation changed cap usage");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(alice), shares, "cancel did not return shares");
        assertEq(pool.balanceOf(address(pool)), 0, "cancel left shares in escrow");
        assertEq(pool.queuedShares(), 0, "cancel left requested shares");
        assertEq(_depositCapUsage(pool), usageBefore, "cancel changed cap usage");

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (uint256 secondId,,,,) = pool.withdrawalRequest(alice);
        assertEq(secondId, firstId + 1, "request id was reused");
        assertEq(_depositCapUsage(pool), usageBefore, "a replacement request changed cap usage");
        _assertRequestBounds(token, pool);
    }

    function test_repeatedPartialServiceDebitsExactClaimsAndConservesUSDC() public {
        (MockUSDC token, LenderPool pool) = _book(900e6, 900e6, 300e6, 0);
        uint256 shares = pool.balanceOf(alice);
        uint256 slice = shares / 3;
        vm.prank(alice);
        pool.requestWithdrawal(shares, receiver);

        uint256 rawBefore = token.balanceOf(address(pool));
        uint256 totalAssetsBefore = pool.totalAssets();
        uint256 usageBefore = _depositCapUsage(pool);
        uint256 claimed;

        for (uint256 i = 0; i < 3; i++) {
            uint256 sharesToService = i == 2 ? pool.maxRequestRedeem(alice) : slice;
            uint256 sliceUsageBefore = _depositCapUsage(pool);
            uint256 claimableBefore = pool.claimable(receiver);
            vm.prank(alice);
            uint256 assetsOut = pool.serviceWithdrawalRequest(alice, sharesToService, 0);
            claimed += assetsOut;
            assertEq(_depositCapUsage(pool), sliceUsageBefore - assetsOut, "partial service cap debit");
            assertEq(pool.claimable(receiver), claimableBefore + assetsOut, "partial service claim credit");
        }

        assertEq(pool.queuedShares(), 0, "repeated service left shares requested");
        assertEq(pool.claimable(receiver), claimed, "claim accounting");
        assertEq(token.balanceOf(address(pool)), rawBefore, "service pushed USDC");
        assertEq(pool.totalAssets(), totalAssetsBefore - claimed, "service did not remove the claim from NAV");
        assertEq(_depositCapUsage(pool), usageBefore - claimed, "services did not free exact cap usage");

        uint256 usageAfterService = _depositCapUsage(pool);
        vm.prank(stranger);
        pool.claimFor(receiver);
        assertEq(token.balanceOf(receiver), claimed, "fixed receiver was not paid");
        assertEq(pool.totalClaimable(), 0, "claimable total did not clear");
        assertEq(token.balanceOf(address(pool)), rawBefore - claimed, "USDC conservation");
        assertEq(_depositCapUsage(pool), usageAfterService, "claim changed cap usage a second time");

        (uint256 requestId, address storedReceiver, uint256 storedShares, uint256 serviceableShares, uint256 assets) =
            pool.withdrawalRequest(alice);
        assertEq(requestId, 0, "completed request still exists");
        assertEq(storedReceiver, address(0), "completed receiver still exists");
        assertEq(storedShares, 0, "completed shares still exist");
        assertEq(serviceableShares, 0, "completed request is serviceable");
        assertEq(assets, 0, "completed request reports assets");
        _assertRequestBounds(token, pool);
    }

    function test_controllerCanServiceUnderALiveMarkWithAnExecutionFloor() public {
        (MockUSDC token, LenderPool pool) = _book(2_000e6, 1_000e6, 500e6, 0);
        vm.prank(manager);
        pool.impair(borrower, 400e6);
        assertGt(pool.exitReserve(), 0, "fixture mark");

        uint256 requestShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(requestShares, receiver);
        uint256 serviceShares = pool.maxRequestRedeem(alice) / 2;
        uint256 minimum = pool.previewRedeem(serviceShares);

        vm.prank(alice);
        uint256 assetsOut = pool.serviceWithdrawalRequest(alice, serviceShares, minimum);
        assertEq(assetsOut, minimum, "live-mark execution moved past its floor");
        assertEq(pool.claimable(receiver), assetsOut, "live-mark claim not recorded");
        _assertRequestBounds(token, pool);
    }

    function test_noRequestReportsAZeroTupleAndCannotBeCancelledOrServiced() public {
        (MockUSDC token, LenderPool pool) = _newPool();
        (uint256 requestId, address storedReceiver, uint256 shares, uint256 serviceable, uint256 assets) =
            pool.withdrawalRequest(alice);
        assertEq(requestId, 0);
        assertEq(storedReceiver, address(0));
        assertEq(shares, 0);
        assertEq(serviceable, 0);
        assertEq(assets, 0);
        assertEq(pool.queueCashReserve(), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.WithdrawalRequestNotFound.selector, alice));
        pool.cancelWithdrawalRequest();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.WithdrawalRequestNotFound.selector, alice));
        pool.serviceWithdrawalRequest(alice, 1, 0);
        _assertRequestBounds(token, pool);
    }

    function test_oneLiveRequestPerControllerAndAlreadyQueuedIsAtomic() public {
        (MockUSDC token, LenderPool pool) = _book(1_000e6, 1_000e6, 400e6, 0);
        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(shares / 2, receiver);
        (uint256 requestId, address receiverBefore, uint256 sharesBefore,,) = pool.withdrawalRequest(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AlreadyQueued.selector, requestId));
        pool.requestWithdrawal(1, bob);

        (uint256 requestIdAfter, address receiverAfter, uint256 sharesAfter,,) = pool.withdrawalRequest(alice);
        assertEq(requestIdAfter, requestId, "duplicate request changed the id");
        assertEq(receiverAfter, receiverBefore, "duplicate request changed the receiver");
        assertEq(sharesAfter, sharesBefore, "duplicate request changed the shares");
        _assertRequestBounds(token, pool);
    }

    function test_operatorAuthorityCannotCreateCancelOrRedirectTheControllersRequest() public {
        (MockUSDC token, LenderPool pool) = _book(1_000e6, 1_000e6, 400e6, 0);
        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(shares, receiver);
        vm.prank(alice);
        pool.setRequestOperator(operator, true);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.WithdrawalRequestNotFound.selector, operator));
        pool.cancelWithdrawalRequest();

        _deposit(token, pool, operator, 10e6);
        uint256 operatorShares = pool.balanceOf(operator);
        vm.prank(operator);
        pool.requestWithdrawal(operatorShares, operator);

        (uint256 aliceId, address aliceReceiver, uint256 aliceShares,,) = pool.withdrawalRequest(alice);
        (uint256 operatorId, address operatorReceiver,,,) = pool.withdrawalRequest(operator);
        assertGt(aliceId, 0, "controller request disappeared");
        assertGt(operatorId, aliceId, "operator did not create only its own request");
        assertEq(aliceReceiver, receiver, "operator redirected the controller receiver");
        assertEq(aliceShares, shares, "operator mutated the controller shares");
        assertEq(operatorReceiver, operator, "operator request receiver");

        uint256 serviceShares = pool.maxRequestRedeem(alice) / 2;
        vm.prank(operator);
        pool.serviceWithdrawalRequest(alice, serviceShares, 0);
        assertGt(pool.claimable(receiver), 0, "operator service missed the fixed receiver");
        assertEq(pool.claimable(operator), 0, "operator redirected controller assets");
        _assertRequestBounds(token, pool);
    }

    function test_zeroAndSelfAddressBoundariesAreExplicit() public {
        (MockUSDC token, LenderPool pool) = _book(1_000e6, 1_000e6, 400e6, 0);
        uint256 shares = pool.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(LenderPool.ZeroAddress.selector);
        pool.requestWithdrawal(shares, address(0));

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.requestWithdrawal(shares, address(pool));

        vm.prank(alice);
        vm.expectRevert(LenderPool.ZeroAddress.selector);
        pool.setRequestOperator(address(0), true);

        vm.prank(alice);
        assertTrue(pool.setRequestOperator(alice, true), "self operator boundary");
        assertTrue(pool.isRequestOperator(alice, alice), "self approval was not recorded");

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (, address storedReceiver,,,) = pool.withdrawalRequest(alice);
        assertEq(storedReceiver, alice, "controller cannot be its own receiver");
        _assertRequestBounds(token, pool);
    }

    function test_dustRequestCanBeCancelledAndZeroAssetServiceRequiresExplicitConsent() public {
        (MockUSDC token, LenderPool pool) = _book(6_000e6, 1_000e6, 1e6, 0);
        uint256 outstanding = pool.outstandingPrincipal();
        vm.prank(manager);
        pool.impair(borrower, outstanding);

        uint256 dustShares = 6_667;
        vm.prank(alice);
        pool.requestWithdrawal(dustShares, alice);
        uint256 maximum = pool.maxRequestRedeem(alice);
        assertGt(maximum, 0, "fixture has no gross-funded dust");
        assertEq(pool.previewRedeem(maximum), 0, "fixture dust has a nonzero exit value");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, 0, 1));
        pool.serviceWithdrawalRequest(alice, maximum, 1);

        vm.prank(alice);
        assertEq(pool.serviceWithdrawalRequest(alice, maximum, 0), 0, "zero-asset consent did not execute");
        (,, uint256 sharesLeft,,) = pool.withdrawalRequest(alice);
        assertEq(sharesLeft, dustShares - maximum, "zero-asset service burned the wrong shares");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.queuedShares(), 0, "dust cancellation left a request");
        _assertRequestBounds(token, pool);
    }

    function test_approvedOperatorNeedsAZeroFloorToServiceZeroValueDust() public {
        (MockUSDC token, LenderPool pool) = _book(6_000e6, 1_000e6, 1e6, 0);
        uint256 outstanding = pool.outstandingPrincipal();
        vm.prank(manager);
        pool.impair(borrower, outstanding);

        uint256 dustShares = 6_667;
        vm.prank(alice);
        pool.requestWithdrawal(dustShares, alice);
        vm.prank(alice);
        pool.setRequestOperator(operator, true);

        uint256 maximum = pool.maxRequestRedeem(alice);
        assertGt(maximum, 0, "fixture has no gross-funded dust");
        assertEq(pool.previewRedeem(maximum), 0, "fixture dust has a nonzero exit value");

        (uint256 requestIdBefore, address receiverBefore, uint256 sharesBefore,,) = pool.withdrawalRequest(alice);
        uint256 queuedBefore = pool.queuedShares();
        uint256 escrowBefore = pool.balanceOf(address(pool));
        uint256 usageBefore = _depositCapUsage(pool);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, 0, 1));
        pool.serviceWithdrawalRequest(alice, maximum, 1);

        (uint256 requestIdAfter, address receiverAfter, uint256 sharesAfter,,) = pool.withdrawalRequest(alice);
        assertEq(requestIdAfter, requestIdBefore, "failed operator service changed the request id");
        assertEq(receiverAfter, receiverBefore, "failed operator service changed the receiver");
        assertEq(sharesAfter, sharesBefore, "failed operator service changed the shares");
        assertEq(pool.queuedShares(), queuedBefore, "failed operator service changed queued shares");
        assertEq(pool.balanceOf(address(pool)), escrowBefore, "failed operator service burned escrow");
        assertEq(_depositCapUsage(pool), usageBefore, "failed operator service changed cap usage");
        assertEq(pool.claimable(alice), 0, "failed operator service made a claim");

        vm.prank(operator);
        assertEq(pool.serviceWithdrawalRequest(alice, maximum, 0), 0, "zero floor did not authorize dust service");
        (,, uint256 sharesLeft,,) = pool.withdrawalRequest(alice);
        assertEq(sharesLeft, dustShares - maximum, "operator burned the wrong dust shares");
        assertEq(pool.claimable(alice), 0, "zero-value service made a positive claim");
        assertEq(_depositCapUsage(pool), usageBefore, "zero-value service changed cap usage");
        _assertRequestBounds(token, pool);
    }

    function test_maxRequestRedeemAndRequestPreviewStayExecutableAcrossMarks() public {
        uint256[4] memory marks = [uint256(0), 100e6, 400e6, 1_000e6];
        for (uint256 i = 0; i < marks.length; i++) {
            (MockUSDC token, LenderPool pool) = _book(2_000e6, 1_000e6, 500e6, 0);
            if (marks[i] != 0) {
                vm.prank(manager);
                pool.impair(borrower, marks[i]);
            }

            uint256 requestShares = pool.balanceOf(alice);
            vm.prank(alice);
            pool.requestWithdrawal(requestShares, receiver);
            uint256 requestCash =
                Math.mulDiv(_poolBalance(token, pool), requestShares, pool.totalSupply(), Math.Rounding.Floor);
            uint256 expectedMaximum = pool.convertToShares(requestCash);
            if (expectedMaximum > requestShares) expectedMaximum = requestShares;
            assertEq(pool.maxRequestRedeem(alice), expectedMaximum, "maximum formula drift");

            (, address fixedReceiver, uint256 storedShares, uint256 serviceableShares, uint256 serviceableAssets) =
                pool.withdrawalRequest(alice);
            assertEq(fixedReceiver, receiver, "preview receiver drift");
            assertEq(storedShares, requestShares, "preview stored shares drift");
            assertEq(serviceableShares, expectedMaximum, "preview maximum drift");
            assertEq(serviceableAssets, pool.previewRedeem(expectedMaximum), "preview asset drift");

            vm.prank(alice);
            uint256 assetsOut = pool.serviceWithdrawalRequest(alice, expectedMaximum, serviceableAssets);
            assertEq(assetsOut, serviceableAssets, "reported maximum was not executable");
            _assertRequestBounds(token, pool);
        }
    }

    function test_markedInexactRepeatedServiceDebitsCapUsageByExactClaim() public {
        (MockUSDC token, LenderPool pool) = _book(2_000e6, 1_000e6, 500e6, 0);
        vm.prank(manager);
        pool.impair(borrower, 333e6);

        uint256 requestShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(requestShares, receiver);
        bool sawPositiveClaim;

        for (uint256 i = 0; i < 3; i++) {
            (,, uint256 storedShares,,) = pool.withdrawalRequest(alice);
            uint256 maximum = pool.maxRequestRedeem(alice);
            uint256 sharesToService = storedShares / 7 + 1;
            if (sharesToService > maximum) sharesToService = maximum;

            uint256 minimum = pool.previewRedeem(sharesToService);
            uint256 usageBefore = _depositCapUsage(pool);
            uint256 claimsBefore = pool.totalClaimable();
            vm.prank(alice);
            uint256 assetsOut = pool.serviceWithdrawalRequest(alice, sharesToService, minimum);
            if (assetsOut != 0) sawPositiveClaim = true;
            assertEq(_depositCapUsage(pool), usageBefore - assetsOut, "partial service cap debit drift");
            assertEq(pool.totalClaimable(), claimsBefore + assetsOut, "partial service claim drift");
        }

        assertTrue(sawPositiveClaim, "fixture did not create a positive claim");
        (,, uint256 remainingShares,,) = pool.withdrawalRequest(alice);
        uint256 usageBeforeCancel = _depositCapUsage(pool);
        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(alice), remainingShares, "cancel did not return the inexact remainder");
        assertEq(_depositCapUsage(pool), usageBeforeCancel, "cancel changed cap usage");
        _assertRequestBounds(token, pool);
    }

    function test_multipleReceiversRemainSeparatelyBackedUntilEachClaims() public {
        address receiverB = makeAddr("receiverB");
        (MockUSDC token, LenderPool pool) = _book(1_000e6, 1_000e6, 300e6, 300e6);
        uint256 aliceShares = pool.balanceOf(alice);
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, receiver);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, receiverB);

        uint256 rawBefore = token.balanceOf(address(pool));
        uint256 aliceService = pool.maxRequestRedeem(alice) / 2;
        uint256 bobService = pool.maxRequestRedeem(bob) / 2;
        vm.prank(alice);
        uint256 aliceAssets = pool.serviceWithdrawalRequest(alice, aliceService, 0);
        vm.prank(bob);
        uint256 bobAssets = pool.serviceWithdrawalRequest(bob, bobService, 0);

        assertEq(token.balanceOf(address(pool)), rawBefore, "service pushed raw USDC");
        assertEq(pool.claimable(receiver), aliceAssets, "first receiver claim");
        assertEq(pool.claimable(receiverB), bobAssets, "second receiver claim");
        assertEq(pool.totalClaimable(), aliceAssets + bobAssets, "claim sum");
        (,, uint256 aliceLeft,,) = pool.withdrawalRequest(alice);
        (,, uint256 bobLeft,,) = pool.withdrawalRequest(bob);
        assertEq(pool.queuedShares(), aliceLeft + bobLeft, "queued share sum");

        pool.claimFor(receiver);
        assertEq(token.balanceOf(address(pool)), rawBefore - aliceAssets, "first claim conservation");
        assertEq(pool.totalClaimable(), bobAssets, "second claim was disturbed");
        pool.claimFor(receiverB);
        assertEq(token.balanceOf(address(pool)), rawBefore - aliceAssets - bobAssets, "final USDC conservation");
        assertEq(pool.totalClaimable(), 0, "claims did not clear");
        _assertRequestBounds(token, pool);
    }
}
