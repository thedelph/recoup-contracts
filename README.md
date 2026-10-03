# Recoup contracts

[![CI](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thedelph/recoup-contracts/actions/workflows/ci.yml)

Recoup is a self-repaying loan protocol for DexFi Treasury Bonds on Base. A borrower supplies bonds,
borrows USDC, and the bonds' realised yield pays the debt down over time. This repository contains
the public Solidity contracts, tests, deployment record and reviewer documentation.

> [!WARNING]
> Recoup is deployed on Base mainnet but not yet open to users, and it accepts no third-party funds.
> Its mainnet `LenderPool` is paused and accepts no deposits. The Base Sepolia stack against mock
> USDC, bonds and farm predates the audit's fixes and does not match this source; its `LenderPool` is
> empty and not wired as the protocol's liquidity source. Do not fund or activate it.

## Current status

| Area | Status |
|---|---|
| External audit | Completed by 33Labs over six files (`LenderPool.sol`, `CreditWiring.sol`, `TreasuryLiquiditySource.sol`, `ProtocolFeeSplitter.sol`, `Config.sol`, `LtvMath.sol`) at commit b66023d, base remediation snapshot f6893cb, main reviewed through 566a9eb. 13 findings (4 High, 6 Medium, 3 Low): 11 Fixed, 2 Acknowledged / Accepted Risk. Final report and sha256 in [`audits/`](audits/). Every other contract in `src/` has had internal review only |
| Latest remediation | M-06 ([#64](https://github.com/thedelph/recoup-contracts/issues/64)) is Fixed: [#69](https://github.com/thedelph/recoup-contracts/pull/69), which also adds a permissionless floor trim, was merged into main as 566a9eb after successful repository CI, and 33Labs independently verified it before merge at 35f0a58. A Low residual is disclosed in [`KNOWN_RISKS.md`](KNOWN_RISKS.md). L-02 (#61) is retained by design; L-03 (#68) is answered by [`USDC_RUNBOOK.md`](USDC_RUNBOOK.md) |
| Core loan path | Implemented and tested: custody, NAV, borrowing, yield application, liquidation and workout |
| Base Sepolia | Historic mock-stack deployment, explorer-verified at deployment but not at parity with this source. Addresses in [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Base mainnet | Deployed 2026-10-02 and not yet open to users. The nine core contracts are owned by a `TimelockController` with a 48-hour minimum delay, whose only proposer and canceller is a 2-of-3 governance Safe; a separate guardian can pause. Every deployed runtime equals the bytecode this repository's `src/` builds, and the source is verified on Sourcify, Blockscout and BaseScan. Addresses in [`deployments/base-mainnet.json`](deployments/base-mainnet.json) |
| Lender pool | On Base mainnet: deployed, paused, empty and not yet wired as the liquidity source. The first phase wires it through the timelock and funds it only with the maintainer's own capital; it stays closed to outside deposits. [`KNOWN_RISKS.md`](KNOWN_RISKS.md) carries the exact state |
| Referral registry | Source fixed. Deployed on Base mainnet, with a runtime equal to this source; the Sepolia instance is defective and unused |

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

On Base mainnet the lender pool is paused and not yet wired. The first phase wires it through the
timelock and funds it only with the maintainer's own capital; no public, DexFi or Bond Fund capital
is accepted. Before any third-party capital:

1. The audit report's recommendations before third-party capital: keep M-06's (#64) regression
   and #61-preservation coverage, keep the activation gate, verify that a deployment matches the
   source, and verify that a production deployment includes the merged M-06 remediation commit
   566a9eb or a descendant of it. The Base mainnet deployment matches this source (see
   [Base mainnet deployment](#base-mainnet-deployment)), and this source descends from 566a9eb. The
   L-03 (#68) runbook is published as [`USDC_RUNBOOK.md`](USDC_RUNBOOK.md).
2. A fresh internal review of the principal-accounting and entry-pricing changes as shipped.
3. The mainnet go-live gates in [`KNOWN_RISKS.md`](KNOWN_RISKS.md): governance (a 48-hour timelock
   and a 2-of-3 Safe) and a rehearsed deployment are in place; the pool's wiring and an agreed DexFi
   whitelist and custody policy remain.

## Base mainnet deployment

Deployed on 2026-10-02 (blocks 52,095,163 to 52,095,204, and 52,095,514 for the referral registry).
The full record is [`deployments/base-mainnet.json`](deployments/base-mainnet.json).

| Contract | Address |
|---|---|
| `NAVOracle` | `0xF18ed41cfC1d00A179Eea790a2A4C7d48365681d` |
| `RiskParams` | `0xf273D492310B08ba02Afc427b103659112e19ACe` |
| `CollateralVault` | `0x95d5442aA3E3FDeb13DD9158fB9eCD0A1777FC53` |
| `DirectCallAdapter` | `0x2a10A9f17024f98Ab9511F73f2473f82125Eb05f` |
| `CreditManager` | `0x8E902D98Ef0b513613b42E3A0AA99b06bf28f748` |
| `TreasuryLiquiditySource` | `0x5dD8BB9A663ABDcad4a123c6684EC423a1ab0334` |
| `LenderPool` | `0x9085B96c079d8790D0A74043e2cfeB031C5d8Fb2` |
| `EpochHarvester` | `0x230A5bDECAb42dCb1f7d4850E47fb02B6F3345b6` |
| `LiquidationAuction` | `0x92E93BD303B1dcA297e69857711d7b77617c694F` |
| `ReferralRegistry` | `0x947A94BA953E68a405527E0259bBd61Ff375a567` |
| `ProtocolFeeSplitter` | `0xA905d06704451733Ea77889FD3ac9847dcD35177` |
| `CreditWiring` (library) | `0xbBd98f91088f09ABD9c1C6396b61623b7722C186` |
| `MintAttemptReceiver` (implementation, deployed by the adapter) | `0xdc1D2a566baaFE3eDDDD2599A9d9eD964e953D33` |
| `TimelockController` (owner of the nine core contracts) | `0x8357AA0899917755744B139b51c72A8AEE0301Bf` |
| Governance Safe (2-of-3; the timelock's only proposer and canceller) | `0x06ac4Ad08474F9C86912009b8489b8d363d3B2D3` |

Every deployed runtime equals the bytecode this repository's `src/` builds with its `foundry.toml`
and pinned libraries: exactly for `NAVOracle`, `RiskParams`, `ReferralRegistry` and
`TimelockController`, and apart from constructor-set immutables for the rest. Source is verified on
Sourcify (exact match), Blockscout and BaseScan for all 14. The mainnet deploy scripts are not
published in this repository; `script/` here holds the Base Sepolia and local paths.

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
