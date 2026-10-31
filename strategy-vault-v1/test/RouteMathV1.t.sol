// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {RouteMath} from "../src/lib/RouteMath.sol";
import {HyperCore} from "../src/lib/HyperCore.sol";

/// `RouteMath`'s functions behind external calls, so a revert can be expected.
contract RouteMathHarness {
    function steps(uint64 sz, uint8 szd) external pure returns (uint64) {
        return RouteMath.steps(sz, szd);
    }
}

/*
 * The contract route's units, limits and worst fill (hyperliquid-contract-route-design.md §4.2, §4.3):
 * the spec's own examples, as numbers.
 */
contract RouteMathV1Test is Test {
    RouteMathHarness h;

    function setUp() public {
        h = new RouteMathHarness();
    }

    /// ETH (szd 4), mark $2,000: 0.5 ETH is 5,000 steps and $1,000; a sale's limit at 15 bp is 1.997e11
    /// (1e8), 199,700 in the mark's unit; its worst fill $1.50 against the mark plus the fee, $0.49925.
    function test_eth() public view {
        assertEq(h.steps(5e7, 4), 5_000);
        assertEq(RouteMath.notional(5_000, 200_000), 1e9);
        uint64 limit = RouteMath.limitFor(200_000, 200_000, 15, false, 4);
        assertEq(limit, 1.997e11);
        assertEq(RouteMath.pxOf(limit, 4, false), 199_700);
        assertEq(RouteMath.worstFill(5_000, 200_000, 199_700, false), 1.5e6 + 499_250);
        // Hyperliquid's $10 minimum, at the sale's price
        assertGe(RouteMath.notional(5_000, 199_700), 1e7);
    }

    function test_steps_refusesAPartialStep() public {
        vm.expectRevert(RouteMath.BadSize.selector);
        h.steps(5e7 + 1, 4);
        vm.expectRevert(RouteMath.BadSize.selector);
        h.steps(999, 5); // BTC: a step is 1,000 (1e-5 BTC in 1e-8)
        assertEq(h.steps(1_000, 5), 1);
        assertEq(h.steps(0, 5), 0);
    }

    /// BTC (szd 5), mark $100,000: 1,000 steps (0.01 BTC) is $1,000.
    function test_btc() public view {
        assertEq(h.steps(1e6, 5), 1_000);
        assertEq(RouteMath.notional(1_000, 1_000_000), 1e9);
        uint64 limit = RouteMath.limitFor(1_000_000, 1_000_000, 15, false, 5);
        assertEq(RouteMath.pxOf(limit, 5, false), 998_500);
        assertEq(RouteMath.worstFill(1_000, 1_000_000, 998_500, false), 1.5e6 + 499_250);
    }

    /// The stricter of the two prices: a buy's ceiling from the lower, a sale's floor from the higher.
    function test_limitFor_theStricterPrice() public pure {
        // oracle 200,000, mark 201,000 (ETH, 10^-2 USD): the buy's ceiling comes from the oracle
        uint64 buy = RouteMath.limitFor(200_000, 201_000, 15, true, 4);
        assertEq(buy, HyperCore.boundedPx(200_000 * 1e6, 15, true, 2));
        assertLe(uint256(buy), uint256(200_000) * 1e6 * 10_015 / 10_000);
        assertEq(buy, RouteMath.limitFor(201_000, 200_000, 15, true, 4)); // either way round
        // the sale's floor from the mark (the higher)
        uint64 sale = RouteMath.limitFor(200_000, 201_000, 15, false, 4);
        assertEq(sale, HyperCore.boundedPx(201_000 * 1e6, 15, false, 2));
        assertGe(uint256(sale), uint256(201_000) * 1e6 * 9_985 / 10_000);
        assertEq(sale, RouteMath.limitFor(201_000, 200_000, 15, false, 4));
        // within the band of BOTH prices
        assertLe(uint256(buy), uint256(201_000) * 1e6 * 10_015 / 10_000);
        assertGe(uint256(sale), uint256(200_000) * 1e6 * 9_985 / 10_000);
    }

    /// `pxOf` rounds against the trade's room: up for a buy's cost, down for a sale's proceeds.
    function test_pxOf_rounding() public pure {
        assertEq(RouteMath.pxOf(1.9970001e11, 4, true), 199_701);
        assertEq(RouteMath.pxOf(1.9970001e11, 4, false), 199_700);
        assertEq(RouteMath.pxOf(1.997e11, 4, true), 199_700);
    }

    /// Either side of the mark counts as a loss (the spec's |mark − px|), and the fee rounds up.
    function test_worstFill_bothSidesAndFeeRoundedUp() public pure {
        assertEq(RouteMath.worstFill(1, 1_000, 1_010, true), 10 + 1); // 1 × 1,010 × 5 / 10,000 = 0.505 → 1
        assertEq(RouteMath.worstFill(1, 1_010, 1_000, true), 10 + 1);
        assertEq(RouteMath.worstFill(2, 1_000, 1_000, false), 1); // 1.0 → 1
        assertEq(RouteMath.worstFill(0, 1_000, 900, false), 0);
    }
    /// A perp's maintenance ceiling (spec §4.1, §4.2): the largest band whose compounded cost
    /// `(1 + b)(1 + FEE_BP) − 1` is at most half the maintenance rate, `1 / (4 × max)`. BTC (40x) 57 bp,
    /// ETH (25x) 94 bp, HYPE (10x) 244 bp; one bp more is over.
    function test_ceilingBp() public pure {
        uint256[3] memory lev = [uint256(40), 25, 10];
        uint256[3] memory want = [uint256(57), 94, 244];
        for (uint256 i; i < 3; ++i) {
            uint256 b = RouteMath.ceilingBp(lev[i]);
            assertEq(b, want[i]);
            assertLe(((10_000 + b) * (10_000 + RouteMath.FEE_BP) - 1e8) * 4 * lev[i], 1e8);
            assertGt(((10_000 + b + 1) * (10_000 + RouteMath.FEE_BP) - 1e8) * 4 * lev[i], 1e8);
        }
    }
}
