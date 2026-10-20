// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * The fee's prices (step 11e2 amendment 2b §3.8): one price per asset, from a Chainlink source the
 * combination factory pins per (hub chain, asset), read AT AN INSTANT — the remote report's observation
 * time `t` — so every leg's positions and cash are valued together (Codex's fifth round).
 *
 * The caller names the round in effect at `t` (the engine reads it off chain beside the report); this
 * library only checks it, so no search runs on chain:
 *   - `getRoundData(hint).updatedAt ≤ t`, and either `hint` is the latest round or the next round of the
 *     same phase was updated after `t`; the hint must be in the latest round's phase (a round of an older
 *     phase is refused: rare, right after an aggregator upgrade, and only defers a fee);
 *   - `answer > 0` and `t − updatedAt ≤ maxAge`;
 *   - scaled to 18 decimals from the feed's own `decimals()`, rounded down.
 * A composite source (kind 2) is `feed × baseFeed` (a rate times a USD price, e.g. wstETH / ETH × ETH / USD),
 * one hint per feed, each checked the same way under the pin's one `maxAge`.
 *
 * On an L2 the sequencer feed must say the chain is up now (answer 0) and has been since before
 * `t − SEQUENCER_GRACE`.
 *
 * Nothing here reverts on a feed's answer: every read is a STATICCALL whose return data is checked
 * before decoding, and a refusal comes back as a reason (an error selector), never a revert. The
 * hub's views and `payout` (which must never wait for the fee, decision 51) rely on it.
 */

/// The factory's pin of one asset's price on one hub chain (§3.8).
struct PriceSourcePin {
    uint32 hubDomain; // the hub's chain (CCTP domain)
    bytes32 asset; // the holdings' asset id (`USD`, `ETH`, …)
    uint8 kind; // PriceSource.KIND_FEED or PriceSource.KIND_COMPOSITE
    address feed; // a USD price (kind 1), or the rate (kind 2)
    address baseFeed; // kind 2: the base's USD price; zero for kind 1
    uint32 maxAge; // seconds: the oldest round accepted at `t`
}

/// The L2 sequencer uptime feed of one hub chain (none on Ethereum).
struct SequencerPin {
    uint32 hubDomain;
    address feed;
}

