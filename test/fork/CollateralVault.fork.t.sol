// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockLiquidationAuction} from "../mocks/MockLiquidationAuction.sol";
import {Config} from "../../src/Config.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {DirectCallAdapter} from "../../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";
import {MockNavOracle} from "../mocks/MockNavOracle.sol";

/// @notice Base mainnet fork tests against the LIVE DexFi contracts (PRD Phase 1
///         integration proof). Run with:
///           RUN_FORK_TESTS=true BASE_RPC_URL=<rpc> forge test --mc Fork -vv
///         (BASE_RPC_URL defaults to the public endpoint; an archive/paid RPC is
///         faster and less flaky.)
///
///         Proves, on real state:
///         1. the Config addresses are the live contracts and behave as documented;
///         2. without DexFi whitelisting, deposits revert at the bond's gate
///            (today's mainnet reality);
///         3. ONE `addWhitelist([adapter])` from DexFi's owner (impersonated here -
///            this is exactly §14 ask #5) unlocks the full lifecycle:
///            deposit → stake → claim (withdraw(0)) → unstake → withdraw.
contract CollateralVaultForkTest is Test {
    IDexFiBond internal bond = IDexFiBond(Config.DEXFI_BOND_NFT);
    IDexFiFarm internal farm = IDexFiFarm(Config.DEXFI_FARM);
    IERC20 internal usdc = IERC20(Config.USDC_BASE);

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");

    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    address internal treasury = makeAddr("treasury");

    bool internal run;

    function setUp() public {
        run = vm.envOr("RUN_FORK_TESTS", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));

        // makeAddr keys are public, and on Base mainnet someone has EIP-7702
        // -delegated the well-known "alice" address (code 0xef0100…), which then
        // fails ERC-1155 receiver checks. Strip any delegation so test accounts
        // behave as plain EOAs on the fork.
        vm.etch(alice, "");
        vm.etch(admin, "");

        vault = new CollateralVault(
            bond, INAVOracle(address(new MockNavOracle(25.15e8))), admin
        );
        adapter = new DirectCallAdapter(bond, farm, usdc, address(vault), admin, treasury);
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        // The vault refuses an auction pointer that is not a contract bound back to it,
        // so suites that never run a liquidation still need a stand-in.
        MockLiquidationAuction auctionStub = new MockLiquidationAuction();
        auctionStub.setVault(address(vault));
        vault.setLiquidationAuction(address(auctionStub));
        vm.stopPrank();

        // Source real bond units for alice: the farm holds the staked supply and is
        // whitelisted, so a farm-originated transfer passes the gate.
        vm.prank(Config.DEXFI_FARM);
        bond.safeTransferFrom(Config.DEXFI_FARM, alice, Config.DEXFI_BOND_TOKEN_ID, 10, "");
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);
    }

    function test_liveContractsMatchPhase0Findings() public {
        vm.skip(!run);
        assertEq(bond.TOKEN_ID(), Config.DEXFI_BOND_TOKEN_ID, "single fungible id 0");
        assertTrue(bond.whitelistContains(Config.DEXFI_FARM), "farm is whitelisted");
        assertEq(bond.rewardPool(), Config.DEXFI_FARM, "farm is the bond's reward pool");
        assertGt(bond.totalSupply(Config.DEXFI_BOND_TOKEN_ID), 100_000, "supply ~102k");
    }

    function test_depositRevertsUntilDexfiWhitelistsUs() public {
        vm.skip(!run);
        assertFalse(bond.whitelistContains(address(adapter)), "not whitelisted today");
        vm.prank(alice);
        vm.expectRevert(); // reverts inside the bond's whitelist gate
        vault.depositBonds(10);
    }

    function test_oneWhitelistCallUnlocksFullLifecycle() public {
        vm.skip(!run);

        // §14 ask #5, impersonated: DexFi's owner whitelists our adapter.
        address bondOwner = Config.DEXFI_TREASURY_EOA;
        address[] memory accounts = new address[](1);
        accounts[0] = address(adapter);
        vm.prank(bondOwner);
        bond.addWhitelist(accounts);
        assertTrue(bond.whitelistContains(address(adapter)));

        // deposit → staked in the live farm under the adapter
        vm.prank(alice);
        vault.depositBonds(10);
        (uint256 staked,) = farm.userInfo(address(adapter));
        assertEq(staked, 10);
        assertEq(vault.bondCount(alice), 10);

        // accrue real rewards, then claim via withdraw(0)
        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        uint256 claimed = vault.harvestYield();
        assertEq(usdc.balanceOf(treasury), claimed); // yield routed to the recipient
        assertGt(claimed, 0, "3 days of streaming rewards on 10 bonds");

        // unstake + withdraw back to the user
        vm.prank(alice);
        vault.withdrawBonds(10);
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), 10);
        (staked,) = farm.userInfo(address(adapter));
        assertEq(staked, 0);
        assertEq(vault.bondCount(alice), 0);
    }

    /// @notice A stake can be withdrawn in the same block it was created: DexFi's farm imposes no
    ///         lock, cooldown, epoch boundary or withdrawal charge on the bond units themselves.
    /// @dev    Written to settle the one open question gating the §14 ask #10 workaround. The
    ///         proposal there is a fresh CREATE2 receiver per mint attempt, so each attempt gets its
    ///         own nonce and users stop sharing one counter. The bonds auto-stake to whoever the
    ///         mint names as receiver, so that receiver has to be able to unwind *immediately* and
    ///         hand the position to the adapter, inside one user transaction. If the farm made a
    ///         fresh stake wait, the whole design would need a child-custody model instead.
    ///
    ///         `test_oneWhitelistCallUnlocksFullLifecycle` above looks like it covers this and does
    ///         not: it warps three days before withdrawing, to accrue rewards worth asserting on.
    ///         Three days of slack is exactly what would hide a cooldown.
    ///
    ///         Only the bond units are asserted here. Forfeiting *rewards* on an instant withdrawal
    ///         would be unsurprising and does not matter: a mint receiver holds the position for
    ///         one transaction, so it has no meaningful yield to lose.
    function test_freshStakeCanBeWithdrawnInTheSameBlock() public {
        vm.skip(!run);

        address bondOwner = Config.DEXFI_TREASURY_EOA;
        address[] memory accounts = new address[](1);
        accounts[0] = address(adapter);
        vm.prank(bondOwner);
        bond.addWhitelist(accounts);

        uint256 before = bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID);

        // No warp between these two calls, deliberately.
        vm.startPrank(alice);
        vault.depositBonds(10);
        (uint256 staked,) = farm.userInfo(address(adapter));
        assertEq(staked, 10, "staked into the live farm");
        vault.withdrawBonds(10);
        vm.stopPrank();

        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), before, "every unit came back");
        (staked,) = farm.userInfo(address(adapter));
        assertEq(staked, 0, "position fully unwound");
    }
}
