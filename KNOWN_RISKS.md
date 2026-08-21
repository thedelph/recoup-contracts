# Known risks and activation gates

This is the launch-critical and material current security posture for the public contracts at
protocol code baseline `95e2c76` (2026-08-21). It is organised by present effect, not by discovery
date. Historical internal review notes are in [`AUDITS.md`](AUDITS.md); the code-level integration
tour is in [`REVIEW.md`](REVIEW.md).

Internal adversarial review, unit tests, invariant campaigns and mainnet fork tests are evidence, but
they are not an external audit.

## Gate definitions

- An **activation blocker** prevents wiring or funding `LenderPool`, including with the author's
  capital.
- A **third-party capital gate** is additional. Even after the activation blockers close, no public,
  DexFi or Bond Fund capital is accepted before an external audit.
- A **residual risk** is a known limitation that must stay disclosed and be reconsidered at go-live,
  even when it is not one of the five current activation blockers.

Closing the five pool blockers is necessary but not sufficient for mainnet. The governance, wiring,
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
| Current-source parity | The 2026-08-21 comparison of this public tree passed the strict length-and-metadata gate for 3 of 13 checked deployments: the three mocks |
| External audit | Not completed |
| Third-party funds | Not accepted |

The mock assets have no real value, and their mint and test-control functions are permissionless.
Explorer verification confirms the source attached to the deployment-era bytecode; it does not mean
the deployed set matches today's source. Eight protocol contracts had the same deployed byte length
but different metadata; `LenderPool` and `ReferralRegistry` also differed in size. Metadata includes
source hashes, so equal length with different metadata is not by itself proof of an executable logic
change, but it does mean this public tree is not the recorded deployment snapshot. The deployment
record is [`deployments/base-sepolia.json`](deployments/base-sepolia.json).

## Current `LenderPool` activation blockers

### Round 22 F3: principal-cap accounting is only partly remediated

Loss-aware principal units removed the original nonlinear rotating-lender cap-pinning trace, and
queue requests now preserve their exact principal units. The remaining model still compresses
transferable, differently priced share lots into scalar units.

Known residual paths are:

- Fungible transfers and merge/split operations average lots that entered at different prices.
- Even with no realised loss, splitting off a dust share can make its redemption round to zero assets
  while reducing `netDeposits` by one asset-wei. Repetition is linear and gas-bound, but it still
  erodes the cap.
- The post-loss path retains a separate double-ceiling boundary residual.
- Repeated near-total loss and refill cycles can grow the principal-unit quotient until issuance
  exhausts its integer range.

Closing this requires an explicit product/accounting choice: exact transferable lot provenance,
restrictions on share composition, or a bounded and proven rescaling policy.

### Round 22 F11: recovery cash inherits the epoch clock

`recoverLoss` and the surplus branch of `repayPrincipal` rate non-epoch cash using time since the last
yield epoch, even though that cash did not accrue over that interval. The same 400 USDC recovery was
measured streaming over five days after a recent epoch and 180 days after a long drought. A lender
leaving after day five forfeited 388.888889 USDC in the long-drought case.

Recovery timing needs its own clock or an explicit delivery rule.

### Round 22 F6a: stream re-rating can extend the tail

When `_rateStream` receives another delivery during a live stream, it floors the new duration at the
old stream's remaining time. Repeated deliveries can therefore keep postponing the end of the tail.
This composes with F10 entry pricing because a later entrant's prepaid tail remains locked for as long
as the stream remains live.

The duration and overlap policy must be bounded before activation.

F11 and F6a must be validated together. A narrow recovery-clock fix can be masked by F6a's
remaining-duration floor and appear to change nothing while a live tail dominates.

### Round 22 F12: queue service can create an uncollectable claim

Any caller can service a queued withdrawal. Service burns the lender's shares and records USDC in
`claimable[receiver]`. If that receiver cannot call the pool, or the asset refuses to transfer to it,
the lender cannot recover the burned shares or redirect the claim.

A delegated claim only solves the first case. The design must also handle an asset-level rejection or
avoid irreversible service before collectability is known.

### Round 21 F7: impaired queues can over-reserve liquidity

