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
    error Detached(address liveManager);
    error NotLiquidationAuction();
    error LiquidationAuctionUnset();
    error LenderPoolUnset();
    error PositionHealthy(uint256 ltvBps);
    error SocialisationRejected(uint256 amount);
    error AuctionHasLiveWork(uint256 outstanding);
    error AuctionPointerMismatch(address manager, address vault);
    error WorkoutOpen(address borrower);
    error StillAttached();
    error LiquidationAuctionVaultMismatch(address auctionVault);

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
    /// @dev Public because a loss that cannot be placed must be *visible*. Until Phase 4
    ///      there is no pool to socialise into, and `LenderPool.socialiseLoss` reverts
    ///      by design - so the alternative to this counter is either a liquidation that
    ///      cannot complete or a loss that is silently dropped. Same shape as
    ///      `EpochHarvester.pendingLenderYield`, adopted for the same reason.
    uint256 public unsocialisedLoss;

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
    function setLiquiditySource(address liquiditySource_) external onlyOwner {
        if (liquiditySource_ == address(0)) revert ZeroAddress();
        if (totalDebt != 0 || pendingPrincipal != 0) revert DebtOutstanding(totalDebt);
        liquiditySource = liquiditySource_;
        emit LiquiditySourceSet(liquiditySource_);
    }

    function setLenderPool(address lenderPool_) external onlyOwner {
        if (lenderPool_ == address(0)) revert ZeroAddress();
        lenderPool = lenderPool_;
        emit LenderPoolSet(lenderPool_);
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
    function fundInsurance(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        insuranceFund += amount;
        emit InsuranceFunded(msg.sender, amount);
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

        unsocialisedLoss = 0;
        try ILenderPool(pool).socialiseLoss(amount) {
            emit LossSocialised(pool, amount);
        } catch {
            unsocialisedLoss = amount;
            revert SocialisationRejected(amount);
        }
    }

    /// @dev Best-effort by necessity. `LenderPool.socialiseLoss` reverts `NotImplemented`
    ///      until Phase 4 and the deploy script wires exactly that pool, so a hard call
    ///      here would sit in the middle of a liquidation that must not be blockable.
    ///      What it fails to place is *remembered*, not swallowed - the round-4 lesson
    ///      about guards that assume their own escape hatch is reachable, applied
    ///      before rather than after it bites.
    function _socialise(uint256 amount) private {
        address pool = lenderPool;
        if (pool != address(0)) {
            try ILenderPool(pool).socialiseLoss(amount) {
                emit LossSocialised(pool, amount);
                return;
            } catch {}
        }
        unsocialisedLoss += amount;
        emit LossDeferred(amount, unsocialisedLoss);
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

        usdc.safeTransferFrom(payer, address(this), paid);
    }
}
