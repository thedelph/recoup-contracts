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

/// @notice Dutch auction lifecycle against the real-ABI mocks (PRD §4.5, §6.3).
///
///         Fixture uses the real 2026-07-24 NAV snapshot, so 100 bonds is $2,515 of
///         collateral and 35% of that is 880.25 USDC of borrowing power. Positions are
///         put underwater by crashing NAV rather than by writing debt directly, which
///         is the only way it can actually happen on chain.
contract LiquidationAuctionTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant CRASHED_NAV = 10e8; // 100 bonds ⇒ exactly $1,000
    uint256 internal constant SOFT_NAV = 15e8; // liquidatable at 5,868 bps, still solvent
    uint256 internal constant BONDS = 100;
    uint256 internal constant MAX_BORROW = 880.25e6;
    uint256 internal constant FLOAT = 100_000e6;

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

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        auction = new LiquidationAuction(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
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
    ///      the liquidation threshold. At $10.00 a bond, 880.25 of debt against $1,000
    ///      of collateral is 8,802 bps - comfortably over 5,800.
    function _openAuction() internal returns (uint256 id) {
        return _openAuctionAt(CRASHED_NAV);
    }

    /// @dev `SOFT_NAV` ($15.00) is the interesting case: past the 5,800 bps threshold
    ///      at 5,868 bps, but still worth more than the debt, so a mid-auction fill
    ///      leaves a surplus. `CRASHED_NAV` ($10.00) is the other side - even a
    ///      100%-of-NAV fill cannot cover the loan.
    function _openAuctionAt(uint256 nav) internal returns (uint256 id) {
        vm.prank(alice);
        credit.borrow(MAX_BORROW);
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
        assertEq(startNav, CRASHED_NAV);
        assertEq(debt, MAX_BORROW);
        assertEq(startPrice, _lotPrice(BONDS, CRASHED_NAV, Config.AUCTION_START_PREMIUM_BPS));
        assertEq(startPrice, 1_000e6, "100 bonds at $10.00 is $1,000 at 100% of NAV");
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
        vm.prank(alice);
        credit.borrow(MAX_BORROW);
        oracle.setNav(CRASHED_NAV);

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
        assertEq(auction.currentPrice(id), 1_000e6);
    }

    function test_currentPrice_decaysLinearlyAtHalfDuration() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION / 2);

        uint256 expected = Config.AUCTION_START_PREMIUM_BPS
            - (Config.AUCTION_START_PREMIUM_BPS - Config.AUCTION_FLOOR_BPS) / 2;
        assertEq(auction.currentPremiumBps(id), expected);
        assertEq(auction.currentPrice(id), _lotPrice(BONDS, CRASHED_NAV, expected));
    }

    function test_currentPrice_reachesTheFloorExactlyAtDurationAndStaysThere() public {
        uint256 id = _openAuction();
        skip(Config.AUCTION_DURATION);
        assertEq(auction.currentPremiumBps(id), Config.AUCTION_FLOOR_BPS);
        assertEq(auction.currentPrice(id), 680e6, "68% of $1,000");

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

    function testFuzz_currentPriceIsMonotonicallyNonIncreasing(uint32 firstStep, uint32 secondStep) public {
        // Both steps stay inside the window: past it the auction lapses and
        // `currentPrice` refuses rather than quoting a price no bid can fill.
        uint256 id = _openAuction();
        skip(bound(firstStep, 0, Config.AUCTION_DURATION / 2));
        uint256 earlier = auction.currentPrice(id);
        skip(bound(secondStep, 0, Config.AUCTION_DURATION / 2));
        assertLe(auction.currentPrice(id), earlier, "a Dutch price must only ever fall");
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

        oracle.setNav(CRASHED_NAV * 3);
        assertEq(auction.currentPrice(id), priced, "a recovery must not reprice a live auction upward");

        oracle.setNav(CRASHED_NAV / 4);
        assertEq(auction.currentPrice(id), priced, "and a further crash must not reprice it downward");
    }

    /// @dev Staleness pauses borrowing, never liquidation (PRD §4.6). The auction is
    ///      independent of the feed once open, so this is free - but it must be pinned,
    ///      because "gate the auction on staleness" is a plausible-looking change.
    function test_currentPrice_worksWithAStaleFeed() public {
        uint256 id = _openAuction();
        oracle.setStale(true);
        assertEq(auction.currentPrice(id), 1_000e6);
    }

    function test_currentPrice_pricesTheLiveLotSoATopUpIsNotSoldForNothing() public {
        uint256 id = _openAuction();
        vm.prank(alice);
        vault.depositBonds(50);
        assertEq(auction.currentPrice(id), 1_500e6, "150 bonds at $10.00");
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
        usdc.mint(friend, MAX_BORROW);
        vm.startPrank(friend);
        usdc.approve(address(credit), MAX_BORROW);
        credit.repayFor(alice, MAX_BORROW);
        vm.stopPrank();

        auction.cancel(id);
        assertFalse(auction.isLiquidating(alice));
    }

    function test_cancel_revertsWhileStillLiquidatable() public {
        uint256 id = _openAuction();
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.StillLiquidatable.selector, uint256(8_802)));
        auction.cancel(id);
    }

    /// @notice The guard and every clearer it depends on, composed. A one-auction rule
    ///         whose clearers are asserted separately passes forever even if no clearer
    ///         actually works, leaving the borrower permanently un-reliquidatable.
    function test_reliquidationBecomesPossibleAgainAfterACancel() public {
        uint256 first = _openAuction();
        oracle.setNav(NAV);
        auction.cancel(first);

        oracle.setNav(CRASHED_NAV);
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
        uint256 id = _openAuctionAt(SOFT_NAV);
        skip(_elapsedForPremium(8_200));
        assertEq(auction.currentPremiumBps(id), 8_200);

        uint256 price = auction.currentPrice(id);
        assertEq(price, 1_230e6, "100 bonds at $15.00, 82% of NAV");

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
        assertEq(credit.pendingPrincipal(), MAX_BORROW);

        // Penalty is 500 bps of the debt, split down the middle.
        uint256 penalty = (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(penalty, 44.0125e6);
        assertEq(auction.rewardOf(keeper), penalty / 2, "the trigger, not the bidder");
        assertEq(credit.insuranceFund(), penalty - penalty / 2);

        // And the borrower keeps what is left, claimable rather than pushed.
        assertEq(credit.claimableOf(alice), price - MAX_BORROW - penalty);
        assertEq(credit.claimableOf(alice), 305.7375e6);

        // Every wei accounted for, and the auction keeps only the unclaimed reward.
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());
        assertEq(auction.totalUnclaimedRewards(), penalty / 2);

        // Principal finds its way home through the existing permissionless path.
        credit.settlePrincipal();
        assertEq(usdc.balanceOf(address(liquidity)), floatBefore + MAX_BORROW);

        vm.prank(alice);
        credit.claimSurplus();
        assertEq(usdc.balanceOf(alice), MAX_BORROW + 305.7375e6, "the loan plus the surplus");

        vm.prank(keeper);
        auction.claimReward();
        assertEq(usdc.balanceOf(keeper), penalty / 2);
        assertEq(usdc.balanceOf(address(auction)), 0, "nothing left at rest");
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
        assertEq(price, 680e6, "68% of $1,000");
        assertLt(price, MAX_BORROW, "the whole point: the lot is worth less than the loan");

        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        uint256 shortfall = MAX_BORROW - price;
        assertEq(credit.debtOf(alice), 0, "the position is resolved either way");
        assertEq(credit.insuranceFund(), 0, "insurance absorbed what it could");
        assertEq(credit.unsocialisedLoss(), shortfall - 100e6, "and the rest is remembered for lenders");
        assertEq(credit.claimableOf(alice), 0, "no surplus, so nothing for the borrower");
        assertEq(auction.rewardOf(keeper), 0, "and no penalty to pay the caller from");
        assertEq(bond.bondBalance(bidder), BONDS);
    }

    /// @dev Near the floor `price < debt + penalty` is routine, not exotic. An unclamped
    ///      subtraction would panic in exactly the band where Dutch auctions fill.
    function test_bid_clampsThePenaltyToTheSurplusThatExists() public {
        // $13.00 a bond puts the *floor* price only just above the debt: less than a
        // full penalty of surplus, but more than none. The decay curve cannot reach
        // that band at a higher NAV, because it stops at the floor by design.
        uint256 id = _openAuctionAt(13e8);
        skip(Config.AUCTION_DURATION);
        uint256 price = auction.currentPrice(id);
        assertGt(price, MAX_BORROW);
        uint256 surplus = price - MAX_BORROW;
        assertLt(surplus, (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS, "a partial penalty");

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
        uint256 id = _openAuctionAt(SOFT_NAV);
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
        uint256 id = _openAuctionAt(SOFT_NAV);
        skip(_elapsedForPremium(8_200));
        uint256 price = auction.currentPrice(id);

        _fundBidder(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        uint256 penalty = (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(auction.rewardOf(keeper) + credit.insuranceFund(), penalty, "no wei invented or lost");
        assertGe(credit.insuranceFund(), auction.rewardOf(keeper), "the odd wei goes to the protocol");
    }

    // ── bid: adverse conditions ──────────────────────────────────────────────

    function test_bid_revertsForAWinnerThatCannotReceiveErc1155() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
        RejectingBidder rejecting = new RejectingBidder();
        usdc.mint(address(rejecting), 2_000e6);

        vm.expectRevert();
        rejecting.bid(auction, usdc, id);

        // Nothing moved, and the auction is still live for someone who can take it.
        assertEq(vault.bondCount(alice), BONDS);
        assertTrue(auction.isLiquidating(alice));
    }

    function test_bid_succeedsForAContractWinnerThatCan() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
        ContractBidder accepting = new ContractBidder();
        usdc.mint(address(accepting), 2_000e6);

        accepting.bid(auction, usdc, id);
        assertEq(bond.bondBalance(address(accepting)), BONDS);
    }

    /// @notice The callback is the one moment the auction hands control to arbitrary
    ///         code. Everything the attacker can reach must already be closed, and the
    ///         settlement figures must be read after them, not before.
    function test_bid_isNotReentrableThroughTheWinnersCallback() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
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
        uint256 id = _openAuctionAt(SOFT_NAV);
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
        uint256 id = _openAuctionAt(SOFT_NAV);
        bond.setWhitelisted(address(adapter), false);
        bond.setWhitelisted(bidder, true);

        _fundBidder(bidder, 2_000e6);
        vm.prank(bidder);
        auction.bid(id);
        assertEq(bond.bondBalance(bidder), BONDS);
    }

    function test_bid_revertsAfterTheAuctionIsCancelled() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
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
    function test_bid_lapsesAfterTheWindowAndLiquidateSupersedesIt() public {
        uint256 first = _openAuctionAt(SOFT_NAV);
        skip(Config.AUCTION_DURATION + 5 days);

        _fundBidder(bidder, 5_000e6);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, first));
        auction.bid(first, type(uint256).max);

        // The replacement reprices from scratch at current NAV, which is the thing the
        // stale floor fill was standing in for.
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 second = auction.auctionOf(alice);
        assertEq(second, first + 1);
        assertEq(auction.currentPremiumBps(second), Config.AUCTION_START_PREMIUM_BPS, "priced fresh, not at a floor");

        vm.prank(bidder);
        auction.bid(second);
        assertEq(bond.bondBalance(bidder), BONDS);
    }

    /// @notice The floor is reachable at the last instant of the window, not an
    ///         asymptote - the lapse check is strictly-after for exactly this reason.
    function test_bid_fillsAtExactlyTheFloorOnTheFinalInstant() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
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
        uint256 id = _openAuctionAt(SOFT_NAV);
        vm.prank(alice);
        vault.depositBonds(50); // 150 bonds at $15.00 is 3,912 bps: healthy again

        _fundBidder(bidder, 5_000e6);
        uint256 price = auction.currentPrice(id);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, uint256(3_912)));
        auction.bid(id, price);

        auction.cancel(id);
        assertFalse(auction.isLiquidating(alice));
        assertEq(vault.bondCount(alice), BONDS + 50, "she keeps everything, including the top-up");
    }

    function test_bid_revertsAboveTheCallersCap() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
        uint256 price = auction.currentPrice(id);

        _fundBidder(bidder, 5_000e6);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.PriceAboveCap.selector, price, price - 1));
        auction.bid(id, price - 1);
    }

    function test_bid_pullsExactlyTheCurrentPriceAndNoMore() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
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
        uint256 id = _openAuctionAt(SOFT_NAV);
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

        assertEq(credit.debtOf(alice), MAX_BORROW, "still owed");
        assertEq(credit.unsocialisedLoss(), 0, "and nothing guessed at lenders' expense");
        (,,,, uint256 debtAtExpiry,,) = auction.workouts(id);
        assertEq(debtAtExpiry, MAX_BORROW);
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
        uint256 id = _openAuction();

        // 1. DexFi revokes the adapter's transfer whitelist entry.
        bond.setWhitelisted(address(adapter), false);
        // 2. The farm stops honouring withdrawals.
        farm.setRevertOnWithdraw(true);
        // 3. The borrower is USDC-blacklisted, so nothing can be pushed to them.
        usdc.setBlocked(alice, true);
        // 4. The lender pool refuses every loss.
        MockLenderPool pool = new MockLenderPool();
        vm.prank(admin);
        credit.setLenderPool(address(pool));
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
        auction.closeWorkout(id);
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.unsocialisedLoss(), MAX_BORROW, "remembered, not lost");
        assertEq(auction.openWorkoutCount(), 0);
    }

    function test_workoutSettle_repaysAndPaysTheSameSplitAsAFill() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
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

        uint256 penalty = (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(credit.debtOf(alice), 0);
        assertEq(auction.rewardOf(keeper), penalty / 2, "the same split a fill would have paid");
        assertEq(credit.insuranceFund(), penalty - penalty / 2);
        assertEq(credit.claimableOf(alice), recovery - MAX_BORROW - penalty);
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());
    }

    /// @dev A manual redemption may pay in stages. Writing the gap down on the first
    ///      tranche would socialise a loss the second tranche covers.
    function test_workoutSettle_acceptsPartialTranchesWithoutSocialisingEarly() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        address operator = makeAddr("operator");
        usdc.mint(operator, MAX_BORROW);
        vm.startPrank(operator);
        usdc.approve(address(auction), MAX_BORROW);

        auction.workoutSettle(id, 400e6);
        assertGt(credit.debtOf(alice), 0, "still owed after the first tranche");
        assertEq(credit.unsocialisedLoss(), 0, "and nothing written off prematurely");

        auction.workoutSettle(id, MAX_BORROW - 400e6);
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

        (, uint96 openedAt,,,,,) = auction.workouts(id);
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

        auction.closeWorkout(id); // permissionless

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.insuranceFund(), 0, "insurance absorbed what it could");
        assertEq(credit.unsocialisedLoss(), MAX_BORROW - 300e6, "and the rest is lenders'");
        assertEq(auction.openWorkoutCount(), 0);
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
        credit.borrow(350e6); // exactly max LTV against $1,000 of collateral
        vm.stopPrank();
        oracle.setNav(5e8); // and then it halves again
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
        auction.closeWorkout(id);

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.unsocialisedLoss(), defaulted, "lenders eat the default and nothing more");

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
        uint256 id = _openAuctionAt(SOFT_NAV);
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        // Borrower front-runs the relay and clears the debt themselves.
        usdc.mint(alice, MAX_BORROW);
        vm.startPrank(alice);
        usdc.approve(address(credit), MAX_BORROW);
        credit.repay(MAX_BORROW);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 0);

        address operator = makeAddr("operator");
        usdc.mint(operator, 1_350e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 1_350e6);
        auction.workoutSettle(id, 1_350e6);
        vm.stopPrank();

        uint256 penalty = (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
        assertEq(auction.rewardOf(keeper), penalty / 2, "the caller still earns their share");
        assertEq(credit.insuranceFund(), penalty - penalty / 2, "and insurance still gets its own");
    }

    /// @dev Tranching must not shrink the total penalty either - the unpaid balance
    ///      carries across calls rather than being recomputed from a shrinking debt.
    function test_workoutSettle_tranchingCollectsTheSamePenaltyAsOneTranche() public {
        uint256 id = _openAuctionAt(SOFT_NAV);
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);

        address operator = makeAddr("operator");
        usdc.mint(operator, 1_350e6);
        vm.startPrank(operator);
        usdc.approve(address(auction), 1_350e6);
        auction.workoutSettle(id, MAX_BORROW); // clears the debt exactly, no surplus
        auction.workoutSettle(id, 1_350e6 - MAX_BORROW); // the surplus tranche
        vm.stopPrank();

        uint256 penalty = (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;
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
    function test_setLiquidationAuction_refusesWhileWorkIsInFlight() public {
        LiquidationAuction next =
            new LiquidationAuction(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);

        _openAuctionAt(SOFT_NAV);
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
        CreditManager next =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);

        _openAuctionAt(SOFT_NAV);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionHasLiveWork.selector, uint256(1)));
        auction.setCreditManager(address(next));

        // And it refuses a manager bound to a different vault, the way its siblings do.
        oracle.setNav(NAV);
        auction.cancel(auction.auctionOf(alice));
        CollateralVault otherVault =
            new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        CreditManager foreign =
            new CreditManager(usdc, ICollateralVault(address(otherVault)), INAVOracle(address(oracle)), admin);
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
        CreditManager next =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);

        _openAuctionAt(SOFT_NAV);
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
        CreditManager sibling =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);

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
        uint256 id = _openAuctionAt(SOFT_NAV);
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

        CreditManager next =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);

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

        CreditManager next =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
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
}