The pool reserves queued shares at an un-impaired value while separately refusing to service the
queue during impairment. In the measured trace, a request representing 15.8% of the book reduced an
unqueued lender's `maxWithdraw` from 3,567.125000 USDC to zero while the request's economic
entitlement was 563.230263 USDC. `available()` can reach zero and halt borrowing.

The request is free, revocable and continues earning. Four partial mitigations were measured and
rejected. The lock also measured 3.00x with both `totalImpairment` and `exitReserve()` at zero, so
impairment-aware reservation alone is not a solution. Impaired pricing and service-while-marked also
moved in opposite directions in the measured fixture. The design remains unresolved.

A related accepted exposure is the permissionless workout transition. Once an auction expires, any
caller can move it into workout and hold the full-debt impairment, and therefore the queue, for up to
14 days. This is part of the same queue design problem rather than a sixth activation blocker.

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

### `ReferralRegistry.registerFor` can assign a code to an unusable payee

The current source prevents assignment to the reserved `NON_BINDABLE` sentinel, but permissionless
`registerFor` can still assign an unused code to another unspendable address. A referee can then burn
their one-time binding on a payee that can never claim. Referral-program use remains blocked until
this is removed, consent-gated or explicitly accepted with an operational policy.

While that design remains open, the standalone deployment script rejects every run whose chain ID
is not 31337 before the legacy confirmation check. This executable guard prevents broadcasting the
current source through that script; it does not resolve `registerFor`.

### The deployed Sepolia `ReferralRegistry` is stale

The source includes the guard that prevents a stranger from assigning the `NON_BINDABLE` tombstone
to somebody else's referral code. The carried-over Sepolia instance predates that fix, so its
bytecode does not enforce the guard. It holds no value, no protocol contract reads it and the
referral programme has not launched, but the address must not be used as proof of current behaviour.

Measured on 2026-08-20, the deployed runtime was 1,489 bytes versus 1,554 bytes for the current
source. A stranger's `registerFor(code, NON_BINDABLE)` call succeeded on the deployed instance while
the current source reverted `CodeNotBindable`. Replacement is not complete; do not publish or
reserve codes against the stale instance.

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

These do not add to the five-item pool activation list, but they remain open, partly closed or
accepted for the present pre-launch state.

### Pool, stream and liquidation

| Finding | Current state |
|---|---|
| Round 21 borrower stream cadence | Bond movement and zero-claim epochs can bypass the intended epoch gap and repeatedly re-rate borrower yield; the measured trace still had 35% unreleased after five days |
| Round 22 F16 | Public callers can pin the lot or cap the price, but cannot bind both in one call; price monotonicity across a re-strike is not restored and the widened fuzz test is still owed |
| Round 22 F17 | `LenderPool.claim` remains the unswept member of the delegated `*For` claim class |
| Round 22 F18 | The public source lacks the later partial workout-yield fix: a clean close still sweeps the borrower's collateral yield to insurance, and the pre-close ordering hazard also remains |
| Round 22 F19 | `claimSurplusFor` can front-run the auction's own sweep into a revert |
| Round 22 F23 | `_settle` can advance a borrower's yield index past a payout that floors to zero; the proposed one-line fix was measured inert |
| Long-gap lender yield | A long delivery gap can defer several epochs and then stream about 3.10 epochs over five days rather than their original accrual windows |
| Impairment refresh | A conservative stale-high mark persists until a permissionless refresh; `refreshImpairments` can report apparent progress when `impair` no-ops |
| Queue progress event | A cancelled queue husk can suppress `QueueHeldByReserve` for one call that still makes progress |

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
| F3 original nonlinear ratchet | Removed, but F3 remains an activation blocker for the residual paths above |
| F10 post-delivery capture | Closed for capital entering after a live pot is delivered, with the narrower semantics above |

## Verification sources

- [`README.md`](README.md) for the repository overview and commands
- [`REVIEW.md`](REVIEW.md) for custody, whitelist and fork-test claims
- [`AUDITS.md`](AUDITS.md) for the historical internal review record
- [`test/`](test/) for deterministic regressions and invariant campaigns
- [`deployments/base-sepolia.json`](deployments/base-sepolia.json) for current testnet addresses and
  recorded state
