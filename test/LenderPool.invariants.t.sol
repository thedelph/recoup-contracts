// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Randomised call sequences against the lender pool. The fuzzer plays four lenders, the
///         credit manager and the harvester in arbitrary order; the invariants below must hold
///         after every sequence.
/// @dev The roles are separate EOAs the handler pranks, not the handler itself. Two reasons, both
///      load-bearing: `repayPrincipal` and `distributeYield` pull with `safeTransferFrom(msg.sender)`
///      so the role needs its own balance, and mixing that into the handler's would make the USDC
///      conservation invariant a statement about one pot rather than several. And `lend` pays the
///      credit manager, so a handler that was also the credit manager would never let the money
///      leave the protocol side at all.
///
///      **There is a `passTime` action, and for four audit rounds there was not.** This paragraph
///      used to say the pool had no time dependence anywhere, which stopped being true the day the
///      yield stream landed and stayed written down for months afterwards. Confirmed over 128,000
///      invariant calls in audit round 15: the clock never moved, so `unreleasedYield` never
///      decayed, both anti-JIT rules in `_rateStream` were dead code, and the two price-monotonicity
///      invariants only ever saw a price moving down. The action's own counter is not the evidence
///      that this is fixed - `streamReleases` and `releasedBookPriceRisesOnTheClock` are, because they
///      count the clock reaching the mechanism rather than the clock moving.
contract LenderHandler is Test {
    /// @notice A fixed number of shares to value on the released, un-impaired book, so the result is
    ///         a price rather than a total that moves when supply does.
    /// @dev Declared here and read by the suite rather than written down in both. The handler needs
    ///      it for the clock ghosts and the suite needs it for the two monotonicity invariants, and
    ///      a fixture literal that appears twice is one edit away from meaning two different things.
    uint256 public constant PRICE_PROBE_SHARES = 1e12;

    LenderPool public immutable pool;
    MockUSDC public immutable usdc;
    address public immutable creditManager;
    address public immutable epochHarvester;

    address[] public actors;

    /// @notice Addresses the pool holds impairments against. Deliberately disjoint from `actors`.
    /// @dev `impair` takes any address and never checks that it is a borrower - the pool has no way
    ///      to know - so nothing stops a fixture marking down a lender. Keeping the two sets apart
    ///      keeps the suite honest about what an impairment is: a reserve against a *position*,
    ///      which every share in the pool carries a pro-rata slice of. A reserve keyed to an actor
    ///      who also holds shares would read as though the pool could mark one lender down
    ///      individually, which it cannot and must never look like it can.
    address[] public borrowers;

    /// @notice Mirror: every USDC unit this fixture has ever created. A *quantity*, and the
    ///         reference point `invariant_usdcIsConserved` measures against - the handler is the
    ///         only minter, so anything that leaves the fixture shows up as a shortfall here.
    uint256 public totalMinted;

    /// @notice Coverage ghosts, distinct from the mirror above: that one is a quantity and stays
    ///         put whether an action never ran or ran and moved nothing. These count occurrences.
    ///         Every interesting action is wrapped in `try` - it has to be, since most random
    ///         sequences are meaningless and must not fail a run - so without these a fixture that
    ///         could never reach a queue would report a dozen green invariants having exercised
    ///         nothing. `test_handlerCanReachEveryStateTheInvariantsCheck` asserts them.
    uint256 public depositsDone;
    uint256 public depositsRefusedByCap;

    /// @notice The second legal refusal on the entry side, added by audit round 22 finding 2.
    /// @dev A deposit too small to buy one wei of share used to take the USDC and mint nothing for
    ///      it. `_deposit` refuses it now, and this campaign found the state on its own: one
    ///      `donate` of 2.5e62 wei followed by a 220-wei deposit, in two calls. Counted separately
    ///      from the cap refusal because they are different refusals about different things, and a
    ///      single counter would let one of them fall to zero unnoticed.
    uint256 public depositsRefusedAsZeroShare;
    uint256 public mintsDone;
    uint256 public withdrawsDone;
    uint256 public redeemsDone;
    uint256 public requestsQueued;
    uint256 public requestsRefusedAsDuplicate;
    uint256 public cancelsDone;
    uint256 public fullFills;
    uint256 public partialFills;
    uint256 public dustReleases;

    /// @notice **The numerator beside `dustReleases`.** Times an entry was handed back as dust while
    ///         it was still worth an asset-wei on the un-impaired book: it must stay zero.
    /// @dev Audit round 12's eviction, as a counter rather than as one scenario. A markdown is
    ///      temporary and a lost place in a FIFO queue is not, so "this can never be worth anything"
    ///      has to be asked of the released, un-impaired book price, never of the exit price. The
    ///      release branch is already written that way; nothing was watching whether it stayed that
    ///      way.
    uint256 public dustReleasedWhileStillWorthSomething;
    uint256 public lendsDone;
    uint256 public lendsWhileQueued;
    uint256 public repaysDone;
    uint256 public overRepaysDone;
    /// @notice Recoveries booked against a loss the pool had already absorbed, and the ones that
    ///         landed while the pool was too small to raise the price of.
    /// @dev Audit round 21, finding 14. Two counters rather than one because the second is an
    ///      anti-just-in-time rule copied from `repayPrincipal`'s surplus branch, and this file's
    ///      own standing lesson is that a rule with no denominator is silence.
    uint256 public lossRecoveriesDone;
    uint256 public lossRecoveriesFrozenBelowTheShareFloor;
    uint256 public yieldDistributions;
    uint256 public lossesSocialised;
    uint256 public lossesClamped;
    uint256 public claimsDone;
    uint256 public impairmentsSet;
    uint256 public impairmentsReleased;
    uint256 public backlogsSet;
    uint256 public coversSet;

    /// @notice The clock, and the two things it has to actually reach.
    /// @dev `timeAdvances` on its own would be the defect it fixes wearing a new name: it proves the
    ///      action exists, not that the pool's three clock dependencies are exercised. The other two
    ///      are derived from observed state either side of the jump, so they cannot be satisfied by
    ///      a `skip` that lands nowhere interesting.
    uint256 public donationsDone;
    uint256 public timeAdvances;
    uint256 public streamReleases;
    uint256 public releasedBookPriceRisesOnTheClock;
    uint256 public yieldRefusedAsTooLargeForTheCapital;
    uint256 public yieldRefusedWithNoSharesOutstanding;

    /// @notice Times `serviceQueue` refused while the money to pay its head was sitting in the
    ///         pool. The signature of the bug this suite was written around: it must stay zero.
    uint256 public serviceRefusedWithFundsAndQueue;

    /// @notice The denominator beside it: refusals under a standing reserve with cash in the pool.
    /// @dev The state the wedge exclusion admits. Audit round 15 found it covered by nothing
    ///      anywhere, because the exclusion named it and then nothing counted it - so an exclusion
    ///      that had quietly grown to swallow every refusal would have looked identical.
    uint256 public refusalsUnderAStandingReserveWithCashPresent;

    /// @notice **The numerator.** Times any exit paid out more than the shares it burned were worth
    ///         at the exit price. Round-10 finding 7 in one number, restated for the mechanism that
    ///         replaced the gate: it must stay zero.
    /// @dev Counted from outside and checked against arithmetic this file does itself - see
    ///      `_paidAboveTheExitPrice`. Asking `previewRedeem` what the pool would pay and then
    ///      checking that it paid that would restate the line under test, which is green on the bug
    ///      and red on the fix.
    uint256 public exitsAboveTheImpairedPrice;

    /// @notice **The denominators, and they are the point.** How many exits actually ran while a
    ///         reserve was standing against the book, split by route.
    /// @dev The counter these replace counted exits taken while the round-10 gate was up, and it
    ///      was structurally pinned at zero by the very gate it was written to test: the gate made
    ///      `maxWithdraw` return zero, so both handler actions bailed out before they could ever
    ///      count, and the invariant over it passed by construction while a lender could walk out
    ///      through the queue. A zero numerator over a zero denominator is that same vacuity in a
    ///      new costume, so these are asserted **non-zero** by
    ///      `test_handlerCanReachEveryStateTheInvariantsCheck`.
    ///
    ///      Split in two because the two routes price through different code - `redeem`/`withdraw`
    ///      go through `previewRedeem`/`previewWithdraw`, `serviceQueue` calls `_exitToAssets` and
    ///      `_exitToShares` directly on its own two branches - and round 11 was found in the second
    ///      one after the first had been declared covered.
    uint256 public exitsPricedAgainstAnImpairment;
    /// @notice **Was a denominator, is now a numerator, and audit round 16 turned it round.**
    ///         Times the queue paid anybody out while a reserve stood against the book: it must
    ///         stay zero.
    /// @dev It used to count queued exits *priced* against a live mark and was asserted non-zero,
    ///      because under the old walk that state was the one round 11 was found in. The walk now
    ///      refuses to crystallise a live entry while a reserve stands, so that state no longer
    ///      exists and a non-zero assertion over it would be unsatisfiable - the same "pinned by
    ///      the mechanism it tests" shape as round 11's own counter, arriving from the other side.
    ///      Kept and inverted rather than deleted: the fact it used to measure is now the fact that
    ///      must never happen, and `refusalsUnderAStandingReserveWithCashPresent` is the
    ///      denominator proving the fuzzer reaches the state at all.
    uint256 public queuedExitsPaidWhileAReserveStood;

    /// @notice **The six "compared with last time" observations, moved in here from the runner.**
    /// @dev Measured on 2026-08-17, in this file, over 128,000 invariant calls: **forge 1.7.1
    ///      evaluates every `invariant_` function against a snapshot and rolls its writes back.** An
    ///      `invariant_` that increments a counter and asserts the counter stays under three passes
    ///      the whole campaign. So an invariant of the shape "remember what I saw last time, assert
    ///      this time relates to it" never remembers anything: its `last…` field holds the value
    ///      `setUp` left, on every one of the 128,000 calls, and a probe measured exactly that for
    ///      all nine of the fields these counters replace. Six invariants here were written in that
    ///      shape and each silently degraded into a comparison against the fixture's opening state -
    ///      which for the two prices was a guard carrying a factor of two thousand of slack, and for
    ///      the head and the two counters was `x >= 0`.
    ///
    ///      The observation therefore has to happen where state survives, which is the handler: the
    ///      `watched` modifier reads either side of **every** action. Counters rather than
    ///      assertions, deliberately - a forge-std assertion inside a handler reverts, and under
    ///      `fail_on_revert = false` a reverting handler call is discarded, so an in-handler
    ///      assertion fails invisibly *and* truncates the state space. Same idiom as
    ///      `exitsAboveTheImpairedPrice` above, and for the same reason.
    ///
    ///      Each numerator carries a denominator, because a numerator pinned at zero by a fixture
    ///      that never reaches the state is the vacuity this file already has a history of. The
    ///      denominators are asserted non-zero by
    ///      `test_handlerCanReachEveryStateTheInvariantsCheck`.
    uint256 public headWentBackwards;
    uint256 public headAdvances;

    uint256 public lifetimeLossFell;
    uint256 public lifetimeLossRoseWithNoSocialisedLoss;
    uint256 public lifetimeLossRises;

    uint256 public principalRoseWithNoLend;
    uint256 public principalRises;

    uint256 public releasedBookPriceFellWithNoRealisedLoss;
    uint256 public releasedBookPriceFalls;

    uint256 public exitPriceFellWithNeitherAReserveNorALoss;
    uint256 public exitPriceFalls;

    /// @notice The deposit-cap counter, watched the same way as the five above.
    /// @dev **Audit round 22, finding 15: this layer had no property on `netDeposits` at all.**
    ///      Twenty-three invariants at 256 runs / 128,000 calls each passed 24 of 24 with round
    ///      21's flagship fix reverted at **both** doors - the two lines commit `719f4e4` added -
    ///      so the layer was blind to the flagship fix of the round it was extended in.
    ///
    ///      `netDepositsFalls` is the reach control and it is the reason the green above is not
    ///      "the walk never withdraws": an invariant asserting the counter never falls goes red
    ///      immediately, shrunk to `deposit -> queueExit`. It is asserted non-zero by the tripwire
    ///      rather than shipped as an invariant, because the state it names is ordinary rather
    ///      than forbidden.
    ///
    ///      **What this pair does NOT catch, said plainly rather than implied by omission.**
    ///      Reverting the round-21 fix changes the *size* of a fall, never the *cause* of a rise,
    ///      so `netDepositsRoseWithNoDepositOrMint` stays at zero under both neuters. The
    ///      discriminator for that is the conservation property - `netDeposits` equalling the sum
    ///      of every holder's principal basis - and it belongs with whichever accounting rule
    ///      wins, not here. What is shipped here is the half that is true regardless of the rule:
    ///      a counter measuring what lenders put in may only ever rise when a lender puts
    ///      something in.
    uint256 public netDepositsRoseWithNoDepositOrMint;
    uint256 public netDepositsRises;
    uint256 public netDepositsFalls;

    /// @notice Independent entry-side check for the principal-unit issuance formula.
    /// @dev This remains live after a total-loss generation reset, unlike a condition gated on the
    ///      lifetime loss counter, which can never return to zero.
    uint256 public principalUnitIssuances;
    uint256 public principalUnitIssuanceMismatches;

    /// @notice Successful live-tail entries and independently observed quote disagreements.
    /// @dev The production previews deliberately diverge from `convertToAssets`/`convertToShares`
    ///      while a stream is live: exact entry prices include the projected unreleased tail, while
    ///      the conversion views continue to report the released, un-impaired book. These counters
    ///      reproduce OpenZeppelin's virtual-share arithmetic from public state instead of asking
    ///      either preview for the answer. Assertions do not belong in the handler because a
    ///      forge-std assertion reverts and `fail_on_revert = false` would discard the evidence.
    uint256 public activeTailDeposits;
    uint256 public activeTailDepositQuoteMismatches;
    uint256 public activeTailMints;
    uint256 public activeTailMintQuoteMismatches;

    struct ActiveTailQuote {
        bool observed;
        uint256 amount;
    }

    /// @notice Reads the six watched quantities either side of every action.
    /// @dev The post-block is a call rather than inline code because the pair does not fit on the
    ///      stack otherwise, and because a single writer for all six keeps the "loss landed" test
    ///      identical across them - the three that need it were three separate transcriptions
    ///      before, and one of them tested the loss counter against a different field.
    ///
    ///      Every read here is a `view` on the pool, so nothing in this modifier can revert and
    ///      `invariant_theHandlerNeverDropsAFrame` is not put at risk by it. It does consume a
    ///      dangling `vm.prank` if an action ever left one - none do, every prank in this handler is
    ///      immediately followed by the call that spends it, and that is a property to keep.
    /// @dev **Storage, not locals, and not a memory struct.** Held on the stack the eight readings
    ///      stay live across the modifier's `_`, so they stack under every local the action itself
    ///      declares and the compiler runs out of slots - measured, `serviceQueue` alone puts it
    ///      over. Held as a *memory* struct they would be a trap of a different kind: assigning one
    ///      memory struct to another aliases rather than copies, so a `before = after` would move
    ///      both and every direction test would read equal. Storage has neither problem, and the
    ///      handler's actions never nest, so one slot is enough.
    struct Watch {
        uint256 head;
        uint256 loss;
        uint256 principal;
        uint256 releasedBookPrice;
        uint256 exitPrice;
        uint256 reserve;
        uint256 losses;
        uint256 lends;
        uint256 netDeposits;
        uint256 entries;
    }

    Watch private _before;

    modifier watched() {
        _observe();
        _;
        _settle();
    }

    function _observe() private {
        _before.head = pool.queueHead();
        _before.loss = pool.lifetimeSocialisedLoss();
        _before.principal = pool.outstandingPrincipal();
        _before.releasedBookPrice = pool.convertToAssets(PRICE_PROBE_SHARES);
        _before.exitPrice = pool.previewRedeem(PRICE_PROBE_SHARES);
        _before.reserve = pool.exitReserve();
        _before.losses = lossesSocialised;
        _before.lends = lendsDone;
        _before.netDeposits = pool.netDeposits();
        _before.entries = depositsDone + mintsDone;
    }

    function _settle() private {
        uint256 headBefore = _before.head;
        uint256 lossBefore = _before.loss;
        uint256 principalBefore = _before.principal;
        uint256 releasedBookBefore = _before.releasedBookPrice;
        uint256 exitBefore = _before.exitPrice;
        uint256 reserveBefore = _before.reserve;
        uint256 lossesBefore = _before.losses;
        uint256 lendsBefore = _before.lends;

        // A realised loss, asked once and shared by the three observations that exclude on it.
        bool aLossLanded = lossesSocialised != lossesBefore;

        uint256 head = pool.queueHead();
        if (head < headBefore) ++headWentBackwards;
        if (head > headBefore) ++headAdvances;

        uint256 loss = pool.lifetimeSocialisedLoss();
        if (loss < lossBefore) ++lifetimeLossFell;
        if (loss > lossBefore) {
            ++lifetimeLossRises;
            if (!aLossLanded) ++lifetimeLossRoseWithNoSocialisedLoss;
        }

        uint256 principal = pool.outstandingPrincipal();
        if (principal > principalBefore) {
            ++principalRises;
            if (lendsDone == lendsBefore) ++principalRoseWithNoLend;
        }

        uint256 releasedBook = pool.convertToAssets(PRICE_PROBE_SHARES);
        if (releasedBook < releasedBookBefore) {
            ++releasedBookPriceFalls;
            if (!aLossLanded) ++releasedBookPriceFellWithNoRealisedLoss;
        }

        uint256 exit_ = pool.previewRedeem(PRICE_PROBE_SHARES);
        if (exit_ < exitBefore) {
            ++exitPriceFalls;
            // The reserve is read rather than counted, for the reason the invariant this replaces
            // already gave: `impair` is not its only writer. `setLossReserves` moves it, and so does
            // the exposure clamp whenever `outstandingPrincipal` moves, with nobody calling
            // anything that names a reserve.
            if (!aLossLanded && pool.exitReserve() <= reserveBefore) {
                ++exitPriceFellWithNeitherAReserveNorALoss;
            }
        }

        // Read straight off `_before` rather than through locals of its own: the eight above
        // already crowd the stack across the modifier's `_`, which is why they are storage in the
        // first place, and two more would put `serviceQueue` over.
        uint256 net = pool.netDeposits();
        if (net > _before.netDeposits) {
            ++netDepositsRises;
            if (depositsDone + mintsDone == _before.entries) ++netDepositsRoseWithNoDepositOrMint;
        }
        if (net < _before.netDeposits) ++netDepositsFalls;
    }

    constructor(LenderPool pool_, MockUSDC usdc_, address creditManager_, address epochHarvester_) {
        pool = pool_;
        usdc = usdc_;
        creditManager = creditManager_;
        epochHarvester = epochHarvester_;

        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("lender", i)));
            actors.push(a);
            vm.prank(a);
            usdc.approve(address(pool), type(uint256).max);
        }

        for (uint256 i = 0; i < 2; i++) {
            borrowers.push(makeAddr(string(abi.encodePacked("borrower", i))));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _borrower(uint256 seed) internal view returns (address) {
        return borrowers[seed % borrowers.length];
    }

    /// @dev So an invariant can walk the other direction and check that no marked borrower is
    ///      missing from the pool's own set.
    function borrowerCount() external view returns (uint256) {
        return borrowers.length;
    }

    /// @dev The claim `exitsAboveTheImpairedPrice` counts, written in money and cross-multiplied so
    ///      there is no division here and therefore no rounding argument to get wrong: whatever an
    ///      exit paid out must be no more than the shares it burned, valued pro rata against the
    ///      book *after* the reserve.
    ///
    ///      `exitAssets()` is read from the pool rather than recomposed, because that view is one
    ///      subtraction and recomposing it would prove nothing. What is deliberately **not** taken
    ///      from the pool is the per-share division, because that is where the exit paths could
    ///      disagree with each other - and round 11 was exactly a case of one of them having been
    ///      left out of a change the rest of them got.
    ///
    ///      The virtual-share term is derived from the two token decimals rather than written down.
    ///      A literal `1e3` here would pin `_decimalsOffset()` from a file that never names it,
    ///      which is how a fixture literal survives the parameter it was chosen for.
    function _paidAboveTheExitPrice(
        uint256 paidAssets,
        uint256 burnedShares,
        uint256 exitAssetsBefore,
        uint256 supplyBefore
    ) private view returns (bool) {
        uint256 virtualShares = 10 ** (pool.decimals() - usdc.decimals());
        return paidAssets * (supplyBefore + virtualShares) > burnedShares * (exitAssetsBefore + 1);
    }

    /// @dev Every mint goes through here. `invariant_usdcIsConserved` is only an independent
    ///      check for as long as that stays true.
    function _mint(address to, uint256 amount) internal {
        usdc.mint(to, amount);
        totalMinted += amount;
    }

    function _recordPrincipalUnitIssuance(uint256 unitsBefore, uint256 netBefore, uint256 assets) private {
        uint256 expected = unitsBefore == 0
            ? assets
            : Math.mulDiv(assets, unitsBefore, netBefore, Math.Rounding.Ceil);
        ++principalUnitIssuances;
        if (pool.totalPrincipalUnits() != unitsBefore + expected) ++principalUnitIssuanceMismatches;
    }

    /// @dev An independent transcription of the exact-entry deposit quote. The pool's preview is
    ///      deliberately not read: this counter exists to catch that preview falling back to the
    ///      released book. A zero-rate pot is frozen, not an active tail, and remains outside the
    ///      quote until a later delivery rates it again.
    function _activeTailDepositQuote(uint256 assets) private view returns (ActiveTailQuote memory quote) {
        uint256 tail = pool.unreleasedYield();
        if (pool.yieldRate() == 0 || tail == 0) return quote;

        uint256 virtualShares = 10 ** (pool.decimals() - usdc.decimals());
        quote.observed = true;
        quote.amount =
            Math.mulDiv(assets, pool.totalSupply() + virtualShares, pool.totalAssets() + tail + 1, Math.Rounding.Floor);
    }

    /// @dev The share-input twin: OpenZeppelin's virtual terms, but against the same active gross
    ///      shareholder book and rounded up so a requested share amount is fully paid for.
    function _activeTailMintQuote(uint256 shares) private view returns (ActiveTailQuote memory quote) {
        uint256 tail = pool.unreleasedYield();
        if (pool.yieldRate() == 0 || tail == 0) return quote;

        uint256 virtualShares = 10 ** (pool.decimals() - usdc.decimals());
        quote.observed = true;
        quote.amount =
            Math.mulDiv(shares, pool.totalAssets() + tail + 1, pool.totalSupply() + virtualShares, Math.Rounding.Ceil);
    }

    // ── lender-facing ────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 receiverSeed, uint256 assets) external watched {
        address a = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        assets = bound(assets, 1, 5_000e6);
        ActiveTailQuote memory tailQuote = _activeTailDepositQuote(assets);
        uint256 unitsBefore = pool.totalPrincipalUnits();
        uint256 netBefore = pool.netDeposits();
        _mint(a, assets);

        vm.prank(a);
        try pool.deposit(assets, receiver) returns (uint256 mintedShares) {
            ++depositsDone;
            if (tailQuote.observed) {
                ++activeTailDeposits;
                if (mintedShares != tailQuote.amount) ++activeTailDepositQuoteMismatches;
            }
            _recordPrincipalUnitIssuance(unitsBefore, netBefore, assets);
            // **`netDeposits`, not `totalAssets()`, and `LenderPool.sol:738` says why.** The cap is
            // sized from what lenders put in, deliberately, because audit round 11 found a donation
            // to `totalAssets()` would otherwise close the pool permanently. Asserting the cap
            // against `totalAssets()` therefore names a property the contract does not have and was
            // designed not to have: it fires the moment released yield lifts the pool past 25,000
            // USDC, which is ordinary operation. It was firing, and nobody saw it - a forge-std
            // assertion inside a handler reverts, and under `fail_on_revert = false` a reverting
            // handler call is discarded. So the failure was invisible **and** every deposit that
            // triggered it was rolled back, which quietly stopped this suite depositing at all
            // above that size.
            //
            // The subject on the right moved too. `Config.LENDER_POOL_DEPOSIT_CAP` was a constant
            // aliased to the global borrow cap; the pool owns settable storage now, so this reads
            // `pool.depositCap()` live rather than a compile-time figure that a `setDepositCap`
            // mid-sequence would leave behind. Same claim, still asserted, still exact.
            assertLe(pool.netDeposits(), pool.depositCap(), "deposit crossed the cap");
        } catch (bytes memory err) {
            // **Two legal refusals since audit round 22 finding 2, and the second one is why this
            // arm cannot just assert the cap selector.** A deposit small enough to round to zero
            // shares is refused rather than swallowed, and this campaign reaches that state
            // unaided - a donation lifts the share price far enough that a small deposit buys
            // nothing. Left as a bare `assertEq` against the cap selector it would have been
            // invisible in the worst way: a forge-std assertion inside a handler reverts, and under
            // `fail_on_revert = false` a reverting handler call is discarded, so every deposit past
            // that point would have silently stopped happening. It failed loudly instead only
            // because `invariant_theHandlerNeverDropsAFrame` watches for exactly that.
            bytes4 selector = bytes4(err);
            if (selector == LenderPool.ZeroAmount.selector) {
                ++depositsRefusedAsZeroShare;
            } else {
                assertEq(selector, LenderPool.DepositCapExceeded.selector, "unexpected deposit revert");
                ++depositsRefusedByCap;
            }
        }
    }

    function mintShares(uint256 actorSeed, uint256 shares) external watched {
        address a = _actor(actorSeed);
        shares = bound(shares, 1, 5_000e9);
        ActiveTailQuote memory tailQuote = _activeTailMintQuote(shares);
        uint256 cost = pool.previewMint(shares);
        if (cost == 0) return;
        uint256 unitsBefore = pool.totalPrincipalUnits();
        uint256 netBefore = pool.netDeposits();
        _mint(a, cost);

        vm.prank(a);
        try pool.mint(shares, a) returns (uint256 paidAssets) {
            ++mintsDone;
            if (tailQuote.observed) {
                ++activeTailMints;
                if (paidAssets != tailQuote.amount) ++activeTailMintQuoteMismatches;
            }
            _recordPrincipalUnitIssuance(unitsBefore, netBefore, paidAssets);
            // Same subject as `deposit` above, for the same reason - including the live read.
            assertLe(pool.netDeposits(), pool.depositCap(), "mint crossed the cap");
        } catch (bytes memory err) {
            assertEq(bytes4(err), LenderPool.DepositCapExceeded.selector, "unexpected mint revert");
            ++depositsRefusedByCap;
        }
    }

    /// @dev `maxWithdraw` as an executable claim rather than an assertion that restates its own
    ///      `min()`. The contract's NatSpec promises it "reports what can genuinely be taken now",
    ///      and the only honest way to check a promise like that is to take it.
    function withdrawMax(uint256 actorSeed) external watched {
        address a = _actor(actorSeed);
        uint256 assets = pool.maxWithdraw(a);
        if (assets == 0) return;

        bool marked = pool.exitReserve() != 0;
        uint256 exitAssetsBefore = pool.exitAssets();
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(a);
        try pool.withdraw(assets, a, a) returns (uint256 burned) {
            ++withdrawsDone;
            if (marked) {
                ++exitsPricedAgainstAnImpairment;
                if (_paidAboveTheExitPrice(assets, burned, exitAssetsBefore, supplyBefore)) {
                    ++exitsAboveTheImpairedPrice;
                }
            }
        } catch {
            assertTrue(false, "maxWithdraw offered more than withdraw would pay");
        }
    }

    function redeemMax(uint256 actorSeed) external watched {
        address a = _actor(actorSeed);
        uint256 shares = pool.maxRedeem(a);
        if (shares == 0) return;

        bool marked = pool.exitReserve() != 0;
        uint256 exitAssetsBefore = pool.exitAssets();
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(a);
        try pool.redeem(shares, a, a) returns (uint256 paid) {
            ++redeemsDone;
            if (marked) {
                ++exitsPricedAgainstAnImpairment;
                if (_paidAboveTheExitPrice(paid, shares, exitAssetsBefore, supplyBefore)) {
                    ++exitsAboveTheImpairedPrice;
                }
            }
        } catch {
            assertTrue(false, "maxRedeem offered more than redeem would pay");
        }
    }

    /// @notice The queue exit, driven end to end in one transaction: join, self-service, collect.
    /// @dev **This action exists because the invariant over it was vacuous without it, and it is
    ///      kept for the same reason under a mechanism that no longer refuses anybody.** Audit
    ///      round 11 found the round-10 gate had been put on the four ERC-4626 exits and not on
    ///      `serviceQueue`, so a lender could compose these three permissionless calls and pay
    ///      themselves out at the pre-loss price. The counter that was meant to catch it could not:
    ///      it was only incremented by `withdrawMax`/`redeemMax`, both of which bail out at
    ///      `maxWithdraw == 0`, which is exactly what the gate made it.
    ///
    ///      What it measures has changed from "nobody exits" to "nobody exits at an un-impaired
    ///      price", because that is the property that survived. The composite still reaches more
    ///      liquidity than the immediate path does - servicing draws on `_poolBalance()` where
    ///      `maxWithdraw` is bounded by `unreservedIdle()` - and under pricing that buys a lender
    ///      more money out, never a better price per share. That distinction is the whole argument
    ///      for pricing over gating, and it is what this action is now here to falsify.
    function queueExit(uint256 actorSeed, uint256 shares) external watched {
        address a = _actor(actorSeed);
        uint256 held = pool.balanceOf(a);
        if (held == 0) return;
        shares = bound(shares, 1, held);

        bool marked = pool.exitReserve() != 0;
        uint256 exitAssetsBefore = pool.exitAssets();
        uint256 supplyBefore = pool.totalSupply();
        uint256 claimableBefore = pool.totalClaimable();

        vm.prank(a);
        try pool.requestWithdrawal(shares, a) {} catch { return; }

        try pool.serviceQueue(3) {} catch {}

        // Measured on the *set-aside*, not on the payout, and pool-wide rather than per-actor.
        //
        // The set-aside is the moment shares stop existing and exposure ends, which is the moment
        // the price has to be right. `claim` can legitimately pay out a balance an earlier call
        // earmarked at an earlier price, and counting the claim made this fire on exactly that -
        // a false positive in the measurement, not a hole in the pool.
        //
        // Pool-wide because `serviceQueue(3)` can settle somebody else's entry in the same call,
        // and `requestWithdrawal` lets an owner name any receiver: a per-actor delta would then be
        // measuring one lender's payout against another lender's burned shares.
        uint256 paid = pool.totalClaimable() - claimableBefore;
        uint256 burned = supplyBefore - pool.totalSupply();
        if (marked && burned != 0) {
            ++queuedExitsPaidWhileAReserveStood;
            if (_paidAboveTheExitPrice(paid, burned, exitAssetsBefore, supplyBefore)) {
                ++exitsAboveTheImpairedPrice;
            }
        }

        vm.prank(a);
        try pool.claim() {
            ++claimsDone;
        } catch {}
    }

    /// @notice Reserve an expected shortfall against a borrower, which is the state the exit price
    ///         stands back from and the thing that replaced round-10's gate.
    /// @dev Without this the suite could never reach an impaired book at all and would report every
    ///      invariant about the exit price green having exercised none of them - the vacuity
    ///      failure this file's reachability test exists to catch, and the reason the action it
    ///      replaces (`toggleLiquidation`) was written.
    ///
    ///      Zero is inside the bound deliberately: `impair(b, 0)` is the idempotent-set path that
    ///      leaves storage exactly as `releaseImpairment` does but emits nothing, and the manager
    ///      routes round it for that reason. It has to be reachable here so the sum arithmetic is
    ///      exercised on it.
    function impair(uint256 borrowerSeed, uint256 amount) external watched {
        address b = _borrower(borrowerSeed);
        amount = bound(amount, 0, 8_000e6);

        vm.prank(creditManager);
        pool.impair(b, amount);

        // Counted only when it actually reserved something. The reserve clamps to
        // `outstandingPrincipal`, so a mark against an unlent pool moves no price - the same
        // distinction `socialiseLoss` draws below, and for the same reason: it is not evidence the
        // path works.
        if (amount != 0 && pool.exitReserve() != 0) ++impairmentsSet;
    }

    function releaseImpairment(uint256 borrowerSeed) external watched {
        address b = _borrower(borrowerSeed);
        if (pool.impairmentOf(b) == 0) return;

        vm.prank(creditManager);
        pool.releaseImpairment(b);
        ++impairmentsReleased;
    }

    /// @notice The two book-level reserves: a recognised loss the pool has not absorbed yet, and
    ///         the insurance fund standing in front of the live impairments.
    /// @dev The backlog is the one branch of the deleted gate that had to be rebuilt rather than
    ///      argued away - a recognised loss outlives the auction that produced it, so no
    ///      per-borrower mark can carry it, and `flushSocialisedLoss` is permissionless.
    function setLossReserves(uint256 unplaced, uint256 cover) external watched {
        unplaced = bound(unplaced, 0, 5_000e6);
        cover = bound(cover, 0, 5_000e6);

        vm.prank(creditManager);
        pool.setLossReserves(unplaced, cover);

        if (unplaced != 0) ++backlogsSet;
        if (cover != 0) ++coversSet;
    }

    /// @dev The receiver is deliberately allowed to differ from the owner. That path is otherwise
    ///      unexercised, and it is what `invariant_usdcIsConserved` defends: servicing burns
    ///      against the owner and pays the receiver, so a mix-up moves money to the wrong lender
    ///      without changing any total.
    function requestWithdrawal(uint256 actorSeed, uint256 receiverSeed, uint256 shares) external watched {
        address a = _actor(actorSeed);
        uint256 held = pool.balanceOf(a);
        if (held == 0) return;
        shares = bound(shares, 1, held);

        vm.prank(a);
        try pool.requestWithdrawal(shares, _actor(receiverSeed)) {
            ++requestsQueued;
        } catch (bytes memory err) {
            assertEq(bytes4(err), LenderPool.AlreadyQueued.selector, "unexpected requestWithdrawal revert");
            ++requestsRefusedAsDuplicate;
        }
    }

    function claim(uint256 actorSeed) external watched {
        address a = _actor(actorSeed);
        if (pool.claimable(a) == 0) return;
        vm.prank(a);
        pool.claim();
        ++claimsDone;
    }

    function cancelWithdrawal(uint256 actorSeed) external watched {
        address a = _actor(actorSeed);
        vm.prank(a);
        try pool.cancelWithdrawalRequest() {
            ++cancelsDone;
        } catch (bytes memory err) {
            assertEq(bytes4(err), LenderPool.NothingQueued.selector, "unexpected cancel revert");
        }
    }

    /// @dev Actor to actor only, never to the pool. A share transferred straight into the pool
    ///      would be indistinguishable from escrow and would break
    ///      `invariant_escrowedSharesEqualTheContractsOwnBalance` permanently - but that is an
    ///      ERC-20 fact about every escrow-by-transfer design, not a defect in this one, and there
    ///      is nothing the pool could do about it. Excluded on the record rather than silently.
    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external watched {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = pool.balanceOf(from);
        if (held == 0 || from == to) return;
        amount = bound(amount, 1, held);

        vm.prank(from);
        pool.transfer(to, amount);
    }

    // ── the queue ────────────────────────────────────────────────────────────

    /// @dev The outcome is predicted from outside the contract before the call, then counted on
    ///      success. Predicting rather than reading back is what makes `fullFills` and
    ///      `partialFills` independent evidence about which branch ran.
    function serviceQueue(uint256 maxEntries) external watched {
        maxEntries = bound(maxEntries, 1, 5);
        // The pool's own money, not its balance. Two kinds of USDC sit in this contract without
        // being available to pay a queued lender: a set-aside payout belongs to its receiver
        // already, and unreleased yield has not been credited to the share price yet. Paying the
        // queue out of the second would hand over the backing for a rise every remaining
        // shareholder is still owed, and `totalAssets()` would fall through the floor behind it.
        //
        // The unreleased term arrived with finding 6 and this line is why the invariant went red:
        // the *prediction* was stale, not the pool. Sixth time a change has broken a fixture
        // outside its own diff.
        uint256 idleBefore =
            usdc.balanceOf(address(pool)) - pool.totalClaimable() - pool.unreleasedYield();
        uint256 headShares = headLiveShares();
        // The exit price, because that is the one `serviceQueue` values an entry at. This read
        // `convertToAssets` until impairment pricing split the two, which inflated the prediction
        // whenever a reserve stood against the book - and an inflated prediction makes the wedge
        // guard below fire *less* often, which is the direction that hides the bug rather than the
        // direction that flakes.
        uint256 owedAtHead = headShares == 0 ? 0 : pool.previewRedeem(headShares);
        // The same head valued on the released, un-impaired book, which is the predicate the
        // release branch is actually written against. Read here rather than derived from
        // `owedAtHead`, because since impairment pricing the two are different numbers and telling
        // them apart is the whole point: zero at both is dust, zero at only the exit price is a
        // marked-down lender.
        uint256 unimpairedAtHead = headShares == 0 ? 0 : pool.convertToAssets(headShares);

        // The head entry itself, so the eviction check below reads an *outcome* rather than
        // re-deriving the contract's own predicate. Predicting from `unimpairedAtHead` would make
        // the counter structurally incapable of rising: it would only be evaluated in the branch
        // where the release is legitimate, which is the third failure mode this file's own history
        // records. A release hands the shares back to their owner and a payment burns them, so the
        // owner's balance tells the two apart with no prediction at all.
        (address headOwner,, uint256 headEntryShares) = _headEntry();
        uint256 headOwnerSharesBefore = headOwner == address(0) ? 0 : pool.balanceOf(headOwner);

        try pool.serviceQueue(maxEntries) {
            if (headShares == 0) return;

            // Measured, not predicted. If the entry emptied and its owner got shares back, it was
            // released; if it emptied and they did not, it was paid. Audit round 12's eviction is
            // the first of those happening to an entry that was still worth something.
            if (headOwner != address(0) && headEntryShares != 0) {
                (,, uint256 headEntryAfter) = pool.queueEntry(_headIndexBefore);
                bool released = headEntryAfter == 0 && pool.balanceOf(headOwner) > headOwnerSharesBefore;
                if (released && unimpairedAtHead != 0) ++dustReleasedWhileStillWorthSomething;
            }

            if (unimpairedAtHead == 0) {
                ++dustReleases;
            } else if (owedAtHead <= idleBefore) {
                ++fullFills;
            } else {
                ++partialFills;
            }
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == LenderPool.QueueIsEmpty.selector) return;

            // **The third exclusion is now the contract's own answer rather than this file's copy
            // of it**, and that is the point of the new error. It used to be a predicate
            // transcribed here (`reserveBefore != 0`) and re-evaluated from outside, which is the
            // exact shape audit round 15 recorded against the previous exclusion: a local
            // restatement of a contract's decision cannot see the contract change under it. Now the
            // contract says which refusal it is and this counts what it said.
            if (sel == LenderPool.QueueHeldByReserve.selector) {
                // The denominator audit round 15 found covered by nothing anywhere: a refusal under
                // a standing reserve with money in the pool. Counted rather than merely excluded,
                // so the tripwire can prove the exclusion admits something real rather than
                // quietly swallowing everything.
                if (headShares != 0 && idleBefore != 0 && unimpairedAtHead != 0) {
                    ++refusalsUnderAStandingReserveWithCashPresent;
                }
                return;
            }

            assertEq(sel, LenderPool.NothingToService.selector, "unexpected serviceQueue revert");

            // Refusing when the head could have been paid in full - or released, if it is dust -
            // is the exact shape of the wedge. Three cases are excluded because refusing is the
            // honest answer in all of them: a pool holding no USDC at all has nothing to pay with,
            // a partial fill whose idle cannot buy even one share-wei makes no progress by
            // arithmetic, and a head worth nothing at today's exit price *because a reserve stands
            // against the book* can be neither paid nor released. The zero-idle exclusion is not
            // cosmetic - the fuzzer reached exactly it, by draining idle with a `withdrawMax`
            // while a one-share entry sat at the head, and without it `0 >= 0` would have read an
            // honest refusal as a wedge.
            //
            // **The third exclusion is keyed on the cause, and audit round 15 is why it had to
            // move.** It used to read `owedAtHead == 0 && exitReserve() != 0` - the symptom and the
            // cause together - and that was written when the contract refused inside a truncation
            // branch. The contract now refuses on the standing reserve itself, because the
            // truncation was one wei wide and an attacker chose which side of it a victim fell on.
            // An exclusion still naming the truncation would let every refusal at `owedAtHead != 0`
            // count as a wedge, and the invariant would go red on correct behaviour.
            //
            // Each clause is named because each is a different reason refusing is honest, and the
            // three must stay separable: no cash to pay with, an entry that is worthless on the
            // un-impaired book (which the contract *releases* rather than refuses on, so it should
            // never reach here at all), and a reserve standing against the book.
            //
            // **What this knowingly stops detecting is a queue frozen by a reserve nobody
            // releases**, which is a real harm and a recorded open finding. A fuzz run has no
            // notion of "eventually", so it cannot be asserted here. It is asserted directly
            // instead, by the two unit tests that service the same entry once the mark comes off -
            // one at zero idle and one with cash present, because the zero-idle case is the only
            // one the previous compensating test could reach.
            // Only the two remaining reasons can reach here, because the reserve refusal returned
            // above under its own selector.
            bool honestRefusal = idleBefore == 0 || unimpairedAtHead == 0;
            if (headShares != 0 && idleBefore != 0 && idleBefore >= owedAtHead && !honestRefusal) {
                ++serviceRefusedWithFundsAndQueue;
            }
        }
    }

    // ── protocol-facing ──────────────────────────────────────────────────────

    function lend(uint256 amount) external watched {
        uint256 lendable = pool.available();
        amount = bound(amount, 1, lendable + 1_000e6);
        uint256 queuedBefore = pool.queuedShares();

        vm.prank(creditManager);
        try pool.lend(amount) {
            ++lendsDone;
            if (queuedBefore != 0) ++lendsWhileQueued;
            // Only a constraint on lending, never a standing invariant: an ordinary withdrawal is
            // bounded by unreserved idle, not by the float, so it may legitimately take idle below
            // the reserve. Asserting it globally would fail on correct behaviour.
            assertGe(
                usdc.balanceOf(address(pool)) - pool.totalClaimable(),
                (pool.totalAssets() * Config.RESERVE_RATIO_BPS) / Config.BPS,
                "lending ate the hot float"
            );
        } catch (bytes memory err) {
            assertEq(bytes4(err), LenderPool.InsufficientLiquidity.selector, "unexpected lend revert");
        }
    }

    function repayPrincipal(uint256 amount) external watched {
        uint256 outstanding = pool.outstandingPrincipal();
        amount = bound(amount, 1, outstanding + 2_000e6);
        _mint(creditManager, amount);

        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.repayPrincipal(amount);
        vm.stopPrank();

        ++repaysDone;
        if (amount > outstanding) ++overRepaysDone;
    }

    /// @notice Money coming back on a loss already socialised here. Audit round 21, finding 14.
    /// @dev Unbounded by `lifetimeSocialisedLoss` on purpose: this pool does not police what the
    ///      manager sends, and the bound lives on `LiquidationAuction.workoutSettleAfterClose`,
    ///      where the write-off it repays is recorded. A handler that enforced the bound here would
    ///      be testing a guard that does not exist.
    function recoverLoss(uint256 amount) external watched {
        amount = bound(amount, 1, 2_000e6);
        _mint(creditManager, amount);
        // Derived, never written down: `MIN_SUPPLY_FOR_YIELD` is `10**3 * Config.BPS` and is
        // private, so it is rebuilt from the same two terms rather than pinned at 10,000.
        bool belowTheFloor = pool.totalSupply() < (10 ** 3) * Config.BPS;

        vm.startPrank(creditManager);
        usdc.approve(address(pool), amount);
        pool.recoverLoss(amount);
        vm.stopPrank();

        ++lossRecoveriesDone;
        if (belowTheFloor) ++lossRecoveriesFrozenBelowTheShareFloor;
    }

    /// @dev Wrapped since the clock arrived. Both refusals are anti-JIT rules that were unreachable
    ///      for as long as nothing advanced time, so they get named counters rather than a bare
    ///      `catch` - an anti-JIT rule with no denominator is the same silence audit round 15 found
    ///      in this file, one function along.
    function distributeYield(uint256 amount) external watched {
        amount = bound(amount, 1, 1_000e6);
        _mint(epochHarvester, amount);

        vm.startPrank(epochHarvester);
        usdc.approve(address(pool), amount);
        try pool.distributeYield(amount) {
            ++yieldDistributions;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == LenderPool.YieldExceedsCapital.selector) {
                ++yieldRefusedAsTooLargeForTheCapital;
            } else if (sel == LenderPool.NoSharesOutstanding.selector) {
                ++yieldRefusedWithNoSharesOutstanding;
            } else {
                assertTrue(false, "unexpected distributeYield revert");
            }
        }
        vm.stopPrank();
    }

    /// @notice USDC transferred straight in, belonging to nobody.
    /// @dev Anyone can do this to any ERC-4626 vault and there is no guard that could stop it, so
    ///      it is a state the suite has to be able to reach rather than a threat model. Audit round
    ///      11's `maxDeposit` finding was exactly this shape - a cap sized from a raw `balanceOf`
    ///      that a donation to the empty pool pinned at zero forever - and the only suite that
    ///      could have exercised it had no way to donate. It is also the slack that makes
    ///      `invariant_poolNeverOwesMoreThanItHolds` an inequality rather than an equality, so
    ///      without this action that inequality would never be tested away from its boundary.
    function donate(uint256 amount) external watched {
        amount = bound(amount, 1, 1_000e6);
        _mint(address(this), amount);
        usdc.transfer(address(pool), amount);
        ++donationsDone;
    }

    // ── the clock ────────────────────────────────────────────────────────────

    /// @notice Move time forward, which is what makes the yield stream reachable at all.
    /// @dev Bounded per call rather than free. `_rateStream` rates an epoch over
    ///      `max(YIELD_STREAM_DURATION, time since the last delivery)`, so an unbounded jump before
    ///      the first `distributeYield` would rate that epoch over a window long enough to leave
    ///      `unreleasedYield()` permanently large, `_poolBalance()` permanently small and the queue
    ///      permanently unfunded - hiding the fill states this suite exists for behind a fixture
    ///      artefact. Two full stream durations is enough to see a stream open, decay and close.
    function passTime(uint256 seed) external watched {
        uint256 unreleasedBefore = pool.unreleasedYield();
        uint256 releasedBookBefore = pool.convertToAssets(PRICE_PROBE_SHARES);

        skip(bound(seed, 1 hours, Config.YIELD_STREAM_DURATION * 2));
        ++timeAdvances;

        if (unreleasedBefore != 0 && pool.unreleasedYield() < unreleasedBefore) ++streamReleases;
        if (pool.convertToAssets(PRICE_PROBE_SHARES) > releasedBookBefore) {
            ++releasedBookPriceRisesOnTheClock;
        }
    }

    function socialiseLoss(uint256 amount) external watched {
        uint256 outstanding = pool.outstandingPrincipal();
        amount = bound(amount, 1, outstanding + 2_000e6);

        vm.prank(creditManager);
        pool.socialiseLoss(amount);

        // A loss against nothing lent absorbs nothing and moves no price, so it is not evidence
        // the loss path works - the same distinction VaultHandler draws for a harvest of nothing.
        if (outstanding != 0) ++lossesSocialised;
        if (amount > outstanding) ++lossesClamped;
    }

    // ── views the invariants read (forge does not fuzz these) ────────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function sumClaimable() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.claimable(actors[i]);
        }
    }

    /// @dev Includes the pool's own balance, which is where escrowed shares live.
    function sumShareBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.balanceOf(actors[i]);
        }
        sum += pool.balanceOf(address(pool));
    }

    /// @dev Includes the pool because queued shares carry their principal units into escrow.
    function sumPrincipalUnits() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.principalUnits(actors[i]);
        }
        sum += pool.principalUnits(address(pool));
    }

    /// @dev Sums each holder's marked-down asset basis. Individual conversions round up, so the
    ///      result may exceed `netDeposits` by less than one asset unit per non-empty holder.
    function sumPrincipalBasis() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.principalBasis(actors[i]);
        }
        sum += pool.principalBasis(address(pool));
    }

    /// @dev Walks the array rather than restating `queuedShares`. A checker that read the counter
    ///      would agree with it by construction and prove nothing about the entries behind it.
    function sumLiveQueueShares() external view returns (uint256 sum) {
        uint256 length = pool.queueLength();
        for (uint256 i = 0; i < length; i++) {
            (,, uint256 shares) = pool.queueEntry(i);
            sum += shares;
        }
    }

    /// @dev Each live request owns an exact slice of the pool's escrowed principal units. The
    ///      handler never transfers shares straight to the pool, so every escrowed unit must have
    ///      exactly one queue entry behind it.
    function sumLiveQueuePrincipalUnits() external view returns (uint256 sum) {
        uint256 length = pool.queueLength();
        for (uint256 i = 0; i < length; i++) {
            sum += pool.queueEntryPrincipalUnits(i);
        }
    }

    function hasPrincipalUnitsOnEmptyQueueEntry() external view returns (bool) {
        uint256 length = pool.queueLength();
        for (uint256 i = 0; i < length; i++) {
            (,, uint256 shares) = pool.queueEntry(i);
            if (shares == 0 && pool.queueEntryPrincipalUnits(i) != 0) return true;
        }
        return false;
    }

    /// @dev A live entry behind the head has been stepped over and will never be paid. The head
    ///      moves in three places, which is three chances to skip somebody.
    function hasLiveEntryBeforeHead() external view returns (bool) {
        uint256 head = pool.queueHead();
        for (uint256 i = 0; i < head; i++) {
            (,, uint256 shares) = pool.queueEntry(i);
            if (shares != 0) return true;
        }
        return false;
    }

    function liveEntryCountFor(address lender) external view returns (uint256 count) {
        uint256 length = pool.queueLength();
        for (uint256 i = 0; i < length; i++) {
            (address owner,, uint256 shares) = pool.queueEntry(i);
            if (owner == lender && shares != 0) ++count;
        }
    }

    /// @dev The index the next live entry sits at, and the entry itself. Split out because the
    ///      servicing observation needs both the index (to re-read the same slot afterwards) and
    ///      the owner (to tell a release from a payment by where the shares went).
    uint256 internal _headIndexBefore;

    function _headEntry() internal returns (address owner, address receiver, uint256 shares) {
        uint256 length = pool.queueLength();
        for (uint256 i = pool.queueHead(); i < length; i++) {
            (address o, address r, uint256 s) = pool.queueEntry(i);
            if (s != 0) {
                _headIndexBefore = i;
                return (o, r, s);
            }
        }
        _headIndexBefore = 0;
        return (address(0), address(0), 0);
    }

    function headLiveShares() public view returns (uint256) {
        uint256 length = pool.queueLength();
        for (uint256 i = pool.queueHead(); i < length; i++) {
            (,, uint256 shares) = pool.queueEntry(i);
            if (shares != 0) return shares;
        }
        return 0;
    }
}

