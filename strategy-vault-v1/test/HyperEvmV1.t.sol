// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureV1} from "./FixtureV1.sol";
import {HyperCoreLegV2} from "./MocksV1.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {HyperCoreLeg} from "../src/HyperCoreLeg.sol";
import {HyperCoreLegState} from "../src/HyperCoreLegState.sol";
import {HyperCoreLegExitB} from "../src/HyperCoreLegExitB.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {AssetProfile, AssetsV1, HyperCoreParams, StrategySpec} from "../src/Types.sol";
import {Assets} from "../src/lib/VaultTypes.sol";

/*
 * Version 1 on HyperEVM, unit: the Hyperliquid leg as a proxy on the BTC profile, its perp's checks (AP-3:
 * the coin and szDecimals read from HyperCore, the asset id derived from the coin, AP-4/AP-5 at creation),
 * and following its hub's upgrade by Circle (owner-upgrades-design.md §C4: from link 0 only, finalized,
 * resolved on this chain's registry, the freshness rules).
 */
contract HyperEvmV1Test is FixtureV1 {
    address short;
    address hubAt;
    StrategySpec spec;

    function setUp() public {
        _hyperEvm();
        spec = _btcSpec();
        short = _create(spec)[0];
        hubAt = _memberAddresses(spec)[0];
    }

    function test_create_theShortOnItsProfile() public view {
        assertEq(_implOf(short), address(shortImpl));
        assertEq(HyperCoreLegState(short).profile(), btcProfile);
        assertEq(HyperCoreLegState(short).perp(), 0);
        assertEq(HyperCoreLegState(short).asset(), AssetsV1.BTC);
        assertEq(MemberState(short).memberType(), 3);
        assertEq(MemberState(short).links(0), hubAt);
        (bytes32 legType,,) = HyperCoreLeg(payable(short)).legInfo();
        assertEq(legType, keccak256("dltx.leg.hypercore"));
    }

    function test_create_refusesAShortUnlikeItsProfile() public {
        AssetProfile memory p = _btc();
        HyperCoreParams memory s = _shortParams(p, btcProfile);
        s.perp = 1; // the ETH perp under the BTC profile
        _refusedShort(s);
        s = _shortParams(p, btcProfile);
        s.asset = Assets.ETH;
        _refusedShort(s);
        s = _shortParams(p, btcProfile);
        s.coin = _word("ETH");
        _refusedShort(s);
    }

    function _refusedShort(HyperCoreParams memory s) internal {
        StrategySpec memory c = _btcSpec();
        c.legs[1].params = abi.encode(s);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory sig = _createSig(c, deadline);
        vm.expectRevert(HyperCoreLeg.BadParams.selector);
        factory.create(STRATEGY, address(owner), c, deadline, sig);
    }

    /// AP-3: an ETH perp claiming BTC, a wrong szDecimals, an underlying other than the coin: refused.
    function test_profile_perpFactsRefused() public {
        AssetProfile memory p;
        p = _btc(); p.perp = 1; _refusedProfile(p); // perp 1's coin is "ETH"
        p = _btc(); p.szDecimals = 4; _refusedProfile(p);
        p = _btc(); p.underlying = _word("WBTC"); _refusedProfile(p);
        p = _btc(); p.shortAsset = AssetsV1.WBTC; _refusedProfile(p);
        p = _btc(); p.perp = 10_000; _refusedProfile(p); // not a DEX 0 perp
    }

    function _refusedProfile(AssetProfile memory p) internal {
        vm.prank(recovery);
        bytes32 id = registry.proposeProfile(p);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(recovery);
        vm.expectRevert(MemberState.BadProfile.selector);
        registry.acceptProfile(id);
    }

    // ── following the hub (§C4) ─────────────────────────────────────────────────────────────────────────

    function _version2() internal returns (bytes32 manifest2, address short2) {
        short2 = address(
            new HyperCoreLegV2(
                address(shortExit), address(shortExit).codehash, address(shortExitB), address(shortExitB).codehash,
                address(upgrade), address(upgrade).codehash, address(registry)
            )
        );
        manifest2 = _listVersion(2, address(0xB1), address(0xB2), short2, short2.codehash);
        _checkIn();
    }

    function _deliverUpgrade(bytes32 manifest, uint256 publishedAt) internal returns (bool) {
        return transmitter.deliver(
            short, ARB, bytes32(uint256(uint160(hubAt))), abi.encode(UPGRADE_MESSAGE, manifest, publishedAt)
        );
    }

    function test_follow_theHubsMessage() public {
        (bytes32 manifest2, address short2) = _version2();
        _deliverUpgrade(manifest2, vm.getBlockTimestamp());
        assertEq(_implOf(short), short2);
        assertEq(MemberState(short).codeVersion(), 2);
        assertEq(MemberState(short).lastPublishedAt(), vm.getBlockTimestamp());
        assertEq(HyperCoreLegState(short).profile(), btcProfile); // nothing else moves
    }

    function test_follow_anUnlistedManifestWaits() public {
        bytes32 nope = keccak256("listed on Arbitrum, not yet here");
        vm.expectRevert(MemberState.NotListed.selector);
        this.deliverUpgrade(nope, vm.getBlockTimestamp());
        assertEq(_implOf(short), address(shortImpl));
    }

    function deliverUpgrade(bytes32 manifest, uint256 publishedAt) external {
        _deliverUpgrade(manifest, publishedAt);
    }

    function test_follow_freshnessRules() public {
        uint256 t0 = vm.getBlockTimestamp();
        (bytes32 manifest2, address short2) = _version2();
        // published before this leg's creation: ignored
        _deliverUpgrade(manifest2, t0 - 1);
        assertEq(_implOf(short), address(shortImpl));
        // older than 3 days: ignored
        _deliverUpgrade(manifest2, vm.getBlockTimestamp() - 3 days - 1);
        assertEq(_implOf(short), address(shortImpl));
        // fresh: followed; then the same or an older publication is ignored
        _deliverUpgrade(manifest2, vm.getBlockTimestamp() - 1 hours);
        assertEq(_implOf(short), short2);
        // a version not above its own is ignored too (manifest 1 republished)
        _deliverUpgrade(manifest1, vm.getBlockTimestamp());
        assertEq(_implOf(short), short2);
    }

    function test_follow_onlyFromItsHubFinalized() public {
        (bytes32 manifest2,) = _version2();
        bytes memory body = abi.encode(UPGRADE_MESSAGE, manifest2, vm.getBlockTimestamp());
        vm.expectRevert(MemberState.BadMessage.selector);
        transmitter.deliver(short, HYPER, bytes32(uint256(uint160(stranger))), body);
        // unfinalized
        vm.prank(TRANSMITTER);
        vm.expectRevert(MemberState.BadMessage.selector);
        MemberBase(short).handleReceiveUnfinalizedMessage(ARB, bytes32(uint256(uint160(hubAt))), 1000, body);
        // the upgrade module's message entry refuses any caller but Circle's transmitter
        vm.expectRevert(MemberState.NotAllowed.selector);
        (bool ok,) = short.call(abi.encodeWithSignature("followMessage(bytes32,uint256)", manifest2, block.timestamp));
        ok;
    }

    function test_beginExitStopped_perVersion() public {
        vm.expectRevert(MemberState.GroupNotStopped.selector);
        MemberBase(short).beginExitStopped();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        MemberBase(short).beginExitStopped();
        assertTrue(MemberState(short).exiting());
    }
}
