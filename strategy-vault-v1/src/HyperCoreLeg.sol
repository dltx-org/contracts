// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {MemberBase} from "./MemberBase.sol";
import {HyperCoreLegState} from "./HyperCoreLegState.sol";
import {HyperCoreLegExit} from "./HyperCoreLegExit.sol";
import {HyperCoreLegExitB} from "./HyperCoreLegExitB.sol";
import {HyperCoreLegRoute} from "./HyperCoreLegRoute.sol";
import {IDepositOwner} from "./interfaces/IDepositOwner.sol";
import {ICoreDepositWallet, IERC20} from "./interfaces/Protocols.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {Legs, OwnerMessages} from "./lib/VaultTypes.sol";
import {HyperCoreParams, MemberTypes, ParamsTypesV1, Routes} from "./Types.sol";

/*
 * VERSION 1 of the Hyperliquid leg (version 0's `ShortVault`, owner-upgradeable and profile-aware: its
 * perp, coin and asset id are its profile's, checked against HyperEVM's registry at creation, AP-3, AP-4).
 * Its exit module is split in two (`HyperCoreLegExit`, `HyperCoreLegExitB`); the execution key's `order`, on
 * both routes, is a third module's (`HyperCoreLegRoute`, hyperliquid-contract-route-design.md §4.3, §4.7),
 * which every selector the leg and the exit modules don't name reaches.
 * Version 0's text follows.
 *
 * The Hyperliquid leg on HyperEVM (spec §8.3, §8.4; amendment 2a, revision 1, §3.7: a leg like any other):
 * this contract IS the Hyperliquid account. Its HyperCore account is created by its first Circle deposit;
 * its agent (one per strategy, decision 8) trades it and cannot move money (Hyperliquid's rule); money
 * moves only through the functions below, and leaves HyperEVM only to the strategy's other members (in
 * exit, only to its hub).
 *
 * The exit (decisions 24, 28, 30; §8.4's table) lives in a fixed module, `ShortVaultExit` (amendment 2a
 * §3.8: the leg is over EIP-170 with it inline): its address and code hash are fixed in this code's
 * constructor (`VaultBase`), and only its nine functions (the exit's six, `receiveMint`, `report` and
 * `holdings`)
 * are dispatched to it, by DELEGATECALL, in this leg's storage.
 */
