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

    /// @dev Lend and write off until the pool holds nothing at all.
    ///
    ///      **Round-23 finding 6 is why this exists.** `socialiseLoss` used to debit the whole
    ///      absorbed amount from `netDeposits`, so a single loss the size of the counter cleared it
    ///      while the pool was still holding assets - which is the defect. The debit is now
    ///      yield-first: the counter falls to what the pool no longer holds, so a *total* loss is
    ///      one after which there is nothing left, and a fixture that wants one has to produce it.
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

    /// @dev The classic ERC-4626 first-depositor attack. With a zero decimals offset the attacker
    ///      mints one wei of shares, donates to inflate the price, and the victim's deposit rounds
    ///      to zero shares. The offset is what makes that uneconomic, and this is the case that
    ///      would prove it gone.
    function test_firstDepositorCannotRoundTheSecondOneToNothing() public {
        vm.prank(alice);
        pool.deposit(1, alice);

        // Donate straight to the contract, bypassing `deposit`, which is the attack.
        usdc.mint(address(pool), 1_000e6);

        uint256 bobShares = _deposit(bob, 1_000e6);
        assertGt(bobShares, 0, "second depositor must not be rounded out of the pool");
        assertGt(pool.convertToAssets(bobShares), 0);
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
                LenderPool.DepositCapTooLarge.selector,
                Config.GLOBAL_BORROW_CAP_MAX + 1,
                Config.GLOBAL_BORROW_CAP_MAX
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
        vm.expectRevert(
            abi.encodeWithSelector(LenderPool.InsufficientLiquidity.selector, DEPOSIT, DEPOSIT - reserve)
        );
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
        assertLe(pool.netDeposits(), pool.depositCap(), "mint crossed the deposit cap");
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

    /// @notice A frozen backlog is not a cohort pot and remains outside entry pricing.
    /// @dev With no live release rate, the next depositor must see the ordinary ERC-4626 price.
    ///      The next delivered epoch re-rates the frozen money and establishes its cohort then.
    function test_F10_frozenBacklogKeepsEntryPreviewsOnReleasedAssets() public {
        uint256 incumbentShares = _deposit(alice, DEPOSIT);
        _distributeYield(500e6);
        skip(1 days);

        vm.prank(alice);
        pool.redeem(incumbentShares, alice, alice);
        assertEq(pool.yieldRate(), 0, "fixture: the tail did not freeze");
        assertGt(pool.unreleasedYield(), 0, "fixture: there is no frozen backlog");

        uint256 assets = 1_000e6;
        assertEq(pool.previewDeposit(assets), pool.convertToShares(assets), "frozen yield entered the deposit price");

        uint256 virtualShares = 10 ** uint256(pool.decimals() - usdc.decimals());
        uint256 shares = assets * virtualShares;
        assertEq(pool.previewMint(shares), pool.convertToAssets(shares), "frozen yield entered the mint price");
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

    /// @dev Unreleased yield must not outlive the shareholders it was meant for. With the stream
    ///      still running against a zero supply, the remainder would keep landing in `totalAssets`
    ///      and the next depositor - minting against the virtual shares alone - would own all of
    ///      it outright. That is the same just-in-time capture, reachable by waiting.
    function test_stream_freezesWhenTheLastShareIsBurnedRatherThanBecomingAWindfall() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _distributeYield(500e6);
        skip(1 days);

        vm.prank(alice);
        pool.redeem(shares, alice, alice);
        assertEq(pool.totalSupply(), 0, "the last share is gone");

        uint256 frozen = pool.unreleasedYield();
        assertGt(frozen, 0, "the rest of the epoch is still owed to lenders");
        assertEq(pool.yieldRate(), 0, "and stopped releasing when it stopped having owners");
        // Rounding on the way out favours the pool, so a wei or two can be left behind. It must be
        // dust and nothing more - a windfall here would be the whole unreleased remainder.
        assertLe(pool.totalAssets(), 1, "no windfall sitting in the share price");

        skip(30 days);
        assertEq(pool.unreleasedYield(), frozen, "time alone hands it to nobody");
        assertLe(pool.totalAssets(), 1);

        address late = makeAddr("late");
        usdc.mint(late, DEPOSIT);
        vm.startPrank(late);
        usdc.approve(address(pool), type(uint256).max);
        uint256 lateShares = pool.deposit(DEPOSIT, late);
        vm.stopPrank();

        assertApproxEqAbs(pool.previewRedeem(lateShares), DEPOSIT, 1, "arriving late is not a windfall");

        // The next epoch folds the frozen remainder into a fresh stream, so it is not stranded -
        // it is earned by holding through that stream, which is the point.
        _distributeYield(100e6);
        assertEq(pool.pendingYield(), frozen + 100e6, "the whole pot is re-rated, not just the new money");
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
    function test_recoverLoss_doesNotMoveOutstandingPrincipalOrNetDeposits() public {
        _deposit(alice, DEPOSIT);
        _lend(4_000e6);
        vm.prank(creditManager);
        pool.socialiseLoss(1_000e6);

        uint256 principalBefore = pool.outstandingPrincipal();
        uint256 headroomBefore = pool.maxDeposit(alice);

        usdc.mint(creditManager, 600e6);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), 600e6);
        pool.recoverLoss(600e6);
        vm.stopPrank();

        assertEq(pool.outstandingPrincipal(), principalBefore, "no loan was re-recognised");
        assertEq(pool.maxDeposit(alice), headroomBefore, "and the cap moved by nothing, as yield does");
    }

    /// @notice Below the share floor it is frozen into the pot rather than raising nobody's price.
    /// @dev Verbatim the rule `repayPrincipal`'s surplus uses. Rating a stream into an empty pool
    ///      is a windfall for the next depositor rather than a payment to anyone.
    function test_recoverLoss_freezesIntoThePotWhileThePoolIsTooSmall() public {
        assertEq(pool.totalSupply(), 0, "premise: nobody to raise the price of");

        usdc.mint(creditManager, 600e6);
        vm.startPrank(creditManager);
        usdc.approve(address(pool), 600e6);
        pool.recoverLoss(600e6);
        vm.stopPrank();

        assertEq(pool.pendingYield(), 600e6, "held, not rated");
        assertEq(pool.yieldRate(), 0, "and the stream stays frozen");
        assertEq(pool.totalAssets(), 0, "so no share price moved");
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
    /// @dev `maxDeposit` was sized from `totalAssets()`, which reads a raw `balanceOf`. With
    ///      `totalSupply()` at zero there is no share to redeem that would bring the balance back
    ///      under the cap, and this contract has no sweep and no owner rescue - so the only
    ///      recovery was a redeploy plus three re-wirings, against a pool the deploy script ships
    ///      in exactly this state.
    function test_maxDeposit_survivesADonationToTheEmptyPool() public {
        assertEq(pool.totalSupply(), 0, "the deploy script ships it empty");
        assertEq(pool.maxDeposit(alice), pool.depositCap());

        usdc.mint(address(this), pool.depositCap());
        usdc.transfer(address(pool), pool.depositCap());

        assertEq(pool.maxDeposit(alice), pool.depositCap(), "a stranger closed the pool");
        assertGt(pool.maxMint(alice), 0);

        // And the pool still actually works.
        uint256 shares = _deposit(alice, DEPOSIT);
        assertGt(shares, 0);
    }

    /// @dev The cap counts lender capital admitted, not the pool's valuation, so withdrawing frees
    ///      room again and yield does not consume it.
    function test_maxDeposit_countsCapitalInNotValuation() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        assertEq(pool.maxDeposit(bob), pool.depositCap() - DEPOSIT);

        _distributeYield(500e6);
        skip(Config.YIELD_STREAM_DURATION);
        assertEq(pool.maxDeposit(bob), pool.depositCap() - DEPOSIT, "yield must not eat the cap");

        vm.prank(alice);
        pool.redeem(shares, alice, alice);
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

    /// @notice **`serviceQueue` pays the un-impaired price or it pays nobody.** It can never pay a
    ///         marked-down one, and this calls it rather than reading a view about it.
    ///
    /// @dev **This replaces `test_impairment_theQueueIsPaidAtTheImpairedPrice`, which audit round
    ///      16 found asserted a view.** That test impaired and then read `queuePosition`, so it
    ///      passed identically against a `serviceQueue` that pays nobody - which, since audit round
    ///      15 keyed the refusal on the standing reserve, is the behaviour. It was named in
    ///      `serviceQueue`'s own NatSpec as the thing that pinned the claim, and the claim had
    ///      stopped being true. **Read a test's name as a claim and check that its verb appears in
    ///      the body.**
    ///
    ///      The property now: below the break, `reserved == false` implies `exitReserve() == 0`
    ///      implies `exitAssets() == totalAssets()`, so the impaired arithmetic is arithmetically
    ///      the plain conversion. Both halves are asserted here, because either alone is
    ///      satisfiable by a broken implementation: a queue that refuses forever passes the first,
    ///      and a queue that pays the marked price passes the second.
    ///
    ///      `queuePosition` is still checked, but as what it is - a quote for the lender, not a
    ///      statement about what the queue will pay. Round 16's undesigned consequence is visible
    ///      right here: the quote falls, and the money that eventually arrives does not.
    function test_impairment_theQueueIsPaidTheUnimpairedPriceOrNothing() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        uint256 unimpairedOwed = pool.convertToAssets(shares);
        (, uint256 quotedBefore) = pool.queuePosition(alice);

        _impair(carol, 2_000e6);
        assertGt(pool.exitReserve(), 0, "fixture: a reserve must actually be standing");

        // The quote a lender is shown does fall, which is what the old test measured.
        (, uint256 quotedAfter) = pool.queuePosition(alice);
        assertLt(quotedAfter, quotedBefore, "the quote must carry the mark");

        // And the queue refuses to act on it, naming the reserve as the reason.
        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(10);
        assertEq(pool.claimable(alice), 0, "nothing may be set aside at a marked-down price");

        // Once the mark comes off, the entry is serviced - and the identity that makes the
        // impaired branch dead is asserted directly, because it is the whole finding: with nothing
        // reserved, the exit price *is* the plain price, so the arithmetic below the break has no
        // reachable state in which it differs.
        _impair(carol, 0);
        assertEq(pool.exitReserve(), 0, "releasing must leave nothing reserved");
        assertEq(pool.exitAssets(), pool.totalAssets(), "and with nothing reserved the two prices are one");

        uint256 idle = usdc.balanceOf(address(pool));
        assertGt(idle, 0, "fixture: there must be cash to pay with");
        assertLt(idle, unimpairedOwed, "fixture: fully lent, so this is a partial fill");

        assertEq(pool.serviceQueue(10), 1, "the entry must be serviced once nothing is reserved");
        assertEq(pool.claimable(alice), idle, "every available cent goes to the head of the queue");

        // The burn matched the un-impaired price: what is left owed is the entry less what was
        // paid, valued the same way. A fill priced off a marked-down book would have burned more
        // shares for the same cash and left less standing.
        (, uint256 stillOwed) = pool.queuePosition(alice);
        assertEq(stillOwed, unimpairedOwed - idle, "the fill was priced off the un-impaired book");
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

    /// @notice A realised loss must not consume deposit-cap headroom for good.
    /// @dev Audit round 12. `netDeposits` was incremented at the entry price and decremented only
    ///      by assets actually withdrawn, and `socialiseLoss` never touched it - so capital
    ///      written off went on counting against the cap forever, because it never leaves as a
    ///      withdrawal. `LenderPool` is immutable with no sweep and no rescue, so enough realised
    ///      losses close it to deposits permanently. The same permanent-brick shape round 11 found
    ///      through a donation, reachable here through ordinary operation.
    ///
    ///      Driven at the cap rather than at a comfortable figure, because the harm is a boundary:
    ///      at any smaller deposit the ratchet is real but invisible.
    function test_netDeposits_fallsWithARealisedLossSoTheCapDoesNotRatchetShut() public {
        uint256 cap = pool.depositCap();
        usdc.mint(alice, cap);
        vm.prank(alice);
        pool.deposit(cap, alice);
        assertEq(pool.maxDeposit(bob), 0, "fixture: the pool must start full");

        _lend(pool.available());

        uint256 lost = 1_000e6;
        vm.prank(creditManager);
        uint256 absorbed = pool.socialiseLoss(lost);
        assertEq(absorbed, lost, "fixture: the loss must actually land against principal");

        // The money is gone. The pool now holds less than the cap, so it must be able to take
        // replacement capital - that is the entire point of a cap on principal admitted.
        assertEq(pool.netDeposits(), cap - lost, "destroyed capital must stop counting against the cap");
        assertEq(pool.maxDeposit(bob), lost, "and the headroom it freed must be usable");

        usdc.mint(bob, lost);
        vm.prank(bob);
        pool.deposit(lost, bob);
        assertGt(pool.balanceOf(bob), 0, "a replacement lender must be able to get in");
    }

    /// @notice Yield must not erode the deposit-cap counter at the ERC-4626 door.
    /// @dev Audit round 21, finding 8. `_deposit` credits `netDeposits` in **principal** and every
    ///      exit used to debit it in **assets paid out**, which once the pool has earned is that
    ///      lender's principal plus their share of every epoch of yield. The floor-at-zero clamp
    ///      makes the difference a one-way ratchet, so the counter walks down while the principal
    ///      it is supposed to measure stays in the pool - and `maxDeposit` re-opens headroom that
    ///      was never freed. Measured at the shipped code: one 4,000e6 epoch over a 20,000e6 book
    ///      leaves the counter at 8,000.000000 with 10,000.000000 of Bob's principal still in.
    ///
    ///      Driven with two lenders on purpose: the one who leaves must not carry the other's
    ///      headroom out with them.
    function test_netDeposits_isNotErodedByYieldAtTheErc4626Door() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _distributeYield(4_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);
        assertEq(pool.netDeposits(), 2 * DEPOSIT, "fixture: yield must not move the counter up");

        uint256 shares = pool.balanceOf(alice);
        uint256 paid = pool.previewRedeem(shares);
        vm.prank(alice);
        pool.redeem(shares, alice, alice);

        assertGt(paid, DEPOSIT, "fixture: the exit must actually carry yield out with it");
        assertEq(pool.netDeposits(), DEPOSIT, "the leaver must debit their exact remaining principal");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - DEPOSIT, "and the cap must free exactly one seat");
    }

    /// @notice The same rule at the queue door, which is a second writer, not the same one.
    /// @dev Round 21 recorded that this fix **cannot be validated by subclassing**: `_withdraw` is
    ///      not `virtual` and `_reduceNetDeposits` is `private`. Had it been subclassable the
    ///      natural fix would have closed the ERC-4626 door above and left this one open while
    ///      reading like closure. Two doors, two assertions, and neither one implies the other.
    function test_netDeposits_isNotErodedByYieldAtTheQueueDoor() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _distributeYield(4_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        pool.serviceQueue(4);

        assertEq(pool.balanceOf(address(pool)), 0, "fixture: the queue entry must have been paid in full");
        assertEq(pool.netDeposits(), DEPOSIT, "the queue door must debit the exact same principal");
    }

    /// @notice The measured headline: a rotating lender must not be able to walk the counter to
    ///         zero while the pool is still holding a full book.
    /// @dev Round 21 MEASURED, on the shipped code: two epochs of a lender who deposits, waits out
    ///      the stream and leaves drive `netDeposits` to **0** while `totalAssets()` is
    ///      40,000.000003 and `maxDeposit` reports the **full 100,000e6 cap** - the pool would
    ///      accept 140,000e6 of book under a 100,000e6 ceiling. `depositCap` is a yield control,
    ///      not a solvency one, so the harm is dilution of the realised yield this product refuses
    ///      to project rather than insolvency; it is still the one mechanism limiting how much
    ///      lender capital competes for a fixed borrow book, silently limiting nothing.
    function test_netDeposits_doesNotRatchetToZeroUnderARotatingLender() public {
        vm.prank(admin);
        pool.setDepositCap(100_000e6);

        uint256 anchor = 20_000e6;
        usdc.mint(carol, anchor);
        vm.prank(carol);
        pool.deposit(anchor, carol);

        address rotator = makeAddr("rotator");
        for (uint256 epoch = 0; epoch < 2; epoch++) {
            usdc.mint(rotator, anchor);
            vm.startPrank(rotator);
            usdc.approve(address(pool), type(uint256).max);
            pool.deposit(anchor, rotator);
            vm.stopPrank();

            _distributeYield(10_000e6);
            skip(Config.YIELD_STREAM_DURATION + 1);

            // Read the balance BEFORE the prank: an external view in argument position spends it,
            // and the redeem then runs as this test contract instead of the rotator.
            uint256 out = pool.balanceOf(rotator);
            vm.prank(rotator);
            pool.redeem(out, rotator, rotator);
        }

        emit log_named_uint("netDeposits", pool.netDeposits());
        emit log_named_uint("totalAssets", pool.totalAssets());
        emit log_named_uint("maxDeposit ", pool.maxDeposit(bob));

        assertEq(pool.netDeposits(), anchor, "only the anchor lender's principal must remain");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - anchor, "the cap must free exactly the vacated seats");
    }

    /// @notice A lender entering above par and leaving immediately cannot consume cap headroom.
    /// @dev Audit round 22 finding 3. A global share-ratio debit records less principal than this
    ///      lender supplied because their shares were minted after yield raised the price. Their own
    ///      principal units remain exact, so the round trip leaves both the anchor and headroom
    ///      unchanged.
    function test_R22F3_aboveParRoundTripPreservesPrincipalAndHeadroom() public {
        _deposit(alice, DEPOSIT);
        _distributeYield(2_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 assets = 15_000e6;
        usdc.mint(bob, assets - DEPOSIT);
        uint256 netBefore = pool.netDeposits();
        uint256 headroomBefore = pool.maxDeposit(bob);

        vm.prank(bob);
        uint256 shares = pool.deposit(assets, bob);
        assertEq(pool.principalBasis(bob), assets, "the entrant must carry exactly what they supplied");

        vm.prank(bob);
        pool.redeem(shares, bob, bob);

        assertEq(pool.balanceOf(bob), 0, "the entrant must have completed the round trip");
        assertEq(pool.principalUnits(bob), 0, "no principal units may outlive the shares");
        assertEq(pool.netDeposits(), netBefore, "a round trip must not move admitted principal");
        assertEq(pool.maxDeposit(bob), headroomBefore, "a round trip must not consume cap headroom");
    }

    /// @notice The original 114-cycle cap ratchet no longer moves admitted principal.
    /// @dev One asset-wei per cycle is the audit's measured total cost. The above-par fixture keeps
    ///      every entry on the share-ratio boundary that made the old global debit drift upward.
    function test_R22F3_original114CycleRatchetNoLongerMovesTheCap() public {
        _deposit(alice, DEPOSIT);
        _distributeYield(2_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 netBefore = pool.netDeposits();
        uint256 headroomBefore = pool.maxDeposit(bob);

        for (uint256 i = 0; i < 114; i++) {
            vm.prank(bob);
            uint256 shares = pool.deposit(1, bob);
            vm.prank(bob);
            pool.redeem(shares, bob, bob);
        }

        assertEq(pool.balanceOf(bob), 0, "the rotating account must finish every cycle empty");
        assertEq(pool.netDeposits(), netBefore, "114 cycles must not move admitted principal");
        assertEq(pool.maxDeposit(bob), headroomBefore, "114 cycles must not consume cap headroom");
    }

    /// @notice Replacement capital does not inherit a loss and survives an older lender's exit.
    /// @dev A raw per-holder basis is insufficient here. The old lender's recorded deposit predates
    ///      the loss, so debiting that raw amount would clamp `netDeposits` to zero and erase the new
    ///      lender's replacement capital from the cap. Principal units mark the old cohort down and
    ///      issue the replacement cohort at the post-loss ratio.
    function test_R22F3_replacementCapitalSurvivesTheLossCohortsExit() public {
        _deposit(alice, DEPOSIT);
        _lend(1_000e6);

        vm.prank(creditManager);
        assertEq(pool.socialiseLoss(1_000e6), 1_000e6, "fixture: the loss must land");

        _deposit(bob, 1_000e6);
        assertEq(pool.netDeposits(), DEPOSIT, "replacement capital must refill only the realised loss");

        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(aliceShares, alice, alice);

        assertEq(pool.principalUnits(alice), 0, "the old cohort must leave no units behind");
        assertEq(pool.netDeposits(), 1_000e6, "the replacement lender's principal must remain admitted");
        assertEq(pool.principalBasis(bob), 1_000e6, "the replacement lender must keep their full basis");
        assertEq(pool.maxDeposit(bob), pool.depositCap() - 1_000e6, "the cap must still count the replacement");
    }

    /// @notice A total loss invalidates old units and the next deposit starts at par.
    /// @dev **The fixture changed in round 23 and the assertions did not.** It used to donate
    ///      2,000.000000 into the pool so one `lend` could reach the whole deposit, then socialise
    ///      exactly `netDeposits` - and under the old whole-amount debit that cleared the counter
    ///      while the donation was still sitting in the pool. That is round-23 finding 6, not a
    ///      total loss, and the yield-first debit now leaves the counter at 2,000.000000 to say so.
    ///      The repair is to make the loss genuinely total rather than to relax the assertion:
    ///      `_loseEverything` drives `totalAssets()` to zero and the generation rolls on merit.
    function test_R22F3_totalLossStartsAFreshPrincipalGeneration() public {
        _deposit(alice, DEPOSIT);
        usdc.mint(address(pool), 2_000e6);
        _loseEverything();

        assertEq(pool.totalAssets(), 0, "fixture: a total loss is one that leaves nothing behind");
        assertEq(pool.netDeposits(), 0, "a total loss must clear admitted principal");
        assertEq(pool.totalPrincipalUnits(), 0, "a total loss must clear the active unit generation");
        assertEq(pool.principalUnits(alice), 0, "old shares must carry no basis after a total loss");

        usdc.mint(alice, 1_000e6);
        _deposit(alice, 1_000e6);

        assertEq(pool.netDeposits(), 1_000e6, "new principal must start at par");
        assertEq(pool.totalPrincipalUnits(), 1_000e6, "only the new generation may count");
        assertEq(pool.principalUnits(alice), 1_000e6, "stale units must be replaced rather than merged");
        assertEq(pool.principalBasis(alice), 1_000e6, "the new generation must reconstruct the new principal");
    }

    /// @notice Principal units follow shares and merge additively at the receiver.
    /// @dev **Floored, and the direction is load-bearing rather than incidental.** Shares carry
    ///      three more decimals than the assets the units are denominated in, so a ceiling here
    ///      rounded a one-share-wei transfer - a ten-thousandth of a ten-asset-wei position - up to
    ///      a whole unit, and that detached unit could then be burned for zero assets while still
    ///      debiting `netDeposits`. Round-22 finding 3's no-loss dust boundary was exactly that,
    ///      and `LenderPoolUnitProvenance.t.sol` owns the executed trace and the closure.
    ///
    ///      Conservation is what this test is really for and it is unchanged: whatever the sender
    ///      loses the receiver gains, to the wei, in either rounding direction.
    function test_R22F3_principalUnitsMoveAndMergeOnTransfer() public {
        _deposit(alice, DEPOSIT);
        _deposit(bob, 1_000e6);

        uint256 aliceUnitsBefore = pool.principalUnits(alice);
        uint256 bobUnitsBefore = pool.principalUnits(bob);
        uint256 totalUnitsBefore = pool.totalPrincipalUnits();
        uint256 movedUnits = Math.mulDiv(aliceUnitsBefore, 1, pool.balanceOf(alice), Math.Rounding.Floor);

        vm.prank(alice);
        pool.transfer(bob, 1);

        assertEq(pool.principalUnits(alice), aliceUnitsBefore - movedUnits, "the sender must lose the rounded units");
        assertEq(pool.principalUnits(bob), bobUnitsBefore + movedUnits, "the receiver must merge the rounded units");
        assertEq(pool.totalPrincipalUnits(), totalUnitsBefore, "a transfer must conserve principal units");
    }

    /// @notice A token callback cannot move basis for shares that have not been minted yet.
    function test_R22F3_depositCreditsPrincipalAfterTheAssetTransferHook() public {
        ShareTransferHookUSDC hookedUsdc = new ShareTransferHookUSDC();
        LenderPool fresh = new LenderPool(IERC20(address(hookedUsdc)), admin);

        hookedUsdc.mint(alice, 2 * DEPOSIT);
        vm.startPrank(alice);
        hookedUsdc.approve(address(fresh), type(uint256).max);
        fresh.deposit(DEPOSIT, alice);
        fresh.approve(address(hookedUsdc), type(uint256).max);
        vm.stopPrank();

        uint256 sharesMoved = fresh.balanceOf(alice) / 2;
        hookedUsdc.arm(fresh, alice, bob, sharesMoved);

        vm.prank(alice);
        fresh.deposit(DEPOSIT, alice);

        assertTrue(hookedUsdc.hookRan(), "fixture: the asset-transfer hook must have run");
        assertEq(fresh.principalUnits(bob), DEPOSIT / 2, "the callback may move only half the old basis");
        assertEq(
            fresh.principalUnits(alice), DEPOSIT + DEPOSIT / 2, "the new deposit must remain with its minted shares"
        );
        assertEq(fresh.totalPrincipalUnits(), 2 * DEPOSIT, "the callback must not create or destroy units");
        assertEq(fresh.netDeposits(), 2 * DEPOSIT, "the callback must not move admitted principal");
    }

    /// @notice Queue escrow moves, returns and finally burns the same principal units.
    function test_R22F3_queueEscrowUsesTheTokenHookForPrincipal() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        uint256 queued = shares / 2;
        uint256 queuedUnits = Math.mulDiv(DEPOSIT, queued, shares, Math.Rounding.Ceil);

        vm.prank(alice);
        pool.requestWithdrawal(queued, alice);
        assertEq(pool.principalUnits(address(pool)), queuedUnits, "escrow must receive the queued units");
        assertEq(pool.principalUnits(alice), DEPOSIT - queuedUnits, "the lender must release the queued units");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.principalUnits(address(pool)), 0, "cancellation must empty the escrow basis");
        assertEq(pool.principalUnits(alice), DEPOSIT, "cancellation must restore the lender's basis");

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        pool.serviceQueue(10);

        assertEq(pool.principalUnits(address(pool)), 0, "the queue burn must consume the escrow units");
        assertEq(pool.totalPrincipalUnits(), 0, "a full exit must consume every principal unit");
        assertEq(pool.netDeposits(), 0, "a full exit must release all deposit-cap principal");
    }

    /// @notice Shared escrow preserves each request's basis even when share prices differ.
    /// @dev Alice enters at par and Bob enters after yield doubles the price, so their units per
    ///      share differ. A partial fill, cancellation and later full fill must each use the units
    ///      recorded for that request rather than the pool's blended escrow ratio.
    function test_R22F3_queuePreservesHeterogeneousPrincipalProvenance() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _distributeYield(DEPOSIT);
        skip(Config.YIELD_STREAM_DURATION + 1);
        uint256 bobShares = _deposit(bob, DEPOSIT);

        _lend(25_000e6);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        assertEq(pool.queueEntryPrincipalUnits(0), DEPOSIT, "Alice's request must record her basis");
        assertEq(pool.queueEntryPrincipalUnits(1), DEPOSIT, "Bob's request must record his basis");

        pool.serviceQueue(1);
        (,, uint256 aliceSharesRemaining) = pool.queueEntry(0);
        uint256 aliceUnitsRemaining = pool.queueEntryPrincipalUnits(0);
        uint256 aliceSharesBurned = aliceShares - aliceSharesRemaining;
        uint256 aliceUnitsBurned = Math.mulDiv(DEPOSIT, aliceSharesBurned, aliceShares, Math.Rounding.Ceil);
        assertEq(
            aliceUnitsRemaining,
            DEPOSIT - aliceUnitsBurned,
            "the partial fill must burn the request's ceiling-rounded unit slice"
        );
        assertLt(aliceUnitsRemaining, DEPOSIT, "fixture: Alice must be partially serviced");
        assertGt(aliceUnitsRemaining, 0, "fixture: Alice must retain a live remainder");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.principalUnits(alice), aliceUnitsRemaining, "cancellation must return Alice's exact remainder");
        assertEq(pool.principalUnits(address(pool)), DEPOSIT, "only Bob's exact request may remain in escrow");
        assertEq(pool.queueEntryPrincipalUnits(1), DEPOSIT, "Alice's cancellation must not dilute Bob's basis");

        _repay(25_000e6);
        pool.serviceQueue(1);

        assertEq(pool.principalUnits(address(pool)), 0, "servicing Bob must empty the escrow basis");
        assertEq(pool.principalUnits(bob), 0, "Bob's full exit must consume his exact basis");
        assertEq(pool.totalPrincipalUnits(), aliceUnitsRemaining, "only Alice's cancelled remainder may stay active");
        assertEq(pool.netDeposits(), aliceUnitsRemaining, "the cap must count only Alice's remaining principal");
    }

    /// @notice A partial fill burns exactly the shares the cash it pays out can buy back, floored.
    /// @dev **Audit round 25, finding 2: this branch was protected by nothing.** Flipping the
    ///      `Math.Rounding.Floor` in `serviceQueue`'s partial-fill `_exitToShares(idle, ...)` to
    ///      `Ceil` stayed green across all 58 `LenderPool` invariant evaluations and all 900
    ///      deterministic tests - zero detection anywhere in a 993-test suite. This is the
    ///      regression, and it was neuter-verified against exactly that flip and nothing else.
    ///
    ///      **The one wei donated below is the whole reason this test works, and it is a second
    ///      finding sitting inside the first.** On the fixture's own round numbers - a
    ///      10,000.000000 deposit into an empty pool, lent down to `Config.RESERVE_RATIO_BPS` of
    ///      the book - the three quantities that decide the rounding are
    ///
    ///        idle = 1,500,000,000    s = totalSupply() + 10**3 = 10**13 + 1,000
    ///                                a = exitAssets() + 1      = 10,000,000,001
    ///
    ///      and `idle * s` is an **exact** multiple of `a`. Floor and Ceil agree to the wei, so a
    ///      partial fill built on those numbers cannot see the mutation however many times it is
    ///      reached - which is why reaching the branch was never the whole problem. One wei of
    ///      donation moves `a` to 10,000,000,002, leaves a remainder of 300, and separates the two
    ///      roundings in **both** observable outputs: the shares burned and the USDC set aside.
    ///      That exactness is asserted rather than described, in
    ///      `test_theRoundNumberFixtureCannotSeeThePartialFillRounding` below, because a fixture
    ///      that quietly stopped being exact would turn this test back into the thing it replaced.
    ///
    ///      **What would have to be true for this to pass without measuring anything.** Three
    ///      things, and all three are asserted before the rounding is looked at: the fill not being
    ///      partial at all (`remaining > 0`), nothing being serviced (`serviceQueue` returning 1),
    ///      and the two roundings coinciding (`wouldBurnRoundedUp == expectedBurn + 1`). The last
    ///      is the one this repo has been bitten by fifteen times and the only one that is
    ///      invisible from the outcome.
    function test_R25F2_aPartialFillBurnsOnlyWhatTheCashCanBuyBack() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        assertEq(shares, 10 ** 13, "fixture: an empty pool prices at 10**3 shares per asset-wei");

        // One wei, donated straight in, is what makes the exit ratio inexact. See the docstring.
        usdc.mint(address(this), 1);
        usdc.transfer(address(pool), 1);

        // Lend before queueing, never after. `available()` subtracts what the queue is already
        // owed, so a request placed first shrinks this lend to nothing and the fill comes out full
        // rather than partial. That ordering is also why the invariant campaign reached this branch
        // in 1 of 8 unseeded runs before round-26 remediation.
        uint256 lent = pool.available();
        assertEq(lent, 8_500_000_001, "fixture: the hot float is RESERVE_RATIO_BPS of the book");
        _lend(lent);

        uint256 idle = usdc.balanceOf(address(pool));
        uint256 supplyBefore = pool.totalSupply();
        uint256 exitAssetsBefore = pool.exitAssets();
        assertEq(idle, 1_500_000_000, "fixture: the float left behind moved");

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        // The prediction, **restated here rather than read back off the contract**. Asking the pool
        // to convert `idle` for us would be the shape audit round 25 filed against
        // `invariant_theStoredSetIsAlwaysLegal`: a function checked against its own output, which
        // agrees with itself under every mutation. These are OZ's ERC-4626 terms written out, with
        // `exitAssets()` in place of `totalAssets()` and `10**3` for the decimals offset.
        uint256 s = supplyBefore + 10 ** 3;
        uint256 a = exitAssetsBefore + 1;
        uint256 expectedBurn = Math.mulDiv(idle, s, a, Math.Rounding.Floor);
        uint256 wouldBurnRoundedUp = Math.mulDiv(idle, s, a, Math.Rounding.Ceil);
        assertEq(expectedBurn, 1_499_999_999_850, "fixture: the floored share slice moved");
        assertEq(
            wouldBurnRoundedUp,
            expectedBurn + 1,
            "fixture: the two roundings coincide here, so this test cannot see the mutation it targets"
        );

        assertEq(pool.serviceQueue(1), 1, "the head must be serviced");

        (,, uint256 remaining) = pool.queueEntry(0);
        assertGt(remaining, 0, "fixture: the fill must be partial rather than a clearance");
        uint256 burned = supplyBefore - pool.totalSupply();
        assertEq(shares - remaining, burned, "every burned share must come off the entry that was paid");

        // The property, first: the shares burned are worth no more, at the pre-burn exit price,
        // than the cash that left. `burned * a <= idle * s`, expressed through the floored
        // conversion so nothing can overflow.
        assertLe(burned, expectedBurn, "the partial fill burned more shares than its cash can buy back");
        // Then the pin, because the property alone still admits burning too few.
        assertEq(burned, expectedBurn, "the partial fill burned a different slice than the floored conversion");
        assertEq(pool.claimable(alice), 1_499_999_999, "the partial fill set aside a different amount");
    }

    /// @notice The round-number fixture cannot tell Floor from Ceil. This is why the test above
    ///         donates one wei before it measures anything.
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
    function test_theRoundNumberFixtureCannotSeeThePartialFillRounding() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        uint256 lent = pool.available();
        assertEq(lent, 8_500_000_000, "fixture: 15% of a round 10,000.000000 book");
        _lend(lent);

        uint256 idle = usdc.balanceOf(address(pool));
        uint256 s = pool.totalSupply() + 10 ** 3;
        uint256 a = pool.exitAssets() + 1;

        assertEq(
            Math.mulDiv(idle, s, a, Math.Rounding.Floor),
            Math.mulDiv(idle, s, a, Math.Rounding.Ceil),
            "the round fixture has stopped being exact, so the sibling test's literals are stale"
        );

        // And the branch really is taken on these numbers, so the statement above is about the
        // rounding rather than about reachability.
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        assertEq(pool.serviceQueue(1), 1, "the head must be serviced");
        (,, uint256 remaining) = pool.queueEntry(0);
        assertGt(remaining, 0, "fixture: the fill must be partial rather than a clearance");
        assertEq(
            shares - remaining,
            Math.mulDiv(idle, s, a, Math.Rounding.Floor),
            "the burn must equal the floored conversion even where Ceil would give the same answer"
        );
    }

    /// @notice Stale queue requests cannot take units from a post-loss generation.
    function test_R22F3_staleQueueRequestsCannotTakeFreshPrincipalUnits() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);

        // **The fixture changed in round 23 and the assertions did not.** It used to donate
        // 4,000.000000 into the pool so one `lend` could reach both deposits, then socialise
        // exactly `netDeposits` - and under the old whole-amount debit that rolled the generation
        // while the donation was still sitting in the pool. That is round-23 finding 6, not a total
        // loss. Under the yield-first debit the roll has to be earned, so the write-down runs
        // first, the entries are queued against a pool whose last asset is out on loan, and the
        // final write-off is what rolls the generation. See `_lendDownToNothingIdle` for why the
        // order cannot be the other way round.
        _lendDownToNothingIdle();

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        // Read first. An external staticcall in argument position spends the prank.
        uint256 exposure = pool.outstandingPrincipal();
        vm.prank(creditManager);
        pool.socialiseLoss(exposure);

        assertEq(pool.totalAssets(), 0, "fixture: the total loss must leave nothing behind");
        assertEq(pool.netDeposits(), 0, "fixture: the generation must roll on merit, not on finding 6");

        uint256 freshAssets = 1_000e6;
        uint256 carolShares = _deposit(carol, freshAssets);
        vm.prank(carol);
        pool.requestWithdrawal(carolShares, carol);

        assertEq(pool.principalUnits(address(pool)), freshAssets, "only the fresh request may carry active units");
        assertEq(pool.queueEntryPrincipalUnits(0), 0, "Alice's old request must be stale");
        assertEq(pool.queueEntryPrincipalUnits(1), 0, "Bob's old request must be stale");
        assertEq(pool.queueEntryPrincipalUnits(2), freshAssets, "Carol's request must own every fresh unit");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        vm.prank(bob);
        pool.cancelWithdrawalRequest();

        assertEq(pool.principalUnits(address(pool)), freshAssets, "stale cancellations must not take Carol's units");
        assertEq(pool.queueEntryPrincipalUnits(2), freshAssets, "Carol's request provenance must survive");

        vm.prank(carol);
        pool.cancelWithdrawalRequest();
        assertEq(pool.principalUnits(address(pool)), 0, "the fresh cancellation must empty active escrow units");
        assertEq(pool.principalUnits(carol), freshAssets, "Carol must recover her fresh-generation basis");
    }

    /// @notice CLOSED: a dust share split no longer loosens the cap without a realised loss.
    /// @dev **This was round-22 finding 3's no-loss boundary and it is shut.** At par the
    ///      three-decimal virtual offset gives a ten-asset-wei deposit 10,000 share-wei and ten
    ///      principal units. Transferring one share-wei used to **ceil**-move a whole unit; that
    ///      dust share then redeemed for zero assets because the exit conversion floors, and its
    ///      unit burn still removed one asset-wei from `netDeposits`. Ten executed cycles drove the
    ///      counter from ten to zero while all ten assets remained and `maxDeposit` returned to the
    ///      full cap.
    ///
    ///      `_update` floors now, so the same trace moves no units at all and the counter does not
    ///      move. The executed before-and-after, the brick-direction control, the two boundaries
    ///      that stay open and the per-holder basis that was built and refused all live in
    ///      `LenderPoolUnitProvenance.t.sol`. What is kept here is the shortest form of the
    ///      closure, so the file that owns the rest of finding 3 still states it.
    function test_R22F3_aDustTransferThenZeroAssetRedeemNoLongerErodesTheCap() public {
        uint256 aliceShares = _deposit(alice, 10);
        assertEq(aliceShares, 10_000, "fixture: the virtual offset must mint one thousand shares per asset-wei");

        uint256 assetsBefore = usdc.balanceOf(address(pool));
        uint256 headroomBefore = pool.maxDeposit(bob);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            pool.transfer(bob, 1);

            assertEq(pool.principalUnits(bob), 0, "a dust split must move no principal unit at all");
            assertEq(pool.previewRedeem(1), 0, "fixture: each one-share position must redeem for zero assets");

            vm.prank(bob);
            uint256 assetsOut = pool.redeem(1, bob, bob);

            assertEq(assetsOut, 0, "fixture: each boundary must pay no assets");
            assertEq(usdc.balanceOf(address(pool)), assetsBefore, "fixture: no asset may leave the pool");
            assertEq(pool.totalPrincipalUnits(), 10, "a zero-asset exit must burn no units");
            assertEq(pool.netDeposits(), 10, "a zero-asset exit must not loosen the cap");
            assertEq(pool.maxDeposit(bob), headroomBefore, "cap headroom must not move when no asset moves");
        }
    }

    /// @notice Known residual: after a loss, quotient rounding can loosen the cap by one asset-wei.
    /// @dev The candidate remains a partial remediation until this boundary has transferable
    ///      fractional provenance. The error is one USDC micro-unit per completed round trip, not
    ///      the original nonlinear ratchet that closed the whole cap in 114 cycles.
    function test_R22F3_knownResidual_postLossDustRoundTripErodesOneAssetWei() public {
        uint256 aliceShares = _deposit(alice, 10);
        assertGt(aliceShares, 0, "fixture: Alice must receive shares");
        _lend(1);

        vm.prank(creditManager);
        assertEq(pool.socialiseLoss(1), 1, "fixture: the one-wei loss must land");
        assertEq(pool.netDeposits(), 9, "fixture: nine admitted asset-wei must remain");

        uint256 bobShares = _deposit(bob, 1);
        vm.prank(bob);
        pool.redeem(bobShares, bob, bob);

        assertEq(pool.netDeposits(), 8, "known residual: the round trip loosens the cap by one asset-wei");
    }

    /// @notice Known residual: merging differently priced lots makes their basis fungibly average.
    /// @dev Exact lot provenance cannot survive an additive ERC-20 merge and a later split in one
    ///      scalar balance. This path requires the caller to keep the blended anchor position; it
    ///      does not reproduce the original near-free fresh-account round trip.
    function test_R22F3_knownResidual_mergeAndSplitAveragesPrincipalBasis() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _distributeYield(2_000e6);
        skip(Config.YIELD_STREAM_DURATION + 1);

        uint256 bobAssets = 15_000e6;
        usdc.mint(bob, bobAssets - DEPOSIT);
        uint256 bobShares = _deposit(bob, bobAssets);

        vm.prank(bob);
        pool.transfer(alice, bobShares);
        vm.prank(alice);
        pool.transfer(bob, bobShares);

        uint256 bobBasisAfterBlend = pool.principalBasis(bob);
        assertLt(bobBasisAfterBlend, bobAssets, "fixture: the split must average Bob's basis downward");

        vm.prank(bob);
        pool.redeem(bobShares, bob, bob);

        assertEq(pool.balanceOf(alice), aliceShares, "the anchor shares must remain invested");
        assertGt(pool.netDeposits(), DEPOSIT, "known residual: averaged basis remains on the anchor position");
        assertEq(
            pool.netDeposits(),
            DEPOSIT + bobAssets - bobBasisAfterBlend,
            "the residual must equal the basis moved onto the anchor"
        );
    }

    /// @notice CONTROL for the other direction: the round-21 fix must not ratchet the counter UP.
    /// @dev Debiting pro-rata instead of at the assets paid moves the error the other way, and the
    ///      other way is the permanent brick rounds 11 and 12 both landed on - a counter that grows
    ///      past `depositCap` closes an immutable pool to deposits for good. It does not, and the
    ///      reason is structural rather than lucky: an exit scales `netDeposits` and `totalAssets()`
    ///      by the same factor, so it cannot raise their ratio, a deposit adds the same amount to
    ///      both, and yield only raises the denominator. `netDeposits <= totalAssets()` therefore
    ///      survives arbitrarily many rotations.
    ///
    ///      **This assertion also holds on the pre-fix code**, by a much slacker margin, so it is a
    ///      guard on the fix's own direction rather than evidence the fix works - the three tests
    ///      above are that. Kept because nothing else in the suite bounds this counter from above.
    function test_netDeposits_neverExceedsTheBookUnderRepeatedRotation() public {
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

            assertLe(pool.netDeposits(), pool.totalAssets(), "the counter claimed more principal than the book holds");
            assertGt(pool.maxDeposit(carol), 0, "the pool must not have closed itself to deposits");
        }

        emit log_named_uint("after 10 rotations: netDeposits", pool.netDeposits());
        emit log_named_uint("after 10 rotations: totalAssets", pool.totalAssets());
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
    ///      At that point `serviceQueue`'s dust-release branch runs - above the `idle == 0` break,
    ///      deliberately, so that cash-free progress still happens when the pool is fully lent -
    ///      and treats "worth zero at today's exit price" as permanently worthless. One
    ///      permissionless call hands the whole queue back and whoever re-queues first takes the
    ///      head. A markdown is temporary; losing your place is not.
    function test_impairment_deepMarkdownDoesNotEvictTheQueue() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        // Bob is not queued, so `unreservedIdle()` is the whole float and `maxWithdraw` will hand
        // it over. This is the drain the round-12 trace used.
        uint256 bobsMax = pool.maxWithdraw(bob);
        assertGt(bobsMax, 0, "fixture: there must be a float to drain");
        vm.prank(bob);
        pool.withdraw(bobsMax, bob, bob);
        assertEq(usdc.balanceOf(address(pool)), 0, "fixture: the pool must be holding nothing");

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        (uint256 placeBefore,) = pool.queuePosition(alice);

        // A markdown big enough to take the whole book to zero at the exit price.
        _impair(carol, type(uint128).max);
        assertEq(pool.exitAssets(), 0, "fixture: this is the full-markdown state");

        // Nothing is payable and nothing is permanently worthless, so there is genuinely no work
        // to do. Refusing is the honest answer; the old behaviour "made progress" by emptying the
        // queue.
        //
        // The reserve is what stops the walk here, and the pool being empty would stop it one
        // branch later - so this asserts the reserve refusal specifically. Two honest reasons
        // holding at once is exactly the case the old single error could not describe.
        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(10);

        assertEq(pool.balanceOf(alice), 0, "the queued shares must stay escrowed, not be handed back");
        assertEq(pool.balanceOf(address(pool)), aliceShares, "the pool still holds them");
        (uint256 placeAfter,) = pool.queuePosition(alice);
        assertEq(placeAfter, placeBefore, "a temporary markdown must not cost a lender their place");
        assertEq(pool.queuedShares(), aliceShares, "and the entry must still be live");

        // And the place is worth keeping: once the mark comes off and the principal comes home,
        // the same entry pays out. Without this half the test would pass just as well against a
        // pool that had frozen the queue permanently, which is the other way to fail this.
        vm.prank(creditManager);
        pool.releaseImpairment(carol);

        uint256 out = pool.outstandingPrincipal();
        vm.prank(creditManager);
        usdc.approve(address(pool), out);
        vm.prank(creditManager);
        pool.repayPrincipal(out);

        pool.serviceQueue(10);
        assertGt(pool.claimable(alice), 0, "the entry it kept must still be payable afterwards");
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
    function test_impairment_aMarkedDownHeadIsRefusedEvenWithCashInThePool() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        uint256 bobsMax = pool.maxWithdraw(bob);
        assertGt(bobsMax, 0, "fixture: there must be a float to drain");
        vm.prank(bob);
        pool.withdraw(bobsMax, bob, bob);

        // One wei back in, which is the whole difference from the test above.
        _setIdleTo(1);
        assertEq(usdc.balanceOf(address(pool)), 1, "fixture: the pool must be holding something");

        // A quarter, and the size is load-bearing. `owed` is `shares * (exitAssets + 1) /
        // (supply + 1000)` and this fixture leaves `exitAssets` at the one wei of idle, so a head
        // holding half the supply or more values at exactly one wei rather than at nothing - which
        // is a different branch and a different open finding, recorded separately. A quarter floors
        // to zero, which is the refusal this test is about.
        uint256 queued = aliceShares / 4;
        vm.prank(alice);
        pool.requestWithdrawal(queued, alice);
        (uint256 placeBefore,) = pool.queuePosition(alice);

        _impair(carol, type(uint128).max);

        // The premises, stated so the branch cannot be entered by accident later: the head is worth
        // nothing at the exit price, it is worth something un-impaired, and there is cash.
        assertEq(pool.previewRedeem(queued), 0, "fixture: the head must value at zero to exit");
        assertGt(pool.convertToAssets(queued), 0, "fixture: and at something un-impaired");
        assertGt(pool.exitReserve(), 0, "fixture: a reserve must actually be standing");

        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(10);

        // The protection.
        assertEq(pool.balanceOf(alice), aliceShares - queued, "the queued shares must stay escrowed");
        assertEq(pool.queuedShares(), queued, "the entry must still be live");
        (uint256 placeAfter,) = pool.queuePosition(alice);
        assertEq(placeAfter, placeBefore, "a temporary markdown must not cost a lender their place");

        // And the cost, which is the open half: the money is there and the queue cannot reach it.
        assertEq(pool.claimable(alice), 0, "nothing was paid out");
        assertEq(usdc.balanceOf(address(pool)), 1, "and the cash sat there unused");

        // Released, it pays. Without this the test would read as well against a permanent freeze.
        vm.prank(creditManager);
        pool.releaseImpairment(carol);
        _setIdleTo(pool.totalAssets());
        pool.serviceQueue(10);
        assertGt(pool.claimable(alice), 0, "the entry it kept must still be payable afterwards");
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
    function test_impairment_aMarkedDownHeadIsNotBurnedInFullForOneWeiOfIdle() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(pool.available());

        uint256 bobsMax = pool.maxWithdraw(bob);
        vm.prank(bob);
        pool.withdraw(bobsMax, bob, bob);
        _setIdleTo(1);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);

        _impair(carol, type(uint128).max);

        // The premise, and it is the finding: the entry values at one wei, not at zero, so the
        // dust guard never sees it.
        assertEq(pool.previewRedeem(aliceShares), 1, "fixture: the head must value at exactly one wei");
        assertGt(pool.convertToAssets(aliceShares), 1e6, "fixture: and be worth real money un-impaired");

        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(10);

        assertEq(pool.queuedShares(), aliceShares, "a whole position was crystallised for one wei");
        assertEq(pool.claimable(alice), 0, "and paid out at a price that values it at nothing");
        assertEq(pool.balanceOf(address(pool)), aliceShares, "the escrow must still hold the entry");
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
    function test_exit_queueingDuringALiquidationBuysNoBetterPrice() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(4_000e6);

        _impair(carol, 2_000e6);

        // Joining and cancelling both stay open, and neither was ever the hazard - a gate on
        // `requestWithdrawal` would have left a lender unable even to take their place in line.
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        assertEq(pool.queuedShares(), shares, "queueing must stay available");

        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        assertEq(pool.queuedShares(), 0, "and so must cancelling");

        // What the front door would pay, read at the moment she commits rather than earlier. A new
        // deposit between the two would legitimately move it: an entrant pays the un-impaired price
        // and so subsidises the mark, which is `test_impairment_anEntrantCannotBuyTheDiscount`.
        uint256 immediatePrice = pool.previewRedeem(shares);
        assertLt(immediatePrice, DEPOSIT, "the fixture must have something marked for this to mean anything");

        // **Audit round 16: the queue now buys no service at all while a reserve stands**, so it
        // certainly buys no better price. Restated rather than softened - the claim in the name is
        // stronger under the new refusal, not weaker, and asserting the refusal is what keeps it a
        // test of the queue rather than of the front door.
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(1);

        // The mark comes off, and only then does the queue pay. What it pays is the point: the
        // price she would have got at the front door at the moment she committed is the floor she
        // never fell below, and the release is what restores it.
        vm.prank(creditManager);
        pool.releaseImpairment(carol);
        pool.serviceQueue(1);
        vm.prank(alice);
        pool.claim();

        assertGe(usdc.balanceOf(alice), immediatePrice, "waiting in the queue paid worse than leaving would have");
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
    ///      `requestWithdrawal`, `serviceQueue` and `claim` are all permissionless and compose in
    ///      one transaction, so a lender could join the queue and pay themselves out at the pre-loss
    ///      price in the block the auction opened. Worse than the door that had been shut: servicing
    ///      draws on `_poolBalance()` where `redeem` is bounded by `unreservedIdle()`, so the queue
    ///      route also reaches the `RESERVE_RATIO_BPS` float.
    ///
    ///      That extra reach is *still true* and is now harmless, which is the whole argument for
    ///      pricing over gating: the composite gets a lender more liquidity, never a better price.
    ///      A gate has to enumerate every door and this one was missed; the price is on the
    ///      valuation every door shares.
    function test_exit_cannotBeSelfServicedOutOfTheQueueAtAnUnimpairedPrice() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(6_000e6);

        _impair(carol, 3_000e6);

        uint256 impairedPrice = pool.previewRedeem(aliceShares);
        uint256 unimpairedPrice = pool.convertToAssets(aliceShares);
        assertLt(impairedPrice, unimpairedPrice, "fixture: the two prices must diverge, or this proves nothing");

        // The composite, in the order and with the callers an attacker would use. Every one of
        // these is permissionless and they fit in a single transaction.
        //
        // **The conclusion changed in audit round 16 and the property did not.** This used to
        // assert the composite *paid the impaired price*. Since the refusal moved onto its cause,
        // the composite pays nothing at all while a reserve stands, so the claim in the name holds
        // a fortiori rather than differently. The assertion is restated rather than deleted,
        // because "cannot exit at the pre-loss price" and "cannot exit" are different facts and the
        // second one is what the code now says.
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.QueueHeldByReserve.selector, pool.exitReserve()));
        pool.serviceQueue(1);
        assertEq(pool.claimable(alice), 0, "the composite set aside money while a reserve stood");

        // And the front door, which is the exit that stays open: it pays the impaired price, so
        // there is no route out at the un-impaired one either way. Without this half the test would
        // read as well against a pool that had frozen every exit, which is the mechanism audit
        // round 10 shipped and audit round 11 took apart.
        vm.prank(alice);
        pool.cancelWithdrawalRequest();
        uint256 exitable = pool.maxRedeem(alice);
        assertGt(exitable, 0, "the front door must stay open, or this is a freeze rather than a price");
        vm.prank(alice);
        pool.redeem(exitable, alice, alice);

        assertLt(usdc.balanceOf(alice), unimpairedPrice, "a lender walked out at the pre-loss price");
        assertLe(usdc.balanceOf(alice), impairedPrice, "and never above what the impaired book allows");
    }

    /// @dev The other half: someone already queued before the liquidation opened is marked down
    ///      like everybody else. Their shares stay outstanding and stay exposed while they wait,
    ///      which is the promise the whole queue design rests on - and it is a promise about the
    ///      valuation, so it survived the mechanism change underneath it.
    function test_exit_anAlreadyQueuedLenderIsMarkedDownLikeEveryoneElse() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        _lend(6_000e6);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        (, uint256 owedBefore) = pool.queuePosition(alice);

        _impair(carol, 3_000e6);

        (, uint256 owedAfter) = pool.queuePosition(alice);
        // Two equal holders, a 3,000 mark: alice's half is 1,500.
        assertApproxEqAbs(owedAfter, owedBefore - 1_500e6, 1, "waiting in line did not carry the mark");

        // The loss then actually lands and the mark comes off. What she is paid must not move:
        // the estimate was right, so recognising it changes nothing for her.
        vm.startPrank(creditManager);
        pool.socialiseLoss(3_000e6);
        pool.releaseImpairment(carol);
        vm.stopPrank();

        pool.serviceQueue(5);
        vm.prank(alice);
        pool.claim();

        assertApproxEqAbs(usdc.balanceOf(alice), owedAfter, 2, "the price she waited at is not the price she got");
        assertApproxEqAbs(usdc.balanceOf(alice), DEPOSIT - 1_500e6, 2, "alice bore her half");
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
        fresh.serviceQueue(1);
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

    function test_requestWithdrawal_escrowsSharesAndRecordsAPosition() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        assertEq(pool.balanceOf(alice), 0, "shares moved to escrow");
        assertEq(pool.balanceOf(address(pool)), shares);
        assertEq(pool.queuedShares(), shares);
        assertEq(pool.totalSupply(), shares, "and are still outstanding");

        (uint256 index, uint256 remaining) = pool.queuePosition(alice);
        assertEq(index, 0, "first in line");
        assertEq(remaining, DEPOSIT);
    }

    /// @dev **The reason escrowed shares stay live.** Burning at request time would let a lender
    ///      who sees trouble queue, stop being exposed, and leave the loss to whoever stayed -
    ///      which is exactly the incentive that turns a wobble into a run.
    function test_queuedLendersTakeTheirShareOfALossLikeEveryoneElse() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);

        (, uint256 owedBefore) = pool.queuePosition(alice);

        vm.prank(creditManager);
        pool.socialiseLoss(2_000e6);

        (, uint256 owedAfter) = pool.queuePosition(alice);
        assertLt(owedAfter, owedBefore, "queueing is a place in line, not an exit from risk");
        assertEq(owedAfter, pool.convertToAssets(bobShares), "and it is the same damage bob takes");
    }

    /// @dev Equally, they keep earning while they wait. The symmetry is the point: escrow is not
    ///      a penalty box, it is simply not an exit.
    /// @dev Escrowed shares stay outstanding, so they keep earning. Since finding 6 the earning
    ///      arrives on a clock rather than in a step, and this test says so in both directions:
    ///      waiting in the queue is not an exit from the stream, and it is not early access to it
    ///      either.
    function test_queuedLendersKeepEarningWhileTheyWait() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (, uint256 owedBefore) = pool.queuePosition(alice);

        _distributeYield(1_000e6);

        (, uint256 owedAtDelivery) = pool.queuePosition(alice);
        assertEq(owedAtDelivery, owedBefore, "no step at the moment of delivery, for them either");

        skip(Config.YIELD_STREAM_DURATION);

        (, uint256 owedAfter) = pool.queuePosition(alice);
        assertGt(owedAfter, owedBefore);
    }

    function test_requestWithdrawal_refusesASecondOne() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.startPrank(alice);
        pool.requestWithdrawal(shares / 2, alice);
        vm.expectRevert(abi.encodeWithSelector(LenderPool.AlreadyQueued.selector, 0));
        pool.requestWithdrawal(shares / 2, alice);
        vm.stopPrank();
    }

    /// @dev PRD §6.4: the queue cannot be jumped.
    function test_serviceQueue_paysInOrderAndCannotBeJumped() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        (uint256 aliceIndex,) = pool.queuePosition(alice);
        (uint256 bobIndex,) = pool.queuePosition(bob);
        assertEq(aliceIndex, 0);
        assertEq(bobIndex, 1);

        // Only enough comes back for the first of them.
        _setIdleTo(DEPOSIT);
        pool.serviceQueue(10);

        assertEq(pool.claimable(alice), DEPOSIT, "the head was paid");
        assertEq(pool.claimable(bob), 0, "and the queue was not jumped");
        _claim(alice);
        assertEq(usdc.balanceOf(alice), DEPOSIT, "and the payout is collectable");

        (uint256 bobIndexNow,) = pool.queuePosition(bob);
        assertEq(bobIndexNow, 0, "bob is now next");
    }

    /// @dev PRD §6.4: partial fills. One large request must not block every small one behind it
    ///      until it can be paid in full.
    function test_serviceQueue_partiallyFillsTheHeadRatherThanStalling() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        _setIdleTo(3_000e6);
        pool.serviceQueue(10);

        _claim(alice);
        assertEq(usdc.balanceOf(alice), 3_000e6);
        (uint256 index, uint256 remaining) = pool.queuePosition(alice);
        assertEq(index, 0, "still at the head");
        assertApproxEqAbs(remaining, DEPOSIT - 3_000e6, 1, "and still owed the rest");
    }

    /// @notice Audit round 23, finding 12. A partial fill rounds the unit debit UP, and this is the
    ///         assertion that can tell which way it rounds.
    ///
    /// @dev **The four #246 principal-unit invariants do not discriminate this.** Measured in round
    ///      23: flipping `serviceQueue`'s `unitsToBurn` ceiling to a floor leaves all four green at
    ///      128,000 calls each, and **3 of 5 campaigns never reach a partial fill at all**.
    ///      Re-measured here on 2026-08-22 against this tree: all 29 lender invariants, including
    ///      the four, pass at `(runs: 256, calls: 128000, reverts: 0)` with the ceiling flipped to a
    ///      floor - cache cleared, unseeded, one invocation - while the assertion below goes red one
    ///      wei wide.
    ///
    ///      **And the campaign's own reach instrument is provably a coin flip.** Round 23's
    ///      `invariant_A23_10_partialFillsNeverHappen` asserts `reached == 0`, so it FAILS when a
    ///      partial fill is reached. It fired at run 161 on the round-23 baseline seed; on seed
    ///      `0x55ccdadb2b3b9336f404ed80090349e8225ac8fe3d93db1cf925ba53bbfd0a4c`, one independent
    ///      invocation with `cache/invariant` cleared, it did not fire in 256 runs at all. Eight of
    ///      the nine sibling censuses in the same bundle still fire, so the instruments work; this
    ///      one moved. **A zero from an unseeded campaign reads as proof of impossibility and is
    ///      not.** A branch a campaign may never enter cannot be guarded by that campaign. This
    ///      test enters it deterministically, which is why it exists at all.
    ///
    ///      **The premise is asserted before the property, and it is the whole test.** Ceil and
    ///      floor differ by at most one unit, so on an exact ratio *both* rounding modes satisfy
    ///      every assertion below and the test would pass against the defect it is named for. The
    ///      `assertEq(ceil, floor + 1)` line is therefore load-bearing: it fails the fixture rather
    ///      than the contract if the trace stops being one wei wide. Every queue test written
    ///      before yield exists in this file inherits an exact 1000:1 ratio, which is exactly how
    ///      this branch went unguarded.
    ///
    ///      **Why UP is the correct direction.** The residual entry keeps `requestUnits - unitsToBurn`.
    ///      Rounding the debit down leaves the entry holding a unit whose principal has already left
    ///      through the fill, and `_burnPrincipalUnits` debits `netDeposits` in proportion to units
    ///      burned - so a floor here under-debits the deposit-cap counter on every partial fill and
    ///      lets residual principal accumulate against the cap. That is round-22 finding 3's
    ///      cap-loosening direction, reached through the queue instead of through the doors.
    function test_R23F12_aPartialFillRoundsTheUnitDebitUp() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        // The skip is load-bearing for the same reason it is two tests down: at the instant of
        // delivery the ratio is still exactly 1000:1 and nothing here would be inexact.
        _distributeYield(333_333_333);
        skip(Config.YIELD_STREAM_DURATION);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        (,, uint256 entryShares) = pool.queueEntry(0);
        uint256 entryUnits = pool.queueEntryPrincipalUnits(0);
        uint256 totalUnitsBefore = pool.totalPrincipalUnits();
        uint256 netDepositsBefore = pool.netDeposits();
        assertGt(entryUnits, 0, "fixture: the entry carries no principal units to round");

        _setIdleTo(3_000e6);
        pool.serviceQueue(10);

        (,, uint256 entrySharesAfter) = pool.queueEntry(0);
        uint256 entryUnitsAfter = pool.queueEntryPrincipalUnits(0);
        uint256 sharesBurned = entryShares - entrySharesAfter;
        assertGt(entrySharesAfter, 0, "fixture: the fill was not partial, so no rounding happened");
        assertGt(sharesBurned, 0, "fixture: nothing was filled");

        uint256 roundedUp = Math.mulDiv(entryUnits, sharesBurned, entryShares, Math.Rounding.Ceil);
        uint256 roundedDown = Math.mulDiv(entryUnits, sharesBurned, entryShares, Math.Rounding.Floor);

        emit log_named_uint("R23F12 entry units before ", entryUnits);
        emit log_named_uint("R23F12 entry shares before", entryShares);
        emit log_named_uint("R23F12 shares burned      ", sharesBurned);
        emit log_named_uint("R23F12 units burned       ", entryUnits - entryUnitsAfter);
        emit log_named_uint("R23F12 ceiling            ", roundedUp);
        emit log_named_uint("R23F12 floor              ", roundedDown);

        // THE PREMISE. One wei wide, or this test cannot see the direction at all.
        assertEq(roundedUp, roundedDown + 1, "fixture: the ratio is exact here, so this discriminates nothing");

        assertEq(entryUnits - entryUnitsAfter, roundedUp, "the unit debit did not round up");
        assertEq(entryUnitsAfter, entryUnits - roundedUp, "the residual entry kept a unit it no longer backs");
        assertEq(
            totalUnitsBefore - pool.totalPrincipalUnits(),
            roundedUp,
            "the aggregate unit counter moved by a different amount than the entry did"
        );
        // And the consequence the direction is chosen for: the cap counter is debited for the
        // principal that actually left, never less.
        assertGt(netDepositsBefore, pool.netDeposits(), "a partial fill did not debit the deposit-cap counter");
    }

    function test_serviceQueue_clearsTheEntryAndTheHeadWhenFullyPaid() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        _setIdleTo(DEPOSIT);
        pool.serviceQueue(10);

        assertEq(pool.queuedShares(), 0);
        assertEq(pool.queueHead(), 1);
        assertEq(pool.balanceOf(address(pool)), 0, "escrow emptied");
        assertEq(pool.totalSupply(), 0, "and the shares burned");

        (uint256 index, uint256 remaining) = pool.queuePosition(alice);
        assertEq(index, 0);
        assertEq(remaining, 0);
    }

    /// @dev The test above passes for a reason that has nothing to do with the queue: the first
    ///      deposit mints `S = 1000 * A`, so `(A+1)/(S+1000)` is exactly 1/1000 and both of
    ///      `serviceQueue`'s conversions are lossless. Every queue test in this file inherits that
    ///      alignment. One epoch of yield destroys it, and yield is the pool's normal operation -
    ///      so the aligned case is the special one and it is the only case being tested.
    ///
    ///      With the ratio inexact, `convertToAssets` then `convertToShares` both floor, so the
    ///      shares burned come back short of the shares owed and the entry never reaches zero.
    function test_serviceQueue_clearsTheEntryWhenTheShareRatioIsNotExact() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        // The skip is load-bearing, not tidiness: since finding 6 the epoch lands on a clock, and
        // at the instant of delivery the share ratio is still exactly 1000:1. Without it this test
        // sets up none of the inexactness it is named for and passes on the wrong premise.
        _distributeYield(333_333_333);
        skip(Config.YIELD_STREAM_DURATION);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        _setIdleTo(pool.totalAssets());
        pool.serviceQueue(10);

        assertEq(pool.queuedShares(), 0, "a dust residual left the entry live");
        assertEq(pool.queueHead(), 1, "the head never advanced past a fully paid lender");
        assertEq(pool.balanceOf(address(pool)), 0, "escrow emptied");

        // And the mapping released them, so they are not locked out of ever queueing again.
        vm.prank(alice);
        vm.expectRevert(LenderPool.NothingQueued.selector);
        pool.cancelWithdrawalRequest();
    }

    /// @dev The consequence, and the reason the entry above matters beyond one lender's tidiness.
    ///      An entry that cannot be cleared is at the head forever. `convertToAssets(residual)`
    ///      floors to zero, so servicing must release and step past it: otherwise everyone behind
    ///      is blocked, `serviceQueue` reverts for good, and because `queuedShares` never returns
    ///      to zero, `available()` is pinned at zero and the pool can never lend again.
    ///
    ///      **This test could not enter the branch it is named for until audit round 15, and it
    ///      would have passed against a `serviceQueue` with the dust branch deleted entirely.**
    ///      Observed, not argued: deleting `if (convertToAssets(shares) != 0) break;` leaves the
    ///      old version green. It queued two lenders holding whole positions and funded both, so
    ///      no entry was ever worth zero and no release ever ran. The dust is now real and is
    ///      asserted to be dust before the act, because the premise is the test.
    ///
    ///      One share-wei is dust by construction here: at a decimals offset of three the price is
    ///      about a thousand shares to the asset-wei, so any conversion of one share floors to
    ///      nothing. Asserted rather than assumed, so a change to the offset fails here loudly
    ///      instead of quietly retiring the branch.
    function test_serviceQueue_dustAtTheHeadIsReleasedAndTheQueueMovesOn() public {
        _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        // See the sibling test above: the epoch has to land before the ratio is inexact.
        _distributeYield(333_333_333);
        skip(Config.YIELD_STREAM_DURATION);
        _lend(pool.available());

        // Dust at the head, and a whole position behind it. Alice goes first with one share-wei.
        assertEq(pool.convertToAssets(1), 0, "one share-wei is not dust here - the fixture ratio moved");
        vm.prank(alice);
        pool.requestWithdrawal(1, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        assertEq(pool.queueHead(), 0, "fixture: the dust must be the head");

        uint256 aliceHeldBefore = pool.balanceOf(alice);
        _setIdleTo(pool.totalAssets());
        pool.serviceQueue(10);

        // The release half, which had no assertion anywhere before audit round 15: the shares go
        // back to their owner rather than being burned for nothing, and the request is cleared so
        // the lender is not locked out of ever queueing again.
        assertEq(pool.balanceOf(alice), aliceHeldBefore + 1, "the dust was not handed back to its owner");
        vm.prank(alice);
        vm.expectRevert(LenderPool.NothingQueued.selector);
        pool.cancelWithdrawalRequest();

        // And the walk did not stop on it.
        assertGt(pool.claimable(bob), 0, "the lender behind the dust was never paid");
        assertEq(pool.queuedShares(), 0, "the queue never emptied");
        assertEq(pool.queueHead(), 2, "the head did not advance past both entries");
        _claim(bob);
        assertGt(pool.available(), 0, "the pool can never lend again");
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
    function test_serviceQueue_budgetSpentOnCancelledEntriesStillMakesProgress() public {
        // Three lenders inside the 25,000e6 deposit cap, so a third of it each rather than DEPOSIT.
        uint256 each = 8_000e6;
        uint256 aliceShares = _deposit(alice, each);
        uint256 bobShares = _deposit(bob, each);
        uint256 carolShares = _deposit(carol, each);
        _lend(pool.available());

        // Alice at the head, then two husks behind her, then Carol.
        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        vm.prank(bob);
        pool.cancelWithdrawalRequest();
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        vm.prank(bob);
        pool.cancelWithdrawalRequest();
        vm.prank(carol);
        pool.requestWithdrawal(carolShares, carol);

        _setIdleTo(pool.totalAssets());

        // Pays Alice and stops on budget, leaving the head sitting on the first husk.
        pool.serviceQueue(1);
        assertEq(pool.claimable(alice), each, "alice should have been paid");
        assertEq(pool.queueHead(), 1, "the head should have advanced onto the first husk");

        // A budget of one now buys one husk-step and no payment. It must still commit that step.
        pool.serviceQueue(1);
        assertEq(pool.queueHead(), 2, "the husk step was rolled back");

        // Which means repeated bounded calls always get there in the end.
        pool.serviceQueue(1);
        pool.serviceQueue(1);
        assertEq(pool.claimable(carol), each, "carol was stranded behind the husks");
        assertEq(pool.queuedShares(), 0, "the queue never emptied");
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
    function test_cancel_returnsTheSharesAndTheQueuePosition() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        // Half, not all: lending everything leaves idle sitting exactly on the reserve, so
        // `available()` would be zero after the cancel for that reason rather than because of the
        // queue, and the assertion below would prove nothing.
        _lend(pool.available() / 2);

        vm.startPrank(alice);
        pool.requestWithdrawal(shares, alice);
        pool.cancelWithdrawalRequest();
        vm.stopPrank();

        assertEq(pool.balanceOf(alice), shares);
        assertEq(pool.queuedShares(), 0);
        assertEq(pool.available() > 0, true, "and the pool can lend again");

        // And they may re-queue, losing their place, which is the honest price of changing mind.
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);
        (uint256 index,) = pool.queuePosition(alice);
        assertEq(index, 0);
    }

    function test_cancel_revertsWithNothingQueued() public {
        vm.prank(alice);
        vm.expectRevert(LenderPool.NothingQueued.selector);
        pool.cancelWithdrawalRequest();
    }

    /// @dev A cancelled entry is left in place with zero shares so indices stay stable in events.
    ///      Servicing has to step over it rather than stop at it.
    function test_serviceQueue_stepsOverACancelledEntry() public {
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
        pool.serviceQueue(10);

        assertEq(pool.claimable(bob), DEPOSIT, "bob was paid past the hole alice left");
        assertEq(pool.claimable(alice), 0);
    }

    function test_serviceQueue_isPermissionlessButBounded() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT);
        _lend(pool.available());

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);
        _setIdleTo(2 * DEPOSIT);

        vm.prank(makeAddr("a passing keeper"));
        uint256 serviced = pool.serviceQueue(1);
        assertEq(serviced, 1, "bounded by maxEntries");
        assertEq(pool.claimable(bob), 0);

        pool.serviceQueue(1);
        assertEq(pool.claimable(bob), DEPOSIT);
        _claim(bob);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
    }

    /// @dev Two different "nothing to do" states, and they are worth telling apart. An empty queue
    ///      means nobody is waiting; a queue with no idle USDC behind it means somebody is waiting
    ///      and the money has not come back yet. A keeper polling this needs to know which.
    function test_serviceQueue_distinguishesAnEmptyQueueFromAnUnfundedOne() public {
        vm.expectRevert(LenderPool.QueueIsEmpty.selector);
        pool.serviceQueue(1);

        uint256 shares = _deposit(alice, DEPOSIT);
        _lend(pool.available());
        vm.prank(alice);
        pool.requestWithdrawal(shares, alice);

        // The reserve is still sitting here, so the first call does real work: a partial fill that
        // takes the idle balance to zero.
        uint256 paid = pool.serviceQueue(10);
        assertEq(paid, 1);
        // The USDC is still in the contract, but it is set aside for alice and is no longer the
        // pool's to pay anyone else with - which is what `_poolBalance` exists to express.
        assertEq(pool.totalClaimable(), usdc.balanceOf(address(pool)), "all of it is spoken for");
        assertEq(pool.unreservedIdle(), 0, "idle drained into the partial fill");

        // Now there is a queue and nothing to pay it with, which is the other state.
        vm.expectRevert(LenderPool.NothingToService.selector);
        pool.serviceQueue(1);
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
    ///      `serviceQueue` call forever - freezing every lender behind it and all lending with it.
    ///      `MockUSDC` models the blacklist because real USDC on Base has one.
    function test_serviceQueue_survivesAReceiverThatCannotBePaid() public {
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

        // The queue drains regardless: nothing is pushed, so nothing can refuse delivery.
        pool.serviceQueue(10);
        assertEq(pool.queuedShares(), 0, "the queue was bricked by one entry");
        assertEq(pool.claimable(bob), DEPOSIT, "the lender behind was never paid");

        // Only the blocked receiver's own claim fails, and only when they try to take it.
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
        pool.serviceQueue(10);
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
    ///      After a stranger's free `serviceQueue` the shares are burned and the money sits under
    ///      the **receiver's** name. `claimFor` widens who may pull that money out; it does not
    ///      give the owner back the ability to undo the conversion. Recorded as an assertion so the
    ///      next round reads the residual rather than the sweep.
    function test_claimFor_doesNotRestoreTheOwnersCancelledPosition() public {
        address frozen = makeAddr("blacklistedReceiver");
        _serviceInFavourOf(frozen);
        usdc.setBlocked(frozen, true);

        assertEq(pool.balanceOf(alice), 0, "the owner still holds shares, so nothing was crystallised");
        vm.prank(alice);
        vm.expectRevert(LenderPool.NothingQueued.selector);
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
        pool.serviceQueue(10);

        uint256 priceAfterFill = pool.convertToAssets(bobShares);
        _claim(alice);
        assertEq(pool.convertToAssets(bobShares), priceAfterFill, "collecting moved the share price");
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
    function _serviceAndClaim(uint256 maxEntries, address[] memory receivers) internal {
        pool.serviceQueue(maxEntries);
        for (uint256 i = 0; i < receivers.length; i++) {
            if (pool.claimable(receivers[i]) == 0) continue;
            vm.prank(receivers[i]);
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
    ///      `serviceQueue` refuses entirely under a mark, so a lender who queues reserves a claim
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
    ///        a bystander's free `serviceQueue` burns a queued lender's whole 3,750,000,000,000
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
    function test_queueReservation_theGoldfinchClampIsInertHere() public {
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);
        // Lend the book down to the float, which is the state the queue exists for.
        _lend(pool.available());

        uint256 victimBefore = pool.maxWithdraw(bob);
        assertGt(victimBefore, 0, "control: the unqueued lender's door is open before the park");

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);

        emit log_named_uint("F7 victim maxWithdraw before the park", victimBefore);
        emit log_named_uint("F7 victim maxWithdraw after the park ", pool.maxWithdraw(bob));
        emit log_named_uint("F7 unreservedIdle                    ", pool.unreservedIdle());
        emit log_named_uint("F7 the parker reserved               ", _queueClaimCeil());
        emit log_named_uint("F7 the pool actually holds           ", _poolBalanceFromPublicReads());

        // The harm, in one line: one free call by one lender zeroed a different lender's quote.
        assertEq(pool.maxWithdraw(bob), 0, "the park did not shut the unqueued lender's door");

        // ── the prescribed clamp, built ──────────────────────────────────────
        uint256 idle = _poolBalanceFromPublicReads();
        uint256 owed = _queueClaimCeil();
        uint256 clampedReservation = owed < idle ? owed : idle;

        assertEq(idle - clampedReservation, pool.unreservedIdle(), "the clamp moved unreservedIdle");
        assertEq(
            _availableUnderTheClamp(idle, clampedReservation),
            pool.available(),
            "the clamp moved available()"
        );
        assertGt(owed, idle, "fixture: the clamp must actually bind, or this proves nothing");
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
                conserved + 2,
                valueBefore,
                "a mark somewhere in this range destroys book value that nobody realised"
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
    ///      ERC-4626 also forbids any of the four from reverting. None of them makes an external
    ///      call and every conversion is a `mulDiv` whose result is bounded by an input, so calling
    ///      them here is the assertion.
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
    ///      idle cash binding, the derived figure is exactly **one wei lower** and never higher:
    ///      8,304.579169 against 8,304.579170, found in six fuzz runs once a donation is in the
    ///      fixture.
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
    function testFuzz_R22F2_theBoundIsInertWhileNothingIsReserved(
        uint256 lentSeed,
        uint256 heldSeed,
        uint256 donationSeed
    ) public {
        uint256 held = bound(heldSeed, 1e6, DEPOSIT);
        _deposit(alice, held);
        _deposit(bob, DEPOSIT);

        // **Breaks the exact 1000:1 share ratio, and without this the test is far weaker than it
        // reads.** A pool built only out of deposits sits at exactly `10 ** offset` shares per
        // asset, and on that ratio every conversion here round-trips exactly - so a fuzz over
        // deposit sizes alone reports inertness for an expression that is inert only on that one
        // ratio. MEASURED: without this line an `assertEq` here passes 256 runs; with it the same
        // `assertEq` fails on run six, at one wei. A donation is the shortest route to an inexact
        // price, because `totalAssets()` reads a raw `balanceOf` - the same reachability
        // `maxDeposit`'s NatSpec is written around.
        usdc.mint(address(pool), bound(donationSeed, 0, DEPOSIT));

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

    /// @notice A deposit may not mint zero shares.
    /// @dev The poisoned end state this finding leads to, closed from the other side. Once the
    ///      share price is high enough that a deposit rounds to nothing, `deposit` used to take the
    ///      USDC and mint nothing for it - a silent, total loss for the depositor and a windfall for
    ///      everyone already in. Reached here by the shortest honest route rather than through the
    ///      crush: `totalAssets()` reads a raw `balanceOf`, so a donation moves the price without
    ///      minting anything, which is the same donation `maxDeposit`'s NatSpec is written around.
    ///
    ///      `mint` is unaffected in practice - it is quoted in shares, so a caller asking for zero
    ///      shares is the only way to reach this from that side, and refusing that is right too.
    function test_R22F2_depositCannotMintZeroShares() public {
        _deposit(alice, 1);
        usdc.mint(address(pool), 1_000e6);

        assertEq(pool.previewDeposit(1), 0, "fixture: this deposit must be the zero-share one");

        vm.expectRevert(LenderPool.ZeroAmount.selector);
        vm.prank(bob);
        pool.deposit(1, bob);

        // CONTROL: the same pool still takes a deposit large enough to buy a share.
        vm.prank(bob);
        assertGt(pool.deposit(1e6, bob), 0, "a real deposit was refused as well");
    }


    // ── round-28 item 10 (round-25 A6 F4): the pool refuses entry while paused ──
    //
    // The pause shuts `deposit` and `mint` and nothing else. Every test below that touches an exit
    // is there to hold that line: `withdraw`, `redeem`, `requestWithdrawal`, `serviceQueue` and
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
        // Three lenders under the 25,000.000000 cap, so the fixture is refused for nothing but the
        // reason under test.
        uint256 stake = 8_000e6;
        uint256 aliceShares = _deposit(alice, stake);
        _deposit(bob, stake);
        uint256 carolShares = _deposit(carol, stake);

        vm.prank(admin);
        pool.pause();

        // 1. The immediate pair, priced exactly as they would be with the door open.
        uint256 quoted = pool.previewRedeem(aliceShares / 2);
        vm.prank(alice);
        uint256 paid = pool.redeem(aliceShares / 2, alice, alice);
        assertEq(paid, quoted, "redeem was repriced by the pause");

        uint256 assets = pool.maxWithdraw(bob);
        assertGt(assets, 0, "maxWithdraw went to zero, which would be an exit shut by the pause");
        vm.prank(bob);
        pool.withdraw(assets, bob, bob);

        // 2. The queue, and the pull payment at the end of it. Lend the float out first so the
        //    request cannot simply be paid from idle - the queue is the exit that matters here.
        _lend(pool.available());
        vm.prank(carol);
        pool.requestWithdrawal(carolShares, carol);
        assertEq(pool.queuedShares(), carolShares, "a queued exit was refused while paused");

        _repay(stake);
        vm.prank(alice);
        uint256 serviced = pool.serviceQueue(5);
        assertGt(serviced, 0, "the servicing walk was shut by the pause");

        uint256 owed = pool.claimable(carol);
        assertGt(owed, 0, "the queue paid nothing");
        uint256 heldBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        pool.claim();
        assertEq(usdc.balanceOf(carol) - heldBefore, owed, "the pull payment was shut by the pause");
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
    function _queueClaimCeil() internal view returns (uint256) {
        return Math.mulDiv(pool.queuedShares(), pool.totalAssets() + 1, pool.totalSupply() + 1_000, Math.Rounding.Ceil);
    }

    function _availableUnderTheClamp(uint256 idle, uint256 clampedReservation) internal view returns (uint256) {
        uint256 spare = idle - clampedReservation;
        uint256 float = (pool.totalAssets() * Config.RESERVE_RATIO_BPS) / Config.BPS;
        return spare > float ? spare - float : 0;
    }

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
