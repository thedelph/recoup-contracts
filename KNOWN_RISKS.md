
# Known risks and activation gates

This is the launch-critical and material current security posture for the public contracts. The
core protocol executable logic in this repository is current as of 2026-09-15, and everything
below is written against it; the prose was last re-read against that source on 2026-09-17, after a
review of the published documents alone found figures and sentences the tree no longer reproduced,
each corrected in place below and dated. Analysis published here before 2026-08-31 was written against an
earlier lender pool, credit manager and collateral vault, and does not describe this source. This record is organised by present effect, not by discovery date. Historical internal review notes are
in [`AUDITS.md`](AUDITS.md); the code-level integration tour is in [`REVIEW.md`](REVIEW.md).
The section "Open findings from internal review round 45, at the audit commit" was added on
2026-09-07 and was written against the source at commit b66023d, the commit handed to the
external auditors; where the 2026-09-12, 2026-09-14 and 2026-09-15 syncs change what a sentence in it says,
the change is marked in place and names the tree it is true of. The section "External review,
33audits preliminary issues #45 to #54 (2026-09-11)" records the disposition of the ten issues the
external reviewers filed against b66023d, as it stands after the 2026-09-15 sync.

Internal adversarial review, unit tests, invariant campaigns and mainnet fork tests are evidence, but
they are not an external audit.

## Gate definitions

- An **activation blocker** prevents wiring or funding `LenderPool`, including with the author's
  capital.
- A **third-party capital gate** is additional. Even after the activation blockers close, no public,
  DexFi or Bond Fund capital is accepted until the recommendations the external audit report makes
  before third-party capital are met (see the External audit row under Deployment facts).
- A **residual risk** is a known limitation that must stay disclosed and be reconsidered at go-live,
  even when it is not an activation blocker.

The three findings this file once listed as pool activation blockers stand, in this source, at two
closed by construction and one narrowed to a disclosed residual; the section "`LenderPool` findings"
below names the function that carries each. Until 2026-09-17 this paragraph and the definition
above still counted three live blockers, which that section contradicted. What blocks activation
now is process rather than an open finding: the fresh internal review in the next paragraph and
the audit report's recommendations before third-party capital. Closing findings is necessary but not sufficient for mainnet; the governance,
wiring, deployment and review gates below still apply.

The merged principal-accounting and active-tail entry-pricing mechanisms require a fresh internal
follow-up review before any Phase-4 wiring or funding. That review must rerun the prior attack bundle
and re-audit their rounding, sequencing, impairment, frozen-stream, queue and recovery interactions.

## Deployment facts

