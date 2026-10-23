// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * A strategy's configuration (step 11e2 amendment 2a, revision 1, §3.2): the CREATION INPUTS only, never
 * a derived address. The owner signs its hash (decision 16). A strategy is one hub (member 0) and 2 to 4
 * legs (members 1 to n); each member's salt hashes the pair's id with its index, so every member derives
 * every other member's address from it.
 *
 * `configHash = keccak256(abi.encode(StrategyConfig))`: a dynamic encoding (the hub's params, the legs
 * array and each leg's params), the same in TypeScript (`encodeAbiParameters` with the tuple's types).
 */

/// The AAVE leg's parameters on Arbitrum (its `params`). Every address must equal the leg code's pinned one.
struct LongParams {
    address pool; // AAVE V3 pool
    address oracle; // AAVE's own price oracle: the one its health factor uses
    address weth; // collateral
    address usdc; // debt, and what is bridged
    address swapPool; // Uniswap V3 WETH/USDC fee 500
    address receiver; // the repay-with-collateral receiver
    uint64 healthFloor; // AAVE health factor scale, 1e18 = 1.0 (e.g. 1.15e18)
    uint16 oracleBoundBp; // every sale's bound against AAVE's oracle
    uint16 dailyLossBp; // the 24-hour loss budget, bp of the position's equity
    uint16 fastFeeCapBp; // CCTP fast transfer: maxFee at most this share of the amount
}

/// The Hyperliquid leg's parameters on HyperEVM (its `params`).
struct ShortParams {
    uint32 perp; // the strategy's perp on DEX 0 (Hyperliquid's own perps), e.g. 1 = ETH
    bytes32 asset; // the perp's asset as the hub values it (`Assets`), e.g. Assets.ETH
    uint16 orderBoundBp; // every order's bound against Hyperliquid's validator oracle
    uint16 fastFeeCapBp; // CCTP fast transfer cap (HyperEVM → Arbitrum is free today)
    uint16 feeBudgetBp; // Circle fees in 24 hours, bp of the account's value (invariant 6)
}

/// The hub's parameters (its `hubParams`).
struct HubParams {
    uint16 fastFeeCapBp; // CCTP fast transfer: maxFee at most this share of the amount
    uint16 feeBudgetBp; // Circle fees in 24 hours, bp of the hub's USDC before the burn (invariant 6)
    uint16 feeRateBp; // amendment 2b: DLTX's performance fee, bp of the profit above the mark (≤ 5,000)
}

/// One leg of a strategy, as the combination factory pins it (code, domain, role) plus its own parameters.
struct LegConfig {
    address code; // the leg code (the clones' implementation)
    uint32 domain; // the CCTP domain of the leg's chain
    uint8 role; // Legs.LONG or Legs.SHORT
    bytes params; // the leg type's own parameters, abi-encoded
}

struct StrategyConfig {
    address factory; // the combination factory: the same address on every chain its members live on
    uint8 group; // the execution group whose key operates every member
    uint32 hubDomain; // the hub's chain, one the factory allows
    bytes hubParams; // the hub's parameters, abi-encoded (HubParams)
    LegConfig[] legs; // 2 to 4 legs: members 1 to n (the hub is member 0)
}

/// One holding in a leg's report: an asset and a signed quantity in 18 decimals.
struct Holding {
    bytes32 asset;
    int256 quantity;
}

/// The assets a report may name (amendment 2a §3.6): the hub values each by its own price source (2b).
library Assets {
    bytes32 internal constant USD = keccak256("dltx.asset.USD");
    bytes32 internal constant ETH = keccak256("dltx.asset.ETH");
}

library Legs {
    uint8 internal constant LONG = 1;
    uint8 internal constant SHORT = 2;
    /// `legInfo().roles`: a bit per role
    uint8 internal constant ROLE_LONG = 1;
    uint8 internal constant ROLE_SHORT = 2;
    /// `legInfo().valueKind` (§3.9): the leg reads its own value on chain
    uint8 internal constant VALUE_READ = 1;
    /// ... or DLTX reports it within bounds (the future ExchangeLeg, Lighter): amendment 2b values only
    /// what is read on chain, so such a leg makes the hub's value refused (`ReportedValue`)
    uint8 internal constant VALUE_REPORTED = 2;
    /// The most links a member holds: a hub's legs, or a leg's hub and its sister legs (4 legs at most).
    uint8 internal constant MAX_LINKS = 4;
    uint8 internal constant MAX_LEGS = 4;
}

