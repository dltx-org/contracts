// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {IERC20, IMessageTransmitterV2} from "./interfaces/Protocols.sol";
import {Legs, OwnerMessages} from "./lib/VaultTypes.sol";
import {IRegistryV1} from "./Interfaces.sol";
import {ILinkV1, MemberState} from "./MemberState.sol";
import {MemberTypes, OwnerMessagesV1} from "./Types.sol";
import {VaultUpgrade} from "./VaultUpgrade.sol";

/*
 * What every version-1 member shares: version 0's `VaultBase` (the fixed links, the owner's signed
 * actions, the execution key's gate, pause, readiness, money between members counted per pair, reports,
 * the exit state's entry and its telling, decision 27), and the owner-upgradeable frame
 * (owner-upgrades-design.md §A1, §A2, §C1–§C4):
 * - a member is the shared ERC-1967 PROXY (`ProxyInitCode`), made by the combination factory with
 *   CREATE2, its address independent of any code; this contract is an IMPLEMENTATION behind it;
 * - its upgrade path is the shared `VaultUpgrade` module (its address and code hash immutables here),
 *   reached by this fallback as the member type's own modules are; nothing else writes the slot;
 * - the implementation itself can never be initialised (`factory == address(1)` in its own storage), and
 *   every module function refuses a call outside an initialised instance (`delegated`).
 *
 * A member's links live in storage, written once by `initialize` from its combination factory in the
 * transaction that creates it. No setter exists for any of them (invariant 9, V7).
 */
