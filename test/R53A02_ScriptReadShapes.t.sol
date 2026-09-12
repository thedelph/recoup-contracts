// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {DeployBase, IMockLockdownView} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice `AssertMockStackLocked` with the record seam closed and both environment reads hermetic,
///         plus the faucet probe exposed on its own.
contract R53A02LockedProbe is AssertMockStackLocked {
    string private _record;

    function setRecord(string memory json) external {
        _record = json;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

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

    function exposedAssertFaucetOpen(address bond, address usdc) external {
        Stack memory s;
        s.bond = bond;
        s.usdc = usdc;
        _assertFaucetOpen(s);
    }
}

/// @notice `WirePhase4` with both seams and the record closed.
contract R53A02ShapeScript is WirePhase4 {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    mapping(bytes32 => string) private _str;
    mapping(bytes32 => bool) private _strSet;
    string private _record;

    function setEnvAddress(string memory key, address value) external {
        bytes32 k = keccak256(bytes(key));
        _addr[k] = value;
        _addrSet[k] = true;
    }

    function setEnvString(string memory key, string memory value) external {
        bytes32 k = keccak256(bytes(key));
        _str[k] = value;
        _strSet[k] = true;
    }

    function setRecord(string memory json) external {
        _record = json;
    }

    function _envOrAddress(string memory key, address fallbackValue) internal view override returns (address) {
        bytes32 k = keccak256(bytes(key));
        return _addrSet[k] ? _addr[k] : fallbackValue;
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        override
        returns (string memory)
    {
        bytes32 k = keccak256(bytes(key));
        return _strSet[k] ? _str[k] : fallbackValue;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }
}

/// @notice The mirror of round-52 item 167, asked of every other low-level read in `contracts/script/`.
///
/// @dev `_settlementDecimals` (round 52) decodes the returned word as a `uint256` and range-checks it,
///      so a 32-byte answer that is not a `uint8` is refused BY NAME. `_answersWithItself` (round 46)
///      compares the word as `bytes32` for the same reason, and its docstring says why: an
///      `abi.decode(ret, (address))` on a word with dirty high bits reverts the whole assertion
///      with EMPTY data. **Six other readers in `contracts/script/` check `ok` and `length == 32`
///      and then `abi.decode` as `address` or `bool`, and the ninth reader, `_ownablesOf`, checks
///      the length and never decodes at all, leaving the decode to the high-level `owner()` one
///      call later.** Every one of them survives a reverting callee and a no-data callee by name,
///      and dies EMPTY on the third shape: a coded contract at the recorded address that answers
///      the selector with a word that is not the type asked for. That is "the wrong contract at
///      the row" - a selector collision on some other contract, or a proxy answering for the
///      wrong implementation - and it is the case the two named refusals were written for.
///
///      Every claim MEASURED. Three tests here PINNED OPEN the empty revert while this file was a
///      PoC; round 53's contracts wave shipped the range-checked decodes (`_asAddress`, `_bool` to
///      {0,1}, one check in `_ownablesOf`) and promoted this file, rewriting those three to assert
///      the named errors. `R53A02_MirrorFixes.t.sol` asserts the same fixes from the other side.
contract R53A02ScriptReadShapesTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;
    /// @dev A word whose low 160 bits are a real address and whose high 96 bits are not zero.
    uint256 internal constant DIRTY_HIGH_BITS = uint256(1) << 200;

    address internal treasury = makeAddr("r53a02.shape.treasury");
    address internal feeWallet = makeAddr("r53a02.shape.feeWallet");
    address internal keeper = makeAddr("r53a02.shape.keeper");
    address internal navConfirmer = makeAddr("r53a02.shape.navConfirmer");
    address internal guardian = makeAddr("r53a02.shape.guardian");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

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
    }

    // ── AssertLocked: a locked stack whose `admin()` answers a dirty word ──────────────────────

    /// @dev A fully locked, correctly configured stack plus a probe whose record names it. The
    ///      `contracts.*` rows point at the farm, which holds code, is whitelisted and is not
    ///      blocked, so the whole entry point is green on the control.
    function _lockedStack() internal returns (R53A02LockedProbe probe, MockUSDC u, MockBond b, MockFarm f) {
        probe = new R53A02LockedProbe();
        u = new MockUSDC();
        b = new MockBond();
        f = new MockFarm(b, u);
        address lockKeeper = address(0xC0FFEE);
        u.lockTo(address(this), lockKeeper);
        b.lockTo(address(this), lockKeeper);
        f.lockTo(address(this), lockKeeper);
        b.setRewardPool(address(f));
        b.setWhitelisted(address(f), true);
        probe.setRecord(
            string.concat(
                '{"chainId":', vm.toString(BASE_SEPOLIA), ',"deployer":"', vm.toString(address(this)), '",',
                '"operators":{"keeper":"', vm.toString(lockKeeper), '"},',
                '"mocks":{"MockUSDC":"', vm.toString(address(u)), '","MockBond":"', vm.toString(address(b)),
                '","MockFarm":"', vm.toString(address(f)), '"},',
                '"contracts":{"CollateralVault":"', vm.toString(address(f)), '","DirectCallAdapter":"',
                vm.toString(address(f)), '"},"seededPosition":{"bonds":0}}'
            )
        );
    }

    /// @notice Control: the fixture passes the whole entry point.
    function test_R53A02_shape_control_theLockedStackPassesTheEntryPoint() public {
        (R53A02LockedProbe probe,,,) = _lockedStack();
        probe.assertLockedOnChain();
    }

    /// @notice FIXED in round 53 (was PINS OPEN, asserting an EMPTY revert). `MockUSDC.admin()`
    ///         answering a 32-byte word with dirty high bits: `_readAddress` saw `ok` and
    ///         `length == 32` and `abi.decode(ret, (address))` reverted EMPTY, telling the operator
    ///         nothing. `_asAddress` now range-checks the word and names it `PreLockdownBytecode`,
    ///         the same way a short answer always was.
    /// @dev `_report` runs first and its `_printOrAbsent` decoded the same way, so the death was in
    ///      the REPORTING half before any assertion ran; it now prints the wrong-contract line and
    ///      the assertion half raises the named error.
    function test_R53A02_shape_aDirtyAdminWordIsNamedPreLockdownBytecode() public {
        (R53A02LockedProbe probe, MockUSDC u,,) = _lockedStack();
        vm.mockCall(
            address(u),
            abi.encodeWithSelector(IMockLockdownView.admin.selector),
            abi.encode(DIRTY_HIGH_BITS | uint256(uint160(address(this))))
        );

        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.PreLockdownBytecode.selector, "MockUSDC", address(u), "admin()")
        );
        probe.assertLockedOnChain();
    }

    /// @notice Negative, recorded: the same word one byte SHORTER is named `PreLockdownBytecode`, so the
    ///         length check does its job and only the decode is unguarded.
    function test_R53A02_shape_negative_aShortAdminAnswerIsNamed() public {
        (R53A02LockedProbe probe, MockUSDC u,,) = _lockedStack();
        vm.mockCall(address(u), abi.encodeWithSelector(IMockLockdownView.admin.selector), hex"00");

        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.PreLockdownBytecode.selector, "MockUSDC", address(u), "admin()")
        );
        probe.assertLockedOnChain();
    }

    /// @notice FIXED in round 53 (was PINS OPEN, asserting an EMPTY revert). `_bool`:
    ///         `whitelistContains(farm)` answering `2` - a word that is 32 bytes and not a `bool` -
    ///         died EMPTY inside `_assertConfigurationPristine`, after every named assertion had
    ///         passed. `_bool` now range-checks to {0,1} and names it `PreLockdownBytecode`.
    function test_R53A02_shape_aNonBoolWhitelistAnswerIsNamedPreLockdownBytecode() public {
        (R53A02LockedProbe probe,, MockBond b, MockFarm f) = _lockedStack();
        vm.mockCall(
            address(b), abi.encodeWithSignature("whitelistContains(address)", address(f)), abi.encode(uint256(2))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.PreLockdownBytecode.selector, "config read", address(b), "bool getter"
            )
        );
        probe.assertLockedOnChain();
    }

    /// @notice Negative, recorded: the faucet probe alone passes over a CODELESS bond, because a plain
    ///         `call` to an address with no code succeeds. It is not reachable in that state through
    ///         the entry point, because `_assertOne`'s `_readAddress` refuses a codeless mock by name
    ///         first; the ordering is the guard, and this pins that the probe itself is not one.
    function test_R53A02_shape_negative_theFaucetProbeAloneIsBlindToACodelessBond() public {
        R53A02LockedProbe probe = new R53A02LockedProbe();
        address nothing = makeAddr("r53a02.codeless.bond");
        assertEq(nothing.code.length, 0, "premise: no code");
        probe.exposedAssertFaucetOpen(nothing, nothing);
    }

    // ── WirePhase4: a member of `Deployed` whose `owner()` answers a dirty word ─────────────────

    function _externals() internal view returns (Externals memory) {
        return Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
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

    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', vm.toString(value), last ? '"' : '",');
    }

    function _healthReport() internal returns (R53A02ShapeScript script, Deployed memory d) {
        d = _deployProtocol(_externals(), _params(), address(this));
        _wirePhase4(d);
        _assertPhase4Wiring(d, _params());
        script = new R53A02ShapeScript();
        script.setEnvAddress("RECOUP_OWNER", address(this));
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(address(this)), '"},'
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
            _row("EpochHarvester", address(d.harvester), false),
            _row("LiquidationAuction", address(d.auction), true),
            "}}"
        );
        script.setRecord(string.concat(head, first, second));
    }

    /// @notice Control: the switched-over graph passes the health report.
    function test_R53A02_shape_control_theHealthReportPasses() public {
        (R53A02ShapeScript script,) = _healthReport();
        script.assertOnly();
    }

    /// @notice FIXED in round 53 (was PINS OPEN, asserting an EMPTY revert). A record row naming a
    ///         coded contract whose `owner()` answers a dirty word: `_ownablesOf` accepted it (`ok`,
    ///         32 bytes, never decoded) and the high-level `Ownable(member).owner()` one call later
    ///         died EMPTY. `_ownablesOf` now range-checks the word it already holds and names the
    ///         row `DeployedMemberNotOwnable(i)`, the error written for exactly "this row is not an
    ///         Ownable of ours"; `d.liquidity` is index 6.
    function test_R53A02_shape_aDirtyOwnerWordIsNamedByIndex() public {
        (R53A02ShapeScript script, Deployed memory d) = _healthReport();
        vm.mockCall(
            address(d.liquidity),
            abi.encodeWithSelector(Ownable.owner.selector),
            abi.encode(DIRTY_HIGH_BITS | uint256(uint160(address(this))))
        );

        vm.expectRevert(abi.encodeWithSelector(DeployBase.DeployedMemberNotOwnable.selector, 6));
        script.assertOnly();
    }

    /// @notice Negative, recorded: the same member answering `owner()` with NO data is named by index,
    ///         so the length check in `_ownablesOf` does its job and only the decode is unguarded.
    function test_R53A02_shape_negative_aNoDataOwnerAnswerIsNamedByIndex() public {
        (R53A02ShapeScript script, Deployed memory d) = _healthReport();
        vm.mockCall(address(d.liquidity), abi.encodeWithSelector(Ownable.owner.selector), "");

        vm.expectPartialRevert(DeployBase.DeployedMemberNotOwnable.selector);
        script.assertOnly();
    }
}
