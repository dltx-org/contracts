// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {FeeMath} from "../src/lib/FeeMath.sol";

/// Amendment 2b's arithmetic (§3.3–§3.7) on its own: every numeric example and Codex scenario of the spec
/// at the level of the figures, plus fuzzed bounds. The hub's wiring (state, transfers, the snapshot) is
/// tested with the hub.
contract FeeMathTest is Test {
    uint256 constant USDC = 1e6;
    uint256 constant ETH_PRICE = 2_500e18;
    uint256 constant FACE = 1e18; // USD at face
    uint16 constant RATE = 1_500; // 15 %
    uint256 constant T0 = 1_000_000_000;

    // ── helpers: a strategy's figures as the hub would gather them ───────────────────────────────────

    function _q(int256 a, int256 b, int256 c) internal pure returns (int256[] memory x) {
        x = new int256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function _q(int256 a, int256 b) internal pure returns (int256[] memory x) {
        x = new int256[](2);
        (x[0], x[1]) = (a, b);
    }

    function _p(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function _p(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        (x[0], x[1]) = (a, b);
    }

    function _usd(int256[] memory q, uint256[] memory p) internal pure returns (int256 s) {
        bool ok;
        (ok, s) = FeeMath.holdingsUsd18(q, p);
        require(ok, "holdings refused");
    }

    function _pair(uint256 sent, uint256 received) internal pure returns (int256 t) {
        bool ok;
        (ok, t) = FeeMath.pairTerm(sent, received);
        require(ok, "pair refused");
    }

    /// The exit's state, stepped as `exitStep` does with or without a fee address.
    struct Exit {
        int256 exitBase;
        int256 exitFrom;
        uint256 exitCheckDue;
        uint256 exitPaid;
        uint256 exitFeePaid;
        uint256 exitFeeForgiven;
        uint16 rate;
    }

    function _enter(int256 mark, uint16 rate) internal pure returns (Exit memory e) {
        e.exitBase = mark;
        e.exitFrom = mark;
        e.rate = rate;
    }

    /// One `exitStep` on `cash` in hand; returns what DLTX received and what the owner received.
    function _step(Exit memory e, uint256 cash, bool feeAddress) internal pure returns (uint256 fee, uint256 owner) {
        (, uint256 due) = FeeMath.exitDue(
            e.exitPaid, e.exitFeePaid, e.exitFeeForgiven, cash, e.exitFrom, e.exitCheckDue, e.rate
        );
        if (due > 0 && !feeAddress) {
            e.exitFeeForgiven += due;
            due = 0;
        }
        e.exitFeePaid += due;
        e.exitPaid += cash - due;
        return (due, cash - due);
    }

    function _deposit(Exit memory e, uint256 amount) internal pure {
        e.exitBase += int256(amount);
        e.exitFrom += int256(amount);
    }

    function _lower(Exit memory e, uint16 newRate) internal pure {
        (e.exitFrom, e.exitCheckDue) =
            FeeMath.exitCheckpoint(e.exitPaid, e.exitFeePaid, e.exitFrom, e.exitCheckDue, e.rate);
        e.rate = newRate;
    }

    // ── §3.4: the value ──────────────────────────────────────────────────────────────────────────────

    /// The worked example: mark $10,000, ETH $2,500; AAVE +4 ETH, −5,000 USD, +200 USD; Hyperliquid
    /// +14,920 USD, −4 ETH; nothing in flight; the hub empty: $10,120.
    function test_value_workedExample() public pure {
        int256 aave = _usd(_q(4e18, -5_000e18, 200e18), _p(ETH_PRICE, FACE, FACE));
        int256 hl = _usd(_q(14_920e18, -4e18), _p(FACE, ETH_PRICE));
        assertEq(aave, 5_200e18);
        assertEq(hl, 4_920e18);
        assertEq(FeeMath.value(0, aave + hl, _pair(0, 0) + _pair(0, 0)), int256(10_120 * USDC));
    }

    /// Codex's fifth round at the price level: the snapshot at $2,500 (long +1 ETH; short +3,500 USD, −1
    /// ETH: $1,000 of margin): $3,500. ETH falls to $2,400, the short closes for $1,100 before its report.
    /// At the report's instant's price the value is $3,500 (no profit); at the snapshot's it would read
    /// $3,600.
    function test_value_codexFifthRound_oneInstantOnePrice() public pure {
        int256 atSnapshot = _usd(_q(1e18, 3_500e18, -1e18), _p(ETH_PRICE, FACE, ETH_PRICE));
        assertEq(FeeMath.value(0, atSnapshot, 0), int256(3_500 * USDC));
        // after the close: the long unchanged, the short all USD
        int256 atReportPrice = _usd(_q(1e18, 1_100e18), _p(2_400e18, FACE));
        int256 atSnapshotPrice = _usd(_q(1e18, 1_100e18), _p(ETH_PRICE, FACE));
        int256 mark = int256(3_500 * USDC);
        int256 v = FeeMath.value(0, atReportPrice, 0);
        assertEq(v, mark, "valued at t_r: $3,500, the truth");
        assertEq(FeeMath.value(0, atSnapshotPrice, 0), int256(3_600 * USDC), "the mix the instant rule refuses");
        (, uint256 fee) = FeeMath.charge(v, mark, T0, T0 + 3 days, RATE, true);
        assertEq(fee, 0, "no fee");
    }

    /// The pair terms (2a §3.6, the probe's cases): a $2 burn from the remote leg to the hub, with Circle's
    /// 1.4 bp fee. Whatever the age of each side's figures, the dollar counts once.
    function test_value_pairInFlight_bothArrivalOrders() public pure {
        uint256 hubUsdc = 10 * USDC;
        int256 legUsd18 = 21_402_812e12; // $21.402812 before the burn
        uint256 burn = 2 * USDC;
        uint256 circleFee = 280; // 1.4 bp of $2
        int256 before = FeeMath.value(hubUsdc, legUsd18, _pair(0, 0));
        // 1. the leg's report saw the burn, the mint not done: the pair term carries it
        int256 inFlight = FeeMath.value(hubUsdc, legUsd18 - int256(burn) * 1e12, _pair(burn, 0));
        assertEq(inFlight, before, "in flight: unchanged");
        // 2. the mint done, the leg's report newer: the hub holds it net of Circle's fee
        int256 minted = FeeMath.value(hubUsdc + burn - circleFee, legUsd18 - int256(burn) * 1e12, _pair(burn, burn));
        assertEq(minted, before - int256(circleFee), "only Circle's fee, a cost");
        // 3. the mint done, the leg's report OLDER (it still holds the $2, its sentTo still 0): the term is
        //    negative and cancels the double count
        int256 olderSender = FeeMath.value(hubUsdc + burn - circleFee, legUsd18, _pair(0, burn));
        assertEq(_pair(0, burn), -int256(burn), "the negative term");
        assertEq(olderSender, minted, "equal to the unit");
    }

    function test_rounding_towardMinusInfinity() public pure {
        assertEq(FeeMath.mulPrice(-1, 1.5e18), -2, "not -1: truncation would favour DLTX");
        assertEq(FeeMath.mulPrice(1, 1.5e18), 1);
        assertEq(FeeMath.mulPrice(-3, 1e18), -3, "exact");
        assertEq(FeeMath.floorDiv(-1, 1e12), -1);
        assertEq(FeeMath.floorDiv(-1e12, 1e12), -1);
        assertEq(FeeMath.floorDiv(-1e12 - 1, 1e12), -2);
        assertEq(FeeMath.floorDiv(1e12 - 1, 1e12), 0);
        // a debt of $0.0000001 (below a USDC unit) is a whole unit off the value
        assertEq(FeeMath.value(5, -1e11, 0), 4);
        // a position worth $0.0000009 is nothing
        assertEq(FeeMath.value(5, 9e11, 0), 5);
    }

    function testFuzz_floorDiv(int256 a, int256 d) public pure {
        a = bound(a, -int256(2 ** 250), int256(2 ** 250));
        d = bound(d, 1, int256(2 ** 120));
        int256 q = FeeMath.floorDiv(a, d);
        assertLe(q * d, a);
        assertGt((q + 1) * d, a);
    }

    function test_value_outOfRangeFigures_refused_neverRevert() public pure {
        uint256 big = FeeMath.MAX_FIGURE + 1;
        (bool ok,) = FeeMath.holdingsUsd18(_q(int256(big), 0), _p(FACE, FACE));
        assertFalse(ok, "quantity");
        (ok,) = FeeMath.holdingsUsd18(_q(-int256(big), 0), _p(FACE, FACE));
        assertFalse(ok, "negative quantity");
        (ok,) = FeeMath.holdingsUsd18(_q(type(int256).min, 0), _p(FACE, FACE));
        assertFalse(ok, "int256's minimum");
        (ok,) = FeeMath.holdingsUsd18(_q(1, 0), _p(big, FACE));
        assertFalse(ok, "price");
        (ok,) = FeeMath.holdingsUsd18(_q(1, 0), new uint256[](1));
        assertFalse(ok, "lengths");
        (ok,) = FeeMath.pairTerm(big, 0);
        assertFalse(ok, "counter");
        (ok,) = FeeMath.pairTerm(type(uint256).max, 0);
        assertFalse(ok, "a counter that would wrap int256");
        (ok,) = FeeMath.holdingsUsd18(_q(int256(FeeMath.MAX_FIGURE), -int256(FeeMath.MAX_FIGURE)), _p(FeeMath.MAX_FIGURE, FeeMath.MAX_FIGURE));
        assertTrue(ok, "at the bound");
    }

    function testFuzz_value_neverReverts(int256[8] memory q, uint256[8] memory p, uint256 s, uint256 r, uint256 free)
        public
        pure
    {
        int256[] memory qs = new int256[](8);
        uint256[] memory ps = new uint256[](8);
        for (uint256 i; i < 8; ++i) (qs[i], ps[i]) = (q[i], p[i]);
        (bool ok, int256 h) = FeeMath.holdingsUsd18(qs, ps);
        (bool pok, int256 t) = FeeMath.pairTerm(s, r);
        free = bound(free, 0, 2 ** 128);
        if (ok && pok) FeeMath.value(free, h, t + t + t + t);
    }

    // ── §3.3: capital ────────────────────────────────────────────────────────────────────────────────

    function test_inflow_deposit_andRebase() public pure {
        (uint256 capital, uint256 booked) = FeeMath.inflow(1_000 * USDC, 0);
        assertEq(capital, 1_000 * USDC, "a deposit by plain transfer is capital");
        assertEq(booked, 1_000 * USDC);
        // a balance below booked (a token-level event): re-based, not booked to the mark
        (capital, booked) = FeeMath.inflow(990 * USDC, booked);
        assertEq(capital, 0);
        assertEq(booked, 990 * USDC);
        // a later deposit is then counted in full, not partly masked
        (capital, booked) = FeeMath.inflow(1_090 * USDC, booked);
        assertEq(capital, 100 * USDC);
    }

    // ── §3.5: crystallize and payout ─────────────────────────────────────────────────────────────────

    /// The worked example three days after the last fee: the cap allows 0.5 % of $10,000 a day, $150,
    /// above the $120 of profit: 15 % × 120 = $18, the mark $10,102; `payout(102)` then brings it back to
    /// $10,000.
    function test_charge_eighteenDollarsThreeDaysLater() public pure {
        int256 mark = int256(10_000 * USDC);
        int256 v = int256(10_120 * USDC);
        assertEq(FeeMath.profitCap(mark, T0, T0 + 3 days), 150 * USDC);
        (uint256 profit, uint256 fee) = FeeMath.charge(v, mark, T0, T0 + 3 days, RATE, true);
        assertEq(profit, 120 * USDC);
        assertEq(fee, 18 * USDC);
        mark = FeeMath.markAfter(mark, profit, fee);
        assertEq(mark, int256(10_102 * USDC));
        // payout(102): the value and the mark fall by the amount, the profit above the mark unchanged
        mark -= int256(102 * USDC);
        v -= int256(18 * USDC + 102 * USDC);
        assertEq(mark, int256(10_000 * USDC));
        assertEq(v, mark, "back to the starting value");
    }

    /// Codex's sixth round: one day after the last fee the cap is $50, so the fee is $7.50, not $18; the
    /// $70 above it stays above the mark.
    function test_charge_oneDayLater_capped() public pure {
        int256 mark = int256(10_000 * USDC);
        int256 v = int256(10_120 * USDC);
        (uint256 profit, uint256 fee) = FeeMath.charge(v, mark, T0, T0 + 1 days, RATE, true);
        assertEq(profit, 50 * USDC);
        assertEq(fee, 7.5e6);
        mark = FeeMath.markAfter(mark, profit, fee);
        assertEq(mark, int256(10_042.5e6));
        assertEq(v - mark, int256(77.5e6), "the capped excess stays above the mark");
    }

    function test_charge_noProfit_negativeValue_markAtOrBelowZero() public pure {
        int256 mark = int256(10_000 * USDC);
        (uint256 profit, uint256 fee) = FeeMath.charge(mark, mark, T0, T0 + 3 days, RATE, true);
        assertEq(profit + fee, 0, "v == mark");
        (profit, fee) = FeeMath.charge(mark - 1, mark, T0, T0 + 3 days, RATE, true);
        assertEq(profit + fee, 0, "a loss");
        (profit, fee) = FeeMath.charge(-5, -100, T0, T0 + 3 days, RATE, true);
        assertEq(profit + fee, 0, "a negative value charges nothing, even above a lower mark");
        (profit, fee) = FeeMath.charge(-5, -100, T0, T0 + 3 days, RATE, false);
        assertEq(profit + fee, 0, "uncapped too");
        (profit, fee) = FeeMath.charge(int256(500 * USDC), -int256(50 * USDC), T0, T0 + 7 days, RATE, true);
        assertEq(fee, 0, "a mark below zero: the cap is zero, the fee waits for the exit");
        (profit, fee) = FeeMath.charge(int256(500 * USDC), 0, T0, T0 + 7 days, RATE, true);
        assertEq(fee, 0, "a mark at zero likewise");
    }

    /// Sub-unit fees: a positive profit whose fee rounds to zero changes nothing (the hub leaves the mark
    /// and `lastFeeAt`), and a later, larger profit is charged in full.
    function test_charge_subUnitFee_changesNothing_laterChargedInFull() public pure {
        int256 mark = int256(10_000 * USDC);
        (uint256 profit, uint256 fee) = FeeMath.charge(mark + 6, mark, T0, T0 + 1 days, RATE, true);
        assertEq(profit, 6);
        assertEq(fee, 0, "0.9 of a unit rounds to zero");
        // the hub: fee == 0 → return; mark and lastFeeAt unchanged. The profit grows; a day later
        (profit, fee) = FeeMath.charge(mark + 40 * int256(USDC), mark, T0, T0 + 2 days, RATE, true);
        assertEq(profit, 40 * USDC, "the whole profit, the earlier six units included");
        assertEq(fee, 6 * USDC);
    }

    /// The daily cap and its 7-day window, on the MARK: a forged report inflating the value is capped,
    /// whatever it claims and however long the hub was idle; the excess is never charged once it is gone.
    function test_charge_forgedValue_cappedOnTheMark() public pure {
        int256 mark = int256(10_000 * USDC);
        int256 forged = int256(FeeMath.MAX_FIGURE); // any figure the value accepts
        (uint256 profit, uint256 fee) = FeeMath.charge(forged, mark, T0, T0 + 100 days, RATE, true);
        assertEq(profit, 350 * USDC, "0.5 % a day over at most 7 days");
        assertEq(fee, 52.5e6, "0.525 % of the mark");
        int256 markAfterForgery = FeeMath.markAfter(mark, profit, fee);
        // the forgery disappears: the real value ($10,000 minus the $52.50 taken) is below the new mark
        (, fee) = FeeMath.charge(mark - int256(52.5e6), markAfterForgery, T0 + 100 days, T0 + 101 days, RATE, true);
        assertEq(fee, 0, "the excess never charged");
        // the next day's charge, forged again: 0.075 % of the mark a day
        (, fee) = FeeMath.charge(forged, markAfterForgery, T0 + 100 days, T0 + 101 days, RATE, true);
        assertEq(fee, uint256(markAfterForgery) * 50 / 10_000 * RATE / 10_000);
    }

    /// Forged values chosen to drain the hub's free USDC take no more than the bound, whatever the hub
    /// holds: the fee depends on the mark, the rate and the time only.
    function testFuzz_charge_forgedValue_bound(int256 v, uint256 markU, uint256 idle, uint16 rate) public pure {
        markU = bound(markU, 0, 2 ** 100);
        int256 mark = int256(markU);
        v = bound(v, -int256(2 ** 200), int256(2 ** 200));
        idle = bound(idle, 0, 3_650 days);
        rate = uint16(bound(rate, 0, FeeMath.MAX_FEE_BP));
        (uint256 profit, uint256 fee) = FeeMath.charge(v, mark, T0, T0 + idle, rate, true);
        uint256 window = idle > 7 days ? 7 days : idle;
        assertLe(profit, markU * 50 * window / (10_000 * 1 days), "the cap");
        assertLe(fee, markU * 50 * 7 * rate / (10_000 * 10_000) + 1, "at most 7 days' cap at the rate");
        if (rate <= 1_500) assertLe(fee * 1_000_000, markU * 5_250, "<= 0.525 % of the mark at 15 %");
        if (fee > 0) assertLe(FeeMath.markAfter(mark, profit, fee), v, "the mark never above the value");
    }

    /// A real profit above the cap is charged over the following days, never twice.
    function test_charge_realExcess_chargedLater() public pure {
        int256 mark = int256(10_000 * USDC);
        int256 v = int256(10_500 * USDC);
        uint256 total;
        uint256 at = T0;
        for (uint256 day = 1; day <= 30; ++day) {
            (uint256 profit, uint256 fee) = FeeMath.charge(v, mark, at, T0 + day * 1 days, RATE, true);
            if (fee == 0) continue;
            total += fee;
            mark = FeeMath.markAfter(mark, profit, fee);
            v -= int256(fee); // the fee leaves the hub
            at = T0 + day * 1 days;
        }
        // after it all: the fee on $500 at 15 % = $75, less at most a unit per charge (each fee rounded
        // down, in the owner's favour); the mark at the value, the profit charged once
        assertLe(total, 75 * USDC);
        assertGe(total, 75 * USDC - 30);
        assertEq(mark, v, "every dollar of profit charged once");
    }

    // ── §3.6: the exit ───────────────────────────────────────────────────────────────────────────────

    /// A profitable exit over several steps charges rate × (realised − exitBase) in total, whatever the
    /// order and size of the arrivals (to a unit per step of rounding, always in the owner's favour).
    function testFuzz_exit_totalIsRateTimesProfit(uint256[5] memory arrivals, int256 base, uint16 rate) public pure {
        base = bound(base, -int256(1e12), int256(1e12));
        rate = uint16(bound(rate, 0, FeeMath.MAX_FEE_BP));
        Exit memory e = _enter(base, rate);
        uint256 fees;
        uint256 realised;
        for (uint256 i; i < 5; ++i) {
            uint256 cash = bound(arrivals[i], 0, 1e12);
            (uint256 fee,) = _step(e, cash, true);
            fees += fee;
            realised += cash;
        }
        int256 above = int256(realised) - base;
        uint256 expected = above > 0 ? uint256(above) * rate / 10_000 : 0;
        // the cash cap can hold part back when the base is negative; otherwise exact
        assertLe(fees, expected);
        if (base >= 0) assertEq(fees, expected, "exact on a non-negative base");
        assertEq(e.exitPaid + e.exitFeePaid, realised, "every dollar handled once");
    }

    function test_exit_several_steps_exact() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        (uint256 f1, uint256 o1) = _step(e, 600 * USDC, true); // below the base: the owner first
        (uint256 f2,) = _step(e, 500 * USDC, true); // crosses it by $100
        (uint256 f3,) = _step(e, 100 * USDC, true);
        assertEq(f1, 0);
        assertEq(o1, 600 * USDC);
        assertEq(f2, 15 * USDC);
        assertEq(f3, 15 * USDC);
        assertEq(e.exitFeePaid, 30 * USDC, "15 % of the $200 above the base");
    }

    function test_exit_losing_chargesNothing() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        (uint256 f1,) = _step(e, 700 * USDC, true);
        (uint256 f2,) = _step(e, 250 * USDC, true);
        assertEq(f1 + f2, 0);
        assertEq(e.exitPaid, 950 * USDC);
    }

    /// The independent reader's P1: deposit 1,000, profit 100, `payout(1,050)` deferred (mark −50), then
    /// losses; the exit realises 5: due = 15 % × 55 = 8.25, capped at the $5 in hand; never a revert.
    function test_exit_negativeBase_dueCappedAtCash() public pure {
        Exit memory e = _enter(-int256(50 * USDC), RATE);
        (uint256 fee, uint256 owner) = _step(e, 5 * USDC, true);
        assertEq(fee, 5 * USDC, "8.25 due, capped at the cash");
        assertEq(owner, 0);
        // more cash: the rest of the 8.25 first, then 15 % of the new
        (fee, owner) = _step(e, 10 * USDC, true);
        assertEq(e.exitFeePaid, 9.75e6, "15 % of 65");
        assertEq(fee, 4.75e6);
        assertEq(owner, 5.25e6);
        // a step with nothing in hand: nothing, no revert
        (fee, owner) = _step(e, 0, true);
        assertEq(fee + owner, 0);
    }

    /// Codex's third round: $100 above the base settled at 15 % ($15 paid), the rate lowered to 5 %,
    /// another $100 arrives: total = 15 + 5 % × 100 = 20, due = 5.
    function test_exit_lowering_settledProfitKeepsItsRate() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        (uint256 f1,) = _step(e, 1_100 * USDC, true);
        assertEq(f1, 15 * USDC);
        _lower(e, 500);
        assertEq(e.exitCheckDue, 15 * USDC);
        assertEq(e.exitFrom, int256(1_100 * USDC));
        (uint256 f2,) = _step(e, 100 * USDC, true);
        assertEq(f2, 5 * USDC);
    }

    /// Codex's fourth round: the same, then a $100 DEPOSIT instead of profit: it raises exitBase and
    /// exitFrom, realised by $100, the total stays 15, due 0.
    function test_exit_depositAfterCheckpoint_chargedNothing() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        _step(e, 1_100 * USDC, true);
        _lower(e, 500);
        _deposit(e, 100 * USDC);
        (uint256 f2, uint256 o2) = _step(e, 100 * USDC, true);
        assertEq(f2, 0);
        assertEq(o2, 100 * USDC);
        assertEq(e.exitBase, int256(1_100 * USDC));
    }

    /// A deposit during the exit with no rate change raises the base: never charged.
    function test_exit_depositRaisesTheBase() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        _step(e, 1_000 * USDC, true);
        _deposit(e, 300 * USDC);
        (uint256 fee,) = _step(e, 300 * USDC, true);
        assertEq(fee, 0);
    }

    /// Codex's fourth round: base −$50 with no rate change still charges $8.25 capped at $5; with the rate
    /// lowered to 5 % before any step, the old rate keeps the profit up to zero: exitCheckDue 7.5,
    /// exitFrom 0; then $5: total 7.5 + 5 % × 5 = 7.75, capped at $5.
    function test_exit_negativeBase_loweringBeforeAnyStep() public pure {
        Exit memory e = _enter(-int256(50 * USDC), RATE);
        _lower(e, 500);
        assertEq(e.exitCheckDue, 7.5e6);
        assertEq(e.exitFrom, 0);
        (uint256 fee, uint256 owner) = _step(e, 5 * USDC, true);
        assertEq(fee, 5 * USDC, "7.75 capped at 5");
        assertEq(owner, 0);
        (fee,) = _step(e, 100 * USDC, true);
        assertEq(e.exitFeePaid, 12.75e6, "7.5 + 5 % of 105");
    }

    /// Cash at the hub not yet stepped at the lowering takes the new rate (the owner's favour).
    function test_exit_unsteppedCash_takesTheNewRate() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        _step(e, 1_000 * USDC, true);
        // $200 of profit reaches the hub, then the rate is lowered before anyone steps
        _lower(e, 500);
        assertEq(e.exitCheckDue, 0, "nothing above the base handled yet");
        (uint256 fee,) = _step(e, 200 * USDC, true);
        assertEq(fee, 10 * USDC, "5 %, not 15 %");
    }

    function test_exit_severalLoweringsInARow() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), 2_000);
        _step(e, 1_100 * USDC, true); // $100 at 20 %: $20
        _lower(e, 1_000);
        _step(e, 100 * USDC, true); // $100 at 10 %: $10
        _lower(e, 500);
        _lower(e, 500); // a second checkpoint with nothing new handled changes nothing
        _step(e, 100 * USDC, true); // $100 at 5 %: $5
        _lower(e, 0);
        (uint256 fee,) = _step(e, 100 * USDC, true);
        assertEq(fee, 0, "0 % on the last $100");
        assertEq(e.exitFeePaid, 35 * USDC);
        assertEq(e.exitCheckDue, 35 * USDC);
    }

    /// Codex's first round: with no fee address the owner receives every dollar, the forgiven due recorded
    /// apart, and an address accepted later collects none of it.
    function test_exit_noFeeAddress_forgiven_neverCollectedLater() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        (uint256 fee, uint256 owner) = _step(e, 1_200 * USDC, false);
        assertEq(fee, 0);
        assertEq(owner, 1_200 * USDC, "every dollar to the owner");
        assertEq(e.exitFeeForgiven, 30 * USDC);
        // the address now exists; a step with nothing new collects nothing
        (fee,) = _step(e, 0, true);
        assertEq(fee, 0);
        // new profit is charged on its own, never the forgiven part
        (fee,) = _step(e, 100 * USDC, true);
        assertEq(fee, 15 * USDC);
    }

    /// A fee transfer that fails goes to `feeOwed` in the hub but is still settled (counted in
    /// exitFeePaid): the next step doesn't charge it again.
    function test_exit_failedTransfer_settledOnce() public pure {
        Exit memory e = _enter(int256(1_000 * USDC), RATE);
        (uint256 fee,) = _step(e, 1_100 * USDC, true); // the hub's try fails: feeOwed += 15
        assertEq(fee, 15 * USDC);
        // the free USDC excludes feeOwed: the next step's cash is only what arrived since
        (fee,) = _step(e, 0, true);
        assertEq(fee, 0);
    }
}
