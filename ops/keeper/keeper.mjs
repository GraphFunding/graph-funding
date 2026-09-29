// Graph Funding keeper. One run does the whole cycle: advance() when the epoch is over, then wait until the seed
// block is mined and draw(). If draw() asks for a new seed instead of drawing (stale seed, or the stake freeze
// expired), it waits for the new one and draws again, at most 3 draw() calls per run. It never sends a tx that the
// current state says would revert, and after each of its txs it only decides on state read at or after the receipt's
// block (a load-balanced RPC can answer from a node that is still behind it).
// Env:
//   RPC_URL, GRAPHFUND_ADDRESS
//   KEEPER_PRIVATE_KEY  a small wallet that only pays gas (without it the run only reads)
//   DRY_RUN             1 or true: only print what it would do
//   MIN_BALANCE_ETH     default 0.05. Below it the run still does its work, then exits with code 1 so GitHub emails
//                       the owner to top the wallet up.
import { createPublicClient, createWalletClient, formatEther, http, parseAbi, parseEther } from 'viem'
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

const POLL_MS = 4_000 // ~one poll per 12 s block is plenty
const SEED_WAIT_MS = 180_000 // the seed block is 5 blocks (~1 min) after the request
const MAX_DRAWS = 3
const READ_TRIES = 10 // ~40 s for a lagging RPC backend to reach the block of our last receipt
const DEFAULT_MIN_BALANCE = '0.05'

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const log = (msg, data) => console.log(data === undefined ? msg : `${msg} ${JSON.stringify(data)}`)

async function main() {
  const { RPC_URL, GRAPHFUND_ADDRESS, KEEPER_PRIVATE_KEY, DRY_RUN, MIN_BALANCE_ETH } = process.env
  if (!RPC_URL || !GRAPHFUND_ADDRESS) {
    log('RPC_URL / GRAPHFUND_ADDRESS not set, nothing to do')
    return
  }
  const dryRun = ['1', 'true'].includes(String(DRY_RUN ?? '').trim().toLowerCase())
  let minEth = String(MIN_BALANCE_ETH ?? '').trim() || DEFAULT_MIN_BALANCE
  if (!/^\d+(\.\d+)?$/.test(minEth)) {
    log(`MIN_BALANCE_ETH "${minEth}" is not a number, using ${DEFAULT_MIN_BALANCE}`)
    minEth = DEFAULT_MIN_BALANCE
  }
  const minBalance = parseEther(minEth)

  const chain = { ...mainnet, rpcUrls: { default: { http: [RPC_URL] } } }
  const pub = createPublicClient({ chain, transport: http(RPC_URL) })
  const fund = { address: GRAPHFUND_ADDRESS, abi }
  const account = KEEPER_PRIVATE_KEY ? privateKeyToAccount(KEEPER_PRIVATE_KEY) : undefined
  const wallet = account && createWalletClient({ account, chain, transport: http(RPC_URL) })

  let lowBalance = false
  if (account) {
    const balance = await pub.getBalance({ address: account.address })
    lowBalance = balance < minBalance
    log('keeper wallet', { address: account.address, balanceEth: formatEther(balance), minEth, low: lowBalance })
  } else {
    log('KEEPER_PRIVATE_KEY not set: read-only run')
  }
  const canSend = Boolean(wallet) && !dryRun
  const why = dryRun ? 'DRY_RUN' : 'no KEEPER_PRIVATE_KEY'

  // Reads the whole state at one block. `minBlock` is the block of our last receipt (or of the previous read): the
  // head must have reached it, so a node that is still behind never makes us resend a tx that already landed (a
  // second draw() would revert). A read from a lagging node, or one that fails, is retried every POLL_MS.
  const read = async (minBlock = 0n) => {
    for (let attempt = 1; ; attempt++) {
      try {
        const head = await pub.getBlock()
        if (head.number < minBlock) throw new Error(`RPC head ${head.number} is behind block ${minBlock}`)
        const at = { blockNumber: head.number }
        const [epoch, nextAt, pending, seed] = await Promise.all([
          pub.readContract({ ...fund, functionName: 'epoch', ...at }),
          pub.readContract({ ...fund, functionName: 'nextAdvanceAt', ...at }),
          pub.readContract({ ...fund, functionName: 'drawPending', ...at }),
          pub.readContract({ ...fund, functionName: 'seedBlock', ...at }),
        ])
        return { epoch, nextAt, pending, seed, block: head.number, timestamp: head.timestamp }
      } catch (e) {
        if (attempt >= READ_TRIES) throw e
        log(`state read failed, retry ${attempt}/${READ_TRIES - 1}`, { reason: e.shortMessage ?? e.message })
        await sleep(POLL_MS)
      }
    }
  }
  const show = (s) => ({
    epoch: String(s.epoch),
    nextAt: String(s.nextAt),
    pending: s.pending,
    seedBlock: String(s.seed),
    block: String(s.block),
    timestamp: String(s.timestamp),
  })

  // Simulates against the latest state first: a call that would revert is logged and not sent (returns null).
  // Otherwise returns the receipt, whose block the next read must reach.
  const send = async (functionName) => {
    try {
      await pub.simulateContract({ ...fund, functionName, account })
    } catch (e) {
      log(`${functionName}() would revert, not sent`, { reason: e.shortMessage ?? e.message })
      return null
    }
    const hash = await wallet.writeContract({ ...fund, functionName })
    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: SEED_WAIT_MS })
    log(`${functionName}()`, {
      hash,
      status: receipt.status,
      block: String(receipt.blockNumber),
      gasUsed: String(receipt.gasUsed),
    })
    if (receipt.status !== 'success') throw new Error(`${functionName}() reverted: ${hash}`)
    return receipt
  }

  // Polls until the seed block is mined (block > seedBlock), someone else drew, or the wait runs out.
  const waitPastSeed = async (s) => {
    const deadline = Date.now() + SEED_WAIT_MS
    log('waiting for the seed block', { seedBlock: String(s.seed), block: String(s.block) })
    while (s.pending && s.block <= s.seed && Date.now() < deadline) {
      await sleep(POLL_MS)
      s = await read(s.block)
    }
    return s
  }

  let s = await read()
  log('state', show(s))

  // 1. Close the epoch if it is over.
  if (s.epoch > 0n && s.timestamp >= s.nextAt) {
    if (!canSend) {
      log(`advance() is due, not sent (${why})`)
    } else {
      const receipt = await send('advance')
      s = await read(receipt ? receipt.blockNumber : s.block)
    }
  }

  // 2. Draw the committees once the seed block exists; again if draw() asked for a new seed.
  for (let attempt = 1; attempt <= MAX_DRAWS && s.pending; attempt++) {
    if (!canSend) {
      log(`draw() pending, not sent (${why})`, { seedBlock: String(s.seed), block: String(s.block) })
      break
    }
    if (s.block <= s.seed) {
      s = await waitPastSeed(s)
      if (!s.pending) {
        log('someone else already drew')
        break
      }
      if (s.block <= s.seed) {
        log('seed block not mined in time, the next run draws', show(s))
        break
      }
    }
    const receipt = await send('draw')
    if (!receipt) break
    s = await read(receipt.blockNumber)
    if (s.pending) log(`draw() asked for a new seed (stale seed or expired freeze), attempt ${attempt}/${MAX_DRAWS}`, show(s))
    else log('committees drawn', { epoch: String(s.epoch) })
  }

  if (lowBalance) {
    console.error(`keeper wallet below MIN_BALANCE_ETH (${minEth} ETH): top it up`)
    process.exitCode = 1
  }
}

main().catch((e) => {
  console.error(e)
  process.exitCode = 1
})
