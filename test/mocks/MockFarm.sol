// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./MockBond.sol";
import {MockUSDC} from "./MockUSDC.sol";

import {MockLockdown} from "./MockLockdown.sol";

/// @notice Stand-in for the DexFi reward pool ("RewardPoolBondsMigration"),
///         mirroring the verified contract's external behaviour: permissionless
///         deposit/withdraw of fungible bond units, `withdraw(0)` claims pending
///         USDC, emergencyWithdraw forfeits rewards. Reward accrual is
///         test-settable rather than time-based.
contract MockFarm is IDexFiFarm, MockLockdown {
    MockBond public immutable bond;
    MockUSDC public immutable usdc;

    mapping(address => uint256) public staked;
    mapping(address => uint256) public pendingYield;
    mapping(address => uint256) public yieldAfterAutoDeposit;

    /// @notice The live farm's owner-written third reward component, modelled additively.
    /// @dev    `pendingShare` adds this in UNCONDITIONALLY, but every settle path pays it
    ///         only inside `if (pending > 0)` and otherwise leaves it untouched. So a
    ///         zero-stake address whose `userDebt` was planted reports a claimable balance
    ///         no call will ever pay and no call will ever clear - the state
    ///         `A6PhantomRecovery.fork.t.sol` measures on the real farm, and the state this
    ///         mock previously denied could exist, which made every negative test written
    ///         against it evidence about a stricter world than we deploy into.
    /// @dev    Defaults to zero, so every existing fixture behaves exactly as before.
    mapping(address => uint256) public userDebt;
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
        if (pending > 0) {
            pending += userDebt[account];
            userDebt[account] = 0;
            usdc.mint(account, pending);
        }
        staked[account] += amount;
        uint256 afterDeposit = yieldAfterAutoDeposit[account];
        if (afterDeposit != 0) {
            yieldAfterAutoDeposit[account] = 0;
            pendingYield[account] = afterDeposit;
        }
    }

    function pendingShare(address account) external view returns (uint256) {
        return pendingYield[account] + userDebt[account];
    }

    /// @notice Test helper: set the USDC a staker will receive on next claim/withdraw.
    function setPendingYield(address staker, uint256 amount) external gated {
        pendingYield[staker] = amount;
    }

    /// @notice Test helper: plant the owner-written reward component. Only DexFi's owner
    ///         can write it on the live farm; it is a plain setter here for the same
    ///         reason `setPendingYield` is.
    function setUserDebt(address staker, uint256 amount) external gated {
        userDebt[staker] = amount;
    }

    /// @notice Test hook that makes the child withdrawal settle a second reward
    ///         leg after the auto-deposit has already paid the first one.
    function setYieldAfterAutoDeposit(address staker, uint256 amount) external gated {
        yieldAfterAutoDeposit[staker] = amount;
    }

    /// @notice Test helper: install a staked baseline for `account` without originating a
    ///         transaction from it. 🟥 **It credits the LEDGER ONLY. No bonds are minted and the
    ///         pool does not hold what this credits** - the body is one line, `staked[account] +=
    ///         amount;`, and it never had a `_mint`.
    /// @dev    🟥 **This notice said "Back it by minting the bonds straight to this pool, so the
    ///         pool physically holds what it credits" from the commit that introduced it (#339)
    ///         until audit round 38 corrected it.** `git log -S` and `git show` both confirm the
    ///         body never matched the sentence. That sentence is the reason the function reads as
    ///         safe, and the gap between it and the body is exactly round-36 finding D2: an
    ///         unbacked credit here lets its holder withdraw collateral no bond backs. `gated`
    ///         keeps that reachable only by the mock stack's admin or operator, which is the
    ///         mitigation - the prose was never one.
    /// @dev    Exists because the only other ways to give an address a staked position both
    ///         make it unusable as a mint receiver. `deposit` credits `msg.sender`, so it
    ///         needs a transaction FROM the account - and under forge's **isolate execution
    ///         mode**, which became the default in 1.8.0 but is available on 1.7.1 too,
    ///         `vm.prank` leaves the pranked account's nonce incremented (0 -> 1 -> 2), after
    ///         which CREATE2 into that address fails EIP-684 with `FailedDeployment()`. MEASURED
    ///         2026-08-30 on both binaries: 1.7.1 default 0, 1.8.1 default 2, 1.8.1
    ///         `--no-isolate` 0, **1.7.1 `--isolate` 2**. The forge *version* is not the variable;
    ///         the execution mode is. The bond's auto-stake mint can credit
    ///         an arbitrary receiver, but it bumps `nonces[receiver]`, and
    ///         `DirectCallAdapter._validateMintAttempt` then rejects the attempt with
    ///         `MintAttemptAlreadyUsed`. A counterfactual address holds no key and originates
    ///         nothing in production, so seeding the state directly is the faithful model.
    function seedStakeFor(address account, uint256 amount) external gated {
        staked[account] += amount;
    }

    /// @notice Test helper: make `withdraw` revert, modelling DexFi pausing rewards or
    ///         shipping a proxy upgrade that breaks the call. Their farm is behind a
    ///         UUPS proxy owned by a single EOA, so this is a live possibility rather
    ///         than a hypothetical, and several paths exist to survive it.
    bool public revertOnWithdraw;

    function setRevertOnWithdraw(bool value) external gated {
        revertOnWithdraw = value;
    }

    /// @dev Settles pending rewards, exactly as `withdraw` does. MasterChef-style
    ///      pools pay out on deposit as well, and the real one is one of those. Until
    ///      this mirrored that, no test could see USDC arriving on a stake - which is
    ///      the whole reason `stake()` and `mintBonds` measure their own balance.
    function deposit(uint256 amount) external {
        uint256 pending = pendingYield[msg.sender];
        pendingYield[msg.sender] = 0;
        if (pending > 0) {
            pending += userDebt[msg.sender];
            userDebt[msg.sender] = 0;
            usdc.mint(msg.sender, pending);
        }
        bond.safeTransferFrom(msg.sender, address(this), bond.TOKEN_ID(), amount, "");
        staked[msg.sender] += amount;
    }

    error FarmDown();

    function withdraw(uint256 amount) external {
        if (revertOnWithdraw) revert FarmDown();
        if (amount > staked[msg.sender]) revert InsufficientStake(amount, staked[msg.sender]);
        uint256 pending = pendingYield[msg.sender];
        pendingYield[msg.sender] = 0;
        if (pending > 0) {
            pending += userDebt[msg.sender];
            userDebt[msg.sender] = 0;
            usdc.mint(msg.sender, pending);
        }
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
