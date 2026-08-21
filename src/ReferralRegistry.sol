// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Config} from "./Config.sol";

/// @title ReferralRegistry
/// @notice Records two facts and nothing else: **who owns a referral code**, and **which code an
///         account bound to**. It never holds value, never moves value, and never lets either
///         fact change once written.
///
/// @dev **Why this contract is so small.** Reward rates, the reward windows, the outflow cap and
///      the minimum thresholds are all applied by an off-chain calculator that reads these events
///      alongside the harvester's and the credit manager's, and paid by a separate cumulative
///      Merkle distributor. That split is the point: every parameter of the programme can be
///      retuned without touching a deployed contract, and anyone can re-run the calculation and
///      check the payouts, exactly as they can re-run the NAV methodology.
///
///      The property the calculator rests on is that **attribution resolves identically at every
///      future block**. Both mappings are write-once, there is no owner, and there is no function
///      that can move a code or a binding.
///
///      **Zero coupling.** No protocol contract reads this, and this reads no protocol contract.
///      It is deliberately absent from the main protocol deploy: the supported fix for a core
///      defect before launch is redeploying the set, and a registry inside that deploy would take
///      a new address each time and orphan every existing binding permanently. Its lifecycle has
///      to outlive the protocol's.
///
///      **No owner, and that is a decision.** There is no value to rescue, no parameter to tune
///      and no pointer to repoint, so an owner would be a key that can do nothing useful. More to
///      the point, an owner power here would be a power over *who gets paid*, which is the one
///      thing this contract exists to put beyond anyone's reach. A pause would be worse than
///      useless: it cannot un-squat a code, and pausing `bind` would silently cost referrers
///      attribution they can never re-acquire, because binding is once-only and those users do not
///      come back to redo it. Do not add either.
///
/// @dev **What an integrator must know, because it is not enforced here.**
///      1. **Filter logs by this contract's address.** The events below are the payout table's
///         only source, and any contract can emit byte-identical topics. The address filter is the
///         entire authenticity guarantee.
///      2. **Join against the credit manager's `Borrowed` event.** This contract records *that* an
///         account bound and *when*, but nothing about whether they had already borrowed. The
///         programme only pays where the bind precedes the referee's first qualifying borrow, and
///         that test is not expressible here. Without the join, every pre-existing borrower can
///         bind on launch day and divert the full programme budget on a book nobody referred.
///      3. **Ignore codes owned by `NON_BINDABLE`.** They are brand protection, not payees.
contract ReferralRegistry {
    // ── Errors ───────────────────────────────────────────────────────────────

    /// @dev Carries the code so a frontend can echo back what was rejected.
    error MalformedCode(bytes32 code);
    /// @dev Carries the incumbent so a frontend can say who holds it.
    error CodeTaken(bytes32 code, address owner);
    error CodeNotRegistered(bytes32 code);
    /// @dev Carries the existing binding, which is the only thing a caller can do about it.
    error AlreadyBound(bytes32 code);
    error SelfReferral();
    error CodeNotBindable(bytes32 code);
    error ZeroAddress();

    // ── Events ───────────────────────────────────────────────────────────────

    /// @dev Every field indexed. These logs *are* the product: the calculator's queries are
    ///      "codes owned by X", "referees of X" and "who is Y bound to", one topic each.
    ///      `referrer` is denormalised into `Bound` so the payout table needs no join *within this
    ///      contract* - it still needs the two joins named in the integrator note above.
    event CodeRegistered(bytes32 indexed code, address indexed referrer);
    event Bound(address indexed referee, bytes32 indexed code, address indexed referrer);

    // ── Constants ────────────────────────────────────────────────────────────

    /// @notice Owner of the reserved brand codes. Nobody holds the key, and `bind` refuses any
    ///         code owned by it.
    /// @dev Reserved codes exist so that nobody can publish a link that reads as official. That
    ///      makes them exactly the strings an unreferred user guesses - `OFFICIAL`, `RECOUP`,
    ///      `SUPPORT` - and a binding is one-shot and permanent. If they were owned by a normal
    ///      address, anyone could publish `/r/OFFICIAL`, and every borrower who followed it would
    ///      permanently burn their single lifetime binding on a relationship that pays nobody,
    ///      locking out the real referrer who introduced them. Parking them here means such an
    ///      attempt reverts with a name the frontend can explain instead of silently succeeding.
    ///
    ///      Deliberately an unspendable constant rather than the deployer: code ownership is
    ///      permanent and has no rotation path, so seeding brand codes to the deploy key would
    ///      weld them to a key that is meant to be retired at go-live, outside any handover.
    address public constant NON_BINDABLE = address(uint160(uint256(keccak256("recoup.referral.nonBindable"))));

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice Code to the account that claimed it. Write-once; `address(0)` means unclaimed.
    mapping(bytes32 code => address referrer) public referrerOf;

    /// @notice Referee to the code they bound to. Write-once; `bytes32(0)` means unbound.
    /// @dev Only the code is stored, not the resolved referrer, because the two carry identical
    ///      information: `referrerOf` is write-once and there is no transfer function, so
    ///      `referrerOf[boundCode[x]]` can never change under a bound referee.
    mapping(address referee => bytes32 code) public boundCode;

    // ── Construction ─────────────────────────────────────────────────────────

    /// @notice Deploys the registry and claims `reservedCodes` for `NON_BINDABLE`, atomically.
    ///
    /// @dev **Seeding lives in the constructor because it has to be one transaction.** The first
    ///      version of the deploy script called `register` in a loop inside a broadcast block and
    ///      claimed that "closes the window entirely: no adversary can race an address nobody has
    ///      seen yet". That was wrong twice over. A broadcast emits **one transaction per external
    ///      call**, so the real sequence was: transaction 1 creates a live registry whose
    ///      `register` is open to everyone, then N more transactions try to claim the brand codes.
    ///      And the address is not unseen - a `CREATE` address is `keccak256(rlp([deployer,
    ///      nonce]))`, derivable from a known deployer before the deploy transaction is even sent.
    ///      Anything a squatter landed in that gap would be permanent, because there is no owner
    ///      and no transfer.
    ///
    ///      In a constructor there is no gap: the codes are claimed in the same transaction that
    ///      creates the address, and any failure reverts the whole deployment instead of leaving a
    ///      live half-seeded registry on a namespace that can only be claimed once.
    constructor(bytes32[] memory reservedCodes) {
        for (uint256 i; i < reservedCodes.length; ++i) {
            bytes32 code = reservedCodes[i];
            if (!isCanonical(code)) revert MalformedCode(code);
            // Catches a duplicate in the list, which would otherwise re-emit and put two
            // registrations of one code into the log the calculator reads.
            address incumbent = referrerOf[code];
            if (incumbent != address(0)) revert CodeTaken(code, incumbent);

            referrerOf[code] = NON_BINDABLE;
            emit CodeRegistered(code, NON_BINDABLE);
        }
    }

    // ── Registration ─────────────────────────────────────────────────────────

    /// @notice Claim an unused code for yourself.
    function register(bytes32 code) external {
        _register(code, msg.sender);
    }

    /// @notice Claim an unused code **for someone else**, who becomes its owner and payee.
    /// @dev Originally intended to claim a partner code during deployment, but the deploy script
    ///      cannot make that atomic: broadcast mode emits one transaction per external call. The
    ///      permissionless form also lets a stranger weld an unused code to an unspendable payee,
    ///      permanently burning every referee's one-shot binding. This broader round-13 finding is
    ///      open. Do not use this function for partner onboarding or deploy this source while the
    ///      design is unresolved; deletion is the recorded recommendation unless onboarding a
    ///      partner without their own transaction becomes a firm requirement.
    function registerFor(bytes32 code, address owner) external {
        if (owner == address(0)) revert ZeroAddress();
        // **Audit round 12.** `NON_BINDABLE` is the constructor's tombstone: it means "reserved by
        // Recoup, permanently unbindable", and `bind` treats it as a refusal that can never be
        // lifted. `register` cannot mint it, because it can only ever write `msg.sender`. This
        // function could, and one call was enough to brick any advertised-but-unclaimed code
        // forever - write-once mappings, no owner, no transfer, so no recovery at any price - while
        // emitting an event byte-identical to genuine brand protection, which the payout calculator
        // is told to skip. Two writers of the same mapping, only one of them constrained.
        if (owner == NON_BINDABLE) revert CodeNotBindable(code);
        _register(code, owner);
    }

    /// @dev One account may hold many codes, deliberately: partner integrations want a code per
    ///      channel to measure with, and a one-code-per-referrer rule would be defeated by a
    ///      second address for free.
    ///
    ///      **Front-running is accepted, and the earlier reasoning for accepting it was wrong.**
    ///      The original note here said a squatted code "earns nothing" because "a code with no
    ///      bindings pays nothing". That is true only of a code nobody has heard of. It is false
    ///      for a code that has been **advertised but not yet claimed**, which inherits the whole
    ///      downstream the advertiser's own marketing generates. Worse, a failed `bind` is itself
    ///      the targeting signal: the reverting transaction is still mined, with the code readable
    ///      in its calldata, publicly advertising an unclaimed code someone is actively trying to
    ///      use. So the real rules are operational, and they are not optional:
    ///
    ///      1. **Claim before you publish.** A code must be registered on-chain before it appears
    ///         in any marketing, link or announcement. The window is unbounded otherwise.
    ///      2. **There is no current partner-code procedure while `registerFor` is design-open.** If
    ///         it is deleted, the partner registers for itself; any alternative must be explicitly
    ///         accepted and tested before publication.
    ///      3. Brand and confusable spellings are claimed in the constructor, before the address
    ///         exists to race against.
    ///
    ///      What remains after those is impersonation with a *different* string, which is the same
    ///      problem as a lookalike domain and is not one an on-chain rule can tell apart.
    function _register(bytes32 code, address owner) private {
        if (!isCanonical(code)) revert MalformedCode(code);
        address incumbent = referrerOf[code];
        // Reverts even when the caller already owns it. `register` must never be a silent no-op
        // that re-emits, because the calculator would then see two registrations of one code.
        if (incumbent != address(0)) revert CodeTaken(code, incumbent);

        referrerOf[code] = owner;
        emit CodeRegistered(code, owner);
    }

    // ── Binding ──────────────────────────────────────────────────────────────

    /// @notice Record who referred the caller. Once only, and permanent.
    /// @dev Checks are ordered already-bound, registered, non-bindable, then self-referral.
    ///
    ///      **The unregistered-code check is load-bearing.** Without it, an attacker could watch
    ///      for binds to codes nobody owns and register them afterwards, harvesting a downstream
    ///      they did nothing to earn.
    ///
    ///      **Permanence needs no escape hatch** *provided the code is a real payee* - a mis-bind
    ///      between two live codes costs the referee nothing, since their own rebate is earned by
    ///      binding at all rather than by whom they bound to. That argument fails for a code the
    ///      programme voids, which is why `NON_BINDABLE` exists rather than relying on nobody
    ///      thinking to bind to `OFFICIAL`.
    ///
    ///      **Self-referral rejection is a courtesy, not sybil resistance, and the cost of
    ///      defeating it is larger than previously written here.** A second address defeats it for
    ///      free, and so does a plain two-party cycle where each binds the other's code, needing
    ///      no extra addresses at all. The earlier note called the worst case "a capped rebate on
    ///      a fee the user's own capital genuinely generated", which accounted only for the
    ///      referee leg. The pair also collects the **referrer** leg, which is larger and runs far
    ///      longer, and which is payment for an introduction that did not happen. The honest worst
    ///      case is therefore the programme's entire outflow cap, for the full referrer window,
    ///      with zero acquisition - and since an unreferred borrower receives nothing, self-pairing
    ///      is the rational default rather than an edge case. Nothing on-chain can distinguish it;
    ///      the containment is the cap itself plus whatever gating the calculator applies.
    ///
    ///      **Integration hazard.** This binds `msg.sender`, and reverts rather than no-ops when
    ///      already bound. A wallet batch that bundles `bind` with a borrow is atomic, so a caller
    ///      who is already bound would have the borrow reverted along with it. Read `boundCode`
    ///      and omit the call rather than relying on it succeeding.
    function bind(bytes32 code) external {
        bytes32 existing = boundCode[msg.sender];
        // Rebinding to the *same* code must revert too, not no-op, for the same one-row-per-fact
        // reason as `register`.
        if (existing != bytes32(0)) revert AlreadyBound(existing);

        address referrer = referrerOf[code];
        if (referrer == address(0)) revert CodeNotRegistered(code);
        if (referrer == NON_BINDABLE) revert CodeNotBindable(code);
        if (referrer == msg.sender) revert SelfReferral();

        boundCode[msg.sender] = code;
        emit Bound(msg.sender, code, referrer);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @notice The account that referred `referee`, or `address(0)` if unbound.
    /// @dev An unbound referee reads `referrerOf[bytes32(0)]`, which is safe only because the zero
    ///      code can never be registered - `isCanonical(bytes32(0))` measures length 0 and fails
    ///      the minimum. That makes a positive `Config.REFERRAL_CODE_MIN_LENGTH` load-bearing for
    ///      correctness here, not just for namespace economics: at zero, one `register` would make
    ///      the caller the recorded referrer of every unbound account in existence. `Config.t.sol`
    ///      asserts the floor for this reason as well as the obvious one.
    function referrerFor(address referee) external view returns (address) {
        return referrerOf[boundCode[referee]];
    }

    function isRegistered(bytes32 code) external view returns (bool) {
        return referrerOf[code] != address(0);
    }

    /// @notice Whether `code` is a well-formed referral code.
    /// @dev Exposed so a frontend can tell "you typed it wrong" from "that code does not exist"
    ///      using *this contract's* rule rather than a reimplementation that can disagree.
    ///
    ///      The rule: uppercase `A-Z`, digits `0-9`, `-` and `_`, between
    ///      `Config.REFERRAL_CODE_MIN_LENGTH` and `Config.REFERRAL_CODE_MAX_LENGTH` bytes, encoded
    ///      as a left-aligned ASCII string with zero padding and no interior nulls.
    ///
    ///      **`0` and `1` are deliberately excluded, leaving 36 symbols.** Uppercase-only closes
    ///      the `BERNARD`/`bernard` confusion, but on its own it opens a worse one: in a
    ///      capitals-only string `0` is barely distinguishable from `O`, and `1` from `I`, so
    ///      `REC0UP` would be a legal code rendering as the brand. Reserving the confusables
    ///      instead was considered and rejected - the substitution set is combinatorial (a
    ///      13-character brand with four `O`/`I` positions has sixteen single-brand variants
    ///      before separators), the reserved list is claimed once at construction, and nothing can
    ///      reclaim a missed spelling afterwards because there is no owner and no upgrade. Barring
    ///      two characters is the only mitigation that is complete, and it is complete by
    ///      construction rather than by enumeration.
    ///
    ///      The cost is that a code cannot contain a zero or a one; `2-9` remain, so campaign
    ///      codes keep their digits. `5`/`S` and `8`/`B` stay legal because they are far weaker
    ///      confusions and barring them would start eating the alphabet for diminishing returns -
    ///      that residual is accepted and belongs in the reserved list, not the charset.
    function isCanonical(bytes32 code) public pure returns (bool) {
        uint256 length;
        // Walk all 32 bytes rather than stopping at the terminator: everything after the first
        // zero must also be zero, or `bytes32("AB\x00C")` would pass as "AB" while carrying a
        // different value, giving two distinct codes that print identically.
        bool ended;
        for (uint256 i; i < 32; ++i) {
            uint8 c = uint8(code[i]);
            if (ended) {
                if (c != 0) return false;
                continue;
            }
            if (c == 0) {
                ended = true;
                length = i;
                continue;
            }
            // 0x32-0x39 is 2-9, NOT 0x30-0x39: '0' and '1' are excluded as homoglyphs of 'O'
            // and 'I'. See the note above before widening this.
            bool ok = (c >= 0x41 && c <= 0x5A) // A-Z
                || (c >= 0x32 && c <= 0x39) // 2-9
                || c == 0x2D // -
                || c == 0x5F; // _
            if (!ok) return false;
        }
        // A code filling all 32 bytes never sets `ended`, and is over the maximum anyway.
        if (!ended) length = 32;

        return length >= Config.REFERRAL_CODE_MIN_LENGTH && length <= Config.REFERRAL_CODE_MAX_LENGTH;
    }
}
