// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {INAVOracle} from "./INAVOracle.sol";
import {IRiskParams} from "./IRiskParams.sol";

/// @title ICollateralVault
/// @notice Holds bond collateral (fungible ERC-1155 units, id 0), tracks per-owner
///         balances, delegates DexFi interaction to an ICustodyAdapter (PRD §4.1).
interface ICollateralVault {
    event BondsDeposited(address indexed owner, uint256 amount);
    event ETHDeposited(address indexed owner, uint256 ethAmount, uint256 bondAmount);
    event BondsWithdrawn(address indexed owner, uint256 amount);
    event BondsSeized(address indexed owner, address indexed to, uint256 amount);
    event BondsReassigned(address indexed from, address indexed to, uint256 amount);
    event BondsDisposed(address indexed from, address indexed to, uint256 amount);

    /// @notice Deposit existing bond units as collateral; vault stakes them into
    ///         the farm. Requires the depositor↔vault transfer to pass DexFi's
    ///         whitelist (vault must be whitelisted).
    function depositBonds(uint256 amount) external;

    /// @notice Deposit ETH; vault mints new bonds via the custody adapter using a
    ///         DexFi keeper-signed mint payload, and stakes them.
    function depositETH(bytes calldata mintData) external payable;

    /// @notice Withdraw bond units. Only allowed when debt is zero or resulting
    ///         LTV ≤ maxLTV.
    function withdrawBonds(uint256 amount) external;

    /// @notice Move a liquidated position's bonds out to the auction winner.
    ///         LiquidationAuction only, and only while the position is liquidatable.
    function seize(address owner, address to) external returns (uint256 amount);

    /// @notice Move a liquidated position's *ledger entry* to `to`, leaving the bonds
    ///         staked exactly where they are. LiquidationAuction only, and only while
    ///         the position is liquidatable.
    /// @dev This is the workout path. It exists because DexFi gates bond transfers on
    ///      a whitelist that only the custody adapter is on, so an expiry path that
    ///      moved tokens would need a second whitelisted address the protocol does not
    ///      have - and would therefore be a path that can revert while holding someone
    ///      else's collateral. Moving the claim instead makes expiry unfailable, and
    ///      leaves the lot earning through the manual-redemption wait.
    function reassign(address from, address to) external returns (uint256 amount);

    /// @notice Send a workout lot out of custody in one hop, through the adapter.
    ///         LiquidationAuction only.
    function disposeTo(address to, uint256 amount) external;

    function bondCount(address owner) external view returns (uint256);

    /// @notice The auction this vault accepts `seize`/`reassign`/`disposeTo` from.
    /// @dev Read by `CreditManager.liquidate`, which must not open an auction the vault
    ///      will not honour - that auction's every exit would revert.
    function liquidationAuction() external view returns (address);


    /// @notice The CreditManager this vault currently settles into.
    /// @dev Exposed so a CreditManager can tell whether it is still the live one. Its
    ///      accumulator prices positions off `bondCount`/`totalBondCount`, and that is
    ///      only sound while the vault settles into it before every bond-count change
    ///      - which stops the instant this pointer moves elsewhere.
    function creditManager() external view returns (address);

    /// @notice The risk configuration this vault reads, and the reference every other risk reader
    ///         is checked against.
    /// @dev **Audit round 20.** All three risk readers hold this as an `immutable`, and until this
    ///      member reached the interfaces no wiring setter could look at it - so an ordinary
    ///      zero-debt manager+auction migration installed a second `RiskParams` with no refusal at
    ///      any of the seven calls, and a position between the two thresholds then had `bid`,
    ///      `expireToWorkout` and `cancel` all refuse it at once.
    ///
    ///      **This one is the reference because this contract cannot be replaced.** There is no
    ///      `setCollateralVault` anywhere; the vault pointer is `immutable` on both the manager and
    ///      the auction. So the manager and the auction are checked against the vault's answer, and
    ///      never against each other - a symmetric check between two replaceable contracts can
    ///      agree with itself while both disagree with the collateral.
    function riskParams() external view returns (IRiskParams);

    /// @notice The NAV feed this vault prices collateral from, and the reference every other nav
    ///         reader is checked against.
    /// @dev **Audit round 21, and the exact sibling of `riskParams` above.** Round 20 anchored the
    ///      risk pointer at six wiring sites and left this one - the identical `immutable` triple,
    ///      one constructor argument over - with no constructor check, no setter check, nothing on
    ///      any interface and not one line in `DeployBase._assertCoreGraph`. It was therefore
    ///      *weaker* than `riskParams` had been before round 20, which at least had the script
    ///      assertion.
    ///
    ///      Divergence here produces no revert anywhere, because each contract reads its own feed
    ///      for a different, non-overlapping job: the vault values collateral and decides
    ///      liquidatability, the manager gates `borrow` on staleness, the auction prices the whole
    ///      Dutch curve. Measured on the shipped fixture, a lot worth 943.125000 sold for
    ///      94.312500 and 534.437500 of principal was written off against a control of zero.
    ///
    ///      This one is the reference for the same reason `riskParams` is: there is no
    ///      `setCollateralVault` anywhere, so the vault is the only contract in the graph that
    ///      cannot be replaced.
    function navOracle() external view returns (INAVOracle);

    /// @notice Sum of every `bondCount`. The denominator for pro-rata yield, and the
    ///         figure custody solvency is checked against.
    function totalBondCount() external view returns (uint256);

    /// @return value bondCount(owner) × navPerBond, in USD 8 decimals
    function collateralValue(address owner) external view returns (uint256 value);

    /// @notice True when custody holds at least as many bonds as the ledger records.
    /// @dev Gate new debt on this. The emergency custody exit empties the farm
    ///      position without clearing per-owner balances, so the ledger can outlive
    ///      the collateral behind it.
    function custodyIsSolvent() external view returns (bool);
}
