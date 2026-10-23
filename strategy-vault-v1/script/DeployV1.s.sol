// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {AssetProfile, AssetsV1, MemberTypes, ParamsTypesV1, PricePin, Profiles, VersionMember} from "../src/Types.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {FeePins} from "../src/lib/FeePins.sol";
import {PriceSource} from "../src/lib/PriceSource.sol";
import {Assets, Legs} from "../src/lib/VaultTypes.sol";

/*
 * Deploy ONE contract of the strategy vaults' VERSION 1 (asset-profiles-design.md §10 slice 8,
 * owner-upgrades-design.md §12) through the deterministic deployer, from `master`, the pinned build
 * (test/PinnedV1.t.sol), one CONTRACT per run, in this order:
 *
 *   1. upgrade        Arbitrum, HyperEVM            —
 *   2. hub-fee        Arbitrum                      —
 *   3. hub            Arbitrum                      —  its modules computed
 *   4. long-exit      Arbitrum                      —  (Arbitrum's facts: AAVE's pool, USDC, the receiver,
 *   5. long-rewards   Arbitrum                      —   the sequencer feed: constructor data, Q11)
 *   6. long           Arbitrum                      —  its modules computed
 *   7. short-exit     HyperEVM (big blocks)         —
 *   8. short-exit-b   HyperEVM (big blocks)         —
 *   9. short          HyperEVM (big blocks)         —  its modules computed
 *  10. registry       Arbitrum, HyperEVM (big)      RECOVERY, version 1's members, the ETH and BTC profiles
 *  11. factory        Arbitrum, HyperEVM            RECOVERY (its registry)
 *
 *   CONTRACT=<name> EXPECTED=0x… \
 *   forge script script/DeployV1.s.sol --rpc-url <chain> --broadcast --skip-simulation --verify --private-key $DEPLOYER_KEY
 *
 * `--skip-simulation`: forge's replay of the transactions runs the project's `paris` EVM, where Arbitrum's
 * live contracts (PUSH0), which the AAVE modules' and the long's constructors call, do not run; `run()`
 * itself simulates on Cancun, and the node estimates the gas (deploy-factories.md §0c, rehearsed).
 *
 * ⚠ The REGISTRY on HyperEVM: forge runs `run()` in its own EVM before it broadcasts, where HyperCore's
 * precompiles do not exist, so the genesis's profile check (AP-3, `perpAssetInfo`) reverts there and
 * nothing is sent. Run it with `PRINT_CALLDATA=1` instead: the script checks everything, prints the
 * deterministic deployer's calldata and the address, and broadcasts nothing; then send that calldata to
 * the deployer with `cast send` (big blocks, an explicit gas limit: the node runs the real precompiles).
 *
 * THE GENESIS (the operator's decision of 2026-10-23): the registry's constructor lists version 1 (its
 * manifest: `genesisMembers()`) and opens the ETH and BTC profiles (`genesisProfiles()`) at once, no 7-day
 * wait; so the implementations name no registry and come first, the registry checks the local ones (code
 * hash, version, type) and runs each profile's checks on this chain (AP-3) in its constructor. Its
 * arguments are the same on both chains, so it has one address; so has the factory, which names it: the
 * deposit contract's `PINNED_VAULT_FACTORY` (owner-upgrades-design.md §8). Version 2 and every later
 * profile take the public 7 days.
 *
 * RECOVERY is ONE constant below, the registry's only authority (and so the factory's address): every
 * pin downstream derives from it. It is a PLACEHOLDER (version 0's hot key) until the operator's hardware
 * wallet's address replaces it, with `node scripts/repin-v1.mjs --recovery <address>` (the whole cascade, one
 * step: deploy-factories.md §5c). The implementations, the modules and the manifest do not depend on it.
 *
 * Every address is computed from the pinned build and the deployer; the script refuses a build, a key or
 * a deployer that would put a contract elsewhere, and a module or implementation whose runtime is not its
 * pinned one (the implementations name their modules' code hashes: the partner's audit L1, never
 * `type(...).runtimeCode`). Nothing obeys anybody until RECOVERY sets each group's key.
 */
