// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import {DeployBase, IMockLockdownView} from "./DeployBase.sol";
import {MockLockdown} from "../test/mocks/MockLockdown.sol";

/// @title AssertMockStackLocked
/// @notice Read the deployed mock stack off the LIVE chain and prove it is closed.
///
/// @dev 🟥 **This file exists because the post-condition inside the deploy script cannot see the
///      broadcast.** `forge script` executes `run()` exactly once, in the SIMULATION phase, before
///      a single transaction is sent. A check written after `vm.stopBroadcast()` is after the
///      broadcast in source order and nowhere else. Measured 3 of 3 against a local anvil running
///      the real `DeployTestnet` with a real `--broadcast`: with the three `lockTo` transactions
///      among those the node discarded, the script printed `ONCHAIN EXECUTION COMPLETE and
///      SUCCESSFUL` and exited 0, `cast nonce` read 14 of 47, `farm.admin()` and `farm.operator()`
///      were zero on chain, and `farm.seedStakeFor(...)` from a role-less address succeeded.
///      **The deploy reported success and the stack shipped open.**
///
/// @dev **Usage. The `and and` between the two commands is load-bearing:**
///
///      forge script script/Deploy.s.sol:DeployTestnet --rpc-url base_sepolia --broadcast --verify
///        && forge script script/AssertLocked.s.sol:AssertMockStackLocked --rpc-url base_sepolia
///
///      Run it after `--resume` too. `--resume` is the path a partial broadcast actually takes,
///      and it is the case this file was written for.
///
/// @dev 🟥 **NO `vm.startBroadcast` APPEARS ANYWHERE IN THIS FILE, and that is the defence rather
///      than a modifier.** `forge script` only collects transactions between broadcast markers, so
///      an operator who reflexively appends `--broadcast` here sends exactly zero transactions.
///      That property is checkable with one grep and a falsifier asserts it.
///
/// @dev **Reads are low-level `staticcall`, never a high-level call, and the reason is the live
///      chain's actual condition.** The deployed `MockUSDC` at the recorded address predates
///      `MockLockdown` and has no `admin()` at all: a high-level call lands on an absent fallback
///      and bubbles an empty revert, which tells an operator nothing. One branch here separates
///      "wrong value" from "that function does not exist on this bytecode" from "nothing is
///      deployed at this address", and those three need three different responses.
contract AssertMockStackLocked is DeployBase {
    error RecordChainMismatch(uint256 recordChainId, uint256 actualChainId);
    error NoCodeAt(string name, address target);
    error PreLockdownBytecode(string name, address target, string selector);
    error MockStillOpen(string name, address target);
    error MockAdminWrong(string name, address actual, address expected);
    error MockOperatorNotKeeper(string name, address actual, address expected);
    error MockLockAuthorityWrong(string name, address actual, address expected);
    error MockStackDisagrees(string field, address a, address b);
    error GateDoesNotRefuse(string name, address target);
    error FaucetClosed(string name);
    error ConfigurationTampered(string what);

    /// @dev An address with no role of any kind, used to probe that the gate actually refuses.
    address internal constant ROLELESS = address(0xBAD);

    string internal constant RECORD = "deployments/base-sepolia.json";

    struct Stack {
        address usdc;
        address bond;
        address farm;
        address vault;
        address adapter;
        address deployer;
        address keeper;
        uint256 chainId;
        uint256 seededBonds;
    }

    function run() external {
        assertLockedOnChain();
    }

    /// @notice The whole check. `public` so the ledger's own name for this mechanism is directly
    ///         invocable; `run()` exists so the operator command needs no `--sig`, because a
    ///         mistyped `--sig` is a class of failure this repository does not need a new instance
    ///         of.
    function assertLockedOnChain() public {
        Stack memory s = _readStack();

        if (s.chainId != block.chainid) revert RecordChainMismatch(s.chainId, block.chainid);

        // Print EVERYTHING before evaluating any refusal. A run that fails must still tell the
        // operator the whole picture, which is the convention the deployed-bytecode gate
        // already sets: all the counts, every run, including the zeroes.
        _report("MockUSDC", s.usdc);
        _report("MockBond", s.bond);
        _report("MockFarm", s.farm);

        _assertOne("MockUSDC", s.usdc, s.deployer, s.keeper);
        _assertOne("MockBond", s.bond, s.deployer, s.keeper);
        _assertOne("MockFarm", s.farm, s.deployer, s.keeper);

        _assertStackAgrees(s);
        _assertGateRefuses(s);
        _assertFaucetOpen(s);
        _assertConfigurationPristine(s);

        console.log("");
        console.log("OK: all three mocks are locked, the gate refuses a role-less caller,");
        console.log("    the faucet still works, and no configuration value has moved.");
    }

    // -- reads ---------------------------------------------------------------

    /// @dev A seam, for exactly the reason `DeployBase._envOrAddress` is one: a harness overrides
    ///      it with an inline JSON string, so `forge test` touches no filesystem and needs no
    ///      permission grant, while a real run reads the file. The residual - that the base
    ///      implementation genuinely reads the disk and is exercised only on a real run - is the
    ///      same residual this file's parent already documents and accepts.
    ///
    /// @dev 🟥 **THAT SENTENCE WAS WRITTEN BEFORE THE HARNESS EXISTED, and audit round 39 caught
    ///      it in the present tense.** `_readRecord` was `virtual` with ZERO overrides, and because
    ///      the live stack fails at the first assertion - its bytecode predates the lockdown gate -
    ///      four of this file's five assertion groups had never been executed by anything at all.
    ///      The harness is `test/R39AssertLocked.t.sol` now, and it is named here so the claim is
    ///      checkable rather than merely asserted. Seven tests; the load-bearing one is
    ///      `test_R39_slotsSetButTheGateDoesNotRefuseIsCaught`, which MEASURED: deleting
    ///      `_assertGateRefuses` from `assertLockedOnChain()` turns exactly ONE test of 93 red.
    function _readRecord() internal view virtual returns (string memory) {
        return vm.readFile(RECORD);
    }

    function _readStack() internal view returns (Stack memory s) {
        string memory j = _readRecord();
        s.chainId = vm.parseJsonUint(j, ".chainId");
        s.deployer = vm.parseJsonAddress(j, ".deployer");
        s.keeper = _envOrAddress("RECOUP_KEEPER", vm.parseJsonAddress(j, ".operators.keeper"));
        s.usdc = vm.parseJsonAddress(j, ".mocks.MockUSDC");
        s.bond = vm.parseJsonAddress(j, ".mocks.MockBond");
        s.farm = vm.parseJsonAddress(j, ".mocks.MockFarm");
        s.vault = vm.parseJsonAddress(j, ".contracts.CollateralVault");
        s.adapter = vm.parseJsonAddress(j, ".contracts.DirectCallAdapter");
        s.seededBonds = vm.parseJsonUint(j, ".seededPosition.bonds");
    }

    /// @dev The one read primitive. Separates the three failures a naive read collapses into one.
    function _readAddress(string memory name, address target, bytes4 sel, string memory selName)
        internal
        view
        returns (address)
    {
        if (target.code.length == 0) revert NoCodeAt(name, target);
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(sel));
        if (!ok || ret.length != 32) revert PreLockdownBytecode(name, target, selName);
        return abi.decode(ret, (address));
    }

    // -- assertions ----------------------------------------------------------

    function _assertOne(string memory name, address m, address expectedAdmin, address expectedOperator)
        internal
        view
    {
        address a = _readAddress(name, m, IMockLockdownView.admin.selector, "admin()");
        if (a == address(0)) revert MockStillOpen(name, m);
        if (a != expectedAdmin) revert MockAdminWrong(name, a, expectedAdmin);

        address op = _readAddress(name, m, IMockLockdownView.operator.selector, "operator()");
        if (op != expectedOperator) revert MockOperatorNotKeeper(name, op, expectedOperator);

        // The mock's own constructor recorded who created it. A lookalike redeployed at a stale
        // recorded address fails here even if somebody set its admin to the right value.
        address auth = _readAddress(name, m, IMockLockdownView.lockAuthority.selector, "lockAuthority()");
        if (auth != expectedAdmin) revert MockLockAuthorityWrong(name, auth, expectedAdmin);
    }

    /// @dev Catches a PARTIAL re-lock, where one mock was replaced and two were not. Keeps the
    ///      per-mock assertions honest if the expected source of truth ever changes.
    function _assertStackAgrees(Stack memory s) internal view {
        address ua = _readAddress("MockUSDC", s.usdc, IMockLockdownView.admin.selector, "admin()");
        address ba = _readAddress("MockBond", s.bond, IMockLockdownView.admin.selector, "admin()");
        address fa = _readAddress("MockFarm", s.farm, IMockLockdownView.admin.selector, "admin()");
        if (ua != ba) revert MockStackDisagrees("admin", ua, ba);
        if (ba != fa) revert MockStackDisagrees("admin", ba, fa);

        address uo = _readAddress("MockUSDC", s.usdc, IMockLockdownView.operator.selector, "operator()");
        address bo = _readAddress("MockBond", s.bond, IMockLockdownView.operator.selector, "operator()");
        address fo = _readAddress("MockFarm", s.farm, IMockLockdownView.operator.selector, "operator()");
        if (uo != bo) revert MockStackDisagrees("operator", uo, bo);
        if (bo != fo) revert MockStackDisagrees("operator", bo, fo);
    }

    /// @notice The assertion that makes this file worth more than a re-read, and the one a tidy-up
    ///         will want to delete as redundant.
    /// @dev 🟥 **Reading `admin()` proves a STORAGE SLOT is set. It does not prove the deployed
    ///      bytecode gates anything, and that distinction is not hypothetical here - it is the live
    ///      stack's exact condition.** Audit round 38 measured `setBlocked`, `setRewardPool`,
    ///      `setWhitelisted`, `setPendingYield` and `setRevertOnWithdraw` all succeeding on chain
    ///      from a role-less address. A stack whose slots were somehow populated but whose bytecode
    ///      predates `MockLockdown` passes every other assertion in this file and fails this one.
    ///      **A replacement for this file that omits this probe has not replaced it.**
    ///
    /// @dev This probe was genuinely unavailable to the in-script post-condition, whose docstring
    ///      said so: "a probe would need a caller the script does not have". Inside a broadcast
    ///      that is true. Here there is no broadcast, so `vm.prank` is free and local.
    function _assertGateRefuses(Stack memory s) internal {
        _probeRefusal("MockUSDC", s.usdc, abi.encodeWithSignature("setBlocked(address,bool)", ROLELESS, true));
        _probeRefusal("MockBond", s.bond, abi.encodeWithSignature("setWhitelisted(address,bool)", ROLELESS, true));
        _probeRefusal("MockFarm", s.farm, abi.encodeWithSignature("seedStakeFor(address,uint256)", ROLELESS, 1));
    }

    function _probeRefusal(string memory name, address m, bytes memory payload) internal {
        vm.prank(ROLELESS);
        (bool ok, bytes memory ret) = m.call(payload);
        bytes memory want = abi.encodeWithSelector(MockLockdown.MockLocked.selector, ROLELESS);
        if (ok || keccak256(ret) != keccak256(want)) revert GateDoesNotRefuse(name, m);
    }

    /// @dev A stack that is locked AND broken is not a success. The faucet is the whole reason the
    ///      mocks are on a public chain: a stranger mints themselves bonds and USDC and tries the
    ///      dApp. `lockTo` must never have closed it, and nothing else checks that it did not.
    function _assertFaucetOpen(Stack memory s) internal {
        vm.prank(ROLELESS);
        (bool okB,) = s.bond.call(abi.encodeWithSignature("mint(address,uint256)", ROLELESS, 1));
        if (!okB) revert FaucetClosed("MockBond");

        vm.prank(ROLELESS);
        (bool okU,) = s.usdc.call(abi.encodeWithSignature("mint(address,uint256)", ROLELESS, 1));
        if (!okU) revert FaucetClosed("MockUSDC");
    }

    /// @notice The half the lock-ordering fix does NOT close.
    /// @dev Locking each mock in the transaction that creates it narrows the front-run window from
    ///      forty transactions to one, but a write made inside a window that small is still
    ///      permanent and still survives the lockdown. These reads are the round-38 survival
    ///      test's own end state, read back off the chain.
    ///
    /// @dev 🟥 **These read as a TAMPER and the commonest cause is a broadcast that did not
    ///      finish.** Audit round 39 hit exactly this: a truncated run left the whitelist calls
    ///      unsent, and the honest verdict was `the farm is no longer whitelisted` - which reads as
    ///      an attack, whose stated remedy is a redeploy, when the correct remedy is `--resume`.
    ///      That is the same defect this wave fixed one file over in `WirePhase4`, where a health
    ///      report invented a wiring failure out of an unset environment variable. So each message
    ///      below states the CONDITION and names both causes, in the order an operator should check
    ///      them.
    ///
    /// @dev 🟥 **State the gap rather than implying there is none.** `farm.staked[attacker]` and
    ///      whitelist membership for an arbitrary address are not enumerable from chain state, so a
    ///      SEEDED BUT NOT YET WITHDRAWN stake is invisible here. It becomes visible the moment it
    ///      is used, because the withdrawal drains `bond.bondBalance(farm)`, which this function
    ///      does read. So the class moves from permanent-and-unobserved to detected-before-anyone-
    ///      deposits, or detected-on-use. On a testnet stack the remedy for a detected tamper is a
    ///      redeploy.
    function _assertConfigurationPristine(Stack memory s) internal view {
        if (_addr(s.bond, abi.encodeWithSignature("rewardPool()")) != s.farm) {
            revert ConfigurationTampered("bond.rewardPool is not the farm - an unfinished broadcast (try --resume) or a tamper");
        }
        if (!_bool(s.bond, abi.encodeWithSignature("whitelistContains(address)", s.farm))) {
            revert ConfigurationTampered("the farm is not whitelisted - an unfinished broadcast (try --resume) or a tamper");
        }
        if (!_bool(s.bond, abi.encodeWithSignature("whitelistContains(address)", s.adapter))) {
            revert ConfigurationTampered("the adapter is not whitelisted - an unfinished broadcast (try --resume) or a tamper");
        }
        if (_bool(s.usdc, abi.encodeWithSignature("blocked(address)", s.vault))) {
            revert ConfigurationTampered("the vault is blocked out of USDC");
        }
        if (_bool(s.usdc, abi.encodeWithSignature("blocked(address)", s.adapter))) {
            revert ConfigurationTampered("the adapter is blocked out of USDC");
        }
        if (_bool(s.farm, abi.encodeWithSignature("revertOnWithdraw()"))) {
            revert ConfigurationTampered("withdrawals are halted at the farm");
        }
        if (_uint(s.bond, abi.encodeWithSignature("bondBalance(address)", s.farm)) < s.seededBonds) {
            revert ConfigurationTampered("the farm holds fewer bonds than the record's seeded position");
        }
    }

    // -- reporting -----------------------------------------------------------

    /// @dev Prints the `lockState` row ready to paste into the deployment record. It PRINTS rather
    ///      than writes on purpose: `fs_permissions` is process-wide, so `read-write` on
    ///      `deployments` would hand every test in the suite the ability to overwrite the record,
    ///      and stamping the row automatically would make it a side effect instead of a deliberate
    ///      act. a repo-wide guard refuses an incomplete row, so the row is a
    ///      required output of a required step.
    function _report(string memory name, address m) internal view {
        console.log("");
        console.log(name, m);
        if (m.code.length == 0) {
            console.log("  NO CODE AT THIS ADDRESS");
            return;
        }
        _printOrAbsent("  admin        ", m, IMockLockdownView.admin.selector);
        _printOrAbsent("  operator     ", m, IMockLockdownView.operator.selector);
        _printOrAbsent("  lockAuthority", m, IMockLockdownView.lockAuthority.selector);
    }

    function _printOrAbsent(string memory label, address m, bytes4 sel) internal view {
        (bool ok, bytes memory ret) = m.staticcall(abi.encodeWithSelector(sel));
        if (!ok || ret.length != 32) {
            console.log(string.concat(label, " REVERTS - this bytecode predates MockLockdown"));
        } else {
            console.log(label, abi.decode(ret, (address)));
        }
    }

    // -- small typed readers -------------------------------------------------

    function _addr(address t, bytes memory data) private view returns (address) {
        (bool ok, bytes memory ret) = t.staticcall(data);
        if (!ok || ret.length != 32) revert PreLockdownBytecode("config read", t, "address getter");
        return abi.decode(ret, (address));
    }

    function _bool(address t, bytes memory data) private view returns (bool) {
        (bool ok, bytes memory ret) = t.staticcall(data);
        if (!ok || ret.length != 32) revert PreLockdownBytecode("config read", t, "bool getter");
        return abi.decode(ret, (bool));
    }

    function _uint(address t, bytes memory data) private view returns (uint256) {
        (bool ok, bytes memory ret) = t.staticcall(data);
        if (!ok || ret.length != 32) revert PreLockdownBytecode("config read", t, "uint getter");
        return abi.decode(ret, (uint256));
    }
}
