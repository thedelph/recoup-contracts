// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {ProtocolFeeSplitter} from "../src/ProtocolFeeSplitter.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IEpochHarvester} from "../src/interfaces/IEpochHarvester.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

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

/// @notice A pool that refuses delivery outright, whatever the reason.
/// @dev Named for the shape, not for a particular cause. It was written when the real
///      `LenderPool.distributeYield` reverted `NotImplemented` and the deploy script wired
///      exactly that pool; the pool has had a real body since 2026-08-10, but a pool that
///      refuses is still reachable - one that does not recognise this harvester, or one
///      whose USDC transfer is blocked - and the accrual path has to survive it either way.
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
contract EpochHarvesterTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant FLOAT = 100_000e6;
    uint256 internal constant YIELD = 1_000e6;
    uint256 internal constant BONDS = 100;

    /// @dev Borrowing power at the ceiling for the seeded lot, derived from the live risk
    ///      parameters so the ratchet moves the fixture instead of breaking it. Tests
    ///      asserting a partial write-down need a debt larger than one epoch of borrower share
    ///      (YIELD x SPLIT_BORROWER_BPS = 550e6), which the ceiling comfortably is; the
    ///      literal 800e6 this replaced stopped being inside the ceiling at 25% LTV.
    /// @dev **A function rather than a `constant`, and deliberately not a value cached in
    ///      `setUp`.** A Solidity `constant` cannot read the storage the ceiling now lives in,
    ///      and a cache would let a test that moved the parameter partway through keep
    ///      asserting against the figure derived before the move. Re-read on every call; see
    ///      `RiskParamsFixture`.
    function _maxBorrow() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    /// @dev At most 1 wei of USDC is left behind **per stream** by the rate truncation, and a
    ///      test that runs two streams carries that to 2. Anything larger is a real accounting
    ///      bug, so this stays tight rather than being widened to pass.
    ///
    ///      Per *stream*, not per accrual, and audit round 21 is why the distinction is written
    ///      down. `CreditManager._accrue` used to floor each slice against the previous call, so
    ///      the residual grew with the number of calls and nothing bounded it; `_sliceOwed` now
    ///      floors once against the stream's own origin, which is what makes a fixed tolerance
    ///      mean anything here at all.
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
        // Audit round 20: the setters also check the risk authority agrees with the vault's.
        auctionStub.setRiskParams(address(riskParams));
        // Audit round 21: and the NAV feed, anchored on the vault's answer.
        auctionStub.setNavOracle(address(vault.navOracle()));
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

        _deposit(alice, BONDS);
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

    // **The end-to-end lender-leg test is not in this repository yet.** It constructs a real
    // `LenderPool`, has a lender deposit into it, and asserts that a flushed epoch lands as a
    // higher share price rather than as loose USDC. It went when the pool was held back from
    // publication; the pool was published on 2026-08-19 and this case has not been ported back.
    // The delivery mechanism itself is still covered below by `AcceptingPool` and `ShortPool`,
    // which is the part that is about this contract rather than about the pool.

    /// @notice The 80/20 with DexFi, proved through a real epoch rather than in isolation.
    /// @dev `ProtocolFeeSplitter` rests on one claim about this contract: that installing
    ///      it as `protocolFeeWallet` needs no change to the core, because
    ///      `flushProtocolFee` pays out with a plain `safeTransfer` and so does not care
    ///      that the destination is a contract. That claim is worth an executable test
    ///      and not a comment, because the *lender* leg of this same split is delivered
    ///      by approve-and-call, where a plain recipient receives nothing - the two legs
    ///      genuinely differ, and the difference is invisible at the call site.
    function test_harvest_protocolFeeSplitsWithDexFiWhenTheSplitterIsTheFeeWallet() public {
        ProtocolFeeSplitter splitter =
            new ProtocolFeeSplitter(IERC20(address(usdc)), makeAddr("recoupTreasury"), makeAddr("dexfiTreasury"));
        vm.prank(admin);
        harvester.setProtocolFeeWallet(address(splitter));

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        harvester.flushProtocolFee();

        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        uint256 toLenders = (YIELD * Config.SPLIT_LENDER_BPS) / Config.BPS;
        uint256 toInsurance = (YIELD * Config.SPLIT_INSURANCE_BPS) / Config.BPS;
        uint256 toProtocol = YIELD - toBorrowers - toLenders - toInsurance;

        assertEq(usdc.balanceOf(address(splitter)), toProtocol, "the whole fee reached the splitter");

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();
        assertEq(toRecoup + toDexFi, toProtocol, "and left it in full");
        assertEq(usdc.balanceOf(splitter.dexfiWallet()), toDexFi);
        assertEq(usdc.balanceOf(splitter.recoupWallet()), toRecoup);
        assertEq(
            toDexFi,
            (toProtocol * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS,
            "DexFi's leg is the agreed share of the fee, not of gross yield"
        );
    }

    // -- round 21: repointing the fee wallet over an accrued backlog ---------

    /// @dev Three identical epochs with the splitter installed, which is the shape the agreement
    ///      with DexFi actually ships in. Separate from `_harvestAndStream` because these tests
    ///      care about what the harvester holds, not about what reaches a borrower.
    function _threeEpochs() private {
        for (uint256 i = 0; i < 3; ++i) {
            farm.setPendingYield(address(adapter), YIELD);
            harvester.harvest();
            skip(Config.MIN_EPOCH_GAP);
        }
    }

    function _splitter() private returns (ProtocolFeeSplitter) {
        return new ProtocolFeeSplitter(IERC20(address(usdc)), makeAddr("recoupTreasury"), makeAddr("dexfiTreasury"));
    }

    /// @notice A repoint leaves the accrued fee with the wallet that earned it.
    /// @dev **Audit round 21, finding 13.** `harvest` accrues the protocol slice into
    ///      `pendingProtocolFee` and deliberately never pushes it; `flushProtocolFee` pays
    ///      whatever `protocolFeeWallet` says **at flush time**; and `setProtocolFeeWallet` was
    ///      three lines of bare `onlyOwner` with no checkpoint, no drain and - alone among the
    ///      setters in this file - no event at all. So the whole accrual window sat behind a
    ///      pointer only Recoup can move, and `ProtocolFeeSplitter`'s claim that "neither party
    ///      can redirect the other's leg" bound only money already at the splitter.
    ///
    ///      MEASURED before the fix, and reproduced by this test's control arm: three epochs of
    ///      1,000.000000 pay DexFi **60.000000** through the splitter, while a repoint followed
    ///      by a flush - both of which fit in one block - paid DexFi **0** and sent 300.000000
    ///      elsewhere. The backlog builds with no attacker and drains through no automatic path:
    ///      100.000000 after one epoch, 1,000.000000 after ten.
    ///
    ///      Both arms in one test on purpose. The hazard arm alone would pass just as well if the
    ///      checkpoint had destroyed the fee rather than parked it, and the control arm alone says
    ///      nothing about the redirect.
    function test_setProtocolFeeWallet_leavesTheBacklogWithTheWalletThatEarnedIt() public {
        ProtocolFeeSplitter splitter = _splitter();
        vm.prank(admin);
        harvester.setProtocolFeeWallet(address(splitter));

        _threeEpochs();
        uint256 backlog = harvester.pendingProtocolFee();
        assertEq(backlog, (3 * YIELD * Config.SPLIT_PROTOCOL_BPS) / Config.BPS, "fixture: three epochs of fee");

        uint256 snapshot = vm.snapshotState();

        // CONTROL: flush to the splitter as wired. This is what the agreement pays.
        harvester.flushProtocolFee();
        splitter.split();
        uint256 dexfiIsOwed = usdc.balanceOf(splitter.dexfiWallet());
        assertEq(dexfiIsOwed, (backlog * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS, "control: the agreed share");

        vm.revertToState(snapshot);

        // HAZARD: repoint, then flush, in the same block.
        address elsewhere = makeAddr("elsewhere");
        vm.prank(admin);
        harvester.setProtocolFeeWallet(elsewhere);

        assertEq(harvester.pendingProtocolFee(), 0, "the live counter still carries the outgoing wallet's fee");
        assertEq(harvester.owedProtocolFee(address(splitter)), backlog, "the backlog was not checkpointed");
        assertEq(harvester.totalOwedProtocolFee(), backlog, "the sum did not follow the mapping");

        // Nothing to redirect: the live counter is empty, so the flush has nothing to pay out.
        vm.expectRevert(EpochHarvester.NothingToFlush.selector);
        harvester.flushProtocolFee();
        assertEq(usdc.balanceOf(elsewhere), 0, "the incoming wallet was paid the outgoing wallet's fee");

        // And the parked fee is still payable, to the splitter and only to the splitter.
        harvester.flushProtocolFeeTo(address(splitter));
        splitter.split();
        assertEq(usdc.balanceOf(splitter.dexfiWallet()), dexfiIsOwed, "DexFi is short against the control");
        assertEq(harvester.owedProtocolFee(address(splitter)), 0, "the checkpoint was not cleared by the flush");
        assertEq(harvester.totalOwedProtocolFee(), 0, "the sum was not cleared by the flush");
    }

    /// @notice A checkpointed fee is not re-harvested as fresh yield.
    /// @dev **The interaction the fix would have been a downgrade without.** `harvest` sizes an
    ///      epoch as this contract's raw balance less what is already spoken for, and moving value
    ///      out of `pendingProtocolFee` into `owedProtocolFee` removes it from that subtraction.
    ///      Left off the line, the parked fee reads as fresh yield to the very next epoch, is
    ///      split four ways to borrowers, lenders and insurance, and is *still* owed to the wallet
    ///      it was parked for - so the second payment comes out of somebody else's epoch. The
    ///      comment on that line predicted this counter before it existed.
    function test_setProtocolFeeWallet_aCheckpointedFeeIsNotReHarvestedAsFreshYield() public {
        ProtocolFeeSplitter splitter = _splitter();
        vm.prank(admin);
        harvester.setProtocolFeeWallet(address(splitter));

        _threeEpochs();
        uint256 parked = harvester.pendingProtocolFee();

        vm.prank(admin);
        harvester.setProtocolFeeWallet(feeWallet);
        assertEq(harvester.owedProtocolFee(address(splitter)), parked, "fixture: the checkpoint must have happened");

        // A fourth, identical epoch. Its fee must be one epoch's worth, not one epoch plus the
        // backlog counted a second time.
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();

        uint256 oneEpochFee = (YIELD * Config.SPLIT_PROTOCOL_BPS) / Config.BPS;
        assertEq(harvester.pendingProtocolFee(), oneEpochFee, "the epoch was sized to include the parked fee");
        // Within DUST, not exact: three completed streams have each left their one wei of rate
        // truncation behind, which is the residual `CreditManager._sliceOwed` is bounded by.
        assertApproxEqAbs(
            credit.undistributedYield(),
            (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS,
            DUST,
            "borrowers were paid out of a fee parked for somebody else"
        );
        assertEq(harvester.owedProtocolFee(address(splitter)), parked, "and the parked fee is untouched");
    }

    /// @notice The repoint works when the outgoing wallet cannot take delivery, which is the case
    ///         it exists for.
    /// @dev **The sign check on the obvious fix.** Draining to the outgoing wallet before
    ///      repointing is what MetaMorpho's `setFeeRecipient` does - but its `_accrueFee` mints
    ///      the vault's own shares and cannot revert, while ours would be a USDC push to an
    ///      address that may be blacklisted or a contract that reverts. Compromised, bricked or
    ///      frozen is *why* anybody rotates a fee wallet, so a drain-first fix fails in exactly
    ///      the case it was built for and hands the outgoing recipient a veto over its own
    ///      replacement. It also contradicts `flushProtocolFee`'s own rationale, one function
    ///      below, that a recipient which cannot take delivery must never block anything.
    ///
    ///      So: the repoint succeeds against a blacklisted outgoing wallet, the fee is parked
    ///      rather than pushed, and it becomes payable the moment the block is lifted.
    function test_setProtocolFeeWallet_repointsAwayFromAWalletThatCannotTakeDelivery() public {
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 backlog = harvester.pendingProtocolFee();
        assertGt(backlog, 0, "fixture: there must be a backlog to strand");

        usdc.setBlocked(feeWallet, true);

        address incoming = makeAddr("incoming");
        vm.prank(admin);
        harvester.setProtocolFeeWallet(incoming);
        assertEq(harvester.protocolFeeWallet(), incoming, "a bricked outgoing wallet blocked its own replacement");
        assertEq(harvester.owedProtocolFee(feeWallet), backlog, "the stranded fee was not parked");

        // Still undeliverable while the block stands, and deliverable the moment it lifts.
        vm.expectRevert();
        harvester.flushProtocolFeeTo(feeWallet);

        usdc.setBlocked(feeWallet, false);
        harvester.flushProtocolFeeTo(feeWallet);
        assertEq(usdc.balanceOf(feeWallet), backlog, "the parked fee never reached the wallet that earned it");
    }

    /// @notice The setter has no precondition a stranger can flip.
    /// @dev **The other rejected fix, and it manufactures a different finding from the same
    ///      round.** `require(pendingProtocolFee == 0)` on this setter reads like the tidy answer,
    ///      and it would be a live griefing surface: `harvest()` is permissionless, so anybody
    ///      could re-block the setter for the price of gas, indefinitely, inside the 48-hour
    ///      timelock window a production repoint has to sit in. An unconditional checkpoint has no
    ///      precondition to go stale, which is why it is the right shape here and in
    ///      `setLenderPool`. This test is the guard against somebody adding that require later: a
    ///      stranger harvests immediately before the repoint, and the repoint still lands.
    function test_setProtocolFeeWallet_cannotBeBlockedByAStrangerHarvestingFirst() public {
        farm.setPendingYield(address(adapter), YIELD);
        vm.prank(caller); // permissionless, and not the owner
        harvester.harvest();
        assertGt(harvester.pendingProtocolFee(), 0, "fixture: the stranger must have created a backlog");

        address incoming = makeAddr("incoming");
        vm.prank(admin);
        harvester.setProtocolFeeWallet(incoming);
        assertEq(harvester.protocolFeeWallet(), incoming, "a stranger's harvest blocked the repoint");
    }

    /// @notice The repoint is on chain even when there is no backlog to park.
    /// @dev It was the only setter in this contract that emitted nothing at all, on the one
    ///      pointer a third party's revenue hangs off, so a repoint left no record that it had
    ///      happened. The park event is conditional because a park may not have happened; this one
    ///      is unconditional, because the repoint always has.
    function test_setProtocolFeeWallet_emitsTheRepointAndTheParkSeparately() public {
        ProtocolFeeSplitter splitter = _splitter();

        // No backlog yet: the repoint is announced, nothing is parked.
        vm.expectEmit(true, false, false, true, address(harvester));
        emit EpochHarvester.ProtocolFeeWalletSet(address(splitter));
        vm.prank(admin);
        harvester.setProtocolFeeWallet(address(splitter));

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 backlog = harvester.pendingProtocolFee();

        // With a backlog, both.
        address incoming = makeAddr("incoming");
        vm.expectEmit(true, false, false, true, address(harvester));
        emit EpochHarvester.ProtocolFeeParked(address(splitter), backlog, backlog);
        vm.expectEmit(true, false, false, true, address(harvester));
        emit EpochHarvester.ProtocolFeeWalletSet(incoming);
        vm.prank(admin);
        harvester.setProtocolFeeWallet(incoming);
    }

    /// @notice The parked flush is permissionless and cannot choose a destination.
    /// @dev The two properties that make the checkpoint safe rather than merely tidy, and the same
    ///      pair `flushLenderYieldTo` rests on. Keyed by the wallet that earned the fee, so there
    ///      is nothing for an owner to redirect; callable by anybody, so DexFi's leg does not
    ///      depend on Recoup's owner cooperating in paying it - which matters precisely because
    ///      Recoup's owner is the party a redirect would have benefited.
    function test_flushProtocolFeeTo_isPermissionlessAndPaysOnlyTheWalletThatEarnedIt() public {
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 backlog = harvester.pendingProtocolFee();

        address incoming = makeAddr("incoming");
        vm.prank(admin);
        harvester.setProtocolFeeWallet(incoming);

        // No standing claim for anyone else, including the wallet now wired.
        vm.expectRevert(EpochHarvester.NothingToFlush.selector);
        harvester.flushProtocolFeeTo(incoming);
        vm.expectRevert(EpochHarvester.ZeroAddress.selector);
        harvester.flushProtocolFeeTo(address(0));

        // And a stranger can pay the wallet that earned it.
        vm.prank(caller);
        harvester.flushProtocolFeeTo(feeWallet);
        assertEq(usdc.balanceOf(feeWallet), backlog, "a stranger could not deliver the parked fee");

        vm.expectRevert(EpochHarvester.NothingToFlush.selector);
        harvester.flushProtocolFeeTo(feeWallet);
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
    /// @dev **Round 10, finding 9 - the same regression, priced properly.** The test below proves a
    ///      1-wei donation is inert, and stops there. `MIN_EPOCH_YIELD` is 1e6 against a 55%
    ///      borrower share, so the actual price of an epoch is 1,818,182 units - about $1.82 - and
    ///      that clears the floor the test above was guarding. It buys five days of `lastHarvestAt`
    ///      *and* pins `CreditManager.lastDistributeAt`, the anti-just-in-time window's only input,
    ///      while debt write-down stalls and the donor collects the liquidation caller share on
    ///      positions the withheld yield would have kept solvent. A floor denominated in absolute
    ///      dollars cannot price a right whose value scales with the pot behind it.
    ///
    ///      The claim return value is the one signal in `harvest` a stranger cannot forge, so the
    ///      cooldown now keys off that rather than off a balance anyone can raise.
    function test_harvest_aDonationAboveTheFloorStillCannotBurnTheCooldown() public {
        // Farm pays nothing. Donate comfortably past MIN_EPOCH_YIELD on the borrower share.
        usdc.mint(address(this), 10e6);
        usdc.transfer(address(harvester), 10e6);

        harvester.harvest();
        assertEq(harvester.lastHarvestAt(), 0, "a donated epoch consumed the cooldown");

        // The money is not lost - it is distributed - but the next real epoch is not locked out.
        skip(1);
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        assertGt(harvester.lastHarvestAt(), 0, "a corroborated epoch must start the cooldown");
    }

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
        // Read before the prank: the ceiling is a staticcall to `RiskParams` now, and a
        // single-shot `vm.prank` is spent on the next call this contract makes - so deriving
        // the amount inside the `borrow` argument would send the borrow from the test contract.
        uint256 loan = _maxBorrow();
        vm.prank(alice);
        credit.borrow(loan);

        farm.setPendingYield(address(adapter), YIELD);
        _harvestAndStream();
        credit.settle(alice);

        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        assertLt(toBorrowers, loan, "a partial write-down, not a full repayment");
        assertApproxEqAbs(credit.debtOf(alice), loan - toBorrowers, DUST, "the loan repaid itself");
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
    ///
    ///      **The second half of this test asserts the opposite of what it used to, deliberately.**
    ///      It read "and the share came with it" - the repoint handed the outgoing pool's accrued
    ///      share to the incoming one, on the reasoning that a pool which cannot take delivery has
    ///      no depositors to be short-changed. Audit round 11 found nothing enforces that, and the
    ///      protocol's own wiring falsifies it: `LenderPool.setEpochHarvester` is unguarded, so
    ///      pointing a live pool away from this harvester is precisely how delivery is made to
    ///      fail. The share is now parked against the pool that earned it and the incoming pool
    ///      gets none of it. What this test still pins, and the reason it was written, is
    ///      unchanged: the repoint itself never blocks.
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

        // The repoint must still go through. The share must not.
        address realPool = address(new AcceptingPool(usdc));
        vm.prank(admin);
        harvester.setLenderPool(realPool);

        assertEq(harvester.lenderPool(), realPool, "Phase 4 is wirable");
        assertEq(harvester.owedToPool(stuck), owed, "parked for the pool that earned it");
        assertEq(harvester.totalOwedToPools(), owed);
        assertEq(harvester.pendingLenderYield(), 0, "and it is no longer the live counter's");

        // The incoming pool is owed nothing, and cannot be flushed into.
        vm.expectRevert(EpochHarvester.NothingToFlush.selector);
        harvester.flushLenderYield();
        assertEq(usdc.balanceOf(realPool), 0, "the incoming pool got none of it");

        // Nothing is locked either: the money is still here, still backed, still payable.
        assertEq(
            usdc.balanceOf(address(harvester)) - harvester.pendingProtocolFee(),
            owed,
            "parked, not spent"
        );
    }

    /// @dev And parked is not lost. `flushLenderYieldTo` is permissionless and takes the pool as
    ///      its argument, so the moment the outgoing pool can take delivery again anybody can pay
    ///      it - the owner's cooperation is not needed, and there is no destination to choose, so
    ///      there is nothing here for an owner to redirect either.
    ///
    ///      The refusal is modelled as a blocked USDC transfer rather than a reverting body,
    ///      because that is the case with real depositors behind it: a pool full of lenders whose
    ///      delivery fails for a reason that later clears.
    function test_flushLenderYieldTo_paysAParkedShareOnceThePoolCanTakeIt() public {
        address outgoing = address(new AcceptingPool(usdc));
        vm.prank(admin);
        harvester.setLenderPool(outgoing);

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 owed = harvester.pendingLenderYield();
        assertGt(owed, 0);

        // Delivery starts failing for a reason outside this contract.
        usdc.setBlocked(outgoing, true);

        // Constructed before the prank: `vm.prank` is consumed by the very next call, and a
        // `new` is one, so an inline construction here would leave the repoint unpranked.
        address incoming = address(new AcceptingPool(usdc));
        vm.prank(admin);
        harvester.setLenderPool(incoming);
        assertEq(harvester.owedToPool(outgoing), owed, "parked at the repoint");

        // Still unpayable while the block stands, and it says so rather than pretending.
        vm.expectRevert(EpochHarvester.FlushDeliveredNothing.selector);
        harvester.flushLenderYieldTo(outgoing);

        usdc.setBlocked(outgoing, false);
        vm.prank(caller); // permissionless
        harvester.flushLenderYieldTo(outgoing);

        assertEq(usdc.balanceOf(outgoing), owed, "paid in full to the pool that earned it");
        assertEq(harvester.owedToPool(outgoing), 0);
        assertEq(harvester.totalOwedToPools(), 0);
        vm.expectRevert(EpochHarvester.NothingToFlush.selector);
        harvester.flushLenderYieldTo(outgoing);
    }

    /// @dev **The line that double-pays if it is missed.** `harvest` sizes an epoch from this
    ///      contract's raw USDC balance less what is already spoken for, and a parked share is a
    ///      third category of spoken-for balance that does not move when it is parked. Leave it
    ///      out of that subtraction and the next epoch counts it as fresh farm yield, splits it
    ///      four ways, and pays it out - while it is still owed to the pool it was parked for.
    ///
    ///      Asserted two ways because one of them is not enough. The lender-share equality says
    ///      the epoch was sized correctly; the solvency line says the money is actually there,
    ///      which is what a second payment destroys. Without the `- totalOwedToPools` term the
    ///      second epoch's split is 25% larger and the balance ends up short by the parked amount,
    ///      because the borrower and insurance legs have already transferred it away.
    function test_harvest_doesNotCountAParkedShareAsFreshYield() public {
        address stuck = address(new RevertingPool());
        vm.prank(admin);
        harvester.setLenderPool(stuck);

        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        uint256 parked = harvester.pendingLenderYield();

        address incoming = address(new AcceptingPool(usdc));
        vm.prank(admin);
        harvester.setLenderPool(incoming);
        assertEq(harvester.owedToPool(stuck), parked, "fixture: the park must have happened");

        // A second, identical epoch. Its lender share must be identical too.
        skip(Config.MIN_EPOCH_GAP);
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();

        assertEq(
            harvester.pendingLenderYield(),
            (YIELD * Config.SPLIT_LENDER_BPS) / Config.BPS,
            "the epoch was sized from the farm's yield, not from the farm's yield plus a parked share"
        );
        assertEq(harvester.owedToPool(stuck), parked, "and the parked share is untouched");

        assertGe(
            usdc.balanceOf(address(harvester)),
            harvester.pendingLenderYield() + harvester.pendingProtocolFee() + harvester.totalOwedToPools(),
            "every counter this contract carries is still backed by USDC that is actually here"
        );
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
                + credit.insuranceFund() + credit.totalBountyEscrowed() + credit.totalBountyParked()
                + credit.totalBountyOwed()
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

    // ── round 11: a donated epoch and the anti-just-in-time window ───────────

    /// @notice What one run of the timeline below produced, so the three arms can be
    ///         compared field by field rather than through a snapshot.
    struct PinRun {
        uint256 window; // `streamEndsAt - now`, read in the real epoch's own block
        uint256 pot; // the borrower share that window has to be paid out over
        uint256 jitTake; // USDC a depositor who arrived in that block walks away with
        uint256 aliceTake; // what the lot staked for the whole outage has earned by then
        uint256 donated; // what the pins cost the attacker
    }

    /// @dev How long DexFi's farm is assumed to be down for - twelve epochs, sixty days
    ///      at today's parameters. Not a worst case: `harvest` is permissionless
    ///      precisely because the keeper is expected to go missing, and the farm sits
    ///      behind a proxy a single EOA can upgrade, so `withdraw(0)` reverting for weeks
    ///      is the scenario the whole best-effort claim path was written for.
    ///
    ///      **Expressed as a multiple of `YIELD_STREAM_DURATION` on purpose.** Written as
    ///      a literal `60 days`, raising the stream floor to sixty would have collapsed
    ///      the attack arm to zero pins and left it passing while proving nothing -
    ///      exactly the vacuity this repo has recorded three times. Scaling with the
    ///      parameter instead means the arms keep making the same claim whatever the
    ///      floor is set to, which is also the finding: a bigger floor does not fix this,
    ///      it just rescales it.
    uint256 internal constant OUTAGE = 12 * Config.YIELD_STREAM_DURATION;
    /// @dev Twelve epochs' worth of yield accruing inside the farm while nothing can
    ///      collect it. This is the money the stream's accrual window is supposed to
    ///      be measured against.
    uint256 internal constant OUTAGE_ACCRUAL = 12 * YIELD;
    /// @dev The just-in-time position, nine times the honest lot, so its share of the
    ///      stream is 90% and the arithmetic in the assertions stays readable.
    uint256 internal constant JIT_BONDS = 9 * BONDS;
    /// @dev The cheapest donation that clears `MIN_EPOCH_YIELD` on the borrower share -
    ///      1,818,182 units, the $1.82 audit round 10 priced and round 11 found buys
    ///      more than round 10 thought. Derived rather than written out, so a change to
    ///      either constant re-prices the attack instead of silently invalidating it.
    uint256 internal constant PIN_COST =
        (Config.MIN_EPOCH_YIELD * Config.BPS + Config.SPLIT_BORROWER_BPS - 1) / Config.SPLIT_BORROWER_BPS;

    /// @dev Rate truncation is integer division twice over (pot into a per-second rate,
    ///      then a slice into per-bond units), so a few units of USDC go missing across
    ///      a run. Kept tight: the effects under test are measured in thousands of
    ///      dollars, so if this ever has to be widened the test has stopped working.
    uint256 internal constant STREAM_DUST = 10;

    /// @dev The shared timeline for the three arms below.
    ///
    ///      The farm stops honouring `withdraw` - the one call `claimYield` makes - and
    ///      keeps accruing yield for `OUTAGE`. That is the sharp version of the root
    ///      cause: `harvest` is best-effort about the claim, so during an outage the
    ///      *only* kind of epoch that can run is one funded by a donation, and every one
    ///      of those consumes the accrual window without collecting any of the accrual.
    ///
    ///      `pinOffsets` are absolute seconds from the start of the outage at which the
    ///      attacker donates `PIN_COST` and calls the permissionless `harvest`. An empty
    ///      array is the honest control: the same sixty days, the same recovery, nobody
    ///      donating anything.
    function _runPinnedOutage(uint256[] memory pinOffsets) private returns (PinRun memory r) {
        address attacker = makeAddr("attacker");
        address jit = makeAddr("jit");
        uint256 start = block.timestamp;
        uint256 distributeAtBefore = credit.lastDistributeAt();

        farm.setRevertOnWithdraw(true);
        farm.setPendingYield(address(adapter), OUTAGE_ACCRUAL);

        for (uint256 i; i < pinOffsets.length; ++i) {
            vm.warp(start + pinOffsets[i]);
            usdc.mint(attacker, PIN_COST);
            vm.startPrank(attacker);
            usdc.transfer(address(harvester), PIN_COST);
            harvester.harvest();
            vm.stopPrank();
            r.donated += PIN_COST;

            // Round 10's `corroborated` guard holds: the cooldown never starts. That is
            // what makes the pin repeatable rather than a once-per-five-days move, so
            // the guard is load-bearing *for the attacker* here.
            assertEq(harvester.lastHarvestAt(), 0, "a donated epoch must not consume the cooldown");
            // And the epoch it just ran collected nothing. The yield is still in the farm.
            assertEq(farm.pendingShare(address(adapter)), OUTAGE_ACCRUAL, "the accrual is untouched");

            // **The three assertions the round-11 fix is actually about**, and they live in the
            // shared helper on purpose: every arm below donates into a farm that is paying
            // nothing, so `farmYieldDelivered` cannot move, so no arm may reach
            // `distributeYield` at all. Asserting per-pin rather than once at the end is what
            // makes a pin that writes on, say, only its first call visible - which is exactly
            // the shape the degenerate arm below had before the fix.
            assertEq(
                credit.lastDistributeAt(),
                distributeAtBefore,
                "a donated epoch wrote lastDistributeAt - the anti-JIT window's only input"
            );
            assertEq(harvester.epochCount(), 0, "a donated epoch was counted as an epoch");
            assertEq(credit.undistributedYield(), 0, "a donated epoch reached the credit manager");
        }

        // The farm comes back and the whole outage is claimable in one call.
        vm.warp(start + OUTAGE);
        farm.setRevertOnWithdraw(false);
        harvester.harvest();

        r.pot = credit.undistributedYield();
        r.window = credit.streamEndsAt() - block.timestamp;

        // The just-in-time depositor buys in during the harvest block itself, holds for
        // exactly one stream length, and leaves.
        _deposit(jit, JIT_BONDS);
        skip(Config.YIELD_STREAM_DURATION);
        vm.startPrank(jit);
        vault.withdrawBonds(JIT_BONDS);
        credit.claimSurplus();
        vm.stopPrank();
        r.jitTake = usdc.balanceOf(jit);

        credit.settle(alice);
        r.aliceTake = credit.claimableOf(alice);
    }

    /// @dev What the stream pays a `JIT_BONDS` position that holds for one stream length
    ///      out of a `pot` rated over `window`, against a bond base of `BONDS + JIT_BONDS`.
    function _expectedTake(uint256 pot, uint256 window) private pure returns (uint256) {
        uint256 streamed = window < Config.YIELD_STREAM_DURATION ? pot : (pot * Config.YIELD_STREAM_DURATION) / window;
        return (streamed * JIT_BONDS) / (BONDS + JIT_BONDS);
    }

    /// @notice Control arm: sixty days of accrual, nobody donating, rated over sixty days.
    /// @dev This is the behaviour `distributeYield`'s "pay out over at least as long as
    ///      the pot took to accrue" paragraph promises, and it holds. A depositor who
    ///      arrives in the harvest block and stays a full stream length earns one
    ///      twelfth of the epoch, which is exactly the fraction of the earning window
    ///      they were actually staked for.
    function test_harvest_anHonestOutageRatesTheEpochOverItsWholeAccrualWindow() public {
        PinRun memory r = _runPinnedOutage(new uint256[](0));

        assertEq(r.donated, 0, "control arm donates nothing");
        assertEq(r.window, OUTAGE, "the window matches the accrual it is paying out");
        assertApproxEqAbs(r.pot, (OUTAGE_ACCRUAL * Config.SPLIT_BORROWER_BPS) / Config.BPS, STREAM_DUST);
        assertApproxEqAbs(r.jitTake, _expectedTake(r.pot, OUTAGE), STREAM_DUST, "one twelfth, pro rata");
        // Measured: 494,999,999 of a 6,600,000,000 pot. The round trip earned what it
        // was staked for, and the honest lot keeps the other eleven twelfths.
        assertLt(r.jitTake * 10, r.pot, "a five-day stay cannot take a tenth of a sixty-day pot");
    }

    /// @notice The attack arm, now asserting that it does not work.
    /// @dev **What this arm measured before the fix, kept because it is the record of what the
    ///      finding was worth.** Eleven donations of $1.82, spaced one `YIELD_STREAM_DURATION`
    ///      apart, held `CreditManager.lastDistributeAt` at the present and let each tiny stream
    ///      expire exactly as the next pin landed. When the farm recovered, `elapsed` was five days
    ///      rather than sixty and `remaining` was zero, so sixty days of everyone's yield was rated
    ///      over the `YIELD_STREAM_DURATION` floor. Against the control arm above: the window fell
    ///      from 60 days to 5, the just-in-time take rose from 494,999,999 to 5,940,000,000 - $495
    ///      to $5,940 - and the lot staked for all sixty days ended with 670,999,999 of a
    ///      6,600,000,001 pot instead of the whole of it. Total cost of the pins: 20,000,002 units.
    ///      Twenty dollars bought roughly $5,400.
    ///
    ///      Note what was never happening, because it is what made the fix hard to place: no
    ///      running stream is ever shortened. `duration >= remaining` makes `streamEndsAt`
    ///      monotonically non-decreasing, so a pin can only push it further out. The damage was
    ///      entirely to `lastDistributeAt` - the pins stopped a long window from ever *forming*,
    ///      rather than collapsing one that already had. That is why the naive same-block version
    ///      below was always inert, and it is the distinction the five agents split on.
    ///
    ///      The fix does not defend the window; it declines the epoch. A donation cannot move
    ///      `DirectCallAdapter.farmYieldDelivered`, so with the farm paying nothing every pin below
    ///      returns before touching a single storage slot - which the shared helper now asserts
    ///      pin by pin. The arm is kept in full, at its original spacing and cost, because a fix
    ///      whose test no longer runs the attack is a fix nobody can re-check.
    function test_harvest_donatedEpochsNoLongerCompressTheAntiJitWindow() public {
        // 5d, 10d, ... 55d. The last pin lands one stream length before the recovery, so
        // its own stream has just run dry when the real epoch arrives - nothing to
        // "never shorten", and `elapsed` was five days instead of sixty.
        uint256 pins = OUTAGE / Config.YIELD_STREAM_DURATION - 1;
        // The arm is about repeated pinning, so a timeline that fits fewer than two pins
        // is not this test passing, it is this test having nothing to say.
        assertGe(pins, 2, "the attack arm went vacuous");
        uint256[] memory offsets = new uint256[](pins);
        for (uint256 i; i < pins; ++i) offsets[i] = (i + 1) * Config.YIELD_STREAM_DURATION;

        PinRun memory r = _runPinnedOutage(offsets);

        assertEq(r.donated, pins * PIN_COST, "eleven donations at the floor");
        assertLt(r.donated, 21e6, "which is twenty dollars");

        // The one number the finding was about. It read `YIELD_STREAM_DURATION` before the fix.
        assertEq(r.window, OUTAGE, "the pins bought no compression at all");
        assertEq(harvester.epochCount(), 1, "eleven pinned harvests produced no epoch between them");

        // The donations were declined, not burned. They sat in the harvester's balance until the
        // real epoch counted them into `claimed`, so the attacker's $20 ends up written down
        // against borrowers' debt alongside the farm's own sixty days.
        assertApproxEqAbs(
            r.pot,
            ((OUTAGE_ACCRUAL + r.donated) * Config.SPLIT_BORROWER_BPS) / Config.BPS,
            STREAM_DUST,
            "the declined donations joined the next real epoch instead of being stranded"
        );

        // And the round trip is back to earning what it was staked for: one twelfth of the pot for
        // one twelfth of the earning window, against the 90% it took before.
        assertApproxEqAbs(r.jitTake, _expectedTake(r.pot, OUTAGE), STREAM_DUST, "rated pro rata again");
        assertLt(r.jitTake * 10, r.pot, "a five-day stay cannot take a tenth of a sixty-day pot");
    }

    /// @notice The degenerate arm two of the five agents found, kept because it was the half of
    ///         the picture that was already safe - and because it is the arm that changed shape
    ///         rather than value when the fix landed.
    /// @dev Pinning one block apart, immediately before the real epoch, never compressed anything.
    ///      Before the fix it still *wrote*: the first pin inherited the full sixty-day `elapsed`
    ///      and rated its own dust stream over sixty days, and every later call - including the
    ///      real epoch - then hit `if (remaining > duration) duration = remaining` and re-read the
    ///      tail it left. So the window came out at exactly `OUTAGE - 2 x lead`, six seconds short:
    ///      three lost at the pin that started early, three more waiting for the recovery. A
    ///      self-sustaining same-block pin was real - `lastDistributeAt` never got away from it -
    ///      but it sustained a window it could not shrink.
    ///
    ///      Those six seconds are the tell, and they are gone now. Every pin is declined before it
    ///      reaches `distributeYield`, so nothing writes `lastDistributeAt` at all and the window
    ///      is the honest one to the second. The arm now agrees with the control arm exactly
    ///      rather than approximately, which is a stronger statement than the one it used to make.
    ///
    ///      So "a donated epoch compresses the stream" was false, "donated epochs compress the
    ///      stream" was true, and both are now moot: a donated epoch is not an epoch.
    function test_harvest_donatedEpochsOneBlockApartCompressNothing() public {
        uint256 lead = 3; // the burst starts three seconds before the recovery
        uint256[] memory offsets = new uint256[](lead);
        for (uint256 i; i < lead; ++i) offsets[i] = OUTAGE - lead + i;

        PinRun memory r = _runPinnedOutage(offsets);

        assertEq(r.window, OUTAGE, "not even the six seconds the first pin used to cost");
        // Exact, not approximate. The 1e3 tolerance this used to carry was there to absorb the
        // 572 units the six seconds were worth at the stream rate; with no write at all there is
        // nothing left to absorb, so the tolerance comes back down to the suite's own dust bound.
        assertApproxEqAbs(r.jitTake, _expectedTake(r.pot, OUTAGE), STREAM_DUST, "so the take is the honest one");
        assertLt(r.jitTake * 10, r.pot, "identical to the control arm, to within rounding");
    }

    // ── round 11: what corroboration is, and what it must not cost ───────────

    /// @notice A bond movement corroborates an epoch. A successful claim is not required.
    /// @dev **The direct anti-regression for the one-liner that was tried and reverted.** Gating
    ///      `distributeYield` on `claimYield`'s return value would fail this scenario: the farm is
    ///      down, `claimYield` reverts, and the epoch's entire USDC arrived through `withdrawBonds`
    ///      settling the MasterChef position on the way out. That is a wholly legitimate epoch with
    ///      a zero `corroborated`, and under the one-liner its borrower share would have sat in
    ///      `undistributedYield` unrated for up to `MIN_EPOCH_GAP`.
    ///
    ///      `farmYieldDelivered` sees it because the adapter measures the farm on every path, not
    ///      just the claim. The assertion that matters most here is the last one: the epoch runs in
    ///      the same block the money arrived in, so no legitimate epoch is delayed by a second -
    ///      the bar the finding set for any fix.
    function test_harvest_aBondMovementCorroboratesAnEpochWhenTheClaimReverts() public {
        _deposit(bob, 100);
        farm.setPendingYield(address(adapter), YIELD);

        // Bob exits. The farm settles the whole adapter position through `unstake`, so the epoch's
        // USDC is delivered here without `claimYield` ever being called, let alone succeeding.
        vm.prank(bob);
        vault.withdrawBonds(100);
        assertEq(adapter.farmYieldDelivered(), YIELD, "the exit path is what corroborated it");
        assertEq(farm.pendingShare(address(adapter)), 0, "and the farm has nothing left to claim");

        // Now the farm stops honouring `withdraw` entirely, so the claim inside `harvest` reverts
        // and `corroborated` is zero.
        farm.setRevertOnWithdraw(true);

        uint256 at = block.timestamp;
        harvester.harvest();

        assertEq(harvester.epochCount(), 1, "the epoch ran on a movement-corroborated delivery");
        assertEq(harvester.lastCorroboratedYield(), YIELD, "and the watermark moved with it");
        assertEq(credit.lastDistributeAt(), at, "in the same block the money arrived - nothing delayed");
        assertEq(harvester.lastHarvestAt(), 0, "the claim itself paid nothing, so the cooldown stays open");

        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();
        uint256 toBorrowers = (YIELD * Config.SPLIT_BORROWER_BPS) / Config.BPS;
        assertApproxEqAbs(credit.accYieldPerBond() * BONDS / 1e18, toBorrowers, DUST, "borrowers got the lot");
    }

    /// @notice A declined epoch strands nothing: the donation joins the next real one.
    /// @dev The half of the fix that is not about the attack. Declining has to be free of
    ///      side-effects in *both* directions - it must not write the anti-JIT window, and it must
    ///      not swallow the USDC either. `harvest` returns before touching a slot, so the donated
    ///      balance is still sitting here when the next epoch sizes itself from that same balance.
    function test_harvest_aDeclinedUncorroboratedEpochStrandsNothing() public {
        uint256 donation = 10e6; // comfortably past MIN_EPOCH_YIELD on the borrower share
        uint256 distributeAtBefore = credit.lastDistributeAt();
        usdc.mint(address(this), donation);
        usdc.transfer(address(harvester), donation);

        vm.expectEmit(true, false, false, true, address(harvester));
        emit EpochHarvester.EpochDeclinedUncorroborated(1, 0, donation);
        harvester.harvest();

        assertEq(harvester.epochCount(), 0, "no epoch was counted");
        assertEq(harvester.lastHarvestAt(), 0, "no cooldown was consumed");
        assertEq(harvester.lastCorroboratedYield(), 0, "and the watermark did not move");
        assertEq(credit.lastDistributeAt(), distributeAtBefore, "nor did the anti-JIT window");
        assertEq(usdc.balanceOf(address(harvester)), donation, "the money is still here");

        // The next real epoch, in the very next second, counts the donation as its own.
        skip(1);
        farm.setPendingYield(address(adapter), YIELD);
        uint256 expected = YIELD + donation;
        vm.expectEmit(true, false, false, true, address(harvester));
        emit IEpochHarvester.Harvested(
            1,
            expected,
            (expected * Config.SPLIT_BORROWER_BPS) / Config.BPS,
            (expected * Config.SPLIT_LENDER_BPS) / Config.BPS,
            (expected * Config.SPLIT_INSURANCE_BPS) / Config.BPS,
            expected - (expected * Config.SPLIT_BORROWER_BPS) / Config.BPS
                - (expected * Config.SPLIT_LENDER_BPS) / Config.BPS
                - (expected * Config.SPLIT_INSURANCE_BPS) / Config.BPS
        );
        harvester.harvest();
        assertEq(harvester.lastCorroboratedYield(), YIELD, "rated against farm inflow, not against the balance");
    }

    /// @notice Swapping the custody adapter re-seeds the corroboration watermark.
    /// @dev **The deadlock this fix would otherwise have introduced**, and it is the same shape
    ///      `setLenderPool`'s NatSpec spends twenty lines on: a function gated on a condition only
    ///      that function could clear. `farmYieldDelivered` is per-adapter and a fresh one starts
    ///      at zero, so a watermark carried across the swap would sit permanently above the
    ///      incoming counter, `fromFarm` would saturate to zero on every call, and every epoch
    ///      would be declined forever - with the only thing able to raise the counter past the
    ///      stale mark being the epochs the stale mark is refusing.
    ///
    ///      The second half of the test is the part that would fail without the re-seed: an epoch
    ///      of `PIN_COST` through the new adapter, three orders of magnitude below the stale mark
    ///      of `YIELD`, has to be accepted immediately.
    function test_setCustodyAdapter_reSeedsTheCorroborationWatermark() public {
        farm.setPendingYield(address(adapter), YIELD);
        harvester.harvest();
        assertEq(harvester.lastCorroboratedYield(), YIELD, "a real epoch raised the mark");

        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        assertEq(fresh.farmYieldDelivered(), 0, "a fresh adapter's counter starts at zero");

        vm.startPrank(admin);
        fresh.setHarvester(address(harvester));
        vm.expectEmit(true, false, false, true, address(harvester));
        emit EpochHarvester.CustodyAdapterSet(address(fresh), 0);
        harvester.setCustodyAdapter(ICustodyAdapter(address(fresh)));
        vm.stopPrank();

        assertEq(harvester.lastCorroboratedYield(), 0, "re-seeded from the incoming adapter, not carried");

        // An epoch far smaller than the stale mark, through the new adapter. Without the re-seed
        // this is declined, and so is every epoch after it.
        skip(Config.MIN_EPOCH_GAP);
        farm.setPendingYield(address(fresh), PIN_COST);
        harvester.harvest();

        assertEq(harvester.epochCount(), 2, "the epoch ran through the new adapter");
        assertEq(harvester.lastCorroboratedYield(), PIN_COST, "against the new adapter's own counter");
    }

    /// @notice Audit round 21's setter census: this pointer had no binding check at all, while its
    ///         twin on `CollateralVault` has always required the adapter to name the right vault.
    /// @dev An adapter bound elsewhere carries a `farmYieldDelivered` counter that has nothing to
    ///      do with this protocol's yield, and that counter is the whole of `harvest`'s answer to
    ///      "is this epoch real". The test above is the control: an adapter bound to the *right*
    ///      vault still installs, including one the vault has not moved to yet.
    function test_setCustodyAdapter_refusesAnAdapterBoundToADifferentVault() public {
        address otherVault = makeAddr("otherVault");
        DirectCallAdapter foreign = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, otherVault, admin, address(harvester)
        );

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EpochHarvester.AdapterVaultMismatch.selector, otherVault));
        harvester.setCustodyAdapter(ICustodyAdapter(address(foreign)));

        assertEq(address(harvester.custodyAdapter()), address(adapter), "the pointer did not move");
    }
}
