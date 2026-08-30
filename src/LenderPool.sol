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
/// @dev Four withdrawal decisions are load-bearing:
///
///      **1. A request keeps its shares live.** Requesting moves shares into escrow rather than
///      burning them. They keep earning yield and carry socialised losses until the controller
///      services or cancels the request.
///
///      **2. ERC-4626 exits stay synchronous.** `withdraw` and `redeem` never silently become
///      claims. Their maximum views report immediately executable liquidity. A lender explicitly
///      calls `requestWithdrawal` when they want an escrowed, asynchronously serviceable claim.
///
///      **3. Requests have controllers, not positions.** Each controller has at most one live
///      request in an O(1) mapping. Monotonic request IDs identify events but create no priority,
///      cursor, shared walk, or cross-controller veto. Each request owns the same fraction of cash
///      as its shares own of supply, independent of pool leverage.
///
///      **4. Service timing belongs to the controller.** Only the controller or an operator they
///      approve may choose the amount and execution block. The receiver is fixed when the request
///      is created, and `minAssetsOut` applies atomically to the live exit price. This removes the
///      stranger-timed conversion from recoverable shares into claimable cash without installing a
///      trusted protocol key. Pull claims continue to isolate a receiver that cannot accept USDC.
///
///      This is a custom ERC-4626 extension, not ERC-7540. ERC-7540 would require incompatible
///      preview behaviour and a different claim lifecycle, while a trusted fulfiller would add a
///      censorship and key-liveness dependency to the exit path.
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
///      setters and its yield-stream freeze. The pull-payment claim is part of `ILenderPool`; see
///      that interface's header for the rule that decides which side a new event belongs on.
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
    error AlreadyQueued(uint256 requestId);
    error WithdrawalRequestNotFound(address controller);
    error UnauthorizedRequestOperator(address controller, address caller);
    error ServiceSharesExceedMaximum(uint256 requested, uint256 maximum);
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
    /// @notice Fixed withdrawal claims are not fully backed by recognised on-contract cash.
    error ClaimsUnderfunded(uint256 required, uint256 available);
    /// @notice A claim-deficit cover may restore the shortfall, but may not create unowned cash.
    error ClaimDeficitExceeded(uint256 requested, uint256 remaining);
    /// @notice New capital cannot enter until a recognised external cash loss is written down.
    error CashDeficitOutstanding(uint256 amount);
    /// @notice Principal-backed shares may not be burned below the virtual-share safety floor.
    error MinimumShareSupply(uint256 resultingSupply, uint256 minimumSupply);
    /// @notice Entry is closed until recognised shareholder backing restores the quotient bound.
    error EntryPriceBelowMinimum(uint256 currentAssets, uint256 requiredAssets);
    /// @notice A share-price cover may restore the shortfall, but may not create excess value.
    error EntryPriceDeficitExceeded(uint256 requested, uint256 remaining);
    /// @notice Minting refused the absolute share-supply ceiling derived from the global asset cap.
    error MaximumShareSupplyExceeded(uint256 resultingSupply, uint256 maximumSupply);

    // Everything this contract emits that `ILenderPool` describes is declared *there*, including
    // `YieldDistributed`, `Impaired`, `ImpairmentReleased`, `LossReservesSet` and the request and
    // claim events. Re-declaring any of them here would not compile, which is the point - see
    // decision 5 in the header. What remains below is machinery the interface does not promise.

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
    /// @notice The stream stopped because real share supply fell below the safety floor.
    /// @dev Local, not interface: `ILenderPool` promises that a delivered epoch reaches the share
    ///      price over a window, and says nothing about *how* the pot is held. Freezing it for a
    ///      low but non-zero cohort is emitted from `_update`, not from an interface function.
    event YieldStreamFrozen(uint256 unreleased);
    /// @notice An observed token-balance shortfall was written into the pool's recognised book.
    event CashDeficitReconciled(
        uint256 accountedBefore, uint256 accountedAfter, uint256 yieldWrittenOff, uint256 claimDeficitAfter
    );
    /// @notice Recognised cash with no remaining owner was removed permanently from the book.
    event CashDerecognised(uint256 amount);
    /// @notice A caller restored part of the minimum entry-price backing after an abnormal loss.
    event EntryPriceDeficitCovered(address indexed payer, uint256 amount, uint256 remaining);
    /// @dev Fixed-point scale for `yieldRate`, matching `CreditManager.ACC_PRECISION`. An unscaled
    ///      rate in USDC-wei per second floors to zero whenever the pot is smaller than the number
    ///      of seconds it is spread over, and `YIELD_STREAM_DURATION` is 432,000 of them: a
    ///      `MIN_EPOCH_YIELD` epoch delivers a quarter of 1e6 to this leg, which is under one wei
    ///      per second. The whole stream would round away.
    uint256 private constant ACC_PRECISION = 1e18;

    /// @dev Gas cap for the non-reverting raw balance probe used by the ERC-4626 maximum views.
    uint256 private constant BALANCE_READ_GAS = 30_000;

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

    /// @notice The second key that may halt lender entry. Zero means the role is unfilled, which is
    ///         the shipped default.
    /// @dev Go-live item G4, third contract. See `pause()` for why this switch is guardian-reachable
    ///      when the vault's bond-deposit switch deliberately is not.
    address public guardian;

    /// @notice Ceiling on cumulative lender deposits, in USDC.
    /// @dev Settable by the owner, which is a `TimelockController` in production. It lives here
    ///      rather than in `RiskParams` because it is a *yield* figure rather than a risk one, and
    ///      because `maxDeposit` below is an ERC-4626 override that the standard forbids from
    ///      reverting. Its only external dependency is therefore a gas-bounded asset-balance probe,
    ///      and a failed probe becomes a zero maximum rather than a revert.
    ///
    ///      It used to be `Config.LENDER_POOL_DEPOSIT_CAP`, aliased by `=` to the global borrow
    ///      cap. That alias could not survive the cap becoming storage: a Solidity constant cannot
    ///      be defined in terms of a storage value, so it would have silently frozen at the launch
    ///      figure through every ratchet step. The ratchet still moves the two together; it now
    ///      does so by naming both.
    uint256 public depositCap;

    /// @dev USDC recognised by an explicit pool flow and still held by this contract. It includes
    ///      fixed withdrawal claims and unreleased yield. A raw transfer never writes this slot, so
    ///      donations are inert in every price, cap and liquidity calculation.
    uint256 private _accountedCash;

    /// @notice USDC currently lent out, carried at face value less socialised loss.
    uint256 public outstandingPrincipal;

    /// @notice Cumulative loss written down against the pool, for disclosure. Never decreases.
    uint256 public lifetimeSocialisedLoss;

    /// @notice Cumulative money that came back on a loss already written down here, for
    ///         disclosure. Never decreases either.
    /// @dev **A sibling counter rather than a subtraction from the one above**, and audit round 21
    ///      is why the distinction is worth a line: `lifetimeSocialisedLoss` is what lenders
    ///      actually took, and netting a later recovery into it would erase the fact that they took
    ///      it. `invariant_lifetimeAndPrincipalCountersMoveOnlyOnTheirNamedFlows` (`LenderPool.invariants.t.sol`)
    ///      asserts that counter never falls and never rises without a loss action; this one
    ///      carries the other half, so the pair still answers "how much of it came back"
    ///      without either of them lying.
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
    ///      plus swap-pop keeps both insertion and removal bounded.
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

    struct WithdrawalRequest {
        uint256 requestId;
        address receiver;
        uint256 shares;
    }

    /// @dev One live request per controller. Request IDs are monotonic event identifiers; they do
    ///      not create an ordering or confer settlement priority.
    mapping(address controller => WithdrawalRequest request) private _withdrawalRequests;
    uint256 private _nextWithdrawalRequestId = 1;

    /// @dev Operators may choose only the timing and size of service. The controller alone creates
    ///      and cancels a request, and the receiver is immutable for the request's lifetime.
    mapping(address controller => mapping(address operator => bool approved)) private _requestOperators;

    /// @notice Total shares escrowed against outstanding requests.
    uint256 public queuedShares;

    /// @notice USDC a serviced withdrawal has set aside for its receiver to collect.
    /// @dev Pull, not push. Service only records a claim for the fixed receiver. A receiver that
    ///      USDC blocks can therefore fail only its own later claim and cannot veto another
    ///      controller's service decision.
    mapping(address => uint256) public claimable;

    /// @notice USDC owed to receivers that has not been collected yet.
    /// @dev Subtracted from lendable and withdrawable balances: it is sitting in this contract but
    ///      it is not the pool's money any more.
    uint256 public totalClaimable;

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
    ///      will run. Lowering it below `depositCapUsage()` is legal and simply closes the pool to
    ///      new capital. It cannot strand an existing lender, because neither `maxWithdraw` nor
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
    ///      a cure. `withdraw`, `redeem`, `requestWithdrawal`, `serviceWithdrawalRequest` and
    ///      `claim` are untouched by this switch and stay correct while it is on, so the worst a compromised
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

    /// @notice Recognised cash plus outstanding principal, less fixed claims and unreleased yield.
    /// @dev Raw token balance is deliberately not the book. Anyone may transfer USDC here, so using
    ///      it directly gives an outsider control over entry pricing, lending and the deposit cap.
    ///      `_effectiveCash` also projects an abnormal external balance reduction immediately.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return _totalAssets(_rawBalance());
    }

    /// @inheritdoc ERC4626
    /// @dev Uses a saturating quotient so the standard conversion view remains non-reverting even
    ///      for an input far larger than any amount this capped pool can accept.
    function convertToShares(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        return _convertToShares(assets, _rawBalance());
    }

    function _convertToShares(uint256 assets, uint256 raw) private view returns (uint256) {
        uint256 denominator = Math.saturatingAdd(_totalAssets(raw), 1);
        uint256 numerator = Math.saturatingAdd(totalSupply(), 10 ** _decimalsOffset());
        return _saturatingMulDiv(assets, numerator, denominator, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626
    /// @dev The asset-side conversion uses the same saturating arithmetic as `convertToShares`.
    function convertToAssets(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 numerator = Math.saturatingAdd(totalAssets(), 1);
        uint256 denominator = Math.saturatingAdd(totalSupply(), 10 ** _decimalsOffset());
        return _saturatingMulDiv(shares, numerator, denominator, Math.Rounding.Floor);
    }

    function _totalAssets(uint256 raw) private view returns (uint256) {
        uint256 gross = _effectiveCash(raw) + outstandingPrincipal;
        uint256 excluded = totalClaimable + _effectiveUnreleasedYield(raw);
        return gross > excluded ? gross - excluded : 0;
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
        // zero. The explicit timestamp boundary prevents that permanent residual.
        if (block.timestamp >= yieldStreamEndsAt) return 0;

        if (block.timestamp <= lastYieldAccrualAt) return pending;
        uint256 released = ((block.timestamp - lastYieldAccrualAt) * yieldRate) / ACC_PRECISION;
        return released >= pending ? 0 : pending - released;
    }

    /// @notice Raw USDC outside the recognised book, including donations and terminal residue.
    function unmanagedSurplus() public view returns (uint256) {
        uint256 raw = _rawBalance();
        uint256 accounted = _accountedCash;
        return raw > accounted ? raw - accounted : 0;
    }

    /// @notice Recognised cash missing from the token balance before state reconciliation.
    function cashDeficit() public view returns (uint256) {
        return _cashDeficit(_rawBalance());
    }

    /// @notice Fixed serviced claims not presently backed by recognised physical cash.
    function claimLiquidityDeficit() public view returns (uint256) {
        return _claimLiquidityDeficit(_rawBalance());
    }

    function _claimLiquidityDeficit(uint256 raw) private view returns (uint256) {
        uint256 effective = _effectiveCash(raw);
        uint256 claims = totalClaimable;
        return claims > effective ? claims - effective : 0;
    }

    /// @notice Fixed claims exceeding recognised cash plus outstanding principal.
    /// @dev Unlike a liquidity deficit, this is a balance-sheet shortfall. Only this amount may be
    ///      recapitalised without gifting unstreamed equity to the remaining shareholders.
    function claimSolvencyDeficit() public view returns (uint256) {
        return _claimSolvencyDeficit(_rawBalance());
    }

    function _claimSolvencyDeficit(uint256 raw) private view returns (uint256) {
        uint256 backing = _effectiveCash(raw) + outstandingPrincipal;
        uint256 claims = totalClaimable;
        return claims > backing ? claims - backing : 0;
    }

    function _rawBalance() private view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @dev `maxDeposit` must not revert. A bounded static call converts a broken or hostile token
    ///      balance read into a zero maximum instead of bubbling the failure through the ERC-4626
    ///      limit view.
    function _tryRawBalance() private view returns (bool ok, uint256 raw) {
        bytes memory data;
        (ok, data) = asset().staticcall{gas: BALANCE_READ_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || data.length < 32) return (false, 0);
        assembly ("memory-safe") {
            raw := mload(add(data, 0x20))
        }
    }

    /// @dev Full-precision multiplication and division with saturation instead of a panic when the
    ///      mathematical quotient is outside `uint256`. ERC-4626 preview and conversion views must
    ///      remain quotable for arbitrary caller-supplied inputs.
    function _saturatingMulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding)
        private
        pure
        returns (uint256 result)
    {
        (uint256 high,) = Math.mul512(x, y);
        if (denominator == 0 || high >= denominator) return type(uint256).max;

        result = Math.mulDiv(x, y, denominator);
        if (Math.unsignedRoundsUp(rounding) && mulmod(x, y, denominator) != 0) {
            if (result == type(uint256).max) return result;
            result += 1;
        }
    }

    function _cashDeficit(uint256 raw) private view returns (uint256) {
        uint256 accounted = _accountedCash;
        return accounted > raw ? accounted - raw : 0;
    }

    /// @dev Recognised cash projected down to the physical token balance, but never up to a raw
    ///      donation. This makes every view agree with permissionless reconciliation in advance.
    function _effectiveCash() private view returns (uint256) {
        return _effectiveCash(_rawBalance());
    }

    function _effectiveCash(uint256 raw) private view returns (uint256) {
        uint256 accounted = _accountedCash;
        return raw < accounted ? raw : accounted;
    }

    /// @dev The live tail is bounded twice. An external cash shortfall consumes unreleased yield
    ///      before released NAV, and fixed claims then cap the tail at the gross backing still left
    ///      for shareholders. The second bound prevents a destroyed tail from being revived by a
    ///      later depositor.
    function _effectiveUnreleasedYield() private view returns (uint256) {
        return _effectiveUnreleasedYield(_rawBalance());
    }

    function _effectiveUnreleasedYield(uint256 raw) private view returns (uint256 effective) {
        effective = unreleasedYield();
        uint256 deficit = _cashDeficit(raw);
        if (deficit >= effective) return 0;
        effective -= deficit;

        uint256 backing = _effectiveCash(raw) + outstandingPrincipal;
        uint256 claims = totalClaimable;
        backing = backing > claims ? backing - claims : 0;
        if (effective > backing) effective = backing;
    }

    /// @dev Recognised shareholder cash after fixed claims and the backed stream tail. This is the
    ///      sole cash basis for exits, request reserves and lending.
    function _poolBalance(uint256 raw) private view returns (uint256) {
        uint256 effective = _effectiveCash(raw);
        uint256 excluded = totalClaimable + _effectiveUnreleasedYield(raw);
        return effective > excluded ? effective - excluded : 0;
    }

    /// @notice Released shareholder cash retained while principal remains at risk.
    /// @dev Unreleased yield is cash too, but only the portion physically held after fixed claims
    ///      can protect against a total principal write-off. The remainder of
    ///      `minimumEntryAssets()` is senior to exits, request service and new lending. Once no
    ///      principal remains, exits may release the reserve. `available()` still applies it to a
    ///      prospective loan because that call is what creates the next principal at risk.
    function entryPriceCashReserve() public view returns (uint256) {
        return _entryPriceCashReserve(_rawBalance(), false);
    }

    function _entryPriceCashReserve(uint256 raw, bool prospectivePrincipal) private view returns (uint256) {
        if (!prospectivePrincipal && outstandingPrincipal == 0) return 0;

        uint256 effective = _effectiveCash(raw);
        uint256 claims = totalClaimable;
        uint256 cashAfterClaims = effective > claims ? effective - claims : 0;
        uint256 tailCash = _effectiveUnreleasedYield(raw);
        if (tailCash > cashAfterClaims) tailCash = cashAfterClaims;

        uint256 required = minimumEntryAssets();
        return required > tailCash ? required - tailCash : 0;
    }

    /// @dev Shareholder cash that is neither fixed-claim backing, yield tail nor entry-price
    ///      safety cash. This is the only cash basis that exits, requests and lending may consume.
    function _executablePoolCash(uint256 raw) private view returns (uint256) {
        uint256 poolCash = _poolBalance(raw);
        uint256 reserve = _entryPriceCashReserve(raw, false);
        return poolCash > reserve ? poolCash - reserve : 0;
    }

    /// @dev Crystallise a reduced stream without changing its payout rate. The end moves earlier
    ///      when the smaller pot runs dry. The epoch accrual clock is deliberately untouched.
    function _writeYieldState(uint256 target) private {
        uint256 unreleased = unreleasedYield();
        if (target >= unreleased) return;

        uint256 oldRate = yieldRate;
        uint256 oldRemaining = yieldStreamEndsAt > block.timestamp ? yieldStreamEndsAt - block.timestamp : 0;

        pendingYield = target;
        lastYieldAccrualAt = block.timestamp;
        if (target == 0) {
            yieldRate = 0;
            yieldStreamEndsAt = block.timestamp;
            return;
        }

        if (oldRate == 0 || totalSupply() < MIN_SUPPLY_FOR_YIELD) {
            yieldRate = 0;
            yieldStreamEndsAt = block.timestamp;
            return;
        }

        uint256 duration = Math.mulDiv(target, ACC_PRECISION, oldRate, Math.Rounding.Ceil);
        if (duration > oldRemaining) duration = oldRemaining;
        assert(duration != 0);
        yieldRate = oldRate;
        yieldStreamEndsAt = block.timestamp + duration;
    }

    /// @notice Write an observed external token-balance reduction into the recognised cash book.
    /// @return lost Recognised cash removed from the book.
    /// @return yieldWrittenOff How much projected unreleased yield absorbed first.
    function reconcileCashDeficit() external nonReentrant returns (uint256 lost, uint256 yieldWrittenOff) {
        return _reconcileCashDeficit();
    }

    function _reconcileCashDeficit() private returns (uint256 lost, uint256 yieldWrittenOff) {
        uint256 raw = _rawBalance();
        uint256 accountedBefore = _accountedCash;
        uint256 unreleasedBefore = unreleasedYield();
        uint256 backedYield = _effectiveUnreleasedYield(raw);

        if (accountedBefore > raw) {
            lost = accountedBefore - raw;
            _accountedCash = raw;
        }
        yieldWrittenOff = unreleasedBefore - backedYield;
        if (yieldWrittenOff != 0) {
            _writeYieldState(backedYield);
        } else if (lost != 0 && backedYield == 0 && (pendingYield != 0 || yieldRate != 0)) {
            // A finished stream can retain stale terms even though `unreleasedYield()` is zero.
            // Reconciliation clears those terms so a cash loss leaves one canonical empty state.
            pendingYield = 0;
            yieldRate = 0;
            yieldStreamEndsAt = block.timestamp;
            lastYieldAccrualAt = block.timestamp;
        }

        if (lost != 0 || yieldWrittenOff != 0) {
            uint256 claims = totalClaimable;
            uint256 effectiveAfter = _effectiveCash(raw);
            uint256 claimDeficitAfter = claims > effectiveAfter ? claims - effectiveAfter : 0;
            emit CashDeficitReconciled(accountedBefore, _accountedCash, yieldWrittenOff, claimDeficitAfter);
        }
    }

    /// @notice Supply USDC specifically to restore insolvent fixed serviced withdrawal claims.
    /// @dev A claim that is merely waiting on outstanding principal is solvent and cannot use this
    ///      door. Recognising that liquidity top-up without streaming it would gift its value to the
    ///      remaining shareholders.
    /// @return remaining The claim solvency shortfall still outstanding.
    function coverClaimDeficit(uint256 amount) external nonReentrant returns (uint256 remaining) {
        if (amount == 0) revert ZeroAmount();
        _reconcileCashDeficit();

        uint256 deficit = claimSolvencyDeficit();
        if (amount > deficit) revert ClaimDeficitExceeded(amount, deficit);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _accountedCash += amount;
        remaining = deficit - amount;
        emit ClaimDeficitCovered(msg.sender, amount, remaining);
    }

    /// @notice Restore a minimum entry-price shortfall without minting shares.
    /// @dev This is an explicit recapitalisation door for an abnormal recognised cash loss. It is
    ///      capped at the exact shortfall, so it cannot be used as an unstreamed donation. Fixed
    ///      claims must be liquid first; otherwise part of this cash would belong to claimants and
    ///      the reported share-price repair would be false. A merely solvent liquidity gap waits
    ///      for neutral principal repayment rather than using this recapitalisation door.
    /// @return remaining The minimum entry-price shortfall still outstanding.
    function coverEntryPriceDeficit(uint256 amount) external nonReentrant returns (uint256 remaining) {
        if (amount == 0) revert ZeroAmount();
        _reconcileCashDeficit();

        uint256 claimDeficit = claimLiquidityDeficit();
        if (claimDeficit != 0) {
            revert ClaimsUnderfunded(totalClaimable, _effectiveCash());
        }

        uint256 deficit = entryPriceDeficit();
        if (amount > deficit) revert EntryPriceDeficitExceeded(amount, deficit);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _accountedCash += amount;
        remaining = deficit - amount;
        emit EntryPriceDeficitCovered(msg.sender, amount, remaining);
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
    ///         never moved. Reported as a
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
    ///      The clamp is solely a loss bound. Request service is controller-scoped and protected
    ///      by an execution floor, so it does not need a separate reserve refusal here.
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

    /// @dev Swap-pop and idempotent because both writers can reach it with nothing to remove.
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
    ///      A frozen backlog is included too. If supply is non-zero, that value belongs to the
    ///      existing cohort even while its clock is stopped, so a newcomer must pay for it rather
    ///      than dilute it. A terminal pot with no holder is de-recognised instead.
    ///
    ///      Impairments are not deducted here. Entry pricing remains on the un-impaired book so an
    ///      entrant cannot buy the discount and profit when the mark is released.
    function _entryAssets() private view returns (uint256) {
        return _entryAssets(_rawBalance());
    }

    function _entryAssets(uint256 raw) private view returns (uint256 assets) {
        assets = _totalAssets(raw);
        assets = Math.saturatingAdd(assets, _effectiveUnreleasedYield(raw));
    }

    /// @notice Minimum shareholder backing required by the bounded share-to-asset quotient.
    /// @dev The virtual asset and shares are included exactly as they are in entry conversion.
    ///      Fair-price deposits preserve this boundary. Cash-consuming paths retain enough of the
    ///      backing that a later total principal write-off preserves it too.
    function minimumEntryAssets() public view returns (uint256) {
        uint256 sharesWithVirtual = Math.saturatingAdd(totalSupply(), 10 ** _decimalsOffset());
        return Math.ceilDiv(sharesWithVirtual, Config.MAX_LENDER_SHARES_PER_ASSET) - 1;
    }

    /// @notice Absolute real share supply supported by the bounded entry quotient and asset cap.
    /// @dev Ordinary entry stays below this by algebra. The central mint check is a defensive
    ///      backstop against a future internal mint path that forgets one side of that proof.
    function maximumShareSupply() public pure returns (uint256) {
        uint256 maximumWithVirtual = Config.MAX_LENDER_SHARES_PER_ASSET * (Config.GLOBAL_BORROW_CAP_MAX + 1);
        return maximumWithVirtual - 10 ** _decimalsOffset();
    }

    /// @notice Recognised cash backing needed before fair-price entry can resume safely.
    /// @dev This uses cash after fixed claims, not cash plus principal. Principal can still be
    ///      written off after the entry, so letting it satisfy the boundary would preserve today's
    ///      quote and leave tomorrow's loss able to break it. Protocol-controlled flows retain this
    ///      cash in advance. A projected or reconciled external token-balance loss can consume it.
    function entryPriceDeficit() public view returns (uint256) {
        return _entryPriceDeficit(_rawBalance());
    }

    function _entryPriceDeficit(uint256 raw) private view returns (uint256) {
        uint256 required = minimumEntryAssets();
        uint256 effective = _effectiveCash(raw);
        uint256 claims = totalClaimable;
        uint256 target = Math.saturatingAdd(claims, required);
        return target > effective ? target - effective : 0;
    }

    /// @dev OpenZeppelin 5.6.1's entry conversion with `_entryAssets()` substituted for
    ///      `totalAssets()`. The virtual one asset and `10 ** _decimalsOffset()` shares are kept
    ///      exactly, including the deposit-side floor that prevents over-issuing shares.
    function _entryToShares(uint256 assets) private view returns (uint256) {
        return _entryToShares(assets, _rawBalance());
    }

    function _entryToShares(uint256 assets, uint256 raw) private view returns (uint256) {
        return _saturatingMulDiv(
            assets,
            Math.saturatingAdd(totalSupply(), 10 ** _decimalsOffset()),
            Math.saturatingAdd(_entryAssets(raw), 1),
            Math.Rounding.Floor
        );
    }

    /// @dev The exact-share inverse of `_entryToShares`, retaining OpenZeppelin's asset-side
    ///      ceiling so a mint never underpays the gross entry price.
    function _entryToAssets(uint256 shares) private view returns (uint256) {
        return _entryToAssets(shares, _rawBalance());
    }

    function _entryToAssets(uint256 shares, uint256 raw) private view returns (uint256) {
        return _saturatingMulDiv(
            shares,
            Math.saturatingAdd(_entryAssets(raw), 1),
            Math.saturatingAdd(totalSupply(), 10 ** _decimalsOffset()),
            Math.Rounding.Ceil
        );
    }

    /// @notice What the pool is worth to somebody leaving it: assets less reserved shortfalls.
    /// @dev The entry side deliberately does **not** deduct this. Its active-tail adjustment is
    ///      independent of the impairment split; see `_entryAssets` and `previewDeposit`. Not
    ///      deducting the reserve is the whole impairment mechanism, and it is Maple's: an entrant
    ///      who bought at the impaired price would profit when the impairment was released, which
    ///      is round-11's buy-the-dip finding arriving through the front door instead.
    function exitAssets() public view returns (uint256) {
        return _exitAssets(_rawBalance());
    }

    function _exitAssets(uint256 raw) private view returns (uint256) {
        uint256 assets = _totalAssets(raw);
        uint256 reserved = exitReserve();
        return assets > reserved ? assets - reserved : 0;
    }

    /// @dev OZ's conversion math with `exitAssets()` substituted for `totalAssets()`. The virtual
    ///      share and asset terms are kept identical, or the inflation defence would differ between
    ///      the two sides of the pool.
    function _exitToShares(uint256 assets, Math.Rounding rounding) private view returns (uint256) {
        return _exitToShares(assets, rounding, _rawBalance());
    }

    function _exitToShares(uint256 assets, Math.Rounding rounding, uint256 raw) private view returns (uint256) {
        return _saturatingMulDiv(
            assets,
            Math.saturatingAdd(totalSupply(), 10 ** _decimalsOffset()),
            Math.saturatingAdd(_exitAssets(raw), 1),
            rounding
        );
    }

    function _exitToAssets(uint256 shares, Math.Rounding rounding) private view returns (uint256) {
        return _exitToAssets(shares, rounding, _rawBalance());
    }

    function _exitToAssets(uint256 shares, Math.Rounding rounding, uint256 raw) private view returns (uint256) {
        return _saturatingMulDiv(
            shares,
            Math.saturatingAdd(_exitAssets(raw), 1),
            Math.saturatingAdd(totalSupply(), 10 ** _decimalsOffset()),
            rounding
        );
    }

    /// @notice Executable cash reserved pro rata for all currently requested shares.
    /// @dev The entry-price cash reserve is removed first because it is senior while principal can
    ///      still be lost. Both numerator and result are cash-denominated. Ceiling rounding gives
    ///      the request side the one indivisible executable cash unit at the boundary.
    function queueCashReserve() public view returns (uint256) {
        uint256 raw = _rawBalance();
        return _queueCashReserve(_executablePoolCash(raw));
    }

    function _queueCashReserve(uint256 executableCash) private view returns (uint256) {
        uint256 shares = queuedShares;
        if (shares == 0) return 0;
        return Math.mulDiv(executableCash, shares, totalSupply(), Math.Rounding.Ceil);
    }

    /// @notice Executable USDC not reserved for live withdrawal requests.
    function unreservedIdle() public view returns (uint256) {
        return _unreservedIdle(_rawBalance());
    }

    function _unreservedIdle(uint256 raw) private view returns (uint256) {
        uint256 executable = _executablePoolCash(raw);
        return executable - _queueCashReserve(executable);
    }

    /// @notice The recognised entry book currently consuming the deposit cap.
    /// @dev Active and frozen stream value both belong to a non-zero cohort and count in full. A
    ///      terminal residual is de-recognised, and raw donations never enter `_accountedCash`, so
    ///      neither can consume headroom.
    function depositCapUsage() public view returns (uint256 usage) {
        uint256 gross = _accountedCash + outstandingPrincipal;
        uint256 claims = totalClaimable;
        usage = gross > claims ? gross - claims : 0;
    }

    /// @inheritdoc ERC4626
    /// @dev Conservative while an external cash deficit awaits explicit reconciliation. Fixed
    ///      claims must be fully cash-backed before new lender money can enter, and a quoted maximum
    ///      must mint at least one share. A failed raw-balance probe returns zero rather than
    ///      violating ERC-4626's non-reverting maximum rule.
    function maxDeposit(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        (bool ok, uint256 raw) = _tryRawBalance();
        return ok ? _maxDeposit(receiver, raw) : 0;
    }

    function _maxDeposit(address receiver, uint256 raw) private view returns (uint256) {
        if (paused() || receiver == address(0) || receiver == address(this)) return 0;
        if (_cashDeficit(raw) != 0) return 0;

        uint256 effective = _effectiveCash(raw);
        if (totalClaimable > effective) return 0;
        if (_entryPriceDeficit(raw) != 0) return 0;

        uint256 usage = depositCapUsage();
        uint256 cap = depositCap;
        if (usage >= cap) return 0;

        uint256 headroom = cap - usage;
        uint256 supply = totalSupply();
        uint256 maximumSupply = maximumShareSupply();
        if (supply >= maximumSupply) return 0;

        uint256 shareRoom = maximumSupply - supply;
        uint256 assetRoom = _entryToAssets(shareRoom + 1, raw) - 1;
        if (assetRoom < headroom) headroom = assetRoom;
        return _entryToShares(headroom, raw) == 0 ? 0 : headroom;
    }

    /// @inheritdoc ERC4626
    /// @dev Converts the remaining asset cap at the same gross active-tail price `previewMint`
    ///      executes. Rounding down guarantees the quoted share maximum costs no more than
    ///      `maxDeposit(receiver)` when `previewMint` applies its inverse ceiling.
    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        (bool ok, uint256 raw) = _tryRawBalance();
        if (!ok) return 0;
        uint256 shares = _entryToShares(_maxDeposit(receiver, raw), raw);
        uint256 supply = totalSupply();
        uint256 maximumSupply = maximumShareSupply();
        uint256 shareRoom = supply < maximumSupply ? maximumSupply - supply : 0;
        return shares < shareRoom ? shares : shareRoom;
    }

    /// @inheritdoc ERC4626
    /// @dev Prices a deposit against the un-impaired book plus the projected tail of a live yield
    ///      stream. A post-delivery entrant therefore pays for the whole active pot and cannot
    ///      dilute the delivered cohort as it releases. A frozen pot belongs to the same non-zero
    ///      cohort and is priced here too. `_entryToShares` preserves OpenZeppelin's virtual terms
    ///      and floor.
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
    ///      figure that silently turns into an asynchronous request on execution.
    ///
    ///      Priced on `exitAssets()`, so a lender leaving during a liquidation already carries the
    ///      expected loss. **That pricing is what replaced the round-10 gate**, which used to
    ///      return a flat zero from here while a liquidation was live: the number is honest now, so
    ///      there is nothing to run from and no reason to stop anybody. It is also why this reads
    ///      storage plus one bounded asset-balance probe, which turns a failed read into zero rather
    ///      than reverting - see decision 4 in the contract header.
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
    ///      This uses storage and one bounded asset-balance probe, returns zero if that probe fails,
    ///      and otherwise never returns zero for a lender with shares while any cash is
    ///      unspoken-for. It is computed at read time for the caller's own immediate ERC-4626 exit
    ///      and gives no controller authority over another request.
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
        (bool ok, uint256 raw) = _tryRawBalance();
        return ok ? _exitToAssets(_maxRedeem(owner, raw), Math.Rounding.Floor, raw) : 0;
    }

    /// @inheritdoc ERC4626
    /// @dev The share-denominated twin of `maxWithdraw`, and now the primary of the pair: the
    ///      liquidity cap is an asset quantity and this is where it becomes a share count, so this
    ///      is the function the bound lives on and `maxWithdraw` is derived from it. Read
    ///      `maxWithdraw`'s note for what the pair costs under a mark, for what the old shape cost,
    ///      and for the two precedents this is not. ERC-4626 forbids this from reverting, so its one
    ///      asset-balance probe is bounded and a failed read returns zero.
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
        (bool ok, uint256 raw) = _tryRawBalance();
        return ok ? _maxRedeem(owner, raw) : 0;
    }

    function _maxRedeem(address owner, uint256 raw) private view returns (uint256) {
        if (_claimLiquidityDeficit(raw) != 0) return 0;

        uint256 shares = balanceOf(owner);
        uint256 idleShares = _convertToShares(_unreservedIdle(raw), raw);
        if (idleShares < shares) shares = idleShares;

        if (outstandingPrincipal != 0) {
            uint256 supply = totalSupply();
            uint256 burnable = supply > MIN_SUPPLY_FOR_YIELD ? supply - MIN_SUPPLY_FOR_YIELD : 0;
            if (burnable < shares) shares = burnable;
        }
        return shares;
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
        returns (uint256)
    {
        if (receiver == address(this)) revert EscrowIsNotAHolder();
        uint256 deficit = cashDeficit();
        if (deficit != 0) revert CashDeficitOutstanding(deficit);
        _reconcileCashDeficit();
        uint256 priceDeficit = entryPriceDeficit();
        if (priceDeficit != 0) {
            uint256 required = minimumEntryAssets();
            uint256 current = priceDeficit < required ? required - priceDeficit : 0;
            revert EntryPriceBelowMinimum(current, required);
        }
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
        returns (uint256)
    {
        if (receiver == address(this)) revert EscrowIsNotAHolder();
        uint256 deficit = cashDeficit();
        if (deficit != 0) revert CashDeficitOutstanding(deficit);
        _reconcileCashDeficit();
        uint256 priceDeficit = entryPriceDeficit();
        if (priceDeficit != 0) {
            uint256 required = minimumEntryAssets();
            uint256 current = priceDeficit < required ? required - priceDeficit : 0;
            revert EntryPriceBelowMinimum(current, required);
        }
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
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares) {
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
    function mint(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets) {
        assets = mint(shares, receiver);
        if (assets > maxAssets) revert AssetsAboveMaximum(assets, maxAssets);
    }

    /// @notice Refuses shares sent straight to the pool. Use `requestWithdrawal`.
    /// @dev The contract address is request escrow, not a holder. Allowing any other route to send
    ///      shares here creates an ownerless position that no controller can service or cancel.
    ///      Request creation and cancellation use the internal transfer path and remain available.
    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        if (to == address(this)) revert EscrowIsNotAHolder();
        return super.transfer(to, value);
    }

    /// @dev The same door as `transfer`, and shut for the same reason.
    function transferFrom(address from, address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        if (to == address(this)) revert EscrowIsNotAHolder();
        return super.transferFrom(from, to, value);
    }

    /// @dev Overridden for `nonReentrant` and to refuse the request escrow as receiver. Exit value
    ///      is still priced through `exitAssets()`; owner and receiver may otherwise differ.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (receiver == address(this)) revert EscrowIsNotAHolder();
        _reconcileCashDeficit();
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
        _reconcileCashDeficit();
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
    ///      **This is a bound on the caller's own call.** There is no cursor, ordering, stored
    ///      floor, or second party. The figure lives in calldata for one transaction and can only
    ///      revert the caller's own exit. Request service uses the same caller-scoped shape.
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
    /// @dev Bounded by `available()`, which holds back the cash owned by live requests and the
    ///      operational float on the post-request book. A live impairment changes exit pricing but
    ///      does not create another cash holdback: refusing every borrow while one position is in
    ///      distress would halt the whole protocol over one bad loan.
    function lend(uint256 amount) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        if (amount == 0) revert ZeroAmount();
        _reconcileCashDeficit();
        if (totalSupply() < MIN_SUPPLY_FOR_YIELD) revert NoSharesOutstanding();

        uint256 claimDeficit = claimLiquidityDeficit();
        if (claimDeficit != 0) revert ClaimsUnderfunded(totalClaimable, _effectiveCash());

        uint256 lendable = available();
        if (amount > lendable) revert InsufficientLiquidity(amount, lendable);

        _accountedCash -= amount;
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
        _reconcileCashDeficit();

        uint256 claimDeficitBefore = claimSolvencyDeficit();

        // Clamped rather than subtracted. Yield can exceed principal, and a socialised loss has
        // already reduced this counter for money that will never come back - so a repayment can
        // legitimately be larger than what is still recorded as out on loan.
        //
        // **Shareholder surplus is routed through the yield mechanism, not banked, and audit round
        // 11 is why.** Left as idle float it lands in `totalAssets()` in the repaying block, which is
        // an instantaneous share-price step, and `settlePrincipal` is permissionless, so a
        // just-in-time depositor picks the block and can take a pro-rata slice immediately. That
        // same-block capture is exactly the defect the yield stream exists to prevent, arriving on
        // the principal leg where nobody had thought to look for it. A fixed-claim insolvency is
        // repaired first; residual value streams for a viable cohort, freezes below the stream
        // floor, or is de-recognised when no holder remains.
        //
        // It is real money and it does belong to the pool. Streaming it, together with gross
        // active-tail entry pricing, assigns it economically to the shares present at delivery
        // rather than to whoever enters after seeing the transaction. Share accounting does not
        // preserve which accounts held through the historical write-down.
        uint256 outstanding = outstandingPrincipal;
        uint256 principal = amount > outstanding ? outstanding : amount;
        uint256 surplus = amount - principal;

        IERC20(asset()).safeTransferFrom(creditManager, address(this), amount);
        outstandingPrincipal = outstanding - principal;
        _accountedCash += amount;

        uint256 covered = surplus > claimDeficitBefore ? claimDeficitBefore : surplus;
        if (covered != 0) emit ClaimDeficitCovered(creditManager, covered, claimDeficitBefore - covered);

        uint256 streamable = surplus - covered;

        if (streamable != 0) {
            // With no holder, a surplus has no cohort and is de-recognised permanently. A low but
            // non-zero cohort keeps it frozen and priced into any later entry.
            uint256 supply = totalSupply();
            if (supply == 0) {
                _accountedCash -= streamable;
                emit CashDerecognised(streamable);
            } else if (supply < MIN_SUPPLY_FOR_YIELD) {
                pendingYield = unreleasedYield() + streamable;
                yieldRate = 0;
                yieldStreamEndsAt = block.timestamp;
                lastYieldAccrualAt = block.timestamp;
            } else {
                _rateStream(streamable, false);
            }
            if (supply != 0) emit PrincipalSurplusStreamed(streamable);
        }

        emit PrincipalRepaid(amount);
    }

    /// @notice Receive the lender share of harvested yield. Repairs fixed claims first, then raises
    ///         share value for a viable cohort over time. Harvester only.
    /// @dev Pull, not push, because that is what `EpochHarvester._tryDeliverLenderYield` does: it
    ///      approves this contract for the amount and then calls. A plain `receive`-style
    ///      implementation would take nothing and the harvester would correctly report that
    ///      nothing was delivered.
    ///
    ///      No shares are minted. For the shareholder remainder, released assets rise while supply
    ///      does not, and entry previews charge a newcomer for the projected active tail so shares
    ///      already present at delivery are not diluted while that value moves into released NAV.
    ///
    ///      **The shareholder remainder is streamed, not applied at once**, and this is audit round
    ///      10's finding 6. An instantaneous share-price step is free money for anyone watching the mempool:
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
        _reconcileCashDeficit();
        uint256 raw = _rawBalance();
        uint256 liquidityDeficitBefore = _claimLiquidityDeficit(raw);
        uint256 claimDeficitBefore = _claimSolvencyDeficit(raw);
        uint256 covered = amount > claimDeficitBefore ? claimDeficitBefore : amount;

        // Raising the price of nothing destroys the money. With no shares outstanding the assets
        // back only the virtual shares the decimals offset implies, which nobody owns and no
        // function here can sweep - a later depositor gets their own principal back and not a cent
        // of this. The harvester measures delivery and catches the revert, so refusing leaves the
        // share owed in `pendingLenderYield` until there is somebody to pay it to. That is exactly
        // what that counter is for: "the lender share of every epoch before the pool opens is
        // still owed and payable". Fixed serviced claims are the exception: they remain real debts
        // after the last share is burned, so the pool pulls only their exact insolvency shortfall.
        // Any excess stays with the measuring harvester and remains pending for a future cohort.
        if (totalSupply() < MIN_SUPPLY_FOR_YIELD) {
            if (covered == 0) revert NoSharesOutstanding();

            IERC20(asset()).safeTransferFrom(epochHarvester, address(this), covered);
            _accountedCash += covered;
            if (covered == amount) lastYieldDistributeAt = block.timestamp;
            emit ClaimDeficitCovered(epochHarvester, covered, claimDeficitBefore - covered);
            emit YieldDistributed(covered, yieldRate, yieldStreamEndsAt);
            return;
        }

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
        //
        // The exception is an existing claim liquidity deficit. Entry is already closed in that
        // state, so there is no just-in-time entrant to protect against, while rejecting the whole
        // epoch would also reject cash that can restore the fixed claims. Only the balance-sheet
        // insolvency is recognised immediately; every residual gain still enters the stream.
        uint256 streamable = amount - covered;
        uint256 capital = _totalAssets(raw);
        if (liquidityDeficitBefore == 0 && streamable > capital) {
            revert YieldExceedsCapital(streamable, capital);
        }

        IERC20(asset()).safeTransferFrom(epochHarvester, address(this), amount);
        _accountedCash += amount;

        if (covered != 0) emit ClaimDeficitCovered(epochHarvester, covered, claimDeficitBefore - covered);

        if (streamable != 0) {
            _rateStream(streamable, true);
        } else {
            lastYieldDistributeAt = block.timestamp;
        }

        emit YieldDistributed(amount, yieldRate, yieldStreamEndsAt);
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
        //    division dust, and anything frozen while real supply was below the safety floor
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

    /// @dev Every ERC-4626 entry funnels through here. The transfer and mint complete before the
    ///      cash is recognised, so a raw transfer can never become accounted value on its own.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // **A deposit that mints nothing is a donation the depositor did not mean to make**, and
        // audit round 22 finding 2 is why the guard is here rather than filed as dust. Once the
        // share price is high enough for `previewDeposit` to round to zero, this path took the USDC
        // and minted nothing for it: a total loss for the depositor and a windfall for everyone
        // already in. Canonical cash makes raw donations inert, but loss and yield can still move
        // the price far enough to reach the same rounding boundary.
        //
        // On the hook rather than on `deposit`, because `mint` funnels through here too and a
        // zero-share mint is the same refusal. There is no legitimate caller of either.
        if (shares == 0) revert ZeroAmount();

        super._deposit(caller, receiver, assets, shares);
        _accountedCash += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _accountedCash -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
        _derecogniseEmptyPoolResidual();
    }

    /// @dev The burn floor is centralised here so synchronous exits and request service cannot
    ///      disagree. While principal is out, at least the yield-safety supply must remain.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) && to != address(0)) {
            uint256 supply = totalSupply();
            uint256 maximumSupply = maximumShareSupply();
            if (supply > maximumSupply || value > maximumSupply - supply) {
                revert MaximumShareSupplyExceeded(Math.saturatingAdd(supply, value), maximumSupply);
            }
        }

        if (to == address(0) && from != address(0) && outstandingPrincipal != 0) {
            uint256 supply = totalSupply();
            uint256 resulting = value >= supply ? 0 : supply - value;
            if (resulting < MIN_SUPPLY_FOR_YIELD) {
                revert MinimumShareSupply(resulting, MIN_SUPPLY_FOR_YIELD);
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
        uint256 supplyAfter = totalSupply();
        if (yieldRate != 0 && supplyAfter != 0 && supplyAfter < MIN_SUPPLY_FOR_YIELD) {
            // Computed before the rate is zeroed, so the elapsed part of the stream is still paid.
            uint256 unreleased = _effectiveUnreleasedYield();
            pendingYield = unreleased;
            yieldRate = 0;
            yieldStreamEndsAt = block.timestamp;
            lastYieldAccrualAt = block.timestamp;
            emit YieldStreamFrozen(unreleased);
        }
    }

    /// @dev Once both supply and principal are zero, recognised cash not owed to fixed claims has
    ///      no owner. Remove it from the book and leave the raw tokens permanently inert. This
    ///      prevents a later depositor or epoch from reviving an abandoned cohort's value.
    function _derecogniseEmptyPoolResidual() private {
        if (totalSupply() != 0 || outstandingPrincipal != 0) return;

        uint256 accounted = _accountedCash;
        uint256 claims = totalClaimable;
        uint256 residual = accounted > claims ? accounted - claims : 0;

        _accountedCash = accounted - residual;
        pendingYield = 0;
        yieldRate = 0;
        yieldStreamEndsAt = block.timestamp;
        lastYieldAccrualAt = block.timestamp;
        if (residual != 0) emit CashDerecognised(residual);
    }

    /// @notice Write a shortfall down against the pool. CreditManager only.
    /// @dev The loss lands on principal that has been lent out and will not come back, so it
    ///      reduces `outstandingPrincipal` and therefore `totalAssets`, and therefore the share
    ///      price. Every lender takes it in proportion to their holding, **including anyone
    ///      holding a withdrawal request**, whose shares are still outstanding for exactly
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
        _reconcileCashDeficit();

        absorbed = amount > outstandingPrincipal ? outstandingPrincipal : amount;
        outstandingPrincipal -= absorbed;
        lifetimeSocialisedLoss += absorbed;

        // A principal loss can destroy backing underneath an active tail without moving cash.
        // Write that part off now so a later depositor cannot make it live again.
        uint256 backed = _accountedCash + outstandingPrincipal;
        uint256 claims = totalClaimable;
        backed = backed > claims ? backed - claims : 0;
        uint256 unreleased = unreleasedYield();
        if (unreleased > backed) _writeYieldState(backed);

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
    ///      `outstandingPrincipal` does not move because there is no loan to re-recognise.
    ///
    ///      Fixed-claim insolvency is repaired first. Residual shareholder value follows exactly the
    ///      rules `repayPrincipal`'s surplus branch uses: it streams for a viable cohort, freezes
    ///      below the stream floor, or is de-recognised when no holder remains. The stream rule is
    ///      required because `LiquidationAuction.workoutSettleAfterClose` is permissionless and an
    ///      instantaneous share-price step is capturable by whoever picks the block. An active
    ///      stream belongs economically to the shares present when delivery occurs: later entries
    ///      pay its gross value, but the pool does not reconstruct which accounts historically bore
    ///      the write-down. That is round 10's finding 6, and this is a third leg it covers.
    ///
    ///      No `YieldExceedsCapital` guard, unlike `distributeYield`: a recovery genuinely can
    ///      exceed everything the pool now holds, precisely because the loss it reverses is what
    ///      made the pool that small. The closer sibling is `repayPrincipal`'s surplus, which has
    ///      no such guard either and for the same reason.
    function recoverLoss(uint256 amount) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        if (amount == 0) revert ZeroAmount();
        _reconcileCashDeficit();

        uint256 claimDeficitBefore = claimSolvencyDeficit();
        IERC20(asset()).safeTransferFrom(creditManager, address(this), amount);
        _accountedCash += amount;

        uint256 covered = amount > claimDeficitBefore ? claimDeficitBefore : amount;
        if (covered != 0) emit ClaimDeficitCovered(creditManager, covered, claimDeficitBefore - covered);
        uint256 streamable = amount - covered;

        // A gain with no holder is de-recognised permanently. A low but non-zero cohort keeps it
        // frozen and priced into later entry until a stream can run safely.
        uint256 supply = totalSupply();
        if (streamable != 0 && supply == 0) {
            _accountedCash -= streamable;
            emit CashDerecognised(streamable);
        } else if (streamable != 0 && supply < MIN_SUPPLY_FOR_YIELD) {
            pendingYield = unreleasedYield() + streamable;
            yieldRate = 0;
            yieldStreamEndsAt = block.timestamp;
            lastYieldAccrualAt = block.timestamp;
        } else if (streamable != 0) {
            _rateStream(streamable, false);
        }

        lifetimeLossRecovered += amount;
        emit LossRecovered(amount, lifetimeLossRecovered);
    }

    /// @notice USDC available to lend after request cash, operational float and price safety cash.
    /// @dev The request reserve is cash-denominated. The 15% float is then calculated on the book
    ///      that remains after that cash is paid:
    ///
    ///      `reserve = ceil(executableCash * queuedShares / totalSupply)`
    ///      `float = floor((totalAssets - reserve) * RESERVE_RATIO_BPS / BPS)`
    ///
    ///      Applying the float to `totalAssets` would count the requested payout twice. Taking the
    ///      maximum of those two terms would leave the post-payment book below its float target.
    ///
    ///      The senior holdback is `minimumEntryAssets()`. Unreleased yield is physical cash and is
    ///      already excluded from executable cash, so only the remainder has to stay in the pool.
    ///      If every principal unit is then written off, recognised cash plus that yield still meet
    ///      the bounded entry quotient. Repeated losses therefore taper lending instead of growing
    ///      ERC-20 share supply until a conversion overflows.
    function available() public view returns (uint256) {
        if (totalSupply() < MIN_SUPPLY_FOR_YIELD) return 0;

        uint256 raw = _rawBalance();
        uint256 effective = _effectiveCash(raw);
        if (totalClaimable > effective) return 0;

        uint256 poolCash = _poolBalance(raw);
        uint256 priceReserve = _entryPriceCashReserve(raw, true);
        uint256 lendingCash = poolCash > priceReserve ? poolCash - priceReserve : 0;
        uint256 requestReserve = _queueCashReserve(lendingCash);
        uint256 postRequestBook = _totalAssets(raw) - requestReserve;
        uint256 postRequestFloat = Math.mulDiv(postRequestBook, Config.RESERVE_RATIO_BPS, Config.BPS);
        uint256 held = requestReserve + postRequestFloat;
        return lendingCash > held ? lendingCash - held : 0;
    }

    // ── Controller-scoped withdrawal requests ────────────────────────────────

    /// @notice Escrow shares in a request controlled only by the caller.
    /// @dev Escrowed shares stay outstanding, continue to earn yield and carry losses. The receiver
    ///      is fixed for the request's lifetime.
    function requestWithdrawal(uint256 shares, address receiver) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert EscrowIsNotAHolder();

        WithdrawalRequest storage existing = _withdrawalRequests[msg.sender];
        if (existing.requestId != 0) revert AlreadyQueued(existing.requestId);

        _transfer(msg.sender, address(this), shares);

        uint256 requestId = _nextWithdrawalRequestId++;
        _withdrawalRequests[msg.sender] = WithdrawalRequest({requestId: requestId, receiver: receiver, shares: shares});
        queuedShares += shares;

        emit WithdrawalRequested(msg.sender, requestId, receiver, shares);
    }

    /// @notice Cancel the caller's live request and recover its remaining shares.
    function cancelWithdrawalRequest() external nonReentrant {
        WithdrawalRequest storage request = _withdrawalRequests[msg.sender];
        uint256 requestId = request.requestId;
        if (requestId == 0) revert WithdrawalRequestNotFound(msg.sender);

        address receiver = request.receiver;
        uint256 shares = request.shares;

        queuedShares -= shares;
        delete _withdrawalRequests[msg.sender];

        _transfer(address(this), msg.sender, shares);
        emit WithdrawalRequestCancelled(msg.sender, requestId, receiver, shares);
    }

    /// @notice Approve or revoke an operator for the caller's service decisions.
    /// @dev An operator cannot create or cancel a request, change its receiver, or redirect a claim.
    function setRequestOperator(address operator, bool approved) external returns (bool) {
        if (operator == address(0)) revert ZeroAddress();
        _requestOperators[msg.sender][operator] = approved;
        emit RequestOperatorSet(msg.sender, operator, approved);
        return true;
    }

    function isRequestOperator(address controller, address operator) public view returns (bool) {
        return _requestOperators[controller][operator];
    }

    /// @notice The most requested shares currently funded by this request's pro-rata cash.
    /// @dev The cash slice is calculated independently for each controller. The conversion back to
    ///      shares is deliberately the gross ERC-4626 conversion, while execution pays the live
    ///      exit price through `previewRedeem`.
    function maxRequestRedeem(address controller) public view returns (uint256 shares) {
        uint256 requestedShares = _withdrawalRequests[controller].shares;
        if (requestedShares == 0 || claimLiquidityDeficit() != 0) return 0;

        uint256 requestCash =
            Math.mulDiv(_executablePoolCash(_rawBalance()), requestedShares, totalSupply(), Math.Rounding.Floor);
        uint256 cashFundedShares = convertToShares(requestCash);
        shares = cashFundedShares < requestedShares ? cashFundedShares : requestedShares;

        if (outstandingPrincipal != 0) {
            uint256 supply = totalSupply();
            uint256 burnable = supply > MIN_SUPPLY_FOR_YIELD ? supply - MIN_SUPPLY_FOR_YIELD : 0;
            if (burnable < shares) shares = burnable;
        }
    }

    /// @notice Read a controller's live request and its serviceable amount at current prices.
    function withdrawalRequest(address controller)
        external
        view
        returns (
            uint256 requestId,
            address receiver,
            uint256 shares,
            uint256 serviceableShares,
            uint256 serviceableAssets
        )
    {
        WithdrawalRequest storage request = _withdrawalRequests[controller];
        requestId = request.requestId;
        receiver = request.receiver;
        shares = request.shares;
        serviceableShares = maxRequestRedeem(controller);
        serviceableAssets = previewRedeem(serviceableShares);
    }

    /// @notice Convert exactly `shares` from a controller's request into claimable USDC.
    /// @dev Only the controller or an opted-in operator chooses service timing and size. The
    ///      receiver is fixed by the request, and `minAssetsOut` makes the live price explicit.
    function serviceWithdrawalRequest(address controller, uint256 shares, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (msg.sender != controller && !isRequestOperator(controller, msg.sender)) {
            revert UnauthorizedRequestOperator(controller, msg.sender);
        }
        if (shares == 0) revert ZeroAmount();
        _reconcileCashDeficit();

        WithdrawalRequest storage request = _withdrawalRequests[controller];
        uint256 requestId = request.requestId;
        if (requestId == 0) revert WithdrawalRequestNotFound(controller);

        uint256 maximum = maxRequestRedeem(controller);
        if (shares > maximum) revert ServiceSharesExceedMaximum(shares, maximum);

        assetsOut = previewRedeem(shares);
        if (assetsOut < minAssetsOut) revert AssetsBelowMinimum(assetsOut, minAssetsOut);

        address receiver = request.receiver;
        uint256 requestShares = request.shares;

        uint256 remainingShares = requestShares - shares;
        request.shares = remainingShares;
        queuedShares -= shares;

        _burn(address(this), shares);

        claimable[receiver] += assetsOut;
        totalClaimable += assetsOut;

        if (remainingShares == 0) delete _withdrawalRequests[controller];
        _derecogniseEmptyPoolResidual();

        emit WithdrawalRequestServiced(controller, requestId, receiver, shares, assetsOut);
    }

    /// @notice Collect USDC a serviced withdrawal set aside for the caller.
    function claim() external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender);
    }

    /// @notice Collect a named receiver's set-aside USDC to that fixed receiver.
    /// @dev Permissionless initiation recovers funds for a mute receiver but cannot bypass a token
    ///      block on the receiver. A caller never chooses a different destination.
    function claimFor(address receiver) external nonReentrant returns (uint256 amount) {
        if (receiver == address(0)) revert ZeroAddress();
        return _claim(receiver);
    }

    function _claim(address receiver) private returns (uint256 amount) {
        _reconcileCashDeficit();
        amount = claimable[receiver];
        if (amount == 0) revert NothingToClaim();

        uint256 deficit = claimLiquidityDeficit();
        if (deficit != 0) revert ClaimsUnderfunded(totalClaimable, _effectiveCash());

        claimable[receiver] = 0;
        totalClaimable -= amount;
        _accountedCash -= amount;

        emit WithdrawalClaimed(receiver, amount);
        IERC20(asset()).safeTransfer(receiver, amount);
    }
}
