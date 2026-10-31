// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {HyperCore} from "./HyperCore.sol";

/*
 * The contract route's units, limits and worst fill (hyperliquid-contract-route-design.md §4.2, §4.3), pure.
 *
 * Units (`szd` the perp's `szDecimals`): an order's `sz` is in 1e-8 of the coin, a position's `szi` in
 * 10^-szd (one "step"); the mark and the oracle in 10^-(6 - szd) USD, so `steps × price` is USD × 1e6, the
 * unit of `marginSummary`; an order's limit (what `boundedPx` returns and CoreWriter takes) is 1e8 × the
 * price. Every rounding goes against the trade's room: a cost rounds up, proceeds round down.
 */
library RouteMath {
    /// The taker fee a fill is costed at: Hyperliquid's base 4.5 bp, rounded up
    uint256 internal constant FEE_BP = 5;

    error BadSize();

    /// `sz` (1e-8) in whole size steps; a size HyperCore would drop silently is refused.
    function steps(uint64 sz, uint8 szd) internal pure returns (uint64) {
        uint64 unit = uint64(10 ** (8 - szd));
        if (sz % unit != 0) revert BadSize();
        return sz / unit;
    }

    /// `steps` at `px` (the mark's or the oracle's unit): USD × 1e6.
    function notional(uint64 st, uint64 px) internal pure returns (uint256) {
        return uint256(st) * px;
    }

    /// A limit (1e8 × the price) in the mark's unit: up when it is a buy's cost, down for a sale's proceeds.
    function pxOf(uint64 limit1e8, uint8 szd, bool roundUp) internal pure returns (uint64) {
        uint256 d = 10 ** (2 + szd);
        return uint64(roundUp ? (uint256(limit1e8) + d - 1) / d : limit1e8 / d);
    }

    /// The limit from the STRICTER of the two prices (a buy's ceiling from the lower, a sale's floor from
    /// the higher), moved by the band against the trade and rounded to a valid price that keeps the bound
    /// (`boundedPx`): so it is within `bp` of both the mark and the oracle (spec D11).
    function limitFor(uint64 oracle, uint64 mark, uint16 bp, bool isBuy, uint8 szd) internal pure returns (uint64) {
        uint64 ref = isBuy == (oracle < mark) ? oracle : mark;
        return HyperCore.boundedPx(uint256(ref) * 10 ** (2 + szd), bp, isBuy, 6 - szd);
    }

    /// A perp's maintenance ceiling (spec §4.1, §4.2): the largest band `b` (bp) whose compounded cost
    /// `(1 + b)(1 + FEE_BP) − 1` is at most half its maintenance rate `1 / (2 × maxLev)`, i.e.
    /// `((1e4 + b)(1e4 + FEE_BP) − 1e8) × 4 × maxLev ≤ 1e8`, exactly. BTC (40x) 57 bp, ETH (25x) 94 bp.
    /// Never negative for a max leverage Hyperliquid can show (at most 255x: 4 bp).
    function ceilingBp(uint256 maxLev) internal pure returns (uint256) {
        return 1e8 * (4 * maxLev + 1) / ((10_000 + FEE_BP) * 4 * maxLev) - 10_000;
    }

    /// A fill of `steps` at `px` valued against `ref` (the mark, or the oracle): `steps × |ref − px|` (either
    /// side counts as a loss: the spec's bound, never a gain) plus the fee at `px`, rounded up. USD × 1e6.
    function worstFill(uint64 st, uint64 ref, uint64 px, bool /* isBuy: either side counts */ )
        internal
        pure
        returns (uint256)
    {
        uint256 gap = ref > px ? ref - px : px - ref;
        return uint256(st) * gap + (uint256(st) * px * FEE_BP + 9_999) / 10_000;
    }
}
