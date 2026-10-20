// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {Legs, ParamsTypes} from "../src/lib/VaultTypes.sol";
import {FeePins} from "../src/lib/FeePins.sol";

/*
 * Deploy ONE contract of the strategy vaults (step 11e2 amendment 2a §8.1) through the deterministic
 * deployer, so each lands at the same address on every chain it is deployed to. Run from `master`, the
 * pinned build (test/Pinned.t.sol), one CONTRACT per run, in this order:
 *
 *   1. registry      Arbitrum, HyperEVM           RECOVERY
 *   1b. hub-fee      Arbitrum (every hub chain)   —
 *   1c. hub          Arbitrum (every hub chain)   — (its module: the hub-fee's address, computed)
 *   2. long-exit     Arbitrum                     —
 *   3. long          Arbitrum                     — (its module: the long-exit's address, computed)
 *   4. short-exit    HyperEVM (big block)         —
 *   5. short         HyperEVM (big block)         — (its module: the short-exit's address, computed)
 *   6. combination   Arbitrum, HyperEVM           RECOVERY, HUB_CODE_HASH, LONG_CODE_HASH, SHORT_CODE_HASH
 *
 *   CONTRACT=<name> RECOVERY=0x… EXPECTED=0x… [HUB_CODE_HASH=0x… LONG_CODE_HASH=0x… SHORT_CODE_HASH=0x…] \
 *   forge script script/Deploy.s.sol --rpc-url <chain> --broadcast --verify --private-key $DEPLOYER_KEY
 *
 * Every address is computed here from the pinned build and the deployer; EXPECTED is the address the
 * first chain printed (or test/Pinned.t.sol's vector for RECOVERY 0xdEaD): the script refuses a build,
 * a key or a deployer that would put a contract elsewhere. The leg codes' hashes carry their modules'
 * addresses (immutables), and so does the hub's (its fee module, amendment 2b), so the combination takes
 * them as inputs, printed by steps 1c, 3 and 5, and checks those whose code is on this chain. It also
 * pins the fee's price sources and sequencer feed (`src/lib/FeePins.sol`). The sender keeps no power and may be any funded key.
 *
 * On HyperEVM the leg code, its module and (since amendment 2d's typed `CreateVault`, 3.76M gas) the
 * combination need the deployer's BIG blocks (a small block holds 3M gas; `evmUserModify {usingBigBlocks:
 * true}` signed by the deployer on HyperCore first); the registry fits a small block. Afterwards nothing obeys anybody until RECOVERY calls
 * `registry.setExecutionKey(group, key)` on each chain; a group's clock starts at its first key.
 */
