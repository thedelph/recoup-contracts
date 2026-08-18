// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Config} from "./Config.sol";
import {LtvMath} from "./LtvMath.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ICreditManager} from "./interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "./interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "./interfaces/IDexFiBond.sol";
import {ILiquidationAuction} from "./interfaces/ILiquidationAuction.sol";
import {INAVOracle} from "./interfaces/INAVOracle.sol";
import {IRiskParams} from "./interfaces/IRiskParams.sol";

/// @title CollateralVault (PRD §4.1)
/// @notice Accounting home for bond collateral (fungible ERC-1155 units, id 0).
///         Custody and all DexFi interaction are delegated to a pluggable
///         ICustodyAdapter, so the direct-call vs Safe decision (pending the §14
///         whitelist answer) swaps the backend without touching balances here.
/// @dev Bond units move depositor → adapter directly (one hop, so DexFi whitelisting
///      the adapter alone is sufficient). Deposits pause with the contract; exits
///      (withdraw/seize) intentionally never pause.
contract CollateralVault is ICollateralVault, Ownable, Pausable, ReentrancyGuard {
    error NotLiquidationAuction();
    error AdapterNotSet();
    error ZeroAmount();
    error InsufficientCollateral(uint256 requested, uint256 available);
    /// @dev Carries the ceiling as well as the resulting LTV. Without it a caller has to supply
    ///      the ceiling from somewhere else, and once it is settable, "somewhere else" is a copy
    ///      that can be stale. See the same widening on `CreditManager.ExceedsMaxLtv`.
    error WithdrawalExceedsMaxLtv(uint256 postLtvBps, uint256 maxLtvBps);
    error NothingMinted();
    error ZeroAddress();
    error AdapterHasLivePosition(uint256 staked);
    error AdapterVaultMismatch(address adapterVault);
    error NavStale();
    error RenounceDisabled();
    error CreditManagerHasDebt(uint256 outstanding);
    error CreditManagerNotVirgin(address incoming);
    error CreditManagerVaultMismatch(address creditManagerVault);
    error PositionNotLiquidatable(uint256 ltvBps);
    error CreditManagerHasUndistributedYield(uint256 undistributed);
    error AuctionHasLiveWork(uint256 outstanding);
    error LiquidationAuctionVaultMismatch(address auctionVault);
    error CreditManagerRiskParamsMismatch(address managerRiskParams);
    error LiquidationAuctionRiskParamsMismatch(address auctionRiskParams);
    /// @notice The incoming manager prices collateral off a different NAV feed to this vault.
    error CreditManagerNavOracleMismatch(address managerNavOracle);
    /// @notice The incoming auction prices collateral off a different NAV feed to this vault.
    error LiquidationAuctionNavOracleMismatch(address auctionNavOracle);

    event YieldHarvested(uint256 usdcAmount);

    IDexFiBond public immutable bond;

    /// @inheritdoc ICollateralVault
    /// @notice The live NAV feed, and the reference the other two nav readers are checked against.
    /// @dev **Audit round 21: the sibling round 20 did not anchor.** Immutability of *this* pointer
    ///      says nothing about the manager's or the auction's, exactly as it said nothing about
    ///      their `riskParams` before #199 - and this pointer had less than that one did, because
    ///      not even `DeployBase._assertCoreGraph` compared the three. `setCreditManager` and
    ///      `setLiquidationAuction` below are what make "the protocol prices one position off one
    ///      feed" a property rather than an intention.
    INAVOracle public immutable override navOracle;

    /// @inheritdoc ICollateralVault
    /// @notice The live risk configuration, and the reference the other two risk readers are
    ///         checked against.
    /// @dev **The sentence that used to be here was wrong, and audit round 20 executed it.** It
    ///      read "Immutable, so this vault and the manager it settles into can never disagree about
    ///      where the liquidation line is". Immutability of *this* pointer says nothing about the
    ///      manager's: the manager is replaceable, and an ordinary zero-debt migration to a pair
    ///      built on a second `RiskParams` was accepted by all seven wiring calls. The claim is now
    ///      true because `setCreditManager` and `setLiquidationAuction` below enforce it, not
    ///      because the keyword implies it.
    IRiskParams public immutable override riskParams;
    /// @notice Pluggable custody backend (direct-call vs Safe) - §4.1 config decision.
    ICustodyAdapter public custodyAdapter;
    address public creditManager;
    address public liquidationAuction;

    /// @inheritdoc ICollateralVault
    mapping(address => uint256) public override bondCount;

    /// @notice Sum of every `bondCount`. Exists so the ledger can be checked against
    ///         what custody actually holds - without it there is no on-chain way to
    ///         notice the two have diverged.
    uint256 public totalBondCount;

    constructor(IDexFiBond bond_, INAVOracle navOracle_, IRiskParams riskParams_, address initialOwner)
        Ownable(initialOwner)
    {
        if (
            address(bond_) == address(0) || address(navOracle_) == address(0)
                || address(riskParams_) == address(0)
        ) revert ZeroAddress();
        bond = bond_;
        navOracle = navOracle_;
        riskParams = riskParams_;
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    /// @dev **Audit round 19's argument, and audit round 21 found it unapplied here.** A real
    ///      adapter's `stakedBalance()` is not a storage getter - it forwards to DexFi's farm - so
    ///      the sentence `_outgoingAuctionWork` uses below ("the only address that fails to answer
    ///      never held live work") does **not** transfer verbatim, and the difference is why this
    ///      helper is written out rather than reusing that one's reasoning by reference.
    ///
    ///      What catching costs: an adapter that genuinely holds a position, whose farm is down,
    ///      reads as idle and can be repointed away from. What it buys is the repoint being
    ///      possible at all, which round 21 measured it was not - `setCustodyAdapter`,
    ///      `depositBonds` and `custodyIsSolvent()` all reverting **permanently**, on a contract
    ///      that cannot be replaced and is holding third-party collateral.
    ///
    ///      The trade is one-sided because the bonds do not move either way. `bondCount` is
    ///      untouched by a repoint, the units stay in the farm under the outgoing adapter, and
    ///      while that farm is down nobody can unstake them whichever address this pointer names -
    ///      so the orphan the catch admits is a wrong pointer over collateral that was already
    ///      immobile, not a loss of it. **That arm is reasoned, not measured.** What is measured is
    ///      the other one: `test_control_aLiveOutgoingPositionIsStillRefused` holds a real position
    ///      under a working farm and is still refused, so the catch did not loosen the guard.
    ///
    ///      The deliberate liar - an adapter that answers at install and refuses afterwards while
    ///      holding a live position - is out of scope for the same reason `CreditManager
    ///      .setLenderPool` gives for its own `catch`: this guard is against operator error, not
    ///      against an owner who is choosing the addresses on both sides.
    function _outgoingStake(ICustodyAdapter current) private view returns (uint256 staked) {
        try current.stakedBalance() returns (uint256 n) {
            staked = n;
        } catch {}
    }

    /// @dev A swap must not orphan a live position: reject unless the outgoing
    ///      adapter holds nothing in custody, and require the incoming adapter to be
    ///      bound to this vault. Migrating a live position requires unstaking first
    ///      (or an explicit migration path), never a bare re-point.
    ///
    /// @dev **Audit round 21: this contract's own docstring, one function down, calls its incoming
    ///      probe "the weakest in the protocol" - and it says that about the auction pointer, which
    ///      round 20 then fixed. The sentence was left standing, true and unread, about this
    ///      setter.** Measured: an adapter answering `vault()` and nothing else installed with no
    ///      revert, and afterwards this function, `depositBonds` and `custodyIsSolvent()` all
    ///      reverted forever.
    ///
    ///      **What this probe does not check, said plainly rather than left to a count.** This
    ///      contract calls six selectors bare on this pointer - `stake`, `unstake`, `claimYield`,
    ///      `transferBonds`, `stakedBalance` and `mintBonds` - and four of them change state, so
    ///      they cannot be probed by calling them. The probe below therefore covers **two of six**,
    ///      and an adapter that answers both views and implements none of the four still installs
    ///      and still bricks `depositBonds`. What it does close is the way back: an adapter that
    ///      answers `stakedBalance()` at install answers it at the next repoint too, so the escape
    ///      hatch survives the mistake even where the probe did not prevent it. That, and not the
    ///      count, is the property worth having.
    ///
    ///      Bare rather than `try`/`catch` with an error of its own, following `LiquidationAuction
    ///      .setCreditManager`'s `totalBountyParked()` probe: this path is `onlyOwner`, so failing
    ///      loudly with no data costs nothing a named error would buy.
    function setCustodyAdapter(ICustodyAdapter adapter) external onlyOwner {
        if (address(adapter) == address(0)) revert ZeroAddress();
        ICustodyAdapter current = custodyAdapter;
        if (address(current) != address(0)) {
            // Audit round 21: this read was bare. See `_outgoingStake`.
            uint256 staked = _outgoingStake(current);
            if (staked != 0) revert AdapterHasLivePosition(staked);
        }
        address boundVault = adapter.vault();
        if (boundVault != address(this)) revert AdapterVaultMismatch(boundVault);
        // The second of the two views, probed for the reason given above. Its value is discarded:
        // a fresh adapter's balance is whatever it is, and this is testing only that the call
        // answers at all.
        // slither-disable-next-line unused-return
        adapter.stakedBalance();
        custodyAdapter = adapter;
    }

    /// @dev The manager-pointer twin of `_outgoingStake`. See the `totalDebt` call site in
    ///      `setCreditManager` for why catching here is safe in a way it is not for the adapter.
    function _outgoingDebt(address current) private view returns (uint256 outstanding) {
        try ICreditManager(current).totalDebt() returns (uint256 n) {
            outstanding = n;
        } catch {}
    }

    /// @dev Refuses to repoint while the outgoing manager still records debt.
    ///      `withdrawBonds` reads its entire LTV rule out of this pointer, so a swap
    ///      over live debt makes every borrower read zero and withdraw all of their
    ///      collateral against a loan the old manager still holds. Both structural
    ///      siblings - `setCustodyAdapter` here and `setLiquiditySource` on
    ///      CreditManager - already guard their own live state; this one did not.
    ///
    ///      It also checks the incoming manager is bound back to this vault, the same
    ///      way `setCustodyAdapter` does. Since Phase 3 the vault settles a position
    ///      before every bond-count change, and `settleForVault` is gated on the
    ///      caller being its own vault - so pointing at a manager bound elsewhere
    ///      reverts every deposit, withdrawal and seizure, with collateral inside.
    function setCreditManager(address creditManager_) external onlyOwner {
        if (creditManager_ == address(0)) revert ZeroAddress();
        address current = creditManager;
        if (current != address(0)) {
            // **Audit round 21, and the read is one statement above the two round 19 wrapped.**
            // Bare on the address this setter is *replacing*, in the function this file calls "the
            // escape from every other unrecoverable state in this contract". A manager answering
            // the four selectors probed below but not this one installed cleanly and then welded
            // the hatch shut.
            //
            // Here round 19's argument does transfer verbatim, unlike the adapter's above:
            // `CreditManager.totalDebt` is a plain `uint256` public getter over storage and cannot
            // revert, so the only address that fails to answer it was never a credit manager, and
            // an address that was never a credit manager records no debt for this guard to
            // protect. Catching can only make a repoint more possible, never a genuine one less
            // refused.
            uint256 outstanding = _outgoingDebt(current);
            if (outstanding != 0) revert CreditManagerHasDebt(outstanding);
            // Debt is not the only live state a manager owns, and it is not even the
            // one most at risk here. Yield accrues to bond *holders*, so a vault of
            // pure stakers has zero debt - the exact state this guard waves through -
            // while holding the largest unpaid pot. Detaching then freezes the
            // accumulator and makes `accrueYield`/`settle` revert `Detached`, with the
            // USDC unreachable and no sweep.
            // **Deliberately no `undistributedYield` guard here.** One was added and
            // then removed in the same day's work, and the reason is worth keeping.
            //
            // It compared against `Config.MIN_EPOCH_YIELD` - the same constant that
            // prices a real epoch - so the minimum spend that buys a dust epoch was by
            // construction the minimum spend that blocks a migration. `harvest` is
            // permissionless, so anyone could pin the guard closed for about $1.82 every
            // five days, and its honest escape window was roughly the last 1% of each
            // stream. A guard on the emergency migration path that a stranger can hold
            // shut is worse than the dust it protects.
            //
            // It also guarded the wrong pot. `insuranceFund` is an order of magnitude
            // larger, grows monotonically, and its only spender needs a live borrower on
            // the outgoing manager - which `totalDebt == 0` has just guaranteed does not
            // exist. **That strand is real, and `CreditManager.migrateReserves` is the
            // fix for it** - a migration path on the manager, not a guard here. The
            // one-way-detachment note below is what makes that sweep safe: nobody is
            // coming back for the outgoing manager. Recorded in the private security notes.
        }
        // **The twin of `setLiquidationAuction`'s guard, and the one round 6b missed.**
        // `expireToWorkout` takes its authorisation from *this* pointer, via
        // `reassign`'s `_requireLiquidatable`, but reads `debtAtExpiry` from the
        // auction's. Moving this one while an auction is live pins the two apart -
        // and pins them apart permanently, because the auction's own setter then
        // refuses to follow while it has live work. The result is a lot seized under
        // one manager's health check and recorded against another manager's zero
        // debt: no penalty, no shortfall, and a live loan left with no collateral.
        //
        // The precondition is reachable without anyone misbehaving: `repayFor` is
        // permissionless and `cancel` is optional and unrewarded, so `totalDebt` can
        // sit at zero with an auction ticket still ticking.
        address auction = liquidationAuction;
        if (auction != address(0)) {
            // **Audit round 19.** Bare reads on an address this setter is not replacing and does
            // not control. It matters more here than anywhere else in the protocol: this function
            // is the escape from every other unrecoverable state in this contract, and a stub
            // installed at `liquidationAuction` - which needs only to answer `vault()` to get in -
            // bricked it permanently. See `_outgoingAuctionWork` for why an unanswerable auction is
            // treated as idle rather than as busy.
            (uint256 liveAuctions, uint256 openWorkouts) = _outgoingAuctionWork(auction);
            if (liveAuctions != 0) revert AuctionHasLiveWork(liveAuctions);
            if (openWorkouts != 0) revert AuctionHasLiveWork(openWorkouts);
        }
        address boundVault = address(ICreditManager(creditManager_).vault());
        if (boundVault != address(this)) revert CreditManagerVaultMismatch(boundVault);

        // **Audit round 20: the one cross-contract pointer with no binding check anywhere.** Every
        // setter in this protocol cross-checks the pointer *relation* it installs and none of them
        // looked at the risk parameters, so a manager reading a different `RiskParams` installed
        // here without a murmur. What that buys is a position both contracts have an opinion about
        // and no shared answer for: liquidatable under the auction's threshold, healthy under this
        // one, so `bid` and `expireToWorkout` refuse it here while `cancel` refuses it there.
        //
        // Checked against *this* contract's pointer rather than between the incoming pair, because
        // this is the only contract in the graph that cannot be replaced - there is no
        // `setCollateralVault`, and the vault pointer is `immutable` on both the manager and the
        // auction. Two replaceable contracts checking each other can agree while both disagree
        // with the collateral.
        //
        // No probe is owed for this selector. The probe rule covers selectors called *bare and
        // elsewhere* on a pointer this setter installs; `riskParams()` is called here and nowhere
        // else, so the call is its own probe and an address that cannot answer it is refused
        // rather than installed.
        address incomingRisk = address(ICreditManager(creditManager_).riskParams());
        if (incomingRisk != address(riskParams)) revert CreditManagerRiskParamsMismatch(incomingRisk);

        // **Audit round 21, and the same argument one pointer over.** `navOracle` is the other
        // `immutable` all three of the vault, the manager and the auction carry, and it had none of
        // the six guards the risk pointer got. What a divergence buys here is quieter than the risk
        // one and worth more: nothing reverts, because this manager reads its feed only for
        // `borrow`'s staleness gate while this vault values the collateral off its own. The vault
        // calls the price stale and the manager keeps lending against it, or the reverse freezes
        // borrowing over a book nothing is wrong with.
        //
        // No probe is owed, for the same reason the line above owes none: `navOracle()` is called
        // here and nowhere else, so the call is its own probe.
        address incomingNav = address(ICreditManager(creditManager_).navOracle());
        if (incomingNav != address(navOracle)) revert CreditManagerNavOracleMismatch(incomingNav);

        // **Detachment is one-way.** `whileAttached` stops a detached manager pricing
        // positions it no longer governs, but nothing stopped it being pointed at
        // again - and `_settle`'s detached early-return skips the index stamp, so any
        // position whose bond count moved during the gap carries a zero index against
        // a frozen, non-zero accumulator. Re-attaching lets it claim the whole of that
        // accumulator: the drain `whileAttached`'s own docstring says it closes,
        // reachable from the other side. One block of detachment is enough, and a
        // searcher only has to sandwich a deposit between two owner transactions.
        //
        // A virgin manager reports a zero accumulator, so this blocks exactly the
        // dangerous case and nothing else. It is also what lets `migrateReserves`
        // sweep the outgoing manager: nobody is coming back for it.
        if (current != address(0) && ICreditManager(creditManager_).accYieldPerBond() != 0) {
            revert CreditManagerNotVirgin(creditManager_);
        }
        creditManager = creditManager_;
    }

    /// @dev Both structural siblings guard their live state; this one did not, and the
    ///      omission is worse here than it looks. The outgoing auction is the only
    ///      caller `seize` and `reassign` accept, so repointing while an auction is live
    ///      makes `bid` and `expireToWorkout` revert `NotLiquidationAuction` and leaves
    ///      `cancel` - which refuses precisely while the position is underwater. All
    ///      three exits closed at once, with collateral inside, which is the one state
    ///      the auction's own header names as the thing that must never exist.
    ///
    ///      Gated on the outgoing auction reporting no live auctions and no open
    ///      workouts, and on the incoming one being bound back to this vault, the same
    ///      way `setCreditManager` does.
    ///
    /// @dev **Audit round 19, and the twin of `CreditManager._outgoingAuctionWork`.** Both setters
    ///      above read two selectors off an auction pointer they are not installing, bare. This
    ///      contract's incoming probe is the weakest in the protocol - it checks `vault()` and
    ///      nothing else, while three functions read four selectors off that pointer bare - so a
    ///      stub answering only `vault()` installs, and from then on `setLiquidationAuction` *and*
    ///      `setCreditManager` revert forever, on an immutable contract holding third-party
    ///      collateral.
    ///
    ///      Treating an unanswerable outgoing auction as idle is the safe direction rather than the
    ///      convenient one: a real `LiquidationAuction` answers both with plain storage getters
    ///      that cannot revert, so the only address that fails to answer never held live work for
    ///      this guard to protect. Catching can only make a repoint more possible, never a genuine
    ///      one less refused.
    function _outgoingAuctionWork(address auction) private view returns (uint256 live, uint256 open) {
        try ILiquidationAuction(auction).liveAuctionCount() returns (uint256 n) {
            live = n;
        } catch {}
        try ILiquidationAuction(auction).openWorkoutCount() returns (uint256 n) {
            open = n;
        } catch {}
    }

    function setLiquidationAuction(address liquidationAuction_) external onlyOwner {
        if (liquidationAuction_ == address(0)) revert ZeroAddress();
        address current = liquidationAuction;
        if (current != address(0)) {
            // Audit round 19: bare reads on the outgoing pointer. See `_outgoingAuctionWork`.
            (uint256 liveAuctions, uint256 openWorkouts) = _outgoingAuctionWork(current);
            if (liveAuctions != 0) revert AuctionHasLiveWork(liveAuctions);
            if (openWorkouts != 0) revert AuctionHasLiveWork(openWorkouts);
            // **Counting queue entries is not the same as counting assets.**
            // `closeWorkout` pops the queue but leaves the lot parked under the
            // outgoing auction's ledger entry; only `disposeWorkoutLot` clears it, and
            // that call needs this pointer still to name that auction. Between the two
            // - which is the normal steady state, since the close is forced at 14 days
            // while the DexFi redemption behind the disposal is quoted at "48h+" - both
            // counters read zero over collateral that is still there.
            //
            // Repointing there strands the lot for good: `disposeTo` refuses the old
            // auction, the new one has no ledger entry to dispose from, and `seize`
            // and `reassign` both refuse a debt-free holder. `totalBondCount` then
            // overstates forever, diluting every later accrual, and `setCustodyAdapter`
            // is blocked by a position nobody can clear. `setCustodyAdapter` gets this
            // right by checking a balance rather than a queue; so does this now.
            uint256 heldLot = bondCount[current];
            if (heldLot != 0) revert AuctionHasLiveWork(heldLot);
        }
        address boundVault = address(ILiquidationAuction(liquidationAuction_).vault());
        if (boundVault != address(this)) revert LiquidationAuctionVaultMismatch(boundVault);

        // Audit round 20, and the twin of the check in `setCreditManager`. This one is the direct
        // one: `bid` calls `seize` here, which re-runs the health test against *this* contract's
        // threshold, while the auction opened the lot against its own. An auction on a different
        // authority is an auction whose own fill path this contract refuses.
        //
        // It also, incidentally, gives this contract the incoming probe its own docstring below
        // calls the weakest in the protocol: an address answering `vault()` and nothing else no
        // longer installs.
        address incomingRisk = address(ILiquidationAuction(liquidationAuction_).riskParams());
        if (incomingRisk != address(riskParams)) revert LiquidationAuctionRiskParamsMismatch(incomingRisk);

        // **Audit round 21, and the loudest of the six.** `start` fixes the Dutch curve off the
        // auction's own feed and freezes it for the auction's life, while `bid` settles a debt this
        // contract priced off its own. Measured on the shipped fixture: an auction one order of
        // magnitude behind sold a lot worth 943.125000 for 94.312500 and wrote off 534.437500 of
        // principal, against a control that wrote off nothing.
        address incomingNav = address(ILiquidationAuction(liquidationAuction_).navOracle());
        if (incomingNav != address(navOracle)) revert LiquidationAuctionNavOracleMismatch(incomingNav);

        liquidationAuction = liquidationAuction_;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Renouncing would permanently disable all wiring and the pause switch.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── ICollateralVault ─────────────────────────────────────────────────────

    /// @inheritdoc ICollateralVault
    function depositBonds(uint256 amount) external whenNotPaused nonReentrant {
        ICustodyAdapter adapter = _adapter();
        if (amount == 0) revert ZeroAmount();

        // Settle against the balance that earned, and set a new position's index to
        // now. Without this a fresh depositor would inherit an index of zero and
        // immediately claim every epoch distributed before they arrived.
        _settlePosition(msg.sender);

        bondCount[msg.sender] += amount;
        totalBondCount += amount;
        emit BondsDeposited(msg.sender, amount);

        // Passes DexFi's whitelist iff the adapter is whitelisted (to-side).
        bond.safeTransferFrom(msg.sender, address(adapter), Config.DEXFI_BOND_TOKEN_ID, amount, "");
        // A deposit settles the farm's pending rewards for the whole adapter position,
        // so it flushes protocol-wide yield exactly as a withdrawal does. Report it
        // for the same reason: unreported, an epoch of everyone's yield could be
        // pushed out through the deposit path with nothing accounting for it.
        uint256 swept = adapter.stake(amount);
        if (swept != 0) emit YieldHarvested(swept);
    }

    /// @inheritdoc ICollateralVault
    /// @dev Slither reentrancy-benign: bondCount is written after the external mint
    ///      because the minted amount cannot be known before it; guarded by
    ///      nonReentrant and the adapter is immutable protocol code.
    // slither-disable-next-line reentrancy-benign
    function depositETH(bytes calldata mintData) external payable whenNotPaused nonReentrant {
        ICustodyAdapter adapter = _adapter();
        if (msg.value == 0) revert ZeroAmount();

        // Mint via DexFi's keeper-signed payload; bonds auto-stake for the adapter.
        uint256 amount = adapter.mintBonds{value: msg.value}(mintData);
        if (amount == 0) revert NothingMinted();

        _settlePosition(msg.sender);
        bondCount[msg.sender] += amount;
        totalBondCount += amount;
        emit ETHDeposited(msg.sender, msg.value, amount);
    }

    /// @inheritdoc ICollateralVault
    function withdrawBonds(uint256 amount) external nonReentrant {
        ICustodyAdapter adapter = _adapter();
        uint256 held = bondCount[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > held) revert InsufficientCollateral(amount, held);

        // Credit earned yield first, so the check prices the debt actually owed. A
        // borrower whose yield has already covered their loan must not be refused
        // their own collateral on a stale figure.
        _settlePosition(msg.sender);

        // Withdrawal rule (PRD §4.1): free when debt-clear, else the remaining
        // collateral must keep LTV within maxLTV. The formula lives in LtvMath so
        // borrowing and withdrawing can never disagree about what is safe.
        if (creditManager != address(0)) {
            uint256 debt = ICreditManager(creditManager).debtOf(msg.sender);
            if (debt > 0) {
                // Releasing collateral raises LTV exactly as borrowing does, so it
                // must not price against a stale NAV (PRD §4.6).
                if (navOracle.isStale()) revert NavStale();
                uint256 remainingValue = LtvMath.collateralValue(held - amount, navOracle.navPerBond());
                uint256 ceiling = riskParams.maxLtvBps();
                if (LtvMath.exceedsLtv(debt, remainingValue, ceiling)) {
                    revert WithdrawalExceedsMaxLtv(LtvMath.ltvBps(debt, remainingValue), ceiling);
                }
            }
        }

        bondCount[msg.sender] = held - amount;
        totalBondCount -= amount;
        emit BondsWithdrawn(msg.sender, amount);

        // The farm settles the whole position's pending USDC on any withdrawal, so
        // this path moves protocol-wide yield. Surface it, or an epoch's yield can
        // leave through here with the accounted harvest reading zero.
        uint256 swept = adapter.unstake(amount);
        if (swept != 0) emit YieldHarvested(swept);
        adapter.transferBonds(msg.sender, amount);
    }

    /// @inheritdoc ICollateralVault
    function seize(address owner_, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != liquidationAuction) revert NotLiquidationAuction();
        if (to == address(0)) revert ZeroAddress();
        ICustodyAdapter adapter = _adapter();

        amount = bondCount[owner_];
        if (amount == 0) return 0;
        _requireLiquidatable(owner_, amount);
        _settlePosition(owner_);
        bondCount[owner_] = 0;
        totalBondCount -= amount;
        emit BondsSeized(owner_, to, amount);

        // The farm settles the whole position's pending USDC on any withdrawal, so
        // this path moves protocol-wide yield. Surface it, or an epoch's yield can
        // leave through here with the accounted harvest reading zero.
        uint256 swept = adapter.unstake(amount);
        if (swept != 0) emit YieldHarvested(swept);
        adapter.transferBonds(to, amount);
    }

    /// @inheritdoc ICollateralVault
    /// @dev The workout path, and the reason it moves nothing: DexFi's transfer gate
    ///      passes only when the adapter is party to the transfer, so any expiry that
    ///      relocated bonds would need a second whitelisted address the protocol has
    ///      not been granted. An exit that can revert while holding a third party's
    ///      collateral is the failure this codebase has paid for repeatedly, so the
    ///      claim moves and the lot stays staked - still earning, through a manual
    ///      redemption quoted at "48h+".
    ///
    ///      `totalBondCount` is deliberately untouched: the bonds are still in custody
    ///      and still collateral, so changing it would make `custodyIsSolvent()` lie.
    ///
    ///      Both sides settle first, for the same reason every other bond-count change
    ///      does: yield accrued to the old balances, and settling afterwards would pay
    ///      the wrong amount in both directions.
    function reassign(address from, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != liquidationAuction) revert NotLiquidationAuction();
        if (to == address(0) || from == address(0)) revert ZeroAddress();
        if (to == from) revert ZeroAddress();

        amount = bondCount[from];
        if (amount == 0) return 0;
        _requireLiquidatable(from, amount);

        _settlePosition(from);
        _settlePosition(to);
        bondCount[from] = 0;
        bondCount[to] += amount;
        emit BondsReassigned(from, to, amount);
    }

    /// @notice Send a workout lot out of custody in one hop. LiquidationAuction only.
    /// @dev **The disposal path, done the only way DexFi's gate permits.** An earlier
    ///      version had the auction call `withdrawBonds` and then forward the units
    ///      itself. That second hop has `msg.sender == from == auction` and an arbitrary
    ///      `to`, so no party is whitelisted and it reverts - which is precisely what
    ///      this protocol's whole no-escrow design is built around, asserted in the
    ///      auction's own header, and still shipped. The two tests covering it passed
    ///      only because they whitelisted the destination first.
    ///
    ///      Routing it through the adapter puts the one whitelisted address on both
    ///      `msg.sender` and `from`, exactly as `seize` does. No ERC-1155 units ever
    ///      touch the auction.
    ///
    ///      Not gated on liquidatability: the position being disposed of belongs to the
    ///      auction and carries no debt by construction, so `_requireLiquidatable` would
    ///      refuse it every time. That is the whole reason the earlier design could not
    ///      recover the lot by any route.
    function disposeTo(address to, uint256 amount) external nonReentrant {
        if (msg.sender != liquidationAuction) revert NotLiquidationAuction();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        ICustodyAdapter adapter = _adapter();
        uint256 held = bondCount[msg.sender];
        if (amount > held) revert InsufficientCollateral(amount, held);

        _settlePosition(msg.sender);
        bondCount[msg.sender] = held - amount;
        totalBondCount -= amount;
        emit BondsDisposed(msg.sender, to, amount);

        uint256 swept = adapter.unstake(amount);
        if (swept != 0) emit YieldHarvested(swept);
        adapter.transferBonds(to, amount);
    }

    /// @dev Defence in depth for the largest single-key power in the protocol: with an
    ///      EOA owner, `setLiquidationAuction(x)` followed by `seize(anyone, x)` takes
    ///      any position's whole collateral in two transactions with no independent
    ///      check. The vault cannot know whether an auction is honest, but it can
    ///      refuse to hand over a position that is not actually liquidatable, which
    ///      narrows that power from "anyone's collateral, instantly" to "collateral
    ///      that was already forfeit". It narrows go-live item G2; it does not replace
    ///      it, because a holder of both the owner and keeper keys can still post a NAV
    ///      that manufactures unhealthy positions.
    ///
    ///      Compared with `exceedsLtv`, never `healthFactor`: the view divides twice
    ///      and reports exactly 1e18 for a position a fraction of a bp past the
    ///      threshold, so gating on it would refuse precisely the first position that
    ///      becomes liquidatable - an auction that can be started and never settled.
    ///
    ///      Skipped entirely when no manager is wired. A vault with no credit manager
    ///      records no debt, so there is nothing to be unhealthy about, and reverting
    ///      would make the check an obstacle to the very migration path that sets one.
    ///
    ///      Deliberately still ungated on NAV staleness and custody solvency: PRD §4.6
    ///      keeps liquidation alive on the last known NAV, and a break-glass custody
    ///      exit must not also disable it.
    function _requireLiquidatable(address owner_, uint256 amount) private view {
        address cm = creditManager;
        if (cm == address(0)) return;
        uint256 debt = ICreditManager(cm).currentDebtOf(owner_);
        uint256 value = LtvMath.collateralValue(amount, navOracle.navPerBond());
        if (!LtvMath.exceedsLtv(debt, value, riskParams.liquidationThresholdBps())) {
            revert PositionNotLiquidatable(LtvMath.ltvBps(debt, value));
        }
    }

    /// @inheritdoc ICollateralVault
    /// @dev Deliberately ungated on staleness: liquidations must keep pricing on the
    ///      last known NAV (PRD §4.6). Callers that gate state changes must check
    ///      `navOracle.isStale()` themselves, as `withdrawBonds` and
    ///      `CreditManager.borrow` do. Likewise ungated on `custodyIsSolvent()`, so
    ///      liquidation keeps working after a break-glass exit.
    function collateralValue(address owner_) external view returns (uint256) {
        return LtvMath.collateralValue(bondCount[owner_], navOracle.navPerBond());
    }

    /// @notice True when custody holds at least as many bonds as the ledger records.
    /// @dev `DirectCallAdapter.emergencyUnstake` empties the farm position without
    ///      touching `bondCount`, so after a break-glass exit the ledger prices
    ///      collateral that is no longer held. Withdrawals revert on their own (there
    ///      is nothing to unstake), but nothing stopped *new borrowing* against it,
    ///      which is unrecoverable. `CreditManager.borrow` gates on this.
    ///
    ///      Reads live farm state, so it is also the honest version of the check
    ///      `setCustodyAdapter` makes: `stakedBalance() == 0` proves nothing while the
    ///      ledger is non-empty.
    function custodyIsSolvent() public view returns (bool) {
        ICustodyAdapter adapter = custodyAdapter;
        if (address(adapter) == address(0)) return false;
        return adapter.stakedBalance() >= totalBondCount;
    }

    // ── Yield ────────────────────────────────────────────────────────────────

    /// @notice Owner-triggered claim of accrued USDC from the farm.
    /// @dev No longer the main route. Since Phase 3 `EpochHarvester.harvest()` calls
    ///      `claimYield` on the adapter itself and splits the proceeds per PRD §4.4;
    ///      the adapter's `onlyClaimer` gate accepts this vault or the wired
    ///      harvester, so both callers work. This stays as the manual path.
    ///
    ///      **The USDC does not land here, despite the name.** `claimYield` sweeps it
    ///      to the adapter's `yieldRecipient`, which is the harvester in a wired
    ///      deployment. That is deliberate: this contract is immutable and has no
    ///      egress, so USDC arriving here would be lost - the first audit's worst
    ///      finding, and the reason the recipient is settable rather than fixed.
    // slither-disable-next-line reentrancy-events
    function harvestYield() external onlyOwner returns (uint256 usdcAmount) {
        usdcAmount = _adapter().claimYield();
        emit YieldHarvested(usdcAmount);
    }

    /// @dev Credit any yield the position has earned before its bond count moves.
    ///      Yield accrued to the OLD balance, so settling after the change would pay
    ///      the wrong amount in both directions.
    function _settlePosition(address owner_) private {
        address cm = creditManager;
        if (cm != address(0)) ICreditManager(cm).settleForVault(owner_, bondCount[owner_]);
    }

    function _adapter() internal view returns (ICustodyAdapter adapter) {
        adapter = custodyAdapter;
        if (address(adapter) == address(0)) revert AdapterNotSet();
    }
}
