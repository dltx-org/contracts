// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Fixture} from "./utils/Fixture.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {LongVault} from "../src/LongVault.sol";
import {LongVaultState} from "../src/LongVaultState.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {StrategyHubState} from "../src/StrategyHubState.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {Assets, HubParams, LegConfig, Legs, LongParams, ParamsTypes, ShortParams, StrategyConfig, VaultConfig} from "../src/lib/VaultTypes.sol";
import {MockOwner} from "./mocks/Mocks.sol";
import {PriceSourcePin, SequencerPin} from "../src/lib/PriceSource.sol";

/// The combination factory (amendment 2a, revision 1, §3.3): its pins — the hub code and its chains, each
/// leg's code, chain and role — checked per chain at construction, every chain a deposit chain; creation
/// only for a configuration on its pins that the owner signed, every local member at once, member `i` at
/// the salt of decision 26 with its index (0 the hub); every link computed; funding for the hub only.
contract CombinationFactoryTest is Fixture {
    function setUp() public {
        _world();
    }

    function _pin(address code, uint32 domain, uint8 role) internal view returns (CombinationFactory.LegPin memory) {
        return code == address(shortCode)
            ? CombinationFactory.LegPin(code, code.codehash, domain, role, Legs.VALUE_READ, ParamsTypes.HYPERCORE_NAME, ParamsTypes.HYPERCORE_FIELDS, ParamsTypes.HYPERCORE_COUNT)
            : CombinationFactory.LegPin(code, code.codehash, domain, role, Legs.VALUE_READ, ParamsTypes.AAVE_V3_NAME, ParamsTypes.AAVE_V3_FIELDS, ParamsTypes.AAVE_V3_COUNT);
    }

    function _domains(uint32 a) internal pure returns (uint32[] memory d) {
        d = new uint32[](1);
        d[0] = a;
    }

    // ── construction ─────────────────────────────────────────────────────────────────────────────────

    function test_pins_kept_inOrder() public view {
        assertEq(factory.legCount(), 2);
        assertEq(factory.leg(0).code, address(longCode));
        assertEq(factory.leg(0).domain, ARB_DOMAIN);
        assertEq(factory.leg(1).code, address(shortCode));
        assertEq(factory.leg(1).codeHash, address(shortCode).codehash);
        assertEq(factory.hubCode(), address(hubCode));
        assertEq(factory.hubCodeHash(), address(hubCode).codehash);
        assertEq(factory.hubDomains().length, 1);
        assertEq(factory.hubDomains()[0], ARB_DOMAIN);
        assertEq(factory.registry(), address(registry));
    }

    function test_pins_refused() public {
        CombinationFactory.LegPin[] memory p = _pins();
        // a single leg, or five
        CombinationFactory.LegPin[] memory one = new CombinationFactory.LegPin[](1);
        one[0] = p[0];
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), one);
        CombinationFactory.LegPin[] memory five = new CombinationFactory.LegPin[](5);
        for (uint256 i; i < 5; ++i) five[i] = p[1];
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), five);
        // no hub chain; a hub chain twice; a hub chain without the owner's deposit contract (Avalanche 1)
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(new uint32[](0), p);
        uint32[] memory twice = new uint32[](2);
        (twice[0], twice[1]) = (ARB_DOMAIN, ARB_DOMAIN);
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(twice, p);
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_domains(1), p);
        // a leg on a chain without the owner's deposit contract
        p = _pins();
        p[0].domain = 1;
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // this chain's leg code under another hash
        p = _pins();
        p[1].codeHash = keccak256("other");
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // a role the code doesn't declare: the AAVE code is LONG only (pinned here on HyperEVM)
        p = _pins();
        p[1] = _pin(address(longCode), HYPEREVM_DOMAIN, Legs.SHORT);
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // no role, no code
        p = _pins();
        p[1].role = 0;
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        p = _pins();
        p[0].code = address(0);
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // the hub code under another hash, on a hub chain that is this one
        vm.expectRevert(CombinationFactory.BadPins.selector);
        new CombinationFactory(address(registry), address(hubCode), keccak256("other"), ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _domains(HYPEREVM_DOMAIN), _pins(), _noPrices(), _noSequencers());
        // no hub hash, no registry, no hub code
        vm.expectRevert(CombinationFactory.BadPins.selector);
        new CombinationFactory(address(registry), address(hubCode), bytes32(0), ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _hubDomains(), _pins(), _noPrices(), _noSequencers());
        vm.expectRevert(CombinationFactory.ZeroAddress.selector);
        new CombinationFactory(address(0), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _hubDomains(), _pins(), _noPrices(), _noSequencers());
        vm.expectRevert(CombinationFactory.ZeroAddress.selector);
        new CombinationFactory(address(registry), address(0), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _hubDomains(), _pins(), _noPrices(), _noSequencers());
    }

    /// Another chain's codes are that chain's copy to check: here they are data.
    function test_pins_ofAnotherChain_notCheckedHere() public {
        CombinationFactory.LegPin[] memory p = _pins();
        p[0].codeHash = keccak256("whatever Arbitrum holds");
        new CombinationFactory(address(registry), address(hubCode), keccak256("the hub on Arbitrum"), ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _hubDomains(), p, _noPrices(), _sequencers(_hubDomains()));
    }

    // ── creation ─────────────────────────────────────────────────────────────────────────────────────

    function test_create_eachChainItsMembers_aMesh_fundingAtTheHubOnly() public {
        StrategyConfig memory c = _config();
        address[] memory at = _legs(c);
        assertEq(at.length, 3);
        // HyperEVM: the Hyperliquid leg alone
        address hl = _create(c);
        assertEq(hl, at[2]);
        assertEq(VaultBase(hl).linkCount(), 2);
        assertEq(VaultBase(hl).links(0), at[0], "a leg's link 0 is its hub");
        assertEq(VaultBase(hl).links(1), at[1], "then its sister leg");
        assertEq(VaultBase(hl).linkDomains(0), ARB_DOMAIN);
        assertEq(VaultBase(hl).linkDomains(1), ARB_DOMAIN);
        assertEq(VaultBase(hl).localLinks(), 0);
        (address o, bytes32 id, bytes32 h, uint8 index) = factory.memberOf(hl);
        assertEq(o, address(owner));
        assertEq(id, STRATEGY);
        assertEq(h, VaultConfig.hash(c));
        assertEq(index, 2);
        (o, id, h) = factory.authorisedFor(hl);
        assertEq(o, address(0), "a leg is never funded by a deposit account");
        assertEq(h, bytes32(0));
        // Arbitrum: the hub and the AAVE leg, in one transaction, the hub first
        transmitter.setLocalDomain(ARB_DOMAIN);
        uint256 deadline = block.timestamp + 1 days;
        address[] memory made =
            factory.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline));
        assertEq(made.length, 2);
        assertEq(made[0], at[0]);
        assertEq(made[1], at[1]);
        StrategyHub hub = StrategyHub(made[0]);
        assertEq(hub.linkCount(), 2);
        assertEq(hub.links(0), at[1]);
        assertEq(hub.links(1), at[2]);
        assertEq(hub.linkDomains(1), HYPEREVM_DOMAIN);
        assertEq(hub.localLinks(), 1, "the AAVE leg shares the hub's chain");
        assertEq(hub.fastFeeCapBp(), 5);
        assertEq(hub.feeBudgetBp(), 50);
        assertEq(VaultBase(made[1]).links(0), at[0]);
        assertEq(VaultBase(made[1]).links(1), at[2]);
        assertEq(VaultBase(made[1]).localLinks(), 1);
        (o, id, h) = factory.authorisedFor(address(hub));
        assertEq(o, address(owner));
        assertEq(id, STRATEGY);
        assertEq(h, VaultConfig.hash(c));
        (o,,) = factory.authorisedFor(made[1]);
        assertEq(o, address(0));
        (o,,) = factory.authorisedFor(stranger);
        assertEq(o, address(0));
        (,,, index) = factory.memberOf(made[1]);
        assertEq(index, 1);
        assertEq(LongVault(payable(made[1])).healthFloor(), 1.15e18);
        assertEq(ShortVault(payable(hl)).perp(), ETH);
    }

    /// Decision 26 with the member index: another owner, or another configuration, lands elsewhere, and
    /// the real leg's link doesn't name it.
    function test_create_anotherOwnerOrConfig_landsElsewhere() public {
        StrategyConfig memory c = _config();
        address hl = _create(c);
        address hub = VaultBase(hl).links(0);
        transmitter.setLocalDomain(ARB_DOMAIN);
        (address w2, uint256 pk2) = makeAddrAndKey("other-user");
        MockOwner owner2 = new MockOwner();
        owner2.setWallet(w2, true);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk2, factory.createDigest(STRATEGY, address(owner2), c, deadline));
        bytes memory sig2 = abi.encodePacked(uint8(1), r, s, v);
        address intruder = factory.create(STRATEGY, address(owner2), c, deadline, sig2)[0];
        assertTrue(intruder != hub);
        LongParams memory lp = _longParams();
        lp.healthFloor = 1.2e18;
        address other = _create(_configWith(lp, _shortParams()));
        assertTrue(other != hub);
        assertEq(VaultBase(hl).links(0), hub);
    }

    function _expect(StrategyConfig memory c, bytes4 err) internal {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _createSig(walletPk, STRATEGY, c, deadline);
        vm.expectRevert(err);
        factory.create(STRATEGY, address(owner), c, deadline, sig);
    }

    /// The pairing is the factory's: a configuration naming another factory, code, chain or role, a hub
    /// chain it doesn't allow, or another number of legs, is refused, so a member's links are always this
    /// factory's other clones.
    function test_create_refusesAConfigurationOffItsPins() public {
        StrategyConfig memory c = _config();
        c.factory = stranger;
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        c.legs[0].code = address(shortCode);
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        c.legs[1].domain = 6; // Base
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        c.legs[1].role = Legs.LONG;
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        c.hubDomain = HYPEREVM_DOMAIN; // a deposit chain, not one of this factory's hub chains
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        c.group = 16; // the registry's GROUPS
        _expect(c, CombinationFactory.BadConfig.selector);
        StrategyConfig memory one = _config();
        LegConfig memory first = one.legs[0];
        one.legs = new LegConfig[](1);
        one.legs[0] = first;
        _expect(one, CombinationFactory.BadConfig.selector);
        // the last group is fine
        c = _config();
        c.group = 15;
        vm.prank(recovery);
        registry.setExecutionKey(15, key);
        _create(c);
    }

    /// Each member's code checks its own parameters (`validateParams`), on the chain it lives on.
    function test_create_paramsCheckedByTheirCode() public {
        ShortParams memory sp = _shortParams();
        sp.perp = 10_107; // a spot asset
        _expect(_configWith(_longParams(), sp), ShortVault.BadParams.selector);
        sp = _shortParams();
        sp.orderBoundBp = 29; // under the 30 bp floor
        _expect(_configWith(_longParams(), sp), ShortVault.BadParams.selector);
        sp = _shortParams();
        sp.fastFeeCapBp = 51;
        _expect(_configWith(_longParams(), sp), ShortVault.BadParams.selector);
        sp = _shortParams();
        sp.asset = bytes32(0);
        _expect(_configWith(_longParams(), sp), ShortVault.BadParams.selector);
        sp = _shortParams();
        sp.asset = Assets.USD; // amendment 2b: the perp's size would be valued at $1 a unit
        _expect(_configWith(_longParams(), sp), ShortVault.BadParams.selector);
        sp = _shortParams();
        sp.feeBudgetBp = 0;
        _expect(_configWith(_longParams(), sp), ShortVault.BadParams.selector);
        sp = _shortParams();
        sp.feeBudgetBp = 501;
        _expect(_configWith(_longParams(), sp), ShortVault.BadParams.selector);
        // on Arbitrum: the AAVE leg's and the hub's
        transmitter.setLocalDomain(ARB_DOMAIN);
        LongParams memory lp = _longParams();
        lp.receiver = stranger;
        _expect(_configWith(lp, _shortParams()), LongVaultState.BadParams.selector);
        lp = _longParams();
        lp.pool = stranger;
        _expect(_configWith(lp, _shortParams()), LongVaultState.BadParams.selector);
        lp = _longParams();
        lp.healthFloor = 1e18;
        _expect(_configWith(lp, _shortParams()), LongVaultState.BadParams.selector);
        lp = _longParams();
        lp.dailyLossBp = 501;
        _expect(_configWith(lp, _shortParams()), LongVaultState.BadParams.selector);
        StrategyConfig memory c = _config();
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 51, feeBudgetBp: 50, feeRateBp: 1500}));
        _expect(c, StrategyHubState.BadParams.selector);
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 5, feeBudgetBp: 0, feeRateBp: 1500}));
        _expect(c, StrategyHubState.BadParams.selector);
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 5, feeBudgetBp: 501, feeRateBp: 1500}));
        _expect(c, StrategyHubState.BadParams.selector);
        // garbage instead of parameters
        c = _config();
        c.hubParams = hex"01";
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _createSig(walletPk, STRATEGY, c, deadline);
        vm.expectRevert(); // abi.decode's own revert
        factory.create(STRATEGY, address(owner), c, deadline, sig);
    }

    function test_create_refusals() public {
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _createSig(walletPk, STRATEGY, c, deadline);
        (, uint256 otherPk) = makeAddrAndKey("not-owner");
        bytes memory bad = _createSig(otherPk, STRATEGY, c, deadline);
        vm.expectRevert(CombinationFactory.BadSignature.selector);
        factory.create(STRATEGY, address(owner), c, deadline, bad);
        // signed for another strategy id
        vm.expectRevert(CombinationFactory.BadSignature.selector);
        factory.create(bytes32(uint256(7)), address(owner), c, deadline, sig);
        // an owner with no code
        vm.expectRevert(CombinationFactory.BadSignature.selector);
        factory.create(STRATEGY, wallet, c, deadline, sig);
        // an unsynced copy accepts no signature
        owner.setSynced(false);
        vm.expectRevert(CombinationFactory.BadSignature.selector);
        factory.create(STRATEGY, address(owner), c, deadline, sig);
        owner.setSynced(true);
        vm.warp(deadline + 1);
        vm.expectRevert(CombinationFactory.Expired.selector);
        factory.create(STRATEGY, address(owner), c, deadline, sig);
    }

    function test_create_wrongChain() public {
        transmitter.setLocalDomain(6); // Base: none of its members
        _expect(_config(), CombinationFactory.WrongChain.selector);
    }

    function test_create_once() public {
        StrategyConfig memory c = _config();
        _create(c);
        _expect(c, CombinationFactory.DeployFailed.selector);
        transmitter.setLocalDomain(ARB_DOMAIN);
        _create(c);
        _expect(c, CombinationFactory.DeployFailed.selector);
    }

    /// A member code is never a member: its own storage holds the factory sentinel.
    function test_codes_neverInitializable() public {
        vm.expectRevert(VaultState.AlreadyInitialized.selector);
        longCode.initialize(stranger, stranger, new address[](1), new uint32[](1), 0, bytes32(0), bytes32(0), "");
        vm.expectRevert(VaultState.AlreadyInitialized.selector);
        hubCode.initialize(stranger, stranger, new address[](1), new uint32[](1), 0, bytes32(0), bytes32(0), "");
    }

    // ── amendment 2b §3.8: the fee's pins ────────────────────────────────────────────────────────────

    function _withPrices(PriceSourcePin[] memory prices, SequencerPin[] memory seqs) internal returns (CombinationFactory) {
        return new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _hubDomains(), _pins(), prices, seqs
        );
    }

    function _one(PriceSourcePin memory p) internal pure returns (PriceSourcePin[] memory a) {
        a = new PriceSourcePin[](1);
        a[0] = p;
    }

    function _eth() internal view returns (PriceSourcePin memory) {
        return PriceSourcePin(ARB_DOMAIN, Assets.ETH, 1, address(ethFeed), address(0), 1 hours);
    }

    function _expectBadPins(PriceSourcePin[] memory prices, SequencerPin[] memory seqs) internal {
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _withPrices(prices, seqs);
    }

    function test_feePins_kept_andHubSetupServesThisChainsOnly() public {
        (PriceSourcePin[] memory prices, SequencerPin[] memory seqs) = factory.pricePins();
        assertEq(prices.length, 1);
        assertEq(prices[0].hubDomain, ARB_DOMAIN);
        assertEq(seqs.length, 1);
        // on HyperEVM (the fixture's chain) no hub chain's pins
        (PriceSourcePin[] memory here, address seq, uint8[] memory kinds) = factory.hubSetup();
        assertEq(here.length, 0);
        assertEq(seq, address(0));
        assertEq(kinds.length, 2);
        assertEq(kinds[1], Legs.VALUE_READ);
        transmitter.setLocalDomain(ARB_DOMAIN);
        (here, seq,) = factory.hubSetup();
        assertEq(here.length, 1);
        assertEq(here[0].feed, address(ethFeed));
        assertEq(seq, address(seqFeed));
    }

    function test_feePins_refused() public {
        SequencerPin[] memory none = _noSequencers();
        PriceSourcePin memory p = _eth();
        p.hubDomain = HYPEREVM_DOMAIN; // not a hub chain of this factory
        _expectBadPins(_one(p), none);
        p = _eth();
        p.asset = Assets.USD; // USD is at face
        _expectBadPins(_one(p), none);
        p = _eth();
        p.asset = bytes32(0);
        _expectBadPins(_one(p), none);
        p = _eth();
        p.feed = address(0);
        _expectBadPins(_one(p), none);
        p = _eth();
        p.maxAge = 0;
        _expectBadPins(_one(p), none);
        p = _eth();
        p.kind = 3;
        _expectBadPins(_one(p), none);
        p = _eth();
        p.baseFeed = address(ethFeed); // kind 1 with a base
        _expectBadPins(_one(p), none);
        p = _eth();
        p.kind = 2; // a composite without its base
        _expectBadPins(_one(p), none);
        // the same asset twice on one chain; more than eight on one chain
        PriceSourcePin[] memory two = new PriceSourcePin[](2);
        (two[0], two[1]) = (_eth(), _eth());
        _expectBadPins(two, none);
        PriceSourcePin[] memory nine = new PriceSourcePin[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = _eth();
            nine[i].asset = bytes32(i + 1);
        }
        _expectBadPins(nine, none);
        // a feed without code, on the chain it is read on
        transmitter.setLocalDomain(ARB_DOMAIN);
        p = _eth();
        p.feed = makeAddr("no-code");
        CombinationFactory.LegPin[] memory pins = _pins();
        vm.expectRevert(CombinationFactory.BadPins.selector);
        new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _hubDomains(), pins, _one(p), none
        );
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);
        // sequencers: zero, twice on a chain, off the hub chains
        SequencerPin[] memory s = new SequencerPin[](1);
        s[0] = SequencerPin(ARB_DOMAIN, address(0));
        _expectBadPins(_noPrices(), s);
        s[0] = SequencerPin(HYPEREVM_DOMAIN, address(seqFeed));
        _expectBadPins(_noPrices(), s);
        SequencerPin[] memory s2 = new SequencerPin[](2);
        (s2[0], s2[1]) = (SequencerPin(ARB_DOMAIN, address(seqFeed)), SequencerPin(ARB_DOMAIN, address(seqFeed)));
        _expectBadPins(_noPrices(), s2);
        // accepted: the composite kind
        p = _eth();
        (p.kind, p.asset, p.baseFeed) = (2, keccak256("dltx.asset.WSTETH"), address(ethFeed));
        _withPrices(_one(p), none);
    }

    /// Each leg pin's `valueKind`, checked against the leg code on its own chain (amendment 2b).
    function test_legPin_valueKind_checkedHere() public {
        CombinationFactory.LegPin[] memory p = _pins();
        p[1].valueKind = Legs.VALUE_REPORTED; // the Hyperliquid leg's code here says VALUE_READ
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        p = _pins();
        p[0].valueKind = 0;
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        p = _pins();
        p[0].valueKind = Legs.VALUE_REPORTED; // the AAVE leg's code is on Arbitrum: checked there
        _factoryWith(_hubDomains(), p);
    }

    // ── amendment 2d §4.2: the typed CreateVault ─────────────────────────────────────────────────────

    function _withHubType(string memory name, string memory fields, uint8 count, uint32[] memory hubs)
        internal
        returns (CombinationFactory)
    {
        return new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, name, fields, count, hubs, _pins(), _prices(hubs), _sequencers(hubs)
        );
    }

    /// `params` are exactly the pinned field count in words: a trailing word (which `abi.decode` tolerates
    /// and `configHash` would carry) or one word short is refused, on a local member and a remote one.
    function test_create_paramsOfTheirFieldCountOnly() public {
        StrategyConfig memory c = _config();
        c.legs[1].params = bytes.concat(c.legs[1].params, bytes32(uint256(1))); // the Hyperliquid leg, here
        shortCode.validateParams(c.legs[1].params); // its own check lets it through
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        c.legs[0].params = bytes.concat(c.legs[0].params, bytes32(0)); // the AAVE leg, on Arbitrum
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        bytes memory p = c.legs[0].params;
        assembly ("memory-safe") {
            mstore(p, sub(mload(p), 32))
        }
        _expect(c, CombinationFactory.BadConfig.selector);
        c = _config();
        c.hubParams = bytes.concat(c.hubParams, bytes32(0));
        vm.expectRevert(CombinationFactory.BadConfig.selector);
        factory.createDigest(STRATEGY, address(owner), c, 1);
        // the configuration as signed is created
        _create(_config());
    }

    /// A signature over any other value of any field, or another deadline, is refused.
    function test_create_digestBindsEveryField() public {
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 d = factory.createDigest(STRATEGY, address(owner), c, deadline);
        StrategyConfig memory o = _config();
        o.group = 1;
        assertTrue(factory.createDigest(STRATEGY, address(owner), o, deadline) != d, "group");
        o = _config();
        o.hubDomain = HYPEREVM_DOMAIN;
        assertTrue(factory.createDigest(STRATEGY, address(owner), o, deadline) != d, "hubDomain");
        o = _config();
        o.factory = stranger;
        assertTrue(factory.createDigest(STRATEGY, address(owner), o, deadline) != d, "factory");
        LongParams memory lp = _longParams();
        lp.oracleBoundBp = 101;
        assertTrue(factory.createDigest(STRATEGY, address(owner), _configWith(lp, _shortParams()), deadline) != d);
        ShortParams memory sp = _shortParams();
        sp.orderBoundBp = 101;
        assertTrue(factory.createDigest(STRATEGY, address(owner), _configWith(_longParams(), sp), deadline) != d);
        assertTrue(factory.createDigest(keccak256("other"), address(owner), c, deadline) != d, "strategy");
        assertTrue(factory.createDigest(STRATEGY, stranger, c, deadline) != d, "owner");
        assertTrue(factory.createDigest(STRATEGY, address(owner), c, deadline + 1) != d, "deadline");
        // a signature over the deadline + 1 refused at this deadline
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(walletPk, factory.createDigest(STRATEGY, address(owner), c, deadline + 1));
        vm.expectRevert(CombinationFactory.BadSignature.selector);
        factory.create(STRATEGY, address(owner), c, deadline, abi.encodePacked(uint8(1), r, s2, v));
    }

    /// The constructor checks each local code's own declaration against its pin, and every pin's shape.
    function test_pins_typesRefused() public {
        CombinationFactory.LegPin[] memory p = _pins();
        // the Hyperliquid code here, its fields not its own
        p[1].typeFields = "uint32 perp,bytes32 asset,uint16 orderBoundBp,uint16 fastFeeCapBp,uint16 feeBudget";
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        p = _pins();
        p[1].typeName = "HyperCoreShort";
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // a count other than its fields', even where the code isn't checked (the AAVE leg is on Arbitrum)
        p = _pins();
        p[0].fieldCount = 9;
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        p = _pins();
        p[1].fieldCount = 6;
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // no name, no fields, CreateVault's own name
        p = _pins();
        p[0].typeName = "";
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        p = _pins();
        p[0].typeFields = "";
        p[0].fieldCount = 0;
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        p = _pins();
        p[0].typeName = "CreateVault";
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // one name for two field lists (the AAVE pin named as the Hyperliquid type)
        p = _pins();
        p[0].typeName = ParamsTypes.HYPERCORE_NAME;
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _factoryWith(_hubDomains(), p);
        // the hub's: checked against the hub code where the hub may live (Arbitrum here)
        transmitter.setLocalDomain(ARB_DOMAIN);
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _withHubType("StrategyHub", "uint16 fastFeeCapBp,uint16 feeBudgetBp,uint16 feeRate", 3, _hubDomains());
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _withHubType(ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, 2, _hubDomains());
        _withHubType(ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, _hubDomains());
        // on HyperEVM the hub code isn't checked; its count still is
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);
        _withHubType("Hub", "uint16 a,uint16 b,uint16 c", 3, _hubDomains());
        vm.expectRevert(CombinationFactory.BadPins.selector);
        _withHubType("Hub", "uint16 a,uint16 b,uint16 c", 4, _hubDomains());
    }

    /// A member type used twice appears once among the referenced types, which are sorted by name.
    function test_createVaultType_oneTypeOnce_sortedByName() public {
        CombinationFactory.LegPin[] memory p = new CombinationFactory.LegPin[](2);
        p[0] = _pin(address(shortCode), HYPEREVM_DOMAIN, Legs.LONG);
        p[1] = _pin(address(shortCode), HYPEREVM_DOMAIN, Legs.SHORT);
        CombinationFactory f = _factoryWith(_hubDomains(), p);
        assertEq(
            f.createVaultType(),
            string.concat(
                "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,StrategyHub hub,HyperCoreLeg leg1,HyperCoreLeg leg2,uint256 deadline)",
                ParamsTypes.HYPERCORE,
                ParamsTypes.HUB
            )
        );
        // today's: AaveV3Leg < HyperCoreLeg < StrategyHub
        assertEq(
            factory.createVaultType(),
            string.concat(
                "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,StrategyHub hub,AaveV3Leg leg1,HyperCoreLeg leg2,uint256 deadline)",
                ParamsTypes.AAVE_V3,
                ParamsTypes.HYPERCORE,
                ParamsTypes.HUB
            )
        );
        assertEq(factory.createVaultTypehash(), keccak256(bytes(factory.createVaultType())));
    }

    /// Each member code declares its own type, and the constants agree with their name and fields.
    function test_paramsType_eachCodeItsOwn() public view {
        assertEq(longCode.paramsType(), ParamsTypes.AAVE_V3);
        assertEq(shortCode.paramsType(), ParamsTypes.HYPERCORE);
        assertEq(hubCode.paramsType(), ParamsTypes.HUB);
        assertEq(ParamsTypes.AAVE_V3, string.concat(ParamsTypes.AAVE_V3_NAME, "(", ParamsTypes.AAVE_V3_FIELDS, ")"));
        assertEq(ParamsTypes.HYPERCORE, string.concat(ParamsTypes.HYPERCORE_NAME, "(", ParamsTypes.HYPERCORE_FIELDS, ")"));
        assertEq(ParamsTypes.HUB, string.concat(ParamsTypes.HUB_NAME, "(", ParamsTypes.HUB_FIELDS, ")"));
        // every field static, one word each: the params' encoding is the fields' count in words
        assertEq(abi.encode(_longParams()).length, uint256(ParamsTypes.AAVE_V3_COUNT) * 32);
        assertEq(abi.encode(_shortParams()).length, uint256(ParamsTypes.HYPERCORE_COUNT) * 32);
        assertEq(abi.encode(_hubParams()).length, uint256(ParamsTypes.HUB_COUNT) * 32);
    }
}
