// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {MemberBase} from "./MemberBase.sol";
import {ILinkV1} from "./MemberState.sol";
import {HubState} from "./HubState.sol";
import {HubFee} from "./HubFee.sol";
import {IRegistryV1} from "./Interfaces.sol";
import {IDepositOwner} from "./interfaces/IDepositOwner.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {FeeMath} from "./lib/FeeMath.sol";
import {PriceSourcePin} from "./lib/PriceSource.sol";
import {Holding} from "./lib/VaultTypes.sol";
import {HubParams, MemberTypes, ParamsTypesV1} from "./Types.sol";

/// What a hub reads of its combination factory at its initialisation: each leg's value kind, in leg order.
interface IHubSetupV1 {
    function hubSetup() external view returns (uint8[] memory valueKinds);
}

/*
 * VERSION 1 of a strategy's HUB (version 0's `StrategyHub`, owner-upgradeable and profile-aware): the
 * strategy's HOME for the owner's upgrade and profile switch (owner-upgrades-design.md §C4,
 * asset-profiles-design.md §3.7), its fee's price pins its profile's (§3.6). Version 0's text follows.
 *
 * A strategy's HUB (step 11e2 amendment 2a, revision 1, decision 43, §3.7): the strategy's account, with
 * no market position and no market call of any kind. The owner's deposit contract funds it (it alone is
 * registered for funding, `authorisedFor`); it sends the legs their money, pays the owner, stores the
 * legs' reports, and ends the exit by paying the owner's withdrawal address on its chain.
 *
 * Amendment 2b: DLTX's PERFORMANCE FEE, computed by the hub from figures it reads or receives
 * authenticated; the server decides when, and supplies no number (decision 49):
 *   - the MARK: capital in raises it (every USDC that reaches the hub without being one of its counted
 *     moves, `_sync`), a payment to the owner lowers it, a fee charged raises it to the value net of the
 *     fee; a loss must be earned back before any new fee;
 *   - the valuation, `crystallize` (at most once a day, the profit capped on the mark), `payout` (it
 *     charges first when it can, pays anyway when it can't: decision 51) and the rate (set by recovery) live in
 *     its fee module, `StrategyHubFee` (amendment 2a §3.8's mechanism: inline, the hub is over EIP-170),
 *     dispatched by `VaultBase`'s fallback in this hub's storage;
 *   - the exit charges on the cash it pays out, with no price and no report (decision 53); fee
 *     transfers never block the owner (`feeOwed`).
 *
 * One code, deployed through the deterministic deployer at one address on every deposit chain a
 * combination may put its hub on: its USDC comes from a pinned table by chain id, as the deposit
 * contract's `cctpUsdc()`.
 */
