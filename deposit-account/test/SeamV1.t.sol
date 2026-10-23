// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {DepositAccount} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Helpers} from "./Helpers.sol";
import {Assets, Legs, OwnerMessages} from "@vault/lib/VaultTypes.sol";
import {FeePins} from "@vault/lib/FeePins.sol";
import {Arbitrum} from "@vault/lib/Pinned.sol";

// ── version 1's types, ABI-identical to contracts/strategy-vault-v1/src/Types.sol ────────────────────

struct PricePinV1 {
    bytes32 asset;
    uint8 kind;
    address feed;
    address baseFeed;
    uint32 maxAge;
}

struct AssetProfileV1 {
    address asset;
    uint8 assetDecimals;
    address aAsset;
    address swapPool;
    uint24 swapFee;
    bool assetIsToken0;
    bytes32 holdingAsset;
    uint16 minBoundBp;
    address rateFeed;
    bytes32 rateDescription;
    uint32 rateMaxAge;
    uint32 perp;
    bytes32 perpCoin;
    uint8 szDecimals;
    bytes32 underlying;
    bytes32 shortAsset;
    PricePinV1[2] pins;
}

struct LegSpecV1 {
    uint8 memberType;
    uint32 domain;
    uint8 role;
    bytes params;
}

struct StrategySpecV1 {
    address factory;
    uint8 group;
    uint32 hubDomain;
    bytes32 manifest;
    bytes hubParams;
    LegSpecV1[] legs;
}

struct VersionMemberV1 {
    uint8 memberType;
    uint32 domain;
    address implementation;
    bytes32 codeHash;
}

struct LegPinV1 {
    uint8 memberType;
    uint32 domain;
    uint8 role;
    uint8 valueKind;
    string typeName;
    string typeFields;
    uint8 fieldCount;
}

interface IFactoryV1 {
    function create(bytes32, address, StrategySpecV1 calldata, uint256, bytes calldata) external returns (address[] memory);
    function createDigest(bytes32, address, StrategySpecV1 calldata, uint256) external view returns (bytes32);
    function createVaultType() external view returns (string memory);
    function memberAddresses(bytes32, address, StrategySpecV1 calldata) external view returns (address[] memory, bytes32);
    function authorisedFor(address) external view returns (address, bytes32, bytes32);
}

interface IRegistryV1Seam {
    function setExecutionKey(uint8, address) external;
    function profileOpen(bytes32) external view returns (bool);
    function checkIn(uint8, uint256[] calldata) external;
}

interface IMemberV1 {
    function beginExit(uint256, bytes calldata) external;
    function exiting() external view returns (bool);
    function exitStep() external;
    function ownerAction(uint8, address, bytes32, uint256, bytes calldata) external;
    function ownerNonceOf(bytes32) external view returns (uint256);
    function executionRevoked() external view returns (bool);
    function handleReceiveFinalizedMessage(uint32, bytes32, uint32, bytes calldata) external returns (bool);
    function scheduleUpgrade(bytes32, bytes32, uint256, bytes calldata) external;
    function cancelPendingAction(uint8, bytes32, uint256, uint256, bytes calldata) external;
    function pendingAction() external view returns (uint8, uint64, bytes32, bytes32);
}

interface ITokenV1 {
    function balanceOf(address) external view returns (uint256);
}

interface IOwnerRemovalsV1 {
    function removalPendingOf(bytes32) external view returns (bool);
}

