// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureV1} from "./FixtureV1.sol";
import {AaveV3AssetLegV2, HubV2, MockToken} from "./MocksV1.sol";
import {Hub} from "../src/Hub.sol";
import {HubFee} from "../src/HubFee.sol";
import {HubState} from "../src/HubState.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {AaveV3AssetLeg} from "../src/AaveV3AssetLeg.sol";
import {AaveV3AssetLegState} from "../src/AaveV3AssetLegState.sol";
import {AaveV3AssetLegRewards} from "../src/AaveV3AssetLegRewards.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {ProxyInitCode} from "../src/ProxyInitCode.sol";
import {AssetProfile, AssetsV1, HubParams, OwnerMessagesV1, PricePin, Profiles, StrategySpec} from "../src/Types.sol";
import {Assets, VaultConfig} from "../src/lib/VaultTypes.sol";
import {PriceSourcePin} from "../src/lib/PriceSource.sol";
import {walletCred} from "./mocks/Mocks.sol";

/*
 * Version 1 on Arbitrum, unit: the hub and the AAVE asset leg as proxies on the BTC profile; creation's
 * refusals (AP-4, AP-5, the manifest, the stopped group); the owner's upgrade at the hub, followed by the
 * long (owner-upgrades-design.md §C4); the owner's profile switch (asset-profiles-design.md §3.7); the one
 * pending action (Q13).
 */
