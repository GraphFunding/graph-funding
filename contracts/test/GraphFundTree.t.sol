// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GraphFund} from "../src/GraphFund.sol";
import {Base} from "./utils/Base.t.sol";

contract GraphFundTreeTest is Base {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function test_root() public view {
        assertEq(fund.nodeCount(), 1);
        GraphFund.Node memory r = fund.getNode(0);
        assertTrue(r.active);
        assertEq(r.recipient, address(0));
        assertEq(r.name, "Ethereum public goods");
        assertEq(fund.liveNodes(), 1);
    }

    function test_addNode_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fund.addNode(0, "X", address(0));
    }

    function test_firstChildTakesAll_nextStartsAtZero() public {
        uint32 a = _leaf(0, "A", alice);
        uint32 b = _leaf(0, "B", bob);
        (uint32[] memory ids, uint16[] memory w) = fund.getChildren(0);
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(w[0], 10_000);
        assertEq(w[1], 0);
    }

    function test_setWeights() public {
        _leaf(0, "A", alice);
        _leaf(0, "B", bob);
        _setWeights(0, _w2(6000, 4000));
        (, uint16[] memory w) = fund.getChildren(0);
        assertEq(w[0], 6000);
        assertEq(w[1], 4000);
    }

    function test_setWeights_mustSumTo10000() public {
        _leaf(0, "A", alice);
        _leaf(0, "B", bob);
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadWeights.selector);
        fund.setWeights(0, _w2(6000, 3000));
    }

    function test_setWeights_lengthMustMatch() public {
        _leaf(0, "A", alice);
        _leaf(0, "B", bob);
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadWeights.selector);
        fund.setWeights(0, _w3(5000, 3000, 2000));
    }

    function test_cannotAddUnderLeaf() public {
        uint32 a = _leaf(0, "A", alice);
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadParent.selector);
        fund.addNode(a, "X", bob);
    }

    function test_depthLimit() public {
        uint32 b1 = _branch(0, "1");
        uint32 b2 = _branch(b1, "2");
        uint32 b3 = _branch(b2, "3");
        uint32 b4 = _branch(b3, "4");
        _leaf(b3, "4-leaf", alice);
        vm.prank(owner);
        vm.expectRevert(GraphFund.TooDeep.selector);
        fund.addNode(b4, "5", alice);
    }

    function test_childrenLimit() public {
        for (uint256 i; i < 8; i++) {
            _leaf(0, string(abi.encodePacked("L", vm.toString(i))), address(uint160(0x100 + i)));
        }
        vm.prank(owner);
        vm.expectRevert(GraphFund.TooManyChildren.selector);
        fund.addNode(0, "L8", alice);
    }

    function test_badName() public {
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadName.selector);
        fund.addNode(0, "", alice);
    }

    function test_removeNode_removesSubtreeAndRenormalizes() public {
        uint32 x = _branch(0, "X");
        uint32 c = _leaf(0, "C", bob);
        _leaf(x, "A", alice);
        _leaf(x, "B", bob);
        _setWeights(0, _w2(6000, 4000));
        assertEq(fund.liveNodes(), 5);
        vm.prank(owner);
        fund.removeNode(x);
        (uint32[] memory ids, uint16[] memory w) = fund.getChildren(0);
        assertEq(ids.length, 1);
        assertEq(ids[0], c);
        assertEq(w[0], 10_000);
        assertEq(fund.liveNodes(), 2);
        assertFalse(fund.getNode(x).active);
    }

    function test_removeRoot_reverts() public {
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadNode.selector);
        fund.removeNode(0);
    }

    function test_addAfterStart_isPendingUntilAdvance() public {
        _leaf(0, "A", alice);
        _start();
        uint32 b = _leaf(0, "B", bob);
        assertTrue(fund.getNode(b).pending);
        (uint32[] memory ids,) = fund.getChildren(0);
        assertEq(ids.length, 1);
        _nextEpoch();
        assertFalse(fund.getNode(b).pending);
        assertTrue(fund.getNode(b).active);
        uint16[] memory w;
        (ids, w) = fund.getChildren(0);
        assertEq(ids.length, 2);
        assertEq(w[1], 0);
    }

    function test_setParams_validates() public {
        GraphFund.Params memory p = fund.getParams();
        p.committeeSize = 0;
        vm.prank(owner);
        vm.expectRevert(GraphFund.BadParams.selector);
        fund.setParams(p);
        p.committeeSize = 3;
        _setParams(p);
        assertEq(fund.getParams().committeeSize, 3);
    }
}
