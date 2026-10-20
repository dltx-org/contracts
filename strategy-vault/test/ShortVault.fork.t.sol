// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {LongVault} from "../src/LongVault.sol";
import {LongVaultExit} from "../src/LongVaultExit.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";
import {ShortVaultState} from "../src/ShortVaultState.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {StrategyHubFee} from "../src/StrategyHubFee.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {FeePins} from "../src/lib/FeePins.sol";
import {
    Assets,
    Holding,
    HubParams,
    LegConfig,
    Legs,
    LongParams,
    OwnerMessages,
    ShortParams,
    StrategyConfig,
    VaultConfig,
    ParamsTypes
} from "../src/lib/VaultTypes.sol";
import {CoreState, MockOwner, PrecompileStub, walletCred} from "./mocks/Mocks.sol";

interface IERC20h {
    function balanceOf(address) external view returns (uint256);
}

/// TokenMessengerV2's minimum fee (read on HyperEVM 2026-10-14: minFee 0, MIN_FEE_MULTIPLIER 1e7).
interface IMinFee {
    function minFeeController() external view returns (address);
    function setMinFee(uint256 minFee) external;
    function getMinFeeAmount(uint256 amount) external view returns (uint256);
}

interface ITransmitterh {
    function localDomain() external view returns (uint32);
    function attesterManager() external view returns (address);
    function enableAttester(address attester) external;
    function setSignatureThreshold(uint256 newSignatureThreshold) external;
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/*
 * The Hyperliquid leg on a HyperEVM fork (spec §13: "the CoreWriter bytes of every short-half function;
 * Circle's deposit; topUpHype; the owner's replaceAgent"): the REAL CoreWriter (its RawAction log is
 * what HyperCore executes), Circle's real USDC, CoreDepositWallet and CCTP V2. HyperCore's read
 * precompiles do not exist in Foundry's EVM, so they are the unit tests' stubs; HyperCore's effects are
 * not simulated here — §5's mainnet probe proved them. SKIPPED when HyperEVM can't be reached
 * (HYPEREVM_RPC_URL, default the public https://rpc.hyperliquid.xyz/evm).
 */
contract ShortVaultForkTest is Test {
    uint256 constant PINNED_BLOCK = 48_521_917; // the probe's pinned block, 2026-10-14
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CDW = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant STATE = 0x00000000000000000000000000000000c0eC0dE0;
    address constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    address constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    uint32 constant SPOT = type(uint32).max;
    bytes32 constant STRATEGY = keccak256("strategy-1");

    // CoreWriter's only event (topic 0x8c7f585f…12e3, read from its runtime code by the probe)
    event RawAction(address indexed user, bytes data);

    bool forked;
    VaultRegistry registry;
    CombinationFactory factory;
    LongVault longCode;
    ShortVault shortCode;
    MockOwner owner;
    ShortVault vault;
    ShortVaultExit ex; // the same address: the exit module's functions
    CoreState core;
    address recovery = makeAddr("recovery");
    address key = makeAddr("group-key");
    address stranger = makeAddr("stranger");
    uint256 walletPk;
    address wallet;

    function setUp() public {
        string memory url = vm.envOr("HYPEREVM_RPC_URL", string("https://rpc.hyperliquid.xyz/evm"));
        try vm.createSelectFork(url, vm.envOr("HYPEREVM_FORK_BLOCK", PINNED_BLOCK)) returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        assertEq(block.chainid, 999, "not HyperEVM");
        vm.etch(STATE, type(CoreState).runtimeCode);
        for (uint160 a = 0x800; a <= 0x810; ++a) {
            vm.etch(address(a), type(PrecompileStub).runtimeCode);
        }
        core = CoreState(STATE);
        core.setOracle(1, 243_140, 4);
        core.setOracle(159, 802_635, 2);

        (wallet, walletPk) = makeAddrAndKey("owner-wallet");
        owner = new MockOwner();
        owner.setWallet(wallet, true);
        registry = new VaultRegistry(recovery);
        vm.prank(recovery);
        registry.setExecutionKey(2, key);
        LongVaultExit longExit = new LongVaultExit(); // Arbitrum's: here only for its address
        longCode = new LongVault(address(longExit), address(longExit).codehash);
        // the leg code's constructor checks its module's code hash: EXTCODEHASH on HyperEVM itself
        ShortVaultExit shortExit = new ShortVaultExit();
        shortCode = new ShortVault(address(shortExit), address(shortExit).codehash);
        StrategyHubFee hubFee = new StrategyHubFee(); // Arbitrum's: here only for their addresses
        StrategyHub hubCode = new StrategyHub(address(hubFee), address(hubFee).codehash);
        CombinationFactory.LegPin[] memory pins = new CombinationFactory.LegPin[](2);
        pins[0] = CombinationFactory.LegPin(address(longCode), address(longCode).codehash, 3, Legs.LONG, Legs.VALUE_READ, ParamsTypes.AAVE_V3_NAME, ParamsTypes.AAVE_V3_FIELDS, ParamsTypes.AAVE_V3_COUNT);
        pins[1] = CombinationFactory.LegPin(address(shortCode), address(shortCode).codehash, 19, Legs.SHORT, Legs.VALUE_READ, ParamsTypes.HYPERCORE_NAME, ParamsTypes.HYPERCORE_FIELDS, ParamsTypes.HYPERCORE_COUNT);
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = 3;
        // HyperEVM's copy checks the Hyperliquid pin
        factory = new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, hubDomains, pins, FeePins.prices(), FeePins.sequencers()
        );
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 hours;
        vault = ShortVault(
            payable(
                factory.create(
                    STRATEGY,
                    address(owner),
                    c,
                    deadline,
                    _signDigest(factory.createDigest(STRATEGY, address(owner), c, deadline))
                )[0]
            )
        );
        ex = ShortVaultExit(address(vault));
        // the hub's and the AAVE leg's finalized READY from Arbitrum, Circle's transmitter impersonated
        for (uint256 k; k < 2; ++k) {
            bytes32 from = bytes32(uint256(uint160(vault.links(k))));
            vm.prank(TRANSMITTER);
            vault.handleReceiveFinalizedMessage(3, from, 2000, abi.encode(keccak256("dltx.strategy-vault.ready.v1")));
        }
        core.setExists(address(vault), true);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _config() internal view returns (StrategyConfig memory c) {
        c.factory = address(factory);
        c.group = 2;
        c.hubDomain = 3;
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 5, feeBudgetBp: 50, feeRateBp: 1500}));
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(
            address(longCode),
            3,
            Legs.LONG,
            abi.encode(
                LongParams(
                    Arbitrum.POOL, Arbitrum.ORACLE, Arbitrum.WETH, Arbitrum.USDC, Arbitrum.SWAP_POOL, Arbitrum.RECEIVER,
                    1.15e18, 100, 50, 5
                )
            )
        );
        c.legs[1] = LegConfig(address(shortCode), 19, Legs.SHORT, abi.encode(ShortParams({perp: 1, asset: Assets.ETH, orderBoundBp: 100, fastFeeCapBp: 5, feeBudgetBp: 50}))
        );
    }

    function _signDigest(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletPk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(walletPk, keccak256(abi.encodePacked(hex"1901", owner.domainSeparator(), structHash)));
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _expectRaw(address user, bytes memory data) internal {
        vm.expectEmit(true, false, false, true, CORE_WRITER);
        emit RawAction(user, data);
    }

    // ── the chain ────────────────────────────────────────────────────────────────────────────────────

    function test_fork_hyperevm_wiring() public onFork {
        assertEq(ITransmitterh(TRANSMITTER).localDomain(), 19);
        assertGt(CORE_WRITER.code.length, 0);
        assertGt(CDW.code.length, 0);
        assertEq(vault.linkDomains(0), 3);
        assertEq(vault.linkDomains(1), 3);
        (address[] memory at,) = factory.memberAddresses(STRATEGY, address(owner), _config());
        assertEq(vault.links(0), at[0], "its hub");
        assertEq(vault.links(1), at[1], "its sister leg");
        assertEq(address(vault), at[2]);
        assertEq(shortCode.exitModule().codehash, keccak256(type(ShortVaultExit).runtimeCode));
    }

    // ── Circle's deposit: CoreDepositWallet forwards with ITS OWN action 13, crediting the VAULT ─────

    function test_fork_toMargin_circleCreditsTheVaultsOwnPerpMargin() public onFork {
        deal(USDC, address(vault), 5e6);
        _expectRaw(CDW, abi.encodePacked(uint8(1), uint24(13), abi.encode(address(vault), address(0), SPOT, uint32(0), uint64(0), uint64(500_000_000))));
        vm.prank(key);
        vault.toMargin(5e6);
        assertEq(IERC20h(USDC).balanceOf(address(vault)), 0);
    }

    // ── the CoreWriter bytes of every short-half function ──────────────────────────────────────────

    function test_fork_fromMargin_bytes() public onFork {
        _expectRaw(address(vault), hex"0100000700000000000000000000000000000000000000000000000000000000003d09000000000000000000000000000000000000000000000000000000000000000000");
        _expectRaw(address(vault), abi.encodePacked(uint8(1), uint24(13), abi.encode(USDC_SYSTEM, address(0), SPOT, SPOT, uint64(0), uint64(400_000_000))));
        vm.prank(key);
        vault.fromMargin(4_000_000);
    }

    function test_fork_order_and_cancels_bytes() public onFork {
        // ETH, buy, 2,455.70, 0.0045, reduce-only, IOC, no cloid
        _expectRaw(
            address(vault),
            bytes.concat(
                hex"01000001",
                hex"0000000000000000000000000000000000000000000000000000000000000001",
                hex"0000000000000000000000000000000000000000000000000000000000000001",
                hex"000000000000000000000000000000000000000000000000000000392d1cd480",
                hex"000000000000000000000000000000000000000000000000000000000006ddd0",
                hex"0000000000000000000000000000000000000000000000000000000000000001",
                hex"0000000000000000000000000000000000000000000000000000000000000003",
                hex"0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
        vm.prank(key);
        vault.order(true, 450_000, true);
        _expectRaw(address(vault), abi.encodePacked(uint8(1), uint24(10), abi.encode(uint32(1), uint64(42))));
        vm.prank(key);
        vault.cancel(1, false, 42);
        _expectRaw(address(vault), abi.encodePacked(uint8(1), uint24(11), abi.encode(uint32(1), uint128(0xbeef))));
        vm.prank(key);
        vault.cancel(1, true, 0xbeef);
    }

    function test_fork_agent_bytes_andTheOwnersReplaceAgent() public onFork {
        address a1 = makeAddr("agent-1");
        vm.prank(key);
        vault.proposeAgent(a1);
        // (address, string "dltx"): the address, offset 0x40, length 4, "dltx" padded
        _expectRaw(
            address(vault),
            bytes.concat(
                hex"01000009",
                abi.encode(a1),
                hex"0000000000000000000000000000000000000000000000000000000000000040",
                hex"0000000000000000000000000000000000000000000000000000000000000004",
                hex"646c747800000000000000000000000000000000000000000000000000000000"
            )
        );
        vm.prank(key);
        vault.applyAgent();
        address mine = makeAddr("owner-agent");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, address(vault), block.chainid, uint8(3), mine, uint256(0), deadline))
        );
        // decision 34: the owner's own agent waits 24 hours; then anyone applies it
        vm.prank(stranger);
        vault.ownerAction(OwnerMessages.REPLACE_AGENT, mine, walletCred(wallet), deadline, sig);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _expectRaw(address(vault), abi.encodePacked(uint8(1), uint24(9), abi.encode(mine, "dltx")));
        vault.applyOwnerAgent();
        assertEq(vault.agent(), mine);
        // the burner, at once
        address b = vault.burner();
        uint256 d2 = vm.getBlockTimestamp() + 1 hours; // via-IR may keep block.timestamp across a warp
        sig = _sign(
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, address(vault), block.chainid, uint8(3), b, uint256(1), d2))
        );
        _expectRaw(address(vault), abi.encodePacked(uint8(1), uint24(9), abi.encode(b, "dltx")));
        vault.ownerAction(OwnerMessages.REPLACE_AGENT, b, walletCred(wallet), d2, sig);
    }

    function test_fork_topUpHype_creditsItsCoreSpot() public onFork {
        uint256 before = HYPE_SYSTEM.balance;
        vm.deal(key, 1 ether);
        vm.prank(key);
        vault.topUpHype{value: 0.01 ether}(0.01 ether);
        assertEq(HYPE_SYSTEM.balance, before + 0.01 ether);
        // in exit, anyone, bringing the HYPE
        uint256 deadline = block.timestamp + 1 hours;
        vault.beginExit(deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, deadline))));
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vault.topUpHype{value: 0.02 ether}(0.02 ether);
        assertEq(HYPE_SYSTEM.balance, before + 0.03 ether);
    }

    /// To the hub, and to the AAVE leg directly, each burn bound to its member: Circle's real
    /// `MessageSent` names it as the mint's recipient and only caller (decision 44).
    function test_fork_send_toEachMember_boundBurns() public onFork {
        deal(USDC, address(vault), 30e6);
        for (uint8 k; k < 2; ++k) {
            vm.recordLogs();
            vm.prank(key);
            vault.send(k, 10e6, false, 0);
            bytes memory message = _messageSent(vm.getRecordedLogs());
            bytes32 to = bytes32(uint256(uint160(vault.links(k))));
            assertEq(uint32(bytes4(_slice(message, 8, 4))), 3, "to Arbitrum");
            assertEq(bytes32(_slice(message, 108, 32)), to, "its only caller");
            assertEq(bytes32(_slice(message, 148 + 36, 32)), to, "its recipient");
            assertEq(bytes32(_slice(message, 148 + 100, 32)), bytes32(uint256(uint160(address(vault)))));
            assertEq(vault.sentTo(k), 10e6);
        }
        assertEq(IERC20h(USDC).balanceOf(address(vault)), 10e6);
    }

    /// Circle's fees within the leg's daily budget: 50 bp of its value (here its HyperEVM USDC alone).
    function test_fork_send_feeBudget() public onFork {
        address controller = IMinFee(TOKEN_MESSENGER).minFeeController();
        vm.prank(controller);
        IMinFee(TOKEN_MESSENGER).setMinFee(9_000); // 9 bp, under the 10 bp cap
        // each send of the whole 1,000 pays 0.9: five fit in 5 (50 bp of 1,000), a sixth doesn't
        vm.startPrank(key);
        for (uint256 i; i < 5; ++i) {
            deal(USDC, address(vault), 1_000e6);
            vault.send(0, 1_000e6, false, 0);
        }
        deal(USDC, address(vault), 1_000e6);
        vm.expectRevert(VaultState.OverFeeBudget.selector);
        vault.send(0, 1_000e6, false, 0);
        vm.stopPrank();
    }

    /// The leg's report goes to its hub on Arbitrum by Circle, finalized: USD (perp cash, spot, HyperEVM)
    /// and the perp's asset in 18 decimals, its counters, and the block of its last HyperCore move.
    function test_fork_report_toTheHubByCircle() public onFork {
        deal(USDC, address(vault), 10e6);
        core.setMargin(0, address(vault), 1_500e6, 0, 0); // rawUsd 1,500 (the stub's rawUsd = av)
        core.setSpot(address(vault), 0, 200e8); // 200 USDC on spot (8 decimals)
        core.setPosition(address(vault), 1, -4_500); // 0.45 ETH short (szDecimals 4)
        vm.prank(key);
        vault.toMargin(5e6);
        uint256 moved = vm.getBlockNumber(); // via-IR may read `block.number` after the roll
        vm.roll(moved + 5);
        vm.recordLogs();
        vm.prank(stranger);
        ex.report();
        bytes memory message = _messageSent(vm.getRecordedLogs());
        assertEq(bytes32(_slice(message, 76, 32)), bytes32(uint256(uint160(vault.links(0)))), "to its hub");
        assertEq(uint32(bytes4(_slice(message, 140, 4))), 2000, "finalized");
        (bytes32 tag, uint256 seq, uint256 observedAt, uint256 observedBlock, uint256 extra, Holding[] memory h,,,) =
            abi.decode(_slice(message, 148, message.length - 148), (bytes32, uint256, uint256, uint256, uint256, Holding[], uint256[4], uint256[4], uint256[4]));
        assertEq(observedBlock, vm.getBlockNumber(), "amendment 2b: the block its figures were read in");
        assertEq(tag, vault.REPORT_MESSAGE());
        assertEq(seq, 1);
        assertEq(observedAt, block.timestamp);
        assertEq(h[0].asset, Assets.USD);
        assertEq(h[0].quantity, int256(1_500e18 + 200e18 + 5e18));
        assertEq(h[1].asset, Assets.ETH);
        assertEq(h[1].quantity, -0.45e18);
        assertEq(extra, moved);
    }

    /// Decision 44 on HyperEVM's real Circle: the hub's burn on Arbitrum to this leg, attested by an
    /// attester this test enables, is completed only by the leg (through its module, by anyone) and
    /// counted there gross; Circle refuses a stranger relaying it directly.
    function test_fork_receiveMint_aBurnFromArbitrum_boundToTheLeg() public onFork {
        (address attester, uint256 pk) = makeAddrAndKey("test-attester");
        ITransmitterh t = ITransmitterh(TRANSMITTER);
        vm.startPrank(t.attesterManager());
        t.enableAttester(attester);
        t.setSignatureThreshold(1);
        vm.stopPrank();
        bytes32 messenger = bytes32(uint256(uint160(TOKEN_MESSENGER)));
        bytes32 me = bytes32(uint256(uint160(address(vault))));
        bytes memory message = abi.encodePacked(
            abi.encodePacked(uint32(1), uint32(3), uint32(19), keccak256("arb-burn-1"), messenger, messenger, me, uint32(2000), uint32(2000)),
            abi.encodePacked(
                uint32(1),
                bytes32(uint256(uint160(Arbitrum.USDC))),
                me,
                uint256(75e6),
                bytes32(uint256(uint160(vault.links(0)))), // the hub burned it
                uint256(0),
                uint256(0),
                uint256(0)
            )
        );
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, keccak256(message));
        bytes memory attestation = abi.encodePacked(r, s_, v);
        vm.prank(stranger);
        vm.expectRevert(bytes("Invalid caller for message"));
        t.receiveMessage(message, attestation);
        vm.prank(stranger);
        ex.receiveMint(message, attestation);
        assertEq(IERC20h(USDC).balanceOf(address(vault)), 75e6);
        assertEq(vault.receivedFrom(0), 75e6);
        assertEq(vault.feesFrom(0), 0);
    }

    function _messageSent(Vm.Log[] memory logs) internal pure returns (bytes memory message) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == TRANSMITTER && logs[i].topics[0] == keccak256("MessageSent(bytes)")) {
                message = abi.decode(logs[i].data, (bytes));
            }
        }
    }

    function _slice(bytes memory b, uint256 from, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = b[from + i];
    }

    /// Circle's minimum fee raised by its controller (as the review did): every burn pays it at standard
    /// finality, none above 10 bp; the exit's bridge-out waits rather than paying more.
    function test_fork_bridge_paysCirclesMinimumFee() public onFork {
        address controller = IMinFee(TOKEN_MESSENGER).minFeeController();
        vm.prank(controller);
        IMinFee(TOKEN_MESSENGER).setMinFee(1_000); // 1 bp (MIN_FEE_MULTIPLIER 1e7)
        assertEq(IMinFee(TOKEN_MESSENGER).getMinFeeAmount(1_000e6), 0.1e6);
        deal(USDC, address(vault), 3_000e6);
        vm.prank(key);
        vault.send(0, 1_000e6, false, 0);
        assertEq(IERC20h(USDC).balanceOf(address(vault)), 2_000e6);
        vm.prank(controller);
        IMinFee(TOKEN_MESSENGER).setMinFee(11_000); // 11 bp: above the vault's cap
        vm.prank(key);
        vm.expectRevert(VaultState.FeeAboveCap.selector);
        vault.send(0, 1_000e6, false, 0);
        uint256 deadline = block.timestamp + 1 hours;
        vault.beginExit(deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, deadline))));
        ex.bridgeOut();
        assertEq(IERC20h(USDC).balanceOf(address(vault)), 2_000e6, "waits above the cap");
        vm.prank(controller);
        IMinFee(TOKEN_MESSENGER).setMinFee(1_000);
        ex.bridgeOut();
        assertEq(IERC20h(USDC).balanceOf(address(vault)), 0);
    }

    /// The exit on HyperEVM: the burner replaces the agent, Circle's real `sendMessage` tells both other
    /// members, and the exit's sends are the probe's encodings (spot → HyperEVM by action 13 to the
    /// USDC system address) — HyperCore's state stubbed, the bytes real.
    function test_fork_exit_tellsThePartner_andSendsTheProvenBytes() public onFork {
        uint256 deadline = block.timestamp + 1 hours;
        vault.beginExit(deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, deadline))));
        assertFalse((vault.toldPending() != 0), "Circle's sendMessage on HyperEVM went");
        core.setSpot(address(vault), 0, 2_000_000_000);
        core.setSpot(address(vault), 150, 1_000_000);
        _expectRaw(address(vault), abi.encodePacked(uint8(1), uint24(13), abi.encode(USDC_SYSTEM, address(0), SPOT, SPOT, uint64(0), uint64(2_000_000_000))));
        ShortVaultState.ExitArgs memory a;
        vm.prank(stranger);
        ex.exitStep(a);
        // what came back to HyperEVM is sent to the hub, in a later call
        deal(USDC, address(vault), 20e6);
        vm.roll(vm.getBlockNumber() + 20);
        vm.prank(stranger);
        ex.exitStep(a);
        assertEq(IERC20h(USDC).balanceOf(address(vault)), 0);
    }
}
