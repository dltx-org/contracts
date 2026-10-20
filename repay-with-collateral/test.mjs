/**
 * `pnpm test` for the receiver: Foundry fork tests against the real pools, gated the way the
 * database suites are — they run when the engine's RPC urls are present and SKIP otherwise, so
 * `turbo test` stays green on a machine without them. The urls come from `.env` at the repository root (the file
 * the engine reads) when the environment does not already carry them.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const envFile = resolve(here, '../.env')
const wanted = ['ARBITRUM_RPC_URL', 'MAINNET_RPC_URL']

if (existsSync(envFile)) {
  for (const line of readFileSync(envFile, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim())
    if (!m) continue
    const [, key, raw] = m
    if (!wanted.includes(key) || process.env[key]) continue
    process.env[key] = raw.replace(/^["']|["']$/g, '')
  }
}

if (spawnSync('forge', ['--version'], { stdio: 'ignore' }).status !== 0) {
  console.log('repay-with-collateral: tests skipped — forge is not installed')
  process.exit(0)
}
if (!existsSync(resolve(here, 'dependencies'))) {
  const dep = spawnSync('forge', ['soldeer', 'install'], { cwd: here, stdio: 'inherit' })
  if (dep.status !== 0) process.exit(dep.status ?? 1)
}
// EIP-170 and EIP-3860: a chain refuses runtime code over 24,576 bytes and init code over 49,152, but
// forge's test EVM deploys either without complaint, so a contract can pass every test here and still
// revert on deployment. Every contract's size is measured before any test, with or without the RPC urls.
const RUNTIME_LIMIT = 24_576
const INIT_LIMIT = 49_152
const built = spawnSync('forge', ['build', '--sizes', '--json'], {
  cwd: here,
  encoding: 'utf8',
  maxBuffer: 64 * 1024 * 1024,
})
let sizes
try {
  sizes = JSON.parse(built.stdout.slice(Math.max(0, built.stdout.indexOf('{'))))
} catch {
  process.stderr.write(built.stdout + built.stderr)
  console.error('repay-with-collateral: forge build --sizes gave no sizes')
  process.exit(built.status || 1)
}
const over = Object.entries(sizes).filter(
  ([, s]) => s.runtime_size > RUNTIME_LIMIT || s.init_size > INIT_LIMIT,
)
for (const [name, s] of over)
  console.error(
    `repay-with-collateral: ${name} is over the size limit: runtime ${s.runtime_size} B (limit ${RUNTIME_LIMIT}), init ${s.init_size} B (limit ${INIT_LIMIT})`,
  )
if (over.length > 0 || built.status !== 0) process.exit(1)
const [largest, most] = Object.entries(sizes).sort(
  ([, a], [, b]) => b.runtime_size - a.runtime_size,
)[0]
console.log(
  `repay-with-collateral: every contract within EIP-170 and EIP-3860; the largest, ${largest}, ${most.runtime_size} B (margin ${RUNTIME_LIMIT - most.runtime_size} B)`,
)
const missing = wanted.filter((k) => !process.env[k])
if (missing.length > 0) {
  console.log(`repay-with-collateral: fork tests skipped — ${missing.join(', ')} not set`)
  process.exit(0)
}
const run = spawnSync('forge', ['test', '-vv'], { cwd: here, stdio: 'inherit' })
process.exit(run.status ?? 1)
