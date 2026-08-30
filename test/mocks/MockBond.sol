// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";

import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";

import {MockLockdown} from "./MockLockdown.sol";

/// @notice Stand-in for the DexFi Treasury Bond ("NFTBondsMigration"), mirroring the
///         verified contract's shape: ERC-1155, single fungible TOKEN_ID = 0, and a
///         whitelist gate on wallet↔wallet transfers (mint/burn exempt) - the check
///         passes if any of msg.sender / from / to is whitelisted, exactly like the
///         real `_update` override. The signed-mint entrypoint is mirrored minus the
///         EIP-712 check: UUIDs are globally single-use, nonces are keyed by receiver,
///         the deadline and minimum payment are enforced, and bonds auto-stake for the
///         receiver when a reward pool is set, like the real `mint`.
contract MockBond is ERC1155Supply, MockLockdown {
    uint256 public constant TOKEN_ID = 0;

    mapping(address => bool) public whitelisted;
    mapping(uint256 => bool) public uuidUsed;
    mapping(address => uint256) public nonces;
    address public rewardPool;
    address public revokeDuringMint;

    /// @notice Test-only stand-in for DexFi's treasury EOA. Keeping the payment leg
    ///         separate from this contract's balance makes the real overpayment trap
    ///         observable: only `paymentAmount` moves onward and any excess stays here.
    address payable public treasury = payable(address(0xBEEF));

    error AddressesNotWhitelisted(address operator, address from, address to);
    error PaymentMismatch(uint256 expected, uint256 actual);
    error DeadlineExpired(uint256 deadline);
    error UUIDAlreadyExist(uint256 uuid);
    error InvalidNonce(address receiver, uint256 expected, uint256 actual);
    error ZeroReceiver();
    error TreasuryTransferFailed();

    constructor() ERC1155("mock://bond/{id}") {}

    function mint(address to, uint256 amount) external {
        _mint(to, TOKEN_ID, amount, "");
    }

    function setRewardPool(address pool) external gated {
        rewardPool = pool;
    }

    function setTreasury(address payable treasury_) external gated {
        treasury = treasury_;
    }

    /// @notice Test hook for a whitelist revocation after the upstream mint has
    ///         changed state but before the adapter can consolidate the position.
    function setRevokeDuringMint(address account) external gated {
        revokeDuringMint = account;
    }

    /// @notice Matches the real signature-gated mint's selector and observable
    ///         behaviour (signature verification elided in the mock).
    function mint(IDexFiBond.MintDataInput memory data) external payable {
        if (uuidUsed[data.uuid]) revert UUIDAlreadyExist(data.uuid);
        if (block.timestamp > data.deadline) revert DeadlineExpired(data.deadline);
        if (data.receiver == address(0)) revert ZeroReceiver();
        // The live contract accepts overpayment but forwards only the signed amount.
        // The adapter's strict equality check, rather than this mock, must be what
        // prevents the excess from becoming permanently stranded.
        if (msg.value < data.paymentAmount) revert PaymentMismatch(data.paymentAmount, msg.value);

        uint256 expectedNonce = nonces[data.receiver];
        if (data.nonce != expectedNonce) {
            revert InvalidNonce(data.receiver, expectedNonce, data.nonce);
        }
        uuidUsed[data.uuid] = true;
        nonces[data.receiver] = expectedNonce + 1;

        if (rewardPool != address(0)) {
            // Real contract: bonds land in the pool, staked for the receiver.
            _mint(rewardPool, TOKEN_ID, data.amountNfts, "");
            IDexFiFarm(rewardPool).depositForAccount(data.receiver, data.amountNfts);
        } else {
            _mint(data.receiver, TOKEN_ID, data.amountNfts, "");
        }

        address revoke = revokeDuringMint;
        if (revoke != address(0)) whitelisted[revoke] = false;

        (bool ok,) = treasury.call{value: data.paymentAmount}("");
        if (!ok) revert TreasuryTransferFailed();
    }

    function setWhitelisted(address account, bool value) external gated {
        whitelisted[account] = value;
    }

    /// @notice Exact live-contract getter selector used by the adapter preflight.
    function whitelistContains(address account) external view returns (bool) {
        return whitelisted[account];
    }

    function bondBalance(address account) external view returns (uint256) {
        return balanceOf(account, TOKEN_ID);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        if (from != address(0) && to != address(0)) {
            if (!(whitelisted[msg.sender] || whitelisted[from] || whitelisted[to])) {
                revert AddressesNotWhitelisted(msg.sender, from, to);
            }
        }
        super._update(from, to, ids, values);
    }
}
