// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {VaultState} from "./VaultBase.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {FeeMath} from "./lib/FeeMath.sol";
import {PriceSourcePin} from "./lib/PriceSource.sol";
import {Holding} from "./lib/VaultTypes.sol";

/// What a hub reads of its chain's registry (amendment 2b §3.7, §3.9).
interface IFeeRegistry {
    function feeAddress() external view returns (address);
    function recovery() external view returns (address);
}

/*
 * The hub's STORAGE, events, errors and shared internals (step 11e2 amendment 2a §3.7, amendment 2b
 * §3.2): inherited by the hub (`StrategyHub is VaultBase, StrategyHubState`) and by its fee module
 * (`StrategyHubFee is StrategyHubState`), which runs by DELEGATECALL in the hub's storage (amendment 2a
 * §3.8's mechanism: inline, the hub misses invariant 13's room). `VaultBase` declares no storage and
 * neither do the two contracts, so both layouts are `VaultState`'s then this one's; `test.mjs` compares
 * them slot for slot.
 */
abstract contract StrategyHubState is VaultState {
    uint16 internal constant MAX_FAST_FEE_CAP_BP = 50;
    uint16 internal constant MAX_FEE_BUDGET_BP = 500;
    // amendment 2b §3.2, §11: the author's calls (FeeMath holds the fee's own)
    uint256 internal constant MAX_REPORT_AGE = 10 minutes;
    uint256 internal constant MAX_CLOCK_SKEW = 1 minutes;
    uint256 internal constant MIN_BLOCKS_AFTER_MOVE = 3;
    uint256 internal constant SNAPSHOT_WINDOW = 3 minutes;
    uint256 internal constant POSITION_TOLERANCE_BP = 1;

    // ── fixed at creation ────────────────────────────────────────────────────────────────────────────
    uint16 public fastFeeCapBp;
    uint16 public feeBudgetBp;
    address public sequencerFeed; // this chain's L2 sequencer uptime feed, zero on Ethereum
    uint8[4] public legValueKind; // link k's `Legs.VALUE_*`, as its factory pinned it
    PriceSourcePin[] internal _priceSources; // this chain's, as its factory pinned them

    // ── the fee (amendment 2b §3.2) ──────────────────────────────────────────────────────────────────
    uint16 public feeRateBp;
    /// The rate the owner signed (`HubParams.feeRateBp`): the ceiling of every later rate (the security
    /// review of 2026-10-16: a rate above it would charge the owner what they never agreed to).
    uint16 public signedFeeRateBp;
    uint64 public lastFeeAt; // the last non-zero fee by `crystallize` or `payout`; creation at first
    int256 public mark; // USDC units: the value above which profit is new
    uint256 public booked; // the USDC balance as the hub's own moves explain it
    uint256 public feeOwed; // fees charged whose transfer failed: outside the value, `claimFee`
    int256 public exitBase;
    int256 public exitFrom; // the level above which the exit's profit takes the current rate
    uint256 public exitPaid; // to the owner's withdrawal address
    uint256 public exitFeePaid; // to DLTX, transferred or owed
    uint256 public exitFeeForgiven; // no fee address: the owner kept it
    uint256 public exitCheckDue; // the due fixed at earlier rates

    // ── the snapshot (amendment 2b §3.4) ─────────────────────────────────────────────────────────────
    uint64 public snapshotAt;
    mapping(uint8 => bytes) internal _snapshots; // link k on this chain: its `holdings()` at `snapshotAt`

    /// The latest report of each leg: the highest sequence number received, its observation time (the
    /// leg's own clock, inside the payload) and its arrival time, kept apart (§3.6).
    struct Report {
        uint64 seq;
        uint64 observedAt;
        uint64 receivedAt;
        bytes body;
    }

    mapping(uint8 => Report) internal _reports;

    event Payout(address indexed to, uint256 amount);
    event ReportReceived(uint8 indexed link, uint64 seq, uint64 observedAt);
    event CapitalIn(uint256 amount);
    event Snapshot(uint64 at);
    event FeeCharged(
        int256 value, int256 markBefore, uint256 profit, uint256 fee, int256 mark, uint16 rateBp, uint64 snapshotAt, uint64 reportSeq
    );
    event FeeDeferred(bytes4 why);
    event FeeSetAside(uint256 amount);
    event FeeClaimed(address indexed to, uint256 amount);
    event FeeRateSet(uint16 previous, uint16 next, address indexed by);
    event ExitSettled(uint256 realised, int256 exitBase, uint256 exitFeePaid, uint256 exitFeeForgiven, uint256 exitPaid);

    error BadParams();
    error NoUsdc();
    // why the value or a charge is refused (amendment 2b §3.4–§3.7)
    error NoSnapshot();
    error SnapshotIncomplete();
    error StaleReport();
    error FutureReport();
    error MoveSettling();
    error UnknownAsset();
    error ReportedValue();
    error TooManyRemote();
    error UntrackedLeg();
    error PositionMoved();
    error TooSoon();
    error NeedUsdc();
    error NoFeeAddress();
    error BadRate();

    /// Circle's USDC on the deposit chains (step 11e1's chain files; `DepositAccount.cctpUsdc()`).
    function _usdc() internal view override returns (address usdc) {
        uint256 id = block.chainid;
        if (id == 1) usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        else if (id == 43114) usdc = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        else if (id == 10) usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        else if (id == 42161) usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        else if (id == 8453) usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        else if (id == 137) usdc = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
        else if (id == 999) usdc = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
        else revert NoUsdc();
    }

    /// The hub reports nothing (it has no `report`): it is where reports arrive.
    function _holdings() internal pure override returns (Holding[] memory h, uint256 extra) {
        (h, extra) = (new Holding[](0), 0);
    }

    function _tracked() internal pure override returns (bool) {
        return true;
    }

    // ── capital (amendment 2b §3.3) ──────────────────────────────────────────────────────────────────────

    /// Every USDC that reached the hub without being one of its counted moves is capital: it raises the
    /// mark (and, in exit, both of the exit's thresholds). A balance below `booked` is re-based.
    function _sync() internal {
        (uint256 inflow, uint256 nowBooked) = FeeMath.inflow(IERC20(_usdc()).balanceOf(address(this)), booked);
        booked = nowBooked;
        if (inflow == 0) return;
        mark += int256(inflow);
        if (exiting) {
            exitBase += int256(inflow);
            exitFrom += int256(inflow);
        }
        emit CapitalIn(inflow);
    }

    /// The hub's USDC less the fees set aside.
    function _free() internal view returns (uint256) {
        uint256 b = IERC20(_usdc()).balanceOf(address(this));
        return b > feeOwed ? b - feeOwed : 0;
    }

    /// A fee transfer never reverts: refused (DLTX's address frozen), the fee is set aside in the hub.
    function _payFee(address to, uint256 fee) internal {
        if (_tryTransfer(to, fee)) {
            booked -= fee;
        } else {
            feeOwed += fee;
            emit FeeSetAside(fee);
        }
    }

    function _tryTransfer(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = _usdc().call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// A new rate; in exit, the profit the steps already handled keeps the rate it was handled at.
    function _setRate(uint16 newBp, address by) internal {
        _sync();
        if (exiting) {
            (exitFrom, exitCheckDue) = FeeMath.exitCheckpoint(exitPaid, exitFeePaid, exitFrom, exitCheckDue, feeRateBp);
        }
        emit FeeRateSet(feeRateBp, newBp, by);
        feeRateBp = newBp;
    }
}
