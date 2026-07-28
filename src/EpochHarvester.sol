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
    event ProtocolFeeAccrued(uint256 indexed epoch, uint256 amount, uint256 totalPending);
    event ProtocolFeeFlushed(address indexed wallet, uint256 amount);
    event CreditManagerSet(address indexed creditManager);

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

    /// @notice Lender share held here because `LenderPool.distributeYield` is Phase 4
    ///         and reverts until then. Tracked rather than skipped, so the lender share
    ///         of every epoch before the pool opens is still owed and payable.
    uint256 public pendingLenderYield;

    /// @notice Protocol fee accrued but not yet collected.
    /// @dev Held for the same reason as the lender share: the fee wallet is a USDC
    ///      recipient like any other, and USDC is blacklistable. Pushing it inside
    ///      `harvest` let one frozen wallet stop every epoch, borrowers included.
    uint256 public pendingProtocolFee;

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

    function setCustodyAdapter(ICustodyAdapter adapter) external onlyOwner {
        if (address(adapter) == address(0)) revert ZeroAddress();
        custodyAdapter = adapter;
    }

    /// @notice Repoint the pool the lender share is paid to.
    /// @dev Pays the outgoing pool what it accrued first, but does NOT let a pool that
    ///      cannot accept block the repoint.
    ///
    ///      An earlier version refused outright while `pendingLenderYield != 0`, on the
    ///      reasoning that the share belongs to the pool that earned it. The reasoning
    ///      is right; the guard was not, because it assumed a flush is always possible.
    ///      `LenderPool.distributeYield` reverts `NotImplemented` until Phase 4 and the
    ///      deploy script wires exactly that pool - so the only function that could
    ///      clear the counter could never succeed, and the only function that could
    ///      replace the pool read that counter. The two were mutually unsatisfiable:
    ///      every epoch's lender share was locked here permanently and Phase 4 could
    ///      never be wired at all.
    ///
    ///      Carrying the share forward to the incoming pool is the right answer in the
    ///      case that actually arises: a pool that cannot take delivery has no
    ///      depositors to be short-changed.
    /// @dev `nonReentrant` because it reaches `_tryDeliverLenderYield`, which makes an
    ///      external call to the outgoing pool. Without it that pool could re-enter
    ///      `harvest` and move the counter the helper is mid-way through writing.
    function setLenderPool(address lenderPool_) external onlyOwner nonReentrant {
        if (lenderPool_ == address(0)) revert ZeroAddress();
        address outgoing = lenderPool;
        if (outgoing != address(0) && outgoing != lenderPool_) {
            _tryDeliverLenderYield(outgoing);
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

    function setProtocolFeeWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        protocolFeeWallet = wallet;
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
        try adapter.claimYield() returns (uint256) {} catch {}
        // Both carried balances come off the top. They are this contract's USDC but not
        // this epoch's yield, and counting either as `claimed` would pay it out a second
        // time - the lender share to borrowers, or the protocol fee to everyone.
        uint256 claimed = usdc.balanceOf(address(this)) - pendingLenderYield - pendingProtocolFee;

        // Split per PRD §4.4, computed before the cooldown decision because the
        // borrower share is what decides whether this epoch did anything.
        uint256 toBorrowers = (claimed * Config.SPLIT_BORROWER_BPS) / Config.BPS;

        // A dust threshold, not a zero check. `claimed` is sized from this contract's
        // USDC balance with no attribution - it has to be, because yield reaches here
        // through unmeasured side paths - so anyone can advance an epoch by transferring
        // a couple of units. That is not merely a wasted cooldown: advancing the epoch
        // resets `CreditManager.lastDistributeAt`, which is the input the stream's
        // anti-just-in-time window is derived from. Pinning it cheaply is what turns
        // the stream-compression bug from theoretical into a funded attack.
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

        lastHarvestAt = block.timestamp;
        uint256 epoch = ++epochCount;

        // The protocol fee takes the rounding remainder so the parts always sum to
        // exactly `claimed` and no dust is stranded here.
        uint256 toLenders = (claimed * Config.SPLIT_LENDER_BPS) / Config.BPS;
        uint256 toInsurance = (claimed * Config.SPLIT_INSURANCE_BPS) / Config.BPS;
        uint256 toProtocol = claimed - toBorrowers - toLenders - toInsurance;

        // Non-zero by the branch above, so no guard needed here.
        usdc.forceApprove(address(creditManager), toBorrowers);
        creditManager.receiveYield(toBorrowers);
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

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Hands a pool the lender share it accrued, tolerating a pool that cannot
    ///      take delivery.
    ///
    ///      Delivery is measured rather than assumed: a pool that pulls short would
    ///      otherwise have the difference silently forgiven, leaving USDC here that no
    ///      counter claims. The counter is written back from what actually left, so a
    ///      partial pull stays owed.
    /// @return delivered USDC that actually left this contract.
    function _tryDeliverLenderYield(address pool) private returns (uint256 delivered) {
        uint256 amount = pendingLenderYield;
        if (amount == 0) return 0;

        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.forceApprove(pool, amount);
        // A pool that reverts must not be able to trap the share - see setLenderPool.
        try ILenderPool(pool).distributeYield(amount) {} catch {}
        usdc.forceApprove(pool, 0); // leave no standing allowance

        // Clamped, not just subtracted. The call above is wrapped so a hostile pool
        // cannot revert the repoint - but this line sits outside the try/catch, so a
        // pool that *pushes* USDC back during `distributeYield` made the subtraction
        // underflow and reverted the repoint anyway, along with the permissionless
        // flush. That is the same mutually-unsatisfiable deadlock `setLenderPool`'s
        // NatSpec says was already fixed once, reachable through arithmetic instead.
        uint256 balanceAfter = usdc.balanceOf(address(this));
        delivered = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        // Decrement, do not assign. `amount` is a snapshot taken before an external
        // call, and `setLenderPool` reaches this helper without `nonReentrant`, so a
        // pool that calls back into `harvest` increments this counter mid-flight - an
        // assignment would erase that increment. `CreditManager.settlePrincipal`
        // documents the identical hazard and avoids it the same way; this was the one
        // place in the codebase that still assigned.
        pendingLenderYield -= delivered;
        if (delivered != 0) emit LenderYieldFlushed(delivered);
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

    /// @inheritdoc IEpochHarvester
    /// @dev Intentionally never implemented. Pagination exists to survive iterating
    ///      positions, and `distributeYield` does not iterate - one write covers every
    ///      position regardless of count. Kept only to satisfy the interface; adding a
    ///      body would create a second, weaker route into the same accounting.
    function harvestRange(uint256, uint256) external pure {
        revert NotImplemented();
    }
}
