// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
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
import {RiskParams} from "../src/RiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @title What an exit costs while a mark stands, executed rather than argued
/// @notice Audit round 20 raised two findings against this pool and both are about the price a
///         lender is paid while a liquidation is open. This file is the executable half of the
///         answer: it fixes one of them, refutes the stated mechanism of the other, and sizes the
///         part that is a design decision rather than a defect.
///
/// @dev **The three things measured here, and which is which.**
///
///      **1. The bound that was missing, and now is not.** A lender reads `previewRedeem`, sends
///      `redeem`, and a stranger's permissionless `liquidate` lands in between. The price they are
///      paid moves by a factor of six and nothing in the ERC-4626 surface let them decline it. That
///      is fixed by the four-argument `withdraw`/`redeem` overloads, and the tests below hold the
///      bound to both directions: it refuses the front-run, and it does not refuse an honest exit.
///
///      **2. The mechanism round 20 named is not the one at work, and the difference matters
///      because it decides what to change.** The finding said `maxRedeem` round-trips a liquidity
///      cap through a depressed denominator while `maxWithdraw` "does not have the defect". Both
///      doors are executed here on one fixture and pay the identical amount for share counts 2,499
///      apart out of three trillion. `_exitToShares` and `_exitToAssets` are inverses, so the
///      round trip is exact; the fuzz below pins `previewRedeem(maxRedeem(o)) == maxWithdraw(o)`
///      to within two wei across the whole range of the mark. Had that asymmetry been real, this
///      is the assertion that would have caught it.
///
///      **3. What a leaver actually gives up is their pro-rata share of the mark, to the wei.**
///      Round 20's finding 2 reports a "3.14% haircut" as the price of escaping a frozen queue.
///      `test_theCostOfLeavingUnderAMarkIsExactlyProRata` shows that figure is the mark's own share
///      of the book and nothing else - the leaver takes exactly the fraction of the loss their
///      shares represent. `CreditManager._impairmentFor` documents that as the intended direction
///      of the whole-debt mark. It is a real cost to a leaver and it is not a penalty for having
///      queued.
///
///      **What is deliberately NOT here: a fix for the queue freeze.** One free permissionless
///      `expireToWorkout` converts a six-hour mark into a fourteen-day one and `serviceQueue`
///      refuses for all of it. `serviceQueue`'s own comment names the answer - "retire the node,
///      carry the claim, advance the cursor" - and
///      `test_payingAQueuedLenderEarlyWouldMoveTheMarkOntoWhoeverStays` measures why that is
///      larger than one pull request: the obvious version of it leaves the un-impaired share price
///      exactly unchanged and cuts the worst case for everyone who stayed by 45%. Rounds 12, 13
///      and 14 each shipped and then deleted a partial answer in this area, so it is measured and
///      reported rather than half-built.
contract LenderPoolExitPricingTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD, 8dp
    uint256 internal constant BONDS = 800;
    uint256 internal constant DEPOSIT = 3_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // borrower
    address internal leaver = makeAddr("leaver"); // the lender who exits
    address internal stayer = makeAddr("stayer"); // the lender who does not
    address internal stranger = makeAddr("stranger"); // no capital, no shares
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
    LenderPool internal pool;
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
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

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
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(harvester);
        // Both roles. `_socialise` refuses a pool that is not also the liquidity source, so this is
        // the only wiring in which the pool has exposure to mark against.
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        _depositAs(leaver);
        _depositAs(stayer);

        bond.mint(alice, 10_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _depositAs(address who) internal {
        usdc.mint(who, DEPOSIT);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(DEPOSIT, who);
        vm.stopPrank();
    }

    /// @dev Borrow at the per-account cap, then drop NAV a hair past the liquidation trigger.
    ///
    ///      **This is the ordinary liquidation, not a crash**, and that is what makes every number
    ///      below a finding rather than a description of a bad loan: the lot at this NAV clears the
    ///      debt with room to spare, so a fill realises no loss at all. `_realiseAtTheFloor` proves
    ///      that rather than asserting it.
    function _borrowAndBreach() internal returns (uint256 debt) {
        // Read before the prank. `perAccountBorrowCap()` is an external view now that the risk
        // parameters are storage, and `vm.prank` is spent by the next call including a staticcall.
        debt = perAccountBorrowCap();
        vm.prank(alice);
        credit.borrow(debt);
        uint256 navAtThreshold = _navAtThreshold(debt, BONDS);
        oracle.setNav(navAtThreshold - navAtThreshold / 100);
    }

    /// @dev Fill the lot and settle, so `lifetimeSocialisedLoss` is the realised answer.
    function _realiseAtTheFloor(uint256 id) internal {
        uint256 price = auction.currentPrice(id);
        usdc.mint(bidder, price);
        vm.startPrank(bidder);
        usdc.approve(address(auction), type(uint256).max);
        auction.bid(id);
        vm.stopPrank();
        credit.settlePrincipal();
    }

    // ── 1. The bound a leaver can now place on their own exit ────────────────

    /// @notice A stranger's `liquidate` between quote and execution no longer decides what a
    ///         bounded exit pays, and the unbounded door in the same block still takes it.
    /// @dev **Both halves are the test.** The refusal alone would only show the new code runs; the
    ///      second half is the finding, and it is what an assertion written before this change
    ///      would have missed. There was no earlier assertion here to compare against - the
    ///      unbounded doors have no bound to blind - so "the old one was blind" is stated by
    ///      executing it rather than by citing it.
    function test_aBoundedRedeemRefusesTheFrontRunTheUnboundedDoorAccepts() public {
        _borrowAndBreach();

        uint256 shares = pool.balanceOf(leaver);
        uint256 quoted = pool.previewRedeem(shares);
        assertEq(quoted, DEPOSIT, "the quote should be the whole stake before any mark");

        // The front-run: permissionless, zero capital, and it is the protocol working as designed.
        vm.prank(stranger);
        credit.liquidate(alice);

        uint256 nowPaid = pool.previewRedeem(shares);
        assertLt(nowPaid, quoted / 5, "the mark should have moved the price by more than 5x");

        // The bounded door refuses at the price the lender was quoted.
        vm.prank(leaver);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, nowPaid, quoted));
        pool.redeem(shares, leaver, leaver, quoted);
        assertEq(pool.balanceOf(leaver), shares, "the refused exit moved shares");

        // The unbounded door, same block, same shares: it pays the marked price and takes the lot.
        uint256 before = usdc.balanceOf(leaver);
        vm.prank(leaver);
        pool.redeem(shares, leaver, leaver);
        assertEq(usdc.balanceOf(leaver) - before, nowPaid, "the unbounded door did not pay the mark");
        assertEq(pool.balanceOf(leaver), 0, "the unbounded door left a stake behind");

        // And the loss the leaver just crystallised: none of it.
        _realiseAtTheFloor(auction.auctionOf(alice));
        assertEq(pool.lifetimeSocialisedLoss(), 0, "this scenario is supposed to realise no loss");
    }

    /// @notice The withdraw-side bound holds the share cost to what `previewWithdraw` quoted.
    function test_aBoundedWithdrawRefusesAShareCostAboveTheQuote() public {
        _borrowAndBreach();

        // Derived from the deposit rather than written down, and chosen to be reachable on both
        // sides of the mark: before it the leaver's cap is the idle balance, after it the cap is
        // this exact figure. So the only thing that changes between the two quotes is the price.
        uint256 assets = DEPOSIT / 6;
        uint256 quotedShares = pool.previewWithdraw(assets);
        assertLe(assets, pool.maxWithdraw(leaver), "the fixture cannot reach this withdrawal");

        vm.prank(stranger);
        credit.liquidate(alice);

        uint256 nowShares = pool.previewWithdraw(assets);
        assertGt(nowShares, quotedShares * 5, "the mark should have moved the share cost by 5x");

        uint256 held = pool.balanceOf(leaver);
        vm.prank(leaver);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.SharesAboveMaximum.selector, nowShares, quotedShares));
        pool.withdraw(assets, leaver, leaver, quotedShares);
        assertEq(pool.balanceOf(leaver), held, "the refused exit moved shares");

        // Unbounded, same block: it spends the six-fold share cost without a word.
        vm.prank(leaver);
        pool.withdraw(assets, leaver, leaver);
        assertEq(held - pool.balanceOf(leaver), nowShares, "the unbounded door did not spend the quoted shares");
    }

    /// @notice A bound the book can meet is not a refusal. Both doors go through untouched.
    /// @dev The other direction of the same guard: a check that always reverts would pass the test
    ///      above and would have made the exit unusable.
    function test_aBoundedExitAtTheCurrentPriceGoesStraightThrough() public {
        _borrowAndBreach();
        vm.prank(stranger);
        credit.liquidate(alice);

        uint256 shares = pool.maxRedeem(leaver);
        uint256 payable_ = pool.previewRedeem(shares);
        uint256 before = usdc.balanceOf(leaver);
        vm.prank(leaver);
        uint256 got = pool.redeem(shares, leaver, leaver, payable_);
        assertEq(got, payable_, "the bounded redeem paid something else");
        assertEq(usdc.balanceOf(leaver) - before, payable_, "the bounded redeem moved a different amount");

        uint256 assets = pool.maxWithdraw(stayer);
        uint256 cost = pool.previewWithdraw(assets);
        vm.prank(stayer);
        uint256 spent = pool.withdraw(assets, stayer, stayer, cost);
        assertEq(spent, cost, "the bounded withdraw spent something else");
    }

    /// @notice Any bound at or below what the pool would pay is accepted; anything above is not.
    /// @dev Fuzzed over the mark as well as over the bound, so the property is about the guard and
    ///      not about one book.
    function testFuzz_aBoundIsExactlyTheQuoteAndNothingElse(uint96 markRaw, uint96 boundRaw) public {
        uint256 debt = _borrowAndBreach();
        vm.prank(address(credit));
        pool.impair(alice, uint256(markRaw) % (debt + 1));

        uint256 shares = pool.maxRedeem(leaver);
        vm.assume(shares != 0);
        uint256 quote = pool.previewRedeem(shares);
        uint256 bound = uint256(boundRaw) % (2 * DEPOSIT);

        uint256 held = pool.balanceOf(leaver);
        if (bound > quote) {
            vm.prank(leaver);
            vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, quote, bound));
            pool.redeem(shares, leaver, leaver, bound);
            assertEq(pool.balanceOf(leaver), held, "a refused exit moved shares");
        } else {
            vm.prank(leaver);
            uint256 got = pool.redeem(shares, leaver, leaver, bound);
            assertEq(got, quote, "an accepted bound changed what was paid");
        }
    }

    // ── 2. The two max doors are one cliff, not two different ones ───────────

    /// @notice `withdraw(maxWithdraw)` and `redeem(maxRedeem)` pay the same money and burn the same
    ///         position. Round 20 attributed the loss to `maxRedeem` alone; it is neither view's.
    /// @dev The measured figures on this fixture, for whoever reads the finding next:
    ///      `totalAssets` 6,000.000000, `exitReserve` 5,000.000000, `exitAssets` 1,000.000000,
    ///      leaver holding 3,000,000,000,000 of 6,000,000,000,000 shares. WITHDRAW burns
    ///      2,999,999,997,501 for 500.000000; REDEEM burns 3,000,000,000,000 for 500.000000.
    function test_theTwoMaxDoorsAreTheSameCliff() public {
        _borrowAndBreach();
        vm.prank(stranger);
        credit.liquidate(alice);

        uint256 held = pool.balanceOf(leaver);
        uint256 snap = vm.snapshotState();

        uint256 before = usdc.balanceOf(leaver);
        uint256 maxW = pool.maxWithdraw(leaver);
        vm.prank(leaver);
        pool.withdraw(maxW, leaver, leaver);
        uint256 burnedByWithdraw = held - pool.balanceOf(leaver);
        uint256 paidByWithdraw = usdc.balanceOf(leaver) - before;

        vm.revertToState(snap);

        before = usdc.balanceOf(leaver);
        uint256 maxR = pool.maxRedeem(leaver);
        vm.prank(leaver);
        pool.redeem(maxR, leaver, leaver);
        uint256 burnedByRedeem = held - pool.balanceOf(leaver);
        uint256 paidByRedeem = usdc.balanceOf(leaver) - before;

        assertEq(paidByWithdraw, paidByRedeem, "the two doors paid different money");
        assertApproxEqAbs(burnedByWithdraw, burnedByRedeem, 10_000, "the two doors burned different positions");
        // Both consume essentially the whole stake, and that is the harm: it is on both doors, not
        // on one of them. Stated as "what is left is under a hundred-thousandth of what was held",
        // because a basis-point comparison rounds the difference away and reads as a pass either
        // way. Measured: 2,499 shares left of 3,000,000,000,000 on the withdraw door, 0 on redeem.
        assertLt(held - burnedByWithdraw, held / 100_000, "withdraw left a meaningful stake");
        assertLt(held - burnedByRedeem, held / 100_000, "redeem left a meaningful stake");
    }

    /// @notice `previewRedeem(maxRedeem(o))` is `maxWithdraw(o)`, across the whole range of a mark.
    /// @dev The assertion that would have caught the asymmetry the round described, had it existed.
    ///      Both are also held under the liquidity cap they are derived from, which is the property
    ///      `maxRedeem` actually owes: it may not report shares whose execution takes more cash
    ///      than the pool has spare.
    function testFuzz_theTwoMaxDoorsAgreeOnWhatAMarkCosts(uint96 markRaw) public {
        uint256 debt = _borrowAndBreach();
        vm.prank(address(credit));
        pool.impair(alice, uint256(markRaw) % (debt + 1));

        uint256 paidByRedeem = pool.previewRedeem(pool.maxRedeem(leaver));
        uint256 maxW = pool.maxWithdraw(leaver);
        uint256 spare = pool.unreservedIdle();

        assertApproxEqAbs(paidByRedeem, maxW, 2, "the two max doors disagree on the assets");
        assertLe(paidByRedeem, spare + 1, "maxRedeem reports more than the pool can pay");
        assertLe(maxW, spare, "maxWithdraw reports more than the pool can pay");
        assertLe(pool.maxRedeem(leaver), pool.balanceOf(leaver), "maxRedeem reports more than is held");
    }

    // ── 3. Round 20's finding 2, measured and bounded ────────────────────────

    /// @notice One free transaction turns a six-hour mark into a fourteen-day one and the queue
    ///         refuses for all of it. Control: the same instant, filled instead, resolves and pays.
    /// @dev **This is a measurement, not a fix.** The lever is `expireToWorkout`, which is
    ///      permissionless and costs the caller nothing but gas, and the duration it selects is
    ///      `Config.WORKOUT_MAX_DURATION`. `Config.AUCTION_RESET_WINDOW` bounds re-strikes and does
    ///      not reach this, so the cost model that window was chosen under does not cover it.
    ///      Recorded here because the state it produces is a `LenderPool` state and this is where
    ///      somebody will come looking for it.
    function test_oneFreeTransactionHoldsTheQueueForFourteenDays() public {
        _borrowAndBreach();
        vm.prank(stranger);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        (, uint96 startedAt,,,,,,) = auction.auctions(id);

        uint256 queued = pool.balanceOf(leaver);
        vm.prank(leaver);
        pool.requestWithdrawal(queued, leaver);

        uint256 snap = vm.snapshotState();

        // CONTROL: a floor fill at the boundary. Resolves, reopens and pays in full, same block.
        vm.warp(uint256(startedAt) + Config.AUCTION_DURATION);
        _realiseAtTheFloor(id);
        assertEq(pool.exitReserve(), 0, "the fill left a reserve standing");
        assertEq(pool.serviceQueue(5), 1, "the fill did not reopen the queue");
        assertEq(pool.lifetimeSocialisedLoss(), 0, "the fill realised a loss");
        vm.prank(leaver);
        assertEq(pool.claim(), DEPOSIT, "the control did not return the whole stake");

        vm.revertToState(snap);

        // ATTACK: a stranger with no shares and no capital, at the same instant.
        vm.warp(uint256(startedAt) + Config.AUCTION_DURATION);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertGt(pool.exitReserve(), 0, "the workout left no reserve");

        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(5);

        // Still shut one second short of the forced close, which is the whole of the window.
        vm.warp(block.timestamp + Config.WORKOUT_MAX_DURATION - 1);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(5);
        assertEq(Config.WORKOUT_MAX_DURATION / 1 days, 14, "the frozen window is not fourteen days");

        // The escape `serviceQueue` names is real and unguarded. It is priced, which is the next
        // test.
        vm.startPrank(leaver);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(leaver), queued, "the cancel did not return the shares");
        uint256 reachable = pool.maxWithdraw(leaver);
        assertGt(reachable, 0, "the escape hatch was shut too");
        pool.withdraw(reachable, leaver, leaver);
        vm.stopPrank();
    }

    /// @notice What the escape costs is the mark's own share of the book, to within a wei of
    ///         rounding. It is pro-rata exposure, not a penalty for having queued.
    /// @dev Round 20 reports the escape as "a 3.14% haircut for a loss the control shows would have
    ///      been zero". Both halves are true and the second is the finding; the first is not a
    ///      haircut in the sense of a fee. The two ratios below are computed from independent reads
    ///      - one from the lender's own two valuations, one from the book - and they agree, which
    ///      is what "pro-rata" means when it is measured instead of asserted.
    ///
    ///      Direction, because it decides who a change here would be for: this is a cost to a
    ///      *leaver* and a matching gain to a *stayer*, and `CreditManager._impairmentFor` calls
    ///      that the intended direction of the whole-debt mark - "an over-mark costs a leaver some
    ///      of their upside, an under-mark hands them somebody else's principal". Narrowing it is a
    ///      change to the mark, in that file, not to this one.
    function test_theCostOfLeavingUnderAMarkIsExactlyProRata() public {
        _borrowAndBreach();
        vm.prank(stranger);
        credit.liquidate(alice);

        uint256 held = pool.balanceOf(leaver);
        uint256 unimpaired = pool.convertToAssets(held);
        uint256 marked = pool.previewRedeem(held);
        assertGt(unimpaired, marked, "the mark did not reach the leaver's valuation");

        uint256 haircutE18 = ((unimpaired - marked) * 1e18) / unimpaired;
        uint256 markShareE18 = (pool.exitReserve() * 1e18) / pool.totalAssets();

        assertApproxEqAbs(haircutE18, markShareE18, 1e6, "the leaver's cost is not the mark's share of the book");
    }

    /// @notice Paying a queued lender out of the unreserved book while the mark stands leaves the
    ///         un-impaired share price untouched and cuts every stayer's worst case.
    /// @dev **This is the sizing of the contingent-entitlement branch `serviceQueue` describes, and
    ///      it is why that branch is not in this pull request.** The obvious construction is to
    ///      treat the book as `exitAssets()` of value that is certain and `exitReserve()` of value
    ///      that is at risk, pay a queued lender their pro-rata share of the certain part now at
    ///      the un-impaired price, and leave the rest of their entry alive against the mark. The
    ///      arithmetic below runs that construction over the live book without executing it.
    ///
    ///      It is neutral on the price everybody quotes and not neutral on the price that matters
    ///      while a mark stands: the leaver removes only unreserved assets, so the reserve is
    ///      spread over a smaller remaining book and concentrates on whoever did not go. Measured
    ///      on this fixture the stayer's worst case falls by about 45%. A partial answer that moves
    ///      a loss onto the party who stayed is the shape rounds 12, 13 and 14 each shipped and
    ///      then deleted, so this is reported rather than built.
    function test_payingAQueuedLenderEarlyWouldMoveTheMarkOntoWhoeverStays() public {
        _borrowAndBreach();
        vm.prank(stranger);
        credit.liquidate(alice);

        uint256 supply = pool.totalSupply();
        uint256 assets = pool.totalAssets();
        uint256 unreserved = pool.exitAssets();
        uint256 leaverShares = pool.balanceOf(leaver);
        uint256 stayerShares = pool.balanceOf(stayer);

        // The hypothetical early payment and the shares it would burn at the un-impaired price.
        uint256 payout = (leaverShares * unreserved) / supply;
        uint256 burned = (payout * supply) / assets;

        uint256 supplyAfter = supply - burned;
        uint256 assetsAfter = assets - payout;
        uint256 unreservedAfter = unreserved - payout;

        // Neutral on the number every integrator reads.
        assertApproxEqAbs(
            (assetsAfter * 1e18) / supplyAfter,
            (assets * 1e18) / supply,
            1e3,
            "the un-impaired price moved, so the construction is not the one described"
        );

        // Not neutral on the number that decides what a stayer keeps if the mark lands.
        uint256 stayerBefore = (stayerShares * unreserved) / supply;
        uint256 stayerAfter = (stayerShares * unreservedAfter) / supplyAfter;
        assertLt(stayerAfter, stayerBefore, "the early payment did not concentrate the mark");
        // At least a 40% cut. Measured on this fixture: 500.000000 becomes 272.727272, a 45.5% cut.
        assertLt(stayerAfter * 10, stayerBefore * 6, "the concentration was smaller than reported");
    }
}
