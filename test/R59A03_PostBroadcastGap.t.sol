// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {Config} from "../src/Config.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R59A03PostBroadcastGapTest
/// @notice Audit round 59, agent A3. The deploy path has a post-condition for the shipped state and
///         has no way to run it against a chain, and the one report the documentation defers to
///         refuses the shipped state by construction.
///
/// @dev **The measurement these cases pin, taken on a local anvil at `c9b5f95` with a throwaway key
///      and forge 1.8.1.** `forge script script/Deploy.s.sol:DeployLocal --broadcast` printed
///      `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` and exited **0** after the node discarded
///      **22 of its 39 transactions**: every CREATE landed and every wiring CALL was lost, so the
///      nine contracts stood on chain with every pointer at zero, the adapter's yield sink still on
///      the interim operator address, and `LenderPool` UNPAUSED at `maxDeposit` 25,000.000000 - the
///      round-36 D7 capture state, reported as a success.
///
///      Three post-conditions run on that path (`_assertMockStackLocked`, `_assertWiring`,
///      `_assertCoreGraph`) and all three ran in the SIMULATION, which the scripts say plainly.
///      What nothing says is that the deferral target does not exist: `script/AssertLocked.s.sol`
///      reads the MOCK STACK only and its own docstring hands the protocol graph to
///      `WirePhase4.assertOnly()`, which asserts the POST-switchover state. The first case below is
///      that sentence executed.
contract R59A03PostBroadcastGapTest is Test, DeployBase {
    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    address internal constant KEEPER = address(0xA11CE);
    address internal constant CONFIRMER = address(0xC0FFEE);
    address internal constant TREASURY = address(0xBEEF11);

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(ANVIL_CHAIN_ID);
    }

    function _externals() internal view returns (Externals memory) {
        return
            Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
    }

    /// @dev Owner is this contract, so `_deployProtocol` skips `_handOver` and every later call
    ///      here is authorised. That is the `DeployLocal` shape, which is the shape the rehearsal
    ///      ran.
    function _params() internal view returns (GovParams memory) {
        return GovParams({
            owner: address(this),
            yieldRecipient: TREASURY,
            keeper: KEEPER,
            navConfirmer: CONFIRMER,
            protocolFeeWallet: TREASURY,
            guardian: address(0)
        });
    }

    function exposedAssertWiring(Deployed memory d, GovParams memory p) external view {
        _assertWiring(d, p);
    }

    function exposedAssertPhase4Wiring(Deployed memory d, GovParams memory p) external view {
        _assertPhase4Wiring(d, p);
    }

    function exposedAssertCoreGraph(Deployed memory d, GovParams memory p) external view {
        _assertCoreGraph(d, p);
    }

    /// @notice The control: the shipped state satisfies its own post-condition.
    /// @dev Without this the two refusals below would be consistent with a broken fixture.
    function test_R59A03_control_theShippedStateSatisfiesAssertWiring() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));
        this.exposedAssertWiring(d, _params());
    }

    /// @notice `WirePhase4.assertOnly()`'s post-condition refuses a CORRECTLY shipped deployment.
    /// @dev This is the executable form of the sentence in `AssertLocked._assertRecordedContractsHaveCode`:
    ///      "widening it to the protocol graph is `WirePhase4.assertOnly()`'s job, and that function
    ///      does hold all eight to the record." It does - on the post-switchover state. Run against
    ///      the state `Deploy.s.sol` actually ships, the whole `_assertCoreGraph` census reads green
    ///      and the report then refuses on the one pointer the switchover exists to move.
    ///
    ///      MEASURED identically off a real chain: `forge script WirePhase4 --sig "assertOnly()"`
    ///      against the anvil rehearsal, every read in the trace correct, exit 1,
    ///      `WiringIncomplete("credit.liquiditySource")`.
    function test_R59A03_theDeferredGraphReportRefusesAShippedDeployment() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));
        GovParams memory p = _params();

        // The shared census - everything the switchover does not move - is green on this state.
        this.exposedAssertCoreGraph(d, p);

        vm.expectRevert(abi.encodeWithSelector(WiringIncomplete.selector, "credit.liquiditySource"));
        this.exposedAssertPhase4Wiring(d, p);
    }

    /// @notice The D7 state a lost `pool.pause()` leaves, and which of the two censuses can see it.
    /// @dev `_assertWiring` refuses it; `_assertCoreGraph` - which is the half `assertOnly()` and
    ///      `WirePhase4._queue` share, and the only half of the pair that reaches a chain today -
    ///      passes over it, because the rule deliberately lives in the caller. So on the shipped
    ///      state there is no chain-reachable assertion that the pool is shut, and the pool is open
    ///      at the full deposit cap.
    function test_R59A03_onlyAssertWiringSeesAnOpenPool() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));
        GovParams memory p = _params();

        d.pool.unpause();

        assertEq(
            d.pool.maxDeposit(address(0xBEEF)),
            Config.DEFAULT_LENDER_POOL_DEPOSIT_CAP,
            "the pool is open at the full cap"
        );

        this.exposedAssertCoreGraph(d, p);

        vm.expectRevert(abi.encodeWithSelector(WiringIncomplete.selector, "pool.paused"));
        this.exposedAssertWiring(d, p);
    }

    /// @notice Every wiring call is independently losable, and the census that would catch it is
    ///         the one with no chain-reading caller.
    /// @dev The rehearsal lost all twenty at once. This pins the single-leg case for the leg whose
    ///      absence is silent in every other direction: `adapter.setYieldRecipient(harvester)` is
    ///      the call that moves the yield sink off the operator's interim address, and a deployment
    ///      that stops before it routes 100% of harvested USDC to an EOA with nothing reverting.
    function test_R59A03_aLostYieldSinkLegIsCaughtOnlyByTheUncalledCensus() public {
        Deployed memory d = _deployProtocol(_externals(), _params(), address(this));
        GovParams memory p = _params();

        // Put the sink back where a broadcast that stopped one call early would have left it.
        d.adapter.setYieldRecipient(p.yieldRecipient);
        assertEq(d.adapter.yieldRecipient(), TREASURY, "the interim sink is the operator's address");

        vm.expectRevert(abi.encodeWithSelector(WiringIncomplete.selector, "adapter.yieldRecipient"));
        this.exposedAssertWiring(d, p);
    }
}