contract Hub is MemberBase, HubState {
    /// Amendment 2d §5.2: the gas `exitDebt()`'s read may take, and what each of the exit's self-calls is
    /// admitted with (`GasTooLow` below it), so that a gas estimate can never buy a skipped route or
    /// payout: about twice the fork's measures (`test_fork_2d_hubStep_gasMeasured`).
    uint256 internal constant EXIT_DEBT_GAS = 300_000;
    uint256 internal constant ROUTE_GAS = 600_000;
    uint256 internal constant SETTLE_GAS = 450_000; // 2e's management settlement: 194k on the fork, warm
    bytes4 internal constant EXIT_DEBT_SELECTOR = bytes4(keccak256("exitDebt()"));

    /// Amendment 2d §5.2: a route to leg `link`, or the settlement, failed on its own (the reason kept).
    event ExitRouteFailed(uint8 indexed link, bytes reason);
    event ExitSettleFailed(bytes reason);

    /// The fee module (its code hash checked here) and this chain's L2 sequencer uptime feed (zero where
    /// there is none): the hub's chain facts, constructor data (Q11).
    address public immutable feeModule;
    address public immutable sequencer;

    constructor(
        address feeModule_,
        bytes32 feeModuleCodeHash,
        address upgradeModule_,
        bytes32 upgradeModuleCodeHash,
        address sequencer_
    ) MemberBase(upgradeModule_, upgradeModuleCodeHash) {
        _checkModule(feeModule_, feeModuleCodeHash);
        if (sequencer_ != address(0) && sequencer_.code.length == 0) revert BadModule();
        feeModule = feeModule_;
        sequencer = sequencer_;
    }

    function MEMBER_TYPE() public pure override returns (uint8) {
        return MemberTypes.HUB;
    }

    /// The fee module's functions: the fee's six, the profile check (AP-3), the profile switch (§3.7) and
    /// the management fee's setter and view (amendment 2e §3.6).
    function _module(bytes4 s) internal view override returns (address) {
        return s == HubFee.snapshot.selector || s == HubFee.crystallize.selector || s == HubFee.payout.selector
            || s == HubFee.setFeeRate.selector || s == HubFee.value.selector || s == HubFee.preview.selector
            || s == HubFee.checkProfile.selector || s == HubFee.initProfile.selector
            || s == HubFee.scheduleSwitch.selector || s == HubFee.applySwitch.selector
            || s == HubFee.setManagementFee.selector || s == HubFee.managementFee.selector ? feeModule : address(0);
    }

    /// `HubParams` as the owner signs it (amendment 2d §4.2).
    function paramsType() external pure returns (string memory) {
        return ParamsTypesV1.HUB;
    }

    /// Sane bounds on the hub's own parameters, and a profile open to new strategies in `r`, the
    /// factory's registry (this chain's); anything else reverts.
    function validateParams(address r, bytes calldata params) external view {
        _validate(abi.decode(params, (HubParams)), IRegistryV1(r));
    }

    function _validate(HubParams memory p, IRegistryV1 r) internal view {
        if (
            p.fastFeeCapBp > MAX_FAST_FEE_CAP_BP || p.feeBudgetBp == 0 || p.feeBudgetBp > MAX_FEE_BUDGET_BP
                || p.feeRateBp > FeeMath.MAX_FEE_BP || p.managementFeeBp > FeeMath.MAX_MGMT_BP
                || p.flatFeePerMonth > FeeMath.MAX_FLAT_PER_MONTH || !r.profileOpen(p.profile)
        ) revert BadParams();
    }

    /// The parameters the owner signed; the profile and its price pins (`HubFee.initProfile`: open in this
    /// chain's registry, checked by this version's code, stored for good: §3.6, each hub only its own);
    /// this chain's sequencer feed; the legs' value kinds from the factory creating it (`msg.sender`).
    function _initParams(bytes calldata params) internal override {
        HubParams memory p = abi.decode(params, (HubParams));
        _validate(p, IRegistryV1(registry)); // again, on the instance's own registry, whatever factory made it
        HubFee(address(this)).initProfile(p.profile);
        fastFeeCapBp = p.fastFeeCapBp;
        feeBudgetBp = p.feeBudgetBp;
        feeRateBp = p.feeRateBp;
        signedFeeRateBp = p.feeRateBp;
        lastFeeAt = uint64(block.timestamp); // the first day charges nothing; the cap counts from here
        // amendment 2e §3.7: at 0 and 0 no word is written (the slot stays zero, one read wherever it is
        // looked at); the window opens here, then again at the first deposit (mark 0: nothing to charge yet)
        if (p.managementFeeBp != 0 || p.flatFeePerMonth != 0) {
            (_mgmtRateBp, _signedMgmtRateBp) = (p.managementFeeBp, p.managementFeeBp);
            (_flatPerMonth, _signedFlatPerMonth) = (p.flatFeePerMonth, p.flatFeePerMonth);
            _mgmtFrom = uint64(block.timestamp);
        }
        uint8[] memory kinds = IHubSetupV1(msg.sender).hubSetup();
        if (kinds.length != linkCount) revert BadParams();
        for (uint256 k; k < kinds.length; ++k) {
            legValueKind[k] = kinds[k];
        }
        sequencerFeed = sequencer;
    }

    function priceSources() external view returns (PriceSourcePin[] memory) {
        return _priceSources;
    }

    /// A member move credited here (`receiveLocal`, a member's mint): booked, never capital (2b §3.3).
    function _onCredit(uint256 net) internal override {
        booked += net;
    }

    // ── the execution key (§3.7) ─────────────────────────────────────────────────────────────────────────

    /// USDC to leg `k`, once it is ready; Circle's fee charged to the hub's 24-hour fee budget, a share
    /// of its USDC before the burn (invariant 6). Never the fees set aside; refused in exit (the key's
    /// gate). In exit the hub sends a leg only what that leg states it owes (`exitStep`'s routing,
    /// amendment 2d §5.2), before paying the owner: the exit's `realised` can fall by no more than the
    /// interest headroom routed after a payment, and `exitDue` caps the due at the cash in hand.
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external onlyExecution nonReentrant {
        _sync();
        if (amount > _free()) revert NeedUsdc();
        uint256 held = IERC20(_usdc()).balanceOf(address(this));
        uint256 fee = _send(k, amount, fast, maxFee, fastFeeCapBp);
        booked -= amount;
        _chargeFee(fee, held, feeBudgetBp);
    }

    /// Anyone, in any state: the fees set aside, to the fee address the registry names now.
    function claimFee() external nonReentrant {
        uint256 owed = feeOwed;
        address to = IRegistryV1(registry).feeAddress();
        if (owed == 0 || to == address(0) || !_tryTransfer(to, owed)) return;
        booked -= owed;
        feeOwed = 0;
        emit FeeClaimed(to, owed);
    }

    // ── the exit (§3.7; amendment 2b §3.6): anyone, as often as needed ───────────────────────────────────

    /// Entering: the exit's base and threshold at the mark; the hub's `send` is refused from here on. The
    /// management fee's accrual stops (an exiting strategy is no longer managed): its window is frozen here,
    /// and the capital that arrived in it, a pending inflow included, is the exit's own (amendment 2e §3.5).
    function _onExit() internal override {
        // money not yet counted is the exit's own capital, never charged for the window before it
        // (`exiting` is already set, so this `_sync` does not move the window: the review of the build)
        (uint256 pending,) = FeeMath.inflow(IERC20(_usdc()).balanceOf(address(this)), booked);
        _sync();
        exitBase = mark;
        exitFrom = mark;
        exitCheckDue = 0;
        if (_mgmtOn()) {
            uint256 w = block.timestamp - _mgmtFrom;
            _exitMgmtWindow = uint64(w > FeeMath.MGMT_WINDOW ? FeeMath.MGMT_WINDOW : w);
            // the capital arrived since the window opened, the pending inflow with it, is the exit's own
            _exitMgmtEntry = mark - int256(_mgmtCapitalIn + pending);
        }
    }

    /// Amendment 2d §5.2: first each leg on this chain enters its exit (`legExit()`, a no-op for one
    /// already in it: a hub that entered by a member's message told nobody), then the hub's free cash
    /// repays what each of them states it owes (`exitRoute`), then the rest is paid out (`exitSettle`).
    /// Each route and the settlement run in their own self-call, admitted only with the gas they need
    /// (`GasTooLow`), so that one failing (USDC refusing the leg, a blacklisted withdrawal address) rolls
    /// back alone and is logged (`ExitRouteFailed`, `ExitSettleFailed`). Repaying a debt needs no
    /// withdrawal address. Anyone, in exit, as often as needed.
    function exitStep() external nonReentrant inExit {
        _sync();
        uint8 n = linkCount;
        for (uint8 k; k < n; ++k) {
            if (_isLocal(k) && links[k].code.length > 0) ILinkV1(links[k]).legExit();
        }
        for (uint8 k; k < n; ++k) {
            if (!_isLocal(k)) continue;
            if (gasleft() < ROUTE_GAS) revert GasTooLow();
            try this.exitRoute(k) {}
            catch (bytes memory reason) {
                emit ExitRouteFailed(k, reason);
            }
        }
        if (gasleft() < SETTLE_GAS) revert GasTooLow();
        try this.exitSettle() {}
        catch (bytes memory reason) {
            emit ExitSettleFailed(reason);
        }
    }

    /// One route of `exitStep`, the hub's own call only: to leg `k` (on this chain, in exit) what it states
    /// it owes, `exitDebt()` read as one word by a staticcall capped at `EXIT_DEBT_GAS` (a revert, or a leg
    /// type without it, reads zero: never routed to), up to the hub's free cash. Amendment 2a's invariant
    /// 4 as amended: in exit, legs send to the hub only, and the hub sends to a leg only what that leg's
    /// `exitDebt()` states, before paying the owner.
    function exitRoute(uint8 k) external {
        if (msg.sender != address(this)) revert NotAllowed();
        uint256 cash = _free();
        if (cash == 0) return;
        if (gasleft() < EXIT_DEBT_GAS + 50_000) revert GasTooLow();
        address leg = links[k];
        bytes4 sel = EXIT_DEBT_SELECTOR;
        uint256 cap = EXIT_DEBT_GAS;
        uint256 owed;
        assembly ("memory-safe") {
            mstore(0, sel)
            // the call first, its answer's length after: Yul evaluates arguments right to left
            let ok := staticcall(cap, leg, 0, 4, 0, 0x20)
            if and(ok, iszero(lt(returndatasize(), 0x20))) { owed := mload(0) }
        }
        if (owed == 0) return;
        uint256 amount = cash < owed ? cash : owed;
        booked -= amount;
        _toLocal(k, amount);
    }

    /// The settlement of `exitStep`, the hub's own call only: everything the hub holds now to the owner's
    /// withdrawal address on this chain, DLTX's fee taken on the way: on the cash the exit has realised
    /// above its base, cumulatively, capped at the cash in hand (so a step never reverts); with no fee
    /// address the due is forgiven (the owner keeps it). No valuation, no report, no price. It waits for
    /// no leg: what arrives later is paid by a later call. Held while no withdrawal address is set, or while
    /// it names the hub or one of its links (a leg would send it back as a member move, and the next step
    /// would count the same cash as realised again: the combined review's CR-B1); if USDC refuses it, the
    /// fee's accounting rolls back with it.
    function exitSettle() external {
        if (msg.sender != address(this)) revert NotAllowed();
        address to = IDepositOwner(owner).withdrawalAddress();
        uint256 cash = _free();
        if (cash == 0 || to == address(0) || to == address(this)) return;
        for (uint8 k; k < linkCount; ++k) {
            if (links[k] == to) return;
        }
        cash -= _settleMgmt(cash);
        (uint256 realised, uint256 due) =
            FeeMath.exitDue(exitPaid, exitFeePaid, exitFeeForgiven, cash, exitFrom, exitCheckDue, feeRateBp);
        if (due > 0) {
            address feeTo = IRegistryV1(registry).feeAddress();
            if (feeTo == address(0)) {
                exitFeeForgiven += due;
                due = 0;
            } else {
                _payFee(feeTo, due);
                exitFeePaid += due;
            }
        }
        uint256 paid = cash - due;
        if (paid > 0) {
            IERC20(_usdc()).transfer(to, paid);
            booked -= paid;
            exitPaid += paid;
            emit Payout(to, paid);
        }
        emit ExitSettled(realised, exitBase, exitFeePaid, exitFeeForgiven, exitPaid);
    }

    /// Amendment 2e §3.5: the management fee of the exit's frozen window, before 2b's fee, on cash with no
    /// valuation: its base is what the exit has recovered of the money there when the window opened (the
    /// cash it has handled less the capital that arrived since), capped at the mark then; net of what was
    /// paid and forgiven, capped at the cash in hand (a step never reverts). Returns what it took from `cash`.
    function _settleMgmt(uint256 cash) internal returns (uint256 m) {
        uint256 window = _exitMgmtWindow;
        if (window == 0) return 0;
        uint256 gross = exitPaid + exitFeePaid + _exitMgmtPaid + cash;
        int256 recovered = int256(gross) - (exitBase - _exitMgmtEntry);
        uint256 base = FeeMath.mgmtBase(_mgmtMarkStart, recovered);
        uint256 total = FeeMath.mgmtFee(base, window, _mgmtRateBp, _flatPerMonth);
        uint256 settled = _exitMgmtPaid + _exitMgmtForgiven;
        m = total > settled ? total - settled : 0;
        if (m > cash) m = cash;
        if (m == 0) return 0;
        address feeTo = IRegistryV1(registry).feeAddress();
        if (feeTo == address(0)) {
            _exitMgmtForgiven += m;
            m = 0; // the owner keeps it: nothing leaves the cash
        } else {
            _payFee(feeTo, m);
            _exitMgmtPaid += m;
        }
        emit ExitManagementSettled(gross, _exitMgmtPaid, _exitMgmtForgiven);
    }

    /// Anyone, in every state: completes a Circle mint bound to the hub and counts it (`_receiveMint`).
    function receiveMint(bytes calldata message, bytes calldata attestation) external nonReentrant {
        _receiveMint(message, attestation);
    }

    // ── reports (§3.6, decision 45) ────────────────────────────────────────────────────────────────────

    /// A leg on this chain hands its report directly.
    function receiveReport(bytes calldata body) external nonReentrant {
        uint8 k = _linkOf(msg.sender);
        if (!_isLocal(k)) revert BadMessage();
        _store(k, body);
    }

    function _onReport(uint8 k, bytes calldata body) internal override {
        _store(k, body);
    }

    /// Keeps the report of the highest sequence number; an older one is ignored (Circle delivers out of
    /// order). A body that doesn't decode as a report (amendment 2b's payload) is refused here, so the
    /// valuation never reverts on one.
    function _store(uint8 k, bytes calldata body) internal {
        if (body.length < 96) revert BadMessage();
        (bytes32 tag, uint256 seq, uint256 observedAt) = abi.decode(body[0:96], (bytes32, uint256, uint256));
        if (tag != REPORT_MESSAGE || seq > type(uint64).max || observedAt > type(uint64).max) revert BadMessage();
        try this.checkReport(body) {}
        catch {
            revert BadMessage();
        }
        Report storage r = _reports[k];
        if (seq <= r.seq) return;
        r.seq = uint64(seq);
        r.observedAt = uint64(observedAt);
        r.receivedAt = uint64(block.timestamp);
        r.body = body;
        emit ReportReceived(k, uint64(seq), uint64(observedAt));
    }

    /// Decodes `body` as a report, at most 16 holdings; reverts otherwise. For `_store`'s `try`.
    function checkReport(bytes calldata body) external pure {
        (,,,,, Holding[] memory h,,,) = abi.decode(
            body, (bytes32, uint256, uint256, uint256, uint256, Holding[], uint256[4], uint256[4], uint256[4])
        );
        if (h.length > 16) revert BadMessage();
    }

    /// Leg `k`'s latest report: its sequence number, observation and arrival times, and its body
    /// (`abi.encode(REPORT_MESSAGE, seq, observedAt, observationBlock, lastMoveBlock, Holding[],
    /// sentTo[4], receivedFrom[4], feesFrom[4])`).
    function reportOf(uint8 k)
        external
        view
        returns (uint64 seq, uint64 observedAt, uint64 receivedAt, bytes memory body)
    {
        Report storage r = _reports[k];
        return (r.seq, r.observedAt, r.receivedAt, r.body);
    }

    /// Leg `k`'s `holdings()` as the snapshot recorded them (a leg on this chain), for the mirror (§6).
    function snapshotOf(uint8 k) external view returns (bytes memory) {
        return _snapshots[k];
    }
}
