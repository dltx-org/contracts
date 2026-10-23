// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, Vm, stdStorage, StdStorage} from "forge-std/Test.sol";
import {HyperCoreLegV2} from "./MocksV1.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {HyperCoreLeg} from "../src/HyperCoreLeg.sol";
import {HyperCoreLegState} from "../src/HyperCoreLegState.sol";
import {HyperCoreLegExit} from "../src/HyperCoreLegExit.sol";
import {HyperCoreLegExitB} from "../src/HyperCoreLegExitB.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {AssetLegParams, AssetProfile, AssetsV1, HubParams, HyperCoreParams, LegSpec, Manifests, MemberTypes, ParamsTypesV1, PricePin, Profiles, StrategySpec, VersionMember} from "../src/Types.sol";
import {Assets, Legs, OwnerMessages} from "../src/lib/VaultTypes.sol";
import {PriceSource} from "../src/lib/PriceSource.sol";
import {CoreState, MockOwner, PrecompileStub} from "./mocks/Mocks.sol";

/// HyperCore's `perpAssetInfo` answer.
struct PerpInfo {
    string coin;
    uint32 marginTableId;
    uint8 szDecimals;
    uint8 maxLeverage;
    bool onlyIsolated;
}

interface IERC20h1 {
    function balanceOf(address) external view returns (uint256);
}

/*
 * The Hyperliquid leg, version 1, on a HyperEVM fork: the REAL CoreWriter (its RawAction log is what
 * HyperCore executes), Circle's USDC, CoreDepositWallet and CCTP V2, the shared proxy on HyperEVM.
 * HyperCore's read precompiles do not run in Foundry's EVM: the stubs answer here what the real ones
 * answer, read from the node itself (`vm.rpc` → `eth_call` of `perpAssetInfo(0)`: "BTC", szDecimals 5),
 * so the BTC profile is accepted against HyperCore's own answer (AP-3). The profile is the same data, so
 * the same id, as Arbitrum's. SKIPPED when HyperEVM can't be reached; the public RPC sometimes refuses an
 * old block: rerun before calling a failure real.
 */
