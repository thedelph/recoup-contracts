// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Config} from "./Config.sol";
import {IEpochHarvester} from "./interfaces/IEpochHarvester.sol";
import {ICustodyAdapter} from "./interfaces/ICustodyAdapter.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ICreditManager} from "./interfaces/ICreditManager.sol";
import {ILenderPool} from "./interfaces/ILenderPool.sol";

/// @title EpochHarvester (PRD §4.4)
/// @notice Claims farm USDC weekly and applies the YieldSplit: borrower debt
///         write-down, lender share, insurance fund, protocol fee. Permissionless
///         with a Config.MIN_EPOCH_GAP cooldown so a missing keeper cannot brick it.
///         Zero-yield epochs are a no-op with an event.
/// @dev PRD §6.2 asks for 200+ borrower positions settled in a single transaction.
///      This does better than that: it settles all of them, in one write, because
///      `CreditManager.distributeYield` bumps a yield-per-bond accumulator rather than
///      iterating positions. Each borrower's debt is written down lazily the next time
///      their position is touched, or by anyone calling `CreditManager.settle`.
///
///      That is why `harvestRange` is retained only as an interface obligation and
///      reverts: pagination exists to work around per-position iteration, and there is
///      none to work around. Implementing it would be a second, weaker path into the
///      same accounting.
contract EpochHarvester is IEpochHarvester, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error CreditManagerNotLive(address liveManager);
    /// @notice The incoming custody adapter is bound to a different vault to the one this
    ///         harvester's credit manager settles into.
    error AdapterVaultMismatch(address adapterVault);
    error NotImplemented();
    error EpochGapNotElapsed(uint256 nextAllowedAt);
    error ZeroAddress();
    error RenounceDisabled();
    error NotWired(string what);
    error NothingToFlush();
    error FlushDeliveredNothing();

    event LenderPoolSet(address indexed lenderPool);

    event LenderYieldAccrued(uint256 amount, uint256 totalPending);
    event LenderYieldFlushed(uint256 amount);
    /// @notice A repoint left an outgoing pool's accrued share undelivered, so it was parked
    ///         against that pool rather than carried to the incoming one.
    /// @param totalParked The sum across all pools, which `harvest` nets off `claimed`.
    event LenderYieldParked(address indexed pool, uint256 amount, uint256 totalParked);
    /// @notice A parked share was finally delivered to the pool it belongs to.
    event ParkedLenderYieldFlushed(address indexed pool, uint256 amount);
    event ProtocolFeeAccrued(uint256 indexed epoch, uint256 amount, uint256 totalPending);
    event ProtocolFeeFlushed(address indexed wallet, uint256 amount);
    /// @notice The fee wallet was repointed, so the fee accrued under the outgoing one was
    ///         checkpointed against it rather than following the pointer.
    /// @param totalParked The sum across all wallets, which `harvest` nets off `claimed`.
    event ProtocolFeeParked(address indexed wallet, uint256 amount, uint256 totalParked);
    /// @notice A checkpointed fee was finally delivered to the wallet it belongs to.
    event ParkedProtocolFeeFlushed(address indexed wallet, uint256 amount);
    /// @notice The fee wallet was repointed.
    /// @dev **This event did not exist until audit round 21.** It was the only setter on this
    ///      contract that emitted nothing at all, on the one pointer a third party's revenue
    ///      hangs off, so the repoint that redirected DexFi's accrued leg left no on-chain
    ///      record whatsoever - not even the fact that it had happened.
    event ProtocolFeeWalletSet(address indexed wallet);
    event CreditManagerSet(address indexed creditManager);
    /// @param seededCorroboration The incoming adapter's `farmYieldDelivered` at the swap, which
    ///        becomes the new high-water mark. Emitted rather than left implicit because a wrong
    ///        value here declines every subsequent epoch, and that is worth being able to see.
    event CustodyAdapterSet(address indexed adapter, uint256 seededCorroboration);
    /// @notice An epoch was declined because the farm had not funded it.
    /// @param epoch The epoch this would have been, had it run. Not consumed - `epochCount` is
    ///        untouched, exactly as in the zero-yield case.
    /// @param farmYieldSinceLastEpoch Farm-attributed USDC delivered since the last accepted
    ///        epoch, which fell short of `Config.MIN_EPOCH_FARM_YIELD`.
    /// @param claimed What the balance said the epoch was worth. The gap between these two is the
    ///        donation, and it is not lost - it stays here and joins the next real epoch.
    event EpochDeclinedUncorroborated(uint256 indexed epoch, uint256 farmYieldSinceLastEpoch, uint256 claimed);

    IERC20 public immutable usdc;
    /// @notice The credit manager epochs are delivered into.
    /// @dev **Settable, and it has to be.** It was immutable, which was safe only while
    ///      `receiveYield` accepted a detached manager. Once that gained `whileAttached`,
    ///      any vault-side manager migration made this contract's permissionless
    ///      `harvest` revert `Detached` forever - and `harvest` is the only function that
    ///      moves un-epoched USDC out of here, so a full epoch's yield was trapped with
    ///      no sweep. Every other wiring pointer on this contract is settable for exactly
    ///      this reason; this one was the outlier the new guard happened to depend on.
    ICreditManager public creditManager;
    ICustodyAdapter public custodyAdapter;
    address public lenderPool;
    address public protocolFeeWallet;

    /// @inheritdoc IEpochHarvester
    uint256 public override lastHarvestAt;
    uint256 public epochCount;

    /// @notice Lender share accrued here rather than pushed, so an epoch never depends on the
    ///         pool being able to take delivery. Tracked rather than skipped, so the lender share
    ///         of every epoch before the pool opens is still owed and payable.
    /// @dev This used to say "because `LenderPool.distributeYield` is Phase 4 and reverts until
    ///      then". The pool was built on 2026-08-10 and no longer reverts, but the counter is not
    ///      scaffolding that can now be removed: `distributeYield` still refuses an empty pool
    ///      (`NoSharesOutstanding`), and holding the share is what keeps that refusal from
    ///      destroying it. `flushLenderYield` is the separate, permissionless delivery.
    uint256 public pendingLenderYield;

    /// @notice Lender share that accrued while a given pool was wired and which that pool could
    ///         not take when it was repointed away from. Payable to that pool forever.
    /// @dev **Audit round 11: the repoint used to hand this to the incoming pool.** The
    ///      carry-forward rested on one sentence in `setLenderPool`'s NatSpec - "a pool that cannot
    ///      take delivery has no depositors to be short-changed" - and nothing anywhere enforced
    ///      it. `LenderPool.setEpochHarvester` is `onlyOwner` and unguarded, so an owner could
    ///      point a live pool full of depositors away from this harvester, watch delivery start
    ///      reverting `NotEpochHarvester`, and then repoint here to a pool of their own that would
    ///      collect the first pool's accrued epochs.
    ///
    ///      The obvious fix - refuse the repoint while a share is outstanding - is the deadlock
    ///      `setLenderPool` spends twenty lines explaining, and it is genuinely unfixable in that
    ///      direction: the only function that can clear the counter is the delivery that is
    ///      failing. So the money is **parked per pool** instead of being either carried or
    ///      blocked. The repoint never blocks, and the outgoing pool's share stays claimable by
    ///      that pool, through `flushLenderYieldTo`, for as long as this contract exists. Neither
    ///      half of the deadlock is reachable because there is no condition to satisfy.
    ///
    ///      A mapping cannot be summed, and `harvest` sizes an epoch from this contract's raw USDC
    ///      balance less what is already spoken for - so `totalOwedToPools` exists beside it and
    ///      that subtraction reads it. Without that, a parked share would be counted a second time
    ///      as fresh epoch yield and paid out to borrowers.
    mapping(address => uint256) public owedToPool;

    /// @notice Sum of `owedToPool`. The third category of USDC sitting here that is not this
    ///         epoch's yield, alongside `pendingLenderYield` and `pendingProtocolFee`.
    uint256 public totalOwedToPools;

    /// @notice Protocol fee accrued but not yet collected.
    /// @dev Held for the same reason as the lender share: the fee wallet is a USDC
    ///      recipient like any other, and USDC is blacklistable. Pushing it inside
    ///      `harvest` let one frozen wallet stop every epoch, borrowers included.
    uint256 public pendingProtocolFee;

    /// @notice Protocol fee that accrued while a given wallet was wired, checkpointed there when
    ///         the pointer moved. Payable to that wallet forever.
    /// @dev **Audit round 21: the fee leg was the lender leg's un-fixed twin.** `setLenderPool`
    ///      has parked an outgoing pool's accrued share since round 11 - see `owedToPool` - and
    ///      the reasoning transplants exactly, with one difference that makes it sharper rather
    ///      than weaker. On the lender leg the party being redirected is a pool this protocol
    ///      deploys. Here it is **DexFi**, a commercial counterparty entitled to
    ///      `PROTOCOL_FEE_DEXFI_BPS` of the fee under an agreement whose only on-chain
    ///      enforcement is the immutable `ProtocolFeeSplitter`. That splitter's own NatSpec
    ///      claimed "once deployed neither party can redirect the other's leg"; it binds only
    ///      money already *at* the splitter, and `setProtocolFeeWallet` reached over it.
    ///      MEASURED over three 1,000.000000 epochs: with the splitter installed DexFi is paid
    ///      60.000000, and a repoint-then-flush in a single block paid DexFi **0** and sent
    ///      300.000000 elsewhere. The backlog needs no attacker to build - it is linear in
    ///      epochs, 100.000000 after one and 1,000.000000 after ten, and nothing drains it
    ///      automatically because `flushProtocolFee` is a separate call by design.
    ///
    ///      **The obvious fix - drain to the outgoing wallet before repointing - is wrong here,
    ///      and this is the half the external precedent gets to skip.** MetaMorpho's
    ///      `setFeeRecipient` accrues to the old recipient first, but its `_accrueFee` mints the
    ///      vault's own shares and cannot revert; ours would be a USDC push to an address that
    ///      may be blacklisted, or a contract that reverts - which is precisely why anyone
    ///      rotates a fee wallet. Draining first hands the outgoing recipient a veto over its own
    ///      replacement, and contradicts `flushProtocolFee`'s own stated rationale that a
    ///      recipient which cannot take delivery must never block anything. So the ordering is
    ///      kept and the push is dropped: credit, and let them pull.
    ///
    ///      **The other naive fix, `require(pendingProtocolFee == 0)` on the setter, is worse
    ///      than wrong - it manufactures a different finding from the same round.** `harvest()`
    ///      is permissionless, so anyone could re-block the setter for gas inside the 48-hour
    ///      timelock window and the repoint would never execute. An unconditional checkpoint has
    ///      no precondition for a stranger to flip.
    mapping(address => uint256) public owedProtocolFee;

    /// @notice Sum of `owedProtocolFee`. The fourth category of USDC sitting here that is not
    ///         this epoch's yield, alongside `pendingLenderYield`, `pendingProtocolFee` and
    ///         `totalOwedToPools`.
    /// @dev A mapping cannot be summed, and `harvest` sizes an epoch from this contract's raw
    ///      balance less what is already spoken for. `harvest`'s own comment predicted this
    ///      counter before it existed - "any future balance this contract holds on someone
    ///      else's behalf belongs on this line too" - and leaving it off would have made the
    ///      checkpoint worse than the bug it fixes: the parked fee would read as fresh yield to
    ///      the next epoch, be split four ways, and still be owed.
    uint256 public totalOwedProtocolFee;

    /// @notice The custody adapter's `farmYieldDelivered` as of the last epoch this contract
    ///         accepted. An epoch is corroborated by the *increase* on this mark, never by the
    ///         absolute figure.
    /// @dev A high-water mark rather than a per-epoch reading, because the adapter's counter is
    ///      monotonic and shared with every other path that touches the farm. Money delivered
    ///      while an epoch was declined - or while nobody was calling `harvest` at all - is still
    ///      sitting here, so it must still count towards the next epoch's corroboration. Storing
    ///      the mark and subtracting is what makes that true without a second counter to keep in
    ///      step.
    ///
    ///      Re-seeded on every custody swap. See `setCustodyAdapter`.
    uint256 public lastCorroboratedYield;

    constructor(IERC20 usdc_, ICreditManager creditManager_, address initialOwner) Ownable(initialOwner) {
        if (address(usdc_) == address(0) || address(creditManager_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
        creditManager = creditManager_;
    }

    /// @dev Matches the live-authority contracts: renouncing would permanently
    ///      freeze wiring on a contract the deploy script already deploys.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    /// @notice Point this contract at the custody adapter it claims from.
    /// @dev **The re-seed on the last line is not bookkeeping - it is the whole reason this
    ///      setter needs reading.** `lastCorroboratedYield` is a high-water mark against
    ///      `adapter.farmYieldDelivered()`, which is per-adapter and starts at zero. Carry a mark
    ///      earned under the outgoing adapter across to a fresh one and the subtraction in
    ///      `harvest` saturates to zero on every call, so every epoch is declined as
    ///      uncorroborated - forever, because the only thing that could raise the incoming
    ///      counter past the stale mark is the epochs the stale mark is refusing to run.
    ///
    ///      That is the same mutually-unsatisfiable shape `setLenderPool`'s NatSpec spends twenty
    ///      lines on: the function that could clear the condition was gated on the condition. It
    ///      has now been reached through a reverting pool, through arithmetic in
    ///      `_tryDeliverLenderYield`, and it would have been reached here through a counter that
    ///      resets. The pattern is worth naming: any state this contract carries *about* a wiring
    ///      pointer has to be re-derived when that pointer moves, not preserved across it.
    ///
    ///      The call also doubles as a shape check on the incoming adapter. An address that does
    ///      not answer `farmYieldDelivered()` reverts here, at wiring time and under the owner's
    ///      hand, rather than inside the permissionless `harvest` where a revert freezes every
    ///      borrower's write-down.
    ///
    /// @dev **Audit round 21's census: this was the one adapter pointer in the protocol with no
    ///      binding check at all**, while `CollateralVault.setCustodyAdapter` - the twin, on the
    ///      same interface - has required `adapter.vault() == address(this)` since it was written.
    ///      What the omission bought is an adapter belonging to a different vault, whose
    ///      `farmYieldDelivered` counter has nothing to do with the yield this protocol earned:
    ///      `harvest` sizes the epoch from this contract's own USDC balance but decides whether the
    ///      epoch is *real* from that counter, so a foreign counter either freezes the stream
    ///      permanently at zero or corroborates epochs funded by a donation - which is the exact
    ///      defence round 11 built the counter to be.
    ///
    ///      **Read against the vault this harvester's own manager settles into**, because this
    ///      contract holds no vault pointer of its own and `creditManager` is a constructor
    ///      argument that can never be zero. `setCreditManager` below already requires that manager
    ///      to be the vault's live one, so the reference is the same vault the collateral is in.
    ///
    ///      **What this does not check, stated rather than implied by the count.** It is the weak
    ///      form: same vault, not *the vault's live adapter*. The strong form - `ICollateralVault
    ///      (liveVault).custodyAdapter() == adapter`, the shape `setCreditManager` below uses for
    ///      its own pointer - was considered and rejected on measured ground: it refuses seeding
    ///      this pointer onto an adapter the vault has not moved to yet, and
    ///      `test_setCustodyAdapter_reSeedsTheCorroborationWatermark` does exactly that and would
    ///      go red. It would also add an ordering constraint to a wiring sequence the deploy script
    ///      and the Phase-4 batch both drive.
    ///
    ///      So an operator can still point this at the *previous* adapter after a vault-side
    ///      migration. That residual is a frozen yield stream, recoverable by calling this setter
    ///      again with the right address, and it is left open knowingly.
    function setCustodyAdapter(ICustodyAdapter adapter) external onlyOwner {
        if (address(adapter) == address(0)) revert ZeroAddress();
        address boundVault = adapter.vault();
        address liveVault = address(creditManager.vault());
        if (boundVault != liveVault) revert AdapterVaultMismatch(boundVault);
        custodyAdapter = adapter;
        lastCorroboratedYield = adapter.farmYieldDelivered();
        emit CustodyAdapterSet(address(adapter), lastCorroboratedYield);
    }

    /// @notice Repoint the pool the lender share is paid to.
    /// @dev Pays the outgoing pool what it accrued first, but does NOT let a pool that
    ///      cannot accept block the repoint.
    ///
    ///      An earlier version refused outright while `pendingLenderYield != 0`, on the
    ///      reasoning that the share belongs to the pool that earned it. The reasoning
    ///      is right; the guard was not, because it assumed a flush is always possible.
    ///      When the guard was written `LenderPool.distributeYield` reverted
    ///      `NotImplemented`, so the only function that could clear the counter could
    ///      never succeed, and the only function that could replace the pool read that
    ///      counter. The two were mutually unsatisfiable: every epoch's lender share was
    ///      locked here permanently and Phase 4 could never be wired at all.
    ///
    ///      The pool has had a real body since 2026-08-10, so that particular deadlock is
    ///      gone - but the guard stays removed, because the shape recurs for any pool that
    ///      cannot take delivery: one that no longer recognises this harvester, or one
    ///      whose own transfer is blocked.
    ///
    ///      **What the undeliverable share does instead used to be "follow the pointer", and audit
    ///      round 11 was right that it should not.** The reasoning was that a pool which cannot
    ///      take delivery has no depositors to be short-changed - which nothing enforces and which
    ///      the protocol's own wiring falsifies: `LenderPool.setEpochHarvester` is `onlyOwner` and
    ///      unguarded, so pointing a live pool away from this harvester is exactly how you make
    ///      delivery revert, and the repoint then handed that pool's depositors' accrued epochs to
    ///      a different pool. Nothing about "cannot accept" implies "empty".
    ///
    ///      So the share is **parked against the outgoing pool** - see `owedToPool` - and stays
    ///      claimable by it forever through the permissionless `flushLenderYieldTo`. That keeps
    ///      both properties at once, which no guard here could: the repoint can never block, and
    ///      the money can never be redirected. Note what is *not* parked - a pool that took
    ///      delivery leaves nothing behind, so the ordinary migration is unchanged.
    /// @dev `nonReentrant` because it reaches `_tryDeliverLenderYield`, which makes an
    ///      external call to the outgoing pool. Without it that pool could re-enter
    ///      `harvest` and move the counter the helper is mid-way through writing - and now also
    ///      the counter the park below reads.
    function setLenderPool(address lenderPool_) external onlyOwner nonReentrant {
        if (lenderPool_ == address(0)) revert ZeroAddress();
        address outgoing = lenderPool;
        if (outgoing != address(0) && outgoing != lenderPool_) {
            _tryDeliverLenderYield(outgoing);

            // Read after the delivery attempt, not before: the helper has already decremented by
            // whatever actually left, so what is left standing is precisely the part the outgoing
            // pool could not take. Everything still counted here accrued while `outgoing` was the
            // wired pool - anything owed to a pool before that was parked by its own repoint - so
            // the whole residue belongs to `outgoing` and none of it to the incoming pool.
            uint256 undelivered = pendingLenderYield;
            if (undelivered != 0) {
                pendingLenderYield = 0;
                owedToPool[outgoing] += undelivered;
                totalOwedToPools += undelivered;
                emit LenderYieldParked(outgoing, undelivered, totalOwedToPools);
            }
        }
        lenderPool = lenderPool_;
        emit LenderPoolSet(lenderPool_);
    }

    /// @notice Repoint at a new credit manager after a vault-side migration.
    /// @dev Guarded the way its siblings are: the incoming manager must be the one the
    ///      vault actually points at, so this cannot be set to a manager whose
    ///      `receiveYield` would immediately revert `Detached` - which is the state this
    ///      setter exists to escape, and would otherwise be trivially re-enterable.
    function setCreditManager(ICreditManager creditManager_) external onlyOwner {
        if (address(creditManager_) == address(0)) revert ZeroAddress();
        address boundVault = address(creditManager_.vault());
        address liveManager = ICollateralVault(boundVault).creditManager();
        if (liveManager != address(creditManager_)) revert CreditManagerNotLive(liveManager);
        creditManager = creditManager_;
        emit CreditManagerSet(address(creditManager_));
    }

    /// @notice Repoint the wallet the protocol fee is paid to.
    /// @dev **Checkpoints the accrued backlog against the outgoing wallet first, and does not
    ///      try to pay it.** The full argument, the measurement and both rejected alternatives
    ///      are on `owedProtocolFee`; the short version is that this setter used to hand a
    ///      third party's accrued revenue to whoever the owner named next, and that the two
    ///      obvious guards - drain first, or refuse while a backlog stands - would each have
    ///      recreated a deadlock this contract has already been bitten by twice.
    ///
    ///      Note what is deliberately *not* copied from `setLenderPool`. That sibling calls
    ///      `_tryDeliverLenderYield(outgoing)` before reading the residue, because its delivery
    ///      is an approve-and-call a pool may take partially, so "what is left standing" is the
    ///      only honest measure of what could not be delivered. Here delivery is a plain
    ///      `safeTransfer` that either moves everything or reverts, so there is no partial case
    ///      to measure - and attempting it inside a `try` would need a low-level call whose only
    ///      effect would be to sometimes pay a wallet that `flushProtocolFee` already lets
    ///      anybody pay, permissionlessly, in the block before this one. Fewer moving parts, no
    ///      external call, and therefore no `nonReentrant` needed either.
    ///
    ///      **No precondition, deliberately.** The only branch below decides whether a park
    ///      *happened*, not whether the repoint is allowed: the pointer moves on every call, in
    ///      every state, and there is nothing here a stranger can flip to make it revert.
    ///      Repointing a wallet to itself is a no-op that still emits. And the park is not a
    ///      state anyone can be stuck in - `flushProtocolFeeTo` is permissionless and takes its
    ///      destination from the mapping key, so the checkpoint can always be discharged by
    ///      whoever wants it discharged.
    function setProtocolFeeWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();

        address outgoing = protocolFeeWallet;
        uint256 backlog = pendingProtocolFee;
        if (outgoing != address(0) && outgoing != wallet && backlog != 0) {
            pendingProtocolFee = 0;
            owedProtocolFee[outgoing] += backlog;
            totalOwedProtocolFee += backlog;
            emit ProtocolFeeParked(outgoing, backlog, totalOwedProtocolFee);
        }

        protocolFeeWallet = wallet;
        emit ProtocolFeeWalletSet(wallet);
    }

    // ── IEpochHarvester ──────────────────────────────────────────────────────

    /// @inheritdoc IEpochHarvester
    /// @dev Permissionless by design (PRD §4.4): a keeper that stops running must not
    ///      be able to stop yield reaching borrowers. The cooldown is the only gate.
    function harvest() external nonReentrant {
        ICustodyAdapter adapter = custodyAdapter;
        if (address(adapter) == address(0)) revert NotWired("custodyAdapter");
        if (protocolFeeWallet == address(0)) revert NotWired("protocolFeeWallet");

        uint256 nextAllowed = lastHarvestAt + Config.MIN_EPOCH_GAP;
        // slither-disable-next-line timestamp
        if (lastHarvestAt != 0 && block.timestamp < nextAllowed) {
            revert EpochGapNotElapsed(nextAllowed);
        }

        // Size the epoch from this contract's own balance, not from what `claimYield`
        // reports. The adapter sweeps farm USDC here on several paths that are not
        // this one - `withdrawBonds` and `seize` both unstake, and `harvestYield` can
        // be called directly - so by the time an epoch runs there is usually USDC
        // sitting here that the claim call knows nothing about. Trusting the return
        // value leaves that money stranded with no counter claiming it and no path to
        // reach borrowers. `pendingLenderYield` is the one balance already spoken for.
        //
        // Best-effort for the same reason it is balance-sized: the claim is an
        // optimisation, not a precondition. DexFi's farm sits behind a proxy their
        // EOA can upgrade, so a revert in `withdraw(0)` is a live possibility - and
        // letting it propagate would freeze USDC that is already sitting here and
        // needs no farm call at all.
        //
        // The return value is kept, not discarded. It cannot *size* the epoch - the paragraph
        // above is why - and since audit round 11 it is no longer what decides whether the epoch
        // is real either; the adapter's `farmYieldDelivered` counter does that, and it sees every
        // farm-touching path rather than this one call. What is left to `corroborated` is the
        // narrower claim that the farm paid out *inside this very call*, which is all the cooldown
        // clock below needs.
        uint256 corroborated;
        try adapter.claimYield() returns (uint256 c) {
            corroborated = c;
        } catch {}
        // All three carried balances come off the top. They are this contract's USDC but not this
        // epoch's yield, and counting any of them as `claimed` would pay it out a second time -
        // the lender share to borrowers, or the protocol fee to everyone.
        //
        // **`totalOwedToPools` is the third one and it is the easy one to miss.** It was added
        // when the repoint stopped carrying an undeliverable share to the incoming pool and
        // started parking it against the pool that earned it; the money does not move at the park,
        // so it is still sitting in this balance. Left out of this line it reads as fresh yield to
        // every subsequent epoch, gets split four ways, and is then still owed to the pool it was
        // parked for - so the second payment comes out of somebody else's epoch. Any future
        // balance this contract holds on someone else's behalf belongs on this line too.
        //
        // **`totalOwedProtocolFee` is that future balance, and it arrived in audit round 21.**
        // The fee leg gained the same per-wallet checkpoint the lender leg has had since round
        // 11, which moves value out of `pendingProtocolFee` and therefore out of this
        // subtraction. Without this term the fix would have been a downgrade: a checkpointed
        // backlog would read as fresh yield to the very next epoch, get split four ways, and
        // still be owed to the wallet it was parked for.
        uint256 claimed = usdc.balanceOf(address(this)) - pendingLenderYield - pendingProtocolFee
            - totalOwedToPools - totalOwedProtocolFee;

        // Split per PRD §4.4, computed before the cooldown decision because the
        // borrower share is what decides whether this epoch did anything.
        uint256 toBorrowers = (claimed * Config.SPLIT_BORROWER_BPS) / Config.BPS;

        // A dust threshold, not a zero check. `claimed` is sized from this contract's
        // USDC balance with no attribution - it has to be, because yield reaches here
        // through unmeasured side paths - so anyone can raise it by transferring a
        // couple of units.
        //
        // This branch only answers whether the epoch is worth *running*. It is not, and never
        // was, a defence against a donation: a floor denominated in absolute dollars cannot price
        // a right whose value scales with the pot behind it, and round 10 measured the price at
        // $1.82. Who funded the epoch is the separate question asked immediately below, against a
        // quantity a donation cannot move. Two questions, two floors - see
        // `Config.MIN_EPOCH_FARM_YIELD` for why they are not the same constant even at the same
        // value.
        if (toBorrowers < Config.MIN_EPOCH_YIELD) {
            // Deliberately does NOT advance `lastHarvestAt`. An epoch that distributed
            // nothing should not consume the cooldown - a transient zero (DexFi
            // pausing rewards for an hour, a claim landing a block early) would
            // otherwise lock the real yield away for another five days. The cooldown
            // is there to bound how often the stream is re-rated, and nothing was
            // re-rated here. The cost is that a zero epoch can be re-attempted at
            // will, which is gas-bounded and harmless.
            emit ZeroYieldEpoch(epochCount + 1);
            return;
        }

        // ── Did the farm fund this epoch, or did a stranger? ─────────────────────
        //
        // **Audit round 11, and the reason this is an early return rather than a guard on the
        // `distributeYield` call further down.** Round 10 priced a donated epoch at 1,818,182
        // units - about $1.82 - and gated `lastHarvestAt` on `corroborated` so the donation could
        // not burn five days of cooldown. It guarded one clock and left the other open. `harvest`
        // fell straight through to `creditManager.distributeYield`, which writes
        // `lastDistributeAt`, and that is the sole record of how long the money took to earn. So
        // the same $1.82 still bought a write to the anti-just-in-time window's only input - and
        // because `lastHarvestAt` was deliberately *not* advanced, the pin was repeatable every
        // block rather than once per cooldown.
        //
        // What that was worth, measured in `test/EpochHarvester.t.sol`: eleven donations of $1.82,
        // spaced one `Config.YIELD_STREAM_DURATION` apart across a sixty-day farm outage, turned a
        // just-in-time round trip worth $495 into one worth $5,940, and left a holder staked for
        // all sixty days with $671 of a $6,600 epoch instead of the whole of it. Note the
        // mechanism, because it is not the obvious one: no running stream is ever shortened -
        // `duration >= remaining` makes `streamEndsAt` monotonically non-decreasing - the pins
        // simply stop a long accrual window from ever *forming*, which costs the attacker nothing.
        //
        // The obvious fix is to gate `distributeYield` on `corroborated`, and it is wrong. That
        // boolean is not a donation detector; it asks "did the farm accrue since anything last
        // touched it", and `depositBonds`/`withdrawBonds` both settle the farm through the
        // adapter. A wholly legitimate epoch therefore reads as uncorroborated whenever a bond
        // moved in the same block, and gating on it strands that epoch's borrower share for up to
        // `MIN_EPOCH_GAP`. It was tried, it broke three existing tests for exactly that reason,
        // and it was reverted: delaying money owed to borrowers in order to close a timing attack
        // needs a sharper signal than a boolean.
        //
        // The sharper signal was already being computed on every farm-touching path and thrown
        // away. `farmYieldDelivered` counts USDC the adapter *measured the farm pay* and forwarded
        // on; it moves on a claim, a stake, an unstake or a mint alike, and a donation cannot move
        // it at all. Rating this epoch against the increase since the last accepted one asks the
        // right question and answers it for every path, so no legitimate epoch is delayed by a
        // second.
        //
        // Declining returns without touching a single piece of state - not `lastHarvestAt`, not
        // `epochCount`, not `lastDistributeAt`, not a cent. That is the point of the shape: the
        // donated USDC stays in this contract's balance and is counted into `claimed` by the next
        // real epoch, so the griefer's money ends up paying borrowers and nothing is stranded.
        uint256 delivered = adapter.farmYieldDelivered();
        // Saturating, not a bare subtraction. The mark is re-seeded on every custody swap, so it
        // can only sit at or below the live adapter's counter and this can only underflow if an
        // adapter breaks its own monotonicity promise. But an underflow here would revert the one
        // permissionless function that moves un-epoched USDC out of this contract, and this
        // codebase has already had two deadlocks of precisely that shape - `setLenderPool`'s
        // refusal and `_tryDeliverLenderYield`'s subtraction. Declining an epoch is recoverable;
        // reverting on an assumption about an external contract is not.
        uint256 fromFarm = delivered > lastCorroboratedYield ? delivered - lastCorroboratedYield : 0;
        if (fromFarm < Config.MIN_EPOCH_FARM_YIELD) {
            emit EpochDeclinedUncorroborated(epochCount + 1, fromFarm, claimed);
            return;
        }
        lastCorroboratedYield = delivered;

        // The cooldown clock, still keyed on `corroborated` rather than on the floor just above,
        // and that is the conservative choice rather than an oversight. `corroborated != 0` means
        // the farm paid out inside this call. An epoch corroborated the other way - a
        // `withdrawBonds` that swept an outage's worth of yield in here while the farm's claim
        // path was down - has no reason to be rate limited: the pot is real and the window it is
        // rated over is the one it genuinely accrued in. Advancing the clock for those too would
        // delay the next honest epoch by up to `MIN_EPOCH_GAP` and buy nothing, because the floor
        // above already means a second epoch cannot run until the farm has delivered another
        // `MIN_EPOCH_FARM_YIELD` - a rate limit no donation can pay for. Round 10 needed this line
        // to be the entire defence; it no longer is.
        if (corroborated != 0) lastHarvestAt = block.timestamp;
        uint256 epoch = ++epochCount;

        // The protocol fee takes the rounding remainder so the parts always sum to
        // exactly `claimed` and no dust is stranded here.
        uint256 toLenders = (claimed * Config.SPLIT_LENDER_BPS) / Config.BPS;
        uint256 toInsurance = (claimed * Config.SPLIT_INSURANCE_BPS) / Config.BPS;
        uint256 toProtocol = claimed - toBorrowers - toLenders - toInsurance;

        // Non-zero by the branch above, so no guard needed on the approval.
        usdc.forceApprove(address(creditManager), toBorrowers);
        creditManager.receiveYield(toBorrowers);
        // Unconditional, and correctly so now. This line writes `lastDistributeAt`, and round 11
        // recorded it as the open finding; the corroboration floor above is the fix. It works by
        // declining the whole epoch rather than by running a half-epoch that pays borrowers and
        // skips the write - which is what the one-line `if (corroborated != 0)` here would do, and
        // a borrower share delivered into `undistributedYield` with nothing rating it is money
        // stranded, not money protected. Anything reaching this line has been funded by the farm.
        creditManager.distributeYield(toBorrowers);

        if (toInsurance != 0) {
            usdc.forceApprove(address(creditManager), toInsurance);
            creditManager.fundInsurance(toInsurance);
        }
        if (toLenders != 0) {
            pendingLenderYield += toLenders;
            emit LenderYieldAccrued(toLenders, pendingLenderYield);
        }
        // Accrued, not pushed. This was the one hard outbound transfer left in the yield
        // path, and every sibling leg is best-effort for a reason it states out loud:
        // `_trySweepUsdc` uses a low-level call, `_tryDeliverLenderYield` and
        // `_socialise` catch. A Circle blacklist on the fee wallet reverted the whole
        // permissionless `harvest()`, freezing the borrower, lender and insurance shares
        // alongside the protocol's own - the exact failure this contract's header claims
        // it cannot have. The protocol's fee is the last thing that should be able to
        // stop borrowers' debt being written down.
        if (toProtocol != 0) {
            pendingProtocolFee += toProtocol;
            emit ProtocolFeeAccrued(epoch, toProtocol, pendingProtocolFee);
        }

        emit Harvested(epoch, claimed, toBorrowers, toLenders, toInsurance, toProtocol);
    }

    /// @notice Deliver the accumulated lender share once the pool can accept it.
    /// @dev Permissionless: it only moves money to the pool it was always owed to.
    ///      Separate from `harvest` so a Phase-4 pool that is not ready, or reverts,
    ///      cannot block borrowers from receiving their share of an epoch.
    function flushLenderYield() external nonReentrant {
        address pool = lenderPool;
        if (pool == address(0)) revert NotWired("lenderPool");
        if (pendingLenderYield == 0) revert NothingToFlush();

        // A caller who asked for a flush wants to know it did not happen, so this
        // path surfaces the failure. `setLenderPool` uses the same helper and
        // deliberately ignores the result.
        if (_tryDeliverLenderYield(pool) == 0) revert FlushDeliveredNothing();
    }

    /// @notice Deliver a share parked for a pool this harvester no longer points at.
    /// @dev Permissionless and takes the pool as an argument, which is the pair of properties
    ///      that make the park safe. `owedToPool` is keyed by the pool that earned the share, so
    ///      this can only ever move money to that address - there is no destination to choose and
    ///      therefore nothing for an owner to redirect. And because anyone may call it, a pool
    ///      that becomes able to take delivery again does not need this contract's owner to
    ///      cooperate in being paid.
    ///
    ///      Deliberately separate from `flushLenderYield` rather than folded into it. That
    ///      function pays the *currently wired* pool out of the live counter; conflating the two
    ///      would mean a caller asking for a flush could not tell which of the two payments they
    ///      got, and would put a stranger's balance inside the path the epoch clock uses.
    ///
    ///      Reverts loudly on a no-op for the same reason its sibling does: a caller who asked for
    ///      a delivery wants to know it did not land.
    function flushLenderYieldTo(address pool) external nonReentrant {
        if (pool == address(0)) revert ZeroAddress();
        if (owedToPool[pool] == 0) revert NothingToFlush();

        if (_tryDeliverParkedYield(pool) == 0) revert FlushDeliveredNothing();
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Hands the currently wired pool the live lender share, tolerating a pool that cannot
    ///      take delivery. The counter is written back from what actually left, so a partial pull
    ///      stays owed - see `_push` for why delivery is measured rather than assumed.
    /// @return delivered USDC that actually left this contract.
    function _tryDeliverLenderYield(address pool) private returns (uint256 delivered) {
        uint256 amount = pendingLenderYield;
        if (amount == 0) return 0;

        delivered = _push(pool, amount);
        // Decrement, do not assign. `amount` is a snapshot taken before an external call, so a
        // pool that called back in and moved this counter would have that increment erased by an
        // assignment. `CreditManager.settlePrincipal` documents the identical hazard and avoids it
        // the same way; this was the one place in the codebase that still assigned.
        //
        // The clause that used to be here - "`setLenderPool` reaches this helper without
        // `nonReentrant`" - has been false since that guard was added, and is removed rather than
        // kept as a scarier-sounding reason. The discipline stands on its own: both callers are
        // guarded *today*, and a snapshot taken across an external call must not be written back
        // wholesale regardless of who is guarding the door this week.
        pendingLenderYield -= delivered;
        if (delivered != 0) emit LenderYieldFlushed(delivered);
    }

    /// @dev The same delivery, against the share parked for a pool this harvester has since been
    ///      pointed away from. Both counters are decremented by what actually left, for the reason
    ///      the sibling above states.
    /// @return delivered USDC that actually left this contract.
    function _tryDeliverParkedYield(address pool) private returns (uint256 delivered) {
        uint256 amount = owedToPool[pool];
        if (amount == 0) return 0;

        delivered = _push(pool, amount);
        owedToPool[pool] -= delivered;
        totalOwedToPools -= delivered;
        if (delivered != 0) emit ParkedLenderYieldFlushed(pool, delivered);
    }

    /// @dev Offer `amount` to `pool` and report what it actually took. Extracted so the live
    ///      counter and the parked one cannot drift in how they deliver: every hazard below was
    ///      paid for once already and a second copy would be a second chance to get one wrong.
    ///      It writes no counter itself - the caller owns that, because the two hold their balance
    ///      in different places.
    /// @return delivered USDC that actually left this contract.
    function _push(address pool, uint256 amount) private returns (uint256 delivered) {
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.forceApprove(pool, amount);
        // A pool that reverts must not be able to trap the share - see setLenderPool.
        try ILenderPool(pool).distributeYield(amount) {} catch {}
        usdc.forceApprove(pool, 0); // leave no standing allowance

        // Delivery is measured rather than assumed: a pool that pulls short would otherwise have
        // the difference silently forgiven, leaving USDC here that no counter claims.
        //
        // Clamped, not just subtracted. The call above is wrapped so a hostile pool
        // cannot revert the repoint - but this line sits outside the try/catch, so a
        // pool that *pushes* USDC back during `distributeYield` made the subtraction
        // underflow and reverted the repoint anyway, along with the permissionless
        // flush. That is the same mutually-unsatisfiable deadlock `setLenderPool`'s
        // NatSpec says was already fixed once, reachable through arithmetic instead.
        uint256 balanceAfter = usdc.balanceOf(address(this));
        delivered = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
    }

    /// @notice Deliver the accumulated protocol fee once the wallet can receive it.
    /// @dev Permissionless and separate from `harvest` for the same reason
    ///      `flushLenderYield` is: a recipient that cannot take delivery must never be
    ///      able to stop an epoch. Reverts loudly, because a caller who explicitly asked
    ///      for a flush wants to know it failed.
    function flushProtocolFee() external nonReentrant {
        address wallet = protocolFeeWallet;
        if (wallet == address(0)) revert NotWired("protocolFeeWallet");
        uint256 amount = pendingProtocolFee;
        if (amount == 0) revert NothingToFlush();

        pendingProtocolFee = 0;
        emit ProtocolFeeFlushed(wallet, amount);
        usdc.safeTransfer(wallet, amount);
    }

    /// @notice Deliver a fee checkpointed for a wallet this harvester no longer points at.
    /// @dev Permissionless, and takes the wallet as an argument - the pair of properties that
    ///      make the checkpoint safe, exactly as they do for `flushLenderYieldTo`.
    ///      `owedProtocolFee` is keyed by the wallet that earned the fee, so this can only ever
    ///      move money to that address: there is no destination to choose and therefore nothing
    ///      for an owner to redirect. And because anybody may call it, DexFi's leg does not
    ///      depend on Recoup's owner cooperating in paying it - which is the entire point, since
    ///      Recoup's owner is the party the redirect would have benefited.
    ///
    ///      Deliberately separate from `flushProtocolFee` rather than folded into it, for the
    ///      reason its lender-leg twin gives: that function pays the *currently wired* wallet out
    ///      of the live counter, and conflating the two would put a stranger's balance inside the
    ///      path the live fee uses. Reverts loudly on a no-op, because a caller who asked for a
    ///      delivery wants to know it did not land.
    ///
    ///      A plain `safeTransfer` like its sibling, not the measured approve-and-call the lender
    ///      legs use. Nothing here is pulled, so there is no short-delivery case to measure; a
    ///      transfer that fails reverts and takes the counters with it, which is the correct
    ///      outcome for a caller who asked for exactly this payment.
    function flushProtocolFeeTo(address wallet) external nonReentrant {
        if (wallet == address(0)) revert ZeroAddress();
        uint256 amount = owedProtocolFee[wallet];
        if (amount == 0) revert NothingToFlush();

        owedProtocolFee[wallet] = 0;
        totalOwedProtocolFee -= amount;
        emit ParkedProtocolFeeFlushed(wallet, amount);
        usdc.safeTransfer(wallet, amount);
    }

    /// @inheritdoc IEpochHarvester
    /// @dev Intentionally never implemented. Pagination exists to survive iterating
    ///      positions, and `distributeYield` does not iterate - one write covers every
    ///      position regardless of count. Kept only to satisfy the interface; adding a
    ///      body would create a second, weaker route into the same accounting.
    function harvestRange(uint256, uint256) external pure {
        revert NotImplemented();
    }
}
