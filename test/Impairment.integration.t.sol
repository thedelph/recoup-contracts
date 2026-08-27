// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {ILenderPool} from "../src/interfaces/ILenderPool.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Impairment pricing, wired end to end: `CreditManager` marks a liquidation into the
///         lender pool's exit price the moment an auction opens, re-sizes it as the position moves,
///         and every terminal transition of the auction releases it.
///
/// @dev **The real `LenderPool` is both the liquidity source and the loss sink here, and that is
///      the whole reason this file exists.** `LiquidationAuction.t.sol` funds its book from
///      `TreasuryLiquiditySource`, so `LenderPool.outstandingPrincipal` is zero throughout it - and
///      every reserve in the pool clamps to that figure. A suite built on the treasury cannot
///      distinguish "the impairment was released" from "the impairment was always zero", which is
///      exactly the shape of vacuous test this repo has now been bitten by three times.
///
///      The fixture mirrors `LiquidationAuction.t.sol`'s: real 2026-07-24 NAV, 100 bonds, and every
///      scenario NAV solved from the live risk parameters rather than written down. A literal here
///      would keep passing while meaning something else the next time the LTV ratchet moves, which
///      is how 53 tests once failed in a fixture rather than in the code under test.
///
///      Those figures were `internal constant`s until the four negotiated parameters moved into
///      `RiskParams` storage, and a Solidity `constant` cannot read a storage slot. They are `view`
///      functions on `RiskParamsFixture`'s derivations now, re-read on every call: a test that
///      moves a parameter partway through has to see the new figure, and a variable cached in
///      `setUp` would keep passing against the stale one.
contract ImpairmentIntegrationTest is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8; // USD 8dp
    uint256 internal constant BONDS = 100;
    uint256 internal constant LENDER_DEPOSIT = 20_000e6;

    // ── the derived scenario figures ─────────────────────────────────────────

    /// @dev Borrowing power at the ceiling: BONDS x NAV x maxLTV, in USDC 6dp.
    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    /// @dev The NAV at which the whole lot is worth exactly the debt, so a fill at 100% of NAV
    ///      covers the loan and not a cent more. The exact-fill scenario is built on it.
    function _debtParityNav() internal view returns (uint256) {
        return _navAtDebtParity(_maxBorrowAtCeiling(), BONDS);
    }

    /// @dev The NAV at which the auction's *floor* lands exactly on the debt. Above it a floor fill
    ///      covers the loan and the honest impairment is zero; below it there is a shortfall to
    ///      reserve. Derived, because it depends on three parameters at once.
    function _floorParityNav() internal view returns (uint256) {
        return (_debtParityNav() * Config.BPS) / Config.AUCTION_FLOOR_BPS;
    }

    /// @dev Inside the band where the floor undershoots the debt but a fill near the top of the
    ///      curve clears it. The "fill covers the debt" scenario needs both halves at once: an
    ///      impairment that is genuinely non-zero at the midpoint, and a fill that leaves no loss.
    function _navFloorShortOfDebt() internal view returns (uint256) {
        return (_debtParityNav() + _floorParityNav()) / 2;
    }

    /// @dev The other side: even a fill at 100% of NAV cannot cover the loan.
    function _crashedNav() internal view returns (uint256) {
        return _debtParityNav() / 2;
    }

    /// @dev **The ordinary liquidation, and the one every scenario in this file used to miss.**
    ///
    ///      `_worstFirstTriggerLtvBps()` is derived the way `Config.t.sol` derives it, from what
    ///      `NAVOracle` will accept without a second key rather than from `NAV_MAX_DEVIATION_BPS`
    ///      directly: the worst LTV a position can *first* become liquidatable at is the threshold
    ///      after one maximal accepted drop. Anything worse than this needs either a two-key
    ///      confirmed move or a keeper that stopped posting, so this is the liquidation that
    ///      happens when everything is working. It lives on `RiskParamsFixture` rather than here
    ///      because the threshold it is built on is now storage, and seven fixtures were keeping
    ///      their own copies of derivations like it.
    ///
    ///      It sits at ~5555 bps, which is **1,245 bps inside `AUCTION_FLOOR_BPS`** - so the floor
    ///      covers the debt outright and the pre-round-13 formula (`debt - floorProceeds`, saturated
    ///      at zero) marked exactly nothing. The mechanism was dormant in precisely the case it
    ///      exists for.
    ///
    ///      NAV is inversely proportional to LTV, and `_debtParityNav()` is LTV 10,000 bps by
    ///      construction, so this lands the position exactly on that LTV.
    function _ordinaryTriggerNav() internal view returns (uint256) {
        return (_debtParityNav() * Config.BPS) / _worstFirstTriggerLtvBps();
    }

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // borrower
    address internal lender = makeAddr("lender");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal payer = makeAddr("payer"); // relays a workout recovery
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
        // Both roles, which is the Phase 4 wiring and the only one where the pool has exposure to
        // impair against. `_socialise` refuses a pool that is not also the source.
        credit.setLiquiditySource(address(pool));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Borrow at the ceiling, then move NAV to `nav` and liquidate. The auction freezes that
    ///      NAV, so each scenario picks the recovery it wants to test by picking a NAV.
    function _openAuctionAt(uint256 nav) internal returns (uint256 id) {
        // **Read before the prank, never from inside the argument list.** The derivation is an
        // external view call now that the risk parameters are storage, and `vm.prank` applies to
        // the *next* call including a static one - so leaving it in argument position would spend
        // the prank on the parameter read and run `borrow` as this contract.
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(nav);
        vm.prank(keeper);
        credit.liquidate(alice);
        id = auction.auctionOf(alice);
        assertGt(id, 0, "fixture: the auction did not open");
    }

    /// @dev A second lender, so the exit price has somebody to be wrong about other than the one
    ///      the fixture deposits in `setUp`.
    function _lend(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(auction), type(uint256).max);
    }

    /// @dev What the whole lot fetches at the auction floor, recomputed here from `Config` rather
    ///      than read back from `floorProceeds`. A test that asks the contract for its own answer
    ///      and then asserts the answer matches proves only that the call is deterministic.
    function _floorPrice(uint256 nav) internal pure returns (uint256) {
        uint256 numerator = BONDS * nav * Config.AUCTION_FLOOR_BPS;
        uint256 denominator = Config.BPS * Config.USDC_TO_NAV_SCALE;
        return (numerator + denominator - 1) / denominator; // rounds up, as the auction does
    }

    /// @dev Deliver an epoch's yield to the borrower side and let the whole stream land. Alice
    ///      holds every bond in this fixture, so she takes all of it and the arithmetic stays
    ///      checkable by hand. Deliberately does **not** settle: the point of the tests below is
    ///      what the yield stream does to the mark with no transaction naming the borrower at all.
    function _streamYieldToAlice(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();
    }

    /// @dev The mark has to be visible in the middle of every scenario, or "it was released" is
    ///      indistinguishable from "there was never anything to release" - which is the one way a
    ///      release test proves nothing at all.
    function _assertMarked(string memory scenario) internal view {
        assertGt(pool.impairmentOf(alice), 0, string.concat(scenario, ": nothing was marked to release"));
        assertGt(pool.totalImpairment(), 0, string.concat(scenario, ": the summed reserve is empty"));
    }

    function _assertReleased(string memory scenario) internal view {
        assertEq(pool.impairmentOf(alice), 0, string.concat(scenario, ": the reserve outlived its auction"));
        assertEq(pool.totalImpairment(), 0, string.concat(scenario, ": the summed reserve outlived its auction"));
    }

    // ── the release set ──────────────────────────────────────────────────────

    /// @notice No impairment outlives the auction that caused it, on any of the six ways an auction
    ///         can end.
    /// @dev `LenderPool.releaseImpairment` names this test in its own NatSpec as the thing that
    ///      pins the claim, so it is one test rather than six: the claim is about the *set* being
    ///      complete, and six separately-named tests are six chances to add a seventh transition
    ///      and not notice that nothing covers it.
    ///
    ///      The set was derived from the storage the exits write - see `_refreshImpairment` in
    ///      `LiquidationAuction` for the grep and for why enumerating from the interface is what
    ///      round 11 punished. Two of these six reach the manager through no other route at all: a
    ///      fill *at* the debt returns early out of `_creditProceeds` (no penalty, no surplus, so
    ///      nothing to credit), and `cancel` never wrote to the manager in its life.
    ///
    ///      Each scenario runs from a clean snapshot, because a stale mark from the previous one
    ///      would make the next one's release assertion pass for the wrong reason.
    function test_impairment_isReleasedOnEveryAuctionExit() public {
        uint256 clean = vm.snapshotState();

        _exitByFillCoveringTheDebt();
        _assertReleased("fill above the debt");
        vm.revertToState(clean);
        clean = vm.snapshotState();

        _exitByFillAtExactlyTheDebt();
        _assertReleased("fill exactly at the debt");
        vm.revertToState(clean);
        clean = vm.snapshotState();

        _exitByFillShortOfTheDebt();
        _assertReleased("fill short of the debt");
        vm.revertToState(clean);
        clean = vm.snapshotState();

        _exitByCancel();
        _assertReleased("cancel");
        vm.revertToState(clean);
        clean = vm.snapshotState();

        _exitByCleanWorkout();
        _assertReleased("workout closed clean");
        vm.revertToState(clean);
        clean = vm.snapshotState();

        _exitByForcedWorkout();
        _assertReleased("workout closed by force");
    }

    /// @notice A winning bidder cannot release their own mark from inside the seize callback.
    /// @dev **The third contract to be caught by the same window.** Round 11 found a lender who won
    ///      their own auction could read `liveAuctionCount == 0` from `onERC1155Received` - the loss
    ///      certain, booked nowhere yet - and moved the decrement below `_settleFill`. Wiring
    ///      `refreshImpairment` reopened it one door along: `_impairmentFor` reads `auctionOf` to
    ///      decide whether a borrower is still under liquidation, `refreshImpairment` is
    ///      permissionless, and `auctionOf` used to clear before the seize. So the same bidder could
    ///      release the mark from the same callback and leave at the pre-loss price.
    ///
    ///      The round-10 exit gate was still in place when this was written and masked it, which is
    ///      the only reason it is a test rather than an incident. The gate has since been deleted;
    ///      a hole found after that would have been the finding reinstated for the third round
    ///      running, so it had to be found first and it was.
    ///
    ///      `_settleFill` runs after the callback, so the honest answer inside it is "still marked".
    ///
    ///      **`assertGt(mark, 0)` was that answer until audit round 15, and it is now too weak to
    ///      be evidence.** Since the recovery is recognised before `seize`, the mark inside the
    ///      callback is the shortfall this fill will actually realise, not the whole debt - so a
    ///      non-zero assertion would keep passing against a netting that was wrong by any amount,
    ///      and would keep passing against no netting at all. It asserts the exact figure instead,
    ///      and the covering-fill sibling below asserts the other side of the same claim, which is
    ///      the case where the honest answer is zero.
    function test_impairment_cannotBeReleasedFromInsideTheSeizeCallback() public {
        uint256 id = _openAuctionAt(_crashedNav());
        _assertMarked("callback attack");

        uint256 price = auction.currentPrice(id);
        uint256 debt = credit.currentDebtOf(alice);
        assertLt(price, debt, "fixture: this fill must leave a real shortfall to keep marked");

        CallbackBidder attacker = new CallbackBidder(credit, pool, alice);
        _fund(address(attacker), price);

        vm.prank(address(attacker));
        auction.bid(id);

        assertTrue(attacker.ran(), "the callback never fired, so this test proves nothing");
        assertEq(
            attacker.markDuringCallback(),
            debt - price,
            "the mark inside the callback must be the shortfall this fill will realise, exactly"
        );
    }

    /// @notice And the other side: a fill that covers the debt leaves nothing marked, inside the
    ///         callback, before the winner gets control.
    /// @dev The inversion of the test above, and the pair is the claim. One asserts the mark is not
    ///      released early; the other asserts it is not left standing over a recovery that has
    ///      already been paid in. A netting that did nothing passes the first and fails this;
    ///      clearing the pointer early passes this and fails the first.
    ///
    ///      This is the case the queue-servicing attack was profitable in, so it is also the direct
    ///      statement of why that attack no longer pays: there is no over-mark left to spend.
    function test_impairment_aCoveringFillLeavesNothingMarkedInsideTheCallback() public {
        uint256 id = _openAuctionAt(_navFloorShortOfDebt());
        _assertMarked("covering fill");

        uint256 price = auction.currentPrice(id);
        assertGt(price, credit.currentDebtOf(alice), "fixture: this fill must clear the debt");

        CallbackBidder attacker = new CallbackBidder(credit, pool, alice);
        _fund(address(attacker), price);

        vm.prank(address(attacker));
        auction.bid(id);

        assertTrue(attacker.ran(), "the callback never fired, so this test proves nothing");
        assertEq(attacker.markDuringCallback(), 0, "a covered loan was still marked inside the callback");
        assertEq(attacker.reserveDuringCallback(), 0, "and the pool was still reserving against it");
    }

    /// @notice **The same fill is never netted off the mark twice.** What stands against the
    ///         borrower while the fill is being settled is the shortfall that fill will actually
    ///         leave - not that shortfall less the fill a second time.
    ///
    /// @dev Audit round 16, eleven of twelve agents, executed twice. The recovery is recognised
    ///      before `seize` so nothing can spend an un-netted mark, and it was cleared one statement
    ///      too late: after `_settleFill`, which reaches `CreditManager._repay`, which has
    ///      re-derived the mark on its way out since audit round 13. At that statement the debt has
    ///      already fallen by the fill and the recovery still records the same fill as unspent, so
    ///      the same dollars are subtracted twice.
    ///
    ///      **This is why the end state proved nothing.** By the end of the transaction the mark is
    ///      released and the loss is booked, correctly, on every path - which is how 513 tests
    ///      stayed green over it. The defect only exists at instants *inside* the fill, so the test
    ///      has to observe the writes rather than the result. Nothing runs attacker code in that
    ///      window, so the probe is the event trace: every mark the pool was quoting exits at
    ///      before the loss was booked.
    ///
    ///      `LossReservesSet` is asserted alongside `Impaired` because it is one level closer to
    ///      money: `exitReserve()` is what `previewRedeem` stands back from, so an understated
    ///      figure there is a leaver being quoted a price over a loss that is already certain.
    ///
    ///      Two scenarios, because the harm has two shapes and a fix that closed one and not the
    ///      other would look right. Below a half-debt fill the mark is merely understated; at or
    ///      above one it saturates to zero, `ImpairmentReleased` fires and `exitAssets()` equals
    ///      `totalAssets()` with a certain loss unbooked - which is verbatim the state audit round
    ///      15 existed to remove, recreated inside the transaction that removes it.
    ///
    ///      **What this test deliberately does not pin**, so the next round reads the gap as a gap
    ///      and not a hole: deleting the refresh at the end of `CreditManager._repay` leaves this
    ///      green, because the pre-seize mark already equals the residual. That statement is pinned
    ///      by the clean-workout branch of `test_impairment_isReleasedOnEveryAuctionExit`. Deleting
    ///      the pre-seize recognition is pinned by
    ///      `test_impairment_cannotBeReleasedFromInsideTheSeizeCallback`.
    function test_impairment_isNotDoubleNettedWhileTheFillIsSettled() public {
        uint256 clean = vm.snapshotState();
        _assertNoMarkFallsBelowTheResidual(_crashedNav(), "understated");
        vm.revertToState(clean);
        _assertNoMarkFallsBelowTheResidual(_navFloorShortOfDebt(), "erased");
    }

    /// @dev Fills at the floor rather than at the top of the curve. The floor is where the
    ///      shortfall is largest, so it is where a double subtraction is furthest from the truth,
    ///      and it is the fill the executed proof used.
    function _assertNoMarkFallsBelowTheResidual(uint256 nav, string memory scenario) private {
        uint256 id = _openAuctionAt(nav);
        _assertMarked(scenario);
        skip(Config.AUCTION_DURATION);

        uint256 debt = credit.currentDebtOf(alice);
        uint256 price = auction.currentPrice(id);
        assertEq(price, _floorPrice(nav), string.concat(scenario, ": fixture must fill at the floor"));
        assertLt(price, debt, string.concat(scenario, ": fixture must leave a real shortfall"));
        uint256 residual = debt - price;

        _fund(bidder, price);
        vm.recordLogs();
        vm.prank(bidder);
        auction.bid(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Walk in order and stop at the write-down: everything before it is a figure the pool was
        // publishing while the whole shortfall was still on the books.
        uint256 lowestMark = type(uint256).max;
        uint256 lowestReserve = type(uint256).max;
        uint256 markWrites;
        bool sawRepaid;
        bool sawWriteDown;
        bytes32 aliceTopic = bytes32(uint256(uint160(alice)));

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(credit)) {
                if (logs[i].topics[0] == keccak256("Repaid(address,uint256)")) sawRepaid = true;
                if (logs[i].topics[0] == keccak256("LossWrittenDown(address,uint256,uint256,uint256)")) {
                    sawWriteDown = true;
                    break;
                }
                continue;
            }
            if (logs[i].emitter != address(pool)) continue;

            if (logs[i].topics[0] == keccak256("Impaired(address,uint256,uint256)") && logs[i].topics[1] == aliceTopic)
            {
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, uint256));
                markWrites++;
                if (amount < lowestMark) lowestMark = amount;
            } else if (
                logs[i].topics[0] == keccak256("ImpairmentReleased(address,uint256,uint256)")
                    && logs[i].topics[1] == aliceTopic
            ) {
                // A release mid-fill is the saturating case: the mark reached zero over a loss
                // nothing had booked yet.
                markWrites++;
                lowestMark = 0;
            } else if (logs[i].topics[0] == keccak256("LossReservesSet(uint256,uint256,uint256)")) {
                (,, uint256 reserve) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                if (reserve < lowestReserve) lowestReserve = reserve;
            }
        }

        // A filter that matched nothing must fail loudly rather than pass on an empty loop. Audit
        // round 16 found a pin that asserted a view and passed against the function it named doing
        // nothing at all.
        assertTrue(sawRepaid, string.concat(scenario, ": the fill never reached the repayment leg"));
        assertTrue(sawWriteDown, string.concat(scenario, ": the fill never recognised a loss"));
        assertGt(markWrites, 0, string.concat(scenario, ": no mark was written before the loss was booked"));

        assertEq(
            lowestMark, residual, string.concat(scenario, ": the mark fell below the shortfall this fill leaves")
        );
        assertEq(
            lowestReserve,
            residual,
            string.concat(scenario, ": the pool published an exit reserve below the pending shortfall")
        );

        // The end state, asserted so the fix cannot regress it - and it is not the evidence, because
        // it is already correct on the unfixed tree.
        assertEq(pool.impairmentOf(alice), 0, string.concat(scenario, ": the mark outlived its auction"));
        assertEq(
            pool.lifetimeSocialisedLoss() + credit.unsocialisedLoss(),
            residual,
            string.concat(scenario, ": the loss booked must be the shortfall the fill left")
        );
    }

    /// @notice **The withdrawal queue does not shut over a debt the yield stream has already paid
    ///         off.** A cleared loan reserves nothing, and idle cash pays the queue.
    ///
    /// @dev Audit round 16, executed. `impairmentOf` is a photograph of `currentDebtOf`, which
    ///      decays continuously on the yield stream with no transaction to hang a refresh on.
    ///      `_settle` is the one debt-writing path that never told the pool; audit round 13 added
    ///      exactly that refresh to `_repay` on the reasoning that "repayment is not a transition
    ///      and notifies nobody", and the identical reasoning applies to yield application.
    ///
    ///      **Audit round 15's queue fix is what escalated this from a wrong price to a total
    ///      freeze.** Before it, a stale-high mark mispriced an exit; after it, any non-zero
    ///      `exitReserve()` stops the paying walk for everybody. Widening what a condition governs
    ///      re-prices every latent defect that can reach it, and this one was not in that diff.
    ///
    ///      The premise is asserted rather than assumed, because the whole finding is that this is
    ///      not a shortage: the debt is zero, the pool is holding cash, and the queue is shut
    ///      anyway.
    ///
    ///      **What this test claims, precisely, and what it does not.** It does not claim the queue
    ///      heals itself. `serviceQueue` walks a shared FIFO and must not make one lender's turn
    ///      depend on a foreign contract answering, which is the rule this repo has now broken and
    ///      re-learned three times. What it claims is that the stale mark is reachable and
    ///      clearable by **anybody, in one bounded call, knowing no borrower address** - and that
    ///      the refusal says which of the two refusals it is, so a caller who hits it knows what to
    ///      do. Before this, the caller had to reconstruct the borrower from `Impaired` logs and
    ///      then call a different contract, and `NothingToService` gave them no reason to think of
    ///      doing either.
    function test_impairment_doesNotFreezeTheQueueOverADebtTheStreamAlreadyCleared() public {
        _lend(stranger, 4_000e6);
        uint256 shares = pool.balanceOf(stranger);
        vm.prank(stranger);
        pool.requestWithdrawal(shares, stranger);

        _openAuctionAt(_crashedNav());
        _assertMarked("stream clears the debt");

        // More than the whole debt, so the stream provably pays it off rather than nearly so.
        _streamYieldToAlice(2 * _maxBorrowAtCeiling());

        assertEq(credit.currentDebtOf(alice), 0, "fixture: the stream must have cleared the debt");
        assertGt(pool.exitReserve(), 0, "fixture: the stale mark must still be standing");
        assertGt(usdc.balanceOf(address(pool)), 0, "fixture: this must not be a genuine shortage");

        // The refusal now names its cause. `NothingToService` said only "nothing happened", which
        // is what a genuine shortage says too.
        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(10);

        // One bounded, permissionless call, made by somebody who knows no borrower address and
        // reads no logs. This is the whole remedy.
        vm.prank(stranger);
        credit.refreshImpairments(8);

        assertEq(pool.totalImpairment(), 0, "the stale mark survived a sweep that could see it");
        assertEq(pool.serviceQueue(10), 1, "idle cash, a cleared debt, and the queue still shut");
        assertGt(pool.claimable(stranger), 0, "the queued lender was never paid");
    }

    /// @notice The impaired borrowers are enumerable on-chain, so clearing a stale mark never
    ///         needs event archaeology.
    /// @dev The half of the fix that is not about this bug. `totalImpairment` is a running
    ///      `total + amount - previous` that nothing could audit, because the map it sums had no
    ///      key list. Two marks, one released, and the set must be exactly the survivors with no
    ///      hole and no duplicate left by the swap-pop.
    function test_impairment_theMarkedBorrowersAreEnumerable() public {
        _openAuctionAt(_crashedNav());
        assertEq(pool.impairedBorrowerCount(), 1, "the marked borrower is not in the set");
        assertEq(pool.impairedBorrowerAt(0), alice, "the set names the wrong borrower");

        uint256 summed;
        for (uint256 i; i < pool.impairedBorrowerCount(); ++i) {
            summed += pool.impairmentOf(pool.impairedBorrowerAt(i));
        }
        assertEq(summed, pool.totalImpairment(), "the running total disagrees with the set it sums");

        // Heal the position and cancel, which is the release path that touches the pool.
        oracle.setNav(NAV);
        vm.prank(stranger);
        auction.cancel(auction.auctionOf(alice));

        assertEq(pool.impairedBorrowerCount(), 0, "a released mark left its borrower in the set");
        assertEq(pool.totalImpairment(), 0);
    }

    /// @notice And the mark itself moves when the yield stream moves the debt, without anybody
    ///         having to know to call the refresh on another contract.
    /// @dev The companion to the test above, stated as the property rather than as its worst
    ///      symptom. The queue freeze is what made this expensive; the defect is that the number
    ///      the mark is made of moved and the mark did not.
    function test_impairment_isRefreshedWhenTheYieldStreamPaysTheDebtDown() public {
        _openAuctionAt(_crashedNav());
        _assertMarked("stream pays the debt down");

        _streamYieldToAlice(_maxBorrowAtCeiling() / 2);
        credit.settle(alice);

        assertEq(
            pool.impairmentOf(alice),
            credit.currentDebtOf(alice),
            "the mark is made of the debt, so applying yield has to move it"
        );
    }

    /// @notice The mark follows a repayment made from inside the seize callback, dollar for dollar.
    /// @dev **The discriminating test between the two families of fix for the finding above.**
    ///      Clearing the recognition once the callback is over tracks a mid-callback cure exactly,
    ///      because the mark is re-derived from `currentDebtOf` at every write. Freezing the debt as
    ///      it stood when the recovery was recognised does not: it would over-mark by whatever the
    ///      callback repaid, inside the one frame where the permissionless `serviceQueue` is
    ///      reachable - which is audit round 15 arriving back through its own fix.
    ///
    ///      A real contract, not a prank. An EOA never receives `onERC1155Received`, and this repo
    ///      has twice been handed a passing proof that staged its state that way.
    function test_impairment_followsACallbackRepaymentInsideTheSeizeWindow() public {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION);

        uint256 debt = credit.currentDebtOf(alice);
        uint256 price = auction.currentPrice(id);
        assertLt(price, debt, "fixture: the fill must leave a shortfall for a cure to eat into");
        uint256 cure = (debt - price) / 2;
        assertGt(cure, 0, "fixture: the cure must be a real repayment");

        RepayingBidder attacker = new RepayingBidder(credit, pool, usdc, alice, cure);
        _fund(address(attacker), price);
        usdc.mint(address(attacker), cure);

        vm.prank(address(attacker));
        auction.bid(id);

        assertTrue(attacker.ran(), "the callback never fired, so this test proves nothing");
        assertEq(attacker.repaid(), cure, "the callback's own repayment did not land");
        assertEq(
            attacker.markDuringCallback(),
            debt - price - cure,
            "the mark must fall by every dollar the callback repaid, or it is an over-mark the callback can spend"
        );
    }

    /// @notice **A winning bidder cannot spend the standing over-mark on somebody else either.**
    /// @dev Audit round 15, executed three times independently by three agents. The test above
    ///      holds `auctionOf` set across the callback so the mark cannot be *released* early, and
    ///      that is still right. What nothing stopped was the callback *paying a third party* at
    ///      that mark: `LenderPool.serviceQueue` is permissionless, its `nonReentrant` is a
    ///      different contract's guard, and the attacker supplies the very fill that releases the
    ///      mark three statements later. Riskless, atomic, no price exposure.
    ///
    ///      **The damning part is the NAV this runs at.** `_navFloorShortOfDebt()` is the band
    ///      where the fill clears the loan outright, so `lifetimeSocialisedLoss` ends at zero: the
    ///      queued lender is crystallised at a discount for a default that never happens, and the
    ///      difference is shared out among everyone who stayed. Measured in that round at victim
    ///      -157.187500, attacker +52.395833, uninvolved holder +104.791666, summing to the wei.
    ///
    ///      The attacker must be a real contract. An EOA prank cannot reach `onERC1155Received`,
    ///      and this repo has twice been given a passing proof-of-concept that staged its state
    ///      that way.
    ///
    ///      **The assertion is about the victim, not about the attacker's profit.** Whether the
    ///      difference lands on an attacker or on an uninvolved holder is a question about who
    ///      benefits; that a lender was paid below what their shares were worth, on a liquidation
    ///      that lost nothing, is the defect either way. Asserting the payout would also have made
    ///      this pass against a fix that merely redistributed the take.
    function test_impairment_aWinningBidderCannotSpendTheOverMarkOnAQueuedLender() public {
        address victim = makeAddr("victim");
        _lend(victim, 4_000e6);

        uint256 id = _openAuctionAt(_navFloorShortOfDebt());
        _assertMarked("queue-servicing callback attack");

        uint256 victimShares = pool.balanceOf(victim);
        vm.prank(victim);
        pool.requestWithdrawal(victimShares, victim);

        // What the entry is worth on the un-impaired book at the instant before the fill. The
        // liquidation is about to recover in full, so this is what the victim should receive.
        uint256 worthBefore = pool.convertToAssets(victimShares);
        assertGt(worthBefore, 0, "fixture: the victim must have something to lose");

        uint256 price = auction.currentPrice(id);
        assertGt(price, credit.currentDebtOf(alice), "fixture: this fill must clear the debt");

        QueueServicingBidder attacker = new QueueServicingBidder(pool);
        _fund(address(attacker), price);
        vm.prank(address(attacker));
        auction.bid(id);

        assertTrue(attacker.ran(), "the callback never fired, so this test proves nothing");
        assertGt(attacker.serviced(), 0, "the queue was never serviced from inside the callback");
        assertEq(pool.lifetimeSocialisedLoss(), 0, "fixture: this liquidation must lose nothing at all");

        // One asset-wei of tolerance for the floor in `_exitToAssets`, and no more.
        assertGe(
            pool.claimable(victim) + 1,
            worthBefore,
            "a queued lender was paid below their shares' worth for a default that never happened"
        );
    }

    function _exitByFillCoveringTheDebt() private {
        uint256 id = _openAuctionAt(_navFloorShortOfDebt());
        _assertMarked("fill above the debt");

        uint256 price = auction.currentPrice(id);
        assertGt(price, credit.currentDebtOf(alice), "fixture: this fill must clear the debt");
        _fund(bidder, price);
        vm.prank(bidder);
        auction.bid(id);
    }

    /// @dev The case the design doc got wrong. Its transition table says a bid covering the debt
    ///      already notifies the manager through `creditLiquidationProceeds` - it does not, because
    ///      that call is skipped entirely when there is no penalty and no surplus to hand over, and
    ///      a fill landing exactly on the debt is precisely that state.
    function _exitByFillAtExactlyTheDebt() private {
        uint256 id = _openAuctionAt(_debtParityNav());
        _assertMarked("fill exactly at the debt");

        uint256 price = auction.currentPrice(id);
        assertEq(price, credit.currentDebtOf(alice), "fixture: the fill must land exactly on the debt");
        _fund(bidder, price);
        vm.prank(bidder);
        auction.bid(id);
    }

    function _exitByFillShortOfTheDebt() private {
        uint256 id = _openAuctionAt(_crashedNav());
        _assertMarked("fill short of the debt");

        uint256 price = auction.currentPrice(id);
        assertLt(price, credit.currentDebtOf(alice), "fixture: this fill must leave a shortfall");
        _fund(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        assertGt(pool.lifetimeSocialisedLoss(), 0, "the real loss still has to land on the share price");
    }

    function _exitByCancel() private {
        uint256 id = _openAuctionAt(_crashedNav());
        _assertMarked("cancel");

        oracle.setNav(NAV); // the position heals
        auction.cancel(id);
    }

    /// @dev The debt is cleared with `repayFor` rather than with `workoutSettle`, and the choice is
    ///      the whole value of this scenario. `workoutSettle` refreshes on its own, so a clean close
    ///      routed through it would pass with `closeWorkout`'s own notification deleted - it would
    ///      be a test of the previous line. `repayFor` is permissionless, does not touch
    ///      `recovered`, and tells nothing in this protocol that a mark can come off, so the release
    ///      here can only have come from `closeWorkout`.
    function _exitByCleanWorkout() private {
        uint256 id = _openAuctionAt(_crashedNav());
        _assertMarked("workout closed clean");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        uint256 owed = credit.currentDebtOf(alice);
        usdc.mint(payer, owed);
        vm.startPrank(payer);
        usdc.approve(address(credit), owed);
        credit.repayFor(alice, owed);
        vm.stopPrank();

        assertEq(credit.currentDebtOf(alice), 0, "fixture: the workout must close with nothing owed");

        // **The repayment itself releases the mark, and audit round 13 is why this line changed.**
        // It used to assert the mark was still standing here, waiting for `closeWorkout` to clear
        // it - which is precisely the defect two agents reported: `repayFor` is permissionless, so
        // a stranger could cure a liquidated borrower's debt and leave the pool reserving all of it
        // until somebody got round to closing the workout, with `serviceQueue` free to settle a
        // queued lender against that phantom shortfall in the meantime.
        _assertReleased("workout closed clean, cured by the repayment");

        auction.closeWorkout(id);
    }

    function _exitByForcedWorkout() private {
        uint256 id = _openAuctionAt(_crashedNav());
        _assertMarked("workout closed by force");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        skip(Config.WORKOUT_MAX_DURATION);
        auction.closeWorkout(id);

        assertGt(pool.lifetimeSocialisedLoss(), 0, "a forced close still recognises the loss");
    }

    // ── sizing ───────────────────────────────────────────────────────────────

    /// @notice The mark lands in the same transaction as the liquidation, not when it resolves.
    /// @dev That is the entire point of impairment pricing over the exit gate it replaces. The gate
    ///      froze exits for six hours because the price was wrong; this makes the price right, so
    ///      there is nothing to freeze and nothing for a lender to run from.
    function test_impairment_isSetTheMomentTheAuctionOpens() public {
        uint256 shares = pool.balanceOf(lender);
        uint256 entryBefore = pool.convertToAssets(shares);
        uint256 exitBefore = pool.previewRedeem(shares);
        assertEq(exitBefore, entryBefore, "fixture: nothing is marked before the liquidation");

        _openAuctionAt(_crashedNav());

        // The whole debt, not `debt - floorProceeds`. See `_impairmentFor`: crediting a recovery
        // nobody has been paid yet made the reserve a function of the clock, and it read as zero
        // for the entire ordinary LTV band. A liquidation in progress reserves what is owed, and
        // the recovery is recognised when it lands.
        assertEq(pool.impairmentOf(alice), _maxBorrowAtCeiling(), "a live auction reserves the whole debt");
        assertEq(pool.totalImpairment(), _maxBorrowAtCeiling());
        assertEq(pool.exitReserve(), _maxBorrowAtCeiling(), "no insurance in front of it, and inside the exposure");

        // The asymmetry that is the whole mechanism, and Maple's: the leaver carries the expected
        // loss, the entrant does not, so nobody can buy the discount and sell the release.
        assertLt(pool.previewRedeem(shares), exitBefore, "a leaver must already carry the expected loss");
        assertEq(pool.convertToAssets(shares), entryBefore, "an entrant must not be offered the discount");
    }

    /// @notice **The ordinary liquidation is marked.** Audit round 12: it was not.
    /// @dev Every other scenario in this file drives from a NAV below `_floorParityNav()`, and
    ///      `_assertMarked` requires a non-zero mark - so between them they excluded the failing
    ///      band by construction and the suite reported twelve green tests over a dormant
    ///      mechanism. This is the case they were all missing.
    ///
    ///      At the worst LTV a position can first become liquidatable at, the auction floor covers
    ///      the debt with 1,245 bps to spare. Under `debt - floorProceeds` that is a mark of
    ///      exactly zero: a lender could leave at the full pre-liquidation price while a
    ///      liquidation was already open against the book, which is the recognition gap the whole
    ///      mechanism exists to close.
    ///
    ///      The assertion is deliberately the *full debt* rather than merely non-zero. "Something
    ///      was marked" would pass against any optimistic recovery estimate, and an estimate is
    ///      what round 12 took apart.
    function test_impairment_marksTheOrdinaryLiquidationNotJustTheCatastrophicOne() public {
        // The premise, asserted rather than assumed: this NAV really is in the band where a floor
        // fill clears the loan outright. If the parameters ever move so that it is not, this test
        // stops testing what it says and says so instead of passing quietly.
        assertGt(
            _ordinaryTriggerNav(), _floorParityNav(), "fixture: this NAV must sit above floor parity"
        );

        uint256 shares = pool.balanceOf(lender);
        uint256 exitBefore = pool.previewRedeem(shares);

        _openAuctionAt(_ordinaryTriggerNav());

        assertGe(
            _floorPrice(_ordinaryTriggerNav()),
            _maxBorrowAtCeiling(),
            "fixture: the floor must cover the debt here, or this is not the dormant case"
        );
        assertEq(pool.impairmentOf(alice), _maxBorrowAtCeiling(), "a live auction reserves the whole debt");
        assertLt(pool.previewRedeem(shares), exitBefore, "and a leaver carries it");
    }

    /// @notice A workout is sized at the whole debt, and so is the auction it came from - so the
    ///         transition moves nothing.
    /// @dev **This used to assert an escalation, and the escalation was the bug.** A mark that
    ///      steps up at `expireToWorkout` is a mark that was too low before it, and the gap was
    ///      taken by whoever left in between: a lapse writes no storage, so the stored figure sat
    ///      at the pre-lapse number until somebody sent a transaction, and round 12 traced $2,500
    ///      out of a lender who stayed.
    ///
    ///      Flat across the transition is the property now, and it is the stronger claim: there is
    ///      no window in which the reserve is stale, because there is no step for it to be stale
    ///      before.
    ///
    ///      **This test is named for a transition it only half enters, and audit round 17 caught
    ///      that.** Its fixture streams no yield, so the settle inside `reassign` finds nothing to
    ///      apply, `reduced` is zero, and the impairment refresh that audit round 16 added to
    ///      `_settle` never runs. Every assertion below passed identically on the tree before that
    ///      refresh existed and on the tree after it, which is the definition of not testing it.
    ///      The end-state property is still worth pinning and is left here unchanged; the branch
    ///      this fixture cannot reach is covered by
    ///      `test_impairment_doesNotDipThroughZeroInsideExpiryToWorkout` below, which is the test
    ///      to read if you are changing the ordering inside `expireToWorkout`.
    function test_impairment_isFlatAcrossExpiryToWorkout() public {
        uint256 id = _openAuctionAt(_crashedNav());
        uint256 whileLive = pool.impairmentOf(alice);
        assertEq(whileLive, _maxBorrowAtCeiling(), "fixture: a live auction already reserves the whole debt");

        // The lapse itself, before anyone acts on it. This is the window that used to leak.
        skip(Config.AUCTION_DURATION + 1);
        assertEq(pool.impairmentOf(alice), whileLive, "a lapse must not change what is reserved");

        auction.expireToWorkout(id);

        assertEq(pool.impairmentOf(alice), _maxBorrowAtCeiling(), "an open workout assumes zero recovery");
        assertEq(pool.impairmentOf(alice), whileLive, "and the transition into it moves nothing");
    }

    /// @notice The mark is never released part-way through `expireToWorkout`, even when the settle
    ///         inside `reassign` moves the debt.
    /// @dev **Audit round 17, and the end-state twin above cannot see it.** `expireToWorkout` used
    ///      to `delete auctionOf[borrower]` before calling `_vault.reassign`, and `reassign`
    ///      settles the position, which reaches `CreditManager._settle`, which refreshes the mark
    ///      whenever the settle moved the debt. In that window the borrower had neither an auction
    ///      nor a workout, so `_impairmentFor` answered zero and the *whole* mark was released and
    ///      then re-taken by the trailing refresh a few statements later.
    ///
    ///      End state identical both ways, which is why nineteen integration tests and the
    ///      similarly-named test above all passed on the broken tree. The defect is only visible as
    ///      a transient, so this asserts on the log rather than on storage.
    ///
    ///      Two things made it worth fixing rather than filing. The trailing refresh is
    ///      deliberately failable - `_refreshImpairment` swallows a reverting pool so the exit of
    ///      last resort cannot be blocked - and the release **inverted the direction that failure
    ///      lands in**, from a stale-high mark to no mark at all. And a stale-high mark over-prices
    ///      the reserve, which is safe for the lenders who stay; a zero mark under-prices it, which
    ///      is the round-15 extraction handed back.
    ///
    ///      `_streamYieldToAlice` is the whole fixture. Without it `reduced` is zero and the branch
    ///      does not execute - see the note on the test above.
    function test_impairment_doesNotDipThroughZeroInsideExpiryToWorkout() public {
        uint256 id = _openAuctionAt(_crashedNav());
        _assertMarked("before the expiry");

        // The debt has to actually move inside `reassign`, or the refresh this test is about never
        // fires. Deliberately unsettled, so the settle nested in `reassign` is the one that applies
        // it - which is exactly the call ordering the defect lived in.
        _streamYieldToAlice(_maxBorrowAtCeiling() / 2);
        skip(Config.AUCTION_DURATION + 1);

        vm.recordLogs();
        auction.expireToWorkout(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 releases;
        uint256 settlesThatMovedTheDebt;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILenderPool.ImpairmentReleased.selector) releases++;
            if (logs[i].topics[0] == ICreditManager.YieldApplied.selector) settlesThatMovedTheDebt++;
        }

        // The reachability tripwire. If the fixture ever stops streaming yield, `reduced` goes to
        // zero, the refresh never runs and a broken ordering would pass this test in silence.
        assertGt(settlesThatMovedTheDebt, 0, "fixture: the nested settle has to move the debt");
        assertEq(releases, 0, "the mark must not be released part-way through the exit");

        assertEq(
            pool.impairmentOf(alice),
            credit.currentDebtOf(alice),
            "and an open workout is still sized at the whole remaining debt"
        );
    }

    /// @notice A position that heals under a lapsed auction, past the re-strike deadline, is
    ///         released by ONE permissionless call - and that call is the documented exit.
    /// @dev **Audit round 20's headline, and it is not an attack.** `Config.AUCTION_RESET_WINDOW`
    ///      bounds the re-strike, not the mark: `_impairmentFor` keys the mark on
    ///      `auctionOf[borrower] != 0`, and nothing deletes `auctionOf` on a lapse. Four routes
    ///      reach the healed-and-lapsed state with no adversary at all - a permissionless
    ///      `repayFor`, the borrower depositing collateral to save their own position, the yield
    ///      stream writing the debt down with no transaction naming the borrower, and a
    ///      `liquidationThresholdBps` raise.
    ///
    ///      Measured on the tree before the fix, at every one of those four routes: `exitReserve`
    ///      unchanged at +365 days, `expireToWorkout` reverting `PositionNotLiquidatable`,
    ///      `refreshImpairments` - the remedy `QueueHeldByReserve` sends a reader to - reporting
    ///      **0**, `openWorkoutCount` **0** so no forced-close clock was ever armed, `borrow`
    ///      refusing with `LiquidationOpen`, `vault.setCreditManager` refusing with
    ///      `AuctionHasLiveWork`, and `withdrawBonds` refusing the collateral that did the healing.
    ///      `cancel` cleared all of it and paid its caller **zero**.
    ///
    ///      So the fix is not a new transition: it is making the exit that is already documented as
    ///      "the exit of last resort" actually reach the state it was written for. The mark-side
    ///      alternative was measured and refused - see the note on this test's twin below.
    function test_impairment_isReleasedByTheDocumentedExitAfterAHealAndALapse() public {
        uint256 id = _openAuctionAt(_ordinaryTriggerNav());
        uint256 markWhileLive = pool.impairmentOf(alice);
        assertGt(markWhileLive, 0, "fixture: a live auction reserves the debt");

        // Past the auction and past the re-strike deadline, so `liquidate` can no longer produce a
        // correctly-priced replacement. This is the state with one legal move in it.
        vm.warp(auction.firstOpenedAt(id) + Config.AUCTION_RESET_WINDOW + 1);

        // The heal, by the route that needs neither an adversary nor a privileged call.
        uint256 cure = credit.currentDebtOf(alice) / 2;
        _fund(stranger, cure);
        vm.startPrank(stranger);
        usdc.approve(address(credit), cure);
        credit.repayFor(alice, cure);
        vm.stopPrank();

        // The premise, asserted both ways so the test cannot go vacuous by self-healing to zero:
        // a live loan that is no longer liquidatable.
        assertGt(credit.currentDebtOf(alice), 0, "premise: the loan must still be live");
        assertGt(credit.healthFactor(alice), Config.HEALTH_FACTOR_SCALE, "premise: and no longer liquidatable");
        assertGt(pool.exitReserve(), 0, "premise: and the mark must still be standing");

        // A queued lender, so the release is observable as the thing that actually hurts.
        uint256 shares = pool.balanceOf(lender);
        vm.prank(lender);
        pool.requestWithdrawal(shares, lender);
        vm.expectRevert();
        pool.serviceQueue(5);

        // ONE call, by anyone, with no capital.
        uint256 before = usdc.balanceOf(stranger);
        vm.prank(stranger);
        auction.expireToWorkout(id);

        assertEq(pool.exitReserve(), 0, "the mark must be released");
        assertEq(pool.impairmentOf(alice), 0, "and the borrower's slot with it");
        assertEq(auction.auctionOf(alice), 0, "the auction pointer must return to zero");
        assertEq(auction.liveAuctionCount(), 0, "and the live register with it");
        assertEq(auction.openWorkoutCount(), 0, "a healed position must not be pushed into a workout");
        assertEq(usdc.balanceOf(stranger), before, "round 18: resolving a heal pays its caller nothing");

        // The queue moves again, over the idle cash it was held off.
        assertGt(pool.serviceQueue(5), 0, "the queue must reopen");
        assertGt(pool.claimable(lender), 0, "and the lender must actually be paid");
    }

    /// @notice A tranche of recovery shrinks the mark, and `workoutSettle` is the only call site
    ///         that does it.
    /// @dev It is not a terminal transition, so a call-site set enumerated from "how does an
    ///      auction end" misses it - and the mark would then stay at the whole debt while DexFi had
    ///      already paid part of it back, over-marking every lender who left afterwards.
    function test_impairment_shrinksAsAWorkoutRecovers() public {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(pool.impairmentOf(alice), _maxBorrowAtCeiling());

        uint256 tranche = _maxBorrowAtCeiling() / 4;
        _fund(payer, tranche);
        vm.prank(payer);
        auction.workoutSettle(id, tranche);

        assertEq(pool.impairmentOf(alice), _maxBorrowAtCeiling() - tranche, "recovery paid is recovery marked");
        assertEq(pool.impairmentOf(alice), credit.currentDebtOf(alice), "and it tracks the debt that is left");
    }

    /// @notice Audit round 21, finding 14: a tranche that lands after the forced close becomes an
    ///         active pool recovery stream, rather than a future defaulter's insurance fund.
    /// @dev **This file is where that sentence can be measured at all.** `LiquidationAuction.t.sol`
    ///      funds its book from the treasury, so it can show the *funder* being repaid and nothing
    ///      about a share price. Here the real pool is both the liquidity source and the loss sink,
    ///      so `socialiseLoss` actually bites and the recovery has a lender to reach.
    ///
    ///      **The money arrives at once and the share price moves over the stream, not in the
    ///      recovery's own block.** `workoutSettleAfterClose` is permissionless, so an instant step
    ///      would be capturable by whoever enters and picks the block. Round 10's finding 6 is why
    ///      `LenderPool.recoverLoss` uses the same rating rules
    ///      `repayPrincipal`'s surplus branch uses. So this measures the pool's cash first and the
    ///      share price after the stream, rather than asserting a jump.
    ///
    ///      The stream belongs to the shares present when the tranche is delivered. It does not
    ///      reconstruct which accounts historically bore the write-down; share transfers and
    ///      exits between those events make that provenance unavailable.
    function test_H_fix_theLateTrancheBecomesAnActivePoolRecoveryStream() public {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        uint256 loan = _maxBorrowAtCeiling();
        assertEq(pool.outstandingPrincipal(), loan, "premise: the pool funded this loan");
        uint256 assetsBeforeTheDefault = pool.totalAssets();

        skip(Config.WORKOUT_MAX_DURATION);
        vm.prank(stranger); // permissionless: nobody with a stake picks this moment
        auction.closeWorkout(id);

        assertEq(pool.lifetimeSocialisedLoss(), loan, "the lenders took the whole loan");
        assertEq(pool.totalAssets(), assetsBeforeTheDefault - loan, "and their share price says so");

        // The redemption comes good the next day, for most of it.
        skip(1 days);
        uint256 tranche = 400e6;
        _fund(payer, tranche);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, tranche);

        emit log_named_uint(
            "MEASURED pool cash gained by a tranche after the forced close",
            usdc.balanceOf(address(pool)) - poolCashBefore
        );
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, tranche, "the money is in the pool, not in insurance");
        assertEq(credit.insuranceFund(), 0, "and not parked where only a future default reaches it");
        assertEq(pool.lifetimeLossRecovered(), tranche, "recorded beside the loss rather than netted into it");
        assertEq(pool.lifetimeSocialisedLoss(), loan, "which stays exactly what the lenders took");

        // The share price picks it up over the stream, which is deliberate. The window is at least
        // as long as the pot took to accrue - here the whole workout - so it is read back rather
        // than assumed: skipping one `YIELD_STREAM_DURATION` releases only part of it.
        assertEq(pool.totalAssets(), assetsBeforeTheDefault - loan, "not in the recovery's own block");
        vm.warp(pool.yieldStreamEndsAt() + 1);
        emit log_named_uint(
            "MEASURED lender assets recovered once the stream has run",
            pool.totalAssets() - (assetsBeforeTheDefault - loan)
        );
        assertEq(pool.totalAssets(), assetsBeforeTheDefault - loan + tranche, "and in full once it has run");
    }

    /// @notice The same recovery with **another loan still on the books**, which is where the first
    ///         version of this fix quietly stopped working.
    /// @dev **This test is here because a measurement refuted the obvious routing.** Booking the
    ///      late tranche into `pendingPrincipal` and letting the permissionless `settlePrincipal`
    ///      carry it home reads like the smallest possible change, and it is wrong twice over.
    ///      `LenderPool.repayPrincipal` nets a repayment against `outstandingPrincipal`, which
    ///      `socialiseLoss` has already written down - so with a surviving loan the share-price
    ///      gain measured **0** in the recovery's block and only appeared when that loan repaid.
    ///      And `LiquidationAuction.invariants.t.sol`'s `invariant_theBooksAgreeOnWhatIsOwed` went
    ///      red on it: `outstandingPrincipal == pendingPrincipal + totalDebt` fails the moment this
    ///      manager owes the pool money it never lent. The invariant found it, not this test.
    ///
    ///      `recoverLoss` books it as what it is instead - a gain on an already-written-off asset -
    ///      so the surviving loan is irrelevant and the identity never moves.
    function test_H_fix_theRecoveryIsNotNettedAgainstASurvivingLoan() public {
        uint256 loan = _maxBorrowAtCeiling();

        // A second borrower, so the pool still has exposure when the recovery lands.
        address bob = makeAddr("bob");
        bond.mint(bob, 1_000);
        vm.startPrank(bob);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        credit.borrow(loan);
        vm.stopPrank();

        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);
        vm.prank(stranger);
        auction.closeWorkout(id);

        uint256 assetsAfterTheLoss = pool.totalAssets();
        assertEq(pool.outstandingPrincipal(), loan, "premise: bob's loan is still out");

        uint256 tranche = 400e6;
        _fund(payer, tranche);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, tranche);
        vm.warp(pool.yieldStreamEndsAt() + 1);

        emit log_named_uint(
            "MEASURED share-price gain with a surviving loan on the books",
            pool.totalAssets() - assetsAfterTheLoss
        );
        assertEq(pool.totalAssets(), assetsAfterTheLoss + tranche, "recognised in full, not deferred");
        assertEq(pool.outstandingPrincipal(), loan, "and no loan was re-recognised or written off to pay for it");
        assertEq(
            pool.outstandingPrincipal(),
            credit.pendingPrincipal() + credit.totalDebt(),
            "the identity the first routing broke"
        );
    }

    /// @notice Superseding a lapsed auction cannot move the mark, however the caller times it.
    /// @dev **This test used to assert the opposite, and the thing it asserted was an attack.**
    ///      The mark was re-derived against the replacement auction's floor, priced off whatever
    ///      NAV was live in the block the caller chose. `liquidate` is permissionless and a lapsed
    ///      auction can be superseded every six hours, so a lender about to leave could wait for an
    ///      uptick, supersede, shrink their own markdown and redeem into the improvement - and do
    ///      it again indefinitely, which also defers `expireToWorkout` for as long as they like.
    ///      The old test read that as correct behaviour and pinned it with two event assertions.
    ///
    ///      The property now is that a NAV recovery mid-liquidation buys the caller nothing,
    ///      because the reserve is a fact about the debt rather than a forecast about the
    ///      collateral. The recovery reaches lenders when a bid actually pays it in.
    ///
    ///      The supersede transition still has to *happen* - it is a fifth way an auction ends and
    ///      the design doc omits it entirely - so that is asserted through storage, separately from
    ///      the mark.
    function test_impairment_isUnmovedByASupersedeAtARecoveredNav() public {
        uint256 first = _openAuctionAt(_crashedNav());
        uint256 before = pool.impairmentOf(alice);
        assertEq(before, _maxBorrowAtCeiling(), "fixture: the crashed auction reserves the whole debt");

        // Lapse it, then let NAV recover most of the way back. Under the old formula this is
        // precisely the moment worth choosing: still liquidatable, but a floor fill now loses far
        // less, so superseding here shrank the mark.
        skip(Config.AUCTION_DURATION + 1);
        oracle.setNav(_navFloorShortOfDebt());
        assertGt(
            _floorPrice(_navFloorShortOfDebt()),
            _floorPrice(_crashedNav()),
            "fixture: the replacement must genuinely be better collateralised, or there is no lever to pull"
        );

        vm.prank(stranger); // permissionless, and not the keeper
        credit.liquidate(alice);

        uint256 second = auction.auctionOf(alice);
        // **Audit round 19 inverted the mechanism and left the property alone.** This used to assert
        // a fresh id and a settled predecessor; the lapsed auction is now re-struck in place, which
        // is what stops the parked bounty being re-assigned to whoever re-struck it. What the test
        // is actually about - that a caller who picks their moment cannot move the mark - is
        // unchanged, and is asserted below exactly as before.
        assertEq(second, first, "the lapsed auction was re-struck, not replaced");
        (,,, bool settled,,,,) = auction.auctions(first);
        assertFalse(settled, "and it was never settled, so there was nothing to unwind");

        assertEq(pool.impairmentOf(alice), before, "a caller-timed re-strike must not restate the reserve");
        assertEq(pool.impairmentOf(alice), credit.currentDebtOf(alice), "it tracks the debt, not the collateral");
    }

    // ── the mark does not move with the price ────────────────────────────────

    /// @notice No NAV move, in either direction, changes what a live liquidation reserves.
    /// @dev **The three `floorProceeds` tests that used to sit here are gone with the view itself.**
    ///      They asserted that the bound was priced off the auction's frozen `startNav` rather than
    ///      live NAV, which was the right defence for the wrong design: it stopped a caller timing
    ///      the *price* input while leaving the mark a function of the clock in four other ways.
    ///      The property they were protecting survives here, and it is now unconditional rather
    ///      than a consequence of which NAV was read.
    ///
    ///      `refreshImpairment` is permissionless, so a lender about to leave picks the block. The
    ///      test drives the two moves worth choosing: a large recovery, which under the old formula
    ///      shrank the mark, and a further crash.
    function test_impairment_isUnmovedByAnyNavMoveMidAuction() public {
        _openAuctionAt(_crashedNav());
        uint256 marked = pool.impairmentOf(alice);
        assertEq(marked, _maxBorrowAtCeiling(), "fixture: the whole debt is reserved");

        // An eightfold "recovery" posted mid-auction: the move a leaver would want.
        oracle.setNav(NAV);
        vm.prank(stranger);
        credit.refreshImpairment(alice);
        assertEq(pool.impairmentOf(alice), marked, "a recovery must not shrink the mark before it is realised");

        // And the other way, which must not inflate it past the debt either.
        oracle.setNav(_crashedNav() / 4);
        vm.prank(stranger);
        credit.refreshImpairment(alice);
        assertEq(pool.impairmentOf(alice), marked, "nor may a further crash raise it above what is owed");
    }

    /// @notice A lapse changes nothing, with or without a transaction to notice it.
    /// @dev Round 12's second costume: `floorProceeds` fell to zero at `startedAt +
    ///      AUCTION_DURATION`, so the correct mark escalated on the clock while the stored one sat
    ///      at the pre-lapse figure until somebody sent a transaction. In the ordinary LTV band
    ///      that pre-lapse figure was zero, and $2,500 was traced out of a lender who stayed.
    ///
    ///      Both halves are asserted deliberately: the stored mark across the boundary with nobody
    ///      acting, and then the same mark after a refresh. If those two ever disagree, the reserve
    ///      has become a function of the clock again.
    function test_impairment_isUnchangedByALapseWithOrWithoutARefresh() public {
        uint256 id = _openAuctionAt(_crashedNav());
        uint256 marked = pool.impairmentOf(alice);

        skip(Config.AUCTION_DURATION + 1);

        // The auction really is lapsed: bids are refused and the quote view says so.
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionLapsed.selector, id));
        auction.currentPrice(id);

        assertEq(pool.impairmentOf(alice), marked, "the stored mark must not drift across the boundary");

        vm.prank(stranger);
        credit.refreshImpairment(alice);
        assertEq(pool.impairmentOf(alice), marked, "and a refresh must find nothing to correct");
    }

    // ── the properties the try/catch and the permissionless call exist for ────

    /// @notice A fill landing exactly on the debt still releases the mark.
    /// @dev `_creditProceeds` returns early when there is neither a penalty nor a surplus to hand
    ///      over, so this is a complete, successful liquidation in which the manager is told
    ///      nothing by any pre-existing path. Without the notification at the end of `_bid` the
    ///      reserve would sit on every lender's exit price for good, over a loan that was repaid in
    ///      full.
    function test_aFillAtExactlyTheDebtStillRefreshes() public {
        uint256 id = _openAuctionAt(_debtParityNav());
        uint256 debt = credit.currentDebtOf(alice);
        assertGt(pool.impairmentOf(alice), 0);

        uint256 price = auction.currentPrice(id);
        assertEq(price, debt, "fixture: the fill must land exactly on the debt");

        _fund(bidder, price);
        vm.prank(bidder);
        auction.bid(id);

        assertEq(credit.insuranceFund(), 0, "no penalty was charged, so nothing was credited");
        assertEq(credit.totalClaimable(), 0, "and no surplus either - this is the early-return case");
        assertEq(credit.currentDebtOf(alice), 0, "the loan was repaid in full");
        assertEq(pool.impairmentOf(alice), 0, "so nothing may be left reserved against it");
        assertEq(pool.totalImpairment(), 0);
    }

    /// @notice The auction's three exits survive a lender pool that reverts every call.
    /// @dev `expireToWorkout` promises this in writing, and the impairment notification is a new
    ///      outbound call on all three paths. A bare call would have put a fourth contract's revert
    ///      in front of the exit of last resort, which is worse than the stale mark it fixes -
    ///      permanently stranded collateral rather than a wrong price.
    function test_theThreeExitsSurviveALenderPoolThatRevertsEverything() public {
        uint256 clean = vm.snapshotState();

        // cancel
        uint256 id = _openAuctionAt(_crashedNav());
        oracle.setNav(NAV);
        _breakThePool();
        auction.cancel(id);
        (,,, bool settled,,,,) = auction.auctions(id);
        assertTrue(settled, "cancel must still close the auction");

        // A mocked call is not storage, so `revertToState` leaves it standing. Without this the
        // next scenario's borrow would revert inside the fixture rather than inside the code under
        // test, which is the failure that looks like a bug in the thing being proved.
        vm.revertToState(clean);
        vm.clearMockedCalls();
        clean = vm.snapshotState();

        // expireToWorkout
        id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        _breakThePool();
        auction.expireToWorkout(id);
        assertEq(auction.openWorkoutCount(), 1, "the exit of last resort must still open the workout");

        vm.revertToState(clean);
        vm.clearMockedCalls();

        // closeWorkout, forced, which is the path that also has to recognise a loss
        id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION);
        _breakThePool();
        auction.closeWorkout(id);

        assertEq(auction.openWorkoutCount(), 0, "the forced close must still complete");
        assertGt(credit.unsocialisedLoss(), 0, "and the loss it could not place must stay visible");
    }

    /// @notice A dropped notification leaves a stuck reserve, and anybody can clear it.
    /// @dev This is what earns the `try`/`catch`. The catch is what makes a dropped release
    ///      possible in the first place, so the recovery has to be reachable by someone with an
    ///      interest in it - which is every lender in the pool, not an operator.
    function test_refreshImpairment_recoversAStuckImpairment() public {
        uint256 id = _openAuctionAt(_crashedNav());
        uint256 marked = pool.impairmentOf(alice);
        assertGt(marked, 0);

        oracle.setNav(NAV); // the position heals, so cancel is the right exit

        // The manager refuses the notification. Nothing in the protocol can make this happen today,
        // which is exactly why it has to be forced: the `catch` is unreachable state until a future
        // manager or an out-of-gas call makes it reachable, and by then the recovery has to exist.
        vm.mockCallRevert(address(credit), ICreditManager.refreshImpairment.selector, "");

        vm.expectEmit(true, true, false, false, address(auction));
        emit LiquidationAuction.ImpairmentRefreshFailed(id, alice);
        auction.cancel(id);

        assertEq(auction.auctionOf(alice), 0, "the auction is gone");
        assertEq(pool.impairmentOf(alice), marked, "but the reserve it caused is stuck behind it");

        vm.clearMockedCalls();

        // Not the borrower, not the keeper, not the owner. Anybody.
        vm.prank(stranger);
        credit.refreshImpairment(alice);

        assertEq(pool.impairmentOf(alice), 0, "a stranger can put the exit price back");
        assertEq(pool.totalImpairment(), 0);
    }

    /// @dev Every call into the pool reverts from here on, including `socialiseLoss`, `impair`,
    ///      `releaseImpairment` and `setLossReserves`. An empty selector prefix matches all of them.

    // ── the loss sink and the funder are one economic role ───────────────────

    /// @notice The loss sink may not be pointed away from the balance sheet that funds the book.
    /// @dev Audit round 21, finding 5. `liquiditySource` and `lenderPool` are two independent
    ///      pointers naming one economic role - the balance sheet whose money is at risk - and only
    ///      `lenderPool` is consulted when the money is actually lost. `_socialise` charges a loss
    ///      only when the two agree and otherwise emits `LossBorneByTheSource` and banks **nothing**,
    ///      while `setLenderPool`'s principal clause is a snapshot at the instant of the swap: the
    ///      harm it names does not need principal out *at the swap*, it needs the outgoing pool to
    ///      be the funder *at all*, because the next borrow is one transaction away.
    ///
    ///      MEASURED on the shipped code before this guard existed: sink repointed on a flat book so
    ///      the guard passed, then one borrow and one short fill - the funding pool's
    ///      `previewRedeem(allShares)` read 20,000.000000 before and after, `lifetimeSocialisedLoss`
    ///      0, `unsocialisedLoss` 0 (not even deferred), and the second lender out ate 100% of a
    ///      314.375000 hole where pro-rata was 251.500000 / 62.875000. There was **no way back**:
    ///      `flushSocialisedLoss` reverts `NothingToSettle` because nothing was banked, and
    ///      `writeDownLoss` had already cleared `debtOf`.
    ///
    ///      Closed at the wiring layer rather than in `_socialise`, and that is the point. All five
    ///      sites that reach the pool - `_socialise`, `flushSocialisedLoss`, `_setImpairment`,
    ///      `_pushLossReserves` and `refreshImpairments` - read `lenderPool`, so a fix to the loss
    ///      leg alone would have left the impairment leg still marking a pool with no exposure and
    ///      **read like closure**. One invariant covers all five.
    function test_lossSink_cannotBePointedAwayFromAPoolThatFundsTheBook() public {
        LenderPool sink = new LenderPool(usdc, admin);
        vm.startPrank(admin);
        sink.setCreditManager(address(credit));
        sink.setEpochHarvester(harvester);
        vm.stopPrank();

        assertEq(credit.liquiditySource(), address(pool), "fixture: the funder is the depositor pool");
        assertEq(pool.outstandingPrincipal(), 0, "fixture: the book must be flat, so the old clause passes");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.LossSinkMustBeTheFunder.selector, address(pool), address(sink))
        );
        credit.setLenderPool(address(sink));

        assertEq(credit.lenderPool(), address(pool), "the sink moved anyway");
    }

    /// @notice The same refusal, driven all the way to the harm it prevents.
    /// @dev The hazard fixture: the exact sequence round 21 measured, run against the guard. If
    ///      the repoint were still accepted this test would reach the borrow and the fill, and the
    ///      funder's share price would be measured unmoved against a real hole. It cannot get past
    ///      line one, which is what makes the refusal attributable rather than incidental.
    function test_lossSink_divergenceCannotBeReachedSoTheHoleCannotBeHidden() public {
        LenderPool sink = new LenderPool(usdc, admin);
        vm.startPrank(admin);
        sink.setCreditManager(address(credit));
        sink.setEpochHarvester(harvester);
        vm.stopPrank();

        vm.prank(admin);
        try credit.setLenderPool(address(sink)) {
            // Only reachable on the pre-guard code. Everything below is the measurement.
            uint256 shares = pool.balanceOf(lender);
            uint256 priceBefore = pool.previewRedeem(shares);

            uint256 id = _openAuctionAt(_crashedNav());
            uint256 price = auction.currentPrice(id);
            _fund(bidder, price);
            vm.prank(bidder);
            auction.bid(id);
            credit.settlePrincipal();

            emit log_named_uint("HAZARD funder previewRedeem before", priceBefore);
            emit log_named_uint("HAZARD funder previewRedeem after ", pool.previewRedeem(shares));
            emit log_named_uint("HAZARD funder lifetimeSocialised  ", pool.lifetimeSocialisedLoss());
            emit log_named_uint("HAZARD manager unsocialisedLoss   ", credit.unsocialisedLoss());
            fail("the sink was repointed off the funder and the loss vanished");
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason),
                CreditManager.LossSinkMustBeTheFunder.selector,
                "refused, but not for the reason this test is about"
            );
        }
    }

    /// @notice CONTROL: the divergence the treasury era needs is still legal.
    /// @dev The deploy script ships the pool as the loss sink while a `TreasuryLiquiditySource`
    ///      still funds borrows, and that divergence is safe for a reason the guard has to be able
    ///      to see: a treasury has no `outstandingPrincipal` book and no `socialiseLoss`, so it
    ///      bears a default by simply never being repaid. The guard is keyed on whether the funder
    ///      is a pool at all, not on whether it happens to differ - so this case must still pass,
    ///      and `Deploy.t.sol` would be the loud failure if it did not.
    function test_lossSink_mayStillDivergeFromATreasuryFunder() public {
        TreasuryLiquiditySource treasury = new TreasuryLiquiditySource(usdc, admin);
        LenderPool sink = new LenderPool(usdc, admin);

        vm.startPrank(admin);
        treasury.setCreditManager(address(credit));
        sink.setCreditManager(address(credit));
        sink.setEpochHarvester(harvester);
        credit.setLiquiditySource(address(treasury));
        credit.setLenderPool(address(sink));
        vm.stopPrank();

        assertEq(credit.liquiditySource(), address(treasury), "the treasury must still be installable");
        assertEq(credit.lenderPool(), address(sink), "the sink must still be pointable while a treasury funds");
    }

    /// @notice The migration this guard must not deadlock: one pool to another, in one call.
    /// @dev **The deadlock question, asked out loud, because this repository has shipped three
    ///      mutually-unsatisfiable guards.** Refusing the sink-side move alone would leave
    ///      `setLiquiditySource` free to create the same divergence from the other end; refusing
    ///      both would make a pool-to-pool migration unreachable, since neither pointer could move
    ///      first. So the source setter *carries* the sink: pointing the funder at a new pool
    ///      repoints the loss sink with it, in the same transaction, after running every clause
    ///      `setLenderPool` would have run on the outgoing pool. There is no ordering to get wrong
    ///      because there is no ordering.
    function test_lossSink_followsTheFunderThroughAPoolToPoolMigration() public {
        LenderPool next = new LenderPool(usdc, admin);
        vm.startPrank(admin);
        next.setCreditManager(address(credit));
        next.setEpochHarvester(harvester);
        credit.setLiquiditySource(address(next));
        vm.stopPrank();

        assertEq(credit.liquiditySource(), address(next), "the funder did not move");
        assertEq(credit.lenderPool(), address(next), "the sink did not follow the funder");
    }

    /// @notice And the outgoing pool's own clauses still bind when the source setter carries it.
    /// @dev Otherwise the migration path would be a way to *skip* the two guards `setLenderPool`
    ///      spends sixty lines on - the round-16 impairment mirror and the round-11 principal
    ///      clause - by going in through the other door. Driven on the impairment clause because
    ///      that is the one round 16 found missing.
    ///
    ///      **The mark is mocked, and the reason is worth writing down.** Every natural way to put
    ///      a mark on the pool also puts debt on the manager, and `setLiquiditySource`'s own
    ///      `DebtOutstanding` clause fires three lines earlier - so the carried clause is
    ///      unreachable from an honest fixture and a test built on one would have proved nothing
    ///      while passing. Mocking the single read isolates it. Ordering noted rather than
    ///      simplified away: `DebtOutstanding` is the *stronger* clause on the converged wiring, and
    ///      the carried ones matter for the states it does not cover.
    function test_lossSink_migrationStillHonoursTheOutgoingPoolsClauses() public {
        LenderPool next = new LenderPool(usdc, admin);
        vm.startPrank(admin);
        next.setCreditManager(address(credit));
        vm.stopPrank();

        uint256 marked = 1_234e6;
        vm.mockCall(address(pool), abi.encodeWithSelector(ILenderPool.totalImpairment.selector), abi.encode(marked));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.PoolImpairmentOutstanding.selector, address(pool), marked)
        );
        credit.setLiquiditySource(address(next));
    }

    function _breakThePool() private {
        vm.mockCallRevert(address(pool), bytes(""), bytes(""));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 21, finding 4 - the auction's claim on the outgoing manager.
    //
    // **The hazard is built here before the fix is asserted**, because a refusal is only
    // attributable if the same call still reaches the same state without it.
    //
    // The shape: `claimableOf` is a `msg.sender`-scoped pot, and this protocol builds exactly one
    // claimant that is a *contract behind a moving pointer*. `LiquidationAuction` accrues the pot
    // while it holds a workout lot - staked, earning, no debt against it - and its only call site
    // for `claimSurplus` reads its own mutable `creditManager` slot. Repoint that slot and the
    // permission survives while its sole holder cannot exercise it. The auction is immutable and
    // vault detachment is one-way, so before this commit there was no later fix.
    //
    // **These live in this file rather than in one of their own on purpose.** They need this
    // fixture, and a test contract that subclassed it would silently re-run all 23 tests above -
    // which the repository's documentation check cannot see, because it counts test functions in source
    // and forge counts them as executed. Measured: the same eight tests in a subclass file made
    // `forge test` report 695 while the detector derived 673.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Drive a workout to the point where the auction holds the lot and has accrued yield as
    ///      `claimableOf[auction]`, then force the workout closed so a migration is legal at all.
    ///      Lifted from the round-21 PoC so the fixture is not re-invented here.
    function _workoutThenIdle(uint256 epochYield) internal returns (uint256 accrued) {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        assertEq(vault.bondCount(address(auction)), BONDS, "fixture: the lot did not move");

        _streamYieldTo(epochYield);
        credit.settle(address(auction));
        accrued = credit.claimableOf(address(auction));

        skip(Config.WORKOUT_MAX_DURATION + 1);
        auction.closeWorkout(id);
        assertEq(auction.openWorkoutCount(), 0, "fixture: workout still open");
        assertEq(auction.liveAuctionCount(), 0, "fixture: auction still live");
        assertEq(credit.totalDebt(), 0, "fixture: debt outstanding blocks the migration");
    }

    function _streamYieldTo(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(credit), amount);
        credit.receiveYield(amount);
        credit.distributeYield(amount);
        vm.stopPrank();
        skip(Config.YIELD_STREAM_DURATION);
        credit.accrueYield();
    }

    function _freshManager() internal returns (CreditManager) {
        return new CreditManager(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
    }

    /// @dev The ordinary migration, in the order that loses the money: repoint, then sweep.
    function _migrate() internal returns (CreditManager incoming) {
        incoming = _freshManager();
        vm.startPrank(admin);
        vault.setCreditManager(address(incoming));
        auction.setCreditManager(address(incoming));
        incoming.setLiquidationAuction(address(auction));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The hazard, unchanged by the fix: nothing about the *ordering* got safer.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The strand still forms. The fix does not stop the pointer moving early - it makes
    ///         the money reachable afterwards, which is a different claim and worth separating.
    function test_theStrandStillFormsOnTheLosingOrder() public {
        uint256 accrued = _workoutThenIdle(400e6);
        assertGt(accrued, 0, "fixture: nothing accrued, the test would prove nothing");

        _migrate();

        // The claim is recorded against the outgoing manager and the auction's own call site now
        // asks the incoming one, which owes it nothing.
        assertEq(credit.claimableOf(address(auction)), accrued, "the claim vanished rather than stranded");
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        auction.sweepWorkoutYieldToInsurance();

        // And the migration sweep will not take it, because it is inside `spokenFor`.
        vm.prank(admin);
        credit.migrateReserves();
        assertEq(credit.claimableOf(address(auction)), accrued, "migrateReserves moved it after all");
        assertGe(usdc.balanceOf(address(credit)), accrued, "the USDC is still sitting on the outgoing manager");

        // There is no way back either: the vault refuses to re-attach a used manager.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.CreditManagerNotVirgin.selector, address(credit)));
        vault.setCreditManager(address(credit));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The fix: the pair makes it reachable in any order.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The losing order, recovered by two permissionless calls from an address with no
    ///         role at all - and the value lands where the winning order would have put it.
    function test_theStrandIsRecoverableAfterTheRepoint() public {
        uint256 accrued = _workoutThenIdle(400e6);
        CreditManager incoming = _migrate();
        vm.prank(admin);
        credit.migrateReserves();

        uint256 insuranceBefore = incoming.insuranceFund();

        // Leg one: anybody can push the outgoing manager's claim to the auction. Detached, and it
        // still works - `claimSurplus` was always open through a migration; what was missing was
        // a caller.
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(credit.claimableOf(address(auction)), 0, "leg one did not clear the claim");
        assertEq(usdc.balanceOf(address(auction)), accrued, "leg one did not deliver to the auction");

        // Leg two: anybody can move what the auction is not holding for a reward claimant into
        // the live manager's insurance fund.
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        assertEq(usdc.balanceOf(address(auction)), 0, "leg two left value on an immutable contract");
        assertEq(incoming.insuranceFund() - insuranceBefore, accrued, "leg two did not reach insurance");
    }

    /// @notice The same two legs work on the *winning* order too, which is what makes this a fix
    ///         rather than a second undocumented ordering constraint.
    function test_theClaimIsCollectableBeforeTheRepointAsWell() public {
        uint256 accrued = _workoutThenIdle(400e6);

        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(usdc.balanceOf(address(auction)), accrued, "the live manager refused the same call");

        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        assertGe(credit.insuranceFund(), accrued, "it did not reach the still-attached manager");

        // And the migration then carries it, exactly as the control did.
        CreditManager incoming = _migrate();
        vm.prank(admin);
        credit.migrateReserves();
        assertGe(incoming.insuranceFund(), accrued, "the value did not survive the migration");
    }

    /// @notice The destination is not chooseable. The caller decides only whether the money moves.
    function test_claimSurplusFor_paysTheClaimantAndNobodyElse() public {
        _workoutThenIdle(400e6);
        uint256 strangerBefore = usdc.balanceOf(stranger);

        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));

        assertEq(usdc.balanceOf(stranger), strangerBefore, "the caller took a cut");
        assertGt(usdc.balanceOf(address(auction)), 0, "the claimant was not paid");
    }

    /// @notice It reverts at zero rather than reporting success, so a caller is never told a
    ///         strand was cleared when nothing moved.
    function test_claimSurplusFor_revertsWithNothingOwed() public {
        vm.expectRevert(CreditManager.NothingToClaim.selector);
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));

        vm.expectRevert(CreditManager.ZeroAddress.selector);
        vm.prank(stranger);
        credit.claimSurplusFor(address(0));
    }

    /// @notice The sweep is bounded by `totalUnclaimedRewards`, so it cannot take a liquidation
    ///         caller's unclaimed reward and hand it to the insurance fund.
    /// @dev **This is the assertion that would go red if the bound were dropped for a raw
    ///      `balanceOf`**, which is the obvious simplification of `sweepFreeBalanceToInsurance`.
    function test_sweepFreeBalance_cannotTakeAnUnclaimedReward() public {
        // An ordinary liquidation that fills, so `keeper` is owed a reward that is still here.
        uint256 id = _openAuctionAt(_navFloorShortOfDebt());
        skip(Config.AUCTION_DURATION / 2);
        uint256 price = auction.currentPrice(id);
        usdc.mint(bidder, price);
        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        auction.bid(id, price);
        vm.stopPrank();

        uint256 owed = auction.totalUnclaimedRewards();
        assertGt(owed, 0, "fixture: no reward is owed, the bound is untested");
        assertEq(auction.rewardOf(keeper), owed, "fixture: the reward is the keeper's");

        // Nothing above the reward, so there is nothing free to sweep.
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();

        // Donate one dollar. Exactly that dollar is free, and not a wei more.
        usdc.mint(stranger, 1e6);
        vm.prank(stranger);
        usdc.transfer(address(auction), 1e6);
        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();

        assertEq(credit.insuranceFund() - insuranceBefore, 1e6, "the sweep took more or less than the free balance");
        assertEq(auction.rewardOf(keeper), owed, "the keeper's reward moved");
        uint256 rewardBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        auction.claimReward();
        assertEq(usdc.balanceOf(keeper) - rewardBefore, owed, "the keeper could not collect after the sweep");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The siblings, swept in the same commit.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `claimBountyFor` and `claimRewardFor` are the other two `msg.sender`-scoped pots.
    /// @dev No trace is filed against either - nothing in this repo builds a keeper contract that
    ///      could strand one. They are here so the property holds by construction: **every pot in
    ///      this protocol is collectable by somebody other than its own claimant, to that
    ///      claimant.** Round 20 fixed one of two identical pointer triples and round 21's whole
    ///      headline was the one it missed; this is that rule applied to pots.
    function test_everyMsgSenderScopedPotHasAThirdPartyCollector() public {
        uint256 id = _openAuctionAt(_navFloorShortOfDebt());
        skip(Config.AUCTION_DURATION / 2);
        uint256 price = auction.currentPrice(id);
        usdc.mint(bidder, price);
        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        auction.bid(id, price);
        vm.stopPrank();

        // `rewardOf` on the auction.
        uint256 reward = auction.rewardOf(keeper);
        assertGt(reward, 0, "fixture: no reward accrued");
        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(stranger);
        auction.claimRewardFor(keeper);
        assertEq(usdc.balanceOf(keeper) - keeperBefore, reward, "claimRewardFor paid the wrong address");

        // `claimableOf` on the manager - the borrower's surplus from the same fill.
        uint256 surplus = credit.claimableOf(alice);
        if (surplus != 0) {
            uint256 aliceBefore = usdc.balanceOf(alice);
            vm.prank(stranger);
            credit.claimSurplusFor(alice);
            assertEq(usdc.balanceOf(alice) - aliceBefore, surplus, "claimSurplusFor paid the wrong address");
        }

        // `bountyOwedTo` on the manager.
        uint256 bounty = credit.bountyOwedTo(keeper);
        assertGt(bounty, 0, "fixture: no bounty was earned");
        keeperBefore = usdc.balanceOf(keeper);
        vm.prank(stranger);
        credit.claimBountyFor(keeper);
        assertEq(usdc.balanceOf(keeper) - keeperBefore, bounty, "claimBountyFor paid the wrong address");

        vm.expectRevert(CreditManager.NoBountyOwed.selector);
        vm.prank(stranger);
        credit.claimBountyFor(keeper);
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        vm.prank(stranger);
        auction.claimRewardFor(keeper);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The fix that was NOT built, measured rather than argued.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The rejected guard: refuse `LiquidationAuction.setCreditManager` while
    ///         `claimableOf(this) != 0`.
    /// @dev **Built as a one-line patch and executed before this was written**, and it is the
    ///      wrong fix for a reason that only shows up in a fixture. The guard is satisfiable
    ///      whenever the outgoing manager can still pay, which is the happy path and the only
    ///      path anyone reasons about. Make it unable to pay - blacklist the auction on USDC,
    ///      which is the exact failure `claimSurplus` is pull-not-push to survive - and the only
    ///      call that can clear the counter is the one that is failing, so the guard welds an
    ///      immutable auction to a dead manager permanently. That is the mutually-unsatisfiable
    ///      shape `EpochHarvester.setLenderPool` spends twenty lines explaining, and this
    ///      codebase has shipped it three times.
    ///
    ///      This test asserts the *predicate* the guard would read, in the state that makes it
    ///      permanent, so it stands as the objection without the guard having to be in the tree.
    function test_theRejectedGuardWouldBeUnsatisfiable() public {
        uint256 accrued = _workoutThenIdle(400e6);
        assertGt(accrued, 0, "fixture: nothing accrued");

        // The claimant cannot receive. Everything else is healthy.
        usdc.setBlocked(address(auction), true);

        // Every route that could clear `claimableOf(auction)` on this manager now reverts, so the
        // guard's predicate is stuck true for the life of the contract.
        vm.expectRevert();
        auction.sweepWorkoutYieldToInsurance();
        vm.expectRevert();
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        assertEq(credit.claimableOf(address(auction)), accrued, "premise: the counter cannot be cleared");

        // And the repoint - which the guard would have refused - is what a migration needs. It
        // succeeds here, which is the whole point: the shipped fix keeps the pointer movable and
        // makes the money reachable later, once the blacklist lifts.
        CreditManager incoming = _migrate();
        assertEq(auction.creditManager(), address(incoming), "the repoint was blocked");

        usdc.setBlocked(address(auction), false);
        vm.prank(stranger);
        credit.claimSurplusFor(address(auction));
        vm.prank(stranger);
        auction.sweepFreeBalanceToInsurance();
        assertGe(incoming.insuranceFund(), accrued, "the money was not recoverable after all");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 22, finding 2: the exit that empties the book
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice One exit under a whole-debt mark must not burn the whole position for the idle cash.
    ///
    /// @dev **The finding's own fixture, and the reason it is here rather than in the unit suite.**
    ///      Real vault, real manager, real auction, real bonds, real farm, and nothing pranked as
    ///      the credit manager: the mark below is written by `CreditManager._impairmentFor` through
    ///      one permissionless `liquidate`, which is what makes it the ordinary state rather than a
    ///      staged one. `LiquidationAuction.t.sol` funds from the treasury, so
    ///      `outstandingPrincipal` is zero throughout it and every reserve clamps to zero - a suite
    ///      built there cannot reach this at all.
    ///
    ///      **The premise is a single-borrower book, which is the shape of the Base Sepolia
    ///      deployment and of launch.** `_impairmentFor` marks `currentDebtOf`, and
    ///      `outstandingPrincipal == pendingPrincipal + totalDebt`, so with one borrower the mark
    ///      reaches `exitReserve`'s clamp exactly. `exitAssets()` then collapses onto the idle
    ///      cash, and before this fix the two terms of `maxWithdraw` - the exit value of the
    ///      caller's shares and `unreservedIdle()` - became the same number, so `previewWithdraw`
    ///      charged nearly the whole position for that cash.
    ///
    ///      MEASURED on the tree before the fix, on exactly this fixture: `maxWithdraw` identical
    ///      in both arms at 19,371.250000, but the share cost 19,999,999,999,968 against the
    ///      control's 19,371,250,000,000, leaving a supply of 32 out of twenty trillion. The
    ///      auction then filled with `lifetimeSocialisedLoss` at zero - the protocol realised no
    ///      loss whatsoever - and the lender's residue was worth 19.496124 where the control's was
    ///      628.749999. `paid + residue` came to 19,390.746124 on a 20,000.000000 deposit: a
    ///      **609.253876** hole with nothing on the other side of it. (The round's write-up calls
    ///      that "exactly the whole debt", which is 628.750000. The measured figure is the debt less
    ///      the 19.496124 the crushed residue is still worth, and it is what this test pins.)
    ///
    ///      The assertion is the conservation identity, not the payout: what a lender takes out
    ///      plus what their residue is worth, once a liquidation that lost nothing has resolved,
    ///      must be what they put in. Asserting the payout would pass against a fix that merely
    ///      moved the hole somewhere else in the book.
    function test_R22F2_aWholeDebtMarkCannotEmptyTheBookOnTheWayOut() public {
        uint256 id = _openAuctionAt(_ordinaryTriggerNav());
        _assertMarked("round 22 finding 2");

        // The premise, asserted rather than assumed, and asserted as the *ordinary* state.
        uint256 loan = pool.outstandingPrincipal();
        assertEq(pool.totalImpairment(), credit.currentDebtOf(alice), "premise: the whole debt is marked");
        assertGe(pool.totalImpairment(), loan, "premise: the mark reaches the clamp in `exitReserve`");
        assertEq(pool.exitReserve(), loan, "premise: so the reserve is the whole lent principal");
        assertEq(
            pool.exitAssets(),
            usdc.balanceOf(address(pool)),
            "premise: and the exit valuation has collapsed onto the idle cash"
        );

        uint256 quoted = pool.maxWithdraw(lender);
        vm.prank(lender);
        uint256 burnt = pool.withdraw(quoted, lender, lender);
        uint256 paid = usdc.balanceOf(lender);

        emit log_named_uint("R22F2 maxWithdraw quoted    ", quoted);
        emit log_named_uint("R22F2 assets actually paid  ", paid);
        emit log_named_uint("R22F2 shares it cost        ", burnt);
        emit log_named_uint("R22F2 supply left           ", pool.totalSupply());

        // 10,000 wei is `MIN_SUPPLY_FOR_YIELD` at a decimals offset of three. Below it the pool is
        // poisoned rather than merely small: `distributeYield` reverts `NoSharesOutstanding`, so
        // every epoch's lender leg backs up behind one exit.
        assertGt(pool.totalSupply(), (10 ** 3) * Config.BPS, "one exit crushed the supply past the yield floor");

        // **No assertion on `previewDeposit` here, and the reason is worth recording.** The round's
        // write-up puts a zero-share deposit downstream of this crush. MEASURED on this fixture
        // before the fix it returns **1**, not 0: 628.750000 of assets against 32 shares is a share
        // price near 20 USDC, and a whole dollar still buys one wei of share. The zero arrives only
        // at a deeper crush than this fixture reaches. An assertion here would therefore have been
        // green on the broken tree and would have proved nothing. The poisoned end state is closed
        // on its own terms by `_deposit`, and pinned in `LenderPool.t.sol` on a fixture that
        // actually reaches it.

        // The liquidation resolves the way this NAV band says it must: covered outright.
        uint256 price = auction.currentPrice(id);
        assertGt(price, credit.currentDebtOf(alice), "fixture: this fill must clear the debt");
        _fund(bidder, price);
        vm.prank(bidder);
        auction.bid(id);
        credit.settlePrincipal();

        assertEq(pool.lifetimeSocialisedLoss(), 0, "fixture: this liquidation must lose nothing at all");
        assertEq(pool.exitReserve(), 0, "fixture: and the mark must have come off with it");

        uint256 residue = pool.previewRedeem(pool.balanceOf(lender));
        emit log_named_uint("R22F2 residue after the fill", residue);
        emit log_named_uint("R22F2 paid + residue        ", paid + residue);

        // The conservation identity. Two wei of tolerance for the floors on the way through and no
        // more.
        assertApproxEqAbs(
            paid + residue,
            LENDER_DEPOSIT,
            2,
            "a lender was destroyed by a liquidation that realised no loss at all"
        );
    }

    /// @notice CONTROL: with no `liquidate` at all, the same sequence loses nothing.
    /// @dev Isolates the mark as the cause. Without this, "the lender got their money back" is
    ///      indistinguishable from "the fixture never put any of it at risk" - and a two-lender
    ///      control would not isolate it either, because the first lender can fully exit even
    ///      un-marked.
    function test_R22F2_control_theSameExitWithNoLiquidationLosesNothing() public {
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);

        assertEq(pool.totalImpairment(), 0, "control: nothing may be marked here");
        assertEq(pool.exitReserve(), 0, "control: and nothing may be reserved");

        uint256 quoted = pool.maxWithdraw(lender);
        vm.prank(lender);
        uint256 burnt = pool.withdraw(quoted, lender, lender);
        uint256 paid = usdc.balanceOf(lender);

        emit log_named_uint("R22F2 control maxWithdraw   ", quoted);
        emit log_named_uint("R22F2 control shares cost   ", burnt);
        emit log_named_uint("R22F2 control supply left   ", pool.totalSupply());

        uint256 residue = pool.previewRedeem(pool.balanceOf(lender));
        assertApproxEqAbs(paid + residue, LENDER_DEPOSIT, 2, "control: an un-marked exit must conserve");
    }

    /// @notice Round 21 finding 7's over-reservation, pinned so this stream cannot be read as
    ///         having touched it.
    /// @dev **This is a pin, not a fix, and that finding is tracked separately.** Round 22 finding
    ///      2 changes `maxWithdraw` and `maxRedeem`, and both changes are provably inert at
    ///      `exitReserve() == 0`, because the un-impaired conversion they now use *is* the
    ///      impaired one when nothing is reserved. So this measurement must read identically
    ///      before and after. If it moves, the change reached further than intended.
    ///
    ///      The state is asserted on both sides of the request so nobody can later mistake this for
    ///      an impairment artefact: nothing is marked, nothing is reserved, and there is no live
    ///      auction anywhere in the graph.
    ///
    ///      MEASURED: one free `requestWithdrawal` by a second lender reserves 3.00x the idle cash
    ///      and takes an unqueued lender's `maxWithdraw` from 1,000.000000 to 0, and `available()`
    ///      from 100.000000 to 0.
    function test_unreservedIdle_overReservationIsUnchangedByThisStream() public {
        // Down to a book small enough to state in whole dollars. Nothing is lent yet, so this is a
        // plain exit at par.
        uint256 trimmed = LENDER_DEPOSIT - 1_000e6;
        vm.prank(lender);
        pool.withdraw(trimmed, lender, lender);
        assertEq(pool.totalAssets(), 1_000e6, "fixture: the residual lender holds 1,000.000000");

        address queuer = makeAddr("r21f7queuer");
        _lend(queuer, 5_000e6);

        // Real principal, out through the real manager against real collateral. Asserted against
        // the derived borrowing power rather than assumed, so a parameter move fails loudly here
        // instead of quietly changing what the numbers below mean.
        assertGe(_maxBorrow(1_000, NAV), 5_000e6, "fixture: the collateral must support this borrow");
        vm.prank(alice);
        vault.depositBonds(900);
        vm.prank(alice);
        credit.borrow(5_000e6);
        assertEq(usdc.balanceOf(address(pool)), 1_000e6, "fixture: 1,000.000000 of idle cash is left");
        assertEq(pool.totalAssets(), 6_000e6, "fixture: on a 6,000.000000 book");

        _assertNothingIsReserved("before");
        assertEq(pool.maxWithdraw(lender), 1_000e6, "the unqueued lender can take the whole float");
        assertEq(pool.available(), 100e6, "and 100.000000 is still lendable behind the hot float");

        uint256 claim = 3_000e6;
        uint256 queuerShares = pool.convertToShares(claim);
        vm.prank(queuer);
        pool.requestWithdrawal(queuerShares, queuer);

        _assertNothingIsReserved("after");
        emit log_named_uint("R21F7 queue claim as a percentage of idle cash", (claim * 100) / 1_000e6);
        assertEq(pool.maxWithdraw(lender), 0, "round 21 finding 7: the unqueued lender is zeroed");
        assertEq(pool.available(), 0, "round 21 finding 7: and so is the lending book");
        assertEq(pool.unreservedIdle(), 0, "round 21 finding 7: 3.00x of the idle cash is reserved");
    }

    function _assertNothingIsReserved(string memory when) private view {
        assertEq(pool.totalImpairment(), 0, string.concat(when, ": nothing may be marked"));
        assertEq(pool.exitReserve(), 0, string.concat(when, ": nothing may be reserved"));
        assertEq(auction.liveAuctionCount(), 0, string.concat(when, ": no auction may be live"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 22, findings 8 and 9. The recovery era: money follows the
    // pointer, not the balance sheet that bore the loss.
    //
    // Two pointers, one shape. Finding 8 is `LiquidationAuction.creditManager`,
    // read at settlement time by `workoutSettleAfterClose`; finding 9 is
    // `CreditManager.lenderPool`/`liquiditySource`, read at recovery time by
    // `recoverWrittenDownLoss`. Both are fixed the same way, and the fixes are
    // deliberately written to look like each other: the bearer is recorded when
    // the loss is recognised and read back when the recovery arrives.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A second pool, funded and wired to `incoming`, so a migrated era has a balance sheet of
    ///      its own for the recovery to land on if it is misdirected.
    function _poolForNewEra(CreditManager incoming) internal returns (LenderPool poolB) {
        poolB = new LenderPool(IERC20(address(usdc)), admin);
        address lenderB = makeAddr("lenderB");
        usdc.mint(lenderB, LENDER_DEPOSIT);
        vm.startPrank(lenderB);
        usdc.approve(address(poolB), type(uint256).max);
        poolB.deposit(LENDER_DEPOSIT, lenderB);
        vm.stopPrank();

        vm.startPrank(admin);
        poolB.setCreditManager(address(incoming));
        poolB.setEpochHarvester(harvester);
        incoming.setLiquiditySource(address(poolB));
        incoming.setLenderPool(address(poolB));
        vm.stopPrank();
    }

    /// @dev A forced close with the pool as both funder and sink, so the pool genuinely takes the
    ///      loss and there is a real bearer for the recovery to find.
    function _forceCloseOntoThePool() internal returns (uint256 id, uint256 writtenDown) {
        id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        writtenDown = pool.lifetimeSocialisedLoss();
        assertGt(writtenDown, 0, "fixture: the pool did not bear the loss");
    }

    /// @notice A lender entering after a real forced-close recovery is delivered cannot dilute
    ///         the shares that formed the delivered recovery cohort.
    /// @dev This uses the full auction/workout return leg rather than pranking a pool callback.
    ///      The old released-only entry price let the newcomer buy before the tail released and
    ///      take part of it. Gross active-tail pricing returns the newcomer only its principal and
    ///      leaves the cohort's recovery value unchanged. The cohort is defined at delivery, not
    ///      by historical loss provenance.
    function test_R22F10_postDeliveryEntrantCannotDiluteTheRecoveryCohort() public {
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();
        uint256 cohortShares = pool.balanceOf(lender);
        uint256 cohortValueAfterLoss = pool.previewRedeem(cohortShares);

        _fund(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);
        assertGt(pool.unreleasedYield(), 0, "fixture: the recovery was not rated as an active stream");
        assertGt(pool.yieldRate(), 0, "fixture: the recovery stream is frozen");

        uint256 controlSnapshot = vm.snapshotState();
        vm.warp(pool.yieldStreamEndsAt() + 1);
        uint256 cohortValueWithoutNewcomer = pool.previewRedeem(cohortShares);
        vm.revertToState(controlSnapshot);

        address entrant = makeAddr("postDeliveryEntrant");
        uint256 entrantAssets = 5_000e6;
        _lend(entrant, entrantAssets);

        vm.warp(pool.yieldStreamEndsAt() + 1);
        uint256 entrantValue = pool.previewRedeem(pool.balanceOf(entrant));
        uint256 cohortValueAfterRecovery = pool.previewRedeem(cohortShares);

        assertLe(entrantValue, entrantAssets, "the entrant captured a recovery delivered before entry");
        assertApproxEqAbs(
            entrantValue, entrantAssets, 2, "gross recovery pricing did not return the entrant's principal"
        );
        assertApproxEqAbs(
            cohortValueAfterRecovery,
            cohortValueWithoutNewcomer,
            2,
            "the post-delivery entrant diluted the cohort against its no-newcomer control"
        );
        assertApproxEqAbs(
            cohortValueWithoutNewcomer,
            cohortValueAfterLoss + writtenDown,
            2,
            "the no-newcomer control did not receive the delivered recovery"
        );
    }

    /// @notice **Finding 8.** The late tranche pays the manager that bore the loss, not whichever
    ///         manager the auction happens to point at when the money turns up.
    /// @dev MEASURED before the fix, on this fixture: the forced close wrote 628.750000 onto the
    ///      first era pool, an ordinary migration moved `LiquidationAuction.creditManager`, and a
    ///      permissionless relayed tranche paid the SECOND era pool 628.750000 while the pool that
    ///      actually took the loss gained 0.
    ///
    ///      The window is opened by the transaction that creates the obligation. `closeWorkout`
    ///      writes `w.writtenDown` and in the same block decrements `workoutsOpenFor` and pops
    ///      `_openWorkouts`, so the `_openWorkouts.length != 0` refusal in `setCreditManager` - the
    ///      only thing standing between the write-off and the repoint - is emptied by that same
    ///      call. The control below asserts that refusal in the state where it does still bind.
    function test_R22_theLateTrancheFollowsTheManagerThatBoreTheLoss() public {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        // CONTROL, and the reason the fix is a struct field rather than a setter guard: while the
        // workout is OPEN the pointer refuses to move. It is the close itself that opens the
        // window.
        CreditManager blocked = _freshManager();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAuction.AuctionHasLiveWork.selector, 1));
        auction.setCreditManager(address(blocked));

        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        uint256 writtenDown = pool.lifetimeSocialisedLoss();
        assertGt(writtenDown, 0, "fixture: the pool did not bear the loss");

        // The ordinary migration, which the emptied counters now allow.
        CreditManager incoming = _migrate();
        LenderPool poolB = _poolForNewEra(incoming);
        assertEq(auction.creditManager(), address(incoming), "fixture: the auction did not repoint");

        uint256 poolBAssetsBefore = poolB.totalAssets();
        uint256 poolCashBefore = usdc.balanceOf(address(pool));

        _fund(payer, writtenDown);
        vm.prank(payer); // permissionless, and nobody with a stake picks the moment
        auction.workoutSettleAfterClose(id, writtenDown);

        emit log_named_uint(
            "MEASURED cash to the pool that bore the loss", usdc.balanceOf(address(pool)) - poolCashBefore
        );
        emit log_named_uint(
            "MEASURED assets gained by the era that bore nothing", poolB.totalAssets() - poolBAssetsBefore
        );
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, writtenDown, "the bearer was not paid");
        assertEq(poolB.totalAssets(), poolBAssetsBefore, "the new era gained money it never lost");
        assertEq(poolB.lifetimeLossRecovered(), 0, "and did not book a recovery it never bore");
        assertEq(pool.lifetimeLossRecovered(), writtenDown, "the bearer booked it");
    }

    /// @notice **Finding 8, second outcome.** A migration that also deploys a fresh auction - the
    ///         ordinary case, because the auction is immutable - used to make `w.writtenDown`
    ///         permanently unreachable. The recorded bearer is what keeps the return leg of the
    ///         outgoing auction alive.
    /// @dev MEASURED before the fix: `workoutSettleAfterClose` reverted `NotLiquidationAuction()`,
    ///      because the *incoming* manager names the new auction and the old auction was the one
    ///      calling. Nothing else in the protocol could reach the figure.
    function test_R22_theReturnLegSurvivesAMigrationToAFreshAuction() public {
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();

        // A whole new era: fresh manager first - which repoints this auction at it - and then the
        // fresh auction the immutable one has to be replaced by.
        CreditManager incoming = _migrate();
        LiquidationAuction auctionB = new LiquidationAuction(
            usdc,
            ICollateralVault(address(vault)),
            INAVOracle(address(oracle)),
            IRiskParams(address(riskParams)),
            admin
        );
        vm.startPrank(admin);
        auction.disposeWorkoutLot(id, admin); // the vault refuses an auction repoint over a live lot
        vault.setLiquidationAuction(address(auctionB));
        incoming.setLiquidationAuction(address(auctionB));
        auctionB.setCreditManager(address(incoming));
        vm.stopPrank();
        _poolForNewEra(incoming);
        assertEq(auction.creditManager(), address(incoming), "fixture: the old auction did not repoint");
        assertEq(incoming.liquidationAuction(), address(auctionB), "fixture: the new manager names the old auction");

        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        _fund(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);

        emit log_named_uint(
            "MEASURED recovered through an auction the protocol no longer uses",
            usdc.balanceOf(address(pool)) - poolCashBefore
        );
        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, writtenDown, "the figure is unreachable again");
    }

    /// @notice **Finding 9.** Moving the funder out to a treasury flips the destination of the
    ///         recovery from the pool that wrote the asset down to a wallet the owner can withdraw from.
    /// @dev MEASURED with control, before the fix: `pool.lifetimeSocialisedLoss` 628.750000 in both
    ///      arms; `pool.lifetimeLossRecovered` 628.750000 (control) vs 0 (treatment); a lender
    ///      `previewRedeem` after the recovery 20,000.000000 vs 19,371.250000 unmoved; treasury USDC
    ///      delta 0 vs +628.750000. The treasury branch is `pendingPrincipal +=`, then the
    ///      permissionless `settlePrincipal`, then `TreasuryLiquiditySource.repayPrincipal`, which
    ///      clamps at zero and keeps the money as idle float withdrawable by the owner.
    ///
    ///      **The mitigation the docstring gave - the window is operational, not adversarial,
    ///      because the setters are `onlyOwner` - is falsified by the shipped governance.** Under
    ///      the `TimelockController` this protocol deploys, `executors[0] = address(0)`, so a
    ///      matured batch is executed by whoever wants to; `workoutSettleAfterClose` is
    ///      permissionless; and the two are bundleable in one transaction. The owner picks whether,
    ///      a stranger picks when. This test does not need them bundled - the plain sequence is
    ///      enough - but the docstring that rested on it has been corrected.
    function test_R22_theRecoveryFollowsTheBalanceSheetNotTheFunderPointer() public {
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();
        uint256 redeemBefore = pool.previewRedeem(pool.balanceOf(lender));

        // The repoint that flips the dispatch. It takes the `else` branch - a treasury does not
        // answer `exitReserve()` - so `lenderPool` is left standing where it is and nothing
        // announces that the loss sink has stopped agreeing with the funder.
        TreasuryLiquiditySource treasury = new TreasuryLiquiditySource(usdc, admin);
        vm.startPrank(admin);
        treasury.setCreditManager(address(credit));
        credit.setLiquiditySource(address(treasury));
        vm.stopPrank();
        assertEq(credit.lenderPool(), address(pool), "premise: the sink stayed behind");
        assertTrue(credit.lenderPool() != credit.liquiditySource(), "premise: the pointers diverged");

        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        _fund(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);
        vm.prank(stranger);
        credit.settlePrincipal();

        emit log_named_uint(
            "MEASURED treasury USDC gained by the recovery", usdc.balanceOf(address(treasury)) - treasuryBefore
        );
        assertEq(usdc.balanceOf(address(treasury)), treasuryBefore, "the recovery reached the treasury");
        assertEq(pool.lifetimeLossRecovered(), writtenDown, "the pool that bore it booked nothing");
        vm.warp(pool.yieldStreamEndsAt() + 1);
        emit log_named_uint(
            "MEASURED lender redeem value after the recovery", pool.previewRedeem(pool.balanceOf(lender))
        );
        assertEq(
            pool.previewRedeem(pool.balanceOf(lender)), redeemBefore + writtenDown, "the lenders were not made whole"
        );
    }

    /// @notice CONTROL for finding 9: with the wiring left alone the recovery reaches the pool.
    ///         The fix must not change this arm, and before the fix this arm already passed.
    function test_R22_control_theRecoveryReachesThePoolWithNoRepoint() public {
        (uint256 id, uint256 writtenDown) = _forceCloseOntoThePool();
        uint256 poolCashBefore = usdc.balanceOf(address(pool));

        _fund(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);

        assertEq(usdc.balanceOf(address(pool)) - poolCashBefore, writtenDown, "the control arm moved");
        assertEq(pool.lifetimeLossRecovered(), writtenDown, "and was booked as a recovery");
    }

    /// @notice **Finding 9, the mirror.** The wiring `DeployBase` actually ships is
    ///         treasury-funds/pool-is-sink, so the treasury bears a default by never being repaid.
    ///         Pointing the funder AT the pool afterwards - the legal Phase-4 switchover - used to
    ///         stream that recovery to depositors who funded nothing.
    /// @dev MEASURED before the fix: `pool.lifetimeSocialisedLoss` 0 - the pool never took this loss
    ///      at all - and a lender's `previewRedeem` still went 20,000.000000 -> 20,628.749999 once
    ///      the stream had run. A gain pointed at whoever holds shares in the next era, which is
    ///      round 11's bearer instrument with the sign flipped.
    function test_R22_theMirror_aPoolThatBoreNothingIsNotPaidTheRecovery() public {
        // Rewire to the shipped shape: the treasury funds the book, the pool stays the sink. Round
        // 21 left this divergence legal on purpose - a treasury has no book to socialise against.
        TreasuryLiquiditySource treasury = new TreasuryLiquiditySource(usdc, admin);
        usdc.mint(admin, LENDER_DEPOSIT);
        vm.startPrank(admin);
        treasury.setCreditManager(address(credit));
        usdc.approve(address(treasury), LENDER_DEPOSIT);
        treasury.fund(LENDER_DEPOSIT);
        credit.setLiquiditySource(address(treasury));
        vm.stopPrank();
        assertEq(credit.lenderPool(), address(pool), "premise: the pool is still the sink");

        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
        assertGt(writtenDown, 0, "fixture: nothing was written down");
        assertEq(pool.lifetimeSocialisedLoss(), 0, "premise: the pool bore none of this");

        // The switchover: the funder moves to the pool, so the two pointers agree again.
        vm.startPrank(admin);
        credit.settlePrincipal();
        credit.setLiquiditySource(address(pool));
        vm.stopPrank();
        assertEq(credit.lenderPool(), credit.liquiditySource(), "premise: the pointers agree again");

        uint256 redeemBefore = pool.previewRedeem(pool.balanceOf(lender));
        _fund(payer, writtenDown);
        vm.prank(payer);
        auction.workoutSettleAfterClose(id, writtenDown);

        // **Audit round 23, finding 5: this test used to stop here, one free permissionless call
        // short of the payment.** `pendingPrincipal == writtenDown` was read as "the funder that
        // bore it is owed the money", and it was not: `pendingPrincipal` is one pot, paid to
        // whatever `liquiditySource` points at when `settlePrincipal` next runs, and the switchover
        // eight lines up has just pointed it at the pool. So the assertion that closed finding 9
        // was measuring the state *before* the free call that undoes it. MEASURED with the
        // sentinel: a lender's `previewRedeem` 20,000.000000 -> 20,628.749999.
        assertEq(credit.pendingPrincipal(), 0, "the recovery must not sit on the live-pointer counter");
        assertEq(
            credit.owedToSource(address(treasury)),
            writtenDown,
            "it must be parked against the funder that actually bore it"
        );
        assertEq(credit.lossFunderOf(alice), address(treasury), "and the era must be recorded, not re-derived");

        // The call the old assertion stopped short of. Anybody may make it, and now it must move
        // nothing, because there is nothing left on the counter it drains.
        vm.prank(stranger);
        credit.settlePrincipal();

        vm.warp(pool.yieldStreamEndsAt() + 1);
        emit log_named_uint(
            "MEASURED lender redeem value after a recovery they never lost",
            pool.previewRedeem(pool.balanceOf(lender))
        );
        assertEq(
            pool.previewRedeem(pool.balanceOf(lender)),
            redeemBefore,
            "depositors were paid for a loss they did not take"
        );
        assertEq(pool.lifetimeLossRecovered(), 0, "and the pool booked a recovery against nothing");

        // And the money is not stranded either: the permissionless flush pays the balance sheet
        // that really bore the default, through its own bookkeeping, which is finding 1's leg.
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        vm.prank(stranger);
        credit.flushPrincipalTo(address(treasury));
        assertEq(
            usdc.balanceOf(address(treasury)) - treasuryBefore, writtenDown, "the bearer was never made whole"
        );
        assertEq(credit.totalOwedToSources(), 0, "and the park must clear");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 22, finding 18. A clean workout close is not a default, so the
    // borrower's own yield is not insurance's.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Expire a liquidation to a workout, run a full epoch through it, then repay the workout
    ///      in full so it closes CLEAN. Returns the workout id and the debt at the moment of
    ///      repayment, which is what the arithmetic hangs on: the lot is under the auction's ledger
    ///      entry, so the epoch writes **none** of the borrower's debt down.
    function _cleanCloseAfterAnEpoch(uint256 epochYield) internal returns (uint256 id, uint256 debtAtRepayment) {
        id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        _streamYieldTo(epochYield);
        credit.settle(address(auction));

        debtAtRepayment = credit.currentDebtOf(alice);
        assertGt(debtAtRepayment, 0, "fixture: nothing left to repay, the close would not be clean");

        // Repaid in full, plus the penalty the workout fixed at expiry, so the close is clean.
        uint256 payment = debtAtRepayment * 2;
        _fund(payer, payment);
        vm.prank(payer);
        auction.workoutSettle(id, payment);
        assertEq(credit.currentDebtOf(alice), 0, "fixture: the debt survived the settlement");

        auction.closeWorkout(id);
        (,,,,,,, uint256 writtenDown,,,) = auction.workouts(id);
        assertEq(writtenDown, 0, "fixture: this close was not clean");
    }

    /// @notice **The finding.** A workout that closed with the debt repaid in full used to send the
    ///         yield its own lot earned to the insurance fund, by a call anybody could make.
    /// @dev MEASURED before the fix, on a 1,000.000000 epoch: debt at repayment 628.750000 with the
    ///      epoch writing **none** of it down, lot yield 999.999999, `claimableOf[borrower]` 0, and
    ///      the whole 999.999999 landing in the insurance fund by a call anybody could make.
    ///
    ///      The design premise for that sweep is "a defaulted position keeps accruing yield against
    ///      a debt being written off". On a clean close the premise is false in every clause: the
    ///      debt is repaid, `writtenDown` is 0, and nobody lost a cent.
    function test_R22_aCleanCloseKeepsTheYieldForTheBorrower() public {
        uint256 epochYield = 1_000e6;
        (uint256 id, uint256 debtAtRepayment) = _cleanCloseAfterAnEpoch(epochYield);

        (,,,,,,,,,, uint256 owed) = auction.workouts(id);
        emit log_named_uint("MEASURED debt at repayment, with the epoch writing none of it down", debtAtRepayment);
        emit log_named_uint("MEASURED yield the lot earned during the workout", owed);
        assertGt(owed, 0, "the clean close credited the borrower nothing");

        uint256 borrowerBefore = usdc.balanceOf(alice);
        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(stranger); // permissionless, and the destination is not the caller's to choose
        auction.claimWorkoutYield(id);

        emit log_named_uint("MEASURED paid to the borrower whose lot earned it", usdc.balanceOf(alice) - borrowerBefore);
        assertEq(usdc.balanceOf(alice) - borrowerBefore, owed, "the borrower was not paid");
        assertEq(credit.insuranceFund(), insuranceBefore, "insurance took it anyway");
        (,,,,,,,,,, uint256 left) = auction.workouts(id);
        assertEq(left, 0, "and the figure was not spent down");
        assertEq(auction.totalWorkoutYieldOwed(), 0);
    }

    /// @notice And once the close has booked the figure, no sweep can take it, whichever runs first.
    /// @dev The ordering hazard is the whole reason `totalWorkoutYieldOwed` exists:
    ///      `sweepWorkoutYieldToInsurance` is permissionless, so without the bound a stranger picks
    ///      whether the borrower is paid by choosing which call lands first.
    ///
    ///      **"Whichever runs first" is scoped to the calls that run AFTER the close, and that scope
    ///      is not a hedge.** A sweep that lands *before* the close is a different and still open
    ///      hazard: it takes the money outright, and all `closeWorkout` can then do is refuse to
    ///      book an entry it cannot pay. Measured, with the residual written down, in
    ///      `test_R22_aSweepBeforeTheCloseCannotBookMoneyTheProtocolCannotPay` below.
    function test_R22_theInsuranceSweepCannotTakeACleanClosesYield() public {
        (uint256 id,) = _cleanCloseAfterAnEpoch(1_000e6);
        (,,,,,,,,,, uint256 owed) = auction.workouts(id);

        // The sweep runs first, and finds nothing free to take.
        vm.prank(stranger);
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.sweepWorkoutYieldToInsurance();
        vm.prank(stranger);
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.sweepFreeBalanceToInsurance();

        // The borrower is still paid in full afterwards.
        uint256 borrowerBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - borrowerBefore, owed, "the sweep took it after all");
    }

    /// @notice **A sweep that lands BEFORE the close must not leave the close booking money that
    ///         no longer exists.** Executed PoC, and it is the reason `closeWorkout` bounds the
    ///         figure it stores.
    /// @dev `sweepWorkoutYieldToInsurance` is permissionless and takes the auction's whole
    ///      realisable claim, and `yieldIndexAtOpen` is never advanced when it does. So the accrual
    ///      this close reads is what the lot *generated*, which after a mid-workout sweep is not
    ///      what the contract can still pay.
    ///
    ///      MEASURED before the bound, on a 1,000.000000 epoch swept while the workout was still
    ///      open: `yieldOwed` 999.999999 against a reachable balance of **zero**. That entry is not
    ///      a harmless over-count - `claimWorkoutYield` pays out of any USDC here above the
    ///      liquidation callers' reserve, so it would be met out of a different borrower's booked
    ///      yield, and `sweepFreeBalanceToInsurance` would reserve it forever against a claim that
    ///      can never be spent down. With the bound it books 0 and the ledger stays honest.
    ///
    ///      **And this test is also where the residual is written down, rather than left to be
    ///      rediscovered.** The bound restores solvency; it does not give the borrower the money,
    ///      because the money is in the insurance fund and `fundInsurance` has no reverse leg. So
    ///      finding 18 closes the ordering hazard *after* the close (see the test above) and leaves
    ///      it open *before* the close: a stranger who sweeps while the workout is open still ends
    ///      the borrower's claim to that epoch, for the price of one transaction. Closing that too
    ///      means the sweeps must stop taking yield attributable to lots whose workout is still
    ///      open - which contradicts `sweepWorkoutYieldToInsurance`'s own stated premise and the
    ///      fixture audit round 22 finding 14 certified one PR earlier, so it is a design decision
    ///      and not a patch. Carried, not silently accepted.
    function test_R22_aSweepBeforeTheCloseCannotBookMoneyTheProtocolCannotPay() public {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        _streamYieldTo(1_000e6);

        // A stranger sweeps while the workout is still open. Nothing is booked yet, so the whole
        // of the lot's accrual so far leaves for the insurance fund.
        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(stranger);
        auction.sweepWorkoutYieldToInsurance();
        uint256 swept = credit.insuranceFund() - insuranceBefore;
        emit log_named_uint("MEASURED swept to insurance mid-workout, before anyone could close", swept);
        assertGt(swept, 0, "fixture: the sweep took nothing, there is no hazard to test");

        // The debt is then repaid in full, so this close is clean and would have booked the lot's
        // whole accrual since the workout opened.
        uint256 payment = credit.currentDebtOf(alice) * 2;
        _fund(payer, payment);
        vm.prank(payer);
        auction.workoutSettle(id, payment);
        assertEq(credit.currentDebtOf(alice), 0, "fixture: the debt survived the settlement");

        auction.closeWorkout(id);
        (,,,,,,, uint256 writtenDown,,, uint256 owed) = auction.workouts(id);
        assertEq(writtenDown, 0, "fixture: this close was not clean");

        uint256 reachable = _reachableBackingForWorkoutYield();
        emit log_named_uint("MEASURED booked to the borrower by the clean close", owed);
        emit log_named_uint("MEASURED money the auction could actually pay it with", reachable);
        assertEq(owed, 0, "the close booked an entry the money for was already spent");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "and the running total carries the same phantom");
        assertGe(reachable, auction.totalWorkoutYieldOwed(), "what is booked must be backed");

        // The residual, asserted rather than described: the borrower gets nothing, and the reason
        // is that a stranger chose the moment.
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(id);
    }

    /// @notice The same bound, from the other side: a **partial** sweep must leave exactly the
    ///         unswept remainder bookable, not zero and not the whole accrual.
    /// @dev The one-arm version above cannot tell a correct bound from a `yieldOwed` hard-wired to
    ///      zero. Here a second epoch lands after the sweep, so the honest answer is strictly
    ///      between the two failure modes and the test says which.
    function test_R22_theBoundLeavesExactlyWhatTheSweepDidNotTake() public {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        _streamYieldTo(1_000e6);
        vm.prank(stranger);
        auction.sweepWorkoutYieldToInsurance();

        // A second epoch, after the sweep. This one is still here.
        _streamYieldTo(400e6);
        uint256 reachable = _reachableBackingForWorkoutYield();
        assertGt(reachable, 0, "fixture: the second epoch never reached the lot");

        uint256 payment = credit.currentDebtOf(alice) * 2;
        _fund(payer, payment);
        vm.prank(payer);
        auction.workoutSettle(id, payment);
        auction.closeWorkout(id);

        (,,,,,,,,,, uint256 owed) = auction.workouts(id);
        emit log_named_uint("MEASURED booked after a partial sweep", owed);
        emit log_named_uint("MEASURED backing available at the close", reachable);
        assertGt(owed, 0, "the bound flattened a claim that was still fully funded");
        assertLe(owed, reachable, "the bound let through more than the money that exists");

        uint256 borrowerBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - borrowerBefore, owed, "and it must be payable in full");
    }

    /// @dev Every USDC the auction could still put behind a workout-yield entry: what it holds
    ///      above the liquidation callers' reserve, plus both halves of what the manager still owes
    ///      it. The same three reads `closeWorkout` bounds against, restated here from the
    ///      properties rather than copied from the implementation.
    function _reachableBackingForWorkoutYield() internal view returns (uint256) {
        uint256 held = usdc.balanceOf(address(auction));
        uint256 rewards = auction.totalUnclaimedRewards();
        uint256 free = held > rewards ? held - rewards : 0;
        return free + credit.claimableOf(address(auction)) + credit.pendingYieldOf(address(auction));
    }

    /// @notice CONTROL: a **forced** close still sends the lot's yield to insurance, because there
    ///         the premise holds - the debt was written off and somebody did lose it.
    /// @dev The two arms differ by one thing only: whether the debt was repaid. Before this commit
    ///      they were identical, which is the finding stated as a comparison.
    function test_R22_control_aForcedCloseStillFundsInsurance() public {
        uint256 id = _openAuctionAt(_crashedNav());
        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);
        _streamYieldTo(1_000e6);
        credit.settle(address(auction));

        skip(Config.WORKOUT_MAX_DURATION + 1);
        vm.prank(stranger);
        auction.closeWorkout(id);
        (,,,,,,, uint256 writtenDown,,, uint256 owed) = auction.workouts(id);
        assertGt(writtenDown, 0, "control: this close was not forced");
        assertEq(owed, 0, "a forced close credited the defaulter");

        uint256 insuranceBefore = credit.insuranceFund();
        vm.prank(stranger);
        auction.sweepWorkoutYieldToInsurance();
        emit log_named_uint(
            "MEASURED insurance gained by a forced close's lot yield", credit.insuranceFund() - insuranceBefore
        );
        assertGt(credit.insuranceFund(), insuranceBefore, "the sweep stopped working on a real default");

        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(id);
    }

    /// @notice CONTROL, and the comparison the finding is built on: the same position and the same
    ///         epoch, with the auction **cancelled** rather than expired, pays the yield into the
    ///         borrower's debt.
    /// @dev MEASURED on this fixture: the same 1,000.000000 epoch takes the debt to 0 instead of
    ///      leaving 628.750000 outstanding, and insurance gains nothing. The whole of that swing
    ///      used to be decided by whether the auction lapsed rather than by whether the loan was
    ///      repaid. This arm is unchanged by the fix and is what the fixed arm is measured against.
    function test_R22_control_aCancelledAuctionPaysTheYieldIntoTheDebt() public {
        uint256 id = _openAuctionAt(_crashedNav());
        uint256 debtBefore = credit.currentDebtOf(alice);

        // Heal the position and cancel, so the lot never leaves the borrower's ledger entry.
        oracle.setNav(NAV);
        auction.cancel(id);
        _streamYieldTo(1_000e6);
        credit.settle(alice);

        emit log_named_uint("MEASURED debt after the same epoch, lot never reassigned", credit.currentDebtOf(alice));
        assertLt(credit.currentDebtOf(alice), debtBefore, "the yield did not reach the debt");
        assertEq(credit.insuranceFund(), 0, "insurance took a share of a position that never defaulted");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audit round 23, finding 4. Round 22's own clamp double-books, because it is
    // right in the singular and wrong in the plural.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Seat a second borrower with their own collateral. Every test above this line runs one
    ///      borrower, which is exactly why finding 4 was invisible to all of them.
    function _seatSecondBorrower(address who) internal {
        bond.mint(who, 1_000);
        vm.startPrank(who);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    /// @dev Borrow at the ceiling as `who`, at the current NAV. Read the derivation before the
    ///      prank: it is an external view call and `vm.prank` is spent by the next call, staticcall
    ///      included.
    function _borrowAtCeilingAs(address who) internal {
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(who);
        credit.borrow(debt);
    }

    function _repayWorkoutInFull(address who, uint256 id) internal {
        uint256 payment = credit.currentDebtOf(who) * 2;
        _fund(payer, payment);
        vm.prank(payer);
        auction.workoutSettle(id, payment);
        assertEq(credit.currentDebtOf(who), 0, "fixture: the debt survived the settlement");
    }

    /// @dev Two concurrent workouts, a permissionless mid-workout sweep that separates what the
    ///      lots *generated* from what the auction can still lay hands on - the disclosed round-22
    ///      residual, and only the setup here - a second epoch that stays, both debts repaid in
    ///      full, and both workouts closed CLEAN.
    function _twoCleanCloses(address second) internal returns (uint256 idA, uint256 idB) {
        return _twoCleanClosesInner(second, true);
    }

    /// @dev The same sequence with the mid-workout sweep removed, so the two arms differ by one
    ///      thing only.
    function _twoCleanClosesWithNoSweep(address second) internal returns (uint256 idA, uint256 idB) {
        return _twoCleanClosesInner(second, false);
    }

    function _twoCleanClosesInner(address second, bool sweepMidWorkout)
        internal
        returns (uint256 idA, uint256 idB)
    {
        _seatSecondBorrower(second);
        _borrowAtCeilingAs(alice);
        _borrowAtCeilingAs(second);
        oracle.setNav(_crashedNav());

        vm.startPrank(keeper);
        credit.liquidate(alice);
        credit.liquidate(second);
        vm.stopPrank();
        idA = auction.auctionOf(alice);
        idB = auction.auctionOf(second);
        assertGt(idA * idB, 0, "fixture: both auctions must open");

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(idA);
        auction.expireToWorkout(idB);

        _streamYieldTo(1_000e6);
        if (sweepMidWorkout) {
            vm.prank(stranger);
            auction.sweepWorkoutYieldToInsurance();
        }
        _streamYieldTo(400e6);

        _repayWorkoutInFull(alice, idA);
        _repayWorkoutInFull(second, idB);

        auction.closeWorkout(idA);
        auction.closeWorkout(idB);
        (,,,,,,, uint256 wdA,,,) = auction.workouts(idA);
        (,,,,,,, uint256 wdB,,,) = auction.workouts(idB);
        assertEq(wdA + wdB, 0, "fixture: neither close was clean");
    }

    /// @notice **The finding.** Two clean closes may not book the same manager-side claim twice.
    /// @dev The bound `closeWorkout` applies is `min(what the lot earned, what this contract can
    ///      still pay for it)`, and as round 22 shipped it the second half netted the already-
    ///      spoken-for claims off the held balance ONLY. `claimableOf(auction)` and
    ///      `pendingYieldOf(auction)` are one shared pot with one yield index, not a per-workout
    ///      allocation, so each close in turn read the same undiminished figure and booked against
    ///      it. MEASURED before the fix, on this exact sequence: the ledger booked more than the
    ///      whole reachable backing, and the phantom was then paid out of a later epoch that
    ///      belonged to the insurance fund - insurance received 200.000000 of a 600.000000 epoch
    ///      against a 600.000001 control.
    ///
    ///      **This test opens two workouts and every test above it opens one, which is the whole
    ///      point.** A bound that is correct in the singular and wrong in the plural is invisible
    ///      to every test that opens one item, and the regression round 22 shipped for its own
    ///      finding opens one.
    function test_R23_04_twoCleanClosesCannotBookTheSameClaimTwice() public {
        (uint256 idA, uint256 idB) = _twoCleanCloses(makeAddr("bob"));

        (,,,,,,,,,, uint256 owedA) = auction.workouts(idA);
        (,,,,,,,,,, uint256 owedB) = auction.workouts(idB);
        uint256 booked = auction.totalWorkoutYieldOwed();
        uint256 reachable = _reachableBackingForWorkoutYield();
        emit log_named_uint("MEASURED booked across both clean closes", booked);
        emit log_named_uint("MEASURED reachable backing behind them", reachable);

        assertEq(booked, owedA + owedB, "the running total must be the sum of its entries");
        assertGt(booked, 0, "premise: neither close booked anything, so this proves nothing");
        assertLe(booked, reachable, "DEFECT: the auction booked workout yield it cannot pay");
    }

    /// @notice CONTROL, and the "is it correct?" half of the sign check: with nothing swept out
    ///         from under them, **both** clean closes are still booked and paid in full.
    /// @dev Netting the spoken-for claims off the whole denominator can only ever *reduce* what is
    ///      booked, so a fix in this direction has to be shown not to have gone too far - a clamp
    ///      that simply booked zero would satisfy the solvency assertion above and nothing else.
    ///      This is the arm that says it did not. The only difference from `_twoCleanCloses` is the
    ///      mid-workout sweep, which is the disclosed round-22 residual and not part of the fix.
    function test_R23_04_control_withNothingSweptBothClosesArePaidInFull() public {
        address bob = makeAddr("bob");
        (uint256 idA, uint256 idB) = _twoCleanClosesWithNoSweep(bob);

        (,,,,,,,,,, uint256 owedA) = auction.workouts(idA);
        (,,,,,,,,,, uint256 owedB) = auction.workouts(idB);
        assertGt(owedA, 0, "CONTROL: the first close booked its borrower nothing");
        assertGt(owedB, 0, "CONTROL: the second close booked its borrower nothing");
        assertLe(auction.totalWorkoutYieldOwed(), _reachableBackingForWorkoutYield(), "and still solvent");

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        auction.claimWorkoutYield(idA);
        auction.claimWorkoutYield(idB);

        assertEq(usdc.balanceOf(alice) - aliceBefore, owedA, "CONTROL: the first borrower was short-paid");
        assertEq(usdc.balanceOf(bob) - bobBefore, owedB, "CONTROL: the second borrower was short-paid");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "CONTROL: the ledger must close out at zero");
    }

    /// @notice **The residual the fix leaves, written down rather than left to be rediscovered.**
    ///         Once a mid-workout sweep has taken money the lots generated, what is left is
    ///         allocated to whoever closes first, and a later close books nothing.
    /// @dev MEASURED on the sequence in `_twoCleanCloses`: 400.000000 booked to the first close and
    ///      **0** to the second, where before the fix both were booked ~700.000000 and the excess
    ///      was met out of a later epoch that belonged to the insurance fund.
    ///
    ///      This is not a new hazard, it is the old one arriving somewhere visible. The money the
    ///      second borrower is missing left in `sweepWorkoutYieldToInsurance`, which is
    ///      permissionless, takes the whole realisable claim and never advances `yieldIndexAtOpen`
    ///      - the residual round 22 disclosed and deliberately did not close, because closing it
    ///      means the sweeps must stop taking yield attributable to open workouts. What the clamp
    ///      decides is only who absorbs a shortfall that already happened, and the ordering answer
    ///      is the only one available to a function whose own docstring forbids it doing new work.
    ///      **The alternative is worse in the direction that matters**: the shipped behaviour paid
    ///      the second borrower out of the first borrower's money or insurance's.
    function test_R23_04_theResidual_aSweptPotIsAllocatedToWhicheverClosesFirst() public {
        address bob = makeAddr("bob");
        (uint256 idA, uint256 idB) = _twoCleanCloses(bob);

        (,,,,,,,,,, uint256 owedA) = auction.workouts(idA);
        (,,,,,,,,,, uint256 owedB) = auction.workouts(idB);
        emit log_named_uint("MEASURED booked to the close that ran first", owedA);
        emit log_named_uint("MEASURED booked to the close that ran second", owedB);
        assertGt(owedA, 0, "the first close must still book what is actually there");
        assertEq(owedB, 0, "the second close must book nothing rather than a phantom");

        // What is booked is paid, in full, which is the property the ledger owes either way.
        uint256 aliceBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(idA);
        assertEq(usdc.balanceOf(alice) - aliceBefore, owedA, "the first borrower was short-paid");
        assertEq(auction.totalWorkoutYieldOwed(), 0, "the ledger must close out at zero");
        vm.expectRevert(LiquidationAuction.NothingToClaim.selector);
        auction.claimWorkoutYield(idB);
    }

    /// @notice CONTROL: with one workout, the bound is unchanged. The fix moves nothing in the case
    ///         round 22 measured, which is what makes it a correction rather than a different rule.
    function test_R23_04_control_oneCleanCloseIsUnchanged() public {
        (uint256 id,) = _cleanCloseAfterAnEpoch(1_000e6);
        (,,,,,,,,,, uint256 owed) = auction.workouts(id);
        assertGt(owed, 0, "the single close must still book the borrower its lot's yield");
        assertLe(owed, _reachableBackingForWorkoutYield(), "and it must still be backed");

        uint256 borrowerBefore = usdc.balanceOf(alice);
        auction.claimWorkoutYield(id);
        assertEq(usdc.balanceOf(alice) - borrowerBefore, owed, "and payable in full");
    }
}

