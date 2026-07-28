// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Records what `CreditManager.liquidate` hands it, and reports the live-work
///         counters the vault and manager check before repointing away from it.
/// @dev Needed because `liquidate` makes a typed call into the auction, and Solidity
///      reverts a typed call to an address with no code - so an EOA stand-in cannot be
///      used, and the CreditManager suite would otherwise be unable to reach the line
///      after its own gate.
///
///      Since audit round 5 it also has to satisfy `setLiquidationAuction`'s guards on
///      both the vault and the manager, which refuse to repoint away from an auction
///      that still has live auctions or open workouts. Those counters are settable here
///      so a fixture can prove the guard bites without running a whole auction.
///
///      Deliberately dumb otherwise: suites using this are testing the *gates*, and a
///      mock that ran a real auction would make their failures ambiguous.
contract MockLiquidationAuction {
    address public lastBorrower;
    address public lastCaller;
    uint256 public startCalls;
    uint256 public nextId = 1;

    uint256 public liveAuctionCount;
    uint256 public openWorkoutCount;
    address public vault;

    /// @dev `borrow` reads this to refuse new debt while the wiring pointers disagree,
    ///      so the mock has to answer it. Defaults to the manager that wires the mock,
    ///      which is the aligned case; a fixture proving the guard bites sets it away.
    address public creditManager;

    function setVault(address vault_) external {
        vault = vault_;
    }

    function setCreditManager(address creditManager_) external {
        creditManager = creditManager_;
    }

    mapping(address => uint256) public workoutsOpenFor;

    function setWorkoutOpenFor(address borrower, uint256 n) external {
        workoutsOpenFor[borrower] = n;
    }

    function setLiveWork(uint256 liveAuctions, uint256 openWorkouts) external {
        liveAuctionCount = liveAuctions;
        openWorkoutCount = openWorkouts;
    }

    function start(address borrower, address caller) external returns (uint256) {
        lastBorrower = borrower;
        lastCaller = caller;
        startCalls++;
        return nextId++;
    }
}
