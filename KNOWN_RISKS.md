
# Known risks and activation gates

This is the launch-critical and material current security posture for the public contracts. The
core protocol executable logic in this repository is current as of 2026-08-31, and everything
below is written against it. Analysis published here before that date was written against an
earlier lender pool, credit manager and collateral vault, and does not describe this source. This record is organised by present effect, not by discovery date. Historical internal review notes are
in [`AUDITS.md`](AUDITS.md); the code-level integration tour is in [`REVIEW.md`](REVIEW.md).
The section "Open findings from internal review round 45, at the audit commit" was added on
2026-09-07 and is written against the same source at commit b66023d, the commit handed to the
external auditors.

Internal adversarial review, unit tests, invariant campaigns and mainnet fork tests are evidence, but
they are not an external audit.

## Gate definitions

- An **activation blocker** prevents wiring or funding `LenderPool`, including with the author's
  capital.
- A **third-party capital gate** is additional. Even after the activation blockers close, no public,
  DexFi or Bond Fund capital is accepted before an external audit.
- A **residual risk** is a known limitation that must stay disclosed and be reconsidered at go-live,
  even when it is not one of the three current activation blockers.

Closing the three remaining pool blockers is necessary but not sufficient for mainnet. The governance, wiring,
deployment and review gates below still apply.

The merged principal-accounting and active-tail entry-pricing mechanisms require a fresh internal
follow-up review before any Phase-4 wiring or funding. That review must rerun the prior attack bundle
and re-audit their rounding, sequencing, impairment, frozen-stream, queue and recovery interactions.

## Deployment facts

| Item | Current fact |
|---|---|
| Base mainnet | No Recoup contracts are deployed |
| Base Sepolia | The protocol is deployed against mock USDC, bond and farm contracts |
| `LenderPool` | Deployed on Sepolia, empty, and not wired as `CreditManager`'s liquidity source in the protocol-to-pool direction; the pool's own pointers to the manager and the harvester are set, and it is open to any depositor at the full 25,000 USDC cap |
| Live `LenderPool` bytecode | **Predates this source.** Read by selector at block 46291047, it still carries `serviceQueue`, `queueHead`, `queueLength`, `queuePosition`, `queueEntry` and `netDeposits`, the round 21 F7 and round 22 F3 mechanisms this file calls CLOSED below and this source has removed, and lacks 26 selectors this source has, `pause` and `guardian` among them, so there is no pause lever on it short of a redeploy. Every `WirePhase4` entry point, `assertOnly()` included, reverts against the live set because the graph assertion calls `guardian()` and `mintReceiverImplementation()` on contracts that do not have them. `pendingLenderYield` on the live pool reads 124.885415 USDC parked with nobody to deliver it to |
| Current testnet liquidity | Supplied by `TreasuryLiquiditySource`, not `LenderPool` |
| Current-source parity | **None, deliberately.** This source is current as of 2026-08-31 and the Sepolia deployment predates it. The last comparison, on 2026-08-21 against an older public tree, passed the strict length-and-metadata gate for 3 of 13 checked deployments (the three mocks); that figure describes a tree this one has replaced and is not re-run here. Treat the deployment as historic and verify against the explorer, not against this source |
| External audit | In progress from 2026-09-07 over `LenderPool`, `CreditWiring`, `TreasuryLiquiditySource`, `ProtocolFeeSplitter`, `Config` and `LtvMath` at commit b66023d; not completed |
| Third-party funds | Not accepted |

The mock assets have no real value, and their mint and test-control functions are permissionless.
Explorer verification confirms the source attached to the deployment-era bytecode; it does not mean
the deployed set matches today's source. Eight protocol contracts had the same deployed byte length
but different metadata; `LenderPool` and `ReferralRegistry` also differed in size. Metadata includes
source hashes, so equal length with different metadata is not by itself proof of an executable logic
change, but it does mean this public tree is not the recorded deployment snapshot. The deployment
record is [`deployments/base-sepolia.json`](deployments/base-sepolia.json).

## `LenderPool` findings, and what the current source does about them

The three findings this section used to list as activation blockers were written against a
`LenderPool` that this source replaces. Two are closed by construction and one is narrowed to a
disclosed residual. Each claim below names the function that carries it, so it can be checked
against the source rather than believed.

