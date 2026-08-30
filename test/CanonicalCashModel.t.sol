// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CanonicalCashModel} from "./models/CanonicalCashModel.sol";

contract CanonicalCashModelTest is Test {
    uint256 internal constant CAP = 25_000e6;
    uint256 internal constant STREAM = 5 days;

    CanonicalCashModel internal model;

    function setUp() public {
        model = new CanonicalCashModel(CAP);
    }

    function _reachMaterialNumericReserve() internal returns (uint256 required) {
        uint256 targetLoss = Math.mulDiv(CAP, 8_500, 10_000);
        model.deposit(CAP);

        for (uint256 cycle = 0; cycle < 128; cycle++) {
            uint256 lent = model.available();
            if (lent > targetLoss) lent = targetLoss;
            if (lent == 0) break;

            model.lend(lent);
            model.socialiseLoss(lent);
            model.deposit(model.maxDeposit());

            required = model.requiredEntryAssets();
            if (required >= 1_000) return required;
        }

        revert("numeric reserve fixture did not become material");
    }

    function test_aDonationCannotChangeAnyShareholderOrCapView() public {
        model.deposit(100e6);

        uint256 assetsBefore = model.totalAssets();
        uint256 entryBefore = model.entryAssets();
        uint256 cashBefore = model.shareholderCash();
        uint256 usageBefore = model.depositCapUsage();
        uint256 roomBefore = model.maxDeposit();

        model.donate(500e6);

        assertEq(model.totalAssets(), assetsBefore, "donation changed released NAV");
        assertEq(model.entryAssets(), entryBefore, "donation changed entry NAV");
        assertEq(model.shareholderCash(), cashBefore, "donation became lendable");
        assertEq(model.depositCapUsage(), usageBefore, "donation consumed cap");
        assertEq(model.maxDeposit(), roomBefore, "donation moved cap headroom");
        assertEq(model.unmanagedSurplus(), 500e6, "donation was not isolated as surplus");
    }

    function test_R22F3_theHundredPlusDonationCannotFundAOneSeventyLoan() public {
        model.deposit(100e6);
        model.donate(100e6);

        assertEq(model.shareholderCash(), 100e6, "donation entered available cash");
        vm.expectRevert(CanonicalCashModel.InsufficientCash.selector);
        model.lend(170e6);

        model.lend(100e6);
        assertEq(model.outstandingPrincipal(), 100e6, "the accounted hundred was not lent");
        assertEq(model.rawCash(), 100e6, "the donated hundred should remain physically present");
        assertEq(model.unmanagedSurplus(), 100e6, "the donated hundred lost its provenance boundary");
    }

    function test_activeAndFrozenYieldBothBelongToTheIncumbentCohort() public {
        model.deposit(100e6);
        model.addFrozenGain(20e6);

        assertEq(model.totalAssets(), 100e6, "frozen yield entered released NAV");
        assertEq(model.entryAssets(), 120e6, "frozen yield was excluded from the entry quote");
        assertEq(model.depositCapUsage(), 120e6, "frozen yield was excluded from cap usage");

        model.activateFrozen(STREAM);
        assertEq(model.totalAssets(), 100e6, "activation released the pot immediately");
        assertEq(model.entryAssets(), 120e6, "active entry quote omitted the live tail");
        assertEq(model.depositCapUsage(), 120e6, "activation did not count the pot exactly once");

        skip(STREAM / 2);
        assertApproxEqAbs(model.totalAssets(), 110e6, 1, "half the stream did not release");
        assertEq(model.entryAssets(), 120e6, "elapsed release changed the gross entry book");
        assertEq(model.depositCapUsage(), 120e6, "elapsed release changed cap usage");
    }

    function test_anActiveStreamCashDeficitProjectsImmediatelyAndReconcilesWithoutExtending() public {
        model.deposit(100e6);
        model.addActiveGain(20e6, STREAM);
        uint256 oldRate = model.yieldRate();
        uint256 oldEnd = model.yieldStreamEndsAt();

        model.destroyCash(10e6);

        assertEq(model.cashDeficit(), 10e6, "the external subtraction was not visible");
        assertEq(model.totalAssets(), 100e6, "the deficit did not consume unreleased yield first");
        assertEq(model.entryAssets(), 110e6, "entry NAV ignored the projected loss");
        assertEq(model.depositCapUsage(), 120e6, "unreconciled usage stopped being conservative");
        assertEq(model.maxDeposit(), 0, "entry stayed open across an unresolved deficit");

        model.reconcileCashDeficit();

        assertEq(model.accountedCash(), 110e6, "reconciliation did not write down accounted cash");
        assertEq(model.pendingYield(), 10e6, "the yield-first write-down was not crystallised");
        assertEq(model.yieldRate(), oldRate, "reconciliation changed the active release rate");
        assertLt(model.yieldStreamEndsAt(), oldEnd, "a smaller pot was not shortened");
        assertEq(model.totalAssets(), 100e6, "reconciliation changed projected NAV");
        assertEq(model.depositCapUsage(), 110e6, "reconciled loss did not reduce active usage");
    }

    function test_entryRequiresExplicitReconciliationSoMaximaAndAcceptanceAgree() public {
        model.deposit(100e6);
        model.destroyCash(1e6);

        assertEq(model.maxDeposit(), 0, "deposit maximum stayed open across a deficit");
        assertEq(model.maxMint(), 0, "mint maximum stayed open across a deficit");
        vm.expectRevert(CanonicalCashModel.DepositClosed.selector);
        model.deposit(1e6);
        vm.expectRevert(CanonicalCashModel.DepositClosed.selector);
        model.mint(1e9);

        model.reconcileCashDeficit();
        assertGt(model.maxDeposit(), 0, "explicit reconciliation did not reopen deposit");
        assertGt(model.maxMint(), 0, "explicit reconciliation did not reopen mint");
        model.deposit(1e6);
        model.mint(1e9);
    }

    function test_aFrozenDeficitReducesThePotAndThenTheStoredUsage() public {
        model.deposit(100e6);
        model.addFrozenGain(20e6);
        model.destroyCash(10e6);

        assertEq(model.totalAssets(), 100e6, "the frozen loss reached released capital");
        assertEq(model.depositCapUsage(), 120e6, "unreconciled usage stopped using stored cash");

        model.reconcileCashDeficit();
        assertEq(model.accountedCash(), 110e6, "accounted cash did not meet raw backing");
        assertEq(model.pendingYield(), 10e6, "the frozen tail did not absorb the loss");
        assertEq(model.yieldRate(), 0, "reconciliation activated a frozen stream");
        assertEq(model.depositCapUsage(), 110e6, "reconciled loss did not reduce stored usage");
    }

    function test_claimUnderfundingBlocksTheRaceUntilAnExplicitCover() public {
        uint256 shares = model.deposit(100e6);
        uint256 serviceShares = (shares * 60) / 100;
        uint256 claim = model.service(serviceShares);
        assertApproxEqAbs(claim, 60e6, 1, "fixture did not create the intended claim");

        model.destroyCash(50e6);
        assertGt(model.claimLiquidityDeficit(), 0, "claim reserve remained fully backed");
        assertEq(model.totalAssets(), 0, "shareholders ranked ahead of an underfunded claim");
        assertEq(model.maxDeposit(), 0, "new money could enter an insolvent claim reserve");

        vm.expectRevert(CanonicalCashModel.ClaimsUnderfunded.selector);
        model.claim(1);

        model.reconcileCashDeficit();
        uint256 shortage = model.claimLiquidityDeficit();
        model.coverClaimDeficit(shortage);
        assertEq(model.claimLiquidityDeficit(), 0, "explicit cover did not restore the reserve");

        model.claim(claim);
        assertEq(model.totalClaimable(), 0, "the restored claim was not cleared");
    }

    function test_aPrincipalBackedLiquidityGapCannotUseTheDeficitCoverAsUnstreamedYield() public {
        uint256 shares = model.deposit(100e6);
        model.lend(50e6);
        uint256 claim = model.service(model.maxRedeem());
        model.destroyCash(25e6);

        assertGt(model.claimLiquidityDeficit(), 0, "fixture did not leave a cash liquidity gap");
        assertEq(model.claimSolvencyDeficit(), 0, "outstanding principal did not keep the claim solvent");

        vm.expectRevert(CanonicalCashModel.CoverExceedsDeficit.selector);
        model.coverClaimDeficit(1);

        assertGt(shares, model.totalSupply(), "fixture did not burn any requested shares");
        assertGt(claim, 0, "fixture did not create a serviced claim");
    }

    function test_socialisedPrincipalCannotResurrectAClaimFundedTailOnTheNextDeposit() public {
        model.deposit(170e6);
        model.lend(20e6);
        uint256 claim = model.service(100e9);
        assertEq(claim, 100e6, "fixture did not service the exact claim");

        model.destroyCash(100e6);
        model.reconcileCashDeficit();
        assertEq(model.accountedCash(), 50e6, "cash write-down moved");
        assertEq(model.outstandingPrincipal(), 20e6, "principal fixture moved");
        assertEq(model.totalClaimable(), 100e6, "claim fixture moved");
        assertEq(model.claimSolvencyDeficit(), 30e6, "solvency shortfall moved");

        model.addActiveGain(50e6, STREAM);
        assertEq(model.claimSolvencyDeficit(), 0, "gain did not restore the fixed claim first");
        assertEq(model.pendingYield(), 20e6, "claim coverage was incorrectly streamed");
        assertEq(model.depositCapUsage(), 20e6, "streamable residual was not counted once");

        model.claim(100e6);
        assertEq(model.accountedCash(), 0, "claim payment left recognised cash");
        assertEq(model.outstandingPrincipal(), 20e6, "claim payment moved principal");
        assertEq(model.totalClaimable(), 0, "claim payment left a fixed liability");
        assertEq(model.unreleasedYield(), 20e6, "claim payment consumed the shareholder tail");

        model.socialiseLoss(20e6);
        assertEq(model.outstandingPrincipal(), 0, "principal loss was not absorbed");
        assertEq(model.pendingYield(), 0, "principal loss left an unbacked stored tail");
        assertEq(model.unreleasedYield(), 0, "principal loss left an effective tail");
        assertEq(model.depositCapUsage(), 0, "principal loss left cap usage behind");

        model.deposit(30e6);
        assertEq(model.pendingYield(), 0, "fresh entry resurrected the written-off tail");
        assertEq(model.totalAssets(), 30e6, "fresh entrant inherited the written-off tail");
        assertEq(model.depositCapUsage(), 30e6, "fresh entry was not counted exactly once");
    }

    function test_aDonationCanBufferDestructionButNeverLiftValueAboveTheRecognisedBook() public {
        model.deposit(100e6);
        model.donate(50e6);
        model.destroyCash(30e6);

        assertEq(model.cashDeficit(), 0, "destruction inside donation surplus impaired the book");
        assertEq(model.totalAssets(), 100e6, "the buffer changed shareholder NAV");
        assertEq(model.unmanagedSurplus(), 20e6, "the surviving buffer was not isolated");

        model.destroyCash(30e6);
        assertEq(model.cashDeficit(), 10e6, "destruction beyond the buffer was hidden");
        assertEq(model.totalAssets(), 90e6, "the unbuffered subtraction was not projected");

        model.donate(10e6);
        assertEq(model.cashDeficit(), 0, "pre-reconciliation replacement did not restore backing");
        assertEq(model.totalAssets(), 100e6, "replacement exceeded the recognised book");
        assertEq(model.unmanagedSurplus(), 0, "replacement was mislabelled as surplus");
    }

    function test_principalKeepsTheMinimumSupplyUntilItIsRepaid() public {
        uint256 shares = model.deposit(20_000);
        uint256 floor = model.minimumSupply();
        assertEq(shares, 20_000_000, "fixture did not mint at the virtual par ratio");
        model.lend(10_000);

        uint256 permitted = shares - floor;
        model.redeem(permitted);
        assertEq(model.totalSupply(), floor, "exit crossed the principal-backed share floor");

        vm.expectRevert(CanonicalCashModel.InsufficientShares.selector);
        model.redeem(1);

        model.repay(10_000, STREAM);
        uint256 finalShares = model.totalSupply();
        model.redeem(finalShares);
        assertEq(model.totalSupply(), 0, "the final burn stayed locked after principal returned");
        assertEq(model.yieldRate(), 0, "the empty pool retained a live stream");
        assertEq(model.depositCapUsage(), 0, "virtual-share residue pinned cap usage");
    }

    function test_finalBurnDerecognisesTheOrphanedTailBeforeFreshEntry() public {
        uint256 shares = model.deposit(10_000);
        assertEq(shares, model.minimumSupply(), "fixture did not start at the minimum supply");

        model.addActiveGain(10_000, STREAM);
        assertEq(model.pendingYield(), 10_000, "fixture did not create the incumbent tail");
        assertEq(model.totalAssets(), 10_000, "the live tail was released before the exit");

        uint256 paid = model.redeem(shares);
        assertEq(paid, 10_000, "final incumbent did not receive the released book");
        assertEq(model.totalSupply(), 0, "final incumbent left shares behind");
        assertEq(model.rawCash(), 10_000, "tail cash did not remain physically present");
        assertEq(model.accountedCash(), 0, "orphaned tail remained recognised");
        assertEq(model.pendingYield(), 0, "orphaned tail remained recyclable");
        assertEq(model.yieldRate(), 0, "empty pool retained a live stream");
        assertEq(model.unmanagedSurplus(), 10_000, "orphaned cash was not isolated permanently");

        model.deposit(10_000);
        model.addActiveGain(10_000, STREAM);
        assertEq(model.pendingYield(), 10_000, "fresh cohort inherited the old tail");
        assertEq(model.entryAssets(), 20_000, "fresh cohort did not own exactly its new book");
        assertEq(model.unmanagedSurplus(), 10_000, "fresh activity re-recognised the old pot");
    }

    function test_zeroSupplyGainRecognisesOnlyWhatCuresSeniorClaims() public {
        uint256 shares = model.deposit(10_000);
        uint256 claim = model.service(shares);
        assertEq(claim, 10_000, "fixture did not create the exact senior claim");
        assertEq(model.totalSupply(), 0, "fixture retained a shareholder cohort");

        model.destroyCash(10_000);
        model.reconcileCashDeficit();
        assertEq(model.claimSolvencyDeficit(), 10_000, "fixture did not create claim insolvency");

        model.repay(15_000, STREAM);
        assertEq(model.accountedCash(), 10_000, "claim cure was not recognised exactly");
        assertEq(model.pendingYield(), 0, "zero-supply surplus became recyclable yield");
        assertEq(model.unmanagedSurplus(), 5_000, "surplus beyond the claim cure was recognised");

        model.claim(claim);
        assertEq(model.accountedCash(), 0, "claim payout left recognised cash");
        assertEq(model.rawCash(), 5_000, "claim payout consumed unmanaged surplus");
        assertEq(model.unmanagedSurplus(), 5_000, "post-claim surplus changed provenance");
    }

    /// @dev The canonical cash book removes the old positional-unit ceiling, but ordinary
    ///      ERC-4626 dilution is still numerically unbounded. Repeatedly losing 85% of the book
    ///      and refilling the cap multiplies supply by roughly 6.67 each time. This pure witness
    ///      stops before calling an overflowing mulDiv and records the first unreachable quote.
    function test_repeatedEightyFivePercentLossAndRefillExhaustsUnboundedShareArithmetic() public pure {
        uint256 cap = CAP;
        uint256 refill = Math.mulDiv(cap, 8_500, 10_000);
        uint256 impairedAssets = cap - refill;
        uint256 denominator = impairedAssets + 1;
        uint256 supply = cap * 1_000;
        uint256 firstUnquotableCycle;

        for (uint256 cycle = 1; cycle <= 100; cycle++) {
            uint256 numerator = supply + 1_000;
            uint256 largestSafeNumerator = Math.mulDiv(type(uint256).max, denominator, refill);
            if (numerator > largestSafeNumerator) {
                firstUnquotableCycle = cycle;
                break;
            }

            uint256 minted = Math.mulDiv(refill, numerator, denominator);
            if (supply > type(uint256).max - minted) {
                firstUnquotableCycle = cycle;
                break;
            }
            supply += minted;
        }

        assertEq(firstUnquotableCycle, 78, "loss/refill overflow boundary moved");
    }

    function test_numericReserveTapersLendingAndKeepsOneHundredTwentyEightRefillsQuotable() public {
        uint256 targetLoss = Math.mulDiv(CAP, 8_500, 10_000);
        model.deposit(CAP);

        bool lendingTapered;
        uint256 previousAvailable = type(uint256).max;
        uint256 attemptsWithLending;

        for (uint256 cycle = 0; cycle < 128; cycle++) {
            assertEq(
                model.requiredEntryAssets(),
                Math.ceilDiv(model.totalSupply() + 1_000, model.MAX_SHARES_PER_ASSET()) - 1,
                "safe required-entry calculation departed from the exact formula"
            );
            assertLe(model.requiredEntryAssets(), model.entryAssets(), "entry quotient escaped before lending");
            assertLe(model.totalSupply(), model.maximumShareSupply(), "absolute supply ceiling escaped");

            uint256 lendable = model.available();
            assertLe(lendable, previousAvailable, "numeric reserve released cash as supply grew");
            previousAvailable = lendable;

            uint256 lent = lendable < targetLoss ? lendable : targetLoss;
            if (lent < targetLoss) lendingTapered = true;
            if (lent != 0) {
                ++attemptsWithLending;
                model.lend(lent);
                model.socialiseLoss(lent);
                assertLe(
                    model.requiredEntryAssets(),
                    model.entryAssets(),
                    "full principal loss crossed the numeric entry floor"
                );
            }

            uint256 maxAssets = model.maxDeposit();
            uint256 maxShares = model.maxMint();
            assertEq(maxAssets, lent, "loss did not reopen exactly its cap headroom");
            assertEq(maxShares, model.previewDeposit(maxAssets), "max mint stopped using the quotable entry path");

            if (maxAssets != 0) {
                uint256 quotedShares = model.previewDeposit(maxAssets);
                assertLe(
                    quotedShares,
                    maxAssets * model.MAX_SHARES_PER_ASSET(),
                    "fair refill exceeded the bounded share quotient"
                );
                assertEq(model.deposit(maxAssets), quotedShares, "refill execution departed from its quote");
            }

            assertEq(model.depositCapUsage(), CAP, "refill did not restore the canonical cap book");
            assertLe(model.requiredEntryAssets(), model.entryAssets(), "fair refill broke the entry bound");
            assertLe(model.totalSupply(), model.maximumShareSupply(), "fair refill crossed the hard supply ceiling");
            assertEq(model.maxDeposit(), 0, "full cap produced a nonzero asset maximum");
            assertEq(model.maxMint(), 0, "full cap produced a nonzero share maximum");
        }

        assertTrue(lendingTapered, "numeric reserve never tapered the 85 percent loss target");
        assertGt(attemptsWithLending, 40, "fixture reached the bound before exercising geometric growth");
        assertLt(attemptsWithLending, 128, "lending never converged to the numeric reserve");
    }

    function test_externalLossAfterReconciliationNeedsExactRecognisedEntryPriceCover() public {
        uint256 required = _reachMaterialNumericReserve();
        uint256 wantedDeficit = required / 2 + 1;
        uint256 cashToKeep = required - wantedDeficit;
        model.destroyCash(model.rawCash() - cashToKeep);

        assertGt(model.cashDeficit(), 0, "external subtraction did not project a cash deficit");
        assertEq(model.maxDeposit(), 0, "unreconciled loss left deposit open");
        assertEq(model.maxMint(), 0, "unreconciled loss left mint open");
        model.reconcileCashDeficit();

        assertEq(model.cashDeficit(), 0, "reconciliation left the raw cash deficit open");
        assertEq(model.entryPriceDeficit(), wantedDeficit, "reconciliation exposed the wrong price deficit");
        assertEq(model.maxDeposit(), 0, "price deficit left deposit open");
        assertEq(model.maxMint(), 0, "price deficit left mint open");
        assertEq(model.previewDeposit(type(uint256).max), type(uint256).max, "extreme quote did not saturate");

        vm.expectRevert(CanonicalCashModel.DepositClosed.selector);
        model.deposit(1);
        vm.expectRevert(CanonicalCashModel.DepositClosed.selector);
        model.mint(1);

        uint256 partialCover = wantedDeficit - 1;
        assertEq(model.coverEntryPriceDeficit(partialCover), 1, "partial cover returned the wrong remainder");
        assertEq(model.entryPriceDeficit(), 1, "partial cover did not preserve the exact shortfall");
        assertEq(model.maxDeposit(), 0, "partial cover reopened deposit");
        assertEq(model.maxMint(), 0, "partial cover reopened mint");

        vm.expectRevert(
            abi.encodeWithSelector(CanonicalCashModel.EntryPriceDeficitExceeded.selector, uint256(2), uint256(1))
        );
        model.coverEntryPriceDeficit(2);

        assertEq(model.coverEntryPriceDeficit(1), 0, "exact cover returned a residual shortfall");
        assertEq(model.entryPriceDeficit(), 0, "exact recognised cover did not clear the price deficit");
        assertLe(model.requiredEntryAssets(), model.entryAssets(), "exact cover did not restore the quotient bound");
        assertGt(model.maxDeposit(), 0, "exact cover did not reopen deposit");
        assertGt(model.maxMint(), 0, "exact cover did not reopen mint");

        uint256 room = model.maxDeposit();
        uint256 quotedShares = model.previewDeposit(room);
        assertLe(
            model.totalSupply() + quotedShares,
            model.maximumShareSupply(),
            "reopened maximum crossed the absolute share ceiling"
        );
        assertEq(model.deposit(room), quotedShares, "reopened deposit departed from its bounded quote");
    }

    function test_maxExitRetainsThePriceReserveThroughATotalPrincipalLoss() public {
        _reachMaterialNumericReserve();
        uint256 lent = model.available() / 2;
        assertGt(lent, 0, "numeric fixture exposed no principal path");
        model.lend(lent);

        uint256 reserveBefore = model.entryPriceCashReserve();
        uint256 redeemable = model.maxRedeem();
        assertGt(reserveBefore, 0, "live principal exposed no senior price reserve");
        assertGt(redeemable, 0, "fixture exposed no executable exit");
        model.redeem(redeemable);
        assertGe(model.rawCash(), model.entryPriceCashReserve(), "max exit spent the senior price reserve");

        model.socialiseLoss(model.outstandingPrincipal());
        assertEq(model.entryPriceDeficit(), 0, "protocol exit and principal loss manufactured a price deficit");
        assertLe(
            model.requiredEntryAssets(), model.entryAssets(), "post-exit total loss crossed the bounded entry quotient"
        );
    }

    function test_epochDeliveryAtZeroSupplyPullsOnlyTheClaimDeficit() public {
        uint256 shares = model.deposit(10_000);
        uint256 claim = model.service(shares);
        model.destroyCash(model.rawCash());
        model.reconcileCashDeficit();
        assertEq(model.totalSupply(), 0, "zero-supply fixture retained shares");
        assertEq(model.claimSolvencyDeficit(), claim, "zero-supply fixture exposed the wrong claim deficit");

        uint256 deliveryClockBefore = model.lastEpochDeliveryAt();
        uint256 accrualClockBefore = model.lastYieldAccrualAt();
        uint256 recognisedBefore = model.recognisedIn();
        skip(1 days);

        uint256 accepted = model.deliverEpochYield(claim + 5_000, STREAM);
        assertEq(accepted, claim, "zero-supply epoch pulled more than the senior deficit");
        assertEq(model.rawCash(), accepted, "unaccepted zero-supply offer entered raw cash");
        assertEq(model.accountedCash(), accepted, "unaccepted zero-supply offer entered the recognised book");
        assertEq(model.recognisedIn() - recognisedBefore, accepted, "accepted epoch cash was counted incorrectly");
        assertEq(model.unmanagedSurplus(), 0, "unaccepted epoch offer became unmanaged pool cash");
        assertEq(model.pendingYield(), 0, "claim-only epoch created shareholder yield");
        assertEq(model.lastEpochDeliveryAt(), deliveryClockBefore, "partial epoch advanced the delivery clock");
        assertEq(model.lastYieldAccrualAt(), accrualClockBefore, "claim-only epoch moved the stream clock");
    }

    function test_epochDeliveryAtLowSupplyPullsOnlyTheClaimDeficit() public {
        uint256 shares = model.deposit(20_000);
        uint256 lowSupply = model.minimumSupply() - 1;
        uint256 claim = model.service(shares - lowSupply);
        model.destroyCash(model.rawCash());
        model.reconcileCashDeficit();
        assertEq(model.totalSupply(), lowSupply, "low-supply fixture moved");
        assertEq(model.claimSolvencyDeficit(), claim, "low-supply fixture exposed the wrong claim deficit");

        uint256 deliveryClockBefore = model.lastEpochDeliveryAt();
        uint256 recognisedBefore = model.recognisedIn();
        skip(1 days);

        uint256 accepted = model.deliverEpochYield(claim + 7_000, STREAM);
        assertEq(accepted, claim, "low-supply epoch pulled more than the senior deficit");
        assertEq(model.rawCash(), accepted, "unaccepted low-supply offer entered raw cash");
        assertEq(model.accountedCash(), accepted, "unaccepted low-supply offer entered the recognised book");
        assertEq(model.recognisedIn() - recognisedBefore, accepted, "low-supply accepted cash was counted incorrectly");
        assertEq(model.pendingYield(), 0, "low-supply claim cure created shareholder yield");
        assertEq(model.lastEpochDeliveryAt(), deliveryClockBefore, "partial low-supply epoch advanced the clock");
    }

    function test_claimOnlyEpochAdvancesTheDeliveryClockOnlyWhenFullyAccepted() public {
        uint256 shares = model.deposit(10_000);
        uint256 claim = model.service(shares);
        model.destroyCash(model.rawCash());
        model.reconcileCashDeficit();
        uint256 accrualClockBefore = model.lastYieldAccrualAt();
        skip(1 days);

        assertEq(model.deliverEpochYield(claim, STREAM), claim, "full claim-only epoch was not accepted");
        assertEq(model.lastEpochDeliveryAt(), block.timestamp, "fully accepted epoch did not advance its clock");
        assertEq(model.lastYieldAccrualAt(), accrualClockBefore, "claim-only epoch moved the stream clock");
    }

    function test_numericReserveCreditsEffectiveYieldAndStillSurvivesAFullPrincipalLoss() public {
        uint256 targetLoss = Math.mulDiv(CAP, 8_500, 10_000);
        model.deposit(CAP);

        for (uint256 cycle = 0; cycle < 64; cycle++) {
            uint256 lendable = model.available();
            uint256 lent = lendable < targetLoss ? lendable : targetLoss;
            if (lent == 0) break;
            model.lend(lent);
            model.socialiseLoss(lent);
            model.deposit(model.maxDeposit());
        }

        uint256 required = model.requiredEntryAssets();
        assertGt(required, 0, "fixture did not reach a positive numeric reserve");
        uint256 releasedCash = model.shareholderCash();
        uint256 yieldAmount = required / 2 + 1;

        model.addFrozenGain(yieldAmount);
        uint256 effectiveYield = model.effectiveUnreleasedYield();
        uint256 uncoveredReserve = required > effectiveYield ? required - effectiveYield : 0;
        uint256 expectedAvailable = releasedCash > uncoveredReserve ? releasedCash - uncoveredReserve : 0;

        assertEq(effectiveYield, yieldAmount, "fixture gain was not an effective frozen tail");
        assertEq(model.shareholderCash(), releasedCash, "yield changed released shareholder cash");
        assertEq(model.available(), expectedAvailable, "available ignored retained effective yield");
        assertGt(model.available(), 0, "effective yield did not release any numeric reserve");

        model.lend(model.available());
        model.socialiseLoss(model.outstandingPrincipal());
        assertGe(model.entryAssets(), required, "full principal loss crossed the yield-aware entry floor");
        assertLe(
            Math.ceilDiv(model.totalSupply() + 1_000, model.entryAssets() + 1),
            model.MAX_SHARES_PER_ASSET(),
            "post-loss entry quotient exceeded the bound"
        );
    }

    function testFuzz_requiredEntryAssetsIsExactAndFairDepositPreservesTheBound(
        uint192 supplySeed,
        uint96 extraEntrySeed,
        uint96 depositSeed
    ) public pure {
        uint256 quotientBound = 1 << 128;
        uint256 numerator = uint256(supplySeed) + 1_000;
        uint256 required = Math.ceilDiv(numerator, quotientBound) - 1;

        assertLe(numerator, quotientBound * (required + 1), "required entry book was too small");
        if (required != 0) {
            assertGt(numerator, quotientBound * required, "required entry book was not minimal");
        }

        uint256 entry = required + uint256(extraEntrySeed);
        uint256 assets = uint256(depositSeed) + 1;
        uint256 minted = Math.mulDiv(assets, numerator, entry + 1, Math.Rounding.Floor);
        uint256 numeratorAfter = numerator + minted;
        uint256 entryAfter = entry + assets;

        assertLe(
            numeratorAfter, quotientBound * (entryAfter + 1), "floor-rounded fair deposit escaped the quotient bound"
        );
        assertLe(
            Math.ceilDiv(numeratorAfter, quotientBound) - 1,
            entryAfter,
            "fair deposit raised the required book above its own payment"
        );
    }

    function testFuzz_ceilRoundedFairMintPreservesTheBound(uint192 supplySeed, uint96 extraEntrySeed, uint96 shareSeed)
        public
        pure
    {
        uint256 quotientBound = 1 << 128;
        uint256 numerator = uint256(supplySeed) + 1_000;
        uint256 required = Math.ceilDiv(numerator, quotientBound) - 1;
        uint256 entry = required + uint256(extraEntrySeed);
        uint256 shares = uint256(shareSeed) + 1;

        uint256 assets = Math.mulDiv(shares, entry + 1, numerator, Math.Rounding.Ceil);
        uint256 numeratorAfter = numerator + shares;
        uint256 entryAfter = entry + assets;

        assertLe(required, entry, "fixture started outside the quotient bound");
        assertLe(
            Math.ceilDiv(numeratorAfter, quotientBound) - 1,
            entryAfter,
            "ceil-rounded fair mint escaped the quotient bound"
        );
    }

    function testFuzz_reconciliationMatchesTheProjectedView(
        uint96 principalSeed,
        uint96 frozenSeed,
        uint96 destroyedSeed
    ) public {
        uint256 principal = bound(uint256(principalSeed), 10_000, 1_000e6);
        uint256 frozen = bound(uint256(frozenSeed), 1, principal);
        model.deposit(principal);
        model.addFrozenGain(frozen);

        uint256 destroyed = bound(uint256(destroyedSeed), 1, principal + frozen);
        model.destroyCash(destroyed);
        uint256 projectedAssets = model.totalAssets();

        model.reconcileCashDeficit();

        assertEq(model.totalAssets(), projectedAssets, "reconciliation changed the projected NAV");
        assertEq(model.depositCapUsage(), model.rawCash(), "reconciled frozen usage did not equal the stored cash book");
        assertEq(model.entryAssets(), model.depositCapUsage(), "frozen entry price omitted the surviving pot");
        assertEq(model.cashDeficit(), 0, "reconciliation left a backing deficit");
    }
}

