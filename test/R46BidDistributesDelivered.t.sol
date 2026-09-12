// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {TreasuryLiquiditySource} from "../src/TreasuryLiquiditySource.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @notice A token whose `transferFrom` credits the sink less than it was asked for. The fee is
///         scoped to one (payer, sink) pair so the probe isolates the inbound bid leg and does not
///         also perturb the manager's pull back out of the auction.
/// @dev Same technique as `PartialUSDC` / `OverpayUSDC` in `test/R34AccountingIdentity.t.sol`,
///      which round 34 pointed at `DirectCallAdapter`. This points it at the auction.
contract R46ShortPayUSDC is MockUSDC {
    address public shortPayer;
    address public shortSink;
    uint256 public feeBps;

    function setShortPay(address payer, address sink, uint256 bps) external {
        shortPayer = payer;
        shortSink = sink;
        feeBps = bps;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool ok = super.transferFrom(from, to, value);
        if (ok && feeBps != 0 && from == shortPayer && to == shortSink) {
            _burn(to, (value * feeBps) / 10_000);
        }
        return ok;
    }
}

/// @notice Audit round 46, Low. Falsifier for the fix in
///         `LiquidationAuction._bid`.
///
///         `_bid` already measures the bidder's delivery as a balance delta either side of the
///         `safeTransferFrom` and stores the clamped figure in `recognisedRecoveryOf`. It then
///         handed `_settleFill` the NOMINAL `price`. Both sibling inbound legs in the same file,
///         `workoutSettle` and `workoutSettleAfterClose`, measure `received` and distribute
///         `received`, each citing fee-on-transfer by name - so the fill leg was the odd one out
///         rather than following a rule. Under a token that delivers short, the difference came out
///         of `totalUnclaimedRewards`, the balance the contract's own docstring calls the only USDC
///         it is ever entitled to hold.
///
///         The fix captures `delivered` after the clamp to `price` and before the
///         `GLOBAL_BORROW_CAP_MAX` clamp, and passes it to `_settleFill`.
///
///         Every assertion here describes the FIXED behaviour. NEUTER MEASURED: restore `price` at
///         the `_settleFill` call and two of the four go red -
///         `test_R46_aShortDeliveredBidIsDistributedAtWhatArrived` on the identity, with the
///         auction holding 6.287500 against 15.718750 owed, and `test_R46_aLargerShortfallStillSettles`
///         with `ERC20InsufficientBalance` inside the fill itself, which is the liquidation path
///         bricked. The control and the discriminator stay green either way, which is what makes
///         this a change to one leg rather than to the waterfall.
contract R46BidDistributesDelivered is RiskParamsFixture {
    uint256 internal constant NAV = 25.15e8;
    uint256 internal constant BONDS = 100;
    uint256 internal constant FLOAT = 100_000e6;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal bidder = makeAddr("bidder");
    address internal harvester = makeAddr("harvester");
    address internal yieldSink = makeAddr("yieldSink");

    R46ShortPayUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    MockNavOracle internal oracle;
    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    CreditManager internal credit;
    LiquidationAuction internal auction;
    TreasuryLiquiditySource internal liquidity;
    RiskParams internal riskParams;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return admin;
    }

    function _maxBorrowAtCeiling() internal view returns (uint256) {
        return _maxBorrow(BONDS, NAV);
    }

    /// @dev Liquidatable but still worth more than the debt, so a fill leaves a surplus, a penalty
    ///      is charged and a caller reward actually accrues. Without a live `totalUnclaimedRewards`
    ///      there is no third-party balance for the shortfall to be taken out of and the probe
    ///      would prove nothing.
    function _softNav() internal view returns (uint256) {
        uint256 debt = _maxBorrowAtCeiling();
        return (_navAtThreshold(debt, BONDS) + _navAtDebtParity(debt, BONDS)) / 2;
    }

    function setUp() public {
        usdc = new R46ShortPayUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        oracle = new MockNavOracle(NAV);

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            IDexFiBond(address(bond)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(
            IDexFiBond(address(bond)), IDexFiFarm(address(farm)), usdc, address(vault), admin, yieldSink
        );
        credit = new CreditManager(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
        auction = new LiquidationAuction(
            usdc, ICollateralVault(address(vault)), INAVOracle(address(oracle)), IRiskParams(address(riskParams)), admin
        );
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

        bond.mint(alice, 1_000);
        vm.startPrank(alice);
        bond.setApprovalForAll(address(vault), true);
        vault.depositBonds(BONDS);
        vm.stopPrank();
    }

    function _openAuctionAt(uint256 nav) internal returns (uint256 id) {
        // Read BEFORE the prank. `_maxBorrow` reaches `_riskParams()`, an external staticcall, and
        // a `vm.prank` is spent by the next external call of any kind - so computing it inside the
        // argument list sends `borrow` from this contract, which holds no bonds. Measured: four
        // tests reverting `ExceedsMaxLtv(type(uint256).max, 2500)`.
        uint256 debt = _maxBorrowAtCeiling();
        vm.prank(alice);
        credit.borrow(debt);
        oracle.setNav(nav);
        vm.prank(keeper);
        credit.liquidate(alice);
        return auction.auctionOf(alice);
    }

    function _fundBidder(uint256 amount) internal {
        usdc.mint(bidder, amount);
        vm.prank(bidder);
        usdc.approve(address(auction), type(uint256).max);
    }

    // -- the falsifiers ------------------------------------------------------

    /// @notice CONTROL, and it must not move. With an ordinary token `delivered == price`, so every
    ///         figure the fill produces is what it always was.
    function test_R46_control_anOrdinaryFillLeavesExactlyTheCallerReward() public {
        uint256 id = _openAuctionAt(_softNav());
        uint256 price = auction.currentPrice(id);
        _fundBidder(price * 2);

        vm.prank(bidder);
        auction.bid(id);

        uint256 held = usdc.balanceOf(address(auction));
        uint256 owed = auction.totalUnclaimedRewards();
        emit log_named_uint("CONTROL price", price);
        emit log_named_uint("CONTROL auction USDC held", held);
        emit log_named_uint("CONTROL totalUnclaimedRewards", owed);
        assertEq(held, owed, "control: the auction should hold exactly the unclaimed rewards");
        assertGt(owed, 0, "control: no caller reward accrued, the probe would be vacuous");

        vm.prank(keeper);
        auction.claimReward();
        assertEq(usdc.balanceOf(keeper), owed, "control: the caller was not paid in full");
    }

    /// @notice THE FIX. A bid that delivers 1% short is distributed at what arrived, so the auction
    ///         ends holding exactly `totalUnclaimedRewards` and the liquidation caller is paid in
    ///         full out of it.
    ///
    ///         Sized under the caller reward so the shortfall would have been absorbed rather than
    ///         reverting - the absorbing case is the one that loses somebody money silently.
    function test_R46_aShortDeliveredBidIsDistributedAtWhatArrived() public {
        uint256 id = _openAuctionAt(_softNav());
        uint256 price = auction.currentPrice(id);
        _fundBidder(price * 2);

        usdc.setShortPay(bidder, address(auction), 100); // 1%

        uint256 bidderBefore = usdc.balanceOf(bidder);
        vm.prank(bidder);
        auction.bid(id);
        uint256 spent = bidderBefore - usdc.balanceOf(bidder);

        uint256 held = usdc.balanceOf(address(auction));
        uint256 owed = auction.totalUnclaimedRewards();
        emit log_named_uint("SHORT nominal price", price);
        emit log_named_uint("SHORT bidder USDC spent", spent);
        emit log_named_uint("SHORT delivered to the auction", (price * 9_900) / 10_000);
        emit log_named_uint("SHORT auction USDC held", held);
        emit log_named_uint("SHORT totalUnclaimedRewards", owed);

        assertLt((price * 9_900) / 10_000, price, "fixture: the token did not deliver short");
        assertGt(owed, 0, "no caller reward accrued, the assertion would be vacuous");
        assertEq(held, owed, "the auction must hold exactly what it owes its callers");

        // The harm, not the accounting: the liquidation caller collects.
        vm.prank(keeper);
        auction.claimReward();
        assertEq(usdc.balanceOf(keeper), owed, "the caller was not paid in full");
        assertEq(auction.totalUnclaimedRewards(), 0, "the reward balance did not clear");
    }

    /// @notice The other end of the range. A 5% shortfall used to revert the fill outright, so a
    ///         token that delivered short bricked the liquidation path; it now settles.
    function test_R46_aLargerShortfallStillSettles() public {
        uint256 id = _openAuctionAt(_softNav());
        uint256 price = auction.currentPrice(id);
        _fundBidder(price * 2);

        usdc.setShortPay(bidder, address(auction), 500); // 5%

        vm.prank(bidder);
        auction.bid(id);

        uint256 held = usdc.balanceOf(address(auction));
        uint256 owed = auction.totalUnclaimedRewards();
        emit log_named_uint("LARGE auction USDC held", held);
        emit log_named_uint("LARGE totalUnclaimedRewards", owed);
        assertEq(auction.auctionOf(alice), 0, "the fill did not resolve the auction");
        assertEq(vault.bondCount(alice), 0, "the lot did not move to the winner");
        assertEq(held, owed, "the auction must hold exactly what it owes its callers");

        vm.prank(keeper);
        auction.claimReward();
        assertEq(usdc.balanceOf(keeper), owed, "the caller was not paid in full");
    }

    /// @notice THE DISCRIMINATOR, unchanged by the fix and the reason it is the right shape.
    ///         `workoutSettle` already measured and distributed what it measured, so the same token
    ///         and the same contract produce the same identity there. The fill leg now agrees with
    ///         its own siblings.
    function test_R46_discriminator_workoutSettleStillDistributesWhatItMeasured() public {
        uint256 id = _openAuctionAt(_softNav());

        skip(Config.AUCTION_DURATION + 1);
        auction.expireToWorkout(id);

        address relayer = makeAddr("relayer");
        // Above the debt on purpose: `_distribute` charges a penalty only out of
        // `surplus = proceeds - repaid`, so a tranche under the debt accrues NO caller reward and
        // the assertion below would be `0 == 0`, green and about nothing.
        uint256 tranche = 800e6;
        usdc.mint(relayer, tranche);
        vm.prank(relayer);
        usdc.approve(address(auction), type(uint256).max);

        usdc.setShortPay(relayer, address(auction), 100);

        vm.prank(relayer);
        auction.workoutSettle(id, tranche);

        uint256 held = usdc.balanceOf(address(auction));
        uint256 owed = auction.totalUnclaimedRewards();
        emit log_named_uint("DISCRIMINATOR auction USDC held", held);
        emit log_named_uint("DISCRIMINATOR totalUnclaimedRewards", owed);
        assertGt(owed, 0, "discriminator: no caller reward accrued, the assertion would be vacuous");
        assertEq(held, owed, "workoutSettle must never spend the callers' reward balance");
    }
}