**Closing them does not open activation.** The third-party capital gate is separate and unchanged:
no public, DexFi or Bond Fund capital is accepted before an external audit, whatever this section
says.

### Round 22 F3: principal-cap accounting. CLOSED, by removing the mechanism

F3 was about compressing transferable, differently priced share lots into scalar principal units,
and its residuals were properties of those units: dust redemptions eroding the cap by an asset-wei
at a time, a double-ceiling boundary, and a principal-unit quotient that repeated loss-and-refill
cycles could grow until issuance exhausted its integer range.

There are no principal units in this source. Deposit-cap usage is
`max(accountedCash + outstandingPrincipal - totalClaimable, 0)` in `depositCapUsage()`, which
follows the recognised entry book rather than holder lots, controller order or raw token balance.
The residuals above cannot be reproduced against it because the quantity they were about does not
exist.

What replaces the overflow bound is explicit rather than emergent. The entry quotient is bounded by
`2^128` shares per asset, and three things hold that bound: `minimumEntryAssets()`,
`entryPriceCashReserve()` while principal is at risk, and `maximumShareSupply()`. Repeated losses
taper lending rather than multiplying a quotient toward overflow.

Cash is now accounted rather than inferred. `_accountedCash` changes only through explicit pool
flows, so a raw token transfer can replace missing backing up to that stored book but cannot lift
value above it; anything above is `unmanagedSurplus()` and never enters cap usage. External balance
loss is visible immediately through `cashDeficit()`, entry stays closed while a deficit remains, and
the two repair doors, `coverClaimDeficit` and `coverEntryPriceDeficit`, are deficit-capped: partial
cover is allowed and excess is refused.

Closed in this source, not on the testnet: the Sepolia `LenderPool` predates this source and still
carries `netDeposits`, the principal book these residuals were properties of and which this source has removed, until it is redeployed.

### Round 21 F7: a queued withdrawal reserving against the whole book. CLOSED

F7 was a real and measured exposure and the numbers were not wrong. The pool valued a queued exit
against the whole book, loans included, then subtracted that figure from cash alone, so the
over-reservation multiple equalled the pool's leverage. At 6.00x a holder of a sixth of the book
took every other lender's `maxWithdraw` to zero, and 1.67% of the book halted borrowing. Fifteen
candidate fixes were built and refused across five audit rounds, every one of them changing a
reserve that neither computing function read.

The mechanism those numbers describe is not in this source. `_queueCashReserve` is
`mulDiv(executableCash, requestedShares, totalSupply(), Ceil)`: a pro-rata slice of executable
**cash**, taken per controller, with the entry-price reserve removed first because it is senior
while principal can still be lost. A holder of a tenth of the supply reserves a tenth of the cash.
The leverage multiplier is gone by construction, not by tuning, which is why the fifteen refusals do
not apply to it.

Closed in this source, not on the testnet: the Sepolia `LenderPool` still exposes the
`serviceQueue` family, removed from this source, and runs the reserve these numbers describe, until it is redeployed.

### Round 22 F12: uncollectable claims. Authority half CLOSED, receiver half ACCEPTED

F12 had two halves. Servicing was permissionless, so any caller could burn a lender's shares and
strand the proceeds; and a claim recorded for a receiver that cannot be paid is unrecoverable.

The first half is closed. `serviceWithdrawalRequest` reverts `UnauthorizedRequestOperator` unless the caller is
the controller or an operator that controller approved through `setRequestOperator`, so nobody else
can force service. `claimFor` provides the delegated collection the old text asked for.

**The second half is accepted and disclosed rather than fixed.** If the asset itself refuses to
transfer to the receiver, for instance because that address is blocked at the token, the claim
cannot be collected and the shares are already burned. Service is still irreversible before
collectability is known. That is a residual risk of this design, it is not closed, and a reviewer
should treat it as open.

### Round 22 F11 and F6a: closed in an earlier sync

F11 rated non-epoch recovery cash on the yield-epoch clock, so the same 400 USDC recovery streamed
over five days after a recent epoch and over 180 days after a drought. F6a had `_rateStream` floor a
new stream's duration at the old one's remaining time, letting repeated deliveries postpone a tail
indefinitely. Both are fixed in this source.

## Material residual risks

### Round 17: liquidation marking is not atomic with the price update

