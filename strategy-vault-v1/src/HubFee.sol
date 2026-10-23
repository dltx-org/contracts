// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {HubState} from "./HubState.sol";
import {ILinkV1} from "./MemberState.sol";
import {IRegistryV1} from "./Interfaces.sol";
import {IERC20, IMessageTransmitterV2} from "./interfaces/Protocols.sol";
import {FeeMath} from "./lib/FeeMath.sol";
import {PriceSource, PriceSourcePin} from "./lib/PriceSource.sol";
import {Assets, Holding, Legs} from "./lib/VaultTypes.sol";
import {AssetProfile, OwnerMessagesV1, PricePin} from "./Types.sol";

/// A leg beside the hub: its report's figures as a view (amendment 2b §3.4); the AAVE leg's signed bound
/// and exit state, which a profile switch must respect (asset-profiles-design.md §3.7).
interface ILegViewV1 {
    function holdings()
        external
        view
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool);
    function oracleBoundBp() external view returns (uint16);
    function exiting() external view returns (bool);
}

/*
 * VERSION 1 of the hub's FEE MODULE (version 0's `StrategyHubFee`, unchanged in its fee), with the
 * profile's hub-side check (AP-3) and the owner's PROFILE SWITCH (asset-profiles-design.md §3.7), here
 * for the hub's size. Version 0's text follows.
 *
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
contract HubFee is HubState {
    /// What the long's `followSwitch` is admitted with at the apply: several times the unit and fork
    /// measures (its reads of AAVE, Uniswap's factory and the token, about 150k).
    uint256 internal constant SWITCH_GAS = 1_000_000;

    // ── the profile (asset-profiles-design.md AP-3, §3.6, §3.7) ──────────────────────────────────────

    /// The hub's part of a profile, checked on this chain when the registry accepts it (AP-3, 2b's pin
    /// checks): one or two pins, each a known kind, its feeds with code and fresh now, no asset twice, none
    /// USD, an unused pin all zero; the long's holding and the short's asset each priced by a pin.
    function checkProfile(AssetProfile calldata p) external view {
        _checkProfile(p, true);
    }

    /// The hub's own call, once, from its initialisation: the profile, open in this chain's registry and
    /// checked by THIS version's code (the registry ran the then-latest version's), the feeds' freshness
    /// aside (a creation never waits for a feed); its price pins stored for good.
    function initProfile(bytes32 id) external delegated {
        if (msg.sender != address(this) || profile != bytes32(0)) revert NotAllowed();
        IRegistryV1 r = IRegistryV1(registry);
        if (!r.profileOpen(id)) revert BadParams();
        AssetProfile memory a = r.profileOf(id);
        _checkProfile(a, false);
        profile = id;
        uint32 here = IMessageTransmitterV2(MESSAGE_TRANSMITTER).localDomain();
        for (uint256 i; i < 2; ++i) {
            PricePin memory q = a.pins[i];
            if (q.asset != bytes32(0)) _priceSources.push(PriceSourcePin(here, q.asset, q.kind, q.feed, q.baseFeed, q.maxAge));
        }
    }

    function _checkProfile(AssetProfile memory p, bool live) internal view {
        bool holding;
        bool shortAsset;
        for (uint256 i; i < 2; ++i) {
            PricePin memory q = p.pins[i];
            if (q.asset == bytes32(0)) {
                if (q.kind != 0 || q.feed != address(0) || q.baseFeed != address(0) || q.maxAge != 0) revert BadProfile();
                continue;
            }
            bool composite = q.kind == PriceSource.KIND_COMPOSITE;
            if (
                q.asset == Assets.USD || (q.kind != PriceSource.KIND_FEED && !composite)
                    || composite != (q.baseFeed != address(0)) || q.maxAge == 0 || (i == 1 && q.asset == p.pins[0].asset)
            ) revert BadProfile();
            if (q.feed.code.length == 0 || (composite && q.baseFeed.code.length == 0)) revert BadProfile();
            if (live) {
                (bool fresh,) = PriceSource.freshAt(
                    PriceSourcePin(0, q.asset, q.kind, q.feed, q.baseFeed, q.maxAge), block.timestamp
                );
                if (!fresh) revert BadProfile();
            }
            if (q.asset == p.holdingAsset) holding = true;
            if (q.asset == p.shortAsset) shortAsset = true;
        }
        if (!holding || !shortAsset) revert BadProfile();
    }

    /// The owner's `SwitchProfile(hub, chainId, fromProfile, toProfile, nonce, deadline)`, by `credential`
    /// (its signer): another open profile of the same token, the same short part and the same price pins,
    /// within the long's signed bound, not in exit (§3.7). It takes the strategy's one pending slot.
    function scheduleSwitch(bytes32 toProfile, bytes32 credential, uint256 deadline, bytes calldata signature)
        external
        delegated
        nonReentrant
    {
        _checkOwnerAs(
            credential,
            keccak256(
                abi.encode(
                    OwnerMessagesV1.SWITCH_PROFILE_TYPEHASH,
                    address(this),
                    block.chainid,
                    profile,
                    toProfile,
                    ownerNonceOf[credential],
                    deadline
                )
            ),
            deadline,
            signature
        );
        if (!_switchOk(toProfile)) revert BadProfile();
        _schedule(OwnerMessagesV1.KIND_SWITCH, toProfile, credential);
    }

    /// Anyone, once due, outside the money lock: the long beside the hub follows (`followSwitch`), then the
    /// hub's profile is the new one; its price pins are equal, so the fee is untouched. A switch that can
    /// no longer apply (its scheduler gone, its conditions failing) is cleared instead.
    function applySwitch() external delegated nonReentrant {
        (bool ok, bytes32 to) = _takeDue(OwnerMessagesV1.KIND_SWITCH);
        if (!ok) return;
        if (!_switchOk(to)) {
            emit ActionCleared(OwnerMessagesV1.KIND_SWITCH, to, 2);
            return;
        }
        // the long checks the profile's facts again with this version's code: refused, the switch is cleared.
        // Admitted only with the gas it needs, so a low gas estimate can never clear the owner's switch
        if (gasleft() < SWITCH_GAS) revert GasTooLow();
        try ILinkV1(links[0]).followSwitch(to) {}
        catch {
            emit ActionCleared(OwnerMessagesV1.KIND_SWITCH, to, 2);
            return;
        }
        emit ProfileSwitched(profile, to);
        profile = to;
    }

    /// §3.7's conditions, at scheduling and again at the apply: outside the exit (the hub's and its long's),
    /// another profile open here, the same asset, aToken, decimals and holding, the same short part, the
    /// same price pins, and the long's signed `oracleBoundBp` at least the new `minBoundBp` and above its
    /// pool's fee (else `_bandLimit` underflows).
    function _switchOk(bytes32 to) internal view returns (bool) {
        if (exiting || to == profile || !_isLocal(0)) return false;
        IRegistryV1 r = IRegistryV1(registry);
        if (!r.profileOpen(to)) return false;
        AssetProfile memory a = r.profileOf(profile);
        AssetProfile memory b = r.profileOf(to);
        if (
            a.asset != b.asset || a.aAsset != b.aAsset || a.assetDecimals != b.assetDecimals
                || a.holdingAsset != b.holdingAsset || a.perp != b.perp || a.perpCoin != b.perpCoin
                || a.szDecimals != b.szDecimals || a.underlying != b.underlying || a.shortAsset != b.shortAsset
                || keccak256(abi.encode(a.pins)) != keccak256(abi.encode(b.pins))
        ) return false;
        ILegViewV1 leg = ILegViewV1(links[0]);
        if (leg.exiting()) return false;
        uint256 bound = leg.oracleBoundBp();
        return bound >= b.minBoundBp && bound > b.swapFee / 100;
    }

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
            (bool ok, bytes memory ret) = links[k].staticcall(abi.encodeCall(ILegViewV1.holdings, ()));
            if (!ok) revert UntrackedLeg();
            (,,,,,, bool tracked) = _decodeView(ret);
            if (!tracked) revert UntrackedLeg();
            _snapshots[k] = ret;
        }
        snapshotAt = uint64(block.timestamp);
        emit Snapshot(uint64(block.timestamp));
    }

    /// Charges the management fee accrued (amendment 2e §3.4), then the performance fee on the profit
    /// above the mark of the value net of it, at most once a day each, capped (§3.5). Refused with the
    /// value's reason, `TooSoon` (neither due), or the performance fee's `NeedUsdc`; with no fee address
    /// either defers.
    function crystallize(uint80[] calldata rounds) external delegated onlyExecution nonReentrant {
        _sync();
        bool perf = block.timestamp >= uint256(lastFeeAt) + FeeMath.MIN_FEE_INTERVAL;
        if (!perf && !_mgmtReady()) revert TooSoon();
        (bool ok, int256 v, bytes4 why, uint64 seq) = _value(rounds);
        if (!ok) _revert(why);
        v -= int256(_chargeMgmt(v, 0, seq));
        if (!perf) return;
        why = _charge(v, seq);
        if (why != 0) emit FeeDeferred(why);
    }

    /// USDC to the owner, the user's deposit contract on this chain. It charges the management fee and
    /// then the performance fee first when it can, each only above the payout's amount; when it can't (too
    /// soon, the value refused, the hub short of USDC), it pays anyway and the profit stays above the mark
    /// (decision 51), the management fee's accrual waiting (amendment 2e §3.4).
    function payout(uint256 amount, uint80[] calldata rounds) external delegated onlyExecution nonReentrant {
        _sync();
        bytes4 why = TooSoon.selector;
        bool perf = block.timestamp >= uint256(lastFeeAt) + FeeMath.MIN_FEE_INTERVAL;
        if (perf || _mgmtReady()) {
            (bool ok, int256 v, bytes4 w, uint64 seq) = _value(rounds);
            if (ok) {
                v -= int256(_chargeMgmt(v, amount, seq));
                if (perf) {
                    (, uint256 fee) = FeeMath.charge(v, mark, lastFeeAt, block.timestamp, feeRateBp, true);
                    w = _free() < amount + fee ? NeedUsdc.selector : _charge(v, seq);
                }
            }
            if (perf) why = w;
        }
        if (why != 0) emit FeeDeferred(why);
        if (amount > _free()) revert NeedUsdc();
        address to = owner;
        IERC20(_usdc()).transfer(to, amount);
        booked -= amount;
        mark -= int256(amount);
        if (_mgmtOn()) _mgmtPaidOut(amount);
        emit Payout(to, amount);
    }

    /// A payout leaves the management window: out of its capital first, then out of its cap, so the base
    /// stays at most the mark less the capital (2e §5's bound: no report raises it above the mark).
    function _mgmtPaidOut(uint256 amount) internal {
        uint256 c = _mgmtCapitalIn;
        uint256 fromCapital = amount < c ? amount : c;
        _mgmtCapitalIn = c - fromCapital;
        _mgmtMarkStart -= int256(amount - fromCapital);
    }

    /// The management fee is due: a knob above 0 and a day since the accrual started (§3.4).
    function _mgmtReady() internal view returns (bool) {
        return _mgmtOn() && block.timestamp >= uint256(_mgmtFrom) + FeeMath.MIN_FEE_INTERVAL;
    }

    /// Amendment 2e §3.4: the management fee accrued since `_mgmtFrom` on the window's base (`_mgmtBase`), from the
    /// hub's free USDC above `reserve` (payout's amount); deferred, never a revert, with no fee address or
    /// not enough USDC; a base of 0 forgives the idle time. Returns what it charged (`v` is net of it after).
    function _chargeMgmt(int256 v, uint256 reserve, uint64 seq) internal returns (uint256 due) {
        if (!_mgmtReady()) return 0;
        uint256 base = _mgmtBase(v, 0);
        if (base == 0) {
            _mgmtOpen(); // nothing of the window's money left: its idle time forgiven
            return 0;
        }
        uint256 window = block.timestamp - _mgmtFrom;
        due = FeeMath.mgmtFee(base, window, _mgmtRateBp, _flatPerMonth);
        if (due == 0) {
            // less than a unit accrued: with capital waiting, open its window now (a window opened at a
            // dust mark would otherwise cap the base at that dust for good: the review of the build)
            if (_mgmtCapitalIn != 0) _mgmtOpen();
            return 0;
        }
        address to = IRegistryV1(registry).feeAddress();
        bytes4 why = to == address(0) ? NoFeeAddress.selector : (_free() < reserve + due ? NeedUsdc.selector : bytes4(0));
        if (why != 0) {
            emit ManagementFeeDeferred(why);
            return 0;
        }
        _payFee(to, due);
        emit ManagementFeeCharged(v, mark, base, window, due, _mgmtRateBp, _flatPerMonth, snapshotAt, seq);
        _mgmtOpen();
    }

    /// The capped charge; returns why it deferred (no fee address), 0 otherwise.
    function _charge(int256 v, uint64 seq) internal returns (bytes4) {
        (uint256 profit, uint256 fee) = FeeMath.charge(v, mark, lastFeeAt, block.timestamp, feeRateBp, true);
        if (fee == 0) return 0;
        address to = IRegistryV1(registry).feeAddress();
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
        if (msg.sender != IRegistryV1(registry).recovery()) revert NotAllowed();
        if (newBp > signedFeeRateBp || (exiting && newBp > feeRateBp)) revert BadRate();
        _setRate(newBp, msg.sender);
    }

    /// Amendment 2e §3.6: the recovery key of this chain's registry sets the management fee, each value at
    /// most the owner's signed one, and in exit at most its current one (`BadRate`). Outside the exit the
    /// accrual not yet charged is forgiven (a restore never reaches back, a lowering needs no valuation); in
    /// exit a lowering applies to the whole exit's management total.
    function setManagementFee(uint16 rateBp, uint32 flatPerMonth) external delegated nonReentrant {
        if (msg.sender != IRegistryV1(registry).recovery()) revert NotAllowed();
        if (
            rateBp > _signedMgmtRateBp || flatPerMonth > _signedFlatPerMonth
                || (exiting && (rateBp > _mgmtRateBp || flatPerMonth > _flatPerMonth))
        ) revert BadRate();
        _sync();
        emit ManagementFeeSet(_mgmtRateBp, rateBp, _flatPerMonth, flatPerMonth, msg.sender);
        (_mgmtRateBp, _flatPerMonth) = (rateBp, flatPerMonth);
        if (!exiting) _mgmtOpen();
    }

    /// The management fee's state (amendment 2e §3.2), read by `core` at each block it records: the current
    /// and signed rate a year and flat amount a month, when the accrual started, and the exit's frozen
    /// window, its mark at entry, and its fee paid and forgiven.
    function managementFee()
        external
        view
        returns (
            uint16 rateBp,
            uint16 signedRateBp,
            uint32 flatPerMonth,
            uint32 signedFlatPerMonth,
            uint64 mgmtFrom,
            uint64 exitWindow,
            int256 exitEntry,
            uint256 exitPaid_,
            uint256 exitForgiven,
            int256 markStart,
            uint256 capitalIn
        )
    {
        return (
            _mgmtRateBp,
            _signedMgmtRateBp,
            _flatPerMonth,
            _signedFlatPerMonth,
            _mgmtFrom,
            _exitMgmtWindow,
            _exitMgmtEntry,
            _exitMgmtPaid,
            _exitMgmtForgiven,
            _mgmtMarkStart,
            _mgmtCapitalIn
        );
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
    /// the profit above it, the profit the cap counts, the performance fee (on the value net of the
    /// management fee), when the next performance charge may run, and the management fee (amendment 2e
    /// §3.4): `mgmtAccrued`, what has accrued now whether or not the hub could pay it, and `mgmtDue`, what
    /// `crystallize` would take now (0 when it would revert on the performance fee's `NeedUsdc`). An inflow
    /// not yet counted is taken as the sync will (the window's capital, or the window opened by it). Both 0
    /// in exit, where the exit's settlement charges.
    /// `why` is the performance fee's: a management fee due still runs while it says `TooSoon`.
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
            uint256 chargeableAt,
            uint256 mgmtAccrued,
            uint256 mgmtDue
        )
    {
        bytes4 w;
        (ok, v, w,) = _value(rounds);
        (uint256 inflow,) = FeeMath.inflow(IERC20(_usdc()).balanceOf(address(this)), booked);
        markSynced = mark + int256(inflow); // a deposit not yet synced never shows as profit
        chargeableAt = uint256(lastFeeAt) + FeeMath.MIN_FEE_INTERVAL;
        if (ok) {
            uint256 free = _free();
            address feeTo = IRegistryV1(registry).feeAddress();
            // as the sync would leave it: an inflow not yet counted is the window's capital, or opens it
            if (_mgmtOn() && !exiting && !(inflow > 0 && _mgmtMarkStart <= 0)) {
                mgmtAccrued =
                    FeeMath.mgmtFee(_mgmtBase(v, inflow), block.timestamp - _mgmtFrom, _mgmtRateBp, _flatPerMonth);
                if (_mgmtReady() && feeTo != address(0) && free >= mgmtAccrued) mgmtDue = mgmtAccrued;
            }
            int256 net = v - int256(mgmtDue);
            if (net > markSynced && net > 0) profit = uint256(net - markSynced);
            (cappedProfit, fee) = FeeMath.charge(net, markSynced, lastFeeAt, block.timestamp, feeRateBp, true);
            if (block.timestamp < chargeableAt) w = TooSoon.selector;
            else if (fee > 0 && feeTo == address(0)) w = NoFeeAddress.selector;
            else if (free < fee + mgmtDue) w = NeedUsdc.selector;
            if (w == NeedUsdc.selector) mgmtDue = 0; // crystallize would revert whole, the management part with it
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
                (bool ok, bytes memory live) = links[k].staticcall(abi.encodeCall(ILegViewV1.holdings, ()));
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
