// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Fixture} from "./utils/Fixture.sol";
import {LongVault} from "../src/LongVault.sol";
import {ShortVaultState} from "../src/ShortVaultState.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {MockTransmitter, walletCred} from "./mocks/Mocks.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {StrategyHubFee} from "../src/StrategyHubFee.sol";
import {StrategyHubState} from "../src/StrategyHubState.sol";
import {Assets, Holding, LegConfig, Legs, ParamsTypes, StrategyConfig} from "../src/lib/VaultTypes.sol";
import {PriceSourcePin, SequencerPin} from "../src/lib/PriceSource.sol";
import {TestLeg, TestLegExit} from "./mocks/TestLeg.sol";

/*
 * The security review of 2026-10-16 (review/vault-security), on master d00a9d234: one test per finding,
 * first written to pass while the gap stood (commit 29bf8bf7a), then turned around by its fix: the rate
 * bounded by the signed rate and never raised in exit, the Hyperliquid leg's cash as `accountValue − szi ×
 * markPx`, a rollup hub chain's sequencer pin required. The hatch-shut test documents a stated fact.
 *
 * The hub's world is HubFee.t.sol's: the hub on HyperEVM beside a test leg L, a second test leg R on
 * Arbitrum whose figures reach the hub by its REPORT (played as Circle's relay); ETH at $2,500.
 */
