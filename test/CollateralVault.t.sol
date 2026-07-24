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
import {MockCreditManager} from "./mocks/MockCreditManager.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Phase-1 lifecycle tests for CollateralVault + DirectCallAdapter against
///         the real-ABI mocks: deposit → stake → claim → unstake → withdraw → seize,
///         the whitelist gate, and the withdrawal LTV rule.
contract CollateralVaultTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp — 2026-07-24 real snapshot

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal auction = makeAddr("auction");
    address internal winner = makeAddr("winner");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    MockCreditManager internal credit;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);
        credit = new MockCreditManager();

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault)
        );

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(auction);
        vm.stopPrank();

        // Mirror mainnet: the farm is whitelisted; ask #5 whitelists our adapter.
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        bond.mint(alice, 1_000);
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);
    }

    // ── deposit / stake ──────────────────────────────────────────────────────

    function test_depositBonds_stakesViaAdapter() public {
        vm.prank(alice);
        vault.depositBonds(100);

        assertEq(vault.bondCount(alice), 100);
        assertEq(farm.staked(address(adapter)), 100);
        assertEq(bond.bondBalance(alice), 900);
        assertEq(bond.bondBalance(address(adapter)), 0); // custody sits in the farm
        assertEq(vault.collateralValue(alice), 100 * NAV);
    }

    function test_depositBonds_revertsWithoutWhitelist() public {
        // DexFi has not granted ask #5: adapter (and vault) unlisted ⇒ the
        // depositor→adapter transfer must hit the bond's whitelist gate.
        bond.setWhitelisted(address(adapter), false);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockBond.AddressesNotWhitelisted.selector, address(vault), alice, address(adapter)
            )
        );
        vault.depositBonds(100);
    }

    function test_depositBonds_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.depositBonds(0);
    }

    function test_depositBonds_pausable() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.depositBonds(100);
    }

    // ── depositETH (signed mint, auto-stake) ─────────────────────────────────

    function test_depositETH_mintsAndAutoStakes() public {
        bytes memory mintData = _mintData(address(adapter), 40, 1 ether);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vault.depositETH{value: 1 ether}(mintData);

        assertEq(vault.bondCount(alice), 40);
        assertEq(farm.staked(address(adapter)), 40);
    }

    function test_depositETH_receiverMustBeAdapter() public {
        bytes memory mintData = _mintData(alice, 40, 1 ether);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.ReceiverMustBeAdapter.selector, alice));
        vault.depositETH{value: 1 ether}(mintData);
    }

    // ── withdraw + LTV rule ──────────────────────────────────────────────────

    function test_withdrawBonds_debtFree() public {
        vm.startPrank(alice);
        vault.depositBonds(100);
        vault.withdrawBonds(100);
        vm.stopPrank();

        assertEq(vault.bondCount(alice), 0);
        assertEq(farm.staked(address(adapter)), 0);
        assertEq(bond.bondBalance(alice), 1_000);
    }

    function test_withdrawBonds_allowsWithinMaxLtv() public {
        vm.prank(alice);
        vault.depositBonds(100);
        // Debt sized so 80 remaining bonds sit exactly at maxLTV:
        // 80 bonds × $25.15 × 35% = $704.20
        credit.setDebt(alice, 704.2e6);

        vm.prank(alice);
        vault.withdrawBonds(20);
        assertEq(vault.bondCount(alice), 80);
    }

    function test_withdrawBonds_revertsBeyondMaxLtv() public {
        vm.prank(alice);
        vault.depositBonds(100);
        credit.setDebt(alice, 704.2e6);

        // One bond more than the maxLTV allows.
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawBonds(21);
    }

    function test_withdrawBonds_cannotEmptyVaultWithDebt() public {
        vm.prank(alice);
        vault.depositBonds(100);
        credit.setDebt(alice, 1e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.WithdrawalExceedsMaxLtv.selector, type(uint256).max)
        );
        vault.withdrawBonds(100);
    }

    function test_withdrawBonds_worksWhilePaused() public {
        vm.prank(alice);
        vault.depositBonds(100);
        vm.prank(admin);
        vault.pause();

        // Exits must never be pausable.
        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(bond.bondBalance(alice), 1_000);
    }

    function test_withdrawBonds_overdrawReverts() public {
        vm.prank(alice);
        vault.depositBonds(100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.InsufficientCollateral.selector, 101, 100));
        vault.withdrawBonds(101);
    }

    // ── yield ────────────────────────────────────────────────────────────────

    function test_harvestYield_sweepsToVault() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 500e6);

        vm.prank(admin);
        uint256 claimed = vault.harvestYield();

        assertEq(claimed, 500e6);
        assertEq(usdc.balanceOf(address(vault)), 500e6);
        assertEq(usdc.balanceOf(address(adapter)), 0); // adapter holds nothing at rest
    }

    function test_unstake_sweepsPendingYieldToo() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 123e6);

        // Farm pays pending USDC alongside any withdrawal; it must not strand.
        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(usdc.balanceOf(address(vault)), 123e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    // ── seize ────────────────────────────────────────────────────────────────

    function test_seize_movesWholePositionToWinner() public {
        vm.prank(alice);
        vault.depositBonds(100);

        vm.prank(auction);
        uint256 seized = vault.seize(alice, winner);

        assertEq(seized, 100);
        assertEq(vault.bondCount(alice), 0);
        assertEq(bond.bondBalance(winner), 100);
    }

    function test_seize_onlyAuction() public {
        vm.expectRevert(CollateralVault.NotLiquidationAuction.selector);
        vault.seize(alice, winner);
    }

    // ── adapter hardening ────────────────────────────────────────────────────

    function test_adapter_onlyVault() public {
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        adapter.stake(1);
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        adapter.claimYield();
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        adapter.transferBonds(alice, 1);
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_depositWithdraw_roundTrips(uint256 amount) public {
        amount = bound(amount, 1, 1_000);
        vm.startPrank(alice);
        vault.depositBonds(amount);
        vault.withdrawBonds(amount);
        vm.stopPrank();

        assertEq(vault.bondCount(alice), 0);
        assertEq(bond.bondBalance(alice), 1_000);
        assertEq(farm.staked(address(adapter)), 0);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _mintData(address receiver, uint256 amountNfts, uint256 payment)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            IDexFiBond.MintDataInput({
                uuid: 1,
                nonce: 0,
                receiver: receiver,
                amountNfts: amountNfts,
                paymentAmount: payment,
                deadline: block.timestamp + 1 hours,
                signature: ""
            })
        );
    }
}