contract CanonicalCashModelHandler is Test {
    uint256 internal constant MAX_FLOW = 1_000e6;
    uint256 internal constant STREAM = 5 days;

    CanonicalCashModel public immutable model;
    uint256 public protocolEntryDeficitMismatches;

    constructor(CanonicalCashModel model_) {
        model = model_;
    }

    function deposit(uint96 seed) external {
        uint256 maximum = model.maxDeposit();
        if (maximum == 0) return;
        uint256 top = maximum < MAX_FLOW ? maximum : MAX_FLOW;
        model.deposit(bound(uint256(seed), 1, top));
    }

    function mint(uint96 seed) external {
        uint256 maximum = model.maxMint();
        if (maximum == 0) return;
        uint256 top = maximum < MAX_FLOW * 1_000 ? maximum : MAX_FLOW * 1_000;
        model.mint(bound(uint256(seed), 1, top));
    }

    function donate(uint96 seed) external {
        model.donate(bound(uint256(seed), 1, MAX_FLOW));
    }

    function destroyCash(uint96 seed) external {
        uint256 raw = model.rawCash();
        if (raw == 0) return;
        model.destroyCash(bound(uint256(seed), 1, raw));
    }

    function reconcileCashDeficit() external {
        model.reconcileCashDeficit();
    }

    function addActiveGain(uint96 amountSeed, uint32 durationSeed) external {
        uint256 amount = bound(uint256(amountSeed), 1, MAX_FLOW);
        uint256 duration = bound(uint256(durationSeed), 1 hours, 30 days);
        model.addActiveGain(amount, duration);
    }

    function addFrozenGain(uint96 seed) external {
        model.addFrozenGain(bound(uint256(seed), 1, MAX_FLOW));
    }

    function activateFrozen(uint32 durationSeed) external {
        if (model.pendingYield() == 0 || model.yieldRate() != 0) return;
        model.activateFrozen(bound(uint256(durationSeed), 1 hours, 30 days));
    }

    function lend(uint96 seed) external {
        model.reconcileCashDeficit();
        uint256 available = model.available();
        if (available == 0 || model.totalSupply() < model.minimumSupply() || model.claimLiquidityDeficit() != 0) {
            return;
        }
        uint256 deficitBefore = model.entryPriceDeficit();
        model.lend(bound(uint256(seed), 1, available));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function repay(uint96 seed) external {
        uint256 principal = model.outstandingPrincipal();
        uint256 top = principal == 0 ? MAX_FLOW : principal > type(uint96).max / 2 ? type(uint96).max : principal * 2;
        model.repay(bound(uint256(seed), 1, top), STREAM);
    }

    function socialiseLoss(uint96 seed) external {
        model.reconcileCashDeficit();
        uint256 principal = model.outstandingPrincipal();
        if (principal == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.socialiseLoss(bound(uint256(seed), 1, principal));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function redeem(uint96 seed) external {
        model.reconcileCashDeficit();
        uint256 maximum = model.maxRedeem();
        if (maximum == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.redeem(bound(uint256(seed), 1, maximum));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function service(uint96 seed) external {
        model.reconcileCashDeficit();
        uint256 maximum = model.maxRedeem();
        if (maximum == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.service(bound(uint256(seed), 1, maximum));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function claim(uint96 seed) external {
        model.reconcileCashDeficit();
        uint256 claimable = model.totalClaimable();
        if (claimable == 0 || model.claimLiquidityDeficit() != 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.claim(bound(uint256(seed), 1, claimable));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function coverClaimDeficit(uint96 seed) external {
        model.reconcileCashDeficit();
        uint256 deficit = model.claimSolvencyDeficit();
        if (deficit == 0) return;
        model.coverClaimDeficit(bound(uint256(seed), 1, deficit));
    }

    function coverEntryPriceDeficit(uint96 seed) external {
        model.reconcileCashDeficit();
        if (model.claimLiquidityDeficit() != 0) return;
        uint256 deficit = model.entryPriceDeficit();
        if (deficit == 0) return;
        model.coverEntryPriceDeficit(bound(uint256(seed), 1, deficit));
    }

    function deliverEpochYield(uint96 offeredSeed, uint32 durationSeed) external {
        model.reconcileCashDeficit();
        if (model.totalSupply() < model.minimumSupply() && model.claimSolvencyDeficit() == 0) return;
        uint256 offered = bound(uint256(offeredSeed), 1, MAX_FLOW);
        uint256 duration = bound(uint256(durationSeed), 1 hours, 30 days);
        model.deliverEpochYield(offered, duration);
    }

    function advance(uint32 seed) external {
        skip(bound(uint256(seed), 1, 7 days));
    }

    function _recordProtocolEntryDeficit(uint256 deficitBefore) private {
        if (deficitBefore == 0 && model.entryPriceDeficit() != 0) ++protocolEntryDeficitMismatches;
    }
}

contract CanonicalCashModelInvariants is Test {
    uint256 internal constant CAP = 25_000e6;

    CanonicalCashModel internal model;
    CanonicalCashModelHandler internal handler;

    function setUp() public {
        model = new CanonicalCashModel(CAP);
        _seedNumericBoundary();
        handler = new CanonicalCashModelHandler(model);
        targetContract(address(handler));
    }

    function _seedNumericBoundary() private {
        uint256 targetLoss = Math.mulDiv(CAP, 8_500, 10_000);
        model.deposit(CAP);

        for (uint256 cycle = 0; cycle < 128; cycle++) {
            uint256 lent = model.available();
            if (lent > targetLoss) lent = targetLoss;
            if (lent == 0) break;

            model.lend(lent);
            model.socialiseLoss(lent);
            model.deposit(model.maxDeposit());
            if (model.requiredEntryAssets() != 0) return;
        }

        revert("stateful numeric-boundary fixture was not reached");
    }

    function invariant_effectiveCashNeverInventsBacking() public view {
        assertLe(model.effectiveCash(), model.accountedCash(), "effective cash exceeded the recognised balance");
        assertLe(model.effectiveCash(), model.rawCash(), "effective cash exceeded physical backing");
    }

    function invariant_theReleasedAndUnreleasedBooksPartitionGrossValue() public view {
        uint256 gross = model.effectiveCash() + model.outstandingPrincipal();
        gross = gross > model.totalClaimable() ? gross - model.totalClaimable() : 0;
        assertEq(
            model.totalAssets() + model.effectiveUnreleasedYield(), gross, "released and unreleased books diverged"
        );
    }

    function invariant_claimsAndYieldNeverBecomeLendable() public view {
        uint256 cash = model.effectiveCash();
        uint256 senior = model.totalClaimable() + model.effectiveUnreleasedYield();
        uint256 expected = cash > senior ? cash - senior : 0;
        assertEq(model.shareholderCash(), expected, "senior cash entered shareholder liquidity");
    }

    function invariant_availableWithholdsOnlyTheYieldAdjustedNumericReserve() public view {
        uint256 cash = model.shareholderCash();
        uint256 required = model.requiredEntryAssets();
        uint256 unreleased = model.effectiveUnreleasedYield();
        uint256 reserve = required > unreleased ? required - unreleased : 0;
        uint256 expected = model.totalSupply() < model.minimumSupply() || model.claimLiquidityDeficit() != 0
            ? 0
            : cash > reserve ? cash - reserve : 0;
        assertEq(model.available(), expected, "available used the wrong numeric reserve");
    }

    function invariant_capUsageUsesTheWholeStoredGrossBook() public view {
        uint256 gross = model.accountedCash() + model.outstandingPrincipal();
        gross = gross > model.totalClaimable() ? gross - model.totalClaimable() : 0;
        assertEq(model.depositCapUsage(), gross, "cap usage left the canonical book");
    }

    function invariant_rawCashConservesAllModelledFlows() public view {
        uint256 sources = model.recognisedIn() + model.donatedIn();
        uint256 sinks = model.paidOut() + model.externallyDestroyed();
        assertGe(sources, sinks, "model paid more raw cash than it received");
        assertEq(model.rawCash(), sources - sinks, "raw cash did not conserve");
    }

    function invariant_principalAlwaysHasTheMinimumRealShareSupply() public view {
        if (model.outstandingPrincipal() != 0) {
            assertGe(model.totalSupply(), model.minimumSupply(), "principal outlived the minimum supply");
        }
    }

    function invariant_unresolvedDeficitsCloseEntry() public view {
        if (model.cashDeficit() != 0 || model.claimLiquidityDeficit() != 0 || model.entryPriceDeficit() != 0) {
            assertEq(model.maxDeposit(), 0, "entry stayed open across a deficit");
            assertEq(model.maxMint(), 0, "mint stayed open across a deficit");
        }
    }

    function invariant_entryPriceDeficitAndTheQuotientBoundAreExact() public view {
        uint256 target = model.totalClaimable() + model.requiredEntryAssets();
        uint256 cash = model.effectiveCash();
        uint256 expectedDeficit = target > cash ? target - cash : 0;
        assertEq(model.entryPriceDeficit(), expectedDeficit, "entry price deficit used the wrong cash target");
        assertLe(model.totalSupply(), model.maximumShareSupply(), "absolute share ceiling escaped");

        if (expectedDeficit == 0) {
            assertLe(model.requiredEntryAssets(), model.entryAssets(), "open entry book crossed the quotient bound");
            assertLe(
                Math.ceilDiv(model.totalSupply() + 1_000, model.entryAssets() + 1),
                model.MAX_SHARES_PER_ASSET(),
                "open entry quotient exceeded its bound"
            );
        }
    }

    function invariant_entryMaximaStayInsideTheAbsoluteShareCeiling() public view {
        uint256 supply = model.totalSupply();
        uint256 maximumSupply = model.maximumShareSupply();
        uint256 shares = model.maxMint();
        assertLe(shares, maximumSupply - supply, "max mint crossed the remaining share room");

        uint256 assets = model.maxDeposit();
        if (assets != 0) {
            uint256 depositShares = model.previewDeposit(assets);
            assertGt(depositShares, 0, "positive maximum minted zero shares");
            assertLe(depositShares, maximumSupply - supply, "max deposit crossed the remaining share room");
            assertLe(model.previewMint(shares), assets, "max mint costs more than the advertised asset room");
        }
    }

    function invariant_protocolControlledCashFlowsCannotManufactureAnEntryPriceDeficit() public view {
        assertEq(
            handler.protocolEntryDeficitMismatches(),
            0,
            "a protocol-controlled exit, claim, loan or loss manufactured a price deficit"
        );
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    function invariant_claimSolvencyUsesCashAndOutstandingPrincipal() public view {
        uint256 backing = model.effectiveCash() + model.outstandingPrincipal();
        uint256 expected = model.totalClaimable() > backing ? model.totalClaimable() - backing : 0;
        assertEq(model.claimSolvencyDeficit(), expected, "claim solvency used the wrong backing");
    }

    function invariant_aRawDonationCannotExceedTheRecognisedBook() public view {
        assertLe(model.totalAssets(), model.entryAssets(), "released NAV exceeded entry NAV");
        assertLe(
            model.entryAssets(),
            model.effectiveCash() + model.outstandingPrincipal(),
            "entry NAV counted unmanaged cash"
        );
    }

    function invariant_emptyPoolCannotRetainRecyclableShareholderValue() public view {
        if (model.totalSupply() == 0 && model.outstandingPrincipal() == 0) {
            assertLe(model.accountedCash(), model.totalClaimable(), "empty pool retained shareholder cash");
            assertEq(model.pendingYield(), 0, "empty pool retained pending yield");
            assertEq(model.yieldRate(), 0, "empty pool retained an active stream");
        }
    }
}
