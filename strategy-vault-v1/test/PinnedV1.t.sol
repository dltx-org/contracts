// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {DeployV1} from "../script/DeployV1.s.sol";
import {AssetProfile, Manifests, MemberTypes, Profiles, VersionMember} from "../src/Types.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {ProxyInitCode} from "../src/ProxyInitCode.sol";
import {CoreState, PrecompileStub} from "./mocks/Mocks.sol";

/*
 * VERSION 1'S PINNED BUILD (as test/Pinned.t.sol for version 0). Every contract lands through the
 * deterministic deployer: its address is the hash of its creation code with its arguments, so any change
 * to a source or the compiler profile moves the hashes below, and `script/DeployV1.s.sol` refuses a build
 * that isn't this one (`test.mjs` checks the two files carry the same hashes). Update them, the
 * deposit contract's `PINNED_VAULT_FACTORY`, and every address derived, before anything is deployed.
 *
 * The vectors are the engine's (`engine/evm`, `engine/owner`): the registry's and the factory's addresses
 * for version 0's recovery `0x5491…07D7` (the factory is the deposit contract's PINNED_VAULT_FACTORY:
 * `CREATE2(deployer, keccak256("dltx.vault.v1.factory"), keccak256(creation code ‖ arguments))`, its
 * arguments the registry and version 1's topology, no code), and, on an Arbitrum fork, the AAVE modules'
 * runtime hashes (they carry Arbitrum's facts) and version 1's manifest.
 */
/// HyperCore's `perpAssetInfo` answer.
struct PerpInfoV1 {
    string coin;
    uint32 marginTableId;
    uint8 szDecimals;
    uint8 maxLeverage;
    bool onlyIsolated;
}

