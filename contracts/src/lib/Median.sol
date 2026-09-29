// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/// @title Median helpers for committee votes (weights in basis points, 10_000 = 100%).
library Median {
    /// @notice Median of `xs`. Sorts `xs` in place. Even count: floor of the average of the two middle values.
    function median(uint16[] memory xs) internal pure returns (uint256) {
        uint256 n = xs.length;
        require(n > 0, "Median: empty");
        for (uint256 i = 1; i < n; i++) {
            uint16 v = xs[i];
            uint256 j = i;
            while (j > 0 && xs[j - 1] > v) {
                xs[j] = xs[j - 1];
                j--;
            }
            xs[j] = v;
        }
        if (n % 2 == 1) return xs[n / 2];
        return (uint256(xs[n / 2 - 1]) + uint256(xs[n / 2])) / 2;
    }

    /// @notice Scales `raw` so it sums to exactly 10_000. The rounding remainder goes to the largest entry
    ///         (first one on ties). If everything is zero, returns an equal split (remainder to index 0).
    function normalize(uint256[] memory raw) internal pure returns (uint16[] memory out) {
        uint256 n = raw.length;
        out = new uint16[](n);
        if (n == 0) return out;
        uint256 sum;
        for (uint256 i; i < n; i++) sum += raw[i];
        if (sum == 0) {
            uint256 each = 10_000 / n;
            for (uint256 i; i < n; i++) out[i] = uint16(each);
            out[0] += uint16(10_000 - each * n);
            return out;
        }
        uint256 acc;
        uint256 maxI;
        for (uint256 i; i < n; i++) {
            uint256 v = (raw[i] * 10_000) / sum;
            out[i] = uint16(v);
            acc += v;
            if (raw[i] > raw[maxI]) maxI = i;
        }
        out[maxI] += uint16(10_000 - acc);
    }
}
