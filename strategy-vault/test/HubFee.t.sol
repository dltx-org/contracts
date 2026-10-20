// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {walletCred} from "./mocks/Mocks.sol";

import {Vm} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {StrategyHubFee} from "../src/StrategyHubFee.sol";
import {StrategyHubState} from "../src/StrategyHubState.sol";
import {VaultState} from "../src/VaultBase.sol";
import {FeeMath} from "../src/lib/FeeMath.sol";
import {PriceSource} from "../src/lib/PriceSource.sol";
import {Assets, Holding, LegConfig, Legs, OwnerMessages, ParamsTypes, StrategyConfig} from "../src/lib/VaultTypes.sol";
import {TestLeg, TestLegExit} from "./mocks/TestLeg.sol";

/*
 * Amendment 2b's performance fee on the hub (§3.2–§3.9, the tests of §9 and Codex's scenarios of §13), in
 * the unit world: the hub on HyperEVM beside a test-only leg L (an ETH position and a signed USD position
 * of its own, `trade` its counted market call, `liquidate` a third party's move), and a second test leg R
 * on Arbitrum, whose figures reach the hub by its REPORT (played here as Circle's relay). ETH / USD is the
 * unit world's Chainlink double (8 decimals, a round per `_ethPrice`), the sequencer is up. The fee
 * address is DLTX's treasury, accepted in the registry. Amounts are USDC units (6 decimals).
 */
