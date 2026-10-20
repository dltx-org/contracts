// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {walletCred} from "./mocks/Mocks.sol";

import {console} from "forge-std/console.sol";
import {Fixture} from "./utils/Fixture.sol";
import {VaultBase} from "../src/VaultBase.sol";
import {OwnerDomain} from "../src/interfaces/IDepositOwner.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {
    Assets,
    HubParams,
    LegConfig,
    Legs,
    LongParams,
    OwnerMessages,
    ShortParams,
    StrategyConfig
} from "../src/lib/VaultTypes.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";

/*
 * THE OWNER'S VAULT MESSAGES, AS DIGEST VECTORS FOR THE TYPESCRIPT SIDE (step 11e3 §8.4, slice 1).
 *
 * `@engine/owner` computes the digest of `CreateVault`, `BeginExit` and `VaultAction` from its own copy of
 * the type strings and the owner domain; `engine/owner/tests/vault-messages.test.ts` pins the literals below.
 * Two halves, so neither side can drift alone:
 *   - `test_digestVectors`: fixed inputs through THIS project's `OwnerMessages` type hashes and
 *     `OwnerDomain.digest` (the domain `{name: "DLTX Owner", version: "1", verifyingContract: owner}`, no
 *     chain id), the literals pinned. `forge test --match-test test_digestVectors -vv` prints them;
 *   - the `accepts` tests: the factory's `create`, a vault's `ownerAction` and `beginExit` accept a
 *     signature over the digest computed by the SAME helpers, and only then: the helpers are the contract's
 *     own encoding of each struct, not a copy that could differ.
 * The inputs are independent of any deployment (a fixed owner, vault and configuration), so a change of the
 * factory's bytecode or salt moves no vector; a change of a type string or of the domain moves them all.
 *
 * Amendment 2d §4.2: `CreateVault` is typed field by field, one nested struct per member type. Its vector is
 * encoded here from the LITERAL type string below and each member's fields decoded one by one (EIP-712 as a
 * wallet does it, independent of the factory's composition from its pins), and pinned to viem's
 * `hashTypedData` of the same message (the spec's build record, §18); `test_factoryDigest_isTheTypedMessage`
 * checks the factory computes the same digest.
 */
