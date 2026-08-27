// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {LowCeilingPool} from "./LenderPoolPrincipalRescaling.t.sol";

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

    /// @notice Times a share was offered straight to the escrow and refused. Round-23 finding 16.
    /// @dev The denominator for the exclusion this replaced. An exclusion that names a state and
    ///      then counts nothing is indistinguishable from one that has quietly stopped reaching it.
    uint256 public escrowDonationsRefused;

    /// @notice Times a queue entry was offered the escrow as its **receiver** and refused, and
    ///         times one was accepted. Audit round 24, the fifth door.
    /// @dev **The receiver set used to be `actors` and nothing else, and that is why 128,000 calls
    ///      a run saw nothing.** The four doors round-23 finding 16 shut are all about a share
    ///      arriving at `address(pool)`; this is the pool arriving in `WithdrawalRequest.receiver`,
    ///      which puts the pool's own USDC into `claimable[address(pool)]` when the queue services.
    ///      A contract fix on its own would have left the campaign exactly as blind, so the draw is
    ///      widened here in the same change - a guard nothing can offer a violation to is not a
    ///      guard the campaign has tested.
    ///
    ///      Same shape as `escrowDonationsRefused`/`escrowDonationsAccepted`: the refusal is the
    ///      denominator and the acceptance is the numerator that must stay zero.
    uint256 public escrowReceiverRequestsRefused;
    uint256 public escrowReceiverRequestsAccepted;

    /// @notice Times an ERC-4626 **exit** was offered the escrow as its receiver and refused, and
    ///         times one was accepted. Audit round 25 finding 1, the four doors one field along
    ///         from the fifth.
    /// @dev **This pair is the other half of that finding, and without it the fix ships blind.**
    ///      Round 24 widened the receiver draw at `requestWithdrawal` and at nothing else, so
    ///      `withdrawMax` and `redeemMax` went on passing `receiver == owner` and the exit doors'
    ///      receiver parameter had **zero variance in 128,000 calls a run**. A guard nothing can
    ///      offer a violation to is not a guard the campaign has tested - the same sentence the
    ///      round-24 counter above is written under, and the reason it is repeated here rather
    ///      than assumed to have generalised.
    ///
    ///      Four doors, two actions: `withdrawMax` and `redeemMax` each draw a door as well as a
    ///      receiver, so the round-20 bounded overloads are exercised too. They carry no guard of
    ///      their own and are shut only because they delegate, which is a property of the bodies
    ///      as written and is exactly the kind of thing a refactor removes silently.
    ///
    ///      Same shape as the two pairs above: the refusal is the denominator that says the draw
    ///      still reaches the door, and the acceptance is the numerator that must stay zero.
    uint256 public escrowExitReceiversRefused;
    uint256 public escrowExitReceiversAccepted;

    /// @notice And the numerator: times a door **accepted** one. Must stay zero.
    /// @dev Counted rather than reverted on, and that distinction is the whole value of this
    ///      action. The first draft reverted the handler frame when a door let the share through,
    ///      which meant the corrupt state was discarded before any invariant could see it.
    ///      **MEASURED, with all four doors reopened: `invariant_principalUnitsConserveNetDeposits`
    ///      passed 256 runs and 128,000 calls, and only the deterministic reach test went red.** An
    ///      action that undoes the damage it causes is not a detector. Letting the donation stand
    ///      is what puts the escrow equality on the hook.
    uint256 public escrowDonationsAccepted;
    uint256 public fullFills;
    uint256 public partialFills;

    /// @notice The two ghosts that make the partial-fill branch *visible* rather than merely
    ///         reachable, and the denominator that stops the first from being vacuous.
    /// @dev **Audit round 25, finding 2.** The partial-fill branch was reached and nothing looked
    ///      inside it: flipping `serviceQueue`'s `_exitToShares(idle, Floor)` to `Ceil` stayed
    ///      green across all 58 `LenderPool` invariant evaluations and all 900 deterministic
    ///      tests. `partialFills` counted the branch; no assertion anywhere said what the branch
    ///      had to produce.
    ///
    ///      `partialFillsBurningMoreThanTheCashCovers` is the numerator and
    ///      `invariant_aPartialFillNeverBurnsMoreThanItsCashCovers` requires it to be zero. The
    ///      predicate is `sharesBurned * (exitAssets() + 1) <= idle * (totalSupply() + 10**3)`,
    ///      evaluated on state read **before** the call and restated here rather than asked of the
    ///      pool. Asking the pool to convert `idle` would be the shape round 25 filed against
    ///      `RiskParams.invariants.t.sol`: a function checked against its own output agrees with
    ///      itself under every mutation.
    ///
    ///      `partialFillsWithInexactShareRounding` is the denominator, and it is the one that
    ///      matters. Where `idle * s` divides `a` exactly, Floor and Ceil are the same number and
    ///      the numerator above **cannot** rise however many partial fills happen. That is not
    ///      hypothetical: `LenderPool.t.sol`'s
    ///      `test_theRoundNumberFixtureCannotSeeThePartialFillRounding` pins a fixture where the
    ///      division is exact and the mutation survives. So the reach test asserts this counter is
    ///      non-zero, not merely that `partialFills` is.
    uint256 public partialFillsWithInexactShareRounding;
    uint256 public partialFillsBurningMoreThanTheCashCovers;

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
    /// @notice Lends that took `available()` to the wei, which is the state a partial fill
    ///         needs in front of it. See `lendTheWholeFloat`.
    uint256 public floatEmptyingLends;
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

    /// @notice The entry pause, and the three things it has to actually reach. Round-28 item 6's
    ///         `LenderPool` half, alongside round-28 item 10.
    /// @dev `pausesDone` on its own would be the defect the clock ghosts above were written against
    ///      wearing a new name: it proves the switch was thrown, not that any invariant was ever
    ///      *evaluated* on the far side of it. `entriesRefusedByThePause` says the campaign put a
    ///      deposit or a mint against a shut door and `exitsWhilePaused` says it took money out
    ///      through one that stayed open, which is the premise the guardian's reach rests on and
    ///      the only one of the three that would be worth anything on its own.
    uint256 public pausesDone;
    uint256 public unpausesDone;
    uint256 public entriesRefusedByThePause;
    uint256 public exitsWhilePaused;

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

    /// @notice The denominator under the correction audit round 24 made to the ghost above, and
    ///         the one number that says this campaign is not measuring drift zero.
    /// @dev **Audit round 24: `_recordPrincipalUnitIssuance` was FALSE, and no campaign could see
    ///      it.** It compared `totalPrincipalUnits()` with `unitsBefore + expected` - which is the
    ///      figure at the exponent the entry was quoted at, not the figure the contract is left
    ///      holding when `_deposit` renormalises on the way out. The expression is corrected rather
    ///      than the call excluded, because excluding the calls where the exponent moved is exactly
    ///      how a vacuous invariant is made to look green, and that is the class being fixed here.
    ///
    ///      This counter exists so the correction cannot rot back into vacuity unnoticed. If it is
    ///      zero the ghost has only ever been evaluated at `shift == 0`, where the corrected and
    ///      the false expressions are identical - which is the state the shipped-ceiling campaign
    ///      is in and the reason `LenderPoolInvariantsAtALoweredCeiling` exists.
    uint256 public principalUnitIssuancesAcrossAShift;

    /// @notice Times `_renormaliseUnits` actually fired during an action, the largest number of
    ///         live queue entries standing when one did, and the largest escrow residue observed.
    /// @dev **The three numbers audit round 24 found nobody had.** At the shipped ceiling
    ///      `unitExponent` was 0 at every seed across 128,000 calls, so every relaxed bound in
    ///      `invariant_principalUnitsConserveNetDeposits` was being evaluated at drift zero and the
    ///      campaign would have passed identically with those `assertLe`s written as the `assertEq`s
    ///      they replaced.
    ///
    ///      `maxLiveEntriesAtAShift` is the `h` the escrow bound is written against, and it is
    ///      recorded **at the shift** rather than continuously, because that is the only moment the
    ///      residue can change: between shifts every credit and every debit against the escrow moves
    ///      the entry and the escrow by exactly the same figure. That is also why one walk of the
    ///      queue per renormalisation is enough to keep `maxEscrowResidueObserved` complete.
    uint256 public renormalisationsObserved;
    uint256 public maxLiveEntriesAtAShift;
    uint256 public maxEscrowResidueObserved;

    /// @notice Completed crush-and-recover cycles, which is the only thing that moves the price of
    ///         admission far enough for the ceiling to bind.
    uint256 public crushAndRecoverCycles;

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
        uint256 unitExponent;
    }

    Watch private _before;

    /// @notice The two pre-call readings the partial-fill check needs.
    /// @dev **Storage for the same two reasons `Watch` above is.** They have to stay live across
    ///      the external call the action makes, and `serviceQueue` is the action this file already
    ///      measured as sitting at the compiler's stack limit - two more locals there is what tips
    ///      it over. Written by `_observeFill` at the top of the `serviceQueue` action, read by
    ///      `_recordPartialFill` in the branch that took one. Nothing else touches it, and the
    ///      handler's actions never nest - `serviceAThinnedQueue` is deliberately not `watched`
    ///      for exactly that reason - so one slot is enough.
    struct FillWatch {
        uint256 supply;
        uint256 exitAssets;
    }

    FillWatch private _fill;

    mapping(address account => bool credited) private _creditedInGeneration;
    uint256 public creditedHolderCount;

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
        _before.unitExponent = pool.unitExponent();
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

        _recordCreditedHolders();
        _recordRenormalisation();
    }

    /// @dev Recorded at the shift and only at the shift. The escrow residue - escrowed units in
    ///      excess of what the live entries between them claim - changes at no other moment:
    ///      `_requestWithdrawal` credits the escrow exactly what it writes on the entry,
    ///      `cancelWithdrawalRequest` and both `serviceQueue` branches debit exactly what they read
    ///      off it, and a shift is the only event that floors the two sides independently. One walk
    ///      of the queue per renormalisation is therefore complete, and a walk after every action
    ///      would cost the campaign a queue scan per call to learn nothing new.
    function _recordRenormalisation() private {
        if (pool.unitExponent() == _before.unitExponent) return;
        ++renormalisationsObserved;

        (uint256 queueUnits, uint256 liveEntries) = _liveQueueUnits();
        if (liveEntries > maxLiveEntriesAtAShift) maxLiveEntriesAtAShift = liveEntries;

        uint256 residue = pool.principalUnits(address(pool)) - queueUnits;
        if (residue > maxEscrowResidueObserved) maxEscrowResidueObserved = residue;
    }

    /// @dev The `h` the renormalisation drift bound is written against: every account that has been
    ///      credited units **at any point in the current generation**.
    ///
    ///      **Not the accounts currently reading a non-zero figure, and the difference is a real
    ///      failure rather than a theoretical one.** A holder whose units have floored all the way
    ///      to zero contributed its floor to the drift on the way down and can then exit without
    ///      clearing its stored figure, because `_update` only writes the remainder when it moves
    ///      units. Counting the visible holders reported `h = 1` against a real drift of 1 and
    ///      failed a bound that is true; the fuzz in `LenderPoolPrincipalRescaling.t.sol` found it
    ///      on run 3. Recorded after every action and cleared when a generation roll clears the
    ///      ledger it is counting.
    function _recordCreditedHolders() private {
        // **The roll check goes FIRST, and audit round 25 found out why.** The saturation early
        // return below used to sit above this block, which made the reset unreachable: once four
        // lenders and the escrow had each held anything, the count was pinned at five and no
        // generation roll could clear it. MEASURED at 5 after a full unwind leaving
        // `totalPrincipalUnits == 0`, so the bound this counter feeds degraded to the slack
        // constant this file argues against two paragraphs above, and the deterministic sibling -
        // which has no early return - disagreed with it about the same quantity.
        // `test_aGenerationRollClearsTheCreditedHolderCount` is the guard on the ordering.
        if (pool.totalPrincipalUnits() == 0) {
            for (uint256 i = 0; i < actors.length; i++) {
                _creditedInGeneration[actors[i]] = false;
            }
            _creditedInGeneration[address(pool)] = false;
            creditedHolderCount = 0;
            return;
        }

        // Nothing left to learn once every possible holder is marked, and this runs after every
        // action of every campaign, so the early return is worth its two lines. It has to stay
        // below the roll check for the reason above.
        if (creditedHolderCount == actors.length + 1) return;

        for (uint256 i = 0; i < actors.length; i++) {
            _markCredited(actors[i]);
        }
        _markCredited(address(pool));
    }

    function _markCredited(address account) private {
        if (_creditedInGeneration[account]) return;
        if (pool.principalUnits(account) == 0 && pool.balanceOf(account) == 0) return;
        _creditedInGeneration[account] = true;
        ++creditedHolderCount;
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

    function _observeFill() private {
        _fill.supply = pool.totalSupply();
        _fill.exitAssets = pool.exitAssets();
    }

    /// @notice What a partial fill had to produce, checked from outside against state read before
    ///         the call.
    /// @dev **The conversion is restated, never asked of the pool.** `serviceQueue` computes the
    ///      share slice as `_exitToShares(idle, Floor)`; asking the pool for that same number and
    ///      comparing would agree with itself under every mutation, which is the tautology shape
    ///      round 25 filed against `RiskParams.invariants.t.sol`. These are OZ's ERC-4626 terms
    ///      written out, with `exitAssets()` in place of `totalAssets()` and `10**3` for
    ///      `_decimalsOffset()`.
    ///
    ///      **Why call-level deltas are the right measurement here and would not be in the other
    ///      two branches.** A call the handler counts as a partial fill stops on the entry it
    ///      partially filled: the loop `break`s underneath it, and everything the walk could have
    ///      done in front of it - stepping over a zero-share husk, releasing dust - moves no USDC
    ///      and burns no shares. So exactly one burn happened in the whole call and the supply
    ///      delta is that burn. A fill counted as full may be one of several in the same call and
    ///      is not measured this way.
    ///
    ///      **Under-counts on purpose, in one case.** A partial fill that happens *behind* a dust
    ///      release in the same call is counted as `dustReleases` by the prediction above and never
    ///      reaches here. Under-counting a denominator is safe; over-counting it is not.
    function _recordPartialFill(uint256 idleBefore) private {
        uint256 s = _fill.supply + 10 ** 3;
        uint256 a = _fill.exitAssets + 1;
        uint256 floored = Math.mulDiv(idleBefore, s, a, Math.Rounding.Floor);

        // The denominator. Where the division is exact the two roundings are one number and the
        // numerator below is structurally incapable of rising, so a campaign that only ever hit
        // exact ratios would report a green invariant over nothing.
        if (floored != Math.mulDiv(idleBefore, s, a, Math.Rounding.Ceil)) {
            ++partialFillsWithInexactShareRounding;
        }

        uint256 burned = _fill.supply - pool.totalSupply();
        if (burned > floored) ++partialFillsBurningMoreThanTheCashCovers;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _borrower(uint256 seed) internal view returns (address) {
        return borrowers[seed % borrowers.length];
    }

    /// @dev The receiver draw for `requestWithdrawal`, and the pool is in it. See
    ///      `escrowReceiverRequestsRefused` for why. Deliberately **not** `_actor`: the owner draw
    ///      must stay the actor set, because an owner is somebody who can hold shares and the pool
    ///      escrow is not.
    function _receiverIncludingTheEscrow(uint256 seed) internal view returns (address) {
        uint256 slot = seed % (actors.length + 1);
        return slot == actors.length ? address(pool) : actors[slot];
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

    /// @dev **Corrected in audit round 24, and the correction is the whole point of the ghost.**
    ///      `_deposit` credits the receiver at the pre-entry ratio and *then* calls
    ///      `_renormaliseUnits`, so what the contract is left holding is
    ///      `(unitsBefore + expected) >> shift`, not `unitsBefore + expected`. Written without the
    ///      shift this ghost was simply false on every entry that crossed the ceiling, and no
    ///      campaign could see it because none of them ever crossed one.
    ///
    ///      The shift term is exact rather than a tolerance. `_renormaliseUnits` halves the
    ///      aggregate one bit at a time, and repeated integer halving is a single shift -
    ///      `floor(floor(x/2)/2) == floor(x/4)` - so the whole loop is `>> shift` with
    ///      `shift = unitExponent_after - unitExponent_before`. A shift of 256 or more yields zero,
    ///      which is what the contract's own reads do and is the honest answer at that resolution.
    ///
    ///      **Not excluded, corrected.** Skipping the calls where the exponent moved would make
    ///      this counter green by refusing to look at the only calls that can falsify it, which is
    ///      the defect class this change exists to close. `principalUnitIssuancesAcrossAShift` is
    ///      the denominator that says the corrected branch is reached at all.
    ///
    ///      The pre-call exponent is read off `_before` rather than passed in: `watched` has
    ///      already recorded it, nothing between `_observe` and the pool call can move it, and both
    ///      call sites are close enough to the stack limit that an extra argument is a risk for no
    ///      gain.
    function _recordPrincipalUnitIssuance(uint256 unitsBefore, uint256 netBefore, uint256 assets) private {
        uint256 expected = unitsBefore == 0
            ? assets
            : Math.mulDiv(assets, unitsBefore, netBefore, Math.Rounding.Ceil);
        ++principalUnitIssuances;

        uint256 shift = pool.unitExponent() - _before.unitExponent;
        if (shift != 0) ++principalUnitIssuancesAcrossAShift;

        if (pool.totalPrincipalUnits() != (unitsBefore + expected) >> shift) ++principalUnitIssuanceMismatches;
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
            // **Three legal refusals since round-28 item 10 added the entry pause**, and the new
            // one is counted separately from the other two for the reason the second one is: they
            // are different refusals about different things, and folding them together would let
            // any one of them fall to zero unnoticed. The pause arm is also the one that must not
            // be swallowed by the cap arm - the whole point of the modifier is that a shut pool
            // says so instead of claiming to be full.
            bytes4 selector = bytes4(err);
            if (selector == LenderPool.ZeroAmount.selector) {
                ++depositsRefusedAsZeroShare;
            } else if (selector == Pausable.EnforcedPause.selector) {
                ++entriesRefusedByThePause;
            } else {
                assertEq(selector, LenderPool.DepositCapExceeded.selector, "unexpected deposit revert");
                ++depositsRefusedByCap;
            }
        }
    }

    /// @dev The receiver draw here is `_actor` and not `_receiverIncludingTheEscrow`, and the
    ///      distinction is deliberate rather than an omission. What this action varies is
    ///      *receiver against owner*, the split `invariant_usdcIsConserved` defends; the escrow on
    ///      this particular door is already offered on every draw by
    ///      `attemptDonationToTheEscrow`, which counts the refusal, and a second unconstrained
    ///      source of it here would make that counter's denominator unreadable.
    function mintShares(uint256 actorSeed, uint256 receiverSeed, uint256 shares) external watched {
        address a = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        shares = bound(shares, 1, 5_000e9);
        ActiveTailQuote memory tailQuote = _activeTailMintQuote(shares);
        uint256 cost = pool.previewMint(shares);
        if (cost == 0) return;
        uint256 unitsBefore = pool.totalPrincipalUnits();
        uint256 netBefore = pool.netDeposits();
        _mint(a, cost);

        vm.prank(a);
        try pool.mint(shares, receiver) returns (uint256 paidAssets) {
            ++mintsDone;
            if (tailQuote.observed) {
                ++activeTailMints;
                if (paidAssets != tailQuote.amount) ++activeTailMintQuoteMismatches;
            }
            _recordPrincipalUnitIssuance(unitsBefore, netBefore, paidAssets);
            // Same subject as `deposit` above, for the same reason - including the live read.
            assertLe(pool.netDeposits(), pool.depositCap(), "mint crossed the cap");
        } catch (bytes memory err) {
            // Same third arm as `deposit` above, and for the same reason.
            if (bytes4(err) == Pausable.EnforcedPause.selector) {
                ++entriesRefusedByThePause;
            } else {
                assertEq(bytes4(err), LenderPool.DepositCapExceeded.selector, "unexpected mint revert");
                ++depositsRefusedByCap;
            }
        }
    }

    /// @dev `maxWithdraw` as an executable claim rather than an assertion that restates its own
    ///      `min()`. The contract's NatSpec promises it "reports what can genuinely be taken now",
    ///      and the only honest way to check a promise like that is to take it.
    ///
    ///      **The receiver and the door are both drawn since audit round 25 finding 1, and before
    ///      that neither varied.** This action used to be `withdraw(assets, a, a)`: one door out of
    ///      the two the pool offers, and a receiver that was always the owner, so the parameter the
    ///      finding is about had zero variance in 128,000 calls a run. The escrow is in the
    ///      receiver draw for the reason `escrowExitReceiversRefused` gives, and the bounded
    ///      round-20 overload is in the door draw because it carries no guard of its own - it is
    ///      shut only by delegating here, and a refactor could take that away without touching a
    ///      line this file reads.
    ///
    ///      The bound passed to the overload is `type(uint256).max`, deliberately inert. A bound
    ///      that could fire would make a refusal ambiguous between the guard and the slippage
    ///      check, and telling those apart is this action's whole job.
    ///
    ///      The catch arm splits on the selector for the same reason the deposit arm does. A
    ///      refusal for the *right* reason is counted; anything else is still the original
    ///      assertion, because `maxWithdraw` offering more than `withdraw` will pay is the failure
    ///      this action was written for and must not be swallowed by the new arm.
    function withdrawMax(uint256 actorSeed, uint256 receiverSeed, uint256 doorSeed) external watched {
        address a = _actor(actorSeed);
        address receiver = _receiverIncludingTheEscrow(receiverSeed);
        uint256 assets = pool.maxWithdraw(a);
        if (assets == 0) return;

        bool marked = pool.exitReserve() != 0;
        bool bounded = doorSeed % 2 == 1;
        uint256 exitAssetsBefore = pool.exitAssets();
        uint256 supplyBefore = pool.totalSupply();

        uint256 burned;
        bool wasPaid;
        bytes memory err;
        if (bounded) {
            vm.prank(a);
            try pool.withdraw(assets, receiver, a, type(uint256).max) returns (uint256 shares) {
                burned = shares;
                wasPaid = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            vm.prank(a);
            try pool.withdraw(assets, receiver, a) returns (uint256 shares) {
                burned = shares;
                wasPaid = true;
            } catch (bytes memory e) {
                err = e;
            }
        }

        if (!wasPaid) {
            assertEq(
                bytes4(err),
                LenderPool.EscrowIsNotAHolder.selector,
                "maxWithdraw offered more than withdraw would pay"
            );
            assertEq(receiver, address(pool), "an ordinary receiver was refused as if it were the escrow");
            ++escrowExitReceiversRefused;
            return;
        }

        if (receiver == address(pool)) ++escrowExitReceiversAccepted;
        // The premise, counted rather than argued: money left through this door while the entry
        // door was shut. Read after the pool call, so there is no prank left standing on it.
        if (pool.paused()) ++exitsWhilePaused;
        ++withdrawsDone;
        if (marked) {
            ++exitsPricedAgainstAnImpairment;
            if (_paidAboveTheExitPrice(assets, burned, exitAssetsBefore, supplyBefore)) {
                ++exitsAboveTheImpairedPrice;
            }
        }
    }

    /// @dev The share-input twin of `withdrawMax`, drawn the same way and for the same reasons.
    ///      The bounded overload's floor is 0 here rather than `type(uint256).max`, which is the
    ///      inert end on this side: the comparison runs the other way.
    function redeemMax(uint256 actorSeed, uint256 receiverSeed, uint256 doorSeed) external watched {
        address a = _actor(actorSeed);
        address receiver = _receiverIncludingTheEscrow(receiverSeed);
        uint256 shares = pool.maxRedeem(a);
        if (shares == 0) return;

        bool marked = pool.exitReserve() != 0;
        bool bounded = doorSeed % 2 == 1;
        uint256 exitAssetsBefore = pool.exitAssets();
        uint256 supplyBefore = pool.totalSupply();

        uint256 got;
        bool wasPaid;
        bytes memory err;
        if (bounded) {
            vm.prank(a);
            try pool.redeem(shares, receiver, a, 0) returns (uint256 assets) {
                got = assets;
                wasPaid = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            vm.prank(a);
            try pool.redeem(shares, receiver, a) returns (uint256 assets) {
                got = assets;
                wasPaid = true;
            } catch (bytes memory e) {
                err = e;
            }
        }

        if (!wasPaid) {
            assertEq(
                bytes4(err), LenderPool.EscrowIsNotAHolder.selector, "maxRedeem offered more than redeem would pay"
            );
            assertEq(receiver, address(pool), "an ordinary receiver was refused as if it were the escrow");
            ++escrowExitReceiversRefused;
            return;
        }

        if (receiver == address(pool)) ++escrowExitReceiversAccepted;
        if (pool.paused()) ++exitsWhilePaused;
        ++redeemsDone;
        if (marked) {
            ++exitsPricedAgainstAnImpairment;
            if (_paidAboveTheExitPrice(got, shares, exitAssetsBefore, supplyBefore)) {
                ++exitsAboveTheImpairedPrice;
            }
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
    ///
    ///      **The escrow is in the receiver draw since audit round 24, and the acceptance is
    ///      counted rather than reverted on.** Same shape and same reason as
    ///      `attemptDonationToTheEscrow`: an action that undoes the damage it causes is not a
    ///      detector, so a request that names `address(pool)` and is allowed through is left
    ///      standing for the invariants to see rather than rolled back by an assertion here.
    function requestWithdrawal(uint256 actorSeed, uint256 receiverSeed, uint256 shares) external watched {
        address a = _actor(actorSeed);
        uint256 held = pool.balanceOf(a);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        address receiver = _receiverIncludingTheEscrow(receiverSeed);

        vm.prank(a);
        try pool.requestWithdrawal(shares, receiver) {
            ++requestsQueued;
            if (receiver == address(pool)) ++escrowReceiverRequestsAccepted;
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            if (selector == LenderPool.EscrowIsNotAHolder.selector) {
                ++escrowReceiverRequestsRefused;
            } else {
                assertEq(selector, LenderPool.AlreadyQueued.selector, "unexpected requestWithdrawal revert");
                ++requestsRefusedAsDuplicate;
            }
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

    /// @dev Actor to actor. The pool used to be excluded from the destination set on the grounds
    ///      that a share transferred straight into it is "an ERC-20 fact about every
    ///      escrow-by-transfer design, not a defect in this one, and there is nothing the pool
    ///      could do about it".
    ///
    ///      **Round 23 found that exclusion expired.** It was written for the shares leg, where it
    ///      was true, and PR #246 later added a *units* leg to the same address, where it was not:
    ///      a donated share also mints escrow principal units that no queue entry claims and
    ///      nothing can ever retire, which is deposit-cap headroom gone for good. That was round-23
    ///      finding 16. There was something the pool could do about it, and it now does - see
    ///      `attemptDonationToTheEscrow` immediately below, which is the same call this exclusion
    ///      used to cover, kept in the sequence and required to be refused.
    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external watched {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = pool.balanceOf(from);
        if (held == 0 || from == to) return;
        amount = bound(amount, 1, held);

        vm.prank(from);
        pool.transfer(to, amount);
    }

    /// @notice The call the exclusion above used to remove from the sequence, put back and
    ///         required to fail.
    /// @dev **This is what turns `invariant_principalUnitsConserveNetDeposits`'s escrow equality
    ///      from a fact about the fixture into a fact about the contract.** Before round-23
    ///      finding 16's fix the equality held only because no handler action could reach the
    ///      pool's own address; the invariant read as coverage that was not there. Now the fuzzer
    ///      offers a share at all three of the doors that are not `requestWithdrawal`, and the
    ///      contract refuses all three.
    ///
    ///      **A success is counted and left standing, never reverted.** See
    ///      `escrowDonationsAccepted` for the measurement that forced that shape: undoing the
    ///      donation hid it from every invariant in the file. A refusal is caught and its selector
    ///      asserted, both because `invariant_theHandlerNeverDropsAFrame` runs this handler under
    ///      `fail-on-revert = true` and because a refusal for some *other* reason must not read as
    ///      the guard working.
    function attemptDonationToTheEscrow(uint256 fromSeed, uint256 amount, uint256 doorSeed) external watched {
        address from = _actor(fromSeed);
        uint256 held = pool.balanceOf(from);
        if (held == 0) return;
        amount = bound(amount, 1, held);

        uint256 door = doorSeed % 3;
        bool accepted;
        bytes memory err;

        if (door == 0) {
            vm.prank(from);
            try pool.transfer(address(pool), amount) {
                accepted = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (door == 1) {
            // Assets, not shares, on this door, and bounded by the cap as well as by the balance:
            // an ordinary `DepositCapExceeded` is not evidence about this guard either way.
            uint256 room = pool.maxDeposit(address(pool));
            uint256 assets = amount > room ? room : amount;
            if (assets == 0) return;
            vm.prank(from);
            try pool.deposit(assets, address(pool)) {
                accepted = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            uint256 room = pool.maxMint(address(pool));
            uint256 shares = amount > room ? room : amount;
            if (shares == 0) return;
            vm.prank(from);
            try pool.mint(shares, address(pool)) {
                accepted = true;
            } catch (bytes memory e) {
                err = e;
            }
        }

        if (accepted) {
            ++escrowDonationsAccepted;
        } else {
            assertEq(bytes4(err), LenderPool.EscrowIsNotAHolder.selector, "unexpected escrow-door revert");
            ++escrowDonationsRefused;
        }
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
        // The supply and exit-asset readings the partial-fill check needs, into storage rather
        // than onto the stack. See `_recordPartialFill`.
        _observeFill();

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
                _recordPartialFill(idleBefore);
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

    /// @notice Lend exactly what `available()` says, to the wei.
    /// @dev **This exists because `lend` above essentially never picks that number and the
    ///      partial-fill branch needs it.** `lend` draws uniformly over `[1, available() + 1000e6]`,
    ///      so the probability of landing on the boundary is negligible, and a fill can only be
    ///      partial while the head is worth more than the idle cash left behind. It also covers the
    ///      boundary of `available()` itself, which nothing was hitting exactly.
    function lendTheWholeFloat() external watched {
        uint256 lendable = pool.available();
        if (lendable == 0) return;

        vm.prank(creditManager);
        try pool.lend(lendable) {
            ++lendsDone;
            ++floatEmptyingLends;
            assertGe(
                usdc.balanceOf(address(pool)) - pool.totalClaimable(),
                (pool.totalAssets() * Config.RESERVE_RATIO_BPS) / Config.BPS,
                "lending the whole float ate the hot float"
            );
        } catch (bytes memory err) {
            assertEq(bytes4(err), LenderPool.InsufficientLiquidity.selector, "unexpected lend revert");
        }
    }

    /// @notice The three moves that make a partial fill, in the only order that can produce one.
    /// @dev **This is the widening audit round 25 asked for, and the reason it has to be a compound
    ///      action rather than a nudge to the existing ones is an ordering constraint in the
    ///      contract.** `available()` subtracts what the queue is already owed, so once a large
    ///      request is standing the manager cannot lend the money out from under it. A partial fill
    ///      therefore requires lend-then-queue-then-service, in that order, with nothing that adds
    ///      idle cash in between - and a uniform random walk over thirty-odd actions produces that
    ///      ordering rarely. **Measured before this existed: the branch was reached in 1 of 8
    ///      unseeded 128,000-call campaigns.**
    ///
    ///      **Not `watched`.** Each of the three calls below is watched in its own right, and
    ///      `Watch` is a single storage slot on the assumption that actions never nest. Wrapping
    ///      this one too would make `_settle` compare against a snapshot taken inside the frame it
    ///      is closing. Same shape as `RiskParamsHandler.proposeNearby`.
    ///
    ///      **It does not force the branch.** The actor may hold nothing, may already be queued, a
    ///      reserve may be standing, and the head may be worth less than the float - all of which
    ///      leave this a full fill, a refusal or a no-op. What it removes is the ordering
    ///      improbability, not the state.
    function serviceAThinnedQueue(uint256 actorSeed, uint256 receiverSeed, uint256 shares, uint256 maxEntries)
        external
    {
        this.lendTheWholeFloat();
        this.requestWithdrawal(actorSeed, receiverSeed, shares);
        this.serviceQueue(maxEntries);
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

    /// @notice Throw the entry pause, from the owner. Round-28 items 6 and 10.
    /// @dev **Reads first, then the prank, then the call, and the order is not stylistic.**
    ///      `vm.prank` is spent on the *next* call including a staticcall, so `vm.prank(owner_);
    ///      if (pool.paused())` would spend the prank on the read and send the switch call from the
    ///      handler - which is not the owner, so every frame would refuse. That mistake is on record
    ///      in this repository as 15,967 reverts out of 15,967 reading as
    ///      `OwnableUnauthorizedAccount`, which is a plausible protocol failure rather than an
    ///      obvious tooling one, and that is what made it expensive. Both reads happen above the
    ///      prank here for that reason.
    ///
    ///      **Reopening is deliberately rarer than shutting.** A switch thrown on every other call
    ///      would leave the pool paused for about half the walk in short alternating runs, and what
    ///      this action is for is getting the *other* invariants evaluated against a paused pool for
    ///      a stretch long enough that a deposit, an exit and a queue service all land inside one.
    ///      One reopen in three keeps the shut state the sticky one without making it absorbing.
    ///
    ///      The owner is read from the pool rather than stored, because the handler is not told who
    ///      it is - and reading it keeps this correct if the fixture ever hands ownership on.
    function togglePause(uint256 seed) external watched {
        bool shut = pool.paused();
        address owner_ = pool.owner();
        if (shut && seed % 3 != 0) return;

        vm.prank(owner_);
        if (shut) {
            pool.unpause();
            ++unpausesDone;
        } else {
            pool.pause();
            ++pausesDone;
        }
    }

    /// @notice A loss taken and handed straight back, in one frame. Audit round 24.
    ///
    /// @dev **The action the campaign needed to reach `_renormaliseUnits` at all, and without it
    ///      the renormalisation shipped by round 23 had no fuzz coverage whatever.** The ceiling
    ///      binds on `totalPrincipalUnits / netDeposits`, the price of admission. Deposits alone
    ///      cannot move that quotient - they issue at it - so nothing this handler could do in a
    ///      single frame ever crossed a ceiling, at 2**128 or anywhere else. What moves it is a loss
    ///      that lowers the counter followed by a recovery that does not restore it, and the fuzzer
    ///      composing `lend`, `socialiseLoss` and `recoverLoss` in that order, repeatedly, at
    ///      compatible sizes, is not something 500 random calls does.
    ///
    ///      **Gentle rather than total, and the difference decides whether anything is observable.**
    ///      Crushing the counter to one asset-wei multiplies the aggregate by about 1e10 on the next
    ///      deposit and the renormalisation that follows shifts thirty-odd bits at once - every stale
    ///      figure floors straight to zero, having lost far less than one post-shift unit each, so
    ///      the integer drift is exactly zero and the bounds are back to being measured at drift
    ///      zero by another route. Taking a fraction and refilling multiplies the aggregate by that
    ///      fraction instead, which crosses in a shift of a few bits and leaves stale figures
    ///      holding real numbers. `LenderPoolPrincipalRescaling.t.sol`'s `_gentleCrushCycle` is the
    ///      deterministic sibling and records the same measurement.
    ///
    ///      Every call is guarded or wrapped: `invariant_theHandlerNeverDropsAFrame` runs this
    ///      handler with `fail-on-revert = true`, so a frame that dies here is a fixture fault.
    ///      The ghosts the other actions maintain are incremented from here too - `lendsDone`,
    ///      `lossesSocialised`, `lossRecoveriesDone`, `timeAdvances` - because `_settle` excuses a
    ///      price fall on `lossesSocialised` moving and a principal rise on `lendsDone` moving, and
    ///      an action that did those things without saying so would fire two invariants that are
    ///      correct.
    function crushLossAndRecoverIt(uint256 seed) external watched {
        uint256 assets = pool.totalAssets();
        if (assets == 0) return;

        // A fraction of the book, never all of it. Taking the last asset-wei empties the pool, the
        // clamp in `_reduceNetDeposits` fires on merit, the generation rolls and the quotient goes
        // back to one - which is the state that has to stay reachable but must not be the only one.
        uint256 target = assets - assets / bound(seed, 2, 16);
        uint256 crushed;

        for (uint256 i = 0; i < 8 && crushed < target; i++) {
            uint256 lendable = pool.available();
            if (lendable != 0) {
                vm.prank(creditManager);
                try pool.lend(lendable) {
                    ++lendsDone;
                } catch {}
            }

            uint256 exposure = pool.outstandingPrincipal();
            if (exposure == 0) break;
            uint256 take = exposure < target - crushed ? exposure : target - crushed;
            if (take == 0) break;

            vm.prank(creditManager);
            pool.socialiseLoss(take);
            crushed += take;
            ++lossesSocialised;
        }

        if (crushed == 0) return;

        _mint(creditManager, crushed);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), crushed);
        pool.recoverLoss(crushed);
        vm.stopPrank();
        ++lossRecoveriesDone;

        // The recovery is rated as a stream, so it has to be allowed to finish or it never reaches
        // the book and the refill that crosses the ceiling is issued against money still in the pot.
        skip(Config.YIELD_STREAM_DURATION + 1);
        ++timeAdvances;
        ++crushAndRecoverCycles;
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

    /// @dev Each live request owns an exact slice of the pool's escrowed principal units, so
    ///      every escrowed unit must have exactly one queue entry behind it.
    ///
    ///      **This used to justify itself with "the handler never transfers shares straight to the
    ///      pool", which made it a fact about the fixture rather than about the contract** - and
    ///      round-23 finding 16 was exactly the transfer the fixture declined to make. Since that
    ///      fix the four doors into escrow that are not `requestWithdrawal` all revert, and
    ///      `attemptDonationToTheEscrow` drives them from inside the sequence, so the equality is
    ///      now enforced by the contract and exercised by the fuzzer.
    ///
    ///      **Round 23 turned that equality into a bounded inequality** and the bound is the number
    ///      of live entries, so both figures come back from one walk: the queue is walked on every
    ///      invariant evaluation of every campaign and a second pass for the count would double it.
    function sumLiveQueuePrincipalUnits() external view returns (uint256 sum, uint256 liveEntries) {
        return _liveQueueUnits();
    }

    /// @dev The same walk, reachable from inside the handler. `_recordRenormalisation` needs it and
    ///      an external self-call to reach a `public` view would spend any prank left standing.
    function _liveQueueUnits() private view returns (uint256 sum, uint256 liveEntries) {
        uint256 length = pool.queueLength();
        for (uint256 i = 0; i < length; i++) {
            sum += pool.queueEntryPrincipalUnits(i);
            (,, uint256 shares) = pool.queueEntry(i);
            if (shares != 0) ++liveEntries;
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
        pool = _deployPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(epochHarvester);
        vm.stopPrank();

        handler = new LenderHandler(pool, usdc, creditManager, epochHarvester);
        targetContract(address(handler));

        PRICE_PROBE = handler.PRICE_PROBE_SHARES();
    }

    /// @dev The one seam in this fixture, and it exists so the whole campaign can be run a second
    ///      time against a renormalisation ceiling a fuzzer can actually reach. See
    ///      `LenderPoolInvariantsAtALoweredCeiling` at the bottom of this file, and `LowCeilingPool`
    ///      in `LenderPoolPrincipalRescaling.t.sol` for why the seam is a ceiling override and
    ///      nothing else.
    function _deployPool(IERC20 usdc_, address admin) internal virtual returns (LenderPool) {
        return new LenderPool(usdc_, admin);
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
    ///
    ///      **`virtual` since audit round 24, and a subclass MUST re-declare it. MEASURED.** Forge
    ///      attaches an inline `forge-config` to the *declaration*, not to the inherited symbol, so
    ///      the line above does not follow this function into a child contract. With `donate`
    ///      neutered to revert unconditionally, this contract failed on the first frame and
    ///      `LenderPoolInvariantsAtALoweredCeiling` - inheriting the guard and nothing else -
    ///      reported **PASS over 181 dropped frames**. An empty body whose entire assertion is one
    ///      comment is exactly the shape that fails silently when that comment is not applied, and
    ///      nothing in the run says so: the guard still prints, still passes, and still counts.
    ///      The repository's documentation check refuses a subclass that inherits it without
    ///      re-declaring.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view virtual {}

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
    ///
    /// @dev **`sumClaimable` walks the actors only, so since audit round 24 put the pool into the
    ///      receiver draw the first line here is a second, independent detector for the fifth
    ///      escrow door** - a payout set aside for `address(pool)` lands in the counter and in no
    ///      actor's balance. It was already written this way and it was already true; what changed
    ///      is that the fixture can now offer it a violation. The direct statement is the invariant
    ///      immediately below.
    /// @notice A pool shut to entry advertises no room to enter, and never reverts saying so.
    /// @dev 🟥 **The ERC-4626 half of round-28 item 10, asserted over the walk.** EIP-4626 requires
    ///      `maxDeposit` to return zero when deposits are disabled *including temporarily*, and
    ///      forbids it from reverting under any condition - which is why the pause is expressed as
    ///      a zero cap here and as a revert only on `deposit` and `mint`. Being a `view` that the
    ///      runner calls on every step, this fires on both halves: a non-zero cap fails the
    ///      assertion, and a `maxDeposit` that learned to revert kills the invariant call outright.
    function invariant_aPausedPoolAdvertisesNoRoomToEnter() public view {
        if (!pool.paused()) return;
        assertEq(pool.maxDeposit(address(this)), 0, "a paused pool advertised room to deposit");
        assertEq(pool.maxMint(address(this)), 0, "a paused pool advertised room to mint");
    }

    /// @notice The pause shuts entry and nothing else. Every exit maximum is what it would be with
    ///         the door open.
    /// @dev **The premise the guardian's reach rests on, as an invariant rather than as a sentence.**
    ///      Audit round 27 refused a guardian-reachable pause next door because that one shut the
    ///      borrower's cure; this one is only defensible while the exits stay open, so the claim is
    ///      checked on every step of the walk rather than left to the unit tests. The right-hand
    ///      side deliberately restates `maxRedeem`'s own formula, which reads nothing about the
    ///      pause: the day somebody adds `if (paused()) return 0;` to an exit view, the two sides
    ///      part company and this fires.
    function invariant_aPausedPoolStillAdvertisesEveryExit() public view {
        if (!pool.paused()) return;
        uint256 idleShares = pool.convertToShares(pool.unreservedIdle());
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 held = pool.balanceOf(handler.actors(i));
            assertEq(
                pool.maxRedeem(handler.actors(i)),
                held < idleShares ? held : idleShares,
                "the pause moved an exit maximum"
            );
        }
    }

    function invariant_setAsideMoneyIsAlwaysCovered() public view {
        assertEq(pool.totalClaimable(), handler.sumClaimable(), "the claimable counter drifted");
        assertLe(pool.totalClaimable(), usdc.balanceOf(address(pool)), "owes more than it holds");
    }

    /// @notice The escrow is never a payee. Audit round 24: the fifth escrow door.
    /// @dev `requestWithdrawal` is the only writer of `WithdrawalRequest.receiver` and therefore
    ///      the only route by which this contract's address can reach `claimable`. With that door
    ///      shut the balance is not merely bounded, it is zero - so this is written as an equality
    ///      rather than as a bound, and the handler offers the fuzzer the violation on every draw.
    ///
    ///      Both halves, because they fail in different worlds. The counter catches a door that
    ///      opens; the ghost catches a door that opens **and** is never serviced, which is the
    ///      state a shorter random sequence reaches first.
    function invariant_theEscrowIsNeverItsOwnPayee() public view {
        assertEq(
            handler.escrowReceiverRequestsAccepted(), 0, "a queue entry was allowed to name the escrow as receiver"
        );
        assertEq(pool.claimable(address(pool)), 0, "the pool set its own balance aside as owed to itself");
    }

    /// @notice The escrow is never an exit's payee either. Audit round 25 finding 1: the four
    ///         ERC-4626 doors one field along from the fifth.
    /// @dev **The counter, and a standing ghost that does not depend on the counter.** An exit
    ///      naming this address burns shares and moves no USDC, so the damage is a share-price
    ///      step and not a balance the pool can be asked about afterwards - there is no
    ///      `claimable(address(pool))` equivalent to read back. What there is, is the escrow's own
    ///      share balance: with `requestWithdrawal` the only route in, every share this contract
    ///      holds belongs to a live queue entry, and an exit accepted at any of the four doors
    ///      would burn shares the queue still claims.
    ///
    ///      Written as an equality against the live entries rather than as a bound, for the reason
    ///      round-23 finding 16 gives: refusing rather than tolerating is what buys a detector
    ///      sharp enough to state as `==`.
    function invariant_theEscrowIsNeverAnExitPayee() public view {
        assertEq(handler.escrowExitReceiversAccepted(), 0, "an exit door paid out to the escrow");
        assertEq(
            pool.balanceOf(address(pool)),
            pool.queuedShares(),
            "the escrow holds a share count the queue does not account for"
        );
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
        uint256 total = pool.totalPrincipalUnits();

        // **Two of these were equalities until round 23 and are now bounded inequalities, and the
        // relaxation is the price of the finding-7 fix.** `_renormaliseUnits` divides the whole
        // ledger by a power of two by moving the exponent it is read against, and each stored
        // figure floors independently at the moment it is next read - so `sum(floor) <= floor(sum)`
        // and the aggregate over-counts. The bound is derived rather than slack: at most one unit
        // per figure that has been credited in the current generation, `holders - 1`, which
        // `LenderPoolPrincipalRescaling.t.sol` proves tight by neutering it to `holders - 2`.
        // Written here as `holders` rather than `holders - 1` on purpose: the handler's count is
        // itself an approximation of "ever credited this generation", so the campaign carries one
        // unit of slack and the deterministic file carries the tight form. A campaign is
        // corroboration; the tight bound is asserted where it can be neutered.
        //
        // The direction is the one that matters and it is not free: the aggregate **over**-counts,
        // so no holder's units can exceed it and no burn can underflow it.
        //
        // **What this costs, on the record: round-23 finding 16's detector is one of these two
        // lines.** An escrow donation shows up as `escrow units > sum of live request units`, which
        // is exactly the signature a lazy shift now introduces as legitimate noise. It is still a
        // detector because the bound is small and derived, and because finding 16's fix closed the
        // four doors into escrow that are not `requestWithdrawal` - so the only way to exceed the
        // bound is the bug. It would not be a detector against a slack constant.
        // **Audit round 24: the escrow bound below was FALSE and no campaign could see it.** It was
        // written against the entries that are live *now*, and the escrow's residue does not belong
        // to them. The escrow's figure is floored once, as a sum; each entry floors independently;
        // so a shift leaves `floor(sum(r_i) + D) - sum(floor(r_i))` behind, and every entry can then
        // leave carrying exactly its own read while that difference stays with an address that has
        // no shares and no entry. MEASURED deterministically in
        // `LenderPoolPrincipalRescaling.t.sol`: after both entries cancel, `balanceOf(pool) == 0`,
        // `queuedShares == 0` and `principalUnits(pool) == 1`. Written against the live count that
        // reads `1 <= 0`.
        //
        // The bound that is true is `H - 1`, with `H` the largest number of entries that were live
        // when a shift fired - the same induction the holder bound above uses, one level in. With
        // `D` the residue before a shift of `k`, `h` the entries live at it and `r_i` their reads,
        // `D' = floor((sum(r_i) + D) / 2**k) - sum(floor(r_i / 2**k)) <= floor((D + h*(2**k - 1)) / 2**k)`,
        // which is `h - 1` whenever `D <= h - 1`; `D` starts at zero, so it is inductive, and a
        // shift with fewer entries live can only shrink it. Entries arriving and leaving between
        // shifts move `D` by nothing at all: `_requestWithdrawal` credits the escrow exactly what it
        // writes on the entry, and cancel, dust release and both fill branches debit exactly what
        // they read off it.
        //
        // `H` therefore has to be a historical maximum rather than today's count, and the handler
        // records it at the shift itself. Nothing looser is being smuggled in: at `H == 0` this is
        // an equality with zero, and the deterministic sibling neuters it at `H - 2` and goes red.
        (uint256 queueUnits,) = handler.sumLiveQueuePrincipalUnits();
        uint256 escrow = pool.principalUnits(address(pool));
        uint256 entriesAtAShift = handler.maxLiveEntriesAtAShift();

        assertLe(units, total, "principal units escaped the known holders");
        assertLe(total - units, handler.creditedHolderCount(), "the unit aggregate drifted beyond its bound");
        assertLe(queueUnits, escrow, "queue requests claim more escrowed principal than the escrow holds");
        assertLe(
            escrow - queueUnits,
            entriesAtAShift == 0 ? 0 : entriesAtAShift - 1,
            "escrowed principal units drifted beyond the flooring residue a shift can leave"
        );
        assertFalse(handler.hasPrincipalUnitsOnEmptyQueueEntry(), "an empty queue entry retained principal units");
        assertEq(total == 0, net == 0, "principal units and admitted principal disagree on emptiness");
        assertLe(net, total, "admitted principal rose above its accounting units");
        assertGe(basis, net, "holder bases do not reconstruct admitted principal");
        assertLe(basis - net, handler.actorCount(), "holder-basis rounding exceeded one unit per boundary");
        assertLt(total, pool.principalUnitCeiling(), "the unit aggregate was left above its ceiling");
    }

    /// @notice A holder with no vault shares cannot retain principal-accounting units, and an empty
    ///         escrow keeps at most the flooring residue a renormalisation can leave.
    ///
    /// @dev **The actor half is an equality and the escrow half cannot be, and audit round 24 found
    ///      the second one shipped as an equality anyway.** An actor exits through `_update`'s
    ///      proportional branch, which writes `heldUnits - movedUnits` and takes `movedUnits ==
    ///      heldUnits` on a full balance, so an emptied actor is exactly zero. The escrow exits
    ///      through `_transferWithExactPrincipalUnits` and `_burnWithExactPrincipalUnits`, which
    ///      move the figure the *entry* carries rather than the figure the escrow holds - and after
    ///      a shift those two are not the same number, because the escrow's was floored as a sum and
    ///      the entries' were floored one by one. So the escrow can be left holding a residue with
    ///      no shares and no entry behind it, and that is not a defect in the contract: it is the
    ///      documented, bounded cost of lazy renormalisation, worth at most one asset-wei of cap
    ///      headroom per entry. See `invariant_principalUnitsConserveNetDeposits` for the induction
    ///      and `LenderPoolPrincipalRescaling.t.sol` for the executed trace.
    function invariant_noPrincipalUnitsOutliveShares() public view {
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actors(i);
            if (pool.balanceOf(actor) == 0) {
                assertEq(pool.principalUnits(actor), 0, "an exited actor retained principal units");
            }
        }

        if (pool.balanceOf(address(pool)) == 0) {
            uint256 entriesAtAShift = handler.maxLiveEntriesAtAShift();
            assertLe(
                pool.principalUnits(address(pool)),
                entriesAtAShift == 0 ? 0 : entriesAtAShift - 1,
                "empty queue escrow retained more than a shift's flooring residue"
            );
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

    /// @notice A partial fill never burns more shares than the cash it pays out can buy back.
    /// @dev **The branch was reached and nothing looked inside it.** Audit round 25, finding 2:
    ///      flipping `serviceQueue`'s partial-fill `_exitToShares(idle, Floor)` to `Ceil` stayed
    ///      green across all 58 invariant evaluations in this file and all 900 deterministic tests
    ///      in the repo - zero detection in a 993-test suite - while `partialFills` had been
    ///      counting the branch since it was written. Counting a branch is not a statement about
    ///      what the branch does.
    ///
    ///      The predicate is `sharesBurned * (exitAssets() + 1) <= idle * (totalSupply() + 10**3)`,
    ///      on state read before the call, restated in `_recordPartialFill` rather than asked of
    ///      the pool. In words: the pool may not retire a share slice worth more, at the price it
    ///      is paying at, than the cash it actually hands over. Rounding the conversion up is
    ///      exactly the way to break it, which is what the contract's own comment says and what
    ///      nothing was checking.
    ///
    ///      **What would have to be true for this to pass without measuring anything**: every
    ///      partial fill in the campaign landing on an exact division, where Floor and Ceil are the
    ///      same number and the counter cannot rise. That is a real state, not a hypothetical -
    ///      `LenderPool.t.sol::test_theRoundNumberFixtureCannotSeeThePartialFillRounding` pins a
    ///      fixture where it holds. `test_handlerCanReachEveryStateTheInvariantsCheck` therefore
    ///      asserts `partialFillsWithInexactShareRounding`, not `partialFills`.
    function invariant_aPartialFillNeverBurnsMoreThanItsCashCovers() public view {
        assertEq(
            handler.partialFillsBurningMoreThanTheCashCovers(),
            0,
            "a partial fill burned a bigger share slice than its idle cash converts to"
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

        handler.mintShares(2, 2, 1_000e9);
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
        handler.mintShares(3, 3, 1e9);
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
        handler.withdrawMax(0, 0, 0);
        handler.redeemMax(1, 1, 0);
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
        // **Reaching the branch was never the whole problem.** Where `idle * s` divides `a`
        // exactly, Floor and Ceil are one number and
        // `invariant_aPartialFillNeverBurnsMoreThanItsCashCovers` is structurally incapable of
        // failing. This driver has reached the branch since the day it was written and the
        // Floor -> Ceil mutation survived it anyway. So the assertion is on the denominator.
        assertGt(
            handler.partialFillsWithInexactShareRounding(),
            0,
            "the partial fill this driver builds rounds exactly, so nothing here can see the rounding"
        );
        // `_recordPartialFill` writes the decimals offset out as `10 ** 3` rather than asking the
        // pool for it, which is deliberate and is only safe while the offset is what it says. A
        // change there would make the ghost mis-predict silently in whichever direction, so it goes
        // red here instead.
        assertEq(pool.decimals(), 9, "the decimals offset moved, so `_recordPartialFill`'s 10**3 is stale");
        assertEq(
            handler.partialFillsBurningMoreThanTheCashCovers(),
            0,
            "the driven partial fill burned more shares than its cash converts to"
        );

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

        // **Round-23 finding 16, and its denominator.** All three doors, on the same actor, in one
        // block: a refusal that stopped being reachable would otherwise look identical to a
        // refusal that never fires. Actor 3 holds the shares actor 2 just handed over.
        handler.attemptDonationToTheEscrow(3, 1e9, 0);
        handler.attemptDonationToTheEscrow(3, 1e6, 1);
        handler.attemptDonationToTheEscrow(3, 1e9, 2);
        assertEq(handler.escrowDonationsRefused(), 3, "all three escrow doors must refuse and be reachable");
        assertEq(handler.escrowDonationsAccepted(), 0, "an escrow door accepted a share");

        // **The fifth door, and its denominator.** `receiverSeed` 4 is the escrow: the draw is
        // `seed % (actors.length + 1)` and there are four actors. Actor 3 holds shares and is not
        // queued here, so this reaches the contract's guard rather than the handler's own bail-out
        // or the duplicate-request refusal - a refusal for the wrong reason would read as this
        // guard working, which is the failure the selector split in the action exists to stop.
        assertGt(pool.balanceOf(handler.actors(3)), 0, "the fifth-door probe needs shares to offer");
        handler.requestWithdrawal(3, 4, 1e9);
        assertGt(
            handler.escrowReceiverRequestsRefused(), 0, "naming the escrow as receiver must be refused and reachable"
        );
        assertEq(handler.escrowReceiverRequestsAccepted(), 0, "a queue entry named the escrow as its receiver");
        assertEq(pool.claimable(address(pool)), 0, "the escrow was booked as its own payee");

        // **And the four exit doors, audit round 25 finding 1, with their denominator.** Same seed
        // convention as the fifth door above: receiver seed 4 is the escrow. Both doors are driven
        // on each side because the round-20 bounded overloads carry no guard of their own - they
        // are shut only by delegating to the three-argument pair, so a refusal at one door is not
        // evidence about the other, and a refactor that gave an overload its own body would leave
        // this line green while reopening the door.
        //
        // The exit counters are read as a delta rather than absolutely, because a refusal that was
        // miscounted as a completed exit would otherwise be invisible: the campaign's own
        // `withdrawsDone`/`redeemsDone` are what several reachability assertions above stand on.
        assertGt(pool.maxWithdraw(handler.actors(3)), 0, "the exit-door probe needs something to take");
        assertGt(pool.maxRedeem(handler.actors(3)), 0, "the exit-door probe needs shares to burn");
        uint256 exitsCountedBefore = handler.withdrawsDone() + handler.redeemsDone();
        handler.withdrawMax(3, 4, 0);
        handler.withdrawMax(3, 4, 1);
        handler.redeemMax(3, 4, 0);
        handler.redeemMax(3, 4, 1);
        assertEq(
            handler.escrowExitReceiversRefused(), 4, "all four exit doors must refuse the escrow and be reachable"
        );
        assertEq(handler.escrowExitReceiversAccepted(), 0, "an exit door paid out to the escrow");
        assertEq(
            handler.withdrawsDone() + handler.redeemsDone(),
            exitsCountedBefore,
            "a refused exit was counted as a completed one"
        );

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
        handler.withdrawMax(3, 3, 0);
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

        // ── the entry pause (round-28 items 6 and 10) ────────────────────────
        //
        // Placed here rather than at the top because everything above has built a book with
        // lenders in it and money to pay them. A pause thrown on an empty pool would count the
        // switch and say nothing about what the invariants see on the far side of it, which is the
        // whole reason this action exists.
        handler.togglePause(0);
        assertGt(handler.pausesDone(), 0, "the entry pause was never reachable");
        assertTrue(pool.paused(), "fixture: the pool must actually be shut here");

        // The entry doors refuse, and they refuse by naming the pause: the handler's catch arms
        // still assert the cap selector on anything else, so a shut pool that reported itself full
        // would fail here rather than be counted.
        handler.deposit(0, 0, 1_000e6);
        handler.mintShares(0, 0, 1_000e9);
        assertGt(handler.entriesRefusedByThePause(), 0, "a shut door never refused an entry");
        invariant_aPausedPoolAdvertisesNoRoomToEnter();

        // And the exits stay open, which is the premise the guardian's reach rests on. Called as a
        // function first, so the claim is checked against a state this test built deliberately
        // rather than only against whatever the random walk happens to reach.
        invariant_aPausedPoolStillAdvertisesEveryExit();
        assertGt(pool.maxRedeem(handler.actors(0)), 0, "fixture: an actor must have an exit to take");
        handler.redeemMax(0, 0, 0);
        assertGt(handler.exitsWhilePaused(), 0, "no exit was taken while the pool was shut");

        // Reopened, because a switch that only goes one way would leave every invariant above this
        // point evaluated in one state for the rest of the run. Seed 0 takes the reopen branch.
        handler.togglePause(0);
        assertGt(handler.unpausesDone(), 0, "the pool could not be reopened");
        assertFalse(pool.paused(), "the pool stayed shut");

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

        // **The denominator under the action audit round 24 added.** It is last because it warps a
        // full stream duration and rewrites the book, and everything above wants the fixture it
        // built.
        //
        // What is asserted here is that the action completes and absorbs something. That the cycle
        // *raises the price of admission* is deliberately not asserted at this point in the
        // sequence, and the reason is worth keeping: by here the book carries far more yield than
        // the counter admits, so the yield-first loss debit covers the whole loss and `netDeposits`
        // does not move at all. MEASURED, the quotient after one cycle here is exactly the quotient
        // before it. The claim belongs where the mechanism is actually driven, which is
        // `LenderPoolInvariantsAtALoweredCeiling.test_theCampaignActuallyRenormalisesAndCanStrandTheEscrow`.
        uint256 lossesBeforeTheCycle = handler.lossesSocialised();
        handler.crushLossAndRecoverIt(16);
        assertGt(handler.crushAndRecoverCycles(), 0, "the crush-and-recover cycle was never completed");
        assertGt(handler.lossesSocialised(), lossesBeforeTheCycle, "the cycle absorbed nothing");
        assertGt(handler.lossRecoveriesDone(), 0, "the cycle recovered nothing");

        // **The denominator under `lendTheWholeFloat`, which the campaign's partial-fill widening
        // rests on.** A ghost nothing reads is coverage that is not there, and
        // the repository's documentation check refuses one outright. Last in the sequence because it
        // empties the lendable book and nothing above should be run against that.
        assertGt(pool.available(), 0, "the fixture must have something left to lend to the wei");
        handler.lendTheWholeFloat();
        assertGt(handler.floatEmptyingLends(), 0, "lending the float to the wei was never reachable");
        assertEq(pool.available(), 0, "lending the whole float left something lendable behind");
    }

    /// @notice The handler's credited-holder count must fall back to zero when a generation roll
    ///         clears the ledger it is counting.
    ///
    /// @dev **This exists because the reset was unreachable and no campaign could say so.** Audit
    ///      round 25 measured `creditedHolderCount` at **5** after a full unwind leaving
    ///      `totalPrincipalUnits == 0`: the saturation early return sat above the roll check, so
    ///      once every actor and the escrow had held anything the counter was pinned for the rest
    ///      of the run. The bound it feeds -
    ///      `invariant_principalUnitsConserveNetDeposits`'s `total - units <= creditedHolderCount` -
    ///      then degraded to a slack constant of 5, which is the exact failure the comment above
    ///      `_recordCreditedHolders` argues against, and the deterministic sibling in
    ///      `LenderPoolPrincipalRescaling.t.sol` has no early return and does reset, so the two
    ///      copies of one quantity disagreed.
    ///
    ///      Deterministic rather than asserted over the walk, for the reason the tripwire above
    ///      gives: the direction of the defect is loosening only, so a random campaign cannot fail
    ///      on it however long it runs. Neutering it is one line - move the early return back above
    ///      the roll check and this reads 5 against 0.
    function test_aGenerationRollClearsTheCreditedHolderCount() public {
        handler.deposit(0, 0, 4_000e6);
        handler.deposit(1, 1, 3_000e6);
        handler.deposit(2, 2, 2_000e6);
        handler.deposit(3, 3, 1_000e6);

        // The escrow is the fifth holder and the only one that is not an actor: a queued request
        // moves shares to the pool's own address, which is what makes the count saturate.
        handler.requestWithdrawal(0, 0, type(uint256).max);
        assertEq(handler.requestsQueued(), 1, "the fixture needs a live request to credit the escrow");
        assertEq(
            handler.creditedHolderCount(),
            handler.actorCount() + 1,
            "premise: every actor and the escrow must have been credited"
        );

        // Unwind. Cancel first so the escrow gives its shares back, then take everything out; with
        // nothing lent, `maxWithdraw` is the whole holding at every actor.
        handler.cancelWithdrawal(0);
        // The three seeds are pinned rather than arbitrary, and the receiver one is load-bearing.
        // Round 26 widened `withdrawMax` to draw a receiver and a door, and `_receiverIncludingTheEscrow`
        // can return the pool itself; if it did so here the escrow would be credited again and the
        // count below could not reach zero. With four actors, `_actor(i)` is `actors[i % 4]` and
        // `_receiverIncludingTheEscrow(i)` is `actors[i % 5]`, so passing `i` twice makes every actor
        // pay itself. The door seed is even, which is the plain three-argument overload: this test is
        // about the counter rolling, not about which door rolls it.
        for (uint256 i = 0; i < 4; i++) {
            handler.withdrawMax(i, i, 0);
        }

        assertEq(pool.totalPrincipalUnits(), 0, "premise: the unwind must actually roll the generation");
        assertEq(handler.creditedHolderCount(), 0, "a generation roll left the credited-holder count pinned");
    }
}

/// @notice **The same campaign, against a renormalisation ceiling a fuzzer can reach.**
///
/// @dev **Audit round 24: three shipped invariants in the file above were false, and no campaign
///      could see it, because the campaign was running at drift zero.** The suite constructs a plain
///      `LenderPool`, so `principalUnitCeiling()` is `2**128` in every run, and `unitExponent` was
///      measured at 0 at seeds `0x2408` and `0x1111` across 128,000 calls each. Every relaxed bound
///      round 23 introduced was therefore evaluated with the mechanism that forced the relaxation
///      switched off - the campaign would have passed identically with those `assertLe`s written as
///      the `assertEq`s they replaced, which is the definition of the thing not being tested. A
///      control using a generation-roll ghost went red on the same runs, which is how that was
///      established rather than assumed.
///
///      So the ceiling is lowered and everything else is left exactly as it was. `LowCeilingPool` is
///      the seam `LenderPoolPrincipalRescaling.t.sol` already carries for the deterministic half of
///      this mechanism, reused rather than rebuilt: overriding `principalUnitCeiling()` and nothing
///      else, with `test_thePrincipalUnitCeilingIsTheShippedValue` over there pinning what the real
///      pool uses. Every invariant, ghost and reachability assertion in the contract above is
///      inherited unchanged, which is the point - this is not a second suite with its own bounds, it
///      is the same claims evaluated where the arithmetic they are about actually happens.
///
///      Both campaigns are kept. The shipped-ceiling run is the production regime and it is the one
///      that would notice a change making the ceiling reachable in ordinary operation; this one is
///      the only place the relaxed bounds are anything but assertions about zero.
///
///      **It runs at 64 rather than 256, and the number is measured rather than picked.** MEASURED
///      standalone, which is the only footing on which any two of these figures are comparable: the
///      shipped-ceiling campaign is 228.58s before `crushLossAndRecoverIt` and 262.78s after, so the
///      new action costs **34s**, and this campaign is **60.4s at 64 runs**. Whole-suite wall clock
///      went 25m59s at 256 to 22m57s at 64.
///
///      **A suite's "finished in" inside a parallel `forge test` measures how long it waited as much
///      as how long it ran, so it is not a cost.** This contract reported 1,555.77s in the full run
///      and 60.4s on its own, against 3,185s of its own CPU - it is simply the last suite scheduled.
///      An earlier draft of this paragraph put the 1,555.77s beside the *standalone* 262.78s and
///      concluded the campaign was six times the cost of its parent. It is not; the two numbers were
///      never measured the same way. Compare standalone with standalone, or whole-suite with
///      whole-suite, and never one of each.
///
///      At 64 this still walks 32,000 calls per invariant, the shipped-ceiling campaign keeps the
///      full 256 over the production regime, and the tight claims are asserted deterministically by
///      the reach test below rather than left to the random walk. Cutting the *other* campaign would
///      have been the wrong lever: that one is the regime the protocol actually ships in.
/// forge-config: default.invariant.runs = 64
contract LenderPoolInvariantsAtALoweredCeiling is LenderPoolInvariants {
    function _deployPool(IERC20 usdc_, address admin) internal override returns (LenderPool) {
        return new LowCeilingPool(usdc_, admin);
    }

    /// @notice Re-declared, and it has to be. See the parent's copy for the measurement.
    /// @dev Forge attaches inline config to a declaration, not to an inherited symbol. Inheriting
    ///      this guard without re-declaring it gives a frame guard that runs under the global
    ///      `fail_on_revert = false` and passes over every dropped frame - MEASURED at 181 of them
    ///      in this contract while the parent failed on the first. The documentation check
    ///      refuses the omission, because nothing in a run reports it.
    ///
    ///      **`virtual override`, and the `virtual` half is not decoration.** Audit round 25 found
    ///      this declaration was `override` alone, which makes the detector's own prescribed repair
    ///      impossible for the next subclass: a third suite re-declaring this guard does not compile
    ///      at all (`Error (4334): Trying to override non-virtual function`), so the check would
    ///      demand a line that cannot be written. The re-declaration recurs every time a subclassed
    ///      campaign is added - that is #279's own conclusion - so the chain has to stay open, and
    ///      now refuses a non-virtual override for the same reason it
    ///      refuses a missing one.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view virtual override {}

    /// @notice The seam is the ceiling and nothing else.
    function test_theCampaignRunsAgainstALoweredCeiling() public view {
        assertEq(pool.principalUnitCeiling(), 1 << 40, "the harness ceiling moved");
        assertLt(pool.principalUnitCeiling(), 1 << 128, "this campaign must not be at the shipped ceiling");
    }

    /// @notice **The reach check for the whole point of this contract, and without it the campaign
    ///         above is the same vacuity in a second costume.**
    ///
    /// @dev Deterministic rather than a floor asserted over the random walk, for the reason the
    ///      parent's tripwire gives: a per-run reachability assertion fails on the first unlucky
    ///      sequence. What this proves is that the *handler's own actions* can reach a
    ///      renormalisation here - not a bare `vm` poke the fuzzer has no equivalent of - so the
    ///      random campaign is drawing from a space that contains one.
    ///
    ///      Two lenders queue before the cycles start, because the escrow residue only exists when
    ///      the escrow's figure is a sum of more than one entry: floored once as a sum against each
    ///      entry floored on its own. With a single entry the two are the same number and the bound
    ///      being fixed here would read zero however many shifts fired.
    function test_theCampaignActuallyRenormalisesAndCanStrandTheEscrow() public {
        handler.deposit(0, 0, 9_000e6);
        handler.deposit(1, 1, 5_000e6);
        handler.deposit(2, 2, 3_000e6);

        // Receiver seeds 1 and 2 are actors, not the escrow - the fifth door is the parent's
        // business and a refused request would leave nothing queued for the residue to form in.
        handler.requestWithdrawal(1, 1, type(uint256).max);
        handler.requestWithdrawal(2, 2, type(uint256).max);
        assertEq(handler.requestsQueued(), 2, "the fixture needs two entries floored independently");

        // Re-queued on every pass on purpose. A stale entry loses a bit of resolution at every
        // shift and never regains it, so after three or four cycles both entries read zero and the
        // residue can no longer form from them - which is the same "the shift size decides what is
        // observable" trap `_gentleCrushCycle` was written for, arriving through the clock instead
        // of through the size.
        uint256 unitsBeforeTheCycles = pool.totalPrincipalUnits();
        uint256 netBeforeTheCycles = pool.netDeposits();
        for (uint256 i = 0; i < 24 && handler.maxEscrowResidueObserved() == 0; i++) {
            handler.cancelWithdrawal(1);
            handler.cancelWithdrawal(2);
            handler.requestWithdrawal(1, 1, type(uint256).max);
            handler.requestWithdrawal(2, 2, type(uint256).max);
            handler.crushLossAndRecoverIt(16);
            handler.deposit(0, 0, 4_000e6);
        }

        assertGt(
            pool.totalPrincipalUnits() * netBeforeTheCycles,
            unitsBeforeTheCycles * pool.netDeposits(),
            "the cycles did not raise the price of admission, so nothing could ever reach the ceiling"
        );

        assertGt(handler.renormalisationsObserved(), 0, "the handler's own actions never renormalised");
        assertGt(pool.unitExponent(), 0, "the exponent never moved, so every bound was measured at drift zero");
        emit log_named_uint("MEASURED unitExponent reached by handler actions", pool.unitExponent());
        emit log_named_uint("MEASURED renormalisations", handler.renormalisationsObserved());
        emit log_named_uint("MEASURED live entries at a shift", handler.maxLiveEntriesAtAShift());
        emit log_named_uint("MEASURED escrow residue", handler.maxEscrowResidueObserved());
        emit log_named_uint("MEASURED issuances across a shift", handler.principalUnitIssuancesAcrossAShift());

        assertGt(
            handler.principalUnitIssuancesAcrossAShift(),
            0,
            "no entry was ever quoted across a shift, so the corrected issuance ghost is untested"
        );

        // **And the residue itself, which is the quantity the false bound could not see.** Zero
        // here would mean the escrow bound is still only ever evaluated at drift zero, by a longer
        // route. MEASURED in this trace: `unitExponent` 10 over seven renormalisations, two
        // entries live at a shift, and a residue of exactly 1 - the same figure round 24 measured
        // by hand.
        assertGt(handler.maxEscrowResidueObserved(), 0, "the escrow never carried a residue at all");
        assertLe(
            handler.maxEscrowResidueObserved(),
            handler.maxLiveEntriesAtAShift() - 1,
            "the residue exceeded one unit per entry boundary"
        );

        // The three corrected claims, evaluated here rather than only by the random walk, so the
        // state they were false in is reached by a sequence somebody can read.
        invariant_principalUnitIssuanceMatchesThePreEntryRatio();
        invariant_principalUnitsConserveNetDeposits();
        invariant_noPrincipalUnitsOutliveShares();

        // **And then drain the queue, which is the half that makes this a detector rather than a
        // measurement.** MEASURED: with both entries still standing, the pre-fix escrow bound reads
        // `1 <= 2` and passes, and the pre-fix `assertEq` sits behind a `balanceOf(pool) == 0` guard
        // it never reaches - so neither neuter goes red until the entries leave and the residue is
        // all that is left. That is the whole shape of the finding, a residue belonging to entries
        // which no longer exist, so the state has to be in the sequence rather than left to the walk.
        handler.cancelWithdrawal(1);
        handler.cancelWithdrawal(2);
        assertEq(pool.balanceOf(address(pool)), 0, "the escrow kept shares after both entries cancelled");
        assertEq(pool.queuedShares(), 0, "the queue did not drain");
        emit log_named_uint("MEASURED escrow units with no shares and no entry", pool.principalUnits(address(pool)));
        assertGt(pool.principalUnits(address(pool)), 0, "the residue did not survive the drain, so nothing is tested");

        invariant_principalUnitsConserveNetDeposits();
        invariant_noPrincipalUnitsOutliveShares();
    }
}