/*
 * The seam with VERSION 1 of the strategy vaults (asset-profiles-design.md §10 slice 1, owner-upgrades-design.md
 * §8): the deposit account built here as the owner of version 1's members, loaded from their pinned build
 * (test/fixtures/strategy-vault-v1-pinned: `forge inspect <C> bytecode` in contracts/strategy-vault on
 * feat/vault-asset-profiles-contracts, each checked against contracts/strategy-vault-v1/test/PinnedV1.t.sol's hash). On the
 * Arbitrum fork: the registry lists version 1 and opens the ETH profile in its constructor (the genesis,
 * checked against the chain), a wallet owner and a passkey owner each sign the typed `CreateVault` of version 1
 * (the factory's digest checked against an independent EIP-712 hash under the account's domain), the
 * factory makes the hub and the AAVE asset leg as the shared proxy, the account trusts the factory and funds
 * the hub only, an owner action through the real account, then the upgrade frame: `UpgradeStrategy` signed
 * through the account (its `removalPendingOf` read by the hub), its cancel by any credential; `BeginExit`
 * and the hub's exit paying the withdrawal address.
 *
 * Version 1's factory refuses an owner that cannot answer `removalPendingOf` (its strategies could never be
 * upgraded nor switched); that function arrives with feat/deposit-upgradeable-contract. Against an account
 * without it (this branch's), the seam first checks the creation is refused (`BadOwner`), then runs with the
 * answer mocked to `false`, saying so; once both branches are merged it runs against the account's own.
 */
