// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "./DeployBase.sol";
import {Config} from "../src/Config.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "../test/mocks/MockBond.sol";
import {MockFarm} from "../test/mocks/MockFarm.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Local deployment against the mock DexFi stack.
///         Usage: forge script script/Deploy.s.sol:DeployLocal --rpc-url <anvil> --broadcast
/// @dev Runs the same `_deployProtocol` and `_assertWiring` as mainnet, so the two
///      cannot drift. Operator addresses fall back to deterministic locals, so this
///      needs no environment setup.
contract DeployLocal is DeployBase {
    function run() external {
        vm.startBroadcast();

        MockUSDC usdc = new MockUSDC();
        MockBond bond = new MockBond();
        MockFarm farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));

        GovParams memory p = _resolveParams(msg.sender);
        Externals memory e = Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });

        Deployed memory d = _deployProtocol(e, p, msg.sender);

        // Mirror mainnet's gate: the farm is whitelisted, and DexFi whitelisting our
        // adapter is the one integration ask (PRD §14 ask #5).
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);

        vm.stopBroadcast();

        _assertWiring(d, p);
        console.log("MockUSDC          ", address(usdc));
        console.log("MockBond          ", address(bond));
        console.log("MockFarm          ", address(farm));
        _log(d, p);
    }
}

/// @notice Base Sepolia deployment against the mock DexFi stack (PRD §8).
///         Usage: forge script script/Deploy.s.sol:DeployTestnet --rpc-url base_sepolia --broadcast --verify
/// @dev Exists as a named target rather than pointing `DeployLocal` at a testnet RPC.
///      `DeployLocal` has no chain guard, so it runs anywhere its RPC points; on a real
///      chain it falls through `_isLocal()` into strict validation and mostly works,
///      which is worse than failing outright. An implicit path nothing tests is exactly
///      the footgun `DeployBase` was written to remove.
/// @dev The mocks are deliberately permissionless - anyone can `mint` bonds and USDC and
///      call `setWhitelisted`. On a testnet that is a feature: it lets someone try the
///      dApp without being handed tokens. It is also why nothing here may ever be reused
///      on mainnet, where the real bond contract gates all three.
contract DeployTestnet is DeployBase {
    error WrongChain(uint256 chainId);
    error TestnetConfirmationMissing();

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    string internal constant CONFIRM_PHRASE = "RECOUP_DEPLOY_BASE_SEPOLIA";

    function run() external {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        if (
            keccak256(bytes(_envOrString("RECOUP_TESTNET_CONFIRM", ""))) != keccak256(bytes(CONFIRM_PHRASE))
        ) revert TestnetConfirmationMissing();

        vm.startBroadcast();

        MockUSDC usdc = new MockUSDC();
        MockBond bond = new MockBond();
        MockFarm farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));

        // Not local, so `_resolveParams` enforces the full set: owner, yield recipient,
        // keeper, nav confirmer and fee wallet all present, the two NAV keys distinct,
        // and the yield recipient distinct from both the deployer and the owner.
        GovParams memory p = _resolveParams(msg.sender);
        Externals memory e = Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });

        Deployed memory d = _deployProtocol(e, p, msg.sender);

        // Mirrors the mainnet gate that DexFi controls. On mainnet this is the one
        // integration ask and cannot be self-served (§14 ask #5).
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);

        vm.stopBroadcast();

        _assertWiring(d, p);
        console.log("MockUSDC          ", address(usdc));
        console.log("MockBond          ", address(bond));
        console.log("MockFarm          ", address(farm));
        _log(d, p);
        console.log("Next: fund the liquidity source, then bootstrapNav as the owner.");
    }
}

/// @notice Base mainnet deployment. Still gated, but the gate is now a checklist of
///         named preconditions rather than a single blanket revert, so the script
///         states what is actually missing.
/// @dev Deliberately absent from the preconditions: DexFi having whitelisted the
///      adapter. The adapter has no address until it is deployed, so that cannot be
///      a pre-deploy check. Deploying first is harmless - deposits simply revert at
///      the bond's gate until DexFi acts, which the fork suite already proves - so
///      the real order is deploy, send DexFi the address, then go live.
contract DeployMainnet is DeployBase {
    error WrongChain(uint256 chainId);
    error MainnetConfirmationMissing();
    error CustodyDecisionUnrecorded();

    uint256 internal constant BASE_CHAIN_ID = 8453;
    string internal constant CONFIRM_PHRASE = "RECOUP_DEPLOY_BASE_MAINNET";

    function run() external {
        if (block.chainid != BASE_CHAIN_ID) revert WrongChain(block.chainid);

        // A stray `forge script` should not be able to reach mainnet by accident.
        if (
            keccak256(bytes(_envOrString("RECOUP_MAINNET_CONFIRM", ""))) != keccak256(bytes(CONFIRM_PHRASE))
        ) revert MainnetConfirmationMissing();

        // The custody decision (direct-call vs a Safe-based backend) is a human
        // judgement that depends on DexFi's whitelist answer. Force it to be stated.
        string memory custody = _envOrString("RECOUP_CUSTODY_ADAPTER", "");
        if (keccak256(bytes(custody)) != keccak256(bytes("direct"))) revert CustodyDecisionUnrecorded();

        // _resolveParams enforces the rest: owner, treasury, keeper and fee wallet
        // all present, and the treasury distinct from the deployer and the owner.
        GovParams memory p = _resolveParams(msg.sender);

        Externals memory e = Externals({
            bond: IDexFiBond(Config.DEXFI_BOND_NFT),
            farm: IDexFiFarm(Config.DEXFI_FARM),
            usdc: IERC20(Config.USDC_BASE)
        });

        vm.startBroadcast();
        Deployed memory d = _deployProtocol(e, p, msg.sender);
        vm.stopBroadcast();

        _assertWiring(d, p);
        _log(d, p);
        console.log("Next: send DexFi the adapter address above for addWhitelist().");
    }
}
