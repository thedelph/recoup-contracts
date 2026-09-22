// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
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
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @title Round 62, seat A3: the real four-contract graph over a CHOSEN USDC mock.
/// @dev `Impairment.integration.t.sol`'s `setUp` is not virtual and builds over `MockUSDC`, so
///      the campaign and the USDC-semantics suite build the same graph here with the token as a
///      parameter. Same wiring, same 2026-07-24 NAV and 100-bond position; the deposits are the
///      caller's.
abstract contract R62A3_GraphFixture is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOOR_TOTAL_SLOT = 33;
    uint256 internal constant WITHDRAWAL_REQUESTS_SLOT = 25;
    uint256 internal constant REQUEST_FLOOR_WORD = 3;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // borrower
    address internal lender = makeAddr("lender");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");
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
    LenderPool internal pool;
    RiskParams internal riskParams;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function _buildGraph(MockUSDC token) internal {
        usdc = token;
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(harvester);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
    }

    function _lenderDeposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        shares = pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _stakeBonds(address who, uint256 count) internal {
        bond.mint(who, count);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(count);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), type(uint256).max);
    }

    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    function _debtParityNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS);
    }

    function _crashedNav() internal view returns (uint256) {
        return _debtParityNav() / 2;
    }

    function _floorTotal() internal view returns (uint256) {
        return uint256(vm.load(address(pool), bytes32(FLOOR_TOTAL_SLOT)));
    }

    function _floorOf(address who) internal view returns (uint256) {
        bytes32 base = keccak256(abi.encode(who, WITHDRAWAL_REQUESTS_SLOT));
        return uint256(vm.load(address(pool), bytes32(uint256(base) + REQUEST_FLOOR_WORD)));
    }

    function _executable() internal view returns (uint256) {
        return pool.unreservedIdle() + pool.queueCashReserve();
    }

    function _requestAll(address who) internal {
        uint256 shares = pool.balanceOf(who);
        vm.prank(who);
        pool.requestWithdrawal(shares, who);
    }

    function _serviceable(address who) internal view returns (uint256) {
        return pool.previewRedeem(pool.maxRequestRedeem(who));
    }

    function _drainLoop(address who) internal returns (uint256 paid) {
        for (uint256 i; i < 32; ++i) {
            uint256 shares = pool.maxRequestRedeem(who);
            if (shares == 0 || pool.previewRedeem(shares) == 0) break;
            vm.prank(who);
            paid += pool.serviceWithdrawalRequest(who, shares, 0);
        }
    }
}
