/**
 * `pnpm test` for the deposit account: the unit tests (no fork) run whenever forge is installed; the
 * fork tests against the real chains run when Arbitrum's RPC url is present and SKIP otherwise, so
 * `turbo test` stays green on a machine without it. HyperEVM's fork uses `HYPEREVM_RPC_URL`, or the
 * public RPC (https://rpc.hyperliquid.xyz/evm, no key) when the forks run at all; Ethereum and Base
 * join the every-chain test when `MAINNET_RPC_URL` and `BASE_RPC_URL` are set. The urls come from
 * `.env` at the repository root when the environment does not already carry them.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const envFile = resolve(here, '../.env')
const wanted = ['ARBITRUM_RPC_URL', 'HYPEREVM_RPC_URL', 'MAINNET_RPC_URL', 'BASE_RPC_URL']
const HYPEREVM_PUBLIC_RPC = 'https://rpc.hyperliquid.xyz/evm'

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
  console.log('deposit-account: tests skipped — forge is not installed')
  process.exit(0)
}
if (!existsSync(resolve(here, 'dependencies'))) {
  const dep = spawnSync('forge', ['soldeer', 'install'], { cwd: here, stdio: 'inherit' })
  if (dep.status !== 0) process.exit(dep.status ?? 1)
}
// EIP-170 and EIP-3860: a chain refuses runtime code over 24,576 bytes and init code over 49,152, but
// forge's test EVM deploys either without complaint, so a contract can pass every test here and still
// revert on deployment (DepositAccount did, at 29,535 B). Every contract's size is measured before any
// test, with or without the RPC urls.
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
  console.error('deposit-account: forge build --sizes gave no sizes')
  process.exit(built.status || 1)
}
const over = Object.entries(sizes).filter(
  ([, s]) => s.runtime_size > RUNTIME_LIMIT || s.init_size > INIT_LIMIT,
)
for (const [name, s] of over)
  console.error(
    `deposit-account: ${name} is over the size limit: runtime ${s.runtime_size} B (limit ${RUNTIME_LIMIT}), init ${s.init_size} B (limit ${INIT_LIMIT})`,
  )
if (over.length > 0 || built.status !== 0) process.exit(1)
const [largest, most] = Object.entries(sizes).sort(
  ([, a], [, b]) => b.runtime_size - a.runtime_size,
)[0]
console.log(
  `deposit-account: every contract within EIP-170 and EIP-3860; the largest, ${largest}, ${most.runtime_size} B (margin ${RUNTIME_LIMIT - most.runtime_size} B)`,
)
// The deploy script refuses any build but the tests' pinned one: the same creation-code hash in both
// files (the combined security review's CR-F5).
const pinOf = (file) =>
  readFileSync(resolve(here, file), 'utf8')
    .match(/bytes32 constant PINNED_CREATION_CODE_HASH = (0x[0-9a-fA-F]+);/)?.[1]
    ?.toLowerCase()
const testedPin = pinOf('test/DepositFactory.t.sol')
if (!testedPin || testedPin !== pinOf('script/Deploy.s.sol')) {
  console.error(
    'deposit-account: script/Deploy.s.sol and test/DepositFactory.t.sol pin different builds',
  )
  process.exit(1)
}
if (!process.env.ARBITRUM_RPC_URL) {
  console.log('deposit-account: fork tests skipped — ARBITRUM_RPC_URL not set')
  const unit = spawnSync('forge', ['test', '-vv', '--no-match-contract', 'ForkTest'], {
    cwd: here,
    stdio: 'inherit',
  })
  process.exit(unit.status ?? 1)
}
if (!process.env.HYPEREVM_RPC_URL) process.env.HYPEREVM_RPC_URL = HYPEREVM_PUBLIC_RPC
const absent = ['MAINNET_RPC_URL', 'BASE_RPC_URL'].filter((k) => !process.env[k])
if (absent.length > 0) console.log(`deposit-account: chains skipped — ${absent.join(', ')} not set`)
const run = spawnSync('forge', ['test', '-vv'], { cwd: here, stdio: 'inherit' })
if (run.status !== 0) process.exit(run.status ?? 1)
// Arbitrum's P-256 precompile (RIP-7212) is not simulated by forge's default runtime; Osaka's
// P256VERIFY (EIP-7951) is the same address, input and output, so the precompile path is run there.
// The build itself stays `cancun`: only the runtime of this one test changes.
const precompile = spawnSync(
  'forge',
  [
    'test',
    '-vv',
    '--hardfork',
    'osaka',
    '--match-test',
    'test_arbitrum_thePasskeyUsesThePrecompile',
  ],
  { cwd: here, stdio: 'inherit' },
)
process.exit(precompile.status ?? 1)
