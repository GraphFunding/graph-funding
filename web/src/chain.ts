import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  parseAbi,
  type Address,
  type EIP1193Provider,
} from 'viem'
import { mainnet } from 'viem/chains'
import genesis from './data/genesis.json' // copia de contracts/script/genesis.json (sincronizar al cambiar el génesis)
import { config, deployed } from './config'

export const fundAbi = parseAbi([
  'struct Node { uint32 parent; uint8 depth; bool active; bool pending; bool everFunded; bool bondSettled; uint8 zeroStreak; address recipient; address proposer; uint256 bond; string name; }',
  'struct Params { uint64 epochLength; uint8 committeeSize; uint16 voterPayBps; uint8 drawDelay; uint8 maxChildren; uint8 maxDepth; uint16 maxNodes; uint8 pruneAfter; uint256 proposalBond; }',
  'function nodeCount() view returns (uint256)',
  'function getNode(uint32 id) view returns (Node)',
  'function getChildren(uint32 id) view returns (uint32[] ids, uint16[] weights)',
  'function getParams() view returns (Params)',
  'function getCommittee(uint256 epoch, uint32 node) view returns (address[])',
  'function getVotes(uint256 epoch, uint32 node) view returns (address[] voters, uint16[][] vectors)',
  'function epoch() view returns (uint256)',
  'function nextAdvanceAt() view returns (uint256)',
  'function drawPending() view returns (bool)',
  'function seedBlock() view returns (uint256)',
  'function pool() view returns (uint256)',
  'function totalOwed() view returns (uint256)',
  'function owed(address) view returns (uint256)',
  'function isMember(uint256, uint256, address) view returns (bool)',
  'function hasVoted(uint256, uint256, address) view returns (bool)',
  'function owner() view returns (address)',
  'function draw()',
  'function advance()',
  'function vote(uint32 node, uint16[] bps)',
  'function payout(address to)',
  'function propose(uint32 parent, address recipient, string name) returns (uint32)',
])

export const stakingAbi = parseAbi([
  'function totalWeight() view returns (uint256)',
  'function totalStaked() view returns (uint256)',
  'function slots() view returns (uint256)',
  'function stakeOf(address) view returns (uint256)',
  'function weightOf(address) view returns (uint256)',
  'function lockedEpoch(address) view returns (uint256)',
  'function drawPending() view returns (bool)',
  'function minStake() view returns (uint256)',
  'function stake(uint256 amount)',
  'function unstake(uint256 amount)',
])

export const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
])

export const escrowAbi = parseAbi([
  'function claimable(address account, address currency) view returns (uint256)',
  'function claim(address currency, address to) returns (uint256)',
])

export type TreeNode = {
  id: number
  name: string
  recipient: Address | null
  weight: number // bps inside its parent
  children: TreeNode[]
  pending?: boolean
  proposer?: Address | null
  owed?: bigint
  committee?: Address[]
  votes?: { voter: Address; weights: number[] }[]
}

export type GraphState = {
  live: boolean
  epoch: number
  nextAdvanceAt: number
  drawPending: boolean
  seedBlock: bigint
  pool: bigint
  totalOwed: bigint
  totalStaked: bigint
  keepers: number
  harvestable: bigint
  tree: TreeNode
}

export const publicClient = createPublicClient({ chain: mainnet, transport: http(config.rpcUrl), batch: { multicall: true } })

type GenesisLeaf = { name: string; recipient: string; weight: number }
type GenesisBranch = { name: string; weight: number; leaves: GenesisLeaf[] }

export function genesisTree(): TreeNode {
  let id = 1
  const branches = (genesis as { branches: GenesisBranch[] }).branches
  return {
    id: 0,
    name: 'Ethereum public goods',
    recipient: null,
    weight: 10_000,
    children: branches.map((b) => ({
      id: id++,
      name: b.name,
      recipient: null,
      weight: b.weight,
      children: b.leaves.map((l) => ({ id: id++, name: l.name, recipient: l.recipient as Address, weight: l.weight, children: [] })),
    })),
  }
}

const emptyState = (): GraphState => ({
  live: false,
  epoch: 0,
  nextAdvanceAt: 0,
  drawPending: false,
  seedBlock: 0n,
  pool: 0n,
  totalOwed: 0n,
  totalStaked: 0n,
  keepers: 0,
  harvestable: 0n,
  tree: genesisTree(),
})

