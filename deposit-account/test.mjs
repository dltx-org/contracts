/**
 * `pnpm test` for the deposit account: the unit tests (no fork) run whenever forge is installed; the
 * fork tests against the real chains run when Arbitrum's RPC url is present and SKIP otherwise, so
 * `turbo test` stays green on a machine without it. HyperEVM's fork uses `HYPEREVM_RPC_URL`, or the
 * public RPC (https://rpc.hyperliquid.xyz/evm, no key) when the forks run at all, and Avalanche's
 * `AVALANCHE_RPC_URL`, or its public RPC (https://api.avax.network/ext/bc/C/rpc, no key); Ethereum and Base
 * join the every-chain test when `MAINNET_RPC_URL` and `BASE_RPC_URL` are set. The urls come from
 * `.env` at the repository root when the environment does not already carry them.
 */
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const envFile = resolve(here, '../.env')
const wanted = [
  'ARBITRUM_RPC_URL',
  'HYPEREVM_RPC_URL',
  'AVALANCHE_RPC_URL',
  'MAINNET_RPC_URL',
  'BASE_RPC_URL',
]
const HYPEREVM_PUBLIC_RPC = 'https://rpc.hyperliquid.xyz/evm'
const AVALANCHE_PUBLIC_RPC = 'https://api.avax.network/ext/bc/C/rpc'

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
// The seam test's fixtures are the vault's pinned build: its eight hashes are the vault project's (the
// partner's audit L1; `test_seam_theFixturesAreThePinnedBuild` checks the files against them).
const vaultPins = (file) =>
  [
    ...readFileSync(resolve(here, file), 'utf8').matchAll(
      /bytes32 constant (\w+_CODE) = (0x[0-9a-fA-F]+);/g,
    ),
  ]
    .map((m) => `${m[1]}=${m[2].toLowerCase()}`)
    .sort()
const seamPins = vaultPins('test/Seam.t.sol')
if (
  seamPins.length !== 8 ||
  JSON.stringify(seamPins) !== JSON.stringify(vaultPins('../strategy-vault/test/Pinned.t.sol'))
) {
  console.error("deposit-account: test/Seam.t.sol does not pin the vault project's eight hashes")
  process.exit(1)
}
// The storage layout (owner-upgrades-design.md §A6, I7): one sequential layout from slot 0, shared by
// the account and its record module, append only from version to version. `forge inspect` gives each
// contract's; the AST ids in struct type names are dropped, and every type is expanded to its members,
// so two builds compare by shape alone. The two contracts must be equal; version 1's pinned file
// (layout/DepositAccount.v1.json, `node test.mjs --pin-layout` writes it, before the first
// deployment only) must be a prefix of each; the test version 2 must extend it too, which proves the
// prefix rule reads an appended field as allowed.
const layoutOf = (name) => {
  const out = spawnSync('forge', ['inspect', name, 'storageLayout', '--json'], {
    cwd: here,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  })
  if (out.status !== 0) {
    process.stderr.write(out.stderr)
    console.error(`deposit-account: forge inspect ${name} storageLayout failed`)
    process.exit(1)
  }
  const raw = JSON.parse(out.stdout.slice(out.stdout.indexOf('{')))
  const norm = (t) => t.replace(/\)\d+(_storage|_memory_ptr|_calldata_ptr)?/g, ')$1')
  const expand = (t, seen = []) => {
    const d = raw.types[t]
    const e = { type: norm(t), encoding: d.encoding, bytes: d.numberOfBytes }
    if (seen.includes(t)) return e
    if (d.members)
      e.members = d.members.map((m) => ({
        label: m.label,
        slot: m.slot,
        offset: m.offset,
        ...expand(m.type, [...seen, t]),
      }))
    if (d.key) e.key = expand(d.key, [...seen, t])
    if (d.value) e.value = expand(d.value, [...seen, t])
    if (d.base) e.base = expand(d.base, [...seen, t])
    return e
  }
  return raw.storage.map((v) => ({
    label: v.label,
    slot: v.slot,
    offset: v.offset,
    ...expand(v.type),
  }))
}
const pinnedLayout = resolve(here, 'layout/DepositAccount.v1.json')
const mainLayout = layoutOf('DepositAccount')
if (process.argv.includes('--pin-layout')) {
  mkdirSync(dirname(pinnedLayout), { recursive: true })
  writeFileSync(pinnedLayout, `${JSON.stringify(mainLayout, null, 2)}\n`)
  console.log(
    `deposit-account: version 1's layout pinned in ${pinnedLayout}; set LAYOUT_V1_SHA256 to its sha256`,
  )
  process.exit(0)
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const isPrefix = (pin, layout) =>
  pin.length <= layout.length && pin.every((v, i) => same(v, layout[i]))
// version 1's file is frozen by its hash: re-pinning it is a decision, never a side effect
const LAYOUT_V1_SHA256 = '7ba58c46296c6067eb9303a028add45e3812c2f6d7c5fbe51cb0def8d625067d'
const pinnedText = readFileSync(pinnedLayout, 'utf8')
if (createHash('sha256').update(pinnedText).digest('hex') !== LAYOUT_V1_SHA256) {
  console.error("deposit-account: layout/DepositAccount.v1.json is not version 1's pinned layout")
  process.exit(1)
}
const pinned = JSON.parse(pinnedText)
const layoutFailures = [
  !same(mainLayout, layoutOf('DepositAccountRecord')) &&
    "DepositAccountRecord does not share DepositAccount's layout",
  !isPrefix(pinned, mainLayout) && "DepositAccount's layout does not extend version 1's pinned one",
  !isPrefix(pinned, layoutOf('DepositAccountV2')) &&
    "the test version 2 does not extend version 1's layout",
  !isPrefix(pinned, layoutOf('DepositAccountRecordV2')) &&
    "the test version 2's module does not extend version 1's layout",
  !same(layoutOf('DepositAccountV2'), layoutOf('DepositAccountRecordV2')) &&
    "the test version 2's two contracts differ",
].filter(Boolean)
for (const f of layoutFailures) console.error(`deposit-account: ${f}`)
if (layoutFailures.length > 0) process.exit(1)
console.log(
  `deposit-account: storage layout append-only against version 1 (${pinned.length} fields), module equal`,
)
if (!process.env.ARBITRUM_RPC_URL) {
  console.log('deposit-account: fork tests skipped — ARBITRUM_RPC_URL not set')
  const unit = spawnSync('forge', ['test', '-vv', '--no-match-contract', 'ForkTest'], {
    cwd: here,
    stdio: 'inherit',
  })
  process.exit(unit.status ?? 1)
}
if (!process.env.HYPEREVM_RPC_URL) process.env.HYPEREVM_RPC_URL = HYPEREVM_PUBLIC_RPC
if (!process.env.AVALANCHE_RPC_URL) process.env.AVALANCHE_RPC_URL = AVALANCHE_PUBLIC_RPC
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
