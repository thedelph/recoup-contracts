# A reading guide for reviewers

Written for someone who has been handed this repo and an afternoon. It answers the questions a
bond issuer actually asks, in the order they tend to ask them, and points at the code and the tests
rather than asserting.

The one thing Recoup needs from DexFi is a single `addWhitelist` call on the custody adapter.
Everything below is really about what that call does and does not buy.

Start with [README.md](README.md) for the architecture and the security posture. This file is the
code-level tour.

## Suggested reading order

1. `src/adapters/DirectCallAdapter.sol` - the only Recoup address that ever touches a DexFi
   contract. Small, and if you only read one file, read this one.
2. `src/CollateralVault.sol` - accounting and the LTV rules. It is the only caller of the adapter.
3. `test/fork/CollateralVault.fork.t.sol` - the same thing running against your live contracts.
4. `src/Config.sol` - every parameter and every external address in one place. No magic numbers
   anywhere else.

Everything else (credit, harvest, liquidation, referrals) sits above this layer and never talks to
a DexFi contract directly.

## Where can your bonds go once they are in the adapter?

`DirectCallAdapter.transferBonds` (`src/adapters/DirectCallAdapter.sol:245`) is the only function
that moves a bond out of Recoup, and it is `onlyVault`. It has exactly three call sites, all in
`CollateralVault`, plus one owner-only break-glass on the adapter itself. That is the complete
list.

| Exit | Destination | What constrains it |
|---|---|---|
| `CollateralVault.withdrawBonds` (`src/CollateralVault.sol:267`) | `msg.sender`, the original depositor | Capped at that user's own balance; refused if it would push their post-withdrawal LTV past `MAX_LTV_BPS`; refused outright if the NAV oracle is stale |
| `CollateralVault.seize` (`src/CollateralVault.sol:307`) | the address the auction nominates | `msg.sender` must be the wired liquidation auction, and the position must actually be liquidatable |
| `CollateralVault.disposeTo` (`src/CollateralVault.sol:376`) | the address the auction nominates | `msg.sender` must be the wired liquidation auction. Deliberately not gated on liquidatability, because by this point the lot belongs to the auction and carries no debt, so that check would refuse it every time |
| `DirectCallAdapter.emergencyUnstake` (`src/adapters/DirectCallAdapter.sol:260`) | a governance address chosen by the owner | `onlyOwner`. Break-glass: it calls the farm's `emergencyWithdraw` and forfeits pending rewards, so it is a last resort rather than a convenience |

There is no function anywhere that lets an arbitrary caller move a bond, and no owner path that
sends bonds to an arbitrary address other than the break-glass in the last row. That last row is
named here rather than left to be found.

## Can Recoup sell or redeem your bonds?

No, and this is deliberate.

- **No redemption.** Nothing in `src/` calls a redeem or exit function on the fund. Grep for it.
  The interface Recoup consumes is enumerated in `src/interfaces/IDexFiFarm.sol` and
  `src/interfaces/IDexFiBond.sol`, and it is small: `deposit`, `withdraw`, `emergencyWithdraw`,
  `depositForAccount`, a few views, and `mint`.
- **No open-market sale.** Your transfer whitelist prevents it. That gate is yours and it keeps
  doing exactly what you built it for.
- **A liquidation is not a sale of the bond out of the fund.** It transfers the bond to a winning
  bidder who paid USDC for it. The bond changes holder; it never leaves the fund. Supply and AUM
  are unchanged, and if anything an auction is a new bid for bonds from someone who was not
  previously a buyer.
- **Bonds get stickier, not looser.** While a borrower has debt outstanding, `withdrawBonds`
  refuses any withdrawal that would push post-withdrawal LTV past the maximum. A bond backing a
  live loan is locked in the farm for the life of that loan.

## Who controls the adapter, and what can they do?

`Ownable`, owner set at construction. Today that is a single EOA, because the protocol is
pre-launch and holds no third-party funds. A timelock and a governance multisig go in before
go-live, and `test/Governance.t.sol` proves that flip is a plain `transferOwnership` with no
redeploy and no disturbance to live state.

This is stated plainly because Recoup also asks DexFi about *their* admin-key plans, and asking a
question you have not answered yourself is the one thing that would make that ask land badly.

What the owner can do: set the yield recipient (`:95`), set the harvester (`:125`), and call
`emergencyUnstake` (`:260`).

What the owner cannot do: `renounceOwnership` reverts (`:132`), so ownership can never be dropped
and the contract can never be orphaned. There is no path for the owner to move bonds to an
arbitrary address other than the break-glass above, and no upgrade path at all. These contracts
are immutable by choice.

