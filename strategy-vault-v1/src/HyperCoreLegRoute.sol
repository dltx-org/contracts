// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {HyperCoreLegExit} from "./HyperCoreLegExit.sol";
import {HyperCoreLegState} from "./HyperCoreLegState.sol";
import {IDepositOwner} from "./interfaces/IDepositOwner.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {RouteMath} from "./lib/RouteMath.sol";
import {OwnerMessages} from "./lib/VaultTypes.sol";
import {OwnerMessagesV1, Routes, Sides} from "./Types.sol";

/*
 * The Hyperliquid leg's ROUTE MODULE (hyperliquid-contract-route-design.md §4.3, §4.5, §4.7; a third module
 * for EIP-170, beside the exit's two): the execution key's `order` on both routes, and the contract route's
 * clean-up of what an old agent left (`cancelResting` for anyone, `closeStray` for the key), run only by DELEGATECALL
 * from an instance (`delegated`), in its storage. Pinned as the exit modules are: its address and code hash
 * fixed in the leg's constructor.
 *
 * On the contract route `order` is every bound the spec sets on what the server can trade: IOC only, on
 * the strategy's own perp only, whole size steps, a reduction within `reduceBoundBp` of both the mark and
 * the oracle (never waiting on anything), growth on the signed side within `growBoundBp` of the stricter
 * price, under the leverage cap at the mark AND at the oracle with its worst fill counted, a quarter of the
 * cap at most, never across a mark-oracle gap, never under Hyperliquid's $10, and out of the 24-hour budget.
 *
 * It also holds the Hyperliquid builder fee (spec §13.2), the owner's alone: `setBuilderFee`,
 * `applyBuilderFee`, `cancelBuilderFee` and `approveBuilder`; the owner-signed referral setup (spec §16,
 * Amendment A): `setupAgent` and `endSetup`; and, as the leg's default target, refuses any selector it
 * doesn't hold (`fallback`).
 */
