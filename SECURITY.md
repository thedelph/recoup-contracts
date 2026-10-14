# Security policy

## Reporting a vulnerability

Report privately through GitHub: the **Security** tab of this repository, then **Report a
vulnerability**. Please do not open a public issue, post in Telegram, or disclose anywhere else
until a fix has shipped or 90 days have passed, whichever is sooner.

If you can see an exploit in progress, also email security@recoup.fi with "ACTIVE EXPLOIT" in the
subject.

A useful report includes:

- the affected contract and function;
- the impact;
- a proof of concept that runs on a fork of Base mainnet.

Recoup is maintained by one developer, with no on-call rota. What you can expect:

- an acknowledgement within 72 hours;
- a severity assessment within 7 days;
- updates while a fix is prepared, and credit when it ships unless you ask not to be named;
- payment within 15 days of a confirmed report.

## Rewards

Recoup is a small protocol with a small lending pool, and the rewards are sized to what is
actually at risk. They rise as capital is added to the pool.

| Severity | What counts | Reward (USDC) |
|---|---|---|
| Critical | Theft of, or a permanent freeze of, lender USDC or borrower bonds | 10% of funds at risk, minimum 100, maximum 500 |
| High | Theft of yield, a temporary freeze of exits, or broken liquidation or workout accounting | 100 to 250 |
| Medium | Griefing, or a wrong value that needs unusual but reachable conditions | 50 |
| Low | Any other real defect | Credit in this repository |

Funds at risk are measured on the live deployment at the block of the report, and are capped at
what the exploit could actually move. Bonds are valued at the NAV the `NAVOracle` holds at that
block. There is one reward per root cause, paid to the first valid report. Rewards are paid in USDC
on Base within 15 days of a confirmed report, up to the critical maximum.

## Scope

**In scope:** these contracts on Base mainnet (chain id 8453), at their deployed bytecode. Contracts
outside the external audit's scope are explicitly in scope; [`AUDITS.md`](AUDITS.md) lists what was
audited.

| Contract | Address |
|---|---|
| `NAVOracle` | 0xF18ed41cfC1d00A179Eea790a2A4C7d48365681d |
| `RiskParams` | 0xf273D492310B08ba02Afc427b103659112e19ACe |
| `CollateralVault` | 0x95d5442aA3E3FDeb13DD9158fB9eCD0A1777FC53 |
| `DirectCallAdapter` | 0x2a10A9f17024f98Ab9511F73f2473f82125Eb05f |
| `CreditManager` | 0x8E902D98Ef0b513613b42E3A0AA99b06bf28f748 |
| `TreasuryLiquiditySource` | 0x5dD8BB9A663ABDcad4a123c6684EC423a1ab0334 |
| `LenderPool` | 0x9085B96c079d8790D0A74043e2cfeB031C5d8Fb2 |
| `EpochHarvester` | 0x230A5bDECAb42dCb1f7d4850E47fb02B6F3345b6 |
| `LiquidationAuction` | 0x92E93BD303B1dcA297e69857711d7b77617c694F |
| `ReferralRegistry` | 0x947A94BA953E68a405527E0259bBd61Ff375a567 |
| Timelock (OpenZeppelin `TimelockController`) | 0x8357AA0899917755744B139b51c72A8AEE0301Bf |
| `ProtocolFeeSplitter` | 0xA905d06704451733Ea77889FD3ac9847dcD35177 |
| `CreditWiring` (library) | 0xbBd98f91088f09ABD9c1C6396b61623b7722C186 |
| `MintAttemptReceiver` (implementation) | 0xdc1D2a566baaFE3eDDDD2599A9d9eD964e953D33 |
| `BondDepositConsentGate` (owner of `CollateralVault`) | 0xF24235E22FC6c52F37512f6f330536c49f61da48 |
| `AdapterConsentGate` (owner of `DirectCallAdapter`) | 0x2A733afD666839998cfF09Ab5c18F5FA7746022C |

Every `MintAttemptReceiver` clone that `DirectCallAdapter` deploys is in scope too.

**Out of scope:**

- DexFi's contracts and API.
- USDC's own pause and blacklist behaviour. See [`USDC_RUNBOOK.md`](USDC_RUNBOOK.md).
- Anything already disclosed in [`KNOWN_RISKS.md`](KNOWN_RISKS.md), including the external
  review's two accepted-risk findings, L-02 (#61) and L-03 (#68). M-06 (#64) is fixed, so a way round
  its fix is in scope.
- The Base Sepolia test deployment.
- Issues that need a compromised owner, keeper or NAV confirmer key, or a compromised signer of the
  governance Safe.
- Gas optimisations, and the website, except where it could lead a user to sign something harmful.

## Rules

- Test only on a local fork. Never test against the live deployment or other users' positions.
- Do not move, freeze or destroy funds beyond what the proof of concept needs on a fork.
- A reward is not paid to anyone who exploited the issue on the live deployment, except under the
  Safe Harbor terms below.
- Rewards are paid at the maintainer's discretion within the table above.

## Whitehat Safe Harbor

Recoup has adopted the SEAL Whitehat Safe Harbor agreement (v3.0.0) on Base on 2026-10-14 (UTC),
transaction 0x878e333cbf74b1f9508b873ab7c33044799dd434995474f93530124ed5bcbf4b. The adoption is recorded in SEAL's Safe Harbor registry on Base,
0x326733493E143b8904716E7A64A9f4fb6A185a2c, under the governance Safe
0x06ac4Ad08474F9C86912009b8489b8d363d3B2D3, and the terms are held on chain by the agreement at
0xb0fFCb4b7a69d2116Ee9F5A1eB6c666b2fa9855C. Read them there with `getDetails()` before acting:
the agreement can be updated, and the terms in force when you act are the ones that apply.

During an active exploit, a whitehat may rescue funds from the contracts in scope under its terms:

- return everything rescued to the asset recovery address, the governance Safe
  0x06ac4Ad08474F9C86912009b8489b8d363d3B2D3, as promptly as you reasonably can, and notify
  security@recoup.fi or this repository's private report form if you cannot within six hours;
- you may act under a pseudonym; before any bounty is paid, the payout address you nominate is
  screened against the US (OFAC), UK, EU and UN sanctions lists;
- the bounty is 10% of the value returned, capped at 500 USD per whitehat and at 500 USD in total
  for one exploit, shared pro rata if several whitehats rescue funds. It is paid in USDC by Recoup
  after the return, within 15 days; it is never deducted from the rescued funds.

The full terms are the registered agreement and SEAL's framework at
https://frameworks.securityalliance.org/safe-harbor/overview/.
