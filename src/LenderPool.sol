// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LenderPool (skeleton — PRD §4.2)
/// @notice ERC-4626 vault over native USDC. Lends to CreditManager only. Share
///         price rises with the lender share of harvested yield; shortfalls after
///         auction + insurance fund are socialised via share price — this must be
///         prominent in lender docs.
/// @dev Deliberately not `is ILenderPool` yet to avoid interface/event inheritance
///      friction while stubbed; the queue + lending functions land in phase 4 and
///      the interface conformance test comes with them.
///      TODO(phase-4): FIFO withdrawal queue (withdraw/redeem overrides honouring
///      hot float), reserveRatio management, loss socialisation.
contract LenderPool is ERC4626, Ownable, ReentrancyGuard {
    error NotImplemented();
    error NotCreditManager();
    error NotEpochHarvester();
    error ZeroAddress();
    error RenounceDisabled();

    event Lent(uint256 amount);
    event PrincipalRepaid(uint256 amount);
    event YieldDistributed(uint256 amount);
    event LossSocialised(uint256 amount);
    event WithdrawalQueued(address indexed lender, uint256 indexed queueIndex, uint256 assets);
    event QueuedWithdrawalServiced(address indexed lender, uint256 indexed queueIndex, uint256 assets);

    address public creditManager;
    address public epochHarvester;

    /// @notice USDC currently lent out, carried at face value less socialised loss
    ///         (debts are written down by yield, not defaulted — PRD §4.2).
    /// @dev Zero until lend() lands (phase 4); the zero default is the correct value.
    // slither-disable-next-line uninitialized-state
    uint256 public outstandingPrincipal;

    constructor(IERC20 usdc_, address initialOwner)
        ERC20("Recoup Lender Pool", "rcUSDC")
        ERC4626(usdc_)
        Ownable(initialOwner)
    {
        if (address(usdc_) == address(0)) revert ZeroAddress();
    }

    /// @dev Matches the live-authority contracts: renouncing would permanently
    ///      freeze wiring on a contract the deploy script already deploys.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    function setCreditManager(address creditManager_) external onlyOwner {
        if (creditManager_ == address(0)) revert ZeroAddress();
        creditManager = creditManager_;
    }

    function setEpochHarvester(address epochHarvester_) external onlyOwner {
        if (epochHarvester_ == address(0)) revert ZeroAddress();
        epochHarvester = epochHarvester_;
    }

    // ── Accounting ───────────────────────────────────────────────────────────

    /// @notice idle USDC + outstanding principal (PRD §4.2)
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + outstandingPrincipal;
    }

    // ── Pool ↔ protocol flows ────────────────────────────────────────────────

    function lend(uint256) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        revert NotImplemented(); // TODO(phase-4)
    }

    function repayPrincipal(uint256) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        revert NotImplemented(); // TODO(phase-4)
    }

    function distributeYield(uint256) external nonReentrant {
        if (msg.sender != epochHarvester) revert NotEpochHarvester();
        revert NotImplemented(); // TODO(phase-4)
    }

    function socialiseLoss(uint256) external {
        revert NotImplemented(); // TODO(phase-4): CreditManager only; emit loudly
    }

    function queuePosition(address) external view returns (uint256, uint256) {
        revert NotImplemented(); // TODO(phase-4)
    }
}