contract SecurityReviewHubTest is Fixture {
    TestLegExit tExit;
    TestLeg code;
    StrategyHub hub;
    StrategyHubFee fee;
    TestLeg L;
    address R;
    address treasury = makeAddr("dltx-treasury");
    address thief = makeAddr("thief");
    uint256 seq;

    function setUp() public {
        _world();
        tExit = new TestLegExit();
        code = new TestLeg(address(tExit), address(tExit).codehash);
        address[] memory at = _make();
        hub = StrategyHub(at[0]);
        fee = StrategyHubFee(at[0]);
        L = TestLeg(payable(at[1]));
        R = at[2];
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
    }

    function _pinsHere() internal view returns (CombinationFactory.LegPin[] memory p) {
        p = new CombinationFactory.LegPin[](2);
        p[0] = CombinationFactory.LegPin(address(code), address(code).codehash, HYPEREVM_DOMAIN, Legs.LONG, Legs.VALUE_READ, "TestLeg", "uint256 seven", 1);
        p[1] = CombinationFactory.LegPin(address(code), address(code).codehash, ARB_DOMAIN, Legs.SHORT, Legs.VALUE_READ, "TestLeg", "uint256 seven", 1);
    }

    function _make() internal returns (address[] memory at) {
        uint32[] memory hubs = new uint32[](1);
        hubs[0] = HYPEREVM_DOMAIN;
        CombinationFactory.LegPin[] memory p = _pinsHere();
        CombinationFactory f = _factoryWith(hubs, p);
        StrategyConfig memory c;
        c.factory = address(f);
        c.hubDomain = HYPEREVM_DOMAIN;
        c.hubParams = abi.encode(_hubParams()); // the owner signs 15 %
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(address(code), HYPEREVM_DOMAIN, Legs.LONG, abi.encode(uint256(7)));
        c.legs[1] = LegConfig(address(code), ARB_DOMAIN, Legs.SHORT, abi.encode(uint256(7)));
        uint256 deadline = block.timestamp + 1 days;
        f.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline));
        (at,) = f.memberAddresses(STRATEGY, address(owner), c);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 dt) internal {
        vm.warp(_now() + dt);
        vm.roll(vm.getBlockNumber() + dt / 2 + 1);
    }

    function _r() internal view returns (uint80[] memory r) {
        r = new uint80[](1);
        r[0] = ethRound;
    }

    function _report(int256 usd6, int256 eth18) internal {
        Holding[] memory h = new Holding[](2);
        h[0] = Holding(Assets.USD, usd6 * 1e12);
        h[1] = Holding(Assets.ETH, eth18);
        uint256[4] memory zero;
        bytes memory body = abi.encode(
            keccak256("dltx.strategy-vault.report.v1"), ++seq, _now(), vm.getBlockNumber(), uint256(0), h, zero, zero, zero
        );
        transmitter.deliver(address(hub), ARB_DOMAIN, bytes32(uint256(uint160(R))), body);
    }

    /// §3.4's worked example: mark $10,000, value $10,120 (L +4 ETH and −$4,800 net, $120 back at the
    /// hub; R +$14,920 and −4 ETH).
    function _workedExample() internal {
        usdc.mint(address(hub), 10_000e6);
        vm.prank(key);
        hub.send(0, 10_000e6, false, 0);
        L.trade(4e18, -14_800e6);
        vm.prank(key);
        L.send(0, 120e6, false, 0);
    }

    // ── P2-1 (fixed): the recovery key's rate is bounded by the rate the owner signed ────────────────

    /// The owner signed 15 % (`HubParams.feeRateBp`). A compromised recovery key gives the group its own
    /// execution key and names its own fee address (it accepts its own proposal), but can't set the rate
    /// above 15 %: on the $120 of profit already earned it takes $18, DLTX's own fee redirected (2b §5's
    /// stated bound), never the 50 % ($60) the code allowed before the fix.
    function test_review_P2_recoveryCannotRaiseAboveTheSignedRate() public {
        _workedExample();
        _warp(3 days);
        _ethPrice(2_500e8);
        assertEq(hub.feeRateBp(), 1500, "the rate the owner signed");

        vm.startPrank(recovery);
        registry.setExecutionKey(0, thief);
        registry.proposeFeeAddress(thief);
        vm.expectRevert(StrategyHubState.BadRate.selector);
        fee.setFeeRate(5000);
        vm.stopPrank();
        vm.prank(thief);
        registry.acceptFeeAddress();

        vm.prank(thief);
        fee.snapshot();
        _warp(90);
        _report(14_920e6, -4e18);
        vm.prank(thief);
        fee.crystallize(_r());
        assertEq(usdc.balanceOf(thief), 18e6, "15 % of the $120 profit: the signed rate");
    }

    /// In exit no raise: the leg's $1,100 reaches the hub (mark $1,000) and no rate change before the
    /// hub's `exitStep` can take more than the rate in force when the exit began.
    function test_review_P2_noRaiseInExit_onCashAlreadyRealised() public {
        usdc.mint(address(hub), 1_000e6);
        vm.prank(key);
        hub.send(0, 1_000e6, false, 0);
        vm.prank(recovery);
        fee.setFeeRate(1000); // lowered before the exit
        usdc.mint(address(L), 100e6); // the leg's earnings
        uint256 deadline = _now() + 1 hours;
        hub.beginExit(deadline, _beginExitSig(STRATEGY, deadline)); // the hub tells L at once
        TestLegExit(address(L)).exitStep(); // L's $1,100 to the hub, counted
        assertEq(usdc.balanceOf(address(hub)), 1_100e6);

        vm.startPrank(recovery);
        vm.expectRevert(StrategyHubState.BadRate.selector);
        fee.setFeeRate(5000);
        vm.expectRevert(StrategyHubState.BadRate.selector);
        fee.setFeeRate(1500); // not even back to the signed rate
        vm.stopPrank();
        vm.prank(stranger);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 10e6, "10 %: the rate when the exit began");
        assertEq(usdc.balanceOf(withdrawalTo), 1_090e6);
    }

    // ── P3 (fixed): an L2 hub chain needs its sequencer pin ──────────────────────────────────────────

    /// A hub domain on a rollup (Arbitrum, 3) with no sequencer pin is refused; with it, accepted, and a
    /// hub created there reads the feed.
    function test_review_P3_factoryRefusesAnL2HubWithNoSequencerPin() public {
        uint32[] memory hubs = new uint32[](1);
        hubs[0] = ARB_DOMAIN;
        CombinationFactory.LegPin[] memory p = _pinsHere();
        vm.expectRevert(CombinationFactory.BadPins.selector);
        new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, hubs, p, _prices(hubs), new SequencerPin[](0)
        );
        CombinationFactory f = new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME, ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, hubs, p, _prices(hubs), _sequencers(hubs)
        );
        transmitter.setLocalDomain(ARB_DOMAIN); // what a hub created on Arbitrum reads
        (PriceSourcePin[] memory prices, address sequencer,) = f.hubSetup();
        assertEq(prices.length, 1, "ETH / USD pinned");
        assertEq(sequencer, address(seqFeed), "the sequencer checked");
    }

    // ── P3: recovery CAN hold a group's hatch shut ───────────────────────────────────────────────────

    /// The registry says "recovery alone can never hold a group's hatch shut" (a replacement is not a
    /// check-in). Recovery can name a key it holds, and that key checks in: the hatch never opens. The
    /// owner's signed `BeginExit` still works; the escape hatch is the owner-less path that does not.
    function test_review_P3_recoveryHoldsTheHatchShutThroughAKeyItNames() public {
        address own = makeAddr("recovery-held-key");
        vm.prank(recovery);
        registry.setExecutionKey(0, own);
        for (uint256 i; i < 10; ++i) {
            _warp(6 days);
            vm.prank(own);
            registry.checkIn(0);
            assertFalse(registry.stopped(0));
        }
    }
}

