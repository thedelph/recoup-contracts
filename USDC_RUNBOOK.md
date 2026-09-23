# USDC pause and blacklist runbook

This is the operational runbook the external review asked for in finding L-03 ("A paused or
blacklisting USDC shuts every bond door, because the farm pays its pending USDC inside the same
call", GitHub issue #68, Acknowledged / Accepted Risk; the review rates it Low, and KNOWN_RISKS.md
rates its two residuals Medium, conditional on a USDC pause). It says what each door of the protocol does
while Circle's USDC is paused or has blacklisted a Recoup address, what the operator does and in
what order, and what no one can do. It describes the source at commit f6893cb. It does not change
any mechanism; the residuals themselves are recorded in [KNOWN_RISKS.md](KNOWN_RISKS.md) under the
two entries dated 2026-09-21, and the corrected exits row is in [AUDITS.md](AUDITS.md).

Every behavioural claim below carries one of three evidence labels:

- **fork-executed**: run against the real Base USDC and the real DexFi farm in
  [`test/R64A1_RealFarmPausedUsdcFork.t.sol`](test/R64A1_RealFarmPausedUsdcFork.t.sol) (opt-in,
  not run by CI; the review reproduced it independently at block 51,641,633).
- **measured locally**: executed against the repository's mocks, as recorded in KNOWN_RISKS.md or a
  named test. The mocks pay farm rewards by minting, so they do not model the farm's reward transfer.
- **source-reviewed**: read from the Solidity, not executed. Treat these as expectations.

## 1. Scope and trigger

- **USDC pause.** Circle pauses the token contract. Every USDC transfer, `transferFrom` and approval
  reverts, whoever the parties are, until Circle unpauses. Per the review, Circle has never paused
  USDC. This is an external event no protocol participant can cause.
- **USDC blacklist.** Circle blacklists one address. Transfers to or from that address revert, and
  everything else keeps working. The address that matters most is `DirectCallAdapter`, because it is
  the account the DexFi farm pays.

The root cause is the same for both. The DexFi farm is MasterChef-style (see
[`src/interfaces/IDexFiFarm.sol`](src/interfaces/IDexFiFarm.sol)) and settles the adapter's whole
pending USDC reward inside every `deposit` and `withdraw`, which are the calls the adapter makes to
move bonds. The adapter's own onward sweep (`_trySweepUsdc`, a low-level call) is best-effort, but
the farm's transfer to the adapter happens inside the farm and nothing in Recoup wraps it. So once
the adapter has any pending reward, a paused token, or a blacklisted adapter, reverts the farm call
and the bond movement with it. The threshold is one second of accrual, not a large balance: on the
fork, 3 wei pending was enough.

Note on the source's own comments: the NatSpec on `stake` and `unstake` in
[`src/adapters/DirectCallAdapter.sol`](src/adapters/DirectCallAdapter.sol) still says a USDC pause or
blacklist "must never" block a deposit or an exit. That is true of the adapter's sweep only and is
not true of the bond movement. This runbook and KNOWN_RISKS.md describe the measured behaviour.

## 2. Door by door

"Pending" means `pendingShare` on the farm reads above zero for the adapter, which is the normal
state one second after any stake. "Another address" means a protocol contract other than the
adapter, or a user.

