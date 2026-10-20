// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IPool, ISwapRouter02, RepayWithCollateral} from "../src/RepayWithCollateral.sol";

/*
 * Deploy one receiver for one (pool, router). The contract has no owner, so the deployer keeps no
 * power over it; the only things that matter afterwards are the two immutables.
 *
 *   POOL=0x794a61358D6845594F94dc1DB02A252b5b4814aD ROUTER=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 \
 *   forge script script/Deploy.s.sol --rpc-url arbitrum --broadcast --verify --private-key $DEPLOYER_KEY
 *
 * Pin the address in apps/api/src/modules/strategy-execution/venues/lending/aave-v3/constants.ts
 * (`REPAY_WITH_COLLATERAL`, keyed by pool) with `trustedForDerisk: false` until the pool's first funded run.
 */
contract Deploy is Script {
    function run() external returns (RepayWithCollateral deployed) {
        address pool = vm.envAddress("POOL");
        address router = vm.envAddress("ROUTER");
        vm.startBroadcast();
        deployed = new RepayWithCollateral(IPool(pool), ISwapRouter02(router));
        vm.stopBroadcast();
        console.log("RepayWithCollateral", address(deployed), "pool", pool);
        console.log("router", router);
    }
}
