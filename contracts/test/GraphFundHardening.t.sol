// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {GraphFund} from "../src/GraphFund.sol";
import {KeeperStaking} from "../src/KeeperStaking.sol";
import {Genesis} from "../script/Genesis.s.sol";
import {Base} from "./utils/Base.t.sol";
import {MedianHarness, MockToken, MockWETH, RejectEth} from "./utils/Mocks.sol";

/// @dev Final-review fixes: I1 (the freeze valve never lets a seed be consumed after it expired), C1 mitigation
///      (a committee moves each child's weight by at most `maxShiftBps` per epoch), proposals only under a branch,
///      M1 (no tree/params edits while a draw is pending), M2 (zero-weight streaks only count epochs with a voting
///      committee), M8 (forced ETH is wrapped at advance), M7 (KeeperBadge is Ownable2Step).
contract GraphFundHardeningTest is Base {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address prop = makeAddr("proposer");
    MedianHarness h;

    function setUp() public override {
        super.setUp();
        h = new MedianHarness();
    }

    // ---------------------------------------------------------------- helpers

    function _stakeKeepers(uint256 n, uint256 amount) internal returns (address[] memory ks) {
        ks = new address[](n);
        for (uint256 i; i < n; i++) {
            ks[i] = makeAddr(string.concat("keeper", vm.toString(i)));
            _stake(ks[i], amount);
        }
    }

    function _propose(uint32 parent, address to) internal returns (uint32 id) {
        uint256 bond = fund.getParams().proposalBond;
        gf.mint(prop, bond);
        vm.startPrank(prop);
        gf.approve(address(fund), bond);
        id = fund.propose(parent, to, "Proposal");
        vm.stopPrank();
    }

    /// @dev Every member of `node`'s committee in the current epoch votes `w`. Returns the committee size.
    function _voteAll(uint32 node, uint16[] memory w) internal returns (uint256 n) {
        address[] memory c = fund.getCommittee(fund.epoch(), node);
        n = c.length;
        for (uint256 i; i < n; i++) {
            vm.prank(c[i]);
            fund.vote(node, w);
        }
    }

    function _weights(uint32 node) internal view returns (uint16[] memory w) {
        (, w) = fund.getChildren(node);
    }

    function _sum(uint16[] memory w) internal pure returns (uint256 s) {
        for (uint256 i; i < w.length; i++) s += w[i];
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev Root -> A (6000), B (4000), C (0), all leaves, and six equal keepers.
    function _abcTree() internal {
        _leaf(0, "A", alice);
        _leaf(0, "B", bob);
        _leaf(0, "C", carol);
        _setWeights(0, _w3(6000, 4000, 0));
        _stakeKeepers(6, 1_000_000e18);
    }

    /// @dev Applies the real script/genesis.json (19 nodes). The owner hands the fund to the script and takes it back.
    function _genesis() internal {
        Genesis g = new Genesis();
        vm.prank(owner);
        fund.transferOwnership(address(g));
        vm.prank(address(g));
        fund.acceptOwnership();
        g.apply_(fund, vm.readFile("script/genesis.json"));
        vm.prank(address(g));
        fund.transferOwnership(owner);
        vm.prank(owner);
        fund.acceptOwnership();
        assertEq(fund.liveNodes(), 19);
    }

    // ---------------------------------------------------------------- I1: the valve never consumes an expired seed

    /// @dev Appendix PoC B. After a stall longer than FREEZE_MAX, `advance()` requests a seed while stakes are
    ///      unfrozen. Once that seed is public the attacker can top up, but `draw()` no longer consumes it: it
    ///      re-freezes stakes and asks for a new seed, so no top-up chosen after seeing a seed selects a committee.
    function test_valve_expiredFreezeReRequestsInsteadOfDrawing() public {
        _genesis();
        _stakeKeepers(20, 1_000_000e18);
        address[3] memory atk = [makeAddr("atk1"), makeAddr("atk2"), makeAddr("atk3")];
        for (uint256 j; j < 3; j++) _stake(atk[j], 2_000_000e18);
        (uint32[] memory rootKids,) = fund.getChildren(0);
        uint32 core = rootKids[0];
        _propose(core, makeAddr("evil")); // under a branch: proposals can no longer hang from the root

        _start();
        uint256 since = staking.drawPendingSince();

        // The bot stalls for more than a day; anyone advances. The new seed is requested with the valve open.
        vm.roll(block.number + staking.FREEZE_MAX() + 1);
        vm.warp(block.timestamp + 1 days);
        fund.advance();
        assertEq(staking.drawPendingSince(), since);
        _donate(100 ether);

        uint256 e = fund.epoch();
        uint256 sb = fund.seedBlock();
        vm.roll(sb + 1); // seed public, valve open

        // Whatever top-up the attacker picks after seeing the seed, draw() forms no committee from that seed.
        for (uint256 x = 1; x <= 64; x++) {
            uint256 snap = vm.snapshotState();
            _stake(atk[0], x * 1e18);
            fund.draw();
            assertTrue(fund.drawPending());
            for (uint256 b; b < rootKids.length; b++) assertEq(fund.getCommittee(e, rootKids[b]).length, 0);
            assertEq(fund.getCommittee(e, 0).length, 0);
            vm.revertToState(snap);
        }

        _stake(atk[0], 59e18); // still allowed: the freeze expired
        fund.draw();

        // Re-requested instead of drawn: still pending, a new seed in the future, stakes frozen again.
        assertTrue(fund.drawPending());
        assertEq(fund.seedBlock(), block.number + fund.getParams().drawDelay);
        assertTrue(staking.drawPending());
        assertEq(staking.drawPendingSince(), block.number);
        assertEq(fund.getCommittee(e, 0).length, 0);
        gf.mint(atk[1], 1e18);
        vm.startPrank(atk[1]);
        gf.approve(address(staking), 1e18);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        staking.stake(1e18);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        staking.unstake(1e18);
        vm.stopPrank();

        // The new seed is drawn normally, with stakes frozen since before it existed.
        vm.roll(fund.seedBlock() + 1);
        fund.draw();
        assertFalse(fund.drawPending());
        assertFalse(staking.drawPending());
        assertGt(fund.getCommittee(e, 0).length, 0);
    }

    // ---------------------------------------------------------------- C1 mitigation: capped weight shift

    function test_cap_defaultIs500() public view {
        assertEq(fund.getParams().maxShiftBps, 500);
    }

    function test_cap_setParamsBounds() public {
        GraphFund.Params memory p = fund.getParams();
        p.maxShiftBps = 99;
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadParams.selector);
        fund.setParams(p);
        p.maxShiftBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadParams.selector);
        fund.setParams(p);
        p.maxShiftBps = 100;
        _setParams(p);
        assertEq(fund.getParams().maxShiftBps, 100);
        p.maxShiftBps = 10_000;
        _setParams(p);
        assertEq(fund.getParams().maxShiftBps, 10_000);
    }

    /// @dev A committee voting 100% to a 0-weight child moves it to exactly maxShiftBps; the others lose the same
    ///      amount in total (each at most maxShiftBps).
    function test_cap_committeeCapturingABranchMovesOnlyMaxShift() public {
        _abcTree();
        _start();
        _draw();
        assertGt(_voteAll(0, _w3(0, 0, 10_000)), 0);
        vm.warp(block.timestamp + fund.getParams().epochLength);
        vm.expectEmit(true, true, false, true, address(fund));
        emit GraphFund.WeightsFinalized(1, 0, _w3(5750, 3750, 500));
        fund.advance();
        uint16[] memory w = _weights(0);
        assertEq(w[2], 500);
        assertEq((6000 - uint256(w[0])) + (4000 - uint256(w[1])), 500);
        assertLe(6000 - uint256(w[0]), 500);
        assertLe(4000 - uint256(w[1]), 500);
        assertEq(_sum(w), 10_000);
    }

    /// @dev Repeating the same vote converges toward the target at most maxShiftBps per child per epoch.
    function test_cap_convergesTowardTargetOverEpochs() public {
        _abcTree();
        _start();
        uint16[] memory target = _w3(0, 0, 10_000);
        uint16[] memory prev = _weights(0);
        for (uint256 k = 1; k <= 20; k++) {
            _draw();
            assertGt(_voteAll(0, target), 0);
            _nextEpoch();
            uint16[] memory w = _weights(0);
            assertEq(_sum(w), 10_000);
            assertEq(w[2], 500 * k);
            for (uint256 i; i < 3; i++) {
                assertLe(_absDiff(w[i], prev[i]), 500);
                assertLe(_absDiff(w[i], target[i]), _absDiff(prev[i], target[i]));
            }
            prev = w;
        }
        assertEq(prev[0], 0);
        assertEq(prev[1], 0);
        assertEq(prev[2], 10_000);
    }

    /// @dev maxShiftBps = 10_000 is the old behavior: the normalized median, in one epoch.
    function test_cap_off_reproducesMedianExactly() public {
        _abcTree();
        GraphFund.Params memory p = fund.getParams();
        p.maxShiftBps = 10_000;
        p.committeeSize = 3;
        _setParams(p);
        _start();
        _draw();
        address[] memory c = fund.getCommittee(1, 0);
        assertEq(c.length, 3);
        vm.prank(c[0]);
        fund.vote(0, _w3(7000, 2000, 1000));
        vm.prank(c[1]);
        fund.vote(0, _w3(6000, 3000, 1000));
        vm.prank(c[2]);
        fund.vote(0, _w3(2000, 2000, 6000));
        _nextEpoch();
        // medians 6000 / 2000 / 1000 -> normalized 6667 / 2222 / 1111, from 6000 / 4000 / 0 in one step
        uint16[] memory w = _weights(0);
        assertEq(w[0], 6667);
        assertEq(w[1], 2222);
        assertEq(w[2], 1111);
    }

    /// @dev Every median 0 (three voters, each all-in on a different child): the weights stay as they were and
    ///      nothing is finalized.
    function test_cap_allZeroMedians_keepPreviousWeights() public {
        _abcTree();
        GraphFund.Params memory p = fund.getParams();
        p.committeeSize = 3;
        _setParams(p);
        _start();
        _draw();
        address[] memory c = fund.getCommittee(1, 0);
        assertEq(c.length, 3);
        vm.prank(c[0]);
        fund.vote(0, _w3(10_000, 0, 0));
        vm.prank(c[1]);
        fund.vote(0, _w3(0, 10_000, 0));
        vm.prank(c[2]);
        fund.vote(0, _w3(0, 0, 10_000));
        vm.recordLogs();
        _nextEpoch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != GraphFund.WeightsFinalized.selector);
        }
        uint16[] memory w = _weights(0);
        assertEq(w[0], 6000);
        assertEq(w[1], 4000);
        assertEq(w[2], 0);
    }

    /// @dev The parked Minor: the committee gave everything to A, then A is removed before the tally. The surviving
    ///      columns are all 0, so the weights renormalized by the removal stay (no equal split to 0-weight siblings).
    function test_cap_allZeroMediansAfterRemovingFavorite_keepRenormalizedWeights() public {
        uint32 a = _leaf(0, "A", alice);
        uint32 b = _leaf(0, "B", bob);
        uint32 c = _leaf(0, "C", carol);
        _setWeights(0, _w3(6000, 4000, 0));
        _stakeKeepers(6, 1_000_000e18);
        _start();
        _draw();
        assertGt(_voteAll(0, _w3(10_000, 0, 0)), 0);
        vm.prank(owner);
        fund.removeNode(a); // allowed: the draw is done
        (uint32[] memory ids, uint16[] memory w0) = fund.getChildren(0);
        assertEq(ids[0], c);
        assertEq(ids[1], b);
        assertEq(w0[0], 0);
        assertEq(w0[1], 10_000);
        _nextEpoch();
        uint16[] memory w = _weights(0);
        assertEq(w[0], 0);
        assertEq(w[1], 10_000);
    }

    function testFuzz_step_sumsTo10000AndMovesAtMostMaxShift(uint256 seedCur, uint256 seedTarget, uint256 n, uint256 d)
        public
        view
    {
        n = bound(n, 1, 16);
        d = bound(d, 0, 12_000);
        uint256[] memory rc = new uint256[](n);
        uint256[] memory rt = new uint256[](n);
        for (uint256 i; i < n; i++) {
            uint256 x = uint256(keccak256(abi.encode(seedCur, i)));
            uint256 y = uint256(keccak256(abi.encode(seedTarget, i)));
            rc[i] = x % 3 == 0 ? 0 : x % 10_001; // plenty of zero weights
            rt[i] = y % 3 == 0 ? 0 : y % 10_001;
        }
        uint16[] memory cur = h.normalize(rc);
        uint16[] memory target = h.normalize(rt);
        uint16[] memory out = h.step(cur, target, d);

        assertEq(out.length, n);
        assertEq(_sum(out), 10_000);
        uint256 gainCap;
        uint256 lossCap;
        uint256 gained;
        for (uint256 i; i < n; i++) {
            assertLe(_absDiff(out[i], cur[i]), d);
            // each entry lands between where it was and where the committee wants it
            if (target[i] >= cur[i]) {
                assertGe(out[i], cur[i]);
                assertLe(out[i], target[i]);
                uint256 up = target[i] - cur[i];
                gainCap += up > d ? d : up;
                gained += out[i] - cur[i];
            } else {
                assertLe(out[i], cur[i]);
                assertGe(out[i], target[i]);
                uint256 down = cur[i] - target[i];
                lossCap += down > d ? d : down;
            }
        }
        // it moves as much as the cap allows on the tighter side
        assertEq(gained, gainCap < lossCap ? gainCap : lossCap);
        if (d >= 10_000) {
            for (uint256 i; i < n; i++) assertEq(out[i], target[i]);
        }
    }

    // ---------------------------------------------------------------- proposals only under a branch

    function test_propose_underRoot_reverts() public {
        uint256 bond = fund.getParams().proposalBond;
        gf.mint(prop, bond);
        vm.startPrank(prop);
        gf.approve(address(fund), bond);
        vm.expectRevert(GraphFund.BadParent.selector);
        fund.propose(0, bob, "Straight under the root");
        vm.stopPrank();
        // the owner may still add under the root, and proposals under a branch work
        uint32 x = _branch(0, "X");
        uint32 id = _propose(x, bob);
        assertEq(fund.getNode(id).parent, x);
    }

    // ---------------------------------------------------------------- M1: nothing moves while a draw is pending

    function test_drawPending_blocksTreeAndParamsEdits() public {
        uint32 x = _branch(0, "X");
        uint32 a = _leaf(x, "A", alice);
        _leaf(x, "B", bob);
        uint32 p1 = _propose(x, carol);
        _start();
        assertTrue(fund.drawPending());

        GraphFund.Params memory p = fund.getParams();
        vm.startPrank(owner);
        vm.expectRevert(GraphFund.DrawPending.selector);
        fund.setParams(p);
        vm.expectRevert(GraphFund.DrawPending.selector);
        fund.addNode(x, "N", carol);
        vm.expectRevert(GraphFund.DrawPending.selector);
        fund.removeNode(a);
        vm.expectRevert(GraphFund.DrawPending.selector);
        fund.rejectProposal(p1);
        fund.setWeights(x, _w3(5000, 5000, 0)); // does not affect the draw: still allowed
        vm.stopPrank();
        vm.expectRevert(GraphFund.DrawPending.selector);
        fund.prune(p1);
        uint32 p2 = _propose(x, alice); // only creates a pending node: still allowed
        assertTrue(fund.getNode(p2).pending);

        _draw();
        vm.expectRevert(GraphFund.NotPrunable.selector); // past the guard, now it is the streak that says no
        fund.prune(p1);
        vm.startPrank(owner);
        fund.setParams(p);
        fund.addNode(x, "N", carol);
        fund.removeNode(a);
        fund.rejectProposal(p1);
        vm.stopPrank();
        assertFalse(fund.getNode(a).active);
        assertFalse(fund.getNode(p1).active);
    }

    // ---------------------------------------------------------------- M2: streaks need a committee that voted

    /// @dev Reviewer PoC `test_poc_proposalPrunedWithoutAnyCommittee`: with no stakers there is never a committee,
    ///      so five closed epochs do not make the proposal prunable and nobody can burn its bond.
    function test_streak_doesNotGrowWithoutAnyCommittee() public {
        uint32 x = _branch(0, "X");
        _leaf(x, "A", alice);
        uint32 p1 = _propose(x, bob);
        uint256 bond = fund.getParams().proposalBond;
        _start();
        for (uint256 i; i < 5; i++) _nextEpoch();
        assertEq(fund.getNode(p1).zeroStreak, 0);
        _draw();
        vm.prank(makeAddr("thirdParty"));
        vm.expectRevert(GraphFund.NotPrunable.selector);
        fund.prune(p1);
        assertEq(gf.balanceOf(fund.DEAD()), 0);
        assertEq(gf.balanceOf(address(fund)), bond);
    }

    /// @dev A committee is drawn every epoch but never votes: the streak does not grow.
    function test_streak_doesNotGrowWhenCommitteeDoesNotVote() public {
        uint32 x = _branch(0, "X");
        _leaf(x, "A", alice);
        uint32 p1 = _propose(x, bob);
        _stakeKeepers(3, 1_000_000e18);
        _start();
        for (uint256 i; i < 5; i++) {
            _draw();
            assertGt(fund.getCommittee(fund.epoch(), x).length, 0);
            _nextEpoch();
        }
        assertEq(fund.getNode(p1).zeroStreak, 0);
    }

    /// @dev Only the fork whose committee voted counts: P1 under X (voted) grows, P2 under Y (did not) does not.
    function test_streak_countsOnlyForkWithVotingCommittee() public {
        uint32 x = _branch(0, "X");
        uint32 y = _branch(0, "Y");
        _setWeights(0, _w2(5000, 5000));
        _leaf(x, "A", alice);
        _leaf(y, "B", bob);
        uint32 p1 = _propose(x, carol);
        uint32 p2 = _propose(y, carol);
        _stakeKeepers(6, 1_000_000e18);
        _start();
        for (uint256 i; i < 4; i++) {
            _draw();
            assertGt(_voteAll(x, _w2(10_000, 0)), 0);
            _nextEpoch();
        }
        assertEq(fund.getNode(p1).zeroStreak, 4);
        assertEq(fund.getNode(p2).zeroStreak, 0);
        _draw();
        fund.prune(p1);
        assertEq(gf.balanceOf(fund.DEAD()), fund.getParams().proposalBond);
        vm.expectRevert(GraphFund.NotPrunable.selector);
        fund.prune(p2);
    }

    // ---------------------------------------------------------------- M8: forced ETH is wrapped at advance

    function test_forcedEth_isWrappedAndDistributedAtAdvance() public {
        _leaf(0, "A", alice);
        _leaf(0, "B", bob);
        _setWeights(0, _w2(5000, 5000));
        _start();
        vm.deal(address(fund), 1 ether); // arrives without receive() (coinbase / selfdestruct)
        _donate(1 ether);
        assertEq(weth.balanceOf(address(fund)), 1 ether);
        assertEq(fund.pool(), 1 ether);
        _nextEpoch();
        assertEq(address(fund).balance, 0);
        assertEq(weth.balanceOf(address(fund)), 2 ether);
        assertEq(fund.owed(alice), 1 ether);
        assertEq(fund.owed(bob), 1 ether);
        assertEq(fund.totalOwed(), 2 ether);
        assertEq(fund.pool(), 0);
    }

    // ---------------------------------------------------------------- P1: two-step exit (leave, then unstake)

    /// @dev Branches of the genesis tree that get a committee: the root and its four children.
    function _genesisBranches() internal view returns (uint32[] memory br) {
        (uint32[] memory kids,) = fund.getChildren(0);
        br = new uint32[](kids.length + 1);
        for (uint256 i; i < kids.length; i++) br[i + 1] = kids[i];
    }

    /// @dev Seats `who` holds across the committees of `br` in epoch `e`.
    function _seats(uint256 e, uint32[] memory br, address who) internal view returns (uint256 n) {
        for (uint256 b; b < br.length; b++) {
            address[] memory c = fund.getCommittee(e, br[b]);
            for (uint256 i; i < c.length; i++) {
                if (c[i] == who) n++;
            }
        }
    }

    function _leave(address who) internal {
        vm.prank(who);
        staking.leave();
    }

    /// @dev The reviewer's P1 scenario on the real genesis tree (25 seats per epoch). A ~33 % staker is drawn every
    ///      epoch: without leave() its lock ends in the same advance() that re-arms the freeze, and the next draw
    ///      locks it again. With leave() between the draw and the advance it unstakes in full right after its lock
    ///      ends, while the next freeze is active.
    function test_exit_largeStakerLeavesBetweenDrawAndAdvance() public {
        _genesis();
        _stakeKeepers(20, 1_000_000e18);
        address big = makeAddr("big");
        _stake(big, 10_000_000e18); // 10M of 30M
        uint32[] memory br = _genesisBranches();
        _start();
        _draw();
        assertGt(_seats(1, br, big), 0);
        assertEq(staking.lockedEpoch(big), 1);

        // Without leave(): locked until the advance, frozen right after it, locked again by the next draw.
        uint256 snap = vm.snapshotState();
        vm.prank(big);
        vm.expectRevert(KeeperStaking.Locked.selector);
        staking.unstake(10_000_000e18);
        _nextEpoch();
        vm.prank(big);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        staking.unstake(10_000_000e18);
        _draw();
        assertGt(_seats(2, br, big), 0);
        assertEq(staking.lockedEpoch(big), 2);
        vm.revertToState(snap);

        // With leave() in the same window (outside the freeze, while locked): out of every future draw.
        _leave(big);
        assertEq(staking.weightOf(big), 0);
        assertEq(staking.totalWeight(), 20_000_000e18);
        vm.prank(big);
        vm.expectRevert(KeeperStaking.Locked.selector); // still on this epoch's committee
        staking.unstake(10_000_000e18);
        _nextEpoch();
        assertTrue(staking.drawPending());
        assertLt(block.number, staking.drawPendingSince() + staking.FREEZE_MAX()); // the next freeze is active
        vm.prank(big);
        staking.unstake(10_000_000e18);
        assertEq(gf.balanceOf(big), 10_000_000e18);
        assertEq(staking.stakeOf(big), 0);
        assertFalse(staking.leaving(big));
        _draw();
        assertEq(_seats(2, br, big), 0);
    }

    /// @dev Stake, get drawn, leave, advance, draw: never on a committee again, and the lock never moves past the
    ///      epoch it was sitting on.
    function test_exit_leavingKeeperIsNeverDrawnAgain() public {
        _genesis();
        _stakeKeepers(6, 1_000_000e18);
        address k = makeAddr("leaver");
        _stake(k, 6_000_000e18); // half the weight
        uint32[] memory br = _genesisBranches();
        _start();
        vm.prank(k);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector); // not while a draw is pending
        staking.leave();
        _draw();
        assertGt(_seats(1, br, k), 0);
        _leave(k);
        for (uint256 i; i < 8; i++) {
            _nextEpoch();
            _draw();
            assertEq(_seats(fund.epoch(), br, k), 0);
            assertGt(fund.getCommittee(fund.epoch(), 0).length, 0);
        }
        assertEq(staking.lockedEpoch(k), 1);
        assertEq(staking.stakeOf(k), 6_000_000e18); // leaving does not move tokens
    }

    /// @dev A member that leaves mid-epoch keeps its seat: it votes, gets its badge and its voter pay, and stays
    ///      locked until the epoch ends.
    function test_exit_leavingMemberStillVotesAndIsPaid() public {
        _abcTree();
        _start();
        _draw();
        address[] memory c = fund.getCommittee(1, 0);
        assertGt(c.length, 1);
        address m = c[0];
        _leave(m);
        assertEq(staking.weightOf(m), 0);
        assertTrue(fund.isMember(1, 0, m));
        assertEq(_voteAll(0, _w3(6000, 4000, 0)), c.length);
        assertTrue(fund.hasVoted(1, 0, m));
        assertEq(badge.balanceOf(m, 1), 1);
        vm.prank(m);
        vm.expectRevert(KeeperStaking.Locked.selector);
        staking.unstake(1);
        _donate(100 ether);
        _nextEpoch();
        uint256 each = (100 ether * uint256(fund.getParams().voterPayBps) / 10_000) / c.length;
        assertGt(each, 0);
        assertEq(fund.owed(m), each);
        assertEq(fund.owed(c[1]), each);
        uint256 all = staking.stakeOf(m);
        vm.prank(m);
        staking.unstake(all); // epoch over, freeze active, weightless: free to go
        assertEq(gf.balanceOf(m), all);
    }

    /// @dev I1 stays closed. While a seed is known and the freeze holds, a weighted stake can neither leave nor
    ///      unstake, and a weightless stake leaving changes no committee.
    function test_exit_knownSeed_weightedCannotMove_weightlessChangesNothing() public {
        _genesis();
        _stakeKeepers(20, 1_000_000e18);
        address[3] memory atk = [makeAddr("atk1"), makeAddr("atk2"), makeAddr("atk3")];
        for (uint256 j; j < 3; j++) _stake(atk[j], 2_000_000e18);
        address ghost = makeAddr("ghost");
        _stake(ghost, 2_000_000e18);
        _leave(ghost); // left before any seed existed
        uint32[] memory br = _genesisBranches();
        _start();
        vm.roll(fund.seedBlock() + 1); // seed public, freeze active
        for (uint256 j; j < 3; j++) {
            vm.startPrank(atk[j]);
            vm.expectRevert(KeeperStaking.DrawIsPending.selector);
            staking.leave();
            vm.expectRevert(KeeperStaking.DrawIsPending.selector);
            staking.unstake(1);
            vm.stopPrank();
        }
        uint256 tw = staking.totalWeight();

        // Same seed, with and without the weightless stake leaving: identical committees.
        uint256 snap = vm.snapshotState();
        fund.draw();
        address[][] memory drawn = new address[][](br.length);
        for (uint256 b; b < br.length; b++) drawn[b] = fund.getCommittee(1, br[b]);
        vm.revertToState(snap);
        vm.prank(ghost);
        staking.unstake(2_000_000e18);
        assertEq(staking.totalWeight(), tw);
        fund.draw();
        for (uint256 b; b < br.length; b++) {
            assertGt(drawn[b].length, 0);
            assertEq(fund.getCommittee(1, br[b]), drawn[b]);
        }
    }

    /// @dev Appendix PoC B with the new move. After a stall the attacker sees the seed with the valve open, when
    ///      leave() is allowed (like stake), and makes any subset of its accounts leave. draw() still consumes
    ///      nothing; once it re-arms the freeze, leave() and weighted unstakes revert again.
    function test_exit_valvePoCB_leaveCannotCapture() public {
        _genesis();
        _stakeKeepers(20, 1_000_000e18);
        address[3] memory atk = [makeAddr("atk1"), makeAddr("atk2"), makeAddr("atk3")];
        for (uint256 j; j < 3; j++) _stake(atk[j], 2_000_000e18);
        (uint32[] memory rootKids,) = fund.getChildren(0);
        _propose(rootKids[0], makeAddr("evil"));
        uint32[] memory br = _genesisBranches();
        _start();

        vm.roll(block.number + staking.FREEZE_MAX() + 1);
        vm.warp(block.timestamp + 1 days);
        fund.advance(); // new seed requested; the freeze is not re-armed
        _donate(100 ether);
        uint256 e = fund.epoch();
        vm.roll(fund.seedBlock() + 1); // seed public, valve open

        for (uint256 mask = 1; mask < 8; mask++) {
            uint256 snap = vm.snapshotState();
            for (uint256 j; j < 3; j++) {
                if ((mask >> j) & 1 == 1) _leave(atk[j]);
            }
            fund.draw();
            assertTrue(fund.drawPending());
            for (uint256 b; b < br.length; b++) assertEq(fund.getCommittee(e, br[b]).length, 0);
            vm.revertToState(snap);
        }

        _leave(atk[0]);
        fund.draw(); // re-requested: the freeze is armed again before the new seed exists
        assertTrue(fund.drawPending());
        vm.roll(fund.seedBlock() + 1);
        vm.startPrank(atk[1]);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        staking.leave();
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        staking.unstake(1);
        vm.stopPrank();
        vm.prank(atk[0]); // weightless and never locked: it may go, which cannot change the draw
        staking.unstake(2_000_000e18);
        fund.draw();
        assertFalse(fund.drawPending());
        assertGt(fund.getCommittee(e, 0).length, 0);
        assertEq(_seats(e, br, atk[0]), 0);
    }

    // ---------------------------------------------------------------- M7: KeeperBadge is Ownable2Step

    function test_badge_ownershipNeedsAcceptance() public {
        vm.prank(owner);
        badge.transferOwnership(alice);
        assertEq(badge.owner(), owner);
        assertEq(badge.pendingOwner(), alice);
        vm.prank(alice);
        badge.acceptOwnership();
        assertEq(badge.owner(), alice);
    }
}

