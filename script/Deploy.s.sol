// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {Config} from "../src/Config.sol";
import {MockBond} from "../test/mocks/MockBond.sol";
import {MockFarm} from "../test/mocks/MockFarm.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Local/testnet deployment with the mock DexFi stack.
///         Usage: forge script script/Deploy.s.sol:DeployLocal --rpc-url <anvil> --broadcast
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();
        address admin = msg.sender;

        MockUSDC usdc = new MockUSDC();
        MockBond bond = new MockBond();
        MockFarm farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));

        NAVOracle oracle = new NAVOracle(admin);
        CollateralVault vault =
            new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        // yieldRecipient defaults to the admin (treasury stand-in); repoint to the
        // EpochHarvester once Phase 3 lands. Owner = admin (timelock in production).
        DirectCallAdapter adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, admin
        );
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);
        CreditManager credit =
            new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        LenderPool pool = new LenderPool(usdc, admin);
        EpochHarvester harvester = new EpochHarvester(usdc, ICreditManager(address(credit)), admin);
        LiquidationAuction auction =
            new LiquidationAuction(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);

        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLenderPool(address(pool));
        credit.setEpochHarvester(address(harvester));
        credit.setLiquidationAuction(address(auction));
        pool.setCreditManager(address(credit));
        pool.setEpochHarvester(address(harvester));
        harvester.setLenderPool(address(pool));
        auction.setCreditManager(address(credit));

        vm.stopBroadcast();

        console.log("MockUSDC          ", address(usdc));
        console.log("MockBond          ", address(bond));
        console.log("MockFarm          ", address(farm));
        console.log("NAVOracle         ", address(oracle));
        console.log("CollateralVault   ", address(vault));
        console.log("DirectCallAdapter ", address(adapter));
        console.log("CreditManager     ", address(credit));
        console.log("LenderPool        ", address(pool));
        console.log("EpochHarvester    ", address(harvester));
        console.log("LiquidationAuction", address(auction));
    }
}

/// @notice Mainnet deployment — intentionally reverts until the remaining Phase 0/1
///         blockers clear: DexFi whitelisting the vault for bond transfers, the
///         signed-mint integration, and a chosen custody adapter (direct-call vs
///         Safe). Addresses themselves are resolved (Config).
contract DeployMainnet is Script {
    error Phase1BlockersUnresolved();

    function run() external pure {
        // TODO(phase-1): remove once the custody adapter exists and DexFi has
        // whitelisted it (see the on-chain verification notes in the README).
        revert Phase1BlockersUnresolved();
    }
}
