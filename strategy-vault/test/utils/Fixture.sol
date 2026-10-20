// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {CombinationFactory} from "../../src/CombinationFactory.sol";
import {VaultRegistry} from "../../src/VaultRegistry.sol";
import {VaultBase} from "../../src/VaultBase.sol";
import {LongVault} from "../../src/LongVault.sol";
import {LongVaultExit} from "../../src/LongVaultExit.sol";
import {ShortVault} from "../../src/ShortVault.sol";
import {ShortVaultExit} from "../../src/ShortVaultExit.sol";
import {StrategyHub} from "../../src/StrategyHub.sol";
import {StrategyHubFee} from "../../src/StrategyHubFee.sol";
import {
    Assets,
    HubParams,
    LegConfig,
    Legs,
    LongParams,
    OwnerMessages,
    ShortParams,
    StrategyConfig,
    VaultConfig,
    ParamsTypes
} from "../../src/lib/VaultTypes.sol";
import {Arbitrum} from "../../src/lib/Pinned.sol";
import {PriceSource, PriceSourcePin, SequencerPin} from "../../src/lib/PriceSource.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {
    CoreState,
    MockCoreDepositWallet,
    MockCoreWriter,
    MockERC20,
    MockOwner,
    MockTokenMessenger,
    MockTransmitter,
    PrecompileStub
} from "../mocks/Mocks.sol";

/*
 * The unit tests' world: HyperEVM without a network. CoreWriter, the read precompiles, Circle's USDC,
 * CoreDepositWallet and CCTP are test doubles etched at their real addresses; HyperCore's state is
 * whatever a test writes into `CoreState`, playing what Hyperliquid did with the actions sent (or not,
 * or late). The numbers are S12's (spikes/hl-vault-probe/RESULTS.md): ETH perp 1 at 2,431.40
 * (szDecimals 4, the minimum 0.0045), the HYPE perp 159 at 80.2635 (szDecimals 2), HYPE/USDC spot 107.
 */
