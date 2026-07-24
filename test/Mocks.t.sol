// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Smoke tests for the mock DexFi stack, mirroring the real contracts'
///         behaviour: fungible ERC-1155 bonds, whitelist-gated transfers,
///         deposit → withdraw(0)-claims → withdraw lifecycle.
contract MocksTest is Test {
    MockBond internal bond;
    MockUSDC internal usdc;
    MockFarm internal farm;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        bond = new MockBond();
        usdc = new MockUSDC();
        farm = new MockFarm(bond, usdc);
        // The real pool is on DexFi's transfer whitelist; mirror that.
        bond.setWhitelisted(address(farm), true);
    }

    function test_depositClaimWithdrawLifecycle() public {
        bond.mint(alice, 3);
        assertEq(bond.bondBalance(alice), 3);

        vm.startPrank(alice);
        bond.setApprovalForAll(address(farm), true);
        farm.deposit(3);
        vm.stopPrank();

        assertEq(bond.bondBalance(address(farm)), 3);
        assertEq(farm.staked(alice), 3);

        farm.setPendingYield(alice, 250e6);

        // withdraw(0) = claim only, mirroring the real pool
        vm.prank(alice);
        farm.withdraw(0);
        assertEq(usdc.balanceOf(alice), 250e6);
        assertEq(farm.staked(alice), 3);

        vm.prank(alice);
        farm.withdraw(3);
        assertEq(bond.bondBalance(alice), 3);
        assertEq(farm.staked(alice), 0);
    }

    function test_transfersAreWhitelistGated() public {
        bond.mint(alice, 1);
        uint256 id = bond.TOKEN_ID();

        // wallet → wallet with no whitelisted party reverts, like the real bond
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MockBond.AddressesNotWhitelisted.selector, alice, alice, bob)
        );
        bond.safeTransferFrom(alice, bob, id, 1, "");

        // whitelisting one party (e.g. our vault) unlocks the transfer
        bond.setWhitelisted(bob, true);
        vm.prank(alice);
        bond.safeTransferFrom(alice, bob, id, 1, "");
        assertEq(bond.bondBalance(bob), 1);
    }

    function test_withdrawRevertsBeyondStake() public {
        bond.mint(alice, 1);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(farm), true);
        farm.deposit(1);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, 2, 1));
        farm.withdraw(2);
        vm.stopPrank();
    }

    function test_emergencyWithdrawForfeitsRewards() public {
        bond.mint(alice, 2);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(farm), true);
        farm.deposit(2);
        vm.stopPrank();

        farm.setPendingYield(alice, 100e6);

        vm.prank(alice);
        farm.emergencyWithdraw();
        assertEq(bond.bondBalance(alice), 2);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(farm.pendingYield(alice), 0);
    }
}
