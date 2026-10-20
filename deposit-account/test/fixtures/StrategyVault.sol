// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * Slice 2's REAL vault factory, for the cross-slice test (amendment 1, §5): its configuration types and
 * the calls this project makes, copied from `contracts/strategy-vault` at `418494f4a`
 * (feat/strategy-vault: src/lib/VaultTypes.sol, src/VaultFactory.sol). The build itself is
 * `strategy-vault-factory-418494f4a.hex` beside this file: `forge inspect VaultFactory bytecode` of that
 * commit's sources with its own profile (paris, via-IR, 200 runs), whose keccak256 is
 * slice 2's pinned creation-code hash (asserted by CrossSliceTest). To refresh it after slice 2
 * changes: `git archive <commit> contracts/strategy-vault | tar -x -C <dir>`, copy `dependencies/`
 * in, `forge build`, `forge inspect VaultFactory bytecode > test/fixtures/strategy-vault-factory-<commit>.hex`,
 * and update the hash, the commit and these types.
 */

struct LongParams {
    address pool;
    address oracle;
    address weth;
    address usdc;
    address swapPool;
    address receiver;
    uint64 healthFloor;
    uint16 oracleBoundBp;
    uint16 dailyLossBp;
    uint16 fastFeeCapBp;
}

struct ShortParams {
    uint32 perp;
    uint16 orderBoundBp;
    uint16 fastFeeCapBp;
}

struct PairConfig {
    uint8 group;
    uint32 longDomain;
    uint32 shortDomain;
    address longFactory;
    address shortFactory;
    LongParams long;
    ShortParams short;
}

interface IStrategyVaultFactory {
    function create(bytes32 strategyId, address owner, PairConfig calldata cfg, uint256 deadline, bytes calldata signature)
        external
        returns (address vault);

    function authorisedFor(address vault) external view returns (address owner, bytes32 strategyId, bytes32 configHash);

    function pairAddresses(bytes32 strategyId, address owner, PairConfig calldata cfg)
        external
        view
        returns (address longVault, address shortVault, bytes32 configHash);
}

library StrategyVaultFixture {
    string internal constant BUILD = "test/fixtures/strategy-vault-factory-418494f4a.hex";
    /// contracts/strategy-vault/test/Pinned.t.sol at 418494f4a.
    bytes32 internal constant PINNED_CREATION_CODE_HASH = 0x9c119714774c2a32f812a62ac6008d4113c17a848b9909c200903ae6c12aed8e;
    bytes32 internal constant FACTORY_SALT = keccak256("dltx.vault-factory.v1");
    bytes32 internal constant CREATE_VAULT_TYPEHASH =
        keccak256("CreateVault(bytes32 strategyId,bytes32 configHash,uint256 deadline)");

    // the long half's pinned protocols on Arbitrum (src/lib/Pinned.sol)
    address internal constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant SWAP_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address internal constant RECEIVER = 0xC69Ee59E3b0DbC99fA928B7674503b8A3f2CeEd0;

    /// A configuration slice 2's `_validate` accepts (its own fixture's values), for `factory`.
    function config(address factory) internal pure returns (PairConfig memory c) {
        c.group = 0;
        c.longDomain = 3;
        c.shortDomain = 19;
        c.longFactory = factory;
        c.shortFactory = factory;
        c.long = LongParams(POOL, ORACLE, WETH, USDC, SWAP_POOL, RECEIVER, 1.15e18, 100, 50, 5);
        c.short = ShortParams(1, 100, 5);
    }
}
