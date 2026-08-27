// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {ContractBidder, RejectingBidder, ReentrantBidder} from "./mocks/Bidders.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockLenderPool} from "./mocks/MockLenderPool.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Dutch auction lifecycle against the real-ABI mocks (PRD §4.5, §6.3).
///
///         Fixture uses the real 2026-07-24 NAV snapshot, so 100 bonds is $2,515 of
///         collateral. Positions are put underwater by crashing NAV rather than by
///         writing debt directly, which is the only way it can actually happen on chain.
///
///         `_maxBorrowAtCeiling()` is derived from the live risk parameters rather than written
///         down. It used to be the literal 880.25e6, which was 35% of $2,515 - correct until the capped-beta
///         parameters landed on 2026-08-07, at which point 53 of the 61 tests in this
///         file failed at the fixture rather than in the code under test. The ratchet
///         agreed with DexFi moves the LTV ceiling at least twice more, so the same break
///         is scheduled to happen again unless the fixture reads the parameter.
///
///         It reads it through `RiskParamsFixture`, and it is a **function** rather than a
///         constant because the four negotiated parameters now live in `RiskParams` storage and a
///         Solidity `constant` cannot read a storage slot. Nothing here is cached in a variable set
///         in `setUp` either: a test that moves a parameter partway through has to see the new
///         derived figure, and a cache would keep passing against the stale one.
contract LiquidationAuctionTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 100_000e6;

    // ── the derived scenario figures ─────────────────────────────────────────
    //
    // Six `internal constant`s until the risk parameters became storage. Same derivations, same
    // relationships between them; see the contract docstring for why they are `view` functions.

    /// @dev Borrowing power at the ceiling: BONDS x NAV x maxLTV, in USDC 6dp.
    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    /// @dev The NAV at which a position borrowed to the ceiling sits exactly on the
    ///      liquidation threshold. Everything below is liquidatable, everything above is
    ///      not, so the two scenario NAVs are chosen either side of it by construction.
    function _thresholdNav() internal view returns (uint256) {
        return _navAtThreshold(_maxBorrowAtCeiling(), BONDS);
    }

    /// @dev The NAV at which the whole lot is worth exactly the debt, so a fill at 100%
    ///      of NAV covers the loan and not a cent more.
    function _debtParityNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS);
    }

    /// @dev Liquidatable but still solvent: past the threshold, yet worth more than the
    ///      debt, so a mid-auction fill leaves the borrower a surplus. Sits midway
    ///      between the two bounds above so it can never drift to the wrong side of
    ///      either when the parameters move.
    function _softNav() internal view returns (uint256) {
        return (_thresholdNav() + _debtParityNav()) / 2;
    }

    /// @dev The other side: even a fill at 100% of NAV cannot cover the loan, so the
    ///      insurance fund and then the lenders take the difference. Half of debt parity
    ///      is comfortably clear of the boundary rather than a cent under it.
    function _crashedNav() internal view returns (uint256) {
        return _debtParityNav() / 2;
    }

    /// @dev The NAV at which the auction's *floor* price lands half a penalty above the
    ///      debt, i.e. inside the band where a fill leaves some surplus but less than a
    ///      full penalty. Solved from the floor rather than picked, because it depends on
    ///      three parameters at once - the LTV ceiling, the auction floor and the penalty
    ///      - and a hand-picked NAV silently leaves the band when any of them moves.
    function _navForPartialPenalty() internal view returns (uint256) {
        uint256 debt = _maxBorrowAtCeiling();
        return (
            (debt + (debt * Config.LIQUIDATION_PENALTY_BPS) / (2 * Config.BPS)) * Config.BPS
                * Config.USDC_TO_NAV_SCALE
        ) / (BONDS * Config.AUCTION_FLOOR_BPS);
    }

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper"); // calls liquidate
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

    /// @dev Borrow at the ceiling, then crash NAV until the position is genuinely past
    ///      the liquidation threshold. `_crashedNav()` is half of debt parity, so the lot
    ///      is worth half the loan and the LTV is well over 10,000 bps.
    function _openAuction() internal returns (uint256 id) {
        return _openAuctionAt(_crashedNav());
    }

    /// @dev `_softNav()` is the interesting case: past the liquidation threshold, but the
    ///      lot is still worth more than the debt, so a mid-auction fill leaves a
    ///      surplus. `_crashedNav()` is the other side - even a 100%-of-NAV fill cannot
    ///      cover the loan. Both are derived either side of `_debtParityNav()`, so
    ///      neither can end up on the wrong side of its own premise.
    function _openAuctionAt(uint256 nav) internal returns (uint256 id) {
        // **Read before the prank, never from inside the argument list.** The derivation is an
        // external view call now that the risk parameters are storage, and `vm.prank` applies to
        // the *next* call including a static one - so leaving it in argument position would spend
        // the prank on the parameter read and run `borrow` as this contract.
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(nav);
        vm.prank(keeper);
        credit.liquidate(alice);
        return auction.auctionOf(alice);
    }

    function _fundBidder(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), type(uint256).max);
    }

    /// @dev The elapsed time at which the decay curve reads exactly `premiumBps`.
    ///      Derived from the curve rather than hard-coded, so retuning the floor or the
    ///      duration moves the test instead of silently making it assert nothing.
    function _elapsedForPremium(uint256 premiumBps) internal pure returns (uint256) {
        return ((Config.AUCTION_START_PREMIUM_BPS - premiumBps) * Config.AUCTION_DURATION)
            / (Config.AUCTION_START_PREMIUM_BPS - Config.AUCTION_FLOOR_BPS);
    }

    function _lotPrice(uint256 bonds, uint256 nav, uint256 premiumBps) internal pure returns (uint256) {
        uint256 numerator = bonds * nav * premiumBps;
        uint256 denominator = Config.BPS * Config.USDC_TO_NAV_SCALE;
        return (numerator + denominator - 1) / denominator;
    }

    // ── start ────────────────────────────────────────────────────────────────

    function test_start_recordsTheLotAndPricesItAtNav() public {
        uint256 id = _openAuction();

        assertEq(id, 1, "ids start at 1 so that zero can mean none");
        (
            address borrower,
            uint96 startedAt,
            address caller,
            bool settled,
            uint256 bondCount,
            uint256 startNav,
            uint256 startPrice,
            uint256 debt
        ) = auction.auctions(id);

        assertEq(borrower, alice);
        assertEq(caller, keeper, "the trigger earns the reward, not the bidder");
        assertEq(startedAt, uint96(block.timestamp));
        assertFalse(settled);
        assertEq(bondCount, BONDS);
        assertEq(startNav, _crashedNav());
        assertEq(debt, _maxBorrowAtCeiling());
        assertEq(startPrice, _lotPrice(BONDS, _crashedNav(), Config.AUCTION_START_PREMIUM_BPS));
        assertEq(startPrice, 314.375e6, "100 bonds at the crashed NAV, at 100% of NAV");
        assertTrue(auction.isLiquidating(alice));
    }

    /// @notice The lot stays staked and earning. Nothing is escrowed, so nothing DexFi
    ///         does to the transfer whitelist can stop an auction opening.
    function test_start_movesNoBondsAtAll() public {
        uint256 stakedBefore = farm.staked(address(adapter));
        bond.setWhitelisted(address(adapter), false); // DexFi revokes mid-flight

        _openAuction();

        assertEq(farm.staked(address(adapter)), stakedBefore, "the lot never left the farm");
        assertEq(vault.bondCount(alice), BONDS, "and it is still hers until someone bids");
        assertEq(bond.bondBalance(address(auction)), 0, "the auction escrows nothing");
    }

    function test_start_onlyCreditManager() public {
        vm.expectRevert(LiquidationAuction.NotCreditManager.selector);
        auction.start(alice, keeper);
    }

    function test_start_refusesASecondLiveAuction() public {
        uint256 id = _openAuction();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionAlreadyLive.selector, id));
        credit.liquidate(alice);
    }

    /// @dev A position with debt and no collateral always passes the health gate, so
    ///      without this the protocol would open auctions over empty lots and a bidder
    ///      could pay the full price for nothing.
    function test_start_refusesAnEmptyLot() public {
        uint256 debt = _maxBorrowAtCeiling(); // read before the prank - see `_openAuctionAt`
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(_crashedNav());

        // Seize the lot out from under the position, leaving debt against no bonds.
        vm.prank(address(auction));
        vault.seize(alice, bidder);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NothingToAuction.selector, alice));
        credit.liquidate(alice);
    }

    // ── pricing ──────────────────────────────────────────────────────────────

    function test_currentPrice_startsAtTheStartPremium() public {
        uint256 id = _openAuction();
        assertEq(auction.currentPremiumBps(id), Config.AUCTION_START_PREMIUM_BPS);
        assertEq(auction.currentPrice(id), 314.375e6);
    }

    function test_currentPrice_decaysLinearlyAtHalfDuration() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION / 2);

        uint256 expected = Config.AUCTION_START_PREMIUM_BPS
            - (Config.AUCTION_START_PREMIUM_BPS - Config.AUCTION_FLOOR_BPS) / 2;
        assertEq(auction.currentPremiumBps(id), expected);
        assertEq(auction.currentPrice(id), _lotPrice(BONDS, _crashedNav(), expected));
    }

    function test_currentPrice_reachesTheFloorExactlyAtDurationAndStaysThere() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        assertEq(auction.currentPremiumBps(id), Config.AUCTION_FLOOR_BPS);
        assertEq(auction.currentPrice(id), 213.775e6, "68% of $314.375");

        // The floor holds at the boundary, which is the last instant a bid can land.
        // Past it, both quoting views refuse rather than keep returning a number no
        // `bid` will honour - round 6b guarded `currentPrice` and left this one
        // answering, and premium x lot x startNav rebuilds the same figure.
        skip(30 days);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, id));
        auction.currentPremiumBps(id);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, id));
        auction.currentPrice(id);

        // `endsAt` deliberately still answers: it is how a keeper tells a lapsed
        // auction from an unknown one, and the value cannot be mistaken for a price.
        assertGt(auction.endsAt(id), 0, "endsAt stays readable");
    }

    /// @notice **The Dutch curve only falls, and the curve is the PREMIUM.** The whole-lot price
    ///         has no monotonicity property at all, because the lot is the borrower's to grow.
    /// @dev **Audit round 23, finding 18. The old assertion here was the finding.** This used to be
    ///      `testFuzz_currentPriceIsMonotonicallyNonIncreasing`: two steps each bounded to
    ///      `Config.AUCTION_DURATION / 2` under the comment "past it the auction lapses", asserting
    ///      `assertLe(currentPrice(id), earlier, "a Dutch price must only ever fall")`. Two separate
    ///      things were wrong with it and only one of them was the bound.
    ///
    ///      **The bound's stated reason had already expired.** The lapse is at a whole
    ///      `AUCTION_DURATION`; `currentPrice` refuses only *past* `startedAt + AUCTION_DURATION`
    ///      and quotes right up to it. Half a duration was never the interval the comment named,
    ///      so the test covered half the window it could have and read as covering all of it.
    ///
    ///      **And the assertion is false on the half it did cover.** `currentPrice` prices the
    ///      *live* lot - `_lotPrice(_vault.bondCount(a.borrower), a.startNav, _premiumBps(...))` -
    ///      and `depositBonds` is the borrower's own unilateral call, available at every instant of
    ///      the window. MEASURED at `_softNav()`, no lapse and no re-strike, time only moving
    ///      forward: `AUCTION_DURATION / 4` quotes **867.675000** at 9,200 bps, and
    ///      `AUCTION_DURATION / 2` after a +20-bond deposit quotes **950.670000** at 8,400 bps. The
    ///      curve fell 800 bps while the quote rose 82.995000. Pinned by the deterministic test
    ///      below, so the counterexample survives as a number rather than as a comment.
    ///
    ///      **What is true, and what this asserts instead:**
    ///
    ///        1. `currentPremiumBps` is non-increasing for as long as `a.startedAt` is unchanged.
    ///           That is the whole Dutch curve - `_premiumBps` is a pure function of
    ///           `block.timestamp - startedAt` and of nothing else.
    ///        2. The quote is exactly `_lotPrice(live lot, frozen startNav, that premium)`. Every
    ///           move in the quote is therefore attributable to one of three named inputs, two of
    ///           which cannot rise. That is the strongest form: it fails if the curve inverts, if
    ///           the recorded lot is quoted instead of the live one, or if a NAV repost reaches the
    ///           price - so the repost is fuzzed here rather than only pinned one case at a time.
    ///        3. With the lot held still the old assertion does hold, so it is kept, guarded by the
    ///           condition that makes it true rather than by a bound that hid the case.
    ///
    ///      Consistent with round 23's finding 13 by construction. This says nothing about what a
    ///      bidder pays, only about what the two quoting views return, so it does not depend on
    ///      there being a setting of the two-bound door that is both re-strike-safe and
    ///      top-up-proof. There is none.
    function testFuzz_theCurveOnlyFallsWhileTheStrikeIsUnchanged(
        uint32 firstStep,
        uint32 secondStep,
        uint16 topUp,
        uint64 navStep
    ) public {
        uint256 openedAt = block.timestamp;
        uint256 id = _openAuctionAt(_softNav());
        (,,,,, uint256 startNav,,) = auction.auctions(id);

        // Anywhere on the curve, which is defined on the whole closed window rather than on half
        // of it.
        uint256 firstAt = openedAt + bound(firstStep, 0, Config.AUCTION_DURATION);
        vm.warp(firstAt);
        uint256 premiumEarlier = auction.currentPremiumBps(id);
        uint256 earlier = auction.currentPrice(id);
        uint256 bondsEarlier = vault.bondCount(alice);
        assertEq(earlier, _lotPrice(bondsEarlier, startNav, premiumEarlier), "the quote is lot x startNav x curve");

        // The two inputs the old test never varied. Alice holds 1,000 bonds and 100 are already
        // posted, so a top-up is a real deposit rather than a fixture that quietly does nothing.
        uint256 added = bound(topUp, 0, 900);
        if (added != 0) {
            vm.prank(alice);
            vault.depositBonds(added);
        }
        oracle.setNav(bound(navStep, 1, NAV * 4));

        vm.warp(firstAt + bound(secondStep, 0, openedAt + Config.AUCTION_DURATION - firstAt));
        uint256 premiumLater = auction.currentPremiumBps(id);
        uint256 later = auction.currentPrice(id);
        uint256 bondsLater = vault.bondCount(alice);

        assertLe(premiumLater, premiumEarlier, "the Dutch curve must only ever fall");
        assertEq(later, _lotPrice(bondsLater, startNav, premiumLater), "and the quote must stay attributable");
        assertLe(later, _lotPrice(bondsLater, startNav, premiumEarlier), "no part of a rise may come from the curve");
        if (bondsLater == bondsEarlier) {
            assertLe(later, earlier, "with the lot held still, the whole-lot price only falls too");
        }
    }

    /// @notice Round 23's finding 18, pinned as the exact numbers it was measured as.
    /// @dev The rise is designed behaviour, not a defect: `currentPrice` quotes the live lot so
    ///      that a top-up is not sold for nothing, which
    ///      `test_currentPrice_pricesTheLiveLotSoATopUpIsNotSoldForNothing` states directly. What
    ///      was defective was the suite claiming the opposite one screen away. Both live here now,
    ///      so a future reader cannot resolve the tension by deleting whichever they met first.
    function test_currentPrice_risesInsideOneWindowWhenTheBorrowerGrowsTheLot() public {
        uint256 id = _openAuctionAt(_softNav());

        skip(Config.AUCTION_DURATION / 4);
        assertEq(auction.currentPremiumBps(id), 9_200);
        assertEq(auction.currentPrice(id), 867.675e6);

        vm.prank(alice);
        vault.depositBonds(20);
        skip(Config.AUCTION_DURATION / 4);

        assertEq(auction.currentPremiumBps(id), 8_400, "the curve fell 800 bps");
        assertEq(auction.currentPrice(id), 950.670e6, "and the quote rose 82.995000 anyway, with no lapse");
    }

    /// @notice **A re-strike rebases the curve; it does not continue it.** A given id can quote a
    ///         higher number after a lapse than before one, and every term of the new quote is
    ///         re-read rather than carried over.
    /// @dev **Audit round 22, finding 16, test half, rewritten rather than landed.** The widened
    ///      fuzz test held on `fix/the-price-test-off-its-interval` reached exactly this state and
    ///      then asserted `assertLe(currentPrice(id), earlier)` over it. MEASURED against this
    ///      tree, first case: **314375000 > 309722250**. The two-bound door added in round 22
    ///      bounds a bidder's exposure; it does not restore price monotonicity across a re-strike,
    ///      and nothing in the design does. The reach that commit opened is worth keeping and its
    ///      assertion is not, so the reach is kept here and the assertion is replaced.
    ///
    ///      The lapse instant is an absolute `vm.warp` rather than a second relative `skip`, and
    ///      that is load-bearing: two relative skips of up to a duration each can still land
    ///      *inside* the window, where `liquidate` reverts `AuctionAlreadyLive` and the test goes
    ///      red for a reason that has nothing to do with pricing.
    ///
    ///      NAV is moved before the re-strike because the re-strike re-reads it: `start` rewrites
    ///      `startedAt`, `bondCount`, `startNav` and `startPrice` in place on the same id. Moving it
    ///      is what makes `startNav == freshNav` discriminate a re-strike that carried the old
    ///      snapshot forward. It moves downward only, because the position has to stay liquidatable
    ///      for `liquidate` to be legal at all. The direction of the price change with NAV held
    ///      still is the deterministic test below.
    function testFuzz_aReStrikeRebasesTheCurveRatherThanContinuingIt(
        uint32 firstStep,
        uint32 lapseStep,
        uint64 navStep
    ) public {
        uint256 openedAt = block.timestamp;
        uint256 id = _openAuctionAt(_softNav());

        vm.warp(openedAt + bound(firstStep, 0, Config.AUCTION_DURATION));
        uint256 premiumBefore = auction.currentPremiumBps(id);

        // Strictly past the lapse and strictly inside the reset window: the only interval in which
        // a re-strike is legal at all.
        vm.warp(
            openedAt + Config.AUCTION_DURATION
                + bound(lapseStep, 1, Config.AUCTION_RESET_WINDOW - Config.AUCTION_DURATION)
        );
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, id));
        auction.currentPrice(id);

        uint256 freshNav = bound(navStep, _crashedNav(), _softNav());
        oracle.setNav(freshNav);
        vm.prank(keeper);
        credit.liquidate(alice);

        (, uint96 startedAt,,,, uint256 startNav,,) = auction.auctions(id);
        assertEq(auction.auctionOf(alice), id, "a re-strike must not mint a new id");
        assertEq(auction.firstOpenedAt(id), openedAt, "and it must not move its own deadline");
        assertEq(startedAt, uint96(block.timestamp), "the strike is new, so the clock restarts here");
        assertEq(startNav, freshNav, "priced off current NAV, never off the snapshot it replaces");
        assertEq(
            auction.currentPremiumBps(id),
            Config.AUCTION_START_PREMIUM_BPS,
            "rebased to the top of the curve rather than continuing down it"
        );
        assertGe(
            auction.currentPremiumBps(id),
            premiumBefore,
            "and this is the deleted assertion, the right way round and in the quantity that has the property"
        );
        assertEq(
            auction.currentPrice(id),
            _lotPrice(vault.bondCount(alice), freshNav, Config.AUCTION_START_PREMIUM_BPS),
            "and the quote is attributable to the new strike, term for term"
        );
    }

    /// @notice The rise across a re-strike, pinned, with NAV held still so nothing else can explain
    ///         it. This is the case the held fuzz test asserted backwards.
    /// @dev MEASURED: the id sits at its floor on **213.775000** and the re-strike one second later
    ///      quotes **314.375000**, a 47.06% rise with no NAV movement behind it.
    ///      `test_R22_thePinnedBidStillPaysTheRestruckPrice` measures what that costs a bidder at
    ///      `_softNav()`; this one is about the quoting views alone.
    function test_currentPrice_rebasesUpwardAcrossAReStrikeWithNavHeldStill() public {
        uint256 openedAt = block.timestamp;
        uint256 id = _openAuction();

        skip(Config.AUCTION_DURATION);
        uint256 atTheFloor = auction.currentPrice(id);
        assertEq(atTheFloor, 213.775e6, "the last quotable instant, at the floor");

        vm.warp(openedAt + Config.AUCTION_DURATION + 1);
        vm.prank(keeper);
        credit.liquidate(alice);

        assertEq(auction.auctionOf(alice), id, "the same id, re-struck in place");
        assertEq(auction.currentPremiumBps(id), Config.AUCTION_START_PREMIUM_BPS);
        assertEq(auction.currentPrice(id), 314.375e6, "back to 100% of an unchanged NAV");
        assertGt(auction.currentPrice(id), atTheFloor, "a re-strike rebases upward; it does not decay");
    }

    /// @notice The snapshot, made executable. A NAV repost must not move a live
    ///         auction's price in *either* direction - upward it breaks the only
    ///         strategy the format offers, downward it breaks the floor's coverage
    ///         guarantee, which is sized against exactly one max-deviation drop.
    ///
    ///         Both directions in one test on purpose: pinning only one leaves the
    ///         other free to regress.
    function test_currentPrice_ignoresANavRepostInEitherDirection() public {
        uint256 id = _openAuction();
        uint256 priced = auction.currentPrice(id);

        oracle.setNav(_crashedNav() * 3);
        assertEq(auction.currentPrice(id), priced, "a recovery must not reprice a live auction upward");

        oracle.setNav(_crashedNav() / 4);
        assertEq(auction.currentPrice(id), priced, "and a further crash must not reprice it downward");
    }

    /// @dev Staleness pauses borrowing, never liquidation (PRD §4.6). The auction is
    ///      independent of the feed once open, so this is free - but it must be pinned,
    ///      because "gate the auction on staleness" is a plausible-looking change.
    function test_currentPrice_worksWithAStaleFeed() public {
        uint256 id = _openAuction();
        oracle.setStale(true);
        assertEq(auction.currentPrice(id), 314.375e6);
    }

    function test_currentPrice_pricesTheLiveLotSoATopUpIsNotSoldForNothing() public {
        uint256 id = _openAuction();
        vm.prank(alice);
        vault.depositBonds(50);
        assertEq(auction.currentPrice(id), 471.5625e6, "150 bonds at the crashed NAV");
    }

    function test_currentPrice_revertsForUnknownAndClosedAuctions() public {
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.UnknownAuction.selector, uint256(0)));
        auction.currentPrice(0);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.UnknownAuction.selector, uint256(7)));
        auction.currentPrice(7);

        uint256 id = _openAuction();
        oracle.setNav(NAV); // heals the position
        auction.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionClosed.selector, id));
        auction.currentPrice(id);
    }

    // ── cancel ───────────────────────────────────────────────────────────────

    function test_cancel_onceNavRecovers() public {
        uint256 id = _openAuction();
        oracle.setNav(NAV);

        auction.cancel(id); // permissionless
        assertFalse(auction.isLiquidating(alice));
        assertEq(vault.bondCount(alice), BONDS, "nothing was ever taken, so nothing comes back");
    }

    function test_cancel_afterAThirdPartyRepays() public {
        uint256 id = _openAuction();

        address friend = makeAddr("friend");
        usdc.mint(friend, _maxBorrowAtCeiling());
        vm.startPrank(friend);
        usdc.approve(address(credit), _maxBorrowAtCeiling());
        credit.repayFor(alice, _maxBorrowAtCeiling());
        vm.stopPrank();

        auction.cancel(id);
        assertFalse(auction.isLiquidating(alice));
    }

    /// @notice A workout cannot be opened over a position that has nothing left in it.
    /// @dev **Audit round 12, executed PoC.** `CollateralVault.reassign` returns 0 rather than
    ///      reverting on an empty position, and that early return also skips its own liquidatable
    ///      check - so both halves of the guard `start` carries were missing here. Anyone could
    ///      clear the debt with the permissionless `repayFor`, let the borrower take their bonds
    ///      out (`withdrawBonds` skips its LTV branch entirely at zero debt, even under a live
    ///      auction), and then push the position through this exit rather than `cancel`.
    ///
    ///      The damage is that `workoutsOpenFor` blocks that borrower from ever borrowing again and
    ///      `openWorkoutCount` blocks four separate wiring setters, until some third party pays gas
    ///      to close a workout over nothing. `cancel` is the correct exit and remains available.
    ///
    ///      **Audit round 20 moved this test from the door to the damage, and the move is the
    ///      point.** Round 12 refused the wrong door with `NothingToAuction`. That was correct
    ///      about the harm and, it turned out, wrong about the remedy: refusing left the caller
    ///      holding a lapsed auction with only one legal move left, and nothing on chain naming
    ///      it. `expireToWorkout` now dispatches a healed position - and an empty position is a
    ///      healed one, since `exceedsLtv` reads zero debt as healthy - into the `cancel` body
    ///      instead. **Every consequence round 12 enumerated is still asserted below**, because
    ///      the dispatch happens before `reassign` and before the workout is registered: no
    ///      workout is opened, `workoutsOpenFor` stays at zero, the four setters stay free, and
    ///      the caller earns nothing. What changed is that the wrong door is now the right one.
    ///
    ///      `NothingToAuction` is not dead: it still guards a *liquidatable* position with an
    ///      empty lot, which is the hole `hasReachableExit` in the invariant suite names and
    ///      argues is unreachable because `withdrawBonds` refuses to empty a position carrying
    ///      debt. It is no longer reachable from *this* fixture, which is the change.
    function test_expireToWorkout_refusesAPositionWithNoCollateral() public {
        uint256 id = _openAuction();

        address friend = makeAddr("friend");
        usdc.mint(friend, _maxBorrowAtCeiling());
        vm.startPrank(friend);
        usdc.approve(address(credit), _maxBorrowAtCeiling());
        credit.repayFor(alice, _maxBorrowAtCeiling());
        vm.stopPrank();

        vm.prank(alice);
        vault.withdrawBonds(BONDS);
        assertEq(vault.bondCount(alice), 0, "the fixture must leave the position empty");

        skip(Config.AUCTION_DURATION + 1);
        address volunteer = makeAddr("volunteer");
        uint256 volunteerBefore = usdc.balanceOf(volunteer);
        vm.prank(volunteer);
        auction.expireToWorkout(id);

        // The round-12 damage, restated as the damage rather than as the door.
        assertEq(auction.openWorkoutCount(), 0, "a workout was opened over nothing");
        assertEq(auction.workoutsOpenFor(alice), 0, "and the borrower must not be blocked by one");

        // And the auction really is resolved, on the one exit that is legal here.
        assertEq(auction.auctionOf(alice), 0, "the auction must not still be registered");
        assertEq(auction.liveAuctionCount(), 0, "nor still be counted live");
        assertFalse(auction.isLiquidating(alice));

        // Nobody was paid for it. Audit round 18: a cancel resolves nothing, so it earns nothing.
        assertEq(usdc.balanceOf(volunteer), volunteerBefore, "a cancel must never pay its caller");
        assertEq(auction.rewardOf(volunteer), 0, "nor accrue them a claim");
    }

    /// @notice Once the auction's clock has run out, `expireToWorkout` always resolves it - on
    ///         either side of the liquidatable predicate, and past the re-strike deadline.
    /// @dev **Audit round 20, and this is the property the round-19 bound was assumed to have.**
    ///      `Config.AUCTION_RESET_WINDOW` bounds the re-strike, not the mark. Past it `start`
    ///      refuses with `AuctionResetWindowClosed`, so `expireToWorkout` is the only legal move
    ///      left - and it used to revert on exactly the positions that had healed, through
    ///      `reassign`'s `_requireLiquidatable`. `cancel` was the remedy, and `CreditManager.borrow`
    ///      has said since round 13 that it "is unrewarded and optional, so nothing makes it
    ///      happen": the mark, the borrowing block, the four welded setters and the locked
    ///      collateral all stood until a volunteer turned up, with no clock on any of them.
    ///
    ///      `hasReachableExit` in `LiquidationAuction.invariants.t.sol` restates the spec as
    ///      "expireToWorkout: needs only that the clock has run out". That line was the spec and
    ///      not the code, which is why the invariant stayed green over the defect. It is the code
    ///      now, and this is the test that says so directly rather than through a fuzz campaign.
    ///
    ///      Both branches are asserted in one test on purpose: the value is the *totality*, and a
    ///      test that only exercised the healed side would pass over an implementation that had
    ///      simply stopped opening workouts.
    function test_expireToWorkout_isTotalOnceTheClockHasRunOut() public {
        // ── the healed branch: resolves as a cancel, opens no workout, pays nobody ──
        uint256 healedId = _openAuctionAt(_softNav());
        vm.warp(auction.firstOpenedAt(healedId) + Config.AUCTION_RESET_WINDOW + 1);

        // The re-strike really is closed, so this is the state with one legal move in it.
        vm.prank(keeper);
        vm.expectRevert();
        credit.liquidate(alice);

        // Permissionless and capital-free: the yield stream reaches the same place.
        address friend = makeAddr("friend");
        // Three quarters, so the heal clears the *borrow* ceiling too and the re-arm below is
        // a real observation rather than a second refusal wearing a different error.
        uint256 cure = (credit.currentDebtOf(alice) * 3) / 4;
        usdc.mint(friend, cure);
        vm.startPrank(friend);
        usdc.approve(address(credit), cure);
        credit.repayFor(alice, cure);
        vm.stopPrank();
        assertGt(credit.currentDebtOf(alice), 0, "premise: the heal must leave a live loan");
        assertGt(credit.healthFactor(alice), Config.HEALTH_FACTOR_SCALE, "premise: and the position must be healthy");

        address volunteer = makeAddr("volunteer");
        uint256 volunteerBefore = usdc.balanceOf(volunteer);
        vm.prank(volunteer);
        auction.expireToWorkout(healedId);

        assertEq(auction.auctionOf(alice), 0, "the healed branch must clear the auction pointer");
        assertEq(auction.liveAuctionCount(), 0, "and the live register with it");
        assertEq(auction.openWorkoutCount(), 0, "a healed position must not open a workout");
        assertEq(auction.workoutsOpenFor(alice), 0, "nor be marked as having one");
        assertEq(usdc.balanceOf(volunteer), volunteerBefore, "round 18: a cancel pays its caller nothing");
        assertEq(auction.rewardOf(volunteer), 0, "nor accrues them a claim");

        // The borrower is armed again rather than permanently barred.
        vm.prank(alice);
        credit.borrow(1);

        // ── the still-forfeit branch: unchanged, and still earns the caller the escrow ──
        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 forfeitId = auction.auctionOf(alice);
        skip(Config.AUCTION_DURATION + 1);

        address keeper2 = makeAddr("keeper2");
        vm.prank(keeper2);
        auction.expireToWorkout(forfeitId);

        assertEq(auction.openWorkoutCount(), 1, "a forfeit position must still open a workout");
        assertEq(auction.workoutsOpenFor(alice), 1, "and still block the borrower through it");
        assertEq(auction.auctionOf(alice), 0, "the auction pointer clears on this branch too");
    }

    function test_cancel_revertsWhileStillLiquidatable() public {
        uint256 id = _openAuction();
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.StillLiquidatable.selector, uint256(20_000)));
        auction.cancel(id);
    }

    /// @notice The guard and every clearer it depends on, composed. A one-auction rule
    ///         whose clearers are asserted separately passes forever even if no clearer
    ///         actually works, leaving the borrower permanently un-reliquidatable.
    function test_reliquidationBecomesPossibleAgainAfterACancel() public {
        uint256 first = _openAuction();
        oracle.setNav(NAV);
        auction.cancel(first);

        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        credit.liquidate(alice);

        uint256 second = auction.auctionOf(alice);
        assertEq(second, first + 1, "a fresh auction, not the old one");
        assertTrue(auction.isLiquidating(alice));
    }

    // ── bid: the money flow ──────────────────────────────────────────────────

    /// @notice PRD §6.3, literally: a keeper buys at 82% of NAV, the debt is repaid,
    ///         the surplus goes to the borrower and the bonds go to the winner.
    function test_bid_repaysDebtSurplusToBorrowerBondsToWinner() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(_elapsedForPremium(8_200));
        assertEq(auction.currentPremiumBps(id), 8_200);

        uint256 price = auction.currentPrice(id);
        assertEq(price, 773.3625e6, "100 bonds at the soft NAV, 82% of NAV");

        _fundBidder(bidder, price);
        uint256 floatBefore = usdc.balanceOf(address(liquidity));

        vm.prank(bidder);
        auction.bid(id);

        // The lot really moved, and it left the farm on the way.
        assertEq(bond.bondBalance(bidder), BONDS, "winner holds the bonds");
        assertEq(vault.bondCount(alice), 0);
        assertEq(farm.staked(address(adapter)), 0, "and they were unstaked to get there");

        // Debt cleared, principal owed home, nothing socialised.
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebt(), 0);
        assertEq(credit.unsocialisedLoss(), 0);
        assertEq(credit.pendingPrincipal(), _maxBorrowAtCeiling());

        // Penalty is 500 bps of the debt, split down the middle.
        uint256 penalty = (_maxBorrowAtCeiling() * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(penalty, 31.4375e6);
        assertEq(auction.rewardOf(keeper), penalty / 2, "the trigger, not the bidder");
        assertEq(credit.insuranceFund(), penalty - penalty / 2);

        // And the borrower keeps what is left, claimable rather than pushed.
        assertEq(credit.claimableOf(alice), price - _maxBorrowAtCeiling() - penalty);
        assertEq(credit.claimableOf(alice), 113.175e6);

        // Every wei accounted for, and the auction keeps only the unclaimed reward.
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());
        assertEq(auction.totalUnclaimedRewards(), penalty / 2);

        // Principal finds its way home through the existing permissionless path.
        credit.settlePrincipal();
        assertEq(usdc.balanceOf(address(liquidity)), floatBefore + _maxBorrowAtCeiling());

        vm.prank(alice);
        credit.claimSurplus();
        // The loan she actually received was the borrow less the prepaid bounty, and the
        // bounty is not coming back - it went to the keeper who opened the auction.
        assertEq(
            usdc.balanceOf(alice),
            _maxBorrowAtCeiling() - Config.LIQUIDATION_CALL_BOUNTY + 113.175e6,
            "the loan plus the surplus"
        );

        vm.prank(keeper);
        auction.claimReward();
        assertEq(usdc.balanceOf(keeper), penalty / 2);
        assertEq(usdc.balanceOf(address(auction)), 0, "nothing left at rest");

        // **On a full fill the caller is paid twice, and that is intended.** The penalty share
        // above prices the position having been penalised, which only exists because the lot
        // sold for more than the debt. The prepaid bounty prices the act of opening the
        // auction at all, which is what makes the pool's mark exist and is worth the same
        // whether the sale clears the debt or misses it by half. Both are charged to the
        // borrower and neither touches a lender. Liquity pays its gas compensation on top of
        // the liquidation gain for the same reason, and Maker pays `tip + chip x tab`
        // regardless of how the auction ends.
        vm.prank(keeper);
        credit.claimBounty();
        assertEq(
            usdc.balanceOf(keeper),
            penalty / 2 + Config.LIQUIDATION_CALL_BOUNTY,
            "the penalty share and the prepaid bounty both"
        );
    }

    /// @notice A fill below the debt must still fill. A position nobody can buy is
    ///         strictly worse for lenders than one bought at a loss.
    function test_bid_atTheFloorWithAShortfallStillFillsAndDrawsInsuranceFirst() public {
        uint256 id = _openAuction(); // $10.00 a bond: even 100% of NAV misses the debt
        usdc.mint(address(this), 100e6);
        usdc.approve(address(credit), 100e6);
        credit.fundInsurance(100e6);

        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id);
        assertEq(price, 213.775e6, "68% of $314.375");
        assertLt(price, _maxBorrowAtCeiling(), "the whole point: the lot is worth less than the loan");

        _fundBidder(bidder, price);
        uint256 shortfall = _maxBorrowAtCeiling() - price;

        // The old assertion was `unsocialisedLoss == shortfall - 100e6`: the residual was banked
        // as a claim to be placed on lenders later. Audit round 11 found that wrong here, because
        // there are no lenders in this fixture - the treasury float funded this loan and no lender
        // pool is wired at all. The residual was already borne by the treasury, which lent
        // `_maxBorrowAtCeiling()` and will only ever see the 100 of insurance plus what the lot fetched, so
        // recording it a second time as a placeable claim counted the same loss twice. The second
        // copy was a bearer instrument: `flushSocialisedLoss` is permissionless, so it could be
        // pointed at whoever held pool shares in a later era, and an executed PoC did exactly
        // that. The amount is unchanged and still asserted to the wei; what changed is that it is
        // reported as already borne rather than banked as owed.
        vm.expectEmit(true, false, false, true, address(credit));
        emit CreditManager.LossBorneByTheSource(address(liquidity), shortfall - 100e6);

        vm.prank(bidder);
        auction.bid(id);

        assertEq(credit.debtOf(alice), 0, "the position is resolved either way");
        assertEq(credit.insuranceFund(), 0, "insurance absorbed what it could");
        assertEq(credit.unsocialisedLoss(), 0, "and the rest is the funder's, not a claim on lenders");
        assertEq(credit.claimableOf(alice), 0, "no surplus, so nothing for the borrower");
        assertEq(auction.rewardOf(keeper), 0, "and no penalty to pay the caller from");
        assertEq(bond.bondBalance(bidder), BONDS);
    }

    /// @notice **The short fill now pays the caller, and this is the finding it closes.**
    /// @dev Audit round seventeen: an insolvent position carries no impairment until somebody
    ///      calls `liquidate`, and on a fill short of the debt the protocol paid that caller
    ///      exactly nothing - `repaid` is clamped to the debt, so there is no surplus, so no
    ///      penalty, so no reward. Every lender exit in that window was priced before the loss.
    ///
    ///      The penalty leg is asserted to still be zero on purpose. Nothing about this change
    ///      manufactures a surplus that does not exist; what changed is that the work of
    ///      opening the auction is paid for out of money the borrower prepaid, so the volunteer
    ///      the whole mechanism waits on now has a reason to turn up.
    ///
    ///      **It narrows the window rather than closing it.** The loss-creating event is a
    ///      public NAV post, and an exiter can back-run it and out-bid the liquidator for
    ///      position in the same block. No calibration of this reward closes an ordering race,
    ///      and it should not be recorded as having done so.
    function test_shortFill_paysTheCallerFromTheEscrowWhenThePenaltyCannot() public {
        uint256 id = _openAuction();
        assertEq(
            credit.bountyOwedTo(keeper),
            0,
            "not yet - since round eighteen, opening an auction earns nothing on its own"
        );
        assertEq(
            credit.totalBountyParked(),
            Config.LIQUIDATION_CALL_BOUNTY,
            "it is parked against the auction until an exit says which way it went"
        );

        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id);
        assertLt(price, _maxBorrowAtCeiling(), "a fill short of the debt");

        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        assertEq(auction.rewardOf(keeper), 0, "still no surplus, so still no penalty share");
        assertEq(credit.totalBountyParked(), 0, "the fill resolved it, so the park is empty");
        assertEq(
            credit.bountyOwedTo(keeper),
            Config.LIQUIDATION_CALL_BOUNTY,
            "and only now is it earned"
        );

        vm.prank(keeper);
        credit.claimBounty();
        assertEq(
            usdc.balanceOf(keeper),
            Config.LIQUIDATION_CALL_BOUNTY,
            "but the caller is paid, which is the point"
        );
        assertEq(credit.totalBountyOwed(), 0);
        assertEq(credit.bountyEscrowOf(alice), 0, "and the escrow is spent, not double-counted");
    }

    /// @dev **Audit round eighteen, the critical.** A stranger opened the auction, cured the
    ///      position with a dust `repayFor` and cancelled, all in one transaction: the lot was
    ///      exposed for zero blocks, nothing was resolved, and the whole escrow left with them
    ///      for a dollar. Measured then: spend 1,000,000, take 25,000,000, and the position was
    ///      left permanently disarmed, so the keeper who liquidated it for real afterwards was
    ///      paid nothing against a control of 25,000,000.
    ///
    ///      The escrow now parks against the auction id and is credited only by the transitions
    ///      that actually resolved the position, so opening one is no longer a payday. **Both
    ///      halves are asserted**, because closing the theft while leaving the position disarmed
    ///      would still be the round-seventeen state the mechanism was built to remove.
    ///
    ///      **The claim is attempted before the cancel on purpose.** `claimBounty` is
    ///      permissionless and the attacker chooses the ordering, which is exactly why a
    ///      claw-back hook on `cancel` would not have been sufficient.
    function test_cancel_returnsTheEscrowSoOpeningAnAuctionIsNotAPayday() public {
        uint256 debt = _maxBorrowAtCeiling(); // read before the prank - see `_openAuctionAt`
        vm.prank(alice);
        credit.borrow(debt);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "premise: armed");

        // Just past the threshold, which is where every real liquidation begins and the only
        // band in which a dust cure is cheap enough for the strip to pay for itself.
        oracle.setNav((_thresholdNav() * 999) / 1000);

        address griefer = makeAddr("griefer");
        uint256 dust = 1e6;
        usdc.mint(griefer, dust);
        uint256 heldBefore = usdc.balanceOf(griefer);

        vm.startPrank(griefer);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        assertEq(credit.bountyOwedTo(griefer), 0, "opening it earns nothing on its own");
        usdc.approve(address(credit), dust);
        credit.repayFor(alice, dust);
        auction.cancel(id);
        vm.expectRevert(CreditManager.NoBountyOwed.selector);
        credit.claimBounty();
        vm.stopPrank();

        assertEq(usdc.balanceOf(griefer), heldBefore - dust, "the strip costs the griefer the cure");
        assertEq(vault.bondCount(alice), BONDS, "no collateral moved, as before");
        assertEq(
            credit.bountyEscrowOf(alice),
            Config.LIQUIDATION_CALL_BOUNTY,
            "and the position is still armed for the liquidation that matters"
        );

        // The control the round-eighteen bundle insisted on: the honest keeper who resolves the
        // position afterwards is paid in full, so the zero above is the guard doing its job and
        // not a fixture in which nobody is ever paid.
        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 second = auction.auctionOf(alice);
        skip(Config.AUCTION_DURATION);
        _fundBidder(bidder, auction.currentPrice(second));
        vm.prank(bidder);
        auction.bid(second);

        assertEq(credit.bountyOwedTo(keeper), Config.LIQUIDATION_CALL_BOUNTY, "the keeper is paid");
    }

    /// @dev **The re-arm residual, pinned as accepted rather than left to be discovered.** A
    ///      borrower whose escrow was spent by a real liquidation carries none until they borrow
    ///      again or somebody calls `fundBounty`, so the next caller earns nothing from it.
    ///      `liquidate` must still work: a position that cannot be liquidated is strictly worse
    ///      than one liquidated for nothing. The empty case announces itself with an event
    ///      rather than passing in silence.
    ///
    ///      **The reachable empty case changed with the fix, and the first draft of this test
    ///      got it wrong.** It used to be a borrower liquidated once and cancelled back to
    ///      health; a cancel now returns the escrow, so that state no longer exists. Nor does
    ///      "resolved, then unarmed": every resolution drives the debt to zero, and a borrower
    ///      with no debt cannot be liquidated at all. What is left is the case the dust guard
    ///      creates on purpose - a position under `MIN_BOUNTIED_DEBT`, never charged, which NAV
    ///      can still carry past the liquidation threshold.
    function test_liquidate_stillWorksWithAnEmptyEscrowAndSaysSo() public {
        uint256 dustLoan = Config.MIN_BOUNTIED_DEBT - 1;
        vm.prank(alice);
        credit.borrow(dustLoan);
        assertEq(credit.bountyEscrowOf(alice), 0, "under the dust threshold, so never charged");
        assertEq(usdc.balanceOf(alice), dustLoan, "and the whole draw was disbursed");

        oracle.setNav(_crashedNav());
        address second = makeAddr("secondCaller");
        vm.expectEmit(true, false, false, false, address(credit));
        emit CreditManager.BountyDepleted(alice);
        vm.prank(second);
        credit.liquidate(alice);

        assertGt(auction.auctionOf(alice), 0, "the auction opened regardless, which is the rule");
        assertEq(credit.bountyOwedTo(second), 0, "unrewarded, and that is the recorded residual");
    }

    /// @dev Near the floor `price < debt + penalty` is routine, not exotic. An unclamped
    ///      subtraction would panic in exactly the band where Dutch auctions fill.
    function test_bid_clampsThePenaltyToTheSurplusThatExists() public {
        // _navForPartialPenalty() puts the *floor* price only just above the debt: less
        // full penalty of surplus, but more than none. The decay curve cannot reach
        // that band at a higher NAV, because it stops at the floor by design.
        uint256 id = _openAuctionAt(_navForPartialPenalty());
        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id);
        assertGt(price, _maxBorrowAtCeiling());
        uint256 surplus = price - _maxBorrowAtCeiling();
        assertLt(surplus, (_maxBorrowAtCeiling() * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS, "a partial penalty");

        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        assertEq(credit.claimableOf(alice), 0, "the penalty took all of it");
        assertEq(
            auction.rewardOf(keeper) + credit.insuranceFund(), surplus, "and no more than existed"
        );
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());
    }

    /// @dev Debt before penalty. The other order manufactures a shortfall the insurance
    ///      fund then covers, which is paying the liquidation caller out of insurance.
    function test_bid_appliesDebtBeforePenalty() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id); // 1,020 vs 880.25 of debt

        usdc.mint(address(this), 500e6);
        usdc.approve(address(credit), 500e6);
        credit.fundInsurance(500e6);
        uint256 insuranceBefore = credit.insuranceFund();

        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        assertEq(credit.debtOf(alice), 0);
        assertGt(credit.insuranceFund(), insuranceBefore, "insurance gained its penalty share");
        assertEq(credit.unsocialisedLoss(), 0, "and never had to cover a manufactured shortfall");
    }

    function test_bid_penaltySplitSumsExactlyEvenOnAnOddPenalty() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(_elapsedForPremium(8_200));
        uint256 price = auction.currentPrice(id);

        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        uint256 penalty = (_maxBorrowAtCeiling() * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(auction.rewardOf(keeper) + credit.insuranceFund(), penalty, "no wei invented or lost");
        assertGe(credit.insuranceFund(), auction.rewardOf(keeper), "the odd wei goes to the protocol");
    }

    // ── bid: adverse conditions ──────────────────────────────────────────────

    function test_bid_revertsForAWinnerThatCannotReceiveErc1155() public {
        uint256 id = _openAuctionAt(_softNav());
        RejectingBidder rejecting = new RejectingBidder();
        usdc.mint(address(rejecting), 2_000e6);

        vm.expectRevert();
        rejecting.bid(auction, usdc, id);

        // Nothing moved, and the auction is still live for someone who can take it.
        assertEq(vault.bondCount(alice), BONDS);
        assertTrue(auction.isLiquidating(alice));
    }

    function test_bid_succeedsForAContractWinnerThatCan() public {
        uint256 id = _openAuctionAt(_softNav());
        ContractBidder accepting = new ContractBidder();
        usdc.mint(address(accepting), 2_000e6);

        accepting.bid(auction, usdc, id);
        assertEq(bond.bondBalance(address(accepting)), BONDS);
    }

    /// @notice The callback is the one moment the auction hands control to arbitrary
    ///         code. Everything the attacker can reach must already be closed, and the
    ///         settlement figures must be read after them, not before.
    function test_bid_isNotReentrableThroughTheWinnersCallback() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(_elapsedForPremium(8_200));
        uint256 price = auction.currentPrice(id);

        ReentrantBidder attacker = new ReentrantBidder();
        attacker.arm(auction, credit, usdc, alice, 100e6);
        usdc.mint(address(attacker), price + 100e6);

        attacker.bid(id);

        assertTrue(attacker.callbackRan(), "the callback must actually have fired");
        assertFalse(attacker.reBidSucceeded(), "a second fill of the same lot");
        assertFalse(attacker.reLiquidateSucceeded(), "a second auction over the same position");

        // The repayment made from inside the callback is honoured rather than
        // double-counted: the sums still close exactly.
        assertEq(credit.debtOf(alice), 0);
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());
    }

    function test_bid_revertsWhenTheBidderIsBlacklisted() public {
        uint256 id = _openAuctionAt(_softNav());
        _fundBidder(bidder, 2_000e6);
        usdc.setBlocked(bidder, true);

        vm.prank(bidder);
        vm.expectRevert();
        auction.bid(id);
        assertTrue(auction.isLiquidating(alice), "their problem, not the protocol's");
    }

    /// @notice DexFi's gate passes if *any* party is whitelisted, so a whitelisted
    ///         bidder can still fill after the adapter's entry is revoked. That is a
    ///         real escape hatch and must be a test, not a discovery during an incident.
    function test_bid_stillFillsToAWhitelistedWinnerAfterTheAdapterIsRevoked() public {
        uint256 id = _openAuctionAt(_softNav());
        bond.setWhitelisted(address(adapter), false);
        bond.setWhitelisted(bidder, true);

        _fundBidder(bidder, 2_000e6);
        vm.prank(bidder);
        auction.bid(id);
        assertEq(bond.bondBalance(bidder), BONDS);
    }

    function test_bid_revertsAfterTheAuctionIsCancelled() public {
        uint256 id = _openAuctionAt(_softNav());
        oracle.setNav(NAV);
        auction.cancel(id);

        _fundBidder(bidder, 2_000e6);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionClosed.selector, id));
        auction.bid(id);
    }

    /// @notice A lapsed auction stops being fillable, and `liquidate` supersedes it with
    ///         a correctly-priced one.
    /// @dev Composed on purpose. An earlier version kept bids legal at the floor
    ///         forever, reasoning that a floor fill beats a manual redemption. That
    ///         turned an uncancelled auction into a perpetual call option struck at 68%
    ///         of a frozen NAV: `cancel` is permissionless but unrewarded, so a healed
    ///         auction lingers, blocks any replacement, and can be filled at the stale
    ///         price the moment the borrower re-levers. Refusing the stale fill is only
    ///         safe *because* supersession replaces it, so both halves are asserted
    ///         together - refusing without a replacement would just be a stuck position.
    ///
    ///         **Audit round 19 changed how the replacement happens, not whether it does.** It used
    ///         to settle the lapsed auction and mint a new id; it now re-strikes the same auction in
    ///         place, Maker `Clipper.redo`-style, because minting a new id was what let the parked
    ///         bounty be re-assigned to whoever made that call - see the test below. The two things
    ///         this test actually cares about are unchanged: the stale fill is refused, and a fresh
    ///         price is reachable.
    function test_bid_lapsesAfterTheWindowAndLiquidateReStrikesIt() public {
        uint256 first = _openAuctionAt(_softNav());
        // Inside `Config.AUCTION_RESET_WINDOW`, because a re-strike past that is refused outright -
        // asserted in its own test rather than smuggled in here.
        skip(Config.AUCTION_DURATION + 1 hours);

        _fundBidder(bidder, 5_000e6);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, first));
        auction.bid(first, type(uint256).max);

        // The re-strike reprices from scratch at current NAV, which is the thing the
        // stale floor fill was standing in for.
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 second = auction.auctionOf(alice);
        assertEq(second, first, "the same auction, re-struck rather than replaced");
        assertEq(auction.currentPremiumBps(second), Config.AUCTION_START_PREMIUM_BPS, "priced fresh, not at a floor");

        vm.prank(bidder);
        auction.bid(second);
        assertEq(bond.bondBalance(bidder), BONDS);
    }

    /// @notice The re-strike window is a deadline measured from the first open, and re-striking
    ///         cannot extend it.
    /// @dev **Audit round 19, critical 2, and this is the bound the whole finding turned on.** The
    ///      re-strike was free, permissionless and unbounded, and each one restarted the auction's
    ///      liveness register - which `CreditManager._impairmentFor` keys the lender pool's mark on.
    ///      So an attacker holding no capital could keep a position live forever, six hours at a
    ///      time, and hold the entire withdrawal queue shut over idle cash while
    ///      `openWorkoutCount` never left zero and no clock was ever armed.
    ///
    ///      Both halves asserted together, deliberately. A test that only showed the refusal would
    ///      pass just as happily against an auction that can never be resolved at all, which is a
    ///      worse bug than the one being fixed - so the workout that the refusal is supposed to
    ///      leave reachable is actually taken here.
    function test_liquidate_reStrikingIsBoundedAndThenTheWorkoutIsTheOnlyMoveLeft() public {
        // Holds nothing at any point, which is the whole shape of the finding: the freeze cost the
        // attacker gas and no capital at all.
        address griefer = makeAddr("reStrikeGriefer");
        uint256 id = _openAuctionAt(_softNav());
        uint256 opened = auction.firstOpenedAt(id);
        assertEq(opened, block.timestamp, "premise: the open stamps the clock");

        // Re-strike as often as the window allows. Each lap is a full lapse plus one second, which
        // is the cheapest cadence available to a griefer.
        uint256 laps;
        while (block.timestamp + Config.AUCTION_DURATION + 1 <= opened + Config.AUCTION_RESET_WINDOW) {
            skip(Config.AUCTION_DURATION + 1);
            vm.prank(griefer);
            credit.liquidate(alice);
            assertEq(auction.auctionOf(alice), id, "still one auction, re-struck in place");
            assertEq(auction.firstOpenedAt(id), opened, "and re-striking never moves its own deadline");
            laps++;
        }
        assertGt(laps, 0, "fixture: the window has to permit at least one re-strike");

        // Past the deadline the door is shut, by name.
        skip(Config.AUCTION_DURATION + 1);
        vm.prank(griefer);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationAuction.AuctionResetWindowClosed.selector, id, opened + Config.AUCTION_RESET_WINDOW
            )
        );
        credit.liquidate(alice);

        // And what is left is the bounded path: permissionless, already legal, and it arms the
        // forced close that ends the lender pool's mark.
        assertEq(auction.openWorkoutCount(), 0, "premise: no clock was armed while re-strikes ran");
        auction.expireToWorkout(id);
        assertEq(auction.openWorkoutCount(), 1, "the workout clock is armed");
        assertEq(auction.liveAuctionCount(), 0, "and the auction is no longer live");
    }

    /// @notice A re-struck auction keeps its parked bounty with the caller who opened it.
    /// @dev **Audit round 19, critical 1, and this test asserted the exact opposite before it.** It
    ///      used to be called `..._supersedingRollsTheEscrowOnToTheNewCallerAndAuction`, and it
    ///      pinned the hand-over as correct behaviour using two strangers, `firstCaller` and
    ///      `keeper`. Substituting the *borrower* for the second one was the whole finding: a keeper
    ///      opens the auction and does the work, the borrower waits one second past the lapse,
    ///      re-strikes, and the 25 USDC lands on them instead. Measured on a genuine default with a
    ///      short fill - keeper 0, borrower 25,000,000, borrower's total out equal to `_maxBorrowAtCeiling()`.
    ///      The keeper's only defence was one second wide: `expireToWorkout` is legal from
    ///      `>= finishesAt` and the re-strike from `> finishesAt`, and nobody is paid to use it.
    ///
    ///      **`require(msg.sender != borrower)` was measured to move nothing** - a second wallet is
    ///      paid identically - so the fix is structural rather than an identity check. Re-striking
    ///      in place means there is no unwind and no re-park at all: `resolveBounty` is not called,
    ///      the park never leaves the id, and the claimant field is never rewritten. Nothing can be
    ///      re-assigned because nothing moves.
    ///
    ///      The borrower is used here as the second caller on purpose. The old test's two strangers
    ///      are what made it look safe.
    function test_liquidate_reStrikingLeavesTheParkedBountyWithTheCallerWhoOpenedIt() public {
        address firstCaller = makeAddr("firstCaller");
        uint256 debt = _maxBorrowAtCeiling(); // read before the prank - see `_openAuctionAt`
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(_softNav());

        vm.prank(firstCaller);
        credit.liquidate(alice);
        uint256 first = auction.auctionOf(alice);
        (,, uint256 parkedFirst) = credit.parkedBountyOf(first);
        assertEq(parkedFirst, Config.LIQUIDATION_CALL_BOUNTY, "parked against the auction at open");

        skip(Config.AUCTION_DURATION + 1);

        // The borrower themselves, which is the adversary the old version never substituted in.
        vm.prank(alice);
        credit.liquidate(alice);
        uint256 second = auction.auctionOf(alice);
        assertEq(second, first, "premise: the same auction, re-struck rather than replaced");

        (address claimant,, uint256 parked) = credit.parkedBountyOf(first);
        assertEq(parked, Config.LIQUIDATION_CALL_BOUNTY, "the escrow never left the auction it was parked against");
        assertEq(claimant, firstCaller, "and it still belongs to whoever opened it, not to whoever re-struck it");
        assertEq(credit.bountyEscrowOf(alice), 0, "it never passed back through the borrower's escrow");
        assertEq(credit.totalBountyParked(), Config.LIQUIDATION_CALL_BOUNTY, "counted once, not twice");

        // And when it finally resolves, it pays the opener - not the borrower who re-struck it.
        // This is the assertion the finding inverted, so it is the one that matters most here.
        skip(Config.AUCTION_DURATION);
        _fundBidder(bidder, auction.currentPrice(second));
        vm.prank(bidder);
        auction.bid(second);

        assertEq(credit.bountyOwedTo(firstCaller), Config.LIQUIDATION_CALL_BOUNTY, "the keeper is paid for the work");
        assertEq(credit.bountyOwedTo(alice), 0, "and the borrower collects nothing by re-striking it");
    }

    /// @notice The floor is reachable at the last instant of the window, not an
    ///         asymptote - the lapse check is strictly-after for exactly this reason.
    function test_bid_fillsAtExactlyTheFloorOnTheFinalInstant() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        assertEq(auction.currentPremiumBps(id), Config.AUCTION_FLOOR_BPS);

        _fundBidder(bidder, 5_000e6);
        vm.prank(bidder);
        auction.bid(id);
        assertEq(bond.bondBalance(bidder), BONDS);
    }

    /// @notice The pinned and capped forms, composed. Asserting only that the pinned
    ///         form refuses a grown lot would pass forever even if no form could fill
    ///         one - which is a borrower griefing every bid by depositing one bond.
    function test_bid_pinnedRefusesAGrownLotAndTheCappedFormTakesIt() public {
        // At $10.00 a bond, 150 bonds is still 5,868 bps - the top-up grows the lot
        // without curing the position, which is the case the pinned form is about.
        uint256 id = _openAuction();
        vm.prank(alice);
        vault.depositBonds(50);

        _fundBidder(bidder, 5_000e6);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.LotChanged.selector, BONDS, BONDS + 50));
        auction.bid(id);

        uint256 price = auction.currentPrice(id);
        vm.prank(bidder);
        auction.bid(id, price);
        assertEq(bond.bondBalance(bidder), BONDS + 50, "the whole grown lot, at the same price per bond");
    }

    /// @notice A borrower can top up their way out of a live auction, and when they do
    ///         the bid must fail rather than sell healthy collateral at a discount.
    /// @dev The vault's own gate is what refuses it, which is the whole reason that gate
    ///      exists: the auction alone would happily fill a position that healed after it
    ///      opened. Composed with the cancel that clears the stale auction afterwards,
    ///      because a refusal with no way to clear the auction is a permanent strand.
    function test_bid_revertsOnceATopUpHasCuredThePositionAndCancelClearsIt() public {
        uint256 id = _openAuctionAt(_softNav());
        vm.prank(alice);
        vault.depositBonds(50); // 150 bonds at _softNav() is 4,444 bps: healthy again

        _fundBidder(bidder, 5_000e6);
        uint256 price = auction.currentPrice(id);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, uint256(4_444)));
        auction.bid(id, price);

        auction.cancel(id);
        assertFalse(auction.isLiquidating(alice));
        assertEq(vault.bondCount(alice), BONDS + 50, "she keeps everything, including the top-up");
    }

    function test_bid_revertsAboveTheCallersCap() public {
        uint256 id = _openAuctionAt(_softNav());
        uint256 price = auction.currentPrice(id);

        _fundBidder(bidder, 5_000e6);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.PriceAboveCap.selector, price, price - 1));
        auction.bid(id, price - 1);
    }

    function test_bid_pullsExactlyTheCurrentPriceAndNoMore() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(_elapsedForPremium(8_200));
        uint256 price = auction.currentPrice(id);

        _fundBidder(bidder, 5_000e6);
        uint256 before = usdc.balanceOf(bidder);
        vm.prank(bidder);
        auction.bid(id);
        assertEq(before - usdc.balanceOf(bidder), price, "an allowance is not a licence");
    }

    /// @notice Anyone can donate bonds to this contract, because it is an
    ///         `ERC1155Holder`. Nothing may be sized from a balance.
    function test_bid_ignoresDonatedBondsAndUsdc() public {
        uint256 id = _openAuctionAt(_softNav());
        address donor = makeAddr("donor");
        bond.mint(donor, 500);
        bond.setWhitelisted(donor, true);
        vm.prank(donor);
        bond.safeTransferFrom(donor, address(auction), Config.DEXFI_BOND_TOKEN_ID, 500, "");
        usdc.mint(address(auction), 10_000e6);

        uint256 price = auction.currentPrice(id);
        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        assertEq(bond.bondBalance(bidder), BONDS, "the lot, not the donation");
        assertEq(
            usdc.balanceOf(address(auction)),
            10_000e6 + auction.totalUnclaimedRewards(),
            "the donation is inert, not spendable"
        );
    }

    function test_claimReward_revertsWithNothingToClaim() public {
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimReward();
    }

    // ── workout: the expiry path ─────────────────────────────────────────────

    function _deliverYield(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
    }

    function test_expireToWorkout_movesTheClaimAndLeavesTheLotStaked() public {
        uint256 id = _openAuction();
        uint256 stakedBefore = farm.staked(address(adapter));
        skip(Config.AUCTION_DURATION);

        auction.expireToWorkout(id); // permissionless

        assertEq(vault.bondCount(alice), 0);
        assertEq(vault.bondCount(address(auction)), BONDS, "the claim moved");
        assertEq(farm.staked(address(adapter)), stakedBefore, "the bonds did not");
        assertEq(bond.bondBalance(address(auction)), 0, "and nothing was escrowed");
        assertFalse(auction.isLiquidating(alice));
        assertEq(auction.openWorkoutCount(), 1);
        assertEq(auction.openWorkoutAt(0), id);
    }

    /// @dev The loss is unknown until DexFi actually pays. Recognising a guess either
    ///      understates it and misleads lenders, or overstates it and hands the borrower
    ///      a windfall when the redemption comes good.
    function test_expireToWorkout_leavesTheDebtStandingUntilRecoveryIsKnown() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        assertEq(credit.debtOf(alice), _maxBorrowAtCeiling(), "still owed");
        assertEq(credit.unsocialisedLoss(), 0, "and nothing guessed at lenders' expense");
        (,,,, uint256 debtAtExpiry,,,,,,) = auction.workouts(id);
        assertEq(debtAtExpiry, _maxBorrowAtCeiling());
    }

    function test_expireToWorkout_revertsBeforeTheDurationElapses() public {
        uint256 id = _openAuction();
        uint256 finishesAt = auction.endsAt(id);
        skip(Config.AUCTION_DURATION - 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionStillRunning.selector, finishesAt));
        auction.expireToWorkout(id);
    }

    /// @notice **The property, not the guards.** Every adverse condition at once, and
    ///         the auction must still have a reachable exit.
    /// @dev Written as one test on purpose. Six tests each asserting "reverts correctly"
    ///      under one condition would all pass forever while the combined state was a
    ///      permanent strand - which is exactly how round-4 finding #1 survived review.
    function test_aLiveAuctionAlwaysHasAnExitUnderEveryAdverseConditionAtOnce() public {
        // Condition 4 has to be arranged first, before the loan exists, and that is a fact about
        // the protocol rather than about the fixture. Since audit round 11 a pool is only offered
        // a loss while it is also the liquidity source - a balance sheet that lent nothing cannot
        // be charged for a default - and `setLiquiditySource` refuses to move while any principal
        // is outstanding. So "the lender pool refuses every loss" is only an adverse condition at
        // all if the pool is the one that funded the loan, and it can only become that before the
        // borrow. Wiring it as a bare loss sink here, as this test used to, would leave the
        // condition doing nothing and the test claiming six adversities while exercising five.
        MockLenderPool pool = new MockLenderPool(usdc);
        usdc.mint(address(pool), FLOAT);
        vm.startPrank(admin);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        vm.stopPrank();

        uint256 id = _openAuction();

        // 1. DexFi revokes the adapter's transfer whitelist entry.
        bond.setWhitelisted(address(adapter), false);
        // 2. The farm stops honouring withdrawals.
        farm.setRevertOnWithdraw(true);
        // 3. The borrower is USDC-blacklisted, so nothing can be pushed to them.
        usdc.setBlocked(alice, true);
        // 4. The lender pool - which funded this loan - refuses every loss. Wired above.
        assertFalse(pool.accepting());
        // 5. The insurance fund is empty.
        assertEq(credit.insuranceFund(), 0);
        // 6. The NAV feed has gone stale.
        oracle.setStale(true);

        // A bid cannot fill - the farm will not release the bonds.
        _fundBidder(bidder, 5_000e6);
        vm.prank(bidder);
        vm.expectRevert();
        auction.bid(id, type(uint256).max);

        // A cancel cannot close it either - the position is genuinely still underwater.
        vm.expectRevert();
        auction.cancel(id);

        // The third exit must work, and it does, because it touches none of them.
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        assertFalse(auction.isLiquidating(alice), "the borrower is re-liquidatable again");
        assertEq(vault.bondCount(address(auction)), BONDS);
        assertEq(auction.openWorkoutCount(), 1);

        // And the loss can still be recognised on schedule, with the pool still refusing.
        skip(Config.WORKOUT_MAX_DURATION);

        // Condition 4 has to bite, not merely be configured, and the post-state cannot tell the
        // difference: a pool that is never asked and a pool that is asked and refuses leave the
        // counter reading the same number. Round 11 is why that matters here. The old wiring -
        // a pool that sank losses without funding anything - is the exact state the round
        // decided should never produce a deferral at all, so this condition had to be re-stated
        // in terms of who funded the loan, and re-stating a condition is when one goes hollow.
        //
        // It is asserted from the outside because the mock cannot testify to it: `socialiseLoss`
        // increments a counter and then reverts, and the revert rolls the increment back with
        // everything else, so a refusal is invisible in the mock's own storage by construction.
        vm.expectCall(address(pool), abi.encodeCall(MockLenderPool.socialiseLoss, (_maxBorrowAtCeiling())));
        auction.closeWorkout(id);

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.unsocialisedLoss(), _maxBorrowAtCeiling(), "remembered, not lost");
        assertEq(auction.openWorkoutCount(), 0);
    }

    function test_workoutSettle_repaysAndPaysTheSameSplitAsAFill() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        // DexFi redeems at 90% of NAV; an operator relays the proceeds.
        uint256 recovery = 1_350e6;
        address operator = makeAddr("operator");
        usdc.mint(operator, recovery);
        vm.startPrank(operator);
        usdc.approve(address(auction), recovery);
        auction.workoutSettle(id, recovery);
        vm.stopPrank();

        uint256 penalty = (_maxBorrowAtCeiling() * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(credit.debtOf(alice), 0);
        assertEq(auction.rewardOf(keeper), penalty / 2, "the same split a fill would have paid");
        assertEq(credit.insuranceFund(), penalty - penalty / 2);
        assertEq(credit.claimableOf(alice), recovery - _maxBorrowAtCeiling() - penalty);
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());
    }

    /// @dev A manual redemption may pay in stages. Writing the gap down on the first
    ///      tranche would socialise a loss the second tranche covers.
    function test_workoutSettle_acceptsPartialTranchesWithoutSocialisingEarly() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        address operator = makeAddr("operator");
        usdc.mint(operator, _maxBorrowAtCeiling());
        vm.startPrank(operator);
        usdc.approve(address(auction), _maxBorrowAtCeiling());

        auction.workoutSettle(id, 400e6);
        assertGt(credit.debtOf(alice), 0, "still owed after the first tranche");
        assertEq(credit.unsocialisedLoss(), 0, "and nothing written off prematurely");

        auction.workoutSettle(id, _maxBorrowAtCeiling() - 400e6);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.unsocialisedLoss(), 0, "the second tranche covered it, as it should");

        auction.closeWorkout(id);
        assertEq(auction.openWorkoutCount(), 0);
    }

    function test_closeWorkout_revertsWhileDebtStandsInsideTheWindow() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        (, uint96 openedAt,,,,,,,,,) = auction.workouts(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationAuction.WorkoutStillRunning.selector, openedAt + Config.WORKOUT_MAX_DURATION
            )
        );
        auction.closeWorkout(id);
    }

    /// @notice Recognition on a schedule nobody has to be trusted to keep.
    function test_closeWorkout_forcedAfterTheWindowRecognisesTheResidual() public {
        uint256 id = _openAuction();
        usdc.mint(address(this), 300e6);
        usdc.approve(address(credit), 300e6);
        credit.fundInsurance(300e6);

        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);

        // The old assertion was `unsocialisedLoss == _maxBorrowAtCeiling() - 300e6`, labelled "and the rest
        // is lenders'". The residual is the point of this test and the figure is untouched, but
        // whose it is was wrong: the treasury float funded this loan and no lender pool is wired,
        // so round 11 stopped recording a loss the funder is already carrying as a claim on
        // somebody else. The recognition still happens on schedule, permissionlessly, for the
        // exact amount insurance could not reach - it is now reported against the source that
        // bears it instead of being banked against a pool that lent nothing.
        uint256 residual = _maxBorrowAtCeiling() - 300e6; // read before the cheatcode, not inside it
        vm.expectEmit(true, false, false, true, address(credit));
        emit CreditManager.LossBorneByTheSource(address(liquidity), residual);

        auction.closeWorkout(id); // permissionless

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.insuranceFund(), 0, "insurance absorbed what it could");
        assertEq(credit.unsocialisedLoss(), 0, "the residual is the funder's, not a claim to place");
        assertEq(auction.openWorkoutCount(), 0);
    }

    // ── Audit round 21, finding 14: the forced close and the late tranche ─────

    /// @notice The control. A tranche that lands INSIDE the window pays the debt down.
    function test_H_control_recoveryInsideTheWindowPaysTheDebtDown() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        assertEq(credit.currentDebtOf(alice), 628.750000e6, "premise: the debt at expiry");

        address operator = makeAddr("operator");
        usdc.mint(operator, 400e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 400e6);
        auction.workoutSettle(id, 400e6);
        vm.stopPrank();

        emit log_named_uint("MEASURED debt after a 400.000000 tranche inside the window", credit.currentDebtOf(alice));
        assertEq(credit.currentDebtOf(alice), 228.750000e6, "628.750000 -> 228.750000");
    }

    /// @notice The hazard. The same tranche one day later, after a stranger forced the close.
    /// @dev DexFi's redemption is off-chain and quoted at "48h+", so a tranche genuinely can be a
    ///      day late. `closeWorkout` is permissionless the instant the window passes, so a stranger
    ///      - not the operator, not the borrower, nobody with any stake - picks the moment.
    function test_H_hazard_theForcedCloseDestroysTheLateTranche() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        assertEq(credit.currentDebtOf(alice), 628.750000e6, "premise: the debt at expiry");

        skip(Config.WORKOUT_MAX_DURATION);

        // Nothing has arrived at this contract to be swept before the write-off, which is what
        // makes the "settle what has already arrived" fix inert on this trace.
        assertEq(
            usdc.balanceOf(address(auction)) - auction.totalUnclaimedRewards(),
            0,
            "premise: no unapplied recovery is sitting here at the moment of the close"
        );

        uint256 writtenOff = credit.currentDebtOf(alice);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        auction.closeWorkout(id);

        emit log_named_uint("MEASURED written off by the forced close (USDC 6dp)", writtenOff);
        assertEq(writtenOff, 628.750000e6, "628.750000 written off in full");
        assertEq(credit.debtOf(alice), 0, "and the debt is gone");
        assertEq(liquidity.outstandingPrincipal(), 628.750000e6, "the funder is still out the whole loan");

        // The tranche arrives the next day. `workoutSettle` and `repayFor` both refuse it.
        skip(1 days);
        address operator = makeAddr("operator");
        usdc.mint(operator, 400e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 400e6);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.WorkoutNotOpen.selector, id));
        auction.workoutSettle(id, 400e6);

        usdc.approve(address(credit), 400e6);
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.repayFor(alice, 400e6);
        vm.stopPrank();

        // The fix, in the same trace: the tranche now lands, and it lands on the balance sheet
        // that funded the loan rather than on the insurance fund.
        vm.startPrank(operator);
        auction.workoutSettleAfterClose(id, 400e6);
        vm.stopPrank();

        assertEq(credit.pendingPrincipal(), 400e6, "booked as principal owed home");
        assertEq(credit.insuranceFund(), 0, "and NOT as a donation that only a future default reaches");

        credit.settlePrincipal(); // permissionless, already here
        emit log_named_uint("MEASURED recovered to the funder after the forced close", 400e6);
        assertEq(liquidity.outstandingPrincipal(), 228.750000e6, "628.750000 -> 228.750000, one day late");
    }

    /// @notice The sign check on the fix this finding's first candidate prescribed, run as a
    ///         measurement rather than argued.
    /// @dev The obvious structural fix is "settle what has already arrived at the moment of the
    ///      close, so the write-off is only ever of what genuinely did not arrive". It is a
    ///      reasonable-sounding change and on this trace it moves **nothing**: an off-chain
    ///      redemption quoted at "48h+" has not arrived at all when the fourteenth day passes, so
    ///      the free balance a sweep would find is zero and the figure written off is identical.
    ///      Asserted as `assertEq(sweptFirst, shipped)` because eight prescribed fixes in a row on
    ///      this project have failed a sign check and the eighth failed by being inert.
    ///
    ///      It is not a bad change - it closes a different, smaller trace, where a relayer
    ///      `transfer`s USDC here instead of calling `workoutSettle`. It is simply not this one,
    ///      and it would have read like closure.
    function test_H_signCheck_sweepingWhatHasArrivedAtTheCloseMovesNothing() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);

        // What the prescribed variant would have found to settle before writing off.
        uint256 sweepable = usdc.balanceOf(address(auction)) - auction.totalUnclaimedRewards();
        uint256 shipped = credit.currentDebtOf(alice);
        uint256 sweptFirst = shipped > sweepable ? shipped - sweepable : 0;

        emit log_named_uint("MEASURED unapplied balance a pre-close sweep would find", sweepable);
        assertEq(sweepable, 0, "there is nothing here: the redemption has not arrived");
        assertEq(sweptFirst, shipped, "the prescribed fix writes off exactly what the shipped one does");

        auction.closeWorkout(id);
        assertEq(credit.debtOf(alice), 0);
    }

    /// @notice Bounded by what the close wrote off **and nobody was made whole for**.
    /// @dev The insurance fund has already handed its part to the liquidity source through
    ///      `pendingPrincipal`, so crediting a recovery against that part would settle the same
    ///      tranche twice. `fundInsurance` is the permissionless destination for anything above the
    ///      bound, and it is already here.
    function test_H_fix_isBoundedByThePartNobodyWasMadeWholeFor() public {
        uint256 id = _openAuction();
        usdc.mint(address(this), 300e6);
        usdc.approve(address(credit), 300e6);
        credit.fundInsurance(300e6);

        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(id);

        (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
        emit log_named_uint("MEASURED recoverable after a close that insurance part-covered", writtenDown);
        assertEq(writtenDown, 328.750000e6, "628.750000 written off, 300.000000 of it already paid home");
        assertEq(credit.pendingPrincipal(), 300e6, "insurance's part is already on its way to the funder");

        address operator = makeAddr("operator");
        usdc.mint(operator, 400e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 400e6);
        auction.workoutSettleAfterClose(id, 400e6); // asks for more than the bound
        vm.stopPrank();

        assertEq(usdc.balanceOf(operator), 400e6 - 328.750000e6, "the pull is clamped, not the caller refused");
        assertEq(credit.pendingPrincipal(), 300e6 + 328.750000e6, "and the funder is whole for the whole loan");

        (,,,,,,, uint256 left,,,) = auction.workouts(id);
        assertEq(left, 0, "nothing left to recover");
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NothingLeftToRecover.selector, id));
        auction.workoutSettleAfterClose(id, 1e6);
    }

    /// @notice A workout that closed cleanly wrote nothing off, so there is nothing to repay.
    /// @dev The second trap round 21 named: once the residual is zero the close is legal
    ///      immediately, with no fourteen-day wait. That path must not open a route for money to
    ///      arrive at a loan that was repaid in full - `_distribute`'s waterfall would send it to
    ///      the borrower, and this function has no waterfall at all.
    function test_H_fix_refusedOnAWorkoutThatClosedClean() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        address operator = makeAddr("operator");
        usdc.mint(operator, 1_350e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 1_350e6);
        auction.workoutSettle(id, 1_350e6); // clears the debt in full
        vm.stopPrank();

        auction.closeWorkout(id); // legal immediately, and rightly so
        (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
        assertEq(writtenDown, 0, "nothing was written off, so nothing can be repaid");

        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NothingLeftToRecover.selector, id));
        auction.workoutSettleAfterClose(id, 1e6);
    }

    /// @notice And it refuses a workout that is still open, which `workoutSettle` is for.
    function test_H_fix_refusesAWorkoutThatIsStillOpen() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.WorkoutNotClosed.selector, id));
        auction.workoutSettleAfterClose(id, 1e6);
    }

    /// @notice Arming a position is refused once its liquidation has started.
    /// @dev A park is fixed at `liquidate` and cannot be topped up, so money paid in during a
    ///      live auction cannot reach the caller working on it. Accepting it would take payment
    ///      for a service this contract cannot deliver, and would leave the amount sitting in
    ///      `bountyEscrowOf` until `writeDownLoss` cleared the debt - refundable, at that point,
    ///      to the borrower who had just defaulted.
    ///
    ///      Both registers are checked, because they cover different halves of a liquidation's
    ///      life and `expireToWorkout` moves a position from one to the other.
    function test_fundBounty_refusedOnceALiquidationHasStarted() public {
        uint256 id = _openAuction();
        assertEq(credit.bountyEscrowOf(alice), 0, "premise: parked against the auction");

        // The borrower's own top-up, which is the only funder `fundBounty` accepts since audit
        // round 21 - so this test still exercises the liveness gate rather than stopping on the
        // provenance gate in front of it. See `test_fundBounty_refusesAnyFunderButTheBorrower`.
        usdc.mint(alice, Config.LIQUIDATION_CALL_BOUNTY);
        vm.startPrank(alice);
        usdc.approve(address(credit), Config.LIQUIDATION_CALL_BOUNTY);

        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.BountyFundingWhileLiquidating.selector, alice)
        );
        credit.fundBounty(alice, Config.LIQUIDATION_CALL_BOUNTY);
        vm.stopPrank();

        // And still refused once the auction has become a workout, which clears `auctionOf` and
        // sets `workoutsOpenFor` - so a check on only the first register would let it through.
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        assertEq(auction.auctionOf(alice), 0, "premise: the first register is clear");
        assertGt(auction.workoutsOpenFor(alice), 0, "and the second one is not");

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.BountyFundingWhileLiquidating.selector, alice)
        );
        credit.fundBounty(alice, Config.LIQUIDATION_CALL_BOUNTY);
        vm.stopPrank();
    }

    /// @notice A borrower holds no escrow for as long as their auction is live.
    /// @dev **This is the property that keeps `writeDownLoss` out of the bounty accounting, and
    ///      it is named for the property rather than for the bug because the bug it was written
    ///      against turned out not to exist here.**
    ///
    ///      Round eighteen's prescription warned of a landmine: once the release is gated, a
    ///      genuine default reaches `writeDownLoss` still holding the escrow, and that function
    ///      is the one `debtOf` writer that never refunds - so completing the pattern
    ///      symmetrically would hand a defaulter the deposit meant to pay whoever cleaned up
    ///      after them. **Built as written into `writeDownLoss` and executed, that refund
    ///      changes nothing at all.** `_refundBounty` needs `bountyEscrowOf[borrower] != 0`,
    ///      and under parking the borrower holds nothing from `liquidate` onwards. The landmine
    ///      is real for the design the note assumed - gating the release *in place* - and
    ///      unreachable for the one actually built.
    ///
    ///      So the thing worth pinning is the precondition, not the symptom. Delete the line in
    ///      `liquidate` that empties `bountyEscrowOf` and twenty tests in this file go red,
    ///      several by arithmetic underflow on the double-counted total; this one names why.
    ///
    ///      Both `writeDownLoss` callers are exercised, because they credit at different
    ///      moments and a check on one says nothing about the other: `_distribute` on a short
    ///      fill, where the caller is credited in the same transaction, and the forced
    ///      `closeWorkout`, where it happened at expiry hours earlier.
    function test_liquidate_leavesTheBorrowerNoEscrowWhileTheAuctionIsLive() public {
        // Path one: a short fill. `_distribute` repays what it can and writes the rest down.
        uint256 id = _openAuction();
        assertEq(credit.bountyEscrowOf(alice), 0, "held by the auction, not by the borrower");
        assertEq(credit.totalBountyParked(), Config.LIQUIDATION_CALL_BOUNTY, "and it is parked");

        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id);
        assertLt(price, _maxBorrowAtCeiling(), "premise: the fill cannot cover the debt");
        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        assertEq(credit.debtOf(alice), 0, "premise: writeDownLoss drove the debt to zero");
        assertEq(credit.claimableOf(alice), 0, "the defaulter is refunded nothing");
        assertEq(credit.bountyEscrowOf(alice), 0, "and holds no escrow to be refunded later");
        assertEq(credit.bountyOwedTo(keeper), Config.LIQUIDATION_CALL_BOUNTY, "the caller has it");
        assertEq(credit.totalBountyParked(), 0);

        // Path two: an expiry to workout, forced closed past the window.
        address bob = makeAddr("bob");
        bond.mint(bob, 1_000);
        vm.startPrank(bob);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();

        oracle.setNav(NAV);
        uint256 bobsDebt = _maxBorrowAtCeiling(); // read before the prank - see `_openAuctionAt`
        vm.prank(bob);
        credit.borrow(bobsDebt);
        assertEq(credit.bountyEscrowOf(bob), Config.LIQUIDATION_CALL_BOUNTY, "premise: armed");

        oracle.setNav(_crashedNav());
        vm.prank(keeper);
        credit.liquidate(bob);
        assertEq(credit.bountyEscrowOf(bob), 0, "and emptied the moment the auction opened");

        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(auction.auctionOf(bob));
        assertEq(credit.totalBountyParked(), 0, "the expiry spent the park");
        uint256 owedBeforeTheWriteDown = credit.bountyOwedTo(keeper);

        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(1 + id); // bob's auction id, one past alice's

        assertEq(credit.debtOf(bob), 0, "premise: the forced close wrote the residual down");
        assertEq(credit.claimableOf(bob), 0, "and this defaulter is refunded nothing either");
        assertEq(credit.bountyEscrowOf(bob), 0);
        assertEq(credit.bountyOwedTo(keeper), owedBeforeTheWriteDown, "nothing moved at all");
    }

    function test_closeWorkout_revertsForAWorkoutThatIsNotOpen() public {
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.WorkoutNotOpen.selector, uint256(1)));
        auction.closeWorkout(1);
    }

    /// @notice A workout lot keeps earning, and that yield belongs to the side of the
    ///         ledger the default damaged.
    function test_sweepWorkoutYieldToInsurance() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        // The auction now holds the only position, so it earns the whole epoch.
        _deliverYield(500e6);
        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();

        uint256 insuranceBefore = credit.insuranceFund();
        auction.sweepWorkoutYieldToInsurance(); // permissionless

        assertGt(credit.insuranceFund(), insuranceBefore, "the default's own collateral pays it down");
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards(), "nothing left behind");
    }

    function test_sweepWorkoutYield_revertsWithNothingToSweep() public {
        vm.expectRevert();
        auction.sweepWorkoutYieldToInsurance();
    }

    /// @dev Swap-and-pop has an off-by-one waiting in it, and a keeper reads this queue.
    function test_workoutQueue_tracksMultiplePositionsThroughClose() public {
        uint256 first = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(first);

        address bob = makeAddr("bob");
        bond.mint(bob, 500);
        vm.startPrank(bob);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        credit.borrow(_maxBorrow(BONDS, _crashedNav()));
        vm.stopPrank();
        oracle.setNav(_crashedNav() / 4); // and then it quarters, to 10,000 bps
        vm.prank(keeper);
        credit.liquidate(bob);
        uint256 second = auction.auctionOf(bob);
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(second);

        assertEq(auction.openWorkoutCount(), 2);

        // Close the first, which is the swap-and-pop case that moves the last entry.
        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(first);
        assertEq(auction.openWorkoutCount(), 1);
        assertEq(auction.openWorkoutAt(0), second, "the survivor is still findable");

        auction.closeWorkout(second);
        assertEq(auction.openWorkoutCount(), 0);
    }

    // ── audit round 5 regressions ────────────────────────────────────────────

    /// @notice A fresh loan taken during the workout window is not forgiven by the
    ///         forced close.
    /// @dev The write-off used to be sized from live account debt, so a defaulter could
    ///      deposit fresh collateral, borrow against it, have the forced close erase
    ///      both loans, and then withdraw the collateral - `withdrawBonds` skips its LTV
    ///      branch at zero debt.
    function test_closeWorkout_doesNotForgiveALoanTakenDuringTheWindow() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        uint256 defaulted = credit.debtOf(alice);

        // Borrowing during the window is refused outright. Bounding the write-off was
        // not enough on its own: `repayFor` is permissionless and never touches
        // `w.recovered`, so a third party clearing the defaulted debt would leave the
        // bound comparing against a live balance that is entirely a fresh loan - and
        // `_distribute` repays live debt before taking any penalty, so a fresh loan also
        // absorbs the surplus the penalty comes out of. One guard closes both.
        oracle.setNav(NAV);
        vm.startPrank(alice);
        vault.depositBonds(500);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.WorkoutOpen.selector, alice));
        credit.borrow(500e6);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), defaulted, "no fresh debt to forgive");

        skip(Config.WORKOUT_MAX_DURATION);

        // The old assertion was `unsocialisedLoss == defaulted`, labelled "lenders eat the default
        // and nothing more". The bound is what this test is about and it is asserted just as
        // tightly - the write-off is exactly the debt that stood at expiry, not a wei of anything
        // borrowed since. Round 11 corrected who eats it: the treasury float funded this loan and
        // there is no lender pool here, so the loss is borne by the source rather than banked as a
        // claim on lenders who funded none of it. Asserting the emitted amount keeps the "and
        // nothing more" half honest, which is the half the round-5 regression was about.
        vm.expectEmit(true, false, false, true, address(credit));
        emit CreditManager.LossBorneByTheSource(address(liquidity), defaulted);

        auction.closeWorkout(id);

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.unsocialisedLoss(), 0, "and nothing banked against a pool that lent none of it");

        // And borrowing works again once the workout is resolved.
        vm.prank(alice);
        credit.borrow(100e6);
        assertEq(credit.debtOf(alice), 100e6);
    }

    /// @notice The penalty survives the borrower paying the debt down first.
    /// @dev `repay` is permissionless and never pausable by design, so a penalty sized
    ///      from live debt at settlement time could be zeroed by the borrower for the
    ///      cost of gas - taking the liquidation caller's reward and the insurance
    ///      fund's share with it. The base is now fixed at expiry.
    function test_workoutSettle_penaltyIsFixedAtExpiryNotAtSettlement() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        // Borrower front-runs the relay and clears the debt themselves.
        usdc.mint(alice, _maxBorrowAtCeiling());
        vm.startPrank(alice);
        usdc.approve(address(credit), _maxBorrowAtCeiling());
        credit.repay(_maxBorrowAtCeiling());
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 0);

        address operator = makeAddr("operator");
        usdc.mint(operator, 1_350e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 1_350e6);
        auction.workoutSettle(id, 1_350e6);
        vm.stopPrank();

        uint256 penalty = (_maxBorrowAtCeiling() * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(auction.rewardOf(keeper), penalty / 2, "the caller still earns their share");
        assertEq(credit.insuranceFund(), penalty - penalty / 2, "and insurance still gets its own");
    }

    /// @dev Tranching must not shrink the total penalty either - the unpaid balance
    ///      carries across calls rather than being recomputed from a shrinking debt.
    function test_workoutSettle_tranchingCollectsTheSamePenaltyAsOneTranche() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        address operator = makeAddr("operator");
        usdc.mint(operator, 1_350e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 1_350e6);
        auction.workoutSettle(id, _maxBorrowAtCeiling()); // clears the debt exactly, no surplus
        auction.workoutSettle(id, 1_350e6 - _maxBorrowAtCeiling()); // the surplus tranche
        vm.stopPrank();

        uint256 penalty = (_maxBorrowAtCeiling() * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(auction.rewardOf(keeper) + credit.insuranceFund(), penalty, "split, not skipped");
    }

    /// @notice The workout lot can leave. Without this the collateral was locked
    ///         forever, even on a workout that closed cleanly with the debt repaid.
    function test_disposeWorkoutLot_releasesTheLotAndReconcilesCustody() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(id);

        address redeemer = makeAddr("redeemer");
        bond.setWhitelisted(redeemer, true);
        vm.prank(admin);
        auction.disposeWorkoutLot(id, redeemer);

        assertEq(bond.bondBalance(redeemer), BONDS, "the units actually moved");
        assertEq(vault.bondCount(address(auction)), 0);
        assertEq(vault.totalBondCount(), 0, "and the dead lot left the accrual denominator");
        assertEq(farm.staked(address(adapter)), 0, "custody is reconciled");
        assertTrue(vault.custodyIsSolvent());
    }

    function test_disposeWorkoutLot_onlyOwnerAndOnlyOnceClosed() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.WorkoutNotClosed.selector, id));
        auction.disposeWorkoutLot(id, bidder);

        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(id);

        vm.expectRevert();
        auction.disposeWorkoutLot(id, bidder); // not the owner

        bond.setWhitelisted(bidder, true);
        vm.startPrank(admin);
        auction.disposeWorkoutLot(id, bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NothingToDispose.selector, id));
        auction.disposeWorkoutLot(id, bidder); // and not twice
        vm.stopPrank();
    }

    /// @notice A repoint that would strand work in flight is refused on both sides.
    /// @dev The outgoing auction is the only caller `seize` and `reassign` accept, so
    ///      repointing over a live auction made `bid` and `expireToWorkout` revert
    ///      `NotLiquidationAuction` while `cancel` refuses precisely because the
    ///      position is underwater - all three exits closed at once, with collateral
    ///      inside. Both setters are asserted together because guarding only one leaves
    ///      the pair able to disagree, which produces the same dead state.
    /// @notice An auction pointer that cannot answer must not weld both setters shut forever.
    /// @dev **Audit round 19.** Every wiring probe in this protocol enumerates the *incoming*
    ///      address's selectors; the two live-work reads are on the *outgoing* one and were bare.
    ///      The vault's incoming probe checks `vault()` and nothing else, so a stub answering only
    ///      that installs cleanly - and from that moment `setLiquidationAuction` reverted forever
    ///      on both contracts, and with it `vault.setCreditManager`, which is the escape from every
    ///      other unrecoverable state in that contract. Owner error rather than an attack, but the
    ///      state was permanent on an immutable contract holding third-party collateral.
    ///
    ///      The guard is not loosened for a real auction: this only decides what an address that
    ///      cannot answer means, and a real `LiquidationAuction` answers both from plain storage.
    ///      The test below still proves the refusal over genuine live work.
    function test_setLiquidationAuction_aPointerThatCannotAnswerIsNotAWeld() public {
        // A stub with the one selector the incoming probes demand, and nothing else.
        StubAuction stub = new StubAuction(address(vault));
        LiquidationAuction next = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        vm.startPrank(admin);
        vault.setLiquidationAuction(address(stub));
        assertEq(vault.liquidationAuction(), address(stub), "premise: the stub really does install");

        // Before the fix both of these reverted on the stub's missing `liveAuctionCount`, with no
        // owner call able to repair it.
        vault.setLiquidationAuction(address(next));
        assertEq(vault.liquidationAuction(), address(next), "the repoint is reachable again");

        // And the escape hatch the vault depends on most is open too.
        vault.setCreditManager(address(credit));
        vm.stopPrank();
    }

    function test_setLiquidationAuction_refusesWhileWorkIsInFlight() public {
        LiquidationAuction next = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        _openAuctionAt(_softNav());
        assertEq(auction.liveAuctionCount(), 1);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, uint256(1)));
        vault.setLiquidationAuction(address(next));
        vm.expectRevert(abi.encodeWithSelector(CreditManager.AuctionHasLiveWork.selector, uint256(1)));
        credit.setLiquidationAuction(address(next));
        vm.stopPrank();

        // An open workout blocks it too, and both clear once the work is resolved.
        skip(Config.AUCTION_DURATION);
        uint256 id = auction.auctionOf(alice);
        auction.expireToWorkout(id);
        assertEq(auction.liveAuctionCount(), 0);
        assertEq(auction.openWorkoutCount(), 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, uint256(1)));
        vault.setLiquidationAuction(address(next));

        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(id);

        // **Closing the workout is not the same as returning the collateral**, and this
        // test used to assert the repoint succeeded here - locking in the strand it was
        // written to prevent. `closeWorkout` pops the queue, so both counters read zero,
        // but the lot stays parked under the auction's ledger entry and only
        // `disposeWorkoutLot` can move it. Repointing first leaves it unreachable by
        // every contract: `disposeTo` refuses the retired auction, the incoming one has
        // no entry to dispose from, and `seize`/`reassign` refuse a debt-free holder.
        assertEq(auction.openWorkoutCount(), 0, "the queue really is empty");
        uint256 lot = vault.bondCount(address(auction));
        assertEq(lot, 100, "but the collateral is still here");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, lot));
        vault.setLiquidationAuction(address(next));

        // And the escape hatch opens: disposal is what actually ends the auction's
        // claim on the vault, so the guard cannot pin a migration shut.
        address redeemer = makeAddr("redeemer");
        bond.setWhitelisted(redeemer, true);
        vm.prank(admin);
        auction.disposeWorkoutLot(id, redeemer);
        assertEq(vault.bondCount(address(auction)), 0, "the lot is released");

        vm.startPrank(admin);
        vault.setLiquidationAuction(address(next));
        credit.setLiquidationAuction(address(next));
        vm.stopPrank();
        assertEq(vault.liquidationAuction(), address(next));
    }

    /// @notice The third leg of the wiring triangle is guarded too.
    /// @dev `cancel` prices a position off the auction's manager pointer while
    ///      `expireToWorkout` prices it off the vault's. The three-exit completeness
    ///      argument rests on those predicates being exact complements, which holds only
    ///      while both pointers name the same manager.
    function test_setCreditManager_refusesWhileWorkIsInFlight() public {
        CreditManager next = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        _openAuctionAt(_softNav());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionHasLiveWork.selector, uint256(1)));
        auction.setCreditManager(address(next));

        // And it refuses a manager bound to a different vault, the way its siblings do.
        oracle.setNav(NAV);
        auction.cancel(auction.auctionOf(alice));
        CollateralVault otherVault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        CreditManager foreign = new CreditManager(
            usdc,
            ICollateralVault(address(otherVault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationAuction.CreditManagerVaultMismatch.selector, address(otherVault))
        );
        auction.setCreditManager(address(foreign));
    }

    /// @notice The vault's manager pointer cannot move out from under a live auction.
    /// @dev **Round 7's critical, and the one the round-6b guard made worse.**
    ///      `expireToWorkout` takes its authorisation from the vault's manager (through
    ///      `reassign`'s `_requireLiquidatable`) and its `debtAtExpiry` from the
    ///      auction's. `_bid` splits the same way. While the two agree that is
    ///      harmless; the vault's setter was the one leg with no live-work guard, so
    ///      they could be pulled apart - and then pinned apart, because the auction's
    ///      own setter refuses to follow while it has live work.
    ///
    ///      Reachable without anyone misbehaving: `repayFor` is permissionless and
    ///      `cancel` is optional and unrewarded, so `totalDebt` reaches zero - the old
    ///      sole precondition - with an auction ticket still ticking. A third party
    ///      could therefore arrange for an ordinary migration to open the hole.
    function test_setCreditManager_refusedWhileAnAuctionIsLive() public {
        CreditManager next = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        _openAuctionAt(_softNav());
        assertEq(auction.liveAuctionCount(), 1);

        // Anyone can clear the debt, which used to be the only thing checked.
        uint256 owed = credit.currentDebtOf(alice);
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, owed);
        vm.startPrank(stranger);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();
        assertEq(credit.totalDebt(), 0, "the old precondition is satisfied");
        assertEq(auction.liveAuctionCount(), 1, "while the auction is still live");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, uint256(1)));
        vault.setCreditManager(address(next));

        // The hatch opens the moment the auction is resolved - here by the cancel the
        // healed position now qualifies for.
        auction.cancel(auction.auctionOf(alice));
        vm.prank(admin);
        vault.setCreditManager(address(next));
        assertEq(vault.creditManager(), address(next));
    }

    /// @notice And the auction may only ever name the manager the vault actually uses.
    /// @dev Sharing a vault is not the same as being that vault's manager - several
    ///      managers can name one immutable vault, so the round-6b `vault()` check
    ///      admitted a manager this vault had never used. This is the check
    ///      `EpochHarvester.setCreditManager` has had since round 6.
    function test_setCreditManager_refusesAManagerTheVaultDoesNotUse() public {
        CreditManager sibling = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        // Same vault, so the round-6b check passes - but the vault does not use it.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationAuction.CreditManagerNotLive.selector, address(credit))
        );
        auction.setCreditManager(address(sibling));

        // Point the vault at it first and the same call is accepted, so a real
        // migration still completes - vault first, then auction.
        vm.startPrank(admin);
        vault.setCreditManager(address(sibling));
        auction.setCreditManager(address(sibling));
        vm.stopPrank();
        assertEq(auction.creditManager(), address(sibling));
    }

    /// @notice A lapsed auction stops quoting a price nobody can fill.
    function test_currentPrice_refusesOnceLapsed() public {
        uint256 id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION + 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, id));
        auction.currentPrice(id);
    }

    /// @notice Every trapped pot survives a manager migration, not just insurance.
    /// @dev Round 6b made `insuranceFund` movable and left `undistributedYield` behind.
    ///      That pot is decremented only by `_accrue()`, whose three callers are
    ///      `_settle` (returns early once detached), `accrueYield` and `distributeYield`
    ///      (both `whileAttached`) - so a detached manager has no writer, no reader and
    ///      no sweep for it, and `harvest` is permissionless, so a stranger could time
    ///      an epoch to maximise what a migration destroyed.
    function test_migrateReserves_movesEveryTrappedPotToTheLiveManager() public {
        usdc.mint(address(this), 5_000e6);
        usdc.approve(address(credit), 5_000e6);
        credit.fundInsurance(5_000e6);

        // An epoch mid-stream: the pot round 6b left behind.
        usdc.mint(harvester, 1_000e6);
        vm.startPrank(harvester);
        usdc.approve(address(credit), 1_000e6);
        credit.receiveYield(1_000e6);
        credit.distributeYield(0);
        vm.stopPrank();
        assertGt(credit.undistributedYield(), 0, "an epoch is in flight");

        CreditManager next = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );

        // Refused while still attached: this is a migration path, not a withdrawal.
        vm.prank(admin);
        vm.expectRevert(CreditManager.StillAttached.selector);
        credit.migrateReserves();

        uint256 trapped = usdc.balanceOf(address(credit)) - credit.totalClaimable() - credit.pendingPrincipal();

        vm.prank(admin);
        vault.setCreditManager(address(next));

        vm.prank(admin);
        credit.migrateReserves();

        assertEq(credit.insuranceFund(), 0, "insurance left");
        assertEq(credit.undistributedYield(), 0, "and so did the epoch");
        assertEq(next.insuranceFund(), trapped, "both pots followed the vault");
        assertEq(usdc.balanceOf(address(next)), trapped, "and are actually backed");
        assertEq(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.pendingPrincipal(),
            "only individually-payable claims stay behind"
        );
    }

    /// @notice An unclaimed liquidation bounty is not a trapped pot. It has a name on it.
    /// @dev The same defect as round 6b's, one pot along, and the one place this mechanism
    ///      could lose money outright: `migrateReserves` sends everything not in `spokenFor`
    ///      to the incoming manager **as insurance**, so a bounty left out of that sum would
    ///      be converted into a general reserve and the keeper who earned it would never be
    ///      paid. The invariant suite cannot catch it either, because this function is
    ///      `onlyOwner` and only callable once detached.
    ///
    ///      Only `totalBountyOwed` can be non-zero here, and that is worth stating rather than
    ///      leaving as an accident of the fixture: detaching requires `totalDebt == 0`, and
    ///      every route a debt has to zero already refunds the escrow, so `totalBountyEscrowed`
    ///      is provably zero at this point. Since round eighteen `totalBountyParked` has to be
    ///      zero too, and it is by the same argument - a park only exists while an auction is
    ///      live, and a live auction means live debt.
    function test_migrateReserves_leavesAnEarnedBountyWithTheCallerWhoEarnedIt() public {
        uint256 id = _openAuction();
        assertEq(credit.bountyOwedTo(keeper), 0, "opening it earns nothing on its own");
        assertEq(credit.totalBountyParked(), Config.LIQUIDATION_CALL_BOUNTY, "it is parked");

        skip(Config.AUCTION_DURATION);
        _fundBidder(bidder, auction.currentPrice(id));
        vm.prank(bidder);
        auction.bid(id); // resolves the position, so the manager can be detached

        assertEq(credit.totalDebt(), 0);
        assertEq(credit.totalBountyEscrowed(), 0, "spent by the liquidation, not still held");
        assertEq(credit.totalBountyParked(), 0, "and the park emptied when the fill resolved it");
        assertEq(credit.totalBountyOwed(), Config.LIQUIDATION_CALL_BOUNTY, "and owed to the keeper");

        CreditManager next = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        vm.prank(admin);
        vault.setCreditManager(address(next));

        // With the bounty the only thing left, there is nothing free to migrate at all: the
        // whole balance is spoken for. Before this change the same call would have found
        // exactly the bounty unaccounted for and sent it on as insurance.
        vm.prank(admin);
        vm.expectRevert(CreditManager.ZeroAmount.selector);
        credit.migrateReserves();

        // Give it something that genuinely is unspoken for, and only that moves.
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(credit), 1_000e6);
        credit.fundInsurance(1_000e6);

        vm.prank(admin);
        credit.migrateReserves();

        assertEq(next.insuranceFund(), 1_000e6, "the insurance moved and nothing else went with it");
        assertEq(
            credit.totalBountyOwed(),
            Config.LIQUIDATION_CALL_BOUNTY,
            "the migration did not convert the bounty into the incoming manager's insurance"
        );

        vm.prank(keeper);
        credit.claimBounty();
        assertEq(
            usdc.balanceOf(keeper),
            Config.LIQUIDATION_CALL_BOUNTY,
            "and it is still actually backed by USDC left behind"
        );
    }

    /// @notice A manager that has already been live can never be attached again.
    /// @dev `whileAttached` stops a detached manager pricing positions, but `_settle`
    ///      skips the index stamp while detached, so a position that moved during the
    ///      gap carries a zero index against a frozen accumulator. Re-attaching lets it
    ///      claim the whole accumulator - the drain `whileAttached` says it closes,
    ///      reached from the other side. It is also what made the reserve sweep unsafe.
    function test_setCreditManager_refusesAManagerThatHasAlreadyBeenLive() public {
        // Give the incumbent a non-zero accumulator.
        usdc.mint(harvester, 1_000e6);
        vm.startPrank(harvester);
        usdc.approve(address(credit), 1_000e6);
        credit.receiveYield(1_000e6);
        credit.distributeYield(0);
        vm.stopPrank();
        skip(5 days);
        credit.accrueYield();
        assertGt(credit.accYieldPerBond(), 0, "the incumbent has history");

        CreditManager next = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        vm.prank(admin);
        vault.setCreditManager(address(next));

        // Rolling back is refused, which is what makes detachment one-way.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.CreditManagerNotVirgin.selector, address(credit))
        );
        vault.setCreditManager(address(credit));
    }

    // ── wiring ───────────────────────────────────────────────────────────────

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(admin);
        vm.expectRevert(LiquidationAuction.RenounceDisabled.selector);
        auction.renounceOwnership();
    }

    /// @notice `claimSurplus`'s `_refundBounty` is a live path, not a spare.
    /// @dev **The comment on that line used to say "unreachable today" and audit round 21
    ///      measured the route.** The argument it made was that every route a debt has to zero
    ///      already refunds - `_repay` at the end, `_settle` in the branch where yield clears the
    ///      last of the debt - so a borrower can never be sitting on an escrow with no debt. It
    ///      is wrong in one direction: all of those hooks key on a debt *reduction*, and
    ///      `resolveBounty(id, false)` writes the escrow with no debt reduction anywhere near it.
    ///
    ///      A stranger cures a liquidated position with the permissionless `repayFor` - the
    ///      escrow is already parked against the auction, so `_repay`'s refund is a no-op - and
    ///      then `cancel` returns the park to a borrower whose `debtOf` is already zero.
    ///      `settle` cannot reach it and `repay` reverts `NoDebt`. This line is the only door
    ///      left. It is also the one exit deliberately kept open through a migration, which is
    ///      why it matters that it is real.
    ///
    ///      Written as a test because the state is reachable, which is the thing the old comment
    ///      denied. It said a test "would have to fake it"; nothing here is faked.
    function test_claimSurplusRefundsAnEscrowNoOtherHookCanReach() public {
        uint256 id = _openAuction();
        assertEq(credit.bountyEscrowOf(alice), 0, "premise: parked against the auction");
        assertEq(credit.totalBountyParked(), Config.LIQUIDATION_CALL_BOUNTY, "premise: and it is parked");

        address rescuer = makeAddr("rescuer");
        uint256 debt = credit.currentDebtOf(alice);
        usdc.mint(rescuer, debt);
        vm.startPrank(rescuer);
        usdc.approve(address(credit), debt);
        credit.repayFor(alice, debt);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 0, "premise: debt-free");
        assertEq(credit.bountyEscrowOf(alice), 0, "premise: and _repay's refund had nothing to do");

        auction.cancel(id);
        assertEq(
            credit.bountyEscrowOf(alice),
            Config.LIQUIDATION_CALL_BOUNTY,
            "resolveBounty(false) did not credit a debt-free borrower"
        );

        credit.settle(alice);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "settle refunded after all");
        vm.prank(alice);
        vm.expectRevert(CreditManager.NoDebt.selector);
        credit.repay(1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.claimSurplus();
        assertEq(credit.bountyEscrowOf(alice), 0, "claimSurplus's _refundBounty did not run");
        assertGe(usdc.balanceOf(alice) - before, Config.LIQUIDATION_CALL_BOUNTY, "and it did not pay");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 22, finding 16. The pinned bid bounds the LOT and not the PRICE.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Run an auction to its floor, take the quote a keeper would sign for, then let anybody
    ///      re-strike it. The re-strike resets the premium from the floor back to 100% of NAV on the
    ///      same id, so the price a `bid` pays goes UP without the lot changing hands.
    function _quoteThenRestrike() private returns (uint256 id, uint256 quoted) {
        id = _openAuctionAt(_softNav());
        skip(Config.AUCTION_DURATION);
        quoted = auction.currentPrice(id); // the last quotable instant, at the floor

        // One second past the window, so the auction has lapsed and `start` re-strikes in place.
        // Permissionless: `liquidate` is, and the position is still underwater.
        skip(1);
        vm.prank(makeAddr("griefer"));
        credit.liquidate(alice);
        assertEq(auction.auctionOf(alice), id, "fixture: the re-strike minted a new id instead");
    }

    /// @notice **The hazard.** The single-argument pin fires on a lot change and misses the change
    ///         that raises the price per bond.
    /// @dev MEASURED: quoted 641.325000, the same `bid(id)` paid 943.125000 - +301.800000, a rise of
    ///      4,705.9 bps - and `claimableOf[borrower]` went 0 -> 282.937500, so the borrower whose
    ///      position it is collects the difference. `start` states the invariant this breaks in its
    ///      own comment: "A Dutch price must only ever fall."
    ///
    ///      This test asserts the behaviour rather than a fix, because the re-strike itself is
    ///      wanted - round 19 built it deliberately, and blocking it turns a stale ticket into a
    ///      perpetual call option. What was missing is a door that bounds both quantities at once;
    ///      the tests below are that door.
    function test_R22_thePinnedBidStillPaysTheRestruckPrice() public {
        (uint256 id, uint256 quoted) = _quoteThenRestrike();

        _fundBidder(bidder, 10_000e6);
        uint256 spentBefore = usdc.balanceOf(bidder);
        vm.prank(bidder);
        auction.bid(id);
        uint256 paid = spentBefore - usdc.balanceOf(bidder);

        emit log_named_uint("MEASURED quoted before the re-strike", quoted);
        emit log_named_uint("MEASURED paid by the same pinned bid", paid);
        assertGt(paid, quoted, "the pin would have to be catching this for the finding to be wrong");
        assertGt(credit.claimableOf(alice), 0, "and the borrower collects the difference");
    }

    /// @notice **The fix: the door that offers both bounds.** It refuses the re-struck price.
    /// @dev CONTROL B, asserted in the same breath: the two-argument overload already refuses on
    ///      price, so a price bound on the pinned form alone would have been inert. The gap was
    ///      never either bound on its own - it was that no single call offered both, so a keeper had
    ///      to choose which of the two griefs to be exposed to.
    function test_R22_theBothBoundsDoorRefusesARestruckPrice() public {
        (uint256 id, uint256 quoted) = _quoteThenRestrike();
        uint256 live = auction.currentPrice(id);
        uint256 lot = vault.bondCount(alice);
        _fundBidder(bidder, 10_000e6);

        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.PriceAboveCap.selector, live, quoted));
        auction.bid(id, lot, quoted);

        // CONTROL B: the price-only overload already did this half.
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.PriceAboveCap.selector, live, quoted));
        auction.bid(id, quoted);
    }

    /// @notice And it refuses a lot change, which the price-only overload does not.
    /// @dev CONTROL C: the pin is not inert - a top-up genuinely moves the lot - and CONTROL D, the
    ///      other arm of the same call: with both bounds satisfied the fill goes through at the
    ///      quoted price, so the door is not simply refusing everything.
    function test_R22_theBothBoundsDoorRefusesALotChangeAndFillsWhenNeither() public {
        uint256 id = _openAuction();
        uint256 lot = vault.bondCount(alice);
        uint256 quoted = auction.currentPrice(id);
        _fundBidder(bidder, 10_000e6);

        // The borrower tops up: the lot moves, the price per bond does not.
        bond.mint(alice, 1);
        vm.prank(alice);
        vault.depositBonds(1);
        assertEq(vault.bondCount(alice), lot + 1, "fixture: the top-up did not land");

        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.LotChanged.selector, lot, lot + 1));
        auction.bid(id, lot, type(uint256).max);

        // CONTROL C: the price-only overload accepts exactly this, which is why the lot bound is
        // the half it is missing.
        uint256 livePrice = auction.currentPrice(id);
        uint256 spentBefore = usdc.balanceOf(bidder);
        vm.prank(bidder);
        auction.bid(id, lot + 1, livePrice);
        assertEq(spentBefore - usdc.balanceOf(bidder), livePrice, "the fill did not go through at the quote");
        assertGt(quoted, 0, "fixture: nothing was quoted");
    }

    /// @notice A zero expectation is refused rather than read as "whatever the lot is".
    /// @dev A silent zero is the shape `currentPrice` refuses for the same reason: a keeper must not
    ///      be able to act on one. Nothing else in this contract treats zero as a wildcard.
    function test_R22_theBothBoundsDoorRefusesAZeroLotExpectation() public {
        uint256 id = _openAuction();
        _fundBidder(bidder, 10_000e6);
        vm.prank(bidder);
        vm.expectRevert(LiquidationAuction.ZeroAmount.selector);
        auction.bid(id, 0, type(uint256).max);
    }
}

