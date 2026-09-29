// Calls advance() when the epoch is over and draw() when the seed block is mined.
// Env: RPC_URL, GRAPHFUND_ADDRESS, KEEPER_PRIVATE_KEY (a small wallet that only pays gas). DRY_RUN=1 to only print.
import { createPublicClient, createWalletClient, http, parseAbi } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { mainnet } from 'viem/chains'

const abi = parseAbi([
  'function epoch() view returns (uint256)',
  'function nextAdvanceAt() view returns (uint256)',
  'function drawPending() view returns (bool)',
  'function seedBlock() view returns (uint256)',
  'function advance()',
  'function draw()',
])

const { RPC_URL, GRAPHFUND_ADDRESS, KEEPER_PRIVATE_KEY, DRY_RUN } = process.env
if (!RPC_URL || !GRAPHFUND_ADDRESS) {
  console.log('RPC_URL / GRAPHFUND_ADDRESS not set, nothing to do')
  process.exit(0)
}
const chain = { ...mainnet, rpcUrls: { default: { http: [RPC_URL] } } }
const pub = createPublicClient({ chain, transport: http(RPC_URL) })
const fund = { address: GRAPHFUND_ADDRESS, abi }

const [epoch, nextAt, pending, seed, block, latest] = await Promise.all([
  pub.readContract({ ...fund, functionName: 'epoch' }),
  pub.readContract({ ...fund, functionName: 'nextAdvanceAt' }),
  pub.readContract({ ...fund, functionName: 'drawPending' }),
  pub.readContract({ ...fund, functionName: 'seedBlock' }),
  pub.getBlockNumber(),
  pub.getBlock(),
])

let action = null
if (epoch > 0n && latest.timestamp >= nextAt) action = 'advance'
else if (pending && block > seed) action = 'draw'
console.log(JSON.stringify({ epoch: String(epoch), nextAt: String(nextAt), pending, seed: String(seed), block: String(block), action }))
if (!action || DRY_RUN) process.exit(0)
if (!KEEPER_PRIVATE_KEY) {
  console.log('KEEPER_PRIVATE_KEY not set, skipping tx')
  process.exit(0)
}
const wallet = createWalletClient({ account: privateKeyToAccount(KEEPER_PRIVATE_KEY), chain, transport: http(RPC_URL) })
const hash = await wallet.writeContract({ ...fund, functionName: action })
const receipt = await pub.waitForTransactionReceipt({ hash })
console.log(`${action} → ${hash} (${receipt.status})`)