export async function readState(): Promise<GraphState> {
  if (!deployed()) return emptyState()
  const fund = { address: config.graphFund as Address, abi: fundAbi }
  const staking = { address: config.staking as Address, abi: stakingAbi }
  const [epoch, nextAt, pending, seed, pool, totalOwed, totalStaked, slots] = await Promise.all([
    publicClient.readContract({ ...fund, functionName: 'epoch' }),
    publicClient.readContract({ ...fund, functionName: 'nextAdvanceAt' }),
    publicClient.readContract({ ...fund, functionName: 'drawPending' }),
    publicClient.readContract({ ...fund, functionName: 'seedBlock' }),
    publicClient.readContract({ ...fund, functionName: 'pool' }),
    publicClient.readContract({ ...fund, functionName: 'totalOwed' }),
    publicClient.readContract({ ...staking, functionName: 'totalStaked' }),
    publicClient.readContract({ ...staking, functionName: 'slots' }),
  ])
  const harvestable = config.creator
    ? await publicClient.readContract({
        address: config.feeEscrow,
        abi: escrowAbi,
        functionName: 'claimable',
        args: [config.creator as Address, config.weth],
      })
    : 0n

  const build = async (id: number, weight: number): Promise<TreeNode> => {
    const n = await publicClient.readContract({ ...fund, functionName: 'getNode', args: [id] })
    const node: TreeNode = {
      id,
      name: n.name,
      recipient: n.recipient === '0x0000000000000000000000000000000000000000' ? null : n.recipient,
      proposer: n.proposer === '0x0000000000000000000000000000000000000000' ? null : n.proposer,
      pending: n.pending,
      weight,
      children: [],
    }
    if (node.recipient) {
      node.owed = await publicClient.readContract({ ...fund, functionName: 'owed', args: [node.recipient] })
      return node
    }
    const [ids, weights] = await publicClient.readContract({ ...fund, functionName: 'getChildren', args: [id] })
    node.children = await Promise.all(ids.map((cid, i) => build(cid, weights[i])))
    if (epoch > 0n) {
      node.committee = [...(await publicClient.readContract({ ...fund, functionName: 'getCommittee', args: [epoch, id] }))]
      const [voters, vectors] = await publicClient.readContract({ ...fund, functionName: 'getVotes', args: [epoch, id] })
      node.votes = voters.map((v, i) => ({ voter: v, weights: vectors[i].map(Number) }))
    }
    return node
  }

  return {
    live: true,
    epoch: Number(epoch),
    nextAdvanceAt: Number(nextAt),
    drawPending: pending,
    seedBlock: seed,
    pool,
    totalOwed,
    totalStaked,
    keepers: Number(slots),
    harvestable,
    tree: await build(0, 10_000),
  }
}

// ------------------------------------------------------------------ wallet

declare global {
  interface Window {
    ethereum?: EIP1193Provider
  }
}

export async function connect() {
  if (!window.ethereum) throw new Error('No wallet found. Install a browser wallet to become a Keeper.')
  const wallet = createWalletClient({ chain: mainnet, transport: custom(window.ethereum) })
  const [account] = await wallet.requestAddresses()
  await wallet.switchChain({ id: mainnet.id }).catch(() => {})
  return { wallet, account }
}

type Wallet = Awaited<ReturnType<typeof connect>>

async function send(w: Wallet, req: Parameters<Wallet['wallet']['writeContract']>[0]) {
  const hash = await w.wallet.writeContract({ ...req, account: w.account, chain: mainnet } as never)
  return publicClient.waitForTransactionReceipt({ hash })
}

async function ensureAllowance(w: Wallet, spender: Address, amount: bigint) {
  const allowance = await publicClient.readContract({
    address: config.token as Address,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [w.account, spender],
  })
  if (allowance < amount) {
    await send(w, { address: config.token as Address, abi: erc20Abi, functionName: 'approve', args: [spender, amount] } as never)
  }
}

export const actions = {
  async stake(w: Wallet, amount: bigint) {
    await ensureAllowance(w, config.staking as Address, amount)
    return send(w, { address: config.staking as Address, abi: stakingAbi, functionName: 'stake', args: [amount] } as never)
  },
  unstake: (w: Wallet, amount: bigint) =>
    send(w, { address: config.staking as Address, abi: stakingAbi, functionName: 'unstake', args: [amount] } as never),
  vote: (w: Wallet, node: number, bps: number[]) =>
    send(w, { address: config.graphFund as Address, abi: fundAbi, functionName: 'vote', args: [node, bps] } as never),
  async propose(w: Wallet, parent: number, recipient: Address, name: string, bond: bigint) {
    await ensureAllowance(w, config.graphFund as Address, bond)
    return send(w, { address: config.graphFund as Address, abi: fundAbi, functionName: 'propose', args: [parent, recipient, name] } as never)
  },
  payout: (w: Wallet, to: Address) =>
    send(w, { address: config.graphFund as Address, abi: fundAbi, functionName: 'payout', args: [to] } as never),
  draw: (w: Wallet) => send(w, { address: config.graphFund as Address, abi: fundAbi, functionName: 'draw' } as never),
  advance: (w: Wallet) => send(w, { address: config.graphFund as Address, abi: fundAbi, functionName: 'advance' } as never),
  // Only the creator wallet has something to claim: the escrow pays straight into Graph Funding.
  harvest: (w: Wallet) =>
    send(w, { address: config.feeEscrow, abi: escrowAbi, functionName: 'claim', args: [config.weth, config.graphFund as Address] } as never),
}

export async function keeperView(account: Address, epoch: number, branchIds: number[]) {
  if (!deployed()) return null
  const staking = { address: config.staking as Address, abi: stakingAbi }
  const fund = { address: config.graphFund as Address, abi: fundAbi }
  const [stake, weight, balance, locked] = await Promise.all([
    publicClient.readContract({ ...staking, functionName: 'stakeOf', args: [account] }),
    publicClient.readContract({ ...staking, functionName: 'weightOf', args: [account] }),
    config.token
      ? publicClient.readContract({ address: config.token as Address, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
      : Promise.resolve(0n),
    publicClient.readContract({ ...staking, functionName: 'lockedEpoch', args: [account] }),
  ])
  const drawnFor: number[] = []
  if (epoch > 0) {
    const flags = await Promise.all(
      branchIds.map((id) => publicClient.readContract({ ...fund, functionName: 'isMember', args: [BigInt(epoch), BigInt(id), account] })),
    )
    flags.forEach((f, i) => f && drawnFor.push(branchIds[i]))
  }
  return { stake, weight, balance, locked: Number(locked), drawnFor }
}
