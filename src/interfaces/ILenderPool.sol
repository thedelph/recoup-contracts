// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILiquiditySource} from "./ILiquiditySource.sol";

/// @title ILenderPool
/// @notice ERC-4626 USDC vault lending exclusively to CreditManager, with a FIFO
///         withdrawal queue when idle USDC is short (PRD §4.2).
/// @dev **`LenderPool` declares `is ILenderPool`, and these events are declared here and only
///      here.** Audit round 11 found the implementation inheriting nothing, so conformance was
///      never compiler-checked - and both of the protocol's call sites into the pool swallow a
///      failed call in a `catch`, which turns a signature drift into a silent deferral rather than
///      a build failure. The evidence that nothing checked is in this file's own history: the
///      published ABI carried `YieldDistributed(uint256)` against three parameters in the
///      implementation for as long as the two were only related by intention.
///
///      So the rule for anything added later, stated once rather than per line: **an event that
///      reports the outcome of a function declared here is declared here too, and the
///      implementation does not re-declare it.** Solidity rejects re-declaring an inherited event,
///      which is what makes the drift structurally impossible instead of merely fixed this once. A
///      second copy in the implementation would restore exactly the freedom that produced the
///      drift. Events the implementation emits from machinery this interface does not describe -
///      its wiring setters, its yield-stream freeze, its pull-payment claim - stay on the
///      implementation, because promising them here would be promising behaviour no other
///      `ILenderPool` has to have.
interface ILenderPool is IERC4626, ILiquiditySource {
    event Lent(uint256 amount);
    event PrincipalRepaid(uint256 amount);
    /// @notice A repayment larger than what was recorded as out on loan, routed into the yield
    ///         stream rather than landing in the share price in the repaying block.
    /// @dev Separate from `PrincipalRepaid`, which reports the whole amount. A surplus means an
    ///      earlier write-down is being reversed, and that is worth being able to see on its own.
    event PrincipalSurplusStreamed(uint256 amount);
    /// @param amount The epoch's newly delivered lender share.
    /// @param ratePerSecond Release rate, scaled by the implementation's fixed-point precision.
    /// @param streamEndsAt When the pot currently being released runs dry.
    /// @dev Carries the stream terms, not just the amount. The amount alone no longer describes
    ///      what happens to the share price, because it no longer happens at once.
    ///
    ///      **The drift this whole file's header is about.** The stream added the rate and the end
    ///      timestamp to the implementation and left this line at one parameter, so an indexer
    ///      built from the published ABI matched on a `topic0` the chain never emits and saw no
    ///      yield events at all. Audit round 11 caught it; `is ILenderPool` is what stops the next
    ///      one.
    event YieldDistributed(uint256 amount, uint256 ratePerSecond, uint256 streamEndsAt);
    /// @param amount The reserve now standing against this borrower, not a delta.
    event Impaired(address indexed borrower, uint256 amount, uint256 totalImpairment);
    event ImpairmentReleased(address indexed borrower, uint256 amount, uint256 totalImpairment);
    /// @dev Carries the resulting `exitReserve()` as well as its two inputs, because the inputs
    ///      alone do not tell an indexer what the exit price actually stood back from - the
    ///      insurance netting and the exposure clamp both sit between them and the answer.
    event LossReservesSet(uint256 unplacedLoss, uint256 insuranceCover, uint256 exitReserve);
    event LossSocialised(uint256 amount);
    event WithdrawalQueued(address indexed lender, uint256 indexed queueIndex, uint256 assets);
    event QueuedWithdrawalServiced(address indexed lender, uint256 indexed queueIndex, uint256 assets);
    /// @notice A queued request was withdrawn by its owner, who took the escrowed shares back.
    event WithdrawalRequestCancelled(address indexed lender, uint256 indexed queueIndex, uint256 shares);
    /// @notice A queued remainder too small to be worth one asset-wei, returned to its owner.
    /// @dev Declared here rather than left on the implementation, and the reason generalises.
    ///      `queuePosition` is part of this interface, so an indexer is invited to reconstruct who
    ///      is waiting from these events - and there are **four** ways an entry stops waiting, not
    ///      two. An indexer that knows only `WithdrawalQueued` and `QueuedWithdrawalServiced` shows
    ///      cancelled and dust-released lenders as still in the queue forever. Distinct from
    ///      `QueuedWithdrawalServiced` because no USDC moves: a lender watching for their payout
    ///      must not read this as one.
    event QueuedWithdrawalReleasedAsDust(address indexed lender, uint256 indexed queueIndex, uint256 shares);

