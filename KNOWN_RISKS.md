
# Known risks and activation gates

This is the launch-critical and material current security posture for the public contracts. The
core protocol executable logic in this repository is current as of 2026-09-12, and everything
below is written against it. Analysis published here before 2026-08-31 was written against an
earlier lender pool, credit manager and collateral vault, and does not describe this source. This record is organised by present effect, not by discovery date. Historical internal review notes are
in [`AUDITS.md`](AUDITS.md); the code-level integration tour is in [`REVIEW.md`](REVIEW.md).
The section "Open findings from internal review round 45, at the audit commit" was added on
2026-09-07 and was written against the source at commit b66023d, the commit handed to the
external auditors; where the 2026-09-12 sync changes what a sentence in it says, the change is
marked in place and names the tree it is true of. The section "External review, 33audits
preliminary issues #45 to #54 (2026-09-11)" records the disposition of the ten issues the external
reviewers filed against b66023d.

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
| Live `LenderPool` bytecode | **Predates this source.** Read by selector at block 46291047 against the 2026-09-01 source, it still carries `serviceQueue`, `queueHead`, `queueLength`, `queuePosition`, `queueEntry` and `netDeposits`, the round 21 F7 and round 22 F3 mechanisms this file calls CLOSED below and this source has removed, and lacked 26 selectors that source had, `pause` and `guardian` among them, so there is no pause lever on it short of a redeploy; the 2026-09-12 sync adds `wasCreditManager` to the pool and changes the signatures of `writeDownLoss` and `recoverWrittenDownLoss` on the manager, so the gap is wider than that reading. Every `WirePhase4` entry point, `assertOnly()` included, reverts against the live set because the graph assertion calls `guardian()` and `mintReceiverImplementation()` on contracts that do not have them. `pendingLenderYield` on the live pool reads 124.885415 USDC parked with nobody to deliver it to |
| Current testnet liquidity | Supplied by `TreasuryLiquiditySource`, not `LenderPool` |
| Current-source parity | **None, deliberately.** This source is current as of 2026-09-12 and the Sepolia deployment predates it. The last comparison, on 2026-08-21 against an older public tree, passed the strict length-and-metadata gate for 3 of 13 checked deployments (the three mocks); that figure describes a tree this one has replaced and is not re-run here. Treat the deployment as historic and verify against the explorer, not against this source |
| External audit | In progress from 2026-09-07 over `LenderPool`, `CreditWiring`, `TreasuryLiquiditySource`, `ProtocolFeeSplitter`, `Config` and `LtvMath` at commit b66023d. Ten preliminary issues, #45 to #54, were filed on 2026-09-11; their disposition in this source is in the section "External review, 33audits preliminary issues #45 to #54 (2026-09-11)" below. Not completed |
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
`mulDiv(executableCash, queuedShares, totalSupply(), Ceil)`: a pro-rata slice of executable
**cash**, taken over every outstanding request at once rather than per controller, with the
entry-price reserve removed first in `_executablePoolCash` because it is senior while principal can
still be lost. The per-controller figure is a different function, `maxRequestRedeem`, which slices
the same executable cash by that controller's own `requestedShares` and rounds Floor where the
aggregate rounds Ceil. This paragraph named `requestedShares` in the aggregate formula and called it
per-controller until 2026-09-12, which crossed the two; both are real names in
[`src/LenderPool.sol`](src/LenderPool.sol) and they are not interchangeable. Requesters holding a
tenth of the supply between them reserve a tenth of the cash. The leverage multiplier is gone by
construction, not by tuning, which is why the fifteen refusals do not apply to it.

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

The three residuals below came out of a further internal adversarial review, dated 2026-09-12, read
over what happens to a lender on the worst day this design permits. None of them is a bug report.
Each is a deliberate property of the design, each is pinned in this tree by a test that asserts the
behaviour rather than forbidding it, and each is held rather than fixed, because in every case the
fix is either a change to a file under external audit or a larger piece of accounting than is
prudent to write while that audit is open. They are recorded here because nothing a lender reads on
the exit path says any of it. Severities are assigned by the author, not by an auditor, and every
figure is an executed reproduction on the fixture its own sentence states.

### Closing the last position destroys the yield still streaming to it. High, deliberate and held

