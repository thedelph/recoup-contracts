// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal USDC stand-in for unit tests and Base Sepolia (PRD §8).
/// @dev Also models real USDC's blacklist, because several paths exist purely to
///      survive it: the adapter's sweep is best-effort so a blocked recipient cannot
///      brick a collateral exit, and `unreportedYield` only ever becomes non-zero when
///      that sweep fails. Without a way to make a transfer fail, none of that is
///      reachable from a test.
contract MockUSDC is ERC20 {
    mapping(address => bool) public blocked;

    /// @notice Transfers to `account` return `false` instead of reverting or moving.
    /// @dev A second, different failure shape, and the suite had no way to express it.
    ///      Real USDC reverts, so this models the other well-known ERC-20 class - the
    ///      tokens that signal failure in the return value - which is what the adapter's
    ///      one raw `call` had to be checked against. Audit round 17 found that
    ///      `_trySweepUsdc` read "the call did not revert" as "the money moved"; with
    ///      only `blocked` available, no test in the tree could reach that branch.
    mapping(address => bool) public silentlyFails;

    error Blocked(address account);

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Make transfers to or from `account` revert, as USDC's blacklist does.
    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    /// @notice Make transfers to `account` return false, moving nothing, without reverting.
    function setSilentlyFails(address account, bool value) external {
        silentlyFails[account] = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (silentlyFails[to]) return false;
        return super.transfer(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}