contract OwnerDigestsTest is Fixture {
    address constant OWNER_V = 0x00000000000000000000000000000000000D1D1D;
    bytes32 constant STRATEGY_V = 0x000000000000000000000000000000000192f1a2b3c47d8e9f00112233445566;
    /// The whole `CreateVault` type for today's combination, as a wallet's `eth_signTypedData_v4` composes it.
    string constant CREATE_VAULT_TYPE =
        "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,StrategyHub hub,AaveV3Leg leg1,HyperCoreLeg leg2,uint256 deadline)"
        "AaveV3Leg(address pool,address oracle,address weth,address usdc,address swapPool,address receiver,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp)"
        "HyperCoreLeg(uint32 perp,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp)"
        "StrategyHub(uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp)";
    uint256 constant DEADLINE_V = 1_800_000_000;
    address constant VAULT_V = 0x000000000000000000000000000000000000fA17;
    address constant AGENT_V = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        _world();
    }

    // ── the helpers: the contract's own encodings ────────────────────────────────────────────────────

    /// `CreateVault`'s digest for today's combination (the hub, the AAVE leg, the Hyperliquid leg),
    /// encoded field by field from the literal type string: independent of the factory's composition.
    function _createVault(address o, bytes32 strategyId, StrategyConfig memory c, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        HubParams memory h = abi.decode(c.hubParams, (HubParams));
        LongParams memory l = abi.decode(c.legs[0].params, (LongParams));
        ShortParams memory sp = abi.decode(c.legs[1].params, (ShortParams));
        bytes32 hub = keccak256(
            abi.encode(
                keccak256("StrategyHub(uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRateBp)"),
                h.fastFeeCapBp,
                h.feeBudgetBp,
                h.feeRateBp
            )
        );
        bytes32 leg1 = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "AaveV3Leg(address pool,address oracle,address weth,address usdc,address swapPool,address receiver,uint64 healthFloor,uint16 oracleBoundBp,uint16 dailyLossBp,uint16 fastFeeCapBp)"
                    ),
                    l.pool,
                    l.oracle,
                    l.weth,
                    l.usdc,
                    l.swapPool
                ),
                abi.encode(l.receiver, l.healthFloor, l.oracleBoundBp, l.dailyLossBp, l.fastFeeCapBp)
            )
        );
        bytes32 leg2 = keccak256(
            abi.encode(
                keccak256("HyperCoreLeg(uint32 perp,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudgetBp)"),
                sp.perp,
                sp.asset,
                sp.orderBoundBp,
                sp.fastFeeCapBp,
                sp.feeBudgetBp
            )
        );
        return OwnerDomain.digest(
            o,
            keccak256(
                abi.encode(
                    keccak256(bytes(CREATE_VAULT_TYPE)), c.factory, strategyId, c.group, c.hubDomain, hub, leg1, leg2, deadline
                )
            )
        );
    }

    /// The fixed configuration of `PinnedTest.test_configVectors` (DLTX's defaults at the code's limits).
    function _vectorConfig() internal pure returns (StrategyConfig memory c) {
        c.factory = 0x00000000000000000000000000000000000fAc70;
        c.group = 2;
        c.hubDomain = 3;
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 50, feeBudgetBp: 500, feeRateBp: 1500}));
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(
            0x0000000000000000000000000000000000001001,
            3,
            Legs.LONG,
            abi.encode(
                LongParams(
                    Arbitrum.POOL, Arbitrum.ORACLE, Arbitrum.WETH, Arbitrum.USDC, Arbitrum.SWAP_POOL, Arbitrum.RECEIVER,
                    1.05e18, 300, 500, 50
                )
            )
        );
        c.legs[1] = LegConfig(
            0x0000000000000000000000000000000000001002, 19, Legs.SHORT, abi.encode(ShortParams(1, Assets.ETH, 500, 50, 500))
        );
    }

    /// `VaultBase.beginExit`'s digest.
    function _beginExit(address o, bytes32 strategyId, uint256 deadline) internal pure returns (bytes32) {
        return OwnerDomain.digest(o, keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, strategyId, deadline)));
    }

    /// `VaultBase.ownerAction`'s digest.
    function _vaultAction(
        address o,
        address vault,
        uint256 chainId,
        uint8 action,
        address agent,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return OwnerDomain.digest(
            o,
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, vault, chainId, action, agent, nonce, deadline))
        );
    }

    function _signDigest(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletPk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    // ── the vectors ──────────────────────────────────────────────────────────────────────────────────

    function test_digestVectors() public pure {
        bytes32 createVault = _createVault(OWNER_V, STRATEGY_V, _vectorConfig(), DEADLINE_V);
        bytes32 beginExit = _beginExit(OWNER_V, STRATEGY_V, DEADLINE_V);
        // the short half on HyperEVM: a new agent at once (REPLACE_AGENT)
        bytes32 replaceAgent = _vaultAction(OWNER_V, VAULT_V, 999, OwnerMessages.REPLACE_AGENT, AGENT_V, 7, DEADLINE_V);
        // the long half on Arbitrum: DLTX revoked (REVOKE_EXECUTION), no agent
        bytes32 revoke =
            _vaultAction(OWNER_V, VAULT_V, 42161, OwnerMessages.REVOKE_EXECUTION, address(0), 0, DEADLINE_V);
        console.log("domainSeparator");
        console.logBytes32(OwnerDomain.separator(OWNER_V));
        console.log("CreateVault");
        console.logBytes32(createVault);
        console.log("BeginExit");
        console.logBytes32(beginExit);
        console.log("VaultAction REPLACE_AGENT on 999");
        console.logBytes32(replaceAgent);
        console.log("VaultAction REVOKE_EXECUTION on 42161");
        console.logBytes32(revoke);
        assertEq(OwnerDomain.separator(OWNER_V), 0x4e9a663853527e9c96e06f2735c7a91b7b6c128aaea3d88b2e611cd4765f3217);
        // viem 2.56 `hashTypedData` of the same message (amendment 2d build record)
        assertEq(createVault, 0x148c196c84a8d139a0684a7a6c76c6cd2c726f4bff4dbb2f48b96f574137769a, "CreateVault");
        assertEq(beginExit, 0x36ce88d85c9170384fd558fd88d39f218572c464497b8441a611f65131426ede, "BeginExit");
        assertEq(replaceAgent, 0xf34491195fdd624e77f71368531fe279ed2f99de3a352c0ec4513fffc799b4c4, "REPLACE_AGENT");
        assertEq(revoke, 0xad6cf8cdb27c2e16e1f58673c747d19075b6c6861662abd37251828014905fac, "REVOKE_EXECUTION");
    }

    // ── the contracts accept a signature over exactly these digests ──────────────────────────────────

    function test_factoryAcceptsTheCreateVaultDigest() public {
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        // a digest over another value of any field is refused: the signature binds every parameter
        StrategyConfig memory other = _config();
        other.hubParams = abi.encode(HubParams({fastFeeCapBp: 5, feeBudgetBp: 50, feeRateBp: 1501}));
        bytes memory wrong = _signDigest(_createVault(address(owner), STRATEGY, other, deadline));
        vm.expectRevert(CombinationFactory.BadSignature.selector);
        factory.create(STRATEGY, address(owner), c, deadline, wrong);
        address v = factory.create(
            STRATEGY, address(owner), c, deadline, _signDigest(_createVault(address(owner), STRATEGY, c, deadline))
        )[0];
        assertTrue(v.code.length > 0);
    }

    /// Amendment 2d §4.2: the factory composes the same type a wallet does, and computes the same digest.
    function test_factoryDigest_isTheTypedMessage() public view {
        assertEq(factory.createVaultType(), CREATE_VAULT_TYPE);
        assertEq(factory.createVaultTypehash(), keccak256(bytes(CREATE_VAULT_TYPE)));
        StrategyConfig memory c = _config();
        assertEq(factory.createDigest(STRATEGY, address(owner), c, 1234), _createVault(address(owner), STRATEGY, c, 1234));
        c = _vectorConfig();
        assertEq(factory.createDigest(STRATEGY_V, OWNER_V, c, DEADLINE_V), _createVault(OWNER_V, STRATEGY_V, c, DEADLINE_V));
    }

    function test_vaultAcceptsTheVaultActionDigest() public {
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        address v = factory.create(
            STRATEGY,
            address(owner),
            c,
            deadline,
            _signDigest(_createVault(address(owner), STRATEGY, c, deadline))
        )[0];
        VaultBase vault = VaultBase(v);
        uint256 nonce = vault.ownerNonceOf(walletCred(wallet));
        // the chain id is the vault's chain: a digest naming another chain is refused
        bytes memory otherChain = _signDigest(
            _vaultAction(
                address(owner), v, block.chainid + 1, OwnerMessages.REVOKE_EXECUTION, address(0), nonce, deadline
            )
        );
        vm.expectRevert();
        vault.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, otherChain);
        vault.ownerAction(
            OwnerMessages.REVOKE_EXECUTION,
            address(0),
            walletCred(wallet),
            deadline,
            _signDigest(
                _vaultAction(
                    address(owner), v, block.chainid, OwnerMessages.REVOKE_EXECUTION, address(0), nonce, deadline
                )
            )
        );
        assertTrue(vault.executionRevoked());
        vault.ownerAction(
            OwnerMessages.ALLOW_EXECUTION,
            address(0),
            walletCred(wallet),
            deadline,
            _signDigest(
                _vaultAction(
                    address(owner), v, block.chainid, OwnerMessages.ALLOW_EXECUTION, address(0), nonce + 1, deadline
                )
            )
        );
        assertFalse(vault.executionRevoked());
        assertEq(vault.ownerNonceOf(walletCred(wallet)), nonce + 2);
    }

    function test_vaultAcceptsTheBeginExitDigest() public {
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        address v = factory.create(
            STRATEGY,
            address(owner),
            c,
            deadline,
            _signDigest(_createVault(address(owner), STRATEGY, c, deadline))
        )[0];
        VaultBase(v).beginExit(deadline, _signDigest(_beginExit(address(owner), STRATEGY, deadline)));
        assertTrue(VaultBase(v).exiting());
    }
}
