# Recoup contracts

Smart contracts for [Recoup](https://recoup.fi) - self-repaying loans on Base, collateralised by
DexFi Treasury Bonds. Deposit bonds (or ETH that becomes bonds), borrow USDC, and the weekly bond
yield pays the debt down automatically. Debt only ever decreases.

Status: **pre-deployment**. The collateral layer, the credit core, the epoch harvester and the
liquidation auction are implemented, and the whole loan lifecycle - including a liquidation
filling at 82% of NAV and an unfilled one falling through to the workout path - is fork-tested
against the live DexFi contracts. Lending is an interfaced skeleton, built in deliberate phases.
Nothing touches real funds before an external audit.

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
forge test      # 197 unit + invariant tests vs real-ABI mocks
```

### Mainnet fork tests

Six integration tests run against the **live** DexFi contracts on Base (fork-at-latest, so any
full node works - no archive access needed). This is the part worth running yourself:

```sh
RUN_FORK_TESTS=true forge test --match-contract Fork -vv
# optionally: BASE_RPC_URL=<your rpc> (defaults to https://mainnet.base.org)
```

Custody, on real state:

1. the configured addresses are the live contracts and behave as documented;
2. deposits currently revert at the bond's transfer whitelist gate (today's mainnet reality);
3. a single `addWhitelist([adapter])` from the bond owner unlocks the entire lifecycle:
   deposit → stake → claim real streamed USDC → unstake → withdraw.

The loan itself, also on real state:

4. **the whole self-repaying loan end to end** - deposit real bonds, borrow at exactly max LTV,
   let a week of real USDC stream out of the live farm, apply that yield to write the debt down,
   repay the remainder, withdraw the collateral, and return the principal to the lender float.
   It also asserts, on real state, that **nothing is earned in the harvest block** - which is the
   property that makes depositing just before a harvest pointless;
5. borrowing refuses while the price feed is stale;
6. a large NAV move parks for a second key instead of being waved through by the price poster.

Test 3 is the one that shows exactly what a single `addWhitelist` call buys. Test 4 is the one
that shows the product actually works.

## Security posture (pre-external-audit)

**Four independent security reviews** have been run, each a 12-agent Solidity audit pass.

The third and fourth (July 2026) covered the epoch harvester and the yield-distribution mechanism
behind it. The fourth deliberately audited *the third round's own fixes*, and that turned out to
matter: **four of its twelve findings were regressions introduced by the third round**. Every one is
fixed with a regression test. The lesson is now a standing habit here - a fix round is new code, and
fixes that add a mechanism regress far more often than fixes that remove a constraint.

The ones worth knowing about from those two rounds:

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

The second review (after the credit core landed) covered all ten contracts and raised twelve
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

The first review covered the two contracts implemented at the time and raised eight findings, all
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
them, and an external audit is still a hard gate before any real funds.

- **Whitelist revocation is modelled, not assumed** (`test/WhitelistRevocation.t.sol`): the bond's
  transfer whitelist is owner-managed and revocable, so the blast radius of losing it is a tested
  quantity. Revocation does not only stop deposits, it strands live collateral: the farm can still
  return bonds to the adapter, but the adapter cannot pass them to a non-whitelisted depositor, and
  the emergency hatch hits the same gate unless its destination is whitelisted. Recorded here
  because the mitigation is an integration agreement, not code.
- **Stateful invariant fuzzing** (`test/CollateralVault.invariants.t.sol`): randomised multi-actor
  call sequences must preserve four invariants after every sequence - vault accounting equals farm
  stake, the adapter holds no USDC or loose bonds at rest, bond units are conserved, the vault
  itself never custodies bonds. Run: `forge test --match-contract Invariants`.
- **Slither**: was clean over the collateral layer - 0 findings with informational/optimization
  excluded, every triaged suppression carrying an inline justification. **Not yet re-run over the
  credit core**, so treat that result as covering the earlier scope only.
- **Coverage**: the collateral layer measured 96.9% lines (CollateralVault) and 97.1% lines / 100%
  functions (DirectCallAdapter) at the previous pass. Skeleton modules are stubs and intentionally
  uncovered until their phase.
- All wiring setters and the adapter constructor zero-address-check; deposits are pausable, exits
  are not; external audit is a hard gate before any real funds.

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
