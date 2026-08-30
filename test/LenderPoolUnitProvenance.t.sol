// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Pure rejection evidence for the exact-controller ledger considered for round-22 F3.
/// @dev The production principal-unit surface no longer belongs in these tests. These three
///      arithmetic proofs retain why the previous replacement was rejected without depending on
///      any removed LenderPool getter or treating a rejected design as live implementation.
contract LenderPoolUnitProvenanceTest is Test {
    uint256 private constant VIRTUAL_SHARES = 1_000;

    function _candidatePrefixBasis(uint256 target, uint256 prefixBefore, uint256 prefixAfter, uint256 oldTotalBasis)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(target, prefixAfter, oldTotalBasis, Math.Rounding.Floor)
            - Math.mulDiv(target, prefixBefore, oldTotalBasis, Math.Rounding.Floor);
    }

    function _candidateRemainingBasis(uint256 anchorBasis, uint256 remainingShares, uint256 anchorShares)
        internal
        pure
        returns (uint256)
    {
        return remainingShares == 0 ? 0 : Math.mulDiv(anchorBasis, remainingShares, anchorShares, Math.Rounding.Ceil);
    }

    function _previewDeposit(uint256 assets, uint256 supply, uint256 entryAssets) internal pure returns (uint256) {
        return Math.mulDiv(assets, supply + VIRTUAL_SHARES, entryAssets + 1, Math.Rounding.Floor);
    }

    function _previewRedeem(uint256 shares, uint256 supply, uint256 book) internal pure returns (uint256) {
        return Math.mulDiv(shares, book + 1, supply + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    /// @notice The rejected checkpoint telescopes exactly across any two burn partitions.
    /// @dev This local property was sound. It did not prove that the checkpoint remained attached
    ///      to the assets its controller's fungible shares could redeem.
    function testFuzz_R22F3_rejectedExactControllerLedger_checkpointDebitsTelescopeAcrossPartitions(
        uint96 anchorBasisSeed,
        uint96 anchorSharesSeed,
        uint96 firstBurnSeed,
        uint96 secondBurnSeed
    ) public pure {
        uint256 anchorBasis = bound(uint256(anchorBasisSeed), 1, type(uint96).max);
        uint256 anchorShares = bound(uint256(anchorSharesSeed), 2, type(uint96).max);
        uint256 firstBurn = bound(uint256(firstBurnSeed), 1, anchorShares - 1);
        uint256 sharesAfterFirst = anchorShares - firstBurn;
        uint256 secondBurn = bound(uint256(secondBurnSeed), 0, sharesAfterFirst);
        uint256 sharesAfterSecond = sharesAfterFirst - secondBurn;

        uint256 basisAfterFirst = _candidateRemainingBasis(anchorBasis, sharesAfterFirst, anchorShares);
        uint256 basisAfterSecond = _candidateRemainingBasis(anchorBasis, sharesAfterSecond, anchorShares);
        uint256 slicedDebit = (anchorBasis - basisAfterFirst) + (basisAfterFirst - basisAfterSecond);
        uint256 oneShotRemaining = _candidateRemainingBasis(anchorBasis, sharesAfterSecond, anchorShares);

        assertEq(basisAfterSecond, oneShotRemaining, "partitioning changed the checkpoint remainder");
        assertEq(slicedDebit, anchorBasis - oneShotRemaining, "partitioning changed the cumulative debit");
    }

    /// @notice Exact prefix conservation still detaches the last asset-wei from its redeeming shares.
    function test_R22F3_rejectedExactControllerLedger_prefixFloorsDetachTheLastAssetWei() public pure {
        uint256 aliceShares = 2_000;
        uint256 bobShares = 1_000;
        uint256 supply = aliceShares + bobShares;
        uint256 target = 1;
        uint256 book = 1;

        uint256 aliceBasis = _candidatePrefixBasis(target, 0, 2, 3);
        uint256 bobBasis = _candidatePrefixBasis(target, 2, 3, 3);
        assertEq(aliceBasis, 0, "the first prefix floor assigns Alice no basis");
        assertEq(bobBasis, 1, "the final prefix receives the exact residual");
        assertEq(aliceBasis + bobBasis, target, "prefix allocation failed to conserve the target");

        uint256 alicePayout = _previewRedeem(aliceShares, supply, book);
        uint256 candidateNetAfter = target - aliceBasis;
        uint256 candidateBookAfter = book - alicePayout;

        assertEq(alicePayout, 1, "Alice's shares do not redeem the last asset-wei");
        assertEq(candidateNetAfter, 1, "the zero-basis burn unexpectedly debited the counter");
        assertEq(candidateBookAfter, 0, "Alice did not take the whole remaining book");
        assertEq(candidateNetAfter - candidateBookAfter, 1, "the rejection inequality moved");
    }

    /// @notice Released yield lets a controller redeem above its unchanged exact basis.
    function test_R22F3_rejectedExactControllerLedger_yieldFirstTargetCrossesControllerBasis() public pure {
        uint256 aliceBasis = 10_000;
        uint256 aliceShares = _previewDeposit(aliceBasis, 0, 0);
        uint256 releasedBook = aliceBasis + 2;
        uint256 bobBasis = 9_998;
        uint256 bobShares = _previewDeposit(bobBasis, aliceShares, releasedBook);
        uint256 supply = aliceShares + bobShares;
        uint256 postLossBook = aliceBasis + bobBasis;
        uint256 target = postLossBook;

        assertEq(aliceShares, 10_000_000, "Alice's virtual-share quote moved");
        assertEq(bobShares, 9_996_000, "Bob's yield-aware entry quote moved");

        uint256 candidateAliceBasis = _candidatePrefixBasis(target, 0, aliceBasis, target);
        uint256 candidateBobBasis = _candidatePrefixBasis(target, aliceBasis, target, target);
        assertEq(candidateAliceBasis, aliceBasis, "Alice's exact prefix basis moved");
        assertEq(candidateBobBasis, bobBasis, "Bob's exact prefix basis moved");

        uint256 alicePayout = _previewRedeem(aliceShares, supply, postLossBook);
        uint256 candidateNetAfter = target - candidateAliceBasis;
        uint256 candidateBookAfter = postLossBook - alicePayout;

        assertEq(alicePayout, 10_001, "Alice's shares stopped crossing her basis by one wei");
        assertEq(candidateNetAfter, 9_998, "the candidate counter remainder moved");
        assertEq(candidateBookAfter, 9_997, "the economic book remainder moved");
        assertEq(candidateNetAfter - candidateBookAfter, 1, "the rejection inequality moved");
    }
}
