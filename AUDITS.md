# Audit log

Every finding listed here is **fixed and covered by a regression test**, unless it is explicitly
named as accepted or deferred. Current open risks are tracked separately in
[KNOWN_RISKS.md](KNOWN_RISKS.md).

This file is the historical record. Each round is an internal 12-agent adversarial review pass, and
rounds are appended newest first.

**This log currently stops at round nine; the protocol has completed thirty-nine rounds.** That
count is adversarial review passes as this file defines them, one per round. Remediation passes
are numbered on their own sequence and run higher; the two are different bases and are not
interchangeable. The code, tests and `KNOWN_RISKS.md` reflect the later work. The remaining
historical write-up is still to be added.

---

## Round nine - referral registry (August 2026)

Round nine covered the referral registry. It is the first round where the contract
logic came through untouched - every agent attacked the code-canonicalisation walk, the write-once
mappings and the attribution lookup, and one differential-fuzzed the canonicalisation 40,000 times
against an independent implementation with zero mismatches. **Every finding was in the deploy
script or in the comments describing the contract**, which is its own lesson: confident prose next
to correct code is still a defect when the prose is wrong. The worst was a claim that reserved
brand codes were seeded atomically - a broadcast emits one transaction per call, so what actually
existed was a live registry with an open, permissionless registration function followed by a race
for each name. Seeding moved into the constructor.

The findings worth knowing about:

- **Yield is streamed, not lumped.** Crediting an epoch's borrower share against an instantaneous
  bond count made it free money for anyone watching the mempool: deposit a large position in the
  harvest block, settle, claim, withdraw. It now pays out over the window it actually accrued
  across, so one block of holding earns one block of yield.
- **An epoch is sized from the harvester's own balance, not from what the claim call returns.** The
  farm is MasterChef-style, so a withdrawal, a seizure or a direct claim each settle the whole
  position and forward that USDC ahead of the epoch. Sized from the return value, those epochs
  reported zero and the money sat unreachable.
- **Guards that assumed their own escape hatch was reachable.** Three separate cases: a "flush
  before repointing" guard whose flush target reverts by design, a "sweep to the outgoing recipient
  before repointing away from it" path where that recipient is blocked (which is *why* you are
  repointing), and a confirmation clock that restarted whenever the pending price changed, which a
  live feed does on every post. The first locked a quarter of all yield permanently.
- **A detached CreditManager stayed live and drainable.** The swap guard checked only that debt was
  zero - the normal end state of a self-repaying loan - while the outgoing manager kept pricing
  positions off the vault's still-moving bond counts.

## Rounds five to eight - liquidation auction, and each other (July 2026)

They covered the liquidation auction and then, repeatedly, each
other. Four rounds running found regressions in the previous round's own fixes, which is why the
re-audit is now automatic rather than optional. Two results are worth stating plainly:

- **Round seven's critical was cleared by eight of twelve agents, and the majority was wrong.**
  They analysed a function where the argument genuinely holds and never looked at the one where it
  does not. A proof-of-concept settled it in ten minutes: 100 bonds confiscated against a recorded
  debt of zero, and a variant that returns an entire liquidation fill to the borrower. Agreement
  between agents is not evidence; a specific trace is.
- **Round six-b's fix made its own bug permanent.** A guard added to one side of a symmetric pair
  meant that once the two pointers diverged, the guard *refused to let them reconverge*.

## Rounds three and four - epoch harvester (July 2026)

They covered the epoch harvester and the yield-distribution mechanism
behind it. The fourth deliberately audited *the third round's own fixes*, and that turned out to
matter: **four of its twelve findings were regressions introduced by the third round**. Every one is
fixed with a regression test. The lesson is now a standing habit here - a fix round is new code, and
fixes that add a mechanism regress far more often than fixes that remove a constraint.

## Round two - the credit core (July 2026)

It covered all ten contracts and raised twelve
findings, all fixed with regression tests. The ones worth knowing about:

- The NAV oracle's deviation rate limit was defeated by integer truncation. Both sides of the budget
  comparison floored to whole basis points, so sub-1-bps steps cost nothing and compounded; it now
  compares by cross-multiplication with no division anywhere.
- The two-key confirmation path had two independent liveness defects - the delay restarted on every
  repost, and an in-budget post cleared the pending value. Either let one key defeat the pair.
- The Dutch auction floor was derived from a maximum NAV move the oracle did not actually enforce.
  The parameter test now derives that bound from the oracle's own formula instead of restating the
  assumption, so the two cannot silently diverge again.
- A single-unit withdrawal settled the whole staked position's farm rewards and forwarded them
  without reporting the amount, so the measured harvest could be driven to zero.
- `LiquidationAuction` could not receive ERC-1155 units at all - invisible while every seize test
  targeted an EOA, because an EOA destination skips the acceptance check. The auction was later
  redesigned to never escrow bonds, which makes the defect moot, but the blind spot it exposed
  was not: a test fixture that only ever used EOAs could not have found it.
- **Four later rounds went over the liquidation auction itself.** The sharpest was a pair of
  wiring pointers that could be pulled apart and then pinned apart, so a position's health was
  checked against one ledger and its debt settled against another - a lot seized against a
  recorded debt of zero, or an entire fill returned to the borrower. Both setters are guarded now.
  Two lessons generalised: when a fix adds a guard, look for the mirror case it did not cover
  (every finding in that round was one side of a symmetric pair), and check what each guard's
  escape hatch actually depends on.

## Round one - collateral layer (July 2026)

It covered the two contracts implemented at the time and raised eight findings, all
fixed - see the `Security hardening` commits for the per-finding diffs. What
they covered:

| Area | What changed |
|---|---|
| Yield routing | Harvested USDC could only ever land in the immutable, egress-less vault, where nothing could move it out again. It now routes to a settable `yieldRecipient`, and the reported figure counts real farm yield rather than the raw balance, so a stray USDC transfer cannot inflate it. |
| Mint accounting | Credit is pinned to the signed `amountNfts`, and the mint delta is measured, so over-credit, under-credit and donated bonds are all excluded. |
| Custody swaps | `setCustodyAdapter` now refuses a swap while the outgoing adapter holds a live position, and requires the incoming adapter to be bound to this vault. |
| Exits | The USDC sweep on `unstake` is best-effort, so a token pause or blacklist cannot brick a withdrawal. An owner-gated `emergencyUnstake` adds a farm escape hatch. |
| Yield pipeline | `claimYield` is callable by the vault or a settable harvester, so the immutable adapter can be pointed at the batch harvester later with no redeploy. |
| Oracle safety | `withdrawBonds` reverts on a stale NAV in the debt-bearing branch. |
| Auction floor | Raised so the floor always clears debt plus penalty at the first triggerable liquidation; the full relation is now asserted in `Config.t.sol`. |

Alongside those: constructor zero-address checks, `renounceOwnership` disabled on the
live-authority contracts, and a `pause`/`unpause` pair on `CreditManager`. The suite grew from 33
to 45 tests in the same pass. Remaining known items are tracked against the phase that resolves
them, and an external audit is still a hard gate before third-party funds.
