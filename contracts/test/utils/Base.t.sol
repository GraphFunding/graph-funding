// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeeperStaking} from "../../src/KeeperStaking.sol";
import {KeeperBadge} from "../../src/KeeperBadge.sol";
import {GraphFund} from "../../src/GraphFund.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IKeeperStaking} from "../../src/interfaces/IKeeperStaking.sol";
import {IKeeperBadge} from "../../src/interfaces/IKeeperBadge.sol";
import {MockWETH, MockToken} from "./Mocks.sol";

abstract contract Base is Test {
    MockWETH internal weth;
    MockToken internal gf;
    KeeperStaking internal staking;
    KeeperBadge internal badge;
    GraphFund internal fund;
    address internal owner = makeAddr("owner");

    function setUp() public virtual {
        weth = new MockWETH();
        gf = new MockToken();
        staking = new KeeperStaking(owner);
        badge = new KeeperBadge(owner, "https://graphfunding.test/badge/{id}.json");
        fund = new GraphFund(owner, IWETH(address(weth)), IKeeperStaking(address(staking)), IKeeperBadge(address(badge)));
        vm.startPrank(owner);
        staking.setGraphFund(address(fund));
        staking.setToken(address(gf));
        badge.setMinter(address(fund));
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        gf.mint(who, amount);
        vm.startPrank(who);
        gf.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _donate(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(fund).call{value: amount}("");
        require(ok, "donate failed");
    }

    function _branch(uint32 parent, string memory name) internal returns (uint32 id) {
        vm.prank(owner);
        id = fund.addNode(parent, name, address(0));
    }

    function _leaf(uint32 parent, string memory name, address to) internal returns (uint32 id) {
        vm.prank(owner);
        id = fund.addNode(parent, name, to);
    }

    function _setWeights(uint32 node, uint16[] memory w) internal {
        vm.prank(owner);
        fund.setWeights(node, w);
    }

    function _w2(uint16 a, uint16 b) internal pure returns (uint16[] memory w) {
        w = new uint16[](2);
        (w[0], w[1]) = (a, b);
    }

    function _w3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory w) {
        w = new uint16[](3);
        (w[0], w[1], w[2]) = (a, b, c);
    }

    function _start() internal {
        vm.prank(owner);
        fund.start();
    }

    function _draw() internal {
        vm.roll(fund.seedBlock() + 1);
        fund.draw();
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + fund.getParams().epochLength);
        fund.advance();
    }

    function _setParams(GraphFund.Params memory p) internal {
        vm.prank(owner);
        fund.setParams(p);
    }
}
