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
    uint256 bond;

    function setUp() public override {
        super.setUp();
        _leaf(0, "A", alice);
        bond = fund.getParams().proposalBond;
        gf.mint(prop, bond * 3);
        vm.prank(prop);
        gf.approve(address(fund), type(uint256).max);
    }

    function _propose(uint32 parent) internal returns (uint32 id) {
        vm.prank(prop);
        id = fund.propose(parent, bob, "Bob tools");
    }

    function test_propose_beforeStart_isActiveWithZeroWeight() public {
        uint32 id = _propose(0);
        GraphFund.Node memory n = fund.getNode(id);
        assertTrue(n.active);
        assertEq(n.proposer, prop);
        assertEq(n.bond, bond);
        (, uint16[] memory w) = fund.getChildren(0);
        assertEq(w[1], 0);
        assertEq(gf.balanceOf(address(fund)), bond);
    }

    function test_propose_afterStart_isPending() public {
        _start();
        uint32 id = _propose(0);
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
        uint32 id = _propose(0);
        vm.prank(owner);
        fund.rejectProposal(id);
        assertEq(gf.balanceOf(fund.DEAD()), bond);
        assertFalse(fund.getNode(id).active);
        (uint32[] memory ids,) = fund.getChildren(0);
        assertEq(ids.length, 1);
    }

    function test_reject_pendingProposal() public {
        _start();
        uint32 id = _propose(0);
        vm.prank(owner);
        fund.rejectProposal(id);
        assertEq(fund.getPending().length, 0);
        assertEq(gf.balanceOf(fund.DEAD()), bond);
    }

    function test_removeNode_onProposal_reverts() public {
        uint32 id = _propose(0);
        vm.prank(owner);
        vm.expectRevert(GraphFund.UseRejectProposal.selector);
        fund.removeNode(id);
    }

    function test_claimBond_afterFunded() public {
        uint32 id = _propose(0);
        _setWeights(0, _w2(5000, 5000));
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
        uint32 id = _propose(0);
        _start();
        _nextEpoch();
        vm.prank(prop);
        vm.expectRevert(GraphFund.NotFunded.selector);
        fund.claimBond(id);
    }

    function test_claimBond_onlyProposer() public {
        uint32 id = _propose(0);
        vm.prank(alice);
        vm.expectRevert(GraphFund.NotProposer.selector);
        fund.claimBond(id);
    }

    function test_prune_afterZeroStreak_burnsBond() public {
        uint32 id = _propose(0);
        _start();
        for (uint256 i; i < 4; i++) _nextEpoch();
        assertEq(fund.getNode(id).zeroStreak, 4);
        fund.prune(id);
        assertEq(gf.balanceOf(fund.DEAD()), bond);
        assertFalse(fund.getNode(id).active);
    }

    function test_prune_tooEarly_reverts() public {
        uint32 id = _propose(0);
        _start();
        for (uint256 i; i < 3; i++) _nextEpoch();
        vm.expectRevert(GraphFund.NotPrunable.selector);
        fund.prune(id);
    }

    function test_removingOwnerBranch_refundsProposalBonds() public {
        uint32 x = _branch(0, "X");
        vm.prank(prop);
        fund.propose(x, bob, "Bob");
        vm.prank(owner);
        fund.removeNode(x);
        assertEq(gf.balanceOf(prop), bond * 3);
    }
}
