// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {IDexFiBond} from "../../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../../src/interfaces/IDexFiFarm.sol";

/// @notice Stand-in for the DexFi Treasury Bond ("NFTBondsMigration"), mirroring the
///         verified contract's shape: ERC-1155, single fungible TOKEN_ID = 0, and a
///         whitelist gate on wallet↔wallet transfers (mint/burn exempt) — the check
///         passes if any of msg.sender / from / to is whitelisted, exactly like the
///         real `_update` override. The signed-mint entrypoint is mirrored minus the
///         EIP-712 check (payment + deadline are enforced; bonds auto-stake for the
///         receiver when a reward pool is set, like the real `mint`).
contract MockBond is ERC1155 {
    uint256 public constant TOKEN_ID = 0;

    mapping(address => bool) public whitelisted;
    address public rewardPool;

    error AddressesNotWhitelisted(address operator, address from, address to);
    error PaymentMismatch(uint256 expected, uint256 actual);
    error DeadlineExpired(uint256 deadline);

    constructor() ERC1155("mock://bond/{id}") {}

    function mint(address to, uint256 amount) external {
        _mint(to, TOKEN_ID, amount, "");
    }

    function setRewardPool(address pool) external {
        rewardPool = pool;
    }

    /// @notice Matches the real signature-gated mint's selector and observable
    ///         behaviour (signature verification elided in the mock).
    function mint(IDexFiBond.MintDataInput memory data) external payable {
        if (msg.value != data.paymentAmount) revert PaymentMismatch(data.paymentAmount, msg.value);
        if (block.timestamp > data.deadline) revert DeadlineExpired(data.deadline);
        if (rewardPool != address(0)) {
            // Real contract: bonds land in the pool, staked for the receiver.
            _mint(rewardPool, TOKEN_ID, data.amountNfts, "");
            IDexFiFarm(rewardPool).depositForAccount(data.receiver, data.amountNfts);
        } else {
            _mint(data.receiver, TOKEN_ID, data.amountNfts, "");
        }
    }

    function setWhitelisted(address account, bool value) external {
        whitelisted[account] = value;
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
