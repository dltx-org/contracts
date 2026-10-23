// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Hub} from "../src/Hub.sol";
import {HubFee} from "../src/HubFee.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {AaveV3AssetLeg} from "../src/AaveV3AssetLeg.sol";
import {AaveV3AssetLegExit} from "../src/AaveV3AssetLegExit.sol";
import {AaveV3AssetLegRewards} from "../src/AaveV3AssetLegRewards.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {AssetLegParams, AssetProfile, AssetsV1, HubParams, HyperCoreParams, LegSpec, Manifests, MemberTypes, ParamsTypesV1, PricePin, Profiles, StrategySpec, VersionMember} from "../src/Types.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {FeePins} from "../src/lib/FeePins.sol";
import {Assets, Legs} from "../src/lib/VaultTypes.sol";
import {PriceSource} from "../src/lib/PriceSource.sol";
import {IAavePool} from "../src/interfaces/Protocols.sol";
import {MockOwner} from "./mocks/Mocks.sol";

/*
 * Version 1 on an Arbitrum fork: the real AAVE V3 pool and oracle, the real Uniswap V3 pools, the
 * DEPLOYED repay-with-collateral receiver, Circle's CCTP V2 and USDC, Chainlink's feeds. The registry,
 * the shared upgrade module, the hub and the AAVE asset leg (with its modules) are deployed as their
 * deployment would (the chain's facts as constructor data, Q11); version 1 is listed and the ETH and BTC
 * profiles accepted with AP-3's checks against the chain's real state. The registry's 7-day delays are
 * the unit suites' subject: here each due time is written to now (a fork cannot wait 7 days without
 * every feed going stale).
 */
