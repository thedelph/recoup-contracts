// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
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

/// @notice TEST-ONLY prototype of the "sanctioned unstake-and-restake path" round-57 item 141 asks
///         for: a `DirectCallAdapter` with ONE extra owner door that pulls bonds the owner holds and
///         stakes them into this adapter's own farm position, crediting NOBODY on the vault ledger.
/// @dev Not shipped and not proposed as shipped code by this file. It exists so the owner's best
///      recovery sequence can be EXECUTED end to end rather than argued. The shipped
///      `DirectCallAdapter` has no such door: `stake` is `onlyVault`, and the vault reaches it only
///      from `depositBonds`, which since round 56 refuses while custody is insolvent.
contract R57A02RestakeRepairAdapter is DirectCallAdapter {
    constructor(
        IDexFiBond bond_,
        IDexFiFarm farm_,
        IERC20 usdc_,
        address vault_,
        address initialOwner,
        address yieldRecipient_
    ) DirectCallAdapter(bond_, farm_, usdc_, vault_, initialOwner, yieldRecipient_) {}

    /// @dev Pull `amount` bonds from `from` (which must have approved this adapter) and stake them
    ///      under this adapter's own farm position. No ledger entry moves anywhere.
    function ownerRestake(address from, uint256 amount) external onlyOwner {
        bond.safeTransferFrom(from, address(this), Config.DEXFI_BOND_TOKEN_ID, amount, "");
        farm.deposit(amount);
    }
}

/// @notice TEST-ONLY: a repair adapter carrying exactly the two views the vault probes plus the
///         bonds it holds, and nothing else - no `farmYieldDeliveredToHarvester`. Round-57 item
///         223's inferred half, executed.
contract R57A02TwoViewRepairAdapter {
    address public immutable vault;
    uint256 public stakedBalance;

    constructor(address vault_, uint256 staked_) {
        vault = vault_;
        stakedBalance = staked_;
    }
}

