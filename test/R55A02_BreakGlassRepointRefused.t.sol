// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R55A02 - after a break-glass exit, no path re-stakes without crediting, and the repoint
///        over the insolvent ledger is now refused by name
/// @notice Round-55 item 218. `emergencyUnstake` moves every bond to a rescue wallet and leaves
///         `totalBondCount` standing; `setCustodyAdapter` then ACCEPTED a fresh, empty adapter
///         because the OUTGOING stake is zero. Enumerated here by execution: the only ways bonds
///         re-enter the farm under this vault are `depositBonds` (credits the depositor) and the
///         mint path (credits the beneficiary), and a raw transfer to the adapter stakes nothing.
///         Since round 56 (A1) both of those paths refuse `CustodyInsolvent()` while custody does
///         not back the ledger, which is the state the hatch leaves; the `enumerate_` case pins it.
///
/// @dev Fix: `setCustodyAdapter` decodes the incoming `stakedBalance()` it already probes and
///      refuses `incoming < totalBondCount` as `CustodyWouldBeInsolvent(incoming, ledger)`. Keyed
///      on the incoming stake so a PRE-STAKED repair adapter is admitted - the one on-chain repair
///      shape that exists - and an empty one over a non-empty ledger is named. `fix_` is RED at
///      9a01996; `control_`, `negative_` and `enumerate_` are green on both trees.
contract R55A02_BreakGlassRepointRefused is Test {
    bytes4 internal constant WOULD_BE_INSOLVENT = bytes4(keccak256("CustodyWouldBeInsolvent(uint256,uint256)"));
    /// @dev Round 56 (A1). Spelled as a signature rather than `CollateralVault.CustodyInsolvent`, so
    ///      this file still compiles against a vault without the error and a neuter reads RED
    ///      rather than failing to build.
    bytes4 internal constant CUSTODY_INSOLVENT = bytes4(keccak256("CustodyInsolvent()"));
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal rescueWallet = makeAddr("rescueWallet");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            admin
        );
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = _newAdapter();
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        treasury = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
        usdc.mint(address(treasury), TREASURY_FLOAT);

        _seed(alice, BONDS);
        _seed(bob, BONDS);
    }

    function _newAdapter() internal returns (DirectCallAdapter a) {
        a = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        bond.setWhitelisted(address(a), true);
    }

    function _seed(address who, uint256 bonds) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _breakGlass() internal {
        vm.prank(admin);
        adapter.emergencyUnstake(rescueWallet);
        assertEq(bond.balanceOf(rescueWallet, Config.DEXFI_BOND_TOKEN_ID), 2 * BONDS, "premise: bonds left custody");
        assertEq(adapter.stakedBalance(), 0, "premise: adapter holds nothing");
        assertEq(vault.totalBondCount(), 2 * BONDS, "premise: ledger unchanged");
        assertFalse(vault.custodyIsSolvent(), "premise: insolvent");
    }

    /// @notice ENUMERATED by execution: (i) a raw transfer of the rescued bonds back to the adapter
    ///         stakes nothing; (ii) the rescue wallet's `depositBonds` is REFUSED `CustodyInsolvent()`
    ///         since round 56, so no re-stake through the vault is possible while the ledger is
    ///         unbacked; (iii) by reading, `stake` is `onlyVault` and the vault's two callers of it
    ///         are `depositBonds` and the mint path, and since round 56 both refuse in this state.
    ///
    ///         History, kept because it is why (ii) reads as it does: at round 55 this deposit was
    ///         ACCEPTED - staked, but credited to the RESCUE WALLET, so the original depositors
    ///         stayed unbacked and the ledger grew to 300 over a stake of 100. Round 56 (A1) measured
    ///         the worse half of that shape - a fresh depositor's bonds withdrawable by a pre-hatch
    ///         ledger entry - and `CollateralVault` now refuses both deposit paths while
    ///         `custodyIsSolvent()` is false. Recovery re-stakes go through the OWNER path - a
    ///         pre-staked repair adapter installed by `setCustodyAdapter`
    ///         (`negative_aPreStakedRepairAdapterIsAdmitted` below) - not through vault deposits.
    function test_R55A02_218_enumerate_noReStakePathCreditsNobody() public {
        _breakGlass();

        // (i) raw transfer to the adapter: sits loose, never staked.
        vm.prank(rescueWallet);
        bond.safeTransferFrom(rescueWallet, address(adapter), Config.DEXFI_BOND_TOKEN_ID, BONDS, "");
        assertEq(bond.balanceOf(address(adapter), Config.DEXFI_BOND_TOKEN_ID), BONDS, "loose on the adapter");
        assertEq(adapter.stakedBalance(), 0, "not staked");
        assertFalse(vault.custodyIsSolvent(), "still insolvent");

        // (ii) the rescue wallet tries to deposit the rest through the vault: refused by name, and
        // nothing moves. Recovery re-stakes go through the owner path, not vault deposits.
        vm.startPrank(rescueWallet);
        bond.setApprovalForAll(address(vault), true);
        vm.expectRevert(CUSTODY_INSOLVENT);
        vault.depositBonds(BONDS);
        vm.stopPrank();
        assertEq(vault.bondCount(rescueWallet), 0, "the rescue wallet became a depositor");
        assertEq(vault.totalBondCount(), 2 * BONDS, "the ledger moved");
        assertEq(adapter.stakedBalance(), 0, "something was staked");
        assertEq(bond.balanceOf(rescueWallet, Config.DEXFI_BOND_TOKEN_ID), BONDS, "the refused bonds left the wallet");
        assertFalse(vault.custodyIsSolvent(), "alice and bob are still unbacked");
    }

    function test_R55A02_218_fix_aRepointOverAnUnbackedLedgerIsRefusedByName() public {
        _breakGlass();
        DirectCallAdapter fresh = _newAdapter();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(WOULD_BE_INSOLVENT, uint256(0), 2 * BONDS));
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));
        assertEq(address(vault.custodyAdapter()), address(adapter), "the pointer did not move");
    }

    /// @notice The one repair shape that can exist is admitted: an adapter already staked with the
    ///         rescued bonds backs the ledger, installs, and custody is solvent again.
    function test_R55A02_218_negative_aPreStakedRepairAdapterIsAdmitted() public {
        _breakGlass();
        DirectCallAdapter repair = _newAdapter();
        farm.seedStakeFor(address(repair), 2 * BONDS);
        assertEq(repair.stakedBalance(), 2 * BONDS, "premise: pre-staked");
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(repair)));
        assertEq(address(vault.custodyAdapter()), address(repair), "admitted");
        assertTrue(vault.custodyIsSolvent(), "and custody is solvent again");
    }

    /// @notice A partially-staked adapter is refused with both figures.
    function test_R55A02_218_fix_aShortRepairAdapterIsRefusedWithBothFigures() public {
        _breakGlass();
        DirectCallAdapter short_ = _newAdapter();
        farm.seedStakeFor(address(short_), BONDS);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(WOULD_BE_INSOLVENT, BONDS, 2 * BONDS));
        vault.setCustodyAdapter(ICustodyAdapter(address(short_)));
    }

    /// @notice CONTROL: the idle repoint - no depositors, outgoing stake zero - still installs.
    function test_R55A02_218_control_theIdleRepointStillInstalls() public {
        CollateralVault idle = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        DirectCallAdapter first = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(idle), admin, yieldSink
        );
        DirectCallAdapter second = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(idle), admin, yieldSink
        );
        vm.startPrank(admin);
        idle.setCustodyAdapter(ICustodyAdapter(address(first)));
        idle.setCustodyAdapter(ICustodyAdapter(address(second)));
        vm.stopPrank();
        assertEq(address(idle.custodyAdapter()), address(second), "idle repoint installs");
    }
}