/// @dev Drives GraphFund through random sequences of donate / force-ETH / stake / leave / unstake / draw / vote /
///      advance / payout / propose / ripen / prune / removeNode / addLeaf with bounded inputs. Actions whose
///      preconditions do not hold are skipped (or caught), so the invariant run can fail on any unexpected revert.
contract FundHandler is Test {
    GraphFund internal fund;
    KeeperStaking internal staking;
    MockWETH internal weth;
    MockToken internal gf;
    address internal owner;

    uint256 public leaves; // successful leave() calls
    uint256 public unstakes; // successful unstake() calls
    uint256 public prunes; // proposals pruned by ripen()

    address[] public keepers;
    address[] internal recipients;
    address[] public payees; // everyone who can ever be owed: recipients + keepers
    uint32[] internal branches; // root first
    uint32[] internal proposals;
    uint32[] internal ownerLeaves;
    address internal prop = makeAddr("handlerProposer");

    constructor(
        GraphFund fund_,
        KeeperStaking staking_,
        MockWETH weth_,
        MockToken gf_,
        address owner_,
        address[] memory keepers_,
        address[] memory recipients_,
        uint32[] memory branches_,
        uint32[] memory ownerLeaves_
    ) {
        fund = fund_;
        staking = staking_;
        weth = weth_;
        gf = gf_;
        owner = owner_;
        keepers = keepers_;
        recipients = recipients_;
        branches = branches_;
        ownerLeaves = ownerLeaves_;
        for (uint256 i; i < recipients_.length; i++) payees.push(recipients_[i]);
        for (uint256 i; i < keepers_.length; i++) payees.push(keepers_[i]);
    }

    function payeeCount() external view returns (uint256) {
        return payees.length;
    }

    function keeperCount() external view returns (uint256) {
        return keepers.length;
    }

    function _frozen() internal view returns (bool) {
        return staking.drawPending() && block.number < staking.drawPendingSince() + staking.FREEZE_MAX();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(fund).call{value: amount}("");
        require(ok, "donate failed");
    }

    function forceEth(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        vm.deal(address(fund), address(fund).balance + amount);
    }

    function stake(uint256 who, uint256 amount) external {
        if (_frozen()) return;
        address k = keepers[who % keepers.length];
        amount = bound(amount, staking.minStake(), 3_000_000e18);
        gf.mint(k, amount);
        vm.startPrank(k);
        gf.approve(address(staking), amount);
        staking.stake(amount); // cancels the exit if the keeper was leaving
        vm.stopPrank();
    }

    /// @dev First step of the exit: outside the freeze, locked or not.
    function leave(uint256 who) external {
        if (_frozen()) return;
        address k = keepers[who % keepers.length];
        if (staking.stakeOf(k) == 0 || staking.leaving(k)) return;
        vm.prank(k);
        staking.leave();
        leaves++;
    }

    /// @dev Part or all of a stake, whenever the rules allow it: never while locked, and during the freeze only for a
    ///      stake without draw weight (leaving, or below minStake).
    function unstake(uint256 who, uint256 amount) external {
        address k = keepers[who % keepers.length];
        uint256 s = staking.stakeOf(k);
        if (s == 0) return;
        uint256 le = staking.lockedEpoch(k);
        if (le != 0 && le >= fund.epoch()) return;
        if (_frozen() && staking.weightOf(k) != 0) return;
        amount = bound(amount, 1, s);
        vm.prank(k);
        staking.unstake(amount);
        unstakes++;
    }

    function draw(uint256 delay) external {
        if (!fund.drawPending()) return;
        uint256 at = fund.seedBlock() + 1 + bound(delay, 0, 300);
        if (block.number < at) vm.roll(at);
        fund.draw();
    }

    function vote(uint256 seed) external {
        uint256 e = fund.epoch();
        if (e == 0) return;
        for (uint256 b; b < branches.length; b++) {
            uint32 node = branches[b];
            (uint32[] memory kids,) = fund.getChildren(node);
            if (kids.length == 0) continue;
            address[] memory c = fund.getCommittee(e, node);
            for (uint256 m; m < c.length; m++) {
                if (fund.hasVoted(e, node, c[m])) continue;
                vm.prank(c[m]);
                fund.vote(node, _randomSplit(kids.length, uint256(keccak256(abi.encode(seed, node, m)))));
            }
        }
    }

    function advance(uint256 blocks) external {
        if (fund.epoch() == 0) return;
        uint256 at = fund.nextAdvanceAt();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < at) vm.warp(at);
        vm.roll(block.number + bound(blocks, 1, 8000)); // sometimes past the 256-block window or the freeze valve
        fund.advance();
    }

    function payout(uint256 who) external {
        address to = payees[who % payees.length];
        if (fund.owed(to) == 0) return;
        fund.payout(to);
    }

    function propose(uint256 parentSeed, uint256 recipientSeed) external {
        uint32 parent = branches[1 + parentSeed % (branches.length - 1)]; // never the root
        address to = recipients[recipientSeed % recipients.length];
        uint256 bond = fund.getParams().proposalBond;
        gf.mint(prop, bond);
        vm.startPrank(prop);
        gf.approve(address(fund), bond);
        try fund.propose(parent, to, "P") returns (uint32 id) {
            proposals.push(id);
        } catch {}
        vm.stopPrank();
    }

    function prune(uint256 idSeed) external {
        if (proposals.length == 0) return;
        try fund.prune(proposals[idSeed % proposals.length]) {} catch {}
    }

    /// @dev N5: drives one proposal to a successful prune. Epoch after epoch its parent's committee votes it 0 (the
    ///      rest split at random) until its zero-weight streak reaches pruneAfter; then it draws once more, lets the
    ///      new committee vote on the fork (live votes) and prunes, so prune -> _remove -> _detach runs with votes in
    ///      place. Gives up after a few epochs (e.g. a proposal that already has weight, or no committee at all).
    function ripen(uint256 idSeed, uint256 seed) external {
        if (proposals.length == 0 || fund.epoch() == 0) return;
        uint32 id = proposals[idSeed % proposals.length];
        uint256 need = fund.getParams().pruneAfter;
        for (uint256 i; i < need + 4; i++) {
            GraphFund.Node memory n = fund.getNode(id);
            if (!(n.active || n.pending)) return; // removed or pruned meanwhile
            if (n.active && n.zeroStreak >= need) break;
            _drawNow();
            if (n.active) _starve(n.parent, id, uint256(keccak256(abi.encode(seed, i))));
            _advanceNow();
        }
        GraphFund.Node memory m = fund.getNode(id);
        if (!m.active || m.zeroStreak < need) return;
        _drawNow();
        _voteRandom(m.parent, seed);
        fund.prune(id);
        prunes++;
    }

    function _drawNow() internal {
        while (fund.drawPending()) {
            uint256 at = fund.seedBlock() + 1;
            if (block.number < at) vm.roll(at);
            fund.draw(); // a stale / valve draw re-requests; the next pass consumes the fresh seed
        }
    }

    function _advanceNow() internal {
        uint256 at = fund.nextAdvanceAt();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < at) vm.warp(at);
        vm.roll(block.number + 1);
        fund.advance();
    }

    /// @dev Every member of `parent`'s current committee that has not voted gives `id` 0 and splits the rest.
    function _starve(uint32 parent, uint32 id, uint256 seed) internal {
        uint256 e = fund.epoch();
        (uint32[] memory kids,) = fund.getChildren(parent);
        if (kids.length < 2) return;
        uint256 skip = kids.length;
        for (uint256 i; i < kids.length; i++) {
            if (kids[i] == id) skip = i;
        }
        if (skip == kids.length) return;
        address[] memory c = fund.getCommittee(e, parent);
        for (uint256 m; m < c.length; m++) {
            if (fund.hasVoted(e, parent, c[m])) continue;
            uint16[] memory rest = _randomSplit(kids.length - 1, uint256(keccak256(abi.encode(seed, m))));
            uint16[] memory w = new uint16[](kids.length);
            for (uint256 i; i < kids.length; i++) {
                if (i < skip) w[i] = rest[i];
                else if (i > skip) w[i] = rest[i - 1];
            }
            vm.prank(c[m]);
            fund.vote(parent, w);
        }
    }

    function _voteRandom(uint32 node, uint256 seed) internal {
        uint256 e = fund.epoch();
        (uint32[] memory kids,) = fund.getChildren(node);
        if (kids.length == 0) return;
        address[] memory c = fund.getCommittee(e, node);
        for (uint256 m; m < c.length; m++) {
            if (fund.hasVoted(e, node, c[m])) continue;
            vm.prank(c[m]);
            fund.vote(node, _randomSplit(kids.length, uint256(keccak256(abi.encode(seed, node, m)))));
        }
    }

    function removeNode(uint256 idSeed) external {
        if (ownerLeaves.length == 0) return;
        vm.prank(owner);
        try fund.removeNode(ownerLeaves[idSeed % ownerLeaves.length]) {} catch {}
    }

    function addLeaf(uint256 parentSeed, uint256 recipientSeed) external {
        uint32 parent = branches[parentSeed % branches.length];
        address to = recipients[recipientSeed % recipients.length];
        vm.prank(owner);
        try fund.addNode(parent, "L", to) returns (uint32 id) {
            ownerLeaves.push(id);
        } catch {}
    }

    function _randomSplit(uint256 n, uint256 seed) internal pure returns (uint16[] memory w) {
        w = new uint16[](n);
        uint256 left = 10_000;
        for (uint256 i; i + 1 < n; i++) {
            uint256 x = uint256(keccak256(abi.encode(seed, i))) % (left + 1);
            // casting to 'uint16' is safe because x <= left <= 10_000
            // forge-lint: disable-next-line(unsafe-typecast)
            w[i] = uint16(x);
            left -= x;
        }
        // casting to 'uint16' is safe because left <= 10_000
        // forge-lint: disable-next-line(unsafe-typecast)
        w[n - 1] = uint16(left);
    }
}

