# Recoup contracts

[![CI](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml)

Recoup is a self-repaying loan protocol for DexFi Treasury Bonds on Base. A borrower supplies bonds,
borrows USDC, and the bonds' realised yield pays the debt down over time. This repository contains
the public Solidity contracts, tests, deployment record and reviewer documentation.

> [!WARNING]
> Recoup is not deployed on Base mainnet. An external audit by 33Labs of six lender-pool files
> completed on 2026-09-22 ([`audits/`](audits/)); every other contract in `src/` has had internal
> review only. The Base Sepolia deployment uses mock USDC, mock bonds and a mock farm, predates the
> audit's fixes, and is not what the audit describes. Its `LenderPool` is empty and is not wired as
> the protocol's liquidity source. Do not fund or activate it. All listed activation blockers must
> close before any capital, including the author's, is connected to the pool.

## Current status

| Area | Status |
|---|---|
| Core loan path | Implemented and tested: custody, NAV, borrowing, yield application, liquidation and workout |
| Base Sepolia | Historic mock-stack deployment; explorer-verified at deployment, but not current-source parity. Addresses are in [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Base mainnet | No Recoup contracts deployed |
| Lender pool | Source and testnet instance exist. The testnet pool is empty and blocked from activation, and it is not wired as the protocol's liquidity source; its own pointers to the manager and the harvester are set, so "unwired" is true in one direction only. [`KNOWN_RISKS.md`](KNOWN_RISKS.md) carries the exact state |
| Referral registry | Source fixed through partner self-registration; the carried-over Sepolia instance remains defective and unused, and live replacement is disabled and unauthorised |
| External audit | Completed 2026-09-22. 33Labs reviewed six files (`LenderPool.sol`, `CreditWiring.sol`, `TreasuryLiquiditySource.sol`, `ProtocolFeeSplitter.sol`, `Config.sol`, `LtvMath.sol`) at commit b66023d from 2026-09-07, with remediation reviewed through f6893cb. 13 findings (4 High, 6 Medium, 3 Low): 10 Fixed, and M-06 #64, L-02 #61 and L-03 #68 Acknowledged / Accepted Risk. The final report and its sha256 are in [`audits/`](audits/); [`KNOWN_RISKS.md`](KNOWN_RISKS.md) records each disposition. The other contracts in `src/` were outside the scope |

For non-reserved referral codes, the only registration path now assigns the code to its caller. A
partner's payout wallet or Safe must call `register(bytes32)` before the code is published;
delegated `registerFor(bytes32,address)` has been removed. This source has only been rehearsed
locally. The committed Sepolia address is unchanged, and the standalone deploy script rejects every
non-local chain with `LiveDeploymentDisabled`.

The real DexFi bond and farm contracts exist only on Base mainnet. Mainnet fork tests exercise those
live contracts and their current state. The Sepolia mocks mirror their verified interfaces,
including the bond transfer whitelist.

## Architecture

```text
User
  |
  | deposit bonds / mint through DexFi / withdraw
  v
CollateralVault ---> DirectCallAdapter ---> DexFi Bond + Farm
  |                         |
  | borrow / repay          +--> realised USDC yield
  v                                      |
CreditManager <--- NAVOracle             v
  ^               RiskParams       EpochHarvester
  |
  +--- ILiquiditySource <--- TreasuryLiquiditySource (current testnet source)
                          \-- LenderPool (published, empty and unwired)
  |
  +--- LiquidationAuction ---> public bidder or workout
```

| Component | Purpose |
|---|---|
| `CollateralVault`, `DirectCallAdapter` | Bond accounting and the only custody path that calls DexFi |
| `NAVOracle`, `RiskParams` | Keeper-posted NAV and bounded, governable LTV/cap parameters |
| `CreditManager`, `TreasuryLiquiditySource` | Debt accounting and the simple liquidity source used before pool activation |
| `CreditWiring` | Deploy-time-linked library that `CreditManager` reaches by delegatecall for its wiring and migration probes; split out so the manager fits under the EIP-170 runtime limit |
| `EpochHarvester` | Claims realised farm yield, splits it and applies the borrower share to debt |
| `LiquidationAuction` | Public Dutch auction with a workout fallback for unfilled positions |
| `LenderPool` | ERC-4626 USDC pool, impairment pricing, and escrowed withdrawal requests serviced per controller rather than a global queue; not approved for activation |
| `ReferralRegistry`, `ProtocolFeeSplitter` | Standalone referral and fee-routing utilities; neither is part of the core deployment path |

Fixed protocol parameters and external addresses live in [`src/Config.sol`](src/Config.sol). Max LTV,
liquidation threshold, global borrow cap and per-account cap live in bounded storage in
[`src/RiskParams.sol`](src/RiskParams.sol).

## Activation blockers and residual risks

**The pool is not approved to wire or fund, and no public, DexFi or Bond Fund capital is accepted
before an external audit.** That gate is independent of everything below: closing findings does not
open it.

Three findings were previously published here as activation blockers. They were written against a
lender pool this source replaces, and their status against what is actually here is:

| Finding | Status in this source |
|---|---|
| Round 22 F3, principal-cap accounting | **Closed.** There are no principal units, so the residuals that were properties of them cannot be reproduced. Cap usage is `max(accountedCash + outstandingPrincipal - totalClaimable, 0)`, and the quotient bound is held explicitly by `minimumEntryAssets`, `entryPriceCashReserve` and `maximumShareSupply` |
| Round 21 F7, queue over-reservation | **Closed as the leverage multiplier.** `_queueCashReserve` is the larger of a pro-rata slice of executable cash taken over every outstanding request at once and `_floorTotal`, the cash the live requests were quoted when they queued, clamped at the executable cash; `maxRequestRedeem` is the per-controller figure, capped at the cash the other live requests are not owed. Both arms are cash, so the old code's pricing of the exit against the whole book, which is why the over-reservation equalled leverage, is gone by construction. Until 2026-09-18 this row described the pro-rata arm alone. The floors are not written down on a raw loss, so after one they can reserve more than the cash and lock it: that residual is #61, in the list below |
| Round 22 F12, uncollectable claims | **Half closed.** `serviceWithdrawalRequest` reverts unless the caller is the controller or an operator it approved, so service is no longer permissionless. A claim recorded for a receiver the asset refuses to pay is still uncollectable, and that half is accepted rather than fixed |

Round 22 F11 and F6a were listed here in earlier revisions and are fixed: F11 rated non-epoch
recovery cash on the yield-epoch clock, and F6a let `_rateStream` floor a new stream's duration at
the old one's remaining time.

**What still stands between this and an activated pool**, in the order it has to happen:

1. The accepted F12 residual above, which is disclosed rather than closed.
2. A fresh internal review of the merged principal-accounting and entry-pricing changes. They are
   substantial, they are recent, and they have not been reviewed as shipped.
3. An external audit, which is a hard gate for any third-party capital. 33Labs completed it on
   2026-09-22 over six files ([`audits/`](audits/)). Its conclusion recommends four things before
   third-party capital: revisiting M-06 (#64) together with the L-02 (#61) trade-off, publishing
   the L-03 (#68) incident runbook, retaining the activation gate, and verifying that the
   deployment matches the source.
4. Round 17's transaction-ordering window, F10's lack of historical loss-bearer entitlement and
   the post-loss lock of #61 (Low, acknowledged and retained by design, since 2026-09-17), which
   are material residual risks rather than blockers. The lock needs a raw loss of pool cash, which,
   on a reading of the source and the measurements in [`KNOWN_RISKS.md`](KNOWN_RISKS.md), no loss
   path inside the protocol produces, and it is released by a repayment, a new deposit, a
   released yield delivery or a floor holder's cancel, each only where it lifts the executable
   cash over the floors the other requests are owed (a deposit below that joins the lock); only
   the yield is the protocol's own and on a clock, each delivery rated over at least
   `YIELD_STREAM_DURATION` and at most `MAX_YIELD_STREAM_DURATION` with a later epoch re-rating
   what has not yet released, so the recovery has a clock when the fund pays and none otherwise
   (since 2026-09-19; until then this item named three releases, no clock and no threshold).

[`KNOWN_RISKS.md`](KNOWN_RISKS.md) carries the mechanism behind each of these and names the function
that implements it, so every claim above can be checked against the source rather than believed.

**One property was given up to make this source current: the published `CreditManager` no longer
compiles to the bytecode deployed on Base Sepolia.** Treat that deployment as historic and verify it
against the explorer rather than against this source. See
[What this source contains](KNOWN_RISKS.md#what-this-source-contains).

## Build and test

Requires [Foundry](https://getfoundry.sh).

```sh
git submodule update --init
forge build
forge test
```

`--recursive` is deliberately absent. It fetches OpenZeppelin's own `erc4626-tests` and
`halmos-cheatcodes` submodules, which nothing here imports, and on a long path it can fail
outright. Remappings are pinned in `foundry.toml` rather than auto-detected from what happens to be
on disk, so the build is byte-identical either way: verified from a cold clone, 4,997 bytes of
`CreditWiring` initcode and two remappings in the metadata in both cases.

As of 2026-09-17, `forge test` on this tree gives 1,940 passed, 0 failed and 32 skipped across 151
suites, 1,972 total, measured with forge 1.8.1 on a clean build of this repository in two
`--match-path` groups run one at a time with nothing else running, whose suite and test counts sum
to those figures: the seven invariant campaign files, 7 suites and 90 tests in 1,768.41s, and
everything else, 144 suites and 1,882 tests in 203.28s. The sync of 2026-09-18 adds one suite,
[`test/R61A4_PublicLockClaims.t.sol`](test/R61A4_PublicLockClaims.t.sol), 24 tests of which 5 are
new bodies and 19 are the `R60S2_H03LockBound` tests it inherits and runs again, measured alone on
forge 1.8.1 at 24 passed; with it the tree reads 1,964 passed, 0 failed and 32 skipped across 152
suites, 1,996 total, as that sum and not as one run. The sync of 2026-09-19 adds one more suite,
[`test/R62S1_YieldDoorAndSecondCancel.t.sol`](test/R62S1_YieldDoorAndSecondCancel.t.sol), 27 tests
of which 8 are new bodies and 19 are the same inherited `R60S2_H03LockBound` tests run a third
time, measured alone on forge 1.8.1 at 27 passed; with it the tree reads 1,991 passed, 0 failed and
32 skipped across 153 suites, 2,023 total, again as a sum, which this repository's CI then measured
as one run on forge 1.8.3 on 2026-09-21. The sync of 2026-09-21 adds one more suite,
[`test/R63A3_DrawMemoryDust.t.sol`](test/R63A3_DrawMemoryDust.t.sol), 5 tests over the bare-pool
fixture [`test/R63A3_Fixture.sol`](test/R63A3_Fixture.sol): the reproduction for #64, a request
serviced down to one share-wei keeping the rest of its cash floor. It pins that finding as the
source stands, so its two dust-held-floor tests are expected to flip the day a fix lands. Measured
alone on forge 1.8.1 at 5 passed; with it the tree reads 1,996 passed, 0 failed and 32 skipped
across 154 suites, 2,028 total, again as a sum, which was also re-derived here as one whole run on
forge 1.8.1. The sync that carries the round-63 audit seats adds eight more suites and 74
tests. Six of them were taken as one whole run; the last two were added after that run and are
measured alone, so the totals below are a sum again. The second reproduction for #64,
[`test/R63S61_DustHeldFloorWiredGraph.t.sol`](test/R63S61_DustHeldFloorWiredGraph.t.sol) over the
four-contract graph fixture
[`test/R62A3_GraphFixture.sol`](test/R62A3_GraphFixture.sol), whose assertions are expected to
flip with the first one's; three more over the same bare pool as the first,
[`test/R63A3_YieldDoorRepeated.t.sol`](test/R63A3_YieldDoorRepeated.t.sol),
[`test/R63A3_ShutOutAndDepositDoor.t.sol`](test/R63A3_ShutOutAndDepositDoor.t.sol) and the
campaign [`test/R63A3_PoolDoors.invariants.t.sol`](test/R63A3_PoolDoors.invariants.t.sol), which
is the eighth invariant file; and the mint-signature pair
[`test/R63A2_KeeperSignatureSeat.t.sol`](test/R63A2_KeeperSignatureSeat.t.sol) with its fork twin
[`test/fork/R63A2_RealBondFork.t.sol`](test/fork/R63A2_RealBondFork.t.sol), whose 10 tests skip
without the opt-in. Those six read 2,042 passed, 0 failed and 42 skipped across 160 suites, 2,084
total, measured as ONE run on forge 1.8.1 in 1,680.68s and not as a sum, of which the new campaign
took 617.46s. Two more follow them:
[`test/R64A4_DustFloorCurve.t.sol`](test/R64A4_DustFloorCurve.t.sol), 13 tests mapping the
threshold curve of the same finding on the same bare pool, measured alone at 13 passed; and
[`test/R64A1_RealFarmPausedUsdcFork.t.sol`](test/R64A1_RealFarmPausedUsdcFork.t.sol), a fork
suite whose 5 tests all skip without the opt-in, measured alone at 0 passed and 5 skipped. With
those two the tree reads 2,055 passed, 0 failed and 47 skipped across 162 suites, 2,102 total, as
a sum. The
figure is dated because it is derived
from the test tree by a
checker that does not live in this repository, so nothing here can hold it to the truth; it read
1,921 across 150 suites from the sync of 2026-09-15 until this one, 1,901 across 149 before that,
1,798 across 137 before that,
and 1,245 across 62 before the sync of 2026-09-12. All 47 skips are the eight fork suites, the seven under `test/fork/` plus
[`test/R64A1_RealFarmPausedUsdcFork.t.sol`](test/R64A1_RealFarmPausedUsdcFork.t.sol), which sits
beside the fixtures it imports; every one of the eight is selected by `--match-contract Fork`, which
is how the section below says to run them, and every one needs a live Base RPC or an explicit
opt-in. Nothing else is skipped. With the opt-in set, 41 of those 47 run and 6 still
skip by design; the fork-test section below says which. Counting test declarations in those eight files gives 43
rather than 47, because four of them subclass a fixture and inherit its suite. CI runs the full
unit and invariant suite on every push and pull request. The workflow installs Foundry's stable
release, which resolved to forge 1.8.1 through 2026-09-14 and to 1.8.3 from 2026-09-15. The figures
above are from 1.8.1; the lender-pool, H-03 and vault-seam suites were re-run on 1.8.3 on this tree
before the 2026-09-15 sync, and the public CI run on its merge (run 35032144995, the push to main
at 68c0c26 on 2026-09-15, forge 1.8.3) printed the totals of that sync on both releases, 1,921
passed, 0 failed and 32 skipped across
150 suites, 1,953 total, and the same contract sizes row for row, so the figures held on both;
until 2026-09-17 this sentence pointed at "the pull request's own run" without naming
it. The 2026-09-17 figures above add one suite and 19 tests to that measurement, of which 7 are new
test bodies and 12 are the `R42S1_H03Floor` tests the new suite inherits and runs a second time,
and were taken on 1.8.1 only; the CI run on that sync's merge (run 35287480369, the push to main at
0f49e61 on 2026-09-17, forge 1.8.3) printed the same totals, 1,940 passed, 0 failed and 32
skipped across 151 suites. One measurement
moved between the two versions on identical bytecode, the `depositETH` gas pair in
`test_a7_measureLocalDepositEthGas` (808,296 under isolation on 1.8.1 against 955,996 on 1.8.3,
and 808,860 without isolation on both), so since 2026-09-15 that test pins its execution mode with
an inline `forge-config` line and keeps its 900,000 ceiling on the pair rather than pinning a
number.

### Mainnet fork tests

```sh
RUN_FORK_TESTS=true forge test --match-contract Fork -vv
# optionally: BASE_RPC_URL=<your rpc> (defaults to https://mainnet.base.org)
```

With all eight fork suites present that printed 41 passed, 0 failed and 6 skipped of 47 in 48.55s,
against a fork at latest on the public endpoint; with seven it printed 37 of 42, and on 2026-09-17
at 68c0c26, with six, 27 passed, 0 failed and 5 skipped of 32. The 6 skip by design: four are one fixture test inherited by
`test/fork/CollateralVault.fork.t.sol`, `test/fork/CreditCore.fork.t.sol` and
`test/fork/Liquidation.fork.t.sol` and `test/R64A1_RealFarmPausedUsdcFork.t.sol`, which needs a retunable `RiskParams` and has none on a fresh
fork; two are `test/fork/DexFiMintAttempt.fork.t.sol`, which runs only with `RUN_DEXFI_MINT_PROOF`
set and, for the handoff itself, a DexFi keeper signature. The review tour names each beside the
same command.

The fork suite covers the custody lifecycle against the live DexFi contracts, including the current
whitelist rejection and the single adapter whitelist required to unlock it. It also exercises the
self-repaying loan path, stale-NAV refusal and the second-key confirmation path for a large NAV move.
See [`REVIEW.md`](REVIEW.md) for the suggested reading order and the exact integration claims.

## DexFi integration

- `DirectCallAdapter` is the only Recoup address that needs DexFi bond-transfer whitelisting. The
  vault initiates deposits by transferring bonds into that whitelisted adapter.
- Revoking that whitelist while collateral is live can strand withdrawals. The behaviour and the
  required operational agreement are documented in [`REVIEW.md`](REVIEW.md).
- Liquidation transfers bonds directly from the adapter to the winning bidder; it does not introduce
  a second custody contract.
- Mainnet activation requires an agreed whitelist/custody policy and a cap decision that accounts for
  DexFi's current admin-key and upgrade posture.

## Documentation

- [`KNOWN_RISKS.md`](KNOWN_RISKS.md) - current activation blockers, residual risks and pre-launch gates
- [`REVIEW.md`](REVIEW.md) - code-level reading guide for DexFi and other reviewers
- [`AUDITS.md`](AUDITS.md) - historical internal review log; currently written through round nine
- [`audits/`](audits/) - external audit reports, with their sha256
- [`USDC_RUNBOOK.md`](USDC_RUNBOOK.md) - what each door does while USDC is paused or blacklists a
  Recoup address, and what the operator does (external review finding L-03, #68)
- [`deployments/base-sepolia.json`](deployments/base-sepolia.json) - current testnet addresses and state

Internal adversarial review and invariant testing are not an external audit. Please report
inconsistencies between the documentation, tests and contract behaviour.

## License

Business Source License 1.1. See [`LICENSE`](LICENSE). Production use on other networks or forks
requires a licence until the change date, after which the code converts to MIT.