contract Deploy is Script {
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant DEPLOYER_CODEHASH = keccak256(
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
    );
    uint32 constant ARBITRUM = 3;
    uint32 constant HYPEREVM = 19;

    bytes32 constant REGISTRY_SALT = keccak256("dltx.vault-registry.v1");
    bytes32 constant LONG_EXIT_SALT = keccak256("dltx.vault-long-exit.v1");
    bytes32 constant LONG_LEG_SALT = keccak256("dltx.vault-long-leg.v1");
    bytes32 constant SHORT_EXIT_SALT = keccak256("dltx.vault-short-exit.v1");
    bytes32 constant SHORT_LEG_SALT = keccak256("dltx.vault-short-leg.v1");
    bytes32 constant COMBINATION_SALT = keccak256("dltx.vault-combination.v1");
    bytes32 constant HUB_SALT = keccak256("dltx.vault-hub.v1");
    bytes32 constant HUB_FEE_SALT = keccak256("dltx.vault-hub-fee.v1");

    // The pinned build: test/Pinned.t.sol's creation-code hashes.
    bytes32 constant REGISTRY_CODE = 0xd9d8d635144040392821ad5807a45484403fe7fa12a70bb9556e9c6aecc0a200;
    bytes32 constant LONG_EXIT_CODE = 0xa5554ffbcbfe26275afa41f148189ca2a347cccb48c9b50bacdd1d08aea5f688;
    bytes32 constant LONG_LEG_CODE = 0xf9c31cb3659be0714a61bd486c86e39978f0c22824620fb3973e821cd4eaba6a;
    bytes32 constant SHORT_EXIT_CODE = 0xb963a515c9467004bd9f58a163e8236a090dd6e5e477758f4d8a1c14892e68f5;
    bytes32 constant SHORT_LEG_CODE = 0xed2cbb37949a5c1c2aa393247d96ae8722c90d3ba1ce5e61f86a7baae1a3c68d;
    bytes32 constant HUB_FEE_CODE = 0xead386251b7465f201678da4f35c44f0fef48c29950b5ec3d01a495d1b8e9fa0;
    bytes32 constant HUB_CODE = 0xa994298b09c27e43fe2bc8043aed521d933d851dfa4923047b4af574aafa260c;
    bytes32 constant COMBINATION_CODE = 0xb321a35ade28a925ea2a7167415260edb76aef1e4a0457a700ccdfb580ed692d;
    // The modules' runtime code hashes, what a leg code (and the hub code) pins: test/Pinned.t.sol's, from
    // the deployed module. Not `type(...).runtimeCode`, which solc 0.8.37 (via-IR) may emit differently in
    // another compile unit than the runtime the creation code deploys (the combined review's re-pin; the
    // partner's audit L1): a leg code naming the wrong hash reverts, and a combination predicting it on a
    // chain without the module would pin the wrong leg address.
    bytes32 constant LONG_EXIT_RUNTIME_HASH = 0x8becfdd9c8ca1285013e279985e557e88e7ff9fe58fe50ace32d24332675fe70;
    bytes32 constant SHORT_EXIT_RUNTIME_HASH = 0x2eb092b6c751c42fd55a1f6cb48b4c27f6c83448e57ea7cfd3ded58d7cdf67ca;
    bytes32 constant HUB_FEE_RUNTIME_HASH = 0xe8aea602bd0c995180388a99447b0f2f39ae93fb9b36c4567861cb793c82c54a;

    function run() external returns (address made) {
        require(keccak256(_code("VaultRegistry")) == REGISTRY_CODE, "not the pinned VaultRegistry");
        require(keccak256(_code("LongVaultExit")) == LONG_EXIT_CODE, "not the pinned LongVaultExit");
        require(keccak256(_code("LongVault")) == LONG_LEG_CODE, "not the pinned LongVault");
        require(keccak256(_code("ShortVaultExit")) == SHORT_EXIT_CODE, "not the pinned ShortVaultExit");
        require(keccak256(_code("ShortVault")) == SHORT_LEG_CODE, "not the pinned ShortVault");
        require(keccak256(_code("CombinationFactory")) == COMBINATION_CODE, "not the pinned CombinationFactory");
        require(keccak256(_code("StrategyHub")) == HUB_CODE, "not the pinned StrategyHub");
        require(keccak256(_code("StrategyHubFee")) == HUB_FEE_CODE, "not the pinned StrategyHubFee");
        require(DEPLOYER.codehash == DEPLOYER_CODEHASH, "no canonical deterministic deployer on this chain");

        string memory what = vm.envString("CONTRACT");
        bytes32 h = keccak256(bytes(what));
        (bytes32 salt, bytes memory init) = h == keccak256("registry")
            ? (REGISTRY_SALT, _registryInit())
            : h == keccak256("long-exit")
                ? (LONG_EXIT_SALT, _code("LongVaultExit"))
                : h == keccak256("long")
                    ? (LONG_LEG_SALT, _legInit(_code("LongVault"), LONG_EXIT_SALT, _code("LongVaultExit"), LONG_EXIT_RUNTIME_HASH))
                    : h == keccak256("short-exit")
                        ? (SHORT_EXIT_SALT, _code("ShortVaultExit"))
                        : h == keccak256("short")
                            ? (SHORT_LEG_SALT, _legInit(_code("ShortVault"), SHORT_EXIT_SALT, _code("ShortVaultExit"), SHORT_EXIT_RUNTIME_HASH))
                            : h == keccak256("combination")
                                ? (COMBINATION_SALT, _combinationInit())
                                : h == keccak256("hub-fee")
                                    ? (HUB_FEE_SALT, _code("StrategyHubFee"))
                                    : h == keccak256("hub") ? (HUB_SALT, _hubInit()) : (bytes32(0), bytes(""));
        require(init.length > 0, "CONTRACT: registry | hub-fee | hub | long-exit | long | short-exit | short | combination");

        address predicted = _predict(salt, init);
        address expected = vm.envOr("EXPECTED", address(0));
        if (expected == address(0)) {
            console.log("FIRST DEPLOYMENT of", what, ": every later chain must expect", predicted);
        } else {
            require(predicted == expected, "this build and these inputs would not land at EXPECTED");
        }
        require(predicted.code.length == 0, "already deployed here");
        // a module deployed here must be the pinned runtime its leg names
        bytes32 runtime = h == keccak256("long-exit")
            ? LONG_EXIT_RUNTIME_HASH
            : h == keccak256("short-exit") ? SHORT_EXIT_RUNTIME_HASH : h == keccak256("hub-fee") ? HUB_FEE_RUNTIME_HASH : bytes32(0);
        vm.startBroadcast();
        (bool ok, bytes memory ret) = DEPLOYER.call(abi.encodePacked(salt, init));
        vm.stopBroadcast();
        require(ok && ret.length == 20 && address(bytes20(ret)) == predicted, "deployment failed");
        require(runtime == bytes32(0) || predicted.codehash == runtime, "the module's runtime is not the pinned one");
        made = predicted;
        console.log(what, made, "chain", block.chainid);
        console.log("runtime code hash (the combination's pin, for a leg code):");
        console.logBytes32(made.codehash);
    }

    /// A contract's creation code from its own build artifact (`forge inspect <C> bytecode`, what the pins and
    /// the seam's fixtures are), never `type(C).creationCode`: solc 0.8.37 (via-IR) compiles a contract named
    /// by `type(...)` inside this script's unit, and it emitted ShortVaultExit differently there (the
    /// partner's audit L1, measured 2026-10-20: the script refused its own pinned build).
    function _code(string memory name) internal view returns (bytes memory) {
        return vm.getCode(string.concat(name, ".sol:", name));
    }

    function _predict(bytes32 salt, bytes memory init) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, salt, keccak256(init))))));
    }

    function _registryInit() internal view returns (bytes memory) {
        return abi.encodePacked(_code("VaultRegistry"), abi.encode(vm.envAddress("RECOVERY")));
    }

    /// A leg code names its module: the module's address (computed) and code hash (its pinned runtime's: a
    /// module carries no immutable).
    function _legInit(bytes memory legCreation, bytes32 exitSalt, bytes memory exitCreation, bytes32 exitRuntimeHash)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(legCreation, abi.encode(_predict(exitSalt, exitCreation), exitRuntimeHash));
    }

    /// The hub code names its fee module the same way (amendment 2b).
    function _hubInit() internal view returns (bytes memory) {
        return _legInit(_code("StrategyHub"), HUB_FEE_SALT, _code("StrategyHubFee"), HUB_FEE_RUNTIME_HASH);
    }

    /// Today's combination: the hub and the AAVE leg on Arbitrum, the Hyperliquid leg on HyperEVM.
    function _combinationInit() internal returns (bytes memory) {
        address registry = _predict(REGISTRY_SALT, _registryInit());
        address hub = _predict(HUB_SALT, _hubInit());
        address longExit = _predict(LONG_EXIT_SALT, _code("LongVaultExit"));
        address shortExit = _predict(SHORT_EXIT_SALT, _code("ShortVaultExit"));
        address longCode = _predict(
            LONG_LEG_SALT,
            abi.encodePacked(_code("LongVault"), abi.encode(longExit, LONG_EXIT_RUNTIME_HASH))
        );
        address shortCode = _predict(
            SHORT_LEG_SALT,
            abi.encodePacked(_code("ShortVault"), abi.encode(shortExit, SHORT_EXIT_RUNTIME_HASH))
        );
        bytes32 hubHash = vm.envBytes32("HUB_CODE_HASH");
        bytes32 longHash = vm.envBytes32("LONG_CODE_HASH");
        bytes32 shortHash = vm.envBytes32("SHORT_CODE_HASH");
        require(registry.code.length > 0, "the registry first");
        if (block.chainid == 42161) {
            require(hub.codehash == hubHash, "HUB_CODE_HASH is not Arbitrum's hub code");
            require(longCode.codehash == longHash, "LONG_CODE_HASH is not Arbitrum's leg code");
        }
        if (block.chainid == 999) require(shortCode.codehash == shortHash, "SHORT_CODE_HASH is not HyperEVM's leg code");
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = ARBITRUM;
        CombinationFactory.LegPin[] memory pins = new CombinationFactory.LegPin[](2);
        pins[0] = CombinationFactory.LegPin(longCode, longHash, ARBITRUM, Legs.LONG, Legs.VALUE_READ, ParamsTypes.AAVE_V3_NAME, ParamsTypes.AAVE_V3_FIELDS, ParamsTypes.AAVE_V3_COUNT);
        pins[1] = CombinationFactory.LegPin(shortCode, shortHash, HYPEREVM, Legs.SHORT, Legs.VALUE_READ, ParamsTypes.HYPERCORE_NAME, ParamsTypes.HYPERCORE_FIELDS, ParamsTypes.HYPERCORE_COUNT);
        return abi.encodePacked(
            _code("CombinationFactory"),
            abi.encode(registry, hub, hubHash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, hubDomains, pins, FeePins.prices(), FeePins.sequencers())
        );
    }
}
