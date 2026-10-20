// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {IFeeRegistry, StrategyHubState} from "./StrategyHubState.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {FeeMath} from "./lib/FeeMath.sol";
import {PriceSource, PriceSourcePin} from "./lib/PriceSource.sol";
import {Assets, Holding, Legs} from "./lib/VaultTypes.sol";

/// A leg beside the hub: its report's figures as a view (amendment 2b §3.4).
interface ILegView {
    function holdings()
        external
        view
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool);
}

/*
 * The hub's FEE MODULE (step 11e2 amendment 2b §3.4–§3.7): the valuation and the functions that charge
 * on it, run only by DELEGATECALL from a hub (`StrategyHub`'s fallback), in the hub's storage; called
 * directly, or through a hub code never initialized, they refuse (`delegated`). Here for size (amendment
 * 2a §3.8's mechanism): with them inline the hub is over EIP-170.
 *
 * The VALUE is the strategy's at one instant (§3.4): `snapshot()` records every leg on the hub's chain;
 * the one leg elsewhere counts by its report observed 1 to 3 minutes after the snapshot; every asset is
 * priced at the Chainlink round in effect at that report's instant (the caller names it, this module
 * checks it); the legs here must be unchanged since the snapshot (`opCount` the same, every non-USD
 * position within 1 bp). The money between members counts once by the signed pair terms.
 */
