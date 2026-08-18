// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IRiskParams
/// @notice The live risk configuration: the borrow ceiling, the liquidation trigger and the two
///         borrow caps. Read by `CreditManager`, `CollateralVault` and `LiquidationAuction`.
/// @dev Consumers hold the implementation as an `immutable`, so this interface exists for them to
///      call through and for tests and fixtures to bind to. Binding fixtures to the interface
///      rather than to the contract is what lets the authority move later without editing every
///      derivation in the suite.
interface IRiskParams {
    /// @notice The whole risk configuration.
    /// @dev Packed into one storage slot. The field widths are not a gas micro-optimisation: they
    ///      are what lets `CreditManager.borrow` read three of the four in a single `SLOAD` on the
    ///      hottest path in the protocol.
    struct Params {
        /// @dev Borrow ceiling, bps of collateral value. Gates `borrow` and `withdrawBonds`.
        uint16 maxLtvBps;
        /// @dev Liquidation trigger, bps of collateral value. Gates `liquidate`, `seize`, `cancel`.
        uint16 liquidationThresholdBps;
        /// @dev USDC, 6 decimals. Ceiling on `totalDebt`.
        uint64 globalBorrowCap;
        /// @dev USDC, 6 decimals. Ceiling on any one account's `debtOf`.
        uint64 perAccountBorrowCap;
    }

    /// @notice All four at once.
    /// @dev Callers needing more than one field must use this rather than the single getters, so a
    ///      reader can never combine two fields observed in different blocks. `borrow` reads three.
    function params() external view returns (Params memory);

    function maxLtvBps() external view returns (uint256);
    function liquidationThresholdBps() external view returns (uint256);
    function globalBorrowCap() external view returns (uint256);
    function perAccountBorrowCap() external view returns (uint256);

    /// @notice Reverts unless `p` is a legal configuration. Does not write.
    /// @dev On the external surface deliberately. A proposer can `eth_call` this before spending
    ///      48 hours on a timelock operation that would revert on execution - `TimelockController`
    ///      validates nothing at schedule time, so without this the first sign of an illegal value
    ///      is a failed execution two days later, leaving an operation that has to be cancelled.
    function checkRiskParams(Params memory p) external pure;

    /// @notice Replace the whole risk configuration. Owner only, which in production means a
    ///         `TimelockController` and therefore a 48 hour delay.
    /// @dev All four at once rather than one setter per field, because the relations must hold
    ///      after every write and per-field setters make some legal end states reachable only
    ///      through an illegal intermediate. See the implementation for the full argument.
    function setRiskParams(Params calldata p) external;
}
