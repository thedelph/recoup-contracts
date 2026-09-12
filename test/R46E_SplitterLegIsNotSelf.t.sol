// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployBase} from "../script/DeployBase.sol";
import {ProtocolFeeSplitter} from "../src/ProtocolFeeSplitter.sol";
import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";
import {MockBond} from "./mocks/MockBond.sol";
import {MockFarm} from "./mocks/MockFarm.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Audit round 46, open item 69: the deploy script's assertion list refuses a
///         `ProtocolFeeSplitter` that names itself as one of its legs.
///
/// @dev The premise, executed here for the first time (audit round 45 reasoned it):
///      `ProtocolFeeSplitter`'s constructor accepts a leg equal to the splitter's own address,
///      because the address is known before construction (`CREATE` is deterministic in the
///      deployer's nonce) and the constructor checks only for zero and for two equal legs. The
///      constructor is frozen for the 33Audits read, so the refusal is script-side: `DeployBase
///      ._assertCoreGraph` probes the deployed fee wallet for `recoupWallet()` and `dexfiWallet()`
///      and reverts `SplitterLegIsSelf` when either answers with the wallet itself.
///
///      Falsifier by construction: every refusing test here is an `expectRevert`, so deleting the
///      assertion turns them red rather than green. The control proves the probe is silent on the
///      two shapes every deployment so far has actually used, an EOA and a healthy splitter.
contract R46E_SplitterLegIsNotSelf is Test, DeployBase {
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal navConfirmer = makeAddr("navConfirmer");
    address internal owner = makeAddr("owner");
    address internal recoupWallet = makeAddr("recoupWallet");
    address internal dexfiWallet = makeAddr("dexfiWallet");

    MockUSDC internal usdc;
    MockBond internal bond;
    MockFarm internal farm;

    /// @dev Round 57 (round-57 item 131, audit agent A6): the DeployBase inheritor round-49's census named as an unreached door.
    ///      Hermetic on all three seams - the fallback, never `super` - so the first reader added to
    ///      this contract cannot hand `contracts/.env` a vote. Nothing here reads a seam today; the
    ///      repository's environment census printed it `direct` on every one.
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
        vm.chainId(ANVIL_CHAIN_ID);
    }

    function _externals() internal view returns (Externals memory) {
        return
            Externals({bond: IDexFiBond(address(bond)), farm: IDexFiFarm(address(farm)), usdc: IERC20(address(usdc))});
    }

    function _params(address feeWallet) internal view returns (GovParams memory) {
        return GovParams({
            owner: owner,
            yieldRecipient: treasury,
            keeper: keeper,
            navConfirmer: navConfirmer,
            protocolFeeWallet: feeWallet,
            guardian: address(0)
        });
    }

    /// @dev External wrapper: `expectRevert` only catches reverts one call depth below the
    ///      cheatcode, and `_assertWiring` is internal.
    function exposedAssertWiring(Deployed memory d, GovParams memory p) external view {
        _assertWiring(d, p);
    }

    /// @dev A real `ProtocolFeeSplitter` whose named leg is its own address, built by predicting
    ///      the `CREATE` address from this contract's nonce and handing it to the constructor.
    function _selfReferential(bool recoupLeg) internal returns (ProtocolFeeSplitter s) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        s = recoupLeg
            ? new ProtocolFeeSplitter(IERC20(address(usdc)), predicted, dexfiWallet)
            : new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, predicted);
        assertEq(address(s), predicted, "premise: the splitter's own address was not the predicted one");
    }

    /// @notice The premise. The frozen constructor accepts itself as either leg.
    function test_R46E_premise_theSplitterConstructorAcceptsItselfAsALeg() public {
        ProtocolFeeSplitter viaRecoup = _selfReferential(true);
        assertEq(viaRecoup.recoupWallet(), address(viaRecoup), "the recoup leg is not the splitter");

        ProtocolFeeSplitter viaDexfi = _selfReferential(false);
        assertEq(viaDexfi.dexfiWallet(), address(viaDexfi), "the dexfi leg is not the splitter");
    }

    /// @notice A deployment whose fee wallet is a splitter with itself as the Recoup leg fails
    ///         the script's post-condition by name.
    function test_R46E_aSplitterNamingItselfAsTheRecoupLegFailsTheDeployAssertion() public {
        ProtocolFeeSplitter s = _selfReferential(true);
        GovParams memory p = _params(address(s));
        Deployed memory d = _deployProtocol(_externals(), p, address(this));
        assertEq(d.harvester.protocolFeeWallet(), address(s), "premise: the deploy wired the splitter");

        vm.expectRevert(abi.encodeWithSelector(DeployBase.SplitterLegIsSelf.selector, address(s), "recoupWallet"));
        this.exposedAssertWiring(d, p);
    }

    /// @notice And the same for the DexFi leg, which is the leg whose loss would be somebody
    ///         else's money.
    function test_R46E_aSplitterNamingItselfAsTheDexfiLegFailsTheDeployAssertion() public {
        ProtocolFeeSplitter s = _selfReferential(false);
        GovParams memory p = _params(address(s));
        Deployed memory d = _deployProtocol(_externals(), p, address(this));

        vm.expectRevert(abi.encodeWithSelector(DeployBase.SplitterLegIsSelf.selector, address(s), "dexfiWallet"));
        this.exposedAssertWiring(d, p);
    }

    /// @notice CONTROL. A healthy splitter and a plain wallet both pass, so the probe refuses only
    ///         the misconfiguration and not the two shapes every deployment has actually shipped.
    function test_R46E_control_aHealthySplitterAndAPlainWalletBothPassTheAssertion() public {
        ProtocolFeeSplitter healthy = new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, dexfiWallet);
        GovParams memory viaSplitter = _params(address(healthy));
        Deployed memory d = _deployProtocol(_externals(), viaSplitter, address(this));
        this.exposedAssertWiring(d, viaSplitter);

        GovParams memory viaWallet = _params(treasury);
        Deployed memory d2 = _deployProtocol(_externals(), viaWallet, address(this));
        this.exposedAssertWiring(d2, viaWallet);
    }
}
