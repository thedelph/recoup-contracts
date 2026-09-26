# External audits

| Report | Auditor | Review window | Scope | Result |
|---|---|---|---|---|
| [33labs-recoup-final-report-2026-09-26.pdf](33labs-recoup-final-report-2026-09-26.pdf) | 33Labs (0x23r0, PhantomOz) | 2026-09-07 to 2026-09-26 | Six files at commit b66023d: LenderPool.sol, CreditWiring.sol, TreasuryLiquiditySource.sol, ProtocolFeeSplitter.sol, Config.sol, LtvMath.sol. Contract remediation reviewed through f6893cb, documentation through 1ec1978, and the M-06 fix on #69 at 35f0a58 | 13 findings (4 High, 6 Medium, 3 Low): 10 Fixed; M-06 #64 Fix Verified / Pending Merge; L-02 #61 and L-03 #68 Acknowledged / Accepted Risk |

This is the re-issued final report. It replaces the first issue of 2026-09-22 (SHA-256
`612fbe1adb22a9d9cd4425b391196a222557d43430b79e6c6140f2ad7c3e92db`), which classed M-06 as
Acknowledged / Accepted Risk; that file is in this repository's history.

SHA-256 of the report, also in the `.sha256` file beside it:

```text
d4dd3226a4745b37d89c3c6c700d6a6bafbf7b9e8aa1a11fc99c7a3dd864040d
```

Check a downloaded copy with `sha256sum -c 33labs-recoup-final-report-2026-09-26.pdf.sha256` from
this directory.

What the audit covers and what it does not:

- It covers the six files above, at the commits above. Every other contract in `src/` (among them the
  credit manager, the liquidation auction, the collateral vault, the harvester, the NAV oracle and the
  custody adapter) was outside the scope and has had internal review only.
- M-06 is "Fix Verified / Pending Merge" because the report dates the fix unmerged: 33Labs verified
  #69 at its head 35f0a58. #69 was merged on 2026-09-26 as 566a9eb, and `src/`, `test/`, `script/`,
  `lib/` and `foundry.toml` are identical between 35f0a58 and 566a9eb (only documentation merged in
  between differs); this repository's CI passed on 566a9eb.
- It is not a statement about any deployment. The Base Sepolia deployment predates the fixes, and
  nothing is deployed on Base mainnet.
- The report's own disclaimer: a security review cannot prove the absence of vulnerabilities, and it
  recommends further review, deployment verification, monitoring and a public bug bounty before
  production use.
- Its conclusion recommends, before third-party capital: merging the verified M-06 remediation,
  retaining its regression and #61-preservation coverage, publishing the L-03 incident runbook,
  retaining the activation gate, and verifying deployment and source parity.
  [`KNOWN_RISKS.md`](../KNOWN_RISKS.md) tracks each.