contract HyperCoreLeg is MemberBase, HyperCoreLegState {
    uint64 internal constant PRIME_MARGIN = 1_200_000; // 1.2 USDC of perp margin (1e6): above the fee + the send
    uint64 internal constant PRIME_SEND = 5_000_000; // 0.05 USDC, Core wei (8 dp)

    address public immutable exitModule;
    address public immutable exitModuleB;
    address public immutable routeModule;

    constructor(
        address exitModule_,
        bytes32 exitModuleCodeHash,
        address exitModuleB_,
        bytes32 exitModuleBCodeHash,
        address routeModule_,
        bytes32 routeModuleCodeHash,
        address upgradeModule_,
        bytes32 upgradeModuleCodeHash
    ) MemberBase(upgradeModule_, upgradeModuleCodeHash) {
        _checkModule(exitModule_, exitModuleCodeHash);
        _checkModule(exitModuleB_, exitModuleBCodeHash);
        _checkModule(routeModule_, routeModuleCodeHash);
        exitModule = exitModule_;
        exitModuleB = exitModuleB_;
        routeModule = routeModule_;
    }

    function MEMBER_TYPE() public pure override returns (uint8) {
        return MemberTypes.HYPERCORE;
    }

    /// The exit modules' functions: A's five (the agents' applies, in or out of the exit, and the
    /// quarantine's reads: size), B's nine (`validateParams` among them, for size). Any other selector goes
    /// to the route module (VaultUpgrade's are routed before this, in `MemberBase`'s fallback): its `order`
    /// (both routes, hyperliquid-contract-route-design.md §4.3: its bounds, for size), `cancelResting`,
    /// `closeStray` (§4.2), the builder fee's (§13.2), the referral setup's (§16) and the checks of the
    /// owner's `END_QUARANTINE` and `CONFIRM_SETUP` (`routeOwnerAction`, the leg's own call); its own fallback
    /// refuses the rest, `Unsupported`.
    /// A default, not a list, so a new route function costs the leg nothing (the leg keeps its 1,024 B
    /// margin, `test.mjs`).
    function _module(bytes4 s) internal view override returns (address) {
        if (
            s == HyperCoreLegExit.exitStep.selector || s == HyperCoreLegExit.bridgeOut.selector
                || s == HyperCoreLegExit.applyOwnerAgent.selector || s == HyperCoreLegExit.applyAgent.selector
                || s == HyperCoreLegExit.readsClean.selector
        ) return exitModule;
        if (
            s == HyperCoreLegExitB.ownerOrder.selector || s == HyperCoreLegExitB.proposeSweep.selector
                || s == HyperCoreLegExitB.sweepResidue.selector || s == HyperCoreLegExitB.exitStatus.selector
                || s == HyperCoreLegExitB.receiveMint.selector || s == HyperCoreLegExitB.report.selector
                || s == HyperCoreLegExitB.holdings.selector || s == HyperCoreLegExitB.checkProfile.selector
                || s == HyperCoreLegExitB.validateParams.selector
        ) return exitModuleB;
        return routeModule;
    }

    // ── the leg standard (amendment 2a §3.5) ─────────────────────────────────────────────────────────

    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind) {
        return (keccak256("dltx.leg.hypercore"), Legs.ROLE_LONG | Legs.ROLE_SHORT, Legs.VALUE_READ);
    }

    /// `ShortParams` as the owner signs it (amendment 2d §4.2): named by the leg type, which plays both roles.
    function paramsType() external pure returns (string memory) {
        return ParamsTypesV1.HYPERCORE;
    }


    /// The account's value for the fee budget, USDC units: DEX 0's account value (never below zero) +
    /// spot USDC + the USDC held on HyperEVM.
    function _value() internal view returns (uint256 v) {
        (, HyperCore.MarginSummary memory m) = HyperCore.marginSummary(0, address(this));
        if (m.accountValue > 0) v = uint256(uint64(m.accountValue));
        v += uint256(HyperCore.spotBalance(address(this), USDC_TOKEN).total) / 100 + IERC20(USDC).balanceOf(address(this));
    }

    /// The owner's bounds and the profile's short part, its perp checked again on HyperCore (AP-3):
    /// `validateParams` (module B, for size) checks both.
    function _initParams(bytes calldata params) internal override {
        HyperCoreLegExitB(address(this)).validateParams(registry, params);
        HyperCoreParams memory p = abi.decode(params, (HyperCoreParams));
        profile = p.profile;
        perp = p.perp;
        asset = p.asset;
        orderBoundBp = p.orderBoundBp;
        fastFeeCapBp = p.fastFeeCapBp;
        feeBudgetBp = p.feeBudgetBp;
        route = p.route;
        side = p.side;
        maxLeverageX100 = p.maxLeverageX100;
        growBoundBp = p.growBoundBp;
        reduceBoundBp = p.reduceBoundBp;
        builder = p.builder;
        builderFeeX10 = p.builderFeeX10;
        referralSetup = p.referralSetup;
        // `quarantine` false and `growAt` 0 (the bucket full on first use, §4.5): their defaults
    }

    /// The key never spends money from outside the strategy that waits to be forwarded (finding 5).
    function _keepOthers(uint256 amount) internal view {
        if (amount + othersPending > IERC20(USDC).balanceOf(address(this))) revert NotAllowed();
    }

    /// HYPE from HyperCore only.
    receive() external payable {
        if (msg.sender != HYPE_SYSTEM) revert NotAllowed();
    }

    // ── the execution key (§8.4) ─────────────────────────────────────────────────────────────────────

    /// Circle's `deposit(amount, 0)`: USDC into this account's own perp margin (creates the account).
    /// Never while the referral setup holds money (spec §16): its agent standing, or, after it, until the
    /// owner's `CONFIRM_SETUP`. Before the setup runs, every amount is counted (`setupIn`: one sent in the
    /// setup's own block is not yet in HyperCore's reads), and past $5 of it the setup is refused.
    function toMargin(uint256 amount) external onlyExecution nonReentrant counted {
        if (_setupHolds()) revert SetupRefused();
        _keepOthers(amount);
        if (!setupDone) {
            // `_keepOthers`: at most the leg's USDC, so the cast cannot truncate in practice. Checked: a sum past
            // 2^64 units (1.8e13 USDC) reverts rather than wrapping under $5 (the setup's in-flight bypass)
            setupIn += uint64(amount);
        }
        IERC20(USDC).approve(CORE_DEPOSIT_WALLET, amount);
        ICoreDepositWallet(CORE_DEPOSIT_WALLET).deposit(amount, 0);
        lastCoreMove = uint64(block.number);
    }

    /// Perp margin → spot (CoreWriter 7), then spot → this contract on HyperEVM (CoreWriter 13).
    /// `amount` in USDC's 6 decimals. Needs HYPE on spot for the second (§5).
    ///
    /// On the contract route (hyperliquid-contract-route-design.md §4.4) 7 moves only `debit`, what spot's
    /// available USDC lacks (a retry after a 13 dropped for lack of HYPE takes nothing twice), under the cap
    /// after it at the mark AND at the oracle, one unsettled risk-raising action at a time. `debit` 0 sends
    /// 13 alone, spot to the leg itself, no margin out: no cap, no window, so stranded money always comes
    /// back. Never in quarantine, where spot may be collateral (§4.6).
    function fromMargin(uint64 amount) external onlyExecution nonReentrant counted {
        uint64 debit = amount;
        if (route == Routes.CONTRACT) {
            if (quarantine) revert Quarantined();
            uint64 spot = HyperCore.spotAvailable(address(this), USDC_TOKEN) / 100;
            debit = amount > spot ? amount - spot : 0;
            if (debit != 0) {
                _releaseCap(debit);
                _takeRiskWindow();
            }
        }
        if (debit != 0) HyperCore.usdClassTransfer(debit, false);
        HyperCore.sendAsset(USDC_SYSTEM, HyperCore.SPOT_DEX, HyperCore.SPOT_DEX, USDC_TOKEN, amount * 100);
        lastCoreMove = uint64(block.number);
    }

    /// `fromMargin`'s cap (spec §4.4), `debit` out of perp margin: `ntlPos ≤ L × (accountValue − debit)` at
    /// the mark (every DEX 0 position), and `|szi| × O ≤ L × (E_O − debit)` at the oracle, the equity
    /// re-valued there (`E_O = accountValue + szi × (O − M)`), so a depressed mark can't make room.
    function _releaseCap(uint64 debit) internal view {
        uint32 p = perp;
        (bool ok, HyperCore.MarginSummary memory ms) = HyperCore.marginSummary(0, address(this));
        if (!ok) revert HyperCore.PrecompileFailed(HyperCore.PX_MARGIN_SUMMARY);
        int256 szi = HyperCore.position(address(this), p).szi;
        uint64 m = HyperCore.markPx(p);
        uint64 o = HyperCore.oraclePx(p);
        if (m == 0 || o == 0) revert HyperCore.PrecompileFailed(m == 0 ? HyperCore.PX_MARK : HyperCore.PX_ORACLE);
        uint256 lev = maxLeverageX100;
        int256 left = int256(ms.accountValue) - int256(uint256(debit));
        _cap(ms.ntlPos, left, lev);
        _cap(uint256(szi < 0 ? -szi : szi) * o, left + szi * (int256(uint256(o)) - int256(uint256(m))), lev);
    }

    /// Pays the account's first outgoing USDC transfer fee (~1 USDC, in USDC, §5), which `fromMargin`
    /// can't on a fresh account (spot then holds only its amount, and the send is dropped silently):
    /// 1.2 USDC of perp margin → spot (CoreWriter 7), then 0.05 USDC spot → this contract on HyperEVM
    /// (CoreWriter 13), so amount and fee fit. Needs HYPE on spot. In unified mode the first action may
    /// do nothing; spot is the whole balance there. Twice is harmless: the money stays in the account.
    /// On the contract route (spec §4.2, §4.4) only while DEX 0 is flat (`ntlPos` 0), never in quarantine,
    /// and one unsettled risk-raising action: unbounded, its 1.2 USDC each time would lever the account.
    function prime() external onlyExecution nonReentrant counted {
        if (route == Routes.CONTRACT) {
            if (quarantine) revert Quarantined();
            (bool ok, HyperCore.MarginSummary memory ms) = HyperCore.marginSummary(0, address(this));
            if (!ok) revert HyperCore.PrecompileFailed(HyperCore.PX_MARGIN_SUMMARY);
            if (ms.ntlPos != 0) revert NotFlat();
            _takeRiskWindow();
        }
        HyperCore.usdClassTransfer(PRIME_MARGIN, false);
        HyperCore.sendAsset(USDC_SYSTEM, HyperCore.SPOT_DEX, HyperCore.SPOT_DEX, USDC_TOKEN, PRIME_SEND);
        lastCoreMove = uint64(block.number);
    }

    /// HyperEVM HYPE (this vault's, or brought with the call) to its HyperCore spot. The execution key;
    /// in exit, anyone (decision 24). Never while the referral setup holds money (spec §16): its agent, or
    /// a spot TWAP it left before the owner's `CONFIRM_SETUP`, could trade it (the confirm sends nothing, so
    /// needs no HYPE). Never refused in the exit, which may need HYPE to send the money home.
    function topUpHype(uint256 amount) external payable nonReentrant counted {
        if (!exiting) _checkExecution();
        if (!exiting && _setupHolds()) revert SetupRefused();
        (bool ok,) = HYPE_SYSTEM.call{value: amount}("");
        if (!ok) revert NotAllowed();
    }

    /// USDC to member `k` of the strategy (its hub or a sister leg), once it is ready (§3.6); Circle's
    /// fee charged to its 24-hour fee budget, a share of the account's value (invariant 6).
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external onlyExecution nonReentrant {
        _keepOthers(amount);
        uint256 value = _value();
        uint256 fee = _send(k, amount, fast, maxFee, fastFeeCapBp);
        _chargeFee(fee, value, feeBudgetBp);
    }

    function cancel(uint32 asset, bool byCloid, uint128 id) external onlyExecution nonReentrant counted {
        _cancel(Cancel(asset, byCloid, id));
    }

    /// Effective after 24 hours unless the owner cancels; the vault's FIRST agent applies at once. Never on
    /// the contract route: there the only way to an agent is the owner's, after 24 hours (spec §4.6).
    function proposeAgent(address next) external onlyExecution {
        if (route == Routes.CONTRACT) revert NotAllowed();
        if (next == address(0)) revert NoAgent();
        pendingAgent = next;
        pendingAgentAt = uint64(block.timestamp);
        emit AgentProposed(next, agentEverSet ? block.timestamp + AGENT_DELAY : block.timestamp);
    }


    // ── the owner (§8.4, decision 34): `replaceAgent`, `cancelAgent` ─────────────────────────────────

    /// `replaceAgent` with the burner cuts trading off at once and drops every pending choice, the
    /// owner's included (CR-D3); any other agent takes effect after 24 hours (`applyOwnerAgent`), in exit
    /// too, cancellable by any owner credential (`cancelAgent`), so a stolen credential can't hand the
    /// account to an agent of its own at once, and only while the credential that chose it still stands
    /// (the partner's audit M2): removing a stolen credential voids its pending choice. `cancelAgent`
    /// drops both DLTX's proposal and the owner's pending choice; each credential signs its own nonce, so
    /// no other can starve it (CR-E1). `RELEASE_RESERVATION` frees the budget mode's reservation
    /// (sends from spot never seen to arrive) on the owner's word that none will still execute (M4).
    ///
    /// The route (hyperliquid-contract-route-design.md §4.6): `USE_CONTRACT` moves the agent route to
    /// the contract route at once, its agent replaced by a fresh burner, in quarantine; on the contract
    /// route it cancels any pending choice (a switch back included), the route unchanged, and cuts a
    /// standing referral setup agent at once (a fresh burner, as `endSetup`). On the contract
    /// route `REPLACE_AGENT(BURNER)` is the owner's retry (a fresh burner, the quarantine's hour from now)
    /// and `REPLACE_AGENT(agent)` the switch back, applied by `applyOwnerAgent` after 24 hours.
    /// `END_QUARANTINE` (§5.3) ends it on the owner's own reading of Hyperliquid's API, bound to the
    /// burner the owner saw approved, an hour after it went in, and only if the leg's reads agree.
    /// `CONFIRM_SETUP` (§16) releases money and growth after the referral setup, once: on the contract route,
    /// the setup ended, bound to the burner the owner saw approved, and only if the leg's reads agree.
    function _agentAction(uint8 action, address next, bytes32 credential) internal override {
        if (action == OwnerMessages.USE_CONTRACT) {
            if (route == Routes.CONTRACT) {
                if (setupOpen) _useAgent(BURNER); // a standing setup agent cut at once (spec §16)
                action = OwnerMessages.CANCEL_AGENT; // below: drops both pending choices
            } else {
                route = Routes.CONTRACT;
                quarantine = true;
                _revokeBuilder(); // the route's orders carry no builder (spec §13.2); the signed rate stays
                emit RouteChanged(Routes.CONTRACT);
                action = OwnerMessages.REPLACE_AGENT;
                next = BURNER;
            }
        }
        if (action == OwnerMessages.REPLACE_AGENT) {
            if (next == address(0)) revert NoAgent();
            pendingAgent = address(0);
            if (next == BURNER) {
                ownerAgent = address(0);
                _useAgent(BURNER);
            } else {
                ownerAgent = next;
                ownerAgentAt = uint64(block.timestamp);
                ownerAgentBy = credential;
                emit AgentProposed(next, block.timestamp + AGENT_DELAY);
            }
        } else if (action == OwnerMessages.CANCEL_AGENT) {
            pendingAgent = address(0);
            ownerAgent = address(0);
            emit AgentCancelled();
        } else if (action == OwnerMessages.RELEASE_RESERVATION) {
            reserved = 0;
        } else {
            // `END_QUARANTINE`, `CONFIRM_SETUP` and the refusal of any other: the route module's, for size
            HyperCoreLegRoute(address(this)).routeOwnerAction(action, next);
        }
    }

    function _onRevoke() internal override {
        pendingAgent = address(0);
    }

    /// Entering the exit: DLTX's pending proposal cancelled, the agent replaced at once by a fresh burner
    /// (an address nobody holds a key for); the owner may later name their own with `replaceAgent`. The
    /// builder fee ends: its approval revoked, its rate 0, any pending raise or builder change dropped.
    function _onExit() internal override {
        _revokeBuilder(); // the exit's orders pay no builder (spec §13.2): revoked, 0, nothing pending
        builderFeeX10 = 0;
        _dropPendingBuilder();
        pendingAgent = address(0);
        ownerAgent = address(0); // a choice made before the exit is not applied in it (CR-D3)
        _useAgent(BURNER); // `exiting` is already set: the exit's agent
        lastSent[_key(K_AGENT, 0, 0)] = block.number;
    }

}
