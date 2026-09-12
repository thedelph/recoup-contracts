// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {Config} from "../src/Config.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract R50DecimalsExposed is WirePhase4 {
    /// @dev Round 57 (round-57 item 131, audit agent A6): the salt seam, hermetic, so a
    ///      `RECOUP_SWITCHOVER_ATTEMPT` in this box's `contracts/.env` cannot decide a case the day a
    ///      test here reaches `queuePause()` or `executeQueuedPause()`.
    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue) internal pure override returns (string memory) {
        return fallbackValue;
    }

    function exposedAssertCoreGraph(Deployed memory d, GovParams memory p) external view {
        _assertCoreGraph(d, p);
    }

    function exposedQueue(Deployed memory d, TimelockController timelock, GovParams memory p) external {
        _queue(d, timelock, p);
    }
}

/// @notice Round-50 item 146(b): the settlement-token census agreed the six members share ONE token
///         and never asked what that token is, on the one path where the token is already on chain.
///
/// @dev Found by round-50 fleet agent A3. `_deployProtocol` checks `decimals() == 6` before its
///      first `new`, and that covers a deployment this script makes. It does not cover the
///      switchover: `WirePhase4` reaches `_assertCoreGraph` through `run()`, `queue()`,
///      `executeQueued()` and `assertOnly()`, and none of those four passes through
///      `_deployProtocol`. So the block that anchors five members on `d.credit.usdc()` proved they
///      AGREE and said nothing about what they agree on - and the direction fails open, because a
///      token with the wrong decimals reverts nowhere and mis-scales every NAV-to-USDC conversion
///      in the protocol instead.
///
///      **The residual, stated rather than implied.** These tests hold the CLAUSE to the tree: they
///      install an eighteen-decimal answer on the graph's real settlement token and assert the
///      census refuses. What they do not rebuild is a whole nine-contract deployment on a genuinely
///      eighteen-decimal ERC-20, which is what the audit's own executable measurement did - it
///      reproduced `_deployProtocol` without the guard and drove the full switchover path, and
///      found it accepted. That measurement is the finding; this file is the regression.
contract R50WirePathDecimalsTest is Test, DeployBase {
    address internal treasury = makeAddr("r50.146b.treasury");
    address internal keeper = makeAddr("r50.146b.keeper");
    address internal navConfirmer = makeAddr("r50.146b.navConfirmer");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    R50DecimalsExposed internal script;

    /// @dev Round 57 (round-57 item 131, audit agent A6): one of three inheritors the round-49 row did not name, open on all three seams at 82679aa.
    ///      Hermetic on all three seams - the fallback, never `super` - so the first reader added to
    ///      this contract cannot hand `contracts/.env` a vote. Nothing here reads a seam today; the
    ///      repository's environment census printed it `direct` on every one.
    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue) internal pure override returns (string memory) {
        return fallbackValue;
    }

    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(ANVIL_CHAIN_ID);
        script = new R50DecimalsExposed();
    }

    function _externals() internal view returns (Externals memory) {
        return
            Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
    }

    function _paramsOwnedBy(address who) internal view returns (GovParams memory) {
        return GovParams({
            owner: who,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: treasury,
            guardian: address(0)
        });
    }

    function _timelock() internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(Config.ADMIN_TIMELOCK, proposers, executors, address(0));
    }

    /// @notice The census refuses a settlement token that is not six-decimal.
    /// @dev **RED before the clause, MEASURED: `next call did not revert as expected`** - the whole
    ///      graph passed the census with an eighteen-decimal settlement token, because every
    ///      settlement assertion in that block is a comparison between two members of the graph.
    ///
    ///      The decimals answer is installed on the graph's own token rather than the graph being
    ///      rebuilt on a different one, deliberately: the subject is the CENSUS, and changing
    ///      exactly the one value it now reads is what isolates the clause from everything else the
    ///      census does.
    function test_R50_146b_theCensusRefusesAnEighteenDecimalSettlementToken() public {
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(this)), address(this));

        // Control first, on the untouched graph, so the refusal below cannot be a fixture fault.
        script.exposedAssertCoreGraph(d, _paramsOwnedBy(address(this)));

        vm.mockCall(address(usdc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.UsdcDecimalsWrong.selector, address(usdc), uint8(18)));
        script.exposedAssertCoreGraph(d, _paramsOwnedBy(address(this)));
        vm.clearMockedCalls();
    }

    /// @notice And the refusal reaches the entry point an operator actually types.
    /// @dev `queue()` runs `_assertCoreGraph` before it schedules anything, so the switchover is
    ///      refused at generation time rather than executed against a mis-scaled book. This is the
    ///      half that makes the clause worth its place: the census is not an internal helper, it is
    ///      the gate on all four `WirePhase4` entry points.
    function test_R50_146b_theSwitchoverEntryPointRefusesItToo() public {
        TimelockController timelock = _timelock();
        GovParams memory p = _paramsOwnedBy(address(timelock));
        Deployed memory d = _deployProtocol(_externals(), p, address(this));

        vm.mockCall(address(usdc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.UsdcDecimalsWrong.selector, address(usdc), uint8(18)));
        script.exposedQueue(d, timelock, p);
        vm.clearMockedCalls();
    }

    /// @notice Negative control: the census still catches a SECOND token, which is what that block
    ///         was already for.
    /// @dev The new clause is an addition rather than a replacement, and a reader should be able to
    ///      see that the agreement arm still bites. Two decimals rather than eighteen, so the arm
    ///      that fires is unambiguous.
    function test_R50_146b_negative_theAgreementArmStillBites() public {
        Deployed memory d = _deployProtocol(_externals(), _paramsOwnedBy(address(this)), address(this));
        MockUSDC other = new MockUSDC();

        vm.mockCall(address(d.credit), abi.encodeWithSignature("usdc()"), abi.encode(address(other)));
        vm.expectRevert(abi.encodeWithSelector(DeployBase.WiringIncomplete.selector, "auction.usdc"));
        script.exposedAssertCoreGraph(d, _paramsOwnedBy(address(this)));
        vm.clearMockedCalls();
    }
}