| Door | USDC paused | Adapter blacklisted | Another address blacklisted | Evidence |
| --- | --- | --- | --- | --- |
| Deposit bonds (`depositBonds`) | Reverts while anything is pending. Passes only with nothing pending (a first stake, or the block of a restake). | Reverts the same way. | Moves bonds only, so a USDC-blacklisted user can still deposit. A blacklisted yield recipient does not block it: the sweep fails softly and the amount is carried in `unreportedYield`. | Pause and adapter blacklist fork-executed; the rest source-reviewed |
| Withdraw bonds (`withdrawBonds`) | Reverts while anything is pending; reopened on the fork as soon as the token was unpaused. | Reverts the same way. | Moves bonds only; a USDC-blacklisted user can still withdraw. | Pause and adapter blacklist fork-executed; the rest source-reviewed |
| Mint (`depositETH`, through `mintBonds`) | Expected to revert: the bond mint drives the farm's deposit hook for the adapter, which settles pending USDC. | Expected to revert the same way. | Pays ETH, not USDC, so a user blacklist is not expected to matter. | Source-reviewed only |
| Borrow (`borrow`) | Reverts: it moves USDC from the liquidity source to the borrower. | Does not call the adapter, so it is expected to work, unless custody is insolvent after a hatch, when `borrow` refuses. | Reverts if the borrower, the `CreditManager` or the liquidity source (`LenderPool` or `TreasuryLiquiditySource`) is blacklisted. | Source-reviewed |
| Repay (`repay`, `repayFor`) | Both revert. | Unaffected; no adapter call. | A blacklisted borrower cannot `repay` from their own wallet; `repayFor` from any other wallet is the rescue path the source names for this case. A blacklisted `CreditManager` refuses both. | Pause measured locally (KNOWN_RISKS.md); the rest source-reviewed |
| Lender entry (`LenderPool.deposit`, `LenderPool.mint`) | Reverts. | Unaffected by the token; the operator pauses it (section 3). | Reverts for a blacklisted depositor or pool. | Source-reviewed |
| Lender exit (`LenderPool.withdraw`, `LenderPool.redeem`) | Reverts. | Unaffected. | The caller names the receiver; a blacklisted receiver reverts. | Source-reviewed |
| Withdrawal requests (`requestWithdrawal`, `cancelWithdrawalRequest`, `serviceWithdrawalRequest`) | Move shares and book a claim; no USDC moves, so they are expected to work. | Unaffected. | Unaffected. | Source-reviewed, not executed under a pause |
| Request claims (`LenderPool.claim`, `LenderPool.claimFor`) | Revert. The booked amount stays owed. | Unaffected. | Pays only the request's fixed receiver; a blacklisted receiver's claim waits and nobody can redirect it. | Source-reviewed |
| Epoch harvest (`harvest`) | Its farm claim sits in a try/catch, so a failed claim does not revert it alone. Paying an epoch moves USDC, so an epoch either declines or reverts. | The farm claim fails and is caught; the yield stays at the farm. | A blacklisted harvester makes the adapter's sweep fail softly (carried in `unreportedYield`) and cannot pay an epoch. | Source-reviewed |
| Manual harvest (`harvestYield`) | Reverts while anything is pending. | Reverts the same way (source-reviewed; the fork's blacklist case ran the two bond doors). | See `harvest`. | Pause fork-executed |
| Fee and lender-yield delivery (`flushProtocolFee`, `flushLenderYield`) | Revert; `harvest` only accrues these, so the amounts stay pending. | Unaffected. | A blacklisted fee wallet can be replaced with `setProtocolFeeWallet`; the old wallet's accrued amount stays payable to it. | Source-reviewed |
| Liquidation opening (`liquidate`, `start`) | Touch no token and run. | Run. | Run; the keeper's bounty is pull-based (`claimBounty`), so a blacklisted keeper can still liquidate. | Pause measured locally (KNOWN_RISKS.md) |
| Auction bids (`bid`) | Revert at the USDC pull. | The pull succeeds but the lot's `seize` unstakes through the farm, so a bid is expected to revert while anything is pending. | A blacklisted bidder cannot pay. | Pause measured locally; adapter case source-reviewed |
| Auction lapse and workout (`cancel`, `expireToWorkout`, `closeWorkout`) | Touch no token and run, on their normal clocks. | Run. | Run. | Pause measured locally (KNOWN_RISKS.md) |
| Workout payments (`workoutSettle`, `disposeWorkoutLot`) | `workoutSettle` reverts at its USDC pull; `disposeWorkoutLot` goes through `disposeTo` and the farm, so it is expected to revert while anything is pending. | `disposeWorkoutLot` as under a pause. | A blacklisted payer cannot settle. | `workoutSettle` measured locally; `disposeWorkoutLot` source-reviewed |
| Pull claims (`claimReward`, `claimBounty`, `claimSurplus`, `claimWorkoutYield`) | Revert; the amounts stay booked. | Unaffected. | Each pays a fixed payee; a blacklisted payee's amount waits, and the permissionless `claimRewardFor`, `claimBountyFor` and `claimSurplusFor` cannot redirect it. | Source-reviewed |
| Custody (`stake`, `unstake`, `claimYield`, `restakeLoose`) | Every one calls the farm's `deposit` or `withdraw` and reverts while anything is pending. `emergencyUnstake` (the farm's `emergencyWithdraw`) succeeded under the pause. | As under a pause. Whether `emergencyUnstake` succeeds with the adapter blacklisted was not executed. | A blacklisted yield recipient only parks the sweep. | Pause fork-executed; the rest source-reviewed |

