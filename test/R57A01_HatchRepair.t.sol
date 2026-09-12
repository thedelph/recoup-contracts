// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
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
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice A farm whose owner has upgraded it to take part of one staker's position. Models the
///         "its owner changes it under you" half of the journey: `IDexFiFarm` says the live farm is
///         UUPS-upgradeable by an outside EOA.
contract SkimmingFarm is MockFarm {
    address public immutable thief;

    constructor(MockBond bond_, MockUSDC usdc_, address thief_) MockFarm(bond_, usdc_) {
        thief = thief_;
    }

    function skim(address account, uint256 amount) external {
        staked[account] -= amount;
        bond.safeTransferFrom(address(this), thief, bond.TOKEN_ID(), amount, "");
    }
}

/// @notice A farm whose `emergencyWithdraw` hands the bonds back and leaves the stake record standing.
contract LyingFarm is MockFarm {
    constructor(MockBond bond_, MockUSDC usdc_) MockFarm(bond_, usdc_) {}

    function emergencyWithdraw() external override {
        uint256 amount = staked[msg.sender];
        pendingYield[msg.sender] = 0;
        bond.safeTransferFrom(address(this), msg.sender, bond.TOKEN_ID(), amount, "");
    }
}

/// @title R57A01 - the owner's worst day: the farm breaks, the hatch fires, and then what.
/// @notice Round 57, agent A1 (cold). Walks `DirectCallAdapter.emergencyUnstake` end to end against
///         the full Phase-4 graph (vault, adapter, manager, auction, real `EpochHarvester`, real
///         `LenderPool` as source and loss sink), and asks whether any sequence of owner and
///         permissionless transactions makes borrowers, lenders and live liquidations whole.
///
///         The shipped answer is no: the only way bond units ever enter a `DirectCallAdapter`'s farm
///         stake is `stake` and `mintBonds`, both `onlyVault`, and the vault reaches them only
///         through its two deposit paths, which credit a depositor and are refused while custody is
///         insolvent. So rescued bonds can be moved (to any whitelisted address) but never re-staked
///         without crediting somebody, and `setCustodyAdapter` refuses every adapter that is not
///         already staked with them. The `fix_` cases call the proposed `restakeLoose()` through a
///         low-level call so this file compiles on the base tree, where they go red.
///
///         Case naming: `control_` green on both trees, `fix_` red at the base and green under the
///         fix, `negative_` a refusal that holds on both trees, `pinsOpen_` a state the fix does NOT
///         close - a green run of a `pinsOpen_` case is not a clearance.
contract R57A01HatchRepairTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant ALICE_BONDS = 100;
    uint256 internal constant BOB_BONDS = 200;
    uint256 internal constant CAROL_BONDS = 100;
    uint256 internal constant LEDGER = ALICE_BONDS + BOB_BONDS + CAROL_BONDS;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;
    uint256 internal constant PENDING_EPOCH = 500e6;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice"); // borrower, half the ceiling
    address internal bob = makeAddr("bob"); // pure staker, no debt
    address internal carol = makeAddr("carol"); // borrower at the ceiling
    address internal lender = makeAddr("lender");
    address internal lateLender = makeAddr("lateLender");
    address internal stranger = makeAddr("stranger");
    address internal bidder = makeAddr("bidder");
    address internal rescue = makeAddr("rescue"); // the governance-controlled hatch destination
    address internal feeWallet = makeAddr("feeWallet");
    address internal proposer = makeAddr("proposer");

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

    uint256 internal aliceDebt;
    uint256 internal carolDebt;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function setUp() public {
        bond = new MockBond();
        usdc = new MockUSDC();
        _build(new MockFarm(bond, usdc));
    }

    /// @dev Everything but the two tokens, so a case can swap in a hostile farm.
    function _build(MockFarm farm_) internal {
        farm = farm_;
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);
        riskParams = _deployRiskParams(admin);
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

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(address(harvester));
        pool.setGuardian(guardian);
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        harvester.setLenderPool(address(pool));
        harvester.setProtocolFeeWallet(feeWallet);
        adapter.setHarvester(address(harvester));
        adapter.setYieldRecipient(address(harvester));
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
        _depositBonds(carol, CAROL_BONDS);

        aliceDebt = _maxBorrow(ALICE_BONDS, NAV) / 2;
        carolDebt = _maxBorrow(CAROL_BONDS, NAV);
        vm.prank(alice);
        credit.borrow(aliceDebt);
        vm.prank(carol);
        credit.borrow(carolDebt);

        // Enough cash for every borrower to repay in full whatever the escrow did.
        usdc.mint(alice, 1_000e6);
        usdc.mint(carol, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(credit), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(credit), type(uint256).max);
        usdc.mint(bidder, 100_000e6);
        vm.prank(bidder);
        usdc.approve(address(auction), type(uint256).max);
    }

    function _depositBonds(address who, uint256 n) internal {
        bond.mint(who, n);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(n);
        vm.stopPrank();
    }

    function _bal(address who) internal view returns (uint256) {
        return bond.balanceOf(who, Config.DEXFI_BOND_TOKEN_ID);
    }

    /// @dev The farm stops honouring `withdraw`, a whole epoch is pending, and the owner fires the hatch.
    function _breakAndHatch(address to) internal {
        farm.setPendingYield(address(adapter), PENDING_EPOCH);
        farm.setRevertOnWithdraw(true);
        vm.prank(admin);
        adapter.emergencyUnstake(to);
    }

    function _restake(DirectCallAdapter a) internal returns (bool ok, bytes memory ret) {
        vm.prank(a.owner());
        (ok, ret) = address(a).call(abi.encodeWithSignature("restakeLoose()"));
    }

    function _repayAll(address who) internal {
        uint256 d = credit.currentDebtOf(who);
        if (d == 0) return;
        vm.prank(who);
        credit.repay(d);
    }

    /// @dev Every borrower and staker leaves in full, the book comes home to the pool, and the lender
    ///      redeems. Returns what the lender got back.
    function _everyoneLeaves() internal returns (uint256 lenderOut) {
        _repayAll(alice);
        _repayAll(carol);
        vm.prank(bob);
        vault.withdrawBonds(BOB_BONDS);
        vm.prank(alice);
        vault.withdrawBonds(ALICE_BONDS);
        vm.prank(carol);
        vault.withdrawBonds(CAROL_BONDS);
        assertEq(_bal(bob), BOB_BONDS, "bob whole");
        assertEq(_bal(alice), ALICE_BONDS, "alice whole");
        assertEq(_bal(carol), CAROL_BONDS, "carol whole");
        assertEq(vault.totalBondCount(), 0, "ledger empty");

        credit.settlePrincipal();
        uint256 shares = pool.balanceOf(lender);
        vm.prank(lender);
        lenderOut = pool.redeem(shares, lender, lender);
    }

    // ── 1. the hatch ─────────────────────────────────────────────────────────

    /// @notice What the hatch leaves: a ledger of 400 over a stake of 0, the bonds at the hatch
    ///         destination and credited to nobody, and the pending epoch forfeited to the farm.
    function test_control_theHatchLeavesALedgerNothingBacks() public {
        assertTrue(vault.custodyIsSolvent(), "fixture: solvent before");
        _breakAndHatch(rescue);

        assertEq(adapter.stakedBalance(), 0, "stake emptied");
        assertEq(vault.totalBondCount(), LEDGER, "ledger untouched");
        assertFalse(vault.custodyIsSolvent(), "custody insolvent");
        assertEq(_bal(rescue), LEDGER, "every unit at the hatch destination");
        assertEq(vault.bondCount(rescue), 0, "credited to nobody");
        assertEq(farm.pendingShare(address(adapter)), 0, "pending epoch forfeited");
        assertEq(usdc.balanceOf(address(harvester)), 0, "and none of it reached the harvester");
        // The destination cannot pass them on: a transfer out of `rescue` has no whitelisted party.
        vm.prank(rescue);
        vm.expectRevert(abi.encodeWithSelector(MockBond.AddressesNotWhitelisted.selector, rescue, rescue, bob));
        bond.safeTransferFrom(rescue, bob, 0, BOB_BONDS, "");
    }

    /// @notice The pending epoch is not lost if the owner claims it in the same batch, first - and a
    ///         batch that tries to claim from a farm refusing `withdraw` reverts whole.
    function test_control_theHatchForfeitsThePendingEpochUnlessClaimedFirstInTheSameBatch() public {
        uint256 clean = vm.snapshotState();

        // Farm still honours withdraw (DexFi replaced the reward pool, say): claim, then hatch.
        farm.setPendingYield(address(adapter), PENDING_EPOCH);
        vm.startPrank(admin);
        vault.harvestYield();
        adapter.emergencyUnstake(rescue);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(harvester)), PENDING_EPOCH, "claimed first: the epoch reached the harvester");
        vm.revertToState(clean);

        // Hatch alone: the same epoch is forfeited.
        farm.setPendingYield(address(adapter), PENDING_EPOCH);
        vm.prank(admin);
        adapter.emergencyUnstake(rescue);
        assertEq(usdc.balanceOf(address(harvester)), 0, "hatch alone: forfeited");
        vm.revertToState(clean);

        // Farm refusing withdraw: the claim leg reverts and would take a batched hatch with it.
        farm.setPendingYield(address(adapter), PENDING_EPOCH);
        farm.setRevertOnWithdraw(true);
        vm.prank(admin);
        vm.expectRevert(MockFarm.FarmDown.selector);
        vault.harvestYield();
    }

    // ── 2. the days in between ───────────────────────────────────────────────

    /// @notice The window, party by party.
    function test_control_theWindowPartyByParty() public {
        _breakAndHatch(rescue);

        // Staker: no exit. The farm refuses, and once it recovers the stake is zero anyway.
        vm.prank(bob);
        vm.expectRevert(MockFarm.FarmDown.selector);
        vault.withdrawBonds(BOB_BONDS);

        // Borrower: the cure is refused by the solvency gate (not by the guardian), borrowing is
        // refused, and repayment is open - but a repaid borrower still cannot leave.
        bond.mint(alice, 10);
        vm.prank(alice);
        vm.expectRevert(CollateralVault.CustodyInsolvent.selector);
        vault.depositBonds(10);
        vm.prank(alice);
        vm.expectRevert(CreditManager.CustodyInsolvent.selector);
        credit.borrow(1e6);
        _repayAll(alice);
        assertEq(credit.debtOf(alice), 0, "repay is open");
        vm.prank(alice);
        vm.expectRevert(MockFarm.FarmDown.selector);
        vault.withdrawBonds(ALICE_BONDS);

        // Lender: the exit price carries no recognition of the insolvent custody.
        assertEq(pool.exitAssets(), pool.totalAssets(), "no mark for a ledger nothing backs");
        // And new lender money still enters unless the guardian shuts the pool.
        usdc.mint(lateLender, 1_000e6);
        vm.startPrank(lateLender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(500e6, lateLender);
        vm.stopPrank();
        vm.prank(guardian);
        pool.pause();
        vm.prank(lateLender);
        vm.expectRevert();
        pool.deposit(500e6, lateLender);

        // Harvest: permissionless and does not revert; there is nothing to harvest.
        harvester.harvest();
        assertEq(harvester.epochCount(), 0, "no epoch");
    }

    /// @notice A liquidation opened in the window can only end in a workout, and the forced close
    ///         writes the whole debt down against lenders while the collateral sits at the hatch
    ///         destination. CONTROL: the identical sequence with custody intact fills and returns the
    ///         surplus to the borrower.
    function test_control_aWindowLiquidationCanOnlyEndInAWorkoutAndTheLendersTakeTheLoss() public {
        uint256 nav = _navAtThreshold(carolDebt, CAROL_BONDS) - 1e6;
        uint256 clean = vm.snapshotState();

        // CONTROL: custody intact.
        oracle.setNav(nav);
        vm.prank(stranger);
        credit.liquidate(carol);
        uint256 id = auction.auctionOf(carol);
        uint256 assetsBefore = pool.totalAssets();
        vm.prank(bidder);
        auction.bid(id, type(uint256).max);
        uint256 controlSurplus = credit.claimableOf(carol);
        uint256 controlPoolLoss = assetsBefore - pool.totalAssets();
        assertGt(controlSurplus, 0, "control: the fill hands carol her surplus");
        emit log_named_uint("control surplus to carol", controlSurplus);
        emit log_named_uint("control pool loss", controlPoolLoss);
        vm.revertToState(clean);

        // The window.
        _breakAndHatch(rescue);
        oracle.setNav(nav);
        vm.prank(stranger);
        credit.liquidate(carol);
        id = auction.auctionOf(carol);
        vm.prank(bidder);
        vm.expectRevert(MockFarm.FarmDown.selector);
        auction.bid(id, type(uint256).max);
        // The cure is refused too.
        bond.mint(carol, 100);
        vm.prank(carol);
        vm.expectRevert(CollateralVault.CustodyInsolvent.selector);
        vault.depositBonds(100);

        skip(Config.AUCTION_DURATION);
        vm.prank(stranger);
        auction.expireToWorkout(id);
        assertEq(credit.bountyOwedTo(stranger), Config.LIQUIDATION_CALL_BOUNTY, "the caller is paid the escrow");
        assertEq(vault.bondCount(address(auction)), CAROL_BONDS, "the lot moved to the auction's ledger");

        skip(Config.WORKOUT_MAX_DURATION);
        assetsBefore = pool.totalAssets();
        vm.prank(stranger);
        auction.closeWorkout(id);
        uint256 windowPoolLoss = assetsBefore - pool.totalAssets();
        emit log_named_uint("window pool loss", windowPoolLoss);
        emit log_named_uint("window surplus to carol", credit.claimableOf(carol));
        assertEq(credit.claimableOf(carol), 0, "window: carol's surplus is gone");
        assertGt(windowPoolLoss, controlPoolLoss, "window: the lenders take a loss the control did not");
        assertEq(_bal(rescue), LEDGER, "while every bond is still sitting at the hatch destination");
    }

    // ── 3. the repair ────────────────────────────────────────────────────────

    /// @notice Every shipped door, tried in order, and none of them restores custody. These refusals
    ///         all still hold under the fix; the fix adds a door rather than opening one of these.
    function test_control_withoutARestakeNoShippedDoorRestoresCustody() public {
        _breakAndHatch(rescue);

        // A fresh adapter is refused: it is empty.
        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(fresh), true);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.CustodyWouldBeInsolvent.selector, 0, LEDGER));
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));

        // Hand it the rescued bonds: they arrive loose, and loose is not staked.
        vm.prank(rescue);
        bond.safeTransferFrom(rescue, address(fresh), 0, LEDGER, "");
        assertEq(_bal(address(fresh)), LEDGER);
        assertEq(fresh.stakedBalance(), 0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.CustodyWouldBeInsolvent.selector, 0, LEDGER));
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));

        // Nothing on the adapter stakes a loose balance without the vault, and the vault will not call.
        vm.prank(admin);
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        fresh.stake(LEDGER);

        // Back to the original adapter: the owner's hatch on the fresh one moves loose units too.
        vm.prank(admin);
        fresh.emergencyUnstake(address(adapter));
        assertEq(_bal(address(adapter)), LEDGER, "the bonds are back at the wired adapter");
        assertFalse(vault.custodyIsSolvent(), "and custody is still insolvent: loose is not staked");

        // The farm comes back. Still nothing.
        farm.setRevertOnWithdraw(false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, BOB_BONDS, 0));
        vault.withdrawBonds(BOB_BONDS);
        vm.prank(bob);
        bond.mint(bob, 1);
        vm.prank(bob);
        vm.expectRevert(CollateralVault.CustodyInsolvent.selector);
        vault.depositBonds(1);
    }

    /// @notice The one repair the shipped code admits: somebody buys a SECOND copy of the whole
    ///         collateral through DexFi's signed mint, naming the adapter as receiver, so the bond
    ///         auto-stakes it. Everyone is then whole, at the price of the entire lot, and the rescued
    ///         copy is stranded at an address DexFi has not whitelisted.
    function test_control_theOnlyShippedRepairIsBuyingASecondCopyOfTheCollateral() public {
        _breakAndHatch(rescue);
        farm.setRevertOnWithdraw(false); // the farm comes back

        uint256 price = 1 ether;
        vm.deal(rescue, price);
        vm.prank(rescue);
        bond.mint{value: price}(
            IDexFiBond.MintDataInput({
                uuid: 57_001,
                nonce: 0,
                receiver: address(adapter),
                amountNfts: LEDGER,
                paymentAmount: price,
                deadline: block.timestamp + 1 hours,
                signature: ""
            })
        );
        assertEq(adapter.stakedBalance(), LEDGER, "the purchase auto-staked for the adapter");
        assertTrue(vault.custodyIsSolvent());

        uint256 lenderOut = _everyoneLeaves();
        assertGe(lenderOut + 1, LENDER_DEPOSIT, "lender whole");
        assertEq(_bal(rescue), LEDGER, "and the rescued copy is still stranded at the hatch destination");
    }

    /// @notice FIX, same farm: the farm comes back, the owner re-stakes the rescued units with
    ///         `restakeLoose`, and borrowers, stakers and the lender all leave whole. No pointer moves.
    function test_fix_theFarmComesBackAndTheOwnerRestakesEveryoneWhole() public {
        // Hatch to the adapter itself: the units stay at the one whitelisted protocol address.
        _breakAndHatch(address(adapter));
        assertEq(_bal(address(adapter)), LEDGER, "loose at the adapter");
        assertFalse(vault.custodyIsSolvent());

        // Nobody else can move them in the window.
        vm.prank(bob);
        vm.expectRevert(MockFarm.FarmDown.selector);
        vault.withdrawBonds(BOB_BONDS);
        vm.prank(stranger);
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        adapter.transferBonds(stranger, 1);

        farm.setRevertOnWithdraw(false);
        (bool ok,) = _restake(adapter);
        assertTrue(ok, "restakeLoose() must exist and succeed for the owner");
        assertEq(adapter.stakedBalance(), LEDGER, "restaked");
        assertEq(vault.totalBondCount(), LEDGER, "no ledger entry was created");
        assertTrue(vault.custodyIsSolvent(), "custody backs the ledger again");

        // Lending resumes.
        vm.prank(alice);
        credit.borrow(1e6);

        uint256 lenderOut = _everyoneLeaves();
        emit log_named_uint("lender out", lenderOut);
        assertGe(lenderOut + 1, LENDER_DEPOSIT, "lender whole");
    }

    /// @notice FIX, new farm: DexFi replaced the reward pool. One hand-built timelock batch claims the
    ///         pending epoch, hatches the old adapter straight into a repair adapter, re-stakes, wires
    ///         the harvester and installs the adapter on the vault - one 48-hour operation - and the
    ///         next epoch runs off the new farm.
    function test_fix_aRepairAdapterGoesInOnVaultAndHarvesterInOneTimelockBatch() public {
        // Governance handover.
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
        vm.startPrank(admin);
        vault.transferOwnership(address(timelock));
        adapter.transferOwnership(address(timelock));
        harvester.transferOwnership(address(timelock));
        vm.stopPrank();

        // DexFi moves the bond onto a new reward pool; the old one still honours withdraw and holds
        // one last pending epoch.
        MockFarm newFarm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(newFarm));
        bond.setWhitelisted(address(newFarm), true);
        farm.setPendingYield(address(adapter), PENDING_EPOCH);

        DirectCallAdapter repair = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(newFarm)),
            usdc,
            address(vault),
            address(timelock),
            address(harvester)
        );
        bond.setWhitelisted(address(repair), true); // DexFi's half: whitelist the repair before installing it

        address[] memory targets = new address[](6);
        uint256[] memory values = new uint256[](6);
        bytes[] memory payloads = new bytes[](6);
        targets[0] = address(vault);
        payloads[0] = abi.encodeCall(CollateralVault.harvestYield, ());
        targets[1] = address(adapter);
        payloads[1] = abi.encodeCall(DirectCallAdapter.emergencyUnstake, (address(repair)));
        targets[2] = address(repair);
        payloads[2] = abi.encodeWithSignature("restakeLoose()");
        targets[3] = address(repair);
        payloads[3] = abi.encodeCall(DirectCallAdapter.setHarvester, (address(harvester)));
        targets[4] = address(harvester);
        payloads[4] = abi.encodeCall(EpochHarvester.setCustodyAdapter, (ICustodyAdapter(address(repair))));
        targets[5] = address(vault);
        payloads[5] = abi.encodeCall(CollateralVault.setCustodyAdapter, (ICustodyAdapter(address(repair))));

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("r57a01"), Config.ADMIN_TIMELOCK);
        skip(Config.ADMIN_TIMELOCK);

        uint256 g = gasleft();
        (bool ok,) = address(timelock)
            .call(
                abi.encodeCall(
                    TimelockController.executeBatch, (targets, values, payloads, bytes32(0), bytes32("r57a01"))
                )
            );
        uint256 used = g - gasleft();
        emit log_named_uint("repair batch gas", used);
        assertTrue(ok, "the whole repair must execute as one timelock batch");

        assertEq(address(vault.custodyAdapter()), address(repair));
        assertEq(address(harvester.custodyAdapter()), address(repair));
        assertEq(repair.stakedBalance(), LEDGER);
        assertTrue(vault.custodyIsSolvent());
        assertEq(
            usdc.balanceOf(address(harvester)), PENDING_EPOCH, "the old farm's last epoch was claimed, not forfeited"
        );

        // The next epoch runs off the new farm.
        newFarm.setPendingYield(address(repair), PENDING_EPOCH);
        harvester.harvest();
        assertEq(harvester.epochCount(), 1, "first post-repair epoch accepted");

        uint256 lenderOut = _everyoneLeaves();
        assertGe(lenderOut + 1, LENDER_DEPOSIT, "lender whole");
    }

    /// @notice The new door is owner-only and refuses an empty balance. Asserted as "refused" on both
    ///         trees, and by name where the function exists.
    function test_negative_theRestakeDoorIsOwnerOnlyAndRefusesNothingToStake() public {
        _breakAndHatch(address(adapter));

        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(adapter).call(abi.encodeWithSignature("restakeLoose()"));
        assertFalse(ok, "a stranger may not re-stake");
        if (ret.length != 0) {
            assertEq(ret, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        }

        // Hand the loose units to `rescue` so the adapter holds none, then ask the owner to restake.
        vm.prank(admin);
        adapter.emergencyUnstake(rescue);
        (ok, ret) = _restake(adapter);
        assertFalse(ok, "nothing loose, nothing to stake");
        if (ret.length != 0) assertEq(ret, abi.encodeWithSignature("NothingToRestake()"));
    }

    // ── 4. the doors ─────────────────────────────────────────────────────────

    /// @notice PINS-OPEN. A rescue short of the ledger by even one unit can never be installed: every
    ///         repair adapter is refused `CustodyWouldBeInsolvent`, and nothing can shrink the ledger
    ///         because every bond-count decrease unstakes. The owner must buy the shortfall. And on the
    ///         original adapter a short stake is a first-come run, because withdrawals do not consult
    ///         solvency: the fastest exits are whole and the last one bears the whole shortfall.
    ///         A green run of this case is not a clearance.
    function test_pinsOpen_aShortRescueIsNeverInstallableAndAShortStakeIsAFirstComeRun() public {
        // Rebuild on a farm whose owner can take part of a position.
        bond = new MockBond();
        usdc = new MockUSDC();
        address thief = makeAddr("thief");
        _build(new SkimmingFarm(bond, usdc, thief));
        uint256 clean = vm.snapshotState();

        // (a) The farm owner takes 100 of the adapter's 400; custody reads insolvent.
        SkimmingFarm(address(farm)).skim(address(adapter), 100);
        assertFalse(vault.custodyIsSolvent());
        // Withdrawals do not ask: bob leaves whole, alice repays and leaves whole, carol is stuck.
        vm.prank(bob);
        vault.withdrawBonds(BOB_BONDS);
        _repayAll(alice);
        vm.prank(alice);
        vault.withdrawBonds(ALICE_BONDS);
        _repayAll(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, CAROL_BONDS, 0));
        vault.withdrawBonds(CAROL_BONDS);
        assertEq(_bal(bob) + _bal(alice), BOB_BONDS + ALICE_BONDS, "the fast exits are whole");
        assertEq(vault.bondCount(carol), CAROL_BONDS, "the last one holds a ledger entry nothing backs");
        vm.revertToState(clean);

        // (b) The same skim, then the hatch: 300 rescued against a ledger of 400.
        SkimmingFarm(address(farm)).skim(address(adapter), 100);
        vm.prank(admin);
        adapter.emergencyUnstake(rescue);
        assertEq(_bal(rescue), LEDGER - 100);
        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(fresh), true);
        vm.prank(rescue);
        bond.safeTransferFrom(rescue, address(fresh), 0, LEDGER - 100, "");
        (bool ok,) = _restake(fresh);
        if (ok) {
            // Under the fix the short stake is as good as it gets, and the door still refuses it.
            assertEq(fresh.stakedBalance(), LEDGER - 100);
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(CollateralVault.CustodyWouldBeInsolvent.selector, LEDGER - 100, LEDGER)
            );
            vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));
        }
    }

    /// @notice PINS-OPEN. A farm that hands the bonds back on `emergencyWithdraw` but leaves its stake
    ///         record standing welds the vault to the old adapter (`AdapterHasLivePosition`) and makes
    ///         `custodyIsSolvent()` read true over bonds the protocol no longer holds, so `borrow`
    ///         reopens against them. The escape and the solvency gate both trust the farm's word.
    ///         A green run of this case is not a clearance.
    function test_pinsOpen_aFarmThatKeepsItsStakeRecordWeldsTheVaultAndReopensLending() public {
        bond = new MockBond();
        usdc = new MockUSDC();
        _build(new LyingFarm(bond, usdc));

        vm.prank(admin);
        adapter.emergencyUnstake(rescue);
        assertEq(_bal(rescue), LEDGER, "the bonds came out");
        assertEq(adapter.stakedBalance(), LEDGER, "and the farm still reports them staked");
        assertTrue(vault.custodyIsSolvent(), "so custody reads solvent");

        // Lending reopens against collateral that is at `rescue`.
        vm.prank(bob);
        credit.borrow(100e6);
        assertEq(credit.debtOf(bob), 100e6, "new debt against rescued collateral");

        // And the repair is refused on the outgoing side, whatever the repair adapter holds.
        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(fresh), true);
        vm.prank(rescue);
        bond.safeTransferFrom(rescue, address(fresh), 0, LEDGER, "");
        _restake(fresh);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AdapterHasLivePosition.selector, LEDGER));
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));
    }

    /// @notice PINS-OPEN. Who a short stake's loss lands on. The pure staker, who owes nothing and so
    ///         is never LTV-gated, drains the shared stake first; the borrower left last holds a ledger
    ///         entry nothing backs, keeps the loan, and the LENDERS take the write-down when that
    ///         position is liquidated - a bid cannot seize, so it ends in a forced close.
    ///         A green run of this case is not a clearance.
    function test_pinsOpen_aSkimmedStakeRunsToTheStakerFirstAndTheLenderBearsTheLastLedger() public {
        bond = new MockBond();
        usdc = new MockUSDC();
        _build(new SkimmingFarm(bond, usdc, makeAddr("thief")));

        SkimmingFarm(address(farm)).skim(address(adapter), 100);
        vm.prank(bob);
        vault.withdrawBonds(BOB_BONDS); // the staker leaves whole
        _repayAll(alice);
        vm.prank(alice);
        vault.withdrawBonds(ALICE_BONDS); // so does the borrower who repays first
        assertEq(adapter.stakedBalance(), 0, "nothing left in custody");
        assertEq(vault.bondCount(carol), CAROL_BONDS, "carol's ledger entry is unbacked");
        assertEq(credit.debtOf(carol), carolDebt, "and her loan stands");
        assertEq(pool.exitAssets(), pool.totalAssets(), "the pool marks nothing for it");

        oracle.setNav(_navAtThreshold(carolDebt, CAROL_BONDS) - 1e6);
        vm.prank(stranger);
        credit.liquidate(carol);
        uint256 id = auction.auctionOf(carol);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, CAROL_BONDS, 0));
        auction.bid(id, type(uint256).max);
        skip(Config.AUCTION_DURATION);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);
        uint256 before = pool.totalAssets();
        auction.closeWorkout(id);
        uint256 lenderLoss = before - pool.totalAssets();
        emit log_named_uint("lender loss on the last ledger", lenderLoss);
        assertEq(lenderLoss, carolDebt, "the lenders bear the whole of the unbacked position");
    }

    /// @notice FIX, ordering. Installing the repair adapter on the vault a batch before the harvester
    ///         follows costs a delayed epoch and nothing else: the harvester keeps claiming from the old
    ///         adapter, declines, and the USDC the repair adapter delivers waits in the harvester until
    ///         the pointer follows and a further dollar of farm yield corroborates it.
    function test_fix_theWrongWiringOrderDelaysAnEpochAndLosesNothing() public {
        _breakAndHatch(address(adapter));
        farm.setRevertOnWithdraw(false);
        MockFarm newFarm = new MockFarm(bond, usdc);
        bond.setWhitelisted(address(newFarm), true);
        DirectCallAdapter repair = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(newFarm)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(repair), true);

        vm.startPrank(admin);
        adapter.emergencyUnstake(address(repair));
        vm.stopPrank();
        (bool ok,) = _restake(repair);
        assertTrue(ok, "restakeLoose() must exist and succeed for the owner");
        vm.startPrank(admin);
        repair.setHarvester(address(harvester));
        vault.setCustodyAdapter(ICustodyAdapter(address(repair))); // the vault moves first
        vm.stopPrank();

        newFarm.setPendingYield(address(repair), PENDING_EPOCH);
        vm.prank(bob);
        vault.withdrawBonds(1); // any farm-touching path sweeps the epoch to the harvester
        assertEq(usdc.balanceOf(address(harvester)), PENDING_EPOCH, "delivered");
        harvester.harvest();
        assertEq(harvester.epochCount(), 0, "declined: the harvester still reads the old adapter");

        vm.prank(admin);
        harvester.setCustodyAdapter(ICustodyAdapter(address(repair)));
        harvester.harvest();
        assertEq(harvester.epochCount(), 0, "still declined: the re-seed discarded the corroboration");

        newFarm.setPendingYield(address(repair), Config.MIN_EPOCH_FARM_YIELD);
        harvester.harvest();
        assertEq(harvester.epochCount(), 1, "the next dollar runs the whole backlog as one epoch");
        assertEq(
            usdc.balanceOf(address(harvester)),
            0 + harvester.pendingLenderYield() + harvester.pendingProtocolFee(),
            "nothing stranded: every dollar is split or accrued"
        );
    }

    /// @notice A door that lets a broken repair through: a pre-staked repair adapter DexFi has not
    ///         whitelisted installs cleanly, solvency reads true so `borrow` reopens, and every exit
    ///         that moves a bond - withdraw, fill, disposal - reverts inside DexFi's gate.
    function test_control_anUnwhitelistedRepairAdapterInstallsAndFreezesEveryExit() public {
        _breakAndHatch(rescue);
        farm.setRevertOnWithdraw(false);

        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        // Pre-staked by the one shipped route (a DexFi-signed purchase naming it), never whitelisted.
        vm.deal(rescue, 1 ether);
        vm.prank(rescue);
        bond.mint{value: 1 ether}(
            IDexFiBond.MintDataInput({
                uuid: 57_002,
                nonce: 0,
                receiver: address(fresh),
                amountNfts: LEDGER,
                paymentAmount: 1 ether,
                deadline: block.timestamp + 1 hours,
                signature: ""
            })
        );
        assertFalse(bond.whitelistContains(address(fresh)));
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));
        assertTrue(vault.custodyIsSolvent());

        vm.prank(bob);
        credit.borrow(100e6); // lending reopened
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(MockBond.AddressesNotWhitelisted.selector, address(fresh), address(fresh), bob)
        );
        vault.withdrawBonds(1);
    }
}
