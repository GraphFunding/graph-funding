# Graph Funding

**The funding system from [Snowmoon](https://vitalik.eth.limo/snowmoon/), running on Ethereum.**
Site: [graphfunding.app](https://graphfunding.app) · X: [@GraphFunding](https://x.com/GraphFunding)

> "For each node on the graph, the cryptographic network randomly selects a committee, that makes the decision of
> what weights the edges right below that node get." (Snowmoon, chapter 17)

Nobody votes on the whole budget. Money climbs down a tree of Ethereum public goods. At every fork, a committee
drawn at random from $GRAPHFUND stakers ("Keepers") sets how the money splits among the branches below. Every six hours
the split is closed (the median of the committee's votes), the money moves down the tree, and new committees are drawn.

**Not affiliated with Vitalik Buterin.** Lore from Snowmoon (GPL v3). Unaudited code, volatile token, no promises.

## How the money gets in

$GRAPHFUND trades on [Stockereum](https://stockereum.com) with a 2% fee: 1% to the platform, 1% to the creator wallet's
escrow. The creator wallet claims it with `FeeEscrow.claim(WETH, GraphFund)`, so it goes from the escrow straight into
this contract; every claim is public on Etherscan. Anyone can also send ETH to the contract.

## The tree

Four branches and fourteen recipients: core protocol (Protocol Guild, Lighthouse, Nimbus, Lodestar), privacy (Tor
Project, Web3Privacy Now, Whonix), security (Revoke.cash, SEAL 911, DeFiHackLabs) and open tooling & data (L2BEAT,
growthepie, Otterscan, rotki). **They are recipients, not partners: none of them has endorsed Graph Funding.** Each
address was read from the project's own donation page and checked on-chain; see [docs/recipients.md](docs/recipients.md).
The starting weights live in [contracts/script/genesis.json](contracts/script/genesis.json).

Anyone can propose a new project under a branch with a deposit of 1,000,000 $GRAPHFUND. It enters at 0% and only gets
money if a committee gives it weight; the deposit comes back the first time it does.

## Contracts

| Contract | What it does |
|---|---|
| `KeeperStaking` | Lock $GRAPHFUND (minimum 100,000) to enter the draw. Your chance of being drawn is your share of everything locked. Stakes are frozen for about a minute while a draw is pending (never more than ~1 day, even if a draw gets stuck), and locked while you sit on a committee. |
| `GraphFund` | The tree, the epochs (`draw` → `vote` → `advance`), the payouts (`payout` sends ETH, or WETH to contracts that refuse ETH) and the proposals. |
| `KeeperBadge` | One soulbound token per epoch you voted in. |

Keepers who voted on a fork share **2% of the ETH that flowed through that fork** that epoch; the other 98% keeps
climbing down the tree.

### What the owner can do, until renouncing
Edit the tree and the starting weights, change parameters within fixed bounds, reject spam proposals. The owner can
never touch stakes, money owed to a project, or who gets drawn. Ownership is renounced after 28 epochs (7 days) with
committees drawn and no emergency changes.

### Known limits
- Seats are drawn in proportion to stake: whoever locks most of the supply wins most seats. The median protects a
  fork's split only while no one holds a majority of its committee.
- Randomness is the blockhash of a future block, which that block's proposer can bias by withholding it.
- Claiming the Stockereum fees always depends on the creator wallet.
- `draw()` does all committees in one transaction; parameters are bounded (`committeeSize × maxNodes/2 ≤ 120`) so the
  worst case stays well under Ethereum's per-transaction gas cap.

## Develop

```bash
cd contracts
forge test                                            # unit + fuzz
FOUNDRY_PROFILE=gas forge test --match-contract GraphFundFixesTest -vv   # worst-case gas, isolated
cd ../web && npm install && npm run dev               # the site
```

## Images

The illustrations are risograph prints generated from the book's world and composed in HTML with real fonts. Per
Snowmoon's license note, the pipeline is published too: prompts and curation scripts are in
[brand/pipeline](brand/pipeline).

## License

GPL-3.0, like the book.
