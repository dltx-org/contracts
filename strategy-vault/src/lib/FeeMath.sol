// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * The performance fee's arithmetic (step 11e2 amendment 2b §3.3–§3.7), pure, for the hub to inline and
 * for the engine's mirror (§6) to reproduce to the unit:
 *   - the VALUE: holdings × prices (18 decimals) floored to USDC's 6, plus the hub's free USDC and the
 *     SIGNED pair terms. Every product and quotient rounds toward −∞ (a floor, never Solidity's
 *     truncation toward zero), so a negative term never rounds in DLTX's favour;
 *   - `charge`: the fee `crystallize` and `payout` take (no fee when v ≤ 0 or v ≤ mark; the profit capped
 *     on max(mark, 0) × MAX_DAILY_PROFIT_BP per day since the last fee, over at most MAX_CAP_WINDOW;
 *     the fee rounded down; a zero fee changes nothing);
 *   - the EXIT: the fee on the cash the exit realises above `exitFrom`, plus what earlier rates fixed
 *     (`exitCheckDue`), net of what was paid and forgiven, capped at the cash in hand; and its rate
 *     checkpoint.
 * Amounts are USDC units (6 decimals) unless named `…18`; the mark, the value and the exit's thresholds
 * are signed. The hub owns the state and the transfers; nothing here reads or writes storage.
 */
