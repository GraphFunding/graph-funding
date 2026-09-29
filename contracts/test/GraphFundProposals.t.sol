// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {GraphFund} from "../src/GraphFund.sol";
import {KeeperStaking} from "../src/KeeperStaking.sol";
import {KeeperBadge} from "../src/KeeperBadge.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IKeeperStaking} from "../src/interfaces/IKeeperStaking.sol";
import {IKeeperBadge} from "../src/interfaces/IKeeperBadge.sol";
import {Base} from "./utils/Base.t.sol";

contract GraphFundProposalsTest is Base {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address prop = makeAddr("proposer");
    address keeper = makeAddr("keeper");
    uint256 bond;
    uint32 x; // proposals go under a branch, never straight under the root

    function setUp() public override {
        super.setUp();
        x = _branch(0, "X");
        _leaf(x, "A", alice);
        bond = fund.getParams().proposalBond;
        gf.mint(prop, bond * 3);
        vm.prank(prop);
        gf.approve(address(fund), type(uint256).max);
    }

    function _propose(uint32 parent) internal returns (uint32 id) {
        vm.prank(prop);
        id = fund.propose(parent, bob, "Bob tools");
    }

    /// @dev Draw, let X's committee give everything to A, close the epoch. Zero-weight streaks only count epochs
    ///      in which the fork had a committee that voted.
    function _votedEpoch() internal {
        _draw();
        address[] memory c = fund.getCommittee(fund.epoch(), x);
        assertGt(c.length, 0);
        for (uint256 i; i < c.length; i++) {
            vm.prank(c[i]);
            fund.vote(x, _w2(10_000, 0));
        }
        _nextEpoch();
    }

    function test_propose_beforeStart_isActiveWithZeroWeight() public {
        uint32 id = _propose(x);
        GraphFund.Node memory n = fund.getNode(id);
        assertTrue(n.active);
        assertEq(n.proposer, prop);
        assertEq(n.bond, bond);
        (, uint16[] memory w) = fund.getChildren(x);
        assertEq(w[1], 0);
        assertEq(gf.balanceOf(address(fund)), bond);
    }

    function test_propose_afterStart_isPending() public {
        _start();
        uint32 id = _propose(x);
        assertTrue(fund.getNode(id).pending);
    }

    function test_propose_requiresToken() public {
        KeeperStaking s2 = new KeeperStaking(owner);
        KeeperBadge b2 = new KeeperBadge(owner, "u");
        GraphFund f2 = new GraphFund(owner, IWETH(address(weth)), IKeeperStaking(address(s2)), IKeeperBadge(address(b2)));
        vm.prank(prop);
        vm.expectRevert(GraphFund.TokenNotSet.selector);
        f2.propose(0, bob, "Bob");
    }

    function test_propose_zeroRecipient_reverts() public {
        vm.prank(prop);
        vm.expectRevert(GraphFund.ZeroAddress.selector);
        fund.propose(0, address(0), "Nobody");
    }

    function test_reject_burnsBond() public {
        uint32 id = _propose(x);
        vm.prank(owner);
        fund.rejectProposal(id);
        assertEq(gf.balanceOf(fund.DEAD()), bond);
        assertFalse(fund.getNode(id).active);
        (uint32[] memory ids,) = fund.getChildren(x);
        assertEq(ids.length, 1);
    }

    function test_reject_pendingProposal() public {
        _start();
        _draw(); // tree edits wait until the pending draw is done
        uint32 id = _propose(x);
        vm.prank(owner);
        fund.rejectProposal(id);
        assertEq(fund.getPending().length, 0);
        assertEq(gf.balanceOf(fund.DEAD()), bond);
    }

    function test_removeNode_onProposal_reverts() public {
        uint32 id = _propose(x);
        vm.prank(owner);
        vm.expectRevert(GraphFund.UseRejectProposal.selector);
        fund.removeNode(id);
    }

    function test_claimBond_afterFunded() public {
        uint32 id = _propose(x);
        _setWeights(x, _w2(5000, 5000));
        _start();
        _donate(1 ether);
        _nextEpoch();
        assertTrue(fund.getNode(id).everFunded);
        vm.prank(prop);
        fund.claimBond(id);
        assertEq(gf.balanceOf(prop), bond * 3);
        vm.prank(prop);
        vm.expectRevert(GraphFund.BondSettled.selector);
        fund.claimBond(id);
    }

    function test_claimBond_notFunded_reverts() public {
        uint32 id = _propose(x);
        _start();
        _nextEpoch();
        vm.prank(prop);
        vm.expectRevert(GraphFund.NotFunded.selector);
        fund.claimBond(id);
    }

    function test_claimBond_onlyProposer() public {
        uint32 id = _propose(x);
        vm.prank(alice);
        vm.expectRevert(GraphFund.NotProposer.selector);
        fund.claimBond(id);
    }

    function test_prune_afterZeroStreak_burnsBond() public {
        uint32 id = _propose(x);
        _stake(keeper, 1_000_000e18);
        _start();
        for (uint256 i; i < 4; i++) _votedEpoch();
        assertEq(fund.getNode(id).zeroStreak, 4);
        _draw(); // prune waits until the pending draw is done
        fund.prune(id);
        assertEq(gf.balanceOf(fund.DEAD()), bond);
        assertFalse(fund.getNode(id).active);
    }

    function test_prune_tooEarly_reverts() public {
        uint32 id = _propose(x);
        _stake(keeper, 1_000_000e18);
        _start();
        for (uint256 i; i < 3; i++) _votedEpoch();
        assertEq(fund.getNode(id).zeroStreak, 3);
        _draw();
        vm.expectRevert(GraphFund.NotPrunable.selector);
        fund.prune(id);
    }

    function test_removingOwnerBranch_refundsProposalBonds() public {
        uint32 y = _branch(0, "Y");
        vm.prank(prop);
        fund.propose(y, bob, "Bob");
        vm.prank(owner);
        fund.removeNode(y);
        assertEq(gf.balanceOf(prop), bond * 3);
    }
}