When a burn takes real supply to zero with no principal outstanding,
`_derecogniseEmptyPoolResidual` writes the whole undelivered stream out of the book, and
`_exitAssets` excludes `unreleasedYield`, so the lender closing the position is paid the principal
and the tail is gone the moment the last share burns. The USDC stays in the contract as
`unmanagedSurplus` and nothing reaches it afterwards. On a 10,000 USDC deposit with 8,500 lent, a
sixty-day gap before the epoch lands and a 2,500 USDC lender share, one ordinary `redeem` destroys
the whole 2,500.000000; a smaller fixture destroys 833.333335, and with two lenders each closing
their own position the 1,000.000000 tail dies once and entirely rather than pro rata. `maxWithdraw`
reports exactly the principal figure and never signals the forfeit, so nothing on the exit path
warns. It is irrecoverable rather than merely mispriced: a later deposit, a fresh epoch, a lend and
repay cycle with surplus, `reconcileCashDeficit`, `coverClaimDeficit` and `coverEntryPriceDeficit`
each leave the dead figure unmoved by a wei, and there is no owner rescue on this pool, which is
the same property that protects a lender from the owner. The exposure window is the larger of the
time since the last epoch and `YIELD_STREAM_DURATION`, so it is not bounded by five days: one
fixture rated a stream over 5,184,000 seconds because the keeper cadence had been interrupted. The
avoidance is to leave `MIN_SUPPLY_FOR_YIELD` behind, wait the stream out and close after it, which
returns 833.260175 of the 833.333335 in that fixture. The behaviour is deliberate and pinned by
`test_stream_finalBurnPermanentlyDerecognisesTheOrphanedTail` in
[`test/LenderPool.t.sol`](test/LenderPool.t.sol). A crystallise-on-final-exit variant, which pays
the closing lender the pot instead of derecognising it, was costed at +97 runtime bytes on
`LenderPool` and refused: it fails that pin and it is a change to a file under audit. Held as
disclosed, not fixed; a reviewer should treat it as open.

### A deposit between a socialised loss and its recovery takes a share of that recovery. High, deliberate and held

The gross active-tail entry price defends the cohort against capital arriving after a recovery is
delivered, and the tree asserts that directly in
`test_R22F10_postDeliveryEntrantCannotDiluteTheRecoveryCohort` in
[`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol), where an entrant
depositing after `workoutSettleAfterClose` pays for the tail it is about to share. Nothing defends
the window before delivery. An entrant that deposits after `socialiseLoss` has written the loss
down and before `recoverLoss` delivers the redemption pays nothing for a tail that does not exist
yet, and then owns its pro-rata slice of it when it arrives. On a 10,000 USDC position with a 1,500
USDC entrant the loss bearer is 4,250.000000 worse off than the same fixture with no entrant, which
returns 10,000.000000 whole, and at the deposit cap the figure is 7,989.999999. The entrant pays
nothing for it: the profit is exactly the bearer's loss. The required hold is `YIELD_STREAM_DURATION`,
432,000 seconds, inside a `WORKOUT_MAX_DURATION` of 1,209,600, so the anti-JIT stream removes the
same-block take and does nothing about the five-day one. The door is wide open in that state and
the senior machinery is inert while it is: in the measured fixture `maxDeposit` offers
23,500.000000 against a pool worth 1,500.000000, and `minimumEntryAssets()`, `entryPriceDeficit()`
and `entryPriceCashReserve()` all read zero, because `MAX_LENDER_SHARES_PER_ASSET` puts the entry
floor out of reach at any realistic supply. The socialisation itself reopens the room, since
`depositCapUsage` falls with `outstandingPrincipal`, which is the cap term the entrant arrives
through. No malice is needed. This is the pre-delivery half of the disclosed post-delivery F10
decision above, and it is held rather than fixed: closing entry inside `socialiseLoss` was costed
at +38 runtime bytes and is not shippable as written, because it pauses the pool and six existing
tests then fail on `EnforcedPause()`. The answers that would work are loss-cohort accounting, which
is large, or a guardian pause taken operationally on `LossSocialised`, which costs nothing in
bytecode but depends on a `guardian` being installed, and it ships as the zero address. Deliberate,
held and disclosed.

### During a liquidation or an open workout the exit price values that loan at zero. Medium-high, deliberate and held

`CreditManager._impairmentFor` returns `currentDebtOf` in full for as long as an auction exists or
a workout is open. It is the whole debt, not an expected shortfall, and `exitReserve` clamps it to
`outstandingPrincipal`, so with a single borrower the exit assets become cash only and a lender who
needs money during that window sells the loan at zero. On a 5,000 USDC deposit the leaver receives
749.999998 and the lender who waits receives 9,250.000001 on the same position, a transfer of
4,250.000002 while the protocol itself loses nothing. The modest version is the one most lenders
would meet: one ordinary 225.000000 withdrawal burns 750.000001, thirty percent of the position at
the zero-recovery price for fifteen percent of its value in cash. The mark is almost always
pessimistic by construction, because `DEFAULT_MAX_LTV_BPS` and `DEFAULT_LIQUIDATION_THRESHOLD_BPS`
sit at 2,500 and 5,000 against an auction that opens at 100 percent of NAV and floors at 68, so
full recovery is the expected case and the pool quotes zero regardless, for six hours of auction
and up to fourteen days of workout. The behaviour is deliberate and is pinned as such in
[`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol) by
`test_impairment_isSetTheMomentTheAuctionOpens`, `test_impairment_isFlatAcrossExpiryToWorkout` and
`test_impairment_isUnmovedByASupersedeAtARecoveredNav`, whose own assertion messages say a live
auction reserves the whole debt, an open workout assumes zero recovery, and the mark tracks the
debt rather than the collateral. What is not reproduced end to end is a full liquidation and
workout: the full-debt mark is read from `_impairmentFor` and from the assertions of those three
tests rather than from a single trace that runs the lifecycle through. This is therefore a severity
disclosure rather than a bug report. What is missing is not the conservatism but the label:
`previewRedeem` is indistinguishable from a permanent loss while the mark stands, and a lender
acting on it takes an irreversible step against a number that is temporary by design. The avoidance
is to wait the auction or workout out. Deliberate, held, and named here because nothing in the
quote says so.

