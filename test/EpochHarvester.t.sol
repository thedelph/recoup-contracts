// SPDX-License-Identifier: MIT
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
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice A lender pool that accepts a flush but pulls less than it was offered.
///         Exists to prove `flushLenderYield` verifies delivery rather than assuming
///         it: zeroing the counter around an unverified transfer would silently
///         forgive the difference and leave USDC in the harvester that nothing claims.
contract ShortPool {
    IERC20 public immutable usdc;
    uint256 public immutable shortfall;

    constructor(IERC20 usdc_, uint256 shortfall_) {
        usdc = usdc_;
        shortfall = shortfall_;
    }

    function distributeYield(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount - shortfall);
    }
}

/// @notice Stands in for the Phase-4 `LenderPool` skeleton, whose `distributeYield`
///         reverts `NotImplemented` until the pool opens. This is what the deploy
///         script actually wires, so it is the shape every pre-Phase-4 lender share
///         accrues against.
contract RevertingPool {
    error NotImplemented();

    function distributeYield(uint256) external pure {
        revert NotImplemented();
    }
}

/// @notice A pool that takes delivery, for the paths where the outgoing pool works.
contract AcceptingPool {
    IERC20 public immutable usdc;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function distributeYield(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice The weekly epoch (PRD §4.4, §6.2): claim from the farm, split 55/25/10/10,
///         write borrower debt down, and do it without iterating positions.
contract EpochHarvesterTest is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant FLOAT = 100_000e6;
    uint256 internal constant YIELD = 1_000e6;

    /// @dev At most 1 wei of USDC is left behind by a stream's rate truncation, and a
    ///      test that accrues twice can compound that to 2. Anything larger is a real
    ///      accounting bug, so this stays tight rather than being widened to pass.
    uint256 internal constant DUST = 2;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeWallet = makeAddr("feeWallet");
    address internal caller = makeAddr("caller");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    EpochHarvester internal harvester;
    TreasuryLiquiditySource internal liquidity;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        // The adapter routes claims to the harvester, which is the Phase 3 wiring.
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        // The vault refuses an auction pointer that is not a contract bound back to it,
        // so suites that never run a liquidation still need a stand-in.
        MockLiquidationAuction auctionStub = new MockLiquidationAuction();
        auctionStub.setVault(address(vault));
        auctionStub.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auctionStub));
        // `borrow` refuses while the vault names an auction this manager does not, so
        // the stand-in has to be wired on both sides rather than just the vault's.
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

        _deposit(alice, 100);
    }

    function _deposit(address who, uint256 bonds) private {
        bond.mint(who, bonds);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(bonds);
        vm.stopPrank();
    }

    /// @dev Harvest, then let the epoch's borrower share finish streaming.
    ///      `distributeYield` spreads the share over YIELD_STREAM_DURATION rather than
    ///      crediting it at once, so nothing is claimable in the harvest block - that
    ///      is the whole point of it. These tests assert how a completed epoch lands,
    ///      so they run the stream out; the streaming itself is covered in
    ///      CreditManager.t.sol.
    function _harvestAndStream() private {
        harvester.harvest();
        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();
    }

    // ── the split ────────────────────────────────────────────────────────────

    function test_harvest_splitsPerConfig() public {
        farm.setPendingYield(address(adapter), YIELD);

        vm.prank(caller); // permissionless
        _harvestAndStream();

        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        uint256 toLenders = (YIELD * Config.SPLIT_LENDER_BPS) / Config.BPS;
        uint256 toInsurance = (YIELD * Config.SPLIT_INSURANCE_BPS) / Config.BPS;
        uint256 toProtocol = YIELD - toBorrowers - toLenders - toInsurance;

        assertApproxEqAbs(
            credit.accYieldPerBond() * 100 / 1e18, toBorrowers, DUST, "borrower share distributed"
        );
        assertEq(credit.insuranceFund(), toInsurance);
        assertEq(harvester.pendingLenderYield(), toLenders, "held until the pool opens");
        harvester.flushProtocolFee();
        assertEq(usdc.balanceOf(feeWallet), toProtocol);
    }

    /// @dev Nothing may be left behind in the harvester beyond the lender share it is
    ///      deliberately holding - the protocol fee takes the rounding remainder.
    ///
    ///      Bounded below by the smallest amount whose borrower share clears
    ///      `MIN_EPOCH_YIELD`. Under that, `harvest` deliberately declines the epoch and
    ///      carries the whole amount to the next one rather than burning the cooldown -
    ///      and, more importantly, rather than letting a donation reset the window the
    ///      yield stream's anti-just-in-time defence is derived from. That is a
    ///      different property, covered by the tests below.
    function testFuzz_harvestLeavesNoStrandedDust(uint256 amount) public {
        uint256 floorAmount = (Config.MIN_EPOCH_YIELD * Config.BPS) / Config.SPLIT_BORROWER_BPS + 1;
        amount = bound(amount, floorAmount, 1_000_000e6);
        farm.setPendingYield(address(adapter), amount);
        harvester.harvest();

        assertEq(
            usdc.balanceOf(address(harvester)) - harvester.pendingProtocolFee(),
            harvester.pendingLenderYield(),
            "harvester holds exactly the lender share and the accrued fee, and nothing else"
        );
    }

    /// @dev **The donation regression.** The zero-epoch branch exists so a transient
    ///      zero cannot burn five days of cooldown, but it used to key off `claimed`,
    ///      which is a raw ERC-20 balance anyone can raise. One wei of USDC made a
    ///      genuinely empty epoch look productive: `lastHarvestAt` advanced, every
    ///      split leg floored to zero, `distributeYield` was never called, and the real
    ///      yield arriving a second later was locked out for a full epoch - for 1 wei
    ///      plus gas, repeatable.
    ///
    ///      Gating on the borrower share instead makes the donation inert: it is not
    ///      an epoch, so it does not consume the cooldown, and the wei simply waits.
    function test_harvest_donationCannotBurnTheCooldown() public {
        // Farm pays nothing; griefer donates the smallest possible amount.
        usdc.mint(address(this), 1);
        usdc.transfer(address(harvester), 1);

        harvester.harvest();
        assertEq(harvester.lastHarvestAt(), 0, "the cooldown never started");
        assertEq(harvester.epochCount(), 0, "and no epoch was counted");

        // Real yield lands a second later and is harvestable immediately.
        skip(1);
        farm.setPendingYield(address(adapter), YIELD);
        _harvestAndStream();

        assertEq(harvester.epochCount(), 1);
        assertGt(credit.accYieldPerBond(), 0, "the epoch was not lost to a 1 wei donation");
    }

    /// @dev And the donated wei is not burned either - it joins the next real epoch.
    function test_harvest_donationIsCarriedIntoTheNextEpoch() public {
        usdc.mint(address(this), 1);
        usdc.transfer(address(harvester), 1);
        harvester.harvest(); // declined

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();

        // The epoch was sized YIELD + 1, so the fee wallet's remainder carries it.
        uint256 expected = YIELD + 1;
        uint256 toBorrowers = (expected * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        uint256 toLenders = (expected * Config.SPLIT_LENDER_BPS) / Config.BPS;
        uint256 toInsurance = (expected * Config.SPLIT_INSURANCE_BPS) / Config.BPS;
        assertEq(
            usdc.balanceOf(address(harvester)) - harvester.pendingLenderYield(),
            expected - toBorrowers - toLenders - toInsurance,
            "the donated wei was counted, not stranded (fee now accrues rather than pushing)"
        );
    }

    /// @dev A revert inside DexFi's farm must not freeze USDC that is already sitting
    ///      in the harvester. The epoch is sized from this contract's own balance, so
    ///      the claim is an optimisation - and DexFi's farm is behind a proxy their EOA
    ///      can upgrade, so treating it as a hard precondition made a third party able
    ///      to stop borrower debt ever being written down.
    function test_harvest_survivesAFarmThatRevertsOnClaim() public {
        // Bob's exit sweeps the epoch here, then the farm stops honouring claims.
        _deposit(bob, 100);
        farm.setPendingYield(address(adapter), YIELD);
        vm.prank(bob);
        vault.withdrawBonds(100);
        assertEq(usdc.balanceOf(address(harvester)), YIELD, "already here, needs no claim");

        farm.setRevertOnWithdraw(true);
        _harvestAndStream();

        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        assertApproxEqAbs(credit.accYieldPerBond() * 100 / 1e18, toBorrowers, DUST);
        assertEq(harvester.epochCount(), 1, "the epoch ran despite the farm being down");
    }

    function test_harvest_writesDownBorrowerDebt() public {
        vm.prank(alice);
        credit.borrow(800e6);

        farm.setPendingYield(address(adapter), YIELD);
        _harvestAndStream();
        credit.settle(alice);

        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        assertApproxEqAbs(credit.debtOf(alice), 800e6 - toBorrowers, DUST, "the loan repaid itself");
    }

    /// @dev And when the yield exceeds the debt, the remainder becomes claimable
    ///      rather than overpaying the loan (PRD §4.3).
    function test_harvest_yieldBeyondDebtBecomesClaimable() public {
        vm.prank(alice);
        credit.borrow(300e6);

        farm.setPendingYield(address(adapter), YIELD);
        _harvestAndStream();
        credit.settle(alice);

        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        assertEq(credit.debtOf(alice), 0, "debt cleared entirely");
        assertApproxEqAbs(
            credit.claimableOf(alice), toBorrowers - 300e6, DUST, "the surplus is owed to her"
        );
    }

    /// @dev PRD §6.2 wanted 200+ positions settled in one transaction. The accumulator
    ///      makes position count irrelevant: this is one storage write either way.
    function test_harvest_costIsIndependentOfPositionCount() public {
        farm.setPendingYield(address(adapter), YIELD);
        uint256 gasOne = gasleft();
        harvester.harvest();
        gasOne -= gasleft();

        for (uint256 i; i < 50; ++i) _deposit(address(uint160(0xD00D + i)), 10);

        vm.warp(block.timestamp + Config.MIN_EPOCH_GAP);
        farm.setPendingYield(address(adapter), YIELD);
        uint256 gasMany = gasleft();
        harvester.harvest();
        gasMany -= gasleft();

        // 51 positions instead of 1, and the harvest costs no more.
        assertLt(gasMany, gasOne + 5_000, "harvest cost must not scale with positions");
    }

    /// @dev The epoch is sized from the harvester's own balance, not from what
    ///      `claimYield` returns. The farm is MasterChef-style, so ANY interaction
    ///      settles the whole adapter position's pending rewards - a withdrawal, a
    ///      deposit, a direct claim - and the adapter forwards that USDC here
    ///      immediately. Sized from the claim's return value it would read as zero and
    ///      the money would sit here permanently, claimed by nothing.
    ///
    ///      Here bob's withdrawal flushes the whole epoch out of the farm before any
    ///      harvest runs. The harvest that follows must still find and split it.
    function test_harvest_countsYieldFlushedOutByOtherPaths() public {
        _deposit(bob, 100);
        farm.setPendingYield(address(adapter), YIELD);

        // Bob exits, which settles the farm and pushes every borrower's yield here.
        vm.prank(bob);
        vault.withdrawBonds(100);
        assertEq(usdc.balanceOf(address(harvester)), YIELD, "yield is already sitting here");
        assertEq(farm.pendingShare(address(adapter)), 0, "and the farm has nothing left to claim");

        // The claim itself now returns nothing, yet the epoch must still be full size.
        _harvestAndStream();

        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        uint256 toInsurance = (YIELD * Config.SPLIT_INSURANCE_BPS) / Config.BPS;
        assertApproxEqAbs(
            credit.accYieldPerBond() * 100 / 1e18, toBorrowers, DUST, "borrowers still got their share"
        );
        assertEq(credit.insuranceFund(), toInsurance);
        assertEq(harvester.epochCount(), 1, "and it counted as a real epoch");
    }

    /// @dev The same leak on the deposit side. A MasterChef `deposit` settles pending
    ///      rewards too, so a depositor arriving mid-epoch flushes everyone's yield.
    function test_harvest_countsYieldFlushedOutByADeposit() public {
        farm.setPendingYield(address(adapter), YIELD);

        vm.recordLogs();
        _deposit(bob, 100); // stakes, and settles the farm on the way
        assertEq(usdc.balanceOf(address(harvester)), YIELD, "the deposit flushed it here");

        _harvestAndStream();
        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        assertApproxEqAbs(credit.accYieldPerBond() * 200 / 1e18, toBorrowers, DUST);
    }

    // ── cooldown and liveness ────────────────────────────────────────────────

    function test_harvest_enforcesEpochGap() public {
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();

        farm.setPendingYield(address(adapter), YIELD);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochHarvester.EpochGapNotElapsed.selector, block.timestamp + Config.MIN_EPOCH_GAP
            )
        );
        harvester.harvest();

        vm.warp(block.timestamp + Config.MIN_EPOCH_GAP);
        harvester.harvest();
        assertEq(harvester.epochCount(), 2);
    }

    /// @dev A missing keeper must not be able to stop yield reaching borrowers.
    function test_harvest_isPermissionless() public {
        farm.setPendingYield(address(adapter), YIELD);
        vm.prank(makeAddr("anybody"));
        _harvestAndStream();
        assertGt(credit.accYieldPerBond(), 0);
    }

    /// @dev A zero-yield epoch does nothing and, crucially, does not consume the
    ///      cooldown. Burning five days on a transient zero - DexFi pausing rewards
    ///      for an hour, a claim landing a block early - would lock the real yield
    ///      away for another full epoch.
    function test_harvest_zeroYieldEpochIsANoOp() public {
        harvester.harvest();
        assertEq(harvester.epochCount(), 0, "an empty epoch is not counted");
        assertEq(credit.accYieldPerBond(), 0);
        assertEq(usdc.balanceOf(feeWallet), 0);
        assertEq(harvester.lastHarvestAt(), 0, "and the cooldown has not started");

        // Yield shows up an hour later and is harvestable immediately.
        skip(1 hours);
        farm.setPendingYield(address(adapter), YIELD);
        _harvestAndStream();
        assertEq(harvester.epochCount(), 1);
        assertGt(credit.accYieldPerBond(), 0, "the epoch was not lost to the cooldown");
    }

    function test_harvest_revertsUntilWired() public {
        EpochHarvester fresh = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        vm.expectRevert(abi.encodeWithSelector(EpochHarvester.NotWired.selector, "custodyAdapter"));
        fresh.harvest();
    }

    // ── the lender share ─────────────────────────────────────────────────────

    /// @dev The pool cannot accept yield until Phase 4, so the share accrues rather
    ///      than being skipped. Skipping it would quietly write lenders out of every
    ///      epoch before the pool opens.
    function test_lenderShareAccruesAcrossEpochs() public {
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        vm.warp(block.timestamp + Config.MIN_EPOCH_GAP);
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();

        uint256 perEpoch = (YIELD * Config.SPLIT_LENDER_BPS) / Config.BPS;
        assertEq(harvester.pendingLenderYield(), perEpoch * 2);
        assertEq(
            usdc.balanceOf(address(harvester)) - harvester.pendingProtocolFee(),
            perEpoch * 2,
            "backed, not just counted"
        );
    }

    /// @dev And the flush is separate, so a pool that reverts cannot block borrowers
    ///      from receiving their share of an epoch.
    function test_flushLenderYield_revertsWhileThePoolCannotAcceptIt() public {
        address pool = address(new RevertingPool());
        vm.prank(admin);
        harvester.setLenderPool(pool);

        farm.setPendingYield(address(adapter), YIELD);
        _harvestAndStream();

        vm.expectRevert(EpochHarvester.FlushDeliveredNothing.selector);
        harvester.flushLenderYield();

        // Borrowers were unaffected by that.
        assertGt(credit.accYieldPerBond(), 0);
    }

    /// @dev **The deadlock regression.** The lender share is owed to the pool that was
    ///      wired when it accrued, so an earlier version refused to repoint while any
    ///      was outstanding. The reasoning was right and the guard was not: it assumed
    ///      a flush is always possible, and `LenderPool.distributeYield` reverts by
    ///      design until Phase 4 while the deploy script wires exactly that pool.
    ///
    ///      The only function that could clear the counter could never succeed, and the
    ///      only function that could replace the pool read that counter. Every epoch's
    ///      lender share was locked in the harvester permanently and Phase 4 could
    ///      never be wired at all.
    ///
    ///      Two earlier tests each asserted one half of that as correct and passed in
    ///      isolation. This one composes them, which is what neither did.
    function test_setLenderPool_repointsAwayFromAPoolThatCannotAccept() public {
        // Exactly the deploy-script shape: a pool that reverts on every delivery.
        address stuck = address(new RevertingPool());
        vm.prank(admin);
        harvester.setLenderPool(stuck);

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();

        uint256 owed = harvester.pendingLenderYield();
        assertGt(owed, 0, "the share accrued against a pool that cannot take it");
        vm.expectRevert(EpochHarvester.FlushDeliveredNothing.selector);
        harvester.flushLenderYield();

        // The repoint must still go through, carrying the share to the new pool.
        address realPool = address(new AcceptingPool(usdc));
        vm.prank(admin);
        harvester.setLenderPool(realPool);

        assertEq(harvester.lenderPool(), realPool, "Phase 4 is wirable");
        assertEq(harvester.pendingLenderYield(), owed, "and the share came with it");

        harvester.flushLenderYield();
        assertEq(usdc.balanceOf(realPool), owed, "paid in full, nothing locked");
        assertEq(harvester.pendingLenderYield(), 0);
    }

    /// @dev A pool that CAN accept is paid before the repoint, so the share still
    ///      reaches the depositors who earned it rather than following the pointer.
    function test_setLenderPool_paysTheOutgoingPoolFirstWhenItCanAccept() public {
        address outgoing = address(new AcceptingPool(usdc));
        vm.prank(admin);
        harvester.setLenderPool(outgoing);

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 owed = harvester.pendingLenderYield();

        address incoming = address(new AcceptingPool(usdc));
        vm.prank(admin);
        harvester.setLenderPool(incoming);

        assertEq(usdc.balanceOf(outgoing), owed, "the pool that earned it was paid");
        assertEq(harvester.pendingLenderYield(), 0, "nothing carried to the new pool");
    }

    /// @dev A pool that pulls short keeps owing the difference. The counter is not
    ///      zeroed on trust - the amount that actually left is measured, and the
    ///      remainder stays payable. It also keeps `setLenderPool`'s guard honest,
    ///      since that reads the same counter.
    function test_flushLenderYield_carriesWhatThePoolDidNotTake() public {
        uint256 shortfall = 10e6;
        ShortPool pool = new ShortPool(usdc, shortfall);
        vm.prank(admin);
        harvester.setLenderPool(address(pool));

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 owed = harvester.pendingLenderYield();

        harvester.flushLenderYield();

        assertEq(usdc.balanceOf(address(pool)), owed - shortfall, "the pool took what it took");
        assertEq(harvester.pendingLenderYield(), shortfall, "the rest is still owed");
        assertEq(
            usdc.balanceOf(address(harvester)) - harvester.pendingProtocolFee(),
            shortfall,
            "and still backed"
        );
        assertEq(usdc.allowance(address(harvester), address(pool)), 0, "no standing allowance");
    }

    function test_flushLenderYield_revertsWithNothingPending() public {
        vm.prank(admin);
        harvester.setLenderPool(makeAddr("pool"));
        vm.expectRevert(EpochHarvester.NothingToFlush.selector);
        harvester.flushLenderYield();
    }

    // ── solvency ─────────────────────────────────────────────────────────────

    /// @dev Everything the harvester hands CreditManager must be backed by USDC that
    ///      actually arrived.
    function test_harvest_keepsCreditManagerSolvent() public {
        vm.prank(alice);
        credit.borrow(500e6);
        _deposit(bob, 400);

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        credit.settle(alice);
        credit.settle(bob);

        assertGe(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
                + credit.insuranceFund()
        );
    }

    /// @notice A fee wallet that cannot receive USDC must not stop the epoch.
    /// @dev This was the one hard outbound transfer left in the yield path, and every
    ///      sibling leg is best-effort with a stated reason. A Circle blacklist on the
    ///      fee wallet reverted the whole permissionless `harvest()`, freezing the
    ///      borrower, lender and insurance shares alongside the protocol's own - so the
    ///      protocol's fee could stop borrowers' debt being written down.
    ///
    ///      Both halves in one test: the epoch completes while the wallet is frozen,
    ///      and the fee is still collectable once it is not. Asserting only the first
    ///      would pass just as well if the fee were silently dropped.
    function test_harvest_completesWithABlacklistedFeeWalletAndPaysOutLater() public {
        usdc.setBlocked(feeWallet, true);
        farm.setPendingYield(address(adapter), 1_000e6);

        harvester.harvest();

        uint256 toProtocol = (1_000e6 * Config.SPLIT_PROTOCOL_BPS) / Config.BPS;
        assertEq(harvester.pendingProtocolFee(), toProtocol, "accrued, not dropped");
        assertEq(credit.undistributedYield(), (1_000e6 * Config.SPLIT_BORROWER_BPS) / Config.BPS,
            "and borrowers were paid regardless");

        vm.expectRevert();
        harvester.flushProtocolFee();

        usdc.setBlocked(feeWallet, false);
        harvester.flushProtocolFee();
        assertEq(usdc.balanceOf(feeWallet), toProtocol);
        assertEq(harvester.pendingProtocolFee(), 0);
    }

    /// @dev The carried fee must not be counted as the next epoch's yield. Deducting
    ///      only `pendingLenderYield` from the balance would have paid it out twice.
    function test_harvest_carriedFeeIsNotCountedAsTheNextEpochsYield() public {
        usdc.setBlocked(feeWallet, true);
        farm.setPendingYield(address(adapter), 1_000e6);
        harvester.harvest();
        uint256 carried = harvester.pendingProtocolFee();
        assertGt(carried, 0);

        skip(Config.MIN_EPOCH_GAP);
        farm.setPendingYield(address(adapter), 1_000e6);
        harvester.harvest();

        assertEq(harvester.pendingProtocolFee(), carried * 2, "one fee per epoch, not compounding");
    }
}
