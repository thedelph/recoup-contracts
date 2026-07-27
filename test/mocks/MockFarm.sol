// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./MockBond.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Stand-in for the DexFi reward pool ("RewardPoolBondsMigration"),
///         mirroring the verified contract's external behaviour: permissionless
///         deposit/withdraw of fungible bond units, `withdraw(0)` claims pending
///         USDC, emergencyWithdraw forfeits rewards. Reward accrual is
///         test-settable rather than time-based.
contract MockFarm is IDexFiFarm {
    MockBond public immutable bond;
    MockUSDC public immutable usdc;

    mapping(address => uint256) public staked;
    mapping(address => uint256) public pendingYield;
    uint256 public poolEndTime;

    error InsufficientStake(uint256 requested, uint256 available);
    error OnlyBond();

    constructor(MockBond bond_, MockUSDC usdc_) {
        bond = bond_;
        usdc = usdc_;
        poolEndTime = block.timestamp + 365 days;
    }

    /// @notice Auto-stake hook used by the bond's mint: tokens were minted straight
    ///         to this pool; only the staking credit is recorded here.
    /// @dev Settles pending rewards like every other deposit path. A MasterChef pool
    ///      pays out the whole position's accrued rewards whenever its stake changes,
    ///      and this hook is a deposit. Until it modelled that, the auto-stake mint
    ///      branch was the one farm-touching path no test could observe - the same
    ///      blind spot that hid the deposit-side leak a round earlier.
    function depositForAccount(address account, uint256 amount) external {
        if (msg.sender != address(bond)) revert OnlyBond();
        uint256 pending = pendingYield[account];
        pendingYield[account] = 0;
        if (pending > 0) usdc.mint(account, pending);
        staked[account] += amount;
    }

    function pendingShare(address account) external view returns (uint256) {
        return pendingYield[account];
    }

    /// @notice Test helper: set the USDC a staker will receive on next claim/withdraw.
    function setPendingYield(address staker, uint256 amount) external {
        pendingYield[staker] = amount;
    }

    /// @notice Test helper: make `withdraw` revert, modelling DexFi pausing rewards or
    ///         shipping a proxy upgrade that breaks the call. Their farm is behind a
    ///         UUPS proxy owned by a single EOA, so this is a live possibility rather
    ///         than a hypothetical, and several paths exist to survive it.
    bool public revertOnWithdraw;

    function setRevertOnWithdraw(bool value) external {
        revertOnWithdraw = value;
    }

    /// @dev Settles pending rewards, exactly as `withdraw` does. MasterChef-style
    ///      pools pay out on deposit as well, and the real one is one of those. Until
    ///      this mirrored that, no test could see USDC arriving on a stake - which is
    ///      the whole reason `stake()` and `mintBonds` measure their own balance.
    function deposit(uint256 amount) external {
        uint256 pending = pendingYield[msg.sender];
        pendingYield[msg.sender] = 0;
        if (pending > 0) usdc.mint(msg.sender, pending);
        bond.safeTransferFrom(msg.sender, address(this), bond.TOKEN_ID(), amount, "");
        staked[msg.sender] += amount;
    }

    error FarmDown();

    function withdraw(uint256 amount) external {
        if (revertOnWithdraw) revert FarmDown();
        if (amount > staked[msg.sender]) revert InsufficientStake(amount, staked[msg.sender]);
        uint256 pending = pendingYield[msg.sender];
        pendingYield[msg.sender] = 0;
        if (pending > 0) usdc.mint(msg.sender, pending);
        if (amount > 0) {
            staked[msg.sender] -= amount;
            bond.safeTransferFrom(address(this), msg.sender, bond.TOKEN_ID(), amount, "");
        }
    }

    function emergencyWithdraw() external {
        uint256 amount = staked[msg.sender];
        staked[msg.sender] = 0;
        pendingYield[msg.sender] = 0;
        bond.safeTransferFrom(address(this), msg.sender, bond.TOKEN_ID(), amount, "");
    }

    function userInfo(address account) external view returns (uint256 amount, uint256 rewardDebt) {
        return (staked[account], 0);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
