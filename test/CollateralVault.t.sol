// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

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

/// @notice Phase-1 lifecycle tests for CollateralVault + DirectCallAdapter against
///         the real-ABI mocks: deposit → stake → claim → unstake → withdraw → seize,
///         the whitelist gate, and the withdrawal LTV rule.
contract CollateralVaultTest is Test {
    uint256 internal constant NAV = 25.15e8; // USD 8dp — 2026-07-24 real snapshot

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

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);
        credit = new MockCreditManager();
        auctionMock = new MockLiquidationAuction();
        auction = address(auctionMock);

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        // setCreditManager refuses a manager bound to a different vault, so the mock
        // has to claim this one. It is built before the vault, hence the setter.
        credit.setVault(address(vault));
        auctionMock.setVault(address(vault));

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

    function test_depositBonds_pausable() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.depositBonds(100);
    }

    // ── depositETH (signed mint, auto-stake) ─────────────────────────────────

    function test_depositETH_mintsAndAutoStakes() public {
        bytes memory mintData = _mintData(address(adapter), 40, 1 ether);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vault.depositETH{value: 1 ether}(mintData);

        assertEq(vault.bondCount(alice), 40);
        assertEq(farm.staked(address(adapter)), 40);
    }

    function test_depositETH_receiverMustBeAdapter() public {
        bytes memory mintData = _mintData(alice, 40, 1 ether);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.ReceiverMustBeAdapter.selector, alice));
        vault.depositETH{value: 1 ether}(mintData);
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

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.WithdrawalExceedsMaxLtv.selector, type(uint256).max)
        );
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

        bytes memory mintData = _mintData(address(adapter), 1, 1 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.depositETH{value: 1 ether}(mintData);

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

    /// @dev 100 bonds at NAV is $2,515 of collateral, so the 5800 bps threshold sits
    ///      at $1,458.70. Derived rather than hard-coded so a NAV or threshold change
    ///      moves it instead of silently making these tests assert nothing.
    function _liquidatableDebt(uint256 bonds) internal pure returns (uint256) {
        return (bonds * NAV * Config.LIQUIDATION_THRESHOLD_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE) + 1;
    }

    /// @dev The largest debt `bonds` may carry and still sit inside the LTV ceiling.
    function _maxDebtFor(uint256 bonds) internal pure returns (uint256) {
        return (bonds * NAV * Config.MAX_LTV_BPS) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
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

        vm.prank(auction);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVault.PositionNotLiquidatable.selector, Config.LIQUIDATION_THRESHOLD_BPS - 1
            )
        );
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

        // And the trapped yield now has a route out.
        vm.prank(admin);
        uint256 swept = vault.harvestYield();
        assertEq(usdc.balanceOf(rescue), 500e6, "recovered in full");
        assertEq(swept, 500e6, "and reported");
        assertEq(adapter.unreportedYield(), 0);
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

    function _mintData(address receiver, uint256 amountNfts, uint256 payment)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            IDexFiBond.MintDataInput({
                uuid: 1,
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
