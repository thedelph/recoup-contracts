// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev The canonical accounting additions are deliberately implementation-specific rather than
///      part of ILenderPool. Keeping their test interface local makes that API boundary explicit.
interface ICanonicalLenderPool {
    function depositCapUsage() external view returns (uint256);
    function unmanagedSurplus() external view returns (uint256);
    function cashDeficit() external view returns (uint256);
    function claimLiquidityDeficit() external view returns (uint256);
    function claimSolvencyDeficit() external view returns (uint256);
    function entryPriceDeficit() external view returns (uint256);
    function minimumEntryAssets() external view returns (uint256);
    function maximumShareSupply() external view returns (uint256);
    function reconcileCashDeficit() external returns (uint256 lost, uint256 yieldWrittenOff);
    function coverClaimDeficit(uint256 amount) external returns (uint256 remaining);
    function coverEntryPriceDeficit(uint256 amount) external returns (uint256 remaining);
}

/// @notice Stateful production-pool driver for the canonical-cash F3 design.
/// @dev Principal-unit ghosts and the lowered-ceiling campaign are gone with their production
///      ledger. The handler instead varies raw donations and external cash destruction alongside
///      every ordinary pool flow, while retaining the request, claim, impairment, pause, price and
///      conservation surfaces that do not depend on a principal representation.
contract CanonicalLenderHandler is Test {
    uint256 private constant MAX_STRESS_CYCLES_PER_ACTION = 4;
    uint256 private constant MAX_STRESS_CYCLES_TOTAL = 128;

    LenderPool public immutable pool;
    ICanonicalLenderPool public immutable canonical;
    MockUSDC public immutable usdc;
    address public immutable owner;
    address public immutable creditManager;
    address public immutable epochHarvester;
    address public immutable destructionSink;

    address[] public actors;
    address[] public borrowers;

    uint256 public totalMinted;
    uint256 public depositsDone;
    uint256 public mintsDone;
    uint256 public withdrawalsDone;
    uint256 public redeemsDone;
    uint256 public donationsDone;
    uint256 public destructionsDone;
    uint256 public reconciliationsDone;
    uint256 public lendsDone;
    uint256 public repaysDone;
    uint256 public yieldsDone;
    uint256 public recoveriesDone;
    uint256 public lossesDone;
    uint256 public requestsDone;
    uint256 public cancellationsDone;
    uint256 public servicesDone;
    uint256 public claimsDone;
    uint256 public coversDone;
    uint256 public entryCoversDone;
    uint256 public lossRefillCyclesDone;
    uint256 public numericReserveStatesReached;
    uint256 public lendTapersReached;
    uint256 public transfersDone;
    uint256 public impairmentsDone;
    uint256 public releasesDone;
    uint256 public pausesDone;
    uint256 public unpausesDone;
    uint256 public timeAdvances;

    uint256 public donationViewMismatches;
    uint256 public otherRequestMutations;
    uint256 public serviceAccountingMismatches;
    uint256 public lifetimeLossFell;
    uint256 public lifetimeLossRoseWithoutLossAction;
    uint256 public principalRoseWithoutLend;
    uint256 public protocolEntryDeficitMismatches;

    mapping(address controller => bytes32 fingerprint) private _requestBefore;

    struct Watch {
        uint256 lifetimeLoss;
        uint256 outstandingPrincipal;
        uint256 entryPriceDeficit;
        uint256 losses;
        uint256 lends;
    }

    Watch private _before;

    modifier watched() {
        _observe();
        _;
        _settle();
    }

    constructor(LenderPool pool_, MockUSDC usdc_, address owner_, address creditManager_, address epochHarvester_) {
        pool = pool_;
        canonical = ICanonicalLenderPool(address(pool_));
        usdc = usdc_;
        owner = owner_;
        creditManager = creditManager_;
        epochHarvester = epochHarvester_;
        destructionSink = makeAddr("cash-destruction-sink");

        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string(abi.encodePacked("canonical-lender-", i)));
            actors.push(actor);
            vm.prank(actor);
            usdc.approve(address(pool), type(uint256).max);
        }
        for (uint256 i = 0; i < 2; i++) {
            borrowers.push(makeAddr(string(abi.encodePacked("canonical-borrower-", i))));
        }

        vm.prank(creditManager);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(epochHarvester);
        usdc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function borrowerCount() external view returns (uint256) {
        return borrowers.length;
    }

    function deposit(uint256 actorSeed, uint96 amountSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(amountSeed), 1, 5_000e6);
        _mint(actor, amount);

        vm.prank(actor);
        try pool.deposit(amount, actor) returns (uint256 shares) {
            if (shares != 0) ++depositsDone;
        } catch {}
    }

    function mintShares(uint256 actorSeed, uint96 shareSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 shares = bound(uint256(shareSeed), 1, 5_000e9);
        uint256 cost = pool.previewMint(shares);
        if (cost == 0 || cost > 5_000e6) return;
        _mint(actor, cost);

        vm.prank(actor);
        try pool.mint(shares, actor) returns (uint256) {
            ++mintsDone;
        } catch {}
    }

    function withdrawMaximum(uint256 actorSeed, uint96 fractionSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 maximum = pool.maxWithdraw(actor);
        if (maximum == 0) return;
        uint256 assets = bound(uint256(fractionSeed), 1, maximum);

        vm.prank(actor);
        try pool.withdraw(assets, actor, actor) returns (uint256) {
            ++withdrawalsDone;
        } catch {}
    }

    function redeemMaximum(uint256 actorSeed, uint256 fractionSeed) external watched {
        address actor = _actor(actorSeed);
        uint256 maximum = pool.maxRedeem(actor);
        if (maximum == 0) return;
        uint256 shares = bound(uint256(fractionSeed), 1, maximum);

        vm.prank(actor);
        try pool.redeem(shares, actor, actor) returns (uint256) {
            ++redeemsDone;
        } catch {}
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 fractionSeed) external watched {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 balance = pool.balanceOf(from);
        if (balance == 0) return;

        vm.prank(from);
        try pool.transfer(to, bound(uint256(fractionSeed), 1, balance)) returns (bool moved) {
            if (moved) ++transfersDone;
        } catch {}
    }

    /// @dev A donation is required to be inert only while no prior external subtraction is being
    ///      masked. Filling an observed deficit can restore value up to the recognised book, which
    ///      is the unavoidable provenance window the design discloses.
    function donate(uint96 amountSeed) external {
        uint256 amount = bound(uint256(amountSeed), 1, 5_000e6);
        uint256 deficitBefore = canonical.cashDeficit();
        uint256 assetsBefore = pool.totalAssets();
        uint256 entryBefore = pool.previewDeposit(1e6);
        uint256 availableBefore = pool.available();
        uint256 usageBefore = canonical.depositCapUsage();
        uint256 roomBefore = pool.maxDeposit(actors[0]);

        _mint(address(pool), amount);
        ++donationsDone;

        if (
            deficitBefore == 0
                && (pool.totalAssets() != assetsBefore
                    || pool.previewDeposit(1e6) != entryBefore
                    || pool.available() != availableBefore
                    || canonical.depositCapUsage() != usageBefore
                    || pool.maxDeposit(actors[0]) != roomBefore)
        ) ++donationViewMismatches;
    }

    /// @dev MockUSDC has no issuer-burn method because current USDC does not expose one for an
    ///      arbitrary holder. Pranking the pool for this transfer changes only raw token backing,
    ///      which is the same observable state a destructive upgrade or adversarial token creates.
    function destroyRawCash(uint96 amountSeed) external {
        uint256 raw = usdc.balanceOf(address(pool));
        if (raw == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, raw);
        vm.prank(address(pool));
        if (usdc.transfer(destructionSink, amount)) ++destructionsDone;
    }

    function reconcileCashDeficit() external watched {
        try canonical.reconcileCashDeficit() returns (uint256 lost, uint256) {
            if (lost != 0) ++reconciliationsDone;
        } catch {}
    }

    function coverClaimDeficit(uint96 amountSeed) external watched {
        uint256 deficit = canonical.claimSolvencyDeficit();
        if (deficit == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, deficit);
        _mint(address(this), amount);
        try canonical.coverClaimDeficit(amount) returns (uint256) {
            ++coversDone;
        } catch {}
    }

    function coverEntryPriceDeficit(uint96 amountSeed) external watched {
        if (canonical.claimLiquidityDeficit() != 0) return;
        uint256 deficit = canonical.entryPriceDeficit();
        if (deficit == 0) return;

        uint256 amount = bound(uint256(amountSeed), 1, deficit);
        _mint(address(this), amount);
        try canonical.coverEntryPriceDeficit(amount) returns (uint256) {
            ++entryCoversDone;
        } catch {}
    }

    /// @dev Advances the real production pool towards the numeric reserve with a bounded number of
    ///      full-loss cycles. The total cap keeps a long invariant campaign from spending most of
    ///      its runtime after the boundary has already been demonstrated.
    function stressLossRefill(uint8 cyclesSeed, uint256 actorSeed) external watched {
        if (
            pool.paused() || pool.outstandingPrincipal() != 0 || canonical.cashDeficit() != 0
                || canonical.claimLiquidityDeficit() != 0 || canonical.entryPriceDeficit() != 0
        ) return;

        address actor = _actor(actorSeed);
        uint256 cycles = bound(uint256(cyclesSeed), 1, MAX_STRESS_CYCLES_PER_ACTION);
        bool startedSafe = true;

        for (uint256 i; i < cycles; ++i) {
            uint256 lendable = pool.available();
            if (lendable == 0) {
                if (canonical.minimumEntryAssets() != 0) ++lendTapersReached;
                return;
            }
            if (lossRefillCyclesDone >= MAX_STRESS_CYCLES_TOTAL) return;

            vm.prank(creditManager);
            try pool.lend(lendable) {
                ++lendsDone;
            } catch {
                return;
            }
            _recordProtocolEntryDeficit(startedSafe);

            vm.prank(creditManager);
            try pool.socialiseLoss(lendable) returns (uint256 absorbed) {
                if (absorbed != lendable) return;
                ++lossesDone;
            } catch {
                return;
            }
            _recordProtocolEntryDeficit(startedSafe);

            uint256 refill = pool.maxDeposit(actor);
            if (refill == 0) return;
            _mint(actor, refill);
            vm.prank(actor);
            try pool.deposit(refill, actor) returns (uint256 shares) {
                if (shares == 0) return;
                ++depositsDone;
                ++lossRefillCyclesDone;
                if (canonical.minimumEntryAssets() != 0) ++numericReserveStatesReached;
            } catch {
                return;
            }
            _recordProtocolEntryDeficit(startedSafe);
        }
    }

    function lend(uint96 amountSeed) external watched {
        uint256 available = pool.available();
        if (available == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, available);

        vm.prank(creditManager);
        try pool.lend(amount) {
            ++lendsDone;
        } catch {}
    }

    function repay(uint96 amountSeed) external watched {
        uint256 principal = pool.outstandingPrincipal();
        uint256 top = principal == 0 ? 1_000e6 : principal + (principal > 1_000e6 ? 1_000e6 : principal);
        if (top > 5_000e6) top = 5_000e6;
        uint256 amount = bound(uint256(amountSeed), 1, top);
        _mint(creditManager, amount);

        vm.prank(creditManager);
        try pool.repayPrincipal(amount) {
            ++repaysDone;
        } catch {}
    }

    function distributeYield(uint96 amountSeed) external watched {
        uint256 capital = pool.totalAssets();
        if (capital == 0) return;
        uint256 top = capital > 1_000e6 ? 1_000e6 : capital;
        uint256 amount = bound(uint256(amountSeed), 1, top);
        _mint(epochHarvester, amount);

        vm.prank(epochHarvester);
        try pool.distributeYield(amount) {
            ++yieldsDone;
        } catch {}
    }

    function recoverLoss(uint96 amountSeed) external watched {
        uint256 amount = bound(uint256(amountSeed), 1, 1_000e6);
        _mint(creditManager, amount);

        vm.prank(creditManager);
        try pool.recoverLoss(amount) {
            ++recoveriesDone;
        } catch {}
    }

    function socialiseLoss(uint96 amountSeed) external watched {
        uint256 principal = pool.outstandingPrincipal();
        if (principal == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, principal);

        vm.prank(creditManager);
        try pool.socialiseLoss(amount) returns (uint256 absorbed) {
            if (absorbed != 0) ++lossesDone;
        } catch {}
    }

    function requestWithdrawal(uint256 actorSeed, uint256 receiverSeed, uint256 shareSeed) external watched {
        address controller = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        uint256 balance = pool.balanceOf(controller);
        if (balance == 0) return;
        _observeOtherRequests(controller);

        vm.prank(controller);
        try pool.requestWithdrawal(bound(uint256(shareSeed), 1, balance), receiver) {
            ++requestsDone;
        } catch {}
        _settleOtherRequests(controller);
    }

    function cancelWithdrawalRequest(uint256 actorSeed) external watched {
        address controller = _actor(actorSeed);
        (uint256 requestId,,,,) = pool.withdrawalRequest(controller);
        if (requestId == 0) return;
        _observeOtherRequests(controller);

        vm.prank(controller);
        try pool.cancelWithdrawalRequest() {
            ++cancellationsDone;
        } catch {}
        _settleOtherRequests(controller);
    }

    function serviceWithdrawalRequest(uint256 actorSeed, uint256 shareSeed) external watched {
        address controller = _actor(actorSeed);
        (uint256 requestId, address receiver, uint256 requestShares,,) = pool.withdrawalRequest(controller);
        if (requestId == 0) return;
        uint256 maximum = pool.maxRequestRedeem(controller);
        if (maximum == 0) return;
        uint256 shares = bound(uint256(shareSeed), 1, maximum);
        uint256 expectedAssets = pool.previewRedeem(shares);
        uint256 claimBefore = pool.claimable(receiver);
        uint256 totalBefore = pool.totalClaimable();
        uint256 supplyBefore = pool.totalSupply();
        uint256 queuedBefore = pool.queuedShares();
        _observeOtherRequests(controller);

        vm.prank(controller);
        try pool.serviceWithdrawalRequest(controller, shares, expectedAssets) returns (uint256 assets) {
            ++servicesDone;
            (,, uint256 remainingShares,,) = pool.withdrawalRequest(controller);
            if (
                assets != expectedAssets || pool.claimable(receiver) != claimBefore + assets
                    || pool.totalClaimable() != totalBefore + assets || pool.totalSupply() != supplyBefore - shares
                    || pool.queuedShares() != queuedBefore - shares || remainingShares != requestShares - shares
            ) ++serviceAccountingMismatches;
        } catch {}
        _settleOtherRequests(controller);
    }

    function claim(uint256 actorSeed) external watched {
        address receiver = _actor(actorSeed);
        if (pool.claimable(receiver) == 0) return;

        vm.prank(receiver);
        try pool.claim() returns (uint256 amount) {
            if (amount != 0) ++claimsDone;
        } catch {}
    }

    function impair(uint256 borrowerSeed, uint96 amountSeed) external watched {
        address borrower = _borrower(borrowerSeed);
        uint256 amount = bound(uint256(amountSeed), 1, Config.GLOBAL_BORROW_CAP_MAX);
        vm.prank(creditManager);
        try pool.impair(borrower, amount) returns (bool wrote) {
            if (wrote) ++impairmentsDone;
        } catch {}
    }

    function releaseImpairment(uint256 borrowerSeed) external watched {
        address borrower = _borrower(borrowerSeed);
        vm.prank(creditManager);
        try pool.releaseImpairment(borrower) returns (bool wrote) {
            if (wrote) ++releasesDone;
        } catch {}
    }

    function togglePause() external watched {
        bool isPaused = pool.paused();
        vm.prank(owner);
        if (isPaused) {
            pool.unpause();
            ++unpausesDone;
        } else {
            pool.pause();
            ++pausesDone;
        }
    }

    function passTime(uint32 secondsSeed) external watched {
        skip(bound(uint256(secondsSeed), 1, 7 days));
        ++timeAdvances;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _borrower(uint256 seed) private view returns (address) {
        return borrowers[seed % borrowers.length];
    }

    function _mint(address to, uint256 amount) private {
        usdc.mint(to, amount);
        totalMinted += amount;
    }

    function _requestFingerprint(address controller) private view returns (bytes32) {
        (uint256 requestId, address receiver, uint256 shares,,) = pool.withdrawalRequest(controller);
        return keccak256(abi.encode(requestId, receiver, shares));
    }

    function _observeOtherRequests(address selected) private {
        for (uint256 i = 0; i < actors.length; i++) {
            address controller = actors[i];
            if (controller != selected) _requestBefore[controller] = _requestFingerprint(controller);
        }
    }

    function _settleOtherRequests(address selected) private {
        for (uint256 i = 0; i < actors.length; i++) {
            address controller = actors[i];
            if (controller != selected && _requestBefore[controller] != _requestFingerprint(controller)) {
                ++otherRequestMutations;
            }
        }
    }

    function _recordProtocolEntryDeficit(bool startedSafe) private {
        if (startedSafe && canonical.entryPriceDeficit() != 0) ++protocolEntryDeficitMismatches;
    }

    function _observe() private {
        _before = Watch({
            lifetimeLoss: pool.lifetimeSocialisedLoss(),
            outstandingPrincipal: pool.outstandingPrincipal(),
            entryPriceDeficit: canonical.entryPriceDeficit(),
            losses: lossesDone,
            lends: lendsDone
        });
    }

    function _settle() private {
        uint256 lifetime = pool.lifetimeSocialisedLoss();
        if (lifetime < _before.lifetimeLoss) ++lifetimeLossFell;
        if (lifetime > _before.lifetimeLoss && lossesDone == _before.losses) ++lifetimeLossRoseWithoutLossAction;
        if (pool.outstandingPrincipal() > _before.outstandingPrincipal && lendsDone == _before.lends) {
            ++principalRoseWithoutLend;
        }
        if (_before.entryPriceDeficit == 0 && canonical.entryPriceDeficit() != 0) {
            ++protocolEntryDeficitMismatches;
        }
    }
}