## What is that standing `setApprovalForAll` in the constructor?

`src/adapters/DirectCallAdapter.sol:86` grants blanket approval over the adapter's bonds to **the
DexFi farm and nothing else**, so `stake()` can move units in. Worth stating the punchline: the
only address in the world with a standing approval over bonds held by Recoup is DexFi's own
contract.

There is no revoke. That is a known trade-off rather than an oversight: it sits inside the "treat
DexFi as mutable" assumption Recoup already carries, and `emergencyUnstake` is the mitigation.

## What happens if you revoke the whitelist later?

The answer is worse than you would guess, which is why it is raised here rather than left to be
discovered. It is tested in `test/WhitelistRevocation.t.sol`:

- Deposits stop immediately. Expected, and fine.
- **Existing collateral is stranded.** The farm stays whitelisted so bonds can still come back to
  the adapter, but the adapter cannot then pass them to a depositor, because neither side of that
  transfer is whitelisted. Users cannot exit.
- `emergencyUnstake` does not rescue it either, unless its destination is itself whitelisted
  (`test_emergencyUnstakeAlsoBlockedToNonWhitelistedDestination`, and the passing case beside it).

The mitigation is an integration agreement rather than code, which is why Recoup asks for either a
permanently whitelisted unwind address or notice before revocation.

## Why believe any of it works?

Run it. Nine integration tests execute against the **live** DexFi contracts on a Base mainnet fork,
fork-at-latest, no archive node needed:

```sh
RUN_FORK_TESTS=true forge test --match-contract Fork -vv
```

`test/fork/CollateralVault.fork.t.sol` is the one to read first. It confirms the configured
addresses really are your live contracts and behave as documented, shows that deposits revert
today at your whitelist gate (the current mainnet reality), and then impersonates a single
`addWhitelist([adapter])` and runs the entire lifecycle: deposit, stake, claim real streamed USDC,
unstake, withdraw. That test is the ask in executable form.

`test/fork/CreditCore.fork.t.sol` runs the whole self-repaying loan on the same fork, and
`test/fork/Liquidation.fork.t.sol` covers a lot filling at 82% of NAV and an unfilled one falling
through to the workout path.

There is also a live deployment on Base Sepolia against a mock DexFi stack, all verified, with
addresses in [`deployments/base-sepolia.json`](deployments/base-sepolia.json). The mocks mirror
your verified ABIs including the whitelist gate. The fork tests are the stronger evidence; the
testnet deployment is there if you would rather click around than run Foundry.

## The invariant suites, and why they might have been lying

Four suites, 21 invariants, fuzzed over randomised call sequences: `test/*.invariants.t.sol`. The
one worth reading is `invariant_everyLiveAuctionHasAReachableExit`, which asserts there is no state
in which all three of an auction's exits revert, because that state would be permanently stranded
collateral and only a fuzzer looking for it would ever find it.

The part worth knowing about how they are built: **an invariant suite can report green having
tested nothing.** Handler actions have to be wrapped in `try`, because most random call sequences
are meaningless and must not fail a run, so a fixture that can never reach the interesting state
still reports every invariant passing. Every suite here is therefore paired with a deterministic
`test_handlerCanReachEveryStateTheInvariantsCheck` that drives the sequence by hand and asserts the
handler's coverage counters actually moved. Both new ones were checked by breaking a handler action
on purpose and confirming the tripwire went red.

That is not a hypothetical. When the tripwire was added to `CreditManager.invariants.t.sol` on
2026-08-03 it failed immediately: the fixture wired the auction stub into the vault but not into
the manager, so a guard added by an earlier audit round had been reverting **every borrow**, and
seven invariants had been running against a protocol in which no debt ever existed. None of the
seven were wrong - re-run with debt reachable, they all still pass - but nothing had tested them.
It is written up here rather than quietly fixed because the distinction between "our invariants
pass" and "our invariants were exercised" is the one an auditor should care about, and this repo
would rather show you the machinery that caught it than the clean result.

## What has been reviewed

[AUDITS.md](AUDITS.md) has the round-by-round record, and the README explains the habits that came
out of it. The short version: every phase gets a multi-agent Solidity review before it merges, and
every fix round is itself re-audited, because four rounds running turned up regressions introduced
by the previous round's own fixes.

No external audit has been commissioned yet. The README says plainly where that sits relative to
third-party funds, and what is knowingly not mitigated in the meantime.

## Questions

Open an issue, or ask Chris directly in the group chat. If something here disagrees with the code,
the code is right and this file is a bug.
