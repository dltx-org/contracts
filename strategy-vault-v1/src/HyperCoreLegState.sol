// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {MemberState} from "./MemberState.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {Assets, Holding} from "./lib/VaultTypes.sol";

/*
 * Version 1 of the Hyperliquid leg's STORAGE, constants and shared internals (version 0's
 * `ShortVaultState`, owner-upgradeable and profile-aware): inherited by the leg (`HyperCoreLeg is
 * MemberBase, HyperCoreLegState`) and by its two exit modules (`HyperCoreLegExit`, `HyperCoreLegExitB`:
 * version 0's exit module split, asset-profiles-design.md §3.2, over EIP-170 otherwise), which run by
 * DELEGATECALL in the leg's storage. The layout is `MemberState`'s then this one's, append only;
 * `test.mjs` compares the three slot for slot.
 */
abstract contract HyperCoreLegState is MemberState {
    // ── pinned on HyperEVM (spec §5, §6) ─────────────────────────────────────────────────────────────
    address public constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address public constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    /// HyperEVM HYPE sent here credits the sender's HyperCore spot; HyperCore HYPE comes back from it.
    address public constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    /// HyperCore USDC sent here (spot → spot) returns Circle USDC to the sender on HyperEVM.
    address public constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    uint64 internal constant USDC_TOKEN = 0;
    uint64 internal constant HYPE_TOKEN = 150;
    uint32 internal constant HYPE_PERP = 159; // the HYPE perp's validator oracle bounds HYPE spot (decision 30)
    uint32 internal constant SPOT_ASSET_OFFSET = 10_000;
    uint32 internal constant HIP3_ASSET_OFFSET = 100_000;

    string internal constant AGENT_NAME = "dltx";
    uint256 internal constant AGENT_DELAY = 24 hours;
    uint256 internal constant PACING_BLOCKS = 20;
    uint256 internal constant DROP_OUT = 7 days;
    uint256 internal constant WALLET_STANDING = 24 hours;
    uint256 internal constant MAX_DEXES = 16;
    uint8 internal constant MAX_PURCHASES = 3;
    /// HYPE kept on spot for the transfers' fee: above the 0.00016 HYPE measured (§5). Core wei, 8 dp.
    uint64 internal constant HYPE_FEE_RESERVE = 20_000;
    uint64 internal constant SALE_MIN_USDC = 10e8; // Hyperliquid's $10 order minimum, Core wei
    uint64 internal constant DUST_USDC = 1e6; // 0.01 USDC, Core wei
    int64 internal constant DUST_VALUE = 10_000; // 0.01 USD, 1e6
    int64 internal constant JOIN_MIN_VALUE = 1e6; // 1 USD: what a named DEX must hold to join
    /// The pinned tokens (decision 30): HYPE by its perp's oracle, and the USD stablecoins a HIP-3 DEX
    /// may use as collateral, at 1 USD. All: szDecimals 2, weiDecimals 8 (spotMeta, 2026-10-14).
    uint256 internal constant PINNED = 4;
    uint64 internal constant STEP_WEI = 1e6; // one size step (0.01) in wei (8 dp)
    /// What a spot → HyperEVM send leaves on spot for the account's first outgoing USDC transfer fee,
    /// charged in USDC on top of the amount (about 1 USDC: 1.0 to 1.021278 measured, §5); an action
    /// that can't pay it is dropped silently. Core wei, 8 dp.
    uint64 internal constant FEE_ALLOWANCE = 105_000_000;

    // kinds of paced actions
    uint8 internal constant K_AGENT = 1;
    uint8 internal constant K_CLOSE = 2;
    uint8 internal constant K_MARGIN = 3;
    uint8 internal constant K_DEX = 4;
    uint8 internal constant K_BUY = 5;
    uint8 internal constant K_TO_EVM = 6;
    uint8 internal constant K_SELL = 7;
    uint8 internal constant K_SWEEP = 8;

    // exitStatus().state
    uint8 public constant NOT_IN_EXIT = 0;
    uint8 public constant CLOSING = 1;
    uint8 public constant RECOVERED = 2;
    uint8 public constant RECOVERED_WITH_RESIDUE = 3;
    // exitStatus().flags
    uint256 internal constant F_PARTNER_PENDING = 1;
    uint256 internal constant F_NEEDS_HYPE = 2; // no HYPE, under 11 USDC: someone must `topUpHype`
    uint256 internal constant F_BUDGET = 4; // a dropped-out DEX reads notional: spot keeps `floor`
    uint256 internal constant F_WAITING_OWNER = 8; // a HIP-3 position: only the owner's signed close
    uint256 internal constant F_MARGIN_HELD = 16; // flat, yet margin not withdrawable: unnamed resting orders?
    /// HyperEVM's copy of the owner's record has not received the home's record yet: no owner
    /// signature is possible here (no `BeginExit` by signature, no signed close or sale, no sweep);
    /// the stopped group's hatch and a member's message still begin the exit.
    uint256 internal constant F_OWNER_UNSYNCED = 32;

    // ── fixed at creation ────────────────────────────────────────────────────────────────────────────
    uint32 public perp;
    uint16 public orderBoundBp;
    uint16 public fastFeeCapBp;
    uint16 public feeBudgetBp;
    bytes32 public asset; // the perp's asset in a report (`Assets`)
    uint64 public lastCoreMove; // the block of the last move between HyperEVM and HyperCore

    // ── the agent (§8.5) ─────────────────────────────────────────────────────────────────────────────
    address public agent;
    address public pendingAgent; // DLTX's proposal
    uint64 public pendingAgentAt;
    bool public agentEverSet;
    address public ownerAgent; // the owner's choice other than the burner: effective after 24 hours
    uint64 public ownerAgentAt;
    /// The credential that proposed `ownerAgent`: it must still stand when the agent is applied (the
    /// partner's audit M2)
    bytes32 internal ownerAgentBy;

    // ── the exit ─────────────────────────────────────────────────────────────────────────────────────
    address public exitAgent;
    uint8 public purchases;
    bool public floorSet;
    uint64 public marginTriedAt; // the exit's first DEX 0 margin → spot try (block), for the floor's fallback
    uint64 public reserved; // budget mode: sent from spot to HyperEVM, not yet seen arriving (Core wei)
    uint256 public floor; // budget mode: the spot USDC kept (R + the fee allowance), Core wei, fixed once
    uint256 internal arrivedMark; // HyperEVM USDC in (`sentTo[0]` + balance, 6 dp) when `reserved` began
    uint256 internal mintedMark; // and Circle's mints counted here then, net of its fee
    uint64 internal toEvmRead; // the spot USDC read when the last spot → HyperEVM send went
    uint32[] internal _dexes; // the watched HIP-3 DEXes (DEX 0 always watched)
    mapping(uint32 => uint64) public dexSince;
    mapping(bytes32 => uint256) public lastSent;
    mapping(address => uint64) public sweepSince;

    // ── version 1: the asset profile (asset-profiles-design.md AP-3, AP-4) ───────────────────────────
    /// The profile the strategy was created on: its short part (`perp`, `asset`) is this leg's; a profile
    /// switch keeps it (§3.7: the short part is identical), so the books read the hub's current id.
    bytes32 public profile;

    struct Cancel {
        uint32 asset;
        bool byCloid;
        uint128 id;
    }

    /// A DEX to watch (it joins for good when it holds at least 1 USD or any position) and the
    /// collateral token its balance is sent back in (USDC or a pinned stablecoin). A wrong hint is
    /// refused by Hyperliquid and costs nothing; it is not stored.
    struct DexHint {
        uint32 dex;
        uint64 collateral;
    }

    struct ExitArgs {
        Cancel[] cancels; // resting orders to cancel: no precompile lists them
        uint32[] perps; // DEX 0 perps with a position, besides the strategy's own
        DexHint[] dexes;
    }

    struct State {
        bool gate; // DEX 0 and every watched DEX not dropped out read zero notional
        bool budgetMode; // a dropped-out DEX reads notional (or can't be read)
        bool waitingOwner;
        uint64 reserve; // R, USDC Core wei
        uint64 wd; // DEX 0 withdrawable, 1e6
        uint64 spotUsdc; // available
        uint64 spotUsdcTotal;
        uint64 spotHype; // available
        uint64 hypePx; // 1e8
        int64 value0; // DEX 0 account value
        bool[] ok;
        HyperCore.MarginSummary[] ms;
    }

    event AgentProposed(address indexed agent, uint256 effectiveAt);
    event AgentSet(address indexed agent);
    event AgentCancelled();
    event DexWatched(uint32 indexed dex);

    error TooEarly();
    error NoCoreAccount();
    error NoAgent();
    error BadAsset();
    error NotResidue();
    error NotOwnerWallet();

    /// The report's holdings (§3.6, decision 45; the fee-value probe's identity, exact in both account
    /// modes): `USD` = DEX 0's account value less the strategy's perp at its mark (`accountValue − szi ×
    /// markPx`: the perp's cash, `rawUsd`, plus every OTHER DEX 0 position at its mark, so a side position
    /// the agent opens counts at what it is worth, its proceeds and its liability together: the security
    /// review of 2026-10-16, replacing 2b's 1 % tolerance on `rawUsd`) + spot USDC (the available amount
    /// in unified mode, so the perp margin counts once) + the USDC this contract holds on HyperEVM (a mint
    /// that landed but is not yet in HyperCore); and the perp's size `szi` as its asset, which the hub
    /// values at its own price; 18 decimals. Its word: the block of its last move between HyperEVM and
    /// HyperCore, which HyperCore credits within a block or two.
    function _holdings() internal view override returns (Holding[] memory h, uint256) {
        (bool ok, HyperCore.MarginSummary memory m) = HyperCore.marginSummary(0, address(this));
        if (!ok) revert BadMessage(); // a report with the perp's cash read as zero would mislead the hub
        HyperCore.SpotBalance memory spot = HyperCore.spotBalance(address(this), USDC_TOKEN);
        int64 szi = HyperCore.position(address(this), perp).szi;
        // szi in 10^-szDecimals, the mark in 10^-(6 - szDecimals): their product in USD × 1e6
        int256 cash = int256(m.accountValue) - int256(szi) * int256(uint256(HyperCore.markPx(perp)));
        int256 usd = cash * 1e12 + int256(uint256(spot.total)) * 1e10
            + int256(IERC20(USDC).balanceOf(address(this))) * 1e12;
        uint8 szd = HyperCore.perpSzDecimals(perp);
        h = new Holding[](2);
        h[0] = Holding(Assets.USD, usd);
        h[1] = Holding(asset, int256(szi) * int256(10 ** (18 - szd)));
        return (h, lastCoreMove);
    }

    function _usdc() internal pure override returns (address) {
        return USDC;
    }

    /// The agent trades this account without a call of this contract (amendment 2b §3.4).
    function _tracked() internal pure override returns (bool) {
        return false;
    }

    function _cancel(Cancel memory c) internal {
        if (c.byCloid) HyperCore.cancelByCloid(c.asset, c.id);
        else HyperCore.cancelByOid(c.asset, uint64(c.id));
    }

    function _perpLimit(uint32 p, uint8 szd, bool isBuy) internal view returns (uint64) {
        return HyperCore.boundedPx(uint256(HyperCore.oraclePx(p)) * 10 ** (2 + szd), orderBoundBp, isBuy, 6 - szd);
    }

    function _key(uint8 kind, uint64 a, uint64 b) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind, a, b));
    }

    /// Pacing: an action sent in the last 20 blocks is not sent again. Marks it sent when due.
    function _due(uint8 kind, uint64 a, uint64 b) internal returns (bool) {
        bytes32 k = _key(kind, a, b);
        uint256 last = lastSent[k];
        if (last != 0 && block.number < last + PACING_BLOCKS) return false;
        lastSent[k] = block.number;
        return true;
    }

    /// The agent named now; in exit, the exit's own (the burner, or the owner's choice).
    function _useAgent(address next) internal {
        if (exiting) exitAgent = next;
        _setAgent(next);
    }

    function _setAgent(address next) internal {
        HyperCore.addApiWallet(next, AGENT_NAME);
        agent = next;
        agentEverSet = true;
        emit AgentSet(next);
    }

    // ── internals both exit modules use ──────────────────────────────────────────────────────────

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


}
