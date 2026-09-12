// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round 56, agent A1 (cold). The borrower's journey through the real contracts, end to end:
///         deposit -> borrow -> yield epochs -> partial repay -> second borrow -> full clear ->
///         claim surplus -> withdraw, reconciled to the wei at every step; plus the exit rules, the
///         permissionless-call interference matrix, the mint path, the NAV and risk-parameter gaps,
///         gas, and one open finding with a fix built in `CollateralVault.sol`.
///
/// @dev Case prefixes: `control_` is green on both trees; `fix_` is red at the base tree and green
///      under the fix on this branch; `negative_` asserts an attack does NOT work; `pin_` and
///      `info_` pin an open state.
///
///      🟥 **PINS-OPEN: `test_R56A01_pin_borrowAgainstTheAnchorWhileALowerNavIsParked` and
///      `test_R56A01_info_aFlatPriceGoesStaleUnderAnHonestKeeper` pin states that are NOT fixed on
///      this branch.** `borrow` lives in `CreditManager.sol`, read-only this round, and both are
///      below MEDIUM. A change that consults `pendingNav` in `borrow`, or that refreshes freshness on
///      a same-price post, must turn the corresponding pin red. A green run of this file is not a
///      clearance.
contract R56A01BorrowerJourneyTest is Test {
    uint256 internal constant NAV = 29_00000000; // $29.00, 8dp
    uint256 internal constant FLOAT = 100_000e6;
    uint256 internal constant BOUNTY = Config.LIQUIDATION_CALL_BOUNTY;

    bytes32 internal constant T_YIELD_APPLIED = keccak256("YieldApplied(address,uint256,uint256)");
    bytes32 internal constant T_REPAID = keccak256("Repaid(address,uint256)");
    bytes32 internal constant T_BORROWED = keccak256("Borrowed(address,uint256)");
    bytes32 internal constant T_HARVESTED = keccak256("Harvested(uint256,uint256,uint256,uint256,uint256,uint256)");

    address internal admin = makeAddr("r56a01.admin");
    address internal keeper = makeAddr("r56a01.keeper");
    address internal confirmer = makeAddr("r56a01.confirmer");
    address internal alice = makeAddr("r56a01.alice");
    address internal bob = makeAddr("r56a01.bob");
    address internal stranger = makeAddr("r56a01.stranger");
    address internal feeWallet = makeAddr("r56a01.feeWallet");
    address internal gov = makeAddr("r56a01.gov");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    NAVOracle internal oracle;
    RiskParams internal risk;
    CollateralVault internal vault;
    CreditManager internal credit;
    EpochHarvester internal harvester;
    DirectCallAdapter internal adapter;
    TreasuryLiquiditySource internal liquidity;
    MockLiquidationAuction internal auctionStub;

    struct Tally {
        uint256 borrowed;
        uint256 repaid;
        uint256 yieldToDebt;
        uint256 yieldToClaim;
    }

    mapping(address => Tally) internal tally;
    uint256 internal toBorrowersTotal;
    uint256 internal maxDust;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));

        oracle = new NAVOracle(admin);
        risk = new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            admin
        );
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(risk)), admin
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(risk)), admin
        );
        harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, address(harvester)
        );
        liquidity = new TreasuryLiquiditySource(usdc, admin);
        auctionStub = new MockLiquidationAuction();
        auctionStub.setVault(address(vault));
        auctionStub.setRiskParams(address(risk));
        auctionStub.setNavOracle(address(oracle));
        auctionStub.setCreditManager(address(credit));

        vm.startPrank(admin);
        oracle.setKeeper(keeper);
        oracle.setNavConfirmer(confirmer);
        oracle.bootstrapNav(NAV);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
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

        vm.recordLogs();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 n) internal {
        bond.mint(who, n);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(n);
        vm.stopPrank();
    }

    function _refreshNav() internal {
        uint256 next = oracle.navPerBond() + 1; // read BEFORE the prank, which the read would spend
        vm.prank(keeper);
        oracle.postNav(next);
    }

    /// @dev A full `MIN_EPOCH_GAP` passes (so the previous stream completes exactly at the harvest),
    ///      the farm owes `farmYield` to the adapter, and the permissionless harvest runs.
    function _epoch(uint256 farmYield) internal {
        vm.warp(block.timestamp + Config.MIN_EPOCH_GAP);
        _refreshNav();
        farm.setPendingYield(address(adapter), farmYield);
        harvester.harvest();
    }

    function _fundAndApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(credit), type(uint256).max);
    }

    function _drain() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            bytes32 t = logs[i].topics[0];
            if (logs[i].emitter == address(credit)) {
                if (t == T_YIELD_APPLIED) {
                    address who = address(uint160(uint256(logs[i].topics[1])));
                    (uint256 d, uint256 o) = abi.decode(logs[i].data, (uint256, uint256));
                    tally[who].yieldToDebt += d;
                    tally[who].yieldToClaim += o;
                } else if (t == T_REPAID) {
                    address who = address(uint160(uint256(logs[i].topics[1])));
                    tally[who].repaid += abi.decode(logs[i].data, (uint256));
                } else if (t == T_BORROWED) {
                    address who = address(uint160(uint256(logs[i].topics[1])));
                    tally[who].borrowed += abi.decode(logs[i].data, (uint256));
                }
            } else if (logs[i].emitter == address(harvester) && t == T_HARVESTED) {
                (, uint256 toB,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                toBorrowersTotal += toB;
            }
        }
    }

    function _spokenFor() internal view returns (uint256) {
        return credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
            + credit.totalOwedToSources() + credit.insuranceFund() + credit.totalBountyEscrowed()
            + credit.totalBountyParked() + credit.totalBountyOwed();
    }

    function _knownBalances() internal view returns (uint256 s) {
        address[12] memory who = [
            alice,
            bob,
            stranger,
            address(this),
            address(liquidity),
            address(credit),
            address(harvester),
            address(adapter),
            feeWallet,
            address(farm),
            gov,
            address(auctionStub)
        ];
        for (uint256 i; i < who.length; i++) {
            s += usdc.balanceOf(who[i]);
        }
    }

    /// @dev Every book identity this journey should hold, checked after every step.
    function _checkBooks(string memory step) internal {
        // Bring the accumulator to now so `pendingYieldOf` and `undistributedYield` do not both
        // count the same un-accrued slice of the stream.
        credit.accrueYield();
        _drain();
        uint256 bal = usdc.balanceOf(address(credit));
        uint256 spoken = _spokenFor();
        uint256 unsettled = credit.pendingYieldOf(alice) + credit.pendingYieldOf(bob);
        // (1) Solvency, including yield accrued into the accumulator but not yet settled.
        assertGe(bal, spoken + unsettled, string.concat(step, ": manager under-backed"));
        uint256 dust = bal - spoken - unsettled;
        if (dust > maxDust) maxDust = dust;
        // (2) The float: every lent wei is debt, owed home, or home.
        assertEq(
            usdc.balanceOf(address(liquidity)) + credit.totalDebt() + credit.pendingPrincipal(),
            FLOAT,
            string.concat(step, ": treasury identity")
        );
        // (3) Per-borrower debt identity from the manager's own events.
        assertEq(
            credit.debtOf(alice),
            tally[alice].borrowed - tally[alice].repaid - tally[alice].yieldToDebt,
            string.concat(step, ": alice debt identity")
        );
        assertEq(
            credit.debtOf(bob),
            tally[bob].borrowed - tally[bob].repaid - tally[bob].yieldToDebt,
            string.concat(step, ": bob debt identity")
        );
        // (4) No USDC outside the known set of holders.
        assertEq(usdc.totalSupply(), _knownBalances(), string.concat(step, ": USDC escaped the known set"));
        emit log_named_uint(string.concat(step, " | manager dust (wei)"), dust);
    }

    // ── 1. The journey, reconciled to the wei ─────────────────────────────────

    function test_R56A01_control_journeyReconcilesToTheWei() public {
        vm.recordLogs();
        _deposit(alice, 1000);
        _deposit(bob, 337);
        _checkBooks("01 deposit");

        // Borrow 1: 2,000.000000 -> 1,975.000000 in hand, 25.000000 escrowed, 2,000.000000 owed.
        uint256 aliceMinted;
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.borrow(2_000e6);
        assertEq(usdc.balanceOf(alice) - before, 2_000e6 - BOUNTY, "borrow 1 disbursement");
        assertEq(credit.debtOf(alice), 2_000e6, "borrow 1 debt");
        assertEq(credit.bountyEscrowOf(alice), BOUNTY, "borrow 1 escrow");
        _checkBooks("02 borrow 1");

        _epoch(1_000e6);
        _checkBooks("03 epoch 1");
        _epoch(1_234_567_891);
        _checkBooks("04 epoch 2");
        _epoch(777_777_777);
        _checkBooks("05 epoch 3");

        // Partial cash repay: escrow must NOT be touched by a partial.
        _fundAndApprove(alice, 10_000e6);
        aliceMinted += 10_000e6;
        vm.prank(alice);
        credit.repay(300_000_001);
        assertEq(credit.bountyEscrowOf(alice), BOUNTY, "partial repay must not disarm the bounty");
        _checkBooks("06 partial repay");

        // Borrow 2: the escrow is armed, so the whole amount is disbursed.
        before = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.borrow(1_111_111_111);
        assertEq(usdc.balanceOf(alice) - before, 1_111_111_111, "borrow 2 disbursement (escrow already armed)");
        _checkBooks("07 borrow 2");

        _epoch(1_500e6);
        _checkBooks("08 epoch 4");

        // Let epoch 4's stream finish, then clear in full. The escrow pays the last 25.000000.
        vm.warp(block.timestamp + Config.MIN_EPOCH_GAP);
        credit.settle(alice);
        _drain();
        uint256 owed = credit.debtOf(alice);
        before = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.repay(type(uint256).max);
        assertEq(before - usdc.balanceOf(alice), owed - BOUNTY, "full clear pulls debt less escrow");
        assertEq(credit.debtOf(alice), 0, "cleared");
        assertEq(credit.bountyEscrowOf(alice), 0, "escrow consumed by the clear");
        _checkBooks("09 full clear");

        // A debt-free epoch: alice's share overflows to claimable.
        // This epoch's accrual window was ten days (the clear sat five days after epoch 4's stream
        // ended), so `distributeYield` stretches it over ten, not five. Walk to its real end.
        _epoch(900e6);
        emit log_named_uint("epoch 5 stream length (s)", credit.streamEndsAt() - block.timestamp);
        vm.warp(credit.streamEndsAt());
        credit.settle(alice);
        credit.settle(bob);
        _checkBooks("10 overflow epoch");

        // Claim, then leave with every bond.
        vm.prank(alice);
        credit.claimSurplus();
        assertEq(credit.claimableOf(alice), 0, "claimed");
        _checkBooks("11 claim");

        vm.prank(alice);
        vault.withdrawBonds(1000);
        assertEq(bond.balanceOf(alice, 0), 1000, "every bond home");
        assertEq(vault.bondCount(alice), 0, "ledger empty");
        _checkBooks("12 withdraw");

        // Alice's own identity: net cash == yield credited to her, exactly.
        uint256 net = usdc.balanceOf(alice) - aliceMinted;
        uint256 aliceYield = tally[alice].yieldToDebt + tally[alice].yieldToClaim;
        assertEq(net, aliceYield, "alice net cash != yield credited to her");
        emit log_named_uint("alice net cash = yield credited (wei)", net);

        // Bob (no debt): all of his yield sits in claimable.
        assertEq(credit.claimableOf(bob), tally[bob].yieldToClaim, "bob claimable");

        // What the borrower share delivered versus what the two positions were credited.
        uint256 credited = aliceYield + tally[bob].yieldToDebt + tally[bob].yieldToClaim;
        emit log_named_uint("sum of epoch borrower shares (wei)", toBorrowersTotal);
        emit log_named_uint("credited to positions (wei)", credited);
        emit log_named_uint("left in undistributedYield (wei)", credit.undistributedYield());
        emit log_named_uint("max manager dust over the journey (wei)", maxDust);
        assertLe(credited, toBorrowersTotal, "positions were credited more than was delivered");
        emit log_named_uint("delivered minus credited (wei)", toBorrowersTotal - credited);
        assertLe(toBorrowersTotal - credited, 10, "more than 10 wei lost to rounding");
    }

    // ── 2. Exit rules ────────────────────────────────────────────────────────

    function test_R56A01_negative_owingOneWeiBlocksTheFullExit() public {
        _deposit(alice, 1000);
        vm.prank(alice);
        credit.borrow(1_000e6);
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        credit.repay(1_000e6 - 1);
        assertEq(credit.debtOf(alice), 1, "one wei owed");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.WithdrawalExceedsMaxLtv.selector, type(uint256).max, uint256(2500))
        );
        vault.withdrawBonds(1000);

        // Partial withdrawal while owing is allowed down to the ceiling: 1 wei of debt needs one bond.
        vm.prank(alice);
        vault.withdrawBonds(999);
        assertEq(vault.bondCount(alice), 1, "one bond left under one wei of debt");

        // The last wei: the escrow pays it, the remainder is refunded, and the exit opens.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.repay(1);
        assertEq(usdc.balanceOf(alice), before, "the escrow paid the last wei; no cash pulled");
        assertEq(credit.claimableOf(alice), BOUNTY - 1, "escrow residue refunded");
        vm.prank(alice);
        vault.withdrawBonds(1);
        assertEq(vault.bondCount(alice), 0);
    }

    function test_R56A01_control_zeroDebtExitsUnderEveryPauseAndAStaleNav() public {
        _deposit(alice, 1000);
        vm.prank(alice);
        credit.borrow(1_000e6);
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        credit.repay(type(uint256).max);
        assertEq(credit.debtOf(alice), 0);

        vm.startPrank(admin);
        vault.pause();
        vault.setBondDepositsPaused(true);
        credit.pause();
        vm.stopPrank();
        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(oracle.isStale(), "stale");

        vm.prank(alice);
        vault.withdrawBonds(1000);
        assertEq(bond.balanceOf(alice, 0), 1000, "exit is open with zero debt");
        // 975 disbursed + 1,000 minted - 975 pulled (the escrow paid the last 25).
        assertEq(usdc.balanceOf(alice), 1_000e6, "a no-yield loan cost exactly nothing");
    }

    function test_R56A01_control_staleNavPauseMatrix() public {
        _deposit(alice, 1000);
        vm.prank(alice);
        credit.borrow(1_000e6);
        vm.warp(block.timestamp + Config.NAV_STALENESS + 1);
        assertTrue(oracle.isStale());

        vm.prank(alice);
        vm.expectRevert(CreditManager.NavStale.selector);
        credit.borrow(1e6);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.NavStale.selector);
        vault.withdrawBonds(1);

        // Repay, deposit, settle and claim stay open.
        _fundAndApprove(alice, 2_000e6);
        vm.prank(alice);
        credit.repay(100e6);
        _deposit(alice, 10);
        credit.settle(alice);
        assertEq(credit.debtOf(alice), 900e6);
    }

    // ── 3. Permissionless interference between two borrowers ──────────────────

    function _walkStream(uint8 mode) internal {
        for (uint256 h; h < 120; h++) {
            vm.warp(block.timestamp + 1 hours);
            if (mode == 1) {
                vm.startPrank(stranger);
                credit.settle(alice);
                credit.settle(bob);
                credit.accrueYield();
                credit.settlePrincipal();
                credit.refreshImpairment(alice);
                try credit.claimSurplusFor(bob) {} catch {}
                try harvester.harvest() {} catch {}
                vm.stopPrank();
            } else if (mode == 2 && h == 7) {
                usdc.mint(stranger, 30e6);
                vm.startPrank(stranger);
                usdc.transfer(address(credit), 5e6);
                usdc.transfer(address(harvester), 11e6);
                usdc.transfer(address(adapter), 7e6);
                usdc.approve(address(credit), 7e6);
                credit.fundInsurance(7e6);
                vm.stopPrank();
            }
        }
    }

    function _twoBorrowerRun(uint8 mode) internal returns (uint256[4] memory out) {
        _deposit(alice, 1000);
        _deposit(bob, 400);
        vm.prank(alice);
        credit.borrow(3_000e6);
        vm.prank(bob);
        credit.borrow(1_500e6);
        vm.warp(block.timestamp + Config.MIN_EPOCH_GAP);
        for (uint256 e; e < 3; e++) {
            _refreshNav();
            farm.setPendingYield(address(adapter), 1_000e6 + e * 333_333);
            harvester.harvest();
            _walkStream(mode);
        }
        // One more epoch so a donation to the harvester or adapter can land, then finish it.
        _refreshNav();
        farm.setPendingYield(address(adapter), 1_000e6);
        harvester.harvest();
        _walkStream(0);
        credit.settle(alice);
        credit.settle(bob);
        out = [credit.debtOf(alice), credit.claimableOf(alice), credit.debtOf(bob), credit.claimableOf(bob)];
    }

    function test_R56A01_negative_permissionlessCallsMoveNothingBetweenBorrowers() public {
        uint256 snap = vm.snapshotState();
        uint256[4] memory quiet = _twoBorrowerRun(0);
        vm.revertToState(snap);
        uint256[4] memory meddled = _twoBorrowerRun(1);
        vm.revertToState(snap);
        uint256[4] memory donated = _twoBorrowerRun(2);

        // Yield credited = starting debt - end debt + end claimable.
        uint256 aQ = 3_000e6 - quiet[0] + quiet[1];
        uint256 bQ = 1_500e6 - quiet[2] + quiet[3];
        uint256 aM = 3_000e6 - meddled[0] + meddled[1];
        uint256 bM = 1_500e6 - meddled[2] + meddled[3];
        uint256 aD = 3_000e6 - donated[0] + donated[1];
        uint256 bD = 1_500e6 - donated[2] + donated[3];
        emit log_named_uint("alice yield, quiet", aQ);
        emit log_named_uint("alice yield, 720 stranger calls", aM);
        emit log_named_uint("bob yield, quiet", bQ);
        emit log_named_uint("bob yield, 720 stranger calls", bM);
        emit log_named_uint("alice yield, donations", aD);
        emit log_named_uint("bob yield, donations", bD);

        // Non-donating calls: nobody gains, and the only loss is the settle floor.
        assertLe(aM, aQ, "a stranger's calls raised alice's yield");
        assertLe(bM, bQ, "a stranger's calls raised bob's yield");
        emit log_named_uint("alice wei lost to stranger settles", aQ - aM);
        emit log_named_uint("bob wei lost to stranger settles", bQ - bM);
        assertLe(aQ - aM, 400, "alice lost more than the settle floor bound");
        assertLe(bQ - bM, 400, "bob lost more than the settle floor bound");

        // Donations: both gain, pro rata to bonds (1000:400), so nothing moved between them.
        assertGt(aD, aQ);
        assertGt(bD, bQ);
        uint256 lhs = (aD - aQ) * 400;
        uint256 rhs = (bD - bQ) * 1000;
        uint256 gap = lhs > rhs ? lhs - rhs : rhs - lhs;
        emit log_named_uint("pro-rata gap on the donation gain (wei x bonds)", gap);
        assertLe(gap, 10_000, "donation gain not pro rata to bonds");
    }

    function test_R56A01_negative_strangerCannotBlockRepayOrExit() public {
        _deposit(alice, 1000);
        vm.prank(alice);
        credit.borrow(1_000e6);
        _fundAndApprove(alice, 1_000e6);
        _fundAndApprove(stranger, 10e6);

        // Front-run with a 1 wei repayFor: alice's full repay still clears (clamped) and the
        // escrow still settles the tail.
        vm.prank(stranger);
        credit.repayFor(alice, 1);
        vm.prank(stranger);
        credit.settle(alice);
        vm.prank(stranger);
        try credit.claimSurplusFor(alice) {} catch {}
        usdc.mint(stranger, 3e6);
        vm.prank(stranger);
        usdc.transfer(address(credit), 3e6);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.repay(1_000e6);
        assertEq(before - usdc.balanceOf(alice), 1_000e6 - 1 - BOUNTY, "clamped clear, escrow applied");
        assertEq(credit.debtOf(alice), 0);

        vm.prank(stranger);
        credit.settle(alice);
        vm.prank(alice);
        vault.withdrawBonds(1000);
        assertEq(bond.balanceOf(alice, 0), 1000);
    }

    // ── 4. Mint path ─────────────────────────────────────────────────────────

    uint256 internal constant PAYMENT = 1 ether;
    uint256 internal constant MINTED = 40;

    function _mintInput(uint256 uuid, address receiver) internal view returns (IDexFiBond.MintDataInput memory) {
        return IDexFiBond.MintDataInput({
            uuid: uuid,
            nonce: 0,
            receiver: receiver,
            amountNfts: MINTED,
            paymentAmount: PAYMENT,
            deadline: block.timestamp + 1 days,
            signature: ""
        });
    }

    function test_R56A01_control_mintCreditsExactlyTheSignedAmountDespitePreArrivals() public {
        bytes32 id = keccak256("r56a01.attempt.1");
        address receiver = adapter.predictMintReceiver(alice, id);
        // Everything that can arrive at the counterfactual address ahead of the handoff.
        vm.deal(receiver, 0.5 ether);
        usdc.mint(receiver, 7e6);
        bond.mint(receiver, 3); // loose bonds, as a whitelisted sender could put them there

        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vault.depositETH{value: PAYMENT}(id, abi.encode(_mintInput(1, receiver)));

        assertEq(vault.bondCount(alice), MINTED, "credited exactly the signed amount");
        assertEq(adapter.stakedBalance(), vault.totalBondCount(), "custody matches the ledger");
        assertEq(receiver.balance, 0.5 ether, "pre-sent ETH stays at the clone, credited to nobody");
        assertEq(usdc.balanceOf(receiver), 7e6, "pre-sent USDC stays at the clone");
        assertEq(bond.balanceOf(receiver, 0), 3, "pre-sent bonds stay at the clone");

        // Replay of the same payload is refused.
        vm.deal(alice, PAYMENT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1));
        vault.depositETH{value: PAYMENT}(id, abi.encode(_mintInput(1, receiver)));

        // Only governance moves the strays, and only to a recipient it names.
        vm.prank(admin);
        adapter.recoverMintAttempt(alice, id, payable(gov));
        assertEq(bond.balanceOf(gov, 0), 3);
        assertEq(usdc.balanceOf(gov), 7e6);
        assertEq(gov.balance, 0.5 ether);
        assertEq(vault.bondCount(alice), MINTED, "recovery never touches credited collateral");
    }

    function test_R56A01_negative_frontRunningAnAttemptOnlyBurnsTheFrontRunnersEth() public {
        bytes32 id = keccak256("r56a01.attempt.2");
        address receiver = adapter.predictMintReceiver(alice, id);
        IDexFiBond.MintDataInput memory data = _mintInput(7, receiver);

        // The payload is public once it is in flight; a stranger lands it first, paying.
        vm.deal(stranger, PAYMENT);
        vm.prank(stranger);
        bond.mint{value: PAYMENT}(data);

        // A stranger cannot route the victim's payload through the vault under their own name.
        vm.deal(stranger, PAYMENT);
        address strangersReceiver = adapter.predictMintReceiver(stranger, id);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintReceiverMismatch.selector, strangersReceiver, receiver)
        );
        vault.depositETH{value: PAYMENT}(id, abi.encode(data));

        vm.deal(alice, 2 * PAYMENT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyUsed.selector, receiver, 1));
        vault.depositETH{value: PAYMENT}(id, abi.encode(data));
        assertEq(alice.balance, 2 * PAYMENT, "the victim's ETH came back");

        // The victim retries with a fresh attempt and a fresh payload.
        bytes32 id2 = keccak256("r56a01.attempt.3");
        address receiver2 = adapter.predictMintReceiver(alice, id2);
        vm.prank(alice);
        vault.depositETH{value: PAYMENT}(id2, abi.encode(_mintInput(8, receiver2)));
        assertEq(vault.bondCount(alice), MINTED);
        assertEq(vault.bondCount(stranger), 0, "the front-runner holds no credited collateral");
        (uint256 strandedStake,) = farm.userInfo(receiver);
        assertEq(strandedStake, MINTED, "the front-runner's bonds sit at the clone for governance");
    }

    // ── 5. NAV and risk-parameter gaps ───────────────────────────────────────

    function test_R56A01_pin_borrowAgainstTheAnchorWhileALowerNavIsParked() public {
        _deposit(alice, 600);
        vm.warp(block.timestamp + 1 days);
        // A 55% drop is outside a day's 10% budget, so it parks for the second key.
        uint256 lower = (NAV * 45) / 100;
        vm.prank(keeper);
        oracle.postNav(lower);
        assertEq(oracle.pendingNav(), lower, "parked");
        assertEq(oracle.navPerBond(), NAV, "the anchor still prices borrow");
        assertFalse(oracle.isStale(), "and it is fresh");

        // Borrow the whole ceiling at the anchor: 25% of 600 x $29 = 4,350.000000, exactly.
        uint256 amount = 4_350e6;
        vm.prank(alice);
        credit.borrow(amount);

        // At the price the protocol already holds on chain, that loan is past the liquidation line.
        uint256 ltvAtPending = (amount * Config.USDC_TO_NAV_SCALE * Config.BPS) / (600 * lower);
        emit log_named_uint("LTV bps at the parked price", ltvAtPending);
        assertGt(ltvAtPending, Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS, "PINS-OPEN: borrow ignored the parked price");

        vm.warp(block.timestamp + Config.NAV_PENDING_DELAY);
        vm.prank(confirmer);
        oracle.confirmNav(lower);
        assertLt(credit.healthFactor(alice), 1e18, "liquidatable the instant the second key confirms");
    }

    function test_R56A01_info_aFlatPriceGoesStaleUnderAnHonestKeeper() public {
        _deposit(alice, 1000);
        for (uint256 d; d < 9; d++) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(keeper);
            oracle.postNav(NAV); // the true price has not moved, and the keeper says so every day
        }
        assertTrue(oracle.isStale(), "PINS-OPEN: a same-price post does not refresh freshness");
        vm.prank(alice);
        vm.expectRevert(CreditManager.NavStale.selector);
        credit.borrow(1e6);
    }

    function test_R56A01_control_riskParamsTightenedUnderAnOpenLoan() public {
        _deposit(alice, 1000);
        vm.prank(alice);
        credit.borrow(5_000e6); // 5000 / 29000 = 17.24%

        vm.prank(admin);
        risk.setRiskParams(
            IRiskParams.Params({
                maxLtvBps: 1_500,
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.MIN_BOUNTIED_DEBT)
            })
        );
        vm.prank(alice);
        vm.expectRevert();
        credit.borrow(1e6);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawBonds(1);
        assertEq(credit.healthFactor(alice) > 1e18, true, "tightening the ceiling liquidates nobody");

        _fundAndApprove(alice, 5_000e6);
        vm.prank(alice);
        credit.repay(1_000e6);
        vm.prank(alice);
        vault.withdrawBonds(80); // 4000 / (920 x 29) = 14.99%
        assertEq(vault.bondCount(alice), 920);
    }

    // ── 6. Gas ───────────────────────────────────────────────────────────────

    function test_R56A01_control_gasOfThePermissionlessAndExitPaths() public {
        _deposit(alice, 1000);
        _deposit(bob, 400);
        vm.prank(alice);
        credit.borrow(3_000e6);
        vm.warp(block.timestamp + Config.MIN_EPOCH_GAP);
        _refreshNav();
        farm.setPendingYield(address(adapter), 1_000e6);

        harvester.harvest();
        emit log_named_uint("gas harvest", vm.lastCallGas().gasTotalUsed);
        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        credit.settle(alice);
        emit log_named_uint("gas settle (stranger, debt-reducing)", vm.lastCallGas().gasTotalUsed);
        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        credit.accrueYield();
        emit log_named_uint("gas accrueYield", vm.lastCallGas().gasTotalUsed);
        vm.prank(stranger);
        credit.settlePrincipal();
        emit log_named_uint("gas settlePrincipal", vm.lastCallGas().gasTotalUsed);
        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        credit.claimSurplusFor(bob);
        emit log_named_uint("gas claimSurplusFor", vm.lastCallGas().gasTotalUsed);

        _fundAndApprove(alice, 3_000e6);
        vm.prank(alice);
        credit.repay(type(uint256).max);
        emit log_named_uint("gas repay (full clear)", vm.lastCallGas().gasTotalUsed);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.withdrawBonds(1000);
        emit log_named_uint("gas withdrawBonds (full)", vm.lastCallGas().gasTotalUsed);
        vm.prank(alice);
        credit.claimSurplus();
        emit log_named_uint("gas claimSurplus", vm.lastCallGas().gasTotalUsed);
    }

    // ── 7. Deposits into insolvent custody (the finding) ─────────────────────

    function test_R56A01_control_solventCustodyStillAcceptsDeposits() public {
        _deposit(alice, 1000);
        assertTrue(vault.custodyIsSolvent());
        _deposit(bob, 100);
        assertEq(vault.bondCount(bob), 100);
    }

    /// @dev Red at the base tree, where the deposit is accepted and the next line hands bob's bonds
    ///      to alice; green under the fix, where the deposit is refused by name.
    function test_R56A01_fix_bondDepositIntoInsolventCustodyIsRefused() public {
        _deposit(alice, 1000);
        vm.prank(admin);
        adapter.emergencyUnstake(gov);
        assertFalse(vault.custodyIsSolvent(), "break-glass left the ledger unbacked");
        assertEq(bond.balanceOf(gov, 0), 1000, "rescued bonds are with governance");

        bond.mint(bob, 100);
        vm.startPrank(bob);
        bond.setApprovalForAll(address(vault), true);
        (bool ok, bytes memory reason) = address(vault).call(abi.encodeCall(vault.depositBonds, (100)));
        vm.stopPrank();
        if (ok) {
            // The base tree: the fresh deposit restocks the farm position, so an old ledger entry
            // can withdraw it.
            vm.prank(alice);
            vault.withdrawBonds(100);
            emit log_named_uint("bob ledger", vault.bondCount(bob));
            emit log_named_uint("custody stake after alice's exit", adapter.stakedBalance());
            emit log_named_uint("alice wallet bonds (bob's)", bond.balanceOf(alice, 0));
            emit log_named_uint("alice ledger still owed by governance", vault.bondCount(alice));
            assertTrue(false, "deposit into insolvent custody accepted; alice withdrew bob's bonds");
        }
        assertEq(bytes4(reason), bytes4(keccak256("CustodyInsolvent()")), "refused by name");
        assertEq(bond.balanceOf(bob, 0), 100, "bob keeps his bonds");
    }

    function test_R56A01_fix_ethDepositIntoInsolventCustodyIsRefused() public {
        _deposit(alice, 1000);
        vm.prank(admin);
        adapter.emergencyUnstake(gov);

        bytes32 id = keccak256("r56a01.attempt.insolvent");
        address receiver = adapter.predictMintReceiver(bob, id);
        vm.deal(bob, PAYMENT);
        vm.prank(bob);
        (bool ok, bytes memory reason) = address(vault).call{value: PAYMENT}(
            abi.encodeCall(vault.depositETH, (id, abi.encode(_mintInput(99, receiver))))
        );
        if (ok) {
            vm.prank(alice);
            vault.withdrawBonds(MINTED);
            emit log_named_uint("bob ledger", vault.bondCount(bob));
            emit log_named_uint("custody stake after alice's exit", adapter.stakedBalance());
            emit log_named_uint("alice wallet bonds (bob's)", bond.balanceOf(alice, 0));
            assertTrue(false, "ETH deposit into insolvent custody accepted; alice withdrew bob's bonds");
        }
        assertEq(bytes4(reason), bytes4(keccak256("CustodyInsolvent()")), "refused by name");
        assertEq(bob.balance, PAYMENT, "bob keeps his ETH");
    }

    function test_R56A01_negative_withdrawalAndRepayStayOpenWhileCustodyIsInsolvent() public {
        _deposit(alice, 1000);
        _deposit(bob, 100);
        vm.prank(bob);
        credit.borrow(500e6);
        vm.prank(admin);
        adapter.emergencyUnstake(gov);
        // Repay is never gated on custody.
        _fundAndApprove(bob, 500e6);
        vm.prank(bob);
        credit.repay(type(uint256).max);
        assertEq(credit.debtOf(bob), 0);
        // Borrow is.
        vm.prank(alice);
        vm.expectRevert(CreditManager.CustodyInsolvent.selector);
        credit.borrow(500e6);
    }
}