contract StrategyHubFee is StrategyHubState {
    // ── the execution key ────────────────────────────────────────────────────────────────────────────

    /// Records, at this block, every leg on this chain (its holdings, its counters, its `opCount`): the
    /// instant the value starts from. A leg whose position the hub can't re-read on its own is refused
    /// (`UntrackedLeg`); so is a snapshot while the sequencer is down or a pinned price is stale.
    function snapshot() external delegated onlyExecution nonReentrant {
        (bool up, bytes4 why) = PriceSource.sequencerUp(sequencerFeed, block.timestamp);
        if (!up) _revert(why);
        for (uint256 i; i < _priceSources.length; ++i) {
            (up, why) = PriceSource.freshAt(_priceSources[i], block.timestamp);
            if (!up) _revert(why);
        }
        uint8 n = linkCount;
        for (uint8 k; k < n; ++k) {
            if (!_isLocal(k)) continue;
            (bool ok, bytes memory ret) = links[k].staticcall(abi.encodeCall(ILegView.holdings, ()));
            if (!ok) revert UntrackedLeg();
            (,,,,,, bool tracked) = _decodeView(ret);
            if (!tracked) revert UntrackedLeg();
            _snapshots[k] = ret;
        }
        snapshotAt = uint64(block.timestamp);
        emit Snapshot(uint64(block.timestamp));
    }

    /// Charges the fee on the profit above the mark, at most once a day, capped (§3.5). Refused with the
    /// value's reason, `TooSoon`, or `NeedUsdc`; with no fee address it defers.
    function crystallize(uint80[] calldata rounds) external delegated onlyExecution nonReentrant {
        _sync();
        if (block.timestamp < uint256(lastFeeAt) + FeeMath.MIN_FEE_INTERVAL) revert TooSoon();
        (bool ok, int256 v, bytes4 why, uint64 seq) = _value(rounds);
        if (!ok) _revert(why);
        why = _charge(v, seq);
        if (why != 0) emit FeeDeferred(why);
    }

    /// USDC to the owner, the user's deposit contract on this chain. It charges the fee first when it
    /// can; when it can't (too soon, the value refused, the hub short of USDC for both), it pays anyway
    /// and the profit stays above the mark (decision 51).
    function payout(uint256 amount, uint80[] calldata rounds) external delegated onlyExecution nonReentrant {
        _sync();
        bytes4 why = TooSoon.selector;
        if (block.timestamp >= uint256(lastFeeAt) + FeeMath.MIN_FEE_INTERVAL) {
            (bool ok, int256 v, bytes4 w, uint64 seq) = _value(rounds);
            why = w;
            if (ok) {
                (, uint256 fee) = FeeMath.charge(v, mark, lastFeeAt, block.timestamp, feeRateBp, true);
                why = _free() < amount + fee ? NeedUsdc.selector : _charge(v, seq);
            }
        }
        if (why != 0) emit FeeDeferred(why);
        if (amount > _free()) revert NeedUsdc();
        address to = owner;
        IERC20(_usdc()).transfer(to, amount);
        booked -= amount;
        mark -= int256(amount);
        emit Payout(to, amount);
    }

    /// The capped charge; returns why it deferred (no fee address), 0 otherwise.
    function _charge(int256 v, uint64 seq) internal returns (bytes4) {
        (uint256 profit, uint256 fee) = FeeMath.charge(v, mark, lastFeeAt, block.timestamp, feeRateBp, true);
        if (fee == 0) return 0;
        address to = IFeeRegistry(registry).feeAddress();
        if (to == address(0)) return NoFeeAddress.selector;
        if (_free() < fee) revert NeedUsdc();
        _payFee(to, fee);
        int256 before = mark;
        mark = FeeMath.markAfter(before, profit, fee);
        lastFeeAt = uint64(block.timestamp);
        emit FeeCharged(v, before, profit, fee, mark, feeRateBp, snapshotAt, seq);
        return 0;
    }

    // ── the rate (§3.7) ──────────────────────────────────────────────────────────────────────────────────

    /// The recovery key of this chain's registry sets the strategy's rate (the operator's decision of
    /// 2026-10-16, replacing §3.7's owner raise), never above the rate the owner signed
    /// (`signedFeeRateBp`, the security review of 2026-10-16): lowered at any time, restored up to it
    /// outside the exit, never raised in exit. It applies to every profit not yet charged, which only
    /// `crystallize` and `payout` charge, capped on the mark; in exit, where only a lowering is possible,
    /// the exit's checkpoint runs first, so the profit the steps already handled keeps the rate it was
    /// handled at and the cash not yet stepped takes the lower one.
    function setFeeRate(uint16 newBp) external delegated nonReentrant {
        if (msg.sender != IFeeRegistry(registry).recovery()) revert NotAllowed();
        if (newBp > signedFeeRateBp || (exiting && newBp > feeRateBp)) revert BadRate();
        _setRate(newBp, msg.sender);
    }

    // ── the value (§3.4) ─────────────────────────────────────────────────────────────────────────────────

    /// The strategy's value in USDC units, from the latest usable snapshot and the price in effect at the
    /// remote report's instant; `rounds` are the caller's round hints, one per feed in the pins' order.
    function value(uint80[] calldata rounds) external view delegated returns (bool ok, int256 v, bytes32 why) {
        bytes4 w;
        (ok, v, w,) = _value(rounds);
        why = bytes32(w);
    }

    /// What `crystallize` would charge now, with the reason when it can't: the value, the mark as synced,
    /// the profit above it, the profit the cap counts, the fee, and when the next charge may run.
    function preview(uint80[] calldata rounds)
        external
        view
        delegated
        returns (
            bool ok,
            bytes32 why,
            int256 v,
            int256 markSynced,
            uint256 profit,
            uint256 cappedProfit,
            uint256 fee,
            uint256 chargeableAt
        )
    {
        bytes4 w;
        (ok, v, w,) = _value(rounds);
        (uint256 inflow,) = FeeMath.inflow(IERC20(_usdc()).balanceOf(address(this)), booked);
        markSynced = mark + int256(inflow); // a deposit not yet synced never shows as profit
        chargeableAt = uint256(lastFeeAt) + FeeMath.MIN_FEE_INTERVAL;
        if (ok) {
            if (v > markSynced && v > 0) profit = uint256(v - markSynced);
            (cappedProfit, fee) = FeeMath.charge(v, markSynced, lastFeeAt, block.timestamp, feeRateBp, true);
            if (block.timestamp < chargeableAt) w = TooSoon.selector;
            else if (fee > 0 && IFeeRegistry(registry).feeAddress() == address(0)) w = NoFeeAddress.selector;
            else if (_free() < fee) w = NeedUsdc.selector;
            if (w != 0) fee = 0;
        }
        why = bytes32(w);
    }

    /// The figures of one member: its holdings and its counters (indexed by its own links).
    struct Figures {
        Holding[] holdings;
        uint256[4] sent;
        uint256[4] received;
    }

    function _value(uint80[] calldata rounds) internal view returns (bool, int256, bytes4, uint64 seq) {
        uint256 at = snapshotAt;
        if (at == 0) return (false, 0, NoSnapshot.selector, 0);
        uint8 n = linkCount;
        Figures[] memory f = new Figures[](n + 1); // member order: 0 the hub, link k is member k + 1
        (f[0].sent, f[0].received) = (sentTo, receivedFrom);
        uint256 t = at; // the instant: the remote report's, else the snapshot's
        uint256 remotes;
        for (uint8 k; k < n; ++k) {
            if (legValueKind[k] != Legs.VALUE_READ) return (false, 0, ReportedValue.selector, 0);
            if (!_isLocal(k)) ++remotes;
        }
        if (remotes > 1) return (false, 0, TooManyRemote.selector, 0);
        for (uint8 k; k < n; ++k) {
            Figures memory g = f[k + 1];
            if (_isLocal(k)) {
                uint64 ops;
                (g.holdings, g.sent, g.received,,, ops,) = _decodeView(_snapshots[k]);
                (bool ok, bytes memory live) = links[k].staticcall(abi.encodeCall(ILegView.holdings, ()));
                if (!ok) return (false, 0, PositionMoved.selector, 0);
                (Holding[] memory now_,,,,, uint64 liveOps,) = _decodeView(live);
                if (liveOps != ops || !_steady(g.holdings, now_)) return (false, 0, PositionMoved.selector, 0);
            } else {
                Report storage r = _reports[k];
                uint256 obs = r.observedAt;
                if (obs > block.timestamp + MAX_CLOCK_SKEW) return (false, 0, FutureReport.selector, 0);
                if (r.seq == 0 || block.timestamp > obs + MAX_REPORT_AGE) return (false, 0, StaleReport.selector, 0);
                if (obs < at + MAX_CLOCK_SKEW || obs > at + SNAPSHOT_WINDOW) {
                    return (false, 0, SnapshotIncomplete.selector, 0);
                }
                uint256 obsBlock;
                uint256 moveBlock;
                bytes memory body = r.body;
                (,,, obsBlock, moveBlock, g.holdings, g.sent, g.received,) = abi.decode(
                    body, (bytes32, uint256, uint256, uint256, uint256, Holding[], uint256[4], uint256[4], uint256[4])
                );
                if (obsBlock < moveBlock || obsBlock - moveBlock < MIN_BLOCKS_AFTER_MOVE) {
                    return (false, 0, MoveSettling.selector, 0);
                }
                t = obs;
                seq = r.seq;
            }
        }
        // the snapshot's own age, after the remote report's (a stale report is reported as such)
        if (block.timestamp > at + MAX_REPORT_AGE) return (false, 0, NoSnapshot.selector, 0);
        (bool up, bytes4 why) = PriceSource.sequencerUp(sequencerFeed, t);
        if (!up) return (false, 0, why, 0);
        int256 usd18;
        (up, usd18, why) = _priced(f, t, rounds);
        if (!up) return (false, 0, why, 0);
        int256 pairs;
        for (uint256 i; i <= n; ++i) {
            for (uint256 j; j <= n; ++j) {
                if (i == j) continue;
                // member j among member i's links: every other member, in member order
                (bool inRange, int256 term) =
                    FeeMath.pairTerm(f[i].sent[j < i ? j : j - 1], f[j].received[i < j ? i : i - 1]);
                if (!inRange) return (false, 0, FeeMath.ValueOutOfRange.selector, 0);
                pairs += term;
            }
        }
        return (true, FeeMath.value(_free(), usd18, pairs), 0, seq);
    }

    /// Every holding at its asset's price in effect at `t`: `USD` at face, any other by its pin (each pin
    /// read once, its hints at its offset in `rounds`), in 18-decimal USD.
    function _priced(Figures[] memory f, uint256 t, uint80[] calldata rounds)
        internal
        view
        returns (bool, int256, bytes4)
    {
        uint256 np = _priceSources.length;
        uint256[] memory px = new uint256[](np);
        uint256[] memory offset = new uint256[](np);
        uint256 hints;
        uint256 terms;
        for (uint256 i; i < np; ++i) {
            offset[i] = hints;
            hints += PriceSource.hintCount(_priceSources[i].kind);
        }
        if (rounds.length != hints) return (false, 0, PriceSource.BadRound.selector);
        for (uint256 m; m < f.length; ++m) {
            terms += f[m].holdings.length;
        }
        int256[] memory q = new int256[](terms);
        uint256[] memory p = new uint256[](terms);
        terms = 0;
        for (uint256 m; m < f.length; ++m) {
            Holding[] memory h = f[m].holdings;
            for (uint256 x; x < h.length; ++x) {
                q[terms] = h[x].quantity;
                if (h[x].asset == Assets.USD) {
                    p[terms++] = 1e18;
                    continue;
                }
                uint256 i;
                while (i < np && _priceSources[i].asset != h[x].asset) ++i;
                if (i == np) return (false, 0, UnknownAsset.selector);
                if (px[i] == 0) {
                    PriceSourcePin memory pin = _priceSources[i];
                    uint80[] memory mine = new uint80[](PriceSource.hintCount(pin.kind));
                    for (uint256 y; y < mine.length; ++y) {
                        mine[y] = rounds[offset[i] + y];
                    }
                    (bool ok, uint256 price, bytes4 why) = PriceSource.priceAt(pin, t, mine);
                    if (!ok) return (false, 0, why);
                    px[i] = price;
                }
                p[terms++] = px[i];
            }
        }
        (bool inRange, int256 s) = FeeMath.holdingsUsd18(q, p);
        if (!inRange) return (false, 0, FeeMath.ValueOutOfRange.selector);
        return (true, s, 0);
    }

    /// Every non-USD quantity live within `POSITION_TOLERANCE_BP` of the snapshot's, and none appeared or
    /// vanished: what no call of the leg does (a liquidation by a third party) caught by the re-read.
    function _steady(Holding[] memory snap, Holding[] memory live) internal pure returns (bool) {
        for (uint256 i; i < live.length; ++i) {
            if (live[i].asset == Assets.USD) continue;
            int256 was;
            for (uint256 j; j < snap.length; ++j) {
                if (snap[j].asset == live[i].asset) was = snap[j].quantity;
            }
            if (_abs(live[i].quantity - was) * FeeMath.BP > _abs(was) * POSITION_TOLERANCE_BP) return false;
        }
        for (uint256 j; j < snap.length; ++j) {
            if (snap[j].asset == Assets.USD || snap[j].quantity == 0) continue;
            bool found;
            for (uint256 i; i < live.length; ++i) {
                if (live[i].asset == snap[j].asset) found = true;
            }
            if (!found) return false;
        }
        return true;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _decodeView(bytes memory b)
        internal
        pure
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool)
    {
        return abi.decode(b, (Holding[], uint256[4], uint256[4], uint64, uint64, uint64, bool));
    }

    function _revert(bytes4 why) internal pure {
        assembly ("memory-safe") {
            mstore(0, why)
            revert(0, 4)
        }
    }
}
