// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

interface IKeeperStaking {
    function token() external view returns (address);
    function totalWeight() external view returns (uint256);
    function drawOne(uint256 rand) external view returns (address);
    function drawPendingSince() external view returns (uint256);
    function FREEZE_MAX() external view returns (uint256);
    function setDrawPending(bool pending) external;
    function lock(address keeper, uint256 epoch) external;
}
