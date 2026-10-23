// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Hub} from "../src/Hub.sol";
import {HubFee} from "../src/HubFee.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {AaveV3AssetLeg} from "../src/AaveV3AssetLeg.sol";
import {AaveV3AssetLegExit} from "../src/AaveV3AssetLegExit.sol";
import {AaveV3AssetLegRewards} from "../src/AaveV3AssetLegRewards.sol";
import {HyperCoreLeg} from "../src/HyperCoreLeg.sol";
import {HyperCoreLegExit} from "../src/HyperCoreLegExit.sol";
import {HyperCoreLegExitB} from "../src/HyperCoreLegExitB.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {AssetLegParams, AssetProfile, AssetsV1, HubParams, HyperCoreParams, LegSpec, Manifests, MemberTypes, OwnerMessagesV1, ParamsTypesV1, PricePin, Profiles, StrategySpec, VersionMember} from "../src/Types.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {Assets, Legs, OwnerMessages} from "../src/lib/VaultTypes.sol";
import {PriceSource} from "../src/lib/PriceSource.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {
    CoreState,
    MockCoreDepositWallet,
    MockCoreWriter,
    MockERC20,
    MockOwner,
    MockTokenMessenger,
    MockTransmitter,
    PrecompileStub,
    walletCred
} from "./mocks/Mocks.sol";
import {AaveV3AssetLegV2, HubV2, HyperCoreLegV2, MockAaveWorld, MockSlot0, MockToken} from "./MocksV1.sol";

/*
 * Version 1's unit world, one chain at a time (each chain has its own registry, whose version entries name
 * only the member types living there): `_arbitrum()` plays Arbitrum (the hub and the AAVE asset leg, AAVE
 * and Uniswap as `MockAaveWorld`), `_hyperEvm()` HyperEVM (the Hyperliquid leg, HyperCore's precompiles
 * stubbed as in version 0's fixture). The other chain's members are named in the manifest by fixed
 * addresses and hashes, and their messages delivered by the mock transmitter. Both worlds deploy in the
 * same order, so the registry and the factory land at the same addresses in each: the member addresses one
 * world computes are the other's.
 */