contract HubFeeTest is Fixture {
    TestLegExit tExit;
    TestLeg code;
    StrategyHub hub;
    StrategyHubFee fee; // the hub, through its fee module's functions
    TestLeg L; // link 0, beside the hub
    address R; // link 1, on Arbitrum
    address treasury = makeAddr("dltx-treasury");
    uint256 seq;
    uint256 nonce;

    function setUp() public {
        _world();
        tExit = new TestLegExit();
        code = new TestLeg(address(tExit), address(tExit).codehash);
        address[] memory at = _make(_d(HYPEREVM_DOMAIN, ARB_DOMAIN), Legs.VALUE_READ);
        hub = StrategyHub(at[0]);
        fee = StrategyHubFee(at[0]);
        L = TestLeg(payable(at[1]));
        R = at[2];
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
    }

    // ── the world ────────────────────────────────────────────────────────────────────────────────────

    function _d(uint32 a, uint32 b) internal pure returns (uint32[] memory d) {
        d = new uint32[](2);
        (d[0], d[1]) = (a, b);
    }

    /// A combination of test legs with the hub here; a remote leg pinned `remoteKind`. Returns every
    /// member's address (0 the hub).
    function _make(uint32[] memory legDomains, uint8 remoteKind) internal returns (address[] memory at) {
        CombinationFactory.LegPin[] memory p = new CombinationFactory.LegPin[](legDomains.length);
        for (uint256 i; i < legDomains.length; ++i) {
            p[i] = CombinationFactory.LegPin(
                address(code),
                address(code).codehash,
                legDomains[i],
                i == 0 ? Legs.LONG : Legs.SHORT,
                legDomains[i] == HYPEREVM_DOMAIN ? Legs.VALUE_READ : remoteKind
            , "TestLeg", "uint256 seven", 1);
        }
        uint32[] memory hubs = new uint32[](1);
        hubs[0] = HYPEREVM_DOMAIN;
        CombinationFactory f = _factoryWith(hubs, p);
        StrategyConfig memory c;
        c.factory = address(f);
        c.hubDomain = HYPEREVM_DOMAIN;
        c.hubParams = abi.encode(_hubParams());
        c.legs = new LegConfig[](legDomains.length);
        for (uint256 i; i < legDomains.length; ++i) {
            c.legs[i] = LegConfig(address(code), legDomains[i], p[i].role, abi.encode(uint256(7)));
        }
        uint256 deadline = block.timestamp + 1 days;
        f.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline));
        (at,) = f.memberAddresses(STRATEGY, address(owner), c);
    }

    function _b(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
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

    function _r(uint80 round) internal pure returns (uint80[] memory r) {
        r = new uint80[](1);
        r[0] = round;
    }

    function _h(int256 usd6, int256 eth18) internal pure returns (Holding[] memory h) {
        h = new Holding[](2);
        h[0] = Holding(Assets.USD, usd6 * 1e12);
        h[1] = Holding(Assets.ETH, eth18);
    }

    /// R's report as Circle relays it: observed now (or at `observedAt`), its counters toward the hub.
    function _report(Holding[] memory h, uint256 sentToHub, uint256 fromHub, uint256 observedAt, uint256 lastMove)
        internal
    {
        uint256[4] memory sent;
        uint256[4] memory received;
        uint256[4] memory fees;
        (sent[0], received[0]) = (sentToHub, fromHub);
        bytes memory body = abi.encode(
            keccak256("dltx.strategy-vault.report.v1"), ++seq, observedAt, vm.getBlockNumber(), lastMove, h, sent, received, fees
        );
        transmitter.deliver(address(hub), ARB_DOMAIN, _b(R), body);
    }

    function _report(int256 usd6, int256 eth18) internal {
        _report(_h(usd6, eth18), 0, 0, _now(), 0);
    }

    function _report(int256 usd6, int256 eth18, uint256 sentToHub, uint256 fromHub) internal {
        _report(_h(usd6, eth18), sentToHub, fromHub, _now(), 0);
    }

    function _snap() internal {
        vm.prank(key);
        fee.snapshot();
    }

    /// A snapshot now, then R's report 90 s later: a usable value.
    function _instant(int256 rUsd, int256 rEth, uint256 sentToHub, uint256 fromHub) internal {
        _snap();
        _warp(90);
        _report(rUsd, rEth, sentToHub, fromHub);
    }

    function _value() internal view returns (bool ok, int256 v, bytes32 why) {
        return fee.value(_r());
    }

    function _assertRefused(bytes4 why) internal view {
        (bool ok, int256 v, bytes32 w) = _value();
        assertFalse(ok, "refused");
        assertEq(v, 0);
        assertEq(bytes4(w), why, "the reason");
    }

    function _crystallize() internal {
        vm.prank(key);
        fee.crystallize(_r());
    }

    function _payout(uint256 amount) internal {
        vm.prank(key);
        fee.payout(amount, _r());
    }

    function _send(uint8 k, uint256 amount) internal {
        vm.prank(key);
        hub.send(k, amount, false, 0);
    }

    /// L's USDC back to the hub (its own `send`, a member move).
    function _back(uint256 amount) internal {
        vm.prank(key);
        L.send(0, amount, false, 0);
    }

    /// The hub funded by the deposit contract's plain transfer.
    function _fund(uint256 amount) internal {
        usdc.mint(address(hub), amount);
    }

    /// The strategy of §3.4's worked example: mark $10,000; L +4 ETH, −5,000 + 200 USD, $120 of it
    /// brought back to the hub for the fee; R's report +14,920 USD, −4 ETH; ETH $2,500: $10,120.
    function _workedExample() internal {
        _fund(10_000e6);
        _send(0, 10_000e6);
        L.trade(4e18, -14_800e6);
        _back(120e6);
    }

    function _beginExit() internal {
        uint256 deadline = _now() + 1 hours;
        hub.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
    }

    /// The recovery key sets the rate.
    function _rate(uint16 bp) internal {
        vm.prank(recovery);
        fee.setFeeRate(bp);
    }

    // ── §3.3: the mark and capital ───────────────────────────────────────────────────────────────────

    /// A deposit by plain transfer, and a donation, raise the mark: never charged. Moves between members
    /// don't move it; `payout` lowers it by the amount; a loss leaves it.
    function test_mark_capitalIn_memberMoves_payout_loss() public {
        _fund(1_000e6);
        assertEq(hub.mark(), 0, "not synced yet");
        (,,, int256 markSynced,,,,) = fee.preview(_r());
        assertEq(markSynced, 1_000e6, "the views count an unsynced deposit into the mark");
        vm.expectEmit(address(hub));
        emit StrategyHubState.CapitalIn(1_000e6);
        _send(0, 600e6);
        assertEq(hub.mark(), 1_000e6);
        usdc.mint(address(hub), 25e6); // a stranger's donation: capital too
        _back(200e6); // a member move back: not capital
        _payout(0);
        assertEq(hub.mark(), 1_025e6);
        assertEq(hub.booked(), 625e6);
        L.trade(0, -300e6); // a loss in the leg
        _payout(100e6);
        assertEq(hub.mark(), 925e6, "the payout, not the loss");
        assertEq(usdc.balanceOf(address(owner)), 100e6);
    }

    /// A balance below `booked` (a token-level event) is re-based, never booked to the mark; a later
    /// deposit is then counted in full.
    function test_sync_rebase_thenADepositFullyCounted() public {
        _fund(1_000e6);
        _payout(0);
        usdc.burn(address(hub), 100e6);
        _payout(0);
        assertEq(hub.booked(), 900e6);
        assertEq(hub.mark(), 1_000e6, "not a capital change");
        _fund(50e6);
        _payout(0);
        assertEq(hub.mark(), 1_050e6);
    }

    // ── §3.4: the value ──────────────────────────────────────────────────────────────────────────────

    /// The worked example, then §3.5's: three days after the last fee the cap allows $150, above the $120
    /// of profit: `crystallize` charges 15 % × 120 = $18 (mark $10,102); `payout(102)` (the fee deferred:
    /// one a day) brings the strategy back to its starting value.
    function test_workedExample_value_eighteenDollars_payout() public {
        _workedExample();
        _warp(3 days);
        _ethPrice(2_500e8);
        _instant(14_920e6, -4e18, 0, 0);
        (bool ok, int256 v,) = _value();
        assertTrue(ok);
        assertEq(v, 10_120e6);
        (, bytes32 why,,, uint256 profit, uint256 capped, uint256 f, uint256 at) = fee.preview(_r());
        assertEq(why, bytes32(0));
        assertEq(profit, 120e6);
        assertEq(capped, 120e6);
        assertEq(f, 18e6, "preview: what crystallize will charge");
        assertLe(at, _now());
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 18e6, "to the cent");
        assertEq(hub.mark(), 10_102e6);
        assertEq(hub.lastFeeAt(), _now());
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeDeferred(StrategyHubState.TooSoon.selector);
        _payout(102e6);
        assertEq(hub.mark(), 10_000e6);
        (ok, v,) = _value();
        assertEq(v, 10_000e6, "back to the starting value");
    }

    /// One day after creation the cap is $50 of a $10,000 mark: $7.50, the rest above the mark.
    function test_crystallize_oneDayLater_capped() public {
        _workedExample();
        _warp(1 days - 90); // the charge lands exactly a day after creation
        _ethPrice(2_500e8);
        _instant(14_920e6, -4e18, 0, 0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 7.5e6);
        assertEq(hub.mark(), 10_042.5e6);
    }

    /// The Hyperliquid leg's report, as the probe's formula reads it in both modes: standard (all cash in
    /// `rawUsd`) and unified (the free cash on spot, 0x801's available amount), the same value; its ETH at
    /// the pinned source. (The probe recorded its totals, 31.402812 at F08; not its components.)
    function test_value_hyperliquidReport_standardAndUnified() public {
        _ethPrice(2_500e8);
        int256 szi = -0.0047e18;
        // standard: rawUsd = value + |szi| × P
        _instant(31_402_812 + 11_750_000, szi, 0, 0);
        (, int256 standard,) = _value();
        // unified: $20 of the cash on spot; the report's USD is rawUsd + spot
        _warp(20 minutes);
        _ethPrice(2_500e8);
        _snap();
        _warp(90);
        Holding[] memory h = _h((31_402_812 + 11_750_000 - 20e6) + 20e6, szi);
        _report(h, 0, 0, _now(), 0);
        (, int256 unified,) = _value();
        assertEq(standard, 31_402_812, "rawUsd + szi x P + spot, at one price");
        assertEq(unified, standard);
    }

    /// The pair terms (2a §3.6, the probe's F08 and F12 cases): the hub's $100 burn to R, Circle's fee
    /// $0.014; then R's $50 burn back. Whatever the age of each side's figures, every dollar counts once.
    function test_value_pairInFlight_bothArrivalOrders() public {
        _fund(1_000e6);
        _deliverReady(address(hub), ARB_DOMAIN, R);
        _send(1, 100e6);
        _ethPrice(2_500e8);
        // R's report from before the mint: the term carries the burn
        _instant(0, 0, 0, 0);
        (, int256 inFlight,) = _value();
        assertEq(inFlight, 1_000e6);
        // R's report after the mint: it holds it net of Circle's fee
        _warp(10 minutes);
        _instant(100e6 - 0.014e6, 0, 0, 100e6);
        (, int256 landed,) = _value();
        assertEq(landed, 1_000e6 - 0.014e6, "only Circle's fee, a cost");
        // R burns $50 back; the hub's mint lands before R's next report: the term is negative
        _warp(10 minutes);
        hub.receiveMint(_mint(ARB_DOMAIN, address(hub), 50e6, R, 0), "");
        _instant(100e6 - 0.014e6, 0, 0, 100e6); // R's figures older than the hub's
        (, int256 negative,) = _value();
        assertEq(negative, landed, "the negative term cancels the double count");
        // R's report that saw the burn
        _warp(10 minutes);
        _instant(50e6 - 0.014e6, 0, 50e6, 100e6);
        (, int256 settled,) = _value();
        assertEq(settled, landed);
    }

    function _mint(uint32 source, address recipient, uint256 amount, address from, uint256 f)
        internal
        returns (bytes memory)
    {
        bytes memory header = abi.encodePacked(
            uint32(1), source, HYPEREVM_DOMAIN, bytes32(++nonce), _b(TOKEN_MESSENGER), _b(TOKEN_MESSENGER), _b(recipient), uint32(2000), uint32(2000)
        );
        bytes memory body =
            abi.encodePacked(uint32(1), _b(USDC), _b(recipient), amount, _b(from), uint256(f), uint256(f), uint256(0));
        return bytes.concat(header, body);
    }

    /// Every product and quotient toward −∞: a wei of ETH owed is a whole USDC unit off the value.
    function test_value_roundsTowardMinusInfinity() public {
        _fund(5e6);
        _payout(0);
        L.trade(-1, 0);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        (, int256 v,) = _value();
        assertEq(v, 5e6 - 1);
    }

    // ── the value's refusals ─────────────────────────────────────────────────────────────────────────

    function test_value_refused_noSnapshot_staleSnapshot() public {
        _assertRefused(StrategyHubState.NoSnapshot.selector);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        (bool ok,,) = _value();
        assertTrue(ok);
        _warp(10 minutes - 90 + 1);
        _assertRefused(StrategyHubState.NoSnapshot.selector);
    }

    function test_value_refused_staleReport_noReport() public {
        _ethPrice(2_500e8);
        _snap();
        _warp(90);
        _assertRefused(StrategyHubState.StaleReport.selector); // none yet
        _report(0, 0);
        _warp(10 minutes + 1);
        _assertRefused(StrategyHubState.StaleReport.selector);
    }

    /// A report from the future is refused, so a forgery can't stay fresh for ever.
    function test_value_refused_futureReport() public {
        _ethPrice(2_500e8);
        _snap();
        _warp(30);
        _report(_h(0, 0), 0, 0, _now() + 61, 0);
        _assertRefused(StrategyHubState.FutureReport.selector);
    }

    /// A report taken within 3 blocks of the leg's move between HyperEVM and HyperCore is refused.
    function test_value_refused_moveSettling() public {
        _ethPrice(2_500e8);
        _snap();
        _warp(90);
        _report(_h(0, 0), 0, 0, _now(), vm.getBlockNumber() - 2);
        _assertRefused(StrategyHubState.MoveSettling.selector);
        _report(_h(0, 0), 0, 0, _now(), vm.getBlockNumber() - 3);
        (bool ok,,) = _value();
        assertTrue(ok, "3 blocks after: settled");
    }

    function test_value_refused_unknownAsset() public {
        _ethPrice(2_500e8);
        _snap();
        _warp(90);
        Holding[] memory h = new Holding[](1);
        h[0] = Holding(keccak256("dltx.asset.BTC"), 1e18);
        _report(h, 0, 0, _now(), 0);
        _assertRefused(StrategyHubState.UnknownAsset.selector);
    }

    /// 2b values only what is read on chain: a leg whose value DLTX reports refuses the value.
    function test_value_refused_reportedValueLeg() public {
        address[] memory at = _make(_d(HYPEREVM_DOMAIN, 0), Legs.VALUE_REPORTED);
        StrategyHubFee h = StrategyHubFee(at[0]);
        assertEq(StrategyHub(at[0]).legValueKind(1), Legs.VALUE_REPORTED);
        vm.prank(key);
        h.snapshot();
        (bool ok,, bytes32 why) = h.value(_r());
        assertFalse(ok);
        assertEq(bytes4(why), StrategyHubState.ReportedValue.selector);
    }

    /// At most one leg off the hub's chain in 2b.
    function test_value_refused_twoRemoteLegs() public {
        uint32[] memory d = new uint32[](3);
        (d[0], d[1], d[2]) = (HYPEREVM_DOMAIN, ARB_DOMAIN, 0);
        address[] memory at = _make(d, Legs.VALUE_READ);
        StrategyHubFee h = StrategyHubFee(at[0]);
        vm.prank(key);
        h.snapshot();
        (bool ok,, bytes32 why) = h.value(_r());
        assertFalse(ok);
        assertEq(bytes4(why), StrategyHubState.TooManyRemote.selector);
    }

    /// A leg beside the hub whose position its own calls don't account for (the Hyperliquid account,
    /// traded by its agent) can't be recorded: the snapshot is refused.
    function test_snapshot_refused_untrackedLeg() public {
        uint32[] memory hubs = new uint32[](1);
        hubs[0] = HYPEREVM_DOMAIN;
        CombinationFactory f = _factoryWith(hubs, _pins());
        StrategyConfig memory c = _config();
        c.factory = address(f);
        c.hubDomain = HYPEREVM_DOMAIN;
        uint256 deadline = _now() + 1 days;
        address[] memory made = f.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline));
        vm.prank(key);
        vm.expectRevert(StrategyHubState.UntrackedLeg.selector);
        StrategyHubFee(made[0]).snapshot();
    }

    // ── §3.8: the price hints, the sequencer ─────────────────────────────────────────────────────────

    /// Codex's fifth round, exactly: the snapshot at ETH $2,500 (L long 1 ETH; R short −1 ETH with $1,000
    /// of margin: $3,500); ETH to $2,400; R closes for $1,100 before its report; L untouched. At the
    /// report's instant the value is $3,500 and no fee is charged; the snapshot's round is refused.
    function test_codexFifthRound_oneInstant_noFictitiousProfit() public {
        _fund(3_500e6);
        _deliverReady(address(hub), ARB_DOMAIN, R);
        _send(0, 2_500e6);
        _send(1, 1_000e6);
        L.trade(1e18, -2_500e6);
        _warp(2 days);
        uint80 atSnapshot = _ethPrice(2_500e8);
        _snap();
        _warp(30);
        uint80 atReport = _ethPrice(2_400e8);
        _warp(60);
        _report(1_100e6, 0, 0, 1_000e6); // closed before its report
        (bool ok, int256 v,) = fee.value(_r(atReport));
        assertTrue(ok);
        assertEq(v, 3_500e6, "the truth");
        bytes32 why;
        (ok,, why) = fee.value(_r(atSnapshot));
        assertFalse(ok, "the snapshot's price would read $3,600");
        assertEq(bytes4(why), PriceSource.BadRound.selector);
        vm.prank(key);
        fee.crystallize(_r(atReport));
        assertEq(usdc.balanceOf(treasury), 0, "no fee");
        assertEq(hub.mark(), 3_500e6);
    }

    function test_priceHints_beforeAfter_stale_latest() public {
        _ethPrice(2_500e8);
        _snap();
        _warp(30);
        uint80 inEffect = _ethPrice(2_510e8);
        _warp(60);
        _report(0, 0);
        _warp(5);
        uint80 after_ = _ethPrice(2_520e8);
        (bool ok,, bytes32 why) = fee.value(_r(inEffect - 1));
        assertEq(bytes4(why), PriceSource.BadRound.selector, "a round before the one in effect");
        (ok,, why) = fee.value(_r(after_));
        assertEq(bytes4(why), PriceSource.BadRound.selector, "a round after");
        (ok,,) = fee.value(_r(inEffect));
        assertTrue(ok);
        (ok,, why) = fee.value(new uint80[](0));
        assertEq(bytes4(why), PriceSource.BadRound.selector, "one hint per feed");
        // older than maxAge at t_r refused: fresh at the snapshot, past the hour at the report's instant
        _warp(1 hours - 1);
        _snap();
        _warp(90);
        _report(0, 0);
        (ok,, why) = fee.value(_r(after_));
        assertEq(bytes4(why), PriceSource.StalePrice.selector, "older than the pin's hour at t_r");
        // the latest round accepted when none later exists
        uint80 latest = _ethPrice(2_530e8);
        _snap();
        _warp(90);
        _report(0, 0);
        (ok,,) = fee.value(_r(latest));
        assertTrue(ok, "the latest round");
    }

    /// The sequencer down refuses the snapshot itself; restarted within the grace hour before t_r, the
    /// value.
    function test_sequencer_down_refusesSnapshot_andValue() public {
        _ethPrice(2_500e8);
        seqFeed.setStatus(seqFeed.id(1, 2), 1, _now()); // down
        vm.prank(key);
        vm.expectRevert(PriceSource.SequencerDown.selector);
        fee.snapshot();
        seqFeed.setStatus(seqFeed.id(1, 3), 0, _now() - 2 hours);
        _snap();
        _warp(90);
        _report(0, 0);
        (bool ok,,) = _value();
        assertTrue(ok);
        seqFeed.setStatus(seqFeed.id(1, 4), 0, _now() - 10 minutes); // restarted since t_r − 1 hour
        _assertRefused(PriceSource.SequencerDown.selector);
    }

    /// A stale price refuses the snapshot itself (§9), as the sequencer down does.
    function test_snapshot_refused_stalePrice() public {
        _warp(1 hours + 1); // the fixture's round is now older than the pin's hour
        vm.prank(key);
        vm.expectRevert(PriceSource.StalePrice.selector);
        fee.snapshot();
        _ethPrice(2_500e8);
        _snap();
    }

    /// Whatever a forged report claims (any holdings, any counters), `payout` pays and never reverts
    /// (decision 51): the fee is charged within its bound or deferred.
    function testFuzz_payout_neverRevertsOnAForgedReport(int256 usd, int256 eth, uint256 sent, uint256 received, bytes32 asset)
        public
    {
        _fund(10_000e6);
        _send(0, 5_000e6);
        _warp(3 days);
        _ethPrice(2_500e8);
        _snap();
        _warp(90);
        Holding[] memory h = new Holding[](2);
        h[0] = Holding(Assets.USD, usd);
        h[1] = Holding(uint256(asset) % 2 == 0 ? Assets.ETH : asset, eth);
        _report(h, sent, received, _now(), 0);
        _payout(1_000e6);
        assertEq(usdc.balanceOf(address(owner)), 1_000e6, "paid");
        assertLe(usdc.balanceOf(treasury), 10_000e6 * 50 * 4 / 10_000 * 1_500 / 10_000, "within the cap (3 days and 90 s)");
    }

    // ── §3.4: the snapshot's instant ─────────────────────────────────────────────────────────────────

    /// A remote report observed BEFORE the snapshot never completes it, however recent; nor one outside 1
    /// to 3 minutes after.
    function test_snapshot_reportMustFollowItWithinTheWindow() public {
        _ethPrice(2_500e8);
        _report(0, 0);
        _warp(1);
        _snap();
        _assertRefused(StrategyHubState.SnapshotIncomplete.selector);
        _warp(59);
        _report(0, 0);
        _assertRefused(StrategyHubState.SnapshotIncomplete.selector); // 59 s after
        _warp(1);
        _report(0, 0);
        (bool ok,,) = _value();
        assertTrue(ok, "60 s after");
        _warp(120);
        _report(0, 0);
        (ok,,) = _value();
        assertTrue(ok, "180 s after");
        _warp(1);
        _report(0, 0);
        _assertRefused(StrategyHubState.SnapshotIncomplete.selector);
    }

    /// Codex's third round: R's report at t − 60 s, both legs closed at t − 30 s with the price down, the
    /// snapshot at t: the old report can't complete it, so no fee on a position that no longer exists.
    function test_codexThirdRound_closeBetweenReportAndSnapshot() public {
        _fund(3_500e6);
        _send(0, 2_500e6);
        L.trade(1e18, -2_500e6);
        _warp(2 days);
        _ethPrice(2_600e8);
        _report(3_600e6, -1e18); // R short at $2,600, $1,000 of margin
        _warp(30);
        L.trade(-1e18, 2_500e6); // both closed at $2,500
        _ethPrice(2_500e8);
        _warp(30);
        _snap();
        _assertRefused(StrategyHubState.SnapshotIncomplete.selector);
        vm.prank(key);
        vm.expectRevert(StrategyHubState.SnapshotIncomplete.selector);
        fee.crystallize(_r());
    }

    /// Codex's fourth round: a leg beside the hub that sells and buys back the same ETH between the
    /// snapshot and the charge is refused by its operation count, its quantities equal.
    function test_snapshot_sellAndBuyBack_refusedByOpCount() public {
        L.trade(1e18, 0);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        L.trade(-1e18, 1_000e6);
        L.trade(1e18, -1_010e6);
        assertEq(L.eth(), 1e18, "the same ETH");
        _assertRefused(StrategyHubState.PositionMoved.selector);
    }

    /// What no call of the leg does — a liquidation — is caught by the 1 bp re-read; an aToken's interest
    /// within 1 bp, and a move between members, are not refused.
    function test_snapshot_liquidationRefused_interestAndMemberMovesNot() public {
        _fund(1_000e6);
        _send(0, 500e6);
        L.trade(4e18, 0);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        (, int256 before,) = _value();
        L.liquidate(0.0004e18 - 1); // within 1 bp of 4 ETH
        (bool ok,,) = _value();
        assertTrue(ok, "interest-sized");
        _send(0, 100e6); // a member move: counted by the pair terms, no operation
        _back(40e6);
        (bool ok2, int256 after_,) = _value();
        assertTrue(ok2);
        assertEq(after_, before, "the moves count once; the snapshot's quantities are the value's");
        L.liquidate(-1e18);
        _assertRefused(StrategyHubState.PositionMoved.selector);
    }

    /// Both legs closed after R's report, then the price moved: the value stays at the report's instant
    /// (L's close is an operation, refused; R's after its report doesn't count), no fictitious profit.
    function test_snapshot_closedAfterReport_priceMoved_noFictitiousProfit() public {
        _fund(3_500e6);
        _deliverReady(address(hub), ARB_DOMAIN, R);
        _send(0, 2_500e6);
        _send(1, 1_000e6);
        L.trade(1e18, -2_500e6);
        _warp(2 days);
        uint80 r0 = _ethPrice(2_500e8);
        _instant(3_500e6, -1e18, 0, 1_000e6);
        (, int256 v,) = fee.value(_r(r0));
        assertEq(v, 3_500e6);
        _warp(10);
        _ethPrice(2_000e8); // after t_r: never the round in effect at it
        (bool ok,, bytes32 why) = _value();
        assertEq(bytes4(why), PriceSource.BadRound.selector);
        (ok, v,) = fee.value(_r(r0));
        assertEq(v, 3_500e6, "still the instant's");
        L.trade(-1e18, 2_000e6); // L closes at $2,000
        (ok,, why) = fee.value(_r(r0));
        assertEq(bytes4(why), StrategyHubState.PositionMoved.selector);
    }

    // ── §3.5: crystallize ────────────────────────────────────────────────────────────────────────────

    function test_crystallize_executionKeyOnly_tooSoon() public {
        vm.expectRevert(VaultState.NotExecution.selector);
        fee.crystallize(_r());
        vm.prank(key);
        vm.expectRevert(StrategyHubState.TooSoon.selector);
        fee.crystallize(_r());
    }

    /// After a day with no new profit: nothing charged, `lastFeeAt` unchanged; a negative value too.
    function test_crystallize_noProfit_negativeValue_changeNothing() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        uint64 created = hub.lastFeeAt();
        _warp(2 days);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        vm.recordLogs();
        _crystallize();
        assertEq(hub.mark(), 1_000e6);
        assertEq(hub.lastFeeAt(), created);
        L.trade(0, -3_000e6);
        _warp(1 days);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        (, int256 v,) = _value();
        assertLt(v, 0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(hub.lastFeeAt(), created);
    }

    /// A positive profit whose fee rounds to zero leaves the mark and `lastFeeAt`; a later, larger profit
    /// is charged in full.
    function test_crystallize_subUnitFee_thenChargedInFull() public {
        _fund(10_000e6);
        _send(0, 9_900e6);
        uint64 created = hub.lastFeeAt();
        _warp(2 days);
        _ethPrice(2_500e8);
        L.trade(0, 6);
        _instant(0, 0, 0, 0);
        _crystallize();
        assertEq(hub.mark(), 10_000e6);
        assertEq(hub.lastFeeAt(), created);
        L.trade(0, 40e6 - 6);
        _warp(1 days);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 6e6, "15 % of the whole $40");
        assertEq(hub.mark(), 10_034e6);
    }

    /// With no fee address the charge is deferred: the mark stays, the profit stays above it.
    function test_crystallize_noFeeAddress_defers() public {
        _noFeeAddress();
        _workedExample();
        _warp(3 days);
        _ethPrice(2_500e8);
        _instant(14_920e6, -4e18, 0, 0);
        (, bytes32 why,,,,, uint256 f,) = fee.preview(_r());
        assertEq(bytes4(why), StrategyHubState.NoFeeAddress.selector);
        assertEq(f, 0);
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeDeferred(StrategyHubState.NoFeeAddress.selector);
        _crystallize();
        assertEq(hub.mark(), 10_000e6);
    }

    /// Replaces the registry with one that never accepted a fee address (the registry's address is
    /// constant per chain; here its storage slot is cleared).
    function _noFeeAddress() internal {
        bytes32 slot = bytes32(uint256(_feeAddressSlot()));
        vm.store(address(registry), slot, bytes32(0));
        assertEq(registry.feeAddress(), address(0));
    }

    function _feeAddressSlot() internal view returns (uint256 s) {
        for (; s < 16; ++s) {
            if (vm.load(address(registry), bytes32(s)) == _b(treasury)) return s;
        }
        revert("fee address slot");
    }

    /// The daily cap and its 7-day window on the MARK: a forged report inflating R's holdings is capped
    /// to 0.525 % of the mark after 100 idle days, whatever it claims and however much USDC the hub
    /// holds; the excess is never charged once the forgery is gone.
    function test_crystallize_forgedReport_cappedOnTheMark() public {
        _fund(30_000e6); // the hub holds plenty: a drain would find it
        _send(0, 10_000e6);
        // mark 30,000; real value 30,000
        _warp(100 days);
        _ethPrice(2_500e8);
        _instant(int256(uint256(type(uint120).max) / 1e12), 0, 0, 0); // forged: a huge USD holding
        _crystallize();
        uint256 taken = usdc.balanceOf(treasury);
        assertEq(taken, 30_000e6 * 50 * 7 / 10_000 * 1_500 / 10_000, "15 % x 0.5 % x 7 days of the mark");
        assertEq(taken, 157.5e6, "0.525 % of $30,000");
        // the forgery gone: the real value is below the new mark, nothing more
        _warp(1 days);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), taken, "the excess never charged");
    }

    /// A mark at or below zero (payouts deferred beyond the capital) caps every charge at zero: the fee
    /// waits for the exit.
    function test_crystallize_markBelowZero_chargesNothing() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        usdc.mint(address(L), 100e6); // $100 of profit, in cash
        _back(1_050e6);
        _payout(1_050e6); // within the first day: the fee deferred
        assertEq(hub.mark(), -50e6);
        _warp(2 days);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        (, int256 v,) = _value();
        assertEq(v, 50e6);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 0);
    }

    /// The hub short of USDC for the fee: `crystallize` refuses (`NeedUsdc`).
    function test_crystallize_needUsdc() public {
        _fund(10_000e6);
        _send(0, 10_000e6);
        L.trade(0, 120e6);
        _warp(3 days);
        _ethPrice(2_500e8);
        _instant(0, 0, 0, 0);
        vm.prank(key);
        vm.expectRevert(StrategyHubState.NeedUsdc.selector);
        fee.crystallize(_r());
    }

    /// A fee transfer refused (DLTX's address frozen by USDC's issuer) is set aside in `feeOwed`, outside
    /// the value; `claimFee` pays it later, to the fee address only.
    function test_crystallize_frozenFeeAddress_feeOwed_claimFee() public {
        _workedExample();
        _warp(3 days);
        _ethPrice(2_500e8);
        _instant(14_920e6, -4e18, 0, 0);
        usdc.setFrozen(treasury, true);
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeSetAside(18e6);
        _crystallize();
        assertEq(hub.feeOwed(), 18e6);
        assertEq(hub.mark(), 10_102e6);
        (, int256 v,) = _value();
        assertEq(v, 10_102e6, "the fee set aside is outside the value");
        hub.claimFee(); // still frozen: nothing, no revert
        assertEq(hub.feeOwed(), 18e6);
        usdc.setFrozen(treasury, false);
        vm.prank(stranger);
        hub.claimFee();
        assertEq(usdc.balanceOf(treasury), 18e6);
        assertEq(hub.feeOwed(), 0);
        assertEq(hub.booked(), 102e6);
    }

    // ── §3.5: payout ─────────────────────────────────────────────────────────────────────────────────

    /// It charges first when it can.
    function test_payout_chargesWhenItCan() public {
        _workedExample();
        _warp(3 days);
        _ethPrice(2_500e8);
        _instant(14_920e6, -4e18, 0, 0);
        _payout(100e6);
        assertEq(usdc.balanceOf(treasury), 18e6);
        assertEq(usdc.balanceOf(address(owner)), 100e6);
        assertEq(hub.mark(), 10_002e6);
    }

    /// It pays anyway on each reason it can't charge, and the profit above the mark stays for the next
    /// `crystallize`.
    function test_payout_defersOnEachReason_profitKept() public {
        _workedExample();
        // too soon (created less than a day ago)
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeDeferred(StrategyHubState.TooSoon.selector);
        _payout(1e6);
        _warp(3 days);
        _ethPrice(2_500e8);
        // the value refused: no snapshot
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeDeferred(StrategyHubState.NoSnapshot.selector);
        _payout(1e6);
        // the hub short of USDC for the amount and the fee together
        _instant(14_920e6, -4e18, 0, 0);
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeDeferred(StrategyHubState.NeedUsdc.selector);
        _payout(110e6);
        assertEq(hub.mark(), 10_000e6 - 112e6);
        (, int256 v,) = _value();
        assertEq(v - hub.mark(), 120e6, "the profit above the mark unchanged");
        assertEq(usdc.balanceOf(address(owner)), 112e6);
        // the next crystallize charges it
        _back(30e6);
        _instant(14_920e6, -4e18, 0, 0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 18e6);
    }

    function test_payout_noFeeAddress_paysAndDefers() public {
        _workedExample();
        _warp(3 days);
        _ethPrice(2_500e8);
        _instant(14_920e6, -4e18, 0, 0);
        _noFeeAddress();
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeDeferred(StrategyHubState.NoFeeAddress.selector);
        _payout(100e6);
        assertEq(usdc.balanceOf(address(owner)), 100e6);
    }

    function test_payout_amountAboveTheFreeUsdc_refused() public {
        _fund(10e6);
        vm.prank(key);
        vm.expectRevert(StrategyHubState.NeedUsdc.selector);
        fee.payout(11e6, _r());
    }

    // ── §3.6: the exit ───────────────────────────────────────────────────────────────────────────────

    /// A profitable exit paid over several steps charges rate × (realised − exitBase), whatever the order
    /// and size of the arrivals.
    function test_exit_profitable_severalSteps() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _beginExit();
        assertEq(hub.exitBase(), 1_000e6);
        usdc.mint(address(L), 200e6); // L's profit
        _legToHub(300e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), 300e6, "below the base: the owner first");
        _legToHub(800e6);
        hub.exitStep();
        _legToHub(100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 30e6, "15 % of the $200 above the base");
        assertEq(usdc.balanceOf(withdrawalTo), 1_170e6);
        assertEq(hub.exitPaid() + hub.exitFeePaid(), 1_200e6);
    }

    /// L's exit sends its USDC to the hub (a member move: booked, not capital).
    function _legToHub(uint256 amount) internal {
        vm.startPrank(address(L));
        usdc.approve(address(hub), amount);
        hub.receiveLocal(amount);
        vm.stopPrank();
    }

    function test_exit_losing_chargesNothing() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _beginExit();
        _legToHub(700e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(withdrawalTo), 700e6);
    }

    /// The escape hatch (the stopped group) charges the same; Circle and Chainlink down change nothing.
    function test_exit_escapeHatch_noCircle_noChainlink() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _warp(7 days);
        transmitter.setPaused(true);
        messenger.setPaused(true);
        ethFeed.setBroken(true);
        seqFeed.setBroken(true);
        vm.prank(stranger);
        hub.beginExitStopped();
        usdc.mint(address(L), 100e6);
        _legToHub(1_100e6);
        vm.prank(stranger);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 15e6);
        assertEq(usdc.balanceOf(withdrawalTo), 1_085e6);
    }

    /// A deposit arriving during the exit raises the base: never charged.
    function test_exit_depositRaisesTheBase() public {
        _fund(1_000e6);
        _beginExit();
        hub.exitStep();
        _fund(300e6);
        hub.exitStep();
        assertEq(hub.exitBase(), 1_300e6);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(withdrawalTo), 1_300e6);
    }

    /// A mark below zero (a payout deferred beyond the capital): never a reverted step, the due capped at
    /// the cash in hand. The independent reader's P1: deposit 1,000, profit 100, payout(1,050) deferred
    /// (mark −50), then losses; the exit realises 5: due 15 % × 55 = 8.25, capped at $5.
    function test_exit_markBelowZero_dueCappedAtCash() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        usdc.mint(address(L), 100e6);
        _back(1_050e6);
        _payout(1_050e6);
        assertEq(hub.mark(), -50e6);
        _beginExit();
        _legToHub(5e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 5e6, "8.25 due, capped at the cash");
        assertEq(usdc.balanceOf(withdrawalTo), 0);
        hub.exitStep(); // nothing in hand: no revert
    }

    /// DLTX's address frozen never blocks a step (the due set aside); with no fee address the owner gets
    /// every dollar, the forgiven due recorded, and an address accepted later collects none of it.
    function test_exit_frozenOrMissingFeeAddress_neverBlocks() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _beginExit();
        usdc.mint(address(L), 100e6);
        _legToHub(1_100e6);
        usdc.setFrozen(treasury, true);
        hub.exitStep();
        assertEq(hub.feeOwed(), 15e6);
        assertEq(hub.exitFeePaid(), 15e6);
        assertEq(usdc.balanceOf(withdrawalTo), 1_085e6);
        usdc.setFrozen(treasury, false);
        hub.claimFee();
        assertEq(usdc.balanceOf(treasury), 15e6);
        // no fee address
        _noFeeAddress();
        usdc.mint(address(L), 100e6);
        _legToHub(100e6);
        hub.exitStep();
        assertEq(hub.exitFeeForgiven(), 15e6);
        assertEq(usdc.balanceOf(withdrawalTo), 1_185e6, "every dollar to the owner");
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 15e6, "the forgiven part never collected");
    }

    /// In exit money only reaches the hub and leaves to the owner: its `send` is refused.
    function test_exit_sendRefused() public {
        _fund(1_000e6);
        _beginExit();
        vm.prank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        hub.send(0, 1e6, false, 0);
        vm.prank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        fee.crystallize(_r());
        vm.prank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        fee.payout(1, _r());
    }

    // ── §3.6, §3.7: the exit's rate checkpoint ───────────────────────────────────────────────────────

    /// Codex's third round: $100 above the base settled at 15 % ($15), the rate lowered to 5 %, another
    /// $100: $5. Then (fourth round) a $100 deposit: nothing.
    function test_exitCheckpoint_settledKeepsItsRate_depositChargedNothing() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _beginExit();
        usdc.mint(address(L), 100e6);
        _legToHub(1_100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 15e6);
        _rate(500);
        assertEq(hub.exitCheckDue(), 15e6);
        _fund(100e6); // a deposit, not profit
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 15e6, "a deposit after the checkpoint: nothing");
        usdc.mint(address(L), 100e6);
        _legToHub(100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 20e6, "5 % of the next $100");
    }

    /// The negative base −$50: with no rate change, $8.25 capped at $5; with the rate lowered to 5 %
    /// before any step, the old rate keeps the profit up to zero: 7.5 + 5 % × 5 = 7.75, capped at $5.
    function test_exitCheckpoint_negativeBase_loweringBeforeAnyStep() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        usdc.mint(address(L), 100e6);
        _back(1_050e6);
        _payout(1_050e6);
        _beginExit();
        _rate(500);
        assertEq(hub.exitCheckDue(), 7.5e6);
        assertEq(hub.exitFrom(), 0);
        _legToHub(5e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 5e6);
        usdc.mint(address(L), 100e6);
        _legToHub(100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 12.75e6, "7.5 + 5 % of 105");
    }

    /// Cash at the hub not yet stepped when the rate is lowered takes the new rate; several lowerings.
    function test_exitCheckpoint_unsteppedCash_severalLowerings() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _beginExit();
        _legToHub(1_000e6);
        hub.exitStep();
        usdc.mint(address(L), 300e6);
        _legToHub(100e6); // $100 of profit at the hub, not stepped
        _rate(1_000);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 10e6, "10 %, not 15 %");
        _rate(500);
        _rate(0);
        _legToHub(100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 10e6, "0 % on the last");
    }

    // ── the rate: the recovery key's, never above the rate the owner signed (the operator's decision,
    //    2026-10-16; the ceiling, the security review of the same day) ──────────────────────────────────

    /// Only the registry's recovery key; down at any time, back up to the signed rate, never above it.
    function test_rate_recoveryOnly_withinTheSignedRate() public {
        vm.prank(stranger);
        vm.expectRevert(VaultState.NotAllowed.selector);
        fee.setFeeRate(100);
        vm.prank(key); // DLTX's execution key can't
        vm.expectRevert(VaultState.NotAllowed.selector);
        fee.setFeeRate(100);
        vm.prank(address(owner)); // nor the owner
        vm.expectRevert(VaultState.NotAllowed.selector);
        fee.setFeeRate(100);
        assertEq(hub.signedFeeRateBp(), 1_500, "the owner's HubParams.feeRateBp");
        vm.startPrank(recovery);
        vm.expectRevert(StrategyHubState.BadRate.selector);
        fee.setFeeRate(1_501); // above what the owner signed
        vm.expectRevert(StrategyHubState.BadRate.selector);
        fee.setFeeRate(5_000);
        vm.stopPrank();
        vm.expectEmit(address(hub));
        emit StrategyHubState.FeeRateSet(1_500, 0, recovery);
        _rate(0);
        assertEq(hub.feeRateBp(), 0);
        _rate(1_500); // restored, up to the signed rate
        assertEq(hub.feeRateBp(), 1_500);
        // the owner's old `VaultAction` path is gone: action 5 is unsupported
        uint256 deadline = _now() + 1 hours;
        bytes memory sig = _actionSig(address(hub), 5, address(uint160(0)), 0, deadline);
        vm.expectRevert(VaultState.Unsupported.selector);
        hub.ownerAction(5, address(uint160(0)), walletCred(wallet), deadline, sig);
    }

    /// A restored rate applies to every profit not yet charged, and only through `crystallize`'s cap: no
    /// charge at the moment of the change, so no instant drain on an inflated value (the review's
    /// finding 2).
    function test_rate_restore_appliesToUnchargedProfit_throughTheCap() public {
        _rate(500);
        _workedExample();
        _warp(3 days);
        _ethPrice(2_500e8);
        _instant(int256(uint256(type(uint120).max) / 1e12), -4e18, 0, 0); // a forged, inflated report
        _rate(1_500);
        assertEq(usdc.balanceOf(treasury), 0, "nothing charged by the change itself");
        assertEq(hub.mark(), 10_000e6);
        _back(1_000e6);
        _instant(int256(uint256(type(uint120).max) / 1e12), -4e18, 0, 0);
        _crystallize();
        // the cap: 0.5 % of the mark a day over 3 days = $150, at 15 %
        assertApproxEqAbs(usdc.balanceOf(treasury), 22.5e6, 0.1e6, "15 % of the capped profit");
    }

    /// In exit no rate goes up, not even back to the signed one: the profit already realised at the hub
    /// keeps the rate it had when the exit began, or a lower one.
    function test_rate_noRaiseInExit() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _rate(500);
        _beginExit();
        vm.startPrank(recovery);
        vm.expectRevert(StrategyHubState.BadRate.selector);
        fee.setFeeRate(1_500);
        vm.expectRevert(StrategyHubState.BadRate.selector);
        fee.setFeeRate(501);
        fee.setFeeRate(500); // the same rate: no raise
        vm.stopPrank();
        usdc.mint(address(L), 100e6);
        _legToHub(1_100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 5e6, "5 % of the $100");
    }

    // ── §3.9: the fee's one destination ──────────────────────────────────────────────────────────────

    /// From the hub only, to the address the registry of its own chain names at the moment of payment.
    function test_destination_theRegistrysFeeAddressAtPayment() public {
        _fund(1_000e6);
        _send(0, 1_000e6);
        _beginExit();
        usdc.mint(address(L), 200e6);
        _legToHub(1_100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(treasury), 15e6);
        address next = makeAddr("next-treasury");
        vm.prank(recovery);
        registry.proposeFeeAddress(next);
        _legToHub(100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(next), 0, "proposed is not accepted");
        assertEq(usdc.balanceOf(treasury), 30e6);
        vm.prank(next);
        registry.acceptFeeAddress();
        usdc.mint(address(L), 100e6);
        _legToHub(100e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(next), 15e6, "read at the moment of payment");
        assertEq(usdc.balanceOf(address(L)), 0);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    // ── creation ─────────────────────────────────────────────────────────────────────────────────────

    function test_creation_rateBound_pins_lastFeeAt() public {
        assertEq(hub.feeRateBp(), 1_500);
        assertEq(hub.lastFeeAt(), _now());
        assertEq(hub.sequencerFeed(), address(seqFeed));
        assertEq(hub.priceSources().length, 1);
        assertEq(hub.priceSources()[0].feed, address(ethFeed));
        assertEq(hub.legValueKind(0), Legs.VALUE_READ);
        bytes memory p = abi.encode(uint16(5), uint16(50), uint16(5_001));
        vm.expectRevert(StrategyHubState.BadParams.selector);
        hubCode.validateParams(p);
        hubCode.validateParams(abi.encode(uint16(5), uint16(50), uint16(5_000)));
    }

    /// The fee module runs only inside an initialized hub.
    function test_feeModule_delegatedOnly() public {
        vm.expectRevert(VaultState.NotAllowed.selector);
        hubFee.snapshot();
        vm.expectRevert(VaultState.NotAllowed.selector);
        StrategyHubFee(address(hubCode)).snapshot();
    }
}
