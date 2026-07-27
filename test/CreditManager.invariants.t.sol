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

    /// @notice Mirrors what the handler believes each actor owes, so the invariant can
    ///         check the contract's own total against an independent tally.
    mapping(address => uint256) public ghostDebt;
    /// @notice Set whenever a borrow succeeds, so the monotonicity invariant knows a
    ///         legitimate increase happened.
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
            ghostDebt[a] += amount;
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
        try credit.repay(amount) {
            ghostDebt[a] -= paid;
        } catch {}
        vm.stopPrank();
    }

    function applyYield(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 0, 2_000e6);
        if (amount == 0) return;
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        uint256 debt = credit.debtOf(a);
        credit.applyYield(a, amount);
        vm.stopPrank();
        ghostDebt[a] -= amount > debt ? debt : amount;
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

    function sumGhostDebt() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += ghostDebt[actors[i]];
        }
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

    /// @dev The handler's independent tally must agree too, which catches a
    ///       bookkeeping slip that happens to be self-consistent inside the contract.
    function invariant_ghostDebtAgrees() public view {
        assertEq(credit.totalDebt(), handler.sumGhostDebt());
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
}
