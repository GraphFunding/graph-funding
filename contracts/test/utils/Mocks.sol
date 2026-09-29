// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Median} from "../../src/lib/Median.sol";

contract MockWETH is ERC20("Wrapped Ether", "WETH") {
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH: ETH transfer failed");
    }

    receive() external payable {
        deposit();
    }
}

contract MockToken is ERC20("Graph Funding", "GRAPHFUND") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for GraphFund in KeeperStaking unit tests.
contract MockEpoch {
    uint256 public epoch;

    function set(uint256 e) external {
        epoch = e;
    }
}

/// @dev A contract that cannot receive ETH.
contract RejectEth {}

contract MedianHarness {
    function median(uint16[] memory xs) external pure returns (uint256) {
        return Median.median(xs);
    }

    function normalize(uint256[] memory raw) external pure returns (uint16[] memory) {
        return Median.normalize(raw);
    }
}
