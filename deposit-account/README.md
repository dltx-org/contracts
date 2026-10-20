# Deposit account

The user's own deposit contract and its CREATE2 factory: the owner's credentials (passkey or wallet), the one withdrawal address, and the funding of the strategy vaults the owner authorises.

Every function, event and error, with who may call it and when, is documented at
[docs.dltx.org/contracts/deposit-contract](https://docs.dltx.org/contracts/deposit-contract); the deployed addresses are at
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
