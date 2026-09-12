// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {CanonicalCashModel} from "./models/CanonicalCashModel.sol";

/// @notice Regression pins on the TEXT of fourteen accounting views, and nothing more.
/// @dev Round 46, item 73. Until this round these formulas were invariants in the two canonical-cash
///      campaigns, eight in `LenderPool.invariants.t.sol` and eight in `CanonicalCashModel.t.sol`.
///      Audit round 45 wrote arbitrary values straight into every storage slot they read -
///      states no handler reaches and states that are not even self-consistent - and re-ran each
///      assertion verbatim: all sixteen held. An assertion that holds over uint120^n of
///      inconsistent storage is a statement about the function's source text, not about the
///      pool's behaviour, and counting it among "the invariants that guard the pool" overstates
///      the surface to an auditor.
///
///      **So this file says what those assertions are: pins.** Each `testFuzz_pin_*` seeds
///      storage directly with `vm.store` and asserts the view's formula over it. A pin goes red
///      when the view's text changes and for no other reason; it is NOT a claim that any state it
///      evaluates is reachable, and it is NOT coverage of anything. It earns its place the way
///      audit round 45 measured: a source edit to `maxWithdraw`'s rounding tripped the old invariant, and
///      the same edit trips the pin, so the regression guard is kept without pretending it is a
///      property. The campaigns keep only what a reachable state could falsify.
///
///      `test_pins_theStorageLayoutTheyDependOn` is the pin under the pins: every slot constant
///      below is from `forge inspect <contract> storage-layout` at the commit that wrote it, and a
///      layout drift would otherwise make every fuzz pin evaluate a different variable than it
///      names while still passing, because each one seeds and reads the same wrong slot.
contract LenderPoolFormulaPins is Test {
    uint256 private constant VIRTUAL = 1_000;
    uint256 private constant MIN_SUPPLY = 10_000_000;

    // LenderPool, `forge inspect LenderPool storage-layout` at 8631498.
    uint256 private constant P_BALANCES = 0;
    uint256 private constant P_SUPPLY = 2;
    uint256 private constant P_ACC = 10;
    uint256 private constant P_PRINCIPAL = 11;
    uint256 private constant P_PENDING = 14;
    uint256 private constant P_RATE = 15;
    uint256 private constant P_ACCRUAL = 16;
    uint256 private constant P_ENDS = 18;
    uint256 private constant P_QUEUED = 28;
    uint256 private constant P_CLAIMS = 30;

    // CanonicalCashModel, `forge inspect CanonicalCashModel storage-layout` at 8631498.
    uint256 private constant M_RAW = 0;
    uint256 private constant M_ACC = 1;
    uint256 private constant M_PRINCIPAL = 2;
    uint256 private constant M_CLAIMS = 3;
    uint256 private constant M_SUPPLY = 4;
    uint256 private constant M_PENDING = 6;
    uint256 private constant M_RATE = 7;
    uint256 private constant M_ACCRUAL = 8;
    uint256 private constant M_ENDS = 10;

    /// @dev One arbitrary book. `uint120` keeps every sum inside `uint256`; nothing else about
    ///      these values is constrained, which is the point.
    struct Book {
        uint120 raw;
        uint120 acc;
        uint120 principal;
        uint120 claims;
        uint120 supply;
        uint120 pending;
        uint64 rate;
        uint32 elapsed;
        uint32 span;
    }

    MockUSDC internal usdc;
    LenderPool internal pool;
    CanonicalCashModel internal model;
    address internal owner = makeAddr("pins-owner");
    address internal actor = makeAddr("pins-actor");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), owner);
        model = new CanonicalCashModel(Config.DEFAULT_LENDER_POOL_DEPOSIT_CAP);
    }

    // ── The pin under the pins ────────────────────────────────────────────────────────────────

    /// @notice Every slot constant above still names the variable each pin seeds.
    /// @dev A distinct sentinel per slot, read back through the public getter of the variable the
    ///      constant claims to address. `_accountedCash` has no getter and is read back as
    ///      `cashDeficit()` against a zero token balance, which is that view's whole body.
    function test_pins_theStorageLayoutTheyDependOn() public {
        _store(address(pool), P_SUPPLY, 1_002);
        _store(address(pool), P_ACC, 1_010);
        _store(address(pool), P_PRINCIPAL, 1_011);
        _store(address(pool), P_PENDING, 1_014);
        _store(address(pool), P_RATE, 1_015);
        _store(address(pool), P_ACCRUAL, 1_016);
        _store(address(pool), P_ENDS, 1_018);
        _store(address(pool), P_QUEUED, 1_028);
        _store(address(pool), P_CLAIMS, 1_030);
        vm.store(address(pool), keccak256(abi.encode(actor, P_BALANCES)), bytes32(uint256(1_000)));

        assertEq(pool.totalSupply(), 1_002, "P_SUPPLY no longer addresses _totalSupply");
        assertEq(pool.cashDeficit(), 1_010, "P_ACC no longer addresses _accountedCash");
        assertEq(pool.outstandingPrincipal(), 1_011, "P_PRINCIPAL no longer addresses outstandingPrincipal");
        assertEq(pool.pendingYield(), 1_014, "P_PENDING no longer addresses pendingYield");
        assertEq(pool.yieldRate(), 1_015, "P_RATE no longer addresses yieldRate");
        assertEq(pool.lastYieldAccrualAt(), 1_016, "P_ACCRUAL no longer addresses lastYieldAccrualAt");
        assertEq(pool.yieldStreamEndsAt(), 1_018, "P_ENDS no longer addresses yieldStreamEndsAt");
        assertEq(pool.queuedShares(), 1_028, "P_QUEUED no longer addresses queuedShares");
        assertEq(pool.totalClaimable(), 1_030, "P_CLAIMS no longer addresses totalClaimable");
        assertEq(pool.balanceOf(actor), 1_000, "P_BALANCES no longer addresses _balances");

        _store(address(model), M_RAW, 2_000);
        _store(address(model), M_ACC, 2_001);
        _store(address(model), M_PRINCIPAL, 2_002);
        _store(address(model), M_CLAIMS, 2_003);
        _store(address(model), M_SUPPLY, 2_004);
        _store(address(model), M_PENDING, 2_006);
        _store(address(model), M_RATE, 2_007);
        _store(address(model), M_ACCRUAL, 2_008);
        _store(address(model), M_ENDS, 2_010);

        assertEq(model.rawCash(), 2_000, "M_RAW no longer addresses rawCash");
        assertEq(model.accountedCash(), 2_001, "M_ACC no longer addresses accountedCash");
        assertEq(model.outstandingPrincipal(), 2_002, "M_PRINCIPAL no longer addresses outstandingPrincipal");
        assertEq(model.totalClaimable(), 2_003, "M_CLAIMS no longer addresses totalClaimable");
        assertEq(model.totalSupply(), 2_004, "M_SUPPLY no longer addresses totalSupply");
        assertEq(model.pendingYield(), 2_006, "M_PENDING no longer addresses pendingYield");
        assertEq(model.yieldRate(), 2_007, "M_RATE no longer addresses yieldRate");
        assertEq(model.lastYieldAccrualAt(), 2_008, "M_ACCRUAL no longer addresses lastYieldAccrualAt");
        assertEq(model.yieldStreamEndsAt(), 2_010, "M_ENDS no longer addresses yieldStreamEndsAt");
    }

    // ── LenderPool ────────────────────────────────────────────────────────────────────────────

    /// @dev Formerly `invariant_rawAndRecognisedCashHaveOnlyOneSignedDifference`: two clamped
    ///      subtractions of one pair cannot both be non-zero. Pinned over the full `uint256` pair.
    function testFuzz_pin_cashDeficitAndUnmanagedSurplusAreOneSignedDifference(uint256 raw, uint256 acc) public {
        usdc.mint(address(pool), raw);
        _store(address(pool), P_ACC, acc);
        assertTrue(pool.cashDeficit() == 0 || pool.unmanagedSurplus() == 0, "both halves of one difference");
        assertEq(pool.cashDeficit(), acc > raw ? acc - raw : 0, "cashDeficit formula");
        assertEq(pool.unmanagedSurplus(), raw > acc ? raw - acc : 0, "unmanagedSurplus formula");
    }

    /// @dev Formerly `invariant_totalAssetsUsesOnlyEffectiveRecognisedCash`.
    function testFuzz_pin_totalAssetsFormula(Book memory b, uint120 queuedSeed) public {
        _seedPool(b, queuedSeed);
        (uint256 effective, uint256 claims) = _effectiveAndClaims();
        uint256 effectiveYield = _effectiveYield(effective, claims);
        uint256 gross = effective + pool.outstandingPrincipal();
        uint256 shareholderGross = gross > claims ? gross - claims : 0;
        assertEq(pool.totalAssets(), shareholderGross - effectiveYield, "totalAssets formula");
    }

    /// @dev Formerly `invariant_depositCapUsageIsTheStoredEntryBook`.
    function testFuzz_pin_depositCapUsageFormula(Book memory b, uint120 queuedSeed) public {
        _seedPool(b, queuedSeed);
        uint256 gross = _accountedCash(usdc.balanceOf(address(pool))) + pool.outstandingPrincipal();
        uint256 claims = pool.totalClaimable();
        assertEq(pool.depositCapUsage(), gross > claims ? gross - claims : 0, "depositCapUsage formula");
    }

    /// @dev Formerly `invariant_claimDeficitsUseCashForLiquidityAndTheWholeBookForSolvency`.
    function testFuzz_pin_claimDeficitFormulas(Book memory b, uint120 queuedSeed) public {
        _seedPool(b, queuedSeed);
        (uint256 effective, uint256 claims) = _effectiveAndClaims();
        uint256 backing = effective + pool.outstandingPrincipal();
        assertEq(pool.claimLiquidityDeficit(), claims > effective ? claims - effective : 0, "liquidity formula");
        assertEq(pool.claimSolvencyDeficit(), claims > backing ? claims - backing : 0, "solvency formula");
    }

    /// @dev Formerly the formula clauses of `invariant_entryPriceDeficitAndAbsoluteSupplyAreExact`;
    ///      the `supply <= maximum` clause stayed in the campaign as a guard.
    function testFuzz_pin_entryPriceDeficitAndMinimumEntryAssetsFormula(Book memory b, uint120 queuedSeed) public {
        _seedPool(b, queuedSeed);
        (uint256 effective, uint256 claims) = _effectiveAndClaims();
        uint256 supply = pool.totalSupply();
        uint256 required = Math.ceilDiv(Math.saturatingAdd(supply, VIRTUAL), Config.MAX_LENDER_SHARES_PER_ASSET) - 1;
        assertEq(pool.minimumEntryAssets(), required, "minimumEntryAssets formula");
        assertEq(
            pool.maximumShareSupply(),
            Config.MAX_LENDER_SHARES_PER_ASSET * (Config.GLOBAL_BORROW_CAP_MAX + 1) - VIRTUAL,
            "maximumShareSupply formula"
        );

        uint256 target = Math.saturatingAdd(claims, required);
        uint256 expectedDeficit = target > effective ? target - effective : 0;
        assertEq(pool.entryPriceDeficit(), expectedDeficit, "entryPriceDeficit formula");
        if (expectedDeficit == 0) {
            uint256 effectiveYield = _effectiveYield(effective, claims);
            assertGe(pool.totalAssets() + effectiveYield, required, "zero deficit implies the entry quotient bound");
        }
    }

    /// @dev Formerly `invariant_requestCashReserveAndAvailableUseReleasedRecognisedCash`.
    function testFuzz_pin_queueCashReserveAndAvailableFormula(Book memory b, uint120 queuedSeed) public {
        _seedPool(b, queuedSeed);
        (uint256 effective, uint256 claims) = _effectiveAndClaims();
        uint256 effectiveYield = _effectiveYield(effective, claims);
        uint256 excludedCash = claims + effectiveYield;
        uint256 idle = effective > excludedCash ? effective - excludedCash : 0;

        uint256 cashAfterClaims = effective > claims ? effective - claims : 0;
        uint256 tailCash = effectiveYield < cashAfterClaims ? effectiveYield : cashAfterClaims;
        uint256 required = Math.ceilDiv(pool.totalSupply() + VIRTUAL, Config.MAX_LENDER_SHARES_PER_ASSET) - 1;
        uint256 prospectivePriceReserve = required > tailCash ? required - tailCash : 0;
        uint256 existingPriceReserve = pool.outstandingPrincipal() == 0 ? 0 : prospectivePriceReserve;
        uint256 executable = idle > existingPriceReserve ? idle - existingPriceReserve : 0;

        uint256 queued = pool.queuedShares();
        uint256 expectedReserve = queued == 0 ? 0 : Math.mulDiv(executable, queued, pool.totalSupply(), Math.Rounding.Ceil);
        assertEq(pool.queueCashReserve(), expectedReserve, "queueCashReserve formula");

        if (pool.totalSupply() < MIN_SUPPLY) {
            assertEq(pool.available(), 0, "available below the supply floor");
            return;
        }
        uint256 lendingCash = idle > prospectivePriceReserve ? idle - prospectivePriceReserve : 0;
        uint256 requestReserve = queued == 0 ? 0 : Math.mulDiv(lendingCash, queued, pool.totalSupply(), Math.Rounding.Ceil);
        uint256 postRequestBook = pool.totalAssets() - requestReserve;
        uint256 hotFloat = Math.mulDiv(postRequestBook, Config.RESERVE_RATIO_BPS, Config.BPS);
        uint256 held = requestReserve + hotFloat;
        assertEq(pool.available(), lendingCash > held ? lendingCash - held : 0, "available formula");
    }

    /// @dev Formerly `invariant_aPausedPoolStillAdvertisesEveryExit`, which re-typed `_maxRedeem`'s
    ///      three-term minimum and asserted it while paused. The formula has no pause term, which
    ///      is why the campaign now measures the toggle instead; the text is pinned here in both
    ///      pause states.
    function testFuzz_pin_maxRedeemAndMaxWithdrawFormula(Book memory b, uint120 queuedSeed, bool paused) public {
        _seedPool(b, queuedSeed);
        if (paused) {
            vm.prank(owner);
            pool.pause();
        }
        uint256 idleShares = pool.convertToShares(pool.unreservedIdle());
        uint256 burnable = type(uint256).max;
        if (pool.outstandingPrincipal() != 0) {
            uint256 supply = pool.totalSupply();
            burnable = supply > MIN_SUPPLY ? supply - MIN_SUPPLY : 0;
        }
        uint256 expected = pool.balanceOf(actor);
        if (idleShares < expected) expected = idleShares;
        if (burnable < expected) expected = burnable;
        if (pool.claimLiquidityDeficit() != 0) expected = 0;
        assertEq(pool.maxRedeem(actor), expected, "maxRedeem formula");
        assertEq(pool.maxWithdraw(actor), pool.previewRedeem(expected), "maxWithdraw is previewRedeem(maxRedeem)");
    }

    // ── CanonicalCashModel ────────────────────────────────────────────────────────────────────

    /// @dev Formerly `invariant_effectiveCashNeverInventsBacking`, both legs.
    function testFuzz_pin_model_effectiveCashPartition(Book memory b) public {
        _seedModel(b);
        assertEq(model.effectiveCash() + model.cashDeficit(), model.accountedCash(), "effective plus deficit");
        assertEq(model.effectiveCash() + model.unmanagedSurplus(), model.rawCash(), "effective plus surplus");
    }

    /// @dev Formerly `invariant_theReleasedAndUnreleasedBooksPartitionGrossValue`, all three legs.
    function testFuzz_pin_model_grossBookPartition(Book memory b) public {
        _seedModel(b);
        uint256 gross = model.effectiveCash() + model.outstandingPrincipal();
        gross = gross > model.totalClaimable() ? gross - model.totalClaimable() : 0;
        assertEq(model.totalAssets() + model.effectiveUnreleasedYield(), gross, "released plus unreleased");
        assertLe(model.entryAssets(), model.depositCapUsage(), "effective book within stored book");
        assertLe(model.depositCapUsage(), model.entryAssets() + model.cashDeficit(), "stored book within deficit");
    }

    /// @dev Formerly `invariant_claimsAndYieldNeverBecomeLendable`.
    function testFuzz_pin_model_shareholderCashFormula(Book memory b) public {
        _seedModel(b);
        uint256 cash = model.effectiveCash();
        uint256 senior = model.totalClaimable() + model.effectiveUnreleasedYield();
        assertEq(model.shareholderCash(), cash > senior ? cash - senior : 0, "shareholderCash formula");
    }

    /// @dev Formerly `invariant_availableWithholdsOnlyTheYieldAdjustedNumericReserve`.
    function testFuzz_pin_model_availableFormula(Book memory b) public {
        _seedModel(b);
        uint256 cash = model.shareholderCash();
        uint256 required = model.requiredEntryAssets();
        uint256 unreleased = model.effectiveUnreleasedYield();
        uint256 reserve = required > unreleased ? required - unreleased : 0;
        uint256 expected = model.totalSupply() < model.minimumSupply() || model.claimLiquidityDeficit() != 0
            ? 0
            : cash > reserve ? cash - reserve : 0;
        assertEq(model.available(), expected, "available formula");
    }

    /// @dev Formerly `invariant_capUsageUsesTheWholeStoredGrossBook`.
    function testFuzz_pin_model_depositCapUsageFormula(Book memory b) public {
        _seedModel(b);
        uint256 gross = model.accountedCash() + model.outstandingPrincipal();
        gross = gross > model.totalClaimable() ? gross - model.totalClaimable() : 0;
        assertEq(model.depositCapUsage(), gross, "depositCapUsage formula");
    }

    /// @dev Formerly `invariant_claimSolvencyUsesCashAndOutstandingPrincipal`.
    function testFuzz_pin_model_claimSolvencyDeficitFormula(Book memory b) public {
        _seedModel(b);
        uint256 backing = model.effectiveCash() + model.outstandingPrincipal();
        uint256 claims = model.totalClaimable();
        assertEq(model.claimSolvencyDeficit(), claims > backing ? claims - backing : 0, "claimSolvencyDeficit formula");
    }

    /// @dev Formerly the formula half of `invariant_entryPriceDeficitAndTheQuotientBoundAreExact`;
    ///      the supply-ceiling clause stayed in the campaign as a guard.
    function testFuzz_pin_model_entryPriceDeficitFormula(Book memory b) public {
        _seedModel(b);
        uint256 target = model.totalClaimable() + model.requiredEntryAssets();
        uint256 cash = model.effectiveCash();
        uint256 expectedDeficit = target > cash ? target - cash : 0;
        assertEq(model.entryPriceDeficit(), expectedDeficit, "entryPriceDeficit formula");
        if (expectedDeficit == 0) {
            assertLe(model.requiredEntryAssets(), model.entryAssets(), "zero deficit implies the quotient bound");
            assertLe(
                Math.ceilDiv(model.totalSupply() + VIRTUAL, model.entryAssets() + 1),
                model.MAX_SHARES_PER_ASSET(),
                "zero deficit implies the share quotient bound"
            );
        }
    }

    // ── Seeding ───────────────────────────────────────────────────────────────────────────────

    function _store(address target, uint256 slot, uint256 value) private {
        vm.store(target, bytes32(slot), bytes32(value));
    }

    function _seedModel(Book memory b) private {
        _store(address(model), M_RAW, b.raw);
        _store(address(model), M_ACC, b.acc);
        _store(address(model), M_PRINCIPAL, b.principal);
        _store(address(model), M_CLAIMS, b.claims);
        _store(address(model), M_SUPPLY, b.supply);
        _store(address(model), M_PENDING, b.pending);
        _store(address(model), M_RATE, b.rate);
        _store(address(model), M_ACCRUAL, block.timestamp);
        _store(address(model), M_ENDS, block.timestamp + b.span);
        vm.warp(block.timestamp + b.elapsed);
    }

    /// @dev The balances mapping is kept consistent with the seeded supply and escrow, because
    ///      `balanceOf` is an input to the two maxima and a supply the holders do not add up to
    ///      would pin a formula over a book no `_update` can produce even in principle.
    function _seedPool(Book memory b, uint120 queuedSeed) private returns (uint256 queued) {
        queued = b.supply == 0 ? 0 : bound(uint256(queuedSeed), 0, b.supply);
        usdc.mint(address(pool), b.raw);
        _store(address(pool), P_ACC, b.acc);
        _store(address(pool), P_PRINCIPAL, b.principal);
        _store(address(pool), P_CLAIMS, b.claims);
        _store(address(pool), P_SUPPLY, b.supply);
        _store(address(pool), P_QUEUED, queued);
        _store(address(pool), P_PENDING, b.pending);
        _store(address(pool), P_RATE, b.rate);
        _store(address(pool), P_ACCRUAL, block.timestamp);
        _store(address(pool), P_ENDS, block.timestamp + b.span);
        vm.store(address(pool), keccak256(abi.encode(actor, P_BALANCES)), bytes32(uint256(b.supply) - queued));
        vm.store(address(pool), keccak256(abi.encode(address(pool), P_BALANCES)), bytes32(queued));
        vm.warp(block.timestamp + b.elapsed);
    }

    function _accountedCash(uint256 raw) private view returns (uint256) {
        return raw + pool.cashDeficit() - pool.unmanagedSurplus();
    }

    function _effectiveAndClaims() private view returns (uint256 effective, uint256 claims) {
        uint256 raw = usdc.balanceOf(address(pool));
        uint256 accounted = _accountedCash(raw);
        effective = raw < accounted ? raw : accounted;
        claims = pool.totalClaimable();
    }

    /// @dev `_effectiveUnreleasedYield` as the pool writes it: the deficit consumes the tail first
    ///      and the shareholder gross book caps what is left.
    function _effectiveYield(uint256 effective, uint256 claims) private view returns (uint256 effectiveYield) {
        uint256 unreleased = pool.unreleasedYield();
        uint256 deficit = pool.cashDeficit();
        effectiveYield = unreleased > deficit ? unreleased - deficit : 0;
        uint256 gross = effective + pool.outstandingPrincipal();
        uint256 shareholderGross = gross > claims ? gross - claims : 0;
        if (effectiveYield > shareholderGross) effectiveYield = shareholderGross;
    }
}
