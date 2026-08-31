# Known risks and activation gates

This is the launch-critical and material current security posture for the public contracts. The
core protocol executable logic is this tree's, synced from the working tree on 2026-08-31. That
sync replaced the lender pool, the credit manager and the collateral vault, so any analysis dated
against the previous baseline `95e2c76` (2026-08-21) describes a pool this source no longer
contains. This record is organised by present effect, not by discovery date. Historical internal review notes are
in [`AUDITS.md`](AUDITS.md); the code-level integration tour is in [`REVIEW.md`](REVIEW.md).

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
| `LenderPool` | Deployed on Sepolia, empty and not wired as `CreditManager`'s liquidity source |
| Current testnet liquidity | Supplied by `TreasuryLiquiditySource`, not `LenderPool` |
| Current-source parity | **None, deliberately.** This source is now synced to the working tree, which the Sepolia set predates. The last comparison, on 2026-08-21 against an older public tree, passed the strict length-and-metadata gate for 3 of 13 checked deployments (the three mocks); that figure describes a tree this one has replaced and is not re-run here. Treat the deployment as historic and verify against the explorer, not against this source |
| External audit | Not completed |
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

This repository is a curated publication of the protocol's contracts. Previous revisions lagged the
working tree and said so here. **That lag is closed.** The four round-22 fixes this section used to
list as absent - F4 (`setYieldRecipient` redirecting a full epoch's gross yield, closed by an
`owedToRecipient` balance drained by a permissionless `flushYieldTo`), F5 (a blacklisted liquidity
source freezing `pendingPrincipal` and the escape from it together, closed by `owedToSource` plus a
permissionless `flushPrincipalTo`), F8 (`workoutSettleAfterClose` resolving its payee from state
`closeWorkout` can empty in the same block, closed by recording a `bearer` at every close) and F9
(`lossBearerOf` recorded at write-down time) - are all present. So is the round-23 remediation in
full, including the entry-side EIP-5143 overloads whose absence was the clearest way to see the old
gap from inside the source.

**One property the lag preserved, and this sync ends it.** The published `src/CreditManager.sol`
used to compile to 23,833 bytes of runtime code, byte-for-byte what is deployed at the Base Sepolia
address in `deployments/base-sepolia.json`, so what you read here was what was running on that
testnet. It no longer is. This source compiles to a different `CreditManager`, and the Sepolia
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
| Round 22 F18 | **Partly closed, and this sync ships the closed half.** The insurance booking at a clean workout close is now bounded to what the lot could actually reach, rather than to what it generated. The **pre-close ordering hazard remains open**: a stranger sweeping mid-workout still changes what the close sees |
| Round 22 F19 | `claimSurplusFor` can front-run the auction's own sweep into a revert |
| Round 22 F23 | `_settle` can advance a borrower's yield index past a payout that floors to zero; the proposed one-line fix was measured inert |
| Long-gap lender yield | A long delivery gap can defer several epochs and then stream about 3.10 epochs over five days rather than their original accrual windows |
| Impairment refresh | A conservative stale-high mark persists until a permissionless refresh; `refreshImpairments` can report apparent progress when `impair` no-ops |

### Oracle, wiring and migration

| Finding | Current state |
|---|---|
| NAV freshness | Alternating a posted NAV by one wei can keep an economically frozen price non-stale without invoking the second key |
| Pending NAV anchor | A pending value can remain confirmable after the accepted anchor moves; exact-value confirmation and expiry bound the exposure but do not remove it |
| Stale view | `collateralValue()` is an ungated stale-NAV view; callers must not treat it as a borrow-authorisation result |
| Pool manager binding | `LenderPool.setCreditManager` has no vault or code/interface binding check and can install an EOA as both authoriser and principal payee |
| Recovery-era binding | Written-down-loss recovery follows the current pool/source rather than the loss-time bearer, and post-close workout settlement follows the live auction manager; a migration can misroute recovery to the incoming era, make it operator-withdrawable or leave it unreachable |
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
| F3 principal-cap accounting | Closed. The principal-unit mechanism its residuals were properties of is not in this source; cap usage follows the recognised entry book |
| F10 post-delivery capture | Closed for capital entering after a live pot is delivered, with the narrower semantics above |

## Verification sources

- [`README.md`](README.md) for the repository overview and commands
- [`REVIEW.md`](REVIEW.md) for custody, whitelist and fork-test claims
- [`AUDITS.md`](AUDITS.md) for the historical internal review record
- [`test/`](test/) for deterministic regressions and invariant campaigns
- [`deployments/base-sepolia.json`](deployments/base-sepolia.json) for current testnet addresses and
  recorded state