/// @notice A bidder that tries to release the borrower's impairment from inside the ERC-1155
///         callback the seize hands it.
/// @dev Deliberately a real contract rather than a `vm.prank` of an EOA: the window this probes only
///      exists because `_vault.seize` hands control to a *contract* winner through
///      `onERC1155Received`, and an EOA winner never gets a callback at all. A test that pranked an
///      address here would exercise nothing and pass forever.
///
///      It calls the permissionless `refreshImpairment` and then records what the mark reads as,
///      rather than asserting inside the callback. A revert in an ERC-1155 hook surfaces as a failed
///      bid, which would look like the guard working when it might equally be the fixture breaking.
contract CallbackBidder {
    CreditManager private immutable credit;
    LenderPool private immutable pool;
    address private immutable borrower;

    bool public ran;
    uint256 public markDuringCallback;
    uint256 public reserveDuringCallback;

    constructor(CreditManager credit_, LenderPool pool_, address borrower_) {
        credit = credit_;
        pool = pool_;
        borrower = borrower_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        ran = true;
        credit.refreshImpairment(borrower);
        markDuringCallback = pool.impairmentOf(borrower);
        reserveDuringCallback = pool.exitReserve();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice A winning bidder that repays part of the borrower's own debt from inside its callback.
/// @dev The cure is reachable and deliberately so: `repayFor` is permissionless and never pausable,
///      and no manager frame is open during `seize`. It exists here to tell apart a mark re-derived
///      from the live debt at every write from one frozen when the recovery was recognised - the
///      second over-marks by exactly this cure, in the frame where `serviceQueue` is callable.
///
///      `repaid` is recorded so a cure that silently did nothing cannot read as a mark that
///      correctly did not move.
contract RepayingBidder {
    CreditManager private immutable credit;
    LenderPool private immutable pool;
    MockUSDC private immutable usdc;
    address private immutable borrower;
    uint256 private immutable cure;

    bool public ran;
    uint256 public repaid;
    uint256 public markDuringCallback;

    constructor(CreditManager credit_, LenderPool pool_, MockUSDC usdc_, address borrower_, uint256 cure_) {
        credit = credit_;
        pool = pool_;
        usdc = usdc_;
        borrower = borrower_;
        cure = cure_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        ran = true;
        uint256 before = credit.currentDebtOf(borrower);
        usdc.approve(address(credit), cure);
        credit.repayFor(borrower, cure);
        repaid = before - credit.currentDebtOf(borrower);
        // `repayFor` re-derives the mark itself on its way out, so this reads what that write left
        // rather than asking for a refresh the production path would not have made.
        markDuringCallback = pool.impairmentOf(borrower);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice A winning bidder that services the withdrawal queue from inside its own seize callback.
/// @dev The lot arrives before the debt is written down and before `auctionOf` is cleared, so for
///      the length of this frame the pool is still reserving the whole loan against every lender.
///      `serviceQueue` is permissionless and the pool's own `nonReentrant` is a different
///      contract's guard, so nothing here is re-entrancy in the sense the auction defends against:
///      it is one permissionless call made at an instant the caller chose.
///
///      Nothing is wrapped in `try`. A callback that silently swallowed its own failure would make
///      the test pass for the wrong reason, and `ran`/`serviced` are asserted so a callback that
///      did nothing cannot read as a callback that found nothing to do.
contract QueueServicingBidder {
    LenderPool private immutable pool;

    bool public ran;
    uint256 public serviced;

    constructor(LenderPool pool_) {
        pool = pool_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        ran = true;
        serviced = pool.serviceQueue(1);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}
