// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC20, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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
///      `exitAssets()`, which already carries it. Entries never deduct that impairment. During an
///      active yield stream their previews additionally price the projected unreleased tail, while
///      the ERC-4626 conversion views remain on released `totalAssets()`. See `previewDeposit`,
///      `previewRedeem` and `exitAssets` for why those two asymmetries are mechanisms rather than
///      inconsistencies, and for the Maple source the impairment split was verified against.
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
contract LenderPool is ERC4626, ILenderPool, Ownable, Pausable, ReentrancyGuard {
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
    /// @notice A bounded `deposit` minted fewer shares than the caller said they would accept.
    error SharesBelowMinimum(uint256 shares, uint256 minShares);
    /// @notice A bounded `mint` would have cost more assets than the caller said they would pay.
    error AssetsAboveMaximum(uint256 assets, uint256 maxAssets);
    /// @notice Shares were sent to this contract by a door that is not `requestWithdrawal`.
    error EscrowIsNotAHolder();
    /// @notice A pause switch was reached by an address that is neither the owner nor the guardian.
    /// @dev Same name and arity as `CollateralVault`'s and `CreditManager`'s, deliberately. One role
    ///      sits across the three contracts, and an operator reading a failed incident transaction
    ///      should not have to work out which of three spellings they are looking at.
    error NotOwnerOrGuardian();
    /// @notice `setGuardian` refused a guardian equal to `owner()`.
    error GuardianMustDifferFromOwner();

    // Everything this contract emits that `ILenderPool` describes is declared *there*, including
    // `YieldDistributed`, `Impaired`, `ImpairmentReleased`, `LossReservesSet` and the four queue
    // events. Re-declaring any of them here would not compile, which is the point - see decision 5
    // in the header. What remains below is machinery the interface does not promise.

    event CreditManagerSet(address indexed creditManager);
    event EpochHarvesterSet(address indexed epochHarvester);
    /// @notice The guardian was installed, moved or cleared. Zero means the role is unfilled.
    /// @dev **The name and the arity match `CollateralVault.GuardianSet` and
    ///      `CreditManager.GuardianSet` on purpose**, which is the same match the vault's own
    ///      comment records as deliberate. One role across three contracts is one event topic to
    ///      subscribe to, and a written procedure that has to name three signatures for one act is
    ///      a procedure somebody gets wrong during the incident.
    event GuardianSet(address indexed guardian);
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

    /// @dev The ceiling `totalPrincipalUnits` is renormalised back under. See `_renormaliseUnits`.
    ///
    ///      **Audit round 23, finding 7: the principal-unit quotient had no bound at all.** A loss
    ///      lowers `netDeposits` and leaves the units alone, so `_deposit`'s issuance ratio
    ///      `totalPrincipalUnits / netDeposits` only ever rises. Nine measured loss-and-recovery
    ///      cycles took it past `type(uint256).max`, and `Math.mulDiv` then shut the deposit door
    ///      of an immutable contract for good. A ceiling bounds the quotient rather than
    ///      rate-limiting it, which is the difference between a fix and a delay.
    ///
    ///      Derived, not picked. Issuance is `mulDiv(assets, U, N)`, which carries the full 512-bit
    ///      product, so the binding constraint is the aggregate `U + units` staying inside 256 bits.
    ///      `units <= ceil(assets * U / N)` and `N >= 1` whenever `U != 0`, so the worst case is
    ///      `assets * U`; `assets` is bounded by `depositCap`, itself bounded by
    ///      `GLOBAL_BORROW_CAP_MAX` of 250,000e6, which is under `2**38` USDC-wei. `2**128 * 2**38`
    ///      is `2**166`, leaving 90 bits above any single post-renormalisation issuance. Underneath,
    ///      `2**127` of resolution is 38 decimal digits against a counter that never exceeds eleven,
    ///      so the bits a shift destroys are far below one asset-wei of basis. Lower loses holder
    ///      resolution on every shift; higher loses headroom above the aggregate.
    uint256 private constant PRINCIPAL_UNIT_CEILING = 1 << 128;

    address public creditManager;
    address public epochHarvester;

    /// @notice The second key that may halt lender entry. Zero means the role is unfilled, which is
    ///         the shipped default.
    /// @dev Go-live item G4, third contract. See `pause()` for why this switch is guardian-reachable
    ///      when the vault's bond-deposit switch deliberately is not.
    address public guardian;

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
    ///      Each share holder carries loss-adjusted principal units, so an exit removes the
    ///      principal attached to the shares it burns rather than treating yield as principal.
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

    /// @notice Principal-accounting units held by each share holder.
    /// @dev Units are distinct from vault shares. Vault shares price the economic claim, while
    ///      these units remember how much admitted principal that claim carries. A realised loss
    ///      reduces `netDeposits` without reducing the units, so every unit that existed when the
    ///      loss landed is marked down by the same ratio. A later deposit mints units at that lower
    ///      ratio and therefore does not inherit the earlier loss.
    ///
    ///      Units are a scalar balance on a fungible ERC-20. If differently priced lots merge in
    ///      one account and are later split, their basis is averaged; exact lot identity cannot be
    ///      reconstructed from one balance. Two integer boundaries can also loosen the cap by at
    ///      most one asset unit each: double-ceiling after a loss, and a no-loss dust-share split
    ///      whose rounded unit is then burned by a zero-asset redemption. All three residuals have
    ///      deterministic tests and keep the broader finding only partly closed.
    mapping(address account => uint256 units) private _principalUnits;

    /// @dev Generation tags let a total loss invalidate old zero-basis units in O(1). Old vault
    ///      shares remain transferable, but they carry no principal after `netDeposits` reaches
    ///      zero. A later deposit starts the next generation at par.
    mapping(address account => uint256 generation) private _principalUnitGeneration;
    uint256 private _principalGeneration = 1;

    /// @dev The exponent every stored unit figure is quoted against. See `_renormaliseUnits`.
    ///      Only ever rises, so `unitExponent - stamp` cannot underflow at any read site.
    mapping(address account => uint256 exponent) private _principalUnitExponent;

    /// @notice Cumulative binary renormalisation applied to the principal-unit ledger.
    /// @dev A stored unit figure stamped at exponent `e` is worth `stored >> (unitExponent - e)`
    ///      today. Public because a renormalisation is irreversible and destroys low-order bits of
    ///      every holder's basis; an off-chain reader that caches unit figures needs to see it move.
    uint256 public unitExponent;

    /// @notice Total principal-accounting units in the current generation, at `unitExponent`.
    /// @dev Repeated near-total losses and recapitalisations make this quotient grow quickly. It is
    ///      bounded above by `PRINCIPAL_UNIT_CEILING`, which `_renormaliseUnits` restores after
    ///      every issuance. Round 23's finding 7 is the measurement of what happens without one.
    uint256 public totalPrincipalUnits;

    /// @dev Queue cancellation and service must move the units recorded for that request, not the
    ///      blended ratio of every lender whose shares share this contract as escrow. These fields
    ///      stage one exact internal transfer or burn through `_update`.
    bool private _hasExactPrincipalUnitMove;
    uint256 private _exactPrincipalUnitsToMove;

    /// @dev `principalUnitExponent` is appended last on purpose. A struct reordering ships a silent
    ///      breaking change to anything that destructures positionally, which round 22 found the
    ///      hard way.
    struct WithdrawalRequest {
        address owner;
        address receiver;
        uint256 shares;
        uint256 principalUnits;
        uint256 principalGeneration;
        uint256 principalUnitExponent;
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

    /// @notice Install, move or clear the guardian (go-live item G4). Zero disables the role.
    /// @dev Copied in shape from `CollateralVault.setGuardian`, including the refusal of
    ///      `owner()` and the reason for it: a single address holding both roles is exactly the
    ///      configuration the second key does not defend against. As there, the comparison is
    ///      against the owner **at the time of the call**, so a later `transferOwnership` to the
    ///      guardian collapses the pair - the G2 handover is such a transfer, so re-read the
    ///      guardian after it. `DeployBase._assertWiring` is what re-reads it.
    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == owner()) revert GuardianMustDifferFromOwner();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @notice Halt new lender entry. Callable by the owner **or** the guardian.
    /// @dev **Guardian-reachable, where the vault's bond-deposit switch deliberately is not, and
    ///      the difference is the whole argument.** Audit round 27 refused a guardian-reachable
    ///      pause next door because the vault case handed the guardian the borrower's *cure*: a
    ///      borrower who cannot deposit bonds cannot climb out of a liquidation. Nothing here shuts
    ///      a cure. `withdraw`, `redeem`, `requestWithdrawal`, `serviceQueue` and `claim` are all
    ///      untouched by this switch and stay correct while it is on, so the worst a compromised
    ///      guardian can do is cost the pool a few hours of inflow - against the harm it prevents,
    ///      which audit round 25 measured as a lender depositing during an incident and taking the
    ///      write-down that followed: **10,000.000000 redeemable in, 9,750.000000 out.** That
    ///      asymmetry is what puts this switch on the fast key.
    ///
    ///      Nothing here freezes the yield stream or the clock. A pause that stopped accrual would
    ///      be a change to the price every existing lender exits at, which is the opposite of
    ///      leaving the exits correct.
    function pause() external {
        _requireOwnerOrGuardian();
        _pause();
    }

    /// @dev `onlyOwner`, and not owner-or-guardian, for the reason `CollateralVault.unpause` gives:
    ///      a compromised guardian must not be able to reopen the door during a live incident. The
    ///      expensive direction of the two is reopening, and the timelock cost that carries is paid
    ///      for by this pause never having shut an exit in the first place.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Reads `owner()` and `guardian` rather than taking either as an argument, so there is
    ///      one place the rule is written. A zero `guardian` cannot match a caller, because
    ///      `msg.sender` is never the zero address.
    function _requireOwnerOrGuardian() private view {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
    }

    /// @notice Principal-accounting units carried by `account` in the current loss generation.
    /// @dev Two lazy adjustments, in this order: the generation tag invalidates units a total loss
    ///      wrote off, and `unitExponent` rescales what survives. Neither iterates over holders.
    function principalUnits(address account) public view returns (uint256) {
        if (_principalUnitGeneration[account] != _principalGeneration) return 0;
        return _scaleToCurrentExponent(_principalUnits[account], _principalUnitExponent[account]);
    }

    /// @dev Brings a figure stamped at `stamp` up to `unitExponent`. `unitExponent` only ever rises
    ///      and every stamp is a value it once held, so the subtraction cannot underflow. A cumulative
    ///      shift of 256 bits or more yields zero rather than reverting, which is `SHR`'s defined
    ///      behaviour and the honest answer: a holder who has sat untouched through that many bits of
    ///      renormalisation has no resolution left. They keep their shares and their money; what they
    ///      lose is the cap-counter credit their principal was holding, which is the same thing the
    ///      shift costs everyone, only taken all the way down.
    function _scaleToCurrentExponent(uint256 units, uint256 stamp) private view returns (uint256) {
        return units >> (unitExponent - stamp);
    }

    /// @notice The loss-adjusted, fungibly averaged principal carried by `account`'s shares.
    /// @dev Rounded up so a partial exit cannot leave deposit-cap debt behind. Across all holders,
    ///      the total rounding surplus is strictly less than one asset unit per holder. This is an
    ///      accounting basis, not recoverable per-deposit lot provenance after balances merge.
    function principalBasis(address account) public view returns (uint256) {
        uint256 units = principalUnits(account);
        uint256 totalUnits = totalPrincipalUnits;
        if (units == 0 || totalUnits == 0) return 0;
        if (units == totalUnits) return netDeposits;
        return Math.mulDiv(netDeposits, units, totalUnits, Math.Rounding.Ceil);
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

    /// @notice The gross value used only to quote and execute ERC-4626 entries.
    /// @dev `totalAssets()` holds an active stream's projected tail out of released NAV. Selling
    ///      new shares against that smaller figure after delivery lets the entrant capture part of
    ///      the tail as it releases, diluting the shares that formed the delivered cohort. Adding
    ///      the live tail back here makes a newcomer pay for that value without stepping the exit
    ///      price or changing the standard `convertToAssets` and `convertToShares` views.
    ///
    ///      A frozen backlog is deliberately different. `yieldRate == 0` means no cohort is being
    ///      paid and time releases nothing; the next delivered epoch establishes the cohort when
    ///      `_rateStream` folds the backlog into a live pot. Charging a depositor for that frozen
    ///      money before then would make its principal depend on value it cannot yet earn.
    ///
    ///      Impairments are not deducted here. Entry pricing remains on the un-impaired book so an
    ///      entrant cannot buy the discount and profit when the mark is released.
    function _entryAssets() private view returns (uint256 assets) {
        assets = totalAssets();
        if (yieldRate != 0) assets += unreleasedYield();
    }

    /// @dev OpenZeppelin 5.6.1's entry conversion with `_entryAssets()` substituted for
    ///      `totalAssets()`. The virtual one asset and `10 ** _decimalsOffset()` shares are kept
    ///      exactly, including the deposit-side floor that prevents over-issuing shares.
    function _entryToShares(uint256 assets) private view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), _entryAssets() + 1, Math.Rounding.Floor);
    }

    /// @dev The exact-share inverse of `_entryToShares`, retaining OpenZeppelin's asset-side
    ///      ceiling so a mint never underpays the gross entry price.
    function _entryToAssets(uint256 shares) private view returns (uint256) {
        return Math.mulDiv(shares, _entryAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @notice What the pool is worth to somebody leaving it: assets less reserved shortfalls.
    /// @dev The entry side deliberately does **not** deduct this. Its active-tail adjustment is
    ///      independent of the impairment split; see `_entryAssets` and `previewDeposit`. Not
    ///      deducting the reserve is the whole impairment mechanism, and it is Maple's: an entrant
    ///      who bought at the impaired price would profit when the impairment was released, which
    ///      is round-11's buy-the-dip finding arriving through the front door instead.
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
    ///      An exit debits the counter through the holder's own principal units in `_update`, not
    ///      through the assets it is paid. Debiting assets mixed yield into a principal counter and
    ///      ratcheted it down against a clamp that could not net it back up.
    ///
    ///      **A pause is reported here as a ZERO CAP and never as a revert**, and the sentence two
    ///      paragraphs up is why: EIP-4626 requires this function to return zero when deposits are
    ///      disabled, *including temporarily*, and forbids it from reverting under any condition.
    ///      A revert here would not stop an integrator, it would break one - a router that reads
    ///      this to size a deposit gets an unexplained failure in a view instead of a zero it knows
    ///      how to handle. The refusal itself lives on `deposit` and `mint`, where a revert is
    ///      what the standard expects; see `pause()`.
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (paused()) return 0;
        uint256 taken = netDeposits;
        uint256 cap = depositCap;
        return taken >= cap ? 0 : cap - taken;
    }

    /// @inheritdoc ERC4626
    /// @dev Converts the remaining asset cap at the same gross active-tail price `previewMint`
    ///      executes. Rounding down guarantees the quoted share maximum costs no more than
    ///      `maxDeposit(receiver)` when `previewMint` applies its inverse ceiling.
    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        return _entryToShares(maxDeposit(receiver));
    }

    /// @inheritdoc ERC4626
    /// @dev Prices a deposit against the un-impaired book plus the projected tail of a live yield
    ///      stream. A post-delivery entrant therefore pays for the whole active pot and cannot
    ///      dilute the delivered cohort as it releases. Frozen yield stays excluded until a later
    ///      epoch re-rates it. `_entryToShares` preserves OpenZeppelin's virtual terms and floor.
    function previewDeposit(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        return _entryToShares(assets);
    }

    /// @inheritdoc ERC4626
    /// @dev The exact-share inverse of `previewDeposit`, on the same gross active-tail basis and
    ///      with OpenZeppelin's ceiling rounding. It intentionally can exceed `convertToAssets`
    ///      during a live stream; the conversion view continues to report released NAV.
    function previewMint(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        return _entryToAssets(shares);
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
    ///
    ///      **Derived from `maxRedeem` since audit round 22 finding 2, and the paragraph above is
    ///      what that finding is about.** Taking a second minimum here, against an asset figure,
    ///      was fine while the reserve was a fraction of the book and catastrophic at the one point
    ///      that is not an edge case. `exitReserve()` clamps to `outstandingPrincipal`, so once
    ///      `totalImpairment >= outstandingPrincipal` the reserve *is* the whole loan,
    ///      `exitAssets()` collapses onto the idle cash, and the two terms above - the exit value of
    ///      the caller's shares, and `unreservedIdle()` - become the same number. `previewWithdraw`
    ///      then charges nearly the whole position for that cash. That state is not exotic:
    ///      `CreditManager._impairmentFor` marks `currentDebtOf`, and
    ///      `outstandingPrincipal == pendingPrincipal + totalDebt`, so a single-borrower book -
    ///      which is the shape of the Base Sepolia deployment and of launch - reaches it through one
    ///      permissionless `liquidate`.
    ///
    ///      MEASURED on the real graph in `Impairment.integration.t.sol`, nothing pranked as the
    ///      manager: `maxWithdraw` read 19,371.250000 with and without the `liquidate`, but the
    ///      share cost went from 19,371,250,000,000 to 19,999,999,999,968 out of twenty trillion,
    ///      leaving a supply of **32**. The auction then filled with `lifetimeSocialisedLoss` at
    ///      zero - the protocol realised no loss at all - and the lender's residue was worth
    ///      19.496124 against the control's 628.749999: a **609.253876** hole with nobody on the
    ///      other side of it, because what the residue stopped owning went to the virtual shares,
    ///      which nobody can ever redeem.
    ///
    ///      **The fix is a bound on the shares an exit may burn, not a different price.**
    ///      `previewWithdraw`, `previewRedeem`, `_exitToShares`, `_exitToAssets`, `exitAssets` and
    ///      `exitReserve` are untouched: a leaver is paid exactly what they were paid before. What
    ///      changed is that the liquidity cap is converted to shares on the **un-impaired** book,
    ///      so it caps the burn at the fraction of the supply the idle cash actually represents,
    ///      and the asset figure is then derived from it at the exit price.
    ///
    ///      **Raising `_decimalsOffset()` does not do this**, and that function's own NatSpec names
    ///      it as the inflation defence, so it is the first thing a reader will reach for. The
    ///      void's cut is `1 / (D(L-M)/(D-M) + 1)` in the deposit `D`, the loan `L` and the mark
    ///      `M`; `10 ** offset` cancels out of it. Inert, algebraically, at any offset.
    ///
    ///      **Two precedents this is not, because the next round will reach for both.**
    ///      Round 10's gate returned a flat **zero** from here while any loss could land, and read
    ///      the manager and the auction to decide - three unguarded external calls on the only exit.
    ///      This reads storage only, cannot revert, and never returns zero for a lender with shares
    ///      while any cash is unspoken-for. Round 14 deleted a per-entry stored `minAssets` field on
    ///      the shared FIFO loop, where one lender's parameter decided another lender's turn; see
    ///      `requestWithdrawal` for all four of its failure modes and for the rule it ends on -
    ///      "change what the queue *pays*, not who it is allowed to walk past". This is per-caller,
    ///      computed at read time, on the caller's own door, and it is not the queue.
    ///
    ///      **What it costs on the un-marked path, stated rather than claimed away.** Deriving this
    ///      composes two floors where the old expression had one. On an exact `10 ** offset` share
    ///      price, or whenever the caller's own balance is the binding term, the figure is
    ///      identical. On an inexact price with the idle cash binding it is exactly **one wei
    ///      lower** and never higher - measured at 8,304.579169 against 8,304.579170. That is the
    ///      conservative side of a disagreement the pair already had rather than a new one: this
    ///      used to report the whole idle balance while `maxRedeem` reported the share count that
    ///      pays one wei less than it, so the asset figure was not executable through the share
    ///      door. Rounding the conversion up instead restores the exact figure here and lets
    ///      `maxRedeem` report a payout larger than the cash the pool holds once the share price is
    ///      high enough, which a socialised loss reaches; a maximum that cannot be executed is the
    ///      worse defect, so the floor stays.
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    /// @inheritdoc ERC4626
    /// @dev The share-denominated twin of `maxWithdraw`, and now the primary of the pair: the
    ///      liquidity cap is an asset quantity and this is where it becomes a share count, so this
    ///      is the function the bound lives on and `maxWithdraw` is derived from it. Read
    ///      `maxWithdraw`'s note for what the pair costs under a mark, for what the old shape cost,
    ///      and for the two precedents this is not. ERC-4626 forbids this from reverting and it
    ///      makes no external call, so it cannot.
    ///
    ///      **`convertToShares` rather than `_exitToShares`, and that one word is the fix.** The
    ///      cap being converted is a quantity of *cash sitting in this contract*, so the question it
    ///      answers is "what fraction of the book is that cash", which is a question about the
    ///      un-impaired book. Asking it at the exit price makes the answer grow as the mark grows,
    ///      until at a whole-loan mark it is the entire supply - which is the finding. It is the
    ///      same argument `unreservedIdle` and `available` give for holding back the un-impaired
    ///      claim, arriving on the third of the three functions that share it.
    ///
    ///      **Inert while nothing is reserved, by construction rather than by rounding**:
    ///      `exitReserve() == 0` implies `exitAssets() == totalAssets()`, and then `convertToShares`
    ///      and `_exitToShares(_, Floor)` are the same expression.
    ///
    ///      **This restores an ERC-4626 identity this contract had broken.** OpenZeppelin is pinned
    ///      at 5.6.1, where the base `maxWithdraw(owner)` *is* `previewRedeem(maxRedeem(owner))` and
    ///      `withdraw`/`redeem` enforce their maximum with `ERC4626ExceededMaxWithdraw` /
    ///      `ERC4626ExceededMaxRedeem`. Overriding the two independently broke it; the audit
    ///      measured the shipped pair agreeing only to within two wei. Exact is what makes the
    ///      reported maximum an executable bound rather than a quote, and
    ///      `testFuzz_R22F2_theMaxViewsConformAcrossTheMarkRange` asserts it as an equality.
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 shares = balanceOf(owner);
        uint256 idleShares = convertToShares(unreservedIdle());
        return shares < idleShares ? shares : idleShares;
    }

    /// @inheritdoc ERC4626
    /// @dev **The exit side of the dual price.** `previewDeposit` and `previewMint` deliberately
    ///      do not deduct the impairment, so an entrant cannot buy that discount and profit when
    ///      the impairment is released. During a live stream they also add the projected tail to
    ///      the entry basis; that is a separate anti-dilution adjustment. Maple documents the
    ///      impairment arbitrage as the reason for the first split.
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
    ///
    ///      **`whenNotPaused` here as well as the zero cap in `maxDeposit`, and the pair is
    ///      deliberate.** The zero cap alone would already refuse this deposit, because the line
    ///      below reads `maxDeposit` - but it would refuse it as `DepositCapExceeded(assets, 0)`,
    ///      which tells a lender the pool is full when the truth is that the pool is shut. The
    ///      modifier runs first and says `EnforcedPause()` instead. OpenZeppelin's own error rather
    ///      than a bespoke one, so the three contracts carrying this role refuse in one voice and
    ///      the dApp's error union already knows the selector.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256) {
        if (receiver == address(this)) revert EscrowIsNotAHolder();
        uint256 remaining = maxDeposit(receiver);
        if (assets > remaining) revert DepositCapExceeded(assets, remaining);
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    /// @dev The exact-share twin of `deposit` above, gated identically and for the same reasons.
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256) {
        if (receiver == address(this)) revert EscrowIsNotAHolder();
        uint256 remaining = maxMint(receiver);
        if (shares > remaining) revert DepositCapExceeded(shares, remaining);
        return super.mint(shares, receiver);
    }

    /// @notice Deposit, refusing to accept fewer than `minShares` shares in return.
    /// @dev **The entry-side half of the bound audit round 20 put on the exits, and audit round 23
    ///      finding 3 is why it is here.** PR #247 made the entry price a function of
    ///      `pendingYield` and `yieldRate` - `_entryAssets()` adds a live stream's projected tail
    ///      back on, so a newcomer pays for value the delivered cohort is owed. That was the right
    ///      change and it is not undone here. What it also did was make the entry quote *steppable*
    ///      by a stranger, and unlike the exits there was no door through which a caller could
    ///      decline the step.
    ///
    ///      **Every writer of that basis sits behind a gate that checks no identity**, which is the
    ///      finding. `distributeYield` is reached from `EpochHarvester.flushLenderYield()`;
    ///      `recoverLoss` from `LiquidationAuction.workoutSettleAfterClose()` by way of
    ///      `CreditManager.recoverWrittenDownLoss`; `repayPrincipal` from
    ///      `CreditManager.settlePrincipal()`. All three raise `_entryAssets()`, which lowers the
    ///      shares a fixed sum of USDC buys. MEASURED on the round-23 fixture: a 909 bps quote
    ///      shortfall on one flush, with what the entrant lost and what the incumbent gained
    ///      balancing to 1 wei, so this is a transfer between lenders and not an accounting
    ///      artefact.
    ///
    ///      **The three are not equally exposed, and `EntryStepReachability.t.sol` is what measured
    ///      that rather than reading it.** Driven end to end from an address with no role: the
    ///      epoch leg is reachable and its size is the lender split of an epoch the farm produced,
    ///      so a stranger picks the block and nothing else; the recovery leg is reachable *and*
    ///      caller-sized, but `workoutSettleAfterClose` clamps to `min(amountUsdc, w.writtenDown)`
    ///      and makes the caller fund it, so the step is bounded by the loss actually written down;
    ///      and the principal leg is reachable as a *call* whose ordinary settlement moves this
    ///      quote by nothing, because the cash in equals the principal off. The 9,090 bps figure in
    ///      `LenderPoolEntryPricing.t.sol` is what this contract accepts from its own manager and
    ///      is not a reachable step. `recoverLoss` genuinely carries no `YieldExceedsCapital`
    ///      guard, deliberately; that is a fact about this boundary and not about the exposure.
    ///
    ///      **What #259 changed and what it did not.** #259 stopped the two non-epoch legs rating
    ///      their money over the epoch accrual clock, so the *window* a stepped-in entrant then
    ///      waits out is `Config.YIELD_STREAM_DURATION` on those two legs and only a genuine epoch
    ///      drought still stretches it. It changed no amount: the size of the step through this
    ///      door is the size of the arriving pot. So the bound is sized against the step, not
    ///      against the window.
    ///
    ///      **Signature taken from EIP-5143**, which standardises exactly this pair, rather than
    ///      invented to match the exits. The parameter names are the EIP's (`minShares`,
    ///      `maxAssets`); the round-20 exit overloads predate the EIP and keep their own
    ///      `minAssetsOut`/`maxSharesIn`, which is a naming difference and not an ABI one - the
    ///      argument order of all four is the EIP's. `external` rather than the EIP's `public`
    ///      because nothing in this tree calls them internally and the exits are `external` too;
    ///      the selector is identical either way.
    ///
    ///      **Checked after execution rather than against a preview**, for the reason the redeem
    ///      overload gives at length: the two agree today, and bounding what actually happened
    ///      keeps that true without depending on it. The revert unwinds the transfer and the mint
    ///      with everything else.
    ///
    ///      **Not a default and not a refusal.** The two-argument doors above are unchanged and
    ///      still take whatever the book says, because ERC-4626 fixes their signatures. This is the
    ///      door for a caller who has an opinion about the price.
    ///
    ///      **What this does NOT close, stated here because both live in this door.** Round-23
    ///      finding 14 is about the *duration* an entrant sits at the #247 discount, and this bound
    ///      cannot see it: the entry quote is a function of the size of the unreleased pot and not
    ///      of the window it unwinds over, so the same pot delivered over five days and over a
    ///      180-day drought mints the identical share count and passes the identical `minShares`.
    ///      MEASURED in `LenderPoolEntryPricing.t.sol`: 4,545,454,545,495 shares either way
    ///      against the same bound, and a five-day exit that forfeits 1 wei under the floor and
    ///      303.819445 USDC under the drought, out of a 5,000.000000 entry. Finding 14 needs a
    ///      duration bound or a shorter window, and neither is this.
    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver);
        if (shares < minShares) revert SharesBelowMinimum(shares, minShares);
    }

    /// @notice Mint exactly `shares`, refusing to pay more than `maxAssets` USDC for them.
    /// @dev The exact-share half of the bound above. `previewMint` already quotes the cost;
    ///      this is what lets a caller hold the quote to it. The step runs the other way on this
    ///      door - a rising `_entryAssets()` makes a fixed share count cost *more* - so the
    ///      comparison is inverted and the bound is a maximum, exactly as EIP-5143 specifies and
    ///      as `withdraw`'s `maxSharesIn` does on the exit side.
    ///
    ///      See the bounded `deposit` above for the finding, the measured step, and for what this
    ///      pair deliberately does not close.
    function mint(uint256 shares, address receiver, uint256 maxAssets)
        external
        returns (uint256 assets)
    {
        assets = mint(shares, receiver);
        if (assets > maxAssets) revert AssetsAboveMaximum(assets, maxAssets);
    }

    /// @notice Refuses shares sent straight to the pool. Use `requestWithdrawal`.
    /// @dev **Audit round 23 finding 16.** This contract's own address is the withdrawal queue's
    ///      escrow, and `_update` credits principal-accounting units to whoever receives shares.
    ///      A share arriving here by any door other than `requestWithdrawal` therefore mints
    ///      escrow units that no queue entry claims, and nothing can ever retire them: the only
    ///      burn path out of escrow (`serviceQueue`) takes exactly the units the entry it is
    ///      paying carries. The `netDeposits` those orphans hold is deposit-cap headroom that
    ///      never comes back - the cap-BRICK direction, opposite to every residual finding 3
    ///      discloses, so it cannot be netted off against them.
    ///
    ///      **MEASURED, and the ledger recorded only the first of these four doors.** From a
    ///      10,000.000000 book: `transfer(this, 25)` and `transferFrom` each strand **1** unit;
    ///      `deposit(1_000e6, this)` strands **1,000,000,000** units and 1,000.000000 of
    ///      `netDeposits`, and `mint` the same. The bound of "one asset-wei per transaction" is a
    ///      fact about the transfer door alone. The ERC-4626 doors are the same defect at
    ///      arbitrary size, so all four are shut here rather than the two that were named.
    ///
    ///      Refusing rather than tolerating, because it is what buys the *detector*. The only
    ///      candidate fix still standing for audit round 23's open finding on principal-unit
    ///      growth turns `escrow units == sum of live request units` from an equality into a
    ///      bounded inequality, which is a weaker detector for exactly this bug. With these doors
    ///      shut the only route into escrow is `requestWithdrawal`, so that bound can be derived
    ///      from the live entries themselves rather than picked as a slack constant large enough
    ///      to make the suite pass.
    ///
    ///      Nothing legitimate is lost. `_requestWithdrawal` reaches escrow through the internal
    ///      `_transfer`, which is below these doors and untouched, and so do the queue's own
    ///      returns in `cancelWithdrawalRequest` and `serviceQueue`. A holder who genuinely wants
    ///      to give shares away can still send them anywhere that is not this contract.
    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        if (to == address(this)) revert EscrowIsNotAHolder();
        return super.transfer(to, value);
    }

    /// @dev The same door as `transfer`, and shut for the same reason.
    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20, IERC20)
        returns (bool)
    {
        if (to == address(this)) revert EscrowIsNotAHolder();
        return super.transferFrom(from, to, value);
    }

    /// @dev Overridden for `nonReentrant`, and since audit round 25 finding 1 for one refusal.
    ///      Both of these used to open with the round-10 gate check and its own dedicated revert;
    ///      what carries the *loss* now is the price they pay out on, because `super` routes
    ///      through `previewWithdraw`/`previewRedeem` and those price on `exitAssets()`. That
    ///      gate is still gone and is not coming back: nothing here refuses an exit on grounds of
    ///      solvency, timing or size, which is what round 10 shipped and what rounds 10/11's
    ///      research overturned.
    ///
    ///      **What is refused is the escrow as `receiver`, and this is the mirror of a guard the
    ///      entry side has had since round 23.** `_deposit` reverts `ZeroAmount` on an entry that
    ///      mints nothing, and `_update`'s comment states the rule these four doors were found by:
    ///      when a fix adds a guard, find its mirror. `deposit`, `mint`, `transfer`,
    ///      `transferFrom` and `requestWithdrawal` all already refuse this address. These two did
    ///      not, and neither did the two bounded overloads below, which reach the escrow through
    ///      this pair and are shut by this line rather than by one of their own.
    ///
    ///      What went wrong without it, MEASURED on one `redeem(10_000e9, address(pool), bob)`
    ///      from a 20,000.000000 book: `usdc.balanceOf(pool)` unchanged at 20,000.000000, the
    ///      shares burned anyway, `totalSupply` halved, and `convertToAssets(1e9)` stepping
    ///      1.000000 -> 1.999999 in that one call. The honest incumbent's stake went
    ///      10,000.000000 -> 19,999.999999 and the caller's went to nothing.
    ///
    ///      **Three things make it the class rather than a caller's own mistake.** The first is
    ///      the mirror above. The second is that the round-20 bound below cannot see it: the
    ///      strictest bound expressible, `redeem(sh, address(pool), bob, previewRedeem(sh))`,
    ///      *returns* 10,000.000000 and delivers 0, because the bound checks what the call
    ///      returned and not what the caller received. A caller doing everything the contract
    ///      offers to protect themselves is told the exit succeeded at the quoted price. The
    ///      third is that the deposit-cap half is not self-harm at all: `_burnPrincipalUnits`
    ///      debits `netDeposits` whether or not an asset left, so `netDeposits` went
    ///      10,000.000000 -> 0 with the money still in the contract, `maxDeposit` came back to
    ///      the full 25,000.000000 cap, and the next deposit left this pool holding
    ///      35,000.000000 against a 25,000.000000 cap. That is the **opposite** direction to
    ///      round-23 finding 16, which bricked the cap, so the two do not cancel - they widen the
    ///      band from both ends.
    ///
    ///      **Not extraction, and audit round 25 finding 2 was refuted end to end on that point.**
    ///      Driven from a stranger's address the PnL is -10,000.000001 and the incumbent's is
    ///      +10,000.000000: redeeming to the escrow is a **donation**, where the fifth door
    ///      `requestWithdrawal` shut was a hidden *subtraction* a stranger could time. It is
    ///      refused because a door that silently converts an exit into a gift to everyone else is
    ///      not a door, not because anybody profits by it.
    ///
    ///      Cost MEASURED on a clean build: `LenderPool` 16,159 -> 16,241 bytes, +82, exactly
    ///      twice the +41 the same guard cost at the fifth door - two lines shutting four doors,
    ///      because the bounded overloads delegate here.
    ///
    ///      Nothing legitimate is lost. Owner and receiver stay free to differ, which is what
    ///      `invariant_usdcIsConserved` defends, and every address but this one is still a
    ///      receiver.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (receiver == address(this)) revert EscrowIsNotAHolder();
        return super.withdraw(assets, receiver, owner);
    }

    /// @dev The same door as `withdraw`, and shut for the same reason. See it for the measurement.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (receiver == address(this)) revert EscrowIsNotAHolder();
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
        // can take a pro-rata slice immediately. That same-block capture is exactly the defect the
        // yield stream exists to prevent, arriving on the principal leg where nobody had thought
        // to look for it.
        //
        // It is real money and it does belong to the pool. Streaming it, together with gross
        // active-tail entry pricing, assigns it economically to the shares present at delivery
        // rather than to whoever enters after seeing the transaction. Share accounting does not
        // preserve which accounts held through the historical write-down.
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
    ///      No shares are minted. Released assets rise while supply does not, and entry previews
    ///      charge a newcomer for the projected active tail so shares already present at delivery
    ///      are not diluted while that value moves into released NAV.
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
    ///
    ///      **The rules are deliberately NOT the same on both legs, and audit round 23 is why.**
    ///      Rule 1 reads `lastYieldDistributeAt`, and only a delivered epoch advances it (see the
    ///      foot of this function, which is where that asymmetry was introduced). On the epoch leg
    ///      that clock IS the accrual window of the money being rated, which is exactly what rule 1
    ///      wants. On the other two legs - `repayPrincipal`'s surplus and `recoverLoss` - it is the
    ///      time since some *other* money was last delivered, it describes nothing about the money
    ///      in hand, and it grows every block the harvester is quiet. Four findings, one fact:
    ///
    ///        - round-22 finding 11: a recovery rated over the epoch clock, 388.888889 of
    ///          400.000000 denied to an exiter;
    ///        - round-23 finding 14: the same stretch decides how long a fresh depositor sits at
    ///          the #247 entry discount, 8.10% permanent loss against a free control;
    ///        - round-22 finding 6a: because rule 2 can only lengthen, every re-rate extends the
    ///          tail - ten at twelve hours sent 191.773143 of a 550.000000 pot to insurance,
    ///          matching `0.9^10` to eight figures and bounded by `1/e`;
    ///        - round-23 finding 2, the Med/High: the two non-epoch legs are permissionlessly
    ///          reachable for ONE asset-wei through `LiquidationAuction.workoutSettleAfterClose`,
    ///          sixteen re-rates fit in one block, and with the epoch clock stale the tail decays
    ///          at `1/t` instead of `exp(-t/D)` - 49.97% of a pot still withheld after six stream
    ///          durations, 129x the control.
    ///
    ///      **Neither half of the answer is a refusal, and that is a hard requirement.** These legs
    ///      carry money that has already left somewhere else: `repayPrincipal` is the only drain on
    ///      `CreditManager`'s `owedToSource`, and `recoverLoss` is reached from the auction's exits
    ///      of last resort. A gate that reverted would strand that money with no rescue, so both
    ///      halves below only ever choose a *duration*. There is no new revert on this path, and
    ///      `rate == 0` stays as unreachable as it was.
    /// @param isEpoch whether this is a delivered epoch, which owns the accrual clock, or a
    ///        surplus arriving from somewhere else, which must not touch it.
    function _rateStream(uint256 amount, bool isEpoch) private {
        // Crystallise the running stream before re-rating it, or the elapsed part of the old one
        // would be re-rated as though it had never been paid out.
        uint256 pot = unreleasedYield() + amount;
        uint256 remaining = yieldStreamEndsAt > block.timestamp ? yieldStreamEndsAt - block.timestamp : 0;

        uint256 duration;
        if (isEpoch) {
            // 1. Pay out over at least as long as the pot took to accrue. A fixed window closes
            //    same-block capture but not the general case: a pot representing sixty days of
            //    yield, rated over five, hands eleven-twelfths of it to whoever is staked for those
            //    five days. Windows stretch for ordinary reasons - a keeper outage, a run of
            //    declined zero-yield epochs, or the gap before this pool is wired at all - and
            //    `flushLenderYield` is permissionless, so the attacker picks the block.
            //
            //    `EpochHarvester.harvest` holds this leg `Config.MIN_EPOCH_GAP` apart, which is the
            //    reason the clock and the money still describe each other here.
            uint256 elapsed = block.timestamp - lastYieldDistributeAt;
            duration = elapsed > Config.YIELD_STREAM_DURATION ? elapsed : Config.YIELD_STREAM_DURATION;
        } else {
            // 1a. Money that does not own the accrual clock is not rated over it. The floor is what
            //     rule 1 exists to guarantee and all this pool can honestly say about a lump it did
            //     not watch accrue.
            //
            //     Together with rule 2 this is the *shortest* single window that never pays a wei
            //     out faster than two separate streams would - the arriving amount over
            //     `YIELD_STREAM_DURATION` and the running tail over its own remaining window.
            //     Anything shorter is under the honest schedule somewhere in `[now, max(D, R)]`,
            //     because a straight line to zero at `T` is below a convex two-ramp release for
            //     every instant after `T`. Round 23 built the shorter version -
            //     `if (!isEpoch && remaining != 0) duration = remaining` - measured it not inert,
            //     and refuted it anyway: with an hour left on a stream it rated a 400.000000
            //     recovery over 3,600 seconds. That is this bound being violated, and it is why
            //     the floor below is `YIELD_STREAM_DURATION` and not `remaining`.
            duration = Config.YIELD_STREAM_DURATION;

            // 1b. **And the extension has to be paid for.** Rule 1a alone still lets a wei reset the
            //     window: with `remaining < D` the whole pot is re-rated over a fresh `D` and the
            //     tail decays `exp(-t/D)` under repeated pokes, which is finding 6a exactly. The
            //     bound that closes it needs no parameter, because the stream states its own price:
            //     extending the pot's window past where it already ends slows the payout, so allow
            //     it only as far as the arriving money itself funds at the rate already running.
            //     `pot / yieldRate` is `remaining + amount / rate` - the current end date, plus the
            //     time the new money buys at the current speed.
            //
            //     Read as a property: **a non-epoch arrival can never reduce the release rate.** One
            //     wei buys one wei's worth of extension. A griefer can only hold the tail back by
            //     funding it at the rate it was already running, which is a subscription, not an
            //     attack.
            //
            //     **What it costs, stated as measured rather than as hoped.** This clause is the one
            //     place the window can come out SHORTER than the floor, and not only for dust: a
            //     400.000000 recovery landing with an hour left on a 550.000000 stream is rated over
            //     317,781 seconds, not 432,000. It binds whenever `amount < rate * (D - remaining)`,
            //     and that threshold scales with the running rate rather than with anything small.
            //     What is preserved is the payout RATE, which is the unit just-in-time capture is
            //     measured in: a sandwicher's take is their share times the rate times the blocks
            //     they hold, and the rate here never exceeds the greater of the rate already flowing
            //     and the whole pot over a full floor. Neither of those is new exposure. MEASURED on
            //     that fixture: a whole-window sandwich takes its 90.9% pro-rata slice of the
            //     recovery either way, because that total is independent of the window; a one-hour
            //     sandwich comes out 9 wei UP under this clause against 1.096162 DOWN under the
            //     shipped rule, because #247's gross active-tail entry pricing charges for the tail
            //     and an early exit forfeits it. `test/YieldStreamClock.t.sol` holds all four.
            //
            //     Skipped when nothing is running (`remaining == 0`): there is no rate to preserve,
            //     `pot / yieldRate` would be measured against a finished stream's stale rate, and a
            //     cold arrival must get the full floor anyway.
            if (remaining != 0 && yieldRate != 0) {
                uint256 funded = (pot * ACC_PRECISION) / yieldRate;
                if (duration > funded) duration = funded;
            }
        }

        // 2. Never shorten a running stream. The window above describes the accrual window of the
        //    *new* money, but the pot also holds the unfinished tail of the previous stream, whose
        //    window may have been far longer. Re-rating that tail over the new gap compresses it,
        //    which is the same just-in-time capture reintroduced one epoch later.
        //
        //    **Last, and load-bearing for more than compression.** Rule 1b divides by a rate, and
        //    a pot that has fully released against a still-future end date can floor `funded` to
        //    zero; this line is what makes `duration >= 1` hold by construction on every path, and
        //    therefore what keeps the division below safe.
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
        //
        // Round 23 closed the other direction of the same asymmetry: the clock does not move on the
        // non-epoch legs, and since this fix those legs no longer *read* it either. Both halves are
        // needed. Writing it here would shorten the next epoch's window; reading it up there rated
        // money over a window belonging to somebody else's money.
        if (isEpoch) lastYieldDistributeAt = block.timestamp;
    }

    /// @dev Every ERC-4626 entry funnels through here. The asset amount credits `netDeposits`, while
    ///      the receiver gets principal units at the pre-deposit ratio. If a loss has reduced
    ///      `netDeposits`, issuing more units for the same assets keeps new capital from inheriting
    ///      that old loss. Before a socialised loss the active unit ratio remains one, so this
    ///      issuance gives assets and units the same number. That ratio is not proof that the cap
    ///      followed assets out: a dust transfer and zero-asset redemption can burn one unit and
    ///      one `netDeposits` asset-wei together while no asset leaves the pool.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // **A deposit that mints nothing is a donation the depositor did not mean to make**, and
        // audit round 22 finding 2 is why the guard is here rather than filed as dust. Once the
        // share price is high enough for `previewDeposit` to round to zero, this path took the USDC
        // and minted nothing for it: a total loss for the depositor and a windfall for everyone
        // already in. That price is reachable by donation alone - `totalAssets()` reads a raw
        // `balanceOf`, which is the same donation `maxDeposit`'s NatSpec is written around - and the
        // exit that finding names walks the pool straight into it from the other direction.
        //
        // On the hook rather than on `deposit`, because `mint` funnels through here too and a
        // zero-share mint is the same refusal. There is no legitimate caller of either.
        if (shares == 0) revert ZeroAmount();

        uint256 totalUnits = totalPrincipalUnits;
        uint256 units = totalUnits == 0
            ? assets
            : Math.mulDiv(assets, totalUnits, netDeposits, Math.Rounding.Ceil);

        super._deposit(caller, receiver, assets, shares);

        // Credit after the asset transfer and share mint. If a hook-bearing settlement token ever
        // reenters the unguarded ERC-20 transfer path during `safeTransferFrom`, it can move only
        // the receiver's old shares and old units, not units for shares that do not exist yet.
        netDeposits += assets;
        totalPrincipalUnits = totalUnits + units;
        _creditPrincipalUnits(receiver, units);

        // Last, and the order is load-bearing. `units` was priced against the pre-entry exponent,
        // so a shift applied before the credit would hand the receiver twice what they paid for.
        _renormaliseUnits();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // `_update` moves and debits the owner's own principal units when the shares are burned.
        // Keeping the debit on the token hook also covers the queue's direct burn.
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev `units` is always quoted at the current `unitExponent`, so the holder's stored figure is
    ///      normalised to that exponent and re-stamped before the addition. Normalising floors, and
    ///      that floor is the whole cost of lazy renormalisation: see `_renormaliseUnits`.
    function _creditPrincipalUnits(address account, uint256 units) private {
        if (units == 0) return;

        uint256 exponent = unitExponent;
        if (_principalUnitGeneration[account] != _principalGeneration) {
            _principalUnitGeneration[account] = _principalGeneration;
            _principalUnits[account] = units;
        } else {
            _principalUnits[account] =
                _scaleToCurrentExponent(_principalUnits[account], _principalUnitExponent[account]) + units;
        }
        _principalUnitExponent[account] = exponent;
    }

    /// @notice The value `totalPrincipalUnits` is renormalised back under.
    /// @dev A function rather than a bare constant read, and `virtual` **solely so a test harness
    ///      can lower it**. The bound `_renormaliseUnits` documents is `drift <= holders - 1`, and
    ///      at the shipped ceiling a fuzzer cannot reach a single shift, so a bound measured only
    ///      at `2**128` would be a statement about the fuzzer's reach and not about the rule. The
    ///      design pass that specified this measured its drift on a patched copy of the source;
    ///      a seam keeps the measurement in the tree where it can rot loudly instead.
    ///
    ///      `LenderPool` is deployed directly and nothing under `src/` inherits from it, so the
    ///      production value is the constant and `test_thePrincipalUnitCeilingIsTheShippedValue`
    ///      pins it. `public` rather than internal because an off-chain reader that has seen a
    ///      `PrincipalUnitsRenormalised` log has no other way to know what triggered it; that costs
    ///      one selector. `view` rather than `pure` only because an override cannot loosen state
    ///      mutability, and the harness needs to move the ceiling between two calls in one trace.
    function principalUnitCeiling() public view virtual returns (uint256) {
        return PRINCIPAL_UNIT_CEILING;
    }

    /// @dev Divides the whole principal-unit ledger by a power of two in O(1), by moving the
    ///      exponent every stored figure is read against rather than by touching any holder.
    ///
    ///      **Audit round 23, finding 7.** `totalPrincipalUnits / netDeposits` is the price
    ///      `_deposit` issues at and nothing in the contract used to divide it back down except a
    ///      total wipe, which is finding 6. Nine measured loss-and-recovery cycles - in which no
    ///      lender was ever actually down anything - took the quotient past `type(uint256).max`,
    ///      and `Math.mulDiv` reverted `Panic(0x11)` while `maxDeposit` still advertised room. On an
    ///      immutable contract with no sweep that is the deposit door closed permanently.
    ///
    ///      A shift is not a generation roll. It destroys no basis and invalidates no holder: every
    ///      figure in the ledger - the aggregate, every holder, every queue entry - is divided by
    ///      the same power of two, so every ratio the contract actually consumes is unchanged.
    ///      What it costs is low-order bits, and it costs them **unevenly**, because each figure is
    ///      floored independently at the moment it is next read.
    ///
    ///      **So the storage identity `sum over holders == totalPrincipalUnits` becomes a bounded
    ///      inequality, and the bound is `holders - 1`.** Derivation: with `D` the drift before a
    ///      shift of `k`, `S` the sum of the reads and `h` the number of them,
    ///      `floor((S+D)/2**k) - sum(floor(r_i/2**k)) <= D/2**k + h*(1 - 2**-k)`, which is under `h`
    ///      whenever `D <= h - 1`, and `D` starts at zero. The aggregate therefore **over**-counts,
    ///      never under-counts, which is the direction every subtraction against it needs: no
    ///      holder's units can exceed it and no burn can underflow it. `principalBasis` therefore
    ///      under-reports by `netDeposits * drift / totalPrincipalUnits`, and because
    ///      `netDeposits <= totalPrincipalUnits` holds unconditionally that is bounded by the drift
    ///      itself: **at most one asset-wei of cap headroom per credited holder**, the same order as
    ///      the ceiling-rounding residuals round-22 finding 3 already discloses.
    function _renormaliseUnits() private {
        uint256 ceiling = principalUnitCeiling();
        uint256 total = totalPrincipalUnits;
        if (total < ceiling) return;

        uint256 shift;
        // Bit at a time rather than through a logarithm: the loop runs at most 128 times and only
        // on the rare issuance that crosses the ceiling, and this contract's scarce resource is
        // bytecode rather than the gas of a path that has never yet run on a live pool.
        while (total >= ceiling) {
            total >>= 1;
            ++shift;
        }

        totalPrincipalUnits = total;
        unitExponent += shift;
        emit PrincipalUnitsRenormalised(shift, unitExponent, total);
    }

    function _stageExactPrincipalUnitMove(uint256 units) private {
        assert(!_hasExactPrincipalUnitMove);
        _hasExactPrincipalUnitMove = true;
        _exactPrincipalUnitsToMove = units;
    }

    function _transferWithExactPrincipalUnits(address from, address to, uint256 value, uint256 units) private {
        _stageExactPrincipalUnitMove(units);
        _transfer(from, to, value);
        assert(!_hasExactPrincipalUnitMove);
    }

    function _burnWithExactPrincipalUnits(address from, uint256 value, uint256 units) private {
        _stageExactPrincipalUnitMove(units);
        _burn(from, value);
        assert(!_hasExactPrincipalUnitMove);
    }

    /// @dev Removes `units` from the current generation and debits their marked-down principal.
    ///      Ceiling is deliberate **here**: this is the only one of the four roundings round-22
    ///      finding 3 runs through whose floor genuinely strands principal, because the counter it
    ///      writes is a single aggregate with nobody left holding the remainder. `N - ceil(N*u/U)`
    ///      is `floor(N*(U-u)/U)`, so each partial burn leaves the counter at most one asset-wei
    ///      below the honest remainder - the LOOSEN direction, bounded, disclosed, and still open.
    ///      A full-unit burn is exact against the remaining aggregate.
    ///
    ///      **One of the three roundings that feed it has been flipped and the boundary it opened
    ///      is closed.** `_update`'s share-to-unit move floors now, for the reason written at the
    ///      site: its remainder stays with a live share balance, so nothing detaches, and the
    ///      no-loss dust boundary that used to zero the counter is shut. `serviceQueue`'s
    ///      partial-fill debit was flipped too and the flip was **refused on a measured sign
    ///      change** - see that site. What is left of finding 3 at this line is one asset-wei per
    ///      *burn*, and `serviceQueue` can buy one burn per call.
    ///
    ///      **NOT closable by a per-holder recorded basis**: after any realised loss the marked-down
    ///      debit is strictly below what the holder admitted, so a cap at the recorded figure is
    ///      INERT on exactly the paths that leak. MEASURED, and a recorded-basis cap built in the
    ///      same tree moved the queue and merge/split figures by not one wei. See
    ///      `LenderPoolUnitProvenance.t.sol`.
    ///
    ///      A post-loss one-asset-wei round trip still loosens the cap by one asset-wei, and that
    ///      one **is** the recorded-basis boundary - the entry ceiling issues two units for 1.111
    ///      units of admission and this line faithfully pays two back. Closing it costs a fourth
    ///      per-holder mapping: MEASURED at +238 bytes and +11,385 gas on a warm ERC-20 transfer,
    ///      +28,373 cold, and refused on that price until the four per-holder mappings are packed
    ///      into one slot rather than added to.
    function _burnPrincipalUnits(uint256 units) private {
        uint256 totalUnits = totalPrincipalUnits;
        uint256 basis = units == totalUnits
            ? netDeposits
            : Math.mulDiv(netDeposits, units, totalUnits, Math.Rounding.Ceil);

        totalPrincipalUnits = totalUnits - units;
        _reduceNetDeposits(basis);
    }

    /// @dev Clamped rather than subtracted. When the counter reaches zero, all surviving units have
    ///      zero basis and a generation change invalidates them without iterating over holders.
    function _reduceNetDeposits(uint256 assets) private {
        if (assets == 0) return;

        uint256 taken = netDeposits;
        if (taken == 0) return;
        if (assets >= taken) {
            netDeposits = 0;
            totalPrincipalUnits = 0;
            ++_principalGeneration;
        } else {
            netDeposits = taken - assets;
        }
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
        if (from != address(0)) {
            uint256 fromBalance = balanceOf(from);

            // Preserve ERC-20's standard insufficient-balance error. A successful update can never
            // return from this branch.
            if (value > fromBalance) {
                super._update(from, to, value);
                return;
            }

            uint256 heldUnits = principalUnits(from);
            uint256 movedUnits;
            // **Floored, and audit round 22 finding 3's no-loss boundary is why it is not a
            // ceiling.** Shares carry three more decimals than the assets the units are
            // denominated in, so one share-wei is a thousandth of a unit and a ceiling always
            // rounds it up to a whole one. MEASURED on the ceiling, from a ten-asset-wei book:
            // transferring one share-wei ceil-moved one whole unit, that dust position then
            // redeemed for zero assets because the exit conversion floors, and the unit burn
            // still took one asset-wei off `netDeposits`. Ten cycles drove the counter from ten
            // to zero with all ten assets still in the contract and `maxDeposit` back at the
            // full cap - the LOOSEN direction, one asset-wei per completed boundary.
            //
            // Flooring closes it exactly rather than bounding it: the same trace now moves zero
            // units, burns zero units and leaves the counter at ten. The direction that replaces
            // it is not the brick it looks like. A floor under-moves, so the remainder stays with
            // the **sender**, who still holds the shares it belongs to; and `value == fromBalance`
            // above is still exact, so the last share out of any balance carries every unit left.
            // Residual principal can therefore never detach from a live share balance, which is
            // precisely what the ceiling allowed. `invariant_noPrincipalUnitsOutliveShares` is the
            // standing check on that claim and both campaigns were run against this change.
            if (_hasExactPrincipalUnitMove) {
                movedUnits = _exactPrincipalUnitsToMove;
                _hasExactPrincipalUnitMove = false;
                _exactPrincipalUnitsToMove = 0;
            } else if (heldUnits != 0) {
                movedUnits = value == fromBalance
                    ? heldUnits
                    : Math.mulDiv(heldUnits, value, fromBalance, Math.Rounding.Floor);
            }

            if (movedUnits != 0) {
                // `heldUnits` came back from a normalising read, so what is written here is quoted
                // at the current exponent and the stamp has to follow it. Missing this line hands
                // the remainder a second shift it has already taken.
                _principalUnits[from] = heldUnits - movedUnits;
                _principalUnitExponent[from] = unitExponent;
                if (to == address(0)) {
                    _burnPrincipalUnits(movedUnits);
                } else {
                    _creditPrincipalUnits(to, movedUnits);
                }
            }
        }

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
        // found it did not.** `netDeposits` rises on a deposit and falls when admitted principal
        // leaves with burned shares, but a socialised loss burns no shares at all. Without this
        // write it consumed cap headroom permanently. This contract is immutable with no sweep and
        // no rescue, so enough losses would close it to deposits for good, which is the same
        // permanent brick round 11 found through a donation and this reaches through ordinary
        // operation.
        //
        // Reducing here does not turn the counter into a valuation: a loss removes principal the
        // pool is holding, which is exactly what it measures. Yield and donations still move it by
        // nothing, which is what stops a donor closing the pool.
        //
        // **Yield-first, and audit round 23 finding 6 is why it is not `_reduceNetDeposits(absorbed)`.**
        // Debiting the counter by the whole loss charges principal for a loss the retained yield
        // already covered. MEASURED on the shipped rule: two lenders at 5,000.000000 each, one
        // epoch of 10,000.000000 released, the first lender out, then a 5,000.000000 loss - and
        // `netDeposits` went to **zero** with 5,000.000001 of book still standing. That took the
        // clamp below, which rolled the generation and handed the whole 25,000.000000 cap back
        // over a pool that had never emptied; the refill then stood at 30,000.000001 against it.
        // And it repeated with no further loss, because each cohort's full exit wiped the counter
        // and re-gifted the cap to the next.
        //
        // The counter measures admitted principal the pool is **still holding**, so after a loss it
        // is `min(N, what is left)`. `totalAssets() + unreleasedYield()` is that: delivered yield
        // waiting on the clock is lender money and belongs in the cushion, and adding it back is
        // also what makes the debit independent of where in a stream the loss lands - MEASURED
        // identical at five points across one stream, where `totalAssets()` alone moved by the
        // whole undelivered tail. `_poolBalance()` floors at zero, so in the one state where the
        // two terms do not cancel this **over**-states the cushion and debits less, which is the
        // cap-tightening direction and therefore the safe one.
        //
        // This makes the clamp's predicate honest: `netDeposits` now reaches zero only when the
        // assets behind it have. **It must not ship without `_renormaliseUnits`** - MEASURED, it
        // closes the counter-crush route to finding 7 and opens a crush-and-recover route on which
        // the quotient multiplies by 2.5e10 per cycle.
        uint256 cushion = totalAssets() + unreleasedYield();
        uint256 admitted = netDeposits;
        if (admitted > cushion) _reduceNetDeposits(admitted - cushion);
        emit LossSocialised(absorbed);
    }

    /// @notice Book money returned on an asset this pool already wrote down. CreditManager only.
    /// @dev **Audit round 21, finding 14: the leg `socialiseLoss` never had.** A workout's forced
    ///      close writes the debt off while DexFi's redemption is still in flight, and the tranche
    ///      that lands afterwards has to reach this pool rather than the insurance fund, which
    ///      helps the pool only if a *future* borrower defaults.
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
    ///      instantaneous share-price step is capturable by whoever picks the block. The active
    ///      stream belongs economically to the shares present when delivery occurs: later entries
    ///      pay its gross value, but the pool does not reconstruct which accounts historically
    ///      bore the write-down. That is round 10's finding 6, and this is a third leg it covers.
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
    ///
    ///      **The fifth door, and audit round 24 found it after round-23 finding 16 shut four.**
    ///      That finding shut every route by which a *share* could reach this address with no queue
    ///      entry behind it: `transfer`, `transferFrom`, `deposit`, `mint`. This is the same class
    ///      one field along - the escrow named as the **receiver** of a queue entry, which is the
    ///      route by which the pool's own USDC ends up booked as owed to the pool.
    ///
    ///      What it does. `serviceQueue` burns the escrowed shares and writes
    ///      `claimable[address(this)] += assetsOut`, so a real payout is set aside inside this
    ///      contract's own balance. `_poolBalance()` subtracts `totalClaimable`, so `totalAssets`,
    ///      `available`, `unreservedIdle`, `maxWithdraw` and `maxRedeem` all under-report from that
    ///      moment. Then `claimFor(address(this))` is permissionless: it clears the entry and
    ///      `safeTransfer`s the USDC to the address already holding it, so the balance does not move
    ///      and the subtraction simply stops. The whole strand rejoins the share price **in one
    ///      block, at an instant any stranger picks**.
    ///
    ///      MEASURED on the unguarded contract: `convertToAssets(1e9)` steps 1.000000 -> 1.999999 in
    ///      a single block, and a stranger holding nothing before that block takes 5,999.999999 USDC
    ///      out of it - the honest incumbent's loss to within 2 wei, with zero seconds of exposure.
    ///
    ///      Refused rather than tolerated, and refused **here** rather than at `claimFor`, for the
    ///      reason the four doors above were: this is the only writer of `WithdrawalRequest.receiver`
    ///      and so the only writer that can put this address into `claimable`. Shutting it makes
    ///      `claimable[address(this)] == 0` a standing fact rather than a bound, which is what buys
    ///      the detector. A guard at `claimFor` would leave the under-reporting half standing and
    ///      spend bytecode defending a state that can no longer be created.
    ///
    ///      Nothing legitimate is lost. Owner and receiver stay free to differ - that split is what
    ///      `invariant_usdcIsConserved` defends - and every address but this one is still a receiver.
    function _requestWithdrawal(uint256 shares, address receiver) private {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert EscrowIsNotAHolder();
        uint256 existing = _requestIndexPlusOne[msg.sender];
        if (existing != 0) revert AlreadyQueued(existing - 1);

        // Moves the shares rather than burning them, so `totalSupply` is untouched and the share
        // price does not jump at the moment somebody asks to leave.
        uint256 escrowUnitsBefore = principalUnits(address(this));
        _transfer(msg.sender, address(this), shares);
        uint256 requestUnits = principalUnits(address(this)) - escrowUnitsBefore;
        queuedShares += shares;

        uint256 index = _queue.length;
        _queue.push(
            WithdrawalRequest({
                owner: msg.sender,
                receiver: receiver,
                shares: shares,
                principalUnits: requestUnits,
                principalGeneration: _principalGeneration,
                principalUnitExponent: unitExponent
            })
        );
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
        WithdrawalRequest storage request = _queue[index];
        uint256 shares = request.shares;
        uint256 requestUnits = _liveRequestUnits(request);

        request.shares = 0;
        request.principalUnits = 0;
        queuedShares -= shares;
        delete _requestIndexPlusOne[msg.sender];

        // Walk the head past any husks this leaves at the front. Amortised O(1) - `queueHead` only
        // ever moves forward, so each entry is stepped over once in the life of the contract - and
        // it keeps `queuePosition`'s scan short in the ordinary case.
        _advanceHeadPastEmpties();

        _transferWithExactPrincipalUnits(address(this), msg.sender, shares, requestUnits);
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
        return _claim(msg.sender);
    }

    /// @notice Collect a named receiver's set-aside USDC **to that receiver**. Permissionless.
    ///
    /// @dev **Audit round 22, findings 12 and 17. This is the fourth member of the
    ///      `msg.sender`-scoped-pot class `CreditManager.claimSurplusFor` was added for, and round
    ///      21 swept that class in one commit minus this one member** - `claimSurplus`,
    ///      `claimBounty` and `claimReward` all got their `*For` twin in #209 and the pool was
    ///      outside that stream's files. Five agents found it independently in round 22, which is
    ///      what a class swept minus one member looks like from the outside.
    ///
    ///      **WHICH HALF THIS CLOSES. Stated here rather than only in a pull request, because two
    ///      agents built this function in round 22, measured OPPOSITE results, and both were
    ///      right.** One measured it recovering 20,000.000000 to a receiver that had gone **mute**;
    ///      the other measured it **inert** against a receiver that was **blocked**. Those are
    ///      different preconditions, and the round-21 `*For` pattern closes exactly one of them:
    ///
    ///      - **CLOSED - the receiver cannot RE-ISSUE THE CALL.** Lost keys; a contract wallet
    ///        whose pointer moved; a keeper behind an upgradeable proxy that no longer exposes a
    ///        route to this function; an address that could never transact. The USDC is
    ///        deliverable and nobody can ask for it. Anyone may now ask on the receiver's behalf.
    ///        `test_claimFor_recoversMoneyFromAReceiverThatCannotCall` executes it.
    ///      - **NOT CLOSED, and not closeable here - the receiver cannot RECEIVE.** A USDC
    ///        blacklist on the receiver makes `safeTransfer` revert whoever initiates it, so this
    ///        reverts in exactly the place `claim()` reverts, with the same error and argument. No
    ///        `*For` can fix that: the failure is in the token and the destination is deliberately
    ///        not chooseable. `test_claimFor_isInertAgainstAReceiverThatCannotReceive` asserts the
    ///        inertness rather than leaving it to a paragraph. Pull-not-push already contains that
    ///        failure to the one entry - see the `claimable` declaration for what the push version
    ///        did, which was freeze the whole queue and, through `available()`, stop all borrowing.
    ///
    ///      **Destination not chooseable**, matching `claimSurplusFor`, `claimBountyFor`,
    ///      `claimRewardFor` and `EpochHarvester.flushLenderYieldTo`: the caller chooses only
    ///      *whether* the money moves, never *where*. It grants no authority over anybody's
    ///      balance, and forcing a receiver to take their own USDC one block early is the same
    ///      class of unsolicited help as `repayFor`.
    ///
    ///      **This does NOT close round-22 finding 12's headline, and that finding stays open.**
    ///      The headline is that a *stranger's* free `serviceQueue` turns recoverable shares into
    ///      unrecoverable cash: before servicing, the owner can `cancelWithdrawalRequest` and take
    ///      the shares back; after it the money sits under the **receiver's** name, and owner and
    ///      receiver need not be the same party. This widens who may pull that cash out. It does
    ///      not give the owner back the ability to undo the conversion, and it does not stop a
    ///      stranger choosing the moment. **A `*For` here would read like closure of a finding it
    ///      half-touches.** The timing half is audit round 21's finding 7 and audit round 22's
    ///      finding 12, both open: four candidates have now been built against it and every one
    ///      fired a control this contract already relies on - see `available()` and this function's
    ///      sibling refusal in `serviceQueue` for the two that pin it.
    ///
    ///      Reverts at zero rather than no-opping, so a caller cannot be told a strand was cleared
    ///      when nothing moved.
    function claimFor(address receiver) external nonReentrant returns (uint256 amount) {
        if (receiver == address(0)) revert ZeroAddress();
        return _claim(receiver);
    }

    function _claim(address receiver) private returns (uint256 amount) {
        amount = claimable[receiver];
        if (amount == 0) revert NothingToClaim();

        claimable[receiver] = 0;
        totalClaimable -= amount;

        emit WithdrawalClaimed(receiver, amount);
        IERC20(asset()).safeTransfer(receiver, amount);
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
                uint256 dustRequestUnits = _liveRequestUnits(request);
                request.shares = 0;
                request.principalUnits = 0;
                queuedShares -= shares;
                delete _requestIndexPlusOne[request.owner];
                _transferWithExactPrincipalUnits(address(this), request.owner, shares, dustRequestUnits);

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
            // and `redeem` are open at the impaired price. So it converts a markdown crystallised
            // at a stranger's chosen instant into one the lender chooses themselves, which is the
            // premise the whole industry norm rests on and the premise audit round 15 proved we
            // lacked.
            //
            // **"Up to `unreservedIdle()`" is what that used to say, and audit round 22 finding 2
            // narrowed it. Re-quantified here rather than left as a sentence that has stopped being
            // true.** That door now opens up to
            // `previewRedeem(min(balanceOf(owner), convertToShares(unreservedIdle())))`. For a
            // lender whose stake is smaller than the idle cash's share of the book it is unchanged,
            // because their own balance is the binding term either way. For a lender larger than
            // that it is strictly narrower, and it narrows exactly as the mark deepens: MEASURED on
            // `Impairment.integration.t.sol`'s single-lender fixture under a whole-debt mark, the
            // escape goes from 19,371.250000 to **18,762.266328**, or 3.1% tighter. The money is
            // not lost - it is the difference between crystallising a temporary markdown and
            // keeping the claim - but the escape is smaller than this comment used to promise.
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
            // spreads the same reserve over a smaller remaining book: measured, a stayer's worst
            // case gets WORSE, and what they keep falls by about 45% - 500.000000 becomes
            // 272.727272. That is a partial answer that moves a loss onto whoever stayed, which is
            // the shape rounds 12, 13 and 14 each shipped and then deleted. Whatever gets built
            // here has to answer that first.
            //
            // **The direction above was stated BACKWARDS in this file and in two places in
            // `test/LenderPoolExitPricing.t.sol` until 2026-08-22.** "The stayer's worst case falls
            // by 45%" reads as the stayer being better off, and the measurement is the opposite.
            // Audit round 21 filed the inversion, round 23 re-counted it as one surviving site,
            // and there were three. Re-measured 2026-08-22 on the fixture that asserts it:
            // 500.000000 becomes 272.727272.
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

            uint256 requestUnits = _liveRequestUnits(request);
            // **The fourth of round-22 finding 3's roundings, and the ledger had attributed only
            // three.** Ceiling here over-burns the entry's units on every partial fill and buys a
            // fresh ceiling in `_burnPrincipalUnits` on top of it, so a sliced fill loosens the cap
            // by up to one asset-wei per slice. MEASURED against the honest pro-rata debit: 400
            // one-asset-wei fills over-debit the counter by **401**, 199 fills of 1.000003 by
            // **123**, one equivalent fill by **2**. `serviceQueue` is permissionless, so how many
            // slices an entry is paid in is nobody's choice but the caller's.
            //
            // **Flooring it was built, measured and REFUSED, and the refutation is the point.** It
            // takes those three figures to 1, **-23** and 1: an order of magnitude smaller and
            // **sign-unstable**, because on the middle trace the floor stops over-debiting and
            // starts UNDER-debiting, which strands admitted principal against the cap. That is the
            // brick direction, it is round-22 finding 3's own headline defect, and this contract
            // refuses to trade a bounded loosening of known sign for a smaller error of unknown
            // sign. Round-23 finding 12 chose this ceiling and its deterministic one-wei-wide test
            // is what discriminates it; the four principal-unit invariants provably cannot.
            //
            // **Round-23 finding 12's stated reason is wrong on the sign and the choice survives
            // anyway.** It says a floor here "lets residual principal accumulate against the cap.
            // That is round-22 finding 3's cap-loosening direction." Residual principal accumulating
            // leaves the counter HIGH, which is less headroom, not more: the floor is the brick
            // direction and the ceiling is the loosening one. The conclusion is right for the
            // opposite reason to the one written down.
            uint256 unitsToBurn = sharesToBurn == shares
                ? requestUnits
                : Math.mulDiv(requestUnits, sharesToBurn, shares, Math.Rounding.Ceil);

            request.shares = shares - sharesToBurn;
            // `requestUnits` is a normalised read, so the remainder is quoted at today's exponent
            // and the entry's stamp has to move with it. Same rule as `_update`'s holder remainder.
            request.principalUnits = requestUnits - unitsToBurn;
            request.principalUnitExponent = unitExponent;
            queuedShares -= sharesToBurn;
            idle -= assetsOut;

            _burnWithExactPrincipalUnits(address(this), sharesToBurn, unitsToBurn);
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

            // `_burn` has already moved the escrow's principal units through `_update`, so the
            // deposit-cap debit has one funnel for both ERC-4626 exits and queue service.

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

    /// @notice Principal units still attached to a queue entry in the current loss generation.
    function queueEntryPrincipalUnits(uint256 index) external view returns (uint256) {
        return _liveRequestUnits(_queue[index]);
    }

    /// @dev The one reader of a queue entry's principal units, and the reason it is a helper rather
    ///      than the ternary it replaced. Four sites had to agree on the generation check; with the
    ///      exponent they have to agree on two adjustments, and a grep for the ternary shape alone
    ///      already missed one of the four once (`queueEntryPrincipalUnits` spelt it as an early
    ///      return). Both adjustments are lazy: an entry stamped in a dead generation is worth
    ///      nothing, and what survives is rescaled by whatever renormalisation has happened since.
    function _liveRequestUnits(WithdrawalRequest storage request) private view returns (uint256) {
        if (request.principalGeneration != _principalGeneration) return 0;
        return _scaleToCurrentExponent(request.principalUnits, request.principalUnitExponent);
    }
}