library VaultConfig {
    function hash(StrategyConfig memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c));
    }

    /// The pair's id (decision 26, today's salt): the strategy id, the owner's deposit contract, the hash.
    function pairId(bytes32 strategyId, address owner, bytes32 configHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(strategyId, owner, configHash));
    }

    /// Member `index`'s CREATE2 salt (§3.2; 0 the hub): two members of one code on one chain never collide.
    function legSalt(bytes32 pair, uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(pair, index));
    }
}

/*
 * Amendment 2d §4.2: each member type's parameters as an EIP-712 struct, named by the member TYPE (not its
 * role), its fields its parameters' in order. Every parameter struct is all static, so `abi.encode(params)`
 * is word for word EIP-712's `encodeData` of the same fields: `hashStruct(member) = keccak256(typeHash ‖
 * params)`. A member code declares its own (`paramsType()`); the combination factory pins name, fields and
 * count, checks each local code's declaration against its pin, and composes `CreateVault` from them.
 */
library ParamsTypes {
    string internal constant HUB_NAME = "StrategyHub";
    string internal constant HUB_FIELDS = "uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp";
    uint8 internal constant HUB_COUNT = 3;
    string internal constant HUB = "StrategyHub(uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp)";

    string internal constant AAVE_V3_NAME = "AaveV3Leg";
    string internal constant AAVE_V3_FIELDS =
        "address pool,address oracle,address weth,address usdc,address swapPool,address receiver,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp";
    uint8 internal constant AAVE_V3_COUNT = 10;
    string internal constant AAVE_V3 =
        "AaveV3Leg(address pool,address oracle,address weth,address usdc,address swapPool,address receiver,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp)";

    string internal constant HYPERCORE_NAME = "HyperCoreLeg";
    string internal constant HYPERCORE_FIELDS =
        "uint32 perp,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp";
    uint8 internal constant HYPERCORE_COUNT = 5;
    string internal constant HYPERCORE =
        "HyperCoreLeg(uint32 perp,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp)";
}

/*
 * The owner's messages a leg or the combination factory verifies (§7.2), under `OwnerDomain` (no chain id).
 * - `CreateVault`: the owner's authorisation of a configuration (decision 16), typed field by field
 *   (amendment 2d §4.2): `CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,
 *   <HubType> hub,<LegType> leg1,…,uint256 deadline)` then the member types sorted by name, composed and
 *   hashed by the combination factory from its pins (`createVaultTypehash`). No nonce: a member is at one
 *   CREATE2 address, so a replay can only hit the member that already exists.
 * - `BeginExit`: names the strategy, not the chain, no nonce (one-way, valid on every member).
 * - the local actions (`VaultAction`, `OwnerOrder`) name the member and the chain and carry its own
 *   sequential nonce.
 */
library OwnerMessages {
    bytes32 internal constant BEGIN_EXIT_TYPEHASH = keccak256("BeginExit(bytes32 strategyId,uint256 deadline)");
    bytes32 internal constant VAULT_ACTION_TYPEHASH = keccak256(
        "VaultAction(address vault,uint256 chainId,uint8 action,address agent,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant OWNER_ORDER_TYPEHASH = keccak256(
        "OwnerOrder(address vault,uint256 chainId,uint32 asset,bool isBuy,uint64 size,uint64 limitPx,uint8 szDecimals,uint256 nonce,uint256 deadline)"
    );

    // VaultAction.action
    uint8 internal constant REVOKE_EXECUTION = 1;
    uint8 internal constant ALLOW_EXECUTION = 2;
    uint8 internal constant REPLACE_AGENT = 3; // the Hyperliquid leg only: the burner at once, others after 24 h
    uint8 internal constant CANCEL_AGENT = 4; // the Hyperliquid leg only
    /// The Hyperliquid leg only, in budget mode: the owner releases the exit's pending reservation (sends
    /// from spot never seen to arrive), asserting none will still execute (the partner's audit M4)
    uint8 internal constant RELEASE_RESERVATION = 5;
}
