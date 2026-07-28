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
/// @dev TODO(phase-3): liquidate.
contract CreditManager is ICreditManager, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotImplemented();
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

    function setLiquidationAuction(address liquidationAuction_) external onlyOwner {
        if (liquidationAuction_ == address(0)) revert ZeroAddress();
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
    function distributeYield(uint256 amount) external {
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
    function receiveYield(uint256 amount) external nonReentrant {
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

    /// @inheritdoc ICreditManager
    function liquidate(address) external nonReentrant {
        revert NotImplemented(); // TODO(phase-3): HF < 1 check, start auction, caller reward
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
