// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {GraphFund} from "../src/GraphFund.sol";

/// @notice GF_FUND=<GraphFund> forge script script/Genesis.s.sol --rpc-url $RPC --account <keystore> --broadcast
///         Reads script/genesis.json (or GF_GENESIS) and builds the initial tree. Owner only, before start().
contract Genesis is Script {
    // Field order must be alphabetical for vm.parseJson decoding.
    struct Leaf {
        string name;
        address recipient;
        uint256 weight;
    }

    function run() external {
        GraphFund fund = GraphFund(payable(vm.envAddress("GF_FUND")));
        string memory json = vm.readFile(vm.envOr("GF_GENESIS", string("script/genesis.json")));
        vm.startBroadcast();
        apply_(fund, json);
        vm.stopBroadcast();
    }

    // Decoding ".branches" straight into a Branch[] (a struct holding a nested dynamic Leaf[])
    // hits solc's legacy-codegen "stack too deep" limit on this project's non-via-ir profile
    // (confirmed: `--via-ir` alone fixes it, but enabling it project-wide would ~30x every build
    // and risk the already-reviewed suite). So branch name/weight are pulled as flat arrays via a
    // `[*]` wildcard path (safe: both the real genesis.json and the test fixture have >=2
    // branches — a `[*]` match on a single element decodes as a bare scalar, not a 1-element
    // array, and would revert; a lone-branch genesis is not a real scenario here). Each branch's
    // `leaves` array is then decoded directly (no wildcard) into Leaf[], which is safe for any
    // length including exactly one, since a JSON array literal — unlike a wildcard match set —
    // always decodes as an array.
    function apply_(GraphFund fund, string memory json) public {
        require(vm.keyExistsJson(json, ".branches[1]"), "Genesis: needs at least two branches");
        string[] memory branchNames = abi.decode(vm.parseJson(json, ".branches[*].name"), (string[]));
        uint256[] memory branchWeights = abi.decode(vm.parseJson(json, ".branches[*].weight"), (uint256[]));
        uint16[] memory rootW = new uint16[](branchNames.length);
        for (uint256 i; i < branchNames.length; i++) {
            uint32 b = fund.addNode(0, branchNames[i], address(0));
            rootW[i] = uint16(branchWeights[i]);

            Leaf[] memory leaves = abi.decode(
                vm.parseJson(json, string.concat(".branches[", vm.toString(i), "].leaves")), (Leaf[])
            );
            uint16[] memory w = new uint16[](leaves.length);
            for (uint256 j; j < leaves.length; j++) {
                fund.addNode(b, leaves[j].name, leaves[j].recipient);
                w[j] = uint16(leaves[j].weight);
            }
            if (leaves.length > 1) fund.setWeights(b, w);
        }
        if (branchNames.length > 1) fund.setWeights(0, rootW);
    }
}
