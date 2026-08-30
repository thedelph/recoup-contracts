// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILiquiditySource} from "./ILiquiditySource.sol";

/// @title ILenderPool
/// @notice ERC-4626 USDC vault lending exclusively to CreditManager, with controller-scoped
///         withdrawal requests when idle USDC is short (PRD §4.2).
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
///      its wiring setters and its yield-stream freeze - stay on the implementation, because
///      promising them here would be promising behaviour no other `ILenderPool` has to have.
///      `WithdrawalClaimed` stays here because both claim functions are part of this interface.
interface ILenderPool is IERC4626, ILiquiditySource {
    event Lent(uint256 amount);
    event PrincipalRepaid(uint256 amount);
    /// @notice A repayment larger than what was recorded as out on loan, routed into the yield
    ///         mechanism rather than landing in the share price in the repaying block.
    /// @dev Separate from `PrincipalRepaid`, which reports the whole amount. A surplus means an
    ///      earlier write-down is being reversed, and that is worth being able to see on its own.
    ///      The amount may freeze below the stream floor; fixed-claim repair is reported separately.
    event PrincipalSurplusStreamed(uint256 amount);
    /// @notice Incoming recognised USDC restored part of a fixed-claim solvency shortfall.
    event ClaimDeficitCovered(address indexed payer, uint256 amount, uint256 remaining);
    /// @param amount The lender share actually pulled, including any exact fixed-claim repair.
    /// @param ratePerSecond Release rate, scaled by the implementation's fixed-point precision.
    /// @param streamEndsAt When the pot currently being released runs dry.
    /// @dev Carries the current stream terms as well as the amount. On a claim-only repair the terms
    ///      can remain unchanged, and the paired `ClaimDeficitCovered` event explains the allocation.
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
    /// @notice Money returned on an asset this pool has already written down.
    /// @dev The exact counterpart of `LossSocialised`, and separate from `PrincipalSurplusStreamed`
    ///      on purpose: a surplus repayment reverses a write-down through the principal leg and
    ///      moves `outstandingPrincipal`, while this arrives on a loan that has already been
    ///      written off entirely and moves nothing but the pot. An indexer that could not tell them
    ///      apart would report a live loan where there is none. The implementation first restores
    ///      any fixed-claim insolvency, then streams value owned by a viable cohort or freezes it for
    ///      a low non-zero cohort. Value arriving with no holder is removed from the recognised book
    ///      rather than gifted to a later one.
    event LossRecovered(uint256 amount, uint256 lifetimeRecovered);
    event WithdrawalRequested(
        address indexed controller, uint256 indexed requestId, address indexed receiver, uint256 shares
    );
    event WithdrawalRequestServiced(
        address indexed controller, uint256 indexed requestId, address indexed receiver, uint256 shares, uint256 assets
    );
    event WithdrawalRequestCancelled(
        address indexed controller, uint256 indexed requestId, address indexed receiver, uint256 shares
    );
    event RequestOperatorSet(address indexed controller, address indexed operator, bool approved);
    event WithdrawalClaimed(address indexed receiver, uint256 assets);

    // `lend`, `repayPrincipal` and `available` come from ILiquiditySource, which the
    // Phase 2 treasury float also implements. That is the whole point of the seam:
    // swapping the pool in behind CreditManager needs no change to CreditManager.

    /// @notice Receive the lender share of harvested yield. It first repairs fixed claims, then
    ///         raises released share value for a viable cohort over the rated stream window rather
    ///         than in the delivering block. See `LenderPool` for why. EpochHarvester only.
    /// @dev While the stream is active, entry previews include its projected unreleased tail so a
    ///      post-delivery entrant pays for the pot instead of diluting the delivered cohort. With
    ///      supply below the stream safety floor, only the amount that repairs a fixed-claim
    ///      insolvency may be pulled; any excess remains owed by the harvester.
    function distributeYield(uint256 amount) external;

