// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

interface ICanonicalCashPoolView {
    function depositCapUsage() external view returns (uint256);
    function unmanagedSurplus() external view returns (uint256);
}

/// @dev A wallet that can hold USDC and can never initiate a call: no functions, no fallback, no
///      owner, no way out. This is the receiver `claimFor` exists for, and the one round 22
///      measured it recovering 20,000.000000 from - lost keys, a contract wallet whose pointer
///      moved, a keeper behind a proxy with no route left to `claim()`. It is deliberately NOT
///      blocked on the token: being unable to ASK and being unable to RECEIVE are the two halves
///      round 22 measured opposite answers on, and `claimFor` closes only the first.
contract MuteWallet {}

/// @dev Test token that moves a depositor's existing pool shares from inside the asset transfer.
///      Real USDC does not currently expose this hook, but the production token is upgradeable and
///      the pool's entry-point guard does not cover inherited ERC-20 transfers.
contract ShareTransferHookUSDC is ERC20 {
    LenderPool private _pool;
    address private _shareOwner;
    address private _shareReceiver;
    uint256 private _shares;
    bool private _armed;

    bool public hookRan;

    constructor() ERC20("Share Transfer Hook USDC", "hUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(LenderPool pool_, address shareOwner_, address shareReceiver_, uint256 shares_) external {
        _pool = pool_;
        _shareOwner = shareOwner_;
        _shareReceiver = shareReceiver_;
        _shares = shares_;
        _armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_armed && from == _shareOwner && to == address(_pool)) {
            _armed = false;
            hookRan = true;
            _pool.transferFrom(_shareOwner, _shareReceiver, _shares);
        }
        super._update(from, to, value);
    }
}