contract DeployV1 is Script {
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// The registry's only authority; the factory's address follows it. PLACEHOLDER: version 0's hot key until the hardware wallet's address (`scripts/repin-v1.mjs --recovery`).
    address public constant RECOVERY = 0x549178f84C788801A4528977a740A9672D2A07D7;
    bytes32 constant DEPLOYER_CODEHASH = keccak256(
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
    );

    bytes32 constant REGISTRY_SALT = keccak256("dltx.vault.v1.registry");
    bytes32 constant UPGRADE_SALT = keccak256("dltx.vault.v1.upgrade");
    bytes32 constant HUB_FEE_SALT = keccak256("dltx.vault.v1.hub-fee");
    bytes32 constant HUB_SALT = keccak256("dltx.vault.v1.hub");
    bytes32 constant LONG_EXIT_SALT = keccak256("dltx.vault.v1.long-exit");
    bytes32 constant LONG_REWARDS_SALT = keccak256("dltx.vault.v1.long-rewards");
    bytes32 constant LONG_SALT = keccak256("dltx.vault.v1.long");
    bytes32 constant SHORT_EXIT_SALT = keccak256("dltx.vault.v1.short-exit");
    bytes32 constant SHORT_EXIT_B_SALT = keccak256("dltx.vault.v1.short-exit-b");
    bytes32 constant SHORT_SALT = keccak256("dltx.vault.v1.short");
    bytes32 constant FACTORY_SALT = keccak256("dltx.vault.v1.factory");

    // The pinned build: test/PinnedV1.t.sol's creation-code hashes (no arguments).
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
    // The modules' runtime code hashes as deployed (the AAVE modules carry Arbitrum's facts as immutables).
    bytes32 constant V1_UPGRADE_RUNTIME_HASH = 0x5bdf1679457ebff4ae3af8681feeae29636f14834340025e3463a985c481d6ef;
    bytes32 constant V1_HUB_FEE_RUNTIME_HASH = 0xf2b7c31aa64ddf5b58dc56e6c4762dd0d24c7be02ca652189a9d518297f4d94d;
    bytes32 constant V1_LONG_EXIT_RUNTIME_HASH = 0x7fd8bb25fc21298423202e65984b94e1d2f0ae513e290fc1a8048bc5ab19dda0;
    bytes32 constant V1_LONG_REWARDS_RUNTIME_HASH = 0xddd16726fd1c07de2d5229347c3466dfbe8a138e13b529e2956c60f5773633bc;
    bytes32 constant V1_SHORT_EXIT_RUNTIME_HASH = 0xd74ed1e8fc78e7dda89bd7ceae622d76e75856ee47167e1f7c4978ed907e9293;
    bytes32 constant V1_SHORT_EXIT_B_RUNTIME_HASH = 0xaa6ee319bb56ff6473c10c36e2c35f620fa8b453c0a9541a6c78c16bc5e4f6bf;
    // Version 1's implementations as deployed (the hub and the long carry Arbitrum's facts): the genesis.
    bytes32 constant V1_HUB_IMPL_RUNTIME_HASH = 0x93296c09c031a16d3e9e6002939a56f23443e57bfb3a9a3c7a6d89b0f6b91965;
    bytes32 constant V1_LONG_IMPL_RUNTIME_HASH = 0xbae325fb6e23958225c80f28ae662b52ae9bf3e6be0dfa170910666c46c4819a;
    bytes32 constant V1_SHORT_IMPL_RUNTIME_HASH = 0xe9184660544798da239c6fe3e6dbd149f46a2481705a83f8cf51d562857f6401;

    function run() external returns (address made) {
        // forge simulates with the project's `paris` EVM; the AAVE modules' and the long's constructors
        // call Arbitrum's live contracts (Q11), which use later opcodes (PUSH0): simulate on Cancun. A
        // cheatcode: no bytecode changes, and the broadcast runs on the chain's own EVM
        (bool cancun,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(cancun, "setEvmVersion");
        _checkBuild();
        require(DEPLOYER.codehash == DEPLOYER_CODEHASH, "no canonical deterministic deployer on this chain");
        string memory what = vm.envString("CONTRACT");
        (bytes32 salt, bytes memory init, bytes32 runtime) = initOf(what, RECOVERY);
        require(init.length > 0, "CONTRACT: upgrade | hub-fee | hub | long-exit | long-rewards | long | short-exit | short-exit-b | short | registry | factory");
        if (keccak256(bytes(what)) == keccak256("registry")) {
            // the genesis: every implementation of this chain first, as pinned (the constructor checks them)
            uint32 here = block.chainid == 42161 ? 3 : block.chainid == 999 ? 19 : type(uint32).max;
            VersionMember[] memory m = genesisMembers();
            for (uint256 i; i < m.length; ++i) {
                if (m[i].domain != here) continue;
                require(m[i].implementation.code.length > 0, "deploy this chain's implementations before the registry");
                require(m[i].implementation.codehash == m[i].codeHash, "an implementation here is not the pinned one");
            }
        }
        address predicted = predict(salt, init);
        address expected = vm.envOr("EXPECTED", address(0));
        if (expected == address(0)) {
            console.log("FIRST DEPLOYMENT of", what, ": every later chain must expect", predicted);
        } else {
            require(predicted == expected, "this build and these inputs would not land at EXPECTED");
        }
        require(predicted.code.length == 0, "already deployed here");
        if (vm.envOr("PRINT_CALLDATA", false)) {
            console.log("send to the deterministic deployer", DEPLOYER, "this calldata; it lands at", predicted);
            console.logBytes(abi.encodePacked(salt, init));
            return predicted;
        }
        vm.startBroadcast();
        (bool ok, bytes memory ret) = DEPLOYER.call(abi.encodePacked(salt, init));
        vm.stopBroadcast();
        require(ok && ret.length == 20 && address(bytes20(ret)) == predicted, "deployment failed");
        require(runtime == bytes32(0) || predicted.codehash == runtime, "the module's runtime is not the pinned one");
        made = predicted;
        console.log(what, made, "chain", block.chainid);
        console.log("runtime code hash (a version's manifest names an implementation's):");
        console.logBytes32(made.codehash);
    }

    function _checkBuild() internal view {
        require(keccak256(_code("StrategyRegistry")) == V1_REGISTRY_CODE, "not the pinned StrategyRegistry");
        require(keccak256(_code("VaultUpgrade")) == V1_UPGRADE_CODE, "not the pinned VaultUpgrade");
        require(keccak256(_code("HubFee")) == V1_HUB_FEE_CODE, "not the pinned HubFee");
        require(keccak256(_code("Hub")) == V1_HUB_CODE, "not the pinned Hub");
        require(keccak256(_code("AaveV3AssetLegExit")) == V1_LONG_EXIT_CODE, "not the pinned AaveV3AssetLegExit");
        require(keccak256(_code("AaveV3AssetLegRewards")) == V1_LONG_REWARDS_CODE, "not the pinned AaveV3AssetLegRewards");
        require(keccak256(_code("AaveV3AssetLeg")) == V1_LONG_CODE, "not the pinned AaveV3AssetLeg");
        require(keccak256(_code("HyperCoreLegExit")) == V1_SHORT_EXIT_CODE, "not the pinned HyperCoreLegExit");
        require(keccak256(_code("HyperCoreLegExitB")) == V1_SHORT_EXIT_B_CODE, "not the pinned HyperCoreLegExitB");
        require(keccak256(_code("HyperCoreLeg")) == V1_SHORT_CODE, "not the pinned HyperCoreLeg");
        require(keccak256(_code("StrategyFactory")) == V1_FACTORY_CODE, "not the pinned StrategyFactory");
    }

    /// The salt, init code and (for a module) pinned runtime hash of `what` under `recovery`.
    function initOf(string memory what, address recovery)
        public
        view
        returns (bytes32 salt, bytes memory init, bytes32 runtime)
    {
        bytes32 h = keccak256(bytes(what));
        if (h == keccak256("registry")) return (REGISTRY_SALT, _registryInit(recovery), bytes32(0));
        if (h == keccak256("upgrade")) return (UPGRADE_SALT, _code("VaultUpgrade"), V1_UPGRADE_RUNTIME_HASH);
        if (h == keccak256("hub-fee")) return (HUB_FEE_SALT, _code("HubFee"), V1_HUB_FEE_RUNTIME_HASH);
        if (h == keccak256("hub")) return (HUB_SALT, _hubInit(), V1_HUB_IMPL_RUNTIME_HASH);
        if (h == keccak256("long-exit")) return (LONG_EXIT_SALT, _longModuleInit("AaveV3AssetLegExit"), V1_LONG_EXIT_RUNTIME_HASH);
        if (h == keccak256("long-rewards")) {
            return (LONG_REWARDS_SALT, _longModuleInit("AaveV3AssetLegRewards"), V1_LONG_REWARDS_RUNTIME_HASH);
        }
        if (h == keccak256("long")) return (LONG_SALT, _longInit(), V1_LONG_IMPL_RUNTIME_HASH);
        if (h == keccak256("short-exit")) return (SHORT_EXIT_SALT, _code("HyperCoreLegExit"), V1_SHORT_EXIT_RUNTIME_HASH);
        if (h == keccak256("short-exit-b")) {
            return (SHORT_EXIT_B_SALT, _code("HyperCoreLegExitB"), V1_SHORT_EXIT_B_RUNTIME_HASH);
        }
        if (h == keccak256("short")) return (SHORT_SALT, _shortInit(), V1_SHORT_IMPL_RUNTIME_HASH);
        if (h == keccak256("factory")) return (FACTORY_SALT, _factoryInit(recovery), bytes32(0));
    }

    /// A contract's creation code from its own build artifact (`forge inspect <C> bytecode`), never
    /// `type(C).creationCode` (the partner's audit L1: another compile unit may emit other bytes).
    function _code(string memory name) internal view returns (bytes memory) {
        return vm.getCode(string.concat(name, ".sol:", name));
    }

    function predict(bytes32 salt, bytes memory init) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, salt, keccak256(init))))));
    }

    function _registryInit(address recovery) internal view returns (bytes memory) {
        return abi.encodePacked(
            _code("StrategyRegistry"), abi.encode(recovery, address(0), uint256(1), genesisMembers(), genesisProfiles())
        );
    }

    /// Version 1's members on every chain, by member type: the hub and the AAVE asset leg on Arbitrum
    /// (domain 3), the Hyperliquid leg on HyperEVM (19), each at its deterministic address with its pinned
    /// runtime hash. Its hash is version 1's manifest.
    function genesisMembers() public view returns (VersionMember[] memory m) {
        m = new VersionMember[](3);
        m[0] = VersionMember(MemberTypes.HUB, 3, predict(HUB_SALT, _hubInit()), V1_HUB_IMPL_RUNTIME_HASH);
        m[1] = VersionMember(MemberTypes.AAVE_V3_ASSET, 3, predict(LONG_SALT, _longInit()), V1_LONG_IMPL_RUNTIME_HASH);
        m[2] = VersionMember(MemberTypes.HYPERCORE, 19, predict(SHORT_SALT, _shortInit()), V1_SHORT_IMPL_RUNTIME_HASH);
    }

    /// The asset profiles open from the start, `profiles/<id>.json`: ETH (version 0's leg as data, Q7),
    /// then BTC (WBTC, §3.1).
    function genesisProfiles() public pure returns (AssetProfile[] memory p) {
        p = new AssetProfile[](2);
        p[0] = ethProfile();
        p[1] = btcProfile();
    }

    function ethProfile() public pure returns (AssetProfile memory p) {
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

    function btcProfile() public pure returns (AssetProfile memory p) {
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

    function _word(string memory s) internal pure returns (bytes32 w) {
        (w,) = Profiles.word(s);
    }

    function registryOf(address recovery) public view returns (address) {
        return predict(REGISTRY_SALT, _registryInit(recovery));
    }

    function _upgrade() internal view returns (address) {
        return predict(UPGRADE_SALT, _code("VaultUpgrade"));
    }

    function _hubInit() internal view returns (bytes memory) {
        return abi.encodePacked(
            _code("Hub"),
            abi.encode(
                predict(HUB_FEE_SALT, _code("HubFee")),
                V1_HUB_FEE_RUNTIME_HASH,
                _upgrade(),
                V1_UPGRADE_RUNTIME_HASH,
                Arbitrum.SEQUENCER
            )
        );
    }

    function _longModuleInit(string memory name) internal view returns (bytes memory) {
        return abi.encodePacked(_code(name), abi.encode(Arbitrum.POOL, Arbitrum.USDC, Arbitrum.RECEIVER, Arbitrum.SEQUENCER));
    }

    function _longInit() internal view returns (bytes memory) {
        return abi.encodePacked(
            _code("AaveV3AssetLeg"),
            abi.encode(
                predict(LONG_EXIT_SALT, _longModuleInit("AaveV3AssetLegExit")),
                V1_LONG_EXIT_RUNTIME_HASH,
                predict(LONG_REWARDS_SALT, _longModuleInit("AaveV3AssetLegRewards")),
                V1_LONG_REWARDS_RUNTIME_HASH,
                _upgrade(),
                V1_UPGRADE_RUNTIME_HASH,
                Arbitrum.POOL,
                Arbitrum.USDC,
                Arbitrum.RECEIVER,
                Arbitrum.SEQUENCER
            )
        );
    }

    function _shortInit() internal view returns (bytes memory) {
        return abi.encodePacked(
            _code("HyperCoreLeg"),
            abi.encode(
                predict(SHORT_EXIT_SALT, _code("HyperCoreLegExit")),
                V1_SHORT_EXIT_RUNTIME_HASH,
                predict(SHORT_EXIT_B_SALT, _code("HyperCoreLegExitB")),
                V1_SHORT_EXIT_B_RUNTIME_HASH,
                _upgrade(),
                V1_UPGRADE_RUNTIME_HASH
            )
        );
    }

    /// Version 1's topology: the hub and the AAVE asset leg on Arbitrum (domain 3), the Hyperliquid leg on
    /// HyperEVM (19); the same arguments on both chains.
    function factoryArgs(address recovery) public view returns (bytes memory) {
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
        return abi.encode(
            registryOf(recovery), ParamsTypesV1.HUB_NAME, ParamsTypesV1.HUB_FIELDS, ParamsTypesV1.HUB_COUNT, hubDomains, pins
        );
    }

    function _factoryInit(address recovery) internal view returns (bytes memory) {
        return abi.encodePacked(_code("StrategyFactory"), factoryArgs(recovery));
    }

    function factoryOf(address recovery) public view returns (address) {
        return predict(FACTORY_SALT, _factoryInit(recovery));
    }
}
