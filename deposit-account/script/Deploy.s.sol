// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/*
 * Deploy the deposit factory on one chain, through the deterministic deployer, so it lands at the
 * same address on every chain (step 11e2 §8.1). Run it from `master`, the pinned build, on each chain:
 *
 *   RECOVERY=0x… EXPECTED_FACTORY=0x… \
 *   forge script script/Deploy.s.sol --rpc-url arbitrum --broadcast --verify --private-key $DEPLOYER_KEY
 *
 * RECOVERY is the operator's offline hardware key: the factory's only constructor argument (amendment
 * 1: no vault factory is named), and so part of its address — the SAME key on every chain.
 * EXPECTED_FACTORY is the address the first deployment printed (and the chain files pin): the script
 * refuses a build, a key or a deployer that would put the factory anywhere else. The sender keeps no
 * power and may be any funded key.
 *
 * On HyperEVM the deployment (≈ 5.8M gas) does not fit a small block (2–3M): the sender must be
 * switched to big blocks first (Hyperliquid's `evmUserModify {usingBigBlocks: true}`).
 *
 * Afterwards the factory obeys nobody until RECOVERY calls `setTransferKey(<the KMS key>)` and
 * `setFeeRecipient(<the platform's fee address>)` on that chain, and the transfer key checks in.
 * Until the first check-in the escape hatch counts from this deployment (README).
 */
contract Deploy is Script {
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant DEPLOYER_CODEHASH = keccak256(
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
    );
    bytes32 constant FACTORY_SALT = keccak256("dltx.deposit-factory");
    /// The pinned build (test/DepositFactory.t.sol `PINNED_CREATION_CODE_HASH`).
    bytes32 constant PINNED_CREATION_CODE_HASH = 0x5abc274f66b2dcae92b61e7fdb0aa38b8f6b72b36e1f0f7c0845d3ca2495b955;

    function run() external returns (DepositFactory factory) {
        address recovery = vm.envAddress("RECOVERY");
        address expected = vm.envOr("EXPECTED_FACTORY", address(0));
        require(keccak256(type(DepositFactory).creationCode) == PINNED_CREATION_CODE_HASH, "not the pinned build");
        require(DEPLOYER.codehash == DEPLOYER_CODEHASH, "no canonical deterministic deployer on this chain");
        bytes memory init = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(recovery));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, FACTORY_SALT, keccak256(init))))));
        if (expected == address(0)) {
            console.log("FIRST DEPLOYMENT: no EXPECTED_FACTORY given; every later chain must expect", predicted);
        } else {
            require(predicted == expected, "this build and key would not land at EXPECTED_FACTORY");
        }
        require(predicted.code.length == 0, "the factory is already deployed here");
        vm.startBroadcast();
        (bool ok, bytes memory ret) = DEPLOYER.call(abi.encodePacked(FACTORY_SALT, init));
        vm.stopBroadcast();
        require(ok && ret.length == 20 && address(bytes20(ret)) == predicted, "deployment failed");
        factory = DepositFactory(predicted);
        console.log("DepositFactory", address(factory), "chain", block.chainid);
        console.log("implementation", factory.implementation());
        console.log("recovery", factory.recovery(), "- now call setTransferKey and setFeeRecipient from it");
    }
}
