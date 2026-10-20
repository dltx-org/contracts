// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {DepositAccount} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Helpers} from "./Helpers.sol";
import {
    Assets, HubParams, LegConfig, Legs, LongParams, OwnerMessages, ParamsTypes, ShortParams, StrategyConfig
} from "@vault/lib/VaultTypes.sol";
import {FeePins} from "@vault/lib/FeePins.sol";
import {PriceSourcePin, SequencerPin} from "@vault/lib/PriceSource.sol";
import {Arbitrum} from "@vault/lib/Pinned.sol";

/// `CombinationFactory.LegPin`, ABI-identical.
struct LegPin {
    address code;
    bytes32 codeHash;
    uint32 domain;
    uint8 role;
    uint8 valueKind;
    string typeName;
    string typeFields;
    uint8 fieldCount;
}

interface ICombination {
    function create(bytes32, address, StrategyConfig calldata, uint256, bytes calldata) external returns (address[] memory);
    function createDigest(bytes32, address, StrategyConfig calldata, uint256) external view returns (bytes32);
    function createVaultType() external view returns (string memory);
    function memberAddresses(bytes32, address, StrategyConfig calldata) external view returns (address[] memory, bytes32);
    function authorisedFor(address) external view returns (address, bytes32, bytes32);
}

interface IMember {
    function beginExit(uint256, bytes calldata) external;
    function exiting() external view returns (bool);
    function links(uint8) external view returns (address);
    function exitStep() external;
    function ownerAction(uint8, address, bytes32, uint256, bytes calldata) external;
    function ownerNonceOf(bytes32) external view returns (uint256);
    function executionRevoked() external view returns (bool);
    function handleReceiveFinalizedMessage(uint32, bytes32, uint32, bytes calldata) external returns (bool);
}

interface IRegistrySeam {
    function setExecutionKey(uint8, address) external;
}

interface IToken {
    function balanceOf(address) external view returns (uint256);
}

/*
 * The seam (the combined security review's brief §8): the FINAL deposit account, built here, as the owner of
 * the FINAL vault contracts, loaded from their pinned build (test/fixtures/strategy-vault-5f1fe1ae6: `forge
 * inspect <C> bytecode` in contracts/strategy-vault at fix/combined-review 5f1fe1ae6 (the approved fixes and the re-review's, solc 0.8.37), each checked against its
 * Pinned.t.sol hash where it is pinned). On the Arbitrum fork (skipped without ARBITRUM_RPC_URL): a wallet
 * owner and a passkey owner each sign the typed `CreateVault` (its digest checked against an independent
 * EIP-712 hash), the combination factory creates the hub and the AAVE leg, the account trusts the factory and
 * funds the hub only, the owner's `BeginExit` (no chain id, one signature for every member) enters the exit,
 * and the hub's exit pays the withdrawal address. A passkey assertion without user verification is refused
 * across the seam. Not covered here (single chain): the Hyperliquid leg on HyperEVM's copy, unsynced and
 * stale copies (the account's own suites cover them).
 */
