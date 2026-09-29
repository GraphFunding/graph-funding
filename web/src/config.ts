// Addresses are filled after the mainnet deploy (env at build time). Empty = "not deployed yet":
// the page shows the genesis tree from contracts/script/genesis.json and disables every write.
const env = import.meta.env

export const config = {
  rpcUrl: env.VITE_RPC_URL || 'https://ethereum-rpc.publicnode.com',
  graphFund: (env.VITE_GRAPHFUND || '') as `0x${string}` | '',
  staking: (env.VITE_STAKING || '') as `0x${string}` | '',
  badge: (env.VITE_BADGE || '') as `0x${string}` | '',
  token: (env.VITE_TOKEN || '') as `0x${string}` | '',
  creator: (env.VITE_CREATOR || '') as `0x${string}` | '',
  github: env.VITE_GITHUB || '',
  x: env.VITE_X || 'https://x.com/GraphFunding',
  // Stockereum (verified on mainnet: factory.hook().escrow())
  weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' as const,
  feeEscrow: '0xAcefe251da006887dA41C063D06CC82A060824BA' as const,
  factory: '0xc6B080DEd03C3382476A76345e79f82BD480977B' as const,
  book: 'https://vitalik.eth.limo/snowmoon/',
}

export const deployed = () => config.graphFund !== '' && config.staking !== ''

export const chapter = (n: number) => `${config.book}html/chapter-${n}.html`