A loss-making position carries no impairment until liquidation is called. The prepaid liquidation
bounty and the bounded, in-place re-strike mechanism remove the old unbounded liveness failure, but
they do not remove transaction ordering. A lender can compete with the liquidator immediately after
the NAV update that makes the position eligible.

The remaining window is bounded to transaction ordering, not eliminated. Closing it would require a
different expected-recovery oracle or a change to the immediate-liquidation rule.

### Round 22 F10: delivered-cohort protection is not historical entitlement

During an active stream, `previewDeposit`, `previewMint` and `maxMint` price entry against released
assets plus the projected unreleased tail. Capital arriving after delivery therefore prepays its
share of that tail instead of diluting holders already present.

The scope is deliberately narrower than historical loss-bearer ownership:

- Capital arriving before delivery can participate if it holds through the stream.
- A holder exiting before release does not retain a sidecar claim.
- A post-delivery entrant that exits early can receive less than deposited principal because its
  entry premium stays with the remaining holders.
- A frozen backlog with `yieldRate == 0` is excluded until a later delivery re-rates it.

A true loss-era entitlement system would require separate snapshot, claim and queue-ownership
semantics.

## Open findings from internal review round 45, at the audit commit

In the week before the external audit, a twelve-reader internal adversarial pass was run over the
six files in the audit scope, and the findings below came out of it. Each one has an executed
reproduction in a test unless it is marked as a lead. **None of them is fixed in this source, and
that is deliberate**: a fix written the week before an audit is what the audit exists to check, so
they are disclosed here and to the auditors as known issues, with the candidate fixes named and
their status given honestly. They are written against commit b66023d. Severities are assigned
by the author, not by an auditor.

### A frozen yield pot over a dust supply bricks the pool. Medium-high

When a burn leaves `0 < totalSupply < MIN_SUPPLY_FOR_YIELD` while a yield stream is live,
`_update` freezes the whole unreleased pot with no clock that ever thaws it. `_entryAssets` then
prices that frozen pot into every later entry against the dust supply, so the entire deposit cap
mints fewer shares than the ten-million-share floor, `distributeYield` and `lend` revert
`NoSharesOutstanding` from then on, and each entrant forfeits roughly the pot to the virtual shares
and the dust holder. The honest route is the last lender leaving during a stream: `withdraw(maxWithdraw)`
leaves 999 shares, and below par a single `redeem(maxRedeem)` leaves about 112 because `_maxRedeem`
floors. The deliberate route is a one-wei `mint(1)` before the last honest lender leaves. About
3 USDC of unreleased yield over one share is enough at the 25,000 cap. The same state is written by
the sub-floor branches of `recoverLoss` and `repayPrincipal` with no stream live. There is no owner
lever. Two fixes are measured and neither is chosen: derecognise the pot on a sub-floor freeze
(reverses the F10 protection for sub-floor cohorts), or thaw it on the next mint while frozen
(about 5 bps of virtual-share leak). A supply-gated thaw was measured inert.

### A socialised loss reopens the deposit cap, and the recovery of that loss is split with whoever fills it. Medium

`depositCapUsage` is `_accountedCash + outstandingPrincipal - totalClaimable`, so `socialiseLoss` of an amount L
frees L of headroom. A stranger deposits into that headroom at the fair post-loss price, and when
the closed workout's redemption lands later through the permissionless `workoutSettleAfterClose`
into `recoverLoss`, the stranger takes 94 to 97 percent of it (measured on 6,000 and 4,000 USDC
recoveries; with no entrant the loss bearer receives all of it). The epoch leg refuses a pot larger
than the pool; the recovery leg has no such guard. This is distinct from the F10 residual above:
the cap term that bounds an entrant is the term the loss opens. The obvious fix, copying
`YieldExceedsCapital` onto `recoverLoss`, was built and refused: it reverts the whole settlement
while the pool is smaller than the recovery. Candidates, neither built: cap the streamable amount at
`_totalAssets` and route the excess to the insurance fund or park it; or measure cap usage gross of
unrecovered loss, which still hands the stranger about 60 percent.

### A recovery arriving after every lender has left is derecognised while `lifetimeLossRecovered` rises. Medium