abstract contract MemberBase is MemberState {
    /// Every version-1 implementation's number (owner-upgrades-design.md §A3): the registry lists it as
    /// version 1 only, and a member asks `stopped(group, CODE_VERSION())` for its escape hatch.
    function CODE_VERSION() public pure virtual returns (uint32) {
        return 1;
    }

    /// The shared upgrade module (§C3), its code hash checked here.
    address public immutable upgradeModule;
    // Version 1's implementations name no registry: they are the registry's genesis, constructor data of
    // the registry deployed after them (owner-upgrades-design.md §A3). An instance reads its own
    // `registry`, written by its factory; `validateParams` is given the factory's. A later version's
    // implementations name their listing registry (`listingRegistry()`, §A9), which a proposal requires.

    error BadModule();

    constructor(address upgradeModule_, bytes32 upgradeModuleCodeHash) {
        _checkModule(upgradeModule_, upgradeModuleCodeHash);
        upgradeModule = upgradeModule_;
    }

    /// A module's code hash as pinned, never empty.
    function _checkModule(address m, bytes32 h) internal view {
        if (h == bytes32(0) || h == keccak256("") || m.codehash != h) revert BadModule();
    }

    /// This implementation's member type (`MemberTypes`).
    function MEMBER_TYPE() public pure virtual returns (uint8);

    /// The upgrade module's selectors and the member type's own modules' (`_module`), and nothing else,
    /// run in this member's storage.
    fallback() external {
        bytes4 s = msg.sig;
        address m = s == VaultUpgrade.scheduleUpgrade.selector || s == VaultUpgrade.cancelPendingAction.selector
            || s == VaultUpgrade.applyUpgrade.selector || s == VaultUpgrade.publishUpgrade.selector
            || s == VaultUpgrade.followUpgrade.selector || s == VaultUpgrade.followMessage.selector
            || s == VaultUpgrade.pendingAction.selector ? upgradeModule : _module(s);
        if (m == address(0)) revert Unsupported();
        _delegate(m);
    }

    function _delegate(address m) internal {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            let ok := delegatecall(gas(), m, p, calldatasize(), 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }

    /// The module that runs selector `s` here, or zero.
    function _module(bytes4 s) internal view virtual returns (address);

    // ── creation ─────────────────────────────────────────────────────────────────────────────────────

    /// The combination factory, once, in the transaction that creates the proxy (`IMemberV1.initialize`).
    /// Every member on another chain is sent this member's READY at once.
    function initialize(
        address owner_,
        address registry_,
        address[] calldata links_,
        uint32[] calldata domains_,
        uint8 group_,
        bytes32 strategyId_,
        bytes32 configHash_,
        bytes calldata params
    ) external {
        if (factory != address(0)) revert AlreadyInitialized();
        uint256 n = links_.length;
        if (n == 0 || n > Legs.MAX_LINKS || domains_.length != n) revert BadLinks();
        factory = msg.sender;
        memberType = MEMBER_TYPE();
        codeVersion = CODE_VERSION();
        createdAt = uint64(block.timestamp);
        owner = owner_;
        registry = registry_;
        group = group_;
        strategyId = strategyId_;
        configHash = configHash_;
        linkCount = uint8(n);
        uint32 here = IMessageTransmitterV2(MESSAGE_TRANSMITTER).localDomain();
        uint8 local;
        for (uint256 k; k < n; ++k) {
            if (links_[k] == address(0)) revert BadLinks();
            links[k] = links_[k];
            linkDomains[k] = domains_[k];
            if (domains_[k] == here) local |= uint8(1 << k);
        }
        localLinks = local;
        _initParams(params);
        emit Initialized(owner_, group_, strategyId_, configHash_);
        for (uint256 k; k < n; ++k) {
            if (local & (1 << k) == 0) _sendReady(uint8(k), true);
        }
    }

    function _initParams(bytes calldata params) internal virtual;

    // ── readiness (§3.6, decision 40) ──────────────────────────────────────────────────────────────────

    /// Anyone, in any state: resends this member's READY to member `k` on another chain. Reverts as
    /// Circle does.
    function announceReady(uint8 k) external {
        if (k >= linkCount || _isLocal(k)) revert NotAllowed();
        _sendReady(k, false);
    }

    /// Whether member `k` has announced itself: its finalized READY arrived, or, on this chain, its code
    /// is there. The execution key sends a member money only then (invariant 2).
    function ready(uint8 k) external view returns (bool) {
        return _ready(k);
    }

    /// A READY Circle refused (paused) is `ReadyPending`: nothing went, `announceReady` resends it.
    function _sendReady(uint8 k, bool soft) internal {
        if (_message(k, abi.encode(READY_MESSAGE), FINALITY_STANDARD, soft)) emit ReadySent(k);
        else emit ReadyPending(k);
    }

    /// A member on this chain, in every state: pulls `amount` of USDC it allowed and counts it.
    function receiveLocal(uint256 amount) external nonReentrant {
        uint8 k = _linkOf(msg.sender);
        if (!_isLocal(k)) revert BadMessage();
        receivedFrom[k] += amount;
        IERC20(_usdc()).transferFrom(msg.sender, address(this), amount);
        _onCredit(amount);
        emit ReceivedFromLink(k, amount, 0);
    }

    // ── the execution key's pause (§8.4) ─────────────────────────────────────────────────────────────────

    /// Blocks the long leg's `supply` and `borrow` only (`whenNotPaused`); never protection, money between
    /// members, payout or the exit. The Hyperliquid agent trades off-chain: revoking DLTX and replacing the
    /// agent are the brake there.
    function pause(bool on) external onlyExecution {
        paused = on;
        emit Paused(on);
    }

    // ── the owner's local actions (§7.2: this member, this chain, its nonce, an expiry) ──────────────────

    /// `revokeExecution`, `allowExecution` and the member type's own actions (the Hyperliquid leg's
    /// `replaceAgent` and `cancelAgent`), each signed by one owner credential, named as `credential` and
    /// signing that credential's own nonce (`ownerNonceOf`): no other credential can spend it, so none can
    /// starve another's action, a cancel included (the combined review's CR-E1). Anyone may submit.
    function ownerAction(uint8 action, address agent, bytes32 credential, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        _checkOwnerAs(
            credential,
            keccak256(
                abi.encode(
                    OwnerMessages.VAULT_ACTION_TYPEHASH,
                    address(this),
                    block.chainid,
                    action,
                    agent,
                    ownerNonceOf[credential],
                    deadline
                )
            ),
            deadline,
            signature
        );
        if (action == OwnerMessages.REVOKE_EXECUTION || action == OwnerMessages.ALLOW_EXECUTION) {
            executionRevoked = action == OwnerMessages.REVOKE_EXECUTION;
            if (executionRevoked) _onRevoke();
            emit ExecutionRevoked(executionRevoked);
        } else {
            _agentAction(action, agent, credential);
        }
    }

    function _agentAction(uint8, address, bytes32) internal virtual {
        revert Unsupported();
    }

    /// Revoking DLTX also drops what DLTX had pending (the Hyperliquid leg's agent proposal).
    function _onRevoke() internal virtual {}

    // ── the exit state's entry (§8.4, decisions 20, 23, 27; invariant 5) ─────────────────────────────────

    /// The owner's `BeginExit(strategyId, deadline)`: no nonce, valid on every member, harmless to replay.
    function beginExit(uint256 deadline, bytes calldata signature) external nonReentrant {
        _checkOwner(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, strategyId, deadline)), deadline, signature);
        _enterExit(1, true);
    }

    /// Anyone, once the member's group has not checked in for 7 days (the escape hatch, decision 17).
    function beginExitStopped() external nonReentrant {
        if (!IRegistryV1(registry).stopped(group, CODE_VERSION())) revert GroupNotStopped();
        _enterExit(2, true);
    }

    /// Anyone: tells member `k`, while this member entered by itself and `k` is not yet told. Reverts as
    /// Circle (or the member) does: retried until it succeeds.
    function notifyLink(uint8 k) external nonReentrant {
        if (!exiting || toldPending & (1 << k) == 0) revert NotAllowed();
        _tell(k, false);
        toldPending &= ~uint8(1 << k);
        emit LinkTold(k);
    }

    /// A member on this chain entering its exit tells this one directly. A member already in exit
    /// returns before taking its lock; one told tells nobody (invariant 5).
    function legExit() external {
        uint8 k = _linkOf(msg.sender);
        if (!_isLocal(k)) revert BadMessage();
        toldPending &= ~uint8(1 << k); // that member is in exit: nothing left to tell it
        if (exiting) return;
        _enterExitLocked(3);
    }

    /// Circle's MessageTransmitterV2 delivers a member's message (CCTP V2's handler interface). `READY`
    /// and reports only finalized; `EXIT` at any finality: entering exit is one-way and only ever safer.
    function handleReceiveFinalizedMessage(uint32 sourceDomain, bytes32 sender, uint32 finality, bytes calldata body)
        external
        returns (bool)
    {
        _receive(sourceDomain, sender, finality, body);
        return true;
    }

    function handleReceiveUnfinalizedMessage(uint32 sourceDomain, bytes32 sender, uint32, bytes calldata body)
        external
        returns (bool)
    {
        _receive(sourceDomain, sender, 0, body);
        return true;
    }

    function _receive(uint32 sourceDomain, bytes32 sender, uint32 finality, bytes calldata body) internal {
        if (msg.sender != MESSAGE_TRANSMITTER || body.length < 32 || uint256(sender) >> 160 != 0) {
            revert BadMessage();
        }
        uint8 k = _linkOf(address(uint160(uint256(sender))));
        if (_isLocal(k) || linkDomains[k] != sourceDomain) revert BadMessage();
        bytes32 tag = bytes32(body[0:32]);
        if (tag == READY_MESSAGE && body.length == 32) {
            if (finality < FINALITY_STANDARD) revert BadMessage();
            readyLinks |= uint8(1 << k);
            emit LinkReady(k);
        } else if (tag == EXIT_MESSAGE && body.length == 32) {
            toldPending &= ~uint8(1 << k); // that member is in exit: nothing left to tell it
            if (exiting) return;
            _enterExitLocked(3);
        } else if (tag == REPORT_MESSAGE) {
            if (finality < FINALITY_STANDARD) revert BadMessage();
            _onReport(k, body);
        } else if (tag == UPGRADE_MESSAGE && body.length == 96) {
            // from the strategy's hub only (a leg's link 0), finalized (§C4): the upgrade module follows
            if (finality < FINALITY_STANDARD || k != 0 || memberType == MemberTypes.HUB) revert BadMessage();
            (, bytes32 manifest, uint256 publishedAt) = abi.decode(body, (bytes32, bytes32, uint256));
            (bool ok, bytes memory ret) =
                upgradeModule.delegatecall(abi.encodeCall(VaultUpgrade.followMessage, (manifest, publishedAt)));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        } else {
            revert BadMessage();
        }
    }

    /// The hub stores a leg's report; any other member refuses one.
    function _onReport(uint8, bytes calldata) internal virtual {
        revert BadMessage();
    }

    function _enterExitLocked(uint8 by) internal nonReentrant {
        _enterExit(by, false);
    }

    /// Commits the local exit first; then, if this member entered by itself (the owner, the stopped
    /// group), tells every other member once, each try's failure changing nothing local (decision 27).
    /// A member told by another member tells nobody (invariant 5).
    function _enterExit(uint8 by, bool tellOthers) internal {
        if (exiting) return;
        exiting = true;
        exitStartedAt = uint64(block.timestamp);
        // a pending profile switch can no longer apply: cleared, so it never holds the only slot (§C3)
        if (_pending.kind == OwnerMessagesV1.KIND_SWITCH) _clear(3);
        emit ExitBegun(by);
        _onExit();
        if (!tellOthers) return;
        uint8 n = linkCount;
        for (uint8 k; k < n; ++k) {
            if (_tell(k, true)) {
                emit LinkTold(k);
            } else {
                toldPending |= uint8(1 << k);
                emit LinkToldPending(k);
            }
        }
    }

    /// Tells member `k` of the exit: a plain `legExit()` on this chain (the member is this strategy's own
    /// code: it fails only short of gas, and then so does this call); a Circle message across chains.
    function _tell(uint8 k, bool soft) internal returns (bool) {
        if (_isLocal(k)) {
            address link = links[k];
            if (link.code.length == 0) {
                if (soft) return false;
                revert NotReady();
            }
            ILinkV1(link).legExit();
            return true;
        }
        return _message(k, abi.encode(EXIT_MESSAGE), FINALITY_FAST, soft);
    }

    /// Role-specific effects of entering (the Hyperliquid leg replaces its agent).
    function _onExit() internal virtual;
}

