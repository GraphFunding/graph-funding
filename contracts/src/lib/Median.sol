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

    /// @notice One capped step from `cur` toward `target`: no entry moves by more than `maxShift` basis points.
    /// @dev Both inputs must have the same length and each sum to 10_000. Every move `target[i] - cur[i]` is first
    ///      clamped to [-maxShift, +maxShift]. The side with more total movement (gains or losses) is then scaled
    ///      down (floor) to match the other one, and the rounding remainder goes back one entry at a time, in index
    ///      order, without exceeding any clamped move. So the result sums to exactly 10_000, every
    ///      `|out[i] - cur[i]| <= maxShift`, and each entry lands between `cur[i]` and `target[i]`.
    ///      With `maxShift >= 10_000` nothing is clamped and the result is `target`.
    function step(uint16[] memory cur, uint16[] memory target, uint256 maxShift)
        internal
        pure
        returns (uint16[] memory out)
    {
        uint256 n = cur.length;
        uint256[] memory up = new uint256[](n);
        uint256[] memory down = new uint256[](n);
        uint256 p;
        uint256 q;
        for (uint256 i; i < n; i++) {
            if (target[i] > cur[i]) {
                uint256 d = target[i] - cur[i];
                up[i] = d > maxShift ? maxShift : d;
                p += up[i];
            } else if (cur[i] > target[i]) {
                uint256 d = cur[i] - target[i];
                down[i] = d > maxShift ? maxShift : d;
                q += down[i];
            }
        }
        if (p > q) _scale(up, p, q);
        else if (q > p) _scale(down, q, p);
        out = new uint16[](n);
        for (uint256 i; i < n; i++) out[i] = uint16(cur[i] + up[i] - down[i]);
    }

    /// @dev Scales `moves` (summing to `from`) down so they sum to exactly `to` (`to < from`), never raising any
    ///      entry above its original value.
    function _scale(uint256[] memory moves, uint256 from, uint256 to) private pure {
        uint256 n = moves.length;
        uint256[] memory cap = new uint256[](n);
        uint256 sum;
        for (uint256 i; i < n; i++) {
            cap[i] = moves[i];
            moves[i] = (moves[i] * to) / from;
            sum += moves[i];
        }
        uint256 rem = to - sum;
        for (uint256 i; i < n && rem > 0; i++) {
            uint256 room = cap[i] - moves[i];
            uint256 add = room < rem ? room : rem;
            moves[i] += add;
            rem -= add;
        }
    }
}