What a user should expect while it lasts:

- **Borrowers.** No interest accrues, so debt does not grow. But no cure works: `repay` and
  `repayFor` move USDC, and `depositBonds` is shut by the farm. The NAV can still move, and a
  position that crosses the liquidation threshold can be liquidated and, six hours later, sent to a
  workout (section 4). Headroom held before the outage is the only protection.
- **Debt-free bond holders.** Bonds cannot leave while anything is pending. Nothing is lost; the
  exit reopens when the token does.
- **Lenders.** Deposits, exits and claims that move USDC wait. Requests can still be filed and
  serviced. Losses written down by a forced workout close during the outage fall on lenders.
- **Bidders and keepers.** Bids wait. Bounties and rewards stay booked for later collection.

## 3. What the operator does, in order

1. **Detect.** Signs: bond doors reverting with "Pausable: paused" or "Blacklistable: account is
   blacklisted" in the revert data; harvests declining; users reporting failed exits.
2. **Confirm on chain.** Read the USDC contract's paused() flag and isBlacklisted() for the adapter,
   `CreditManager`, `LenderPool`, `EpochHarvester`, `LiquidationAuction` and the fee wallet. Read
   `pendingShare` for the adapter, `stakedBalance`, `totalBondCount`, `custodyIsSolvent` and
   `unreportedYield`. Record the block number and every value before acting.
3. **Communicate** (section 5), before any owner action, and say which doors are shut.
4. **Stop new exposure, not cures.** Call `pause` on `CreditManager` (stops `borrow`),
   `CollateralVault` (stops `depositETH`) and `LenderPool` (stops `LenderPool.deposit` and
   `LenderPool.mint`). Do NOT call `setBondDepositsPaused`: `depositBonds` is the borrower's cure and
   should reopen by itself the moment the token allows. None of these pauses touches `repay`, bond
   withdrawal, lender exits, `liquidate` or the workout doors, by design.
5. **Decide on `emergencyUnstake`. The default under a pause is NOT to use it.** It is owner-only
   and protocol-wide. What it does, per the review and the source:
   - it forfeits every pending reward to the farm. It cannot be claimed first, because the claim is
     the call that reverts. The forfeited USDC was yield owed to the epoch split, not principal;
   - it moves every bond unit to one address and leaves `custodyIsSolvent` false. In that window
     `borrow`, `depositBonds` and `depositETH` refuse (`CustodyInsolvent`), `withdrawBonds` reverts
     inside the farm, and a liquidation opened in the window can only end in a workout whose forced
     close writes the debt down against lenders (measured locally in
     [`test/R57A01_HatchRepair.t.sol`](test/R57A01_HatchRepair.t.sol));
   - after `restakeLoose`, nothing is pending for that block only. Exits and cures sent in the same
     block as the restake can pass; one second later the doors shut again. Recoup has no mechanism to
     place a user's transaction in that block, so this is "where possible", not a promise.

   Use it only when a specific harm justifies a protocol-wide act: a cure-sensitive position that a
   same-block cure can save, or a blacklisted adapter that has to be replaced. The hatch destination
   is the adapter itself, so the units stay at the one whitelisted protocol address. A DexFi bond
   transfer needs a whitelisted party, so units sent to any other address can only come back to a
   whitelisted one (such as the adapter) and cost an extra transfer in the insolvent window. Send the
   restake as close to the hatch as the owner key allows, in one batch wherever the owner can batch.
   At f6893cb the owner is a single key; under the intended governance the adapter's owner is the
   timelock, so both calls would carry its delay (from the intended design, not executed).
6. **Blacklisted adapter: replace it.** Hatch-and-restake does not help durably, because the farm
   keeps paying the blacklisted address. The repair path `restakeLoose`'s NatSpec describes is written
   for a replaced farm; applying it to a blacklisted adapter on the same farm is the maintainer's reading, not a
   tested sequence: construct a new adapter on the same farm, have DexFi whitelist it first, hatch the old adapter straight into it with
   `emergencyUnstake`, call `restakeLoose` on the new adapter, then point both `CollateralVault` and
   `EpochHarvester` at it with `setCustodyAdapter`, in one governance batch. The vault refuses an
   incoming adapter that does not already hold the stake. An unwhitelisted repair adapter installs
   and then freezes every exit (measured locally in `test/R57A01_HatchRepair.t.sol`). This path was
   not fork-executed. USDC held at the blacklisted adapter stays frozen by Circle.
