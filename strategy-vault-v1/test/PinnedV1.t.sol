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

    bytes32 constant V1_REGISTRY_CODE = 0x1ad116492b0f0e5d2441041301a49549c52c44ab7eb22392899d86a2d05a64e1;
    bytes32 constant V1_UPGRADE_CODE = 0x6ac7ab0be95c9882db27fa50b5fbc2509041bb6eab69210f5994faa9a9cb9332;
    bytes32 constant V1_HUB_FEE_CODE = 0x8ad730eca56b593a0cbe363a57b3bf2e4c71202b824d284835edbb0a33a2ac1a;
    bytes32 constant V1_HUB_CODE = 0xe79b2bc5e5481afe61e7e961a82e81242b2935ee760fbc68ac97bfc34c451139;
    bytes32 constant V1_LONG_EXIT_CODE = 0x44b24679ef50e7f2d795d9c14a00ab12ab7808ed74bc66530191d4d3c5259329;
    bytes32 constant V1_LONG_REWARDS_CODE = 0x9bb731e9419ccf6b48a4206885ccceb4f0de17c855d4ab9a805ba701de83ec61;
    bytes32 constant V1_LONG_CODE = 0xde6930a86b01b4b3140858999b587b2230004bb8aad4448eb994d55e6c960ffd;
    bytes32 constant V1_SHORT_EXIT_CODE = 0xcf102f284dc70abedef9b3bd20699ecd1ffcdabe52b6d5755f5e696da878e4a4;
    bytes32 constant V1_SHORT_EXIT_B_CODE = 0x21eada971aaca8f5b3cd525a28175164e6207579cadc28a79767e11d4c313e7e;
    bytes32 constant V1_SHORT_CODE = 0xdc8b0e511d865caef80f72ad721a1486931721a59a20ae454d5a815bd462ca51;
    bytes32 constant V1_FACTORY_CODE = 0x76909ca9564b3c0e7dab7eacc8883faf7199048d1ab6093cb0cb058f1f049ff6;
    bytes32 constant V1_UPGRADE_RUNTIME_HASH = 0x5bdf1679457ebff4ae3af8681feeae29636f14834340025e3463a985c481d6ef;
    bytes32 constant V1_HUB_FEE_RUNTIME_HASH = 0xf2b7c31aa64ddf5b58dc56e6c4762dd0d24c7be02ca652189a9d518297f4d94d;
    bytes32 constant V1_LONG_EXIT_RUNTIME_HASH = 0x7fd8bb25fc21298423202e65984b94e1d2f0ae513e290fc1a8048bc5ab19dda0;
    bytes32 constant V1_LONG_REWARDS_RUNTIME_HASH = 0xddd16726fd1c07de2d5229347c3466dfbe8a138e13b529e2956c60f5773633bc;
    bytes32 constant V1_SHORT_EXIT_RUNTIME_HASH = 0xd74ed1e8fc78e7dda89bd7ceae622d76e75856ee47167e1f7c4978ed907e9293;
    bytes32 constant V1_SHORT_EXIT_B_RUNTIME_HASH = 0xaa6ee319bb56ff6473c10c36e2c35f620fa8b453c0a9541a6c78c16bc5e4f6bf;

    // the vectors (RECOVERY, the deploy script's: a PLACEHOLDER until the hardware wallet's address)
    address constant V1_REGISTRY = 0xC83716D42D6834098c3900bF73696876440489A8;
    address constant V1_FACTORY = 0xF6989dDcf67CcbC1077C9054D62F8A1363623d1d; // PINNED_VAULT_FACTORY

    // version 1's implementations (deterministic, independent of RECOVERY) and manifest: the genesis
    address constant V1_HUB_IMPL = 0x8Eb1fC836296D115C8c0BDbab080E0f98E22633B;
    bytes32 constant V1_HUB_IMPL_RUNTIME_HASH = 0x93296c09c031a16d3e9e6002939a56f23443e57bfb3a9a3c7a6d89b0f6b91965;
    address constant V1_LONG_IMPL = 0x803E6538f9b7d5A37AfE45C5615c3D774773870b;
    bytes32 constant V1_LONG_IMPL_RUNTIME_HASH = 0xbae325fb6e23958225c80f28ae662b52ae9bf3e6be0dfa170910666c46c4819a;
    address constant V1_SHORT_IMPL = 0x2d6916F8f81ae37C91f7E228e7cA45c92196d0ca;
    bytes32 constant V1_SHORT_IMPL_RUNTIME_HASH = 0xe9184660544798da239c6fe3e6dbd149f46a2481705a83f8cf51d562857f6401;
    bytes32 constant V1_MANIFEST = 0xb6f68225044351f415b4a65c25e4979ec677ea1b10c54f9ae90935ba3e2567b9;
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
        _checkRuntime("upgrade", up, V1_UPGRADE_RUNTIME_HASH);
        _checkRuntime("hub-fee", fee, V1_HUB_FEE_RUNTIME_HASH);
        _checkRuntime("short-exit", se, V1_SHORT_EXIT_RUNTIME_HASH);
        _checkRuntime("short-exit-b", seb, V1_SHORT_EXIT_B_RUNTIME_HASH);
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
