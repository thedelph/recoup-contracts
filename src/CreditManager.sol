// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Config} from "./Config.sol";
import {LtvMath} from "./LtvMath.sol";
import {ICreditManager} from "./interfaces/ICreditManager.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILenderPool} from "./interfaces/ILenderPool.sol";
import {ILiquidationAuction} from "./interfaces/ILiquidationAuction.sol";
import {ILiquiditySource} from "./interfaces/ILiquiditySource.sol";
import {INAVOracle} from "./interfaces/INAVOracle.sol";

/// @title CreditManager (PRD §4.3)
/// @notice Debt accounting. No borrow interest in v1: lender return comes from the
///         yield split, not from borrowers. Debt is monotonically non-increasing
///         absent new borrow() calls (a core invariant, PRD §8).
/// @dev Solvency rests on one invariant, asserted in the invariant suite:
///
///          usdc.balanceOf(this) >= totalClaimable + undistributedYield
///                                  + pendingPrincipal + insuranceFund
///
///      Every USDC balance this contract holds is spoken for by one of those four.
///      Borrowed principal is never held here - it passes through in a single call.
contract CreditManager is ICreditManager, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotEpochHarvester();
    error NotVault();
    error ZeroAddress();
    error ZeroAmount();
    error RenounceDisabled();
    error NavStale();
    error CustodyInsolvent();
    error LiquiditySourceUnset();
    error ExceedsMaxLtv(uint256 ltvBps);
    error PerAccountCapExceeded(uint256 requested, uint256 cap);
    error GlobalCapExceeded(uint256 requested, uint256 cap);
    error NoDebt();
    error NothingToClaim();
    error NothingToSettle();
    error LiquidityNotDelivered(uint256 expected, uint256 received);
    error YieldNotDelivered(uint256 requested, uint256 undistributed);
    error DebtOutstanding(uint256 totalDebtNow);
    /// @dev Distinct from `DebtOutstanding` so an operator knows which clause of the swap guard
    ///      bit, and what to do about it: one waits for repayment, the other calls the flush.
    error LossOutstanding(uint256 unsocialisedLossNow);
    error LossNotThisPools(address liquiditySource, address lenderPool);
    /// @dev Distinct from `LossOutstanding` for the same reason that one is distinct from
    ///      `DebtOutstanding`: the two clauses of the `setLenderPool` guard need different actions
    ///      from an operator. One waits for the flush, the other waits for borrowers to repay.
    error PoolPrincipalOutstanding(address pool, uint256 outstanding);
    /// @notice The outgoing pool still carries per-borrower marks that only it can be told to clear.
    error PoolImpairmentOutstanding(address pool, uint256 marked);
    error Detached(address liveManager);
    error NotLiquidationAuction();
    error LiquidationAuctionUnset();
    error LenderPoolUnset();
    error PositionHealthy(uint256 ltvBps);
    error SocialisationRejected(uint256 amount);
    error AuctionHasLiveWork(uint256 outstanding);
    error AuctionPointerMismatch(address manager, address vault);
    error WorkoutOpen(address borrower);
    error LiquidationOpen(address borrower);
    error StillAttached();
    error LiquidationAuctionVaultMismatch(address auctionVault);
    /// @notice The incoming auction does not answer the whole interface the repayment path needs.
    error LiquidationAuctionIncomplete();
    /// @notice The incoming pool does not answer the enumeration the bounded impairment sweep needs.
    error LenderPoolIncomplete();

    event LiquiditySourceSet(address indexed source);
    event LenderPoolSet(address indexed lenderPool);
    event EpochHarvesterSet(address indexed epochHarvester);
    event LiquidationAuctionSet(address indexed liquidationAuction);
    event YieldReceived(uint256 amount);
    /// @param amount The epoch's newly delivered borrower share.
    /// @param ratePerSecond USDC per second the accumulator now streams at, re-rated
    ///        over the whole undistributed pot (so it includes any previous tail).
    /// @param streamEndsAt When that stream runs dry.
    event YieldDistributed(uint256 amount, uint256 ratePerSecond, uint256 streamEndsAt);
    /// @param amount USDC moved out of the undistributed pot into the accumulator.
    event YieldAccrued(uint256 amount, uint256 accYieldPerBond, uint256 totalBonds);
    /// @param amount Stream slice that elapsed with nothing staked, sent to insurance.
    event UnstakedSliceToInsurance(uint256 amount);
    event InsuranceFunded(address indexed from, uint256 amount);
    event PrincipalSettled(uint256 amount);
    event LiquidationProceedsCredited(address indexed borrower, uint256 toInsurance, uint256 toBorrower);
    /// @param fromInsurance The part the insurance fund made the liquidity source whole for.
    /// @param socialised The part it could not, which lenders bear.
    event LossWrittenDown(address indexed borrower, uint256 amount, uint256 fromInsurance, uint256 socialised);
    event LossSocialised(address indexed pool, uint256 amount);
    event LossDeferred(uint256 amount, uint256 totalDeferred);
    /// @notice A default whose principal the current lender pool did not fund. Nothing is deferred:
    ///         the source that lent the money bears it by not being repaid.
    /// @dev Emitted rather than silently returning, because "no counter moved" and "a loss
    ///      happened and landed where it should" are different facts and only one of them is
    ///      visible from storage.
    event LossBorneByTheSource(address indexed source, uint256 amount);
    event ReservesMigrated(address indexed to, uint256 amount);

    IERC20 public immutable usdc;
    ICollateralVault public immutable vault;
    INAVOracle public immutable navOracle;

    /// @notice Funds borrows and receives repaid principal. A treasury float in
    ///         Phase 2, the LenderPool from Phase 4 - same interface either way.
    address public liquiditySource;
    /// @notice Reserved for Phase 4 loss socialisation. Distinct from
    ///         `liquiditySource` on purpose: at Phase 4 both point at the LenderPool,
    ///         but they are different roles and only one of them funds borrows.
    address public lenderPool;
    address public epochHarvester;
    address public liquidationAuction;

    /// @inheritdoc ICreditManager
    mapping(address => uint256) public override debtOf;
    /// @notice Yield applied beyond debt, plus post-liquidation surplus, claimable in USDC.
    mapping(address => uint256) public claimableOf;
    /// @notice Sum of `claimableOf`. Tracked so solvency is checkable in one read.
    uint256 public totalClaimable;
    /// @inheritdoc ICreditManager
    uint256 public override totalDebt;
    /// @notice USDC delivered by the harvester but not yet allocated to borrowers.
    ///         `applyYield` can only ever hand out what has actually arrived.
    uint256 public undistributedYield;
    /// @notice Principal written down or repaid, owed back to the liquidity source
    ///         and awaiting `settlePrincipal()`.
    uint256 public pendingPrincipal;
    /// @notice USDC held here to absorb auction shortfalls first (PRD §4.4).
    uint256 public insuranceFund;
    /// @notice Losses recognised on the books that the lender pool has not accepted yet.
    /// @dev Public because a loss that cannot be placed must be *visible*. The alternative to this
    ///      counter is either a liquidation that cannot complete or a loss that is silently
    ///      dropped. Same shape as `EpochHarvester.pendingLenderYield`, adopted for the same
    ///      reason.
    ///
    ///      Audit round 10: for a while it was the silently-dropped option, and this comment was
    ///      still describing the protection. The counter only ever filled from a `catch`, and when
    ///      the pool gained a body it stopped reverting - it clamps a write-down to what it has
    ///      lent and accepts the call regardless. `_socialise` now reads the absorbed amount back
    ///      and keeps the difference here, so the counter fills on a partial acceptance and not
    ///      just on a refusal.
    uint256 public unsocialisedLoss;

    /// @notice Where the next bounded impairment sweep resumes: the index in the pool's impaired
    ///         set that `refreshImpairments` will step down from.
    /// @dev A hint, not a bookmark. The set swap-pops on release, so between calls this index can
    ///      come to name a different borrower or none at all - which is fine, because the property
    ///      the sweep owes is coverage of the whole set over successive calls, not exact
    ///      enumeration within one. Without it, a bounded call restarted at the tail every time and
    ///      the oldest mark was unreachable; see `refreshImpairments`.
    ///
    ///      Public so an operator can see where a sweep got to without replaying logs, which is the
    ///      same off-chain archaeology the sweep itself was built to remove.
    uint256 public impairmentCursor;

    /// @notice Cumulative yield accrued per bond, scaled by ACC_PRECISION.
    ///         Monotonically increasing; the whole distribution mechanism is the
    ///         difference between this and a position's recorded index.
    uint256 public accYieldPerBond;
    /// @notice The accumulator value each position last settled at.
    mapping(address => uint256) public yieldIndexOf;

    /// @notice USDC per second currently being streamed into the accumulator, scaled
    ///         by ACC_PRECISION.
    /// @dev Scaled because the stream runs for five days: a whole-wei rate would
    ///      truncate `pot / 432000` and strand the remainder every epoch - about 0.2%
    ///      of a 200 USDC epoch, which is not dust. At this scale the loss over a full
    ///      stream is at most 1 wei of USDC.
    uint256 public yieldRate;
    /// @notice When the current stream runs dry.
    uint256 public streamEndsAt;
    /// @notice Timestamp the accumulator was last brought up to date.
    uint256 public lastAccrualAt;
    /// @notice When a stream was last rated. Seeded at deploy so the first epoch
    ///         measures its accrual window from genesis rather than from zero.
    uint256 public lastDistributeAt;

    /// @dev Scaling for the accumulator. Yield is USDC (6dp) spread across whole bond
    ///      units, so per-bond amounts need headroom not to truncate away: at 100k
    ///      bonds, one USDC is 1e-5 per bond, which is 1e13 at this scale.
    uint256 internal constant ACC_PRECISION = 1e18;

    constructor(IERC20 usdc_, ICollateralVault vault_, INAVOracle navOracle_, address initialOwner)
        Ownable(initialOwner)
    {
        if (
            address(usdc_) == address(0) || address(vault_) == address(0)
                || address(navOracle_) == address(0)
        ) revert ZeroAddress();
        usdc = usdc_;
        vault = vault_;
        navOracle = navOracle_;
        // Seeded rather than left at zero so the first epoch is streamed over the time
        // that actually elapsed before it. The harvester is wired some way after the
        // vault goes live, so epoch one can represent months of accrual, and its
        // cooldown check is skipped entirely - the exact case a fixed window mishandles.
        lastDistributeAt = block.timestamp;
    }

    /// @dev Position accounting is only sound while this contract is the manager the
    ///      vault settles into.
    ///
    ///      `_settle` prices a position as `bonds x (accYieldPerBond - itsIndex)`,
    ///      reading `bonds` live from the vault. That is safe only because the vault
    ///      settles here before every bond-count change - and it stops being true the
    ///      moment `setCreditManager` points elsewhere, while this contract keeps
    ///      answering `settle`, `accrueYield` and `claimSurplus` permissionlessly and
    ///      keeps reading the vault's still-moving counts.
    ///
    ///      A detached manager is therefore drainable: any position depositing after
    ///      the swap has an index of zero against a non-zero historical accumulator,
    ///      and can claim its whole remaining balance, including the insurance fund
    ///      and other holders' unsettled entitlement. Refusing to price positions once
    ///      detached closes that at the source, which is better than lengthening the
    ///      vault's swap guard - the vault cannot enumerate what makes this contract
    ///      unsafe to leave running.
    ///
    ///      `claimableOf` payouts stay open deliberately: those balances were recorded
    ///      while attached and are already backed, so a migration must not strand them.
    modifier whileAttached() {
        address live = vault.creditManager();
        if (live != address(this)) revert Detached(live);
        _;
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Renouncing would permanently freeze wiring and the pause switch.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev Refuses to swap while any principal is outstanding. The old source would
    ///      never be repaid, and the incoming one would start accounting from money it
    ///      never lent - on a pool that decrements its own principal counter, the very
    ///      first repayment would underflow and brick repayment for every existing
    ///      borrower. Phase 4 therefore swaps at zero debt, or via an explicit
    ///      migration that seeds the pool's books first.
    ///
    ///      Also refuses while a recognised loss is still unplaced. Since round 11 that counter can
    ///      only hold loss the current pool itself funded, so this is always satisfiable - flush it
    ///      first - and it stops the one remaining way the old bearer instrument could re-form: a
    ///      backlog banked against one source and settled against the next.
    function setLiquiditySource(address liquiditySource_) external onlyOwner {
        if (liquiditySource_ == address(0)) revert ZeroAddress();
        if (totalDebt != 0 || pendingPrincipal != 0) revert DebtOutstanding(totalDebt);
        if (unsocialisedLoss != 0) revert LossOutstanding(unsocialisedLoss);
        liquiditySource = liquiditySource_;
        emit LiquiditySourceSet(liquiditySource_);
        _pushLossReserves();
    }

    /// @notice Repoint the balance sheet that bears socialised losses.
    /// @dev **Audit round 11: this had `onlyOwner` and nothing else, while both of its structural
    ///      siblings carried a live-state guard.** `setLiquiditySource` refuses while debt,
    ///      pending principal or an unplaced loss is outstanding, and `LenderPool.setCreditManager`
    ///      refuses while the pool has principal out. This setter decides where every future
    ///      default lands and was the one that would move under anything.
    ///
    ///      Two clauses, mirroring those two siblings.
    ///
    ///      **A backlog banked against the outgoing pool must not be settled against the incoming
    ///      one.** `unsocialisedLoss` records an amount and not whose principal funded it, and
    ///      `flushSocialisedLoss` is permissionless - which is the exact bearer instrument round
    ///      11's PoC monetised across a liquidity-source swap. `_socialise` closed the treasury
    ///      route by refusing to offer a loss to a pool that is not the source; this closes the
    ///      remaining route, which is to move the sink rather than the source.
    ///
    ///      **The deadlock question, asked out loud, because this repository has shipped two
    ///      mutually-unsatisfiable guards and `EpochHarvester.setLenderPool` spends twenty lines
    ///      on one of them.** The only drain for `unsocialisedLoss` is `flushSocialisedLoss`,
    ///      which itself refuses unless `lenderPool == liquiditySource` - so yes, the drain
    ///      requires the pointer this clause is refusing to move. That makes the clause necessary
    ///      rather than dangerous, and the reason is that the move it forbids never unlocked
    ///      anything: `setLiquiditySource` carries the identical clause, so a `lenderPool` repoint
    ///      made in that state leaves the protocol equally stuck, with the loss now *permanently*
    ///      unplaceable because `flushSocialisedLoss` would revert `LossNotThisPools` forever.
    ///      Nothing reachable becomes unreachable. The state where the counter cannot be drained
    ///      at all - a pool that refuses, or one whose `outstandingPrincipal` has already been
    ///      clamped to zero, so `socialiseLoss` absorbs nothing - is terminal for migration
    ///      whether or not this clause exists, because it already blocks the source leg.
    ///
    ///      **The second clause: the outgoing pool must not still be carrying principal.** Its
    ///      `outstandingPrincipal` is written down by exactly two things, `repayPrincipal` and
    ///      `socialiseLoss`, and once this pointer moves away only the first of them can still
    ///      reach it. A default on a loan the outgoing pool funded would then be reported as
    ///      `LossBorneByTheSource` and its `outstandingPrincipal` would never come down - so its
    ///      `totalAssets` would overstate the book forever and its lenders would exit at a price
    ///      that had stopped being true. Satisfiable by the ordinary wind-down: repayments reduce
    ///      it and `setLiquiditySource` already requires an empty book, so the intended migration
    ///      clears both counters before either pointer moves.
    ///
    ///      Read through `try`/`catch`, and failing open on purpose. An outgoing address that
    ///      cannot answer `outstandingPrincipal()` is not a pool with depositors to short-change,
    ///      and letting it brick the pointer permanently would be the deadlock shape again - this
    ///      time reached through a call to a contract that is not what it was assumed to be. The
    ///      guard protects against operator error, not against an owner who is already choosing
    ///      the addresses on both sides.
    function setLenderPool(address lenderPool_) external onlyOwner {
        if (lenderPool_ == address(0)) revert ZeroAddress();
        if (unsocialisedLoss != 0) revert LossOutstanding(unsocialisedLoss);

        address outgoing = lenderPool;
        if (outgoing != address(0) && outgoing != lenderPool_) {
            try ILenderPool(outgoing).outstandingPrincipal() returns (uint256 stillLent) {
                if (stillLent != 0) revert PoolPrincipalOutstanding(outgoing, stillLent);
            } catch {}

            // **The mirror of the outgoing pool's own refusal, and audit round 16 found it missing.**
            // `LenderPool.setCreditManager` will not change its manager while `totalImpairment` is
            // non-zero, with eighteen lines on why a stale per-borrower reserve is invisible at the
            // swap. This side checked the principal and the backlog and said nothing about the
            // mark, so the rule stood on one side of one pointer pair. Once this pointer moves,
            // `_setImpairment` targets the incoming pool, so nothing can clear the outgoing one's
            // map and the outgoing pool can never be repointed either.
            //
            // **`exitReserve()` cannot answer this**, which is why it needs a view of its own: it
            // clamps to `outstandingPrincipal`, and the clause immediately above has just required
            // that to be zero. The one impairment-shaped number already on the interface reads zero
            // in exactly the state that matters.
            //
            // **Not a mutually-unsatisfiable pair, unlike the backlog clause above it**, but audit
            // round 17 found the reason given here inverted and it is corrected rather than
            // quietly deleted. This used to say a mark's drains "depend on neither pointer". They
            // depend on this one: `refreshImpairment` and `refreshImpairments` both read
            // `lenderPool`, `_setImpairment` writes through it, and `LenderPool
            // .releaseImpairment` is gated on the pointer back - which the paragraph eleven lines
            // above says outright. What is actually true is narrower and is all the guard needs:
            // the drains work on the *outgoing* pool right up until this assignment, so the
            // refusal forbids nothing that was reachable before it, and clearing the mark first is
            // a step the owner can always take. That distinction is the one
            // `EpochHarvester.setLenderPool` spends twenty lines on, and it is worth checking
            // every time a guard like this is added.
            //
            // A separate `try` from the one above, because a `revert` inside a success body is not
            // caught by its own `catch`. Fails open on an address that cannot answer, for the
            // reason given at the head of this function.
            try ILenderPool(outgoing).totalImpairment() returns (uint256 marked) {
                if (marked != 0) revert PoolImpairmentOutstanding(outgoing, marked);
            } catch {}
        }

        // **The same rule as `setLiquidationAuction`, one pointer over.** Audit round 17, and the
        // reason it is a separate finding rather than the same one is that it was missed in the
        // same commit range that applied the rule next door: `refreshImpairments` calls
        // `impairedBorrowerCount` and `impairedBorrowerAt` bare, and both members arrived in the
        // round that built the walk.
        //
        // Lower stakes than the auction probe and deliberately so: the two drains reach this pool
        // through `_setImpairment`, which `try`s both legs, so a pool that cannot answer strands
        // the bulk sweep rather than bricking repayment. Worth refusing at wiring time anyway,
        // because the sweep is the only bounded way to clear a stale mark and a frozen queue is
        // what a stale mark costs.
        //
        // Only `impairedBorrowerCount` is probed. `impairedBorrowerAt` cannot be: an incoming pool
        // has an empty set, so index 0 is out of bounds and reverts with a `Panic`, which is
        // indistinguishable at this call site from the missing selector the probe is looking for.
        // A probe that cannot fail for the right reason is worse than none, because it reads as
        // cover - which is the shape of the finding this commit is answering.
        try ILenderPool(lenderPool_).impairedBorrowerCount() returns (uint256) {}
        catch {
            revert LenderPoolIncomplete();
        }

        lenderPool = lenderPool_;
        emit LenderPoolSet(lenderPool_);
        // Same trailing push `setLiquiditySource` makes, for the same reason: the incoming pool
        // prices its exits off these two figures and starts out knowing neither. The loss term is
        // zero by the guard above, so this only ever tells it the insurance cover standing in
        // front of the impairments - which is the difference between a correct exit price and one
        // that stands back from a fund the pool cannot see.
        _pushLossReserves();
    }

    function setEpochHarvester(address epochHarvester_) external onlyOwner {
        if (epochHarvester_ == address(0)) revert ZeroAddress();
        epochHarvester = epochHarvester_;
        emit EpochHarvesterSet(epochHarvester_);
    }

    /// @dev Refuses while the outgoing auction still has work in flight, for the same
    ///      reason the vault's twin does: `creditLiquidationProceeds` and
    ///      `writeDownLoss` are gated on this pointer, so a repoint makes every
    ///      in-flight `bid` revert mid-settlement and every `closeWorkout` revert -
    ///      leaving a residual that can never be recognised, `totalDebt` that never
    ///      returns to zero, and therefore both migration paths blocked permanently.
    function setLiquidationAuction(address liquidationAuction_) external onlyOwner {
        if (liquidationAuction_ == address(0)) revert ZeroAddress();
        address current = liquidationAuction;
        if (current != address(0)) {
            uint256 liveAuctions = ILiquidationAuction(current).liveAuctionCount();
            if (liveAuctions != 0) revert AuctionHasLiveWork(liveAuctions);
            uint256 openWorkouts = ILiquidationAuction(current).openWorkoutCount();
            if (openWorkouts != 0) revert AuctionHasLiveWork(openWorkouts);
        }
        // The incoming check its twin on the vault already had. Without it this manager
        // alone could be pointed at an auction with no relationship to the collateral it
        // is authorised to write losses against - and the two pointers can be set
        // independently, in either order.
        address boundVault = ILiquidationAuction(liquidationAuction_).vault();
        if (boundVault != address(vault)) revert LiquidationAuctionVaultMismatch(boundVault);

        // **Every selector `_impairmentFor` calls, because it makes all of them bare and
        // un-`try`ed.** Reached unguarded from `_repay`, and so from `repay` and `repayFor` - the
        // path this file promises repeatedly is never blockable and deliberately not
        // `whenNotPaused`. An address that answers `vault()` but not one of these bricks every
        // repayment for every borrower it is asked about, repairable only by an `onlyOwner` call
        // that by go-live is a timelock.
        //
        // `EpochHarvester.setCustodyAdapter` already does this and says why: an address that
        // cannot answer should fail "at wiring time and under the owner's hand, rather than inside
        // the permissionless `harvest`".
        //
        // **Audit round 17: the first version of this guard probed one of the three, and not the
        // one called first.** It covered `recognisedRecoveryOf`, the member that had just arrived,
        // and left the two the path had always called. `_impairmentFor` reaches `workoutsOpenFor`
        // first and unconditionally for every borrower; `recognisedRecoveryOf` is reached only
        // when `auctionOf` is non-zero, which on a freshly wired auction is nobody. So the guard
        // read as done while the state it existed to prevent was still one call away - and that
        // state is unrecoverable, because this function's own first statement reads
        // `liveAuctionCount()` on the pointer it has just broken, and `CollateralVault
        // .setCreditManager` needs a zero total debt that repayment can no longer reach.
        //
        // Prevention is therefore the whole of the fix: there is no way back, so the only safe
        // thing is never to arrive. The three probes below are what make that true.
        //
        // **This list is `_impairmentFor`'s call set and has to stay that way.** It is the third
        // round in a row that a selector reached a never-blockable path without its probe. If that
        // function gains a fourth external call, it gains a fourth probe here in the same commit,
        // and a fourth rejection test beside the three that already pin these.
        //
        // Probed at `address(0)`, which can hold no auction, no workout and no recovery, so each
        // reads a value it discards and is testing only that the call answers at all.
        try ILiquidationAuction(liquidationAuction_).workoutsOpenFor(address(0)) returns (uint256) {}
        catch {
            revert LiquidationAuctionIncomplete();
        }
        try ILiquidationAuction(liquidationAuction_).auctionOf(address(0)) returns (uint256) {}
        catch {
            revert LiquidationAuctionIncomplete();
        }
        try ILiquidationAuction(liquidationAuction_).recognisedRecoveryOf(address(0)) returns (uint256) {}
        catch {
            revert LiquidationAuctionIncomplete();
        }
        liquidationAuction = liquidationAuction_;
        emit LiquidationAuctionSet(liquidationAuction_);
    }

    // ── ICreditManager ───────────────────────────────────────────────────────

    /// @inheritdoc ICreditManager
    /// @dev Pausable: new debt stops when paused. Repayment never does.
    ///      Caps are on *outstanding* debt, not lifetime borrowing - a yield
    ///      write-down restores borrowing room, which is the intended behaviour for a
    ///      self-repaying loan.
    function borrow(uint256 amount) external whenNotPaused nonReentrant whileAttached {
        if (amount == 0) revert ZeroAmount();
        // No new debt while a workout is open against you. Two separate attacks need
        // this, and bounding the write-off alone stopped neither:
        //
        //  - `repayFor` is permissionless and does not touch `Workout.recovered`, so a
        //    third party can clear the defaulted debt without the workout noticing.
        //    `min(live, debtAtExpiry - recovered)` then bounds a write-off against debt
        //    that is entirely a fresh, fully-backed loan - and forgives it.
        //  - `_distribute` repays live debt before taking any penalty, and v1 borrowing
        //    is interest-free, so inflating live debt during the window makes the
        //    surplus zero and the liquidation penalty collectable never.
        //
        // Refusing the borrow is the one change that closes both, and it costs a
        // defaulter nothing they are entitled to: their collateral is already forfeit.
        address auction = liquidationAuction;
        if (auction != address(0) && ILiquidationAuction(auction).workoutsOpenFor(msg.sender) != 0) {
            revert WorkoutOpen(msg.sender);
        }
        // **And none while an auction is live against you either.** Audit round 13.
        //
        // The guard above enumerated workouts because the two attacks it was written for were
        // workout-shaped. A live auction is the same situation one stage earlier, and since the
        // impairment reserves `currentDebtOf` it is now also the borrower's own lever on every
        // lender's exit price: get liquidated, heal the position with `depositBonds` so `_bid` and
        // `expireToWorkout` both refuse it, then borrow up to the per-account cap and watch the
        // pool mark the whole of it down. `cancel` is the remedy and it is permissionless, but it
        // is unrewarded and optional, so nothing makes it happen.
        //
        // Refusing costs a borrower under auction nothing they are entitled to - they can still
        // repay their way out, which clears the auction on the next `cancel` - and it removes the
        // only input to the mark that the marked party controls.
        if (auction != address(0) && ILiquidationAuction(auction).auctionOf(msg.sender) != 0) {
            revert LiquidationOpen(msg.sender);
        }
        // **Do not issue debt that cannot be liquidated.** `liquidate` refuses unless
        // all three wiring pointers agree, and a manager migration cannot be atomic
        // across two contracts, so every one passes through a window where no auction
        // can be opened at all. `borrow` checked none of it, which left the protocol's
        // only risk-reduction mechanism offline while its risk-taking one stayed open -
        // a borrower could draw the full per-account cap and then be unliquidatable
        // until the owner finished wiring. The window is self-camouflaging, because the
        // auction's own `liveAuctionCount == 0` precondition is trivially satisfied
        // precisely *because* nothing can start an auction.
        //
        // This only ever blocks new debt, never an exit or a repayment, so it cannot
        // deadlock a migration.
        //
        // **Ask the vault, not this contract.** Round 8 caught the first version of
        // this guard reading `liquidationAuction` off `this`, which is zero on a
        // freshly deployed incoming manager - so it skipped itself in exactly the
        // migration window it was written to close, and only bit if the auction
        // happened to be pre-wired, an ordering nothing requires.
        //
        // From the manager, Phase 2 and a half-finished migration are indistinguishable:
        // both have `liquidationAuction == address(0)`. From the vault they are not.
        // The vault knows whether an auction exists in the system at all, so that is
        // the thing to condition on. Lending before the auction ships stays open;
        // lending while an auction exists but does not agree with this manager does not.
        address vaultAuction = vault.liquidationAuction();
        if (vaultAuction != address(0)) {
            if (vaultAuction != auction) revert AuctionPointerMismatch(auction, vaultAuction);
            address auctionManager = ILiquidationAuction(auction).creditManager();
            if (auctionManager != address(this)) {
                revert AuctionPointerMismatch(auctionManager, address(this));
            }
        }

        address source = liquiditySource;
        if (source == address(0)) revert LiquiditySourceUnset();
        // A never-posted oracle reads as stale, so this covers the unbootstrapped case
        // too and there is no separate zero-NAV check to forget.
        if (navOracle.isStale()) revert NavStale();
        // The vault's ledger must actually be backed by bonds in custody. A
        // break-glass `emergencyUnstake` empties the farm position without touching
        // `bondCount`, and lending against a ledger nothing backs is unrecoverable.
        // Withdrawals and liquidation views deliberately stay open in that state.
        if (!vault.custodyIsSolvent()) revert CustodyInsolvent();

        // Credit any yield the position has already earned before sizing the loan, so
        // a borrower is never refused against a debt that yield has covered.
        _settle(msg.sender, vault.bondCount(msg.sender));

        uint256 newDebt = debtOf[msg.sender] + amount;
        if (newDebt > Config.PER_ACCOUNT_BORROW_CAP) {
            revert PerAccountCapExceeded(newDebt, Config.PER_ACCOUNT_BORROW_CAP);
        }
        uint256 newTotal = totalDebt + amount;
        if (newTotal > Config.GLOBAL_BORROW_CAP) {
            revert GlobalCapExceeded(newTotal, Config.GLOBAL_BORROW_CAP);
        }

        uint256 collateral = vault.collateralValue(msg.sender);
        if (LtvMath.exceedsLtv(newDebt, collateral, Config.MAX_LTV_BPS)) {
            revert ExceedsMaxLtv(LtvMath.ltvBps(newDebt, collateral));
        }

        debtOf[msg.sender] = newDebt;
        totalDebt = newTotal;
        emit Borrowed(msg.sender, amount);

        // Verify the source actually delivered rather than trusting it. A short
        // delivery would otherwise be silently covered from this contract's own
        // balance, which belongs to claimants, the harvester and the insurance fund.
        uint256 balanceBefore = usdc.balanceOf(address(this));
        ILiquiditySource(source).lend(amount);
        uint256 delivered = usdc.balanceOf(address(this)) - balanceBefore;
        if (delivered != amount) revert LiquidityNotDelivered(amount, delivered);

        usdc.safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc ICreditManager
    /// @dev Deliberately not `whenNotPaused`: PRD §4.3 says repayment is always
    ///      allowed, matching the vault's rule that exits never pause. It also does
    ///      not touch the liquidity source, so a broken or paused source cannot stop a
    ///      borrower clearing their debt - settlement is deferred to
    ///      `settlePrincipal()`.
    function repay(uint256 amount) external nonReentrant {
        _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repay on someone else's behalf. Needed for rescue (a borrower who has
    ///         lost keys or been blacklisted by USDC) and for Phase 3 liquidators.
    function repayFor(address borrower, uint256 amount) external nonReentrant {
        _repay(msg.sender, borrower, amount);
    }

    /// @inheritdoc ICreditManager
    /// @dev **One storage write, whatever the position count.** PRD §6.2 asks for 200+
    ///      positions settled in a single transaction; iterating and writing per
    ///      borrower would make that a gas problem to engineer around, and it would
    ///      also need an on-chain list of every holder that nothing currently keeps.
    ///
    ///      Instead this is the accumulator pattern: track yield-per-bond ever
    ///      distributed, and let each position work out its own share lazily from the
    ///      difference against its recorded index. It is the same mechanism DexFi's
    ///      own farm uses to pay us.
    ///
    ///      The USDC must already have arrived via `receiveYield`, so the accumulator
    ///      can only ever promise what is actually held.
    ///
    ///      **The epoch's share is streamed, not applied at once.** A lump credited to
    ///      whoever holds bonds at the harvest instant is free money for anyone
    ///      watching the mempool: deposit a large position in the same block, settle,
    ///      claim, withdraw. Spreading it over `YIELD_STREAM_DURATION` means a
    ///      position earns in proportion to how long it was actually staked, so the
    ///      round trip earns one block of yield and loses the gas.
    ///
    ///      `amount` is the epoch's newly delivered share and is validated against
    ///      what `receiveYield` actually took in. The stream is then re-rated over the
    ///      *whole* undistributed pot, which is what rolls a previous stream's
    ///      unfinished tail - and division dust, and anything that accrued while no
    ///      bonds were staked - into the new one instead of stranding it.
    /// @dev `whileAttached` for the reason the modifier's own NatSpec gives, which
    ///      applied here all along: this calls `_accrue()` directly rather than going
    ///      through `_settle`'s detached bail-out, so a detached manager would keep
    ///      converting `undistributedYield` into accumulator units against a bond base
    ///      it no longer governs - and nothing could ever settle against them. It was
    ///      the one accumulator-writing entrypoint without the guard.
    function distributeYield(uint256 amount) external whileAttached {
        if (msg.sender != epochHarvester) revert NotEpochHarvester();
        if (amount > undistributedYield) revert YieldNotDelivered(amount, undistributedYield);

        // Bring the running stream up to date before re-rating, or the tail would be
        // re-rated as though the elapsed part of it had never been paid out.
        _accrue();

        // Pay out over at least as long as the pot took to accrue.
        //
        // Streaming over a fixed window closes same-block capture but not the general
        // case: a pot representing sixty days of yield, rated over five, hands
        // eleven-twelfths of it to whoever happens to be staked for those five days.
        // A just-in-time depositor of any size profits once the accrual window exceeds
        // roughly twice the stream, and `harvest` is permissionless, so the attacker
        // picks the block. Windows stretch for ordinary reasons: a keeper outage, a run
        // of declined zero-yield epochs, or simply the gap before the harvester is
        // wired at all.
        //
        // Matching the payout window to the earning window makes the round trip cost
        // what it earns, at any scale.
        uint256 elapsed = block.timestamp - lastDistributeAt;
        uint256 duration =
            elapsed > Config.YIELD_STREAM_DURATION ? elapsed : Config.YIELD_STREAM_DURATION;

        // **Never shorten a running stream.** `elapsed` describes the accrual window of
        // the *new* money, but the pot it is applied to also holds the unfinished tail
        // of the previous stream, whose window may have been months. Re-rating the tail
        // over the new gap compresses it - which is precisely the just-in-time capture
        // the stretch above exists to prevent, reintroduced one epoch later.
        //
        // Concretely: a genesis epoch rated over 60 days, followed by a normal epoch
        // five days later, pays 55 days of other people's accrual to whoever is staked
        // for those five. The tail keeps the window it was rated with.
        uint256 remaining = streamEndsAt > block.timestamp ? streamEndsAt - block.timestamp : 0;
        if (remaining > duration) duration = remaining;

        uint256 pot = undistributedYield;
        uint256 rate = (pot * ACC_PRECISION) / duration;
        // Only reachable on an empty pot, since the rate carries ACC_PRECISION of
        // headroom. Nothing to stream, so leave the previous one alone.
        if (rate == 0) return;

        yieldRate = rate;
        lastAccrualAt = block.timestamp;
        lastDistributeAt = block.timestamp;
        streamEndsAt = block.timestamp + duration;
        emit YieldDistributed(amount, rate, streamEndsAt);
    }

    /// @notice Bring the accumulator up to the current timestamp.
    /// @dev Permissionless and idempotent. Nothing requires it to be called - every
    ///      path that reads or writes a position calls it first - but exposing it
    ///      lets a keeper keep the accumulator warm and makes the streaming testable
    ///      without going through a position.
    function accrueYield() external whileAttached {
        _accrue();
    }

    /// @notice Apply a position's accrued yield: debt first, the rest to claimable.
    /// @dev Permissionless on purpose. It only ever helps the position it settles, and
    ///      making it require the borrower would mean an inattentive borrower keeps
    ///      paying against a debt that yield has already covered.
    function settle(address borrower) public whileAttached {
        _settle(borrower, vault.bondCount(borrower));
    }

    /// @notice Settle before the vault changes a position's bond count.
    /// @dev Must run against the OLD count, because that is the balance the yield
    ///      accrued to. It also sets a brand new position's index to the current
    ///      accumulator, which is what stops a depositor claiming yield distributed
    ///      before they arrived.
    function settleForVault(address borrower, uint256 currentBonds) external {
        if (msg.sender != address(vault)) revert NotVault();
        _settle(borrower, currentBonds);
    }

    /// @inheritdoc ICreditManager
    function pendingYieldOf(address borrower) public view returns (uint256) {
        return _pending(borrower, vault.bondCount(borrower));
    }

    /// @inheritdoc ICreditManager
    /// @dev Debt net of yield the position has earned but not yet settled, which is
    ///      what a borrower actually owes. `debtOf` is the stored figure and can be
    ///      stale; anything gating a state change should prefer this.
    function currentDebtOf(address borrower) public view returns (uint256) {
        uint256 pending = pendingYieldOf(borrower);
        uint256 debt = debtOf[borrower];
        return pending >= debt ? 0 : debt - pending;
    }

    /// @notice Deliver the borrower share of an epoch's yield before allocating it.
    /// @dev Separating delivery from allocation is what makes `claimableOf` a backed
    ///      balance rather than a promise: without it, anything holding the harvester
    ///      role could credit arbitrary claimable amounts and drain the contract.
    function receiveYield(uint256 amount) external nonReentrant whileAttached {
        if (msg.sender != epochHarvester) revert NotEpochHarvester();
        if (amount == 0) revert ZeroAmount();
        undistributedYield += amount;
        emit YieldReceived(amount);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Add USDC to the insurance fund, which absorbs auction shortfalls before
    ///         any loss reaches lenders (PRD §4.4).
    /// @dev Permissionless: anyone may top it up, and nothing can pay it out except a
    ///      Phase 3 shortfall. Until this existed the counter was declared but never
    ///      written, which made one term of the solvency invariant vacuous.
    ///
    ///      **Being permissionless gives the withdrawal queue's refusal a price, and the price is
    ///      one wei.** `LenderPool.serviceQueue` stops while `exitReserve()` is non-zero, and a
    ///      donation here is netted off that figure synchronously, so a stranger can switch the
    ///      refusal off by covering the mark. Audit round 16 raised it and it is **not** an
    ///      extraction, for a reason worth writing down as the invariant it actually is:
    ///
    ///          exitReserve() == 0  implies  insuranceCover >= totalImpairment, or nothing is lent
    ///
    ///      so at the moment the queue reopens, either the shortfall is provably absorbed by this
    ///      fund or the pool has no exposure to absorb it with - and the un-impaired price the
    ///      queue then pays is the correct one. The donor pays the whole mark to gain a fraction of
    ///      it. **The safety rests on that inequality and not on the gate**, which is worth being
    ///      explicit about because the commit that introduced the gate is titled for the truncation
    ///      it replaced and the comments around it credit the gate.
    function fundInsurance(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        insuranceFund += amount;
        emit InsuranceFunded(msg.sender, amount);
        // The pool nets insurance against the gross impairment, so a top-up it has not been told
        // about leaves `insuranceCover` stale-low and every exit under-priced until somebody
        // happens to call `refreshImpairment`. See `_pushLossReserves` for the rule.
        _pushLossReserves();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc ICreditManager
    /// @dev Settles first. Without it a borrower whose debt is already cleared has to
    ///      call `settle` themselves before the overflow becomes visible here, and
    ///      claiming looks like it lost them money when it merely ran early.
    function claimSurplus() external nonReentrant {
        _settle(msg.sender, vault.bondCount(msg.sender));
        uint256 amount = claimableOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableOf[msg.sender] = 0;
        totalClaimable -= amount;
        emit SurplusClaimed(msg.sender, amount);
        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Return accumulated principal to the liquidity source.
    /// @dev Permissionless: it only ever moves money home, and keeping it out of
    ///      `repay`/`applyYield` is what lets those work when the source cannot
    ///      receive, and keeps the harvester's hot loop free of external calls.
    ///      Pull-based, so the transfer and the source's bookkeeping cannot come apart.
    function settlePrincipal() external nonReentrant {
        uint256 amount = pendingPrincipal;
        if (amount == 0) revert NothingToSettle();
        address source = liquiditySource;
        if (source == address(0)) revert LiquiditySourceUnset();

        // Verify the pull rather than assume it, mirroring what `borrow` does on the
        // inbound leg. Zeroing the counter before an unverified transfer would let a
        // source that pulls short silently forgive the difference, stranding USDC that
        // no counter claims and clearing the very guard `setLiquiditySource` relies on.
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.forceApprove(source, amount);
        ILiquiditySource(source).repayPrincipal(amount);
        usdc.forceApprove(source, 0); // leave no standing allowance

        // Decrement, do not assign. `amount` is a snapshot from before an external
        // call, and `settle`/`settleForVault` are the only value-moving paths without
        // `nonReentrant` - both reach `_settle`, which does `pendingPrincipal +=`. A
        // liquidity source that calls back into either would have that increment
        // erased by an assignment, or, in the other direction, would leave the counter
        // higher than what is owed so the next call pays the excess out of USDC
        // backing `totalClaimable` and the insurance fund.
        uint256 delivered = balanceBefore - usdc.balanceOf(address(this));
        pendingPrincipal -= delivered;
        emit PrincipalSettled(delivered);
    }

    // ── Liquidation (PRD §4.5) ───────────────────────────────────────────────

    /// @inheritdoc ICreditManager
    /// @dev Three gates this deliberately does NOT apply, each a rule stated elsewhere:
    ///
    ///      - not `whenNotPaused`. Pause stops new risk, never resolution - the same
    ///        rule that keeps `repay` open. A protocol that pauses its way out of
    ///        liquidating underwater positions just converts them into bad debt.
    ///      - no `navOracle.isStale()` check. PRD §4.6: staleness pauses *borrowing*
    ///        and liquidation continues on the last known NAV. Gating here would let a
    ///        keeper outage disable liquidation exactly when it matters.
    ///      - no `custodyIsSolvent()` check. A break-glass `emergencyUnstake` must not
    ///        also disable liquidation; `borrow` is the only caller that refuses.
    ///
    ///      `whileAttached`, though, is required: a detached manager's `_settle` is a
    ///      silent no-op, so it would price positions off a frozen accumulator and
    ///      start auctions against numbers it no longer governs.
    function liquidate(address borrower) external nonReentrant whileAttached {
        // Settle first. Yield streams continuously, so the stored `debtOf` lags what
        // the borrower actually owes, and liquidating on the stale figure seizes a
        // position that a free, permissionless `settle` would have cleared. It also
        // makes this gate, the vault's, and the auction's all read one number.
        _settle(borrower, vault.bondCount(borrower));

        uint256 debt = debtOf[borrower];
        if (debt == 0) revert NoDebt();

        uint256 collateral = vault.collateralValue(borrower);
        // `exceedsLtv` cross-multiplies. `healthFactor` divides twice and reports
        // exactly 1e18 for a position a fraction of a bp past the threshold, so gating
        // on the view would refuse the first position that becomes liquidatable.
        if (!LtvMath.exceedsLtv(debt, collateral, Config.LIQUIDATION_THRESHOLD_BPS)) {
            revert PositionHealthy(LtvMath.ltvBps(debt, collateral));
        }

        address auction = liquidationAuction;
        if (auction == address(0)) revert LiquidationAuctionUnset();
        // The vault must honour the same auction, or `start` succeeds and every exit the
        // new auction has reverts `NotLiquidationAuction` on the vault - a permanently
        // stranded position opened by an anonymous caller, during the two-transaction
        // window every auction migration passes through. Worse, the live-work guard on
        // `setLiquidationAuction` would then refuse to finish that migration.
        address vaultAuction = vault.liquidationAuction();
        if (vaultAuction != auction) revert AuctionPointerMismatch(auction, vaultAuction);

        uint256 maxReward = (
            ((debt * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS) * Config.LIQUIDATION_CALLER_SHARE_BPS
        ) / Config.BPS;
        emit LiquidationTriggered(borrower, msg.sender, maxReward);

        ILiquidationAuction(auction).start(borrower, msg.sender);

        // Marked the moment the auction exists rather than when it resolves, and it has to be
        // after `start` because the mark is derived from the auction that call creates. Until this
        // line runs the pool is still pricing exits as though nothing had happened, which is the
        // recognition gap the whole impairment mechanism exists to close.
        _setImpairment(borrower, _impairmentFor(borrower));
        _pushLossReserves();
    }

    /// @notice Book the non-debt part of a liquidation: the insurance fund's cut of the
    ///         penalty, and whatever is left over for the borrower.
    /// @dev One pull for both legs, so they cannot come apart and only one allowance is
    ///      ever open. The borrower's share lands in `claimableOf` rather than being
    ///      transferred, because a USDC-blacklisted borrower must not be able to make
    ///      every bid on their position revert - which is what a push would do, turning
    ///      a bad position into a permanently unliquidatable one.
    function creditLiquidationProceeds(address borrower, uint256 toInsurance, uint256 toBorrower)
        external
        nonReentrant
    {
        if (msg.sender != liquidationAuction) revert NotLiquidationAuction();
        uint256 total = toInsurance + toBorrower;
        if (total == 0) revert ZeroAmount();

        insuranceFund += toInsurance;
        if (toBorrower != 0) {
            claimableOf[borrower] += toBorrower;
            totalClaimable += toBorrower;
        }
        emit LiquidationProceedsCredited(borrower, toInsurance, toBorrower);
        // Raises the cover standing in front of the pool's reserve, and it arrives on the
        // liquidation path where a reserve is most likely to be live. Not pushing here was the
        // clearest of the five: the same transaction that resolves a liquidation left the pool
        // pricing exits against the insurance figure from before it.
        _pushLossReserves();
        usdc.safeTransferFrom(msg.sender, address(this), total);
    }

    /// @notice Recognise unrecoverable debt: clear it from the books, make the liquidity
    ///         source whole out of insurance as far as that reaches, and socialise the
    ///         rest to lenders.
    /// @dev No token moves. USDC already held here is relabelled from one term of the
    ///      solvency invariant (`insuranceFund`) to another (`pendingPrincipal`), which
    ///      is precisely what "the insurance fund absorbs the shortfall" means: the
    ///      source lent this principal and is still owed it, so erasing the borrower's
    ///      debt without funding it would just move the hole somewhere less visible.
    ///
    ///      Clearing `debtOf`/`totalDebt` is load-bearing beyond the accounting.
    ///      `CollateralVault.setCreditManager` and `setLiquiditySource` both refuse
    ///      while `totalDebt != 0`, so a default written off in narrative but not in
    ///      storage would permanently block both migration paths.
    function writeDownLoss(address borrower, uint256 amount) external nonReentrant {
        if (msg.sender != liquidationAuction) revert NotLiquidationAuction();
        _settle(borrower, vault.bondCount(borrower));

        uint256 outstanding = debtOf[borrower];
        uint256 loss = amount > outstanding ? outstanding : amount;
        if (loss == 0) revert ZeroAmount();

        debtOf[borrower] = outstanding - loss;
        totalDebt -= loss;

        uint256 fromInsurance = loss > insuranceFund ? insuranceFund : loss;
        insuranceFund -= fromInsurance;
        pendingPrincipal += fromInsurance;

        uint256 socialised = loss - fromInsurance;
        emit LossWrittenDown(borrower, loss, fromInsurance, socialised);
        // The uncovered part deliberately does not touch `pendingPrincipal`. That is
        // what socialisation means: the source never gets it back.
        if (socialised != 0) _socialise(socialised);

        // **The mark stands across `_socialise` and is dropped only afterwards, and that order is
        // load-bearing.** Released first, the exit price would sit back at its un-impaired level
        // for the instant between the release and the loss actually landing, and a lender leaving
        // in that instant would take real USDC at a price the protocol already knew was wrong.
        // Held first, the price is momentarily *low* instead - the leaver is short-changed rather
        // than everybody who stayed, which is the safe direction to be wrong in. The only code
        // that runs in that window is this protocol's own pool.
        //
        // **Audit round 16 found this paragraph describing the opposite of what the code did, and
        // the direction it names as unsafe is the one the code took.** On the fill path the mark
        // reaching here had already been netted against the fill twice, so it was understated or
        // zero and the price was momentarily *high*. The order was never the problem; what stood
        // in the window was. The auction now clears its in-flight recovery before the debt moves,
        // so what stands here is the exact loss about to be socialised, and the sentence above is
        // a true statement again rather than an intention.
        //
        // Set to zero rather than re-derived. **The reason is that the debt has just been cleared,
        // not that the auction pointer has.** This used to say the pointer was already deleted on
        // the fill path, which is inverted: `writeDownLoss` is reached from `_settleFill`, and
        // `delete auctionOf[borrower]` happens after that returns. A wrong reason licenses a wrong
        // edit - re-deriving here instead of writing zero is exactly what a reader who believed
        // that sentence would think was equivalent.
        //
        // The forced `closeWorkout` path closes its workout on the next line. Both leave nothing
        // to mark, and the auction re-derives it anyway on the way out.
        _setImpairment(borrower, 0);
        _pushLossReserves();
    }

    /// @notice Re-state the reserve the lender pool holds against `borrower`, derived from auction
    ///         and vault state. Permissionless.
    /// @dev **One function doing two jobs**: the notification `LiquidationAuction` sends on every
    ///      terminal transition, and the way back when that notification is dropped.
    ///
    ///      Permissionless deliberately, and the auction's `try`/`catch` is why. That `catch` has to
    ///      exist - `expireToWorkout` is the exit of last resort and an exit a lender pool can brick
    ///      is not an exit - so a notification genuinely can be swallowed. A dropped *release* would
    ///      then strand a reserve and depress the exit price for every lender permanently, and the
    ///      party who most wants that fixed is the lender about to leave. Letting them call it turns
    ///      "no impairment outlives its auction" from a claim about call-site completeness into a
    ///      claim about reachability, which is the weaker thing to have to prove and the one that
    ///      survives somebody adding a seventh call site badly.
    ///
    ///      Safe to open up because the caller supplies no figure. `_impairmentFor` derives the only
    ///      value this can ever store from state the caller does not control, so the worst a
    ///      stranger can do is bring the pool up to date.
    ///
    ///      Deliberately not `nonReentrant` and not `whenNotPaused`. It is reachable from inside
    ///      `liquidate`'s own guarded frame - `start` notifies from its supersede branch - and
    ///      pausing stops new risk, never resolution, the same rule that keeps `repay` open.
    function refreshImpairment(address borrower) external {
        _setImpairment(borrower, _impairmentFor(borrower));
        _pushLossReserves();
    }

    /// @notice Re-state up to `maxBorrowers` of the pool's standing marks, newest first.
    ///         Permissionless.
    /// @return refreshed how many borrowers were visited.
    /// @dev **The version of the function above that needs no borrower address.** Audit round 16
    ///      found a stale mark with no attacker and no transaction behind it: a mark is a
    ///      photograph of `currentDebtOf`, the yield stream lowers that figure continuously with
    ///      nothing to hang a refresh on, and `impairmentOf` had no key list - so the only way to
    ///      learn which borrower to name was to replay `Impaired` logs off chain. The pool now
    ///      publishes the set and this walks it.
    ///
    ///      What made it worth building rather than documenting is what a stale mark now costs.
    ///      Audit round 15 keyed the withdrawal queue's refusal on `exitReserve() != 0`, which is
    ///      sound and which turned every pre-existing stale mark from a wrong exit price into a
    ///      total freeze of the queue. Executed: a debt of zero, 24,371 USDC of idle cash, and the
    ///      queue shut. **Widening what a condition governs re-prices every latent defect that can
    ///      reach it.**
    ///
    ///      **Downward, and that is load-bearing rather than stylistic.** Releasing a mark
    ///      swap-pops the tail of the pool's set into the vacated slot. Walking upward would step
    ///      over whatever was moved into a slot the cursor had already passed; walking downward has
    ///      visited the tail already, so nothing is skipped.
    ///
    ///      Bounded by the caller, because the set has no a-priori limit and an unbounded loop over
    ///      it would be a call that stops fitting in a block exactly when there are most marks to
    ///      clear.
    ///
    ///      **The bound needs a cursor, and audit round 17 found it missing.** This used to restart
    ///      at `count - 1` on every call, so any `maxBorrowers` below `count` re-visited the same
    ///      tail forever. Marks append, so the *oldest* mark - the one the clock has had longest to
    ///      make stale, and therefore the one freezing the queue - sits nearest index 0 and was
    ///      reached last or never. Executed: twenty-five consecutive `refreshImpairments(1)` calls
    ///      each reported one refresh, changed nothing, and left `serviceQueue` reverting
    ///      `QueueHeldByReserve` over 23,292 USDC of idle cash and one queued lender. Only a call
    ///      spanning the whole set cleared it - which is the unbounded call the bound exists to
    ///      avoid.
    ///
    ///      The old NatSpec claimed "repeated bounded calls always make progress", reasoning that
    ///      each iteration either clears a mark or leaves a live one for later. A live tail entry
    ///      re-examined is a fixed point, so that was false. It is true now, and in the specific
    ///      sense worth stating: **every entry is visited within `ceil(count / maxBorrowers)`
    ///      calls**, because the cursor descends and wraps rather than restarting.
    ///
    ///      **Still downward, and that is load-bearing rather than stylistic.** Releasing a mark
    ///      swap-pops the tail of the pool's set into the vacated slot. Walking upward would step
    ///      over whatever was moved into a slot the cursor had already passed; walking downward has
    ///      visited the tail already, so nothing is skipped within a call. Audit round 17 attacked
    ///      the direction from six angles and it held - the direction was never the defect, and a
    ///      fix that reversed it would have broken the thing that was working.
    ///
    ///      The cursor is an index into a set that mutates between calls, so it is a hint rather
    ///      than a bookmark: after a release the index may name a different borrower. That is
    ///      correct for a sweep. What the cursor has to buy is *coverage*, not exact enumeration,
    ///      and descend-and-wrap gives coverage against any mutation - a swap-popped entry lands
    ///      below the cursor and is picked up on the next lap.
    ///
    ///      It cannot run out of bounds. The cursor only ever decreases within a call while the set
    ///      only ever shrinks by at most one per iteration, so `cursor < count` is preserved; the
    ///      wrap re-reads the live count rather than trusting the one loaded at entry.
    ///
    ///      One `_pushLossReserves` at the end rather than one per borrower - it restates two
    ///      book-level figures that no iteration here changes. **It also has to happen on the empty
    ///      path**, which audit round 17 found it skipping: `count == 0` returned before reaching
    ///      it, so the two terms of the reserve that are not per-borrower went unrefreshed in
    ///      exactly the state where nothing else was going to refresh them.
    ///
    ///      Not `whenNotPaused` and not `nonReentrant`, for the same reasons as the single-borrower
    ///      form above: pausing stops new risk, never resolution.
    function refreshImpairments(uint256 maxBorrowers) external returns (uint256 refreshed) {
        address pool = lenderPool;
        if (pool == address(0)) return 0;

        uint256 count = ILenderPool(pool).impairedBorrowerCount();
        if (count == 0) {
            // Nothing to walk, but the book-level terms are still this function's job.
            impairmentCursor = 0;
            _pushLossReserves();
            return 0;
        }
        if (maxBorrowers > count) maxBorrowers = count;

        uint256 cursor = impairmentCursor;
        if (cursor > count) cursor = count; // the set shrank since the last call

        for (uint256 i; i < maxBorrowers; ++i) {
            if (cursor == 0) {
                // Wrap to the top, re-reading the count rather than trusting the entry snapshot:
                // releases inside this very loop may have shortened the set underneath us.
                cursor = ILenderPool(pool).impairedBorrowerCount();
                if (cursor == 0) break; // everything got released on the way round
            }
            --cursor;
            address borrower = ILenderPool(pool).impairedBorrowerAt(cursor);
            // Counted on the write landing, not on the visit. Audit round 17: `refreshed` used to
            // increment once per iteration while every write here is `try`-swallowed, so a pool
            // refusing all of them reported a full sweep. The return value is what an operator
            // reads to decide whether to call again.
            if (_setImpairment(borrower, _impairmentFor(borrower))) refreshed++;
        }
        impairmentCursor = cursor;
        _pushLossReserves();
    }

    /// @dev The only figure `refreshImpairment` will ever store, derived rather than supplied.
    ///
    ///      **One stage, not two: a liquidation in progress reserves the whole debt, and recovery
    ///      is recognised when it is realised rather than when it is predicted.**
    ///
    ///      This used to credit `floorProceeds` as assumed recovery against a live auction, on the
    ///      reasoning that the worst a Dutch auction can do to lenders is fill at its floor. That
    ///      reasoning is sound about auctions and wrong about *this* number, because the figure it
    ///      produced was a stored snapshot of a quantity that moves on the clock. Audit round 12
    ///      found one defect wearing five costumes, and they are worth listing, because each was
    ///      invisible from inside the formula:
    ///
    ///      - `AUCTION_FLOOR_BPS` (6800) sits above `LIQUIDATION_THRESHOLD_BPS` (5000), so
    ///        `debt - floorProceeds` was negative and stored as **zero for the whole 50-68% LTV
    ///        band** - the band every position enters first, and the only one reachable at all with
    ///        the keeper posting on schedule. The mechanism was dormant in the ordinary case.
    ///      - `floorProceeds` returns zero once the bid window lapses, and **a lapse writes no
    ///        storage**, so the correct figure escalated with no transaction to carry it while the
    ///        stored one stayed low.
    ///      - The permissionless supersede re-derived it at a live NAV the caller chose the block
    ///        for, so it could be reset downward at will.
    ///      - It read as the full debt inside the winner's callback, where `a.settled`
    ///        short-circuited the credit.
    ///
    ///      Marking the whole debt removes the recovery estimate, the supersede reset and the
    ///      callback window together. What is left is a question about facts: is there a
    ///      liquidation open against this borrower, and how much do they owe.
    ///
    ///      **Not "nothing here reads a clock", which is what this comment said until audit round
    ///      13 refuted it.** `currentDebtOf` is `debtOf` less the borrower's projected share of the
    ///      running yield stream, and that projection reads `block.timestamp` - so the derived mark
    ///      decays continuously between blocks, and the permissionless `refreshImpairment` stores
    ///      whichever value its caller's block produces. The claim was written at the moment the
    ///      *price* dependence was removed and overstated it into a clock dependence that is still
    ///      here.
    ///
    ///      What is true, and is the property worth relying on: absent a new `borrow` the debt is
    ///      monotonically non-increasing, so a caller choosing a later block can only lower the
    ///      mark and *raise* the exit price. The residual is the other direction - a caller may
    ///      decline to refresh and settle against a stale-high mark. **This used to say the queue's
    ///      `minAssets` floor answered that, and audit round 14 deleted the floor**, so for two
    ///      rounds this file cited a mechanism that does not exist and `LenderPool` documented the
    ///      deletion a few screens away. The staleness is real, one-directional and currently
    ///      unanswered; it is recorded as an open item rather than papered over here. State it as a
    ///      direction, not as an absence: this is exactly the sort of claim
    ///      `LenderPool.requestWithdrawal` was reading off this file.
    ///
    ///      Recovery needs no branch of its own, and the reason is a disjointness claim rather than
    ///      an ordering one. A fill reduces `currentDebtOf` by the proceeds, and the auction's
    ///      in-flight recovery records only what has been paid in and *not yet* applied to the
    ///      debt, so no dollar of the winner's payment is ever in both terms of the subtraction
    ///      below. `auctionOf` is cleared on every terminal transition, so the mark falls because
    ///      the debt fell - which is the difference between recognising a recovery and forecasting
    ///      one. **Audit round 16 is what turned that from an ordering argument into this one**:
    ///      the recovery outlived the debt reduction by one statement and the same dollars were
    ///      subtracted twice.
    ///
    ///      **The cost, stated as a cost.** This is deliberately over-conservative: in the ordinary
    ///      band the floor comfortably clears the loan, so a lender leaving during a routine
    ///      six-hour auction is marked down for a loss that probably will not happen, and stayers
    ///      gain what leavers give up. That is the intended direction rather than an oversight -
    ///      an over-mark costs a leaver some of their upside, an under-mark hands them somebody
    ///      else's principal - but it is a real cost and it is not being described as free.
    ///      `exitReserve()` bounds it twice, netting `insuranceCover` and clamping to
    ///      `outstandingPrincipal`, so the pool is never marked below its own exposure.
    ///
    ///      The workout is still checked first, because it outlives the auction that opened it: a
    ///      borrower can hold a settled auction and an open workout at the same instant. Both
    ///      branches now answer the same thing, so the ordering is about which fact is still true
    ///      rather than about which figure is larger.
    ///
    ///      Zero once detached, which is the truth rather than a shortcut - the vault only releases
    ///      a manager at `totalDebt == 0`, so a detached manager has no position left to mark.
    function _impairmentFor(address borrower) private view returns (uint256) {
        if (vault.creditManager() != address(this)) return 0;

        address auction = liquidationAuction;
        if (auction == address(0)) return 0;

        if (ILiquidationAuction(auction).workoutsOpenFor(borrower) != 0) return currentDebtOf(borrower);

        // `auctionOf` tracks the *existence* of a liquidation against this borrower: written by
        // `start`, reassigned on a supersede, and deleted by `_bid`, `cancel` and `expireToWorkout`
        // alike. **It does not track liveness, and this comment claimed it did until audit round
        // 15.** Nothing deletes it when the bid window lapses, so a lapsed auction still answers
        // here - which is correct and deliberate, because a lapse means nobody bid, the collateral
        // is still forfeit and the successor states all mark the whole debt. The claim that reading
        // it "keeps this answer free of the clock" was wrong twice over: `currentDebtOf` projects
        // on `block.timestamp` anyway, and existence was never the same question as liveness.
        if (ILiquidationAuction(auction).auctionOf(borrower) == 0) return 0;

        // **Recovery already inside the auction, netted off before anyone can spend the un-netted
        // figure.** Audit round 15: `_bid` holds the pointer above set across the winner's ERC-1155
        // callback so the mark cannot be released early, and a winning bidder used that standing
        // mark to settle a queued lender through the permissionless `serviceQueue`, on auctions
        // whose realised loss ended at zero.
        //
        // This is not a forecast and does not reintroduce one. It is USDC the auction has already
        // taken from the winner, measured as a balance delta, non-zero only between that payment
        // and the first statement that applies it to the debt. The rule above is unchanged -
        // recovery is recognised when it is realised, never when it is predicted - and it is now
        // recognised at the statement where the realisation actually happens.
        //
        // **The two terms below must be disjoint, and audit round 16 is what proved that is the
        // real requirement.** The claim used to be that this slot was non-zero only until "the
        // write-down", which was a wider window than the one that matters: `_repay` re-derives the
        // mark on its way out, with the debt already reduced by the fill, and for one statement
        // both terms described the same dollars. The auction now clears the slot before the
        // repayment leg begins rather than after it ends.
        //
        // Saturating, so a fill above the debt marks nothing rather than underflowing.
        uint256 debt = currentDebtOf(borrower);
        uint256 recovered = ILiquidationAuction(auction).recognisedRecoveryOf(borrower);
        return debt > recovered ? debt - recovered : 0;
    }

    /// @dev Best-effort, exactly like `_socialise` and for the same reason: every caller sits on a
    ///      liquidation path the pool must not be able to block, and all three of the auction's
    ///      exits reach it. A pool that reverts here leaves a stale mark, which is a wrong price; a
    ///      pool that could revert *through* here would leave stranded collateral, which is worse.
    ///
    ///      Routed to `releaseImpairment` at zero rather than to `impair(borrower, 0)`. The two
    ///      leave identical storage, but only one of them emits `ImpairmentReleased` - and an
    ///      indexer that never sees a release cannot tell a resolved position from a permanently
    ///      marked one.
    /// @return landed Whether the pool actually took the figure. Every caller but
    ///         `refreshImpairments` ignores it and must keep ignoring it - they sit on liquidation
    ///         paths that a refusal here is not allowed to change the course of. The bulk sweep is
    ///         the one caller that *reports* to somebody, so it is the one that needs to know the
    ///         difference between a mark it refreshed and a mark it merely looked at.
    function _setImpairment(address borrower, uint256 amount) private returns (bool landed) {
        address pool = lenderPool;
        if (pool == address(0)) return false;

        if (amount == 0) {
            try ILenderPool(pool).releaseImpairment(borrower) {
                return true;
            } catch {
                return false;
            }
        } else {
            try ILenderPool(pool).impair(borrower, amount) {
                return true;
            } catch {
                return false;
            }
        }
    }

    /// @notice Hand the insurance fund to the manager the vault now points at.
    /// @dev **The migration path the vault's guard was standing in for.** Insurance is
    ///      the largest of the four solvency pots, it grows monotonically, and its only
    ///      spender is `writeDownLoss`, which needs a live borrower on *this* manager -
    ///      something `setCreditManager`'s own `totalDebt == 0` precondition has just
    ///      guaranteed does not exist. So a legitimate migration used to destroy it.
    ///
    ///      A guard on the vault could not fix that: insurance never returns to zero on
    ///      its own, so the guard would simply block migration forever. The value has to
    ///      be movable instead.
    ///
    ///      Only callable once detached, and only into the manager the vault actually
    ///      points at, so this cannot be used to drain reserves to an arbitrary
    ///      address. `fundInsurance` is permissionless and pull-based, so the incoming
    ///      manager needs no wiring for this to land.
    ///
    ///      **Round 7: insurance was not the only trapped pot, and moving only it left
    ///      the larger one behind.** `undistributedYield` is decremented in exactly one
    ///      place, `_accrue()`, whose three callers are `_settle` (which returns early
    ///      once detached), `accrueYield` and `distributeYield` (both `whileAttached`).
    ///      A detached manager therefore has no writer, no reader and no sweep for it,
    ///      and `harvest` is permissionless, so a stranger could time an epoch to
    ///      maximise what a migration destroyed. The same is true of yield that
    ///      `_accrue` has already moved into `accYieldPerBond` but no position has
    ///      settled: it is backed by USDC that none of the four counters claims.
    ///
    ///      So this moves everything that is not still individually payable from here.
    ///      `totalClaimable` and `pendingPrincipal` stay, because their claimants are
    ///      named and `claimSurplus` keeps working while detached.
    ///
    ///      **`settlePrincipal` is the exception, and round 8 caught this docstring
    ///      claiming otherwise.** It calls `liquiditySource.repayPrincipal`, which is
    ///      `onlyCreditManager` against a single slot - and repointing that slot is
    ///      part of the same migration, because otherwise the incoming manager cannot
    ///      lend. So the order is load-bearing and is not enforced anywhere:
    ///      **call `settlePrincipal()` here BEFORE repointing the liquidity source.**
    ///      Miss it and the principal is unreachable by every contract, and the sweep
    ///      will not take it either, since `balance == spokenFor` by construction. The
    ///      vault's `totalDebt == 0` detach precondition makes this worst: it is only
    ///      reachable through repayment, and every repayment grows `pendingPrincipal`.
    ///
    ///      Everything else goes, as insurance, because per-position entitlement
    ///      cannot be reconstructed on the incoming manager - there is no holder list
    ///      to replay. **That is a real cost, stated plainly: a holder who had accrued
    ///      but not settled loses the individual claim.** The alternative was losing the
    ///      value outright, and detachment is one-way (see `setCreditManager` on the
    ///      vault), so there is no longer a re-attach that could pay them.
    ///
    ///      Delivery is measured rather than assumed, matching every other value-moving
    ///      leg in this contract.
    function migrateReserves() external onlyOwner nonReentrant {
        address live = vault.creditManager();
        if (live == address(this)) revert StillAttached();
        if (live == address(0)) revert ZeroAddress();

        uint256 spokenFor = totalClaimable + pendingPrincipal;
        uint256 balance = usdc.balanceOf(address(this));
        if (balance <= spokenFor) revert ZeroAmount();
        uint256 amount = balance - spokenFor;

        insuranceFund = 0;
        undistributedYield = 0;
        // The stream has no funds behind it any more; leaving it running would let a
        // re-attached manager accrue against nothing. Detachment is one-way, so this is
        // belt and braces - but a counter that outlives its balance is how round 6b's
        // strand started.
        yieldRate = 0;
        streamEndsAt = 0;
        // **The one insurance write whose direction inverts, so it is the one that matters most.**
        // Every other writer that skipped this left the pool's `insuranceCover` stale-*low*, which
        // over-reserves and under-pays a leaver - conservative, and wrong in the safe direction.
        // This one takes the fund to zero, so a stale mirror leaves cover the manager no longer
        // has standing in front of the pool's reserve, and exits price too high against an
        // impairment that is now uncovered.
        _pushLossReserves();

        usdc.forceApprove(live, amount);
        ICreditManager(live).fundInsurance(amount);
        usdc.forceApprove(live, 0);

        uint256 delivered = balance - usdc.balanceOf(address(this));
        if (delivered != amount) revert LiquidityNotDelivered(amount, delivered);
        emit ReservesMigrated(live, amount);
    }

    /// @notice Retry placing deferred losses once the pool can accept them.
    /// @dev Permissionless: it only ever moves an already-recognised loss to where it
    ///      belongs. This is the Phase-4 seam - a live pool, no redeploy, no migration.
    ///      Unlike the internal path this one *reverts* when the pool refuses, because
    ///      a caller who explicitly asked for a flush wants to know it failed.
    function flushSocialisedLoss() external nonReentrant {
        uint256 amount = unsocialisedLoss;
        if (amount == 0) revert NothingToSettle();
        address pool = lenderPool;
        if (pool == address(0)) revert LenderPoolUnset();

        // The counter can only fill against a pool that was the liquidity source, and this refuses
        // if that is no longer true. Belt to `_socialise`'s braces: it stops a backlog banked
        // against one funder being settled against whoever replaced it.
        if (pool != liquiditySource) revert LossNotThisPools(liquiditySource, pool);

        unsocialisedLoss = 0;
        try ILenderPool(pool).socialiseLoss(amount) returns (uint256 absorbed) {
            // A pool that takes only part of it has not settled the rest. Zeroing the counter
            // before the call and restoring it only in the `catch` meant a partial success wiped
            // the difference - the caller asked to place a loss and was told it was placed.
            if (absorbed < amount) {
                unsocialisedLoss = amount - absorbed;
                emit LossDeferred(amount - absorbed, unsocialisedLoss);
            }
            if (absorbed == 0) revert SocialisationRejected(amount);
            emit LossSocialised(pool, absorbed);
        } catch {
            unsocialisedLoss = amount;
            revert SocialisationRejected(amount);
        }

        // Drop the pool's mirror of the counter in the same call that drained it. Without this the
        // pool would keep reserving against a loss it has now actually taken, double-counting it
        // in the exit price - and the flush would move the price after all, in the direction that
        // punishes whoever is still there.
        _pushLossReserves();
    }

    /// @dev Best-effort by necessity. This call sits in the middle of a liquidation, which
    ///      must not be blockable by anything the pool does - and the pool can refuse for
    ///      reasons that have nothing to do with this position: it may be unset, it may not
    ///      recognise this manager as its `creditManager`, or a future pool may add a
    ///      condition of its own. What it fails to place is *remembered*, not swallowed -
    ///      the round-4 lesson about guards that assume their own escape hatch is
    ///      reachable, applied before rather than after it bites.
    ///
    ///      It also has to *measure* what the pool took rather than infer it from the absence of a
    ///      revert. The pool clamps a write-down to what it has actually lent, so it can accept a
    ///      call and absorb none of it - which is precisely the state the deploy script ships,
    ///      since the pool is wired as the loss sink while the treasury is still the liquidity
    ///      source. Treating that as a full placement erased real bad debt from every counter in
    ///      the protocol, including this one, whose entire purpose is that an unplaceable loss
    ///      stays visible. Every other value-moving call in this contract already measures
    ///      delivery; this was the one that assumed it.
    ///      **Audit round 11: only the balance sheet that funded the principal may be charged.**
    ///      `unsocialisedLoss` recorded an amount and not whose money it was, `flushSocialisedLoss`
    ///      is permissionless, and `socialiseLoss` moves no USDC - so a loss banked in one era
    ///      could be pointed at whoever held shares in the next. An executed PoC turned 5,000e6
    ///      into 6,250e6 with an exactly matching loss to a lender who had been there throughout.
    ///
    ///      The fix is narrower than it first looks, because the counter should never have filled
    ///      in that era at all. `TreasuryLiquiditySource` implements no `socialiseLoss`: while the
    ///      treasury funds the book it bears a default by simply never being repaid. Recording the
    ///      same loss here as well was a **double count** - once against the treasury's capital,
    ///      once as a placeable claim on a pool that had lent nothing.
    ///
    ///      So the loss is offered only to a pool that is also the liquidity source, and otherwise
    ///      it is not deferred, it is reported as already borne. No write-off function is needed to
    ///      unwind it, because nothing untrue is written down; and there is no migration deadlock,
    ///      because the counter can now only ever hold loss the pool itself funded.
    ///
    ///      `setLiquiditySource` refuses while any principal is out, so the source cannot change
    ///      under a live loan and "who funded this" is never ambiguous. That guard is what makes
    ///      the current pointer a sound proxy for provenance here; without it this check would be
    ///      reading today's configuration to answer a question about yesterday's money.
    function _socialise(uint256 amount) private {
        address pool = lenderPool;
        if (pool != liquiditySource || pool == address(0)) {
            emit LossBorneByTheSource(liquiditySource, amount);
            return;
        }

        try ILenderPool(pool).socialiseLoss(amount) returns (uint256 absorbed) {
            if (absorbed != 0) emit LossSocialised(pool, absorbed);
            if (absorbed >= amount) return;
            amount -= absorbed;
        } catch {}

        unsocialisedLoss += amount;
        emit LossDeferred(amount, unsocialisedLoss);
        _pushLossReserves();
    }

    /// @dev Mirror the two book-level figures the pool prices exits against: a loss recognised here
    ///      but not yet absorbed there, and the insurance fund standing in front of the live
    ///      impairments.
    ///
    ///      **This is what makes `flushSocialisedLoss` economically boring.** A deferred loss that
    ///      the exit price does not yet carry is a discontinuity, and the flush is permissionless,
    ///      so its caller would choose the block that discontinuity lands in. Pushed here, the
    ///      backlog is already in the exit price the moment it is recognised, and the later flush
    ///      only moves it from one term to another - the leaver is paid the same either side of it.
    ///      What the caller can no longer choose is a moment when the price is about to move.
    ///
    ///      Best-effort, like `_socialise` itself. Every caller sits inside a liquidation or a
    ///      repayment path that the pool must not be able to block, and the pool's own setter is
    ///      total, so a `catch` here means a misconfigured pointer rather than a reachable state.
    function _pushLossReserves() private {
        address pool = lenderPool;
        if (pool == address(0)) return;
        try ILenderPool(pool).setLossReserves(unsocialisedLoss, insuranceFund) {} catch {}
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc ICreditManager
    /// @dev Staleness is deliberately not gated here: liquidations must keep pricing
    ///      on the last known NAV (PRD §4.6). Only `borrow` refuses on stale.
    ///
    ///      Prices the position against `currentDebtOf`, not the stored `debtOf`.
    ///      Unsettled yield has already been earned and is already backed by USDC
    ///      sitting in this contract; reporting a position against a debt that yield
    ///      has paid down is how a keeper ends up queueing a liquidation that a
    ///      permissionless `settle` would have cleared for free.
    function currentLtvBps(address borrower) external view returns (uint256) {
        return LtvMath.ltvBps(currentDebtOf(borrower), vault.collateralValue(borrower));
    }

    /// @inheritdoc ICreditManager
    /// @dev A view for keepers and the UI. It divides twice, so a position a fraction
    ///      of a bp past the threshold still reports exactly 1e18. Phase 3's
    ///      `liquidate` must compare with `LtvMath.exceedsLtv` rather than read this -
    ///      and must settle first, so that comparison sees the same debt this does.
    function healthFactor(address borrower) external view returns (uint256) {
        return LtvMath.healthFactor(currentDebtOf(borrower), vault.collateralValue(borrower));
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev The whole accumulator, in one place.
    ///
    ///      A position is owed `bonds x (accYieldPerBond - itsIndex)`. Settling pays
    ///      that against debt first and the remainder to claimable, then moves the
    ///      index up to the current accumulator so the same yield cannot be counted
    ///      twice. Setting the index for a position that has never been seen is what
    ///      makes a first deposit start from now rather than from genesis.
    function _settle(address borrower, uint256 bonds) private {
        // Detached, `bonds` is a number this contract no longer governs, so pricing a
        // position against it would mint entitlement out of a stale accumulator. A
        // silent no-op rather than a revert, so that `repay` and `claimSurplus` keep
        // working through a migration - exits must never depend on wiring.
        if (vault.creditManager() != address(this)) return;

        _accrue();

        // The index is stamped even at zero bonds, and that is load-bearing rather
        // than incidental: the vault calls this with the balance BEFORE the change, so
        // a first-time depositor's call arrives with `bonds == 0`, and stamping it
        // there is exactly what stops them claiming the whole historical accumulator.
        //
        // Stamping at zero cannot burn an entitlement either, because the vault
        // settles before every one of the four paths that lowers a bond count, so a
        // position's earnings are always paid out while it still holds the bonds that
        // earned them. That ordering is the invariant this relies on - if a bond count
        // ever moves without a settle in front of it, this becomes a real loss.
        uint256 acc = accYieldPerBond;
        uint256 owed = _pending(borrower, bonds);
        yieldIndexOf[borrower] = acc;
        if (owed == 0) return;

        uint256 debt = debtOf[borrower];
        uint256 reduced = owed > debt ? debt : owed;
        uint256 overflow = owed - reduced;

        if (reduced != 0) {
            debtOf[borrower] = debt - reduced;
            totalDebt -= reduced;
            pendingPrincipal += reduced;
        }
        if (overflow != 0) {
            claimableOf[borrower] += overflow;
            totalClaimable += overflow;
        }
        emit YieldApplied(borrower, reduced, overflow);

        // **The mark is made of the debt, so it has to move when the debt does - and this was the
        // one debt-writing path that never said so.** Audit round 13 added the identical refresh to
        // `_repay`, reasoning that its enumeration had asked "how does an auction end" when the
        // question is "what changes the number the mark is made of". Yield application changes it,
        // and the same enumeration missed the sibling. Audit round 16 executed the consequence: the
        // stream can pay a liquidated borrower's debt to zero while the pool goes on reserving the
        // whole of it.
        //
        // **Gated on `reduced != 0`, which is the only branch that moves the number.** A yield
        // overflow lands in `claimableOf` and leaves the debt alone; a settle at zero pending does
        // nothing at all. So this costs nothing on the ordinary deposit, withdraw and transfer
        // paths, which is where `_settle` is otherwise hot - the vault calls it on every bond-count
        // change, twice on a transfer.
        //
        // **This does not make the mark self-maintaining and is not meant to.** Nothing has to
        // settle a liquidated borrower, so a mark can still go stale on the clock with no
        // transaction naming them; `refreshImpairments` is the answer to that and this is the
        // answer to "somebody touched the position and the mark did not follow". Two different
        // problems, and only one of them has a transaction to hang a fix on.
        //
        // Safe here despite `settle` and `settleForVault` deliberately carrying no `nonReentrant`:
        // `_setImpairment` is `try`/`catch`ed, and both pool entry points it can reach write two
        // slots and emit, with no outbound call to hand control anywhere.
        if (reduced != 0) {
            _setImpairment(borrower, _impairmentFor(borrower));
            _pushLossReserves();
        }
    }

    function _pending(address borrower, uint256 bonds) private view returns (uint256) {
        if (bonds == 0) return 0;
        uint256 delta = _projectedAcc() - yieldIndexOf[borrower];
        if (delta == 0) return 0;
        return (bonds * delta) / ACC_PRECISION;
    }

    /// @dev Moves the elapsed slice of the stream out of the undistributed pot and
    ///      into the accumulator.
    ///
    ///      The integral is exact rather than approximated, because the bond total is
    ///      piecewise constant between calls: every path that changes a bond count
    ///      goes through the vault, and the vault settles first, which lands here. So
    ///      each slice is `elapsed x rate` spread over the total that was actually
    ///      staked for that slice.
    ///
    ///      With nothing staked, the slice is routed to the insurance fund rather than
    ///      retained. Retaining it looks kinder but is not: the pot would be re-rated
    ///      across whatever bond base exists at the *next* distribution, so after a
    ///      mass exit a single bond deposited before the next epoch captures the whole
    ///      previous cohort's yield. Time nobody was staked for must not become a
    ///      windfall for whoever arrives next, and the insurance fund is the one
    ///      destination with no individual claimant - it stays inside the protocol and
    ///      inside the solvency invariant, which a burn would not.
    function _accrue() private {
        uint256 endAt = block.timestamp < streamEndsAt ? block.timestamp : streamEndsAt;
        uint256 last = lastAccrualAt;
        if (endAt <= last) return;

        uint256 bonds = vault.totalBondCount();
        if (bonds == 0) {
            uint256 skipped = ((endAt - last) * yieldRate) / ACC_PRECISION;
            uint256 held = undistributedYield;
            if (skipped > held) skipped = held;
            if (skipped != 0) {
                undistributedYield = held - skipped;
                insuranceFund += skipped;
                emit UnstakedSliceToInsurance(skipped);
                // The fifth insurance writer, and the one easiest to miss because it is not on a
                // liquidation path at all. Reached only when nothing is staked and only when a
                // slice is actually skipped, so this is not a per-accrual external call.
                _pushLossReserves();
            }
            lastAccrualAt = endAt;
            return;
        }

        uint256 amount = ((endAt - last) * yieldRate) / ACC_PRECISION;
        // The rate is derived from the pot by integer division, so it can never
        // outrun it; clamp anyway rather than let rounding underflow the counter.
        uint256 pot = undistributedYield;
        if (amount > pot) amount = pot;

        lastAccrualAt = endAt;
        if (amount == 0) return;

        undistributedYield = pot - amount;
        uint256 acc = accYieldPerBond + (amount * ACC_PRECISION) / bonds;
        accYieldPerBond = acc;
        emit YieldAccrued(amount, acc, bonds);
    }

    /// @dev What `accYieldPerBond` would be if `_accrue` ran right now. Views must use
    ///      this, or `pendingYieldOf` and `currentDebtOf` would under-report between
    ///      interactions and a keeper would liquidate against a debt the stream has
    ///      already paid down.
    function _projectedAcc() private view returns (uint256) {
        uint256 endAt = block.timestamp < streamEndsAt ? block.timestamp : streamEndsAt;
        uint256 last = lastAccrualAt;
        if (endAt <= last) return accYieldPerBond;

        uint256 bonds = vault.totalBondCount();
        if (bonds == 0) return accYieldPerBond;

        uint256 amount = ((endAt - last) * yieldRate) / ACC_PRECISION;
        uint256 pot = undistributedYield;
        if (amount > pot) amount = pot;

        return accYieldPerBond + (amount * ACC_PRECISION) / bonds;
    }

    /// @dev Clamps before pulling. Pulling `amount` and crediting `min(amount, debt)`
    ///      would strand the excess here as unbacked balance.
    function _repay(address payer, address borrower, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        _settle(borrower, vault.bondCount(borrower));
        uint256 debt = debtOf[borrower];
        if (debt == 0) revert NoDebt();

        uint256 paid = amount > debt ? debt : amount;
        debtOf[borrower] = debt - paid;
        totalDebt -= paid;
        pendingPrincipal += paid;
        emit Repaid(borrower, paid);

        // **The mark is the debt, so it has to move when the debt does.** Audit round 13.
        //
        // The six notification sites were all auction transitions, derived from "how does a
        // liquidation end". Repaying is not a transition and notifies nobody - and `repayFor` is
        // permissionless, so a stranger can cure a liquidated borrower's debt entirely while the
        // pool goes on reserving the whole of it. The permissionless `serviceQueue` then settles a
        // queued lender against a shortfall that no longer exists, and a later `refreshImpairment`
        // releases the mark into the share price of whoever stayed.
        //
        // `LiquidationAuction.workoutSettle` already refreshes on exactly this reasoning, for a
        // tranche that pays real debt down. This is the same event one contract over, and the set
        // was enumerated from the wrong question: not "how does an auction end" but "what changes
        // the number the mark is made of".
        //
        // Cheap when it does not apply - `_impairmentFor` returns early with no external calls
        // when no auction is wired, and `_setImpairment` is a no-op at zero against a pool that
        // holds no mark.
        _setImpairment(borrower, _impairmentFor(borrower));
        _pushLossReserves();

        usdc.safeTransferFrom(payer, address(this), paid);
    }
}
