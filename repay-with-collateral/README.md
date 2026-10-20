# Repay with collateral

A flash-loan receiver that repays a lending position's debt with its own collateral in one transaction (AAVE V3 on Arbitrum).

Every function, event and error, with who may call it and when, is documented at
[docs.dltx.org/contracts/repay-with-collateral-contract](https://docs.dltx.org/contracts/repay-with-collateral-contract); the deployed addresses are at
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

MIT, see [`LICENSE`](LICENSE). This contract is deployed and verified under MIT, and stays under it.