/// @notice The Phase 4 lender pool (PRD §4.2, §6.4).
///
///         The share-price arithmetic is the least interesting thing here and gets the fewest
///         tests. What gets the most is the withdrawal queue, because the queue is where a lender
///         can be cheated: by being jumped, by being stranded, or by escaping a loss that then
///         falls on whoever stayed. Each of those has a test named after the thing it prevents.
contract LenderPoolTest is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");

    /// @dev **A plain EOA, and that is itself the assertion.** This used to be a
    ///      `MockCreditManager` pointing at a `MockLiquidationAuction`, and it had to be: the
    ///      round-10 exit gate made a typed call into the manager and two more into that manager's
    ///      auction from inside `maxWithdraw`, and a typed call to an address with no code reverts,
    ///      so an EOA here broke every withdrawal in the suite. Round 11 filed that as a finding in
    ///      its own right - three unguarded external calls on the only ERC-4626 exit, with no owner
    ///      escape while principal was out. The gate is gone and the impairment is pushed in and
    ///      stored locally, so there is nothing left to call. Every test below leans on that
    ///      silently; `test_creditManager_needsNoCodeAtAll` says it out loud.
    address internal creditManager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant DEPOSIT = 10_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            address who = [alice, bob, carol][i];
            usdc.mint(who, DEPOSIT);
            vm.prank(who);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        return pool.deposit(assets, who);
    }

    /// @dev Draw `amount` out to the credit manager, as a borrow would.
    function _lend(uint256 amount) internal {
        vm.prank(creditManager);
        pool.lend(amount);
    }

    function _depositCapUsage(LenderPool target) internal view returns (uint256) {
        return ICanonicalCashPoolView(address(target)).depositCapUsage();
    }

    function _unmanagedSurplus(LenderPool target) internal view returns (uint256) {
        return ICanonicalCashPoolView(address(target)).unmanagedSurplus();
    }

    /// @dev Lend and write off until the pool holds nothing at all.
    ///
    ///      A total loss fixture must remove the recognized shareholder book rather than merely
    ///      move or donate raw tokens. Canonical cash makes unsolicited transfers inert, so this
    ///      helper repeatedly lends and writes off only recognized liquidity until NAV reaches zero.
    ///
    ///      One `lend` cannot reach the book, because `available()` withholds `RESERVE_RATIO_BPS`
    ///      of `totalAssets()`. Each write-off lowers `totalAssets()` and therefore lowers that
    ///      float, so lending and losing in turn converges geometrically and reaches exactly zero
    ///      once the reserve floors below one asset-wei, which it does under seven asset-wei at the
    ///      shipped ratio. The 64-round bound is slack on purpose; the loop exits on its own.
    function _loseEverything() internal {
        for (uint256 i = 0; i < 64; i++) {
            uint256 lendable = pool.available();
            if (lendable != 0) _lend(lendable);
            uint256 exposure = pool.outstandingPrincipal();
            if (exposure == 0) break;
            vm.prank(creditManager);
            pool.socialiseLoss(exposure);
        }
    }

    /// @dev Write the pool down until every remaining asset is out on loan and nothing is idle.
    ///      The caller finishes the job with one `socialiseLoss(outstandingPrincipal())`.
    ///
    ///      **MEASURED, and this is the whole reason the helper is split in two.** The queue has
    ///      first call on liquidity: `available()` and `unreservedIdle()` both hold back
    ///      `convertToAssets(queuedShares)` **ceiling-rounded**. So once an entry is standing,
    ///      neither `lend` nor `redeem` can reach the last asset-wei, `_loseEverything` stalls a
    ///      few wei short of empty, and under the yield-first debit the clamp therefore never
    ///      fires. **A principal-generation roll is unreachable while a queue entry stands** - a
    ///      fixture that wants one has to strand the residue as `outstandingPrincipal` first, which
    ///      is what this does. `available()` withholds `RESERVE_RATIO_BPS` of `totalAssets()`, and
    ///      that floors to zero once `totalAssets()` is under seven asset-wei, so the loop
    ///      converges on a state with a live exposure and no idle at all.
    function _lendDownToNothingIdle() internal {
        for (uint256 i = 0; i < 64; i++) {
            uint256 lendable = pool.available();
            if (lendable != 0) _lend(lendable);
            uint256 exposure = pool.outstandingPrincipal();
            if (exposure == 0) break;
            if (pool.totalAssets() == exposure) break; // nothing idle is left to reserve
            vm.prank(creditManager);
            pool.socialiseLoss(exposure);
        }
    }

    // ── deposits and the cap ─────────────────────────────────────────────────

    function test_depositMintsSharesAndCountsAsAssets() public {
        uint256 shares = _deposit(alice, 1_000e6);

        assertEq(pool.totalAssets(), 1_000e6);
        assertEq(pool.balanceOf(alice), shares);
        assertEq(pool.convertToAssets(shares), 1_000e6);
    }

    /// @dev The offset is the anti-inflation measure, so it is asserted rather than assumed.
    function test_sharesCarryThreeMoreDecimalsThanTheAsset() public view {
        assertEq(pool.decimals(), usdc.decimals() + 3);
    }

    /// @dev Unsolicited USDC is not shareholder cash. It therefore cannot move the entry price or
    ///      amplify the classic ERC-4626 first-depositor attack.
    function test_firstDepositorDonationCannotRoundTheSecondOneToNothing() public {
        vm.prank(alice);
        pool.deposit(1, alice);

        uint256 quoteBefore = pool.previewDeposit(1_000e6);
        usdc.mint(address(pool), 1_000e6);

        uint256 bobShares = _deposit(bob, 1_000e6);
        assertEq(bobShares, quoteBefore, "a donation changed the entry quote");
        assertGt(bobShares, 0, "second depositor must not be rounded out of the pool");
        assertGt(pool.convertToAssets(bobShares), 0);
        assertEq(_unmanagedSurplus(pool), 1_000e6, "donation was recognized as shareholder cash");
    }

    function test_depositCapIsEnforcedAndTracksTotalAssets() public {
        assertEq(pool.maxDeposit(alice), pool.depositCap());

        uint256 cap = pool.depositCap();
        usdc.mint(alice, cap);
        vm.prank(alice);
        pool.deposit(cap, alice);

        assertEq(pool.maxDeposit(alice), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.DepositCapExceeded.selector, 1, 0));
        pool.deposit(1, bob);
    }

    // ── the deposit cap is settable now ──────────────────────────────────────
    //
    // It used to be `Config.LENDER_POOL_DEPOSIT_CAP`, aliased by `=` to the global borrow cap.
    // That alias could not survive the borrow cap becoming storage - a Solidity constant cannot be
    // defined in terms of a storage value - so the pool owns this outright. The ratchet still
    // moves the two together; it now does so by naming both.

    function test_setDepositCap_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setDepositCap(50_000e6);
    }

    function test_setDepositCap_movesWhatTheNextDepositorMayPutIn() public {
        uint256 raised = pool.depositCap() * 2;
        vm.prank(admin);
        pool.setDepositCap(raised);
        assertEq(pool.depositCap(), raised);
        assertEq(pool.maxDeposit(alice), raised, "the ceiling moved and the room did not");
    }

    function test_setDepositCap_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(LenderPool.ZeroAmount.selector);
        pool.setDepositCap(0);
    }

    function test_setDepositCap_acceptsExactlyItsCeiling() public {
        vm.prank(admin);
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
        assertEq(pool.depositCap(), Config.GLOBAL_BORROW_CAP_MAX, "the largest legal cap was refused");
    }

    /// @dev The accept-side test above is the one that would catch an over-tight bound. From this
    ///      side alone an over-tight bound is invisible: the rejection still passes.
    function test_setDepositCap_rejectsOneAboveItsCeiling() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                LenderPool.DepositCapTooLarge.selector, Config.GLOBAL_BORROW_CAP_MAX + 1, Config.GLOBAL_BORROW_CAP_MAX
            )
        );
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX + 1);
    }

    function test_setDepositCap_emitsBothValues() public {
        uint256 previous = pool.depositCap();
        vm.expectEmit(false, false, false, true, address(pool));
        emit LenderPool.DepositCapSet(previous, 50_000e6);
        vm.prank(admin);
        pool.setDepositCap(50_000e6);
    }

    /// @notice Lowering the cap under what is already deposited closes the pool and strands nobody.
    /// @dev The claim `setDepositCap`'s own docstring makes, checked rather than asserted. It
    ///      matters because the cap is the one pool parameter governance can move downward
    ///      freely, and a lender who could not leave afterwards would make that a trap. Neither
    ///      `maxWithdraw` nor the queue reads the cap, which is why this holds.
    function test_setDepositCap_belowLiveDepositsClosesThePoolWithoutTrappingALender() public {
        uint256 shares = _deposit(alice, DEPOSIT);

        vm.prank(admin);
        pool.setDepositCap(DEPOSIT / 2);

        assertEq(pool.maxDeposit(bob), 0, "the pool must be shut to new capital");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.DepositCapExceeded.selector, 1, 0));
        pool.deposit(1, bob);

        // And the lender already in is unaffected: the exit does not read the cap.
        assertEq(pool.maxRedeem(alice), shares, "an existing lender lost their exit");
        vm.prank(alice);
        uint256 out = pool.redeem(shares, alice, alice);
        assertEq(out, DEPOSIT, "the lender did not get their money back");
    }

    // ── lending ──────────────────────────────────────────────────────────────

    function test_lend_isCreditManagerOnly() public {
        _deposit(alice, DEPOSIT);
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.lend(1e6);
    }

    /// @dev `totalAssets` has to keep counting money that is out on loan, or every borrow would
    ///      look like a loss to the share price.
    function test_lend_movesUsdcWithoutMovingTheSharePrice() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        uint256 priceBefore = pool.convertToAssets(shares);

        _lend(1_000e6);

        assertEq(usdc.balanceOf(creditManager), 1_000e6);
        assertEq(pool.outstandingPrincipal(), 1_000e6);
        assertEq(pool.totalAssets(), DEPOSIT);
        assertEq(pool.convertToAssets(shares), priceBefore, "lending is not a loss");
    }

    /// @dev The hot float. Without it, one borrow could take every spare dollar and the next
    ///      ordinary withdrawal would have to queue behind a loan that has months to run.
    function test_lend_leavesTheReserveRatioBehind() public {
        _deposit(alice, DEPOSIT);

        uint256 reserve = (DEPOSIT * Config.RESERVE_RATIO_BPS) / Config.BPS;
        assertEq(pool.available(), DEPOSIT - reserve);

        vm.prank(creditManager);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.InsufficientLiquidity.selector, DEPOSIT, DEPOSIT - reserve));
        pool.lend(DEPOSIT);
    }

    function test_repayPrincipal_pullsAndBooksIt() public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        vm.prank(creditManager);
        usdc.approve(address(pool), 1_000e6);
        vm.prank(creditManager);
        pool.repayPrincipal(1_000e6);

        assertEq(pool.outstandingPrincipal(), 0);
        assertEq(pool.totalAssets(), DEPOSIT);
    }

    // ── yield and loss ───────────────────────────────────────────────────────

    /// @dev Delivery is approve-and-call, matching `EpochHarvester._tryDeliverLenderYield`. A
    ///      push-based implementation would take nothing and the harvester would be right to
    ///      report that nothing arrived.
    ///
    ///      This used to assert `totalAssets() == DEPOSIT + 500e6` on the same line as the
    ///      delivery - the instantaneous step that was audit round 10's finding 6. The USDC still
    ///      arrives at once; what it no longer does is land on the share price at once.
    function test_distributeYield_pullsFromTheHarvesterAndStreamsRatherThanStepping() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        uint256 before = pool.convertToAssets(shares);

        _distributeYield(500e6);

        assertEq(usdc.balanceOf(address(pool)), DEPOSIT + 500e6, "the USDC did arrive");
        assertEq(pool.pendingYield(), 500e6, "and is held out of the share price");
        assertEq(pool.totalAssets(), DEPOSIT, "no step at the moment of delivery");
        assertEq(pool.convertToAssets(shares), before, "so a holder is no richer this block");
        assertEq(pool.totalSupply(), shares, "yield mints no shares");

        skip(Config.YIELD_STREAM_DURATION);

        assertEq(pool.unreleasedYield(), 0, "the stream runs dry on schedule");
        assertEq(pool.totalAssets(), DEPOSIT + 500e6, "and the whole epoch has landed");
        assertGt(pool.convertToAssets(shares), before);
    }

    /// @notice Audit round 10, finding 6, in the order the attack actually runs.
    /// @dev **The deposit has to land before the delivery, and that is the whole test.**
    ///      `EpochHarvester.flushLenderYield` is permissionless, so the attacker does not wait for
    ///      an epoch to arrive - they deposit, call the flush themselves, and redeem, all in one
    ///      transaction. Written the other way round (deposit *after* the delivery) this test
    ///      passes against the unfixed contract, because ERC-4626 sells the late arrival shares at
    ///      the already-raised price. That version was written first and only a deliberately
    ///      neutered build showed it proved nothing.
    function test_stream_justInTimeDepositCapturesNothing() public {
        _deposit(alice, DEPOSIT);
        skip(Config.YIELD_STREAM_DURATION);

        address mallory = makeAddr("mallory");
        usdc.mint(mallory, DEPOSIT);
        vm.startPrank(mallory);
        usdc.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(DEPOSIT, mallory);
        vm.stopPrank();

        _distributeYield(500e6);

        vm.prank(mallory);
        uint256 out = pool.redeem(shares, mallory, mallory);

        assertLe(out, DEPOSIT, "a zero-second holder must not profit from the epoch");
        assertApproxEqAbs(out, DEPOSIT, 1, "and must not be robbed for trying either");
    }

    /// @dev The stream releases on a clock, so half the window is half the epoch.
    function test_stream_releasesInProportionToTimeElapsed() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _distributeYield(500e6);

        skip(Config.YIELD_STREAM_DURATION / 2);

        assertApproxEqAbs(pool.unreleasedYield(), 250e6, 1e3);
        assertApproxEqAbs(pool.convertToAssets(shares), DEPOSIT + 250e6, 1e3);
    }

    /// @dev A fixed window closes same-block capture but not the general case: a pot representing
    ///      sixty days of accrual, rated over five, hands eleven-twelfths of it to whoever happens
    ///      to be holding for those five days. Windows stretch for ordinary reasons - a keeper
    ///      outage, or simply the gap before this pool is wired at all.
    ///      A depositor who really does hold for one whole `YIELD_STREAM_DURATION` earns that
    ///      window's worth and no more - a sixth of a sixty-day pot, not the lot.
    function test_stream_longAccrualWindowIsNotJustInTimeCapturable() public {
        _deposit(alice, DEPOSIT);
        skip(60 days);

        address mallory = makeAddr("mallory");
        usdc.mint(mallory, DEPOSIT);
        vm.startPrank(mallory);
        usdc.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(DEPOSIT, mallory);
        vm.stopPrank();

        _distributeYield(500e6);
        assertEq(pool.yieldStreamEndsAt(), block.timestamp + 60 days, "rated over the window it accrued across");

        skip(Config.YIELD_STREAM_DURATION);
        vm.prank(mallory);
        uint256 out = pool.redeem(shares, mallory, mallory);

        // Two equal holders, so half of whatever the window released. Derived, not hardcoded: the
        // figure moves with `YIELD_STREAM_DURATION`, and a literal here would pin the parameter.
        uint256 fair = ((500e6 * Config.YIELD_STREAM_DURATION) / 60 days) / 2;
        assertApproxEqAbs(out - DEPOSIT, fair, 1e3, "earned the window held, not the window accrued");
        assertLt(out - DEPOSIT, 250e6, "and nothing like half the whole pot");
    }

    /// @notice The step the sibling test above stops one epoch short of.
    /// @dev `test_stream_longAccrualWindowIsNotJustInTimeCapturable` on the borrower leg once
    ///      passed while the defence was broken, because it never ran the *second* epoch - which
    ///      re-rated the first one's tail over five days and undid it. When a test proves a
    ///      defence, ask what the next call does.
    function test_stream_aSecondEpochDoesNotCompressTheFirstEpochsTail() public {
        _deposit(alice, DEPOSIT);
        skip(60 days);
        _distributeYield(500e6);
        uint256 firstStreamEndsAt = pool.yieldStreamEndsAt();

        skip(Config.YIELD_STREAM_DURATION);
        _distributeYield(500e6);

        assertEq(pool.yieldStreamEndsAt(), firstStreamEndsAt, "the tail keeps the window it was rated with");

        // And the capture the compression would have opened is still shut: the whole remaining
        // pot must not be reachable by holding for one stream window.
        address mallory = makeAddr("mallory");
        usdc.mint(mallory, DEPOSIT);
        vm.startPrank(mallory);
        usdc.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(DEPOSIT, mallory);
        vm.stopPrank();

        skip(Config.YIELD_STREAM_DURATION);
        vm.prank(mallory);
        uint256 out = pool.redeem(shares, mallory, mallory);

        assertLe(out, DEPOSIT, "an early exit must not profit from the active tail");
    }

    /// @notice Active yield is part of the price of entering, even though it is not released NAV.
    /// @dev The expected values restate OpenZeppelin 5.6.1's virtual asset/share arithmetic from
    ///      public reads. Only the denominator changes: a live stream adds its projected tail so a
    ///      post-delivery entrant pays for the whole delivered cohort pot rather than diluting it.
    function test_F10_previewDepositAndMintPriceTheProjectedActiveTailWithOZVirtuals() public {
        _deposit(alice, DEPOSIT);
        _distributeYield(500e6);
        skip(1 days);

        uint256 assets = 1_000e6;
        uint256 entryAssets = pool.totalAssets() + pool.unreleasedYield();
        uint256 virtualShares = 10 ** uint256(pool.decimals() - usdc.decimals());
        uint256 expectedShares =
            Math.mulDiv(assets, pool.totalSupply() + virtualShares, entryAssets + 1, Math.Rounding.Floor);
        assertEq(pool.previewDeposit(assets), expectedShares, "deposit ignored the projected active tail");
        assertLt(pool.previewDeposit(assets), pool.convertToShares(assets), "entry still used released NAV");

        uint256 shares = expectedShares;
        uint256 expectedAssets =
            Math.mulDiv(shares, entryAssets + 1, pool.totalSupply() + virtualShares, Math.Rounding.Ceil);
        assertEq(pool.previewMint(shares), expectedAssets, "mint did not invert the gross entry price");
        assertGt(pool.previewMint(shares), pool.convertToAssets(shares), "mint still used released NAV");
    }

    /// @notice Depositing after delivery buys no part of the already-delivered tail.
    function test_F10_postDeliveryYieldEntrantCannotCaptureTheTail() public {
        uint256 incumbentShares = _deposit(alice, DEPOSIT);
        _distributeYield(500e6);

        uint256 entrantShares = _deposit(bob, DEPOSIT);
        vm.warp(pool.yieldStreamEndsAt() + 1);

        vm.prank(bob);
        uint256 entrantOut = pool.redeem(entrantShares, bob, bob);
        assertLe(entrantOut, DEPOSIT, "a post-delivery entrant captured the cohort's tail");
        assertApproxEqAbs(entrantOut, DEPOSIT, 2, "gross pricing did not return the entrant's principal");
        assertGt(pool.previewRedeem(incumbentShares), DEPOSIT + 499e6, "the delivered cohort was diluted");
    }

    /// @notice The exact-share entry door uses the same gross price as a deposit.
    function test_F10_postDeliveryMintCannotCaptureTheTail() public {
        _deposit(alice, DEPOSIT);
        _distributeYield(500e6);

        uint256 shares = 5_000e6 * (10 ** uint256(pool.decimals() - usdc.decimals()));
        uint256 quotedAssets = pool.previewMint(shares);
        vm.prank(bob);
        uint256 assetsIn = pool.mint(shares, bob);
        assertEq(assetsIn, quotedAssets, "mint execution departed from its gross quote");

        vm.warp(pool.yieldStreamEndsAt() + 1);
        vm.prank(bob);
        uint256 out = pool.redeem(shares, bob, bob);
        assertLe(out, assetsIn, "a post-delivery mint captured the cohort's tail");
        assertApproxEqAbs(out, assetsIn, 2, "gross mint pricing did not return the entrant's principal");
    }

    /// @notice The share-denominated cap is the gross-price floor of the remaining asset cap.
    function test_F10_maxMintUsesLiveTailAndCannotCrossTheAssetCap() public {
        _deposit(alice, DEPOSIT);
        _distributeYield(500e6);

        uint256 maxAssets = pool.maxDeposit(bob);
        uint256 entryAssets = pool.totalAssets() + pool.unreleasedYield();
        uint256 virtualShares = 10 ** uint256(pool.decimals() - usdc.decimals());
        uint256 expectedShares =
            Math.mulDiv(maxAssets, pool.totalSupply() + virtualShares, entryAssets + 1, Math.Rounding.Floor);
        uint256 maxShares = pool.maxMint(bob);
        assertEq(maxShares, expectedShares, "maxMint used the released rather than gross entry price");
        assertLe(pool.previewMint(maxShares), maxAssets, "the advertised maximum crosses the asset cap");
        assertGt(pool.previewMint(maxShares + 1), maxAssets, "one more share still fits under the cap");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.DepositCapExceeded.selector, maxShares + 1, maxShares));
        pool.mint(maxShares + 1, bob);

        usdc.mint(bob, maxAssets);
        vm.prank(bob);
        uint256 assetsIn = pool.mint(maxShares, bob);
        assertLe(assetsIn, maxAssets, "mint execution crossed the remaining asset cap");
        assertLe(_depositCapUsage(pool), pool.depositCap(), "mint crossed the deposit cap");
    }

    /// @notice A live impairment changes exits, not the gross price of entering an active stream.
    function test_F10_activeStreamImpairmentMarksOnlyTheExitPrice() public {
        uint256 incumbentShares = _deposit(alice, DEPOSIT);
        _lend(6_000e6);
        _distributeYield(500e6);

        uint256 entryBefore = pool.previewDeposit(1_000e6);
        uint256 exitBefore = pool.previewRedeem(incumbentShares);
        uint256 entryAssets = pool.totalAssets() + pool.unreleasedYield();
        uint256 virtualShares = 10 ** uint256(pool.decimals() - usdc.decimals());
        uint256 expectedEntry =
            Math.mulDiv(1_000e6, pool.totalSupply() + virtualShares, entryAssets + 1, Math.Rounding.Floor);

        _impair(carol, 1_000e6);

        assertLt(pool.previewRedeem(incumbentShares), exitBefore, "the impairment missed the exit price");
        assertEq(pool.previewDeposit(1_000e6), entryBefore, "the impairment leaked into entry pricing");
        assertEq(pool.previewDeposit(1_000e6), expectedEntry, "entry omitted the active tail");
    }

    /// @notice A frozen backlog still belongs to the non-zero cohort that received it.
    /// @dev Stopping the clock below the safe release floor does not make the pot free to a new
    ///      entrant. Deposit and mint price the whole backed tail, and cap usage counts it once.
    function test_F10_frozenBacklogRemainsInEntryPricingForItsLiveCohort() public {
        uint256 incumbentShares = _deposit(alice, DEPOSIT);
        _distributeYield(500e6);

        vm.prank(alice);
        pool.redeem(incumbentShares - 1, alice, alice);
        assertEq(pool.yieldRate(), 0, "fixture: the tail did not freeze");
        assertGt(pool.unreleasedYield(), 0, "fixture: there is no frozen backlog");
        assertEq(pool.totalSupply(), 1, "fixture: the incumbent cohort disappeared");

        uint256 assets = 1_000e6;
        uint256 entryAssets = pool.totalAssets() + pool.unreleasedYield();
        uint256 virtualShares = 10 ** uint256(pool.decimals() - usdc.decimals());
        uint256 expectedShares =
            Math.mulDiv(assets, pool.totalSupply() + virtualShares, entryAssets + 1, Math.Rounding.Floor);
        assertEq(pool.previewDeposit(assets), expectedShares, "deposit omitted the frozen cohort tail");
        assertLt(pool.previewDeposit(assets), pool.convertToShares(assets), "frozen tail became free to entry");

        uint256 shares = expectedShares;
        uint256 expectedAssets =
            Math.mulDiv(shares, entryAssets + 1, pool.totalSupply() + virtualShares, Math.Rounding.Ceil);
        assertEq(pool.previewMint(shares), expectedAssets, "mint omitted the frozen cohort tail");
        assertEq(
            _depositCapUsage(pool),
            pool.totalAssets() + pool.unreleasedYield(),
            "frozen cohort tail was excluded from cap usage"
        );
    }

    /// @notice A lender already present when an epoch is delivered participates in that epoch.
    function test_F10_preDeliveryEntrantParticipatesInTheDeliveredEpoch() public {
        _deposit(alice, DEPOSIT);
        uint256 entrantShares = _deposit(bob, DEPOSIT);

        _distributeYield(500e6);
        vm.warp(pool.yieldStreamEndsAt() + 1);

        vm.prank(bob);
        uint256 out = pool.redeem(entrantShares, bob, bob);
        assertApproxEqAbs(out - DEPOSIT, 250e6, 2, "a pre-delivery cohort member missed its share");
    }

    /// @notice A post-delivery entrant who exits before release forfeits the premium it paid.
    function test_F10_postDeliveryEarlyExitForfeitsTheTailPremium() public {
        _deposit(alice, DEPOSIT);
        _distributeYield(500e6);

        uint256 entrantShares = _deposit(bob, DEPOSIT);
        vm.prank(bob);
        uint256 out = pool.redeem(entrantShares, bob, bob);

        assertLt(out, DEPOSIT, "an early exit recovered the active-tail premium");
    }

    /// @notice Re-rating overlapping streams does not reopen either delivered pot to a newcomer.
    function test_F10_overlappingReratedStreamKeepsTheDeliveredCohortWhole() public {
        uint256 incumbentShares = _deposit(alice, DEPOSIT);
        _distributeYield(400e6);
        skip(Config.YIELD_STREAM_DURATION / 2);
        _distributeYield(200e6);

        uint256 entrantShares = _deposit(bob, DEPOSIT);
        vm.warp(pool.yieldStreamEndsAt() + 1);

        vm.prank(bob);
        uint256 entrantOut = pool.redeem(entrantShares, bob, bob);
        assertLe(entrantOut, DEPOSIT, "the entrant captured an overlapping stream tail");
        assertApproxEqAbs(entrantOut, DEPOSIT, 2, "the rerated gross price did not return principal");
        assertGt(pool.previewRedeem(incumbentShares), DEPOSIT + 599e6, "re-rating diluted the delivered cohort");
    }

    /// @dev Unreleased yield must not outlive the shareholders it was meant for. Merely freezing
    ///      a zero-supply tail lets the next deposit and epoch recycle it into a fresh cohort.
    ///      The terminal burn instead de-recognises the residual while leaving raw cash isolated.
    function test_stream_finalBurnPermanentlyDerecognisesTheOrphanedTail() public {
        uint256 shares = _deposit(alice, 10_000);
        assertEq(shares, 10 ** 3 * Config.BPS, "fixture: deposit did not mint the minimum supply");
        _distributeYield(10_000);
        assertEq(pool.pendingYield(), 10_000, "fixture: epoch did not create the exact tail");

        vm.prank(alice);
        uint256 paid = pool.redeem(shares, alice, alice);
        assertEq(paid, 10_000, "final incumbent did not receive the released book");
        assertEq(pool.totalSupply(), 0, "the last share is gone");
        assertEq(usdc.balanceOf(address(pool)), 10_000, "tail cash did not remain physically present");
        assertEq(pool.pendingYield(), 0, "orphaned tail remained recyclable");
        assertEq(pool.yieldRate(), 0, "empty pool retained a live stream");
        assertEq(_depositCapUsage(pool), 0, "orphaned tail retained cap usage");
        assertEq(_unmanagedSurplus(pool), 10_000, "orphaned tail was not isolated");

        _deposit(bob, 10_000);
        _distributeYield(10_000);
        assertEq(pool.pendingYield(), 10_000, "fresh cohort inherited the old tail");
        assertEq(_unmanagedSurplus(pool), 10_000, "fresh activity re-recognised the old pot");
    }

    function test_distributeYield_isHarvesterOnly() public {
        vm.expectRevert(LenderPool.NotEpochHarvester.selector);
        pool.distributeYield(1e6);
    }

    function test_socialiseLoss_fallsOnEveryLenderInProportion() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(4_000e6);

        vm.prank(creditManager);
        pool.socialiseLoss(1_000e6);

        assertEq(pool.totalAssets(), 2 * DEPOSIT - 1_000e6);
        assertEq(pool.lifetimeSocialisedLoss(), 1_000e6);
        // Equal holdings, equal damage.
        assertEq(pool.convertToAssets(aliceShares), pool.convertToAssets(bobShares));
        assertLt(pool.convertToAssets(aliceShares), DEPOSIT);
    }

    /// @dev A loss bigger than the pool's own exposure is not the pool's to absorb. Letting it
    ///      through would take idle capital that was never lent against anything.
    function test_socialiseLoss_isClampedToWhatIsActuallyOutOnLoan() public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        vm.prank(creditManager);
        pool.socialiseLoss(5_000e6);

        assertEq(pool.outstandingPrincipal(), 0);
        assertEq(pool.lifetimeSocialisedLoss(), 1_000e6, "absorbed only what was at risk");
        assertEq(pool.totalAssets(), DEPOSIT - 1_000e6);
    }

    function test_socialiseLoss_isCreditManagerOnly() public {
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.socialiseLoss(1e6);
    }

    // ── audit round 21, finding 14: the leg that reverses a socialised loss ───

    /// @notice A recovery on a loss already taken raises the share price, over the stream.
    /// @dev It is a gain on an asset this pool has already written off, so it is streamed on the
    ///      same rules as `repayPrincipal`'s surplus: `LiquidationAuction.workoutSettleAfterClose`
    ///      is permissionless, and an instantaneous step is capturable by whoever enters and picks
    ///      the block. The stream instead assigns the value to the shares present at delivery.
    function test_recoverLoss_raisesTheSharePriceOverTheStream() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _lend(4_000e6);
        vm.prank(creditManager);
        pool.socialiseLoss(1_000e6);

        uint256 assetsAfterTheLoss = pool.totalAssets();
        uint256 valueAfterTheLoss = pool.convertToAssets(aliceShares);

        usdc.mint(creditManager, 600e6);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), 600e6);
        pool.recoverLoss(600e6);
        vm.stopPrank();

        assertEq(pool.totalAssets(), assetsAfterTheLoss, "not in the recovering block");
        assertEq(pool.lifetimeLossRecovered(), 600e6);
        assertEq(pool.lifetimeSocialisedLoss(), 1_000e6, "the gross write-down is not netted away");

        vm.warp(pool.yieldStreamEndsAt() + 1);
        assertEq(pool.totalAssets(), assetsAfterTheLoss + 600e6, "and in full once the stream has run");
        assertGt(pool.convertToAssets(aliceShares), valueAfterTheLoss, "the delivered cohort received the stream");
    }

    /// @notice It is a gain, not a repayment: no loan is re-recognised to pay for it.
    /// @dev The distinction the first version of the fix got wrong. `repayPrincipal` nets against
    ///      `outstandingPrincipal`, so routing a recovery through it would have reduced the pool's
    ///      recorded lending for money nobody repaid - deferring the gain behind the surviving book
    ///      and breaking `outstandingPrincipal == pendingPrincipal + totalDebt` on the manager.
    function test_recoverLoss_doesNotMoveOutstandingPrincipalAndCountsTheActiveGain() public {
        _deposit(alice, DEPOSIT);
        _lend(4_000e6);
        vm.prank(creditManager);
        pool.socialiseLoss(1_000e6);

        uint256 principalBefore = pool.outstandingPrincipal();
        uint256 usageBefore = _depositCapUsage(pool);
        uint256 headroomBefore = pool.maxDeposit(alice);

        usdc.mint(creditManager, 600e6);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), 600e6);
        pool.recoverLoss(600e6);
        vm.stopPrank();

        assertEq(pool.outstandingPrincipal(), principalBefore, "no loan was re-recognised");
        assertEq(_depositCapUsage(pool), usageBefore + 600e6, "active recovery was not counted");
        assertEq(pool.maxDeposit(alice), headroomBefore - 600e6, "recovery headroom drift");
    }

    /// @notice A zero-supply recovery has no shareholder cohort and stays unmanaged permanently.
    /// @dev Only the part immediately curing a senior claim deficit may remain recognised.
    function test_recoverLoss_withZeroSupplyBecomesUnmanagedSurplus() public {
        assertEq(pool.totalSupply(), 0, "premise: nobody to raise the price of");

        usdc.mint(creditManager, 600e6);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), 600e6);
        pool.recoverLoss(600e6);
        vm.stopPrank();

        assertEq(pool.pendingYield(), 0, "zero-supply recovery remained recyclable");
        assertEq(pool.yieldRate(), 0, "zero-supply recovery started a stream");
        assertEq(pool.totalAssets(), 0, "zero-supply recovery entered shareholder NAV");
        assertEq(_depositCapUsage(pool), 0, "zero-supply recovery consumed cap");
        assertEq(_unmanagedSurplus(pool), 600e6, "zero-supply recovery was not isolated");

        _deposit(alice, DEPOSIT);
        assertEq(pool.totalAssets(), DEPOSIT, "fresh entrant inherited a historical recovery");
        assertEq(_unmanagedSurplus(pool), 600e6, "entry re-recognised historical recovery");
    }

    function test_recoverLoss_isCreditManagerOnly() public {
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.recoverLoss(1e6);
    }

    function test_recoverLoss_refusesZero() public {
        vm.prank(creditManager);
        vm.expectRevert(LenderPool.ZeroAmount.selector);
        pool.recoverLoss(0);
    }

    // ── audit round 11 ───────────────────────────────────────────────────────

    /// @notice A donation to the empty pool used to close it to lenders forever.
    /// @dev Canonical cash excludes raw transfers from NAV, cap usage and entry pricing. The raw
    ///      balance remains observable as unmanaged surplus, but it cannot close or enrich the pool.
    function test_maxDeposit_survivesADonationToTheEmptyPool() public {
        assertEq(pool.totalSupply(), 0, "the deploy script ships it empty");
        assertEq(pool.maxDeposit(alice), pool.depositCap());

        usdc.mint(address(this), pool.depositCap());
        usdc.transfer(address(pool), pool.depositCap());

        assertEq(pool.maxDeposit(alice), pool.depositCap(), "a stranger closed the pool");
        assertGt(pool.maxMint(alice), 0);
        assertEq(pool.totalAssets(), 0, "a donation entered shareholder NAV");
        assertEq(_depositCapUsage(pool), 0, "a donation consumed cap usage");
        assertEq(_unmanagedSurplus(pool), pool.depositCap(), "the donation was not isolated");

        // And the pool still actually works.
        uint256 shares = _deposit(alice, DEPOSIT);
        assertGt(shares, 0);
        assertEq(pool.totalAssets(), DEPOSIT, "the depositor inherited unmanaged surplus");
        assertEq(_depositCapUsage(pool), DEPOSIT, "only admitted cash must consume the cap");
    }

    /// @dev The cap follows the internally accounted entry book. Recognized active yield consumes
    ///      headroom, and the complete exit releases the recognized book again.
    function test_maxDeposit_countsTheRecognizedEntryBook() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        assertEq(_depositCapUsage(pool), DEPOSIT, "deposit usage");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - DEPOSIT);

        _distributeYield(500e6);
        assertEq(_depositCapUsage(pool), DEPOSIT + 500e6, "active yield must enter cap usage");
        skip(Config.YIELD_STREAM_DURATION);
        assertEq(pool.maxDeposit(bob), pool.depositCap() - DEPOSIT - 500e6, "recognized yield headroom");

        vm.prank(alice);
        pool.redeem(shares, alice, alice);
        assertEq(_depositCapUsage(pool), 0, "complete exit left cap usage behind");
        assertEq(pool.maxDeposit(bob), pool.depositCap(), "leaving must free the room");
    }

    /// @notice One wei of shares used to be enough to accept an epoch.
    /// @dev `_decimalsOffset()` is 3, so conversions run against 1,000 virtual shares nobody holds
    ///      and nothing can sweep. A single share-wei owned about a thousandth of the pool, so a
    ///      permissionless flush could pour a whole epoch into the virtual claim.
    function test_distributeYield_refusesAPoolTooSmallToOwnTheEpoch() public {
        uint256 shares = _deposit(alice, DEPOSIT);

        // Leave a dust holding behind, which the old guard accepted.
        vm.prank(alice);
        pool.redeem(shares - 1, alice, alice);
        assertEq(pool.totalSupply(), 1);

        usdc.mint(harvester, 500e6);
        vm.startPrank(harvester);
        usdc.approve(address(pool), 500e6);
        vm.expectRevert(LenderPool.NoSharesOutstanding.selector);
        pool.distributeYield(500e6);
        vm.stopPrank();
    }

    /// @notice The stream freezes below the yield threshold, not only at exactly zero supply.
    /// @dev **Audit round 12, and round 11 had already proved the threshold.** `distributeYield`
    ///      refuses below `MIN_SUPPLY_FOR_YIELD` because the 1,000 virtual shares dominate a small
    ///      supply; the freeze in `_update` still tested `totalSupply() == 0`, so a partial burn
    ///      walked through the band with a live stream and the release landed on shares nobody can
    ///      redeem. The pool is immutable with no sweep, so that money is gone.
    ///
    ///      Asserted on `unreleasedYield()` rather than on a share price, because the property is
    ///      "the stream stopped", and a price assertion would also pass if the stream had merely
    ///      run out.
    function test_stream_freezesBelowTheThresholdNotOnlyAtZeroSupply() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _distributeYield(500e6);

        // Leave a dust holder behind: supply is non-zero, so an `== 0` freeze never fires.
        vm.prank(alice);
        pool.redeem(shares - 1, alice, alice);

        assertGt(pool.totalSupply(), 0, "the fixture must leave real shares outstanding");
        assertLt(pool.totalSupply(), 10 ** 3 * Config.BPS, "and must sit inside the unsafe band");
        assertEq(pool.yieldRate(), 0, "the stream kept running into a supply the virtual shares own");
    }

    // ── impairment pricing ───────────────────────────────────────────────────

    function _impair(address borrower, uint256 amount) internal {
        vm.prank(creditManager);
        pool.impair(borrower, amount);
    }

    /// @notice The whole mechanism in one test: exits price against the impairment, entries do not.
    /// @dev This is Maple's split (`convertToExitAssets` deducts `unrealizedLosses`,
    ///      `previewDeposit` does not), and it answers both objections to the round-10 gate at
    ///      once. A leaver has nothing to run from, and an entrant cannot buy the discount.
    function test_impairment_marksTheExitPriceDownButNotTheEntryPrice() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(6_000e6);

        uint256 exitBefore = pool.previewRedeem(shares);
        uint256 entryBefore = pool.previewDeposit(1_000e6);

        _impair(bob, 1_000e6);

        assertEq(pool.totalImpairment(), 1_000e6);
        assertEq(pool.exitAssets(), pool.totalAssets() - 1_000e6);

        assertApproxEqAbs(pool.previewRedeem(shares), exitBefore - 1_000e6, 1, "the leaver carries it");
        assertEq(pool.previewDeposit(1_000e6), entryBefore, "the entrant must not get the discount");
    }

    /// @notice Round-10 finding 7, restated as the property rather than as a refusal.
    /// @dev Alice leaves the instant the liquidation opens. She takes her share of the expected
    ///      loss with her, so Bob is not left holding it. Under the old gate she was simply
    ///      blocked; under this she may go, at an honest price.
    function test_impairment_aLeaverCannotOutrunTheExpectedLoss() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(4_000e6);

        _impair(carol, 2_000e6);

        uint256 exitable = pool.maxRedeem(alice);
        vm.prank(alice);
        uint256 out = pool.redeem(exitable, alice, alice);

        // Two equal holders, 2,000 of expected loss, so alice's half is 1,000.
        assertApproxEqAbs(out, DEPOSIT - 1_000e6, 2, "alice bore her half on the way out");
    }

    /// @notice Round-11's buy-the-dip finding, arriving through the front door.
    /// @dev Maple documents this as the reason for the split: an entrant who bought at the impaired
    ///      price would profit when the impairment was released.
    function test_impairment_anEntrantCannotBuyTheDiscount() public {
        _deposit(alice, DEPOSIT);
        _lend(4_000e6);
        _impair(carol, 2_000e6);

        uint256 shares = _deposit(bob, DEPOSIT);

        // The liquidation resolves with no loss at all - the best possible case for a dip buyer.
        vm.prank(creditManager);
        pool.releaseImpairment(carol);

        assertLe(pool.previewRedeem(shares), DEPOSIT, "buying during an impairment must not profit");
    }

    /// @dev The lend is load-bearing, and it was missing. A reserve is clamped to what the pool has
    ///      actually lent, so against an unlent pool this test asserted a mark-down that should
    ///      never have happened - it passed only because `exitReserve` did not yet exist. Exactly
    ///      the note `test_exit_staysOpenAtTheImpairedPriceWhileAnAuctionIsLive` carries one screen
    ///      down, for the same reason: a claim about a loss needs principal the loss can land on.
    function test_impairment_releaseRestoresTheExitPrice() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(4_000e6);
        uint256 before = pool.previewRedeem(shares);

        _impair(bob, 1_000e6);
        assertLt(pool.previewRedeem(shares), before);

        vm.prank(creditManager);
        pool.releaseImpairment(bob);

        assertEq(pool.totalImpairment(), 0);
        assertEq(pool.previewRedeem(shares), before, "releasing must put the price back");
    }

    /// @dev Idempotent set, not an add: the estimate is re-stated as the position moves from a
    ///      floor-bounded auction to a workout that could recover nothing.
    function test_impairment_isRestatedNotAccumulated() public {
        _deposit(alice, DEPOSIT);
        _impair(bob, 1_000e6);
        _impair(bob, 2_500e6);
        assertEq(pool.totalImpairment(), 2_500e6, "escalating must replace, not stack");
        _impair(bob, 0);
        assertEq(pool.totalImpairment(), 0);
    }

    function test_impairment_isCreditManagerOnly() public {
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.impair(bob, 1e6);

        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.releaseImpairment(bob);
    }

    /// @notice Controller service uses the live exit price and an atomic execution floor.
    ///         marked-down one, and this calls it rather than reading a view about it.
    ///
    /// @dev **This replaces `test_impairment_theQueueIsPaidAtTheImpairedPrice`, which audit round
    ///      16 found asserted a view.** That test impaired and then read the former positional view, so it
    ///      passed identically against a settlement path that pays nobody - which, since audit round
    ///      15 keyed the refusal on the standing reserve, is the behaviour. It was named in
    ///      the old settlement NatSpec as the thing that pinned the claim, and the claim had
    ///      stopped being true. **Read a test's name as a claim and check that its verb appears in
    ///      the body.**
    ///
    ///      The property now: below the break, `reserved == false` implies `exitReserve() == 0`
    ///      implies `exitAssets() == totalAssets()`, so the impaired arithmetic is arithmetically
    ///      the plain conversion. Both halves are asserted here, because either alone is
    ///      satisfiable by a broken implementation: a queue that refuses forever passes the first,
    ///      and a queue that pays the marked price passes the second.
    ///
    ///      `withdrawalRequest` is checked as a quote for the controller, not a
    ///      statement about what the queue will pay. Round 16's undesigned consequence is visible
    ///      right here: the quote falls, and the money that eventually arrives does not.
    function test_impairment_theControllerChoosesWhetherToAcceptTheMarkedPrice() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (,,, uint256 serviceableBefore, uint256 quotedBefore) = pool.withdrawalRequest(alice);

        _impair(carol, 2_000e6);
        assertGt(pool.exitReserve(), 0, "fixture: a reserve must actually be standing");
        (,,, uint256 serviceableAfter, uint256 quotedAfter) = pool.withdrawalRequest(alice);
        assertEq(serviceableAfter, serviceableBefore, "the cash-funded share maximum moved with the mark");
        assertLt(quotedAfter, quotedBefore, "the execution quote must carry the mark");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.UnauthorizedRequestOperator.selector, alice, bob));
        pool.serviceWithdrawalRequest(alice, serviceableAfter, 0);
        assertEq(pool.claimable(alice), 0, "a stranger crystallised the marked request");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, quotedAfter, quotedBefore));
        pool.serviceWithdrawalRequest(alice, serviceableAfter, quotedBefore);
        assertEq(pool.claimable(alice), 0, "a failed floor changed the claim");

        vm.prank(alice);
        uint256 paid = pool.serviceWithdrawalRequest(alice, serviceableAfter, quotedAfter);
        assertEq(paid, quotedAfter, "controller service did not use the marked exit price");
        assertEq(pool.claimable(alice), quotedAfter, "marked service was not set aside");
    }

    /// @notice The pool cannot be marked down for a loss it is provably unable to absorb.
    /// @dev **Round-11's zero-exposure finding, arriving from inside the impairment.** The wiring
    ///      `DeployBase` ships makes this pool the loss sink while the treasury is still the
    ///      liquidity source, so `outstandingPrincipal` is zero - and `socialiseLoss` clamps every
    ///      write-down to it, so the pool absorbs exactly nothing of any loss. Without the clamp in
    ///      `exitReserve`, wiring the manager to impair would mark every lender down for a
    ///      shortfall that could never reach them, in the state the deploy script actually ships.
    function test_impairment_neverMarksDownMoreThanThePoolHasLent() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        assertEq(pool.outstandingPrincipal(), 0, "the fixture must have nothing out on loan");

        uint256 exitBefore = pool.previewRedeem(shares);
        _impair(bob, 5_000e6);

        assertEq(pool.exitReserve(), 0, "no exposure, so nothing to reserve");
        assertEq(pool.previewRedeem(shares), exitBefore, "a lender was marked down for someone else's loss");
    }

    /// @dev And the same clamp partially, which is the case a zero-exposure test alone would miss:
    ///      the reserve tracks the exposure up to it and stops there.
    function test_impairment_isCappedAtTheExposureNotAtTheEstimate() public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        _impair(bob, 4_000e6);
        assertEq(pool.exitReserve(), 1_000e6, "the reserve stops at what is actually out on loan");
    }

    /// @notice A yield backlog cannot be streamed into a pool that holds a cent.
    /// @dev Audit round 13. `MIN_SUPPLY_FOR_YIELD` is a *share* threshold, and its own NatSpec puts
    ///      it at "a hundredth of a dollar of deposits". A first deposit mints `assets * 10 **
    ///      offset` shares, so 10,000 wei of USDC clears it exactly - and `pendingLenderYield` is a
    ///      backlog holding the lender share of every epoch since before the pool opened. One cent
    ///      of capital plus one permissionless flush took essentially all of it.
    function test_distributeYield_refusesAnEpochLargerThanThePool() public {
        // Exactly the threshold, and nothing more: 10,000 wei mints 1e7 shares at offset 3.
        vm.prank(alice);
        pool.deposit(10_000, alice);

        uint256 backlog = 5_000e6;
        usdc.mint(harvester, backlog);
        vm.prank(harvester);
        usdc.approve(address(pool), backlog);

        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.YieldExceedsCapital.selector, backlog, 10_000));
        pool.distributeYield(backlog);

        // Once there is real capital behind it, the same delivery is accepted.
        _deposit(bob, DEPOSIT);
        vm.prank(harvester);
        pool.distributeYield(backlog);
        assertEq(pool.unreleasedYield(), backlog, "the epoch streams once the pool can carry it");
    }

    /// @notice A repoint cannot leave the pool priced against a manager it no longer talks to.
    /// @dev Audit round 12. `impairmentOf`, `totalImpairment`, `unplacedLoss` and `insuranceCover`
    ///      all survived `setCreditManager`, and the outgoing manager could no longer clear them -
    ///      its `_setImpairment` calls hit `NotCreditManager` and are swallowed by their own catch.
    ///
    ///      The trap is that it looks fine at the moment of the swap: `exitReserve()` clamps to
    ///      `outstandingPrincipal`, which this setter already requires to be zero. It reactivates
    ///      the first time the new manager lends.
    function test_setCreditManager_refusesWhileAnImpairmentStands() public {
        _deposit(alice, DEPOSIT);
        _impair(bob, 1_000e6);

        address replacement = makeAddr("replacementManager");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.ImpairmentOutstanding.selector, 1_000e6));
        pool.setCreditManager(replacement);

        // And the recovery path is real rather than asserted: releasing the mark unblocks it.
        vm.prank(creditManager);
        pool.releaseImpairment(bob);
        vm.prank(admin);
        pool.setCreditManager(replacement);
        assertEq(pool.creditManager(), replacement, "a cleared pool must be repointable");
    }

    /// @notice The two mirrored scalars are re-derived on a repoint rather than carried over.
    /// @dev They have no per-borrower component, so unlike `impairmentOf` they can be cleared. The
    ///      incoming manager overwrites both on its first push; this closes the window before that.
    function test_setCreditManager_clearsTheMirroredLossReserves() public {
        _deposit(alice, DEPOSIT);
        vm.prank(creditManager);
        pool.setLossReserves(500e6, 300e6);
        assertEq(pool.unplacedLoss(), 500e6, "fixture: the mirror must be populated");

        vm.prank(admin);
        pool.setCreditManager(makeAddr("replacementManager"));

        assertEq(pool.unplacedLoss(), 0, "a backlog belonging to the old manager must not survive");
        assertEq(pool.insuranceCover(), 0, "nor the cover that stood in front of it");
    }

    /// @notice A realised loss frees exactly the destroyed portion of deposit-cap usage.
    function test_depositCapUsage_fallsWithARealisedLossSoTheCapDoesNotRatchetShut() public {
        uint256 cap = pool.depositCap();
        usdc.mint(alice, cap);
        vm.prank(alice);
        pool.deposit(cap, alice);
        assertEq(_depositCapUsage(pool), cap, "fixture: the recognized book must start full");
        assertEq(pool.maxDeposit(bob), 0, "fixture: the pool must start full");

        _lend(pool.available());

        uint256 lost = 1_000e6;
        vm.prank(creditManager);
        uint256 absorbed = pool.socialiseLoss(lost);
        assertEq(absorbed, lost, "fixture: the loss must actually land against principal");

        assertEq(_depositCapUsage(pool), cap - lost, "destroyed capital must stop counting against the cap");
        assertEq(pool.maxDeposit(bob), lost, "and the headroom it freed must be usable");

        usdc.mint(bob, lost);
        vm.prank(bob);
        pool.deposit(lost, bob);
        assertGt(pool.balanceOf(bob), 0, "a replacement lender must be able to get in");
        assertEq(_depositCapUsage(pool), cap, "replacement cash was not counted exactly once");
    }

    /// @notice An ERC-4626 exit frees exactly the recognized cash it pays after yield.
    function test_depositCapUsage_debitsTheExactErc4626PayoutAfterYield() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _distributeYield(4_000e6);
        assertEq(_depositCapUsage(pool), 2 * DEPOSIT + 4_000e6, "active yield was not counted");
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 shares = pool.balanceOf(alice);
        uint256 usageBefore = _depositCapUsage(pool);
        vm.prank(alice);
        uint256 paid = pool.redeem(shares, alice, alice);

        assertGt(paid, DEPOSIT, "fixture: the exit must actually carry yield out with it");
        assertEq(_depositCapUsage(pool), usageBefore - paid, "exit did not debit the exact cash paid");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - _depositCapUsage(pool), "headroom drift");
    }

    /// @notice Request service is a second exit writer and frees usage when cash becomes claimable.
    function test_depositCapUsage_debitsTheExactRequestClaimAfterYield() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _distributeYield(4_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 shares = pool.balanceOf(alice);
        uint256 usageBefore = _depositCapUsage(pool);
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 requestQuote = pool.previewRedeem(shares);
        vm.prank(alice);
        uint256 claimed = pool.serviceWithdrawalRequest(alice, shares, requestQuote);

        assertEq(pool.balanceOf(address(pool)), 0, "fixture: the request must have been paid in full");
        assertEq(claimed, requestQuote, "service departed from its quote");
        assertEq(pool.claimable(alice), claimed, "service did not reserve the claim");
        assertEq(_depositCapUsage(pool), usageBefore - claimed, "request service cap debit drift");

        uint256 usageAfterService = _depositCapUsage(pool);
        _claim(alice);
        assertEq(_depositCapUsage(pool), usageAfterService, "claim debited usage twice");
    }

    /// @notice Repeated entry, yield and exit track the recognized book without a hidden ratchet.
    function test_depositCapUsage_tracksTheRecognizedBookUnderARotatingLender() public {
        vm.prank(admin);
        pool.setDepositCap(100_000e6);

        uint256 anchor = 20_000e6;
        usdc.mint(carol, anchor);
        vm.prank(carol);
        pool.deposit(anchor, carol);
        uint256 expectedUsage = anchor;

        address rotator = makeAddr("rotator");
        for (uint256 epoch = 0; epoch < 2; epoch++) {
            usdc.mint(rotator, anchor);
            vm.startPrank(rotator);
            usdc.approve(address(pool), type(uint256).max);
            pool.deposit(anchor, rotator);
            vm.stopPrank();
            expectedUsage += anchor;
            assertEq(_depositCapUsage(pool), expectedUsage, "deposit transition drift");

            _distributeYield(10_000e6);
            expectedUsage += 10_000e6;
            assertEq(_depositCapUsage(pool), expectedUsage, "yield transition drift");
            skip(Config.YIELD_STREAM_DURATION + 1);

            uint256 out = pool.balanceOf(rotator);
            vm.prank(rotator);
            uint256 assetsOut = pool.redeem(out, rotator, rotator);
            expectedUsage -= assetsOut;
            assertEq(_depositCapUsage(pool), expectedUsage, "exit transition drift");
            assertEq(pool.maxDeposit(bob), pool.depositCap() - expectedUsage, "headroom transition drift");
        }
    }

    /// @notice An above-par round trip changes usage only by its net recognized cash flow.
    function test_R22F3_aboveParRoundTripTracksExactCashAndHeadroom() public {
        vm.prank(admin);
        pool.setDepositCap(50_000e6);

        _deposit(alice, DEPOSIT);
        _distributeYield(2_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 assets = 15_000e6;
        usdc.mint(bob, assets - DEPOSIT);
        uint256 usageBefore = _depositCapUsage(pool);

        vm.prank(bob);
        uint256 shares = pool.deposit(assets, bob);
        assertEq(_depositCapUsage(pool), usageBefore + assets, "entry did not add exact cash");

        vm.prank(bob);
        uint256 assetsOut = pool.redeem(shares, bob, bob);

        assertEq(pool.balanceOf(bob), 0, "the entrant must have completed the round trip");
        assertEq(_depositCapUsage(pool), usageBefore + assets - assetsOut, "round-trip cash flow drift");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - _depositCapUsage(pool), "round-trip headroom drift");
    }

    /// @notice Every one-wei rotation is accounted from actual cash in and actual cash out.
    function test_R22F3_original114CycleRatchetTracksExactCash() public {
        _deposit(alice, DEPOSIT);
        _distributeYield(2_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 expectedUsage = _depositCapUsage(pool);

        for (uint256 i = 0; i < 114; i++) {
            vm.prank(bob);
            uint256 shares = pool.deposit(1, bob);
            expectedUsage += 1;
            vm.prank(bob);
            uint256 assetsOut = pool.redeem(shares, bob, bob);
            expectedUsage -= assetsOut;
            assertEq(_depositCapUsage(pool), expectedUsage, "one-wei rotation drift");
        }

        assertEq(pool.balanceOf(bob), 0, "the rotating account must finish every cycle empty");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - expectedUsage, "114-cycle headroom drift");
    }

    /// @notice Replacement cash remains in cap usage after the pre-loss lender exits.
    function test_R22F3_replacementCashSurvivesTheLossCohortsExit() public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        vm.prank(creditManager);
        assertEq(pool.socialiseLoss(1_000e6), 1_000e6, "fixture: the loss must land");
        assertEq(_depositCapUsage(pool), DEPOSIT - 1_000e6, "loss transition drift");

        uint256 bobShares = _deposit(bob, 1_000e6);
        assertEq(_depositCapUsage(pool), DEPOSIT, "replacement cash must refill only the realised loss");

        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceOut = pool.redeem(aliceShares, alice, alice);

        assertEq(_depositCapUsage(pool), DEPOSIT - aliceOut, "old-cohort exit removed the wrong cash");
        assertGt(pool.convertToAssets(bobShares), 0, "replacement lender lost its position");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - _depositCapUsage(pool), "replacement headroom drift");
    }

    /// @notice A total recognized loss leaves donations inert and the next deposit starts fresh.
    function test_R22F3_totalLossStartsAFreshCanonicalCashBook() public {
        _deposit(alice, DEPOSIT);
        usdc.mint(address(pool), 2_000e6);
        _loseEverything();

        assertEq(pool.totalAssets(), 0, "fixture: a total loss is one that leaves nothing behind");
        assertEq(_depositCapUsage(pool), 0, "a total loss must clear recognized usage");
        assertEq(_unmanagedSurplus(pool), 2_000e6, "the donation was laundered into the book");

        usdc.mint(alice, 1_000e6);
        _deposit(alice, 1_000e6);

        assertEq(pool.totalAssets(), 1_000e6, "the new depositor inherited the donation");
        assertEq(_depositCapUsage(pool), 1_000e6, "new cash must start a fresh recognized book");
        assertEq(_unmanagedSurplus(pool), 2_000e6, "the old donation stopped being inert");
    }

    /// @notice Share transfers change ownership but are neutral to canonical cash and the cap.
    function test_R22F3_shareTransfersAreNeutralToCanonicalCash() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, 1_000e6);

        uint256 aliceBefore = pool.balanceOf(alice);
        uint256 bobBefore = pool.balanceOf(bob);
        uint256 usageBefore = _depositCapUsage(pool);
        uint256 assetsBefore = pool.totalAssets();
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(alice);
        pool.transfer(bob, 1);

        assertEq(pool.balanceOf(alice), aliceBefore - 1, "sender share debit");
        assertEq(pool.balanceOf(bob), bobBefore + 1, "receiver share credit");
        assertEq(pool.totalSupply(), supplyBefore, "transfer changed supply");
        assertEq(pool.totalAssets(), assetsBefore, "transfer changed NAV");
        assertEq(_depositCapUsage(pool), usageBefore, "transfer changed cap usage");
    }

    /// @notice A token callback that transfers old shares cannot double-count a new deposit.
    function test_R22F3_depositCountsCanonicalCashOnceAcrossAnAssetTransferHook() public {
        ShareTransferHookUSDC hookedUsdc = new ShareTransferHookUSDC();
        LenderPool fresh = new LenderPool(IERC20(address(hookedUsdc)), admin);

        hookedUsdc.mint(alice, 2 * DEPOSIT);
        vm.startPrank(alice);
        hookedUsdc.approve(address(fresh), type(uint256).max);
        fresh.deposit(DEPOSIT, alice);
        fresh.approve(address(hookedUsdc), type(uint256).max);
        vm.stopPrank();

        uint256 aliceSharesBefore = fresh.balanceOf(alice);
        uint256 supplyBefore = fresh.totalSupply();
        uint256 usageBefore = _depositCapUsage(fresh);
        uint256 sharesMoved = fresh.balanceOf(alice) / 2;
        hookedUsdc.arm(fresh, alice, bob, sharesMoved);

        vm.prank(alice);
        uint256 sharesMinted = fresh.deposit(DEPOSIT, alice);

        assertTrue(hookedUsdc.hookRan(), "fixture: the asset-transfer hook must have run");
        assertEq(fresh.balanceOf(bob), sharesMoved, "callback transferred the wrong old shares");
        assertEq(fresh.balanceOf(alice), aliceSharesBefore - sharesMoved + sharesMinted, "new shares changed owner");
        assertEq(fresh.totalSupply(), supplyBefore + sharesMinted, "callback changed minted supply");
        assertEq(_depositCapUsage(fresh), usageBefore + DEPOSIT, "deposit cash was not counted exactly once");
    }

    /// @notice Queue escrow and cancellation are usage-neutral; service debits the exact claim.
    function test_R22F3_requestEscrowTracksSharesAndExactCash() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        uint256 requested = shares / 2;
        uint256 usageBefore = _depositCapUsage(pool);

        vm.prank(alice);
        pool.requestWithdrawal(requested, alice);
        assertEq(pool.balanceOf(address(pool)), requested, "escrow must receive the requested shares");
        assertEq(pool.balanceOf(alice), shares - requested, "the lender kept requested shares");
        assertEq(_depositCapUsage(pool), usageBefore, "request creation changed cap usage");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(address(pool)), 0, "cancellation must empty escrow");
        assertEq(pool.balanceOf(alice), shares, "cancellation must restore shares");
        assertEq(_depositCapUsage(pool), usageBefore, "cancellation changed cap usage");

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 requestQuote = pool.previewRedeem(shares);
        vm.prank(alice);
        uint256 assetsOut = pool.serviceWithdrawalRequest(alice, shares, requestQuote);

        assertEq(pool.balanceOf(address(pool)), 0, "request service left escrow shares");
        assertEq(pool.totalSupply(), 0, "full service left live shares");
        assertEq(pool.claimable(alice), assetsOut, "service did not create the fixed claim");
        assertEq(_depositCapUsage(pool), usageBefore - assetsOut, "service cap debit drift");
    }

    /// @notice Shared escrow preserves independent controller requests at different entry prices.
    function test_R22F3_requestsRemainIndependentAcrossDifferentEntryPrices() public {
        vm.prank(admin);
        pool.setDepositCap(50_000e6);

        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _distributeYield(DEPOSIT);
        skip(Config.YIELD_STREAM_DURATION + 1);
        uint256 bobShares = _deposit(bob, DEPOSIT);

        _lend(25_000e6);
        uint256 usageBeforeRequests = _depositCapUsage(pool);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        assertEq(pool.balanceOf(address(pool)), aliceShares + bobShares, "shared escrow lost shares");
        assertEq(_depositCapUsage(pool), usageBeforeRequests, "request creation changed cap usage");

        {
            (uint256 bobId, address bobReceiver, uint256 bobStoredBefore,,) = pool.withdrawalRequest(bob);
            uint256 aliceService = pool.maxRequestRedeem(alice);
            uint256 usageBeforeAliceService = _depositCapUsage(pool);
            vm.prank(alice);
            uint256 aliceClaim = pool.serviceWithdrawalRequest(alice, aliceService, 0);
            (,, uint256 aliceSharesRemaining,,) = pool.withdrawalRequest(alice);
            (uint256 bobIdAfter, address bobReceiverAfter, uint256 bobStoredAfter,,) = pool.withdrawalRequest(bob);
            assertGt(aliceSharesRemaining, 0, "fixture: Alice must retain a live remainder");
            assertEq(_depositCapUsage(pool), usageBeforeAliceService - aliceClaim, "Alice service cap debit drift");
            assertEq(bobIdAfter, bobId, "Alice changed Bob's request id");
            assertEq(bobReceiverAfter, bobReceiver, "Alice changed Bob's receiver");
            assertEq(bobStoredAfter, bobStoredBefore, "Alice changed Bob's shares");

            uint256 usageBeforeAliceCancel = _depositCapUsage(pool);
            vm.prank(alice);
            pool.cancelWithdrawalRequest();
            assertEq(pool.balanceOf(alice), aliceSharesRemaining, "cancel did not return Alice's remainder");
            assertEq(_depositCapUsage(pool), usageBeforeAliceCancel, "Alice cancel changed cap usage");
        }

        _repay(25_000e6);
        {
            uint256 bobService = pool.maxRequestRedeem(bob);
            assertGt(bobService, 0, "fixture: Bob's request must be serviceable");
            assertLt(bobService, bobShares, "fixture: virtual-offset rounding must leave a remainder");
            uint256 bobQuote = pool.previewRedeem(bobService);
            uint256 usageBeforeBobService = _depositCapUsage(pool);
            vm.prank(bob);
            uint256 bobClaim = pool.serviceWithdrawalRequest(bob, bobService, bobQuote);

            (,, uint256 bobSharesRemaining,,) = pool.withdrawalRequest(bob);
            assertEq(bobSharesRemaining, bobShares - bobService, "Bob's service burned the wrong shares");
            assertEq(bobClaim, bobQuote, "Bob service departed from its quote");
            assertEq(_depositCapUsage(pool), usageBeforeBobService - bobClaim, "Bob service cap debit drift");

            uint256 usageBeforeBobCancel = _depositCapUsage(pool);
            vm.prank(bob);
            pool.cancelWithdrawalRequest();
            assertEq(pool.balanceOf(bob), bobSharesRemaining, "cancel did not return Bob's remainder");
            assertEq(pool.balanceOf(address(pool)), 0, "cancelling Bob must empty shared escrow");
            assertEq(_depositCapUsage(pool), usageBeforeBobCancel, "Bob cancel changed cap usage");
        }
    }

    /// @notice A partial fill burns exactly the shares the cash it pays out can buy back, floored.
    /// @dev **Audit round 25, finding 2: this branch was protected by nothing.** Flipping the
    ///      `Math.Rounding.Floor` in the cash-funded gross share conversion to
    ///      `Ceil` stayed green across all 58 `LenderPool` invariant evaluations and all 900
    ///      deterministic tests - zero detection anywhere in a 993-test suite. This is the
    ///      regression, and it was neuter-verified against exactly that flip and nothing else.
    ///
    ///      **The one wei of fully released recognized yield below is the whole reason this test
    ///      works.** On the fixture's own round numbers - a
    ///      10,000.000000 deposit into an empty pool, lent down to `Config.RESERVE_RATIO_BPS` of
    ///      the book - the three quantities that decide the rounding are
    ///
    ///        idle = 1,500,000,000    s = totalSupply() + 10**3 = 10**13 + 1,000
    ///                                a = exitAssets() + 1      = 10,000,000,001
    ///
    ///      and `idle * s` is an **exact** multiple of `a`. Floor and Ceil agree to the wei, so a
    ///      partial fill built on those numbers cannot see the mutation however many times it is
    ///      reached - which is why reaching the branch was never the whole problem. One wei of
    ///      released yield moves `a` to 10,000,000,002, leaves a remainder of 300, and separates
    ///      the two roundings in **both** observable outputs: shares burned and USDC set aside.
    ///      That exactness is asserted rather than described, in
    ///      `test_theRoundNumberFixtureCannotSeeThePartialFillRounding` below, because a fixture
    ///      that quietly stopped being exact would turn this test back into the thing it replaced.
    ///
    ///      **What would have to be true for this to pass without measuring anything.** Three
    ///      things, and all three are asserted before the rounding is looked at: the fill not being
    ///      partial at all (`remaining > 0`), nothing being serviced,
    ///      and the two roundings coinciding (`wouldBurnRoundedUp == expectedBurn + 1`). The last
    ///      is the one this repo has been bitten by fifteen times and the only one that is
    ///      invisible from the outcome.
    function test_R25F2_aPartialServiceBurnsOnlyTheGrossSharesItsCashCanFund() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _distributeYield(1);
        skip(Config.YIELD_STREAM_DURATION + 1);
        _lend(pool.available());

        uint256 idle = usdc.balanceOf(address(pool));
        uint256 supplyBefore = pool.totalSupply();
        uint256 assetsBefore = pool.totalAssets();

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        uint256 requestCash = Math.mulDiv(idle, shares, supplyBefore, Math.Rounding.Floor);
        uint256 expectedBurn = Math.mulDiv(requestCash, supplyBefore + 10 ** 3, assetsBefore + 1, Math.Rounding.Floor);
        uint256 wouldBurnRoundedUp =
            Math.mulDiv(requestCash, supplyBefore + 10 ** 3, assetsBefore + 1, Math.Rounding.Ceil);
        assertEq(wouldBurnRoundedUp, expectedBurn + 1, "fixture does not distinguish floor from ceiling");
        assertEq(pool.maxRequestRedeem(alice), expectedBurn, "cash-funded share maximum");

        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, expectedBurn, 0);
        (,, uint256 remaining,,) = pool.withdrawalRequest(alice);
        uint256 burned = supplyBefore - pool.totalSupply();
        assertEq(shares - remaining, burned, "every burned share must come off Alice's request");
        assertEq(burned, expectedBurn, "service burned a different gross-funded slice");
    }

    /// @notice The round-number fixture cannot tell Floor from Ceil. This is why the test above
    ///         recognizes and releases one wei of yield before it measures anything.
    /// @dev Reaching a branch and being able to see inside it are different properties, and this
    ///      file had the first without the second. The deterministic driver in
    ///      `LenderPool.invariants.t.sol` has reached the partial-fill branch since it was written,
    ///      and the Floor -> Ceil mutation survived it anyway, because on round numbers the two
    ///      roundings are the same number.
    ///
    ///      This asserts that exactness directly, so it is a fact under test rather than a
    ///      paragraph. If it ever goes red, `Config.RESERVE_RATIO_BPS`, `_decimalsOffset()` or
    ///      `DEPOSIT` has moved and every literal in the sibling test above has to be re-derived -
    ///      which is the correct outcome, since those literals are pinned to the same arithmetic.
    function test_theRoundNumberFixtureCannotSeeTheRequestMaximumRounding() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());
        uint256 idle = usdc.balanceOf(address(pool));

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 requestCash = Math.mulDiv(idle, shares, pool.totalSupply(), Math.Rounding.Floor);
        uint256 s = pool.totalSupply() + 10 ** 3;
        uint256 a = pool.totalAssets() + 1;
        assertEq(
            Math.mulDiv(requestCash, s, a, Math.Rounding.Floor),
            Math.mulDiv(requestCash, s, a, Math.Rounding.Ceil),
            "round fixture has stopped being exact"
        );

        uint256 serviceShares = pool.maxRequestRedeem(alice);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, serviceShares, 0);
        (,, uint256 remaining,,) = pool.withdrawalRequest(alice);
        assertGt(remaining, 0, "fixture: service must be partial");
        assertEq(shares - remaining, serviceShares, "service did not burn the reported maximum");
    }

    /// @notice Stale zero-value requests cannot mutate a fresh controller's request or cap usage.
    function test_R22F3_staleRequestsCannotMutateAFreshCanonicalCashRequest() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lendDownToNothingIdle();

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        uint256 exposure = pool.outstandingPrincipal();
        vm.prank(creditManager);
        pool.socialiseLoss(exposure);
        assertEq(pool.totalAssets(), 0, "fixture: total loss");
        assertEq(_depositCapUsage(pool), 0, "fixture: recognized book must be empty");

        uint256 freshAssets = 1_000e6;
        uint256 carolShares = _deposit(carol, freshAssets);
        vm.prank(carol);
        pool.requestWithdrawal(carolShares, carol);
        (uint256 carolId, address carolReceiver, uint256 carolStoredBefore,,) = pool.withdrawalRequest(carol);
        uint256 usageBeforeCancels = _depositCapUsage(pool);

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        vm.prank(bob);
        pool.cancelWithdrawalRequest();

        (uint256 carolIdAfter, address carolReceiverAfter, uint256 carolStoredAfter,,) = pool.withdrawalRequest(carol);
        assertEq(carolIdAfter, carolId, "stale cancellation changed Carol's request id");
        assertEq(carolReceiverAfter, carolReceiver, "stale cancellation changed Carol's receiver");
        assertEq(carolStoredAfter, carolStoredBefore, "stale cancellation changed Carol's shares");
        assertEq(pool.balanceOf(address(pool)), carolShares, "stale cancellation took fresh escrow shares");
        assertEq(_depositCapUsage(pool), usageBeforeCancels, "stale cancellation changed cap usage");

        vm.prank(carol);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(address(pool)), 0, "fresh cancel must empty escrow");
        assertEq(pool.balanceOf(carol), carolShares, "Carol must recover her fresh shares");
        assertEq(_depositCapUsage(pool), usageBeforeCancels, "fresh cancellation changed cap usage");
    }

    /// @notice A dust share split and zero-asset redeem cannot move cap usage.
    function test_R22F3_aDustTransferThenZeroAssetRedeemNoLongerErodesTheCap() public {
        uint256 aliceShares = _deposit(alice, 10);
        assertEq(aliceShares, 10_000, "fixture: the virtual offset must mint one thousand shares per asset-wei");

        uint256 assetsBefore = usdc.balanceOf(address(pool));
        uint256 headroomBefore = pool.maxDeposit(bob);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            pool.transfer(bob, 1);

            assertEq(pool.previewRedeem(1), 0, "fixture: each one-share position must redeem for zero assets");

            vm.prank(bob);
            uint256 assetsOut = pool.redeem(1, bob, bob);

            assertEq(assetsOut, 0, "fixture: each boundary must pay no assets");
            assertEq(usdc.balanceOf(address(pool)), assetsBefore, "fixture: no asset may leave the pool");
            assertEq(_depositCapUsage(pool), 10, "a zero-asset exit must not loosen the cap");
            assertEq(pool.maxDeposit(bob), headroomBefore, "cap headroom must not move when no asset moves");
        }
    }

    /// @notice A post-loss dust round trip follows its exact cash transitions.
    function test_R22F3_postLossDustRoundTripTracksExactCash() public {
        uint256 aliceShares = _deposit(alice, 10_000);
        assertGt(aliceShares, 0, "fixture: Alice must receive shares");
        _lend(1);

        vm.prank(creditManager);
        assertEq(pool.socialiseLoss(1), 1, "fixture: the one-wei loss must land");
        assertEq(_depositCapUsage(pool), 9_999, "fixture: the loss must reduce canonical cash by one wei");

        uint256 bobShares = _deposit(bob, 1);
        assertEq(_depositCapUsage(pool), 10_000, "dust deposit was not counted");
        vm.prank(bob);
        uint256 assetsOut = pool.redeem(bobShares, bob, bob);

        assertEq(_depositCapUsage(pool), 10_000 - assetsOut, "dust exit cap debit drift");
    }

    /// @notice Merging and splitting differently priced shares remains neutral to canonical cash.
    function test_R22F3_mergeAndSplitAreNeutralUntilCashActuallyLeaves() public {
        vm.prank(admin);
        pool.setDepositCap(50_000e6);

        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _distributeYield(2_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 bobAssets = 15_000e6;
        usdc.mint(bob, bobAssets - DEPOSIT);
        uint256 bobShares = _deposit(bob, bobAssets);
        uint256 usageBeforeTransfers = _depositCapUsage(pool);

        vm.prank(bob);
        pool.transfer(alice, bobShares);
        vm.prank(alice);
        pool.transfer(bob, bobShares);

        assertEq(pool.balanceOf(alice), aliceShares, "the split changed the anchor shares");
        assertEq(pool.balanceOf(bob), bobShares, "the split changed Bob's shares");
        assertEq(_depositCapUsage(pool), usageBeforeTransfers, "share merge or split changed cap usage");

        vm.prank(bob);
        uint256 assetsOut = pool.redeem(bobShares, bob, bob);

        assertEq(pool.balanceOf(alice), aliceShares, "the anchor shares must remain invested");
        assertEq(_depositCapUsage(pool), usageBeforeTransfers - assetsOut, "exit removed anything but cash paid");
    }

    /// @notice Matured recognized cash and NAV remain identical through repeated rotations.
    function test_depositCapUsage_matchesTheMatureBookUnderRepeatedRotation() public {
        vm.prank(admin);
        pool.setDepositCap(100_000e6);

        usdc.mint(carol, 20_000e6);
        vm.prank(carol);
        pool.deposit(20_000e6, carol);

        address rotator = makeAddr("rotator");
        vm.prank(rotator);
        usdc.approve(address(pool), type(uint256).max);

        for (uint256 epoch = 0; epoch < 10; epoch++) {
            usdc.mint(rotator, 5_000e6);
            vm.prank(rotator);
            pool.deposit(5_000e6, rotator);

            _distributeYield(2_000e6);
            skip(Config.YIELD_STREAM_DURATION + 1);

            uint256 held = pool.balanceOf(rotator);
            vm.prank(rotator);
            pool.redeem(held, rotator, rotator);

            assertEq(_depositCapUsage(pool), pool.totalAssets(), "mature recognized book drift");
            assertGt(pool.maxDeposit(carol), 0, "the pool must not have closed itself to deposits");
        }
    }

    /// @notice Marking the book down must never raise what the pool will lend.
    /// @dev Audit round 12, flagged by seven of twelve agents and extractable by none of them -
    ///      which is the signature of a lever waiting for the next change to make it reachable,
    ///      and the round-13 impairment fix is exactly that change. The old mark was zero across
    ///      the ordinary LTV band; a full-debt mark is large and routine, so the lever got long.
    ///
    ///      Both holdbacks in `available()` were denominated in `exitAssets()`, so an impairment
    ///      shrank the queue's reserved claim *and* the hot float, and lending capacity went **up**
    ///      as the book got worse. The adjacent NatSpec claimed the opposite.
    ///
    ///      Asserted as monotonicity rather than against a computed figure. An expected-value test
    ///      restates the implementation's own arithmetic and stays green when that arithmetic is
    ///      wrong in the same direction twice; "worse news never buys more lending" is the property
    ///      actually worth having, and it fails on the bug.
    function test_available_neverRisesWhenTheBookIsMarkedDown() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(2_000e6);

        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares / 2, alice);

        uint256 lendableBefore = pool.available();
        assertGt(lendableBefore, 0, "fixture: there must be something to lend in the first place");

        _impair(carol, 1_500e6);

        assertLe(pool.available(), lendableBefore, "a markdown must not free up lending capacity");

        // And deeper is not better either. The clamp at `outstandingPrincipal` means the reserve
        // stops growing, so this also pins that the two are not merely equal by accident.
        _impair(carol, 2_000e6);
        assertLe(pool.available(), lendableBefore, "nor does a deeper one");
    }

    /// @notice A deep markdown must not evict the withdrawal queue.
    /// @dev **This test used to assert `exitAssets() >= usdc.balanceOf(pool)`, and audit round 12
    ///      found that cannot fail on any code.** `exitReserve()` is clamped to
    ///      `outstandingPrincipal` and `totalAssets()` is `idle + outstandingPrincipal`, so
    ///      `exitAssets() >= idle` is an algebraic identity of the clamp - true against the fix,
    ///      true against the bug, true against a body that returned a constant. It was written
    ///      that day specifically to avoid vacuity and was vacuous.
    ///
    ///      It also aimed at the wrong state. The clamp only bites while the pool holds cash, and
    ///      the fixture guaranteed that by lending exactly `available()`, which holds the reserve
    ///      float back. **The state the queue exists for is the one where the pool holds nothing**,
    ///      and it is reachable: `maxWithdraw` is bounded by `unreservedIdle()`, which carries no
    ///      reserve holdback, so an unqueued lender can drain the float to zero. Then
    ///      `totalAssets()` is all principal, a full markdown takes `exitAssets()` to zero, and
    ///      every queued entry values at `owed == 0`.
    ///
    ///      The former shared settlement walk then took its dust-release branch,
    ///      deliberately, so that cash-free progress still happens when the pool is fully lent -
    ///      and treats "worth zero at today's exit price" as permanently worthless. One
    ///      permissionless call hands the whole queue back and whoever re-queues first takes the
    ///      head. A markdown is temporary; losing your place is not.
    function test_impairment_deepMarkdownLeavesTheRequestCancellable() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        uint256 bobsMax = pool.maxWithdraw(bob);
        vm.prank(bob);
        pool.withdraw(bobsMax, bob, bob);
        assertEq(usdc.balanceOf(address(pool)), 0, "fixture: pool cash");

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        _impair(carol, type(uint128).max);
        assertEq(pool.exitAssets(), 0, "fixture: full markdown");
        assertEq(pool.maxRequestRedeem(alice), 0, "cash-free request reports serviceable shares");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.UnauthorizedRequestOperator.selector, alice, bob));
        pool.serviceWithdrawalRequest(alice, 1, 0);
        assertEq(pool.balanceOf(address(pool)), aliceShares, "stranger changed escrow");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(alice), aliceShares, "controller could not recover marked shares");
        assertEq(pool.queuedShares(), 0, "cancel left a live request");
    }

    /// @notice The same refusal, with money in the pool. **This is the state nothing covered.**
    /// @dev The invariant suite excludes a refusal on a marked-down head from its wedge counter,
    ///      and its comment defers coverage to the test above. That test asserts
    ///      `usdc.balanceOf(address(pool)) == 0` in its own fixture, so it only ever runs at zero
    ///      idle, which is exactly where refusing is honest and uninteresting. Audit round 15 found
    ///      the state the exclusion actually admits - a marked-down head **with cash present** - was
    ///      covered by nothing anywhere, and it is the state both of that round's queue findings
    ///      live in.
    ///
    ///      One wei is not a flourish. `exitAssets()` is bounded below by the idle balance because
    ///      the reserve clamps to `outstandingPrincipal`, so one wei of idle is the smallest
    ///      non-zero exit book there is, and it is the boundary an attacker chooses a victim's side
    ///      of with a single free `withdraw()` beforehand.
    ///
    ///      **This records today's behaviour, and today's behaviour is a recorded open finding.**
    ///      The refusal protects the entry from being crystallised at nothing, and it stalls
    ///      everybody behind it for as long as the mark stands. Both halves are asserted, because a
    ///      test that asserted only the protection would read as though the branch were settled.
    function test_impairment_zeroValueRequestNeedsTheControllersExplicitZeroFloor() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        uint256 bobsMax = pool.maxWithdraw(bob);
        vm.prank(bob);
        pool.withdraw(bobsMax, bob, bob);
        _setIdleTo(1);

        uint256 requested = aliceShares / 4;
        vm.prank(alice);
        pool.requestWithdrawal(requested, alice);
        _impair(carol, type(uint128).max);
        assertEq(pool.previewRedeem(requested), 0, "fixture: marked request value");
        assertGt(pool.convertToAssets(requested), 0, "fixture: gross request value");

        uint256 maximum = pool.maxRequestRedeem(alice);
        if (maximum != 0) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, 0, 1));
            pool.serviceWithdrawalRequest(alice, maximum, 1);
        }
        assertEq(pool.balanceOf(address(pool)), requested, "floor failure burned marked shares");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(alice), aliceShares, "marked request was not cancellable");
    }

    /// @notice **One wei of idle must not turn a protected position into a total loss.**
    /// @dev Audit round 15, executed. The dust guard was conditioned on `owed == 0`, which is a
    ///      *truncation event*, rather than on `exitReserve() != 0`, which is its cause. The
    ///      difference is a cliff, and an attacker picks which side of it a victim lands on:
    ///
    ///      - at `idle == 0` the head values at zero, the guard fires, and the shares stay escrowed.
    ///        That is the protection working, and the sibling above asserts it.
    ///      - at `idle == 1` the head values at exactly one wei, so it misses the guard entirely and
    ///        falls into the full-fill branch, where `owed <= idle` burns **the whole entry** for a
    ///        single wei of USDC.
    ///
    ///      `exitAssets() >= idle` is an identity of the exposure clamp, so a single free
    ///      `withdraw()` before the mark sets which case a queued lender is in, for nothing. The
    ///      guard covered the measure-zero worst case and nothing one wei away from it, where the
    ///      harm is 99.99999%.
    ///
    ///      The head has to be worth at least half the supply for `owed` to round to one rather
    ///      than to zero, which is why this is a whole position rather than the quarter the sibling
    ///      queues. That is not an obstacle to an attacker: it is the lender with the most to lose.
    function test_impairment_oneWeiQuoteCannotBypassTheControllersFloor() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());
        uint256 bobsMax = pool.maxWithdraw(bob);
        vm.prank(bob);
        pool.withdraw(bobsMax, bob, bob);
        _setIdleTo(2);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        _impair(carol, type(uint128).max);
        uint256 maximum = pool.maxRequestRedeem(alice);
        uint256 quote = pool.previewRedeem(maximum);
        assertGt(maximum, 0, "fixture: no shares reach the execution-floor check");
        assertEq(quote, 0, "fixture: marked service quote is nonzero");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AssetsBelowMinimum.selector, quote, 2));
        pool.serviceWithdrawalRequest(alice, maximum, 2);
        assertEq(pool.queuedShares(), aliceShares, "floor failure crystallised the position");
        assertEq(pool.claimable(alice), 0, "floor failure made a claim");
    }

    /// @notice The manager-facing writers cannot revert, whatever they are handed.
    /// @dev **This is what lets the auction's exits of last resort stay unbrickable.** `cancel` and
    ///      `expireToWorkout` must survive a lender pool that reverts everything - the auction's
    ///      own header promises it - and the notification path reaches these three. Storage,
    ///      arithmetic and an event only: no external call, no transfer, and no subtraction or
    ///      addition that can leave the range.
    function testFuzz_impairment_writersAreTotal(uint256 a, uint256 b, uint256 c) public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        vm.startPrank(creditManager);
        pool.impair(bob, a);
        pool.impair(carol, b);
        pool.impair(bob, c);
        pool.setLossReserves(a, b);
        pool.setLossReserves(type(uint256).max, type(uint256).max);
        pool.releaseImpairment(bob);
        pool.releaseImpairment(carol);
        pool.releaseImpairment(bob);
        vm.stopPrank();

        assertEq(pool.totalImpairment(), 0, "releasing everything must return the sum to zero");
    }

    /// @dev The recognised-but-unplaced backlog prices into the exit immediately. Without it,
    ///      deleting the gate leaves a public counter anybody can read while the share price still
    ///      says nothing has happened - and `flushSocialisedLoss` is permissionless, so whoever
    ///      reads it first leaves at the old price.
    function test_lossReserves_backlogPricesIntoTheExitImmediately() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(4_000e6);

        uint256 exitBefore = pool.previewRedeem(shares);
        uint256 entryBefore = pool.previewDeposit(1_000e6);

        vm.prank(creditManager);
        pool.setLossReserves(1_500e6, 0);

        assertApproxEqAbs(pool.previewRedeem(shares), exitBefore - 1_500e6, 1, "the backlog was not priced in");
        assertEq(pool.previewDeposit(1_000e6), entryBefore, "entries must stay un-marked");
    }

    /// @dev Insurance nets once against the summed impairments. Netting it per borrower - which is
    ///      what the sizing rule reads like at first glance - spends the same fund twice the moment
    ///      two positions are in distress, and an under-mark is the finding rather than a rounding
    ///      choice.
    function test_lossReserves_insuranceCoverNetsOnceAcrossTwoBorrowers() public {
        _deposit(alice, DEPOSIT);
        _lend(6_000e6);

        _impair(bob, 1_000e6);
        _impair(carol, 1_000e6);
        vm.prank(creditManager);
        pool.setLossReserves(0, 1_000e6);

        // Gross 2,000 less a single 1,000 of cover. Netted per borrower it would be zero.
        assertEq(pool.exitReserve(), 1_000e6, "the insurance fund was spent against both positions");
    }

    /// @dev Insurance does not also net the backlog: `writeDownLoss` spends the fund first and
    ///      socialises only the remainder, so that figure is already post-insurance.
    function test_lossReserves_insuranceCoverDoesNotAlsoNetTheBacklog() public {
        _deposit(alice, DEPOSIT);
        _lend(6_000e6);

        vm.prank(creditManager);
        pool.setLossReserves(1_000e6, 5_000e6);

        assertEq(pool.exitReserve(), 1_000e6, "cover was double-spent against an already-net figure");
    }

    function test_lossReserves_isCreditManagerOnly() public {
        vm.expectRevert(LenderPool.NotCreditManager.selector);
        pool.setLossReserves(1e6, 0);
    }

    /// @notice A repayment larger than the recorded principal must not move the price in its block.
    /// @dev Round-11. The clamp turned a reversed write-down into an instantaneous share-price step,
    ///      which is precisely what the yield stream exists to prevent on the other leg.
    function test_repayPrincipal_surplusStreamsRatherThanStepping() public {
        _deposit(alice, DEPOSIT);
        _lend(4_000e6);

        // A write-down the repayment is about to reverse: principal recorded at 1,000 while 4,000
        // is genuinely coming back.
        vm.prank(creditManager);
        pool.socialiseLoss(3_000e6);

        uint256 assetsBefore = pool.totalAssets();
        _repay(4_000e6);

        assertEq(pool.totalAssets(), assetsBefore, "the surplus stepped the price in its own block");
        assertEq(pool.pendingYield(), 3_000e6, "the surplus is not in the stream");

        skip(Config.YIELD_STREAM_DURATION);
        assertApproxEqAbs(pool.totalAssets(), assetsBefore + 3_000e6, 2, "the surplus never landed");
    }

    /// @notice A delivery-block entrant cannot turn the streamed surplus into an immediate step.
    /// @dev **Order matters and this repo has paid for learning that.** Written the other way round
    ///      - repay, then deposit - the test passes against the unfixed contract, because the
    ///      depositor arrives after the step instead of in front of it. Mallory deposits first and
    ///      then calls the repayment herself, which is the permissionless `settlePrincipal` reaching
    ///      through, so she picks the block exactly as the finding describes.
    ///
    ///      Because Mallory holds shares when the surplus is delivered, she is part of that
    ///      delivery cohort and participates if she remains through the stream. This test proves
    ///      only that she cannot enter, trigger delivery and realise the whole gain immediately.
    function test_repayPrincipal_deliveryBlockEntrantCannotCaptureTheSurplusImmediately() public {
        _deposit(alice, DEPOSIT);
        _lend(4_000e6);
        vm.prank(creditManager);
        pool.socialiseLoss(3_000e6);

        uint256 mallorysShares = _deposit(bob, DEPOSIT);
        _repay(4_000e6);

        // `maxRedeem` resolved before the prank, not inside the call: it is itself a call, so
        // written as an inline argument it consumes the prank and the redeem runs as this contract.
        uint256 exitable = pool.maxRedeem(bob);
        vm.prank(bob);
        uint256 out = pool.redeem(exitable, bob, bob);

        assertLe(out, DEPOSIT, "a delivery-block entrant captured the streamed surplus immediately");
        assertGt(mallorysShares, 0, "the fixture must actually have minted her shares");
    }

    /// @dev The clamped surplus must not move the epoch clock. `lastYieldDistributeAt` is the only
    ///      input to the "pay out over at least as long as it took to accrue" rule, so a repayment
    ///      that wrote it would let anyone shorten the window the next epoch is rated over - which
    ///      is round-11's anti-just-in-time pin, reintroduced on this leg by the fix above.
    function test_repayPrincipal_doesNotMoveTheEpochAccrualClock() public {
        _deposit(alice, DEPOSIT);
        _lend(4_000e6);
        vm.prank(creditManager);
        pool.socialiseLoss(3_000e6);

        uint256 clockBefore = pool.lastYieldDistributeAt();
        skip(10 days);
        _repay(4_000e6);

        assertEq(pool.lastYieldDistributeAt(), clockBefore, "a repayment moved the epoch accrual clock");
    }

    // ── the exit, priced rather than refused (round 10 finding 7, round 11, then the research) ──
    //
    // The `test_exit_*` tests in this section were, until this commit, tests of a *refusal*.
    // Round-10 finding 7 was that a doomed loan sits in `outstandingPrincipal` at face value for the
    // whole auction and workout window, so a lender watching the auction can leave at a price
    // everybody knows is wrong; the answer shipped then was an exit gate. Round 11 found the gate
    // covered the ERC-4626 exits and missed the withdrawal queue, which is a permissionless
    // self-service exit and so was strictly the better door. Three independent research
    // passes then found the shape itself was wrong - no surveyed lending protocol freezes exits -
    // and the field's answer is to close the recognition gap instead, which is what `exitAssets()`
    // now does.
    //
    // So the *property* each of these protects survived and the mechanism under it changed. They
    // are kept, renamed, and rewritten to assert the price rather than the refusal, because a
    // property deleted alongside its implementation is how a finding gets reinstated - which has
    // now happened here twice.

    /// @dev Deposits, queueing and servicing all stay open, and so does the immediate exit. What
    ///      changes while an auction could still write a loss down is the number, not the door.
    function test_exit_staysOpenAtTheImpairedPriceWhileAnAuctionIsLive() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        // The lend is load-bearing since round 11: a reserve is clamped to what the pool has
        // actually lent, so with nothing out on loan this test would assert a mark-down that
        // correctly never happens. Sized so the idle balance still covers alice's whole holding -
        // otherwise `maxWithdraw` is pinned by liquidity and the price it quotes never shows.
        _lend(6_000e6);

        uint256 priceBefore = pool.previewRedeem(shares);
        assertGt(pool.maxWithdraw(alice), 0, "the fixture must start with an open exit");

        _impair(carol, 2_000e6);

        assertGt(pool.maxWithdraw(alice), 0, "the exit must stay open - the gate is what was deleted");
        assertLt(pool.previewRedeem(shares), priceBefore, "but it must not still be quoting the pre-loss price");
        assertGt(pool.maxRedeem(alice), 0);

        // And both immediate paths execute, at that price. `withdraw` first for a token amount,
        // then `redeem` for what is left, because the gate used to refuse them separately and each
        // one is its own door.
        vm.prank(alice);
        pool.withdraw(1e6, alice, alice);

        uint256 exitable = pool.maxRedeem(alice);
        vm.prank(alice);
        pool.redeem(exitable, alice, alice);

        assertEq(pool.balanceOf(alice), 0, "the fixture must have let her out completely");
        assertLt(usdc.balanceOf(alice), DEPOSIT, "alice left without carrying any of the expected loss");
    }

    /// @notice An open workout carries the *whole* debt, not a floor-bounded slice of it.
    /// @dev The longer of the two windows - up to `WORKOUT_MAX_DURATION` - and the one where a loss
    ///      is most nearly certain, because recovery is a manual off-chain redemption nobody has
    ///      paid yet. `CreditManager._impairmentFor` sizes it at the full debt for exactly that
    ///      reason, so the exit price stands back by the whole position. Under the gate this was
    ///      indistinguishable from a live auction: both simply returned zero.
    function test_exit_carriesTheWholeDebtWhileAWorkoutIsOpen() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        uint256 debt = 6_000e6;
        _lend(debt);

        uint256 before = pool.previewRedeem(shares);

        // A live auction's floor bounds the loss; an open workout does not, so the manager pushes
        // the whole debt. Both are `impair` calls - the escalation is the manager's job and
        // `Impairment.integration.t.sol` pins it. What this asserts is that the pool prices it.
        _impair(bob, debt);

        assertEq(pool.exitReserve(), debt, "the whole position must be standing behind the exit price");
        // Two equal holders, so alice's half of a 6,000 mark is 3,000.
        assertApproxEqAbs(pool.previewRedeem(shares), before - 3_000e6, 1, "the exit must carry half of it");
        assertGt(pool.maxWithdraw(alice), 0, "and the door still has to be open");
    }

    /// @notice The negative case, asserted separately on purpose. Pricing that marked every exit
    ///         down unconditionally would pass every test above while robbing every ordinary
    ///         withdrawal in the pool.
    function test_exit_paysTheFullPriceWhenNothingIsImpaired() public {
        uint256 shares = _deposit(alice, DEPOSIT);

        assertEq(pool.exitReserve(), 0);
        assertEq(pool.exitAssets(), pool.totalAssets(), "an unmarked pool must price both sides alike");
        assertEq(pool.maxWithdraw(alice), DEPOSIT);

        vm.prank(alice);
        uint256 out = pool.redeem(shares, alice, alice);
        assertEq(out, DEPOSIT);
    }

    /// @notice The mark is an estimate, so it has to be able to come back off.
    /// @dev The gate's version of this was "the exit reopens". The price's version is stronger and
    ///      is what the `/lend` copy promises in as many words: if the recovery is better than
    ///      feared, the pool's value goes back up. A one-way markdown would be a loss recognised
    ///      against a loan that was repaid in full.
    function test_exit_priceRecoversWhenTheImpairmentIsReleased() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(6_000e6);
        uint256 before = pool.previewRedeem(shares);

        _impair(carol, 2_000e6);
        assertLt(pool.previewRedeem(shares), before, "the fixture must actually have marked it down");

        vm.prank(creditManager);
        pool.releaseImpairment(carol);

        assertEq(pool.exitReserve(), 0);
        assertEq(pool.previewRedeem(shares), before, "releasing must put the exit price back");

        uint256 exitable = pool.maxRedeem(alice);
        assertEq(exitable, shares, "the fixture must leave her able to take the whole holding");
        vm.prank(alice);
        pool.redeem(exitable, alice, alice);
        assertEq(usdc.balanceOf(alice), before, "and the money has to actually come out at it");
    }

    /// @notice **A loss already recognised on the manager's books but not yet absorbed here is
    ///         carried by the exit price too**, and this is the branch of the gate that had to be
    ///         rebuilt rather than argued away.
    /// @dev Audit round 11 found it: such a loss outlives the auction *and* the workout that
    ///      produced it, so the per-borrower impairment cannot cover it - the auction it was keyed
    ///      to has already released. `flushSocialisedLoss` is permissionless, so without a term for
    ///      it the deletion of the gate would have left a public counter anybody can read while the
    ///      share price still said nothing had happened, and whoever read it first would leave at
    ///      the old price. `unplacedLoss` is that term: `CreditManager._pushLossReserves` mirrors
    ///      `unsocialisedLoss` into it after every write, and `exitReserve()` adds it on top of the
    ///      insurance-netted impairments because it is already a post-insurance figure.
    function test_exit_alreadyCarriesARecognisedButUnplacedLoss() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(6_000e6);

        uint256 exitBefore = pool.previewRedeem(shares);
        uint256 entryBefore = pool.previewDeposit(1_000e6);

        // Every auction has closed and every impairment has been released. On the old gate this
        // read as "all clear"; there is nothing keyed to a borrower left to reserve against.
        assertEq(pool.totalImpairment(), 0, "fixture: no live position, so nothing per-borrower");
        vm.prank(creditManager);
        pool.setLossReserves(1_000e6, 0);

        assertEq(pool.exitReserve(), 1_000e6, "a recognised loss is still a loss");
        // Two equal holders, so alice's half of it is 500.
        assertApproxEqAbs(pool.previewRedeem(shares), exitBefore - 500e6, 1, "the leaver must carry her half");
        assertEq(pool.previewDeposit(1_000e6), entryBefore, "and the entrant must still not get the discount");

        // The flush that places it must then not move the price a second time: the counter comes
        // off `unplacedLoss` as the loss lands on `outstandingPrincipal`. This is the pair
        // `flushSocialisedLoss` runs, in the order it runs them.
        uint256 priced = pool.previewRedeem(shares);
        vm.startPrank(creditManager);
        pool.socialiseLoss(1_000e6);
        pool.setLossReserves(0, 0);
        vm.stopPrank();

        assertApproxEqAbs(pool.previewRedeem(shares), priced, 1, "placing the loss double-counted it");
    }

    /// @dev The queue is not a worse deal than the front door and it is not a better one either.
    ///      Joining and cancelling both stay open - neither was ever the hazard - and what a queued
    ///      lender is actually paid is the same marked-down number an immediate exit would have
    ///      handed them.
    function test_exit_requestingDuringALiquidationBuysNoBetterPrice() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(4_000e6);
        _impair(carol, 2_000e6);

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 serviceable = pool.maxRequestRedeem(alice);
        uint256 requestPrice = pool.previewRedeem(serviceable);
        assertLt(requestPrice, pool.convertToAssets(serviceable), "fixture: request is not marked");

        vm.prank(alice);
        uint256 paid = pool.serviceWithdrawalRequest(alice, serviceable, requestPrice);
        assertEq(paid, requestPrice, "request service escaped the live mark");
        assertEq(pool.claimable(alice), requestPrice, "marked payout was not set aside");
    }

    /// @notice Finding 7 stated as the property it protects, rather than as its implementation.
    /// @dev **Kept under its original name across three different mechanisms, which is the point.**
    ///      Under the gate this test asserted that alice was *refused*, and refusal was only ever a
    ///      proxy for the thing that matters. The thing that matters is this: leaving the instant
    ///      the liquidation opens pays her exactly what staying until the loss had landed would
    ///      have paid her. She may go - she simply cannot gain by going.
    ///
    ///      Run as two whole timelines from one snapshot rather than as a single sequence with an
    ///      arithmetic expectation written down beside it. A hand-computed target here would be a
    ///      fixture literal pinning four parameters at once, and it would keep passing while
    ///      meaning something else; the counterfactual is the claim itself.
    function test_exit_cannotOutrunALossThatIsAlreadyComing() public {
        uint256 clean = vm.snapshotState();

        uint256 leftEarly = _leaveFirstThenTakeTheLoss();
        vm.revertToState(clean);

        uint256 stayedPut = _takeTheLossFirstThenLeave();

        assertApproxEqAbs(leftEarly, stayedPut, 2, "leaving ahead of the loss paid better than staying");
        assertLt(leftEarly, DEPOSIT, "the fixture must actually have cost her something");
    }

    /// @dev Two equal holders and 4,000 out on loan, of which 2,000 is expected to be lost. The
    ///      figures are deliberately not asserted in the helpers - only the two totals are compared
    ///      - so the test cannot pass by both paths being wrong in the same way.
    function _outrunFixture() private returns (uint256 aliceShares) {
        aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(4_000e6);
        _impair(carol, 2_000e6);
    }

    function _leaveFirstThenTakeTheLoss() private returns (uint256) {
        _outrunFixture();

        // Read first: `vm.prank` covers exactly one call, and a view in the argument list eats it.
        uint256 exitable = pool.maxRedeem(alice);
        assertGt(exitable, 0, "the exit has to be open for this half to be a test of anything");
        vm.prank(alice);
        pool.redeem(exitable, alice, alice);

        // The auction fills short. `writeDownLoss` socialises and only then drops the mark, in that
        // order and for the reason set out there, so this mirrors it.
        vm.startPrank(creditManager);
        pool.socialiseLoss(2_000e6);
        pool.releaseImpairment(carol);
        vm.stopPrank();

        return usdc.balanceOf(alice);
    }

    function _takeTheLossFirstThenLeave() private returns (uint256) {
        _outrunFixture();

        vm.startPrank(creditManager);
        pool.socialiseLoss(2_000e6);
        pool.releaseImpairment(carol);
        vm.stopPrank();

        uint256 exitable = pool.maxRedeem(alice);
        vm.prank(alice);
        pool.redeem(exitable, alice, alice);

        return usdc.balanceOf(alice);
    }

    /// @notice Audit round 11's composite, which is the path a gate could never have covered.
    /// @dev The finding-7 gate was put on `withdraw`, `redeem`, `maxWithdraw` and `maxRedeem` - the
    ///      complete set of ERC-4626 exits and not the complete set of ways USDC leaves the pool.
    ///      request creation, settlement and claim used to compose without controller authority in
    ///      one transaction, so a lender could join the queue and pay themselves out at the pre-loss
    ///      price in the block the auction opened. Worse than the door that had been shut: servicing
    ///      draws on `_poolBalance()` where `redeem` is bounded by `unreservedIdle()`, so the queue
    ///      route also reaches the `RESERVE_RATIO_BPS` float.
    ///
    ///      That extra reach is *still true* and is now harmless, which is the whole argument for
    ///      pricing over gating: the composite gets a lender more liquidity, never a better price.
    ///      A gate has to enumerate every door and this one was missed; the price is on the
    ///      valuation every door shares.
    function test_exit_controllerServiceCannotTakeTheUnimpairedPrice() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(6_000e6);
        _impair(carol, 3_000e6);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        uint256 serviceable = pool.maxRequestRedeem(alice);
        uint256 impairedPrice = pool.previewRedeem(serviceable);
        uint256 unimpairedPrice = pool.convertToAssets(serviceable);
        assertLt(impairedPrice, unimpairedPrice, "fixture: prices do not diverge");

        vm.prank(alice);
        uint256 paid = pool.serviceWithdrawalRequest(alice, serviceable, impairedPrice);
        assertEq(paid, impairedPrice, "controller service did not pay the exit price");
        assertLt(paid, unimpairedPrice, "controller service escaped at the gross price");
    }

    /// @dev The other half: someone already queued before the liquidation opened is marked down
    ///      like everybody else. Their shares stay outstanding and stay exposed while they wait,
    ///      which is the promise the whole queue design rests on - and it is a promise about the
    ///      valuation, so it survived the mechanism change underneath it.
    function test_exit_anExistingRequestIsMarkedDownLikeEveryoneElse() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(6_000e6);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        (,,, uint256 serviceableBefore, uint256 owedBefore) = pool.withdrawalRequest(alice);

        _impair(carol, 3_000e6);
        (,,, uint256 serviceableAfter, uint256 owedAfter) = pool.withdrawalRequest(alice);
        assertEq(serviceableAfter, serviceableBefore, "mark changed the cash-funded share maximum");
        assertApproxEqAbs(owedAfter, owedBefore - 1_050e6, 2, "request did not carry its pro-rata mark");

        vm.startPrank(creditManager);
        pool.socialiseLoss(3_000e6);
        pool.releaseImpairment(carol);
        vm.stopPrank();
        assertApproxEqAbs(pool.previewRedeem(serviceableAfter), owedAfter, 2, "realised loss repriced the request");

        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, serviceableAfter, owedAfter - 2);
        assertApproxEqAbs(pool.claimable(alice), owedAfter, 2, "service did not preserve the marked price");
    }

    /// @notice The credit manager can be an address with no code at all.
    /// @dev **Audit round 11, stated as a property rather than as a diff.** The round-10 exit gate
    ///      read the manager, then that manager's auction, twice - three unguarded typed calls
    ///      sitting on the only ERC-4626 exit, with no owner escape while principal was out, since
    ///      `setCreditManager` refuses at `outstandingPrincipal != 0`. A manager or auction that
    ///      reverted would have bricked every withdrawal in the pool permanently.
    ///
    ///      With the gate gone the pool calls nothing but USDC: the impairment is pushed in by the
    ///      manager and read from local storage. An EOA has no code, so any typed call into it
    ///      reverts - which makes "this fixture works at all" a complete proof that no such call is
    ///      left. Every manager-facing writer and every lender-facing exit is exercised below for
    ///      that reason; a survivor on any one path would fail here and nowhere else.
    function test_creditManager_needsNoCodeAtAll() public {
        LenderPool fresh = new LenderPool(IERC20(address(usdc)), admin);
        address bare = makeAddr("bareManager");
        assertEq(bare.code.length, 0, "fixture: the manager must genuinely have no code");

        vm.prank(admin);
        fresh.setCreditManager(bare);

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(fresh), type(uint256).max);
        uint256 shares = fresh.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Every writer the manager owns.
        vm.startPrank(bare);
        fresh.lend(4_000e6);
        fresh.impair(bob, 1_000e6);
        fresh.setLossReserves(200e6, 50e6);
        vm.stopPrank();

        assertGt(fresh.exitReserve(), 0, "fixture: something must be marked, or the exits prove nothing");

        // Every read on the exit path.
        assertGt(fresh.maxWithdraw(alice), 0);
        assertGt(fresh.maxRedeem(alice), 0);
        assertGt(fresh.previewRedeem(shares), 0);
        assertGt(fresh.available(), 0);
        assertGt(fresh.unreservedIdle(), 0);

        // The queue exit, end to end. **The mark comes off first, and audit round 16 is why:** the
        // walk refuses to crystallise a live entry while a reserve stands, so leaving it up would
        // make this half assert the refusal rather than the payout. The reserve has already done
        // its job above - it proved every *read* on the exit path answers with a bare address as
        // the manager, which is what this test is about.
        vm.startPrank(bare);
        fresh.releaseImpairment(bob);
        fresh.setLossReserves(0, 0);
        vm.stopPrank();
        assertEq(fresh.exitReserve(), 0, "fixture: the queue leg needs the mark off to reach a payout");

        vm.prank(alice);
        fresh.requestWithdrawal(shares / 2, alice);
        uint256 serviceable = fresh.maxRequestRedeem(alice);
        uint256 requestQuote = fresh.previewRedeem(serviceable);
        vm.prank(alice);
        fresh.serviceWithdrawalRequest(alice, serviceable, requestQuote);
        vm.prank(alice);
        fresh.claim();

        // And the immediate one.
        uint256 exitable = fresh.maxRedeem(alice);
        assertGt(exitable, 0);
        vm.prank(alice);
        fresh.redeem(exitable, alice, alice);

        assertGt(usdc.balanceOf(alice), 0, "nothing came out, so nothing was proved");
    }

    // ── withdrawals: immediate ───────────────────────────────────────────────

    /// @dev The honesty property. `maxWithdraw` must describe what can be taken now, because the
    ///      alternative design - silently turning a withdrawal into a queue ticket - makes this
    ///      number a lie to every integrator that reads it.
    function test_maxWithdrawReportsWhatCanActuallyBeTakenNow() public {
        _deposit(alice, DEPOSIT);
        _lend(8_000e6);

        assertEq(pool.maxWithdraw(alice), 2_000e6);

        vm.prank(alice);
        pool.withdraw(2_000e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 2_000e6);

        assertEq(pool.maxWithdraw(alice), 0);
    }

    function test_withdrawBeyondIdleRevertsRatherThanQueueingSilently() public {
        _deposit(alice, DEPOSIT);
        _lend(8_000e6);

        vm.prank(alice);
        vm.expectRevert();
        pool.withdraw(5_000e6, alice, alice);
    }

    // ── withdrawals: the queue ───────────────────────────────────────────────

    function test_requestWithdrawal_escrowsSharesAndRecordsAControllerRequest() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        assertEq(pool.balanceOf(alice), 0, "shares moved to escrow");
        assertEq(pool.balanceOf(address(pool)), shares);
        assertEq(pool.queuedShares(), shares);
        assertEq(pool.totalSupply(), shares, "escrowed shares remain outstanding");

        (uint256 requestId, address receiver, uint256 storedShares, uint256 serviceable, uint256 assets) =
            pool.withdrawalRequest(alice);
        assertEq(requestId, 1, "first request id");
        assertEq(receiver, alice, "fixed receiver");
        assertEq(storedShares, shares, "stored shares");
        assertEq(serviceable, pool.maxRequestRedeem(alice), "serviceable shares");
        assertEq(assets, pool.previewRedeem(serviceable), "serviceable assets");
    }

    /// @dev **The reason escrowed shares stay live.** Burning at request time would let a lender
    ///      who sees trouble queue, stop being exposed, and leave the loss to whoever stayed -
    ///      which is exactly the incentive that turns a wobble into a run.
    function test_requestedLendersTakeTheirShareOfALossLikeEveryoneElse() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        uint256 owedBefore = pool.previewRedeem(aliceShares);

        vm.prank(creditManager);
        pool.socialiseLoss(2_000e6);

        uint256 owedAfter = pool.previewRedeem(aliceShares);
        assertLt(owedAfter, owedBefore, "requesting became an exit from risk");
        assertEq(owedAfter, pool.convertToAssets(bobShares), "requested and unrequested holders took different damage");
    }

    /// @dev Equally, they keep earning while they wait. The symmetry is the point: escrow is not
    ///      a penalty box, it is simply not an exit.
    /// @dev Escrowed shares stay outstanding, so they keep earning. Since finding 6 the earning
    ///      arrives on a clock rather than in a step, and this test says so in both directions:
    ///      waiting in the queue is not an exit from the stream, and it is not early access to it
    ///      either.
    function test_requestedLendersKeepEarningWhileTheyWait() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 owedBefore = pool.previewRedeem(shares);

        _distributeYield(1_000e6);
        assertEq(pool.previewRedeem(shares), owedBefore, "yield stepped at delivery for a request");

        skip(Config.YIELD_STREAM_DURATION);
        assertGt(pool.previewRedeem(shares), owedBefore, "request shares stopped earning");
    }

    function test_requestWithdrawal_refusesASecondOne() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.startPrank(alice);
        pool.requestWithdrawal(shares / 2, alice);
        (uint256 requestId,,,,) = pool.withdrawalRequest(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AlreadyQueued.selector, requestId));
        pool.requestWithdrawal(shares / 2, alice);
        vm.stopPrank();
    }

    /// @dev PRD §6.4: the queue cannot be jumped.
    function test_requestsHaveNoOrderAndOneControllerCannotMutateAnother() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        _setIdleTo(2 * DEPOSIT);

        (uint256 aliceId, address aliceReceiver, uint256 aliceBefore,,) = pool.withdrawalRequest(alice);
        uint256 bobMaximum = pool.maxRequestRedeem(bob);
        vm.prank(bob);
        pool.serviceWithdrawalRequest(bob, bobMaximum, 0);

        (uint256 aliceIdAfter, address aliceReceiverAfter, uint256 aliceAfter,,) = pool.withdrawalRequest(alice);
        assertEq(aliceIdAfter, aliceId, "Bob changed Alice's request id");
        assertEq(aliceReceiverAfter, aliceReceiver, "Bob changed Alice's receiver");
        assertEq(aliceAfter, aliceBefore, "Bob changed Alice's stored shares");
        assertGt(pool.claimable(bob), 0, "Bob could not choose his own service timing");
    }

    /// @dev PRD §6.4: partial fills. One large request must not block every small one behind it
    ///      until it can be paid in full.
    function test_serviceWithdrawalRequest_partiallyServicesWithoutStalling() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        _setIdleTo(3_000e6);
        uint256 serviceable = pool.maxRequestRedeem(alice);
        uint256 quoted = pool.previewRedeem(serviceable);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, serviceable, quoted);

        _claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 3_000e6, 1, "cash-funded service payout");
        (,, uint256 remainingShares,,) = pool.withdrawalRequest(alice);
        assertGt(remainingShares, 0, "partial service cleared the whole request");
        assertApproxEqAbs(pool.previewRedeem(remainingShares), DEPOSIT - 3_000e6, 2, "remaining request value");
    }

    /// @notice A deterministic partial service frees exactly the cash made claimable.
    function test_R23F12_aPartialServiceDebitsCapUsageByTheExactClaim() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _distributeYield(333_333_333);
        skip(Config.YIELD_STREAM_DURATION);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (,, uint256 entryShares,,) = pool.withdrawalRequest(alice);

        _setIdleTo(3_000e6);
        uint256 sharesToService = pool.maxRequestRedeem(alice);
        uint256 quoted = pool.previewRedeem(sharesToService);
        uint256 usageBefore = _depositCapUsage(pool);
        uint256 claimsBefore = pool.totalClaimable();
        uint256 rawBefore = usdc.balanceOf(address(pool));
        vm.prank(alice);
        uint256 assetsOut = pool.serviceWithdrawalRequest(alice, sharesToService, quoted);

        (,, uint256 entrySharesAfter,,) = pool.withdrawalRequest(alice);

        assertGt(entrySharesAfter, 0, "fixture: service was not partial");
        assertEq(entryShares - entrySharesAfter, sharesToService, "service burned the wrong request slice");
        assertEq(assetsOut, quoted, "service departed from its quote");
        assertGt(assetsOut, 0, "fixture: service made no claim");
        assertEq(_depositCapUsage(pool), usageBefore - assetsOut, "partial service cap debit drift");
        assertEq(pool.totalClaimable(), claimsBefore + assetsOut, "partial service claim drift");
        assertEq(usdc.balanceOf(address(pool)), rawBefore, "service transferred claim cash early");
    }

    function test_serviceWithdrawalRequest_deletesTheRequestWhenFullyPaid() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        _setIdleTo(DEPOSIT);

        uint256 requestQuote = pool.previewRedeem(shares);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, shares, requestQuote);

        assertEq(pool.queuedShares(), 0);
        assertEq(pool.balanceOf(address(pool)), 0, "escrow emptied");
        assertEq(pool.totalSupply(), 0, "shares burned");
        (uint256 requestId, address receiver, uint256 remaining, uint256 serviceable, uint256 assets) =
            pool.withdrawalRequest(alice);
        assertEq(requestId, 0);
        assertEq(receiver, address(0));
        assertEq(remaining, 0);
        assertEq(serviceable, 0);
        assertEq(assets, 0);
    }

    /// @dev The test above passes for a reason that has nothing to do with the queue: the first
    ///      deposit mints `S = 1000 * A`, so `(A+1)/(S+1000)` is exactly 1/1000 and both of
    ///      request service's conversions are lossless. Every request test in this file inherits that
    ///      alignment. One epoch of yield destroys it, and yield is the pool's normal operation -
    ///      so the aligned case is the special one and it is the only case being tested.
    ///
    ///      With the ratio inexact, `convertToAssets` then `convertToShares` both floor, so the
    ///      shares burned come back short of the shares owed and the entry never reaches zero.
    function test_serviceWithdrawalRequest_clearsAnInexactShareRatio() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _distributeYield(333_333_333);
        skip(Config.YIELD_STREAM_DURATION);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        _setIdleTo(pool.totalAssets());
        uint256 quoted = pool.previewRedeem(shares);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, shares, quoted);

        assertEq(pool.queuedShares(), 0, "an inexact residual left the request live");
        assertEq(pool.balanceOf(address(pool)), 0, "escrow emptied");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.WithdrawalRequestNotFound.selector, alice));
        pool.cancelWithdrawalRequest();
    }

    /// @dev The consequence, and the reason the entry above matters beyond one lender's tidiness.
    ///      An entry that cannot be cleared is at the head forever. `convertToAssets(residual)`
    ///      floors to zero, so servicing must release and step past it: otherwise everyone behind
    ///      is blocked, the former shared settlement reverted for good, and because `queuedShares` never returned
    ///      to zero, `available()` is pinned at zero and the pool can never lend again.
    ///
    ///      **This test could not enter the branch it is named for until audit round 15, and it
    ///      would have passed with the former dust branch deleted entirely.**
    ///      Observed, not argued: deleting `if (convertToAssets(shares) != 0) break;` leaves the
    ///      old version green. It queued two lenders holding whole positions and funded both, so
    ///      no entry was ever worth zero and no release ever ran. The dust is now real and is
    ///      asserted to be dust before the act, because the premise is the test.
    ///
    ///      One share-wei is dust by construction here: at a decimals offset of three the price is
    ///      about a thousand shares to the asset-wei, so any conversion of one share floors to
    ///      nothing. Asserted rather than assumed, so a change to the offset fails here loudly
    ///      instead of quietly retiring the branch.
    function test_dustRequestIsIsolatedAndCancellable() public {
        _deposit(alice, DEPOSIT);
        uint256 before = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(1, alice);
        assertEq(pool.maxRequestRedeem(alice), 0, "one share-wei is unexpectedly cash funded");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.ServiceSharesExceedMaximum.selector, 1, 0));
        pool.serviceWithdrawalRequest(alice, 1, 0);

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.balanceOf(alice), before, "dust cancellation did not return the share");
        assertEq(pool.queuedShares(), 0, "dust request stayed live");
    }

    /// @dev Cancelled entries consume `maxEntries` as they are stepped over, so a call can spend
    ///      its whole budget on husks and pay nobody. That much is fine - it is what bounding the
    ///      call is for. What is not fine is reverting afterwards, because the revert undoes the
    ///      head advance the stepping just made, so the next call starts from the same place and
    ///      fails the same way. The queue could then only be serviced by a single call with
    ///      `maxEntries` greater than the whole run of husks, and any lender can lengthen that run
    ///      at will by queueing and cancelling behind someone else. Past a few thousand it does not
    ///      fit in a block and the queue is shut permanently.
    ///
    ///      Found by the invariant suite, which reached it in nine calls.
    function test_repeatedCancelAndRequestDoesNotCreateSharedHusks() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        uint256 priorId;
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            pool.requestWithdrawal(shares, alice);
            (uint256 requestId,,,,) = pool.withdrawalRequest(alice);
            assertGt(requestId, priorId, "request id did not advance");
            priorId = requestId;
            vm.prank(alice);
            pool.cancelWithdrawalRequest();
        }
        assertEq(pool.queuedShares(), 0, "cancel cycle left requested shares");
        assertEq(pool.balanceOf(alice), shares, "cancel cycle lost shares");
    }

    /// @dev The queue has first call on every dollar. A pool that lends out money it already owes
    ///      to someone who has asked for it is not short of liquidity, it is choosing sides.
    function test_lendingIsRefusedWhileAnyoneIsQueued() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        assertEq(pool.available(), 0);
        _repay(5_000e6);
        assertEq(pool.available(), 0, "returned principal belongs to the queue first");

        vm.prank(creditManager);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.InsufficientLiquidity.selector, 1e6, 0));
        pool.lend(1e6);
    }

    /// @dev A lender whose shares are escrowed with no way back would be stranded exactly when the
    ///      queue cannot clear, which is the situation the queue exists for.
    function test_cancelReturnsSharesAndAllowsANewRequestId() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available() / 2);

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (uint256 firstId,,,,) = pool.withdrawalRequest(alice);
        vm.prank(alice);
        pool.cancelWithdrawalRequest();

        assertEq(pool.balanceOf(alice), shares);
        assertEq(pool.queuedShares(), 0);
        assertGt(pool.available(), 0, "pool did not reopen after cancel");

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (uint256 secondId, address receiver, uint256 storedShares,,) = pool.withdrawalRequest(alice);
        assertGt(secondId, firstId, "request id was reused");
        assertEq(receiver, alice, "new fixed receiver");
        assertEq(storedShares, shares, "new stored shares");
    }

    function test_cancelRevertsWithNoControllerRequest() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.WithdrawalRequestNotFound.selector, alice));
        pool.cancelWithdrawalRequest();
    }

    /// @dev A cancelled entry is left in place with zero shares so indices stay stable in events.
    ///      Servicing has to step over it rather than stop at it.
    function test_cancelledRequestCannotBlockAnotherController() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        vm.prank(alice);
        pool.cancelWithdrawalRequest();

        _setIdleTo(DEPOSIT);
        uint256 bobMaximum = pool.maxRequestRedeem(bob);
        vm.prank(bob);
        pool.serviceWithdrawalRequest(bob, bobMaximum, 0);
        assertGt(pool.claimable(bob), 0, "Alice's cancellation blocked Bob");
        assertEq(pool.claimable(alice), 0);
    }

    function test_serviceRequiresControllerOrOptedInOperatorAndIsShareBounded() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 maximum = pool.maxRequestRedeem(alice);
        address keeper = makeAddr("keeper");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.UnauthorizedRequestOperator.selector, alice, keeper));
        pool.serviceWithdrawalRequest(alice, maximum, 0);

        vm.prank(alice);
        pool.setRequestOperator(keeper, true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.ServiceSharesExceedMaximum.selector, maximum + 1, maximum));
        pool.serviceWithdrawalRequest(alice, maximum + 1, 0);

        vm.prank(keeper);
        pool.serviceWithdrawalRequest(alice, maximum, 0);
        assertGt(pool.claimable(alice), 0, "approved operator could not service");
    }

    /// @dev Two different "nothing to do" states, and they are worth telling apart. An empty queue
    ///      means nobody is waiting; a queue with no idle USDC behind it means somebody is waiting
    ///      and the money has not come back yet. A keeper polling this needs to know which.
    function test_serviceDistinguishesMissingRequestFromAnUnfundedRequest() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.WithdrawalRequestNotFound.selector, alice));
        pool.serviceWithdrawalRequest(alice, 1, 0);

        _deposit(alice, DEPOSIT);
        _lend(pool.available());
        uint256 immediate = pool.maxWithdraw(alice);
        vm.prank(alice);
        pool.withdraw(immediate, alice, alice);
        uint256 remainingShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(remainingShares, alice);
        assertEq(pool.maxRequestRedeem(alice), 0, "fixture request is funded");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.ServiceSharesExceedMaximum.selector, 1, 0));
        pool.serviceWithdrawalRequest(alice, 1, 0);
    }

    /// @dev The invariant that has to survive every path above: escrowed shares are exactly the
    ///      shares this contract holds, and both are part of the supply the share price divides.
    // ── audit round 10 ───────────────────────────────────────────────────────

    /// @dev Round 10, finding 2. `available()` used to return 0 whenever anyone was queued, at any
    ///      size. One wei of USDC buys about a thousand shares at three decimals of offset, and a
    ///      request worth zero asset-wei zeroed the whole lending book - every borrow in the
    ///      protocol reverted, and the dust-release path handed the shares straight back so it cost
    ///      gas to repeat and nothing to hold.
    function test_available_isNotFrozenByADustWithdrawalRequest() public {
        _deposit(alice, DEPOSIT);
        uint256 before = pool.available();
        assertGt(before, 0);

        usdc.mint(bob, 1);
        vm.startPrank(bob);
        pool.deposit(1, bob);
        pool.requestWithdrawal(pool.balanceOf(bob), bob);
        vm.stopPrank();

        assertGt(pool.queuedShares(), 0, "the fixture must actually have queued something");
        assertApproxEqAbs(pool.available(), before, 1e6, "a dust request took the whole book");

        // And the borrow path is genuinely still open, not merely reporting a number.
        _lend(pool.available());
    }

    /// @dev Round 10, finding 2, the other half: a queue entry that *is* material still holds its
    ///      claim back. The fix is proportional, not an abandonment of the rule.
    function test_available_stillWithholdsWhatTheQueueIsOwed() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        assertEq(pool.available(), 0, "the queue is owed everything the pool holds");
    }

    /// @dev Round 10, finding 3. The payout used to be a push to a caller-chosen receiver from
    ///      inside the shared FIFO loop, so one entry naming a blacklisted address reverted every
    ///      shared settlement call forever, freezing every lender behind it and all lending with it.
    ///      `MockUSDC` models the blacklist because real USDC on Base has one.
    function test_requestServiceSurvivesAReceiverThatCannotBePaid() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());

        address frozen = makeAddr("blacklisted");
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, frozen);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        usdc.setBlocked(frozen, true);
        _setIdleTo(2 * DEPOSIT);

        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, aliceShares, 0);
        vm.prank(bob);
        pool.serviceWithdrawalRequest(bob, bobShares, 0);
        assertEq(pool.queuedShares(), 0, "blocked receiver stopped independent service");
        assertEq(pool.claimable(bob), DEPOSIT, "Bob was not paid");

        vm.prank(frozen);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, frozen));
        pool.claim();
        _claim(bob);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
    }

    function test_claim_revertsWithNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(LenderPool.NothingToClaim.selector);
        pool.claim();
    }

    // ── audit round 22, findings 12 and 17: the unswept `*For` member ────────
    //
    // Round 21 swept `claimSurplus`, `claimBounty` and `claimReward` into `*For` variants in one
    // commit and stopped at the pool, which was outside that stream's files. Five agents found the
    // gap independently in round 22. Two of them BUILT `claimFor` and measured OPPOSITE results,
    // and both were right - so the pair of tests below is the finding's real answer: one measures
    // the half that closes, one measures the half that does not, and neither is meaningful alone.

    /// @dev Stage a serviced entry whose receiver is `receiver` and whose owner is `alice`, leaving
    ///      `DEPOSIT` of USDC set aside under the receiver's name and the entry gone from the queue.
    function _serviceInFavourOf(address receiver) internal returns (uint256 setAside) {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _lend(pool.available());
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, receiver);
        _setIdleTo(DEPOSIT);
        uint256 quoted = pool.previewRedeem(aliceShares);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, aliceShares, quoted);
        setAside = pool.claimable(receiver);
        assertGt(setAside, 0, "fixture: nothing was set aside for the receiver");
    }

    /// @notice THE HALF `claimFor` CLOSES: a receiver that cannot re-issue the call.
    /// @dev The receiver here is a contract with no functions and no fallback. It can hold USDC -
    ///      an ERC-20 transfer does not call its destination - and it can never call `claim()`.
    ///      Under `claim()` alone that money is stranded for the life of an immutable contract.
    ///      A bystander with no relationship to the pool recovers it, **to the receiver**.
    function test_claimFor_recoversMoneyFromAReceiverThatCannotCall() public {
        address mute = address(new MuteWallet());
        uint256 setAside = _serviceInFavourOf(mute);

        // The control that makes this a measurement: the money really is unreachable first.
        assertEq(usdc.balanceOf(mute), 0, "control: the receiver already held USDC");

        address bystander = makeAddr("bystander");
        vm.prank(bystander);
        uint256 paid = pool.claimFor(mute);

        assertEq(paid, setAside, "the reported figure is not what was set aside");
        assertEq(usdc.balanceOf(mute), setAside, "the receiver was not paid");
        assertEq(usdc.balanceOf(bystander), 0, "the caller took the money, so the destination IS chooseable");
        assertEq(pool.claimable(mute), 0, "the set-aside counter was not cleared");
        assertEq(pool.totalClaimable(), 0, "the aggregate counter drifted from the individual one");
    }

    /// @notice THE HALF `claimFor` DOES NOT CLOSE, and cannot: a receiver that cannot RECEIVE.
    /// @dev Round 22's agents 01 and 12 measured opposite results on this same function because
    ///      they used these two different preconditions. This test is the second one, asserted
    ///      rather than argued: against a USDC blacklist the `*For` door reverts in **exactly** the
    ///      place the receiver's own `claim()` reverts, with the same error and the same argument.
    ///      The failure is in the token and the destination is deliberately not chooseable, so
    ///      there is no version of this function that recovers it.
    ///
    ///      **Asserting the inertness is the point.** A `*For` sweep that is written up as closing
    ///      round-22 finding 12 without this test reads like closure of a finding it half-touches.
    function test_claimFor_isInertAgainstAReceiverThatCannotReceive() public {
        address frozen = makeAddr("blacklistedReceiver");
        uint256 setAside = _serviceInFavourOf(frozen);
        usdc.setBlocked(frozen, true);

        // The receiver's own door.
        vm.prank(frozen);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, frozen));
        pool.claim();

        // The permissionless door, identical.
        address bystander = makeAddr("bystander");
        vm.prank(bystander);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, frozen));
        pool.claimFor(frozen);

        assertEq(pool.claimable(frozen), setAside, "the counter moved on a call that reverted");
    }

    /// @notice The owner's shares are gone by the time either door is tried, which is round-22
    ///         finding 12's headline and is NOT closed by this sweep.
    /// @dev Before servicing, `alice` could `cancelWithdrawalRequest` and take her shares back.
    ///      After controller-authorized service the shares are burned and the money sits under
    ///      the **receiver's** name. `claimFor` widens who may pull that money out; it does not
    ///      give the owner back the ability to undo the conversion. Recorded as an assertion so the
    ///      next round reads the residual rather than the sweep.
    function test_claimForDoesNotRestoreACompletedControllerRequest() public {
        address frozen = makeAddr("blacklistedReceiver");
        _serviceInFavourOf(frozen);
        usdc.setBlocked(frozen, true);

        assertEq(pool.balanceOf(alice), 0, "owner still holds serviced shares");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.WithdrawalRequestNotFound.selector, alice));
        pool.cancelWithdrawalRequest();
    }

    function test_claimFor_refusesTheZeroAddress() public {
        vm.expectRevert(LenderPool.ZeroAddress.selector);
        pool.claimFor(address(0));
    }

    /// @dev Reverts at zero rather than no-opping, so a caller cannot be told a strand was cleared
    ///      when nothing moved. Same rule as `claimSurplusFor` and `claimBountyFor`.
    function test_claimFor_revertsWithNothingToClaim() public {
        vm.expectRevert(LenderPool.NothingToClaim.selector);
        pool.claimFor(alice);
    }

    /// @dev Round 10. Money set aside for a serviced lender is still in the contract but is no
    ///      longer the pool's. Counting it would raise the share price by exactly the amount owed
    ///      to somebody else, on every fill.
    function test_setAsideMoneyDoesNotInflateTheSharePrice() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        _setIdleTo(2 * DEPOSIT);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, aliceShares, 0);

        uint256 priceAfterService = pool.convertToAssets(bobShares);
        _claim(alice);
        assertEq(pool.convertToAssets(bobShares), priceAfterService, "collecting moved the share price");
    }

    /// @dev Round 10, finding 4. With no shares outstanding the assets back only the virtual shares
    ///      the decimals offset implies, which nobody owns and nothing here can sweep. The harvester
    ///      measures delivery and catches, so refusing leaves the share owed rather than destroyed.
    function test_distributeYield_refusesWhenNoSharesExist() public {
        usdc.mint(harvester, 500e6);
        vm.prank(harvester);
        usdc.approve(address(pool), 500e6);

        vm.prank(harvester);
        vm.expectRevert(LenderPool.NoSharesOutstanding.selector);
        pool.distributeYield(500e6);

        // And the money is still the harvester's, not stranded in a vault nobody has a claim on.
        assertEq(usdc.balanceOf(harvester), 500e6);
    }

    /// @dev Round 10, finding 1. The clamp is right; returning nothing was not. A caller that can
    ///      only see "did not revert" books a partial absorption as a full one.
    function test_socialiseLoss_reportsWhatItActuallyAbsorbed() public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        vm.prank(creditManager);
        uint256 absorbed = pool.socialiseLoss(5_000e6);
        assertEq(absorbed, 1_000e6, "absorbed must be the clamped amount, not the request");
        assertEq(pool.lifetimeSocialisedLoss(), 1_000e6);
    }

    /// @dev Round 10, finding 11. The mirror of `CreditManager.setLiquiditySource`, which refuses
    ///      the same swap from the other side. Only the old manager can repay, so repointing
    ///      mid-loan freezes `outstandingPrincipal` above zero forever and `totalAssets()` counts
    ///      money that can never arrive.
    function test_setCreditManager_refusedWhilePrincipalIsOut() public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.PrincipalOutstanding.selector, 1_000e6));
        pool.setCreditManager(makeAddr("a new manager"));

        _repay(1_000e6);
        vm.prank(admin);
        pool.setCreditManager(makeAddr("a new manager"));
    }

    function testFuzz_escrowMatchesTheContractsOwnBalance(uint256 a, uint256 b) public {
        a = bound(a, 1e6, DEPOSIT);
        b = bound(b, 1e6, DEPOSIT);

        uint256 aliceShares = _deposit(alice, a);
        _deposit(bob, b);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);

        assertEq(pool.queuedShares(), pool.balanceOf(address(pool)));
        assertLe(pool.queuedShares(), pool.totalSupply());
    }

    /// @dev Bring the pool's idle balance to exactly `target`, by repaying principal into it.
    ///      The queue tests need a known idle figure and must not encode the reserve ratio to get
    ///      one - that is the literal-in-a-fixture trap this repo has already paid for once.
    function _setIdleTo(uint256 target) internal {
        uint256 idle = usdc.balanceOf(address(pool));
        require(target >= idle, "test: _setIdleTo cannot reduce idle");
        if (target > idle) _repay(target - idle);
    }

    /// @dev Servicing sets money aside rather than sending it, so a test that wants to see a
    ///      balance move has to collect it. That separation is the point of the pull: see the
    ///      `claimable` NatSpec on why a push let one entry block the whole queue.
    function _serviceAndClaim(uint256, address[] memory controllers) internal {
        for (uint256 i = 0; i < controllers.length; i++) {
            uint256 shares = pool.maxRequestRedeem(controllers[i]);
            if (shares == 0) continue;
            vm.prank(controllers[i]);
            pool.serviceWithdrawalRequest(controllers[i], shares, 0);
            if (pool.claimable(controllers[i]) == 0) continue;
            vm.prank(controllers[i]);
            pool.claim();
        }
    }

    function _claim(address who) internal {
        vm.prank(who);
        pool.claim();
    }

    // ── the queue reservation, audit round 21 finding 7, OPEN ────────────────

    /// @notice The prescribed clamp on the queue reservation is INERT. Recorded, not shipped.
    /// @dev Audit round 21 finding 7: `unreservedIdle()` and `available()` hold back
    ///      `_convertToAssets(queuedShares, Ceil)` - the **un-impaired** valuation - while
    ///      controller service executes at the live marked price, so a request reserves cash
    ///      they are forbidden to be paid, at a price they would never be paid at, and nothing
    ///      permissionless drains it. A parker holding 15.8% of the book made one free
    ///      `requestWithdrawal` and an unqueued lender's `maxWithdraw` went 3,567.125000 -> 0 for
    ///      the whole workout, against a real impaired entitlement of 563.230263 on a reservation
    ///      of 3,750.000000: **6.66x**.
    ///
    ///      **External precedent research recommended Goldfinch's `min(available, needed)` clamp as
    ///      the piece that was safe to ship now, "arithmetically unreachable 6.66x". Against this
    ///      tree it moves nothing, and the arithmetic is one line:** the shipped holdback already
    ///      floors at zero, so `idle - min(idle, owed)` and `max(0, idle - owed)` are the same
    ///      function. Asserted here as `assertEq(clamped, shipped)` rather than argued in a
    ///      paragraph, because a prescribed fix that reads like success and moves nothing has now
    ///      cost this project eight rounds running.
    ///
    ///      **This test asserts the DEFECT, and the fix it used to name has since been BUILT AND
    ///      REFUTED. Do not restore that sentence.** It said the real fix is "impaired pricing plus
    ///      serve-while-marked, which are one change", waiting only on the NAV anchor that #204
    ///      shipped. Both halves were built on 2026-08-22 and each fires a control the tree already
    ///      relies on:
    ///
    ///      - **Impaired pricing of the holdback restores audit round 12.** MEASURED: deepening a
    ///        mark from 500.000000 to 4,000.000000 takes `available()` from 15,269.736842 to
    ///        15,407.894736, so a markdown buys 138.157894 of lending capacity.
    ///        `invariant_worseNewsNeverBuysMoreLending` is the shipped guard for exactly that.
    ///      - **Serve-while-marked restores audit round 15 and IS round-22 finding 12.** MEASURED:
    ///        a controller-authorized service burns only the requested share amount
    ///        escrowed shares for 563.230263 - 15.02% of the un-impaired claim, destroyed
    ///        permanently at a stranger's chosen instant.
    ///
    ///      A third candidate, impaired pricing on the WITHDRAWAL door only, passes every control
    ///      and all 29 lender invariants and is refuted by its own cost: a good-faith lender queued
    ///      behind the parker goes from being paid **379.362500** to being paid **0**, while the
    ///      parker at the head of the queue is barely touched. Audit round 21's finding 7 therefore
    ///      stays open, with eight refuted candidates behind it rather than four.
    ///
    ///      Until something survives, the two `assertEq`s below are a tripwire: whichever of them
    ///      goes red says the shape changed.
    function test_requestReservationIsCashProRataAndLeavesTheOtherLenderAnExit() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        uint256 idle = _poolBalanceFromPublicReads();
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);

        uint256 expectedReserve = Math.mulDiv(idle, aliceShares, pool.totalSupply(), Math.Rounding.Ceil);
        assertEq(pool.queueCashReserve(), expectedReserve, "request reserve is not cash pro rata");
        assertEq(pool.unreservedIdle(), idle - expectedReserve, "unreserved cash identity");
        assertGt(pool.maxWithdraw(bob), 0, "one request zeroed the other lender's immediate exit");

        uint256 postRequestBook = pool.totalAssets() - expectedReserve;
        uint256 postRequestFloat = (postRequestBook * Config.RESERVE_RATIO_BPS) / Config.BPS;
        uint256 held = expectedReserve + postRequestFloat;
        uint256 expectedAvailable = idle > held ? idle - held : 0;
        assertEq(pool.available(), expectedAvailable, "post-request hot float identity");
    }

    // ── audit round 22 finding 2: the exit that empties the book ─────────────

    /// @dev The un-impaired worth of every share that somebody actually holds. The virtual shares
    ///      are excluded on purpose: what leaks into them is exactly the money this finding is
    ///      about, because nobody can ever redeem them.
    function _bookValueOfRealShares() internal view returns (uint256) {
        return pool.convertToAssets(pool.totalSupply());
    }

    /// @dev Mark `amount` against a borrower who is not a lender, so the mark moves the exit price
    ///      and nothing else. The manager is a bare EOA in this suite, which is why this is one
    ///      prank rather than a whole liquidation - the end-to-end version of this hazard, driven
    ///      by a real permissionless `liquidate` with nothing pranked, is
    ///      `test_R22F2_aWholeDebtMarkCannotEmptyTheBookOnTheWayOut` in `Impairment.integration.t.sol`.
    function _mark(uint256 amount) internal {
        vm.prank(creditManager);
        pool.impair(makeAddr("markedBorrower"), amount);
    }

    /// @notice The cliff. Destruction must be flat across the whole range of the mark, endpoint
    ///         included.
    /// @dev **`totalImpairment == outstandingPrincipal` is the ordinary single-borrower state, not
    ///      an edge case**, so a test that sweeps the interior and stops short of the endpoint would
    ///      miss the only point that matters.
    ///
    ///      MEASURED on the tree before the fix, the whole 64-step profile on a 10,000.000000 pool
    ///      with 5,000.000000 lent: 0 wei at a zero mark, 1 wei for steps 1 to 42, 2 wei to step 50,
    ///      then 3, 4, 5, 6, 8, 10, 16, 31 - and **2,501.250625 at the endpoint**. So it is a cliff
    ///      rather than a slope: everything below the last step is rounding, and the last step is a
    ///      quarter of the book. After the fix the endpoint destroys **1 wei** and every step
    ///      passes at a tolerance of two.
    ///
    ///      Destruction is measured as book value that stops belonging to anybody: what the exit
    ///      pays out, plus what the residue is worth on the un-impaired book, against what the whole
    ///      real supply was worth before. Measuring the *payout* instead would pass against a fix
    ///      that merely moved the hole onto whoever stayed.
    function test_R22F2_thereIsNoCliffAnywhereInTheMarkRange() public {
        _deposit(alice, DEPOSIT);
        _lend(5_000e6);
        uint256 principal = pool.outstandingPrincipal();

        uint256 steps = 64;
        for (uint256 i = 0; i < steps; i++) {
            uint256 mark = (principal * i) / (steps - 1);
            uint256 clean = vm.snapshotState();

            if (mark != 0) _mark(mark);
            uint256 valueBefore = _bookValueOfRealShares();

            uint256 quoted = pool.maxWithdraw(alice);
            vm.prank(alice);
            pool.withdraw(quoted, alice, alice);

            uint256 conserved = quoted + _bookValueOfRealShares();
            if (i == steps - 1) {
                emit log_named_uint("R22F2 mark == principal, destroyed", valueBefore - conserved);
            }
            assertGe(
                conserved + 2, valueBefore, "a mark somewhere in this range destroys book value that nobody realised"
            );

            vm.revertToState(clean);
        }
    }

    /// @notice The grind. Iterating the bounded exit does not get there either.
    /// @dev **The obvious objection to bounding the exit is that a griefer just calls it in a
    ///      loop.** The decay is harmonic rather than geometric - `1/C(n+1) = 1/C(n) + 1/P`, so
    ///      `S(n) = S * P / (P + n * C)` - which is a reciprocal, not an exponential, and it does
    ///      not reach the virtual-share scale from any starting book a real pool could have.
    ///      Derived, then MEASURED here at a thousand iterations rather than asserted from the
    ///      algebra, because a derivation that happens to be geometric would look identical in
    ///      prose. Report what the log says, not what this paragraph says.
    function test_R22F2_iteratingTheBoundedExitDoesNotGrindTheSupplyDown() public {
        _deposit(alice, DEPOSIT);
        _lend(5_000e6);
        _mark(pool.outstandingPrincipal());

        uint256 valueBefore = _bookValueOfRealShares();
        uint256 supplyBefore = pool.totalSupply();
        uint256 cashBefore = usdc.balanceOf(address(pool));
        uint256 principal = pool.outstandingPrincipal();
        uint256 rounds = 1_000;
        uint256 paid;
        uint256 iterations;

        for (uint256 i = 0; i < rounds; i++) {
            uint256 quoted = pool.maxWithdraw(alice);
            if (quoted == 0) break;
            vm.prank(alice);
            pool.withdraw(quoted, alice, alice);
            paid += quoted;
            iterations++;
        }

        emit log_named_uint("R22F2 grind iterations      ", iterations);
        emit log_named_uint("R22F2 grind supply before   ", supplyBefore);
        emit log_named_uint("R22F2 grind supply after    ", pool.totalSupply());
        emit log_named_uint("R22F2 grind total paid out  ", paid);
        emit log_named_uint("R22F2 grind destroyed       ", valueBefore - (paid + _bookValueOfRealShares()));

        assertEq(iterations, rounds, "the grind stopped early, so a thousand iterations were not measured");

        // **The decay law itself, not just a floor under it.** Harmonic gives
        // `S(n) = S * P / (P + n * C)`; geometric would give `S * (P / (P + C)) ** n`, which at
        // these numbers is zero long before iteration 1,000. Asserting the closed form is what
        // tells the two apart - a floor alone would be satisfied by either if the floor were
        // generous enough.
        assertApproxEqRel(
            pool.totalSupply(),
            Math.mulDiv(supplyBefore, principal, principal + rounds * cashBefore),
            1e15, // 0.1%
            "the supply did not decay harmonically, so the derivation behind this bound is wrong"
        );

        // 10,000 wei is `MIN_SUPPLY_FOR_YIELD` at a decimals offset of three.
        assertGt(pool.totalSupply(), (10 ** 3) * Config.BPS, "a thousand exits ground the supply past the yield floor");
        assertGe(
            paid + _bookValueOfRealShares() + 2 * rounds,
            valueBefore,
            "the grind destroys more than two wei per iteration, so the decay is not harmonic"
        );
    }

    /// @notice ERC-4626 conformance across the whole range of the mark.
    /// @dev OpenZeppelin is pinned at 5.6.1, where the base `ERC4626.maxWithdraw(owner)` **is**
    ///      `previewRedeem(maxRedeem(owner))` and both `withdraw` and `redeem` enforce their maximum
    ///      with `ERC4626ExceededMaxWithdraw` / `ERC4626ExceededMaxRedeem`. This contract overrides
    ///      the two views independently, which is what broke the identity; the audit measured the
    ///      shipped pair agreeing only to within two wei. Exact is the property, because it is the
    ///      identity that makes the reported maximum an executable bound rather than a quote.
    ///
    ///      ERC-4626 also forbids any of the four from reverting. Their only external dependency is
    ///      one gas-bounded asset-balance probe that maps failure to zero, and every conversion uses
    ///      saturating arithmetic, so calling them here is the assertion.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_R22F2_theMaxViewsConformAcrossTheMarkRange(uint256 markSeed) public {
        _deposit(alice, DEPOSIT);
        _lend(5_000e6);
        uint256 mark = bound(markSeed, 0, pool.outstandingPrincipal());
        if (mark != 0) _mark(mark);

        pool.maxDeposit(alice);
        pool.maxMint(alice);
        uint256 maxRedeemable = pool.maxRedeem(alice);
        uint256 maxWithdrawable = pool.maxWithdraw(alice);

        assertEq(
            maxWithdrawable,
            pool.previewRedeem(maxRedeemable),
            "the asset-denominated maximum is not the share-denominated one, priced"
        );

        // And both are executable at the figure reported, which is the whole point of the identity.
        uint256 clean = vm.snapshotState();
        vm.prank(alice);
        pool.withdraw(maxWithdrawable, alice, alice);
        vm.revertToState(clean);
        vm.prank(alice);
        pool.redeem(maxRedeemable, alice, alice);
    }

    /// @notice INERTNESS: with nothing reserved, the bound must not move the numbers.
    /// @dev The bound converts the idle cash at the **un-impaired** price, and at
    ///      `exitReserve() == 0` the un-impaired price *is* the exit price - so `maxRedeem` is
    ///      unchanged identically, by construction rather than by rounding.
    ///
    ///      `maxWithdraw` is now derived from it rather than taken as a second minimum, and that
    ///      composes two floors where the old expression had one. **MEASURED, and it is not
    ///      identically zero, so it is stated rather than claimed away.** On a pool whose share
    ///      price is an exact `10 ** offset` - which every deposit-only fixture is, including
    ///      `test_maxWithdrawReportsWhatCanActuallyBeTakenNow` - the two agree exactly, and so do
    ///      they whenever the caller's own balance is the binding term. On an inexact price with the
    ///      idle cash binding, the derived figure can be exactly one wei lower and never higher.
    ///
    ///      **That wei is the conservative side of a disagreement the shipped pair already had, not
    ///      a new one.** Today `maxWithdraw` reports the full idle cash while `maxRedeem` reports
    ///      the share count that pays one wei less than it - the ERC-4626 identity was already
    ///      broken, in the direction where the asset figure is not executable through the share
    ///      door. Picking the other side is what makes the reported maximum an executable bound.
    ///
    ///      **Rounding the conversion up instead was examined and refused.** `Ceil` restores the
    ///      exact figure at `exitReserve() == 0`, and at a high enough share price - a small supply
    ///      against a large book, which a socialised loss reaches - it lets `maxRedeem` report a
    ///      share count whose payout exceeds the idle cash the pool actually holds. A maximum that
    ///      cannot be executed is a worse ERC-4626 defect than a maximum that is one wei short.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_R22F2_theBoundIsInertWhileNothingIsReserved(uint256 lentSeed, uint256 heldSeed, uint256 yieldSeed)
        public
    {
        uint256 held = bound(heldSeed, 1e6, DEPOSIT);
        _deposit(alice, held);
        _deposit(bob, DEPOSIT);

        // Break the exact 1000:1 share ratio through recognized yield. Raw donations are excluded
        // from canonical cash and therefore cannot be used as a pricing fixture.
        _distributeYield(bound(yieldSeed, 1, DEPOSIT));
        skip(Config.YIELD_STREAM_DURATION + 1);

        _lend(bound(lentSeed, 1, pool.available()));

        assertEq(pool.exitReserve(), 0, "fixture: nothing may be reserved in the inert case");

        uint256 shipped = Math.min(pool.previewRedeem(pool.balanceOf(alice)), pool.unreservedIdle());
        uint256 derived = pool.maxWithdraw(alice);

        assertLe(derived, shipped, "the derived maximum rose, which would be a liquidity claim it cannot back");
        assertGe(derived + 1, shipped, "the derived maximum moved by more than the one wei of the second floor");
        assertEq(
            pool.maxRedeem(alice),
            Math.min(pool.balanceOf(alice), pool.convertToShares(pool.unreservedIdle())),
            "maxRedeem moved while nothing was reserved"
        );
    }

    /// @notice A raw donation cannot raise the entry price or turn a valid deposit into zero shares.
    function test_R22F2_donationCannotCreateAZeroShareDeposit() public {
        _deposit(alice, 1);
        uint256 quoteBefore = pool.previewDeposit(1);
        uint256 assetsBefore = pool.totalAssets();
        uint256 usageBefore = _depositCapUsage(pool);
        usdc.mint(address(pool), 1_000e6);

        assertGt(quoteBefore, 0, "fixture: the deposit must mint shares");
        assertEq(pool.previewDeposit(1), quoteBefore, "donation changed the entry price");
        assertEq(pool.totalAssets(), assetsBefore, "donation changed NAV");
        assertEq(_depositCapUsage(pool), usageBefore, "donation changed cap usage");
        assertEq(_unmanagedSurplus(pool), 1_000e6, "donation was not isolated");

        vm.prank(bob);
        assertEq(pool.deposit(1, bob), quoteBefore, "execution departed from the donation-inert quote");
    }

    // ── round-28 item 10 (round-25 A6 F4): the pool refuses entry while paused ──
    //
    // The pause shuts `deposit` and `mint` and nothing else. Every test below that touches an exit
    // is there to hold that line: `withdraw`, `redeem`, `requestWithdrawal`, `serviceWithdrawalRequest` and
    // `claim` must keep working, and keep working *correctly*, while the door is shut. That is the
    // entire argument for putting this switch on the guardian's key rather than the owner's, so a
    // change that closes an exit has not tightened this contract, it has invalidated the reasoning
    // that let the fast key reach it.

    /// @notice The measured harm, closed. A lender can no longer enter into a write-down they
    ///         missed.
    /// @dev **Audit round 25, finding 4, re-measured here rather than quoted.** The original
    ///      measurement was a lender who deposited while the protocol was paused and watched their
    ///      redeemable balance go **10,000.000000 -> 9,750.000000** when the loss the pause was
    ///      called for landed. Both halves are asserted: the control shows the money genuinely
    ///      moves that far, and the fixed path shows the entry is refused before it can.
    function test_R25A6F4_aLenderCanNoLongerEnterIntoAWriteDownTheyMissed() public {
        _deposit(alice, DEPOSIT);

        // The incident. The guardian shuts the door; the loss has not landed yet.
        vm.prank(admin);
        pool.pause();

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.deposit(DEPOSIT, bob);
        assertEq(pool.balanceOf(bob), 0, "the entrant took an exposure the pause was called to stop");

        // The control, on the same fixture: reopen, let the same lender in, land the same loss.
        // 500.000000 against a 20,000.000000 book is 250 bps, which is the round-25 figure.
        vm.prank(admin);
        pool.unpause();
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(5_000e6);
        vm.prank(creditManager);
        pool.socialiseLoss(500e6);

        assertEq(
            pool.previewRedeem(bobShares),
            9_750e6,
            "the control must reproduce the measurement, or the test above proves nothing"
        );
    }

    /// @notice The ERC-4626 trap. A paused pool reports a zero cap and never reverts in a view.
    /// @dev EIP-4626 requires `maxDeposit` to return zero when deposits are disabled, **including
    ///      temporarily**, and forbids it from reverting under any condition - the contract's own
    ///      NatSpec above `maxDeposit` has recorded the no-revert half since audit round 11, which
    ///      is why the deposit cap is stored locally instead of read from `RiskParams`. A pause
    ///      expressed as a revert here would not stop an integrator, it would break one. Both views
    ///      are asserted because `maxMint` delegates, and delegation is exactly the property a
    ///      refactor removes without touching a line this test reads.
    function test_G4_pauseIsAZeroCapInTheViewsAndNeverARevert() public {
        assertGt(pool.maxDeposit(alice), 0, "fixture: the pool must be open before it is shut");
        assertGt(pool.maxMint(alice), 0);

        vm.prank(admin);
        pool.pause();

        assertEq(pool.maxDeposit(alice), 0, "maxDeposit must report a zero cap while paused");
        assertEq(pool.maxMint(alice), 0, "maxMint must follow it to zero");

        // And back, because a cap that never comes back is a different bug wearing this one's face.
        vm.prank(admin);
        pool.unpause();
        assertEq(pool.maxDeposit(alice), pool.depositCap(), "the cap did not come back");
    }

    /// @notice The refusal names the pause, not the cap.
    /// @dev **The nuance the zero cap alone gets wrong.** `deposit` reads `maxDeposit(receiver)`
    ///      itself, so a zero cap would already refuse the call - as `DepositCapExceeded(assets, 0)`,
    ///      which tells a lender the pool is full when the truth is that the pool is shut. Those are
    ///      different facts with different responses: one says come back when someone leaves, the
    ///      other says come back when the incident is over. `whenNotPaused` runs before the body and
    ///      says `EnforcedPause()` instead. OpenZeppelin's own error rather than a bespoke one, so
    ///      the three contracts carrying the guardian role refuse in one voice and the dApp's error
    ///      union already carries the selector.
    function test_G4_theRefusalNamesThePauseRatherThanTheCap() public {
        vm.prank(admin);
        pool.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.deposit(1e6, alice);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.mint(1e9, alice);
    }

    /// @notice The two bounded EIP-5143 doors are shut too, and only because they delegate.
    /// @dev They carry no gate of their own - they call the two-argument doors above and check a
    ///      bound on the result - so they are covered for free. **Asserted rather than assumed**,
    ///      for the reason the exit-side overloads are asserted in the invariant handler: delegation
    ///      is a property of the bodies as written, and a refactor can take it away silently.
    function test_G4_theBoundedEntryDoorsAreShutByDelegation() public {
        vm.prank(admin);
        pool.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.deposit(1e6, alice, 0);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.mint(1e9, alice, type(uint256).max);
    }

    /// @notice The premise. A paused pool shuts no cure and strands nobody.
    /// @dev **This is the test that makes the switch guardian-reachable.** Audit round 27 refused a
    ///      guardian-reachable pause on `CollateralVault.depositBonds` because that one shut the
    ///      borrower's cure. Here every exit stays open: the immediate ERC-4626 pair, the queue, the
    ///      pull payment at the end of it, and the servicing walk a keeper drives. If a later change
    ///      closes any of them this test goes red, and the right response is to reopen the exit
    ///      rather than to edit the test - the fast key's reach is justified by this and by nothing
    ///      else.
    function test_G4_everyExitStaysOpenAndStaysCorrectWhilePaused() public {
        uint256 stake = 8_000e6;
        uint256 aliceShares = _deposit(alice, stake);
        _deposit(bob, stake);
        uint256 carolShares = _deposit(carol, stake);

        vm.prank(admin);
        pool.pause();

        uint256 quoted = pool.previewRedeem(aliceShares / 2);
        vm.prank(alice);
        uint256 paid = pool.redeem(aliceShares / 2, alice, alice);
        assertEq(paid, quoted, "redeem was repriced by pause");

        uint256 assets = pool.maxWithdraw(bob);
        vm.prank(bob);
        pool.withdraw(assets, bob, bob);

        _lend(pool.available());
        vm.prank(carol);
        pool.requestWithdrawal(carolShares, carol);
        _repay(stake);

        uint256 serviceable = pool.maxRequestRedeem(carol);
        uint256 requestQuote = pool.previewRedeem(serviceable);
        vm.prank(carol);
        uint256 serviced = pool.serviceWithdrawalRequest(carol, serviceable, requestQuote);
        assertGt(serviced, 0, "request service was shut by pause");

        uint256 heldBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        pool.claim();
        assertEq(usdc.balanceOf(carol) - heldBefore, serviced, "claim was shut by pause");
    }

    // ── the role itself ──────────────────────────────────────────────────────

    /// @notice The guardian may shut the door and may not reopen it.
    /// @dev The asymmetry `CollateralVault` already carries, restated here because it is the half
    ///      an implementation gets wrong by symmetry: a compromised guardian that could `unpause`
    ///      would be able to reopen the pool in the middle of the incident the owner shut it for.
    function test_G4_theGuardianMayShutTheDoorAndMayNotReopenIt() public {
        address guardian = makeAddr("guardian");
        vm.prank(admin);
        pool.setGuardian(guardian);

        vm.prank(guardian);
        pool.pause();
        assertTrue(pool.paused(), "the guardian could not reach the pause");

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        pool.unpause();

        vm.prank(admin);
        pool.unpause();
        assertFalse(pool.paused(), "the owner could not reopen the pool");
    }

    /// @notice With the role unfilled the switch is owner-only, and a stranger is refused.
    /// @dev **One thing this deliberately does NOT assert, because it is not true under a
    ///      cheatcode.** `_requireOwnerOrGuardian` reads an unfilled role as `address(0)`, and the
    ///      comment it inherits from `CollateralVault` says a zero guardian cannot match a caller
    ///      because `msg.sender` is never the zero address. That holds on chain and does not hold
    ///      under `vm.prank(address(0))`, which pauses the pool - measured while writing this test.
    ///      It is a property of the cheatcode rather than of the contract, and it is identical in
    ///      `CollateralVault` and `CreditManager`, so it is recorded here rather than defended
    ///      against with a check that would cost bytes and close nothing reachable.
    function test_G4_pauseIsRefusedToAStrangerWhileTheRoleIsUnfilled() public {
        assertEq(pool.guardian(), address(0), "fixture: the role must ship unfilled");

        vm.prank(alice);
        vm.expectRevert(LenderPool.NotOwnerOrGuardian.selector);
        pool.pause();

        // And an installed guardian does not widen it to a third party.
        address guardian = makeAddr("guardian");
        vm.prank(admin);
        pool.setGuardian(guardian);
        vm.prank(bob);
        vm.expectRevert(LenderPool.NotOwnerOrGuardian.selector);
        pool.pause();
    }

    /// @dev The configuration the second key does not defend against, refused. Checked against the
    ///      owner **at the time of the call**, exactly as the vault's is, which is why
    ///      `DeployBase._assertWiring` re-reads the pair after `_handOver`.
    function test_G4_setGuardian_refusesTheOwnerAndIsOwnerOnly() public {
        vm.prank(admin);
        vm.expectRevert(LenderPool.GuardianMustDifferFromOwner.selector);
        pool.setGuardian(admin);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setGuardian(alice);
    }

    /// @dev Clearing the role is a legal act and must emit, or an operator watching the topic sees
    ///      the key installed and never sees it withdrawn.
    function test_G4_setGuardian_emitsOnInstallAndOnClear() public {
        address guardian = makeAddr("guardian");

        vm.expectEmit(true, false, false, false, address(pool));
        emit LenderPool.GuardianSet(guardian);
        vm.prank(admin);
        pool.setGuardian(guardian);
        assertEq(pool.guardian(), guardian);

        vm.expectEmit(true, false, false, false, address(pool));
        emit LenderPool.GuardianSet(address(0));
        vm.prank(admin);
        pool.setGuardian(address(0));
        assertEq(pool.guardian(), address(0), "the role could not be withdrawn");
    }

    /// @dev `_poolBalance()` is private. Reconstructed from the three public reads it is made of,
    ///      so the variant above is computed off the same state the contract uses.
    function _poolBalanceFromPublicReads() internal view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(pool));
        uint256 notOurs = pool.totalClaimable() + pool.unreleasedYield();
        return balance > notOurs ? balance - notOurs : 0;
    }

    /// @dev The un-impaired, ceiling-rounded claim the queue holds back. `convertToAssets` rounds
    ///      the other way, so the formula is restated here rather than approximated - a one-wei
    ///      difference would make the `assertEq`s above pass for the wrong reason.

    function _distributeYield(uint256 amount) internal {
        usdc.mint(harvester, amount);
        vm.prank(harvester);
        usdc.approve(address(pool), amount);
        vm.prank(harvester);
        pool.distributeYield(amount);
    }

    function _repay(uint256 amount) internal {
        usdc.mint(creditManager, amount);
        vm.prank(creditManager);
        usdc.approve(address(pool), amount);
        vm.prank(creditManager);
        pool.repayPrincipal(amount);
    }
}