## Open findings from internal review round 45, at the audit commit

In the week before the external audit, a twelve-reader internal adversarial pass was run over the
six files in the audit scope, and the findings below came out of it. Each one has an executed
reproduction in a test unless it is marked as a lead. **None of them was fixed at commit b66023d,
and that was deliberate**: a fix written the week before an audit is what the audit exists to check, so
they were disclosed here and to the auditors as known issues, with the candidate fixes named and
their status given honestly. They were written against commit b66023d. Severities are assigned
by the author, not by an auditor. The external reviewers' preliminary issues of 2026-09-11 then
confirmed three of them and executed the lead, and the 2026-09-12 sync fixes the migrated-manager
High, corrects the withdrawal-request documentation and carries the open-workout reserve the lead
was about; each of those headings says so below, and the others still stand in this source.

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
The external reviewers' M-04 restates the unbounded window together with the gross entry pricing;
a 30-day ceiling on the epoch leg was built, measured and held, and the measurement is in the
external review section below. Still open in this source.

### Recovery of a written-down loss is undeliverable after a manager migration. High, fixed in this source since 2026-09-12

**Fixed by the one sentence the paragraph below asks for.** `LenderPool.setCreditManager` stamps
`wasCreditManager` for the incoming manager, `recoverLoss` accepts the live manager or a former
one, and it pulls the USDC from and credits `msg.sender` rather than the live pointer. Nothing else
on the pool reads the mapping. The external reviewers filed the same gap as their L-01 at Low and
re-rated it to High on 2026-09-12, on the ground that the second half of their own reproduction
disproves the premise the Low rested on: the acknowledged "retry once the pointer is repaired" is
itself refused with `PrincipalOutstanding` once the successor manager has lent, so the refusal is
permanent rather than a recoverable delay. This record rated it High throughout, and the two
ratings now agree. Regressions: `test_L01_managerMigrationNoLongerStrandsPostCloseRecovery`
in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol) (the reviewers' own
reproduction with the expected revert removed), `test_R46_theRecoveryLandsAfterALegalPoolRepoint`,
`test_R46_theOnlyRouteIntoTheRecoveryIsTheAuctionAndItIsOpen` and
`test_R46_aFormerManagerReachesNoOtherManagerGatedLeg` in
[`test/R46AuctionRepointRecovery.t.sol`](test/R46AuctionRepointRecovery.t.sol) (the first two were the
pins that asserted the refusal), and
`test_regression_aLateTrancheAfterARepointFollowsTheBearerEvenAfterThePoolMovesOn` in
[`test/R55A01_WorkoutLifecycle.t.sol`](test/R55A01_WorkoutLifecycle.t.sol) for the second route. A
former manager reaches no other manager-gated leg of the pool. The auction-side twin the paragraph
below calls "not yet synced" is in this source too: `setLiquidationAuction` stamps
`wasLiquidationAuction` and `recoverWrittenDownLoss` accepts a former auction. The paragraph below
is kept as written on 2026-09-07 and describes commit b66023d.

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
permanent loss and the other two can never be discharged. A second route reaches the same refusal:
a late `workoutSettleAfterClose` tranche that arrives after a forced close, once the pool has been
repointed to the new manager by an ordinary `setCreditManager`, is refused `NotCreditManager` in
`recoverLoss` in the same way, so the tranche is never delivered to the lenders who bore the loss.
Same root cause, same one-sentence fix.

### The withdrawal-request "reserve" is a per-call pro-rata bound, not a reservation. Documentation, corrected in this source since 2026-09-12