contract ArbitrumV1Test is FixtureV1 {
    address hub;
    address long;
    StrategySpec spec;

    function setUp() public {
        _arbitrum();
        spec = _btcSpec();
        address[] memory made = _create(spec);
        hub = made[0];
        long = made[1];
    }

    // ── creation ─────────────────────────────────────────────────────────────────────────────────────

    /// The creation of `c` reverts with `err` (its signature computed first: `createDigest` is a call).
    function _createReverts(StrategySpec memory c, bytes4 err) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory sig = _createSig(c, deadline);
        vm.expectRevert(err);
        factory.create(STRATEGY, address(owner), c, deadline, sig);
    }

    function test_create_membersAreProxiesOnTheirImplementations() public view {
        address[] memory at = _memberAddresses(spec);
        assertEq(at[0], hub);
        assertEq(at[1], long);
        assertEq(hub.code.length, 64); // the shared proxy's runtime
        assertEq(keccak256(hub.code), keccak256(long.code));
        assertEq(_implOf(hub), address(hubImpl));
        assertEq(_implOf(long), address(longImpl));
        assertEq(MemberState(hub).codeVersion(), 1);
        assertEq(MemberState(long).codeVersion(), 1);
        assertEq(MemberState(hub).memberType(), 1);
        assertEq(MemberState(long).memberType(), 2);
        assertEq(factory.proxyImplementation(), address(0)); // staged only during a creation
        (bytes32 pair) = VaultConfig.pairId(STRATEGY, address(owner), keccak256(abi.encode(spec)));
        bytes32 salt = VaultConfig.legSalt(pair, 2);
        assertEq(at[2], address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, ProxyInitCode.HASH))))));
    }

    function test_create_storesTheProfile() public view {
        assertEq(Hub(hub).profile(), btcProfile);
        PriceSourcePin[] memory pins = Hub(hub).priceSources();
        assertEq(pins.length, 2);
        assertEq(pins[0].asset, AssetsV1.BTC);
        assertEq(pins[1].asset, AssetsV1.WBTC);
        assertEq(pins[1].baseFeed, address(btcUsd));
        assertEq(Hub(hub).sequencerFeed(), address(seqFeed));
        (bytes32 id, address asset, uint8 decimals, address aAsset, address pool, uint24 fee, bool t0, bytes32 holding,
            uint16 minBound, address rate, uint32 rateAge) = AaveV3AssetLegRewards(long).assetProfile();
        assertEq(id, btcProfile);
        assertEq(asset, address(wbtc));
        assertEq(decimals, 8);
        assertEq(aAsset, address(aWbtc));
        assertEq(pool, address(wbtcPool));
        assertEq(fee, 500);
        assertEq(t0, address(wbtc) < ARB_USDC);
        assertEq(holding, AssetsV1.WBTC);
        assertEq(minBound, 60);
        assertEq(rate, address(wbtcBtc));
        assertEq(rateAge, 25 hours);
        (bytes32 legType,,) = AaveV3AssetLeg(long).legInfo();
        assertEq(legType, keccak256("dltx.leg.aave-v3-asset"));
    }

    /// AP-3 at creation re-reads the reserve's state, never the rate feed's liveness: a creation two days
    /// after the WBTC / BTC round (its 25 h freshness long gone) still goes.
    function test_create_doesNotWaitForTheRateFeed() public {
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _checkIn();
        StrategySpec memory c = _btcSpec();
        c.group = 0;
        c.hubParams = abi.encode(HubParams(btcProfile, 4, 50, 1500, 0, 0)); // another configuration: new members
        address[] memory made = _create(c);
        assertEq(Hub(made[0]).profile(), btcProfile);
    }

    /// Review P2-1: an owner that cannot answer `removalPendingOf` (an older deposit account) is refused:
    /// its strategy could never be upgraded nor switched.
    function test_create_refusesAnOwnerWithoutRemovalPendingOf() public {
        vm.mockCallRevert(address(owner), abi.encodeWithSignature("removalPendingOf(bytes32)", bytes32(0)), "");
        StrategySpec memory c = _btcSpec();
        c.hubParams = abi.encode(HubParams(btcProfile, 4, 50, 1500, 0, 0));
        _createReverts(c, StrategyFactory.BadOwner.selector);
    }

    /// The hub's profile is set once, by its own initialisation.
    function test_initProfile_onlyOnceByItself() public {
        vm.expectRevert(MemberState.NotAllowed.selector);
        HubFee(hub).initProfile(btcProfile);
    }

    // ── the money lock (owner-upgrades-design.md §C4: refused under it) ─────────────────────────────

    /// `_locked` is slot 12 in every member's layout.
    function _lock(address m) internal {
        vm.store(m, bytes32(uint256(12)), bytes32(uint256(1)));
    }

    function test_moneyLock_refusesTheUpgradeAndTheSwitch() public {
        (bytes32 manifest2,,) = _version2();
        bytes32 to = _accept(_btc30());
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cred = walletCred(wallet);
        bytes memory sig = _upgradeSig(walletPk, hub, manifest2, 0, deadline);
        _lock(hub);
        vm.expectRevert(MemberState.Reentrancy.selector);
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, deadline, sig);
        vm.expectRevert(MemberState.Reentrancy.selector);
        VaultUpgrade(hub).applyUpgrade();
        vm.expectRevert(MemberState.Reentrancy.selector);
        HubFee(hub).applySwitch();
        sig = _switchSig(walletPk, hub, btcProfile, to, 0, deadline);
        vm.expectRevert(MemberState.Reentrancy.selector);
        HubFee(hub).scheduleSwitch(to, cred, deadline, sig);
        _lock(long);
        vm.prank(hub);
        vm.expectRevert(MemberState.Reentrancy.selector);
        VaultUpgrade(long).followUpgrade(manifest2);
        vm.prank(hub);
        vm.expectRevert(MemberState.Reentrancy.selector);
        AaveV3AssetLegRewards(long).followSwitch(to);
    }

    function test_implementationsCannotBeInitialised() public {
        address[] memory links = new address[](1);
        uint32[] memory d = new uint32[](1);
        links[0] = address(1);
        vm.expectRevert(MemberState.AlreadyInitialized.selector);
        hubImpl.initialize(address(owner), address(registry), links, d, 0, STRATEGY, bytes32(0), "");
        vm.expectRevert(MemberState.AlreadyInitialized.selector);
        longImpl.initialize(address(owner), address(registry), links, d, 0, STRATEGY, bytes32(0), "");
        // a module called directly refuses (`delegated`)
        vm.expectRevert(MemberState.NotAllowed.selector);
        upgrade.applyUpgrade();
    }

    /// AP-4: every member names one profile.
    function test_create_refusesMembersOnDifferentProfiles() public {
        AssetProfile memory p = _btc();
        p.swapPool = address(wbtcPool30);
        p.swapFee = 3000;
        bytes32 other = _accept(p);
        StrategySpec memory c = _spec(
            manifest1, abi.encode(_hubParams(btcProfile)), abi.encode(_longParams(p, other)),
            abi.encode(_shortParams(p, btcProfile))
        );
        _createReverts(c, StrategyFactory.BadConfig.selector);
    }

    /// AP-5: every shown field equals the entry's; the profile's bound floor holds.
    function test_create_refusesShownFieldsUnlikeTheProfile() public {
        AssetProfile memory p = _btc();
        bytes memory h = abi.encode(_hubParams(btcProfile));
        bytes memory s = abi.encode(_shortParams(p, btcProfile));
        StrategySpec memory c;

        p.asset = address(new MockToken(8));
        c = _spec(manifest1, h, abi.encode(_longParams(p, btcProfile)), s);
        _createReverts(c, AaveV3AssetLegState.BadParams.selector);

        p = _btc();
        p.swapPool = address(wbtcPool30);
        c = _spec(manifest1, h, abi.encode(_longParams(p, btcProfile)), s);
        _createReverts(c, AaveV3AssetLegState.BadParams.selector);

        p = _btc();
        p.rateFeed = address(0);
        c = _spec(manifest1, h, abi.encode(_longParams(p, btcProfile)), s);
        _createReverts(c, AaveV3AssetLegState.BadParams.selector);

        // oracleBoundBp below the profile's minBoundBp (60)
        p = _btc();
        bytes memory low = abi.encode(
            AaveV3AssetLegParamsLow(btcProfile, p.asset, p.swapPool, p.swapFee, p.rateFeed, 1.15e18, 59, 50, 5)
        );
        c = _spec(manifest1, h, low, s);
        _createReverts(c, AaveV3AssetLegState.BadParams.selector);
    }

    function test_create_refusesAnUnlistedManifestAndAStoppedGroup() public {
        StrategySpec memory c = _btcSpec();
        c.manifest = keccak256("not listed");
        _createReverts(c, StrategyFactory.BadConfig.selector);
        // 7 days without a check-in of version 1 by group 0
        vm.warp(vm.getBlockTimestamp() + 7 days);
        c = _btcSpec();
        c.group = 0;
        _createReverts(c, StrategyFactory.BadConfig.selector);
    }

    function test_create_refusesAClosedProfile() public {
        vm.prank(recovery);
        registry.closeProfile(btcProfile);
        StrategySpec memory c = _btcSpec();
        c.legs[0].params = abi.encode(_longParams(_btc(), btcProfile)); // a fresh config hash: new members
        c.group = 0;
        c.hubParams = abi.encode(HubParams(btcProfile, 4, 50, 1500, 0, 0));
        _createReverts(c, HubState.BadParams.selector);
    }

    // ── the upgrade (owner-upgrades-design.md §C4) ──────────────────────────────────────────────────────

    function _version2() internal returns (bytes32 manifest2, address hub2, address long2) {
        hub2 = address(new HubV2(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), address(seqFeed)));
        long2 = address(
            new AaveV3AssetLegV2(
                address(longExit), address(longExit).codehash, address(longRewards), address(longRewards).codehash,
                address(upgrade), address(upgrade).codehash, address(registry), address(aave), ARB_USDC, address(aave),
                address(seqFeed)
            )
        );
        manifest2 = _listVersion(2, hub2, long2, FAR_SHORT, FAR_HASH_2);
        _checkIn();
    }

    function _schedule(bytes32 manifest) internal returns (uint64 due) {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cred = walletCred(wallet);
        uint256 nonce = MemberState(hub).ownerNonceOf(cred);
        VaultUpgrade(hub).scheduleUpgrade(manifest, cred, deadline, _upgradeSig(walletPk, hub, manifest, nonce, deadline));
        (, due,,) = VaultUpgrade(hub).pendingAction();
    }

    function test_upgrade_scheduleApplyMovesHubAndLongNothingElse() public {
        (bytes32 manifest2, address hub2, address long2) = _version2();
        // the state an upgrade must not touch (AP-11, V3, V10)
        int256 mark = Hub(hub).mark();
        uint64 lastFee = Hub(hub).lastFeeAt();
        uint64 ops = MemberState(long).opCount();
        uint64 due = _schedule(manifest2);
        assertEq(due, vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(MemberState.NotDue.selector);
        VaultUpgrade(hub).applyUpgrade();
        vm.warp(due);
        vm.prank(stranger);
        VaultUpgrade(hub).applyUpgrade();
        assertEq(_implOf(hub), hub2);
        assertEq(_implOf(long), long2);
        assertEq(MemberState(hub).codeVersion(), 2);
        assertEq(MemberState(long).codeVersion(), 2);
        assertEq(Hub(hub).mark(), mark);
        assertEq(Hub(hub).lastFeeAt(), lastFee);
        assertEq(Hub(hub).profile(), btcProfile);
        (bytes32 id,,,,,,,,,,) = AaveV3AssetLegRewards(long).assetProfile();
        assertEq(id, btcProfile);
        assertEq(MemberState(long).opCount(), ops);
        (uint8 kind,,,) = VaultUpgrade(hub).pendingAction();
        assertEq(kind, 0);
        // the remote short is told by Circle, finalized: (UPGRADE, manifest, publishedAt)
        uint256 n = transmitter.sentCount();
        assertEq(transmitter.sent(n - 1).body, abi.encode(UPGRADE_MESSAGE, manifest2, vm.getBlockTimestamp()));
        assertEq(transmitter.sent(n - 1).minFinalityThreshold, 2000);
        // the escape hatch now asks version 2's check-ins
        assertFalse(registry.stopped(0, 2));
    }

    function test_upgrade_refusals() public {
        (bytes32 manifest2,,) = _version2();
        // a manifest not listed, or not above the hub's version
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cred = walletCred(wallet);
        bytes memory sig = _upgradeSig(walletPk, hub, manifest1, 0, deadline);
        vm.expectRevert(MemberState.NotListed.selector);
        VaultUpgrade(hub).scheduleUpgrade(manifest1, cred, deadline, sig);
        bytes32 nope = keccak256("nope");
        sig = _upgradeSig(walletPk, hub, nope, 0, deadline);
        vm.expectRevert(MemberState.NotListed.selector);
        VaultUpgrade(hub).scheduleUpgrade(nope, cred, deadline, sig);
        // signed for another hub, or by another credential than named
        sig = _upgradeSig(walletPk, long, manifest2, 0, deadline);
        vm.expectRevert(MemberState.BadSignature.selector);
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, deadline, sig);
        sig = _upgradeSig(wallet2Pk, hub, manifest2, 0, deadline);
        vm.expectRevert(MemberState.BadSignature.selector);
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, deadline, sig);
        // a credential whose removal is pending
        owner.setRemovalPending(cred, true);
        sig = _upgradeSig(walletPk, hub, manifest2, 0, deadline);
        vm.expectRevert(MemberState.RemovalPending.selector);
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, deadline, sig);
        owner.setRemovalPending(cred, false);
        // a leg never takes an owner's upgrade
        vm.expectRevert(MemberState.Unsupported.selector);
        VaultUpgrade(long).scheduleUpgrade(manifest2, cred, deadline, sig);
        // a leg follows its hub only
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotAllowed.selector);
        VaultUpgrade(long).followUpgrade(manifest2);
        // one pending action: a second schedule is refused, whatever its kind
        _schedule(manifest2);
        sig = _upgradeSig(walletPk, hub, manifest2, 1, deadline);
        vm.expectRevert(MemberState.AlreadyPending.selector);
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, deadline, sig);
    }

    function test_upgrade_cancelByAnyCredentialUntilApplied() public {
        (bytes32 manifest2,,) = _version2();
        uint64 due = _schedule(manifest2);
        vm.warp(due + 1 days); // due, not applied: still cancellable (Q9)
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        // naming another target or due time cancels nothing
        bytes memory bad = _cancelSig(wallet2Pk, hub, 1, manifest1, due, deadline);
        vm.expectRevert(MemberState.NotPending.selector);
        VaultUpgrade(hub).cancelPendingAction(1, manifest1, due, deadline, bad);
        bytes memory sig = _cancelSig(wallet2Pk, hub, 1, manifest2, due, deadline);
        VaultUpgrade(hub).cancelPendingAction(1, manifest2, due, deadline, sig);
        vm.expectRevert(MemberState.NotPending.selector);
        VaultUpgrade(hub).applyUpgrade();
        assertEq(_implOf(hub), address(hubImpl));
    }

    function test_upgrade_clearedWhenItsSchedulerNoLongerStands() public {
        (bytes32 manifest2,,) = _version2();
        uint64 due = _schedule(manifest2);
        vm.warp(due);
        owner.setRemovalPending(walletCred(wallet), true);
        VaultUpgrade(hub).applyUpgrade();
        assertEq(_implOf(hub), address(hubImpl));
        (uint8 kind,,,) = VaultUpgrade(hub).pendingAction();
        assertEq(kind, 0);
    }

    function test_upgrade_allowedDuringTheExit() public {
        (bytes32 manifest2, address hub2, address long2) = _version2();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        MemberBase(hub).beginExit(deadline, _beginExitSig(deadline));
        assertTrue(MemberState(long).exiting());
        uint64 due = _schedule(manifest2);
        vm.warp(due);
        VaultUpgrade(hub).applyUpgrade();
        assertEq(_implOf(hub), hub2);
        assertEq(_implOf(long), long2);
        assertTrue(MemberState(hub).exiting());
    }

    function test_publishUpgrade_sendsTheCurrentManifest() public {
        (bytes32 manifest2,,) = _version2();
        uint64 due = _schedule(manifest2);
        vm.warp(due);
        VaultUpgrade(hub).applyUpgrade();
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.prank(stranger);
        VaultUpgrade(hub).publishUpgrade(1);
        uint256 n = transmitter.sentCount();
        assertEq(transmitter.sent(n - 1).body, abi.encode(UPGRADE_MESSAGE, manifest2, vm.getBlockTimestamp()));
        vm.expectRevert(MemberState.NotAllowed.selector);
        VaultUpgrade(hub).publishUpgrade(2);
    }

    // ── the profile switch (asset-profiles-design.md §3.7) ───────────────────────────────────────────────

    /// The BTC profile on the 0.30 % pool: same token, same short part, same pins.
    function _btc30() internal view returns (AssetProfile memory p) {
        p = _btc();
        p.swapPool = address(wbtcPool30);
        p.swapFee = 3000;
        p.minBoundBp = 70; // the signed 100 still holds, above 30
    }

    function _scheduleSwitch(bytes32 to) internal returns (uint64 due) {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cred = walletCred(wallet);
        uint256 nonce = MemberState(hub).ownerNonceOf(cred);
        HubFee(hub).scheduleSwitch(to, cred, deadline, _switchSig(walletPk, hub, btcProfile, to, nonce, deadline));
        (, due,,) = VaultUpgrade(hub).pendingAction();
    }

    function test_switch_sameTokenAppliedAtTheHubAndTheLong() public {
        bytes32 to = _accept(_btc30());
        uint64 ops = MemberState(long).opCount();
        uint64 due = _scheduleSwitch(to);
        vm.expectRevert(MemberState.NotDue.selector);
        HubFee(hub).applySwitch();
        vm.warp(due);
        _feeds(82_000e8, 0.998e8);
        vm.prank(stranger);
        HubFee(hub).applySwitch();
        assertEq(Hub(hub).profile(), to);
        (bytes32 id, address asset,,, address pool, uint24 fee,,, uint16 minBound,,) =
            AaveV3AssetLegRewards(long).assetProfile();
        assertEq(id, to);
        assertEq(asset, address(wbtc));
        assertEq(pool, address(wbtcPool30));
        assertEq(fee, 3000);
        assertEq(minBound, 70);
        assertEq(MemberState(long).opCount(), ops + 1); // counted: a snapshot before it is refused
        assertEq(Hub(hub).priceSources().length, 2); // the pins unchanged
    }

    function test_switch_refusesAnotherTokenOtherPinsALowBoundAndTheExit() public {
        uint256 deadline;
        bytes32 cred = walletCred(wallet);
        // another token
        AssetProfile memory p = _btc30();
        MockToken other = new MockToken(8);
        MockToken aOther = new MockToken(8);
        aave.setReserve(address(other), address(aOther), address(0), aave.GOOD_CONFIG(), 9);
        aave.setPrice(address(other), 82_000e8, address(0xB7C));
        aave.setPool(address(other), ARB_USDC, 3000, address(wbtcPool30));
        p.asset = address(other);
        p.aAsset = address(aOther);
        p.assetIsToken0 = address(other) < ARB_USDC;
        bytes32 otherToken = _accept(p);
        deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _switchSig(walletPk, hub, btcProfile, otherToken, 0, deadline);
        vm.expectRevert(MemberState.BadProfile.selector);
        HubFee(hub).scheduleSwitch(otherToken, cred, deadline, sig);
        // other price pins (a phantom profit at the next charge)
        p = _btc30();
        p.pins[1].maxAge = 24 hours;
        bytes32 otherPins = _accept(p);
        deadline = vm.getBlockTimestamp() + 1 hours;
        sig = _switchSig(walletPk, hub, btcProfile, otherPins, 0, deadline);
        vm.expectRevert(MemberState.BadProfile.selector);
        HubFee(hub).scheduleSwitch(otherPins, cred, deadline, sig);
        // a floor above the signed bound (100)
        p = _btc30();
        p.minBoundBp = 120;
        bytes32 high = _accept(p);
        deadline = vm.getBlockTimestamp() + 1 hours;
        sig = _switchSig(walletPk, hub, btcProfile, high, 0, deadline);
        vm.expectRevert(MemberState.BadProfile.selector);
        HubFee(hub).scheduleSwitch(high, cred, deadline, sig);
        // unsigned (another credential's signature under this one's name)
        bytes32 to = _accept(_btc30());
        deadline = vm.getBlockTimestamp() + 1 hours;
        sig = _switchSig(wallet2Pk, hub, btcProfile, to, 0, deadline);
        vm.expectRevert(MemberState.BadSignature.selector);
        HubFee(hub).scheduleSwitch(to, cred, deadline, sig);
        // in exit
        deadline = vm.getBlockTimestamp() + 1 hours;
        MemberBase(hub).beginExit(deadline, _beginExitSig(deadline));
        sig = _switchSig(walletPk, hub, btcProfile, to, 0, deadline);
        vm.expectRevert(MemberState.BadProfile.selector);
        HubFee(hub).scheduleSwitch(to, cred, deadline, sig);
    }

    function test_switch_pendingIsClearedAtTheExitAndBlocksAnUpgrade() public {
        bytes32 to = _accept(_btc30());
        (bytes32 manifest2,,) = _version2();
        _scheduleSwitch(to);
        // one pending action in total (Q13): no upgrade while the switch waits
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cred = walletCred(wallet);
        bytes memory sig = _upgradeSig(walletPk, hub, manifest2, 1, deadline);
        vm.expectRevert(MemberState.AlreadyPending.selector);
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, deadline, sig);
        // the exit clears it, freeing the slot for an upgrade
        MemberBase(hub).beginExit(deadline, _beginExitSig(deadline));
        (uint8 kind,,,) = VaultUpgrade(hub).pendingAction();
        assertEq(kind, 0);
        VaultUpgrade(hub).scheduleUpgrade(manifest2, cred, deadline, sig);
    }

    function test_switch_clearedAtApplyWhenItCanNoLongerApply() public {
        bytes32 to = _accept(_btc30());
        uint64 due = _scheduleSwitch(to);
        vm.prank(recovery);
        registry.closeProfile(to);
        vm.warp(due);
        HubFee(hub).applySwitch();
        assertEq(Hub(hub).profile(), btcProfile);
        (uint8 kind,,,) = VaultUpgrade(hub).pendingAction();
        assertEq(kind, 0);
    }

    /// Review P2-2: the long re-checks the profile's facts with its own code at the apply; refused (here
    /// the reserve frozen since the acceptance), the switch is cleared, not reverted. A low gas estimate
    /// cannot buy that clearing (`GasTooLow`).
    function test_switch_clearedWhenTheLongRefusesItsFacts() public {
        bytes32 to = _accept(_btc30());
        uint64 due = _scheduleSwitch(to);
        vm.warp(due);
        aave.setConfiguration(address(wbtc), aave.GOOD_CONFIG() | (1 << 57));
        vm.expectRevert(MemberState.GasTooLow.selector);
        HubFee(hub).applySwitch{gas: 600_000}();
        HubFee(hub).applySwitch();
        assertEq(Hub(hub).profile(), btcProfile);
        (bytes32 id,,,,,,,,,,) = AaveV3AssetLegRewards(long).assetProfile();
        assertEq(id, btcProfile);
        (uint8 kind,,,) = VaultUpgrade(hub).pendingAction();
        assertEq(kind, 0);
    }

    function test_followSwitch_onlyFromTheHub() public {
        bytes32 to = _accept(_btc30());
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotAllowed.selector);
        AaveV3AssetLegRewards(long).followSwitch(to);
    }
}

/// The long's parameters with an arbitrary bound, for a refusal (the same fields as `AssetLegParams`).
struct AaveV3AssetLegParamsLow {
    bytes32 profile;
    address asset;
    address swapPool;
    uint24 swapFee;
    address rateFeed;
    uint64 healthFloor;
    uint16 oracleBoundBp;
    uint16 dailyLossBp;
    uint16 fastFeeCapBp;
}

