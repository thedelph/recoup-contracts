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
import {IRiskParams} from "./interfaces/IRiskParams.sol";

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
    /// @dev **Audit round 19, critical 2.** The re-strike window has closed: this auction has been
    ///      lapsing and re-striking since `openedAt` and may not be re-struck again. The remedy is
    ///      `expireToWorkout`, which is permissionless and legal the moment the current window
    ///      lapses, and which arms the forced close that bounds the lender pool's mark.
    error AuctionResetWindowClosed(uint256 auctionId, uint256 closedAt);
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
    error WorkoutAlreadyOpen(address borrower);
    error WorkoutNotClosed(uint256 auctionId);
    error AuctionLapsed(uint256 auctionId);
    error NothingToDispose(uint256 auctionId);
    /// @dev A closed workout that wrote nothing off, or one whose write-off a late tranche has
    ///      already repaid in full. Distinct from `WorkoutNotClosed`, which is about the state.
    error NothingLeftToRecover(uint256 auctionId);
    error AuctionHasLiveWork(uint256 outstanding);
    error CreditManagerNotLive(address liveManager);
    error CreditManagerVaultMismatch(address managerVault);
    error CreditManagerRiskParamsMismatch(address managerRiskParams);
    error RiskParamsVaultMismatch(address vaultRiskParams);
    /// @notice The incoming manager reads a different NAV feed to the vault's.
    error CreditManagerNavOracleMismatch(address managerNavOracle);
    /// @notice This auction was built on a different NAV feed to the vault it is bound to.
    error NavOracleVaultMismatch(address vaultNavOracle);

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
    /// @notice A tranche that arrived after the forced close, repaying part of what it wrote off.
    /// @param stillWrittenDown What is left of the write-off, and so what a further tranche may
    ///        still repay. Zero once the redemption has come good in full.
    event WorkoutLossRecovered(uint256 indexed auctionId, uint256 amount, uint256 stillWrittenDown);
    event WorkoutYieldSwept(uint256 amount);
    /// @notice USDC held here beyond `totalUnclaimedRewards`, moved on to the insurance fund.
    event FreeBalanceSwept(uint256 amount);
    event WorkoutLotDisposed(uint256 indexed auctionId, address indexed to, uint256 bondCount);
    /// @notice A lapsed auction re-struck in place at the current NAV, keeping its id.
    /// @param resetBy Whoever called `liquidate` to re-strike it. Recorded because it is *not* the
    ///        party who gets paid - the parked bounty stays with whoever opened the auction - and an
    ///        indexer that assumed otherwise would be reading audit round 19's finding back in.
    /// @dev Replaces `AuctionSuperseded`, which announced a fresh auction id. There is no longer a
    ///      second auction to name.
    event AuctionReset(
        uint256 indexed auctionId, address indexed borrower, address indexed resetBy, uint256 nav, uint256 startPrice
    );
    /// @notice The manager refused the impairment refresh this transition sent it, so the lender
    ///         pool is still carrying whatever reserve it had.
    /// @dev The whole reason the notification is best-effort is that these exits must not be
    ///      blockable. That trade leaves a stale mark behind, and a stale mark that nobody can see
    ///      is a permanently wrong exit price - so it is emitted. Anyone can put it right with the
    ///      permissionless `CreditManager.refreshImpairment`.
    event ImpairmentRefreshFailed(uint256 indexed auctionId, address indexed borrower);

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
        /// @notice What a forced close wrote off and **nobody was made whole for**, and therefore
        ///         what a late tranche may still repay. Falls as `workoutSettleAfterClose` pays it
        ///         down; zero on a workout that closed cleanly, and zero for the part of a
        ///         write-down the insurance fund covered.
        /// @dev **Audit round 21, finding 14.** DexFi's redemption is off-chain and quoted at
        ///      "48h+", so a tranche genuinely arrives after the window; `closeWorkout` is
        ///      permissionless the instant that window passes, so a stranger picks the moment the
        ///      debt stops existing. Without this figure the only permissionless destination left
        ///      for that tranche was `fundInsurance`, which helps the lenders who took the loss
        ///      only if a *future* borrower defaults.
        uint256 writtenDown;
    }

    IERC20 public immutable usdc;
    ICollateralVault internal immutable _vault;

    /// @inheritdoc ILiquidationAuction
    /// @notice The NAV feed the Dutch curve is struck from.
    /// @dev **Audit round 21.** `start` reads this once and the curve is frozen for the auction's
    ///      life, while the debt the fill settles and the shortfall it books are priced off the
    ///      vault's feed. Immutability bound this auction to one feed; it never bound it to the
    ///      *vault's* feed, which is the same sentence round 20 had to rewrite about `riskParams`
    ///      one member below. The constructor and `CollateralVault.setLiquidationAuction` are what
    ///      make it true.
    INAVOracle public immutable override navOracle;

    /// @inheritdoc ILiquidationAuction
    /// @notice The live risk configuration. Immutable, for the same reason `_vault` is: `cancel`
    ///         decides whether a position has healed, and it must reach that verdict from the same
    ///         threshold the vault's own `seize` check reads.
    /// @dev **Audit round 20: "the same threshold" was an intention, not a property.** Immutability
    ///      here binds this auction to one authority; it never bound this auction to the *vault's*
    ///      authority, and a replacement auction carrying its own constructor seeds installed
    ///      cleanly through every wiring call. The constructor below and
    ///      `CollateralVault.setLiquidationAuction` are what make the sentence above true.
    IRiskParams public immutable override riskParams;

    address public creditManager;

    /// @dev Pre-incremented, so id 0 is never issued. `auctionOf[borrower] == 0` is
    ///      then an unambiguous "none" rather than a valid-looking zero struct that
    ///      `bid` would happily operate on.
    uint256 public nextAuctionId;
    mapping(uint256 => Auction) public auctions;
    /// @inheritdoc ILiquidationAuction
    /// @dev Also read by `CreditManager._impairmentFor`, which is why it is on the interface now:
    ///      the impairment a live liquidation carries is sized from this auction's floor, and the
    ///      manager only ever holds the borrower.
    mapping(address => uint256) public override auctionOf;

    /// @notice When this auction was *first* opened, as opposed to when its current price window
    ///         started. Zero for an id that was never issued.
    /// @dev **Audit round 19, critical 2, and the whole point is that this one does not move.**
    ///      `Auction.startedAt` is reset by every re-strike, which is what makes the Dutch price
    ///      restart - and is also what let an unfunded stranger keep a position live forever, six
    ///      hours at a time, holding the lender pool's withdrawal queue shut. This is the clock the
    ///      re-strike window is measured against, so re-striking cannot extend its own deadline.
    ///      Written once, at open, and never again.
    mapping(uint256 => uint256) public firstOpenedAt;

    /// @inheritdoc ILiquidationAuction
    /// @dev **Non-zero only inside a `_bid` frame, and audit round 15 is why it exists.**
    ///
    ///      `_bid` holds `auctionOf` set across the winner's ERC-1155 callback on purpose, so the
    ///      mark cannot be *released* early. What nothing stopped was the callback *spending* that
    ///      standing mark on somebody else: `LenderPool.serviceQueue` is permissionless, its
    ///      `nonReentrant` is a different contract's guard, and the attacker supplies the very fill
    ///      that releases the mark three statements later. Riskless, atomic, and it fires on
    ///      auctions where the realised loss ends at zero, so a queued lender was crystallised at a
    ///      discount for a default that never happened.
    ///
    ///      The winner's payment is already inside this contract one statement before `seize` hands
    ///      them control, so the recovery is a **fact** by then rather than a forecast. Recording it
    ///      here is audit round 13's own rule - recognise a recovery when it is realised, never when
    ///      it is predicted - applied one statement earlier than it used to be.
    ///
    ///      **Not a settlement flag and not a counterparty's balance.** Trail of Bits' Maple v2
    ///      finding was a griefer blocking settlement by funding an address the protocol read, so
    ///      this is measured as a delta across this contract's own pull. A donation before or after
    ///      cancels out, and this contract also holds `totalUnclaimedRewards`, so the level is not
    ///      the loan's cash and could never be used as one.
    ///
    ///      **Safe to leave public and safe to read from the callback**, because the callback can
    ///      only re-derive the same reduced figure. Only `_bid` writes it, and only `_bid` clears
    ///      it.
    ///
    ///      **The clear must stay above the first statement that applies this fill to `debtOf`,
    ///      and that is the rule rather than "before the trailing refresh".** This slot and
    ///      `currentDebtOf` are the two terms of one subtraction in `CreditManager._impairmentFor`,
    ///      and they must never describe the same dollars. Audit round 16: the clear used to sit
    ///      below `_settleFill`, which reaches `CreditManager._repay`, which re-derives the mark on
    ///      its way out with the debt already reduced. Eleven of twelve agents found it and two
    ///      executed it. The comment that would have caught it had been written, and it enumerated
    ///      the one call site where the hazard is harmless.
    ///
    ///      **One recognition per auction, because there are no partial fills.** `bid` takes no
    ///      amount. If a partial-fill overload is ever added this must become additive, and the
    ///      clear must move with it under the rule above rather than to wherever it currently is.
    mapping(address => uint256) public override recognisedRecoveryOf;

    /// @notice Liquidation caller rewards awaiting collection.
    mapping(address => uint256) public rewardOf;
    /// @notice Sum of `rewardOf`. The only USDC this contract is ever entitled to hold,
    ///         which is what makes "the auction holds nothing at rest" checkable in one
    ///         read - and it needs to be checkable, because this contract is immutable.
    /// @dev It is also the bound on `sweepFreeBalanceToInsurance`, which is the sweep this
    ///      docstring used to say did not exist. Round 21 measured what that absence cost:
    ///      USDC pushed here by a detached manager's `claimSurplusFor` would otherwise sit on
    ///      an immutable contract with nothing able to move it.
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

    constructor(
        IERC20 usdc_,
        ICollateralVault vault_,
        INAVOracle navOracle_,
        IRiskParams riskParams_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            address(usdc_) == address(0) || address(vault_) == address(0)
                || address(navOracle_) == address(0) || address(riskParams_) == address(0)
        ) revert ZeroAddress();
        // Audit round 20, and the twin of the same check in `CreditManager`'s constructor. The
        // vault's answer is the reference because the vault is the one contract here that cannot be
        // replaced. Failing at deploy is strictly earlier than failing at the setter, and the
        // setter check stays because a stub can answer this however it likes.
        if (address(vault_.riskParams()) != address(riskParams_)) {
            revert RiskParamsVaultMismatch(address(vault_.riskParams()));
        }
        // Audit round 21, and the twin of the same check in `CreditManager`'s constructor. The
        // auction is the contract that sets the price a lot actually sells at, so of the three this
        // is the one where a second feed is worth the most: measured at a tenth of the vault's NAV,
        // a lot worth 943.125000 sold for 94.312500.
        if (address(vault_.navOracle()) != address(navOracle_)) {
            revert NavOracleVaultMismatch(address(vault_.navOracle()));
        }
        usdc = usdc_;
        _vault = vault_;
        navOracle = navOracle_;
        riskParams = riskParams_;
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

        // **Audit round 20.** The docstring above says divergence "lets `cancel` close an underwater
        // auction for free, or closes every exit at once", and until now it meant divergence of the
        // *manager pointer* only. The same two outcomes arrive through the risk pointer, from an
        // ordinary zero-debt migration that no wiring call refused: with the auction's threshold
        // below the vault's, all three exits shut over a live lot; with it above, `cancel` closes an
        // underwater auction for free, repeatedly.
        //
        // Read off the vault, not off this contract's own `riskParams`: the vault cannot be
        // replaced, so it is the reference, and the line above has just established that this
        // manager is the vault's live one.
        address managerRisk = address(ICreditManager(creditManager_).riskParams());
        address vaultRisk = address(ICollateralVault(address(_vault)).riskParams());
        if (managerRisk != vaultRisk) revert CreditManagerRiskParamsMismatch(managerRisk);

        // **Audit round 21, the third leg for the sibling pointer.** Read off the vault, not off
        // this contract's own `navOracle`, for the reason the block above gives. Like that one it
        // is only reachable by an address whose `navOracle()` is not a constant - the line above
        // has already established this manager is the vault's live one, and the vault's own setter
        // insisted it agreed - which is exactly the shape a setter installing an arbitrary address
        // cannot assume away.
        address managerNav = address(ICreditManager(creditManager_).navOracle());
        address vaultNav = address(ICollateralVault(address(_vault)).navOracle());
        if (managerNav != vaultNav) revert CreditManagerNavOracleMismatch(managerNav);

        // **Checked because all three exits now call `resolveBounty` bare.** A manager that
        // answers everything else and not that one installs cleanly and then reverts `cancel`,
        // `_bid` and `expireToWorkout` alike - the state the header comment calls permanently
        // stranded collateral, arrived at through a setter that reported success.
        //
        // **It probes the counter and not the function itself, and the difference is worth
        // stating rather than hiding.** `resolveBounty` is gated on the manager's own auction
        // pointer, so calling it here would revert `NotLiquidationAuction` whenever this setter
        // runs before `CreditManager.setLiquidationAuction` - refusing a legitimate wiring order
        // with an error about the wrong thing. `totalBountyParked` is the storage that only a
        // manager carrying the park exposes, so it is evidence of the right implementation
        // rather than proof of the selector. Bare, not `try`: this setter is `onlyOwner` and
        // already refuses while any work is live, so failing loudly costs nothing.
        //
        // **This adds one check; it does not fix the shape.** Round eighteen's finding is that
        // the rule needs to be "every selector this contract calls bare on this pointer", and
        // the others are still unprobed. That stays open.
        ICreditManager(creditManager_).totalBountyParked();

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

        // **No second liquidation over a borrower who already has a workout open.** Audit round 13,
        // and the harm is that a workout's recovery ends up in the defaulter's pocket.
        //
        // A workout records `debtAtExpiry` and settles against *live* debt, on the assumption that
        // nothing else zeroes live debt while it is open. A second auction does exactly that: the
        // borrower re-collateralises with `depositBonds`, calls the permissionless `liquidate`, lets
        // the lot fill at the floor, and `writeDownLoss` clears the remaining live debt to insurance
        // and lenders without touching `w.debtAtExpiry` or `w.recovered`. DexFi's manual redemption
        // then arrives at `workoutSettle`, which compares it against a live debt of zero, reads the
        // whole payment as surplus, and credits it to `claimableOf[borrower]`. Traced: lenders and
        // insurance absorb the full defaulted debt while the borrower collects the recovery.
        //
        // `CreditManager.borrow` has carried this exact guard, against this exact borrower state,
        // since round 8. It was never applied to the other thing a borrower can do while a workout
        // is open. Same rule, same reason, one contract over.
        if (workoutsOpenFor[borrower] != 0) revert WorkoutAlreadyOpen(borrower);

        // A lapsed auction is re-struck rather than blocking, and that is a security property, not
        // a convenience. `startNav` is frozen for the life of an auction, and `cancel` - the only
        // thing that clears a healed one - is permissionless, unrewarded and optional. Left to
        // block, a stale ticket becomes a perpetual call option struck at 68% of an arbitrarily old
        // price, fillable whenever the borrower re-levers, while no correctly-priced replacement
        // can ever open.
        //
        // **Audit round 19 rewrote how, and it is the same shape Maker's `Clipper.redo` uses:
        // reset the auction in place, keeping its id, rather than settling it and minting a new
        // one.** The old version was two separate criticals wearing one branch:
        //
        //  1. Minting a new id meant the parked bounty had to be unwound off the lapsed auction and
        //     re-parked against the new one - and `liquidate` re-reads `bountyEscrowOf` immediately
        //     after this function returns, so the escrow rolled forward onto whoever made *this*
        //     call. The borrower could therefore wait one second past a keeper's lapse, re-strike,
        //     and take the 25 USDC the keeper had earned. Measured: keeper 0, borrower 25,000,000.
        //     Resetting in place removes the unwind entirely, so there is nothing to re-park and no
        //     claimant to overwrite. The keeper who opened the auction keeps the claim through
        //     every re-strike, whoever pays for them.
        //  2. Settling and re-opening bumped the liveness registers each lap and started a fresh
        //     clock, so an attacker with no capital at all could keep a position live indefinitely
        //     and hold the lender pool's whole withdrawal queue shut. `firstOpenedAt` does not move,
        //     so the window below is a real deadline rather than one the attacker keeps extending.
        //
        // Re-striking is still strictly better than the floor fill it replaces: the price restarts
        // at 100% of *current* NAV and decays again. What is no longer claimed is that it is
        // strictly better full stop - that was only ever true of a neutral re-striker. A borrower
        // or a griefer re-strikes at the top of the curve precisely so the lot never reaches the
        // floor where it would fill, which is why the deadline exists.
        uint256 live = auctionOf[borrower];
        if (live != 0) {
            Auction storage stale = auctions[live];
            if (block.timestamp <= stale.startedAt + Config.AUCTION_DURATION) {
                revert AuctionAlreadyLive(live);
            }

            // The bound. Measured from the first open, never from the last re-strike, so re-striking
            // cannot buy more time to re-strike. Past it the only legal move is `expireToWorkout` -
            // permissionless, and already legal, since the window above has lapsed - which arms
            // `WORKOUT_MAX_DURATION` and the forced close that ends the mark.
            uint256 closesAt = firstOpenedAt[live] + Config.AUCTION_RESET_WINDOW;
            if (block.timestamp > closesAt) revert AuctionResetWindowClosed(live, closesAt);

            // Re-read everything the price depends on, exactly as a fresh open would. The lot can
            // have changed - the borrower may have deposited or the vault may have moved bonds -
            // and pricing a re-strike off the original lot would sell a quantity that is not there.
            uint256 restruckBonds = _vault.bondCount(borrower);
            if (restruckBonds == 0) revert NothingToAuction(borrower);
            uint256 restruckNav = navOracle.navPerBond();
            if (restruckNav == 0) revert NavUnset();

            stale.startedAt = uint96(block.timestamp);
            stale.bondCount = restruckBonds;
            stale.startNav = restruckNav;
            stale.startPrice = _lotPrice(restruckBonds, restruckNav, Config.AUCTION_START_PREMIUM_BPS);
            stale.debt = ICreditManager(creditManager).debtOf(borrower);

            emit AuctionReset(live, borrower, caller, restruckNav, stale.startPrice);

            // **No `resolveBounty` and no `liveAuctionCount` change, and both omissions are the
            // fix rather than oversights.** Nothing resolved: the same auction is still open, still
            // holds the same park, and is still counted once. The old branch's impairment refresh
            // is gone for the same reason - it existed to correct a mark that settling the auction
            // would have invalidated mid-call, and nothing is settled here. `liquidate` re-derives
            // the mark the moment this returns, as it always did.
            return live;
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
        // max-deviation drop; a second drop during the auction puts a floor fill below
        // the debt it is supposed to cover.
        //
        // **The margin over that requirement is a function of the threshold, and the
        // threshold is the one input designed to move.** It is
        // `Config.AUCTION_FLOOR_BPS - RiskParams.minimumAuctionFloorFor(threshold)`,
        // never a literal - this comment used to quote one figure in the present tense,
        // and that figure is the margin at the *ratchet's destination* rather than at
        // today's threshold. The two differ by an order of magnitude, which is how one
        // margin came to carry three values in three files. Both ends are asserted in
        // `RiskParameters.t.sol:test_relationCsMarginIsPinnedAtBothEndsOfTheRatchet`, so
        // a change to the floor, to the penalty or to any of the three NAV deviation
        // constants fails a test rather than staling this paragraph. At the endpoint the
        // room is tens of basis points, and that is the figure this decision is made
        // against.
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
        // Written here and nowhere else. The re-strike branch above deliberately does not touch it -
        // that is what makes `AUCTION_RESET_WINDOW` a deadline rather than a rolling extension.
        firstOpenedAt[auctionId] = block.timestamp;
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
        _claimReward(msg.sender);
    }

    /// @notice Withdraw a named caller's reward **to that caller**. Permissionless.
    /// @dev The third member of the class `CreditManager.claimSurplusFor` was added for, swept
    ///      in the same commit rather than left to be found one pot along. A liquidation caller
    ///      that is a contract behind a moving pointer can be credited here and then lose the
    ///      ability to re-issue the call, and this contract is immutable, so there would be no
    ///      later fix. Destination not chooseable, so this grants no authority over the balance
    ///      - only the timing of a transfer the claimant was always owed.
    function claimRewardFor(address caller) external nonReentrant {
        if (caller == address(0)) revert ZeroAddress();
        _claimReward(caller);
    }

    function _claimReward(address caller) private {
        uint256 amount = rewardOf[caller];
        if (amount == 0) revert NothingToClaim();
        rewardOf[caller] = 0;
        totalUnclaimedRewards -= amount;
        emit CallerRewardClaimed(caller, amount);
        usdc.safeTransfer(caller, amount);
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

        // `settled` clears here, before any external call: it is this contract's own re-entrancy
        // defence, `_live` reads it, and it must not be reachable from the callback.
        //
        // **`auctionOf` no longer clears alongside it, and this is the third contract to learn the
        // same lesson.** Round 11 moved `liveAuctionCount--` below `_settleFill` because the lender
        // pool's exit gate had started reading that counter as a solvency signal from inside the
        // winner's ERC-1155 hook. `auctionOf` has now become exactly that kind of signal too:
        // `CreditManager._impairmentFor` reads it to decide whether a borrower is still under
        // liquidation, and `refreshImpairment` is permissionless. Cleared here, a winning bidder
        // who was also a lender could call it from their own `onERC1155Received`, see no live
        // auction, have the mark released, and leave at the pre-loss price - the loss certain,
        // recorded nowhere yet.
        //
        // Cleared after settlement instead, so the callback window reads a pointer that is still
        // set and nothing can observe this liquidation as resolved from inside it.
        //
        // **The round-12 note this replaces claimed that over-marking for one call frame "is the
        // safe direction".** It is not, in general: an over-mark is only safe while every exit is
        // self-initiated, and `serviceQueue` pays exits their owner did not initiate, which turns
        // an over-mark into someone else's cash inside the same frame.
        //
        // **The sentence that used to end that paragraph was false, and audit round 15 executed
        // the consequence three times.** It said the over-marking "is the thing the impairment
        // redesign removed". The redesign did the opposite: audit round 13 replaced a mark that was
        // zero across the whole ordinary 50-68% LTV band with one that is always the full debt, so
        // the over-mark inside this frame went from rare and small to routine and maximal. The
        // comment named the hole and then dismissed it with a claim the code refutes.
        //
        // What closes it is the recognition below, not this ordering. The two are complements: the
        // pointer stays set so nothing reads "resolved", and the recovery is netted off so nothing
        // can be paid out of a shortfall this transaction has already covered.
        //
        // The gate masked the release half when it was found, which is the only reason that one is
        // a test (`test_impairment_cannotBeReleasedFromInsideTheSeizeCallback`) rather than an
        // incident. The spending half had no such luck and became a finding.
        a.settled = true;

        // **Recognise the recovery before the winner is handed control, not after.** Audit round 15
        // executed the gap three times: holding `auctionOf` set across the callback stops the mark
        // being released early, and stops nothing from being *spent* at it. The callback can call
        // the permissionless `LenderPool.serviceQueue` and settle a queued lender against a
        // shortfall that this very transaction is about to cover, on an auction whose realised loss
        // ends at zero. See `recognisedRecoveryOf`.
        //
        // Measured as a delta across our own pull rather than trusting `price`, the same way
        // `_repay` measures what actually moved and for the same reason. Clamped at the write as
        // well as at the read, mirroring `LenderPool.impair`: a figure above the fill or above the
        // global cap describes no reachable state, and a clamp at only one end is one refactor away
        // from being no clamp at all.
        //
        // **The debt is deliberately not repaid here.** Repaying first cures the position and
        // `_vault.seize` refuses a position that is no longer liquidatable, which is set out where
        // the ordering above is chosen. So this nets the mark rather than moving the debt, and the
        // debt itself is still written down in `_settleFill` exactly as before.
        //
        // **Across the winner's callback the mark is neither an over-mark nor an under-mark: it is
        // the exact shortfall this fill will leave**, because it is re-derived from the live debt
        // at every write and this slot holds only what has been paid in and not yet applied. A
        // callback `repayFor` lowers the debt and the mark follows it dollar for dollar; `borrow`
        // is refused while this pointer stands, so it cannot move the other way.
        //
        // **The claim here used to be "the mark stays an over-mark and never becomes an
        // under-mark", and audit round 16 refuted it by execution.** The proof it gave quantified
        // over `_bid`'s own frame and the statement that broke it was three calls deeper, in
        // another contract, added by a different round. The clear below is what makes the claim
        // true rather than intended; a claim of safety that only holds inside the frame you were
        // looking at is a claim about your attention, not about the code.
        uint256 heldBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), price);
        uint256 credited = usdc.balanceOf(address(this)) - heldBefore;
        if (credited > price) credited = price;
        // Clamped at the hard ceiling rather than at the live cap, deliberately. This sits between
        // a `safeTransferFrom` and a `seize`, so an external read here would add a revert path to
        // a frame that is holding somebody's collateral mid-move.
        //
        // **The justification that used to sit here named a debt for a quantity that is a price.**
        // It said no borrower can owe more than the live cap and the live cap can never exceed
        // this, "so the clamp cannot bite in a reachable state - it guards arithmetic that should
        // be impossible". That is an argument about a *debt*, and it is sound where a debt is what
        // is being clamped: `LenderPool.impair` clamps a mark, a mark is bounded by the debt, so
        // the debt reason covers it. `credited` here is a **price** - what one bidder paid for one
        // lot - and nothing bounds a price by the borrower's debt. On the re-strike path it is not
        // bounded by the collateral recorded at strike either, because the lot is re-priced against
        // a fresh NAV. So this clamp **can** bite.
        //
        // **And it is still correct, for a different reason: the consumer, not the reachability.**
        // `recognisedRecoveryOf` is only ever read as `debt > recovered ? debt - recovered : 0`,
        // and this ceiling is above any debt that can exist, so a clamped value saturates that
        // subtraction to zero exactly as the unclamped one would. Biting is harmless rather than
        // impossible - a different guarantee with a different failure mode, and worth writing down
        // as such rather than leaving a claim of unreachability that one large fill would falsify.
        if (credited > Config.GLOBAL_BORROW_CAP_MAX) credited = Config.GLOBAL_BORROW_CAP_MAX;
        recognisedRecoveryOf[borrower] = credited;
        _refreshImpairment(auctionId, borrower);

        _vault.seize(borrower, msg.sender);

        // **Cleared here: after the winner's callback, and before the first statement that applies
        // this fill to `debtOf`.** This slot means "paid in and *not yet* on the books as a debt
        // reduction", so its life has to end where the debt reduction begins.
        //
        // Audit round 16, eleven of twelve agents, executed twice. It used to sit below
        // `_settleFill`, which reaches `CreditManager._repay` - and that has re-derived the mark on
        // its way out since audit round 13. At that statement the debt had already fallen by the
        // fill and this slot still recorded the same fill as unspent, so the same dollars were
        // netted twice: `max(debtNow - repaid - price, 0)` stored against a true residual of
        // `debtNow - repaid`. At or above a half-debt fill it saturated to zero, emitted
        // `ImpairmentReleased`, and left `exitAssets() == totalAssets()` with a certain loss
        // unbooked - which is exactly the state audit round 15 existed to remove.
        //
        // The comment this replaces reasoned about the same hazard for the trailing refresh below,
        // where it genuinely is harmless because `auctionOf` is deleted by then and
        // `_impairmentFor` answers zero regardless. **The enumeration found the one call site where
        // the hazard does not matter and stopped there.**
        //
        // Nothing is lost by clearing this early. What the netting had to cover was the winner's
        // callback, and that closed when `seize` returned. From here to the write-down the mark is
        // re-derived from the live debt at every write, so it reads `debtNow - repaid` - the exact
        // residual - rather than an over-mark somebody could be paid at.
        delete recognisedRecoveryOf[borrower];

        _settleFill(auctionId, borrower, cm, price, penaltyDue);

        // **`liveAuctionCount` is decremented last, and audit round 11 is why.** It used to sit
        // beside `a.settled` above, which is correct effects-before-interactions for a counter
        // nobody outside this contract reads. That stopped being true when the lender pool's exit
        // gate started reading it as a solvency signal: `seize` hands bonds to the winner via
        // ERC-1155, which calls `onERC1155Received` on a contract winner, and `_settleFill` books
        // the shortfall only afterwards. So a winning bidder who was also a lender saw
        // `liveAuctionCount == 0` from inside their own callback - the loss certain, recorded
        // nowhere yet - and could redeem out of the pool at the pre-loss price.
        //
        // **That gate has since been deleted and this ordering still stands, for a sharper reason
        // than the one that produced it.** Nothing outside this contract reads this counter for
        // pricing any more, but the `delete auctionOf[borrower]` on the next line is read for
        // exactly that, by `_impairmentFor` through the permissionless `refreshImpairment`. The two
        // statements are one block now: everything that could tell an observer "this liquidation is
        // over" stays true until the winner's callback has had its turn and the shortfall is
        // booked, so a winning bidder cannot observe a released mark from inside their own hook.
        // Keeping the pair together is what stops the next edit separating them.
        //
        // Moving it here is safe for the original concern: re-entering `bid` is refused by
        // `nonReentrant` and by `a.settled`, neither of which depends on this counter.
        // `closeWorkout` already orders the same pair this way round, booking the loss before
        // clearing its own live-work state; the two settlement paths now agree.
        liveAuctionCount--;

        // Strictly before the refresh below, and strictly after the callback above. The refresh
        // has to see no live auction or it would re-derive a mark against this settled one; the
        // callback has to see one, for the reason set out where `settled` is written.
        delete auctionOf[borrower];

        // **A fill is the outcome the bounty was bought for, so the escrow is earned here.**
        // Paid on every fill, not only a short one: the caller decides whether to open an
        // auction hours before anyone bids, and cannot know then how well it will clear.
        // Conditioning the reward on the clearing price would put back exactly the uncertainty
        // this mechanism exists to remove - the penalty share already is contingent that way,
        // and pays zero on the short fills that cost lenders money. The cost is stated rather
        // than hidden: on a fill with a surplus the caller is paid twice, out of what the
        // borrower prepaid.
        //
        // After the liveness registers, like every other post-settlement call here, so nothing
        // can observe a resolved auction from inside the winner's callback.
        ICreditManager(cm).resolveBounty(auctionId, true);

        // A fill short of the debt has already released the mark through `writeDownLoss`, but a
        // fill that covers it has not: `_creditProceeds` returns early when there is no penalty
        // and no surplus to hand over, which is exactly a fill *at* the debt, so the manager can
        // come out of a clean settlement never having been told anything at all.
        _refreshImpairment(auctionId, borrower);
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

    /// @dev Tell `CreditManager` to re-derive the reserve the lender pool holds against this
    ///      position, because what this auction can still recover has just changed.
    ///
    ///      **The `try`/`catch` is the exit-of-last-resort property, not defensive habit.**
    ///      `expireToWorkout` promises in writing that it survives "a `LenderPool` that reverts
    ///      everything", and `cancel` reads `currentDebtOf` rather than calling `settle` because
    ///      "the exits must never depend on wiring". A bare call here would put a fourth contract's
    ///      revert in front of all three exits and make permanently stranded collateral reachable
    ///      again - which is strictly worse than the stale mark this notification exists to prevent.
    ///      The failure is emitted rather than swallowed, and `refreshImpairment` is permissionless,
    ///      so a stuck reserve is both visible and fixable by anybody.
    ///
    ///      **The call sites were derived from the storage the exits write, not from the
    ///      interface.** Audit round 11 found the previous exit gate blind to the withdrawal queue
    ///      precisely because its coverage had been enumerated from `IERC4626` rather than from the
    ///      contract. Re-run this and expect hits in four functions - `_bid`, `_cancel`,
    ///      `expireToWorkout` and `closeWorkout`:
    ///
    ///          grep -nE "settled = true|liveAuctionCount--|delete auctionOf|status = WorkoutStatus|workoutsOpenFor\[[^]]+\](\+\+|--)" src/LiquidationAuction.sol
    ///
    ///      It said *five* functions until 2026-08-19, naming `start`'s supersede branch and
    ///      `cancel` separately. Both now dispatch into the shared private `_cancel` body - round
    ///      19 re-struck a lapsed auction in place instead of minting a new id, and round 20's
    ///      finding 1 sent a healed position down that same body - so the grep lands in `_cancel`
    ///      once rather than in two callers. The coverage did not shrink; the enumeration did.
    ///
    ///      The call sites have their own grep, so neither number here has to be believed:
    ///
    ///          grep -n "_refreshImpairment(" src/LiquidationAuction.sol | grep -v "function "
    ///
    ///      **Two of the six call sites are invisible to the first grep, and both for the same
    ///      reason: they are not transitions, they only change the exposure.**
    ///
    ///      `workoutSettle` is one. Left out, the mark would stay at the full debt while DexFi had
    ///      already paid part of it back, over-marking every lender who left afterwards for money
    ///      that is already sitting in the protocol.
    ///
    ///      `_bid`'s **pre-seize** recognition is the other, added with the round-15 fix. It fires
    ///      before any liveness register moves, which is the exact opposite of the rule below and
    ///      is the point of it: the winner's cash is in this contract by then, so the recovery is a
    ///      fact, and it has to be netted off before the winner's ERC-1155 callback can spend the
    ///      un-netted figure through the permissionless `LenderPool.serviceQueue`. Enumerating from
    ///      the liveness registers alone would miss it, which is why this paragraph exists rather
    ///      than a longer grep.
    ///
    ///      Every *other* call site sits **after** the liveness registers are written, so the
    ///      refresh reads the state the transition left rather than the one it is leaving.
    function _refreshImpairment(uint256 auctionId, address borrower) private {
        address cm = creditManager;
        if (cm == address(0)) return;
        try ICreditManager(cm).refreshImpairment(borrower) {}
        catch {
            emit ImpairmentRefreshFailed(auctionId, borrower);
        }
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
        // Clamped rather than bare, matching `EpochHarvester._push` and the manager's own
        // three. Underflow is not reachable today - `repayFor` only pulls, and nothing on
        // that path pushes USDC back here - so this buys no behaviour change now. It is
        // here because `repaid` is what `_distribute` derives the write-down and the
        // surplus from, and a revert in this line would take out the fill path, the
        // workout settlement and the exit of last resort together.
        uint256 balanceAfter = usdc.balanceOf(address(this));
        repaid = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
    }

    /// @inheritdoc ILiquidationAuction
    /// @dev Permissionless. A position can heal mid-auction - yield streams
    ///      continuously, and anyone may `repayFor` - and leaving the auction live
    ///      would sell collateral that is no longer forfeit. Borrower-only would be
    ///      worse than useless: a borrower who has lost keys or been blacklisted is
    ///      exactly the one who cannot call it.
    ///
    ///      No collateral is returned, because none was ever taken. The lot has been in
    ///      custody, staked and earning, for the whole auction.
    ///
    ///      **The prepaid bounty IS returned, and audit round eighteen is why.** With the
    ///      escrow paid at open, a stranger opened an auction, cured the position with a
    ///      one-dollar `repayFor` and cancelled here in the same transaction, keeping
    ///      twenty-four dollars for work nobody did and leaving the position permanently
    ///      unarmed. This function and `repayFor` are both permissionless on purpose, so that
    ///      strangers can help; that generosity was the whole attack. A cancel resolves
    ///      nothing, so it earns nothing and hands the escrow back.
    function cancel(uint256 auctionId) external nonReentrant {
        Auction storage a = _live(auctionId);
        address borrower = a.borrower;

        // Reads `currentDebtOf` rather than calling `settle`, which is `whileAttached`
        // and would make cancelling impossible during a manager migration. A projecting
        // view needs no wiring, and the exits must never depend on wiring.
        uint256 debt = ICreditManager(creditManager).currentDebtOf(borrower);
        uint256 collateral = _vault.collateralValue(borrower);
        if (LtvMath.exceedsLtv(debt, collateral, riskParams.liquidationThresholdBps())) {
            revert StillLiquidatable(LtvMath.ltvBps(debt, collateral));
        }

        _cancel(auctionId, a, borrower);
    }

    /// @dev The cancel body, shared with `expireToWorkout`'s healed branch. Audit round 20: the
    ///      two functions were the only pair of exits whose preconditions are exact complements,
    ///      and a caller who reached for the documented exit of last resort on the wrong side of
    ///      that complement got a revert naming a bps figure and no instruction. Extracting the
    ///      body is what lets the dispatch live in one place rather than being duplicated.
    ///
    ///      **It pays nobody, and that is load-bearing.** Audit round eighteen's executed strip
    ///      (open, cure with a one-dollar `repayFor`, cancel in the same transaction, keep the
    ///      escrow) was closed precisely because a cancel earns nothing. Every caller that lands
    ///      here inherits that, including the new one.
    function _cancel(uint256 auctionId, Auction storage a, address borrower) private {
        a.settled = true;
        liveAuctionCount--;
        delete auctionOf[borrower];
        emit AuctionCancelled(auctionId, borrower);

        // Back to the borrower, so the position is armed again for whoever liquidates it next.
        // Returning it as claimable surplus instead would close the theft and keep the disarm,
        // which is half of what round eighteen actually measured.
        ICreditManager(creditManager).resolveBounty(auctionId, false);

        // The position healed, so there is no expected shortfall left to reserve. Nothing else in
        // this contract ever told the manager a cancelled auction had happened - `cancel` only
        // ever read from it - and a reserve nobody releases sits on every lender's exit price for
        // good.
        _refreshImpairment(auctionId, borrower);
    }

    // ── Workout (PRD §4.5, the expiry path) ──────────────────────────────────

    /// @inheritdoc ILiquidationAuction
    /// @dev **Permissionless, and nothing it does can be refused.** No adapter call, no
    ///      bond transfer, no USDC transfer. That is the whole point: this is the exit of
    ///      last resort, and an exit that can fail while holding a third party's
    ///      collateral is not an exit.
    ///
    ///      It reaches the lender pool twice, and both are wrapped in `try`/`catch` for precisely
    ///      this paragraph's sake. The obvious one is the impairment refresh at the end, which
    ///      re-sizes the reserve to a workout's whole debt; see `_refreshImpairment`. The other is
    ///      indirect and is the reason this sentence keeps needing rewriting: `_vault.reassign`
    ///      settles the position, which reaches `CreditManager._accrue`, whose zero-bond branch
    ///      moves a slice to insurance and pushes the loss reserves.
    ///
    ///      This docstring has now been wrong twice in the same way - it said "no lender pool"
    ///      flatly, then "exactly one outbound call", and audit round 13 caught the second version
    ///      the round after the first. **A count of outbound calls is the wrong thing to promise**,
    ///      because it is a claim about the whole call tree written from one function's body. What
    ///      this exit actually needs is that no reachable call can revert it, which is a property
    ///      of the `try`/`catch` wrappers rather than of how many there are.
    ///
    ///      **It is total once the clock has run out, and audit round 20 is what made that
    ///      true.** Two earlier versions of this comment got this wrong in opposite directions:
    ///      the first claimed the function was literally unconditional, and the second corrected
    ///      that to "this reverts if the position healed during the window, and `cancel` is the
    ///      right exit there". The second version was accurate about the code and wrong about the
    ///      design. `cancel` is permissionless, unrewarded and optional, and once the re-strike
    ///      window has also closed a healed position has no other move at all - so the revert
    ///      handed the caller who reached for the exit of last resort a bps figure and no
    ///      instruction, on the one path the protocol has no second attempt at.
    ///
    ///      The predicates are still exact complements over the same debt, collateral and
    ///      threshold, and that complementarity is now what the dispatch below is built on rather
    ///      than what the revert fell out of: healed goes to the `cancel` body, still-forfeit goes
    ///      to the workout body, and exactly one of them always runs. Do not change one predicate's
    ///      inputs without the other.
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

        // **The dispatch, and audit round 20 is why.** Everything below this point runs through
        // `_vault.reassign`, which carries `_requireLiquidatable` - so on a healed position this
        // whole function reverts and the caller is told `PositionNotLiquidatable(bps)`, which names
        // neither the auction nor the call that would work. `cancel` is that call, and the round-13
        // note on `CreditManager.borrow` already recorded the consequence: "it is unrewarded and
        // optional, so nothing makes it happen."
        //
        // Round 20 measured what "nothing makes it happen" costs once the re-strike window has also
        // closed, and the mark is only the first of five. `auctionOf` never returns to zero, so:
        // the borrower can never borrow again, four wiring setters stay welded, the collateral that
        // did the healing stays locked, and `liquidate` refuses with `AuctionResetWindowClosed` at
        // every later NAV - so the position can never be *auctioned* again, only worked out. That
        // last one is the least bad of the five and it was worth measuring rather than asserting:
        // if the position falls back under water, `expireToWorkout` opens a workout as it always
        // did, so the state degrades the recovery route rather than closing it.
        //
        // **The exception is a heal all the way to zero debt.** That clears the mark on its own,
        // and leaves the other four standing with no clock and - because a debt of zero is healthy
        // at every NAV - no price that can ever reopen this exit. Measured. It is also invisible to
        // any fix written on the mark, which is why this one is not written there.
        //
        // The predicate below is the exact negation of `CollateralVault._requireLiquidatable`: same
        // `currentDebtOf`, same `collateralValue`, same `liquidationThresholdBps`, read the same way
        // `cancel` reads them. So this branch is taken on precisely the inputs that would have
        // reverted, and the change is monotone - it can turn a revert into a resolution and never
        // the reverse. The complementarity the docstring above rests on is unchanged; what changes
        // is that this function now dispatches on it instead of failing on it.
        //
        // **"Same `liquidationThresholdBps`" is a property of the wiring, and it was not one when
        // this paragraph was written.** `riskParams` here and `riskParams` on the vault were two
        // independent constructor arguments that nothing cross-checked, so under a divergent pair
        // this branch was skipped on a position the vault then refused to reassign - the exit
        // designed to be total, defeated by a second `RiskParams`. All four wiring setters and both
        // consumer constructors now refuse that pair; see `test/RiskPointerAgreement.t.sol`.
        //
        // No payment moves. `_cancel` calls `resolveBounty(auctionId, false)`, so a caller who lands
        // here earns nothing, exactly as `cancel` does - round eighteen's strip stays closed.
        {
            uint256 healthDebt = ICreditManager(cm).currentDebtOf(borrower);
            uint256 healthCollateral = _vault.collateralValue(borrower);
            if (!LtvMath.exceedsLtv(healthDebt, healthCollateral, riskParams.liquidationThresholdBps())) {
                _cancel(auctionId, a, borrower);
                return;
            }
        }

        a.settled = true;
        liveAuctionCount--;
        // `auctionOf` is deliberately NOT cleared here. It is cleared below, after
        // `workoutsOpenFor` is incremented, so that the two liveness registers overlap rather
        // than leaving a gap between them.
        //
        // **Audit round 17.** `_vault.reassign` settles the position, which reaches
        // `CreditManager._settle`, which since audit round 16 refreshes the impairment whenever
        // the settle moved the debt. Clearing here put that refresh in a window where the
        // borrower had neither an auction nor a workout, so `_impairmentFor` answered zero and
        // released the whole mark mid-call - the exact hazard the comment beside the trailing
        // refresh already warned about, arriving from a statement three calls deeper in another
        // contract that a different round added.
        //
        // With the clear moved down, that nested refresh reads the auction branch and re-derives
        // the same figure the trailing refresh is about to set: the auction has lapsed with no
        // fill, so `recognisedRecoveryOf` is zero and the branch answers the whole debt, which is
        // what an open workout is sized at. The mark is flat across the transition instead of
        // dipping through zero, and a notification swallowed by a reverting pool now leaves a
        // stale-high mark rather than no mark at all - the direction this file's exits are
        // written to fail in.
        uint256 lot = _vault.reassign(borrower, address(this));
        // **Audit round 12, and `start` has carried the identical guard all along.** `reassign`
        // returns 0 rather than reverting on an empty position, and that early return also skips
        // its own liquidatable check - so a position emptied out from under a live auction (anyone
        // may `repayFor` to clear the debt, and `withdrawBonds` skips its LTV branch at zero debt)
        // could be pushed through this exit instead of `cancel`, opening a workout over nothing.
        // The cost is not cosmetic: `workoutsOpenFor` blocks that borrower from borrowing again,
        // and `openWorkoutCount` blocks four separate wiring setters, until somebody else pays gas
        // to close it. Executed PoC.
        if (lot == 0) revert NothingToAuction(borrower);
        uint256 debt = ICreditManager(cm).currentDebtOf(borrower);

        workouts[auctionId] = Workout({
            borrower: borrower,
            openedAt: uint96(block.timestamp),
            status: WorkoutStatus.Open,
            bondCount: lot,
            debtAtExpiry: debt,
            recovered: 0,
            penaltyRemaining: (debt * Config.LIQUIDATION_PENALTY_BPS) / Config.BPS,
            writtenDown: 0
        });
        _openWorkouts.push(auctionId);
        workoutsOpenFor[borrower]++;
        _workoutIndex[auctionId] = _openWorkouts.length;
        // Only now, with the workout registered, is it safe to stop answering as a live auction.
        // See the note above `reassign`: between these two statements the borrower is covered by
        // both registers, which is the overlap that keeps `_impairmentFor` from ever reading them
        // as an unmarked position.
        delete auctionOf[borrower];

        emit AuctionExpiredToWorkout(auctionId);
        emit WorkoutOpened(auctionId, borrower, lot, debt);

        // **Earned.** An expiry to workout is a resolution, not a lapse: the lot is reassigned
        // out of the borrower's control, the debt is frozen at expiry and a recovery process
        // opens. It is also the outcome that pays the caller least by every other route - no
        // fill means no surplus, so no penalty share - which is exactly the case the escrow was
        // introduced for. Maker pays its keepers on the same no-fill branch, through `redo`.
        ICreditManager(cm).resolveBounty(auctionId, true);

        // Escalation, not release. After the liveness registers above, `workoutsOpenFor` is the
        // state the manager reads, and it sizes an open workout at the whole debt: the recovery is
        // a manual redemption DexFi has not paid yet, so the auction's floor has stopped bounding
        // anything. Placed after the workout is registered, or the refresh would read a borrower
        // with neither an auction nor a workout and release the mark entirely.
        _refreshImpairment(auctionId, borrower);
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

        // Not a terminal transition, and that is why it is easy to miss. The tranche just paid down
        // real debt, so the workout's exposure has genuinely shrunk; without this the mark would
        // stay at the debt as it stood at expiry and over-mark every lender who leaves afterwards,
        // for money DexFi has already handed over.
        _refreshImpairment(auctionId, w.borrower);
    }

    /// @notice Close a workout: cleanly once the debt is gone, or by force once it has
    ///         run longer than `Config.WORKOUT_MAX_DURATION`.
    /// @dev Permissionless in both cases, and the forced branch is the one that matters.
    ///      Without it, recognising bad debt would depend on governance choosing to,
    ///      which is exactly the "loss recognition lags the auction window" deferral,
    ///      recorded open rather than closed. With it, a workout that DexFi never
    ///      honours becomes a recognised loss on a schedule nobody has to be trusted to keep.
    ///
    ///      **The bound stays and it is no longer destructive.** Audit round 21, finding 14
    ///      measured what the bound cost: DexFi's redemption is off-chain and quoted at "48h+", a
    ///      tranche that lands inside the window takes the debt 628.750000 -> 228.750000, and the
    ///      identical tranche a day after a stranger forced the close is refused by every entry
    ///      point in the protocol - `workoutSettle` with `WorkoutNotOpen`, `repayFor` with
    ///      `NoDebt`. So this function records what it wrote off and did not make anyone whole for,
    ///      and `workoutSettleAfterClose` spends that figure down. **Nothing else about this
    ///      function changes, deliberately**: it is permissionless, so a stranger picks the moment
    ///      it runs, and anything new it *did* would be new work a stranger could time. A stored
    ///      figure is not work.
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
            // Only the part no balance sheet was made whole for. The manager returns it rather
            // than this contract re-deriving it from `insuranceFund`: one model, in the contract
            // that owns the split. The insurance-funded part is already sitting in
            // `pendingPrincipal` on its way home, so a later recovery must not repay it a second
            // time - `fundInsurance` is the permissionless destination for anything above this.
            w.writtenDown = ICreditManager(cm).writeDownLoss(w.borrower, residual);
        }

        w.status = WorkoutStatus.Closed;
        workoutsOpenFor[w.borrower]--;
        _removeOpenWorkout(auctionId);
        emit WorkoutClosed(auctionId, w.recovered, residual);

        // Both branches reach here and both need it. The forced branch has already released the
        // mark through `writeDownLoss`, but a workout that closes cleanly - the debt repaid in
        // full - writes nothing down and so would otherwise leave the reserve standing over a
        // position that came good. After the decrement, so the refresh sees a borrower with no
        // open workout.
        _refreshImpairment(auctionId, w.borrower);
    }

    /// @notice Pay a late tranche of an off-chain redemption into a workout the forced close has
    ///         already written off. Permissionless.
    /// @dev **Audit round 21, finding 14, and it is the destination that is the fix.** Simply
    ///      letting `workoutSettle` run on a closed workout would be worse than the defect: with
    ///      the debt written off, `_distribute` repays nothing, charges the penalty and credits the
    ///      whole remainder to `claimableOf[borrower]` - so the recovery would land on the borrower
    ///      who just defaulted. Built and measured before this was.
    ///
    ///      So this is a separate entry point with no waterfall and no destination of its own.
    ///      `CreditManager.recoverWrittenDownLoss` sends it back to whichever balance sheet
    ///      actually bore the loss, picking between them with the same test `_socialise` used on
    ///      the way down: the lender pool when the pool funded the loan, `pendingPrincipal` and the
    ///      already-permissionless `settlePrincipal` when the treasury did. No new sweep:
    ///      `sweepWorkoutYieldToInsurance` and `sweepFreeBalanceToInsurance` both end at the
    ///      insurance fund, which is precisely the destination the finding rules out - insurance
    ///      leaves the socialised loss untouched, so the money would help the lenders who took this
    ///      loss only if a *future* borrower defaulted.
    ///
    ///      Bounded by `w.writtenDown`, which is what the close wrote off **and nobody was made
    ///      whole for**. Above that bound there is nothing left to repay: the insurance-funded part
    ///      of a write-down is already in `pendingPrincipal`, a clean close wrote nothing off at
    ///      all, and a redemption that comes good beyond either has `fundInsurance` - permissionless
    ///      and already here - to refill the fund it spent. The pull is clamped rather than the
    ///      caller refused, so a relayer sending a whole redemption at a workout that only needs
    ///      part of it takes back the difference instead of losing the transaction.
    ///
    ///      Permissionless for the same reason `workoutSettle` is: it only ever moves money *in*,
    ///      nothing here should depend on one operator being alive, and a third party who wants to
    ///      make lenders whole should not need permission to. Nobody can profit: the money leaves
    ///      the caller and reaches a balance sheet the caller has no claim on.
    function workoutSettleAfterClose(uint256 auctionId, uint256 amountUsdc) external nonReentrant {
        Workout storage w = workouts[auctionId];
        if (w.status != WorkoutStatus.Closed) revert WorkoutNotClosed(auctionId);
        uint256 outstanding = w.writtenDown;
        if (outstanding == 0) revert NothingLeftToRecover(auctionId);
        if (amountUsdc == 0) revert ZeroAmount();
        address cm = creditManager;
        if (cm == address(0)) revert CreditManagerUnset();

        // Measured, not trusted, exactly as `workoutSettle` measures its own inbound leg: a token
        // that takes a fee on transfer would otherwise have the difference silently covered out of
        // the caller rewards this contract holds.
        uint256 take = amountUsdc > outstanding ? outstanding : amountUsdc;
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), take);
        uint256 received = usdc.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();
        // Cannot bind today - `take` is already clamped and a fee-on-transfer token can only
        // deliver less - but every figure below is derived from this one, and the subtraction on
        // the next line is the one that must never underflow.
        if (received > outstanding) received = outstanding;

        w.writtenDown = outstanding - received;
        w.recovered += received;
        emit WorkoutRecovered(auctionId, msg.sender, received, w.recovered);
        emit WorkoutLossRecovered(auctionId, received, w.writtenDown);

        // Leaves no standing allowance, matching every other outbound leg here.
        usdc.forceApprove(cm, received);
        ICreditManager(cm).recoverWrittenDownLoss(w.borrower, received);
        usdc.forceApprove(cm, 0);

        // No `_refreshImpairment`. The close already released the mark and the borrower has no
        // open workout and no debt from this one, so there is nothing to re-derive - and a
        // notification here would re-enter the pool on a path that moves no exposure.
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

    /// @notice Move USDC sitting here that no reward claimant is owed into the insurance fund.
    /// @dev **The other half of `CreditManager.claimSurplusFor`, and useless without it.**
    ///      Audit round 21, finding 4. `sweepWorkoutYieldToInsurance` above can only reach
    ///      money the *live* manager owes this contract: it reads the mutable `creditManager`
    ///      slot, so after a repoint the claim on the outgoing manager has no caller. The fix
    ///      is a pair. `claimSurplusFor(auction)` is permissionless on **any** manager, live or
    ///      detached, and pushes that claim here; this then moves it on to whichever manager is
    ///      live now. Neither half chooses a destination, so the two together make the money
    ///      reachable **in any order** rather than trading one undocumented ordering
    ///      constraint for another.
    ///
    ///      **`totalUnclaimedRewards` is the whole of the accounting.** It is the sum of
    ///      `rewardOf` and, as its own docstring says, the only USDC this contract is ever
    ///      entitled to hold - so anything above it is by definition unattributed and belongs
    ///      where every other unattributed balance in this protocol goes. That docstring used
    ///      to finish "and has no sweep"; this is the sweep, and it is bounded by the same
    ///      figure that made the property checkable in one read.
    ///
    ///      Kept separate from the sweep above rather than folded into it, because that one
    ///      must keep reverting `NothingToClaim` when the live manager owes nothing - a caller
    ///      told a claim succeeded when none was made is how an ordering constraint hides.
    function sweepFreeBalanceToInsurance() external nonReentrant {
        address cm = creditManager;
        if (cm == address(0)) revert CreditManagerUnset();

        uint256 owed = totalUnclaimedRewards;
        uint256 balance = usdc.balanceOf(address(this));
        if (balance <= owed) revert NothingToClaim();
        uint256 free = balance - owed;

        usdc.forceApprove(cm, free);
        ICreditManager(cm).fundInsurance(free);
        usdc.forceApprove(cm, 0);
        emit FreeBalanceSwept(free);
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

    // `floorProceeds` used to live here: what the lot would fetch at the auction floor, which
    // `CreditManager._impairmentFor` credited as assumed recovery when sizing the lender pool's
    // reserve. It was deleted in the round-13 fix rather than left as a public view.
    //
    // Two reasons, and the second is the one that matters. It had no caller left - the impairment
    // now reserves the whole debt and recognises recovery only when a bid actually pays it in, so
    // nothing in `src/` asked this question any more. And a view that answers "what will this
    // probably recover" is exactly the shape of the mistake round 12 took apart: it invites the
    // next caller to price something off a forecast that moves on the clock. `currentPrice` is
    // what a bidder needs and it reverts once lapsed, which is the honest behaviour for a quote.

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
    ///      to the debt, not to the bidder. The floor's coverage guarantee clears its own
    ///      requirement - `Config.AUCTION_FLOOR_BPS` against
    ///      `RiskParams.minimumAuctionFloorFor(threshold)` - by tens of basis points at the
    ///      ratchet's endpoint, so the rounding direction is not academic.
    ///
    ///      **This used to quote a single figure in the present tense.** The number was right and
    ///      the tense was not: it is the margin at the ratchet's destination, not at today's
    ///      threshold, where the room is an order of magnitude larger. Both ends are pinned in
    ///      `RiskParameters.t.sol:test_relationCsMarginIsPinnedAtBothEndsOfTheRatchet` rather than
    ///      restated here, because a hand-maintained figure in prose is how one margin came to have
    ///      three values in three files.
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