/*
 * The Hyperliquid leg's report: DEX 0's `rawUsd` holds the proceeds of every DEX 0 position, and only the
 * strategy's perp is reported. 2b's guard refused a notional more than 1 % and $1 above the perp's own,
 * and counted a side short inside that as cash with no liability. Fixed: the report's cash is
 * `accountValue − szi × markPx`, every other position at its mark.
 */
contract SecurityReviewShortTest is Fixture {
    ShortVault vault;
    ShortVaultExit ex;

    function setUp() public {
        _world();
        vault = ShortVault(payable(_create(_config())));
        ex = ShortVaultExit(address(vault));
        core.setExists(address(vault), true);
    }

    /// The strategy's short: −20 ETH (szDecimals 4) at $2,431.40 (mark and oracle), $48,628 of
    /// notional; $10,000 of collateral. The agent also shorts $487 of another DEX 0 perp (inside the old
    /// guard's 1 % + $1, which counted it as $487 of profit). The account is worth $10,000; the report,
    /// valued at the same ETH price, now says $10,000. A side short of any size is no longer refused.
    function test_review_P2_sideShort_valuedAtItsMark_noInflation() public {
        int64 szi = -200_000;
        core.setPosition(address(vault), uint16(ETH), szi);
        core.setMark(ETH, 243_140);
        uint64 own = 200_000 * 243_140; // $48,628.00 (1e6)
        int64 collateral = 10_000e6;
        for (uint256 i; i < 2; ++i) {
            uint64 side = i == 0 ? 487e6 : 100_000e6; // inside the old tolerance, then far beyond it
            int64 raw = collateral + int64(own) + int64(side); // both shorts' proceeds
            int64 av = raw - int64(own) - int64(side); // Σ szi × mark: the true account value
            core.setMarginRaw(0, address(vault), av, 5_000e6, own + side, raw);
            (Holding[] memory h,,,,,,) = ex.holdings();
            assertEq(h[0].asset, Assets.USD);
            assertEq(h[1].asset, Assets.ETH);
            // valued as the hub values it: USD at face, ETH at one price (here the same 2,431.40)
            int256 valued = h[0].quantity + h[1].quantity * 243_140e16 / 1e18;
            assertEq(valued, int256(av) * 1e12, "the account's true value");
        }
    }
}

/*
 * Briac's question (2026-10-16, through the documentation session): the check-in is per execution group
 * (base spec decision 17), so an owner who REVOKED DLTX on their own members, while DLTX's key keeps
 * checking in for the group, never sees the 7-day hatch open. Proven here that such an owner always
 * exits by their own `BeginExit` signature, with no DLTX and no hatch, on today's real combination (the
 * hub and the AAVE leg on Arbitrum, the Hyperliquid leg on HyperEVM), in both of Circle's states: one
 * signature on the hub when Circle relays, or the same signature on each member when it doesn't; and
 * that the Hyperliquid leg's exit then runs by anyone in both account modes. The AAVE leg's unwinding
 * after its entry is the fork suite's (`test_fork_exit_byTheOwner_fromALeveredPosition_toTheWithdrawalAddress`
 * and the five `test_fork_exit_*` cases): its exit functions check no key, only `exiting`.
 */
