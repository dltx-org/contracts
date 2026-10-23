// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Hub} from "../../src/Hub.sol";
import {HubFee} from "../../src/HubFee.sol";
import {VaultUpgrade} from "../../src/VaultUpgrade.sol";
import {AaveV3AssetLeg} from "../../src/AaveV3AssetLeg.sol";
import {AaveV3AssetLegExit} from "../../src/AaveV3AssetLegExit.sol";
import {AaveV3AssetLegRewards} from "../../src/AaveV3AssetLegRewards.sol";
import {HyperCoreLeg} from "../../src/HyperCoreLeg.sol";
import {HyperCoreLegExit} from "../../src/HyperCoreLegExit.sol";
import {HyperCoreLegExitB} from "../../src/HyperCoreLegExitB.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {
    AssetLegParams,
    AssetProfile,
    HubParams as HubParamsV1,
    HyperCoreParams,
    LegSpec,
    MemberTypes,
    ParamsTypesV1,
    PricePin,
    Profiles,
    StrategySpec
} from "../../src/Types.sol";
import {
    Assets, HubParams, Legs, LongParams, OwnerMessages, ShortParams, VaultConfig
} from "../../src/lib/VaultTypes.sol";
import {PriceSource} from "../../src/lib/PriceSource.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {
    CoreState,
    MockCoreDepositWallet,
    MockCoreWriter,
    MockERC20,
    MockOwner,
    MockTokenMessenger,
    MockTransmitter,
    PrecompileStub
} from "../mocks/Mocks.sol";
import {MockAaveWorld, MockSlot0, MockToken} from "../MocksV1.sol";

/*
 * A registry for the compat world: version 0's surface (one key per group, `checkIn(group)`,
 * `stopped(group)`, the fee address in two steps) and version 1's reads (every member type's
 * implementation of version 1, whatever chain the one EVM plays; one open profile). It lets version 0's
 * unit suites, which play both chains in one EVM, run against version 1's members unchanged.
 */
contract CompatRegistry {
    uint8 public constant GROUPS = 16;
    uint256 public constant STOP_AFTER = 7 days;
    address public recovery;
    address public pendingRecovery;
    mapping(uint8 => address) public executionKey;
    mapping(uint8 => uint256) public lastCheckIn;
    address public feeAddress;
    address public pendingFeeAddress;
    mapping(uint8 => address) internal _impl;
    bytes32 public manifest;
    bytes32 public profileId;
    AssetProfile internal _profile;

    constructor(address recovery_) {
        recovery = recovery_;
    }

    function list(bytes32 manifest_, address hub, address long, address short) external {
        manifest = manifest_;
        (_impl[MemberTypes.HUB], _impl[MemberTypes.AAVE_V3_ASSET], _impl[MemberTypes.HYPERCORE]) = (hub, long, short);
    }

    function setProfile(AssetProfile calldata p) external {
        _profile = p;
        profileId = Profiles.id(p);
    }

    function setExecutionKey(uint8 group, address key) external {
        require(msg.sender == recovery, "NotAllowed");
        if (executionKey[group] == address(0)) lastCheckIn[group] = block.timestamp;
        executionKey[group] = key;
    }

    function checkIn(uint8 group) external {
        require(msg.sender == executionKey[group], "NotAllowed");
        lastCheckIn[group] = block.timestamp;
    }

    function stopped(uint8 group) public view returns (bool) {
        return block.timestamp >= lastCheckIn[group] + STOP_AFTER;
    }

    function stopped(uint8 group, uint256 version) external view returns (bool) {
        return version != 1 || stopped(group);
    }

    function proposeFeeAddress(address next) external {
        require(msg.sender == recovery, "NotAllowed");
        pendingFeeAddress = next;
    }

    function acceptFeeAddress() external {
        require(msg.sender == pendingFeeAddress, "NotAllowed");
        feeAddress = msg.sender;
        pendingFeeAddress = address(0);
    }

    function versionOf(bytes32 m) external view returns (uint256) {
        return m == manifest ? 1 : 0;
    }

    function manifestOf(uint256 v) external view returns (bytes32) {
        return v == 1 ? manifest : bytes32(0);
    }

    function implementation(uint256 v, uint8 memberType) external view returns (address) {
        return v == 1 ? _impl[memberType] : address(0);
    }

    function profileOpen(bytes32 id) external view returns (bool) {
        return id == profileId;
    }

    function profileOf(bytes32 id) external view returns (AssetProfile memory p) {
        if (id == profileId) p = _profile;
    }
}