`_unreservedIdle` is the executable balance less the ceiling of executable times queued over supply, re-derived on every call, so
a non-requester can unwind the reserved cash to 0.011 percent of itself in twelve fair-priced
redeems while the requester's whole-request value stays exactly at book. The sync door caps a
holder at all cash not reserved by someone else (114.59 against 236.30 USDC in the same state). The
per-call bound is the intended semantics, and no code change is proposed: a checkpointed cash floor
is the refused F7 shape. What is wrong is the wording, and the previous revision of this paragraph
was wrong in the same direction: it said the request door "caps a controller at their own fraction
of cash", which is true of one service call and false cumulatively. The external reviewers' H-03
measured that: in their state a single fair slice is 4,874,250,000, stepped service reaches
4,999,999,999 over seven calls, and one synchronous `redeem` of the same shares from the same
snapshot quotes and pays 5,000,000,000 and leaves no shares
(`test_H03_steppedRequestServiceReachesNoMoreThanOneSyncRedeem` in
[`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol)). The per-call slice in
`maxRequestRedeem` is a reservation for requesters against `lend` and other exits, not a cap on
cumulative conversion, and a cumulative cap on the request door would make it strictly tighter than
`redeem` for no protection. The file header, the `maxRequestRedeem` docstring and the
`queueCashReserve` docstring in `LenderPool` are corrected in this source to say so; at commit
b66023d they overstated the bound as a reservation.

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

### Lead, executed by the external reviewers as M-01 and M-02, fixed in this source since 2026-09-12: `sweepWorkoutYieldToInsurance`

`sweepWorkoutYieldToInsurance` is in `LiquidationAuction`, outside the audit scope. Two readers
independently thought it shortcuts the round 22 F18 bound for gas, and one found a dead
`NothingToClaim` line beside it. F18 is the double-booking bound in the table below, and a sweep
that shortcuts it would be the same money counted twice from the other end, landing in the pool's
numbers. Nobody executed it at the time, and it was recorded here as a lead so that it was not lost.
The external reviewers executed it against commit b66023d as their M-01, and its sibling route
through `claimSurplusFor` and `sweepFreeBalanceToInsurance` as M-02; both reproduce there. In this
source both pre-close sweeps go through `_fundInsuranceWithFree`, whose owed line is
`totalUnclaimedRewards + totalWorkoutYieldOwed + _openWorkoutAccrual`, the third term being the
accrual on every open workout's bonds read from the manager's accumulator rather than from where the
cash sits, so a sweep that would take it reverts `NothingUnreserved` whichever door it uses.
Regressions: `test_R51_154_regression_aStrangerCannotSweepAnOpenWorkoutsBacking` and
`test_R51_154_regression_theSiblingSweepReachesItWithNoClaimInFront` in
[`test/R51A02_OverRealisationDoor.t.sol`](test/R51A02_OverRealisationDoor.t.sol), and the walk in
[`test/R56A02_SweepVersusF18.t.sol`](test/R56A02_SweepVersusF18.t.sol).

### A forced workout close socialises a loss the lot's own accrued yield would cover. Medium, found in internal review round 54, outside the audit scope, fixed in this source since 2026-09-12

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
pre-close sweeps refuse an open lot's accrual by design since this sync; at b66023d the owed line
had two terms and the external reviewers' M-01 and M-02 reproduce there, so on that commit a
stranger's sweep could put the yield in front of the write-down. The fix is to have the forced
close spend the auction's free balance, the closing lot's own accrual included, before socialising.
It is in this source: the forced branch of `closeWorkout` claims and sweeps the free balance into
the insurance fund before `writeDownLoss` reads the residual, and the clean branch is unchanged
(`test_R55_215_aForcedCloseSpendsTheLotsOwnYieldBeforeSocialising` in
[`test/R54A02_ForcedCloseIgnoresLotYield.t.sol`](test/R54A02_ForcedCloseIgnoresLotYield.t.sol)). At
b66023d it was built and queued on the auction side rather than shipped, so the audited tree does
not carry it. The reviewers' M-03, two clean closes where the first takes the shared residual, is a
different mechanism on the same function and is also closed here: the shortfall that ordering used
to allocate can no longer be created once the open-workout accrual is reserved, and the owed ledger
is kept per bearer, so `test_R23_04_theResidual_aSweptPotIsAllocatedToWhicheverClosesFirst` in
[`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol), which at b66023d asserted
that the second close booked nothing, now asserts that both closes book and are paid.

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
- Slither 0.11.5 has run over the whole tree, and its scope includes `src/LenderPool.sol`, so unlike
  the lint above it is not blind to this file on account of the assembly block. Its own
  `uninitialized-state` detector reported nothing on this file or anywhere else, and in 0.11.5 that
  detector has no inline-assembly skip. The unfiltered run found 269 results across 54 contracts,
  12 of them High impact and 102 Medium; all 269 were triaged and none is a true positive. One
  informational result on this file is real: the zero-argument `_entryAssets` overload has no
  caller. It is private, compiles to no code, and is deleted after the audit freeze. The counts are
  for the development tree at a later internal commit, a superset of the audited scope, not a
  reading of this commit.

## External review, 33audits preliminary issues #45 to #54 (2026-09-11)

The external reviewers filed ten preliminary issues against commit b66023d on 2026-09-11, each with
a Foundry reproduction written against this repository's own test fixtures. All ten reproduce at
b66023d. Four of them (H-02, M-01, M-02, M-03) had been fixed in the development tree between
2026-09-03 and 2026-09-07 and had not been synced to this repository; two (L-01, L-02) were already
disclosed above; one (M-04) was disclosed in parts; and three (H-01, H-03, M-05) were new. The table
below is the status of each issue **in this source from the 2026-09-12 sync on**, which is the
first sync since the issues were filed. Every function and test it names is in `src/` or `test/`
here. Byte figures are the runtime deltas of the fix against the source immediately before it,
measured with `forge build --sizes` on a clean build; "earlier" means the fix is in this sync but
landed in the development tree before the issues were filed, so its delta is not itemised.

| Issue | Title as filed | Status in this source | Runtime bytes |
|---|---|---|---|
| #45 H-01 | Borrower-keyed recovery provenance redirects an earlier workout's recovery | **Fixed.** `writeDownLoss` and `recoverWrittenDownLoss` on `ICreditManager` take the auction id, and `CreditManager` records the bearer and the funder per auction and id in `recoveryBearerOf` and `recoveryFunderOf` and routes the recovery through them; `lossBearerOf` and `lossFunderOf` stay as the borrower's latest record. `LiquidationAuction` passes the id at `closeWorkout`, `workoutSettleAfterClose` and `_settleFill`. Regression: `test_H01_aLaterDefaultDoesNotRedirectAnEarlierWorkoutsRecovery` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol), the reviewers' reproduction with its last two assertions reversed: the first workout's pool is paid 628,750,000 and the second's 0, then the second is paid its own. The two records are internal because making them public getters put the manager under 2,000 bytes of runtime margin | `CreditManager` +307, `LiquidationAuction` +17 |
| #46 H-02 | Auction replacement orphans a closed workout's recovery leg | **Fixed, earlier.** This is the auction-side twin the previous revision of this file called fixed but not yet synced. `setLiquidationAuction` stamps `wasLiquidationAuction`, and `recoverWrittenDownLoss` accepts the live auction or a former one; `checkAuctionSwap` is unchanged, so no fourth clause was added to the migration guard. Regressions: `test_R46_theRecoveryLandsAfterALegalAuctionRepoint` and `test_R46_aFormerAuctionReachesNoOtherAuctionGatedLeg` in [`test/R46AuctionRepointRecovery.t.sol`](test/R46AuctionRepointRecovery.t.sol), `test_R22_theReturnLegSurvivesAMigrationToAFreshAuction` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol) | earlier |
| #47 H-03 | Repeated request service converts more than a requester's pro-rata cash into senior claims | **Documentation; the arithmetic is confirmed and the benchmark is disputed.** Measured in `test_H03_steppedRequestServiceReachesNoMoreThanOneSyncRedeem` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol), in the reviewers' state: a single fair slice is 4,874,250,000, stepped service reaches 4,999,999,999 over seven calls, and one synchronous `redeem` of the same shares from the same snapshot quotes and pays 5,000,000,000 and leaves no shares. The stepped loop therefore reaches no more than the synchronous door already allows an un-queued holder, and the exit price already nets `exitReserve` for known impairment. The per-call slice in `maxRequestRedeem` is a reservation for requesters against `lend` and other exits, not a cumulative cap; the file header and the `maxRequestRedeem` and `queueCashReserve` docstrings are corrected in this source, and the "reserve" paragraph above is corrected with them. A cumulative cap on the request door was not built: it would make that door strictly tighter than `redeem` for no protection | 0 |
| #48 M-01 | Permissionless yield sweep can confiscate an open workout's borrower yield | **Fixed, earlier.** `_fundInsuranceWithFree`, which both pre-close sweeps go through, owes `totalUnclaimedRewards + totalWorkoutYieldOwed + _openWorkoutAccrual`; the third term is the accrual on every open workout's bonds, read from the manager's accumulator, so `sweepWorkoutYieldToInsurance` reverts `NothingUnreserved` rather than moving it. Regressions: `test_R51_154_regression_aStrangerCannotSweepAnOpenWorkoutsBacking` in [`test/R51A02_OverRealisationDoor.t.sol`](test/R51A02_OverRealisationDoor.t.sol), `test_R56A02_81_negative_walk00_sweepWorkoutYieldFirst` in [`test/R56A02_SweepVersusF18.t.sol`](test/R56A02_SweepVersusF18.t.sol) | earlier |
| #49 M-02 | Realised open-workout yield bypasses the dedicated sweep protection | **Fixed, earlier, by the same reserve.** It is derived from the accumulator and not from where the cash sits, so realising the yield onto the auction through `claimSurplusFor` and taking it with `sweepFreeBalanceToInsurance` is refused the same way. Regressions: `test_R51_154_regression_theSiblingSweepReachesItWithNoClaimInFront` in [`test/R51A02_OverRealisationDoor.t.sol`](test/R51A02_OverRealisationDoor.t.sol), `test_R56A02_81_negative_walk02_claimSurplusForFirst` in [`test/R56A02_SweepVersusF18.t.sol`](test/R56A02_SweepVersusF18.t.sol) | earlier |
| #50 M-03 | First clean workout close captures shared residual yield | **Fixed, earlier.** The shortfall that close ordering allocated can no longer be created once the open-workout accrual is reserved, and the owed ledger is kept per bearer. The public test at b66023d, `test_R23_04_theResidual_aSweptPotIsAllocatedToWhicheverClosesFirst`, asserted that the second close booked nothing, which was a pinned disclosure of the round 22 F18 residual and is what the reviewers' reproduction restates; it now asserts that both closes book and are paid, beside `test_R23_04_twoCleanClosesCannotBookTheSameClaimTwice` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol). The forced-close fix the reviewers asked about is separate and is in this source; see the round 54 paragraph above | earlier |
| #51 M-04 | Uncapped stream duration plus gross entry pricing lets a timed flush overcharge new lenders | **Confirmed; a ceiling was built, measured and held.** The gross entry pricing is the disclosed F10 decision above and the unbounded window is the drought item above. A 30-day ceiling on the epoch leg of `_rateStream` was built on a separate branch with the stream-clock tests updated, and is deliberately not in this source: with a 180-day gap, a 1,000.000000 pot and two equal holders, a holder staked for exactly 30 days after the flush takes 499.999999 with the ceiling against 83.333333 without it, and a 3,000.000000 newcomer is whole after 30 days rather than 180. The ceiling moves the transfer from the newcomer to the incumbent rather than removing it, which is the same shape the drought item's "honest fix is two rates" sentence refuses. `_rateStream` is unchanged here and the decision is open with the reviewers | 0 |
| #52 M-05 | A lender-yield backlog above the deposit-cap ceiling can never be delivered | **Fixed.** `distributeYield` clamps the streamable amount to capital only in the terminal state where the cap is at `GLOBAL_BORROW_CAP_MAX` and `depositCapUsage` has reached it; every other oversize offer still reverts `YieldExceedsCapital`, so the one-cent capture the refusal exists for stays refused. The harvester's `_push` decrements `pendingLenderYield` by measured delivery, so the remainder stays pending and drains over successive flushes. Regressions in [`test/LenderPool.t.sol`](test/LenderPool.t.sol): the reviewers' three, `test_distributeYield_theHardCeilingAdmitsNoMoreCapital`, `test_distributeYield_aBacklogAboveTheHardCeilingIsClampedNotRefused` and `test_distributeYield_anOfferOfExactlyCapitalIsAcceptedInFull`, plus `test_distributeYield_aBacklogAboveTheHardCeilingDrainsOverSuccessiveFlushes` (900,000 drained in three flushes) and `test_distributeYield_belowTheHardCeilingTheRefusalIsUnchanged`; and `test_R40_D7_theBacklogAboveTheHardCeilingDrainsThroughTheRealHarvester` in [`test/R40D7Capture.t.sol`](test/R40D7Capture.t.sol), 400,000 through `flushLenderYield` in two flushes | `LenderPool` +60 |
| #53 L-01 | Manager migration strands post-close loss recoveries with no unblocked repair path | **Fixed. High, re-rated by the auditor 2026-09-12** from the Low it was filed at, to the grade this record already carried. `LenderPool.setCreditManager` stamps `wasCreditManager`, and `recoverLoss` accepts the live manager or a former one and pulls from and credits `msg.sender`. The parked-tranche alternative the reviewers proposed, a pool-side balance drained by a permissionless flush, was built and refused by execution: +561 runtime bytes as built, and the drain calls `recoverLoss` from the retired manager, so it is dischargeable only by pointing the pool back, which reverts `PrincipalOutstanding` once the successor has lent. Regressions: `test_L01_managerMigrationNoLongerStrandsPostCloseRecovery` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol); `test_R46_theRecoveryLandsAfterALegalPoolRepoint`, `test_R46_theOnlyRouteIntoTheRecoveryIsTheAuctionAndItIsOpen` and `test_R46_aFormerManagerReachesNoOtherManagerGatedLeg` in [`test/R46AuctionRepointRecovery.t.sol`](test/R46AuctionRepointRecovery.t.sol); `test_regression_aLateTrancheAfterARepointFollowsTheBearerEvenAfterThePoolMovesOn` in [`test/R55A01_WorkoutLifecycle.t.sol`](test/R55A01_WorkoutLifecycle.t.sol) | `LenderPool` +72 |
| #54 L-02 | Permissionless settle discards a borrower's sub-unit yield accrual | **Held; accepted Low.** The one-line skip the reviewers propose was re-executed on a scratch copy of `_settle` at this source and not committed: 336 wei of unbacked credit on a 1.000000 pot (1,000,335 credited plus 1 undistributed against 1,000,000 streamed), for the same reason as the 925,925 wei measured against the original proposal, a zero-floored settle before a top-up leaves the index stale and the next settle prices the stale delta at the larger bond count. The shipped code destroys 2 wei in the same trace. The remainder-carry alternative was measured at +198 bytes and makes `pendingYieldOf` under-report. Pinned by `test_L02_aZeroFlooredSettleBeforeATopUpCreditsNoMoreThanWasStreamed` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol) | 0 |

Measured on this source with `forge build --sizes` on a clean build: `CreditManager` 22,518 bytes
of runtime with 2,058 of EIP-170 margin and 23,867 of initcode with 25,285 of EIP-3860 margin;
`LiquidationAuction` 21,022 / 3,554 and 22,437 / 26,715; `LenderPool` 20,619 / 3,957 and 21,991 /
27,161. `CreditManager` is the contract that binds.

Of the six audited files, this sync changes `src/LenderPool.sol` only (L-01, M-05 and the H-03
docstrings), and `src/LenderPool.sol` additionally differs from b66023d by the `transferOwnership`
guardian guard the 2026-09-01 sync carried. `src/CreditWiring.sol`, `src/Config.sol` and
`src/LtvMath.sol` are byte-identical to b66023d; `src/TreasuryLiquiditySource.sol` and
`src/ProtocolFeeSplitter.sol` differ from it in comments only. The other fixes above are in
`src/CreditManager.sol`, `src/LiquidationAuction.sol` and `src/interfaces/ICreditManager.sol`,
outside the audited six.

**The fix-verification tree for these issues is this repository's head from this commit on.** A
reviewer verifying a fix should read the function and run the test named in its row here, not the
development tree, which is not published.

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
`0xc2a69df82d6752fb9a784997d888448ecba1698c652bb016ce11b2c83cfb7de1` and
`0x3f9a2b1592acbd3c056e88fd94ae712cb5af632dea9dac1789e79dc97c02465e`. Compiler metadata remains
a 51-byte CBOR trailer, with embedded IPFS digest
`0x4d91b88c1f71ca44d584b8ae34d865bbc6c69d1b99eb89993497b7049e335df2` before 2026-09-12 and
`0xff2bc27f977efdde5278aefeda1758958b3d8e1790999470bbccce8a53578131` on this source. All three
hashes were re-measured on 2026-09-12 on a clean `forge build` and all three had gone stale, while
both byte counts stayed exactly right, which is the tell worth keeping. Solc hashes the whole
metadata, and the metadata names every source in the contract's own compilation closure, which here
is this contract and `Config.sol`; both have changed since the hashes were written, and the most
recent change to this contract was four lint-suppression comments, which cost no runtime bytes at
all. A byte count that has not moved is therefore no evidence that a hash has not moved with it.
Re-measure all five figures from the build artifact rather than quoting them from here.

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
- Slither had last been run over an earlier collateral scope. It has since been run over the whole
  credit and lender graph: 269 raw results, all triaged, none a true positive, and 45 left under a
  configuration that records a reason for every detector it mutes (44 when this sentence was written
  on 2026-09-10; one more accepted finding was recorded later that day, and the H-01 fix moved one
  fingerprint without changing the count). Slither now runs in the development tree's CI on every
  contracts change, and a committed baseline of those 45 fails the build on any finding that appears
  or disappears. This repository does not run Slither itself.
- The external audit remains a hard gate before third-party capital regardless of internal review
  count or CI status.

## What this source contains

This repository is a curated publication of the protocol's contracts, current as of 2026-09-12.

It contains the round-22 remediation in full - F4 (`setYieldRecipient` redirecting a full epoch's gross yield, closed by an
`owedToRecipient` balance drained by a permissionless `flushYieldTo`), F5 (a blacklisted liquidity
source freezing `pendingPrincipal` and the escape from it together, closed by `owedToSource` plus a
permissionless `flushPrincipalTo`), F8 (`workoutSettleAfterClose` resolving its payee from state
`closeWorkout` can empty in the same block, closed by recording a `bearer` at every close) and F9
(`lossBearerOf` recorded at write-down time) - and the round-23 remediation, including the
entry-side EIP-5143 overloads. Since 2026-09-12 it also carries the answers to the external
reviewers' preliminary issues: F9's record is completed by per-workout records keyed by auction and
id (`recoveryBearerOf`, `recoveryFunderOf`), and the recovery leg is deliverable from a former
auction (`wasLiquidationAuction`) and to a former manager (`wasCreditManager`).

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
| Round 22 F18 | **Closed in this source since 2026-09-12.** The insurance booking at a clean workout close is bounded to what the lot could actually reach, rather than to what it generated, and the pre-close ordering hazard is closed by the open-workout reserve: a stranger sweeping mid-workout is refused `NothingUnreserved` for any open lot's accrual, so the close sees what the lot earned. `test_R23_04_theResidual_aSweptPotIsAllocatedToWhicheverClosesFirst` now asserts both closes are paid, where at b66023d it asserted the second booked nothing. At b66023d the hazard was open, and the external reviewers' M-01 to M-03 reproduce it there |
| Round 22 F19 | `claimSurplusFor` can front-run the auction's own sweep into a revert |
| Round 22 F23 | `_settle` can advance a borrower's yield index past a payout that floors to zero; the proposed one-line fix was measured inert, and the external reviewers' L-02 restatement of it was re-measured on 2026-09-11 at this source: skipping the index stamp on a zero-floored payout mints 336 wei of unbacked credit on a 1.000000 pot (1,000,335 credited plus 1 undistributed against 1,000,000 streamed), because a stale index is revalued at a larger bond count after a top-up, against 925,925 wei on the original measurement; the shipped code destroys 2 wei in the same trace. Held as accepted Low; pinned by `test_L02_aZeroFlooredSettleBeforeATopUpCreditsNoMoreThanWasStreamed` |
| Long-gap lender yield | A long delivery gap can defer several epochs and then stream about 3.10 epochs over five days rather than their original accrual windows |
| Impairment refresh | A conservative stale-high mark persists until a permissionless refresh; `refreshImpairments` can report apparent progress when `impair` no-ops |
| Balance-probe stipend | The pool reads the asset's balance through a 30,000-gas probe (`_tryRawBalance`); if the USDC contract is ever upgraded to a proxy shape whose `balanceOf` costs more than that, all four ERC-4626 maxima read zero and `deposit`, `withdraw` and `redeem` revert, while the withdrawal-request, service and claim doors keep paying in full - so a synchronous exit silently becomes a two-step one, and the probe's answer can also depend on what warmed storage earlier in the same transaction |
| Final-exit yield forfeit | The position that takes real supply to zero forfeits the whole undelivered stream, which stays in the contract as `unmanagedSurplus` with nothing able to reach it afterwards, and `maxWithdraw` quotes only the principal; deliberate and pinned. See "Closing the last position destroys the yield still streaming to it" above |
| Pre-delivery entry to a socialised loss | A deposit landing after `socialiseLoss` and before `recoverLoss` pays nothing for the recovery tail and then takes its pro-rata slice of it; the stream bounds the take to a `YIELD_STREAM_DURATION` hold rather than to a block, and the cap headroom the loss frees is the door it arrives through. See "A deposit between a socialised loss and its recovery takes a share of that recovery" above |
| Exit price during liquidation or workout | `_impairmentFor` marks the whole debt for as long as an auction exists or a workout is open, so a synchronous exit in that window sells the loan at zero and `previewRedeem` reads the same as a permanent loss; deliberate, conservative, and unlabelled on the exit path. See "During a liquidation or an open workout the exit price values that loan at zero" above |

### Oracle, wiring and migration

| Finding | Current state |
|---|---|
| NAV freshness | Alternating a posted NAV by one wei can keep an economically frozen price non-stale without invoking the second key |
| Pending NAV anchor | A pending value can remain confirmable after the accepted anchor moves; exact-value confirmation and expiry bound the exposure but do not remove it |
| Stale view | `collateralValue()` is an ungated stale-NAV view; callers must not treat it as a borrow-authorisation result |
| Pool manager binding | `LenderPool.setCreditManager` has no vault or code/interface binding check and can install an EOA as both authoriser and principal payee |
| Recovery-era binding | **Closed in this source since 2026-09-12, in three parts.** Written-down-loss recovery follows the bearer and funder recorded at write-down, keyed by auction and workout id (`recoveryBearerOf`, `recoveryFunderOf`), so a later default by the same borrower cannot redirect an earlier workout's recovery (the external reviewers' H-01); a former auction can still deliver it (`wasLiquidationAuction`, their H-02); and the pool accepts it from a former manager (`wasCreditManager`, their L-01). At b66023d recovery was keyed by borrower and the pool-side case was a permanent refusal; see "Recovery of a written-down loss is undeliverable after a manager migration" above. The zero-supply derecognition item above is unaffected |
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
