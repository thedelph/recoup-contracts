// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev The canonical accounting additions are deliberately implementation-specific rather than
///      part of ILenderPool. Keeping their test interface local makes that API boundary explicit.
interface ICanonicalLenderPool {
    function depositCapUsage() external view returns (uint256);
    function unmanagedSurplus() external view returns (uint256);
    function cashDeficit() external view returns (uint256);
    function claimLiquidityDeficit() external view returns (uint256);
    function claimSolvencyDeficit() external view returns (uint256);
    function entryPriceDeficit() external view returns (uint256);
    function minimumEntryAssets() external view returns (uint256);
    function maximumShareSupply() external view returns (uint256);
    function reconcileCashDeficit() external returns (uint256 lost, uint256 yieldWrittenOff);
    function coverClaimDeficit(uint256 amount) external returns (uint256 remaining);
    function coverEntryPriceDeficit(uint256 amount) external returns (uint256 remaining);
}

/// @notice Stateful production-pool driver for the canonical-cash F3 design.
/// @dev Principal-unit ghosts and the lowered-ceiling campaign are gone with their production
///      ledger. The handler varies raw donations and external cash destruction alongside every
///      ordinary pool flow, while retaining the request, claim, impairment, pause, price and
///      conservation surfaces that do not depend on a principal representation.
///
///      **Round 46, item 73: every call whose precondition this handler has already established
///      from a quoted maximum is made BARE.** Audit round 45 measured that the 22 `try` sites
///      this file used to carry swallowed a maximum that could not be executed - the round-22 F2
///      class - so that `invariant_theHandlerNeverDropsAFrame` could not see it and
///      `withdrawalsDone` silently under-counted (bare handler red on `ERC20InsufficientBalance`,
///      this handler `reverts: 0`, same neuter). Eighteen sites are now bare: `withdraw`, `redeem`
///      and request service at or below their maxima, `lend` at or below `available()`, the three
///      `stressLossRefill` legs, both cover doors, reconciliation, cancellation, `impair`,
///      `releaseImpairment`, `socialiseLoss`, `recoverLoss`, `transfer`, `claim` behind a
///      liquidity-deficit pre-check and `requestWithdrawal` behind a no-live-request pre-check.
///      A refusal at any of them drops the frame and the frame guard names the selector.
///
///      The four doors the handler drives WITHOUT a quoted maximum (`deposit`, `mint`,
///      `repayPrincipal`, `distributeYield`) keep their `try`, and the catch is typed: before the
///      call the handler predicts the refusal from the pool's PUBLIC views alone (`paused()`, the
///      three deficits, `maxDeposit`, `maxMint`, `previewDeposit`, `claimSolvencyDeficit`,
///      `totalAssets`, `totalSupply`), in the order the door's own docstring says it refuses. An
///      outcome that differs from the prediction in either direction - a refusal the views did
///      not predict, a refusal with the wrong selector, or an acceptance where a refusal was
///      predicted - is counted in `unpredictedOutcomes` and the first pair of selectors is kept.
///      That is the ERC-4626 executability property (a maximum MUST be a bound) plus the
///      documented error ordering, asserted at the door rather than restated from the view.
contract CanonicalLenderHandler is Test {
    /// @dev Round 46, item 73: raised from 4 to 16. At 4 the campaign completed 0 to 14 cycles per
    ///      run against the roughly 32 a 6.67x-per-cycle walk needs to lift `minimumEntryAssets`
    ///      off zero, so `numericReserveStatesReached` read 0 in 16 of 16 census runs and the
    ///      numeric-reserve regime was guarded by the deterministic tripwire alone.
    uint256 private constant MAX_STRESS_CYCLES_PER_ACTION = 16;
    uint256 private constant MAX_STRESS_CYCLES_TOTAL = 128;
    uint256 private constant MIN_SUPPLY_FOR_YIELD = (10 ** 3) * Config.BPS;

    LenderPool public immutable pool;
    ICanonicalLenderPool public immutable canonical;
    MockUSDC public immutable usdc;
    address public immutable owner;
    address public immutable creditManager;
    address public immutable epochHarvester;
    address public immutable destructionSink;

    address[] public actors;
    address[] public borrowers;

    uint256 public totalMinted;
    uint256 public depositsDone;
    uint256 public mintsDone;
    uint256 public withdrawalsDone;
    uint256 public redeemsDone;
    uint256 public donationsDone;
    uint256 public destructionsDone;
    uint256 public reconciliationsDone;
    uint256 public lendsDone;
    uint256 public repaysDone;
    uint256 public yieldsDone;
    uint256 public recoveriesDone;
    uint256 public lossesDone;
    uint256 public requestsDone;
    uint256 public cancellationsDone;
    uint256 public servicesDone;
    uint256 public claimsDone;
    uint256 public coversDone;
    uint256 public entryCoversDone;
    uint256 public lossRefillCyclesDone;
    uint256 public numericReserveStatesReached;
    uint256 public lendTapersReached;
    /// @dev Round 45, item 55. A deposit the pool ACCEPTED against zero shares. Must stay 0: the
    ///      round-22 guard in `_deposit` refuses that deposit with `ZeroAmount()`, and stock
    ///      OpenZeppelin would take the assets instead. Counted from the success arm of every
    ///      handler deposit, so a neuter of that guard has somewhere to land.
    uint256 public zeroShareDeposits;
    /// @dev Round 45, item 55. Actions after which entry was open (`maxDeposit != 0`) while one
    ///      asset-wei bought nothing (`previewDeposit(1) == 0`): the sub-floor state, where the
    ///      entry price is above one asset-wei per share. A campaign REACH figure and never a
    ///      property - reported as one unseeded 256x500 campaign, not asserted.
    uint256 public subFloorStatesSeen;
    uint256 public transfersDone;
    uint256 public impairmentsDone;
    uint256 public releasesDone;
    uint256 public pausesDone;
    uint256 public unpausesDone;
    uint256 public timeAdvances;

    /**
     * ── ROUND-46 REACH GHOSTS, ONE PER STATE THE ROUND-45 CAMPAIGN DID NOT WALK ────────────────
     *
     * Audit round 45's census of its own handler, 16 independent single runs of 500 calls: nothing
     * could write `insuranceCover` or `unplacedLoss`, so `exitReserve`'s insurance netting and
     * its backlog arm - "three steps, and the order of them is the design" - ran in no campaign;
     * every `deposit`, `withdraw` and `redeem` used receiver == owner == caller; no operator, no
     * `claimFor`, no allowance; and no draw ever landed on the exact top of a range, so the states
     * behind an exhaustive exit, request or destruction were reached by the tripwire alone.
     */
    uint256 public depositForDone;
    uint256 public allowanceExitsDone;
    uint256 public operatorServicesDone;
    uint256 public claimForsDone;
    uint256 public exhaustiveExitsDone;
    uint256 public exhaustiveRequestsDone;
    uint256 public exhaustiveServicesDone;
    uint256 public fullDestructionsDone;
    uint256 public lossReserveWrites;
    /// @dev `exitReserve()` strictly between zero and `outstandingPrincipal`: a mark that is not a
    ///      whole-book mark, which is the only shape in which the reserve's arithmetic is visible.
    uint256 public partialMarkStates;
    /// @dev `insuranceCover != 0` while a mark stands: the netting step of `exitReserve`.
    uint256 public nettedMarkStates;
    /// @dev `unplacedLoss != 0` with principal out: the backlog step of `exitReserve`.
    uint256 public backlogStates;
    /// @dev Entry attempts made while the pool was paused. The denominator for the two refusal
    ///      ghosts below; a paused door nobody knocks on is not a tested door.
    uint256 public pausedEntryAttempts;
    /// @dev Refusals that matched their prediction. The denominator for `unpredictedOutcomes`.
    uint256 public predictedRefusals;

    uint256 public donationViewMismatches;
    uint256 public otherRequestMutations;
    uint256 public serviceAccountingMismatches;
    uint256 public lifetimeLossFell;
    uint256 public lifetimeLossRoseWithoutLossAction;
    uint256 public principalRoseWithoutLend;
    uint256 public protocolEntryDeficitMismatches;

    /**
     * -- coverage ghosts, audit round 48 item 116: the LEGAL half of each transition a violation
     *    counter in this handler counts the illegal half of. `assertEq(violations, 0)` is
     *    satisfied most easily by never reaching the transition, so each ghost is incremented in
     *    the same observation as its partner and asserted `> 0` by a reachability tripwire on
     *    the campaign contract, never in `afterInvariant`.
     */
    /// @dev Partner of `pauseMovedAnExitMaximum`: toggles across which at least one lender had a
    ///      non-zero exit maximum to move. An empty pool compares 0 == 0 and proves nothing.
    uint256 public pauseTogglesWithALiveExitMaximum;
    /// @dev Partner of `lifetimeLossFell` and `lifetimeLossRoseWithoutLossAction`: the third arm
    ///      of that partition, a rise across an action that socialised a loss.
    uint256 public lifetimeLossRoseOnALoss;
    /// @dev Partner of `principalRoseWithoutLend`: a rise across an action that lent.
    uint256 public principalRoseOnALend;
    /// @dev Partner of `lossHeadroomMismatches`: recorder runs whose expected headroom actually
    ///      moved (`absorbed + deficitBefore != 0`). `_recordLossHeadroom` runs on every
    ///      `socialiseLoss` call and `lossesDone` counts only non-zero absorptions, so neither
    ///      proves the comparison was ever made against a moving quantity.
    uint256 public lossHeadroomChecks;
    /// @dev Partner of `protocolEntryDeficitMismatches`: observations that started with no entry
    ///      price deficit and therefore compared. `CanonicalCashModel.t.sol` has carried this
    ///      partner since round 46; this campaign did not.
    ///
    /// 🟥 **ONE counter used to stand here and it was fed by TWO POPULATIONS, which made its
    /// tripwire satisfiable by the population nobody was worried about.** Round-50 item 143.
    /// `_settle` runs after EVERY watched action and increments whenever the observation started
    /// with no entry deficit - which is the ordinary state, so the very first `deposit` in the
    /// deterministic walk pushed it above zero. `_recordProtocolEntryDeficit`, the arm that runs
    /// inside `stressLossRefill`'s lend/socialise cycles, is the one that reaches the numeric
    /// boundary where a protocol flow could actually manufacture a deficit. With both feeding one
    /// counter, `assertGt(protocolEntryDeficitChecks, 0)` proved the cheap arm ran and said nothing
    /// about the expensive one, which is the exact shape - a reachability tripwire satisfied by a
    /// transition other than the one it is about - that this handler's own round-48 ghosts exist
    /// to refuse.
    ///
    /// The mismatch counter is deliberately NOT split: it is a violation counter asserted equal to
    /// zero, and a violation is a violation whichever arm saw it. What had to be split is the
    /// evidence that the observation happened.
    uint256 public protocolEntryDeficitChecksAtSettle;
    uint256 public protocolEntryDeficitChecksAtRefill;
    /// @dev Partner of `donationViewMismatches`: donations that landed with `cashDeficit() == 0`,
    ///      the only ones the view comparison is made for.
    uint256 public donationViewChecks;
    /// @dev Partner of `otherRequestMutations`: foreign requests that were LIVE before a request
    ///      door action and read back unchanged. Two empty fingerprints compare equal.
    uint256 public foreignRequestsObserved;

    /**
     * ── ROUND-46 PROPERTY GHOSTS, EVERY ONE ASSERTED ZERO ──────────────────────────────────────
     */
    /// @dev An entry the pool ACCEPTED while paused. The door half of the pause property; the
    ///      view half (`maxDeposit == 0`) used to be the whole invariant and restates
    ///      `_maxDeposit`'s first line.
    uint256 public pausedEntryAccepted;
    /// @dev An entry refused while paused with any selector but `EnforcedPause`. The docstring on
    ///      `deposit` makes the pair deliberate: the cap read below the modifier would answer
    ///      `DepositCapExceeded(assets, 0)`, "which tells a lender the pool is full when the truth
    ///      is that the pool is shut". Removing `whenNotPaused` lands here, not on the counter
    ///      above, because the zero cap still refuses.
    uint256 public pausedEntryRefusedAsFull;
    /// @dev A `pause` or `unpause` that moved any lender's `maxRedeem`, `maxWithdraw` or
    ///      `maxRequestRedeem`. Measured across the toggle rather than restated from
    ///      `_maxRedeem`, which has no pause term to restate.
    uint256 public pauseMovedAnExitMaximum;
    /// @dev A `socialiseLoss` after which `depositCapUsage` did not fall by exactly the loss
    ///      absorbed plus the cash deficit it reconciled on the way in. Round 45, item 55: a loss
    ///      reopens the cap by exactly the loss, and this is that mechanism asserted at the
    ///      transition rather than the view's body restated at rest.
    uint256 public lossHeadroomMismatches;
    /// @dev A door outcome that was not the one the pool's public views predicted. See the
    ///      contract docstring. The two selectors of the first such outcome are kept beside it.
    uint256 public unpredictedOutcomes;
    bytes4 public firstUnpredictedActual;
    bytes4 public firstUnpredictedPredicted;
    /// @dev Execution returned other than its preview. ERC-4626 lets a preview under-promise; this
    ///      pool's previews are exact and the request door's `minAssetsOut` is set from one.
    uint256 public depositMismatches;
    uint256 public mintMismatches;
    uint256 public withdrawMismatches;
    uint256 public redeemMismatches;

    mapping(address controller => bytes32 fingerprint) private _requestBefore;
    /// @dev `_requestFingerprint` of a controller with no request.
    bytes32 private constant EMPTY_REQUEST = keccak256(abi.encode(uint256(0), address(0), uint256(0)));

    struct Watch {
        uint256 lifetimeLoss;
        uint256 outstandingPrincipal;
        uint256 entryPriceDeficit;
        uint256 losses;
        uint256 lends;
    }

    Watch private _before;

    modifier watched() {
        _observe();
        _;
        _settle();
    }

    constructor(LenderPool pool_, MockUSDC usdc_, address owner_, address creditManager_, address epochHarvester_) {
        pool = pool_;
        canonical = ICanonicalLenderPool(address(pool_));
        usdc = usdc_;
        owner = owner_;
        creditManager = creditManager_;
        epochHarvester = epochHarvester_;
        destructionSink = makeAddr("cash-destruction-sink");

        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string(abi.encodePacked("canonical-lender-", i)));
            actors.push(actor);
            vm.prank(actor);
            usdc.approve(address(pool), type(uint256).max);
        }
        for (uint256 i = 0; i < 2; i++) {
            borrowers.push(makeAddr(string(abi.encodePacked("canonical-borrower-", i))));
        }

        vm.prank(creditManager);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(epochHarvester);
        usdc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function borrowerCount() external view returns (uint256) {
        return borrowers.length;
    }

    // ── Entry: the two doors with no quoted maximum, predicted rather than swallowed ────────────

    function deposit(uint256 actorSeed, uint96 amountSeed) external watched {
        address actor = _actor(actorSeed);
        _enter(actor, actor, bound(uint256(amountSeed), 1, 5_000e6));
    }

    /// @dev Payer and receiver differ, which no action in the round-45 handler ever did.
    function depositFor(uint256 actorSeed, uint256 receiverSeed, uint96 amountSeed) external watched {
        address payer = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        if (payer == receiver) return;
        if (_enter(payer, receiver, bound(uint256(amountSeed), 1, 5_000e6))) ++depositForDone;
    }

    function mintShares(uint256 actorSeed, uint96 shareSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 shares = bound(uint256(shareSeed), 1, 5_000e9);
        uint256 cost = pool.previewMint(shares);
        if (cost == 0 || cost > 5_000e6) return;
        _mint(actor, cost);

        bool wasPaused = pool.paused();
        bytes4 predicted = _predictedEntryRefusal(actor, shares, true);
        if (wasPaused) ++pausedEntryAttempts;

        vm.prank(actor);
        try pool.mint(shares, actor) returns (uint256 paid) {
            ++mintsDone;
            if (paid != cost) ++mintMismatches;
            if (wasPaused) ++pausedEntryAccepted;
            _recordOutcome(predicted, bytes4(0));
        } catch (bytes memory reason) {
            bytes4 actual = _selectorOf(reason);
            if (wasPaused && actual != Pausable.EnforcedPause.selector) ++pausedEntryRefusedAsFull;
            _recordOutcome(predicted, actual);
        }
    }

    function _enter(address payer, address receiver, uint256 amount) private returns (bool accepted) {
        _mint(payer, amount);

        bool wasPaused = pool.paused();
        bytes4 predicted = _predictedEntryRefusal(receiver, amount, false);
        uint256 quoted = pool.previewDeposit(amount);
        if (wasPaused) ++pausedEntryAttempts;

        vm.prank(payer);
        try pool.deposit(amount, receiver) returns (uint256 shares) {
            accepted = true;
            if (shares != 0) ++depositsDone;
            else ++zeroShareDeposits;
            if (shares != quoted) ++depositMismatches;
            if (wasPaused) ++pausedEntryAccepted;
            _recordOutcome(predicted, bytes4(0));
        } catch (bytes memory reason) {
            bytes4 actual = _selectorOf(reason);
            if (wasPaused && actual != Pausable.EnforcedPause.selector) ++pausedEntryRefusedAsFull;
            _recordOutcome(predicted, actual);
        }
    }

    /// @dev The refusal `deposit`/`mint` will give, from public views alone and in the order the
    ///      door's docstring documents: the pause modifier first ("EnforcedPause rather than
    ///      DepositCapExceeded(assets, 0)"), then the unreconciled cash deficit, then the entry
    ///      price deficit, then the quoted maximum, then the round-22 zero-share guard. Zero means
    ///      the views predict acceptance.
    function _predictedEntryRefusal(address receiver, uint256 quantity, bool viaMint) private view returns (bytes4) {
        if (pool.paused()) return Pausable.EnforcedPause.selector;
        if (canonical.cashDeficit() != 0) return LenderPool.CashDeficitOutstanding.selector;
        if (canonical.entryPriceDeficit() != 0) return LenderPool.EntryPriceBelowMinimum.selector;
        if (viaMint) {
            return quantity > pool.maxMint(receiver) ? LenderPool.DepositCapExceeded.selector : bytes4(0);
        }
        if (quantity > pool.maxDeposit(receiver)) return LenderPool.DepositCapExceeded.selector;
        return pool.previewDeposit(quantity) == 0 ? LenderPool.ZeroAmount.selector : bytes4(0);
    }

    // ── Exit: bare at or below the quoted maximum ───────────────────────────────────────────────

    function withdrawMaximum(uint256 actorSeed, uint96 fractionSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 maximum = pool.maxWithdraw(actor);
        if (maximum == 0) return;
        _withdrawBare(actor, bound(uint256(fractionSeed), 1, maximum));
    }

    /// @dev The exact maximum, which a bounded seed lands on with probability about zero.
    function withdrawAll(uint256 actorSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 maximum = pool.maxWithdraw(actor);
        if (maximum == 0) return;
        _withdrawBare(actor, maximum);
        ++exhaustiveExitsDone;
    }

    function redeemMaximum(uint256 actorSeed, uint256 fractionSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 maximum = pool.maxRedeem(actor);
        if (maximum == 0) return;
        _redeemBare(actor, actor, bound(uint256(fractionSeed), 1, maximum));
    }

    function redeemAll(uint256 actorSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 maximum = pool.maxRedeem(actor);
        if (maximum == 0) return;
        _redeemBare(actor, actor, maximum);
        ++exhaustiveExitsDone;
    }

    /// @dev An operator exits the owner's whole maximum through an ERC-20 allowance, paying the
    ///      operator - the third party the ERC-4626 `owner`/`receiver` split exists for.
    function redeemViaAllowance(uint256 ownerSeed, uint256 operatorSeed) external watched {
        address holder = _actor(ownerSeed);
        address operator = _actor(operatorSeed);
        if (operator == holder) return;
        uint256 maximum = pool.maxRedeem(holder);
        if (maximum == 0) return;

        vm.prank(holder);
        pool.approve(operator, maximum);
        _redeemBare(holder, operator, maximum);
        ++allowanceExitsDone;
    }

    function _withdrawBare(address actor, uint256 assets) private {
        uint256 quotedShares = pool.previewWithdraw(assets);
        vm.prank(actor);
        uint256 burned = pool.withdraw(assets, actor, actor);
        if (burned != quotedShares) ++withdrawMismatches;
        ++withdrawalsDone;
    }

    function _redeemBare(address holder, address caller, uint256 shares) private {
        uint256 quotedAssets = pool.previewRedeem(shares);
        vm.prank(caller);
        uint256 paid = pool.redeem(shares, caller, holder);
        if (paid != quotedAssets) ++redeemMismatches;
        ++redeemsDone;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 fractionSeed) external watched {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 balance = pool.balanceOf(from);
        if (balance == 0) return;
        uint256 amount = bound(uint256(fractionSeed), 1, balance);

        vm.prank(from);
        if (pool.transfer(to, amount)) ++transfersDone;
    }

    // ── Raw cash: outside the book ──────────────────────────────────────────────────────────────

    /// @dev A donation is required to be inert only while no prior external subtraction is being
    ///      masked. Filling an observed deficit can restore value up to the recognised book, which
    ///      is the unavoidable provenance window the design discloses.
    function donate(uint96 amountSeed) external {
        uint256 amount = bound(uint256(amountSeed), 1, 5_000e6);
        uint256 deficitBefore = canonical.cashDeficit();
        uint256 assetsBefore = pool.totalAssets();
        uint256 entryBefore = pool.previewDeposit(1e6);
        uint256 availableBefore = pool.available();
        uint256 usageBefore = canonical.depositCapUsage();
        uint256 roomBefore = pool.maxDeposit(actors[0]);

        _mint(address(pool), amount);
        ++donationsDone;

        if (deficitBefore == 0) ++donationViewChecks;
        if (
            deficitBefore == 0
                && (pool.totalAssets() != assetsBefore
                    || pool.previewDeposit(1e6) != entryBefore
                    || pool.available() != availableBefore
                    || canonical.depositCapUsage() != usageBefore
                    || pool.maxDeposit(actors[0]) != roomBefore)
        ) ++donationViewMismatches;
    }

    /// @dev MockUSDC has no issuer-burn method because current USDC does not expose one for an
    ///      arbitrary holder. Pranking the pool for this transfer changes only raw token backing,
    ///      which is the same observable state a destructive upgrade or adversarial token creates.
    function destroyRawCash(uint96 amountSeed) external {
        uint256 raw = usdc.balanceOf(address(pool));
        if (raw == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, raw);
        vm.prank(address(pool));
        if (usdc.transfer(destructionSink, amount)) ++destructionsDone;
    }

    /// @dev Every wei, which is one draw in `raw` for the bounded action above and is the state
    ///      behind a claim liquidity deficit with nothing left to reconcile against.
    function destroyAllRawCash() external {
        uint256 raw = usdc.balanceOf(address(pool));
        if (raw == 0) return;
        vm.prank(address(pool));
        if (usdc.transfer(destructionSink, raw)) {
            ++destructionsDone;
            ++fullDestructionsDone;
        }
    }

    function reconcileCashDeficit() external watched {
        (uint256 lost,) = canonical.reconcileCashDeficit();
        if (lost != 0) ++reconciliationsDone;
    }

    function coverClaimDeficit(uint96 amountSeed) external watched {
        uint256 deficit = canonical.claimSolvencyDeficit();
        if (deficit == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, deficit);
        _mint(address(this), amount);
        canonical.coverClaimDeficit(amount);
        ++coversDone;
    }

    function coverEntryPriceDeficit(uint96 amountSeed) external watched {
        if (canonical.claimLiquidityDeficit() != 0) return;
        uint256 deficit = canonical.entryPriceDeficit();
        if (deficit == 0) return;

        uint256 amount = bound(uint256(amountSeed), 1, deficit);
        _mint(address(this), amount);
        canonical.coverEntryPriceDeficit(amount);
        ++entryCoversDone;
    }

    // ── Protocol legs ───────────────────────────────────────────────────────────────────────────

    /// @dev Advances the real production pool towards the numeric reserve with a bounded number of
    ///      full-loss cycles. The total cap keeps a long invariant campaign from spending most of
    ///      its runtime after the boundary has already been demonstrated. Every leg is bare: each
    ///      one's precondition is a view the pool itself quotes.
    function stressLossRefill(uint8 cyclesSeed, uint256 actorSeed) external watched {
        if (
            pool.paused() || pool.outstandingPrincipal() != 0 || canonical.cashDeficit() != 0
                || canonical.claimLiquidityDeficit() != 0 || canonical.entryPriceDeficit() != 0
        ) return;

        address actor = _actor(actorSeed);
        uint256 cycles = bound(uint256(cyclesSeed), 1, MAX_STRESS_CYCLES_PER_ACTION);
        bool startedSafe = true;

        for (uint256 i; i < cycles; ++i) {
            uint256 lendable = pool.available();
            if (lendable == 0) {
                if (canonical.minimumEntryAssets() != 0) ++lendTapersReached;
                return;
            }
            if (lossRefillCyclesDone >= MAX_STRESS_CYCLES_TOTAL) return;

            vm.prank(creditManager);
            pool.lend(lendable);
            ++lendsDone;
            _recordProtocolEntryDeficit(startedSafe);

            uint256 usageBefore = canonical.depositCapUsage();
            vm.prank(creditManager);
            uint256 absorbed = pool.socialiseLoss(lendable);
            _recordLossHeadroom(usageBefore, 0, absorbed);
            if (absorbed != lendable) return;
            ++lossesDone;
            _recordProtocolEntryDeficit(startedSafe);

            uint256 refill = pool.maxDeposit(actor);
            if (refill == 0) return;
            _mint(actor, refill);
            vm.prank(actor);
            uint256 shares = pool.deposit(refill, actor);
            if (shares == 0) {
                ++zeroShareDeposits;
                return;
            }
            ++depositsDone;
            ++lossRefillCyclesDone;
            if (canonical.minimumEntryAssets() != 0) ++numericReserveStatesReached;
            _recordProtocolEntryDeficit(startedSafe);
        }
    }

    function lend(uint96 amountSeed) external watched {
        uint256 available = pool.available();
        if (available == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, available);

        vm.prank(creditManager);
        pool.lend(amount);
        ++lendsDone;
    }

    /// @dev Kept under `try` with an always-success prediction: the leg has no refusal beyond the
    ///      caller and zero checks this handler cannot fail, so any catch is unpredicted and the
    ///      selector is recorded rather than dropped with the frame.
    function repay(uint96 amountSeed) external watched {
        uint256 principal = pool.outstandingPrincipal();
        uint256 top = principal == 0 ? 1_000e6 : principal + (principal > 1_000e6 ? 1_000e6 : principal);
        if (top > 5_000e6) top = 5_000e6;
        uint256 amount = bound(uint256(amountSeed), 1, top);
        _mint(creditManager, amount);

        vm.prank(creditManager);
        try pool.repayPrincipal(amount) {
            ++repaysDone;
        } catch (bytes memory reason) {
            _recordOutcome(bytes4(0), _selectorOf(reason));
        }
    }

    /// @dev Both legitimate refusals are predicted from public views, so a delivery is attempted
    ///      even when `totalAssets()` is zero - the claim-cure branch below the supply floor is a
    ///      state, and the round-45 handler's `capital == 0` early return made it unreachable.
    function distributeYield(uint96 amountSeed) external watched {
        uint256 capital = pool.totalAssets();
        uint256 top = capital > 1_000e6 || capital == 0 ? 1_000e6 : capital;
        uint256 amount = bound(uint256(amountSeed), 1, top);
        bytes4 predicted = _predictedYieldRefusal(amount, capital);
        _mint(epochHarvester, amount);

        vm.prank(epochHarvester);
        try pool.distributeYield(amount) {
            ++yieldsDone;
            _recordOutcome(predicted, bytes4(0));
        } catch (bytes memory reason) {
            _recordOutcome(predicted, _selectorOf(reason));
        }
    }

    function _predictedYieldRefusal(uint256 amount, uint256 capital) private view returns (bytes4) {
        uint256 solvency = canonical.claimSolvencyDeficit();
        uint256 covered = amount > solvency ? solvency : amount;
        if (pool.totalSupply() < MIN_SUPPLY_FOR_YIELD) {
            return covered == 0 ? LenderPool.NoSharesOutstanding.selector : bytes4(0);
        }
        if (canonical.claimLiquidityDeficit() == 0 && amount - covered > capital) {
            // The one state the pool clamps in rather than refuses: full at the hard ceiling. This
            // handler never sets the cap and deposits at most 5,000e6 an action, so the arm below
            // is the rule stated in full rather than a state the campaign reaches.
            bool fullAtTheHardCeiling =
                pool.depositCap() == Config.GLOBAL_BORROW_CAP_MAX && canonical.depositCapUsage() >= pool.depositCap();
            if (capital != 0 && fullAtTheHardCeiling) return bytes4(0);
            return LenderPool.YieldExceedsCapital.selector;
        }
        return bytes4(0);
    }

    function recoverLoss(uint96 amountSeed) external watched {
        uint256 amount = bound(uint256(amountSeed), 1, 1_000e6);
        _mint(creditManager, amount);

        vm.prank(creditManager);
        pool.recoverLoss(amount);
        ++recoveriesDone;
    }

    function socialiseLoss(uint96 amountSeed) external watched {
        uint256 principal = pool.outstandingPrincipal();
        if (principal == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, principal);
        uint256 usageBefore = canonical.depositCapUsage();
        uint256 deficitBefore = canonical.cashDeficit();

        vm.prank(creditManager);
        uint256 absorbed = pool.socialiseLoss(amount);
        if (absorbed != 0) ++lossesDone;
        _recordLossHeadroom(usageBefore, deficitBefore, absorbed);
    }

    /// @dev `depositCapUsage` is `accountedCash + outstandingPrincipal - totalClaimable` clamped at
    ///      zero. A loss reduces principal by what it absorbed and reconciles any standing cash
    ///      deficit first, so the headroom it reopens is exactly that sum and nothing else.
    function _recordLossHeadroom(uint256 usageBefore, uint256 deficitBefore, uint256 absorbed) private {
        uint256 freed = absorbed + deficitBefore;
        uint256 expected = usageBefore > freed ? usageBefore - freed : 0;
        if (freed != 0) ++lossHeadroomChecks;
        if (canonical.depositCapUsage() != expected) ++lossHeadroomMismatches;
    }

    // ── Controller-scoped requests ──────────────────────────────────────────────────────────────

    function requestWithdrawal(uint256 actorSeed, uint256 receiverSeed, uint256 shareSeed) external watched {
        address controller = _actor(actorSeed);
        uint256 balance = pool.balanceOf(controller);
        if (balance == 0) return;
        (uint256 requestId,,,,) = pool.withdrawalRequest(controller);
        if (requestId != 0) return;
        _requestBare(controller, _actor(receiverSeed), bound(uint256(shareSeed), 1, balance));
    }

    function requestAll(uint256 actorSeed, uint256 receiverSeed) external watched {
        address controller = _actor(actorSeed);
        uint256 balance = pool.balanceOf(controller);
        if (balance == 0) return;
        (uint256 requestId,,,,) = pool.withdrawalRequest(controller);
        if (requestId != 0) return;
        _requestBare(controller, _actor(receiverSeed), balance);
        ++exhaustiveRequestsDone;
    }

    function _requestBare(address controller, address receiver, uint256 shares) private {
        _observeOtherRequests(controller);
        vm.prank(controller);
        pool.requestWithdrawal(shares, receiver);
        ++requestsDone;
        _settleOtherRequests(controller);
    }

    function cancelWithdrawalRequest(uint256 actorSeed) external watched {
        address controller = _actor(actorSeed);
        (uint256 requestId,,,,) = pool.withdrawalRequest(controller);
        if (requestId == 0) return;
        _observeOtherRequests(controller);

        vm.prank(controller);
        pool.cancelWithdrawalRequest();
        ++cancellationsDone;
        _settleOtherRequests(controller);
    }

    function serviceWithdrawalRequest(uint256 actorSeed, uint256 shareSeed) external watched {
        address controller = _actor(actorSeed);
        uint256 maximum = _serviceableShares(controller);
        if (maximum == 0) return;
        _serviceBare(controller, controller, bound(uint256(shareSeed), 1, maximum));
    }

    function serviceWithdrawalRequestMaximum(uint256 actorSeed) external watched {
        address controller = _actor(actorSeed);
        uint256 maximum = _serviceableShares(controller);
        if (maximum == 0) return;
        _serviceBare(controller, controller, maximum);
        ++exhaustiveServicesDone;
    }

    /// @dev An opted-in operator services the controller's maximum. The approval persists, which
    ///      is what the real feature does; the operator can only ever choose timing and size.
    function serviceByOperator(uint256 actorSeed, uint256 operatorSeed) external watched {
        address controller = _actor(actorSeed);
        address operator = _actor(operatorSeed);
        if (operator == controller) return;
        uint256 maximum = _serviceableShares(controller);
        if (maximum == 0) return;

        vm.prank(controller);
        pool.setRequestOperator(operator, true);
        _serviceBare(controller, operator, maximum);
        ++operatorServicesDone;
    }

    function _serviceableShares(address controller) private view returns (uint256) {
        (uint256 requestId,,,,) = pool.withdrawalRequest(controller);
        if (requestId == 0) return 0;
        return pool.maxRequestRedeem(controller);
    }

    function _serviceBare(address controller, address caller, uint256 shares) private {
        (, address receiver, uint256 requestShares,,) = pool.withdrawalRequest(controller);
        uint256 expectedAssets = pool.previewRedeem(shares);
        uint256 claimBefore = pool.claimable(receiver);
        uint256 totalBefore = pool.totalClaimable();
        uint256 supplyBefore = pool.totalSupply();
        uint256 queuedBefore = pool.queuedShares();
        _observeOtherRequests(controller);

        vm.prank(caller);
        uint256 assets = pool.serviceWithdrawalRequest(controller, shares, expectedAssets);
        ++servicesDone;
        (,, uint256 remainingShares,,) = pool.withdrawalRequest(controller);
        if (
            assets != expectedAssets || pool.claimable(receiver) != claimBefore + assets
                || pool.totalClaimable() != totalBefore + assets || pool.totalSupply() != supplyBefore - shares
                || pool.queuedShares() != queuedBefore - shares || remainingShares != requestShares - shares
        ) ++serviceAccountingMismatches;
        _settleOtherRequests(controller);
    }

    function claim(uint256 actorSeed) external watched {
        address receiver = _actor(actorSeed);
        if (pool.claimable(receiver) == 0 || canonical.claimLiquidityDeficit() != 0) return;

        vm.prank(receiver);
        if (pool.claim() != 0) ++claimsDone;
    }

    /// @dev Anyone may initiate a mute receiver's collection; the money still goes to the receiver.
    function claimFor(uint256 receiverSeed, uint256 callerSeed) external watched {
        address receiver = _actor(receiverSeed);
        if (pool.claimable(receiver) == 0 || canonical.claimLiquidityDeficit() != 0) return;
        address caller = _actor(callerSeed);

        vm.prank(caller);
        if (pool.claimFor(receiver) != 0) {
            ++claimsDone;
            ++claimForsDone;
        }
    }

    // ── Marks and reserves ──────────────────────────────────────────────────────────────────────

    function impair(uint256 borrowerSeed, uint96 amountSeed) external watched {
        address borrower = _borrower(borrowerSeed);
        uint256 amount = bound(uint256(amountSeed), 1, Config.GLOBAL_BORROW_CAP_MAX);
        vm.prank(creditManager);
        if (pool.impair(borrower, amount)) ++impairmentsDone;
    }

    /// @dev A mark below the pool's exposure. The uniform draw above lands almost always far above
    ///      any principal this fixture lends, so every mark it writes is a whole-book mark and the
    ///      partial arithmetic of `exitReserve` is never exercised by it.
    function impairWithinPrincipal(uint256 borrowerSeed, uint96 amountSeed) external watched {
        uint256 principal = pool.outstandingPrincipal();
        if (principal == 0) return;
        address borrower = _borrower(borrowerSeed);
        uint256 amount = bound(uint256(amountSeed), 1, principal);
        vm.prank(creditManager);
        if (pool.impair(borrower, amount)) ++impairmentsDone;
    }

    function releaseImpairment(uint256 borrowerSeed) external watched {
        address borrower = _borrower(borrowerSeed);
        vm.prank(creditManager);
        if (pool.releaseImpairment(borrower)) ++releasesDone;
    }

    /// @dev The manager's push of its unplaced loss and insurance fund, which nothing in the
    ///      round-45 handler could write. Bounded near the pool's own exposure so that the netting
    ///      and backlog arms of `exitReserve` are reached as partial figures rather than clamps.
    function setLossReserves(uint96 unplacedSeed, uint96 insuranceSeed) external watched {
        uint256 top = pool.outstandingPrincipal() * 2 + 1;
        uint256 unplaced = bound(uint256(unplacedSeed), 0, top);
        uint256 insurance = bound(uint256(insuranceSeed), 0, top);
        vm.prank(creditManager);
        pool.setLossReserves(unplaced, insurance);
        ++lossReserveWrites;
    }

    // ── Pause and time ──────────────────────────────────────────────────────────────────────────

    /// @dev Pausing entry does not change any lender's executable exit maximum, and that is
    ///      measured across the toggle in both directions rather than restated from a view.
    function togglePause() external watched {
        uint256 count = actors.length;
        uint256[] memory redeemBefore = new uint256[](count);
        uint256[] memory withdrawBefore = new uint256[](count);
        uint256[] memory requestBefore = new uint256[](count);
        bool live;
        for (uint256 i = 0; i < count; i++) {
            redeemBefore[i] = pool.maxRedeem(actors[i]);
            withdrawBefore[i] = pool.maxWithdraw(actors[i]);
            requestBefore[i] = pool.maxRequestRedeem(actors[i]);
            if (redeemBefore[i] != 0 || withdrawBefore[i] != 0 || requestBefore[i] != 0) live = true;
        }

        bool isPaused = pool.paused();
        vm.prank(owner);
        if (isPaused) {
            pool.unpause();
            ++unpausesDone;
        } else {
            pool.pause();
            ++pausesDone;
        }

        for (uint256 i = 0; i < count; i++) {
            if (
                pool.maxRedeem(actors[i]) != redeemBefore[i] || pool.maxWithdraw(actors[i]) != withdrawBefore[i]
                    || pool.maxRequestRedeem(actors[i]) != requestBefore[i]
            ) ++pauseMovedAnExitMaximum;
        }
        if (live) ++pauseTogglesWithALiveExitMaximum;
    }

    function passTime(uint32 secondsSeed) external watched {
        skip(bound(uint256(secondsSeed), 1, 7 days));
        ++timeAdvances;
    }

    // ── Private ─────────────────────────────────────────────────────────────────────────────────

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _borrower(uint256 seed) private view returns (address) {
        return borrowers[seed % borrowers.length];
    }

    function _mint(address to, uint256 amount) private {
        usdc.mint(to, amount);
        totalMinted += amount;
    }

    function _selectorOf(bytes memory reason) private pure returns (bytes4) {
        return reason.length < 4 ? bytes4(0) : bytes4(reason);
    }

    function _recordOutcome(bytes4 predicted, bytes4 actual) private {
        if (actual == predicted) {
            if (actual != bytes4(0)) ++predictedRefusals;
            return;
        }
        ++unpredictedOutcomes;
        if (firstUnpredictedActual == bytes4(0) && firstUnpredictedPredicted == bytes4(0)) {
            firstUnpredictedActual = actual;
            firstUnpredictedPredicted = predicted;
        }
    }

    function _requestFingerprint(address controller) private view returns (bytes32) {
        (uint256 requestId, address receiver, uint256 shares,,) = pool.withdrawalRequest(controller);
        return keccak256(abi.encode(requestId, receiver, shares));
    }

    function _observeOtherRequests(address selected) private {
        for (uint256 i = 0; i < actors.length; i++) {
            address controller = actors[i];
            if (controller != selected) _requestBefore[controller] = _requestFingerprint(controller);
        }
    }

    function _settleOtherRequests(address selected) private {
        for (uint256 i = 0; i < actors.length; i++) {
            address controller = actors[i];
            if (controller == selected) continue;
            bytes32 before = _requestBefore[controller];
            if (before != _requestFingerprint(controller)) {
                ++otherRequestMutations;
            } else if (before != EMPTY_REQUEST) {
                ++foreignRequestsObserved;
            }
        }
    }

    /// @dev The REFILL arm. Its only caller is `stressLossRefill`, which is the action that walks
    ///      the pool to the numeric reserve - the regime where a protocol-controlled flow could
    ///      manufacture an entry-price deficit at all.
    function _recordProtocolEntryDeficit(bool startedSafe) private {
        if (!startedSafe) return;
        ++protocolEntryDeficitChecksAtRefill;
        if (canonical.entryPriceDeficit() != 0) ++protocolEntryDeficitMismatches;
    }

    function _observe() private {
        _before = Watch({
            lifetimeLoss: pool.lifetimeSocialisedLoss(),
            outstandingPrincipal: pool.outstandingPrincipal(),
            entryPriceDeficit: canonical.entryPriceDeficit(),
            losses: lossesDone,
            lends: lendsDone
        });
    }

    function _settle() private {
        uint256 lifetime = pool.lifetimeSocialisedLoss();
        bool lossed = lossesDone != _before.losses;
        if (lifetime < _before.lifetimeLoss) ++lifetimeLossFell;
        if (lifetime > _before.lifetimeLoss && !lossed) ++lifetimeLossRoseWithoutLossAction;
        if (lifetime > _before.lifetimeLoss && lossed) ++lifetimeLossRoseOnALoss;
        uint256 principal = pool.outstandingPrincipal();
        bool lent = lendsDone != _before.lends;
        if (principal > _before.outstandingPrincipal && !lent) ++principalRoseWithoutLend;
        if (principal > _before.outstandingPrincipal && lent) ++principalRoseOnALend;
        // The SETTLE arm: every watched action, whatever it was. Cheap and near-universal, which
        // is exactly why it needed its own counter - see the declaration.
        if (_before.entryPriceDeficit == 0) {
            ++protocolEntryDeficitChecksAtSettle;
            if (canonical.entryPriceDeficit() != 0) ++protocolEntryDeficitMismatches;
        }
        // Round 45, item 55: the sub-floor state, observed after every action rather than only
        // on the deposit arm, because the lever that creates it is `recoverLoss` and not entry.
        if (pool.maxDeposit(actors[0]) != 0 && pool.previewDeposit(1) == 0) ++subFloorStatesSeen;
        // Round 46: the three shapes of `exitReserve`, observed after every action because a mark
        // written by `impair` only becomes partial or netted when a later write changes its terms.
        uint256 reserve = pool.exitReserve();
        if (reserve != 0 && reserve < principal) ++partialMarkStates;
        if (pool.insuranceCover() != 0 && pool.totalImpairment() != 0) ++nettedMarkStates;
        if (pool.unplacedLoss() != 0 && principal != 0) ++backlogStates;
    }
}

