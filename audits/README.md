# External audits

| Report | Auditor | Review window | Scope | Result |
|---|---|---|---|---|
| [33labs-recoup-final-report-2026-09-29.pdf](33labs-recoup-final-report-2026-09-29.pdf) | 33Labs (0x23r0, PhantomOz) | 2026-09-07 to 2026-09-26 | Six files at commit b66023d: LenderPool.sol, CreditWiring.sol, TreasuryLiquiditySource.sol, ProtocolFeeSplitter.sol, Config.sol, LtvMath.sol. Base remediation snapshot f6893cb, main reviewed through 566a9eb, and the M-06 fix additionally reviewed on #69 at 35f0a58 | 13 findings (4 High, 6 Medium, 3 Low): 11 Fixed; L-02 #61 and L-03 #68 Acknowledged / Accepted Risk |

This is the final report as re-issued on 2026-09-29. It replaces the issue of 2026-09-26
(SHA-256 `d4dd3226a4745b37d89c3c6c700d6a6bafbf7b9e8aa1a11fc99c7a3dd864040d`), which classed M-06 as
Fix Verified / Pending Merge, and that issue replaced the first of 2026-09-22 (SHA-256
`612fbe1adb22a9d9cd4425b391196a222557d43430b79e6c6140f2ad7c3e92db`), which classed M-06 as
Acknowledged / Accepted Risk. Both earlier files are in this repository's history.

SHA-256 of the report, also in the `.sha256` file beside it:

```text
83d9b929c481cf2fbf730c53b71d7f681d926fd52c58f3764e4ea7f091f0562a
```

Check a downloaded copy with `sha256sum -c 33labs-recoup-final-report-2026-09-29.pdf.sha256` from
this directory.

What the audit covers and what it does not:

- It covers the six files above, at the commits above. Every other contract in `src/` (among them the
  credit manager, the liquidation auction, the collateral vault, the harvester, the NAV oracle and the
  custody adapter) was outside the scope and has had internal review only.
- M-06 is Fixed: the report records that #69 was merged into main as 566a9eb after successful
  repository CI, and that before merge 33Labs independently verified 35f0a58, where 72 of 72
  fix-focused tests and 104 of 104 #61-preservation tests passed.
- The report also records 33Labs' independent verification of three fixes on commit 29af396: M-04
  (#51), the capped 30-day stream and newcomer full-value recovery; M-05 (#52), successive partial
  backlog delivery, with the below-ceiling anti-capture behaviour preserved; and L-01 (#54), repeated
  non-count-changing settlement preserving the same 41,254-base-unit accrual as a single settlement.
- It is not a statement about any deployment. The Base Sepolia deployment predates the fixes, and
  nothing is deployed on Base mainnet.
- The report's own disclaimer: a security review cannot prove the absence of vulnerabilities, and it
  recommends further review, deployment verification, monitoring and a public bug bounty before
  production use.
- Its conclusion recommends, before third-party capital: retaining M-06's regression and
  #61-preservation coverage, publishing the L-03 incident runbook, retaining the activation gate,
  and verifying deployment and source parity. Its M-06 section adds: verify that production
  deployments include merged remediation commit 566a9eb or an equivalent descendant.
  [`KNOWN_RISKS.md`](../KNOWN_RISKS.md) tracks each.
