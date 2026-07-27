// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Drives randomised borrow / repay / yield / withdraw sequences across a
///         small set of actors.
contract CreditHandler is Test {
    MockUSDC public usdc;
    MockNavOracle public oracle;
    CollateralVault public vault;
    CreditManager public credit;
    TreasuryLiquiditySource public liquidity;

    address public harvester;
    address[3] public actors;

    /// @notice Incremented whenever a borrow succeeds, so the monotonicity invariant
    ///         can tell a legitimate increase from debt appearing out of nowhere.
    uint256 public borrowCount;

    constructor(
        MockUSDC usdc_,
        MockNavOracle oracle_,
        CollateralVault vault_,
        CreditManager credit_,
        TreasuryLiquiditySource liquidity_,
        address harvester_,
        address[3] memory actors_
    ) {
        usdc = usdc_;
        oracle = oracle_;
        vault = vault_;
        credit = credit_;
        liquidity = liquidity_;
        harvester = harvester_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 5_000e6);
        vm.prank(a);
        try credit.borrow(amount) {
            borrowCount++;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 5_000e6);
        uint256 debt = credit.debtOf(a);
        if (debt == 0) return;
        uint256 paid = amount > debt ? debt : amount;
        usdc.mint(a, paid);
        vm.startPrank(a);
        usdc.approve(address(credit), paid);
        try credit.repay(amount) {} catch {}
        vm.stopPrank();
    }

    /// @dev Settles every actor afterwards so later actions start from a clean
    ///      position rather than a pile of unaccrued entitlement.
    function distributeYield(uint256 amount) external {
        amount = bound(amount, 1, 2_000e6);
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();

        for (uint256 i; i < actors.length; ++i) {
            credit.settle(actors[i]);
        }
    }

    /// @dev Without this the fuzzer never moves the clock, and an epoch's share is
    ///      streamed over YIELD_STREAM_DURATION - so every distribution would accrue
    ///      exactly nothing and the whole yield path would go unexercised. The range
    ///      deliberately straddles the stream: shorter jumps land mid-stream, longer
    ///      ones run it past the end and re-rate a leftover pot.
    ///      Accrual alone moves no debt - it only advances the accumulator.
    function passTime(uint256 seconds_) external {
        skip(bound(seconds_, 1 hours, Config.YIELD_STREAM_DURATION * 2));
        credit.accrueYield();
    }

    function settle(uint256 actorSeed) external {
        credit.settle(_actor(actorSeed));
    }

    function claimSurplus(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try credit.claimSurplus() {} catch {}
    }

    function settlePrincipal() external {
        try credit.settlePrincipal() {} catch {}
    }

    function withdraw(uint256 actorSeed, uint256 bonds) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        if (held == 0) return;
        bonds = bound(bonds, 1, held);
        vm.prank(a);
        try vault.withdrawBonds(bonds) {} catch {}
    }

    function moveNav(uint256 nav) external {
        oracle.setNav(bound(nav, 1e8, 100e8));
    }

}

/// @notice The Phase 2 invariants named in PRD §8, fuzzed.
contract CreditManagerInvariantsTest is StdInvariant, Test {
    uint256 internal constant NAV = 25.15e8;

    address internal admin = makeAddr("admin");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    TreasuryLiquiditySource internal liquidity;
    CreditHandler internal handler;

    address[3] internal actors;

    /// @notice Highest accumulator value seen so far, for the monotonicity check.
    uint256 internal lastAcc;
    /// @notice Previous observations, for the debt-monotonicity check.
    uint256 internal lastTotalDebt;
    uint256 internal lastBorrowCount;

    function setUp() public {
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];

        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(makeAddr("auction"));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(liquidity), 1_000_000e6);
        liquidity.fund(1_000_000e6);

        for (uint256 i; i < actors.length; ++i) {
            bond.mint(actors[i], 10_000);
            vm.startPrank(actors[i]);
            bond.setApprovalForAll(address(vault), true);
            vault.depositBonds(5_000);
            vm.stopPrank();
        }

        handler = new CreditHandler(usdc, oracle, vault, credit, liquidity, harvester, actors);
        targetContract(address(handler));
    }

    /// @dev PRD §8: "Sum of user debts == CreditManager total debt."
    function invariant_totalDebtEqualsSumOfDebts() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += credit.debtOf(actors[i]);
        }
        assertEq(credit.totalDebt(), sum);
    }

    /// @dev PRD §8: "Debt is monotonically non-increasing absent a borrow." This is
    ///      the property a self-repaying loan lives or dies on - nothing but an
    ///      explicit borrow may ever increase what someone owes.
    ///
    ///      It replaces an earlier handler-side tally of each actor's debt. That tally
    ///      could not survive lazy accrual: yield now streams continuously, so any
    ///      action that touches a position settles it and writes debt down, and a
    ///      mirror updated only on explicit settles drifts by design rather than by
    ///      bug. This checks the real property instead of a bookkeeping duplicate.
    function invariant_debtOnlyRisesOnABorrow() public {
        uint256 debtNow = credit.totalDebt();
        uint256 borrows = handler.borrowCount();
        if (borrows == lastBorrowCount) {
            assertLe(debtNow, lastTotalDebt, "debt rose with no borrow behind it");
        }
        lastTotalDebt = debtNow;
        lastBorrowCount = borrows;
    }

    /// @dev Solvency. Every USDC this contract holds is spoken for exactly once:
    ///      surplus owed to borrowers, yield not yet allocated, principal owed back to
    ///      the funding source, and the insurance fund. Borrowed principal is never
    ///      held here - it passes straight through.
    function invariant_balanceCoversEveryClaimOnIt() public view {
        assertGe(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
                + credit.insuranceFund()
        );
    }

    /// @dev PRD §8: "No path mints borrower USDC without proportional debt."
    function invariant_totalDebtNeverExceedsGlobalCap() public view {
        assertLe(credit.totalDebt(), Config.GLOBAL_BORROW_CAP);
    }

    function invariant_noPositionExceedsPerAccountCap() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(credit.debtOf(actors[i]), Config.PER_ACCOUNT_BORROW_CAP);
        }
    }

    /// @dev The accumulator only ever moves up. Every position's entitlement is the
    ///      difference between it and a recorded index, so a decrease would underflow
    ///      `_pending` and revert every settlement - including the ones inside
    ///      withdrawals, which would trap collateral.
    function invariant_accumulatorNeverDecreases() public {
        uint256 acc = credit.accYieldPerBond();
        assertGe(acc, lastAcc);
        lastAcc = acc;
    }

    /// @dev A stream can only ever pay out USDC that was actually delivered. If the
    ///      accumulator could outrun the pot, `settle` would credit debt write-downs
    ///      and claimable balances against money the contract does not hold - which is
    ///      the solvency invariant failing one step later, from a cause that is much
    ///      harder to read at that point.
    function invariant_streamNeverPromisesMoreThanWasDelivered() public view {
        assertLe(credit.undistributedYield(), usdc.balanceOf(address(credit)));
    }
}
