// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Config} from "../../src/Config.sol";
import {RiskParams} from "../../src/RiskParams.sol";
import {IRiskParams} from "../../src/interfaces/IRiskParams.sol";

/// @title RiskParamsFixture
/// @notice The one place a test derives a figure from a risk parameter.
/// @dev **Why this exists, and why the obvious shapes are wrong.**
///
///      The suite used to write borrowing power down as a literal. `MAX_BORROW = 880.25e6` was
///      35% of $2,515 and correct until the capped-beta parameters landed on 2026-08-07, at which
///      point 53 of 61 tests in one file and 14 in another failed at the fixture rather than in
///      the code under test. The fix was to derive from `Config` instead - which was better, and
///      is exactly what stopped working the moment those constants became storage, because a
///      Solidity `constant` cannot read a storage slot.
///
///      Two shapes are available and both are traps:
///
///      - `immutable` assigned in `setUp()` does not compile. Immutables must be assigned in the
///        constructor, and every fixture in this suite deploys its protocol in `setUp()`.
///      - A plain storage variable cached in `setUp()` compiles, and is wrong in precisely the
///        tests this change adds. Any test that moves a parameter partway through would then
///        compute its expected values from a snapshot taken before the move, and pass. That is
///        this repo's own "the dangerous literal is the one that keeps passing", one level of
///        abstraction up.
///
///      So the accessors below are `view` and re-read on every call. A value change needs no edit
///      at all, a mid-test parameter move is reflected immediately, and because everything binds
///      to `IRiskParams` rather than to a contract, moving the authority later is one line per
///      fixture instead of a rewrite of every derivation.
abstract contract RiskParamsFixture is Test {
    /// @dev Each fixture points this at whatever its own `setUp` deployed.
    function _riskParams() internal view virtual returns (IRiskParams);

    /// @dev The account that may call the setter. Fork fixtures return `address(0)` and skip the
    ///      inherited detector below, matching how they already self-skip.
    function _riskParamsOwner() internal view virtual returns (address);

    /// @notice A `RiskParams` at the declared launch defaults, owned by `owner`.
    /// @dev Every fixture in the suite builds one this way rather than writing the four values
    ///      out, so a change to the defaults moves the whole suite and no fixture can quietly
    ///      test against a configuration the deploy script would never produce.
    function _deployRiskParams(address owner) internal returns (RiskParams) {
        return new RiskParams(
            IRiskParams.Params({
                maxLtvBps: uint16(Config.DEFAULT_MAX_LTV_BPS),
                liquidationThresholdBps: uint16(Config.DEFAULT_LIQUIDATION_THRESHOLD_BPS),
                globalBorrowCap: uint64(Config.DEFAULT_GLOBAL_BORROW_CAP),
                perAccountBorrowCap: uint64(Config.DEFAULT_PER_ACCOUNT_BORROW_CAP)
            }),
            owner
        );
    }

    // ── The live parameters ──────────────────────────────────────────────────

    function maxLtvBps() internal view returns (uint256) {
        return _riskParams().maxLtvBps();
    }

    function liquidationThresholdBps() internal view returns (uint256) {
        return _riskParams().liquidationThresholdBps();
    }

    function globalBorrowCap() internal view returns (uint256) {
        return _riskParams().globalBorrowCap();
    }

    function perAccountBorrowCap() internal view returns (uint256) {
        return _riskParams().perAccountBorrowCap();
    }

    // ── The derivations ──────────────────────────────────────────────────────
    //
    // Seven fixtures kept seven copies of the first of these. One copy means one place to be
    // wrong, and one place to fix when the next ratchet step lands.

    /// @notice Borrowing power at the ceiling: bonds x NAV x maxLTV, in USDC 6dp.
    function _maxBorrow(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return (bonds * nav * maxLtvBps()) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
    }

    /// @notice The NAV at which `debt` against `bonds` sits exactly on the liquidation threshold.
    /// @dev Everything below is liquidatable and everything above is not, so a scenario NAV chosen
    ///      either side of this cannot drift to the wrong side of its own premise when the
    ///      parameters move.
    function _navAtThreshold(uint256 debt, uint256 bonds) internal view returns (uint256) {
        return (debt * Config.BPS * Config.USDC_TO_NAV_SCALE) / (liquidationThresholdBps() * bonds);
    }

    /// @notice The NAV at which the lot is worth exactly the debt: a fill at 100% of NAV covers
    ///         the loan and not a cent more.
    function _navAtDebtParity(uint256 debt, uint256 bonds) internal pure returns (uint256) {
        return (debt * Config.USDC_TO_NAV_SCALE) / bonds;
    }

    /// @notice The debt that sits exactly on the threshold for `bonds` at `nav`.
    function _debtAtThreshold(uint256 bonds, uint256 nav) internal view returns (uint256) {
        return ((bonds * nav / Config.USDC_TO_NAV_SCALE) * liquidationThresholdBps()) / Config.BPS;
    }

    /// @notice The worst LTV at which a liquidation can first be triggered.
    /// @dev One immediate maximum NAV drop applied to a position sitting on the threshold. The
    ///      drop is derived from what `NAVOracle` actually accepts without a second key - the
    ///      deviation budget prorated over the maximum elapsed window - rather than from
    ///      `NAV_MAX_DEVIATION_BPS` directly. Those were the same number until
    ///      `NAV_DEVIATION_MAX_ELAPSED` was introduced, at which point the real bound tripled and
    ///      the guard test kept passing because it was pinned to the assumption.
    function _worstFirstTriggerLtvBps() internal view returns (uint256) {
        uint256 maxDropBps =
            (Config.NAV_MAX_DEVIATION_BPS * Config.NAV_DEVIATION_MAX_ELAPSED) / Config.NAV_DEVIATION_WINDOW;
        return (liquidationThresholdBps() * Config.BPS) / (Config.BPS - maxDropBps);
    }

    /// @notice The smallest auction floor that still covers debt plus penalty at that worst LTV.
    function _requiredFloorBps() internal view returns (uint256) {
        return (_worstFirstTriggerLtvBps() * (Config.BPS + Config.LIQUIDATION_PENALTY_BPS)) / Config.BPS;
    }

    // ── The detector ─────────────────────────────────────────────────────────

    /// @notice A derivation in this suite still follows the live parameter.
    /// @dev **This is the decay detector for the fixture itself, and it is inherited on purpose.**
    ///
    ///      Ask the question this repo asks of every guard: could it sit at its best value while
    ///      the thing it stands for goes to zero? Yes. Someone re-freezing one derivation into a
    ///      cached variable - for a plausible-looking reason, in one file - leaves every test in
    ///      the suite green while that fixture silently pins a parameter again, which is the exact
    ///      failure that cost 69 tests once already.
    ///
    ///      Being inherited means it runs once per fixture rather than once for the suite, so the
    ///      failure lands in the file where the re-freeze happened rather than somewhere that has
    ///      to be traced back to it.
    function test_fixtureDerivationsFollowALiveParameterChange() public {
        address owner = _riskParamsOwner();
        if (owner == address(0)) {
            vm.skip(true);
            return;
        }

        uint256 bonds = 100;
        uint256 nav = 25.15e8;
        uint256 before = _maxBorrow(bonds, nav);
        assertGt(before, 0, "the fixture derives nothing, so it cannot be shown to derive it live");

        IRiskParams.Params memory p = _riskParams().params();
        uint256 halved = uint256(p.maxLtvBps) / 2;
        // Stay inside the contract's own bounds, so this exercises the fixture rather than the
        // setter's validation. If halving would go under the floor, raise instead: the direction
        // does not matter, only that the derivation moves with it.
        p.maxLtvBps = halved >= 500 ? uint16(halved) : uint16(uint256(p.maxLtvBps) + 500);

        vm.prank(owner);
        _riskParams().setRiskParams(p);

        uint256 expected = (bonds * nav * p.maxLtvBps) / (Config.BPS * Config.USDC_TO_NAV_SCALE);
        assertEq(_maxBorrow(bonds, nav), expected, "a derivation stopped reading the live value");
        assertTrue(_maxBorrow(bonds, nav) != before, "the parameter did not actually move");
    }
}