    // `lend`, `repayPrincipal` and `available` come from ILiquiditySource, which the
    // Phase 2 treasury float also implements. That is the whole point of the seam:
    // swapping the pool in behind CreditManager needs no change to CreditManager.

    /// @notice Receive the lender share of harvested yield - raises share price over the following
    ///         `YIELD_STREAM_DURATION`, not in the delivering block. See `LenderPool` for why.
    ///         EpochHarvester only.
    function distributeYield(uint256 amount) external;

    /// @notice Reserve the shortfall a borrower's live liquidation is expected to produce.
    ///         CreditManager only, and an idempotent **set** rather than an add: the estimate is
    ///         re-stated as the position moves.
    function impair(address borrower, uint256 amount) external;

    /// @notice Drop a borrower's reserve because the position resolved. CreditManager only.
    function releaseImpairment(address borrower) external;

    /// @notice Set the reserves that belong to no single position: a loss the manager has
    ///         recognised but this pool has not absorbed, and the insurance fund standing in front
    ///         of the live impairments. CreditManager only.
    function setLossReserves(uint256 unplacedLoss, uint256 insuranceCover) external;

    /// @notice What the exit price stands back from `totalAssets()`, after insurance is netted once
    ///         and after the clamp to what this pool has actually lent.
    function exitReserve() external view returns (uint256);

    /// @notice Assets less `exitReserve()`. What somebody leaving is priced against.
    /// @dev **Integrators: the ERC-4626 `convertToAssets`/`convertToShares` views deliberately
    ///      report the un-impaired figure**, matching Maple. That asymmetry is the mechanism, not
    ///      an oversight: an entrant who bought at the impaired price would profit when the
    ///      impairment was released. Read `previewRedeem` for what a redemption would actually pay.
    function exitAssets() external view returns (uint256);

    /// @notice USDC currently out on loan. The ceiling on every reserve above, because a pool
    ///         cannot lose more than it has lent.
    function outstandingPrincipal() external view returns (uint256);

    /// @notice The summed per-borrower reserve, gross: before insurance is netted and before the
    ///         exposure clamp.
    /// @dev **Deliberately not `exitReserve()`, and audit round 16 is why.** That figure clamps to
    ///      `outstandingPrincipal`, so it reads zero in exactly the state
    ///      `CreditManager.setLenderPool` needs to detect - a pool whose principal has come home
    ///      but whose per-borrower marks have not been cleared. This is the number
    ///      `LenderPool.setCreditManager` refuses on, exposed so the other side of the same
    ///      pointer pair can refuse on the same one.
    function totalImpairment() external view returns (uint256);

    /// @notice How many borrowers currently carry a non-zero mark.
    /// @dev With `impairedBorrowerAt`, this is what lets a stale mark be found and cleared on
    ///      chain. Audit round 16: a mark is a photograph of a debt that decays on the yield
    ///      stream, and until these existed the only way to learn which borrower to refresh was to
    ///      replay `Impaired` logs off chain.
    function impairedBorrowerCount() external view returns (uint256);

    /// @notice The marked borrower at `index`.
    /// @dev **Unstable order.** Removal swap-pops the tail into the vacated slot, so any walk that
    ///      clears marks as it goes must run downward from `impairedBorrowerCount() - 1`.
    function impairedBorrowerAt(uint256 index) external view returns (address);

    /// @notice Write a shortfall (post-auction, post-insurance) down against the pool.
    ///         Must be loud: PRD §4.2 requires prominent disclosure of socialised loss.
    /// @return absorbed how much of `amount` the pool actually took.
    /// @dev The return value is not decoration. A pool may absorb less than it is asked to - it
    ///      cannot write down more than it has lent - and a `void` signature made a partial
    ///      absorption indistinguishable from a full one, so the caller booked the whole amount as
    ///      placed and the remainder existed on no ledger at all. Any implementation must report
    ///      what it took, and every caller must retain the difference.
    function socialiseLoss(uint256 amount) external returns (uint256 absorbed);

    /// @return index position in the FIFO queue (0 = next), remaining assets still owed
    function queuePosition(address lender) external view returns (uint256 index, uint256 remaining);
}