Both zero-supply branches of `recoverLoss` and `repayPrincipal` pull the USDC and immediately
reduce `_accountedCash` by the amount with no destination. On the shipped deployment graph, the
route `workoutSettleAfterClose` to `recoverWrittenDownLoss` to `recoverLoss` after the sole lender
has exited at par leaves the recovery as `unmanagedSurplus`, with no sweep, no owner rescue and no
later cohort able to recognise it, while `lifetimeLossRecovered` still counts it as recovered. The
control with any share outstanding preserves the tranche. Bounded by the written-down loss, and it
is the natural sequence on a one-lender beta. Candidate fixes, not sign-checked: route to the
insurance fund when the pool's supply is zero inside `CreditManager.recoverWrittenDownLoss`, or
revert `NoSharesOutstanding` so the tranche stays with the caller. The minimum is to stop counting a
derecognised amount as recovered.

### The epoch leg of `_rateStream` re-rates a running recovery stream over a whole harvester drought. Medium-low

Rule 1 takes `max(elapsed, D, remaining)` over the whole pot including a recovery tail that is
deliberately rated over its own five-day floor. After sixty quiet days a `distributeYield` of any
size (one wei reproduces it) slows a running recovery stream fifteen times and pushes
`yieldStreamEndsAt` to `now + 61 days`; a lender exiting inside that window forfeits 3,687.67 of a
5,000 USDC recovery share to the stayers. It is the F11 harm one composition later, recovery first
and drought epoch second, which the stream-clock tests cover only from cold. Realised by a voluntary
exit; the triggering block is the harvester's or a stranger's `flushLenderYield`. The fix is not
sign-checked: bounding the epoch leg by the funded amount preserves the recovery here but lets a
drought epoch on a large tail pay out faster than rule 1 intends, so the honest fix is two rates.

### Recovery of a written-down loss is undeliverable after a manager migration. High

`LenderPool.recoverLoss` accepts only the manager the pool currently points at, and
`setCreditManager` is allowed to move that pointer while a recovery is still owed. After a legal
migration, `CreditManager.lossBearerOf` still names this pool but the pool refuses the recorded
bearer with `NotCreditManager`, so the recovery is undeliverable forever. The migration probe in
`checkLenderPoolSwap` treats that revert as a pass, by comment; no wiring satisfies both the owed
tranche and the new book at once; and the docstring's "retry once repaired" is unreachable after a
single borrow through the replacement, because pointing the pool back is refused with
`PrincipalOutstanding`. Executed by four independent readers. The "Recovery-era binding" row under
"Oracle, wiring and migration" below understates this: it is not a misroute, it is a permanent
refusal. The auction-side twin of this defect is fixed in source not yet synced to this repository.
The pool-side fix is one sentence and is not in this source because the file is under audit:
`recoverLoss` should accept a previously recognised manager, which is the fallback the principal
leg already has and the loss leg does not. Three manager-side workarounds that avoided touching the
pool were built and all three were refused by execution - one turns a permanent refusal into a
permanent loss and the other two can never be discharged.

### The withdrawal-request "reserve" is a per-call pro-rata bound, not a reservation. Documentation

`_unreservedIdle` is the executable balance less the ceiling of executable times queued over supply, re-derived on every call, so
a non-requester can unwind the reserved cash to 0.011 percent of itself in twelve fair-priced
redeems while the requester's whole-request value stays exactly at book. The request door caps a
controller at their own fraction of cash; the sync door caps a holder at all cash not reserved by
someone else (114.59 against 236.30 USDC in the same state). The per-call bound is the intended
semantics, and no code change is proposed: a checkpointed cash floor is the refused F7 shape. What is
wrong is the wording of the `queueCashReserve`, `unreservedIdle` and `available` docstrings in
`LenderPool`, which overstate it as a reservation; they are left as they are in this source because
the file is under audit, and are corrected at fix verification.

### `CreditWiring.sourceStillAnswersToUs` reverts instead of answering false on a dirty word. Low

