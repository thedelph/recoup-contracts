# Recoup contracts

Smart contracts for [Recoup](https://recoup.fi) - self-repaying loans on Base, collateralised by
DexFi Treasury Bonds. Deposit bonds (or ETH that becomes bonds), borrow USDC, and the weekly bond
yield pays the debt down automatically. Debt only ever decreases.

Status: **deployed to Base Sepolia** (2026-08-03), nothing on mainnet. The collateral layer, the
credit core, the epoch harvester and the liquidation auction are implemented, and the whole loan
lifecycle - including a liquidation filling at 82% of NAV and an unfilled one falling through to
the workout path - is fork-tested against the live DexFi contracts. Lending is an interfaced
skeleton, built in deliberate phases. Nothing touches real funds before an external audit.

Testnet addresses are in [`deployments/base-sepolia.json`](deployments/base-sepolia.json), all
verified on Basescan. The testnet deployment runs against a **mock** DexFi stack, because the real
bond and farm contracts exist only on Base mainnet; the mocks mirror their verified ABIs including
the transfer whitelist. The live DexFi contracts are exercised by the mainnet fork tests below,
which are the real integration proof.

**One thing to know before you verify those addresses.** The four risk parameters in
[`src/Config.sol`](src/Config.sol) changed on 2026-08-07 to the capped-beta values agreed with
DexFi - max LTV 3500 -> 2500 bps, liquidation threshold 5800 -> 5000, and both borrow caps down.
Those parameters are `internal constant`, inlined at compile time, and the Sepolia contracts were
deployed on 2026-08-03, so **the deployed bytecode still enforces the old values**. Source and
chain genuinely disagree here, and the source is the intended one. Closing it needs a redeploy,
which is queued behind moving those four into bounded, timelocked storage so the next change is not
a redeploy either.

**Reviewing this repo?** [REVIEW.md](REVIEW.md) is a reading guide: where bonds can and cannot go,
who controls what, what revoking the whitelist would do, and which tests to run first.

`ReferralRegistry` is a standalone addition with zero coupling to the protocol above: two
write-once mappings recording who owns a referral code and which code an account bound to, with no
owner, no pause and no way to move either fact once written. It holds no value and no protocol
contract reads it. It is deliberately absent from the main deploy script, because the supported
fix for a core defect before launch is redeploying the set, and a registry inside that set would
take a new address each time and orphan every existing binding.

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

LenderPool: skeleton, implemented per phase.
All parameters live in src/Config.sol - no magic numbers anywhere else.
```

Design notes that matter for review:

- **The custody adapter is the only address that needs DexFi whitelisting.** It is ~90 lines,
  immutable, holds no USDC at rest (claims sweep onward to the yield recipient in the same call),
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
                # four invariant suites dominate, and a short timeout will kill
                # the run mid-flight rather than fail it
```

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
high: **fourteen rounds so far, and five of the last six found defects in the round before them.**
Findings are fixed with regression tests. The round-by-round record in [AUDITS.md](AUDITS.md) covers
the rounds over the code published here; the later ones also cover the lender pool, which is not in
this repository yet.

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

Alongside the audits: stateful invariant fuzzing over four suites (21 invariants), and the mainnet
fork tests above, which are the real integration proof.

An invariant suite can be vacuously green - handler actions are wrapped so an expected revert does
not fail the fixture, which means a suite that never reaches the interesting state still reports
everything passing. **All four suites** now carry a deterministic reachability test that pins the
state was actually reached. The last two were added on 2026-08-03, and one of them found that a
suite really had been vacuous: seven invariants had been running against a protocol in which no
borrow could succeed. [REVIEW.md](REVIEW.md) has the detail.

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
