// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {DepositAccount} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/*
 * Deploy the deposit factory on one chain, through the deterministic deployer, so it lands at the
 * same address on every chain (step 11e2 §8.1). Run it from `master`, the pinned build, on each chain:
 *
 *   EXPECTED_FACTORY=0x… \
 *   forge script script/Deploy.s.sol --rpc-url arbitrum --broadcast --verify --private-key $DEPLOYER_KEY
 *
 * RECOVERY (the constant below) is the operator's offline hardware key: the factory's only constructor
 * argument (amendment 1: no vault factory is named), and so part of its address — the SAME key on every
 * chain. It is a PLACEHOLDER (version 0's hot key) until the hardware wallet's address replaces it, with
 * the vault's in one step: `node scripts/repin-v1.mjs --recovery <address>` (deploy-factories.md §5c).
 * EXPECTED_FACTORY is the address the first deployment printed (and the chain files pin): the script
 * refuses a build, a key or a deployer that would put the factory anywhere else. The sender keeps no
 * power and may be any funded key.
 *
 * The factory's constructor creates version 1 of the deposit contract, the GENESIS (its record module,
 * then `DepositAccount`), which every account is deployed on (owner-upgrades-design.md §3.2, Q0): no
 * listing is needed for it. A later version is deployed separately (the deterministic deployer, the
 * factory's address its constructor argument, so the same address on every chain) and listed by
 * recovery's `proposeImplementation`, 7 public days, then `acceptImplementation`, on every deposit
 * chain, Arbitrum's last (§3.6 rule 6).
 *
 * On HyperEVM the deployment (≈ 9.9M gas, measured on the fork) does not fit a small block (2–3M): the
 * sender must be switched to big blocks first (Hyperliquid's `evmUserModify {usingBigBlocks: true}`).
 *
 * Afterwards the factory obeys nobody until RECOVERY calls `setTransferKey(<the KMS key>)` and
 * `setFeeRecipient(<the platform's fee address>)` on that chain, and the transfer key checks in.
 * Until the first check-in the escape hatch counts from this deployment (README).
 */
contract Deploy is Script {
    /// The factory's only constructor argument, the vault registry's too. PLACEHOLDER: version 0's hot key until the hardware wallet's address (`scripts/repin-v1.mjs --recovery`).
    address public constant RECOVERY = 0x549178f84C788801A4528977a740A9672D2A07D7;
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant DEPLOYER_CODEHASH = keccak256(
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
    );
    bytes32 constant FACTORY_SALT = keccak256("dltx.deposit-factory");
    /// The pinned build (test/DepositFactory.t.sol `PINNED_CREATION_CODE_HASH`).
    bytes32 constant PINNED_CREATION_CODE_HASH = 0x798060600150566aab91bf10516dc49b93b5b3c82979c0653d0cf52f6b12b807;

    function run() external returns (DepositFactory factory) {
        address recovery = RECOVERY;
        address expected = vm.envOr("EXPECTED_FACTORY", address(0));
        require(keccak256(type(DepositFactory).creationCode) == PINNED_CREATION_CODE_HASH, "not the pinned build");
        require(DEPLOYER.codehash == DEPLOYER_CODEHASH, "no canonical deterministic deployer on this chain");
        bytes memory init = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(recovery));
        address predicted = factoryOf(recovery);
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
        console.log("genesis (version 1)", factory.genesis());
        console.log("its record module", DepositAccount(factory.genesis()).module());
        console.log("recovery", factory.recovery(), "- now call setTransferKey and setFeeRecipient from it");
    }

    /// The factory's address for `recovery`, on every chain.
    function factoryOf(address recovery) public pure returns (address) {
        bytes memory init = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(recovery));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, FACTORY_SALT, keccak256(init))))));
    }
}
