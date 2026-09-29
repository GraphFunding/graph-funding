// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeeperStaking} from "../../src/KeeperStaking.sol";
import {KeeperBadge} from "../../src/KeeperBadge.sol";
import {GraphFund} from "../../src/GraphFund.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IKeeperStaking} from "../../src/interfaces/IKeeperStaking.sol";
import {IKeeperBadge} from "../../src/interfaces/IKeeperBadge.sol";

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct LaunchParams {
    string name;
    string symbol;
    string metadataUri;
    address quote;
    uint256 quoteUsdPrice;
    uint256 priceDeadline;
    bytes priceSignature;
    uint24 feePpm;
    bool feesToHolders;
}

interface IFactory {
    function owner() external view returns (address);
    function setPriceSigner(address signer) external;
    function creationFee() external view returns (uint256);
    function router() external view returns (address);
    function hook() external view returns (address);
    function createLaunchAndBuy(LaunchParams calldata p, uint256 minOut)
        external
        payable
        returns (address token, PoolKey memory key, bytes32 poolId);
}

interface IRouter {
    function buyWethPairWithEth(PoolKey calldata key, uint256 minOut, bytes calldata hookData)
        external
        payable
        returns (uint256);
}

interface IHook {
    function escrow() external view returns (address);
}

interface IEscrow {
    function claimable(address account, address currency) external view returns (uint256);
    function claim(address currency, address to) external returns (uint256);
}

/// @notice Run with: MAINNET_RPC_URL=<rpc> forge test --match-contract StockereumForkTest -vv
contract StockereumForkTest is Test {
    IFactory constant FACTORY = IFactory(0xc6B080DEd03C3382476A76345e79f82BD480977B);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 constant PRICE_TYPEHASH = keccak256("QuotePrice(address quote,uint256 usdPrice,uint256 deadline)");

    uint256 signerPk = 0xA11CE;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        // `makeAddr` addresses are just keccak-derived labels; on a real mainnet fork they can collide with an
        // already-deployed contract (here: 23-byte minimal proxies that forward received ETH elsewhere). alice's
        // payout balance is asserted below, so force these actors to be plain, codeless EOAs regardless of what
        // Ethereum mainnet happens to have at those addresses.
        vm.etch(creator, "");
        vm.etch(alice, "");
        vm.etch(bob, "");
    }

    function _sign(uint256 price, uint256 deadline) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("StockpadLaunchFactory"),
                keccak256("1"),
                block.chainid,
                address(FACTORY)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(PRICE_TYPEHASH, WETH, price, deadline)))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_fork_feesFlowFromStockereumToLeaves() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        // 1. launch $GRAPHFUND-like token from a fresh creator wallet (2% fee, fees to creator)
        vm.prank(FACTORY.owner());
        FACTORY.setPriceSigner(vm.addr(signerPk));
        LaunchParams memory p = LaunchParams({
            name: "Graph Funding",
            symbol: "GRAPHFUND",
            metadataUri: "ipfs://test",
            quote: WETH,
            quoteUsdPrice: 3_000e18,
            priceDeadline: block.timestamp + 300,
            priceSignature: "",
            feePpm: 20_000,
            feesToHolders: false
        });
        p.priceSignature = _sign(p.quoteUsdPrice, p.priceDeadline);
        // NOTE: FACTORY.creationFee() is read into a local *before* vm.prank(creator) below. Inlining it in
        // `{value: FACTORY.creationFee() + 0.05 ether}` would make it the actual next external call (Solidity
        // evaluates call-value expressions before making the call), which silently consumes the one-shot prank
        // and leaves createLaunchAndBuy running as this test contract instead of `creator`.
        uint256 launchValue = FACTORY.creationFee() + 0.05 ether;
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token, PoolKey memory key,) = FACTORY.createLaunchAndBuy{value: launchValue}(p, 0);

        // 2. Graph Funding deployed and wired
        KeeperStaking staking = new KeeperStaking(address(this));
        KeeperBadge badge = new KeeperBadge(address(this), "ipfs://badge/{id}");
        GraphFund fund = new GraphFund(address(this), IWETH(WETH), IKeeperStaking(address(staking)), IKeeperBadge(address(badge)));
        staking.setGraphFund(address(fund));
        staking.setToken(token);
        badge.setMinter(address(fund));
        fund.addNode(0, "Alice", alice);
        fund.addNode(0, "Bob", bob);
        uint16[] memory w = new uint16[](2);
        (w[0], w[1]) = (5000, 5000);
        fund.setWeights(0, w);

        // 3. trading after the anti-snipe window
        vm.warp(block.timestamp + 60);
        address router = FACTORY.router();
        address[3] memory buyers = [makeAddr("b1"), makeAddr("b2"), makeAddr("b3")];
        for (uint256 i; i < 3; i++) {
            vm.deal(buyers[i], 2 ether);
            vm.prank(buyers[i]);
            IRouter(router).buyWethPairWithEth{value: 1 ether}(key, 0, "");
        }

        // 4. creator claims its fee share straight into Graph Funding
        IEscrow escrow = IEscrow(IHook(FACTORY.hook()).escrow());
        uint256 fees = escrow.claimable(creator, WETH);
        assertGt(fees, 0.02 ether);
        vm.prank(creator);
        escrow.claim(WETH, address(fund));
        assertEq(IERC20(WETH).balanceOf(address(fund)), fees);

        // 5. buyers become keepers
        for (uint256 i; i < 3; i++) {
            uint256 bal = IERC20(token).balanceOf(buyers[i]);
            vm.startPrank(buyers[i]);
            IERC20(token).approve(address(staking), bal);
            staking.stake(bal);
            vm.stopPrank();
        }

        // 6. one full epoch: draw, vote 70/30, advance, payout
        fund.start();
        vm.roll(block.number + 6);
        fund.draw();
        address[] memory c = fund.getCommittee(1, 0);
        assertGt(c.length, 0);
        uint16[] memory v = new uint16[](2);
        (v[0], v[1]) = (7000, 3000);
        for (uint256 i; i < c.length; i++) {
            vm.prank(c[i]);
            fund.vote(0, v);
        }
        vm.warp(block.timestamp + 6 hours);
        fund.advance();

        uint256 aliceOwed = fund.owed(alice);
        assertGt(aliceOwed, fund.owed(bob));
        fund.payout(alice);
        assertEq(alice.balance, aliceOwed);
        assertLe(fund.totalOwed(), IERC20(WETH).balanceOf(address(fund)));
    }
}
