// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {LtvMath} from "../src/LtvMath.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockCreditManager} from "./mocks/MockCreditManager.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice Randomised call sequences against the vault + adapter. The fuzzer
///         plays several actors (depositors, the auction, the owner, a yield
///         setter) in arbitrary order; the invariants below must hold after
///         every sequence.
contract VaultHandler is Test {
    CollateralVault public immutable vault;
    DirectCallAdapter public immutable adapter;
    MockBond public immutable bond;
    MockFarm public immutable farm;
    MockUSDC public immutable usdc;
    MockCreditManager public immutable credit;
    address public immutable auction;
    address public immutable admin;

    address[] public actors;
    uint256 public ghostTotalBondCount; // mirror of Σ vault.bondCount
    uint256 public ghostSeizedToWinners;
    /// @notice Bonds that came into existence through `depositETH` rather than out of an actor's
    ///         starting wallet.
    /// @dev **A conservation invariant has a fixture literal in it, and a new mint path is a change
    ///      to that literal.** `invariant_bondConservation` says `wallets + staked + winners ==
    ///      100_000 * actorCount`, which holds only while the *only* bonds in the system are the
    ///      ones this handler's constructor minted into wallets. `depositETH` mints new units
    ///      straight into the farm, so without this term the invariant goes red on the first ETH
    ///      deposit the campaign draws - and it would have gone red for the right reason, which is
    ///      why the term is added rather than the invariant weakened. It still says the vault
    ///      creates and destroys nothing: every unit is in a wallet, in the farm, or with a winner,
    ///      and the right-hand side now names both sources those units can have come from.
    uint256 public ghostMintedByEth;
    /// @notice Monotonic source for globally unique mock UUIDs and fresh attempt IDs.
    /// @dev Every successful attempt needs its own receiver and therefore its own
    ///      nonce-zero domain. Reusing the old literal `uuid: 1` would make the
    ///      hardened mock reject every ETH mint after the first one.
    /// @dev Deliberately `internal` and underscore-prefixed. A plainly-named public counter on a
    ///      handler is swept as a coverage ghost and must be read by an invariant or a tripwire,
    ///      and this one should not be: it is scratch state that records nothing worth asserting
    ///      on. The ETH-mint coverage it could be mistaken for is already carried by
    ///      `ethDepositsDone` and `ghostMintedByEth`, so naming it publicly would read as
    ///      coverage that is not there.
    uint256 internal _nextMintAttempt;

    /// @notice Coverage ghosts, distinct from the two mirrors above: those are
    ///         *quantities* and stay at zero whether an action never ran or ran and
    ///         moved nothing. These count occurrences. Every interesting action here is
    ///         wrapped in `try`, which it has to be - most random sequences are
    ///         meaningless and must not fail a run - so a fixture that could never reach
    ///         a seize would report four green invariants having exercised nothing.
    ///         `test_handlerCanReachEveryStateTheInvariantsCheck` asserts these.
    uint256 public depositsDone;
    /// @notice Deposits refused by the bond-deposit switch. **Not by the pause** - the two were
    ///         separated in audit round 25 finding 1, and the old name said the opposite
    ///         of what is now true, which is why it was renamed rather than left alone.
    uint256 public depositsRefusedByTheirOwnSwitch;
    uint256 public pauseToggles;
    /// @notice Flips of the third switch. Read by the reachability tripwire, like its siblings:
    ///         a counter no invariant or tripwire reads is the unread-coverage-ghost shape the
    ///         repository's documentation check looks for.
    uint256 public bondDepositToggles;
    /// @notice ETH deposits that landed, and ETH deposits the pause refused.
    /// @dev **Round 26 follow-up item 5 / round 28 item 6.** `togglePause`'s own note says the two
    ///      remaining `whenNotPaused` sites in the protocol are `CollateralVault.depositETH` and
    ///      `CreditManager.borrow`, and that "`depositETH` has no action in this handler". This is
    ///      that action. The second counter is the load-bearing one, for the reason
    ///      `depositsRefusedByTheirOwnSwitch` exists next door: a refusal that is swallowed is not
    ///      evidence the branch was reached, and both are read by
    ///      `test_handlerCanReachEveryStateTheInvariantsCheck`.
    uint256 public ethDepositsDone;
    uint256 public ethDepositsRefusedByThePause;
    uint256 public withdrawsDone;
    uint256 public withdrawsRefusedByLtv;
    uint256 public harvestsWithYield;
    /// @notice Flips of the USDC blacklist on the adapter's yield recipient.
    /// @dev Read by `test_handlerCanReachEveryStateTheInvariantsCheck`, which drives a blocked
    ///      harvest and asserts `unreportedYield` actually became non-zero. The counter alone
    ///      would only say the action ran; the state it is here to reach is the carry.
    uint256 public yieldRecipientBlockToggles;
    uint256 public seizesDone;
    uint256 public reassignsDone;

    constructor(
        CollateralVault vault_,
        DirectCallAdapter adapter_,
        MockBond bond_,
        MockFarm farm_,
        MockUSDC usdc_,
        MockCreditManager credit_,
        address auction_,
        address admin_
    ) {
        vault = vault_;
        adapter = adapter_;
        bond = bond_;
        farm = farm_;
        usdc = usdc_;
        credit = credit_;
        auction = auction_;
        admin = admin_;
        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(a);
            bond.mint(a, 100_000);
            vm.prank(a);
            bond.setApprovalForAll(address(vault), true);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev **The zero check has to come before `bound`, not after it.** It used to read
    ///      `bound(amount, 1, bond.bondBalance(a))` with `if (amount == 0) return;` underneath,
    ///      and once an actor had deposited everything they held that `bound` was called with a
    ///      max of 0 against a min of 1. `StdUtils.bound` reverts on that, which kills the whole
    ///      handler frame - so `fail_on_revert = false` discarded the call, and the guard written
    ///      for exactly this case sat one line below something that could never reach it.
    ///      Mirrors `withdraw` below, which has always read the balance first.
    /// @dev **The `try` is what lets a switch-flipping action exist at all, and it is a
    ///      prerequisite rather than a tidy-up.** This call used to be bare, which was correct
    ///      while nothing in the handler could make it revert. The moment a switch over
    ///      `depositBonds` could be on, a bare call here kills the frame and
    ///      `invariant_theHandlerNeverDropsAFrame` fires. **Measured on this fixture before the
    ///      `try` went in: 7,779 of 128,000 frames revert, 6.08%, every one of them this action,
    ///      and the frame guard goes red on the two-call sequence `togglePause` then `deposit`.**
    ///
    ///      **That measurement is now a historical one, and the reason the `try` is needed has
    ///      moved.** `depositBonds` came off `whenNotPaused` in the round-27 remediation, so
    ///      `togglePause` no longer makes this revert at all; `toggleBondDeposits` does. The `try`
    ///      is load-bearing for the same structural reason and against a different action, which
    ///      is exactly the kind of change that leaves a correct guard sitting behind a stale
    ///      justification - so the justification is restated rather than left.
    ///      With it: 0 reverts, 0 discards.
    ///
    ///      The refusal is counted rather than swallowed, and typed rather than bare, for the
    ///      reason `withdraw` states below: anything other than `BondDepositsArePaused` reaching
    ///      here is a
    ///      fixture fault, and a bare `catch {}` would hide it for as long as the suite exists.
    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 heldOutside = bond.bondBalance(a);
        if (heldOutside == 0) return;
        amount = bound(amount, 1, heldOutside);
        vm.prank(a);
        try vault.depositBonds(amount) {
            ghostTotalBondCount += amount;
            ++depositsDone;
        } catch (bytes memory err) {
            assertEq(bytes4(err), CollateralVault.BondDepositsArePaused.selector, "unexpected depositBonds revert");
            ++depositsRefusedByTheirOwnSwitch;
        }
    }

    /// @notice The other deposit door: DexFi's signed ETH mint, which auto-stakes for the adapter.
    /// @dev **Round 26 follow-up item 5, closed as round 28 item 6: this door had no campaign
    ///      standing under it in the paused state, because it had no action in this handler at
    ///      all.** It is one of exactly two `whenNotPaused` sites left in `src/`, and unlike its
    ///      sibling `depositBonds` - which came off the pause in the round-27 remediation because
    ///      it is the borrower's cure - this one stays behind it on purpose: it sends ETH into
    ///      DexFi's mint, which is new exposure rather than a way out of one.
    ///
    ///      **The typed `catch` is the point of the action, not a tidy-up.** `whenNotPaused` is the
    ///      first modifier on `depositETH`, so with the switch on there is exactly one legal answer
    ///      and anything else reaching here is a fixture fault a bare `catch {}` would hide for as
    ///      long as this suite exists - the rule `withdraw` and `deposit` already state. The `try`
    ///      itself is load-bearing for the reason `deposit`'s docstring gives: without it a paused
    ///      frame dies and `invariant_theHandlerNeverDropsAFrame` fires.
    ///
    ///      **The mint payload is built here rather than passed in**, because every field of it is
    ///      a constraint the adapter checks and a fuzzed one would only ever produce reverts the
    ///      typed `catch` would then have to tolerate: `receiver` must be the beneficiary-bound
    ///      prediction, both signed and live receiver nonces must be zero, `msg.value` must equal
    ///      `paymentAmount` exactly, and the minted count must match `amountNfts`. What is fuzzed is
    ///      the only thing that changes the protocol's state: which actor deposits and how many
    ///      units.
    ///
    ///      The deadline is a year out rather than an hour, because nothing in this handler warps
    ///      time today and a fixture that depends on that staying true is one `skip` away from
    ///      failing on `DeadlineExpired` in an unrelated round.
    function depositEth(uint256 actorSeed, uint256 units) external {
        address a = _actor(actorSeed);
        units = bound(units, 1, 500);
        // 0.001 ETH a unit. Any strictly positive price does; what matters is that `msg.value` and
        // `paymentAmount` are the same number, which the adapter requires exactly.
        uint256 payment = units * 1e15;
        uint256 attempt = ++_nextMintAttempt;
        bytes32 attemptId = bytes32(attempt);
        bytes memory mintData = abi.encode(
            IDexFiBond.MintDataInput({
                uuid: attempt,
                nonce: 0,
                receiver: adapter.predictMintReceiver(a, attemptId),
                amountNfts: units,
                paymentAmount: payment,
                deadline: block.timestamp + 365 days,
                signature: ""
            })
        );

        // `vm.deal` before `vm.prank`, not after. Both orderings happen to work here because a
        // cheatcode call does not spend a single-shot prank, but the ordering rule this file has
        // twice been bitten by is "nothing between the prank and the call", and writing it the
        // other way round invites the next reader to put a `paused()` read there.
        vm.deal(a, payment);
        vm.prank(a);
        try vault.depositETH{value: payment}(attemptId, mintData) {
            ghostTotalBondCount += units;
            ghostMintedByEth += units;
            ++ethDepositsDone;
        } catch (bytes memory err) {
            assertEq(bytes4(err), Pausable.EnforcedPause.selector, "unexpected depositETH revert");
            ++ethDepositsRefusedByThePause;
        }
    }

    /// @notice Flip the vault's pause switch, both ways.
    /// @dev **The recorded fact this closes: the string `pause` appeared zero times in all six
    ///      invariant suites, so every invariant in this repo covered the unpaused state only.**
    ///      Stated against the suites rather than against a count on purpose - "how many
    ///      invariants" has five different correct answers here depending on the basis, and the
    ///      claim being closed is about coverage, not arithmetic. Pause is one of exactly **two**
    ///      remaining `whenNotPaused` sites in the protocol - `CollateralVault.depositETH` and
    ///      `CreditManager.borrow` - and it is an operating mode the protocol is expected to sit
    ///      in during an incident, not a corner. **It was three until the deposit gate was split**;
    ///      `depositBonds` now answers to `toggleBondDeposits` below.
    ///
    ///      **Measured rather than argued**: a probe invariant asserting `!vault.paused()` goes red
    ///      on the very first `togglePause` the campaign draws, so all five invariants declared in
    ///      this file are evaluated in the paused state as well as out of it. A second probe
    ///      asserting `depositsRefusedByTheirOwnSwitch == 0` goes red too, so the refusal itself is
    ///      reached and not merely possible.
    ///
    ///      🟩 **Both remaining sites are covered as of round 28 item 6.** This paragraph used to
    ///      end "the other two `whenNotPaused` sites still have no campaign standing under them:
    ///      `depositETH` has no action in this handler, and `CreditManager.invariants.t.sol` has no
    ///      pause action at all". `depositEth` above is the first of those; `CreditHandler
    ///      .togglePause` is the second. Same measurement in both places: a probe invariant
    ///      asserting the door was never refused by the pause goes red on a campaign, and the
    ///      shrunken counterexample is the toggle itself.
    ///
    ///      **Reads `paused()` before the prank, and that ordering is the whole of the bug this
    ///      action shipped with for one measurement.** `vm.prank` is spent on the very next call
    ///      including a staticcall, so `vm.prank(admin); if (vault.paused())` spends the prank on
    ///      the read and sends `pause()` from the handler, which is not the owner. Measured: 15,967
    ///      of 15,967 calls reverted `OwnableUnauthorizedAccount` and the frame guard went red on a
    ///      single `togglePause`. The failure looks like a plausible access-control revert rather
    ///      than a tooling error, which is exactly why this repo has catalogued it twice before.
    ///
    ///      **No `try`, on purpose.** The branch above picks whichever of the two calls is legal
    ///      from the state it just read, and `admin` is the owner, so this cannot revert. If it
    ///      ever does, the frame guard should say so rather than a `catch` swallowing it.
    function togglePause() external {
        bool isPaused = vault.paused();
        vm.prank(admin);
        if (isPaused) vault.unpause();
        else vault.pause();
        ++pauseToggles;
    }

    /// @dev The third switch, added when the deposit gate was split off the pause (audit round 25,
    ///      finding 1). It needs its own action rather than riding on `togglePause`, because the
    ///      entire point of the split is that the two move **independently** - a handler that
    ///      flipped both together would leave the campaign unable to reach the three mixed states,
    ///      which are exactly the ones an operator will be in during an incident.
    ///
    ///      Same prank-before-read ordering as the sibling above, and for the same reason: the
    ///      `bondDepositsPaused()` read is a staticcall and would eat the prank.
    function toggleBondDeposits() external {
        bool isShut = vault.bondDepositsPaused();
        vm.prank(admin);
        vault.setBondDepositsPaused(!isShut);
        ++bondDepositToggles;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        // Debt may make this revert (LTV rule) - both outcomes are valid;
        // the invariants must hold either way.
        vm.prank(a);
        try vault.withdrawBonds(amount) {
            ghostTotalBondCount -= amount;
            ++withdrawsDone;
        } catch (bytes memory err) {
            // Typed rather than swallowed: the LTV refusal is the behaviour under test
            // and needs counting, and anything else reaching here is a fixture fault
            // that a bare `catch {}` would hide for as long as the suite exists.
            assertEq(
                bytes4(err),
                CollateralVault.WithdrawalExceedsMaxLtv.selector,
                "unexpected withdrawBonds revert"
            );
            ++withdrawsRefusedByLtv;
        }
    }

    function setDebt(uint256 actorSeed, uint256 debt) external {
        credit.setDebt(_actor(actorSeed), bound(debt, 0, 1_000_000e6));
    }

    function accrueYield(uint256 amount) external {
        farm.setPendingYield(address(adapter), bound(amount, 0, 1_000_000e6));
    }

    function harvest() external {
        vm.prank(admin);
        uint256 got = vault.harvestYield();
        // A harvest of nothing exercises none of the adapter's USDC path, so it is not
        // evidence the path works. Only a non-zero one counts.
        if (got != 0) ++harvestsWithYield;
    }

    /// @notice Blacklist the adapter's yield recipient, and lift it again.
    /// @dev **Without this action the adapter's USDC path is only ever exercised in its happy
    ///      case, and `invariant_adapterHoldsNothingAtRest` was green for that reason rather
    ///      than because the protocol has the property.** Audit round 34 found that no fuzz
    ///      HANDLER in this repository could block a USDC recipient, so no campaign could
    ///      reach either of the two states the adapter is *designed* to hold USDC in: the
    ///      `unreportedYield` carry left behind when `_trySweepUsdc` cannot go through, and
    ///      the round-22 `owedToRecipient` park. The old assertion `balanceOf(adapter) == 0`
    ///      is false about the protocol and true about the fixture, which is the worst pair.
    ///
    ///      **Stated precisely, because the looser form is wrong.** `setBlocked` does appear in
    ///      an invariant *file*: `LiquidationAuction.invariants.t.sol` uses it inside
    ///      `test_R23_theParkedTermOfThisIdentityIsReachableAndTheHandlerCannotReachIt`, whose
    ///      own name says what it is - a deterministic reachability test, not a fuzz action. The
    ///      property that held before this action is the narrower one: no *handler* anywhere
    ///      could block a recipient, so nothing the random walk could draw ever produced the
    ///      state. "Zero invariant suites" would have been a claim about a grep.
    ///
    ///      `MockUSDC.blocked` reverts in `_update`, which is real USDC's blacklist shape and
    ///      the one `_trySweepUsdc`'s raw `call` exists to tolerate, so the block reddens the
    ///      accounting invariant and not the campaign: every collateral path stays open, which
    ///      is the property the best-effort sweep was written for.
    ///
    ///      Both directions on purpose. A block that could never be lifted would leave the
    ///      swept branch of `_settleFarmPayout` unreachable after the first flip, and the
    ///      identity has to hold on the way back down as well as on the way up.
    function toggleYieldRecipientBlock() external {
        bool next = !usdc.blocked(adapter.yieldRecipient());
        usdc.setBlocked(adapter.yieldRecipient(), next);
        ++yieldRecipientBlockToggles;
    }

    /// @dev Asserts the gate and its complement together: a seize must succeed exactly
    ///      when the position is liquidatable and fail exactly when it is not. Written
    ///      as one action rather than two tests because a guard and the states it is
    ///      supposed to admit are the classic pair that both pass in isolation while
    ///      being mutually unsatisfiable.
    function seize(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        address winner = makeAddr("winner");
        bool liquidatable = _liquidatable(a, held);

        vm.prank(auction);
        try vault.seize(a, winner) returns (uint256 got) {
            assertTrue(liquidatable || held == 0, "seized a position that was not liquidatable");
            assertEq(got, held, "seize must move the whole position");
            ghostTotalBondCount -= held;
            ghostSeizedToWinners += held;
            if (held != 0) ++seizesDone;
        } catch {
            assertFalse(liquidatable && held != 0, "refused a genuinely liquidatable position");
        }
    }

    /// @dev The workout path. Moves the claim to the auction and nothing else, so the
    ///      bond-conservation invariants must be completely indifferent to it.
    function reassign(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 held = vault.bondCount(a);
        if (a == auction) return;
        bool liquidatable = _liquidatable(a, held);

        vm.prank(auction);
        try vault.reassign(a, auction) returns (uint256 moved) {
            assertTrue(liquidatable || held == 0, "reassigned a position that was not liquidatable");
            assertEq(moved, held, "reassign must move the whole claim");
            if (held != 0) ++reassignsDone;
        } catch {
            assertFalse(liquidatable && held != 0, "refused a genuinely liquidatable position");
        }
    }

    /// @dev The threshold is read off the vault's own `RiskParams` on every call rather than
    ///      inlined, so this mirror cannot disagree with the contract it is predicting - not even
    ///      for one handler frame after a parameter move.
    function _liquidatable(address who, uint256 held) internal view returns (bool) {
        return LtvMath.exceedsLtv(
            credit.currentDebtOf(who),
            LtvMath.collateralValue(held, vault.navOracle().navPerBond()),
            vault.riskParams().liquidationThresholdBps()
        );
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev The auction is counted too. A workout reassigns a defaulted position's
    ///      claim to it, and those bonds are still staked and still collateral - so
    ///      leaving it out would not just under-count, it would make the vault look
    ///      insolvent the moment anything expired.
    function sumBondCounts() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.bondCount(actors[i]);
        }
        sum += vault.bondCount(auction);
    }
}

