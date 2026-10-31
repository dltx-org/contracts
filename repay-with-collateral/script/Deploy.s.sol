// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IPool, ISwapRouter02, RepayWithCollateral} from "../src/RepayWithCollateral.sol";

/*
 * Deploy the receiver (`RepayWithCollateral`) for one (pool, router),
 * through the canonical deterministic deployer (0x4e59…956C), as the strategy contracts are: its address is
 * CREATE2(deployer, SALT, keccak256(creation code ‖ abi.encode(pool, router))), so it is known before it
 * exists and the version-1 legs and the engine can pin it first. The contract has no owner, so the sender
 * keeps no power over it. The script refuses a build that is not the pinned one (`CODE`, the hash of
 * the creation code without its arguments: test/Pinned.t.sol holds the same constant and the expected
 * Arbitrum address), a chain without the canonical deployer, and an address that already has code.
 *
 *   POOL=0x794a61358D6845594F94dc1DB02A252b5b4814aD ROUTER=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 \
 *   forge script script/Deploy.s.sol --rpc-url arbitrum --broadcast --verify --private-key $DEPLOYER_KEY
 *
 * `PRINT_CALLDATA=1` checks everything, prints the deployer's calldata and the address, and broadcasts
 * nothing (send it with `cast send` instead). Verify with the constructor arguments `abi.encode(pool, router)`.
 *
 * Then pin the address: contracts/strategy-vault-v1/src/lib/Pinned.sol (`Arbitrum.RECEIVER`, a
 * constructor argument of the AAVE leg and its modules: the v1 repin cascade), and the engine's receiver
 * constants (`engine/evm/src/vault.ts`, `engine/owner/src/vault-pair.ts`, …), before version 1 deploys.
 */
contract Deploy is Script {
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant DEPLOYER_CODEHASH = keccak256(
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
    );
    bytes32 public constant SALT = keccak256("dltx.repay-with-collateral");
    /// keccak256(type(RepayWithCollateral).creationCode): any change to the source or the profile moves it.
    bytes32 public constant CODE = 0x5abeebbd5cdf08aed240cb5b4de9c8cf4ad93b3ece66e3bf6d428eff541bbf33;

    function run() external returns (address made) {
        address pool = vm.envAddress("POOL");
        address router = vm.envAddress("ROUTER");
        require(keccak256(type(RepayWithCollateral).creationCode) == CODE, "not the pinned RepayWithCollateral");
        require(DEPLOYER.codehash == DEPLOYER_CODEHASH, "no canonical deterministic deployer on this chain");
        require(pool.code.length > 0 && router.code.length > 0, "POOL and ROUTER must be contracts on this chain");
        bytes memory init = initOf(pool, router);
        address predicted = predict(init);
        require(predicted.code.length == 0, "already deployed here");
        if (vm.envOr("PRINT_CALLDATA", false)) {
            console.log("send to the deterministic deployer", DEPLOYER, "this calldata; it lands at", predicted);
            console.logBytes(abi.encodePacked(SALT, init));
            return predicted;
        }
        vm.startBroadcast();
        (bool ok, bytes memory ret) = DEPLOYER.call(abi.encodePacked(SALT, init));
        vm.stopBroadcast();
        require(ok && ret.length == 20 && address(bytes20(ret)) == predicted, "deployment failed");
        made = predicted;
        require(address(RepayWithCollateral(made).POOL()) == pool, "POOL");
        require(address(RepayWithCollateral(made).ROUTER()) == router, "ROUTER");
        console.log("RepayWithCollateral", made, "pool", pool);
        console.log("router", router);
    }

    function initOf(address pool, address router) public pure returns (bytes memory) {
        return abi.encodePacked(type(RepayWithCollateral).creationCode, abi.encode(IPool(pool), ISwapRouter02(router)));
    }

    function predict(bytes memory init) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, SALT, keccak256(init))))));
    }
}
