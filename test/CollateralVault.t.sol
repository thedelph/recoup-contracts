// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
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
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Phase-1 lifecycle tests for CollateralVault + DirectCallAdapter against
///         the real-ABI mocks: deposit → stake → claim → unstake → withdraw → seize,
///         the whitelist gate, and the withdrawal LTV rule.
contract CollateralVaultTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp - 2026-07-24 real snapshot
    bytes32 internal constant MINT_ATTEMPT_ID = bytes32(uint256(1));

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    MockLiquidationAuction internal auctionMock;
    address internal auction;
    address internal winner = makeAddr("winner");
    address internal yieldSink = makeAddr("yieldSink");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    MockCreditManager internal credit;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
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
        credit = new MockCreditManager();
        auctionMock = new MockLiquidationAuction();
        auction = address(auctionMock);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        // setCreditManager refuses a manager bound to a different vault, so the mock
        // has to claim this one. It is built before the vault, hence the setter.
        credit.setVault(address(vault));
        auctionMock.setVault(address(vault));
        // Audit round 20: both setters also check the risk authority agrees with the vault's.
        credit.setRiskParams(address(riskParams));
        auctionMock.setRiskParams(address(riskParams));
        // Audit round 21: and that the NAV feed does too. Read off the vault rather than off
        // the local, because the vault's answer is the anchor the guards compare against.
        credit.setNavOracle(address(vault.navOracle()));
        auctionMock.setNavOracle(address(vault.navOracle()));

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(auction);
        vm.stopPrank();

        // Mirror mainnet: the farm is whitelisted; ask #5 whitelists our adapter.
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        bond.mint(alice, 1_000);
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);
    }

    // ── deposit / stake ──────────────────────────────────────────────────────

    function test_depositBonds_stakesViaAdapter() public {
        vm.prank(alice);
        vault.depositBonds(100);

        assertEq(vault.bondCount(alice), 100);
        assertEq(farm.staked(address(adapter)), 100);
        assertEq(bond.bondBalance(alice), 900);
        assertEq(bond.bondBalance(address(adapter)), 0); // custody sits in the farm
        assertEq(vault.collateralValue(alice), 100 * NAV);
    }

    function test_depositBonds_revertsWithoutWhitelist() public {
        // DexFi has not granted ask #5: adapter (and vault) unlisted ⇒ the
        // depositor→adapter transfer must hit the bond's whitelist gate.
        bond.setWhitelisted(address(adapter), false);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockBond.AddressesNotWhitelisted.selector, address(vault), alice, address(adapter)
            )
        );
        vault.depositBonds(100);
    }

    function test_depositBonds_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.depositBonds(0);
    }

    /// @dev **This test used to pause the vault and assert `depositBonds` reverted, on a bare
    ///      `vm.expectRevert()`.** Both halves of that were worth changing. The behaviour is now
    ///      the opposite - audit round 25, finding 1: `pause()` shuts `depositETH` and leaves
    ///      the borrower's cure open, because a top-up by an indebted borrower can only lower
    ///      LTV and `CreditManager.liquidate`'s docstring already stated the rule (*pause
    ///      stops new risk, never resolution*). And a bare `expectRevert` passes on **any** revert,
    ///      including one meaning the fixture broke, which is how a test can keep passing while
    ///      measuring something else; both assertions below name a selector.
    function test_depositBonds_isNotShutByThePause_onlyByItsOwnSwitch() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vault.depositBonds(100);
        assertEq(vault.bondCount(alice), 100, "the pause must not shut the cure");

        vm.prank(admin);
        vault.setBondDepositsPaused(true);
        vm.prank(alice);
        vm.expectRevert(CollateralVault.BondDepositsArePaused.selector);
        vault.depositBonds(100);
    }

    /// @dev The sibling that did not change: `depositETH` is new exposure - it sends ETH into
    ///      DexFi's mint - so it stays behind the contract-level pause and behind the switch the
    ///      guardian may throw.
    function test_depositETH_isStillShutByThePause() public {
        bytes memory mintData = _mintData(
            adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID), MINT_ATTEMPT_ID, 40, 1 ether
        );
        vm.deal(alice, 1 ether);
        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);
    }

    // ── depositETH (signed mint, auto-stake) ─────────────────────────────────

    function test_depositETH_mintsAndAutoStakes() public {
        bytes memory mintData = _mintData(
            adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID), MINT_ATTEMPT_ID, 40, 1 ether
        );
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);

        assertEq(vault.bondCount(alice), 40);
        assertEq(farm.staked(address(adapter)), 40);
    }

    function test_depositETH_receiverMustMatchPredictedAttemptReceiver() public {
        address expected = adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID);
        bytes memory mintData = _mintData(alice, MINT_ATTEMPT_ID, 40, 1 ether);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintReceiverMismatch.selector, expected, alice)
        );
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);
    }

    // -- depositETH is a farm-touching path and must report what it flushes ---

    /// @notice **Audit round 23, finding 22(a).** `depositETH` flushed protocol-wide farm yield and
    ///         emitted nothing, where all four of its bond-count siblings emit `YieldHarvested`.
    /// @dev MEASURED before the fix, on this fixture: 500.000000 reached `yieldSink` through one
    ///      `depositETH` and the vault emitted **zero** `YieldHarvested` events; the identical flush
    ///      through `depositBonds` emitted one. The mechanism is DexFi's auto-stake: `bond.mint`
    ///      drives the reward pool's `depositForAccount` hook for the adapter, and a
    ///      MasterChef-style pool settles the whole position's pending rewards on any deposit.
    ///
    ///      Counted out of the logs rather than asserted with `expectEmit`, and the emitted number
    ///      is compared against the USDC that actually moved rather than against a literal. An
    ///      `expectEmit` here would pass against an emit of the wrong figure in the wrong place,
    ///      which is the failure mode an event test is most prone to.
    function test_depositETH_reportsTheFarmYieldItFlushes() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 500e6);

        uint256 sinkBefore = usdc.balanceOf(yieldSink);
        bytes memory mintData = _mintData(
            adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID), MINT_ATTEMPT_ID, 40, 1 ether
        );
        vm.deal(alice, 1 ether);

        vm.recordLogs();
        vm.prank(alice);
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);
        (uint256 count, uint256 reported) = _yieldHarvested();

        uint256 moved = usdc.balanceOf(yieldSink) - sinkBefore;
        emit log_named_uint("MEASURED USDC flushed to the yield recipient by the mint", moved);
        emit log_named_uint("MEASURED YieldHarvested events emitted by depositETH", count);
        emit log_named_uint("MEASURED figure reported", reported);
        assertEq(moved, 500e6, "premise: the epoch really does leave through this path");
        assertEq(count, 1, "the path that moved it has to account for it");
        assertEq(reported, moved, "and the reported figure is the money that moved, not a proxy");
    }

    /// @notice CONTROL - the same call with nothing pending reports nothing.
    /// @dev Without this arm, an unconditional `emit YieldHarvested(0)` would satisfy the test
    ///      above, which is exactly how an event assertion passes for the wrong reason. The four
    ///      siblings all guard on `swept != 0` and this one must too.
    function test_depositETH_reportsNothingWhenTheFarmSettlesNothing() public {
        bytes memory mintData = _mintData(
            adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID), MINT_ATTEMPT_ID, 40, 1 ether
        );
        vm.deal(alice, 1 ether);

        vm.recordLogs();
        vm.prank(alice);
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);
        (uint256 count,) = _yieldHarvested();

        assertEq(usdc.balanceOf(yieldSink), 0, "premise: the farm settled nothing");
        assertEq(count, 0, "a path that moved no yield must not claim it moved some");
    }

    /// @notice The reported figure is the amount **swept**, which is this call's farm payout plus
    ///         anything a previous failed sweep carried - the same quantity `stake` and `unstake`
    ///         return to the four siblings.
    /// @dev This is the arm that separates the fix from the plausible near-miss. A version that
    ///      reported only the farm's payout for this call would print 300.000000 while 800.000000
    ///      left the protocol, which is the same class of unaccounted money the finding is about.
    function test_depositETH_reportsTheCarriedYieldTheSweepFinallyDelivers() public {
        vm.prank(alice);
        vault.depositBonds(100);

        // A claim whose sweep cannot go through: 500.000000 is carried in `unreportedYield`.
        farm.setPendingYield(address(adapter), 500e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(admin);
        vault.harvestYield();
        assertEq(adapter.unreportedYield(), 500e6, "premise: an undelivered epoch is carried");

        usdc.setBlocked(yieldSink, false);
        farm.setPendingYield(address(adapter), 300e6);

        bytes memory mintData = _mintData(
            adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID), MINT_ATTEMPT_ID, 40, 1 ether
        );
        vm.deal(alice, 1 ether);

        vm.recordLogs();
        vm.prank(alice);
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);
        (uint256 count, uint256 reported) = _yieldHarvested();

        emit log_named_uint("MEASURED USDC delivered by this deposit", usdc.balanceOf(yieldSink));
        emit log_named_uint("MEASURED figure reported", reported);
        assertEq(usdc.balanceOf(yieldSink), 800e6, "the carried epoch left with this call's payout");
        assertEq(count, 1);
        assertEq(reported, 800e6, "the report is the sweep, not just this call's farm payout");
    }

    /// @notice A sweep that could not go through delivered nothing, so nothing is reported.
    /// @dev The direction to be wrong in. `farmYieldDelivered` is the harvester's corroboration
    ///      watermark, so over-reporting here would rate an epoch against money that never arrived -
    ///      round 22's finding 4 in miniature. The ETH path inherits that property because it reads
    ///      the same counter rather than the adapter's balance.
    function test_depositETH_reportsNothingWhenTheSweepCannotGoThrough() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 500e6);
        usdc.setBlocked(yieldSink, true);

        bytes memory mintData = _mintData(
            adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID), MINT_ATTEMPT_ID, 40, 1 ether
        );
        vm.deal(alice, 1 ether);

        vm.recordLogs();
        vm.prank(alice);
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);
        (uint256 count,) = _yieldHarvested();

        assertEq(usdc.balanceOf(yieldSink), 0, "premise: the recipient could not receive");
        assertEq(usdc.balanceOf(address(adapter)), 500e6, "the money is still here, carried");
        assertEq(count, 0, "and nothing claims it was delivered");
    }

    /// @notice CONTROL for the whole group - the sibling path this one was measured against.
    function test_depositBonds_reportsTheSameFlush() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 500e6);

        vm.recordLogs();
        vm.prank(alice);
        vault.depositBonds(10);
        (uint256 count, uint256 reported) = _yieldHarvested();

        assertEq(usdc.balanceOf(yieldSink), 500e6);
        assertEq(count, 1, "CONTROL: the sibling path reports it");
        assertEq(reported, 500e6);
    }

    /// @dev Counts `YieldHarvested` emitted **by the vault** and returns the last figure reported.
    ///      Filtering on the emitter matters: a count that also picked up another contract's
    ///      identically-named event would report the vault as accounting for a flush it ignored.
    function _yieldHarvested() private returns (uint256 count, uint256 reported) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("YieldHarvested(uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != sig) continue;
            count++;
            reported = abi.decode(logs[i].data, (uint256));
        }
    }

    // ── withdraw + LTV rule ──────────────────────────────────────────────────

    function test_withdrawBonds_debtFree() public {
        vm.startPrank(alice);
        vault.depositBonds(100);
        vault.withdrawBonds(100);
        vm.stopPrank();

        assertEq(vault.bondCount(alice), 0);
        assertEq(farm.staked(address(adapter)), 0);
        assertEq(bond.bondBalance(alice), 1_000);
    }

    function test_withdrawBonds_allowsWithinMaxLtv() public {
        vm.prank(alice);
        vault.depositBonds(100);
        // Debt sized so the 80 remaining bonds sit exactly at maxLTV. Derived, so a
        // change to MAX_LTV_BPS moves the fixture instead of breaking it.
        credit.setDebt(alice, _maxDebtFor(80));

        vm.prank(alice);
        vault.withdrawBonds(20);
        assertEq(vault.bondCount(alice), 80);
    }

    function test_withdrawBonds_revertsBeyondMaxLtv() public {
        vm.prank(alice);
        vault.depositBonds(100);
        credit.setDebt(alice, _maxDebtFor(80));

        // One bond more than the maxLTV allows.
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawBonds(21);
    }

    function test_withdrawBonds_cannotEmptyVaultWithDebt() public {
        vm.prank(alice);
        vault.depositBonds(100);
        credit.setDebt(alice, 1e6);

        // **Read the ceiling first, then expect, then prank.** Two separate things spend a
        // single-shot prank. `vm.expectRevert` is a call this contract makes and consumes one -
        // the rule this file already followed. The parameters moving into `RiskParams` storage
        // added a second: the ceiling is now an external staticcall rather than a compile-time
        // constant, so a read left inline, or inside the `abi.encodeWithSelector` arguments,
        // spends the prank too. Either mistake sends `withdrawBonds` from this contract, which
        // holds no bonds, so it reverts `InsufficientCollateral` and the test quietly checks
        // nothing. Measured, not reasoned: it did exactly that on the first run.
        uint256 ceiling = maxLtvBps();
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVault.WithdrawalExceedsMaxLtv.selector, type(uint256).max, ceiling
            )
        );
        vm.prank(alice);
        vault.withdrawBonds(100);
    }

    function test_withdrawBonds_worksWhilePaused() public {
        vm.prank(alice);
        vault.depositBonds(100);
        vm.prank(admin);
        vault.pause();

        // Exits must never be pausable.
        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(bond.bondBalance(alice), 1_000);
    }

    function test_withdrawBonds_overdrawReverts() public {
        vm.prank(alice);
        vault.depositBonds(100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.InsufficientCollateral.selector, 101, 100));
        vault.withdrawBonds(101);
    }

    // ── yield ────────────────────────────────────────────────────────────────

    function test_harvestYield_sweepsToRecipient() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 500e6);

        vm.prank(admin);
        uint256 claimed = vault.harvestYield();

        assertEq(claimed, 500e6);
        assertEq(usdc.balanceOf(yieldSink), 500e6); // routed to the spendable recipient
        assertEq(usdc.balanceOf(address(vault)), 0); // vault is no longer a USDC sink
        assertEq(usdc.balanceOf(address(adapter)), 0); // adapter holds nothing at rest
    }

    function test_unstake_sweepsPendingYieldToRecipient() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 123e6);

        // Farm pays pending USDC alongside any withdrawal; it must not strand.
        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(usdc.balanceOf(yieldSink), 123e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// Finding 8: a donation to the adapter must not inflate the reported harvest.
    function test_claimYield_reportsFarmDeltaNotBalance() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 500e6);
        usdc.mint(address(adapter), 1_000_000e6); // attacker donation

        vm.prank(admin);
        uint256 claimed = vault.harvestYield();

        assertEq(claimed, 500e6, "report only the farm's payout, not the donation");
        assertEq(usdc.balanceOf(address(adapter)), 0); // everything still swept out
    }

    /// Finding 2: bonds mis-sent to the adapter are not credited to the next depositor.
    function test_depositETH_ignoresDonatedLooseBonds() public {
        // A third party pushes bonds straight to the whitelisted adapter.
        bond.mint(winner, 500);
        vm.prank(winner);
        bond.safeTransferFrom(winner, address(adapter), 0, 500, "");
        assertEq(bond.bondBalance(address(adapter)), 500);

        bytes memory mintData = _mintData(
            adapter.predictMintReceiver(alice, MINT_ATTEMPT_ID), MINT_ATTEMPT_ID, 1, 1 ether
        );
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.depositETH{value: 1 ether}(MINT_ATTEMPT_ID, mintData);

        // Alice is credited exactly what she minted, not the donation.
        assertEq(vault.bondCount(alice), 1);
    }

    // ── adapter migration guards (Finding 3) ─────────────────────────────────

    function test_setCustodyAdapter_revertsWithLivePosition() public {
        vm.prank(alice);
        vault.depositBonds(100); // adapter now holds a live position

        DirectCallAdapter fresh = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AdapterHasLivePosition.selector, 100));
        vault.setCustodyAdapter(ICustodyAdapter(address(fresh)));
    }

    function test_setCustodyAdapter_revertsOnVaultMismatch() public {
        // Adapter bound to a different vault address.
        DirectCallAdapter foreign = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(0xBEEF), admin, yieldSink
        );
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.AdapterVaultMismatch.selector, address(0xBEEF))
        );
        vault.setCustodyAdapter(ICustodyAdapter(address(foreign)));
    }

    // ── stale-NAV withdrawal guard (Finding 6) ───────────────────────────────

    function test_withdrawBonds_revertsOnStaleNav() public {
        vm.prank(alice);
        vault.depositBonds(100);
        credit.setDebt(alice, 1e6);
        oracle.setStale(true);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.NavStale.selector);
        vault.withdrawBonds(10);
    }

    function test_withdrawBonds_debtFreeIgnoresStaleNav() public {
        vm.prank(alice);
        vault.depositBonds(100);
        oracle.setStale(true); // no debt ⇒ staleness is irrelevant

        vm.prank(alice);
        vault.withdrawBonds(100);
        assertEq(vault.bondCount(alice), 0);
    }

    // ── seize / reassign ─────────────────────────────────────────────────────

    /// @dev 100 bonds at NAV is $2,515 of collateral, so at the launch threshold of 5000 bps this
    ///      sits at $1,257.50. Derived rather than hard-coded so a NAV or threshold change moves
    ///      it instead of silently making these tests assert nothing - and `view` rather than
    ///      `pure` since the threshold moved into storage, which is the whole reason a test may
    ///      now change it partway through and still expect the right answer.
    function _liquidatableDebt(uint256 bonds) internal view returns (uint256) {
        return _debtAtThreshold(bonds, NAV) + 1;
    }

    /// @dev The largest debt `bonds` may carry and still sit inside the LTV ceiling.
    function _maxDebtFor(uint256 bonds) internal view returns (uint256) {
        return _maxBorrow(bonds, NAV);
    }

    function _unhealthy(address who, uint256 bonds) internal {
        vm.prank(who);
        vault.depositBonds(bonds);
        credit.setDebt(who, _liquidatableDebt(bonds));
    }

    function test_seize_movesWholePositionToWinner() public {
        _unhealthy(alice, 100);

        vm.prank(auction);
        uint256 seized = vault.seize(alice, winner);

        assertEq(seized, 100);
        assertEq(vault.bondCount(alice), 0);
        assertEq(bond.bondBalance(winner), 100);
    }

    function test_seize_onlyAuction() public {
        vm.expectRevert(CollateralVault.NotLiquidationAuction.selector);
        vault.seize(alice, winner);
    }

    function test_seize_refusesAHealthyPosition() public {
        vm.prank(alice);
        vault.depositBonds(100);
        credit.setDebt(alice, _liquidatableDebt(100) - 2); // a whisker inside the threshold

        // Read first, then expect, then prank, for the reason given in
        // `test_withdrawBonds_cannotEmptyVaultWithDebt`.
        uint256 trigger = liquidationThresholdBps();
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, trigger - 1)
        );
        vm.prank(auction);
        vault.seize(alice, winner);
    }

    /// @notice The executable form of go-live item G2. An owner who repoints the
    ///         auction at themselves still cannot take a healthy position.
    function test_ownerCannotSeizeAHealthyPositionByRepointingTheAuction() public {
        vm.prank(alice);
        vault.depositBonds(100);
        credit.setDebt(alice, 1e6); // comfortably healthy

        // Since audit round 5 the repoint itself is refused: the incoming auction must
        // be a contract bound back to this vault, the same rule the custody adapter and
        // credit manager have always had. An EOA cannot answer `vault()`.
        vm.prank(admin);
        vm.expectRevert();
        vault.setLiquidationAuction(admin);

        // And even a legitimately-wired auction cannot take a healthy position, which
        // is the property that survives regardless of how the pointer is set. Both
        // halves together, because the first guard is the one an owner can work around
        // by deploying a compliant contract, and the second is the one they cannot.
        vm.prank(auction);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, uint256(3))
        );
        vault.seize(alice, admin);

        assertEq(vault.bondCount(alice), 100, "collateral must survive a hostile repoint");
    }

    /// @notice PRD §4.6: staleness pauses borrowing, never liquidation.
    function test_seize_stillWorksOnStaleNav() public {
        _unhealthy(alice, 100);
        oracle.setStale(true);

        vm.prank(auction);
        assertEq(vault.seize(alice, winner), 100);
    }

    /// @dev A position liquidatable on stored debt but cured by yield the accumulator
    ///      has not paid out yet must not be seizable: a permissionless settle would
    ///      have cleared it for free.
    function test_seize_refusesAPositionCuredByUnsettledYield() public {
        _unhealthy(alice, 100);
        credit.setUnsettledCredit(alice, _liquidatableDebt(100));

        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionNotLiquidatable.selector, 0));
        vault.seize(alice, winner);
    }

    function test_reassign_movesTheClaimAndLeavesTheBondsStaked() public {
        _unhealthy(alice, 100);
        uint256 stakedBefore = farm.staked(address(adapter));

        vm.prank(auction);
        uint256 moved = vault.reassign(alice, auction);

        assertEq(moved, 100);
        assertEq(vault.bondCount(alice), 0);
        assertEq(vault.bondCount(auction), 100);
        assertEq(farm.staked(address(adapter)), stakedBefore, "workout must not unstake");
        assertEq(vault.totalBondCount(), 100, "the lot is still collateral in custody");
        assertTrue(vault.custodyIsSolvent(), "custody solvency must stay honest");
    }

    /// @notice The whole point of the workout path: it cannot revert on a bond
    ///         transfer, because it does not make one.
    function test_reassign_survivesTheAdapterLosingItsWhitelistEntry() public {
        _unhealthy(alice, 100);
        bond.setWhitelisted(address(adapter), false);

        vm.prank(auction);
        assertEq(vault.reassign(alice, auction), 100);
        assertEq(vault.bondCount(auction), 100);
    }

    function test_reassign_onlyAuctionAndOnlyWhenLiquidatable() public {
        vm.prank(alice);
        vault.depositBonds(100);

        vm.expectRevert(CollateralVault.NotLiquidationAuction.selector);
        vault.reassign(alice, auction);

        credit.setDebt(alice, 1e6);
        vm.prank(auction);
        vm.expectRevert();
        vault.reassign(alice, auction);
    }

    function test_reassign_settlesBothSidesBeforeMovingTheCount() public {
        _unhealthy(alice, 100);
        uint256 callsBefore = credit.settleCalls();

        vm.prank(auction);
        vault.reassign(alice, auction);

        assertEq(credit.settleCalls(), callsBefore + 2, "both positions settle first");
        assertEq(credit.settledAtBonds(alice), 100, "alice settles against her OLD count");
        assertEq(credit.settledAtBonds(auction), 0, "the destination settles against its old count");
    }

    // ── adapter hardening ────────────────────────────────────────────────────

    function test_adapter_onlyVault() public {
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        adapter.stake(1);
        vm.expectRevert(DirectCallAdapter.NotVault.selector);
        adapter.transferBonds(alice, 1);
        // claimYield is gated to vault OR the wired harvester.
        vm.expectRevert(DirectCallAdapter.NotClaimer.selector);
        adapter.claimYield();
    }

    function test_adapter_ownerOnlyRouting() public {
        // Yield-routing config and the emergency hatch are owner-gated.
        vm.expectRevert();
        adapter.setYieldRecipient(alice);
        vm.expectRevert();
        adapter.setHarvester(alice);
        vm.expectRevert();
        adapter.emergencyUnstake(alice);

        vm.prank(admin);
        adapter.setHarvester(alice);
        assertEq(adapter.harvester(), alice);
    }

    /// @dev Repointing the yield recipient sweeps everything the adapter holds to the
    ///      outgoing address - including the USDC backing `unreportedYield`. The
    ///      counter has to go with it. Left standing it is a claim on money the
    ///      adapter no longer has: the next claim reports a figure it cannot pay, and
    ///      an exit hands the vault a swept amount that never arrived.
    function test_adapter_repointingYieldRecipientClearsTheCarriedCounter() public {
        vm.prank(alice);
        vault.depositBonds(100);

        // Strand a payout here by making the sweep fail, which is the only way
        // unreportedYield ever becomes non-zero.
        farm.setPendingYield(address(adapter), 500e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(alice);
        vault.withdrawBonds(50);
        usdc.setBlocked(yieldSink, false);

        assertEq(adapter.unreportedYield(), 500e6, "carried, because the sweep failed");
        assertEq(usdc.balanceOf(address(adapter)), 500e6, "and the USDC is still here");

        address newSink = makeAddr("newSink");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);

        assertEq(usdc.balanceOf(address(adapter)), 0, "swept to the outgoing recipient");
        assertEq(usdc.balanceOf(yieldSink), 500e6);
        assertEq(adapter.unreportedYield(), 0, "and the counter went with it");
    }

    /// @dev Audit round 17: `_trySweepUsdc` read "the low-level call did not revert" as
    ///      "the money moved". A token that returns `false` without reverting satisfies
    ///      the first and not the second, and the swept figure feeds the harvester's
    ///      corroboration watermark - so an over-report there rates an epoch against
    ///      money that never arrived.
    ///
    ///      This branch was unreachable from the suite until `MockUSDC.setSilentlyFails`
    ///      existed: the mock could only revert, which the old code already handled. The
    ///      defect survived because the only failure shape the tests could express was
    ///      the one that was covered.
    function test_adapter_aSilentlyFailingTransferIsNotCountedAsSwept() public {
        vm.prank(alice);
        vault.depositBonds(100);

        farm.setPendingYield(address(adapter), 500e6);
        usdc.setSilentlyFails(yieldSink, true);

        vm.prank(alice);
        vault.withdrawBonds(50);

        assertEq(usdc.balanceOf(yieldSink), 0, "premise: nothing actually moved");
        assertEq(usdc.balanceOf(address(adapter)), 500e6, "premise: the USDC is still here");
        assertEq(adapter.unreportedYield(), 500e6, "so it is carried, not counted as delivered");

        // And the carry is honest: once the token behaves, the same money sweeps once.
        usdc.setSilentlyFails(yieldSink, false);
        farm.setPendingYield(address(adapter), 0);
        vm.prank(alice);
        vault.withdrawBonds(10);

        assertEq(usdc.balanceOf(yieldSink), 500e6, "delivered exactly once");
        assertEq(adapter.unreportedYield(), 0, "and the counter cleared");
    }

    /// @dev **The blacklist-trap regression.** The adapter's sweep is deliberately
    ///      best-effort so a USDC pause or blacklist can never brick a collateral
    ///      exit - but `setYieldRecipient`, the designated escape from a recipient
    ///      that can no longer receive, used to hard-`safeTransfer` the whole balance
    ///      to that very address first. It reverted on exactly the condition it
    ///      existed to fix, so the recipient could never be repointed and every dollar
    ///      of farm yield was trapped in an immutable contract, growing with each exit.
    ///
    ///      The test above steps around this by unblocking the sink one line before
    ///      the repoint. This one leaves it blocked, which is the real situation.
    ///
    ///      **Audit round 22, finding 4: the route out is right, the destination was not.**
    ///      This test used to end by handing the whole trapped balance to `rescue` - an
    ///      address the outgoing recipient had no relationship with - and called that "the
    ///      trapped yield now has a route out". It is gross farm yield, earned before the
    ///      repoint and owed to the recipient that earned it, and the drain that was meant
    ///      to deliver it does nothing on precisely the condition this test sets up. So the
    ///      money is now **parked against the outgoing recipient** and flushed to it,
    ///      permissionlessly, once it can receive again. Both halves are asserted: the
    ///      repoint still cannot be blocked, and the money still cannot be redirected.
    function test_adapter_canRepointAwayFromABlockedYieldRecipient() public {
        vm.prank(alice);
        vault.depositBonds(100);

        farm.setPendingYield(address(adapter), 500e6);
        usdc.setBlocked(yieldSink, true);

        // The exit still works - that hardening is not what is being tested.
        vm.prank(alice);
        vault.withdrawBonds(50);
        assertEq(adapter.unreportedYield(), 500e6, "carried, sweep failed");
        assertEq(usdc.balanceOf(address(adapter)), 500e6, "and stuck here");

        // The escape must go through with the old sink still blocked.
        address rescue = makeAddr("rescue");
        vm.prank(admin);
        adapter.setYieldRecipient(rescue);
        assertEq(adapter.yieldRecipient(), rescue, "repointed despite the block");

        // The drain could not run, so the money is checkpointed against the recipient that
        // earned it rather than left free for the next sweep to hand to `rescue`.
        assertEq(adapter.owedToRecipient(yieldSink), 500e6, "not parked against the earner");
        assertEq(adapter.totalOwedToRecipients(), 500e6, "and the sum has to move with it");
        assertEq(adapter.unreportedYield(), 0, "the carry counter is a claim on money now spoken for");

        // A sweep after the repoint finds nothing free, which is the whole point.
        vm.prank(admin);
        assertEq(vault.harvestYield(), 0, "the parked balance was swept to the new recipient");
        assertEq(usdc.balanceOf(rescue), 0, "and the new recipient took money it never earned");

        // And the route out: permissionless, destination taken from the mapping key.
        usdc.setBlocked(yieldSink, false);
        vm.prank(alice); // no role at all
        adapter.flushYieldTo(yieldSink);
        assertEq(usdc.balanceOf(yieldSink), 500e6, "recovered in full, by the party that earned it");
        assertEq(adapter.owedToRecipient(yieldSink), 0);
        assertEq(adapter.totalOwedToRecipients(), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0, "and nothing is left stranded here");
    }

    /// @notice **Finding 4, the hazard the park closes.** The next ordinary deposit - made by a
    ///         lender, not the owner - used to deliver the whole accrued epoch to whichever
    ///         address the owner had just named.
    /// @dev MEASURED before the fix: 1,000.000000 gross accrued, `setYieldRecipient(newSink)` with
    ///      the outgoing recipient blacklisted so the drain is inert, then one `depositBonds(1)`
    ///      delivers 1,000.000000 to `newSink` and 0 to the recipient that earned it - and
    ///      `farmYieldDelivered`, the corroboration watermark the harvester rates epochs against,
    ///      still recorded it as delivered.
    ///
    ///      CONTROL: the same sequence with the outgoing recipient able to receive parks nothing,
    ///      because the drain works. That arm is
    ///      `test_adapter_repointingYieldRecipientClearsTheCarriedCounter` above and is unchanged.
    function test_adapter_aRepointCannotHandTheOutgoingRecipientsYieldToTheNextSink() public {
        vm.prank(alice);
        vault.depositBonds(100);

        // A whole epoch of gross yield, stranded here because the recipient cannot receive.
        farm.setPendingYield(address(adapter), 1_000e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(admin);
        vault.harvestYield();
        assertEq(usdc.balanceOf(address(adapter)), 1_000e6, "premise: the gross epoch is sitting here");
        uint256 deliveredBefore = adapter.farmYieldDelivered();

        address newSink = makeAddr("newSink");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);

        // The lender deposit, which is what actually moved the money.
        vm.prank(alice);
        vault.depositBonds(1);

        emit log_named_uint("MEASURED delivered to the incoming sink", usdc.balanceOf(newSink));
        emit log_named_uint("MEASURED parked for the recipient that earned it", adapter.owedToRecipient(yieldSink));
        assertEq(usdc.balanceOf(newSink), 0, "a lender's deposit paid the new sink the old one's epoch");
        assertEq(adapter.owedToRecipient(yieldSink), 1_000e6, "the earner is not owed it");
        assertEq(
            adapter.farmYieldDelivered(),
            deliveredBefore,
            "the corroboration watermark counted money nobody received"
        );
    }

    /// @notice The park is not a state anyone can be stuck in, and it is not a destination anyone
    ///         can choose either.
    function test_adapter_flushYieldToIsPermissionlessAndPaysOnlyTheMappingKey() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 300e6);
        usdc.setBlocked(yieldSink, true);
        vm.prank(admin);
        vault.harvestYield();

        address newSink = makeAddr("newSink");
        vm.prank(admin);
        adapter.setYieldRecipient(newSink);
        assertEq(adapter.owedToRecipient(yieldSink), 300e6, "premise: parked");

        // Nothing is owed to anybody else, and asking says so rather than paying zero.
        vm.expectRevert(DirectCallAdapter.NothingToFlush.selector);
        adapter.flushYieldTo(newSink);
        vm.expectRevert(DirectCallAdapter.NothingToFlush.selector);
        adapter.flushYieldTo(alice);

        // A recipient that still cannot receive surfaces the failure rather than reporting
        // success, matching `EpochHarvester.flushProtocolFeeTo`.
        vm.expectRevert();
        adapter.flushYieldTo(yieldSink);

        usdc.setBlocked(yieldSink, false);
        adapter.flushYieldTo(yieldSink);
        assertEq(usdc.balanceOf(yieldSink), 300e6);
    }

    /// @dev A blocked recipient must not brick harvesting either - the yield carries
    ///      to the next successful claim rather than reverting the epoch.
    function test_adapter_claimYieldCarriesRatherThanRevertingOnABlockedSink() public {
        vm.prank(alice);
        vault.depositBonds(100);
        farm.setPendingYield(address(adapter), 300e6);
        usdc.setBlocked(yieldSink, true);

        vm.prank(admin);
        uint256 swept = vault.harvestYield();
        assertEq(swept, 0, "nothing left, and it said so");
        assertEq(adapter.unreportedYield(), 300e6, "carried instead");

        usdc.setBlocked(yieldSink, false);
        vm.prank(admin);
        assertEq(vault.harvestYield(), 300e6, "picked up by the next claim");
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_depositWithdraw_roundTrips(uint256 amount) public {
        amount = bound(amount, 1, 1_000);
        vm.startPrank(alice);
        vault.depositBonds(amount);
        vault.withdrawBonds(amount);
        vm.stopPrank();

        assertEq(vault.bondCount(alice), 0);
        assertEq(bond.bondBalance(alice), 1_000);
        assertEq(farm.staked(address(adapter)), 0);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _mintData(address receiver, bytes32 attemptId, uint256 amountNfts, uint256 payment)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            IDexFiBond.MintDataInput({
                uuid: uint256(attemptId),
                nonce: 0,
                receiver: receiver,
                amountNfts: amountNfts,
                paymentAmount: payment,
                deadline: block.timestamp + 1 hours,
                signature: ""
            })
        );
    }
}
