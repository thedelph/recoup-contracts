// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bare-minimum stand-in for the vault's debt lookup: only `debtOf`,
///         settable per borrower. The real CreditManager arrives in Phase 2.
contract MockCreditManager {
    mapping(address => uint256) public debtOf;

    function setDebt(address borrower, uint256 debtUsdc) external {
        debtOf[borrower] = debtUsdc;
    }
}
