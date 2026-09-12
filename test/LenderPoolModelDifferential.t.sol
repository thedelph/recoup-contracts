// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {CanonicalCashModel} from "./models/CanonicalCashModel.sol";

/// @notice Stateless differential fuzz: one `LenderPool` and one `CanonicalCashModel` are driven
///         through the SAME action sequence and their canonical books are compared after every
///         step. Audit round 46.
/// @dev Until this file existed nothing in `contracts/test` compared the model to the pool: the
///      model's own campaign checked the model against itself, and the pool's campaign checked the
///      pool against itself. The two agreeing was assumed, never measured.
///
///      **Shape.** The test contract is the only actor and holds every role the pool recognises -
///      depositor, `creditManager` and `epochHarvester` - because the model is single-actor and has
///      no roles, so one address is the faithful twin. No prank is needed for any pool door except
///      the external cash destruction, which pranks the pool itself exactly as
///      `CanonicalLenderHandler.destroyRawCash` does. Every request is serviced or cancelled inside
///      its own step, so the pool never carries a live request across a comparison and the
///      model's absence of a queue is not a divergence the book can see.
///
///      **The stream duration is the harness's, not the model's.** The model takes its stream
///      window as a parameter and its docstring disclaims `_rateStream` rules 1 and 1b. The harness
///      computes the pool's window from the MODEL's own state (never from the pool's) and passes
///      it in, so the comparison is about the book and not about the rating rules. What the model
///      would do with its bare default window is pinned separately below as a known divergence.
///
///      **Refusal protocol.** The pool acts first. If it refuses on a KNOWN selector - a guard
///      the model deliberately lacks - the step is counted and the model is not called, so the two
///      stay in lockstep. If it refuses on any other selector the model must refuse too, or the
///      model over-approximates and the test fails. If the pool accepts, the model must accept, or
///      the model under-approximates and the test fails; that is the finding class nobody had
///      looked for. A state the pool reaches and the model refuses is the shape that matters most,
///      because every model-side proof is silent about it.
///
///      **Comparison sets**, widened one leg at a time from the stored book outward, and every leg
///      that stayed red became a `test_knownDivergence_*` below or a ledger row. None was dropped.
contract LenderPoolModelDifferentialTest is Test {
    uint256 internal constant CAP = 25_000e6;
    uint256 internal constant MAX_FLOW = 5_000e6;
    uint256 internal constant MAX_GAIN = 1_000e6;
    uint256 internal constant STREAM = Config.YIELD_STREAM_DURATION;
    uint256 internal constant ACC_PRECISION = 1e18;
    uint256 internal constant MIN_SUPPLY = (10 ** 3) * Config.BPS;
    bytes4 internal constant PANIC = 0x4e487b71; // Panic(uint256)
    uint8 internal constant OP_COUNT = 16;

    uint8 internal constant OP_DEPOSIT = 0;
    uint8 internal constant OP_MINT = 1;
    uint8 internal constant OP_DONATE = 2;
    uint8 internal constant OP_DESTROY = 3;
    uint8 internal constant OP_LEND = 4;
    uint8 internal constant OP_REPAY = 5;
    uint8 internal constant OP_EPOCH = 6;
    uint8 internal constant OP_RECOVER = 7;
    uint8 internal constant OP_LOSS = 8;
    uint8 internal constant OP_REDEEM = 9;
    uint8 internal constant OP_SERVICE = 10;
    uint8 internal constant OP_CLAIM = 11;
    uint8 internal constant OP_COVER_CLAIM = 12;
    uint8 internal constant OP_COVER_ENTRY = 13;
    uint8 internal constant OP_RECONCILE = 14;
    uint8 internal constant OP_WARP = 15;

    MockUSDC internal usdc;
    LenderPool internal pool;
    CanonicalCashModel internal model;
    address internal sink;

    /// @dev Per-op outcome counters, written by `_step` and read by the seeded census below. The
    ///      fuzz entry point writes them too and never reads them: forge restores state between
    ///      fuzz runs, so under fuzz they are a per-sequence figure nothing observes.
    uint256[OP_COUNT] internal accepted;
    uint256[OP_COUNT] internal refusedByBoth;
    uint256[OP_COUNT] internal knownSkips;
    uint256[OP_COUNT] internal noOps;
    uint256 internal knownInsufficientLiquidity;
    uint256 internal knownYieldExceedsCapital;

    /// @dev State census at the tail of every step, so the always-equal legs can be read as
    ///      "equal across N states of this kind" and not only "equal on N sequences".
    uint256 internal streamStates;
    uint256 internal frozenStates;
    uint256 internal cashDeficitStates;
    uint256 internal liquidityDeficitStates;
    uint256 internal solvencyDeficitStates;
    uint256 internal entryDeficitStates;
    uint256 internal principalStates;
    uint256 internal lowSupplyStates;
    uint256 internal emptyPoolStates;
    uint256 internal floatRelationChecks;
    /// @dev An empty pool still holding raw cash: emptied AFTER use, as against the pool before
    ///      its first deposit, which is what every empty-pool state was until the exact draws.
    uint256 internal drainedStates;

    string[OP_COUNT] internal opNames = [
        "deposit",
        "mint",
        "donate",
        "destroy",
        "lend",
        "repay",
        "epoch",
        "recover",
        "loss",
        "redeem",
        "service",
        "claim",
        "coverClaim",
        "coverEntry",
        "reconcile",
        "warp"
    ];

    function setUp() public {
        vm.warp(1_750_000_000);
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), address(this));
        pool.setCreditManager(address(this));
        pool.setEpochHarvester(address(this));
        pool.setDepositCap(CAP);
        model = new CanonicalCashModel(CAP);
        sink = makeAddr("cash-destruction-sink");

        usdc.mint(address(this), type(uint128).max);
        usdc.approve(address(pool), type(uint256).max);
    }

    // ── The differential ─────────────────────────────────────────────────────

    function testFuzz_theModelAndThePoolAgreeOnTheCanonicalBook(uint8[24] memory ops, uint96[24] memory args) public {
        _compare(type(uint256).max);
        for (uint256 i; i < ops.length; ++i) {
            uint8 op = ops[i] % OP_COUNT;
            _step(op, args[i], i);
            _compare(i);
        }
    }

    function _step(uint8 op, uint96 seed, uint256 step) internal {
        // The pool reconciles first and unconditionally on every one of these doors; doing it
        // explicitly on both sides before the draw keeps a REFUSED step from leaving the pool
        // unreconciled (the revert unwinds its internal reconcile) while the harness computed the
        // model's window from reconciled views. Both calls are permissionless and idempotent, so
        // the state they leave is a reachable one. Entry doors are excluded on purpose: they
        // refuse a deficit BEFORE reconciling, and that refusal is part of what is compared.
        if (op >= OP_LEND && op <= OP_COVER_ENTRY) {
            pool.reconcileCashDeficit();
            model.reconcileCashDeficit();
        }

        uint256 amount = _draw(op, seed);
        if (amount == 0) {
            ++noOps[op];
            _census();
            return;
        }

        (bool poolOk, bytes4 poolSel) = _poolStep(op, amount);
        string memory where = string.concat(opNames[op], " at step ", vm.toString(step));

        if (!poolOk) {
            assertTrue(poolSel != PANIC, string.concat("the pool PANICKED on ", where, " rather than refusing"));
            if (_known(poolSel)) {
                ++knownSkips[op];
                if (poolSel == LenderPool.InsufficientLiquidity.selector) ++knownInsufficientLiquidity;
                else ++knownYieldExceedsCapital;
                _census();
                return;
            }
            (bool modelOk, bytes4 modelSel) = _modelStep(op, amount);
            assertFalse(
                modelOk,
                string.concat(
                    "OVER-APPROXIMATION: the pool refused ",
                    where,
                    " with ",
                    vm.toString(poolSel),
                    " and the model accepted"
                )
            );
            // A panic is not a refusal. The model is an executable specification and must say no
            // with a typed error where the pool does; MEASURED: with `redeem`'s `maxRedeem` guard
            // deleted from the model, `rawCash -= assets` underflowed instead and the deletion
            // was invisible to the protocol above.
            assertTrue(
                modelSel != PANIC,
                string.concat("the model PANICKED on ", where, " where the pool refused with ", vm.toString(poolSel))
            );
            ++refusedByBoth[op];
            _census();
            return;
        }

        (bool ok, bytes4 sel) = _modelStep(op, amount);
        assertTrue(
            ok,
            string.concat(
                "UNDER-APPROXIMATION: the pool accepted ", where, " and the model refused with ", vm.toString(sel)
            )
        );
        ++accepted[op];
        _census();
    }

    function _census() internal {
        if (pool.unreleasedYield() != 0) {
            ++streamStates;
            if (pool.yieldRate() == 0) ++frozenStates;
        }
        if (pool.totalSupply() == 0 && usdc.balanceOf(address(pool)) != 0) ++drainedStates;
        if (pool.cashDeficit() != 0) ++cashDeficitStates;
        if (pool.claimLiquidityDeficit() != 0) ++liquidityDeficitStates;
        if (pool.claimSolvencyDeficit() != 0) ++solvencyDeficitStates;
        if (pool.entryPriceDeficit() != 0) ++entryDeficitStates;
        if (pool.outstandingPrincipal() != 0) ++principalStates;
        uint256 supply = pool.totalSupply();
        if (supply == 0) ++emptyPoolStates;
        else if (supply < MIN_SUPPLY) ++lowSupplyStates;
        if (
            supply >= MIN_SUPPLY && pool.cashDeficit() == 0 && pool.claimLiquidityDeficit() == 0
                && pool.unreleasedYield() == 0
        ) ++floatRelationChecks;
    }

    // ── The seeded census ────────────────────────────────────────────────────

    uint256 internal constant CENSUS_SEED = 0x5246_4432; // "RF D2", named so the figures reproduce
    uint256 internal constant CENSUS_SEQUENCES = 512;

    /// @notice What the differential's sequences actually reach, from a NAMED seed so the figures
    ///         in the PR body reproduce. Every door must be accepted at least once, every
    ///         refusable door refused by both sides at least once, and both KNOWN selectors must
    ///         fire, or the refusal protocol's known arm is decorative. The state floors make the
    ///         always-equal legs a statement about deficits, streams and empty pools rather than
    ///         about the happy path.
    /// @dev The same `_step` the fuzz uses, over `CENSUS_SEQUENCES` keccak-derived sequences of
    ///      24 steps, each started from the post-`setUp` snapshot so a sequence is shaped like one
    ///      fuzz run. Counters are copied out before each revert because the revert takes them.
    function test_census_theDifferentialReachesEveryDoorAndBothKnownRefusals() public {
        uint256[OP_COUNT] memory acceptedTotal;
        uint256[OP_COUNT] memory refusedTotal;
        uint256[OP_COUNT] memory knownTotal;
        uint256[OP_COUNT] memory noOpTotal;
        uint256[13] memory states;

        // 512 sequences at roughly 30M gas each is fifteen times the 2^30 per-call limit, and the
        // count is the point of a census, so metering is off for the loop rather than the loop
        // shortened to fit the meter. MEASURED: without this line the test dies `OutOfGas` at
        // 1,073,720,760.
        vm.pauseGasMetering();
        for (uint256 seq; seq < CENSUS_SEQUENCES; ++seq) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 i; i < 24; ++i) {
                uint256 h = uint256(keccak256(abi.encode(CENSUS_SEED, seq, i)));
                _step(uint8(h) % OP_COUNT, uint96(h >> 8), i);
                _compare(i);
            }
            for (uint256 op; op < OP_COUNT; ++op) {
                acceptedTotal[op] += accepted[op];
                refusedTotal[op] += refusedByBoth[op];
                knownTotal[op] += knownSkips[op];
                noOpTotal[op] += noOps[op];
            }
            states[0] += knownInsufficientLiquidity;
            states[1] += knownYieldExceedsCapital;
            states[2] += streamStates;
            states[3] += frozenStates;
            states[4] += cashDeficitStates;
            states[5] += liquidityDeficitStates;
            states[6] += solvencyDeficitStates;
            states[7] += entryDeficitStates;
            states[8] += principalStates;
            states[9] += lowSupplyStates;
            states[10] += emptyPoolStates;
            states[11] += floatRelationChecks;
            states[12] += drainedStates;
            vm.revertToState(snapshot);
        }

        for (uint256 op; op < OP_COUNT; ++op) {
            emit log_named_uint(string.concat("CENSUS accepted ", opNames[op]), acceptedTotal[op]);
            emit log_named_uint(string.concat("CENSUS refusedByBoth ", opNames[op]), refusedTotal[op]);
            emit log_named_uint(string.concat("CENSUS knownSkips ", opNames[op]), knownTotal[op]);
            emit log_named_uint(string.concat("CENSUS noOps ", opNames[op]), noOpTotal[op]);
        }
        for (uint256 op; op < OP_COUNT; ++op) {
            // `coverEntryPriceDeficit` is the one door these sequences can only REFUSE. Accepting
            // it needs an entry-price deficit with fixed claims liquid, and `minimumEntryAssets()`
            // is zero until real supply passes 2^128 shares - the numeric regime the loss-refill
            // cycle reaches and a 24-step random walk does not (MEASURED: 0 accepted, 13 refused
            // by both, at this seed). Its refusal is held to a floor instead, so the door is not
            // silently absent from the census.
            if (op == OP_COVER_ENTRY) {
                assertGt(refusedTotal[op], 0, "the census never refused coverEntry on both sides");
                continue;
            }
            assertGt(acceptedTotal[op], 0, string.concat("the census never accepted ", opNames[op]));
        }
        emit log_named_uint("CENSUS known InsufficientLiquidity", states[0]);
        emit log_named_uint("CENSUS known YieldExceedsCapital", states[1]);
        emit log_named_uint("CENSUS states with a live stream", states[2]);
        emit log_named_uint("CENSUS states with a frozen pot", states[3]);
        emit log_named_uint("CENSUS states with a cash deficit", states[4]);
        emit log_named_uint("CENSUS states with a claim liquidity deficit", states[5]);
        emit log_named_uint("CENSUS states with a claim solvency deficit", states[6]);
        emit log_named_uint("CENSUS states with an entry price deficit", states[7]);
        emit log_named_uint("CENSUS states with principal out", states[8]);
        emit log_named_uint("CENSUS states below the supply floor", states[9]);
        emit log_named_uint("CENSUS states with an empty pool", states[10]);
        emit log_named_uint("CENSUS float relation checks", states[11]);
        emit log_named_uint("CENSUS states with an empty pool still holding cash", states[12]);

        assertGt(states[0], 0, "the known InsufficientLiquidity arm never fired");
        assertGt(states[1], 0, "the known YieldExceedsCapital arm never fired");
        assertGt(states[2], 0, "no state with a live stream was compared");
        assertGt(states[4], 0, "no state with a cash deficit was compared");
        assertGt(states[5], 0, "no state with a claim liquidity deficit was compared");
        assertGt(states[7], 0, "no state with an entry price deficit was compared");
        assertGt(states[8], 0, "no state with principal out was compared");
        assertGt(states[11], 0, "the float relation was never checked");
        assertGt(states[12], 0, "no pool emptied after use was compared");
    }

    // ── The known divergences, pinned ────────────────────────────────────────
    //
    // Each of these asserts that the model and the pool DISAGREE, and says why, so the day the
    // model closes the gap the test goes red and somebody reads this block. They are the four
    // over-approximations the model's docstring names. None is a finding: every one is a guard the
    // model deliberately lacks, and the differential above either neutralises it (the window),
    // skips it (the two KNOWN selectors) or never reaches it (a frozen pot at low supply).

    /// @notice `_startStream` ignores `_rateStream` rules 1a and 1b. Given its bare default window
    ///         the model rates a small recovery over the full floor while the pool shortens it to
    ///         what the money funds at the running rate; given the harness's window it matches.
    ///         Round-23 finding 2 is why the pool does this. Goes red when the model learns 1b.
    function test_knownDivergence_theModelStreamIgnoresRuleOneB() public {
        pool.deposit(10_000e6, address(this));
        model.deposit(10_000e6);
        pool.distributeYield(500e6);
        model.deliverEpochYield(500e6, _epochWindow());
        assertEq(pool.yieldStreamEndsAt(), model.yieldStreamEndsAt(), "epoch windows differ");
        skip(4 days);

        // Rule 1b binds: with a day left on a 500 pot, a 10 recovery funds about 1.1 days at the
        // running rate, well under the five-day floor.
        uint256 snapshot = vm.snapshotState();
        pool.recoverLoss(10e6);
        model.addActiveGain(10e6, _nonEpochWindow(10e6));
        assertEq(pool.yieldStreamEndsAt(), model.yieldStreamEndsAt(), "the harness window did not reproduce 1b");
        skip(12 hours);
        assertEq(pool.unreleasedYield(), model.unreleasedYield(), "the harness window did not reproduce the release");
        vm.revertToState(snapshot);

        pool.recoverLoss(10e6);
        model.addActiveGain(10e6, STREAM);
        assertGt(
            model.yieldStreamEndsAt(), pool.yieldStreamEndsAt(), "KNOWN DIVERGENCE CLOSED: the model applies rule 1b"
        );
        skip(12 hours);
        assertGt(
            model.unreleasedYield(),
            pool.unreleasedYield(),
            "KNOWN DIVERGENCE CLOSED: the model releases at the pool's rate"
        );
    }

    /// @notice No `YieldExceedsCapital`. The pool refuses an epoch larger than everything it holds
    ///         (audit round 13); the model books it. The differential skips this selector.
    function test_knownDivergence_theModelAcceptsAnEpochLargerThanCapital() public {
        pool.deposit(100e6, address(this));
        model.deposit(100e6);

        vm.expectRevert(abi.encodeWithSelector(LenderPool.YieldExceedsCapital.selector, 200e6, 100e6));
        pool.distributeYield(200e6);

        assertEq(
            model.deliverEpochYield(200e6, _epochWindow()),
            200e6,
            "KNOWN DIVERGENCE CLOSED: the model refused the epoch"
        );
        assertEq(model.accountedCash(), 300e6, "the model did not book the whole epoch");
    }

    /// @notice No float and no request reserve. `available()` on the pool holds back the 15%
    ///         operational float on the post-request book; the model lends every unreserved wei.
    ///         The differential skips `InsufficientLiquidity` and asserts the exact relation.
    function test_knownDivergence_theModelHoldsNoFloat() public {
        pool.deposit(1_000e6, address(this));
        model.deposit(1_000e6);

        uint256 lendable = model.available();
        assertEq(lendable, 1_000e6, "the model held something back");
        uint256 float_ = Math.mulDiv(pool.totalAssets(), Config.RESERVE_RATIO_BPS, Config.BPS);
        assertEq(pool.available(), lendable - float_, "the float relation");

        vm.expectRevert(abi.encodeWithSelector(LenderPool.InsufficientLiquidity.selector, lendable, lendable - float_));
        pool.lend(lendable);
        model.lend(lendable);
        assertEq(model.outstandingPrincipal(), lendable, "KNOWN DIVERGENCE CLOSED: the model refused the whole book");
    }

    /// @notice No supply check in `activateFrozen`. The pool re-rates a frozen pot only through
    ///         a delivered epoch, and `distributeYield` refuses one below the supply floor; the
    ///         model can thaw at any supply. Unreached by the differential, which has no thaw door.
    function test_knownDivergence_theModelThawsAFrozenPotBelowTheSupplyFloor() public {
        // 5,000 wei of USDC mints 5e6 shares, half the 1e7 floor.
        pool.deposit(5_000, address(this));
        model.deposit(5_000);
        pool.recoverLoss(1e6);
        model.addActiveGain(1e6, STREAM);
        assertEq(pool.yieldRate(), 0, "the pool did not freeze below the floor");
        assertEq(model.yieldRate(), 0, "the model did not freeze below the floor");
        assertEq(pool.pendingYield(), model.pendingYield(), "frozen pots differ");

        vm.expectRevert(LenderPool.NoSharesOutstanding.selector);
        pool.distributeYield(1);

        model.activateFrozen(STREAM);
        assertGt(model.yieldRate(), 0, "KNOWN DIVERGENCE CLOSED: the model refused to thaw below the floor");
    }

    /// @dev Guards the pool carries that the model deliberately lacks. A refusal on one of these
    ///      is counted as a documented over-approximation, not compared.
    ///      - `InsufficientLiquidity`: the pool's `available()` holds back the 15% float and the
    ///        request reserve; the model's holds back neither.
    ///      - `YieldExceedsCapital`: the round-13 capital floor on `distributeYield`; the model
    ///        accepts any epoch a viable cohort exists for.
    function _known(bytes4 sel) internal pure returns (bool) {
        return sel == LenderPool.InsufficientLiquidity.selector || sel == LenderPool.YieldExceedsCapital.selector;
    }

    /// @dev One draw per step, shared by both sides. Where a bound needs live state it reads the
    ///      POOL, because every quantity it reads is in the always-equal set below and a divergence
    ///      there fails the comparison rather than the draw. Zero means "no action on either side".
    ///
    ///      **One draw in four is the exact maximum, and that is a measurement, not a taste.** A
    ///      uniform draw over `[1, balance]` lands on `balance` once in `balance` tries, so a
    ///      neuter that stopped the model de-recognising the empty-pool residual stayed GREEN at
    ///      256 runs: the census reached 3,925 empty-pool states and every one of them was the
    ///      pool before its first deposit. The same shape as `CanonicalCashModelHandler`'s
    ///      `redeemAll`/`serviceAll`/`destroyAllCash`, arrived at the same way.
    function _draw(uint8 op, uint96 seed) internal view returns (uint256) {
        uint256 s = uint256(seed);
        bool exact = s % 4 == 0;
        if (op == OP_DEPOSIT || op == OP_DONATE || op == OP_REPAY) return bound(s, 1, MAX_FLOW);
        if (op == OP_MINT) return bound(s, 1, MAX_FLOW * 1_000);
        if (op == OP_EPOCH) return bound(s, 1, MAX_GAIN);
        // One recovery in four is dust against the running pot. `_rateStream` rule 1b binds only
        // when the arriving money funds less than the floor at the running rate, which a uniform
        // draw up to 1,000 USDC on a pot of a few hundred almost never is. MEASURED: handing the
        // model its bare window on this leg stayed GREEN at 256 runs without this line.
        if (op == OP_RECOVER) return exact ? bound(s, 1, MAX_GAIN / 100) : bound(s, 1, MAX_GAIN);
        if (op == OP_LEND) return exact ? pool.available() : bound(s, 1, MAX_FLOW);
        if (op == OP_DESTROY) {
            uint256 raw = usdc.balanceOf(address(pool));
            return raw == 0 ? 0 : exact ? raw : bound(s, 1, raw);
        }
        if (op == OP_LOSS) {
            uint256 principal = pool.outstandingPrincipal();
            return principal == 0 ? 0 : exact ? principal : bound(s, 1, principal);
        }
        if (op == OP_REDEEM || op == OP_SERVICE) {
            uint256 balance = pool.balanceOf(address(this));
            if (balance == 0) return 0;
            uint256 maximum = pool.maxRedeem(address(this));
            return exact && maximum != 0 ? maximum : bound(s, 1, balance);
        }
        if (op == OP_CLAIM) return pool.totalClaimable();
        if (op == OP_COVER_CLAIM) {
            uint256 deficit = pool.claimSolvencyDeficit();
            return deficit == 0 ? 0 : bound(s, 1, deficit);
        }
        if (op == OP_COVER_ENTRY) {
            uint256 deficit = pool.entryPriceDeficit();
            return deficit == 0 ? 0 : bound(s, 1, deficit);
        }
        // Fourteen days, not seven: a five-day stream has to be able to run down inside one
        // sequence, or rule 1b never binds. Not thirty either: then most epochs are rated over an
        // `elapsed` far longer than the floor, and rule 2 makes both sides pick `remaining`, which
        // is the same window and no divergence at all. Two regimes, both blind to 1b.
        if (op == OP_WARP) return bound(s, 1, 14 days);
        return 1; // reconcile
    }

    function _poolStep(uint8 op, uint256 amount) internal returns (bool ok, bytes4 sel) {
        address self = address(this);
        if (op == OP_DEPOSIT) {
            try pool.deposit(amount, self) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_MINT) {
            try pool.mint(amount, self) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_DONATE) {
            usdc.mint(address(pool), amount);
            return (true, 0);
        }
        if (op == OP_DESTROY) {
            vm.prank(address(pool));
            usdc.transfer(sink, amount);
            return (true, 0);
        }
        if (op == OP_LEND) {
            try pool.lend(amount) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_REPAY) {
            try pool.repayPrincipal(amount) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_EPOCH) {
            try pool.distributeYield(amount) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_RECOVER) {
            try pool.recoverLoss(amount) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_LOSS) {
            try pool.socialiseLoss(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_REDEEM) {
            try pool.redeem(amount, self, self) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_SERVICE) {
            // Request EVERY share, so the controller's pro-rata slice is the whole executable book
            // and `maxRequestRedeem` coincides with the model's `maxRedeem`. Whatever is not
            // serviced is cancelled in the same step, so no request outlives its comparison.
            pool.requestWithdrawal(pool.balanceOf(self), self);
            try pool.serviceWithdrawalRequest(self, amount, 0) returns (uint256) {
                ok = true;
            } catch (bytes memory r) {
                sel = _selector(r);
            }
            (uint256 requestId,,,,) = pool.withdrawalRequest(self);
            if (requestId != 0) pool.cancelWithdrawalRequest();
            return (ok, sel);
        }
        if (op == OP_CLAIM) {
            try pool.claim() returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_COVER_CLAIM) {
            try pool.coverClaimDeficit(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_COVER_ENTRY) {
            try pool.coverEntryPriceDeficit(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_RECONCILE) {
            pool.reconcileCashDeficit();
            return (true, 0);
        }
        skip(amount);
        return (true, 0);
    }

    function _modelStep(uint8 op, uint256 amount) internal returns (bool ok, bytes4 sel) {
        if (op == OP_DEPOSIT) {
            try model.deposit(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_MINT) {
            try model.mint(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_DONATE) {
            model.donate(amount);
            return (true, 0);
        }
        if (op == OP_DESTROY) {
            model.destroyCash(amount);
            return (true, 0);
        }
        if (op == OP_LEND) {
            try model.lend(amount) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_REPAY) {
            uint256 principal = Math.min(amount, model.outstandingPrincipal());
            uint256 surplus = amount - principal;
            uint256 streamable = surplus - Math.min(surplus, model.claimSolvencyDeficit());
            try model.repay(amount, _nonEpochWindow(streamable)) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_EPOCH) {
            try model.deliverEpochYield(amount, _epochWindow()) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_RECOVER) {
            uint256 streamable = amount - Math.min(amount, model.claimSolvencyDeficit());
            try model.addActiveGain(amount, _nonEpochWindow(streamable)) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_LOSS) {
            try model.socialiseLoss(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_REDEEM) {
            try model.redeem(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_SERVICE) {
            try model.service(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_CLAIM) {
            try model.claim(amount) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_COVER_CLAIM) {
            try model.coverClaimDeficit(amount) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_COVER_ENTRY) {
            try model.coverEntryPriceDeficit(amount) returns (uint256) {
                return (true, 0);
            } catch (bytes memory r) {
                return (false, _selector(r));
            }
        }
        if (op == OP_RECONCILE) {
            model.reconcileCashDeficit();
            return (true, 0);
        }
        // OP_WARP: `skip` in `_poolStep` already moved the one clock both contracts read.
        return (true, 0);
    }

    /// @dev Rule 1 of `LenderPool._rateStream` for a delivered epoch: at least as long as the pot
    ///      took to accrue, floored at `YIELD_STREAM_DURATION`. Read from the MODEL's own delivery
    ///      clock so the model stays independent of the pool. Rule 2 (never shorten a running
    ///      stream) the model applies itself in `_startStream`.
    function _epochWindow() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - model.lastEpochDeliveryAt();
        return elapsed > STREAM ? elapsed : STREAM;
    }

    /// @dev Rules 1a and 1b for money that does not own the accrual clock: the floor window,
    ///      shortened to what the arriving money funds at the rate already running. Read from the
    ///      model's own stream terms, which the pre-step reconcile has already crystallised.
    function _nonEpochWindow(uint256 streamable) internal view returns (uint256 duration) {
        duration = STREAM;
        uint256 endsAt = model.yieldStreamEndsAt();
        uint256 remaining = endsAt > block.timestamp ? endsAt - block.timestamp : 0;
        uint256 rate = model.yieldRate();
        if (remaining != 0 && rate != 0) {
            uint256 funded = ((model.unreleasedYield() + streamable) * ACC_PRECISION) / rate;
            if (duration > funded) duration = funded;
        }
    }

    function _selector(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(reason, 32))
        }
    }

    // ── The comparison ───────────────────────────────────────────────────────

    function _compare(uint256 step) internal view {
        string memory at =
            step == type(uint256).max ? " before any step" : string.concat(" at step ", vm.toString(step));
        address self = address(this);
        uint256 raw = usdc.balanceOf(address(pool));

        // 1. The stored book. Always equal.
        _eq(raw, model.rawCash(), "rawCash", at);
        _eq(raw + pool.cashDeficit() - pool.unmanagedSurplus(), model.accountedCash(), "accountedCash", at);
        _eq(pool.outstandingPrincipal(), model.outstandingPrincipal(), "outstandingPrincipal", at);
        _eq(pool.totalClaimable(), model.totalClaimable(), "totalClaimable", at);
        _eq(pool.totalSupply(), model.totalSupply(), "totalSupply", at);
        _eq(pool.cashDeficit(), model.cashDeficit(), "cashDeficit", at);
        _eq(pool.unmanagedSurplus(), model.unmanagedSurplus(), "unmanagedSurplus", at);
        _eq(pool.claimLiquidityDeficit(), model.claimLiquidityDeficit(), "claimLiquidityDeficit", at);
        _eq(pool.claimSolvencyDeficit(), model.claimSolvencyDeficit(), "claimSolvencyDeficit", at);
        _eq(pool.depositCapUsage(), model.depositCapUsage(), "depositCapUsage", at);
        _eq(pool.minimumEntryAssets(), model.requiredEntryAssets(), "minimumEntryAssets", at);
        _eq(pool.entryPriceDeficit(), model.entryPriceDeficit(), "entryPriceDeficit", at);
        _eq(pool.maximumShareSupply(), model.maximumShareSupply(), "maximumShareSupply", at);
        assertEq(pool.exitReserve(), 0, "the differential never impairs, so the exit price is the NAV");

        // 2. The stream, projected. With the harness supplying the pool's window this should be
        //    exact; if it is not, the legs below narrow to `unreleasedYield() == 0`.
        _eq(pool.unreleasedYield(), model.unreleasedYield(), "unreleasedYield", at);

        // 3. Prices and maxima.
        _eq(pool.totalAssets(), model.totalAssets(), "totalAssets", at);
        _eq(pool.previewDeposit(1e6), model.previewDeposit(1e6), "previewDeposit(1e6)", at);
        _eq(pool.previewMint(1e9), model.previewMint(1e9), "previewMint(1e9)", at);
        _eq(
            pool.previewRedeem(pool.totalSupply()),
            model.previewRedeem(model.totalSupply()),
            "previewRedeem(supply)",
            at
        );
        _eq(pool.maxDeposit(self), model.maxDeposit(), "maxDeposit", at);
        _eq(pool.maxMint(self), model.maxMint(), "maxMint", at);
        _eq(pool.maxRedeem(self), model.maxRedeem(), "maxRedeem", at);

        // 4. The over-approximation inequalities.
        assertGe(
            pool.entryPriceCashReserve(),
            model.entryPriceCashReserve(),
            string.concat("the model reserved more entry-price cash than the pool", at)
        );
        assertLe(
            pool.available(),
            model.available(),
            string.concat("the pool advertised more lending room than the model", at)
        );

        // 5. The one exact float relation: no request (always here), supply above the floor, no
        //    deficit of either kind, no stream. Then the pool's `available()` is the model's less
        //    the 15% float on the post-request book, which with no request is `totalAssets()`.
        if (
            pool.totalSupply() >= MIN_SUPPLY && pool.cashDeficit() == 0 && pool.claimLiquidityDeficit() == 0
                && pool.unreleasedYield() == 0
        ) {
            uint256 float_ = Math.mulDiv(pool.totalAssets(), Config.RESERVE_RATIO_BPS, Config.BPS);
            uint256 lendable = model.available();
            _eq(pool.available(), lendable > float_ ? lendable - float_ : 0, "available less the float", at);
            _eq(pool.entryPriceCashReserve(), model.entryPriceCashReserve(), "entryPriceCashReserve (no stream)", at);
        }
    }

    function _eq(uint256 poolValue, uint256 modelValue, string memory what, string memory at) internal pure {
        assertEq(poolValue, modelValue, string.concat(what, ": pool != model", at));
    }
}
