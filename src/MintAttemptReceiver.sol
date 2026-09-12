// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {Config} from "./Config.sol";
import {IDexFiBond} from "./interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "./interfaces/IDexFiFarm.sol";

/// @title MintAttemptReceiver
/// @notice The implementation behind one deterministic ERC-1167 clone per signed
///         DexFi mint attempt. A clone receives the freshly minted position, unwinds
///         it in the same transaction and hands the bonds to the custody adapter.
/// @dev There is deliberately no initializer. Every authority and external binding
///      is embedded as an implementation immutable, so a newly deployed clone has no
///      configuration window that another account can front-run. The only clone
///      storage is corroborated farm yield that a paused or blacklisted USDC could
///      not forward to the adapter.
contract MintAttemptReceiver is IERC1155Receiver {
    error NotAdapter();
    error ImplementationCall();
    error UnexpectedBond(address token);
    error UnexpectedTokenId(uint256 tokenId);
    error BatchTransferUnsupported();
    error ZeroAddress();

    event FarmYieldParked(uint256 newlyAccrued, uint256 totalParked);
    event FarmYieldForwarded(uint256 amount, uint256 remainingParked);
    event RawUsdcRecovered(address indexed recipient, uint256 moved, uint256 remaining);
    event NativeRecovered(address indexed recipient, uint256 moved, uint256 remaining);
    event EmergencyFarmExit(uint256 amount);

    address public immutable adapter;
    IDexFiBond public immutable bond;
    IDexFiFarm public immutable farm;
    IERC20 public immutable usdc;

    /// @notice Farm-originated USDC measured around a farm call but not yet
    ///         received by the adapter. Raw token donations never enter this value.
    uint256 public parkedFarmYield;

    address private immutable _implementation;

    modifier onlyAdapter() {
        if (msg.sender != adapter) revert NotAdapter();
        _;
    }

    modifier onlyClone() {
        if (address(this) == _implementation) revert ImplementationCall();
        _;
    }

    constructor(address adapter_, IDexFiBond bond_, IDexFiFarm farm_, IERC20 usdc_) {
        if (
            adapter_ == address(0) || address(bond_) == address(0) || address(farm_) == address(0)
                || address(usdc_) == address(0)
        ) revert ZeroAddress();
        adapter = adapter_;
        bond = bond_;
        farm = farm_;
        usdc = usdc_;
        _implementation = address(this);
    }

    /// @notice Accept accidental native transfers only on attempt clones. The
    ///         implementation itself remains inert, including for plain ETH sends.
    receive() external payable onlyClone {}

    /// @notice Unwind the units created by one mint and deliver them to the adapter.
    /// @param stakedAmount Increase in this clone's farm position caused by the mint.
    /// @param bondAmount Exact keeper-signed amount the clone must hand off.
    /// @param farmPaidOnAutoDeposit USDC measured arriving at the clone while the
    ///        bond's auto-stake hook ran.
    /// @return farmYieldForwarded Corroborated farm USDC actually received by the
    ///         adapter. A failed token transfer parks the remainder instead of
    ///         reverting the collateral deposit.
    function releaseMint(uint256 stakedAmount, uint256 bondAmount, uint256 farmPaidOnAutoDeposit)
        external
        onlyAdapter
        onlyClone
        returns (uint256 farmYieldForwarded)
    {
        uint256 withdrawPaid;
        if (stakedAmount != 0) {
            uint256 beforeBalance = usdc.balanceOf(address(this));
            farm.withdraw(stakedAmount);
            withdrawPaid = usdc.balanceOf(address(this)) - beforeBalance;
        }

        // FALSE (audit round 44). `withdrawPaid` stays zero when nothing was staked, which is exactly
        // the amount the farm paid in that case.
        // forge-lint: disable-next-line(uninitialized-local)
        uint256 newlyAccrued = farmPaidOnAutoDeposit + withdrawPaid;
        if (newlyAccrued != 0) parkedFarmYield += newlyAccrued;

        // ERC-1155 authorisation is caller-based: the clone must move its own
        // units. The adapter cannot pull them without an approval. DexFi's transfer
        // whitelist still passes because the whitelisted adapter is `to`.
        // ACCEPTED (audit round 44). `onlyAdapter onlyClone`, and every path that reaches the adapter
        // starts at a `nonReentrant` vault entry point. DexFi's bond contract is third-party and
        // MUTABLE, which is why re-entry is refused by the caller gate rather than by trusting it.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        bond.safeTransferFrom(address(this), adapter, Config.DEXFI_BOND_TOKEN_ID, bondAmount, "");

        farmYieldForwarded = _tryForwardFarmYield();
        if (parkedFarmYield != 0 && newlyAccrued != 0) {
            emit FarmYieldParked(newlyAccrued, parkedFarmYield);
        }
    }

    /// @notice Retry delivery of corroborated farm yield parked at this clone.
    /// @dev Destination is immutable, so the adapter can safely expose a
    ///      permissionless wrapper around this call.
    function flushFarmYield()
        external
        onlyAdapter
        onlyClone
        returns (uint256 farmYieldForwarded)
    {
        farmYieldForwarded = _tryForwardFarmYield();
    }

    /// @notice Withdraw every child stake and hand all child assets to the adapter.
    /// @dev Existing USDC is swept separately from newly measured farm payout. The
    ///      caller can therefore forward donations without reporting them as yield.
    function recoverAll(address payable recoveryRecipient)
        external
        onlyAdapter
        onlyClone
        returns (
            uint256 recoveredBonds,
            uint256 farmYieldForwarded,
            uint256 rawUsdcForwarded,
            uint256 rawUsdcRemaining,
            uint256 nativeForwarded,
            uint256 nativeRemaining
        )
    {
        if (recoveryRecipient == address(0)) revert ZeroAddress();
        // FALSE (audit round 44). Tuple destructure; the slot this site needs is bound.
        // forge-lint: disable-next-line(unused-return)
        (uint256 staked,) = farm.userInfo(address(this));
        if (staked != 0 || farm.pendingShare(address(this)) != 0) {
            uint256 beforeBalance = usdc.balanceOf(address(this));
            farm.withdraw(staked);
            // Saturated, like `emergencyRecoverAll` and `_tryForwardRawUsdc` in this file, and the
            // adapter's `_farmDelta`. Round-49 finding: the farm holds this window too, and from
            // inside `withdraw` it can reach the adapter's permissionless `flushMintAttemptYield`,
            // which has this clone forward its park mid-window - so the balance can come back
            // BELOW `beforeBalance` and a bare subtraction panics the owner's recovery. A drained
            // window reports 0 for what the farm paid, the same under-count `_farmDelta` accepts.
            uint256 afterBalance = usdc.balanceOf(address(this));
            uint256 farmPaid = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
            if (farmPaid != 0) parkedFarmYield += farmPaid;
        }

        recoveredBonds = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        if (recoveredBonds != 0) {
            // ACCEPTED (audit round 44). Same gate as `releaseMint`: `onlyAdapter onlyClone`, reached only
            // through a `nonReentrant` vault or an `onlyOwner` adapter entry point. Block form because a
            // next-line directive does not reach a multi-line span at forge 1.8.1.
            // forge-lint: disable-start(reentrancy-no-eth)
            bond.safeTransferFrom(
                address(this), adapter, Config.DEXFI_BOND_TOKEN_ID, recoveredBonds, ""
            );
            // forge-lint: disable-end(reentrancy-no-eth)
        }

        farmYieldForwarded = _tryForwardFarmYield();
        (rawUsdcForwarded, rawUsdcRemaining) = _tryForwardRawUsdc(recoveryRecipient);
        (nativeForwarded, nativeRemaining) = _tryForwardNative(recoveryRecipient);
    }

    /// @notice Use the farm's reward-forfeiting escape hatch and leave recovered
    ///         bonds at the clone for a later normal recovery.
    /// @dev Deliberately does not perform the clone-to-adapter ERC-1155 transfer, so
    ///      governance can exit a broken farm even while DexFi has revoked the
    ///      adapter's bond whitelist entry. Once restored, `recoverAll` completes the
    ///      handoff to an explicit recovery recipient through the adapter.
    function emergencyRecoverAll()
        external
        onlyAdapter
        onlyClone
        returns (
            uint256 bondsAtReceiver,
            uint256 farmYieldForwarded,
            uint256 rawUsdcRemaining,
            uint256 nativeRemaining
        )
    {
        // FALSE (audit round 44). Tuple destructure; the slot this site needs is bound.
        // forge-lint: disable-next-line(unused-return)
        (uint256 staked,) = farm.userInfo(address(this));
        if (staked != 0 || farm.pendingShare(address(this)) != 0) {
            farm.emergencyWithdraw();
            emit EmergencyFarmExit(staked);
        }

        bondsAtReceiver = bond.balanceOf(address(this), Config.DEXFI_BOND_TOKEN_ID);
        farmYieldForwarded = _tryForwardFarmYield();
        uint256 balance = usdc.balanceOf(address(this));
        uint256 parked = parkedFarmYield;
        rawUsdcRemaining = balance > parked ? balance - parked : 0;
        nativeRemaining = address(this).balance;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        view
        override
        onlyClone
        returns (bytes4)
    {
        if (msg.sender != address(bond)) revert UnexpectedBond(msg.sender);
        if (id != Config.DEXFI_BOND_TOKEN_ID) revert UnexpectedTokenId(id);
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        override
        onlyClone
        returns (bytes4)
    {
        if (msg.sender != address(bond)) revert UnexpectedBond(msg.sender);
        revert BatchTransferUnsupported();
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _tryForwardFarmYield() private returns (uint256 forwarded) {
        uint256 amount = parkedFarmYield;
        if (amount == 0) return 0;

        forwarded = _tryTransferUsdc(adapter, amount);
        if (forwarded != 0) {
            parkedFarmYield = amount - forwarded;
            emit FarmYieldForwarded(forwarded, parkedFarmYield);
        }
    }

    function _tryForwardRawUsdc(address recipient)
        private
        returns (uint256 forwarded, uint256 remaining)
    {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 parked = parkedFarmYield;
        uint256 raw = balance > parked ? balance - parked : 0;
        if (raw != 0) forwarded = _tryTransferUsdc(recipient, raw);

        balance = usdc.balanceOf(address(this));
        remaining = balance > parkedFarmYield ? balance - parkedFarmYield : 0;
        emit RawUsdcRecovered(recipient, forwarded, remaining);
    }

    function _tryForwardNative(address payable recipient)
        private
        returns (uint256 forwarded, uint256 remaining)
    {
        uint256 beforeBalance = address(this).balance;
        if (beforeBalance != 0) {
            // Best-effort by design: a rejecting recovery recipient must not roll
            // back the bond handoff. Measure the clone's balance rather than trust
            // the call result, including for a recipient that sends some value back.
            // ACCEPTED (audit round 44). Both remedies the lint names are already in force. The caller is
            // restricted twice - `onlyAdapter onlyClone` here, `onlyOwner` on
            // `DirectCallAdapter.recoverMintAttempt` - and the destination is validated there against zero,
            // the adapter and the receiver. The control this hands `recoveryRecipient` is audit round 34's
            // finding and is recorded in `_recoverTo`'s own comment; forwarding is best effort on purpose,
            // because a rejecting recipient must not roll back the bond handoff.
            // forge-lint: disable-next-line(arbitrary-send-eth)
            (bool ok,) = recipient.call{value: beforeBalance}("");
            if (ok && beforeBalance > address(this).balance) {
                forwarded = beforeBalance - address(this).balance;
            }
        }
        remaining = address(this).balance;
        emit NativeRecovered(recipient, forwarded, remaining);
    }

    /// @dev A token pause, blacklist, false return or revert must not block bond
    ///      custody. `forwarded` is the adapter's measured balance increase rather
    ///      than the requested amount or the token's return value.
    function _tryTransferUsdc(address recipient, uint256 amount) private returns (uint256 forwarded) {
        uint256 beforeBalance = usdc.balanceOf(recipient);
        // ACCEPTED (audit round 44). The callee is the immutable USDC token, which does not call back.
        // The result is deliberately not trusted; the recipient's balance delta is measured instead.
        // forge-lint: disable-start(reentrancy-no-eth)
        (bool ok,) = address(usdc).call(abi.encodeCall(IERC20.transfer, (recipient, amount)));
        // forge-lint: disable-end(reentrancy-no-eth)
        if (!ok) return 0;

        uint256 afterBalance = usdc.balanceOf(recipient);
        if (afterBalance > beforeBalance) {
            forwarded = afterBalance - beforeBalance;
            if (forwarded > amount) forwarded = amount;
        }
    }
}
