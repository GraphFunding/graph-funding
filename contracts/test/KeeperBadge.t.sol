// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeeperBadge} from "../src/KeeperBadge.sol";

contract KeeperBadgeTest is Test {
    KeeperBadge b;
    address owner = makeAddr("owner");
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");

    function setUp() public {
        b = new KeeperBadge(owner, "https://graphfunding.test/badge/{id}.json");
        vm.prank(owner);
        b.setMinter(minter);
    }

    function test_setMinter_once() public {
        vm.prank(owner);
        vm.expectRevert(KeeperBadge.AlreadySet.selector);
        b.setMinter(alice);
    }

    function test_onlyMinterMints() public {
        vm.expectRevert(KeeperBadge.NotMinter.selector);
        b.mint(alice, 1);
        vm.prank(minter);
        b.mint(alice, 7);
        assertEq(b.balanceOf(alice, 7), 1);
    }

    function test_soulbound() public {
        vm.prank(minter);
        b.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(KeeperBadge.Soulbound.selector);
        b.safeTransferFrom(alice, minter, 1, 1, "");
    }

    function test_ownerSetsUri() public {
        vm.prank(owner);
        b.setURI("ipfs://x/{id}");
        assertEq(b.uri(1), "ipfs://x/{id}");
    }
}