contract CollateralVaultInvariants is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;

    VaultHandler internal handler;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    MockBond internal bond;
    MockFarm internal farm;
    MockUSDC internal usdc;
    RiskParams internal riskParams;
    address internal riskParamsOwner;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return riskParamsOwner;
    }

    function setUp() public {
        address admin = makeAddr("admin");
        riskParamsOwner = admin;
        MockLiquidationAuction auctionMock = new MockLiquidationAuction();
        address auction = address(auctionMock);
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        MockNavOracle oracle = new MockNavOracle(NAV);
        MockCreditManager credit = new MockCreditManager();

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)),
            IDexFiFarm(address(farm)),
            usdc,
            address(vault),
            admin,
            makeAddr("treasury")
        );
        credit.setVault(address(vault)); // setCreditManager checks the binding back
        auctionMock.setVault(address(vault));
        // Audit round 20: both setters also check the risk authority agrees with the vault's.
        credit.setRiskParams(address(riskParams));
        auctionMock.setRiskParams(address(riskParams));
        // Audit round 21: and that the NAV feed does too. Read off the vault rather than off
        // the local, because the vault's answer is the anchor the guards compare against.
        credit.setNavOracle(address(vault.navOracle()));
        auctionMock.setNavOracle(address(vault.navOracle()));
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(auction);
        vm.stopPrank();
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        handler = new VaultHandler(vault, adapter, bond, farm, usdc, credit, auction, admin);
        targetContract(address(handler));
    }

    /// Vault accounting always equals what is actually staked in the farm.
    /// @notice No handler call may revert. Every action in this handler wraps its interesting call
    ///         in `try`, or guards it, so a handler *frame* that dies is a fixture fault rather
    ///         than a meaningless random sequence.
    /// @dev **Added to all five suites at once, because the bug that prompted it was found in one
    ///      and existed in three.** `LiquidationAuction.invariants.t.sol` opened auctions at a
    ///      healthy rate and rolled every one of them back, for three audit rounds, because a
    ///      statement after the `try` reverted and `fail_on_revert = false` discards a reverting
    ///      frame. Nothing inside a handler can detect that - the ghost that would record it dies
    ///      with the frame. Only the runner, counting frames from outside, can.
    ///
    ///      Deterministic: a property of the handler's code rather than of the random walk, so it
    ///      cannot flake the way a per-run reachability floor does.
    ///
    ///      Empty body on purpose. The assertion is the config line, enforced by the runner. The
    ///      global `fail_on_revert = false` in `foundry.toml` stays correct for every other
    ///      invariant here and is what lets the `try`/`catch` idiom work at all.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    function invariant_accountingMatchesFarmStake() public view {
        (uint256 staked,) = farm.userInfo(address(adapter));
        assertEq(staked, handler.sumBondCounts(), "sum(bondCount) == farm stake");
        assertEq(staked, handler.ghostTotalBondCount(), "ghost mirror agrees");
    }

    /// The adapter holds no loose bonds, and the USDC it holds is exactly what it is accounted
    /// to hold - nothing more and nothing less.
    /// @dev **This assertion used to be `balanceOf(adapter) == 0` and that was FALSE about the
    ///      protocol.** `DirectCallAdapter` deliberately holds USDC at rest in two designed
    ///      states: the `unreportedYield` carry `_settleFarmPayout` writes when a best-effort
    ///      sweep cannot go through, and the round-22 `owedToRecipient` / `totalOwedToRecipients`
    ///      park that `changeYieldRecipient` writes when the outgoing recipient cannot be paid.
    ///      Both exist precisely so a blocked recipient cannot brick a collateral exit, so an
    ///      invariant forbidding them contradicts the mechanism two other comments in this repo
    ///      defend.
    ///
    ///      **It was green for a fixture reason, not a protocol reason, and audit round 34 found
    ///      the reason.** No fuzz handler anywhere in this repository could block a USDC
    ///      recipient - `MockUSDC.setBlocked` reached an invariant file only from a
    ///      deterministic reachability test, never from a handler action - so neither designed
    ///      state was reachable and a false statement passed 256 runs. `toggleYieldRecipientBlock`
    ///      on the handler is what makes it reachable, and it ships in the same commit as this
    ///      line on purpose: **the assertion and the action are one change.** Landing the stronger
    ///      identity without the action would leave it exactly as unreached as the weak one, which
    ///      is the shape that produced the original defect.
    ///
    ///      MEASURED, this fixture, unseeded:
    ///        - blocking action + old assertion: RED in 6 calls, shrunk to 3, `no USDC at rest:
    ///          1 != 0`;
    ///        - blocking action + this assertion: green at the production 256 runs x 500 depth;
    ///        - this assertion falsified on demand: a temporary handler action donating USDC
    ///          straight to the adapter takes it RED again, so it is a real identity rather than
    ///          a restatement of the balance.
    function invariant_adapterHoldsNothingAtRest() public view {
        assertEq(
            usdc.balanceOf(address(adapter)),
            adapter.totalOwedToRecipients() + adapter.unreportedYield(),
            "USDC at rest must be exactly the park plus the carried unreported yield"
        );
        assertEq(bond.bondBalance(address(adapter)), 0, "no loose bonds");
    }

    /// Bond units are conserved: everything minted is in wallets, the farm, or
    /// with auction winners - nothing is created or destroyed by the vault.
    /// @dev **The right-hand side gained a term in round 28 and did not get weaker.** It used to be
    ///      the bare literal `100_000 * actorCount`, which was the whole supply only while the sole
    ///      way bonds entered the system was the handler's constructor minting them into wallets.
    ///      `depositEth` mints new units through DexFi's signed mint straight into the farm, so the
    ///      identity now names both sources. `ghostMintedByEth` is written only inside that action's
    ///      success branch, so a mint that reverted contributes nothing and the invariant still
    ///      fails on a unit that appears from anywhere else.
    function invariant_bondConservation() public view {
        uint256 inWallets;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            inWallets += bond.bondBalance(handler.actors(i));
        }
        (uint256 staked,) = farm.userInfo(address(adapter));
        uint256 winners = handler.ghostSeizedToWinners();
        assertEq(
            inWallets + staked + winners,
            100_000 * handler.actorCount() + handler.ghostMintedByEth(),
            "minted == wallets + staked + seized"
        );
    }

    /// The vault never accumulates bonds itself (custody is farm-side only).
    function invariant_vaultHoldsNoBonds() public view {
        assertEq(bond.bondBalance(address(vault)), 0, "vault holds no bonds");
    }

    /// @notice Proves the fixture above is not vacuous.
    /// @dev The interesting handler actions are wrapped in `try`, which they have to be -
    ///      most random call sequences are meaningless and must not fail a run. The cost
    ///      is that a handler which could never reach a seize would still report four
    ///      green invariants, having exercised nothing. Two of the four are worse than
    ///      merely unexercised without it: `invariant_bondConservation`'s `winners` term
    ///      is only non-zero after a seize, and the auction term in `sumBondCounts()` is
    ///      only non-zero after a reassign, so both reduce to a simpler identity that
    ///      cannot fail.
    ///
    ///      This drives the handler deterministically through every state the invariants
    ///      are supposed to be checking, and asserts each counter moved. It is a normal
    ///      test rather than `afterInvariant` on purpose: `afterInvariant` fires once per
    ///      run against counters that reset each run, so it would demand that all of
    ///      these behaviours occur in *every* random 500-call sequence, and fail on the
    ///      first unlucky one.
    ///
    ///      NAV is fixed at `NAV` in this fixture and there is no `moveNav` action, so
    ///      liquidatability comes only from `setDebt`. That is why the debt figures below
    ///      are derived from the bond counts rather than picked round - and, since the LTV
    ///      ceiling and the liquidation threshold became settable storage, derived through
    ///      the fixture rather than written out. A literal here would sit on whichever side
    ///      of the line the launch values happened to put it, and this test asserts *which
    ///      branch was taken*: a stale figure would not fail, it would silently stop
    ///      exercising the guard it was chosen to exercise. It already had: the percentages
    ///      this comment used to quote were the pre-2026-08-07 parameters, and the step
    ///      described as sitting inside the ceiling was over it.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        // actor0 stakes 1,000 bonds - $25,150 of collateral at 25.15e8.
        handler.deposit(0, 1_000);
        assertEq(handler.ghostTotalBondCount(), 1_000, "deposits must reach the farm");

        // A debt-free withdrawal, which the LTV rule lets through untouched.
        handler.withdraw(0, 100);
        assertEq(handler.withdrawsDone(), 1, "withdrawals must be possible");

        // 900 bonds left. Debt set to exactly what 900 bonds may carry, so the position is
        // inside the ceiling where it stands and releasing 300 more - leaving 600 bonds to
        // carry the same debt - must be refused, whatever the ceiling currently is.
        handler.setDebt(0, _maxBorrow(900, NAV));
        handler.withdraw(0, 300);
        assertEq(handler.withdrawsRefusedByLtv(), 1, "the LTV withdrawal guard was never exercised");
        assertEq(handler.withdrawsDone(), 1, "a withdrawal that breaches max LTV was allowed");

        // Yield has to actually flow, or the adapter's USDC path goes unchecked and
        // `invariant_adapterHoldsNothingAtRest` proves nothing about it.
        handler.accrueYield(500e6);
        handler.harvest();
        assertEq(handler.harvestsWithYield(), 1, "harvested yield must be reachable");

        // **The blocked-recipient carry, which no campaign in this repository could reach until
        // audit round 34.** `invariant_adapterHoldsNothingAtRest` names `unreportedYield` on its
        // right-hand side, so a run in which that term is always zero is checking a weaker
        // statement than the one written down - the exact shape that let the old
        // `balanceOf(adapter) == 0` stand for rounds while being false about the protocol.
        //
        // The counter is asserted *and* the state is, deliberately. `yieldRecipientBlockToggles`
        // alone would only say the action ran; a blocked harvest that swept anyway would satisfy
        // it and leave the carry term at zero. So the assertion below is on the adapter's own
        // storage, and the harvest is driven through the block rather than around it.
        handler.toggleYieldRecipientBlock();
        assertEq(handler.yieldRecipientBlockToggles(), 1, "the USDC blacklist must be reachable");
        handler.accrueYield(250e6);
        handler.harvest();
        assertGt(adapter.unreportedYield(), 0, "a blocked sweep must leave a carry to invariant on");
        assertEq(
            usdc.balanceOf(address(adapter)),
            adapter.totalOwedToRecipients() + adapter.unreportedYield(),
            "the accounted identity must hold while the carry is non-zero"
        );

        // And back down, or the swept branch of `_settleFarmPayout` is unreachable after the
        // first flip and the identity is only ever checked in one direction.
        handler.toggleYieldRecipientBlock();
        assertEq(handler.yieldRecipientBlockToggles(), 2, "the blacklist must be liftable");
        handler.accrueYield(1e6);
        handler.harvest();
        assertEq(adapter.unreportedYield(), 0, "lifting the block must let the carry sweep out");

        // The smallest debt past the liquidation threshold on 900 bonds.
        handler.setDebt(0, _debtAtThreshold(900, NAV) + 1);
        handler.seize(0);
        assertEq(handler.seizesDone(), 1, "seizure must be reachable");
        assertEq(handler.ghostSeizedToWinners(), 900, "the whole position must move to the winner");

        // The workout path, on a second actor, so the seized one is not reused.
        handler.deposit(1, 1_000);
        handler.setDebt(1, _debtAtThreshold(1_000, NAV) + 1);
        handler.reassign(1);
        assertEq(handler.reassignsDone(), 1, "the workout reassignment must be reachable");
        assertEq(vault.bondCount(handler.auction()), 1_000, "the claim must land on the auction");

        // **The paused operating mode.** Until round-26 remediation the string `pause` appeared
        // zero times in all six invariant suites, so all of this repo's invariants covered the
        // unpaused state only. Both directions are driven here, and the refusal is asserted on the
        // handler's own counter rather than on `vm.expectRevert`, so this is evidence the campaign
        // can stand in the paused state rather than evidence the modifier exists.
        //
        // **What changed when the deposit gate was split off the pause** (audit round 25,
        // finding 1): `togglePause` no longer refuses a deposit at all, so the first half below now
        // asserts the *opposite* of what it used to. That is the fix, and it is asserted here
        // rather than only in `PausedMode.t.sol` because this file is where a future round will
        // look to find out what the campaign can reach.
        assertEq(handler.depositsDone(), 2, "deposits must have been reachable while unpaused");
        handler.togglePause();
        assertTrue(vault.paused(), "the toggle must reach the switch");
        handler.deposit(2, 1_000);
        assertEq(handler.depositsDone(), 3, "a paused vault must STILL take a deposit - it is the cure");
        assertEq(handler.depositsRefusedByTheirOwnSwitch(), 0, "and refuse nothing on the pause flag");

        // The third switch, which is the one that does refuse, driven independently of the pause.
        handler.toggleBondDeposits();
        assertTrue(vault.bondDepositsPaused(), "the third toggle must reach its own switch");
        assertTrue(vault.paused(), "and must not have disturbed the pause flag");
        handler.deposit(2, 1_000);
        assertEq(handler.depositsRefusedByTheirOwnSwitch(), 1, "the bond-deposit switch must refuse");
        assertEq(handler.depositsDone(), 3, "and must not take the deposit");

        handler.toggleBondDeposits();
        assertFalse(vault.bondDepositsPaused(), "the third toggle must come back the other way");

        // **The other door, and the one the pause DOES shut** - round 26 follow-up item 5, closed as
        // round 28 item 6. `depositETH` is still `whenNotPaused` on purpose: it sends ETH into
        // DexFi's mint, so it is new exposure rather than the borrower's way out of one, which is
        // the distinction the round-27 split drew. Driven while the pause is still on, so this is
        // the refusal rather than a claim about it.
        assertTrue(vault.paused(), "premise: the pause is still on");
        handler.depositEth(3, 40);
        assertEq(handler.ethDepositsDone(), 0, "an ETH deposit landed against a paused vault");
        assertEq(handler.ethDepositsRefusedByThePause(), 1, "the ETH-deposit pause refusal was never exercised");

        handler.togglePause();
        assertFalse(vault.paused(), "the toggle must come back the other way");
        handler.deposit(2, 1_000);
        assertEq(handler.depositsDone(), 4, "reopening must let deposits through again");
        assertEq(handler.pauseToggles(), 2, "both directions of the switch must be reachable");
        assertEq(handler.bondDepositToggles(), 2, "and both directions of the third one");

        // And the same door open again, which is what makes the refusal above evidence about the
        // pause rather than about a mint payload this fixture can never satisfy. The new bonds are
        // minted into the farm, never into a wallet, which is why `invariant_bondConservation`
        // needed a term for them rather than a looser identity.
        uint256 stakedBefore = handler.ghostTotalBondCount();
        handler.depositEth(3, 40);
        assertEq(handler.ethDepositsDone(), 1, "an ETH deposit must be possible while unpaused");
        assertEq(handler.ghostMintedByEth(), 40, "the ETH mint must be counted as new supply");
        assertEq(handler.ghostTotalBondCount(), stakedBefore + 40, "and must reach the vault's books");
        (uint256 stakedNow,) = farm.userInfo(address(adapter));
        assertEq(stakedNow, handler.sumBondCounts(), "the ETH mint must land staked, not loose");
    }
}
