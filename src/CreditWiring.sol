// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILenderPool} from "./interfaces/ILenderPool.sol";
import {ILiquidationAuction} from "./interfaces/ILiquidationAuction.sol";
import {ILiquiditySource} from "./interfaces/ILiquiditySource.sol";

/// @title CreditWiring - `CreditManager`'s cold paths, moved off its bytecode
/// @notice A stateless, deploy-time-linked library holding the checks `CreditManager` runs when a
///         pointer is repointed or a principal balance is delivered. Nothing here is reached by
///         `borrow`, `repay`, `settle` or `liquidate`.
///
/// @dev **WHY THIS EXISTS, AND WHY IT IS A LIBRARY RATHER THAN A CONTRACT.**
///
///      `CreditManager` is against the EIP-170 runtime code limit. It was 1,658 bytes over it
///      between 2026-08-20 and 2026-08-22 - undeployable, while a twelve-agent audit round
///      reviewed it and every test passed, because Foundry's test EVM does not enforce the limit.
///      PR #268 recovered it to 24,512 bytes, a margin of 64, by hoisting ten repeated statements
///      behind private functions. That was the last cheap trick.
///
///      64 bytes is not headroom: the last three pull requests to touch `CreditManager` added 861,
///      485 and 879 bytes each. This library is the structural answer, and it is measured rather
///      than argued. MEASURED, `forge build --sizes` from a clean `out/`, whole tree:
///      **24,512 -> 21,510**, a margin of **3,066**. The repository's contract-size check reports
///      the figure on every contracts pull request.
///
///      **The round-24 remediation spent 56 of that margin: `CreditManager` now reads 21,566, a
///      margin of 3,010, and this library 4,089 -> 4,286.** All 56 are the attestation described on
///      `WIRING_CHECKED` below - two returndata decodes and one shared comparison. Round 24's
///      other follow-up item, the fourth probe in `checkAuctionSwap`, cost **nothing** on
///      `CreditManager` and 120 here, which is exactly the trade this file exists to make.
///      Measured by building each fix alone: `CreditManager` read 21,510 with only the probe and
///      21,566 with both.
///
///      **Round 26 spent 113 more, extending that attestation to the whole library: `CreditManager`
///      now reads 21,679, a margin of 2,897, and this library 4,341.** Nothing else in the tree
///      moved. The per-member breakdown, including the one that made the contract *smaller*, is on
///      `WIRING_CHECKED`.
///
///      The pair to quote is whatever the contract-size check prints from a clean
///      `out/`; every figure written down by hand elsewhere is one build behind, and after a round
///      that moves this number several of them are. They are corrected in one pass once a round's
///      work has landed rather than per branch, because a figure re-derived on each branch in
///      flight is wrong in a different way on every one of them.
///
///      **Audit round 26 spent none of it, which is the same trade a second time.** The `start`
///      probe at the foot of `checkAuctionSwap` cost **0 bytes on `CreditManager`** - still 21,566,
///      margin still 3,010 - and **208 here**, 4,286 -> 4,494, margin 20,082. MEASURED,
///      the contract-size check from a clean `out/` on both sides of the change. A probe
///      is the cheapest thing there is to add to this file and the most expensive to add to that
///      one, which is worth remembering the next time a guard is written into the wrong contract to
///      save a `DELEGATECALL`.
///
///      **An `internal` library would have bought nothing, and that is measured too.** An internal
///      library function is inlined into every caller; `LtvMath` is `internal` throughout and
///      compiles to 85 bytes of standalone runtime code, which is a metadata stub and no code at
///      all. Only an `external` library function moves bytes, because only that becomes a
///      `DELEGATECALL` to a separately deployed address.
///
///      **And `external` is not free, which decides what belongs here.** A library call site costs
///      roughly 130 bytes of encode/call/decode, so moving a small function out makes the caller
///      *bigger*. MEASURED, same tree, as a control: making all four `LtvMath` functions `external`
///      grew `CreditManager` by 434 bytes, `LiquidationAuction` by 295 and `CollateralVault` by
///      695. The rule this establishes is that a body has to be substantially larger than its call
///      site before extraction pays, which is why the five functions below are the large, branchy,
///      `try`/`catch`-heavy ones and nothing else moved.
///
///      **WHY A LIBRARY IS NOT THE CONTRACT SPLIT THAT WAS REFUSED.** That refusal is about
///      adding a *contract* to the graph, and it is right: rounds 7 and 8 were both two contracts
///      disagreeing about what a pointer meant, and `RiskPointerAgreement.t.sol` and
///      `NavPointerAgreement.t.sol` exist because of it. The objection is about a pointer that can
///      be set to one thing here and another thing there. This library has **no storage, no owner,
///      no setter and no address in anybody's storage**: its address is written into
///      `CreditManager`'s bytecode by the linker at compile time, so there is nothing to disagree
///      with. It cannot be repointed without recompiling and redeploying `CreditManager` itself,
///      which is the same act as changing any other line of it.
///
///      **THE ERROR TYPES ARE REDECLARED HERE ON PURPOSE.** A custom error's selector is
///      `keccak256` of its name and parameter types and carries no contract identity, so
///      `CreditWiring.LenderPoolIncomplete` and `CreditManager.LenderPoolIncomplete` are the same
///      four bytes. `revert` data propagates through a `DELEGATECALL` unchanged, so every existing
///      `vm.expectRevert(CreditManager.X.selector)` still holds and no test was edited. The
///      declarations in `CreditManager` are deliberately left in place: they are what the tests
///      name, an unused error declaration costs no runtime code, and deleting them would be a
///      change to that contract's published ABI for no gain. **If you rename or reparameterise an
///      error here, rename it there in the same commit** - the two are one type in every way that
///      the chain can see, and nothing in the compiler will tell you they have drifted.
///
///      **WHAT DELEGATECALL PRESERVES.** `address(this)`, `msg.sender`, `msg.value` and storage
///      are the caller's. So `sourceStillAnswersToUs` comparing against `address(this)` reads
///      `CreditManager`'s address, `pullPrincipal`'s `usdc.balanceOf(address(this))` reads
///      `CreditManager`'s balance, and every outbound call below arrives at its target with
///      `CreditManager` as `msg.sender` - all exactly as before the move. That is the property
///      that makes this a pure relocation of bytes rather than a change of behaviour, and it is
///      why the functions take their inputs as arguments: an external library function cannot
///      name a value-typed state variable of its caller.
///
///      **`view` library functions are `DELEGATECALL` too, and that was checked rather than
///      assumed.** The EVM has no static delegatecall, so a `view` external library function could
///      plausibly have compiled to a plain `STATICCALL` - which would make `address(this)` the
///      *library's* address and turn `sourceStillAnswersToUs` into a function that always answers
///      no. MEASURED with solc 0.8.24, a library returning `(address(this), msg.sender)` from one
///      `view` and one non-`view` function: both return the **caller's** address and the caller's
///      own caller, identically. Anything moved here later that reads `address(this)` inherits
///      that, but re-run the check if the compiler version moves.
///
///      **GAS.** One `DELEGATECALL` plus argument encoding, on the order of 3,000 gas, added to
///      each call site. Every call site is an `onlyOwner` wiring change behind a timelock, or a
///      principal settlement that runs at most once per liquidity-source migration. None is on a
///      borrower's path. That trade is the whole reason this particular set was chosen.
library CreditWiring {
    using SafeERC20 for IERC20;

    /// @notice The value **every** external member of this library returns once its body has run to
    ///         the end, and which `CreditManager` asserts on the way back. **Not decoration, and not
    ///         deletable to save bytes.**
    ///
    /// @dev **AUDIT ROUND 24, FOLLOW-UP ITEM 2 - WHY A GUARD THAT ONLY REVERTS IS NOT ENOUGH.**
    ///
    ///      `checkLenderPoolSwap` and `checkAuctionSwap` used to return nothing. Between them they
    ///      carry the *entire* clause set of `setLenderPool`, `setLiquiditySource` and
    ///      `setLiquidationAuction` - and `CreditManager.setLiquidationAuction` has no clause of
    ///      its own at all, only the library call, the assignment and the event. With no return
    ///      value there is nothing for the ABI decoder to reject, so "the `DELEGATECALL` did not
    ///      revert" was read as "every clause passed", and the caller could not tell the two apart.
    ///      Eight of twelve agents found that independently.
    ///
    ///      What it is NOT about. All of this was measured last round and none of it can be
    ///      re-derived by reading this file, so it is written down rather than left to be found
    ///      again:
    ///
    ///      - **A missing library address fails CLOSED, not open.** solc 0.8.24 emitted an
    ///        `EXTCODESIZE` guard ahead of exactly the two void-returning delegatecalls and omitted
    ///        it for the three value-returning ones, because for those the returndata check
    ///        subsumes it. Four agents measured that; one disassembled the linked runtime at all
    ///        five placeholder offsets. **Now that all five return a value the compiler emits no
    ///        `EXTCODESIZE` at any of them, and that was measured here rather than assumed**: no
    ///        `0x3b` byte occurs within 120 bytes either side of any of the five link-reference
    ///        offsets in the shipped runtime, and the whole contract contains six. The guard has
    ///        not been lost, it has moved - an address with no code returns empty returndata, and
    ///        the decode refuses that. `test_R24_anEmptyLibraryAddressStillFailsClosed` is the
    ///        behavioural half, and it is the arm to re-run if the compiler version moves.
    ///      - **A `view` library member does not compile to `STATICCALL`.** Refuted six ways; the
    ///        note at the head of this file records it. Re-run only if the compiler version moves.
    ///
    ///      **The residual, and the only thing this constant closes, is a WRONG-BUT-CODED address
    ///      at the placeholder.** Any code at all passes an `EXTCODESIZE` guard. With a stale or
    ///      simply mistaken library linked, a `DELEGATECALL` that hits a fallback - or a bare
    ///      `STOP` - returns success, and `DELEGATECALL` grants that code this manager's storage,
    ///      identity and full write authority. MEASURED last round with one `STOP` byte etched at
    ///      the library address: `setLiquidationAuction(EOA)` **succeeded**, the pointer moved,
    ///      `repay` then reverted for every borrower, and repointing at a freshly deployed real
    ///      auction reverted too - an unrecoverable state. With permissive code etched, the
    ///      substituted body wrote `0xdeadbeef` into `CreditManager`'s own storage.
    ///
    ///      **This project has already made the wrong-but-coded mistake once**, with
    ///      `ReferralRegistry` in round 22: a stale address carried across a redeploy. A linker
    ///      cannot catch that, because the address it writes is whatever it was handed.
    ///
    ///      So both members now answer and the caller asserts the answer. The tag is
    ///      domain-separated rather than a bare `true` on purpose: `1` is what a great deal of
    ///      accidental code returns, so a boolean would be forged by any fallback that happens to
    ///      leave a non-zero word in memory. `CreditWiringLinkage.t.sol` pins all of it.
    ///
    ///      **AUDIT ROUND 25, FINDING 1 (HIGH), AND ROUND 26 FOLLOW-UP ITEM 3 - THE OTHER THREE.**
    ///
    ///      Round 24 stopped at the two void members, on the argument written into this file that
    ///      "the three that already returned a value always had their returndata checked". That
    ///      sentence is true and it is not the question. **It conflates the returndata being
    ///      DECODABLE with the real body having RUN** - which is the same substitution round 24
    ///      itself found one level up, where "the delegatecall did not revert" was read as "every
    ///      clause passed". A decoder rejects a *malformed* answer. It cannot reject a well-formed
    ///      one invented by a fallback, and every one of the three carried a measurement or a
    ///      routing decision in that answer rather than merely a revert.
    ///
    ///      MEASURED before the fix and re-measured here rather than taken from the finding.
    ///      Eleven bytes etched at the linked address -
    ///      `PUSH1 0x44 CALLDATALOAD PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN` - which echoes
    ///      `pullPrincipal`'s third argument back as `delivered`: a substitute that reports full
    ///      delivery and moves nothing. Against a 5,000.000000 park, `settlePrincipal` took
    ///      `pendingPrincipal` **5,000,000,000 -> 0** while `CreditManager`'s USDC stayed at
    ///      5,000,000,000 and `TreasuryLiquiditySource`'s at 95,000,000,000. The control on the real
    ///      library moves the 5,000,000,000 and leaves the manager holding nothing. The counter that
    ///      records what the funder is owed was destroyed and the money never left.
    ///
    ///      **`flushPrincipalTo` is worse, and that was executed rather than left "by inspection".**
    ///      It zeroes `owedToSource[source]` before it calls, and `owedToSource` has one drain, no
    ///      owner rescue, and is excluded from `sweepFreeBalanceToInsurance`. Both substitute shapes
    ///      were run against a 5,000.000000 parked entry:
    ///
    ///      - The echoing substitute above: `owedToSource` **5,000,000,000 -> 0**,
    ///        `totalOwedToSources` likewise, `PrincipalFlushed` emitted - and **not one unit of USDC
    ///        moved anywhere**. The park is gone and no counter claims the money.
    ///      - A substitute returning one zero word: `pullPrincipal` reports nothing delivered and
    ///        `sourceStillAnswersToUs` is forged to `false`, so the fallback leg fires and
    ///        **5,000,000,000 USDC is bare-transferred to a source that does still name this
    ///        manager** - audit round 23's finding 1 reconstituted out of two forged answers. The
    ///        control on the real library reverts `PrincipalRefused(source, 5000000000)` and moves
    ///        nothing.
    ///
    ///      **And an attested call gated by an unattested one is not attested** (round 25 finding 3).
    ///      `setLiquiditySource` reaches the attested `checkLenderPoolSwap` only inside
    ///      `if (... && _fundsAsALenderPool(...))`. A forged zero word reads `false`, the branch is
    ///      skipped, and the attested call is never made at all. MEASURED with the zero-word
    ///      substitute and a real `LenderPool`: `liquiditySource` = the pool, `lenderPool` =
    ///      `address(0)`, which is precisely the funder/sink split `LossSinkMustBeTheFunder` exists
    ///      to forbid. The control sets both pointers to the pool.
    ///
    ///      **THE RULE THAT COMES OUT OF IT, AND WHY IT IS NOT PER-MEMBER.** The tag proves one
    ///      thing about one *address*: that the code at the linker's placeholder is this library. So
    ///      a narrow reading is available - `sourceStillAnswersToUs` is reached only from
    ///      `flushPrincipalTo`, always after `pullPrincipal` has already asserted the tag against the
    ///      same address, so attesting it buys nothing. That reading is exactly the shape this file
    ///      has already been punished for twice: `checkAuctionSwap`'s probe list was read as "every
    ///      selector *this function* calls bare" when the rule needed was "every selector *this
    ///      protocol* calls bare", and it let a finding through four rounds running. A rule that
    ///      depends on the order of two statements in a caller is not checkable by reading either
    ///      file, and nothing in the compiler reports it when a refactor reorders them.
    ///
    ///      So the rule is stated at the type instead, with no exceptions to reason about: **every
    ///      `external` member of this library returns `WIRING_CHECKED` as its first return value,
    ///      and every call site in `CreditManager` passes it to `_requireWiringRan`.** A member
    ///      added here without one is the defect, whatever its call graph looks like.
    ///
    ///      Each of the three sets the tag on a **single exit path**, after the work, rather than at
    ///      the top. `fundsAsALenderPool` and `sourceStillAnswersToUs` had early `return false`
    ///      statements ahead of their probe; keeping those and adding the tag would have let a body
    ///      that never asked the question hand back the word that says it did.
    ///
    ///      **COST, measured on a clean `out/` and built one member at a time**, because the
    ///      inherited estimate of "about +28 bytes per site" is a hypothesis and it is out by a factor
    ///      of two in one direction and by its sign in another. From `CreditManager` 21,566:
    ///
    ///      - `pullPrincipal` alone: **21,622** (+56). One private call site covers all three
    ///        principal paths, because `settlePrincipal` and `setLiquiditySource` reach it through
    ///        `_deliverPrincipal` and `flushPrincipalTo` reaches it directly.
    ///      - plus `fundsAsALenderPool`: **21,734** (+112). Twice the first, because solc inlines
    ///        that private helper into both of its call sites.
    ///      - plus `sourceStillAnswersToUs`: **21,679**, which is **55 bytes SMALLER** than the step
    ///        before it. Adding the fifth assertion is what makes solc stop inlining
    ///        `_requireWiringRan` and emit it once, and the saving at the other four sites more than
    ///        pays for the new one. Worth writing down: the member with the weakest independent case
    ///        was the one that reduced the contract, and had the three been costed by argument
    ///        rather than by building each in turn, it is the one that would have been dropped.
    ///
    ///      Net **21,566 -> 21,679, +113, margin 3,010 -> 2,897**; this library 4,286 -> 4,341.
    bytes32 internal constant WIRING_CHECKED = keccak256("recoup.CreditWiring.checked.v1");

    // These are `CreditManager`'s errors, by selector. See the note on redeclaration above.
    error ZeroAddress();
    error LossOutstanding(uint256 unsocialisedLossNow);
    error PoolPrincipalOutstanding(address pool, uint256 outstanding);
    error PoolImpairmentOutstanding(address pool, uint256 marked);
    error LenderPoolIncomplete();
    error LiquiditySourceIncomplete();
    error AuctionHasLiveWork(uint256 outstanding);
    error LiquidationAuctionVaultMismatch(address auctionVault);
    error LiquidationAuctionRiskParamsMismatch(address auctionRiskParams);
    error LiquidationAuctionNavOracleMismatch(address auctionNavOracle);
    error LiquidationAuctionIncomplete();

    /// @dev Does `who` keep a lender-pool principal book, and therefore have to be charged when
    ///      principal it funded is lost?
    ///
    ///      `exitReserve()` is the discriminator because it *is* the property being asked about:
    ///      it exists only on a balance sheet whose depositors price their own exit against the
    ///      protocol's losses, which is exactly what makes "the source bore it by never being
    ///      repaid" false. `socialiseLoss` would be the more direct question and cannot be asked -
    ///      it is not a view. `TreasuryLiquiditySource` implements `ILiquiditySource` and nothing
    ///      else, so it answers no.
    ///
    ///      **`outstandingPrincipal()` was tried first and is WRONG**, which the treasury control
    ///      test caught: `TreasuryLiquiditySource` declares that counter too, so the probe returned
    ///      true for a treasury and the deploy script's own wiring - pool as sink, treasury as
    ///      funder - stopped being legal. Recorded rather than quietly corrected, because it is the
    ///      obvious choice: the selector `setLenderPool` probes on its *outgoing* pointer is not a
    ///      pool test, it is a principal-book test, and the two are not the same question.
    ///
    ///      **Fails open on a CONTRACT that cannot answer, deliberately, and it is the same stance
    ///      `setLenderPool` takes on its outgoing probe.** A contract that refuses `exitReserve()`
    ///      is not a pool with depositors to short-change, and letting it freeze a pointer
    ///      permanently is the deadlock shape again. A real `LenderPool` answers this from storage
    ///      it always has and cannot fail to.
    ///
    ///      **It does NOT fail open on an address with no code, and audit round 25 finding 5 was
    ///      right that the sentence above used to claim otherwise.** solc emits its `EXTCODESIZE`
    ///      check ahead of the call and therefore *outside* the `try`, so a codeless `who` reverts
    ///      with empty returndata and nothing catches it. MEASURED: `setLiquiditySource(EOA)`
    ///      reverts, returndata length 0.
    ///
    ///      **The code is right and the sentence was wrong, which is why only the sentence moved.**
    ///      The prescription was to make the behaviour match the claim with a `who.code.length`
    ///      guard. That was built and run before being refused, and it moves the number the wrong
    ///      way: with the guard in place `setLiquiditySource(EOA)` **succeeds** and installs a bare
    ///      EOA as the protocol's funder, from which `borrow` reverts for everybody. The revert this
    ///      finding calls a contradiction is the only thing standing between an operator typo and
    ///      that state, so failing open here would remove a live protection to make an unreachable
    ///      case tidier.
    ///
    ///      Unreachable by construction, and the argument is short enough to check. `who` is always
    ///      `liquiditySource` or the address about to become it. A codeless address cannot become
    ///      `liquiditySource`: `setLiquiditySource` reaches this probe on it, and the one branch
    ///      that skips the probe requires `lenderPool == liquiditySource_`, while `lenderPool`
    ///      cannot be codeless either - MEASURED rather than reasoned, `setLenderPool(EOA)` on a
    ///      manager with no funder set, so the gate above is skipped and the probes are reached:
    ///      **reverts, returndata length 0**, from the same `EXTCODESIZE` check outside the `try`
    ///      rather than from `LenderPoolIncomplete`. `who == address(0)` is answered `false` on the
    ///      line below without reaching any of that, which is the fresh-deployment state and has to
    ///      stay legal.
    ///      `test_R26_aCodelessFunderRevertsRatherThanFailingOpen` pins the behaviour so the
    ///      sentence cannot drift back.
    function fundsAsALenderPool(address who) external view returns (bytes32 attestation, bool funds) {
        if (who != address(0)) {
            try ILenderPool(who).exitReserve() returns (uint256) {
                funds = true;
            } catch {}
        }

        // Reached only when the probe above was actually run. Single exit and no early return on
        // purpose: the tag has to mean "this body reached its end", and a `return false` before the
        // `try` would let the tag be handed back by a body that never asked the question.
        attestation = WIRING_CHECKED;
    }

    /// @dev The completeness probe `setLiquiditySource` owes on the address it is about to install,
    ///      and the third pointer in this contract to get one. Audit round 27 item 2, carried to
    ///      round 28 as item 3: **`setLiquiditySource` probed nothing at all**, while
    ///      `CreditManager.borrow` calls `lend` on that pointer bare, one function away from every
    ///      borrower in the protocol.
    ///
    ///      **WHAT THIS PROBES AND WHAT IT CANNOT, BECAUSE THE FILE ALREADY ARGUED ITSELF OUT OF
    ///      HAVING IT ONCE.** `CreditManager.owedToSource` says, of round 22's finding 5, that "a
    ///      selector probe on `setLiquiditySource` does nothing either, because the break is
    ///      dynamic: the source answered perfectly until it was frozen". That sentence is **true**
    ///      and it is about a **different failure**. Round 22 is a source that implements this
    ///      interface correctly and is later blacklisted by USDC; no probe of any shape can see a
    ///      freeze that has not happened yet, which is exactly why `owedToSource` parks the money
    ///      instead. This probe is aimed at the pointer being **wrong on the day it is written** -
    ///      a mistyped address, an address carried over from a previous deployment, a contract that
    ///      is not a liquidity source at all - where the answer is available at the setter and
    ///      nowhere else afterwards. Two failure modes, two remedies, and neither substitutes for
    ///      the other. **Do not delete this probe on the strength of that sentence.**
    ///
    ///      The consequence it closes is total and silent. A wrong-but-coded pointer installs with
    ///      no complaint, and then `borrow` reverts for **every borrower** with **returndata length
    ///      0** - a missing selector, with no error to diagnose it by - which is the same shape and
    ///      the same evidence round 22 finding 21 measured one pointer over on `recoverLoss`.
    ///      Nothing else in the protocol asks the question: `fundsAsALenderPool` runs on the same
    ///      address in the same call, but it asks whether the incoming funder keeps a principal
    ///      book and **fails open by design**, so a contract that answers nothing at all passes it
    ///      as a treasury.
    ///
    ///      **THE PROBE LIST, COUNTED FROM THE TYPE RATHER THAN FROM THE DIFF** - round 22's own
    ///      headline lesson, and the reading that let a finding through four rounds running was
    ///      "every selector *this function* calls" instead of "every selector *this protocol* calls
    ///      bare on this pointer". `ILiquiditySource` has **three** members. Two are reached from
    ///      `src/` and **both are bare**: `lend`, at `CreditManager.borrow`, and `repayPrincipal`,
    ///      on the non-`bestEffort` branch of `pullPrincipal` below, which is the branch
    ///      `settlePrincipal` takes. `available()` is called from nowhere in `src/` - it is
    ///      advertised as advisory for keepers and the UI - so it is **not** probed, on the same
    ///      rule that leaves `ILenderPool.exitAssets` and `withdrawalRequest` out of the list in
    ///      `checkLenderPoolSwap`. Three members, two reached, two bare, two probed.
    ///
    ///      **Both probes read the SHAPE of the failure, not its success**, which is what makes
    ///      them probes at all: a contract with no matching selector and no fallback reverts with
    ///      empty returndata, while a contract that has the function and refuses reverts with four
    ///      bytes of error selector or a `Panic`. Success is *not* required, and must not be: both
    ///      members are `onlyCreditManager` on both in-tree sources, and a legal wiring order
    ///      installs the source here **before** the source has been pointed back at this manager -
    ///      so `NotCreditManager()` is the ordinary answer and it proves the selector exists. That
    ///      is the same distinction `checkLenderPoolSwap` draws for `recoverLoss(0)`.
    ///
    ///      **A zero argument, and a genuine `CALL` rather than a `STATICCALL`.** A static probe is
    ///      wrong here for the reason recorded on `recoverLoss(0)`: `LenderPool.lend` and
    ///      `LenderPool.repayPrincipal` are both `nonReentrant`, so the guard writes a slot before
    ///      the body runs and a `STATICCALL` would revert with empty returndata against the **real**
    ///      contract and refuse it. It is not new exposure - `setLiquiditySource` already reaches
    ///      this address non-`view` through `_pushLossReserves` when the incoming funder is also the
    ///      sink - and it runs before this setter has written anything, so a re-entrant call sees
    ///      the pointer that is already installed rather than a half-written pair.
    ///
    ///      **`lend(0)` is the one that can SUCCEED, and that is written down rather than left to
    ///      be discovered.** `LenderPool.lend` refuses zero (`ZeroAmount`), but
    ///      `TreasuryLiquiditySource.lend` does not: against a treasury already pointed back at
    ///      this manager the probe completes, adding zero to `outstandingPrincipal`, emitting
    ///      `Lent(0)` and transferring zero USDC. That is inert in value terms and it is a real
    ///      event an indexer will see. It was preferred to dropping `lend` from the list, because
    ///      `lend` is the selector this entire item is about; and to probing with a non-zero
    ///      amount, which would move money out of a source at a wiring change.
    ///
    ///      **WHAT IT DOES NOT CATCH, said plainly rather than left to a count.** A contract with a
    ///      fallback answers everything, so it passes - the same limit every probe in this file
    ///      has. And a **codeless** address passes both calls rather than failing them: neither
    ///      member returns a value, so solc emits no `EXTCODESIZE` check, and a call to an account
    ///      with no code succeeds returning nothing. That case is already refused, and refused
    ///      unconditionally: `setLiquiditySource` reaches `fundsAsALenderPool` on the same address
    ///      whenever `lenderPool != liquiditySource_`, where `exitReserve()` **does** return a value
    ///      and the `EXTCODESIZE` check therefore reverts - and in the one branch that skips it,
    ///      `lenderPool == liquiditySource_`, `lenderPool` itself cannot be codeless because
    ///      `checkLenderPoolSwap` probed it through `impairedBorrowerCount()`. Both halves are
    ///      measured, and both measurements are written down in `fundsAsALenderPool`'s docstring
    ///      above: `setLiquiditySource(EOA)` and `setLenderPool(EOA)` each revert with returndata
    ///      length 0, and `test_R26_aCodelessFunderRevertsRatherThanFailingOpen` pins the first.
    ///
    /// @return attestation `WIRING_CHECKED`, which the caller asserts. Set on a single exit after
    ///         both probes, for the reason `fundsAsALenderPool` gives: the tag has to mean that this
    ///         body reached its end, not that something at this address returned a word.
    function checkLiquiditySourceSwap(address incoming) external returns (bytes32 attestation) {
        try ILiquiditySource(incoming).lend(0) {}
        catch (bytes memory reason) {
            if (reason.length == 0) revert LiquiditySourceIncomplete();
        }
        try ILiquiditySource(incoming).repayPrincipal(0) {}
        catch (bytes memory reason) {
            if (reason.length == 0) revert LiquiditySourceIncomplete();
        }

        // Reached only when both probes above were actually run. The caller refuses any other
        // answer. See `WIRING_CHECKED`.
        attestation = WIRING_CHECKED;
    }

    /// @dev Every clause `setLenderPool` owes, and no writes. Shared with `setLiquiditySource` so
    ///      the migration path cannot be a way in through the other door that skips them, and
    ///      split from the assignment so both callers can leave the pointer pair consistent at
    ///      every instant an external call could observe it.
    ///
    ///      `outgoing` is the caller's current `lenderPool` and `unsocialisedLoss` is its counter
    ///      of the same name, both read by the caller and passed in because an external library
    ///      function cannot name a value-typed state variable of its caller. The second replaces a
    ///      call to `_requireNoUnsocialisedLoss` and reverts `LossOutstanding` on the same
    ///      condition, with the same argument, in the same position.
    ///
    /// @return attestation `WIRING_CHECKED`, which the caller asserts. See that constant: without
    ///         a return value there was nothing for the ABI decoder to reject and a wrong-but-coded
    ///         library address turned this entire guard body into a no-op that reported success.
    function checkLenderPoolSwap(address outgoing, address lenderPool_, uint256 unsocialisedLoss)
        external
        returns (bytes32 attestation)
    {
        if (lenderPool_ == address(0)) revert ZeroAddress();
        if (unsocialisedLoss != 0) revert LossOutstanding(unsocialisedLoss);

        if (outgoing != address(0) && outgoing != lenderPool_) {
            try ILenderPool(outgoing).outstandingPrincipal() returns (uint256 stillLent) {
                if (stillLent != 0) revert PoolPrincipalOutstanding(outgoing, stillLent);
            } catch {}

            // **The mirror of the outgoing pool's own refusal, and audit round 16 found it missing.**
            // `LenderPool.setCreditManager` will not change its manager while `totalImpairment` is
            // non-zero, with eighteen lines on why a stale per-borrower reserve is invisible at the
            // swap. This side checked the principal and the backlog and said nothing about the
            // mark, so the rule stood on one side of one pointer pair. Once this pointer moves,
            // `_setImpairment` targets the incoming pool, so nothing can clear the outgoing one's
            // map and the outgoing pool can never be repointed either.
            //
            // **`exitReserve()` cannot answer this**, which is why it needs a view of its own: it
            // clamps to `outstandingPrincipal`, and the clause immediately above has just required
            // that to be zero. The one impairment-shaped number already on the interface reads zero
            // in exactly the state that matters.
            //
            // **Not a mutually-unsatisfiable pair, unlike the backlog clause above it**, but audit
            // round 17 found the reason given here inverted and it is corrected rather than
            // quietly deleted. This used to say a mark's drains "depend on neither pointer". They
            // depend on this one: `refreshImpairment` and `refreshImpairments` both read
            // `lenderPool`, `_setImpairment` writes through it, and `LenderPool
            // .releaseImpairment` is gated on the pointer back - which the paragraph eleven lines
            // above says outright. What is actually true is narrower and is all the guard needs:
            // the drains work on the *outgoing* pool right up until this assignment, so the
            // refusal forbids nothing that was reachable before it, and clearing the mark first is
            // a step the owner can always take. That distinction is the one
            // `EpochHarvester.setLenderPool` spends twenty lines on, and it is worth checking
            // every time a guard like this is added.
            //
            // A separate `try` from the one above, because a `revert` inside a success body is not
            // caught by its own `catch`. Fails open on an address that cannot answer, for the
            // reason given at the head of this function.
            try ILenderPool(outgoing).totalImpairment() returns (uint256 marked) {
                if (marked != 0) revert PoolImpairmentOutstanding(outgoing, marked);
            } catch {}
        }

        // **The same rule as `setLiquidationAuction`, one pointer over.** Audit round 17, and the
        // reason it is a separate finding rather than the same one is that it was missed in the
        // same commit range that applied the rule next door: `refreshImpairments` calls
        // `impairedBorrowerCount` and `impairedBorrowerAt` bare, and both members arrived in the
        // round that built the walk.
        //
        // Lower stakes than the auction probe and deliberately so: the two drains reach this pool
        // through `_setImpairment`, which `try`s both legs, so a pool that cannot answer strands
        // the bulk sweep rather than bricking repayment. Worth refusing at wiring time anyway,
        // because the sweep is the only bounded way to clear a stale mark. Under controller-scoped
        // requests a stale mark no longer freezes a global queue, but it does leave every live
        // request quoting against a stale-low exit price until its controller refuses through
        // `minAssetsOut` or somebody refreshes the mark.
        //
        // **Audit round 22, finding 21: the list was one selector long and the file had already
        // said, three rounds running, that it should be every selector called bare.** The comment
        // twelve lines above this one says outright that this is "the third round in a row that a
        // selector reached a never-blockable path without its probe". It was the fourth:
        // `recoverLoss` was added to `ILenderPool` by round 21's own remediation and called bare at
        // `recoverWrittenDownLoss`, and nothing extended the list. MEASURED: a pool answering every
        // other member installed with no complaint as both funder and sink, and
        // `recoverWrittenDownLoss` then reverted with **returndata length 0** - a missing selector,
        // with no error to diagnose it by.
        //
        // Counted from the type rather than from the diff, which is round 22's own headline lesson.
        // `ILenderPool` declares twenty-two callable members of its own. Eleven are reached from
        // `src/`; the other eleven are controller-facing request functions or external views not
        // referenced by protocol source. Of the eleven reached members, eight sit inside a
        // `try`/`catch` and three are called bare: `impairedBorrowerCount`, `impairedBorrowerAt`
        // and `recoverLoss`. The probe list below therefore remains exactly the bare three.
        //
        // **The probe reads the SHAPE of the failure, not its success, and that is what makes the
        // last two probeable at all.** A contract with no matching selector and no fallback reverts
        // with empty returndata; a contract that *has* the function and refuses reverts with four
        // bytes of error selector or a `Panic`. So `catch (bytes memory reason)` with
        // `reason.length == 0` distinguishes "not implemented" from "implemented and refused",
        // which a bare `catch` cannot.
        //
        // That retires the objection recorded here for `impairedBorrowerAt` - "an incoming pool has
        // an empty set, so index 0 reverts with a `Panic`, which is indistinguishable at this call
        // site from the missing selector". It is distinguishable: a `Panic` carries returndata. The
        // objection was sound about a bare `catch` and is what a probe of the right shape removes.
        //
        // `recoverLoss(0)` is refused by a conforming pool with `ZeroAmount()` - or with
        // `NotCreditManager()` when this setter runs before the pool has been pointed back here,
        // which is a legal wiring order - and either answer proves the selector exists. Shipping
        // `recoverLoss(0)` as a *success* probe would have rejected the real contract, which is why
        // both arms are run in `SetterGuards.t.sol` rather than only the refusal.
        //
        // The `recoverLoss` probe is the one non-view call in this list, so it is a genuine `CALL`
        // rather than a `STATICCALL`. It is not new exposure: this setter already reaches the same
        // pool non-view through `_pushLossReserves` on the line after it returns, and a conforming
        // pool reverts before writing anything. A `STATICCALL` was tried first and is wrong - the
        // pool's `nonReentrant` writes a slot before the body runs, so a static probe reverts with
        // empty returndata against the *real* contract and would refuse it.
        try ILenderPool(lenderPool_).impairedBorrowerCount() returns (uint256) {}
        catch {
            revert LenderPoolIncomplete();
        }
        try ILenderPool(lenderPool_).impairedBorrowerAt(0) returns (address) {}
        catch (bytes memory reason) {
            if (reason.length == 0) revert LenderPoolIncomplete();
        }
        try ILenderPool(lenderPool_).recoverLoss(0) {}
        catch (bytes memory reason) {
            if (reason.length == 0) revert LenderPoolIncomplete();
        }

        // Reached only when every clause above passed. The caller refuses any other answer.
        return WIRING_CHECKED;
    }

    /// @dev Every clause `setLiquidationAuction` owes before it moves the pointer, and no writes.
    ///      `current` and `incoming` are the outgoing and incoming auctions; `vault` is the
    ///      caller's vault immutable. Split out so the assignment and the event stay in
    ///      `CreditManager` where the storage is, and the checks - which touch no storage of the
    ///      caller's at all - live where the bytes are cheaper. See the note at the top of this
    ///      file on what `DELEGATECALL` preserves.
    ///
    /// @return attestation `WIRING_CHECKED`, which the caller asserts. See that constant. This is
    ///         the member that made follow-up item 2 severe: `CreditManager.setLiquidationAuction`
    ///         has no clause of its own, so a wrong-but-coded library address left the setter as an
    ///         unguarded assignment.
    ///
    /// @dev **AUDIT ROUND 25, FINDING F4: this member is no longer `view`, and that is deliberate
    ///      rather than incidental.** The `start` probe at the foot of the body calls a
    ///      state-changing selector, so the whole function had to drop `view` to compile - the same
    ///      trade `checkLenderPoolSwap` already makes for its `recoverLoss` probe, and for the same
    ///      reason: the real contract's `nonReentrant` writes a slot before the body runs, so a
    ///      `STATICCALL` reverts with empty returndata against the *genuine* auction and the probe
    ///      would refuse it. Nothing else about the function changed. Its only caller,
    ///      `CreditManager.setLiquidationAuction`, is an `onlyOwner` state-changing setter that was
    ///      never `view`, and the `DELEGATECALL` reaching this function was never a `STATICCALL`
    ///      either - see the note at the top of this file measuring that a `view` external library
    ///      function is delegatecalled identically to a non-`view` one, which is exactly why
    ///      removing the keyword changes no behaviour at any other line.
    function checkAuctionSwap(address current, address incoming, ICollateralVault vault)
        external
        returns (bytes32 attestation)
    {
        if (incoming == address(0)) revert ZeroAddress();
        if (current != address(0)) {
            (uint256 liveAuctions, uint256 openWorkouts) = _outgoingAuctionWork(current);
            if (liveAuctions != 0) revert AuctionHasLiveWork(liveAuctions);
            if (openWorkouts != 0) revert AuctionHasLiveWork(openWorkouts);

            // **Audit round 21, and the sibling clause of round 20's own fix.** The vault's twin
            // was taught to count the *lot* rather than the queue - "counting queue entries is not
            // the same as counting assets" - because `closeWorkout` pops the queue and leaves the
            // lot parked under the outgoing auction's ledger entry until the owner-gated
            // `disposeWorkoutLot` moves it. This setter was left reading the two counters that
            // change taught the vault not to trust, and the two pointers have to agree: `borrow`
            // and `liquidate` both compare this one against `vault.liquidationAuction()` and revert
            // `AuctionPointerMismatch` when they differ.
            //
            // MEASURED at round 21: after a forced `closeWorkout` both counters read 0 while
            // `vault.bondCount(auction)` read 100, the vault refused `AuctionHasLiveWork(100)` and
            // this setter succeeded - splitting the pair and taking **every new loan and every
            // liquidation in the protocol** offline until the lot was disposed and the vault's
            // setter followed. Two 48-hour timelock operations, out of one call that reported
            // success.
            //
            // Read off the vault rather than off the auction, for the reason the `riskParams` and
            // `navOracle` checks below give: the vault is the one contract in this graph that
            // cannot be replaced. `bondCount` is its own storage, so this is a plain getter that
            // cannot revert and needs no `try`, unlike the two counters above. It cannot deadlock
            // either - it refuses exactly the state the vault already refuses, and the disposal
            // that clears it is reachable in that state, so nothing reachable before this clause
            // is unreachable after it.
            uint256 heldLot = vault.bondCount(current);
            if (heldLot != 0) revert AuctionHasLiveWork(heldLot);
        }
        // The incoming check its twin on the vault already had. Without it this manager
        // alone could be pointed at an auction with no relationship to the collateral it
        // is authorised to write losses against - and the two pointers can be set
        // independently, in either order.
        address boundVault = ILiquidationAuction(incoming).vault();
        if (boundVault != address(vault)) revert LiquidationAuctionVaultMismatch(boundVault);

        // **Audit round 20, and read off the vault rather than off `riskParams` here.** The vault
        // is the one contract in the graph that cannot be replaced, so its answer is the reference;
        // this manager's own pointer only equals it because the constructor above insisted, and a
        // check that compares two replaceable contracts to each other can agree with itself while
        // both disagree with the collateral. Reading the reference directly costs one staticcall on
        // an `onlyOwner` path and removes the transitive step from the argument.
        //
        // This is a fourth bare selector on the incoming pointer, and it does **not** join the
        // three probes below. Those exist because `_impairmentFor` calls their selectors bare on a
        // never-blockable path, so an address that cannot answer bricks `repay` for everyone;
        // `riskParams()` is called here and nowhere else, so this call is its own probe.
        address auctionRisk = address(ILiquidationAuction(incoming).riskParams());
        if (auctionRisk != address(vault.riskParams())) revert LiquidationAuctionRiskParamsMismatch(auctionRisk);

        // **Audit round 21.** Read off the vault for the same reason, and it is not redundant with
        // the vault's own setter: the two pointers are set independently and in either order, so
        // this manager alone could otherwise be pointed at an auction pricing the lot off a feed
        // the collateral is not valued against - and this manager is the contract that books the
        // write-off when that lot sells short. `navOracle()` is called here and nowhere else on
        // this path, so like the line above it is its own probe and joins none of the three below.
        address auctionNav = address(ILiquidationAuction(incoming).navOracle());
        if (auctionNav != address(vault.navOracle())) revert LiquidationAuctionNavOracleMismatch(auctionNav);

        // **Every selector `_impairmentFor` calls, because it makes all of them bare and
        // un-`try`ed.** Reached unguarded from `_repay`, and so from `repay` and `repayFor` - the
        // path this file promises repeatedly is never blockable and deliberately not
        // `whenNotPaused`. An address that answers `vault()` but not one of these bricks every
        // repayment for every borrower it is asked about, repairable only by an `onlyOwner` call
        // that by go-live is a timelock.
        //
        // `EpochHarvester.setCustodyAdapter` already does this and says why: an address that
        // cannot answer should fail "at wiring time and under the owner's hand, rather than inside
        // the permissionless `harvest`".
        //
        // **Audit round 17: the first version of this guard probed one of the three, and not the
        // one called first.** It covered `recognisedRecoveryOf`, the member that had just arrived,
        // and left the two the path had always called. `_impairmentFor` reaches `workoutsOpenFor`
        // first and unconditionally for every borrower; `recognisedRecoveryOf` is reached only
        // when `auctionOf` is non-zero, which on a freshly wired auction is nobody. So the guard
        // read as done while the state it existed to prevent was still one call away - and that
        // state is unrecoverable, because this function's own first statement reads
        // `liveAuctionCount()` on the pointer it has just broken, and `CollateralVault
        // .setCreditManager` needs a zero total debt that repayment can no longer reach.
        //
        // Prevention is therefore the whole of the fix: there is no way back, so the only safe
        // thing is never to arrive. The three probes below are what make that true.
        //
        // **This list is `_impairmentFor`'s call set and has to stay that way.** It is the third
        // round in a row that a selector reached a never-blockable path without its probe. If that
        // function gains a fourth external call, it gains a fourth probe here in the same commit,
        // and a fourth rejection test beside the three that already pin these.
        //
        // **Round 24 read that promise too narrowly and it cost a finding.** The set that has to be
        // probed is every selector *this protocol* calls bare on this pointer, not every selector
        // *this function* does. `borrow`'s bare `creditManager()` is the one that was missed; the
        // block after these three is the probe it owed. Count from the call graph, not the file.
        //
        // Probed at `address(0)`, which can hold no auction, no workout and no recovery, so each
        // reads a value it discards and is testing only that the call answers at all.
        _probe(ILiquidationAuction(incoming).workoutsOpenFor);
        _probe(ILiquidationAuction(incoming).auctionOf);
        _probe(ILiquidationAuction(incoming).recognisedRecoveryOf);

        // **AUDIT ROUND 24, FOLLOW-UP ITEM 3. The fourth probe the comment above asked for, in the
        // commit that owed it.** That paragraph promised "if that function gains a fourth external
        // call, it gains a fourth probe here in the same commit" - and it was already owed, because
        // the fourth call is not `_impairmentFor`'s. `borrow` reads
        // `ILiquidationAuction(auction).creditManager()` bare inside its `vaultAuction != address(0)`
        // branch and reverts `AuctionPointerMismatch` on the answer, and no probe anywhere covered
        // it. So the promise has to be read as *every* selector this protocol calls bare on this
        // pointer, not every selector one function calls bare on it; a per-function reading is what
        // let this one through four rounds in a row.
        //
        // MEASURED at round 24 with an eight-selector stub - one answering everything both setters
        // probe and not this - it installed cleanly through the vault's setter and this one, and
        // then **every borrow in the protocol reverted**, reproduced for a second borrower.
        // Recovery is repointing both pointers: two 48-hour timelock operations with all borrowing
        // offline in between.
        //
        // **A probe, not an equality assertion, and the difference was checked rather than
        // assumed.** `creditManager` on a real auction is a plain public `address` starting at
        // zero, set afterwards by `setCreditManager`, whose own `CreditManagerNotLive` clause
        // requires the vault to already name the incoming manager. So the legal wiring order is
        // this setter first and the auction's return leg second, which is the order `DeployBase`'s
        // wiring uses and the order every fixture in the tree uses. Requiring
        // `creditManager() == address(this)` here would
        // refuse the only order that works and weld the pair shut, which is the
        // mutually-unsatisfiable window this codebase has already shipped three times. Existence is
        // the whole of the question: an address that answers cannot brick `borrow`, and an address
        // that cannot answer bricks it for everybody.
        try ILiquidationAuction(incoming).creditManager() returns (address) {}
        catch {
            revert LiquidationAuctionIncomplete();
        }

        // **AUDIT ROUND 25, FINDING F4. The fifth bare selector, and the round after the fourth.**
        // Round 24 rewrote the rule two blocks above into "every selector *this protocol* calls
        // bare on this pointer, not every selector *this function* does" and then enumerated the
        // set one selector short. `liquidate` reads
        // `ILiquidationAuction(auction).start(borrower, msg.sender)` bare - unguarded, with its
        // return value captured as the key the bounty escrow parks against - and nothing anywhere
        // probed it. Five rounds running now that a bare selector arrived ahead of its probe, which
        // is why the enumeration below is written out rather than left to be re-derived.
        //
        // MEASURED at round 25: a stub answering the nine selectors both setters otherwise probe
        // and not this one installed through *both*, and on a genuinely liquidatable position
        // `liquidate(alice)` then reverted with empty returndata for two independent callers.
        // Recovery is repointing both pointers - two 48-hour timelock operations with liquidation
        // offline in between, which is the same severity statement round 24 wrote for
        // `creditManager()`, over a worse window: while liquidation is off, an underwater position
        // cannot be seized at all and the lenders carry the whole of the drift.
        //
        // **`ILiquidationAuction`'s call set, counted from the type as round 22 insists.** Fifteen
        // members. `cancel`, `bid`, `expireToWorkout` and `currentPrice` are never called by this
        // protocol - they are the outside world's entry points - and `liveAuctionCount` and
        // `openWorkoutCount` are read on the OUTGOING pointer inside `_outgoingAuctionWork`'s
        // `try`, which is round 19's finding and not this one. Of the rest, `vault`, `riskParams`
        // and `navOracle` are called by this very function and are their own probes; that leaves
        // `workoutsOpenFor`, `auctionOf`, `recognisedRecoveryOf`, `creditManager` and `start` as
        // the selectors this protocol calls bare on an installed pointer. The first four are the
        // four blocks above. `start` is the fifth, and this is it.
        //
        // **Why probing at `(address(0), address(0))` is safe on the real contract, checked at the
        // ordering rather than assumed.** `LiquidationAuction.start` refuses in this order:
        // `msg.sender != creditManager` -> `NotCreditManager()`, then a zero `borrower` or `caller`
        // -> `ZeroAddress()`. Both arms are reached before any write, so the probe can neither open
        // an auction nor move a bond however this pointer is wired. Both arms are also *legal*
        // wiring states rather than failures: `NotCreditManager()` is what a freshly deployed
        // auction answers, because its own `creditManager` is still zero until `setCreditManager`
        // runs afterwards - the order `DeployBase` and every fixture in the tree use - and
        // `ZeroAddress()` is what an auction already pointed back at this manager answers, which is
        // the state a re-point onto an existing auction is in. MEASURED: `0x02667ef8` and
        // `0xd92e233d`, four bytes each, against the stub's zero. So the `reason.length == 0` shape
        // the other probes use works here unchanged, and both arms are pinned by tests in
        // `SetterGuards.t.sol` - shipping only one of them is how a probe ends up rejecting the real
        // contract.
        //
        // **A CALL, not a STATICCALL, which is what costs this function its `view`.** `start` is
        // `nonReentrant` and that modifier writes its slot before the body runs, so a static probe
        // reverts with empty returndata against the genuine auction and would refuse everything.
        // Identical to the `recoverLoss` probe in `checkLenderPoolSwap`, down to the reasoning, and
        // it is not new exposure: this setter is `onlyOwner` behind a timelock, and the revert above
        // undoes the reentrancy slot along with everything else.
        //
        // **A probe, not an equality assertion**, for the reason the `creditManager()` block gives
        // at length: requiring a particular answer here would require the auction to be pointed back
        // at this manager before this setter runs, and the auction's own `setCreditManager` requires
        // the vault to name the incoming manager first. That is the mutually-unsatisfiable window
        // this codebase has shipped three times. Existence is the whole of the question.
        try ILiquidationAuction(incoming).start(address(0), address(0)) returns (uint256) {}
        catch (bytes memory reason) {
            if (reason.length == 0) revert LiquidationAuctionIncomplete();
        }

        // Reached only when every clause above passed. The caller refuses any other answer.
        return WIRING_CHECKED;
    }

    /// @dev **Audit round 19: the two reads below are on the OUTGOING pointer and were bare.**
    ///      Every probe in this file enumerates the *incoming* address's selectors, and this setter
    ///      says its list "has to stay that way" while its own first statements call two selectors
    ///      on the address it is replacing. Measured: a stub implementing only `vault()` installs
    ///      cleanly, and afterwards this function reverts forever - and on the vault's twin so does
    ///      `setCreditManager`, which is the escape from every other unrecoverable state there.
    ///      Fourth round running that a bare selector arrived ahead of its probe.
    ///
    ///      **Why treating an unanswerable outgoing auction as "no work" is the safe direction, and
    ///      not merely the convenient one.** A real `LiquidationAuction` answers both of these with
    ///      plain getters over storage - `liveAuctionCount` is a public `uint256`, `openWorkoutCount`
    ///      reads an array length - and neither can revert. So the only address that fails to answer
    ///      is one that was never a real auction, and an address that was never a real auction is
    ///      holding no live work for this guard to protect. Catching therefore unblocks exactly the
    ///      repoints that were protecting nothing, and cannot loosen the guard over a genuine
    ///      auction. It only ever makes a repoint more possible, so it cannot create the
    ///      mutually-unsatisfiable window this codebase has shipped three times.
    function _outgoingAuctionWork(address current) private view returns (uint256 live, uint256 open) {
        try ILiquidationAuction(current).liveAuctionCount() returns (uint256 n) {
            live = n;
        } catch {}
        try ILiquidationAuction(current).openWorkoutCount() returns (uint256 n) {
            open = n;
        } catch {}
    }

    /// @dev The three `setLiquidationAuction` completeness probes, which differed only in which
    ///      member they called: same signature, same argument, same error. Taking the member as an
    ///      external function pointer keeps the `try`/`catch` exactly as it was rather than
    ///      swapping it for a low-level call, so the probe still reads a genuine revert and not a
    ///      returndata length.
    ///
    ///      **Why the extcodesize difference cannot bite here.** A member call and a call through
    ///      a function pointer both check that the target has code. By the time these three run,
    ///      `setLiquidationAuction` has already called `vault()`, `riskParams()` and `navOracle()`
    ///      on the same address and taken their return values, so an address with no code has
    ///      already reverted three lines earlier and never reaches this. The probes' own tests -
    ///      one per member, in `CreditManager.t.sol` - all use fixtures that are contracts.
    function _probe(function(address) external view returns (uint256) member) private view {
        try member(address(0)) returns (uint256) {}
        catch {
            revert LiquidationAuctionIncomplete();
        }
    }

    /// @dev The delivery leg every principal path shares, so they cannot disagree about what
    ///      "delivered" means. Approves, calls, measures the balance delta. **Moves no counter of
    ///      its own**, which is what lets the parked path reuse it: `settlePrincipal` and
    ///      `setLiquiditySource` are spending `pendingPrincipal` down, while `flushPrincipalTo` is
    ///      spending `owedToSource` down and zeroed its entry before it got here. Audit round 23
    ///      finding 1 records the naive version of that reuse - routing the flush through
    ///      `_deliverPrincipal` as it stood - which would have underflowed or corrupted the other
    ///      counter, so the split is the point rather than tidiness.
    ///
    ///      Verify the pull rather than assume it, mirroring what `borrow` does on the
    ///      inbound leg. Zeroing the counter before an unverified transfer would let a
    ///      source that pulls short silently forgive the difference, stranding USDC that
    ///      no counter claims.
    ///
    ///      Clamped at both ends now, matching `LenderPool.impair`: a source that *pushes* USDC back
    ///      during `repayPrincipal` made the low end underflow and revert, and the high end is the
    ///      same clamp from the other side - a figure above what was owed describes no reachable
    ///      state, and a clamp at only one end is one refactor away from being no clamp at all. Zero
    ///      is the right answer on the low branch rather than a fudge: a source that returned more
    ///      than it took has delivered nothing net.
    ///
    /// @param bestEffort When true a refusing source is tolerated and reported as nothing delivered,
    ///        rather than reverting the caller. `setLiquiditySource` and `flushPrincipalTo` set it,
    ///        because a revert in either would block the escape from the very source that is
    ///        refusing - audit round 22, finding 5.
    ///
    /// @return attestation `WIRING_CHECKED`, which the caller asserts. **Audit round 25 finding 1,
    ///         the round's one High.** This member was left unattested on the argument that its
    ///         returndata was always decoded anyway - but what it returns is a *measurement*, and a
    ///         forged measurement of full delivery is worth more to an attacker than a forged
    ///         boolean. See `WIRING_CHECKED` for the two executions: `pendingPrincipal`
    ///         5,000,000,000 -> 0 with every balance unmoved, and the same substitute burning a
    ///         5,000.000000 `owedToSource` entry through `flushPrincipalTo`.
    /// @return delivered What actually arrived, by balance delta, clamped at both ends.
    function pullPrincipal(IERC20 usdc, address source, uint256 amount, bool bestEffort)
        external
        returns (bytes32 attestation, uint256 delivered)
    {
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.forceApprove(source, amount);
        bool ok = true;
        if (bestEffort) {
            // Low-level so a reverting source cannot brick the repoint.
            // slither-disable-next-line unchecked-lowlevel
            (ok,) = source.call(abi.encodeCall(ILiquiditySource.repayPrincipal, (amount)));
        } else {
            ILiquiditySource(source).repayPrincipal(amount);
        }
        usdc.forceApprove(source, 0); // leave no standing allowance

        // `ok` and the delta together, exactly as `DirectCallAdapter._trySweepUsdc` reads its own
        // low-level call. The flag alone is not a measurement - it says only that the call did not
        // revert - and on the bare branch it is unconditionally true, so the delta is what decides
        // in both cases.
        uint256 balanceAfter = usdc.balanceOf(address(this));
        delivered = ok && balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (delivered > amount) delivered = amount;

        // Reached only when the approve, the call and both balance readings above actually
        // happened. The caller refuses any other answer. See `WIRING_CHECKED`.
        attestation = WIRING_CHECKED;
    }

    /// @dev Does `source` still name this manager as the counterparty of its own principal book?
    ///
    ///      The one question that decides whether a bare push is safe. Both in-tree sources keep a
    ///      `creditManager` pointer and gate `repayPrincipal` on it; a source that has moved on is
    ///      no longer recording this manager's loans, so pushing USDC at it cannot double-count
    ///      anything, while a source that still names this manager is the case finding 1 is about.
    ///
    ///      **Fails closed, unlike `_fundsAsALenderPool`, and the difference is deliberate.** That
    ///      probe fails open because a wrong answer only mis-routes a loss between two addresses the
    ///      owner chose. Here a wrong answer in the "still ours" direction merely refuses a payment
    ///      that can be retried, whereas a wrong answer the other way pushes money into a book that
    ///      will double-count it forever. So an address that cannot answer at all is treated as
    ///      *not* ours - which is also what keeps the round-22 escape intact for any third-party
    ///      source that never had the pointer.
    ///
    ///      A raw `staticcall` rather than an interface: adding `creditManager()` to
    ///      `ILiquiditySource` would oblige every implementation and every mock to carry it, for a
    ///      question only this one function asks.
    ///
    ///      **Attested even though its one caller already asserted the tag two statements earlier.**
    ///      `flushPrincipalTo` calls `pullPrincipal` first and unconditionally, so on today's call
    ///      graph the address behind this `DELEGATECALL` has already been proved to be this library.
    ///      That is an argument about statement order in another file, which nothing checks and a
    ///      refactor can silently invert - and reading a promise per-function rather than per-type
    ///      is what let round 24's fourth probe through four rounds running. `WIRING_CHECKED` states
    ///      the rule at the type instead. It also happens to be the member that made
    ///      `CreditManager` 55 bytes *smaller*, which is recorded there.
    ///
    ///      🟩 **And it is no longer pinned only as defence in depth.** Round 26 follow-up item 3,
    ///      carried through rounds 27 and 28, was that this attestation had no falsifier which did
    ///      not run through the `pullPrincipal` assertion two statements earlier - so *"a round that
    ///      touches the `pullPrincipal` assertion silently removes this one's coverage"*. Closed by
    ///      a **selector-aware** substitute: `AttestsThePullAndForgesTheSourceQuestion` in
    ///      `CreditWiringLinkage.t.sol` returns the real tag from `pullPrincipal` and a zero tag
    ///      from this member, with `test_R28_premise_...` proving the first half is accepted.
    ///      MEASURED with **only** this member's `_requireWiringRan` removed: `owedToSource`
    ///      5,000,000,000 -> 0, `totalOwedToSources` -> 0 and **5,000.000000 USDC bare-transferred**
    ///      to a source whose `creditManager()` still names this manager. Restored, the flush
    ///      reverts `WiringLibraryUnverified(0)` and all three figures stand still.
    function sourceStillAnswersToUs(address source) external view returns (bytes32 attestation, bool ours) {
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory data) = source.staticcall(abi.encodeWithSignature("creditManager()"));
        if (ok && data.length == 32) ours = abi.decode(data, (address)) == address(this);

        // Reached only when the staticcall above was actually made. Single exit, for the reason
        // `fundsAsALenderPool` gives.
        attestation = WIRING_CHECKED;
    }
}
