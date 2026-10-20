// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {VaultState} from "./VaultBase.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {Assets, Holding} from "./lib/VaultTypes.sol";

/*
 * The Hyperliquid leg's STORAGE, constants and shared internals (step 11e2 amendment 2a §3.8): inherited
 * by the leg (`ShortVault is VaultBase, ShortVaultState`) and by its exit module (`ShortVaultExit is
 * ShortVaultState`), which runs by DELEGATECALL in the leg's storage. `VaultBase` declares no storage and
 * neither do the two contracts, so both layouts are `VaultState`'s then this one's; `test.mjs`
 * compares them slot for slot (`forge inspect … storageLayout`) before any test.
 */
abstract contract ShortVaultState is VaultState {
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
}
