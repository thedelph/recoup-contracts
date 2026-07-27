// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ILiquiditySource} from "./interfaces/ILiquiditySource.sol";

/// @title TreasuryLiquiditySource (PRD §4.3)
/// @notice The Phase 2 lending float: owner-funded USDC that only the wired
///         CreditManager can draw on. Deliberately the simplest thing that satisfies
///         `ILiquiditySource`.
/// @dev This contract is disposable. Phase 4 replaces it with the LenderPool, which
///      implements the same interface, so `CreditManager` does not change. Note that
///      `CreditManager.setLiquiditySource` refuses to swap while any debt is
///      outstanding: principal drawn from here must be returned here, or the
///      incoming source's accounting would start from a balance it never lent.
contract TreasuryLiquiditySource is ILiquiditySource, Ownable {
    using SafeERC20 for IERC20;

    error NotCreditManager();
    error ZeroAddress();
    error ZeroAmount();
    error RenounceDisabled();
    error InsufficientLiquidity(uint256 requested, uint256 availableNow);

    event CreditManagerSet(address indexed creditManager);
    event Funded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Lent(uint256 amount);
    event PrincipalRepaid(uint256 amount);

    IERC20 public immutable usdc;
    address public creditManager;

    /// @notice Principal currently out on loan. Book-keeping only; the CreditManager
    ///         is the authority on per-borrower debt.
    uint256 public outstandingPrincipal;

    modifier onlyCreditManager() {
        if (msg.sender != creditManager) revert NotCreditManager();
        _;
    }

    constructor(IERC20 usdc_, address initialOwner) Ownable(initialOwner) {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
    }

    // ── Wiring ───────────────────────────────────────────────────────────────

    function setCreditManager(address creditManager_) external onlyOwner {
        if (creditManager_ == address(0)) revert ZeroAddress();
        creditManager = creditManager_;
        emit CreditManagerSet(creditManager_);
    }

    /// @dev Renouncing would strand the float with no way to withdraw it.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── Treasury ─────────────────────────────────────────────────────────────

    /// @notice Add USDC to the lending float. Permissionless: anyone may top it up,
    ///         only the owner can take it back out.
    function fund(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Withdraw idle USDC. Cannot touch principal that is out on loan,
    ///         because that USDC is not here to withdraw.
    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit Withdrawn(to, amount);
        usdc.safeTransfer(to, amount);
    }

    // ── ILiquiditySource ─────────────────────────────────────────────────────

    /// @inheritdoc ILiquiditySource
    function lend(uint256 amount) external onlyCreditManager {
        uint256 idle = usdc.balanceOf(address(this));
        if (amount > idle) revert InsufficientLiquidity(amount, idle);
        outstandingPrincipal += amount;
        emit Lent(amount);
        usdc.safeTransfer(creditManager, amount);
    }

    /// @inheritdoc ILiquiditySource
    /// @dev Pulls against the allowance the CreditManager set immediately before the
    ///      call, so the transfer and the accounting cannot come apart.
    function repayPrincipal(uint256 amount) external onlyCreditManager {
        if (amount == 0) revert ZeroAmount();
        // Tolerate repaying more than was drawn (yield can exceed principal); the
        // surplus simply becomes idle float rather than underflowing the counter.
        outstandingPrincipal = amount > outstandingPrincipal ? 0 : outstandingPrincipal - amount;
        emit PrincipalRepaid(amount);
        usdc.safeTransferFrom(creditManager, address(this), amount);
    }

    /// @inheritdoc ILiquiditySource
    function available() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
