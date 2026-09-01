// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockLockdown} from "./mocks/MockLockdown.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {DeployLocal, DeployTestnet} from "../script/Deploy.s.sol";

/// @title R36MockLockdownTest
/// @notice The mock stack's configuration surface, before and after lockdown.
///
/// @dev **What this is about.** The mock stack is deployed to a public chain, where minting is
///      meant to be open and everything else is not. Before the gate, every configuration setter
///      on all three mocks was callable by any address, which was reproduced against the live
///      deployment from a role-less caller. Three consequences, in ascending order of how much
///      they matter:
///
///        1. **Bricking.** Block the vault out of USDC, un-whitelist the adapter, or halt every
///           withdrawal, and the deployment stops.
///        2. **Forged evidence.** Writing a pending-yield figure moves the counter the harvester
///           records as delivered farm yield, which is the quantity the minimum-per-epoch
///           threshold is measured against. Evidence a third party can write is not evidence.
///        3. **Theft of collateral**, which outranks both. `seedStakeFor` credits a stake that no
///           bond backs, and `withdraw` checks the credit rather than the backing, so it pays out
///           of the pool's real balance. `test_R36_theUngatedFarmLetsAStrangerWithdrawSomebodyElsesBonds`
///           executes that end to end.
///
/// @dev **The default-open property is load-bearing and is tested first.** The gate does nothing
///      while `admin` is zero. That is what lets every other suite here, and every harness that
///      binds to these mocks by relative path, keep calling these setters from arbitrary
///      addresses. If that property ever breaks, it breaks quietly and everywhere at once, so it
///      gets an assertion of its own rather than being relied upon.
contract R36MockLockdownTest is Test {
    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    address internal constant STRANGER = address(0xBAD);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant VICTIM = address(0xFEED);

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        bond.setWhitelisted(address(farm), true);
    }

    function _lockAll() internal {
        usdc.lockTo(ADMIN, KEEPER);
        bond.lockTo(ADMIN, KEEPER);
        farm.lockTo(ADMIN, KEEPER);
    }

    // ── the default-open property ────────────────────────────────────────────

    /// @dev Every gated setter, called by an address holding no role, on a mock nobody locked.
    ///      This is the state under `forge test` and it must stay reachable.
    function test_R36_anUnlockedMockAcceptsEverySetterFromAnybody() public {
        assertEq(usdc.admin(), address(0), "usdc starts open");
        assertEq(bond.admin(), address(0), "bond starts open");
        assertEq(farm.admin(), address(0), "farm starts open");

        vm.startPrank(STRANGER);
        usdc.setBlocked(VICTIM, true);
        usdc.setSilentlyFails(VICTIM, true);
        bond.setRewardPool(address(farm));
        bond.setTreasury(payable(STRANGER));
        bond.setRevokeDuringMint(VICTIM);
        bond.setWhitelisted(STRANGER, true);
        farm.setPendingYield(VICTIM, 1e6);
        farm.setUserDebt(VICTIM, 1e6);
        farm.setYieldAfterAutoDeposit(VICTIM, 1e6);
        farm.seedStakeFor(STRANGER, 1);
        farm.setRevertOnWithdraw(true);
        vm.stopPrank();

        assertTrue(usdc.blocked(VICTIM), "the stranger's write landed");
        assertTrue(farm.revertOnWithdraw(), "and so did the last one");
    }

    // ── the finding, executed ────────────────────────────────────────────────

    /// @dev **The collateral drain, end to end, on the ungated mock.** A victim stakes real bonds.
    ///      A stranger credits themselves an equal unbacked stake and withdraws it. The bonds that
    ///      leave are the victim's. The whitelist does not stop the transfer: the bond's gate is a
    ///      three-way disjunction over caller, sender and recipient, and the farm satisfies two of
    ///      the three, so the bonds reach an address that was never whitelisted.
    function test_R36_theUngatedFarmLetsAStrangerWithdrawSomebodyElsesBonds() public {
        bond.mint(VICTIM, 1_000);
        vm.startPrank(VICTIM);
        bond.setApprovalForAll(address(farm), true);
        farm.deposit(1_000);
        vm.stopPrank();

        assertEq(bond.bondBalance(address(farm)), 1_000, "farm custodies the victim's bonds");
        assertEq(bond.bondBalance(STRANGER), 0, "the stranger holds nothing");
        assertFalse(bond.whitelistContains(STRANGER), "and is not whitelisted");

        vm.startPrank(STRANGER);
        farm.seedStakeFor(STRANGER, 1_000);
        farm.withdraw(1_000);
        vm.stopPrank();

        assertEq(bond.bondBalance(STRANGER), 1_000, "the stranger took the collateral");
        assertEq(bond.bondBalance(address(farm)), 0, "the pool is empty");

        (uint256 victimStake,) = farm.userInfo(VICTIM);
        assertEq(victimStake, 1_000, "the victim's stake still reads 1,000 and is backed by nothing");
    }

    /// @dev The same sequence against a locked farm, refused at the first step.
    function test_R36_aLockedFarmRefusesTheSeededStake() public {
        bond.mint(VICTIM, 1_000);
        vm.startPrank(VICTIM);
        bond.setApprovalForAll(address(farm), true);
        farm.deposit(1_000);
        vm.stopPrank();

        _lockAll();

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MockLockdown.MockLocked.selector, STRANGER));
        farm.seedStakeFor(STRANGER, 1_000);

        assertEq(bond.bondBalance(address(farm)), 1_000, "the collateral stayed");
    }

    // ── the gate, once closed ────────────────────────────────────────────────

    function test_R36_aLockedStackRefusesEverySetterFromAStranger() public {
        _lockAll();
        bytes memory expected = abi.encodeWithSelector(MockLockdown.MockLocked.selector, STRANGER);

        vm.startPrank(STRANGER);
        vm.expectRevert(expected);
        usdc.setBlocked(VICTIM, true);
        vm.expectRevert(expected);
        usdc.setSilentlyFails(VICTIM, true);
        vm.expectRevert(expected);
        bond.setRewardPool(address(farm));
        vm.expectRevert(expected);
        bond.setTreasury(payable(STRANGER));
        vm.expectRevert(expected);
        bond.setRevokeDuringMint(VICTIM);
        vm.expectRevert(expected);
        bond.setWhitelisted(STRANGER, true);
        vm.expectRevert(expected);
        farm.setPendingYield(VICTIM, 1e6);
        vm.expectRevert(expected);
        farm.setUserDebt(VICTIM, 1e6);
        vm.expectRevert(expected);
        farm.setYieldAfterAutoDeposit(VICTIM, 1e6);
        vm.expectRevert(expected);
        farm.seedStakeFor(STRANGER, 1);
        vm.expectRevert(expected);
        farm.setRevertOnWithdraw(true);
        vm.stopPrank();
    }

    function test_R36_theAdminAndTheOperatorBothStillPass() public {
        _lockAll();

        vm.prank(ADMIN);
        bond.setWhitelisted(VICTIM, true);
        assertTrue(bond.whitelistContains(VICTIM), "admin writes");

        // The epoch job signs with the keeper key, not the deploying key, and this is its one
        // write to this stack. If this assertion ever fails the job stops as a red scheduled run.
        vm.prank(KEEPER);
        farm.setPendingYield(VICTIM, 7e6);
        assertEq(farm.pendingShare(VICTIM), 7e6, "the keeper writes");
    }

    /// @dev Minting stays open on all three, and on both of the bond's overloads' sibling path.
    ///      This is the feature the stack exists for, and the farm additionally mints USDC to pay
    ///      every yield claim, so a gate here would stop the protocol rather than an attacker.
    function test_R36_mintingStaysOpenAfterLockdown() public {
        _lockAll();

        vm.startPrank(STRANGER);
        bond.mint(STRANGER, 40);
        usdc.mint(STRANGER, 100e6);
        vm.stopPrank();

        assertEq(bond.bondBalance(STRANGER), 40, "bond faucet open");
        assertEq(usdc.balanceOf(STRANGER), 100e6, "usdc faucet open");
    }

    /// @dev The three farm members that are permissionless on the real DexFi farm stay
    ///      permissionless here. Gating them would model the integration wrongly, which is a
    ///      worse defect in a mock than being too open.
    function test_R36_theRealFarmsPermissionlessMembersStayOpen() public {
        bond.mint(STRANGER, 10);
        _lockAll();

        vm.startPrank(STRANGER);
        bond.setApprovalForAll(address(farm), true);
        farm.deposit(10);
        farm.withdraw(4);
        farm.emergencyWithdraw();
        vm.stopPrank();

        assertEq(bond.bondBalance(STRANGER), 10, "deposit, withdraw and emergency exit all open");
    }

    // ── the lock itself ──────────────────────────────────────────────────────

    /// @dev Only the constructing address may lock. Without this a watcher could take the stack in
    ///      the window between construction and the deploy script's lockdown call, which would
    ///      hand them the powers the gate exists to remove.
    function test_R36_onlyTheConstructingAddressMayLock() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MockLockdown.MockLocked.selector, STRANGER));
        farm.lockTo(STRANGER, address(0));

        assertEq(farm.admin(), address(0), "still open, and still ours to lock");
    }

    function test_R36_lockingIsOneWay() public {
        farm.lockTo(ADMIN, KEEPER);
        vm.expectRevert(MockLockdown.MockAlreadyLocked.selector);
        farm.lockTo(STRANGER, STRANGER);
        assertEq(farm.admin(), ADMIN, "the first admin stands");
    }

    /// @dev A zero admin would read as a successful lockdown while leaving the stack open, which
    ///      is the one failure this gate's caller cannot see from a green run.
    function test_R36_lockingToZeroIsRefused() public {
        vm.expectRevert(MockLockdown.MockAdminRequired.selector);
        farm.lockTo(address(0), KEEPER);
        assertEq(farm.admin(), address(0), "unchanged");
    }

    // ── the second key can be rotated and revoked (round 40) ─────────────────

    /// @notice **The rotation that did not exist.** `lockTo` is one-way, so before round 40 the
    ///         `operator` slot was frozen for the life of the deployment: a keeper rotation
    ///         stranded the epoch job, and a keeper COMPROMISE could not be revoked at all
    ///         without redeploying all three mocks and moving all three addresses.
    /// @dev The revocation arm is the one that matters. `seedStakeFor` is `gated`, and
    ///      `test_R36_theUngatedFarmLetsAStrangerWithdrawSomebodyElsesBonds` above shows what a
    ///      caller who reaches that surface can take.
    function test_R40_theOperatorCanBeRotatedAndRevoked() public {
        _lockAll();
        address newKeeper = address(0xBEEF);

        // Rotation: the old key stops working and the new one starts.
        vm.prank(ADMIN);
        farm.setOperator(newKeeper);
        assertEq(farm.operator(), newKeeper, "the second key moved");

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MockLockdown.MockLocked.selector, KEEPER));
        farm.setPendingYield(VICTIM, 1);

        vm.prank(newKeeper);
        farm.setPendingYield(VICTIM, 1);

        // Revocation: zero clears the role outright, in one transaction.
        vm.prank(ADMIN);
        farm.setOperator(address(0));
        assertEq(farm.operator(), address(0), "the second key is gone");
        vm.prank(newKeeper);
        vm.expectRevert(abi.encodeWithSelector(MockLockdown.MockLocked.selector, newKeeper));
        farm.setPendingYield(VICTIM, 2);

        // And `admin` is untouched throughout: `lockTo` is still one-way. Sent from the LOCK
        // AUTHORITY (this contract), because `lockTo` checks authority before it checks
        // one-wayness - so pranking as `ADMIN` reaches `MockLocked` and proves the wrong clause.
        assertEq(farm.admin(), ADMIN, "admin never moved");
        vm.expectRevert(MockLockdown.MockAlreadyLocked.selector);
        farm.lockTo(STRANGER, STRANGER);
    }

    /// @notice **The escalation this is built to refuse, and the one way to build it wrong.**
    /// @dev `setOperator` is deliberately NOT `gated`. `gated` admits the operator as well as the
    ///      admin, so had it carried that modifier the second key could re-point itself - handing
    ///      the gated surface to a third party, or locking the admin's chosen operator out of it.
    ///      A stranger is refused for the same reason. Both arms are asserted because the
    ///      difference between them and the shipped form is one modifier.
    function test_R40_neitherTheOperatorNorAStrangerMayMoveTheSecondKey() public {
        _lockAll();

        vm.prank(KEEPER);
        vm.expectRevert(MockLockdown.MockAdminRequired.selector);
        farm.setOperator(STRANGER);

        vm.prank(STRANGER);
        vm.expectRevert(MockLockdown.MockAdminRequired.selector);
        farm.setOperator(STRANGER);

        assertEq(farm.operator(), KEEPER, "the second key is where the admin put it");
    }

    /// @notice **It fails closed BEFORE lockdown, which is a free property rather than a clause.**
    /// @dev While `admin` is zero, `msg.sender != admin` holds for every possible caller, because
    ///      `msg.sender` is never the zero address. So `setOperator` cannot be used to squat the
    ///      operator slot in the window between the constructor and `lockTo` - the window round 38
    ///      measured at 40 transactions and a block boundary before the round-39 remediation
    ///      narrowed it to one transaction. Asserted rather than reasoned about, because the whole
    ///      point of the surrounding gate is that it is default-OPEN and this member is not.
    function test_R40_setOperatorIsShutBeforeTheStackIsLocked() public {
        assertEq(farm.admin(), address(0), "premise: unlocked, and every gated setter is open");
        farm.setPendingYield(VICTIM, 1);

        vm.prank(STRANGER);
        vm.expectRevert(MockLockdown.MockAdminRequired.selector);
        farm.setOperator(STRANGER);

        // Including from the address that will become admin, which has no standing yet either.
        vm.prank(ADMIN);
        vm.expectRevert(MockLockdown.MockAdminRequired.selector);
        farm.setOperator(KEEPER);

        assertEq(farm.operator(), address(0), "nothing was squatted");
    }

    /// @dev The operator is optional. Locking without one still closes the surface.
    function test_R36_theOperatorMayBeOmitted() public {
        farm.lockTo(ADMIN, address(0));
        assertEq(farm.operator(), address(0), "no operator");

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MockLockdown.MockLocked.selector, STRANGER));
        farm.setPendingYield(VICTIM, 1);
    }
}

