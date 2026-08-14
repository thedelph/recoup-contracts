// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LenderPool (skeleton - PRD §4.2)
/// @notice ERC-4626 vault over native USDC. Lends to CreditManager only. Share
///         price rises with the lender share of harvested yield; shortfalls after
///         auction + insurance fund are socialised via share price - this must be
///         prominent in lender docs.
/// @dev Not `is ILenderPool` while stubbed; the queue + lending functions land in
///      phase 4 and the interface conformance test comes with them.
///
///      This line used to call that "avoiding interface/event inheritance friction",
///      and the friction it avoided was the compiler doing its job: with the two only
///      related by intention, `YieldDistributed` drifted to a different signature in
///      the implementation and nobody found out until an internal audit round. The
///      Phase-4 contract declares `is ILenderPool` for exactly that reason. Until it
///      lands, the event signatures below are held to the interface by hand.
///      TODO(phase-4): FIFO withdrawal queue (withdraw/redeem overrides honouring
///      hot float), reserveRatio management, loss socialisation.
contract LenderPool is ERC4626, Ownable, ReentrancyGuard {
    error NotImplemented();
    error NotCreditManager();
    error NotEpochHarvester();
    error ZeroAddress();
    error RenounceDisabled();

    event Lent(uint256 amount);
    event PrincipalRepaid(uint256 amount);
    /// @dev Three parameters, matching `ILenderPool` and the Phase-4 implementation. See the
    ///      interface for what the extra two carry and why this line was wrong.
    event YieldDistributed(uint256 amount, uint256 ratePerSecond, uint256 streamEndsAt);
    event LossSocialised(uint256 amount);
    event WithdrawalQueued(address indexed lender, uint256 indexed queueIndex, uint256 assets);
    event QueuedWithdrawalServiced(address indexed lender, uint256 indexed queueIndex, uint256 assets);

    address public creditManager;
    address public epochHarvester;

    /// @notice USDC currently lent out, carried at face value less socialised loss
    ///         (debts are written down by yield, not defaulted - PRD §4.2).
    /// @dev Zero until lend() lands (phase 4); the zero default is the correct value.
    // slither-disable-next-line uninitialized-state
    uint256 public outstandingPrincipal;

    constructor(IERC20 usdc_, address initialOwner)
        ERC20("Recoup Lender Pool", "rcUSDC")
        ERC4626(usdc_)
        Ownable(initialOwner)
    {
        if (address(usdc_) == address(0)) revert ZeroAddress();
    }

    /// @dev Matches the live-authority contracts: renouncing would permanently
    ///      freeze wiring on a contract the deploy script already deploys.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ── Wiring (owner, behind timelock in production) ────────────────────────

    function setCreditManager(address creditManager_) external onlyOwner {
        if (creditManager_ == address(0)) revert ZeroAddress();
        creditManager = creditManager_;
    }

    function setEpochHarvester(address epochHarvester_) external onlyOwner {
        if (epochHarvester_ == address(0)) revert ZeroAddress();
        epochHarvester = epochHarvester_;
    }

    // ── Entry (closed until phase 4) ─────────────────────────────────────────

    /// @dev The skeleton stubbed the functions it declared - `lend`, `repayPrincipal`,
    ///      `distributeYield`, `socialiseLoss` - but `deposit`, `mint`, `withdraw` and
    ///      `redeem` come from ERC4626 and were live from the moment this contract was
    ///      deployed. That let anyone commit real USDC to a vault that cannot lend it,
    ///      cannot distribute yield, and has no withdrawal queue. Returning zero here
    ///      makes `deposit`/`mint` revert with ERC4626's own max-exceeded errors.
    ///      Withdrawals stay open so anyone who deposited before this can still exit.
    ///      Remove both overrides when the phase-4 queue and loss accounting land.
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    // ── Accounting ───────────────────────────────────────────────────────────

    /// @notice idle USDC + outstanding principal (PRD §4.2)
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + outstandingPrincipal;
    }

    // ── Pool ↔ protocol flows ────────────────────────────────────────────────

    function lend(uint256) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        revert NotImplemented(); // TODO(phase-4)
    }

    function repayPrincipal(uint256) external nonReentrant {
        if (msg.sender != creditManager) revert NotCreditManager();
        revert NotImplemented(); // TODO(phase-4)
    }

    function distributeYield(uint256) external nonReentrant {
        if (msg.sender != epochHarvester) revert NotEpochHarvester();
        revert NotImplemented(); // TODO(phase-4)
    }

    function socialiseLoss(uint256) external {
        revert NotImplemented(); // TODO(phase-4): CreditManager only; emit loudly
    }

    function queuePosition(address) external view returns (uint256, uint256) {
        revert NotImplemented(); // TODO(phase-4)
    }

    // ── The impairment surface, answered rather than stubbed ─────────────────
    //
    // `CreditManager.setLenderPool` probes `impairedBorrowerCount()` and refuses a pool that
    // cannot answer, and it reads the outgoing pool's `totalImpairment()` to refuse stranding a
    // mark. Both were added by an internal audit round after the phase-4 pool was written, and a
    // skeleton that reverts on them is a skeleton the deploy script cannot wire at all.
    //
    // Zero is not a placeholder here, it is the truth: this contract has no way to be impaired.
    // Nothing can lend from it, so nothing can be marked against it, and the guards above are
    // asking a question whose answer for a dormant pool is genuinely none. `impairedBorrowerAt`
    // gets no body for the same reason - there is no index 0 to return, and the manager's walk
    // never reaches it while the count is zero.
    //
    // These stay when the phase-4 pool lands; there they carry the real set.

    function totalImpairment() external pure returns (uint256) {
        return 0;
    }

    function impairedBorrowerCount() external pure returns (uint256) {
        return 0;
    }
}
