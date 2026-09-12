// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {IEpochHarvester} from "../src/interfaces/IEpochHarvester.sol";
import {EpochHarvester} from "../src/EpochHarvester.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title R55A02 - what a wrong `DirectCallAdapter.harvester` pointer costs NOW
/// @notice Round-55 item 246(f). The probe on `setHarvester` was refused in round 52 at +53/+172/
///         +183/+236 bytes against a ~40 ceiling; this file does NOT rebuild it. It answers the
///         question the item leaves, on BOTH sides of round-55 item 219's adapter-side fix.
///
/// @dev MEASURED at 9a01996 (the pre-fix regime, recorded in the `measure_` docstrings): the pointer
///      gated exactly one thing, `claimYield`'s `onlyClaimer`, and `harvest` wraps that call in
///      `try`; every other farm-touching path - the vault's own `harvestYield`, a deposit, a
///      withdrawal, a mint - still swept to the recipient AND moved the corroboration counter, so
///      the very next `harvest` ran the epoch with the pointer still wrong. Cost: one delayed pull.
///
///      UNDER item 219's fix the harvester corroborates on `farmYieldDeliveredToHarvester`, which
///      counts only USDC forwarded to the WIRED harvester (`farmYieldDelivered` is unchanged), so the
///      same wrong pointer now leaves the counter still: the USDC still reaches the harvester, and
///      every `harvest` declines it as uncorroborated - loudly, on every call - until one owner
///      `setHarvester` repairs the pointer and one more dollar of farm delivery corroborates it.
///      No money is lost or taken; the wrong holder gains a call that forwards to the recipient.
///      That is a real cost increase for a wiring error, and it is stated here as the price of
///      closing item 219's handover residual rather than hidden. The `cost_` cases are green under
///      the fix and RED at 9a01996 (where the epoch ran); the `negative_` case is green on both.
contract R55A02_WrongHarvesterPointerCostNow is Test, DeployBase {
    bytes4 internal constant TO_HARVESTER = bytes4(keccak256("farmYieldDeliveredToHarvester()"));
    uint256 internal constant YIELD = 1_000e6;

    address internal treasury = makeAddr("r55a02.treasury");
    address internal feeWallet = makeAddr("r55a02.feeWallet");
    address internal keeper = makeAddr("r55a02.keeper");
    address internal navConfirmer = makeAddr("r55a02.navConfirmer");
    address internal stranger = makeAddr("r55a02.stranger");
    address internal donor = makeAddr("r55a02.donor");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;
    Deployed internal d;

    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue)
        internal
        pure
        override
        returns (string memory)
    {
        return fallbackValue;
    }

    function _toHarvester() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(d.adapter).staticcall(abi.encodeWithSelector(TO_HARVESTER));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256));
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(ANVIL_CHAIN_ID);
        d = _deployProtocol(
            Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))}),
            GovParams({
                owner: address(this),
                yieldRecipient: treasury,
                keeper: keeper,
                navConfirmer: navConfirmer,
                protocolFeeWallet: feeWallet,
                guardian: address(0)
            }),
            address(this)
        );
        assertEq(d.adapter.yieldRecipient(), address(d.harvester), "premise: the wire hands the recipient to the harvester");
    }

    /// @notice Under the fix: a wrong pointer stops the harvester pulling the farm AND stops any other
    ///         farm-touching path corroborating for it. The owner's `CollateralVault.harvestYield`
    ///         (the vault is the other permitted claimer) still delivers the USDC to the harvester,
    ///         the counter stays at zero, and `harvest` declines loudly until the pointer is repaired.
    ///         At 9a01996 the same sequence read `farmYieldDelivered == YIELD` and ran epoch 1.
    function test_R55A02_246f_cost_aWrongPointerStallsEpochsLoudlyUntilRepaired() public {
        d.adapter.setHarvester(address(usdc));
        farm.setPendingYield(address(d.adapter), YIELD);

        vm.expectEmit(true, false, false, true, address(d.harvester));
        emit IEpochHarvester.ZeroYieldEpoch(1);
        d.harvester.harvest();
        assertEq(d.harvester.epochCount(), 0, "the harvester alone cannot reach the farm");

        uint256 swept = d.vault.harvestYield();
        assertEq(swept, YIELD, "the vault is the other permitted claimer");
        assertEq(usdc.balanceOf(address(d.harvester)), YIELD, "the yield still reaches the harvester");
        assertEq(d.adapter.farmYieldDelivered(), YIELD, "the round-11 counter counts it");
        assertEq(_toHarvester(), 0, "but forwarded under a wrong pointer it corroborates nothing");

        vm.expectEmit(true, false, false, true, address(d.harvester));
        emit EpochHarvester.EpochDeclinedUncorroborated(1, 0, YIELD);
        d.harvester.harvest();
        assertEq(d.harvester.epochCount(), 0, "declined, loudly, with the money already here");

        // Repair: one owner call, then one more dollar of farm delivery corroborates the whole pot.
        d.adapter.setHarvester(address(d.harvester));
        farm.setPendingYield(address(d.adapter), 1e6);
        d.harvester.harvest();
        assertEq(d.harvester.epochCount(), 1, "the stranded epoch runs once the pointer is right");
        assertEq(_toHarvester(), 1e6, "counted from the repair onwards");
    }

    /// @notice The wrong holder's only new power is `claimYield`, which forwards to the recipient
    ///         and, under the fix, does not corroborate either: the stranger can neither take the
    ///         yield nor buy an epoch with it.
    function test_R55A02_246f_cost_theWrongHolderCanNeitherTakeNorCorroborate() public {
        d.adapter.setHarvester(stranger);
        farm.setPendingYield(address(d.adapter), YIELD);

        vm.prank(stranger);
        uint256 got = d.adapter.claimYield();
        assertEq(got, YIELD);
        assertEq(usdc.balanceOf(stranger), 0, "the caller receives nothing");
        assertEq(usdc.balanceOf(address(d.harvester)), YIELD, "the recipient does");
        assertEq(_toHarvester(), 0, "and the pointer holder corroborates nothing");

        d.harvester.harvest();
        assertEq(d.harvester.epochCount(), 0, "declined until the pointer is repaired");
    }

    /// @notice Round 11's guard holds under a wrong pointer on both trees: with the farm unclaimed
    ///         and a donation sitting on the harvester, the epoch is declined rather than run.
    function test_R55A02_246f_negative_aDonationStillCannotBuyAnEpochUnderAWrongPointer() public {
        d.adapter.setHarvester(address(usdc));
        farm.setPendingYield(address(d.adapter), YIELD);
        usdc.mint(donor, 10e6);
        vm.prank(donor);
        usdc.transfer(address(d.harvester), 10e6);

        vm.expectEmit(true, false, false, true, address(d.harvester));
        emit EpochHarvester.EpochDeclinedUncorroborated(1, 0, 10e6);
        d.harvester.harvest();
        assertEq(d.harvester.epochCount(), 0, "declined");
    }
}
