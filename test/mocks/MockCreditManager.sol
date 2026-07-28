// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bare-minimum stand-in for the vault's debt lookup: only `debtOf`,
///         settable per borrower. The real CreditManager arrives in Phase 2.
contract MockCreditManager {
    mapping(address => uint256) public debtOf;
    uint256 public totalDebt;

    /// @notice The vault this manager claims to be bound to. `setCreditManager`
    ///         refuses a manager bound elsewhere, so the suites have to set it.
    ///         Settable rather than constructor-set because the mock is built before
    ///         the vault it will be wired into.
    address public vault;

    function setVault(address vault_) external {
        vault = vault_;
    }

    /// @notice Records that the vault settled a position before changing its bonds.
    ///         The real accumulator lives in CreditManager; the vault only has to call
    ///         this at the right moment, which is what these suites check.
    mapping(address => uint256) public settledAtBonds;
    uint256 public settleCalls;

    function setDebt(address borrower, uint256 debtUsdc) external {
        totalDebt = totalDebt + debtUsdc - debtOf[borrower];
        debtOf[borrower] = debtUsdc;
    }

    function settleForVault(address borrower, uint256 currentBonds) external {
        settledAtBonds[borrower] = currentBonds;
        settleCalls++;
    }
}
