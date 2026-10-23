// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {DeployV1} from "./DeployV1.s.sol";
import {Hub} from "../src/Hub.sol";
import {HubFee} from "../src/HubFee.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {AaveV3AssetLegV2, HubV2, HyperCoreLegV2} from "../test/MocksV1.sol";
import {Credential, OwnerDomain} from "../src/interfaces/IDepositOwner.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {Legs} from "../src/lib/VaultTypes.sol";
import {
    AssetLegParams,
    AssetProfile,
    HubParams,
    HyperCoreParams,
    LegSpec,
    MemberTypes,
    OwnerMessagesV1,
    Profiles,
    StrategySpec
} from "../src/Types.sol";

interface IDepositFactoryR {
    function deploy(bytes32 user, Credential[] calldata owners) external returns (address);
    function addressOf(bytes32 user, Credential[] calldata owners) external view returns (address);
}

/*
 * THE VERSION-1 REDEPLOY'S END-TO-END REHEARSAL on local anvil forks (deploy-factories.md §0c,
 * `scripts/fork-rehearsal/v1-redeploy.sh` drives it), NEVER against a real network: anvil's public test
 * keys only. One PHASE per run, on the chain `--rpc-url` names:
 *
 *   account        (both chains)  the owner's deposit account at its genesis, through the deposit factory
 *   create         (both chains)  an ETH and a BTC strategy, the owner's typed CreateVault of version 1
 *                                 signed once (no chain id: the same signature on both chains); on
 *                                 Arbitrum the hubs' `managementFee()`, both knobs 0
 *   v2-short       (HyperEVM)     version 2's short (a test mock naming the registry), its hash printed
 *   v2-arb         (Arbitrum)     version 2's hub and long, likewise
 *   upgrade        (Arbitrum)     the owner's UpgradeStrategy to version 2 scheduled at the ETH hub
 *   cancel         (Arbitrum)     then cancelled by the owner's CancelPendingAction: nothing moves
 *   hatch          (Arbitrum)     7 days without a check-in: `stopped(0, 1)`, then anyone's
 *                                 `beginExitStopped` and `exitStep` on the BTC hub
 *
 * Env: DEPOSIT (the deposit factory), OWNER_PK (the owner's wallet, an anvil key), and the deployer's
 * key through `--private-key`.
 */
