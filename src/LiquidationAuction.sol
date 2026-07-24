// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILiquidationAuction} from "./interfaces/ILiquidationAuction.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {INAVOracle} from "./interfaces/INAVOracle.sol";

/// @title LiquidationAuction (skeleton — PRD §4.5)
/// @notice One Dutch auction per liquidated position, whole lot. Linear decay from
///         startPremium×NAV to the floor over Config.AUCTION_DURATION. Unfilled
///         auctions fall back to the DexFi manual-redemption workout queue.
/// @dev TODO(phase-3): implement full lifecycle incl. expiry → workout fork test
///      (PRD §6.3 AC). Blocked on Phase 0 bond-transferability verdict: if bonds
///      can't transfer, this design is dead and liquidation is redemption-only.
contract LiquidationAuction is ILiquidationAuction, Ownable, ReentrancyGuard {
    error NotImplemented();
    error NotCreditManager();

    struct Auction {
        address borrower;
        uint96 startedAt;
        uint256 bondCount;
        uint256 startPrice; // USDC for the whole lot
        uint256 debt; // outstanding at start
        bool settled;
    }

    IERC20 public immutable usdc;
    ICollateralVault public immutable vault;
    INAVOracle public immutable navOracle;
    address public creditManager;

    uint256 public nextAuctionId;
    mapping(uint256 => Auction) public auctions;

    constructor(IERC20 usdc_, ICollateralVault vault_, INAVOracle navOracle_, address initialOwner)
        Ownable(initialOwner)
    {
        usdc = usdc_;
        vault = vault_;
        navOracle = navOracle_;
    }

    function setCreditManager(address creditManager_) external onlyOwner {
        creditManager = creditManager_;
    }

    // ── ILiquidationAuction ──────────────────────────────────────────────────

    /// @inheritdoc ILiquidationAuction
    function start(address) external returns (uint256) {
        if (msg.sender != creditManager) revert NotCreditManager();
        revert NotImplemented(); // TODO(phase-3)
    }

    /// @inheritdoc ILiquidationAuction
    function bid(uint256) external nonReentrant {
        revert NotImplemented(); // TODO(phase-3): pay → repay debt → surplus to borrower → bonds to winner
    }

    /// @inheritdoc ILiquidationAuction
    function expireToWorkout(uint256) external nonReentrant {
        revert NotImplemented(); // TODO(phase-3): workout queue + insurance fund → socialised loss
    }

    /// @inheritdoc ILiquidationAuction
    function currentPrice(uint256) external view returns (uint256) {
        revert NotImplemented(); // TODO(phase-3): linear decay startPrice → floor over AUCTION_DURATION
    }
}
