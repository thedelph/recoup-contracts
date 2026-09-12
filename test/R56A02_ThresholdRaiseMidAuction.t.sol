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
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R56A02 - round-56 item 82: raising `liquidationThresholdBps` mid-auction, end to end
/// @notice Audit round 56, agent A2. The RAISING direction only (the lowering direction is recorded
///         unreachable by round 50's A4 and is not redone). Executed through the real governance
///         path: `RiskParams` owned by a `TimelockController` at `Config.ADMIN_TIMELOCK` with one
///         proposer and OPEN execution (`executors[0] = address(0)`, the shape `Governance.t.sol`
///         pins as the one this repository deploys). No storage is pranked.
///
///         THE LEAD: "raising `liquidationThresholdBps` mid-auction makes LIVE auctions cancel-able,
///         permissionlessly". CONFIRMED by execution, and it is the designed outcome the
///         `setRiskParams` docstring already states ("`cancel` ... becomes the correct exit. That
///         is the right outcome: the position is genuinely healthy"). What the docstring does NOT
///         state, and this file measures, is WHO the move pays and who it costs, and that under open
///         execution the party who picks the block may be the borrower.
contract R56A02_ThresholdRaiseMidAuction is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    /// @dev LTV = 628.750000 / (100 x 11.64) = 54.02%: liquidatable at 5000, healthy at 5800.
    uint256 internal constant NAV_BETWEEN = 11.64e8;
    /// @dev LTV = 628.750000 / (100 x 10.50) = 59.88%: liquidatable at 5000 AND at 5800.
    uint256 internal constant NAV_BELOW_BOTH = 10.50e8;

    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal alice = makeAddr("alice");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
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
    TreasuryLiquiditySource internal treasury;
    RiskParams internal riskParams;
    TimelockController internal timelock;

    bytes internal raiseCall;

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
        bond.setWhitelisted(bidder, true);
        usdc.mint(address(treasury), 100_000e6);

        // The governance shape this repository deploys (Governance.t.sol): one proposer, open
        // execution, no standalone admin.
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
        vm.prank(admin);
        riskParams.transferOwnership(address(timelock));

        // The ratchet's terminus threshold, everything else unchanged.
        raiseCall = abi.encodeCall(
            RiskParams.setRiskParams,
            (
                IRiskParams.Params({
                    maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                    liquidationThresholdBps: 5_800,
                    globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                    perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
                })
            )
        );

        // alice borrows at the ceiling; carol is an ordinary staker so the book is not one position.
        _seed(alice);
        _seed(carol);
        uint256 debt = (BONDS * NAV * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        vm.prank(alice);
        credit.borrow(debt);

        usdc.mint(bidder, 10_000e6);
        vm.prank(bidder);
        usdc.approve(address(auction), type(uint256).max);
    }

    function _seed(address who) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @dev Schedule the raise at t0, let 48 h less 3 h pass, drop NAV so alice is liquidatable,
    ///      open her auction, then walk to maturity. Returns the auction id; the raise is READY
    ///      and not executed, and the auction has three hours left to run.
    function _scheduleThenLiquidate(uint256 nav) internal returns (uint256 id) {
        vm.prank(proposer);
        timelock.schedule(address(riskParams), 0, raiseCall, bytes32(0), bytes32(0), Config.ADMIN_TIMELOCK);
        skip(Config.ADMIN_TIMELOCK - 3 hours);
        oracle.setNav(nav);
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: no auction opened");
        skip(3 hours);
        bytes32 op = timelock.hashOperation(address(riskParams), 0, raiseCall, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationReady(op), "fixture: the raise is not ready");
        assertLt(block.timestamp, auction.endsAt(id), "fixture: the auction is no longer live");
    }

    function _execute(address who) internal {
        vm.prank(who);
        timelock.execute(address(riskParams), 0, raiseCall, bytes32(0), bytes32(0));
    }

    // ── CONTROL: the auction as it would have ended without the raise ────────

    /// @notice CONTROL. Same state, raise ready but NOT executed: the lot fills at the current Dutch
    ///         price. The keeper is paid the parked bounty plus half the penalty, insurance the other
    ///         half, alice's surplus goes to `claimableOf`, and she loses the lot.
    function test_R56A02_82_control_withoutTheRaiseTheLotFills() public {
        uint256 id = _scheduleThenLiquidate(NAV_BETWEEN);
        uint256 debt = credit.currentDebtOf(alice);
        uint256 price = auction.currentPrice(id);
        uint256 insBefore = credit.insuranceFund();

        vm.prank(bidder);
        auction.bid(id, BONDS, price);

        uint256 keeperBounty = credit.bountyOwedTo(keeper);
        uint256 keeperReward = auction.rewardOf(keeper);
        emit log_named_uint("CONTROL debt at fill", debt);
        emit log_named_uint("CONTROL price paid", price);
        emit log_named_uint("CONTROL keeper bounty (parked escrow released)", keeperBounty);
        emit log_named_uint("CONTROL keeper penalty share", keeperReward);
        emit log_named_uint("CONTROL insurance gain", credit.insuranceFund() - insBefore);
        emit log_named_uint("CONTROL alice surplus to claimable", credit.claimableOf(alice));
        emit log_named_uint("CONTROL alice bonds after", vault.bondCount(alice));
        assertEq(keeperBounty, Config.LIQUIDATION_CALL_BOUNTY, "control: keeper bounty");
        assertGt(keeperReward, 0, "control: no penalty share");
        assertEq(vault.bondCount(alice), 0, "control: the lot did not move");
    }

    // ── CONFIRMED: the raise makes the live auction cancellable by anyone ────

    /// @notice CONFIRMED (the lead). A STRANGER executes the matured raise through the open
    ///         executor and, in the next call, cancels alice's live auction. Measured: the bounty
    ///         parked for the keeper goes back to alice's escrow, the keeper earns nothing, insurance
    ///         gains nothing, alice keeps all 100 bonds, and an in-flight bid from the keeper-side
    ///         reverts on the vault's liquidatable re-check. `liveAuctionCount` returns to 0.
    function test_R56A02_82_confirmed_aRaiseMakesTheLiveAuctionCancellableByAStranger() public {
        uint256 id = _scheduleThenLiquidate(NAV_BETWEEN);
        uint256 escrowBefore = credit.bountyEscrowOf(alice);
        uint256 parked = credit.totalBountyParked();
        uint256 insBefore = credit.insuranceFund();
        uint256 price = auction.currentPrice(id);

        // Before the raise, a stranger cannot cancel: the position is liquidatable at 5000.
        vm.prank(stranger);
        vm.expectRevert();
        auction.cancel(id);

        _execute(stranger);
        assertEq(riskParams.liquidationThresholdBps(), 5_800, "the raise did not land");

        // The bid a keeper-side bidder had in flight now reverts inside `seize`.
        uint256 ltvNow = credit.currentLtvBps(alice);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, ltvNow));
        auction.bid(id, BONDS, price);

        vm.prank(stranger);
        auction.cancel(id);

        emit log_named_uint("MEASURED parked bounty before cancel", parked);
        emit log_named_uint("MEASURED alice escrow before / after", escrowBefore);
        emit log_named_uint("MEASURED alice escrow after", credit.bountyEscrowOf(alice));
        emit log_named_uint("MEASURED keeper bounty owed", credit.bountyOwedTo(keeper));
        emit log_named_uint("MEASURED keeper penalty share", auction.rewardOf(keeper));
        emit log_named_uint("MEASURED insurance gain", credit.insuranceFund() - insBefore);
        emit log_named_uint("MEASURED alice bonds kept", vault.bondCount(alice));
        emit log_named_uint("MEASURED alice LTV bps after", credit.currentLtvBps(alice));

        assertEq(auction.liveAuctionCount(), 0, "the auction is still live");
        assertEq(credit.bountyEscrowOf(alice), escrowBefore + parked, "the park did not return to alice");
        assertEq(credit.bountyOwedTo(keeper), 0, "the keeper was paid for a cancelled auction");
        assertEq(auction.rewardOf(keeper), 0, "a penalty share was paid on a cancel");
        assertEq(credit.insuranceFund(), insBefore, "insurance moved on a cancel");
        assertEq(vault.bondCount(alice), BONDS, "alice lost bonds on a cancel");
    }

    /// @notice CONFIRMED, the incidence under open execution. The BORROWER herself can be the party
    ///         who executes the matured raise and cancels, atomically, in whatever block she picks.
    ///         Nothing in the auction or `RiskParams` prefers one executor over another.
    function test_R56A02_82_confirmed_theBorrowerCanPickTheBlock() public {
        uint256 id = _scheduleThenLiquidate(NAV_BETWEEN);
        _execute(alice);
        vm.prank(alice);
        auction.cancel(id);
        assertEq(auction.liveAuctionCount(), 0, "the borrower could not cancel her own auction");
        assertEq(vault.bondCount(alice), BONDS, "alice lost bonds");
    }

    /// @notice CONFIRMED, the exit of last resort agrees. With the raise executed and nobody
    ///         cancelling, `expireToWorkout` after the window dispatches to the cancel body rather
    ///         than opening a workout: no workout, the park back to alice.
    function test_R56A02_82_confirmed_expiryAfterTheRaiseDispatchesToCancel() public {
        uint256 id = _scheduleThenLiquidate(NAV_BETWEEN);
        uint256 parked = credit.totalBountyParked();
        uint256 escrowBefore = credit.bountyEscrowOf(alice);
        _execute(stranger);
        skip(Config.AUCTION_DURATION);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertEq(auction.openWorkoutCount(), 0, "a workout opened over a healthy position");
        assertEq(credit.bountyEscrowOf(alice), escrowBefore + parked, "the park did not return");
        assertEq(credit.bountyOwedTo(keeper), 0, "the keeper earned on a healed expiry");
    }

    // ── NEGATIVES ────────────────────────────────────────────────────────────

    /// @notice NEGATIVE. A position still liquidatable at the RAISED threshold is not made
    ///         cancellable: `cancel` refuses with `StillLiquidatable`, and the lot still fills.
    function test_R56A02_82_negative_aPositionBeyondTheNewThresholdStaysForfeit() public {
        uint256 id = _scheduleThenLiquidate(NAV_BELOW_BOTH);
        _execute(stranger);
        uint256 ltv = credit.currentLtvBps(alice);
        assertGt(ltv, 5_800, "fixture: not beyond the raised threshold");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.StillLiquidatable.selector, ltv));
        auction.cancel(id);
        uint256 price = auction.currentPrice(id);
        vm.prank(bidder);
        auction.bid(id, BONDS, price);
        assertEq(vault.bondCount(alice), 0, "the forfeit lot did not fill");
    }

    /// @notice NEGATIVE, the lenders. No loss is socialised by the cancel: the position is healthy
    ///         at 5800 (collateral above debt by a factor of at least 1/0.58), nothing is written
    ///         down, and total debt is unchanged.
    function test_R56A02_82_negative_noLossIsRecognisedByTheCancel() public {
        uint256 id = _scheduleThenLiquidate(NAV_BETWEEN);
        uint256 debtBefore = credit.totalDebt();
        uint256 collateral = vault.collateralValue(alice);
        _execute(stranger);
        vm.prank(stranger);
        auction.cancel(id);
        assertEq(credit.totalDebt(), debtBefore, "debt moved on a cancel");
        assertGt(collateral, credit.currentDebtOf(alice), "the cancelled position is underwater");
    }
}
