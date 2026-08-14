// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import {DeployBase} from "./DeployBase.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";

/// @notice The Phase-4 switchover as a broadcastable operation: the LenderPool takes over funding
///         the book and takes on the losses that come with it, and the post-condition runs in the
///         same breath.
///
/// @dev **Audit round 16, seven agents: this file did not exist, and that made roughly eighteen
///      assertions unreachable outside CI.** `_wirePhase4` and `_assertPhase4Wiring` are `internal`
///      on an abstract contract, and a repo-wide grep found callers only in the test suite. All
///      three `Deploy.s.sol` targets call `_deployProtocol` and `_assertWiring` and neither Phase-4
///      function. So on mainnet the switchover was three hand-sent owner transactions with **no
///      post-condition at all** - including every ownership check and `d.liquidity`, the contract
///      that has been missed twice while holding the lending float behind an uncapped `onlyOwner`
///      withdraw.
///
///      `DeployBase`'s own header names this exact class: "A switchover written as a runbook step
///      instead of as code would be the same class of defect as the one it fixes." Audit round 15
///      made the post-condition worth running and left it with nothing to run it.
///
///      **Addresses come from the environment rather than from a deployment record**, because by
///      the time this runs the deployment is history and the operator has the addresses in front of
///      them. Every one is required: there is no local fallback here, unlike `_resolveParams`,
///      because there is no such thing as a switchover on a protocol that was not deployed.
///
///      **The owner runs this, and by Phase 4 the owner is meant to be a Safe or a timelock.** Then
///      `run()` is not the transaction; it is the source of the three calls that get queued, and
///      `--sig` on `assertOnly()` is how the post-condition is checked after they execute. That
///      split is deliberate: a timelocked switchover cannot assert its own result in the same
///      transaction, and an assertion that can only run in the same transaction as the change is an
///      assertion that never runs on the deployment that matters.
contract WirePhase4 is DeployBase {
    error DeployedAddressMissing(string name);
    error SwitchoverConfirmationMissing();

    string internal constant CONFIRM_PHRASE = "RECOUP_WIRE_PHASE_4";

    /// @notice Wire the switchover, then assert the state it must leave behind.
    function run() external {
        _requireConfirmation();
        Deployed memory d = _resolveDeployed();
        GovParams memory p = _resolveParams(msg.sender);

        vm.startBroadcast();
        _wirePhase4(d);
        vm.stopBroadcast();

        _assertPhase4Wiring(d, p);
        _log(d, p);
        console.log("Phase 4 wired: the pool funds the book and takes the losses.");
    }

    /// @notice The post-condition on its own, for the case the three calls were queued rather than
    ///         sent - which is the case this protocol is heading for.
    /// @dev Usage: forge script script/WirePhase4.s.sol:WirePhase4 --sig "assertOnly()" --rpc-url base
    ///      Reverts with the same named `WiringIncomplete` reason a broadcast run would, so a
    ///      half-executed switchover is a legible failure rather than a silent one. Deliberately
    ///      not gated on the confirmation phrase: reading state changes nothing and an operator
    ///      should never be discouraged from checking.
    function assertOnly() external view {
        _assertPhase4Wiring(_resolveDeployed(), _resolveParams(msg.sender));
        console.log("Phase-4 wiring holds.");
    }

    /// @dev A stray `forge script` should not be able to move the funder and the loss sink by
    ///      accident, which is the same reason the mainnet deploy target carries one. No chain
    ///      guard, though: unlike a deployment this is legitimate on a testnet, on a fork and on
    ///      anvil, and a chain allow-list here would have to be edited every time it is exercised.
    function _requireConfirmation() internal view {
        if (keccak256(bytes(vm.envOr("RECOUP_SWITCHOVER_CONFIRM", string("")))) != keccak256(bytes(CONFIRM_PHRASE)))
        {
            revert SwitchoverConfirmationMissing();
        }
    }

    function _resolveDeployed() internal view returns (Deployed memory d) {
        d.oracle = NAVOracle(_required("RECOUP_NAV_ORACLE"));
        d.vault = CollateralVault(_required("RECOUP_COLLATERAL_VAULT"));
        d.adapter = DirectCallAdapter(_required("RECOUP_CUSTODY_ADAPTER"));
        d.credit = CreditManager(_required("RECOUP_CREDIT_MANAGER"));
        d.pool = LenderPool(_required("RECOUP_LENDER_POOL"));
        d.liquidity = TreasuryLiquiditySource(_required("RECOUP_LIQUIDITY_SOURCE"));
        d.harvester = EpochHarvester(_required("RECOUP_EPOCH_HARVESTER"));
        d.auction = LiquidationAuction(_required("RECOUP_LIQUIDATION_AUCTION"));
    }

    /// @dev Named in the revert, because "one of eight addresses is unset" is not an error message
    ///      anybody can act on.
    function _required(string memory name) internal view returns (address a) {
        a = vm.envOr(name, address(0));
        if (a == address(0)) revert DeployedAddressMissing(name);
    }
}