/// @notice The production-pool campaign, round 46.
/// @dev **Twenty invariants, and what they are NOT.** Audit round 45 wrote arbitrary values
///      straight into every storage slot the round-45 invariants read - states no handler reaches
///      and states that are not self-consistent - and re-ran each assertion verbatim: eight of the
///      twenty-one held over all of it. An assertion that holds over uint120^n of inconsistent
///      storage is a statement about the function's source text, not about the pool's behaviour.
///      Those eight are gone from here. Six moved to `LenderPoolFormulaPins.t.sol` as what they
///      always were, regression pins on a view's text; one was split so its single real clause
///      survives (`invariant_realSupplyNeverCrossesTheAbsoluteCeiling`); one was strengthened into
///      the door it only ever described (`invariant_aPausedPoolRefusesEveryEntry`). What stands
///      here is a claim about money, ordering or conservation that some reachable state could
///      falsify - or a handler ghost that some reachable transition could move.
contract LenderPoolInvariants is Test {
    uint256 private constant MIN_SUPPLY_FOR_PRINCIPAL = (10 ** 3) * Config.BPS;

    MockUSDC internal usdc;
    LenderPool internal pool;
    ICanonicalLenderPool internal canonical;
    CanonicalLenderHandler internal handler;

    address internal owner = makeAddr("canonical-owner");
    address internal creditManager = makeAddr("canonical-credit-manager");
    address internal epochHarvester = makeAddr("canonical-epoch-harvester");

    function setUp() public virtual {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), owner);
        canonical = ICanonicalLenderPool(address(pool));

        vm.startPrank(owner);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(epochHarvester);
        vm.stopPrank();

        handler = new CanonicalLenderHandler(pool, usdc, owner, creditManager, epochHarvester);
        targetContract(address(handler));
    }

    /// @dev Round 45, item 55: the campaign reach of the sub-floor state, read at the end of a
    ///      run and logged only when the run reached it. A FIGURE and never a floor - a per-run
    ///      reachability assertion here fails a 256-run campaign on one unlucky run, and no state
    ///      survives between runs to total. Forge replays only the last run of a campaign for its
    ///      `-vv` logs, so a line here is the last run's count, and its absence is not a zero.
    function afterInvariant() public {
        uint256 seen = handler.subFloorStatesSeen();
        if (seen != 0) emit log_named_uint("sub-floor states seen in the replayed run", seen);
    }

    /// @notice The stored yield tail never exceeds the stored gross book that backs it.
    /// @dev Not asserted anywhere in the tree before round 46. `unreleasedYield()` is a pure
    ///      function of the stream terms and the book is three storage words, and nothing in
    ///      either view clamps one to the other: `distributeYield`'s `YieldExceedsCapital`,
    ///      `socialiseLoss`'s write-down and reconciliation's yield-first write-off are what hold
    ///      it, and any of them going missing lands here. Replaces
    ///      `invariant_rawAndRecognisedCashHaveOnlyOneSignedDifference`, which asserted that two
    ///      clamped subtractions of one pair cannot both be non-zero.
    function invariant_theStoredTailNeverExceedsTheStoredGrossBook() public view {
        uint256 gross = _accountedCash(usdc.balanceOf(address(pool))) + pool.outstandingPrincipal();
        uint256 claims = pool.totalClaimable();
        uint256 book = gross > claims ? gross - claims : 0;
        assertLe(pool.unreleasedYield(), book, "the stored tail outgrew the stored book that backs it");
    }

    /// @notice Real share supply never crosses the absolute ceiling.
    /// @dev A GUARD, not coverage: the ceiling is `2^128 * (GLOBAL_BORROW_CAP_MAX + 1) - 1000`
    ///      shares and no fixture approaches it, so this discriminates on nothing the walk
    ///      reaches. It is the one clause of the former
    ///      `invariant_entryPriceDeficitAndAbsoluteSupplyAreExact` that a `vm.store` could break
    ///      and that `_update`'s mint clause is written to hold, kept so the clause has a
    ///      campaign-side assertion at all; the formula clauses beside it are pins now.
    function invariant_realSupplyNeverCrossesTheAbsoluteCeiling() public view {
        assertLe(pool.totalSupply(), canonical.maximumShareSupply(), "real share supply crossed the absolute ceiling");
    }

    function invariant_entryMaximaStayInsideTheAbsoluteSupplyCeiling() public view {
        assertEq(handler.zeroShareDeposits(), 0, "the pool accepted a deposit and minted nothing for it");
        address receiver = handler.actors(0);
        uint256 maxAssets = pool.maxDeposit(receiver);
        uint256 maxShares = pool.maxMint(receiver);
        uint256 supply = pool.totalSupply();
        uint256 maximum = canonical.maximumShareSupply();
        assertLe(supply, maximum, "entry maximum observed an over-ceiling supply");
        uint256 shareRoom = maximum - supply;

        if (
            canonical.cashDeficit() != 0 || canonical.claimLiquidityDeficit() != 0 || canonical.entryPriceDeficit() != 0
        ) {
            assertEq(maxAssets, 0, "an accounting deficit left maxDeposit open");
            assertEq(maxShares, 0, "an accounting deficit left maxMint open");
            return;
        }

        uint256 depositShares = pool.previewDeposit(maxAssets);
        assertLe(depositShares, shareRoom, "maxDeposit crossed the absolute share ceiling");
        assertLe(maxShares, shareRoom, "maxMint crossed the absolute share ceiling");
        uint256 expectedMint = depositShares < shareRoom ? depositShares : shareRoom;
        assertEq(maxShares, expectedMint, "maxMint diverged from maxDeposit at the entry price");
        assertLe(pool.previewMint(maxShares), maxAssets, "maxMint costs more than maxDeposit");

        // Round 45, item 55. `maxDeposit` is a maximum and not a minimum: below `previewMint(1)`
        // a deposit is refused, so a quoted maximum must sit at or above that floor, the floor
        // must buy a share, and the maximum itself must not be a zero-share donation. What is
        // deliberately NOT asserted is `previewDeposit(floor - 1) == 0` - that is an algebraic
        // identity of the ceil/floor pair no state can falsify. The handler's `zeroShareDeposits`
        // is the other half: a deposit the pool accepted against nothing, which the round-22
        // guard makes unreachable and a neuter of it makes reachable; that counter is checked at
        // the top of this function so a deficit frame's early return cannot skip it.
        if (maxAssets != 0) {
            uint256 floor = pool.previewMint(1);
            assertGe(maxAssets, floor, "maxDeposit quoted a maximum below the one-share floor");
            assertGt(pool.previewDeposit(floor), 0, "previewMint(1) does not buy a share");
            assertGt(depositShares, 0, "maxDeposit quoted a zero-share donation");
        }
    }

    function invariant_deficitsCloseOnlyTheDoorsTheirBackingRequires() public view {
        if (canonical.cashDeficit() != 0 || canonical.claimLiquidityDeficit() != 0) {
            assertEq(pool.maxDeposit(handler.actors(0)), 0, "entry stayed open across a cash deficit");
        }
        if (canonical.claimLiquidityDeficit() == 0) return;

        assertEq(pool.available(), 0, "lending ranked ahead of an underfunded claim");
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertEq(pool.maxRedeem(actor), 0, "an immediate exit ranked ahead of an underfunded claim");
            assertEq(pool.maxRequestRedeem(actor), 0, "request service ranked ahead of an underfunded claim");
        }
    }

    function invariant_principalCannotOutliveTheMinimumRealSupply() public view {
        if (pool.outstandingPrincipal() != 0) {
            assertGe(pool.totalSupply(), MIN_SUPPLY_FOR_PRINCIPAL, "principal outlived the minimum supply");
        }
    }

    function invariant_emptyPoolCannotRetainRecyclableShareholderValue() public view {
        if (pool.totalSupply() != 0 || pool.outstandingPrincipal() != 0) return;

        uint256 accounted = _accountedCash(usdc.balanceOf(address(pool)));
        assertLe(accounted, pool.totalClaimable(), "empty pool retained recognised shareholder cash");
        assertEq(pool.pendingYield(), 0, "empty pool retained pending yield");
        assertEq(pool.yieldRate(), 0, "empty pool retained an active stream");
    }

    function invariant_escrowedSharesEqualTheSumOfLiveRequests() public view {
        uint256 requested;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            (,, uint256 shares,,) = pool.withdrawalRequest(handler.actors(i));
            requested += shares;
        }
        assertEq(pool.queuedShares(), requested, "queued shares diverged from live requests");
        assertEq(pool.balanceOf(address(pool)), requested, "request escrow held the wrong shares");
    }

    function invariant_shareSupplyIsFullyAccountedFor() public view {
        uint256 held = pool.balanceOf(address(pool));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            held += pool.balanceOf(handler.actors(i));
        }
        assertEq(pool.totalSupply(), held, "share supply escaped the fixture");
    }

    function invariant_claimableSumEqualsTheFixedLiability() public view {
        uint256 claims;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            claims += pool.claimable(handler.actors(i));
        }
        assertEq(pool.totalClaimable(), claims, "fixed claim liability diverged from receivers");
        assertEq(pool.claimable(address(pool)), 0, "the pool became its own claim receiver");
    }

    /// @notice A paused pool refuses every entry, refuses it as paused, and advertises no room.
    /// @dev The door half is the content: the handler knocks on `deposit` and `mint` while paused
    ///      (`pausedEntryAttempts` is the denominator, asserted in the tripwire) and counts an
    ///      acceptance, or a refusal with any selector but `EnforcedPause`. The view half is the
    ///      ERC-4626 MUST the door half proves, and on its own it restated `_maxDeposit`'s first
    ///      line - which is all `invariant_aPausedPoolAdvertisesNoRoomToEnter` did.
    function invariant_aPausedPoolRefusesEveryEntry() public view {
        assertEq(handler.pausedEntryAccepted(), 0, "a paused pool accepted an entry");
        assertEq(handler.pausedEntryRefusedAsFull(), 0, "a paused pool refused an entry as anything but paused");
        if (!pool.paused()) return;
        assertEq(pool.maxDeposit(handler.actors(0)), 0, "paused pool advertised entry room");
        assertEq(pool.maxMint(handler.actors(0)), 0, "paused pool advertised mint room");
    }

    /// @notice Pausing entry does not change any lender's executable exit maximum.
    /// @dev Measured by the handler either side of every toggle, in both directions. The
    ///      invariant this replaces re-typed `_maxRedeem`'s three-term minimum and asserted it
    ///      only while paused; it held over arbitrary storage, and it went red under round 45's
    ///      `maxWithdraw` neuter only because it happened to re-type the function that was edited.
    function invariant_pausingMovesNoExitMaximum() public view {
        assertEq(handler.pauseMovedAnExitMaximum(), 0, "a pause or unpause moved an exit maximum");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    function invariant_lifetimeAndPrincipalCountersMoveOnlyOnTheirNamedFlows() public view {
        assertEq(handler.lifetimeLossFell(), 0, "lifetime loss fell");
        assertEq(handler.lifetimeLossRoseWithoutLossAction(), 0, "lifetime loss rose without a loss");
        assertEq(handler.principalRoseWithoutLend(), 0, "principal rose without a lend");
    }

    /// @notice A socialised loss reopens exactly its own deposit-cap headroom, and nothing else.
    /// @dev Round 45, item 55, asserted at the transition. What
    ///      `invariant_depositCapUsageIsTheStoredEntryBook` asserted at rest was the view's own
    ///      three-term body, which held over arbitrary storage; that text is a pin now.
    function invariant_aSocialisedLossReopensExactlyItsOwnCapHeadroom() public view {
        assertEq(handler.lossHeadroomMismatches(), 0, "a loss reopened cap headroom other than its own size");
    }

    function invariant_protocolControlledFlowsCannotManufactureAnEntryPriceDeficit() public view {
        assertEq(
            handler.protocolEntryDeficitMismatches(), 0, "a protocol-controlled flow created an entry price deficit"
        );
    }

    function invariant_donationsAreInertOutsideTheDocumentedReplacementWindow() public view {
        assertEq(handler.donationViewMismatches(), 0, "a raw donation changed an economic view");
    }

    function invariant_requestMutationAndServiceAccountingStayControllerScoped() public view {
        assertEq(handler.otherRequestMutations(), 0, "one controller rewrote another request");
        assertEq(handler.serviceAccountingMismatches(), 0, "request service stopped conserving its fixed claim");
    }

    /// @notice Every ERC-4626 door pays or charges exactly what its preview quoted.
    /// @dev Lifted from round 45's bare-maxima campaign. Behavioural rather than a view identity:
    ///      a reconciliation, freeze or re-rate inside the door that moved the price between the
    ///      quote and the execution lands here, and nothing in a preview's body can hold it.
    function invariant_previewsMatchedExecution() public view {
        assertEq(handler.depositMismatches(), 0, "deposit minted other than its preview");
        assertEq(handler.mintMismatches(), 0, "mint charged other than its preview");
        assertEq(handler.withdrawMismatches(), 0, "withdraw burned other than its preview");
        assertEq(handler.redeemMismatches(), 0, "redeem paid other than its preview");
    }

    /// @notice Every door outcome was the one the pool's public views predicted.
    /// @dev The typed catch on the four doors driven without a quoted maximum. The two selector
    ///      assertions come first so the failing one prints what was seen: `actual` is zero when
    ///      the door accepted what the views said it would refuse. Its denominator,
    ///      `predictedRefusals`, is asserted non-zero in the tripwire; the walk refuses often.
    function invariant_everyRefusalWasThePredictedOne() public view {
        assertEq(bytes32(handler.firstUnpredictedActual()), bytes32(0), "first unpredicted outcome, actual selector");
        assertEq(
            bytes32(handler.firstUnpredictedPredicted()), bytes32(0), "first unpredicted outcome, predicted selector"
        );
        assertEq(handler.unpredictedOutcomes(), 0, "a door's outcome was not the one its public views predicted");
    }

    function invariant_mockUsdcIsConservedAcrossEveryKnownHolder() public view {
        uint256 held = usdc.balanceOf(address(pool)) + usdc.balanceOf(creditManager) + usdc.balanceOf(epochHarvester)
            + usdc.balanceOf(address(handler)) + usdc.balanceOf(handler.destructionSink());
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            held += usdc.balanceOf(handler.actors(i));
        }
        assertEq(held, handler.totalMinted(), "USDC escaped the modelled system");
        assertEq(usdc.totalSupply(), handler.totalMinted(), "the mint mirror diverged from token supply");
    }

    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        handler.deposit(0, 5_000e6);
        handler.deposit(1, 5_000e6);
        handler.mintShares(2, 1_000e9);
        handler.transferShares(0, 1, 1);
        handler.withdrawMaximum(0, 1);
        handler.redeemMaximum(1, 1);
        handler.donate(1e6);
        handler.lend(1_000e6);
        handler.repay(500e6);
        handler.distributeYield(100e6);
        handler.passTime(1 days);
        handler.recoverLoss(1e6);
        handler.requestWithdrawal(2, 2, type(uint96).max);
        // Round 48, item 116: actor 0 files while actor 2's request is live, and actor 2 cancels
        // while actor 0's is, so the controller-scope observer compares a LIVE foreign request
        // rather than two empty fingerprints. Same end state as the old order.
        handler.requestWithdrawal(0, 2, type(uint96).max);
        handler.cancelWithdrawalRequest(2);
        handler.serviceWithdrawalRequest(0, type(uint96).max);
        handler.impair(0, 100e6);
        handler.releaseImpairment(0);
        handler.socialiseLoss(500e6);
        uint256 rawCash = usdc.balanceOf(address(pool));
        assertLe(rawCash, type(uint96).max, "fixture cash exceeded the handler seed");
        handler.destroyRawCash(uint96(rawCash));
        handler.reconcileCashDeficit();
        uint256 claimDeficit = canonical.claimSolvencyDeficit();
        assertGt(claimDeficit, 0, "fixture did not make the fixed claim insolvent");
        assertLe(claimDeficit, type(uint96).max, "fixture claim exceeded the handler seed");
        handler.coverClaimDeficit(uint96(claimDeficit));
        handler.claim(2);
        handler.togglePause();
        handler.togglePause();

        assertGt(handler.depositsDone(), 0, "entry was never reached");
        assertGt(handler.mintsDone(), 0, "exact-share entry was never reached");
        assertGt(handler.withdrawalsDone(), 0, "asset exit was never reached");
        assertGt(handler.redeemsDone(), 0, "share exit was never reached");
        assertGt(handler.donationsDone(), 0, "raw donation was never reached");
        assertGt(handler.lendsDone(), 0, "lending was never reached");
        assertGt(handler.repaysDone(), 0, "repayment was never reached");
        assertGt(handler.yieldsDone(), 0, "yield delivery was never reached");
        assertGt(handler.recoveriesDone(), 0, "loss recovery was never reached");
        assertGt(handler.timeAdvances(), 0, "stream time never moved");
        assertGt(handler.requestsDone(), 0, "request creation was never reached");
        assertGt(handler.cancellationsDone(), 0, "request cancellation was never reached");
        assertGt(handler.servicesDone(), 0, "request service was never reached");
        assertGt(handler.coversDone(), 0, "claim-deficit cover was never reached");
        assertGt(handler.claimsDone(), 0, "claim collection was never reached");
        assertGt(handler.transfersDone(), 0, "share transfer was never reached");
        assertGt(handler.impairmentsDone(), 0, "impairment was never reached");
        assertGt(handler.releasesDone(), 0, "impairment release was never reached");
        assertGt(handler.lossesDone(), 0, "loss socialisation was never reached");
        assertGt(handler.destructionsDone(), 0, "external cash destruction was never reached");
        assertGt(handler.reconciliationsDone(), 0, "cash reconciliation was never reached");
        assertGt(handler.pausesDone(), 0, "pause was never reached");
        assertGt(handler.unpausesDone(), 0, "unpause was never reached");

        // Round 48, item 116: the legal half of every transition the violation counters count.
        assertGt(handler.donationViewChecks(), 0, "no donation was ever compared against the views");
        assertGt(handler.principalRoseOnALend(), 0, "the observer never saw principal rise across a lend");
        assertGt(handler.foreignRequestsObserved(), 0, "no request door acted beside a live foreign request");
        assertGt(handler.lifetimeLossRoseOnALoss(), 0, "the observer never saw lifetime loss rise across a loss");
        assertGt(handler.lossHeadroomChecks(), 0, "the loss-headroom recorder never compared a moving headroom");
        // Round-50 item 143: the SETTLE arm only, and named as such. This walk never calls
        // `stressLossRefill`, so the refill arm is not reachable from here and asserting it would
        // be a false claim rather than a stronger one. It is asserted in
        // `test_handlerCanReachTheNumericReserveAndRepairAnExternalPriceDeficit`, which is the walk
        // that reaches the numeric boundary. One counter used to cover both, and this assertion
        // passed on the first deposit while saying nothing whatever about the other arm.
        assertGt(
            handler.protocolEntryDeficitChecksAtSettle(),
            0,
            "the entry-deficit recorder never ran after a watched action"
        );

        // ── Round 46: the states the round-45 campaign never walked ──────────────────────────
        // The pool above ends with shares outstanding and no cash, so it is refunded first.
        handler.deposit(1, 5_000e6);
        handler.deposit(3, 5_000e6);
        handler.depositFor(0, 2, 1_000e6);
        assertGt(handler.depositForDone(), 0, "a deposit to a foreign receiver was never reached");

        handler.lend(2_000e6);
        handler.impairWithinPrincipal(0, 100e6);
        assertGt(handler.partialMarkStates(), 0, "a partial mark was never reached");
        handler.setLossReserves(50e6, 40e6);
        assertGt(handler.lossReserveWrites(), 0, "the loss-reserve push was never reached");
        assertGt(handler.nettedMarkStates(), 0, "an insurance-netted mark was never reached");
        assertGt(handler.backlogStates(), 0, "a loss backlog was never reached");

        handler.togglePause();
        assertGt(handler.pauseTogglesWithALiveExitMaximum(), 0, "no toggle ever had a live exit maximum to move");
        handler.deposit(1, 100e6);
        handler.mintShares(1, 100e9);
        assertGt(handler.pausedEntryAttempts(), 0, "no entry was attempted while paused");
        assertEq(handler.pausedEntryAccepted(), 0, "a paused pool accepted an entry");
        assertEq(handler.pausedEntryRefusedAsFull(), 0, "a paused pool refused an entry as full");
        handler.togglePause();
        handler.releaseImpairment(0);
        handler.setLossReserves(0, 0);

        handler.requestAll(3, 3);
        assertGt(handler.exhaustiveRequestsDone(), 0, "a whole-balance request was never reached");
        handler.serviceWithdrawalRequestMaximum(3);
        assertGt(handler.exhaustiveServicesDone(), 0, "service at the exact maximum was never reached");
        handler.claimFor(3, 0);
        assertGt(handler.claimForsDone(), 0, "a third-party claim was never reached");

        handler.requestAll(2, 2);
        handler.serviceByOperator(2, 1);
        assertGt(handler.operatorServicesDone(), 0, "an operator service was never reached");
        handler.claim(2);
        handler.cancelWithdrawalRequest(2);

        handler.repay(3_000e6);
        handler.redeemViaAllowance(1, 0);
        assertGt(handler.allowanceExitsDone(), 0, "an allowance exit was never reached");
        handler.withdrawAll(0);
        handler.redeemAll(2);
        assertGt(handler.exhaustiveExitsDone(), 0, "an exit at the exact maximum was never reached");

        handler.destroyAllRawCash();
        assertGt(handler.fullDestructionsDone(), 0, "whole-balance destruction was never reached");
        handler.reconcileCashDeficit();

        assertGt(handler.predictedRefusals(), 0, "no door refusal was ever predicted and met");
        assertEq(handler.unpredictedOutcomes(), 0, "a door outcome was not the predicted one");
        assertEq(handler.pauseMovedAnExitMaximum(), 0, "a toggle moved an exit maximum");
        assertEq(handler.lossHeadroomMismatches(), 0, "a loss reopened headroom other than its own size");
        assertEq(handler.depositMismatches(), 0, "deposit minted other than its preview");
        assertEq(handler.mintMismatches(), 0, "mint charged other than its preview");
        assertEq(handler.withdrawMismatches(), 0, "withdraw burned other than its preview");
        assertEq(handler.redeemMismatches(), 0, "redeem paid other than its preview");
    }

    /// @notice The handler reaches the sub-floor entry price through its own actions, so the
    ///         campaign's reach is proven here rather than sampled from a replayed run.
    /// @dev Round 45, item 55. A deterministic one-shot rather than a per-run floor, for the
    ///      reason given on `afterInvariant`. The route is the production one and nothing else:
    ///      a genesis deposit landing exactly on `MIN_SUPPLY_FOR_PRINCIPAL` shares, then
    ///      `recoverLoss` streaming a pot a hundred thousand times the backing, which entry
    ///      prices in the same block. Both handler calls are the ordinary fuzz actions, so a
    ///      campaign that happens to sequence them reaches the same state. The refusal at the
    ///      end is the handler's own deposit arm meeting the round-22 guard, and since round 46
    ///      that refusal is also the predicted one: `ZeroAmount`, from `previewDeposit(1) == 0`.
    function test_handlerCanReachTheSubFloorEntryPrice() public {
        address receiver = handler.actors(0);
        handler.deposit(0, 10_000);
        assertEq(pool.totalSupply(), MIN_SUPPLY_FOR_PRINCIPAL, "fixture: the genesis deposit missed the yield floor");
        assertEq(handler.subFloorStatesSeen(), 0, "fixture: the sub-floor state preceded the lever");

        handler.recoverLoss(1_000e6);

        emit log_named_uint("sub-floor states seen", handler.subFloorStatesSeen());
        emit log_named_uint("one-share floor (asset-wei)", pool.previewMint(1));
        emit log_named_uint("maxDeposit at the floor", pool.maxDeposit(receiver));

        assertGt(handler.subFloorStatesSeen(), 0, "the handler never reached the sub-floor state");
        assertEq(pool.previewDeposit(1), 0, "one asset-wei still buys a share");
        assertGt(pool.maxDeposit(receiver), 0, "entry closed rather than going sub-floor");
        assertGe(pool.maxDeposit(receiver), pool.previewMint(1), "the maximum sits below the floor");

        handler.deposit(0, 1);
        assertEq(handler.zeroShareDeposits(), 0, "a sub-floor deposit was accepted against nothing");
        assertEq(pool.balanceOf(receiver), MIN_SUPPLY_FOR_PRINCIPAL, "the refused deposit minted shares");
        assertGt(handler.predictedRefusals(), 0, "the sub-floor refusal was not the predicted one");
        assertEq(handler.unpredictedOutcomes(), 0, "the sub-floor refusal carried an unpredicted selector");
    }

    function test_handlerCanReachTheNumericReserveAndRepairAnExternalPriceDeficit() public {
        handler.deposit(0, 5_000e6);
        for (uint256 i; i < 40 && handler.lendTapersReached() == 0; ++i) {
            handler.stressLossRefill(type(uint8).max, 0);
        }

        emit log_named_uint("loss-refill cycles", handler.lossRefillCyclesDone());
        emit log_named_uint("numeric reserve states", handler.numericReserveStatesReached());
        emit log_named_uint("lend tapers", handler.lendTapersReached());

        assertGt(handler.lossRefillCyclesDone(), 0, "loss-refill stress never completed a cycle");
        assertGt(handler.numericReserveStatesReached(), 0, "loss-refill stress never reached the numeric reserve");
        assertGt(handler.lendTapersReached(), 0, "numeric reserve never tapered lending to zero");
        assertEq(pool.available(), 0, "tapered boundary still advertised lendable cash");
        assertEq(pool.outstandingPrincipal(), 0, "stress boundary retained principal");
        assertEq(canonical.entryPriceDeficit(), 0, "protocol stress created a price deficit");
        assertLe(pool.totalSupply(), canonical.maximumShareSupply(), "stress crossed the absolute share ceiling");

        uint256 required = canonical.minimumEntryAssets();
        uint256 raw = usdc.balanceOf(address(pool));
        assertGt(required, 0, "numeric reserve fixture remained trivial");
        assertGe(raw, required, "stress ended below its own entry backing");
        uint256 externalLoss = raw - required + 1;
        assertLe(externalLoss, type(uint96).max, "external loss exceeded the handler seed");
        handler.destroyRawCash(uint96(externalLoss));

        assertEq(canonical.entryPriceDeficit(), 1, "projected external loss exposed the wrong price deficit");
        assertEq(pool.maxDeposit(handler.actors(0)), 0, "projected price deficit left maxDeposit open");
        assertEq(pool.maxMint(handler.actors(0)), 0, "projected price deficit left maxMint open");
        handler.reconcileCashDeficit();
        assertEq(canonical.entryPriceDeficit(), 1, "reconciliation changed the projected price deficit");

        handler.coverEntryPriceDeficit(1);
        emit log_named_uint("entry covers", handler.entryCoversDone());
        assertGt(handler.entryCoversDone(), 0, "entry-price cover action was never reached");
        assertEq(canonical.entryPriceDeficit(), 0, "exact entry-price cover left a deficit");
        assertGt(pool.maxDeposit(handler.actors(0)), 0, "exact cover did not reopen maxDeposit");
        assertGt(pool.maxMint(handler.actors(0)), 0, "exact cover did not reopen maxMint");
        // Round-50 item 143: BOTH arms, and the refill one is the load-bearing half of this test.
        // It is the only walk in the file that runs `stressLossRefill`, so it is the only place the
        // lend/socialise cycles at the numeric reserve are ever measured for a manufactured
        // deficit. Until the counter was split, this line was satisfied by the settle arm - which
        // the first `handler.deposit` above had already pushed above zero - and the mismatch
        // assertion below could have been green over a recorder that never ran at the boundary.
        assertGt(
            handler.protocolEntryDeficitChecksAtRefill(),
            0,
            "the entry-deficit recorder never ran inside a loss-refill cycle"
        );
        assertGt(
            handler.protocolEntryDeficitChecksAtSettle(),
            0,
            "the entry-deficit recorder never ran after a watched action"
        );
        assertEq(handler.protocolEntryDeficitMismatches(), 0, "protocol stress manufactured a price deficit");
    }

    function _accountedCash(uint256 raw) private view returns (uint256) {
        uint256 deficit = canonical.cashDeficit();
        uint256 surplus = canonical.unmanagedSurplus();
        return raw + deficit - surplus;
    }
}
