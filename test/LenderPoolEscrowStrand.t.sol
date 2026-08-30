// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

interface ICanonicalEscrowAccounting {
    function depositCapUsage() external view returns (uint256);
}

/// @notice The pool is the withdrawal escrow, never an ordinary holder or payout receiver.
/// @dev These are behavioral safety tests. Accounting assertions use canonical cap usage and
///      exact escrowed shares, with no dependency on the retired positional ledger.
contract LenderPoolEscrowStrandTest is Test {
    MockUSDC internal usdc;
    LenderPool internal pool;

    address internal admin = makeAddr("admin");
    address internal creditManager = makeAddr("creditManager");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), admin);

        vm.startPrank(admin);
        pool.setCreditManager(creditManager);
        pool.setEpochHarvester(harvester);
        vm.stopPrank();

        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 100_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function _usage() private view returns (uint256) {
        return ICanonicalEscrowAccounting(address(pool)).depositCapUsage();
    }

    function _seedAlice() private {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);
    }

    function _assertEmptyEscrow() private view {
        assertEq(pool.balanceOf(address(pool)), 0, "escrow holds shares without a request");
        assertEq(pool.queuedShares(), 0, "queue records shares that escrow does not hold");
    }

    function _assertEscrowBacked() private view {
        assertEq(pool.balanceOf(address(pool)), pool.queuedShares(), "escrow and queue shares diverged");
    }

    function test_F16_theTransferDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.transfer(address(pool), 25);

        _assertEmptyEscrow();
    }

    function test_F16_theTransferFromDoorIsShut() public {
        _seedAlice();
        vm.prank(alice);
        pool.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.transferFrom(alice, address(pool), 25);

        _assertEmptyEscrow();
    }

    function test_F16_theDepositDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.deposit(1_000e6, address(pool));

        _assertEmptyEscrow();
    }

    function test_F16_theMintDoorIsShut() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.mint(1_000e9, address(pool));

        _assertEmptyEscrow();
    }

    function test_F16_aRefusedDoorMovesNeitherUsageNorHeadroom() public {
        _seedAlice();
        uint256 usageBefore = _usage();
        uint256 roomBefore = pool.maxDeposit(alice);
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.deposit(1_000e6, address(pool));

        assertEq(_usage(), usageBefore, "cap usage moved on a refused call");
        assertEq(pool.maxDeposit(alice), roomBefore, "headroom moved on a refused call");
        assertEq(pool.totalSupply(), supplyBefore, "supply moved on a refused call");
    }

    function test_F16_theQueueStillServicesThroughTheShutDoor() public {
        _seedAlice();
        vm.prank(bob);
        pool.deposit(10_000e6, bob);

        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.requestWithdrawal(bobShares, bob);

        assertEq(pool.queuedShares(), bobShares, "escrow did not take the requested shares");
        _assertEscrowBacked();

        uint256 serviceable = pool.maxRequestRedeem(bob);
        vm.prank(bob);
        pool.serviceWithdrawalRequest(bob, serviceable, 0);
        uint256 owed = pool.claimable(bob);
        assertGt(owed, 0, "the request serviced nothing");

        vm.prank(bob);
        assertEq(pool.claim(), owed, "claim paid something other than the recorded debt");
        _assertEmptyEscrow();
    }

    function test_F16_cancelStillReturnsTheSharesThroughTheShutDoor() public {
        _seedAlice();
        uint256 aliceShares = pool.balanceOf(alice);

        vm.prank(alice);
        pool.requestWithdrawal(aliceShares, alice);
        _assertEscrowBacked();

        vm.prank(alice);
        pool.cancelWithdrawalRequest();

        assertEq(pool.balanceOf(alice), aliceShares, "cancel did not return the shares");
        _assertEmptyEscrow();
    }

    function test_F16_everyOtherDestinationStillWorks() public {
        _seedAlice();

        vm.prank(alice);
        pool.transfer(bob, 1_000);
        assertEq(pool.balanceOf(bob), 1_000, "actor transfer refused");

        vm.prank(alice);
        pool.deposit(1_000e6, carol);
        assertGt(pool.balanceOf(carol), 0, "third-party deposit refused");

        vm.prank(alice);
        pool.transfer(creditManager, 1_000);
        assertEq(pool.balanceOf(creditManager), 1_000, "manager transfer refused");
    }

    function test_F16_aHoldersSelfTransferIsNotThisDoor() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        vm.prank(alice);
        pool.transfer(alice, held);

        assertEq(pool.balanceOf(alice), held, "self transfer lost shares");
    }

    function test_F16_theBoundedDepositDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.deposit(1_000e6, address(pool), 0);

        _assertEmptyEscrow();
    }

    function test_F16_theBoundedMintDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.mint(1_000e9, address(pool), type(uint256).max);

        _assertEmptyEscrow();
    }

    function test_A24_theWithdrawalReceiverDoorIsShut() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.requestWithdrawal(held, address(pool));

        (uint256 requestId,, uint256 requestShares,,) = pool.withdrawalRequest(alice);
        assertEq(requestId, 0, "a refused request received an id");
        assertEq(requestShares, 0, "a refused request recorded shares");
        assertEq(pool.claimable(address(pool)), 0, "escrow became its own payee");
        _assertEmptyEscrow();
    }

    function test_A24_theEscrowCannotBeMadeItsOwnPayee() public {
        vm.prank(alice);
        pool.deposit(6_000e6, alice);

        uint256 priceAtPar = pool.convertToAssets(1e9);
        uint256 held = pool.balanceOf(alice);
        vm.prank(alice);
        try pool.requestWithdrawal(held, address(pool)) {} catch {}

        uint256 serviceable = pool.maxRequestRedeem(alice);
        if (serviceable != 0) {
            vm.prank(alice);
            try pool.serviceWithdrawalRequest(alice, serviceable, 0) {} catch {}
        }

        assertEq(pool.claimable(address(pool)), 0, "queue set money aside for escrow");
        assertEq(pool.totalClaimable(), 0, "pool booked its own cash as a claim");
        vm.expectRevert(LenderPool.NothingToClaim.selector);
        pool.claimFor(address(pool));

        vm.prank(bob);
        pool.deposit(6_000e6, bob);
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        uint256 out = pool.redeem(bobShares, bob, bob);

        assertEq(pool.convertToAssets(1e9), priceAtPar, "share price stepped inside one block");
        assertLe(out, 6_000e6, "unexposed entrant extracted the strand");
    }

    function test_A24_aRequestNamingAnyOtherReceiverStillWorks() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        vm.prank(alice);
        pool.requestWithdrawal(held, carol);
        _assertEscrowBacked();

        uint256 serviceable = pool.maxRequestRedeem(alice);
        vm.prank(alice);
        pool.serviceWithdrawalRequest(alice, serviceable, 0);
        uint256 owed = pool.claimable(carol);
        assertGt(owed, 0, "named receiver was owed nothing");
        assertEq(pool.claimable(alice), 0, "owner replaced the named receiver");

        vm.prank(carol);
        assertEq(pool.claim(), owed, "named receiver could not collect");
    }

    function test_A25F1_theWithdrawDoorIsShut() public {
        _seedAlice();
        uint256 usageBefore = _usage();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.withdraw(1_000e6, address(pool), alice);

        assertEq(_usage(), usageBefore, "refused exit reduced cap usage");
        _assertEmptyEscrow();
    }

    function test_A25F1_theRedeemDoorIsShut() public {
        _seedAlice();
        uint256 usageBefore = _usage();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.redeem(1_000e9, address(pool), alice);

        assertEq(_usage(), usageBefore, "refused exit reduced cap usage");
        _assertEmptyEscrow();
    }

    function test_A25F1_theBoundedWithdrawDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.withdraw(1_000e6, address(pool), alice, type(uint256).max);

        _assertEmptyEscrow();
    }

    function test_A25F1_theBoundedRedeemDoorIsShutByDelegation() public {
        _seedAlice();

        vm.prank(alice);
        vm.expectRevert(LenderPool.EscrowIsNotAHolder.selector);
        pool.redeem(1_000e9, address(pool), alice, 0);

        _assertEmptyEscrow();
    }

    function test_A25F1_anExitToEscrowCannotBurnSharesWithoutPaying() public {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);
        vm.prank(bob);
        pool.deposit(10_000e6, bob);

        uint256 priceBefore = pool.convertToAssets(1e9);
        uint256 cashBefore = usdc.balanceOf(address(pool));
        uint256 aliceCashBefore = usdc.balanceOf(alice);
        uint256 supplyBefore = pool.totalSupply();
        uint256 held = pool.balanceOf(alice);

        vm.prank(alice);
        try pool.redeem(held, address(pool), alice) {} catch {}

        assertEq(usdc.balanceOf(address(pool)), cashBefore, "refused exit moved pool cash");
        assertEq(usdc.balanceOf(alice), aliceCashBefore, "refused exit paid the caller");
        assertEq(pool.totalSupply(), supplyBefore, "supply shrank without a payout");
        assertEq(pool.balanceOf(alice), held, "stake burned for nothing");
        assertEq(pool.convertToAssets(1e9), priceBefore, "share price stepped inside one call");
    }

    function test_A25F1_theStrictBoundCannotApproveAnUndeliveredExit() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);
        uint256 quote = pool.previewRedeem(held);
        uint256 cashBefore = usdc.balanceOf(address(pool));

        uint256 reported;
        vm.prank(alice);
        try pool.redeem(held, address(pool), alice, quote) returns (uint256 assets) {
            reported = assets;
        } catch {}

        uint256 delivered = cashBefore - usdc.balanceOf(address(pool));
        assertEq(reported, delivered, "bound passed on an undelivered redemption");
    }

    function test_A25F1_anExitToEscrowDoesNotWidenTheDepositCap() public {
        _seedAlice();
        uint256 cap = pool.depositCap();
        uint256 usageBefore = _usage();

        uint256 held = pool.balanceOf(alice);
        vm.prank(alice);
        try pool.redeem(held, address(pool), alice) {} catch {}

        assertEq(_usage(), usageBefore, "cap usage fell without an accounted payout");
        assertEq(pool.maxDeposit(bob), cap - usageBefore, "headroom widened without a payout");

        uint256 room = pool.maxDeposit(bob);
        vm.prank(bob);
        pool.deposit(room, bob);
        assertEq(_usage(), cap, "reported headroom did not fill the cap");
    }

    function test_A25F1_theDoorTableRefusesTwelveAndAcceptsNone() public {
        _seedAlice();
        vm.prank(alice);
        pool.approve(bob, type(uint256).max);

        uint256 refused;
        uint256 accepted;
        uint256 refusedByGuard;
        uint256 refusedByConstruction;

        for (uint256 door = 0; door < 12; door++) {
            uint256 snapshot = vm.snapshotState();
            (bool doorAccepted, bytes4 selector) = _offerTheEscrowToDoor(door);
            vm.revertToState(snapshot);

            if (doorAccepted) {
                ++accepted;
                emit log_named_uint("door accepted escrow", door);
            } else {
                ++refused;
                if (selector == LenderPool.EscrowIsNotAHolder.selector) {
                    ++refusedByGuard;
                } else {
                    assertEq(selector, LenderPool.NothingToClaim.selector, "unrelated refusal");
                    ++refusedByConstruction;
                }
            }
        }

        assertEq(accepted, 0, "a door accepted escrow as receiver");
        assertEq(refused, 12, "door table lost a door");
        assertEq(refusedByGuard, 11, "guard coverage changed");
        assertEq(refusedByConstruction, 1, "pot-keyed row changed");
    }

    function _offerTheEscrowToDoor(uint256 door) private returns (bool, bytes4) {
        if (door == 0) {
            vm.prank(alice);
            try pool.transfer(address(pool), 25) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 1) {
            vm.prank(bob);
            try pool.transferFrom(alice, address(pool), 25) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 2) {
            vm.prank(alice);
            try pool.deposit(1_000e6, address(pool)) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 3) {
            vm.prank(alice);
            try pool.mint(1_000e9, address(pool)) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 4) {
            vm.prank(alice);
            try pool.deposit(1_000e6, address(pool), 0) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 5) {
            vm.prank(alice);
            try pool.mint(1_000e9, address(pool), type(uint256).max) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 6) {
            vm.prank(alice);
            try pool.requestWithdrawal(1_000e9, address(pool)) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 7) {
            vm.prank(alice);
            try pool.withdraw(1_000e6, address(pool), alice) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 8) {
            vm.prank(alice);
            try pool.redeem(1_000e9, address(pool), alice) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 9) {
            vm.prank(alice);
            try pool.withdraw(1_000e6, address(pool), alice, type(uint256).max) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else if (door == 10) {
            vm.prank(alice);
            try pool.redeem(1_000e9, address(pool), alice, 0) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        } else {
            vm.prank(carol);
            try pool.claimFor(address(pool)) {
                return (true, bytes4(0));
            } catch (bytes memory error) {
                return (false, bytes4(error));
            }
        }
    }

    function test_A25F1_anExitNamingAnyOtherReceiverStillWorks() public {
        _seedAlice();
        uint256 held = pool.balanceOf(alice);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(alice);
        uint256 paid = pool.redeem(held / 2, carol, alice);
        assertGt(paid, 0, "third-party receiver was paid nothing");
        assertEq(usdc.balanceOf(carol) - carolBefore, paid, "payout missed named receiver");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        pool.withdraw(100e6, bob, alice);
        assertEq(usdc.balanceOf(bob) - bobBefore, 100e6, "withdraw missed named receiver");

        vm.prank(alice);
        pool.redeem(1e9, carol, alice, 0);
        vm.prank(alice);
        pool.withdraw(1e6, bob, alice, type(uint256).max);
    }
}