library FeeMath {
    uint256 internal constant BP = 10_000;
    uint16 internal constant MAX_FEE_BP = 5_000;
    uint256 internal constant MIN_FEE_INTERVAL = 1 days;
    uint256 internal constant MAX_DAILY_PROFIT_BP = 50;
    uint256 internal constant MAX_CAP_WINDOW = 7 days;
    /// 18-decimal USD to USDC's 6
    int256 internal constant USD18_PER_USDC = 1e12;
    /// The largest |quantity| (18 decimals), price (18 decimals) and counter (USDC units) the value
    /// accepts: about 1.3e18 whole tokens, $1.3e18 a unit, $1.3e30. Far above anything real, they keep
    /// every product and sum below 2^255, so a forged report's absurd figure makes the value refused
    /// (`ValueOutOfRange`), never an overflow that would revert `payout` (decision 51).
    uint256 internal constant MAX_FIGURE = 2 ** 120;

    /// A holding, a price or a counter beyond `MAX_FIGURE`.
    error ValueOutOfRange();

    // ── rounding toward −∞ ───────────────────────────────────────────────────────────────────────────

    /// floor(a / d) for d > 0.
    function floorDiv(int256 a, int256 d) internal pure returns (int256 q) {
        q = a / d;
        if (a % d != 0 && a < 0) q -= 1;
    }

    /// floor(q × p / 1e18): a signed 18-decimal quantity at an 18-decimal price, in 18-decimal USD.
    function mulPrice(int256 q, uint256 p) internal pure returns (int256) {
        return floorDiv(q * int256(p), 1e18);
    }

    // ── the value (§3.4) ─────────────────────────────────────────────────────────────────────────────

    /// Σ quantities[i] × prices[i], each term floored, in 18-decimal USD; `ok` false when a figure is
    /// beyond `MAX_FIGURE`. A `USD` holding is priced 1e18 (face value) by the caller. At most 64 terms.
    function holdingsUsd18(int256[] memory quantities, uint256[] memory prices)
        internal
        pure
        returns (bool ok, int256 s)
    {
        if (quantities.length != prices.length || quantities.length > 64) return (false, 0);
        for (uint256 i; i < quantities.length; ++i) {
            int256 q = quantities[i];
            uint256 absQ = q < 0 ? uint256(-(q + 1)) + 1 : uint256(q);
            if (absQ > MAX_FIGURE || prices[i] > MAX_FIGURE) return (false, 0);
            s += mulPrice(q, prices[i]);
        }
        return (true, s);
    }

    /// One ordered pair's term: the gross amount in flight when the sender's figures are newer, negative
    /// when the receiver's are (a mint the receiver already holds that the sender's older figures still
    /// count as unsent: the term cancels the double count). `ok` false beyond `MAX_FIGURE`.
    function pairTerm(uint256 sentToReceiver, uint256 receivedFromSender) internal pure returns (bool ok, int256) {
        if (sentToReceiver > MAX_FIGURE || receivedFromSender > MAX_FIGURE) return (false, 0);
        return (true, int256(sentToReceiver) - int256(receivedFromSender));
    }

    /// v = the hub's free USDC + floor(Σ holdings in USD to 6 decimals) + Σ pair terms, in USDC units.
    function value(uint256 freeUsdc, int256 holdings18, int256 pairTerms) internal pure returns (int256) {
        return int256(freeUsdc) + floorDiv(holdings18, USD18_PER_USDC) + pairTerms;
    }

    // ── capital (§3.3) ───────────────────────────────────────────────────────────────────────────────

    /// What reached the hub without being one of its counted moves (capital), and the new `booked`. A
    /// balance below `booked` is re-based, never booked to the mark.
    function inflow(uint256 balance, uint256 booked) internal pure returns (uint256 capital, uint256 newBooked) {
        return (balance > booked ? balance - booked : 0, balance);
    }

    // ── crystallize and payout (§3.5) ────────────────────────────────────────────────────────────────

    /// The profit counted (capped when `capped`) and the fee `_charge` would take on it. `fee == 0` means
    /// nothing changes: the mark and `lastFeeAt` stay, the profit stays above the mark for a later charge.
    function charge(int256 v, int256 mark, uint256 lastFeeAt, uint256 nowTs, uint16 rateBp, bool capped)
        internal
        pure
        returns (uint256 profit, uint256 fee)
    {
        if (v <= 0 || v <= mark) return (0, 0);
        profit = uint256(v - mark);
        if (capped) {
            uint256 cap = profitCap(mark, lastFeeAt, nowTs);
            if (profit > cap) profit = cap;
        }
        fee = profit * rateBp / BP;
    }

    /// The most profit one capped charge counts: max(mark, 0) × 50 bp × min(now − lastFeeAt, 7 days) / 1 day.
    /// Its base is the mark, never the value: no report can move it.
    function profitCap(int256 mark, uint256 lastFeeAt, uint256 nowTs) internal pure returns (uint256) {
        if (mark <= 0 || nowTs <= lastFeeAt) return 0;
        uint256 window = nowTs - lastFeeAt;
        if (window > MAX_CAP_WINDOW) window = MAX_CAP_WINDOW;
        return uint256(mark) * MAX_DAILY_PROFIT_BP * window / (BP * 1 days);
    }

    /// The mark after a charge of `fee` on `profit`: the value counted, net of the fee.
    function markAfter(int256 mark, uint256 profit, uint256 fee) internal pure returns (int256) {
        return mark + int256(profit) - int256(fee);
    }

    // ── the exit (§3.6) ──────────────────────────────────────────────────────────────────────────────

    /// One `exitStep`'s settlement: every dollar the exit has handled (`realised`), and the fee due on it
    /// now, net of what was paid and forgiven, capped at the cash in hand. The caller forgives `due` when
    /// there is no fee address.
    function exitDue(
        uint256 exitPaid,
        uint256 exitFeePaid,
        uint256 exitFeeForgiven,
        uint256 cash,
        int256 exitFrom,
        uint256 exitCheckDue,
        uint16 rateBp
    ) internal pure returns (uint256 realised, uint256 due) {
        realised = exitPaid + exitFeePaid + cash;
        uint256 total = exitCheckDue + _above(realised, exitFrom) * rateBp / BP;
        uint256 settled = exitFeePaid + exitFeeForgiven;
        due = total > settled ? total - settled : 0;
        if (due > cash) due = cash;
    }

    /// The exit's rate checkpoint, run before a rate changes in exit: the profit the steps already
    /// handled keeps the old rate (fixed into `exitCheckDue`); every later dollar takes the new one.
    function exitCheckpoint(uint256 exitPaid, uint256 exitFeePaid, int256 exitFrom, uint256 exitCheckDue, uint16 oldRateBp)
        internal
        pure
        returns (int256 newExitFrom, uint256 newExitCheckDue)
    {
        uint256 handled = exitPaid + exitFeePaid;
        newExitCheckDue = exitCheckDue + _above(handled, exitFrom) * oldRateBp / BP;
        newExitFrom = int256(handled) > exitFrom ? int256(handled) : exitFrom;
    }

    /// max(0, amount − threshold), the threshold signed.
    function _above(uint256 amount, int256 threshold) private pure returns (uint256) {
        int256 d = int256(amount) - threshold;
        return d > 0 ? uint256(d) : 0;
    }
}
