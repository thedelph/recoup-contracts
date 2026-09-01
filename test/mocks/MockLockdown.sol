// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockLockdown
/// @notice The gate that lets one mock stack be permissionless under `forge test` and gated on a
///         public chain, without those being two different contracts.
///
/// @dev **Why this exists.** `DeployTestnet` puts the mock stack on Base Sepolia, where the whole
///      point is that a stranger can mint themselves bonds and USDC and try the dApp. That is a
///      feature and it stays. What was also true, and was not a feature, is that the same stranger
///      could call every *configuration* setter on those mocks: block an address out of USDC,
///      repoint the auto-stake sink, un-whitelist the adapter, halt every withdrawal, plant a
///      pending-yield figure the protocol then records as delivered farm yield, or credit
///      themselves a stake that no bond backs and withdraw somebody else's collateral against it.
///
/// @dev **Why a gate rather than a second set of contracts.** A hardened copy under `script/`
///      would need every setter marked `virtual` and overridden, would collide by artifact name
///      with the originals unless renamed, and renaming reaches three consumers that resolve these
///      contracts by bare name: the webapp's chain generator, the deployed-bytecode gate, and the
///      keeper's deployment-record check. More importantly the two copies would drift, and the
///      copy under test would be the one nobody deployed.
///
/// @dev **Default-open is the property that makes this safe to add.** `admin` starts zero and the
///      modifier is a no-op while it is zero, so every existing call site keeps working unchanged:
///      every suite here, and every other harness that imports these mocks by relative path and
///      therefore binds to whatever this tree ships. Gating them by default would have turned
///      those calls into runtime reverts, which is worse than a compile break: such a harness
///      would still report some passes and some failures, and so would report a wrong answer
///      about whether the defect it exists for is still present.
///
/// @dev **`lockTo` is one-way and only the constructing address may call it.** Both halves matter
///      on a public chain. Without the authority check a watcher could lock the stack to themselves
///      in the window between the mock's constructor and the deploy script's lockdown call, which
///      would hand them exactly the powers this file removes. Without the one-way check an admin
///      could be replaced. The window itself is real and is not closed here: between construction
///      and lockdown the mocks are open, both inside one `forge script` broadcast.
///
/// @dev 🟥 **NOTHING CATCHES A DEPLOY THAT LOSES THAT RACE, and this block said the opposite until
///      audit round 38.** It read: "A deploy that loses that race fails its own wiring
///      post-conditions rather than completing quietly." MEASURED 2026-08-30 against a local anvil
///      running the real `DeployTestnet` with a real `--broadcast`: with the three `lockTo`
///      transactions among those the node discarded, the script printed
///      `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` and **exited 0**, while on chain `admin()` and
///      `operator()` were still zero and a role-less caller could still write. Reproduced 3 of 3.
///
///      The structural half does not depend on that anvil. `forge script` executes `run()`
///      **exactly once, in the simulation phase, before a single transaction is sent**, so
///      `_assertMockStackLocked` sitting after `vm.stopBroadcast()` in *source order* is not the
///      same as running after the broadcast. It verifies the plan, and no post-condition re-reads
///      the chain, so it is blind to any partial broadcast however caused.
///
///      The window is also wider than "between two adjacent calls". Measured from a clean
///      47-transaction broadcast artefact, **40 transactions and a block boundary** separate the
///      last mock CREATE from the first `lockTo`, on an instant-mining chain, and a write made in
///      that window is permanent and survives a lockdown that then succeeds. The race this block
///      names - a watcher calling `lockTo` first - is genuinely closed by `lockAuthority`. The one
///      it does not name, a watcher writing mock *configuration* and the operator locking over the
///      top, is open and unobserved. Round-38 findings F1 and F2; the proposed fix is a separate
///      chain-reading entrypoint run against the live RPC after the deploy, and it is not built.
abstract contract MockLockdown {
    /// @notice Zero while the mock is open to anybody. Set once by `lockTo` and never again.
    address public admin;

    /// @notice A second address the gate admits, or zero. It exists because the off-chain epoch
    ///         job signs with the keeper key rather than the deploying key, and its one write to
    ///         this stack is the farm's pending-yield setter. An owner-only gate would have
    ///         stopped that job, and it would have stopped it as a red scheduled run, which is a
    ///         channel that reaches nobody unless failure email is switched on.
    address public operator;

    /// @notice The address that constructed this mock, and the only one that may lock it.
    address public immutable lockAuthority;

    error MockLocked(address caller);
    error MockAlreadyLocked();
    error MockAdminRequired();

    constructor() {
        lockAuthority = msg.sender;
    }

    /// @dev Reverts only once `admin` is set. While it is zero this costs a cold SLOAD and does
    ///      nothing, which is what keeps every existing caller of these setters working unchanged.
    modifier gated() {
        if (admin != address(0) && msg.sender != admin && msg.sender != operator) {
            revert MockLocked(msg.sender);
        }
        _;
    }

    /// @notice Close the configuration surface to `admin_`, and to `operator_` if non-zero.
    /// @dev Deliberately not `onlyOwner` and deliberately not two calls. A mock that could be
    ///      locked twice could be re-pointed, and a mock anybody could lock is a mock anybody can
    ///      capture. `admin_` may not be zero: passing zero would read as a successful lockdown
    ///      while leaving the stack open, which is the one failure mode a caller cannot see.
    function lockTo(address admin_, address operator_) external {
        if (msg.sender != lockAuthority) revert MockLocked(msg.sender);
        if (admin != address(0)) revert MockAlreadyLocked();
        if (admin_ == address(0)) revert MockAdminRequired();
        admin = admin_;
        operator = operator_;
    }

    /// @notice Move or clear the second key. `admin` itself stays one-way and unrotatable.
    ///
    /// @dev **An open finding since audit round 38, closed in round 40 after passing through
    ///      round 39 undispositioned.** It was filed as a convenience problem - "a
    ///      `RECOUP_KEEPER` rotation strands the epoch job forever; recovery is the deploy key or
    ///      a full mock redeploy" - and the convenience framing understates it in a way worth
    ///      writing down, because it is what kept the finding looking optional for two rounds.
    ///
    /// @dev 🟥 **SIGN-CHECKED, AND THE SIGN IS THE OPPOSITE OF THE ONE THE FINDING WARNS ABOUT.** The
    ///      warning was that `lockTo` being one-way is a security property and that a
    ///      `setOperator` "puts a door back in it". Read against the shipped configuration, it
    ///      does not:
    ///
    ///      - **Who can call it: `admin`, and nobody else.** `Deploy.s.sol` locks each mock with
    ///        `lockTo(deployer, p.keeper)`, so `admin == lockAuthority == the deploy key`. That
    ///        key already reaches **every** `gated` member of all three mocks directly. So this
    ///        function hands no principal a capability it did not already hold; it only lets the
    ///        holder delegate one it has.
    ///      - **It is deliberately NOT `gated`.** `gated` admits `operator` as well, which would
    ///        let the second key re-point itself - privilege escalation inside the gated set, and
    ///        the one genuine way to build this wrong. `admin` only.
    ///      - **It fails closed before lockdown.** While `admin` is zero, `msg.sender != admin` is
    ///        true for every possible caller, because `msg.sender` is never the zero address. So
    ///        this cannot be used to squat the operator slot in the window between the constructor
    ///        and `lockTo` - the window audit round 38 measured at 40 transactions and a block
    ///        boundary before the round-39 remediation narrowed it. That is a free property of
    ///        the comparison, not a clause anybody has to remember.
    ///      - **`admin` is untouched and `lockTo` stays one-way.** `MockAlreadyLocked` still
    ///        refuses a second lock, so the property the file's own docstring names - "without the
    ///        one-way check an admin could be replaced" - is exactly as true after this as before.
    ///
    /// @dev **What the one-way `operator` was actually buying was an INABILITY TO REVOKE, and that
    ///      is the direction that matters.** `seedStakeFor` is `gated`, and this file's own
    ///      neighbour says of it that unbacked credit "lets its holder withdraw collateral no bond
    ///      backs". Until this function existed, a compromised keeper key could do that on the
    ///      live testnet stack and there was **no revocation path at all** short of redeploying
    ///      three contracts, moving three addresses, and rewriting the deployment record, the
    ///      webapp's chain generator and the bytecode gate's rows. Passing `address(0)` here
    ///      revokes in one transaction - **on a deployment made by a script that carries this
    ///      contract, which the live Base Sepolia mocks predate entirely, so this is a control
    ///      for the next deployment and not one in force on the current one.** So the door this
    ///      adds opens outward: it is the incident
    ///      response that was missing, not a new way in.
    ///
    ///      That is not hypothetical. `RECOUP_KEEPER_KEY` lives in `contracts/.env` on the
    ///      development machine, in the same file as the deploy key and the NAV confirmer key.
    ///
    /// @dev **No event.** Nothing in this repository watches these mocks by log; `AssertLocked`
    ///      reads `admin()` and `operator()` from the chain and compares them against the
    ///      deployment record, which is the check that would actually catch a wrong value here,
    ///      and it already runs. An event would cost bytes to be read by nothing.
    function setOperator(address operator_) external {
        if (msg.sender != admin) revert MockAdminRequired();
        operator = operator_;
    }
}