contract SecurityReviewOwnerExitTest is Fixture {
    StrategyHub hub;
    LongVault long_;
    ShortVault short_;
    ShortVaultExit ex;

    function setUp() public {
        _world();
        short_ = ShortVault(payable(_create(_config()))); // on HyperEVM
        transmitter.setLocalDomain(ARB_DOMAIN);
        hub = StrategyHub(_create(_config())); // the hub and the AAVE leg on Arbitrum
        long_ = LongVault(hub.links(0));
        ex = ShortVaultExit(address(short_));
        core.setExists(address(short_), true);
    }

    function _revoke(VaultBase m) internal {
        uint256 deadline = block.timestamp + 1 hours;
        m.ownerAction(1, address(0), walletCred(wallet), deadline, _actionSig(address(m), 1, address(0), m.ownerNonceOf(walletCred(wallet)), deadline));
        assertTrue(m.executionRevoked());
    }

    /// The owner revoked DLTX everywhere; DLTX's key keeps checking in for 30 days: the hatch stays shut on
    /// every member, and DLTX can do nothing on any of them.
    function _revokedAndCheckingIn() internal {
        _revoke(hub);
        _revoke(long_);
        _revoke(short_);
        for (uint256 i; i < 30; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(key);
            registry.checkIn(0);
        }
        assertFalse(registry.stopped(0));
        vm.expectRevert(VaultState.GroupNotStopped.selector);
        hub.beginExitStopped();
        vm.expectRevert(VaultState.GroupNotStopped.selector);
        long_.beginExitStopped();
        vm.expectRevert(VaultState.GroupNotStopped.selector);
        short_.beginExitStopped();
        vm.startPrank(key);
        vm.expectRevert(VaultState.NotAllowed.selector);
        hub.send(0, 1, false, 0);
        vm.expectRevert(VaultState.NotAllowed.selector);
        long_.supply(1);
        vm.expectRevert(VaultState.NotAllowed.selector);
        short_.fromMargin(1);
        vm.stopPrank();
    }

    /// Circle relays: ONE signature, on the hub. The hub tells the AAVE leg beside it at once and the
    /// Hyperliquid leg by Circle (anyone relays it); every member is in exit without DLTX.
    function test_review_revokedOwner_exitsByOneSignature_circleRelays() public {
        _revokedAndCheckingIn();
        uint256 sent = transmitter.sentCount();
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(stranger); // anyone submits the owner's signature
        hub.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        assertTrue(hub.exiting());
        assertTrue(long_.exiting(), "told directly, on the same chain");
        MockTransmitter.Sent memory m = transmitter.sent(sent);
        assertEq(m.recipient, bytes32(uint256(uint160(address(short_)))));
        assertEq(m.body, abi.encode(short_.EXIT_MESSAGE()));
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);
        transmitter.deliver(address(short_), ARB_DOMAIN, bytes32(uint256(uint160(address(hub)))), m.body);
        assertTrue(short_.exiting(), "told by Circle");
        assertEq(short_.agent(), short_.burner(), "DLTX's agent replaced at once");
        _shortExitRunsInBothModes();
        _hubPaysTheWithdrawalAddress();
    }

    /// Circle refuses (paused): the same signature, submitted on each member (no chain id, no nonce),
    /// enters each one; the told links stay pending for anyone's `notifyLink` and are never needed.
    function test_review_revokedOwner_exitsByTheSameSignatureOnEachMember_circleDown() public {
        _revokedAndCheckingIn();
        transmitter.setPaused(true);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _beginExitSig(STRATEGY, deadline);
        vm.startPrank(stranger);
        hub.beginExit(deadline, sig);
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);
        short_.beginExit(deadline, sig);
        vm.stopPrank();
        assertTrue(hub.exiting() && long_.exiting() && short_.exiting());
        assertTrue(hub.toldPending() != 0 && short_.toldPending() != 0, "Circle's messages pending, unneeded");
        _shortExitRunsInBothModes();
        _hubPaysTheWithdrawalAddress();
    }

    /// The Hyperliquid leg's exit by a stranger: standard mode (a perp position closed, reduce-only at the
    /// oracle bound), then unified mode (the free cash read on spot, sent to HyperEVM), then its HyperEVM
    /// USDC burned to the hub.
    function _shortExitRunsInBothModes() internal {
        address v = address(short_);
        ShortVaultState.ExitArgs memory none;
        core.setPosition(v, uint16(ETH), -45);
        core.setMargin(0, v, 14_980_000, 1_100_000, 10_940_000);
        uint256 from = writer.count();
        vm.prank(stranger);
        ex.exitStep(none);
        assertEq(_countId(_since(from), 1), 1, "standard: the close sent");
        // unified: flat, the cash on spot (0x801's available amount), HYPE for the transfer's fee
        core.setPosition(v, uint16(ETH), 0);
        core.setMargin(0, v, 0, 0, 0);
        core.setWithdrawable(v, 0);
        core.setSpot(v, 0, 379_300_000);
        core.setSpot(v, HYPE, 1_000_000);
        vm.roll(vm.getBlockNumber() + 20);
        from = writer.count();
        vm.prank(stranger);
        ex.exitStep(none);
        assertTrue(_has(_since(from), _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 379_300_000)), "unified: spot to HyperEVM");
        // HyperCore credited it on HyperEVM: burned to the hub, bound to it
        usdc.mint(v, 3_793_000);
        uint256 burns = messenger.burnCount();
        vm.prank(stranger);
        ex.bridgeOut();
        assertEq(messenger.burnCount(), burns + 1);
        assertEq(messenger.burn(burns).mintRecipient, bytes32(uint256(uint160(address(hub)))));
    }

    /// The hub's exit by a stranger pays the owner's withdrawal address (no mark above which to charge).
    function _hubPaysTheWithdrawalAddress() internal {
        usdc.mint(address(hub), 1_000e6);
        vm.prank(stranger);
        hub.exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), 1_000e6);
    }
}
