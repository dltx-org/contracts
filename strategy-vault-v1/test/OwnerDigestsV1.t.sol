// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {DeployV1} from "../script/DeployV1.s.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {AssetLegParams, AssetProfile, AssetsV1, HubParams, HyperCoreParams, LegSpec, MemberTypes, OwnerMessagesV1, PricePin, Profiles, StrategySpec} from "../src/Types.sol";
import {OwnerDomain} from "../src/interfaces/IDepositOwner.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {FeePins} from "../src/lib/FeePins.sol";
import {Assets, Legs, VaultConfig} from "../src/lib/VaultTypes.sol";
import {PriceSource} from "../src/lib/PriceSource.sol";

/*
 * Version 1's encodings as the engine must reproduce them (`engine/owner/src/strategy-spec.ts`), with
 * fixed inputs and literal answers: the ETH and BTC profiles' ids, a strategy's configuration hash and
 * member addresses (the shared proxy at the pinned factory, `PinnedV1Test`'s), and the owner's digests of
 * `CreateVault` (version 1), `UpgradeStrategy`, `SwitchProfile` and `CancelPendingAction`. The
 * `CreateVault` digest is also composed here independently of the factory, from the type strings alone.
 */
contract OwnerDigestsV1Test is Test {
    address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address constant RECOVERY = 0x549178f84C788801A4528977a740A9672D2A07D7;
    // the fixed inputs
    address constant OWNER = 0x00000000000000000000000000000000000D0c0a; // a deposit account's address
    bytes32 constant STRATEGY_ID = keccak256("vector-strategy");
    address constant FACTORY = 0xF6989dDcf67CcbC1077C9054D62F8A1363623d1d; // PinnedV1Test's V1_FACTORY
    bytes32 constant MANIFEST = 0xb6f68225044351f415b4a65c25e4979ec677ea1b10c54f9ae90935ba3e2567b9; // version 1's
    address constant HUB = 0x00000000000000000000000000000000000000a0;
    uint256 constant DEADLINE = 1_900_000_000;

    // the literals
    bytes32 constant ETH_PROFILE = 0x39a05622f1cdb348a942e419f7692092319f00b31ca5350f66a556fe25a6434a;
    bytes32 constant BTC_PROFILE = 0xd714870e84be29bc90f0a4ac10bab72a63e27a5c4fc139dcdd2aac3070300d12;
    bytes32 constant CONFIG_HASH = 0x45e1b4d4cad9d6724bb59e3708cbce7234a16fe16b09aec74743f1a0c18930f1;
    address constant MEMBER_HUB = 0x86d9eF9EA57F1F72a14FD844239AbC80f8384051;
    address constant MEMBER_LONG = 0xeC4c29f3A7b9e7a8dE39f4e3c99e32d1b1F19aD0;
    address constant MEMBER_SHORT = 0xD6e155ebb75176D93F4186D5B47ff7ef72A8ee68;
    bytes32 constant CREATE_DIGEST = 0xc4abaaa6bdb4064ddfb64f3a81bc324ef917b19dbbb33729fdd0d9b501f882c0;
    bytes32 constant UPGRADE_DIGEST = 0xc580440b21a0182abe40e59b90ea5965741ef0f6eed2e38b4e9f983a93d01e8c;
    bytes32 constant SWITCH_DIGEST = 0x30d5d254dab7b184f5ae0cb0922e08cdee3d74f13d584410d8e3110d22b17dae;
    /// The same CreateVault with the management fee at its caps (100 bp, 10 USDC): the two fields' order.
    bytes32 constant CREATE_DIGEST_MGMT = 0x2e46774263e5eb051eed2d74320184271dae780f433adeeded4fea342b98319e;
    bytes32 constant CANCEL_DIGEST = 0x13651c8287ec200df095b066cb8b095b54621bbabfb1cc3b38e4ada12b6f41fe;

    StrategyFactory factory;
    DeployV1 script;

    function setUp() public {
        vm.etch(DETERMINISTIC_DEPLOYER, DEPLOYER_RUNTIME);
        script = new DeployV1();
        // the factory alone: it reads its registry only at a creation (the registry, its genesis checked
        // on chain, deploys on the fork tests)
        (bytes32 salt, bytes memory init,) = script.initOf("factory", RECOVERY);
        (bool ok, bytes memory ret) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, init));
        require(ok, "factory");
        factory = StrategyFactory(address(bytes20(ret)));
    }

    /// Every vector as this build computes it (`script/PinsV1.s.sol` reads them to re-pin).
    function computed()
        public
        view
        returns (
            address factoryAt,
            bytes32 configHash,
            address[] memory members,
            bytes32 create,
            bytes32 up,
            bytes32 sw,
            bytes32 cancel,
            bytes32 createMgmt
        )
    {
        bytes32 eth = Profiles.id(_eth());
        bytes32 btc = Profiles.id(_btc());
        StrategySpec memory c = _spec();
        factoryAt = address(factory);
        configHash = keccak256(abi.encode(c));
        (members,) = factory.memberAddresses(STRATEGY_ID, OWNER, c);
        create = factory.createDigest(STRATEGY_ID, OWNER, c, DEADLINE);
        createMgmt = factory.createDigest(STRATEGY_ID, OWNER, _spec(100, 10e6), DEADLINE);
        up = OwnerDomain.digest(
            OWNER, keccak256(abi.encode(OwnerMessagesV1.UPGRADE_STRATEGY_TYPEHASH, HUB, uint256(42161), MANIFEST, uint256(0), DEADLINE))
        );
        sw = OwnerDomain.digest(
            OWNER,
            keccak256(abi.encode(OwnerMessagesV1.SWITCH_PROFILE_TYPEHASH, HUB, uint256(42161), btc, eth, uint256(3), DEADLINE))
        );
        cancel = OwnerDomain.digest(
            OWNER,
            keccak256(
                abi.encode(
                    OwnerMessagesV1.CANCEL_PENDING_ACTION_TYPEHASH, HUB, uint256(42161), uint8(1), MANIFEST, uint256(1_899_990_000), DEADLINE
                )
            )
        );
    }

    function _word(string memory s) internal pure returns (bytes32 w) {
        (w,) = Profiles.word(s);
    }

    function _eth() internal pure returns (AssetProfile memory p) {
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

    function _btc() internal pure returns (AssetProfile memory p) {
        p.asset = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
        p.assetDecimals = 8;
        p.aAsset = 0x078f358208685046a11C85e8ad32895DED33A249;
        p.swapPool = 0x0E4831319A50228B9e450861297aB92dee15B44F;
        p.swapFee = 500;
        p.assetIsToken0 = true;
        p.holdingAsset = AssetsV1.WBTC;
        p.minBoundBp = 60;
        p.rateFeed = 0x0017abAc5b6f291F9164e35B1234CA1D697f9CF4;
        p.rateDescription = _word("WBTC / BTC");
        p.rateMaxAge = 25 hours;
        p.perp = 0;
        p.perpCoin = _word("BTC");
        p.szDecimals = 5;
        p.underlying = _word("BTC");
        p.shortAsset = AssetsV1.BTC;
        p.pins[0] = PricePin(AssetsV1.BTC, PriceSource.KIND_FEED, 0x6ce185860a4963106506C203335A2910413708e9, address(0), 1 hours);
        p.pins[1] = PricePin(
            AssetsV1.WBTC, PriceSource.KIND_COMPOSITE, 0x0017abAc5b6f291F9164e35B1234CA1D697f9CF4,
            0x6ce185860a4963106506C203335A2910413708e9, 25 hours
        );
    }

    function _spec() internal view returns (StrategySpec memory c) {
        return _spec(0, 0);
    }

    /// The vector strategy with the management fee `mgmtBp` a year and `flat` a month (amendment 2e).
    function _spec(uint16 mgmtBp, uint32 flat) internal view returns (StrategySpec memory c) {
        AssetProfile memory p = _btc();
        bytes32 id = Profiles.id(p);
        c.factory = address(factory);
        c.group = 0;
        c.hubDomain = 3;
        c.manifest = MANIFEST;
        c.hubParams = abi.encode(HubParams(id, 5, 50, 1500, mgmtBp, flat));
        c.legs = new LegSpec[](2);
        c.legs[0] = LegSpec(
            MemberTypes.AAVE_V3_ASSET, 3, Legs.LONG,
            abi.encode(AssetLegParams(id, p.asset, p.swapPool, p.swapFee, p.rateFeed, 1.15e18, 300, 50, 5))
        );
        c.legs[1] = LegSpec(
            MemberTypes.HYPERCORE, 19, Legs.SHORT, abi.encode(HyperCoreParams(id, p.perp, p.perpCoin, p.shortAsset, 100, 0, 50))
        );
    }

    function _eq(string memory what, bytes32 got, bytes32 want) internal pure {
        if (got != want) {
            console.log(what);
            console.logBytes32(got);
        }
    }

    function _eqA(string memory what, address got, address want) internal pure {
        if (got != want) console.log(what, got);
    }

    function test_v1_vectors() public view {
        assertEq(address(factory), FACTORY, "the pinned factory (PINNED_VAULT_FACTORY)");
        bytes32 eth = Profiles.id(_eth());
        bytes32 btc = Profiles.id(_btc());
        StrategySpec memory c = _spec();
        bytes32 configHash = keccak256(abi.encode(c));
        (address[] memory at, bytes32 h) = factory.memberAddresses(STRATEGY_ID, OWNER, c);
        assertEq(h, configHash);
        // the members: CREATE2(factory, keccak256(abi.encode(pairId, i)), the proxy's hash), no code in it
        bytes32 pair = VaultConfig.pairId(STRATEGY_ID, OWNER, configHash);
        assertEq(at[1], factory.memberAt(VaultConfig.legSalt(pair, 1)));
        bytes32 create = factory.createDigest(STRATEGY_ID, OWNER, c, DEADLINE);
        bytes32 up = OwnerDomain.digest(
            OWNER, keccak256(abi.encode(OwnerMessagesV1.UPGRADE_STRATEGY_TYPEHASH, HUB, uint256(42161), MANIFEST, uint256(0), DEADLINE))
        );
        bytes32 sw = OwnerDomain.digest(
            OWNER,
            keccak256(abi.encode(OwnerMessagesV1.SWITCH_PROFILE_TYPEHASH, HUB, uint256(42161), btc, eth, uint256(3), DEADLINE))
        );
        bytes32 cancel = OwnerDomain.digest(
            OWNER,
            keccak256(
                abi.encode(
                    OwnerMessagesV1.CANCEL_PENDING_ACTION_TYPEHASH, HUB, uint256(42161), uint8(1), MANIFEST, uint256(1_899_990_000), DEADLINE
                )
            )
        );
        // the deploy script's genesis carries the same two profiles, ETH first
        assertEq(Profiles.id(script.genesisProfiles()[0]), eth);
        assertEq(Profiles.id(script.genesisProfiles()[1]), btc);
        _eq("ETH_PROFILE", eth, ETH_PROFILE);
        _eq("BTC_PROFILE", btc, BTC_PROFILE);
        _eq("CONFIG_HASH", configHash, CONFIG_HASH);
        _eqA("MEMBER_HUB", at[0], MEMBER_HUB);
        _eqA("MEMBER_LONG", at[1], MEMBER_LONG);
        _eqA("MEMBER_SHORT", at[2], MEMBER_SHORT);
        _eq("CREATE_DIGEST", create, CREATE_DIGEST);
        _eq("UPGRADE_DIGEST", up, UPGRADE_DIGEST);
        _eq("SWITCH_DIGEST", sw, SWITCH_DIGEST);
        bytes32 createMgmt = factory.createDigest(STRATEGY_ID, OWNER, _spec(100, 10e6), DEADLINE);
        _eq("CREATE_DIGEST_MGMT", createMgmt, CREATE_DIGEST_MGMT);
        assertEq(createMgmt, CREATE_DIGEST_MGMT);
        _eq("CANCEL_DIGEST", cancel, CANCEL_DIGEST);
        assertEq(eth, ETH_PROFILE);
        assertEq(btc, BTC_PROFILE);
        assertEq(configHash, CONFIG_HASH);
        assertEq(at[0], MEMBER_HUB);
        assertEq(at[1], MEMBER_LONG);
        assertEq(at[2], MEMBER_SHORT);
        assertEq(create, CREATE_DIGEST);
        assertEq(up, UPGRADE_DIGEST);
        assertEq(sw, SWITCH_DIGEST);
        assertEq(cancel, CANCEL_DIGEST);
    }

    /// `CreateVault`'s digest composed from the type strings alone, as a wallet does: the factory's agrees.
    function test_v1_createDigest_independently() public view {
        string memory hub =
            "StrategyHub(bytes32 profile,uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp,uint16 managementFeeBp,uint32 flatFeePerMonth)";
        string memory long =
            "AaveV3AssetLeg(bytes32 profile,address asset,address swapPool,uint24 swapFee,address rateFeed,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp)";
        string memory short =
            "HyperCoreLeg(bytes32 profile,uint32 perp,bytes32 coin,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp)";
        bytes memory full = abi.encodePacked(
            "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,bytes32 manifest,StrategyHub hub,AaveV3AssetLeg leg1,HyperCoreLeg leg2,uint256 deadline)",
            long,
            short,
            hub
        );
        assertEq(string(full), factory.createVaultType());
        StrategySpec memory c = _spec();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(full),
                c.factory,
                STRATEGY_ID,
                c.group,
                c.hubDomain,
                c.manifest,
                keccak256(bytes.concat(keccak256(bytes(hub)), c.hubParams)),
                keccak256(bytes.concat(keccak256(bytes(long)), c.legs[0].params)),
                keccak256(bytes.concat(keccak256(bytes(short)), c.legs[1].params)),
                DEADLINE
            )
        );
        assertEq(factory.createDigest(STRATEGY_ID, OWNER, c, DEADLINE), OwnerDomain.digest(OWNER, structHash));
    }
}
