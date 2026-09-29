// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeeperStaking} from "../src/KeeperStaking.sol";
import {KeeperBadge} from "../src/KeeperBadge.sol";
import {GraphFund} from "../src/GraphFund.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IKeeperStaking} from "../src/interfaces/IKeeperStaking.sol";
import {IKeeperBadge} from "../src/interfaces/IKeeperBadge.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Genesis} from "../script/Genesis.s.sol";

contract ScriptsTest is Test {
    function test_deploy_wiresEverything() public {
        Deploy d = new Deploy();
        (KeeperStaking s, KeeperBadge b, GraphFund f) = d.run();
        assertEq(s.graphFund(), address(f));
        assertEq(b.minter(), address(f));
        assertEq(address(f.staking()), address(s));
        assertEq(address(f.badge()), address(b));
        assertEq(address(f.weth()), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(f.owner(), s.owner());
        assertEq(f.owner(), b.owner());
    }

    function test_genesis_buildsTree() public {
        Genesis g = new Genesis();
        KeeperStaking s = new KeeperStaking(address(this));
        KeeperBadge b = new KeeperBadge(address(this), "u");
        GraphFund f = new GraphFund(address(g), IWETH(address(0xE7)), IKeeperStaking(address(s)), IKeeperBadge(address(b)));
        g.apply_(f, vm.readFile("test/fixtures/genesis.test.json"));
        (uint32[] memory ids, uint16[] memory w) = f.getChildren(0);
        assertEq(ids.length, 2);
        assertEq(w[0], 6000);
        assertEq(w[1], 4000);
        assertEq(f.getNode(ids[0]).name, "Core");
        (uint32[] memory leaves, uint16[] memory lw) = f.getChildren(ids[0]);
        assertEq(leaves.length, 2);
        assertEq(lw[0], 7000);
        assertEq(lw[1], 3000);
        assertEq(f.getNode(leaves[0]).recipient, address(0xbEEF));
        (uint32[] memory tools, uint16[] memory tw) = f.getChildren(ids[1]);
        assertEq(tools.length, 1);
        assertEq(tw[0], 10_000);
    }
}
