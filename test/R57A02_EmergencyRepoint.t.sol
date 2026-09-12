// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MinusOneManager} from "./R56A02_ManagerDoorLegs.t.sol";

/// @notice TEST-ONLY: a manager that CARRIES `claimableOf` but refuses it for the zero address, the
///         argument the auction's door probes with. Delegates everything else to the genuine runtime.
contract R57A02ZeroArgRefusingManager {
    address internal immutable _impl;

    constructor(address impl_) {
        _impl = impl_;
    }

    fallback() external payable {
        if (msg.sig == ICreditManager.claimableOf.selector) {
            address who = abi.decode(msg.data[4:], (address));
            if (who == address(0)) revert("zero account");
        }
        address impl = _impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @title R57A02 - round-57 items 220 and 224 residuals: what #514's four-member probe changes for an
///        owner who must REPOINT the manager
/// @notice Audit round 57, agent A2, target 6. The vault's manager door does not probe the four
///         members; the auction's does; and the ordering the auction insists on (the vault moves
///         FIRST, `CreditManagerNotLive` otherwise) plus the vault's one-way virgin rule means an owner
///         who sends the two legs as SEPARATE transactions to a manager lacking one member is left with
///         the pointers SPLIT: the vault on the new manager, the auction refusing it, and no way back
///         to the old one. Borrowing and liquidation are then offline protocol-wide until a THIRD,
///         complete, virgin manager is installed - which is possible, and is the recovery measured
///         here. Sent as ONE timelock batch, the refusal reverts both legs and nothing splits.
/// @dev Also measured: the probe's ARGUMENT is part of the door. A manager that carries `claimableOf`
///      but refuses it for `address(0)` is refused `CreditManagerDoesNotAnswer(claimableOf)`, a name
///      that says the member is absent when it is not. Info.
contract R57A02_EmergencyRepoint is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant EPOCH = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal one;
    LiquidationAuction internal auction;
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
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        one = _manager(bytes4(0), false);
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(one));
        vault.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(one));
        vm.stopPrank();
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();

        // Manager one distributes an epoch, so it is NOT virgin: the vault can never come back to it.
        usdc.mint(harvester, EPOCH);
        vm.startPrank(harvester);
        usdc.approve(address(one), EPOCH);
        one.receiveYield(EPOCH);
        one.distributeYield(EPOCH);
        vm.stopPrank();
        skip(1 days);
        one.accrueYield();
        require(one.accYieldPerBond() != 0, "fixture: manager one is still virgin");
    }

    /// @dev A fully wired manager with its own funded treasury. `removed != 0` etches it into a
    ///      `MinusOneManager` lacking that member (storage kept in place, the `R56A02` technique);
    ///      `zeroArg` etches it into the zero-argument-refusing variant instead.
    function _manager(bytes4 removed, bool zeroArg) internal returns (CreditManager m) {
        m = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        if (removed != bytes4(0) || zeroArg) {
            address implCopy = makeAddr(string.concat("impl-", vm.toString(address(m))));
            vm.etch(implCopy, address(m).code);
            if (zeroArg) {
                R57A02ZeroArgRefusingManager z = new R57A02ZeroArgRefusingManager(implCopy);
                vm.etch(address(m), address(z).code);
            } else {
                MinusOneManager proxy = new MinusOneManager(implCopy, removed, false);
                vm.etch(address(m), address(proxy).code);
            }
        }
        TreasuryLiquiditySource t = new TreasuryLiquiditySource(usdc, admin);
        usdc.mint(address(t), 100_000e6);
        vm.startPrank(admin);
        t.setCreditManager(address(m));
        m.setLiquiditySource(address(t));
        m.setEpochHarvester(harvester);
        m.setLiquidationAuction(address(auction));
        vm.stopPrank();
    }

    /// @notice MEASURED. Two separate owner transactions to a manager lacking `claimableOf`: the
    ///         vault takes it, the auction refuses it by name, the pointers are split, borrow is
    ///         refused `AuctionPointerMismatch`, and the vault cannot go back (`CreditManagerNotVirgin`).
    ///         A third, complete, virgin manager then restores both pointers and borrowing.
    function test_R57A02_224_measure_separateLegsSplitThePointersAndAThirdManagerRecovers() public {
        CreditManager two = _manager(ICreditManager.claimableOf.selector, false);

        vm.prank(admin);
        vault.setCreditManager(address(two));
        vm.prank(admin);
        (bool ok, bytes memory ret) = address(auction).call(abi.encodeCall(auction.setCreditManager, (address(two))));
        assertFalse(ok, "the auction admitted a manager lacking claimableOf");
        assertEq(
            ret,
            abi.encodeWithSelector(
                LiquidationAuction.CreditManagerDoesNotAnswer.selector, ICreditManager.claimableOf.selector
            ),
            "refused, but not by the four-member probe"
        );
        assertEq(vault.creditManager(), address(two), "premise: the vault moved");
        assertEq(auction.creditManager(), address(one), "premise: the auction did not");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.AuctionPointerMismatch.selector, address(one), address(two))
        );
        two.borrow(100e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.CreditManagerNotVirgin.selector, address(one)));
        vault.setCreditManager(address(one));

        CreditManager three = _manager(bytes4(0), false);
        vm.startPrank(admin);
        vault.setCreditManager(address(three));
        auction.setCreditManager(address(three));
        vm.stopPrank();
        vm.prank(alice);
        three.borrow(100e6);
        assertEq(three.debtOf(alice), 100e6, "borrowing did not come back on the third manager");
    }

    /// @notice CONTROL. The same two legs as ONE timelock batch: the auction's refusal reverts the
    ///         vault's leg with it, and nothing splits.
    function test_R57A02_224_control_oneBatchRevertsBothLegs() public {
        CreditManager two = _manager(ICreditManager.claimableOf.selector, false);
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        TimelockController tl = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
        vm.startPrank(admin);
        vault.transferOwnership(address(tl));
        auction.transferOwnership(address(tl));
        vm.stopPrank();

        address[] memory targets = new address[](2);
        targets[0] = address(vault);
        targets[1] = address(auction);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(CollateralVault.setCreditManager, (address(two)));
        payloads[1] = abi.encodeCall(LiquidationAuction.setCreditManager, (address(two)));
        vm.prank(admin);
        tl.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        skip(Config.ADMIN_TIMELOCK);
        vm.prank(admin);
        vm.expectRevert();
        tl.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        assertEq(vault.creditManager(), address(one), "the vault's leg survived the auction's refusal");
        assertEq(auction.creditManager(), address(one), "the auction moved");
    }

    /// @notice Info. A manager that carries `claimableOf` and refuses only the zero address is
    ///         refused under a name that says the member does not answer.
    function test_R57A02_224_info_theProbesArgumentIsPartOfTheDoor() public {
        CreditManager z = _manager(bytes4(0), true);
        assertEq(z.claimableOf(alice), 0, "premise: the member answers for a real account");
        vm.prank(admin);
        vault.setCreditManager(address(z));
        vm.prank(admin);
        (bool ok, bytes memory ret) = address(auction).call(abi.encodeCall(auction.setCreditManager, (address(z))));
        assertFalse(ok, "admitted");
        assertEq(
            ret,
            abi.encodeWithSelector(
                LiquidationAuction.CreditManagerDoesNotAnswer.selector, ICreditManager.claimableOf.selector
            ),
            "refused under another name"
        );
    }
}
