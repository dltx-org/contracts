/**
 * `pnpm test` for the strategy vault. The unit tests (HyperCore's precompiles and CoreWriter mocked to the
 * probe's recorded answers, no network) run whenever forge is installed. The fork tests run when their
 * RPC url is set and SKIP otherwise, so `turbo test` stays green on a machine without them:
 *   - Arbitrum (the real AAVE pool, the deployed receiver, Circle's CCTP): `ARBITRUM_RPC_URL`;
 *   - HyperEVM (CoreWriter, Circle's CoreDepositWallet and CCTP): `HYPEREVM_RPC_URL`, defaulting to the
 *     public endpoint https://rpc.hyperliquid.xyz/evm; skipped when it can't be reached.
 * The urls come from `.env` at the repository root (the file the engine reads) when the environment does not carry them.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const envFile = resolve(here, '../.env')
const wanted = ['ARBITRUM_RPC_URL', 'HYPEREVM_RPC_URL']

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
  console.log('strategy-vault: tests skipped — forge is not installed')
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
  console.error('strategy-vault: forge build --sizes gave no sizes')
  process.exit(built.status || 1)
}
const over = Object.entries(sizes).filter(
  ([, s]) => s.runtime_size > RUNTIME_LIMIT || s.init_size > INIT_LIMIT,
)
for (const [name, s] of over)
  console.error(
    `strategy-vault: ${name} is over the size limit: runtime ${s.runtime_size} B (limit ${RUNTIME_LIMIT}), init ${s.init_size} B (limit ${INIT_LIMIT})`,
  )
if (over.length > 0 || built.status !== 0) process.exit(1)

// Amendment 2a, invariant 11: every MEMBER CODE (the hub and each leg) keeps at least 4,096 bytes of room
// under EIP-170 at 2a's end, so amendment 2b's fee logic fits (an exit module carries a leg's exit when the
// leg would not).
const LEG_ROOM = 4_096
const LEGS = ['StrategyHub', 'LongVault', 'ShortVault']
const cramped = LEGS.filter(
  (name) => !sizes[name] || RUNTIME_LIMIT - sizes[name].runtime_size < LEG_ROOM,
)
for (const name of cramped)
  console.error(
    `strategy-vault: member ${name} leaves ${sizes[name] ? RUNTIME_LIMIT - sizes[name].runtime_size : '?'} B under EIP-170, under the ${LEG_ROOM} B amendment 2a keeps for 2b`,
  )
if (cramped.length > 0) process.exit(1)

// A module (a leg's exit module, the hub's fee module) runs by DELEGATECALL in its member's storage: their
// layouts must be the same, slot for slot.
const layout = (name) => {
  const out = spawnSync('forge', ['inspect', name, 'storageLayout', '--json'], {
    cwd: here,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  })
  if (out.status !== 0) {
    process.stderr.write(out.stderr)
    process.exit(out.status || 1)
  }
  return JSON.parse(out.stdout.slice(out.stdout.indexOf('{'))).storage.map(
    // a struct's type carries its AST id, which differs between two compilations of the same source
    ({ label, slot, offset, type }) =>
      `${slot}:${offset} ${label} ${type.replace(/(t_struct\(\w+\))\d+/g, '$1')}`,
  )
}
for (const [leg, module] of [
  ['LongVault', 'LongVaultExit'],
  ['ShortVault', 'ShortVaultExit'],
  ['StrategyHub', 'StrategyHubFee'],
]) {
  const a = layout(leg)
  const b = layout(module)
  if (a.length !== b.length || a.some((x, i) => x !== b[i])) {
    console.error(
      `strategy-vault: ${module}'s storage layout differs from ${leg}'s:\n  ${a.join('\n  ')}\nvs\n  ${b.join('\n  ')}`,
    )
    process.exit(1)
  }
}

// The deploy script refuses any build but the tests' pinned one: the same eight hashes in both files.
const pinsOf = (file) =>
  [
    ...readFileSync(resolve(here, file), 'utf8').matchAll(
      /bytes32 constant (\w+_CODE) = (0x[0-9a-fA-F]+);/g,
    ),
  ]
    .map((m) => `${m[1]}=${m[2].toLowerCase()}`)
    .sort()
const tested = pinsOf('test/Pinned.t.sol')
const deployed = pinsOf('script/Deploy.s.sol')
if (tested.length !== 8 || JSON.stringify(tested) !== JSON.stringify(deployed)) {
  console.error('strategy-vault: script/Deploy.s.sol and test/Pinned.t.sol pin different builds')
  process.exit(1)
}
const [largest, most] = Object.entries(sizes).sort(
  ([, a], [, b]) => b.runtime_size - a.runtime_size,
)[0]
console.log(
  `strategy-vault: every contract within EIP-170 and EIP-3860; the largest, ${largest}, ${most.runtime_size} B (margin ${RUNTIME_LIMIT - most.runtime_size} B); the member codes keep their ${LEG_ROOM} B; each module's storage is its member's`,
)
if (!process.env.ARBITRUM_RPC_URL)
  console.log('strategy-vault: Arbitrum fork tests skipped — ARBITRUM_RPC_URL not set')
// The fork suites skip themselves (vm.skip) when their url is absent; the unit suites always run.
const run = spawnSync('forge', ['test', '-vv'], { cwd: here, stdio: 'inherit', env: process.env })
process.exit(run.status ?? 1)