/// @title R57A02 - the break-glass recovery after round 56's deposit refusal (#514)
/// @notice Audit round 57, agent A2, target 1: round-57 items 139, 140, 141 and 223 re-executed at
///         `82679aa`, plus round-57 item 243's question. Self-contained: deploys its own stack and
///         inherits no fixture.
///
///         What `82679aa` does after `DirectCallAdapter.emergencyUnstake`, MEASURED here:
///         - both deposit doors refuse `CustodyInsolvent()` by themselves, in the same transaction
///           as the hatch, with every pause switch still off (`hatch_` case);
///         - the round-50 escape "hatch, then repoint to a correctly-anchored adapter" is REFUSED by
///           #491's `CustodyWouldBeInsolvent`, so in item 139's state (DexFi moved the reward pool
///           under a live position) NO shipped door reaches a working custody (`pin_` case);
///         - the only way back WITHOUT double-crediting anybody is an adapter the owner has already
///           staked with the rescued bonds, which the shipped `DirectCallAdapter` cannot be
///           (`limit_` cases) - so the owner's best sequence needs NEW code, executed here as
///           `R57A02RestakeRepairAdapter` (`recovery_` case), plus a DexFi whitelist entry;
///         - with shipped code alone the one other door is a DexFi HANDLER's
///           `depositForAccount(liveAdapter, n)` on a farm that still works (`dexfi_` case).
///
/// @dev 🟥 **PINS-OPEN: the `pin_` case asserts the CURRENT behaviour - after the hatch no shipped
///      door restores custody in the anchor-moved state - and the `recovery_` case runs on a
///      test-only adapter that the tree does not ship. A green run of this file is not a
///      clearance.**
contract R57A02_BreakGlassRecovery is Test {
    bytes4 internal constant CUSTODY_INSOLVENT = bytes4(keccak256("CustodyInsolvent()"));
    bytes4 internal constant WOULD_BE_INSOLVENT = bytes4(keccak256("CustodyWouldBeInsolvent(uint256,uint256)"));

    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant TREASURY_FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal rescueWallet = makeAddr("rescueWallet");
    address internal stranger = makeAddr("stranger");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal treasury;
    EpochHarvester internal harvester;
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
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        treasury = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        adapter.setHarvester(address(harvester));
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        harvester.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
        usdc.mint(address(treasury), TREASURY_FLOAT);

        _seed(alice, BONDS);
        _seed(bob, BONDS);
        // alice borrows at the ceiling, so a NAV drop makes her liquidatable. Computed before the
        // prank: `_maxBorrow` makes an external call that would consume it.
        uint256 debt = _maxBorrow(BONDS);
        vm.prank(alice);
        credit.borrow(debt);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _seed(address who, uint256 bonds) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    function _maxBorrow(uint256 bonds) internal view returns (uint256) {
        return (bonds * NAV * riskParams.maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    function _hatch() internal {
        vm.prank(admin);
        adapter.emergencyUnstake(rescueWallet);
        assertEq(bond.balanceOf(rescueWallet, Config.DEXFI_BOND_TOKEN_ID), 2 * BONDS, "premise: bonds left custody");
        assertEq(adapter.stakedBalance(), 0, "premise: adapter holds nothing");
        assertEq(vault.totalBondCount(), 2 * BONDS, "premise: ledger unchanged");
        assertFalse(vault.custodyIsSolvent(), "premise: insolvent");
    }

    function _mintData(address beneficiary, bytes32 attemptId, DirectCallAdapter a, uint256 bonds)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            IDexFiBond.MintDataInput({
                uuid: uint256(keccak256(abi.encode(attemptId, address(a)))),
                nonce: 0,
                receiver: a.predictMintReceiver(beneficiary, attemptId),
                amountNfts: bonds,
                paymentAmount: 1 ether,
                deadline: block.timestamp + 1 hours,
                signature: ""
            })
        );
    }

    function _dexfiReplacesTheRewardPool() internal returns (MockFarm replacement) {
        replacement = new MockFarm(bond, usdc);
        bond.setRewardPool(address(replacement));
        bond.setWhitelisted(address(replacement), true);
    }

    // ── round-57 item 243: the hatch closes both deposit doors by itself ─────

    /// @notice MEASURED. The hatch alone, with every pause switch OFF, leaves: both deposit doors
    ///         refusing `CustodyInsolvent()`, `borrow` refusing `CustodyInsolvent()`, `repay` open,
    ///         `withdrawBonds` dying inside the farm, `bid` dying inside the farm, and the exit of
    ///         last resort (`expireToWorkout`) still total. So the operational question "pause
    ///         deposits in the same batch" has no deposit-safety content any more: nothing a pause
    ///         would shut is still open.
    function test_R57A02_243_hatch_closesBothDepositDoorsWithNoPauseThrown() public {
        _hatch();
        assertFalse(vault.paused(), "premise: vault not paused");
        assertFalse(vault.bondDepositsPaused(), "premise: bond deposits not paused");
        assertFalse(credit.paused(), "premise: manager not paused");

        // depositBonds: refused by name, nothing moves.
        vm.prank(carol);
        bond.setApprovalForAll(address(vault), true);
        bond.mint(carol, 50);
        vm.prank(carol);
        vm.expectRevert(CUSTODY_INSOLVENT);
        vault.depositBonds(50);

        // depositETH: refused by name before the mint is attempted.
        bytes32 attemptId = keccak256("r57a02.hatch.eth");
        bytes memory mintData = _mintData(carol, attemptId, adapter, 40);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(CUSTODY_INSOLVENT);
        vault.depositETH{value: 1 ether}(attemptId, mintData);
        assertEq(address(adapter.predictMintReceiver(carol, attemptId)).code.length, 0, "a clone was deployed");

        // borrow: refused by the manager's own custody gate.
        vm.prank(bob);
        vm.expectRevert(CreditManager.CustodyInsolvent.selector);
        credit.borrow(100e6);

        // repay: open.
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(credit), 10e6);
        credit.repay(10e6);
        vm.stopPrank();

        // withdraw: dies inside the farm (stake 0).
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, uint256(1), uint256(0)));
        vault.withdrawBonds(1);

        // liquidation: opens (bookkeeping only), the fill dies inside the farm, the expiry is total.
        oracle.setNav(NAV / 3);
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        assertGt(id, 0, "no auction opened");
        uint256 price = auction.currentPrice(id);
        usdc.mint(stranger, price);
        vm.startPrank(stranger);
        usdc.approve(address(auction), price);
        vm.expectRevert();
        auction.bid(id);
        vm.stopPrank();
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(auction.workoutsOpenFor(alice), 1, "the exit of last resort did not open a workout");
        emit log_named_uint("MEASURED ledger after the hatch (total)", vault.totalBondCount());
        emit log_named_uint("MEASURED custody stake after the hatch", adapter.stakedBalance());
    }

    // ── round-57 item 139, re-executed after #491 and #514 ───────────────────

    /// @notice PIN (open). Item 139's state - DexFi moves the bond's reward pool under a LIVE
    ///         position - at `82679aa`. The correctly-anchored adapter is refused
    ///         `AdapterHasLivePosition` while anything is staked (unchanged since round 50), and the
    ///         round-50 escape (hatch, then repoint) is now refused `CustodyWouldBeInsolvent(0, 200)`
    ///         (#491), while the hatch shuts both deposit doors (#514). Round 50's replay of
    ///         A3's own file at this tree turns exactly `test_R50_146a_emergencyUnstakeFrees...` red
    ///         with `CustodyWouldBeInsolvent(0, 3)`. So NO shipped door reaches a working custody.
    function test_R57A02_139_pin_afterTheAnchorMovesNoShippedDoorReachesAWorkingCustody() public {
        MockFarm replacement = _dexfiReplacesTheRewardPool();
        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(replacement)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(fresh), true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AdapterHasLivePosition.selector, 2 * BONDS));
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));

        _hatch();
        vm.prank(admin);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(vault.setCustodyAdapter, (ICustodyAdapter(address(fresh)))));
        assertFalse(ok, "PINS-OPEN: the hatch frees the anchor repoint again - re-read rows 139 and 141");
        assertEq(
            keccak256(ret),
            keccak256(abi.encodeWithSelector(WOULD_BE_INSOLVENT, uint256(0), 2 * BONDS)),
            "refused, but not by the round-55 clause"
        );

        // And the rescued bonds cannot re-enter through the vault either (#514).
        vm.startPrank(rescueWallet);
        bond.setApprovalForAll(address(vault), true);
        vm.expectRevert(CUSTODY_INSOLVENT);
        vault.depositBonds(2 * BONDS);
        vm.stopPrank();
        assertEq(address(vault.custodyAdapter()), address(adapter), "the pointer moved");
    }

    // ── round-57 item 140, re-executed: #514 changes nothing here ─────────────

    /// @notice CONTROL for #514's reach. Custody stays SOLVENT after DexFi's reward-pool move, so the
    ///         new refusal does not bite: `depositBonds` still stakes into the abandoned farm and
    ///         credits the depositor, and `depositETH` still dies `MintAmountMismatch(40, 0)` for
    ///         every caller. Round-57 item 140 stands unchanged at `82679aa`.
    function test_R57A02_140_control_theAnchorMoveIsUntouchedByTheDepositRefusal() public {
        MockFarm replacement = _dexfiReplacesTheRewardPool();
        _seed(carol, 50);
        assertEq(farm.staked(address(adapter)), 2 * BONDS + 50, "the deposit went into the OLD farm");
        assertEq(replacement.staked(address(adapter)), 0, "and none into the pool the bond now pays");
        assertTrue(vault.custodyIsSolvent(), "the vault calls that solvent");
        assertEq(vault.bondCount(carol), 50, "and credits carol");

        bytes32 attemptId = keccak256("r57a02.140.eth");
        bytes memory mintData = _mintData(carol, attemptId, adapter, 40);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.MintAmountMismatch.selector, uint256(40), uint256(0)));
        vault.depositETH{value: 1 ether}(attemptId, mintData);
    }

    // ── round-57 item 141: the owner's best recovery sequence ────────────────

    /// @notice The owner's BEST recovery, executed end to end on the item-139 state, on a TEST-ONLY
    ///         adapter (`R57A02RestakeRepairAdapter`, one extra owner door). Sequence:
    ///           1. `adapter.emergencyUnstake(rescueWallet)` - custody insolvent, both deposit doors
    ///              shut by the vault itself, `borrow` shut by the manager itself;
    ///           2. deploy the repair adapter on the farm the bond NOW pays, DexFi whitelists it;
    ///           3. `repair.ownerRestake(rescueWallet, 200)` - stakes the rescued bonds, credits nobody;
    ///           4. `vault.setCustodyAdapter(repair)` - admitted, incoming 200 >= ledger 200;
    ///           5. `repair.setHarvester`, `harvester.setCustodyAdapter(repair)`.
    ///         Afterwards custody is solvent, every ledger entry withdraws exactly what it holds
    ///         (nobody is credited twice, the rescue wallet ends with none of anyone's bonds), the ETH
    ///         mint path works again on the new farm, and a later deposit is ordinary.
    function test_R57A02_141_recovery_restakeRepairAdapterRestoresCustodyWithoutDoubleCredit() public {
        MockFarm replacement = _dexfiReplacesTheRewardPool();
        _hatch();

        R57A02RestakeRepairAdapter repair = new R57A02RestakeRepairAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(replacement)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(repair), true); // DexFi's act, not the owner's

        vm.prank(rescueWallet);
        bond.setApprovalForAll(address(repair), true);
        vm.startPrank(admin);
        repair.ownerRestake(rescueWallet, 2 * BONDS);
        vault.setCustodyAdapter(ICustodyAdapter(address(repair)));
        repair.setHarvester(address(harvester));
        harvester.setCustodyAdapter(ICustodyAdapter(address(repair)));
        vm.stopPrank();

        assertTrue(vault.custodyIsSolvent(), "custody is not solvent after the repair");
        assertEq(repair.stakedBalance(), vault.totalBondCount(), "stake != ledger");
        assertEq(bond.balanceOf(rescueWallet, Config.DEXFI_BOND_TOKEN_ID), 0, "the rescue wallet kept bonds");

        // bob exits in full; alice exits down to her LTV ceiling. Exactly their ledger entries.
        uint256 bobBefore = bond.balanceOf(bob, Config.DEXFI_BOND_TOKEN_ID);
        vm.prank(bob);
        vault.withdrawBonds(BONDS);
        assertEq(bond.balanceOf(bob, Config.DEXFI_BOND_TOKEN_ID) - bobBefore, BONDS, "bob was not paid his entry");

        // The ETH mint path works on the repaired custody (the item-140 total failure is healed).
        bytes32 attemptId = keccak256("r57a02.141.eth");
        bytes memory mintData = _mintData(carol, attemptId, repair, 40);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vault.depositETH{value: 1 ether}(attemptId, mintData);
        assertEq(vault.bondCount(carol), 40, "the mint path did not credit carol");
        assertEq(repair.stakedBalance(), vault.totalBondCount(), "stake != ledger after a mint");

        // Full exit of everyone who can: the stake drains exactly with the ledger.
        vm.prank(carol);
        vault.withdrawBonds(40);
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(credit), type(uint256).max);
        credit.repay(credit.currentDebtOf(alice));
        vault.withdrawBonds(BONDS);
        vm.stopPrank();
        assertEq(vault.totalBondCount(), 0, "ledger not drained");
        assertEq(repair.stakedBalance(), 0, "stake not drained with the ledger: somebody was credited twice");
        emit log_named_uint("MEASURED ledger after every exit", vault.totalBondCount());
        emit log_named_uint("MEASURED repair stake after every exit", repair.stakedBalance());
    }

    /// @notice CONTROL, and a side effect of #514 nobody filed: a stranger cannot grief the repair.
    ///         Between the hatch and the owner's repoint (48 hours apart under G2) a one-bond
    ///         `depositBonds` used to stake into the OLD adapter, after which `setCustodyAdapter`
    ///         refused `AdapterHasLivePosition(1)` and the ledger grew past what the owner holds. At
    ///         `82679aa` that deposit is refused `CustodyInsolvent()` and the repair lands. (Neutered
    ///         to the pre-#514 vault this case goes red, `AdapterHasLivePosition(1)`.)
    function test_R57A02_141_control_aStrangerCannotGriefTheRepairAfterTheHatch() public {
        MockFarm replacement = _dexfiReplacesTheRewardPool();
        _hatch();
        R57A02RestakeRepairAdapter repair = new R57A02RestakeRepairAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(replacement)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(repair), true);
        vm.prank(rescueWallet);
        bond.setApprovalForAll(address(repair), true);
        vm.prank(admin);
        repair.ownerRestake(rescueWallet, 2 * BONDS);

        // The griefer's one bond, between the restake and the repoint.
        bond.mint(stranger, 1);
        vm.startPrank(stranger);
        bond.setApprovalForAll(address(vault), true);
        (bool griefed,) = address(vault).call(abi.encodeCall(CollateralVault.depositBonds, (1)));
        vm.stopPrank();
        emit log_named_uint("MEASURED griefer's post-hatch deposit admitted (1 = yes)", griefed ? 1 : 0);

        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(repair)));
        assertTrue(vault.custodyIsSolvent(), "the repair did not land");
    }

    // ── what the best sequence cannot do ─────────────────────────────────────

    /// @notice LIMIT. The shipped `DirectCallAdapter` cannot be the repair: bonds handed to it sit
    ///         LOOSE (stake 0), the vault refuses it `CustodyWouldBeInsolvent(0, 200)`, and the owner
    ///         cannot call `stake` (`NotVault`). This is why the best sequence needs new code.
    function test_R57A02_141_limit_theShippedAdapterCannotBePreStaked() public {
        _hatch();
        DirectCallAdapter plain = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(plain), true);
        vm.prank(rescueWallet);
        bond.safeTransferFrom(rescueWallet, address(plain), Config.DEXFI_BOND_TOKEN_ID, 2 * BONDS, "");
        assertEq(plain.stakedBalance(), 0, "loose bonds read as stake");

        vm.prank(admin);
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        plain.stake(2 * BONDS);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(WOULD_BE_INSOLVENT, uint256(0), 2 * BONDS));
        vault.setCustodyAdapter(ICustodyAdapter(address(plain)));
    }

    /// @notice LIMIT. The repair is all-or-nothing: an owner holding even ONE bond fewer than the
    ///         ledger (a rescued bond sold, lost, or never rescued) cannot install it, and there is
    ///         no partial repair - the ledger has no write-down door for custody losses.
    function test_R57A02_141_limit_aShortRescueCannotRestoreCustody() public {
        MockFarm replacement = _dexfiReplacesTheRewardPool();
        _hatch();
        R57A02RestakeRepairAdapter repair = new R57A02RestakeRepairAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(replacement)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(repair), true);
        vm.prank(rescueWallet);
        bond.setApprovalForAll(address(repair), true);
        vm.startPrank(admin);
        repair.ownerRestake(rescueWallet, 2 * BONDS - 1);
        vm.expectRevert(abi.encodeWithSelector(WOULD_BE_INSOLVENT, 2 * BONDS - 1, 2 * BONDS));
        vault.setCustodyAdapter(ICustodyAdapter(address(repair)));
        vm.stopPrank();
    }

    /// @notice LIMIT. The repair adapter needs a DexFi whitelist entry of its own: without it the
    ///         restake dies in DexFi's transfer gate (`AddressesNotWhitelisted`). That is a third
    ///         party's act (PRD 14 ask 5) on the critical path of every recovery.
    function test_R57A02_141_limit_theRepairNeedsDexFisWhitelist() public {
        MockFarm replacement = _dexfiReplacesTheRewardPool();
        _hatch();
        R57A02RestakeRepairAdapter repair = new R57A02RestakeRepairAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(replacement)), usdc, address(vault), admin, address(harvester)
        );
        vm.prank(rescueWallet);
        bond.setApprovalForAll(address(repair), true);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockBond.AddressesNotWhitelisted.selector, address(repair), rescueWallet, address(repair)
            )
        );
        repair.ownerRestake(rescueWallet, 2 * BONDS);
    }

    /// @notice LIMIT, round-57 item 223's INFERRED half, executed. A repair adapter carrying only the
    ///         two views the VAULT probes installs on the vault (custody solvent again), but
    ///         `EpochHarvester.setCustodyAdapter` reads `farmYieldDeliveredToHarvester()` bare and
    ///         dies with EMPTY returndata, so every repair must carry that member too or its yield is
    ///         never corroborated.
    function test_R57A02_223_limit_aRepairWithoutTheHarvesterCounterCannotBeHarvested() public {
        _hatch();
        R57A02TwoViewRepairAdapter bare = new R57A02TwoViewRepairAdapter(address(vault), 2 * BONDS);
        vm.prank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(bare)));
        assertTrue(vault.custodyIsSolvent(), "the vault did not admit the two-view repair");

        vm.prank(admin);
        (bool ok, bytes memory ret) =
            address(harvester).call(abi.encodeCall(harvester.setCustodyAdapter, (ICustodyAdapter(address(bare)))));
        emit log_named_uint("MEASURED harvester admitted the two-view repair (1 = yes)", ok ? 1 : 0);
        emit log_named_uint("MEASURED harvester refusal returndata length", ret.length);
        assertFalse(ok, "the harvester admitted a repair with no farmYieldDeliveredToHarvester");
        assertEq(ret.length, 0, "the harvester named the missing member (it did not at 82679aa)");
    }

    /// @notice LIMIT, and an ORDERING the owner must know. A closed workout's lot parked under the
    ///         auction at the moment of the hatch cannot be disposed (the unstake dies in the farm),
    ///         and while it stands the vault refuses BOTH wiring doors `AuctionHasLiveWork(100)`, so the
    ///         manager and the auction cannot be migrated until custody is repaired. The restake
    ///         repair then clears it: the disposal works and so does the migration.
    function test_R57A02_141_limit_aParkedLotWeldsTheWiringUntilCustodyIsRepaired() public {
        // alice defaults, expires to workout, a rescuer clears her debt, the workout closes clean.
        oracle.setNav(NAV / 3);
        vm.prank(keeper);
        credit.liquidate(alice);
        uint256 id = auction.auctionOf(alice);
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        oracle.setNav(NAV);
        uint256 owed = credit.currentDebtOf(alice);
        usdc.mint(stranger, owed);
        vm.startPrank(stranger);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();
        auction.closeWorkout(id);
        assertEq(vault.bondCount(address(auction)), BONDS, "premise: the lot is parked under the auction");

        MockFarm replacement = _dexfiReplacesTheRewardPool();
        _hatch();

        bond.setWhitelisted(alice, true);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MockFarm.InsufficientStake.selector, BONDS, uint256(0)));
        auction.disposeWorkoutLot(id, alice);

        CreditManager fresh = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, BONDS));
        vault.setCreditManager(address(fresh));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AuctionHasLiveWork.selector, BONDS));
        vault.setLiquidationAuction(address(auction));

        // The repair, then the disposal and the migration both work.
        R57A02RestakeRepairAdapter repair = new R57A02RestakeRepairAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(replacement)), usdc, address(vault), admin, address(harvester)
        );
        bond.setWhitelisted(address(repair), true);
        vm.prank(rescueWallet);
        bond.setApprovalForAll(address(repair), true);
        vm.startPrank(admin);
        repair.ownerRestake(rescueWallet, 2 * BONDS);
        vault.setCustodyAdapter(ICustodyAdapter(address(repair)));
        auction.disposeWorkoutLot(id, alice);
        vm.stopPrank();
        assertEq(vault.bondCount(address(auction)), 0, "the lot was not disposed after the repair");
        assertEq(bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID), 1_000, "alice did not get her lot back");
        assertEq(repair.stakedBalance(), vault.totalBondCount(), "stake != ledger after the disposal");
    }

    // ── the one shipped-code door: a DexFi handler ───────────────────────────

    /// @notice MODEL (the live farm gates `depositForAccount` with `onlyHandler` over four DexFi keys;
    ///         `MockFarm` gates it `onlyBond`, so the handler is played by the bond address here).
    ///         With the OLD farm still working, a DexFi handler holding the rescued bonds can credit
    ///         them straight back to the LIVE adapter: custody is solvent again with no new code and
    ///         no repoint, and nobody is credited twice. Needs a DexFi key, and does nothing for item
    ///         139's anchor move (the stake goes back into the abandoned farm).
    function test_R57A02_141_dexfi_aHandlerCanRestoreTheLiveAdapterWithShippedCode() public {
        _hatch();
        // The handler must own the bonds: model it as the rescue wallet moving them into the pool
        // and the handler crediting the adapter.
        vm.prank(rescueWallet);
        bond.safeTransferFrom(rescueWallet, address(farm), Config.DEXFI_BOND_TOKEN_ID, 2 * BONDS, "");
        vm.prank(address(bond));
        farm.depositForAccount(address(adapter), 2 * BONDS);
        assertTrue(vault.custodyIsSolvent(), "custody not restored");
        vm.prank(bob);
        vault.withdrawBonds(BONDS);
        assertEq(vault.bondCount(bob), 0, "bob could not exit");
        assertEq(adapter.stakedBalance(), vault.totalBondCount(), "stake != ledger");
    }
}