`abi.decode(data, (address))` validates the high bits, so a source that answers with a 32-byte word
carrying any high bit set makes the check revert rather than answer `false`, while the docstring says
an address that cannot answer is treated as not ours. Reached only through
`CreditManager.flushPrincipalTo` against an owner-installed source, so the amount owed to that source
is un-flushable while it answers that way. The one-line fix, decoding as `bytes32` and comparing
against `bytes32(uint256(uint160(address(this))))`, is measured false on both hostile shapes and true
on the control; its byte cost is unmeasured. A related note: a decode failure inside a
`try ... returns (...)` is not caught, so `fundsAsALenderPool` and `checkLenderPoolSwap` revert with
empty return data on a fallback that returns nothing, outside the `catch`; that is the safe
direction and the file's "a silent contract fails open" sentence is wrong on direction.

### `deposit` can revert for an amount below `maxDeposit`. Low, an integrator hazard

`LenderPool` floors shares in `_entryToShares` with a decimals offset of three, so once the entry
price is above one asset-wei per share, a deposit below `previewMint(1)` rounds to zero shares.
`maxDeposit(receiver)` is a true maximum: `_maxDeposit` only checks that the maximum itself mints at
least one share, so there are amounts `x < previewMint(1)` for which `maxDeposit(receiver) > 0` and
`deposit(x, receiver)` reverts. It reverts in `_deposit` with the generic `ZeroAmount()` and takes
nothing, where stock OpenZeppelin 5.6.1 would take the assets and mint nothing. The
three-argument doors `deposit(assets, receiver, minShares)` and `mint(shares, receiver, maxAssets)`
report `ZeroAmount()` for a sub-floor amount rather than `SharesBelowMinimum`, because the guard
fires before the bound is read. The floor is `previewMint(1)`, with no dedicated view and no distinct
error. The shape was found in the invariant model first (one sequence in 14,143 calls, which every
other invariant ran green) and then confirmed in the production code by reading. An integrator that
reads `maxDeposit(r) > 0` and assumes every smaller amount is accepted is wrong below the floor. A
distinct floor error is deferred until after the audit.

### Lead, not a finding: `sweepWorkoutYieldToInsurance`

`sweepWorkoutYieldToInsurance` is in `LiquidationAuction`, outside the audit scope. Two readers
independently thought it shortcuts the round 22 F18 bound for gas, and one found a dead
`NothingToClaim` line beside it. F18 is the double-booking bound in the table below, and a sweep
that shortcuts it would be the same money counted twice from the other end, landing in the pool's
numbers. Nobody executed it. It is recorded here as a lead so that it is not lost, not as a finding.

### A forced workout close socialises a loss the lot's own accrued yield would cover. Medium, found in internal review round 54, outside the audit scope

Found the night before the audit began, in `LiquidationAuction` rather than in the six audited
files, and recorded here because it lands in the pool's numbers. When a workout closes forced,
`closeWorkout` calls `writeDownLoss` on the residual before the lot's own accrued yield, which is
sitting on the auction at that moment, is used to cover it. The funder therefore bears the whole
residual, and one block later `sweepWorkoutYieldToInsurance` moves that same yield into the
insurance fund, so the funder is short by exactly what insurance gains. Executed in a self-contained
test: one 100-bond lot in workout out of 200 staked with a 1,000.000000 epoch streamed during the
window, the lot's accrual was 499,999,999, the residual 628,750,000, the write-down 628,750,000 with
nothing from insurance, and the sweep then banked 499,999,999. With the pool as funder that comes
through `socialiseLoss` and reduces `outstandingPrincipal` by more than it needed to. The bound is
what streams to the lot over the auction plus the workout window, up to about fourteen days. Both
pre-close sweeps refuse an open lot's accrual by design, so no order of permissionless calls puts
the yield in front of the write-down; the fix is to have the forced close spend the auction's free
balance, the closing lot's own accrual included, before socialising, and it is built, sign-checked
and queued on the auction side rather than shipped, so the audited tree does not carry it.

### Tooling coverage on `LenderPool`

- Forge's `uninitialized-state` lint skips any contract containing inline assembly, per contract,
  and `LenderPool` has one assembly block (`_tryRawBalance`, one `mload`), so a clean lint over
  `src/` says nothing about this file. It was checked by hand instead: 25 storage declarations, all
  with at least one writer, four seeded away from zero and three of those because zero would be
  wrong for them. Over an assembly-free copy the lint reads the file and reports nothing.
