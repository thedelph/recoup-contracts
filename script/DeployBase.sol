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
///
/// @dev **`ReferralRegistry` is deliberately NOT deployed here, and must not be added.**
///      It has zero coupling in both directions, so `_assertWiring` would have nothing to
///      assert about it, and a `Deployed` field with no possible assertion is the shape of
///      audit-7 finding #6. The decisive reason is G9: the supported fix for a core defect
///      before launch is to redeploy this whole set and move the bonds across, and a
///      registry inside that set would take a new address every time. Bindings are
///      immutable, address-scoped and non-portable, so each redeploy would orphan every
///      referral binding permanently, with no owner able to repair it. The registry's
///      lifecycle has to outlive the protocol's. It ships via
///      `script/DeployReferral.s.sol`, once, on its own schedule.
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
    /// @dev The mirror image of `WiringIncomplete`, and audit round 11 is why it has to exist as
    ///      its own error rather than as a missing check. A pointer that is set too early is not a
    ///      half-finished deployment, it is a finished deployment with a role nobody funds - so
    ///      "incomplete" would be the wrong word in the revert reason an operator reads at 3am.
    error LenderExposureWiredEarly(string what);
    /// @dev The Phase-4 post-condition that is about a relation rather than about an address.
    ///      `CreditManager._socialise` refuses to charge a pool that is not also the liquidity
    ///      source, so a deployment where these two disagree has a loss sink that can never be
    ///      charged - which is precisely the state round 11 found shipped.
    error LenderRolesDisagree(address liquiditySource, address lenderPool);

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

    /// @dev Every wiring call the Phase-2/3 protocol needs, made by the deployer while it still
    ///      holds authority. **The two lender-share pointers are deliberately NOT among them** -
    ///      see `_wirePhase4`.
    function _wire(Deployed memory d, GovParams memory p) internal {
        d.vault.setCustodyAdapter(ICustodyAdapter(address(d.adapter)));
        d.vault.setCreditManager(address(d.credit));
        d.vault.setLiquidationAuction(address(d.auction));

        d.credit.setLiquiditySource(address(d.liquidity));
        d.credit.setEpochHarvester(address(d.harvester));
        d.credit.setLiquidationAuction(address(d.auction));

        d.liquidity.setCreditManager(address(d.credit));

        // The pool's own two pointers stay here, and only these two. They cost the protocol
        // nothing while the pool is dormant: they say who the pool would answer if it were ever
        // asked, not that anyone is asking. `setCreditManager` in particular refuses once the pool
        // has principal out, so wiring it now is what keeps it wirable at all later.
        d.pool.setCreditManager(address(d.credit));
        d.pool.setEpochHarvester(address(d.harvester));

        // **Audit round 11: the two calls that used to sit here paid the lender share for zero
        // credit exposure.** `credit.setLenderPool` and `harvester.setLenderPool` were made in the
        // same breath as `credit.setLiquiditySource(address(d.liquidity))` three lines up - so the
        // treasury funded every loan and absorbed every default while `EpochHarvester`, whose
        // `flushLenderYield` is permissionless, handed pool depositors `Config.SPLIT_LENDER_BPS`
        // of every epoch. Anyone could deposit into a pool that carried none of the risk and
        // collect a quarter of the yield for it, and nothing in the protocol could stop them
        // because nothing about it was a bug in a contract: it was two lines of the deploy script.
        //
        // It got worse rather than better when the socialisation fix landed in the same round.
        // `CreditManager._socialise` now offers a loss only to a pool that is also the liquidity
        // source, because a balance sheet that lent nothing cannot be charged for a default. Under
        // the old wiring the pool was therefore the *nominal* loss sink and could never actually
        // be charged - the script named a role it had made unperformable. A wiring that states a
        // relationship the code refuses to honour is worse than no wiring at all, because
        // `_assertWiring` was asserting it and reporting the deployment healthy.
        //
        // So the lender legs move out of the shipping path entirely and into `_wirePhase4`, which
        // sets the liquidity source and the loss sink together or not at all.
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

    /// @notice The Phase-4 switchover: the LenderPool takes over funding the book, and takes on
    ///         the losses that come with it, in one operation.
    /// @dev Not called by `_deployProtocol`. A deployment ships with the treasury float funding
    ///      borrows and no lender exposure at all, and this is the separate, later transaction
    ///      that changes that - run by whoever owns the contracts at the time, which by then is
    ///      meant to be a Safe or a timelock rather than the deploying key.
    ///
    ///      **It lives here, and is `internal` rather than private, so the tests can execute it.**
    ///      That is the entire reason `DeployBase` exists: the mainnet wiring runs in CI before it
    ///      runs on mainnet. A switchover written as a runbook step instead of as code would be
    ///      the same class of defect as the one it fixes - the old script's mainnet target
    ///      reverted, so the wiring destined for mainnet had never executed anywhere.
    ///
    ///      The order is load-bearing, top to bottom:
    ///
    ///      1. `settlePrincipal` first. `setLiquiditySource` refuses while `pendingPrincipal` is
    ///         non-zero, and the manager's own migration notes say the principal becomes
    ///         unreachable by every contract if the pointer moves before the money does. Guarded
    ///         on the counter because the call reverts `NothingToSettle` at zero, and a switchover
    ///         on a book that was already flat must not fail for being tidy.
    ///      2. `setLiquiditySource` before `setLenderPool`, so the pool is the funder before it is
    ///         the sink. Never the reverse: a pool named as the loss sink while the treasury still
    ///         funds the book is exactly the shipped state round 11 found, and `_socialise` would
    ///         refuse to charge it anyway.
    ///      3. `harvester.setLenderPool` last, because it is the leg that starts paying. The
    ///         lender share is only earned once the pool is carrying the credit risk, and every
    ///         epoch harvested before this line stays accrued in `pendingLenderYield` and is
    ///         delivered whole by the first `flushLenderYield` after it. Nothing is lost by
    ///         waiting; something is given away by not.
    function _wirePhase4(Deployed memory d) internal {
        if (d.credit.pendingPrincipal() != 0) d.credit.settlePrincipal();

        d.credit.setLiquiditySource(address(d.pool));
        d.credit.setLenderPool(address(d.pool));
        d.harvester.setLenderPool(address(d.pool));
    }

    /// @dev Ownership moves last, after everything is wired.
    ///      Every `Ownable` in `Deployed` belongs in this list. `d.liquidity` was missing from it,
    ///      and from `_assertWiring` below, and from the equivalent list in `test/Deploy.t.sol` -
    ///      so a deployment handing seven contracts to the governance Safe left the eighth with
    ///      the broadcasting EOA, and the post-condition check that exists to catch exactly this
    ///      reported success. The omitted one holds the whole lending float behind an uncapped
    ///      `onlyOwner withdraw(to, amount)`, and CI asserted "the deployer owns nothing" while
    ///      the deployer owned the money.
    function _handOver(Deployed memory d, address newOwner) internal {
        d.vault.transferOwnership(newOwner);
        d.adapter.transferOwnership(newOwner);
        d.oracle.transferOwnership(newOwner);
        d.credit.transferOwnership(newOwner);
        d.pool.transferOwnership(newOwner);
        d.harvester.transferOwnership(newOwner);
        d.auction.transferOwnership(newOwner);
        d.liquidity.transferOwnership(newOwner);
    }

    // ── Post-conditions ──────────────────────────────────────────────────────

    /// @notice Assert the deployment is actually usable. Reverting the whole script
    ///         is the point: a half-wired protocol should never be left on chain.
    function _assertWiring(Deployed memory d, GovParams memory p) internal view {
        _assertCoreGraph(d, p);

        // **The two legs that must be unset, and asserting that is not the same as dropping the
        // assertion.** These two lines used to require both pointers to name the pool, which is
        // how audit round 11 found a deployment paying `Config.SPLIT_LENDER_BPS` of every epoch to
        // depositors who funded no loan and could not be charged for a default. The temptation on
        // finding that is to delete the checks along with the wiring; this file's own comment
        // fifty lines down is why that is wrong - "ruling out wrong destinations is not the same
        // as asserting the right one", and for a pre-Phase-4 deployment the right one is nothing.
        //
        // Zero is a real, checkable post-condition here, not an absence. `CreditManager` treats an
        // unset `lenderPool` as "the source bears its own losses" and `EpochHarvester` refuses the
        // flush with `NotWired("lenderPool")` while accruing the share for whoever eventually
        // earns it, so both contracts have a defined and safe behaviour at zero. Asserting it is
        // what stops the two lines being quietly restored.
        if (d.credit.lenderPool() != address(0)) revert LenderExposureWiredEarly("credit.lenderPool");
        if (d.harvester.lenderPool() != address(0)) revert LenderExposureWiredEarly("harvester.lenderPool");

        // Without these two the protocol deploys but cannot lend a cent, which is the
        // failure mode worth catching in the script rather than in production. **Not shared with
        // the Phase-4 assertion**, because this is the one pointer the switchover genuinely moves:
        // afterwards the source is the pool, and asserting the treasury there would refuse the
        // deployment the switchover exists to produce.
        if (d.credit.liquiditySource() != address(d.liquidity)) {
            revert WiringIncomplete("credit.liquiditySource");
        }
        // `liquidity.creditManager` moved into `_assertCoreGraph` in audit round 16, because the
        // switchover does not touch it and that is the shared function's inclusion rule. It is not
        // restated here for the reason the whole consolidation exists: two hand-maintained copies
        // of one set is how the drift happened twice.
    }

    /// @notice Everything both wiring assertions must check, because the switchover does not move
    ///         any of it.
    /// @dev **Shared rather than restated, and the reason is the finding that produced it.** Audit
    ///      round 15 found `_assertWiring` testing four pointers for non-zero instead of for the
    ///      right address, in a file that says "ruling out wrong destinations is not the same as
    ///      asserting the right one" fifty lines further down, and found `_assertPhase4Wiring`
    ///      silently missing about eighteen of these including **every** ownership check. Two
    ///      hand-maintained copies of one set is how both happened, so there is now one copy.
    ///
    ///      What deliberately stays out: the two `LenderExposureWiredEarly` checks, which Phase 4
    ///      exists to invert, and the treasury liquidity source, which it replaces. Both are stated
    ///      in the callers rather than parameterised here, because a shared function branching on
    ///      "which phase" would have to be read twice to answer either question.
    function _assertCoreGraph(Deployed memory d, GovParams memory p) private view {
        _requireOwner(address(d.vault), d.vault.owner(), p.owner);
        _requireOwner(address(d.adapter), d.adapter.owner(), p.owner);
        _requireOwner(address(d.oracle), d.oracle.owner(), p.owner);
        _requireOwner(address(d.credit), d.credit.owner(), p.owner);
        _requireOwner(address(d.pool), d.pool.owner(), p.owner);
        _requireOwner(address(d.harvester), d.harvester.owner(), p.owner);
        _requireOwner(address(d.auction), d.auction.owner(), p.owner);
        // The one that has been missed twice, and it holds the lending float behind an uncapped
        // `onlyOwner` withdraw.
        _requireOwner(address(d.liquidity), d.liquidity.owner(), p.owner);

        // The pool's own two legs, which a shipping deployment does set. Each fails quietly rather
        // than loudly: a wrong `pool.epochHarvester` is swallowed by the harvester's best-effort
        // catch and the lender share accrues forever with no error at all. `_wire` set them and
        // this block checked neither, which is the shape audit-7 finding #6 named.
        if (d.pool.creditManager() != address(d.credit)) revert WiringIncomplete("pool.creditManager");
        if (d.pool.epochHarvester() != address(d.harvester)) revert WiringIncomplete("pool.epochHarvester");

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

        // **These four tested for non-zero rather than for the right address, and this file names
        // the rule it was breaking a few lines below: "ruling out wrong destinations is not the
        // same as asserting the right one". It said it and then broke it four times**, which is
        // what audit round 15 found.
        //
        // The cost is not cosmetic, and it is worst on the first. A harvester pointed at some
        // *other* live adapter passes a non-zero check, and then `harvest()` declines every epoch
        // forever with `EpochDeclinedUncorroborated`, because `lastCorroboratedYield` is seeded
        // from a counter on an adapter nothing else moves. Repair is `onlyOwner`, and by go-live
        // the owner is a timelock.
        //
        // All four are set from exactly these values in `_wire`, so the happy path is unchanged and
        // only a wrong deployment starts failing.
        if (address(d.harvester.custodyAdapter()) != address(d.adapter)) {
            revert WiringIncomplete("harvester.custodyAdapter");
        }
        if (d.harvester.protocolFeeWallet() != p.protocolFeeWallet) {
            revert WiringIncomplete("harvester.protocolFeeWallet");
        }
        if (d.oracle.keeper() != p.keeper) revert WiringIncomplete("oracle.keeper");
        if (d.oracle.navConfirmer() != p.navConfirmer) revert WiringIncomplete("oracle.navConfirmer");

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

        // **The two audit round 16 found missing, and neither was in the exclusions list**, so both
        // read as drift rather than intent - which is the two-hand-maintained-lists failure this
        // consolidation was written to end.
        //
        // `harvester.creditManager` is the only pointer in the graph that is constructor-set with a
        // live `onlyOwner` setter behind it, and its divergence bricks the permissionless
        // `harvest()` forever with an `onlyOwner` repair. Four agents.
        if (address(d.harvester.creditManager()) != address(d.credit)) {
            revert WiringIncomplete("harvester.creditManager");
        }
        // `liquidity.creditManager` was asserted only in `_assertWiring`, even though `_wirePhase4`
        // does not move it - and "everything the switchover does not change" is this function's own
        // stated inclusion rule. Three agents. The treasury source keeps this pointer after the
        // switchover: the pool becomes the funder, and the float it is being replaced as still
        // answers to the same manager for whatever is left to settle home.
        if (d.liquidity.creditManager() != address(d.credit)) {
            revert WiringIncomplete("liquidity.creditManager");
        }
    }

    /// @notice The post-condition for `_wirePhase4`, and the counterpart to `_assertWiring`'s two
    ///         "must still be zero" checks.
    /// @dev Deliberately a separate function rather than a flag on `_assertWiring`. The two
    ///      describe states that contradict each other on three pointers, and a single function
    ///      branching on a boolean would have to be read twice to answer either question. Run this
    ///      one immediately after the switchover transaction; `_assertWiring` no longer holds once
    ///      it has, because `credit.liquiditySource` is the pool rather than the treasury float.
    function _assertPhase4Wiring(Deployed memory d, GovParams memory p) internal view {
        // **Everything `_assertWiring` checks that a switchover does not change, and audit round 15
        // is why it is here.** This function dropped roughly eighteen assertions, including every
        // ownership check - so nothing after the switchover re-verified that the eight contracts
        // were owned by anybody in particular, and `d.liquidity` is the one that has been missed
        // twice before while holding the lending float behind an uncapped `onlyOwner` withdraw.
        //
        // Shared rather than restated, because the drift between these two lists *is* the finding.
        // Two hand-maintained copies of one set is how the first one came to name a rule it broke
        // four times.
        _assertCoreGraph(d, p);

        // All three legs, together. Half a switchover is the failure this exists to catch: the
        // pool funding borrows without being the loss sink means depositors take the credit risk
        // and the deferral counter never fills, and the sink without the funding is round 11 all
        // over again.
        if (d.credit.liquiditySource() != address(d.pool)) revert WiringIncomplete("credit.liquiditySource");
        if (d.credit.lenderPool() != address(d.pool)) revert WiringIncomplete("credit.lenderPool");
        if (d.harvester.lenderPool() != address(d.pool)) revert WiringIncomplete("harvester.lenderPool");

        // Redundant against the two lines above only for as long as both compare with the same
        // `d.pool`, and that is the point of stating it separately: this is the relation
        // `CreditManager._socialise` and `flushSocialisedLoss` actually evaluate at runtime, read
        // off the contract rather than off this struct. It stays a true statement of the intent
        // even if somebody rewrites what the assertions above compare against.
        address source = d.credit.liquiditySource();
        address sink = d.credit.lenderPool();
        if (source != sink) revert LenderRolesDisagree(source, sink);

        // The pool's own legs are as load-bearing after the switchover as before it - `lend` and
        // `repayPrincipal` are `onlyCreditManager`, so a pool pointing at the wrong manager funds
        // nothing and the first borrow reverts - and they are now asserted in `_assertCoreGraph`
        // above, along with everything else the switchover leaves alone.
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
        // Printed because the deployment is deliberately incomplete: the LenderPool above is
        // deployed and knows who its manager is, and is wired into nothing that pays it or
        // charges it. That is the safe shipping state, and it takes an explicit later operation
        // (`_wirePhase4`) to leave it.
        console.log("The LenderPool ships dormant. Phase 4 wires funding and losses together.");
    }
}
