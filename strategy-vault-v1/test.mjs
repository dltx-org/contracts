/**
 * `pnpm test` for version 1 of the strategy vaults (its own project: in one compilation with version 0, the
 * version-1 test files moved version 0's pinned via-IR bytecode, so version 0 stays alone in
 * contracts/strategy-vault). The unit tests (HyperCore's precompiles and CoreWriter mocked to the
 * probe's recorded answers, no network) run whenever forge is installed. The fork tests run when their
 * RPC url is set and SKIP otherwise, so `turbo test` stays green on a machine without them:
 *   - Arbitrum (the real AAVE pool, the deployed receiver, Circle's CCTP): `ARBITRUM_RPC_URL`;
 *   - HyperEVM (CoreWriter, Circle's CoreDepositWallet and CCTP): `HYPEREVM_RPC_URL`, defaulting to the
 *     public endpoint https://rpc.hyperliquid.xyz/evm; skipped when it can't be reached.
 * The urls come from `.env` at the repository root (the file the engine reads) when the environment does not carry them.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
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
  console.log('strategy-vault-v1: tests skipped — forge is not installed')
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
  console.error('strategy-vault-v1: forge build --sizes gave no sizes')
  process.exit(built.status || 1)
}
const over = Object.entries(sizes).filter(
  ([, s]) => s.runtime_size > RUNTIME_LIMIT || s.init_size > INIT_LIMIT,
)
for (const [name, s] of over)
  console.error(
    `strategy-vault-v1: ${name} is over the size limit: runtime ${s.runtime_size} B (limit ${RUNTIME_LIMIT}), init ${s.init_size} B (limit ${INIT_LIMIT})`,
  )
if (over.length > 0 || built.status !== 0) process.exit(1)

// Version 1 (asset-profiles-design.md Q9): the 4,096 B room rule is dropped for upgradeable members; each
// keeps at least 1,024 B under EIP-170 (a version needing more splits into a module). Modules: EIP-170 alone.
const V1_ROOM = 1_024
const V1_MEMBERS = ['Hub', 'AaveV3AssetLeg', 'HyperCoreLeg']
const crampedV1 = V1_MEMBERS.filter(
  (name) => !sizes[name] || RUNTIME_LIMIT - sizes[name].runtime_size < V1_ROOM,
)
for (const name of crampedV1)
  console.error(
    `strategy-vault-v1: version-1 member ${name} leaves ${sizes[name] ? RUNTIME_LIMIT - sizes[name].runtime_size : '?'} B under EIP-170, under the ${V1_ROOM} B Q9 keeps`,
  )
if (crampedV1.length > 0) process.exit(1)

// A module (a leg's exit module, the hub's fee module) runs by DELEGATECALL in its member's storage: their
// layouts must be the same, slot for slot. Each entry is one line: its slot, offset and label, then its
// type expanded to its members (a struct's fields with their slots, offsets and types, a mapping's key and
// value, an array's base), recursively, with the AST ids that differ between two compilations of the same
// source dropped: so a field reordered or retyped INSIDE a stored struct changes the line (Codex on the
// integration, 2026-10-23: the type name alone hid it), as the deposit project's guard already does.
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
  return raw.storage.map(
    ({ label, slot, offset, type }) => `${slot}:${offset} ${label} ${JSON.stringify(expand(type))}`,
  )
}
// The guard must see inside a struct: two members of the first stored struct swapped must read as a
// different layout (else the comparisons below would pass a reordered struct).
{
  const hub = layout('Hub')
  const i = hub.findIndex((x) => x.includes('"members"'))
  const [head, json] = [
    hub[i].slice(0, hub[i].indexOf('{')),
    JSON.parse(hub[i].slice(hub[i].indexOf('{'))),
  ]
  const m = json.members
  if (i < 0 || m.length < 2) {
    console.error('strategy-vault-v1: the layout guard found no stored struct to check itself on')
    process.exit(1)
  }
  ;[m[0], m[1]] = [
    { ...m[1], slot: m[0].slot, offset: m[0].offset },
    { ...m[0], slot: m[1].slot, offset: m[1].offset },
  ]
  if (`${head}${JSON.stringify(json)}` === hub[i]) {
    console.error("strategy-vault-v1: the layout guard does not see a struct's members")
    process.exit(1)
  }
}
for (const [leg, module] of [
  ['Hub', 'HubFee'],
  ['AaveV3AssetLeg', 'AaveV3AssetLegExit'],
  ['AaveV3AssetLeg', 'AaveV3AssetLegRewards'],
  ['HyperCoreLeg', 'HyperCoreLegExit'],
  ['HyperCoreLeg', 'HyperCoreLegExitB'],
]) {
  const a = layout(leg)
  const b = layout(module)
  if (a.length !== b.length || a.some((x, i) => x !== b[i])) {
    console.error(
      `strategy-vault-v1: ${module}'s storage layout differs from ${leg}'s:\n  ${a.join('\n  ')}\nvs\n  ${b.join('\n  ')}`,
    )
    process.exit(1)
  }
}

// Version 1 (owner-upgrades-design.md §A6, Q7: one append-only layout per family). The shared upgrade
// module knows only `MemberState`: its layout must be a PREFIX of every member's. Each member's layout
// must keep its pinned file (`layouts/<Member>.txt`) as a prefix: a later version appends, never
// reorders, retypes or drops a field (`UPDATE_LAYOUTS=1 node test.mjs` writes the files, for a new
// version only, never to make a changed layout pass).
const upgradeLayout = layout('VaultUpgrade')
const layoutDir = resolve(here, 'layouts')
for (const member of V1_MEMBERS) {
  const a = layout(member)
  if (upgradeLayout.some((x, i) => x !== a[i])) {
    console.error(
      `strategy-vault-v1: VaultUpgrade's storage layout is not a prefix of ${member}'s:\n  ${upgradeLayout.join('\n  ')}\nvs\n  ${a.join('\n  ')}`,
    )
    process.exit(1)
  }
  const file = resolve(layoutDir, `${member}.txt`)
  if (process.env.UPDATE_LAYOUTS === '1') {
    mkdirSync(layoutDir, { recursive: true })
    writeFileSync(file, `${a.join('\n')}\n`)
  }
  if (!existsSync(file)) {
    console.error(`strategy-vault-v1: no pinned layout for ${member} (${file})`)
    process.exit(1)
  }
  const pinned = readFileSync(file, 'utf8').trim().split('\n')
  if (pinned.some((x, i) => x !== a[i])) {
    console.error(
      `strategy-vault-v1: ${member}'s storage layout no longer starts with its pinned one (layouts/${member}.txt): append only`,
    )
    process.exit(1)
  }
}

// The shared proxy (owner-upgrades-design.md §A1): ONE init code for the deposit contract and every member.
// src/ProxyInitCode.sol is a byte-for-byte copy of the deposit project's; a drift would move every
// member's address away from the engine's.
const proxyOf = (file) => {
  const text = readFileSync(file, 'utf8')
  const code = /INIT_CODE =\s*hex"([0-9a-f]+)"/.exec(text)
  const hash = /HASH = (0x[0-9a-f]{64})/.exec(text)
  return `${code?.[1]}:${hash?.[1]}`
}
const depositProxy = resolve(here, '../deposit-account/src/ProxyInitCode.sol')
if (existsSync(depositProxy)) {
  if (proxyOf(depositProxy) !== proxyOf(resolve(here, 'src/ProxyInitCode.sol'))) {
    console.error(
      'strategy-vault-v1: src/ProxyInitCode.sol differs from contracts/deposit-account/src/ProxyInitCode.sol',
    )
    process.exit(1)
  }
} else {
  console.log(
    'strategy-vault: the deposit project has no ProxyInitCode.sol on this branch yet; the copy is checked once it lands',
  )
}

// ...and version 1's pinned build likewise: the same eleven creation-code hashes, six module runtime
// hashes and three implementation runtime hashes (the genesis) in test/PinnedV1.t.sol and script/DeployV1.s.sol
const v1PinsOf = (file) =>
  [
    ...readFileSync(resolve(here, file), 'utf8').matchAll(
      /bytes32 constant (V1_\w+_(?:CODE|RUNTIME_HASH)) = (0x[0-9a-fA-F]+);/g,
    ),
  ]
    .map((m) => `${m[1]}=${m[2].toLowerCase()}`)
    .sort()
const v1Tested = v1PinsOf('test/PinnedV1.t.sol')
if (
  v1Tested.length !== 20 ||
  JSON.stringify(v1Tested) !== JSON.stringify(v1PinsOf('script/DeployV1.s.sol'))
) {
  console.error(
    'strategy-vault-v1: script/DeployV1.s.sol and test/PinnedV1.t.sol pin different builds',
  )
  process.exit(1)
}
const [largest, most] = Object.entries(sizes).sort(
  ([, a], [, b]) => b.runtime_size - a.runtime_size,
)[0]
console.log(
  `strategy-vault-v1: every contract within EIP-170 and EIP-3860; the largest, ${largest}, ${most.runtime_size} B (margin ${RUNTIME_LIMIT - most.runtime_size} B); the members keep their ${V1_ROOM} B; each module's storage is its member's`,
)
if (!process.env.ARBITRUM_RPC_URL)
  console.log('strategy-vault-v1: Arbitrum fork tests skipped — ARBITRUM_RPC_URL not set')
// The fork suites skip themselves (vm.skip) when their url is absent; the unit suites always run.
const run = spawnSync('forge', ['test', '-vv'], { cwd: here, stdio: 'inherit', env: process.env })
process.exit(run.status ?? 1)