- `missing-events-arithmetic` is excluded from the lint set because it aborts on `LenderPool`. The
  abort is the linter's: it doubles a pending-write list at every fall-through `if`, so K sequential
  `if`s after one un-emitted write cost it 2^K records, and a 122-line contract reproduces the abort
  at K=32 on an allocation of exactly 2^32 times 12 bytes while a 13,076-line branchless contract
  lints in under a second. There is no result for that lint on this file.
- Slither has not run on this tree. Its own `uninitialized-state` is the detector this file has
  most wanted a reading from.

## Other pre-launch risks and dependencies

### Referral source fixed through partner self-registration; live deployment remains disabled

Delegated `registerFor(bytes32,address)` and the registry-only `ZeroAddress` error are removed. The
remaining public registration function derives the owner from `msg.sender`, so a partner's payout
wallet or Safe must call `register(bytes32)` before its code is published. A raw call to the former
`0x791d1a9e` selector reverts with empty data and leaves both mappings unchanged, and a contract
wallet can self-register and resolve as the payout address. The storage layout remains the two
existing mappings in slots 0 and 1.

The standalone deploy script permits local chain ID 31337 for tests and rehearsal. Every non-local
chain reverts with `LiveDeploymentDisabled` before the legacy confirmation phrase is considered, so
that phrase cannot bypass the gate. This source correction is not authorisation for a public-chain
transaction.

### The deployed Sepolia `ReferralRegistry` is stale

The committed address remains `0x30B9B1D7A40aa7D14613cb1742EFaaB155dC84a0`. Its 1,489-byte
runtime predates the tombstone guard and still exposes the deleted delegated writer. Measured on
2026-08-20, a stranger's `registerFor(code, NON_BINDABLE)` call succeeded there. The 1,554-byte
candidate that rejected that call is historical; current self-registration source builds to a
1,350-byte runtime. The deployed registry holds no value, no protocol contract reads it and the
referral programme has not launched, but the address must not be used as proof of current behaviour.

The current creation/runtime sizes are 2,150/1,350 bytes, with keccak256 hashes
`0x574a196d16ed1a5c2d1f41293e756628f3038ea49ab39a66c166c82cb51a7fba` and
`0x07da903bdd0b827c5b8a8b8164a789ec28087119ca9e32d1f67478f9021d7a37`. Compiler metadata remains
a 51-byte CBOR trailer with embedded IPFS digest
`0x4d91b88c1f71ca44d584b8ae34d865bbc6c69d1b99eb89993497b7049e335df2`.

A 2026-08-21 loopback-only Base Sepolia-fork rehearsal exposed chain ID 31337 and used one local
deployment transaction, 16 constructor reservation logs and 841,101 gas. Reserved codes resolved to
`NON_BINDABLE`; `DEXFI` began unclaimed; former-selector refusal, partner self-registration,
referee binding, collision rejection and reserved-code refusal all passed; and deployed runtime
matched the build exactly. No live key or signing material was used, no public transaction was sent
and the committed address did not change. Replacement remains disabled and unauthorised; do not
publish or reserve codes against the stale instance.

### `ProtocolFeeSplitter` can strand both recipients' fees

`split()` makes two unconditional USDC transfers to immutable recipients. If either recipient is
blocked by the token, the whole call reverts and the unblocked recipient cannot collect either. The
splitter is published but not deployed. Do not deploy or use it until fee entitlements are separated
from delivery, for example through independent pull claims.

### DexFi whitelist revocation can strand collateral

The adapter is the only Recoup address that needs DexFi transfer whitelisting. Revocation stops new
deposits and can also prevent the adapter from returning existing collateral to an unwhitelisted
owner. The farm can return bonds to the adapter, but the final adapter-to-owner transfer still meets
the bond's whitelist gate. The tested behaviour and proposed operational safeguards are in
[`REVIEW.md`](REVIEW.md).

Referral launch also needs an operational policy for claim-before-publication, lookalike codes,
Sybil attribution and the first qualifying borrow. The registry alone does not solve those programme
rules.

### Governance is deliberately pre-launch

Every current Ownable protocol contract is controlled by the same EOA. That key can redirect yield,
replace the auction pointer before seizure, emergency-unstake collateral, pause core paths and stop
lender-yield delivery. Losing it permanently freezes every owner-only recovery and wiring path.

There is no production timelock, multisig or separate guardian role. Go-live requires the ownership
handover, a governance Safe, a timelock for risk changes and a pause role that does not inherit the
timelock's delay.

