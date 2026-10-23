// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * Version 1's types: the asset profile, the members' parameters, a strategy's configuration and the
 * owner's new messages (asset-profiles-design.md §3.1, §3.3, §3.7; owner-upgrades-design.md §C2, §C4,
 * §C6). Version 0's (`lib/VaultTypes.sol`) stay as they are: `Holding`, `Assets`, `Legs`, `VaultConfig`
 * and the frozen owner messages (`BeginExit`, `VaultAction`, `OwnerOrder`) are reused unchanged.
 */

/// One of a profile's fee price pins, for the hub (amendment 2b §3.8): `asset` zero is an unused pin.
struct PricePin {
    bytes32 asset; // the holding's asset id (`Assets`)
    uint8 kind; // PriceSource.KIND_FEED (a USD price) or KIND_COMPOSITE (a rate × a USD price)
    address feed;
    address baseFeed; // kind 2 only
    uint32 maxAge;
}

/*
 * An ASSET PROFILE (§3.1): everything a strategy on that asset reads, on every chain it has members on.
 * Its id is `keccak256(abi.encode(profile))`, every field static, so the same id names the same data on
 * every chain's registry; each chain checks the facts that live there when it accepts it (AP-3).
 */
struct AssetProfile {
    // the long, on Arbitrum
    address asset; // the collateral (WBTC)
    uint8 assetDecimals; // its `decimals()`, 6 to 18
    address aAsset; // AAVE's aToken for it
    address swapPool; // the Uniswap V3 asset/USDC pool of the receiver's router's factory
    uint24 swapFee; // that pool's fee tier (500 = 0.05 %)
    bool assetIsToken0; // asset < USDC
    bytes32 holdingAsset; // the long's holding in a report (Assets.WBTC); the hub prices it by a pin
    uint16 minBoundBp; // the least `oracleBoundBp` an owner may sign: above `swapFee / 100`
    address rateFeed; // a wrapped asset's market rate (Chainlink WBTC / BTC), zero for none (§3.5)
    bytes32 rateDescription; // the feed's `description()`, left-aligned ("WBTC / BTC"); zero with no feed
    uint32 rateMaxAge; // the rate's freshness, seconds (25 h); zero with no feed
    // the short, on HyperEVM
    uint32 perp; // its DEX 0 index (0 = BTC)
    bytes32 perpCoin; // `perpAssetInfo(perp).coin`, left-aligned ("BTC")
    uint8 szDecimals; // `perpAssetInfo(perp).szDecimals`
    bytes32 underlying; // what the long's asset is (WBTC → "BTC"): equal to `perpCoin`
    bytes32 shortAsset; // the short's id: keccak256("dltx.asset." ‖ perpCoin), never chosen
    // the hub, on Arbitrum
    PricePin[2] pins;
}

/// The hub's parameters as the owner signs them (`StrategyHub(...)`). The management fee (amendment 2e):
/// a rate a year of the base and a flat USDC amount a month, each the strategy's ceiling for good.
struct HubParams {
    bytes32 profile;
    uint16 fastFeeCapBp;
    uint16 feeBudgetBp;
    uint16 feeRateBp;
    uint16 managementFeeBp;
    uint32 flatFeePerMonth;
}

/// The AAVE V3 asset leg's parameters (`AaveV3AssetLeg(...)`): the profile and the fields a wallet shows
/// (AP-5), each refused unless equal to the registry's entry, then the owner's bounds.
struct AssetLegParams {
    bytes32 profile;
    address asset;
    address swapPool;
    uint24 swapFee;
    address rateFeed;
    uint64 healthFloor;
    uint16 oracleBoundBp;
    uint16 dailyLossBp;
    uint16 fastFeeCapBp;
}

/// The Hyperliquid leg's parameters (`HyperCoreLeg(...)`).
struct HyperCoreParams {
    bytes32 profile;
    uint32 perp;
    bytes32 coin;
    bytes32 asset;
    uint16 orderBoundBp;
    uint16 fastFeeCapBp;
    uint16 feeBudgetBp;
}

/// One leg of a strategy (version 1): its member type in place of a code, which the registry resolves.
struct LegSpec {
    uint8 memberType;
    uint32 domain;
    uint8 role;
    bytes params;
}

/// A strategy's configuration (version 1): `manifest` names every member's code on every chain (§C6).
struct StrategySpec {
    address factory;
    uint8 group;
    uint32 hubDomain;
    bytes32 manifest;
    bytes hubParams;
    LegSpec[] legs;
}

/// One member type of a version, as its manifest names it (§C2).
struct VersionMember {
    uint8 memberType;
    uint32 domain;
    address implementation;
    bytes32 codeHash;
}

