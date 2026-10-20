// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {VaultBase} from "./VaultBase.sol";
import {ShortVaultState} from "./ShortVaultState.sol";
import {ShortVaultExit} from "./ShortVaultExit.sol";
import {IDepositOwner} from "./interfaces/IDepositOwner.sol";
import {ICoreDepositWallet, IERC20} from "./interfaces/Protocols.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {Assets, Holding, Legs, OwnerMessages, ParamsTypes, ShortParams} from "./lib/VaultTypes.sol";

/*
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
contract ShortVault is VaultBase, ShortVaultState {
    uint16 internal constant MIN_BOUND_BP = 30;
    uint16 internal constant MAX_ORDER_BOUND_BP = 1000;
    uint16 internal constant MAX_FAST_FEE_CAP_BP = 50;
    uint16 internal constant MAX_FEE_BUDGET_BP = 500;
    uint64 internal constant PRIME_MARGIN = 1_200_000; // 1.2 USDC of perp margin (1e6): above the fee + the send
    uint64 internal constant PRIME_SEND = 5_000_000; // 0.05 USDC, Core wei (8 dp)

    error BadParams();

    constructor(address exitModule_, bytes32 exitModuleCodeHash) VaultBase(exitModule_, exitModuleCodeHash) {}

    /// The exit module's nine functions.
    function _exitSelector(bytes4 s) internal pure override returns (bool) {
        return s == ShortVaultExit.exitStep.selector || s == ShortVaultExit.bridgeOut.selector
            || s == ShortVaultExit.ownerOrder.selector || s == ShortVaultExit.proposeSweep.selector
            || s == ShortVaultExit.sweepResidue.selector || s == ShortVaultExit.exitStatus.selector
            || s == ShortVaultExit.receiveMint.selector || s == ShortVaultExit.report.selector
            || s == ShortVaultExit.holdings.selector;
    }

    // ── the leg standard (amendment 2a §3.5) ─────────────────────────────────────────────────────────

    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind) {
        return (keccak256("dltx.leg.hypercore.v1"), Legs.ROLE_LONG | Legs.ROLE_SHORT, Legs.VALUE_READ);
    }

    /// `ShortParams` as the owner signs it (amendment 2d §4.2): named by the leg type, which plays both roles.
    function paramsType() external pure returns (string memory) {
        return ParamsTypes.HYPERCORE;
    }


    /// The account's value for the fee budget, USDC units: DEX 0's account value (never below zero) +
    /// spot USDC + the USDC held on HyperEVM.
    function _value() internal view returns (uint256 v) {
        (, HyperCore.MarginSummary memory m) = HyperCore.marginSummary(0, address(this));
        if (m.accountValue > 0) v = uint256(uint64(m.accountValue));
        v += uint256(HyperCore.spotBalance(address(this), USDC_TOKEN).total) / 100 + IERC20(USDC).balanceOf(address(this));
    }

    /// A DEX 0 perp and sane bounds; anything else reverts.
    function validateParams(bytes calldata params) external pure {
        ShortParams memory p = abi.decode(params, (ShortParams));
        if (
            p.perp >= SPOT_ASSET_OFFSET || p.asset == bytes32(0) || p.asset == Assets.USD || p.orderBoundBp < MIN_BOUND_BP
                || p.orderBoundBp > MAX_ORDER_BOUND_BP || p.fastFeeCapBp > MAX_FAST_FEE_CAP_BP || p.feeBudgetBp == 0
                || p.feeBudgetBp > MAX_FEE_BUDGET_BP
        ) revert BadParams();
    }

    function _initParams(bytes calldata params) internal override {
        ShortParams memory p = abi.decode(params, (ShortParams));
        perp = p.perp;
        asset = p.asset;
        orderBoundBp = p.orderBoundBp;
        fastFeeCapBp = p.fastFeeCapBp;
        feeBudgetBp = p.feeBudgetBp;
    }

    /// HYPE from HyperCore only.
    receive() external payable {
        if (msg.sender != HYPE_SYSTEM) revert NotAllowed();
    }

    // ── the execution key (§8.4) ─────────────────────────────────────────────────────────────────────

    /// Circle's `deposit(amount, 0)`: USDC into this account's own perp margin (creates the account).
    function toMargin(uint256 amount) external onlyExecution nonReentrant counted {
        IERC20(USDC).approve(CORE_DEPOSIT_WALLET, amount);
        ICoreDepositWallet(CORE_DEPOSIT_WALLET).deposit(amount, 0);
        lastCoreMove = uint64(block.number);
    }

    /// Perp margin → spot (CoreWriter 7), then spot → this contract on HyperEVM (CoreWriter 13).
    /// `amount` in USDC's 6 decimals. Needs HYPE on spot for the second (§5).
    function fromMargin(uint64 amount) external onlyExecution nonReentrant counted {
        HyperCore.usdClassTransfer(amount, false);
        HyperCore.sendAsset(USDC_SYSTEM, HyperCore.SPOT_DEX, HyperCore.SPOT_DEX, USDC_TOKEN, amount * 100);
        lastCoreMove = uint64(block.number);
    }

    /// Pays the account's first outgoing USDC transfer fee (~1 USDC, in USDC, §5), which `fromMargin`
    /// can't on a fresh account (spot then holds only its amount, and the send is dropped silently):
    /// 1.2 USDC of perp margin → spot (CoreWriter 7), then 0.05 USDC spot → this contract on HyperEVM
    /// (CoreWriter 13), so amount and fee fit. Needs HYPE on spot. In unified mode the first action may
    /// do nothing; spot is the whole balance there. Twice is harmless: the money stays in the account.
    function prime() external onlyExecution nonReentrant counted {
        HyperCore.usdClassTransfer(PRIME_MARGIN, false);
        HyperCore.sendAsset(USDC_SYSTEM, HyperCore.SPOT_DEX, HyperCore.SPOT_DEX, USDC_TOKEN, PRIME_SEND);
        lastCoreMove = uint64(block.number);
    }

    /// HyperEVM HYPE (this vault's, or brought with the call) to its HyperCore spot. The execution key;
    /// in exit, anyone (decision 24).
    function topUpHype(uint256 amount) external payable nonReentrant counted {
        if (!exiting) _checkExecution();
        (bool ok,) = HYPE_SYSTEM.call{value: amount}("");
        if (!ok) revert NotAllowed();
    }

    /// USDC to member `k` of the strategy (its hub or a sister leg), once it is ready (§3.6); Circle's
    /// fee charged to its 24-hour fee budget, a share of the account's value (invariant 6).
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external onlyExecution nonReentrant {
        uint256 value = _value();
        uint256 fee = _send(k, amount, fast, maxFee, fastFeeCapBp);
        _chargeFee(fee, value, feeBudgetBp);
    }

    /// The vault's own order on the strategy's perp (decision 4): IOC, at Hyperliquid's oracle ± the
    /// bound, and REDUCE-ONLY (decision 33): growing the hedge goes through the agent only.
    function order(bool isBuy, uint64 sz, bool reduceOnly) external onlyExecution nonReentrant counted {
        if (!reduceOnly) revert NotAllowed();
        uint8 szd = HyperCore.perpSzDecimals(perp);
        HyperCore.orderIoc(perp, isBuy, _perpLimit(perp, szd, isBuy), sz, reduceOnly);
    }

    function cancel(uint32 asset, bool byCloid, uint128 id) external onlyExecution nonReentrant counted {
        _cancel(Cancel(asset, byCloid, id));
    }

    /// Effective after 24 hours unless the owner cancels; the vault's FIRST agent applies at once.
    function proposeAgent(address next) external onlyExecution {
        if (next == address(0)) revert NoAgent();
        pendingAgent = next;
        pendingAgentAt = uint64(block.timestamp);
        emit AgentProposed(next, agentEverSet ? block.timestamp + AGENT_DELAY : block.timestamp);
    }

    /// CoreWriter 9 under the fixed name: the new agent replaces the old one (§5).
    function applyAgent() external onlyExecution nonReentrant {
        address next = pendingAgent;
        if (next == address(0)) revert NoAgent();
        if (agentEverSet && block.timestamp < uint256(pendingAgentAt) + AGENT_DELAY) revert TooEarly();
        if (!HyperCore.coreUserExists(address(this))) revert NoCoreAccount();
        pendingAgent = address(0);
        _setAgent(next);
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
    function _agentAction(uint8 action, address next, bytes32 credential) internal override {
        if (action == OwnerMessages.REPLACE_AGENT) {
            if (next == address(0)) revert NoAgent();
            pendingAgent = address(0);
            if (next == burner()) {
                ownerAgent = address(0);
                _useAgent(next);
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
            revert Unsupported();
        }
    }

    /// Anyone, once the owner's choice has stood 24 hours and while the credential that chose it is still
    /// one in this chain's record (M2).
    function applyOwnerAgent() external nonReentrant {
        address next = ownerAgent;
        if (next == address(0)) revert NoAgent();
        if (block.timestamp < uint256(ownerAgentAt) + AGENT_DELAY) revert TooEarly();
        if (!IDepositOwner(owner).isCredentialId(ownerAgentBy)) revert NotAllowed();
        ownerAgent = address(0);
        _useAgent(next);
    }

    /// The vault's burner agent: an address derived from the vault, whose key nobody holds.
    function burner() public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("dltx.strategy-vault.burner", address(this))))));
    }

    function _onRevoke() internal override {
        pendingAgent = address(0);
    }

    /// Entering the exit: DLTX's pending proposal cancelled, the agent replaced at once by a burner
    /// (an address nobody holds a key for); the owner may later name their own with `replaceAgent`.
    function _onExit() internal override {
        pendingAgent = address(0);
        ownerAgent = address(0); // a choice made before the exit is not applied in it (CR-D3)
        address b = burner();
        exitAgent = b;
        _setAgent(b);
        lastSent[_key(K_AGENT, 0, 0)] = block.number;
    }

}
