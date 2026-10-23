// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {DeployV1} from "../script/DeployV1.s.sol";
import {Manifests} from "../src/Types.sol";
import {OwnerDigestsV1Test} from "./OwnerDigestsV1.t.sol";

/*
 * VERSION 1'S PINS AS THIS BUILD COMPUTES THEM, one `PIN <name> <value>` line each, for
 * `scripts/repin-v1.mjs` (the re-pin cascade: deploy-factories.md §5c). Skipped unless PRINT_PINS=1
 * and ARBITRUM_RPC_URL are set: it deploys on an Arbitrum fork (the AAVE modules, the hub and the long
 * read Arbitrum's contracts in their constructors), the short there too (it reads nothing of its chain).
 *
 *   PRINT_PINS=1 forge test --match-contract PinsV1 -vv
 *
 * The implementations' init codes carry the modules' pinned runtime hashes, and the registry's the
 * implementations': a stale pin reads as `PIN <name> stale`, and the tool runs this again once the
 * earlier pins are written, until nothing moves.
 */
contract PinsV1 is Test {
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    DeployV1 d;

    function test_printPins() external {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (!vm.envOr("PRINT_PINS", false) || bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, 517_200_797);
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        d = new DeployV1();
        address recovery = d.RECOVERY();
        _code("V1_REGISTRY_CODE", "StrategyRegistry");
        _code("V1_UPGRADE_CODE", "VaultUpgrade");
        _code("V1_HUB_FEE_CODE", "HubFee");
        _code("V1_HUB_CODE", "Hub");
        _code("V1_LONG_EXIT_CODE", "AaveV3AssetLegExit");
        _code("V1_LONG_REWARDS_CODE", "AaveV3AssetLegRewards");
        _code("V1_LONG_CODE", "AaveV3AssetLeg");
        _code("V1_SHORT_EXIT_CODE", "HyperCoreLegExit");
        _code("V1_SHORT_EXIT_B_CODE", "HyperCoreLegExitB");
        _code("V1_SHORT_CODE", "HyperCoreLeg");
        _code("V1_FACTORY_CODE", "StrategyFactory");
        _runtime("V1_UPGRADE_RUNTIME_HASH", "upgrade");
        _runtime("V1_HUB_FEE_RUNTIME_HASH", "hub-fee");
        _runtime("V1_LONG_EXIT_RUNTIME_HASH", "long-exit");
        _runtime("V1_LONG_REWARDS_RUNTIME_HASH", "long-rewards");
        _runtime("V1_SHORT_EXIT_RUNTIME_HASH", "short-exit");
        _runtime("V1_SHORT_EXIT_B_RUNTIME_HASH", "short-exit-b");
        _runtime("V1_HUB_IMPL_RUNTIME_HASH", "hub");
        _runtime("V1_LONG_IMPL_RUNTIME_HASH", "long");
        _runtime("V1_SHORT_IMPL_RUNTIME_HASH", "short");
        _address("V1_HUB_IMPL", _at("hub", recovery));
        _address("V1_LONG_IMPL", _at("long", recovery));
        _address("V1_SHORT_IMPL", _at("short", recovery));
        _bytes32("V1_MANIFEST", Manifests.hash(d.genesisMembers()));
        _address("V1_RECOVERY", recovery);
        _address("V1_REGISTRY", d.registryOf(recovery));
        _address("V1_FACTORY", d.factoryOf(recovery));
        // the owner's vectors, by OwnerDigestsV1Test's own code (it deploys the factory itself)
        OwnerDigestsV1Test t = new OwnerDigestsV1Test();
        t.setUp();
        (address f, bytes32 configHash, address[] memory members, bytes32 c, bytes32 u, bytes32 s, bytes32 x, bytes32 cm) =
            t.computed();
        _address("OWNER_FACTORY", f);
        _bytes32("CONFIG_HASH", configHash);
        _address("MEMBER_HUB", members[0]);
        _address("MEMBER_LONG", members[1]);
        _address("MEMBER_SHORT", members[2]);
        _bytes32("CREATE_DIGEST", c);
        _bytes32("UPGRADE_DIGEST", u);
        _bytes32("SWITCH_DIGEST", s);
        _bytes32("CANCEL_DIGEST", x);
        _bytes32("CREATE_DIGEST_MGMT", cm);
    }

    function _code(string memory name, string memory c) internal view {
        _bytes32(name, keccak256(vm.getCode(string.concat(c, ".sol:", c))));
    }

    function _at(string memory what, address recovery) internal view returns (address) {
        (bytes32 salt, bytes memory init,) = d.initOf(what, recovery);
        return d.predict(salt, init);
    }

    /// Deploys `what` through the deterministic deployer on the fork (once) and prints its runtime hash.
    function _runtime(string memory name, string memory what) internal {
        (bytes32 salt, bytes memory init,) = d.initOf(what, d.RECOVERY());
        address at = d.predict(salt, init);
        if (at.code.length == 0) {
            (bool ok,) = DEPLOYER.call(abi.encodePacked(salt, init));
            if (!ok || at.code.length == 0) {
                console.log(string.concat("PIN ", name, " stale"));
                return;
            }
        }
        _bytes32(name, at.codehash);
    }

    function _bytes32(string memory name, bytes32 v) internal pure {
        console.log(string.concat("PIN ", name, " ", vm.toString(v)));
    }

    function _address(string memory name, address v) internal pure {
        console.log(string.concat("PIN ", name, " ", vm.toString(v)));
    }
}
