// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";

/// @notice Settable NAV for unit tests (USD, 8 decimals per Config.NAV_DECIMALS).
contract MockNavOracle is INAVOracle {
    uint256 public navPerBond;
    uint256 public lastUpdated;

    constructor(uint256 nav) {
        setNav(nav);
    }

    function setNav(uint256 nav) public {
        navPerBond = nav;
        lastUpdated = block.timestamp;
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}
