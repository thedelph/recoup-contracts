// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IEpochHarvester
/// @notice Permissionless (cooldown-limited) weekly yield harvest and split (PRD §4.4).
interface IEpochHarvester {
    event Harvested(
        uint256 indexed epoch,
        uint256 totalYield,
        uint256 toBorrowers,
        uint256 toLenders,
        uint256 toInsurance,
        uint256 toProtocol
    );
    event ZeroYieldEpoch(uint256 indexed epoch);

    /// @notice Claim farm USDC and apply the YieldSplit across all positions.
    ///         Permissionless; reverts if called within Config.MIN_EPOCH_GAP of the last run.
    function harvest() external;

    /// @notice Pagination fallback for >200 positions (PRD §6.2 AC).
    function harvestRange(uint256 start, uint256 end) external;

    function lastHarvestAt() external view returns (uint256);
}
