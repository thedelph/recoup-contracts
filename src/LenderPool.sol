// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC20, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "./Config.sol";
import {ILenderPool} from "./interfaces/ILenderPool.sol";

/// @title LenderPool (PRD §4.2)
/// @notice ERC-4626 vault over native USDC. Lends to CreditManager only. Share price rises with
///         the lender share of harvested yield, and **falls when a shortfall is socialised** -
///         after the liquidation auction and the insurance fund have both been exhausted. That
///         second sentence is the whole risk of being a lender here and the lender docs must say
///         so at least as plainly as this comment does.
/// @dev Built at Phase 4. What follows is the reasoning behind the five decisions that are not
///      forced by the spec, because each of them is a place where the obvious implementation is
///      subtly worse.
///
///      **1. A queued withdrawal keeps its shares live, and that is the point.** The obvious
///      design burns shares at request time and records a fixed USDC claim. It is simpler, and it
///      hands the first lender out of the door a way to escape a loss that has not landed yet: see
///      trouble, queue, stop being exposed, and let whoever is behind you absorb your share of it.
///      That is precisely the incentive that turns a wobble into a run. Here a request **escrows**
///      the shares instead. They stay outstanding, keep earning yield and stay fully exposed to
///      socialised loss until the moment they are actually paid, so leaving early buys a place in
///      the queue and nothing else. The amount owed therefore moves with the share price, which is
///      why `queuePosition` reports assets computed at read time rather than a number fixed at
///      request time.
///
///      **2. `withdraw` and `redeem` never silently become an IOU.** They are ERC-4626 standard
///      and immediate, and `maxWithdraw` reports what can genuinely be taken right now. If the
///      idle balance is short they revert, and the lender chooses to queue by calling
///      `requestWithdrawal`. Quietly converting "withdraw" into "you are 14th in line" would make
///      `maxWithdraw` a lie to every integrator that reads it, and would put a lender into a queue
///      they never asked to join.
///
///      **The yield leg is streamed, not stepped**, for the same family of reasons: see
///      `distributeYield`. An epoch that landed on the share price at once was free money for
///      anyone who deposited in the block that delivered it.
///
///      **3. One outstanding request per lender.** A second one is refused rather than appended.
///      Appending to an existing entry would let new shares inherit an old queue position, which
///      is queue-jumping with extra steps; giving each request its own entry makes
///      `queuePosition` an unbounded scan and lets one address flood the queue. Cancelling and
///      re-queueing is always available and costs the lender their place, which is the honest
///      price of changing their mind.
///
///      **4. Exits are priced, not refused, and this one was arrived at the long way round.**
///      Audit round 10's finding 7 was that `outstandingPrincipal` carries a doomed loan at face
///      value for the whole of `AUCTION_DURATION` and up to `WORKOUT_MAX_DURATION`, so until
///      `writeDownLoss` fires the share price says nothing has gone wrong and a lender watching the
///      auction can take the hot float out at that pre-loss price. The first answer was a gate: a
///      public predicate that asked the manager, and then the manager's auction, whether a loss
///      could still land, and refused the ERC-4626 exits for as long as one could.
///
///      Audit round 11 found the gate covered `withdraw`, `redeem`, `maxWithdraw` and `maxRedeem` -
///      the complete set of ERC-4626 exits and *not* the complete set of ways USDC leaves this
///      contract, because `requestWithdrawal`, `serviceQueue` and `claim` are all permissionless
///      and compose in one transaction. The gate was extended to `serviceQueue`; then three
///      independent research passes found the shape itself was wrong. **No surveyed lending
///      protocol ships an exit freeze** - not Maple, Aave, Euler, Morpho, Gearbox, Goldfinch,
///      Centrifuge, Clearpool, TrueFi or Notional - and a *sized* gate needs the auction's clearing
///      price, which is the auction's unresolved output, so any safe bound collapses to "reserve
///      the whole distressed loan". That is impairment with a 100% haircut, which is this.
///
///      So the recognition gap is narrowed instead of the door being shut: `CreditManager` marks
///      the expected shortfall in the moment the auction opens, and a leaver is paid on
///      `exitAssets()`, which already carries it. Entries stay on `totalAssets()` - see
///      `previewRedeem` and `exitAssets` for why that asymmetry is the mechanism rather than an
///      inconsistency, and for the Maple source it was verified against.
///
///      **This used to say "there is nothing left to run from, so there is no reason to stop
///      anybody", and audit round seventeen executed it as false.** The mark does not exist until
///      somebody calls `liquidate`, and until round seventeen the protocol paid that caller
///      nothing whenever the sale came in short of the debt - so recognition was gated on an
///      unrewarded volunteer, and every exit before one appeared was priced at the full pre-loss
///      figure. That sentence is what justified deleting the round-ten exit gate, so it is worth
///      being exact about what replaced it.
///
///      What is true now: `liquidate` is permissionless and carries a bounty the borrower prepaid
///      at `borrow`, so the volunteer is paid for the work whatever the sale fetches. **The window
///      is bounded by transaction ordering rather than by whether anyone volunteers. It is not
///      zero.** The loss-creating event is a public `postNav`, and an exiter can back-run it and
///      out-bid the liquidator for position in the same block. No calibration of that bounty
///      closes an ordering race, and nothing here should be read as claiming it does.
///
///      **"A leaver" here means the ERC-4626 exits, and since audit round 15 it does not include
///      the queue.** `serviceQueue` refuses to crystallise a live entry while any reserve stands,
///      so it pays the un-impaired price or it pays nobody, and the marked-down number it used to
///      pay is unreachable. Audit round 16 found four places in this file still saying otherwise.
///      **The design consequence is that during a mark, queueing strictly dominates withdrawing** -
///      the opposite of what this decision set out to create - and that is an open item against the
///      forced-exit pricing work rather than something a comment can fix.
///
///      **What "matching Maple" does NOT cover, and it is the half that matters here.** Three
///      independent research passes checked this after round 14 and agreed: Maple's queue
///      processor is *permissioned*. Its `processRedemptions` is callable only by a designated
///      redeemer, the pool delegate or an operational admin, and Maple's own contract reference
///      says the queue manager "will only be used in permissioned pools, not public pools to avoid
///      denial of service attacks". So Maple never lets an arbitrary party choose the instant at
///      which somebody else's shares are valued.
///
///      This pool took Maple's pricing formula and kept a fully permissionless `serviceQueue`.
///      That substitution is deliberate - a queue that needs a keeper is not an exit - but it means
///      **the precedent supports the price and not the timing**, and the timing is where the open
///      finding lives. Do not read "matching Maple" anywhere in this file as covering who may call.
///
///      **The gate's deletion also removed the last external call this contract makes to anything
///      other than USDC**, which is round 11's other complaint about it answered in full:
///      the gate read the manager and then the auction, three unguarded typed calls sitting
///      on the only ERC-4626 exit, with no owner escape while principal was out
///      (`setCreditManager` refuses at `outstandingPrincipal != 0`). A reverting auction would have
///      bricked every exit in the pool. The impairment is *pushed* in and stored locally, so every
///      pricing path here reads storage and nothing else.
///
///      **5. `is ILenderPool` is a compiler check, not documentation.** Audit round 11 found this
///      contract implementing that interface by intention alone, and both protocol call sites into
///      it - `EpochHarvester._tryDeliverLenderYield` and `CreditManager._socialise` - wrap the call
///      in a `catch`, so a signature that had drifted apart would surface as a silently deferred
///      payment rather than a failed build. It had already happened: the published `ILenderPool`
///      carried `YieldDistributed(uint256)` while this contract emitted three parameters, and a
///      different arity is a different `topic0`, so an indexer built from that ABI saw no yield
///      events at all. The shared events are therefore declared in the interface and **not**
///      re-declared here - Solidity rejects the duplicate, which is precisely the property being
///      bought. What is left below is what this contract does *beyond* the interface: its wiring
///      setters, its yield-stream freeze, and its pull-payment claim. See `ILenderPool`'s header
///      for the rule that decides which side a new event belongs on.
contract LenderPool is ERC4626, ILenderPool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotCreditManager();
    error NotEpochHarvester();
    error ZeroAddress();
    error ZeroAmount();
    error RenounceDisabled();
    error DepositCapTooLarge(uint256 given, uint256 max);
    error DepositCapExceeded(uint256 requested, uint256 remaining);
    error InsufficientLiquidity(uint256 requested, uint256 availableNow);
    error AlreadyQueued(uint256 index);
    error NothingQueued();
    error QueueIsEmpty();
    error NothingToService();
    /// @notice The paying walk stopped because a loss reserve stands against the book, not because
    ///         the pool is short of cash.
    /// @param standingReserve `exitReserve()` at the moment of the refusal.
    error QueueHeldByReserve(uint256 standingReserve);
    error NoSharesOutstanding();
    error PrincipalOutstanding(uint256 outstanding);
    error ImpairmentOutstanding(uint256 totalImpairment);
    error YieldExceedsCapital(uint256 amount, uint256 capital);
    error NothingToClaim();
    /// @notice A bounded `redeem` was paid less than the caller said they would accept.
    error AssetsBelowMinimum(uint256 assets, uint256 minAssetsOut);
    /// @notice A bounded `withdraw` would have cost more shares than the caller said they would pay.
    error SharesAboveMaximum(uint256 shares, uint256 maxSharesIn);

    // Everything this contract emits that `ILenderPool` describes is declared *there*, including
    // `YieldDistributed`, `Impaired`, `ImpairmentReleased`, `LossReservesSet` and the four queue
    // events. Re-declaring any of them here would not compile, which is the point - see decision 5
    // in the header. What remains below is machinery the interface does not promise.

    event CreditManagerSet(address indexed creditManager);
    event EpochHarvesterSet(address indexed epochHarvester);
    event DepositCapSet(uint256 previous, uint256 current);
    /// @notice The stream stopped because the last share was burned; the remainder is held.
    /// @dev Local, not interface: `ILenderPool` promises that a delivered epoch reaches the share
    ///      price over a window, and says nothing about *how* the pot is held. Freezing it when the
    ///      pool empties is this implementation's answer, emitted from `_update` rather than from
    ///      any function the interface declares.
    event YieldStreamFrozen(uint256 unreleased);
    /// @notice A serviced receiver collected what was set aside for them.
    /// @dev Local for the same reason: `claim()` and `claimable` are this pool's pull-payment
    ///      mechanism and appear nowhere in `ILenderPool`, which stops at
    ///      `QueuedWithdrawalServiced`.
    event WithdrawalClaimed(address indexed receiver, uint256 assets);

    /// @dev How far one call may walk the head over cancelled entries. See `_advanceHeadPastEmpties`.
    uint256 private constant MAX_HEAD_ADVANCE = 64;

    /// @dev Fixed-point scale for `yieldRate`, matching `CreditManager.ACC_PRECISION`. An unscaled
    ///      rate in USDC-wei per second floors to zero whenever the pot is smaller than the number
    ///      of seconds it is spread over, and `YIELD_STREAM_DURATION` is 432,000 of them: a
    ///      `MIN_EPOCH_YIELD` epoch delivers a quarter of 1e6 to this leg, which is under one wei
    ///      per second. The whole stream would round away.
    uint256 private constant ACC_PRECISION = 1e18;

    /// @dev The smallest share supply an epoch may be delivered into.
    ///
    ///      **Audit round 11: `totalSupply() == 0` was the wrong threshold.** `_decimalsOffset()`
    ///      is 3, so every conversion runs against 10^3 virtual shares that nobody holds and no
    ///      function here can sweep. One wei of real shares therefore cleared the old guard while
    ///      owning about a thousandth of the pool, so a permissionless flush could stream an entire
    ///      epoch's lender share into the virtual claim, unrecoverably - and
    ///      `_tryDeliverLenderYield` decrements `pendingLenderYield` by what left, so the harvester
    ///      stopped owing it too.
    ///
    ///      Derived rather than picked: at `10 ** offset * BPS` the virtual shares are under one
    ///      basis point of supply, so the leak is bounded by the rounding this contract already
    ///      tolerates everywhere else. In USDC terms that is a hundredth of a dollar of deposits,
    ///      which is not a real barrier to a genuine pool.
    uint256 private constant MIN_SUPPLY_FOR_YIELD = (10 ** 3) * Config.BPS;

    address public creditManager;
    address public epochHarvester;

    /// @notice Ceiling on cumulative lender deposits, in USDC.
    /// @dev Settable by the owner, which is a `TimelockController` in production. It lives here
    ///      rather than in `RiskParams` because it is a *yield* figure rather than a risk one, and
    ///      because `maxDeposit` below is an ERC-4626 override that the standard forbids from
    ///      reverting - so it must not depend on an external call.
    ///
    ///      It used to be `Config.LENDER_POOL_DEPOSIT_CAP`, aliased by `=` to the global borrow
    ///      cap. That alias could not survive the cap becoming storage: a Solidity constant cannot
    ///      be defined in terms of a storage value, so it would have silently frozen at the launch
    ///      figure through every ratchet step. The ratchet still moves the two together; it now
    ///      does so by naming both.
    uint256 public depositCap;

    /// @notice USDC currently lent out, carried at face value less socialised loss.
    uint256 public outstandingPrincipal;

    /// @notice Cumulative loss written down against the pool, for disclosure. Never decreases.
    uint256 public lifetimeSocialisedLoss;

    /// @notice Cumulative money that came back on a loss already written down here, for
    ///         disclosure. Never decreases either.
    /// @dev **A sibling counter rather than a subtraction from the one above**, and audit round 21
    ///      is why the distinction is worth a line: `lifetimeSocialisedLoss` is what lenders
    ///      actually took, and netting a later recovery into it would erase the fact that they took
    ///      it. `invariant_lifetimeSocialisedLossOnlyRisesOnALoss` asserts that counter is
    ///      monotone; this one carries the other half so the pair still answers "how much of it
    ///      came back" without either of them lying.
    uint256 public lifetimeLossRecovered;

    /// @notice The size of the pot the current stream is releasing. **Not** the amount still owed.
    /// @dev The USDC is already in this contract's balance; holding it out of `totalAssets()` until
    ///      time has passed is what makes the stream a stream. See `distributeYield` for why.
    ///
    ///      Read `unreleasedYield()` instead unless you specifically want the pot. This value is
    ///      only rewritten when a stream is rated or frozen, so once a stream runs dry it stays at
    ///      the last pot size while nothing is owed - the release is computed from the clock, not
    ///      by decrementing here.
    uint256 public pendingYield;

    /// @notice Release rate of `pendingYield`, in USDC-wei per second scaled by `ACC_PRECISION`.
    uint256 public yieldRate;

    /// @notice When `pendingYield` was last crystallised, i.e. the point `unreleasedYield()`
    ///         measures elapsed time from.
    uint256 public lastYieldAccrualAt;

    /// @notice When an epoch was last delivered. Sets the accrual window the next stream is rated
    ///         over, so it is deliberately separate from `lastYieldAccrualAt`.
    uint256 public lastYieldDistributeAt;

    /// @notice When the current stream runs dry.
    uint256 public yieldStreamEndsAt;

    /// @notice Reserved shortfall for a borrower whose position is being liquidated or worked out.
    /// @dev Keyed by borrower because `LiquidationAuction.auctionOf` already enforces one live
    ///      auction each, and because the borrower is the identifier every `CreditManager` entry
    ///      point already carries - keying by auction id would force `writeDownLoss` to learn one
    ///      it never sees.
    mapping(address => uint256) public impairmentOf;

    /// @notice Sum of `impairmentOf`. The only impairment figure the pricing path reads.
    /// @dev A single slot on purpose: exit pricing must not iterate, and it must not make an
    ///      external call. Audit round 11 found the round-10 gate had put three unguarded external
    ///      calls on the only ERC-4626 exit, with no owner escape while principal was out. With the
    ///      gate deleted this contract calls nothing but USDC, and this slot is what allows that.
    uint256 public totalImpairment;

    /// @notice Every borrower currently carrying a non-zero mark.
    /// @dev **The map had no key list, and audit round 16 is what that cost.** A mark is a
    ///      photograph of `currentDebtOf`, which decays on the yield stream with no transaction to
    ///      hang a refresh on, so a stale one is routine rather than exotic. Clearing it means
    ///      calling `CreditManager.refreshImpairment(borrower)` - and until this existed there was
    ///      no way to learn `borrower` except by reconstructing it from `Impaired` logs off-chain.
    ///      A remedy that needs event archaeology is a remedy only its author will ever run.
    ///
    ///      It also makes `totalImpairment` auditable for the first time. That slot is a running
    ///      `total + amount - previous`, and nothing in the tree could check it against the map it
    ///      claims to sum, because the map could not be walked.
    ///
    ///      **O(1) and allocation-free at both ends, and that is a hard requirement rather than an
    ///      optimisation.** `impair` and `releaseImpairment` sit on `expireToWorkout`, the exit of
    ///      last resort, and an exit a lender pool can brick is not an exit. The index-plus-one map
    ///      plus swap-pop is the same shape `_requestIndexPlusOne` already uses here, so there is
    ///      one idiom in this file rather than two.
    ///
    ///      Never read by the pricing path. `totalImpairment` is still the only impairment figure
    ///      `exitReserve` touches, so nothing here puts a loop anywhere near an exit.
    address[] private _impairedBorrowers;
    mapping(address => uint256) private _impairedIndexPlusOne;

    /// @notice A loss the manager has recognised on its books that this pool has not absorbed yet.
    /// @dev **The second trigger the round-10 exit gate had, and the one the per-borrower
    ///      impairment does not cover.** That gate fired on `CreditManager.unsocialisedLoss != 0`
    ///      as well as on a live auction, and for a reason the auction mark cannot reach: a
    ///      recognised loss outlives the auction *and* the workout that produced it, and
    ///      `flushSocialisedLoss` is permissionless. Without this term, deleting the gate would have
    ///      left a public counter everybody can read while the share price still said nothing had
    ///      happened, and whoever read it first would leave at the old price. That is round-10
    ///      finding 7 arriving through a different door, and it is the one branch of the gate that
    ///      had to be rebuilt rather than argued away before the gate could go.
    ///
    ///      Deliberately *not* a sentinel key in `impairmentOf`. The per-borrower map has to carry
    ///      the clean claim "no impairment outlives its auction", and a key that belongs to no
    ///      borrower would quietly falsify it.
    uint256 public unplacedLoss;

    /// @notice The insurance fund standing in front of the live impairments, as the manager last
    ///         reported it.
    /// @dev Netted **once, against the sum**, which is the only way to net a single fund against N
    ///      independent shortfalls without spending it more than once. Netting per borrower - which
    ///      is what a naive reading of the sizing rule gives - under-marks the moment two positions
    ///      are in distress together, and an under-mark is the finding rather than a rounding
    ///      choice.
    ///
    ///      Not netted against `unplacedLoss`: `writeDownLoss` spends insurance first and socialises
    ///      only the remainder, so that figure is already post-insurance and netting it again would
    ///      spend the same dollar twice.
    uint256 public insuranceCover;

    /// @notice Lender capital deposited less lender capital withdrawn. What `maxDeposit` is sized
    ///         from, so a donation cannot close the pool.
    /// @dev Deliberately *not* a valuation. It moves when a lender puts money in or takes money
    ///      out, and when capital is destroyed - never on yield or on a donation - so it is a
    ///      running total of principal still admitted rather than an alias for `totalAssets()`.
    ///      Floored at zero on the way down: once the pool has earned, a withdrawal can exceed what
    ///      was put in.
    ///
    ///      **`socialiseLoss` reduces it, and audit round 12 is why.** This used to say it never
    ///      moved "on yield, loss or donation", and the loss clause was a permanent brick: capital
    ///      written off is decremented by nothing, because it never leaves as a withdrawal, so
    ///      destroyed money went on consuming deposit-cap headroom for good. Enough realised losses
    ///      and `maxDeposit` reaches zero on an immutable contract with no sweep and no rescue -
    ///      the same shape round 11 found by donation, reachable here through ordinary operation.
    ///
    ///      The distinction that keeps this honest: a loss removes principal the pool is holding,
    ///      which is what this counter measures, while yield and donations add value without
    ///      admitting principal. Both directions still refuse to make it a valuation.
    uint256 public netDeposits;

    struct WithdrawalRequest {
        address owner;
        address receiver;
        uint256 shares;
    }

    /// @dev Append-only. `queueHead` walks forward; serviced entries are left in place with zero
    ///      shares rather than deleted, so a queue index stays a stable reference in events.
    WithdrawalRequest[] private _queue;

    /// @notice Index of the next request to be serviced. Everything before it is settled.
    uint256 public queueHead;

    /// @notice Total shares escrowed against outstanding requests.
    uint256 public queuedShares;

    /// @notice USDC a serviced withdrawal has set aside for its receiver to collect.
    /// @dev Pull, not push. `serviceQueue` used to `safeTransfer` straight to the receiver from
    ///      inside the shared FIFO loop, which handed one entry a veto over everybody: USDC on
    ///      Base blacklists, the receiver is chosen freely at request time, the loop always starts
    ///      at the head, and only the entry's own owner may cancel it - so a single request naming
    ///      a blacklisted address reverted every `serviceQueue` call permanently, froze every
    ///      lender behind it, and through `available()` stopped all borrowing. This is the shape
    ///      `CreditManager.creditLiquidationProceeds` and `EpochHarvester.pendingProtocolFee` were
    ///      both already written to avoid, for this exact reason.
    mapping(address => uint256) public claimable;

    /// @notice USDC owed to receivers that has not been collected yet.
    /// @dev Subtracted from lendable and withdrawable balances: it is sitting in this contract but
    ///      it is not the pool's money any more.
    uint256 public totalClaimable;

    /// @dev Queue index of a lender's outstanding request, stored as index+1 so that zero means
    ///      "none". Enforces the one-request-per-lender rule in O(1).
    mapping(address => uint256) private _requestIndexPlusOne;

    constructor(IERC20 usdc_, address initialOwner)
        ERC20("Recoup Lender Pool", "rcUSDC")
        ERC4626(usdc_)
        Ownable(initialOwner)
    {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        // Seeded from the declared default and validated by the same rule every later write goes
        // through, so a pool cannot be deployed in a state its own setter would refuse.
        _setDepositCap(Config.DEFAULT_LENDER_POOL_DEPOSIT_CAP);
        // Seeded, not left at zero. `distributeYield` rates the first stream over the time since
        // this stamp, so a zero would read as an accrual window running from the epoch and stretch
        // the first epoch over decades. `CreditManager` seeds `lastDistributeAt` for the same
        // reason and in the same line of its constructor.
        lastYieldDistributeAt = block.timestamp;
        lastYieldAccrualAt = block.timestamp;
    }

    /// @dev Matches the live-authority contracts: renouncing would permanently freeze wiring.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Move the ceiling on cumulative lender deposits.
    /// @dev No relation to the risk parameters, which is the point of separating it: this decides
    ///      how much lender capital the pool will accept, not how much credit risk the protocol
    ///      will run. Lowering it below `netDeposits` is legal and simply closes the pool to new
    ///      capital - it cannot strand an existing lender, because neither `maxWithdraw` nor
    ///      `requestWithdrawal` reads it.
    ///
    ///      Bounded by `Config.GLOBAL_BORROW_CAP_MAX` for a yield reason rather than a safety one.
    ///      Idle USDC earns nothing and dilutes the rate for everyone in the pool, so a pool
    ///      materially larger than the debt it could ever fund pays everyone less for no extra
    ///      safety, and the debt it could ever fund is bounded by that ceiling.
    function setDepositCap(uint256 cap) external onlyOwner {
        _setDepositCap(cap);
    }

    function _setDepositCap(uint256 cap) private {
        if (cap == 0) revert ZeroAmount();
        if (cap > Config.GLOBAL_BORROW_CAP_MAX) {
            revert DepositCapTooLarge(cap, Config.GLOBAL_BORROW_CAP_MAX);
        }
        emit DepositCapSet(depositCap, cap);
        depositCap = cap;
    }

    /// @notice Shares carry three more decimals than USDC.
    /// @dev The ERC-4626 inflation attack, closed by construction rather than by a bootstrap
    ///      deposit. With a zero offset the first depositor can mint one wei of shares and then
    ///      donate USDC directly to raise the share price, so the second depositor's deposit
    ///      rounds down into the first one's pocket. An offset makes the attacker fund that
    ///      donation 10^3 times over for the same theft, which is what makes it uneconomic. This
    ///      contract's own `distributeYield` is a legitimate donation of exactly that shape, so
    ///      the mechanism is not hypothetical here - it is the normal operation of the pool.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    /// @dev Refused while principal is out on loan, mirroring `CreditManager.setLiquiditySource`,
    ///      which refuses the same swap from the other side and explains why. Only the old manager
    ///      can repay - `repayPrincipal` is gated on this very slot - so repointing mid-loan makes
    ///      the repayment path revert forever. `outstandingPrincipal` would then be frozen above
    ///      zero, and since `totalAssets()` counts it, the share price would permanently overstate
    ///      what the pool can actually pay: early redeemers would take real USDC at a fictional
    ///      price and the lenders left behind would hold the gap.
    ///
    ///      **Also refused while any impairment stands, and audit round 12 is why.** Every piece of
    ///      state this contract holds *about* its manager - `impairmentOf`, `totalImpairment`,
    ///      `unplacedLoss`, `insuranceCover` - survived a repoint, and the outgoing manager could
    ///      no longer clear it: its `_setImpairment` calls land on `NotCreditManager` and are
    ///      swallowed by their own `catch`. `exitReserve()` clamps to `outstandingPrincipal`, which
    ///      this setter already requires to be zero, so the stale reserve is invisible at the
    ///      moment of the swap - and reactivates the first time the new manager lends, marking
    ///      every exit down against a liquidation that belongs to a contract no longer wired in.
    ///
    ///      Refusing rather than clearing, for one reason worth stating: the aggregate could be
    ///      zeroed but the per-borrower entries could not be walked, so a later `impair` would
    ///      compute `totalImpairment + amount - previous` against a stale `previous` and a partial
    ///      clear would be worse than none. **That reasoning survives; the key list added in audit
    ///      round 16 does not change it**, because clearing marks in bulk here would still be this
    ///      contract deciding what the manager's derived figures are.
    ///
    ///      The precondition is reachable and permissionless: detach the outgoing manager from the
    ///      vault, at which point its `_impairmentFor` returns zero for everyone, then
    ///      `refreshImpairment(borrower)` releases each mark - or `refreshImpairments(n)`, which
    ///      needs no borrower address at all.
    ///
    ///      **The order matters and this paragraph used to leave it out, which audit round 16 found
    ///      by executing the wrong one.** The recovery above works only while the *manager* still
    ///      points at this pool. If `CreditManager.setLenderPool` has already moved on, every
    ///      refresh writes to the new pool and nothing can reach this map again; the way back is to
    ///      repoint the manager here, refresh, and only then repoint it away. `setLenderPool` now
    ///      refuses to move while marks stand, which is the mirror of this refusal and is what
    ///      stops that ordering being reachable by accident.
    ///
    ///      `EpochHarvester.setCustodyAdapter` re-seeds its watermark on exactly this reasoning.
    ///      The rule was written into one file and not applied to its sibling: **any state a
    ///      contract carries about a wiring pointer has to be re-derived when that pointer moves.**
    function setCreditManager(address creditManager_) external onlyOwner {
        if (creditManager_ == address(0)) revert ZeroAddress();
        if (outstandingPrincipal != 0) revert PrincipalOutstanding(outstandingPrincipal);
        if (totalImpairment != 0) revert ImpairmentOutstanding(totalImpairment);

        // These two carry no per-borrower component - they are straight mirrors of the outgoing
        // manager's `unsocialisedLoss` and `insuranceFund` - so they can be re-derived rather than
        // refused on. The incoming manager overwrites both on its first `_pushLossReserves`;
        // clearing here is what stops the window in between pricing exits off a manager that is
        // no longer wired in.
        unplacedLoss = 0;
        insuranceCover = 0;
        emit LossReservesSet(0, 0, exitReserve());

        creditManager = creditManager_;
        emit CreditManagerSet(creditManager_);
    }

    /// @notice Point this pool at the harvester whose deliveries it accepts.
    /// @dev **Deliberately unguarded, and that is a governance deferral rather than a claim of
    ///      safety.** Round 11's finding is that this setter is the other half of
    ///      `EpochHarvester.setLenderPool`: pointing this pool away from the live harvester is
    ///      exactly what makes delivery revert `NotEpochHarvester`, and an owner who does that has
    ///      stopped a pool full of depositors from being paid.
    ///
    ///      **The harvester's half is fixed here in code and this half is not, and the asymmetry
    ///      is the whole point.** Over there the undeliverable share is parked against the pool
    ///      that earned it, so it can no longer follow the pointer to a different pool - the money
    ///      cannot be *redirected* by anyone. What is left on this side is only the ability to stop
    ///      it arriving, and there is no guard that closes that without recreating the deadlock
    ///      from the other direction: a check here that reads the harvester's counter refuses
    ///      precisely the repoint that would escape a harvester which can no longer deliver, and
    ///      the only thing that could clear the counter is the delivery being refused. That shape
    ///      has now been hit three times in this codebase and it is recorded rather than rebuilt.
    ///
    ///      So it sits with the go-live governance items, in the same bucket as
    ///      `adapter.setYieldRecipient`: same power (an owner redirecting yield), same stated
    ///      mitigation (owner becomes a `TimelockController` at G1/G2), and the same honest note
    ///      that **the mitigation does not exist yet** - the owner is a plain EOA today. The
    ///      condition making that acceptable is unchanged and is a tripwire, not a comfort: no
    ///      third-party lender funds, nothing on mainnet. Phase 4 breaks it by design.
    function setEpochHarvester(address epochHarvester_) external onlyOwner {
        if (epochHarvester_ == address(0)) revert ZeroAddress();
        epochHarvester = epochHarvester_;
        emit EpochHarvesterSet(epochHarvester_);
    }

    // ── Accounting ───────────────────────────────────────────────────────────

    /// @notice Idle USDC + outstanding principal, less what serviced lenders have yet to collect
    ///         and less yield that has not been released yet.
    /// @dev `totalClaimable` sits in this contract's balance but stopped being the pool's money
    ///      the moment its shares were burned. Counting it would raise the share price by exactly
    ///      the amount owed to somebody else, every time the queue was serviced.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return _poolBalance() + outstandingPrincipal;
    }

    /// @notice Delivered yield still waiting on the clock, projected to this instant.
    /// @dev A pure function of the stream terms, so no state has to be written for the share price
    ///      to move: every read of `totalAssets()` prices the stream forward on its own.
    ///      `CreditManager` needs a matching `_accrue()`/`_projectedAcc()` pair because its
    ///      accumulator is divided by a bond count that changes underneath it; here the share
    ///      price does the apportioning, so there is no base to keep in step and no keeper poke.
    function unreleasedYield() public view returns (uint256) {
        uint256 pending = pendingYield;
        if (pending == 0) return 0;

        // Frozen by `_update`: nothing releases until a new epoch re-rates the pot.
        if (yieldRate == 0) return pending;

        // Finished. The window is the authority on the end of the stream, not the arithmetic that
        // approximates it: `yieldRate` is floored when it is set, so replaying it across the whole
        // window recovers slightly less than the pot and leaves a residual that never reaches
        // zero. A counter that cannot reach zero is how the head of the withdrawal queue wedged
        // this entire pool once already.
        if (block.timestamp >= yieldStreamEndsAt) return 0;

        if (block.timestamp <= lastYieldAccrualAt) return pending;
        uint256 released = ((block.timestamp - lastYieldAccrualAt) * yieldRate) / ACC_PRECISION;
        return released >= pending ? 0 : pending - released;
    }

    /// @dev USDC this contract holds on its own account.
    ///
    ///      **The one choke point for both classes of money that sit here without belonging to
    ///      shareholders.** `totalClaimable` is owed to a lender whose shares are already burned;
    ///      `unreleasedYield()` is owed to whoever holds shares over the coming days rather than to
    ///      whoever holds them now. Subtracting both here is what carries the exclusion into
    ///      `totalAssets`, `unreservedIdle`, `available`, `maxWithdraw`, `maxRedeem` and the
    ///      queue's valuations without any of them having to know about it.
    function _poolBalance() private view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 notOurs = totalClaimable + unreleasedYield();
        return balance > notOurs ? balance - notOurs : 0;
    }

    /// @notice Reserve an expected shortfall against a borrower being liquidated. CreditManager only.
    /// @dev **The replacement for the round-10 exit gate.** Rather than refusing to let anyone
    ///      leave while a loss is unresolved, the pool marks the expected loss into the price a
    ///      leaver receives. Three independent research passes found no lending protocol that
    ///      ships an exit freeze, and Maple ships exactly this: `convertToExitAssets` deducts
    ///      `unrealizedLosses` while `previewDeposit` does not.
    ///
    ///      **This is push-based storage, and that is the limit of what it can promise.** The
    ///      mark exists from the moment `CreditManager` writes it and not a block sooner, so it
    ///      says nothing about a position that has gone bad and that nobody has named yet. This
    ///      docstring used to finish the first sentence with "so there is nothing left to run
    ///      from"; audit round seventeen executed that as false and it is the sentence a future
    ///      editor is most likely to read before changing the mark. See the contract header for
    ///      what bounds the window now, and for why the bound is transaction ordering rather
    ///      than zero.
    ///
    ///      Idempotent set, not an add. The estimate is re-stated as the position moves - the
    ///      auction's floor bounds it while an auction is live, and a workout that could recover
    ///      nothing escalates it - so the caller sends the current figure and this stores it.
    ///
    ///      Pushed by the manager rather than pulled from the auction. See `totalImpairment`.
    ///      **Clamped at the write, not only at the read.** Without the clamp,
    ///      `totalImpairment + amount` can overflow with a second borrower already marked, and this
    ///      function must not be able to revert: the auction's exits of last resort reach it, and an
    ///      exit that can fail while holding somebody else's collateral is not an exit.
    ///
    ///      **What makes the clamp unreachable is that `amount` is a debt, and audit round 20 found
    ///      this and `LiquidationAuction._bid` carrying one justification between them.** The
    ///      argument this used to give stopped at "no borrower can owe more than the live cap, and
    ///      the live cap can never exceed the ceiling", which is true and is only half of what is
    ///      needed - it says nothing about the quantity being clamped. The step that closes it here:
    ///      `amount` is a *mark*, which `CreditManager._impairmentFor` computes as
    ///      `debt - recovered`, and a shortfall cannot exceed the debt it is a shortfall of. So the
    ///      debt argument covers this site exactly. It does **not** cover the sibling, which clamps
    ///      a price rather than a debt; `Config.GLOBAL_BORROW_CAP_MAX` sets both arguments out in
    ///      full and is the place to read before editing either. The clamp itself is unchanged.
    ///
    ///      **The clamp is the ceiling, not the live cap, and that is not laziness.** Reading the
    ///      live cap would mean an external call from a function whose entire contract with its
    ///      callers is that it cannot fail. The ceiling is a compile-time constant and bounds the
    ///      live cap by construction, so it costs nothing and gives up nothing: the clamp was never
    ///      reachable in a legitimate state and still is not.
    /// @return wrote Whether this call actually moved the stored mark. **Audit round 19**: the
    ///         early return below is silent - no write, no event, and no revert - so a caller using
    ///         `try` as its success signal reads a no-op as a refresh. `refreshImpairments` did
    ///         exactly that and reported `refreshed = 1` five calls running while `exitReserve`
    ///         never moved and the withdrawal queue stayed shut over idle cash. Reported as a
    ///         return value rather than inferred from an `impairmentOf` read at the call site,
    ///         because a read there would be a **new selector called bare on the pool pointer**,
    ///         and by this protocol's own rule a new bare selector owes a probe in `setLenderPool`
    ///         in the same commit. The selector of this function is unchanged - return types do not
    ///         enter it - so nothing that already calls it needs to know.
    function impair(address borrower, uint256 amount) external returns (bool wrote) {
        if (msg.sender != creditManager) revert NotCreditManager();

        if (amount > Config.GLOBAL_BORROW_CAP_MAX) amount = Config.GLOBAL_BORROW_CAP_MAX;

        uint256 previous = impairmentOf[borrower];
        if (amount == previous) return false;

        impairmentOf[borrower] = amount;
        totalImpairment = totalImpairment + amount - previous;

        // The set mirrors the map, and it is maintained in the same statement that writes the map
        // so the two cannot drift. `amount == 0` is reachable here even though `_setImpairment`
        // routes zero to `releaseImpairment`: this function is external and on the interface.
        if (previous == 0 && amount != 0) {
            _trackImpaired(borrower);
        } else if (amount == 0) {
            _untrackImpaired(borrower);
        }

        emit Impaired(borrower, amount, totalImpairment);
        return true;
    }

    /// @notice Set the two book-level reserves: a recognised loss not yet absorbed here, and the
    ///         insurance fund standing in front of the live impairments. CreditManager only.
    /// @dev Restated wholesale rather than adjusted, for the same reason `impair` is a set: the
    ///      manager holds both figures and pushing the current pair cannot drift from them, where
    ///      a delta can. Total by construction - two stores, one event, no external call, no
    ///      subtraction that can underflow - so a caught push at the auction is a stale mark and
    ///      never a bricked exit.
    function setLossReserves(uint256 unplacedLoss_, uint256 insuranceCover_) external {
        if (msg.sender != creditManager) revert NotCreditManager();

        unplacedLoss = unplacedLoss_;
        insuranceCover = insuranceCover_;
        emit LossReservesSet(unplacedLoss_, insuranceCover_, exitReserve());
    }

    /// @notice What the exit price stands back from `totalAssets()`.
    /// @dev Three steps, and the order of them is the design.
    ///
    ///      Insurance nets once against the summed impairments - see `insuranceCover`. The
    ///      recognised-but-unplaced loss is added after, because it is already post-insurance.
    ///
    ///      **Then everything clamps to `outstandingPrincipal`, and that clamp is load-bearing
    ///      twice over.** `socialiseLoss` clamps every write-down to what this pool has actually
    ///      lent, so a reserve above that prices in a loss the pool provably cannot take: the
    ///      wiring `DeployBase` ships makes this pool the loss sink while the treasury is still the
    ///      liquidity source, which is round-11's zero-exposure finding, and without the clamp the
    ///      impairment would reinstate it from the inside.
    ///
    ///      **The second reason this comment used to give no longer applies, and the clamp stays
    ///      for the first.** It said the clamp keeps `exitAssets()` above the idle balance, which
    ///      stopped `serviceQueue` taking its dust-release branch on the whole queue at
    ///      `exitAssets() == 0`. Since audit round 15 that branch asks the **un-impaired**
    ///      valuation and does not read `exitAssets()` at all, so the failure it describes is not
    ///      reachable through it. Recorded rather than deleted, because the first reason is
    ///      load-bearing and a clamp with one stated reason left is easier to remove by mistake
    ///      than one with two.
    ///      Written to clamp *before* the second addition rather than after it. Adding first and
    ///      clamping after reads more naturally and overflows: `unplacedLoss` is set from the
    ///      manager's own counter, and a saturating sum has to be reached without ever leaving the
    ///      range, because this view sits under `previewRedeem` and a revert here would be a
    ///      bricked exit rather than a bad number. The fuzz over the writers caught it.
    function exitReserve() public view returns (uint256) {
        uint256 exposure = outstandingPrincipal;

        uint256 gross = totalImpairment;
        uint256 cover = insuranceCover;
        uint256 reserve = gross > cover ? gross - cover : 0;
        if (reserve >= exposure) return exposure;

        uint256 headroom = exposure - reserve;
        uint256 backlog = unplacedLoss;
        return backlog >= headroom ? exposure : reserve + backlog;
    }

    /// @notice Drop a borrower's reserve, because the position resolved. CreditManager only.
    /// @dev **Every terminal transition of an auction must reach this**, or the reserve outlives
    ///      its cause and depresses the exit price for every lender permanently. The auction's own
    ///      header warns that its three exits must leave no gap; this binds a fourth contract to
    ///      the same rule, and `test_impairment_isReleasedOnEveryAuctionExit` is what pins it.
    ///
    ///      Idempotent, so a path that releases twice is harmless. That matters because releasing
    ///      is the safe direction: a missed release strands the reserve, a doubled one does nothing.
    /// @return wrote Whether this call actually cleared a mark, for the same reason `impair` reports
    ///         it: the idempotent no-op above is silent, and a caller that counts calls rather than
    ///         writes would report a sweep of already-clear borrowers as work done. Idempotence is
    ///         the right behaviour here and the wrong thing to *count*.
    function releaseImpairment(address borrower) external returns (bool wrote) {
        if (msg.sender != creditManager) revert NotCreditManager();

        uint256 previous = impairmentOf[borrower];
        if (previous == 0) return false;

        delete impairmentOf[borrower];
        totalImpairment -= previous;
        _untrackImpaired(borrower);
        emit ImpairmentReleased(borrower, previous, totalImpairment);
        return true;
    }

    /// @notice How many borrowers carry a mark right now.
    /// @dev Paired with `impairedBorrowerAt` so `CreditManager.refreshImpairments` can walk the set
    ///      without this contract ever calling back into the manager. The call direction stays
    ///      manager to pool, which is the direction every other impairment call already goes.
    function impairedBorrowerCount() external view returns (uint256) {
        return _impairedBorrowers.length;
    }

    /// @notice The marked borrower at `index`.
    /// @dev **Order is not stable and callers must not assume it is.** A release swap-pops the tail
    ///      into the vacated slot, so a walk that clears marks as it goes has to run *downward* or
    ///      it will step over the entry that was moved. `refreshImpairments` does exactly that and
    ///      says so.
    function impairedBorrowerAt(uint256 index) external view returns (address) {
        return _impairedBorrowers[index];
    }

    /// @dev Append. Cheap, and never reverts: no allocation beyond the push, no external call.
    function _trackImpaired(address borrower) private {
        if (_impairedIndexPlusOne[borrower] != 0) return;
        _impairedBorrowers.push(borrower);
        _impairedIndexPlusOne[borrower] = _impairedBorrowers.length;
    }

    /// @dev Swap-pop, the same shape `cancelWithdrawalRequest` uses on the queue index. Idempotent,
    ///      because both writers can reach it with nothing to remove and neither may revert.
    function _untrackImpaired(address borrower) private {
        uint256 indexPlusOne = _impairedIndexPlusOne[borrower];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 last = _impairedBorrowers.length - 1;
        if (index != last) {
            address moved = _impairedBorrowers[last];
            _impairedBorrowers[index] = moved;
            _impairedIndexPlusOne[moved] = index + 1;
        }
        _impairedBorrowers.pop();
        delete _impairedIndexPlusOne[borrower];
    }

    /// @notice What the pool is worth to somebody leaving it: assets less reserved shortfalls.
    /// @dev The entry side deliberately does **not** deduct this - see `previewDeposit`. That
    ///      asymmetry is the whole mechanism, and it is Maple's: an entrant who bought at the
    ///      impaired price would profit when the impairment was released, which is round-11's
    ///      buy-the-dip finding arriving through the front door instead.
    function exitAssets() public view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 reserved = exitReserve();
        return assets > reserved ? assets - reserved : 0;
    }

    /// @dev OZ's conversion math with `exitAssets()` substituted for `totalAssets()`. The virtual
    ///      share and asset terms are kept identical, or the inflation defence would differ between
    ///      the two sides of the pool.
    function _exitToShares(uint256 assets, Math.Rounding rounding) private view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), exitAssets() + 1, rounding);
    }

    function _exitToAssets(uint256 shares, Math.Rounding rounding) private view returns (uint256) {
        return Math.mulDiv(shares, exitAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @notice Idle USDC not already spoken for by the withdrawal queue.
    /// @dev The queue has first call on every dollar in the contract. Without this, servicing
    ///      would compete with new withdrawals and with lending for the same balance, and FIFO
    ///      would hold only until someone else got there first.
    ///      Valued at the exit price: what the queue is owed is what it would be paid, and since
    ///      the impairment the two are the same number.
    ///      **Priced on the un-impaired book, matching `available()`, and audit round 13 is why.**
    ///      This read `_exitToAssets` until then - the marked-down figure - so an impairment shrank
    ///      the queue's reserved claim and *raised* what an unqueued lender could take ahead of it,
    ///      which is the same defect round 12 found in `available()` and the same argument against
    ///      it: a mark is released when its liquidation resolves and the claim rises again at that
    ///      moment, so reserving today's marked-down figure hands out the difference in between.
    ///      Four agents flagged the pair. The fix had been applied to one sibling and not the other,
    ///      which is exactly the miss `_update`'s comment warns about two screens up.
    function unreservedIdle() public view returns (uint256) {
        uint256 idle = _poolBalance();
        uint256 owedToQueue = _convertToAssets(queuedShares, Math.Rounding.Ceil);
        return idle > owedToQueue ? idle - owedToQueue : 0;
    }

    /// @inheritdoc ERC4626
    /// @dev Capped at `depositCap`. See that variable for why the cap is a yield argument rather
    ///      than a risk one, and why it is stored here rather than read from `RiskParams` - the
    ///      short version is that ERC-4626 forbids this function from reverting, so it must not
    ///      depend on an external call.
    ///
    ///      **Sized from `netDeposits`, not from `totalAssets()`, and audit round 11 is why.**
    ///      `totalAssets()` reads a raw `balanceOf`, so anyone could transfer the whole cap
    ///      straight to the freshly deployed pool and pin this at zero
    ///      **permanently**: with `totalSupply()` also zero there is no share to redeem that would
    ///      bring the balance back under the cap, and this contract is immutable with no sweep and
    ///      no owner rescue. Recovery would be a redeploy plus three re-wirings. The deploy script
    ///      ships the pool in exactly that empty state, so it was reachable from block one, and one
    ///      of the round-11 agents executed it.
    ///
    ///      A donation cannot move `netDeposits`, because only `_deposit` writes it up, and yield
    ///      deliberately does not either: the cap is a statement about how much *new lender
    ///      capital* the pool will take, not about how large it may grow once it is earning. **A
    ///      realised loss DOES move it down** - round 12 added that, because capital destroyed has
    ///      to stop counting against the cap; see `socialiseLoss`. This sentence used to say losses
    ///      did not move it either, which was false from round 12 onwards and is exactly the
    ///      sentence a reader would have used to clear round 21's finding 8 without measuring.
    ///
    ///      An exit debits the counter its **pro-rata share of principal**, not the assets it is
    ///      paid - see `_withdraw`. Debiting the assets mixed yield into a principal counter and
    ///      ratcheted it down against a clamp that could not net it back up.
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 taken = netDeposits;
        uint256 cap = depositCap;
        return taken >= cap ? 0 : cap - taken;
    }

    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @inheritdoc ERC4626
    /// @dev Reports what can actually be taken now, which is the whole reason `requestWithdrawal`
    ///      exists as a separate call. An integrator reading this gets the truth rather than a
    ///      figure that turns into a queue ticket on execution.
    ///
    ///      Priced on `exitAssets()`, so a lender leaving during a liquidation already carries the
    ///      expected loss. **That pricing is what replaced the round-10 gate**, which used to
    ///      return a flat zero from here while a liquidation was live: the number is honest now, so
    ///      there is nothing to run from and no reason to stop anybody. It is also why this reads
    ///      storage only and makes no external call - see decision 4 in the contract header.
    ///
    ///      **What this pair costs while a mark stands, stated as a cost, because audit round 20
    ///      measured it and because the shape of the measurement got attributed to the wrong
    ///      function.** During a mark the exit price is a fraction of the entry price, so exiting at
    ///      the reported maximum consumes nearly the whole position for a fraction of its
    ///      un-impaired value. That is real and it is `CreditManager._impairmentFor`'s whole-debt
    ///      mark arriving here as designed - that function's own docstring says "a lender leaving
    ///      during a routine six-hour auction is marked down for a loss that probably will not
    ///      happen, and stayers gain what leavers give up", and calls it the intended direction.
    ///
    ///      **It is not an asymmetry between these two views, and that was the round's stated
    ///      mechanism.** Both were executed on the same fixture in `LenderPoolExitPricing.t.sol`:
    ///      `withdraw(maxWithdraw(owner))` and `redeem(maxRedeem(owner))` pay an identical
    ///      500.000000 out of a 3,000.000000 position and burn share counts 2,499 apart out of three
    ///      trillion. `previewRedeem(maxRedeem(owner))` equals `maxWithdraw(owner)` to within two
    ///      wei across the whole range of the mark, under fuzz. `_exitToShares` and `_exitToAssets`
    ///      are inverses, so converting an asset-denominated liquidity cap through the first and
    ///      paying through the second round-trips; there is no six-fold disagreement between them.
    ///      The six-fold disagreement is between `convertToAssets` and `previewRedeem`, which is the
    ///      dual price this pool ships on purpose and documents on `previewRedeem`.
    ///
    ///      What is genuinely missing is a *bound*, not a different number here: a stranger's
    ///      `liquidate` can move the price between quote and execution. See the four-argument
    ///      `withdraw` and `redeem` below, which is where that got fixed.
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 owned = _exitToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 idle = unreservedIdle();
        return owned < idle ? owned : idle;
    }

    /// @inheritdoc ERC4626
    /// @dev The share-denominated twin of `maxWithdraw`, and it reports the same money: the
    ///      liquidity cap is an asset quantity, so it is converted at the price this door pays at.
    ///      Read `maxWithdraw`'s note for what the pair costs under a mark and for the measurement
    ///      that says the two agree. ERC-4626 forbids this from reverting and it makes no external
    ///      call, so it cannot.
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 shares = balanceOf(owner);
        uint256 idleShares = _exitToShares(unreservedIdle(), Math.Rounding.Floor);
        return shares < idleShares ? shares : idleShares;
    }

    /// @inheritdoc ERC4626
    /// @dev **The exit side of the dual price.** `previewDeposit` and `previewMint` are deliberately
    ///      left on `totalAssets()`, so an entrant does not receive the impairment discount and
    ///      cannot profit when the impairment is released. Maple documents that arbitrage as the
    ///      reason for the same split.
    ///
    ///      Note for integrators: the ERC-4626 `convertToAssets`/`convertToShares` views stay on
    ///      the un-impaired figure, matching Maple. Read `previewRedeem` for what you would
    ///      actually be paid.
    function previewRedeem(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        return _exitToAssets(shares, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        return _exitToShares(assets, Math.Rounding.Ceil);
    }

    // ── Pool ↔ protocol flows ────────────────────────────────────────────────

    /// @inheritdoc ERC4626
    /// @dev `nonReentrant` on the mutating ERC-4626 entry points, because USDC is an upgradeable
    ///      proxy on Base and a future hook on it would otherwise sit inside share accounting.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256) {
        uint256 remaining = maxDeposit(receiver);
        if (assets > remaining) revert DepositCapExceeded(assets, remaining);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256) {
        uint256 remaining = maxMint(receiver);
        if (shares > remaining) revert DepositCapExceeded(shares, remaining);
        return super.mint(shares, receiver);
    }

    /// @dev Overridden for `nonReentrant` and for nothing else since the gate came out. Both of
    ///      these used to open with the round-10 gate check and its own dedicated revert; what
    ///      carries the loss now is the price they pay out on, because `super` routes through
    ///      `previewWithdraw`/`previewRedeem` and those price on `exitAssets()`. There is
    ///      deliberately no check of any kind left here - a refusal is what round 10 shipped and
    ///      what the research overturned.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Redeem, refusing to settle for less than `minAssetsOut` USDC.
    /// @dev **The bound a leaver could not previously place on their own exit, and audit round 20
    ///      is what measured the gap.** The two doors above pay `exitAssets()`, which a stranger can
    ///      move by a factor of six in the block before the transaction lands: `liquidate` is
    ///      permissionless by design, `CreditManager._impairmentFor` marks the whole debt while an
    ///      auction stands, and the loss-creating `postNav` is public. Measured on the ordinary
    ///      liquidation, in `LenderPoolExitPricing.t.sol`: a lender quoted 3,000.000000 by
    ///      `previewRedeem`, front-run by one `liquidate`, was paid 500.000000 for the same shares
    ///      on an auction whose realised loss ended at zero. Nothing in the ERC-4626 surface let
    ///      them say no to that.
    ///
    ///      **This is a bound on the caller's own call and inherits nothing from audit round 14.**
    ///      A reader will reach for round 14 to dismiss it, because round 14 deleted a price floor
    ///      from this contract. That floor was a **per-entry field on the shared FIFO loop** in
    ///      `serviceQueue`, and all four of its failure modes came from one lender having a say over
    ///      another lender's turn: a stored figure that drifted from a rising book, a queue frozen
    ///      for everybody on a realised loss, FIFO inverted between two entries, and a skipped live
    ///      entry that pinned the head. Read `requestWithdrawal` for the full list. **None of those
    ///      shapes exists here.** There is no cursor, no ordering, no stored field and no second
    ///      party: the figure lives in calldata for the length of one transaction, and the only
    ///      thing it can do is revert the caller's own exit. Round 14's own closing rule -
    ///      "change what the queue *pays*, not who it is allowed to walk past" - is a rule about the
    ///      queue, and this door is not the queue.
    ///
    ///      The in-tree precedent is `LiquidationAuction.bid(uint256,uint256)`, added for the same
    ///      reason in the same shape: "it bounds what an in-flight transaction can cost".
    ///
    ///      **Checked after execution rather than against a preview.** `previewRedeem` and the paid
    ///      amount agree today, so the two are equivalent now; bounding the figure actually paid
    ///      keeps that true without depending on it. The revert unwinds the transfer with everything
    ///      else, so nothing is observable in between.
    ///
    ///      Not a default and not a refusal. The three-argument doors are unchanged and still take
    ///      whatever the book says, because ERC-4626 fixes their signatures and a refusal is what
    ///      audit round 10 shipped and rounds 10/11's research overturned. This is the door for a
    ///      caller who has an opinion about the price.
    function redeem(uint256 shares, address receiver, address owner, uint256 minAssetsOut)
        external
        returns (uint256 assets)
    {
        assets = redeem(shares, receiver, owner);
        if (assets < minAssetsOut) revert AssetsBelowMinimum(assets, minAssetsOut);
    }

    /// @notice Withdraw, refusing to spend more than `maxSharesIn` shares on it.
    /// @dev The withdraw-side half of the bound above, and the half that carries the loss the
    ///      round-20 finding is named for. `maxWithdraw` is honest about the *assets* - it reports
    ///      500.000000 and pays 500.000000 - and says nothing about the 2,999,999,997,501 shares
    ///      that come out to fund it. Measured: on the same fixture `withdraw(maxWithdraw(owner))`
    ///      and `redeem(maxRedeem(owner))` pay an identical 500.000000 and burn share counts 2,499
    ///      apart out of three trillion, so the two doors are the same cliff and neither view is
    ///      more honest than the other. `previewWithdraw` already quotes the share cost; this is
    ///      what lets a caller hold the quote to it.
    ///
    ///      See the redeem overload for why this is not the price floor audit round 14 deleted.
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxSharesIn)
        external
        returns (uint256 shares)
    {
        shares = withdraw(assets, receiver, owner);
        if (shares > maxSharesIn) revert SharesAboveMaximum(shares, maxSharesIn);
    }

    /// @notice Send `amount` USDC to the CreditManager to fund a borrow. CreditManager only.
    /// @dev Bounded by `available()`, which holds back what the queue is owed. A pool that lends
    ///      out money it owes to a lender who has already asked for it is not short of liquidity,
    ///      it is choosing borrowers over lenders. (This used to say "zero while anyone is queued",
    ///      which was the pre-round-10 rule: a boolean where the intent was an amount, and one wei
    ///      of queued shares stopped all borrowing.)
    ///
    ///      Deliberately *not* held back by a live impairment either, and it was not held back by
    ///      the gate that preceded one. A reserve is about lenders leaving at a price that has
    ///      stopped being true; refusing to fund borrows while any position anywhere is in distress
    ///      would halt the whole protocol for every borrower over one bad loan. What the reserve
    ///      **This used to claim `available()` values the queue's claim and the hot float at the
    ///      exit price, so that a marked-down book lends less. It does not**, and audit round 16
    ///      found the claim rather than a bug: `available()` reads neither `exitReserve()` nor
    ///      `exitAssets()`, and the function four screens down says so at length and explains why
    ///      that is deliberate. A mark does not reduce what may be lent, by design, because
    ///      reserving is about the price a leaver gets and not about the size of the book.
    function lend(uint256 amount) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        if (amount == 0) revert ZeroAmount();

        uint256 lendable = available();
        if (amount > lendable) revert InsufficientLiquidity(amount, lendable);

        outstandingPrincipal += amount;
        emit Lent(amount);
        IERC20(asset()).safeTransfer(creditManager, amount);
    }

    /// @notice Pull returned principal from the CreditManager, which has approved exactly this
    ///         much. CreditManager only.
    /// @dev Pull rather than push, matching `TreasuryLiquiditySource`: a bare transfer would look
    ///      like idle capital and leave `outstandingPrincipal` overstated.
    function repayPrincipal(uint256 amount) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        if (amount == 0) revert ZeroAmount();

        // Clamped rather than subtracted. Yield can exceed principal, and a socialised loss has
        // already reduced this counter for money that will never come back - so a repayment can
        // legitimately be larger than what is still recorded as out on loan.
        //
        // **The surplus is streamed, not banked, and audit round 11 is why.** Left as idle float it
        // lands in `totalAssets()` in the repaying block, which is an instantaneous share-price step
        // - and `settlePrincipal` is permissionless, so a just-in-time depositor picks the block and
        // takes a pro-rata slice of a recovery they were exposed to for zero seconds. That is
        // exactly the defect the yield stream exists to prevent, arriving on the principal leg
        // where nobody had thought to look for it.
        //
        // It is real money and it does belong to lenders. Streaming it hands it to the lenders who
        // were actually invested while the loss it reverses was outstanding, rather than to whoever
        // was watching the mempool.
        uint256 outstanding = outstandingPrincipal;
        uint256 surplus = amount > outstanding ? amount - outstanding : 0;
        outstandingPrincipal = outstanding > amount ? outstanding - amount : 0;

        if (surplus != 0) {
            // Below the yield threshold there is nobody to raise the price of, and rating a stream
            // into an empty pool is a windfall for the next depositor rather than a payment to
            // anyone. Add it to the pot with the stream frozen instead, exactly as `_update` does
            // when the last share is burned, and the next epoch folds it in under rule 3.
            if (totalSupply() < MIN_SUPPLY_FOR_YIELD) {
                pendingYield += surplus;
                yieldRate = 0;
            } else {
                _rateStream(surplus, false);
            }
            emit PrincipalSurplusStreamed(surplus);
        }

        emit PrincipalRepaid(amount);
        IERC20(asset()).safeTransferFrom(creditManager, address(this), amount);
    }

    /// @notice Receive the lender share of harvested yield. Raises share price. Harvester only.
    /// @dev Pull, not push, because that is what `EpochHarvester._tryDeliverLenderYield` does: it
    ///      approves this contract for the amount and then calls. A plain `receive`-style
    ///      implementation would take nothing and the harvester would correctly report that
    ///      nothing was delivered.
    ///
    ///      No shares are minted, which is the entire mechanism: assets rise, supply does not, so
    ///      every existing share is worth more.
    ///
    ///      **The epoch is streamed, not applied at once**, and this is audit round 10's finding 6.
    ///      An instantaneous share-price step is free money for anyone watching the mempool:
    ///      `flushLenderYield` is permissionless, so the attacker picks the block, deposits to the
    ///      cap in it, and takes a pro-rata slice of an epoch they were exposed to for zero
    ///      seconds. `CreditManager.distributeYield` streams the *borrower* leg for exactly this
    ///      reason; this leg was built without the equivalent and the two now match.
    ///
    ///      The mechanism differs from the borrower leg's because it can afford to be simpler.
    ///      There is no accumulator and no per-holder index: `pendingYield` is held out of
    ///      `totalAssets()` and released on a clock, so the share price rises continuously and
    ///      apportions itself. What is copied over verbatim is the *rating*, because all three of
    ///      the rules below were paid for with real bugs on the other leg.
    function distributeYield(uint256 amount) external nonReentrant {
        if (msg.sender != epochHarvester) revert NotEpochHarvester();
        if (amount == 0) revert ZeroAmount();
        // Raising the price of nothing destroys the money. With no shares outstanding the assets
        // back only the virtual shares the decimals offset implies, which nobody owns and no
        // function here can sweep - a later depositor gets their own principal back and not a cent
        // of this. The harvester measures delivery and catches the revert, so refusing leaves the
        // share owed in `pendingLenderYield` until there is somebody to pay it to. That is exactly
        // what that counter is for: "the lender share of every epoch before the pool opens is
        // still owed and payable".
        if (totalSupply() < MIN_SUPPLY_FOR_YIELD) revert NoSharesOutstanding();

        // **A share floor is not a capital floor, and audit round 13 found the gap between them.**
        //
        // `MIN_SUPPLY_FOR_YIELD` was derived against the virtual-share leak and is honest about its
        // size: "a hundredth of a dollar of deposits, which is not a real barrier to a genuine
        // pool". It is not a barrier to a dishonest one either. A first deposit into an empty pool
        // mints `assets * 10 ** offset` shares, so 10,000 wei of USDC mints exactly the threshold -
        // and `pendingLenderYield` is a *backlog*, holding the lender share of every epoch since
        // before the pool opened. One cent of capital plus one permissionless flush took
        // essentially all of it.
        //
        // The threshold answered "is there anybody here to pay"; this answers "is there enough
        // here that paying it is not a windfall". Comparing against the pool's own size rather than
        // a constant means it scales with the pool and needs no parameter: an epoch that is larger
        // than everything the pool holds is not an epoch this pool earned.
        //
        // Refusing is safe and is the designed behaviour, not an outage: `_push` wraps the call in
        // `try`/`catch` and measures delivery, so the share stays in `pendingLenderYield` until
        // there is capital to pay it to. Same reasoning as the guard above, one question further
        // along.
        uint256 capital = totalAssets();
        if (amount > capital) revert YieldExceedsCapital(amount, capital);

        _rateStream(amount, true);

        emit YieldDistributed(amount, yieldRate, yieldStreamEndsAt);
        IERC20(asset()).safeTransferFrom(epochHarvester, address(this), amount);
    }

    /// @dev The rating rules, extracted so the principal leg can reuse them. All three were paid
    ///      for with real bugs on the borrower leg, and a second copy of them would be a second
    ///      chance to get one wrong.
    /// @param isEpoch whether this is a delivered epoch, which owns the accrual clock, or a
    ///        surplus arriving from somewhere else, which must not touch it.
    function _rateStream(uint256 amount, bool isEpoch) private {
        // Crystallise the running stream before re-rating it, or the elapsed part of the old one
        // would be re-rated as though it had never been paid out.
        uint256 pot = unreleasedYield() + amount;

        // 1. Pay out over at least as long as the pot took to accrue. A fixed window closes
        //    same-block capture but not the general case: a pot representing sixty days of yield,
        //    rated over five, hands eleven-twelfths of it to whoever is staked for those five days.
        //    Windows stretch for ordinary reasons - a keeper outage, a run of declined zero-yield
        //    epochs, or the gap before this pool is wired at all - and `flushLenderYield` is
        //    permissionless, so the attacker picks the block.
        uint256 elapsed = block.timestamp - lastYieldDistributeAt;
        uint256 duration =
            elapsed > Config.YIELD_STREAM_DURATION ? elapsed : Config.YIELD_STREAM_DURATION;

        // 2. Never shorten a running stream. `elapsed` describes the accrual window of the *new*
        //    money, but the pot also holds the unfinished tail of the previous stream, whose window
        //    may have been far longer. Re-rating that tail over the new gap compresses it, which is
        //    the same just-in-time capture reintroduced one epoch later.
        uint256 remaining = yieldStreamEndsAt > block.timestamp ? yieldStreamEndsAt - block.timestamp : 0;
        if (remaining > duration) duration = remaining;

        // 3. Rate the whole pot, not just `amount`. That is what rolls the previous stream's tail,
        //    division dust, and anything frozen while the pool stood empty into the new stream
        //    instead of stranding it outside `totalAssets()` forever.
        uint256 rate = (pot * ACC_PRECISION) / duration;
        // Only reachable on an empty pot, which `amount != 0` already excludes - the rate carries
        // ACC_PRECISION of headroom. Kept so the invariant "a live pot always has a live rate"
        // holds by construction rather than by argument.
        if (rate == 0) revert ZeroAmount();

        pendingYield = pot;
        yieldRate = rate;
        lastYieldAccrualAt = block.timestamp;
        yieldStreamEndsAt = block.timestamp + duration;

        // **Only a delivered epoch moves the accrual clock**, and this flag is the whole reason the
        // helper takes one. `lastYieldDistributeAt` is the sole input to rule 1, so letting a
        // repayment write it would let anyone shorten the window the *next* epoch is rated over by
        // calling the permissionless `settlePrincipal` just before a harvest. That is round-11's
        // anti-just-in-time pin, reintroduced on the other leg by the fix for the step below it.
        if (isEpoch) lastYieldDistributeAt = block.timestamp;
    }

    /// @dev The two hooks every ERC-4626 entry and exit funnels through, so `netDeposits` cannot be
    ///      missed by a path that forgets to update it. `serviceQueue` is the one exit that does not
    ///      come through `_withdraw` - it burns escrowed shares directly - and it decrements there.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        netDeposits += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // **Debited pro-rata on the shares burnt, not on the assets paid, and audit round 21 is
        // why.** `_deposit` credits this counter in principal; paying out `assets` debits it in
        // principal *plus* that lender's share of every epoch of yield since. The clamp below
        // floors the difference at zero rather than letting it net out, so the drift is a one-way
        // ratchet: measured, two epochs of a rotating lender walked the counter from 20,000.000000
        // to 10,555.555557 while the pool still held 30,555.555557, handing back 9,444.444443 of
        // cap headroom that nobody had vacated. `totalSupply()` here still includes `shares` -
        // `super._withdraw` is what burns them.
        _reduceNetDeposits(_principalPortion(shares, totalSupply()));
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev The share of `netDeposits` that leaves with `shares` out of `supply`. Floored, so the
    ///      counter is never debited more principal than the exit is actually entitled to carry.
    ///      `mulDiv` rather than a plain multiply: the product is unreachable at any cap real USDC
    ///      could fund, but `depositCap` is an owner-set figure and this pool is immutable, so the
    ///      one place a bad cap could brick is not the place to rely on an arithmetic bound.
    function _principalPortion(uint256 shares, uint256 supply) private view returns (uint256) {
        if (supply == 0) return netDeposits;
        return Math.mulDiv(netDeposits, shares, supply, Math.Rounding.Floor);
    }

    /// @dev Clamped rather than subtracted. Once the pool has earned, a lender can take out more
    ///      than they put in, and the counter must floor at zero rather than underflow.
    function _reduceNetDeposits(uint256 assets) private {
        uint256 taken = netDeposits;
        netDeposits = assets > taken ? 0 : taken - assets;
    }

    /// @dev Freezes the stream if the last share has just been burned.
    ///
    ///      Without this, unreleased yield outlives the shareholders it was meant for and becomes a
    ///      windfall for whoever deposits next: with `totalSupply()` at zero the remainder keeps
    ///      releasing into `totalAssets()`, and the next depositor - who mints against the virtual
    ///      shares alone - ends up owning all of it outright. That is the just-in-time capture this
    ///      whole stream exists to close, reachable by waiting rather than by front-running.
    ///
    ///      Freezing rather than sweeping. The money is still owed to lenders, so it stays out of
    ///      `totalAssets()` at a zero rate until the next `distributeYield` folds it into a fresh
    ///      stream - which the "rate the whole pot" rule above already does. A new depositor
    ///      therefore has to hold through that stream to earn any of it, which is the point.
    ///
    ///      Hooked on `_update` rather than on `withdraw`/`redeem` because `serviceQueue` burns
    ///      escrowed shares too, and that path would otherwise slip past.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        // **Audit round 12: this tested the threshold round 11 had already proved wrong.** The
        // freeze and `distributeYield`'s guard answer the same question - is there enough real
        // supply for a release to reach anybody - and they answered it differently. Round 11 fixed
        // the entry point and derived `MIN_SUPPLY_FOR_YIELD` for exactly this harm; the exit kept
        // `== 0`, so a partial burn walked straight through the band with a live stream and up to a
        // whole epoch released into the 1,000 virtual shares, which nobody can ever redeem. At
        // `totalSupply() == 1` those shares own 99.9% of the pool. Symmetric-pair miss: when a fix
        // adds a guard, find its mirror.
        if (yieldRate != 0 && totalSupply() < MIN_SUPPLY_FOR_YIELD) {
            // Computed before the rate is zeroed, so the elapsed part of the stream is still paid.
            uint256 unreleased = unreleasedYield();
            pendingYield = unreleased;
            yieldRate = 0;
            yieldStreamEndsAt = block.timestamp;
            lastYieldAccrualAt = block.timestamp;
            emit YieldStreamFrozen(unreleased);
        }
    }

    /// @notice Write a shortfall down against the pool. CreditManager only.
    /// @dev The loss lands on principal that has been lent out and will not come back, so it
    ///      reduces `outstandingPrincipal` and therefore `totalAssets`, and therefore the share
    ///      price. Every lender takes it in proportion to their holding, **including anyone
    ///      sitting in the withdrawal queue**, whose shares are still outstanding for exactly
    ///      this reason.
    ///
    ///      Clamped to what is actually out on loan: a loss larger than the pool's own exposure
    ///      is not the pool's to absorb, and silently underflowing it into idle depositor capital
    ///      would take money that was never at risk in the first place.
    /// @return absorbed how much of `amount` actually landed on the share price.
    /// @dev **The return value is the whole point, and it used to be missing.** The clamp above is
    ///      right, but with a `void` signature the caller could not tell a full absorption from a
    ///      zero one - and `CreditManager._socialise` reads "did not revert" as "fully placed", so
    ///      the remainder went into no counter at all. That was not an edge case: the deploy script
    ///      wires this pool as the loss sink while the treasury is still the liquidity source, so
    ///      `outstandingPrincipal` is zero and *every* loss absorbed exactly nothing. Before this
    ///      contract had a body it reverted `NotImplemented`, which made the caller's `catch` fire
    ///      and the loss visible - so building the pool is what broke the deferral it relies on.
    function socialiseLoss(uint256 amount) external nonReentrant returns (uint256 absorbed) {
        if (msg.sender != creditManager) revert NotCreditManager();
        if (amount == 0) revert ZeroAmount();

        absorbed = amount > outstandingPrincipal ? outstandingPrincipal : amount;
        outstandingPrincipal -= absorbed;
        lifetimeSocialisedLoss += absorbed;
        // **Capital destroyed has to stop counting against the deposit cap, and audit round 12
        // found it did not.** `netDeposits` rises on a deposit and falls only by assets actually
        // withdrawn - and a socialised loss never leaves as a withdrawal, so it consumed cap
        // headroom permanently. This contract is immutable with no sweep and no rescue, so enough
        // losses would close it to deposits for good, which is the same permanent brick round 11
        // found through a donation and this reaches through ordinary operation.
        //
        // Reducing here does not turn the counter into a valuation: a loss removes principal the
        // pool is holding, which is exactly what it measures. Yield and donations still move it by
        // nothing, which is what stops a donor closing the pool.
        _reduceNetDeposits(absorbed);
        emit LossSocialised(absorbed);
    }

    /// @notice Book money recovered on a loss this pool has already absorbed. CreditManager only.
    /// @dev **Audit round 21, finding 14: the leg `socialiseLoss` never had.** A workout's forced
    ///      close writes the debt off while DexFi's redemption is still in flight, and the tranche
    ///      that lands afterwards has to reach the lenders who took that loss - not the insurance
    ///      fund, which helps them only if a *future* borrower defaults.
    ///
    ///      **It cannot arrive through `repayPrincipal`, and that was measured before this was
    ///      built.** That leg nets against `outstandingPrincipal`, which the socialisation has
    ///      already written down: with any other loan still on the books the recovery reduces the
    ///      counter instead of the share price, and the gain is recognised only when the surviving
    ///      book unwinds. It also breaks the identity
    ///      `outstandingPrincipal == pendingPrincipal + totalDebt`, asserted in
    ///      `LiquidationAuction.invariants.t.sol`, because the manager would owe this pool money it
    ///      never lent. That invariant is what found it.
    ///
    ///      So the money arrives here as what it is: a gain on an asset already written off.
    ///      `outstandingPrincipal` does not move - there is no loan to re-recognise, and
    ///      `invariant_outstandingPrincipalOnlyRisesOnALend` says so - and neither does
    ///      `netDeposits`, for the reason `socialiseLoss` gives one function down: yield and
    ///      donations move it by nothing, which is what stops a donor closing the pool to deposits.
    ///
    ///      **Streamed, never banked**, on exactly the rules `repayPrincipal`'s surplus branch
    ///      uses, because `LiquidationAuction.workoutSettleAfterClose` is permissionless and an
    ///      instantaneous share-price step is a slice of somebody else's recovery for whoever picks
    ///      the block. That is round 10's finding 6, and this is a third leg it has to cover.
    ///
    ///      No `YieldExceedsCapital` guard, unlike `distributeYield`: a recovery genuinely can
    ///      exceed everything the pool now holds, precisely because the loss it reverses is what
    ///      made the pool that small. The closer sibling is `repayPrincipal`'s surplus, which has
    ///      no such guard either and for the same reason.
    function recoverLoss(uint256 amount) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        if (amount == 0) revert ZeroAmount();

        // Below the yield threshold there is nobody to raise the price of, and rating a stream into
        // an empty pool is a windfall for the next depositor rather than a payment to anyone. Add
        // it to the pot with the stream frozen instead, exactly as `repayPrincipal` does with its
        // surplus and `_update` does when the last share is burned.
        if (totalSupply() < MIN_SUPPLY_FOR_YIELD) {
            pendingYield += amount;
            yieldRate = 0;
        } else {
            _rateStream(amount, false);
        }

        lifetimeLossRecovered += amount;
        emit LossRecovered(amount, lifetimeLossRecovered);
        IERC20(asset()).safeTransferFrom(creditManager, address(this), amount);
    }

    /// @notice USDC available to lend, after the queue's claim and the hot float.
    /// @dev Holds back what the queue is actually owed, plus the `RESERVE_RATIO_BPS` float so an
    ///      ordinary withdrawal does not have to join a queue merely because a borrow arrived
    ///      first.
    ///
    ///      This used to be `if (queuedShares != 0) return 0`. The intent behind that line is an
    ///      amount - do not lend money already owed to someone in the queue - but a boolean cannot
    ///      express an amount, and `requestWithdrawal` has no minimum size. With three decimals of
    ///      share offset, one wei of USDC buys about a thousand shares, and a request worth *zero*
    ///      asset-wei zeroed the entire lending book: every borrow in the protocol reverted, and
    ///      the dust-release path handed the shares straight back so it could be re-queued for gas.
    ///      `unreservedIdle()` had expressed the same rule monetarily all along, four functions up.
    ///
    ///      **Both holdbacks are priced on the un-impaired book, and audit round 12 is why.** They
    ///      were denominated in `exitAssets()`, which meant marking the book down shrank the
    ///      queue's reserved claim *and* the hot float, so a liquidation **raised** what the pool
    ///      would lend - the exact inverse of the sentence above. Seven of twelve agents saw it and
    ///      none could extract from it, because `borrow` stays bound by LTV and the caps; it was
    ///      fixed rather than filed on the view that a lever nobody can pull yet is a lever the
    ///      next change makes reachable, and the round-13 impairment fix is that change. The old
    ///      mark was zero across the ordinary LTV band, so the lever barely moved. A full-debt mark
    ///      is large and routine.
    ///
    ///      The two legs want the un-impaired figure for different reasons, and it is worth keeping
    ///      them apart:
    ///
    ///      - **The float** is an operational buffer, sized so an ordinary withdrawal does not have
    ///        to queue. A markdown does not make the pool need less cash on hand; if anything it
    ///        makes withdrawals more likely.
    ///      - **The queue's claim** is what those shares might ultimately be owed, not what they
    ///        would fetch this second. `serviceQueue` pays the exit price, so the exit price is what
    ///        gets *paid* - but a mark is released when its liquidation resolves, and the claim
    ///        rises again at that moment. Reserving only today's marked-down figure lends out the
    ///        difference in between. Holding the larger of the two costs some lending capacity
    ///        while a mark stands and never strands the queue behind it.
    ///
    ///      The property this buys is simply that `available()` is non-increasing in the
    ///      impairment: worse news never buys more lending. `test_available_neverRisesWhenTheBookIsMarkedDown`
    ///      asserts it as monotonicity rather than against a recomputed figure, because an
    ///      expected-value test here would just restate this arithmetic.
    function available() public view returns (uint256) {
        uint256 idle = _poolBalance();
        uint256 held = _convertToAssets(queuedShares, Math.Rounding.Ceil)
            + (totalAssets() * Config.RESERVE_RATIO_BPS) / Config.BPS;
        return idle > held ? idle - held : 0;
    }

    // ── Withdrawal queue ─────────────────────────────────────────────────────

    /// @notice Join the FIFO queue for `shares` that cannot be withdrawn right now.
    ///
    /// @dev **A per-entry price floor was added here in round 13 and deleted in round 14. Read this
    ///      before adding one back, because the obvious design is the one that failed.**
    ///
    ///      The problem it was written for is real and is recorded as an open finding:
    ///      `serviceQueue` is permissionless and prices escrowed shares at the live exit
    ///      price, so a stranger chooses the instant somebody else's shares are valued, and can
    ///      open a mark themselves with the equally permissionless `liquidate`. Five agents traced
    ///      that in round 12.
    ///
    ///      The floor was a `minAssets` figure stored on the request, defaulting to the exit
    ///      valuation at request time. Twelve agents took it apart in round 14, and the reasons
    ///      compose rather than being separate bugs:
    ///
    ///      - **It did not close the attack.** A stored figure does not track a book whose price
    ///        rises with every epoch, so the gap between a queued lender's floor and their market
    ///        value grew monotonically, and the original extraction ran through it at full size.
    ///      - **It froze the queue on any realised loss.** `socialiseLoss` permanently lowers the
    ///        price, so every entry queued before a default fell under its own floor at once and
    ///        `serviceQueue` reverted `NothingToService` while the pool held cash. Executed.
    ///      - **It inverted FIFO.** A lender who queued first with the default floor was skipped
    ///        while one who queued after the mark, at a lower floor, took the whole idle balance.
    ///        Executed.
    ///      - **Skipping pinned the head.** A live entry the walk could not pay stopped `queueHead`
    ///        advancing for good, so cancelled husks behind it were re-scanned on every later call
    ///        and the cost grew without bound. Measured: 2,000 husks took a servicing call from
    ///        17,646 gas to 1,528,060 and rising.
    ///
    ///      **The lesson worth keeping is about the shape, not the arithmetic.** A per-entry
    ///      parameter on a shared FIFO loop gives one lender a say over everybody else's turn, and
    ///      this codebase has now had that defect three times through three different fields -
    ///      a blacklisted receiver, then a `break` on an unmet floor, then a skip that pinned the
    ///      head. `claimable` fixed the first by removing the per-entry veto entirely rather than
    ///      by making it safer. Any future price protection should follow that precedent: change
    ///      what the queue *pays*, not who it is allowed to walk past.
    ///
    ///      **None of this reaches the four-argument `withdraw` and `redeem`, and a reader arriving
    ///      from audit round 20 will try to make it.** Every clause above is about a shared FIFO
    ///      loop: a stored field, a cursor, an ordering, and one lender's parameter deciding another
    ///      lender's turn. A bound passed in calldata to a caller's own ERC-4626 exit has no cursor,
    ///      no ordering, no storage and no second party, and the only outcome it can produce is that
    ///      the caller's own transaction reverts. The rule this paragraph ends on is a rule about
    ///      *the queue*, and those doors are not the queue. See the overloads for the front-run this
    ///      contract had no answer to, measured.
    function requestWithdrawal(uint256 shares, address receiver) external nonReentrant {
        _requestWithdrawal(shares, receiver);
    }

    /// @dev The shares move to this contract and stay outstanding. See the contract NatSpec for
    ///      why that matters: escrowed shares keep earning and keep taking losses, so queueing is
    ///      not an exit from risk, only a place in line.
    function _requestWithdrawal(uint256 shares, address receiver) private {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 existing = _requestIndexPlusOne[msg.sender];
        if (existing != 0) revert AlreadyQueued(existing - 1);

        // Moves the shares rather than burning them, so `totalSupply` is untouched and the share
        // price does not jump at the moment somebody asks to leave.
        _transfer(msg.sender, address(this), shares);
        queuedShares += shares;

        uint256 index = _queue.length;
        _queue.push(WithdrawalRequest({owner: msg.sender, receiver: receiver, shares: shares}));
        _requestIndexPlusOne[msg.sender] = index + 1;

        emit WithdrawalQueued(msg.sender, index, _exitToAssets(shares, Math.Rounding.Floor));
    }

    /// @notice Give up a place in the queue and take the shares back.
    /// @dev Always available. A lender whose shares are escrowed with no way to reclaim them
    ///      would be stranded whenever the queue cannot clear, which is precisely the situation
    ///      the queue exists for.
    function cancelWithdrawalRequest() external nonReentrant {
        uint256 indexPlusOne = _requestIndexPlusOne[msg.sender];
        if (indexPlusOne == 0) revert NothingQueued();

        uint256 index = indexPlusOne - 1;
        uint256 shares = _queue[index].shares;

        _queue[index].shares = 0;
        queuedShares -= shares;
        delete _requestIndexPlusOne[msg.sender];

        // Walk the head past any husks this leaves at the front. Amortised O(1) - `queueHead` only
        // ever moves forward, so each entry is stepped over once in the life of the contract - and
        // it keeps `queuePosition`'s scan short in the ordinary case.
        _advanceHeadPastEmpties();

        _transfer(address(this), msg.sender, shares);
        emit WithdrawalRequestCancelled(msg.sender, index, shares);
    }

    /// @dev A cancelled entry stays in the array so its index remains a stable reference in
    ///      events, which means the array can carry gaps. Nothing may treat a gap as somebody
    ///      waiting.
    ///
    ///      Bounded, for the same reason `serviceQueue` is. The walk was unbounded on the argument
    ///      that it is amortised O(1) - true across the contract's life, and no comfort to the one
    ///      caller who pays for the whole run in a single transaction. Whoever builds the run is
    ///      not who pays for it: queue and cancel repeatedly behind a live entry and the head never
    ///      moves, so the husks pile up in front of it and land on whichever lender cancels next.
    ///      That is `cancelWithdrawalRequest`, the function documented as always available and the
    ///      only way to reclaim escrowed shares. Leaving the head short of a husk costs nothing -
    ///      `queuePosition` and `serviceQueue` both step over husks anyway, and the next call
    ///      carries on from here.
    function _advanceHeadPastEmpties() private {
        uint256 head = queueHead;
        uint256 length = _queue.length;
        uint256 steps;
        while (head < length && steps < MAX_HEAD_ADVANCE && _queue[head].shares == 0) {
            head++;
            steps++;
        }
        queueHead = head;
    }

    /// @notice Collect USDC a serviced withdrawal set aside for you.
    /// @dev The receiver pulls rather than the queue pushing, so an address that cannot take
    ///      delivery fails only its own claim instead of the whole queue's.
    function claim() external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender] = 0;
        totalClaimable -= amount;

        emit WithdrawalClaimed(msg.sender, amount);
        IERC20(asset()).safeTransfer(msg.sender, amount);
    }

    /// @notice Pay out queued withdrawals in order, as far as idle USDC allows.
    /// @dev Permissionless and bounded by `maxEntries`, so it cannot become a call that nobody
    ///      can afford to make. Partial fills are supported: an entry that can only be half paid
    ///      is half paid and keeps its place at the head, which is what stops one large request
    ///      blocking every small one behind it indefinitely.
    ///
    ///      **This function is why an exit gate could never have been the answer, and audit round
    ///      11 is where that was learned.** Six of twelve agents found the same hole independently
    ///      and one of them executed it: the round-10 gate was put on `withdraw`, `redeem`,
    ///      `maxWithdraw` and `maxRedeem`, which is the complete set of ERC-4626 exits and *not* the
    ///      complete set of ways USDC leaves this contract. `requestWithdrawal`, this function and
    ///      `claim` are all permissionless, impose no delay, and compose in a single transaction, so
    ///      a lender could join the queue and pay themselves out of it at the pre-loss price in the
    ///      same block the auction opened. Worse than the door the gate had shut: this path draws on
    ///      `_poolBalance()` where `maxWithdraw` is bounded by `unreservedIdle()`, so it also
    ///      reached the `RESERVE_RATIO_BPS` float the immediate path may not touch.
    ///
    ///      The gate was then extended to cover this function, and that fix is what has now been
    ///      deleted rather than kept. **A gate has to enumerate every door; a price does not.**
    ///      Every valuation below runs at `exitAssets()`, so a door nobody remembered to list is
    ///      priced correctly anyway, which is why the composite route round 11 found is no longer
    ///      worth more than the direct one.
    ///
    ///      **What this used to say next was that a queued lender is paid the same marked-down
    ///      number an immediate one would be, and audit round 16 showed that cannot happen.**
    ///      Since the refusal below was keyed on the standing reserve, `reserved == false` implies
    ///      `exitReserve() == 0` implies `exitAssets() == totalAssets()` - so below the break the
    ///      impaired arithmetic is identical to the un-impaired kind. **This function pays the
    ///      un-impaired price or it pays nobody.** The `_exitToAssets` and `_exitToShares` calls
    ///      below are correct and are, on every reachable path, the plain conversions.
    ///
    ///      **The consequence nobody designed, and it is recorded open rather than fixed here:
    ///      during a mark, queueing strictly dominates withdrawing.** A queued lender waits and is
    ///      eventually paid un-impaired; a lender who exits immediately takes the haircut. That
    ///      inverts the incentive the two-price design was built to create. It belongs with the
    ///      forced-exit pricing work, not with a comment fix. It is recorded as an open finding
    ///      rather than left for a later round to rediscover, and it is open at the time of writing.
    ///
    ///      The header's older claim that queued shares "stay exposed until they are actually paid"
    ///      was true and, on its own, useless: nothing made the queue slow and the lender chose when
    ///      to be paid. It is load-bearing again now, because what they are paid moves with the mark.
    function serviceQueue(uint256 maxEntries) external nonReentrant returns (uint256 serviced) {
        if (maxEntries == 0) revert ZeroAmount();
        uint256 length = _queue.length;
        if (queueHead >= length) revert QueueIsEmpty();

        uint256 idle = _poolBalance();

        // Read once, because it is a property of the book rather than of any entry and nothing in
        // this loop writes any of its four inputs. See the refusal below for why the cause and not
        // the truncation.
        bool reserved = exitReserve() != 0;

        uint256 headBefore = queueHead;
        uint256 index = queueHead;
        uint256 examined;
        // Memory only, and its whole job is to tell the two refusals apart at the bottom.
        bool heldByReserve;
        // `idle` is deliberately NOT in this condition. Two of the branches below move no money at
        // all - stepping over a husk, and releasing dust - and both advance the head, which is the
        // progress the revert guard at the bottom exists to commit. Gating the whole loop on idle
        // made them unreachable exactly when the pool is fully lent, which is the state the queue
        // is for. The paying branch checks idle for itself.
        while (index < length && examined < maxEntries) {
            WithdrawalRequest storage request = _queue[index];
            uint256 shares = request.shares;

            // Cancelled entries are left in place with zero shares so indices stay stable.
            // Advance the head over them too, or a husk at the front would make every later
            // `queuePosition` scan walk it again.
            if (shares == 0) {
                index++;
                if (queueHead == index - 1) queueHead = index;
                examined++;
                continue;
            }

            // Shares that cannot be valued at even one asset-wei **on the un-impaired book**.
            // Paying them is arithmetically impossible, and leaving them is worse than useless: the
            // entry would sit at the head forever, every later call would stop on it, and
            // `queuedShares` would never return to zero - which pins `available()` at zero and
            // stops the pool lending at all. So release them back to their owner, exactly as a
            // cancel would, and step past.
            //
            // **Keyed on the entry price alone since audit round 15, and the guard that used to
            // stand inside it has moved out.** This used to ask `owed == 0` first and then check
            // the un-impaired value to tell genuine dust from a marked-down lender. Asking the
            // question in that order made the answer depend on a truncation rather than on its
            // cause, and the two are one wei apart: see the standing-reserve refusal below.
            if (convertToAssets(shares) == 0) {
                // **Worthless and marked down to nothing are not the same thing, and audit round
                // 12 found this branch could not tell them apart.** The exit price is what
                // `serviceQueue` pays at, so a deep enough impairment values every entry in the
                // queue at zero - and the pool being fully lent is exactly when `exitAssets()` can
                // reach zero, because `maxWithdraw` carries no reserve holdback and an unqueued
                // lender can drain the float first. One permissionless call then handed the whole
                // queue back, and whoever re-queued first took the head.
                //
                // A markdown is temporary; a lost place in a FIFO queue is not. So the release asks
                // the *un-impaired* valuation, which is what "this can never be worth an asset-wei"
                // actually means. Genuine dust still releases, because dust is worth nothing at
                // either price.
                request.shares = 0;
                queuedShares -= shares;
                delete _requestIndexPlusOne[request.owner];
                _transfer(address(this), request.owner, shares);

                emit QueuedWithdrawalReleasedAsDust(request.owner, index, shares);
                index++;
                queueHead = index;
                serviced++;
                examined++;
                continue;
            }

            // **A live entry is not crystallised while a reserve stands against the book, and this
            // is keyed on the cause rather than on a truncation.** Audit round 15 executed what the
            // old shape cost. The refusal used to live inside `owed == 0`, which is a truncation
            // event, and the cliff either side of it is one wei wide:
            //
            //   - at `idle == 0` the head valued at zero, the guard fired, the shares stayed
            //     escrowed. That was the protection working.
            //   - at `idle == 1` the same head valued at exactly one wei, missed the guard, fell
            //     into the full-fill branch below, and `owed <= idle` burned a ten-trillion-share
            //     position for a single wei of USDC.
            //
            // `exitAssets()` is bounded below by the idle balance, because the reserve clamps to
            // `outstandingPrincipal`. So one free `withdraw()` before the mark decides which side
            // of that line a queued lender lands on, and the old guard covered the measure-zero
            // worst case and nothing one wei away from it, where the harm is 99.99999%.
            //
            // One global read, taken once before the loop: it is a property of the book, identical
            // for every entry, so it stops the cursor for everybody or for nobody. That is honest
            // FIFO shortage, not the shared-cursor poisoning the rule above forbids. It is
            // deliberately **not** a price floor and deliberately **not** per-entry - audit round
            // 13 shipped that shape and audit round 14 deleted it.
            //
            // **The cost, stated as a cost, because it is real and it is not free.** More entries
            // stop here than stopped at the old guard, so the stall is wider: any non-zero reserve
            // suspends the paying walk until the liquidation resolves. Against that, the burn it
            // replaces was unrecoverable and stranger-timed, while the stall moves no money,
            // destroys no claim, and has an exit the affected lender controls -
            // `cancelWithdrawalRequest` is always available and unguarded, and after it `withdraw`
            // and `redeem` are open at the impaired price up to `unreservedIdle()`. So it converts
            // a markdown crystallised at a stranger's chosen instant into one the lender chooses
            // themselves, which is the premise the whole industry norm rests on and the premise
            // audit round 15 proved we lacked.
            //
            // It compounds with the `unreservedIdle()` over-reservation, which is a separate open
            // finding: during a mark the queue is suspended and an unqueued lender's `maxWithdraw`
            // can already be zero, which narrows the very escape being relied on. Recorded, not
            // fixed here.
            //
            // **This is where the contingent-entitlement branch goes when it is built**: retire the
            // node, carry the claim, advance the cursor. Until that exists, stopping is the only
            // option that neither crystallises a temporary markdown nor forgets a live entry.
            //
            // **Audit round 20 put numbers on both halves of that trade, and they are worth having
            // here before anyone builds the branch.**
            //
            // The stall's worst case is longer than the paragraph above assumes. It is not bounded
            // by `AUCTION_DURATION`: `LiquidationAuction.expireToWorkout` is permissionless, costs
            // its caller nothing but gas, and is legal at the instant the bid window lapses, and it
            // replaces a six-hour mark with one that stands for `Config.WORKOUT_MAX_DURATION`.
            // Measured in `LenderPoolExitPricing.t.sol` against a control that fills the same lot at
            // the same instant: the fill resolves, reopens the queue and pays the lender in full
            // with `lifetimeSocialisedLoss` at zero, while one free transaction from a stranger with
            // no shares holds this break for fourteen days. `Config.AUCTION_RESET_WINDOW` bounds
            // re-strikes and does not reach that lever, so the cost model it was chosen under does
            // not cover this one. The lever is in the auction, not here.
            //
            // The escape is real and it is priced, and the price is not a penalty. Measured on the
            // same fixture: what a lender gives up by cancelling and taking the ERC-4626 door is
            // `exitReserve() / totalAssets()` of their stake, to within rounding - their own
            // pro-rata share of the mark and nothing besides. `CreditManager._impairmentFor` calls
            // that the intended direction of the whole-debt mark. What they could not do until
            // audit round 20 was bound the price of that exit against a stranger moving it in the
            // same block, which the four-argument doors now let them do.
            //
            // **And the obvious contingent branch is not neutral, which is why it is still not
            // built.** Paying a queued lender their pro-rata share of the *unreserved* book now, at
            // the un-impaired price, leaves the un-impaired share price exactly unchanged and
            // spreads the same reserve over a smaller remaining book: measured, every stayer's
            // worst case falls by about 45%. That is a partial answer that moves a loss onto
            // whoever stayed, which is the shape rounds 12, 13 and 14 each shipped and then
            // deleted. Whatever gets built here has to answer that first.
            if (reserved) {
                heldByReserve = true;
                break;
            }

            // Nothing left to pay with. Everything cash-free has already been done above, so stop
            // rather than spin: the head has advanced as far as it can without money.
            if (idle == 0) break;

            // Fully funded: burn the whole entry against exactly what it is worth. Converting the
            // assets back into shares here is what used to strand these entries - both conversions
            // floor, so the round trip returned fewer shares than were owed and the remainder kept
            // the entry alive after its owner had been paid in full. There is nothing to convert:
            // the shares are known, and `owed` is what they are worth.
            //
            // **`_exitToAssets` here is the plain conversion on every reachable path**, because the
            // break above means nothing is reserved. Kept as the exit form rather than swapped for
            // `convertToAssets`, so this stays correct if the refusal is ever narrowed - but it is
            // not evidence the queue prices at a mark, and the header no longer says it is.
            uint256 owed = _exitToAssets(shares, Math.Rounding.Floor);

            uint256 sharesToBurn;
            uint256 assetsOut;
            if (owed <= idle) {
                sharesToBurn = shares;
                assetsOut = owed;
            } else {
                // Partial fill. Convert the cash back into shares so the burn matches the money
                // leaving, rounding in the pool's favour. Rounding the other way would let a
                // sequence of dust-sized partial fills burn more shares than the USDC covers.
                sharesToBurn = _exitToShares(idle, Math.Rounding.Floor);
                if (sharesToBurn == 0) break;
                if (sharesToBurn > shares) sharesToBurn = shares;

                assetsOut = _exitToAssets(sharesToBurn, Math.Rounding.Floor);
                if (assetsOut == 0) break;
            }

            request.shares = shares - sharesToBurn;
            queuedShares -= sharesToBurn;
            idle -= assetsOut;

            _burn(address(this), sharesToBurn);
            serviced++;
            examined++;

            // Emitted before the head moves. Emitting after the increment named the entry *behind*
            // the one that was paid, on exactly the fills that clear an entry - which defeats the
            // reason husks are left in the array at all, namely that an index stays a stable
            // reference in events.
            emit QueuedWithdrawalServiced(request.owner, index, assetsOut);

            // Set aside rather than sent. The receiver collects it with `claim()`; see the
            // `claimable` declaration for why a push here handed one entry a veto over the queue.
            claimable[request.receiver] += assetsOut;
            totalClaimable += assetsOut;

            // The one exit that does not run through `_withdraw`, so the deposit-cap counter is
            // decremented here instead. Done at the set-aside rather than at `claim`, because this
            // is the moment the shares are burned and the capital stops being the pool's.
            //
            // **Same pro-rata rule as `_withdraw`, and this is a second writer, not the same one.**
            // `_withdraw` is not `virtual` and `_reduceNetDeposits` is `private`, so round 21 could
            // not validate the rule by subclassing - and had it been subclassable, the natural fix
            // would have closed the ERC-4626 door and left this one open while reading like
            // closure. The burn above has already happened, so the supply is reconstructed.
            _reduceNetDeposits(_principalPortion(sharesToBurn, totalSupply() + sharesToBurn));

            if (request.shares == 0) {
                delete _requestIndexPlusOne[request.owner];
                index++;
                // Not past a live entry this call stepped over - see the floor branch above.
                queueHead = index;
            }

            // A partial fill leaves shares on the entry, and means idle ran out on it - so there is
            // nothing left for anyone behind. Stopping here also keeps `serviced` an honest count
            // of entries rather than of loop iterations: without it the loop re-enters on the same
            // index with the rounding dust still in `idle` and counts one entry twice.
            if (request.shares != 0) break;
        }

        // Advancing the head is progress even when no USDC moved, and it must be allowed to
        // commit. Reverting on `serviced == 0` alone threw away the head advance the husk branch
        // had just made, so a call whose `maxEntries` ran out while stepping over cancelled
        // entries failed *and* undid its own work - and then failed identically on every retry,
        // because the state it needed to get past was restored each time. Servicing the queue
        // would have required one call with `maxEntries` greater than the run of husks in front of
        // the next live entry, and a lender can lengthen that run at will by queueing and
        // cancelling behind someone: past a few thousand husks no single call fits in a block and
        // the queue is shut for good. With this, repeated bounded calls always chew through.
        if (serviced == 0 && queueHead == headBefore) {
            // **Which refusal this is, because the two want opposite things from the caller.**
            // A genuine shortage means wait; a standing reserve means find out whether it is
            // stale, and `CreditManager.refreshImpairments` is now a bounded permissionless call
            // that needs no borrower address. `NothingToService` said only "nothing happened",
            // which is exactly what a real shortage says, and audit round 16 recorded a case where
            // the cause was a mark the yield stream had already paid off while the pool sat on
            // 24,371 USDC of idle cash.
            //
            // **This changes what the refusal says and never when it fires.** `heldByReserve` is
            // memory, set where the walk stopped; the loop and its guards are untouched.
            if (heldByReserve) revert QueueHeldByReserve(exitReserve());
            revert NothingToService();
        }
    }

    /// @notice Where a lender sits, and what they are owed at today's share price.
    /// @return index how many lenders are genuinely ahead of them, 0 meaning next
    /// @return remaining assets still owed, valued now rather than at request time
    /// @dev Counts *live* entries rather than array slots. Subtracting `queueHead` from the raw
    ///      index is the obvious implementation and it is wrong: cancelled requests stay in the
    ///      array as zero-share husks so their indices remain stable in events, so the raw
    ///      distance counts people who are not waiting. A lender told they are second when they
    ///      are next has been given a number that will not match what happens.
    ///
    ///      Linear in the gap between the head and the caller, which is bounded in practice by the
    ///      deposit cap and shortened by `_advanceHeadPastEmpties`. It is a view; off-chain callers
    ///      pay nothing for it.
    function queuePosition(address lender) external view returns (uint256 index, uint256 remaining) {
        uint256 indexPlusOne = _requestIndexPlusOne[lender];
        if (indexPlusOne == 0) return (0, 0);

        uint256 absolute = indexPlusOne - 1;
        for (uint256 i = queueHead; i < absolute; i++) {
            if (_queue[i].shares != 0) index++;
        }
        remaining = _exitToAssets(_queue[absolute].shares, Math.Rounding.Floor);
    }

    /// @notice Total entries ever queued, including serviced and cancelled ones.
    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    /// @notice Read a queue entry by absolute index, as reported in events.
    function queueEntry(uint256 index) external view returns (address owner, address receiver, uint256 shares) {
        WithdrawalRequest storage request = _queue[index];
        return (request.owner, request.receiver, request.shares);
    }
}
