// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PriceSource, PriceSourcePin} from "../src/lib/PriceSource.sol";
import {MockAggregator, ShortAnswerFeed} from "./mocks/MockAggregator.sol";

/// The library is internal; the hub inlines it. This exposes it to the tests.
contract PriceSourceHarness {
    function priceAt(PriceSourcePin memory pin, uint256 t, uint80[] memory hints)
        external
        view
        returns (bool, uint256, bytes4)
    {
        return PriceSource.priceAt(pin, t, hints);
    }

    function sequencerUp(address feed, uint256 t) external view returns (bool, bytes4) {
        return PriceSource.sequencerUp(feed, t);
    }
}

/// The fee's prices (amendment 2b §3.8, §9 "Price sources" and the price hints of Codex's fifth round):
/// the round in effect at `t`, named by the caller and checked; age, sign, decimals, phases, gaps, the
/// composite kind and the sequencer, each refused with its reason and never by a revert.
contract PriceSourceTest is Test {
    bytes32 constant ETH = "ETH";
    uint32 constant MAX_AGE = 1 hours; // the ETH / USD pin's (the operator's call, 2026-10-16)
    PriceSourceHarness h;
    MockAggregator feed;
    uint80 r1;
    uint80 r2;
    uint80 r3;

    function setUp() public {
        vm.warp(1_000_000);
        h = new PriceSourceHarness();
        feed = new MockAggregator(8);
        r1 = feed.id(1, 1);
        r2 = feed.id(1, 2);
        r3 = feed.id(1, 3);
        feed.push(r1, 2_500e8, 900_100);
        feed.push(r2, 2_400e8, 900_200);
        feed.push(r3, 2_450e8, 900_300);
    }

    function _pin(address f) internal pure returns (PriceSourcePin memory) {
        return PriceSourcePin(3, ETH, PriceSource.KIND_FEED, f, address(0), MAX_AGE);
    }

    function _hints(uint80 a) internal pure returns (uint80[] memory x) {
        x = new uint80[](1);
        x[0] = a;
    }

    function _hints(uint80 a, uint80 b) internal pure returns (uint80[] memory x) {
        x = new uint80[](2);
        x[0] = a;
        x[1] = b;
    }

    function _expect(PriceSourcePin memory pin, uint256 t, uint80[] memory hints, bytes4 why) internal view {
        (bool ok, uint256 p, bytes4 w) = h.priceAt(pin, t, hints);
        assertFalse(ok, "refused");
        assertEq(p, 0);
        assertEq(w, why, "reason");
    }

    function _price(PriceSourcePin memory pin, uint256 t, uint80[] memory hints) internal view returns (uint256) {
        (bool ok, uint256 p, bytes4 w) = h.priceAt(pin, t, hints);
        assertTrue(ok, "accepted");
        assertEq(w, bytes4(0));
        return p;
    }

    // ── the round in effect at t ─────────────────────────────────────────────────────────────────────

    function test_roundInEffect_accepted_scaledTo18() public view {
        assertEq(_price(_pin(address(feed)), 900_250, _hints(r2)), 2_400e18);
        // t exactly at a round's update: that round is in effect
        assertEq(_price(_pin(address(feed)), 900_200, _hints(r2)), 2_400e18);
        assertEq(_price(_pin(address(feed)), 900_199, _hints(r1)), 2_500e18);
    }

    function test_roundBeforeTheOneInEffect_refused() public view {
        _expect(_pin(address(feed)), 900_250, _hints(r1), PriceSource.BadRound.selector);
        // the next round updated exactly at t: the hint is no longer in effect
        _expect(_pin(address(feed)), 900_200, _hints(r1), PriceSource.BadRound.selector);
    }

    function test_roundAfterTheOneInEffect_refused() public view {
        _expect(_pin(address(feed)), 900_250, _hints(r3), PriceSource.BadRound.selector);
        _expect(_pin(address(feed)), 900_099, _hints(r1), PriceSource.BadRound.selector);
    }

    function test_latestRound_acceptedWhenNoLaterOneExists() public {
        assertEq(_price(_pin(address(feed)), 900_300, _hints(r3)), 2_450e18);
        // t in the future of the hub's clock (a report within MAX_CLOCK_SKEW): still the latest round
        vm.warp(900_400);
        assertEq(_price(_pin(address(feed)), vm.getBlockTimestamp() + 60, _hints(r3)), 2_450e18);
    }

    function test_roundBeyondTheLatest_refused() public view {
        _expect(_pin(address(feed)), 900_400, _hints(feed.id(1, 4)), PriceSource.BadRound.selector);
    }

    function test_gap_missingRound_refused_bothFeedStyles() public {
        // round 4 never written, round 5 is the latest
        uint80 r5 = feed.id(1, 5);
        feed.push(r5, 2_460e8, 900_500);
        _expect(_pin(address(feed)), 900_400, _hints(r3), PriceSource.BadRound.selector);
        _expect(_pin(address(feed)), 900_400, _hints(feed.id(1, 4)), PriceSource.BadRound.selector);
        feed.setRevertOnMissing(false);
        _expect(_pin(address(feed)), 900_400, _hints(r3), PriceSource.BadRound.selector);
        _expect(_pin(address(feed)), 900_400, _hints(feed.id(1, 4)), PriceSource.BadRound.selector);
    }

    function test_phases_hintMustBeInTheLatestPhase() public {
        uint80 p2r1 = feed.id(2, 1);
        feed.push(p2r1, 2_470e8, 900_600);
        // the old phase's last round, in effect before the new phase began, is refused (a deferral)
        _expect(_pin(address(feed)), 900_500, _hints(r3), PriceSource.BadRound.selector);
        assertEq(_price(_pin(address(feed)), 900_700, _hints(p2r1)), 2_470e18);
        // a round id of the new phase whose aggregator round is low but whose phase is old
        _expect(_pin(address(feed)), 900_700, _hints(feed.id(1, 1)), PriceSource.BadRound.selector);
        uint80 p2r2 = feed.id(2, 2);
        feed.push(p2r2, 2_480e8, 900_800);
        assertEq(_price(_pin(address(feed)), 900_799, _hints(p2r1)), 2_470e18);
        _expect(_pin(address(feed)), 900_800, _hints(p2r1), PriceSource.BadRound.selector);
    }

    // ── age, sign, decimals ──────────────────────────────────────────────────────────────────────────

    function test_staleFeed_refused_atMaxAgeAccepted() public view {
        assertEq(_price(_pin(address(feed)), 900_300 + MAX_AGE, _hints(r3)), 2_450e18);
        _expect(_pin(address(feed)), 900_300 + MAX_AGE + 1, _hints(r3), PriceSource.StalePrice.selector);
    }

    function test_nonPositiveAnswer_refused() public {
        feed.push(feed.id(1, 4), 0, 900_400);
        _expect(_pin(address(feed)), 900_400, _hints(feed.id(1, 4)), PriceSource.StalePrice.selector);
        feed.push(feed.id(1, 5), -1, 900_500);
        _expect(_pin(address(feed)), 900_500, _hints(feed.id(1, 5)), PriceSource.StalePrice.selector);
    }

    function test_decimalsOtherThan8() public {
        MockAggregator f18 = new MockAggregator(18);
        f18.push(f18.id(1, 1), 1.234567890123456789e18, 900_000);
        assertEq(_price(_pin(address(f18)), 900_000, _hints(f18.id(1, 1))), 1.234567890123456789e18);
        MockAggregator f6 = new MockAggregator(6);
        f6.push(f6.id(1, 1), 2_437_890_000, 900_000);
        assertEq(_price(_pin(address(f6)), 900_000, _hints(f6.id(1, 1))), 2_437.89e18);
        MockAggregator f0 = new MockAggregator(0);
        f0.push(f0.id(1, 1), 3, 900_000);
        assertEq(_price(_pin(address(f0)), 900_000, _hints(f0.id(1, 1))), 3e18);
        // more than 18: rounded down
        MockAggregator f20 = new MockAggregator(20);
        f20.push(f20.id(1, 1), 199, 900_000);
        assertEq(_price(_pin(address(f20)), 900_000, _hints(f20.id(1, 1))), 1);
        f20.push(f20.id(1, 2), 99, 900_100);
        _expect(_pin(address(f20)), 900_100, _hints(f20.id(1, 2)), PriceSource.StalePrice.selector);
    }

    // ── the composite kind ───────────────────────────────────────────────────────────────────────────

    function test_composite_rateTimesBase() public {
        MockAggregator rate = new MockAggregator(18); // wstETH / ETH
        rate.push(rate.id(1, 7), 1.21e18, 900_150);
        PriceSourcePin memory pin =
            PriceSourcePin(3, "WSTETH", PriceSource.KIND_COMPOSITE, address(rate), address(feed), MAX_AGE);
        assertEq(_price(pin, 900_250, _hints(rate.id(1, 7), r2)), 2_904e18); // 1.21 × 2,400
        // one hint per feed: either feed's wrong round refuses
        _expect(pin, 900_250, _hints(rate.id(1, 7), r3), PriceSource.BadRound.selector);
        _expect(pin, 900_250, _hints(rate.id(1, 6), r2), PriceSource.BadRound.selector);
        _expect(pin, 900_250, _hints(r2), PriceSource.BadRound.selector);
        // the rate stale at t refuses the whole price
        _expect(pin, 900_150 + MAX_AGE + 1, _hints(rate.id(1, 7), r3), PriceSource.StalePrice.selector);
    }

    function test_unknownKind_orWrongHintCount_refused() public view {
        PriceSourcePin memory pin = _pin(address(feed));
        _expect(pin, 900_250, _hints(r2, r2), PriceSource.BadRound.selector);
        _expect(pin, 900_250, new uint80[](0), PriceSource.BadRound.selector);
        pin.kind = 3;
        _expect(pin, 900_250, _hints(r2), PriceSource.BadRound.selector);
        pin.kind = 0;
        _expect(pin, 900_250, _hints(r2), PriceSource.BadRound.selector);
    }

    // ── a feed that misbehaves is a refusal, never a revert ──────────────────────────────────────────

    function test_brokenFeeds_refusedWithoutRevert() public {
        _expect(_pin(address(0)), 900_250, _hints(r2), PriceSource.BadRound.selector);
        _expect(_pin(makeAddr("eoa")), 900_250, _hints(r2), PriceSource.BadRound.selector);
        _expect(_pin(address(new ShortAnswerFeed())), 900_250, _hints(r2), PriceSource.BadRound.selector);
        feed.setBroken(true);
        _expect(_pin(address(feed)), 900_250, _hints(r2), PriceSource.BadRound.selector);
    }

    function testFuzz_neverReverts(uint80 hint, uint256 t, int256 answer, uint8 decimals) public {
        t = bound(t, 0, 2 ** 64);
        MockAggregator f = new MockAggregator(decimals);
        f.push(f.id(1, 1), answer, 900_000);
        f.push(f.id(1, 2), answer, 900_100);
        h.priceAt(_pin(address(f)), t, _hints(hint));
        h.priceAt(PriceSourcePin(3, ETH, 2, address(f), address(f), MAX_AGE), t, _hints(hint, f.id(1, 2)));
    }

    // ── the L2 sequencer ─────────────────────────────────────────────────────────────────────────────

    function test_sequencer() public {
        MockAggregator seq = new MockAggregator(0);
        uint256 t = 1_000_000;
        // no sequencer pinned (Ethereum): nothing to check
        (bool ok, bytes4 why) = h.sequencerUp(address(0), t);
        assertTrue(ok);
        assertEq(why, bytes4(0));
        // up since more than an hour before t
        seq.setStatus(seq.id(1, 1), 0, t - 1 hours);
        (ok,) = h.sequencerUp(address(seq), t);
        assertTrue(ok, "up for the whole grace hour");
        // restarted within the grace hour
        seq.setStatus(seq.id(1, 2), 0, t - 1 hours + 1);
        (ok, why) = h.sequencerUp(address(seq), t);
        assertFalse(ok);
        assertEq(why, PriceSource.SequencerDown.selector);
        // restarted after t (it went down between the report and the charge)
        seq.setStatus(seq.id(1, 3), 0, t + 10);
        (ok,) = h.sequencerUp(address(seq), t);
        assertFalse(ok);
        // down now
        seq.setStatus(seq.id(1, 4), 1, t - 2 hours);
        (ok, why) = h.sequencerUp(address(seq), t);
        assertFalse(ok);
        assertEq(why, PriceSource.SequencerDown.selector);
        // an uninitialised round (Chainlink's own guard)
        seq.setStatus(seq.id(1, 5), 0, 0);
        (ok,) = h.sequencerUp(address(seq), t);
        assertFalse(ok);
        // a feed that reverts or has no code
        seq.setBroken(true);
        (ok,) = h.sequencerUp(address(seq), t);
        assertFalse(ok);
        (ok,) = h.sequencerUp(makeAddr("eoa"), t);
        assertFalse(ok);
    }
}
