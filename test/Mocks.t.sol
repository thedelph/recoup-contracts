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
    address internal phantom = makeAddr("phantom");

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

    // -- the owner-written third reward leg ----------------------------------
    //
    // Filed by audit round 35. The live DexFi farm carries a reward component its owner
    // can write directly: `pendingShare` adds it in unconditionally, while every settle
    // path pays it only inside `if (pending > 0)` and otherwise leaves it untouched.
    // `A6PhantomRecovery.fork.t.sol` measures that on the real farm, but it self-skips,
    // so nothing in an ordinary run held this mock to it - and while the mock denied the
    // component existed, every negative test written against it was evidence about a
    // stricter world than we deploy into. These four pin the fixture to the real one.

    /// @notice Inert by default, on both legs. This is the neutrality half of the model:
    ///         it is what lets the fixture gain the model without any of the many suites
    ///         built on it having to change, in or out of this tree.
    function test_userDebtDefaultsToZeroAndLeavesPendingShareUntouched() public {
        farm.setPendingYield(phantom, 7e6);
        assertEq(farm.userDebt(phantom), 0, "userDebt starts at zero");
        assertEq(farm.pendingShare(phantom), 7e6, "pendingShare is the ordinary leg alone");
    }

    /// @notice `pendingShare` reports the planted component even though the address has
    ///         never staked. This is the read that defeats a `pendingShare == 0` check.
    function test_pendingShareReportsPlantedUserDebtOnAZeroStakeAddress() public {
        farm.setUserDebt(phantom, 100e6);

        (uint256 stakedAmount,) = farm.userInfo(phantom);
        assertEq(stakedAmount, 0, "the address never staked");
        assertEq(farm.pendingShare(phantom), 100e6, "pendingShare reports the planted debt anyway");
    }

    /// @notice And the claim never arrives. `withdraw(0)` is the claim entrypoint, it
    ///         returns cleanly, it pays nothing, and it does not clear the component - so
    ///         the state is permanent rather than momentary. The permanence is the point;
    ///         a mock that cleared it would model a farm that self-heals.
    function test_withdrawZeroNeitherPaysNorClearsPlantedUserDebt() public {
        farm.setUserDebt(phantom, 100e6);

        vm.prank(phantom);
        farm.withdraw(0);

        assertEq(usdc.balanceOf(phantom), 0, "nothing was paid");
        assertEq(farm.userDebt(phantom), 100e6, "and nothing was cleared");
        assertEq(farm.pendingShare(phantom), 100e6, "so the phantom balance is permanent");
    }

    /// @notice The other side of the same asymmetry: the component IS collectable, but
    ///         only as a passenger on a real pending balance. Asserting both directions is
    ///         what stops the model degenerating into "userDebt is simply unpayable",
    ///         which would be a different farm from the one on Base.
    function test_plantedUserDebtIsPaidAndClearedOnlyAlongsideARealPendingBalance() public {
        farm.setUserDebt(phantom, 100e6);
        farm.setPendingYield(phantom, 3e6);

        vm.prank(phantom);
        farm.withdraw(0);

        assertEq(usdc.balanceOf(phantom), 103e6, "both legs paid together");
        assertEq(farm.userDebt(phantom), 0, "and the planted leg is cleared");
        assertEq(farm.pendingShare(phantom), 0, "leaving nothing behind");
    }
}