contract LenderPoolInvariants is Test {
    LenderHandler internal handler;
    LenderPool internal pool;
    MockUSDC internal usdc;

    /// @dev A plain EOA. It was a `MockCreditManager` pointing at a `MockLiquidationAuction` for as
    ///      long as the round-10 exit gate lived here, because that gate made typed calls through
    ///      the manager into its auction from inside `maxWithdraw` and a typed call to an address
    ///      with no code reverts. The gate is gone, the impairment is pushed in and read from local
    ///      storage, and the pool now calls nothing but USDC - so an address with no code is a
    ///      complete credit manager, and every action in the handler depends on that being true.
    address internal creditManager = makeAddr("creditManager");
    address internal epochHarvester = makeAddr("epochHarvester");

    /// @dev The probe the handler's clock ghosts use, read from there rather than restated, so the
    ///      two can never come to mean different sizes. See `LenderHandler.PRICE_PROBE_SHARES`.
    uint256 internal PRICE_PROBE;

    /// @dev **Nine `last…` fields used to live here and every one of them was dead weight.** They
    ///      were the remembered halves of six "compare with what I saw last time" invariants, and
    ///      forge evaluates each `invariant_` call against a snapshot and rolls back everything it
    ///      writes - measured in this very file over 128,000 calls, see `LenderHandler.watched`. So
    ///      each field held the value `setUp` left it, forever. The observation now happens in the
    ///      handler, where state survives, and these invariants read the counters it keeps.
    ///      **Do not reintroduce a `last…` field here.**

    /// @dev A borrower this file marks down and rolls back, never one the handler touches. Sharing
    ///      the handler's set would let a probe leak into `impairmentsSet` and turn a coverage ghost
    ///      into a count of this test's own scaffolding.
    address internal markdownProbe = makeAddr("markdownProbe");
    /// @dev The denominator for `invariant_worseNewsNeverBuysMoreLending`, asserted by the tripwire.
    uint256 internal markdownProbesThatBit;

    function setUp() public {
        address admin = makeAddr("admin");
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(epochHarvester);
        vm.stopPrank();

        handler = new LenderHandler(pool, usdc, creditManager, epochHarvester);
        targetContract(address(handler));

        PRICE_PROBE = handler.PRICE_PROBE_SHARES();
    }

    /// Escrow and its counter are two representations of one fact, mutated by four different
    /// paths: request, cancel, a partial fill and a full one.
    /// @notice No handler call may revert. Every action in this handler wraps its interesting call
    ///         in `try`, or guards it, so a handler *frame* that dies is a fixture fault rather
    ///         than a meaningless random sequence.
    /// @dev **Added to all five suites at once, because the bug that prompted it was found in one
    ///      and existed in three.** `LiquidationAuction.invariants.t.sol` opened auctions at a
    ///      healthy rate and rolled every one of them back, for three audit rounds, because a
    ///      statement after the `try` reverted and `fail_on_revert = false` discards a reverting
    ///      frame. Nothing inside a handler can detect that - the ghost that would record it dies
    ///      with the frame. Only the runner, counting frames from outside, can.
    ///
    ///      Deterministic: a property of the handler's code rather than of the random walk, so it
    ///      cannot flake the way a per-run reachability floor does.
    ///
    ///      Empty body on purpose. The assertion is the config line, enforced by the runner. The
    ///      global `fail_on_revert = false` in `foundry.toml` stays correct for every other
    ///      invariant here and is what lets the `try`/`catch` idiom work at all.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    function invariant_escrowedSharesEqualTheContractsOwnBalance() public view {
        assertEq(pool.queuedShares(), pool.balanceOf(address(pool)), "escrow and counter disagree");
    }

    /// And the counter agrees with the entries it summarises.
    function invariant_queuedSharesEqualTheSumOfLiveEntries() public view {
        assertEq(pool.queuedShares(), handler.sumLiveQueueShares(), "counter drifted from the queue");
    }

    /// No share exists outside the fixture: nothing mints or burns off the four accounted paths.
    function invariant_shareSupplyIsFullyAccountedFor() public view {
        assertEq(pool.totalSupply(), handler.sumShareBalances(), "shares exist outside the fixture");
        // Kept for its message, and recorded as subsumed rather than left looking like a second
        // check. `sumShareBalances` counts the pool's own balance, and
        // `invariant_escrowedSharesEqualTheContractsOwnBalance` pins `queuedShares` to exactly
        // that, so this cannot fail while the line above holds. Audit round 15's sweep instruction
        // is to look for the shape rather than the line, and an assertion that cannot fail while
        // its neighbour holds is that shape: it reads as coverage that is not there.
        assertLe(pool.queuedShares(), pool.totalSupply(), "more escrowed than issued");
    }

    /// A head that moved backwards would pay an entry twice.
    ///
    /// @dev The backwards half is a handler ghost. It used to be `assertGe(head, lastHead)` with
    ///      `lastHead` written here, which forge discards - so it was `assertGe(head, 0)` on all
    ///      128,000 calls and could not have gone red for any value of `queueHead` at all. The
    ///      array-bound half below never depended on remembered state and is unchanged.
    function invariant_queueHeadOnlyMovesForward() public view {
        assertEq(handler.headWentBackwards(), 0, "queueHead moved backwards");
        assertLe(pool.queueHead(), pool.queueLength(), "queueHead ran past the array");
    }

    /// The structural form of "the queue cannot be jumped": nobody live is left behind the head.
    function invariant_nothingLiveSitsBeforeTheHead() public view {
        assertFalse(handler.hasLiveEntryBeforeHead(), "a live request was left behind the head");
    }

    /// One request per lender, and the index mapping agrees with the array in both directions. A
    /// stale mapping locks a paid lender out forever; a cleared one lets them queue twice.
    function invariant_atMostOneLiveRequestPerLender() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            uint256 live = handler.liveEntryCountFor(a);
            assertLe(live, 1, "a lender holds two live requests");
            (, uint256 remaining) = pool.queuePosition(a);
            if (live == 0) assertEq(remaining, 0, "queuePosition reports a request that is not there");
        }
    }

    /// The queue has first call on every dollar it is owed - which is an amount, not a flag.
    ///
    /// This used to assert `available() == 0` whenever anyone was queued, which encoded the very
    /// defect round 10 found: a request worth zero asset-wei zeroed the whole lending book. An
    /// invariant written from the implementation agrees with the implementation, including when
    /// the implementation is wrong. The property that survives is the one about money: whatever is
    /// lendable, plus what the queue is owed, plus the hot float, must fit inside the pool's own
    /// balance - so lending can never dip into a queued lender's claim.
    /// Note what is deliberately *not* asserted any more: that no lend happens while anyone is
    /// queued. Under the fix that is legitimate - a lender owed ten dollars does not freeze a
    /// twenty-thousand dollar book - so the old ghost would now fail on correct behaviour.
    ///
    /// **Audit round 15: this measured with a smaller ruler than the contract uses.** Valuing the
    /// queue at `previewRedeem` while `available()` holds its claim back at the un-impaired figure
    /// carries the whole markdown as slack. Executed, it passed against the round-12 defect and
    /// against the round-13 fix alike, across 3,250e6 of lending capacity: it could not tell them
    /// apart. Priced on the same book `available()` uses, the slack goes to zero.
    ///
    /// The paragraph this replaces argued for the exit price, and it was answering a different
    /// question. What a queued lender is *paid* is the exit price. What may be *lent past* them is
    /// bounded by what their claim will be worth once the mark comes off, because a mark is
    /// released when its liquidation resolves and the claim rises again at that moment - so
    /// reserving only today's marked-down figure lends out the difference in between. Audit round
    /// 13 settled that those are two numbers and applied the un-impaired one to `available()` and
    /// `unreservedIdle()`; this invariant was left measuring the other.
    ///
    /// @notice The impaired-borrower set is exactly the borrowers with a non-zero mark, and
    ///         `totalImpairment` is exactly what that set sums to.
    /// @dev **`totalImpairment` had never been auditable, and that is worth as much here as the
    ///      bug the set was added for.** It is a running `total + amount - previous` written by two
    ///      functions, and the map it claims to sum had no key list - so no invariant in this repo
    ///      could compare it against anything. Every price this pool quotes on the way out stands
    ///      back from that one slot.
    ///
    ///      The membership half is what keeps the swap-pop honest: a removal moves the tail into
    ///      the vacated slot, and getting that wrong leaves either a duplicate or a hole, neither
    ///      of which any other assertion here would see.
    function invariant_theImpairedSetIsExactlyTheNonZeroMarks() public view {
        uint256 count = pool.impairedBorrowerCount();
        uint256 summed;

        for (uint256 i; i < count; ++i) {
            address b = pool.impairedBorrowerAt(i);
            assertGt(pool.impairmentOf(b), 0, "the set holds a borrower carrying no mark");
            summed += pool.impairmentOf(b);
            // No duplicates: a second slot holding the same borrower would be a swap-pop that
            // wrote the index of a moved entry to the wrong key.
            for (uint256 j = i + 1; j < count; ++j) {
                assertTrue(pool.impairedBorrowerAt(j) != b, "the set holds the same borrower twice");
            }
        }

        assertEq(summed, pool.totalImpairment(), "the running total disagrees with the set it sums");

        // And the other direction, which is the one that catches a marked borrower left out: every
        // borrower the handler can mark is either in the set or carries nothing.
        uint256 marked;
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            if (pool.impairmentOf(handler.borrowers(i)) != 0) marked++;
        }
        assertEq(marked, count, "a borrower carries a mark and is not in the set");
    }

    /// Sameness of ruler is necessary and not sufficient, which is why the sibling below exists.
    function invariant_theQueueHasFirstCallOnLiquidity() public view {
        uint256 owedToQueue = pool.convertToAssets(pool.queuedShares());
        // Unreleased yield joins `totalClaimable` as money sitting here that is not the pool's to
        // hand out - see the note on `serviceQueue` in the handler.
        uint256 poolBalance =
            usdc.balanceOf(address(pool)) - pool.totalClaimable() - pool.unreleasedYield();

        if (owedToQueue <= poolBalance) {
            // There is enough cash to cover the queue, so lending must leave that cover intact.
            assertLe(pool.available() + owedToQueue, poolBalance, "lending would eat the queue's claim");
        } else {
            // The queue is owed more than the pool holds - the state the queue exists for. Nothing
            // may be lent at all until principal comes home.
            assertEq(pool.available(), 0, "lendable while the queue is already short");
        }
    }

    /// @notice Worse news never buys more lending.
    /// @dev **The discriminator the invariant above could not be.** The property that separates the
    ///      round-12 defect from the round-13 fix is not how the queue's claim is measured, it is
    ///      that `available()` must not depend on `exitReserve()` at all. Under the fix it reads
    ///      `_poolBalance()`, an un-impaired conversion and `totalAssets()`, none of which carry the
    ///      reserve; under the defect it rose with a mark, which handed an unqueued lender the
    ///      difference. A comparison of two standing quantities cannot see that. A probe can.
    ///
    ///      Executable rather than argued: mark a borrower down, read `available()` again, and roll
    ///      the state back. The probe borrower is disjoint from the handler's own set, or the
    ///      rollback would still leave `impairmentsSet` counting a mark this file invented.
    ///
    ///      `assertLe`, not `assertEq`. A future design that deliberately holds back *more* while a
    ///      mark stands is not a defect and must not be forced red by a test written against
    ///      today's arithmetic - which is the mistake the invariant above made once already.
    ///
    ///      `markdownProbesThatBit` is the denominator and the tripwire asserts it non-zero. Without
    ///      it this is a zero over a zero on every run where nothing was ever lent, since the
    ///      reserve clamps to `outstandingPrincipal` and an unlent pool cannot be marked down.
    ///
    ///      The probe amount was `Config.GLOBAL_BORROW_CAP` while that was a constant. The live cap
    ///      is storage on `RiskParams` now and this pool holds no pointer to it, so the probe names
    ///      `Config.GLOBAL_BORROW_CAP_MAX` instead - the ceiling the ratchet may never pass, which
    ///      is therefore the largest debt any borrower can ever carry and the figure `impair` itself
    ///      clamps on. It is the *worst* news that can exist rather than the worst news available
    ///      today, which is what a probe named "worse news" should be asking about, and the reserve
    ///      clamps to `outstandingPrincipal` regardless so nothing about the measurement changes.
    ///      **Deliberately left where it is when the other five moved into the handler.** It is not
    ///      the "remember last time" shape: both readings are taken inside one call, either side of
    ///      a probe this function makes itself and rolls back, so the discard that emptied the other
    ///      five cannot reach it. What the discard *does* eat is `markdownProbesThatBit` - during a
    ///      campaign that counter is rolled back with everything else and reads zero, which is why
    ///      the tripwire calls this function directly and reads it back rather than asserting on it
    ///      from the fuzzer's state. Verified by mutation on 2026-08-17: an `available()` that rose
    ///      with the reserve turned this red in a single fuzz call.
    function invariant_worseNewsNeverBuysMoreLending() public {
        uint256 lendableBefore = pool.available();
        uint256 reserveBefore = pool.exitReserve();

        uint256 snap = vm.snapshotState();
        vm.prank(creditManager);
        pool.impair(markdownProbe, Config.GLOBAL_BORROW_CAP_MAX);
        uint256 reserveAfter = pool.exitReserve();
        uint256 lendableAfter = pool.available();
        vm.revertToState(snap);

        if (reserveAfter > reserveBefore) {
            ++markdownProbesThatBit;
            assertLe(lendableAfter, lendableBefore, "a markdown bought lending capacity");
        }
    }

    /// Money set aside for a serviced lender is no longer the pool's. The pool must always hold at
    /// least what it has promised, and the counter must agree with the individual balances behind
    /// it - two writers, one fact.
    function invariant_setAsideMoneyIsAlwaysCovered() public view {
        assertEq(pool.totalClaimable(), handler.sumClaimable(), "the claimable counter drifted");
        assertLe(pool.totalClaimable(), usdc.balanceOf(address(pool)), "owes more than it holds");
    }

    /// Monotonic *with a cause*, which is what a unit test cannot express.
    ///
    /// @dev Both halves are handler ghosts now. Written here they compared against `lastLifetimeLoss
    ///      = 0` and `lastLossCount = 0` forever, which made the first half `assertGe(lossNow, 0)`
    ///      and the second reachable only while nothing had been socialised yet: after the first
    ///      loss landed the guard stopped being satisfiable and the assertion behind it was never
    ///      evaluated again.
    function invariant_lifetimeSocialisedLossOnlyRisesOnALoss() public view {
        assertEq(handler.lifetimeLossFell(), 0, "the disclosure counter went down");
        assertEq(
            handler.lifetimeLossRoseWithNoSocialisedLoss(), 0, "a loss was recorded with no socialiseLoss behind it"
        );
    }

    /// Principal appearing without a lend behind it is money invented into `totalAssets`.
    ///
    /// @dev Same shape, same repair. Written here this said "while `lendsDone` is still zero,
    ///      principal must be at most zero" - true, and true of nothing after the first lend.
    function invariant_outstandingPrincipalOnlyRisesOnALend() public view {
        assertEq(handler.principalRoseWithNoLend(), 0, "principal rose with no lend behind it");
    }

    /// The deposit-cap counter measures what lenders put in. It may only ever rise when a lender
    /// puts something in, or the cap it gates is measuring something else.
    ///
    /// @dev **Audit round 22, finding 15. This layer had no property on `netDeposits` whatsoever**,
    ///      which is how it passed 24 of 24 at full config with round 21's flagship fix reverted at
    ///      both doors. Same "monotonic with a cause" shape as the two above, and the same reason
    ///      it is a handler ghost rather than a remembered field here - forge evaluates every
    ///      `invariant_` against a snapshot and rolls its writes back, so a `last…` field on this
    ///      contract would hold what `setUp` left it on all 128,000 calls.
    ///
    ///      The principal-unit conservation property below owns the accounting rule itself. This
    ///      one remains the independent writer check: a basis is established on entry and nowhere
    ///      else, regardless of how losses mark existing units down.
    ///
    ///      **`netDeposits <= totalAssets()` is still deliberately not shipped, for a current rather
    ///      than historical reason.** The no-loss dust-transfer regression keeps that inequality
    ///      green while it pays zero assets and lowers `netDeposits` by one. It therefore cannot
    ///      distinguish correct principal release from cap-loosening drift. The old RED measurement
    ///      belonged to `_principalPortion`'s deleted floor rule; retaining it here as though it
    ///      constrained the replacement would give an obsolete implementation authority over this
    ///      one. The deterministic residual tests own the two rounding directions instead.
    function invariant_netDepositsOnlyRisesOnADepositOrMint() public view {
        assertEq(
            handler.netDepositsRoseWithNoDepositOrMint(), 0, "the deposit-cap counter rose with no entry behind it"
        );
    }

    /// @notice Every successful entry issues units from the independent pre-entry ratio.
    function invariant_principalUnitIssuanceMatchesThePreEntryRatio() public view {
        assertEq(handler.principalUnitIssuanceMismatches(), 0, "a deposit or mint issued the wrong principal units");
    }

    /// @notice Transfers conserve aggregate units and exits retire the units carried by their shares.
    /// @dev Audit round 22 findings 3, 15 and 22. The actor list is exhaustive for this handler and
    ///      the pool is the fifth possible holder while shares are queued. Summing units proves the
    ///      storage conservation directly. Summing the marked-down bases proves they reconstruct
    ///      `netDeposits`, allowing only the strict ceiling-rounding bound.
    ///
    ///      No no-loss equality is asserted here. `units == netDeposits` and `basis == netDeposits`
    ///      can both remain green while a dust transfer followed by a zero-asset redemption burns
    ///      one unit and one asset-wei of `netDeposits` together, increasing cap headroom although
    ///      no asset left. The deterministic ten-cycle regression owns that economic boundary; this
    ///      invariant keeps the unconditional storage-conservation bounds it can actually prove.
    function invariant_principalUnitsConserveNetDeposits() public view {
        uint256 units = handler.sumPrincipalUnits();
        uint256 basis = handler.sumPrincipalBasis();
        uint256 net = pool.netDeposits();

        assertEq(units, pool.totalPrincipalUnits(), "principal units escaped the known holders");
        assertEq(
            handler.sumLiveQueuePrincipalUnits(),
            pool.principalUnits(address(pool)),
            "queue requests lost their escrowed principal provenance"
        );
        assertFalse(handler.hasPrincipalUnitsOnEmptyQueueEntry(), "an empty queue entry retained principal units");
        assertEq(units == 0, net == 0, "principal units and admitted principal disagree on emptiness");
        assertLe(net, units, "admitted principal rose above its accounting units");
        assertGe(basis, net, "holder bases do not reconstruct admitted principal");
        assertLe(basis - net, handler.actorCount(), "holder-basis rounding exceeded one unit per boundary");
    }

    /// @notice A holder with no vault shares cannot retain principal-accounting units.
    function invariant_noPrincipalUnitsOutliveShares() public view {
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actors(i);
            if (pool.balanceOf(actor) == 0) {
                assertEq(pool.principalUnits(actor), 0, "an exited actor retained principal units");
            }
        }

        if (pool.balanceOf(address(pool)) == 0) {
            assertEq(pool.principalUnits(address(pool)), 0, "empty queue escrow retained principal units");
        }
    }

    /// The released, un-impaired book price falls for exactly one reason: a realised loss.
    ///
    /// This probes `convertToAssets`, not an executable entry quote. Exact deposit and mint previews
    /// include a live stream's projected unreleased tail, while this conversion continues to show
    /// only what has reached the book. Impairment must not move it either: the marked exit price is
    /// the separate sibling below.
    ///
    /// @dev **This is the one the discard cost most.** Written here it compared today's price with
    ///      `lastPrice`, which forge pinned at the `setUp` value of 1,000,000,000 - while the price
    ///      the campaign actually reaches was measured at 2,001,000,000,000. The guard therefore
    ///      carried a factor of two thousand of slack: the released book price could have fallen by
    ///      99.95% in a single action and this invariant would still have been green.
    function invariant_theReleasedBookPriceOnlyFallsOnARealisedLoss() public view {
        assertEq(
            handler.releasedBookPriceFellWithNoRealisedLoss(),
            0,
            "the released book price fell with no socialised loss behind it"
        );
    }

    /// @notice Exact entries price the projected active tail rather than acquiring it for free.
    /// @dev The handler derives both quotes independently from public accounting state and
    ///      OpenZeppelin's virtual terms. Deposit and mint have separate numerators because a
    ///      shared zero could otherwise hide one unexercised door; the deterministic reach test
    ///      below requires both denominators to move.
    function invariant_activeTailEntryQuotesUseTheGrossShareholderBook() public view {
        assertEq(handler.activeTailDepositQuoteMismatches(), 0, "an active-tail deposit used the wrong quote");
        assertEq(handler.activeTailMintQuoteMismatches(), 0, "an active-tail mint used the wrong quote");
    }

    /// And the other half, which is the one impairment pricing added: the **exit** price falls only
    /// on a reserve going up or on a loss actually landing. Anything else moving it down would be a
    /// lender losing money to arithmetic rather than to a borrower.
    ///
    /// The reserve is read here rather than counted, deliberately. A ghost counting `impair` calls
    /// would miss the two other writers - `setLossReserves`, and the exposure clamp, which moves
    /// `exitReserve()` whenever `outstandingPrincipal` does without anybody calling anything - and
    /// enumerating writers from the interface instead of from the storage they touch is precisely
    /// what round 11 punished.
    /// The reserve stays read rather than counted inside the handler's `_settle`, for exactly the
    /// reason this comment gave when the comparison was made here.
    ///
    /// @dev And this one was worse than merely slack. Written here, its guard was
    ///      `reserve <= lastExitReserve` with `lastExitReserve` pinned at zero, so the assertion
    ///      behind it was only ever evaluated while `exitReserve()` was itself zero - which is to
    ///      say only while the mechanism it was written for was switched off.
    function invariant_theExitPriceOnlyFallsOnAReserveOrARealisedLoss() public view {
        assertEq(
            handler.exitPriceFellWithNeitherAReserveNorALoss(),
            0,
            "the exit price fell with neither a reserve nor a loss behind it"
        );
    }

    /// Round-10 finding 7, carried across the mechanism that replaced its gate. Nobody leaves at a
    /// price that has stopped being true - through the front door or through the queue - because
    /// what is paid out is always the burned shares valued against the book *after* the reserve.
    ///
    /// The numerator only. Its denominators are asserted non-zero by the reachability test below,
    /// and they have to be: the counter this replaces was pinned at zero by the gate it was written
    /// to test, and a zero over a zero is the same vacuity wearing different clothes.
    function invariant_nobodyExitsAboveTheImpairedPrice() public view {
        assertEq(
            handler.exitsAboveTheImpairedPrice(), 0, "an exit paid out more than the impaired price allowed"
        );
    }

    /// Round-10 finding 6, as a claim about money rather than about the stream's arithmetic:
    /// whatever the pool is holding for somebody else - a serviced payout, and an epoch it has not
    /// released yet - has to actually be there. If these two ever fought over the same dollar, one
    /// of them would be paid out of the other's backing.
    function invariant_theStreamAndTheQueueBothFitInsideTheBalance() public view {
        assertLe(
            pool.totalClaimable() + pool.unreleasedYield(),
            usdc.balanceOf(address(pool)),
            "set-aside plus unreleased yield exceeds what the pool holds"
        );
    }

    /// Aggregate no-over-issuance: everyone redeeming at once cannot ask for more than the pool
    /// actually has, counting the cash it holds and the principal it is owed back.
    ///
    /// **This used to compare `convertToAssets(totalSupply())` against `totalAssets()`, and audit
    /// round 15 showed that is an algebraic identity.** `convertToAssets(S)` is
    /// `floor(S * (T + 1) / (S + 1000))`, and because `S < S + 1000` the quotient is strictly below
    /// `T + 1` for every `S` and every `T`. It therefore held against any implementation in any
    /// state, including a `totalAssets()` that was pure fiction, because it was the same
    /// `totalAssets()` on both sides. It never read `usdc.balanceOf(address(pool))`, which is the
    /// only quantity its name was ever about.
    ///
    /// Both sides now name the balance. What this catches that the old one could not: a
    /// `totalAssets()` that over-reports the cash component by any amount at all. What it still
    /// cannot catch is `outstandingPrincipal` drifting from what was really lent, because that
    /// counter is the pool's own word and nothing here can check it independently -
    /// `invariant_outstandingPrincipalOnlyRisesOnALend` is the guard for that half.
    ///
    /// An inequality rather than an equality because a donation legitimately creates slack: anyone
    /// may transfer USDC straight in, and the `donate` action exists so that slack is real in this
    /// suite rather than hypothetical.
    function invariant_poolNeverOwesMoreThanItHolds() public view {
        uint256 cash = usdc.balanceOf(address(pool));
        uint256 notOurs = pool.totalClaimable() + pool.unreleasedYield();
        assertLe(notOurs, cash, "the pool owes more set-aside and unreleased yield than it holds");

        uint256 backing = cash - notOurs + pool.outstandingPrincipal();
        assertLe(pool.totalAssets(), backing, "totalAssets counts money the pool neither holds nor is owed");
        assertLe(
            pool.convertToAssets(pool.totalSupply()),
            backing,
            "the whole supply values above the cash and principal behind it"
        );
    }

    /// The handler is the only minter, so every unit it made must still be somewhere. This is what
    /// catches a payout sent to the wrong party, which matters because servicing burns against the
    /// owner and pays the receiver, and those are deliberately allowed to differ.
    function invariant_usdcIsConserved() public view {
        uint256 sum = usdc.balanceOf(address(pool)) + usdc.balanceOf(creditManager) + usdc.balanceOf(epochHarvester);
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += usdc.balanceOf(handler.actors(i));
        }
        assertEq(sum, handler.totalMinted(), "USDC left the fixture");
    }

    /// The `_decimalsOffset() == 3` rounding guarantee as an instantaneous property.
    ///
    /// **Swept in audit round 16 and deliberately kept.** It is the same algebraic family as the
    /// identity that had to be rewritten above - both sides read the pool's own conversions, and
    /// neither touches `usdc.balanceOf(address(pool))` - so it holds for every `S` and every `T`
    /// against the current rounding. It is not vacuous in the way that one was, because it *does*
    /// discriminate: flip either conversion's rounding direction and this goes red, which is the
    /// only thing it claims to guard. It does **not** prove that a cheap entry cannot capture yield
    /// as a stream releases later: both legs here are quoted at one instant. The independent
    /// active-tail quote invariant above guards that entry basis. Recorded here rather than
    /// deleted, because deleting an invariant that still separates two implementations is the
    /// overcorrection, and because the next sweep should not have to re-derive why this one
    /// survived.
    function invariant_roundTripsNeverProfit() public view {
        assertLe(pool.previewRedeem(pool.previewDeposit(1_000e6)), 1_000e6, "deposit-then-redeem minted value");
        assertGe(pool.previewWithdraw(pool.previewMint(1_000e9)), 1_000e9, "mint-then-withdraw minted value");
    }

    /// @notice The queue never crystallises anybody while a reserve stands against the book.
    /// @dev **The positive statement of the round-15 fix**, and the reason the counter it reads was
    ///      turned round rather than deleted. Servicing is permissionless and its caller chooses
    ///      the instant, so any payout made while a mark stands is a payout somebody else timed -
    ///      the whole class of extraction that round executed three ways. The contract refuses
    ///      instead, on the standing reserve itself rather than on a one-wei truncation of it.
    ///
    ///      Paired with `refusalsUnderAStandingReserveWithCashPresent`, asserted non-zero by the
    ///      tripwire. Without that denominator this is satisfied by a run that never marked
    ///      anything down, which is the vacuity this file exists to keep out.
    function invariant_theQueueIsNeverServicedWhileAReserveStands() public view {
        assertEq(
            handler.queuedExitsPaidWhileAReserveStood(),
            0,
            "a queued lender was crystallised at an instant somebody else chose, under a live mark"
        );
    }

    /// @notice A markdown is temporary; a lost place in a FIFO queue is not.
    /// @dev Audit round 12 found the release branch could not tell "worthless" from "marked down to
    ///      nothing", and one permissionless call handed the whole queue back. The branch was fixed
    ///      to ask the un-impaired price and then nothing watched it, which is how the sibling
    ///      finding in the same branch survived three more audit rounds.
    function invariant_dustIsOnlyReleasedWhenItIsWorthlessAtBothPrices() public view {
        assertEq(
            handler.dustReleasedWhileStillWorthSomething(),
            0,
            "a queued lender was evicted as dust while their entry was still worth something"
        );
    }

    /// @notice The regression guard for the wedge.
    /// @dev `serviceQueue` refusing while the money to pay its head sits in the pool is not a
    ///      liquidity problem, it is an entry that cannot be cleared - and because `queuedShares`
    ///      then never returns to zero, `available()` is pinned at zero and the pool stops lending
    ///      for good. Counted from outside rather than derived from state, so it stays true even if
    ///      the internals are rewritten.
    function invariant_servicingIsNeverRefusedWhileTheHeadIsFunded() public view {
        assertEq(handler.serviceRefusedWithFundsAndQueue(), 0, "serviceQueue refused a funded head");
    }

    /// @notice Proves the fixture above is not vacuous.
    /// @dev The interesting handler actions are wrapped in `try`, which they have to be - most
    ///      random call sequences are meaningless and must not fail a run. The cost is that a
    ///      handler which could never reach a queue would still report a dozen green invariants
    ///      having exercised nothing, and here that would be worse than merely unexercised: five of
    ///      them quantify over a queue that is empty until a request lands, and the guards on the
    ///      price and the loss counter are trivially satisfied while nothing has been lent or lost.
    ///      Seven invariants once ran against zero debt for six days on exactly this mistake.
    ///
    ///      It is a normal test rather than `afterInvariant` on purpose: `afterInvariant` fires
    ///      once per run against counters that reset each run, so it would demand all of these
    ///      behaviours occur in *every* random sequence and fail on the first unlucky one.
    ///
    ///      The yield below is deliberately not round. Every queue test in `LenderPool.t.sol`
    ///      inherits an exactly divisible share ratio from the first deposit, which is precisely
    ///      what hid the servicing bug this suite guards - so a tripwire built on round numbers
    ///      would assert `fullFills` against the one case that was never broken.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        // **The two yield refusals, first, because an empty pool is the only place one of them is
        // free to reach.** Both are anti-windfall guards and neither had a denominator anywhere:
        // `distributeYield` was called unwrapped, so if a random sequence had ever reached either
        // one the whole run would have failed rather than counted it. Reaching them here is what
        // makes the wrapped version evidence rather than a silencer.
        handler.distributeYield(1);
        assertGt(
            handler.yieldRefusedWithNoSharesOutstanding(), 0, "delivering into an empty pool must be refused"
        );

        // **And the third leg of the same rule, reachable only here for the same reason.** Audit
        // round 21 finding 14's `recoverLoss` copies `repayPrincipal`'s share-floor branch, which
        // freezes the money into the pot instead of rating a stream nobody owns. An empty pool is
        // the only free place to reach it, and a rule with no denominator is the silence this file
        // exists to stop.
        handler.recoverLoss(1);
        assertGt(
            handler.lossRecoveriesFrozenBelowTheShareFloor(),
            0,
            "a recovery below the share floor must be frozen, not rated"
        );
        assertEq(pool.yieldRate(), 0, "and the stream must actually be frozen by it");

        // **The entry-side refusal audit round 22 finding 2 added, and it belongs in this opening
        // block for the same reason the two above do: a nearly-empty pool is the only place it is
        // free to reach.** `previewDeposit` rounds to zero only when the share price is above one
        // asset per wei of share, which is 10 ** offset times par - unreachable on a funded book,
        // and one donation away on an empty one. That is round 11's `maxDeposit` shape exactly.
        //
        // Snapshotted, because the donation would otherwise sit in `totalAssets()` for the rest of
        // this test and break the `MIN_SUPPLY_FOR_YIELD` arithmetic three lines down, which needs
        // the first deposit to mint at exactly the offset ratio. The counter is read before the
        // revert and asserted after it.
        {
            uint256 snap = vm.snapshotState();
            handler.donate(1_000e6);
            handler.deposit(0, 0, 1);
            bool refused = handler.depositsRefusedAsZeroShare() > 0;
            vm.revertToState(snap);
            assertTrue(refused, "a deposit that buys no share must be refused, not swallowed");
        }

        // 10,000 wei is exactly `MIN_SUPPLY_FOR_YIELD` at a decimals offset of three, so this clears
        // the share floor and nothing else. The capital rule is the one audit round 13 added on top
        // of it, and this is the gap between the two: enough holders to pay, not enough capital for
        // the epoch to be anything but a windfall.
        handler.deposit(0, 0, 10_000);
        handler.distributeYield(1_000e6);
        assertGt(
            handler.yieldRefusedAsTooLargeForTheCapital(), 0, "an epoch larger than the pool must be refused"
        );

        handler.deposit(0, 0, 5_000e6);
        handler.deposit(1, 1, 5_000e6);
        assertEq(handler.depositsDone(), 3, "deposits must be possible");

        handler.mintShares(2, 1_000e9);
        assertEq(handler.mintsDone(), 1, "mint must be possible");

        // The rising half of the deposit-cap counter's denominator. Audit round 22, finding 15:
        // the numerator `invariant_netDepositsOnlyRisesOnADepositOrMint` watches is worth nothing
        // without evidence the quantity moves at all, and this file's own history is that a
        // numerator pinned at zero by an unreachable state reads exactly like a property holding.
        assertGt(handler.netDepositsRises(), 0, "the deposit-cap counter never rose");
        assertGt(handler.principalUnitIssuances(), 0, "principal-unit issuance was never observed");

        // The cap is 25,000e6 and 15,000e6 is in. Four more 5,000e6 deposits cross it.
        for (uint256 i = 0; i < 4; i++) {
            handler.deposit(3, 3, 5_000e6);
        }
        assertGt(handler.depositsRefusedByCap(), 0, "the deposit cap was never exercised");

        // Breaks the exact share ratio the first deposit sets up, so everything below runs on
        // inexact arithmetic. This is the state the queue is actually used in.
        //
        // The skip is what makes that true. Since finding 6 an epoch lands on a clock, so at the
        // instant of delivery the ratio is still exactly 1000:1 and every queue state below would
        // be reached on the round arithmetic this tripwire's own comment warns against.
        handler.distributeYield(333_333_333);
        assertEq(handler.yieldDistributions(), 1, "yield must be deliverable");
        assertGt(pool.unreleasedYield(), 0, "an epoch must be reachable mid-stream");

        // Exercise both exact-entry doors while that tail is live. These go through the handler,
        // not bare pool calls, so the same independent quote counters used by the random campaign
        // are the evidence. The small amounts leave ample room under the principal cap reached
        // above; a cap refusal would leave the denominator at zero and fail here.
        handler.deposit(2, 2, 1e6);
        handler.mintShares(3, 1e9);
        assertGt(handler.activeTailDeposits(), 0, "an active-tail deposit quote was never observed");
        assertGt(handler.activeTailMints(), 0, "an active-tail mint quote was never observed");

        // Through the handler's own action rather than a bare `skip`, so the two derived clock
        // ghosts are exercised by the same call the fuzzer makes. A tripwire that moved time by a
        // route the fuzzer does not have would assert reachability of a state the random sequences
        // still cannot get to, which is the failure this whole test exists to prevent.
        handler.passTime(Config.YIELD_STREAM_DURATION);
        assertGt(handler.timeAdvances(), 0, "the clock must be movable");
        assertGt(handler.streamReleases(), 0, "moving the clock must release a running stream");
        assertGt(
            handler.releasedBookPriceRisesOnTheClock(),
            0,
            "the released book price must be able to rise on the clock alone"
        );
        assertEq(pool.unreleasedYield(), 0, "and must be reachable fully released");

        // Actors 0 and 1 exit completely here, which is why the queue below is driven by actors
        // 2 and 3 - the only two still holding shares.
        handler.withdrawMax(0);
        handler.redeemMax(1);
        assertEq(handler.withdrawsDone(), 1, "maxWithdraw must be executable");
        assertEq(handler.redeemsDone(), 1, "maxRedeem must be executable");

        // **The reach control, and it is what stops the green above reading as "the walk never
        // withdraws".** An invariant asserting the counter never falls goes red immediately,
        // shrunk to `deposit -> queueExit`; the state is ordinary rather than forbidden, so it is
        // asserted here as a denominator instead of shipped as a property.
        assertGt(handler.netDepositsFalls(), 0, "the deposit-cap counter never fell, so nothing exits");

        uint256 lendable = pool.available();
        assertGt(lendable, 0, "the fixture must have something to lend");
        handler.lend(lendable);
        assertEq(handler.lendsDone(), 1, "lending must be reachable");
        assertGt(pool.outstandingPrincipal(), 0, "the lend must have moved principal");

        // **The markdown probe has to bite, and it has to bite somewhere with capacity to lose.**
        // Asserted here rather than from a ghost the fuzzer sets, because invariant state does not
        // survive into a normal test, so the probe is called directly and its counter read back.
        //
        // Two zero-over-zeros were found writing this, one inside the other. The probe needs
        // exposure for the reserve to clamp against, and it needs `available()` to be non-zero or
        // the comparison it makes is `0 <= 0` and would pass against a pool where a markdown
        // doubled the lending capacity. It also needs no mark already standing: `exitReserve()`
        // clamps to `outstandingPrincipal`, so against an already-clamped reserve a second mark
        // cannot move the number at all and the probe silently proves nothing.
        //
        // The whole block runs inside a snapshot so the fixture below is untouched. The counters
        // are copied out first, because reverting the state reverts this contract's storage too.
        {
            uint256 beforeProbe = vm.snapshotState();
            handler.repayPrincipal(1_000e6);
            uint256 capacity = pool.available();
            uint256 exposure = pool.outstandingPrincipal();
            invariant_worseNewsNeverBuysMoreLending();
            uint256 bites = markdownProbesThatBit;
            vm.revertToState(beforeProbe);

            assertGt(exposure, 0, "the probe needs exposure for the reserve to clamp against");
            assertGt(capacity, 0, "the probe must run where there is lending capacity to lose");
            assertGt(bites, 0, "the markdown probe never moved the reserve, so it proved nothing");
        }

        handler.socialiseLoss(500e6);
        assertEq(handler.lossesSocialised(), 1, "a loss that absorbs something must be reachable");

        // Actor 3 holds roughly ten times actor 2, and goes first so the head is worth more than
        // the hot float left behind by the lend. That is what makes the next call a partial fill.
        // Part of the holding, not all of it. Queueing escrows the shares, so a lender who queued
        // everything has a zero balance and the second attempt below would never reach the pool -
        // it would be refused by the handler's own guard and prove nothing about the contract's.
        handler.requestWithdrawal(3, 3, 9e12);
        handler.requestWithdrawal(2, 2, type(uint256).max);
        assertEq(handler.requestsQueued(), 2, "queueing must be reachable");
        handler.requestWithdrawal(3, 3, type(uint256).max);
        assertEq(handler.requestsRefusedAsDuplicate(), 1, "the one-request-per-lender guard was never hit");

        handler.serviceQueue(5);
        assertEq(handler.partialFills(), 1, "the partial-fill path was never taken");

        // Fund it and the head clears - the case that used to leave a residual behind forever.
        // One entry only, so actor 2 stays queued and the cancel below has something to cancel.
        handler.repayPrincipal(type(uint256).max);
        // The parent ghost as well as the clamp. Audit round 15 found `dustReleases` had been
        // counted and never read since the day it was written; `repaysDone` was sitting beside it
        // in the same state, asserted only through its own special case. An unread ghost is not a
        // harmless spare - it is the shape of coverage without the substance, and the suite it sits
        // in reads as complete because of it.
        assertGt(handler.repaysDone(), 0, "repaying principal must be reachable");
        assertGt(handler.overRepaysDone(), 0, "the over-repay clamp was never exercised");
        handler.serviceQueue(1);
        assertEq(handler.fullFills(), 1, "the full-fill path was never taken");

        // A cancel is the only writer of the husk-skipping path the head guard exists for.
        handler.cancelWithdrawal(2);
        assertEq(handler.cancelsDone(), 1, "cancelling must be reachable");

        // Nothing is out on loan after the over-repay, so this absorbs nothing and only exercises
        // the clamp - which is the branch that has to be reached without moving the price.
        handler.socialiseLoss(type(uint256).max);
        assertGt(handler.lossesClamped(), 0, "the loss clamp was never exercised");

        // And the leg that reverses one. Audit round 21, finding 14: a recovery arriving on a loss
        // this pool has already written off is a gain, not a repayment, so it never touches
        // `outstandingPrincipal` - which is what keeps `invariant_outstandingPrincipalOnlyRisesOnALend`
        // and the manager-side identity both true while the money still reaches the share price.
        uint256 principalBeforeTheRecovery = pool.outstandingPrincipal();
        handler.recoverLoss(500e6);
        assertGt(handler.lossRecoveriesDone(), 0, "recovering a socialised loss must be reachable");
        assertEq(pool.outstandingPrincipal(), principalBeforeTheRecovery, "a recovery is not a repayment");

        handler.transferShares(2, 3, type(uint256).max);

        // A donation, which nobody owns and no function here can sweep. It is the slack that makes
        // the backing invariant an inequality, and it is the state audit round 11's `maxDeposit`
        // finding lived in.
        handler.donate(1_000e6);
        assertGt(handler.donationsDone(), 0, "donating straight into the pool must be reachable");

        // Servicing sets money aside; collecting it is a separate call and its own reachable state.
        handler.claim(3);
        assertGt(handler.claimsDone(), 0, "a serviced lender could not collect");

        // And the point of round 10's `available()` fix: a lend must be possible *while* somebody
        // is queued, so long as their claim is covered. The old behaviour made this unreachable.
        // Actor 3, because the transfer above left actor 2 holding nothing.
        handler.requestWithdrawal(3, 3, 1e9);
        assertGt(pool.queuedShares(), 0, "the fixture must have somebody queued here");
        uint256 lendableAlongsideQueue = pool.available();
        assertGt(lendableAlongsideQueue, 0, "a queued lender still freezes the whole book");
        handler.lend(lendableAlongsideQueue);
        assertGt(handler.lendsWhileQueued(), 0, "lending alongside a queue must be reachable");

        // ── impairment pricing, which replaced round-10's exit gate ──────────
        //
        // **Five things have to be reachable here, and this block is not asserting absence.** The
        // counter the exit invariant now watches replaced one that counted exits taken while the
        // round-10 gate was up, and the gate pinned that at zero by construction: `maxWithdraw`
        // returned zero, so the handler action bailed before it could count and the invariant
        // passed having proved nothing. The replacement can
        // only avoid that by proving *opportunity* - that the fuzzer can reach a state where an
        // exit priced against a live mark actually happens - so each step below is a state, not a
        // non-event.
        assertEq(pool.exitReserve(), 0, "the unmarked state must be reachable");
        assertGt(pool.outstandingPrincipal(), 0, "the reserve clamps to exposure, so there must be some");
        assertGt(pool.maxWithdraw(handler.actors(3)), 0, "an actor must have something to exit with");

        // 1. A mark that actually reserves something. It clamps to `outstandingPrincipal`, so a
        //    mark against an unlent pool reserves nothing - and the handler's own ghost only counts
        //    the ones that bite, for exactly that reason.
        handler.impair(0, 2_000e6);
        assertGt(handler.impairmentsSet(), 0, "marking a borrower down must be reachable");
        assertGt(pool.exitReserve(), 0, "the mark reserved nothing - the exposure clamp ate all of it");


        // 2. **The two prices must genuinely come apart.** Without this every exit invariant above
        //    is a claim about one number wearing two names, and would hold just as well against a
        //    pool that had never heard of an impairment.
        assertLt(
            pool.previewRedeem(PRICE_PROBE),
            pool.convertToAssets(PRICE_PROBE),
            "the entry and exit prices never diverged"
        );

        // 3. An exit through the queue, against that live mark. This is the composite route round
        //    11 was found through - join, self-service, collect, all permissionless and all in one
        //    transaction - so it is the one that most needs to be shown reachable rather than
        //    assumed. The standing request has to be cancelled first or the join is refused as a
        //    duplicate and the action returns without ever reaching the pool.
        handler.cancelWithdrawal(3);
        handler.queueExit(3, 1e9);

        // The composite leaves the entry standing, because servicing under a mark is refused. The
        // bare action is called separately so the refusal is counted by the ghost the fuzzer's own
        // `serviceQueue` maintains - `queueExit` wraps its own call and deliberately measures
        // payouts rather than refusals.
        handler.serviceQueue(3);
        assertGt(
            handler.refusalsUnderAStandingReserveWithCashPresent(),
            0,
            "the queue was never even asked to service under a live mark with cash present"
        );
        assertEq(
            handler.queuedExitsPaidWhileAReserveStood(),
            0,
            "the queue paid somebody out while a reserve stood against the book"
        );

        // 4. And an exit through the front door, which is a different valuation path.
        handler.withdrawMax(3);
        assertGt(
            handler.exitsPricedAgainstAnImpairment(), 0, "no immediate exit was ever priced against a live mark"
        );

        // 5. Release, or a mark would outlive its cause and the exit price could never be observed
        //    coming back up - which is half of what the exit-price invariant quantifies over.
        handler.releaseImpairment(0);
        assertGt(handler.impairmentsReleased(), 0, "releasing a mark must be reachable");
        assertEq(pool.exitReserve(), 0, "the reserve outlived its release");

        // 6. **Genuine dust, released and stepped over.** Audit round 15's sharpest test finding was
        //    that this branch had a ghost counting it and nothing reading the ghost, and no unit
        //    test for its release half at all - so the one branch that can stop the walk on a live
        //    entry was the one branch with no reachability evidence anywhere. It is reached here
        //    with the mark already released, because "genuine dust" means worth nothing at *both*
        //    prices: an entry worth zero only at the exit price is a marked-down lender, and
        //    releasing that one is the round-12 eviction. One share-wei is dust by construction at
        //    a decimals offset of three, since the price is about a thousand shares to the asset-wei.
        handler.cancelWithdrawal(3);
        assertGt(pool.balanceOf(handler.actors(3)), 0, "the fixture must have shares left to make dust with");
        handler.requestWithdrawal(3, 3, 1);
        assertEq(pool.convertToAssets(1), 0, "one share-wei is not dust here - the fixture ratio moved");
        handler.serviceQueue(5);
        assertGt(handler.dustReleases(), 0, "releasing genuine dust must be reachable");
        assertEq(pool.balanceOf(address(pool)), 0, "the dust was not handed back to its owner");

        // The book-level pair, reached separately because it is a different writer and because the
        // backlog is the one branch of the deleted gate that had to be rebuilt rather than argued
        // away: a recognised loss outlives the auction that produced it.
        handler.setLossReserves(1_500e6, 0);
        assertGt(handler.backlogsSet(), 0, "the recognised-but-unplaced backlog must be reachable");
        assertGt(pool.exitReserve(), 0, "the backlog priced into nothing");
        handler.setLossReserves(1_500e6, 1_000e6);
        assertGt(handler.coversSet(), 0, "insurance cover must be reachable");
        handler.setLossReserves(0, 0);
        assertEq(pool.exitReserve(), 0, "clearing the book-level reserves must put the price back");

        assertEq(handler.serviceRefusedWithFundsAndQueue(), 0, "the queue wedged during the tripwire");
        assertEq(
            handler.exitsAboveTheImpairedPrice(), 0, "an exit was paid above the impaired price during the tripwire"
        );

        // ── the denominators under the five watched observations ─────────────
        //
        // **Five numerators that must stay zero are worth exactly as much as the evidence that the
        // quantities behind them move at all.** The invariants these replaced were vacuous because
        // forge discarded the value they remembered; replacing them with counters that no action
        // ever increments would be the same vacuity with a shorter diff. Each of these is the
        // denominator of one of them, and every one is reached by the sequence above rather than by
        // a special case written to satisfy it.
        assertGt(
            handler.headAdvances(), 0, "the queue head never moved forward, so the backwards counter proves nothing"
        );
        assertGt(handler.lifetimeLossRises(), 0, "the disclosure counter never rose, so its cause was never tested");
        assertGt(handler.principalRises(), 0, "principal never rose, so the no-lend counter proves nothing");
        assertGt(
            handler.releasedBookPriceFalls(), 0, "the released book price never fell, so its cause was never tested"
        );
        assertGt(handler.exitPriceFalls(), 0, "the exit price never fell, so its cause was never tested");
    }
}
