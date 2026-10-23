# DLTX contracts

The smart contracts behind [DLTX](https://dltx.org): delta-neutral strategies held in contracts the
user owns, which DLTX operates within on-chain limits and the user can always exit without DLTX.

| Project | What it is | License |
|---|---|---|
| [`deposit-account`](deposit-account) | the user's deposit contract and its factory | DLTX Source License 1.0 |
| [`strategy-vault`](strategy-vault) | version 0: a strategy's hub, its long and short legs, their exits, the combination factory and the registry | DLTX Source License 1.0 |
| [`strategy-vault-v1`](strategy-vault-v1) | version 1: the same, owner-upgradeable, on any allowed asset (asset profiles) | DLTX Source License 1.0 |
| [`repay-with-collateral`](repay-with-collateral) | a flash-loan receiver repaying debt from collateral | MIT |

**Status.** Version 0 of the deposit account and of the strategy vaults is deployed on Arbitrum and
HyperEVM, not audited, and not open to users. Version 1 (`strategy-vault-v1` and the
owner-upgradeable deposit account in `deposit-account`) is built and under security review, **not
deployed**: do not treat this code as live or audited. `repay-with-collateral` is deployed on
Arbitrum.

How the contracts fit together, every function, and the deployed addresses:
[docs.dltx.org/contracts](https://docs.dltx.org/contracts).

**License.** The deposit account and the strategy vaults are under the DLTX Source License 1.0
([`LICENSE`](LICENSE)): you may read, audit and test them, and compare them with the deployed
contracts; you may not deploy them, or a work derived from them, in production. They become MIT
five years after their first mainnet deployment. `repay-with-collateral` is MIT.

**Security.** Report a vulnerability privately, never in a public issue: see [`SECURITY.md`](SECURITY.md).

Exported from DLTX's development repository at `0e21d7ea2`.
