// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureV1} from "./FixtureV1.sol";
import {HubV2} from "./MocksV1.sol";
import {Hub} from "../src/Hub.sol";
import {HubState} from "../src/HubState.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {ProxyInitCode} from "../src/ProxyInitCode.sol";
import {AssetProfile, HubParams, Manifests, MemberTypes, ParamsTypesV1, Profiles, StrategySpec, VersionMember} from "../src/Types.sol";

/*
 * THE GENESIS (the operator's decision of 2026-10-23; owner-upgrades-design.md §A3): version 1 and its
 * asset profiles are the registry's constructor data, listed and open at once, its check-ins seeded; the
 * constructor checks the local implementations as a proposal does, but for the listing registry, which
 * version 1's implementations cannot name (they come first). Then what that costs, checked: a version-1
 * implementation is never listed by a proposal; a proxy of it made by another factory over another
 * registry reads that registry only, is no hub of the pinned factory (`authorisedFor`: the deposit
 * contract's test), and its initialisation re-validates the owner's parameters on its stored registry.
 */
contract GenesisV1Test is FixtureV1 {
    function setUp() public {
        _arbitrum();
    }

    function _genesisArgs(VersionMember[] memory m, AssetProfile[] memory p) internal view returns (bytes memory) {
        return abi.encode(recovery, address(0), uint256(1), m, p);
    }

    function _deployRegistry(VersionMember[] memory m, AssetProfile[] memory p) internal returns (StrategyRegistry) {
        return StrategyRegistry(deployCode("StrategyRegistry.sol:StrategyRegistry", _genesisArgs(m, p)));
    }

    function _deployReverts(VersionMember[] memory m, AssetProfile[] memory p, bytes4 err) internal {
        // the constructor's revert surfaces as a failed creation; read its reason through a raw CREATE
        bytes memory init = abi.encodePacked(vm.getCode("StrategyRegistry.sol:StrategyRegistry"), _genesisArgs(m, p));
        address made;
        bytes32 reason;
        assembly ("memory-safe") {
            made := create(0, add(init, 0x20), mload(init))
            if iszero(made) {
                returndatacopy(0, 0, 4)
                reason := mload(0)
            }
        }
        assertEq(made, address(0), "refused");
        assertEq(bytes4(reason), err);
    }

    function test_genesis_listedAndOpenAtConstruction() public {
        assertEq(registry.latestVersion(), 1);
        assertEq(registry.firstVersion(), 1);
        assertEq(registry.manifestOf(1), manifest1);
        assertEq(registry.versionOf(manifest1), 1);
        assertEq(registry.implementation(1, MemberTypes.HUB), address(hubImpl));
        assertEq(registry.implementation(1, MemberTypes.AAVE_V3_ASSET), address(longImpl));
        assertEq(registry.acceptedAt(1), vm.getBlockTimestamp()); // the check-in clock, seeded
        (uint64 due,,,) = registry.proposal(1);
        assertEq(due, 0); // nothing left proposed
        assertTrue(registry.profileOpen(btcProfile));
        assertEq(registry.profileState(btcProfile), registry.PROFILE_OPEN());
        assertEq(registry.profileIds().length, 1);
        // a strategy on it at once, no 7 days
        _create(_btcSpec());
        // never stopped on arrival; stopped 7 days after the last check-in, as any version
        assertFalse(registry.stopped(0, 1));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertTrue(registry.stopped(0, 1));
    }

    function test_genesis_events() public {
        VersionMember[] memory m = _members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        vm.expectEmit(false, false, false, true);
        emit StrategyRegistry.VersionAccepted(1, Manifests.hash(m));
        vm.expectEmit(false, false, false, true);
        emit StrategyRegistry.ProfileAccepted(Profiles.id(_btc()));
        _deployRegistry(m, _one(_btc()));
    }

    function test_genesis_none_thenProposals() public {
        StrategyRegistry r = _deployRegistry(new VersionMember[](0), new AssetProfile[](0));
        assertEq(r.latestVersion(), 0);
        // version 1's implementations name no registry: a proposal can never list them
        VersionMember[] memory m = _members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        vm.prank(recovery);
        vm.expectRevert();
        r.proposeVersion(1, m);
    }

    function test_genesis_refusals() public {
        VersionMember[] memory good = _members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        // profiles with no genesis
        _deployReverts(new VersionMember[](0), _one(_btc()), StrategyRegistry.BadProfile.selector);
        // a local implementation whose code hash is not the one named
        VersionMember[] memory m = _members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        m[0].codeHash = keccak256("other");
        _deployReverts(m, new AssetProfile[](0), StrategyRegistry.CodeChanged.selector);
        // a local implementation of another version (version 2's hub)
        HubV2 hub2 = new HubV2(
            address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), address(seqFeed)
        );
        m = _members(address(hub2), address(longImpl), FAR_SHORT, FAR_HASH);
        _deployReverts(m, new AssetProfile[](0), StrategyRegistry.BadVersion.selector);
        // a member type answering another type (the long as the hub)
        m = _members(address(longImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        _deployReverts(m, new AssetProfile[](0), StrategyRegistry.BadVersion.selector);
        // members out of order
        m = _members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        (m[0], m[1]) = (m[1], m[0]);
        _deployReverts(m, new AssetProfile[](0), StrategyRegistry.BadVersion.selector);
        // no member type of it lives on this chain
        m = _members(FAR_HUB, FAR_LONG, FAR_SHORT, FAR_HASH);
        (m[0].domain, m[1].domain) = (HYPER + 1, HYPER + 1);
        _deployReverts(m, new AssetProfile[](0), StrategyRegistry.BadVersion.selector);
        // a profile failing this chain's checks (AP-3): a pin's feed with no code
        AssetProfile memory bad = _btc();
        bad.pins[0].feed = address(0xdead);
        _deployReverts(good, _one(bad), StrategyRegistry.BadProfile.selector);
        // a profile twice
        AssetProfile[] memory twice = new AssetProfile[](2);
        twice[0] = _btc();
        twice[1] = _btc();
        _deployReverts(good, twice, StrategyRegistry.AlreadyPending.selector);
        // the root registry starts at version 1
        bytes memory init = abi.encodePacked(
            vm.getCode("StrategyRegistry.sol:StrategyRegistry"), abi.encode(recovery, address(0), uint256(2), good, new AssetProfile[](0))
        );
        address made;
        assembly ("memory-safe") {
            made := create(0, add(init, 0x20), mload(init))
        }
        assertEq(made, address(0));
    }

    /// The next version still takes the public 7 days, and its implementations name this registry.
    function test_genesis_version2TakesSevenDays() public {
        address hub2 = address(
            new HubV2(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), address(seqFeed))
        );
        VersionMember[] memory m = _members(hub2, address(longImpl), FAR_SHORT, FAR_HASH_2);
        m[1].implementation = address(new LongShapeV2(address(registry)));
        m[1].codeHash = m[1].implementation.codehash;
        vm.prank(recovery);
        registry.proposeVersion(2, m);
        vm.prank(recovery);
        vm.expectRevert(StrategyRegistry.NotDue.selector);
        registry.acceptVersion(2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        registry.acceptVersion(2);
        assertEq(registry.latestVersion(), 2);
    }

    // ── a version-1 implementation behind another factory and another registry ────────────────────────

    /// Anyone may build a registry listing DLTX's version-1 implementations and a factory over it: its
    /// members read THAT registry only (its fee address, its keys), and none is a hub of the pinned
    /// factory, the only one a deposit contract funds (`authorisedFor`, PINNED_VAULT_FACTORY).
    function test_foreignRegistry_readsItsOwnAndIsNotAuthorised() public {
        address thief = makeAddr("thief");
        VersionMember[] memory m = _members(address(hubImpl), address(longImpl), FAR_SHORT, FAR_HASH);
        bytes memory args = abi.encode(thief, address(0), uint256(1), m, _one(_btc()));
        StrategyRegistry foreign = StrategyRegistry(deployCode("StrategyRegistry.sol:StrategyRegistry", args));
        vm.prank(thief);
        foreign.setExecutionKey(0, key);
        StrategyFactory otherFactory = StrategyFactory(
            deployCode(
                "StrategyFactory.sol:StrategyFactory",
                abi.encode(
                    address(foreign), ParamsTypesV1.HUB_NAME, ParamsTypesV1.HUB_FIELDS, ParamsTypesV1.HUB_COUNT, _hubDomains(), _legPins()
                )
            )
        );
        StrategySpec memory c = _btcSpec();
        c.factory = address(otherFactory);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(walletPk, otherFactory.createDigest(STRATEGY, address(owner), c, deadline));
        address[] memory made = otherFactory.create(STRATEGY, address(owner), c, deadline, abi.encodePacked(uint8(1), r, ss, v));
        Hub hub = Hub(payable(made[0]));
        assertEq(hub.registry(), address(foreign));
        (address o,,) = factory.authorisedFor(address(hub));
        assertEq(o, address(0), "not a hub of the pinned factory");
        (o,,) = otherFactory.authorisedFor(address(hub));
        assertEq(o, address(owner));
    }

    /// `initialize` re-validates the hub's parameters on the registry it stores, whatever made it: a
    /// factory skipping `validateParams` can't store a fee rate above the cap, nor a profile its registry
    /// does not hold open.
    function test_initialize_revalidatesOnItsRegistry() public {
        RogueMaker rogue = new RogueMaker();
        HubParams memory p = _hubParams(btcProfile);
        p.feeRateBp = 5_001; // above FeeMath.MAX_FEE_BP
        address proxy = rogue.make(address(hubImpl), bytes32(uint256(1)));
        address[] memory links = new address[](2);
        links[0] = address(0x1111);
        links[1] = address(0x2222);
        uint32[] memory domains = new uint32[](2);
        domains[0] = ARB;
        domains[1] = HYPER;
        vm.expectRevert(HubState.BadParams.selector);
        rogue.init(proxy, address(owner), address(registry), links, domains, abi.encode(p));
        // a profile the stored registry does not hold open
        StrategyRegistry empty = _deployRegistry(new VersionMember[](0), new AssetProfile[](0));
        p = _hubParams(btcProfile);
        proxy = rogue.make(address(hubImpl), bytes32(uint256(2)));
        vm.expectRevert(HubState.BadParams.selector);
        rogue.init(proxy, address(owner), address(empty), links, domains, abi.encode(p));
    }
}

/// A maker that is not the combination factory: it stages an implementation for the shared proxy and
/// initialises it with whatever it is given, with no `validateParams`.
contract RogueMaker {
    address internal _staged;

    function proxyImplementation() external view returns (address) {
        return _staged;
    }

    function hubSetup() external pure returns (uint8[] memory k) {
        k = new uint8[](2);
    }

    function make(address impl, bytes32 salt) external returns (address made) {
        _staged = impl;
        bytes memory init = ProxyInitCode.INIT_CODE;
        assembly ("memory-safe") {
            made := create2(0, add(init, 0x20), mload(init), salt)
        }
        _staged = address(0);
        require(made != address(0), "proxy");
    }

    function init(
        address proxy,
        address owner,
        address registry,
        address[] calldata links,
        uint32[] calldata domains,
        bytes calldata params
    ) external {
        Hub(payable(proxy)).initialize(owner, registry, links, domains, 0, bytes32(uint256(7)), bytes32(uint256(8)), params);
    }
}

/// A version-2 long that only answers the listing's questions, naming its listing registry.
contract LongShapeV2 {
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
