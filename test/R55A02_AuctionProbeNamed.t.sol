// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {ICreditManager} from "../src/interfaces/ICreditManager.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IRiskParams} from "../src/interfaces/IRiskParams.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev The three pointer reads every incoming manager answers BEFORE the two probes are reached,
///      taken from the vault so they agree by construction: the shipped `StubAuction` shape.
contract R55A02ManagerBase {
    address public immutable vault;
    address public immutable riskParams;
    address public immutable navOracle;

    constructor(address v) {
        vault = v;
        riskParams = address(ICollateralVault(v).riskParams());
        navOracle = address(ICollateralVault(v).navOracle());
    }
}

/// @dev Answers neither probed view.
contract R55A02MissingBoth is R55A02ManagerBase {
    constructor(address v) R55A02ManagerBase(v) {}
}

/// @dev Answers `totalBountyParked()` and not `yieldAccruedOn(uint256,uint256)`.
contract R55A02MissingYield is R55A02ManagerBase {
    constructor(address v) R55A02ManagerBase(v) {}

    function totalBountyParked() external pure returns (uint256) {
        return 0;
    }
}

/// @dev Answers every probe on the door: the control. The round-55 wave combined A2's two named view
///      probes with A1's two shape probes on the same door, so a complete manager answers
///      `resolveBounty` and `currentDebtOf` as well, the way `NavPointerAgreement.t.sol`'s and
///      `RiskPointerAgreement.t.sol`'s two-faced managers do; the round-56 wave (item 236) added the
///      four members whose absence strands work, so it answers those too. `writeDownLoss` is not a
///      view, so the door reads its SHAPE: it refuses by name, as the genuine zero-amount call does.
contract R55A02Complete is R55A02ManagerBase {
    error ZeroAmount();

    constructor(address v) R55A02ManagerBase(v) {}

    function totalBountyParked() external pure returns (uint256) {
        return 0;
    }

    function yieldAccruedOn(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function resolveBounty(uint256, bool) external {}

    function currentDebtOf(address) external pure returns (uint256) {
        return 0;
    }

    function writeDownLoss(address, uint256, uint256) external pure returns (uint256) {
        revert ZeroAmount();
    }

    function claimableOf(address) external pure returns (uint256) {
        return 0;
    }

    function pendingYieldOf(address) external pure returns (uint256) {
        return 0;
    }

    function accYieldPerBond() external pure returns (uint256) {
        return 0;
    }
}

/// @dev REVERTS from `totalBountyParked()` with exactly 32 bytes of returndata: the one shape the
///      `!ok` arm catches and the length arm does not.
contract R55A02ThirtyTwoByteRevert is R55A02ManagerBase {
    constructor(address v) R55A02ManagerBase(v) {}

    function totalBountyParked() external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0x00, 1)
            revert(0x00, 0x20)
        }
    }

    function yieldAccruedOn(uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Answers `yieldAccruedOn` with TWO words. A high-level call decoding one `uint256` accepts
///      any returndata of at least 32 bytes, so the bare probe INSTALLED this; the length check
///      names it.
contract R55A02TwoWords is R55A02ManagerBase {
    constructor(address v) R55A02ManagerBase(v) {}

    function totalBountyParked() external pure returns (uint256) {
        return 0;
    }

    function yieldAccruedOn(uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

/// @title R55A02 - `LiquidationAuction.setCreditManager` names the selector that did not answer
/// @notice Round-55 item 246(i). Both completeness probes on the incoming manager were bare
///         high-level calls whose comment argued `onlyOwner` plus the live-work refusal made a loud
///         EMPTY failure free; #482 refuted that argument for the vault's mirror pair. Both now go
///         through `_probeManager(cm, calldata)` raising `CreditManagerDoesNotAnswer(selector)`.
///         No range check, deliberately: both members return a `uint256`, so every 32-byte word is
///         a valid answer and there is nothing to narrow, unlike the vault's `vault()` word.
///
/// @dev Self-contained: a fresh vault holding no manager admits a stub that answers its three
///      pointer reads, and the auction's setter then reads that same stub back as the live one.
///      The `fix_` cases are RED at 9a01996 (EMPTY reason, or a bubbled 32-byte revert, or an
///      install that should have been refused) and green under the fix.
contract R55A02_AuctionProbeNamed is Test {
    bytes4 internal constant DOES_NOT_ANSWER = bytes4(keccak256("CreditManagerDoesNotAnswer(bytes4)"));

    CollateralVault internal vault;
    LiquidationAuction internal auction;
    address internal oracle = makeAddr("r55a02.oracle");
    address internal risk = makeAddr("r55a02.riskParams");

    function setUp() public {
        MockBond bond = new MockBond();
        MockUSDC usdc = new MockUSDC();
        vault = new CollateralVault(IDexFiBond(address(bond)), INAVOracle(oracle), IRiskParams(risk), address(this));
        auction = new LiquidationAuction(
            IERC20(address(usdc)),
            ICollateralVault(address(vault)),
            INAVOracle(oracle),
            IRiskParams(risk),
            address(this)
        );
    }

    function _install(address stub) internal returns (bool ok, bytes memory reason) {
        // Premise: the vault admits the stub, so the auction's setter reaches its own probes.
        vault.setCreditManager(stub);
        assertEq(vault.creditManager(), stub, "premise: the vault holds the stub");
        (ok, reason) = address(auction).call(abi.encodeCall(auction.setCreditManager, (stub)));
    }

    function _named(bytes4 sel) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(DOES_NOT_ANSWER, sel);
    }

    function test_R55A02_246i_control_aCompleteManagerInstalls() public {
        address stub = address(new R55A02Complete(address(vault)));
        (bool ok,) = _install(stub);
        assertTrue(ok, "installs");
        assertEq(auction.creditManager(), stub);
    }

    function test_R55A02_246i_fix_aManagerMissingBothIsNamedOnTotalBountyParked() public {
        (bool ok, bytes memory reason) = _install(address(new R55A02MissingBoth(address(vault))));
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICreditManager.totalBountyParked.selector), "named, not EMPTY");
    }

    function test_R55A02_246i_fix_aManagerMissingYieldAccruedOnIsNamedOnIt() public {
        (bool ok, bytes memory reason) = _install(address(new R55A02MissingYield(address(vault))));
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICreditManager.yieldAccruedOn.selector), "named, not EMPTY");
    }

    function test_R55A02_246i_fix_aThirtyTwoByteRevertIsNamedNotBubbled() public {
        (bool ok, bytes memory reason) = _install(address(new R55A02ThirtyTwoByteRevert(address(vault))));
        assertFalse(ok, "premise: refused");
        assertEq(reason, _named(ICreditManager.totalBountyParked.selector), "named by the success flag");
    }

    function test_R55A02_246i_fix_aTwoWordAnswerIsRefusedByName() public {
        (bool ok, bytes memory reason) = _install(address(new R55A02TwoWords(address(vault))));
        assertFalse(ok, "a two-word answer used to INSTALL");
        assertEq(reason, _named(ICreditManager.yieldAccruedOn.selector), "named by the length check");
    }

    /// @notice RESIDUAL, both trees: the three pointer reads ahead of the probes are still bare
    ///         high-level calls, so an address answering nothing dies EMPTY on `vault()` before either
    ///         named probe is reached. Recorded, not fixed: it is not the pair item 246(i) names.
    function test_R55A02_246i_residual_aCodelessAddressStillDiesEmptyOnTheFirstBareLeg() public {
        address codeless = makeAddr("r55a02.codeless");
        (bool ok, bytes memory reason) = address(auction).call(abi.encodeCall(auction.setCreditManager, (codeless)));
        assertFalse(ok, "refused");
        assertEq(reason.length, 0, "EMPTY, on the bare vault() read");
    }
}
