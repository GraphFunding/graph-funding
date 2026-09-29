// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KeeperStaking} from "../src/KeeperStaking.sol";
import {MockToken, MockEpoch} from "./utils/Mocks.sol";

contract KeeperStakingTest is Test {
    KeeperStaking s;
    MockToken t;
    MockEpoch ep;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        t = new MockToken();
        ep = new MockEpoch();
        s = new KeeperStaking(owner);
        vm.startPrank(owner);
        s.setToken(address(t));
        s.setGraphFund(address(ep));
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        t.mint(who, amount);
        vm.startPrank(who);
        t.approve(address(s), amount);
        s.stake(amount);
        vm.stopPrank();
    }

    function test_setToken_onlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(KeeperStaking.AlreadySet.selector);
        s.setToken(address(1));
    }

    function test_setToken_onlyOwner() public {
        KeeperStaking fresh = new KeeperStaking(owner);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setToken(address(t));
    }

    function test_stake_requiresToken() public {
        KeeperStaking fresh = new KeeperStaking(owner);
        vm.expectRevert(KeeperStaking.TokenNotSet.selector);
        fresh.stake(1);
    }

    function test_stake_movesTokensAndAddsWeight() public {
        _stake(alice, 200_000e18);
        assertEq(t.balanceOf(address(s)), 200_000e18);
        assertEq(s.stakeOf(alice), 200_000e18);
        assertEq(s.weightOf(alice), 200_000e18);
        assertEq(s.totalWeight(), 200_000e18);
    }

    function test_stake_belowMinStake_reverts() public {
        t.mint(alice, 50_000e18);
        vm.startPrank(alice);
        t.approve(address(s), 50_000e18);
        vm.expectRevert(KeeperStaking.BelowMinStake.selector);
        s.stake(50_000e18);
        vm.stopPrank();
    }

    function test_belowMinStake_hasNoWeight() public {
        // stake() now requires the resulting balance to clear minStake, so a stake can no longer land
        // below it directly; a partial unstake is the only way to end up under minStake, and that must
        // still carry zero weight.
        _stake(alice, 150_000e18);
        assertEq(s.totalWeight(), 150_000e18);
        vm.prank(alice);
        s.unstake(100_000e18);
        assertEq(s.stakeOf(alice), 50_000e18);
        assertEq(s.totalWeight(), 0);
    }

    function test_unstake_returnsTokensAndRemovesWeight() public {
        _stake(alice, 300_000e18);
        vm.prank(alice);
        s.unstake(250_000e18);
        assertEq(t.balanceOf(alice), 250_000e18);
        assertEq(s.stakeOf(alice), 50_000e18);
        assertEq(s.totalWeight(), 0);
    }

    function test_unstake_moreThanStake_reverts() public {
        _stake(alice, 100_000e18);
        vm.prank(alice);
        vm.expectRevert(KeeperStaking.InsufficientStake.selector);
        s.unstake(100_001e18);
    }

    function test_drawPending_blocksStakeAndUnstake() public {
        _stake(alice, 100_000e18);
        vm.prank(address(ep));
        s.setDrawPending(true);
        t.mint(alice, 1);
        vm.startPrank(alice);
        t.approve(address(s), 1);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        s.stake(1);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        s.unstake(1);
        vm.stopPrank();
    }

    function test_lock_blocksUnstakeUntilEpochPasses() public {
        _stake(alice, 100_000e18);
        ep.set(3);
        vm.prank(address(ep));
        s.lock(alice, 3);
        vm.prank(alice);
        vm.expectRevert(KeeperStaking.Locked.selector);
        s.unstake(1);
        ep.set(4);
        vm.prank(alice);
        s.unstake(1);
        assertEq(s.stakeOf(alice), 100_000e18 - 1);
    }

    function test_onlyGraphFund() public {
        vm.expectRevert(KeeperStaking.NotGraphFund.selector);
        s.setDrawPending(true);
        vm.expectRevert(KeeperStaking.NotGraphFund.selector);
        s.lock(alice, 1);
    }

    function test_setMinStake_onlyBeforeStakers() public {
        vm.prank(owner);
        s.setMinStake(1);
        assertEq(s.minStake(), 1);
        _stake(alice, 5);
        vm.prank(owner);
        vm.expectRevert(KeeperStaking.StakersExist.selector);
        s.setMinStake(2);
    }

    function test_drawOne_withoutWeight_reverts() public {
        vm.expectRevert(KeeperStaking.NoWeight.selector);
        s.drawOne(1);
    }

    function testFuzz_drawOne_matchesLinearScan(uint256 seed) public {
        uint256 n = 12;
        uint256 minAmt = s.minStake();
        address[] memory who = new address[](n);
        for (uint256 i; i < n; i++) {
            who[i] = address(uint160(0x1000 + i));
            // stake() now requires the resulting balance to clear minStake; unstake below it is still
            // allowed, so only the stake amount is floored here.
            uint256 amount = minAmt + (uint256(keccak256(abi.encode(seed, i))) % (3_000_000e18 - minAmt));
            _stake(who[i], amount);
            if (i % 3 == 0) {
                vm.prank(who[i]);
                s.unstake(amount / 2 + 1 > amount ? amount : amount / 2 + 1);
            }
        }
        uint256 total = s.totalWeight();
        if (total == 0) return;
        for (uint256 k; k < 20; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, "r", k))) % total;
            uint256 cum;
            address expected;
            for (uint256 i; i < n; i++) {
                cum += s.weightOf(who[i]);
                if (cum > r) {
                    expected = who[i];
                    break;
                }
            }
            assertEq(s.drawOne(r), expected);
        }
    }
}