abstract contract ArbitrumForkV1 is Test {
    using stdStorage for StdStorage;

    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    // BTC on Arbitrum (asset-profiles-design.md §3.1, §7)
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant WBTC_USDC_500 = 0x0E4831319A50228B9e450861297aB92dee15B44F;
    address constant WBTC_BTC_FEED = 0x0017abAc5b6f291F9164e35B1234CA1D697f9CF4;
    address constant BTC_USD_FEED = 0x6ce185860a4963106506C203335A2910413708e9;
    // the other chain's member in the manifest (HyperEVM's short: never called here)
    address constant FAR_SHORT = address(0xA3);
    bytes32 constant FAR_HASH = keccak256("hypercore leg implementation, HyperEVM");

    bool forked;
    StrategyRegistry registry;
    StrategyFactory factory;
    VaultUpgrade upgrade;
    HubFee hubFee;
    Hub hubImpl;
    AaveV3AssetLegExit longExit;
    AaveV3AssetLegRewards longRewards;
    AaveV3AssetLeg longImpl;
    bytes32 manifest1;
    bytes32 ethProfile;
    bytes32 btcProfile;
    MockOwner owner;
    address recovery = makeAddr("recovery");
    address key = makeAddr("group-key");
    address stranger = makeAddr("stranger");
    address withdrawalTo = makeAddr("withdrawal-address");
    uint256 walletPk;
    address wallet;

    // the management fee the next configuration signs (amendment 2e; 0 and 0 unless a test sets them)
    uint16 nextMgmtBp;
    uint32 nextFlatPerMonth;

    /// The world at `blockNumber`; false (and nothing done) without ARBITRUM_RPC_URL.
    function _forkV1(uint256 blockNumber, uint8 group) internal returns (bool) {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url, vm.envOr("ARBITRUM_FORK_BLOCK", blockNumber));
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        forked = true;
        (wallet, walletPk) = makeAddrAndKey("owner-wallet");
        owner = new MockOwner();
        owner.setWallet(wallet, true);
        owner.setWithdrawalAddress(withdrawalTo);
        upgrade = new VaultUpgrade();
        hubFee = new HubFee();
        hubImpl = new Hub(
            address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, Arbitrum.SEQUENCER
        );
        longExit = new AaveV3AssetLegExit(Arbitrum.POOL, Arbitrum.USDC, Arbitrum.RECEIVER, Arbitrum.SEQUENCER);
        longRewards = new AaveV3AssetLegRewards(Arbitrum.POOL, Arbitrum.USDC, Arbitrum.RECEIVER, Arbitrum.SEQUENCER);
        longImpl = new AaveV3AssetLeg(
            address(longExit), address(longExit).codehash, address(longRewards), address(longRewards).codehash,
            address(upgrade), address(upgrade).codehash, Arbitrum.POOL, Arbitrum.USDC,
            Arbitrum.RECEIVER, Arbitrum.SEQUENCER
        );
        // the genesis: version 1 and both profiles in the registry's constructor, checked against the fork
        VersionMember[] memory m = _members(1, address(hubImpl), address(longImpl));
        AssetProfile[] memory profiles = new AssetProfile[](2);
        profiles[0] = _ethP();
        profiles[1] = _btcP();
        registry = new StrategyRegistry(recovery, address(0), 1, m, profiles);
        manifest1 = Manifests.hash(m);
        ethProfile = Profiles.id(profiles[0]);
        btcProfile = Profiles.id(profiles[1]);
        vm.prank(recovery);
        registry.setExecutionKey(group, key);
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = 3;
        StrategyFactory.LegPinV1[] memory pins = new StrategyFactory.LegPinV1[](2);
        pins[0] = StrategyFactory.LegPinV1(
            MemberTypes.AAVE_V3_ASSET, 3, Legs.LONG, Legs.VALUE_READ, ParamsTypesV1.AAVE_V3_ASSET_NAME,
            ParamsTypesV1.AAVE_V3_ASSET_FIELDS, ParamsTypesV1.AAVE_V3_ASSET_COUNT
        );
        pins[1] = StrategyFactory.LegPinV1(
            MemberTypes.HYPERCORE, 19, Legs.SHORT, Legs.VALUE_READ, ParamsTypesV1.HYPERCORE_NAME,
            ParamsTypesV1.HYPERCORE_FIELDS, ParamsTypesV1.HYPERCORE_COUNT
        );
        factory = new StrategyFactory(
            address(registry), ParamsTypesV1.HUB_NAME, ParamsTypesV1.HUB_FIELDS, ParamsTypesV1.HUB_COUNT, hubDomains, pins
        );
        return true;
    }

    function _members(uint256, address hub, address long) internal view returns (VersionMember[] memory m) {
        m = new VersionMember[](3);
        m[0] = VersionMember(MemberTypes.HUB, 3, hub, hub.codehash);
        m[1] = VersionMember(MemberTypes.AAVE_V3_ASSET, 3, long, long.codehash);
        m[2] = VersionMember(MemberTypes.HYPERCORE, 19, FAR_SHORT, FAR_HASH);
    }

    /// Proposes version `v`, writes its due time to now, accepts it.
    function _listNow(uint256 v, address hub, address long) internal returns (bytes32 manifest) {
        VersionMember[] memory m = _members(v, hub, long);
        vm.prank(recovery);
        registry.proposeVersion(v, m);
        stdstore.target(address(registry)).sig("proposal(uint256)").with_key(v).depth(0).checked_write(
            block.timestamp
        );
        vm.prank(recovery);
        registry.acceptVersion(v);
        manifest = Manifests.hash(m);
    }

    /// Proposes `p`, writes its due time to now, accepts it (AP-3's checks against the fork).
    function _acceptNow(AssetProfile memory p) internal returns (bytes32 id) {
        vm.prank(recovery);
        id = registry.proposeProfile(p);
        stdstore.target(address(registry)).sig("profileDue(bytes32)").with_key(id).checked_write(block.timestamp);
        vm.prank(recovery);
        registry.acceptProfile(id);
    }

    function _word(string memory s) internal pure returns (bytes32 w) {
        (w,) = Profiles.word(s);
    }

    /// ETH on version 1 (Q7): version 0's leg as a profile; no rate feed.
    function _ethP() internal pure returns (AssetProfile memory p) {
        p.asset = Arbitrum.WETH;
        p.assetDecimals = 18;
        p.aAsset = Arbitrum.A_WETH;
        p.swapPool = Arbitrum.SWAP_POOL;
        p.swapFee = 500;
        p.assetIsToken0 = true;
        p.holdingAsset = Assets.ETH;
        p.minBoundBp = 30;
        p.perp = 1;
        p.perpCoin = _word("ETH");
        p.szDecimals = 4;
        p.underlying = _word("ETH");
        p.shortAsset = Assets.ETH;
        p.pins[0] = PricePin(Assets.ETH, PriceSource.KIND_FEED, FeePins.ETH_USD, address(0), FeePins.ETH_USD_MAX_AGE);
    }

    /// BTC (WBTC) as asset-profiles-design.md §3.1 proposes it.
    function _btcP() internal view returns (AssetProfile memory p) {
        p.asset = WBTC;
        p.assetDecimals = 8;
        p.aAsset = IAavePool(Arbitrum.POOL).getReserveData(WBTC).aTokenAddress;
        p.swapPool = WBTC_USDC_500;
        p.swapFee = 500;
        p.assetIsToken0 = true;
        p.holdingAsset = AssetsV1.WBTC;
        p.minBoundBp = 60;
        p.rateFeed = WBTC_BTC_FEED;
        p.rateDescription = _word("WBTC / BTC");
        p.rateMaxAge = 25 hours;
        p.perp = 0;
        p.perpCoin = _word("BTC");
        p.szDecimals = 5;
        p.underlying = _word("BTC");
        p.shortAsset = AssetsV1.BTC;
        p.pins[0] = PricePin(AssetsV1.BTC, PriceSource.KIND_FEED, BTC_USD_FEED, address(0), 1 hours);
        p.pins[1] = PricePin(AssetsV1.WBTC, PriceSource.KIND_COMPOSITE, WBTC_BTC_FEED, BTC_USD_FEED, 25 hours);
    }

    // ── a strategy ────────────────────────────────────────────────────────────────────────────────────

    function _specOf(bytes32 id, AssetProfile memory p, uint8 group, uint16 oracleBoundBp, uint16 dailyLossBp)
        internal
        view
        returns (StrategySpec memory c)
    {
        return _specWith(id, p, group, 1.15e18, oracleBoundBp, dailyLossBp, 100);
    }

    /// Every bound the owner signs, named.
    function _specWith(
        bytes32 id,
        AssetProfile memory p,
        uint8 group,
        uint64 healthFloor,
        uint16 oracleBoundBp,
        uint16 dailyLossBp,
        uint16 orderBoundBp
    ) internal view returns (StrategySpec memory) {
        // through an external call: inlined by via-IR into a test that also walks logs, it ran out of stack
        return this.buildSpec(id, p, group, healthFloor, oracleBoundBp, dailyLossBp, orderBoundBp);
    }

    function buildSpec(
        bytes32 id,
        AssetProfile memory p,
        uint8 group,
        uint64 healthFloor,
        uint16 oracleBoundBp,
        uint16 dailyLossBp,
        uint16 orderBoundBp
    ) external view returns (StrategySpec memory c) {
        c.factory = address(factory);
        c.group = group;
        c.hubDomain = 3;
        c.manifest = manifest1;
        c.hubParams = abi.encode(HubParams(id, 5, 50, 1500, nextMgmtBp, nextFlatPerMonth));
        c.legs = new LegSpec[](2);
        c.legs[0] = LegSpec(MemberTypes.AAVE_V3_ASSET, 3, Legs.LONG, _longParams(id, p, healthFloor, oracleBoundBp, dailyLossBp));
        c.legs[1] = LegSpec(MemberTypes.HYPERCORE, 19, Legs.SHORT, _shortParams(id, p, orderBoundBp));
    }

    function _longParams(bytes32 id, AssetProfile memory p, uint64 healthFloor, uint16 oracleBoundBp, uint16 dailyLossBp)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(AssetLegParams(id, p.asset, p.swapPool, p.swapFee, p.rateFeed, healthFloor, oracleBoundBp, dailyLossBp, 5));
    }

    function _shortParams(bytes32 id, AssetProfile memory p, uint16 orderBoundBp) internal pure returns (bytes memory) {
        return abi.encode(HyperCoreParams(id, p.perp, p.perpCoin, p.shortAsset, orderBoundBp, 0, 50));
    }

    function _signDigest(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletPk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(walletPk, keccak256(abi.encodePacked(hex"1901", owner.domainSeparator(), structHash)));
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
    }
}
