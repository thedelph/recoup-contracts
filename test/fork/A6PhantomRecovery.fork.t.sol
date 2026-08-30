// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../../src/Config.sol";
import {DirectCallAdapter} from "../../src/adapters/DirectCallAdapter.sol";
import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";

struct UserDebtInput {
    address user;
    uint256 debt;
}

interface IFarmLive {
    function owner() external view returns (address);
    function pendingShare(address) external view returns (uint256);
    function userInfo(address) external view returns (uint256, uint256);
    function userDebt(address) external view returns (uint256);
    function setUsersDebt(UserDebtInput[] memory) external;
}

interface IBondLive {
    function owner() external view returns (address);
    function nonces(address) external view returns (uint256);
    function balanceOf(address, uint256) external view returns (uint256);
    function addWhitelist(address[] memory) external;
}

/// @notice A6 / round 34, follow-up. Traces a PHANTOM recovery to the end against the LIVE Base
///         mainnet farm and bond: a counterfactual attempt receiver that holds nothing of value
///         but still satisfies `DirectCallAdapter._prepareRecovery`'s `NothingToRecover` guard.
///         Answers whether the outcome is merely a wasted governance transaction or worse.
///         Run with: RUN_FORK_TESTS=true BASE_RPC_URL=<rpc> forge test --mc A6PhantomRecovery -vv
contract A6PhantomRecoveryForkTest is Test {
    IFarmLive internal farmLive = IFarmLive(Config.DEXFI_FARM);
    IBondLive internal bondLive = IBondLive(Config.DEXFI_BOND_NFT);
    IERC20 internal usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    DirectCallAdapter internal adapter;
    address internal governance = makeAddr("governance");
    address internal vaultAddr = makeAddr("vault");
    address internal yieldSink = makeAddr("yieldSink");
    address internal victim = makeAddr("victim");
    address internal recipient = makeAddr("recoveryRecipient");
    address internal donor = makeAddr("keyless-donor");

    bytes32 internal constant ATTEMPT = keccak256("victim attempt");

    bool internal run;

    function setUp() public {
        run = vm.envOr("RUN_FORK_TESTS", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));

        adapter = new DirectCallAdapter(
            IDexFiBond(Config.DEXFI_BOND_NFT),
            IDexFiFarm(Config.DEXFI_FARM),
            usdc,
            vaultAddr,
            governance,
            yieldSink
        );
        // DexFi ask #5: one addWhitelist from their owner. recoverMintAttempt requires it.
        address[] memory w = new address[](1);
        w[0] = address(adapter);
        vm.prank(bondLive.owner());
        bondLive.addWhitelist(w);
    }

    /// @dev The shared trace, asserted step by step.
    function _traceRecovery(address receiver) internal {
        assertEq(receiver.code.length, 0, "counterfactual before");
        assertEq(bondLive.nonces(receiver), 0, "attempt still LIVE - nonce untouched");
        (uint256 staked,) = farmLive.userInfo(receiver);
        assertEq(staked, 0, "no farm stake");
        assertEq(bondLive.balanceOf(receiver, Config.DEXFI_BOND_TOKEN_ID), 0, "no bonds");

        uint256 deliveredBefore = adapter.farmYieldDelivered();
        uint256 adapterUsdcBefore = usdc.balanceOf(address(adapter));

        vm.prank(governance);
        (
            uint256 bonds,
            uint256 swept,
            uint256 rawUsdcForwarded,
            uint256 rawUsdcRemaining,
            uint256 nativeForwarded,
            uint256 nativeRemaining
        ) = adapter.recoverMintAttempt(victim, ATTEMPT, payable(recipient));

        // 1. It does NOT revert: the guard was satisfied by the bait.
        // 2. The clone deploys.
        assertGt(receiver.code.length, 0, "clone WAS deployed by the phantom recovery");
        // 3. Nothing of value moves.
        assertEq(bonds, 0, "no bonds recovered");
        assertEq(swept, 0, "nothing swept");
        assertEq(rawUsdcRemaining, 0, "no usdc left stranded");
        assertEq(nativeRemaining, 0, "no native left stranded");
        // 4. The corroboration watermark does not move.
        assertEq(adapter.farmYieldDelivered(), deliveredBefore, "farmYieldDelivered moves by ZERO");
        assertEq(usdc.balanceOf(address(adapter)), adapterUsdcBefore, "adapter gains nothing");
        emit log_named_uint("rawUsdcForwarded to recipient", rawUsdcForwarded);
        emit log_named_uint("nativeForwarded to recipient", nativeForwarded);

        // 5. THE COST, and the only one: the victim's still-unspent attempt is permanently dead.
        //    Validation fires before any DexFi call, so a garbage payload reaches the same guard.
        assertEq(bondLive.nonces(receiver), 0, "nonce STILL zero - nothing was ever minted");
        vm.deal(vaultAddr, 10 ether);
        vm.prank(vaultAddr);
        vm.expectRevert(
            abi.encodeWithSelector(DirectCallAdapter.MintAttemptAlreadyDeployed.selector, receiver)
        );
        adapter.mintBonds{value: 1 ether}(victim, ATTEMPT, abi.encode(_payload(receiver)));
    }

    function _payload(address receiver) internal view returns (IDexFiBond.MintDataInput memory) {
        return IDexFiBond.MintDataInput({
            uuid: uint256(ATTEMPT),
            nonce: 0,
            receiver: receiver,
            amountNfts: 40,
            paymentAmount: 1 ether,
            deadline: block.timestamp + 3 minutes,
            signature: ""
        });
    }

    /// @notice VARIANT A - the owner-key bait. DexFi's owner plants `userDebt`, which
    ///         `pendingShare` adds in and `withdraw` never pays out. Needs DexFi's key.
    function test_A6_phantomRecovery_viaPlantedUserDebt() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        address receiver = adapter.predictMintReceiver(victim, ATTEMPT);

        UserDebtInput[] memory d = new UserDebtInput[](1);
        d[0] = UserDebtInput({user: receiver, debt: 100e6});
        vm.prank(farmLive.owner());
        farmLive.setUsersDebt(d);
        assertEq(farmLive.pendingShare(receiver), 100e6, "NothingToRecover guard now defeated");

        _traceRecovery(receiver);

        assertEq(farmLive.userDebt(receiver), 100e6, "phantom debt survives, still uncollectable");
    }

    /// @notice VARIANT B - the KEYLESS bait, and it is strictly cheaper. One wei of native to the
    ///         counterfactual address defeats the same guard, with no DexFi key and no Recoup
    ///         permission at all. The userDebt route is the expensive version of a free trick.
    function test_A6_phantomRecovery_viaOneWeiOfNative() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        address receiver = adapter.predictMintReceiver(victim, ATTEMPT);

        vm.deal(donor, 1 ether);
        vm.prank(donor);
        (bool ok,) = receiver.call{value: 1 wei}("");
        assertTrue(ok, "a plain value send to a codeless address always succeeds");
        assertEq(receiver.balance, 1, "guard defeated for one wei, by anybody");
        assertEq(farmLive.pendingShare(receiver), 0, "no farm involvement at all");

        _traceRecovery(receiver);
    }

    /// @notice VARIANT C - the same, with one wei of USDC.
    function test_A6_phantomRecovery_viaOneWeiOfUsdc() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        address receiver = adapter.predictMintReceiver(victim, ATTEMPT);

        deal(address(usdc), donor, 1);
        vm.prank(donor);
        usdc.transfer(receiver, 1);
        assertEq(usdc.balanceOf(receiver), 1, "guard defeated for one USDC wei");

        _traceRecovery(receiver);
    }

    /// @notice CONTROL. With no bait at all the guard fires, governance cannot deploy the clone,
    ///         and the attempt survives. Without this the three tests above would pass even if
    ///         `recoverMintAttempt` deployed a clone unconditionally.
    function test_A6_control_withoutBaitTheGuardHolds() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        address receiver = adapter.predictMintReceiver(victim, ATTEMPT);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(DirectCallAdapter.NothingToRecover.selector, receiver));
        adapter.recoverMintAttempt(victim, ATTEMPT, payable(recipient));
        assertEq(receiver.code.length, 0, "no clone, attempt still usable");
    }
}
