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

    event LiquiditySourceSet(address indexed source);
    event LenderPoolSet(address indexed lenderPool);
    event EpochHarvesterSet(address indexed epochHarvester);
    event LiquidationAuctionSet(address indexed liquidationAuction);
    event YieldReceived(uint256 amount);
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
    ///         Funded by the harvester in Phase 3; zero until then.
    uint256 public insuranceFund;

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
    function borrow(uint256 amount) external whenNotPaused nonReentrant {
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
    /// @dev No external calls and no reentrancy guard by design: the harvester settles
    ///      200+ positions in one transaction (PRD §6.2), so this has to stay cheap.
    ///      The USDC must already have arrived via `receiveYield`.
    function applyYield(address borrower, uint256 amount) external {
        if (msg.sender != epochHarvester) revert NotEpochHarvester();
        // Dust in a pro-rata split is normal; a no-op beats 200 empty events.
        if (amount == 0) return;
        if (amount > undistributedYield) revert YieldNotDelivered(amount, undistributedYield);
        undistributedYield -= amount;

        uint256 debt = debtOf[borrower];
        uint256 reduced = amount > debt ? debt : amount;
        uint256 overflow = amount - reduced;

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

    /// @inheritdoc ICreditManager
    function claimSurplus() external nonReentrant {
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

        uint256 delivered = balanceBefore - usdc.balanceOf(address(this));
        pendingPrincipal = amount - delivered;
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
    function currentLtvBps(address borrower) external view returns (uint256) {
        return LtvMath.ltvBps(debtOf[borrower], vault.collateralValue(borrower));
    }

    /// @inheritdoc ICreditManager
    /// @dev A view for keepers and the UI. It divides twice, so a position a fraction
    ///      of a bp past the threshold still reports exactly 1e18. Phase 3's
    ///      `liquidate` must compare with `LtvMath.exceedsLtv` rather than read this.
    function healthFactor(address borrower) external view returns (uint256) {
        return LtvMath.healthFactor(debtOf[borrower], vault.collateralValue(borrower));
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Clamps before pulling. Pulling `amount` and crediting `min(amount, debt)`
    ///      would strand the excess here as unbacked balance.
    function _repay(address payer, address borrower, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
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
