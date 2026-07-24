// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title INAVOracle
/// @notice Keeper-posted bond NAV with deviation + staleness guards (PRD §4.6).
interface INAVOracle {
    /// @return nav USD value of one bond, 8 decimals (Config.NAV_DECIMALS)
    function navPerBond() external view returns (uint256 nav);

    /// @return Timestamp of the last accepted NAV update
    function lastUpdated() external view returns (uint256);

    /// @notice True when NAV is older than Config.NAV_STALENESS. Stale ⇒ borrow()
    ///         pauses; liquidations continue on last-known NAV (PRD §4.6).
    function isStale() external view returns (bool);
}
