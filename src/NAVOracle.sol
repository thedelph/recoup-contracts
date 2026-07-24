// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {INAVOracle} from "./interfaces/INAVOracle.sol";
import {Config} from "./Config.sol";

/// @title NAVOracle (skeleton — PRD §4.6)
/// @notice Keeper posts navPerBond (USD, 8 decimals) daily (minimum weekly).
///         Updates beyond maxDeviationPerUpdate enter a 12h pending state needing
///         a second admin key. Staleness pauses borrows; liquidations continue on
///         last-known NAV.
/// @dev TODO(phase-2): implement postNav with deviation guard + two-key confirm
///      flow; keeper role management. Worst realistic attack is NAV keeper key
///      compromise (PRD §9) — guards here are the mitigation, treat as critical.
contract NAVOracle is INAVOracle, Ownable {
    error NotImplemented();
    error NotKeeper();

    event NAVPosted(uint256 nav, uint256 timestamp);
    event NAVPending(uint256 nav, uint256 confirmableAt);

    address public keeper;
    /// @inheritdoc INAVOracle
    uint256 public override navPerBond;
    /// @inheritdoc INAVOracle
    uint256 public override lastUpdated;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
    }

    /// @notice Post a new NAV. Within deviation bounds it takes effect immediately;
    ///         beyond Config.NAV_MAX_DEVIATION_BPS it must wait NAV_PENDING_DELAY
    ///         and be confirmed by a second key.
    function postNav(uint256) external {
        if (msg.sender != keeper) revert NotKeeper();
        revert NotImplemented(); // TODO(phase-2)
    }

    /// @inheritdoc INAVOracle
    function isStale() external view returns (bool) {
        return block.timestamp > lastUpdated + Config.NAV_STALENESS;
    }
}
