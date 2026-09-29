// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {KeeperStaking} from "../src/KeeperStaking.sol";
import {KeeperBadge} from "../src/KeeperBadge.sol";
import {GraphFund} from "../src/GraphFund.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IKeeperStaking} from "../src/interfaces/IKeeperStaking.sol";
import {IKeeperBadge} from "../src/interfaces/IKeeperBadge.sol";

/// @notice forge script script/Deploy.s.sol --rpc-url $RPC --account <keystore> --broadcast --verify
///         The broadcasting wallet becomes the owner of all three contracts.
contract Deploy is Script {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external returns (KeeperStaking staking, KeeperBadge badge, GraphFund fund) {
        string memory badgeURI = vm.envOr("GF_BADGE_URI", string("https://graphfunding.app/badge/{id}.json"));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        staking = new KeeperStaking(deployer);
        badge = new KeeperBadge(deployer, badgeURI);
        fund = new GraphFund(deployer, IWETH(WETH), IKeeperStaking(address(staking)), IKeeperBadge(address(badge)));
        staking.setGraphFund(address(fund));
        badge.setMinter(address(fund));
        vm.stopBroadcast();
        console2.log("KeeperStaking", address(staking));
        console2.log("KeeperBadge  ", address(badge));
        console2.log("GraphFund    ", address(fund));
    }
}