contract RehearseV1 is Script {
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant USER = keccak256("rehearsal-user");
    uint256 constant DEADLINE = 1_900_000_000;

    DeployV1 d;
    StrategyRegistry registry;
    StrategyFactory factory;

    function run() external {
        (bool cancun,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(cancun, "setEvmVersion"); // the members' shared proxy has PUSH0, as both chains run
        d = new DeployV1();
        registry = StrategyRegistry(d.registryOf(d.RECOVERY()));
        factory = StrategyFactory(d.factoryOf(d.RECOVERY()));
        bytes32 phase = keccak256(bytes(vm.envString("PHASE")));
        if (phase == keccak256("account")) _account();
        else if (phase == keccak256("create")) _create();
        else if (phase == keccak256("v2-short")) _v2Short();
        else if (phase == keccak256("v2-arb")) _v2Arb();
        else if (phase == keccak256("upgrade")) _upgrade();
        else if (phase == keccak256("cancel")) _cancel();
        else if (phase == keccak256("hatch")) _hatch();
        else revert("PHASE: account | create | v2-short | v2-arb | upgrade | cancel | hatch");
    }

    function _owners() internal view returns (Credential[] memory c) {
        c = new Credential[](1);
        c[0] = OwnerDomain.wallet(vm.addr(vm.envUint("OWNER_PK")));
    }

    function _account() internal {
        IDepositFactoryR f = IDepositFactoryR(vm.envAddress("DEPOSIT"));
        vm.startBroadcast();
        address a = f.deploy(USER, _owners());
        vm.stopBroadcast();
        console.log("deposit account (genesis)", a, "chain", block.chainid);
        console.log("its implementation slot");
        console.logBytes32(vm.load(a, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc));
    }

    function _ownerAccount() internal view returns (address) {
        return IDepositFactoryR(vm.envAddress("DEPOSIT")).addressOf(USER, _owners());
    }

    function _spec(AssetProfile memory p) internal view returns (StrategySpec memory c) {
        bytes32 id = Profiles.id(p);
        c.factory = address(factory);
        c.group = 0;
        c.hubDomain = 3;
        c.manifest = registry.manifestOf(1);
        c.hubParams = abi.encode(HubParams(id, 5, 50, 1500, 0, 0));
        c.legs = new LegSpec[](2);
        c.legs[0] = LegSpec(
            MemberTypes.AAVE_V3_ASSET, 3, Legs.LONG,
            abi.encode(AssetLegParams(id, p.asset, p.swapPool, p.swapFee, p.rateFeed, 1.15e18, 300, 50, 5))
        );
        c.legs[1] = LegSpec(
            MemberTypes.HYPERCORE, 19, Legs.SHORT, abi.encode(HyperCoreParams(id, p.perp, p.perpCoin, p.shortAsset, 100, 0, 50))
        );
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(vm.envUint("OWNER_PK"), digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _create() internal {
        address owner = _ownerAccount();
        AssetProfile[2] memory profiles = [d.ethProfile(), d.btcProfile()];
        string[2] memory names = ["ETH", "BTC"];
        for (uint256 i; i < 2; ++i) {
            StrategySpec memory c = _spec(profiles[i]);
            bytes32 sid = keccak256(abi.encode("rehearsal", names[i]));
            bytes memory sig = _sign(factory.createDigest(sid, owner, c, DEADLINE));
            vm.startBroadcast();
            address[] memory made = factory.create(sid, owner, c, DEADLINE, sig);
            vm.stopBroadcast();
            (address[] memory at,) = factory.memberAddresses(sid, owner, c);
            console.log(names[i], "strategy on chain", block.chainid);
            for (uint256 k; k < made.length; ++k) {
                console.log("  member", made[k]);
            }
            if (block.chainid == 42161) {
                (uint16 rate, uint16 signedRate, uint32 flat, uint32 signedFlat,,,,,,,) = HubFee(at[0]).managementFee();
                console.log("  hub", at[0]);
                console.log("  managementFee: rate, signed rate (bp a year)", rate, signedRate);
                console.log("  managementFee: flat, signed flat (USDC units a month)", flat, signedFlat);
                require(rate == 0 && signedRate == 0 && flat == 0 && signedFlat == 0, "both knobs 0");
                console.log("  profile");
                console.logBytes32(Hub(at[0]).profile());
            }
        }
    }

    /// A version-2 implementation through the deterministic deployer (its address the same for the
    /// manifest on both chains): `code` with `args` (a test mock: rehearsal only, never pinned).
    function _deploy2(string memory label, bytes memory code, bytes memory args) internal returns (address at) {
        bytes memory init = abi.encodePacked(code, args);
        bytes32 salt = keccak256(abi.encode("dltx.rehearsal.v2", label));
        at = d.predict(salt, init);
        if (at.code.length == 0) {
            vm.startBroadcast();
            (bool ok,) = DEPLOYER.call(abi.encodePacked(salt, init));
            vm.stopBroadcast();
            require(ok && at.code.length > 0, label);
        }
        console.log(label, at);
        console.logBytes32(at.codehash);
    }

    function _module(string memory what) internal view returns (address at, bytes32 runtime) {
        bytes32 salt;
        bytes memory init;
        (salt, init, runtime) = d.initOf(what, d.RECOVERY());
        at = d.predict(salt, init);
    }

    function _v2Short() internal {
        (address e, bytes32 eh) = _module("short-exit");
        (address b, bytes32 bh) = _module("short-exit-b");
        (address u, bytes32 uh) = _module("upgrade");
        _deploy2("SHORT_V2", type(HyperCoreLegV2).creationCode, abi.encode(e, eh, b, bh, u, uh, address(registry)));
    }

    function _v2Arb() internal {
        (address fee, bytes32 feeh) = _module("hub-fee");
        (address u, bytes32 uh) = _module("upgrade");
        (address le, bytes32 leh) = _module("long-exit");
        (address lr, bytes32 lrh) = _module("long-rewards");
        _deploy2("HUB_V2", type(HubV2).creationCode, abi.encode(fee, feeh, u, uh, address(registry), Arbitrum.SEQUENCER));
        _deploy2(
            "LONG_V2",
            type(AaveV3AssetLegV2).creationCode,
            abi.encode(le, leh, lr, lrh, u, uh, address(registry), Arbitrum.POOL, Arbitrum.USDC, Arbitrum.RECEIVER, Arbitrum.SEQUENCER)
        );
    }

    function _ethHub() internal view returns (address hub) {
        StrategySpec memory c = _spec(d.ethProfile());
        (address[] memory at,) = factory.memberAddresses(keccak256(abi.encode("rehearsal", "ETH")), _ownerAccount(), c);
        hub = at[0];
    }

    function _upgrade() internal {
        address owner = _ownerAccount();
        address hub = _ethHub();
        bytes32 manifest2 = registry.manifestOf(2);
        require(manifest2 != bytes32(0), "version 2 not listed here");
        bytes32 cred = keccak256(abi.encode(OwnerDomain.WALLET, bytes32(uint256(uint160(vm.addr(vm.envUint("OWNER_PK"))))), bytes32(0)));
        uint256 nonce = MemberState(hub).ownerNonceOf(cred);
        bytes memory sig = _sign(
            OwnerDomain.digest(
                owner, keccak256(abi.encode(OwnerMessagesV1.UPGRADE_STRATEGY_TYPEHASH, hub, block.chainid, manifest2, nonce, DEADLINE))
            )
        );
        vm.startBroadcast();
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, DEADLINE, sig);
        vm.stopBroadcast();
        (uint8 kind, uint64 due, bytes32 by, bytes32 target) = VaultUpgrade(hub).pendingAction();
        console.log("upgrade scheduled at the ETH hub", hub);
        console.log("  kind, due", kind, due);
        console.logBytes32(target);
        require(kind == OwnerMessagesV1.KIND_UPGRADE && target == manifest2 && by == cred, "scheduled");
    }

    /// The owner's CancelPendingAction for what is pending at the ETH hub, read on chain (its due is the
    /// schedule's block's, which the owner's wallet reads before signing).
    function _cancel() internal {
        address owner = _ownerAccount();
        address hub = _ethHub();
        (uint8 kind, uint64 due,, bytes32 target) = VaultUpgrade(hub).pendingAction();
        require(kind == OwnerMessagesV1.KIND_UPGRADE, "no upgrade pending");
        bytes memory cancel = _sign(
            OwnerDomain.digest(
                owner,
                keccak256(
                    abi.encode(
                        OwnerMessagesV1.CANCEL_PENDING_ACTION_TYPEHASH, hub, block.chainid, kind, target, uint256(due), DEADLINE
                    )
                )
            )
        );
        vm.startBroadcast();
        VaultUpgrade(hub).cancelPendingAction(kind, target, due, DEADLINE, cancel);
        vm.stopBroadcast();
        (kind,,,) = VaultUpgrade(hub).pendingAction();
        require(kind == 0 && MemberState(hub).codeVersion() == 1, "cancelled: still version 1");
        console.log("  cancelled by the owner: nothing pending, the hub on version", MemberState(hub).codeVersion());
    }

    function _hatch() internal {
        require(registry.stopped(0, 1), "group 0 is not stopped on version 1");
        StrategySpec memory c = _spec(d.btcProfile());
        (address[] memory at,) = factory.memberAddresses(keccak256(abi.encode("rehearsal", "BTC")), _ownerAccount(), c);
        Hub hub = Hub(at[0]);
        vm.startBroadcast();
        MemberBase(address(hub)).beginExitStopped();
        hub.exitStep();
        vm.stopBroadcast();
        console.log("escape hatch: stopped(0, 1) true; the BTC hub exiting:", hub.exiting());
        require(hub.exiting(), "exiting");
    }
}
