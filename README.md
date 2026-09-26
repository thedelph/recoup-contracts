# Recoup contracts

[![CI](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml)

Recoup is a self-repaying loan protocol for DexFi Treasury Bonds on Base. A borrower supplies bonds,
borrows USDC, and the bonds' realised yield pays the debt down over time. This repository contains
the public Solidity contracts, tests, deployment record and reviewer documentation.

> [!WARNING]
> Recoup is not deployed on Base mainnet and accepts no third-party funds. The only deployment is a
> Base Sepolia testnet stack against mock USDC, bonds and farm; it predates the audit's fixes and does
> not match this source. Its `LenderPool` is empty and not wired as the protocol's liquidity source.
> Do not fund or activate it.

## Current status

| Area | Status |
|---|---|
| External audit | Completed 2026-09-22 by 33Labs over six files (`LenderPool.sol`, `CreditWiring.sol`, `TreasuryLiquiditySource.sol`, `ProtocolFeeSplitter.sol`, `Config.sol`, `LtvMath.sol`) at commit b66023d, remediation reviewed through f6893cb. 13 findings (4 High, 6 Medium, 3 Low): 10 Fixed, 3 Acknowledged / Accepted Risk. Final report and sha256 in [`audits/`](audits/). Every other contract in `src/` has had internal review only |
| Remediation after the report | M-06 ([#64](https://github.com/thedelph/recoup-contracts/issues/64)) is fixed in this source by [#69](https://github.com/thedelph/recoup-contracts/pull/69), which also adds a permissionless floor trim; a Low residual is disclosed in [`KNOWN_RISKS.md`](KNOWN_RISKS.md). The report in `audits/` predates that fix. L-02 (#61) is retained by design; L-03 (#68) is answered by [`USDC_RUNBOOK.md`](USDC_RUNBOOK.md) |
| Core loan path | Implemented and tested: custody, NAV, borrowing, yield application, liquidation and workout |
| Base Sepolia | Historic mock-stack deployment, explorer-verified at deployment but not at parity with this source. Addresses in [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Base mainnet | No Recoup contracts deployed |
| Lender pool | Not approved to wire or fund; [`KNOWN_RISKS.md`](KNOWN_RISKS.md) carries the exact state |
| Referral registry | Source fixed; the Sepolia instance is defective and unused, and live redeployment is disabled |

The real DexFi bond and farm contracts exist only on Base mainnet. Mainnet fork tests exercise them
directly; the Sepolia mocks mirror their verified interfaces, including the bond transfer whitelist.

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
| `CreditWiring` | Deploy-time-linked library `CreditManager` reaches by delegatecall for its wiring probes, split out to fit the EIP-170 limit |
| `EpochHarvester` | Claims realised farm yield, splits it and applies the borrower share to debt |
| `LiquidationAuction` | Public Dutch auction with a workout fallback for unfilled positions |
| `LenderPool` | ERC-4626 USDC pool with impairment pricing and escrowed withdrawal requests; not approved for activation |
| `ReferralRegistry`, `ProtocolFeeSplitter` | Standalone referral and fee-routing utilities, outside the core deployment path |

Fixed parameters and external addresses live in [`src/Config.sol`](src/Config.sol); max LTV,
liquidation threshold and the borrow caps live in bounded storage in
[`src/RiskParams.sol`](src/RiskParams.sol).

## Activation blockers and residual risks

The lender pool is not approved to wire or fund, including with the author's capital, and no
public, DexFi or Bond Fund capital is accepted. Before any of that:

1. The audit report's recommendations before third-party capital: revisit M-06 (#64) together with
   the L-02 (#61) trade-off, keep the activation gate, and verify that a deployment matches the
   source. The L-03 (#68) runbook is published as [`USDC_RUNBOOK.md`](USDC_RUNBOOK.md).
2. A fresh internal review of the principal-accounting and entry-pricing changes as shipped.
3. The mainnet go-live gates in [`KNOWN_RISKS.md`](KNOWN_RISKS.md): governance (timelock and Safe),
   wiring, a rehearsed deployment, and an agreed DexFi whitelist and custody policy.

Disclosed residual risks, each with its mechanism and the function that implements it, are in
[`KNOWN_RISKS.md`](KNOWN_RISKS.md). Among them: the post-loss request-floor lock (#61), the
round 22 F12 uncollectable-receiver claim, round 17's transaction-ordering window, and the
paused-USDC behaviour of the bond doors (#68).

## Build and test

Requires [Foundry](https://getfoundry.sh).

```sh
git submodule update --init
forge build
forge test
```

`--recursive` is deliberately absent: nothing here imports OpenZeppelin's own nested submodules.
Remappings are pinned in `foundry.toml`, so every clone compiles the same bytecode. CI runs the full
unit and invariant suite on every push and pull request; the invariant campaigns take several
minutes.

### Mainnet fork tests

```sh
RUN_FORK_TESTS=true forge test --match-contract Fork -vv
# optionally: BASE_RPC_URL=<your rpc> (defaults to https://mainnet.base.org)
```

These run against the live DexFi contracts: the custody lifecycle including the whitelist gate, the
self-repaying loan path, liquidation and stale-NAV refusal. A few tests skip by design even with
the opt-in; [`REVIEW.md`](REVIEW.md) names them.

## DexFi integration

- `DirectCallAdapter` is the only Recoup address that needs DexFi bond-transfer whitelisting.
- Revoking that whitelist while collateral is live can strand withdrawals; the required operational
  agreement is in [`REVIEW.md`](REVIEW.md).
- Liquidation transfers bonds from the adapter to the winning bidder; there is no second custody
  contract, and nothing in `src/` redeems bonds from the fund.
- Mainnet activation needs an agreed whitelist and custody policy and caps set against DexFi's
  admin-key and upgrade posture.

## Documentation

- [`REVIEW.md`](REVIEW.md) - code-level reading guide for DexFi and other reviewers
- [`KNOWN_RISKS.md`](KNOWN_RISKS.md) - activation gates, residual risks and each audit finding's disposition
- [`audits/`](audits/) - the external audit report, with its sha256
- [`USDC_RUNBOOK.md`](USDC_RUNBOOK.md) - what each door does while USDC is paused or blacklists a
  Recoup address, and what the operator does (L-03, #68)
- [`AUDITS.md`](AUDITS.md) - historical internal review log
- [`deployments/base-sepolia.json`](deployments/base-sepolia.json) - testnet addresses and state

Please report inconsistencies between the documentation, tests and contract behaviour. Do not post
suspected vulnerability details in a public issue; contact the maintainer privately first.

## License

Business Source License 1.1. See [`LICENSE`](LICENSE). Production use on other networks or forks
requires a licence until the change date, after which the code converts to MIT.