The contracts are immutable by choice. Replacing a manager requires a redeploy and pointer update;
it does not automatically migrate assets held by the old contract. Migration must be rehearsed before
mainnet use. Until G9 is resolved, pointer ordering can strand pending principal or route unsettled
position yield to insurance, and a live position can temporarily block the transition.

### External dependencies remain real

- Liquidation seizure depends on the DexFi farm remaining callable.
- The custody backend is swappable, but live collateral must be moved deliberately during a change;
  the current farm approval cannot be revoked in place.
- DexFi's owned and upgradeable contracts remain outside Recoup's control. The adapter seam and
  borrow caps limit that dependency but do not eliminate it, and an audit of this repository does
  not audit DexFi's contracts.
- Slither's clean result covered the earlier collateral scope; it has not been rerun over the whole
  credit and lender graph.
- The external audit remains a hard gate before third-party capital regardless of internal review
  count or CI status.

## What this source contains

This repository is a curated publication of the protocol's contracts, current as of 2026-08-31.

It contains the round-22 remediation in full - F4 (`setYieldRecipient` redirecting a full epoch's gross yield, closed by an
`owedToRecipient` balance drained by a permissionless `flushYieldTo`), F5 (a blacklisted liquidity
source freezing `pendingPrincipal` and the escape from it together, closed by `owedToSource` plus a
permissionless `flushPrincipalTo`), F8 (`workoutSettleAfterClose` resolving its payee from state
`closeWorkout` can empty in the same block, closed by recording a `bearer` at every close) and F9
(`lossBearerOf` recorded at write-down time) - and the round-23 remediation, including the
entry-side EIP-5143 overloads.

**The published source no longer matches the deployed testnet bytecode, and that is worth knowing
before you compare them.** `src/CreditManager.sol` once compiled to 23,833 bytes of runtime code,
byte-for-byte what is deployed at the Base Sepolia address in `deployments/base-sepolia.json`. It
compiles to a different `CreditManager` now, and the Sepolia
deployment is now **historic**: verify it against the block explorer rather than against this tree,
and read `deployments/base-sepolia.json` as a record of what was deployed rather than a description
of this code.

**This is a disclosure that moved in both directions.** The defects listed above are no longer live
in the code you are reading, which is better. The ability to reproduce the deployed bytecode from
this source is gone, which is worse. Neither is worth discovering by surprise.

## Mainnet go-live requirements

These are additional to the pool blockers and external-audit gate.

| Gate | Requirement |
|---|---|
| G1-G4 | Deploy a timelock with no standalone admin, use a documented 2-of-3 governance Safe, transfer every Ownable contract to the timelock, and add a separate guardian pause role in the same change |
| G5-G6 | Set the adapter's yield recipient to `EpochHarvester` and wire its harvester path; never route production yield to a deployer or governance address |
| G7 | Satisfy every `DeployMainnet` precondition and rehearse the script end to end |
| G8 | Re-review the governance diff, rerun Slither over the full graph and require the fork suite to pass |
| G9 | Decide whether manager migration is supported and design and rehearse it if so |
| G10 | Schedule and execute the pause first, then schedule the Phase-4 switchover as one batch; never queue its legs separately |
| G11 | Cancel every pending operation against a target before scheduling a replacement |
| DexFi integration | Agree the whitelist and custody policy, and set responsible caps against DexFi's admin-key and upgrade posture |

## Additional current limitations

These do not add to the three-item pool activation list, but they remain open, partly closed or
accepted for the present pre-launch state.

### Pool, stream and liquidation

