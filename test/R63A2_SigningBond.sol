// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";

import {IDexFiBond} from "../src/interfaces/IDexFiBond.sol";
import {IDexFiFarm} from "../src/interfaces/IDexFiFarm.sol";

/// @notice Audit round 63, seat A2. A SIGNATURE-FAITHFUL stand-in for DexFi's `NFTBondsMigration`
///         (`0x969C6eCF97c256846029cBCBB865824E505E006f` on Base), written from the verified source
///         fetched read-only from Blockscout on 2026-09-21. `MockBond` elides the EIP-712 check;
///         this contract keeps it, so the keeper's signature can be attacked under `forge test`
///         without a fork.
///
/// @dev What is mirrored, line for line in ORDER: the uuid check, the deadline check
///      (`deadline >= block.timestamp`), the EIP-712 digest over `MINT_TYPEHASH` inside the
///      `NFT_BOND` / `1` domain, `ECDSA.recover`, `signer == owner() || signer == keeper`, the zero
///      receiver check, `msg.value >= paymentAmount`, `_useNonce(receiver) == nonce`, the treasury
///      payment BEFORE the mint, `whenNotPaused nonReentrant`, the whitelist gate in `_update`, and
///      every custom error's name and argument list. The live source is `pragma 0.8.26` and spells its checks
///      `require(cond, Error())`; this tree compiles at 0.8.24, so they are `if (!cond) revert Error()`.
///
///      What is NOT mirrored, on purpose, and what it costs: the live contract mints to ITSELF and
///      lets the farm pull the units (`rewardPool.depositForAccount`); `MockFarm` records a stake
///      without pulling, so this stand-in mints straight to the pool the way `MockBond` does. The
///      live contract's `EnumerableSet` whitelist, `paymentDataByUser`, `_buyers`,
///      `ERC1155Burnable`, `mintSingle`, `setMintDataHistory` and `lock` are dropped. The fork suite
///      `R63A2_RealBondFork` runs the same attacks against the real bytecode, which is where any
///      doubt about this port is settled.
contract R63A2_SigningBond is ERC1155Supply, Ownable, EIP712, Nonces, Pausable, ReentrancyGuard {
    uint256 public constant TOKEN_ID = 0;
    string public constant EIP712_DOMAIN_NAME = "NFT_BOND";
    string public constant EIP712_DOMAIN_VERSION = "1";
    bytes32 public constant MINT_TYPEHASH = keccak256(
        "MintDataInput(uint256 uuid,uint256 nonce,address receiver,uint256 amountNfts,uint256 paymentAmount,uint256 deadline)"
    );

    address public keeper;
    address public treasury;
    address public rewardPool;

    mapping(uint256 => bool) public uuidsContains;
    mapping(address => bool) public whitelistContains;

    error ReceiverZero();
    error TransferNativeFailed();
    error UUIDAlreadyExist(uint256 uuid);
    error SignatureTimeExpired(uint256 deadline, uint256 timestamp);
    error AddressesNotWhitelisted(address caller, address from, address to);
    error SentValueLtPaymentAmount(uint256 msgValue, uint256 paymentAmount);
    error MintSignerNotOwnerOrKeeper(address signer, address owner, address keeper);
    error MintIncorrectReceiverNonce(address receiver, uint256 contractNonce, uint256 dataNonce);

    constructor(address keeper_, address treasury_)
        ERC1155("r63a2://bond/{id}")
        Ownable(msg.sender)
        EIP712(EIP712_DOMAIN_NAME, EIP712_DOMAIN_VERSION)
    {
        keeper = keeper_;
        treasury = treasury_;
    }

    function updateKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
    }

    function updateTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
    }

    function updateRewardPool(address pool) external onlyOwner {
        rewardPool = pool;
    }

    function setWhitelisted(address account, bool value) external onlyOwner {
        whitelistContains[account] = value;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function mint(IDexFiBond.MintDataInput memory data) external payable whenNotPaused nonReentrant {
        if (uuidsContains[data.uuid]) revert UUIDAlreadyExist(data.uuid);
        if (data.deadline < block.timestamp) revert SignatureTimeExpired(data.deadline, block.timestamp);
        bytes32 mintDataHash = keccak256(
            abi.encode(
                MINT_TYPEHASH, data.uuid, data.nonce, data.receiver, data.amountNfts, data.paymentAmount, data.deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(mintDataHash), data.signature);
        if (signer != owner() && signer != keeper) revert MintSignerNotOwnerOrKeeper(signer, owner(), keeper);
        if (data.receiver == address(0)) revert ReceiverZero();
        if (msg.value < data.paymentAmount) revert SentValueLtPaymentAmount(msg.value, data.paymentAmount);
        if (_useNonce(data.receiver) != data.nonce) {
            revert MintIncorrectReceiverNonce(data.receiver, nonces(data.receiver) - 1, data.nonce);
        }
        uuidsContains[data.uuid] = true;
        (bool success,) = treasury.call{value: data.paymentAmount}("");
        if (!success) revert TransferNativeFailed();
        if (rewardPool != address(0)) {
            // DIVERGENCE, named in the contract comment: the live bond mints to itself and the farm pulls.
            _mint(rewardPool, TOKEN_ID, data.amountNfts, "");
            IDexFiFarm(rewardPool).depositForAccount(data.receiver, data.amountNfts);
        } else {
            _mint(data.receiver, TOKEN_ID, data.amountNfts, "");
        }
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (from != address(0) && to != address(0)) {
            if (!(whitelistContains[msg.sender] || whitelistContains[from] || whitelistContains[to])) {
                revert AddressesNotWhitelisted(msg.sender, from, to);
            }
        }
        super._update(from, to, ids, values);
    }
}
