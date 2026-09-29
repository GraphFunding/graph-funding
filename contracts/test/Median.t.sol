// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MedianHarness} from "./utils/Mocks.sol";

contract MedianTest is Test {
    MedianHarness h;

    function setUp() public {
        h = new MedianHarness();
    }

    function _u16(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory x) {
        x = new uint16[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function test_median_odd() public view {
        assertEq(h.median(_u16(3000, 1000, 2000)), 2000);
    }

    function test_median_even_averagesMiddle() public view {
        uint16[] memory x = new uint16[](4);
        (x[0], x[1], x[2], x[3]) = (1000, 4000, 2000, 3000);
        assertEq(h.median(x), 2500);
    }

    function test_median_single() public view {
        uint16[] memory x = new uint16[](1);
        x[0] = 7777;
        assertEq(h.median(x), 7777);
    }

    function test_median_empty_reverts() public {
        vm.expectRevert(bytes("Median: empty"));
        h.median(new uint16[](0));
    }

    function test_normalize_remainderToLargest() public view {
        uint256[] memory r = new uint256[](3);
        (r[0], r[1], r[2]) = (5000, 3000, 1000);
        uint16[] memory w = h.normalize(r);
        assertEq(w[0], 5556);
        assertEq(w[1], 3333);
        assertEq(w[2], 1111);
    }

    function test_normalize_allZero_equalSplit() public view {
        uint16[] memory w = h.normalize(new uint256[](3));
        assertEq(w[0], 3334);
        assertEq(w[1], 3333);
        assertEq(w[2], 3333);
    }

    function testFuzz_normalize_sumsTo10000(uint256 seed, uint8 n) public view {
        n = uint8(bound(n, 1, 8));
        uint256[] memory r = new uint256[](n);
        for (uint256 i; i < n; i++) {
            r[i] = uint256(keccak256(abi.encode(seed, i))) % 10_001;
        }
        uint16[] memory w = h.normalize(r);
        uint256 sum;
        for (uint256 i; i < n; i++) sum += w[i];
        assertEq(sum, 10_000);
    }
}
