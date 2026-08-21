# Recoup contracts

Smart contracts for [Recoup](https://recoup.fi) - self-repaying loans on Base, collateralised by
DexFi Treasury Bonds. Deposit bonds (or ETH that becomes bonds), borrow USDC, and the weekly bond
yield pays the debt down automatically. Debt only ever decreases.

Status: **deployed to Base Sepolia** (redeployed 2026-08-19), nothing on mainnet. The collateral
layer, the credit core, the epoch harvester and the liquidation auction are implemented, and the
whole loan lifecycle - including a liquidation filling at 82% of NAV and an unfilled one falling
through to the workout path - is fork-tested against the live DexFi contracts. Lending reaches the
credit core through an interfaced seam, and the pool behind that seam is published here with its
open and partly remediated findings stated below rather than left to be found. No
third-party money is accepted before an external audit; the exact shape of that gate, and what it
deliberately does not cover, is spelled out further down.

**`LenderPool` is here, and its deployment blockers are stated below.** The real one - the
ERC-4626 vault, the withdrawal queue, the yield stream and the impairment pricing - is
`src/LenderPool.sol`. It was
withheld from this repository until 2026-08-19; the section under the architecture diagram says why
it is not any more. One of the open findings: a loss-making position carries no impairment
until somebody calls `liquidate`, so in the gap between a loan going bad and that call, the pool
prices every exit at the full pre-loss price and a lender who leaves first is paid out of the
lenders who stay.

That gap used to be unbounded, because the protocol paid the caller nothing when the sale fell short
of the debt and nobody was obliged to volunteer. It is not unbounded now. `liquidate` carries a
bounty the borrower prepaid at `borrow` - `Config.LIQUIDATION_CALL_BOUNTY`, 25 USDC, charged on any
position above `MIN_BOUNTIED_DEBT` - and a short fill is the one outcome it exists to pay for. Audit
round eighteen then found the first version of that bounty extractable: paying at open let a stranger
open an auction, cure the position for a dollar and cancel it in the same transaction, keeping the
deposit and leaving the position disarmed for whoever liquidated it for real afterwards. Since
2026-08-15 the escrow parks against the auction id and is credited only by the transitions that
actually resolved the position.

**Audit round nineteen then found that fix extractable too, and the fix for it was structural.**
Superseding a lapsed auction used to settle it and mint a new id, which forced the parked bounty to
be unwound and re-parked - and the manager re-reads the escrow immediately afterwards, so it landed
on whoever made that call. A borrower could wait one second past a keeper's lapse, re-strike, and
take the payment the keeper had earned; their defence was one second wide and nobody is paid to use
it. Gating the caller was measured to move the number by zero, because a second wallet is paid
identically. Since 2026-08-16 a lapsed auction is **re-struck in place, keeping its id** - the shape
Maker's `Clipper.redo` uses - so there is no unwind, nothing to re-park, and no claimant to
overwrite. The same change bounds a second finding: re-strikes are measured against a first-open
timestamp that never moves, so past `Config.AUCTION_RESET_WINDOW` the only move left is the
permissionless `expireToWorkout`, which arms the forced close. That constant was first written at 14
days and the proof-of-concept still passed against it, which is why it is 48 hours: a bound longer
than the attack is not a bound.

**The finding is narrowed, not closed.** The window is bounded by transaction ordering now rather
than by whether a caller ever appears, and that bound is not zero. `postNav` is public, so the price
post that makes a position liquidatable can be back-run, and a lender exiting can out-bid the
liquidator for position in the same block. No calibration of the bounty closes an ordering race, and
I have no clean mitigation for it in this architecture: any delay between a post and liquidatability
contradicts the rule that keeps liquidation priced on the last known NAV through a keeper outage.

**And rounds twenty and twenty-one found another, larger blocker.** A lender who asks to withdraw
parks a request, and the pool holds back the un-impaired value of those queued shares from everybody
else. Separately, and correctly, it refuses
to service the queue at all while a position is marked down. Each rule is defensible on its own.
Together they mean a parker reserves a claim they are forbidden to be paid, at a price they would
never be paid at, and nothing permissionless drains it. Measured: a parker holding 15.8% of the book
makes one free request and an unqueued lender's `maxWithdraw` goes from 3,567.125000 to zero for the
whole workout, against a real entitlement of 563.230263 - a 6.66x over-reservation. `available()`
reaches zero, which halts borrowing protocol-wide. The request is free, revocable at will, and the
parked shares keep earning, so the cost of holding it is negative.

Four candidate fixes were built and each one failed, which is why this is deferred to its own piece
of work rather than patched: a clamp to what is actually available is inert against the holdback
already flooring at zero; reserving only the queue's pro-rata share re-prices every lender who
stayed, which is a branch this codebase already built, broke and deleted; charging for a request
makes the lock cost something without making it smaller; and expiring a parked request turns an
exclusive lock into a periodic one with a cheaper renewal for the parker than anyone else gets. What
is left is one change - price the queue against the impairment and serve it while marked - and it
needed an anchor on the NAV oracle that only landed in round twenty-one.

**Publishing a pool with either of those open looked worse than publishing none, and that stopped
being the trade on 2026-08-19.** The section under the architecture diagram sets out what changed.
The `ILenderPool` interface here is the real one and `src/LenderPool.sol` is what implements it.

Testnet addresses are in [`deployments/base-sepolia.json`](deployments/base-sepolia.json), all
verified on Basescan. The testnet deployment runs against a **mock** DexFi stack, because the real
bond and farm contracts exist only on Base mainnet; the mocks mirror their verified ABIs including
the transfer whitelist. The live DexFi contracts are exercised by the mainnet fork tests below,
which are the real integration proof.

**The risk parameters on chain now match the source, and did not until 2026-08-19.** The four
values in [`src/Config.sol`](src/Config.sol) changed on 2026-08-07 to the capped-beta figures
agreed with DexFi - max LTV 3500 -> 2500 bps, liquidation threshold 5800 -> 5000, and both borrow
caps down. They were `internal constant`, inlined at compile time, and the Sepolia contracts then
deployed predated that change, so for twelve days the deployed bytecode enforced the old values
while the source declared the new ones. That window is recorded rather than quietly removed:
anyone who checked those addresses during it saw the old numbers, and was seeing them correctly.

The redeploy on 2026-08-19 closed it. The four parameters now live in bounded, timelocked storage
in [`src/RiskParams.sol`](src/RiskParams.sol) rather than as compile-time constants, so the next
change to them is a transaction rather than a redeploy. Read them back rather than taking this on
trust: `RiskParams` on Base Sepolia returns **2500 / 5000 / 25000000000 / 5000000000**.

**And the parameters bind rather than merely read back**, which is worth checking separately,
because a storage read proves less than it looks like it does. `healthFactor` on the seeded position
is 2.729, which is collateral x **0.50** / debt: the 5000 bps threshold is live, where the old 5800
would give 3.165. Borrowing past the wallet cap reverts `PerAccountCapExceeded` with 5,100,000,000
requested against a 5,000,000,000 cap.

The deployment is complete as of 2026-08-19. The oracle is bootstrapped at $21.8244 and there is a
seeded position of 1000 bonds against $4,000 of debt at 1832 bps. Note that `borrow` disburses less
than it books, $3,975 against $4,000 of debt, because 25 USDC tops up a prepaid liquidation bounty
escrow that `bountyEscrowOf` then reports.

**Reviewing this repo?** [REVIEW.md](REVIEW.md) is a reading guide: where bonds can and cannot go,
who controls what, what revoking the whitelist would do, and which tests to run first.

`ReferralRegistry` is a standalone addition with zero coupling to the protocol above: two
write-once mappings recording who owns a referral code and which code an account bound to, with no
owner, no pause and no way to move either fact once written. It holds no value and no protocol
contract reads it. It is deliberately absent from the main deploy script, because the supported
fix for a core defect before launch is redeploying the set, and a registry inside that set would
take a new address each time and orphan every existing binding.

**That argument is about whether the address can stay put across a redeploy. It says nothing about
whether the bytecode at it is current, and on Base Sepolia it is not.** The source here carries
audit round twelve's fix: `registerFor` refuses to write the `NON_BINDABLE` tombstone on somebody
else's behalf (`src/ReferralRegistry.sol:154`), because without that check one call bricks any
advertised-but-unclaimed code forever - write-once mappings, no owner, no transfer, no recovery at
any price. The contract at `0x30B9B1D7A40aa7D14613cb1742EFaaB155dC84a0` predates the fix and was
carried across the 2026-08-19 redeploy rather than rebuilt, so the guard is not in its bytecode.
Measured 2026-08-20: 1,489 bytes of deployed runtime code against 1,554 that `forge build --sizes`
reports for this source, and `registerFor(code, NON_BINDABLE)` from a stranger succeeds against that
address, for 51,706 gas, where `test_registerFor_cannotMintTheReservedSentinel` pins this source
reverting `CodeNotBindable`. Two controls on the same address still revert - `ZeroAddress()` for a
zero owner, and `CodeTaken` naming the incumbent for a reserved code - so the deployed contract does
run its other guards, and this is one missing check rather than a different contract.

The scope, stated rather than left to be inferred: Base Sepolia is a testnet, the registry holds no
value, no protocol contract reads it, the referral programme has not launched, and the codes on that
chain are re-registrable after a redeploy. Nothing is at risk. The redeploy is authorised and
pending, and this paragraph is what should be checked against the chain rather than trusted.

`ProtocolFeeSplitter` is the other standalone one, and it is also not in the deploy script yet
because it needs a second address that does not exist. It forwards Recoup's protocol fee to two
fixed destinations in a fixed ratio, and it exists so that a revenue split with a partner is a
contract rather than a monthly promise: no owner, no setter, no pause, no rescue, both addresses and
both shares fixed at construction. It needs no change to anything else, because
`EpochHarvester.flushProtocolFee` pays out with a plain `safeTransfer` and does not care that the
destination is a contract - a claim worth checking rather than believing, so
`EpochHarvester.t.sol` runs a real epoch through it. Note the *lender* leg of the same split is
delivered by approve-and-call, where a plain recipient would receive nothing; the two legs differ
and the difference is invisible at the call site.

## Architecture

```
                    depositBonds / depositETH / withdrawBonds
User ──────────────────────────────┐
                                   ▼
                            CollateralVault          accounting + LTV rules (implemented)
                                   │ onlyVault
                                   ▼
                           DirectCallAdapter         custody backend (implemented)
                              │          │
                    stake/unstake      claim = withdraw(0)
                              ▼          ▼
                        DexFi Farm ◄── DexFi Bond (ERC-1155, id 0, transfer whitelist)

CreditManager + NAVOracle: implemented (borrow / repay / yield application; keeper-posted NAV
behind a deviation budget and a second key). Liquidity reaches CreditManager through the
ILiquiditySource seam - a treasury float now, the LenderPool later, same interface.

EpochHarvester: implemented. Claims farm USDC, splits it four ways, and writes borrower debt down.
It settles EVERY position in a single storage write, because CreditManager distributes through a
yield-per-bond accumulator rather than iterating - so the cost of an epoch does not scale with the
number of borrowers. The share is streamed over the window it accrued across, not applied as a lump.

LiquidationAuction: implemented. A Dutch auction over the whole position, decaying from NAV to a
6800 bps floor over six hours. Bonds are never escrowed - a fill sends them from custody straight
to the winner, and an unfilled auction moves the *claim* to a workout queue while the units stay
staked and earning. Three exits, and the guards exist to prove no state closes all of them.

LenderPool: implemented. ERC-4626 over USDC, lending only to CreditManager, a FIFO withdrawal
queue that escrows shares rather than burning them, and exits priced on a reserve so a leaver
cannot outrun a loss they already carry. **Its open and partly remediated findings are named
below.** Check the findings below and the commit history rather than relying on a fixed count here.
All parameters live in src/Config.sol - no magic numbers anywhere else.
```

**`LenderPool` was withheld from this repo until 2026-08-19, and here is why it is not any more.**
It was held back because findings are open against it and publishing the mechanism without the fix
seemed the wrong trade while nothing carrying the code was deployed. The 2026-08-19 Base Sepolia
redeploy put it on chain and Basescan verification published the full source, so withholding it here
stopped protecting anything and started making this README wrong. It is published, with the current
deployment blockers stated rather than left to be discovered:

- **A loss-making position has no mark until somebody volunteers to liquidate it** (round 17). The
  window is narrowed to one transaction-ordering slot and the residual is irreducible without an
  oracle for expected recovery.
- **A parked withdrawal request reserves, at an un-impaired price, a claim it is forbidden to be
  paid** (round 21). Measured at 6.66x over-reservation on a request that is free and revocable, and
  `available()` can reach zero, which halts borrowing protocol-wide. Four candidate fixes were built
  and each was refuted; what is left is impaired pricing plus serve-while-marked, which are one
  change.
- **Principal-cap accounting is partly remediated, not closed** (round 22, F3). Loss-aware principal
  units remove the original 114-cycle, one-asset-wei-per-cycle rotating-lender ratchet, and exact
  request units preserve queue provenance. Unrestricted ERC-20 merges still average differently
  priced share lots. Even without a loss, a dust-share split can make a redemption round to zero
  assets, eroding the cap linearly by one asset-wei per completed cycle. Separately, the post-loss
  path retains its own double-ceiling residual at an integer boundary, and repeated near-total loss
  and refill cycles can eventually exhaust the quotient's integer range. It remains a deployment
  blocker.
- **Loss recovery uses a stream that cannot preserve who bore the loss** (round 22, F10).
  `recoverLoss` feeds recovered value into the general yield stream, whose unreleased pot is excluded
  from the price paid by new deposits. Measured, a lender arriving one block into a 628.750000 USDC
  recovery captured 128.994204 USDC, or 20.5%, despite bearing none of the loss. That entry-pricing
  rule applies to every live stream, so changing only `recoverLoss`'s rating parameters cannot fix
  recovery ownership. It remains a deployment blocker.
- **A non-epoch recovery inherits the epoch clock** (round 22, F11). `recoverLoss` and the surplus
  branch of `repayPrincipal` use time since the last yield epoch to size their stream even though
  neither cash flow accrued over that interval. The same 400 USDC recovery therefore streams over
  five days after a recent epoch and 180 days after a long drought; a lender exiting after day five
  forfeited 388.888889 USDC in the measured long-drought case. It remains a deployment blocker.
- **Permissionless queue service can crystallise shares into cash the receiver cannot collect**
  (round 22, F12). Any caller can burn a queued lender's shares and park the proceeds in
  `claimable[receiver]`. If that receiver cannot call the pool or the USDC transfer to it is blocked,
  the lender has no way to recover the shares or redirect the claim after service. Delegated claiming
  would address only the first case, not an asset-level transfer rejection. It remains a deployment
  blocker.

**No lender capital is exposed and none can be.** The pool is deployed but not wired as
`CreditManager`'s liquidity source and holds nothing, so it cannot lend and therefore cannot take a
loss. Its asset on that chain is a mock USDC anyone can mint. The public lender launch is gated on
an external audit, which has not happened.

Design notes that matter for review:

- **The custody adapter is the only address that needs DexFi whitelisting.** It is ~140 lines of
  code, immutable, holds no USDC at rest (claims sweep onward to the yield recipient in the same call),
  and only the vault can call it. The `ICustodyAdapter` interface keeps custody swappable (direct-call vs a
  Safe-based backend) without touching vault accounting.
- The DexFi-facing interfaces (`IDexFiBond`, `IDexFiFarm`) were built from the verified sources of
  the live contracts, and the mocks mirror their observable behaviour including the transfer
  whitelist gate and the auto-stake-on-mint path.
- Deposits are pausable; withdrawals and seizures are deliberately not.
- Prefer immutable contracts + parameterised config behind a timelock over proxies.

## Build and test

Requires [Foundry](https://getfoundry.sh).

```sh
forge install   # restores pinned deps (forge-std v1.16.2, openzeppelin v5.6.1)
forge build
forge test      # unit + invariant tests vs real-ABI mocks. Allow ~6 minutes: the
                # invariant suites dominate, and a short timeout will kill the
                # run mid-flight rather than fail it
```

Measured on 2026-08-21 for this tree: **725 passed, 0 failed, 13 skipped across 30 suites**. The
skips are the mainnet fork tests below, which need `RUN_FORK_TESTS=true`. This is a dated baseline,
not a substitute for running the command: CI runs it on every push and pull request, and the green
tick on `main` is the standing claim.

### Mainnet fork tests

Ten integration tests run against the **live** DexFi contracts on Base (fork-at-latest, so any
full node works - no archive access needed). This is the part worth running yourself:

```sh
RUN_FORK_TESTS=true forge test --match-contract Fork -vv
# optionally: BASE_RPC_URL=<your rpc> (defaults to https://mainnet.base.org)
```

Custody, on real state:

1. the configured addresses are the live contracts and behave as documented;
2. deposits currently revert at the bond's transfer whitelist gate (today's mainnet reality);
3. a single `addWhitelist([adapter])` from the bond owner unlocks the entire lifecycle:
   deposit → stake → claim real streamed USDC → unstake → withdraw;
4. **a fresh stake can be unwound in the same block it was created** - the farm imposes no lock,
   cooldown, epoch boundary or withdrawal charge on the bond units themselves. Worth stating
   separately because test 3 does *not* establish it: that one warps three days forward before
   withdrawing, in order to accrue rewards worth asserting on, and three days of slack is exactly
   what would hide a cooldown.

The loan itself, also on real state:

5. **the whole self-repaying loan end to end** - deposit real bonds, borrow at exactly max LTV,
   let a week of real USDC stream out of the live farm, apply that yield to write the debt down,
   repay the remainder, withdraw the collateral, and return the principal to the lender float.
   It also asserts, on real state, that **nothing is earned in the harvest block** - which is the
   property that makes depositing just before a harvest pointless;
6. borrowing refuses while the price feed is stale;
7. a large NAV move parks for a second key instead of being waved through by the price poster.

Test 3 is the one that shows exactly what a single `addWhitelist` call buys. Test 5 is the one
that shows the product actually works.

## Security posture (pre-external-audit)

**Nothing is deployed to mainnet.** The current deployment is Base Sepolia only, against a mock
DexFi stack, from the `DeployTestnet` target in `script/Deploy.s.sol`. Addresses are in
[`deployments/base-sepolia.json`](deployments/base-sepolia.json). It holds no third-party funds and
no real value: the USDC, bonds and farm on that chain are all mocks deployed by the same script.

**An external audit is a hard gate before any third-party funds.** It is deliberately not a gate on
the author's capital: the plan is to run a mainnet beta funded solely by the author, then
commission an external audit before anyone else's money is accepted. That ordering is a judgement,
not an oversight, and it is stated here rather than left to be discovered. Everything in "what is
knowingly not mitigated" below is published on the same principle.

### What this means if you are DexFi

The one thing Recoup needs from you is `addWhitelist` on the custody adapter. What that buys and
what it does not is a tested quantity rather than an assurance:

- **The adapter is the only Recoup address that calls your contracts.** Fork test 3 runs the entire
  lifecycle with only that single address whitelisted, against live Base state, so you can see
  exactly which of your functions get called and which never do.
- **Revoking the whitelist is modelled, not assumed** (`test/WhitelistRevocation.t.sol`). Revocation
  does not merely stop new deposits: it strands live collateral. The farm can still return bonds to
  the adapter, but the adapter cannot pass them to a non-whitelisted depositor, and the emergency
  hatch hits the same gate unless its destination is whitelisted. This is recorded here because the
  mitigation is an integration agreement, not code. It is the reason Recoup asks for either a
  permanently whitelisted unwind address or notice before revocation.
- **The auction never escrows bonds.** A lot moves adapter-to-winner in one hop, so no second
  address needs whitelisting for liquidations to work.
- **DexFi is treated as mutable.** Both your contracts are owned by a single EOA and the farm is
  upgradeable, so Recoup is built against that rather than around it: the custody backend sits
  behind a swappable interface, and there are hard borrow caps. How large those caps can
  responsibly go depends on your admin-key plans, which is one of the open questions.

### How the contracts are reviewed

Every phase gets a 12-agent Solidity audit pass before it merges, and **every fix round is
re-audited**, because the rate at which fix rounds produce their own defects has stayed stubbornly
high: **twenty-two rounds so far, and twelve of rounds nine to twenty-one found defects in the
round immediately before them.**
Findings are fixed with regression tests. The round-by-round record in [AUDITS.md](AUDITS.md) is
written up as far as round nine. The rounds after it are not written up there yet: their fixes are
in the code published here, and the reason for the gap used to be that most of those rounds are
about the lender pool, which was not. That reason went away on 2026-08-19 and the write-up is now
simply behind.

Four habits came out of that and now apply by default:

- A fix round is new code. Fixes that add a mechanism regress far more often than fixes that remove
  a constraint.
- Agreement between reviewers is not evidence. One round's critical was cleared by eight of twelve
  agents who had all analysed the wrong function; a proof-of-concept settled it in ten minutes.
- When a fix adds a guard, look for the mirror case it did not cover, and check what the guard's
  escape hatch actually depends on.
- Before auditing a fix for bugs, re-run the original attack against it. One recent mechanism was
  audited twice for correctness and deleted on the third pass, when someone finally asked the prior
  question and found it never closed the hole it was written for.

Alongside the audits: stateful invariant fuzzing over six suites (58 invariants), and the mainnet
fork tests above, which are the real integration proof.

An invariant suite can be vacuously green - handler actions are wrapped so an expected revert does
not fail the fixture, which means a suite that never reaches the interesting state still reports
everything passing. **Every suite** now carries a deterministic reachability test that pins the
state was actually reached. The last two were added on 2026-08-03, and one of them found that a
suite really had been vacuous: seven invariants had been running against a protocol in which no
borrow could succeed. [REVIEW.md](REVIEW.md) has the detail.

**A reachability test is a floor, not a guarantee, and round nineteen's first job was finding out
where the floor is.** The auction suite passed its reachability test and still fuzzed nothing: the
handler exposed a wiring setter, every external non-view function on a handler is a fuzz action
whether it was meant to be one or not, and once the fuzzer had repointed that field the read which
followed reverted and took the whole handler call with it - auction included. It had been opening
auctions at a healthy rate and rolling every one of them back for three audit rounds. So each suite
now also carries `invariant_theHandlerNeverDropsAFrame`, which fails if any handler call reverts at
all. That is the half a reachability test cannot cover, because the ghost that would record the
evidence dies with the frame; only the runner, counting from outside, can see it.

### What is knowingly not mitigated

Published because the alternative is worse. All of it is acceptable only while **no third-party
funds exist**, and each item is tripwired to that condition. A testnet deployment does not loosen
any of it, and a mainnet deployment holding only the author's capital does not either.

| Item | Status |
|---|---|
| **Ownership is a plain EOA.** No timelock, no multisig. A 48-hour wait per fix while the deployment shape is still moving costs more than it buys pre-launch. | Resolved at go-live by a documented checklist: timelock, a 2-of-3 governance Safe, a guardian pause role landing in the same change, and ownership handover. `test/Governance.t.sol` proves the flip is a pure `transferOwnership` with no redeploy. |
| **Manager migration is out of scope.** The contracts are immutable by choice, so fixing one means redeploying and repointing, and repointing does not move what the old contract holds. | Deliberate. Before launch the fix is to redeploy the set and move the bonds. The guards that protect any pointer change stay regardless. |
| **`seize` depends on the farm being callable.** Accepted rather than engineered around. | Accepted, documented. |
| **Slither has not been re-run over the credit core.** It was clean over the collateral layer, with every triaged suppression carrying an inline justification. | Treat the clean result as covering the earlier scope only. |

Deposits are pausable; exits are not. All wiring setters and constructors zero-address-check, and
`renounceOwnership` is disabled on the live-authority contracts.

## External addresses (Base mainnet, verified 2026-07-24)

| Name | Address |
|---|---|
| DexFi Bond ("NFTBondsMigration", ERC-1155 id 0, mint entrypoint) | `0x969C6eCF97c256846029cBCBB865824E505E006f` |
| DexFi Farm ("RewardPoolBondsMigration", UUPS proxy) | `0x0251cbB9a752331D29031eEc88c5a8BCbcDafFfa` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Chainlink ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |

## License

Business Source License 1.1 - see [LICENSE](LICENSE). Production use on other networks or forks
requires a licence until the change date, after which the code converts to MIT.
