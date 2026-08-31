# Recoup contracts

[![CI](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml)

Recoup is a self-repaying loan protocol for DexFi Treasury Bonds on Base. A borrower supplies bonds,
borrows USDC, and the bonds' realised yield pays the debt down over time. This repository contains
the public Solidity contracts, tests, deployment record and reviewer documentation.

> [!WARNING]
> Recoup is pre-audit and not deployed on Base mainnet. The Base Sepolia deployment uses mock USDC,
> mock bonds and a mock farm. Its `LenderPool` is empty and is not wired as the protocol's liquidity
> source. Do not fund or activate it. All listed activation blockers must close before any capital,
> including the author's, is connected to the pool. An external audit is an additional hard gate
> before third-party capital.

## Current status

| Area | Status |
|---|---|
| Core loan path | Implemented and tested: custody, NAV, borrowing, yield application, liquidation and workout |
| Base Sepolia | Historic mock-stack deployment; explorer-verified at deployment, but not current-source parity. Addresses are in [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Base mainnet | No Recoup contracts deployed |
| Lender pool | Source and testnet instance exist, but the pool is empty, unwired and blocked from activation |
| Referral registry | Source fixed through partner self-registration; the carried-over Sepolia instance remains defective and unused, and live replacement is disabled and unauthorised |
| External audit | Not completed |

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
| `EpochHarvester` | Claims realised farm yield, splits it and applies the borrower share to debt |
| `LiquidationAuction` | Public Dutch auction with a workout fallback for unfilled positions |
| `LenderPool` | ERC-4626 USDC pool, impairment pricing and FIFO withdrawal queue; not approved for activation |
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
| Round 21 F7, queue over-reservation | **Closed.** `_queueCashReserve` is a per-controller pro-rata slice of executable cash. The old code priced the exit against the whole book and subtracted it from cash alone, which is why the over-reservation equalled leverage; that multiplier is gone by construction |
| Round 22 F12, uncollectable claims | **Half closed.** `serviceWithdrawalRequest` reverts unless the caller is the controller or an operator it approved, so service is no longer permissionless. A claim recorded for a receiver the asset refuses to pay is still uncollectable, and that half is accepted rather than fixed |

Round 22 F11 and F6a were listed here in earlier revisions and are fixed: F11 rated non-epoch
recovery cash on the yield-epoch clock, and F6a let `_rateStream` floor a new stream's duration at
the old one's remaining time.

**What still stands between this and an activated pool**, in the order it has to happen:

1. The accepted F12 residual above, which is disclosed rather than closed.
2. A fresh internal review of the merged principal-accounting and entry-pricing changes. They are
   substantial, they are recent, and they have not been reviewed as shipped.
3. An external audit, which is a hard gate for any third-party capital.
4. Round 17's transaction-ordering window and F10's lack of historical loss-bearer entitlement,
   which are material residual risks rather than blockers.

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

On the current public tree, `forge test` gives 1,227 passed, 0 failed and 32 skipped across 61
suites, 1,259 total. All 32 skips are the six `test/fork/` suites, which need a live Base RPC or an
explicit opt-in; nothing else is skipped. Counting test declarations in those fork files gives 29
rather than 32, because three of them subclass a fixture and inherit its suite. CI runs the full
unit and invariant suite on every push and pull request.

### Mainnet fork tests

```sh
RUN_FORK_TESTS=true forge test --match-contract Fork -vv
# optionally: BASE_RPC_URL=<your rpc> (defaults to https://mainnet.base.org)
```

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
- [`deployments/base-sepolia.json`](deployments/base-sepolia.json) - current testnet addresses and state

Internal adversarial review and invariant testing are not an external audit. Please report
inconsistencies between the documentation, tests and contract behaviour.

## License

Business Source License 1.1. See [`LICENSE`](LICENSE). Production use on other networks or forks
requires a licence until the change date, after which the code converts to MIT.
