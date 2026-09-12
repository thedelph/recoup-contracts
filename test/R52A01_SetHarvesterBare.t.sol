// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {IEpochHarvester} from "../src/interfaces/IEpochHarvester.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round-52 item 144. `DirectCallAdapter.setHarvester` has only a zero check: it accepts an
///         EOA and it accepts any coded address, and the pointer it writes is the ONLY thing that
///         lets `EpochHarvester.harvest()` claim the farm.
///
/// @dev 🟥 **The two `pin_` tests below PIN AN OPEN STATE and say so: a probe on `setHarvester`
///      must turn them red, and a green run of them is not a clearance.** The `cost_` test follows
///      the money one hop: a wrong pointer makes every `harvest()` emit `ZeroYieldEpoch` while the
///      farm still holds the yield, until one owner `setHarvester` repairs it. No money is lost or
///      taken - the wrong address gains only the right to call `claimYield()`, which forwards to
///      `yieldRecipient` rather than to the caller - so the severity is LOW and the byte budget is
///      the decision.
///
///      **REFUSED BY EXECUTION in round 52, and the byte number is what refused it.** The fix was
///      authorised only at or under 40 runtime bytes. The probe was BUILT in four forms and each
///      MEASURED on a clean `out/` against `DirectCallAdapter`'s 16,179 runtime at `99bb4cf`:
///      a `code.length == 0` check alone with a named error is **+53**; an identity probe
///      (`IHarvesterBinding(h).custodyAdapter() != address(this)`) alone is **+172** with a
///      parameterless error and **+183** with `HarvesterNotBound(address)`; the code check plus the
///      identity probe, the shape the item was filed in, is **+236**. Every form is over the ceiling,
///      the cheapest by a factor of more than four, so `DirectCallAdapter.sol` is unchanged and this
///      file pins the open state instead. `CreditManager` and `LiquidationAuction` were byte-identical
///      under all four variants. The `premise_` test records that the live wiring order would have admitted an identity
///      probe (`harvester.setCustodyAdapter` runs before `adapter.setHarvester` in `_wire`), which
///      is the one fact a future build of it needs and which one shipped test contradicts by calling
///      the two in the other order.
contract R52A01SetHarvesterBareTest is Test, DeployBase {
    uint256 internal constant YIELD = 1_000e6;

    address internal treasury = makeAddr("r52a01.h.treasury");
    address internal feeWallet = makeAddr("r52a01.h.feeWallet");
    address internal keeper = makeAddr("r52a01.h.keeper");
    address internal navConfirmer = makeAddr("r52a01.h.navConfirmer");
    address internal stranger = makeAddr("r52a01.h.stranger");

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
    }

    /// @notice PINS AN OPEN STATE. The setter accepts an address with no code.
    function test_R52A01_144_pin_theBareSetterAcceptsAnEoa() public {
        assertEq(stranger.code.length, 0, "premise: no code");
        d.adapter.setHarvester(stranger);
        assertEq(d.adapter.harvester(), stranger, "an EOA was installed as the harvester");
    }

    /// @notice PINS AN OPEN STATE. The setter accepts a coded address that is not a harvester.
    function test_R52A01_144_pin_theBareSetterAcceptsAWrongButCodedAddress() public {
        assertGt(address(usdc).code.length, 0, "premise: coded");
        d.adapter.setHarvester(address(usdc));
        assertEq(d.adapter.harvester(), address(usdc), "the settlement token was installed as the harvester");
    }

    /// @notice The cost, followed one hop: with the pointer wrong, `harvest()` swallows `NotClaimer`,
    ///         sees nothing claimed and emits `ZeroYieldEpoch` while the farm still holds the yield;
    ///         one owner `setHarvester` back to the real harvester and the same epoch harvests.
    function test_R52A01_144_cost_aWrongHarvesterStallsTheStreamUntilRepaired() public {
        d.adapter.setHarvester(address(usdc));
        farm.setPendingYield(address(d.adapter), YIELD);

        vm.expectEmit(true, false, false, true, address(d.harvester));
        emit IEpochHarvester.ZeroYieldEpoch(1);
        d.harvester.harvest();
        assertEq(d.harvester.epochCount(), 0, "no epoch was recorded");
        assertEq(d.adapter.farmYieldDelivered(), 0, "nothing left the farm");

        // Repair is one owner transaction, and the same epoch then lands.
        d.adapter.setHarvester(address(d.harvester));
        d.harvester.harvest();
        assertEq(d.harvester.epochCount(), 1, "the epoch harvested once the pointer was right");
        assertEq(d.adapter.farmYieldDelivered(), YIELD, "the farm paid the adapter");
    }

    /// @notice The premise a future identity probe rests on: on a fresh deployment the harvester's
    ///         back-pointer already names this adapter when `setHarvester` runs, because `_wire`
    ///         calls `harvester.setCustodyAdapter` first. MEASURED live too: the Base Sepolia
    ///         harvester answers `custodyAdapter()` with the record's adapter and the adapter answers
    ///         `harvester()` with the record's harvester.
    function test_R52A01_144_premise_theWiringOrderWouldAdmitAnIdentityProbe() public view {
        assertEq(address(d.harvester.custodyAdapter()), address(d.adapter), "harvester -> adapter");
        assertEq(d.adapter.harvester(), address(d.harvester), "adapter -> harvester");
    }
}
