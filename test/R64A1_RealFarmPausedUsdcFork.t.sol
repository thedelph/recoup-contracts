// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockLiquidationAuction} from "./mocks/MockLiquidationAuction.sol";
import {MockNavOracle} from "./mocks/MockNavOracle.sol";
import {Config} from "../src/Config.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {DirectCallAdapter} from "../src/adapters/DirectCallAdapter.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ICustodyAdapter} from "../src/interfaces/ICustodyAdapter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {RiskParamsFixture} from "./helpers/RiskParamsFixture.sol";

/// @dev The four members of Circle's FiatToken this suite drives on the REAL Base USDC.
interface IR64A1_FiatTokenPause {
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

/// @title Round 64, seat A1: the REAL DexFi farm under a REAL paused Base USDC (mainnet fork).
/// @notice The local graph cannot answer this. `MockFarm` pays pending rewards with `usdc.mint`,
///         and the shared `R64_PausableFiatToken` leaves `mint` OPEN while paused (its stated
///         limit 1), so on the local graph a paused token never bites inside the farm. The real
///         farm is MasterChef-style and settles the whole position's pending USDC on every
///         `deposit` and `withdraw`. This suite pauses the real token (its `pauser` impersonated)
///         and tries the vault's bond doors, which move BONDS and which the ledger records as
///         unable to be bricked by a USDC pause.
/// @dev Run with:
///      RUN_FORK_TESTS=true forge test --match-contract '^R64A1_RealFarmPausedUsdcFork$' -vv -j 1
///      Self-skips without `RUN_FORK_TESTS`, like every fork suite in this tree.
contract R64A1_RealFarmPausedUsdcFork is RiskParamsFixture {
    IDexFiBond internal bond = IDexFiBond(Config.DEXFI_BOND_NFT);
    IDexFiFarm internal farm = IDexFiFarm(Config.DEXFI_FARM);
    IERC20 internal usdc = IERC20(Config.USDC_BASE);
    IR64A1_FiatTokenPause internal circle = IR64A1_FiatTokenPause(Config.USDC_BASE);

    address internal admin = makeAddr("r64a1-admin");
    address internal alice = makeAddr("r64a1-alice");
    address internal treasury = makeAddr("r64a1-treasury");

    CollateralVault internal vault;
    DirectCallAdapter internal adapter;
    RiskParams internal riskParams;
    bool internal run;

    function _riskParams() internal view override returns (IRiskParams) {
        return IRiskParams(address(riskParams));
    }

    function _riskParamsOwner() internal view override returns (address) {
        return address(0);
    }

    function setUp() public {
        run = vm.envOr("RUN_FORK_TESTS", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        vm.etch(alice, "");
        vm.etch(admin, "");

        riskParams = _deployRiskParams(admin);
        vault = new CollateralVault(
            bond, INAVOracle(address(new MockNavOracle(25.15e8))), IRiskParams(address(riskParams)), admin
        );
        adapter = new DirectCallAdapter(bond, farm, usdc, address(vault), admin, treasury);
        vm.startPrank(admin);
        vault.setCustodyAdapter(ICustodyAdapter(address(adapter)));
        MockLiquidationAuction auctionStub = new MockLiquidationAuction();
        auctionStub.setVault(address(vault));
        auctionStub.setRiskParams(address(riskParams));
        auctionStub.setNavOracle(address(vault.navOracle()));
        vault.setLiquidationAuction(address(auctionStub));
        vm.stopPrank();

        vm.prank(Config.DEXFI_FARM);
        bond.safeTransferFrom(Config.DEXFI_FARM, alice, Config.DEXFI_BOND_TOKEN_ID, 10, "");
        vm.prank(alice);
        bond.setApprovalForAll(address(vault), true);

        address[] memory accounts = new address[](1);
        accounts[0] = address(adapter);
        vm.prank(Config.DEXFI_TREASURY_EOA);
        bond.addWhitelist(accounts);
    }

    function _try(string memory name, address who, address target, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        bytes memory ret;
        (ok, ret) = target.call(data);
        if (ok) {
            console2.log(string.concat("MEASURED [door] ", name, " -> ok"));
        } else if (ret.length >= 68 && bytes4(ret) == bytes4(keccak256("Error(string)"))) {
            bytes memory body = new bytes(ret.length - 4);
            for (uint256 i; i < body.length; ++i) {
                body[i] = ret[i + 4];
            }
            console2.log(string.concat("MEASURED [door] ", name, " -> REVERT string: ", abi.decode(body, (string))));
        } else {
            console2.log(string.concat("MEASURED [door] ", name, " -> REVERT selector:"));
            console2.logBytes4(ret.length >= 4 ? bytes4(ret) : bytes4(0));
        }
    }

    function _pauseCircle() internal {
        address pauser = circle.pauser();
        vm.prank(pauser);
        circle.pause();
        assertTrue(circle.paused(), "the real token did not pause");
    }

    function _staked() internal view returns (uint256 staked) {
        (staked,) = farm.userInfo(address(adapter));
    }

    /// @notice The headline: five bonds staked for three days, the real token paused, every bond
    ///         door tried, then the unpause.
    function test_R64A1_fork_bondDoorsUnderARealPausedUsdc() public {
        vm.skip(!run);
        console2.log("MEASURED [fork] block / USDC pauser", block.number, circle.pauser());

        vm.prank(alice);
        vault.depositBonds(5);
        vm.warp(block.timestamp + 3 days);
        uint256 pending = farm.pendingShare(address(adapter));
        console2.log("MEASURED [fork] adapter staked / pendingShare after 3 days (USDC 6dp)", _staked(), pending);
        assertGt(pending, 0, "premise: the adapter has no pending USDC, the farm would not try to pay");

        // Control, in a snapshot: the same exit with the token live.
        uint256 live = vm.snapshotState();
        bool ok = _try(
            "[token live] vault.withdrawBonds(5) [alice, debt-free]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.withdrawBonds, (5))
        );
        assertTrue(ok, "control: the exit is shut with the token live");
        console2.log("MEASURED [fork] control: treasury received (USDC 6dp)", usdc.balanceOf(treasury));
        vm.revertToState(live);

        _pauseCircle();

        bool exitOk = _try(
            "[USDC paused] vault.withdrawBonds(5) [alice, debt-free: a BOND exit]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.withdrawBonds, (5))
        );
        console2.log(
            "MEASURED [fork] alice vault bonds / wallet bonds after the paused exit attempt",
            vault.bondCount(alice),
            bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID)
        );

        bool cureOk = _try(
            "[USDC paused] vault.depositBonds(5) [alice: ADDING collateral, the cure for a falling NAV]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.depositBonds, (5))
        );

        bool claimOk = _try(
            "[USDC paused] vault.harvestYield() [owner: adapter.claimYield, farm.withdraw(0)]",
            admin,
            address(vault),
            abi.encodeCall(CollateralVault.harvestYield, ())
        );
        console2.log(
            "MEASURED [fork] adapter unreportedYield / farmYieldDelivered / adapter USDC",
            adapter.unreportedYield(),
            adapter.farmYieldDelivered(),
            usdc.balanceOf(address(adapter))
        );

        // The break-glass: forfeits rewards, moves EVERY staked bond to one address, owner only.
        uint256 hatch = vm.snapshotState();
        bool hatchOk = _try(
            "[USDC paused] adapter.emergencyUnstake(admin) [owner: forfeits rewards, ALL bonds]",
            admin,
            address(adapter),
            abi.encodeCall(DirectCallAdapter.emergencyUnstake, (admin))
        );
        console2.log(
            "MEASURED [fork] after the hatch: admin bonds / adapter staked / custodyIsSolvent",
            bond.balanceOf(admin, Config.DEXFI_BOND_TOKEN_ID),
            _staked(),
            vault.custodyIsSolvent()
        );
        assertTrue(hatchOk, "the break-glass is shut too: there is NO way to move a bond under the pause");
        assertFalse(vault.custodyIsSolvent(), "the break-glass left custody solvent: re-read what it costs");
        vm.revertToState(hatch);

        console2.log("MEASURED [fork] paused: exit ok / cure ok / claim ok", exitOk, cureOk, claimOk);
        // PINS AN OPEN FINDING AS THE TREE STANDS (round 64 seat A1, F1). Each of these flips the
        // day bond custody stops depending on the farm being able to pay USDC.
        assertFalse(exitOk, "F1 is gone: a debt-free bond exit survived a paused USDC on the real farm");
        assertFalse(cureOk, "F1 is gone: adding collateral survived a paused USDC on the real farm");
        assertFalse(claimOk, "the claim survived a paused USDC on the real farm");

        vm.prank(circle.pauser());
        circle.unpause();
        ok = _try(
            "[unpaused] vault.withdrawBonds(5) [alice]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.withdrawBonds, (5))
        );
        assertTrue(ok, "the exit did not reopen with the token");
        console2.log(
            "MEASURED [fork] after the unpause: alice wallet bonds / treasury USDC / unreportedYield",
            bond.balanceOf(alice, Config.DEXFI_BOND_TOKEN_ID),
            usdc.balanceOf(treasury),
            adapter.unreportedYield()
        );
    }

    /// @notice The edge of the finding: with NOTHING pending (a first stake, then an exit in the
    ///         same block) the farm has no USDC to move. Then one second of accrual.
    function test_R64A1_fork_zeroPendingThenOneSecondUnderARealPausedUsdc() public {
        vm.skip(!run);
        _pauseCircle();
        bool ok = _try(
            "[USDC paused, first stake, nothing pending] vault.depositBonds(5) [alice]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.depositBonds, (5))
        );
        console2.log("MEASURED [fork] adapter staked / pendingShare", _staked(), farm.pendingShare(address(adapter)));
        if (!ok) return;
        uint256 sameBlock = vm.snapshotState();
        bool zeroPendingExit = _try(
            "[USDC paused, same block, nothing pending] vault.withdrawBonds(5) [alice]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.withdrawBonds, (5))
        );
        vm.revertToState(sameBlock);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        console2.log("MEASURED [fork] one second later: pendingShare", farm.pendingShare(address(adapter)));
        assertTrue(zeroPendingExit, "with nothing pending the real farm still met the token");
        bool oneSecondExit = _try(
            "[USDC paused, ONE SECOND of accrual] vault.withdrawBonds(5) [alice]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.withdrawBonds, (5))
        );
        assertFalse(oneSecondExit, "F1 is gone: one second of accrual no longer shuts the exit");
        _try(
            "[USDC paused, ONE SECOND of accrual] vault.depositBonds(5) [alice, adding collateral]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.depositBonds, (5))
        );
    }

    /// @notice INCIDENTAL, outside this seat's pause: the same weld under a BLACKLIST. Round 63's
    ///         seat A1 listed "a blacklisted adapter" as not reached. The farm pays the ADAPTER,
    ///         so an adapter on Circle's blacklist is refused inside `farm.withdraw` the same way,
    ///         for as long as the listing stands.
    function test_R64A1_fork_aBlacklistedAdapterIsTheSameWeld() public {
        vm.skip(!run);
        vm.prank(alice);
        vault.depositBonds(5);
        vm.warp(block.timestamp + 3 days);
        vm.prank(circle.blacklister());
        circle.blacklist(address(adapter));
        bool exitOk = _try(
            "[adapter BLACKLISTED on real USDC] vault.withdrawBonds(5) [alice, debt-free]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.withdrawBonds, (5))
        );
        bool cureOk = _try(
            "[adapter BLACKLISTED on real USDC] vault.depositBonds(5) [alice]",
            alice,
            address(vault),
            abi.encodeCall(CollateralVault.depositBonds, (5))
        );
        console2.log("MEASURED [fork] adapter blacklisted: exit ok / cure ok", exitOk, cureOk);
        assertFalse(exitOk, "the weld is gone under a blacklisted adapter");
        assertFalse(cureOk, "the weld is gone under a blacklisted adapter (deposit side)");
    }

    /// @notice The shared stand-in held to the REAL token: under a real pause, `approve`,
    ///         `transfer` and `transferFrom` each answer the string the model answers, and
    ///         `balanceOf` and `allowance` still read.
    function test_R64A1_fork_theSharedModelMatchesTheRealTokenUnderAPause() public {
        vm.skip(!run);
        address holder = Config.DEXFI_FARM; // holds real USDC for rewards
        uint256 held = usdc.balanceOf(holder);
        console2.log("MEASURED [fork] the real farm holds USDC (6dp)", held);
        assertGt(held, 0, "premise: the holder has no USDC to move");
        vm.prank(holder);
        usdc.approve(alice, 1);
        _pauseCircle();
        bool a = _try(
            "[real USDC paused] usdc.approve(alice, 2)",
            holder,
            address(usdc),
            abi.encodeCall(IERC20.approve, (alice, 2))
        );
        bool t = _try(
            "[real USDC paused] usdc.transfer(alice, 1)",
            holder,
            address(usdc),
            abi.encodeCall(IERC20.transfer, (alice, 1))
        );
        bool f = _try(
            "[real USDC paused] usdc.transferFrom(holder, alice, 1) [alice, allowance 1]",
            alice,
            address(usdc),
            abi.encodeCall(IERC20.transferFrom, (holder, alice, 1))
        );
        assertFalse(a || t || f, "the real token let one of the three through under a pause");
        assertEq(usdc.allowance(holder, alice), 1, "the refused approve moved the allowance");
        assertEq(usdc.balanceOf(holder), held, "a view disagrees under the pause");
    }
}
