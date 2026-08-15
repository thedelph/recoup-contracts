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
///         collateral. Positions are put underwater by crashing NAV rather than by
///         writing debt directly, which is the only way it can actually happen on chain.
///
///         `MAX_BORROW` is derived from `Config` rather than written down. It used to be
///         the literal 880.25e6, which was 35% of $2,515 - correct until the capped-beta
///         parameters landed on 2026-08-07, at which point 53 of the 61 tests in this
///         file failed at the fixture rather than in the code under test. The ratchet
///         agreed with DexFi moves `MAX_LTV_BPS` at least twice more, so the same break
///         is scheduled to happen again unless the fixture reads the parameter.
contract LiquidationAuctionTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 100_000e6;

    /// @dev Borrowing power at the ceiling: BONDS x NAV x maxLTV, in USDC 6dp.
    uint256 internal constant MAX_BORROW =
        (BONDS * NAV * Config.MAX_LTV_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE);

    /// @dev The NAV at which a position borrowed to the ceiling sits exactly on the
    ///      liquidation threshold. Everything below is liquidatable, everything above is
    ///      not, so the two scenario NAVs are chosen either side of it by construction.
    uint256 internal constant NAV_AT_THRESHOLD =
        (MAX_BORROW * Config.BPS * Config.USDC_TO_NAV_SCALE) / (Config.LIQUIDATION_THRESHOLD_BPS * BONDS);

    /// @dev The NAV at which the whole lot is worth exactly the debt, so a fill at 100%
    ///      of NAV covers the loan and not a cent more.
    uint256 internal constant NAV_AT_DEBT_PARITY = (MAX_BORROW * Config.USDC_TO_NAV_SCALE) / BONDS;

    /// @dev Liquidatable but still solvent: past the threshold, yet worth more than the
    ///      debt, so a mid-auction fill leaves the borrower a surplus. Sits midway
    ///      between the two bounds above so it can never drift to the wrong side of
    ///      either when the parameters move.
    uint256 internal constant SOFT_NAV = (NAV_AT_THRESHOLD + NAV_AT_DEBT_PARITY) / 2;

    /// @dev The other side: even a fill at 100% of NAV cannot cover the loan, so the
    ///      insurance fund and then the lenders take the difference. Half of debt parity
    ///      is comfortably clear of the boundary rather than a cent under it.
    uint256 internal constant CRASHED_NAV = NAV_AT_DEBT_PARITY / 2;

    /// @dev The NAV at which the auction's *floor* price lands half a penalty above the
    ///      debt, i.e. inside the band where a fill leaves some surplus but less than a
    ///      full penalty. Solved from the floor rather than picked, because it depends on
    ///      three parameters at once - the LTV ceiling, the auction floor and the penalty
    ///      - and a hand-picked NAV silently leaves the band when any of them moves.
    uint256 internal constant NAV_FOR_PARTIAL_PENALTY = (
        (MAX_BORROW + (MAX_BORROW * Config.LIQUIDATION_PENALTY_BPS) / (2 * Config.BPS))
            * Config.BPS * Config.USDC_TO_NAV_SCALE
    ) / (BONDS * Config.AUCTION_FLOOR_BPS);

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
    ///      the liquidation threshold. `CRASHED_NAV` is half of debt parity, so the lot
    ///      is worth half the loan and the LTV is well over 10,000 bps.
    function _openAuction() internal returns (uint256 id) {
        return _openAuctionAt(CRASHED_NAV);
    }

    /// @dev `SOFT_NAV` is the interesting case: past the liquidation threshold, but the
    ///      lot is still worth more than the debt, so a mid-auction fill leaves a
    ///      surplus. `CRASHED_NAV` is the other side - even a 100%-of-NAV fill cannot
    ///      cover the loan. Both are derived either side of `NAV_AT_DEBT_PARITY`, so
    ///      neither can end up on the wrong side of its own premise.
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
        assertEq(startPrice, 314.375e6, "100 bonds at CRASHED_NAV, at 100% of NAV");
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
        assertEq(auction.currentPrice(id), 314.375e6);
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
        assertEq(auction.currentPrice(id), 314.375e6);
    }

    function test_currentPrice_pricesTheLiveLotSoATopUpIsNotSoldForNothing() public {
        uint256 id = _openAuction();
        vm.prank(alice);
        vault.depositBonds(50);
        assertEq(auction.currentPrice(id), 471.5625e6, "150 bonds at CRASHED_NAV");
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
    ///      to close a workout over nothing. `cancel` is the correct exit and remains available,
    ///      which is what the second half asserts: the fix refuses the wrong door without closing
    ///      the right one.
    function test_expireToWorkout_refusesAPositionWithNoCollateral() public {
        uint256 id = _openAuction();

        address friend = makeAddr("friend");
        usdc.mint(friend, MAX_BORROW);
        vm.startPrank(friend);
        usdc.approve(address(credit), MAX_BORROW);
        credit.repayFor(alice, MAX_BORROW);
        vm.stopPrank();

        vm.prank(alice);
        vault.withdrawBonds(BONDS);
        assertEq(vault.bondCount(alice), 0, "the fixture must leave the position empty");

        skip(Config.AUCTION_DURATION + 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.NothingToAuction.selector, alice));
        auction.expireToWorkout(id);

        assertEq(auction.openWorkoutCount(), 0, "a workout was opened over nothing");
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
        assertEq(price, 773.3625e6, "100 bonds at SOFT_NAV, 82% of NAV");

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
        assertEq(penalty, 31.4375e6);
        assertEq(auction.rewardOf(keeper), penalty / 2, "the trigger, not the bidder");
        assertEq(credit.insuranceFund(), penalty - penalty / 2);

        // And the borrower keeps what is left, claimable rather than pushed.
        assertEq(credit.claimableOf(alice), price - MAX_BORROW - penalty);
        assertEq(credit.claimableOf(alice), 113.175e6);

        // Every wei accounted for, and the auction keeps only the unclaimed reward.
        assertEq(usdc.balanceOf(address(auction)), auction.totalUnclaimedRewards());
        assertEq(auction.totalUnclaimedRewards(), penalty / 2);

        // Principal finds its way home through the existing permissionless path.
        credit.settlePrincipal();
        assertEq(usdc.balanceOf(address(liquidity)), floatBefore + MAX_BORROW);

        vm.prank(alice);
        credit.claimSurplus();
        // The loan she actually received was the borrow less the prepaid bounty, and the
        // bounty is not coming back - it went to the keeper who opened the auction.
        assertEq(
            usdc.balanceOf(alice),
            MAX_BORROW - Config.LIQUIDATION_CALL_BOUNTY + 113.175e6,
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
        assertLt(price, MAX_BORROW, "the whole point: the lot is worth less than the loan");

        _fundBidder(bidder, price);
        uint256 shortfall = MAX_BORROW - price;

        // The old assertion was `unsocialisedLoss == shortfall - 100e6`: the residual was banked
        // as a claim to be placed on lenders later. Audit round 11 found that wrong here, because
        // there are no lenders in this fixture - the treasury float funded this loan and no lender
        // pool is wired at all. The residual was already borne by the treasury, which lent
        // `MAX_BORROW` and will only ever see the 100 of insurance plus what the lot fetched, so
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
        assertLt(price, MAX_BORROW, "a fill short of the debt");

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
        vm.prank(alice);
        credit.borrow(MAX_BORROW);
        assertEq(credit.bountyEscrowOf(alice), Config.LIQUIDATION_CALL_BOUNTY, "premise: armed");

        // Just past the threshold, which is where every real liquidation begins and the only
        // band in which a dust cure is cheap enough for the strip to pay for itself.
        oracle.setNav((NAV_AT_THRESHOLD * 999) / 1000);

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
        oracle.setNav(CRASHED_NAV);
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

        oracle.setNav(CRASHED_NAV);
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
        // NAV_FOR_PARTIAL_PENALTY puts the *floor* price only just above the debt: less
        // full penalty of surplus, but more than none. The decay curve cannot reach
        // that band at a higher NAV, because it stops at the floor by design.
        uint256 id = _openAuctionAt(NAV_FOR_PARTIAL_PENALTY);
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

    /// @notice A superseded auction hands its escrow to the auction that replaces it.
    /// @dev **The fourth exit, and the one a bounty fix forgets.** Superseding resolves nothing -
    ///      no fill, no workout, no loss recognised - so the escrow parked against the lapsed
    ///      auction must not stay with the caller who opened it and then let it lapse. Left
    ///      unhandled it would be stranded against a settled id that no exit can ever reach
    ///      again, which is USDC no address could claim.
    ///
    ///      The ordering is what makes the hand-over free rather than special-cased: `start`
    ///      returns the escrow to `bountyEscrowOf` from inside the supersede branch, and
    ///      `liquidate` reads that map again after `start` returns, so the same money re-parks
    ///      against the new id for the new caller in one call.
    function test_liquidate_supersedingRollsTheEscrowOnToTheNewCallerAndAuction() public {
        address firstCaller = makeAddr("firstCaller");
        vm.prank(alice);
        credit.borrow(MAX_BORROW);
        oracle.setNav(SOFT_NAV);

        vm.prank(firstCaller);
        credit.liquidate(alice);
        uint256 first = auction.auctionOf(alice);
        (,, uint256 parkedFirst) = credit.parkedBountyOf(first);
        assertEq(parkedFirst, Config.LIQUIDATION_CALL_BOUNTY, "parked against the first auction");

        skip(Config.AUCTION_DURATION + 1);

        address secondCaller = makeAddr("secondCaller");
        vm.prank(secondCaller);
        credit.liquidate(alice); // supersedes the lapsed one
        uint256 second = auction.auctionOf(alice);
        assertEq(second, first + 1, "premise: a fresh auction, not the old one");

        (,, uint256 parkedOld) = credit.parkedBountyOf(first);
        assertEq(parkedOld, 0, "the lapsed auction holds nothing");
        (address claimant,, uint256 parkedNew) = credit.parkedBountyOf(second);
        assertEq(parkedNew, Config.LIQUIDATION_CALL_BOUNTY, "and the escrow moved across whole");
        assertEq(claimant, secondCaller, "to the caller who actually opened the live auction");
        assertEq(credit.totalBountyParked(), Config.LIQUIDATION_CALL_BOUNTY, "counted once, not twice");

        // And it pays out to the second caller, not the first.
        skip(Config.AUCTION_DURATION);
        _fundBidder(bidder, auction.currentPrice(second));
        vm.prank(bidder);
        auction.bid(second);

        assertEq(credit.bountyOwedTo(secondCaller), Config.LIQUIDATION_CALL_BOUNTY);
        assertEq(credit.bountyOwedTo(firstCaller), 0, "the caller who let it lapse earns nothing");
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
        vault.depositBonds(50); // 150 bonds at SOFT_NAV is 4,444 bps: healthy again

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
        vm.expectCall(address(pool), abi.encodeCall(MockLenderPool.socialiseLoss, (MAX_BORROW)));
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

        // The old assertion was `unsocialisedLoss == MAX_BORROW - 300e6`, labelled "and the rest
        // is lenders'". The residual is the point of this test and the figure is untouched, but
        // whose it is was wrong: the treasury float funded this loan and no lender pool is wired,
        // so round 11 stopped recording a loss the funder is already carrying as a claim on
        // somebody else. The recognition still happens on schedule, permissionlessly, for the
        // exact amount insurance could not reach - it is now reported against the source that
        // bears it instead of being banked against a pool that lent nothing.
        vm.expectEmit(true, false, false, true, address(credit));
        emit CreditManager.LossBorneByTheSource(address(liquidity), MAX_BORROW - 300e6);

        auction.closeWorkout(id); // permissionless

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.insuranceFund(), 0, "insurance absorbed what it could");
        assertEq(credit.unsocialisedLoss(), 0, "the residual is the funder's, not a claim to place");
        assertEq(auction.openWorkoutCount(), 0);
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

        address stranger = makeAddr("stranger");
        usdc.mint(stranger, Config.LIQUIDATION_CALL_BOUNTY);
        vm.startPrank(stranger);
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

        vm.startPrank(stranger);
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
        assertLt(price, MAX_BORROW, "premise: the fill cannot cover the debt");
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
        vm.prank(bob);
        credit.borrow(MAX_BORROW);
        assertEq(credit.bountyEscrowOf(bob), Config.LIQUIDATION_CALL_BOUNTY, "premise: armed");

        oracle.setNav(CRASHED_NAV);
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
        credit.borrow((BONDS * CRASHED_NAV * Config.MAX_LTV_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE));
        vm.stopPrank();
        oracle.setNav(CRASHED_NAV / 4); // and then it quarters, to 10,000 bps
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

        CreditManager next =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
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
