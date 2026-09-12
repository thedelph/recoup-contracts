// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice The ONE thing `DeployBase`'s seam docstring says has no test: that the base
///         implementations reach the process environment at all.
///
/// @dev 🟥 **This contract deliberately does NOT override either seam**, which is the whole point
///      and is also what it costs. The round-49 item-136 environment census
///      classes any test contract that inherits a script, resolves a seam to `direct`, and reaches
///      it as a REACHED DOOR, and refuses a reached door with no allowlist entry. So shipping this
///      probe costs exactly one `ENV_ALLOWLIST` line, whose reason is that this contract IS the
///      subject: it exists to prove the seam reads the environment, and it is keyed on
///      `R51A01_SEAM_PROBE`, which no deployment, no workflow and no runbook sets.
contract R51A01EnvSeamProbe is DeployBase {
    function probeAddress(string memory key, address fallbackValue) external view returns (address) {
        return _envOrAddress(key, fallbackValue);
    }

    function probeString(string memory key, string memory fallbackValue) external view returns (string memory) {
        return _envOrString(key, fallbackValue);
    }
}

/// @notice Round-51 item 170, A2 row 7: `DeployBase._envOrAddress`'s own `vm.envOr` line is reached
///         by no test, and the file records that as a residual with "no test for it, on purpose"
///         because the only way it saw to assert it was `vm.setEnv`.
///
/// @dev **There is a second way, and it needs neither `vm.setEnv` nor a `vm.env*` call in a test.**
///      Ask the seam TWICE for the same key with two DIFFERENT fallbacks:
///
///        - if the key is unset, the two answers are the two fallbacks and they DIFFER;
///        - if the key is set, the two answers are the same value and it is neither fallback.
///
///      The two branches are exhaustive, both are asserted, and which one runs is decided by the
///      process the operator launched - so this file is green in CI with nothing set, and green on a
///      run that sets `R51A01_SEAM_PROBE`, and the SECOND branch is the assertion the residual said
///      could not be written.
///
///      MEASURED both ways. `vm.setEnv` does not appear in this file and the round-49 item-136
///      census would refuse it if it did.
contract R51A01EnvSeamTest is Test {
    R51A01EnvSeamProbe internal probe;

    /// @dev A key no deployment, workflow, runbook or `.env` in this repository sets. Grep-checked.
    string internal constant KEY = "R51A01_SEAM_PROBE";
    string internal constant STRING_KEY = "R51A01_SEAM_PROBE_STRING";

    address internal constant FALLBACK_A = address(0xA11CE);
    address internal constant FALLBACK_B = address(0xB0B);

    function setUp() public {
        probe = new R51A01EnvSeamProbe();
    }

    /// @notice The residual, closed: the address seam's body reads the process environment.
    function test_R51A01_170_theAddressSeamReadsTheProcessEnvironment() public {
        address a = probe.probeAddress(KEY, FALLBACK_A);
        address b = probe.probeAddress(KEY, FALLBACK_B);

        if (a == FALLBACK_A && b == FALLBACK_B) {
            // Branch one: the key is unset. All this arm proves is that the seam answers with its
            // fallback, which is what every hermetic override in this repository also does - so it
            // is stated as what it is rather than dressed up.
            emit log("R51A01_SEAM_PROBE is unset: the fallback branch ran, which proves nothing about vm.envOr");
            assertTrue(a != b, "two different fallbacks must give two different answers");
        } else {
            // Branch two: the key is set. Two calls with DIFFERENT fallbacks returned the SAME
            // address, so the answer cannot have come from either fallback. This is the assertion
            // the seam's docstring says has no test.
            assertEq(a, b, "the seam answered both calls with one value, so it read the environment");
            assertTrue(a != FALLBACK_A, "and that value is not the first fallback");
            assertTrue(a != FALLBACK_B, "nor the second");
            emit log_named_address("R51A01_SEAM_PROBE is set: vm.envOr reached the process environment", a);
        }
    }

    /// @notice The string half, which is the seam `R36DeployPathTest` still inherits raw and which
    ///         the shipped `ENV_ALLOWLIST` carries as its one open residual.
    function test_R51A01_170_theStringSeamReadsTheProcessEnvironment() public {
        string memory a = probe.probeString(STRING_KEY, "fallback-a");
        string memory b = probe.probeString(STRING_KEY, "fallback-b");
        bytes32 ha = keccak256(bytes(a));
        bytes32 hb = keccak256(bytes(b));

        if (ha == keccak256("fallback-a") && hb == keccak256("fallback-b")) {
            emit log("R51A01_SEAM_PROBE_STRING is unset: the fallback branch ran");
            assertTrue(ha != hb, "two different fallbacks must give two different answers");
        } else {
            assertEq(ha, hb, "the seam answered both calls with one value, so it read the environment");
            assertTrue(ha != keccak256("fallback-a"), "and it is not the first fallback");
            emit log_named_string("R51A01_SEAM_PROBE_STRING is set", a);
        }
    }
}