/// Version 1's asset ids beyond version 0's `Assets` (USD, ETH), kept here: a constant added to the shared
/// `lib/VaultTypes.sol` shifts via-IR's ordering and changes version 0's pinned bytecode. A short's id is
/// `keccak256("dltx.asset." ‖ its perp's coin)`, so BTC's is the perp "BTC"'s; WBTC is the long's holding,
/// valued as WBTC / BTC × BTC / USD.
library AssetsV1 {
    bytes32 internal constant BTC = keccak256("dltx.asset.BTC");
    bytes32 internal constant WBTC = keccak256("dltx.asset.WBTC");
}

library MemberTypes {
    uint8 internal constant HUB = 1;
    uint8 internal constant AAVE_V3_ASSET = 2;
    uint8 internal constant HYPERCORE = 3;
}

/// Each member type's parameters as an EIP-712 struct (amendment 2d §4.2's mechanism).
library ParamsTypesV1 {
    string internal constant HUB_NAME = "StrategyHub";
    string internal constant HUB_FIELDS =
        "bytes32 profile,uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp,uint16 managementFeeBp,uint32 flatFeePerMonth";
    uint8 internal constant HUB_COUNT = 6;
    string internal constant HUB =
        "StrategyHub(bytes32 profile,uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp,uint16 managementFeeBp,uint32 flatFeePerMonth)";

    string internal constant AAVE_V3_ASSET_NAME = "AaveV3AssetLeg";
    string internal constant AAVE_V3_ASSET_FIELDS =
        "bytes32 profile,address asset,address swapPool,uint24 swapFee,address rateFeed,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp";
    uint8 internal constant AAVE_V3_ASSET_COUNT = 9;
    string internal constant AAVE_V3_ASSET =
        "AaveV3AssetLeg(bytes32 profile,address asset,address swapPool,uint24 swapFee,address rateFeed,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp)";

    string internal constant HYPERCORE_NAME = "HyperCoreLeg";
    string internal constant HYPERCORE_FIELDS =
        "bytes32 profile,uint32 perp,bytes32 coin,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp";
    uint8 internal constant HYPERCORE_COUNT = 7;
    string internal constant HYPERCORE =
        "HyperCoreLeg(bytes32 profile,uint32 perp,bytes32 coin,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp)";
}

/*
 * The owner's version-1 messages (owner-upgrades-design.md §C4; asset-profiles-design.md §3.7), under the
 * owner's domain (no chain id), verified at the hub: each names the hub and its chain. A schedule spends
 * the signing credential's vault nonce; the cancel is nonce-free and names exactly what it cancels.
 */
library OwnerMessagesV1 {
    bytes32 internal constant UPGRADE_STRATEGY_TYPEHASH =
        keccak256("UpgradeStrategy(address hub,uint256 chainId,bytes32 manifest,uint256 nonce,uint256 deadline)");
    bytes32 internal constant SWITCH_PROFILE_TYPEHASH = keccak256(
        "SwitchProfile(address hub,uint256 chainId,bytes32 fromProfile,bytes32 toProfile,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant CANCEL_PENDING_ACTION_TYPEHASH = keccak256(
        "CancelPendingAction(address hub,uint256 chainId,uint8 kind,bytes32 target,uint256 due,uint256 deadline)"
    );
    /// `PendingAction.kind`
    uint8 internal constant KIND_UPGRADE = 1;
    uint8 internal constant KIND_SWITCH = 2;
}

library Profiles {
    function id(AssetProfile memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    /// The short's reporting id from its perp's coin (AP-3): `keccak256("dltx.asset." ‖ coin)`, the coin
    /// left-aligned in its word and cut at its first zero byte.
    function assetOf(bytes32 coin) internal pure returns (bytes32) {
        uint256 n;
        while (n < 32 && coin[n] != 0) ++n;
        bytes memory s = new bytes(n);
        for (uint256 i; i < n; ++i) {
            s[i] = coin[i];
        }
        return keccak256(abi.encodePacked("dltx.asset.", s));
    }

    /// A string as a left-aligned word: its first 32 bytes, zero beyond (a longer string is refused).
    function word(string memory s) internal pure returns (bytes32 w, bool fits) {
        bytes memory b = bytes(s);
        if (b.length > 32) return (bytes32(0), false);
        assembly ("memory-safe") {
            w := mload(add(b, 0x20))
        }
        if (b.length < 32) w &= ~bytes32(type(uint256).max >> (b.length * 8));
        return (w, true);
    }
}

/// The manifest of a version (§C2): every member type's (type, domain, implementation, code hash), in
/// member-type order, hashed: the same bytes on every chain.
library Manifests {
    function hash(VersionMember[] memory m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m));
    }
}
