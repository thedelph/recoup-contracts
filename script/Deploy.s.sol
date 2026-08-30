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
    /// @notice What the last `run` deployed, so the success path can be asserted rather than
    ///         eyeballed. Mirrors `DeployTestnet`, and for the same reason.
    MockUSDC public deployedUsdc;
    MockBond public deployedBond;
    MockFarm public deployedFarm;

    function run() external {
        vm.startBroadcast();
        (Deployed memory d, GovParams memory p) = _deployLocalStack(msg.sender);
        vm.stopBroadcast();

        _afterBroadcast(d, p, msg.sender);
    }

    /// @notice Everything `run` broadcasts, with the broadcast lifted out.
    /// @dev **Split for the same reason `DeployTestnet` was split, and because leaving it unsplit
    ///      would have recreated the very defect this round is closing.** Round 38 measured that
    ///      `DeployLocal.run()` is invoked by NO TEST AT ALL, so deleting its three `lockTo` calls
    ///      was green in two independent audit streams. Adding a post-condition to a function
    ///      nothing executes would have moved the hole rather than closed it: the assertion would
    ///      be as unreachable as the calls it guards.
    function _deployLocalStack(address deployer) internal returns (Deployed memory d, GovParams memory p) {
        // Resolved FIRST because `p.keeper` is now needed at construction time. `_resolveParams`
        // is `view` and reads only the environment, so moving it ahead of the mocks changes
        // nothing about what it returns.
        p = _resolveParams(deployer);

        // **Each mock is locked in the same transaction that creates it. Round-39 remediation, and
        // the ordering IS the fix.** See the note in `DeployTestnet._deployTestnetStack`.
        MockUSDC usdc = new MockUSDC();
        usdc.lockTo(deployer, p.keeper);
        MockBond bond = new MockBond();
        bond.lockTo(deployer, p.keeper);
        MockFarm farm = new MockFarm(bond, usdc);
        farm.lockTo(deployer, p.keeper);

        deployedUsdc = usdc;
        deployedBond = bond;
        deployedFarm = farm;

        // Every configuration call below is made by `deployer`, who is now `admin`, so the gate
        // admits it. Sign-checked against `MockLockdown.gated` for every gated call on this path.
        bond.setRewardPool(address(farm));

        Externals memory e = Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });

        d = _deployProtocol(e, p, deployer);

        // Mirror mainnet's gate: the farm is whitelisted, and DexFi whitelisting our
        // adapter is the one integration ask (PRD §14 ask #5).
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);
    }

    /// @notice The post-broadcast half, extracted so a test can drive the CALL SITE and not only
    ///         the bodies it calls.
    /// @dev Round 38 found that the equivalent call site on `DeployTestnet` was covered by
    ///      nothing: deleting `_assertMockStackLocked(msg.sender)` from `run()` left 91 of 91 and
    ///      88 of 88 green in two streams. A post-condition nothing exercises is a post-condition
    ///      somebody deletes in a tidy-up.
    function _afterBroadcast(Deployed memory d, GovParams memory p, address deployer) internal view {
        _assertMockStackLocked(
            address(deployedUsdc), address(deployedBond), address(deployedFarm), deployer, p.keeper
        );
        _assertWiring(d, p);
        console.log("MockUSDC          ", address(deployedUsdc));
        console.log("MockBond          ", address(deployedBond));
        console.log("MockFarm          ", address(deployedFarm));
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
/// @dev **The mocks MINT permissionlessly and are gated everywhere else, and the split is the
///      point.** Anyone may `mint` bonds and USDC: on a testnet that is a feature, because it lets
///      someone try the dApp without being handed tokens, and the farm itself mints USDC to pay
///      every yield claim, so an owner gate there would stop the protocol rather than an attacker.
///      Every *configuration* setter is closed by `lockTo` at the end of `run`.
/// @dev **The sentence above used to say the mocks were permissionless full stop, and that was a
///      live hole rather than a description.** With the setters open, any address could block USDC
///      out of the vault, repoint the auto-stake sink, un-whitelist the adapter, halt every
///      withdrawal, or write a pending-yield figure that the harvester then records as delivered
///      farm yield - which is the counter the four-clean-epoch evidence is measured on, so that
///      evidence was forgeable by a stranger. `seedStakeFor` was worse than any of those: it
///      credits a stake that no bond backs, and `withdraw` checks the credit rather than the
///      backing, so one call and one withdrawal take collateral that belongs to somebody else.
/// @dev None of this makes the stack fit for mainnet. The real bond gates minting too.
contract DeployTestnet is DeployBase {
    error WrongChain(uint256 chainId);
    error TestnetConfirmationMissing();
    // `MockNotLocked` and `MockOperatorWrong` moved to `DeployBase` in round-39 remediation, so
    // `DeployLocal` gets the same post-condition. Callers that encoded
    // `DeployTestnet.MockNotLocked.selector` now encode `DeployBase.MockNotLocked.selector`; it is
    // the same selector either way, since a Solidity error selector is keyed on its signature and
    // not on the contract that declares it.

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    string internal constant CONFIRM_PHRASE = "RECOUP_DEPLOY_BASE_SEPOLIA";

    /// @notice What the last `run` deployed, recorded rather than only printed.
    /// @dev A script that prints its addresses can be read by a person and by nothing else. These
    ///      three exist so the success path can be asserted rather than eyeballed: the lockdown at
    ///      the end of `run` is default-open, so a run that skipped it would pass every other
    ///      post-condition in this file and leave the stack exactly as open as it was before the
    ///      gate existed. Storage on an ephemeral script contract costs a real deployment nothing.
    MockUSDC public deployedUsdc;
    MockBond public deployedBond;
    MockFarm public deployedFarm;

    function run() external {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        if (
            keccak256(bytes(_envOrString("RECOUP_TESTNET_CONFIRM", ""))) != keccak256(bytes(CONFIRM_PHRASE))
        ) revert TestnetConfirmationMissing();

        vm.startBroadcast();
        (Deployed memory d, GovParams memory p) = _deployTestnetStack(msg.sender);
        vm.stopBroadcast();

        _afterBroadcast(d, p, msg.sender);
    }

    /// @notice The post-broadcast half, extracted so a test can drive the CALL SITE.
    /// @dev 🟥 **The call site was covered by nothing, and that was found twice independently.**
    ///      Deleting `_assertMockStackLocked(msg.sender);` from `run()` left 91 of 91 and 88 of 88
    ///      green in two audit streams working in separate worktrees. The BODY was covered, by
    ///      `R36TestnetLockdownHarness.exposedAssertMockStackLockedTo`; the line that calls it was
    ///      not, because `run()` starts a broadcast and cannot be executed from a test frame.
    ///      Everything after `vm.stopBroadcast()` now lives here, where it can be.
    /// @dev 🟥 **And read what this does NOT prove.** `forge script` runs `run()` once, in
    ///      simulation, before any transaction is sent, so this executes against the simulated
    ///      state and is blind to a partial broadcast. `script/AssertLocked.s.sol`, run without
    ///      `--broadcast` against the live RPC afterwards, is the thing that reads the chain.
    function _afterBroadcast(Deployed memory d, GovParams memory p, address deployer) internal view {
        _assertMockStackLocked(
            address(deployedUsdc), address(deployedBond), address(deployedFarm), deployer, p.keeper
        );
        _assertWiring(d, p);
        console.log("MockUSDC          ", address(deployedUsdc));
        console.log("MockBond          ", address(deployedBond));
        console.log("MockFarm          ", address(deployedFarm));
        _log(d, p);
        console.log("Next: fund the liquidity source, then bootstrapNav as the owner.");
        console.log("THEN, and it is not optional:");
        console.log("  forge script script/AssertLocked.s.sol:AssertMockStackLocked --rpc-url base_sepolia");
    }

    /// @notice Everything `run` broadcasts, with the broadcast lifted out.
    /// @dev **Split out so the success path can be executed by a test, which it never could be.**
    ///      `vm.startBroadcast` inside a `forge test` frame pranks every subsequent call and
    ///      creation to the broadcaster while `address(this)` stays the script, so the contracts
    ///      end up owned by one address and wired by another and `_wire` reverts
    ///      `OwnableUnauthorizedAccount`. That is why this contract's success path had only ever
    ///      been read. Calling this directly, with no broadcast, is consistent and executes the
    ///      same statements a real run does. The two lines left in `run` are the ones a test
    ///      cannot execute anyway.
    /// @param deployer The address the deployment is made by and handed on from. `msg.sender`
    ///        under a real broadcast; the script contract itself under a test.
    function _deployTestnetStack(address deployer) internal returns (Deployed memory d, GovParams memory p) {
        // Not local, so `_resolveParams` enforces the full set: owner, yield recipient,
        // keeper, nav confirmer and fee wallet all present, the two NAV keys distinct,
        // and the yield recipient distinct from both the deployer and the owner.
        //
        // **Moved ahead of the mocks by round-39 remediation** because `p.keeper` is now needed at
        // construction time. It is `view` and reads only the environment, so what it returns is
        // unchanged; and resolving before anything is deployed is strictly better, because a
        // missing operator address now fails before it has spent a nonce.
        p = _resolveParams(deployer);

        // 🟥 **EACH MOCK IS LOCKED IN THE SAME TRANSACTION THAT CREATES IT, and the ordering is
        // the fix rather than a tidy-up.** These three calls used to sit at the END of this
        // function. Measured from a clean 47-transaction broadcast artefact, that put **40
        // transactions and a block boundary** between the last mock CREATE and the first `lockTo`,
        // and audit round 38 executed both halves of what that buys an attacker: a front-run
        // `seedStakeFor` from a role-less EOA one block after the CREATE succeeded, and the write
        // it made SURVIVED the lockdown that then completed successfully. Creating and locking
        // adjacently narrows the window to one transaction on consecutive nonces of the same
        // sender, which the executed attack no longer has a block to fire in.
        //
        // **It is narrowed, not closed, and saying so is the point.** Only same-transaction gating
        // gives zero, and only a deploy factory does that. The factory was costed and REFUSED:
        // the hazard the ledger named for it - a failed call leaving the mocks permanently
        // unlockable - is actually defeated by atomicity, since a revert unwinds the CREATE too;
        // but it makes `lockAuthority` the factory forever, moves every mock address, and embeds
        // 16,465 measured bytes of mock initcode into a new contract that would need its own
        // deployment record row and its own bytecode-gate row. The residual is covered instead by
        // the configuration-pristine assertions in `script/AssertLocked.s.sol`.
        //
        // **Admin is the deploying key, deliberately not `p.owner`.** These are demo furniture
        // holding no value, and the operator has to be able to whitelist a new adapter or reseed
        // the faucet without scheduling a timelock operation. Handing them to the protocol owner
        // would read as consistency and would make ordinary testnet upkeep a governance action.
        //
        // **Operator is the keeper, and omitting it would have broken the epoch job silently.**
        // The off-chain epoch job signs with the keeper key rather than the deploying key, and its
        // one write to this stack is `setPendingYield`. An admin-only gate would have stopped it
        // as a red scheduled run, which is a channel that reaches nobody unless failure email is
        // switched on.
        MockUSDC usdc = new MockUSDC();
        usdc.lockTo(deployer, p.keeper);
        MockBond bond = new MockBond();
        bond.lockTo(deployer, p.keeper);
        MockFarm farm = new MockFarm(bond, usdc);
        farm.lockTo(deployer, p.keeper);

        deployedUsdc = usdc;
        deployedBond = bond;
        deployedFarm = farm;

        // **Every gated call from here on is made by `deployer`, who is now `admin`, so the gate
        // admits it.** Sign-checked by reading `MockLockdown.gated` against every gated call on
        // this path: `setRewardPool` and the two `setWhitelisted` below are the only three, and
        // under a real broadcast `vm.startBroadcast` sends each of them from the EOA that is
        // `admin`, while under `R36TestnetLockdownHarness` the caller and the deployer are both
        // `address(this)`.
        bond.setRewardPool(address(farm));

        Externals memory e = Externals({
            bond: IDexFiBond(address(bond)),
            farm: IDexFiFarm(address(farm)),
            usdc: IERC20(address(usdc))
        });

        d = _deployProtocol(e, p, deployer);

        // Mirrors the mainnet gate that DexFi controls. On mainnet this is the one
        // integration ask and cannot be self-served (§14 ask #5).
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(d.adapter), true);
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
