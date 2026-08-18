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

    /// @notice The risk configuration this manager claims to read.
    /// @dev **Audit round 20**, and settable for exactly the reason `vault` is. Every wiring setter
    ///      that installs a risk reader now refuses one answering a different authority to the
    ///      vault's, so a fixture has to point this at the vault's own `RiskParams` before wiring -
    ///      and a fixture proving the guard bites points it somewhere else, which is the whole
    ///      value of it being settable rather than derived.
    address public riskParams;

    function setRiskParams(address riskParams_) external {
        riskParams = riskParams_;
    }

    /// @notice The NAV feed this manager claims to read.
    /// @dev **Audit round 21**, and settable for exactly the reason `riskParams` is, one pointer
    ///      over. `CollateralVault.setCreditManager` now refuses a manager pricing off a different
    ///      feed to the vault's, so a fixture points this at the vault's own oracle before wiring -
    ///      and a fixture proving the guard bites points it elsewhere.
    address public navOracle;

    function setNavOracle(address navOracle_) external {
        navOracle = navOracle_;
    }

    // This mock used to carry a `liquidationAuction` pointer and an `unsocialisedLoss` counter,
    // both added so `LenderPool`'s round-10 exit gate could read them: the gate asked its manager
    // which auction was authoritative and whether a loss had already been recognised. The gate was
    // deleted when impairment pricing replaced it - the pool is pushed its reserves and makes no
    // call into its manager at all now - so nothing read either field any more, and a mock surface
    // that answers a question nobody asks is the next reader's false lead.

    /// @notice Records that the vault settled a position before changing its bonds.
    ///         The real accumulator lives in CreditManager; the vault only has to call
    ///         this at the right moment, which is what these suites check.
    mapping(address => uint256) public settledAtBonds;
    uint256 public settleCalls;

    function setDebt(address borrower, uint256 debtUsdc) external {
        totalDebt = totalDebt + debtUsdc - debtOf[borrower];
        debtOf[borrower] = debtUsdc;
    }

    /// @notice What the vault's liquidatability check reads.
    /// @dev The real manager projects unsettled streamed yield here, so it can be
    ///      lower than `debtOf`. The mock has no accumulator, so the two agree - and
    ///      `setUnsettledCredit` exists to force them apart, because the difference is
    ///      exactly what makes a position look liquidatable on stored debt while a
    ///      permissionless settle would have cleared it for free.
    mapping(address => uint256) public unsettledCredit;

    function setUnsettledCredit(address borrower, uint256 amount) external {
        unsettledCredit[borrower] = amount;
    }

    function currentDebtOf(address borrower) external view returns (uint256) {
        uint256 debt = debtOf[borrower];
        uint256 credit = unsettledCredit[borrower];
        return credit >= debt ? 0 : debt - credit;
    }

    function settleForVault(address borrower, uint256 currentBonds) external {
        settledAtBonds[borrower] = currentBonds;
        settleCalls++;
    }
}
