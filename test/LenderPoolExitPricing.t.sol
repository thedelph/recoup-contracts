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
///      Round 20's finding 2 reports a "3.14% haircut" as the price of escaping a frozen request.
///      `test_theCostOfLeavingUnderAMarkIsExactlyProRata` shows that figure is the mark's own share
///      of the book and nothing else - the leaver takes exactly the fraction of the loss their
///      shares represent. `CreditManager._impairmentFor` documents that as the intended direction
///      of the whole-debt mark. It is a real cost to a leaver and it is not a penalty for having
///      requested an exit.
///
///      **What changed for controller requests.** A request no longer sits behind a global FIFO
///      refusal. Its controller, or an operator the controller approved, chooses whether and how
///      much to service at the live marked price. `minAssetsOut` is transaction-local: it can
///      refuse the controller's own execution and cannot pin another request. The six-hour auction
///      mark, the fourteen-day workout mark and the unbounded lifetime of an unclosed workout are
///      all still measured below because changing settlement authority does not change the mark.
///
///      The rejected alternative is still sized here. Paying a request at the un-impaired price
///      while a mark stands leaves that price unchanged and makes the worst case WORSE for everyone
///      who stayed, cutting what a stayer keeps by 45.45% - 500.000000 becomes 272.727272. The
///      controller design instead pays `previewRedeem`, so that transfer is not built.
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
    ///
    ///      **Driven on `maxRedeem` rather than on the whole balance since audit round 22 finding
    ///      2, and the substitution is the finding.** This used to redeem `balanceOf(leaver)` -
    ///      3,000,000,000,000 shares, the entire stake - in one call for 500.000000, which is the
    ///      hole that finding closes. `maxRedeem` is now a real cap and reports 1,000,000,000,000
    ///      here, **the same figure before and after the `liquidate`**, because the liquidity cap is
    ///      converted on the un-impaired book and a mark does not move it. So the only thing that
    ///      changes between the two quotes is still the price, which is what this test is about,
    ///      and the front-run is still a six-fold move. The assertion that the leaver is left with
    ///      nothing has gone with it: a third of the stake now stays, which is the point.
    function test_aBoundedRedeemRefusesTheFrontRunTheUnboundedDoorAccepts() public {
        _borrowAndBreach();

        uint256 held = pool.balanceOf(leaver);
        uint256 shares = pool.maxRedeem(leaver);
        uint256 quoted = pool.previewRedeem(shares);
        assertGt(shares, 0, "fixture: the exit door must be open before the mark");
        assertLt(shares, held, "fixture: the cap must bind, or this says nothing about the cap");

        // The front-run: permissionless, zero capital, and it is the protocol working as designed.
        vm.prank(stranger);
        credit.liquidate(alice);

        assertEq(pool.maxRedeem(leaver), shares, "the mark moved the share cap, so the price is not isolated");
        uint256 nowPaid = pool.previewRedeem(shares);
        assertLt(nowPaid, quoted / 5, "the mark should have moved the price by more than 5x");

        // The bounded door refuses at the price the lender was quoted.
        vm.prank(leaver);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, nowPaid, quoted));
        pool.redeem(shares, leaver, leaver, quoted);
        assertEq(pool.balanceOf(leaver), held, "the refused exit moved shares");

        // The unbounded door, same block, same shares: it pays the marked price and takes what the
        // cap allows.
        uint256 before = usdc.balanceOf(leaver);
        vm.prank(leaver);
        pool.redeem(shares, leaver, leaver);
        assertEq(usdc.balanceOf(leaver) - before, nowPaid, "the unbounded door did not pay the mark");
        assertEq(pool.balanceOf(leaver), held - shares, "the unbounded door took more than its cap");

        // And the loss the leaver just crystallised: none of it.
        _realiseAtTheFloor(auction.auctionOf(alice));
        assertEq(pool.lifetimeSocialisedLoss(), 0, "this scenario is supposed to realise no loss");
    }

    /// @notice The withdraw-side bound holds the share cost to what `previewWithdraw` quoted.
    function test_aBoundedWithdrawRefusesAShareCostAboveTheQuote() public {
        _borrowAndBreach();

        // Derived from the deposit rather than written down, and chosen to be reachable on both
        // sides of the mark, so the only thing that changes between the two quotes is the price.
        //
        // **`DEPOSIT / 6` until audit round 22 finding 2, and that divisor was the old cap.** Before
        // the mark the leaver's cap was the whole idle balance, 1,000.000000; after it, the cap was
        // exactly `DEPOSIT / 6` - which is to say the leaver could still take 500.000000 of cash,
        // but only by burning practically the whole 3,000.000000 stake to do it. `maxWithdraw` is
        // now derived from `maxRedeem` and reports 166.666666 under the mark, so the figure has to
        // sit below that to stay reachable on both sides. The 5x price move this test is about is
        // unchanged; what moved is how much of it one call may take.
        uint256 assets = DEPOSIT / 20;
        uint256 quotedShares = pool.previewWithdraw(assets);
        assertLe(assets, pool.maxWithdraw(leaver), "the fixture cannot reach this withdrawal");

        vm.prank(stranger);
        credit.liquidate(alice);

        assertLe(assets, pool.maxWithdraw(leaver), "the mark closed the door, so the price is not isolated");
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

    // ── 2. The two max doors are one door, and the cliff is gone ─────────────

    /// @notice `withdraw(maxWithdraw)` and `redeem(maxRedeem)` pay the same money and burn the same
    ///         position. Round 20 attributed the loss to `maxRedeem` alone; it is neither view's.
    /// @dev The measured figures on this fixture, for whoever reads the finding next:
    ///      `totalAssets` 6,000.000000, `exitReserve` 5,000.000000, `exitAssets` 1,000.000000,
    ///      leaver holding 3,000,000,000,000 of 6,000,000,000,000 shares. Round 20 measured WITHDRAW
    ///      burning 2,999,999,997,501 for 500.000000 and REDEEM burning 3,000,000,000,000 for the
    ///      same 500.000000 - one cliff on two doors, which is what this test was named for.
    ///
    ///      **Audit round 22 finding 2 removed the cliff, and the last two assertions are inverted
    ///      rather than deleted.** Both doors now burn 1,000,000,000,000 for 166.666666 and leave
    ///      2,000,000,000,000 standing: two thirds of the stake, not two thousandths of a percent.
    ///      The claim this file was written to make survives unchanged - the two doors are still one
    ///      door, and the loss was never `maxRedeem`'s alone - and what changed is the size of what
    ///      one call can take. Inverted here because a test that asserts a defect has to be turned
    ///      round when the defect goes, or it becomes a test that forbids the fix.
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
        // **INVERTED by audit round 22 finding 2.** These two used to read
        // `assertLt(held - burned, held / 100_000)` - "what is left is under a hundred-thousandth of
        // what was held" - because both doors consumed essentially the whole stake and that was the
        // harm. Neither does now: MEASURED 2,000,000,004,833 shares left of 3,000,000,000,000 on the
        // withdraw door and 2,000,000,000,000 on redeem, against a pre-fix 2,499 and 0. Asserted as
        // "more than half the stake survives one call" rather than against the exact residue,
        // because the exact residue is a function of the fixture's cash-to-book ratio and the claim
        // is that a whole-loan mark can no longer empty the position.
        assertGt(held - burnedByWithdraw, held / 2, "withdraw consumed the stake for the idle cash");
        assertGt(held - burnedByRedeem, held / 2, "redeem consumed the stake for the idle cash");
    }

    /// @notice `previewRedeem(maxRedeem(o))` is `maxWithdraw(o)`, across the whole range of a mark.
    /// @dev The assertion that would have caught the asymmetry the round described, had it existed.
    ///      Both are also held under the liquidity cap they are derived from, which is the property
    ///      `maxRedeem` actually owes: it may not report shares whose execution takes more cash
    ///      than the pool has spare.
    ///
    ///      **Tightened from two wei to exact by audit round 22 finding 2.** `maxWithdraw` *is*
    ///      `previewRedeem(maxRedeem(owner))` now, which is what OpenZeppelin 5.6.1's base
    ///      `ERC4626` does and what this contract broke by overriding the two independently. The
    ///      two-wei tolerance was the right assertion against a pair that only nearly agreed; an
    ///      equality is the right one against a pair where one is defined as the other, and it is
    ///      what keeps the reported maximum an executable bound rather than a quote.
    function testFuzz_theTwoMaxDoorsAgreeOnWhatAMarkCosts(uint96 markRaw) public {
        uint256 debt = _borrowAndBreach();
        vm.prank(address(credit));
        pool.impair(alice, uint256(markRaw) % (debt + 1));

        uint256 paidByRedeem = pool.previewRedeem(pool.maxRedeem(leaver));
        uint256 maxW = pool.maxWithdraw(leaver);
        uint256 spare = pool.unreservedIdle();

        assertEq(paidByRedeem, maxW, "the two max doors disagree on the assets");
        assertLe(paidByRedeem, spare + 1, "maxRedeem reports more than the pool can pay");
        assertLe(maxW, spare, "maxWithdraw reports more than the pool can pay");
        assertLe(pool.maxRedeem(leaver), pool.balanceOf(leaver), "maxRedeem reports more than is held");
    }

    // ── 3. Round 20's finding 2, measured and bounded ────────────────────────

    /// @notice A controller can settle at the live price under both the six-hour auction mark and
    ///         the fourteen-day workout mark. A stranger cannot choose the settlement instant.
    /// @dev The duration lever is still `expireToWorkout`, which is
    ///      permissionless and costs the caller nothing but gas, and the duration it selects is
    ///      `Config.WORKOUT_MAX_DURATION`. `Config.AUCTION_RESET_WINDOW` bounds re-strikes and does
    ///      not reach this. The mark remains; only the global service refusal is gone.
    ///
    ///      The control remains the same instant filled instead: it resolves, realises no loss and
    ///      lets the controller service the full request. The two marked branches pin the new
    ///      authority and the transaction-local execution bound.
    function test_controllerChoosesServiceAtSixHoursAndFourteenDays() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        uint256 snap = vm.snapshotState();

        // CONTROL: a floor fill at the boundary. Resolves, reopens and pays in full, same block.
        vm.warp(finishesAt);
        _realiseAtTheFloor(id);
        assertEq(pool.exitReserve(), 0, "the fill left a reserve standing");
        uint256 controlShares = pool.maxRequestRedeem(leaver);
        uint256 controlQuote = pool.previewRedeem(controlShares);
        vm.prank(leaver);
        pool.serviceWithdrawalRequest(leaver, controlShares, controlQuote);
        assertEq(pool.lifetimeSocialisedLoss(), 0, "the fill realised a loss");
        vm.prank(leaver);
        assertEq(pool.claim(), DEPOSIT, "the control did not return the whole stake");

        vm.revertToState(snap);

        // At six hours the auction mark still stands. The controller owns settlement and its
        // minimum is local to this call.
        vm.warp(finishesAt);
        uint256 sixHourMark = pool.exitReserve();
        assertGt(sixHourMark, 0, "the six-hour auction mark disappeared");
        uint256 sixHourShares = pool.maxRequestRedeem(leaver);
        uint256 sixHourQuote = pool.previewRedeem(sixHourShares);
        assertGt(sixHourShares, 0, "the six-hour request was not serviceable");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(LenderPool.UnauthorizedRequestOperator.selector, leaver, stranger)
        );
        pool.serviceWithdrawalRequest(leaver, sixHourShares, sixHourQuote);

        (,, uint256 requestSharesBefore,,) = pool.withdrawalRequest(leaver);
        vm.prank(leaver);
        vm.expectRevert(
            abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, sixHourQuote, sixHourQuote + 1)
        );
        pool.serviceWithdrawalRequest(leaver, sixHourShares, sixHourQuote + 1);
        (,, uint256 requestSharesAfter,,) = pool.withdrawalRequest(leaver);
        assertEq(requestSharesAfter, requestSharesBefore, "the refused bound changed the request");

        uint256 markedSnap = vm.snapshotState();
        vm.prank(leaver);
        assertEq(
            pool.serviceWithdrawalRequest(leaver, sixHourShares, sixHourQuote),
            sixHourQuote,
            "the exact six-hour quote did not settle"
        );
        assertEq(pool.claimable(leaver), sixHourQuote, "the six-hour service did not create the fixed claim");

        vm.revertToState(markedSnap);

        // A stranger may move the auction into workout, but still cannot settle the request.
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertGt(pool.exitReserve(), 0, "the workout left no reserve");
        vm.warp(finishesAt + Config.WORKOUT_MAX_DURATION);
        assertEq(Config.WORKOUT_MAX_DURATION / 1 days, 14, "the workout window is not fourteen days");
        uint256 fourteenDayShares = pool.maxRequestRedeem(leaver);
        uint256 fourteenDayQuote = pool.previewRedeem(fourteenDayShares);
        assertGt(fourteenDayShares, 0, "the fourteen-day request was not serviceable");
        vm.prank(leaver);
        assertEq(
            pool.serviceWithdrawalRequest(leaver, fourteenDayShares, fourteenDayQuote),
            fourteenDayQuote,
            "the exact fourteen-day quote did not settle"
        );
    }

    /// @notice What the escape costs is the mark's own share of the book, to within a wei of
    ///         rounding. It is pro-rata exposure, not a penalty for having requested an exit.
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

    /// @notice Paying a requested lender out of the unreserved book while the mark stands leaves the
    ///         un-impaired share price untouched and cuts every stayer's worst case.
    /// @dev **This is the sizing of the un-impaired-price alternative, and why it is not used.**
    ///      The obvious construction is to
    ///      treat the book as `exitAssets()` of value that is certain and `exitReserve()` of value
    ///      that is at risk, pay a requested lender their pro-rata share of the certain part now at
    ///      the un-impaired price, and leave the rest of their entry alive against the mark. The
    ///      arithmetic below runs that construction over the live book without executing it.
    ///
    ///      It is neutral on the price everybody quotes and not neutral on the price that matters
    ///      while a mark stands: the leaver removes only unreserved assets, so the reserve is
    ///      spread over a smaller remaining book and concentrates on whoever did not go. Measured
    ///      on this fixture, what a stayer KEEPS falls by 45.45% - 500.000000 becomes 272.727272 -
    ///      so the stayer's worst case gets WORSE, not better. A partial answer that moves a loss
    ///      onto the party who stayed is the shape rounds 12, 13 and 14 each shipped and then
    ///      deleted, so this is reported rather than built.
    ///
    ///      **This said "the stayer's worst case falls by about 45%" until 2026-08-22**, which
    ///      reads as the stayer being better off. The assertion in the body has always been
    ///      `assertLt(stayerAfter, stayerBefore)`, so the prose contradicted the test directly
    ///      beneath it. Round 21 filed the inversion; round 23 re-counted the surviving sites as
    ///      one; there were three.
    function test_payingARequestedLenderAtTheUnimpairedPriceWouldMoveTheMarkOntoWhoeverStays() public {
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

    // ── 4. The duration lever, re-derived. Audit round 20's finding 2, reopened ──

    /// @dev Stage round 20's finding 2: a breached position, a stranger's `liquidate`, and the
    ///      whole of the leaver's stake held in a controller-scoped withdrawal request.
    function _stageTheParkedMark() private returns (uint256 id, uint256 finishesAt) {
        _borrowAndBreach();
        vm.prank(stranger);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        (, uint96 startedAt,,,,,,) = auction.auctions(id);
        finishesAt = uint256(startedAt) + Config.AUCTION_DURATION;
        // Read before the prank. `vm.prank` is spent by the next call including a staticcall, and
        // writing this as one statement charged the balance read to `leaver` and the withdrawal
        // request to this test contract, which holds nothing. Seventh instance in this project.
        uint256 held = pool.balanceOf(leaver);
        vm.prank(leaver);
        pool.requestWithdrawal(held, leaver);
    }

    /// @notice `Config.WORKOUT_MAX_DURATION` is a floor under the mark, not a ceiling over it.
    /// @dev **This corrects round 20's finding 2 rather than restating it.** The finding is written
    ///      as "one permissionless transaction at hour six buys fourteen days of frozen exits", and
    ///      fourteen days reads as the bound. It is not. `CreditManager._impairmentFor` keys the
    ///      mark on `workoutsOpenFor(borrower) != 0`, and the only statement that decrements that
    ///      register is inside `closeWorkout` - which is permissionless, unrewarded and optional.
    ///      So the constant sets the earliest instant a volunteer *may* end the mark and nothing
    ///      sets a latest one. Measured below at thirty days past the forced-close boundary, with
    ///      the reserve unmoved.
    ///
    ///      This is audit round 19's critical 2 - "a reserve nobody releases" - one register over.
    ///      Round 19 bounded the auction register with `Config.AUCTION_RESET_WINDOW`. Nothing
    ///      bounds the workout register, because the bound it is given is a permission rather than
    ///      an event.
    ///
    ///      Direction worth keeping: there is at least one party with a live incentive to make the
    ///      call, which is why this is a correction and not a new critical. `closeWorkout` clears
    ///      the borrower's residual debt and decrements the register that blocks them borrowing
    ///      again, so the defaulter is the one actor who gains by ending it. Lenders gain by
    ///      waiting, because the close is what turns a releasable mark into a realised loss.
    function test_theWorkoutMarkIsBoundedBelowByTheConstantAndAboveByNothing() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        vm.warp(finishesAt);
        vm.prank(stranger);
        auction.expireToWorkout(id);

        uint256 markedAtOpen = pool.exitReserve();
        assertGt(markedAtOpen, 0, "the workout opened without a mark");
        assertGt(pool.maxRequestRedeem(leaver), 0, "the live mark made the request unserviceable");
        vm.warp(finishesAt + Config.WORKOUT_MAX_DURATION - 1);
        assertEq(pool.exitReserve(), markedAtOpen, "the mark moved one second short of forced close");
        assertGt(pool.maxRequestRedeem(leaver), 0, "the request lost serviceability before forced close");
        vm.warp(finishesAt + Config.WORKOUT_MAX_DURATION);
        assertEq(pool.exitReserve(), markedAtOpen, "the constant released the mark by itself at the boundary");
        assertGt(pool.maxRequestRedeem(leaver), 0, "the request lost serviceability at the boundary");
        vm.warp(finishesAt + Config.WORKOUT_MAX_DURATION + 30 days);
        assertEq(pool.exitReserve(), markedAtOpen, "the constant released the mark by itself thirty days later");

        uint256 heldOpen = pool.exitReserve();
        assertEq(heldOpen, markedAtOpen, "the held-open mark changed without a workout transition");

        // Only the call ends it, and ending it is what makes the loss permanent.
        assertEq(pool.lifetimeSocialisedLoss(), 0, "the loss was realised before the close");
        vm.prank(stranger);
        auction.closeWorkout(id);
        assertEq(pool.exitReserve(), 0, "the forced close did not release the mark");
        assertGt(pool.maxRequestRedeem(leaver), 0, "the close made the request unserviceable");
        assertEq(pool.lifetimeSocialisedLoss(), heldOpen, "the close did not realise what was marked");
    }

    /// @notice The alternative to the workout is not a fill. It is a mark with no clock at all.
    /// @dev Round 20's finding 2 prices `expireToWorkout` against a control that fills the lot at
    ///      the same instant, and reads the difference as what the call costs. That control is the
    ///      right one for the *loss* and the wrong one for the *duration*: a fill is not available
    ///      to the caller of `expireToWorkout` and is not what happens if they decline. What
    ///      happens if they decline is this. `auctionOf` is not cleared by a lapse - deliberately,
    ///      see `CreditManager._impairmentFor` - so the mark stands with nothing counting down
    ///      against it, and `expireToWorkout` is still the only legal move a year later.
    ///
    ///      So the call converts an unbounded mark into one with a floor under its end. Any
    ///      candidate that makes the call rarer, harder or more expensive moves the protocol
    ///      towards this state, which is the one the candidate was trying to avoid.
    function test_decliningToExpireLeavesTheMarkWithNoClockAtAll() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        uint256 marked = pool.exitReserve();
        assertGt(marked, 0, "the liquidation left no mark");

        vm.warp(finishesAt + 1);
        assertEq(pool.exitReserve(), marked, "the lapse alone released the mark");
        assertGt(pool.maxRequestRedeem(leaver), 0, "the lapsed mark made the request unserviceable");
        vm.warp(finishesAt + 365 days);
        assertEq(pool.exitReserve(), marked, "the mark decayed on its own");
        assertGt(pool.maxRequestRedeem(leaver), 0, "the year-old mark made the request unserviceable");
        assertEq(auction.workoutsOpenFor(alice), 0, "a workout opened without a caller");

        // And the exit under study is still the only move.
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertGt(auction.workoutsOpenFor(alice), 0, "expireToWorkout stopped being legal");
    }

    /// @notice What the free call forecloses is the re-strike, not the fill - and the fill it is
    ///         measured against is unreachable one second later anyway.
    /// @dev **This is the harm that survives measurement, and it is not a duration.** `bid` is
    ///      legal while `block.timestamp <= startedAt + AUCTION_DURATION` and `expireToWorkout`
    ///      from `>=`, so the two overlap for exactly one instant and are complements everywhere
    ///      else. After that instant the lot is off the market entirely - `currentPrice` and `bid`
    ///      both revert `AuctionLapsed` - until somebody pays gas for an unrewarded re-strike.
    ///
    ///      The control below re-strikes one second after the lapse and the lot clears the debt at
    ///      the new floor with `lifetimeSocialisedLoss` at zero. The attack expires at the same
    ///      instant, and `liquidate` then reverts `WorkoutAlreadyOpen` for the whole workout, so
    ///      seven further attempts inside `Config.AUCTION_RESET_WINDOW` are gone. The delta is the
    ///      whole debt, not a haircut on one lender.
    function test_expiringAtTheFirstLapseForeclosesEveryRemainingRestrike() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        uint256 snap = vm.snapshotState();

        // The lot is off the market the moment the window lapses, either way.
        vm.warp(finishesAt + 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, id));
        auction.currentPrice(id);

        // CONTROL: re-strike, and the lot clears the debt at the new floor.
        vm.prank(stranger);
        credit.liquidate(alice);
        (, uint96 restruckAt,,,,,,) = auction.auctions(id);
        vm.warp(uint256(restruckAt) + Config.AUCTION_DURATION);
        _realiseAtTheFloor(id);
        assertEq(pool.exitReserve(), 0, "the re-struck fill left a reserve standing");
        assertEq(pool.lifetimeSocialisedLoss(), 0, "the re-struck fill realised a loss");

        vm.revertToState(snap);

        // ATTACK: the same instant, expired instead. Every later attempt is refused.
        vm.warp(finishesAt + 1);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.WorkoutAlreadyOpen.selector, alice));
        vm.prank(stranger);
        credit.liquidate(alice);

        vm.warp(block.timestamp + Config.WORKOUT_MAX_DURATION);
        vm.prank(stranger);
        auction.closeWorkout(id);
        assertGt(pool.lifetimeSocialisedLoss(), 0, "the foreclosed path realised no loss");
    }

    /// @notice `bid` and `expireToWorkout` overlap for exactly one instant, and that instant is
    ///         worth one tick of the decay curve.
    /// @dev Pinned in both directions because the pair are complements and a change to either
    ///      predicate has to state what it does to the other - the same rule
    ///      `expireToWorkout`'s own dispatch is built on. The tick is the reason the obvious
    ///      one-character fix here (`<` becomes `<=`, removing the overlap) is not worth its
    ///      churn: measured on this fixture the last second of the curve is 0.990000 USDC on a
    ///      6,732.000000 lot, 0.0147%, and a bidder who wants none of that risk bids a second
    ///      earlier for that price.
    function test_theBidAndExpireWindowsOverlapForExactlyOneInstant() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        uint256 snap = vm.snapshotState();

        vm.warp(finishesAt - 1);
        uint256 oneEarly = auction.currentPrice(id);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionStillRunning.selector, finishesAt));
        auction.expireToWorkout(id);

        vm.warp(finishesAt);
        uint256 atFloor = auction.currentPrice(id);
        vm.prank(stranger);
        auction.expireToWorkout(id); // both legal, in one block
        vm.revertToState(snap);

        vm.warp(finishesAt + 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, id));
        auction.currentPrice(id);
        vm.prank(stranger);
        auction.expireToWorkout(id);

        assertGt(oneEarly, atFloor, "the curve had stopped decaying before the boundary");
        assertLt((oneEarly - atFloor) * 1_000, oneEarly, "the boundary tick is worth more than 0.1%");
    }

    /// @notice Servicing at the marked price or waiting for the matching write-down preserves the
    ///         controller's value to the wei.
    /// @dev **This is the falsifier every duration candidate has to clear.**
    ///      Round 20's finding 2 prices the delay as "a 3.14% haircut for a loss the control
    ///      shows would have been zero". The haircut is real and it is the mark's pro-rata share -
    ///      `test_theCostOfLeavingUnderAMarkIsExactlyProRata` measures that. What it is *not* is a
    ///      price of the *duration*: the controller who services at hour six and the controller who
    ///      waits for the workout close finish holding the same value, because the mark is an exact
    ///      forecast of the write-down the close performs. Whichever route they take, they end at
    ///      their pro-rata share of what is left.
    ///
    ///      Both paths are valued at the same wall clock and both count cash plus what is still in
    ///      hand, or the comparison would be measuring the clock rather than the price. Measured:
    ///      500.000000 against 500.000000.
    ///
    ///      Consequence: changing the settlement authority removes the foreign timing choice, but
    ///      shortening or pricing the mark's duration still transfers no value to the party the
    ///      finding names. What the duration costs is liquidity timing, which is real and is not a
    ///      loss.
    function test_servicingAtTheMarkOrWaitingForTheWriteDownPreservesTheLeaversValue() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        vm.warp(finishesAt);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        uint256 snap = vm.snapshotState();

        // PATH 1: the controller services the currently cash-funded slice at hour six.
        uint256 earlyShares = pool.maxRequestRedeem(leaver);
        uint256 earlyQuote = pool.previewRedeem(earlyShares);
        vm.prank(leaver);
        pool.serviceWithdrawalRequest(leaver, earlyShares, earlyQuote);
        vm.warp(finishesAt + Config.WORKOUT_MAX_DURATION);
        vm.prank(stranger);
        auction.closeWorkout(id);
        (,, uint256 remainingRequestShares,,) = pool.withdrawalRequest(leaver);
        uint256 servicedEarly = pool.claimable(leaver) + pool.previewRedeem(remainingRequestShares);

        vm.revertToState(snap);

        // PATH 2: leave the whole request live until the matching write-down is realised.
        vm.warp(finishesAt + Config.WORKOUT_MAX_DURATION);
        vm.prank(stranger);
        auction.closeWorkout(id);
        (,, uint256 waitedRequestShares,,) = pool.withdrawalRequest(leaver);
        uint256 waitedForWriteDown = pool.previewRedeem(waitedRequestShares);

        assertEq(servicedEarly, waitedForWriteDown, "service timing moved value between the two routes");
        assertGt(servicedEarly, 0, "the fixture paid the lender nothing on either route");
    }

    /// @notice The caller who ends the sale process is paid for it, and a re-strike pays nothing.
    /// @dev Round 20 records the attack as costing "zero capital". It is stronger than that:
    ///      `expireToWorkout` resolves the parked bounty as **earned**, so the keeper who opened
    ///      the auction collects `Config.LIQUIDATION_CALL_BOUNTY` the moment the workout opens.
    ///      `start`'s re-strike branch resolves nothing, by design and correctly - the same
    ///      auction is still open. The consequence is an incentive rather than a defect in either
    ///      statement: the party owed the bounty is paid to end the sale process at the first
    ///      lapse rather than to let the remaining attempts run.
    ///
    ///      Recorded rather than fixed. Withholding it was built and refuted when round 20's
    ///      finding 2 was reopened: `resolveBounty(id, false)` refunds the borrower, which is audit
    ///      round 19's finding, and the expiry is the one outcome the escrow was introduced for.
    function test_theCallerWhoEndsTheSaleProcessIsPaidAndARestrikePaysNothing() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        uint256 snap = vm.snapshotState();

        // A re-strike resolves nothing.
        vm.warp(finishesAt + 1);
        vm.prank(stranger);
        credit.liquidate(alice);
        assertEq(credit.bountyOwedTo(stranger), 0, "a re-strike paid the caller");

        vm.revertToState(snap);

        vm.warp(finishesAt + 1);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertEq(
            credit.bountyOwedTo(stranger),
            Config.LIQUIDATION_CALL_BOUNTY,
            "expiring to a workout did not pay the bounty"
        );
    }

    /// @notice At `navPerBond() == 0` the exit of last resort is the ONLY exit, and it works.
    /// @dev The guard on the candidate refused when round 20's finding 2 was reopened: gating
    ///      `expireToWorkout` on `Config.AUCTION_RESET_WINDOW`, so the sale process has to exhaust
    ///      before a workout may open. Built, and this is the falsifier it fired. With the oracle
    ///      reporting zero, a re-strike reverts `NavUnset` and `cancel` reverts `StillLiquidatable`
    ///      - a position with no collateral value is liquidatable at every threshold - so the gate
    ///      would shut all three exits for forty-two hours on precisely the input the exit of last
    ///      resort exists for.
    ///
    ///      Kept as an assertion rather than as a note, because the property is what makes the
    ///      exit total and nothing else in the suite states it: `expireToWorkout` reads the oracle
    ///      through `_vault.collateralValue` and must not begin to *depend* on it.
    function test_atNavZeroTheWorkoutExitIsTheOnlyOneLeftAndItWorks() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        vm.warp(finishesAt + 1);
        oracle.setNav(0);
        uint256 snap = vm.snapshotState();

        vm.prank(stranger);
        vm.expectRevert(LiquidationAuction.NavUnset.selector);
        credit.liquidate(alice);

        // Partial, because `StillLiquidatable` carries an LTV in bps and a position with zero
        // collateral value has no finite one. The selector is the assertion.
        vm.expectPartialRevert(LiquidationAuction.StillLiquidatable.selector);
        auction.cancel(id);

        vm.revertToState(snap);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertGt(auction.workoutsOpenFor(alice), 0, "the exit of last resort failed at nav zero");
    }

    /// @notice A DexFi tranche arriving inside their own quoted turnaround lands on an open
    ///         workout and realises no loss at all.
    /// @dev The guard on the other candidate refused at the same time: shortening
    ///      `Config.WORKOUT_MAX_DURATION`. Built at two days, and this is the falsifier it fired -
    ///      the forced close became reachable at forty-eight hours, socialised the whole debt, and
    ///      the seventy-two hour tranche was then refused by `workoutSettle` and had to be relayed
    ///      back through `workoutSettleAfterClose` by another volunteer.
    ///
    ///      `Config.WORKOUT_MAX_DURATION` is pinned to an off-chain process quoted at "48h+", and
    ///      this is the assertion that says so in executable form. It is deliberately written
    ///      against 72 hours rather than against the constant: a test that scales with the
    ///      parameter cannot notice the parameter moving under the process.
    function test_aSeventyTwoHourTrancheLandsOnAnOpenWorkoutAndRealisesNoLoss() public {
        (uint256 id, uint256 finishesAt) = _stageTheParkedMark();
        vm.warp(finishesAt);
        vm.prank(stranger);
        auction.expireToWorkout(id);

        vm.warp(finishesAt + 72 hours);
        // The window is still open at DexFi's own quoted turnaround. This is the assertion a
        // shortened `Config.WORKOUT_MAX_DURATION` goes red on.
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationAuction.WorkoutStillRunning.selector, finishesAt + Config.WORKOUT_MAX_DURATION
            )
        );
        auction.closeWorkout(id);

        uint256 owedBefore = credit.currentDebtOf(alice);
        usdc.mint(address(this), 400e6);
        usdc.approve(address(auction), type(uint256).max);
        auction.workoutSettle(id, 400e6);

        assertLt(credit.currentDebtOf(alice), owedBefore, "the tranche did not pay down the debt");
        assertEq(pool.lifetimeSocialisedLoss(), 0, "a loss was realised before the redemption landed");
    }
}