contract HyperCoreLegRoute is HyperCoreLegState {
    /// The leg sends here every selector it doesn't name (`HyperCoreLeg._module`): what this module
    /// doesn't hold either is refused, as the leg refused it before.
    fallback() external {
        revert Unsupported();
    }

    /// One CoreWriter 1 action: an IOC on the strategy's perp, under the engine's client id `cloid`. On the
    /// agent route reduce-only (decision 33), priced as the exit's closes are (`_perpLimit`: the stricter of
    /// oracle and mark, at most the perp's ceiling); on the contract route the route's order (spec §4.3,
    /// steps 1–8).
    function order(bool isBuy, uint64 sz, bool reduceOnly, uint128 cloid)
        external
        delegated
        onlyExecution
        nonReentrant
        counted
    {
        uint32 p = perp; // 1. the market: always the strategy's DEX 0 perp
        uint64 limit;
        if (route != Routes.CONTRACT) {
            if (!reduceOnly) revert NotAllowed();
            (limit,) = _perpLimit(p, isBuy);
            if (limit == 0) revert BadAsset(); // the perp can't be priced now
        } else {
            limit = _routeLimit(p, HyperCore.perpSzDecimals(p), isBuy, sz, reduceOnly);
        }
        HyperCore.orderIoc(p, isBuy, limit, sz, reduceOnly, cloid); // 8. IOC (tif 3)
        emit RouteOrder(cloid, isBuy, sz, limit, reduceOnly);
    }

    /// Anyone, on the contract route (spec §4.2): cancels resting orders, any asset, by oid or cloid. The
    /// route never rests an order of its own, so one resting is an old agent's, and a cancel moves no value;
    /// it must not wait on the server. Not `counted`: it changes no holding, and a count anyone could bump
    /// would void a hub's snapshot (HubFee's `PositionMoved`) for the price of gas. Never in the exit: there
    /// the agent may be the owner's own, and `exitStep` cancels what it is told. At most `MAX_CANCELS` a call
    /// (the final review's I2: a stranger must not make the leg send actions without bound against its own
    /// Hyperliquid address), and NOT paced: a pace shared by everyone would let a stranger, a compromised
    /// server too, starve the owner's quarantine cancels (§5.3). Whether CoreWriter actions count against the
    /// request budget is measured at §12 step 4; the key's `cancel` is not paced either.
    function cancelResting(Cancel[] calldata cs) external delegated nonReentrant {
        if (exiting) revert Exiting();
        if (route != Routes.CONTRACT) revert NotAllowed();
        if (cs.length > MAX_CANCELS) revert BadParams();
        for (uint256 i; i < cs.length; ++i) {
            _cancel(cs[i]);
        }
    }

    /// The execution key, on the contract route (spec §4.2, §5.3): a reduce-only IOC for the whole of
    /// another DEX 0 perp's position (one an old agent left), banded as a reduction is, from THAT perp's
    /// own mark and oracle (`limitFor`), at `min(reduceBoundBp, its own maintenance ceiling)` read now:
    /// closing part of one cross position at a cost under its own maintenance rate releases more
    /// maintenance than it loses (§4.3). Paced 20 blocks, as the exit's `_closeDex0`.
    function closeStray(uint32 p) external delegated onlyExecution nonReentrant counted {
        if (p == perp || p >= SPOT_ASSET_OFFSET) revert BadAsset();
        if (route != Routes.CONTRACT) revert NotAllowed();
        int64 szi = HyperCore.position(address(this), p).szi;
        if (szi == 0) revert NotAllowed();
        if (!_due(K_STRAY, p, 0)) revert TooEarly();
        uint8 szd = HyperCore.perpSzDecimals(p);
        uint64 m = HyperCore.markPx(p);
        uint64 o = HyperCore.oraclePx(p);
        if (m == 0 || o == 0) revert HyperCore.PrecompileFailed(m == 0 ? HyperCore.PX_MARK : HyperCore.PX_ORACLE);
        uint256 lev = HyperCore.perpMaxLeverage(p);
        if (lev == 0) revert BadAsset();
        uint256 bp = RouteMath.ceilingBp(lev);
        if (bp > reduceBoundBp) bp = reduceBoundBp;
        bool isBuy = szi < 0;
        uint64 sz = uint64(isBuy ? -szi : szi) * uint64(10 ** (8 - szd));
        uint64 limit = RouteMath.limitFor(o, m, uint16(bp), isBuy, szd);
        HyperCore.orderIoc(p, isBuy, limit, sz, true, 0);
        emit RouteOrder(0, isBuy, sz, limit, true);
    }

    // ── the referral setup (spec §16, Amendment A): owner-signed, once, $5 and an hour ──────────────────

    /// The execution key, once, where the owner signed `referralSetup`: approves `a` under the agent's
    /// name (CoreWriter 9) so that the server can sign Hyperliquid's `setReferrer` with it. Only on the
    /// contract route, outside quarantine (a switched strategy's burner stays as `END_QUARANTINE` will name
    /// it) and the exit (`onlyExecution`), and only while DEX 0 is flat and the account holds at most
    /// `SETUP_MAX_VALUE` of account value and as much of spot USDC (its total: held USDC counts), on an
    /// account HyperCore knows, and `toMargin` sent at most as much before it (`setupIn`: a deposit sent in
    /// this block is not yet in HyperCore's reads). While it stands, `toMargin`, growth and `topUpHype` are refused; `endSetup`
    /// ends it, and money and growth then wait for the owner's `CONFIRM_SETUP`. Not `counted`: it moves no
    /// holding.
    function setupAgent(address a) external delegated onlyExecution nonReentrant {
        if (!referralSetup || setupDone || route != Routes.CONTRACT || quarantine || a == address(0) || a == BURNER) {
            revert SetupRefused();
        }
        // an approval on an account HyperCore doesn't know is dropped: the one-time setup spent for nothing
        if (!HyperCore.coreUserExists(address(this))) revert NoCoreAccount();
        (bool ok, HyperCore.MarginSummary memory ms) = HyperCore.marginSummary(0, address(this));
        if (!ok) revert HyperCore.PrecompileFailed(HyperCore.PX_MARGIN_SUMMARY);
        if (
            ms.ntlPos != 0 || ms.accountValue > SETUP_MAX_VALUE
                || HyperCore.spotBalance(address(this), USDC_TOKEN).total > SETUP_MAX_SPOT
                // a deposit sent in this block is not in the reads above (the final review's C1)
                || setupIn > uint64(SETUP_MAX_VALUE)
        ) revert SetupRefused();
        setupDone = true;
        uint64 until = uint64(block.timestamp + SETUP_WINDOW);
        setupUntil = until;
        _useAgent(a);
        setupOpen = true;
        emit SetupAgent(a, until);
    }

    /// The setup agent replaced by a fresh burner (`_useAgent(BURNER)`, as `USE_CONTRACT` does): by the
    /// execution key at once, by anyone from `setupUntil` on while the setup agent still stands.
    /// Repeatable after the first end, paced 20 blocks, by the key alone: the engine's retry while
    /// Hyperliquid's API still shows the setup agent (CoreWriter may drop an approval in silence); a
    /// stranger's would rotate the burner the owner's `CONFIRM_SETUP` must name, and starve it (the owner's
    /// own retry is `REPLACE_AGENT(BURNER)`). Only on the contract route, never in quarantine nor in the
    /// exit: there the agent is the owner's choice, the burner `END_QUARANTINE` names, or the exit's own,
    /// and a stranger's retry must never replace it. Not `counted`.
    function endSetup() external delegated nonReentrant {
        if (exiting) revert Exiting();
        if (!setupDone || route != Routes.CONTRACT) revert SetupRefused();
        if (quarantine) revert Quarantined();
        if (block.timestamp < setupUntil || !setupOpen) _checkExecution();
        if (!_due(K_SETUP_END, 0, 0)) revert TooEarly();
        _useAgent(BURNER);
        emit SetupEnded();
    }

    // ── the owner's actions that end a hold (spec §5.3, §16), here for the leg's size ─────────────────────

    /// The owner's `VaultAction`s the leg's `_agentAction` doesn't hold, which it calls on itself after
    /// `ownerAction` checked the signature (so only the leg may call this; any other action is refused
    /// `Unsupported`, as the leg refused it before). Each is bound to the agent now approved (`next`: the burner the owner saw
    /// on Hyperliquid's API) and to the leg's own reads (`readsClean`, module A: not isolated, nothing on
    /// DEX 0 beyond the strategy's perp). Not `counted`: they move no holding.
    ///   - `END_QUARANTINE` (§5.3): only in quarantine (a switched strategy, on the contract route), an hour
    ///     after the last burner went in;
    ///   - `CONFIRM_SETUP` (§16): once, on the contract route, after the referral setup ended (it ran, and its
    ///     agent no longer stands); money and growth resume (`_setupHolds`).
    function routeOwnerAction(uint8 action, address next) external delegated {
        if (msg.sender != address(this)) revert NotAllowed();
        if (action == OwnerMessages.END_QUARANTINE) {
            if (!quarantine) revert Unsupported(); // only a switched strategy, only on the contract route
            if (next != agent) revert NotAllowed();
            if (block.timestamp < uint256(burnerAt) + QUARANTINE_MIN) revert TooEarly();
            if (!HyperCoreLegExit(address(this)).readsClean()) revert NotAllowed();
            quarantine = false;
            emit QuarantineEnded();
        } else if (action == OwnerMessages.CONFIRM_SETUP) {
            if (!setupDone || setupOpen || setupConfirmed || route != Routes.CONTRACT) revert SetupRefused();
            if (next != agent || !HyperCoreLegExit(address(this)).readsClean()) revert NotAllowed();
            setupConfirmed = true;
            emit SetupConfirmed();
        } else {
            revert Unsupported();
        }
    }

    // ── the builder fee (spec §13.2): the owner's alone, 0 at launch ────────────────────────────────────

    /// The owner's `BuilderFee(vault, chainId, builder, feeX10, nonce, deadline)`, by one credential spending
    /// its own nonce, up to `MAX_BUILDER_FEE_X10` (2 bp); anyone may submit it. It replaces anything pending.
    /// The same builder at the same or a lower rate applies at once: stored, and the new approval sent where
    /// one may stand (a 0 revokes, in every state; the contract route stores only). A raise, or another
    /// builder, waits 24 hours (`applyBuilderFee`), cancellable by any credential and only while its signer
    /// stands (M2's rule for agents), so a stolen credential can't point the fee at itself at once; never in
    /// the exit, whose rate is 0 for good (`_onExit`).
    function setBuilderFee(address b, uint16 feeX10, bytes32 credential, uint256 deadline, bytes calldata signature)
        external
        delegated
        nonReentrant
    {
        _checkOwnerAs(credential, _builderFeeHash(b, feeX10, credential, deadline), deadline, signature);
        if (feeX10 > MAX_BUILDER_FEE_X10 || (b == address(0) && feeX10 != 0)) revert BadParams(); // a rate names a builder
        _dropPendingBuilder();
        if (b == builder && feeX10 <= builderFeeX10) {
            builderFeeX10 = feeX10;
            if (feeX10 == 0 || route == Routes.AGENT) _sendBuilder(b, feeX10);
            emit BuilderFeeSet(b, feeX10);
        } else {
            if (exiting) revert Exiting();
            pendingBuilder = b;
            pendingBuilderFeeX10 = feeX10;
            pendingBuilderAt = uint64(block.timestamp);
            pendingBuilderBy = credential;
            emit BuilderFeeProposed(b, feeX10, block.timestamp + AGENT_DELAY);
        }
    }

    /// Anyone, once the owner's pending raise or builder change has stood 24 hours, while the credential that
    /// signed it is still one in this chain's record, never in the exit. A builder change revokes the old one
    /// first; the new approval is sent on the agent route (the contract route stores only).
    function applyBuilderFee() external delegated nonReentrant {
        if (exiting) revert Exiting();
        uint64 at = pendingBuilderAt;
        if (at == 0 || !IDepositOwner(owner).isCredentialId(pendingBuilderBy)) revert NotAllowed();
        if (block.timestamp < uint256(at) + AGENT_DELAY) revert TooEarly();
        address b = pendingBuilder;
        uint16 feeX10 = pendingBuilderFeeX10;
        _dropPendingBuilder();
        if (b != builder) _revokeBuilder();
        builder = b;
        builderFeeX10 = feeX10;
        if (feeX10 != 0 && route == Routes.AGENT) _sendBuilder(b, feeX10);
        emit BuilderFeeSet(b, feeX10);
    }

    /// Any owner credential drops the pending raise or builder change, by its own nonce: the owner's
    /// `BuilderFee` naming what stands (the stored builder and rate).
    function cancelBuilderFee(bytes32 credential, uint256 deadline, bytes calldata signature)
        external
        delegated
        nonReentrant
    {
        _checkOwnerAs(credential, _builderFeeHash(builder, builderFeeX10, credential, deadline), deadline, signature);
        _dropPendingBuilder();
        emit BuilderFeeCancelled();
    }

    /// Anyone: the signed builder approved at the signed rate (CoreWriter 12, once; it moves no money). At 0
    /// nothing; above 0 only on the agent route outside the exit (`_sendBuilder`), so an approval never
    /// stands where no order can use it. Paced 20 blocks, as `cancelResting` (the final review's I2).
    function approveBuilder() external delegated nonReentrant {
        uint16 feeX10 = builderFeeX10;
        if (feeX10 != 0) {
            _sendBuilder(builder, feeX10); // its refusals first; a call too early sends nothing (reverts)
            if (!_due(K_APPROVE_BUILDER, 0, 0)) revert TooEarly();
        }
    }

    function _builderFeeHash(address b, uint16 feeX10, bytes32 credential, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                OwnerMessagesV1.BUILDER_FEE_TYPEHASH, address(this), block.chainid, b, feeX10, ownerNonceOf[credential], deadline
            )
        );
    }

    /// The contract route's checks, in the spec's terms; the limit to send. Every input read now.
    function _routeLimit(uint32 p, uint8 szd, bool isBuy, uint64 sz, bool reduceOnly) internal returns (uint64 limit) {
        // 2. whole size steps (HyperCore drops any other silently), and something to send
        uint64 st = RouteMath.steps(sz, szd);
        if (st == 0) revert RouteMath.BadSize();
        HyperCore.Position memory pos = HyperCore.position(address(this), p);
        uint64 m = HyperCore.markPx(p);
        uint64 o = HyperCore.oraclePx(p);
        if (m == 0 || o == 0) revert HyperCore.PrecompileFailed(m == 0 ? HyperCore.PX_MARK : HyperCore.PX_ORACLE);
        int256 szi = pos.szi;
        uint256 size = uint256(szi < 0 ? -szi : szi);
        if (reduceOnly) {
            // 3. a reduction closes, at most the whole position; 4. within `reduceBoundBp` of BOTH prices.
            // Never a budget, a window or quarantine: protection can always shrink the hedge
            if (isBuy != (szi < 0)) revert NotGrowth();
            if (st > size) revert OrderTooLarge();
            return RouteMath.limitFor(o, m, reduceBoundBp, isBuy, szd);
        }
        // 3. growth: not in quarantine, not isolated, the signed side only, never across zero
        if (quarantine) revert Quarantined();
        if (_setupHolds()) revert SetupRefused(); // spec §16: no growth until the owner confirms the setup
        if (pos.isIsolated) revert Isolated();
        bool sideBuy = side == Sides.LONG;
        if (isBuy != sideBuy || (szi != 0 && (szi > 0) != sideBuy)) revert NotGrowth();
        // 4. `growBoundBp` from the stricter of the two prices; `px` the limit in the mark's unit, rounded
        // against the trade
        limit = RouteMath.limitFor(o, m, growBoundBp, isBuy, szd);
        uint64 px = RouteMath.pxOf(limit, szd, isBuy);
        // 5. the cap after this order, its worst fill counted: at the mark, `ntlPos + n ≤ L × (accountValue
        // − w)` (every DEX 0 position); at the oracle, `|szi| × O + steps × O ≤ L × (E_O − w_O)`, the equity
        // re-valued there (`E_O = accountValue + szi × (O − M)`)
        (bool ok, HyperCore.MarginSummary memory ms) = HyperCore.marginSummary(0, address(this));
        if (!ok) revert HyperCore.PrecompileFailed(HyperCore.PX_MARGIN_SUMMARY);
        uint256 lev = maxLeverageX100;
        int256 av = ms.accountValue;
        uint256 n = RouteMath.notional(st, m);
        _cap(ms.ntlPos + n, av - int256(RouteMath.worstFill(st, m, px, isBuy)), lev);
        _cap(
            (size + st) * o,
            av + szi * (int256(uint256(o)) - int256(uint256(m))) - int256(RouteMath.worstFill(st, o, px, isBuy)),
            lev
        );
        // ... and a quarter of the cap at most (`av` is positive: the cap at the mark passed)
        if (n * 10_000 > MAX_ORDER_X100 * lev * uint256(av)) revert OrderTooLarge();
        // 4. growth is never urgent: it waits out a gap between the mark and the oracle
        if ((m > o ? m - o : o - m) * 10_000 > MARK_SLACK_BP * m) revert MarkOracleGap();
        // 6. Hyperliquid's $10 minimum, at the limit
        if (RouteMath.notional(st, px) < MIN_ORDER_USD) revert BelowMinimum();
        // 7. the budget: a bucket of one cap `C = L × accountValue`, refilled over 24 hours (spec §4.5)
        _spend(n, lev * uint256(av) / 100);
        // 5. a risk-raising action: one unsettled at a time (spec §4.4)
        _takeRiskWindow();
    }

    /// Takes `n` from the bucket of size `c` (spec §4.5): full on the first growth (`growAt == 0`), else
    /// `min(c, growLeft + c × elapsed / 24 h)`. Counted as sent, not as filled.
    function _spend(uint256 n, uint256 c) internal {
        uint256 left = growAt == 0 ? c : growLeft + c * (block.timestamp - growAt) / GROW_REFILL;
        if (left > c) left = c;
        if (n > left) revert GrowthBudget();
        left -= n;
        growLeft = left > type(uint64).max ? type(uint64).max : uint64(left);
        growAt = uint64(block.timestamp);
    }
}
