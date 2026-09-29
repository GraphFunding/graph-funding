// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {GraphFund} from "../src/GraphFund.sol";
import {Base} from "./utils/Base.t.sol";
import {RejectEth} from "./utils/Mocks.sol";

contract GraphFundDistributionTest is Base {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    uint32 x;

    function setUp() public override {
        super.setUp();
        x = _branch(0, "X");
        _leaf(0, "C", carol);
        _leaf(x, "A", alice);
        _leaf(x, "B", bob);
        _setWeights(0, _w2(6000, 4000));
        _setWeights(x, _w2(5000, 5000));
    }

    function test_donation_wrapsToWeth() public {
        _donate(1 ether);
        assertEq(weth.balanceOf(address(fund)), 1 ether);
        assertEq(fund.pool(), 1 ether);
    }

    function test_advance_distributesByWeightProduct() public {
        _start();
        _donate(1 ether);
        _nextEpoch();
        assertEq(fund.owed(alice), 0.3 ether);
        assertEq(fund.owed(bob), 0.3 ether);
        assertEq(fund.owed(carol), 0.4 ether);
        assertEq(fund.totalOwed(), 1 ether);
        assertEq(fund.pool(), 0);
    }

    function test_voterPay_goesToRootVoters() public {
        for (uint256 i; i < 4; i++) {
            _stake(makeAddr(string(abi.encodePacked("k", vm.toString(i)))), 1_000_000e18);
        }
        _start();
        _draw();
        _donate(1 ether);
        address[] memory c = fund.getCommittee(1, 0);
        for (uint256 i; i < c.length; i++) {
            vm.prank(c[i]);
            fund.vote(0, _w2(6000, 4000));
        }
        _nextEpoch();
        uint256 each = (1 ether * 200 / 10_000) / c.length;
        uint256 rest = 1 ether - each * c.length;
        for (uint256 i; i < c.length; i++) assertEq(fund.owed(c[i]), each);
        assertEq(fund.owed(carol), rest * 4000 / 10_000);
        uint256 toX = rest * 6000 / 10_000;
        assertEq(fund.owed(alice), toX * 5000 / 10_000);
        assertEq(fund.owed(bob), toX * 5000 / 10_000);
    }

    function test_payout_sendsEth() public {
        _start();
        _donate(1 ether);
        _nextEpoch();
        uint256 before = alice.balance;
        fund.payout(alice);
        assertEq(alice.balance - before, 0.3 ether);
        assertEq(fund.owed(alice), 0);
        assertEq(fund.totalOwed(), 0.7 ether);
        assertEq(weth.balanceOf(address(fund)), 0.7 ether);
    }

    function test_payout_toContractWithoutReceive_sendsWeth() public {
        RejectEth r = new RejectEth();
        _leaf(x, "R", address(r));
        _setWeights(x, _w3(2500, 2500, 5000));
        _start();
        _donate(1 ether);
        _nextEpoch();
        uint256 expected = 0.6 ether * 5000 / 10_000;
        assertEq(fund.owed(address(r)), expected);
        fund.payout(address(r));
        assertEq(weth.balanceOf(address(r)), expected);
        assertEq(address(r).balance, 0);
    }

    function test_payout_nothingOwed_reverts() public {
        vm.expectRevert(GraphFund.NothingOwed.selector);
        fund.payout(alice);
    }

    function test_undistributedMoneyStaysInPool() public {
        _start();
        _nextEpoch(); // empty pool
        _donate(1 ether);
        assertEq(fund.pool(), 1 ether);
        _nextEpoch();
        assertEq(fund.pool(), 0);
    }

    function testFuzz_distributionConserves(uint96 amount, uint16 wRoot, uint16 wX) public {
        wRoot = uint16(bound(wRoot, 0, 10_000));
        wX = uint16(bound(wX, 0, 10_000));
        _setWeights(0, _w2(wRoot, 10_000 - wRoot));
        _setWeights(x, _w2(wX, 10_000 - wX));
        _start();
        _donate(amount);
        _nextEpoch();
        uint256 owedSum = fund.owed(alice) + fund.owed(bob) + fund.owed(carol);
        assertEq(owedSum, fund.totalOwed());
        assertLe(owedSum, amount);
        assertLe(uint256(amount) - owedSum, 3);
        assertEq(fund.pool() + fund.totalOwed(), amount);
    }
}
