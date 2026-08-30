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

The pool is not approved to wire or fund. The current blockers are:

| Finding | Summary |
|---|---|
| Round 22 F3 | Principal-cap accounting is only partly remediated; fungible share composition, dust boundaries and repeated-loss quotient growth remain |
| Round 22 F12 | Permissionless queue service can turn shares into a claim that its receiver cannot collect |
| Round 21 F7 | A queued withdrawal is valued against the whole book but reserved out of cash, so it over-reserves by the pool's leverage; at 6.00x, 1.67% of the book halts all borrowing |

**Two rows were removed in this sync, and removed because they are fixed rather than because they
were reconsidered.** Round 22 F11 (non-epoch recovery cash inheriting an unrelated epoch clock) and
Round 22 F6a (stream re-rating extending an unreleased tail) are closed by the round-23 remediation,
which this source now contains and previously did not.

**This table describes this source, and this source is now current.** The lag that previous
revisions disclosed here - four round-22 fixes and the whole round-23 remediation absent from
the published code - is closed by this sync. One property went with it: the published
`CreditManager` no longer compiles to the bytecode deployed on Base Sepolia. See
[What this source contains](KNOWN_RISKS.md#what-this-source-contains).

Other material residual risks are Round 17's transaction-ordering window and F10's lack of
historical loss-bearer entitlement. [`KNOWN_RISKS.md`](KNOWN_RISKS.md) contains the launch-critical
and material current risks, measured traces and go-live rules. Closing the three remaining pool
blockers is necessary but not sufficient for mainnet. The merged principal-accounting and entry-pricing changes
also require a fresh internal follow-up review before Phase-4 wiring or funding; the pool remains
empty and unwired in the meantime.

## Build and test

Requires [Foundry](https://getfoundry.sh).

```sh
git submodule update --init --recursive
forge build
forge test
```

On the current public tree, the normal run is 1,227 passed, 0 failed and 32 skipped across 61
suites, 1,259 total. Every one of the 32 skips is in the six `test/fork/` suites, which need a live
Base RPC or an explicit opt-in and skip without one; nothing outside those six is skipped. CI runs
the full unit and invariant suite on every push and pull request.

Measured on this tree by a single `forge test` run with its summary line present, rather than
carried from a previous sync. The figure this replaced read 733 across 30 suites and had been wrong
since the sync before last. Three of the six fork suites report more tests than they declare,
because they subclass a fixture and inherit its suite, so counting declarations in those files
gives 29 rather than 32.

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