contract SeamV1Test is Helpers {
    using stdStorage for StdStorage;

    string constant DIR = "test/fixtures/strategy-vault-v1-pinned/";
    uint256 constant PINNED_BLOCK = 517_200_797; // the version-1 suites' block
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant GROUP_KEY = address(0xBEEF04);
    bytes32 constant STRATEGY = keccak256("seam-v1");
    bytes32 constant READY = keccak256("dltx.strategy-vault.ready.v1");
    // version 1's pinned build (contracts/strategy-vault-v1/test/PinnedV1.t.sol's creation-code hashes)
    bytes32 constant V1_REGISTRY_CODE = 0x1ad116492b0f0e5d2441041301a49549c52c44ab7eb22392899d86a2d05a64e1;
    bytes32 constant V1_UPGRADE_CODE = 0x6ac7ab0be95c9882db27fa50b5fbc2509041bb6eab69210f5994faa9a9cb9332;
    bytes32 constant V1_HUB_FEE_CODE = 0x8ad730eca56b593a0cbe363a57b3bf2e4c71202b824d284835edbb0a33a2ac1a;
    bytes32 constant V1_HUB_CODE = 0xe79b2bc5e5481afe61e7e961a82e81242b2935ee760fbc68ac97bfc34c451139;
    bytes32 constant V1_LONG_EXIT_CODE = 0x44b24679ef50e7f2d795d9c14a00ab12ab7808ed74bc66530191d4d3c5259329;
    bytes32 constant V1_LONG_REWARDS_CODE = 0x9bb731e9419ccf6b48a4206885ccceb4f0de17c855d4ab9a805ba701de83ec61;
    bytes32 constant V1_LONG_CODE = 0xde6930a86b01b4b3140858999b587b2230004bb8aad4448eb994d55e6c960ffd;
    bytes32 constant V1_FACTORY_CODE = 0x76909ca9564b3c0e7dab7eacc8883faf7199048d1ab6093cb0cb058f1f049ff6;

    string constant HUB_T =
        "StrategyHub(bytes32 profile,uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp,uint16 managementFeeBp,uint32 flatFeePerMonth)";
    string constant LONG_T =
        "AaveV3AssetLeg(bytes32 profile,address asset,address swapPool,uint24 swapFee,address rateFeed,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp)";
    string constant SHORT_T =
        "HyperCoreLeg(bytes32 profile,uint32 perp,bytes32 coin,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp)";

    address registry;
    address factory;
    bytes32 manifest;
    bytes32 profile;

    function _fork() internal returns (bool) {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url, PINNED_BLOCK);
        return true;
    }

    function _code(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat(DIR, name, ".hex")));
    }

    function _deploy(string memory name, bytes memory args) internal returns (address a) {
        bytes memory code = abi.encodePacked(_code(name), args);
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), name);
    }

    function _word(string memory s) internal pure returns (bytes32 w) {
        bytes memory b = bytes(s);
        assembly ("memory-safe") {
            w := mload(add(b, 0x20))
        }
        w &= ~bytes32(type(uint256).max >> (b.length * 8));
    }

    function _eth() internal pure returns (AssetProfileV1 memory p) {
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
        p.pins[0] = PricePinV1(Assets.ETH, 1, FeePins.ETH_USD, address(0), FeePins.ETH_USD_MAX_AGE);
    }

    /// Version 1's world on the fork: the implementations first (they name no registry), then the registry
    /// with version 1 and the ETH profile in its constructor (the genesis, checked against the chain).
    function _mesh() internal {
        address up = _deploy("VaultUpgrade", "");
        address fee = _deploy("HubFee", "");
        address hub = _deploy("Hub", abi.encode(fee, fee.codehash, up, up.codehash, Arbitrum.SEQUENCER));
        bytes memory chain = abi.encode(Arbitrum.POOL, Arbitrum.USDC, Arbitrum.RECEIVER, Arbitrum.SEQUENCER);
        address ex = _deploy("AaveV3AssetLegExit", chain);
        address rw = _deploy("AaveV3AssetLegRewards", chain);
        address long = _deploy(
            "AaveV3AssetLeg", abi.encodePacked(abi.encode(ex, ex.codehash, rw, rw.codehash, up, up.codehash), chain)
        );
        VersionMemberV1[] memory m = new VersionMemberV1[](3);
        m[0] = VersionMemberV1(1, 3, hub, hub.codehash);
        m[1] = VersionMemberV1(2, 3, long, long.codehash);
        m[2] = VersionMemberV1(3, 19, address(0xA3), keccak256("the short, HyperEVM"));
        AssetProfileV1[] memory profiles = new AssetProfileV1[](1);
        profiles[0] = _eth();
        registry = _deploy("StrategyRegistry", abi.encode(RECOVERY, address(0), uint256(1), m, profiles));
        manifest = keccak256(abi.encode(m));
        profile = keccak256(abi.encode(profiles[0]));
        assertTrue(IRegistryV1Seam(registry).profileOpen(profile), "the genesis's profile is open");
        vm.prank(RECOVERY);
        IRegistryV1Seam(registry).setExecutionKey(1, GROUP_KEY);
        LegPinV1[] memory pins = new LegPinV1[](2);
        pins[0] = LegPinV1(2, 3, Legs.LONG, Legs.VALUE_READ, "AaveV3AssetLeg",
            "bytes32 profile,address asset,address swapPool,uint24 swapFee,address rateFeed,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp", 9);
        pins[1] = LegPinV1(3, 19, Legs.SHORT, Legs.VALUE_READ, "HyperCoreLeg",
            "bytes32 profile,uint32 perp,bytes32 coin,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp", 7);
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = 3;
        factory = _deploy(
            "StrategyFactory",
            abi.encode(
                registry,
                "StrategyHub",
                "bytes32 profile,uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp,uint16 managementFeeBp,uint32 flatFeePerMonth",
                uint8(6),
                hubDomains,
                pins
            )
        );
    }

    function _spec() internal view returns (StrategySpecV1 memory c) {
        AssetProfileV1 memory p = _eth();
        c.factory = factory;
        c.group = 1;
        c.hubDomain = 3;
        c.manifest = manifest;
        c.hubParams = abi.encode(profile, uint16(5), uint16(50), uint16(1500), uint16(0), uint32(0));
        c.legs = new LegSpecV1[](2);
        c.legs[0] = LegSpecV1(
            2, 3, Legs.LONG,
            abi.encode(profile, p.asset, p.swapPool, p.swapFee, p.rateFeed, uint64(1.05e18), uint16(300), uint16(500), uint16(5))
        );
        c.legs[1] = LegSpecV1(
            3, 19, Legs.SHORT, abi.encode(profile, p.perp, p.perpCoin, p.shortAsset, uint16(500), uint16(0), uint16(50))
        );
    }

    function _createStruct(StrategySpecV1 memory c, uint256 deadline) internal view returns (bytes32) {
        bytes memory ty = abi.encodePacked(
            "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,bytes32 manifest,StrategyHub hub,AaveV3AssetLeg leg1,HyperCoreLeg leg2,uint256 deadline)",
            LONG_T,
            SHORT_T,
            HUB_T
        );
        assertEq(string(ty), IFactoryV1(factory).createVaultType(), "the factory's composed type");
        return keccak256(
            abi.encode(
                keccak256(ty), c.factory, STRATEGY, c.group, c.hubDomain, c.manifest,
                keccak256(abi.encodePacked(keccak256(bytes(HUB_T)), c.hubParams)),
                keccak256(abi.encodePacked(keccak256(bytes(LONG_T)), c.legs[0].params)),
                keccak256(abi.encodePacked(keccak256(bytes(SHORT_T)), c.legs[1].params)),
                deadline
            )
        );
    }

    function test_seamV1_theFixturesAreThePinnedBuild() public view {
        assertEq(keccak256(_code("StrategyRegistry")), V1_REGISTRY_CODE, "StrategyRegistry");
        assertEq(keccak256(_code("VaultUpgrade")), V1_UPGRADE_CODE, "VaultUpgrade");
        assertEq(keccak256(_code("HubFee")), V1_HUB_FEE_CODE, "HubFee");
        assertEq(keccak256(_code("Hub")), V1_HUB_CODE, "Hub");
        assertEq(keccak256(_code("AaveV3AssetLegExit")), V1_LONG_EXIT_CODE, "AaveV3AssetLegExit");
        assertEq(keccak256(_code("AaveV3AssetLegRewards")), V1_LONG_REWARDS_CODE, "AaveV3AssetLegRewards");
        assertEq(keccak256(_code("AaveV3AssetLeg")), V1_LONG_CODE, "AaveV3AssetLeg");
        assertEq(keccak256(_code("StrategyFactory")), V1_FACTORY_CODE, "StrategyFactory");
    }

    function test_seamV1_walletOwner() public {
        if (!_fork()) return vm.skip(true);
        _seam(WALLET_A);
    }

    function test_seamV1_passkeyOwner() public {
        if (!_fork()) return vm.skip(true);
        _seam(PASSKEY_A);
    }

    function _seam(uint256 pk) internal {
        _mesh();
        DepositFactory f = deployFactory();
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        DepositAccount a = DepositAccount(f.deploy(ALICE, one(credOf(pk))));
        setWithdrawalNow(a, pk, DEST);
        uint256[] memory v1 = new uint256[](1);
        v1[0] = 1;
        vm.prank(GROUP_KEY);
        IRegistryV1Seam(registry).checkIn(1, v1);
        StrategySpecV1 memory c = _spec();
        (address[] memory at, bytes32 configHash) = IFactoryV1(factory).memberAddresses(STRATEGY, address(a), c);
        uint256 dl = vm.getBlockTimestamp() + 7 days;

        // the typed CreateVault of version 1, under the account's domain
        bytes32 digest = IFactoryV1(factory).createDigest(STRATEGY, address(a), c, dl);
        assertEq(digest, a.hashTypedData(_createStruct(c, dl)), "the typed message, under the account's domain");
        if (pk == PASSKEY_A) {
            bytes memory noUv = signPasskeyFlags(pk, digest, 0x01);
            vm.expectRevert(bytes4(keccak256("BadSignature()")));
            IFactoryV1(factory).create(STRATEGY, address(a), c, dl, noUv);
        }
        bytes memory createSig = sign(pk, digest);
        (bool has,) = address(a).staticcall(abi.encodeCall(IOwnerRemovalsV1.removalPendingOf, (bytes32(0))));
        if (!has) {
            vm.expectRevert(bytes4(keccak256("BadOwner()")));
            IFactoryV1(factory).create(STRATEGY, address(a), c, dl, createSig);
            emit log("this branch's deposit account has no removalPendingOf: refused; the rest runs with it mocked to false");
            vm.mockCall(address(a), abi.encodeWithSelector(IOwnerRemovalsV1.removalPendingOf.selector), abi.encode(false));
        }
        uint256 g = gasleft();
        address[] memory made = IFactoryV1(factory).create(STRATEGY, address(a), c, dl, createSig);
        emit log_named_uint(pk == PASSKEY_A ? "v1 create gas, passkey" : "v1 create gas, wallet", g - gasleft());
        assertEq(made[0], at[0], "the hub, member 0");
        assertEq(made[1], at[1], "the AAVE asset leg");
        assertEq(at[0].code.length, 64, "the shared proxy");
        (address owner, bytes32 sid, bytes32 ch) = IFactoryV1(factory).authorisedFor(at[0]);
        assertEq(owner, address(a));
        assertEq(sid, STRATEGY);
        assertEq(ch, configHash);
        for (uint256 i; i < 2; ++i) {
            vm.prank(MT);
            IMemberV1(at[i]).handleReceiveFinalizedMessage(19, bytes32(uint256(uint160(at[2]))), 2000, abi.encode(READY));
        }

        // the account trusts the factory and funds the hub, never a leg
        uint256 id = authorise(a, pk, factory, 3, STRATEGY, configHash, 500e6);
        deal(ARB_USDC, address(a), 600e6);
        vm.warp(dueOf(a, factory, 3));
        a.applyAuthorisation(id);
        vm.prank(TRANSFER);
        vm.expectRevert(bytes4(keccak256("NotOwnVault()"))); // by selector: DepositAccount on master, DepositAccountState once split
        a.fund(factory, at[1], 1e6);
        vm.prank(TRANSFER);
        a.fund(factory, at[0], 500e6);
        assertEq(ITokenV1(ARB_USDC).balanceOf(at[0]), 500e6, "the hub funded");

        // an owner action through the real account, at this credential's own nonce
        bytes32 cred = a.credentialId(credOf(pk));
        uint256 n = IMemberV1(at[0]).ownerNonceOf(cred);
        dl = vm.getBlockTimestamp() + 7 days;
        bytes memory revoke = sign(
            pk,
            a.hashTypedData(
                keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, at[0], block.chainid, uint8(1), address(0), n, dl))
            )
        );
        IMemberV1(at[0]).ownerAction(1, address(0), cred, dl, revoke);
        assertTrue(IMemberV1(at[0]).executionRevoked());

        // the upgrade frame: UpgradeStrategy through the account, the hub reading removalPendingOf
        _upgradeFrame(a, pk, at[0], cred, dl);

        // BeginExit, one signature for every member; the hub's exit pays the withdrawal address
        bytes32 begin = keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, dl));
        IMemberV1(at[0]).beginExit(dl, sign(pk, a.hashTypedData(begin)));
        assertTrue(IMemberV1(at[1]).exiting(), "the local leg told");
        vm.prank(STRANGER);
        IMemberV1(at[0]).exitStep();
        assertEq(ITokenV1(ARB_USDC).balanceOf(DEST), 500e6, "paid to the withdrawal address");
    }

    /// The schedule names version 1's manifest, which is not above the hub's own: the account verifies the
    /// signature (the hub's `_checkOwnerAs`, its nonce spent in the reverted call), then the listing refuses
    /// (`NotListed`) before the account's `removalPendingOf` is asked.
    function _upgradeFrame(DepositAccount a, uint256 pk, address hub, bytes32 cred, uint256 dl) internal {
        bytes32 h = keccak256(
            abi.encode(
                keccak256("UpgradeStrategy(address hub,uint256 chainId,bytes32 manifest,uint256 nonce,uint256 deadline)"),
                hub,
                block.chainid,
                manifest,
                IMemberV1(hub).ownerNonceOf(cred),
                dl
            )
        );
        bytes memory sig = sign(pk, a.hashTypedData(h));
        vm.expectRevert(bytes4(keccak256("NotListed()")));
        IMemberV1(hub).scheduleUpgrade(manifest, cred, dl, sig);
    }
}
