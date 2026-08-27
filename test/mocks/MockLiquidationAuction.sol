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
    /// @dev The same four bytes `LiquidationAuction` reverts with. A custom error's selector is
    ///      `keccak256` of its name and parameter types and carries no contract identity, so a
    ///      redeclaration here is the same type on the wire.
    error ZeroAddress();

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

    /// @notice The risk configuration this auction claims to read.
    /// @dev **Audit round 20**, and settable for exactly the reason `vault` is. `CollateralVault
    ///      .setLiquidationAuction` and `CreditManager.setLiquidationAuction` both refuse an
    ///      auction answering a different authority to the vault's, so a fixture points this at the
    ///      vault's own `RiskParams` - and a fixture proving the guard bites points it elsewhere.
    address public riskParams;

    function setRiskParams(address riskParams_) external {
        riskParams = riskParams_;
    }

    /// @notice The NAV feed this auction claims to price from.
    /// @dev **Audit round 21**, and settable for exactly the reason `riskParams` is.
    ///      `CollateralVault.setLiquidationAuction` and `CreditManager.setLiquidationAuction` both
    ///      refuse an auction pricing off a different feed to the vault's, so a fixture points this
    ///      at the vault's own oracle - and a fixture proving the guard bites points it elsewhere.
    address public navOracle;

    function setNavOracle(address navOracle_) external {
        navOracle = navOracle_;
    }

    function setCreditManager(address creditManager_) external {
        creditManager = creditManager_;
    }

    mapping(address => uint256) public workoutsOpenFor;

    function setWorkoutOpenFor(address borrower, uint256 n) external {
        workoutsOpenFor[borrower] = n;
    }

    /// @notice The live auction per borrower.
    /// @dev `CreditManager._impairmentFor` reads this, so a mock that did not answer made
    ///      `liquidate` revert on a typed call to a function that was not there - the same reason
    ///      this file exists at all. `start` writes it, so the mock cannot report a liquidation it
    ///      never opened.
    ///
    ///      A `floorProceeds` mapping sat beside this until the round-13 fix. It is gone with the
    ///      view: the impairment reserves the whole debt while a liquidation is open and no longer
    ///      credits a predicted recovery, so there is nothing here left to stub.
    mapping(address => uint256) public auctionOf;

    /// @notice USDC an in-flight fill has already credited against the borrower's loan.
    /// @dev Added with the round-15 fix, and it is the same trap as `auctionOf` above: this file is
    ///      duck-typed, `CreditManager` makes a typed call into it, and a typed call to a function
    ///      that is not there reverts the whole fixture rather than returning zero. Writable so a
    ///      test can stage the netting without an auction, which the real contract only ever
    ///      reaches from inside a `bid`.
    mapping(address => uint256) public recognisedRecoveryOf;

    function setRecognisedRecovery(address borrower, uint256 amount) external {
        recognisedRecoveryOf[borrower] = amount;
    }

    function setLiveWork(uint256 liveAuctions, uint256 openWorkouts) external {
        liveAuctionCount = liveAuctions;
        openWorkoutCount = openWorkouts;
    }

    /// @notice Mirrors the real contract's zero-address refusal, and audit round 26 is why.
    /// @dev **This mock is duck-typed, so every clause the protocol probes for has to exist here or
    ///      the mock stops standing in for the thing it mocks.** `CreditWiring.checkAuctionSwap`
    ///      probes this selector by calling `start(address(0), address(0))` on the incoming pointer
    ///      and reading the *shape* of the refusal - four bytes of error selector means the function
    ///      is there, empty returndata means it is not. The real `LiquidationAuction.start` refuses a
    ///      zero `borrower` or `caller` with `ZeroAddress()` before it writes anything, so the probe
    ///      is free.
    ///
    ///      Without this clause the probe *succeeded* against this mock and opened an auction:
    ///      MEASURED, `startCalls` read 2 rather than 1 after a single `liquidate`, `nextId` was one
    ///      ahead, and `auctionOf[address(0)]` held an id no caller ever asked for. Two tests in
    ///      `CreditManager.t.sol` went red on the counter, which is the mock reporting a liquidation
    ///      it never opened - exactly what `auctionOf`'s own note above says must not happen.
    ///
    ///      The real contract's *first* clause, `msg.sender != creditManager` -> `NotCreditManager()`,
    ///      is deliberately not mirrored. It would be a second, stricter refusal on a mock several
    ///      fixtures drive directly and point away from the manager on purpose, and the probe needs
    ///      only one four-byte answer to see the selector. This file is dumb by design; it is copied
    ///      here to the depth the protocol actually inspects and no further.
    function start(address borrower, address caller) external returns (uint256 id) {
        if (borrower == address(0) || caller == address(0)) revert ZeroAddress();
        lastBorrower = borrower;
        lastCaller = caller;
        startCalls++;
        id = nextId++;
        auctionOf[borrower] = id;
    }
}
