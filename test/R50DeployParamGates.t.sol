// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round-50 item 142: `NavKeysMustDiffer` sat BELOW `_validateParams`'s local early return
///         while the two rules it belongs beside sat above it.
///
/// @dev `_validateParams` has a documented split. Above `if (_isLocal()) return;` sit the rules
///      that MIRROR SOMETHING A CONTRACT ENFORCES - `GuardianMustDifferFromOwner`,
///      `NavConfirmerMustDifferFromOwner`, `KeeperMustDifferFromOwner` - and each of the three says
///      in its own comment why: a local deploy that broke one would otherwise revert mid-`_wire`
///      with no indication which of two roles was wrong. Below it sit the completeness rules, which
///      are relaxed locally on purpose.
///
///      `NavKeysMustDiffer` is in the first family and was living in the second. `NAVOracle`
///      enforces exactly this rule from both sides - `setNavConfirmer` reverts `KeysMustDiffer()`
///      against the live keeper and `setKeeper` does the same against the live confirmer - so a
///      local deploy naming one key for both roles was accepted by the gate and died inside `_wire`
///      after the whole graph had been created. The suite's own
///      `test_deploy_scriptRefusesTheSameKeyForBothNavRoles` never saw it because it runs at chain
///      id 8453, where the clause below the return already fires.
///
///      This file is hermetic: both environment seams return their fallback and never `super`, so
///      nothing here reads the process environment (round-49 item 136's discipline).
contract R50DeployParamGatesTest is Test, DeployBase {
    address internal treasury = makeAddr("r50.142.treasury");
    address internal feeWallet = makeAddr("r50.142.feeWallet");
    address internal owner = makeAddr("r50.142.owner");
    address internal keeper = makeAddr("r50.142.keeper");
    address internal navConfirmer = makeAddr("r50.142.navConfirmer");
    address internal oneKeyForBoth = makeAddr("r50.142.oneKeyForBoth");

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
        vm.chainId(ANVIL_CHAIN_ID);
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
            owner: owner,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: feeWallet,
            guardian: address(0)
        });
    }

    /// @dev External so `vm.expectRevert` sees a call boundary, and so every `new` inside
    ///      `_deployProtocol` executes in THIS contract's account - which is what makes
    ///      `vm.getNonce(address(this))` an exact count of the contracts a run created.
    function exposedDeployProtocol(Externals memory e, GovParams memory p, address deployer)
        external
        returns (Deployed memory)
    {
        return _deployProtocol(e, p, deployer);
    }

    function exposedValidateParams(GovParams memory p, address deployer) external view {
        _validateParams(p, deployer);
    }

    /// @dev Round 51 moved the four sink collision clauses down into this function, so the arm
    ///      below that asks whether the rule is live off the local chain has to ask the function
    ///      that now carries it.
    function exposedValidateNewDeployment(GovParams memory p, address deployer) external view {
        _validateNewDeployment(p, deployer);
    }

    /// @notice A LOCAL deploy naming one key for both NAV roles is refused at the gate, before the
    ///         first contract is created.
    /// @dev **RED before the move, MEASURED at 9d1e72d with this test against the unmoved clause:**
    ///      `[FAIL: KeysMustDiffer()]` - the deploy ran all the way into `_wire`'s
    ///      `setNavConfirmer` and died on the oracle's own refusal, with every contract in the
    ///      graph already created, and the creation count below had risen rather than stayed put.
    ///      Green after the move, naming the script's own `NavKeysMustDiffer` with a creation count
    ///      of zero.
    ///
    ///      The creation count is the load-bearing half. "Reverts with the right error" would also
    ///      be satisfied by a gate that fired after forty million gas of contract creations, and
    ///      the whole point of the placement is that it fires before the first one.
    ///
    ///      🟥 **Counted from the state diff and NOT from `vm.getNonce`, which was the first
    ///      attempt and is WRONG UNDER THIS `foundry.toml`.** `isolate = true` makes every
    ///      top-level call its own transaction, so `this.exposedDeployProtocol(...)` bumps this
    ///      contract's nonce by one whether it creates anything or not - MEASURED, `6 != 5` on a
    ///      call that reverted at the gate having created nothing. A nonce is a transaction counter
    ///      here, not a creation counter; `AccountAccessKind.Create` is the creation counter.
    function test_R50_142_aLocalDeployWithOneKeyForBothNavRolesDiesBeforeAnyCreation() public {
        GovParams memory p = _params();
        p.keeper = oneKeyForBoth;
        p.navConfirmer = oneKeyForBoth;

        vm.startStateDiffRecording();
        vm.expectRevert(NavKeysMustDiffer.selector);
        this.exposedDeployProtocol(_externals(), p, address(this));
        assertEq(_creationsIn(vm.stopAndReturnStateDiff()), 0, "not one contract may have been created");
    }

    /// @dev Creations made BY THIS CONTRACT, which is what `_deployProtocol`'s `new` statements
    ///      are, and deliberately not every creation in the recorded session.
    ///
    ///      🟥 **A bare `kind == Create` count reads ONE on a call that created nothing.** MEASURED
    ///      while writing this file: the recorded session's second entry is a `Create` of
    ///      `0xbBd98f91088f09ABD9c1C6396b61623b7722C186` by
    ///      `0x4e59b44847b379578588920cA78FbF26c0B4956C` - the `CreditWiring` library, deployed
    ///      through the canonical CREATE2 deployer by forge itself when the linked artifact is
    ///      first touched in a transaction. That is the toolchain arranging the run rather than the
    ///      deploy path doing work, and it appears whether or not the call under test creates
    ///      anything. Filtering on the accessor separates the two without pinning either address.
    function _creationsIn(VmSafe.AccountAccess[] memory accesses) internal view returns (uint256 n) {
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].kind == VmSafe.AccountAccessKind.Create && accesses[i].accessor == address(this)) {
                n++;
            }
        }
    }

    /// @notice The same shape reaches `_validateParams` directly on the local chain.
    /// @dev The sibling of `test_deploy_aNavConfirmerEqualToTheIncomingOwnerIsRefusedBeforeTheFirst
    ///      Creation`'s local arm, one key over.
    function test_R50_142_theLocalGateItselfRefusesOneKeyForBothNavRoles() public {
        GovParams memory p = _params();
        p.keeper = oneKeyForBoth;
        p.navConfirmer = oneKeyForBoth;
        vm.expectRevert(NavKeysMustDiffer.selector);
        this.exposedValidateParams(p, address(this));
    }

    /// @notice Control: distinct keys deploy locally, and the creation count really does move.
    /// @dev Without this the test above would pass over a gate that refused everything.
    function test_R50_142_control_distinctNavKeysDeployLocally() public {
        vm.startStateDiffRecording();
        Deployed memory d = this.exposedDeployProtocol(_externals(), _params(), address(this));
        assertGt(_creationsIn(vm.stopAndReturnStateDiff()), 0, "control: the graph must actually be created");
        assertEq(d.oracle.keeper(), keeper, "control: the keeper is wired");
        assertEq(d.oracle.navConfirmer(), navConfirmer, "control: and the confirmer is a different key");
    }

    /// @notice The zero pair still gets its own name, which is what the non-zero guard on the moved
    ///         clause is for.
    /// @dev Off the local chain an unset keeper and an unset confirmer are equal, so an unguarded
    ///      equality above the return would swallow both `KeeperRequired` and `NavConfirmerRequired`
    ///      into a `NavKeysMustDiffer` naming neither. MEASURED with the guard removed:
    ///      `[FAIL: NavKeysMustDiffer()]` where this expects `KeeperRequired()`.
    function test_R50_142_anUnsetPairIsStillRefusedByTheNameOfTheMissingRole() public {
        vm.chainId(8453);
        GovParams memory p = _params();
        p.keeper = address(0);
        p.navConfirmer = address(0);
        vm.expectRevert(KeeperRequired.selector);
        this.exposedValidateParams(p, address(this));
    }

    /// @notice The clause the item asked about and the answer is that it STAYS below the return.
    /// @dev Round-50 item 142's second half, measured rather than argued. The criterion for sitting
    ///      above the local early return is that the rule MIRRORS ONE A CONTRACT ENFORCES.
    ///      `ProtocolFeeWalletCollision` mirrors nothing: `EpochHarvester.setProtocolFeeWallet`
    ///      refuses only `address(0)`, and `_assertCoreGraph` checks where the sink ENDS UP rather
    ///      than who it collides with. So a local deploy routing the protocol fee at the deploying
    ///      key does not die late - it does not die at all, and moving the clause would refuse a
    ///      local deploy that works today rather than catch one that fails afterwards.
    ///
    ///      This is the measurement behind that decision, held to the tree so the next reader gets
    ///      a number instead of the argument. If a contract ever DOES start enforcing the rule,
    ///      this test goes red and the clause should move.
    ///
    ///      The other half of the item - whether `LOCAL_TREASURY` filling both `yieldRecipient` and
    ///      `protocolFeeWallet` would collide under a move - is recorded in `_validateParams` and is
    ///      not the binding reason: no clause compares those two with each other.
    ///
    /// @dev 🟥 **Round 51 moved this clause, and this test is untouched in the half that matters.**
    ///      The move is the OPPOSITE direction to the one refused here: round-50's ordinal 39 would
    ///      have put the clause ABOVE the local early return, refusing the local deploy the first
    ///      assertion below measures completing; round 51 moved it DOWN into
    ///      `_validateNewDeployment`, still below a local early return. So the first assertion is
    ///      unchanged and still bites, and only the second arm re-points at the function that now
    ///      carries the rule. If a contract ever starts enforcing it, the first assertion is what
    ///      goes red.
    function test_R50_142_theProtocolFeeWalletCollisionHasNoContractMirror() public {
        GovParams memory p = _params();
        p.protocolFeeWallet = address(this); // the deploying key, which is what the rule forbids

        Deployed memory d = this.exposedDeployProtocol(_externals(), p, address(this));
        assertEq(
            d.harvester.protocolFeeWallet(),
            address(this),
            "no contract refuses the collision, so a local deploy completes with it wired"
        );

        // And off the local chain the same parameters are refused by name, so the rule is live
        // where it is meant to be live. Both directions, on one set of parameters.
        vm.chainId(8453);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolFeeWalletCollision.selector, address(this), "deployer")
        );
        this.exposedValidateNewDeployment(p, address(this));

        // And the address rules ALONE accept it, which is what lets an already deployed protocol be
        // switched over after an owner has pointed the harvester's fee wallet at itself. That
        // acceptance is the round-51 change and is asserted rather than left implied.
        this.exposedValidateParams(p, address(this));
    }
}
