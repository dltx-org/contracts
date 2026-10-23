# Strategy vaults, version 1

Version 1 of the strategy contracts: each strategy's hub and legs are owner-upgradeable proxies (only the owner's signature moves them to an allowed version, after a 24-hour cancellable delay), any allowed asset through registry profiles (ETH and BTC first), the combination factory, the registry with its version and profile lists, and the exit modules. The owner can always exit without DLTX.

Every function, event and error, with who may call it and when, is documented at
[docs.dltx.org/contracts](https://docs.dltx.org/contracts); the deployed addresses are at
[docs.dltx.org/contract-addresses](https://docs.dltx.org/contract-addresses). `functions.json` here is
the machine-readable list those pages are generated from.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge soldeer install
forge build
node test.mjs
```

`node test.mjs` runs the unit tests always and the fork tests against the real protocols when
`ARBITRUM_RPC_URL` (and `HYPEREVM_RPC_URL` where used) are set, in the environment or in a `.env` at
the repository root; without them the fork tests are skipped.

## License

DLTX Source License 1.0, see [`../LICENSE`](../LICENSE).