    /// @notice Reserve the shortfall a borrower's live liquidation is expected to produce.
    ///         CreditManager only, and an idempotent **set** rather than an add: the estimate is
    ///         re-stated as the position moves.
    /// @return wrote Whether the stored mark actually changed. Both of these return it because both
    ///         are idempotent and therefore silent on a no-op - no write, no event, no revert - and
    ///         a caller that treats "did not revert" as "did something" reports work it did not do.
    ///         Audit round 19 measured that: five refreshes, `refreshed = 1` each time, zero
    ///         `Impaired` events, and an unchanged reserve throughout.
    function impair(address borrower, uint256 amount) external returns (bool wrote);

    /// @notice Drop a borrower's reserve because the position resolved. CreditManager only.
    /// @return wrote Whether a mark was actually cleared. See `impair` above.
    function releaseImpairment(address borrower) external returns (bool wrote);

    /// @notice Set the reserves that belong to no single position: a loss the manager has
    ///         recognised but this pool has not absorbed, and the insurance fund standing in front
    ///         of the live impairments. CreditManager only.
    function setLossReserves(uint256 unplacedLoss, uint256 insuranceCover) external;

    /// @notice What the exit price stands back from `totalAssets()`, after insurance is netted once
    ///         and after the clamp to what this pool has actually lent.
    function exitReserve() external view returns (uint256);

    /// @notice Assets less `exitReserve()`. What somebody leaving is priced against.
    /// @dev **Integrators: the ERC-4626 `convertToAssets`/`convertToShares` views deliberately
    ///      report released, un-impaired NAV**, matching Maple on the impairment split. That
    ///      asymmetry is the mechanism, not an oversight: an entrant who bought at the impaired
    ///      price would profit when the impairment was released. During a live yield stream,
    ///      `previewDeposit` and `previewMint` additionally price the unreleased tail, whether its
    ///      clock is active or frozen, so a later entrant cannot dilute the cohort that owns it.
    ///      Read `previewRedeem` for what a redemption would actually pay.
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

    /// @notice Book money returned on an asset this pool already wrote down, as yield.
    ///         CreditManager only.
    /// @dev **Audit round 21, finding 14.** `socialiseLoss` is not reversible through
    ///      `repayPrincipal`: that leg nets against `outstandingPrincipal`, which the socialisation
    ///      has already written down, so a recovery arriving that way is recognised only when the
    ///      surviving book unwinds. It arrives here instead, where it is what it actually is - a
    ///      gain on an asset the pool has already written off. It first repairs any fixed-claim
    ///      insolvency. Residual value is streamed for a live cohort, frozen for a low non-zero
    ///      cohort, or removed from the recognised book when no holder remains. A stream is
    ///      allocated economically to shares present when the recovery is delivered; it does not
    ///      reconstruct historical loss bearers.
    function recoverLoss(uint256 amount) external;

    /// @notice Escrow `shares` in a controller-scoped request with a receiver that cannot change.
    function requestWithdrawal(uint256 shares, address receiver) external;

    /// @notice Service exactly `shares` from `controller`'s request at the live exit price.
    /// @dev Only the controller or an operator they approved may call this. `minAssetsOut` protects
    ///      the controller against an adverse price move in the execution block.
    function serviceWithdrawalRequest(address controller, uint256 shares, uint256 minAssetsOut)
        external
        returns (uint256 assetsOut);

    /// @notice The most shares in `controller`'s request that its current pro-rata cash can fund.
    function maxRequestRedeem(address controller) external view returns (uint256 shares);

    /// @notice Read a controller's one live request and its current serviceable amount.
    function withdrawalRequest(address controller)
        external
        view
        returns (
            uint256 requestId,
            address receiver,
            uint256 shares,
            uint256 serviceableShares,
            uint256 serviceableAssets
        );

    /// @notice Cash reserved pro rata for all currently requested shares.
    function queueCashReserve() external view returns (uint256);

    /// @notice Approve or revoke an operator that may choose service timing and amount.
    function setRequestOperator(address operator, bool approved) external returns (bool);

    function isRequestOperator(address controller, address operator) external view returns (bool);

    /// @notice Cancel the caller's request and return its remaining shares.
    function cancelWithdrawalRequest() external;

    function claim() external returns (uint256 amount);

    function claimFor(address receiver) external returns (uint256 amount);
}
