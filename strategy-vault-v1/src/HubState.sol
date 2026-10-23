// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {MemberState} from "./MemberState.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {FeeMath} from "./lib/FeeMath.sol";
import {PriceSourcePin} from "./lib/PriceSource.sol";
import {Holding} from "./lib/VaultTypes.sol";

/*
 * Version 1 of the hub's STORAGE, events, errors and shared internals (version 0's `StrategyHubState`,
 * made profile-aware: asset-profiles-design.md §3.6, §3.7): inherited by the hub (`Hub is MemberBase,
 * HubState`) and by its fee module (`HubFee is HubState`), which runs by DELEGATECALL in the hub's
 * storage. The layout is `MemberState`'s then this one's, append only; `test.mjs` compares them.
 */
abstract contract HubState is MemberState {
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

    // ── version 1: the asset profile (asset-profiles-design.md §3.6, §3.7) ───────────────────────────
    /// The profile this strategy runs, its CURRENT one: written at creation and by a profile switch only
    /// (V10). Its price pins are `_priceSources`, copied at creation and never changed by a switch.
    bytes32 public profile;

    // ── version 1: the management fee (amendment 2e §3.2) ────────────────────────────────────────────
    // The first six in one slot: a strategy at 0 pays one storage read where the fee is looked at (§3.7).
    // `internal`, read through `HubFee.managementFee()`: public getters would be compiled into both the hub
    // and its module.
    uint16 internal _mgmtRateBp; // the current rate a year
    uint16 internal _signedMgmtRateBp; // the owner's signed rate: its ceiling for good (V11)
    uint32 internal _flatPerMonth; // the current flat amount a month, USDC units
    uint32 internal _signedFlatPerMonth; // the owner's signed amount: its ceiling for good (V11)
    uint64 internal _mgmtFrom; // the window not yet charged opened here (a charge, the first capital, a change)
    uint64 internal _exitMgmtWindow; // the seconds accrued at the exit's entry, frozen, at most MGMT_WINDOW
    int256 internal _exitMgmtEntry; // `exitBase − it` is the capital that arrived since the window opened
    uint256 internal _exitMgmtPaid; // the exit's management fee transferred or set aside (`feeOwed`)
    uint256 internal _exitMgmtForgiven; // and forgiven (no fee address: the owner kept it)
    // The window's capital (the build's review, Codex's round): the mark when it opened, the cap of its base,
    // and the capital that arrived since, taken out of the value at the charge, so money is never charged
    // for time before it arrived and never stands in for capital lost before it arrived (as the exit's).
    int256 internal _mgmtMarkStart;
    uint256 internal _mgmtCapitalIn;

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
    event ManagementFeeCharged(
        int256 value,
        int256 mark,
        uint256 base,
        uint256 window,
        uint256 fee,
        uint16 rateBp,
        uint32 flatPerMonth,
        uint64 snapshotAt,
        uint64 reportSeq
    );
    event ManagementFeeDeferred(bytes4 why);
    event ManagementFeeSet(uint16 previousBp, uint16 nextBp, uint32 previousFlat, uint32 nextFlat, address indexed by);
    event ExitManagementSettled(uint256 gross, uint256 exitMgmtPaid, uint256 exitMgmtForgiven);

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
    event ProfileSwitched(bytes32 indexed fromProfile, bytes32 indexed toProfile);

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
        } else if (_mgmtOn()) {
            // amendment 2e §3.3: money that arrives is kept out of the window's base (charged from the next
            // window on); the first capital of a window with nothing to charge opens it
            if (_mgmtMarkStart <= 0) _mgmtOpen();
            else _mgmtCapitalIn += inflow;
        }
        emit CapitalIn(inflow);
    }

    /// A new management window from now: its cap the mark now, no capital arrived in it yet.
    function _mgmtOpen() internal {
        _mgmtFrom = uint64(block.timestamp);
        _mgmtMarkStart = mark;
        _mgmtCapitalIn = 0;
    }

    /// The management fee's base at a value `v` that counts `pending` USDC not yet synced: what the window
    /// holds of the money there when it opened, `max(0, min(mark then, v − the capital arrived since))`.
    function _mgmtBase(int256 v, uint256 pending) internal view returns (uint256) {
        return FeeMath.mgmtBase(_mgmtMarkStart, v - int256(_mgmtCapitalIn + pending));
    }

    /// Either management knob above 0 (one storage read: the packed slot).
    function _mgmtOn() internal view returns (bool) {
        return _mgmtRateBp != 0 || _flatPerMonth != 0;
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
