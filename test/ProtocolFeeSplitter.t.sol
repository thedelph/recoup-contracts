// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {ProtocolFeeSplitter} from "../src/ProtocolFeeSplitter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice The on-chain 80/20 of Recoup's protocol fee with DexFi (agreed 2026-08-06).
///
///         The point of these tests is not that a percentage is computed correctly. It is
///         that the two properties the arrangement is *sold* on actually hold: that
///         neither party can redirect the other's leg, and that the two legs always sum
///         to exactly what arrived.
contract ProtocolFeeSplitterTest is Test {
    MockUSDC internal usdc;
    ProtocolFeeSplitter internal splitter;

    address internal recoupWallet = makeAddr("recoupWallet");
    address internal dexfiWallet = makeAddr("dexfiWallet");

    function setUp() public {
        usdc = new MockUSDC();
        splitter = new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, dexfiWallet);
    }

    // ── construction ─────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ProtocolFeeSplitter.ZeroAddress.selector);
        new ProtocolFeeSplitter(IERC20(address(0)), recoupWallet, dexfiWallet);

        vm.expectRevert(ProtocolFeeSplitter.ZeroAddress.selector);
        new ProtocolFeeSplitter(IERC20(address(usdc)), address(0), dexfiWallet);

        vm.expectRevert(ProtocolFeeSplitter.ZeroAddress.selector);
        new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, address(0));
    }

    function test_constructor_rejectsOneAddressOnBothLegs() public {
        vm.expectRevert(ProtocolFeeSplitter.WalletsMustDiffer.selector);
        new ProtocolFeeSplitter(IERC20(address(usdc)), recoupWallet, recoupWallet);
    }

    /// @dev The whole commercial argument for a contract over a monthly transfer. If any
    ///      of these existed, "neither of us can point it somewhere else" would be false.
    function test_hasNoOwnerAndNoWayToRedirectEitherLeg() public {
        assertEq(splitter.recoupWallet(), recoupWallet);
        assertEq(splitter.dexfiWallet(), dexfiWallet);

        // No `owner()`, no `setRecoupWallet`, no `setDexfiWallet`, no `pause`, no
        // `rescue`. Asserted by selector so that adding one later fails this test rather
        // than quietly weakening the guarantee the partner was given.
        string[6] memory forbidden =
            ["owner()", "setRecoupWallet(address)", "setDexfiWallet(address)", "pause()", "rescue(address)", "sweep()"];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(splitter).call(abi.encodeWithSignature(forbidden[i]));
            assertFalse(ok, forbidden[i]);
        }
    }

    // ── splitting ────────────────────────────────────────────────────────────

    function test_split_paysTheAgreedRatio() public {
        usdc.mint(address(splitter), 1_000e6);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(toRecoup, 800e6, "80% to Recoup");
        assertEq(toDexFi, 200e6, "20% to DexFi");
        assertEq(usdc.balanceOf(recoupWallet), 800e6);
        assertEq(usdc.balanceOf(dexfiWallet), 200e6);
        assertEq(usdc.balanceOf(address(splitter)), 0, "nothing left behind");
    }

    function test_split_isPermissionless() public {
        usdc.mint(address(splitter), 500e6);

        vm.prank(makeAddr("a passing keeper"));
        splitter.split();

        assertEq(usdc.balanceOf(dexfiWallet), 100e6);
    }

    function test_split_revertsOnAnEmptyBalance() public {
        vm.expectRevert(ProtocolFeeSplitter.NothingToSplit.selector);
        splitter.split();
    }

    /// @dev The invariant that matters more than the ratio: whatever arrives leaves, in
    ///      full, in one call. A dust remainder stranded here would accumulate forever,
    ///      because there is no rescue path by design.
    function testFuzz_split_alwaysDistributesTheWholeBalance(uint256 amount) public {
        amount = bound(amount, 1, 1e18);
        usdc.mint(address(splitter), amount);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(toRecoup + toDexFi, amount, "the legs must sum to what arrived");
        assertEq(usdc.balanceOf(address(splitter)), 0, "and nothing may be stranded");
        assertEq(usdc.balanceOf(recoupWallet), toRecoup);
        assertEq(usdc.balanceOf(dexfiWallet), toDexFi);
    }

    /// @dev DexFi's leg is never rounded up at Recoup's expense, and never silently
    ///      zeroed on a small amount either - both are things a partner would reasonably
    ///      check for themselves.
    function testFuzz_split_neverOverpaysEitherLeg(uint256 amount) public {
        amount = bound(amount, 1, 1e18);
        usdc.mint(address(splitter), amount);

        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertLe(toDexFi, (amount * Config.PROTOCOL_FEE_DEXFI_BPS) / Config.BPS + 1);
        assertGe(toRecoup, (amount * Config.PROTOCOL_FEE_RECOUP_BPS) / Config.BPS);
    }

    function test_split_accumulatesAcrossSeveralFlushes() public {
        usdc.mint(address(splitter), 100e6);
        splitter.split();
        usdc.mint(address(splitter), 100e6);
        splitter.split();

        assertEq(usdc.balanceOf(recoupWallet), 160e6);
        assertEq(usdc.balanceOf(dexfiWallet), 40e6);
    }

    // ── preview ──────────────────────────────────────────────────────────────

    function testFuzz_preview_matchesWhatSplitActuallyPays(uint256 amount) public {
        amount = bound(amount, 1, 1e18);
        (uint256 previewRecoup, uint256 previewDexFi) = splitter.preview(amount);

        usdc.mint(address(splitter), amount);
        (uint256 toRecoup, uint256 toDexFi) = splitter.split();

        assertEq(previewRecoup, toRecoup);
        assertEq(previewDexFi, toDexFi);
    }

    // ── the integration it exists for ─────────────────────────────────────────
    //
    // Proved end to end in `EpochHarvester.t.sol`, not here:
    // `test_harvest_protocolFeeSplitsWithDexFiWhenTheSplitterIsTheFeeWallet` runs a real
    // epoch, flushes the fee into this contract and splits it. That belongs where the
    // full wiring already exists, and it is the test that would fail if the payout ever
    // became an approve-and-call the way the lender leg is.
}
