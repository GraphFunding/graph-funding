// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GraphFund} from "../src/GraphFund.sol";
import {KeeperStaking} from "../src/KeeperStaking.sol";
import {KeeperBadge} from "../src/KeeperBadge.sol";
import {Base} from "./utils/Base.t.sol";

contract GraphFundEpochsTest is Base {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address[6] keepers;

    function setUp() public override {
        super.setUp();
        _leaf(0, "A", alice);
        _leaf(0, "B", bob);
        _leaf(0, "C", carol);
        _setWeights(0, _w3(5000, 3000, 2000));
        for (uint256 i; i < 6; i++) {
            keepers[i] = makeAddr(string(abi.encodePacked("keeper", vm.toString(i))));
            _stake(keepers[i], 1_000_000e18);
        }
        // These tests check median/split semantics: lift the per-epoch shift cap.
        GraphFund.Params memory p = fund.getParams();
        p.maxShiftBps = 10_000;
        _setParams(p);
    }

    function _committeeSize(uint8 k) internal {
        GraphFund.Params memory p = fund.getParams();
        p.committeeSize = k;
        _setParams(p);
    }

    function test_start_onlyOwnerOnce() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fund.start();
        _start();
        assertEq(fund.epoch(), 1);
        assertTrue(fund.drawPending());
        assertTrue(staking.drawPending());
        vm.prank(owner);
        vm.expectRevert(GraphFund.AlreadyStarted.selector);
        fund.start();
    }

    function test_draw_beforeStart_reverts() public {
        vm.expectRevert(GraphFund.NoDrawPending.selector);
        fund.draw();
    }

    function test_draw_tooEarly_reverts() public {
        _start();
        vm.expectRevert(GraphFund.TooEarly.selector);
        fund.draw();
    }

    function test_draw_formsCommitteeOfDistinctStakers() public {
        _start();
        _draw();
        address[] memory c = fund.getCommittee(1, 0);
        assertGt(c.length, 0);
        assertLe(c.length, 5);
        for (uint256 i; i < c.length; i++) {
            assertTrue(fund.isMember(1, 0, c[i]));
            assertEq(staking.lockedEpoch(c[i]), 1);
            for (uint256 j = i + 1; j < c.length; j++) assertTrue(c[i] != c[j]);
        }
        assertFalse(fund.drawPending());
        assertFalse(staking.drawPending());
    }

    function test_draw_skipsBranchWithOneChild() public {
        uint32 x = _branch(0, "X");
        _leaf(x, "only", alice);
        uint16[] memory w = new uint16[](4);
        (w[0], w[1], w[2], w[3]) = (4000, 3000, 2000, 1000);
        _setWeights(0, w);
        _start();
        _draw();
        assertGt(fund.getCommittee(1, 0).length, 0);
        assertEq(fund.getCommittee(1, x).length, 0);
    }

    function test_draw_withoutStakers_formsNoCommittee() public {
        for (uint256 i; i < 6; i++) {
            vm.prank(keepers[i]);
            staking.unstake(1_000_000e18);
        }
        _start();
        _draw();
        assertEq(fund.getCommittee(1, 0).length, 0);
        assertFalse(fund.drawPending());
    }

    function test_draw_reseedsAfter256Blocks() public {
        _start();
        uint256 sb = fund.seedBlock();
        vm.roll(sb + 300);
        fund.draw();
        assertTrue(fund.drawPending());
        assertEq(fund.seedBlock(), sb + 300 + 5);
    }

    function test_stakeFrozenWhileDrawPending() public {
        _start();
        gf.mint(alice, 1);
        vm.startPrank(alice);
        gf.approve(address(staking), 1);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        staking.stake(1);
        vm.stopPrank();
    }

    function test_memberCannotUnstakeDuringEpoch() public {
        _start();
        _draw();
        address m = fund.getCommittee(1, 0)[0];
        vm.prank(m);
        vm.expectRevert(KeeperStaking.Locked.selector);
        staking.unstake(1);
    }

    function test_vote_validations() public {
        _start();
        _draw();
        address m = fund.getCommittee(1, 0)[0];
        vm.prank(alice);
        vm.expectRevert(GraphFund.NotMember.selector);
        fund.vote(0, _w3(4000, 4000, 2000));
        vm.prank(m);
        vm.expectRevert(GraphFund.BadWeights.selector);
        fund.vote(0, _w2(5000, 5000));
        vm.prank(m);
        vm.expectRevert(GraphFund.BadWeights.selector);
        fund.vote(0, _w3(5000, 5000, 1));
        vm.prank(m);
        fund.vote(0, _w3(4000, 4000, 2000));
        vm.prank(m);
        vm.expectRevert(GraphFund.AlreadyVoted.selector);
        fund.vote(0, _w3(4000, 4000, 2000));
    }

    function test_vote_mintsSoulboundBadge() public {
        _start();
        _draw();
        address m = fund.getCommittee(1, 0)[0];
        vm.prank(m);
        fund.vote(0, _w3(4000, 4000, 2000));
        assertEq(badge.balanceOf(m, 1), 1);
        assertTrue(fund.badged(1, m));
        vm.prank(m);
        vm.expectRevert(KeeperBadge.Soulbound.selector);
        badge.safeTransferFrom(m, alice, 1, 1, "");
    }

    function test_advance_tooEarly_reverts() public {
        _start();
        vm.expectRevert(GraphFund.TooEarly.selector);
        fund.advance();
    }

    function test_advance_notStarted_reverts() public {
        vm.expectRevert(GraphFund.NotStarted.selector);
        fund.advance();
    }

    function test_advance_setsMedianOfVotes() public {
        _committeeSize(3);
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
        (, uint16[] memory w) = fund.getChildren(0);
        // medians 6000 / 2000 / 1000 → normalized 6667 / 2222 / 1111
        assertEq(w[0], 6667);
        assertEq(w[1], 2222);
        assertEq(w[2], 1111);
        assertEq(fund.epoch(), 2);
        assertTrue(fund.drawPending());
    }

    function test_advance_twoVotes_averagesMiddle() public {
        _committeeSize(3);
        _start();
        _draw();
        address[] memory c = fund.getCommittee(1, 0);
        vm.prank(c[0]);
        fund.vote(0, _w3(8000, 2000, 0));
        vm.prank(c[1]);
        fund.vote(0, _w3(6000, 2000, 2000));
        _nextEpoch();
        (, uint16[] memory w) = fund.getChildren(0);
        assertEq(w[0], 7000);
        assertEq(w[1], 2000);
        assertEq(w[2], 1000);
    }

    function test_advance_withoutVotes_keepsWeights() public {
        _start();
        _draw();
        _nextEpoch();
        (, uint16[] memory w) = fund.getChildren(0);
        assertEq(w[0], 5000);
        assertEq(w[1], 3000);
        assertEq(w[2], 2000);
    }

    function test_nonMemberCanUnstakeAfterNextDraw() public {
        _start();
        _draw();
        _nextEpoch();
        _draw();
        for (uint256 i; i < 6; i++) {
            if (!fund.isMember(2, 0, keepers[i])) {
                vm.prank(keepers[i]);
                staking.unstake(1);
                assertEq(staking.stakeOf(keepers[i]), 1_000_000e18 - 1);
                return;
            }
        }
        revert("every keeper was drawn");
    }
}
