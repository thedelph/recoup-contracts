// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {LiquidationAuction} from "../../src/LiquidationAuction.sol";
import {ICreditManager} from "../../src/interfaces/ICreditManager.sol";

/// @notice A contract bidder that accepts the lot normally.
/// @dev Exists because every seize test in this repo has historically targeted an EOA,
///      and an EOA destination skips the ERC-1155 acceptance check entirely. That is
///      exactly how audit round 2 finding #8 stayed invisible: the auction was missing
///      `ERC1155Holder` and no test could see it.
contract ContractBidder is ERC1155Holder {
    function bid(LiquidationAuction auction, IERC20 usdc, uint256 auctionId) external {
        usdc.approve(address(auction), type(uint256).max);
        auction.bid(auctionId);
    }
}

/// @notice A contract bidder with no ERC-1155 receiver hook at all.
/// @dev Its bid must revert, cleanly and atomically, rather than burning the lot.
contract RejectingBidder {
    function bid(LiquidationAuction auction, IERC20 usdc, uint256 auctionId) external {
        usdc.approve(address(auction), type(uint256).max);
        auction.bid(auctionId);
    }
}

/// @notice A bidder that re-enters the protocol from inside the ERC-1155 callback.
/// @dev The callback fires while the winner is being paid the lot, which is the one
///      moment the auction hands control to arbitrary code. `nonReentrant` covers
///      `bid`, but not `CreditManager.settle`, `repayFor` or `liquidate` - so this
///      exists to prove the auction is already closed and de-registered by then, and
///      that the settlement figures are read *after* the callback rather than before.
///
///      Everything is attempted in `try` so the callback cannot revert the bid it is
///      supposed to be probing; the flags record what actually got through.
contract ReentrantBidder is ERC1155Holder {
    LiquidationAuction public auction;
    ICreditManager public credit;
    IERC20 public usdc;
    address public borrower;
    uint256 public auctionId;

    uint256 public repayInsideCallback;
    bool public reBidSucceeded;
    bool public reLiquidateSucceeded;
    bool public callbackRan;

    function arm(
        LiquidationAuction auction_,
        ICreditManager credit_,
        IERC20 usdc_,
        address borrower_,
        uint256 repayAmount
    ) external {
        auction = auction_;
        credit = credit_;
        usdc = usdc_;
        borrower = borrower_;
        repayInsideCallback = repayAmount;
    }

    function bid(uint256 auctionId_) external {
        auctionId = auctionId_;
        usdc.approve(address(auction), type(uint256).max);
        usdc.approve(address(credit), type(uint256).max);
        auction.bid(auctionId_);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        callbackRan = true;

        try auction.bid(auctionId) {
            reBidSucceeded = true;
        } catch {}

        try credit.liquidate(borrower) {
            reLiquidateSucceeded = true;
        } catch {}

        if (repayInsideCallback != 0) {
            try credit.repayFor(borrower, repayInsideCallback) {} catch {}
        }

        return this.onERC1155Received.selector;
    }
}
