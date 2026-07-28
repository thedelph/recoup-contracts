// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {Config} from "../src/Config.sol";
import {LtvMath} from "../src/LtvMath.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockCreditManager} from "./mocks/MockCreditManager.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Randomised call sequences against the vault + adapter. The fuzzer
///         plays several actors (depositors, the auction, the owner, a yield
///         setter) in arbitrary order; the invariants below must hold after
///         every sequence.
contract VaultHandler is Test {
    CollateralVault public immutable vault;
    DirectCallAdapter public immutable adapter;
    MockBond public immutable bond;
    MockFarm public immutable farm;
    MockUSDC public immutable usdc;
    MockCreditManager public immutable credit;
    address public immutable auction;
    address public immutable admin;

    address[] public actors;
    uint256 public ghostTotalBondCount; // mirror of Σ vault.bondCount
    uint256 public ghostSeizedToWinners;

    constructor(
        CollateralVault vault_,
        DirectCallAdapter adapter_,
        MockBond bond_,
        MockFarm farm_,
        MockUSDC usdc_,
        MockCreditManager credit_,
        address auction_,
        address admin_
    ) {
        vault = vault_;
        adapter = adapter_;
        bond = bond_;
        farm = farm_;
        usdc = usdc_;
        credit = credit_;
        auction = auction_;
        admin = admin_;
        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(a);
            bond.mint(a, 100_000);
            vm.prank(a);
            bond.setApprovalForAll(address(vault), true);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, bond.bondBalance(a));
        if (amount == 0) return;
        vm.prank(a);
        vault.depositBonds(amount);
        ghostTotalBondCount += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        // Debt may make this revert (LTV rule) - both outcomes are valid;
        // the invariants must hold either way.
        vm.prank(a);
        try vault.withdrawBonds(amount) {
            ghostTotalBondCount -= amount;
        } catch {}
    }

    function setDebt(uint256 actorSeed, uint256 debt) external {
        credit.setDebt(_actor(actorSeed), bound(debt, 0, 1_000_000e6));
    }

    function accrueYield(uint256 amount) external {
        farm.setPendingYield(address(adapter), bound(amount, 0, 1_000_000e6));
    }

    function harvest() external {
        vm.prank(admin);
        vault.harvestYield();
    }

    /// @dev Asserts the gate and its complement together: a seize must succeed exactly
    ///      when the position is liquidatable and fail exactly when it is not. Written
    ///      as one action rather than two tests because a guard and the states it is
    ///      supposed to admit are the classic pair that both pass in isolation while
    ///      being mutually unsatisfiable.
    function seize(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        address winner = makeAddr("winner");
        bool liquidatable = _liquidatable(a, held);

        vm.prank(auction);
        try vault.seize(a, winner) returns (uint256 got) {
            assertTrue(liquidatable || held == 0, "seized a position that was not liquidatable");
            assertEq(got, held, "seize must move the whole position");
            ghostTotalBondCount -= held;
            ghostSeizedToWinners += held;
        } catch {
            assertFalse(liquidatable && held != 0, "refused a genuinely liquidatable position");
        }
    }

    /// @dev The workout path. Moves the claim to the auction and nothing else, so the
    ///      bond-conservation invariants must be completely indifferent to it.
    function reassign(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        if (a == auction) return;
        bool liquidatable = _liquidatable(a, held);

        vm.prank(auction);
        try vault.reassign(a, auction) returns (uint256 moved) {
            assertTrue(liquidatable || held == 0, "reassigned a position that was not liquidatable");
            assertEq(moved, held, "reassign must move the whole claim");
        } catch {
            assertFalse(liquidatable && held != 0, "refused a genuinely liquidatable position");
        }
    }

    function _liquidatable(address who, uint256 held) internal view returns (bool) {
        return LtvMath.exceedsLtv(
            credit.currentDebtOf(who),
            LtvMath.collateralValue(held, vault.navOracle().navPerBond()),
            Config.LIQUIDATION_THRESHOLD_BPS
        );
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev The auction is counted too. A workout reassigns a defaulted position's
    ///      claim to it, and those bonds are still staked and still collateral - so
    ///      leaving it out would not just under-count, it would make the vault look
    ///      insolvent the moment anything expired.
    function sumBondCounts() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.bondCount(actors[i]);
        }
        sum += vault.bondCount(auction);
    }
}

contract CollateralVaultInvariants is Test {
    VaultHandler internal handler;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    MockBond internal bond;
    MockFarm internal farm;
    MockUSDC internal usdc;

    function setUp() public {
        address admin = makeAddr("admin");
        MockLiquidationAuction auctionMock = new MockLiquidationAuction();
        address auction = address(auctionMock);
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        MockNavOracle oracle = new MockNavOracle(25.15e8);
        MockCreditManager credit = new MockCreditManager();

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(farm)),
            usdc,
            address(vault),
            admin,
            makeAddr("treasury")
        );
        credit.setVault(address(vault)); // setCreditManager checks the binding back
        auctionMock.setVault(address(vault));
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(auction);
        vm.stopPrank();
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        handler = new VaultHandler(vault, adapter, bond, farm, usdc, credit, auction, admin);
        targetContract(address(handler));
    }

    /// Vault accounting always equals what is actually staked in the farm.
    function invariant_accountingMatchesFarmStake() public view {
        (uint256 staked,) = farm.userInfo(address(adapter));
        assertEq(staked, handler.sumBondCounts(), "sum(bondCount) == farm stake");
        assertEq(staked, handler.ghostTotalBondCount(), "ghost mirror agrees");
    }

    /// The adapter is a pass-through: it never holds USDC or loose bonds.
    function invariant_adapterHoldsNothingAtRest() public view {
        assertEq(usdc.balanceOf(address(adapter)), 0, "no USDC at rest");
        assertEq(bond.bondBalance(address(adapter)), 0, "no loose bonds");
    }

    /// Bond units are conserved: everything minted is in wallets, the farm, or
    /// with auction winners - nothing is created or destroyed by the vault.
    function invariant_bondConservation() public view {
        uint256 inWallets;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            inWallets += bond.bondBalance(handler.actors(i));
        }
        (uint256 staked,) = farm.userInfo(address(adapter));
        uint256 winners = handler.ghostSeizedToWinners();
        assertEq(
            inWallets + staked + winners,
            100_000 * handler.actorCount(),
            "minted == wallets + staked + seized"
        );
    }

    /// The vault never accumulates bonds itself (custody is farm-side only).
    function invariant_vaultHoldsNoBonds() public view {
        assertEq(bond.bondBalance(address(vault)), 0, "vault holds no bonds");
    }
}