/// @notice `DeployTestnet.run()` itself, executed, asserting that it closes the mock stack.
///
/// @dev **Why this exists rather than a test of a copied sequence.** The gate is default-open, so
///      a deployment that never calls `lockTo` is indistinguishable from one made before the gate
///      existed: everything succeeds, every wiring post-condition passes, and the stack is open.
///      That is the one failure mode a default-open design has, and the only thing that closes it
///      is executing the real script body. A test that reimplements the sequence would prove the
///      reimplementation.
///
/// @dev The script's own docstring used to record that its success path was untested because it
///      "needs a real broadcast and an environment variable, and `vm.setEnv` leaks into every
///      other test in the run". Overriding the two env readers in a subclass removes both
///      obstacles: no process environment is touched, and nothing leaks.
contract R36TestnetLockdownHarness is DeployTestnet {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    mapping(bytes32 => string) private _str;
    mapping(bytes32 => bool) private _strSet;

    function setEnvAddress(string memory key, address value) external {
        _addr[keccak256(bytes(key))] = value;
        _addrSet[keccak256(bytes(key))] = true;
    }

    function setEnvString(string memory key, string memory value) external {
        _str[keccak256(bytes(key))] = value;
        _strSet[keccak256(bytes(key))] = true;
    }

    /// @notice What the last `exposedDeployTestnetStack` produced, so the POST-BROADCAST half can
    ///         be driven too.
    /// @dev Round 38 measured that the call site was covered by nothing: deleting
    ///      `_assertMockStackLocked(msg.sender);` from `run()` left the suite green in two
    ///      independent streams. Covering the body is not covering the line that calls it.
    Deployed private _lastDeployed;
    GovParams private _lastParams;

    /// @dev The real body, minus only the two broadcast lines a test frame cannot execute.
    function exposedDeployTestnetStack() external {
        (Deployed memory d, GovParams memory p) = _deployTestnetStack(address(this));
        _lastDeployed = d;
        _lastParams = p;
    }

    /// @notice The real post-broadcast half, at its real call site.
    /// @dev **This is the arm that turns red when `_assertMockStackLocked` is deleted from
    ///      `_afterBroadcast`.** `exposedAssertMockStackLockedTo` below covers the assertion's
    ///      BODY and stays green under that neuter, which is exactly why both exist.
    function exposedAfterBroadcast(address deployer) external view {
        _afterBroadcast(_lastDeployed, _lastParams, deployer);
    }

    function exposedAssertMockStackLocked() external view {
        _assertMockStackLocked(
            address(deployedUsdc), address(deployedBond), address(deployedFarm),
            address(this), _lastParams.keeper
        );
    }

    function exposedAssertMockStackLockedTo(address who) external view {
        _assertMockStackLocked(
            address(deployedUsdc), address(deployedBond), address(deployedFarm),
            who, _lastParams.keeper
        );
    }

    /// @notice Assert against an arbitrary expected operator.
    /// @dev Exists so the round-38 neuters N18 and N19 - `usdc.lockTo(deployer, address(0))` and
    ///      the bond equivalent, both GREEN before this round - have something that can see them.
    function exposedAssertMockStackLockedWith(address admin_, address operator_) external view {
        _assertMockStackLocked(
            address(deployedUsdc), address(deployedBond), address(deployedFarm), admin_, operator_
        );
    }

    function _envOrAddress(string memory key, address fallbackValue)
        internal
        view
        virtual
        override
        returns (address)
    {
        bytes32 k = keccak256(bytes(key));
        if (_addrSet[k]) return _addr[k];
        return super._envOrAddress(key, fallbackValue);
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        virtual
        override
        returns (string memory)
    {
        bytes32 k = keccak256(bytes(key));
        if (_strSet[k]) return _str[k];
        return super._envOrString(key, fallbackValue);
    }
}

contract R36TestnetLockdownTest is Test {
    R36TestnetLockdownHarness internal script;

    address internal constant OWNER = address(0x0011);
    address internal constant KEEPER = address(0x0022);
    address internal constant CONFIRMER = address(0x0033);
    address internal constant TREASURY = address(0x0044);
    address internal constant FEE_WALLET = address(0x0055);
    address internal constant STRANGER = address(0xBAD);

    function setUp() public {
        vm.chainId(84532);
        script = new R36TestnetLockdownHarness();
        script.setEnvString("RECOUP_TESTNET_CONFIRM", "RECOUP_DEPLOY_BASE_SEPOLIA");
        script.setEnvAddress("RECOUP_OWNER", OWNER);
        script.setEnvAddress("RECOUP_KEEPER", KEEPER);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", CONFIRMER);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", TREASURY);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", FEE_WALLET);
    }

    /// @dev The whole point. A deployment made by the shipped script hands nobody but its operator
    ///      and its keeper a configuration write, and a stranger who tries is refused by name.
    function test_R36_theTestnetDeployLeavesTheMockStackClosed() public {
        script.exposedDeployTestnetStack();
        script.exposedAssertMockStackLocked();

        MockUSDC usdc = script.deployedUsdc();
        MockBond bond = script.deployedBond();
        MockFarm farm = script.deployedFarm();

        assertEq(usdc.admin(), address(script), "usdc locked to the broadcaster");
        assertEq(bond.admin(), address(script), "bond locked to the broadcaster");
        assertEq(farm.admin(), address(script), "farm locked to the broadcaster");
        assertEq(farm.operator(), KEEPER, "and the keeper can still fire an epoch");

        bytes memory refusal = abi.encodeWithSelector(MockLockdown.MockLocked.selector, STRANGER);
        vm.startPrank(STRANGER);
        vm.expectRevert(refusal);
        farm.seedStakeFor(STRANGER, 1_000);
        vm.expectRevert(refusal);
        farm.setPendingYield(STRANGER, 1e6);
        vm.expectRevert(refusal);
        bond.setWhitelisted(STRANGER, true);
        vm.expectRevert(refusal);
        usdc.setBlocked(address(bond), true);
        vm.stopPrank();

        // Still a faucet, which is the reason the stack is on a public chain at all.
        vm.startPrank(STRANGER);
        bond.mint(STRANGER, 40);
        usdc.mint(STRANGER, 100e6);
        vm.stopPrank();
        assertEq(bond.bondBalance(STRANGER), 40, "minting survived the lockdown");
    }

    /// @dev The post-condition itself, exercised rather than assumed.
    /// @dev **This test exists because a neuter found it missing.** Deleting the body of
    ///      `_assertMockStackLocked` left every other test in this file green: they read `admin`
    ///      themselves, so none of them needed the script to check anything. A post-condition
    ///      nothing exercises is a post-condition that can be deleted in a tidy-up, and the thing
    ///      it guards against - a run that silently skipped the lockdown - would come straight
    ///      back with it.
    function test_R36_theDeployPostConditionRefusesAStackLockedToSomebodyElse() public {
        script.exposedDeployTestnetStack();
        script.exposedAssertMockStackLocked();

        MockUSDC usdc = script.deployedUsdc();
        vm.expectRevert(abi.encodeWithSelector(DeployBase.MockNotLocked.selector, address(usdc)));
        script.exposedAssertMockStackLockedTo(STRANGER);
    }

    /// @notice The CALL SITE, not the body.
    /// @dev 🟥 **The distinction is the whole finding.** The test above covers the assertion's
    ///      body; audit round 38 then deleted the LINE THAT CALLS IT from `run()` and left 91 of 91
    ///      and 88 of 88 green in two independent streams working in separate worktrees. That line
    ///      now lives in `_afterBroadcast`, where a test frame can reach it, and this is the test
    ///      that reaches it. **Deleting `_assertMockStackLocked` from `_afterBroadcast` must turn
    ///      this red and must leave the test above green.** If both go red, this one is a duplicate
    ///      and buys nothing.
    function test_R39_theCallSiteRunsTheLockdownAssertion() public {
        script.exposedDeployTestnetStack();
        script.exposedAfterBroadcast(address(script));

        MockUSDC usdc = script.deployedUsdc();
        vm.expectRevert(abi.encodeWithSelector(DeployBase.MockNotLocked.selector, address(usdc)));
        script.exposedAfterBroadcast(STRANGER);
    }

    /// @notice The operator argument, on every mock rather than on the farm alone.
    /// @dev 🟥 **Round-38 neuters N18 and N19 were GREEN.** `usdc.lockTo(deployer, address(0))` and
    ///      the bond equivalent both passed the whole suite, because the only place any test read
    ///      an operator was `assertEq(farm.operator(), KEEPER)`. The post-condition read `admin`
    ///      only. An open finding from that round. This asserts the mock NAMED FIRST in the check order is USDC, so a
    ///      regression that drops the operator read cannot hide behind the farm.
    function test_R39_aWrongOperatorIsCaughtOnUsdcNotJustTheFarm() public {
        script.exposedDeployTestnetStack();

        MockUSDC usdc = script.deployedUsdc();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.MockOperatorWrong.selector, address(usdc), KEEPER, STRANGER
            )
        );
        script.exposedAssertMockStackLockedWith(address(script), STRANGER);
    }

    /// @dev The lock now happens in the same transaction as the CREATE, so every configuration
    ///      call the script makes afterwards is made by the admin. If the reorder had broken one of
    ///      them, `exposedDeployTestnetStack` would revert `MockLocked` rather than fail an
    ///      assertion - so this asserts the end state those calls produce, which is the thing that
    ///      would be silently missing.
    function test_R39_theReorderedLockLeavesEveryConfigurationCallApplied() public {
        script.exposedDeployTestnetStack();

        MockBond bond = script.deployedBond();
        MockFarm farm = script.deployedFarm();
        assertEq(bond.rewardPool(), address(farm), "setRewardPool ran after the lock");
        assertTrue(bond.whitelistContains(address(farm)), "the farm is whitelisted");
    }
}

