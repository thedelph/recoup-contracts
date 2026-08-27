// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ICollateralVault} from "./ICollateralVault.sol";
import {INAVOracle} from "./INAVOracle.sol";
import {IRiskParams} from "./IRiskParams.sol";

/// @title ICreditManager
/// @notice Debt accounting: borrow, optional manual repay, yield-driven write-down,
///         liquidation trigger (PRD §4.3). No borrow interest in v1.
interface ICreditManager {
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount);
    event YieldApplied(address indexed borrower, uint256 debtReduced, uint256 overflowToClaimable);
    /// @param callerReward What the caller earns *if* the lot sells for more than the
    ///        debt. Not paid at trigger time: the penalty is taken from surplus, and
    ///        an auction that fills below the debt has none. An entitlement ceiling.
    event LiquidationTriggered(address indexed borrower, address indexed caller, uint256 callerReward);
    event SurplusClaimed(address indexed borrower, uint256 amount);

    /// @notice Borrow USDC against collateral. Reverts if post-borrow LTV > maxLTV,
    ///         NAV is stale, or a borrow cap is hit.
    function borrow(uint256 amount) external;

    /// @notice Optional manual repayment, always allowed.
    function repay(uint256 amount) external;

    /// @notice Repay on someone else's behalf; clamps at their outstanding debt.
    /// @dev Needed for rescue (a borrower who has lost keys or been blacklisted) and
    ///      by the auction, which pays a liquidated position's debt out of the sale.
    function repayFor(address borrower, uint256 amount) external;

    /// @notice Deliver an epoch's borrower share before distributing it, so the
    ///         accumulator can only ever promise USDC that has actually arrived.
    ///         EpochHarvester only; pulls against an allowance.
    function receiveYield(uint256 amount) external;

    /// @notice Add USDC to the insurance fund, which absorbs auction shortfalls before
    ///         any loss reaches lenders. Permissionless; pulls against an allowance.
    function fundInsurance(uint256 amount) external;

    /// @notice Top your own position's prepaid liquidation bounty back up to the full charge,
    ///         so somebody is paid for liquidating it. Pulls against an allowance. Exists
    ///         because arming a position through `borrow` is not always reachable - see the
    ///         implementation. **`msg.sender` must be `borrower`**, and the position must
    ///         carry debt.
    function fundBounty(address borrower, uint256 amount) external;

    /// @notice Spread an epoch's borrower share across every bond, in one write.
    ///         EpochHarvester only, and the USDC must already have been delivered.
    /// @dev Positions are not iterated. Each one works out its own share lazily from
    ///      the difference between the running yield-per-bond and its own recorded
    ///      index, which is what lets PRD §6.2's 200+ positions settle in one call.
    function distributeYield(uint256 amount) external;

    /// @notice Apply a position's accrued yield: debt first, remainder to claimable.
    ///         Permissionless - it can only help the position it settles.
    function settle(address borrower) external;

    /// @notice Settle before the vault changes a bond count. Vault only.
    /// @param currentBonds The balance BEFORE the change, since that is what earned.
    function settleForVault(address borrower, uint256 currentBonds) external;

    /// @return Yield this position has earned but not yet settled.
    function pendingYieldOf(address borrower) external view returns (uint256);

    /// @return Yield already settled out of a position and waiting to be collected.
    /// @dev The other half of `pendingYieldOf`: the two together are everything this manager
    ///      still owes an account, and neither alone is. Exposed for audit round 22, finding 18,
    ///      where `LiquidationAuction.closeWorkout` has to bound what it books against money that
    ///      actually exists, and a settled-but-uncollected balance is money that exists.
    function claimableOf(address account) external view returns (uint256);

    /// @return Debt net of unsettled yield - what the borrower actually owes.
    ///         `debtOf` is the stored figure and can be stale between settlements.
    function currentDebtOf(address borrower) external view returns (uint256);

    /// @notice Claim yield accrued beyond debt (and post-liquidation surplus).
    function claimSurplus() external;

    /// @notice Collect a named account's surplus, paid to that account. Permissionless, and
    ///         the destination is not chooseable. Exists because `claimSurplus` strands any
    ///         claimant that is a contract behind a moving pointer - see the implementation.
    function claimSurplusFor(address account) external;

    /// @notice Start a Dutch auction for an unhealthy position. Callable by anyone
    ///         once the position is past the liquidation threshold; the caller earns a
    ///         share of the penalty if the lot sells for more than the debt.
    function liquidate(address borrower) external;

    /// @notice Book a liquidation's insurance cut and the borrower's surplus.
    ///         LiquidationAuction only.
    function creditLiquidationProceeds(address borrower, uint256 toInsurance, uint256 toBorrower) external;

    /// @notice Recognise unrecoverable debt: insurance first, then socialised to
    ///         lenders. LiquidationAuction only.
    /// @return socialised The part the insurance fund did **not** make the liquidity source whole
    ///         for, and therefore the exact amount a later recovery may still repay without paying
    ///         the same tranche twice. `LiquidationAuction.closeWorkout` keeps it.
    function writeDownLoss(address borrower, uint256 amount) external returns (uint256 socialised);

    /// @notice Book USDC recovered after its loss was written down, back to whichever balance
    ///         sheet bore it - the pool that absorbed it, or the source that was never repaid.
    ///         LiquidationAuction only.
    function recoverWrittenDownLoss(address borrower, uint256 amount) external;

    /// @return Sum of the bounties currently parked against live auctions.
    /// @dev Also the marker `LiquidationAuction.setCreditManager` checks a candidate manager
    ///      for, because only one carrying the park can answer it.
    function totalBountyParked() external view returns (uint256);

    /// @notice Settle the bounty parked against an auction. LiquidationAuction only.
    /// @param earned True from the exits that resolved the position (`_bid`,
    ///        `expireToWorkout`), which credit the caller who opened it; false from the
    ///        exits that resolved nothing (`cancel`, `start`'s supersede branch), which
    ///        return the escrow to the borrower so the position stays armed.
    /// @dev Must not revert. It sits on every auction exit, and a state where all of them
    ///      revert is permanently stranded collateral.
    function resolveBounty(uint256 auctionId, bool earned) external;

    /// @notice Retry placing losses the lender pool could not accept. Permissionless.
    function flushSocialisedLoss() external;

    /// @notice Re-state the reserve the lender pool holds against a borrower, from auction and
    ///         vault state. Permissionless.
    /// @dev The auction calls this on every terminal transition, inside a `try`/`catch` - its exits
    ///      must survive a pool that reverts everything. Anyone may call it because that `catch`
    ///      means a release can be dropped, and a dropped release depresses the exit price for
    ///      every lender until somebody calls this.
    function refreshImpairment(address borrower) external;

    /// @return Losses recognised on the books but not yet accepted by the lender pool.
    function unsocialisedLoss() external view returns (uint256);

    /// @notice USDC held to absorb auction shortfalls before any loss reaches lenders.
    function insuranceFund() external view returns (uint256);

    function debtOf(address borrower) external view returns (uint256);

    function totalDebt() external view returns (uint256);

    /// @notice Delivered yield not yet moved into the accumulator. The vault checks it
    ///         before a manager swap, because it is value in flight that debt does not
    ///         account for.
    function undistributedYield() external view returns (uint256);

    /// @notice The running yield-per-bond accumulator. The vault reads it to refuse a
    ///         manager that has already been live: `_settle` does not stamp an index
    ///         while detached, so re-attaching one would let any position that moved in
    ///         the meantime claim the whole accumulator against a zero index. A manager
    ///         that has never been attached reports zero.
    function accYieldPerBond() external view returns (uint256);

    /// @notice What `bonds` bonds have earned since the accumulator stood at `sinceIndex`, in USDC.
    /// @dev The arithmetic `_settle` runs on a position, exposed so a caller holding a *slice* of a
    ///      position can ask about that slice. `LiquidationAuction` holds every open workout's lot
    ///      under one ledger entry, so its own accrual is the sum of them and no per-workout figure
    ///      can be recovered from it; a workout records the accumulator when its lot arrived and
    ///      asks this.
    ///
    ///      A view rather than a formula the caller writes, because the scale factor is internal to
    ///      the manager and a second copy of `bonds x delta / ACC_PRECISION` is a second model of the
    ///      same quantity. Audit round 22, finding 18.
    ///
    ///      Prices against the *projected* accumulator, exactly as `pendingYieldOf` does, so the
    ///      answer does not depend on whether anybody has called `accrueYield` recently.
    function yieldAccruedOn(uint256 bonds, uint256 sinceIndex) external view returns (uint256);

    /// @notice The vault this manager is bound to. Exposed so the vault can refuse to
    ///         point at a manager bound elsewhere: `settleForVault` is caller-gated on
    ///         this, and the vault settles before every bond-count change, so a
    ///         mismatched pointer reverts every deposit, withdrawal and seizure.
    function vault() external view returns (ICollateralVault);

    /// @notice The risk configuration this manager reads.
    /// @dev **Audit round 20.** Exposed for the same reason `vault()` is: so a setter installing
    ///      this manager can refuse one that answers a different authority to the vault's. Before
    ///      this reached the interface no setter could have expressed the check - the member was on
    ///      all three implementations and on none of their interfaces.
    function riskParams() external view returns (IRiskParams);

    /// @notice The NAV feed this manager reads.
    /// @dev **Audit round 21.** Exposed for the same reason `riskParams()` is: so a setter
    ///      installing this manager can refuse one that prices off a different feed to the vault's.
    ///      Before this reached the interface no setter could have expressed the check - the member
    ///      was on all three implementations and on none of their interfaces.
    ///
    ///      This manager reads its own feed for exactly one thing, `borrow`'s `isStale()` gate, and
    ///      that is what makes the divergence silent: vault stale and manager fresh keeps lending
    ///      against a price `NAV_STALENESS` has already disowned, and manager stale with the vault
    ///      fresh freezes borrowing on a book nothing is wrong with. Both measured.
    function navOracle() external view returns (INAVOracle);

    /// @return ltvBps debt / collateralValue in bps. Zero when there is no debt,
    ///         whatever the collateral; type(uint256).max when there is debt against
    ///         no collateral. The debt-first ordering matters: otherwise every empty
    ///         address reports maximum LTV and keeper scanners queue liquidations for
    ///         accounts that do not exist.
    function currentLtvBps(address borrower) external view returns (uint256 ltvBps);

    /// @return hf liquidationThreshold / currentLTV, 1e18 fixed point; < 1e18 ⇒ liquidatable.
    ///         A view for keepers and the UI only. It divides twice, so a position a
    ///         fraction of a bp past the threshold still reads as exactly 1e18: gate
    ///         liquidation on a direct comparison, not on this.
    function healthFactor(address borrower) external view returns (uint256 hf);
}
