// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A lender pool that can be switched between accepting and refusing losses,
///         and that can fund the loan those losses come out of.
/// @dev "The pool refuses" is not an edge case to imagine. Until 2026-08-10 the real
///      `LenderPool.socialiseLoss` reverted `NotImplemented` and the deploy script wired
///      exactly that pool, so refusal was the only state that existed. The pool has a real
///      body now, but it still refuses a caller it does not recognise as its
///      `creditManager` and a zero amount, and a design that cannot survive refusal cannot
///      complete a single liquidation.
///
///      The flag exists so both halves can be exercised in one test. Asserting "the
///      write-down survives a refusing pool" and "the flush delivers to an accepting
///      pool" in separate tests is the pair that passes forever in isolation while the
///      two states are mutually unreachable.
contract MockLenderPool {
    IERC20 public immutable usdc;

    bool public accepting;
    uint256 public socialisedTotal;
    /// @notice Accepted calls to `socialiseLoss`, and only accepted ones.
    /// @dev Not a call count, despite the name it has always had. The increment happens inside
    ///      the same call that reverts when the pool is refusing, so it is rolled back with
    ///      everything else and a refusal leaves no trace here at all. A test that wants to prove
    ///      the pool was *asked* has to say so from outside, with `vm.expectCall`.
    uint256 public calls;
    /// @notice Principal this pool has out on loan. Book-keeping only, as on the real source.
    uint256 public outstandingPrincipal;

    error PoolRefuses();

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    /// @notice Cap on what a single call will absorb. 0 = absorb everything asked.
    /// @dev The third state, and the reason round 10 found what it found. This mock only ever
    ///      reverted or absorbed in full, so every CreditManager test asserting `unsocialisedLoss`
    ///      was measuring a pool that no deployment can produce - the real one clamps to what it
    ///      has lent and returns quietly. A mock that cannot express partial acceptance cannot
    ///      catch a caller that assumes acceptance is total.
    uint256 public absorbCap;

    function setAccepting(bool value) external {
        accepting = value;
    }

    function setAbsorbCap(uint256 cap) external {
        absorbCap = cap;
    }

    function socialiseLoss(uint256 amount) external returns (uint256 absorbed) {
        calls++;
        if (!accepting) revert PoolRefuses();
        absorbed = (absorbCap != 0 && amount > absorbCap) ? absorbCap : amount;
        socialisedTotal += absorbed;
        outstandingPrincipal = absorbed > outstandingPrincipal ? 0 : outstandingPrincipal - absorbed;
    }

    /// @notice Money coming back on a loss this pool already took. Audit round 21, finding 14.
    /// @dev Kept in step with `socialiseLoss` above deliberately: `CreditManager` picks between
    ///      the two destinations for a recovery with the same test `_socialise` uses on the way
    ///      down, so a mock that could absorb a loss but not receive its recovery would make the
    ///      pool branch of that dispatch untestable and the treasury branch look total.
    ///      **`outstandingPrincipal` does not move**, matching the real pool: there is no loan to
    ///      re-recognise, the money is a gain on one already written off.
    uint256 public recoveredTotal;

    function recoverLoss(uint256 amount) external {
        if (!accepting) revert PoolRefuses();
        recoveredTotal += amount;
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    // ── ILiquiditySource ─────────────────────────────────────────────────────

    /// @dev Audit round 11 is why a *loss sink* mock now also has to be able to *fund a loan*.
    ///      `CreditManager._socialise` offers a loss only to a pool that is also the liquidity
    ///      source, because a balance sheet that lent nothing cannot be charged for a default -
    ///      the treasury bears its own by simply never being repaid, and recording that same
    ///      loss against the pool as well was the double count the round's PoC monetised.
    ///
    ///      So a mock that could only absorb losses could only ever reach the *other* branch.
    ///      Any test about deferral, partial absorption or the flush has to put this pool on
    ///      both sides of "whose money was it", and until now it had no way to be on the
    ///      funding side at all.
    ///
    ///      `lend` pays, and `repayPrincipal` pulls, from `msg.sender` rather than from a stored
    ///      `creditManager` pointer. The real sources gate on that pointer and then use it as
    ///      the counterparty, so the two are the same address by construction; here it saves
    ///      every fixture a wiring call it would otherwise be free to forget, and a forgotten
    ///      one fails as a confusing transfer revert rather than as a clear `NotCreditManager`.
    function lend(uint256 amount) external {
        outstandingPrincipal += amount;
        usdc.transfer(msg.sender, amount);
    }

    /// @dev Clamped, not subtracted, for the reason the real pool documents: yield can exceed
    ///      principal and a socialised loss has already written this counter down for money that
    ///      is never coming back, so a repayment can legitimately be larger than what is still
    ///      recorded as out on loan.
    function repayPrincipal(uint256 amount) external {
        outstandingPrincipal = amount > outstandingPrincipal ? 0 : outstandingPrincipal - amount;
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    function available() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ── the impairment surface ───────────────────────────────────────────────

    /// @dev Added for audit round 16. `CreditManager.setLenderPool` now refuses while the outgoing
    ///      pool still carries a mark, and until this existed the mock had no way to be in that
    ///      state at all - so the guard could only have been tested against the real pool, which
    ///      cannot be put into the stranded state without also arming the clauses beside it.
    mapping(address => uint256) public impairmentOf;
    uint256 public totalImpairment;

    address[] private _impaired;
    mapping(address => uint256) private _impairedIndexPlusOne;

    /// @notice Stage a mark directly, without going through the manager.
    /// @dev The stranded state is reached by a *dropped* notification - `_setImpairment` wraps both
    ///      pool calls in `try`/`catch` precisely so a refusing pool cannot brick an exit - so a
    ///      mark that the manager believes it cleared is a reachable production state and not a
    ///      convenience for this test.
    /// @dev **The removal half was missing until audit round 17, and it is the half that matters.**
    ///      This tracked additions and never removals, so the set could only ever grow - and a set
    ///      that cannot shrink cannot express the one thing the manager's downward walk exists to
    ///      survive, which is the real pool's swap-pop during a release. The interaction was
    ///      untested everywhere in the repo: the only real-pool exercise of `refreshImpairments`
    ///      runs a one-element set, where `LenderPool._untrackImpaired`'s `index != last` branch is
    ///      unreachable.
    ///
    ///      Mirrors the real pool exactly, swap-pop included, because a mock that removes in a
    ///      different order would test a walk the production contract never performs.
    /// @return wrote Whether the stored mark actually moved, mirroring the real pool's return.
    ///         **This has to mirror it, not merely compile against it.** A mock that always answered
    ///         `true` would leave the silent-no-op branch unreachable from the suite, which is
    ///         exactly how audit round 19's `refreshImpairments` defect survived round 17's fix -
    ///         and the same shape as `MockUSDC` being unable to fail silently until round 18 taught
    ///         it how.
    function setImpairment(address borrower, uint256 amount) external returns (bool wrote) {
        uint256 previous = impairmentOf[borrower];
        if (amount == previous) return false;
        wrote = true;
        impairmentOf[borrower] = amount;
        totalImpairment = totalImpairment + amount - previous;
        if (previous == 0 && amount != 0) {
            _impairedIndexPlusOne[borrower] = _impaired.length + 1;
            _impaired.push(borrower);
        } else if (amount == 0) {
            uint256 indexPlusOne = _impairedIndexPlusOne[borrower];
            // The map was already written above, so this is a real write however the set ends up.
            if (indexPlusOne == 0) return wrote;
            uint256 index = indexPlusOne - 1;
            uint256 last = _impaired.length - 1;
            if (index != last) {
                address moved = _impaired[last];
                _impaired[index] = moved;
                _impairedIndexPlusOne[moved] = index + 1;
            }
            _impaired.pop();
            delete _impairedIndexPlusOne[borrower];
        }
    }

    function impair(address borrower, uint256 amount) external returns (bool wrote) {
        return this.setImpairment(borrower, amount);
    }

    function releaseImpairment(address borrower) external returns (bool wrote) {
        return this.setImpairment(borrower, 0);
    }

    function impairedBorrowerCount() external view returns (uint256) {
        return _impaired.length;
    }

    function impairedBorrowerAt(uint256 index) external view returns (address) {
        return _impaired[index];
    }

    /// @dev Clamped to `outstandingPrincipal` exactly as the real pool clamps it, because the
    ///      finding is that this reads **zero** in the state that matters. A mock that reported the
    ///      raw mark here would make the new guard look unnecessary.
    function exitReserve() external view returns (uint256) {
        return totalImpairment > outstandingPrincipal ? outstandingPrincipal : totalImpairment;
    }

    function setLossReserves(uint256, uint256) external {}
}
