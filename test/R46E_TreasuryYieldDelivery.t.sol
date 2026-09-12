// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
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
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice A pool that takes delivery, for the repoint in the strand test.
contract R46E_AcceptingPool {
    IERC20 public immutable usdc;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function distributeYield(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice Round 46, open item 76b: can approve-and-call delivery to `TreasuryLiquiditySource`
///         double-approve or strand?
///
/// @dev Two approve-and-call legs reach a treasury, and they are traced separately because they
///      answer differently:
///
///      - **`CreditManager -> repayPrincipal`** (`CreditWiring.pullPrincipal`): the allowance is
///        opened at `amount`, the treasury pulls exactly `amount` or reverts - there is no partial
///        branch in `TreasuryLiquiditySource.repayPrincipal` - and the allowance is closed to zero
///        after the call on both the bare and the best-effort branch. MEASURED below: no standing
///        allowance after a settle, after a second settle that moves nothing, and after a migration
///        between two treasuries; nothing parks; the surplus clamp takes the whole amount rather
///        than a partial one. Neither "double-approve" nor "strand" is reachable on this leg.
///
///      - **`EpochHarvester -> distributeYield`** (`_push`): the same open-call-close, and a
///        treasury has no `distributeYield`, so the call reverts into the `catch`, delivery is
///        measured at zero and the allowance is closed. Nothing is double-approved. **The strand
///        half is real, and it is owner-shaped**: `EpochHarvester.setLenderPool` accepts any
///        non-zero address with no completeness probe (the probe `CreditManager.setLiquiditySource`
///        gained in round 27 has no twin here), so a harvester pointed at the treasury accrues the
///        lender share against it, and the repoint that fixes the pointer parks that share against
///        the treasury under `owedToPool`, where `flushLenderYieldTo(treasury)` can never land it.
///        MEASURED in round 46 and filed rather than fixed then, because the fix is a probe in
///        `EpochHarvester`, which that round did not touch. **FIXED in audit round 48, finding
///        83**: `setLenderPool` now probes the incoming address for `distributeYield` and refuses
///        the treasury by name with `LenderPoolIncomplete`, so the strand is no longer reachable
///        through the setter. The test that measured the strand is rewritten below into the
///        falsifier for that probe - it was RED before the probe, because the setter accepted the
///        treasury - and the manager-leg tests above are unchanged.
contract R46E_TreasuryYieldDelivery is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant FLOAT = 100_000e6;
    uint256 internal constant YIELD = 1_000e6;
    uint256 internal constant BONDS = 100;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal feeWallet = makeAddr("feeWallet");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    EpochHarvester internal harvester;
    TreasuryLiquiditySource internal liquidity;
    RiskParams internal riskParams;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        credit = new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        MockLiquidationAuction auctionStub = new MockLiquidationAuction();
        auctionStub.setVault(address(vault));
        auctionStub.setRiskParams(address(riskParams));
        auctionStub.setNavOracle(address(vault.navOracle()));
        auctionStub.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auctionStub));
        credit.setLiquidationAuction(address(auctionStub));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(address(harvester));
        liquidity.setCreditManager(address(credit));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        harvester.setProtocolFeeWallet(feeWallet);
        adapter.setHarvester(address(harvester));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        bond.mint(alice, BONDS);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @dev Borrow at the ceiling and repay it, so the whole principal is waiting to go home.
    function _borrowAndRepay() private returns (uint256 loan) {
        loan = _maxBorrow(BONDS, NAV);
        vm.prank(alice);
        credit.borrow(loan);
        uint256 owed = credit.currentDebtOf(alice);
        usdc.mint(alice, owed);
        vm.startPrank(alice);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();
        assertEq(credit.pendingPrincipal(), loan, "premise: the principal is waiting to go home");
    }

    // ── the manager's leg ────────────────────────────────────────────────────

    function test_R46E_settlePrincipalOpensOneAllowanceClosesItAndPullsExactlyOnce() public {
        uint256 loan = _borrowAndRepay();
        uint256 treasuryBefore = usdc.balanceOf(address(liquidity));

        credit.settlePrincipal();

        assertEq(usdc.allowance(address(credit), address(liquidity)), 0, "a standing allowance survived");
        assertEq(usdc.balanceOf(address(liquidity)) - treasuryBefore, loan, "the treasury pulled short or long");
        assertEq(liquidity.outstandingPrincipal(), 0, "the treasury's book did not close");
        assertEq(credit.pendingPrincipal(), 0, "the counter did not spend down");
        assertEq(credit.owedToSource(address(liquidity)), 0, "something parked on a delivery that landed");

        // A second settle finds nothing, approves nothing and moves nothing.
        credit.settlePrincipal();
        assertEq(usdc.allowance(address(credit), address(liquidity)), 0, "the no-op settle left an allowance");
        assertEq(usdc.balanceOf(address(liquidity)) - treasuryBefore, loan, "the no-op settle moved money");
    }

    function test_R46E_migratingBetweenTwoTreasuriesDeliversEverythingAndParksNothing() public {
        uint256 loan = _borrowAndRepay();
        TreasuryLiquiditySource next = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        next.setCreditManager(address(credit));
        uint256 outgoingBefore = usdc.balanceOf(address(liquidity));

        vm.prank(admin);
        credit.setLiquiditySource(address(next));

        assertEq(credit.liquiditySource(), address(next), "premise: the funder moved");
        assertEq(usdc.balanceOf(address(liquidity)) - outgoingBefore, loan, "the outgoing treasury was not paid in full");
        assertEq(credit.owedToSource(address(liquidity)), 0, "a full delivery still parked something");
        assertEq(credit.totalOwedToSources(), 0);
        assertEq(credit.pendingPrincipal(), 0);
        assertEq(usdc.allowance(address(credit), address(liquidity)), 0, "the outgoing treasury kept an allowance");
        assertEq(usdc.allowance(address(credit), address(next)), 0, "the incoming treasury was handed an allowance");
    }

    /// @notice The clamp the treasury's docstring names - "yield can exceed principal" - takes the
    ///         whole amount offered, not the part that was principal, so a settlement carrying a
    ///         surplus never delivers short and never leaves a residue to park.
    function test_R46E_theTreasuryTakesASurplusRepaymentWholeAndClampsItsBookAtZero() public {
        TreasuryLiquiditySource t = new TreasuryLiquiditySource(usdc, admin);
        vm.prank(admin);
        t.setCreditManager(address(this));
        uint256 principal = 1_000e6;
        usdc.mint(address(this), principal);
        usdc.approve(address(t), principal);
        t.fund(principal);
        t.lend(principal);
        assertEq(t.outstandingPrincipal(), principal, "premise: the float is out on loan");

        // Repay twice what was lent: the manager's approve-and-call, opened at exactly the amount.
        uint256 offered = 2 * principal;
        usdc.mint(address(this), principal);
        usdc.approve(address(t), offered);
        t.repayPrincipal(offered);

        assertEq(usdc.balanceOf(address(t)), offered, "the treasury took a partial amount");
        assertEq(usdc.allowance(address(this), address(t)), 0, "the allowance was not consumed exactly");
        assertEq(t.outstandingPrincipal(), 0, "the book did not clamp at zero");
        assertEq(t.available(), offered, "the surplus is not idle float");
    }

    // ── the harvester's leg ──────────────────────────────────────────────────

    /// @notice Audit round 48, finding 83: the setter refuses the treasury BY NAME, before the
    ///         strand round 46 measured here can begin. A `TreasuryLiquiditySource` has no
    ///         `distributeYield` and no fallback, so the probe's call returns empty returndata
    ///         and `setLenderPool` reverts `LenderPoolIncomplete`. The pointer stays zero, the
    ///         probe leaves no allowance and moves no money, and the treasury's book is untouched.
    /// @dev    RED before the probe: `setLenderPool(treasury)` succeeded and the strand followed,
    ///         which is what the test this replaced measured step by step. What round 46 measured
    ///         about the harvest and flush halves is still true of a harvester that somehow holds
    ///         a non-pool - nothing about delivery changed - but no setter can install one now.
    ///
    ///         Then the ordinary path, to show the probe is not refusing every incoming pool: a
    ///         contract that has `distributeYield` is accepted, and delivery lands there.
    function test_R48_setLenderPoolRefusesATreasuryByName() public {
        uint256 treasuryBefore = usdc.balanceOf(address(liquidity));
        assertEq(harvester.lenderPool(), address(0), "premise: nothing wired yet");

        vm.prank(admin);
        vm.expectRevert(EpochHarvester.LenderPoolIncomplete.selector);
        harvester.setLenderPool(address(liquidity));

        assertEq(harvester.lenderPool(), address(0), "the setter took the treasury");
        assertEq(usdc.allowance(address(harvester), address(liquidity)), 0, "the probe left a standing allowance");
        assertEq(usdc.balanceOf(address(liquidity)), treasuryBefore, "the probe moved money");
        assertEq(liquidity.outstandingPrincipal(), 0, "the treasury's book moved");
        assertEq(harvester.owedToPool(address(liquidity)), 0, "nothing can park against an address never installed");

        // The same harvester, an address that can take delivery: accepted, and the share lands.
        address realPool = address(new R46E_AcceptingPool(IERC20(address(usdc))));
        vm.prank(admin);
        harvester.setLenderPool(realPool);
        assertEq(harvester.lenderPool(), realPool, "a real pool is still accepted");

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 toLenders = (YIELD * Config.SPLIT_LENDER_BPS) / Config.BPS;
        assertEq(harvester.pendingLenderYield(), toLenders, "the lender share was held back for the flush");
        harvester.flushLenderYield();
        assertEq(usdc.balanceOf(realPool), toLenders, "and it reached the pool");
        assertEq(harvester.pendingLenderYield(), 0);
        assertEq(harvester.totalOwedToPools(), 0, "nothing parked anywhere");
    }
}