contract PinnedV1Test is Test {
    address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address constant RECOVERY = 0x549178f84C788801A4528977a740A9672D2A07D7;
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant HYPER_STATE = 0x00000000000000000000000000000000c0eC0dE0;

    bytes32 constant V1_REGISTRY_CODE = 0xe48b2616616ece99d5808a0449d05070c05f105181a6803025767a8381674982;
    bytes32 constant V1_UPGRADE_CODE = 0xfed82dcb610541112276c8aa95c704d3c89e4b15665673ef98a77668ced13384;
    bytes32 constant V1_HUB_FEE_CODE = 0x168a8e159e1bdc84213f888fbfcbf0e8c3d5c269f9dc96e5ba3696d349fcd91b;
    bytes32 constant V1_HUB_CODE = 0xfd7fa471f2687c6224d2223d70d46c9b0bb3c527947891a1c234f984f090822e;
    bytes32 constant V1_LONG_EXIT_CODE = 0xf8ea056a6c89e65e3d0140524f8b0ef01c6a413909ad7d1384775830d03addf1;
    bytes32 constant V1_LONG_REWARDS_CODE = 0x668bf2684481b0ec3f9ecfc8d4265961c08105e0cf44db90a40b770a223fd065;
    bytes32 constant V1_LONG_CODE = 0x4e1cb9cf59e565d945d3dcc5855ed58cd44c5fc717e1fe97043d06afd1d07381;
    bytes32 constant V1_SHORT_EXIT_CODE = 0x029e8b38714e1c400da0eda3d99a021825b4b60aa04c09a3ceb85ae128e5d7f8;
    bytes32 constant V1_SHORT_EXIT_B_CODE = 0x06cedbe2ff70862d549f91bcfcd02138d3399d24c05e7677704ac6ec220b88a1;
    bytes32 constant V1_SHORT_ROUTE_CODE = 0x4e45a53b4004b099aa2c97d4e0ef3333714a200c41170ea9038be499eb8f5311;
    bytes32 constant V1_SHORT_CODE = 0x40a38048e72e5d0f3f4ab35c40dd6817d21c4172245f79997a9b0ca6ed51d2d4;
    bytes32 constant V1_FACTORY_CODE = 0xbe8b2ce88fa238704d044b7ec8e9edd8111f2d32dd495627199edbd26c12c3b9;
    bytes32 constant V1_UPGRADE_RUNTIME_HASH = 0x9c68dad54fa71396143090ac811af87bc4261607513311df72bdf6c21d6d5ac3;
    bytes32 constant V1_HUB_FEE_RUNTIME_HASH = 0x63803b9a8925094ad40e99bacca1ee8e62b80d316e6842cf1047c2bef3a08465;
    bytes32 constant V1_LONG_EXIT_RUNTIME_HASH = 0xe692b4628156f743cda2084f6873901798d5fde7ddd2aed49fe433b29bea68f6;
    bytes32 constant V1_LONG_REWARDS_RUNTIME_HASH = 0x6360520231370c3cb53bb7d92f547c8244342bdc770ace57cce46af419bc38fe;
    bytes32 constant V1_SHORT_EXIT_RUNTIME_HASH = 0x84ed06a43fe68f07e793fee055aea68199f111f653e894002289df90afd58c1d;
    bytes32 constant V1_SHORT_EXIT_B_RUNTIME_HASH = 0xedb625e68f994bdb734accd1e84192c57921154f0a3d2129d4e5e4706cbfc164;
    bytes32 constant V1_SHORT_ROUTE_RUNTIME_HASH = 0xa8d9109f2e429a28f6f1b760277d2dc012b8501fce387868c64394782cc6b2c9;

    // the vectors (RECOVERY, the deploy script's: a PLACEHOLDER until the hardware wallet's address)
    address constant V1_REGISTRY = 0x738F5d2b4B5db95A6741a07f6E8EdaAf56fB1eC5;
    address constant V1_FACTORY = 0x05C8c664b5484ed764f8C53e72c182fE071ceAA9; // PINNED_VAULT_FACTORY

    // version 1's implementations (deterministic, independent of RECOVERY) and manifest: the genesis
    address constant V1_HUB_IMPL = 0x04731698C1f9DF9b548659032c6588C4C2B06264;
    bytes32 constant V1_HUB_IMPL_RUNTIME_HASH = 0xfc4e7eec650b78e2a920f9a4e6f8c3dfc950ccd5f20932952038a09efc225cc0;
    address constant V1_LONG_IMPL = 0x731630faE2Eb852cBB8DbF2DD4aFf2e946F6c3B8;
    bytes32 constant V1_LONG_IMPL_RUNTIME_HASH = 0x1a6740b72cce4afc4d2b44ebefb60ca607063d56f13a47dfe9569f99fb0ac60d;
    address constant V1_SHORT_IMPL = 0x2117461DAE79dA83b2d74D4E97F0a8e336229956;
    bytes32 constant V1_SHORT_IMPL_RUNTIME_HASH = 0x08e9b8f3679fc92978ca6cb1fbb43ba268f8fbcbcc970352a029e5298a7205c1;
    bytes32 constant V1_MANIFEST = 0x4d87a3d47fadf9333e7bc107dcdffd93fb111da9bb7b03bbf0065c2480788df7;
    bytes32 constant ETH_PROFILE = 0x39a05622f1cdb348a942e419f7692092319f00b31ca5350f66a556fe25a6434a;
    bytes32 constant BTC_PROFILE = 0xd714870e84be29bc90f0a4ac10bab72a63e27a5c4fc139dcdd2aac3070300d12;

    DeployV1 script;

    function setUp() public {
        script = new DeployV1();
    }

    function _code(string memory name) internal view returns (bytes memory) {
        return vm.getCode(string.concat(name, ".sol:", name));
    }

    function _check(string memory name, bytes32 pinned) internal view {
        bytes32 h = keccak256(_code(name));
        if (h != pinned) {
            console.log(name);
            console.logBytes32(h);
        }
        assertEq(h, pinned, name);
    }

    function test_v1_creationCodesArePinned() public view {
        _check("StrategyRegistry", V1_REGISTRY_CODE);
        _check("VaultUpgrade", V1_UPGRADE_CODE);
        _check("HubFee", V1_HUB_FEE_CODE);
        _check("Hub", V1_HUB_CODE);
        _check("AaveV3AssetLegExit", V1_LONG_EXIT_CODE);
        _check("AaveV3AssetLegRewards", V1_LONG_REWARDS_CODE);
        _check("AaveV3AssetLeg", V1_LONG_CODE);
        _check("HyperCoreLegExit", V1_SHORT_EXIT_CODE);
        _check("HyperCoreLegExitB", V1_SHORT_EXIT_B_CODE);
        _check("HyperCoreLegRoute", V1_SHORT_ROUTE_CODE);
        _check("HyperCoreLeg", V1_SHORT_CODE);
        _check("StrategyFactory", V1_FACTORY_CODE);
    }

    function _deploy(string memory what) internal returns (address made) {
        (bytes32 salt, bytes memory init,) = script.initOf(what, RECOVERY);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, init));
        g -= gasleft();
        require(ok && ret.length == 20, string.concat("deterministic deployment failed: ", what));
        made = address(bytes20(ret));
        assertEq(made, script.predict(salt, init));
        console.log(what, made, g);
    }

    /// The registry and the factory are the script's, for the script's RECOVERY; the genesis is version 1's
    /// manifest and the two profiles; the modules without immutables and the short land as pinned.
    function test_v1_deploymentVectors() public {
        assertEq(script.RECOVERY(), RECOVERY, "the script's RECOVERY is the vectors'");
        vm.etch(DETERMINISTIC_DEPLOYER, DEPLOYER_RUNTIME);
        vm.etch(TRANSMITTER, hex"00");
        address up = _deploy("upgrade");
        address fee = _deploy("hub-fee");
        address se = _deploy("short-exit");
        address seb = _deploy("short-exit-b");
        address sr = _deploy("short-route");
        _checkRuntime("upgrade", up, V1_UPGRADE_RUNTIME_HASH);
        _checkRuntime("hub-fee", fee, V1_HUB_FEE_RUNTIME_HASH);
        _checkRuntime("short-exit", se, V1_SHORT_EXIT_RUNTIME_HASH);
        _checkRuntime("short-exit-b", seb, V1_SHORT_EXIT_B_RUNTIME_HASH);
        _checkRuntime("short-route", sr, V1_SHORT_ROUTE_RUNTIME_HASH);
        address short = _deploy("short");
        _checkVector("V1_SHORT_IMPL", short, V1_SHORT_IMPL);
        _checkRuntime("V1_SHORT_IMPL_RUNTIME_HASH", short, V1_SHORT_IMPL_RUNTIME_HASH);
        VersionMember[] memory m = script.genesisMembers();
        _checkVector("V1_HUB_IMPL", m[0].implementation, V1_HUB_IMPL);
        _checkVector("V1_LONG_IMPL", m[1].implementation, V1_LONG_IMPL);
        assertEq(m[2].implementation, short);
        bytes32 h = Manifests.hash(m);
        if (h != V1_MANIFEST) console.logBytes32(h);
        assertEq(h, V1_MANIFEST, "the genesis is version 1's manifest");
        AssetProfile[] memory p = script.genesisProfiles();
        assertEq(p.length, 2);
        assertEq(Profiles.id(p[0]), ETH_PROFILE);
        assertEq(Profiles.id(p[1]), BTC_PROFILE);
        // the registry deploys on a chain with its implementations (the fork tests); its address is the
        // hash of its arguments, here; the factory needs no registry code
        address factory = _deploy("factory");
        assertEq(factory, script.factoryOf(RECOVERY));
        assertEq(StrategyFactory(factory).registry(), script.registryOf(RECOVERY));
        assertEq(StrategyFactory(factory).PROXY_INIT_CODE_HASH(), ProxyInitCode.HASH);
        _checkVector("registry", script.registryOf(RECOVERY), V1_REGISTRY);
        _checkVector("factory (PINNED_VAULT_FACTORY)", factory, V1_FACTORY);
    }

    function _checkRuntime(string memory what, address a, bytes32 pinned) internal view {
        if (a.codehash != pinned) {
            console.log(what, "runtime:");
            console.logBytes32(a.codehash);
        }
        assertEq(a.codehash, pinned, what);
    }

    function _checkVector(string memory what, address a, address pinned) internal pure {
        if (a != pinned) console.log(what, a);
        assertEq(a, pinned, what);
    }

    /// HyperCore's precompiles are the node's, not the EVM's: the stubs play perpAssetInfo for ETH (1) and
    /// BTC (0) with the node's own answers, which the genesis's profile checks read (AP-3).
    function _playHyperCore() internal {
        vm.etch(HYPER_STATE, type(CoreState).runtimeCode);
        for (uint160 a = 0x800; a <= 0x810; ++a) {
            vm.etch(address(a), type(PrecompileStub).runtimeCode);
        }
        for (uint32 perp; perp < 2; ++perp) {
            bytes memory info = vm.rpc(
                "eth_call",
                string.concat(
                    '[{"to":"0x000000000000000000000000000000000000080a","data":"', vm.toString(abi.encode(perp)), '"},"latest"]'
                )
            );
            PerpInfoV1 memory pi = abi.decode(info, (PerpInfoV1));
            CoreState(HYPER_STATE).setOracle(perp, 1, pi.szDecimals);
            CoreState(HYPER_STATE).setCoin(perp, pi.coin);
        }
    }

    /// The registry as deployed: version 1 listed and both profiles open from its constructor, check-ins
    /// seeded, nothing proposed.
    function _checkGenesis(address registry) internal view {
        StrategyRegistry r = StrategyRegistry(registry);
        assertEq(r.recovery(), RECOVERY);
        assertEq(r.latestVersion(), 1);
        assertEq(r.manifestOf(1), V1_MANIFEST);
        assertEq(r.versionOf(V1_MANIFEST), 1);
        assertEq(r.acceptedAt(1), block.timestamp);
        assertTrue(r.profileOpen(ETH_PROFILE));
        assertTrue(r.profileOpen(BTC_PROFILE));
        assertEq(r.profileIds().length, 2);
        assertEq(r.feeAddress(), address(0));
    }

    /// On an Arbitrum fork: the AAVE modules (Arbitrum's facts as immutables), the hub and the long, then the
    /// registry (its genesis checked against Arbitrum's AAVE, pools and feeds) and the factory, at the
    /// vectors. SKIPPED without ARBITRUM_RPC_URL.
    function test_v1_arbitrumVectors() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, 517_200_797);
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        script = new DeployV1(); // the fork's own (setUp's is on the other chain)
        assertEq(DETERMINISTIC_DEPLOYER.codehash, keccak256(DEPLOYER_RUNTIME));
        _deploy("upgrade");
        _deploy("hub-fee");
        address le = _deploy("long-exit");
        address lr = _deploy("long-rewards");
        _checkRuntime("long-exit", le, V1_LONG_EXIT_RUNTIME_HASH);
        _checkRuntime("long-rewards", lr, V1_LONG_REWARDS_RUNTIME_HASH);
        address hub = _deploy("hub");
        address long = _deploy("long");
        _checkVector("V1_HUB_IMPL", hub, V1_HUB_IMPL);
        _checkRuntime("V1_HUB_IMPL_RUNTIME_HASH", hub, V1_HUB_IMPL_RUNTIME_HASH);
        _checkVector("V1_LONG_IMPL", long, V1_LONG_IMPL);
        _checkRuntime("V1_LONG_IMPL_RUNTIME_HASH", long, V1_LONG_IMPL_RUNTIME_HASH);
        address registry = _deploy("registry");
        _checkVector("registry", registry, V1_REGISTRY);
        _checkGenesis(registry);
        address factory = _deploy("factory");
        _checkVector("factory (PINNED_VAULT_FACTORY)", factory, V1_FACTORY);
    }

    /// On a HyperEVM fork: the short and its modules, then the same registry (its genesis checked against
    /// HyperCore) and factory at the same addresses. SKIPPED when HyperEVM can't be reached.
    function test_v1_hyperEvmVectors() public {
        string memory url = vm.envOr("HYPEREVM_RPC_URL", string("https://rpc.hyperliquid.xyz/evm"));
        try vm.createSelectFork(url, 48_521_917) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        _playHyperCore();
        script = new DeployV1();
        assertEq(DETERMINISTIC_DEPLOYER.codehash, keccak256(DEPLOYER_RUNTIME));
        _deploy("upgrade");
        _deploy("short-exit");
        _deploy("short-exit-b");
        _deploy("short-route");
        address short = _deploy("short");
        _checkVector("V1_SHORT_IMPL", short, V1_SHORT_IMPL);
        _checkRuntime("V1_SHORT_IMPL_RUNTIME_HASH", short, V1_SHORT_IMPL_RUNTIME_HASH);
        address registry = _deploy("registry");
        _checkVector("registry", registry, V1_REGISTRY);
        _checkGenesis(registry);
        address factory = _deploy("factory");
        _checkVector("factory (PINNED_VAULT_FACTORY)", factory, V1_FACTORY);
    }
}
