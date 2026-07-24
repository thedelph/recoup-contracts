// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Config} from "../Config.sol";
import {ICustodyAdapter} from "../interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../interfaces/IDexFiFarm.sol";

/// @title DirectCallAdapter (PRD §4.1)
/// @notice Custody backend where the protocol itself holds and works the DexFi
///         position: this contract is the farm staker and the address DexFi must
///         add to the bond transfer whitelist (§14 ask #5). Holds no USDC at rest —
///         every claim is forwarded to the vault in the same call.
/// @dev Only the CollateralVault may call state-changing functions. The adapter is
///      deliberately dumb: no accounting, no parameters — all ownership bookkeeping
///      lives in the vault, so swapping to SafeAdapter later changes custody, not
///      accounting.
contract DirectCallAdapter is ICustodyAdapter, ERC1155Holder {
    using SafeERC20 for IERC20;

    error NotVault();
    error ReceiverMustBeAdapter(address receiver);
    error PaymentMismatch(uint256 expected, uint256 actual);

    IDexFiBond public immutable bond;
    IDexFiFarm public immutable farm;
    IERC20 public immutable usdc;
    address public immutable vault;

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(IDexFiBond bond_, IDexFiFarm farm_, IERC20 usdc_, address vault_) {
        bond = bond_;
        farm = farm_;
        usdc = usdc_;
        vault = vault_;
        // Standing approval so stake() can move bond units into the farm.
        bond_.setApprovalForAll(address(farm_), true);
    }

    /// @inheritdoc ICustodyAdapter
    function mintBonds(bytes calldata mintData) external payable onlyVault returns (uint256 amount) {
        IDexFiBond.MintDataInput memory data = abi.decode(mintData, (IDexFiBond.MintDataInput));
        // Bonds auto-stake for the receiver on mint; custody must land here.
        if (data.receiver != address(this)) revert ReceiverMustBeAdapter(data.receiver);
        if (msg.value != data.paymentAmount) revert PaymentMismatch(data.paymentAmount, msg.value);

        (uint256 stakedBefore,) = farm.userInfo(address(this));
        bond.mint{value: msg.value}(data);
        // Defensive: if DexFi ever mints without a reward pool set, stake manually.
        uint256 loose = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        if (loose > 0) farm.deposit(loose);
        (uint256 stakedAfter,) = farm.userInfo(address(this));
        amount = stakedAfter - stakedBefore;
    }

    /// @inheritdoc ICustodyAdapter
    function stake(uint256 amount) external onlyVault {
        farm.deposit(amount);
    }

    /// @inheritdoc ICustodyAdapter
    function unstake(uint256 amount) external onlyVault {
        // The farm pays any pending USDC alongside a withdrawal — sweep it so
        // yield is never stranded on the adapter.
        farm.withdraw(amount);
        _sweepUsdc();
    }

    /// @inheritdoc ICustodyAdapter
    function claimYield() external onlyVault returns (uint256 usdcAmount) {
        farm.withdraw(0); // withdraw(0) = claim, verified on-chain behaviour
        usdcAmount = _sweepUsdc();
    }

    /// @inheritdoc ICustodyAdapter
    function transferBonds(address to, uint256 amount) external onlyVault {
        bond.safeTransferFrom(address(this), to, Config.DEXFI_BOND_TOKEN_ID, amount, "");
    }

    function _sweepUsdc() internal returns (uint256 amount) {
        amount = usdc.balanceOf(address(this));
        if (amount > 0) usdc.safeTransfer(vault, amount);
    }
}
