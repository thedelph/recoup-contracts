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
            keccak256(bytes(vm.envOr("RECOUP_MAINNET_CONFIRM", string("")))) != keccak256(bytes(CONFIRM_PHRASE))
        ) revert MainnetConfirmationMissing();

        // The custody decision (direct-call vs a Safe-based backend) is a human
        // judgement that depends on DexFi's whitelist answer. Force it to be stated.
        string memory custody = vm.envOr("RECOUP_CUSTODY_ADAPTER", string(""));
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