| Item | Current fact |
|---|---|
| Base mainnet | No Recoup contracts are deployed |
| Base Sepolia | The protocol is deployed against mock USDC, bond and farm contracts |
| `LenderPool` | Deployed on Sepolia, empty, and not wired as `CreditManager`'s liquidity source in the protocol-to-pool direction; the pool's own pointers to the manager and the harvester are set, and it is open to any depositor at the full 25,000 USDC cap |
| Live `LenderPool` bytecode | **Predates this source.** Read by selector at block 46291047 against the 2026-09-01 source, it still carries `serviceQueue`, `queueHead`, `queueLength`, `queuePosition`, `queueEntry` and `netDeposits`, the round 21 F7 and round 22 F3 mechanisms this file calls CLOSED below and this source has removed, and lacked 26 selectors that source had, `pause` and `guardian` among them, so there is no pause lever on it short of a redeploy; the 2026-09-12 sync adds `wasCreditManager` to the pool and changes the signatures of `writeDownLoss` and `recoverWrittenDownLoss` on the manager, the 2026-09-14 sync adds the request-draw memory and the stream ceiling to the pool and the bool-gated `_settle` to the manager, and the 2026-09-15 sync adds the cash floor (`_floorTotal`) to the pool, so the gap is wider than that reading. Every `WirePhase4` entry point, `assertOnly()` included, reverts against the live set because the graph assertion calls `guardian()` and `mintReceiverImplementation()` on contracts that do not have them. `pendingLenderYield` on the live `EpochHarvester` (the pool has no such selector and the call reverts there; until 2026-09-17 this cell attributed the figure to the pool) read 259.795831 USDC at block 46942219 on 2026-09-17, parked with nobody to deliver it to; it read 124.885415 USDC when this cell was first written, undated, and it rises with every harvest while the pool stays unwired |
| Current testnet liquidity | Supplied by `TreasuryLiquiditySource`, not `LenderPool` |
| Current-source parity | **None, deliberately.** This source is current as of 2026-09-15 and the Sepolia deployment predates it. The last comparison, on 2026-08-21 against an older public tree, passed the strict length-and-metadata gate for 3 of 13 checked deployments (the three mocks); that figure describes a tree this one has replaced and is not re-run here. Treat the deployment as historic and verify against the explorer, not against this source |
| External audit | Completed 2026-09-22. 33Labs reviewed `LenderPool`, `CreditWiring`, `TreasuryLiquiditySource`, `ProtocolFeeSplitter`, `Config` and `LtvMath` at commit b66023d from 2026-09-07, with remediation reviewed through f6893cb. The final report is in [`audits/`](audits/) with its sha256. 13 findings (4 High, 6 Medium, 3 Low): 10 Fixed, and three Acknowledged / Accepted Risk, M-06 (#64), L-02 (#61) and L-03 (#68). The report renumbers some issues: #53 is H-04, #54 is L-01 and #61 is L-02. The disposition of the ten preliminary issues, #45 to #54, filed on 2026-09-11, is in the section "External review, 33audits preliminary issues #45 to #54 (2026-09-11)" below; the post-loss lock is under the heading "33audits H-03, the post-loss lock the floor retains". Every other contract in `src/` was outside the scope. M-06 (#64) is fixed in this source by #69 (see the #64 heading below), and the reproductions in [`test/R63A3_DrawMemoryDust.t.sol`](test/R63A3_DrawMemoryDust.t.sol) and [`test/R63S61_DustHeldFloorWiredGraph.t.sol`](test/R63S61_DustHeldFloorWiredGraph.t.sol) now assert the fixed behaviour. The report in `audits/` predates that fix. Before third-party capital the report recommends revisiting M-06 with the L-02 trade-off, publishing the L-03 incident runbook, retaining the activation gate, and verifying deployment and source parity |
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
no public, DexFi or Bond Fund capital is accepted until the audit report's recommendations before
third-party capital are met, whatever this section says.

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

The mechanism those numbers describe is not in this source. `_queueCashReserve` is the larger of
`mulDiv(executableCash, queuedShares, totalSupply(), Ceil)`, a pro-rata slice of executable
**cash** taken over every outstanding request at once rather than per controller, and `_floorTotal`,
the sum of the cash the live requests were quoted when they were filed (since 2026-09-15), and never
more than the executable cash itself; the entry-price reserve is removed first in
`_executablePoolCash` because it is senior while principal can still be lost. Both arms are cash: a
request's floor is priced by `_freshFloor` out of executable cash after that reserve, never out of
the book, so the leverage multiplier F7 was about does not come back with it. The per-controller
figure is a different function, `maxRequestRedeem`, which pays the larger of that request's
remaining floor and its slice of the same executable cash by that controller's own
`requestedShares`, rounds Floor where the aggregate rounds Ceil, and is capped at the cash the other
live requests are not owed. This paragraph named `requestedShares` in the aggregate formula and called it
per-controller until 2026-09-12, which crossed the two; both are real names in
[`src/LenderPool.sol`](src/LenderPool.sol) and they are not interchangeable. Requesters holding a
tenth of the supply between them reserve a tenth of the cash, or the cash they were quoted when they
queued if that is more. The leverage multiplier is gone by
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
prudent to write while that audit was open. They are recorded here because nothing a lender reads on
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

### 33audits H-03, the post-loss lock the floor retains. Low, acknowledged and retained by design, not fixed, dated 2026-09-17, tracked separately as #61

**The rule.** Since the 2026-09-15 sync a queued lender is owed the cash she was quoted when she
queued (`WithdrawalRequest.floor`, summed in `_floorTotal`), and no path writes a floor down on a
loss. After a raw loss the cash locked is the executable cash no request can reach.
`_queueCashReserve` holds the larger of the pro-rata fraction and the floors, clamped at the
executable cash, so the whole of that cash is reserved while the floors exceed it, and
`maxRequestRedeem` caps each request at the executable cash the OTHER live requests are not owed.
**The locked amount is not bounded above by the raw loss**, and this heading said that it was
until 2026-09-17. With several live floors every request's cap can read 0 at once, and then the
whole remaining cash is locked: three floors of 100.000000 with 100.000000 lost lock 200.000000,
and one hundred floors of 100.000000 with the same 100.000000 lost lock 9,900.000000. The excess
of the floors over the cash, 100.000000 in both cases, measures the SHORTFALL and not the amount
locked. The reviewers filed the falsifier on #47 (comment 5718920756) and both rows are ported
verbatim as `test_AuditH03_threeFloorsLockMoreThanTheRawLoss` and
`test_AuditH03_oneHundredFloorsLockNinetyNineTimesTheRawLoss` in
[`test/R60S2_H03LockBound.t.sol`](test/R60S2_H03LockBound.t.sol), where
`testFuzz_R60S2_theLockIsTheQueueNotTheRawLoss` states the general form over 2 to 40 equal floors
and any raw loss inside the book. What IS bounded is `_floorTotal` at the moment of loss, which no
later request can raise above the cash, because a request filed in the locked state is quoted a
floor of 0 (`_freshFloor` prices a floor out of the cash not already reserved for the requests
ahead of it).

**What causes it, added 2026-09-18.** A raw loss: the pool's USDC balance falling by something
other than the pool's own transfers. No loss path inside the protocol produces one, on a reading
of the source and the measurements below rather than a proof over every interleaving. Every USDC
outflow in `LenderPool` lowers `_accountedCash` in the same call, so `_reconcileCashDeficit` finds
a loss only when the token balance itself falls; and a written-down loss moves no cash,
because `socialiseLoss` lowers `outstandingPrincipal` and executable cash depends on principal only
through the entry-price reserve, which principal reaching 0 removes, so a protocol loss leaves the
executable cash where it was or raises it. Measured on this source with every lender queued
(floors of 22,371.249998 against 22,371.250000 of executable cash): a liquidation filled short at a
crashed NAV, then `writeDownLoss`, `socialiseLoss` and `settlePrincipal`, leaves 0 locked, and so
does an expired auction forced through `closeWorkout` with 628.750000 socialised; the same
314.375000 taken out of the pool as a raw cash exit, with the loan standing, locks 628.749999. On a
copy of this source whose `socialiseLoss` also sends the absorbed amount out of the pool, the
protocol-path measurements turn red, which is what shows they can see a lock. These three are
measured in a development-tree test on the same `src/` that is not yet in this repository. The
causes left are outside the protocol, an upgrade of the USDC contract or a seizure of the pool's
balance by its issuer, argued rather than executed; every loss in this repository's tests is
simulated by transferring USDC out of the pool.

**Who bears it.** Nobody is paid beyond what exists: each request is capped at the executable cash
the other live requests are not owed, and a synchronous exit is capped at the cash none of them is
owed, so `unreservedIdle`, an unqueued lender's `maxRedeem` and `available()` read 0 while the lock
stands. The shortfall sits with the pool, as recognised shareholder cash promised twice, until a
repayment, a new deposit or a released yield delivery lifts the executable cash above the floors or
a floor holder cancels. When a holder
cancels, `cancelWithdrawalRequest` releases her floor whole and the cash it held becomes reachable
by the other live request first, so the unwind is by whoever releases first: in the reviewers' own
regression on this source, one controller cancelling restores 500.000000 of serviceable cash to the
other request, and with three equal floors of 100.000000 after a loss of 100.000000 one cancel
moves each remaining cap from 0 to 100.000000, of which the next holder draws 66.666666, what her
escrowed shares are worth at the post-loss price; the third then draws 66.666667, the floors reach
0 and the lock is gone, with 66.666667 unreserved and the canceller's `maxRedeem` at 66.666666
(`test_R61A4_afterOneCancelBothRemainingDoorsAndWhatStaysLocked`). One cancel ends that lock
because the loss is one floor, and until 2026-09-19 this paragraph did not say so: with 200.000000
lost from the same three floors, one cancel leaves both remaining doors at 0 and a second cancel
opens the last holder's door to 33.333333, what her shares are worth at that price
(`test_R62S1_Q2_twoHundredLostNeedsTwoCancels`); the count is stated under the rule below. A new
lender's deposit is a
third release, and until 2026-09-18 this file named two: `maxDeposit` stays open in the locked
state unless a claim liquidity deficit stands as well (`_maxDeposit` returns 0 while
`totalClaimable` exceeds the pool's cash, which takes serviced claims left uncollected and then a
loss of nearly all the cash), and her cash lifts the executable cash above the old floors when
there is enough of it, and until 2026-09-19 this sentence had no "when": a deposit reopens an old
door only where the executable cash plus the deposit exceeds the floors the other live requests
are owed, with equal floors a deposit over the shortfall less one floor (the shortfall is the
floors less the executable cash, and equals the loss only where the floors held the whole cash
when it landed), and below that her whole deposit joins the lock while `maxDeposit` quotes the cap
and nothing at the door says so (the figures are under "The rule and the fourth door" below).
From three floors of
100.000000 with 100.000000 lost, a deposit of 100.000000 reopens each old door to 66.666666 while
the depositor's own `maxRedeem` and request door read 0 and her request is quoted a floor of 0; the
old holders draw 199.999999 between them, after which her request door reads 100.000000 and she
draws 100.000000 (`test_R61A4_aDepositIntoTheLockedPool`). Her cash is what unlocks the old floors,
she is made whole only after they act, and nothing at the door says so. A queued lender whose floor
is not fully serviceable is held until a repayment, a deposit, a released yield delivery or another
holder's cancel. **There is no guaranteed recovery time, and until 2026-09-19 this sentence
overstated that**: three of the four releases are somebody else's act, a borrower's repayment, a new
lender's deposit or another holder's cancel, and none of those is owed on any schedule; the fourth,
an accepted epoch's yield, is the protocol's own delivery on the epoch clock and opens the doors as
its stream releases. Read from `_rateStream`, each delivery is rated over at least
`YIELD_STREAM_DURATION` and at most `MAX_YIELD_STREAM_DURATION`, and a later epoch re-rates
whatever has not yet released over its own window, so the money of one delivery can finish
releasing later than `MAX_YIELD_STREAM_DURATION` after it: that ceiling bounds each rating and not
the recovery. It is the composition under "The epoch leg of `_rateStream` re-rates a running
recovery stream" below, met from the lock's side. In tests on this source that are not in this
repository yet, a delivery of 100.000000 rated over the 30-day ceiling and followed 29 days later
by an epoch of 0.250000 still had 3.209771 of a 100.000000 shortfall closed at the 30-day mark and
cleared it on day 56, a second epoch of 0.250000 at spacings `harvest` allows (seven days, then
five) cleared the shortfall 255,600 seconds later than no second epoch would have, while a second
delivery as large as the first, landing half way through its stream, cleared it sooner. So
whenever the fund pays yield the recovery is on the epoch clock, sized by how much of the
shortfall each delivery covers, and one delivery's window is a bound only where no later epoch
lands on its stream (the rule and the figures are under "The rule and the fourth door" below).
An epoch that delivers nothing opens nothing, and the yield door is then as closed as the other
three. Her own cancel is not a way out for her, and until
2026-09-18 this paragraph
said it was: it releases her floor to the other live requests and leaves her own `maxRedeem` at 0
until they draw, because the cash left is what their floors are owed, and a request she files again
is quoted a floor of 0. In the reviewers' two-floor regression the canceller's `maxRedeem` reads 0
straight after her cancel, in either cancel order (`test_R61A4_floorF_oneCancelRestoresToTheOtherRequest`);
in the three-floor case above it reaches 66.666666 only once both others have drawn.
There is no privileged path: `claimSolvencyDeficit()`
and `entryPriceDeficit()` both read 0 in the locked state, `coverClaimDeficit(1)` and
`coverEntryPriceDeficit(1)` revert `ClaimDeficitExceeded` and `EntryPriceDeficitExceeded`, because
the locked cash is not a deficit either door is built for, and the pool has no owner lever over a
floor.

**The pinned figure.** Two floors of 2,000.000000 and 1,000.000000 with 2,500 of cash lost from
5,000 leave the two requests serviced to 1,499.999999 and 499.999999 and 500.000002 of executable
cash locked, with `unreservedIdle`, the third lender's `maxRedeem` and `available()` all 0, pinned
by `test_R42S1_floorF_aLossWithTwoFloorsLocksTheOverPromise` in
[`test/R42S1_H03Floor.t.sol`](test/R42S1_H03Floor.t.sol); after a `repayPrincipal` of 20,000 the
two read 7,499.999965 and 3,999.999925 and `available()` 7,650.000095. The reviewers reproduced the
same 500.000002 independently on 68c0c26 on 2026-09-16, cancel included. **That figure is one
shape and is not the bound.** The multiple-request figures are in
[`test/R60S2_H03LockBound.t.sol`](test/R60S2_H03LockBound.t.sol): 3 equal floors of 100.000000 and
100.000000 lost lock 200.000000, 100 floors lock 9,900.000000, and in the five-floor state
`unreservedIdle`, `available()`, `claimSolvencyDeficit()`, `entryPriceDeficit()`, `totalClaimable`
and every `maxRequestRedeem` read 0 over 400.000000 of locked cash
(`test_R60S2_theLockedStateReadsZeroAtEveryDoorAndBothRepairs`). The two releases are pinned
there too: `test_R60S2_oneCancelReleasesExactlyItsFloorToTheOtherRequests`, where one cancel
releases exactly its floor of 100.000000 and the next holder then draws 66.666666; and
`test_R60S2_aRepaymentReopensTheDoorsTheLossClosed`, where three floors of 50.000000 under a
150.000000 loan lock 100.000000 after a 50.000000 loss and a `repayPrincipal` of 30.000000
reopens each door to 29.999999. That test reads two of the three doors; drawn in turn, all three
pay 89.999997 in total and 40.000003 stays locked, measured in the same development-tree test as
the causes above. The cover doors are executed in the multi-floor states as well as in the
two-floor one: at 3, 5 and 100 floors both deficits read 0 and `coverClaimDeficit(1)` and
`coverEntryPriceDeficit(1)` revert (`test_R61A4_coverDoorsRefuseOneWeiInEveryMultiFloorLock`), and
a request filed in the locked state is quoted a floor of 0
(`test_R61A4_aRequestFiledInTheLockIsQuotedFloorZero`), all in
[`test/R61A4_PublicLockClaims.t.sol`](test/R61A4_PublicLockClaims.t.sol).

**The rule and the fourth door, added 2026-09-19.** Every request's cap, the executable cash the
other live floors are not owed, is its own floor less the SHORTFALL, the floors less the executable
cash, so every door reads 0 exactly while the shortfall is at least the largest live floor. A
service that leaves shares in the request moves the cash and the floors down together and leaves
the shortfall where it was, and one that completes the request releases whatever is left of its
floor (`serviceWithdrawalRequest`: in `test_R62S1_Q2_twoHundredLostNeedsTwoCancels` the last
holder draws 33.333333 against a floor of 100.000000 and the floors reach 0); a cancel lowers the
shortfall by the cancelled floor; a repayment, a new deposit or a released yield delivery raises
the cash and lowers it by that amount while no claim liquidity deficit stands. Where one does,
serviced claims waiting uncollected after a loss of nearly all the cash, `_poolBalance` nets the
claims out first, so arriving cash fills that hole before it reaches a floor and `maxDeposit`
reads 0 until it has (`test_R63A3_6_theYieldDoorWhileAClaimLiquidityDeficitStands`: 60.000000 of
released yield lowered a shortfall of 100.000000 by 40.000000, the other 20.000000 having covered
the deficit). For N equal floors of F and a loss L the cancels that end the
lock are therefore floor(L / F), at most N - 1, and the first door then opens to F less the
remainder: fuzzed over 2 to 12 floors and every loss inside the book, with the reviewers' two rows
as fixed points, one cancel at 100.000000 lost and two at 200.000000
(`testFuzz_R62S1_Q2_theCancelsThatEndTheLockAreFloorOfLossOverFloor`,
`test_R62S1_Q2_theFuzzBodyReachesZeroOneAndTwoCancels`). Yield is the fourth release, and the
reviewers reproduced it before this file named it: `distributeYield` accepts an epoch in the locked
state, the executable cash excludes the part of it the stream has not released, and the doors open
as it releases. From three floors of 100.000000 with 100.000000 lost, 100.000000 delivered is rated
over exactly `YIELD_STREAM_DURATION` (432,000 seconds); at delivery every door still reads 0, half
way through the stream each reads 49.999998, of which the three draw 149.999994 in turn while
100.000005 stays locked, and once the stream ends each reads 100.000000 and all three draw their
whole floor with no repayment, deposit or cancel
(`test_R62S1_Q1_yieldEqualToTheShortfallReopensEveryDoorOverTheStream`). Yield under the shortfall
opens each door by what it has released and no more: 30.000000 delivered opens each door to
29.999999, lets 89.999997 out and leaves 140.000003 locked with the shortfall unmoved at
70.000000, while 200.000000 lets 399.999998 out
(`test_R62S1_Q1_yieldBelowEqualAndAboveTheShortfall`). That bounds a door and not what the yield
can end: a door pays the smaller of its cap and what its shares are worth, and a completing
service releases its whole floor, so where every share is not queued, yield under the shortfall
can end the lock whole (`test_R63A3_5_withDormantHoldersYieldUnderTheShortfallCascades`: three
queued floors of 100.000000 beside two unqueued holders of 100.000000 with 300.000000 lost,
60.000000 delivered against a shortfall of 100.000000 let 156.000000 out and left no floor). With
150.000000 lent, three floors of 50.000000 and 50.000000 lost, 50.000000 delivered reopens every
door to 50.000000 with the loan standing (`test_R62S1_Q1_theYieldDoorOpensWithTheLoanStanding`).
After one cancel from the 200.000000 loss, a deposit of 30.000000 or a released yield of 30.000000
each lower the shortfall by 30.000000 and open both remaining doors to 29.999999
(`test_R62S1_Q2_afterOneCancelADepositOrAYieldOfXReopensByX`). The same inequality sizes every
release, the deposit included: a release of R reopens a request only where `E + R` exceeds the
floors the other live requests are owed. Five floors of 100.000000 with 201.940593 lost put that
threshold at 101.940593 while `maxDeposit` quotes 249,701.940593; a deposit of 1.672435 lifts the
executable cash from 298.059407 to 299.731842 against 400.000000 owed to the other four floors at
every old door, so every old door stays 0, her request is quoted a floor of 0, her request door and
sync door read 0, no door reaches a wei, and her whole deposit is locked with theirs until every
old holder cancels (her door then reads 1.672433 and she draws it), a repayment lands or a further
deposit clears the threshold; 110.000000 from the same state opens every old door to 8.059406 at
once. Her shares are worth 1.672434 the block she pays 1.672435, entry and exit prices agreeing to
a wei, so with no stream running the lock costs her time and not money
(`test_R62S1_Q3_aDepositUnderTheThresholdJoinsTheLockWhole`, the counterexample's arithmetic
copied from the seat that found it). While a stream is running, which is when the fourth door is
opening, she pays the gross entry price of #51 below, the unreleased yield included, and the lock
holds her to the end of the stream to earn it back: in
`test_R63A3_T2_aStreamIntoTheLockMovesTheThresholdAndTheEntryPrice`, 60.000000 deposited into the
lock mid-stream bought shares worth 46.901262 that block and 59.999999 once the stream ended. All
of it is in
[`test/R62S1_YieldDoorAndSecondCancel.t.sol`](test/R62S1_YieldDoorAndSecondCancel.t.sol), 27 tests
of which 8 are new bodies and 19 are `R60S2_H03LockBound` inherited, except the three figures
named above by test, which are in
[`test/R63A3_YieldDoorRepeated.t.sol`](test/R63A3_YieldDoorRepeated.t.sol) and
[`test/R63A3_ShutOutAndDepositDoor.t.sol`](test/R63A3_ShutOutAndDepositDoor.t.sol).

**The alternatives, costed and refused.** A floor write-down on a raw loss, one storage word applied
to every floor read, was measured by the maintainer on a copy of this source and posted on #47
(comment 5715504360, 2026-09-17): +285 bytes of `LenderPool` runtime (21,511 with 3,065 of EIP-170
margin). It takes the lock to 0.000001, and in the same state each queued lender permanently loses
a sixth of her quote while any floor lives, and a cancel then restores 0 to the other request rather
than 500.000000; it moves the cost from a lock the next repayment or cancel releases onto a loss
nothing gives back. The aggregate reconstructions of the reserve refused before the floor (+532 and
+533 bytes) over-promise after a loss, which is the shape the floor exists to refuse. Both are
refused; the lock is held.

**Where a lender reads it.** The three views read 0 in the locked state without saying why; this
heading is the place that says why, and the #47 row below carries the mechanism function by
function. A lender who wants a reservation queues for one. A queued lender cannot leave the lock
by her own act: cancelling releases her floor to the other live requests and pays her nothing until
they draw. A lender depositing into a locked pool reads an open `maxDeposit` and, once she has
deposited, a `maxRedeem` of 0.

**Status.** Low. **Acknowledged and retained by design, not fixed**, dated 2026-09-17, and tracked
separately from the original High as [#61](https://github.com/thedelph/recoup-contracts/issues/61). The maintainer's disposition is posted on
#47 as comment 5715504360. The reviewers answered on #47 on 2026-09-17 (comment 5718920756): the
original H-03 withdrawal routes stay verified fixed on 68c0c26, the residual is to be recorded
separately as a Low that is acknowledged and retained rather than fixed, and they support closing
the original High without the floor write-down shipping, on condition that the bound above is
corrected and multiple-request coverage added. Both shipped in 0f49e61 (#60) on 2026-09-17. On
2026-09-18 the reviewers reported that commit reviewed and its test file passing, and supported
closing the original H-03 as verified fixed, with the lock tracked under #61 as acknowledged and
retained by design (comment 5727241497 on #47). The recovery conditions are the four named above,
a repayment, a new deposit, a released yield delivery or a floor holder's cancel; three are somebody
else's act with no time at which any of them is owed, and the fourth is the protocol's own on the
epoch clock, so the recovery has a clock whenever yield is delivered and none otherwise; that clock
is each delivery's own rating window, and a later epoch can stretch what has not yet released, as
stated under "Who bears it". Until
2026-09-18 this paragraph named two and until 2026-09-19 three; the reviewers filed the yield door
and the second cancel as qualifications on #61 on 2026-09-18 (comment 5734172519), and both were
measured as stated.

### #64, 33audits M-06: a request serviced down to one share-wei kept the rest of its cash floor. Medium, fixed in this source by the change that added this heading; a Low residual remains, dated 2026-09-22, narrowed by a permissionless trim on 2026-09-24

**What it was.** `serviceWithdrawalRequest` spent a request's floor by what each service paid and
released the rest only with the final share. Once a price fall (a socialised loss, or the whole-debt
impairment mark of a routine liquidation that is later cleared in full) left the floor above what
the request's shares were worth, a requester could take everything a complete service would pay and
stop one share-wei short. The rest of her floor stayed reserved against that share-wei, every other
lender's door and `available` read it as owed, and only her own completing service or her cancel
released it. 33audits' final report of 2026-09-22 rates it Medium, Accepted Risk, on f6893cb, and
the public main branch up to and including f6893cb does not carry the change described next.

**The change.** After the plain spend, `serviceWithdrawalRequest` now caps what is left of a
partially serviced request's floor at what the remaining shares are worth, the gross conversion
`convertToAssets` uses rounded UP rather than down, but only while the floors left after the plain
spend sit inside the executable cash:
`_floorTotal - floorSpent <= _executablePoolCash(_rawBalance())`. The second condition is what keeps #61 as it is: after a raw
loss that puts the floors over the cash, no floor is written down, and every figure the #61 section
above states still holds (`test_R64A4_C7_orderOfService_underARawLoss`,
`test_R63A3_3_unequalFloorsOpenLargestFirst` and both `R62S1_YieldDoorAndSecondCancel` Q1 tests pass
unchanged). Cost: +91 bytes of `LenderPool` runtime and +91 of initcode over f6893cb (+85 each for
the cap as first offered on 2026-09-22 with the worth rounded down, and +6 each for rounding it up on
2026-09-24), measured with `forge build --sizes` on a clean build; `CreditManager` is unchanged.

**What it closes.** Every dust service made while the floors are within the executable cash now
leaves a floor no larger than what the dust is worth rounded up, which for one share-wei (worth about
a thousandth of a wei) is 1 wei. That covers the
three reproductions, whose dust-held-floor assertions are flipped and marked #64 at each assertion:
[`test/R63A3_DrawMemoryDust.t.sol`](test/R63A3_DrawMemoryDust.t.sol),
[`test/R63S61_DustHeldFloorWiredGraph.t.sol`](test/R63S61_DustHeldFloorWiredGraph.t.sol) and
[`test/R64A4_DustFloorCurve.t.sol`](test/R64A4_DustFloorCurve.t.sol), where every socialised-loss
and mark row of the threshold curve now keeps at most a wei per request at any fall and none of the
twelve asset-denominated round trips of C5f leaves a floor of 1.000000 or more. It covers the no-loss mark route on the wired
graph in [`test/Issue64_MarkRoute.t.sol`](test/Issue64_MarkRoute.t.sol) (a routine auction that
clears in full, a workout rescued in full, a short fill inside the cash), and the seeded census
replay in [`test/Issue64_DustCensusReplay.t.sol`](test/Issue64_DustCensusReplay.t.sol), which keeps
no floor of 1.000000 or more on dust before a raw loss on the replay or on the walk with a mark, and
none at all on the walk that has no loss of any kind. Internal review also measured six further
shapes on the same `LenderPool` source, each of which kept a floor under the old rule and kept none
under the change as first offered, with the worth rounded down (they were not re-run with it rounded
up):
floors priced through the real `NAVOracle`, yield streamed between filing and service, a partial
workout tranche, a forced workout close followed by `recoverLoss`, a deposit-cap change, and a
request filed for part of a position. Those six tests are not in this repository. The
`LenderPool` invariant suite's handler models the change, the rounding included, so its floor-sum
ghost holds the stored floors to it in every campaign.

**Why the worth rounds up, measured.** The kept floor was also what held a request's door open, and
the change as first offered wrote it down to the worth rounded DOWN. That left a request on one
share-wei with a floor of 0 and a door of 0 while its draw memory had spent its slice, and it broke
an honest exit: after a socialised loss, a requester who serviced half her request and then ran the
ordinary `maxRequestRedeem` loop was paid 8,999.999999 of the 9,000.000000 her remaining shares
were worth and left with 13 share-wei behind a door of 0, a cancel being her only way out. With the
worth rounded up the same loop pays 9,000.000000 in one call and completes, and one share-wei keeps
a floor of 1 wei, which holds a door of one share-wei open, so a completing one-wei service ends the
request again; a cancel still removes it at any time.
[`test/Issue64_HonestCompletion.t.sol`](test/Issue64_HonestCompletion.t.sol) pins both, and the
tails of D4, W2 and C6 end with that completing service. The cost is one wei, and it goes to the
requester: her reservation sits at most one wei above what her remaining shares are worth, and every
other lender's reach is short by at most that wei per live request until she completes or cancels.

**The residual, disclosed. Low.** A dust service made while the floors EXCEED the executable cash
keeps its floor, exactly as the old rule did, and the kept floor outlives the shortfall: no service
re-examines it once the cash returns, so her completing service, her cancel or a trim (next
paragraph) is what releases it.
[`test/Issue64_DustUnderShortfall.t.sol`](test/Issue64_DustUnderShortfall.t.sol) pins it with
nobody trimming: two requesters of 20,000 filed in an idle book of 100,000, 40,000 lent, a 10,000
socialised loss and a 25,000 raw loss put the floors (40,000) over the cash (35,000); one requester
services to one share-wei and keeps 7,000.000000; the loan then repays in full and the last lender
out still leaves 7,000.000001 behind.
[`test/Issue64_KeptFloorAfterShortfall.t.sol`](test/Issue64_KeptFloorAfterShortfall.t.sol) reads the
same shape at the instant the shortfall ends, which is before any repayment: when the other
requester completes, the floors (7,000) are back inside the executable cash (9,000), so the
change's own condition holds with the kept floor counted, and still nothing but a trim takes it.
It is Low because it needs an external event first, a raw cash loss, which no path inside the
protocol produces (see #61 above), and then the requester's own dust service while that shortfall
stands. The unconditional cap would close it and was not chosen, because it writes floors down
under the #61 lock: with it, C7, the unequal-floors test and both Q1 tests above go red, and so
does the residual pin itself.

**The trim, added 2026-09-24.** A service that declines the write-down above because the floors
stand over the executable cash now marks the request (`writeDownDeclined`, read by
`requestWriteDownDeclined`), and `trimRequestFloor(controller)` applies the same write-down later,
on the same condition, as if it were a service of zero shares. Anyone may call it, for any
controller: it acts only on a marked request, only while `_floorTotal`, the marked floor included,
sits inside `_executablePoolCash`, and only ever lowers that one floor to the worth a service
writes it to, the escrowed shares' gross conversion rounded up, reducing `_floorTotal` by the same amount and emitting
`RequestFloorTrimmed`; anywhere else it returns 0 without reverting or emitting. An unserviced
request is never marked, so a price fall never moves an honest requester's filing-time floor to
anyone else, and no floor is ever written down under the #61 lock. Nothing calls it automatically:
a keeper, a waiting lender or the requester has to. Measured in
[`test/Issue64_FloorTrim.t.sol`](test/Issue64_FloorTrim.t.sol) on the shape above: under the
shortfall the trim releases 0; once the other requester completes it releases 6,999.999999,
leaving her one share-wei a floor of 1 wei (its worth rounded up), and after the loan repays the
last lender out leaves 0 behind (7,000.000001 without it). A trim takes no cash from the requester
it applies to: a requester serviced half-way under the shortfall and then trimmed draws
6,500.000000, exactly what she draws untrimmed, and her request completes. The `LenderPool`
invariant handler calls the trim as a fuzz action, predicts each release from its own floor and
mark mirrors and the rounded-up worth recomputed from the public views, and asserts both the
release and the mark (`invariant_aTrimReleasesExactlyThePredictedExcess`). Its single actions
rarely line up a shortfall, a recovery and a trim in that order (2 trims in 2 of 256 runs of one
unseeded campaign, measured with a per-run census on a copy of this tree), so the handler also
composes the three in one action, `composeShortfallRecoveryAndTrim`: the same campaign then takes
267 trims in 161 of its 256 runs, and with the trim's worth rounded down instead of up it goes red
on its own. Cost: +417 bytes of
`LenderPool` runtime and +417 of initcode over the rounded-up change above, measured with
`forge build --sizes` on a clean build, the event and the view included. The trim writes the
rounded-up worth out itself: a private helper shared with the service path measured 4 bytes more,
so it was not used. The trim, the view and the event are declared on
`LenderPool` and not in `ILenderPool`, so no other source file changes and every other contract,
`CreditManager` and the CREATE2 initcode of `CreditWiring` included, builds byte-identical.

**Who picks the moment, and what a re-trim moves.** The mark is cleared only with the request,
never by a trim, so a request trimmed once is trimmed again, by anyone, after any later price fall,
to the same worth her own next service would write it down to. In
`test_trimTiming_theMarkSurvivesATrimSoALaterFallIsTrimmedAgain` in
[`test/Issue64_TrimTiming.t.sol`](test/Issue64_TrimTiming.t.sol), on the shape above, the first
trim releases 6,999.999999 and leaves a floor of 6,500.000001; a later 3,000 socialised loss leaves
the floors (6,500.000001) inside the executable cash (15,500), a second trim releases 428.571429,
and she still completes. Because anyone may call it, a stranger chooses the moment, and can trim
her at a trough that a recovery then reverses. What that moves is her liquidity priority, the cash
held for her ahead of lending and of synchronous exits, never the value of her shares:
`test_trimTiming_aStrangerTrimAtATroughMovesPriorityNeverValue` runs that 3,000 loss, a 3,000
recovery, the manager lending all it may and a dormant lender exiting first, with and without a
trim at the trough. Untrimmed, her floor of 13,500 leaves the manager 200 to lend, and she draws
6,500.000002 at once. Trimmed, her floor is 6,071.428572, 6,514.285714 is lent, and she
draws 6,071.428571 at once while 428.571430 stays escrowed at its full worth until cash comes back:
1 wei less in total, and later. The untrimmed column is the #64 shape itself, about 6,300 of
lending held back by a floor 7,000 above her worth. Clearing the mark on a taken trim would stop
the re-trim, at +16 bytes of `LenderPool` runtime measured on a copy, and was not taken: after a
loss that lands once the first trim is taken, on a request nobody services again, the floor would
stay above its worth with nothing able to lower it, which is the shape #64 fixes. Measured on a
copy with the mark cleared, the same later loss leaves the floor 428.571429 above its worth, the
second trim releases 0, and `available` reads 3,600.000000 where the sticky mark gives 3,964.285714.

**The trim's own residual. Low.** The trim waits for the floors, the kept one included, to sit
inside the executable cash. If a SECOND raw loss lands after the shortfall has ended and before
anyone has trimmed, the floors are over the cash again and the kept floor becomes a #61 lock held
by one share-wei: in `test_trim_residual_aSecondRawLossBeforeAnyTrim`, a further 3,000 raw loss
leaves executable cash 6,000 against floors 7,000, both dormant lenders' doors read 0 and the trim
releases 0. It ends the way #61 ends, when the cash covers the floors again, and then at the next
trim: after a 5,000 repayment the trim releases 6,999.999999 and a dormant lender's door reads
10,999.999998. Until someone trims after that, the kept floor stays reserved. It needs two external
raw losses and nobody trimming in the window between them.

**Status.** On the main branch, merged by #69 together with the trim. The change was first offered
to the reviewers on #64 on 2026-09-22 with the worth rounded down; the rounding was changed to up on
2026-09-24, before they reported, for the reason given above. The report in `audits/` records the
status on f6893cb, before this change.

### A paused or blacklisting USDC shuts every bond door, because the farm settles its pending USDC inside the same call. Medium, conditional on a USDC pause; open, not fixed, dated 2026-09-21

`DirectCallAdapter` moves its own USDC on a best-effort basis, so its own transfer cannot revert a
bond movement. That covers the adapter's leg and nothing else. The live DexFi farm is
MasterChef-style and settles the position's pending USDC inside `deposit` and `withdraw`, which are
the two calls the adapter makes to move bonds, and that settlement is a plain token transfer nothing
here wraps. [`src/interfaces/IDexFiFarm.sol`](src/interfaces/IDexFiFarm.sol) has recorded since
round 34 that `withdraw(0)` is the claim primitive; what was not written down until now is that
every other `withdraw`, and every `deposit`, claims as well.

So while USDC is paused, and for as long as the adapter carries any pending farm yield,
`withdrawBonds`, `depositBonds` and `harvestYield` revert with the token's own pause string, and so
do `seize`, `disposeTo`, `restakeLoose` and the mint paths, which make the same farm calls.
Measured on a Base fork against the real token, paused by impersonating its own pauser, with 5 bonds
staked: three days of accrual leaves 0.695611 USDC pending; `withdrawBonds(5)` succeeds with the
token live and reverts "Pausable: paused" once it is paused; `depositBonds(5)`, which is the cure a
borrower reaches for when the NAV falls, reverts the same way; `harvestYield` reverts the same way.
The threshold is one second of accrual, not a large balance: in the same block as the escape hatch,
with nothing pending, `withdrawBonds(5)` goes through UNDER the pause, and one second later, with
0.000003 USDC pending on those 5 bonds, the same call reverts. `seize`, `disposeTo`, `restakeLoose`
and the mint paths were read from the source rather than executed on the fork; the three doors above
were executed.

The same weld holds with no pause at all: with the ADAPTER blacklisted on real USDC,
`withdrawBonds` and `depositBonds` both revert with the token's blacklist string, for as long as the
listing stands.

The only lever is the owner-only `emergencyUnstake`, which calls the farm's `emergencyWithdraw`:
it forfeits the pending rewards, moves EVERY bond unit to one address, and leaves
`custodyIsSolvent` reading false, so it is a protocol-wide act taken to release one position. After
it, on the local twin, the owner can return the bonds and `restakeLoose` under a standing pause
because nothing is pending at that moment, and an exit in that same block goes through. That
sequence is an operator procedure rather than a mechanism, and no such procedure is published
yet.

What is NOT true of this: it is not a loss. No USDC is taken, no debt moves, and everything works
again when the token does. What it costs is the ability to exit collateral, to ADD collateral, and
to harvest, for the duration - and see the separate entry on the protocol's clocks, which do not
stop while this holds.

Status: open, not fixed, no design decision taken. Severity Medium, conditional on a USDC pause or a
blacklisting of the adapter; the impact is high while it lasts and Circle has never paused USDC.
The reproduction is [`test/R64A1_RealFarmPausedUsdcFork.t.sol`](test/R64A1_RealFarmPausedUsdcFork.t.sol),
a fork test on the same `src/` as this repository, public since #66. It uses the same `RUN_FORK_TESTS`
opt-in as the suites under [`test/fork/`](test/fork), so it self-skips in CI the way they do, and it
pauses the real token by impersonating its own pauser. Run it with
`RUN_FORK_TESTS=true forge test --match-contract '^R64A1_RealFarmPausedUsdcFork$' -vv -j 1`;
at block 51619708 it read 4 passed, 0 failed, 1 skipped of 5.
Earlier internal rounds could not see this at all, because the farm mock here pays its rewards by
minting and a paused token still allows a mint, so on the mocks a paused token never bites inside
the farm.

### A USDC pause shuts every cure while the liquidation and workout clocks keep running. Medium, conditional on a USDC pause; open, not fixed, dated 2026-09-21

No interest accrues in this protocol, so a borrower's debt does not grow while a token is paused.
What moves is the NAV and three clocks: the six-hour auction, the 48-hour reset window and the
fourteen-day workout. `liquidate`, `start`, the in-place re-strike, `expireToWorkout`, `closeWorkout`
and `cancel` touch no token, so all of them run under a paused USDC. Every cure does touch one.
`repay`, `repayFor` and `bid` move USDC, and `depositBonds` - adding collateral, the answer to a
falling NAV - reverts for the separate reason in the entry above, because the farm settles its
pending USDC inside the same call.

Measured on the four-contract graph with a paused token, a borrower at the ceiling owing 628.750000
who holds the WHOLE debt in her wallet, 50 spare bonds, a funded rescuer and a bidder ready since
before the pause: `repay` of everything reverts; `repayFor` by the rescuer reverts; `depositBonds`
of the 50 spare bonds reverts; `liquidate` by the keeper succeeds; `bid` by the waiting bidder
reverts; `expireToWorkout` succeeds at six hours after the pause and pays its caller the 25.000000
bounty at once; `workoutSettle` reverts; `closeWorkout` by a stranger succeeds at 342 hours after
the pause, socialising 628.750000 onto the lenders, whose worth falls from 20,000.000000 to
19,371.250000. With the token LIVE and the same NAV move, the same borrower keeps 471.562500 and the
lenders lose nothing. Under the pause she keeps 0, and 503.000000 of her equity sits on a lot worth
1,131.750000 at the moved NAV that only the owner can dispose of. The lenders are made whole only if
somebody pays the late tranche, which is capped at the written-down debt, streamed back over up to
thirty days, to whoever holds shares then.

Six hours is enough on its own. Pause one minute into a live auction and at six hours one minute
anyone's `expireToWorkout` goes through under the pause; after the unpause the lot is out of the
auction for good, `bid` and `liquidate` both revert on it, and one workout stands open. Both of
those doors are permissionless and the lapse pays its caller immediately. Past the 48-hour reset
window the workout is the only door: the re-strike reverts, though a cure after the unpause still
works, and the lapse then cancels.

No Recoup lever stops this. With `pause` engaged on the credit manager, on the pool and on the
vault, and bond deposits paused as well, `liquidate`, `expireToWorkout` and `closeWorkout` all still
succeed and the same 628.750000 is socialised. The one lever that reaches a LIVE auction is the
owner ratcheting `liquidationThresholdBps` to its bound of 5,800, which makes a position at 5,555
bps healthy again so the permissionless `cancel` returns the lot. That reaches a NAV move of at most
about 13.8 percent past the old threshold, reaches nothing once a workout is open, and in production
sits behind the 48-hour risk timelock against a six-hour auction, which is read from the intended
governance design rather than executed.

The workout design itself is deliberate and is disclosed above: the mark values the loan at zero
while an auction or workout stands, and the lot is offered to the market before it is written down.
What the pause breaks is its premise. The design reads "no bid" as evidence about the collateral,
and under a pause no bid is evidence of nothing.

Status: open, not fixed, no design decision taken. Severity Medium, conditional on a USDC pause:
impact high, likelihood low, and Circle has never paused USDC. The reproduction is on the same
`src/` as this repository and is NOT in this repository yet.

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

### The epoch leg of `_rateStream` re-rates a running recovery stream over a whole harvester drought. Medium-low; the window is bounded in this source since 2026-09-14

Rule 1 takes `max(elapsed, D, remaining)` over the whole pot including a recovery tail that is
deliberately rated over its own five-day floor. Measured at b66023d, before the ceiling: after sixty
quiet days a `distributeYield` of any size (one wei reproduces it) slows a running recovery stream
fifteen times and pushes `yieldStreamEndsAt` to `now + 61 days`; a lender exiting inside that
window forfeits 3,687.67 of a 5,000 USDC recovery share to the stayers. It is the F11 harm one
composition later, recovery first and drought epoch second, which the stream-clock tests cover only
from cold. Realised by a voluntary exit; the triggering block is the harvester's or a stranger's
`flushLenderYield`. Since 2026-09-14 the epoch leg is clamped at `Config.MAX_YIELD_STREAM_DURATION`
(30 days) in `_rateStream`, so the same sixty-day flush rates the pot, recovery tail included, over
30 days rather than 61: `test_clock_signCheck_ruleTwoStillRefusesToShortenARunningStream` in
[`test/YieldStreamClock.t.sol`](test/YieldStreamClock.t.sol) asserts `yieldStreamEndsAt` is
`now + MAX_YIELD_STREAM_DURATION` after a sixty-day gap. The forfeit inside that window was not
re-measured under the ceiling; the 3,687.67 is the pre-ceiling figure. The ceiling bounds the
composition without separating the rates: the recovery tail is still re-rated with the epoch pot,
over at most 30 days. Bounding the epoch leg by the funded amount instead was not sign-checked,
since it preserves the recovery here but lets a drought epoch on a large tail pay out faster than
rule 1 intends, and the two-rate fix that would close the composition outright is not built. The
external reviewers' M-04 restates the unbounded window together with the gross entry pricing; the
ceiling, its figure and the trade it makes are in the external review section below.

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

**Written on 2026-09-07 about commit b66023d and kept as written: every present tense in this paragraph, "is fixed in source not yet synced" and "is not in this source" included, is about that commit; in this source the fix has been present since 2026-09-12, as the paragraph above and the #46 and #53 rows below record.** `LenderPool.recoverLoss` accepts only the manager the pool currently points at, and
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

### The withdrawal-request "reserve" is a per-call pro-rata bound, not a reservation. Documentation, corrected in this source since 2026-09-12; the request door is bounded per controller since 2026-09-14; a queued lender is owed a cash floor since 2026-09-15

`_unreservedIdle` is the executable balance less the ceiling of executable times queued over supply, re-derived on every call, so
a non-requester can unwind the reserved cash to 0.011 percent of itself in twelve fair-priced
redeems while the requester's whole-request value stays exactly at book. The sync door caps a
holder at all cash not reserved by someone else (114.59 against 236.30 USDC in the same state). The
per-call bound was the intended semantics of the reserve until 2026-09-15, and a checkpointed cash
floor valued against the whole book is the refused F7 shape. What was wrong at b66023d was the wording, and the previous revision of this
paragraph was wrong in the same direction: it said the request door "caps a controller at their own
fraction of cash", which is true of one service call and false cumulatively. The external reviewers'
H-03 measured that: in their state a single fair slice is 4,874,250,000, stepped service reaches
4,999,999,999 over seven calls, and one synchronous `redeem` of the same shares from the same
snapshot quotes and pays 5,000,000,000 and leaves no shares. The 2026-09-12 revision of this
paragraph then said the stepped loop reaches no more than the synchronous door already allows, which
holds with nobody else queued and fails with another lender's request holding the reserve: the same
loop then out-paid one synchronous `redeem` by 2,499.999998 (the counter-case in the #47 row
below). Since 2026-09-14 `maxRequestRedeem` nets the controller's own earlier draws out of the
slice (`_requestDraws`), so servicing one request in steps reaches exactly one slice of the cash as
it stands, and `test_H03_steppedRequestServiceReachesNoMoreThanOneSyncRedeem` in
[`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol) now asserts the stepped
total equals the single slice. Until 2026-09-15 that still did not make the reserve a cash
guarantee: it was a fraction of live executable cash, re-derived on every read, so the synchronous
door stepped, or a position walked through fresh controllers, still reached the total the loop had
reached, and a queued lender's serviceable figure fell with each step. Since 2026-09-15 a queued
lender is owed the cash she was quoted when she queued: `requestWithdrawal` records a floor per
request (`WithdrawalRequest.floor`, priced by `_freshFloor` as the executable cash not already
reserved for the requests ahead of her, pro rata over the shares not yet queued), `_queueCashReserve`
is never below the sum of the live floors (`_floorTotal`) and never above the executable cash, so
the floor is held against `lend`, against every synchronous exit and against every other request
until she is paid or cancels, and `maxRequestRedeem` pays the larger of her remaining floor and her
live slice, capped at the cash not owed to the other requests. The #47 row carries the figures and
the cost. The checkpointed floor refused as the F7 shape was valued against the whole book; this one
is priced out of executable cash after the entry-price reserve, which is why F7's leverage
multiplier does not return with it. The file header, the `maxRequestRedeem` docstring and the
`queueCashReserve` docstring in `LenderPool` say all of this; at commit b66023d they overstated the
bound as a reservation, at the 2026-09-12 sync they understated what the stepped loop could reach,
and since 2026-09-15 the reservation is an amount.

Two consequences of the floor at the request door, measured in
[`test/RequestDoorResidue.t.sol`](test/RequestDoorResidue.t.sol) on a book half lent with yield
streaming, where a requester services half her request and then runs the ordinary
`maxRequestRedeem` loop; neither loses anyone money. Spending a floor rounds down twice, so at most
1 wei of floor stays behind per live request, and the door that wei holds open is 983 share-wei
whose `previewRedeem` is 0: a service there with `minAssetsOut` of 1 is refused and one with 0
burns her own share-wei for nothing, so a loop should stop on a door that previews 0 and not only
on a door of 0. And her yield above her floor is paid only once the cash comes back: the floor was
spent by those first steps, and what her remaining shares earn after that is paid only by her live
slice of the executable cash, net of what she has already drawn. With 50,000 still lent and 5,000
of yield an epoch, her 327,868,851,802 remaining share-wei stay escrowed for nine epochs while
their worth grows from 367.346938 to 530.612243, and are paid in the tenth. A cancel then a
synchronous `redeem` pays the same remainder at once, at its full worth.

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
  wrong for them. The 2026-09-15 sync adds one more, `_floorTotal`, written by `requestWithdrawal`,
  `serviceWithdrawalRequest` and `cancelWithdrawalRequest`; the hand count above predates it and was
  not re-derived. Over an assembly-free copy the lint reads the file and reports nothing.
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
  reading of this commit. Re-run on 2026-09-18 over this repository at 0f49e61, Slither 0.11.5
  with the same path filter (the library, test and script directories excluded) and no detector excluded reads
  273 results across 54 contracts, 11 High and 104 Medium, and with no path filter 359, 12 High and
  115 Medium. The 273 have not been re-triaged at this commit; the triage above is of the 269.

## External review, 33audits preliminary issues #45 to #54 (2026-09-11)

The external reviewers filed ten preliminary issues against commit b66023d on 2026-09-11, each with
a Foundry reproduction written against this repository's own test fixtures. All ten reproduce at
b66023d. Four of them (H-02, M-01, M-02, M-03) had been fixed in the development tree between
2026-09-03 and 2026-09-07 and had not been synced to this repository; two (L-01, L-02) were already
disclosed above; one (M-04) was disclosed in parts; and three (H-01, H-03, M-05) were new. The table
below is the status of each issue **in this source from the 2026-09-15 sync on**; the 2026-09-12
sync was the first since the issues were filed, the 2026-09-14 sync adds the M-04 ceiling, the
L-02 fix and the H-03 request-draw memory, and the 2026-09-15 sync adds the H-03 cash floor. Every function and test it names is in `src/` or `test/`
here. Byte figures are the runtime deltas of the fix against the source immediately before it,
measured with `forge build --sizes` on a clean build; "earlier" means the fix is in this sync but
landed in the development tree before the issues were filed, so its delta is not itemised.

On 2026-09-16 the reviewers verified, on this source at 68c0c26, the fixes for #45, #46 and #48 and
the three drain routes of #47 (their comments 5700959027, 5700962106, 5700964558 and 5700944284 on
the respective issues). The post-loss liquidity lock the #47 row discloses was disposed by the maintainer on 2026-09-17 as
held and disclosed at Low (comment 5715504360 on #47; the heading under material residual risks
above states it present tense). The reviewers answered on 2026-09-17 (comment 5718920756): record the residual separately as a Low, acknowledged and retained by design, and close the original High without the write-down once the stated bound is corrected, which 0f49e61 (#60) did; the Low is #61. On 2026-09-18 they reported 0f49e61 reviewed and supported closing the original H-03 as verified fixed (comment 5727241497 on #47). The audit completed on 2026-09-22; the final report is in [`audits/`](audits/). Those five are the verification comments as
of 2026-09-18; the other six rows stand on this record's own tests.

| Issue | Title as filed | Status in this source | Runtime bytes |
|---|---|---|---|
| #45 H-01 | Borrower-keyed recovery provenance redirects an earlier workout's recovery | **Fixed.** `writeDownLoss` and `recoverWrittenDownLoss` on `ICreditManager` take the auction id, and `CreditManager` records the bearer and the funder per auction and id in `recoveryBearerOf` and `recoveryFunderOf` and routes the recovery through them; `lossBearerOf` and `lossFunderOf` stay as the borrower's latest record. `LiquidationAuction` passes the id at `closeWorkout`, `workoutSettleAfterClose` and `_settleFill`. Regression: `test_H01_aLaterDefaultDoesNotRedirectAnEarlierWorkoutsRecovery` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol), the reviewers' reproduction with its last two assertions reversed: the first workout's pool is paid 628,750,000 and the second's 0, then the second is paid its own; and in [`test/R59A02_H01SecondDefault.t.sol`](test/R59A02_H01SecondDefault.t.sol) the two records are read out of storage for two write-downs by the same borrower, the second write-down is recovered first and both still route correctly, the fix composes with L-01 across a pool migration and a manager migration, and one auction id carries at most one write-down. The two records are internal because making them public getters put the manager under 2,000 bytes of runtime margin. Verified fixed by the reviewers on 68c0c26, 2026-09-16 (comment 5700959027) | `CreditManager` +307, `LiquidationAuction` +17 |
| #46 H-02 | Auction replacement orphans a closed workout's recovery leg | **Fixed, earlier.** This is the auction-side twin the previous revision of this file called fixed but not yet synced. `setLiquidationAuction` stamps `wasLiquidationAuction`, and `recoverWrittenDownLoss` accepts the live auction or a former one; `checkAuctionSwap` is unchanged, so no fourth clause was added to the migration guard. Regressions: `test_R46_theRecoveryLandsAfterALegalAuctionRepoint` and `test_R46_aFormerAuctionReachesNoOtherAuctionGatedLeg` in [`test/R46AuctionRepointRecovery.t.sol`](test/R46AuctionRepointRecovery.t.sol), `test_R22_theReturnLegSurvivesAMigrationToAFreshAuction` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol). Verified fixed by the reviewers on 68c0c26, 2026-09-16 (comment 5700962106) | earlier |
| #47 H-03 | Repeated request service converts more than a requester's pro-rata cash into senior claims | **Fixed on both doors: the reviewers' request-draw memory (2026-09-14) closes the same-controller loop, and a cash floor per request (2026-09-15) closes the two routes the memory left open, at the cost disclosed at the end of this row.** The 2026-09-12 revision of this row said the stepped loop reaches no more than the synchronous door already allows; that was measured with nobody else queued and is false with another lender's request holding the reserve. Counter-case, two lenders of 10,000 with 15,000 lent and the other lender's whole position queued: before the memory the same-controller request loop paid 4,999.999998 over 53 calls against 2,500.000000 from one synchronous `redeem` of the same shares, 45 of 60 cells of a grid over the queue and the loan favoured the loop, and the best excess was 3,999.999995 (`test_R59A02_H03_aSecondLendersQueueMakesTheLoopBeatTheSyncDoor` and `test_R59A02_H03_gridSearchForTheBestCounterCase` in [`test/R59A02_H03CounterCase.t.sol`](test/R59A02_H03CounterCase.t.sol), which assert the closed state and keep those figures as history). The memory is the reviewers' per-controller record (`RequestDraw`, `_requestDraws`, declared after every older slot): `maxRequestRedeem` adds the controller's earlier draws back into all three terms of the slice and deducts them from the answer, and `serviceWithdrawalRequest` records each service and clears the memory only once the request is empty and the controller holds no shares, which is what closes cancel-and-re-request. The reviewers' eight tests pass verbatim in [`test/R60S1_H03RequestDraw.t.sol`](test/R60S1_H03RequestDraw.t.sol): the loop 2,500.000000 in one call, 0 of 60 grid cells, cancel-and-re-request 2,500.000000; and `test_H03_steppedRequestServiceReachesNoMoreThanOneSyncRedeem` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol) asserts the stepped total equals the single slice, 4,874.250000. Before this sync `queueCashReserve` was a fraction of live cash rather than an amount of it, so from the same state the stepped synchronous door, `redeem(maxRedeem)` until it read zero, paid 4,999.999998 over 53 calls with no request serviced, a walk through forty fresh controllers one request each paid 4,999.999773 through either door, and the queued lender's serviceable figure ended at 0.000001 either way. Since 2026-09-15 a queued lender is owed the cash she was quoted when she queued. `requestWithdrawal` quotes a floor through `_freshFloor`, the executable cash not already reserved for the requests ahead of her, pro rata over the shares not yet queued, and records it in `WithdrawalRequest.floor`; with no earlier floor binding that is exactly her pro-rata slice, and where the earlier floors hold the whole cash it is 0, so the floors never exceed the cash at request time. Their sum, `_floorTotal` (declared last, at slot 33, so no existing slot moves; `LenderPoolFormulaPins` pins the layout), is the second arm of `_queueCashReserve`: the reserve is the larger of the queued shares' pro-rata fraction and the floors, clamped at the executable cash, so the floor is held against `lend`, against every synchronous exit and against every other request until she is paid or cancels. `maxRequestRedeem` pays the larger of her remaining floor and her live slice, capped at the executable cash not owed to the other live requests, which is the request-door twin of `_unreservedIdle` and is what stops a fresh controller's empty memory re-slicing cash the floors hold; `serviceWithdrawalRequest` spends the floor by what it paid and releases whatever is left when the request is gone; `cancelWithdrawalRequest` releases it whole. The memory stays, because under a floor it is what holds one request to one slice of the cash above the floor. Measured on this source from the counter-case: the stepped synchronous door, the sequential split through either door and cancel-and-re-request each pay 2,500.000000 in one call, the walk stops with 7,500 shares on its first address, and she keeps 2,500.000000 before and after (`test_R60S1_H03_theSyncDoorSteppedDrainsTheSameCash`, `test_R60S1_H03_theSequentialAddressSplitThroughTheRequestDoor` and `test_R60S1_H03_theSequentialAddressSplitThroughTheSyncDoor` in [`test/R60S1_H03Routes.t.sol`](test/R60S1_H03Routes.t.sol), which asserted the open figures until this sync and keep them as history; the reviewers' five verification tests of the two routes and the two side effects, ported verbatim as `test_R42S1_verify47_route2_syncDoorStepped`, `test_R42S1_verify47_route3_sequentialSplitRequestDoor`, `test_R42S1_verify47_route3_sequentialSplitSyncDoor`, `test_R42S1_verify47_phantomReserve` and `test_R42S1_verify47_staleMemory` in [`test/R60S1_H03RequestDraw.t.sol`](test/R60S1_H03RequestDraw.t.sol), with the floor's figures asserted under their logs and the fraction's beside them; and `test_R59A02_H03_theExcessComesOutOfTheQueuedLendersOwnReserve`, which asserted her loss and now asserts her figure unmoved). The memory's two side effects, re-measured in [`test/R60S1_H03Probes.t.sol`](test/R60S1_H03Probes.t.sol): the phantom reserve is 0 in the two-lender state where the floor binds (1,071.428572 before this sync) and 347.826087 in the three-lender state where the fraction arm still exceeds the floors (1,043.478261 before), because that arm still counts queued shares whose controller has drawn its whole slice; and the memory still outlives the position it priced, but no re-request is priced below its fresh floor, so the controller whose ratio of cash to supply fell reads 750.000000, equal to a fresh holder (0 before this sync), and a request with shares transferred in reaches no more than a fresh holder's slice. What the floor costs, present tense about this source and measured in [`test/R42S1_H03Floor.t.sol`](test/R42S1_H03Floor.t.sol): the floors are not written down on a loss, so after a raw loss their sum can exceed the executable cash. Each request is then capped at the cash the others are not owed, so nobody is paid beyond what exists, but the cash no door can reach is locked, and the amount locked is NOT bounded by the raw loss: with several equal floors every cap can read 0 at once and the whole remaining cash is locked, three floors of 100.000000 locking 200.000000 against 100.000000 lost and one hundred floors locking 9,900.000000 (the reviewers' rows on #47, comment 5718920756, ported verbatim as `test_AuditH03_threeFloorsLockMoreThanTheRawLoss` and `test_AuditH03_oneHundredFloorsLockNinetyNineTimesTheRawLoss` in [`test/R60S2_H03LockBound.t.sol`](test/R60S2_H03LockBound.t.sol), where `testFuzz_R60S2_theLockIsTheQueueNotTheRawLoss` states the general form over 2 to 40 equal floors and any raw loss inside the book). The excess of the floors over the cash measures the shortfall, not the amount locked. With two floors of 2,000.000000 and 1,000.000000 and 2,500 of cash lost from 5,000, the two requests are serviced to 1,499.999999 and 499.999999, 500.000002 of executable cash remains, and `unreservedIdle`, the third lender's `maxRedeem` and `available()` all read 0: no door reaches it until a repayment or a new deposit lifts the cash above the floors or one of them cancels (`test_R42S1_floorF_aLossWithTwoFloorsLocksTheOverPromise`; after a `repayPrincipal` of 20,000 the two read 7,499.999965 and 3,999.999925 and `available()` 7,650.000095). The repair doors do not release it: `claimSolvencyDeficit()` and `entryPriceDeficit()` both read 0 in that state, and `coverClaimDeficit(1)` and `coverEntryPriceDeficit(1)` revert `ClaimDeficitExceeded` and `EntryPriceDeficitExceeded`, because the locked cash is recognised shareholder cash promised twice, not a shortfall either door is built for. A queued lender who never services holds a cash amount against lending, not a fraction the next exit shrinks, until she cancels (`test_R42S1_floorG_theFloorHoldsAgainstLendingUntilRepaidOrCancelled`). The floor does not ratchet up: it is what she was quoted, the live slice above it rises with a repayment, and other exits re-slice that lift back down to the floor (`test_R42S1_floorH_theUpwardRederivationIsAFractionTheSyncDoorReslices`: after a 5,000 repayment her slice reads 5,000.000000, the stepped sync door pays 7,500.000000 over 4 calls, and she is left with her floor of 2,500.000000; `test_R42S1_floorI_aDroughtFloorDoesNotRatchetUp`: a floor of 1,500.000000 quoted in a drought stays 1,500.000000 while the slice reads 6,000.000000 after a 9,000 repayment and 4,050.000000 once that cash is lent again). An unqueued holder's share of the cash is what a walker still reaches, through either door, which is the non-requester exposure the paragraph above has disclosed since 2026-09-12 and is unchanged by the floor (`test_R42S1_floorD_theUnqueuedBystanderIsWhatTheAttackerReaches`): a holder who wants a reservation queues for one. In [`test/LenderPool.invariants.t.sol`](test/LenderPool.invariants.t.sol), `invariant_oneRequestNeverDrawsMoreThanOneSliceOfTheLiveCash` now bounds each service by the larger of the floor and the live slice, capped at the cash not owed to the other floors, `invariant_theFloorTotalIsTheSumOfTheLiveFloors` and `invariant_noServiceEverPaysBeyondTheExecutableCash` are new, and `test_handlerCanReachABoundFloorAndAFloorBoundService` asserts the campaign reaches a bound floor and a floor-bound service rather than assuming it. The variants refused before the floor stay refused: never clearing the memory (+172), clearing it on transfer or on request, and the aggregate reconstruction of the reserve (+532, +533); a floor without the memory was measured to reopen the same-controller loop up to the cap and was not shipped. On 2026-09-16 the reviewers verified the three drain routes fixed on 68c0c26 (comment 5700944284), reproduced the post-loss lock above at the same 500.000002, and wrote that it "still needs an explicit audit-team disposition before unconditional closure"; the maintainer's disposition, hold the lock as a disclosed residual at Low with the floor write-down costed and refused, is posted on #47 (comment 5715504360, 2026-09-17) and stated present tense under the heading "33audits H-03, the post-loss lock the floor retains" above. The reviewers answered on 2026-09-17 (comment 5718920756): the three withdrawal routes stay verified fixed on 68c0c26, the residual is recorded separately as a Low that is acknowledged and retained by design rather than fixed, and they support closing the original High without the floor write-down shipping, once the bound is corrected and multiple-request coverage is added. Both shipped in 0f49e61 (#60): the corrected bound under that heading, and [`test/R60S2_H03LockBound.t.sol`](test/R60S2_H03LockBound.t.sol); on 2026-09-18 the reviewers supported closing the original H-03 as verified fixed on that commit (comment 5727241497), with the lock tracked as #61 | `LenderPool` +219 (memory, 2026-09-14) and +370 (floor, 2026-09-15) |
| #48 M-01 | Permissionless yield sweep can confiscate an open workout's borrower yield | **Fixed, earlier.** `_fundInsuranceWithFree`, which both pre-close sweeps go through, owes `totalUnclaimedRewards + totalWorkoutYieldOwed + _openWorkoutAccrual`; the third term is the accrual on every open workout's bonds, read from the manager's accumulator, so `sweepWorkoutYieldToInsurance` reverts `NothingUnreserved` rather than moving it. Regressions: `test_R51_154_regression_aStrangerCannotSweepAnOpenWorkoutsBacking` in [`test/R51A02_OverRealisationDoor.t.sol`](test/R51A02_OverRealisationDoor.t.sol), `test_R56A02_81_negative_walk00_sweepWorkoutYieldFirst` in [`test/R56A02_SweepVersusF18.t.sol`](test/R56A02_SweepVersusF18.t.sol). Verified fixed by the reviewers on 68c0c26, 2026-09-16 (comment 5700964558) | earlier |
| #49 M-02 | Realised open-workout yield bypasses the dedicated sweep protection | **Fixed, earlier, by the same reserve.** It is derived from the accumulator and not from where the cash sits, so realising the yield onto the auction through `claimSurplusFor` and taking it with `sweepFreeBalanceToInsurance` is refused the same way. Regressions: `test_R51_154_regression_theSiblingSweepReachesItWithNoClaimInFront` in [`test/R51A02_OverRealisationDoor.t.sol`](test/R51A02_OverRealisationDoor.t.sol), `test_R56A02_81_negative_walk02_claimSurplusForFirst` in [`test/R56A02_SweepVersusF18.t.sol`](test/R56A02_SweepVersusF18.t.sol) | earlier |
| #50 M-03 | First clean workout close captures shared residual yield | **Fixed, earlier.** The shortfall that close ordering allocated can no longer be created once the open-workout accrual is reserved, and the owed ledger is kept per bearer. The public test at b66023d, `test_R23_04_theResidual_aSweptPotIsAllocatedToWhicheverClosesFirst`, asserted that the second close booked nothing, which was a pinned disclosure of the round 22 F18 residual and is what the reviewers' reproduction restates; it now asserts that both closes book and are paid, beside `test_R23_04_twoCleanClosesCannotBookTheSameClaimTwice` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol). The forced-close fix the reviewers asked about is separate and is in this source; see the round 54 paragraph above | earlier |
| #51 M-04 | Uncapped stream duration plus gross entry pricing lets a timed flush overcharge new lenders | **Fixed.** `Config.MAX_YIELD_STREAM_DURATION = 30 days` and a one-line clamp on the epoch leg of `_rateStream`: the window a delivered pot is rated over is the larger of the gap since the last delivery and `YIELD_STREAM_DURATION`, capped at `MAX_YIELD_STREAM_DURATION`. The gross entry pricing is the disclosed F10 decision above and is unchanged. The ceiling changes how long anyone waits and not what anyone can take, measured on the reviewers' own 180-day fixture (two equal holders, one 1,000.000000 pot) at 30, 60, 90 and 120 days and with no ceiling in [`test/R60S3_M04Curve.t.sol`](test/R60S3_M04Curve.t.sol): the staker who arrives one block before the flush captures 499.999999 at every setting and only their annualised rate moves, 6,083 / 3,041 / 2,027 / 1,520 / 1,013 bps at 30 / 60 / 90 / 120 days / none; an incumbent leaving 30 days after the flush takes 499.999999 of the pot with the ceiling against 83.333332 without it, the stayer 500.000000 against 916.666667; a 3,000.000000 newcomer is redeemable at 2,875.000000 on arrival at every setting and whole at day 30 rather than day 180. Two flushes inside one window do not compound: a second epoch five days into a clamped stream inherits the first window's end, one landing a day before the end moves it by its own window and no further, and the end is never more than the ceiling past the latest flush, fuzzed over every offset. The ceiling moves the transfer rather than removing it: the timed staker's multiple over the honest incumbent's rate is the gap over the ceiling, six times at 30 days on a 180-day gap against twice at the 90 the reviewers recommended, and 30 was kept because the newcomer's exposure is involuntary and invisible at the door while the timed staker's is a position taken with foresight and the pool's full credit risk, on a pot the delivered-cohort rule already grants them; the cost, that for an outage between about a month and a quarter the catch-up flush is worth turning up for at 30 and not at 90, is stated rather than hidden. Tests on the shipped constant: `testFuzz_clock_theEpochWindowIsFloorAndCeilingBounded`, `test_clock_measure_whatTheCeilingHandsAnIncumbentStakedForExactlyMax` and `test_clock_measure_theNewcomersHoldingPeriodIsTheCeilingNotTheGap` in [`test/YieldStreamClock.t.sol`](test/YieldStreamClock.t.sol); [`test/R59A02_M04WhichSide.t.sol`](test/R59A02_M04WhichSide.t.sol), whose executed arm is the shipped one on the reviewers' fixture, whose no-ceiling column is retained as measured constants, and whose `setUp` asserts the constant so a retune fails the file loudly rather than re-rating its literals; and the two drought pins in [`test/LenderPoolEntryPricing.t.sol`](test/LenderPoolEntryPricing.t.sol), which read the ceiling | `LenderPool` +18 |
| #52 M-05 | A lender-yield backlog above the deposit-cap ceiling can never be delivered | **Fixed.** `distributeYield` clamps the streamable amount to capital only in the terminal state where the cap is at `GLOBAL_BORROW_CAP_MAX` and `depositCapUsage` has reached it; every other oversize offer still reverts `YieldExceedsCapital`, so the one-cent capture the refusal exists for stays refused. The harvester's `_push` decrements `pendingLenderYield` by measured delivery, so the remainder stays pending and drains over successive flushes. Regressions in [`test/LenderPool.t.sol`](test/LenderPool.t.sol): the reviewers' three, `test_distributeYield_theHardCeilingAdmitsNoMoreCapital`, `test_distributeYield_aBacklogAboveTheHardCeilingIsClampedNotRefused` and `test_distributeYield_anOfferOfExactlyCapitalIsAcceptedInFull`, plus `test_distributeYield_aBacklogAboveTheHardCeilingDrainsOverSuccessiveFlushes` (900,000 drained in three flushes) and `test_distributeYield_belowTheHardCeilingTheRefusalIsUnchanged`; and `test_R40_D7_theBacklogAboveTheHardCeilingDrainsThroughTheRealHarvester` in [`test/R40D7Capture.t.sol`](test/R40D7Capture.t.sol), 400,000 through `flushLenderYield` in two flushes; and [`test/R59A02_M05Clamp.t.sol`](test/R59A02_M05Clamp.t.sol), which fires the clamp through a pause, shows a partial cap still refusing and the owner lever opening it and a reconciled cash loss closing the clamp and reopening the door, measures the drain as geometric over successive flushes and still progressing with no time between them, and measures the one stranding the clamp cannot reach: a backlog above a pool frozen below `MIN_SUPPLY_FOR_YIELD` is refused `NoSharesOutstanding` for ever, because the clamp's predicate is never true there (that freeze is the zero-supply derecognition item above) | `LenderPool` +60 |
| #53 L-01 | Manager migration strands post-close loss recoveries with no unblocked repair path | **Fixed. High, re-rated by the auditor 2026-09-12** from the Low it was filed at, to the grade this record already carried. `LenderPool.setCreditManager` stamps `wasCreditManager`, and `recoverLoss` accepts the live manager or a former one and pulls from and credits `msg.sender`. The parked-tranche alternative the reviewers proposed, a pool-side balance drained by a permissionless flush, was built and refused by execution: +561 runtime bytes as built, and the drain calls `recoverLoss` from the retired manager, so it is dischargeable only by pointing the pool back, which reverts `PrincipalOutstanding` once the successor has lent. Regressions: `test_L01_managerMigrationNoLongerStrandsPostCloseRecovery` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol); `test_R46_theRecoveryLandsAfterALegalPoolRepoint`, `test_R46_theOnlyRouteIntoTheRecoveryIsTheAuctionAndItIsOpen` and `test_R46_aFormerManagerReachesNoOtherManagerGatedLeg` in [`test/R46AuctionRepointRecovery.t.sol`](test/R46AuctionRepointRecovery.t.sol); `test_regression_aLateTrancheAfterARepointFollowsTheBearerEvenAfterThePoolMovesOn` in [`test/R55A01_WorkoutLifecycle.t.sol`](test/R55A01_WorkoutLifecycle.t.sol); `test_R59A02_L01_withTheDisposalTheAuditorsPoCPassesAsAFix` in [`test/R59A02_H01SecondDefault.t.sol`](test/R59A02_H01SecondDefault.t.sol), the reviewers' PoC verbatim with the lot disposal this tree's wiring doors require. The composition the former-manager door leaves is measured in [`test/R59A02_RetiredManagerDelivers.t.sol`](test/R59A02_RetiredManagerDelivers.t.sol): a retired manager can deliver a recovery into a pool frozen between zero and `MIN_SUPPLY_FOR_YIELD` at any time, where it joins the frozen pot, releases to nobody, is charged to every later entrant and consumes deposit-cap headroom nothing gives back; in a healthy pool the same delivery streams to the sitting lenders, which is the intended behaviour, and only the headroom cost remains | `LenderPool` +72 |
| #54 L-02 | Permissionless settle discards a borrower's sub-unit yield accrual | **Fixed with the reviewers' second shape, at -57 runtime bytes; Low stays.** `_settle` takes a `bondCountMoving` flag. On a path that moves no bond count (`settle`, `borrow`, `claimSurplus`, `liquidate` and `writeDownLoss`, all through `_settleLive`) the index advances by exactly the part actually paid, `owed` times `ACC_PRECISION` over `bonds`, so a floored remainder stays in the index gap, is read by `pendingYieldOf` and is paid once it reaches a base unit, and nothing is written at all when `owed` is zero. On a count-changing path (`settleForVault`, which the vault calls ahead of `depositBonds`, `withdrawBonds`, `reassign`, `seize` and `disposeTo`) the index is still stamped at the accumulator, because a remainder earned at the old count and priced at the new one is the revaluation the one-line skip minted 925,925 and then 336 wei through; `test_L02_aZeroFlooredSettleBeforeATopUpCreditsNoMoreThanWasStreamed` in [`test/Impairment.integration.t.sol`](test/Impairment.integration.t.sol) pins that and is unchanged. The reviewers' exact shape on the previous source measured +99 (22,617 / 1,959, under the 2,000-byte margin floor the manager is held to); routing `borrow` and `_claimSurplus` through the existing `_settleLive` is -149 on its own and the trimmed branch on top of it is +92, net -57. The `bonds == 0` arm of their shape was dropped: `_pending` is zero there and the vault stamps a new position at count zero before its first deposit lands. Probed in [`test/R60S2_L02Probes.t.sol`](test/R60S2_L02Probes.t.sol), nineteen tests: the retained gap stays under one base unit at 1, 7, 100 and a million bonds with zero over-credit from accumulator slack; the grind now destroys nothing; every count-changing path destroys the gap it finds and none re-prices it, while the four non-moving doors leave it where it was; a manager migration freezes it on the outgoing manager as a phantom `pendingYieldOf` priced at the live count that nothing can realise. `invariant_noIndexEverOvertakesTheAccumulator` in [`test/CreditManager.invariants.t.sol`](test/CreditManager.invariants.t.sol) watches the index on every frame; a planted one-unit overshoot goes red on three invariants at once, the third being `withdrawBonds` reverting, which is the trapped collateral the property exists to name. The residual, and why Low stays: the count-changing stamp still destroys under one base unit per change, so the auction's dust deadlock, in which `closeWorkout` books a lot's yield at one floor against a pot that is a sum of floors, is still reachable through count changes alone. Eight extra lots liquidated into the auction's pooled position and closed clean, sixteen count changes and no `settle` call at all, leave the bookings one wei above the pot, ten wei of bookings standing after every claim and `NothingUnreserved` on the sweep; bounded at one wei per count change and pinned. The five tests that asserted the grind opened a gap were flipped on their own fixtures in [`test/R55A02_AuctionHeldOut.t.sol`](test/R55A02_AuctionHeldOut.t.sol), [`test/R57A02_GrindTwoManagers.t.sol`](test/R57A02_GrindTwoManagers.t.sol) and [`test/R53A01_VariantSplit.t.sol`](test/R53A01_VariantSplit.t.sol), so the same grinds now assert no gap, both claims paid in full and nothing standing | `CreditManager` -57 |

Measured on this source with `forge build --sizes` on a clean build on 2026-09-15, forge 1.8.1, and
identical row for row in the public CI run 35032144995 on forge 1.8.3 at 68c0c26:
`CreditManager` 22,461 bytes of runtime with 2,115 of EIP-170 margin and 23,796 of initcode with
25,356 of EIP-3860 margin; `LiquidationAuction` 21,022 / 3,554 and 22,437 / 26,715; `LenderPool`
21,226 / 3,350 and 22,598 / 26,554. `CreditManager` is the contract that binds. Against the
2026-09-14 sync the pool carries the floor's +370 of runtime and +370 of initcode and the manager
and the auction are unmoved; against the 2026-09-12 sync the manager is 57 bytes of runtime smaller
(L-02) and the pool carries M-04's +18, the memory's +219 and the floor's +370.

Of the six audited files, the 2026-09-15 sync changes `src/LenderPool.sol` only (the H-03 cash
floor, on top of the M-04 clamp and the H-03 memory of the 2026-09-14 sync and the L-01, M-05 and
H-03 docstring changes of the 2026-09-12 sync); `src/Config.sol` is as the 2026-09-14 sync left it
(one constant, `MAX_YIELD_STREAM_DURATION`, with its docstring; otherwise byte-identical to
b66023d). `src/LenderPool.sol` additionally differs from b66023d by the
`transferOwnership` guardian guard the 2026-09-01 sync carried. `src/CreditWiring.sol` and
`src/LtvMath.sol` are byte-identical to b66023d; `src/TreasuryLiquiditySource.sol` and
`src/ProtocolFeeSplitter.sol` differ from it in comments only. Outside the audited six,
`src/CreditManager.sol` carries L-02 (2026-09-14) and H-01 (2026-09-12), and
`src/LiquidationAuction.sol` and `src/interfaces/ICreditManager.sol` carry H-01.

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

At commit 68c0c26, measured on 2026-09-17 on a clean `forge build` with forge 1.8.1, the
creation/runtime sizes are 2,150/1,350 bytes, with keccak256 hashes
`0x87a4f28569e0fea184d4ee65f0e8725c9cf4aaf9b4634cefe668e318f346532c` (creation) and
`0x7d736d1a08568e90442015700984f27634b326148a79f9989edd8f412df02f95` (runtime). Compiler metadata
remains a 51-byte CBOR trailer, with embedded IPFS digest
`0xf5c597796127e8c8735ec7ee2598896191b5a143a78a3c99a6ab474e04cf064f` at that commit. A hash
quoted here is true of the commit it names and of no other, and this paragraph has now gone stale
that way twice: the digest read `0x4d91b88c1f71ca44d584b8ae34d865bbc6c69d1b99eb89993497b7049e335df2`
before 2026-09-12, and the three hashes measured on 2026-09-12
(`0xc2a69df82d6752fb9a784997d888448ecba1698c652bb016ce11b2c83cfb7de1`,
`0x3f9a2b1592acbd3c056e88fd94ae712cb5af632dea9dac1789e79dc97c02465e` and
`0xff2bc27f977efdde5278aefeda1758958b3d8e1790999470bbccce8a53578131`) were quoted here as
current until 2026-09-17 although the 2026-09-14 sync had already moved all three, while both byte
counts stayed exactly right, which is the tell worth keeping. Solc hashes the whole metadata, and
the metadata names every source in the contract's own compilation closure, which here is this
contract and `Config.sol`; the only change to that closure since 2026-09-12 is the one constant the
2026-09-14 sync added to `Config.sol`, which touched no line of this contract and cost it no bytes,
and that alone moved all three hashes. A byte count that has not moved is therefore no evidence
that a hash has not moved with it. Re-measure all five figures from the build artifact rather than
quoting them from here.

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
  fingerprint and the L-02 fix re-keyed two, none of which changed the count). Slither now runs in the development tree's CI on every
  contracts change, and a committed baseline of those 45 fails the build on any finding that appears
  or disappears. This repository does not run Slither itself.
- The external audit completed on 2026-09-22, but it does not lift the third-party capital gate on
  its own: that gate also needs the report's recommendations met, whatever the internal review
  count or CI status.

## What this source contains

This repository is a curated publication of the protocol's contracts, current as of 2026-09-15.

It contains the round-22 remediation in full - F4 (`setYieldRecipient` redirecting a full epoch's gross yield, closed by an
`owedToRecipient` balance drained by a permissionless `flushYieldTo`), F5 (a blacklisted liquidity
source freezing `pendingPrincipal` and the escape from it together, closed by `owedToSource` plus a
permissionless `flushPrincipalTo`), F8 (`workoutSettleAfterClose` resolving its payee from state
`closeWorkout` can empty in the same block, closed by recording a `bearer` at every close) and F9
(`lossBearerOf` recorded at write-down time) - and the round-23 remediation, including the
entry-side EIP-5143 overloads. Since 2026-09-12 it also carries the answers to the external
reviewers' preliminary issues: F9's record is completed by per-workout records keyed by auction and
id (`recoveryBearerOf`, `recoveryFunderOf`), and the recovery leg is deliverable from a former
auction (`wasLiquidationAuction`) and to a former manager (`wasCreditManager`). Since 2026-09-14 it
also carries the stream ceiling (`MAX_YIELD_STREAM_DURATION`, M-04), the bool-gated `_settle` (L-02)
and the per-controller request-draw memory (`_requestDraws`, H-03). Since 2026-09-15 it also carries
the cash floor a queued lender is owed (`WithdrawalRequest.floor`, `_freshFloor`, `_floorTotal`,
H-03).

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

These are additional to the pool's activation gates and the external-audit gate.

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

None of these is an activation blocker (the former three-item pool list is two closed and one
residual, in the `LenderPool` findings section above), but they remain open, partly closed or
accepted for the present pre-launch state.

### Pool, stream and liquidation

| Finding | Current state |
|---|---|
| Round 21 borrower stream cadence | Bond movement and zero-claim epochs can bypass the intended epoch gap and repeatedly re-rate borrower yield; the measured trace still had 35% unreleased after five days |
| Round 22 F16 | Public callers can pin the lot or cap the price, but cannot bind both in one call; price monotonicity across a re-strike is not restored and the widened fuzz test is still owed |
| Round 22 F17 | Closed on the half it was filed for; the other half is F12's. `LenderPool.claim` was the one member of the pool's claim class with no delegated `*For` twin, so a claim owed to a receiver that never called could be collected by nobody on its behalf. `claimFor(address)` collects it to the recorded receiver and the caller never chooses a different destination. What remains is the receiver half F12 above accepts: a claim recorded for a receiver the asset refuses to pay is still uncollectable through either door. Until 2026-09-17 this row read "remains the unswept member of the delegated `*For` claim class", a term defined nowhere in this repository |
| Round 22 F18 | **Closed in this source since 2026-09-12.** The insurance booking at a clean workout close is bounded to what the lot could actually reach, rather than to what it generated, and the pre-close ordering hazard is closed by the open-workout reserve: a stranger sweeping mid-workout is refused `NothingUnreserved` for any open lot's accrual, so the close sees what the lot earned. `test_R23_04_theResidual_aSweptPotIsAllocatedToWhicheverClosesFirst` now asserts both closes are paid, where at b66023d it asserted the second booked nothing. At b66023d the hazard was open, and the external reviewers' M-01 to M-03 reproduce it there |
| Round 22 F19 | `claimSurplusFor` can front-run the auction's own sweep into a revert |
| Round 22 F23 | `_settle` can advance a borrower's yield index past a payout that floors to zero; the proposed one-line fix was measured inert, and the external reviewers' L-02 restatement of it was re-measured on 2026-09-11 at this source: skipping the index stamp on a zero-floored payout mints 336 wei of unbacked credit on a 1.000000 pot (1,000,335 credited plus 1 undistributed against 1,000,000 streamed), because a stale index is revalued at a larger bond count after a top-up, against 925,925 wei on the original measurement; the shipped code destroys 2 wei in the same trace. Held as accepted Low through the 2026-09-12 sync, pinned by `test_L02_aZeroFlooredSettleBeforeATopUpCreditsNoMoreThanWasStreamed`; **fixed in this source since 2026-09-14** with the reviewers' second shape, a `bondCountMoving` flag on `_settle` under which a path that moves no bond count advances the index only over what it paid, at -57 runtime bytes, with the count-changing stamp and its one-wei-per-change residual disclosed in the #54 row above |
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