/// @notice `DeployLocal`, which had no lockdown post-condition at all.
/// @dev 🟥 **Round 38 deleted all three `lockTo` calls from `DeployLocal.run()` and the suite
///      stayed green in two independent streams, because `DeployLocal.run()` is invoked by NO TEST
///      AT ALL.** Filed by that round as an omission rather than a decision. Adding a
///      post-condition to a function nothing executes would have moved the hole one contract over,
///      so `DeployLocal` got the same `_afterBroadcast` split `DeployTestnet` has, and this is the
///      harness that drives it.
/// @dev No environment overrides are needed: `DeployLocal` has no chain guard and `_readParams`
///      supplies the local operator addresses on chain id 31337, which is what `forge test` runs.
contract R39LocalLockdownHarness is DeployLocal {
    Deployed private _lastDeployed;
    GovParams private _lastParams;

    function exposedDeployLocalStack() external {
        (Deployed memory d, GovParams memory p) = _deployLocalStack(address(this));
        _lastDeployed = d;
        _lastParams = p;
    }

    function exposedAfterBroadcast(address deployer) external view {
        _afterBroadcast(_lastDeployed, _lastParams, deployer);
    }
}

contract R39LocalLockdownTest is Test {
    R39LocalLockdownHarness internal script;

    address internal constant STRANGER = address(0xBAD);

    function setUp() public {
        script = new R39LocalLockdownHarness();
    }

    /// @dev **Deleting any of the three `lockTo` calls from `_deployLocalStack` must turn this
    ///      red.** That edit was green before this round.
    function test_R39_deployLocalLocksTheWholeStack() public {
        script.exposedDeployLocalStack();

        assertEq(script.deployedUsdc().admin(), address(script), "usdc locked");
        assertEq(script.deployedBond().admin(), address(script), "bond locked");
        assertEq(script.deployedFarm().admin(), address(script), "farm locked");

        script.exposedAfterBroadcast(address(script));
    }

    /// @dev The call site, for the same reason as the testnet one.
    function test_R39_deployLocalCallSiteRunsTheAssertion() public {
        script.exposedDeployLocalStack();

        MockUSDC usdc = script.deployedUsdc();
        vm.expectRevert(abi.encodeWithSelector(DeployBase.MockNotLocked.selector, address(usdc)));
        script.exposedAfterBroadcast(STRANGER);
    }
}
