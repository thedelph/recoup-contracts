// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Config} from "./Config.sol";

/// @title LtvMath
/// @notice The one place loan-to-value is computed (PRD §4.1, §4.3).
/// @dev Both `CollateralVault.withdrawBonds` and `CreditManager` price positions, and
///      releasing collateral raises LTV exactly as borrowing does. Keeping the formula
///      in a library rather than having one contract call the other avoids a circular
///      dependency: CreditManager already reads `vault.collateralValue`, so delegating
///      the withdrawal check to it would have the vault calling into a contract that
///      calls straight back into the vault mid-withdrawal.
///
///      Units, which are easy to get wrong: bond counts are whole integers (the bond
///      is a fungible ERC-1155, id 0, with no decimals), `navPerBond` is USD at
///      `Config.NAV_DECIMALS` (8), and debt is USDC at 6. `Config.USDC_TO_NAV_SCALE`
///      lifts debt into NAV decimals.
library LtvMath {
    /// @notice Collateral value in USD, 8 decimals.
    function collateralValue(uint256 bondCount, uint256 navPerBond) internal pure returns (uint256) {
        return bondCount * navPerBond;
    }

    /// @notice True when `debtUsdc` against `collateralValue8dp` exceeds `maxBps`.
    /// @dev Compared by cross-multiplication rather than by computing a bps figure and
    ///      dividing. Dividing floors, which understates LTV by up to 1 bps and lets a
    ///      borrower sit fractionally over the limit. There is no division here, so
    ///      there is no rounding to favour anyone.
    ///
    ///      Zero collateral with non-zero debt is infinitely levered and always
    ///      exceeds. Zero debt never exceeds, whatever the collateral.
    function exceedsLtv(uint256 debtUsdc, uint256 collateralValue8dp, uint256 maxBps)
        internal
        pure
        returns (bool)
    {
        if (debtUsdc == 0) return false;
        if (collateralValue8dp == 0) return true;
        return debtUsdc * Config.USDC_TO_NAV_SCALE * Config.BPS > maxBps * collateralValue8dp;
    }

    /// @notice LTV in basis points.
    /// @dev For views only (UI, keepers). It divides, so it inherits the ≤1 bps
    ///      downward bias that `exceedsLtv` exists to avoid. Never gate a state change
    ///      on this: use `exceedsLtv`. In particular Phase 3's `liquidate` must
    ///      compare directly rather than reading `healthFactor`, or a position with a
    ///      true LTV a fraction above the threshold reports as exactly healthy.
    /// @return ltvBps `type(uint256).max` when collateral is zero and debt is not;
    ///         0 when there is no debt.
    function ltvBps(uint256 debtUsdc, uint256 collateralValue8dp) internal pure returns (uint256) {
        if (debtUsdc == 0) return 0;
        if (collateralValue8dp == 0) return type(uint256).max;
        return (debtUsdc * Config.USDC_TO_NAV_SCALE * Config.BPS) / collateralValue8dp;
    }

    /// @notice Health factor, `Config.HEALTH_FACTOR_SCALE` fixed point.
    /// @dev `< 1e18` means liquidatable. See the caveat on `ltvBps`: this is a view.
    function healthFactor(uint256 debtUsdc, uint256 collateralValue8dp) internal pure returns (uint256) {
        uint256 ltv = ltvBps(debtUsdc, collateralValue8dp);
        if (ltv == 0) return type(uint256).max;
        if (ltv == type(uint256).max) return 0;
        return (Config.LIQUIDATION_THRESHOLD_BPS * Config.HEALTH_FACTOR_SCALE) / ltv;
    }
}