| Finding | Current state |
|---|---|
| Round 21 borrower stream cadence | Bond movement and zero-claim epochs can bypass the intended epoch gap and repeatedly re-rate borrower yield; the measured trace still had 35% unreleased after five days |
| Round 22 F16 | Public callers can pin the lot or cap the price, but cannot bind both in one call; price monotonicity across a re-strike is not restored and the widened fuzz test is still owed |
| Round 22 F17 | `LenderPool.claim` remains the unswept member of the delegated `*For` claim class |
| Round 22 F18 | **Partly closed, and the closed half is in this source.** The insurance booking at a clean workout close is now bounded to what the lot could actually reach, rather than to what it generated. The **pre-close ordering hazard remains open**: a stranger sweeping mid-workout still changes what the close sees |
| Round 22 F19 | `claimSurplusFor` can front-run the auction's own sweep into a revert |
| Round 22 F23 | `_settle` can advance a borrower's yield index past a payout that floors to zero; the proposed one-line fix was measured inert |
| Long-gap lender yield | A long delivery gap can defer several epochs and then stream about 3.10 epochs over five days rather than their original accrual windows |
| Impairment refresh | A conservative stale-high mark persists until a permissionless refresh; `refreshImpairments` can report apparent progress when `impair` no-ops |
| Balance-probe stipend | The pool reads the asset's balance through a 30,000-gas probe (`_tryRawBalance`); if the USDC contract is ever upgraded to a proxy shape whose `balanceOf` costs more than that, all four ERC-4626 maxima read zero and `deposit`, `withdraw` and `redeem` revert, while the withdrawal-request, service and claim doors keep paying in full - so a synchronous exit silently becomes a two-step one, and the probe's answer can also depend on what warmed storage earlier in the same transaction |

### Oracle, wiring and migration

| Finding | Current state |
|---|---|
| NAV freshness | Alternating a posted NAV by one wei can keep an economically frozen price non-stale without invoking the second key |
| Pending NAV anchor | A pending value can remain confirmable after the accepted anchor moves; exact-value confirmation and expiry bound the exposure but do not remove it |
| Stale view | `collateralValue()` is an ungated stale-NAV view; callers must not treat it as a borrow-authorisation result |
| Pool manager binding | `LenderPool.setCreditManager` has no vault or code/interface binding check and can install an EOA as both authoriser and principal payee |
| Recovery-era binding | Written-down-loss recovery follows the current pool/source rather than the loss-time bearer, and post-close workout settlement follows the live auction manager; a migration can misroute recovery to the incoming era, make it operator-withdrawable or leave it unreachable. See "Recovery of a written-down loss is undeliverable after a manager migration" above for the pool-side case, which is a permanent refusal rather than a misroute |
| Risk-parameter check | The deployment check can approve a liquidation-threshold transition that the on-chain setter would reject |
| Insurance target | `INSURANCE_FUND_TARGET_BPS` has no consumer or enforcement path |
| Pointer probes | Contract-graph probe coverage remains incomplete as a class and must be re-derived when interfaces change |
| Lender-yield authority | Until governance is installed, the pool owner can stop new lender-yield delivery by changing `epochHarvester` |

### Liquidation incentives and lifecycle

| Limitation | Current state |
|---|---|
| Small-debt bounty exemption | The exemption is per account, so many wallets can consume the global cap without prepaying caller bounties |
| Keeper capture | A valid NAV poster can back-run its own update and capture the fixed liquidation bounty |
| Post-cancel liveness | A cured and cancelled position is live but unarmed until a later draw recreates bounty escrow |
| Re-strike incentive | Immediate workout pays the original caller while a re-strike pays nobody and delays the same outcome, so the re-strike path is economically dominated |
| Event accuracy | `BountyDepleted` is emitted on re-strikes even when the already-parked escrow was not depleted |

## Narrowly closed items relevant to reviewers

| Item | Current state |
|---|---|
| Liquidation caller bounty | Prepaid by the borrower, parked against the auction id and credited only by a transition that resolves the position |
| Auction reset | Re-strikes in place without changing the auction id; the first-open timestamp bounds reset to 48 hours |
| Risk parameters | Max LTV, liquidation threshold and both borrow caps live in bounded `RiskParams` storage and match the current Sepolia record |
| F3 principal-cap accounting | Closed in this source. The principal-unit mechanism its residuals were properties of is not in this source; cap usage follows the recognised entry book. Still live on the Sepolia deployment until the redeploy |
| F10 post-delivery capture | Closed for capital entering after a live pot is delivered, with the narrower semantics above |

## Verification sources

- [`README.md`](README.md) for the repository overview and commands
- [`REVIEW.md`](REVIEW.md) for custody, whitelist and fork-test claims
- [`AUDITS.md`](AUDITS.md) for the historical internal review record
- [`test/`](test/) for deterministic regressions and invariant campaigns
- [`deployments/base-sepolia.json`](deployments/base-sepolia.json) for current testnet addresses and
  recorded state
