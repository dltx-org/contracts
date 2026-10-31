// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {MemberState} from "./MemberState.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {RouteMath} from "./lib/RouteMath.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {Assets, Holding} from "./lib/VaultTypes.sol";
import {Routes} from "./Types.sol";

/*
 * Version 1 of the Hyperliquid leg's STORAGE, constants and shared internals (version 0's
 * `ShortVaultState`, owner-upgradeable and profile-aware): inherited by the leg (`HyperCoreLeg is
 * MemberBase, HyperCoreLegState`) and by its two exit modules (`HyperCoreLegExit`, `HyperCoreLegExitB`:
 * version 0's exit module split, asset-profiles-design.md §3.2, over EIP-170 otherwise) and its route
 * module (`HyperCoreLegRoute`, the key's `order`), which run by DELEGATECALL in the leg's storage. The
 * layout is `MemberState`'s then this one's, append only; `test.mjs` compares the four slot for slot.
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
    /// The owner's `REPLACE_AGENT` names a burner by this sentinel: a burner's address exists only once
    /// the leg derives it, so no one can claim it on HyperCore ahead of time (the audit of 2026-10-26,
    /// finding 1)
    address internal constant BURNER = address(1);
    uint256 internal constant AGENT_DELAY = 24 hours;
    /// How long a burner stands before the owner may end the quarantine (spec §4.6): time for the
    /// owner to see it approved on Hyperliquid, and the old agent gone
    uint256 internal constant QUARANTINE_MIN = 1 hours;
    uint256 internal constant PACING_BLOCKS = 20;
    uint256 internal constant DROP_OUT = 7 days;
    uint256 internal constant WALLET_STANDING = 24 hours;
    uint256 internal constant MAX_DEXES = 16;
    uint8 internal constant MAX_PURCHASES = 3;
    /// HYPE kept on spot for the transfers' fee: above the 0.00016 HYPE measured (§5) at 1 gwei. Core wei,
    /// 8 dp. The least: `_hypeReserve` raises it with HyperEVM's base fee.
    uint64 internal constant HYPE_FEE_RESERVE = 20_000;
    uint256 internal constant HYPE_FEE_GAS = 200_000;
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

    // the contract route's compiled bounds (spec §4.1, §13.2)
    uint16 internal constant FEE_BP = uint16(RouteMath.FEE_BP); // the taker fee a fill is costed at (4.5 bp, rounded up)
    uint16 internal constant MIN_BAND_BP = 10;
    uint16 internal constant MAX_LEVERAGE_X100 = 2_000; // 20x
    uint16 internal constant MAX_BUILDER_FEE_X10 = 20; // 2 bp
    /// Growth waits while the mark and the oracle are more than this apart, of the mark (spec §4.3 step 4)
    uint256 internal constant MARK_SLACK_BP = 20;
    /// A growth order is at most this share of the cap, in hundredths (spec §4.3 step 5)
    uint256 internal constant MAX_ORDER_X100 = 25;
    /// Hyperliquid's $10 order minimum, USD × 1e6 (spec §4.3 step 6)
    uint256 internal constant MIN_ORDER_USD = 10e6;
    /// The growth budget refills one cap over this (spec §4.5)
    uint256 internal constant GROW_REFILL = 24 hours;
    /// HyperCore blocks a leverage-raising action is held unsettled for (spec §4.4). PROVISIONAL: Plan 3's
    /// contract probe replaces it with ten times the delay it measures between an action and HyperCore
    /// applying it (§12)
    uint64 internal constant SETTLE_L1_BLOCKS = 500;
    /// The referral setup (spec §16, Amendment A): what the account may hold when the setup agent is
    /// approved, DEX 0's account value (USD × 1e6) and spot USDC (Core wei): $5 each, the creation deposit
    /// and `prime`'s amounts; and the time after which anyone may end it
    int64 internal constant SETUP_MAX_VALUE = 5e6;
    uint64 internal constant SETUP_MAX_SPOT = 5e8;
    uint256 internal constant SETUP_WINDOW = 1 hours;

    // kinds of paced actions
    uint8 internal constant K_AGENT = 1;
    uint8 internal constant K_CLOSE = 2;
    uint8 internal constant K_MARGIN = 3;
    uint8 internal constant K_DEX = 4;
    uint8 internal constant K_BUY = 5;
    uint8 internal constant K_TO_EVM = 6;
    uint8 internal constant K_SELL = 7;
    uint8 internal constant K_SWEEP = 8;
    uint8 internal constant K_STRAY = 9;
    uint8 internal constant K_SETUP_END = 10;
    // 11 was the pace on anyone's `cancelResting`, removed: a shared pace starves the owner's cancels
    uint8 internal constant K_APPROVE_BUILDER = 12;
    /// Anyone's `cancelResting`: at most this many cancels a call (the final review of 2026-10-28, I2: a
    /// stranger must not make the leg send CoreWriter actions without bound); not paced
    uint256 internal constant MAX_CANCELS = 50;

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

    // ── the audit of 2026-10-26, finding 1: burners from exit entropy ────────────────────────────────
    /// Whether the agent is a burner, so that each re-approval in the exit names a fresh one
    bool public burning;
    uint64 internal burnerNonce;

    // ── the contract route (hyperliquid-contract-route-design.md §4.1, §4.4, §4.5, §13.2) ─────────────
    /// Signed in `CreateVault`: the route (`Routes`; only the owner moves it later), the side on the perp
    /// (`Sides`), the leverage cap (× 100) and the growth and reduction bands (bp around the oracle)
    uint8 public route;
    uint8 public side;
    uint16 public maxLeverageX100;
    uint16 public growBoundBp;
    uint16 public reduceBoundBp;
    /// After a switch to the contract route, until the owner ends it; when the last burner went in
    /// (timestamp), from which `END_QUARANTINE`'s hour runs
    bool public quarantine;
    uint64 internal burnerAt;
    /// The HyperCore block of the one unsettled leverage-raising action
    uint64 internal riskL1At;
    /// The growth budget: what is left of the bucket and when it was last taken from (0: full)
    uint64 internal growLeft;
    uint64 internal growAt;
    /// The Hyperliquid builder fee: signed at creation, changed only by the owner's `BuilderFee`; a
    /// raise or another builder waits (`pendingBuilder*`) while the credential that signed it stands
    address public builder;
    uint16 public builderFeeX10;
    address public pendingBuilder;
    uint16 public pendingBuilderFeeX10;
    uint64 public pendingBuilderAt;
    bytes32 internal pendingBuilderBy;
    /// Signed in `CreateVault` (spec §16, Amendment A): whether the referral setup runs; whether it ran
    /// (once, for good), and from when anyone may end it (kept after the end: a stranger's retry waits for
    /// it too)
    bool public referralSetup;
    bool public setupDone;
    uint64 public setupUntil;
    /// The setup agent stands: approved by `setupAgent`, ended by the next agent the leg names, whoever
    /// names it (`_useAgent`: `endSetup`, the owner's burner or switch back, the exit). While it stands no
    /// money joins the account and no growth is sent (spec §16)
    bool public setupOpen;
    /// The owner's `CONFIRM_SETUP` (spec §16): after a setup ran, no money joins the account and no
    /// growth is sent on the contract route until it, once, for good
    bool public setupConfirmed;
    /// What `toMargin` sent before the setup ran (USDC, 6 dp; the final review of 2026-10-28, C1): a Circle
    /// deposit sent in the setup's own HyperEVM block is not yet in HyperCore's reads, so `setupAgent` also
    /// refuses past `SETUP_MAX_VALUE` of it
    uint64 internal setupIn;

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
    event RouteChanged(uint8 route);
    event QuarantineEnded();
    /// The route's order as sent (spec §4.3 step 8): its client id, side, size (1e-8) and limit (1e8)
    event RouteOrder(uint128 indexed cloid, bool isBuy, uint64 sz, uint64 limit, bool reduceOnly);
    /// The builder fee as it now stands (spec §13.2); one waiting 24 hours, and its cancel
    event BuilderFeeSet(address indexed builder, uint16 feeX10);
    event BuilderFeeProposed(address indexed builder, uint16 feeX10, uint256 effectiveAt);
    event BuilderFeeCancelled();
    /// The referral setup agent approved, and the time from which anyone may end it (spec §16); a burner
    /// sent in its place (only sent: CoreWriter may drop it, so the engine reads Hyperliquid before funding)
    event SetupAgent(address agent, uint256 until);
    event SetupEnded();
    /// The owner read the account clean after the setup (spec §16): money and growth may resume
    event SetupConfirmed();

    error BadParams();
    error TooEarly();
    error NoCoreAccount();
    error NoAgent();
    error BadAsset();
    error NotResidue();
    error NotOwnerWallet();
    error Quarantined();
    error NotGrowth();
    error CapExceeded();
    error OrderTooLarge();
    error BelowMinimum();
    error MarkOracleGap();
    error GrowthBudget();
    error Isolated();
    error Unsettled();
    error NotFlat();
    error SetupRefused();

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
            + int256(_ownUsdc(USDC)) * 1e12;
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

    /// An automatic close's limit on DEX 0 perp `p` (spec §6, the exit row): the exit's closes, and the agent
    /// route's reduce-only `order`. From the STRICTER of `p`'s oracle and mark (`limitFor`), at
    /// `min(orderBoundBp, p's own maintenance ceiling)` read now, as `closeStray` is: closing part of one
    /// cross position at a cost under its maintenance rate releases more maintenance than it loses (§4.3),
    /// so no such close, even a partial fill at the edge, takes the account under maintenance. A wider price
    /// stays the owner's signed `ownerOrder`. `limit` 0 when a read fails or shows 0 (a delisted perp):
    /// the caller sends nothing. `szd` is `p`'s size decimals, read with its max leverage.
    function _perpLimit(uint32 p, bool isBuy) internal view returns (uint64 limit, uint8 szd) {
        uint8 lev;
        (szd, lev) = HyperCore.tryPerpInfo(p);
        uint64 o = HyperCore.tryPx(HyperCore.PX_ORACLE, p);
        uint64 m = HyperCore.tryPx(HyperCore.PX_MARK, p);
        if (lev == 0 || o == 0 || m == 0) return (0, szd);
        uint256 bp = RouteMath.ceilingBp(lev);
        if (bp > orderBoundBp) bp = orderBoundBp;
        limit = RouteMath.limitFor(o, m, uint16(bp), isBuy, szd);
    }

    /// One unsettled leverage-raising action at a time (spec §4.4), on the contract route: a growth order,
    /// `fromMargin` or `prime`. HyperCore applies each after its HyperEVM block, the precompiles showing the
    /// account before it meanwhile, so the next waits until HyperCore's own clock has run
    /// `SETTLE_L1_BLOCKS` past it (a stalled HyperCore holds it). Reductions and `toMargin` never take it.
    function _takeRiskWindow() internal {
        uint64 now_ = HyperCore.l1BlockNumber();
        uint64 last = riskL1At;
        if (last != 0 && now_ < last + SETTLE_L1_BLOCKS) revert Unsettled();
        riskL1At = now_;
    }

    /// The ONE place the leg sends CoreWriter 12 (spec §13.2): `b` approved at `feeX10`. A revocation (0) in
    /// every state; a nonzero approval only on the agent route outside the exit (the contract route's orders
    /// carry no builder, and the exit's pay none), whichever path asks: `approveBuilder()`, an immediate
    /// lowering, a delayed apply. So no withheld owner message can restore an approval there.
    function _sendBuilder(address b, uint16 feeX10) internal {
        if (feeX10 != 0 && (exiting || route != Routes.AGENT)) revert NotAllowed();
        HyperCore.approveBuilderFee(_builderRate(feeX10), b);
    }

    /// CoreWriter 12's `maxFeeRate` for a rate in tenths of a bp, Hyperliquid's API unit.
    function _builderRate(uint16 feeX10) internal pure returns (uint64) {
        return uint64(feeX10); // UNIT TO MEASURE: spec §13.5 probe
    }

    /// The stored builder's approval withdrawn (12 at 0) where one may stand: only a nonzero stored rate is
    /// ever approved, so at 0 nothing is sent (`USE_CONTRACT`, `_onExit`, a builder change).
    function _revokeBuilder() internal {
        if (builderFeeX10 != 0) _sendBuilder(builder, 0);
    }

    function _dropPendingBuilder() internal {
        pendingBuilder = address(0);
        pendingBuilderFeeX10 = 0;
        pendingBuilderAt = 0;
    }

    /// The leverage cap, `notional ≤ L × equity` (`lev` = L × 100): below zero equity, no room; at zero,
    /// none but for nothing (a flat account may release its last dollar; growth always adds notional).
    function _cap(uint256 notional, int256 equity, uint256 lev) internal pure {
        if (equity < 0 || notional * 100 > lev * uint256(equity)) revert CapExceeded();
    }

    /// The referral setup holds money and growth (spec §16): while its agent stands, and, on the contract
    /// route (the claim's), after it ran until the owner's `CONFIRM_SETUP`. Off that route the server's
    /// agent trades the account anyway, and the confirm is refused there: holding money would only strand it.
    function _setupHolds() internal view returns (bool) {
        return setupOpen || (setupDone && !setupConfirmed && route == Routes.CONTRACT);
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

    /// The agent named now; in exit, the exit's own (a burner, or the owner's choice). `BURNER` names a
    /// fresh burner.
    function _useAgent(address next) internal {
        setupOpen = false; // any agent named after the setup agent ends its standing (spec §16)
        burning = next == BURNER;
        if (burning) {
            next = _newBurner();
            burnerAt = uint64(block.timestamp);
        }
        if (exiting) exitAgent = next;
        _setAgent(next);
    }

    /// A burner agent: an address nobody holds a key for, derived from the previous block's hash and a
    /// counter, so it is known only once this transaction runs: HyperCore's approval of an agent can't
    /// be voided by a stranger who registered the address first, as it could be for an address derivable
    /// in advance (CoreWriter's action fails silently, and no precompile reads the agent back).
    function _newBurner() internal returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encode("dltx.strategy-vault.burner", address(this), blockhash(block.number - 1), ++burnerNonce)
                    )
                )
            )
        );
    }

    /// The HYPE kept for a transfer's fee at this block's base fee (the audit of 2026-10-26, low 8: a fixed
    /// 0.0002 HYPE pays 200,000 gas at 1 gwei only; past it the transfer is dropped silently). Core wei.
    function _hypeReserve() internal view returns (uint64) {
        uint256 r = HYPE_FEE_GAS * block.basefee / 1e10; // wei (18 dp) to Core wei (8 dp)
        return r > HYPE_FEE_RESERVE ? uint64(r) : HYPE_FEE_RESERVE;
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