abstract contract Fixture is Test {
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant STATE = 0x00000000000000000000000000000000c0eC0dE0;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CDW = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    address constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    uint32 constant SPOT = type(uint32).max;
    uint32 constant ETH = 1;
    uint32 constant HYPE_PERP = 159;
    uint64 constant HYPE = 150;
    uint32 constant ARB_DOMAIN = 3;
    uint32 constant HYPEREVM_DOMAIN = 19;
    bytes32 constant STRATEGY = bytes32(uint256(0x5a5a));

    CoreState core;
    MockCoreWriter writer;
    MockTransmitter transmitter;
    MockTokenMessenger messenger;
    MockERC20 usdc;
    MockOwner owner;

    address recovery = makeAddr("recovery");
    address key = makeAddr("group0-key");
    address stranger = makeAddr("stranger");
    uint256 walletPk;
    address wallet;
    address withdrawalTo = makeAddr("withdrawal-address");

    VaultRegistry registry; // the same address on both chains
    CombinationFactory factory; // the same address on both chains: switch the transmitter's domain to play either
    LongVaultExit longExit;
    LongVault longCode;
    ShortVaultExit shortExit;
    ShortVault shortCode;
    StrategyHub hubCode;
    StrategyHubFee hubFee;
    /// Amendment 2b: every hub chain's ETH / USD (8 decimals) and sequencer feed in the unit world.
    MockAggregator ethFeed;
    MockAggregator seqFeed;
    uint80 ethRound; // the latest round's id
    uint32 constant ETH_MAX_AGE = 1 hours;

    // ShortVault.exitStatus(): states and flags
    uint8 constant NOT_IN_EXIT = 0;
    uint8 constant CLOSING = 1;
    uint8 constant RECOVERED = 2;
    uint8 constant RECOVERED_WITH_RESIDUE = 3;
    uint256 constant F_PARTNER_PENDING = 1;
    uint256 constant F_NEEDS_HYPE = 2;
    uint256 constant F_BUDGET = 4;
    uint256 constant F_WAITING_OWNER = 8;
    uint256 constant F_MARGIN_HELD = 16;
    uint256 constant F_OWNER_UNSYNCED = 32;

    function _world() internal {
        vm.etch(CORE_WRITER, type(MockCoreWriter).runtimeCode);
        vm.etch(STATE, type(CoreState).runtimeCode);
        for (uint160 a = 0x800; a <= 0x810; ++a) {
            vm.etch(address(a), type(PrecompileStub).runtimeCode);
        }
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(CDW, type(MockCoreDepositWallet).runtimeCode);
        vm.etch(TOKEN_MESSENGER, type(MockTokenMessenger).runtimeCode);
        vm.etch(TRANSMITTER, type(MockTransmitter).runtimeCode);
        core = CoreState(STATE);
        writer = MockCoreWriter(CORE_WRITER);
        transmitter = MockTransmitter(TRANSMITTER);
        messenger = MockTokenMessenger(TOKEN_MESSENGER);
        usdc = MockERC20(USDC);
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);

        (wallet, walletPk) = makeAddrAndKey("owner-wallet");
        owner = new MockOwner();
        owner.setWallet(wallet, true);
        owner.setWithdrawalAddress(withdrawalTo);

        vm.chainId(999); // HyperEVM: the hub's USDC table names the etched USDC
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        registry = new VaultRegistry(recovery);
        vm.prank(recovery);
        registry.setExecutionKey(0, key);
        longExit = new LongVaultExit();
        longCode = new LongVault(address(longExit), address(longExit).codehash);
        shortExit = new ShortVaultExit();
        shortCode = new ShortVault(address(shortExit), address(shortExit).codehash);
        hubFee = new StrategyHubFee();
        hubCode = new StrategyHub(address(hubFee), address(hubFee).codehash);
        ethFeed = new MockAggregator(8);
        seqFeed = new MockAggregator(0);
        seqFeed.setStatus(seqFeed.id(1, 1), 0, block.timestamp - 30 days); // up for a month
        _ethPrice(2_500e8);
        factory = _factoryWith(_hubDomains(), _pins()); // on HyperEVM: checks the Hyperliquid pin

        core.setOracle(ETH, 243_140, 4); // 2,431.40
        core.setOracle(HYPE_PERP, 802_635, 2); // 80.2635
    }

    /// Today's combination: the hub and the AAVE leg on Arbitrum, the Hyperliquid leg on HyperEVM.
    function _pins() internal view returns (CombinationFactory.LegPin[] memory p) {
        p = new CombinationFactory.LegPin[](2);
        p[0] = CombinationFactory.LegPin(address(longCode), address(longCode).codehash, ARB_DOMAIN, Legs.LONG, Legs.VALUE_READ, ParamsTypes.AAVE_V3_NAME, ParamsTypes.AAVE_V3_FIELDS, ParamsTypes.AAVE_V3_COUNT);
        p[1] = CombinationFactory.LegPin(address(shortCode), address(shortCode).codehash, HYPEREVM_DOMAIN, Legs.SHORT, Legs.VALUE_READ, ParamsTypes.HYPERCORE_NAME, ParamsTypes.HYPERCORE_FIELDS, ParamsTypes.HYPERCORE_COUNT);
    }

    function _hubDomains() internal pure returns (uint32[] memory d) {
        d = new uint32[](1);
        d[0] = ARB_DOMAIN;
    }

    function _factoryWith(uint32[] memory hubDomains, CombinationFactory.LegPin[] memory pins)
        internal
        returns (CombinationFactory)
    {
        return new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, hubDomains, pins, _prices(hubDomains), _sequencers(hubDomains)
        );
    }

    /// ETH at the unit world's feed on every hub chain.
    function _prices(uint32[] memory hubDomains) internal view returns (PriceSourcePin[] memory p) {
        p = new PriceSourcePin[](hubDomains.length);
        for (uint256 i; i < hubDomains.length; ++i) {
            p[i] = PriceSourcePin(hubDomains[i], Assets.ETH, PriceSource.KIND_FEED, address(ethFeed), address(0), ETH_MAX_AGE);
        }
    }

    function _sequencers(uint32[] memory hubDomains) internal view returns (SequencerPin[] memory s) {
        s = new SequencerPin[](hubDomains.length);
        for (uint256 i; i < hubDomains.length; ++i) {
            s[i] = SequencerPin(hubDomains[i], address(seqFeed));
        }
    }

    function _noPrices() internal pure returns (PriceSourcePin[] memory) {}

    function _noSequencers() internal pure returns (SequencerPin[] memory) {}

    /// A new ETH / USD round at `price` (8 decimals), updated now; returns its id.
    function _ethPrice(int256 price) internal returns (uint80 r) {
        r = ethFeed.id(1, uint64(uint80(ethRound)) + 1);
        ethFeed.push(r, price, vm.getBlockTimestamp());
        ethRound = r;
    }

    function _hubParams() internal pure returns (HubParams memory) {
        return HubParams({fastFeeCapBp: 5, feeBudgetBp: 50, feeRateBp: 1500});
    }

    function _longParams() internal pure returns (LongParams memory) {
        return LongParams({
            pool: Arbitrum.POOL,
            oracle: Arbitrum.ORACLE,
            weth: Arbitrum.WETH,
            usdc: Arbitrum.USDC,
            swapPool: Arbitrum.SWAP_POOL,
            receiver: Arbitrum.RECEIVER,
            healthFloor: 1.15e18,
            oracleBoundBp: 100,
            dailyLossBp: 50,
            fastFeeCapBp: 5
        });
    }

    function _shortParams() internal pure returns (ShortParams memory) {
        return ShortParams({perp: ETH, asset: Assets.ETH, orderBoundBp: 100, fastFeeCapBp: 5, feeBudgetBp: 50});
    }

    function _config() internal view returns (StrategyConfig memory) {
        return _configWith(_longParams(), _shortParams());
    }

    function _configWith(LongParams memory lp, ShortParams memory sp) internal view returns (StrategyConfig memory c) {
        c.factory = address(factory);
        c.group = 0;
        c.hubDomain = ARB_DOMAIN;
        c.hubParams = abi.encode(_hubParams());
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(address(longCode), ARB_DOMAIN, Legs.LONG, abi.encode(lp));
        c.legs[1] = LegConfig(address(shortCode), HYPEREVM_DOMAIN, Legs.SHORT, abi.encode(sp));
    }

    /// Creates the configuration's members on the chain the transmitter plays; returns the first made (on
    /// Arbitrum: the hub; on HyperEVM: the Hyperliquid leg).
    function _create(StrategyConfig memory c) internal returns (address) {
        uint256 deadline = block.timestamp + 1 days;
        return factory.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline))[0];
    }

    /// Every member's address (index order: the hub, the AAVE leg, the Hyperliquid leg).
    function _legs(StrategyConfig memory c) internal view returns (address[] memory at) {
        (at,) = factory.memberAddresses(STRATEGY, address(owner), c);
    }

    /// Circle relays `from`'s finalized READY (sent from `fromDomain`) to `leg`.
    function _deliverReady(address leg, uint32 fromDomain, address from) internal {
        transmitter.deliver(leg, fromDomain, bytes32(uint256(uint160(from))), abi.encode(keccak256("dltx.strategy-vault.ready.v1")));
    }

    // ── signatures in the owner's domain (slice 1a's wallet format: 0x01 ‖ r ‖ s ‖ v) ──────────────

    function _sign(uint256 pk, address ownerAddr, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", MockOwner(ownerAddr).domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    /// The owner's `CreateVault` over `c`, as its factory computes the digest (amendment 2d §4.2; checked
    /// against an independent encoding in `CombinationFactoryTest` and viem's in `OwnerDigestsTest`). A
    /// configuration its factory can't hash (no factory there, a wrong length) gets a signature over
    /// nothing: the creation is refused before or at the signature.
    function _createSig(uint256 pk, bytes32 strategyId, StrategyConfig memory c, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256("unsignable");
        if (c.factory.code.length > 0) {
            try CombinationFactory(c.factory).createDigest(strategyId, address(owner), c, deadline) returns (bytes32 d) {
                digest = d;
            } catch {}
        }
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    function _beginExitSig(bytes32 strategyId, uint256 deadline) internal view returns (bytes memory) {
        return _sign(walletPk, address(owner), keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, strategyId, deadline)));
    }

    function _actionSig(address vault, uint8 action, address agent, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            walletPk,
            address(owner),
            keccak256(
                abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, vault, block.chainid, action, agent, nonce, deadline)
            )
        );
    }

    // ── CoreWriter's log ─────────────────────────────────────────────────────────────────────────────

    function _core(uint24 id, bytes memory fields) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), id, fields);
    }

    function _order(uint32 asset, bool isBuy, uint64 px, uint64 sz, bool reduceOnly) internal pure returns (bytes memory) {
        return _core(1, abi.encode(asset, isBuy, px, sz, reduceOnly, uint8(3), uint128(0)));
    }

    function _sendAsset(address to, uint32 src, uint32 dst, uint64 token, uint64 amount)
        internal
        pure
        returns (bytes memory)
    {
        return _core(13, abi.encode(to, address(0), src, dst, token, amount));
    }

    function _agentBytes(address agent) internal pure returns (bytes memory) {
        return _core(9, abi.encode(agent, "dltx"));
    }

    /// The actions logged from `from` on, as bytes.
    function _since(uint256 from) internal view returns (bytes[] memory out) {
        uint256 n = writer.count();
        out = new bytes[](n - from);
        for (uint256 i = from; i < n; ++i) {
            out[i - from] = writer.action(i).data;
        }
    }

    function _has(bytes[] memory actions, bytes memory want) internal pure returns (bool) {
        for (uint256 i; i < actions.length; ++i) {
            if (keccak256(actions[i]) == keccak256(want)) return true;
        }
        return false;
    }

    /// How many logged actions carry action id `id`.
    function _countId(bytes[] memory actions, uint24 id) internal pure returns (uint256 n) {
        for (uint256 i; i < actions.length; ++i) {
            bytes memory a = actions[i];
            if (a.length >= 4 && uint24(uint8(a[1])) << 16 | uint24(uint8(a[2])) << 8 | uint24(uint8(a[3])) == id) n++;
        }
    }
}