contract HyperCoreLegV1ForkTest is Test {
    using stdStorage for StdStorage;

    uint256 constant PINNED_BLOCK = 48_521_917; // version 0's
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant STATE = 0x00000000000000000000000000000000c0eC0dE0;
    bytes32 constant STRATEGY = keccak256("strategy-btc");
    bytes32 constant UPGRADE_MESSAGE = keccak256("dltx.strategy-vault.upgrade.v1");
    // Arbitrum's facts in the profile (asset-profiles-design.md §3.1), so the id is Arbitrum's
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant A_WBTC = 0x078f358208685046a11C85e8ad32895DED33A249;
    address constant WBTC_USDC_500 = 0x0E4831319A50228B9e450861297aB92dee15B44F;
    address constant WBTC_BTC_FEED = 0x0017abAc5b6f291F9164e35B1234CA1D697f9CF4;
    address constant BTC_USD_FEED = 0x6ce185860a4963106506C203335A2910413708e9;

    event RawAction(address indexed user, bytes data);

    bool forked;
    StrategyRegistry registry;
    StrategyFactory factory;
    VaultUpgrade upgrade;
    HyperCoreLegExit shortExit;
    HyperCoreLegExitB shortExitB;
    HyperCoreLeg shortImpl;
    CoreState core;
    MockOwner owner;
    address short;
    address short2;
    address hubAt;
    bytes32 manifest1;
    bytes32 btcProfile;
    address recovery = makeAddr("recovery");
    address key = makeAddr("group-key");
    uint256 walletPk;
    address wallet;

    function setUp() public {
        string memory url = vm.envOr("HYPEREVM_RPC_URL", string("https://rpc.hyperliquid.xyz/evm"));
        try vm.createSelectFork(url, vm.envOr("HYPEREVM_FORK_BLOCK", PINNED_BLOCK)) returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        assertEq(block.chainid, 999, "not HyperEVM");
        // HyperCore's answer for perp 0, from the node (the stubs then play it)
        bytes memory info = vm.rpc(
            "eth_call",
            '[{"to":"0x000000000000000000000000000000000000080a","data":"0x0000000000000000000000000000000000000000000000000000000000000000"},"latest"]'
        );
        PerpInfo memory pi = abi.decode(info, (PerpInfo));
        (string memory coin, uint8 szd) = (pi.coin, pi.szDecimals);
        vm.etch(STATE, type(CoreState).runtimeCode);
        for (uint160 a = 0x800; a <= 0x810; ++a) {
            vm.etch(address(a), type(PrecompileStub).runtimeCode);
        }
        core = CoreState(STATE);
        core.setOracle(0, 8_205_810, szd);
        core.setCoin(0, coin);
        core.setOracle(159, 802_635, 2);
        (wallet, walletPk) = makeAddrAndKey("owner-wallet");
        owner = new MockOwner();
        owner.setWallet(wallet, true);
        upgrade = new VaultUpgrade();
        shortExit = new HyperCoreLegExit();
        shortExitB = new HyperCoreLegExitB();
        shortImpl = new HyperCoreLeg(
            address(shortExit), address(shortExit).codehash, address(shortExitB), address(shortExitB).codehash,
            address(upgrade), address(upgrade).codehash
        );
        // the genesis: version 1 and the BTC profile in the registry's constructor (AP-3 against the fork)
        VersionMember[] memory m = _members(address(shortImpl));
        AssetProfile[] memory profiles = new AssetProfile[](1);
        profiles[0] = _btcP();
        registry = StrategyRegistry(
            vm.deployCode("StrategyRegistry.sol:StrategyRegistry", abi.encode(recovery, address(0), uint256(1), m, profiles))
        );
        manifest1 = Manifests.hash(m);
        btcProfile = Profiles.id(profiles[0]);
        vm.prank(recovery);
        registry.setExecutionKey(2, key);
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
        StrategySpec memory c = _spec();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletPk, factory.createDigest(STRATEGY, address(owner), c, deadline));
        short = factory.create(STRATEGY, address(owner), c, deadline, abi.encodePacked(uint8(1), r, s, v))[0];
        (address[] memory at,) = factory.memberAddresses(STRATEGY, address(owner), c);
        hubAt = at[0];
        // version 2's implementation; through `deployCode`: a plain `new` here is held to a small block's
        // 3M gas on HyperEVM
        short2 = vm.deployCode(
            "test/MocksV1.sol:HyperCoreLegV2",
            abi.encode(
                address(shortExit), address(shortExit).codehash, address(shortExitB), address(shortExitB).codehash,
                address(upgrade), address(upgrade).codehash, address(registry)
            )
        );
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _members(address s) internal view returns (VersionMember[] memory m) {
        m = new VersionMember[](3);
        m[0] = VersionMember(MemberTypes.HUB, 3, address(0xA1), keccak256("hub implementation, Arbitrum"));
        m[1] = VersionMember(MemberTypes.AAVE_V3_ASSET, 3, address(0xA2), keccak256("long implementation, Arbitrum"));
        m[2] = VersionMember(MemberTypes.HYPERCORE, 19, s, s.codehash);
    }

    function _listNow(uint256 v, address s) internal returns (bytes32 manifest) {
        VersionMember[] memory m = _members(s);
        vm.prank(recovery);
        registry.proposeVersion(v, m);
        stdstore.target(address(registry)).sig("proposal(uint256)").with_key(v).depth(0).checked_write(block.timestamp);
        vm.prank(recovery);
        registry.acceptVersion(v);
        manifest = Manifests.hash(m);
    }

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

    function _btcP() internal pure returns (AssetProfile memory p) {
        p.asset = WBTC;
        p.assetDecimals = 8;
        p.aAsset = A_WBTC;
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

    function _spec() internal view returns (StrategySpec memory c) {
        AssetProfile memory p = _btcP();
        c.factory = address(factory);
        c.group = 2;
        c.hubDomain = 3;
        c.manifest = manifest1;
        c.hubParams = abi.encode(HubParams(btcProfile, 5, 50, 1500, 0, 0));
        c.legs = new LegSpec[](2);
        c.legs[0] = LegSpec(
            MemberTypes.AAVE_V3_ASSET, 3, Legs.LONG,
            abi.encode(AssetLegParams(btcProfile, p.asset, p.swapPool, p.swapFee, p.rateFeed, 1.15e18, 300, 50, 5))
        );
        c.legs[1] = LegSpec(
            MemberTypes.HYPERCORE, 19, Legs.SHORT, abi.encode(HyperCoreParams(btcProfile, 0, p.perpCoin, AssetsV1.BTC, 100, 0, 50))
        );
    }

    // ── the tests ─────────────────────────────────────────────────────────────────────────────────────

    /// The profile's id here is Arbitrum's: the same data (asset-profiles-design.md §3.1, AP-2).
    function test_fork_hyper_profileIdIsArbitrums() public onFork {
        assertEq(btcProfile, Profiles.id(_btcP()));
        assertEq(HyperCoreLegState(short).profile(), btcProfile);
        assertEq(HyperCoreLegState(short).asset(), AssetsV1.BTC);
        assertEq(short.code.length, 64);
    }

    function test_fork_hyper_anEthPerpUnderTheBtcProfileRefused() public onFork {
        core.setCoin(1, "ETH");
        core.setOracle(1, 243_140, 4);
        AssetProfile memory p = _btcP();
        p.perp = 1;
        vm.prank(recovery);
        bytes32 id = registry.proposeProfile(p);
        stdstore.target(address(registry)).sig("profileDue(bytes32)").with_key(id).checked_write(block.timestamp);
        vm.prank(recovery);
        vm.expectRevert(MemberState.BadProfile.selector);
        registry.acceptProfile(id);
    }

    /// The real CoreDepositWallet and CoreWriter through the proxy: margin in, a reduce-only order on the
    /// BTC perp (the profile's), and the exit's burner agent.
    function test_fork_hyper_marginOrderAndExit() public onFork {
        deal(USDC, short, 100e6);
        vm.prank(key);
        HyperCoreLeg(payable(short)).toMargin(100e6);
        assertEq(IERC20h1(USDC).balanceOf(short), 0);
        core.setPosition(short, 0, -100); // 0.001 BTC short
        vm.expectEmit(true, false, false, false, CORE_WRITER);
        emit RawAction(short, "");
        vm.prank(key);
        HyperCoreLeg(payable(short)).order(true, 100_000, true);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            walletPk,
            keccak256(
                abi.encodePacked(
                    hex"1901", owner.domainSeparator(), keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, deadline))
                )
            )
        );
        MemberBase(short).beginExit(deadline, abi.encodePacked(uint8(1), r, s, v));
        assertEq(HyperCoreLegState(short).agent(), HyperCoreLeg(payable(short)).burner());
    }

    /// The hub's `.upgrade.v1` message, delivered as Circle's transmitter would: the short follows to
    /// HyperEVM's own entry for the manifest.
    function test_fork_hyper_followsTheHubsUpgrade() public onFork {
        bytes32 manifest2 = _listNow(2, short2);
        bytes memory body = abi.encode(UPGRADE_MESSAGE, manifest2, block.timestamp);
        vm.prank(TRANSMITTER);
        MemberBase(short).handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(hubAt))), 2000, body);
        assertEq(
            address(uint160(uint256(vm.load(short, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))),
            short2
        );
        assertEq(MemberState(short).codeVersion(), 2);
    }
}
