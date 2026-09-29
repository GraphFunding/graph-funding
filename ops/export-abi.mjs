// Copies the compiled ABIs into the site. Run after `forge build`: node ops/export-abi.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const outDir = join(root, 'web', 'src', 'abi')
mkdirSync(outDir, { recursive: true })
for (const name of ['GraphFund', 'KeeperStaking', 'KeeperBadge']) {
  const art = JSON.parse(readFileSync(join(root, 'contracts', 'out', `${name}.sol`, `${name}.json`), 'utf8'))
  writeFileSync(join(outDir, `${name}.json`), JSON.stringify(art.abi, null, 2) + '\n')
  console.log(`abi → web/src/abi/${name}.json (${art.abi.length} entries)`)
}
