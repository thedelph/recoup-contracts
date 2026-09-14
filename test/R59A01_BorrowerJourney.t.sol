// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @title R59A01_BorrowerJourney
/// @notice Audit round 59, slot A1. One borrower, one worst day, priced in USDC at every step.
///
///         The scenario is chosen so every figure is a round number a person could check by hand:
///         NAV starts at exactly $20.00, the borrower deposits 200 bonds, so the collateral is
///         $4,000.00 and the 25% ceiling is a $1,000.00 loan.
///
///         Each test asserts what the borrower PAID, and where each USDC went. Where the webapp
///         states something in prose, the test names the claim and asserts the figure the claim
///         is about, so a reader can see the gap without running the site.
contract R59A01_BorrowerJourneyTest is RiskParamsFixture {
    uint256 internal constant NAV0 = 20e8; // $20.00, 8dp
    uint256 internal constant BONDS = 200; // collateral $4,000.00
    uint256 internal constant FLOAT = 100_000e6;
    uint256 internal constant EPOCH = 1_000e6; // one epoch of farm USDC

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // the borrower, that is me
    address internal keeper = makeAddr("keeper"); // whoever calls liquidate
    address internal bidder = makeAddr("bidder");
    address internal feeWallet = makeAddr("feeWallet");
    address internal stranger = makeAddr("stranger");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    EpochHarvester internal harvester;
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
        oracle = new MockNavOracle(NAV0);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
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
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        liquidity.setCreditManager(address(credit));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        harvester.setProtocolFeeWallet(feeWallet);
        adapter.setHarvester(address(harvester));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        _deposit(alice, BONDS);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 bonds) internal {
        bond.mint(who, bonds);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    /// @dev One epoch of farm USDC, harvested and streamed to completion.
    function _epoch(uint256 amount) internal {
        farm.setPendingYield(address(adapter), amount);
        harvester.harvest();
        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();
    }

    function _fundBidder(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), type(uint256).max);
    }

    function _lotPriceAt(uint256 bonds, uint256 nav, uint256 premiumBps) internal pure returns (uint256) {
        uint256 numerator = bonds * nav * premiumBps;
        uint256 denominator = Config.BPS * Config.USDC_TO_NAV_SCALE;
        return (numerator + denominator - 1) / denominator; // ceilDiv, the last wei is the debt's
    }

    // ── step 1: what the screen promises against what the wallet receives ────

    /// @notice `/borrow` renders "Borrowed, and owed as debt" and "Liquidation deposit,
    ///         refundable" as two lines. This is the same pair, in USDC, from the chain.
    ///
    ///         The webapp's `borrowSplit()` mirrors this exactly and the landing FAQ answer
    ///         "Can my debt ever go up?" is literally true: the deposit is withheld from the
    ///         disbursement, never added to `debtOf`.
    function test_R59A01_step1_theWalletReceivesTwentyFiveLessThanTheDebt() public {
        vm.prank(alice);
        credit.borrow(1_000e6);

        assertEq(credit.debtOf(alice), 1_000e6, "the protocol books the full amount as debt");
        assertEq(usdc.balanceOf(alice), 975e6, "the wallet receives amount - 25");
        assertEq(credit.bountyEscrowOf(alice), 25e6, "the difference is escrowed, not spent");
        assertEq(credit.currentLtvBps(alice), 2_500, "and the LTV is computed on the debt, not the cash");
    }

    /// @notice The dust guard keys on the RESULTING debt, so a small first loan is not charged
    ///         and a top-up that crosses $500 pays the whole deposit out of that top-up.
    function test_R59A01_step1b_theDepositIsFreeBelowFiveHundredAndCliffsAtIt() public {
        vm.prank(alice);
        credit.borrow(499e6);
        assertEq(usdc.balanceOf(alice), 499e6, "under the dust threshold nothing is withheld");
        assertEq(credit.bountyEscrowOf(alice), 0);

        // The cliff: a $1 top-up would take the debt to $500 and owe the whole $25 out of that $1.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.BorrowBelowBounty.selector, 1e6, 25e6));
        credit.borrow(1e6);

        vm.prank(alice);
        credit.borrow(25e6);
        assertEq(usdc.balanceOf(alice), 499e6, "the whole top-up went to the deposit");
        assertEq(credit.debtOf(alice), 524e6, "and the debt still moved by the full amount");
    }

    // ── step 2: custody ──────────────────────────────────────────────────────

    /// @notice What the farm pays on YOUR bonds while they sit in custody, and who takes it.
    ///
    ///         The landing FAQ says "Bonds sit in Recoup's non-custodial vault contract - we
    ///         can't spend them, only return them when you repay". True of the bonds. The yield
    ///         they earn in there is split four ways whether or not you ever borrow: a holder
    ///         with zero debt keeps 55% and the other 45% is lenders', insurance's and the
    ///         protocol's.
    function test_R59A01_step2_custodyKeepsFortyFivePercentOfYourBondsYield() public {
        // No debt at all. Just parking bonds.
        assertEq(credit.debtOf(alice), 0);

        _epoch(EPOCH);

        uint256 toBorrowers = (EPOCH * Config.SPLIT_BORROWER_BPS) / Config.BPS; // 550.000000
        uint256 toLenders = (EPOCH * Config.SPLIT_LENDER_BPS) / Config.BPS; // 250.000000
        uint256 toInsurance = (EPOCH * Config.SPLIT_INSURANCE_BPS) / Config.BPS; // 100.000000
        uint256 toProtocol = EPOCH - toBorrowers - toLenders - toInsurance; // 100.000000
        assertEq(toBorrowers, 550e6);
        assertEq(toLenders, 250e6);
        assertEq(toInsurance, 100e6);
        assertEq(toProtocol, 100e6);

        vm.prank(alice);
        credit.claimSurplus();

        // Alice is the only holder, so the whole borrower share is hers, less the stream's
        // per-stream truncation of at most one wei.
        assertApproxEqAbs(usdc.balanceOf(alice), toBorrowers, 1, "55% of what her own bonds earned");
        assertEq(credit.insuranceFund(), toInsurance, "insurance took 10%");
        assertEq(harvester.pendingLenderYield(), toLenders, "lenders are owed 25%");
        harvester.flushProtocolFee();
        assertEq(usdc.balanceOf(feeWallet), toProtocol, "the protocol took 10%");

        // The cash cost of custody, stated as one number: $450.00 of every $1,000.00 the
        // borrower's own bonds earn while they are in the vault.
        assertEq(EPOCH - toBorrowers, 450e6, "the haircut on a zero-debt deposit");
    }

    /// @notice "We can't spend them, only return them when you repay." The adapter owner can
    ///         move every depositor's bonds to any address in one call, and the vault's ledger
    ///         does not move, so nobody's `bondCount` changes and nobody is compensated.
    function test_R59A01_step2b_theOwnerCanMoveEveryBondOutOfCustodyInOneCall() public {
        assertEq(vault.bondCount(alice), BONDS);
        assertEq(adapter.stakedBalance(), BONDS);
        assertTrue(vault.custodyIsSolvent());

        address elsewhere = makeAddr("elsewhere");
        bond.setWhitelisted(elsewhere, true); // DexFi's gate, satisfied by any whitelisted address

        vm.prank(admin);
        adapter.emergencyUnstake(elsewhere);

        assertEq(bond.balanceOf(elsewhere, Config.DEXFI_BOND_TOKEN_ID), BONDS, "every bond left");
        assertEq(vault.bondCount(alice), BONDS, "and her ledger entry is untouched");
        assertFalse(vault.custodyIsSolvent(), "the only signal is this view");

        // She cannot get them back. `CreditManager.borrow`'s own comment says of this state that
        // "withdrawals and liquidation views deliberately stay open"; the withdrawal reaches the
        // farm for units that are no longer staked and dies there. The selector is the mock
        // farm's, so on mainnet the exact revert is DexFi's - but the shape is arithmetic, not a
        // policy choice, and no unstake of 200 out of 0 can succeed anywhere.
        assertEq(adapter.stakedBalance(), 0, "nothing is staked to unstake");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InsufficientStake(uint256,uint256)", BONDS, 0));
        vault.withdrawBonds(BONDS);

        // At the live Base Sepolia NAV of $29.318552 read at block 46734635, the staked balance
        // of 1,000 bonds this call would move is $29,318.55.
        assertEq(uint256(1_000) * 2931855156 / uint256(1e8), 29318, "live custody, to the dollar");
    }

    /// @notice The other half of the same dependency: DexFi's whitelist. Revoke the adapter and
    ///         a debt-free borrower cannot withdraw their own collateral.
    ///         And the trap is one-directional: the gate passes when the caller, the sender OR the
    ///         recipient is whitelisted, so a whitelisted buyer can still take the lot out of a
    ///         liquidation in the same state that refuses the borrower her own bonds.
    function test_R59A01_step2c_deWhitelistingTheAdapterTrapsYourBondsButNotALiquidation() public {
        vm.prank(alice);
        credit.borrow(1_000e6);

        bond.setWhitelisted(address(adapter), false); // DexFi's EOA, one transaction

        // Her own exit is refused by DexFi's gate, not by anything Recoup controls. She cannot
        // clear it by repaying either: the same transfer is the last statement of `withdrawBonds`.
        usdc.mint(alice, 25e6);
        vm.startPrank(alice);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(1_000e6);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AddressesNotWhitelisted(address,address,address)", address(adapter), address(adapter), alice
            )
        );
        vault.withdrawBonds(BONDS);
        vm.stopPrank();

        assertEq(vault.bondCount(alice), BONDS, "the ledger says they are hers");
        assertTrue(vault.custodyIsSolvent(), "and custody reads solvent while she cannot exit");

        // Meanwhile a whitelisted bidder can still be handed the same bonds by a liquidation.
        vm.prank(alice);
        credit.borrow(1_000e6);
        oracle.setNav(9.99e8);
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        bond.setWhitelisted(bidder, true);
        _fundBidder(bidder, 1_998e6);
        vm.prank(bidder);
        auction.bid(id, 1_998e6);
        assertEq(bond.balanceOf(bidder, Config.DEXFI_BOND_TOKEN_ID), BONDS, "out through the auction");
    }

    // ── step 3: borrowing to the ceiling ─────────────────────────────────────

    /// @notice A second draw is free, the ceiling binds on resulting debt, and the health
    ///         factor at the ceiling is exactly 2.00 - the badge says SAFE and it is right.
    function test_R59A01_step3_aSecondDrawIsFreeAndTheCeilingIsExactlyTwoThousandUsdc() public {
        assertEq(_maxBorrow(BONDS, NAV0), 1_000e6, "200 bonds at $20.00, 25% ceiling");

        vm.prank(alice);
        credit.borrow(600e6);
        assertEq(usdc.balanceOf(alice), 575e6, "first draw pays the deposit");

        vm.prank(alice);
        credit.borrow(400e6);
        assertEq(usdc.balanceOf(alice), 975e6, "second draw is free - the escrow is a top-up");
        assertEq(credit.bountyEscrowOf(alice), 25e6, "still one deposit, not two");

        // One wei more is refused, and the error carries the ceiling so the screen need not
        // mirror a parameter that can move.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsMaxLtv.selector, 2_500, 2_500));
        credit.borrow(1);

        assertEq(credit.healthFactor(alice), 2e18, "threshold 50% over LTV 25%");
        assertEq(credit.currentLtvBps(alice), 2_500);
    }

    // ── step 4: NAV falls ────────────────────────────────────────────────────

    /// @notice How far NAV has to fall, and how long one key alone needs to take it there.
    ///
    ///         A position at the 25% ceiling is liquidatable only once NAV has HALVED. The
    ///         oracle's deviation budget is 10% per 24 hours against the last accepted price,
    ///         so a single keeper walking the price down needs seven daily posts. That is the
    ///         warning the borrower gets, and it is the thing worth knowing: the webapp's
    ///         "NAV would have to fall 50%" is exactly right.
    function test_R59A01_step4_navMustHalveAndOneKeyNeedsSevenDailyPosts() public {
        vm.prank(alice);
        credit.borrow(1_000e6);

        // Exactly on the threshold is still healthy: `exceedsLtv` is a strict `>`.
        oracle.setNav(10e8);
        assertEq(credit.healthFactor(alice), 1e18, "hf reads exactly 1.00 at the boundary");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.PositionHealthy.selector, 5_000));
        credit.liquidate(alice);

        // One NAV-wei below it is not.
        oracle.setNav(10e8 - 1);
        vm.prank(keeper);
        credit.liquidate(alice);
        assertGt(auction.auctionOf(alice), 0, "liquidatable at $9.99999999, not at $10.00000000");

        // Now the clock, on the real oracle rather than the mock.
        NAVOracle real = new NAVOracle(admin);
        vm.startPrank(admin);
        real.setKeeper(keeper);
        real.bootstrapNav(NAV0);
        vm.stopPrank();

        uint256 posts;
        while (real.navPerBond() > 10e8) {
            skip(Config.NAV_DEVIATION_WINDOW); // a full day buys the full 10% budget
            uint256 floorPrice = real.navPerBond() - (real.navPerBond() * Config.NAV_MAX_DEVIATION_BPS) / Config.BPS;
            vm.prank(keeper);
            real.postNav(floorPrice);
            posts++;
        }
        assertEq(posts, 7, "seven daily posts to halve the price with one key");
        assertEq(real.navPerBond(), 9.565938e8, "$20.00 compounded down at 10% a day for a week");
    }

    // ── step 5: being liquidated ─────────────────────────────────────────────

    /// @notice Every USDC of a floor fill, and whose pocket it lands in.
    ///
    ///         The landing FAQ says: "the bonds are Dutch-auctioned, your debt is repaid from
    ///         the proceeds, and any surplus comes back to you." Both clauses are true. What
    ///         neither says is that the WHOLE lot is sold - at the liquidation boundary that is
    ///         twice the debt - and that the price decays to 68% of NAV, so the 32% discount is
    ///         charged on the whole position rather than on the part needed to clear the loan.
    function test_R59A01_step5_everyUsdcOfAFloorFill() public {
        vm.prank(alice);
        credit.borrow(1_000e6);
        assertEq(usdc.balanceOf(alice), 975e6);

        // NAV halves and then some: $9.99. Collateral is $1,998.00 against a $1,000.00 loan.
        uint256 crashNav = 9.99e8;
        oracle.setNav(crashNav);
        uint256 markAtLiquidation = (BONDS * crashNav) / Config.USDC_TO_NAV_SCALE;
        assertEq(markAtLiquidation, 1_998e6, "what the lot is worth at the moment it is seized");

        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);

        (,,,, uint256 lot, uint256 startNav, uint256 startPrice,) = auction.auctions(id);
        assertEq(lot, BONDS, "the WHOLE position is the lot, not the part that covers the debt");
        assertEq(startNav, crashNav);
        assertEq(startPrice, 1_998e6, "the auction opens at 100% of NAV");

        // Nobody bids for six hours. The price decays to the floor.
        skip(Config.AUCTION_DURATION);
        uint256 floorPrice = _lotPriceAt(BONDS, crashNav, Config.AUCTION_FLOOR_BPS);
        assertEq(floorPrice, 1_358.64e6, "68% of NAV on the whole lot");
        assertEq(auction.currentPrice(id), floorPrice);

        _fundBidder(bidder, floorPrice);
        vm.prank(bidder);
        auction.bid(id, floorPrice);

        // The waterfall, to the cent.
        uint256 repaid = 1_000e6;
        uint256 surplus = floorPrice - repaid; // 358.640000
        uint256 penalty = (1_000e6 * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS; // 50.000000
        uint256 callerShare = (penalty * Config.LIQUIDATION_CALLER_SHARE_BPS) / Config.BPS; // 25.000000
        assertEq(surplus, 358.64e6);
        assertEq(penalty, 50e6);
        assertEq(callerShare, 25e6);

        assertEq(credit.debtOf(alice), 0, "the loan is cleared");
        assertEq(credit.claimableOf(alice), surplus - penalty, "surplus less the penalty comes back");
        assertEq(credit.claimableOf(alice), 308.64e6);
        assertEq(vault.bondCount(alice), 0, "and every bond is gone");
        assertEq(bond.balanceOf(bidder, Config.DEXFI_BOND_TOKEN_ID), BONDS);

        vm.prank(alice);
        credit.claimSurplus();
        uint256 aliceEndsWith = usdc.balanceOf(alice);
        assertEq(aliceEndsWith, 975e6 + 308.64e6, "the borrowed cash plus the surplus");
        assertEq(aliceEndsWith, 1_283.64e6);

        // The keeper is paid twice out of the borrower: the prepaid deposit and half the penalty.
        vm.startPrank(keeper);
        credit.claimBounty();
        auction.claimReward();
        vm.stopPrank();
        assertEq(usdc.balanceOf(keeper), 25e6 + callerShare, "deposit plus the caller's half");
        assertEq(usdc.balanceOf(keeper), 50e6);

        // The bidder's side of the same trade.
        assertEq(bond.balanceOf(bidder, Config.DEXFI_BOND_TOKEN_ID) * crashNav / Config.USDC_TO_NAV_SCALE, 1_998e6);

        // The bill. Against the mark at the moment of seizure, the borrower is out $714.36 -
        // 35.75% of the position - of which the 5% penalty and the $25 deposit are $75.00 and
        // the remaining $639.36 is the auction discount charged on collateral that was never
        // needed to clear the loan.
        assertEq(markAtLiquidation - aliceEndsWith, 714.36e6, "what the worst day actually costs");
        assertEq(markAtLiquidation - floorPrice, 639.36e6, "the discount, on the whole lot");
        assertEq((markAtLiquidation - aliceEndsWith) * 10_000 / markAtLiquidation, 3_575, "bps of the mark");
    }

    /// @notice The same seizure filled at the opening price, for contrast: the advertised cost.
    function test_R59A01_step5b_aStartPriceFillCostsTheAdvertisedFivePercent() public {
        vm.prank(alice);
        credit.borrow(1_000e6);
        oracle.setNav(9.99e8);

        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);

        _fundBidder(bidder, 1_998e6);
        vm.prank(bidder);
        auction.bid(id, 1_998e6); // same block, so the premium is still 100%

        vm.prank(alice);
        credit.claimSurplus();

        // surplus 998, penalty 50, so 948 back. Plus the 975 she was disbursed.
        assertEq(usdc.balanceOf(alice), 975e6 + 948e6);
        assertEq(usdc.balanceOf(alice), 1_923e6);
        assertEq(uint256(1_998e6) - 1_923e6, 75e6, "the penalty and the deposit, and nothing else");

        // So the borrower's bill is 9.5x larger at the floor than at the open, on the same
        // position, decided entirely by when a bidder chooses to turn up.
        assertEq(714.36e6 / uint256(75e6), 9);
    }

    /// @notice Nobody bids at all. The workout is worse for the borrower than the floor fill.
    function test_R59A01_step5c_theWorkoutIsWorseThanTheFloor() public {
        vm.prank(alice);
        credit.borrow(1_000e6);
        oracle.setNav(9.99e8);

        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);

        skip(Config.AUCTION_DURATION + 1);
        vm.prank(stranger);
        auction.expireToWorkout(id);

        assertEq(vault.bondCount(alice), 0, "the lot is reassigned out of her ledger");
        assertEq(vault.bondCount(address(auction)), BONDS, "and parked under the auction's");
        assertEq(auction.workoutsOpenFor(alice), 1);

        // No recovery ever arrives. Fourteen days later anyone can force the close.
        skip(Config.WORKOUT_MAX_DURATION);
        vm.prank(stranger);
        auction.closeWorkout(id);

        assertEq(credit.currentDebtOf(alice), 0, "the debt is written off");
        assertEq(credit.claimableOf(alice), 0, "and she gets nothing back");

        // She keeps the $975.00 she was disbursed and nothing else, against a position marked
        // at $1,998.00 when it was seized: $1,023.00, 51.20% of the mark. The forgiven debt is
        // already counted - she keeps the cash it bought.
        assertEq(usdc.balanceOf(alice), 975e6);
        assertEq(uint256(1_998e6) - 975e6, 1_023e6, "worse than the floor fill by $308.64");
        assertEq(uint256(1_023e6) - 714.36e6, 308.64e6);
    }

    // ── step 6: repaying, withdrawing, and the things that go wrong ──────────

    /// @notice What a partial repayment buys, and what it does not.
    function test_R59A01_step6_partialRepaymentBuysHeadroomNotTheDeposit() public {
        vm.prank(alice);
        credit.borrow(1_000e6);

        usdc.mint(alice, 500e6);
        vm.startPrank(alice);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(500e6);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 500e6);
        assertEq(credit.bountyEscrowOf(alice), 25e6, "a partial repayment does not disarm the deposit");
        assertEq(usdc.balanceOf(alice), 975e6, "and costs exactly the amount repaid");
        assertEq(credit.currentLtvBps(alice), 1_250, "what it buys: the LTV halves");

        // The liquidation price halves with it.
        oracle.setNav(5e8 + 1);
        vm.prank(keeper);
        vm.expectRevert();
        credit.liquidate(alice);
        oracle.setNav(5e8 - 1);
        vm.prank(keeper);
        credit.liquidate(alice);
    }

    /// @notice The full repayment settles its own tail out of the escrow, so clearing a $1,000
    ///         loan costs the $975 that was actually received. Then the collateral comes back.
    function test_R59A01_step6b_clearingTheLoanCostsWhatYouReceived() public {
        vm.prank(alice);
        credit.borrow(1_000e6);
        assertEq(usdc.balanceOf(alice), 975e6);

        vm.startPrank(alice);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0, "the cash cost of the loan is the loan");
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.bountyEscrowOf(alice), 0);

        vm.prank(alice);
        vault.withdrawBonds(BONDS);
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), BONDS, "and the bonds come home");
    }

    /// @notice The keeper has been out for nine days. What still works and what does not.
    ///
    ///         Borrowing stops and so does every partial withdrawal of collateral. Liquidation
    ///         does NOT stop: it prices on the last known NAV, so a nine-day-old price can seize
    ///         a position that is healthy at the real one. Repaying and depositing stay open,
    ///         which is the borrower's only defence.
    function test_R59A01_step6c_aStaleOracleLocksCollateralInButNotLiquidationOut() public {
        vm.prank(alice);
        credit.borrow(1_000e6);

        oracle.setStale(true);

        vm.prank(alice);
        vm.expectRevert(CreditManager.NavStale.selector);
        credit.borrow(1);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.NavStale.selector);
        vault.withdrawBonds(1);

        // Repaying is never gated.
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(100e6);
        vm.stopPrank();
        assertEq(credit.debtOf(alice), 900e6);

        // And neither is liquidation, on whatever price was last posted. $8.90 against a debt of
        // $900.00 over 200 bonds is an LTV of 5,056 bps, past the 5,000 threshold.
        oracle.setNav(8.9e8); // the stale figure; `isStale` is still true
        vm.prank(keeper);
        credit.liquidate(alice);
        assertGt(auction.auctionOf(alice), 0, "seized on a price nobody has refreshed for nine days");
    }

    /// @notice The credit manager is migrated. A holder's accrued-but-unsettled yield is swept
    ///         into the incoming manager's insurance fund and is unreachable forever.
    ///
    ///         `migrateReserves` says so in its own docstring - "a holder who had accrued but
    ///         not settled loses the individual claim" - and nothing on any screen does.
    function test_R59A01_step6d_aManagerMigrationDestroysUnsettledYield() public {
        // No debt, so the migration precondition (`totalDebt == 0`) is satisfied throughout.
        _epoch(EPOCH);

        uint256 owed = credit.pendingYieldOf(alice);
        assertApproxEqAbs(owed, 550e6, 1, "one epoch's borrower share, accrued and unsettled");
        assertEq(credit.claimableOf(alice), 0, "nothing has settled it");

        CreditManager incoming = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        vm.startPrank(admin);
        vault.setCreditManager(address(incoming));
        credit.migrateReserves();
        vm.stopPrank();

        // Gone. Not deferred, not claimable somewhere else.
        vm.prank(alice);
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        credit.claimSurplus();
        assertEq(incoming.claimableOf(alice), 0, "and the incoming manager owes her nothing");
        assertEq(incoming.pendingYieldOf(alice), 0);
        assertGe(incoming.insuranceFund(), owed, "her yield is now the protocol's insurance");
    }

    /// @notice Repaying a defaulted loan IN FULL during a workout does not get the collateral
    ///         back. The lot is parked under the auction contract's ledger entry and the only
    ///         function that moves it is `disposeWorkoutLot`, which is `onlyOwner`, carries no
    ///         deadline and answers to nobody. The borrower has no call at all.
    function test_R59A01_step6e_aCleanWorkoutCloseLeavesYourBondsInTheOwnersHands() public {
        vm.prank(alice);
        credit.borrow(1_000e6);
        oracle.setNav(9.99e8);

        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);

        skip(Config.AUCTION_DURATION + 1);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertEq(vault.bondCount(address(auction)), BONDS, "the lot moved to the auction's entry");

        // She pays the whole loan back, out of her own pocket, with the bonds still staked.
        usdc.mint(alice, 25e6);
        vm.startPrank(alice);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(1_000e6);
        vm.stopPrank();
        assertEq(credit.currentDebtOf(alice), 0, "nothing is owed");
        assertEq(usdc.balanceOf(alice), 0, "and it cost her the whole thousand");

        // A clean close: no residual, so no fourteen-day wait and nothing written off.
        vm.prank(stranger);
        auction.closeWorkout(id);
        assertEq(auction.workoutsOpenFor(alice), 0);

        // And the bonds are still not hers.
        assertEq(vault.bondCount(alice), 0);
        assertEq(vault.bondCount(address(auction)), BONDS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.InsufficientCollateral.selector, BONDS, 0));
        vault.withdrawBonds(BONDS);
        vm.prank(alice);
        vm.expectRevert();
        auction.disposeWorkoutLot(id, alice);

        // Only the owner can hand them over, and nothing obliges them to, ever.
        vm.prank(admin);
        auction.disposeWorkoutLot(id, alice);
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), BONDS, "at the owner's discretion");
    }

    // ── step 7: referring a friend ───────────────────────────────────────────

    /// @notice Where the referral cash lands: nowhere, on chain. The registry records two facts
    ///         and holds no value, and there is no distributor to pay from. `/refer` says so -
    ///         its claim button is disabled - and this is the assertion behind that sentence.
    function test_R59A01_step7_theReferralRegistryMovesNoMoney() public {
        ReferralRegistry registry = new ReferralRegistry(new bytes32[](0));

        bytes32 code = bytes32("ALICECODE");
        vm.prank(alice);
        registry.register(code);
        assertEq(registry.referrerOf(code), alice);

        vm.prank(stranger);
        registry.bind(code);
        assertEq(registry.referrerFor(stranger), alice);

        // No value moved, and the contract cannot hold any: it has no token balance, no owner
        // and no payable path.
        assertEq(usdc.balanceOf(address(registry)), 0);
        assertEq(address(registry).balance, 0);

        // The binding is permanent, which is the only thing a referee can get wrong.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.AlreadyBound.selector, code));
        registry.bind(code);

        // What the programme is worth, in the units a referee would actually see: the rebate is
        // 10% of Recoup's 80% of the 10% protocol fee, so 0.8% of gross yield, for 12 weeks.
        uint256 grossYield = EPOCH;
        uint256 protocolLeg = (grossYield * Config.SPLIT_PROTOCOL_BPS) / Config.BPS;
        uint256 recoupLeg = (protocolLeg * Config.PROTOCOL_FEE_RECOUP_BPS) / Config.BPS;
        uint256 refereeRebate = (recoupLeg * Config.REFERRAL_REFEREE_SHARE_BPS) / Config.BPS;
        assertEq(refereeRebate, 8e6, "$8.00 per $1,000.00 epoch, payable by nothing that exists");
    }
}
