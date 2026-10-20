// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockTransmitter} from "./mocks/Mocks.sol";

/// The partner's audit L1: the real deploy script, run in the test EVM through the deterministic deployer,
/// each step as the runbook runs it, lands every contract at test/Pinned.t.sol's vectors (recovery 0xdEaD).
contract DeployScriptTest is Test {
    address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    function _run(Deploy d, string memory what) internal returns (address) {
        vm.setEnv("CONTRACT", what);
        return d.run();
    }

    function test_theDeployScriptLandsEveryContractAtItsVector() public {
        vm.etch(DETERMINISTIC_DEPLOYER, DEPLOYER_RUNTIME);
        vm.etch(TRANSMITTER, type(MockTransmitter).runtimeCode);
        MockTransmitter(TRANSMITTER).setLocalDomain(19);
        vm.setEnv("RECOVERY", vm.toString(address(0xdEaD)));
        vm.setEnv("EXPECTED", vm.toString(address(0)));
        Deploy d = new Deploy();
        address registry = _run(d, "registry");
        _run(d, "hub-fee");
        address hub = _run(d, "hub");
        _run(d, "long-exit");
        address longLeg = _run(d, "long");
        _run(d, "short-exit");
        address shortLeg = _run(d, "short");
        vm.setEnv("HUB_CODE_HASH", vm.toString(hub.codehash));
        vm.setEnv("LONG_CODE_HASH", vm.toString(longLeg.codehash));
        vm.setEnv("SHORT_CODE_HASH", vm.toString(shortLeg.codehash));
        address combination = _run(d, "combination");
        assertEq(registry, 0x057a270B71e1189BF8e877FD9CFA6f399b8608CD, "registry vector");
        assertEq(hub, 0x572A510cd396aE6D345b5085c1dfB5B4450071da, "hub code vector");
        assertEq(longLeg, 0x576848daE996EA4fFFce9462F028aAab27C08C3D, "long leg code vector");
        assertEq(shortLeg, 0x563B6bE2D1b33Df538985e7bE04b6e78C7982eDa, "short leg code vector");
        assertEq(combination, 0x424aE02E590Cc4CE4CbC47f623E81C1a92Ee2bb8, "combination vector");
    }
}
