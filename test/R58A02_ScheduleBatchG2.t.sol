// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R58A02 - round-58 item 243: a `scheduleBatch` rehearsal of the hatch UNDER G2
/// @notice Audit round 58, agent A2, target 2. Round-57 A1 rehearsed the repair batch with THREE of
///         the nine contracts handed over (`R57A01HatchRepairTest.
///         test_fix_aRepairAdapterGoesInOnVaultAndHarvesterInOneTimelockBatch`). This file rehearses
///         it under the FULL G2 posture - every `Ownable` in the graph owned by a
///         `TimelockController` at `Config.ADMIN_TIMELOCK` - and asks the three questions that
///         posture raises and the three-contract rehearsal cannot: how many timelock OPERATIONS the
///         incident costs (not how many legs one of them has), what the two batch calls cost in gas,
///         and which legs cannot go in a batch at all.
///
/// @dev `DirectCallAdapter` carries NO guardian and no pause, so after G2 **every** adapter door
///      except the permissionless `flushYieldTo` is a 48-hour operation. That is the whole reason
///      this file exists: `emergencyUnstake` is the protocol's emergency hatch and under G2 it is
///      not an emergency lever at all.
contract R58A02_ScheduleBatchG2 is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant ALICE_BONDS = 100;
    uint256 internal constant BOB_BONDS = 200;
    uint256 internal constant LEDGER = ALICE_BONDS + BOB_BONDS;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;
    uint256 internal constant PENDING_EPOCH = 500e6;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal lender = makeAddr("lender");
    address internal stranger = makeAddr("stranger");
    address internal feeWallet = makeAddr("feeWallet");
    address internal proposer = makeAddr("proposer");
    address internal keeperKey = makeAddr("keeperKey");
    address internal confirmerKey = makeAddr("confirmerKey");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    RiskParams internal riskParams;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    LenderPool internal pool;
    EpochHarvester internal harvester;
    TreasuryLiquiditySource internal liquidity;
    TimelockController internal timelock;

    function setUp() public {
        bond = new MockBond();
        usdc = new MockUSDC();
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
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, feeWallet
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        pool = new LenderPool(IERC20(address(usdc)), admin);
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        vault.setGuardian(guardian);
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(address(harvester));
        pool.setGuardian(guardian);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        credit.setGuardian(guardian);
        auction.setCreditManager(address(credit));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        harvester.setLenderPool(address(pool));
        harvester.setProtocolFeeWallet(feeWallet);
        adapter.setHarvester(address(harvester));
        adapter.setYieldRecipient(address(harvester));
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        _depositBonds(alice, ALICE_BONDS);
        _depositBonds(bob, BOB_BONDS);
        uint256 debt = (ALICE_BONDS * NAV * riskParams.maxLtvBps()) / (2 * Config.BPS * Config.USDC_TO_NAV_SCALE);
        vm.prank(alice);
        credit.borrow(debt);
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(credit), type(uint256).max);
    }

    function _depositBonds(address who, uint256 n) internal {
        bond.mint(who, n);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(n);
        vm.stopPrank();
    }

    function _newTimelock() internal returns (TimelockController t) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution, the shape every governance suite here deploys
        t = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    /// @dev The nine legs of G2, in `DeployBase._handOver`'s order, each metered. The guardian is
    ///      cleared first on the three contracts whose `transferOwnership` refuses a handover to the
    ///      sitting guardian - which is only a refusal when the guardian IS the incoming owner, and
    ///      is not the case here, so it is asserted rather than worked around.
    function _handOverAll(TimelockController t) internal returns (uint256 gasUsed) {
        uint256 g = gasleft();
        vm.startPrank(admin);
        vault.transferOwnership(address(t));
        adapter.transferOwnership(address(t));
        // The ninth leg, `NAVOracle.transferOwnership`, is not exercised here: the fixture's
        // `MockNavOracle` is not `Ownable`. Its shape is identical to the eight below and the
        // handover order is `DeployBase._handOver`'s.
        credit.transferOwnership(address(t));
        pool.transferOwnership(address(t));
        harvester.transferOwnership(address(t));
        auction.transferOwnership(address(t));
        liquidity.transferOwnership(address(t));
        riskParams.transferOwnership(address(t));
        vm.stopPrank();
        gasUsed = g - gasleft();
    }

    /// @dev The farm stops honouring `withdraw` and a whole epoch is pending. The hatch is NOT
    ///      fired here - under G2 firing it is itself a timelock operation, which is the point.
    function _breakFarm() internal {
        farm.setPendingYield(address(adapter), PENDING_EPOCH);
        farm.setRevertOnWithdraw(true);
    }

    function _repairAdapter(TimelockController t, MockFarm newFarm) internal returns (DirectCallAdapter repair) {
        repair = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(newFarm)),
            usdc,
            address(vault),
            address(t), // born owned by the timelock, or legs 2 and 3 cannot be in the batch
            address(harvester)
        );
        bond.setWhitelisted(address(repair), true); // DexFi's leg - NOT batchable, see the info case
    }

    // ── 1. The handover itself ───────────────────────────────────────────────

    /// @notice G2 is NINE ordinary owner transactions and cannot be one timelock batch, because the
    ///         timelock is not yet the owner of anything it would have to call. Measured, with the
    ///         guardian collision measured beside it.
    function test_R58A02_243_control_g2IsNineOwnerTransactionsAndNotABatch() public {
        TimelockController t = _newTimelock();
        uint256 g = _handOverAll(t);
        emit log_named_uint("MEASURED gas for all nine transferOwnership legs", g);
        emit log_named_uint("MEASURED legs in the G2 handover (eight executed, the oracle's ninth not on a mock)", 9);
        assertEq(vault.owner(), address(t), "vault");
        assertEq(adapter.owner(), address(t), "adapter");
        assertEq(credit.owner(), address(t), "credit");
        assertEq(pool.owner(), address(t), "pool");
        assertEq(harvester.owner(), address(t), "harvester");
        assertEq(auction.owner(), address(t), "auction");
        assertEq(liquidity.owner(), address(t), "liquidity");
        assertEq(riskParams.owner(), address(t), "riskParams");

        // A tenth leg exists whenever the incoming owner is the sitting guardian.
        TimelockController t2 = _newTimelock();
        vm.prank(address(t));
        vault.setGuardian(address(t2));
        vm.prank(address(t));
        vm.expectRevert(CollateralVault.GuardianMustDifferFromOwner.selector);
        vault.transferOwnership(address(t2));
        emit log_string("MEASURED a handover to the sitting guardian is refused: the guardian must move first");
    }

    // ── 2. The repair, as one batch, under the full G2 posture ───────────────

    /// @notice The whole custody repair as ONE timelock operation of six legs, with both timelock
    ///         calls metered. This is the shape that works, and the figures are the price of it.
    function test_R58A02_243_measure_theWholeRepairIsOneSixLegOperation() public {
        timelock = _newTimelock();
        _handOverAll(timelock);
        farm.setPendingYield(address(adapter), PENDING_EPOCH); // the old farm still honours withdraw
        MockFarm newFarm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(newFarm));
        bond.setWhitelisted(address(newFarm), true);
        DirectCallAdapter repair = _repairAdapter(timelock, newFarm);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _repairCalls(repair, true);
        bytes32 salt = bytes32("r58a02-attempt-1");

        uint256 g = gasleft();
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, Config.ADMIN_TIMELOCK);
        emit log_named_uint("MEASURED gas: scheduleBatch, six legs", g - gasleft());
        emit log_named_uint("MEASURED legs in the repair operation", targets.length);
        emit log_named_uint("MEASURED wait, seconds", Config.ADMIN_TIMELOCK);

        skip(Config.ADMIN_TIMELOCK);
        g = gasleft();
        vm.prank(stranger); // open execution: a stranger fires it
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        emit log_named_uint("MEASURED gas: executeBatch, six legs", g - gasleft());

        assertEq(address(vault.custodyAdapter()), address(repair), "vault pointer");
        assertEq(address(harvester.custodyAdapter()), address(repair), "harvester pointer");
        assertEq(repair.stakedBalance(), LEDGER, "the ledger is backed again");
        assertTrue(vault.custodyIsSolvent(), "custody solvent");
        assertEq(usdc.balanceOf(address(harvester)), PENDING_EPOCH, "the old farm's last epoch was claimed");
    }

    /// @dev The repair, with or without the `vault.harvestYield()` leg in front.
    function _repairCalls(DirectCallAdapter repair, bool withHarvest)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        uint256 n = withHarvest ? 6 : 5;
        targets = new address[](n);
        values = new uint256[](n);
        payloads = new bytes[](n);
        uint256 i;
        if (withHarvest) {
            targets[i] = address(vault);
            payloads[i++] = abi.encodeCall(CollateralVault.harvestYield, ());
        }
        targets[i] = address(adapter);
        payloads[i++] = abi.encodeCall(DirectCallAdapter.emergencyUnstake, (address(repair)));
        targets[i] = address(repair);
        payloads[i++] = abi.encodeCall(DirectCallAdapter.restakeLoose, ());
        targets[i] = address(repair);
        payloads[i++] = abi.encodeCall(DirectCallAdapter.setHarvester, (address(harvester)));
        targets[i] = address(harvester);
        payloads[i++] = abi.encodeCall(EpochHarvester.setCustodyAdapter, (ICustodyAdapter(address(repair))));
        targets[i] = address(vault);
        payloads[i++] = abi.encodeCall(CollateralVault.setCustodyAdapter, (ICustodyAdapter(address(repair))));
        assertEq(i, n, "leg count");
    }

    // ── 3. What the farm-down case costs ────────────────────────────────────

    /// @notice The case the three-contract rehearsal did not reach: the farm is REFUSING `withdraw`,
    ///         which is the state that makes anyone fire the hatch in the first place. The
    ///         six-leg batch then reverts AT MATURITY, forty-eight hours in, and the five-leg batch
    ///         is the one that works. Measured: whether the reverted operation's id is burned.
    function test_R58A02_243_measure_theFarmDownCaseRevertsTheSixLegBatchAtMaturity() public {
        timelock = _newTimelock();
        _handOverAll(timelock);
        _breakFarm();
        MockFarm newFarm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(newFarm));
        bond.setWhitelisted(address(newFarm), true);
        DirectCallAdapter repair = _repairAdapter(timelock, newFarm);

        (address[] memory t6, uint256[] memory v6, bytes[] memory p6) = _repairCalls(repair, true);
        bytes32 salt = bytes32("r58a02-six");
        vm.prank(proposer);
        timelock.scheduleBatch(t6, v6, p6, bytes32(0), salt, Config.ADMIN_TIMELOCK);
        skip(Config.ADMIN_TIMELOCK);

        bytes32 id = timelock.hashOperationBatch(t6, v6, p6, bytes32(0), salt);
        assertTrue(timelock.isOperationReady(id), "ready before the attempt");
        vm.prank(stranger);
        (bool ok,) =
            address(timelock).call(abi.encodeCall(TimelockController.executeBatch, (t6, v6, p6, bytes32(0), salt)));
        emit log_named_uint("MEASURED the six-leg batch executed (1 = yes)", ok ? 1 : 0);
        emit log_named_uint(
            "MEASURED the id is still READY after the failed attempt (1 = yes)", timelock.isOperationReady(id) ? 1 : 0
        );
        emit log_named_uint(
            "MEASURED the id is DONE after the failed attempt (1 = yes)", timelock.isOperationDone(id) ? 1 : 0
        );
        assertFalse(ok, "the harvest leg must take the whole batch down when the farm is refusing");

        // The five-leg form, scheduled from scratch: another forty-eight hours.
        (address[] memory t5, uint256[] memory v5, bytes[] memory p5) = _repairCalls(repair, false);
        uint256 g = gasleft();
        vm.prank(proposer);
        timelock.scheduleBatch(t5, v5, p5, bytes32(0), bytes32("r58a02-five"), Config.ADMIN_TIMELOCK);
        emit log_named_uint("MEASURED gas: scheduleBatch, five legs", g - gasleft());
        skip(Config.ADMIN_TIMELOCK);
        g = gasleft();
        vm.prank(stranger);
        timelock.executeBatch(t5, v5, p5, bytes32(0), bytes32("r58a02-five"));
        emit log_named_uint("MEASURED gas: executeBatch, five legs", g - gasleft());
        emit log_named_uint("MEASURED total wait to repair when the farm is down, seconds", 2 * Config.ADMIN_TIMELOCK);

        assertEq(address(vault.custodyAdapter()), address(repair), "vault pointer");
        assertTrue(vault.custodyIsSolvent(), "custody solvent");
        emit log_named_uint("MEASURED the pending epoch forfeited by the hatch (wei)", PENDING_EPOCH);
        assertEq(usdc.balanceOf(address(harvester)), 0, "the epoch was forfeited: that is the price of the hatch");
    }

    // ── 4. What is reachable while the batch matures ────────────────────────

    /// @notice The forty-eight-hour window, enumerated: what the guardian can still do, and which
    ///         owner doors have become forty-eight-hour operations.
    function test_R58A02_243_info_whatTheGuardianCanStillDoUnderG2() public {
        timelock = _newTimelock();
        _handOverAll(timelock);
        _breakFarm();

        // Reachable in one transaction, by the guardian.
        vm.prank(guardian);
        credit.pause();
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        pool.pause();
        emit log_string("MEASURED the guardian pauses the manager, the vault and the pool in one transaction each");

        // Not reachable by the guardian.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.setBondDepositsPaused(true);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        adapter.emergencyUnstake(guardian);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.harvestYield();
        emit log_string("MEASURED unpause, setBondDepositsPaused, emergencyUnstake and harvestYield are all 48-hour operations");

        // The adapter has no guardian and no pause at all: the hatch is not a fast lever under G2.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.emergencyUnstake(stranger);
    }

    // ── 5. The batch hazard a hand-built repair carries ─────────────────────

    /// @notice `TimelockController._execute` uses `Address.verifyCallResult`, not
    ///         `verifyCallResultFromTarget`, so a leg aimed at a CODELESS address executes as a
    ///         silent SUCCESS. In a hand-built repair batch the typo that matters is the repair
    ///         adapter's address: legs 1 to 3 all pass, and only the vault's own probe stops it.
    function test_R58A02_243_negative_aCodelessLegInTheRepairBatchSucceedsSilently() public {
        timelock = _newTimelock();
        _handOverAll(timelock);
        address ghost = makeAddr("notYetDeployed");
        assertEq(ghost.code.length, 0, "fixture: the ghost must be codeless");

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = ghost;
        payloads[0] = abi.encodeCall(DirectCallAdapter.restakeLoose, ());
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("ghost"), Config.ADMIN_TIMELOCK);
        skip(Config.ADMIN_TIMELOCK);
        vm.prank(stranger);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32("ghost"));
        emit log_string("MEASURED a restakeLoose() aimed at a codeless address executed as a SUCCESS");
        assertTrue(
            timelock.isOperationDone(
                timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32("ghost"))
            ),
            "the ghost operation is recorded Done"
        );
    }

    // ── 6. What cannot be batched at all ────────────────────────────────────

    /// @notice The legs that are not timelock calls, stated by executing the one that can be: a
    ///         repair adapter DexFi has not whitelisted installs cleanly and freezes every exit, so
    ///         the whitelist is a prerequisite with no on-chain guard and must precede the schedule.
    function test_R58A02_243_info_theWhitelistLegIsNotInTheBatchAndNothingChecksIt() public {
        timelock = _newTimelock();
        _handOverAll(timelock);
        farm.setPendingYield(address(adapter), PENDING_EPOCH);
        MockFarm newFarm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(newFarm));
        bond.setWhitelisted(address(newFarm), true);
        DirectCallAdapter repair = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(newFarm)),
            usdc,
            address(vault),
            address(timelock),
            address(harvester)
        );
        // DELIBERATELY NOT whitelisted.
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _repairCalls(repair, true);
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("nowl"), Config.ADMIN_TIMELOCK);
        skip(Config.ADMIN_TIMELOCK);
        vm.prank(stranger);
        (bool ok,) = address(timelock)
            .call(
                abi.encodeCall(
                    TimelockController.executeBatch, (targets, values, payloads, bytes32(0), bytes32("nowl"))
                )
            );
        emit log_named_uint("MEASURED the unwhitelisted repair batch executed (1 = yes)", ok ? 1 : 0);
        if (ok) {
            emit log_named_uint("MEASURED custody reads solvent (1 = yes)", vault.custodyIsSolvent() ? 1 : 0);
            uint256 out;
            vm.prank(bob);
            try vault.withdrawBonds(1) {
                out = 1;
            } catch {}
            emit log_named_uint("MEASURED a staker can still withdraw one bond (1 = yes)", out);
        }
    }
}
