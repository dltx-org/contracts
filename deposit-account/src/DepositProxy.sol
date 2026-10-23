// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * The fixed ERC-1967 proxy of every owner-upgradeable instance — owner-upgrades-design.md §A1, §3.1.
 *
 * ONE init code for both families: a user's deposit contract (made by the deposit factory) and each
 * member of a strategy (made by the combination factory, Part C). No constructor argument, so an
 * instance's address is CREATE2(maker, salt, keccak256(this init code)) and never depends on any
 * implementation. Its constructor asks its maker (`msg.sender`) for the first implementation: the
 * deposit factory answers its `genesis()`, the combination factory the implementation it staged for
 * the member it is creating. A maker outside a creation answers zero, which has no code: refused, so
 * no instance points nowhere.
 *
 * The ERC-1967 slot is written by this constructor and afterwards only by the implementation's own
 * upgrade path (UUPS-style, in a pinned module of the implementation). The proxy has no admin and no
 * function of its own: every call is delegated. `fallback` is payable so that a later version may
 * accept the native coin; version 1 has no payable function, so a plain transfer still reverts.
 *
 * Its init code is pinned byte for byte in `ProxyInitCode.sol`, which the vault project embeds, so
 * both families share one hash whatever their own compiler settings (test/Proxy.t.sol checks it).
 */

/// What the proxy asks its maker for, once, in its constructor.
interface IProxyMaker {
    function proxyImplementation() external view returns (address);
}

contract DepositProxy {
    /// bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event Upgraded(address indexed implementation);

    constructor() {
        address impl = IProxyMaker(msg.sender).proxyImplementation();
        if (impl.code.length == 0) revert();
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION_SLOT, impl)
        }
        emit Upgraded(impl);
    }

    fallback() external payable {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), sload(IMPLEMENTATION_SLOT), 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
