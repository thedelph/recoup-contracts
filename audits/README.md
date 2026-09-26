# External audits

| Report | Auditor | Review window | Scope | Result |
|---|---|---|---|---|
| [33labs-recoup-final-report-2026-09-22.pdf](33labs-recoup-final-report-2026-09-22.pdf) | 33Labs (0x23r0, PhantomOz) | 2026-09-07 to 2026-09-22 | Six files at commit b66023d: LenderPool.sol, CreditWiring.sol, TreasuryLiquiditySource.sol, ProtocolFeeSplitter.sol, Config.sol, LtvMath.sol. Remediation reviewed through f6893cb | 13 findings (4 High, 6 Medium, 3 Low): 10 Fixed; M-06 #64, L-02 #61 and L-03 #68 Acknowledged / Accepted Risk |

SHA-256 of the report, also in the `.sha256` file beside it:

```text
612fbe1adb22a9d9cd4425b391196a222557d43430b79e6c6140f2ad7c3e92db
```

Check a downloaded copy with `sha256sum -c 33labs-recoup-final-report-2026-09-22.pdf.sha256` from
this directory.

What the audit covers and what it does not:

- It covers the six files above, at the commits above. Every other contract in `src/` (among them the
  credit manager, the liquidation auction, the collateral vault, the harvester, the NAV oracle and the
  custody adapter) was outside the scope and has had internal review only.
- It is not a statement about any deployment. The Base Sepolia deployment predates the fixes, and
  nothing is deployed on Base mainnet.
- The report's own disclaimer: a security review cannot prove the absence of vulnerabilities, and it
  recommends further review, deployment verification, monitoring and a public bug bounty before
  production use.
- Its conclusion recommends, before third-party capital: revisiting M-06 together with the L-02
  trade-off, publishing the L-03 incident runbook, retaining the activation gate, and verifying
  deployment and source parity. [`KNOWN_RISKS.md`](../KNOWN_RISKS.md) tracks each.
