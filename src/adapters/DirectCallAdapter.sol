// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Config} from "../Config.sol";
import {MintAttemptReceiver} from "../MintAttemptReceiver.sol";
import {ICustodyAdapter} from "../interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../interfaces/IDexFiFarm.sol";

/// @title DirectCallAdapter (PRD §4.1)
/// @notice Custody backend where the protocol itself holds and works the DexFi
///         position: this contract is the farm staker and the address DexFi must
///         add to the bond transfer whitelist (§14 ask #5). Holds no USDC at rest -
///         every claim is forwarded to `yieldRecipient` in the same call.
/// @dev Vault-only for the custody hot path; owner-only (the governance timelock) for
///      the yield-routing config and the emergency hatch. `yieldRecipient` and
///      `harvester` are settable so the immutable adapter can be pointed at the
///      EpochHarvester once it ships, without a redeploy/migration.
contract DirectCallAdapter is ICustodyAdapter, ERC1155Holder, Ownable {
    using SafeERC20 for IERC20;

    error NotVault();
    error NotClaimer();
    error InvalidBeneficiary();
    error InvalidAttemptId();
    error MintReceiverMismatch(address expected, address actual);
    error MintNonceMustBeZero(uint256 supplied);
    error MintAttemptAlreadyUsed(address receiver, uint256 nonce);
    error MintAttemptAlreadyDeployed(address receiver);
    error AdapterNotWhitelisted();
    error ZeroMintAmount();
    error InvalidRecoveryRecipient(address recipient);
    error InvalidMintReceiverCode(address receiver, bytes32 actual, bytes32 expected);
    error MintReceiverDeployMismatch(address expected, address actual);
    error MintReceiverPositionMismatch(
        uint256 expectedStake, uint256 actualStake, uint256 expectedLoose, uint256 actualLoose
    );
    error AdapterPositionMismatch(
        uint256 expectedStake, uint256 actualStake, uint256 expectedLoose, uint256 actualLoose
    );
    error PaymentMismatch(uint256 expected, uint256 actual);
    error MintAmountMismatch(uint256 expected, uint256 actual);
    error MintReceiverUsdcMismatch(uint256 expected, uint256 actual);
    error NothingToRecover(address receiver);
    error ZeroAddress();
    error RenounceDisabled();
    error NothingToFlush();

    event YieldRecipientSet(address indexed recipient);
    event HarvesterSet(address indexed harvester);
    event EmergencyUnstaked(address indexed to, uint256 amount);
    event YieldParked(address indexed recipient, uint256 amount, uint256 totalOwed);
    event YieldFlushed(address indexed recipient, uint256 amount);
    event MintAttemptExecuted(
        address indexed beneficiary,
        bytes32 indexed attemptId,
        address indexed receiver,
        uint256 paymentAmount,
        uint256 bondAmount
    );
    /// @dev 🟥 **`bonds` means two different things and only `emergency` says which.** On the
    ///      normal path it is the amount that moved clone -> adapter -> `recoveryRecipient` in this
    ///      transaction. On the emergency path `emergencyRecoverAll` deliberately performs no
    ///      ERC-1155 transfer, so `bonds` is the amount **still sitting at the clone** and
    ///      `recoveryRecipient` is `address(0)`. MEASURED at audit round 34, same 9 units both
    ///      ways: normal left 0 at the clone and 9 at the recipient; emergency left 9 at the clone
    ///      and 0 at the adapter. A consumer that reads `bonds` as "delivered to
    ///      `recoveryRecipient`" therefore reads the emergency event as 9 units sent to the zero
    ///      address. `emergency == true` and `recoveryRecipient == address(0)` are both reliable
    ///      discriminators; nothing but this comment says so.
    ///
    ///      **`farmYieldForwarded` can under-report** - see `_recoverTo`, where a re-entrant
    ///      `flushMintAttemptYield` was measured making it read 0 against 41.000000 that really
    ///      left. Read `farmYieldDelivered` and the recipient's balance, never this field alone.
    event MintAttemptRecovered(
        address indexed beneficiary,
        bytes32 indexed attemptId,
        address indexed receiver,
        address recoveryRecipient,
        uint256 bonds,
        uint256 farmYieldForwarded,
        uint256 rawUsdcForwarded,
        uint256 rawUsdcRemaining,
        uint256 nativeForwarded,
        uint256 nativeRemaining,
        bool emergency
    );
    event MintAttemptYieldFlushed(
        address indexed beneficiary,
        bytes32 indexed attemptId,
        address indexed receiver,
        uint256 received,
        uint256 swept
    );

    IDexFiBond public immutable bond;
    IDexFiFarm public immutable farm;
    IERC20 public immutable usdc;
    address public immutable vault;
    MintAttemptReceiver public immutable mintReceiverImplementation;

    bytes32 public constant MINT_ATTEMPT_DOMAIN = keccak256("RECOUP_MINT_ATTEMPT_V1");

    struct MintSnapshot {
        uint256 childStake;
        uint256 childLoose;
        uint256 childUsdc;
    }

    struct RecoveryResult {
        uint256 bonds;
        uint256 farmForwarded;
        uint256 swept;
        uint256 rawUsdcForwarded;
        uint256 rawUsdcRemaining;
        uint256 nativeForwarded;
        uint256 nativeRemaining;
    }

    /// @notice Where claimed/swept USDC is sent. Defaults to a treasury sink at
    ///         deploy; repointed to the EpochHarvester when Phase 3 lands.
    address public yieldRecipient;
    /// @notice Additional address permitted to trigger a claim (the EpochHarvester),
    ///         so harvesting need not route through the owner-only vault path.
    address public harvester;

    /// @notice Farm yield that has been received but not yet reported to the vault -
    ///         a deposit-time settlement, or a payout left behind by a sweep that
    ///         failed. Carried so the next successful claim reports it rather than the
    ///         money leaving the protocol's accounting silently.
    uint256 public unreportedYield;

    /// @notice Farm yield that accrued while a given address was the yield recipient and which that
    ///         address could not take when it was repointed away from. Payable to it forever.
    /// @dev **Audit round 22, finding 4.** `setYieldRecipient` validated `!= address(0)` and nothing
    ///      else, and what it carries is **gross** yield - the whole pot, before the 55/25/10/10
    ///      split. The only protection was the best-effort drain below, which does nothing on
    ///      precisely the condition the setter exists for: a blacklist, a pause. MEASURED:
    ///      1,000.000000 gross accrued, the drain inert, and the next ordinary `depositBonds(1)` -
    ///      **called by a lender, not the owner** - delivered the whole 1,000.000000 to the incoming
    ///      address and 0 to the recipient that earned it, while `farmYieldDelivered` recorded it as
    ///      delivered. CONTROL: a recipient able to receive means the drain works and nothing parks.
    ///
    ///      **The fix is copied from `EpochHarvester`, which parks per recipient twice.**
    ///      `owedToPool` since round 11 and `owedProtocolFee` since round 21, each drained by a
    ///      permissionless `flush...To(address)` that takes its destination from the mapping key.
    ///      The reasoning transplants line for line, and `setProtocolFeeWallet` had already
    ///      **rejected "drain first"** for the same pot one contract downstream: draining hands the
    ///      outgoing recipient a veto over its own replacement, which is the trap this setter was
    ///      built to escape. So the drain stays best-effort, and whatever it could not move is
    ///      checkpointed here instead of being left free for the next sweep to hand onward.
    ///
    ///      A mapping cannot be summed and `_trySweepUsdc` sizes its transfer from this contract's
    ///      raw balance, so `totalOwedToRecipients` exists beside it and that sweep subtracts it.
    ///      Without that, a parked balance would be swept to the incoming recipient on the very
    ///      next farm-touching call and still be owed here.
    mapping(address => uint256) public owedToRecipient;

    /// @notice Sum of `owedToRecipient`. The USDC sitting here that is not this contract's to
    ///         forward - the same role `EpochHarvester.totalOwedToPools` plays one contract down.
    uint256 public totalOwedToRecipients;

    /// @inheritdoc ICustodyAdapter
    /// @dev Monotonic, and the reason it can be trusted is that `_settleFarmPayout` is handed a
    ///      *measured delta* rather than this contract's balance. `_trySweepUsdc` moves everything
    ///      sitting here, donations included, but only a measured delta is ever added to this
    ///      counter. **So the property that holds is that a party who can only SEND TOKENS cannot
    ///      move this number** - not the wider claim that no outside party can, which this comment
    ///      used to make and which is false on one path.
    ///
    ///      **The exception, named rather than left to be found. Recorded round-34 Low 1.**
    ///      `autoDepositPaid` in `_mintIntoReceiver` is the one measurement feeding this counter
    ///      that is taken across `bond.mint` rather than across a `farm.*` call: it is the
    ///      receiver's USDC balance differenced over the whole mint. DexFi's `treasury` is
    ///      owner-settable and is called inside that window, so USDC arriving at the receiver from
    ///      that address during the mint is counted here as farm yield. It is measured against
    ///      `Config.MIN_EPOCH_FARM_YIELD` - one dollar - so it is the epoch-liveness signal that
    ///      would be bought, exactly as round 11's donated $1.82 bought one.
    ///
    ///      It needs DexFi's owner key, which already permits strictly better attacks than
    ///      manufacturing a dollar of apparent yield, and `treasury()` is an EOA today, so the
    ///      hook is inert. It is written down because an unstated exception in a monotonicity
    ///      claim reads as coverage.
    ///
    ///      **The obvious fix is REFUSED, and the reason is worth keeping.** Corroborating
    ///      `autoDepositPaid` against a `farm.pendingShare(receiver)` read taken before the mint
    ///      cannot work: the farm is MasterChef-style, `bond.mint`'s `depositForAccount` hook is a
    ///      deposit, and a deposit settles the whole position's pending rewards. So the pre-mint
    ///      `pendingShare` IS the quantity the auto-deposit pays out. The check would compare a
    ///      figure against itself, and would pass on precisely the case it was added to catch.
    ///
    ///      Audit round 11 is why it exists, and the shape of that finding is why it lives here
    ///      rather than in the harvester. `EpochHarvester.harvest` treats the farm claim as
    ///      best-effort but treated the epoch as real regardless, so ~$1.82 of donated USDC bought
    ///      a write to `CreditManager.lastDistributeAt` - the sole record of how long an epoch's
    ///      money took to earn. The sharper signal that closes it was already being computed on
    ///      every farm-touching path and thrown away: `stake`, `unstake`, `mintBonds` and
    ///      `claimYield` all return it and `CollateralVault` emits it and drops it. Accumulating
    ///      it costs one SSTORE on paths that are already writing storage.
    ///
    ///      Never decreases, so the harvester can hold a high-water mark against it. A fresh
    ///      adapter starts at zero, which is exactly why `EpochHarvester.setCustodyAdapter`
    ///      re-seeds that mark instead of carrying it across a custody swap: a stale mark against
    ///      a zeroed counter would decline every epoch forever.
    uint256 public farmYieldDelivered;

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @dev Vault or the wired harvester may claim yield.
    modifier onlyClaimer() {
        if (msg.sender != vault && msg.sender != harvester) revert NotClaimer();
        _;
    }

    constructor(
        IDexFiBond bond_,
        IDexFiFarm farm_,
        IERC20 usdc_,
        address vault_,
        address initialOwner,
        address yieldRecipient_
    ) Ownable(initialOwner) {
        if (
            address(bond_) == address(0) || address(farm_) == address(0)
                || address(usdc_) == address(0) || vault_ == address(0)
                || yieldRecipient_ == address(0)
        ) revert ZeroAddress();
        bond = bond_;
        farm = farm_;
        usdc = usdc_;
        vault = vault_;
        yieldRecipient = yieldRecipient_;
        mintReceiverImplementation = new MintAttemptReceiver(address(this), bond_, farm_, usdc_);
        // Standing approval so stake() can move bond units into the farm.
        bond_.setApprovalForAll(address(farm_), true);
    }

    // ── Yield routing config (owner = governance timelock) ───────────────────

    /// @dev Settles to the outgoing recipient before repointing, and **checkpoints whatever the
    ///      settlement could not deliver against that same recipient**. Rewards accrue continuously
    ///      inside the farm, so a bare repoint hands an epoch of already-earned
    ///      borrower/lender/insurance yield to the new address - and that is the *planned* Phase 3
    ///      handover, not just a malicious one.
    ///
    ///      **Audit round 22, finding 4, and the full argument is on `owedToRecipient`.** The drain
    ///      below is best-effort and therefore does nothing on exactly the condition this setter
    ///      exists for; without the park, the yield it failed to deliver simply sat here as free
    ///      balance until the next farm-touching call swept it to the incoming address. That call is
    ///      an ordinary `depositBonds` by any lender, so the redirection did not even need the owner
    ///      to make it happen twice.
    ///
    ///      **No precondition, deliberately, and no new failure mode.** The only branch below
    ///      decides whether a park *happened*: the pointer moves on every call, in every state, and
    ///      there is nothing here a stranger can flip to make it revert. Nor is the park a state
    ///      anyone can be stuck in - `flushYieldTo` is permissionless and takes its destination from
    ///      the mapping key. Both properties are lifted verbatim from
    ///      `EpochHarvester.setProtocolFeeWallet`, which reached them by having the two obvious
    ///      alternatives - drain first, or refuse while a backlog stands - fail on it first.
    function setYieldRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        address outgoing = yieldRecipient;
        if (outgoing != address(0) && recipient != outgoing) {
            // Best-effort, not mandatory. This is the designated escape from a
            // recipient that can no longer receive USDC - a Circle blacklist, a pause -
            // and an earlier version made the escape itself a hard `safeTransfer` to
            // that same address. It reverted on precisely the condition it existed to
            // fix, so the recipient could never be repointed and every dollar of farm
            // yield was trapped in an immutable contract, growing with each exit.
            //
            // `_trySweepUsdc` targets the *outgoing* recipient because the flip below
            // has not happened yet, and `unreportedYield` is cleared only when the
            // sweep actually moved the money it was tracking.
            try this.claimFarmRewards() {} catch {}
            if (_trySweepUsdc() != 0) unreportedYield = 0;

            // Read after the drain, exactly as `EpochHarvester.setLenderPool` reads its residue
            // after the delivery attempt: what is still free is precisely the part the outgoing
            // recipient could not take. Everything free here accrued while `outgoing` was wired -
            // anything owed to an earlier recipient was parked by its own repoint and is excluded
            // by `_freeBalance` - so the whole residue belongs to `outgoing`.
            //
            // The *whole* free balance, donations included, and that is not an oversight: the drain
            // it replaces sends the whole free balance too, so this parks exactly what the outgoing
            // recipient would have received had it been able to receive. A donation is a gift to the
            // recipient rather than yield owed to borrowers, which is what `_settleFarmPayout`
            // already says about the same dollars.
            uint256 stranded = _freeBalance();
            if (stranded != 0) {
                // The carried counter goes with the money. Left standing it is a claim on a balance
                // this contract can no longer forward, so the next successful sweep would report
                // the parked amount to the vault as freshly delivered yield - the same reasoning
                // that clears it on the successful branch above, for the opposite reason.
                unreportedYield = 0;
                owedToRecipient[outgoing] += stranded;
                totalOwedToRecipients += stranded;
                emit YieldParked(outgoing, stranded, totalOwedToRecipients);
            }
        }
        yieldRecipient = recipient;
        emit YieldRecipientSet(recipient);
    }

    /// @notice Deliver a parked balance to the recipient it was parked for. Permissionless.
    /// @dev The destination is the mapping key, never an argument, so this grants no authority over
    ///      the money - only the timing of a transfer that address was always owed. Exactly
    ///      `EpochHarvester.flushProtocolFeeTo`, which is the same shape one contract downstream.
    ///
    ///      **A hard `safeTransfer`, unlike the sweep.** The sweep is best-effort because a
    ///      collateral exit must never be blockable by a token; nothing waits on this call, and a
    ///      caller who explicitly asked for a flush wants to know it did not happen. Same split
    ///      `EpochHarvester` draws between `harvest` and its two `flush` functions.
    ///
    ///      State is written before the transfer, so a token with a callback cannot re-enter into a
    ///      second payment of the same balance. This contract has no reentrancy guard and does not
    ///      need one for that reason.
    function flushYieldTo(address recipient) external {
        uint256 amount = owedToRecipient[recipient];
        if (amount == 0) revert NothingToFlush();
        owedToRecipient[recipient] = 0;
        totalOwedToRecipients -= amount;
        emit YieldFlushed(recipient, amount);
        usdc.safeTransfer(recipient, amount);
    }

    /// @notice Pull pending farm rewards into this contract without forwarding them.
    /// @dev External only so `setYieldRecipient` can wrap it in try/catch - Solidity
    ///      has no try around an internal call. Self-call gated, so it is not a new
    ///      entry point. Exists because a farm that reverts must not block a repoint.
    function claimFarmRewards() external {
        if (msg.sender != address(this)) revert NotVault();
        farm.withdraw(0); // withdraw(0) = claim, verified on-chain behaviour
    }

    function setHarvester(address harvester_) external onlyOwner {
        if (harvester_ == address(0)) revert ZeroAddress();
        harvester = harvester_;
        emit HarvesterSet(harvester_);
    }

    /// @dev Renouncing would permanently freeze yield routing and the emergency hatch.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── ICustodyAdapter ──────────────────────────────────────────────────────

    /// @inheritdoc ICustodyAdapter
    function mintBonds(address beneficiary, bytes32 attemptId, bytes calldata mintData)
        external
        payable
        onlyVault
        returns (uint256 amount)
    {
        IDexFiBond.MintDataInput memory data = abi.decode(mintData, (IDexFiBond.MintDataInput));
        address receiver = _validateMintAttempt(beneficiary, attemptId, data);

        address deployed = Clones.cloneDeterministic(
            address(mintReceiverImplementation), _mintAttemptSalt(beneficiary, attemptId)
        );
        if (deployed != receiver) revert MintReceiverDeployMismatch(receiver, deployed);

        uint256 farmPaid = _mintAndConsolidate(receiver, data);
        _settleFarmPayout(farmPaid);

        amount = data.amountNfts;
        emit MintAttemptExecuted(beneficiary, attemptId, receiver, data.paymentAmount, amount);
    }

    /// @notice Counterfactual receiver used for one beneficiary's independent mint attempt.
    function predictMintReceiver(address beneficiary, bytes32 attemptId)
        public
        view
        returns (address receiver)
    {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (attemptId == bytes32(0)) revert InvalidAttemptId();
        receiver = Clones.predictDeterministicAddress(
            address(mintReceiverImplementation), _mintAttemptSalt(beneficiary, attemptId), address(this)
        );
    }

    /// @notice Retry a child clone's delivery of corroborated farm yield.
    /// @dev Permissionless because both the receiver and final yield destination are fixed.
    function flushMintAttemptYield(address beneficiary, bytes32 attemptId)
        external
        returns (uint256 swept)
    {
        address receiver = predictMintReceiver(beneficiary, attemptId);
        _requireMintReceiverCode(receiver);

        uint256 beforeBalance = usdc.balanceOf(address(this));
        uint256 reported = MintAttemptReceiver(payable(receiver)).flushFarmYield();
        uint256 received = usdc.balanceOf(address(this)) - beforeBalance;
        uint256 corroborated = reported < received ? reported : received;
        if (corroborated != 0) swept = _settleFarmPayout(corroborated);

        emit MintAttemptYieldFlushed(beneficiary, attemptId, receiver, corroborated, swept);
    }

    /// @notice Recover a front-run or donated counterfactual position without crediting a user.
    /// @dev Bonds pass through the whitelisted adapter and leave in the same transaction for the
    ///      explicit governance-chosen recipient. They are never pooled with credited collateral.
    function recoverMintAttempt(
        address beneficiary,
        bytes32 attemptId,
        address payable recoveryRecipient
    )
        external
        onlyOwner
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        address receiver = _prepareRecovery(beneficiary, attemptId);
        if (recoveryRecipient == address(0)) revert ZeroAddress();
        if (recoveryRecipient == address(this) || recoveryRecipient == receiver) {
            revert InvalidRecoveryRecipient(recoveryRecipient);
        }
        // **The preflight is conditional, and it used to be unconditional.** As written before,
        // it demanded the bond whitelist for every recovery, including one that never touches an
        // ERC-1155: a clone holding nothing but donated USDC or donated native could not be
        // emptied at all while DexFi had the adapter de-whitelisted. The money then sat at a
        // counterfactual address behind a third party's list, for a transfer that list does not
        // govern.
        //
        // **It keys on the STAKE as well as the loose bonds, and the loose-bond-only form of this
        // condition was considered and refused.** `MintAttemptReceiver.recoverAll` withdraws from
        // the farm FIRST and reads its own bond balance afterwards, so at preflight time a staked
        // clone reads zero loose bonds and still needs the bond path one call later. The clone is
        // never whitelisted, and the adapter as `to` is the only whitelisted party in the
        // clone-to-adapter handoff; a condition that looked only at loose bonds would therefore
        // skip this check and die inside DexFi's `_update` with an opaque error instead of this
        // named one.
        //
        // It is tight in the other direction too. A pending-only position is claimed with
        // `farm.withdraw(0)`, moves no bond at all, and correctly recovers while the adapter is
        // de-whitelisted - which is why `pendingShare` is deliberately not one of the terms.
        //
        // The flag is recomputed here rather than threaded out of `_prepareRecovery`, which
        // already reads both quantities. That saving was considered and refused: the condition is
        // written down as it stands so a later reader does not have to re-derive it from a
        // boolean's provenance, and bytes are not the binding constraint on this contract.
        (uint256 stakedAtReceiver,) = farm.userInfo(receiver);
        bool needsBondPath =
            stakedAtReceiver != 0 || bond.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID) != 0;
        if (needsBondPath && !bond.whitelistContains(address(this))) revert AdapterNotWhitelisted();

        RecoveryResult memory result = _recoverTo(receiver, recoveryRecipient);

        emit MintAttemptRecovered(
            beneficiary,
            attemptId,
            receiver,
            recoveryRecipient,
            result.bonds,
            result.farmForwarded,
            result.rawUsdcForwarded,
            result.rawUsdcRemaining,
            result.nativeForwarded,
            result.nativeRemaining,
            false
        );
        return (
            result.bonds,
            result.swept,
            result.rawUsdcForwarded,
            result.rawUsdcRemaining,
            result.nativeForwarded,
            result.nativeRemaining
        );
    }

    /// @notice Escape a broken farm while leaving bonds at the clone until the adapter whitelist
    ///         is restored and normal recovery can route them to an explicit recipient.
    function emergencyRecoverMintAttempt(address beneficiary, bytes32 attemptId)
        external
        onlyOwner
        returns (uint256, uint256, uint256, uint256)
    {
        address receiver = _prepareRecovery(beneficiary, attemptId);
        RecoveryResult memory result = _emergencyRecover(receiver);
        emit MintAttemptRecovered(
            beneficiary,
            attemptId,
            receiver,
            address(0),
            result.bonds,
            result.farmForwarded,
            0,
            result.rawUsdcRemaining,
            0,
            result.nativeRemaining,
            true
        );
        return (result.bonds, result.swept, result.rawUsdcRemaining, result.nativeRemaining);
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Measures any USDC the farm settles on deposit, then forwards it, mirroring
    ///      `unstake` exactly. MasterChef-style pools pay pending rewards on `deposit`
    ///      as well as `withdraw`; unmeasured, that money would later be swept out
    ///      without ever being counted as yield, and unswept it would sit here at rest
    ///      against this contract's stated design.
    ///
    ///      The sweep stays best-effort for the same reason it does on the way out: a
    ///      USDC pause or blacklist must never block a deposit. Un-swept USDC is
    ///      carried in `unreportedYield` and reported by the next successful claim.
    function stake(uint256 amount) external onlyVault returns (uint256 swept) {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.deposit(amount);
        swept = _settleFarmPayout(usdc.balanceOf(address(this)) - balBefore);
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Returns the USDC swept, which the vault must account for. The farm is
    ///      MasterChef-style, so `withdraw(amount)` settles the pending rewards of the
    ///      entire adapter position - which is every borrower's pooled yield, not just
    ///      the caller's. Reporting nothing meant any depositor could withdraw a single
    ///      bond unit and push a whole epoch's yield out through an unmeasured path,
    ///      leaving the accounted harvest at zero and nobody's debt written down.
    ///
    ///      The sweep stays best-effort: a USDC pause or blacklist must never brick a
    ///      collateral exit. Un-swept USDC stays claimable via claimYield.
    function unstake(uint256 amount) external onlyVault returns (uint256 swept) {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.withdraw(amount);
        // On a failed sweep (USDC paused, recipient blacklisted) the exit still
        // succeeds and the yield is carried to the next successful claim.
        swept = _settleFarmPayout(usdc.balanceOf(address(this)) - balBefore);
    }

    /// @inheritdoc ICustodyAdapter
    /// @dev Reports real farm yield - this claim's payout plus anything a previous
    ///      failed sweep or a deposit-time settlement left behind - while still
    ///      excluding donations, so neither problem is traded for the other. A
    ///      donation is transferred onward but never counted, because it is a gift to
    ///      the recipient rather than yield owed to borrowers and lenders.
    ///      Routes through the same best-effort settle as `stake` and `unstake`, so a
    ///      recipient that cannot receive carries the yield forward instead of
    ///      reverting. A hard transfer here meant a blacklisted recipient bricked
    ///      every epoch as well as trapping the money.
    function claimYield() external onlyClaimer returns (uint256 usdcAmount) {
        uint256 balBefore = usdc.balanceOf(address(this));
        farm.withdraw(0); // withdraw(0) = claim, verified on-chain behaviour
        usdcAmount = _settleFarmPayout(usdc.balanceOf(address(this)) - balBefore);
    }

    /// @inheritdoc ICustodyAdapter
    function transferBonds(address to, uint256 amount) external onlyVault {
        bond.safeTransferFrom(address(this), to, Config.DEXFI_BOND_TOKEN_ID, amount, "");
    }

    /// @inheritdoc ICustodyAdapter
    // slither-disable-next-line unused-return
    function stakedBalance() external view returns (uint256 staked) {
        (staked,) = farm.userInfo(address(this));
    }

    // ── Emergency (owner = governance timelock) ──────────────────────────────

    /// @notice Break-glass exit if the farm stops honouring withdraw(): pull all
    ///         bonds via the farm's reward-forfeiting escape hatch and hand them to
    ///         a governance-controlled address for redistribution.
    function emergencyUnstake(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        farm.emergencyWithdraw();
        uint256 bal = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        if (bal > 0) bond.safeTransferFrom(address(this), to, Config.DEXFI_BOND_TOKEN_ID, bal, "");
        emit EmergencyUnstaked(to, bal);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev The nine-check mint preflight, and what each check is worth. Audit round 34
    ///      measured this by deleting each check in turn and running
    ///      `MintAttemptReceiverTest`, so every backstop named below is an observed revert
    ///      selector rather than an argument. Eight of the nine reddened a test; the ninth,
    ///      `InvalidBeneficiary`, appeared nowhere in `test/` and now has one.
    ///
    ///      **Seven of the nine are backstopped only by DexFi's bond contract or by the
    ///      CREATE2 opcode.** DexFi's bond is owned by a single EOA and is treated
    ///      throughout this repo as mutable, so a backstop living over there is not a reason
    ///      to drop a check here - it is a dependency on somebody else's upgrade policy.
    ///      Only check 9 changes whether the transaction succeeds at all; the rest change
    ///      which error a user sees, how much gas they burn, and how far into DexFi the call
    ///      gets before it unwinds.
    ///
    ///      1. `InvalidBeneficiary` (raised in `predictMintReceiver`) - **UNREACHABLE on
    ///         this path.** `mintBonds` is `onlyVault` against an immutable `vault`, and
    ///         `CollateralVault.depositETH`'s single call site passes `msg.sender`, which
    ///         the EVM never sets to the zero address. Deleting it reddens nothing here. It
    ///         is load-bearing on `predictMintReceiver`, `flushMintAttemptYield` and both
    ///         recovery doors, where it closes the zero-beneficiary salt namespace - see
    ///         `test_zeroBeneficiaryIsRejectedOnEveryPathThatCanReachIt` for the trade that
    ///         closure makes.
    ///      2. `InvalidAttemptId` (raised in `predictMintReceiver`) - reachable and
    ///         unshadowed: a borrower can send `bytes32(0)` straight through `depositETH`.
    ///      3. `MintReceiverMismatch` - backstopped by `MintAmountMismatch`, because a mint
    ///         that landed anywhere else leaves this clone's bond delta at zero. Deleting it
    ///         still reverts, further in, with an error naming the wrong quantity.
    ///      4. `MintNonceMustBeZero` - backstopped by DexFi's own `InvalidNonce`. Rejects
    ///         before the clone is deployed and before any ETH leaves this contract. Note it
    ///         is a different quantity from check 6: this is the nonce the payload declares,
    ///         that is the nonce the receiver actually holds.
    ///      5. `ZeroMintAmount` - backstopped by `CollateralVault.NothingMinted`, which is
    ///         **in the caller, not here**. On its own this adapter would deploy a clone,
    ///         forward `msg.value` and consume a DexFi UUID for zero bonds, and only the
    ///         vault's post-check unwinds it. Any second caller of `mintBonds` without that
    ///         post-check would pay ETH for nothing.
    ///      6. `MintAttemptAlreadyUsed` - backstopped by DexFi's `UUIDAlreadyExist` on a
    ///         replayed payload, and by check 7 once the clone exists, but by **neither**
    ///         when a front-runner has consumed the receiver's nonce with a payload of their
    ///         own and no clone has been deployed. It is the guard that names the front-run
    ///         condition, which is what tells an operator to reach for `recoverMintAttempt`.
    ///      7. `MintAttemptAlreadyDeployed` - backstopped structurally, because CREATE2
    ///         cannot overwrite: `Clones.cloneDeterministic` reverts `FailedDeployment()`.
    ///         What this check buys is **gas**, and the ordinary user who needs it is one
    ///         retrying an attempt governance has already recovered. Measured as the gas
    ///         `forge` reports for
    ///         `test_pendingOnlyCounterfactualPositionIsClaimedWithWithdrawZero`: 345,939
    ///         with the check, 1,024,211,172 without it, because a create that collides
    ///         consumes every unit forwarded to it rather than returning them.
    ///      8. `AdapterNotWhitelisted` - backstopped by DexFi's `AddressesNotWhitelisted`
    ///         when the clone tries to hand the bonds over. Fails before the clone is
    ///         deployed, and names the PRD §14 ask #5 dependency rather than three raw
    ///         addresses. Distinct from the same guard in `recoverMintAttempt`, which is
    ///         separately reached and separately covered.
    ///      9. `PaymentMismatch` - **the only one whose deletion lets a transaction
    ///         succeed.** Underpayment is caught by DexFi and a zero payment by
    ///         `CollateralVault.ZeroAmount`, so overpayment is this check's entire job.
    ///         Measured with it deleted: 1.5 ETH against a 1.0 ETH signed payment credits
    ///         the same 40 bonds and strands 0.5 ETH at the bond contract, which forwards
    ///         only the signed amount and has no native rescue.
    function _validateMintAttempt(
        address beneficiary,
        bytes32 attemptId,
        IDexFiBond.MintDataInput memory data
    ) private view returns (address receiver) {
        receiver = predictMintReceiver(beneficiary, attemptId);
        if (data.receiver != receiver) revert MintReceiverMismatch(receiver, data.receiver);
        if (data.nonce != 0) revert MintNonceMustBeZero(data.nonce);
        if (data.amountNfts == 0) revert ZeroMintAmount();

        uint256 currentNonce = bond.nonces(receiver);
        if (currentNonce != 0) revert MintAttemptAlreadyUsed(receiver, currentNonce);
        if (receiver.code.length != 0) revert MintAttemptAlreadyDeployed(receiver);
        if (!bond.whitelistContains(address(this))) revert AdapterNotWhitelisted();

        // DexFi accepts `>=`, forwards only the signed payment, and has no native
        // rescue. Equality prevents an accidental overpayment from being burned.
        if (msg.value != data.paymentAmount) {
            revert PaymentMismatch(data.paymentAmount, msg.value);
        }
    }

    /// @dev Move one signed mint through its fresh child and consolidate the exact
    ///      signed amount under the adapter's existing pooled farm position.
    function _mintAndConsolidate(address receiver, IDexFiBond.MintDataInput memory data)
        private
        returns (uint256 farmPaid)
    {
        (MintSnapshot memory beforeMint, uint256 stakedDelta, uint256 autoDepositPaid) =
            _mintIntoReceiver(receiver, data);
        (uint256 childFarmPaid, uint256 adapterLooseBefore) = _releaseFromReceiver(
            receiver, data.amountNfts, stakedDelta, autoDepositPaid, beforeMint
        );
        farmPaid = childFarmPaid + _stakeReleasedMint(data.amountNfts, adapterLooseBefore);
    }

    function _mintIntoReceiver(address receiver, IDexFiBond.MintDataInput memory data)
        private
        returns (MintSnapshot memory beforeMint, uint256 stakedDelta, uint256 autoDepositPaid)
    {
        (beforeMint.childStake,) = farm.userInfo(receiver);
        beforeMint.childLoose = bond.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID);
        beforeMint.childUsdc = usdc.balanceOf(receiver);

        bond.mint{value: msg.value}(data);

        (uint256 childStakeAfter,) = farm.userInfo(receiver);
        uint256 childLooseAfter = bond.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID);
        stakedDelta = childStakeAfter - beforeMint.childStake;
        uint256 looseDelta = childLooseAfter - beforeMint.childLoose;
        uint256 minted = stakedDelta + looseDelta;
        if (minted != data.amountNfts) revert MintAmountMismatch(data.amountNfts, minted);

        autoDepositPaid = usdc.balanceOf(receiver) - beforeMint.childUsdc;
    }

    function _releaseFromReceiver(
        address receiver,
        uint256 amount,
        uint256 stakedDelta,
        uint256 autoDepositPaid,
        MintSnapshot memory beforeMint
    ) private returns (uint256 childFarmPaid, uint256 adapterLooseBefore) {
        adapterLooseBefore = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        uint256 adapterUsdcBefore = usdc.balanceOf(address(this));
        uint256 reported = MintAttemptReceiver(payable(receiver)).releaseMint(
            stakedDelta, amount, autoDepositPaid
        );
        uint256 received = usdc.balanceOf(address(this)) - adapterUsdcBefore;
        childFarmPaid = reported < received ? reported : received;

        _requireReceiverRestored(receiver, beforeMint);
        uint256 adapterLooseAfter = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        uint256 receivedBonds = adapterLooseAfter - adapterLooseBefore;
        if (receivedBonds != amount) revert MintAmountMismatch(amount, receivedBonds);
    }

    function _requireReceiverRestored(address receiver, MintSnapshot memory beforeMint) private view {
        (uint256 actualStake,) = farm.userInfo(receiver);
        uint256 actualLoose = bond.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID);
        if (actualStake != beforeMint.childStake || actualLoose != beforeMint.childLoose) {
            revert MintReceiverPositionMismatch(
                beforeMint.childStake, actualStake, beforeMint.childLoose, actualLoose
            );
        }

        uint256 expectedUsdc =
            beforeMint.childUsdc + MintAttemptReceiver(payable(receiver)).parkedFarmYield();
        uint256 actualUsdc = usdc.balanceOf(receiver);
        if (actualUsdc != expectedUsdc) revert MintReceiverUsdcMismatch(expectedUsdc, actualUsdc);
    }

    function _stakeReleasedMint(uint256 amount, uint256 adapterLooseBefore)
        private
        returns (uint256 farmPaid)
    {
        (uint256 stakeBefore,) = farm.userInfo(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));
        farm.deposit(amount);
        farmPaid = usdc.balanceOf(address(this)) - usdcBefore;

        (uint256 stakeAfter,) = farm.userInfo(address(this));
        uint256 looseAfter = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        if (stakeAfter != stakeBefore + amount || looseAfter != adapterLooseBefore) {
            revert AdapterPositionMismatch(
                stakeBefore + amount, stakeAfter, adapterLooseBefore, looseAfter
            );
        }
    }

    /// @dev **Reads its own balances after running recipient-chosen code, deliberately, and audit
    ///      round 34 measured what that costs.** Three windows hand control to `recoveryRecipient`
    ///      inside this call, not one: `recoverAll`'s raw-USDC leg, its `_tryForwardNative` raw
    ///      `call`, and - later than both - the ERC-1155 acceptance hook on the
    ///      `bond.safeTransferFrom` below, which fires *after* the bond equality check and *before*
    ///      the USDC subtraction. The owner names that address; the code at it is not the owner's,
    ///      and there is no `ReentrancyGuard` anywhere in this contract, so the permissionless
    ///      `flushYieldTo` and `flushMintAttemptYield` are re-enterable from all three.
    ///
    ///      **Neither value read can be inflated, and that part is checked rather than argued.**
    ///      Bonds are compared for *equality* against the clone's own report, so a donation into
    ///      this contract mid-call reverts instead of over-crediting - MEASURED: one bond unit
    ///      donated from the recipient produced `MintAmountMismatch(5, 6)`. Farm USDC is
    ///      `min(reportedFarm, received)`, so a donation cannot lift it above what the clone said
    ///      it sent - MEASURED: 500.000000 donated against 12.000000 reported still credited
    ///      12.000000.
    ///
    ///      **The checked subtraction below is not the mitigation, it is the exposure.**
    ///      `flushYieldTo` is permissionless and moves USDC *out* of this contract. Re-entered from
    ///      any of the three windows it drops the balance under `usdcBefore` and panics the whole
    ///      recovery, so a recovery recipient can block its own recovery - the precise outcome
    ///      `_tryForwardNative` was made best-effort to prevent. MEASURED at round 34 from both the
    ///      native leg and the ERC-1155 hook, the second with the clone holding no native balance
    ///      at all. Bounded rather than permanent: the park is finite, and the owner can flush it
    ///      first or name a different recipient. **Do not "fix" this by saturating the
    ///      subtraction** - that hides the drain instead of refusing it, and the read is then the
    ///      thing that is wrong.
    ///
    ///      **What is silently wrong is the reporting, and it under-counts.** Re-entering
    ///      `flushMintAttemptYield` for a *different* clone carrying parked yield makes the inner
    ///      `_settleFarmPayout` sweep this contract's whole free balance - including the farm USDC
    ///      this call has already received and not yet measured. MEASURED: 48.000000 reached
    ///      `yieldRecipient`, `farmYieldDelivered` recorded 7.000000, and both this function's
    ///      `swept` and `MintAttemptRecovered.farmYieldForwarded` reported 0 for the 41.000000 that
    ///      actually left. No money is lost - it goes to the destination it was always going to -
    ///      and under-counting that watermark is the safe direction, which is why this is recorded
    ///      rather than guarded. The **event** is the part a consumer can act wrongly on.
    function _recoverTo(address receiver, address payable recoveryRecipient)
        private
        returns (RecoveryResult memory result)
    {
        uint256 bondBefore = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 reportedBonds;
        uint256 reportedFarm;
        (
            reportedBonds,
            reportedFarm,
            result.rawUsdcForwarded,
            result.rawUsdcRemaining,
            result.nativeForwarded,
            result.nativeRemaining
        ) = MintAttemptReceiver(payable(receiver)).recoverAll(recoveryRecipient);

        result.bonds = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID) - bondBefore;
        if (result.bonds != reportedBonds) {
            revert MintAmountMismatch(reportedBonds, result.bonds);
        }
        if (result.bonds != 0) {
            bond.safeTransferFrom(
                address(this), recoveryRecipient, Config.DEXFI_BOND_TOKEN_ID, result.bonds, ""
            );
        }

        uint256 received = usdc.balanceOf(address(this)) - usdcBefore;
        result.farmForwarded = reportedFarm < received ? reportedFarm : received;
        if (result.farmForwarded != 0) {
            result.swept = _settleFarmPayout(result.farmForwarded);
        }
    }

    function _emergencyRecover(address receiver)
        private
        returns (RecoveryResult memory result)
    {
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 reportedFarm;
        (result.bonds, reportedFarm, result.rawUsdcRemaining, result.nativeRemaining) =
            MintAttemptReceiver(payable(receiver)).emergencyRecoverAll();

        uint256 received = usdc.balanceOf(address(this)) - usdcBefore;
        result.farmForwarded = reportedFarm < received ? reportedFarm : received;
        if (result.farmForwarded != 0) {
            result.swept = _settleFarmPayout(result.farmForwarded);
        }
    }

    function _prepareRecovery(address beneficiary, bytes32 attemptId)
        private
        returns (address receiver)
    {
        receiver = predictMintReceiver(beneficiary, attemptId);
        (uint256 staked,) = farm.userInfo(receiver);
        if (
            staked == 0 && farm.pendingShare(receiver) == 0
                && bond.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID) == 0
                && usdc.balanceOf(receiver) == 0 && receiver.balance == 0
        ) revert NothingToRecover(receiver);

        if (receiver.code.length == 0) {
            address deployed = Clones.cloneDeterministic(
                address(mintReceiverImplementation), _mintAttemptSalt(beneficiary, attemptId)
            );
            if (deployed != receiver) revert MintReceiverDeployMismatch(receiver, deployed);
        } else {
            _requireMintReceiverCode(receiver);
        }
    }

    function _requireMintReceiverCode(address receiver) private view {
        bytes32 expected = _mintReceiverRuntimeCodeHash();
        bytes32 actual = receiver.codehash;
        if (receiver.code.length == 0 || actual != expected) {
            revert InvalidMintReceiverCode(receiver, actual, expected);
        }
    }

    function _mintReceiverRuntimeCodeHash() private view returns (bytes32) {
        // Exact 45-byte ERC-1167 runtime emitted by OpenZeppelin Clones.
        return keccak256(
            abi.encodePacked(
                hex"363d3d373d3d3d363d73",
                bytes20(address(mintReceiverImplementation)),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
    }

    function _mintAttemptSalt(address beneficiary, bytes32 attemptId)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(MINT_ATTEMPT_DOMAIN, beneficiary, attemptId));
    }

    /// @dev What every farm interaction does with the USDC it shook loose: forward it
    ///      and report it, or - if the transfer cannot go through - carry it in
    ///      `unreportedYield` so the next successful claim picks it up.
    ///
    ///      Shared by every path that touches the farm, because a MasterChef-style pool
    ///      settles the pending rewards of the entire adapter position on any call that
    ///      moves its stake - so each of them can shake USDC loose whether or not that
    ///      was its purpose. Having it in one place is what stops a new farm-touching
    ///      path quietly reintroducing the leak.
    ///
    ///      The callers are named rather than counted, because a count written here goes
    ///      stale silently the next time a path is added and a symbol does not: `stake`,
    ///      `unstake`, `claimYield`, `mintBonds`, `flushMintAttemptYield`, `_recoverTo`
    ///      and `_emergencyRecover`. The two prose counts that stood here said three and
    ///      four while the tree had seven, which audit round 31 filed and which is why this
    ///      paragraph no longer carries a number.
    /// @param farmPaid USDC measured as arriving from the farm during the call.
    /// @return swept Total forwarded onward, including any previously carried amount.
    ///         Zero when the sweep could not go through.
    function _settleFarmPayout(uint256 farmPaid) private returns (uint256 swept) {
        if (_trySweepUsdc() == 0) {
            unreportedYield += farmPaid;
            return 0;
        }
        swept = farmPaid + unreportedYield;
        unreportedYield = 0;
        // Counted here rather than at each caller, for the same reason the sweep itself lives
        // here: this is the one funnel every farm-touching path goes through, so a NEW path
        // cannot deliver farm yield without also corroborating the epoch that pays it out.
        // That is what stops a new path quietly reintroducing round 11's finding, the same way
        // this helper stops one reintroducing the leak it was factored out to close.
        //
        // Counted on the swept branch only, and never on the failed one. A sweep that did not go
        // through has delivered nothing to the harvester yet, so counting it there would let the
        // harvester rate an epoch against money it has not received; `unreportedYield` carries the
        // amount instead and the next successful sweep counts it exactly once.
        //
        // **A parked balance is never counted here, and `flushYieldTo` does not count it either.**
        // Audit round 22 measured this counter recording as delivered a 1,000.000000 epoch that the
        // recipient never received, so under-counting is the direction to be wrong in. The cost of
        // never counting it is bounded and small: `EpochHarvester` needs only
        // `Config.MIN_EPOCH_FARM_YIELD` - one dollar - of subsequent farm delivery before an epoch
        // that includes the flushed money can run, and the fund pays hundreds of dollars a week.
        // Counting it at the flush instead would let a donation move this number, which is the one
        // property round 11 built it for.
        farmYieldDelivered += swept;
    }

    /// @dev Best-effort USDC sweep that never reverts the calling transaction.
    /// @return swept The amount that actually left, so the caller can account for it.
    ///         Zero when the transfer failed, which is the case the whole low-level
    ///         call exists to tolerate.
    function _trySweepUsdc() internal returns (uint256 swept) {
        uint256 amount = _freeBalance();
        if (amount == 0) return 0;
        // Low-level call so a reverting transfer (pause/blacklist) cannot brick exits.
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = address(usdc).call(abi.encodeCall(IERC20.transfer, (yieldRecipient, amount)));
        // Not ignored any more: exits still succeed either way, but the amount has to
        // be reported or it leaves the protocol's accounting silently.
        //
        // **Measured, not inferred.** `ok` says only that the call did not revert. The
        // return value is discarded, so a token that returns `false` without reverting
        // satisfies it while moving nothing - and this figure feeds `farmYieldDelivered`,
        // the harvester's corroboration watermark, so an over-report there rates an epoch
        // against money that never arrived. This is the one raw token call in a repo that
        // uses `SafeERC20` everywhere else, which is why it was worth checking.
        //
        // The balance delta is used rather than decoding the return value, because it is
        // right for both failure shapes - a `false` return and a partial transfer - and
        // because measuring rather than trusting an external call is already the rule in
        // four other places here.
        // The *free* balance on both sides of the transfer, not the raw one. `totalOwedToRecipients`
        // cannot move inside this call, so the delta is identical either way - but reading the raw
        // balance here beside a free-balance `amount` above would be two different quantities in one
        // subtraction, which is one refactor away from a wrong number.
        uint256 remaining = _freeBalance();
        swept = ok && amount > remaining ? amount - remaining : 0;
    }

    /// @dev This contract's USDC less what is parked for a former recipient. Every path that moves
    ///      USDC out of here reads this rather than `balanceOf`, so a park cannot be swept onward.
    ///      `flushYieldTo` is the single exception and is the function that pays the park down.
    ///
    ///      Saturating rather than a bare subtraction. The two counters move together on every write
    ///      and the park can only ever be a subset of the balance, so this can only underflow if the
    ///      token itself takes money out of this contract - and an underflow here would revert
    ///      `stake`, `unstake` and `mintBonds` alike, which is to say every collateral path. The
    ///      whole point of the sweep being best-effort is that a token must never be able to do that.
    function _freeBalance() private view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 owed = totalOwedToRecipients;
        return balance > owed ? balance - owed : 0;
    }
}