contract SeamTest is Helpers {
    string constant DIR = "test/fixtures/strategy-vault-5f1fe1ae6/";
    uint256 constant PINNED_BLOCK = 514_790_000; // the vault's fork suites' block
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant GROUP_KEY = address(0xBEEF04);
    bytes32 constant STRATEGY = keccak256("seam");
    bytes32 constant READY = keccak256("dltx.strategy-vault.ready.v1");
    bytes32 constant LONG_LEG_CODE = 0xf9c31cb3659be0714a61bd486c86e39978f0c22824620fb3973e821cd4eaba6a;
    bytes32 constant COMBINATION_CODE = 0x24a4f84b2ca4cdcd0d6a4194c71b454ef9ebca6d621bc792045eda551307b184;

    address combination;
    address longCode;
    address shortCode;

    function _fork() internal returns (bool) {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url, PINNED_BLOCK);
        return true;
    }

    function _code(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat(DIR, name, ".hex")));
    }

    function _deploy(string memory name, bytes memory args) internal returns (address a) {
        bytes memory code = abi.encodePacked(_code(name), args);
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), name);
    }

    function _mesh() internal {
        address registry = _deploy("VaultRegistry", abi.encode(RECOVERY));
        vm.prank(RECOVERY);
        IRegistrySeam(registry).setExecutionKey(1, GROUP_KEY);
        address hubFee = _deploy("StrategyHubFee", "");
        address hub = _deploy("StrategyHub", abi.encode(hubFee, hubFee.codehash));
        address longExit = _deploy("LongVaultExit", "");
        longCode = _deploy("LongVault", abi.encode(longExit, longExit.codehash));
        address shortExit = _deploy("ShortVaultExit", "");
        shortCode = _deploy("ShortVault", abi.encode(shortExit, shortExit.codehash));
        LegPin[] memory pins = new LegPin[](2);
        pins[0] = LegPin(
            longCode, longCode.codehash, 3, Legs.LONG, Legs.VALUE_READ,
            ParamsTypes.AAVE_V3_NAME, ParamsTypes.AAVE_V3_FIELDS, ParamsTypes.AAVE_V3_COUNT
        );
        pins[1] = LegPin(
            shortCode, shortCode.codehash, 19, Legs.SHORT, Legs.VALUE_READ,
            ParamsTypes.HYPERCORE_NAME, ParamsTypes.HYPERCORE_FIELDS, ParamsTypes.HYPERCORE_COUNT
        );
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = 3;
        PriceSourcePin[] memory prices = FeePins.prices();
        SequencerPin[] memory sequencers = FeePins.sequencers();
        combination = _deploy(
            "CombinationFactory",
            abi.encode(
                registry, hub, hub.codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT,
                hubDomains, pins, prices, sequencers
            )
        );
    }

    function _config() internal view returns (StrategyConfig memory c) {
        c.factory = combination;
        c.group = 1;
        c.hubDomain = 3;
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 5, feeBudgetBp: 50, feeRateBp: 1500}));
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(
            longCode,
            3,
            Legs.LONG,
            abi.encode(
                LongParams({
                    pool: Arbitrum.POOL,
                    oracle: Arbitrum.ORACLE,
                    weth: Arbitrum.WETH,
                    usdc: Arbitrum.USDC,
                    swapPool: Arbitrum.SWAP_POOL,
                    receiver: Arbitrum.RECEIVER,
                    healthFloor: 1.05e18,
                    oracleBoundBp: 300,
                    dailyLossBp: 500,
                    fastFeeCapBp: 5
                })
            )
        );
        c.legs[1] = LegConfig(
            shortCode, 19, Legs.SHORT,
            abi.encode(ShortParams({perp: 1, asset: Assets.ETH, orderBoundBp: 500, fastFeeCapBp: 0, feeBudgetBp: 50}))
        );
    }

    /// `CreateVault` hashed independently of the factory, by EIP-712's rules (amendment 2d §4.2).
    function _createStruct(StrategyConfig memory c, uint256 deadline) internal view returns (bytes32) {
        string memory ty = string.concat(
            "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,StrategyHub hub,",
            "AaveV3Leg leg1,HyperCoreLeg leg2,uint256 deadline)",
            ParamsTypes.AAVE_V3,
            ParamsTypes.HYPERCORE,
            ParamsTypes.HUB
        );
        assertEq(ty, ICombination(combination).createVaultType(), "the factory's composed type");
        return keccak256(
            abi.encode(
                keccak256(bytes(ty)),
                c.factory,
                STRATEGY,
                c.group,
                c.hubDomain,
                keccak256(abi.encodePacked(keccak256(bytes(ParamsTypes.HUB)), c.hubParams)),
                keccak256(abi.encodePacked(keccak256(bytes(ParamsTypes.AAVE_V3)), c.legs[0].params)),
                keccak256(abi.encodePacked(keccak256(bytes(ParamsTypes.HYPERCORE)), c.legs[1].params)),
                deadline
            )
        );
    }

    function test_seam_theFixturesAreThePinnedBuild() public view {
        assertEq(keccak256(_code("LongVault")), LONG_LEG_CODE);
        assertEq(keccak256(_code("CombinationFactory")), COMBINATION_CODE);
    }

    function test_seam_walletOwner() public {
        if (!_fork()) return vm.skip(true);
        _seam(WALLET_A);
    }

    function test_seam_passkeyOwner() public {
        if (!_fork()) return vm.skip(true);
        _seam(PASSKEY_A);
    }

    function _seam(uint256 pk) internal {
        DepositFactory f = deployFactory();
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        DepositAccount a = DepositAccount(f.deploy(ALICE, one(credOf(pk))));
        setWithdrawalNow(a, pk, DEST);
        _mesh();
        StrategyConfig memory c = _config();
        (address[] memory at, bytes32 configHash) = ICombination(combination).memberAddresses(STRATEGY, address(a), c);
        uint256 dl = vm.getBlockTimestamp() + 7 days;

        // the typed CreateVault: the factory's digest is the account's EIP-712 hash of the independent struct
        bytes32 digest = ICombination(combination).createDigest(STRATEGY, address(a), c, dl);
        assertEq(digest, a.hashTypedData(_createStruct(c, dl)), "the typed message, under the account's domain");
        if (pk == PASSKEY_A) {
            // G6: user presence without user verification is refused across the seam
            bytes memory noUv = signPasskeyFlags(pk, digest, 0x01);
            vm.expectRevert(bytes4(keccak256("BadSignature()")));
            ICombination(combination).create(STRATEGY, address(a), c, dl, noUv);
        }
        uint256 g = gasleft();
        address[] memory made = ICombination(combination).create(STRATEGY, address(a), c, dl, sign(pk, digest));
        emit log_named_uint(pk == PASSKEY_A ? "create gas, passkey" : "create gas, wallet", g - gasleft());
        assertEq(made[0], at[0], "the hub, member 0");
        assertEq(made[1], at[1], "the AAVE leg");
        (address owner, bytes32 sid, bytes32 ch) = ICombination(combination).authorisedFor(at[0]);
        assertEq(owner, address(a));
        assertEq(sid, STRATEGY);
        assertEq(ch, configHash);
        // the Hyperliquid leg's READY (finalized), as Circle would relay it
        for (uint256 i; i < 2; ++i) {
            vm.prank(MT);
            IMember(at[i]).handleReceiveFinalizedMessage(19, bytes32(uint256(uint160(at[2]))), 2000, abi.encode(READY));
        }

        // the account trusts the factory (24 hours) and funds the hub, never a leg
        uint256 id = authorise(a, pk, combination, 3, STRATEGY, configHash, 500e6);
        deal(ARB_USDC, address(a), 600e6);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.fund(combination, at[0], 500e6);
        vm.warp(dueOf(a, combination, 3));
        a.applyAuthorisation(id);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NotOwnVault.selector);
        a.fund(combination, at[1], 1e6);
        vm.prank(TRANSFER);
        a.fund(combination, at[0], 500e6);
        assertEq(IToken(ARB_USDC).balanceOf(at[0]), 500e6, "the hub funded");

        // the owner's local action through the real account (the combined review's CR-E1, RR-6): signed by
        // this credential at its own nonce, a passkey's included; another credential's id refused
        bytes32 cred = a.credentialId(credOf(pk));
        uint256 n = IMember(at[0]).ownerNonceOf(cred);
        bytes memory revoke = sign(
            pk,
            a.hashTypedData(
                keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, at[0], block.chainid, uint8(1), address(0), n, dl))
            )
        );
        vm.expectRevert(bytes4(keccak256("BadSignature()")));
        IMember(at[0]).ownerAction(1, address(0), keccak256("another credential"), dl, revoke);
        IMember(at[0]).ownerAction(1, address(0), cred, dl, revoke);
        assertTrue(IMember(at[0]).executionRevoked(), "revoked by the owner's credential");
        assertEq(IMember(at[0]).ownerNonceOf(cred), n + 1, "its own nonce spent");

        // BeginExit: no chain id, one signature valid on every member; the hub tells its local leg
        bytes32 begin = keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, dl));
        bytes memory exitSig = sign(pk, a.hashTypedData(begin));
        g = gasleft();
        IMember(at[0]).beginExit(dl, exitSig);
        emit log_named_uint(pk == PASSKEY_A ? "beginExit gas, passkey" : "beginExit gas, wallet", g - gasleft());
        assertTrue(IMember(at[0]).exiting());
        assertTrue(IMember(at[1]).exiting(), "the local leg told");
        vm.prank(STRANGER);
        IMember(at[0]).exitStep();
        assertEq(IToken(ARB_USDC).balanceOf(DEST), 500e6, "paid to the withdrawal address: no profit, no fee");
        assertEq(IToken(ARB_USDC).balanceOf(at[0]), 0);
    }
}