/// @dev M9: the fund always holds enough WETH for everything it owes.
contract GraphFundInvariantTest is Base {
    FundHandler handler;

    function setUp() public override {
        super.setUp();
        address[] memory recipients = new address[](5);
        recipients[0] = makeAddr("r0");
        recipients[1] = makeAddr("r1");
        recipients[2] = address(new RejectEth()); // paid in WETH
        recipients[3] = address(fund); // recycles into the pool
        recipients[4] = address(weth); // recycles into the pool

        uint32 x = _branch(0, "X");
        uint32 y = _branch(0, "Y");
        uint32[] memory leaves = new uint32[](5);
        leaves[0] = _leaf(0, "L0", recipients[0]);
        leaves[1] = _leaf(x, "L1", recipients[1]);
        leaves[2] = _leaf(x, "L2", recipients[2]);
        leaves[3] = _leaf(y, "L3", recipients[3]);
        leaves[4] = _leaf(y, "L4", recipients[4]);
        _setWeights(0, _w3(4000, 4000, 2000));
        _setWeights(x, _w2(5000, 5000));
        _setWeights(y, _w2(5000, 5000));

        address[] memory keepers = new address[](6);
        for (uint256 i; i < 6; i++) {
            keepers[i] = makeAddr(string.concat("invKeeper", vm.toString(i)));
            _stake(keepers[i], 1_000_000e18);
        }
        _start();

        uint32[] memory branches = new uint32[](3);
        (branches[0], branches[1], branches[2]) = (0, x, y);
        handler = new FundHandler(fund, staking, weth, gf, owner, keepers, recipients, branches, leaves);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = FundHandler.donate.selector;
        selectors[1] = FundHandler.forceEth.selector;
        selectors[2] = FundHandler.stake.selector;
        selectors[3] = FundHandler.draw.selector;
        selectors[4] = FundHandler.vote.selector;
        selectors[5] = FundHandler.advance.selector;
        selectors[6] = FundHandler.payout.selector;
        selectors[7] = FundHandler.propose.selector;
        selectors[8] = FundHandler.prune.selector;
        selectors[9] = FundHandler.removeNode.selector;
        selectors[10] = FundHandler.addLeaf.selector;
        selectors[11] = FundHandler.draw.selector; // draws twice as often: most epochs get a committee
        selectors[12] = FundHandler.leave.selector;
        selectors[13] = FundHandler.unstake.selector;
        selectors[14] = FundHandler.ripen.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The N5 action on its own: a fresh proposal is starved for pruneAfter epochs and pruned with live votes.
    function test_handler_ripenPrunesAProposal() public {
        handler.propose(0, 0);
        assertEq(handler.prunes(), 0);
        handler.ripen(0, 1);
        assertEq(handler.prunes(), 1);
        assertEq(gf.balanceOf(fund.DEAD()), fund.getParams().proposalBond); // never funded: the bond is burned
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_wethCoversEverythingOwed() public view {
        assertGe(weth.balanceOf(address(fund)), fund.totalOwed());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_owedSumsToTotalOwed() public view {
        uint256 s;
        uint256 n = handler.payeeCount();
        for (uint256 i; i < n; i++) s += fund.owed(handler.payees(i));
        assertEq(s, fund.totalOwed());
    }

    /// @dev P1: through stakes, leaves, cancelled leaves and (partial) unstakes, weightOf (0 while leaving) adds up to
    ///      totalWeight, the draw still matches a linear scan of the slots, and the tokens back every stake.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_stakingWeightsAddUp() public view {
        uint256 w;
        uint256 st;
        uint256 n = handler.keeperCount();
        for (uint256 i; i < n; i++) {
            address k = handler.keepers(i);
            w += staking.weightOf(k);
            st += staking.stakeOf(k);
            if (staking.leaving(k)) {
                assertGt(staking.stakeOf(k), 0);
                assertEq(staking.weightOf(k), 0);
            }
        }
        assertEq(w, staking.totalWeight());
        assertEq(st, staking.totalStaked());
        assertEq(gf.balanceOf(address(staking)), staking.totalStaked());
        uint256 tw = staking.totalWeight();
        if (tw == 0) return;
        uint256 slots = staking.slots();
        for (uint256 j; j <= 8; j++) {
            uint256 r = j == 8 ? tw - 1 : tw * j / 8;
            uint256 cum;
            address expected;
            for (uint256 i = 1; i <= slots; i++) {
                address k = staking.slotOwner(i);
                cum += staking.weightOf(k);
                if (cum > r) {
                    expected = k;
                    break;
                }
            }
            assertEq(staking.drawOne(r), expected);
        }
    }
}
