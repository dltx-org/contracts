// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {ShortVaultState} from "./ShortVaultState.sol";
import {IDepositOwner, OwnerDomain} from "./interfaces/IDepositOwner.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {Holding, OwnerMessages} from "./lib/VaultTypes.sol";

/*
 * The Hyperliquid leg's EXIT MODULE (step 11e2 amendment 2a §3.8): the exit's six functions, with
 * `receiveMint` and `report` (size), run only by
 * DELEGATECALL from a leg (`ShortVault`'s fallback), in the leg's storage. Called directly, or through a
 * leg code that was never initialized, every function refuses: the module's own storage, and the leg
 * code's, carry the factory sentinel `address(1)` (VaultBase's constructor).
 *
 * The exit (decisions 24, 28, 30; §8.4's table) is driven by state: each `exitStep` reads the account
 * through the precompiles and sends every action that state still calls for, each chosen so that
 * executing twice, late, in any order, is refused by Hyperliquid or bounded. Pacing (20 blocks) saves
 * gas; it proves nothing.
 */
contract ShortVaultExit is ShortVaultState {
    // ── the exit (§8.4's table) ──────────────────────────────────────────────────────────────────────

    /// Anyone, in exit. Reads, then sends what the state still calls for.
    function exitStep(ExitArgs calldata a) external delegated nonReentrant inExit counted {
        // the exit's agent again: the same agent under the same name twice is harmless
        if (_due(K_AGENT, 0, 0)) HyperCore.addApiWallet(exitAgent, AGENT_NAME);
        for (uint256 i; i < a.cancels.length; ++i) {
            _cancel(a.cancels[i]);
        }
        for (uint256 i; i < a.dexes.length; ++i) {
            _watch(a.dexes[i].dex, false);
        }
        // DEX 0 closes: sized by the position precompile, bounded by the validator oracle
        bool closing = _closeDex0(perp);
        for (uint256 i; i < a.perps.length; ++i) {
            if (_closeDex0(a.perps[i])) closing = true;
        }
        State memory s = _read();
        // the gate: nothing leaves spot, and nothing is spent, while a watched DEX shows notional; a
        // close and a transfer are never sent by the same call
        if (s.gate && !closing) _moves(s, a.dexes);
        _sendAllToHub();
    }

    /// Anyone, in exit: the leg's HyperEVM USDC to its hub, with no HyperCore read, so it goes even
    /// when a precompile read fails.
    function bridgeOut() external delegated nonReentrant inExit {
        _sendAllToHub();
    }

    /// The owner's signed order (decision 30), in exit: where no independent price exists (a HIP-3
    /// position, a spot token with no oracle) or the market won't fill within the oracle bound (an
    /// illiquid DEX 0 position). IOC at the owner's limit, which the on-chain best bid or offer ± the
    /// bound may only tighten; reduce-only on a perp. `asset` is Hyperliquid's: a DEX 0 perp (< 10,000),
    /// a spot market (10,000 + its index) or a HIP-3 perp (100,000 + 10,000 × DEX + index), whose DEX
    /// then joins the watched list; `szDecimals` is the asset's (no precompile serves a HIP-3 one).
    function ownerOrder(
        uint32 asset,
        bool isBuy,
        uint64 size,
        uint64 limitPx,
        uint8 szDecimals,
        bytes32 credential,
        uint256 deadline,
        bytes calldata signature
    ) external delegated nonReentrant inExit counted {
        bool spot = asset >= SPOT_ASSET_OFFSET && asset < HIP3_ASSET_OFFSET;
        // a spot order SELLS only: a buy could spend the vault's USDC on a token whose only ask is a
        // thief's; a perp order is reduce-only
        if (
            (asset >= HIP3_ASSET_OFFSET && asset < HIP3_ASSET_OFFSET + 10_000) || szDecimals > (spot ? 8 : 6)
                || (spot && isBuy)
        ) revert BadAsset();
        _checkOwnerAs(
            credential,
            keccak256(
                abi.encode(
                    OwnerMessages.OWNER_ORDER_TYPEHASH,
                    address(this),
                    block.chainid,
                    asset,
                    isBuy,
                    size,
                    limitPx,
                    szDecimals,
                    ownerNonceOf[credential],
                    deadline
                )
            ),
            deadline,
            signature
        );
        if (asset >= HIP3_ASSET_OFFSET) _watch((asset - HIP3_ASSET_OFFSET) / 10_000, true);
        (uint64 bid, uint64 ask) = HyperCore.bbo(asset);
        // the book's price in 1e8: perps carry 6 − szDecimals decimals, spot 8 − szDecimals
        uint256 scale = 10 ** (spot ? szDecimals : 2 + szDecimals);
        uint256 maxDecimals = (spot ? 8 : 6) - szDecimals;
        uint64 px = limitPx;
        if (isBuy && ask > 0) {
            uint64 t = HyperCore.boundedPx(ask * scale, orderBoundBp, true, maxDecimals);
            if (t < px) px = t;
        } else if (!isBuy && bid > 0) {
            uint64 t = HyperCore.boundedPx(bid * scale, orderBoundBp, false, maxDecimals);
            if (t > px) px = t;
        }
        HyperCore.orderIoc(asset, isBuy, px, size, !spot);
    }

    /// Starts the 24 hours an owner wallet credential must stand before the residue may be swept to it
    /// (§8.4). The deposit account does not record when a credential joined its copy, so the vault
    /// observes it itself: from the first call here naming `to` while `to` is a wallet credential in
    /// this chain's copy. Anyone, in exit; a later call for the same address changes nothing.
    function proposeSweep(address to) external delegated inExit {
        if (!_isOwnerWallet(to)) revert NotOwnerWallet();
        if (sweepSince[to] == 0) sweepSince[to] = uint64(block.timestamp);
    }

    /// The residue sweep (§8.4): not a withdrawal authority. Only in "recovered with residue", never
    /// USDC, at most the residue listed for `token`, only to an owner wallet credential that has stood
    /// 24 hours in this chain's copy of the record (seen by `proposeSweep`) and still stands. Anyone.
    function sweepResidue(uint64 token, address to) external delegated nonReentrant inExit counted {
        (uint8 state, uint64[PINNED] memory residue,) = _status();
        if (state != RECOVERED_WITH_RESIDUE) revert NotResidue();
        uint256 i = _pinnedIndex(token);
        if (i == type(uint256).max || residue[i] == 0) revert BadAsset();
        uint256 since = sweepSince[to];
        if (since == 0 || block.timestamp < since + WALLET_STANDING || !_isOwnerWallet(to)) revert NotOwnerWallet();
        if (!_due(K_SWEEP, token, 0)) revert TooEarly();
        HyperCore.spotSend(to, token, residue[i]);
    }

    function _isOwnerWallet(address to) internal view returns (bool) {
        return to != address(0) && IDepositOwner(owner).isCredential(OwnerDomain.wallet(to));
    }

    /// The exit's status from reads only (§8.4): `state` (NOT_IN_EXIT, CLOSING, RECOVERED,
    /// RECOVERED_WITH_RESIDUE), the watched HIP-3 DEXes (DEX 0 is always watched), the residue per
    /// pinned token (HYPE, USDE, USDT0, USDH; HYPE above its fee reserve), and the `F_*` flags.
    function exitStatus()
        external
        view
        delegated
        returns (uint8 state, uint32[] memory dexes, uint64[4] memory residue, uint256 flags)
    {
        dexes = _dexes;
        if (exiting) (state, residue, flags) = _status();
        if (!_ownerSynced()) flags |= F_OWNER_UNSYNCED;
    }

    // ── internals: the rows of §8.4's table ──────────────────────────────────────────────────────────

    /// A DEX 0 position (the caller names its index): reduce-only IOC for its current size, at the
    /// validator oracle ± the bound. Returns whether a position is open (sent now or paced).
    function _closeDex0(uint32 p) internal returns (bool open) {
        if (p >= SPOT_ASSET_OFFSET) revert BadAsset();
        // a position that can't be read (an unknown or delisted perp) is not closed here and doesn't stop
        // the step: the gate still holds every move while DEX 0 shows notional (the combined review's CR-X1)
        (bool ok, HyperCore.Position memory pos) = HyperCore.tryPosition(address(this), p);
        if (!ok || pos.szi == 0) return false;
        if (!_due(K_CLOSE, p, 0)) return true;
        uint8 szd = HyperCore.perpSzDecimals(p);
        bool isBuy = pos.szi < 0;
        uint256 size = uint256(uint64(isBuy ? -pos.szi : pos.szi)) * 10 ** (8 - szd);
        HyperCore.orderIoc(p, isBuy, _perpLimit(p, szd, isBuy), uint64(size), true);
        return true;
    }

    function _moves(State memory s, DexHint[] calldata hints) internal {
        // DEX 0's withdrawable margin → spot (CoreWriter 7)
        if (s.wd == 0) marginTriedAt = 0; // the margin is on spot: a later one is tried afresh (RR-3)
        if (s.wd > 0 && _due(K_MARGIN, 0, 0)) {
            if (marginTriedAt == 0) marginTriedAt = uint64(block.number);
            HyperCore.usdClassTransfer(s.wd, false);
        }
        // each flat watched DEX's collateral → spot (sendAsset): refused if the hint is wrong, or twice
        for (uint256 i; i < _dexes.length; ++i) {
            HyperCore.MarginSummary memory m = s.ms[i];
            if (!s.ok[i] || m.ntlPos != 0 || m.accountValue <= DUST_VALUE) continue;
            uint32 dex = _dexes[i];
            uint64 token = _hint(hints, dex);
            if (_due(K_DEX, dex, token)) {
                HyperCore.sendAsset(address(this), dex, HyperCore.SPOT_DEX, token, uint64(m.accountValue) * 100);
            }
        }
        // budget mode (§8.4): spot keeps a floor, R plus the fee allowance (so a first transfer's fee is
        // paid above R, never out of it), fixed once DEX 0's margin is on spot (or its transfer has been
        // tried for two pacing windows since the first try: unified mode; the pacing timestamp itself is
        // refreshed by every try, the combined review's CR-X2). What is above it may leave, later arrivals
        // included (CR-D5), less what was sent and not yet seen arriving on HyperEVM: a send is released
        // only once as much USDC has arrived here from outside the strategy (Circle's mints, counted per
        // link net of its fee, set aside), never by time alone (the partner's audit M4). USDC that is not this send (a
        // stranger's) still only goes to the hub, the owner's. A send that never executes stays reserved
        // until the owner's signed RELEASE_RESERVATION.
        uint256 arrived = sentTo[0] + IERC20(USDC).balanceOf(address(this));
        uint256 minted = receivedFromOthers;
        for (uint256 k; k < 4; ++k) {
            minted += receivedFrom[k] - feesFrom[k]; // net, as they arrived
        }
        uint64 room = type(uint64).max;
        if (s.budgetMode) {
            if (!floorSet) {
                uint256 first = marginTriedAt;
                if (s.wd == 0 || (first != 0 && block.number >= first + 2 * PACING_BLOCKS)) {
                    floor = uint256(s.reserve) + FEE_ALLOWANCE;
                    floorSet = true;
                }
            }
            // released whole once as much has arrived from outside the strategy since the first unseen send
            // (compared, never subtracted: before the exit, mints may have left for HyperCore uncounted); a
            // part is never released, so a stranger's smaller credit frees nothing
            if (reserved != 0 && (arrived + mintedMark) * 100 >= (arrivedMark + minted) * 100 + reserved) reserved = 0;
            room = floorSet && s.spotUsdc > floor + reserved ? uint64(s.spotUsdc - floor - reserved) : 0;
        }
        uint64 spotFee = HYPE_FEE_RESERVE;
        // HYPE from zero: the fewest 0.01 steps worth Hyperliquid's $10 order minimum at the HYPE perp's
        // oracle + the bound (`_purchase`), at most 3 purchases
        if (s.spotHype < spotFee && purchases < MAX_PURCHASES) {
            (uint64 limit, uint64 steps, uint64 cost) = _purchase(s.hypePx);
            if (steps > 0 && cost <= s.spotUsdc && cost <= room && _due(K_BUY, 0, 0)) {
                HyperCore.orderIoc(SPOT_ASSET_OFFSET + 107, true, limit, steps * STEP_WEI, false);
                purchases++;
                room -= cost;
            }
        }
        // spot USDC → HyperEVM, the whole balance read (less what the budget doesn't allow). The account's
        // first outgoing USDC transfer pays ~1 USDC on top, and one that can't is dropped silently (§5):
        // a read that has not fallen since the last send means it may have been (only the vault's own
        // actions lower spot USDC; anyone can raise it, so "unchanged" alone could be held off by a
        // stranger's dust: the combined review's CR-D1), so this send leaves the allowance for the fee. If
        // the first had only been late, one of the two exceeds the balance and is refused; what the
        // allowance kept back reads as a lower balance and goes whole on a later call. Nothing under the
        // dust bound is sent, so a stranger's dust can't spend the vault's HYPE on paced transfers (CR-D6).
        if (s.spotHype >= spotFee) {
            uint64 amount = s.spotUsdc;
            // the allowance kept back only while what is sent stays above the dust bound: a read between
            // the allowance and the allowance + dust goes whole (RR-4)
            if (toEvmRead != 0 && amount >= toEvmRead && amount >= FEE_ALLOWANCE + DUST_USDC) amount -= FEE_ALLOWANCE;
            if (amount > room) amount = room;
            amount -= amount % 100; // HyperEVM USDC has 6 decimals
            if (amount >= DUST_USDC && _due(K_TO_EVM, 0, 0)) {
                HyperCore.sendAsset(USDC_SYSTEM, HyperCore.SPOT_DEX, HyperCore.SPOT_DEX, USDC_TOKEN, amount);
                lastCoreMove = uint64(block.number);
                toEvmRead = s.spotUsdc;
                if (s.budgetMode) {
                    if (reserved == 0) (arrivedMark, mintedMark) = (arrived, minted);
                    reserved += amount;
                }
            }
        }
        // the pinned tokens' sales: HYPE above its fee reserve; the stablecoins (not in budget mode: in
        // a unified account one may be a dropped-out position's collateral)
        for (uint256 i; i < PINNED; ++i) {
            if (i > 0 && s.budgetMode) break;
            (uint64 token, uint32 spot) = _pinned(i);
            uint64 bal = i == 0 ? s.spotHype : HyperCore.spotAvailable(address(this), token);
            uint64 sellable = i == 0 ? (bal > spotFee ? bal - spotFee : 0) : bal;
            uint64 limit = HyperCore.boundedPx(i == 0 ? s.hypePx : 1e8, orderBoundBp, false, 6);
            uint64 steps = sellable / STEP_WEI;
            if (uint256(steps) * limit / 100 >= SALE_MIN_USDC && _due(K_SELL, token, 0)) {
                HyperCore.orderIoc(SPOT_ASSET_OFFSET + spot, false, limit, steps * STEP_WEI, false);
            }
        }
    }

    function _read() internal view returns (State memory s) {
        (bool ok0, HyperCore.MarginSummary memory m0) = HyperCore.marginSummary(0, address(this));
        if (!ok0) revert HyperCore.PrecompileFailed(HyperCore.PX_MARGIN_SUMMARY);
        s.gate = m0.ntlPos == 0;
        s.value0 = m0.accountValue;
        uint256 n = _dexes.length;
        s.ok = new bool[](n);
        s.ms = new HyperCore.MarginSummary[](n);
        uint256 reserveUsd;
        for (uint256 i; i < n; ++i) {
            uint32 dex = _dexes[i];
            (s.ok[i], s.ms[i]) = HyperCore.marginSummary(dex, address(this));
            HyperCore.MarginSummary memory m = s.ms[i];
            if (s.ok[i] && m.ntlPos == 0) continue;
            s.waitingOwner = true;
            if (block.timestamp >= uint256(dexSince[dex]) + DROP_OUT) {
                // dropped out of the gate: its position keeps R = 1.1 × max(margin used, 10% of notional)
                s.budgetMode = true;
                if (s.ok[i]) reserveUsd += m.marginUsed > m.ntlPos / 10 ? m.marginUsed : m.ntlPos / 10;
            } else {
                s.gate = false;
            }
        }
        s.reserve = uint64(reserveUsd * 11 / 10 * 100);
        s.wd = HyperCore.withdrawable(address(this));
        // what can move: total − hold (standard mode's resting spot orders hold some; unified mode's
        // read is already the available amount, hold 0)
        HyperCore.SpotBalance memory u = HyperCore.spotBalance(address(this), USDC_TOKEN);
        s.spotUsdc = u.total - u.hold;
        s.spotUsdcTotal = u.total;
        s.spotHype = HyperCore.spotAvailable(address(this), HYPE_TOKEN);
        s.hypePx = uint64(uint256(HyperCore.oraclePx(HYPE_PERP)) * 1e4); // HYPE perp: szDecimals 2
    }

    /// One HYPE purchase: at the HYPE perp's oracle + the bound, the fewest 0.01 steps whose value is at
    /// least Hyperliquid's $10 order minimum (a smaller order is refused, silently: the combined review's
    /// CR-D2), and what it costs in Core wei of USDC.
    function _purchase(uint64 hypePx) internal view returns (uint64 limit, uint64 steps, uint64 cost) {
        limit = HyperCore.boundedPx(hypePx, orderBoundBp, true, 6);
        if (limit == 0) return (0, 0, 0);
        steps = uint64((uint256(SALE_MIN_USDC) * 100 + limit - 1) / limit);
        cost = uint64(uint256(steps) * limit / 100);
    }

    /// closing / recovered / recovered with residue, the residue per pinned token, and the flags.
    function _status() internal view returns (uint8 state, uint64[PINNED] memory residue, uint256 flags) {
        State memory s = _read();
        bool closing = !s.gate || s.budgetMode || s.wd > 0 || s.value0 > DUST_VALUE || s.spotUsdcTotal >= DUST_USDC
            || IERC20(USDC).balanceOf(address(this)) > 0;
        for (uint256 i; i < _dexes.length; ++i) {
            if (s.ok[i] && s.ms[i].accountValue > DUST_VALUE) closing = true;
        }
        bool any;
        for (uint256 i; i < PINNED; ++i) {
            (uint64 token,) = _pinned(i);
            uint64 bal = i == 0 ? s.spotHype : HyperCore.spotAvailable(address(this), token);
            uint64 held = i == 0 ? (bal > HYPE_FEE_RESERVE ? bal - HYPE_FEE_RESERVE : 0) : bal;
            uint256 px = i == 0 ? s.hypePx : 1e8;
            uint256 value = uint256(held) * px / 1e8; // Core wei of USDC (both 8 dp)
            uint256 saleValue = uint256(held / STEP_WEI) * HyperCore.boundedPx(px, orderBoundBp, false, 6) / 100;
            if (saleValue >= SALE_MIN_USDC) closing = true;
            if (value >= DUST_USDC) {
                residue[i] = held;
                any = true;
            }
        }
        if (toldPending != 0) flags |= F_PARTNER_PENDING;
        if (s.budgetMode) flags |= F_BUDGET;
        if (s.waitingOwner) flags |= F_WAITING_OWNER;
        if (s.gate && s.spotHype < HYPE_FEE_RESERVE && s.spotUsdc >= DUST_USDC) {
            // no purchase can happen: three made, none placeable, the spot or the budget too small (CR-D2)
            (,, uint64 cost) = _purchase(s.hypePx);
            if (
                purchases >= MAX_PURCHASES || cost == 0 || cost > s.spotUsdc
                    || (s.budgetMode && floorSet && s.spotUsdc < floor + reserved + cost)
            ) flags |= F_NEEDS_HYPE;
        }
        if (s.gate && s.wd == 0 && s.value0 > DUST_VALUE) flags |= F_MARGIN_HELD;
        state = closing ? CLOSING : (any ? RECOVERED_WITH_RESIDUE : RECOVERED);
    }

    /// The owner's copy here answers `synced()`; anything else (an old account, a revert) reads as not.
    function _ownerSynced() internal view returns (bool) {
        (bool ok, bytes memory out) = owner.staticcall(abi.encodeCall(IDepositOwner.synced, ()));
        return ok && out.length >= 32 && abi.decode(out, (bool));
    }

    /// A DEX joins when it can be read and (unless the owner's close names it) holds something: any
    /// notional or 1 USD. Only DEXes that still hold more than dust count toward the 16: when the list
    /// is full, an entry with no notional and at most dust gives its place.
    function _watch(uint32 dex, bool force) internal {
        if (dex == 0 || dexSince[dex] != 0) return;
        (bool ok, HyperCore.MarginSummary memory m) = HyperCore.marginSummary(dex, address(this));
        if (!ok || (!force && m.ntlPos == 0 && m.accountValue < JOIN_MIN_VALUE)) return;
        uint256 n = _dexes.length;
        if (n < MAX_DEXES) {
            _dexes.push(dex);
        } else {
            uint256 i;
            for (; i < n; ++i) {
                (bool okI, HyperCore.MarginSummary memory e) = HyperCore.marginSummary(_dexes[i], address(this));
                if (okI && e.ntlPos == 0 && e.accountValue <= DUST_VALUE) break;
            }
            if (i == n) return;
            delete dexSince[_dexes[i]];
            _dexes[i] = dex;
        }
        dexSince[dex] = uint64(block.timestamp);
        emit DexWatched(dex);
    }

    function _hint(DexHint[] calldata hints, uint32 dex) internal pure returns (uint64 token) {
        for (uint256 i; i < hints.length; ++i) {
            if (hints[i].dex != dex) continue;
            token = hints[i].collateral;
            uint256 idx = _pinnedIndex(token);
            // USDC or a pinned stablecoin only; anything else is read as USDC
            if (token != USDC_TOKEN && (idx == 0 || idx == type(uint256).max)) return USDC_TOKEN;
            return token;
        }
    }

    function _pinned(uint256 i) internal pure returns (uint64 token, uint32 spot) {
        if (i == 0) return (HYPE_TOKEN, 107); // HYPE/USDC
        if (i == 1) return (235, 150); // USDE/USDC
        if (i == 2) return (268, 166); // USDT0/USDC
        return (360, 230); // USDH/USDC
    }

    function _pinnedIndex(uint64 token) internal pure returns (uint256) {
        for (uint256 i; i < PINNED; ++i) {
            (uint64 t,) = _pinned(i);
            if (t == token) return i;
        }
        return type(uint256).max;
    }


    // ── the leg's rarely called functions, here for size (amendment 2a §3.8) ─────────────────────────────

    /// Anyone, in every state: completes a Circle mint bound to this leg and counts it (§3.6).
    function receiveMint(bytes calldata message, bytes calldata attestation) external delegated nonReentrant {
        _receiveMint(message, attestation);
    }

    /// Anyone: this leg's report to its hub (§3.6, decision 45).
    function report() external delegated nonReentrant {
        _report();
    }

    /// The report's figures as a view (amendment 2b §3.4); `tracked` false: the agent trades the account
    /// unseen by this contract, so a hub on HyperEVM can't prove the position steady (`UntrackedLeg`).
    function holdings()
        external
        view
        delegated
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool)
    {
        return _legView();
    }
}