contract R51A01RecordGapScript is WirePhase4 {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    string private _record;

    function setEnvAddress(string memory key, address value) external {
        _addr[keccak256(bytes(key))] = value;
        _addrSet[keccak256(bytes(key))] = true;
    }

    function setRecord(string memory json) external {
        _record = json;
    }

    function _envOrAddress(string memory key, address fallbackValue) internal view override returns (address) {
        bytes32 k = keccak256(bytes(key));
        return _addrSet[k] ? _addr[k] : fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue)
        internal
        pure
        override
        returns (string memory)
    {
        return fallbackValue;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    function exposedResolveDeployed() external view returns (Deployed memory) {
        return _resolveDeployed();
    }

    function exposedResolveParamsAgainstRecord(address sender) external view returns (GovParams memory) {
        return _resolveParamsAgainstRecord(sender);
    }

    function exposedAssertCoreGraph(Deployed memory d, GovParams memory p) external view {
        _assertCoreGraph(d, p);
    }
}

/// @notice The mirror questions round 50's item-134 fix invites: what does `_resolveDeployed` do
///         when the record and the environment DISAGREE, when the record is SILENT, and what does
///         the round-50 decimals anchor do when the token will not answer.
///
/// @dev Three answers, all MEASURED:
///
///      1. **Disagreement**: the record wins and the disagreement is refused by name with BOTH
///         values (`DeployedEnvDisagreesWithRecord`). That is the shipped round-50 behaviour and it
///         is correct; it is re-measured here only so the negative is on the record.
///      2. **Silence**: a record that did not carry a `contracts.X` key fell STRAIGHT BACK to the
///         pre-fix, environment-only path (`_resolveOne` -> `if (!vm.keyExistsJson) return
///         _required(name)`), with no warning of any kind. So item 134's fix was exactly as strong
///         as the record's completeness, and the failure direction of an incomplete record was
///         SILENT REVERSION rather than refusal. That is `DeployedRecordRowMissing` now.
///      3. **A token that will not answer `decimals()`**: the round-50 anchor in `_assertCoreGraph`
///         reverts with the token's own empty revert rather than a named error, on ALL FOUR
///         `WirePhase4` entry points including the read-only health report. Recorded, not fixed:
///         see the test for why it is LOW and what it would cost.
contract R51A01RecordGapsTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal treasury = makeAddr("r51a01.g.treasury");
    address internal feeWallet = makeAddr("r51a01.g.feeWallet");
    address internal keeper = makeAddr("r51a01.g.keeper");
    address internal navConfirmer = makeAddr("r51a01.g.navConfirmer");
    address internal stranger = makeAddr("r51a01.g.stranger");
    address internal guardian = makeAddr("r51a01.g.guardian");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    R51A01RecordGapScript internal script;

    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue)
        internal
        pure
        override
        returns (string memory)
    {
        return fallbackValue;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(BASE_SEPOLIA);
        script = new R51A01RecordGapScript();
    }

    function _externals() internal view returns (Externals memory) {
        return Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });
    }

    function _params() internal view returns (GovParams memory) {
        return GovParams({
            owner: address(this),
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: feeWallet,
            guardian: guardian
        });
    }

    function _generation() internal returns (Deployed memory) {
        return _deployProtocol(_externals(), _params(), address(this));
    }

    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', vm.toString(value), last ? '"' : '",');
    }

    /// @param omitAuction when true the record carries seven of the eight contract rows.
    function _recordFor(Deployed memory d, address recordOwner, bool omitAuction)
        internal
        pure
        returns (string memory)
    {
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(recordOwner), '"},'
        );
        string memory first = string.concat(
            '"contracts":{',
            _row("NAVOracle", address(d.oracle), false),
            _row("CollateralVault", address(d.vault), false),
            _row("DirectCallAdapter", address(d.adapter), false),
            _row("CreditManager", address(d.credit), false)
        );
        string memory second = string.concat(
            _row("LenderPool", address(d.pool), false),
            _row("TreasuryLiquiditySource", address(d.liquidity), false),
            omitAuction
                ? _row("EpochHarvester", address(d.harvester), true)
                : string.concat(
                    _row("EpochHarvester", address(d.harvester), false),
                    _row("LiquidationAuction", address(d.auction), true)
                ),
            "}}"
        );
        return string.concat(head, first, second);
    }

    function _installEnv(Deployed memory d) internal {
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
    }

    /// @notice Mirror answer 1, re-measured: the record wins and BOTH values are printed. Negative.
    function test_R51A01_mirror_theRecordWinsAndTheDisagreementNamesBothValues() public {
        Deployed memory d = _generation();
        script.setRecord(_recordFor(d, address(this), false));
        _installEnv(d);
        script.setEnvAddress("RECOUP_LENDER_POOL", stranger);

        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector, "RECOUP_LENDER_POOL", stranger, address(d.pool)
            )
        );
        script.exposedResolveDeployed();
    }

    /// @notice THE FINDING in this group, flipped. A record that is SILENT about a contract used to
    ///         revert to the pre-fix, environment-only path with no warning, so the environment
    ///         named whatever it liked for that member.
    /// @dev MEASURED. Seven of eight rows name the live generation; the eighth comes from a
    ///      SUPERSEDED one through `RECOUP_LIQUIDATION_AUCTION`. Before
    ///      `DeployedRecordRowMissing` the resolution returned the superseded auction with the other
    ///      seven off the record, silently - which is the whole of round-50 item 134 turned off for
    ///      that member. The auction is the member chosen because `_assertCoreGraph` reaches it
    ///      through the fewest `immutable`s, but the point is the branch, not the member.
    function test_R51A01_mirror_arecordSilentAboutAContractIsRefusedByName() public {
        Deployed memory live = _generation();
        Deployed memory stale = _generation();
        assertTrue(address(live.auction) != address(stale.auction), "premise: two generations");

        script.setRecord(_recordFor(live, address(this), true));
        _installEnv(live);
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(stale.auction));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.DeployedRecordRowMissing.selector,
                "RECOUP_LIQUIDATION_AUCTION",
                ".contracts.LiquidationAuction"
            )
        );
        script.exposedResolveDeployed();
    }

    /// @notice And the refusal is about the ROW, not about the environment disagreeing: the same
    ///         incomplete record is refused when the environment names the RIGHT address too.
    /// @dev This is the arm that separates `DeployedRecordRowMissing` from
    ///      `DeployedEnvDisagreesWithRecord`. Without it the test above would pass on a fix that
    ///      only tightened the disagreement check.
    function test_R51A01_mirror_anIncompleteRecordIsRefusedEvenWhenTheEnvironmentIsRight() public {
        Deployed memory live = _generation();
        script.setRecord(_recordFor(live, address(this), true));
        _installEnv(live);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.DeployedRecordRowMissing.selector,
                "RECOUP_LIQUIDATION_AUCTION",
                ".contracts.LiquidationAuction"
            )
        );
        script.exposedResolveDeployed();
    }

    /// @notice Control: with the row present, the environment's superseded value is refused by name
    ///         with both values. So the two failures are told apart rather than collapsed.
    function test_R51A01_mirror_control_withTheRowPresentTheSameValueIsRefusedAsADisagreement() public {
        Deployed memory live = _generation();
        Deployed memory stale = _generation();
        script.setRecord(_recordFor(live, address(this), false));
        _installEnv(live);
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(stale.auction));

        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector,
                "RECOUP_LIQUIDATION_AUCTION",
                address(stale.auction),
                address(live.auction)
            )
        );
        script.exposedResolveDeployed();
    }

    /// @notice And a complete record with an agreeing environment still resolves, so the new
    ///         refusal is not a refusal of everything.
    function test_R51A01_mirror_control_aCompleteRecordStillResolves() public {
        Deployed memory d = _generation();
        script.setRecord(_recordFor(d, address(this), false));
        _installEnv(d);

        Deployed memory got = script.exposedResolveDeployed();
        assertEq(address(got.auction), address(d.auction), "the eighth member came off the record");
        assertEq(address(got.credit), address(d.credit), "and so did the others");
    }

    /// @notice The ZERO address in a present row is still caught, so `_resolveOne`'s ordering is
    ///         right: the row check runs first, then the disagreement, then the zero. Negative.
    function test_R51A01_mirror_aZeroRowIsRefusedRatherThanResolvingToZero() public {
        Deployed memory d = _generation();
        Deployed memory zeroed = d;
        zeroed.pool = LenderPool(address(0));
        script.setRecord(_recordFor(zeroed, address(this), false));
        _installEnv(d);
        script.setEnvAddress("RECOUP_LENDER_POOL", address(0));

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressMissing.selector, "RECOUP_LENDER_POOL")
        );
        script.exposedResolveDeployed();
    }

    /// @notice N4, closed: a record with no `operators.owner` row used to die inside forge's JSON
    ///         parser rather than at a named error.
    /// @dev `_resolveParamsAgainstRecord` read `.operators.owner` with NO `keyExistsJson` guard,
    ///      unlike `_resolveOne` and `_requiredTimelock` which both had one. Small, and it is the
    ///      same class as `OwnerNotNamedForReport`, which exists two functions away precisely
    ///      because "a health report inventing a wiring failure out of an unset variable" was judged
    ///      worth its own error.
    function test_R51A01_mirror_arecordWithNoOwnerRowIsRefusedByName() public {
        Deployed memory d = _generation();
        string memory noOwner = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{},',
            '"contracts":{', _row("NAVOracle", address(d.oracle), true), "}}"
        );
        script.setRecord(noOwner);
        _installEnv(d);
        // The five operator addresses `_resolveParams` requires off the local chain, so this test
        // reaches the row check rather than stopping at `YieldRecipientRequired` - which is what it
        // did on the first run, and is why they are installed explicitly rather than assumed.
        script.setEnvAddress("RECOUP_OWNER", address(this));
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.DeployedRecordRowMissing.selector, "RECOUP_OWNER", ".operators.owner"
            )
        );
        script.exposedResolveParamsAgainstRecord(address(this));
    }

    /// @notice Mirror answer 3, recorded in round 51 and FIXED in round 52 (round-52 item 167): the
    ///         round-50 decimals anchor used to take the whole census down with an undecodable revert
    ///         when the token's `decimals()` reverted, on the read-only health report as well as on
    ///         the three broadcast entry points. It now refuses by name,
    ///         `UsdcDecimalsUnreadable(token)`, through `DeployBase._settlementDecimals`.
    /// @dev MEASURED with `vm.mockCallRevert`. `decimals()` is OPTIONAL in ERC-20, so this is not a
    ///      hypothetical shape. What made it LOW rather than higher is that the settlement token is
    ///      `immutable` on six members and `Config.USDC_BASE` is a real six-decimal token, so the
    ///      state needs a deployment nobody would make - or a fork or RPC on the wrong chain, which
    ///      is the reachable operator case. The cost was legibility.
    ///
    ///      🟥 **This test used a bare `vm.expectRevert()` when it was written, and that pinned
    ///      nothing: it stayed GREEN through the fix**, because a named refusal is also a revert. A
    ///      pin of an open finding has to assert the SHAPE of the failure it records, or it cannot
    ///      tell the fix from the defect. It now asserts the named error, so reverting the fix turns
    ///      it red. Round 51 also proposed `try/catch` as the fix and that was the wrong shape:
    ///      `try` catches the revert and not the no-data answer, which
    ///      `R52A01_DecimalsUnreadable.t.sol` executes as its sign-check.
    function test_R51A01_mirror_aTokenThatWillNotAnswerDecimalsTakesTheWholeCensusDown() public {
        Deployed memory d = _generation();
        // Premise: the census passes on the unmocked graph.
        script.exposedAssertCoreGraph(d, _params());

        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20Metadata.decimals, ()), "");
        vm.expectRevert(abi.encodeWithSelector(DeployBase.UsdcDecimalsUnreadable.selector, address(usdc)));
        script.exposedAssertCoreGraph(d, _params());
    }
}