7. **Reconcile.** After any restake or repoint, confirm `stakedBalance` is at least `totalBondCount`
   and `custodyIsSolvent` reads true before reopening anything. Record the reward forfeited at the
   hatch (the `pendingShare` read in step 2, an upper bound: `IDexFiFarm` records that it can include
   an owner-written component the farm never pays) and any `unreportedYield`, which the next
   successful sweep reports.
8. **Return bonds.** Only the ledger decides who owns what. A restake credits nobody and cannot
   double-credit; each holder leaves through `withdrawBonds` once the doors reopen. No bond is ever
   handed out by the operator from a hatch destination.
9. **Resume.** When Circle unpauses or delists, the bond doors reopen with no action (fork-executed
   for `withdrawBonds`). Then run `harvest`, flush any parked legs (`flushLenderYield`,
   `flushProtocolFee`, and `flushYieldTo` if a recipient was parked), and call `unpause` on each
   contract paused in step 4 (owner-only by design). Publish a closing notice with what happened to
   any position that was liquidated or sent to a workout during the outage.

## 4. What cannot be done

- **No protocol lever stops the liquidation and workout clocks.** The six-hour auction, the 48-hour
  reset window and the fourteen-day workout keep running. With `pause` engaged on the credit manager,
  the pool and the vault, and bond deposits paused, `liquidate`, `expireToWorkout` and `closeWorkout`
  still succeed (measured locally, KNOWN_RISKS.md). Pausing them was not built: they are deliberately
  unpausable so a pause can never turn an underwater position into unrecoverable debt.
- **The one partial lever** is raising `liquidationThresholdBps` through `setRiskParams`, to its bound
  (5,800 bps per KNOWN_RISKS.md), which can make a position in a live auction healthy again so the
  permissionless `cancel` returns the lot. It reaches a NAV move of at most about 13.8 percent past
  the old threshold, reaches nothing once a workout is open, and in production sits behind the
  48-hour risk timelock against a six-hour auction.
- **An adapter-side try/catch does not isolate the farm.** The adapter's own sweep is already
  best-effort. The revert happens inside the farm's `deposit` or `withdraw`, which is the bond
  movement itself.
- **Per-position liveness does not exist.** `emergencyUnstake` is the only lever, it acts on every
  position at once, and it costs the pending reward and a window of insolvent custody.
- **Nothing makes a blacklisted payee's booked USDC go elsewhere.** Pull claims keep a blacklisted
  payee from blocking anyone else; they do not let anyone re-route that payee's money.
- **No USDC moves under a pause.** Recoup cannot repay, pay out, or settle on anyone's behalf until
  Circle lifts it.

What this is NOT: a loss by itself. No USDC is taken and no debt moves. The costs are the forfeited
reward if the hatch is used, and any liquidation or workout that the clocks complete while cures are
shut.

## 5. How users are told

Recoup's intent is to post a notice on the app and on the project's public channels as soon as step 2
confirms the event, naming the trigger (pause or blacklist, and which address), which doors are shut,
that repayments and collateral top-ups cannot be made, and that the liquidation clocks keep running.
A follow-up is posted before any `emergencyUnstake`, saying why and what it costs, and a closing
notice after resumption. No notice promises a reopening time, because only Circle controls it.

## 6. The Base Sepolia deployment cannot exercise this

The Base Sepolia deployment predates this source (see README.md and KNOWN_RISKS.md: no current-source
parity) and runs mock USDC, bonds and farm. The mock USDC in `test/mocks/MockUSDC.sol` has no pause
function, so a Circle pause cannot be reproduced there, and the mock farm pays rewards by minting,
which is why the local suite could not see this finding. Read on Base Sepolia on 2026-09-23, the
deployed mock USDC reverts a paused() call, and the deployed LenderPool and CollateralVault predate
their pause-related changes (the pool's pause() and the vault's bond-deposit switch are not exposed).
The only evidence against real Circle behaviour is the opt-in fork suite named above.