/// @notice An address that satisfies every *incoming* wiring probe and answers nothing else.
/// @dev Deliberately minimal, because the finding is about what the probes do not ask. `vault()` is
///      the whole of `CollateralVault.setLiquidationAuction`'s incoming check, so this installs -
///      and before audit round 19's fix, the two live-work reads on the outgoing pointer then made
///      both of that contract's pointer setters revert for good. It must stay this bare: adding
///      `liveAuctionCount` here would make the test pass against the defect it exists to catch.
contract StubAuction {
    address public immutable vault;
    /// @dev **Audit round 20 gave this contract a second incoming check, and it goes here rather
    ///      than being left out.** With the risk pointer unanswered the stub no longer installs at
    ///      all, and the round-19 defect this stub exists to catch - a pointer that installs and
    ///      then welds both setters shut - would become unreachable, which reads as the test
    ///      passing when it is really no longer looking. Taken from the vault so it agrees by
    ///      construction. `liveAuctionCount` still must not appear here: that is the selector the
    ///      finding is about.
    address public immutable riskParams;
    /// @dev **Audit round 21 added a fifth incoming check**, the sibling of the risk one above.
    ///      Agreed on purpose, for exactly the same reason: the probe under test has to be the one
    ///      that fires. Taken from the vault so it is right by construction.
    address public immutable navOracle;

    constructor(address vault_) {
        vault = vault_;
        riskParams = address(ICollateralVault(vault_).riskParams());
        navOracle = address(ICollateralVault(vault_).navOracle());
    }
}
