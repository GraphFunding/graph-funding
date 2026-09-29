// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

interface IEpochSource {
    function epoch() external view returns (uint256);
}
