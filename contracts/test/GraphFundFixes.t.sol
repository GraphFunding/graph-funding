// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {GraphFund} from "../src/GraphFund.sol";
import {KeeperStaking} from "../src/KeeperStaking.sol";
import {Base} from "./utils/Base.t.sol";

/// @dev Tests for Task 4 fix rounds 1-2/5: setParams gas-safety bounds (round 2: maxNodes 48, the
///      committeeSize*(maxNodes/2)<=120 bound, and an isolated-gas worst-case measurement),
///      KeeperStaking's freeze-expiry valve (round 2: fixed to only reset on a false->true transition),
///      votes surviving a sibling removal, and the reject/prune bond-routing + pending-cascade NatSpec
///      fixes.
contract GraphFundFixesTest is Base {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _wN(uint256 n) internal pure returns (uint16[] memory w) {
        w = new uint16[](n);
        uint256 each = 10_000 / n;
        for (uint256 i; i < n; i++) w[i] = uint16(each);
        w[0] += uint16(10_000 - each * n);
    }

    // ---------------------------------------------------------------- Important-1a: setParams gas bounds

    function test_setParams_rejectsGasHeavyCommittee() public {
        GraphFund.Params memory p = fund.getParams();
        p.committeeSize = 6;
        // maxNodes stays at the default 48: 6 * (48 / 2) = 144 > 120.
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadParams.selector);
        fund.setParams(p);

        // 6 * (40 / 2) = 120 <= 120 must pass.
        p.maxNodes = 40;
        _setParams(p);
        assertEq(fund.getParams().committeeSize, 6);
        assertEq(fund.getParams().maxNodes, 40);
    }

    function test_setParams_rejectsShortEpoch() public {
        GraphFund.Params memory p = fund.getParams();
        // drawDelay stays at the default 5: 5 * 12 + 1 hours = 3660s; 1 hours = 3600s < 3660s.
        p.epochLength = 1 hours;
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadParams.selector);
        fund.setParams(p);

        // 1 hours + 60 = 3660s, not < 3660s, must pass.
        p.epochLength = 1 hours + 60;
        _setParams(p);
        assertEq(fund.getParams().epochLength, 1 hours + 60);
    }

    // ---------------------------------------------------------------- Important-1a: worst-case draw()/advance() gas

    /// @dev The true worst case under the (post fix-round-2) default `maxNodes=48`: every branch has
    ///      exactly 2 children (a binary tree maximizes the branch:leaf ratio, so it packs the most
    ///      committee-forming nodes into a fixed node budget). `maxDepth` is raised to 6 via `setParams`
    ///      (still within its own existing <=6 bound) because a balanced binary tree needs depth 5 to
    ///      reach 24 leaves; the default maxDepth=4 tops out at 16 leaves / 15 branches.
    ///      Shape: a perfect binary tree for depths 0-3 (1+2+4+8 = 15 branches), whose 16 depth-4
    ///      children are split into 8 that become depth-5 branches (each with 2 leaf children) and 8
    ///      that stay leaves. Totals: 15+8 = 23 branches, 8+16 = 24 leaves, 47 of the 48-node budget.
    function _buildWorstCaseTree() internal returns (uint32[] memory branchIds, uint256[] memory branchKids) {
        branchIds = new uint32[](23);
        branchKids = new uint256[](23);
        uint256 bi;

        branchIds[bi] = 0;
        branchKids[bi] = 2;
        bi++;

        uint32[2] memory d1;
        for (uint256 i; i < 2; i++) {
            d1[i] = _branch(0, string(abi.encodePacked("d1-", vm.toString(i))));
            branchIds[bi] = d1[i];
            branchKids[bi] = 2;
            bi++;
        }

        uint32[4] memory d2;
        uint256 d2i;
        for (uint256 i; i < 2; i++) {
            for (uint256 j; j < 2; j++) {
                d2[d2i] = _branch(d1[i], string(abi.encodePacked("d2-", vm.toString(d2i))));
                branchIds[bi] = d2[d2i];
                branchKids[bi] = 2;
                bi++;
                d2i++;
            }
        }

        uint32[8] memory d3;
        uint256 d3i;
        for (uint256 i; i < 4; i++) {
            for (uint256 j; j < 2; j++) {
                d3[d3i] = _branch(d2[i], string(abi.encodePacked("d3-", vm.toString(d3i))));
                branchIds[bi] = d3[d3i];
                branchKids[bi] = 2;
                bi++;
                d3i++;
            }
        }

        // depth4: 16 nodes (2 per depth3 branch). The first 8 become depth5 branches; the other 8 stay
        // leaves.
        uint32[8] memory d4b;
        uint256 d4bi;
        uint256 leafI;
        for (uint256 i; i < 8; i++) {
            for (uint256 j; j < 2; j++) {
                if (d4bi < 8) {
                    d4b[d4bi] = _branch(d3[i], string(abi.encodePacked("d4b-", vm.toString(d4bi))));
                    branchIds[bi] = d4b[d4bi];
                    branchKids[bi] = 2;
                    bi++;
                    d4bi++;
                } else {
                    _leaf(d3[i], string(abi.encodePacked("d4l-", vm.toString(leafI))), address(uint160(0x300000 + leafI)));
                    leafI++;
                }
            }
        }

        // depth5 leaves: 2 per depth4-branch (8 * 2 = 16).
        for (uint256 i; i < 8; i++) {
            for (uint256 j; j < 2; j++) {
                _leaf(d4b[i], string(abi.encodePacked("d5l-", vm.toString(leafI))), address(uint160(0x300000 + leafI)));
                leafI++;
            }
        }
    }

    function _stakeKeepers(uint256 count) internal {
        for (uint256 i; i < count; i++) {
            address k = address(uint160(0x400000 + i));
            _stake(k, 1_000_000e18);
        }
    }

    function _voteAllCommittees(uint32[] memory branchIds, uint256[] memory branchKids) internal {
        uint256 e = fund.epoch();
        for (uint256 i; i < branchIds.length; i++) {
            address[] memory committee = fund.getCommittee(e, branchIds[i]);
            uint16[] memory w = _wN(branchKids[i]);
            for (uint256 m; m < committee.length; m++) {
                vm.prank(committee[m]);
                fund.vote(branchIds[i], w);
            }
        }
    }

    /// @dev Run with `FOUNDRY_PROFILE=gas forge test --match-contract GraphFundFixesTest -vv` so
    ///      `[profile.gas]` (`isolate = true`) is active: each top-level external call then runs in its
    ///      own isolated EVM context, so `vm.lastCallGas()` reports what a real mainnet transaction would
    ///      pay (no warm-storage discount carried over from `setUp`/tree construction/staking in the same
    ///      test). Without `--isolate`, `gasleft()` deltas understate this because most of the storage
    ///      this call touches was already warmed earlier in the same test transaction.
    function test_draw_gasUnderCap_worstCase() public {
        GraphFund.Params memory p = fund.getParams();
        p.maxDepth = 6;
        _setParams(p);

        (uint32[] memory branchIds, uint256[] memory branchKids) = _buildWorstCaseTree();
        assertEq(fund.liveNodes(), 47);
        _stakeKeepers(2000);

        _start();
        vm.roll(fund.seedBlock() + 1);
        fund.draw();
        uint256 drawGas = vm.lastCallGas().gasTotalUsed;
        console2.log("draw() gas (23 branches, 2000 keepers, isolated):", drawGas);
        assertLt(drawGas, 14_000_000);

        _voteAllCommittees(branchIds, branchKids);

        // Fund the pool so advance()'s distribution walk actually recurses through the whole tree.
        _donate(10 ether);

        vm.warp(block.timestamp + fund.getParams().epochLength);
        fund.advance();
        uint256 advanceGas = vm.lastCallGas().gasTotalUsed;
        console2.log("advance() gas (23 branches, full votes, funded pool, isolated):", advanceGas);
        assertLt(advanceGas, 14_000_000);
    }

    // ---------------------------------------------------------------- Important-1b: staking freeze valve

    function test_staking_freezeExpires() public {
        _start(); // drawPending == true, drawPendingSince == block.number

        gf.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        gf.approve(address(staking), 1_000_000e18);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        staking.stake(1_000_000e18);
        vm.stopPrank();

        vm.roll(block.number + staking.FREEZE_MAX());
        _stake(alice, 1_000_000e18);
        assertEq(staking.stakeOf(alice), 1_000_000e18);
    }

    /// @dev Regresses the fix-round-1 bug: `advance()` always calls `_requestDraw()`, which used to
    ///      reset `drawPendingSince` on every epoch even though `drawPending` never actually went
    ///      false->true again (draw() is never called here), so the freeze never expired. With the fix,
    ///      `drawPendingSince` is only set on an actual false->true transition, so it stays pinned to the
    ///      original `start()` block across every subsequent epoch, and the freeze does expire once
    ///      enough real blocks have passed.
    function test_staking_freezeExpiresWhileEpochsAdvance() public {
        _start();
        uint256 startBlock = block.number;
        assertEq(staking.drawPendingSince(), startBlock);

        // Never call draw(): both GraphFund's and staking's drawPending stay true the whole time, only
        // via repeated _requestDraw() calls from advance() -- exactly the scenario the bug lived in.
        while (block.number - startBlock <= staking.FREEZE_MAX()) {
            vm.warp(block.timestamp + fund.getParams().epochLength);
            vm.roll(block.number + 1800);
            fund.advance();
        }
        assertGt(block.number - startBlock, staking.FREEZE_MAX());
        assertTrue(fund.drawPending());
        assertTrue(staking.drawPending());
        assertEq(staking.drawPendingSince(), startBlock);

        gf.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        gf.approve(address(staking), 1_000_000e18);
        staking.stake(1_000_000e18);
        vm.stopPrank();
        assertEq(staking.stakeOf(alice), 1_000_000e18);
    }

    // ---------------------------------------------------------------- Important-2: votes survive a removal

    function test_prune_keepsCommitteeVotes() public {
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        address keeperX = makeAddr("keeperX");
        address eve = makeAddr("eve");

        // Proposals go under a branch, never straight under the root: the fork under test is X.
        uint32 x = _branch(0, "X");
        uint32 a = _leaf(x, "A", alice);
        uint32 b = _leaf(x, "B", bob);

        uint256 bondAmt = fund.getParams().proposalBond;
        gf.mint(carol, bondAmt);
        vm.startPrank(carol);
        gf.approve(address(fund), bondAmt);
        uint32 p = fund.propose(x, dave, "P");
        vm.stopPrank();

        (uint32[] memory ids0, uint16[] memory w0) = fund.getChildren(x);
        assertEq(ids0.length, 3);
        assertEq(w0[0], 10_000);
        assertEq(w0[1], 0);
        assertEq(w0[2], 0);

        _stake(keeperX, 1_000_000e18);

        GraphFund.Params memory params = fund.getParams();
        params.committeeSize = 1;
        params.maxShiftBps = 10_000; // this test checks the exact median of the surviving votes
        _setParams(params);

        _start();
        // 4 epochs in which X's committee (keeperX) votes everything to A: P's weight stays 0 with a voting
        // committee every time, so its zeroStreak reaches pruneAfter (4) without ever being funded.
        for (uint256 i; i < 4; i++) {
            _draw();
            vm.prank(keeperX);
            fund.vote(x, _w3(10_000, 0, 0));
            _nextEpoch();
        }
        assertEq(fund.getNode(p).zeroStreak, 4);
        assertFalse(fund.getNode(p).everFunded);

        _draw();
        address[] memory committee = fund.getCommittee(fund.epoch(), x);
        assertEq(committee.length, 1);
        vm.prank(committee[0]);
        fund.vote(x, _w3(2000, 8000, 0));

        vm.prank(eve);
        fund.prune(p);

        // P is gone before the votes are tallied.
        (uint32[] memory idsAfterPrune,) = fund.getChildren(x);
        assertEq(idsAfterPrune.length, 2);

        _nextEpoch();

        (uint32[] memory ids, uint16[] memory w) = fund.getChildren(x);
        assertEq(ids.length, 2);
        bool sawA;
        bool sawB;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == a) {
                assertEq(w[i], 2000);
                sawA = true;
            } else if (ids[i] == b) {
                assertEq(w[i], 8000);
                sawB = true;
            } else {
                assertTrue(false, "unexpected child id");
            }
        }
        assertTrue(sawA && sawB);
    }

    // ---------------------------------------------------------------- Minor-5: rejectProposal mirrors prune

    function test_reject_refundsFundedProposal() public {
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        uint32 x = _branch(0, "X");
        uint256 bondAmt = fund.getParams().proposalBond;
        gf.mint(carol, bondAmt);
        vm.startPrank(carol);
        gf.approve(address(fund), bondAmt);
        uint32 p = fund.propose(x, dave, "P");
        vm.stopPrank();

        // P is X's only child: first-child-takes-all gives it weight 10_000 immediately.
        (, uint16[] memory w) = fund.getChildren(x);
        assertEq(w[0], 10_000);

        _start();
        _nextEpoch(); // _updateStreaks sees weight != 0 -> everFunded = true
        assertTrue(fund.getNode(p).everFunded);
        _draw(); // rejecting waits until the pending draw is done

        uint256 balBefore = gf.balanceOf(carol);
        uint256 deadBefore = gf.balanceOf(fund.DEAD());

        vm.prank(owner);
        fund.rejectProposal(p);

        assertEq(gf.balanceOf(carol), balBefore + bondAmt);
        assertEq(gf.balanceOf(fund.DEAD()), deadBefore);
        assertFalse(fund.getNode(p).active);
    }

    function test_reject_burnsUnfundedProposal() public {
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        uint256 bondAmt = fund.getParams().proposalBond;
        gf.mint(carol, bondAmt);
        vm.startPrank(carol);
        gf.approve(address(fund), bondAmt);
        // Owner-added leaf E takes X's weight first, so the proposal P starts at weight 0 and is
        // never funded.
        vm.stopPrank();
        uint32 x = _branch(0, "X");
        _leaf(x, "E", eve);
        vm.startPrank(carol);
        uint32 p = fund.propose(x, dave, "P");
        vm.stopPrank();
        assertFalse(fund.getNode(p).everFunded);

        uint256 balBefore = gf.balanceOf(carol);
        uint256 deadBefore = gf.balanceOf(fund.DEAD());

        vm.prank(owner);
        fund.rejectProposal(p);

        assertEq(gf.balanceOf(carol), balBefore);
        assertEq(gf.balanceOf(fund.DEAD()), deadBefore + bondAmt);
        assertFalse(fund.getNode(p).active);
    }

    // ---------------------------------------------------------------- pending-children cascade on removal

    function test_deactivate_dropsPendingChildrenOfRemovedBranch() public {
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");

        uint32 x = _branch(0, "X");
        _start();
        _draw(); // tree edits wait until the pending draw is done

        uint256 bondAmt = fund.getParams().proposalBond;
        gf.mint(carol, bondAmt);
        vm.startPrank(carol);
        gf.approve(address(fund), bondAmt);
        uint32 p2 = fund.propose(x, dave, "P2");
        vm.stopPrank();
        assertTrue(fund.getNode(p2).pending);

        uint256 balBefore = gf.balanceOf(carol);

        vm.prank(owner);
        fund.removeNode(x);

        uint32[] memory pending = fund.getPending();
        for (uint256 i; i < pending.length; i++) {
            assertTrue(pending[i] != p2);
        }
        assertFalse(fund.getNode(p2).active);
        assertFalse(fund.getNode(p2).pending);
        assertEq(gf.balanceOf(carol), balBefore + bondAmt);
    }
}
