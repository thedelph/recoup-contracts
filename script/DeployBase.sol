// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {NAVOracle} from "../src/NAVOracle.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";

/// @title DeployBase
/// @notice The deployment sequence, extracted so local, testnet and mainnet all run
///         the *same* wiring rather than three drifting copies, and so `Deploy.t.sol`
///         can execute it in CI. Previously only the local target wired anything and
///         the mainnet target reverted, which meant the wiring destined for mainnet
///         had never run.
/// @dev Operator addresses (owner, treasury, keeper) are environment parameters, not
///      constants in Config. Config holds protocol parameters and verified external
///      addresses; operator identities are per-deployment, rotatable, and must not be
///      committed. Keeping them here is also what makes the eventual move of `owner`
///      from an EOA to a Safe or timelock a config change rather than a code change.
abstract contract DeployBase is Script {
    /// @notice Per-deployment operator addresses. `owner` is deliberately a plain
    ///         address: an EOA while building, a Safe or TimelockController at
    ///         go-live, with no contract change in between.
    struct GovParams {
        address owner;
        address yieldRecipient;
        address keeper;
        address navConfirmer;
        address protocolFeeWallet;
    }

    /// @notice The DexFi side: mocks locally, the verified Config addresses on Base.
    struct Externals {
        IDexFiBond bond;
        IDexFiFarm farm;
        IERC20 usdc;
    }

    struct Deployed {
        NAVOracle oracle;
        CollateralVault vault;
        DirectCallAdapter adapter;
        CreditManager credit;
        LenderPool pool;
        TreasuryLiquiditySource liquidity;
        EpochHarvester harvester;
        LiquidationAuction auction;
    }

    error OwnerRequired();
    error YieldRecipientRequired();
    error KeeperRequired();
    error NavConfirmerRequired();
    error NavKeysMustDiffer();
    error ProtocolFeeWalletRequired();
    error YieldRecipientCollision(address recipient, string collidesWith);
    error OwnershipNotTransferred(address contractAddr, address actualOwner);
    error WiringIncomplete(string what);

    uint256 internal constant ANVIL_CHAIN_ID = 31337;

    /// @dev Deterministic local stand-in for the treasury. Anything but the deployer:
    ///      defaulting `yieldRecipient` to `msg.sender` is exactly the footgun this
    ///      script exists to remove, and a local default that models the real shape
    ///      is worth more than one that merely runs.
    address internal constant LOCAL_TREASURY = address(uint160(uint256(keccak256("recoup.local.treasury"))));
    address internal constant LOCAL_KEEPER = address(uint160(uint256(keccak256("recoup.local.keeper"))));
    address internal constant LOCAL_NAV_CONFIRMER =
        address(uint160(uint256(keccak256("recoup.local.navConfirmer"))));

    function _isLocal() internal view returns (bool) {
        return block.chainid == ANVIL_CHAIN_ID;
    }

    // ── Parameters ───────────────────────────────────────────────────────────

    /// @notice Resolve operator addresses from the environment, then validate them.
    /// @dev Reading and checking are separate so the rules can be tested directly,
    ///      without a test having to mutate process environment variables that would
    ///      then leak into every other test in the run.
    function _resolveParams(address deployer) internal view returns (GovParams memory p) {
        p.owner = vm.envOr("RECOUP_OWNER", deployer);
        p.yieldRecipient = vm.envOr("RECOUP_YIELD_RECIPIENT", address(0));
        p.keeper = vm.envOr("RECOUP_KEEPER", address(0));
        p.navConfirmer = vm.envOr("RECOUP_NAV_CONFIRMER", address(0));
        p.protocolFeeWallet = vm.envOr("RECOUP_PROTOCOL_FEE_WALLET", address(0));

        if (_isLocal()) {
            if (p.yieldRecipient == address(0)) p.yieldRecipient = LOCAL_TREASURY;
            if (p.keeper == address(0)) p.keeper = LOCAL_KEEPER;
            if (p.navConfirmer == address(0)) p.navConfirmer = LOCAL_NAV_CONFIRMER;
            if (p.protocolFeeWallet == address(0)) p.protocolFeeWallet = LOCAL_TREASURY;
        }

        _validateParams(p, deployer);
    }

    /// @notice The rules a real deployment must satisfy.
    /// @dev Permissive locally so `forge script ... DeployLocal` needs zero setup;
    ///      strict everywhere else so a real deployment cannot inherit a default.
    function _validateParams(GovParams memory p, address deployer) internal view {
        if (p.owner == address(0)) revert OwnerRequired();
        if (_isLocal()) return;

        if (p.yieldRecipient == address(0)) revert YieldRecipientRequired();
        if (p.keeper == address(0)) revert KeeperRequired();
        if (p.navConfirmer == address(0)) revert NavConfirmerRequired();
        // Two keys that are one key are not two keys. The oracle rejects this too;
        // catching it here means a misconfigured deploy fails before it broadcasts.
        if (p.navConfirmer == p.keeper) revert NavKeysMustDiffer();
        if (p.protocolFeeWallet == address(0)) revert ProtocolFeeWalletRequired();
        // A real treasury must be a distinct address. Routing harvested USDC to the
        // key that signed the deploy is the default that looks fine and is not
        // (PRD §4.4, and the yield-routing decision the audit locked in).
        if (p.yieldRecipient == deployer) revert YieldRecipientCollision(p.yieldRecipient, "deployer");
        if (p.yieldRecipient == p.owner) revert YieldRecipientCollision(p.yieldRecipient, "owner");
    }

    // ── Deployment ───────────────────────────────────────────────────────────

    /// @notice Deploy, wire, then hand ownership over. Callable from tests, which is
    ///         the point: this is the code path a mainnet deploy takes.
    /// @dev Construct with `address(this)` as owner so the same caller can perform
    ///      every wiring call, then transfer to `p.owner` last. This ordering is not
    ///      cosmetic: once `owner` is a timelock, wiring before the handover is the
    ///      difference between a one-transaction deploy and one delayed operation per
    ///      setter. `renounceOwnership` is disabled everywhere, but `transferOwnership`
    ///      is untouched, so the handover works.
    /// @dev `deployer` is passed in rather than read from `address(this)`: under
    ///      `vm.startBroadcast` the transactions originate from the broadcasting EOA,
    ///      not from this (ephemeral) script contract, so `address(this)` would name
    ///      an address that never holds authority. Scripts pass `msg.sender`; tests
    ///      pass `address(this)`.
    function _deployProtocol(Externals memory e, GovParams memory p, address deployer)
        internal
        returns (Deployed memory d)
    {
        d.oracle = new NAVOracle(deployer);
        d.vault = new CollateralVault(e.bond, INAVOracle(address(d.oracle)), deployer);
        // owner and yieldRecipient are distinct arguments and must stay visibly
        // distinct at the call site: they are unrelated roles.
        d.adapter = new DirectCallAdapter(e.bond, e.farm, e.usdc, address(d.vault), deployer, p.yieldRecipient);
        d.credit =
            new CreditManager(e.usdc, ICollateralVault(address(d.vault)), INAVOracle(address(d.oracle)), deployer);
        d.pool = new LenderPool(e.usdc, deployer);
        // Funds borrows until the LenderPool takes over in Phase 4. Without it,
        // `borrow` reverts `LiquiditySourceUnset` and the deployed protocol is a
        // read-only museum piece.
        d.liquidity = new TreasuryLiquiditySource(e.usdc, deployer);
        d.harvester = new EpochHarvester(e.usdc, ICreditManager(address(d.credit)), deployer);
        d.auction = new LiquidationAuction(
            e.usdc, ICollateralVault(address(d.vault)), INAVOracle(address(d.oracle)), deployer
        );

        _wire(d, p);

        if (p.owner != deployer) _handOver(d, p.owner);
    }

    /// @dev Every wiring call, made by the deployer while it still holds authority.
    function _wire(Deployed memory d, GovParams memory p) internal {
        d.vault.setCustodyAdapter(ICustodyAdapter(address(d.adapter)));
        d.vault.setCreditManager(address(d.credit));
        d.vault.setLiquidationAuction(address(d.auction));

        d.credit.setLiquiditySource(address(d.liquidity));
        d.credit.setLenderPool(address(d.pool));
        d.credit.setEpochHarvester(address(d.harvester));
        d.credit.setLiquidationAuction(address(d.auction));

        d.liquidity.setCreditManager(address(d.credit));

        d.pool.setCreditManager(address(d.credit));
        d.pool.setEpochHarvester(address(d.harvester));

        d.harvester.setLenderPool(address(d.pool));
        d.harvester.setCustodyAdapter(ICustodyAdapter(address(d.adapter)));
        d.harvester.setProtocolFeeWallet(p.protocolFeeWallet);

        d.auction.setCreditManager(address(d.credit));

        // Live code today, unlike the harvester setters above: NAVOracle.setKeeper
        // works even though postNav reverts, and an unset keeper blocks everyone.
        // Wiring it now means the address is already correct when Phase 2 lands.
        d.oracle.setKeeper(p.keeper);
        // The second key on large NAV moves. Must differ from the keeper, or the
        // two-key guard on the protocol's worst realistic attack (PRD §9) collapses
        // to one key; the oracle enforces that itself.
        d.oracle.setNavConfirmer(p.navConfirmer);

        // **The yield path, which round 7 found was never actually connected.**
        // This deferral used to say the harvester link "becomes load-bearing when the
        // EpochHarvester ships" - and it has shipped: it is constructed above and
        // wired on both the manager and the pool. The trigger fired and the comment
        // outlived it.
        //
        // Two calls are needed and the old note only ever named one. `setHarvester`
        // makes the harvester a permitted claimer, without which `harvest`'s
        // `try adapter.claimYield()` swallows a `NotClaimer` revert every epoch. But
        // the money moves on the second: `_trySweepUsdc` sends the adapter's whole USDC
        // balance to `yieldRecipient`, so while that stays the treasury the split never
        // runs, every epoch reports `ZeroYieldEpoch`, and no borrower's debt is ever
        // written down. The treasury still gets its share - through the harvester's
        // protocol-fee leg, which is where the split says it belongs.
        d.adapter.setHarvester(address(d.harvester));
        d.adapter.setYieldRecipient(address(d.harvester));
    }

    /// @dev Ownership moves last, after everything is wired.
    function _handOver(Deployed memory d, address newOwner) internal {
        d.vault.transferOwnership(newOwner);
        d.adapter.transferOwnership(newOwner);
        d.oracle.transferOwnership(newOwner);
        d.credit.transferOwnership(newOwner);
        d.pool.transferOwnership(newOwner);
        d.harvester.transferOwnership(newOwner);
        d.auction.transferOwnership(newOwner);
    }

    // ── Post-conditions ──────────────────────────────────────────────────────

    /// @notice Assert the deployment is actually usable. Reverting the whole script
    ///         is the point: a half-wired protocol should never be left on chain.
    function _assertWiring(Deployed memory d, GovParams memory p) internal view {
        _requireOwner(address(d.vault), d.vault.owner(), p.owner);
        _requireOwner(address(d.adapter), d.adapter.owner(), p.owner);
        _requireOwner(address(d.oracle), d.oracle.owner(), p.owner);
        _requireOwner(address(d.credit), d.credit.owner(), p.owner);
        _requireOwner(address(d.pool), d.pool.owner(), p.owner);
        _requireOwner(address(d.harvester), d.harvester.owner(), p.owner);
        _requireOwner(address(d.auction), d.auction.owner(), p.owner);

        if (address(d.vault.custodyAdapter()) != address(d.adapter)) revert WiringIncomplete("vault.custodyAdapter");
        if (d.vault.creditManager() != address(d.credit)) revert WiringIncomplete("vault.creditManager");
        if (d.vault.liquidationAuction() != address(d.auction)) revert WiringIncomplete("vault.liquidationAuction");

        // The other two legs of the same triangle. Both are wired in `_wire` and
        // neither was asserted, so a deployment could reach production able to seize
        // collateral but unable to open an auction, or with an auction nothing would
        // accept settlement from. Now Phase 3 is real, that is not theoretical.
        if (d.credit.liquidationAuction() != address(d.auction)) {
            revert WiringIncomplete("credit.liquidationAuction");
        }
        if (d.auction.creditManager() != address(d.credit)) revert WiringIncomplete("auction.creditManager");

        if (address(d.harvester.custodyAdapter()) == address(0)) revert WiringIncomplete("harvester.custodyAdapter");
        if (d.harvester.lenderPool() == address(0)) revert WiringIncomplete("harvester.lenderPool");
        if (d.harvester.protocolFeeWallet() == address(0)) revert WiringIncomplete("harvester.protocolFeeWallet");
        if (d.oracle.keeper() == address(0)) revert WiringIncomplete("oracle.keeper");
        if (d.oracle.navConfirmer() == address(0)) revert WiringIncomplete("oracle.navConfirmer");

        // Without these two the protocol deploys but cannot lend a cent, which is the
        // failure mode worth catching in the script rather than in production.
        if (d.credit.liquiditySource() != address(d.liquidity)) {
            revert WiringIncomplete("credit.liquiditySource");
        }
        if (d.liquidity.creditManager() != address(d.credit)) {
            revert WiringIncomplete("liquidity.creditManager");
        }

        // The audit's finding #1 in assertion form: the vault has no USDC egress, so
        // routing yield there strands it permanently.
        address sink = d.adapter.yieldRecipient();
        if (sink == address(d.vault)) revert YieldRecipientCollision(sink, "vault");
        if (sink == address(d.adapter)) revert YieldRecipientCollision(sink, "adapter");
        if (sink == address(0)) revert YieldRecipientRequired();
        // The three checks above rule out the sinks that strand yield, and every one
        // of them passed while 100% of it went to an EOA and the whole split sat idle.
        // Ruling out wrong destinations is not the same as asserting the right one.
        if (sink != address(d.harvester)) revert WiringIncomplete("adapter.yieldRecipient");
        if (d.adapter.harvester() != address(d.harvester)) revert WiringIncomplete("adapter.harvester");
        if (d.credit.epochHarvester() != address(d.harvester)) revert WiringIncomplete("credit.epochHarvester");
    }

    function _requireOwner(address contractAddr, address actual, address expected) private pure {
        if (actual != expected) revert OwnershipNotTransferred(contractAddr, actual);
    }

    // ── Logging ──────────────────────────────────────────────────────────────

    function _log(Deployed memory d, GovParams memory p) internal pure {
        console.log("owner             ", p.owner);
        console.log("yieldRecipient    ", p.yieldRecipient);
        console.log("keeper            ", p.keeper);
        console.log("protocolFeeWallet ", p.protocolFeeWallet);
        console.log("NAVOracle         ", address(d.oracle));
        console.log("CollateralVault   ", address(d.vault));
        console.log("DirectCallAdapter ", address(d.adapter));
        console.log("CreditManager     ", address(d.credit));
        console.log("LiquiditySource   ", address(d.liquidity));
        console.log("LenderPool        ", address(d.pool));
        console.log("EpochHarvester    ", address(d.harvester));
        console.log("LiquidationAuction", address(d.auction));
        console.log("Post-deploy: fund the liquidity source and bootstrap the NAV oracle.");
    }
}
