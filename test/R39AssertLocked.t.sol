// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockLockdown} from "./mocks/MockLockdown.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice The harness `AssertLocked.s.sol`'s `_readRecord` docstring said already existed.
///
/// @dev 🟥 **It did not exist, and the docstring claimed it in the present tense.** Audit round 39
///      measured that `_readRecord` is `virtual` with **zero overrides**, that no Solidity file
///      outside `AssertLocked.s.sol` mentions any of its members, and that because the live Base
///      Sepolia stack fails at the FIRST assertion - the bytecode predates the lockdown gate - four
///      of the entrypoint's five assertion groups had never been executed by anything at all.
///      `_assertStackAgrees`, `_assertGateRefuses`, `_assertFaucetOpen` and
///      `_assertConfigurationPristine` were written, shipped, and unreached.
///
///      That is the same shape as the finding the entrypoint exists to fix, one level down: a check
///      that reports on a thing it cannot see, beside a check nothing runs.
///
/// @dev The seam works exactly as its docstring describes: `_readRecord()` is overridden to return
///      an inline JSON string built from the mocks this test deploys, so `forge test` touches no
///      filesystem and needs no `fs_permissions` grant. The real run reads the file.
contract R39AssertLockedHarness is AssertMockStackLocked {
    string private _record;
    mapping(bytes32 => address) private _addressOverride;
    mapping(bytes32 => bool) private _addressOverridden;

    function setRecord(string memory json) external {
        _record = json;
    }

    /// @dev Same two-argument shape as `EnvOverridable.setEnvAddress` in `Deploy.t.sol`, so a
    ///      call site reads like the `vm.setEnv` it replaces, and for the same reason: `forge
    ///      test` contains no `vm.setEnv` and must stay that way.
    function setEnvAddress(string memory key, address value) external {
        bytes32 k = keccak256(bytes(key));
        _addressOverride[k] = value;
        _addressOverridden[k] = true;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    /// @dev 🟥 **Defaults to the FALLBACK and never to `super`, which is what makes this harness
    ///      hermetic and is the one place it differs from `EnvOverridable`.** Round-47 item 95:
    ///      the entrypoint read `RECOUP_KEEPER` over the record, forge auto-loads `contracts/.env`
    ///      into every `forge test`, and `.env` on the machine that runs deploys sets that key.
    ///      MEASURED before this override, with `RECOUP_KEEPER=0x...BEEF` in a `.env` beside the
    ///      worktree's `foundry.toml`: 4 of this file's 7 tests went red as
    ///      `MockOperatorNotKeeper("MockUSDC", 0xC0FFEE, 0xBEEF)`, so the harness result was a
    ///      property of the box. An override that fell through to `super` would still be.
    function _envOrAddress(string memory key, address fallbackValue) internal view override returns (address) {
        bytes32 k = keccak256(bytes(key));
        if (_addressOverridden[k]) return _addressOverride[k];
        return fallbackValue;
    }
}

contract R39AssertLockedTest is Test {
    R39AssertLockedHarness internal probe;

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant ROLELESS = address(0xBAD);

    /// @dev 🟥 **These were `address(0xFA017)` and `address(0xADA97E)`, two literals with NO CODE,
    ///      and round-51 item 150's second lead is that the entrypoint was green over them.** The
    ///      record's two `contracts.*` rows were parsed and then used only as arguments to
    ///      `bond.whitelistContains(...)` and `usdc.blocked(...)`, so nothing ever asked whether
    ///      either address held code - and this fixture, which is the only thing that executes four
    ///      of the five assertion groups, could not have told the two states apart. They are
    ///      deployed contracts now. `assertLockedOnChain()` refuses a codeless row by name since
    ///      round 51, so leaving them as literals would turn this whole suite red.
    address internal vaultRow;
    address internal adapterRow;

    function setUp() public {
        probe = new R39AssertLockedHarness();
        vaultRow = address(new NoLockdownSurface());
        adapterRow = address(new NoLockdownSurface());

        // Deployed and locked BY THIS TEST CONTRACT, so `admin`, `lockAuthority` and the record's
        // `deployer` are all `address(this)` - which is what a correct deploy produces.
        usdc = new MockUSDC();
        usdc.lockTo(address(this), KEEPER);
        bond = new MockBond();
        bond.lockTo(address(this), KEEPER);
        farm = new MockFarm(bond, usdc);
        farm.lockTo(address(this), KEEPER);

        bond.setRewardPool(address(farm));
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(adapterRow, true);

        probe.setRecord(_json());
    }

    /// @dev Built at run time because the mock addresses are not known until they are deployed.
    ///      `chainId` is 31337 so the entrypoint's first assertion, which refuses a record aimed at
    ///      a different chain, passes rather than short-circuiting everything behind it.
    function _json() internal view returns (string memory) {
        return _jsonFor(address(usdc), KEEPER);
    }

    /// @notice The whole entrypoint, against a correctly locked stack.
    /// @dev This is the assertion that was missing. Every group runs here, including the three that
    ///      the live chain can never reach because it fails at `PreLockdownBytecode` first.
    function test_R39_theEntrypointPassesOverACorrectlyLockedStack() public {
        probe.assertLockedOnChain();
    }

    /// @dev 🟥 **The probe that makes this file worth more than a re-read.** Reading `admin()`
    ///      proves a storage slot is set; it does not prove the deployed bytecode gates anything,
    ///      which is the live stack's exact condition. Here the slot is set AND the gate works, so
    ///      the only way to break this is to break the gate.
    function test_R39_theGateRefusesARoleLessCaller() public {
        vm.prank(ROLELESS);
        vm.expectRevert(abi.encodeWithSelector(MockLockdown.MockLocked.selector, ROLELESS));
        farm.seedStakeFor(ROLELESS, 1);

        vm.prank(ROLELESS);
        vm.expectRevert(abi.encodeWithSelector(MockLockdown.MockLocked.selector, ROLELESS));
        usdc.setBlocked(ROLELESS, true);
    }

    /// @dev A locked stack that is also a broken testnet is not a success. The faucet is the whole
    ///      reason the mocks are on a public chain.
    function test_R39_theFaucetIsStillOpenAfterTheLockdown() public {
        vm.startPrank(ROLELESS);
        bond.mint(ROLELESS, 5);
        usdc.mint(ROLELESS, 1e6);
        vm.stopPrank();
        assertEq(bond.bondBalance(ROLELESS), 5, "bond faucet open");
        assertEq(usdc.balanceOf(ROLELESS), 1e6, "usdc faucet open");
        probe.assertLockedOnChain();
    }

    /// @dev The half the lock reorder does NOT close: a write made inside the remaining
    ///      one-transaction window is permanent and survives the lockdown. The admin can still make
    ///      it, which is what lets this test create the condition the entrypoint must catch.
    function test_R39_aTamperedConfigurationIsRefused() public {
        bond.setWhitelisted(adapterRow, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.ConfigurationTampered.selector,
                "the adapter is not whitelisted - an unfinished broadcast (try --resume) or a tamper"
            )
        );
        probe.assertLockedOnChain();
    }

    /// @dev A stack locked to a stranger. `admin` is set, so the naive read passes; the record says
    ///      it should be this contract.
    function test_R39_aStackLockedToSomebodyElseIsRefused() public {
        MockUSDC other = new MockUSDC();
        other.lockTo(ROLELESS, KEEPER);
        probe.setRecord(_jsonWith(address(other)));
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.MockAdminWrong.selector, "MockUSDC", ROLELESS, address(this)
            )
        );
        probe.assertLockedOnChain();
    }

    /// @dev The condition the LIVE deployment is in: bytecode that predates the lockdown gate, so
    ///      `admin()` does not exist. Modelled with a plain contract that has no such function.
    function test_R39_preLockdownBytecodeIsNamedRatherThanBubbled() public {
        address bare = address(new NoLockdownSurface());
        probe.setRecord(_jsonWith(bare));
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.PreLockdownBytecode.selector, "MockUSDC", bare, "admin()"
            )
        );
        probe.assertLockedOnChain();
    }

    /// @notice 🟥 **THE TEST THAT GIVES THE REFUSAL PROBE ITS REASON TO EXIST.**
    /// @dev Reading `admin()` proves a STORAGE SLOT is set. It does not prove the deployed bytecode
    ///      GATES anything, and the difference is not hypothetical - it is the live Base Sepolia
    ///      stack's exact condition, where audit round 38 measured five configuration setters
    ///      succeeding from a role-less address.
    ///
    ///      `LooksLockedButIsNot` below is that condition in miniature: every read the entrypoint
    ///      makes answers correctly, so `_assertOne` and `_assertStackAgrees` both pass, and only
    ///      the probe catches it. **Delete `_assertGateRefuses` from `assertLockedOnChain()` and
    ///      this is the only test in the repository that goes red.**
    function test_R39_slotsSetButTheGateDoesNotRefuseIsCaught() public {
        LooksLockedButIsNot fake = new LooksLockedButIsNot(address(this), KEEPER);
        probe.setRecord(_jsonWith(address(fake)));
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.GateDoesNotRefuse.selector, "MockUSDC", address(fake)
            )
        );
        probe.assertLockedOnChain();
    }

    // ── the environment against the record (round-47 item 95) ────────────────

    /// @notice 🟥 **THE FALSIFIER. Before the fix this test's entrypoint call PASSED against a
    ///         keeper nobody committed.**
    /// @dev The record is the committed side; that is its whole point. The entrypoint read
    ///      `_envOrAddress("RECOUP_KEEPER", record)`, so an environment value that matched the
    ///      CHAIN made the record irrelevant: here the record names `committedKeeper`, the stack
    ///      is locked to `KEEPER`, the environment says `KEEPER`, and the old read certified the
    ///      stack against the environment and never looked at the record. MEASURED red before the
    ///      fix as `next call did not revert as expected`. After it the disagreement is named
    ///      with both values, environment first.
    function test_R48_aKeeperInTheEnvironmentThatMatchesTheChainButNotTheRecordIsRefused() public {
        address committed = makeAddr("committedKeeper");
        probe.setRecord(_jsonFor(address(usdc), committed));
        probe.setEnvAddress("RECOUP_KEEPER", KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.KeeperEnvDisagreesWithRecord.selector, KEEPER, committed)
        );
        probe.assertLockedOnChain();
    }

    /// @dev The other direction: the record is right and the environment is the stranger. Before
    ///      the fix this reverted too, but as `MockOperatorNotKeeper`, which reads as the CHAIN
    ///      being wrong and names a redeploy as the remedy when the remedy is a stale `.env`.
    function test_R48_aStrangerKeeperInTheEnvironmentIsRefusedByName() public {
        address stranger = makeAddr("strangerKeeper");
        probe.setEnvAddress("RECOUP_KEEPER", stranger);
        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.KeeperEnvDisagreesWithRecord.selector, stranger, KEEPER)
        );
        probe.assertLockedOnChain();
    }

    /// @dev Not forbidden outright, on purpose: the documented `deploy && assert` command runs
    ///      both halves against one `.env`, and the deploy half needs `RECOUP_KEEPER` in it. An
    ///      environment that agrees with the record is the state that command is in.
    function test_R48_aKeeperInTheEnvironmentThatAgreesWithTheRecordIsTolerated() public {
        probe.setEnvAddress("RECOUP_KEEPER", KEEPER);
        probe.assertLockedOnChain();
    }

    /// @dev With no override installed the harness reads the fallback and nothing else, so this
    ///      passes whatever `contracts/.env` says on the machine running it. That is the property
    ///      the harness lacked: see the measurement on `R39AssertLockedHarness._envOrAddress`.
    function test_R48_theHarnessReadsNoEnvironmentAtAll() public {
        probe.assertLockedOnChain();
    }

    function _jsonWith(address usdcAddress) internal view returns (string memory) {
        return _jsonFor(usdcAddress, KEEPER);
    }

    function _jsonFor(address usdcAddress, address keeperAddress) internal view returns (string memory) {
        return string.concat(
            '{"chainId":31337,',
            '"deployer":"', vm.toString(address(this)), '",',
            '"operators":{"keeper":"', vm.toString(keeperAddress), '"},',
            '"mocks":{"MockUSDC":"', vm.toString(usdcAddress),
            '","MockBond":"', vm.toString(address(bond)),
            '","MockFarm":"', vm.toString(address(farm)), '"},',
            '"contracts":{"CollateralVault":"', vm.toString(vaultRow),
            '","DirectCallAdapter":"', vm.toString(adapterRow), '"},',
            '"seededPosition":{"bonds":0}}'
        );
    }
}

/// @dev Stands in for the deployed 2026-08-19 bytecode, which has no `admin()` at all.
contract NoLockdownSurface {
    uint256 public something;
}

/// @dev A mock that ANSWERS every lockdown read correctly and gates nothing - the shape a
///      storage-slot read cannot tell from a real lockdown, and the shape the live deployment is
///      actually in.
contract LooksLockedButIsNot {
    address public admin;
    address public operator;
    address public lockAuthority;
    mapping(address => bool) public blocked;

    constructor(address admin_, address operator_) {
        admin = admin_;
        operator = operator_;
        lockAuthority = admin_;
    }

    // Ungated, which is the whole point.
    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function mint(address, uint256) external {}
}