/*
 * Version 0's unit fixture (`test/utils/Fixture.sol`) on version 1's members: the same names, the same
 * HyperEVM world (CoreWriter, the precompiles, Circle's USDC and CCTP as doubles), the same strategy (the
 * hub and the AAVE leg on Arbitrum, the Hyperliquid leg on HyperEVM, ETH, its bounds) made by version 1's
 * factory as the shared proxy, every member on version 1, the ETH profile its asset. Version 0's
 * `LongParams` and `ShortParams` are mapped to version 1's at `_configWith`.
 */
abstract contract FixtureCompat is Test {
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant STATE = 0x00000000000000000000000000000000c0eC0dE0;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CDW = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    address constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    uint32 constant SPOT = type(uint32).max;
    uint32 constant ETH = 1;
    uint32 constant HYPE_PERP = 159;
    uint64 constant HYPE = 150;
    uint32 constant ARB_DOMAIN = 3;
    uint32 constant HYPEREVM_DOMAIN = 19;
    bytes32 constant STRATEGY = bytes32(uint256(0x5a5a));
    bytes32 constant MANIFEST = keccak256("compat version 1");

    CoreState core;
    MockCoreWriter writer;
    MockTransmitter transmitter;
    MockTokenMessenger messenger;
    MockERC20 usdc;
    MockOwner owner;

    address recovery = makeAddr("recovery");
    address key = makeAddr("group0-key");
    address stranger = makeAddr("stranger");
    uint256 walletPk;
    address wallet;
    address withdrawalTo = makeAddr("withdrawal-address");

    CompatRegistry registry;
    StrategyFactory factory;
    VaultUpgrade upgrade;
    Hub hubCode;
    HubFee hubFee;
    AaveV3AssetLeg longCode;
    HyperCoreLegExit shortExit;
    HyperCoreLegExitB shortExitB;
    HyperCoreLeg shortCode;
    MockAaveWorld aaveWorld;
    MockAggregator ethFeed;
    MockAggregator seqFeed;
    uint80 ethRound;
    uint32 constant ETH_MAX_AGE = 1 hours;
    bytes32 ethProfile;

    uint8 constant NOT_IN_EXIT = 0;
    uint8 constant CLOSING = 1;
    uint8 constant RECOVERED = 2;
    uint8 constant RECOVERED_WITH_RESIDUE = 3;
    uint256 constant F_PARTNER_PENDING = 1;
    uint256 constant F_NEEDS_HYPE = 2;
    uint256 constant F_BUDGET = 4;
    uint256 constant F_WAITING_OWNER = 8;
    uint256 constant F_MARGIN_HELD = 16;
    uint256 constant F_OWNER_UNSYNCED = 32;

    function _world() internal {
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        vm.etch(CORE_WRITER, type(MockCoreWriter).runtimeCode);
        vm.etch(STATE, type(CoreState).runtimeCode);
        for (uint160 a = 0x800; a <= 0x810; ++a) {
            vm.etch(address(a), type(PrecompileStub).runtimeCode);
        }
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(CDW, type(MockCoreDepositWallet).runtimeCode);
        vm.etch(TOKEN_MESSENGER, type(MockTokenMessenger).runtimeCode);
        vm.etch(TRANSMITTER, type(MockTransmitter).runtimeCode);
        core = CoreState(STATE);
        writer = MockCoreWriter(CORE_WRITER);
        transmitter = MockTransmitter(TRANSMITTER);
        messenger = MockTokenMessenger(TOKEN_MESSENGER);
        usdc = MockERC20(USDC);
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);

        (wallet, walletPk) = makeAddrAndKey("owner-wallet");
        owner = new MockOwner();
        owner.setWallet(wallet, true);
        owner.setWithdrawalAddress(withdrawalTo);

        vm.chainId(999);
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        registry = new CompatRegistry(recovery);
        vm.prank(recovery);
        registry.setExecutionKey(0, key);
        ethFeed = new MockAggregator(8);
        seqFeed = new MockAggregator(0);
        seqFeed.setStatus(seqFeed.id(1, 1), 0, block.timestamp - 30 days);
        _ethPrice(2_500e8);
        upgrade = new VaultUpgrade();
        hubFee = new HubFee();
        hubCode = new Hub(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(seqFeed));
        // the AAVE leg's chain facts (it is created, never operated, in these suites)
        aaveWorld = new MockAaveWorld();
        aaveWorld.setReserve(USDC, address(new MockToken(6)), address(new MockToken(6)), aaveWorld.GOOD_CONFIG(), 12);
        aaveWorld.setPrice(USDC, 1e8, address(0xFEED));
        MockToken weth = new MockToken(18);
        MockToken aWeth = new MockToken(18);
        MockSlot0 wethPool = new MockSlot0();
        aaveWorld.setReserve(address(weth), address(aWeth), address(0), aaveWorld.GOOD_CONFIG(), 0);
        aaveWorld.setPrice(address(weth), 2_500e8, address(0xE7));
        aaveWorld.setPool(address(weth), USDC, 500, address(wethPool));
        AaveV3AssetLegExit le = new AaveV3AssetLegExit(address(aaveWorld), USDC, address(aaveWorld), address(seqFeed));
        AaveV3AssetLegRewards lr = new AaveV3AssetLegRewards(address(aaveWorld), USDC, address(aaveWorld), address(seqFeed));
        longCode = new AaveV3AssetLeg(
            address(le), address(le).codehash, address(lr), address(lr).codehash, address(upgrade),
            address(upgrade).codehash, address(aaveWorld), USDC, address(aaveWorld), address(seqFeed)
        );
        shortExit = new HyperCoreLegExit();
        shortExitB = new HyperCoreLegExitB();
        shortCode = new HyperCoreLeg(
            address(shortExit), address(shortExit).codehash, address(shortExitB), address(shortExitB).codehash,
            address(upgrade), address(upgrade).codehash
        );
        registry.list(MANIFEST, address(hubCode), address(longCode), address(shortCode));
        AssetProfile memory p;
        p.asset = address(weth);
        p.assetDecimals = 18;
        p.aAsset = address(aWeth);
        p.swapPool = address(wethPool);
        p.swapFee = 500;
        p.assetIsToken0 = address(weth) < USDC;
        p.holdingAsset = Assets.ETH;
        p.minBoundBp = 30;
        p.perp = ETH;
        (p.perpCoin,) = Profiles.word("ETH");
        p.szDecimals = 4;
        p.underlying = p.perpCoin;
        p.shortAsset = Assets.ETH;
        p.pins[0] = PricePin(Assets.ETH, PriceSource.KIND_FEED, address(ethFeed), address(0), ETH_MAX_AGE);
        registry.setProfile(p);
        ethProfile = registry.profileId();
        StrategyFactory.LegPinV1[] memory pins = new StrategyFactory.LegPinV1[](2);
        pins[0] = StrategyFactory.LegPinV1(
            MemberTypes.AAVE_V3_ASSET, ARB_DOMAIN, Legs.LONG, Legs.VALUE_READ, ParamsTypesV1.AAVE_V3_ASSET_NAME,
            ParamsTypesV1.AAVE_V3_ASSET_FIELDS, ParamsTypesV1.AAVE_V3_ASSET_COUNT
        );
        pins[1] = StrategyFactory.LegPinV1(
            MemberTypes.HYPERCORE, HYPEREVM_DOMAIN, Legs.SHORT, Legs.VALUE_READ, ParamsTypesV1.HYPERCORE_NAME,
            ParamsTypesV1.HYPERCORE_FIELDS, ParamsTypesV1.HYPERCORE_COUNT
        );
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = ARB_DOMAIN;
        factory = new StrategyFactory(
            address(registry), ParamsTypesV1.HUB_NAME, ParamsTypesV1.HUB_FIELDS, ParamsTypesV1.HUB_COUNT, hubDomains, pins
        );
        core.setOracle(ETH, 243_140, 4);
        core.setCoin(ETH, "ETH");
        core.setOracle(HYPE_PERP, 802_635, 2);
    }

    /// Arbitrum's USDC for the AAVE leg (a suite that plays Arbitrum: the hub's USDC by chain id is
    /// Arbitrum's there): a second implementation on it, listed in place of the first.
    function _arbitrumLong(address arbUsdc) internal {
        aaveWorld.setReserve(arbUsdc, address(new MockToken(6)), address(new MockToken(6)), aaveWorld.GOOD_CONFIG(), 12);
        aaveWorld.setPrice(arbUsdc, 1e8, address(0xFEED));
        AssetProfile memory p = registry.profileOf(ethProfile);
        aaveWorld.setPool(p.asset, arbUsdc, 500, p.swapPool);
        p.assetIsToken0 = p.asset < arbUsdc;
        registry.setProfile(p);
        ethProfile = registry.profileId();
        AaveV3AssetLegExit le = new AaveV3AssetLegExit(address(aaveWorld), arbUsdc, address(aaveWorld), address(seqFeed));
        AaveV3AssetLegRewards lr = new AaveV3AssetLegRewards(address(aaveWorld), arbUsdc, address(aaveWorld), address(seqFeed));
        longCode = new AaveV3AssetLeg(
            address(le), address(le).codehash, address(lr), address(lr).codehash, address(upgrade),
            address(upgrade).codehash, address(aaveWorld), arbUsdc, address(aaveWorld), address(seqFeed)
        );
        registry.list(MANIFEST, address(hubCode), address(longCode), address(shortCode));
    }

    function _ethPrice(int256 price) internal returns (uint80 r) {
        r = ethFeed.id(1, uint64(uint80(ethRound)) + 1);
        ethFeed.push(r, price, vm.getBlockTimestamp());
        ethRound = r;
    }

    function _hubParams() internal pure returns (HubParams memory) {
        return HubParams({fastFeeCapBp: 5, feeBudgetBp: 50, feeRateBp: 1500});
    }

    function _longParams() internal pure returns (LongParams memory p) {
        p.healthFloor = 1.15e18;
        p.oracleBoundBp = 100;
        p.dailyLossBp = 50;
        p.fastFeeCapBp = 5;
    }

    function _shortParams() internal pure returns (ShortParams memory) {
        return ShortParams({perp: ETH, asset: Assets.ETH, orderBoundBp: 100, fastFeeCapBp: 5, feeBudgetBp: 50});
    }

    function _config() internal view returns (StrategySpec memory) {
        return _configWith(_longParams(), _shortParams());
    }

    /// Version 0's parameters as version 1's, on the ETH profile.
    function _configWith(LongParams memory lp, ShortParams memory sp) internal view returns (StrategySpec memory c) {
        AssetProfile memory p = registry.profileOf(ethProfile);
        HubParams memory h = _hubParams();
        c.factory = address(factory);
        c.group = 0;
        c.hubDomain = ARB_DOMAIN;
        c.manifest = MANIFEST;
        c.hubParams = abi.encode(HubParamsV1(ethProfile, h.fastFeeCapBp, h.feeBudgetBp, h.feeRateBp, 0, 0));
        c.legs = new LegSpec[](2);
        c.legs[0] = LegSpec(
            MemberTypes.AAVE_V3_ASSET,
            ARB_DOMAIN,
            Legs.LONG,
            abi.encode(
                AssetLegParams(
                    ethProfile, p.asset, p.swapPool, p.swapFee, p.rateFeed, lp.healthFloor, lp.oracleBoundBp,
                    lp.dailyLossBp, lp.fastFeeCapBp
                )
            )
        );
        c.legs[1] = LegSpec(
            MemberTypes.HYPERCORE,
            HYPEREVM_DOMAIN,
            Legs.SHORT,
            abi.encode(
                HyperCoreParams(ethProfile, sp.perp, p.perpCoin, sp.asset, sp.orderBoundBp, sp.fastFeeCapBp, sp.feeBudgetBp)
            )
        );
    }

    function _create(StrategySpec memory c) internal returns (address) {
        uint256 deadline = block.timestamp + 1 days;
        return factory.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline))[0];
    }

    function _legs(StrategySpec memory c) internal view returns (address[] memory at) {
        (at,) = factory.memberAddresses(STRATEGY, address(owner), c);
    }

    function _deliverReady(address leg, uint32 fromDomain, address from) internal {
        transmitter.deliver(leg, fromDomain, bytes32(uint256(uint160(from))), abi.encode(keccak256("dltx.strategy-vault.ready.v1")));
    }

    function _sign(uint256 pk, address ownerAddr, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", MockOwner(ownerAddr).domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _createSig(uint256 pk, bytes32 strategyId, StrategySpec memory c, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256("unsignable");
        if (c.factory.code.length > 0) {
            try StrategyFactory(c.factory).createDigest(strategyId, address(owner), c, deadline) returns (bytes32 d) {
                digest = d;
            } catch {}
        }
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _beginExitSig(bytes32 strategyId, uint256 deadline) internal view returns (bytes memory) {
        return _sign(walletPk, address(owner), keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, strategyId, deadline)));
    }

    function _actionSig(address vault, uint8 action, address agent, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            walletPk,
            address(owner),
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, vault, block.chainid, action, agent, nonce, deadline))
        );
    }

    function _core(uint24 id, bytes memory fields) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), id, fields);
    }

    function _order(uint32 asset, bool isBuy, uint64 px, uint64 sz, bool reduceOnly) internal pure returns (bytes memory) {
        return _core(1, abi.encode(asset, isBuy, px, sz, reduceOnly, uint8(3), uint128(0)));
    }

    function _sendAsset(address to, uint32 src, uint32 dst, uint64 token, uint64 amount)
        internal
        pure
        returns (bytes memory)
    {
        return _core(13, abi.encode(to, address(0), src, dst, token, amount));
    }

    function _agentBytes(address agent) internal pure returns (bytes memory) {
        return _core(9, abi.encode(agent, "dltx"));
    }

    function _since(uint256 from) internal view returns (bytes[] memory out) {
        uint256 n = writer.count();
        out = new bytes[](n - from);
        for (uint256 i = from; i < n; ++i) {
            out[i - from] = writer.action(i).data;
        }
    }

    function _has(bytes[] memory actions, bytes memory want) internal pure returns (bool) {
        for (uint256 i; i < actions.length; ++i) {
            if (keccak256(actions[i]) == keccak256(want)) return true;
        }
        return false;
    }

    function _countId(bytes[] memory actions, uint24 id) internal pure returns (uint256 n) {
        for (uint256 i; i < actions.length; ++i) {
            bytes memory a = actions[i];
            if (a.length >= 4 && uint24(uint8(a[1])) << 16 | uint24(uint8(a[2])) << 8 | uint24(uint8(a[3])) == id) n++;
        }
    }
}
