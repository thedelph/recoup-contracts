// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Config} from "../src/Config.sol";
import {LenderPool} from "../src/LenderPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {R63A3_PoolDoorsHandler} from "./R63A3_PoolDoorsHandler.sol";

/// @title #64: the census replay. Every floor kept on share dust, classified by what loss stood.
/// @notice Written first (internal review round 64) to classify the kept-floor frames an earlier
///         census had counted "before any raw loss". The assertions marked `B-flipped` are the #64
///         fix: no floor is kept on dust while no raw loss has landed, on the replay and on the
///         mark walk, and none at all on the no-loss walk. A floor kept AFTER a raw loss is the
///         disclosed residual of the fix (a dust service made while the floors exceed the
///         executable cash keeps its floor), so it is counted and printed, not asserted zero.
///         A3's census walk (40 walks of 400 calls from the NAMED seed chain
///         keccak256(abi.encode("R63A3 census walk", walk))) is replayed here call for call against
///         `R63A3_PoolDoorsHandler`, and every kept-floor-on-dust frame is classified from OUTSIDE the
///         handler by two facts the pool itself publishes: `lifetimeSocialisedLoss` and the
///         handler's `rawLossesDone`. "Before any raw loss" turns out to mean "after a SOCIALISED
///         loss", every time: A3's handler has no action that lowers the exit price without a
///         loss. The second walk adds the one protocol path that does, an impairment MARK and its
///         release (what a routine auction writes and clears), and counts the frames that keep a
///         floor with NO loss of either kind in the walk.
/// @dev Seeded on purpose and said so: a census, not a search. The walk is a plain test and not an
///      invariant campaign, so there is no handler of this suite's own and no frame to drop; the
///      replay asserts A3's own frame count instead.
contract Issue64_DustCensusReplay is Test {
    uint256 internal constant LENDERS = 4;
    uint256 internal constant REPLAY = 0;
    uint256 internal constant WITH_MARK = 1;
    uint256 internal constant MARK_INSTEAD_OF_LOSSES = 2;

    MockUSDC internal usdc;
    LenderPool internal pool;
    R63A3_PoolDoorsHandler internal handler;
    address internal marked = makeAddr("r64a4-marked-borrower");

    struct Tally {
        uint256 frames;
        uint256 kept; // kept-floor-on-dust frames (A3's predicate, re-evaluated here)
        uint256 keptNoRaw; // ... with no raw loss yet in the walk
        uint256 keptNoRawNoSocialised; // ... and no socialised loss either
        uint256 births; // frames where a kept floor APPEARS on a lender who had none the frame before
        uint256 birthsNoRaw;
        uint256 birthsNoLossOfAnyKind;
        uint256 birthsUnderAMark; // the mark standing at the birth
        uint256 largestNoLossKept;
        uint256 marks;
        uint256 releases;
    }

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LenderPool(IERC20(address(usdc)), address(this));
        handler = new R63A3_PoolDoorsHandler(pool, usdc);
        pool.setCreditManager(address(handler));
        pool.setEpochHarvester(address(handler));
        pool.setDepositCap(Config.GLOBAL_BORROW_CAP_MAX);
    }

    function _keptOf(address who) internal view returns (uint256) {
        uint256 shares = handler.requestSharesOf(who);
        if (shares == 0 || shares > 1_000) return 0;
        uint256 floor = handler.floorOf(who);
        return floor >= 1e6 ? floor : 0;
    }

    function _observe(Tally memory t, uint256[LENDERS] memory before) internal view {
        ++t.frames;
        if (pool.cashDeficit() != 0) return; // A3's observer skips an unreconciled instant too
        bool noRaw = handler.rawLossesDone() == 0;
        bool noSocialised = pool.lifetimeSocialisedLoss() == 0;
        uint256 kept;
        for (uint256 i; i < LENDERS; ++i) {
            uint256 mine = _keptOf(handler.lenders(i));
            if (mine > kept) kept = mine;
            if (mine != 0 && before[i] == 0) {
                ++t.births;
                if (noRaw) ++t.birthsNoRaw;
                if (noRaw && noSocialised) ++t.birthsNoLossOfAnyKind;
                if (pool.exitReserve() != 0) ++t.birthsUnderAMark;
            }
            before[i] = mine;
        }
        if (kept == 0) return;
        ++t.kept;
        if (noRaw) ++t.keptNoRaw;
        if (noRaw && noSocialised) {
            ++t.keptNoRawNoSocialised;
            if (kept > t.largestNoLossKept) t.largestNoLossKept = kept;
        }
    }

    /// @dev A3's dispatch, byte for byte in its arms. `WITH_MARK` widens the modulus by two;
    ///      `MARK_INSTEAD_OF_LOSSES` sends A3's two loss arms (10 socialise, 11 raw loss) to the mark
    ///      and its release, so that walk contains NO loss of any kind by construction.
    function _dispatch(uint256 r, uint256 mode, Tally memory t) internal {
        uint256 action = r % (mode == WITH_MARK ? 16 : 14);
        if (mode == MARK_INSTEAD_OF_LOSSES && action == 10) action = 14;
        if (mode == MARK_INSTEAD_OF_LOSSES && action == 11) action = 15;
        uint256 x = r >> 8;
        uint256 y = uint256(keccak256(abi.encode(r)));
        if (action == 0) handler.deposit(x, y);
        else if (action == 1) handler.request(x, y);
        else if (action == 2) handler.cancel(x);
        else if (action == 3) handler.serviceMax(x);
        else if (action == 4) handler.serviceAllButOneShareWei(x);
        else if (action == 5) handler.redeemMax(x);
        else if (action == 6) handler.claim(x);
        else if (action == 7) handler.lend(x);
        else if (action == 8) handler.repay(x, y);
        else if (action == 9) handler.deliverEpoch(y);
        else if (action == 10) handler.socialise(x);
        else if (action == 11) handler.rawLoss(x, y);
        else if (action == 12) handler.passTime(uint32(y));
        else if (action == 13) handler.strangerDust(x);
        else if (action == 14) _mark(x, t);
        else _release(t);
    }

    /// @dev What `CreditManager._setImpairment` writes when an auction opens: the WHOLE debt of one
    ///      borrower. Here a loan of 1% to 50% of the principal out, from the manager's seat.
    function _mark(uint256 x, Tally memory t) internal {
        uint256 principal = pool.outstandingPrincipal();
        if (principal == 0) return;
        uint256 amount = principal * (100 + x % 4_901) / 10_000;
        vm.prank(address(handler));
        if (pool.impair(marked, amount)) ++t.marks;
    }

    function _release(Tally memory t) internal {
        vm.prank(address(handler));
        if (pool.releaseImpairment(marked)) ++t.releases;
    }

    function _walks(uint256 from, uint256 to, uint256 mode) internal returns (Tally memory t) {
        uint256 clean = vm.snapshotState();
        for (uint256 walk = from; walk < to; ++walk) {
            vm.revertToState(clean);
            uint256[LENDERS] memory before;
            bytes32 seed = keccak256(abi.encode("R63A3 census walk", walk));
            for (uint256 step; step < 400; ++step) {
                seed = keccak256(abi.encode(seed));
                _dispatch(uint256(seed), mode, t);
                _observe(t, before);
            }
            if (mode == MARK_INSTEAD_OF_LOSSES) {
                assertEq(pool.lifetimeSocialisedLoss(), 0, "a loss was socialised on the no-loss walk");
                assertEq(handler.rawLossesDone(), 0, "a raw loss landed on the no-loss walk");
                assertEq(pool.lifetimeLossRecovered(), 0, "a recovery landed on the no-loss walk");
            }
            if (mode == REPLAY) {
                // The replay is A3's walk or it is nothing: its own frame ghost must agree.
                assertEq(handler.frames(), 400, "the replay dropped a handler frame");
            }
        }
    }

    function _print(string memory label, Tally memory t) internal pure {
        console2.log(label);
        console2.log("MEASURED   frames / kept-floor frames / before any raw loss ", t.frames, t.kept, t.keptNoRaw);
        console2.log("MEASURED   ... of those, with NO socialised loss either      ", t.keptNoRawNoSocialised);
        console2.log(
            "MEASURED   births / before any raw loss / with no loss at all",
            t.births,
            t.birthsNoRaw,
            t.birthsNoLossOfAnyKind
        );
        console2.log(
            "MEASURED   births under a standing mark / marks / releases   ", t.birthsUnderAMark, t.marks, t.releases
        );
        console2.log("MEASURED   largest floor kept with no loss of any kind       ", t.largestNoLossKept);
    }

    // A3's walk, replayed: ten tests of four walks each (ten walks plus this observer run out of
    // the test gas limit: `OutOfGas` measured in run02).

    function _replay(uint256 from, uint256 to) internal returns (Tally memory t) {
        t = _walks(from, to, REPLAY);
        _print("REPLAY of A3's census walk, no mark action", t);
        assertEq(t.frames, (to - from) * 400, "a walk dropped a frame");
        // What "before any raw loss" was: never a frame with no loss at all.
        assertEq(
            t.keptNoRawNoSocialised,
            0,
            "A3's walk kept a floor with NO loss of any kind: a route this census did not find"
        );
        assertEq(t.birthsNoLossOfAnyKind, 0, "A3's walk bore a kept floor with NO loss of any kind");
        assertEq(t.keptNoRaw, 0, "B-flipped: a floor was kept on dust before any raw loss");
    }

    function test_R64A4_replay_A3sWalk_00to03() public {
        _replay(0, 4);
    }

    function test_R64A4_replay_A3sWalk_04to07() public {
        _replay(4, 8);
    }

    function test_R64A4_replay_A3sWalk_08to11() public {
        _replay(8, 12);
    }

    function test_R64A4_replay_A3sWalk_12to15() public {
        _replay(12, 16);
    }

    function test_R64A4_replay_A3sWalk_16to19() public {
        _replay(16, 20);
    }

    function test_R64A4_replay_A3sWalk_20to23() public {
        _replay(20, 24);
    }

    function test_R64A4_replay_A3sWalk_24to27() public {
        _replay(24, 28);
    }

    function test_R64A4_replay_A3sWalk_28to31() public {
        _replay(28, 32);
    }

    function test_R64A4_replay_A3sWalk_32to35() public {
        _replay(32, 36);
    }

    function test_R64A4_replay_A3sWalk_36to39() public {
        _replay(36, 40);
    }

    // The same seed chain with the mark and its release added as two more arms.

    function _withMark(uint256 from, uint256 to) internal returns (Tally memory t) {
        t = _walks(from, to, WITH_MARK);
        _print("WALK with an impairment mark and its release as actions 14 and 15", t);
        assertEq(t.frames, (to - from) * 400, "a walk dropped a frame");
        assertEq(t.keptNoRaw, 0, "B-flipped: the mark walk kept a floor on dust before any raw loss");
    }

    function test_R64A4_walkWithAMark_00to03() public {
        _withMark(0, 4);
    }

    function test_R64A4_walkWithAMark_04to07() public {
        _withMark(4, 8);
    }

    function test_R64A4_walkWithAMark_08to11() public {
        _withMark(8, 12);
    }

    function test_R64A4_walkWithAMark_12to15() public {
        _withMark(12, 16);
    }

    function test_R64A4_walkWithAMark_16to19() public {
        _withMark(16, 20);
    }

    function test_R64A4_walkWithAMark_20to23() public {
        _withMark(20, 24);
    }

    function test_R64A4_walkWithAMark_24to27() public {
        _withMark(24, 28);
    }

    function test_R64A4_walkWithAMark_28to31() public {
        _withMark(28, 32);
    }

    function test_R64A4_walkWithAMark_32to35() public {
        _withMark(32, 36);
    }

    function test_R64A4_walkWithAMark_36to39() public {
        _withMark(36, 40);
    }

    // A3's seed chain with its two LOSS arms replaced by the mark and its release: no loss of any
    // kind can land, and every kept floor below was born under a mark.

    function _noLoss(uint256 from, uint256 to) internal returns (Tally memory t) {
        t = _walks(from, to, MARK_INSTEAD_OF_LOSSES);
        _print("NOLOSS walk: the mark and its release INSTEAD of the two loss arms", t);
        assertEq(t.frames, (to - from) * 400, "a walk dropped a frame");
        assertEq(t.kept, t.keptNoRawNoSocialised, "a kept-floor frame on the no-loss walk was classified as lossy");
        assertEq(t.kept, 0, "B-flipped: the no-loss walk kept a floor on dust");
    }

    function test_R64A4_noLossWalk_00to03() public {
        _noLoss(0, 4);
    }

    function test_R64A4_noLossWalk_04to07() public {
        _noLoss(4, 8);
    }

    function test_R64A4_noLossWalk_08to11() public {
        _noLoss(8, 12);
    }

    function test_R64A4_noLossWalk_12to15() public {
        _noLoss(12, 16);
    }

    function test_R64A4_noLossWalk_16to19() public {
        _noLoss(16, 20);
    }

    function test_R64A4_noLossWalk_20to23() public {
        _noLoss(20, 24);
    }

    function test_R64A4_noLossWalk_24to27() public {
        _noLoss(24, 28);
    }

    function test_R64A4_noLossWalk_28to31() public {
        _noLoss(28, 32);
    }

    function test_R64A4_noLossWalk_32to35() public {
        _noLoss(32, 36);
    }

    function test_R64A4_noLossWalk_36to39() public {
        _noLoss(36, 40);
    }
}
