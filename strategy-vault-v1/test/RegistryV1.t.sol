// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureV1} from "./FixtureV1.sol";
import {HubV2, MockToken} from "./MocksV1.sol";
import {MemberState} from "../src/MemberState.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {AssetProfile, AssetsV1, Manifests, MemberTypes, PricePin, Profiles, VersionMember} from "../src/Types.sol";
import {Assets} from "../src/lib/VaultTypes.sol";
import {PriceSource} from "../src/lib/PriceSource.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/*
 * The version-1 registry on Arbitrum, unit: the version list (propose, 7 days, accept in order, withdraw,
 * the listing checks), per-version check-ins and their seeding, and the profile list with AP-3's checks:
 * every field mutated is refused at acceptance (asset-profiles-design.md AP-3, §4.1, §9.2's mutation
 * test, the wrong-pair rate feed included).
 */
contract RegistryV1Test is FixtureV1 {
    function setUp() public {
        _arbitrum();
    }

    // ── versions ─────────────────────────────────────────────────────────────────────────────────────

    function test_version_listing() public view {
        assertEq(registry.latestVersion(), 1);
        assertEq(registry.versionOf(manifest1), 1);
        assertEq(registry.implementation(1, MemberTypes.HUB), address(hubImpl));
        assertEq(registry.implementation(1, MemberTypes.AAVE_V3_ASSET), address(longImpl));
        assertEq(registry.implementation(1, MemberTypes.HYPERCORE), address(0)); // not this chain's
        uint8[] memory t = registry.localTypes(1);
        assertEq(t.length, 2);
    }

    function test_version_refusals() public {
        HubV2 hub2 = new HubV2(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), address(seqFeed));
        VersionMember[] memory m = _members(address(hub2), address(longImpl), FAR_SHORT, FAR_HASH);
        // not recovery
        vm.prank(stranger);
        vm.expectRevert(StrategyRegistry.NotAllowed.selector);
        registry.proposeVersion(2, m);
        // a local implementation whose CODE_VERSION is not the number (the long is still version 1's)
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.proposeVersion(2, m);
        // a wrong code hash
        m = _members(address(hub2), address(longImpl), FAR_SHORT, FAR_HASH);
        m[1].implementation = address(hub2);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.CodeChanged.selector);
        registry.proposeVersion(2, m);
        // members out of order
        m = _members(address(hub2), address(longImpl), FAR_SHORT, FAR_HASH);
        (m[0], m[1]) = (m[1], m[0]);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.proposeVersion(2, m);
        // a version already listed, or skipping a number
        m = _members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.proposeVersion(1, m);
    }

    function test_version_delayOrderAndWithdraw() public {
        address hub2 = address(new HubV2(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), address(seqFeed)));
        // a long that answers 2 as well, so the version is well-formed on this chain
        VersionMember[] memory m = _members(hub2, hub2, FAR_SHORT, FAR_HASH);
        m[1].implementation = address(new HubV2LongShape(address(registry)));
        m[1].codeHash = m[1].implementation.codehash;
        vm.prank(recovery);
        registry.proposeVersion(2, m);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.NotDue.selector);
        registry.acceptVersion(2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        registry.withdrawVersion(2);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.acceptVersion(2);
        // proposed again, accepted, its check-ins seeded at acceptance (never stopped on arrival)
        vm.prank(recovery);
        registry.proposeVersion(2, m);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        registry.acceptVersion(2);
        assertEq(registry.versionOf(Manifests.hash(m)), 2);
        assertFalse(registry.stopped(0, 2));
        assertTrue(registry.stopped(1, 2)); // no key for group 1
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertTrue(registry.stopped(0, 2));
        uint256[] memory vs = new uint256[](1);
        vs[0] = 2;
        vm.prank(key);
        registry.checkIn(0, vs);
        assertFalse(registry.stopped(0, 2));
        assertTrue(registry.stopped(0, 1)); // each version's clock is its own
        vs[0] = 3;
        vm.prank(key);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.checkIn(0, vs);
    }

    /// Review P3-4: a version leaving out a member type the previous one had here is refused at its
    /// acceptance (a long could never resolve its implementation, and every hub's apply would revert).
    function test_version_keepsEveryLocalMemberType() public {
        address hub2 = address(new HubV2(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), address(seqFeed)));
        VersionMember[] memory m = new VersionMember[](2);
        m[0] = VersionMember(MemberTypes.HUB, ARB, hub2, hub2.codehash);
        m[1] = VersionMember(MemberTypes.HYPERCORE, HYPER, FAR_SHORT, FAR_HASH_2);
        vm.prank(recovery);
        registry.proposeVersion(2, m);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.acceptVersion(2);
    }

    function test_stopped_unacceptedVersionAndFirstKey() public {
        assertTrue(registry.stopped(0, 9));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        address k5 = makeAddr("group5-key");
        vm.prank(recovery);
        registry.setExecutionKey(5, k5);
        assertFalse(registry.stopped(5, 1)); // a group's first key starts its clock
    }

    // ── profiles ──────────────────────────────────────────────────────────────────────────────────────

    function test_profile_lifecycle() public {
        assertTrue(registry.profileOpen(btcProfile));
        assertEq(registry.profileIds().length, 1);
        assertEq(Profiles.id(registry.profileOf(btcProfile)), btcProfile);
        AssetProfile memory p = _btc();
        p.swapPool = address(wbtcPool30);
        p.swapFee = 3000;
        vm.prank(recovery);
        bytes32 id = registry.proposeProfile(p);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.AlreadyPending.selector);
        registry.proposeProfile(p);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.NotDue.selector);
        registry.acceptProfile(id);
        vm.prank(recovery);
        registry.withdrawProfile(id);
        assertEq(registry.profileState(id), 0);
        vm.prank(stranger);
        vm.expectRevert(StrategyRegistry.NotAllowed.selector);
        registry.closeProfile(btcProfile);
        vm.prank(recovery);
        registry.closeProfile(btcProfile);
        assertFalse(registry.profileOpen(btcProfile));
        assertEq(registry.profileOf(btcProfile).asset, address(wbtc)); // the data stays readable
    }

    /// Proposes `p` and expects its acceptance, 7 days later, to revert `BadProfile`.
    function _refused(AssetProfile memory p) internal {
        vm.prank(recovery);
        bytes32 id = registry.proposeProfile(p);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _feeds(_answer(btcUsd), _answer(wbtcBtc));
        vm.prank(recovery);
        vm.expectRevert(MemberState.BadProfile.selector);
        registry.acceptProfile(id);
    }

    function test_profile_eachLongFactRefused() public {
        AssetProfile memory p;
        p = _btc(); p.assetDecimals = 18; _refused(p);
        p = _btc(); p.aAsset = address(new MockToken(8)); _refused(p);
        p = _btc(); p.swapPool = address(wbtcPool30); _refused(p); // the 0.05 % tier names the other pool
        p = _btc(); p.assetIsToken0 = !p.assetIsToken0; _refused(p);
        p = _btc(); p.minBoundBp = 5; _refused(p); // not above the fee (5 bp)
        p = _btc(); p.holdingAsset = Assets.USD; _refused(p);
        p = _btc(); p.asset = ARB_USDC; _refused(p);
        p = _btc(); p.asset = 0x912CE59144191C1204E64559FE8253a0e49E6548; _refused(p); // ARB, the reward
        p = _btc(); p.shortAsset = Assets.ETH; _refused(p); // never chosen: derived from the coin
        p = _btc(); p.underlying = _word("ETH"); _refused(p);
    }

    function test_profile_reserveStateRefused() public {
        uint256 good = aave.GOOD_CONFIG();
        uint256[6] memory bad = [
            good & ~uint256(0xFFFF), // LTV 0
            good | (1 << 57), // frozen
            good | (1 << 60), // paused
            good & ~(uint256(1) << 56), // inactive
            good | (uint256(1) << 212), // a debt ceiling
            good & ~(uint256(1) << 252) // no virtual accounting
        ];
        for (uint256 i; i < bad.length; ++i) {
            aave.setConfiguration(address(wbtc), bad[i]);
            AssetProfile memory p = _btc();
            p.minBoundBp = uint16(61 + i); // a new id each time
            _refused(p);
        }
        aave.setConfiguration(address(wbtc), good);
        aave.setPrice(address(wbtc), 82_000e8, address(0)); // no oracle source
        AssetProfile memory q = _btc();
        q.minBoundBp = 70;
        _refused(q);
    }

    /// The rate feed's identity, not its liveness (Codex round 1): a USDC / USD feed answers near 1 with 8
    /// decimals and is fresh, and is refused by its description.
    function test_profile_wrongPairRateFeedRefused() public {
        MockAggregator usdcUsd = new MockAggregator(8);
        usdcUsd.setDescription("USDC / USD");
        usdcUsd.push(usdcUsd.id(1, 1), 1e8, vm.getBlockTimestamp() + 7 days);
        AssetProfile memory p = _btc();
        p.rateFeed = address(usdcUsd);
        p.pins[1].feed = address(usdcUsd);
        vm.prank(recovery);
        bytes32 id = registry.proposeProfile(p);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _feeds(_answer(btcUsd), _answer(wbtcBtc));
        vm.prank(recovery);
        vm.expectRevert(MemberState.BadProfile.selector);
        registry.acceptProfile(id);
        // and a stale rate, or a description with no feed
        p = _btc();
        p.rateMaxAge = 1; // the round is older than 1 s at acceptance
        p.minBoundBp = 61;
        _refusedStale(p);
        p = _btc();
        p.rateFeed = address(0);
        p.rateMaxAge = 0;
        _refused(p);
    }

    function _refusedStale(AssetProfile memory p) internal {
        vm.prank(recovery);
        bytes32 id = registry.proposeProfile(p);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        btcUsd.push(btcUsd.id(1, uint64(uint80(btcUsd.latest())) + 1), _answer(btcUsd), vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(recovery);
        vm.expectRevert(MemberState.BadProfile.selector);
        registry.acceptProfile(id);
    }

    function test_profile_hubPinsRefused() public {
        AssetProfile memory p;
        p = _btc(); p.pins[1].asset = Assets.ETH; _refused(p); // the holding (WBTC) unpriced
        p = _btc(); p.pins[1].baseFeed = address(0); _refused(p); // a composite without its base
        p = _btc(); p.pins[0].asset = Assets.USD; _refused(p);
        p = _btc(); p.pins[0].maxAge = 0; _refused(p);
        p = _btc(); p.pins[1] = PricePin(AssetsV1.BTC, PriceSource.KIND_FEED, address(btcUsd), address(0), 1 hours); _refused(p);
        p = _btc(); p.pins[0].feed = address(new MockAggregator(8)); _refused(p); // no answer: not fresh
    }

    /// §A9 (Codex on the integration, 2026-10-23, P2): a version naming a registry two successions on
    /// (R0 → R1 → R2) is listable in R0, so a follower made through R0 can follow its hub there; a
    /// chain longer than MAX_SUCCESSIONS, a loop, or one ending elsewhere is refused.
    function test_version_successorChain() public {
        StrategyRegistry r1 = new StrategyRegistry(recovery, address(registry), 2, new VersionMember[](0), new AssetProfile[](0));
        StrategyRegistry r2 = new StrategyRegistry(recovery, address(r1), 3, new VersionMember[](0), new AssetProfile[](0));
        VersionMember[] memory m = _shapes(address(r2), 2);
        vm.prank(recovery);
        registry.proposeVersion(2, m);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        registry.acceptVersion(2);
        assertEq(registry.implementation(2, MemberTypes.HUB), m[0].implementation);

        // MAX_SUCCESSIONS steps back to this registry: listable; one more: refused
        address at = address(registry);
        for (uint256 i; i < registry.MAX_SUCCESSIONS(); ++i) {
            at = address(new PredecessorShape(at));
        }
        m = _shapes(at, 3);
        vm.prank(recovery);
        registry.proposeVersion(3, m);
        vm.prank(recovery);
        registry.withdrawVersion(3);
        at = address(new PredecessorShape(at));
        m = _shapes(at, 3);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.proposeVersion(3, m);

        // a loop never reaching this registry, and a chain ending at another registry: refused
        PredecessorShape loop = new PredecessorShape(address(0));
        loop.set(address(loop));
        m = _shapes(address(loop), 3);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.proposeVersion(3, m);
        StrategyRegistry elsewhere = new StrategyRegistry(recovery, address(0), 1, new VersionMember[](0), new AssetProfile[](0));
        m = _shapes(address(new PredecessorShape(address(elsewhere))), 3);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        registry.proposeVersion(3, m);
    }

    /// Version `v`'s hub and long on this chain as listing shapes naming `listing`, the short far away.
    function _shapes(address listing, uint32 v) internal returns (VersionMember[] memory m) {
        address hub = address(new ListingShape(listing, v, MemberTypes.HUB));
        address long = address(new ListingShape(listing, v, MemberTypes.AAVE_V3_ASSET));
        m = _members(hub, long, FAR_SHORT, v == 2 ? FAR_HASH : FAR_HASH_2);
    }

    function test_profile_needsAListedVersion() public {
        StrategyRegistry fresh = new StrategyRegistry(recovery, address(0), 1, new VersionMember[](0), new AssetProfile[](0));
        vm.prank(recovery);
        bytes32 id = fresh.proposeProfile(_btc());
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.BadVersion.selector);
        fresh.acceptProfile(id);
    }
}

/// An implementation that only answers the listing's questions as an AAVE asset leg of version 2.
contract HubV2LongShape {
    address public immutable listingRegistry;

    constructor(address r) {
        listingRegistry = r;
    }

    function CODE_VERSION() external pure returns (uint32) {
        return 2;
    }

    function MEMBER_TYPE() external pure returns (uint8) {
        return MemberTypes.AAVE_V3_ASSET;
    }
}

/// An implementation that only answers the listing's questions, as `memberType` of `version`.
contract ListingShape {
    address public immutable listingRegistry;
    uint32 internal immutable _version;
    uint8 internal immutable _type;

    constructor(address r, uint32 v, uint8 t) {
        listingRegistry = r;
        _version = v;
        _type = t;
    }

    function CODE_VERSION() external view returns (uint32) {
        return _version;
    }

    function MEMBER_TYPE() external view returns (uint8) {
        return _type;
    }
}

/// A registry-shaped link of a predecessor chain: it answers only `predecessor()`.
contract PredecessorShape {
    address public predecessor;

    constructor(address p) {
        predecessor = p;
    }

    function set(address p) external {
        predecessor = p;
    }
}
