// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Config} from "../../src/Config.sol";

struct UserDebtInfoInput {
    address user;
    uint256 debt;
}

interface IFarmRaw {
    function isHandler(address) external view returns (bool);
    function owner() external view returns (address);
    function deposit(uint256) external;
    function depositForAccount(address, uint256) external;
    function depositForAccounts(address[] memory, uint256[] memory) external;
    function withdraw(uint256) external;
    function pendingShare(address) external view returns (uint256);
    function userInfo(address) external view returns (uint256, uint256);
    function setHandler(address, bool) external;
    function setUsersDebt(UserDebtInfoInput[] memory) external;
    function userDebt(address) external view returns (uint256);
}

interface IBondRaw {
    function mintSingle(address, uint256, bytes memory) external;
    function nonces(address) external view returns (uint256);
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function locked() external view returns (bool);
    function whitelistContains(address) external view returns (bool);
    function safeTransferFrom(address, address, uint256, uint256, bytes memory) external;
    function balanceOf(address, uint256) external view returns (uint256);
}

/// @notice A6 / round 34. Establishes, on LIVE Base mainnet state, the access control on the
///         DexFi reward pool's deposit-on-behalf entry point and the bond's free-mint entry point.
///         Run with: RUN_FORK_TESTS=true BASE_RPC_URL=<rpc> forge test --mc A6Farm -vv
contract A6FarmAccessControlForkTest is Test {
    IFarmRaw internal farm = IFarmRaw(Config.DEXFI_FARM);
    IBondRaw internal bond = IBondRaw(Config.DEXFI_BOND_NFT);

    address internal constant TREASURY = 0xd4ec4E5b7625Fed3c40Bfeec206E49396F02Dd54;
    address internal constant AFFILIATE = 0x8a7B37D8db3B0530c1277c7Db0CF99D66d8ea51D;
    address internal constant EOA_7702 = 0x6668A6c1309075eB513b6C555BE95E8679d875b9;
    address internal constant REVOKED = 0x0a6767bFD8025BD4de695a5623C2Ac5FFC4B48b5;

    address internal stranger = makeAddr("stranger-with-no-dexfi-key");
    address internal counterfactualReceiver = makeAddr("counterfactual-mint-attempt-receiver");

    bool internal run;

    function setUp() public {
        run = vm.envOr("RUN_FORK_TESTS", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
    }

    /// @dev THE question: can a keyless stranger credit an arbitrary account with a farm stake?
    function test_depositForAccount_isNotPermissionless() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("CallerNotHandler(address)", stranger));
        farm.depositForAccount(counterfactualReceiver, 1);
    }

    function test_depositForAccounts_isNotPermissionless() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        address[] memory a = new address[](1);
        uint256[] memory n = new uint256[](1);
        a[0] = counterfactualReceiver;
        n[0] = 1;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("CallerNotHandler(address)", stranger));
        farm.depositForAccounts(a, n);
    }

    /// @dev The handler set, read live. Every member is DexFi-key-controlled.
    function test_handlerSet_isDexFiControlledOnly() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        assertTrue(farm.isHandler(Config.DEXFI_BOND_NFT), "bond is a handler");
        assertTrue(farm.isHandler(TREASURY), "treasury EOA is a handler");
        assertTrue(farm.isHandler(AFFILIATE), "Affiliate proxy is a handler");
        assertTrue(farm.isHandler(EOA_7702), "7702 EOA is a handler");
        assertFalse(farm.isHandler(REVOKED), "revoked handler");
        assertFalse(farm.isHandler(stranger), "stranger is not a handler");
        assertEq(farm.owner(), TREASURY, "farm owner");
    }

    function test_setHandler_isOwnerOnly() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        farm.setHandler(stranger, true);
    }

    /// @dev `deposit` credits msg.sender only, so it cannot seed a counterfactual address.
    function test_deposit_creditsOnlyMsgSender() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        (uint256 before,) = farm.userInfo(counterfactualReceiver);
        assertEq(before, 0, "receiver starts unstaked");
        vm.prank(stranger);
        vm.expectRevert();
        farm.deposit(1);
        (uint256 stillZero,) = farm.userInfo(counterfactualReceiver);
        assertEq(stillZero, 0, "no path from deposit() to another account");
    }

    /// @dev Even a handler must own the bonds: `_deposit` pulls from msg.sender, not `account`.
    function test_handlerStillNeedsItsOwnBonds() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        uint256 bal = bond.balanceOf(TREASURY, Config.DEXFI_BOND_TOKEN_ID);
        emit log_named_uint("treasury loose bond balance", bal);
        if (bal != 0) return; // fixture-dependent; the point only holds while it holds nothing
        vm.prank(TREASURY);
        vm.expectRevert();
        farm.depositForAccount(counterfactualReceiver, 1);
    }

    /// @dev withdraw and pendingShare: msg.sender-scoped and an open view respectively.
    function test_withdraw_isSelfScoped_and_pendingShare_isOpenView() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("InsufficientAvailableAmount(uint256,uint256)", 1, 0));
        farm.withdraw(1);
        vm.prank(stranger);
        farm.withdraw(0); // the permissionless claim primitive, self-scoped
        assertEq(farm.pendingShare(stranger), 0, "stranger has no pending");
    }

    /// @dev The free-mint arm needs DexFi's owner key, confirmed live.
    function test_mintSingle_isOwnerOnly() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        bond.mintSingle(counterfactualReceiver, 1, "");
    }

    /// @dev mintSingle does NOT bump nonces, so it is the one path that seeds a counterfactual
    ///      receiver with bonds while leaving our mint preflight passable - but only from the
    ///      owner key, and the bonds land UNSTAKED, so there is no farm reward to sweep.
    function test_mintSingle_fromOwner_doesNotBumpNonce_andDoesNotStake() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        assertEq(bond.nonces(counterfactualReceiver), 0, "fresh receiver");
        vm.prank(bond.owner());
        bond.mintSingle(counterfactualReceiver, 1, "");
        assertEq(bond.nonces(counterfactualReceiver), 0, "mintSingle leaves the nonce at zero");
        assertEq(bond.balanceOf(counterfactualReceiver, Config.DEXFI_BOND_TOKEN_ID), 1, "bond delivered");
        (uint256 staked,) = farm.userInfo(counterfactualReceiver);
        assertEq(staked, 0, "NOT staked: no farm position, no pending reward");
        assertEq(farm.pendingShare(counterfactualReceiver), 0, "and nothing pending");
    }

    /// @dev A keyless stranger cannot hand bonds to a counterfactual address either: the bond's
    ///      whitelist gate rejects a transfer where neither party nor the caller is whitelisted.
    function test_strangerCannotTransferBondsToACounterfactualAddress() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        assertFalse(bond.whitelistContains(stranger), "stranger not whitelisted");
        assertFalse(bond.whitelistContains(counterfactualReceiver), "receiver not whitelisted");
        vm.prank(bond.owner());
        bond.mintSingle(stranger, 1, "");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AddressesNotWhitelisted(address,address,address)", stranger, stranger, counterfactualReceiver
            )
        );
        bond.safeTransferFrom(stranger, counterfactualReceiver, Config.DEXFI_BOND_TOKEN_ID, 1, "");
    }

    /// @dev The bond's owner-only nonce backfill is permanently locked, so DexFi cannot
    ///      invalidate a live attempt receiver either.
    function test_setMintDataHistory_isPermanentlyLocked() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        assertTrue(bond.locked(), "nonce backfill is locked one-way");
    }

    /// @dev NEUTER for test_depositForAccount_isNotPermissionless: grant the stranger the
    ///      handler flag and the SAME call must now get PAST onlyHandler and fail later, on the
    ///      ERC-1155 pull from msg.sender. If the guard were not the thing being measured, this
    ///      would still revert CallerNotHandler and the positive test would be worthless.
    function test_NEUTER_grantingHandlerLetsTheSameCallPastTheGuard() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        vm.prank(farm.owner());
        farm.setHandler(stranger, true);
        assertTrue(farm.isHandler(stranger), "neuter applied");

        vm.prank(stranger);
        // Past the guard: now it fails on the ERC-1155 pull from msg.sender, not CallerNotHandler.
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC1155MissingApprovalForAll(address,address)", Config.DEXFI_FARM, stranger
            )
        );
        farm.depositForAccount(counterfactualReceiver, 1);
    }

    /// @notice INCIDENTAL, and a real-vs-model divergence our mocks cannot express at all:
    ///         the live farm has a THIRD reward component, owner-writable "userDebt", which
    ///         pendingShare ADDS in but which withdraw only pays inside its
    ///         "if (_pending > 0)" branch. For an account with no live accrual - exactly the
    ///         shape of a fresh MintAttemptReceiver clone - pendingShare therefore reports a
    ///         balance that withdraw pays NOTHING against, and never clears.
    ///
    ///         Consequence for us: DexFi's owner can make farm.pendingShare(receiver) non-zero
    ///         for ANY counterfactual attempt receiver without touching bond.nonces(receiver),
    ///         which is the predicate DirectCallAdapter._prepareRecovery trusts to mean "there
    ///         is something here". MockFarm models no userDebt, so nothing in the tree sees it.
    function test_A6_pendingShareOverReports_andWithdrawPaysNothing() public {
        if (!run) {
            vm.skip(true);
            return;
        }
        address phantom = makeAddr("counterfactual-clone-with-planted-userDebt");
        (uint256 staked,) = farm.userInfo(phantom);
        assertEq(staked, 0, "no stake");
        assertEq(farm.pendingShare(phantom), 0, "nothing pending to start");

        UserDebtInfoInput[] memory d = new UserDebtInfoInput[](1);
        d[0] = UserDebtInfoInput({user: phantom, debt: 100e6});
        vm.prank(farm.owner());
        farm.setUsersDebt(d);

        assertEq(farm.userDebt(phantom), 100e6, "planted");
        assertEq(farm.pendingShare(phantom), 100e6, "pendingShare REPORTS it");

        uint256 balBefore = IERC20Raw(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(phantom);
        vm.prank(phantom);
        farm.withdraw(0); // the claim primitive our harvester and clones use
        uint256 balAfter = IERC20Raw(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(phantom);

        assertEq(balAfter - balBefore, 0, "withdraw pays NOTHING against it");
        assertEq(farm.userDebt(phantom), 100e6, "and does not clear it either - it is permanent");
        assertEq(farm.pendingShare(phantom), 100e6, "so pendingShare stays non-zero forever");
    }
}

interface IERC20Raw {
    function balanceOf(address) external view returns (uint256);
}
