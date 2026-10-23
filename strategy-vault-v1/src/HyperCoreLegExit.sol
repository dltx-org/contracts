// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {HyperCoreLegState} from "./HyperCoreLegState.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {HyperCore} from "./lib/HyperCore.sol";

/*
 * The Hyperliquid leg's EXIT MODULE, part A (version 0's `ShortVaultExit`, split for EIP-170:
 * asset-profiles-design.md §3.2): the exit's state-driven step (`exitStep`, its closes and moves) and
 * `bridgeOut`, run only by DELEGATECALL from an instance (`delegated`), in its storage. Part B
 * (`HyperCoreLegExitB`) holds the owner's exit actions, the status, the profile check and the leg's rarely
 * called functions.
 *
 * The exit (decisions 24, 28, 30; §8.4's table) is driven by state: each `exitStep` reads the account
 * through the precompiles and sends every action that state still calls for, each chosen so that
 * executing twice, late, in any order, is refused by Hyperliquid or bounded. Pacing (20 blocks) saves
 * gas; it proves nothing.
 */
contract HyperCoreLegExit is HyperCoreLegState {
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

}
