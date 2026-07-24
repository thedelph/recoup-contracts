# Recoup contracts

Smart contracts for [Recoup](https://recoup.fi) - self-repaying loans on Base, collateralised by
DexFi Treasury Bonds. Deposit bonds (or ETH that becomes bonds), borrow USDC, and the weekly bond
yield pays the debt down automatically. Debt only ever decreases.

Status: **pre-deployment**. The collateral layer is implemented and fork-tested against the live
DexFi contracts; credit, lending, and liquidation modules are interfaced skeletons built in
deliberate phases. Nothing touches real funds before an external audit.

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

CreditManager / LenderPool / EpochHarvester / LiquidationAuction / NAVOracle: skeletons,
implemented per phase. All parameters live in src/Config.sol - no magic numbers anywhere else.
```

Design notes that matter for review:

- **The custody adapter is the only address that needs DexFi whitelisting.** It is ~90 lines,
  immutable, holds no USDC at rest (claims sweep to the vault in the same call), and only the
  vault can call it. The `ICustodyAdapter` interface keeps custody swappable (direct-call vs a
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
forge test      # 33 unit tests vs real-ABI mocks
```

### Mainnet fork tests

Three integration tests run against the **live** DexFi contracts on Base (fork-at-latest, so any
full node works - no archive access needed):

```sh
RUN_FORK_TESTS=true forge test --match-contract Fork -vv
# optionally: BASE_RPC_URL=<your rpc> (defaults to https://mainnet.base.org)
```

They prove, on real state:

1. the configured addresses are the live contracts and behave as documented;
2. deposits currently revert at the bond's transfer whitelist gate (today's mainnet reality);
3. a single `addWhitelist([adapter])` from the bond owner unlocks the entire lifecycle:
   deposit → stake → claim real streamed USDC → unstake → withdraw.

## Security posture (pre-audit)

- **Stateful invariant fuzzing** (`test/CollateralVault.invariants.t.sol`): randomised multi-actor
  call sequences must preserve four invariants after every sequence - vault accounting equals farm
  stake, the adapter holds no USDC or loose bonds at rest, bond units are conserved, the vault
  itself never custodies bonds. Run: `forge test --match-contract Invariants`.
- **Slither**: clean - 0 findings with informational/optimization excluded; every triaged
  suppression carries an inline justification comment.
- **Coverage** (implemented contracts): CollateralVault 96.9% lines, DirectCallAdapter 97.1% lines
  / 100% functions. Skeleton modules are stubs and intentionally uncovered until their phase.
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