contract LenderPoolInvariants is Test {
    uint256 private constant VIRTUAL_SHARES = 10 ** 3;
    uint256 private constant MIN_SUPPLY_FOR_PRINCIPAL = (10 ** 3) * Config.BPS;

    MockUSDC internal usdc;
    LenderPool internal pool;
    ICanonicalLenderPool internal canonical;
    CanonicalLenderHandler internal handler;

    address internal owner = makeAddr("canonical-owner");
    address internal creditManager = makeAddr("canonical-credit-manager");
    address internal epochHarvester = makeAddr("canonical-epoch-harvester");

    function setUp() public virtual {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), owner);
        canonical = ICanonicalLenderPool(address(pool));

        vm.startPrank(owner);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(epochHarvester);
        vm.stopPrank();

        handler = new CanonicalLenderHandler(pool, usdc, owner, creditManager, epochHarvester);
        targetContract(address(handler));
    }

    function invariant_rawAndRecognisedCashHaveOnlyOneSignedDifference() public view {
        assertTrue(
            canonical.cashDeficit() == 0 || canonical.unmanagedSurplus() == 0,
            "cash was simultaneously above and below its recognised book"
        );
    }

    function invariant_totalAssetsUsesOnlyEffectiveRecognisedCash() public view {
        uint256 raw = usdc.balanceOf(address(pool));
        uint256 accounted = _accountedCash(raw);
        uint256 effective = raw < accounted ? raw : accounted;
        uint256 unreleased = pool.unreleasedYield();
        uint256 deficit = canonical.cashDeficit();
        uint256 effectiveYield = unreleased > deficit ? unreleased - deficit : 0;
        uint256 gross = effective + pool.outstandingPrincipal();
        uint256 claims = pool.totalClaimable();
        uint256 shareholderGross = gross > claims ? gross - claims : 0;
        if (effectiveYield > shareholderGross) effectiveYield = shareholderGross;
        uint256 expected = shareholderGross - effectiveYield;
        assertEq(pool.totalAssets(), expected, "NAV left the canonical effective-cash identity");
    }

    function invariant_depositCapUsageIsTheStoredEntryBook() public view {
        uint256 gross = _accountedCash(usdc.balanceOf(address(pool))) + pool.outstandingPrincipal();
        uint256 claims = pool.totalClaimable();
        uint256 expected = gross > claims ? gross - claims : 0;
        assertEq(canonical.depositCapUsage(), expected, "deposit-cap usage left the recognised entry book");
    }

    function invariant_claimDeficitsUseCashForLiquidityAndTheWholeBookForSolvency() public view {
        uint256 raw = usdc.balanceOf(address(pool));
        uint256 accounted = _accountedCash(raw);
        uint256 effective = raw < accounted ? raw : accounted;
        uint256 claims = pool.totalClaimable();
        uint256 liquidity = claims > effective ? claims - effective : 0;
        uint256 backing = effective + pool.outstandingPrincipal();
        uint256 solvency = claims > backing ? claims - backing : 0;
        assertEq(canonical.claimLiquidityDeficit(), liquidity, "claim liquidity deficit used the wrong backing");
        assertEq(canonical.claimSolvencyDeficit(), solvency, "claim solvency deficit used the wrong backing");
    }

    function invariant_entryPriceDeficitAndAbsoluteSupplyAreExact() public view {
        uint256 raw = usdc.balanceOf(address(pool));
        uint256 unmanaged = canonical.unmanagedSurplus();
        assertLe(unmanaged, raw, "unmanaged cash exceeded the token balance");
        uint256 effective = raw - unmanaged;

        uint256 supply = pool.totalSupply();
        uint256 required =
            Math.ceilDiv(Math.saturatingAdd(supply, VIRTUAL_SHARES), Config.MAX_LENDER_SHARES_PER_ASSET) - 1;
        assertEq(canonical.minimumEntryAssets(), required, "minimum entry backing left the quotient formula");

        uint256 expectedMaximum =
            Config.MAX_LENDER_SHARES_PER_ASSET * (Config.GLOBAL_BORROW_CAP_MAX + 1) - VIRTUAL_SHARES;
        uint256 maximum = canonical.maximumShareSupply();
        assertEq(maximum, expectedMaximum, "absolute share ceiling left the configured bound");
        assertLe(supply, maximum, "real share supply crossed the absolute ceiling");

        uint256 target = Math.saturatingAdd(pool.totalClaimable(), required);
        uint256 expectedDeficit = target > effective ? target - effective : 0;
        uint256 actualDeficit = canonical.entryPriceDeficit();
        assertEq(actualDeficit, expectedDeficit, "entry price deficit used the wrong cash backing");

        if (actualDeficit == 0) {
            uint256 effectiveYield = pool.unreleasedYield();
            uint256 cashDeficit = canonical.cashDeficit();
            effectiveYield = effectiveYield > cashDeficit ? effectiveYield - cashDeficit : 0;
            uint256 gross = effective + pool.outstandingPrincipal();
            uint256 claims = pool.totalClaimable();
            uint256 shareholderGross = gross > claims ? gross - claims : 0;
            if (effectiveYield > shareholderGross) effectiveYield = shareholderGross;
            uint256 entryAssets = pool.totalAssets() + effectiveYield;
            assertGe(entryAssets, required, "zero deficit did not preserve the bounded entry quotient");
        }
    }

    function invariant_entryMaximaStayInsideTheAbsoluteSupplyCeiling() public view {
        address receiver = handler.actors(0);
        uint256 maxAssets = pool.maxDeposit(receiver);
        uint256 maxShares = pool.maxMint(receiver);
        uint256 supply = pool.totalSupply();
        uint256 maximum = canonical.maximumShareSupply();
        assertLe(supply, maximum, "entry maximum observed an over-ceiling supply");
        uint256 shareRoom = maximum - supply;

        if (
            canonical.cashDeficit() != 0 || canonical.claimLiquidityDeficit() != 0 || canonical.entryPriceDeficit() != 0
        ) {
            assertEq(maxAssets, 0, "an accounting deficit left maxDeposit open");
            assertEq(maxShares, 0, "an accounting deficit left maxMint open");
            return;
        }

        uint256 depositShares = pool.previewDeposit(maxAssets);
        assertLe(depositShares, shareRoom, "maxDeposit crossed the absolute share ceiling");
        assertLe(maxShares, shareRoom, "maxMint crossed the absolute share ceiling");
        uint256 expectedMint = depositShares < shareRoom ? depositShares : shareRoom;
        assertEq(maxShares, expectedMint, "maxMint diverged from maxDeposit at the entry price");
        assertLe(pool.previewMint(maxShares), maxAssets, "maxMint costs more than maxDeposit");
        if (maxAssets != 0) assertGt(depositShares, 0, "maxDeposit quoted a zero-share donation");
    }

    function invariant_deficitsCloseOnlyTheDoorsTheirBackingRequires() public view {
        if (canonical.cashDeficit() != 0 || canonical.claimLiquidityDeficit() != 0) {
            assertEq(pool.maxDeposit(handler.actors(0)), 0, "entry stayed open across a cash deficit");
        }
        if (canonical.claimLiquidityDeficit() == 0) return;

        assertEq(pool.available(), 0, "lending ranked ahead of an underfunded claim");
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertEq(pool.maxRedeem(actor), 0, "an immediate exit ranked ahead of an underfunded claim");
            assertEq(pool.maxRequestRedeem(actor), 0, "request service ranked ahead of an underfunded claim");
        }
    }

    function invariant_principalCannotOutliveTheMinimumRealSupply() public view {
        if (pool.outstandingPrincipal() != 0) {
            assertGe(pool.totalSupply(), MIN_SUPPLY_FOR_PRINCIPAL, "principal outlived the minimum supply");
        }
    }

    function invariant_emptyPoolCannotRetainRecyclableShareholderValue() public view {
        if (pool.totalSupply() != 0 || pool.outstandingPrincipal() != 0) return;

        uint256 accounted = _accountedCash(usdc.balanceOf(address(pool)));
        assertLe(accounted, pool.totalClaimable(), "empty pool retained recognised shareholder cash");
        assertEq(pool.pendingYield(), 0, "empty pool retained pending yield");
        assertEq(pool.yieldRate(), 0, "empty pool retained an active stream");
    }

    function invariant_escrowedSharesEqualTheSumOfLiveRequests() public view {
        uint256 requested;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            (,, uint256 shares,,) = pool.withdrawalRequest(handler.actors(i));
            requested += shares;
        }
        assertEq(pool.queuedShares(), requested, "queued shares diverged from live requests");
        assertEq(pool.balanceOf(address(pool)), requested, "request escrow held the wrong shares");
    }

    function invariant_shareSupplyIsFullyAccountedFor() public view {
        uint256 held = pool.balanceOf(address(pool));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            held += pool.balanceOf(handler.actors(i));
        }
        assertEq(pool.totalSupply(), held, "share supply escaped the fixture");
    }

    function invariant_claimableSumEqualsTheFixedLiability() public view {
        uint256 claims;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            claims += pool.claimable(handler.actors(i));
        }
        assertEq(pool.totalClaimable(), claims, "fixed claim liability diverged from receivers");
        assertEq(pool.claimable(address(pool)), 0, "the pool became its own claim receiver");
    }

    function invariant_requestCashReserveAndAvailableUseReleasedRecognisedCash() public view {
        uint256 raw = usdc.balanceOf(address(pool));
        uint256 accounted = _accountedCash(raw);
        uint256 effective = raw < accounted ? raw : accounted;
        uint256 deficit = canonical.cashDeficit();
        uint256 unreleased = pool.unreleasedYield();
        uint256 effectiveYield = unreleased > deficit ? unreleased - deficit : 0;
        uint256 claims = pool.totalClaimable();
        uint256 shareholderGross = effective + pool.outstandingPrincipal();
        shareholderGross = shareholderGross > claims ? shareholderGross - claims : 0;
        if (effectiveYield > shareholderGross) effectiveYield = shareholderGross;
        uint256 excludedCash = claims + effectiveYield;
        uint256 idle = effective > excludedCash ? effective - excludedCash : 0;

        uint256 cashAfterClaims = effective > claims ? effective - claims : 0;
        uint256 tailCash = effectiveYield < cashAfterClaims ? effectiveYield : cashAfterClaims;
        uint256 required = Math.ceilDiv(pool.totalSupply() + 10 ** 3, Config.MAX_LENDER_SHARES_PER_ASSET) - 1;
        uint256 prospectivePriceReserve = required > tailCash ? required - tailCash : 0;
        uint256 existingPriceReserve = pool.outstandingPrincipal() == 0 ? 0 : prospectivePriceReserve;
        uint256 executable = idle > existingPriceReserve ? idle - existingPriceReserve : 0;

        uint256 expectedReserve = pool.queuedShares() == 0
            ? 0
            : Math.mulDiv(executable, pool.queuedShares(), pool.totalSupply(), Math.Rounding.Ceil);
        assertEq(pool.queueCashReserve(), expectedReserve, "request reserve counted unrecognised cash");

        if (pool.totalSupply() < MIN_SUPPLY_FOR_PRINCIPAL) {
            assertEq(pool.available(), 0, "sub-floor supply advertised lendable cash");
            return;
        }

        uint256 lendingCash = idle > prospectivePriceReserve ? idle - prospectivePriceReserve : 0;
        uint256 prospectiveRequestReserve = pool.queuedShares() == 0
            ? 0
            : Math.mulDiv(lendingCash, pool.queuedShares(), pool.totalSupply(), Math.Rounding.Ceil);
        uint256 postRequestBook = pool.totalAssets() - prospectiveRequestReserve;
        uint256 hotFloat = Math.mulDiv(postRequestBook, Config.RESERVE_RATIO_BPS, Config.BPS);
        uint256 held = prospectiveRequestReserve + hotFloat;
        uint256 expectedAvailable = lendingCash > held ? lendingCash - held : 0;
        assertEq(pool.available(), expectedAvailable, "available left the request and float formula");
    }

    /// @notice A paused pool advertises no room through either ERC-4626 entry door.
    function invariant_aPausedPoolAdvertisesNoRoomToEnter() public view {
        if (!pool.paused()) return;
        assertEq(pool.maxDeposit(handler.actors(0)), 0, "paused pool advertised entry room");
        assertEq(pool.maxMint(handler.actors(0)), 0, "paused pool advertised mint room");
    }

    /// @notice Pausing entry does not change any lender's executable exit maximum.
    function invariant_aPausedPoolStillAdvertisesEveryExit() public view {
        if (!pool.paused()) return;

        uint256 idleShares = pool.convertToShares(pool.unreservedIdle());
        uint256 burnable = type(uint256).max;
        if (pool.outstandingPrincipal() != 0) {
            uint256 supply = pool.totalSupply();
            burnable = supply > MIN_SUPPLY_FOR_PRINCIPAL ? supply - MIN_SUPPLY_FOR_PRINCIPAL : 0;
        }

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            uint256 expected = pool.balanceOf(handler.actors(i));
            if (idleShares < expected) expected = idleShares;
            if (burnable < expected) expected = burnable;
            assertEq(pool.maxRedeem(handler.actors(i)), expected, "pause moved an exit maximum");
            assertEq(pool.maxWithdraw(handler.actors(i)), pool.previewRedeem(expected), "pause moved an asset exit");
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theHandlerNeverDropsAFrame() public view {}

    function invariant_lifetimeAndPrincipalCountersMoveOnlyOnTheirNamedFlows() public view {
        assertEq(handler.lifetimeLossFell(), 0, "lifetime loss fell");
        assertEq(handler.lifetimeLossRoseWithoutLossAction(), 0, "lifetime loss rose without a loss");
        assertEq(handler.principalRoseWithoutLend(), 0, "principal rose without a lend");
    }

    function invariant_protocolControlledFlowsCannotManufactureAnEntryPriceDeficit() public view {
        assertEq(
            handler.protocolEntryDeficitMismatches(), 0, "a protocol-controlled flow created an entry price deficit"
        );
    }

    function invariant_donationsAreInertOutsideTheDocumentedReplacementWindow() public view {
        assertEq(handler.donationViewMismatches(), 0, "a raw donation changed an economic view");
    }

    function invariant_requestMutationAndServiceAccountingStayControllerScoped() public view {
        assertEq(handler.otherRequestMutations(), 0, "one controller rewrote another request");
        assertEq(handler.serviceAccountingMismatches(), 0, "request service stopped conserving its fixed claim");
    }

    function invariant_mockUsdcIsConservedAcrossEveryKnownHolder() public view {
        uint256 held = usdc.balanceOf(address(pool)) + usdc.balanceOf(creditManager) + usdc.balanceOf(epochHarvester)
            + usdc.balanceOf(address(handler)) + usdc.balanceOf(handler.destructionSink());
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            held += usdc.balanceOf(handler.actors(i));
        }
        assertEq(held, handler.totalMinted(), "USDC escaped the modelled system");
        assertEq(usdc.totalSupply(), handler.totalMinted(), "the mint mirror diverged from token supply");
    }

    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        handler.deposit(0, 5_000e6);
        handler.deposit(1, 5_000e6);
        handler.mintShares(2, 1_000e9);
        handler.transferShares(0, 1, 1);
        handler.withdrawMaximum(0, 1);
        handler.redeemMaximum(1, 1);
        handler.donate(1e6);
        handler.lend(1_000e6);
        handler.repay(500e6);
        handler.distributeYield(100e6);
        handler.passTime(1 days);
        handler.recoverLoss(1e6);
        handler.requestWithdrawal(2, 2, type(uint96).max);
        handler.cancelWithdrawalRequest(2);
        handler.requestWithdrawal(0, 2, type(uint96).max);
        handler.serviceWithdrawalRequest(0, type(uint96).max);
        handler.impair(0, 100e6);
        handler.releaseImpairment(0);
        handler.socialiseLoss(500e6);
        uint256 rawCash = usdc.balanceOf(address(pool));
        assertLe(rawCash, type(uint96).max, "fixture cash exceeded the handler seed");
        handler.destroyRawCash(uint96(rawCash));
        handler.reconcileCashDeficit();
        uint256 claimDeficit = canonical.claimSolvencyDeficit();
        assertGt(claimDeficit, 0, "fixture did not make the fixed claim insolvent");
        assertLe(claimDeficit, type(uint96).max, "fixture claim exceeded the handler seed");
        handler.coverClaimDeficit(uint96(claimDeficit));
        handler.claim(2);
        handler.togglePause();
        handler.togglePause();

        assertGt(handler.depositsDone(), 0, "entry was never reached");
        assertGt(handler.mintsDone(), 0, "exact-share entry was never reached");
        assertGt(handler.withdrawalsDone(), 0, "asset exit was never reached");
        assertGt(handler.redeemsDone(), 0, "share exit was never reached");
        assertGt(handler.donationsDone(), 0, "raw donation was never reached");
        assertGt(handler.lendsDone(), 0, "lending was never reached");
        assertGt(handler.repaysDone(), 0, "repayment was never reached");
        assertGt(handler.yieldsDone(), 0, "yield delivery was never reached");
        assertGt(handler.recoveriesDone(), 0, "loss recovery was never reached");
        assertGt(handler.timeAdvances(), 0, "stream time never moved");
        assertGt(handler.requestsDone(), 0, "request creation was never reached");
        assertGt(handler.cancellationsDone(), 0, "request cancellation was never reached");
        assertGt(handler.servicesDone(), 0, "request service was never reached");
        assertGt(handler.coversDone(), 0, "claim-deficit cover was never reached");
        assertGt(handler.claimsDone(), 0, "claim collection was never reached");
        assertGt(handler.transfersDone(), 0, "share transfer was never reached");
        assertGt(handler.impairmentsDone(), 0, "impairment was never reached");
        assertGt(handler.releasesDone(), 0, "impairment release was never reached");
        assertGt(handler.lossesDone(), 0, "loss socialisation was never reached");
        assertGt(handler.destructionsDone(), 0, "external cash destruction was never reached");
        assertGt(handler.reconciliationsDone(), 0, "cash reconciliation was never reached");
        assertGt(handler.pausesDone(), 0, "pause was never reached");
        assertGt(handler.unpausesDone(), 0, "unpause was never reached");
    }

    function test_handlerCanReachTheNumericReserveAndRepairAnExternalPriceDeficit() public {
        handler.deposit(0, 5_000e6);
        for (uint256 i; i < 40 && handler.lendTapersReached() == 0; ++i) {
            handler.stressLossRefill(type(uint8).max, 0);
        }

        emit log_named_uint("loss-refill cycles", handler.lossRefillCyclesDone());
        emit log_named_uint("numeric reserve states", handler.numericReserveStatesReached());
        emit log_named_uint("lend tapers", handler.lendTapersReached());

        assertGt(handler.lossRefillCyclesDone(), 0, "loss-refill stress never completed a cycle");
        assertGt(handler.numericReserveStatesReached(), 0, "loss-refill stress never reached the numeric reserve");
        assertGt(handler.lendTapersReached(), 0, "numeric reserve never tapered lending to zero");
        assertEq(pool.available(), 0, "tapered boundary still advertised lendable cash");
        assertEq(pool.outstandingPrincipal(), 0, "stress boundary retained principal");
        assertEq(canonical.entryPriceDeficit(), 0, "protocol stress created a price deficit");
        assertLe(pool.totalSupply(), canonical.maximumShareSupply(), "stress crossed the absolute share ceiling");

        uint256 required = canonical.minimumEntryAssets();
        uint256 raw = usdc.balanceOf(address(pool));
        assertGt(required, 0, "numeric reserve fixture remained trivial");
        assertGe(raw, required, "stress ended below its own entry backing");
        uint256 externalLoss = raw - required + 1;
        assertLe(externalLoss, type(uint96).max, "external loss exceeded the handler seed");
        handler.destroyRawCash(uint96(externalLoss));

        assertEq(canonical.entryPriceDeficit(), 1, "projected external loss exposed the wrong price deficit");
        assertEq(pool.maxDeposit(handler.actors(0)), 0, "projected price deficit left maxDeposit open");
        assertEq(pool.maxMint(handler.actors(0)), 0, "projected price deficit left maxMint open");
        handler.reconcileCashDeficit();
        assertEq(canonical.entryPriceDeficit(), 1, "reconciliation changed the projected price deficit");

        handler.coverEntryPriceDeficit(1);
        emit log_named_uint("entry covers", handler.entryCoversDone());
        assertGt(handler.entryCoversDone(), 0, "entry-price cover action was never reached");
        assertEq(canonical.entryPriceDeficit(), 0, "exact entry-price cover left a deficit");
        assertGt(pool.maxDeposit(handler.actors(0)), 0, "exact cover did not reopen maxDeposit");
        assertGt(pool.maxMint(handler.actors(0)), 0, "exact cover did not reopen maxMint");
        assertEq(handler.protocolEntryDeficitMismatches(), 0, "protocol stress manufactured a price deficit");
    }

    function _accountedCash(uint256 raw) private view returns (uint256) {
        uint256 deficit = canonical.cashDeficit();
        uint256 surplus = canonical.unmanagedSurplus();
        return raw + deficit - surplus;
    }
}
