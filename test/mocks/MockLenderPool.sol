// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A lender pool that can be switched between accepting and refusing losses.
/// @dev The real `LenderPool.socialiseLoss` reverts `NotImplemented` until Phase 4, and
///      the deploy script wires exactly that pool. So "the pool refuses" is not an edge
///      case to imagine - it is the only state that exists today, and a design that
///      cannot survive it cannot complete a single liquidation.
///
///      The flag exists so both halves can be exercised in one test. Asserting "the
///      write-down survives a refusing pool" and "the flush delivers to an accepting
///      pool" in separate tests is the pair that passes forever in isolation while the
///      two states are mutually unreachable.
contract MockLenderPool {
    bool public accepting;
    uint256 public socialisedTotal;
    uint256 public calls;

    error PoolRefuses();

    function setAccepting(bool value) external {
        accepting = value;
    }

    function socialiseLoss(uint256 amount) external {
        calls++;
        if (!accepting) revert PoolRefuses();
        socialisedTotal += amount;
    }
}