abstract contract FixtureV1 is Test {
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant HYPER_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant STATE = 0x00000000000000000000000000000000c0eC0dE0;
    address constant CDW = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    uint32 constant ARB = 3;
    uint32 constant HYPER = 19;
    bytes32 constant STRATEGY = bytes32(uint256(0xb7c));
    bytes32 constant UPGRADE_MESSAGE = keccak256("dltx.strategy-vault.upgrade.v1");
    // the other chain's members in a manifest (never called in a one-chain world)
    address constant FAR_HUB = address(0xA1);
    address constant FAR_LONG = address(0xA2);
    address constant FAR_SHORT = address(0xA3);
    bytes32 constant FAR_HASH = keccak256("far");
    bytes32 constant FAR_HASH_2 = keccak256("far v2");
    address constant REGISTRY_AT = address(0x5e6157);
    address constant FACTORY_AT = address(0xFAC7);

    MockTransmitter transmitter;
    MockTokenMessenger messenger;
    MockOwner owner;
    address recovery = makeAddr("recovery");
    address key = makeAddr("group0-key");
    address stranger = makeAddr("stranger");
    uint256 walletPk;
    address wallet;
    uint256 wallet2Pk;
    address wallet2;

    StrategyRegistry registry;
    StrategyFactory factory;
    VaultUpgrade upgrade;

    // Arbitrum
    MockAaveWorld aave;
    MockERC20 usdc;
    HubFee hubFee;
    Hub hubImpl;
    AaveV3AssetLegExit longExit;
    AaveV3AssetLegRewards longRewards;
    AaveV3AssetLeg longImpl;
    MockToken wbtc;
    MockToken aWbtc;
    MockSlot0 wbtcPool;
    MockSlot0 wbtcPool30;
    MockAggregator btcUsd;
    MockAggregator wbtcBtc;
    MockAggregator seqFeed;

    // HyperEVM
    CoreState core;
    HyperCoreLegExit shortExit;
    HyperCoreLegExitB shortExitB;
    HyperCoreLeg shortImpl;

    bytes32 manifest1;
    bytes32 btcProfile;

    // ── the worlds ─────────────────────────────────────────────────────────────────────────────────────

    function _common(uint256 chainId, uint32 domain) internal {
        // the shared proxy's init code is the deposit project's cancun build (PUSH0), as both chains run
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        vm.etch(TOKEN_MESSENGER, type(MockTokenMessenger).runtimeCode);
        vm.etch(TRANSMITTER, type(MockTransmitter).runtimeCode);
        transmitter = MockTransmitter(TRANSMITTER);
        messenger = MockTokenMessenger(TOKEN_MESSENGER);
        transmitter.setLocalDomain(domain);
        vm.chainId(chainId);
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        (wallet, walletPk) = makeAddrAndKey("owner-wallet");
        (wallet2, wallet2Pk) = makeAddrAndKey("owner-wallet-2");
        owner = new MockOwner();
        owner.setWallet(wallet, true);
        owner.setWallet(wallet2, true);
        owner.setWithdrawalAddress(makeAddr("withdrawal-address"));
        upgrade = new VaultUpgrade();
    }

    /// The registry with version 1 and `profiles` in its constructor (the genesis), group 0's key, the
    /// factory: each at a fixed address, so that both worlds compute the same members.
    function _genesis(VersionMember[] memory m, AssetProfile[] memory profiles) internal {
        deployCodeTo(
            "StrategyRegistry.sol:StrategyRegistry", abi.encode(recovery, address(0), uint256(1), m, profiles), REGISTRY_AT
        );
        registry = StrategyRegistry(REGISTRY_AT);
        vm.prank(recovery);
        registry.setExecutionKey(0, key);
        deployCodeTo("StrategyFactory.sol:StrategyFactory", _factoryArgs(), FACTORY_AT);
        factory = StrategyFactory(FACTORY_AT);
        manifest1 = Manifests.hash(m);
        assertEq(registry.manifestOf(1), manifest1);
    }

    function _factoryArgs() internal view returns (bytes memory) {
        StrategyFactory.LegPinV1[] memory pins = _legPins();
        uint32[] memory domains = _hubDomains();
        return abi.encode(address(registry), ParamsTypesV1.HUB_NAME, ParamsTypesV1.HUB_FIELDS, ParamsTypesV1.HUB_COUNT, domains, pins);
    }

    function _one(AssetProfile memory p) internal pure returns (AssetProfile[] memory a) {
        a = new AssetProfile[](1);
        a[0] = p;
    }

    function _hubDomains() internal pure returns (uint32[] memory d) {
        d = new uint32[](1);
        d[0] = ARB;
    }

    function _legPins() internal pure returns (StrategyFactory.LegPinV1[] memory p) {
        p = new StrategyFactory.LegPinV1[](2);
        p[0] = StrategyFactory.LegPinV1(
            MemberTypes.AAVE_V3_ASSET, ARB, Legs.LONG, Legs.VALUE_READ, ParamsTypesV1.AAVE_V3_ASSET_NAME,
            ParamsTypesV1.AAVE_V3_ASSET_FIELDS, ParamsTypesV1.AAVE_V3_ASSET_COUNT
        );
        p[1] = StrategyFactory.LegPinV1(
            MemberTypes.HYPERCORE, HYPER, Legs.SHORT, Legs.VALUE_READ, ParamsTypesV1.HYPERCORE_NAME,
            ParamsTypesV1.HYPERCORE_FIELDS, ParamsTypesV1.HYPERCORE_COUNT
        );
    }

    /// Arbitrum: AAVE's world, WBTC (8 decimals) and its aToken, two WBTC/USDC pools (0.05 %, 0.30 %),
    /// BTC / USD, WBTC / BTC and the sequencer; version 1 listed; the BTC profile accepted.
    function _arbitrum() internal {
        _common(42161, ARB);
        vm.etch(ARB_USDC, type(MockERC20).runtimeCode);
        usdc = MockERC20(ARB_USDC);
        aave = new MockAaveWorld();
        aave.setReserve(ARB_USDC, address(new MockToken(6)), address(new MockToken(6)), MockAaveWorld(aave).GOOD_CONFIG(), 12);
        aave.setPrice(ARB_USDC, 1e8, address(0xFEED));
        seqFeed = new MockAggregator(0);
        seqFeed.setStatus(seqFeed.id(1, 1), 0, block.timestamp - 30 days);
        hubFee = new HubFee();
        hubImpl = new Hub(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(seqFeed));
        longExit = new AaveV3AssetLegExit(address(aave), ARB_USDC, address(aave), address(seqFeed));
        longRewards = new AaveV3AssetLegRewards(address(aave), ARB_USDC, address(aave), address(seqFeed));
        longImpl = new AaveV3AssetLeg(
            address(longExit), address(longExit).codehash, address(longRewards), address(longRewards).codehash,
            address(upgrade), address(upgrade).codehash, address(aave), ARB_USDC, address(aave),
            address(seqFeed)
        );
        wbtc = new MockToken(8);
        aWbtc = new MockToken(8);
        wbtcPool = new MockSlot0();
        wbtcPool30 = new MockSlot0();
        aave.setReserve(address(wbtc), address(aWbtc), address(0), MockAaveWorld(aave).GOOD_CONFIG(), 3);
        aave.setPrice(address(wbtc), 82_000e8, address(0xB7C));
        aave.setPool(address(wbtc), ARB_USDC, 500, address(wbtcPool));
        aave.setPool(address(wbtc), ARB_USDC, 3000, address(wbtcPool30));
        btcUsd = new MockAggregator(8);
        btcUsd.setDescription("BTC / USD");
        wbtcBtc = new MockAggregator(8);
        wbtcBtc.setDescription("WBTC / BTC");
        _feeds(82_000e8, 0.998e8);

        _genesis(_members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH), _one(_btc()));
        btcProfile = Profiles.id(_btc());
    }

    /// HyperEVM: HyperCore stubbed, BTC perp 0 (szDecimals 5); version 1 listed; the BTC profile accepted.
    function _hyperEvm() internal {
        _common(999, HYPER);
        vm.etch(CORE_WRITER, type(MockCoreWriter).runtimeCode);
        vm.etch(STATE, type(CoreState).runtimeCode);
        for (uint160 a = 0x800; a <= 0x810; ++a) {
            vm.etch(address(a), type(PrecompileStub).runtimeCode);
        }
        vm.etch(HYPER_USDC, type(MockERC20).runtimeCode);
        vm.etch(CDW, type(MockCoreDepositWallet).runtimeCode);
        core = CoreState(STATE);
        core.setOracle(0, 8_205_810, 5); // 82,058.1
        core.setCoin(0, "BTC");
        core.setOracle(1, 243_140, 4);
        core.setCoin(1, "ETH");
        core.setOracle(159, 802_635, 2);
        shortExit = new HyperCoreLegExit();
        shortExitB = new HyperCoreLegExitB();
        shortImpl = new HyperCoreLeg(
            address(shortExit), address(shortExit).codehash, address(shortExitB), address(shortExitB).codehash,
            address(upgrade), address(upgrade).codehash
        );
        _genesis(_members(FAR_HUB, FAR_LONG, address(shortImpl), address(shortImpl).codehash), _one(_btc()));
        btcProfile = Profiles.id(_btc());
    }

    /// New rounds of BTC / USD and WBTC / BTC, updated now.
    function _feeds(int256 btc, int256 rate) internal {
        btcUsd.push(btcUsd.id(1, uint64(uint80(btcUsd.latest())) + 1), btc, vm.getBlockTimestamp());
        wbtcBtc.push(wbtcBtc.id(1, uint64(uint80(wbtcBtc.latest())) + 1), rate, vm.getBlockTimestamp());
    }

    // ── versions and profiles ──────────────────────────────────────────────────────────────────────────

    /// The manifest's members, by type: the hub and the long on Arbitrum, the short on HyperEVM. On this
    /// chain the local ones are the real implementations; the other chain's, fixed placeholders.
    function _members(address hub, address long, address short, bytes32 shortHash)
        internal
        view
        returns (VersionMember[] memory m)
    {
        m = new VersionMember[](3);
        bool arb = transmitter.localDomain() == ARB;
        m[0] = VersionMember(MemberTypes.HUB, ARB, hub, arb ? hub.codehash : (hub == FAR_HUB ? FAR_HASH : FAR_HASH_2));
        m[1] = VersionMember(MemberTypes.AAVE_V3_ASSET, ARB, long, arb ? long.codehash : (long == FAR_LONG ? FAR_HASH : FAR_HASH_2));
        m[2] = VersionMember(MemberTypes.HYPERCORE, HYPER, short, shortHash);
    }

    function _listVersion(uint256 v, address hub, address long, address short, bytes32 shortHash)
        internal
        returns (bytes32 manifest)
    {
        VersionMember[] memory m = _members(hub, long, short, shortHash);
        vm.prank(recovery);
        registry.proposeVersion(v, m);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        registry.acceptVersion(v);
        manifest = Manifests.hash(m);
        assertEq(registry.manifestOf(v), manifest);
        if (transmitter.localDomain() == ARB) _feeds(_answer(btcUsd), _answer(wbtcBtc));
    }

    function _answer(MockAggregator f) internal view returns (int256 a) {
        (, a,,,) = f.latestRoundData();
    }

    /// Proposes, waits 7 days (the feeds refreshed), accepts; returns the id.
    function _accept(AssetProfile memory p) internal returns (bytes32 id) {
        vm.prank(recovery);
        id = registry.proposeProfile(p);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        if (transmitter.localDomain() == ARB) _feeds(_answer(btcUsd), _answer(wbtcBtc));
        vm.prank(recovery);
        registry.acceptProfile(id);
        _checkIn();
    }

    /// The group's key checks every listed version in (the 7-day listing waits would stop them).
    function _checkIn() internal {
        uint256[] memory vs = new uint256[](registry.latestVersion());
        for (uint256 i; i < vs.length; ++i) {
            vs[i] = i + 1;
        }
        vm.prank(key);
        registry.checkIn(0, vs);
    }

    function _word(string memory s) internal pure returns (bytes32 w) {
        (w,) = Profiles.word(s);
    }

    /// The BTC profile as §3.1 proposes it, on the unit world's addresses.
    function _btc() internal view returns (AssetProfile memory p) {
        p.asset = address(wbtc) == address(0) ? address(0xB7C0) : address(wbtc);
        p.assetDecimals = 8;
        p.aAsset = address(aWbtc) == address(0) ? address(0xB7C1) : address(aWbtc);
        p.swapPool = address(wbtcPool) == address(0) ? address(0xB7C2) : address(wbtcPool);
        p.swapFee = 500;
        p.assetIsToken0 = p.asset < ARB_USDC;
        p.holdingAsset = AssetsV1.WBTC;
        p.minBoundBp = 60;
        p.rateFeed = address(wbtcBtc) == address(0) ? address(0xB7C3) : address(wbtcBtc);
        p.rateDescription = _word("WBTC / BTC");
        p.rateMaxAge = 25 hours;
        p.perp = 0;
        p.perpCoin = _word("BTC");
        p.szDecimals = 5;
        p.underlying = _word("BTC");
        p.shortAsset = AssetsV1.BTC;
        address btc = address(btcUsd) == address(0) ? address(0xB7C4) : address(btcUsd);
        p.pins[0] = PricePin(AssetsV1.BTC, PriceSource.KIND_FEED, btc, address(0), 1 hours);
        p.pins[1] = PricePin(AssetsV1.WBTC, PriceSource.KIND_COMPOSITE, p.rateFeed, btc, 25 hours);
    }

    // ── a strategy ────────────────────────────────────────────────────────────────────────────────────

    function _hubParams(bytes32 profile) internal pure returns (HubParams memory) {
        return HubParams(profile, 5, 50, 1500, 0, 0);
    }

    function _longParams(AssetProfile memory p, bytes32 id) internal pure returns (AssetLegParams memory) {
        return AssetLegParams(id, p.asset, p.swapPool, p.swapFee, p.rateFeed, 1.15e18, 100, 50, 5);
    }

    function _shortParams(AssetProfile memory p, bytes32 id) internal pure returns (HyperCoreParams memory) {
        return HyperCoreParams(id, p.perp, p.perpCoin, p.shortAsset, 100, 5, 50);
    }

    function _spec(bytes32 manifest, bytes memory hubParams, bytes memory longParams, bytes memory shortParams)
        internal
        view
        returns (StrategySpec memory c)
    {
        c.factory = address(factory);
        c.group = 0;
        c.hubDomain = ARB;
        c.manifest = manifest;
        c.hubParams = hubParams;
        c.legs = new LegSpec[](2);
        c.legs[0] = LegSpec(MemberTypes.AAVE_V3_ASSET, ARB, Legs.LONG, longParams);
        c.legs[1] = LegSpec(MemberTypes.HYPERCORE, HYPER, Legs.SHORT, shortParams);
    }

    /// The BTC strategy on version 1.
    function _btcSpec() internal view returns (StrategySpec memory) {
        AssetProfile memory p = _btc();
        return _spec(
            manifest1,
            abi.encode(_hubParams(btcProfile)),
            abi.encode(_longParams(p, btcProfile)),
            abi.encode(_shortParams(p, btcProfile))
        );
    }

    function _create(StrategySpec memory c) internal returns (address[] memory) {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        return factory.create(STRATEGY, address(owner), c, deadline, _createSig(c, deadline));
    }

    function _createSig(StrategySpec memory c, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = keccak256("unsignable");
        try factory.createDigest(STRATEGY, address(owner), c, deadline) returns (bytes32 d) {
            digest = d;
        } catch {}
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletPk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _memberAddresses(StrategySpec memory c) internal view returns (address[] memory at) {
        (at,) = factory.memberAddresses(STRATEGY, address(owner), c);
    }

    // ── owner signatures ─────────────────────────────────────────────────────────────────────────────

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", owner.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _upgradeSig(uint256 pk, address hub, bytes32 manifest, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk, keccak256(abi.encode(OwnerMessagesV1.UPGRADE_STRATEGY_TYPEHASH, hub, block.chainid, manifest, nonce, deadline))
        );
    }

    function _switchSig(uint256 pk, address hub, bytes32 from, bytes32 to, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk, keccak256(abi.encode(OwnerMessagesV1.SWITCH_PROFILE_TYPEHASH, hub, block.chainid, from, to, nonce, deadline))
        );
    }

    function _cancelSig(uint256 pk, address hub, uint8 kind, bytes32 target, uint256 due, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            keccak256(
                abi.encode(OwnerMessagesV1.CANCEL_PENDING_ACTION_TYPEHASH, hub, block.chainid, kind, target, due, deadline)
            )
        );
    }

    function _beginExitSig(uint256 deadline) internal view returns (bytes memory) {
        return _sign(walletPk, keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, deadline)));
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
    }
}
