// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {WirePhase4} from "../script/WirePhase4.s.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice `WirePhase4` with its record seam COUNTED and optionally REWRITTEN mid-run: from read
///         number `plantFrom` onward (counted across the harness's whole life), `_readRecord`
///         returns `planted` instead of `record` - the shape a deployment record edited on disk
///         while one entry point is between two of its reads would have.
/// @dev The counter is a storage write reached from a `view` override through an internal
///      function pointer cast in assembly. It is therefore only live when the entry point is
///      entered with a CALL: the `view` entry point `assertOnly()` is reached with a low-level
///      `call` here, never through the typed interface (which would STATICCALL and revert on the
///      write). Hermetic on all three environment seams.
contract R57A06CountingScript is WirePhase4 {
    mapping(bytes32 => address) private _addr;
    mapping(bytes32 => bool) private _addrSet;
    mapping(bytes32 => string) private _str;
    mapping(bytes32 => bool) private _strSet;
    string private _record;
    string private _planted;
    uint256 private _plantFrom;
    uint256 public reads;

    function setEnvAddress(string memory key, address value) external {
        bytes32 k = keccak256(bytes(key));
        _addr[k] = value;
        _addrSet[k] = true;
    }

    function setEnvString(string memory key, string memory value) external {
        bytes32 k = keccak256(bytes(key));
        _str[k] = value;
        _strSet[k] = true;
    }

    function setRecord(string memory json) external {
        _record = json;
    }

    /// @dev `from == 0` switches the plant off.
    function plant(uint256 from, string memory json) external {
        _plantFrom = from;
        _planted = json;
    }

    function _envOrAddress(string memory key, address fallbackValue) internal view override returns (address) {
        bytes32 k = keccak256(bytes(key));
        return _addrSet[k] ? _addr[k] : fallbackValue;
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        override
        returns (string memory)
    {
        bytes32 k = keccak256(bytes(key));
        return _strSet[k] ? _str[k] : fallbackValue;
    }

    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function _bump() internal returns (uint256) {
        reads += 1;
        return reads;
    }

    function _asView(function() internal returns (uint256) f)
        internal
        pure
        returns (function() internal view returns (uint256) g)
    {
        assembly {
            g := f
        }
    }

    function _readRecord() internal view override returns (string memory) {
        uint256 n = _asView(_bump)();
        return (_plantFrom != 0 && n >= _plantFrom) ? _planted : _record;
    }
}

/// @notice Round-57 item 236(b) (round-56 item 163's third lead), EXECUTED. `_deploymentRecord()`
///         is called once per record-reading helper, and an entry point calls two or three of them,
///         each with its own `vm.readFile` and its own `RecordChainMismatch` check. Can those reads
///         disagree, and would it matter?
///
/// @dev MEASURED here: the count per entry point (`queuePause` 2, `executeQueuedPause` 2, `queue` 3,
///      `executeQueued` 3, `assertOnly` 2, `run` 2), that EVERY read re-checks `chainId` (a
///      wrong-chain record planted at any single read of `queue()` is refused by name at that read),
///      and that the reads are DISJOINT in what else they consume: `_resolveDeployed` takes only
///      `contracts.*`, `_requiredTimelock` only `operators.timelock`, and the params helpers only
///      `operators.*`. So a record rewritten mid-run cannot make one field disagree with itself;
///      it can only produce the same mixed record an operator could have committed before the run,
///      and every mixed case below is refused by name or is indistinguishable from the unplanted
///      run. Nothing to fix; the count is pinned so a refactor that reads once per entry point
///      (strictly simpler) is a deliberate edit to this file.
contract R57A06RecordReadsPerEntryPointTest is Test, DeployBase {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant BASE_MAINNET = 8453;

    address internal treasury = makeAddr("r57a06.reads.treasury");
    address internal feeWallet = makeAddr("r57a06.reads.feeWallet");
    address internal keeper = makeAddr("r57a06.reads.keeper");
    address internal navConfirmer = makeAddr("r57a06.reads.navConfirmer");
    address internal guardian = makeAddr("r57a06.reads.guardian");
    address internal stranger = makeAddr("r57a06.reads.stranger");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    function _envOrAddress(string memory, address fallbackValue) internal pure override returns (address) {
        return fallbackValue;
    }

    function _envOrString(string memory, string memory fallbackValue) internal pure override returns (string memory) {
        return fallbackValue;
    }

    function _envOrBytes32(string memory, bytes32 fallbackValue) internal pure override returns (bytes32) {
        return fallbackValue;
    }

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        farm = new MockFarm(bond, usdc);
        bond.setRewardPool(address(farm));
        vm.chainId(BASE_SEPOLIA);
        // Forge's default timestamp is OZ's DONE sentinel; see R53A02_DeployPathFacts.setUp.
        vm.warp(1_788_000_000);
    }

    function _externals() internal view returns (Externals memory) {
        return
            Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
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

    function _recordFor(Deployed memory d, uint256 chainId, address recordOwner) internal pure returns (string memory) {
        string memory head = string.concat(
            '{"chainId":', vm.toString(chainId), ',"operators":{"owner":"', vm.toString(recordOwner), '"},'
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

    function _timelock() internal returns (TimelockController t) {
        address[] memory proposers = new address[](2);
        proposers[0] = DEFAULT_SENDER;
        proposers[1] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        t = new TimelockController(0, proposers, executors, address(0));
    }

    function _generation(address newOwner) internal returns (Deployed memory d) {
        d = _deployProtocol(_externals(), _params(address(this)), address(this));
        _handOver(d, newOwner);
    }

    /// @dev A script whose environment names `d` and `newOwner` and whose record names the same.
    function _script(Deployed memory d, address newOwner) internal returns (R57A06CountingScript s) {
        s = new R57A06CountingScript();
        s.setEnvAddress("RECOUP_NAV_ORACLE", address(d.oracle));
        s.setEnvAddress("RECOUP_COLLATERAL_VAULT", address(d.vault));
        s.setEnvAddress("RECOUP_CUSTODY_ADAPTER", address(d.adapter));
        s.setEnvAddress("RECOUP_CREDIT_MANAGER", address(d.credit));
        s.setEnvAddress("RECOUP_LENDER_POOL", address(d.pool));
        s.setEnvAddress("RECOUP_LIQUIDITY_SOURCE", address(d.liquidity));
        s.setEnvAddress("RECOUP_EPOCH_HARVESTER", address(d.harvester));
        s.setEnvAddress("RECOUP_LIQUIDATION_AUCTION", address(d.auction));
        s.setEnvAddress("RECOUP_OWNER", newOwner);
        s.setEnvAddress("RECOUP_YIELD_RECIPIENT", treasury);
        s.setEnvAddress("RECOUP_KEEPER", keeper);
        s.setEnvAddress("RECOUP_NAV_CONFIRMER", navConfirmer);
        s.setEnvAddress("RECOUP_PROTOCOL_FEE_WALLET", feeWallet);
        s.setEnvAddress("RECOUP_GUARDIAN", guardian);
        s.setEnvAddress("RECOUP_TIMELOCK", newOwner);
        s.setEnvString("RECOUP_SWITCHOVER_CONFIRM", "RECOUP_WIRE_PHASE_4");
        s.setRecord(_recordFor(d, BASE_SEPOLIA, newOwner));
    }

    function _pauseThrough(R57A06CountingScript s) internal {
        s.queuePause();
        s.executeQueuedPause();
    }

    // ── the count ────────────────────────────────────────────────────────────────────────────────

    /// @notice control_: the reads each timelock entry point makes, counted, and the report path.
    function test_R57A06_236b_control_readsPerTimelockEntryPoint() public {
        TimelockController t = _timelock();
        Deployed memory d = _generation(address(t));
        R57A06CountingScript s = _script(d, address(t));

        uint256 before = s.reads();
        s.queuePause();
        assertEq(s.reads() - before, 2, "queuePause: _resolveDeployed + _requiredTimelock");
        before = s.reads();
        s.executeQueuedPause();
        assertEq(s.reads() - before, 2, "executeQueuedPause: _resolveDeployed + _requiredTimelock");
        before = s.reads();
        s.queue();
        assertEq(s.reads() - before, 3, "queue: _resolveDeployed + _requiredTimelock + _resolveParamsAgainstRecord");
        before = s.reads();
        s.executeQueued();
        assertEq(s.reads() - before, 3, "executeQueued: the same three");
        assertEq(d.credit.liquiditySource(), address(d.pool), "premise: the switchover completed");

        before = s.reads();
        (bool ok, bytes memory reason) = address(s).call(abi.encodeCall(WirePhase4.assertOnly, ()));
        assertTrue(ok, string(reason));
        assertEq(s.reads() - before, 2, "assertOnly: _readParamsAgainstRecord + _resolveDeployed");
    }

    /// @notice control_: `run()`, the EOA-owner entry point, reads twice.
    function test_R57A06_236b_control_runReadsTwice() public {
        Deployed memory d = _generation(DEFAULT_SENDER);
        R57A06CountingScript s = _script(d, DEFAULT_SENDER);
        uint256 before = s.reads();
        s.run();
        assertEq(s.reads() - before, 2, "run: _resolveDeployed + _resolveParamsAgainstRecord");
        assertEq(d.credit.liquiditySource(), address(d.pool), "premise: the switchover completed");
    }

    // ── can the reads disagree? ──────────────────────────────────────────────────────────────────

    /// @notice negative_: a record for ANOTHER CHAIN planted at any ONE of `queue()`'s three reads is
    ///         refused by name at that read. Every read re-checks the one row every read consumes.
    function test_R57A06_236b_negative_everyReadRechecksTheChain() public {
        TimelockController t = _timelock();
        Deployed memory d = _generation(address(t));
        R57A06CountingScript s = _script(d, address(t));
        _pauseThrough(s);
        string memory wrongChain = _recordFor(d, BASE_MAINNET, address(t));

        for (uint256 k = 1; k <= 3; k++) {
            uint256 base = s.reads();
            // From read k of this call onward the record names Base mainnet. Reads 1..k-1 saw the
            // real one, so a refusal proves read k checked `chainId` itself.
            s.plant(base + k, wrongChain);
            vm.expectRevert(abi.encodeWithSelector(WirePhase4.RecordChainMismatch.selector, BASE_MAINNET, BASE_SEPOLIA));
            s.queue();
        }
        s.plant(0, "");
        s.queue();
    }

    /// @notice negative_: a record rewritten to ANOTHER GENERATION after `queue()`'s first read changes
    ///         nothing, because only the first read consumes `contracts.*`. The operation scheduled is
    ///         the one the first read named, byte for byte the unplanted run's.
    function test_R57A06_236b_negative_aRewriteAfterTheContractReadIsUnread() public {
        TimelockController t = _timelock();
        Deployed memory live = _generation(address(t));
        Deployed memory other = _generation(address(t));
        R57A06CountingScript s = _script(live, address(t));
        _pauseThrough(s);

        s.plant(s.reads() + 2, _recordFor(other, BASE_SEPOLIA, address(t)));
        s.queue();
        s.plant(0, "");
        s.executeQueued();
        assertEq(
            live.credit.liquiditySource(), address(live.pool), "the generation the FIRST read named was switched over"
        );
        assertTrue(
            other.credit.liquiditySource() != address(other.pool), "the generation planted later was never touched"
        );
    }

    /// @notice control_ for the test above: the same other generation planted from read ONE is the
    ///         whole run on that record, and is refused - so the plant is live, and the negative above
    ///         is about WHICH read consumes the rows rather than about a plant that never landed.
    function test_R57A06_236b_control_theSamePlantFromReadOneIsTheWholeRun() public {
        TimelockController t = _timelock();
        Deployed memory live = _generation(address(t));
        Deployed memory other = _generation(address(t));
        R57A06CountingScript s = _script(live, address(t));
        _pauseThrough(s);

        s.plant(s.reads() + 1, _recordFor(other, BASE_SEPOLIA, address(t)));
        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector,
                "RECOUP_NAV_ORACLE",
                address(live.oracle),
                address(other.oracle)
            )
        );
        s.queue();
    }

    /// @notice negative_: a record whose OPERATOR row changes at `queue()`'s third read - the only read
    ///         that consumes `operators.owner` - is refused by name at that read, the same refusal an
    ///         operator gets for the same record committed before the run.
    function test_R57A06_236b_negative_anOperatorRewriteIsRefusedByName() public {
        TimelockController t = _timelock();
        Deployed memory d = _generation(address(t));
        R57A06CountingScript s = _script(d, address(t));
        _pauseThrough(s);

        s.plant(s.reads() + 3, _recordFor(d, BASE_SEPOLIA, stranger));
        vm.expectRevert(
            abi.encodeWithSelector(
                WirePhase4.DeployedEnvDisagreesWithRecord.selector, "RECOUP_OWNER", address(t), stranger
            )
        );
        s.queue();
    }
}
