// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice What happens to live positions if DexFi revokes the adapter's transfer
///         whitelist entry after we are running. The whitelist is owner-managed and
///         revocable at any time (PRD §7 standing risk), so the blast radius needs to
///         be a known quantity rather than a discovery.
contract WhitelistRevocationTest is Test {
    uint256 internal constant NAV = 25.15e8;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal rescue = makeAddr("rescue");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );

        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        bond.mint(alice, 100);
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);

        vm.prank(alice);
        vault.depositBonds(100);
    }

    /// @dev Baseline: while whitelisted, the exit works.
    function test_withdrawWorksWhileWhitelisted() public {
        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), 100);
    }

    /// @dev The finding. Revoking the adapter strands live collateral: the farm can
    ///      still push bonds back to the adapter (the farm stays whitelisted, so the
    ///      from-side satisfies the gate), but the adapter cannot hand them on to a
    ///      non-whitelisted depositor. Deposits stopping is expected; exits breaking
    ///      is the part that matters.
    function test_revokingWhitelistStrandsExistingCollateral() public {
        bond.setWhitelisted(address(adapter), false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockBond.AddressesNotWhitelisted.selector, address(adapter), address(adapter), alice
            )
        );
        vault.withdrawBonds(100);
    }

    /// @dev And the break-glass hatch is gated by the same rule: emergencyUnstake
    ///      pulls bonds out of the farm fine, but cannot deliver them onward unless
    ///      the destination is itself whitelisted.
    function test_emergencyUnstakeAlsoBlockedToNonWhitelistedDestination() public {
        bond.setWhitelisted(address(adapter), false);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockBond.AddressesNotWhitelisted.selector, address(adapter), address(adapter), rescue
            )
        );
        adapter.emergencyUnstake(rescue);
    }

    /// @dev The one escape that survives revocation: a destination DexFi still has on
    ///      the whitelist. Worth knowing, because it is the only unwind that works
    ///      without DexFi re-adding us.
    function test_emergencyUnstakeSucceedsToWhitelistedDestination() public {
        bond.setWhitelisted(address(adapter), false);
        bond.setWhitelisted(rescue, true);

        vm.prank(admin);
        adapter.emergencyUnstake(rescue);
        assertEq(bond.balanceOf(rescue, Config.DEXFI_BOND_TOKEN_ID), 100);
    }
}
