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

    /**
     * ── REACHABILITY GHOSTS ───────────────────────────────────────────────────────────────────
     *
     * One counter per state an invariant on the campaign contract discriminates on, so a green
     * campaign can be told apart from a campaign that never left the corner `setUp` seeds it in.
     * An earlier audit round found `CreditManager.invariants` running 128,000 calls apiece against
     * a protocol that could not reach a single borrow, for six days: none of those invariants was
     * wrong, every one still passed once debt was reachable, and what was wrong was the claim that
     * they had been TESTED.
     *
     * Every counter here is read by `test_handlerCanReachEveryStateTheInvariantsCheck` on the
     * campaign contract below. An unread ghost reads as coverage that is not there, and the
     * repository's documented-claims check fails the build on one.
     */
    uint256 public actionsObserved;
    uint256 public principalOutstandingStates;
    uint256 public claimableStates;
    uint256 public unreleasedYieldStates;
    uint256 public frozenYieldStates;
    uint256 public cashDeficitStates;
    uint256 public claimLiquidityDeficitStates;
    uint256 public entryPriceDeficitStates;
    uint256 public claimSolvencyDeficitStates;
    uint256 public belowMinimumSupplyStates;
    uint256 public emptyPoolStates;
    uint256 public openEntryStates;
    uint256 public donationsDone;
    uint256 public destructionsDone;
    uint256 public exhaustiveExitsDone;
    uint256 public claimCoversDone;
    uint256 public entryCoversDone;
    /// @dev Round 46, item 73. Entry attempts made while a deficit stood, and the ones the model
    ///      ACCEPTED. `invariant_unresolvedDeficitsCloseEntry` used to assert only that
    ///      `maxDeposit()` read zero under a deficit, which is that view's own first line and held
    ///      over arbitrary storage; the door is what an entrant meets, so the door is what is
    ///      knocked on. The first is the denominator, the second must stay zero.
    uint256 public entryProbesUnderDeficit;
    uint256 public entryAcceptedUnderDeficit;

    /**
     * The most load-bearing counter in this file.
     *
     * `invariant_protocolControlledCashFlowsCannotManufactureAnEntryPriceDeficit` asserts that
     * `protocolEntryDeficitMismatches` is zero, and until this counter existed nothing in the tree
     * could tell "no protocol flow ever manufactured a deficit" apart from "no protocol flow was
     * ever measured for one". A mismatch counter reading zero because its recorder never ran is
     * the exact shape of a vacuously green invariant, and it is the shape that hides best: the
     * assertion looks like a statement about the protocol when it is also one about the handler.
     *
     * **Round-50 item 143 asked whether this counter carries the two-population defect its
     * `LenderPool.invariants.t.sol` namesake had, and MEASURED that it does not.** There the same
     * counter was fed both by an arm running after every watched action and by an arm inside
     * `stressLossRefill`, so its tripwire was satisfied by the first deposit and said nothing about
     * the boundary; there it is now split in two. Here every increment comes through
     * `_recordProtocolEntryDeficit`, whose eight callers - `lend`, `repay`, `socialiseLoss`,
     * `redeem`, `service`, `claim`, `redeemAll` and `serviceAll` - are ONE population by
     * construction: protocol-controlled cash flows that began with no entry-price deficit, which is
     * exactly the domain the mismatch counter is about. So it stays one counter. What changed is
     * that its two assertions now say what it counts rather than "the recorder never ran", which is
     * the wording that let the sibling's defect hide.
     */
    uint256 public protocolEntryDeficitChecks;

    /// @dev Runs `_observe()` after the body, including after a guard's early `return`. That is
    ///      verified by execution rather than assumed - a Solidity `return` inside a modified
    ///      function continues into the modifier's post-code - so the census covers refused draws
    ///      as well as accepted ones, which is what makes "the guard was hit" measurable.
    modifier watched() {
        _;
        _observe();
    }

    constructor(CanonicalCashModel model_) {
        model = model_;
    }

    /**
     * 🟥 **`maxDeposit() != 0` does NOT make every amount below it depositable, and this handler
     * assumed it did for the life of the campaign.** Shares are floored, so an amount under the
     * share-rounding floor mints zero and `deposit` reverts `DepositClosed` - the same selector
     * the entry-closed guards use, which is why it reads as a closed door rather than as dust.
     *
     * It was unreachable until round 44 made the low-supply half reachable, and then
     * `invariant_theHandlerNeverDropsAFrame` caught it on the first campaign that could get there:
     * ONE revert in 14,143 calls, `0xe00c8ecd`, on a `deposit` drawn after four `serviceAll`s had
     * moved nearly the whole book into the fixed claim. Every other invariant in this file ran the
     * same sequence and reported green, because under the global `fail_on_revert = false` a
     * reverting handler call is DISCARDED - which is the entire argument for the frame guard.
     */
    function deposit(uint96 seed) external watched {
        uint256 maximum = model.maxDeposit();
        if (maximum == 0) return;
        uint256 top = maximum < MAX_FLOW ? maximum : MAX_FLOW;
        uint256 assets = bound(uint256(seed), 1, top);
        if (model.previewDeposit(assets) == 0) return;
        model.deposit(assets);
    }

    /// @dev The same asymmetry from the other side: `previewMint` rounds the cost UP, so a share
    ///      count inside `maxMint()` can still cost more assets than `maxDeposit()` allows.
    function mint(uint96 seed) external watched {
        uint256 maximum = model.maxMint();
        if (maximum == 0) return;
        uint256 top = maximum < MAX_FLOW * 1_000 ? maximum : MAX_FLOW * 1_000;
        uint256 shares = bound(uint256(seed), 1, top);
        uint256 cost = model.previewMint(shares);
        if (cost == 0 || cost > model.maxDeposit()) return;
        model.mint(shares);
    }

    function donate(uint96 seed) external watched {
        model.donate(bound(uint256(seed), 1, MAX_FLOW));
        ++donationsDone;
    }

    function destroyCash(uint96 seed) external watched {
        uint256 raw = model.rawCash();
        if (raw == 0) return;
        model.destroyCash(bound(uint256(seed), 1, raw));
        ++destructionsDone;
    }

    function reconcileCashDeficit() external watched {
        model.reconcileCashDeficit();
    }

    function addActiveGain(uint96 amountSeed, uint32 durationSeed) external watched {
        uint256 amount = bound(uint256(amountSeed), 1, MAX_FLOW);
        uint256 duration = bound(uint256(durationSeed), 1 hours, 30 days);
        model.addActiveGain(amount, duration);
    }

    function addFrozenGain(uint96 seed) external watched {
        model.addFrozenGain(bound(uint256(seed), 1, MAX_FLOW));
    }

    function activateFrozen(uint32 durationSeed) external watched {
        if (model.pendingYield() == 0 || model.yieldRate() != 0) return;
        model.activateFrozen(bound(uint256(durationSeed), 1 hours, 30 days));
    }

    function lend(uint96 seed) external watched {
        model.reconcileCashDeficit();
        uint256 available = model.available();
        if (available == 0 || model.totalSupply() < model.minimumSupply() || model.claimLiquidityDeficit() != 0) {
            return;
        }
        uint256 deficitBefore = model.entryPriceDeficit();
        model.lend(bound(uint256(seed), 1, available));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function repay(uint96 seed) external watched {
        uint256 principal = model.outstandingPrincipal();
        uint256 top = principal == 0 ? MAX_FLOW : principal > type(uint96).max / 2 ? type(uint96).max : principal * 2;
        model.repay(bound(uint256(seed), 1, top), STREAM);
    }

    function socialiseLoss(uint96 seed) external watched {
        model.reconcileCashDeficit();
        uint256 principal = model.outstandingPrincipal();
        if (principal == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.socialiseLoss(bound(uint256(seed), 1, principal));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function redeem(uint96 seed) external watched {
        model.reconcileCashDeficit();
        uint256 maximum = model.maxRedeem();
        if (maximum == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.redeem(bound(uint256(seed), 1, maximum));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function service(uint96 seed) external watched {
        model.reconcileCashDeficit();
        uint256 maximum = model.maxRedeem();
        if (maximum == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.service(bound(uint256(seed), 1, maximum));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function claim(uint96 seed) external watched {
        model.reconcileCashDeficit();
        uint256 claimable = model.totalClaimable();
        if (claimable == 0 || model.claimLiquidityDeficit() != 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.claim(bound(uint256(seed), 1, claimable));
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function coverClaimDeficit(uint96 seed) external watched {
        model.reconcileCashDeficit();
        uint256 deficit = model.claimSolvencyDeficit();
        if (deficit == 0) return;
        model.coverClaimDeficit(bound(uint256(seed), 1, deficit));
        ++claimCoversDone;
    }

    function coverEntryPriceDeficit(uint96 seed) external watched {
        model.reconcileCashDeficit();
        if (model.claimLiquidityDeficit() != 0) return;
        uint256 deficit = model.entryPriceDeficit();
        if (deficit == 0) return;
        model.coverEntryPriceDeficit(bound(uint256(seed), 1, deficit));
        ++entryCoversDone;
    }

    function deliverEpochYield(uint96 offeredSeed, uint32 durationSeed) external watched {
        model.reconcileCashDeficit();
        if (model.totalSupply() < model.minimumSupply() && model.claimSolvencyDeficit() == 0) return;
        uint256 offered = bound(uint256(offeredSeed), 1, MAX_FLOW);
        uint256 duration = bound(uint256(durationSeed), 1 hours, 30 days);
        model.deliverEpochYield(offered, duration);
    }

    function advance(uint32 seed) external watched {
        skip(bound(uint256(seed), 1, 7 days));
    }

    /**
     * ── THE EXHAUSTIVE DRAWS, AND WHY A `uint96` SEED IS NOT ONE ──────────────────────────────
     *
     * `redeem`, `service` and `destroyCash` each draw `bound(uint256(seed), 1, maximum)` from a
     * `uint96`. Where `maximum` is small that is a uniform draw over the whole range. Where it is
     * not, it is a uniform draw over a range whose TOP the seed cannot reach, and the top is the
     * only end that matters here.
     *
     * MEASURED on the post-`setUp` fixture, which is what makes this a defect rather than a
     * stylistic note: `totalSupply` is 8.69e38 and `maxRedeem()` is 8.69e38, against a `uint96`
     * ceiling of 7.92e28. One `redeem` can therefore burn at most 9.1e-11 of the supply, 500 of
     * them cannot move it by a millionth, and every guard below `MIN_SUPPLY` is unreachable by
     * construction rather than by luck. `destroyCash` has the same shape from the other side:
     * `rawCash` is 2.5e10, so "destroy all of it" is one draw in 2.5e10.
     *
     * These three pass the maximum directly. A 64-run unseeded census before they existed reached
     * none of `claimLiquidityDeficit`, `claimSolvencyDeficit` or an empty pool in 32,000 calls;
     * the campaign was not vacuous, but a third of what its invariants discriminate on was
     * outside the handler's reach. The counters they move are asserted in the tripwire.
     */
    function redeemAll() external watched {
        model.reconcileCashDeficit();
        uint256 maximum = model.maxRedeem();
        if (maximum == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.redeem(maximum);
        ++exhaustiveExitsDone;
        _recordProtocolEntryDeficit(deficitBefore);
    }

    function serviceAll() external watched {
        model.reconcileCashDeficit();
        uint256 maximum = model.maxRedeem();
        if (maximum == 0) return;
        uint256 deficitBefore = model.entryPriceDeficit();
        model.service(maximum);
        ++exhaustiveExitsDone;
        _recordProtocolEntryDeficit(deficitBefore);
    }

    /// @dev External destruction is not protocol-controlled, so it deliberately does NOT record
    ///      an entry-deficit mismatch: manufacturing a price deficit is exactly what an external
    ///      loss is allowed to do, and `invariant_unresolvedDeficitsCloseEntry` is what states
    ///      the consequence.
    function destroyAllCash() external watched {
        uint256 raw = model.rawCash();
        if (raw == 0) return;
        model.destroyCash(raw);
        ++destructionsDone;
    }

    /// @dev The door under a deficit. Every other entry action returns early on `maxDeposit() == 0`
    ///      and so never asks the model to refuse; this one asks, for one asset-wei and one share,
    ///      whenever any of the three deficits stands. An acceptance is the finding; a refusal
    ///      with either selector is the designed answer and is not distinguished here.
    function probeEntryUnderDeficit() external watched {
        if (model.cashDeficit() == 0 && model.claimLiquidityDeficit() == 0 && model.entryPriceDeficit() == 0) return;
        ++entryProbesUnderDeficit;
        try model.deposit(1) {
            ++entryAcceptedUnderDeficit;
        } catch {}
        try model.mint(1) {
            ++entryAcceptedUnderDeficit;
        } catch {}
    }

    function _recordProtocolEntryDeficit(uint256 deficitBefore) private {
        if (deficitBefore != 0) return;
        ++protocolEntryDeficitChecks;
        if (model.entryPriceDeficit() != 0) ++protocolEntryDeficitMismatches;
    }

    /**
     * The whole state census, evaluated once at the tail of every action.
     *
     * 🟥 **No `assert*` may ever appear in here, and nothing in here may revert.** The rule behind
     * that is ASYMMETRIC and must not be restated in either blanket form - MEASURED on forge
     * 1.8.1, 2026-09-09. A THREE-argument forge-std assertion inside a handler reverts with the
     * assertion's own message, is indistinguishable from an ordinary business revert, and under
     * the global `fail_on_revert = false` is DISCARDED SILENTLY. A TWO-argument one reverts with a
     * string beginning "assertion failed", which forge 1.8.1 picks out of the discarded frame and
     * reports as `failure_type: "handler_assertion"`, naming the handler and the selector.
     * 🟥 **A MESSAGE IS SUFFICIENT to make an in-handler assertion invisible; ITS ABSENCE IS NOT
     * SUFFICIENT to guarantee reporting** - a message-less `assertEq` inside
     * `RegistryHandler.register`'s catch block went unreported at
     * `(runs: 256, calls: 128000, reverts: 62346)`, and THAT READING IS UNEXPLAINED. Position, and
     * possibly the campaign, is a third variable nobody has isolated, so the ban here is stated
     * over `assert*` as a whole rather than over the messaged form only. Every assertion this
     * campaign would want here carries a message anyway, which is the suppressing half.
     * `CreditHandler.firstBrokenProperty` in `CreditManager.invariants.t.sol` carries the fullest
     * statement of the same rule.
     *
     * Reads and `++` only; every assertion over these counters lives on the campaign contract.
     *
     * Two cost decisions, stated rather than left to be re-derived:
     *
     *  - `maxDeposit()` is NOT called. It runs `previewMint` and `previewDeposit`, and this
     *    function runs on all 128,000 calls of every one of the campaign's invariants. What
     *    `openEntryStates` counts instead is the cheap conjunction of `maxDeposit`'s four early
     *    returns that are already read here anyway - the three deficits and cap headroom. **That
     *    is a necessary, not a sufficient, condition**: it cannot see the share-room and
     *    `previewDeposit(headroom) == 0` arms, so the ghost can over-count relative to the branch
     *    `invariant_entryMaximaStayInsideTheAbsoluteShareCeiling` actually takes. The tripwire
     *    closes that gap by asserting the exact `model.maxDeposit() != 0` deterministically.
     *  - `effectiveUnreleasedYield()` IS called, because nothing cheaper distinguishes the state
     *    `invariant_claimsAndYieldNeverBecomeLendable` and `invariant_availableWithholds...` turn
     *    on: `pendingYield != 0` is not the same predicate once a cash deficit has eaten it.
     */
    function _observe() private {
        ++actionsObserved;

        uint256 supply = model.totalSupply();
        uint256 principal = model.outstandingPrincipal();
        if (principal != 0) ++principalOutstandingStates;
        if (model.totalClaimable() != 0) ++claimableStates;
        if (model.effectiveUnreleasedYield() != 0) ++unreleasedYieldStates;
        if (model.pendingYield() != 0 && model.yieldRate() == 0) ++frozenYieldStates;
        if (supply < model.minimumSupply()) ++belowMinimumSupplyStates;
        if (supply == 0 && principal == 0) ++emptyPoolStates;

        uint256 cash = model.cashDeficit();
        uint256 liquidity = model.claimLiquidityDeficit();
        uint256 entry = model.entryPriceDeficit();
        if (cash != 0) ++cashDeficitStates;
        if (liquidity != 0) ++claimLiquidityDeficitStates;
        if (entry != 0) ++entryPriceDeficitStates;
        if (model.claimSolvencyDeficit() != 0) ++claimSolvencyDeficitStates;

        if (cash == 0 && liquidity == 0 && entry == 0 && model.depositCapUsage() < model.depositCap()) {
            ++openEntryStates;
        }
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

    /**
     * ── ROUND-46: EIGHT OF THE FIFTEEN WERE IDENTITIES, AND THE ROUND-44 REPAIR ADDED TWO ──────
     *
     * 🟥 **Round 44 struck three assertions of the shape `min(a, b) <= a` and replaced one of them
     * with `min(a, r) + max(a - r, 0) == a`, which is the same shape with the clamp written
     * out.** Audit round 45 wrote arbitrary `uint120` values into every slot these invariants
     * read - `rawCash`, `accountedCash`, `outstandingPrincipal`, `totalClaimable`, `totalSupply`,
     * the pot, the rate and both clocks, states no handler reaches and states that are not
     * self-consistent - and re-ran each assertion verbatim. Eight of the fifteen held over all of
     * it: the effective-cash pair, all three legs of the gross-value partition (its own comment
     * called the first "an identity" and the other two "the content"; all three are), the
     * `shareholderCash`, `available`, `depositCapUsage` and `claimSolvencyDeficit` formulas, the
     * `entryPriceDeficit` formula with its quotient bound, and `maxDeposit`'s own first line under
     * a deficit.
     *
     * An assertion that holds over uint120^n of inconsistent storage is a statement about the
     * function's source text, not about the model's behaviour. Those are regression pins on text,
     * and they are kept as exactly that in `LenderPoolFormulaPins.t.sol`, over `vm.store`d
     * storage, labelled. What stands here is what some reachable state could falsify.
     */
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

    /// @notice An unresolved deficit closes the entry DOOR, not only the entry view.
    /// @dev Round 46: the door half is `entryAcceptedUnderDeficit`, moved by
    ///      `probeEntryUnderDeficit` whenever any deficit stands (`entryProbesUnderDeficit` is its
    ///      denominator, asserted in the tripwire). The view half restates `maxDeposit`'s first
    ///      line and is kept only because ERC-4626 makes that view a MUST; alone it was the whole
    ///      invariant and held over arbitrary storage.
    function invariant_unresolvedDeficitsCloseEntry() public view {
        assertEq(handler.entryAcceptedUnderDeficit(), 0, "the model accepted an entry across a deficit");
        if (model.cashDeficit() != 0 || model.claimLiquidityDeficit() != 0 || model.entryPriceDeficit() != 0) {
            assertEq(model.maxDeposit(), 0, "entry stayed open across a deficit");
            assertEq(model.maxMint(), 0, "mint stayed open across a deficit");
        }
    }

    /// @notice Real share supply never crosses the absolute ceiling.
    /// @dev A GUARD, not coverage, kept from `invariant_entryPriceDeficitAndTheQuotientBoundAreExact`
    ///      as its one clause a `vm.store` could break; the formula and the quotient bound beside
    ///      it are pins now. The seeded fixture sits at 8.69e38 shares against a ceiling of
    ///      2^128 x 250,001e6 - 1000, so nothing the walk does approaches it.
    function invariant_realSupplyNeverCrossesTheAbsoluteCeiling() public view {
        assertLe(model.totalSupply(), model.maximumShareSupply(), "absolute share ceiling escaped");
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

    /**
     * 🟥 **This invariant's NAME was false about its own body until round 44.** It said a raw
     * donation cannot exceed the recognised book and then asserted `x <= x + y` and
     * `subOrZero(x, c) <= x`, neither of which any state can falsify, and it never read
     * `donatedIn` at all. A donation was the one thing it was not about.
     *
     * The line below is the real statement, and it is about donation by exclusion:
     * `recognisedIn` counts every inflow the model AGREED to recognise and `paidOut` every
     * outflow, while `donate` credits `rawCash` and `donatedIn` only. So a recognised book larger
     * than net recognised flows means donated cash got in. Crediting `accountedCash` inside
     * `donate` turns this red immediately, which is the neuter that proves it.
     *
     * Round 44 kept the old tautology as a second line "marked, so nobody counts it twice".
     * Round 46 struck it: a marked tautology is still a line somebody counts.
     */
    function invariant_aRawDonationCannotExceedTheRecognisedBook() public view {
        assertLe(
            model.accountedCash() + model.paidOut(),
            model.recognisedIn(),
            "the recognised book outgrew the flows that were recognised into it"
        );
    }

    function invariant_emptyPoolCannotRetainRecyclableShareholderValue() public view {
        if (model.totalSupply() == 0 && model.outstandingPrincipal() == 0) {
            assertLe(model.accountedCash(), model.totalClaimable(), "empty pool retained shareholder cash");
            assertEq(model.pendingYield(), 0, "empty pool retained pending yield");
            assertEq(model.yieldRate(), 0, "empty pool retained an active stream");
        }
    }

    /**
     * ── THE TRIPWIRE ──────────────────────────────────────────────────────────────────────────
     *
     * @notice Proves the nine invariants above (fifteen until round 46 struck six identities) are
     *         checking states this handler can actually reach, rather than passing over a fixture
     *         that never leaves the corner `setUp` seeds it in.
     *
     * @dev Every handler action returns early on a guard it cannot satisfy, which it has to: most
     *      random call sequences are meaningless and must not fail a run. The cost is that a
     *      handler which could never reach a deficit, a fixed claim or an empty pool at all would
     *      still report nine green invariants having exercised none of them. An earlier audit
     *      round found exactly that here: seven invariants, 128,000 calls apiece, six days, and a
     *      protocol that could not reach a single borrow.
     *
     *      **It is a normal `test_` rather than an `afterInvariant` on purpose, and that is a
     *      measurement rather than a preference.** `afterInvariant` fires once per run against
     *      counters the runner resets between runs, so as a floor it demands that every behaviour
     *      occur in EVERY random 500-call sequence and fails on the first unlucky one - measured
     *      on the sibling `LiquidationAuction` campaign at `0 <= 0`, one run in 256. There is no
     *      cross-run accumulator either: the runner reverts to the post-`setUp` snapshot between
     *      runs, so nothing in EVM state survives to be totalled. Round 44 built that floor anyway
     *      as a MEASURING INSTRUMENT, ran it 64 times with `runs = 1`, and threw it away. **Do not
     *      ship it.** The vacuity guard is deliberately two halves, neither of them a campaign
     *      floor: this test proves the transitions are reachable at all, and
     *      `invariant_theHandlerNeverDropsAFrame` proves the fuzzer is not discarding the ones it
     *      reaches.
     *
     *      🟥 **This test proves reachability. It does NOT prove the CAMPAIGN reaches anything,
     *      and the two were measured separately.** Both censuses are unseeded - `foundry.toml`
     *      sets no seed and CI runs a bare `forge test` - forge 1.8.1, `depth = 500`, sampled as
     *      64 independent forced single runs at `8b730d8`, 32,000 calls in total each.
     *
     *      BEFORE the three exhaustive draws, over eighteen actions: nine of the fifteen counters
     *      moved in every run, `claimableStates` in 44 of 64, `entryPriceDeficitStates` in **one**
     *      of 64, and `claimLiquidityDeficitStates`, `claimSolvencyDeficitStates`,
     *      `belowMinimumSupplyStates` and `emptyPoolStates` in **none of 32,000 calls**. The
     *      campaign was not vacuous. A third of what its invariants discriminate on was outside
     *      its handler's reach, and the cause was the `uint96` seeds rather than the fixture.
     *
     *      AFTER, over twenty-one: every one of them moves. Twelve counters in 64 of 64,
     *      `unreleasedYieldStates` 62, `frozenYieldStates` 60, `principalOutstandingStates` 52,
     *      `belowMinimumSupplyStates` 34, `emptyPoolStates` 31, and `entryCoversDone` **8 of 64**.
     *      🟥 **The last two are not a clear majority and are reported rather than rounded up.**
     *      An empty pool needs several exhaustive exits with no lend, loss or claim interleaved,
     *      and the entry-price cover needs recognised cash below `requiredEntryAssets` with no
     *      claim gap, which is a narrow corner of the model's own arithmetic rather than a defect.
     *      Re-measure rather than quote: these are frequencies of an unseeded walk, not properties
     *      of the tree.
     *
     *      MEASURED at `dfd987d`, 2026-09-04 (audit round 48, item 51), the same instrument
     *      rebuilt and thrown away again: 64 forced single runs, `depth = 500`, unseeded, forge
     *      1.8.1, over the twenty-two actions the handler now has (`probeEntryUnderDeficit` is
     *      round 46's). The fixture HAD moved since `8b730d8` - #392, #405 and #406 all touch this
     *      file or the model - so this is a re-measurement, not a re-sample. Fourteen counters in
     *      64 of 64, `frozenYieldStates` 59, `principalOutstandingStates` 53,
     *      `belowMinimumSupplyStates` 35, `emptyPoolStates` 33, and `entryCoversDone` **6 of 64**
     *      (at most two covers in any run). The two violation counters,
     *      `entryAcceptedUnderDeficit` and `protocolEntryDeficitMismatches`, read 0 in 64 of 64,
     *      which is what they must read and is not reach. Same shape as round 44, within
     *      sampling: no state fell to zero, and the two narrow corners are still below a
     *      majority. Re-measure rather than quote.
     */
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        // ── the numeric-boundary corner the fixture is seeded in ──────────────────────
        // `setUp` leaves `totalSupply` at 8.69e38, the deposit cap FULL and every deficit at
        // zero, so entry is closed and the only thing that reopens it is a loss freeing cap
        // headroom. Asserted rather than assumed, because if `_seedNumericBoundary` ever stops
        // landing here the rest of this test would quietly measure a different fixture.
        assertEq(model.maxDeposit(), 0, "premise: the seeded fixture starts with entry closed");
        assertGt(model.requiredEntryAssets(), 0, "premise: the seeded fixture is at the numeric boundary");

        handler.lend(uint96(1_000e6));
        assertGt(handler.principalOutstandingStates(), 0, "principal was never reached");
        assertGt(
            handler.protocolEntryDeficitChecks(),
            0,
            "the entry-deficit recorder never ran on a protocol-controlled cash flow"
        );

        handler.socialiseLoss(uint96(1_000e6));
        assertGt(handler.openEntryStates(), 0, "entry never reopened");
        // The ghost counts a cheap four-clause necessary condition, not `maxDeposit()` itself.
        // This is the assertion that closes the gap between the two.
        assertGt(model.maxDeposit(), 0, "the cheap open-entry conjunction over-counted");
        handler.deposit(uint96(1_000e6));
        handler.mint(uint96(1_000e6));

        // Both yield shapes, which are different states rather than one: a frozen pot is fully
        // unreleased with no rate, and `invariant_availableWithholds...` reads the difference.
        handler.addActiveGain(uint96(1_000e6), uint32(5 days));
        assertGt(handler.unreleasedYieldStates(), 0, "streamed yield was never reached");
        handler.addFrozenGain(uint96(1_000e6));
        assertGt(handler.frozenYieldStates(), 0, "frozen yield was never reached");
        handler.activateFrozen(uint32(5 days));
        handler.deliverEpochYield(uint96(1_000e6), uint32(5 days));
        handler.advance(uint32(7 days));

        // External destruction and the raw donation, which are the two terms
        // `invariant_rawCashConservesAllModelledFlows` quantifies over.
        handler.destroyCash(uint96(1_000e6));
        assertGt(handler.destructionsDone(), 0, "external destruction was never reached");
        assertGt(handler.cashDeficitStates(), 0, "a cash deficit was never reached");
        // Round 46: the door under that deficit, knocked on rather than read.
        handler.probeEntryUnderDeficit();
        assertGt(handler.entryProbesUnderDeficit(), 0, "entry was never attempted under a deficit");
        assertEq(handler.entryAcceptedUnderDeficit(), 0, "the model accepted an entry under a deficit");
        handler.donate(uint96(1_000e6));
        assertGt(handler.donationsDone(), 0, "a raw donation was never reached");
        handler.reconcileCashDeficit();

        // ── the entry-price corner, and why it needs the whole book drained ───────────
        // `entryPriceDeficit != 0` with `claimLiquidityDeficit == 0` is the only state in which
        // `coverEntryPriceDeficit` can run at all, and on this fixture it needs recognised cash
        // BELOW `requiredEntryAssets`, which is 2. Lending stops at exactly the reserve, so the
        // last two units have to be destroyed. The census reached this in 1 run of 64.
        uint256 lendable = model.available();
        assertLe(lendable, type(uint96).max, "fixture lendable cash exceeded the handler seed");
        handler.lend(uint96(lendable));
        handler.socialiseLoss(uint96(model.outstandingPrincipal()));
        assertEq(model.available(), 0, "the drain left lendable cash behind");
        handler.destroyCash(uint96(model.rawCash()));
        assertGt(handler.entryPriceDeficitStates(), 0, "an entry price deficit was never reached");
        assertEq(model.claimLiquidityDeficit(), 0, "the entry-price corner was contaminated by a claim gap");
        handler.coverEntryPriceDeficit(uint96(model.entryPriceDeficit()));
        assertGt(handler.entryCoversDone(), 0, "the entry-price repair door was never opened");
        assertEq(model.entryPriceDeficit(), 0, "an exact cover left a deficit");

        // ── the senior claim, and all three senior deficits at once ───────────────────
        handler.serviceAll();
        assertGt(handler.exhaustiveExitsDone(), 0, "the exhaustive exit was never reached");
        assertGt(handler.claimableStates(), 0, "a fixed claim was never reached");
        handler.redeem(uint96(1_000e6));
        handler.service(uint96(1_000e6));

        handler.destroyAllCash();
        assertGt(handler.claimLiquidityDeficitStates(), 0, "a claim liquidity deficit was never reached");
        assertGt(handler.claimSolvencyDeficitStates(), 0, "a claim solvency deficit was never reached");

        uint256 solvency = model.claimSolvencyDeficit();
        assertLe(solvency, type(uint96).max, "fixture claim exceeded the handler seed");
        handler.coverClaimDeficit(uint96(solvency));
        assertGt(handler.claimCoversDone(), 0, "the claim repair door was never opened");
        assertEq(model.claimSolvencyDeficit(), 0, "an exact claim cover left a deficit");
        handler.claim(uint96(model.totalClaimable()));
        assertEq(model.totalClaimable(), 0, "the fixed claim was never collected");

        // ── the descent to an empty pool ──────────────────────────────────────────────
        // 🟥 **This is the half a bounded seed cannot do.** One `redeem` can burn at most
        // `type(uint96).max` shares out of ~9e38, so 500 of them cannot move the supply by a
        // millionth, and both `invariant_emptyPoolCannotRetainRecyclableShareholderValue` and the
        // below-minimum branch of `invariant_availableWithholds...` sit behind a floor the walk
        // cannot descend to. Passing `maxRedeem()` directly divides the supply by roughly the
        // cash on hand each time, so the descent is five cycles rather than ninety halvings.
        for (uint256 cycle = 0; cycle < 16 && model.totalSupply() != 0; ++cycle) {
            handler.repay(uint96(1_000e6));
            handler.advance(uint32(7 days));
            handler.redeemAll();
        }
        assertEq(model.totalSupply(), 0, "the exhaustive exit could not empty the pool");
        assertGt(handler.belowMinimumSupplyStates(), 0, "the below-minimum supply regime was never reached");
        assertGt(handler.emptyPoolStates(), 0, "an empty pool was never reached");

        // Nothing above may have manufactured a price deficit through a protocol-controlled flow,
        // and the recorder that decides it must have run - which is the whole point of counting
        // the checks as well as the mismatches.
        assertGt(
            handler.protocolEntryDeficitChecks(),
            0,
            "the entry-deficit recorder never ran on a protocol-controlled cash flow"
        );
        assertEq(handler.protocolEntryDeficitMismatches(), 0, "a protocol flow manufactured a price deficit");
        assertGt(handler.actionsObserved(), 0, "the state census never ran");
    }
}
