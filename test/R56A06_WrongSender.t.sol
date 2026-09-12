// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AssertMockStackLocked} from "../script/AssertLocked.s.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Round 56, audit agent A6, target 3 (round-56 item 145, lead 3): a deploy sent from the
///         wrong `--sender` used to read back as `MockAdminWrong` on the first mock, whose stated
///         remedy is a redeploy, rather than as what it is - a whole stack created and locked by one
///         key that is not the record's `deployer`.
/// @dev `fix_` is red at 8ab4d88 (the entrypoint reverts `MockAdminWrong("MockUSDC", wrong,
///      recorded)`) and green once `AssertLocked` names the shape. `control_` is green on both sides.
///      `negative_` pins that a PARTIAL mismatch - one mock re-locked by somebody else - is still
///      `MockAdminWrong`, because that is a tamper or a half-finished re-lock and not a sender.
contract R56A06WrongSenderHarness is AssertMockStackLocked {
    string private _record;

    function setRecord(string memory json) external {
        _record = json;
    }

    function _readRecord() internal view override returns (string memory) {
        return _record;
    }

    /// @dev Hermetic: the environment is never read, so a `.env` on this box cannot decide a case.
    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }
}

contract R56A06_WrongSenderTest is Test {
    R56A06WrongSenderHarness internal probe;

    address internal constant KEEPER = address(0xC0FFEE);
    address internal wrongKey;
    address internal vaultRow;
    address internal adapterRow;

    function setUp() public {
        probe = new R56A06WrongSenderHarness();
        wrongKey = makeAddr("wrongSender");
        vaultRow = address(new CodedRow());
        adapterRow = address(new CodedRow());
    }

    /// @dev The whole of `DeployTestnet._deployTestnetStack`'s mock half, sent from `key`: every
    ///      constructor and every `lockTo` from one address, exactly what a broadcast from a given
    ///      `--sender` produces.
    function _stackFrom(address key) internal returns (MockUSDC usdc, MockBond bond, MockFarm farm) {
        vm.startPrank(key);
        usdc = new MockUSDC();
        usdc.lockTo(key, KEEPER);
        bond = new MockBond();
        bond.lockTo(key, KEEPER);
        farm = new MockFarm(bond, usdc);
        farm.lockTo(key, KEEPER);
        bond.setRewardPool(address(farm));
        bond.setWhitelisted(address(farm), true);
        bond.setWhitelisted(adapterRow, true);
        vm.stopPrank();
    }

    function _json(address deployer, MockUSDC usdc, MockBond bond, MockFarm farm)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"chainId":31337,',
            '"deployer":"',
            vm.toString(deployer),
            '",',
            '"operators":{"keeper":"',
            vm.toString(KEEPER),
            '"},',
            '"mocks":{"MockUSDC":"',
            vm.toString(address(usdc)),
            '","MockBond":"',
            vm.toString(address(bond)),
            '","MockFarm":"',
            vm.toString(address(farm)),
            '"},',
            '"contracts":{"CollateralVault":"',
            vm.toString(vaultRow),
            '","DirectCallAdapter":"',
            vm.toString(adapterRow),
            '"},',
            '"seededPosition":{"bonds":0}}'
        );
    }

    function test_control_aStackDeployedByTheRecordedKeyPasses() public {
        address recorded = makeAddr("recordedDeployer");
        (MockUSDC usdc, MockBond bond, MockFarm farm) = _stackFrom(recorded);
        probe.setRecord(_json(recorded, usdc, bond, farm));
        probe.assertLockedOnChain();
    }

    function test_fix_aWholeStackFromAnotherSenderIsNamedAsTheWrongKey() public {
        address recorded = makeAddr("recordedDeployer");
        (MockUSDC usdc, MockBond bond, MockFarm farm) = _stackFrom(wrongKey);
        probe.setRecord(_json(recorded, usdc, bond, farm));
        // Encoded by SIGNATURE rather than `.selector`, so this file compiles at the baseline, where
        // the error does not exist yet, and the case goes red there on the revert it really gets.
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("StackDeployedByAnotherKey(address,address)")), wrongKey, recorded)
        );
        probe.assertLockedOnChain();
    }

    function test_negative_oneMockReLockedBySomebodyElseIsStillMockAdminWrong() public {
        address recorded = makeAddr("recordedDeployer");
        (, MockBond bond, MockFarm farm) = _stackFrom(recorded);
        // A lone USDC created by the recorded key and locked to a stranger: lockAuthority is the
        // recorded key and admin is not, so this is a re-lock or a tamper, never a sender.
        vm.startPrank(recorded);
        MockUSDC relocked = new MockUSDC();
        relocked.lockTo(wrongKey, KEEPER);
        vm.stopPrank();
        probe.setRecord(_json(recorded, relocked, bond, farm));
        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.MockAdminWrong.selector, "MockUSDC", wrongKey, recorded)
        );
        probe.assertLockedOnChain();
    }

    function test_negative_twoOfThreeFromAnotherSenderIsNotAWholeStack() public {
        address recorded = makeAddr("recordedDeployer");
        (MockUSDC usdcWrong, MockBond bondWrong,) = _stackFrom(wrongKey);
        (,, MockFarm farmRight) = _stackFrom(recorded);
        probe.setRecord(_json(recorded, usdcWrong, bondWrong, farmRight));
        vm.expectRevert(
            abi.encodeWithSelector(AssertMockStackLocked.MockAdminWrong.selector, "MockUSDC", wrongKey, recorded)
        );
        probe.assertLockedOnChain();
    }
}

contract CodedRow {
    uint256 public something;
}
