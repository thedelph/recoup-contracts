// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Test-only executable specification for LenderPool's canonical-cash replacement.
/// @dev This is deliberately independent of LenderPool. It carries only the balance-sheet terms
///      needed to decide F3 and is an oracle for production tests, not an implementation helper.
contract CanonicalCashModel {
    uint256 internal constant ACC_PRECISION = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1_000;
    uint256 internal constant MIN_SUPPLY = 10_000_000;
    uint256 internal constant ABSOLUTE_ASSET_CAP = 250_000e6;
    uint256 public constant MAX_SHARES_PER_ASSET = 1 << 128;

    uint256 public rawCash;
    uint256 public accountedCash;
    uint256 public outstandingPrincipal;
    uint256 public totalClaimable;
    uint256 public totalSupply;
    uint256 public depositCap;

    uint256 public pendingYield;
    uint256 public yieldRate;
    uint256 public lastYieldAccrualAt;
    uint256 public lastEpochDeliveryAt;
    uint256 public yieldStreamEndsAt;

    uint256 public recognisedIn;
    uint256 public paidOut;
    uint256 public donatedIn;
    uint256 public externallyDestroyed;

    error AmountZero();
    error DepositClosed();
    error InsufficientCash();
    error InsufficientShares();
    error PrincipalNeedsMinimumSupply();
    error ClaimsUnderfunded();
    error CoverExceedsDeficit();
    error EntryPriceDeficitExceeded(uint256 attempted, uint256 deficit);
    error MaximumShareSupplyExceeded(uint256 resultingSupply, uint256 maximumSupply);
    error NoSharesOutstanding();
    error StreamNotFrozen();

    constructor(uint256 cap) {
        depositCap = cap;
        lastYieldAccrualAt = block.timestamp;
        lastEpochDeliveryAt = block.timestamp;
    }

    function minimumSupply() external pure returns (uint256) {
        return MIN_SUPPLY;
    }

    function setDepositCap(uint256 cap) external {
        depositCap = cap;
    }

    function effectiveCash() public view returns (uint256) {
        return accountedCash < rawCash ? accountedCash : rawCash;
    }

    function cashDeficit() public view returns (uint256) {
        return accountedCash > rawCash ? accountedCash - rawCash : 0;
    }

    function unmanagedSurplus() public view returns (uint256) {
        return rawCash > accountedCash ? rawCash - accountedCash : 0;
    }

    function claimLiquidityDeficit() public view returns (uint256) {
        uint256 cash = effectiveCash();
        return totalClaimable > cash ? totalClaimable - cash : 0;
    }

    function claimSolvencyDeficit() public view returns (uint256) {
        uint256 backing = effectiveCash() + outstandingPrincipal;
        return totalClaimable > backing ? totalClaimable - backing : 0;
    }

    function unreleasedYield() public view returns (uint256) {
        uint256 pending = pendingYield;
        if (pending == 0) return 0;
        if (yieldRate == 0) return pending;
        if (block.timestamp >= yieldStreamEndsAt) return 0;
        if (block.timestamp <= lastYieldAccrualAt) return pending;

        uint256 released = ((block.timestamp - lastYieldAccrualAt) * yieldRate) / ACC_PRECISION;
        return released >= pending ? 0 : pending - released;
    }

    function effectiveUnreleasedYield() public view returns (uint256) {
        uint256 unreleased = unreleasedYield();
        uint256 deficit = cashDeficit();
        unreleased = unreleased > deficit ? unreleased - deficit : 0;

        uint256 gross = _effectiveGrossBook();
        return unreleased < gross ? unreleased : gross;
    }

    function totalAssets() public view returns (uint256) {
        return _effectiveGrossBook() - effectiveUnreleasedYield();
    }

    function entryAssets() public view returns (uint256) {
        return totalAssets() + effectiveUnreleasedYield();
    }

    function shareholderCash() public view returns (uint256) {
        uint256 cash = effectiveCash();
        uint256 claims = totalClaimable;
        if (cash <= claims) return 0;
        uint256 releasedCash = cash - claims;
        uint256 unreleased = effectiveUnreleasedYield();
        return releasedCash > unreleased ? releasedCash - unreleased : 0;
    }

    /// @notice Minimum entry book that keeps the ERC-4626 share quotient at or below 2^128.
    /// @dev The minus one is exact because conversions divide by entryAssets + 1.
    function requiredEntryAssets() public view returns (uint256) {
        uint256 quotient = totalSupply / MAX_SHARES_PER_ASSET;
        uint256 remainderWithVirtual = (totalSupply % MAX_SHARES_PER_ASSET) + VIRTUAL_SHARES;
        return quotient + Math.ceilDiv(remainderWithVirtual, MAX_SHARES_PER_ASSET) - 1;
    }

    /// @notice Absolute real share supply supported by the quotient and protocol asset ceilings.
    function maximumShareSupply() public pure returns (uint256) {
        return MAX_SHARES_PER_ASSET * (ABSOLUTE_ASSET_CAP + 1) - VIRTUAL_SHARES;
    }

    /// @notice Recognised cash needed to preserve the bounded entry quotient after reconciliation.
    /// @dev Principal is deliberately excluded because it can still be written off after entry.
    function entryPriceDeficit() public view returns (uint256) {
        uint256 target = totalClaimable + requiredEntryAssets();
        uint256 cash = effectiveCash();
        return target > cash ? target - cash : 0;
    }

    /// @notice Shareholder cash that can leave while a total principal loss preserves entry math.
    /// @dev Effective unreleased yield is already retained outside shareholderCash and still
    ///      belongs in entryAssets, so only the uncovered part of the numeric reserve is held back.
    function available() public view returns (uint256) {
        if (totalSupply < MIN_SUPPLY || claimLiquidityDeficit() != 0) return 0;
        uint256 cash = shareholderCash();
        uint256 required = requiredEntryAssets();
        uint256 unreleased = effectiveUnreleasedYield();
        uint256 reserve = required > unreleased ? required - unreleased : 0;
        return cash > reserve ? cash - reserve : 0;
    }

    /// @notice Released cash that must remain while principal can still be written off.
    function entryPriceCashReserve() public view returns (uint256) {
        if (outstandingPrincipal == 0) return 0;
        uint256 required = requiredEntryAssets();
        uint256 unreleased = effectiveUnreleasedYield();
        return required > unreleased ? required - unreleased : 0;
    }

    function executableShareholderCash() public view returns (uint256) {
        uint256 cash = shareholderCash();
        uint256 reserve = entryPriceCashReserve();
        return cash > reserve ? cash - reserve : 0;
    }

    function depositCapUsage() public view returns (uint256) {
        return _storedGrossBook();
    }

    function maxDeposit() public view returns (uint256) {
        if (cashDeficit() != 0 || claimLiquidityDeficit() != 0 || entryPriceDeficit() != 0) return 0;
        uint256 usage = depositCapUsage();
        if (usage >= depositCap) return 0;
        uint256 headroom = depositCap - usage;

        uint256 supply = totalSupply;
        uint256 maximumSupply = maximumShareSupply();
        if (supply >= maximumSupply) return 0;

        uint256 shareRoom = maximumSupply - supply;
        uint256 assetRoom = previewMint(shareRoom + 1) - 1;
        if (assetRoom < headroom) headroom = assetRoom;
        return previewDeposit(headroom) == 0 ? 0 : headroom;
    }

    function maxMint() public view returns (uint256) {
        uint256 shares = previewDeposit(maxDeposit());
        uint256 supply = totalSupply;
        uint256 maximumSupply = maximumShareSupply();
        uint256 shareRoom = supply < maximumSupply ? maximumSupply - supply : 0;
        return shares < shareRoom ? shares : shareRoom;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _saturatingMulDiv(assets, totalSupply + VIRTUAL_SHARES, entryAssets() + 1, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _saturatingMulDiv(shares, entryAssets() + 1, totalSupply + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _saturatingMulDiv(shares, totalAssets() + 1, totalSupply + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    function maxBurnBySupply() public view returns (uint256) {
        uint256 supply = totalSupply;
        if (outstandingPrincipal == 0) return supply;
        return supply > MIN_SUPPLY ? supply - MIN_SUPPLY : 0;
    }

    function maxRedeem() public view returns (uint256) {
        uint256 supplyMaximum = maxBurnBySupply();
        if (supplyMaximum == 0 || claimLiquidityDeficit() != 0) return 0;

        uint256 cashShares = Math.mulDiv(
            executableShareholderCash(), totalSupply + VIRTUAL_SHARES, totalAssets() + 1, Math.Rounding.Floor
        );
        return cashShares < supplyMaximum ? cashShares : supplyMaximum;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert AmountZero();
        if (cashDeficit() != 0) revert DepositClosed();
        if (assets > maxDeposit()) revert DepositClosed();
        shares = previewDeposit(assets);
        if (shares == 0) revert DepositClosed();

        rawCash += assets;
        accountedCash += assets;
        _mintShares(shares);
        recognisedIn += assets;
    }

    function mint(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert AmountZero();
        if (cashDeficit() != 0) revert DepositClosed();
        if (shares > maxMint()) revert DepositClosed();
        assets = previewMint(shares);
        if (assets == 0 || assets > maxDeposit()) revert DepositClosed();

        rawCash += assets;
        accountedCash += assets;
        _mintShares(shares);
        recognisedIn += assets;
    }

    function donate(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        rawCash += amount;
        donatedIn += amount;
    }

    function destroyCash(uint256 amount) external returns (uint256 destroyed) {
        if (amount == 0) revert AmountZero();
        destroyed = amount < rawCash ? amount : rawCash;
        rawCash -= destroyed;
        externallyDestroyed += destroyed;
    }

    function lend(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        _reconcile();
        if (totalSupply < MIN_SUPPLY) revert PrincipalNeedsMinimumSupply();
        if (claimLiquidityDeficit() != 0 || amount > available()) revert InsufficientCash();

        rawCash -= amount;
        accountedCash -= amount;
        outstandingPrincipal += amount;
        paidOut += amount;
    }

    function repay(uint256 amount, uint256 streamDuration) external {
        if (amount == 0) revert AmountZero();
        _reconcile();

        uint256 claimDeficitBefore = claimSolvencyDeficit();
        uint256 principal = amount < outstandingPrincipal ? amount : outstandingPrincipal;
        uint256 surplus = amount - principal;
        outstandingPrincipal -= principal;
        rawCash += amount;
        recognisedIn += amount;

        uint256 covered = surplus < claimDeficitBefore ? surplus : claimDeficitBefore;
        uint256 streamable = surplus - covered;

        if (totalSupply == 0 && outstandingPrincipal == 0) {
            accountedCash += principal + covered;
            return;
        }

        accountedCash += amount;
        if (streamable != 0) _addGainToStream(streamable, streamDuration);
    }

    function addActiveGain(uint256 amount, uint256 streamDuration) external {
        if (amount == 0) revert AmountZero();
        _reconcile();
        uint256 claimDeficitBefore = claimSolvencyDeficit();
        rawCash += amount;
        recognisedIn += amount;
        uint256 covered = amount < claimDeficitBefore ? amount : claimDeficitBefore;
        uint256 streamable = amount - covered;

        if (totalSupply == 0 && outstandingPrincipal == 0) {
            accountedCash += covered;
            return;
        }

        accountedCash += amount;
        if (streamable != 0) _addGainToStream(streamable, streamDuration);
    }

    function addFrozenGain(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        _reconcile();
        uint256 claimDeficitBefore = claimSolvencyDeficit();
        rawCash += amount;
        recognisedIn += amount;

        uint256 covered = amount < claimDeficitBefore ? amount : claimDeficitBefore;
        uint256 streamable = amount - covered;

        if (totalSupply == 0 && outstandingPrincipal == 0) {
            accountedCash += covered;
            return;
        }

        accountedCash += amount;
        pendingYield = unreleasedYield() + streamable;
        yieldRate = 0;
        lastYieldAccrualAt = block.timestamp;
        yieldStreamEndsAt = block.timestamp;
    }

    /// @notice Deliver one epoch, pulling only a senior claim cure below the real-supply floor.
    /// @dev Any unaccepted offer remains outside the model. Only a fully accepted epoch advances
    ///      the delivery clock. Recovery and principal-surplus gains keep their generic behavior.
    function deliverEpochYield(uint256 offered, uint256 streamDuration) external returns (uint256 accepted) {
        if (offered == 0) revert AmountZero();
        _reconcile();

        uint256 deficit = claimSolvencyDeficit();
        uint256 covered = offered < deficit ? offered : deficit;
        if (totalSupply < MIN_SUPPLY) {
            if (covered == 0) revert NoSharesOutstanding();
            accepted = covered;
            rawCash += accepted;
            accountedCash += accepted;
            recognisedIn += accepted;
            if (accepted == offered) lastEpochDeliveryAt = block.timestamp;
            return accepted;
        }

        accepted = offered;
        rawCash += accepted;
        accountedCash += accepted;
        recognisedIn += accepted;

        uint256 streamable = accepted - covered;
        if (streamable != 0) _addGainToStream(streamable, streamDuration);
        lastEpochDeliveryAt = block.timestamp;
    }

    function activateFrozen(uint256 streamDuration) external {
        if (yieldRate != 0 || pendingYield == 0) revert StreamNotFrozen();
        _startStream(pendingYield, streamDuration);
    }

    function socialiseLoss(uint256 amount) external returns (uint256 absorbed) {
        if (amount == 0) revert AmountZero();
        _reconcile();
        absorbed = amount < outstandingPrincipal ? amount : outstandingPrincipal;
        outstandingPrincipal -= absorbed;

        uint256 backed = _storedGrossBook();
        uint256 unreleased = unreleasedYield();
        if (unreleased > backed) _writeYieldState(backed);
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert AmountZero();
        _reconcile();
        if (shares > maxRedeem()) revert InsufficientShares();
        assets = previewRedeem(shares);
        _burn(shares);
        rawCash -= assets;
        accountedCash -= assets;
        paidOut += assets;
        _freezeAfterLowSupplyBurn();
    }

    function service(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert AmountZero();
        _reconcile();
        if (shares > maxRedeem()) revert InsufficientShares();
        assets = previewRedeem(shares);
        _burn(shares);
        totalClaimable += assets;
        _freezeAfterLowSupplyBurn();
    }

    function claim(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        _reconcile();
        if (claimLiquidityDeficit() != 0) revert ClaimsUnderfunded();
        if (amount > totalClaimable) revert InsufficientCash();

        totalClaimable -= amount;
        rawCash -= amount;
        accountedCash -= amount;
        paidOut += amount;
    }

    function coverClaimDeficit(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        _reconcile();
        uint256 deficit = claimSolvencyDeficit();
        if (amount > deficit) revert CoverExceedsDeficit();

        rawCash += amount;
        accountedCash += amount;
        recognisedIn += amount;
    }

    function coverEntryPriceDeficit(uint256 amount) external returns (uint256 remaining) {
        if (amount == 0) revert AmountZero();
        _reconcile();
        if (claimLiquidityDeficit() != 0) revert ClaimsUnderfunded();

        uint256 deficit = entryPriceDeficit();
        if (amount > deficit) revert EntryPriceDeficitExceeded(amount, deficit);

        rawCash += amount;
        accountedCash += amount;
        recognisedIn += amount;
        remaining = deficit - amount;
    }

    function reconcileCashDeficit() external returns (uint256 deficit) {
        deficit = _reconcile();
    }

    function _reconcile() internal returns (uint256 deficit) {
        deficit = cashDeficit();
        if (deficit == 0) return 0;

        uint256 remainingYield = effectiveUnreleasedYield();
        accountedCash = rawCash;
        _writeYieldState(remainingYield);
    }

    function _addGainToStream(uint256 amount, uint256 streamDuration) internal {
        uint256 pot = unreleasedYield() + amount;
        if (totalSupply < MIN_SUPPLY) {
            pendingYield = pot;
            yieldRate = 0;
            lastYieldAccrualAt = block.timestamp;
            yieldStreamEndsAt = block.timestamp;
            return;
        }
        _startStream(pot, streamDuration);
    }

    function _startStream(uint256 pot, uint256 streamDuration) internal {
        uint256 duration = streamDuration == 0 ? 1 : streamDuration;
        uint256 remaining = yieldStreamEndsAt > block.timestamp ? yieldStreamEndsAt - block.timestamp : 0;
        if (remaining > duration) duration = remaining;

        pendingYield = pot;
        yieldRate = (pot * ACC_PRECISION) / duration;
        if (yieldRate == 0) yieldRate = 1;
        lastYieldAccrualAt = block.timestamp;
        yieldStreamEndsAt = block.timestamp + duration;
    }

    function _writeYieldState(uint256 remainingYield) internal {
        bool active = yieldRate != 0;
        uint256 oldRate = yieldRate;
        uint256 oldRemaining = yieldStreamEndsAt > block.timestamp ? yieldStreamEndsAt - block.timestamp : 0;

        pendingYield = remainingYield;
        lastYieldAccrualAt = block.timestamp;
        if (remainingYield == 0 || !active || oldRemaining == 0) {
            yieldRate = 0;
            yieldStreamEndsAt = block.timestamp;
            return;
        }

        yieldRate = oldRate;
        uint256 duration = Math.mulDiv(remainingYield, ACC_PRECISION, oldRate, Math.Rounding.Ceil);
        if (duration > oldRemaining) duration = oldRemaining;
        yieldStreamEndsAt = block.timestamp + duration;
    }

    function _burn(uint256 shares) internal {
        if (shares > totalSupply) revert InsufficientShares();
        if (outstandingPrincipal != 0 && totalSupply - shares < MIN_SUPPLY) {
            revert PrincipalNeedsMinimumSupply();
        }
        totalSupply -= shares;
    }

    function _mintShares(uint256 shares) internal {
        uint256 maximumSupply = maximumShareSupply();
        if (totalSupply > maximumSupply || shares > maximumSupply - totalSupply) {
            revert MaximumShareSupplyExceeded(
                totalSupply > type(uint256).max - shares ? type(uint256).max : totalSupply + shares, maximumSupply
            );
        }
        totalSupply += shares;
    }

    function _freezeAfterLowSupplyBurn() internal {
        if (totalSupply >= MIN_SUPPLY) return;

        if (totalSupply == 0 && outstandingPrincipal == 0) {
            if (accountedCash > totalClaimable) accountedCash = totalClaimable;
            pendingYield = 0;
            yieldRate = 0;
            lastYieldAccrualAt = block.timestamp;
            yieldStreamEndsAt = block.timestamp;
            return;
        }

        uint256 frozen = unreleasedYield();
        pendingYield = frozen;
        yieldRate = 0;
        lastYieldAccrualAt = block.timestamp;
        yieldStreamEndsAt = block.timestamp;
    }

    function _storedGrossBook() internal view returns (uint256) {
        return _subOrZero(accountedCash + outstandingPrincipal, totalClaimable);
    }

    function _effectiveGrossBook() internal view returns (uint256) {
        return _subOrZero(effectiveCash() + outstandingPrincipal, totalClaimable);
    }

    function _subOrZero(uint256 left, uint256 right) internal pure returns (uint256) {
        return left > right ? left - right : 0;
    }

    function _saturatingMulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding)
        internal
        pure
        returns (uint256 result)
    {
        (uint256 high,) = Math.mul512(x, y);
        if (denominator == 0 || high >= denominator) return type(uint256).max;

        result = Math.mulDiv(x, y, denominator);
        if (Math.unsignedRoundsUp(rounding) && mulmod(x, y, denominator) != 0) {
            if (result == type(uint256).max) return result;
            result += 1;
        }
    }
}
