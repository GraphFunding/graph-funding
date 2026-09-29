// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
