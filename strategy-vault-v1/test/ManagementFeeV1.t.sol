// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {FixtureV1} from "./FixtureV1.sol";
import {AaveV3AssetLegV2, HubV2} from "./MocksV1.sol";
import {Hub} from "../src/Hub.sol";
import {HubFee} from "../src/HubFee.sol";
import {HubState} from "../src/HubState.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {FeeMath} from "../src/lib/FeeMath.sol";
import {PriceSourcePin} from "../src/lib/PriceSource.sol";
import {Assets, Holding} from "../src/lib/VaultTypes.sol";
import {AssetProfile, HubParams, StrategySpec} from "../src/Types.sol";
import {MockERC20, walletCred} from "./mocks/Mocks.sol";

/*
 * Amendment 2e: version 1's MANAGEMENT FEE on the hub (§3, the tests of §7), in the unit Arbitrum world:
 * the hub beside the AAVE asset leg (empty here) and the Hyperliquid short on HyperEVM, whose report
 * carries a USD position. So the value is the hub's free USDC plus that position: a positive one is
 * profit above the mark, a negative one a loss. The fee address is DLTX's treasury. Amounts are USDC
 * units (6 decimals); every expected figure is computed by hand in the comment beside it.
 */
contract ManagementFeeV1Test is FixtureV1 {
    address treasury = makeAddr("dltx-treasury");
    Hub hub;
    HubFee fee; // the hub, through its fee module's functions
    address long;
    address short;
    uint64 seq;

    function setUp() public {
        _arbitrum();
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
    }

    // ── the world ────────────────────────────────────────────────────────────────────────────────────

    function _make(uint16 rateBp, uint32 flat) internal {
        AssetProfile memory p = _btc();
        StrategySpec memory c = _spec(
            manifest1,
            abi.encode(HubParams(btcProfile, 5, 50, 1500, rateBp, flat)),
            abi.encode(_longParams(p, btcProfile)),
            abi.encode(_shortParams(p, btcProfile))
        );
        address[] memory made = _create(c);
        hub = Hub(made[0]);
        fee = HubFee(made[0]);
        long = made[1];
        short = hub.links(1);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 dt) internal {
        vm.warp(_now() + dt);
        vm.roll(vm.getBlockNumber() + dt / 2 + 1);
    }

    function _fund(uint256 amount) internal {
        usdc.mint(address(hub), amount);
    }

    /// The hints: each price pin's latest round(s), in the pins' order.
    function _r() internal view returns (uint80[] memory r) {
        PriceSourcePin[] memory pins = hub.priceSources();
        uint256 n;
        for (uint256 i; i < pins.length; ++i) {
            n += pins[i].kind == 2 ? 2 : 1;
        }
        r = new uint80[](n);
        n = 0;
        for (uint256 i; i < pins.length; ++i) {
            r[n++] = _latest(pins[i].feed);
            if (pins[i].kind == 2) r[n++] = _latest(pins[i].baseFeed);
        }
    }

    function _latest(address feed) internal view returns (uint80 id) {
        (id,,,,) = btcUsd.latestRoundData();
        if (feed == address(wbtcBtc)) (id,,,,) = wbtcBtc.latestRoundData();
    }

    /// A usable value: the feeds refreshed, a snapshot now, the short's report (`usd` whole dollars of USD)
    /// 90 s later.
    function _value(int256 usd) internal {
        _feeds(_answer(btcUsd), _answer(wbtcBtc));
        vm.prank(key);
        fee.snapshot();
        _warp(90);
        Holding[] memory h = new Holding[](1);
        h[0] = Holding(Assets.USD, usd * 1e18);
        uint256[4] memory zero;
        bytes memory body = abi.encode(
            keccak256("dltx.strategy-vault.report.v1"), uint256(++seq), _now(), vm.getBlockNumber(), uint256(0), h, zero, zero, zero
        );
        transmitter.deliver(address(hub), HYPER, bytes32(uint256(uint160(short))), body);
    }

    function _crystallize() internal {
        uint80[] memory r = _r();
        vm.prank(key);
        fee.crystallize(r);
    }

    function _payout(uint256 amount) internal {
        uint80[] memory r = _r();
        vm.prank(key);
        fee.payout(amount, r);
    }

    function _sync() internal {
        _payout(0); // syncs the hub; the value is refused (no snapshot), so nothing is charged
    }

    function _mgmt()
        internal
        view
        returns (uint16 rate, uint16 signedRate, uint32 flat, uint32 signedFlat, uint64 from, uint64 window)
    {
        (rate, signedRate, flat, signedFlat, from, window,,,,,) = fee.managementFee();
    }

    function _beginExit() internal {
        uint256 deadline = _now() + 1 hours;
        MemberBase(address(hub)).beginExit(deadline, _beginExitSig(deadline));
    }

    function _exitStep() internal {
        vm.prank(stranger);
        hub.exitStep();
    }

    function _setMgmt(uint16 bp, uint32 flat) internal {
        vm.prank(recovery);
        fee.setManagementFee(bp, flat);
    }

    function _countEvents(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    // ── §3.7: the 0 case ─────────────────────────────────────────────────────────────────────────────

    /// Both at 0: no word written at creation, no management event in a full life (fund, crystallize,
    /// payout, exit), and nothing above 0 can ever be set (the ceilings are 0).
    function test_zero_noWordNoEventEver() public {
        _make(0, 0);
        (uint16 rate, uint16 signedRate, uint32 flat, uint32 signedFlat, uint64 from, uint64 window) = _mgmt();
        assertEq(uint256(rate) + signedRate + flat + signedFlat + from + window, 0, "the slot is never written");
        vm.recordLogs();
        _fund(10_000e6);
        _warp(2 days);
        _value(1_000);
        _crystallize();
        _payout(100e6);
        _beginExit();
        _exitStep();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, HubState.ManagementFeeCharged.selector), 0);
        assertEq(_countEvents(logs, HubState.ManagementFeeDeferred.selector), 0);
        assertEq(_countEvents(logs, HubState.ExitManagementSettled.selector), 0);
        (,,,, from, window) = _mgmt();
        assertEq(uint256(from) + window, 0);
        (,,,,,, int256 entry, uint256 paid, uint256 forgiven, int256 markStart, uint256 capitalIn) = fee.managementFee();
        assertEq(uint256(entry) + paid + forgiven + uint256(markStart) + capitalIn, 0, "all eleven values 0");
        vm.prank(recovery);
        vm.expectRevert(HubState.BadRate.selector);
        fee.setManagementFee(1, 0);
        vm.prank(recovery);
        vm.expectRevert(HubState.BadRate.selector);
        fee.setManagementFee(0, 1);
    }

    // ── §3.3: accrual ────────────────────────────────────────────────────────────────────────────────

    /// $100,000 for 30 days at 1 % a year and 10 USDC a month: 100,000 × 1 % × 30 / 365 = $82.191780
    /// (floored to the unit) + $10: $92.191780, to the fee address; the window restarts at the charge.
    function test_accrual_aMonth_bothKnobs_toTheUnit() public {
        _make(100, 10e6);
        _fund(100_000e6);
        _sync(); // the deposit restarts the window here
        uint256 t0 = _now();
        _warp(30 days - 90);
        _value(0);
        assertEq(_now(), t0 + 30 days);
        vm.expectEmit(address(hub));
        emit HubState.ManagementFeeCharged(100_000e6, 100_000e6, 100_000e6, 30 days, 92_191_780, 100, 10e6, uint64(_now() - 90), seq);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 92_191_780);
        assertEq(hub.mark(), 100_000e6, "the mark is not moved by the management fee");
        (,,,, uint64 from,) = _mgmt();
        assertEq(from, _now());
    }

    /// Each knob alone, a day and a year: rate 1 % on $36,500 a day = $1; flat 10 USDC a month a year =
    /// 10 × 365 / 30 = $121.666666.
    function test_accrual_eachKnobAlone() public {
        assertEq(FeeMath.mgmtFee(36_500e6, 1 days, 100, 0), 1e6);
        assertEq(FeeMath.mgmtFee(36_500e6, 365 days, 0, 10e6), 30_000_000, "a year accrues 90 days at most");
        assertEq(FeeMath.mgmtFee(36_500e6, 365 days, 100, 0), 90_000_000, "1 % of $36,500, 90 days: $90");
        assertEq(FeeMath.mgmtFee(36_500e6, 90 days, 0, 10e6), 30_000_000);
        assertEq(FeeMath.mgmtFee(36_500e6, 1 days, 0, 10e6), 333_333, "10 / 30, floored");
        assertEq(FeeMath.mgmtFee(36_500e6, 0, 100, 10e6), 0);
    }

    /// 100 idle days charge 90: $100,000 × 1 % × 90 / 365 = $246.575342, + 3 months of $10.
    function test_accrual_cappedAt90Days() public {
        _make(100, 10e6);
        _fund(100_000e6);
        _sync();
        _warp(100 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 246_575_342 + 30_000_000);
    }

    /// The flat part is at most 1 % of the base a month: a $500 strategy pays $5 a month, not $10.
    function test_accrual_flatCappedAtOnePercentOfTheBase() public {
        _make(0, 10e6);
        _fund(500e6);
        _sync();
        _warp(30 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 5e6);
    }

    /// A base of 0 (the value at or below 0) charges nothing, the flat part included, and forgives the
    /// idle time: the window restarts there.
    function test_accrual_baseZero_chargesNothing_restarts() public {
        _make(100, 10e6);
        _fund(1_000e6);
        _sync();
        _warp(40 days);
        _value(-1_000); // v = 1,000 − 1,000 = 0
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 0);
        (,,,, uint64 from,) = _mgmt();
        assertEq(from, _now(), "the idle time forgiven");
    }

    /// The reader's P1 (§3.3): $1,000 for 89 days unpaid, then $100,000 of Add money, a charge the next day
    /// takes the window's 90 days on the $1,000 only: $1,000 × 1 % × 90 / 365 = $2.465753, never $246; the
    /// new money is out of this window (from the next one on).
    function test_accrual_capitalArrivedIsOutOfTheWindow() public {
        _make(100, 0);
        _fund(1_000e6);
        _sync();
        _warp(89 days);
        _fund(100_000e6);
        _sync();
        _warp(1 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 2_465_753);
        // the next window holds all of it: a day on $101,000 less the fee just paid
        _warp(1 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 2_465_753 + 2_767_055); // $100,997.534247 × 1 % / 365, floored
    }

    /// Codex's P1 on the proportional window: in a loss, new capital never stands in for what was lost.
    /// $100,000 deposited, $99,000 lost, 89 days, $99,000 more deposited, a charge a day later: 90 days on
    /// the $1,000 left, $2.465753, never $122.53.
    function test_accrual_newCapitalNeverCoversALoss() public {
        _make(100, 0);
        _fund(100_000e6);
        _sync();
        usdc.burn(address(hub), 99_000e6); // the loss (the mark unmoved)
        _sync(); // `booked` re-based to the $1,000 left (else the next deposit would cancel the burn in it)
        _warp(89 days);
        _fund(99_000e6);
        _sync();
        _warp(1 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 2_465_753);
    }

    /// Codex's other P1: no deposit revives time beyond the 90 days. $100,000 for 180 days, $100,000 more
    /// just before the charge: 90 days on the first $100,000, $246.575342, never $493.15.
    function test_accrual_aDepositNeverRevivesTimeBeyond90Days() public {
        _make(100, 0);
        _fund(100_000e6);
        _sync();
        _warp(180 days);
        _fund(100_000e6);
        _sync();
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 246_575_342);
    }

    /// A payout during the window lowers its base (the value falls; the cap is the mark when it opened):
    /// $36,500, $18,250 paid out on day 10, the charge on day 30 takes 30 days on $18,250, $15.
    function test_accrual_aPayoutLowersTheWindowsBase() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days);
        _payout(18_250e6);
        _warp(20 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 15e6);
    }

    /// The capital-apart window's review (P2-1): a stranger's unit before the first deposit opens a window
    /// at a dust mark; the first charge, finding less than a unit due, opens the deposit's window, and the
    /// fee runs from there: $100,000 deposited, a day (the window opened at the first charge), then 30 days.
    function test_accrual_dustBeforeTheFirstDeposit_healsAtTheNextCharge() public {
        _make(100, 0);
        usdc.mint(address(hub), 1); // a stranger's dust
        _sync(); // the window opens at a mark of 1 unit
        _fund(100_000e6);
        _sync(); // the deposit: the window's capital
        _warp(1 days - 90);
        _value(0);
        _crystallize(); // less than a unit due on a base of 1 unit: the deposit's window opens here
        assertEq(usdc.balanceOf(treasury), 0);
        (,,,,,,,,, int256 markStart, uint256 capitalIn) = fee.managementFee();
        assertEq(markStart, 100_000e6 + 1);
        assertEq(capitalIn, 0);
        _warp(30 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 82_191_780, "30 days on $100,000 (and its unit)");
    }

    /// A strategy funded again after a full collect: the window with nothing in it opens at the new money.
    function test_accrual_fundedAgainAfterAFullCollect() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(2 days - 90);
        _value(0);
        _payout(36_498e6); // everything but the $2 the fee takes
        assertEq(usdc.balanceOf(treasury), 2e6);
        assertEq(usdc.balanceOf(address(hub)), 0);
        _warp(10 days);
        _fund(36_500e6);
        _sync();
        _warp(1 days - 90);
        _value(0);
        (,,,,,,,, uint256 accrued, uint256 due) = fee.preview(_r());
        _crystallize();
        // the window that held nothing (cap at the mark after the collect, the capital all new) charges 0
        // and opens the new money's window; preview said the same
        assertEq(accrued, 0);
        assertEq(due, 0);
        assertEq(usdc.balanceOf(treasury), 2e6);
        _warp(1 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 3e6, "then a day on $36,500");
    }

    /// The capital-apart window's review (P2-2): a payout lowers the window's cap with the mark, so a forged
    /// report raises the base to the mark at most: $100,000, $50,000 paid out, a +$50,000 forged report 90
    /// days later charges 90 days on $50,000, $123.287671, never on $100,000.
    function test_accrual_aPayoutLowersTheCap_forgedReportBoundedByTheMark() public {
        _make(100, 0);
        vm.prank(recovery);
        fee.setFeeRate(0);
        _fund(100_000e6);
        _sync();
        _payout(50_000e6);
        _warp(90 days - 90);
        _value(50_000); // forged
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 123_287_671);
    }

    /// A deposit paid back out before any valuation leaves the old money's accrual whole: $36,500 for 30
    /// days, $10,000 in then out, the charge takes 30 days on $36,500, $30.
    function test_accrual_aRoundTripForgivesNothing() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days);
        _fund(10_000e6);
        _payout(10_000e6); // syncs the deposit, then pays it out: out of the window's capital first
        _warp(20 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 30e6);
    }

    /// The build's review P2: a stranger's unit of USDC no longer forgives the accrual; it only leaves the
    /// window's base itself. $100,000, 30 days, 1 unit, then the charge: $82.191780.
    function test_accrual_dustChangesNothing() public {
        _make(100, 0);
        _fund(100_000e6);
        _sync();
        _warp(30 days - 90);
        usdc.mint(address(hub), 1); // a stranger's dust
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 82_191_780);
    }

    /// The first deposit starts the window, never the creation: a strategy funded 60 days after its creation
    /// is charged from its deposit.
    function test_accrual_firstDepositStartsIt() public {
        _make(100, 0);
        _warp(60 days);
        _fund(36_500e6);
        _sync();
        _warp(1 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 1e6, "one day of 1 % on $36,500");
    }

    // ── §3.3: the base ───────────────────────────────────────────────────────────────────────────────

    /// In profit the base is the mark (profit not yet crystallised is not charged), in a loss the value; a
    /// forged report inflating the value above the mark changes nothing.
    function test_base_minOfMarkAndValue() public {
        assertEq(FeeMath.mgmtBase(10_000e6, 12_000e6), 10_000e6);
        assertEq(FeeMath.mgmtBase(10_000e6, 8_000e6), 8_000e6);
        assertEq(FeeMath.mgmtBase(-5, 8_000e6), 0);
        assertEq(FeeMath.mgmtBase(10_000e6, -1), 0);
        _make(100, 0);
        vm.prank(recovery);
        fee.setFeeRate(0); // the performance fee aside
        _fund(36_500e6);
        _sync();
        _warp(1 days - 90);
        _value(1_000_000_000); // a forged report: $1bn of USD on the short
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 1e6, "on the mark ($36,500), never the forged value");
        _warp(1 days - 90);
        _value(1_000_000_000);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 2e6, "the mark again: the fee lowered the value, not the mark");
    }

    /// Codex's bound (§5): a report hiding a loss raises the base to the mark at most: $100,000 mark, $1,000
    /// real, 90 days at 1 %: $246.575342 where $2.465753 was due, and never more (the signed rate on the
    /// mark over the window). Not prevented: it needs a valuation no report moves (2b has none).
    function test_base_forgedReportHidingALoss_boundedByTheMark() public {
        _make(100, 0);
        vm.prank(recovery);
        fee.setFeeRate(0);
        _fund(100_000e6);
        _sync();
        usdc.burn(address(hub), 99_000e6); // the loss: $1,000 left, the mark unmoved
        _warp(120 days - 90);
        _value(99_000); // the forged report hides it
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 246_575_342, "the bound, to the unit");
        assertEq(FeeMath.mgmtFee(FeeMath.mgmtBase(100_000e6, 1_000e6), 90 days, 100, 0), 2_465_753, "what was due");
    }

    // ── §3.4: crystallize ────────────────────────────────────────────────────────────────────────────

    /// The management fee alone when the performance fee is too soon (a day after its last charge).
    function test_crystallize_managementAlone_whenThePerformanceFeeIsTooSoon() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(2 days - 90);
        _value(0);
        _crystallize(); // both: management $2, performance 0
        assertEq(usdc.balanceOf(treasury), 2e6);
        _warp(1 days - 90);
        uint64 lastFee = hub.lastFeeAt();
        _value(0);
        _crystallize();
        // a day on the base min(mark $36,500, value $36,498): the fee lowered the value, not the mark
        assertEq(usdc.balanceOf(treasury), 2e6 + 999_945);
        assertEq(hub.lastFeeAt(), lastFee, "no performance charge");
    }

    /// At most one management charge a day; with neither fee due, `TooSoon`.
    function test_crystallize_atMostOnceADay() public {
        _make(100, 0);
        _fund(36_500e6);
        _warp(1 days);
        _value(1_000);
        _crystallize(); // a performance charge; the management window restarted by the deposit's sync
        assertEq(hub.lastFeeAt(), _now());
        _value(1_000);
        uint80[] memory r = _r();
        vm.prank(key);
        vm.expectRevert(HubState.TooSoon.selector);
        fee.crystallize(r);
    }

    /// Both in one call (§3.4's example): mark $10,000, value $11,000, 7 days at 1 % and 15 %: management
    /// 10,000 × 1 % × 7 / 365 = $1.917808; the performance profit capped at 10,000 × 0.5 % × 7 = $350, its
    /// fee $52.50, the mark 10,000 + 350 − 52.50 = $10,297.50; `preview` said exactly that before.
    function test_crystallize_both_performanceOnTheNetValue_previewEqual() public {
        _make(100, 0);
        _fund(10_000e6);
        _sync(); // the window starts with the deposit
        _warp(7 days - 90);
        _value(1_000);
        (bool ok, bytes32 why, int256 v, int256 markSynced,, uint256 capped, uint256 perfFee,, uint256 accrued, uint256 due) =
            fee.preview(_r());
        assertTrue(ok);
        assertEq(why, bytes32(0));
        assertEq(v, 11_000e6);
        assertEq(markSynced, 10_000e6);
        assertEq(accrued, 1_917_808);
        assertEq(due, 1_917_808);
        assertEq(capped, 350e6);
        assertEq(perfFee, 52_500_000);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 1_917_808 + 52_500_000);
        assertEq(hub.mark(), 10_297_500_000);
    }

    /// `preview` with an inflow not yet synced shows 0 (the sync would restart the window); with no cash it
    /// shows the accrued fee but 0 due, and a flat fee with no cash is still visible to schedule.
    function test_preview_unsyncedInflow_andNoCash() public {
        _make(0, 10e6);
        _fund(10_000e6);
        _sync();
        _warp(30 days - 90);
        _value(0);
        (,,,,,,,, uint256 accrued, uint256 due) = fee.preview(_r());
        assertEq(accrued, 10e6);
        assertEq(due, 10e6);
        _fund(1e6); // not synced: preview takes it as the window's capital, as the sync will
        (,,,,,,,, accrued, due) = fee.preview(_r());
        assertEq(accrued, 10e6);
        assertEq(due, 10e6);
        // the hub's cash gone to its legs: the value holds, the cash does not
        usdc.burn(address(hub), 10_001e6);
        _sync();
        _warp(30 days - 90);
        _value(10_000);
        (,,,,,,,, accrued, due) = fee.preview(_r());
        assertEq(accrued, 10e6, "accrued: what the harvest must bring");
        assertEq(due, 0, "no cash: crystallize would defer");
        vm.expectEmit(address(hub));
        emit HubState.ManagementFeeDeferred(HubState.NeedUsdc.selector);
        _crystallize();
        (,,,, uint64 from,) = _mgmt();
        assertLt(from, _now(), "the accrual waits");
    }

    /// No fee address: deferred, never a revert, the accrual kept; `preview` shows it accrued, not due.
    function test_crystallize_noFeeAddress_defers() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(2 days - 90);
        _value(0);
        vm.mockCall(address(registry), abi.encodeWithSignature("feeAddress()"), abi.encode(address(0)));
        (,,,,,,,, uint256 accrued, uint256 due) = fee.preview(_r());
        assertEq(accrued, 2e6);
        assertEq(due, 0);
        (,,,, uint64 from,) = _mgmt();
        vm.expectEmit(address(hub));
        emit HubState.ManagementFeeDeferred(HubState.NoFeeAddress.selector);
        _crystallize();
        (,,,, uint64 after_,) = _mgmt();
        assertEq(after_, from, "the accrual waits");
        vm.clearMockedCalls();
        _warp(1 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 3e6, "charged later, three days");
    }

    // ── §3.4: payout ─────────────────────────────────────────────────────────────────────────────────

    /// `payout` always pays; it charges the management fee only above its amount, else defers.
    function test_payout_chargesAboveTheAmountOnly_alwaysPays() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(2 days - 90);
        _value(0);
        vm.expectEmit(address(hub));
        emit HubState.ManagementFeeDeferred(HubState.NeedUsdc.selector);
        _payout(36_500e6); // everything: no room for the $2
        assertEq(usdc.balanceOf(address(owner)), 36_500e6);
        assertEq(usdc.balanceOf(treasury), 0);
        _fund(36_500e6);
        _sync();
        _warp(2 days - 90);
        _value(0);
        _payout(1_000e6);
        assertEq(usdc.balanceOf(treasury), 2e6, "charged: two days on $36,500 (the deposit restarted the window)");
        assertEq(usdc.balanceOf(address(owner)), 37_500e6);
    }

    // ── §3.5: the exit ───────────────────────────────────────────────────────────────────────────────

    /// The accrual stops at the exit's entry, frozen with the mark; settled on cash, before 2b's fee.
    /// $36,500 for 10 days at 1 %: $10, then the owner gets the rest.
    function test_exit_frozenWindow_settledOnCash() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days);
        _beginExit();
        (,,,,, uint64 window) = _mgmt();
        assertEq(window, 10 days);
        _warp(30 days); // no more accrual
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 10e6);
        assertEq(usdc.balanceOf(makeAddr("withdrawal-address")), 36_490e6);
        (,,,,,,, uint256 paid,,,) = fee.managementFee();
        assertEq(paid, 10e6);
    }

    /// Codex's P1 (§3.5): a $100,000 mark, $1,000 recovered, $99,000 deposited during the exit, 90 days at
    /// 1 %: $2.465753 (on the $1,000 recovered), never $246.58; over two steps, whatever arrives.
    function test_exit_depositDuringTheExit_neverStandsInForLostCapital() public {
        _make(100, 0);
        _fund(100_000e6);
        _sync();
        usdc.burn(address(hub), 99_000e6); // the loss
        _warp(120 days);
        _beginExit();
        _fund(99_000e6); // capital arriving during the exit
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 2_465_753);
        _fund(5_000e6); // a later arrival: also the exit's own capital
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 2_465_753, "nothing more");
    }

    /// The review of the build (P1): a deposit not yet counted when the exit begins is the exit's own
    /// capital: $1,000 for 89 days at 1 %, $100,000 arriving, then the exit: $2.438356, never $246.27.
    function test_exit_unsyncedDepositAtTheEntry_isTheExitsCapital() public {
        _make(100, 0);
        _fund(1_000e6);
        _sync();
        _warp(89 days);
        _fund(100_000e6); // in flight when the owner exits
        _beginExit();
        (,,,,, uint64 window) = _mgmt();
        assertEq(window, 89 days, "the old money's window");
        (,,,,,, int256 entry,,,,) = fee.managementFee();
        assertEq(entry, 1_000e6, "the mark before the deposit");
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 2_438_356);
    }

    /// Over several steps the base grows with what the exit recovers: $36,500 at 1 % for 90 days is $90;
    /// a first step that recovers $50 pays 1 % × 90 / 365 of $50 ($0.123287), the step that recovers the
    /// rest pays the remainder, $90 in all.
    function test_exit_baseGrowsWithWhatIsRecovered_acrossSteps() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        usdc.burn(address(hub), 36_450e6); // $50 in hand at the hub; the rest still at the legs
        _warp(90 days);
        _beginExit();
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 123_287);
        vm.startPrank(long); // the leg's money back: a member move, not capital
        usdc.mint(long, 36_450e6);
        usdc.approve(address(hub), 36_450e6);
        hub.receiveLocal(36_450e6);
        vm.stopPrank();
        _exitStep();
        (,,,,,,, uint256 paid,,,) = fee.managementFee();
        assertEq(paid, 90e6, "the whole due over two steps");
        assertEq(usdc.balanceOf(treasury), 90e6);
    }

    /// 2b's rate checkpoint in exit beside the management settlement: each fee on its own figures.
    function test_exit_performanceRateCheckpoint_withTheManagementFee() public {
        _make(100, 0);
        _fund(10_000e6);
        _sync();
        _warp(30 days);
        _beginExit();
        vm.startPrank(long);
        usdc.mint(long, 2_000e6);
        usdc.approve(address(hub), 2_000e6);
        hub.receiveLocal(2_000e6);
        vm.stopPrank();
        _exitStep(); // management $8.219178 then 15 % on 12,000 − 8.219178 − 10,000
        uint256 mgmt = 8_219_178;
        uint256 perf1 = (12_000e6 - mgmt - 10_000e6) * 1500 / 10_000;
        vm.prank(recovery);
        fee.setFeeRate(1000); // a lowering in exit: what was handled keeps 15 %
        vm.startPrank(long);
        usdc.mint(long, 1_000e6);
        usdc.approve(address(hub), 1_000e6);
        hub.receiveLocal(1_000e6);
        vm.stopPrank();
        _exitStep(); // no more management fee (the base is capped at the mark at entry); 10 % on $1,000
        assertEq(usdc.balanceOf(treasury), mgmt + perf1 + 100e6);
        (,,,,,,, uint256 paid,,,) = fee.managementFee();
        assertEq(paid, mgmt);
    }

    /// `preview` in exit: the accrual has stopped, so nothing accrues nor is due there.
    function test_preview_inExit_zero() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days);
        _value(0);
        _beginExit();
        (,,,,,,,, uint256 accrued, uint256 due) = fee.preview(_r());
        assertEq(accrued, 0);
        assertEq(due, 0);
    }

    /// The percentage on what a losing exit recovers; a $5 exit keeps the owner's share (the flat part at
    /// most 1 % of the base a month: 5 × 1 % × 3 = $0.15 over 90 days).
    function test_exit_losingExit_andADustExit() public {
        _make(0, 10e6);
        _fund(5e6);
        _sync();
        _warp(90 days);
        _beginExit();
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 150_000);
        assertEq(usdc.balanceOf(makeAddr("withdrawal-address")), 4_850_000);
    }

    /// A profitable exit: the management fee on the base (the mark at entry), then 2b's fee on the cash
    /// left, and the owner, DLTX's two fees and the totals reconcile to the unit. $10,000 deposited, $12,000
    /// recovered (a leg's money back, not capital), 30 days at 1 %: $8.219178; 2b's 15 % on
    /// 12,000 − 8.219178 − 10,000 = $1,991.780822 → $298.767123.
    function test_exit_profitable_reconciles() public {
        _make(100, 0);
        _fund(10_000e6);
        _sync();
        _warp(30 days);
        _beginExit();
        vm.startPrank(long);
        usdc.mint(long, 2_000e6);
        usdc.approve(address(hub), 2_000e6);
        hub.receiveLocal(2_000e6);
        vm.stopPrank();
        _exitStep();
        uint256 mgmt = 8_219_178;
        uint256 perf = (12_000e6 - mgmt - 10_000e6) * 1500 / 10_000;
        assertEq(perf, 298_767_123);
        assertEq(usdc.balanceOf(treasury), mgmt + perf);
        assertEq(usdc.balanceOf(makeAddr("withdrawal-address")), 12_000e6 - mgmt - perf);
        assertEq(hub.exitFeePaid(), perf);
        (,,,,,,, uint256 paid,,,) = fee.managementFee();
        assertEq(paid, mgmt);
    }

    /// No fee address in the exit: the management fee is forgiven, the owner keeps it; a frozen fee address
    /// sets it aside (2b's try), the owner paid either way.
    function test_exit_noFeeAddress_forgives_frozenSetsAside() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days);
        _beginExit();
        vm.mockCall(address(registry), abi.encodeWithSignature("feeAddress()"), abi.encode(address(0)));
        _exitStep();
        (,,,,,,, uint256 paid, uint256 forgiven,,) = fee.managementFee();
        assertEq(paid, 0);
        assertEq(forgiven, 10e6);
        assertEq(usdc.balanceOf(makeAddr("withdrawal-address")), 36_500e6, "the owner kept it");
        vm.clearMockedCalls();
        _fund(1_000e6); // a later arrival settles nothing more: the total is already forgiven
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_exit_frozenFeeAddress_setAside() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days);
        _beginExit();
        vm.mockCallRevert(ARB_USDC, abi.encodeCall(MockERC20.transfer, (treasury, 10e6)), "frozen");
        _exitStep();
        assertEq(hub.feeOwed(), 10e6, "set aside, the owner paid");
        (,,,,,,, uint256 paid,,,) = fee.managementFee();
        assertEq(paid, 10e6);
    }

    /// A lowering during the exit applies to the whole exit's total; a raise is refused there.
    function test_exit_loweringApplies_raiseRefused() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days);
        _beginExit();
        _setMgmt(50, 0);
        vm.prank(recovery);
        vm.expectRevert(HubState.BadRate.selector);
        fee.setManagementFee(100, 0);
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 5e6, "10 days at 0.5 %");
    }

    /// The escape hatch is the same `exitStep`: it charges the same with DLTX stopped.
    function test_exit_escapeHatch_chargesTheSame() public {
        _make(100, 0);
        _fund(36_500e6);
        _sync();
        _warp(10 days); // the group's key checked in at creation's day; 7 days later the group is stopped
        assertTrue(registry.stopped(0, 1));
        vm.prank(stranger);
        MemberBase(address(hub)).beginExitStopped();
        _exitStep();
        assertEq(usdc.balanceOf(treasury), 10e6);
    }

    // ── §3.6: the knobs ──────────────────────────────────────────────────────────────────────────────

    /// The recovery key only; never above the signed values; a change forgives the accrual (restarts).
    function test_changes_recoveryOnly_ceilings_restart() public {
        _make(100, 10e6);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        fee.setManagementFee(50, 0);
        vm.prank(recovery);
        vm.expectRevert(HubState.BadRate.selector);
        fee.setManagementFee(101, 0);
        vm.prank(recovery);
        vm.expectRevert(HubState.BadRate.selector);
        fee.setManagementFee(100, 10e6 + 1);
        _fund(36_500e6);
        _sync();
        _warp(20 days);
        vm.expectEmit(address(hub));
        emit HubState.ManagementFeeSet(100, 0, 10e6, 0, recovery);
        _setMgmt(0, 0);
        (,,,, uint64 from,) = _mgmt();
        assertEq(from, _now());
        _warp(5 days);
        _setMgmt(100, 10e6); // restored up to the signed values, never reaching back
        _warp(1 days - 90);
        _value(0);
        _crystallize();
        assertEq(usdc.balanceOf(treasury), 1e6 + 333_333, "one day only");
        (uint16 rate, uint16 signedRate, uint32 flat, uint32 signedFlat,,) = _mgmt();
        assertEq(rate, 100);
        assertEq(signedRate, 100);
        assertEq(flat, 10e6);
        assertEq(signedFlat, 10e6);
    }

    /// `validateParams` refuses 101 bp and 10,000,001 units; the factory with it.
    function test_bounds_validateParams() public {
        hubImpl.validateParams(address(registry), abi.encode(HubParams(btcProfile, 5, 50, 1500, 100, 10e6)));
        vm.expectRevert(HubState.BadParams.selector);
        hubImpl.validateParams(address(registry), abi.encode(HubParams(btcProfile, 5, 50, 1500, 101, 0)));
        vm.expectRevert(HubState.BadParams.selector);
        hubImpl.validateParams(address(registry), abi.encode(HubParams(btcProfile, 5, 50, 1500, 0, 10e6 + 1)));
    }

    // ── §3.8: upgrades (V3, V11) ─────────────────────────────────────────────────────────────────────

    /// An upgrade is not a fee event: the management fee's state and its signed ceilings carry across.
    function test_upgrade_keepsTheStateAndTheCeilings() public {
        _make(80, 7e6);
        _fund(36_500e6);
        _sync();
        _setMgmt(40, 3e6);
        (uint16 r0, uint16 s0, uint32 f0, uint32 sf0, uint64 from0,) = _mgmt();
        address hub2 = address(
            new HubV2(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), address(seqFeed))
        );
        address long2 = address(
            new AaveV3AssetLegV2(
                address(longExit), address(longExit).codehash, address(longRewards), address(longRewards).codehash,
                address(upgrade), address(upgrade).codehash, address(registry), address(aave), ARB_USDC, address(aave),
                address(seqFeed)
            )
        );
        bytes32 manifest2 = _listVersion(2, hub2, long2, FAR_SHORT, FAR_HASH_2);
        _checkIn();
        uint256 deadline = _now() + 1 hours;
        bytes32 cred = walletCred(wallet);
        VaultUpgrade(address(hub)).scheduleUpgrade(
            manifest2, cred, deadline, _upgradeSig(walletPk, address(hub), manifest2, MemberState(address(hub)).ownerNonceOf(cred), deadline)
        );
        (, uint64 due,,) = VaultUpgrade(address(hub)).pendingAction();
        vm.warp(due);
        VaultUpgrade(address(hub)).applyUpgrade();
        assertEq(MemberState(address(hub)).codeVersion(), 2);
        (uint16 r1, uint16 s1, uint32 f1, uint32 sf1, uint64 from1,) = _mgmt();
        assertEq(abi.encode(r0, s0, f0, sf0, from0), abi.encode(r1, s1, f1, sf1, from1));
        vm.prank(recovery);
        vm.expectRevert(HubState.BadRate.selector);
        fee.setManagementFee(81, 0); // the signed ceiling still binds
    }
}
