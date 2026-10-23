// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity ^0.8.24;

/*
 * The init code of `DepositProxy` (src/DepositProxy.sol), pinned byte for byte —
 * owner-upgrades-design.md §A1, §3.1, §C6: ONE init code for the deposit contract and every strategy
 * member, so one hash in every address formula. The deposit factory and the combination factory both
 * CREATE2 exactly these bytes; the vault project imports this file instead of compiling the proxy under
 * its own settings (`paris`), which would give other bytes. test/Proxy.t.sol checks that the deposit
 * project's build of `DepositProxy` is these bytes and that HASH is their keccak; changing either
 * changes every account's and every member's address.
 */
library ProxyInitCode {
    bytes internal constant INIT_CODE =
        hex"6080806040523461009357630c870f9160e01b8152602081600481335afa908115610102575f91610097575b50803b15610093577f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc819055604051906001600160a01b03167fbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b5f80a26040908161010e8239f35b5f80fd5b905060203d6020116100fb575b601f8101601f191682016001600160401b038111838210176100e75760209183916040528101031261009357516001600160a01b0381168103610093575f61002b565b634e487b7160e01b5f52604160045260245ffd5b503d6100a4565b6040513d5f823e3d90fdfe6080604052365f80375f8036817f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc545af43d5f803e15603c573d5ff35b3d5ffd";
    bytes32 internal constant HASH = 0x6f7b25ec6a5059170168f7c23327b6f7e572f9cdcbe26af04cf747b6542bbfc4;
}
