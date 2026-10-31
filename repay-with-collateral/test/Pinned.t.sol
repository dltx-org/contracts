// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {RepayWithCollateral} from "../src/RepayWithCollateral.sol";

/*
 * THE PINNED BUILD. The receiver lands through the deterministic deployer, so its address follows its
 * creation code: any change to its source or the compiler profile moves `CODE` and the address below,
 * and `script/Deploy.s.sol` refuses a build that is not this one. Update both, and every pin of the
 * address (the script's header lists them), before it is deployed.
 */
contract PinnedTest is Test {
    address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address constant AAVE_ARBITRUM = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /// keccak256(type(RepayWithCollateral).creationCode).
    bytes32 constant CODE = 0x5abeebbd5cdf08aed240cb5b4de9c8cf4ad93b3ece66e3bf6d428eff541bbf33;
    /// Where the receiver lands on Arbitrum for (AAVE V3's pool, SwapRouter02).
    address constant ARBITRUM = 0x741060C5F81b5226eB74355da4FDe6467651673b;

    function test_buildIsPinned() public {
        Deploy script = new Deploy();
        assertEq(keccak256(type(RepayWithCollateral).creationCode), CODE, "RepayWithCollateral's build moved");
        assertEq(script.CODE(), CODE, "script/Deploy.s.sol pins another build");
        assertEq(script.SALT(), keccak256("dltx.repay-with-collateral"));
        assertEq(script.predict(script.initOf(AAVE_ARBITRUM, SWAP_ROUTER_02)), ARBITRUM, "the Arbitrum address");
    }

    /// The script's prediction is where the deterministic deployer really puts it, with its two pins.
    function test_landsWherePredicted() public {
        vm.etch(DETERMINISTIC_DEPLOYER, DEPLOYER_RUNTIME);
        Deploy script = new Deploy();
        bytes memory init = script.initOf(AAVE_ARBITRUM, SWAP_ROUTER_02);
        (bool ok, bytes memory ret) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(script.SALT(), init));
        require(ok && ret.length == 20, "deterministic deployment failed");
        address made = address(bytes20(ret));
        assertEq(made, ARBITRUM);
        assertEq(address(RepayWithCollateral(made).POOL()), AAVE_ARBITRUM);
        assertEq(address(RepayWithCollateral(made).ROUTER()), SWAP_ROUTER_02);
    }

    /// On an Arbitrum fork: the canonical deployer exists there, and the receiver is not deployed yet.
    function test_arbitrumHasTheDeployer() public {
        vm.createSelectFork(vm.rpcUrl("arbitrum"));
        assertEq(DETERMINISTIC_DEPLOYER.codehash, keccak256(DEPLOYER_RUNTIME), "no canonical deployer on Arbitrum");
        assertEq(ARBITRUM.code.length, 0, "the receiver is not deployed yet");
    }
}
