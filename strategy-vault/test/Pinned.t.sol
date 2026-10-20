// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {LongVault} from "../src/LongVault.sol";
import {LongVaultExit} from "../src/LongVaultExit.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {StrategyHubFee} from "../src/StrategyHubFee.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {
    Assets, HubParams, LegConfig, Legs, LongParams, ShortParams, StrategyConfig, VaultConfig,
    ParamsTypes
} from "../src/lib/VaultTypes.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {FeePins} from "../src/lib/FeePins.sol";
import {MockTransmitter} from "./mocks/Mocks.sol";

/*
 * THE PINNED BUILD (amendment 2a §8). Every contract here lands through the deterministic deployer, so
 * its address on every chain is the hash of its creation code with its arguments: any change to the
 * source or the compiler profile moves the hashes below, and the deploy script refuses a build that
 * isn't this one. Update them (and `script/Deploy.s.sol`, the runbook, every address derived) before
 * anything is deployed — never after.
 *
 * The order is the deployment's: the registry (recovery), the hub's fee module and the hub code (naming
 * its module, amendment 2b), the two exit modules, the two leg codes (each naming its module and its code
 * hash), the combination factory (the registry, the hub code, its hash and chains, the two leg pins, the
 * fee's price and sequencer pins, `src/lib/FeePins.sol`). The vectors are for TypeScript (`engine/owner`,
 * `engine/evm`): a recovery key of 0xdEaD, and a fixed configuration whose hash and member addresses the
 * encoders must reproduce.
 */
