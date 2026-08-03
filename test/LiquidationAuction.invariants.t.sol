// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {Config} from "../src/Config.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {LtvMath} from "../src/LtvMath.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Drives the whole liquidation lifecycle in random order against a NAV that
///         moves under it, and checks the properties that must survive any sequence.
///
///         The important one is `invariant_everyLiveAuctionHasAReachableExit`. Individual
///         guards are tested in the unit suite; what cannot be tested there is that
///         their preconditions leave no gap between them. A state in which all three
///         exits revert is permanently stranded collateral, and only a fuzzer looking
///         for it will find it.
contract AuctionHandler is Test {
    CollateralVault public immutable vault;
    CreditManager public immutable credit;
    LiquidationAuction public immutable auction;
    MockNavOracle public immutable oracle;
    MockUSDC public immutable usdc;
    MockBond public immutable bond;
    address public immutable keeper;

    address[] public actors;
    uint256[] public startedAuctions;

    /// @notice Coverage ghosts. Every action here is wrapped in `try`, so a fixture
    ///         that silently never reaches a liquidation would report six green
    ///         invariants having proved nothing at all.
    ///         `test_handlerCanReachEveryStateTheInvariantsCheck` reads these - not
    ///         `afterInvariant`, for the reason given on that test.
    uint256 public bidsFilled;
    uint256 public cancelsDone;
    uint256 public workoutsOpened;
    uint256 public workoutsClosed;
    uint256 public recoveriesPaid;

    constructor(
        CollateralVault vault_,
        CreditManager credit_,
        LiquidationAuction auction_,
        MockNavOracle oracle_,
        MockUSDC usdc_,
        MockBond bond_,
        address keeper_,
        address[] memory actors_
    ) {
        vault = vault_;
        credit = credit_;
        auction = auction_;
        oracle = oracle_;
        usdc = usdc_;
        bond = bond_;
        keeper = keeper_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function startedCount() external view returns (uint256) {
        return startedAuctions.length;
    }

    // ── actions ──────────────────────────────────────────────────────────────

    function borrow(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try credit.borrow(bound(amount, 1, 500e6)) {} catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        vm.startPrank(a);
        usdc.approve(address(credit), type(uint256).max);
        try credit.repay(bound(amount, 1, 500e6)) {} catch {}
        vm.stopPrank();
    }

    /// @dev The whole point of the suite: NAV has to move, or nothing is ever
    ///      liquidatable and every auction action is a no-op that passes.
    function moveNav(uint256 navSeed) external {
        oracle.setNav(bound(navSeed, 1e8, 30e8));
    }

    function liquidate(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(keeper);
        try credit.liquidate(a) {
            startedAuctions.push(auction.auctionOf(a));
        } catch {}
    }

    function passTime(uint256 secondsSeed) external {
        skip(bound(secondsSeed, 1 minutes, 3 days));
    }

    function bid(uint256 idSeed, uint256 actorSeed) external {
        if (startedAuctions.length == 0) return;
        uint256 id = startedAuctions[idSeed % startedAuctions.length];
        address buyer = _actor(actorSeed);
        vm.startPrank(buyer);
        usdc.approve(address(auction), type(uint256).max);
        try auction.bid(id, type(uint256).max) {
            bidsFilled++;
        } catch {}
        vm.stopPrank();
    }

    function cancel(uint256 idSeed) external {
        if (startedAuctions.length == 0) return;
        try auction.cancel(startedAuctions[idSeed % startedAuctions.length]) {
            cancelsDone++;
        } catch {}
    }

    function expire(uint256 idSeed) external {
        if (startedAuctions.length == 0) return;
        try auction.expireToWorkout(startedAuctions[idSeed % startedAuctions.length]) {
            workoutsOpened++;
        } catch {}
    }

    function workoutSettle(uint256 idSeed, uint256 amount) external {
        if (startedAuctions.length == 0) return;
        uint256 id = startedAuctions[idSeed % startedAuctions.length];
        uint256 pay = bound(amount, 1, 2_000e6);
        usdc.mint(address(this), pay);
        usdc.approve(address(auction), pay);
        try auction.workoutSettle(id, pay) {
            recoveriesPaid++;
        } catch {}
    }

    function closeWorkout(uint256 idSeed) external {
        if (startedAuctions.length == 0) return;
        try auction.closeWorkout(startedAuctions[idSeed % startedAuctions.length]) {
            workoutsClosed++;
        } catch {}
    }

    function sweepWorkoutYield() external {
        try auction.sweepWorkoutYieldToInsurance() {} catch {}
    }

    function claimReward() external {
        vm.prank(keeper);
        try auction.claimReward() {} catch {}
    }

    // ── views the invariants need ────────────────────────────────────────────

    /// @dev Restates each exit's precondition from the *spec*, not from the code, and
    ///      asks whether at least one holds. Deriving them independently is the whole
    ///      value: a checker that copied the implementation would agree with it by
    ///      construction and prove nothing.
    ///
    ///      The union has one hole in it, and finding out whether that hole is
    ///      reachable is the job. `liquidatable && bondCount == 0 && the auction is
    ///      still running` satisfies none of the three: `bid` refuses an empty lot,
    ///      `cancel` refuses a position that is still underwater, and expiry has not
    ///      opened yet. It *should* be unreachable, because a borrower cannot withdraw
    ///      collateral while breaching LTV and nothing else empties a position - but
    ///      "should be" is an argument, and this is a test.
    function hasReachableExit(uint256 auctionId) external view returns (bool) {
        (address borrower, uint96 startedAt,, bool settled,,,,) = auction.auctions(auctionId);
        if (borrower == address(0) || settled) return true; // not live: nothing to strand

        // expireToWorkout: needs only that the clock has run out.
        if (block.timestamp >= uint256(startedAt) + Config.AUCTION_DURATION) return true;

        uint256 debt = credit.currentDebtOf(borrower);
        uint256 collateral = vault.collateralValue(borrower);
        bool liquidatable = LtvMath.exceedsLtv(debt, collateral, Config.LIQUIDATION_THRESHOLD_BPS);

        // cancel: needs the position to have healed.
        if (!liquidatable) return true;

        // bid: needs the position still liquidatable AND a lot to actually sell.
        return vault.bondCount(borrower) != 0;
    }

    function sumBondCounts() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.bondCount(actors[i]);
        }
        sum += vault.bondCount(address(auction)); // workout positions are real positions
    }
}

