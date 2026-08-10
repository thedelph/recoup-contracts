// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Config} from "./Config.sol";

/// @title ProtocolFeeSplitter
/// @notice Splits Recoup's protocol fee between Recoup and DexFi on-chain, in the
///         `PROTOCOL_FEE_RECOUP_BPS` / `PROTOCOL_FEE_DEXFI_BPS` ratio agreed on
///         2026-08-06.
/// @dev Installed as `EpochHarvester.protocolFeeWallet`. That is the whole integration:
///      `flushProtocolFee` pays the fee out with a plain `safeTransfer`, so the fee
///      arrives here as an ordinary ERC-20 balance and **no core contract changes**.
///      A splitter is not the only way to honour the agreement - the alternative is
///      Chris sending DexFi a share every month - but a monthly transfer is a promise
///      and this is not. Both destinations are immutable and both shares are compiled
///      in, so once deployed neither party can redirect the other's leg, and neither
///      needs to trust the other to remember.
///
///      There is deliberately **no owner, no setter, no pause and no rescue**. An owner
///      is exactly the thing that would make the guarantee above untrue, and a contract
///      whose only job is to forward a fixed ratio to two fixed addresses has nothing an
///      owner could usefully do. The cost is that a token sent here by mistake is stuck;
///      that is accepted, and it is why `split()` is USDC-only rather than taking an
///      arbitrary token - a general sweep would be a way to move value that the fixed
///      ratio was meant to constrain.
contract ProtocolFeeSplitter {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error WalletsMustDiffer();
    error NothingToSplit();

    event FeeSplit(uint256 total, uint256 toRecoup, uint256 toDexFi);

    IERC20 public immutable usdc;

    /// @notice Recoup's leg. Referral rewards and the borrower rebate are funded from
    ///         this one alone, which is the promise `/refer` publishes.
    address public immutable recoupWallet;

    /// @notice DexFi's leg.
    address public immutable dexfiWallet;

    constructor(IERC20 usdc_, address recoupWallet_, address dexfiWallet_) {
        if (address(usdc_) == address(0) || recoupWallet_ == address(0) || dexfiWallet_ == address(0)) {
            revert ZeroAddress();
        }
        // Not paranoia: with one address on both legs the event would report a split
        // that did not happen, and the on-chain record is the only evidence either
        // party has that the agreement was honoured.
        if (recoupWallet_ == dexfiWallet_) revert WalletsMustDiffer();

        usdc = usdc_;
        recoupWallet = recoupWallet_;
        dexfiWallet = dexfiWallet_;
    }

    /// @notice Forward the whole balance to the two wallets in the agreed ratio.
    /// @dev Permissionless, and sized from this contract's own balance rather than from
    ///      an argument, so it cannot be told a figure that differs from what arrived.
    ///      Same reasoning as `EpochHarvester.harvest`, which sizes an epoch from the
    ///      adapter's balance for exactly this reason.
    ///
    ///      DexFi's leg is computed from the bps and Recoup's takes the remainder, so
    ///      the two always sum to precisely the balance and no dust is ever stranded
    ///      here. The direction of that rounding is worth one sentence: at most one wei
    ///      of USDC per split, and it goes to the party operating the contract, which
    ///      mirrors how `EpochHarvester` already hands the protocol slice the remainder
    ///      of the four-way split.
    ///
    ///      Reverts rather than no-opping on an empty balance, because a caller who
    ///      explicitly asked for a flush wants to know it did nothing - the same choice
    ///      `flushProtocolFee` makes.
    function split() external returns (uint256 toRecoup, uint256 toDexFi) {
        uint256 total = usdc.balanceOf(address(this));
        if (total == 0) revert NothingToSplit();

        toDexFi = (total * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS;
        toRecoup = total - toDexFi;

        emit FeeSplit(total, toRecoup, toDexFi);

        // DexFi's leg first. If either transfer reverts the whole call reverts and the
        // balance stays put, so a blacklisted or reverting destination cannot be used to
        // strand the other party's share in a partially-executed split.
        if (toDexFi != 0) usdc.safeTransfer(dexfiWallet, toDexFi);
        usdc.safeTransfer(recoupWallet, toRecoup);
    }

    /// @notice What a given amount would split into, without moving anything.
    /// @dev For the app and for DexFi's own reconciliation. Deliberately pure and
    ///      derived from the same expression `split` uses, so the two cannot disagree.
    function preview(uint256 amount) external pure returns (uint256 toRecoup, uint256 toDexFi) {
        toDexFi = (amount * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS;
        toRecoup = amount - toDexFi;
    }
}