contract PinnedTest is Test {
    address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant RECOVERY_V = 0x000000000000000000000000000000000000dEaD;

    bytes32 constant REGISTRY_SALT = keccak256("dltx.vault-registry.v1");
    bytes32 constant LONG_EXIT_SALT = keccak256("dltx.vault-long-exit.v1");
    bytes32 constant LONG_LEG_SALT = keccak256("dltx.vault-long-leg.v1");
    bytes32 constant SHORT_EXIT_SALT = keccak256("dltx.vault-short-exit.v1");
    bytes32 constant SHORT_LEG_SALT = keccak256("dltx.vault-short-leg.v1");
    bytes32 constant COMBINATION_SALT = keccak256("dltx.vault-combination.v1");
    bytes32 constant HUB_SALT = keccak256("dltx.vault-hub.v1");
    bytes32 constant HUB_FEE_SALT = keccak256("dltx.vault-hub-fee.v1");

    // creation-code hashes (no arguments)
    bytes32 constant REGISTRY_CODE = 0xd9d8d635144040392821ad5807a45484403fe7fa12a70bb9556e9c6aecc0a200;
    bytes32 constant LONG_EXIT_CODE = 0xa5554ffbcbfe26275afa41f148189ca2a347cccb48c9b50bacdd1d08aea5f688;
    bytes32 constant LONG_LEG_CODE = 0xf9c31cb3659be0714a61bd486c86e39978f0c22824620fb3973e821cd4eaba6a;
    bytes32 constant SHORT_EXIT_CODE = 0x96546cbafe94aff55bbbe39837d25e7b0fafe63a0a96fe7bd3541a05002dc91c;
    bytes32 constant SHORT_LEG_CODE = 0xc5daf55cc017f960321ad9450e73c9474cb69aee6857ee6ef0e1fb6bb4cae46b;
    bytes32 constant COMBINATION_CODE = 0x24a4f84b2ca4cdcd0d6a4194c71b454ef9ebca6d621bc792045eda551307b184;
    bytes32 constant HUB_FEE_CODE = 0x8046886f60273b10ef6973bca5dd4b671ce86112f512c92acd0daab0057eb60c;
    bytes32 constant HUB_CODE = 0x0f0b5ec17b617a5dd0e75cc45ebecf401241bc4ea9b02088e5a9e831786a4f7a;

    function _predict(bytes32 salt, bytes memory init) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DETERMINISTIC_DEPLOYER, salt, keccak256(init)))))
        );
    }

    function _deploy(bytes32 salt, bytes memory init) internal returns (address made) {
        bytes memory data = abi.encodePacked(salt, init);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = DETERMINISTIC_DEPLOYER.call(data);
        g -= gasleft();
        require(ok && ret.length == 20, "deterministic deployment failed");
        made = address(bytes20(ret));
        assertEq(made, _predict(salt, init));
        // the transaction's gas, about: 21,000 + calldata (16 a non-zero byte, 4 a zero) + execution
        uint256 calldataGas;
        for (uint256 i; i < data.length; ++i) calldataGas += data[i] == 0 ? 4 : 16;
        emit log_named_uint("  deployment gas (approx.)", 21_000 + calldataGas + g);
    }

    function test_creationCodesArePinned() public {
        emit log_named_bytes32("VaultRegistry", keccak256(type(VaultRegistry).creationCode));
        emit log_named_bytes32("LongVaultExit", keccak256(type(LongVaultExit).creationCode));
        emit log_named_bytes32("LongVault", keccak256(type(LongVault).creationCode));
        emit log_named_bytes32("ShortVaultExit", keccak256(type(ShortVaultExit).creationCode));
        emit log_named_bytes32("ShortVault", keccak256(type(ShortVault).creationCode));
        emit log_named_bytes32("CombinationFactory", keccak256(type(CombinationFactory).creationCode));
        emit log_named_bytes32("StrategyHub", keccak256(type(StrategyHub).creationCode));
        emit log_named_bytes32("StrategyHubFee", keccak256(type(StrategyHubFee).creationCode));
        assertEq(keccak256(type(VaultRegistry).creationCode), REGISTRY_CODE, "VaultRegistry");
        assertEq(keccak256(type(LongVaultExit).creationCode), LONG_EXIT_CODE, "LongVaultExit");
        assertEq(keccak256(type(LongVault).creationCode), LONG_LEG_CODE, "LongVault");
        assertEq(keccak256(type(ShortVaultExit).creationCode), SHORT_EXIT_CODE, "ShortVaultExit");
        assertEq(keccak256(type(ShortVault).creationCode), SHORT_LEG_CODE, "ShortVault");
        assertEq(keccak256(type(CombinationFactory).creationCode), COMBINATION_CODE, "CombinationFactory");
        assertEq(keccak256(type(StrategyHub).creationCode), HUB_CODE, "StrategyHub");
        assertEq(keccak256(type(StrategyHubFee).creationCode), HUB_FEE_CODE, "StrategyHubFee");
    }

    /// The whole deployment for recovery 0xdEaD, as `script/Deploy.s.sol` performs it on each chain: the
    /// addresses and the code hashes the combination's pins carry.
    function test_deploymentVectors() public {
        vm.etch(DETERMINISTIC_DEPLOYER, DEPLOYER_RUNTIME);
        vm.etch(TRANSMITTER, type(MockTransmitter).runtimeCode);
        MockTransmitter(TRANSMITTER).setLocalDomain(19); // HyperEVM checks the Hyperliquid pin
        address registry =
            _deploy(REGISTRY_SALT, abi.encodePacked(type(VaultRegistry).creationCode, abi.encode(RECOVERY_V)));
        address hubFee = _deploy(HUB_FEE_SALT, type(StrategyHubFee).creationCode);
        address hub = _deploy(
            HUB_SALT, abi.encodePacked(type(StrategyHub).creationCode, abi.encode(hubFee, hubFee.codehash))
        );
        address longExit = _deploy(LONG_EXIT_SALT, type(LongVaultExit).creationCode);
        address longLeg = _deploy(
            LONG_LEG_SALT, abi.encodePacked(type(LongVault).creationCode, abi.encode(longExit, longExit.codehash))
        );
        address shortExit = _deploy(SHORT_EXIT_SALT, type(ShortVaultExit).creationCode);
        address shortLeg = _deploy(
            SHORT_LEG_SALT, abi.encodePacked(type(ShortVault).creationCode, abi.encode(shortExit, shortExit.codehash))
        );
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = 3;
        CombinationFactory.LegPin[] memory pins = new CombinationFactory.LegPin[](2);
        pins[0] = CombinationFactory.LegPin(longLeg, longLeg.codehash, 3, Legs.LONG, Legs.VALUE_READ, ParamsTypes.AAVE_V3_NAME, ParamsTypes.AAVE_V3_FIELDS, ParamsTypes.AAVE_V3_COUNT);
        pins[1] = CombinationFactory.LegPin(shortLeg, shortLeg.codehash, 19, Legs.SHORT, Legs.VALUE_READ, ParamsTypes.HYPERCORE_NAME, ParamsTypes.HYPERCORE_FIELDS, ParamsTypes.HYPERCORE_COUNT);
        address combination = _deploy(
            COMBINATION_SALT,
            abi.encodePacked(
                type(CombinationFactory).creationCode,
                abi.encode(registry, hub, hub.codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, hubDomains, pins, FeePins.prices(), FeePins.sequencers())
            )
        );
        emit log_named_address("registry", registry);
        emit log_named_address("hub fee module", hubFee);
        emit log_named_address("hub code", hub);
        emit log_named_bytes32("hub code hash", hub.codehash);
        emit log_named_address("long exit module", longExit);
        emit log_named_bytes32("long exit module code hash", longExit.codehash);
        emit log_named_address("long leg code", longLeg);
        emit log_named_bytes32("long leg code hash", longLeg.codehash);
        emit log_named_address("short exit module", shortExit);
        emit log_named_bytes32("short exit module code hash", shortExit.codehash);
        emit log_named_address("short leg code", shortLeg);
        emit log_named_bytes32("short leg code hash", shortLeg.codehash);
        emit log_named_address("combination AAVE Arbitrum x Hyperliquid", combination);
        // the modules carry no immutable: their code hash is their runtime code's, known before deployment
        assertEq(longExit.codehash, keccak256(type(LongVaultExit).runtimeCode));
        // solc 0.8.37 (via-IR) emits `type(ShortVaultExit).runtimeCode` differently in this compile unit
        // than the runtime its creation code deploys (the combined review's re-pin, 2026-10-18; 0.8.28 had
        // them equal): the deployed module, what the leg pins, is the vector below
        assertEq(shortExit.codehash, 0x6a7bebb78fd843969f0fcc1ba552011b16a07a2128f045e9e7f6af549d0d6472, "short exit module code hash");
        assertEq(hubFee.codehash, keccak256(type(StrategyHubFee).runtimeCode));
        assertEq(registry, 0x057a270B71e1189BF8e877FD9CFA6f399b8608CD, "registry vector");
        assertEq(hub, 0xbb416DF2FA250301B2c1F92e2CD9B8723a0a98f8, "hub code vector");
        assertEq(hub.codehash, 0x539cd67f0106ff95734af31c613f60604ff953715f6de219c89fe5fae77dbd17, "hub code hash");
        assertEq(longExit, 0x8503d38Dc689fDacF732B9127EfF30E18101f9d0, "long exit module vector");
        assertEq(longLeg, 0x576848daE996EA4fFFce9462F028aAab27C08C3D, "long leg code vector");
        assertEq(longLeg.codehash, 0x1bc4ae3696e6e8db5c393acb4cb6219f07b4cde3cf90cc1cc95c524a8912cdda, "long leg code hash");
        assertEq(shortExit, 0x28BA9223B86471Ee3D10b396bB817d37D2BfA0f9, "short exit module vector");
        assertEq(shortLeg, 0x1F58E440292434CCBA90869502033e6b5730d072, "short leg code vector");
        assertEq(shortLeg.codehash, 0x1a3ec84f1960379ea063c0217e8216e60bcecbd16157a0ac8516ea680b9a7385, "short leg code hash");
        assertEq(hubFee, 0xce38790486045B2E44D21D99E225b8cD08491e48, "hub fee module vector");
        assertEq(combination, 0xf8410023BD0729A9B28CF5e7c2Fe60Ffc7A180B0, "combination vector");
    }

    /// For the TypeScript encoders: a fixed configuration (no deployment in it), its hash, its pair id and
    /// each member's address from a fixed factory (member 0 the hub).
    function test_configVectors() public {
        address f = 0x00000000000000000000000000000000000fAc70;
        address longCode = 0x0000000000000000000000000000000000001001;
        address shortCode = 0x0000000000000000000000000000000000001002;
        address hubCode = 0x0000000000000000000000000000000000001000;
        address ownerV = 0x00000000000000000000000000000000000D1D1D;
        bytes32 strategyV = 0x000000000000000000000000000000000192f1a2b3c47d8e9f00112233445566;
        StrategyConfig memory c;
        c.factory = f;
        c.group = 2;
        c.hubDomain = 3;
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 50, feeBudgetBp: 500, feeRateBp: 1500}));
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(
            longCode,
            3,
            Legs.LONG,
            abi.encode(
                LongParams(
                    Arbitrum.POOL, Arbitrum.ORACLE, Arbitrum.WETH, Arbitrum.USDC, Arbitrum.SWAP_POOL, Arbitrum.RECEIVER,
                    1.05e18, 300, 500, 50
                )
            )
        );
        c.legs[1] = LegConfig(shortCode, 19, Legs.SHORT, abi.encode(ShortParams(1, Assets.ETH, 500, 50, 500)));
        bytes32 h = VaultConfig.hash(c);
        bytes32 pair = VaultConfig.pairId(strategyV, ownerV, h);
        address m0 = _predictClone(f, hubCode, VaultConfig.legSalt(pair, 0));
        address m1 = _predictClone(f, longCode, VaultConfig.legSalt(pair, 1));
        address m2 = _predictClone(f, shortCode, VaultConfig.legSalt(pair, 2));
        emit log_named_bytes32("configHash", h);
        emit log_named_bytes32("pairId", pair);
        emit log_named_address("member 0 (the hub)", m0);
        emit log_named_address("member 1 (the AAVE leg)", m1);
        emit log_named_address("member 2 (the Hyperliquid leg)", m2);
        assertEq(h, 0x7b739582fab21bfa64f70f010a1a958af0f0ef35461c61f03ed3af68d13fed23, "configHash vector");
        assertEq(pair, 0x3db8301178b0b318494b59f358a0cff01876b9102a6dc3fe9d00d4be58647898, "pairId vector");
        assertEq(m0, 0xB5d45Ec1444e0d7Dff8E181C63d761B862a635a1, "member 0 vector");
        assertEq(m1, 0x543b45D5389B1d85345F032462636161250E1CF8, "member 1 vector");
        assertEq(m2, 0xe66b82BA1D846B466214831A6891283d4f6B7fFB, "member 2 vector");
    }

    function _predictClone(address deployer, address impl, bytes32 salt) internal pure returns (address) {
        bytes memory init = abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(init))))));
    }
}