library PriceSource {
    uint8 internal constant KIND_FEED = 1;
    uint8 internal constant KIND_COMPOSITE = 2;
    /// The sequencer must have been up for this long before the instant priced (amendment 2b §11.5).
    uint256 internal constant SEQUENCER_GRACE = 1 hours;

    /// The round is in effect at `t` but too old for the pin's `maxAge`, or its answer is not positive.
    error StalePrice();
    /// The hint is not the round in effect at `t` (or the feed can't answer for it).
    error BadRound();
    /// The L2 sequencer is down, restarted within the grace hour before `t`, or its feed can't answer.
    error SequencerDown();

    /// Chainlink's AggregatorV3Interface, the three reads used here.
    bytes4 private constant DECIMALS = 0x313ce567; // decimals()
    bytes4 private constant GET_ROUND_DATA = 0x9a6fc8f5; // getRoundData(uint80)
    bytes4 private constant LATEST_ROUND_DATA = 0xfeaf968c; // latestRoundData()

    /// The pin's price at `t` in 18 decimals; `why` is 0 when `ok`, else one of this library's error
    /// selectors. `hints` holds one round per feed: one for kind 1, two (feed, baseFeed) for kind 2.
    function priceAt(PriceSourcePin memory pin, uint256 t, uint80[] memory hints)
        internal
        view
        returns (bool ok, uint256 price, bytes4 why)
    {
        if (pin.kind == KIND_FEED) {
            if (hints.length != 1) return (false, 0, BadRound.selector);
            return roundAt(pin.feed, t, hints[0], pin.maxAge);
        }
        if (pin.kind == KIND_COMPOSITE) {
            if (hints.length != 2) return (false, 0, BadRound.selector);
            uint256 rate;
            (ok, rate, why) = roundAt(pin.feed, t, hints[0], pin.maxAge);
            if (!ok) return (false, 0, why);
            uint256 base;
            (ok, base, why) = roundAt(pin.baseFeed, t, hints[1], pin.maxAge);
            if (!ok) return (false, 0, why);
            if (base > type(uint256).max / rate) return (false, 0, StalePrice.selector);
            price = rate * base / 1e18;
            if (price == 0) return (false, 0, StalePrice.selector);
            return (true, price, bytes4(0));
        }
        return (false, 0, BadRound.selector);
    }

    /// The pin's latest round(s) usable at `t`: fresh within `maxAge`, a positive answer (amendment 2b §9:
    /// a stale price refuses the snapshot itself).
    function freshAt(PriceSourcePin memory pin, uint256 t) internal view returns (bool ok, bytes4 why) {
        (ok, why) = _latestFresh(pin.feed, t, pin.maxAge);
        if (ok && pin.kind == KIND_COMPOSITE) (ok, why) = _latestFresh(pin.baseFeed, t, pin.maxAge);
    }

    function _latestFresh(address feed, uint256 t, uint256 maxAge) private view returns (bool ok, bytes4 why) {
        (bool got, uint80 latest,,,) = _round(feed, abi.encodeWithSelector(LATEST_ROUND_DATA));
        if (!got) return (false, BadRound.selector);
        (ok,, why) = roundAt(feed, t, latest, maxAge);
    }

    /// A feed's latest round at `t`, checked as `roundAt` checks a hint (amendment 2c §3.5: the reward's
    /// price, read now).
    function latestAt(address feed, uint256 t, uint256 maxAge)
        internal
        view
        returns (bool ok, uint256 price, bytes4 why)
    {
        (bool got, uint80 latest,,,) = _round(feed, abi.encodeWithSelector(LATEST_ROUND_DATA));
        if (!got) return (false, 0, BadRound.selector);
        return roundAt(feed, t, latest, maxAge);
    }

    /// How many round hints a pin takes.
    function hintCount(uint8 kind) internal pure returns (uint256) {
        return kind == KIND_COMPOSITE ? 2 : 1;
    }

    /// One feed's answer at `t` in 18 decimals, from the caller's round `hint`, checked.
    function roundAt(address feed, uint256 t, uint80 hint, uint256 maxAge)
        internal
        view
        returns (bool ok, uint256 price, bytes4 why)
    {
        (bool got, uint80 latest,,,) = _round(feed, abi.encodeWithSelector(LATEST_ROUND_DATA));
        if (!got || hint > latest || hint >> 64 != latest >> 64) return (false, 0, BadRound.selector);
        (bool read, uint80 id, int256 answer, uint256 updatedAt) = _roundData(feed, hint);
        if (!read || id != hint || updatedAt == 0 || updatedAt > t) return (false, 0, BadRound.selector);
        if (hint != latest) {
            (bool nextRead, uint80 nextId,, uint256 nextUpdatedAt) = _roundData(feed, hint + 1);
            if (!nextRead || nextId != hint + 1 || nextUpdatedAt <= t) return (false, 0, BadRound.selector);
        }
        if (answer <= 0 || t - updatedAt > maxAge) return (false, 0, StalePrice.selector);
        (bool dok, uint256 d) = _decimals(feed);
        if (!dok) return (false, 0, BadRound.selector);
        uint256 a = uint256(answer);
        if (d <= 18) {
            uint256 scale = 10 ** (18 - d);
            if (a > type(uint256).max / scale) return (false, 0, StalePrice.selector);
            price = a * scale;
        } else {
            price = a / 10 ** (d - 18);
        }
        if (price == 0) return (false, 0, StalePrice.selector);
        return (true, price, bytes4(0));
    }

    /// The L2 sequencer is up now and has been since before `t − SEQUENCER_GRACE`. A zero feed: no
    /// sequencer to check (Ethereum).
    function sequencerUp(address feed, uint256 t) internal view returns (bool ok, bytes4 why) {
        if (feed == address(0)) return (true, bytes4(0));
        (bool got,, int256 answer, uint256 startedAt,) = _round(feed, abi.encodeWithSelector(LATEST_ROUND_DATA));
        // startedAt == 0: the feed's round is not initialised (Chainlink's own guard on Arbitrum)
        if (!got || answer != 0 || startedAt == 0 || startedAt > t || t - startedAt < SEQUENCER_GRACE) {
            return (false, SequencerDown.selector);
        }
        return (true, bytes4(0));
    }

    function _roundData(address feed, uint80 id)
        private
        view
        returns (bool ok, uint80 roundId, int256 answer, uint256 updatedAt)
    {
        (ok, roundId, answer,, updatedAt) = _round(feed, abi.encodeWithSelector(GET_ROUND_DATA, id));
    }

    /// `(roundId, answer, startedAt, updatedAt, answeredInRound)`, with `ok` false when the call reverts,
    /// the feed has no code or returns too little.
    function _round(address feed, bytes memory data)
        private
        view
        returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt)
    {
        if (feed.code.length == 0) return (false, 0, 0, 0, 0);
        bytes memory ret;
        (ok, ret) = feed.staticcall(data);
        if (!ok || ret.length < 160) return (false, 0, 0, 0, 0);
        uint256 rawId;
        (rawId, answer, startedAt, updatedAt) = abi.decode(ret, (uint256, int256, uint256, uint256));
        if (rawId > type(uint80).max) return (false, 0, 0, 0, 0);
        roundId = uint80(rawId);
    }

    function _decimals(address feed) private view returns (bool ok, uint256 d) {
        (bool called, bytes memory ret) = feed.staticcall(abi.encodeWithSelector(DECIMALS));
        if (!called || ret.length < 32) return (false, 0);
        d = abi.decode(ret, (uint256));
        // a uint8 in the interface; beyond 36 the scaling is meaningless
        return (d <= 36, d);
    }
}
