// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Keeper badge
/// @notice One soulbound token per epoch in which a keeper voted (id = epoch).
contract KeeperBadge is ERC1155, Ownable {
    error Soulbound();
    error NotMinter();
    error AlreadySet();
    error ZeroAddress();

    string public constant name = "Graph Funding Keeper";
    string public constant symbol = "KEEPER";

    address public minter;

    constructor(address owner_, string memory uri_) ERC1155(uri_) Ownable(owner_) {}

    function setMinter(address minter_) external onlyOwner {
        if (minter != address(0)) revert AlreadySet();
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
    }

    function setURI(string calldata uri_) external onlyOwner {
        _setURI(uri_);
    }

    function mint(address to, uint256 epoch) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, epoch, 1, "");
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (from != address(0)) revert Soulbound();
        super._update(from, to, ids, values);
    }
}
