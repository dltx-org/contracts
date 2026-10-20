# Strategy vaults

The contracts that hold a running strategy: the strategy hub, the long leg on AAVE V3 (Arbitrum), the short leg as a Hyperliquid account (HyperEVM), their exit modules, the combination factory and the registry. The owner can always exit without DLTX.

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
