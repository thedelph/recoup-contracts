// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IEpochHarvester} from "./interfaces/IEpochHarvester.sol";
import {ICustodyAdapter} from "./interfaces/ICustodyAdapter.sol";
import {ICreditManager} from "./interfaces/ICreditManager.sol";

/// @title EpochHarvester (skeleton — PRD §4.4)
/// @notice Claims farm USDC weekly and applies the YieldSplit: borrower debt
///         write-down (pro-rata by bond count), lender share, insurance fund,
///         protocol fee. Permissionless with Config.MIN_EPOCH_GAP cooldown so a
///         missing keeper can't brick it. Zero-yield epochs are a no-op with event.
/// @dev TODO(phase-3): implement harvest + ≥200-position batch settlement
///      (harvestRange pagination fallback per PRD §6.2), dust handling.
contract EpochHarvester is IEpochHarvester, Ownable, ReentrancyGuard {
    error NotImplemented();
    error EpochGapNotElapsed();
    error ZeroAddress();
    error RenounceDisabled();

    IERC20 public immutable usdc;
    ICreditManager public immutable creditManager;
    ICustodyAdapter public custodyAdapter;
    address public lenderPool;
    address public protocolFeeWallet;

    /// @inheritdoc IEpochHarvester
    uint256 public override lastHarvestAt;
    uint256 public epochCount;

    constructor(IERC20 usdc_, ICreditManager creditManager_, address initialOwner) Ownable(initialOwner) {
        if (address(usdc_) == address(0) || address(creditManager_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
        creditManager = creditManager_;
    }

    /// @dev Matches the live-authority contracts: renouncing would permanently
    ///      freeze wiring on a contract the deploy script already deploys.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    function setCustodyAdapter(ICustodyAdapter adapter) external onlyOwner {
        if (address(adapter) == address(0)) revert ZeroAddress();
        custodyAdapter = adapter;
    }

    function setLenderPool(address lenderPool_) external onlyOwner {
        if (lenderPool_ == address(0)) revert ZeroAddress();
        lenderPool = lenderPool_;
    }

    function setProtocolFeeWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        protocolFeeWallet = wallet;
    }

    // ── IEpochHarvester ──────────────────────────────────────────────────────

    /// @inheritdoc IEpochHarvester
    function harvest() external nonReentrant {
        revert NotImplemented(); // TODO(phase-3): claim → split → applyYield per borrower → distribute
    }

    /// @inheritdoc IEpochHarvester
    function harvestRange(uint256, uint256) external nonReentrant {
        revert NotImplemented(); // TODO(phase-3)
    }
}
