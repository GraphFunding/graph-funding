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
    address bob = makeAddr("bob");

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

    // ---------------------------------------------------------------- two-step exit (P1)

    function _freeze() internal {
        vm.prank(address(ep));
        s.setDrawPending(true);
    }

    function test_leave_revertsDuringFreeze_worksOnceItExpires() public {
        _stake(alice, 300_000e18);
        _freeze();
        vm.prank(alice);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        s.leave();
        // same rule as stake(): once the freeze valve expired, leaving is allowed again
        vm.roll(block.number + s.FREEZE_MAX());
        vm.prank(alice);
        s.leave();
        assertTrue(s.leaving(alice));
    }

    function test_leave_dropsWeightEvenWhileLocked() public {
        _stake(alice, 300_000e18);
        _stake(bob, 200_000e18);
        ep.set(3);
        vm.prank(address(ep));
        s.lock(alice, 3);
        vm.expectEmit(true, false, false, false, address(s));
        emit KeeperStaking.Leaving(alice);
        vm.prank(alice);
        s.leave();
        assertTrue(s.leaving(alice));
        assertEq(s.weightOf(alice), 0);
        assertEq(s.stakeOf(alice), 300_000e18); // still staked, still locked
        assertEq(s.totalWeight(), 200_000e18);
        assertEq(s.totalStaked(), 500_000e18);
        for (uint256 r; r < 50; r++) assertEq(s.drawOne(uint256(keccak256(abi.encode(r)))), bob);
        vm.prank(alice);
        vm.expectRevert(KeeperStaking.Locked.selector);
        s.unstake(1);
    }

    function test_leave_revertsWithoutStakeOrTwice() public {
        vm.prank(alice);
        vm.expectRevert(KeeperStaking.NoStake.selector);
        s.leave();
        _stake(alice, 100_000e18);
        vm.startPrank(alice);
        s.leave();
        vm.expectRevert(KeeperStaking.AlreadyLeaving.selector);
        s.leave();
        vm.stopPrank();
    }

    function test_leave_belowMinStake_keepsZeroWeight() public {
        _stake(alice, 150_000e18);
        _stake(bob, 100_000e18);
        vm.startPrank(alice);
        s.unstake(100_000e18); // 50k: below minStake, already weightless
        s.leave();
        vm.stopPrank();
        assertEq(s.weightOf(alice), 0);
        assertEq(s.totalWeight(), 100_000e18);
    }

    function test_unstake_leavingDuringFreeze_isAllowed() public {
        _stake(alice, 300_000e18);
        _stake(bob, 200_000e18);
        vm.prank(alice);
        s.leave();
        _freeze();
        vm.startPrank(alice);
        s.unstake(100_000e18); // partial: still leaving, still weightless
        assertTrue(s.leaving(alice));
        assertEq(s.weightOf(alice), 0);
        assertEq(s.totalWeight(), 200_000e18);
        s.unstake(200_000e18); // full: the flag goes away with the stake
        vm.stopPrank();
        assertFalse(s.leaving(alice));
        assertEq(s.stakeOf(alice), 0);
        assertEq(t.balanceOf(alice), 300_000e18);
        assertEq(s.totalWeight(), 200_000e18);
        assertEq(s.totalStaked(), 200_000e18);
    }

    function test_unstake_weightedDuringFreeze_stillReverts() public {
        _stake(alice, 300_000e18);
        _stake(bob, 200_000e18);
        vm.prank(alice);
        s.leave();
        _freeze();
        vm.prank(bob);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        s.unstake(1);
        vm.prank(alice);
        s.unstake(1); // the weightless neighbour can
    }

    function test_unstake_belowMinStakeDuringFreeze_isAllowed() public {
        _stake(alice, 150_000e18);
        vm.prank(alice);
        s.unstake(100_000e18);
        _freeze();
        vm.prank(alice);
        s.unstake(50_000e18);
        assertEq(s.stakeOf(alice), 0);
        assertEq(s.totalWeight(), 0);
    }

    function test_unstake_leavingStillLocked_untilEpochPasses() public {
        _stake(alice, 300_000e18);
        ep.set(3);
        vm.prank(address(ep));
        s.lock(alice, 3);
        vm.prank(alice);
        s.leave();
        _freeze();
        vm.prank(alice);
        vm.expectRevert(KeeperStaking.Locked.selector);
        s.unstake(300_000e18);
        ep.set(4); // the epoch the keeper sat on is over; the next freeze is active
        vm.prank(alice);
        s.unstake(300_000e18);
        assertEq(t.balanceOf(alice), 300_000e18);
        assertFalse(s.leaving(alice));
    }

    function test_stake_whileLeaving_cancelsExitAndRestoresWeight() public {
        _stake(alice, 300_000e18);
        _stake(bob, 200_000e18);
        vm.prank(alice);
        s.leave();
        _stake(alice, 50_000e18);
        assertFalse(s.leaving(alice));
        assertEq(s.weightOf(alice), 350_000e18);
        assertEq(s.totalWeight(), 550_000e18);
    }

    function test_stake_whileLeaving_duringFreeze_reverts() public {
        _stake(alice, 300_000e18);
        vm.prank(alice);
        s.leave();
        _freeze();
        t.mint(alice, 1);
        vm.startPrank(alice);
        t.approve(address(s), 1);
        vm.expectRevert(KeeperStaking.DrawIsPending.selector);
        s.stake(1);
        vm.stopPrank();
        assertTrue(s.leaving(alice));
    }

    function test_fullUnstake_clearsLeaving_thenStakeIsWeighted() public {
        _stake(alice, 300_000e18);
        vm.startPrank(alice);
        s.leave();
        s.unstake(300_000e18);
        vm.stopPrank();
        assertFalse(s.leaving(alice));
        _stake(alice, 100_000e18);
        assertEq(s.weightOf(alice), 100_000e18);
        assertEq(s.totalWeight(), 100_000e18);
    }

    /// @dev Random stakes, partial unstakes, leaves and cancelled leaves: the Fenwick tree still matches a linear
    ///      scan of weightOf, and weightOf sums to totalWeight.
    function testFuzz_drawOne_matchesLinearScan_withLeaving(uint256 seed) public {
        uint256 n = 12;
        uint256 minAmt = s.minStake();
        address[] memory who = new address[](n);
        for (uint256 i; i < n; i++) {
            // casting to 'uint160' is safe because 0x2000 + i < 2**160
            // forge-lint: disable-next-line(unsafe-typecast)
            who[i] = address(uint160(0x2000 + i));
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = minAmt + (x % (3_000_000e18 - minAmt));
            _stake(who[i], amount);
            if (x % 4 == 0) {
                vm.prank(who[i]);
                s.unstake(amount / 2 + 1);
            }
            if ((x >> 8) % 3 == 0) {
                vm.prank(who[i]);
                s.leave();
                if ((x >> 16) % 4 == 0) {
                    _stake(who[i], minAmt); // cancels the exit
                } else if ((x >> 16) % 4 == 1) {
                    uint256 all = s.stakeOf(who[i]);
                    vm.prank(who[i]);
                    s.unstake(all);
                }
            }
        }
        uint256 sum;
        for (uint256 i; i < n; i++) sum += s.weightOf(who[i]);
        assertEq(sum, s.totalWeight());
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
