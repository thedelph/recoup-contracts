// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {DeployBase, IMockLockdownView} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {R53A02FactsScript} from "./R53A02_DeployPathFacts.t.sol";
import {R53A02LockedProbe, R53A02ShapeScript} from "./R53A02_ScriptReadShapes.t.sol";

/// @notice FIX-ASSERTING. Compiles only at a tree carrying the two round-53 mirror diffs
///         (`TimelockDoesNotAnswer` and the range-checked decodes). It lived in the round's
///         copy-out directory while those diffs were unshipped; round 53's contracts wave shipped
///         both and promoted it here. The pins it flipped are in `R53A02_DeployPathFacts.t.sol` and
///         `R53A02_ScriptReadShapes.t.sol`, rewritten by the same wave to assert the named errors.
contract R53A02MirrorFixesTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant DIRTY_HIGH_BITS = uint256(1) << 200;

    address internal treasury = makeAddr("r53a02.mirror.treasury");
    address internal feeWallet = makeAddr("r53a02.mirror.feeWallet");
    address internal keeper = makeAddr("r53a02.mirror.keeper");
    address internal navConfirmer = makeAddr("r53a02.mirror.navConfirmer");
    address internal guardian = makeAddr("r53a02.mirror.guardian");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

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

    /// @dev Round 56 (round-56 item 144): the salt seam, hermetic, so a `RECOUP_SWITCHOVER_ATTEMPT`
    ///      in this box's `contracts/.env` cannot decide a case here.
    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(BASE_SEPOLIA);
        vm.warp(1_788_000_000);
    }

    function _externals() internal view returns (Externals memory) {
        return Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
    }

    function _params(address owner_) internal view returns (GovParams memory) {
        return GovParams({
            owner: owner_,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: feeWallet,
            guardian: guardian
        });
    }

    function _row(string memory name, address value, bool last) internal pure returns (string memory) {
        return string.concat('"', name, '":"', vm.toString(value), last ? '"' : '",');
    }

    function _record(Deployed memory d, address owner_) internal pure returns (string memory) {
        string memory head = string.concat(
            '{"chainId":', vm.toString(BASE_SEPOLIA), ',"operators":{"owner":"', vm.toString(owner_), '"},'
        );
        string memory first = string.concat(
            '"contracts":{',
            _row("NAVOracle", address(d.oracle), false),
            _row("CollateralVault", address(d.vault), false),
            _row("DirectCallAdapter", address(d.adapter), false),
            _row("CreditManager", address(d.credit), false)
        );
        string memory second = string.concat(
            _row("LenderPool", address(d.pool), false),
            _row("TreasuryLiquiditySource", address(d.liquidity), false),
            _row("EpochHarvester", address(d.harvester), false),
            _row("LiquidationAuction", address(d.auction), true),
            "}}"
        );
        return string.concat(head, first, second);
    }

    function _installEnv(R53A02FactsScript script, Deployed memory d, address owner_) internal {
        script.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        script.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        script.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        script.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        script.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        script.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        script.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        script.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
        script.setEnvAddress("RECOUP_OWNER", owner_);
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setEnvAddress("RECOUP_TIMELOCK", owner_);
        script.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        script.setRecord(_record(d, owner_));
    }

    // ── the timelock dereference ─────────────────────────────────────────────────────────────────

    /// @notice The EOA owner named as the timelock is now `DeployedAddressHasNoCode("RECOUP_TIMELOCK")`.
    function test_R53A02_mirrorFix_anEoaOwnerNamedAsTheTimelockIsNamed() public {
        address eoaOwner = makeAddr("r53a02.mirror.eoa");
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, eoaOwner);
        R53A02FactsScript script = new R53A02FactsScript();
        _installEnv(script, d, eoaOwner);

        vm.expectRevert(
            abi.encodeWithSelector(WirePhase4.DeployedAddressHasNoCode.selector, "RECOUP_TIMELOCK", eoaOwner)
        );
        script.queuePause();
    }

    /// @notice A CODED owner that is not a timelock (a Safe, stood in for by a token contract) is now
    ///         `TimelockDoesNotAnswer(owner)` instead of an empty revert on `getMinDelay()`.
    function test_R53A02_mirrorFix_aCodedNonTimelockOwnerIsNamed() public {
        MockUSDC safeStandIn = new MockUSDC();
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, address(safeStandIn));
        R53A02FactsScript script = new R53A02FactsScript();
        _installEnv(script, d, address(safeStandIn));

        vm.expectRevert(abi.encodeWithSelector(WirePhase4.TimelockDoesNotAnswer.selector, address(safeStandIn)));
        script.queuePause();
    }

    // ── the six readers ──────────────────────────────────────────────────────────────────────────

    function _lockedStack() internal returns (R53A02LockedProbe probe, MockUSDC u, MockBond b, MockFarm f) {
        probe = new R53A02LockedProbe();
        u = new MockUSDC();
        b = new MockBond();
        f = new MockFarm(b, u);
        address lockKeeper = address(0xC0FFEE);
        u.lockTo(address(this), lockKeeper);
        b.lockTo(address(this), lockKeeper);
        f.lockTo(address(this), lockKeeper);
        b.setRewardPool(address(f));
        b.setWhitelisted(address(f), true);
        probe.setRecord(
            string.concat(
                '{"chainId":', vm.toString(BASE_SEPOLIA), ',"deployer":"', vm.toString(address(this)), '",',
                '"operators":{"keeper":"', vm.toString(lockKeeper), '"},',
                '"mocks":{"MockUSDC":"', vm.toString(address(u)), '","MockBond":"', vm.toString(address(b)),
                '","MockFarm":"', vm.toString(address(f)), '"},',
                '"contracts":{"CollateralVault":"', vm.toString(address(f)), '","DirectCallAdapter":"',
                vm.toString(address(f)), '"},"seededPosition":{"bonds":0}}'
            )
        );
    }

    function test_R53A02_mirrorFix_aDirtyAdminWordIsNamedPreLockdownBytecode() public {
        (R53A02LockedProbe probe, MockUSDC u,,) = _lockedStack();
        vm.mockCall(
            address(u),
            abi.encodeWithSelector(IMockLockdownView.admin.selector),
            abi.encode(DIRTY_HIGH_BITS | uint256(uint160(address(this))))
        );

        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.PreLockdownBytecode.selector, "MockUSDC", address(u), "admin()")
        );
        probe.assertLockedOnChain();
    }

    function test_R53A02_mirrorFix_aNonBoolWhitelistAnswerIsNamedPreLockdownBytecode() public {
        (R53A02LockedProbe probe,, MockBond b, MockFarm f) = _lockedStack();
        vm.mockCall(
            address(b), abi.encodeWithSignature("whitelistContains(address)", address(f)), abi.encode(uint256(2))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AssertMockStackLocked.PreLockdownBytecode.selector, "config read", address(b), "bool getter"
            )
        );
        probe.assertLockedOnChain();
    }

    function test_R53A02_mirrorFix_aDirtyOwnerWordIsNamedByIndex() public {
        Deployed memory d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _wirePhase4(d);
        R53A02ShapeScript script = new R53A02ShapeScript();
        script.setEnvAddress("RECOUP_OWNER", address(this));
        script.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        script.setEnvAddress("RECOUP_KEEPER", keeper);
        script.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        script.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        script.setEnvAddress("RECOUP_GUARDIAN", guardian);
        script.setRecord(_record(d, address(this)));
        vm.mockCall(
            address(d.liquidity),
            abi.encodeWithSelector(Ownable.owner.selector),
            abi.encode(DIRTY_HIGH_BITS | uint256(uint160(address(this))))
        );

        // `Deployed` order: oracle 0, riskParams 1, vault 2, adapter 3, credit 4, pool 5, liquidity 6.
        vm.expectRevert(abi.encodeWithSelector(DeployBase.DeployedMemberNotOwnable.selector, 6));
        script.assertOnly();
    }
}