contract LiquidationAuctionInvariants is Test {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant FLOAT = 1_000_000e6;

    AuctionHandler internal handler;
    CollateralVault internal vault;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    DirectCallAdapter internal adapter;
    TreasuryLiquiditySource internal liquidity;
    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal harvester = makeAddr("harvester");

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(address(oracle)), admin);
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, makeAddr("sink")
        );
        credit = new CreditManager(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        auction = new LiquidationAuction(usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), admin);
        liquidity = new TreasuryLiquiditySource(usdc, admin);

        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        vault.setCreditManager(address(credit));
        vault.setLiquidationAuction(address(auction));
        credit.setLiquiditySource(address(liquidity));
        credit.setEpochHarvester(harvester);
        credit.setLiquidationAuction(address(auction));
        auction.setCreditManager(address(credit));
        liquidity.setCreditManager(address(credit));
        vm.stopPrank();

        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(address(adapter), true);

        usdc.mint(address(this), FLOAT);
        usdc.approve(address(liquidity), FLOAT);
        liquidity.fund(FLOAT);

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        for (uint256 i = 0; i < actors.length; i++) {
            bond.mint(actors[i], 1_000);
            usdc.mint(actors[i], 100_000e6);
            vm.startPrank(actors[i]);
            bond.setApprovalForAll(address(vault), true);
            vault.depositBonds(100);
            vm.stopPrank();
        }

        handler = new AuctionHandler(vault, credit, auction, oracle, usdc, bond, keeper, actors);
        targetContract(address(handler));
    }

    /// @notice The auction is immutable and has no sweep, so any USDC it holds beyond
    ///         unclaimed rewards is stranded forever. Round-1 finding #1's exact shape.
    function invariant_auctionHoldsNothingButUnclaimedRewards() public view {
        assertGe(
            usdc.balanceOf(address(auction)),
            auction.totalUnclaimedRewards(),
            "rewards must always be backed"
        );
        assertEq(
            usdc.balanceOf(address(auction)),
            auction.totalUnclaimedRewards(),
            "and nothing else may accumulate"
        );
    }

    /// @notice Nothing is escrowed, ever. If a bond unit ever rests here, some path is
    ///         moving tokens that should only be moving claims.
    function invariant_auctionEscrowsNoBonds() public view {
        assertEq(bond.bondBalance(address(auction)), 0);
    }

    function invariant_atMostOneLiveAuctionPerBorrower() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            uint256 id = auction.auctionOf(handler.actors(i));
            if (id == 0) continue;
            (address borrower,,, bool settled,,,,) = auction.auctions(id);
            assertEq(borrower, handler.actors(i), "the registry and the record must agree");
            assertFalse(settled, "a settled auction must not still be registered as live");
        }
    }

    /// @notice **The property, not the guards.** No sequence may produce a live auction
    ///         that none of bid, cancel or expireToWorkout can close.
    function invariant_everyLiveAuctionHasAReachableExit() public view {
        for (uint256 i = 0; i < handler.startedCount(); i++) {
            assertTrue(handler.hasReachableExit(handler.startedAuctions(i)), "stranded auction");
        }
    }

    /// @notice The vault ledger still equals what is actually staked, with liquidations
    ///         and workouts moving positions around underneath it.
    function invariant_accountingSurvivesLiquidation() public view {
        (uint256 staked,) = farm.userInfo(address(adapter));
        assertEq(staked, handler.sumBondCounts(), "sum(bondCount) == farm stake");
    }

    /// @notice The Phase-2 solvency invariant, now proved over a state space that has
    ///         auctions in it. `writeDownLoss` is the only function that moves money
    ///         between its terms, so it was previously untested by construction.
    function invariant_creditManagerBalanceCoversEveryClaimOnIt() public view {
        assertGe(
            usdc.balanceOf(address(credit)),
            credit.totalClaimable() + credit.undistributedYield() + credit.pendingPrincipal()
                + credit.insuranceFund(),
            "balance must cover every claim on it"
        );
    }

    /// @notice Proves the fixture above is not vacuous.
    /// @dev Every handler action is wrapped in `try`, which it has to be - most random
    ///      call sequences are meaningless and must not fail a run. The cost is that a
    ///      handler which could never reach a liquidation at all would still report
    ///      green invariants, having exercised nothing.
    ///
    ///      This drives the handler deterministically through every state the
    ///      invariants are supposed to be checking, and asserts each counter moved. It
    ///      is a normal test rather than `afterInvariant` on purpose: `afterInvariant`
    ///      fires once per run against counters that reset each run, so it would demand
    ///      that all six behaviours occur in *every* random 500-call sequence, and fail
    ///      on the first unlucky one.
    function test_handlerCanReachEveryStateTheInvariantsCheck() public {
        handler.borrow(0, 500e6); // alice, at a healthy LTV
        handler.borrow(1, 500e6); // bob
        handler.borrow(2, 500e6); // carol

        handler.moveNav(8e8); // everyone is now underwater
        handler.liquidate(0);
        handler.liquidate(1);
        handler.liquidate(2);
        assertEq(handler.startedCount(), 3, "auctions must be openable");

        // One is bought.
        handler.bid(0, 1);
        assertEq(handler.bidsFilled(), 1, "auctions must be fillable");

        // One heals and is cancelled.
        handler.moveNav(30e8);
        handler.cancel(1);
        assertEq(handler.cancelsDone(), 1, "auctions must be cancellable");

        // One runs out of time, is partly recovered, then written off.
        handler.moveNav(8e8);
        handler.passTime(3 days);
        handler.expire(2);
        assertEq(handler.workoutsOpened(), 1, "the workout path must be reachable");

        handler.workoutSettle(2, 100e6);
        assertEq(handler.recoveriesPaid(), 1, "recoveries must be payable");

        // `passTime` is capped at three days a call, so the 14-day recognition window
        // takes a few of them - which is the point of the cap: a fuzzer must be able to
        // reach the forced close without one lucky jump doing all the work.
        for (uint256 i = 0; i < 5; i++) {
            handler.passTime(3 days);
        }
        handler.closeWorkout(2);
        assertEq(handler.workoutsClosed(), 1, "losses must be recognisable");
    }
}
