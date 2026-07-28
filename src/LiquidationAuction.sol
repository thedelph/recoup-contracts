// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "./Config.sol";
import {LtvMath} from "./LtvMath.sol";
import {ILiquidationAuction} from "./interfaces/ILiquidationAuction.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ICreditManager} from "./interfaces/ICreditManager.sol";
import {INAVOracle} from "./interfaces/INAVOracle.sol";

/// @title LiquidationAuction (PRD §4.5)
/// @notice One Dutch auction per liquidated position, whole lot, single lot in v1.
///         Linear decay from `AUCTION_START_PREMIUM_BPS` x NAV to `AUCTION_FLOOR_BPS`
///         over `AUCTION_DURATION`. Unfilled auctions fall back to a workout against
///         DexFi's manual redemption.
///
/// @dev **Bonds are never escrowed here.** `start` touches no external protocol at all,
///      and the lot only moves when a bid actually settles, adapter straight to winner
///      in one hop. Two reasons, and both are load-bearing:
///
///      1. DexFi gates bond transfers on a whitelist that only the custody adapter is
///         on. A transfer out of this contract would have no whitelisted party on any
///         side and would revert - so escrowing would need a second address whitelisted
///         by DexFi, which is a new ask on the project's largest external dependency.
///      2. Seizing at `start` would put `farm.withdraw` on the path that *triggers* a
///         liquidation. DexFi's farm is a proxy behind a single EOA; if it pauses,
///         liquidation would become impossible exactly when it is most needed.
///
///      The lot therefore stays staked and earning for the life of the auction, and
///      the borrower can still repay their way out of it until someone bids.
///
///      `ERC1155Holder` is retained because the workout path leaves this contract
///      holding a vault *position*, and disposing of that position later withdraws
///      real ERC-1155 units to this address.
///
///      **Exactly three exits, and their preconditions must leave no gap.** `bid`,
///      `cancel` and `expireToWorkout`. Any state where all three revert is permanently
///      stranded collateral, and that - not the individual guards - is the property to
///      test.
contract LiquidationAuction is ILiquidationAuction, ERC1155Holder, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotCreditManager();
    error ZeroAddress();
    error RenounceDisabled();
    error AuctionAlreadyLive(uint256 auctionId);
    error UnknownAuction(uint256 auctionId);
    error AuctionClosed(uint256 auctionId);
    error NothingToAuction(address borrower);
    error NavUnset();
    error StillLiquidatable(uint256 ltvBps);
    error CreditManagerUnset();
    error LotChanged(uint256 expected, uint256 actual);
    error PriceAboveCap(uint256 price, uint256 cap);
    error NothingToClaim();
    error ZeroAmount();
    error AuctionStillRunning(uint256 finishesAt);
    error WorkoutStillRunning(uint256 forceableAt);
    error WorkoutNotOpen(uint256 auctionId);
    error WorkoutNotClosed(uint256 auctionId);
    error AuctionLapsed(uint256 auctionId);
    error NothingToDispose(uint256 auctionId);
    error AuctionHasLiveWork(uint256 outstanding);
    error CreditManagerNotLive(address liveManager);
    error CreditManagerVaultMismatch(address managerVault);

    event CreditManagerSet(address indexed creditManager);
    event CallerRewardAccrued(uint256 indexed auctionId, address indexed caller, uint256 amount);
    event CallerRewardClaimed(address indexed caller, uint256 amount);
    event LiquidationPenaltyTaken(
        uint256 indexed auctionId, address indexed caller, uint256 callerReward, uint256 toInsurance
    );
    /// @param debtAtExpiry Left standing on purpose - the loss is unknown until DexFi pays.
    event WorkoutOpened(uint256 indexed auctionId, address indexed borrower, uint256 bondCount, uint256 debtAtExpiry);
    event WorkoutRecovered(uint256 indexed auctionId, address indexed from, uint256 amount, uint256 totalRecovered);
    /// @param writtenOff Zero on a clean close; the forced residual otherwise.
    event WorkoutClosed(uint256 indexed auctionId, uint256 recovered, uint256 writtenOff);
    event WorkoutYieldSwept(uint256 amount);
    event WorkoutLotDisposed(uint256 indexed auctionId, address indexed to, uint256 bondCount);
    /// @param supersededBy The fresh auction opened over the same position.
    event AuctionSuperseded(uint256 indexed auctionId, address indexed borrower, uint256 supersededBy);

    struct Auction {
        address borrower;
        uint96 startedAt;
        /// @notice Whoever called `liquidate`, and who earns the caller share of the
        ///         penalty if the lot sells above the debt.
        address caller;
        /// @notice Filled, cancelled, or moved to workout. One-way.
        bool settled;
        /// @notice The lot at open. A record for the event and for detecting a lot that
        ///         changed under a bidder - never the figure a fill is priced on.
        uint256 bondCount;
        /// @notice NAV at open, 8dp. The only oracle input this auction will ever have.
        uint256 startNav;
        /// @notice USDC for the whole lot at t=0.
        uint256 startPrice;
        /// @notice Outstanding at open. A record; every settlement re-reads live debt.
        uint256 debt;
    }

    enum WorkoutStatus {
        None,
        Open,
        Closed
    }

    /// @notice A position whose auction expired unfilled, awaiting DexFi's manual
    ///         redemption. The bonds are still staked - only the claim moved here.
    struct Workout {
        address borrower;
        uint96 openedAt;
        WorkoutStatus status;
        uint256 bondCount;
        /// @notice Debt when the auction expired. **This bounds the loss this workout
        ///         may recognise.** Live debt is not a safe substitute: the borrower can
        ///         take a fresh, fully-collateralised loan during the window, and a
        ///         write-off sized from live debt would forgive that too.
        uint256 debtAtExpiry;
        uint256 recovered;
        /// @notice Penalty still collectable, fixed at expiry.
        /// @dev Deriving it from live debt at settlement time meant it was charged
        ///      *never* rather than once: surplus only exists after the debt is zero, and
        ///      the borrower can reach that state themselves with a permissionless,
        ///      never-pausable `repay`. Fixing the base at expiry is the whole fix.
        uint256 penaltyRemaining;
    }

    IERC20 public immutable usdc;
    ICollateralVault internal immutable _vault;
    INAVOracle public immutable navOracle;
    address public creditManager;

    /// @dev Pre-incremented, so id 0 is never issued. `auctionOf[borrower] == 0` is
    ///      then an unambiguous "none" rather than a valid-looking zero struct that
    ///      `bid` would happily operate on.
    uint256 public nextAuctionId;
    mapping(uint256 => Auction) public auctions;
    /// @notice The live auction for a borrower, or 0. One at a time.
    mapping(address => uint256) public auctionOf;

    /// @notice Liquidation caller rewards awaiting collection.
    mapping(address => uint256) public rewardOf;
    /// @notice Sum of `rewardOf`. The only USDC this contract is ever entitled to hold,
    ///         which is what makes "the auction holds nothing at rest" checkable in one
    ///         read - and it needs to be checkable, because this contract is immutable
    ///         and has no sweep.
    uint256 public totalUnclaimedRewards;

    /// @inheritdoc ILiquidationAuction
    /// @dev Incremented on `start` and decremented on every path that settles an
    ///      auction, so the vault can refuse a repoint that would strand work in flight.
    uint256 public override liveAuctionCount;

    /// @inheritdoc ILiquidationAuction
    /// @dev Read by `CreditManager.borrow`. A borrower with an open workout must not be
    ///      able to take a fresh loan: the forced close bounds its write-off by
    ///      `debtAtExpiry - recovered`, and `repayFor` is permissionless and does not
    ///      touch `recovered` - so if anyone clears the defaulted debt that way, live
    ///      debt becomes entirely a new, fully-backed loan and the bound stops binding.
    mapping(address => uint256) public override workoutsOpenFor;

    /// @notice Keyed by the auction id that produced it, so a position keeps one
    ///         identity from liquidation through to loss recognition.
    mapping(uint256 => Workout) public workouts;
    uint256[] private _openWorkouts;
    mapping(uint256 => uint256) private _workoutIndex; // id → index + 1

    constructor(IERC20 usdc_, ICollateralVault vault_, INAVOracle navOracle_, address initialOwner)
        Ownable(initialOwner)
    {
        if (
            address(usdc_) == address(0) || address(vault_) == address(0)
                || address(navOracle_) == address(0)
        ) revert ZeroAddress();
        usdc = usdc_;
        _vault = vault_;
        navOracle = navOracle_;
    }

    /// @dev Matches the live-authority contracts: renouncing would permanently
    ///      freeze wiring on a contract the deploy script already deploys.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev The third leg of the wiring triangle, and the last one to be guarded.
    ///      `cancel` prices a position off *this* pointer while `expireToWorkout` prices
    ///      it off the vault's, and the completeness of the three exits rests on those
    ///      two predicates being exact complements - which they only are while both
    ///      pointers name the same manager. Divergence lets `cancel` close an underwater
    ///      auction for free, or closes every exit at once.
    function setCreditManager(address creditManager_) external onlyOwner {
        if (creditManager_ == address(0)) revert ZeroAddress();
        if (liveAuctionCount != 0) revert AuctionHasLiveWork(liveAuctionCount);
        if (_openWorkouts.length != 0) revert AuctionHasLiveWork(_openWorkouts.length);

        address boundVault = address(ICreditManager(creditManager_).vault());
        if (boundVault != address(_vault)) revert CreditManagerVaultMismatch(boundVault);

        // Sharing a vault is not the same as *being* the vault's manager - several
        // managers can name one immutable vault, so the check above admits a manager
        // this vault has never used. The docstring above claims the property is "both
        // pointers name the same manager"; only this line actually asserts it.
        // `EpochHarvester.setCreditManager` has made the same check since round 6.
        address liveManager = ICollateralVault(address(_vault)).creditManager();
        if (liveManager != creditManager_) revert CreditManagerNotLive(liveManager);

        creditManager = creditManager_;
        emit CreditManagerSet(creditManager_);
    }

    // ── ILiquidationAuction ──────────────────────────────────────────────────

    /// @inheritdoc ILiquidationAuction
    /// @dev Pure bookkeeping. No external protocol is touched, so nothing DexFi does
    ///      can stop a liquidation being opened.
    function start(address borrower, address caller) external nonReentrant returns (uint256 auctionId) {
        if (msg.sender != creditManager) revert NotCreditManager();
        if (borrower == address(0) || caller == address(0)) revert ZeroAddress();

        // A lapsed auction is superseded rather than blocking, and that is a security
        // property, not a convenience. `startNav` is frozen for the life of an auction,
        // and `cancel` - the only thing that clears a healed one - is permissionless,
        // unrewarded and optional. Left to block, a stale ticket becomes a perpetual
        // call option struck at 68% of an arbitrarily old price, fillable whenever the
        // borrower re-levers, while no correctly-priced replacement can ever open.
        //
        // Superseding is also strictly better than the floor fill it replaces: the new
        // auction restarts at 100% of *current* NAV and decays again.
        uint256 live = auctionOf[borrower];
        if (live != 0) {
            if (block.timestamp <= auctions[live].startedAt + Config.AUCTION_DURATION) {
                revert AuctionAlreadyLive(live);
            }
            auctions[live].settled = true;
            liveAuctionCount--;
            emit AuctionSuperseded(live, borrower, nextAuctionId + 1);
        }

        uint256 bonds = _vault.bondCount(borrower);
        // A position with debt and no collateral reads as infinitely levered, so it
        // always passes the health gate. Opening an auction over nothing would let a
        // bidder pay the current price for a lot that seizes zero, silently. The
        // caller's remedy is the shortfall path, not an empty auction.
        if (bonds == 0) revert NothingToAuction(borrower);

        // **NAV is snapshotted, and this auction never reads the oracle again.**
        //
        // A Dutch price must only ever fall. Reading live NAV would let a repost move
        // the price under a bidder who has already computed and signed for it, in
        // either direction: upward it breaks the only strategy a Dutch auction offers
        // ("wait, it gets cheaper"), and downward it breaks the floor's coverage
        // guarantee. `Config.AUCTION_FLOOR_BPS` is sized against exactly *one*
        // max-deviation drop, with 33 bps of margin; a second drop during the auction
        // puts a floor fill below the debt it is supposed to cover.
        //
        // The cost is real and accepted: a genuinely collapsing NAV means the auction
        // is priced too high and does not fill, which routes to the workout path. That
        // is the designed fallback, not a failure.
        uint256 nav = navOracle.navPerBond();
        if (nav == 0) revert NavUnset();

        uint256 startPrice = _lotPrice(bonds, nav, Config.AUCTION_START_PREMIUM_BPS);

        auctionId = ++nextAuctionId;
        auctions[auctionId] = Auction({
            borrower: borrower,
            startedAt: uint96(block.timestamp),
            caller: caller,
            settled: false,
            bondCount: bonds,
            startNav: nav,
            startPrice: startPrice,
            debt: ICreditManager(creditManager).debtOf(borrower)
        });
        auctionOf[borrower] = auctionId;
        liveAuctionCount++;

        emit AuctionStarted(auctionId, borrower, caller, bonds, startPrice);
    }

    /// @inheritdoc ILiquidationAuction
    /// @dev Fills only if the lot is exactly what the auction was opened over. The lot
    ///      is not escrowed, and the one way it can change is the borrower depositing
    ///      more bonds into their own position. That is not theft - the extra units are
    ///      bought at the same price per bond - but a bidder should not discover it
    ///      after the fact. Use the two-argument form to accept whatever the lot has
    ///      become up to a price you name.
    function bid(uint256 auctionId) external nonReentrant {
        _bid(auctionId, 0, true);
    }

    /// @notice Fill at up to `maxPriceUsdc`, whatever the lot has become.
    /// @dev The form a keeper should use: it cannot be griefed by a borrower topping up
    ///      mid-auction, and it bounds what an in-flight transaction can cost.
    function bid(uint256 auctionId, uint256 maxPriceUsdc) external nonReentrant {
        _bid(auctionId, maxPriceUsdc, false);
    }

    /// @notice Withdraw liquidation caller rewards.
    /// @dev Pull, not push. A liquidation caller who is USDC-blacklisted or a contract
    ///      that rejects transfers must not be able to make every bid on the position
    ///      they flagged revert.
    function claimReward() external nonReentrant {
        uint256 amount = rewardOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        rewardOf[msg.sender] = 0;
        totalUnclaimedRewards -= amount;
        emit CallerRewardClaimed(msg.sender, amount);
        usdc.safeTransfer(msg.sender, amount);
    }

    /// @dev The order here is the design.
    ///
    ///      **Effects before interactions, unconditionally.** The lot moves through
    ///      `_vault.seize`, which ends in an ERC-1155 transfer to the winner and so
    ///      hands control to arbitrary code. `nonReentrant` stops that code re-entering
    ///      `bid`, but not `settle`, `repayFor` or `liquidate` - so the auction must
    ///      already be closed and de-registered before the hook can run.
    ///
    ///      **Seize before repaying.** Repaying first would cure the position, and the
    ///      vault refuses to seize a position that is not liquidatable, so the two
    ///      would deadlock. Seizing first also settles the borrower's accrued yield
    ///      against the old bond count on the way through, which is what makes the debt
    ///      read on the next line the real one.
    ///
    ///      **Debt is read after the seize, never from the struct.** An auction runs
    ///      six hours; yield streams over five days; anyone may `repayFor` in between,
    ///      including from inside the winner's own callback. Pricing the settlement off
    ///      `Auction.debt` would under-credit the borrower, and if the stream had
    ///      cleared the loan entirely `repayFor` would revert `NoDebt` and every bid
    ///      for the rest of the auction with it.
    ///
    ///      **Debt first, then penalty, then surplus, clamped at every step.** Near the
    ///      floor `price < debt + penalty` is routine rather than exotic, so an
    ///      unclamped subtraction would panic in exactly the price band where Dutch
    ///      auctions actually fill. Taking the penalty before the debt would manufacture
    ///      a shortfall the insurance fund then covers, which is paying the liquidation
    ///      caller out of insurance.
    function _bid(uint256 auctionId, uint256 maxPriceUsdc, bool pinned) private {
        Auction storage a = _live(auctionId);
        address borrower = a.borrower;
        address cm = creditManager;
        if (cm == address(0)) revert CreditManagerUnset();

        uint256 lot = _vault.bondCount(borrower);
        if (lot == 0) revert NothingToAuction(borrower);
        if (pinned && lot != a.bondCount) revert LotChanged(a.bondCount, lot);

        // Bids stop when the window does. An earlier version kept them legal at the
        // floor indefinitely, on the argument that a floor fill beats a 90%-of-NAV
        // manual redemption - but `AUCTION_FLOOR_BPS` is derived against a NAV at most
        // one deviation step stale, and past the window nothing bounds the staleness of
        // `startNav` at all, so the number being charged stops meaning what the
        // constant proves. Recovery is not lost: `liquidate` supersedes a lapsed
        // auction and reprices from scratch, which is better than a stale floor.
        // Strictly after, so the floor price is actually reachable at the last instant
        // of the window rather than being an asymptote nobody can fill at.
        if (block.timestamp > a.startedAt + Config.AUCTION_DURATION) revert AuctionLapsed(auctionId);

        uint256 price = _lotPrice(lot, a.startNav, _premiumBps(a.startedAt));
        if (!pinned && price > maxPriceUsdc) revert PriceAboveCap(price, maxPriceUsdc);

        // Snapshotted here, before a single external call. The penalty base used to be
        // read inside `_settleFill`, which runs after `seize` has handed control to the
        // winner's ERC-1155 hook - so a borrower bidding through their own contract
        // could `repayFor` themselves inside the callback, drive live debt to zero, and
        // pay no penalty and no caller reward. The workout path was frozen at expiry for
        // exactly this reason and the fill path was left reading live debt; both halves
        // of the same bug were documented on adjacent lines and only one was fixed.
        uint256 penaltyDue =
            (ICreditManager(cm).currentDebtOf(borrower) * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS;

        a.settled = true;
        liveAuctionCount--;
        delete auctionOf[borrower];

        usdc.safeTransferFrom(msg.sender, address(this), price);
        _vault.seize(borrower, msg.sender);
        _settleFill(auctionId, borrower, cm, price, penaltyDue);
    }

    /// @dev Split out of `_bid` because the two together do not fit in the EVM's stack.
    ///      The seam is deliberate: everything above it is checks and effects, and
    ///      everything here runs after the winner's callback has already had its turn.
    /// @dev `penaltyDue` is passed in rather than computed here: this runs after the
    ///      winner's callback, so any figure read at this point is attacker-influenced.
    function _settleFill(uint256 auctionId, address borrower, address cm, uint256 price, uint256 penaltyDue)
        private
    {
        (uint256 repaid,) = _distribute(auctionId, borrower, cm, price, penaltyDue, true);
        emit AuctionFilled(auctionId, msg.sender, price, repaid, price - repaid);
    }

    /// @dev The one place proceeds are shared out, used by both recovery paths so they
    ///      cannot drift apart on who gets paid what.
    ///
    ///      `recogniseShortfall` is the only difference between them. A fill resolves
    ///      the position in one go, so anything the sale did not cover is a loss, now.
    ///      A workout may pay in tranches, so writing the gap down on the first one
    ///      would socialise a loss the second one covers - there, recognition waits for
    ///      `closeWorkout`.
    ///
    ///      Debt first, then penalty, then surplus, clamped at each step. Near the floor
    ///      `proceeds < debt + penalty` is routine rather than exotic, so an unclamped
    ///      subtraction would panic in exactly the band where fills happen. Taking the
    ///      penalty before the debt would manufacture a shortfall the insurance fund
    ///      then covers, which is paying the liquidation caller out of insurance.
    function _distribute(
        uint256 auctionId,
        address borrower,
        address cm,
        uint256 proceeds,
        uint256 penaltyDue,
        bool recogniseShortfall
    ) private returns (uint256 repaid, uint256 penaltyCharged) {
        uint256 debtNow = ICreditManager(cm).currentDebtOf(borrower);
        repaid = _repay(cm, borrower, proceeds < debtNow ? proceeds : debtNow);

        if (recogniseShortfall && debtNow > repaid) {
            // Only reachable when NAV fell further than the floor's coverage margin.
            // This must never revert the fill: a position nobody can buy is strictly
            // worse for lenders than one bought at a loss.
            ICreditManager(cm).writeDownLoss(borrower, debtNow - repaid);
        }

        uint256 surplus = proceeds - repaid;
        // `penaltyDue` is passed in rather than derived from `debtNow`. Deriving it here
        // meant the workout path charged it never: surplus only appears once the debt is
        // already zero, and the borrower can reach that state themselves with a
        // permissionless, never-pausable `repay`.
        uint256 penalty = surplus < penaltyDue ? surplus : penaltyDue;
        penaltyCharged = penalty;
        uint256 callerReward = (penalty * Config.LIQUIDATION_CALLER_SHARE_BPS) / Config.BPS;

        // The odd wei goes to insurance, never to the caller. Same rule as the
        // harvester's rounding remainder: the protocol keeps the dust it creates.
        _accrueReward(auctionId, callerReward);
        _creditProceeds(cm, borrower, penalty - callerReward, surplus - penalty);

        emit LiquidationPenaltyTaken(auctionId, auctions[auctionId].caller, callerReward, penalty - callerReward);
    }

    function _accrueReward(uint256 auctionId, uint256 amount) private {
        if (amount == 0) return;
        address caller = auctions[auctionId].caller;
        rewardOf[caller] += amount;
        totalUnclaimedRewards += amount;
        emit CallerRewardAccrued(auctionId, caller, amount);
    }

    /// @dev Leaves no standing allowance. Both legs go in one call so they cannot come
    ///      apart, and the USDC lands inside the CreditManager's solvency invariant
    ///      rather than sitting unbacked here.
    function _creditProceeds(address cm, address borrower, uint256 toInsurance, uint256 toBorrower) private {
        uint256 total = toInsurance + toBorrower;
        if (total == 0) return;
        usdc.forceApprove(cm, total);
        ICreditManager(cm).creditLiquidationProceeds(borrower, toInsurance, toBorrower);
        usdc.forceApprove(cm, 0);
    }

    /// @dev Measures what actually moved rather than trusting the argument, the same
    ///      way `borrow` and `settlePrincipal` do on their own transfers. It matters
    ///      here because the winner's ERC-1155 callback runs before this line and could
    ///      have repaid part of the debt itself, in which case `repayFor` clamps and
    ///      takes less than asked - and every downstream figure is derived from this
    ///      one. Leaves no standing allowance either way.
    function _repay(address cm, address borrower, uint256 target) private returns (uint256 repaid) {
        if (target == 0) return 0;
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.forceApprove(cm, target);
        ICreditManager(cm).repayFor(borrower, target);
        usdc.forceApprove(cm, 0);
        repaid = balanceBefore - usdc.balanceOf(address(this));
    }

    /// @inheritdoc ILiquidationAuction
    /// @dev Permissionless. A position can heal mid-auction - yield streams
    ///      continuously, and anyone may `repayFor` - and leaving the auction live
    ///      would sell collateral that is no longer forfeit. Borrower-only would be
    ///      worse than useless: a borrower who has lost keys or been blacklisted is
    ///      exactly the one who cannot call it.
    ///
    ///      Nothing is returned, because nothing was ever taken. The lot has been in
    ///      custody, staked and earning, for the whole auction.
    function cancel(uint256 auctionId) external nonReentrant {
        Auction storage a = _live(auctionId);
        address borrower = a.borrower;

        // Reads `currentDebtOf` rather than calling `settle`, which is `whileAttached`
        // and would make cancelling impossible during a manager migration. A projecting
        // view needs no wiring, and the exits must never depend on wiring.
        uint256 debt = ICreditManager(creditManager).currentDebtOf(borrower);
        uint256 collateral = _vault.collateralValue(borrower);
        if (LtvMath.exceedsLtv(debt, collateral, Config.LIQUIDATION_THRESHOLD_BPS)) {
            revert StillLiquidatable(LtvMath.ltvBps(debt, collateral));
        }

        a.settled = true;
        liveAuctionCount--;
        delete auctionOf[borrower];
        emit AuctionCancelled(auctionId, borrower);
    }

    // ── Workout (PRD §4.5, the expiry path) ──────────────────────────────────

    /// @inheritdoc ILiquidationAuction
    /// @dev **Permissionless, and it touches no external protocol.** No adapter call,
    ///      no bond transfer, no USDC transfer, no lender pool. That is the whole point:
    ///      this is the exit of last resort, and an exit that can fail while holding a
    ///      third party's collateral is not an exit.
    ///
    ///      It is not literally unconditional, and an earlier version of this comment
    ///      wrongly claimed it was: `reassign` carries the vault's own liquidatable
    ///      check, so this reverts if the position healed during the window. That is
    ///      correct - `cancel` is the right exit there - and the two predicates are
    ///      exact complements over the same debt, collateral and threshold, so exactly
    ///      one of them always passes. The completeness of the three exits rests on that
    ///      complementarity, so do not change one predicate's inputs without the other.
    ///
    ///      Concretely, it survives all of: DexFi revoking the adapter's whitelist
    ///      entry, the farm pausing `withdraw`, a USDC-blacklisted borrower, an empty
    ///      insurance fund, and a `LenderPool` that reverts everything.
    ///
    ///      **The debt is deliberately not written down here.** The loss is unknown
    ///      until DexFi actually pays, and recognising a guess either understates it and
    ///      misleads lenders, or overstates it and hands the borrower a windfall if the
    ///      redemption comes good. It sits on the books, uncollateralised and visible,
    ///      until `closeWorkout` - which anyone may force once `WORKOUT_MAX_DURATION`
    ///      has passed, so "visible" cannot quietly become "indefinite".
    ///
    ///      The claim moves to this contract rather than being left with the borrower:
    ///      otherwise a defaulted position keeps accruing yield against a debt that is
    ///      being written off, and the borrower gets paid for defaulting.
    function expireToWorkout(uint256 auctionId) external nonReentrant {
        Auction storage a = _live(auctionId);
        uint256 finishesAt = a.startedAt + Config.AUCTION_DURATION;
        if (block.timestamp < finishesAt) revert AuctionStillRunning(finishesAt);

        address borrower = a.borrower;
        address cm = creditManager;
        if (cm == address(0)) revert CreditManagerUnset();

        a.settled = true;
        liveAuctionCount--;
        delete auctionOf[borrower];

        uint256 lot = _vault.reassign(borrower, address(this));
        uint256 debt = ICreditManager(cm).currentDebtOf(borrower);

        workouts[auctionId] = Workout({
            borrower: borrower,
            openedAt: uint96(block.timestamp),
            status: WorkoutStatus.Open,
            bondCount: lot,
            debtAtExpiry: debt,
            recovered: 0,
            penaltyRemaining: (debt * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS
        });
        _openWorkouts.push(auctionId);
        workoutsOpenFor[borrower]++;
        _workoutIndex[auctionId] = _openWorkouts.length;

        emit AuctionExpiredToWorkout(auctionId);
        emit WorkoutOpened(auctionId, borrower, lot, debt);
    }

    /// @notice Pay recovered USDC into an open workout. Permissionless.
    /// @dev Permissionless because it only ever moves money *in*. DexFi's redemption is
    ///      a manual off-chain process, so in practice an operator relays the proceeds -
    ///      but nothing here should depend on that operator being alive, and a third
    ///      party who wants to make lenders whole should not need permission to.
    ///
    ///      Partial tranches are supported, because a manual redemption may well pay in
    ///      stages. The shortfall is therefore *not* recognised here: doing so on the
    ///      first tranche would socialise a loss the second tranche covers.
    ///
    ///      Runs the same distribution as a fill, so the two recovery paths cannot
    ///      disagree about who gets paid what.
    function workoutSettle(uint256 auctionId, uint256 amountUsdc) external nonReentrant {
        Workout storage w = _openWorkout(auctionId);
        if (amountUsdc == 0) revert ZeroAmount();
        address cm = creditManager;
        if (cm == address(0)) revert CreditManagerUnset();

        // Measured, not trusted, the same way every other inbound leg in this protocol
        // is: a token that takes a fee on transfer would otherwise have the difference
        // silently covered out of the caller rewards this contract holds.
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amountUsdc);
        uint256 received = usdc.balanceOf(address(this)) - balanceBefore;

        w.recovered += received;
        emit WorkoutRecovered(auctionId, msg.sender, received, w.recovered);

        // The unpaid balance carries across tranches, so splitting a recovery cannot
        // shrink the total penalty and cannot double-charge it either.
        (, uint256 charged) = _distribute(auctionId, w.borrower, cm, received, w.penaltyRemaining, false);
        w.penaltyRemaining -= charged;
    }

    /// @notice Close a workout: cleanly once the debt is gone, or by force once it has
    ///         run longer than `Config.WORKOUT_MAX_DURATION`.
    /// @dev Permissionless in both cases, and the forced branch is the one that matters.
    ///      Without it, recognising bad debt would depend on governance choosing to,
    ///      which is exactly the "loss recognition lags the auction window" deferral in
    ///      the security notes. With it, a workout that DexFi never honours becomes a
    ///      recognised loss on a schedule nobody has to be trusted to keep.
    function closeWorkout(uint256 auctionId) external nonReentrant {
        Workout storage w = _openWorkout(auctionId);
        address cm = creditManager;
        if (cm == address(0)) revert CreditManagerUnset();

        // Bounded by what this workout was actually opened over. Live debt is not a
        // safe substitute: `borrow` never consults the workout queue, and the borrower's
        // ledger was zeroed by `reassign`, so fresh collateral makes them look like a
        // new borrower. Sized from live debt, a forced close would forgive a brand-new,
        // fully-backed loan taken during the window - and the borrower could then
        // withdraw that collateral, because `withdrawBonds` skips its LTV branch at
        // zero debt.
        uint256 exposure = w.debtAtExpiry > w.recovered ? w.debtAtExpiry - w.recovered : 0;
        uint256 live = ICreditManager(cm).currentDebtOf(w.borrower);
        uint256 residual = live < exposure ? live : exposure;
        if (residual != 0) {
            uint256 forceableAt = w.openedAt + Config.WORKOUT_MAX_DURATION;
            if (block.timestamp < forceableAt) revert WorkoutStillRunning(forceableAt);
            ICreditManager(cm).writeDownLoss(w.borrower, residual);
        }

        w.status = WorkoutStatus.Closed;
        workoutsOpenFor[w.borrower]--;
        _removeOpenWorkout(auctionId);
        emit WorkoutClosed(auctionId, w.recovered, residual);
    }

    /// @notice Move yield earned by workout positions into the insurance fund.
    /// @dev Permissionless. A workout lot stays staked and keeps earning, and with no
    ///      debt against it that yield accumulates as this contract's claimable balance.
    ///      Left there it would be dead weight; the insurance fund is the side of the
    ///      ledger the default actually damaged, so that is where it goes.
    ///
    ///      Deliberately not folded into `closeWorkout`: a claim that reverts must never
    ///      be able to block the recognition of a loss.
    function sweepWorkoutYieldToInsurance() external nonReentrant {
        address cm = creditManager;
        if (cm == address(0)) revert CreditManagerUnset();

        uint256 balanceBefore = usdc.balanceOf(address(this));
        ICreditManager(cm).claimSurplus();
        uint256 swept = usdc.balanceOf(address(this)) - balanceBefore;
        if (swept == 0) revert NothingToClaim();

        usdc.forceApprove(cm, swept);
        ICreditManager(cm).fundInsurance(swept);
        usdc.forceApprove(cm, 0);
        emit WorkoutYieldSwept(swept);
    }

    /// @notice Hand a closed workout's lot out of the vault, for redemption or sale.
    /// @dev **The exit the workout path was missing.** `reassign` parks the lot under
    ///      this contract's ledger entry, and without a call site for `withdrawBonds`
    ///      nothing could ever move it again: `seize` and `reassign` both refuse a
    ///      zero-debt holder, and this contract is immutable. That stranded the
    ///      collateral even on a workout that closed cleanly with the debt fully repaid,
    ///      kept the dead lot in `totalBondCount` diluting every future accrual, and
    ///      permanently blocked `setCustodyAdapter`, which refuses while custody holds
    ///      anything.
    ///
    ///      It also left DexFi's manual redemption - the entire premise of the workout -
    ///      with no on-chain leg, since a redemption needs the bonds to actually move.
    ///
    ///      Owner-gated because "DexFi agreed to redeem these" is an off-chain fact with
    ///      no on-chain proof, and because the destination is a judgement call: the
    ///      redemption counterparty on a written-off workout, the borrower on one that
    ///      closed clean. Under a timelock this is a 48h operation, which is the right
    ///      cadence for a redemption quoted at "48h+" anyway.
    function disposeWorkoutLot(uint256 auctionId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        Workout storage w = workouts[auctionId];
        if (w.status != WorkoutStatus.Closed) revert WorkoutNotClosed(auctionId);

        uint256 n = w.bondCount;
        if (n == 0) revert NothingToDispose(auctionId);
        w.bondCount = 0;

        // One hop, from the adapter. An earlier version pulled the units here with
        // `withdrawBonds` and forwarded them, which cannot work: that second hop has
        // this contract as both sender and source and an arbitrary destination, so no
        // party is whitelisted and DexFi's gate refuses it. That is the same fact the
        // header above is built on, and it still shipped - the tests only passed
        // because they whitelisted the destination first.
        emit WorkoutLotDisposed(auctionId, to, n);
        _vault.disposeTo(to, n);
    }

    /// @inheritdoc ILiquidationAuction
    /// @dev Typed as `address` rather than `ICollateralVault` so the vault can read it
    ///      back without a circular interface import.
    function vault() external view returns (address) {
        return address(_vault);
    }

    /// @notice How many workouts are awaiting resolution. The queue, as a number.
    function openWorkoutCount() external view returns (uint256) {
        return _openWorkouts.length;
    }

    function openWorkoutAt(uint256 index) external view returns (uint256 auctionId) {
        return _openWorkouts[index];
    }

    function _openWorkout(uint256 auctionId) private view returns (Workout storage w) {
        w = workouts[auctionId];
        if (w.status != WorkoutStatus.Open) revert WorkoutNotOpen(auctionId);
    }

    /// @dev Swap and pop, so the queue stays a bounded read for a keeper scanning it.
    function _removeOpenWorkout(uint256 auctionId) private {
        uint256 indexPlusOne = _workoutIndex[auctionId];
        uint256 last = _openWorkouts.length;
        if (indexPlusOne != last) {
            uint256 moved = _openWorkouts[last - 1];
            _openWorkouts[indexPlusOne - 1] = moved;
            _workoutIndex[moved] = indexPlusOne;
        }
        _openWorkouts.pop();
        delete _workoutIndex[auctionId];
    }

    // ── Pricing ──────────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidationAuction
    /// @dev Reverts rather than returning zero for an unknown or closed auction. A
    ///      keeper must not be able to act on a silent zero, and zero is a price.
    ///
    ///      Prices the *live* lot, not the recorded one, so a borrower who tops up
    ///      mid-auction does not sell the extra units for nothing.
    function currentPrice(uint256 auctionId) external view returns (uint256 price) {
        Auction storage a = _live(auctionId);
        // Refuses once lapsed, for the same reason it refuses an unknown id. The
        // decay curve keeps returning the floor forever, so without this a keeper reads
        // a plausible, fillable-looking quote for an auction every `bid` reverts on.
        // A price nobody can fill is as misleading as a silent zero.
        if (block.timestamp > a.startedAt + Config.AUCTION_DURATION) revert AuctionLapsed(auctionId);
        return _lotPrice(_vault.bondCount(a.borrower), a.startNav, _premiumBps(a.startedAt));
    }

    /// @notice The decay curve on its own, in bps of NAV.
    /// @dev Refuses once lapsed for the same reason `currentPrice` does, and round 7
    ///      had to add it here too: the guard went on one of the two views that quote a
    ///      fillable-looking number, and premium x lot x startNav reconstructs exactly
    ///      the price the other one now refuses. Guarding one of a pair is how a fix
    ///      reads as done while the behaviour it removed is still one call away.
    ///      `endsAt` deliberately keeps answering - it is the view a keeper needs in
    ///      order to tell "lapsed" from "unknown", and its value is self-describing.
    function currentPremiumBps(uint256 auctionId) external view returns (uint256) {
        Auction storage a = _live(auctionId);
        if (block.timestamp > a.startedAt + Config.AUCTION_DURATION) revert AuctionLapsed(auctionId);
        return _premiumBps(a.startedAt);
    }

    /// @notice When the price stops falling and the workout path opens.
    function endsAt(uint256 auctionId) external view returns (uint256) {
        return _live(auctionId).startedAt + Config.AUCTION_DURATION;
    }

    /// @notice True while `borrower` has a live auction against them.
    function isLiquidating(address borrower) external view returns (bool) {
        return auctionOf[borrower] != 0;
    }

    /// @dev Linear decay, clamped at the floor. The division floors, so the premium is
    ///      at worst a fraction of a bp *high* - the price decays a touch slowly, which
    ///      favours the protocol. Never the other way.
    function _premiumBps(uint256 startedAt) private view returns (uint256) {
        uint256 elapsed = block.timestamp - startedAt;
        if (elapsed >= Config.AUCTION_DURATION) return Config.AUCTION_FLOOR_BPS;
        return Config.AUCTION_START_PREMIUM_BPS
            - ((Config.AUCTION_START_PREMIUM_BPS - Config.AUCTION_FLOOR_BPS) * elapsed) / Config.AUCTION_DURATION;
    }

    /// @dev Multiplies the whole lot before dividing, so per-bond truncation cannot
    ///      accumulate across a large position, and rounds **up**: the last wei belongs
    ///      to the debt, not to the bidder. With 33 bps of margin on the floor's
    ///      coverage guarantee, the rounding direction is not academic.
    ///
    ///      Units: bonds x NAV(8dp) x bps / (BPS x USDC_TO_NAV_SCALE) = USDC(6dp).
    function _lotPrice(uint256 bonds, uint256 nav, uint256 premiumBps) private pure returns (uint256) {
        return Math.ceilDiv(bonds * nav * premiumBps, Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    /// @dev Both checks, always. Starting ids at 1 makes the zero struct unreachable
    ///      through `auctionOf`, and the borrower check makes it unreachable through a
    ///      hand-passed id - either alone is one refactor away from being wrong.
    function _live(uint256 auctionId) private view returns (Auction storage a) {
        a = auctions[auctionId];
        if (a.borrower == address(0)) revert UnknownAuction(auctionId);
        if (a.settled) revert AuctionClosed(auctionId);
    }
}
