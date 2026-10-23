// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {IDepositOwner, OwnerDomain} from "./interfaces/IDepositOwner.sol";
import {IERC20, IMessageTransmitterV2, ITokenMessengerV2} from "./interfaces/Protocols.sol";
import {Holding} from "./lib/VaultTypes.sol";
import {IOwnerRemovals, IRegistryV1} from "./Interfaces.sol";

/// What a member calls on another member of the same chain.
interface ILinkV1 {
    function legExit() external;
    function receiveLocal(uint256 amount) external;
    function receiveReport(bytes calldata body) external;
    function followUpgrade(bytes32 manifest) external;
    function followSwitch(bytes32 toProfile) external;
}

/*
 * VERSION 1 of a member's STORAGE, events, errors and the internals its modules may need (version 0's
 * `VaultState`, `src/VaultBase.sol`, made owner-upgradeable: owner-upgrades-design.md Part C,
 * asset-profiles-design.md §3.8): the base of `MemberBase`, and alone the base of a module, which runs by
 * DELEGATECALL in a member's storage and so must share its layout. `MemberBase` declares no storage.
 *
 * ONE APPEND-ONLY LAYOUT (owner-upgrades-design.md §A6, Q7): version 0's fields in their order, then the
 * upgrade state (§C3), then each member type's own fields. A later version only appends; `test.mjs`
 * compares every module's layout to its member's, the shared `VaultUpgrade`'s as a prefix, and each
 * member's to its pinned layout file (`layouts/`). The only foreign slot is ERC-1967's, a hash.
 *
 * A strategy's members are its hub (index 0) and 2 to 4 legs. Every member knows every other: a leg's
 * link 0 is its hub, then its sister legs; a hub's links are its legs.
 */
abstract contract MemberState {
    // ── Circle CCTP V2, the same addresses on every chain a member lives on (§6) ──────────────────────
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint32 internal constant FINALITY_FAST = 1000; // "confirmed": the fast transfer, with a fee
    uint32 internal constant FINALITY_STANDARD = 2000; // "finalized": no fee
    /// The messages between members: a tag first, from a member's address and domain only.
    bytes32 public constant EXIT_MESSAGE = keccak256("dltx.strategy-vault.exit.v1");
    bytes32 public constant READY_MESSAGE = keccak256("dltx.strategy-vault.ready.v1");
    bytes32 public constant REPORT_MESSAGE = keccak256("dltx.strategy-vault.report.v1");
    /// The hub tells a leg on another chain the version it moved to (owner-upgrades-design.md §C4):
    /// `abi.encode(UPGRADE_MESSAGE, manifest, publishedAt)`, finalized.
    bytes32 public constant UPGRADE_MESSAGE = keccak256("dltx.strategy-vault.upgrade.v1");
    /// ERC-1967's implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1).
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// An upgrade or a profile switch waits this long after the owner signs it (§C4, §3.7).
    uint256 internal constant ACTION_DELAY = 24 hours;
    /// Gas handed to Circle when telling a member from inside an entering call.
    uint256 internal constant NOTIFY_GAS = 200_000;
    /// The most of Circle's minimum fee a burn accepts: 10 bp (it is 0 today; Circle's controller can
    /// raise it). Above it, a burn waits rather than paying.
    uint256 internal constant MIN_FEE_CAP_BP = 10;
    bytes4 internal constant MIN_FEE_SELECTOR = bytes4(keccak256("getMinFeeAmount(uint256)"));
    /// CCTP V2's message layout: the header, then a burn's body (TokenMessengerV2's BurnMessageV2).
    uint256 internal constant HEADER = 148;
    uint256 internal constant BURN_BODY = 228;

    // ── fixed at creation ────────────────────────────────────────────────────────────────────────────
    address public factory;
    address public owner; // the user's deposit contract on this chain (a leg: its owner VERIFIER only)
    address public registry; // this chain's registry: the group's key and check-in
    uint8 public group;
    uint8 public linkCount;
    uint8 public localLinks; // bit k: link k lives on this chain
    bytes32 public strategyId;
    bytes32 public configHash;
    address[4] public links; // Legs.MAX_LINKS: every other member
    uint32[4] public linkDomains;

    // ── state ────────────────────────────────────────────────────────────────────────────────────────
    bool public executionRevoked; // the owner's switch
    bool public paused; // the execution key's switch: the long leg's supply and borrow only
    bool public exiting; // one-way
    uint8 public readyLinks; // bit k: link k's finalized READY arrived
    uint8 public toldPending; // bit k: this member entered by itself; link k not yet told
    uint64 public exitStartedAt;
    /// The local actions' sequential nonce, one per owner credential (the deposit account's credential id),
    /// so no credential can spend another's (the combined review's CR-E1)
    mapping(bytes32 => uint256) public ownerNonceOf;
    uint256 private _locked;

    // ── the money between members, per pair, cumulative, USDC units (invariant 11) ────────────────────
    uint256[4] public sentTo; // gross: what this member burned or transferred to link k
    uint256[4] public receivedFrom; // gross: what link k sent that reached this member
    uint256[4] public feesFrom; // Circle's executed fee on link k's burns to this member
    uint256 public receivedFromOthers; // minted here from a burn of no member (net of Circle's fee)

    // ── the daily fee budget (invariant 6; the AAVE leg keeps its own loss budget) ────────────────────
    uint64 public feeDay;
    uint96 public feeToday;
    uint96 public feeYesterday;

    uint64 public reportSeq; // a leg's REPORT sequence number
    /// Amendment 2b §3.4: every call of a leg that can change a holding other than a move between members
    /// (a market call of the execution key, the owner's orders, the exit's parts). A hub on the leg's
    /// chain records it in its snapshot and refuses to charge unless it is unchanged: the evidence that
    /// no operation ran between the snapshot and the charge.
    uint64 public opCount;

    // ── version 1: the upgrade state (owner-upgrades-design.md §C3), appended ───────────────────────────
    uint8 public memberType; // MemberTypes.*, written at initialisation
    uint32 public codeVersion; // the version this instance runs: its implementation's CODE_VERSION
    uint64 public createdAt;
    uint64 public lastPublishedAt; // a follower: the `publishedAt` of the last upgrade it applied

    /// The strategy's ONE pending action (Q13): an upgrade or a profile switch, never both, at the hub.
    struct PendingAction {
        uint8 kind; // OwnerMessagesV1.KIND_*; 0 none
        uint64 due;
        bytes32 by; // the scheduling credential's id
        bytes32 target; // a version's manifest, or the profile switched to
    }

    PendingAction internal _pending;

    event Initialized(address indexed owner, uint8 group, bytes32 strategyId, bytes32 configHash);
    event ReadySent(uint8 indexed link);
    event ReadyPending(uint8 indexed link);
    event LinkReady(uint8 indexed link);
    event ExecutionRevoked(bool revoked);
    event Paused(bool paused);
    event ExitBegun(uint8 by); // 1 owner, 2 stopped group, 3 a member
    event LinkToldPending(uint8 indexed link);
    event LinkTold(uint8 indexed link);
    event Sent(uint8 indexed link, uint256 amount, uint256 maxFee, uint32 minFinalityThreshold);
    event ReceivedFromLink(uint8 indexed link, uint256 amount, uint256 fee);
    event ReceivedFromOther(address indexed sender, uint32 sourceDomain, uint256 amount);
    event ReportSent(uint64 seq);
    /// ERC-1967's, emitted by the instance whenever its implementation changes.
    event Upgraded(address indexed implementation);
    event ActionScheduled(uint8 indexed kind, bytes32 target, uint64 due, bytes32 by);
    event ActionCancelled(uint8 indexed kind, bytes32 target, uint64 due);
    /// A pending action that could no longer apply, cleared (§C3): 1 its scheduler no longer stands, 2 the
    /// switch's conditions fail, 3 the exit began.
    event ActionCleared(uint8 indexed kind, bytes32 target, uint8 why);

    error AlreadyInitialized();
    error BadLinks();
    error NotExecution();
    error NotAllowed();
    error NotReady();
    error Exiting();
    error NotExiting();
    error BadSignature();
    error Expired();
    error GroupNotStopped();
    error BadMessage();
    error IsPaused();
    error FeeAboveCap();
    error OverFeeBudget();
    error Reentrancy();
    error Unsupported();
    error ZeroAmount();
    error GasTooLow();
    error AlreadyPending();
    error NotPending();
    error NotListed();
    error RemovalPending();
    error NotDue();
    error BadProfile();

    constructor() {
        factory = address(1); // the code itself can never be initialized
    }

    modifier nonReentrant() {
        if (_locked == 1) revert Reentrancy();
        _locked = 1;
        _;
        _locked = 0;
    }

    /// The group's current key, while the owner allows it and outside the exit (§8.4 "DLTX is blocked").
    modifier onlyExecution() {
        _checkExecution();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    /// An exit module's functions run only by DELEGATECALL from an initialized member: in the module's
    /// own storage, or a member code's, `factory` is the sentinel `address(1)`.
    modifier delegated() {
        if (factory == address(1)) revert NotAllowed();
        _;
    }

    modifier inExit() {
        if (!exiting) revert NotExiting();
        _;
    }

    /// A call that can change a holding (amendment 2b §3.4): counted in `opCount`.
    modifier counted() {
        ++opCount;
        _;
    }

    function _checkExecution() internal view {
        if (exiting) revert Exiting();
        if (executionRevoked) revert NotAllowed();
        if (msg.sender != IRegistryV1(registry).executionKey(group)) revert NotExecution();
    }

    // ── the one pending action (owner-upgrades-design.md §A4, §C3) ─────────────────────────────────────

    /// Schedules `kind` → `target` by `credential` (whose signature the caller checked): refused while
    /// any action is pending (no replacement: the owner cancels, then signs again) and from a credential
    /// whose removal is pending.
    function _schedule(uint8 kind, bytes32 target, bytes32 credential) internal {
        if (_pending.kind != 0) revert AlreadyPending();
        if (IOwnerRemovals(owner).removalPendingOf(credential)) revert RemovalPending();
        uint64 due = uint64(block.timestamp + ACTION_DELAY);
        _pending = PendingAction(kind, due, credential, target);
        emit ActionScheduled(kind, target, due, credential);
    }

    /// The pending action of `kind`, due now; cleared (and `ok` false) when its scheduler no longer
    /// stands (a credential no longer in effect, or one whose removal is pending: a schedule dies with
    /// its signer).
    function _takeDue(uint8 kind) internal returns (bool ok, bytes32 target) {
        PendingAction memory p = _pending;
        if (p.kind != kind) revert NotPending();
        if (block.timestamp < p.due) revert NotDue();
        if (!IDepositOwner(owner).isCredentialId(p.by) || IOwnerRemovals(owner).removalPendingOf(p.by)) {
            _clear(1);
            return (false, p.target);
        }
        delete _pending;
        return (true, p.target);
    }

    function _clear(uint8 why) internal {
        emit ActionCleared(_pending.kind, _pending.target, why);
        delete _pending;
    }

    /// Writes this instance's implementation (owner-upgrades-design.md §A1: only its own upgrade path).
    function _setImplementation(address impl, uint256 version) internal {
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION_SLOT, impl)
        }
        codeVersion = uint32(version);
        emit Upgraded(impl);
    }

    /// This chain's Circle USDC, the only money that moves between members.
    function _usdc() internal view virtual returns (address);

    // ── internals a member or its exit module uses ──────────────────────────────────────────────────

    function _ready(uint8 k) internal view returns (bool) {
        if (k >= linkCount) return false;
        if (_isLocal(k)) return links[k].code.length > 0;
        return readyLinks & (1 << k) != 0;
    }

    function _isLocal(uint8 k) internal view returns (bool) {
        return localLinks & (1 << k) != 0;
    }

    /// Verifies one owner credential's signature of `structHash` through the owner, and the expiry.
    function _checkOwner(bytes32 structHash, uint256 deadline, bytes calldata signature) internal view {
        if (block.timestamp > deadline) revert Expired();
        address o = owner;
        if (!IDepositOwner(o).checkOwnerSignature(OwnerDomain.digest(o, structHash), signature)) {
            revert BadSignature();
        }
    }

    /// `_checkOwner` by the named credential, which must be the signature's own signer, and that
    /// credential's nonce spent. The signer is read from the signature as the deposit account reads it (a
    /// wallet's recovered address, a passkey's key) and keyed by its credential id (CR-E1).
    function _checkOwnerAs(bytes32 credential, bytes32 structHash, uint256 deadline, bytes calldata signature)
        internal
    {
        _checkOwner(structHash, deadline, signature);
        bytes32 id;
        uint8 kind = uint8(signature[0]); // a valid signature is never empty
        if (kind == OwnerDomain.WALLET) {
            address a = ecrecover(
                OwnerDomain.digest(owner, structHash),
                uint8(signature[65]),
                bytes32(signature[1:33]),
                bytes32(signature[33:65])
            );
            id = keccak256(abi.encode(kind, bytes32(uint256(uint160(a))), bytes32(0)));
        } else {
            id = keccak256(abi.encode(kind, bytes32(signature[1:33]), bytes32(signature[33:65])));
        }
        if (id != credential) revert BadSignature();
        ownerNonceOf[credential]++;
    }

    function _linkOf(address a) internal view returns (uint8 k) {
        uint8 n = linkCount;
        for (; k < n; ++k) {
            if (links[k] == a) return k;
        }
        revert BadMessage();
    }

    /// The execution key's money to member `k`, once it is ready (invariant 2): on this chain through its
    /// `receiveLocal`, else a CCTP V2 burn whose mint only `k` can complete (`destinationCaller`). Across
    /// chains the finality is the caller's choice: standard (finalized) pays Circle's minimum fee only;
    /// fast (confirmed) pays up to `maxFee`, at most `fastFeeCapBp` of the amount. Either way the fee is
    /// at least Circle's minimum, refused above `MIN_FEE_CAP_BP`. Returns the `maxFee` passed.
    function _send(uint8 k, uint256 amount, bool fast, uint256 maxFee, uint16 fastFeeCapBp)
        internal
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();
        if (!_ready(k)) revert NotReady();
        if (_isLocal(k)) {
            _toLocal(k, amount);
            return 0;
        }
        uint256 minFee = _minFee(amount);
        if (minFee * 10_000 > amount * MIN_FEE_CAP_BP) revert FeeAboveCap();
        if (!fast) maxFee = 0;
        else if (maxFee * 10_000 > amount * fastFeeCapBp) revert FeeAboveCap();
        if (maxFee < minFee) maxFee = minFee;
        _burnTo(k, amount, maxFee, fast ? FINALITY_FAST : FINALITY_STANDARD);
        return maxFee;
    }

    function _toLocal(uint8 k, uint256 amount) internal {
        address usdc = _usdc();
        sentTo[k] += amount;
        IERC20(usdc).approve(links[k], amount);
        ILinkV1(links[k]).receiveLocal(amount);
        IERC20(usdc).approve(links[k], 0);
        emit Sent(k, amount, 0, 0);
    }

    function _burnTo(uint8 k, uint256 amount, uint256 maxFee, uint32 finality) internal {
        address usdc = _usdc();
        bytes32 to = bytes32(uint256(uint160(links[k])));
        sentTo[k] += amount;
        IERC20(usdc).approve(TOKEN_MESSENGER, amount);
        ITokenMessengerV2(TOKEN_MESSENGER).depositForBurn(amount, linkDomains[k], to, usdc, to, maxFee, finality);
        emit Sent(k, amount, maxFee, finality);
    }

    /// Circle's minimum fee for `amount` (TokenMessengerV2 `getMinFeeAmount`), 0 where it has none.
    function _minFee(uint256 amount) internal view returns (uint256 fee) {
        (bool ok, bytes memory out) =
            TOKEN_MESSENGER.staticcall(abi.encodeWithSelector(MIN_FEE_SELECTOR, amount));
        if (ok && out.length >= 32) fee = abi.decode(out, (uint256));
    }

    /// Adds `fee` to the 24-hour fee budget, `budgetBp` of `valueBefore` (two day buckets: any 24 hours
    /// fall within two consecutive buckets, so no 24 hours pay more than the budget).
    function _chargeFee(uint256 fee, uint256 valueBefore, uint16 budgetBp) internal {
        if (fee == 0) return;
        uint256 day = block.timestamp / 1 days;
        if (day != feeDay) {
            feeYesterday = day == uint256(feeDay) + 1 ? feeToday : 0;
            feeToday = 0;
            feeDay = uint64(day);
        }
        uint256 total = uint256(feeToday) + feeYesterday + fee;
        if (total * 10_000 > valueBefore * budgetBp) revert OverFeeBudget();
        feeToday = uint96(feeToday + fee);
    }

    /// A leg's exit: everything to its hub (link 0), never a revert — Circle may be paused, and nothing
    /// local may wait for it (decision 27). Exempt from readiness (invariant 2): a leg's money came from
    /// its strategy's members, all funded from the hub, so the hub exists. Standard finality, Circle's
    /// minimum fee within the cap; the mint bound to the hub, so it is counted there.
    function _sendAllToHub() internal {
        address usdc = _usdc();
        uint256 amount = IERC20(usdc).balanceOf(address(this));
        if (amount == 0) return;
        if (_isLocal(0)) {
            try this.exitTransfer(amount) {} catch {}
            return;
        }
        uint256 fee = _minFee(amount);
        if (fee * 10_000 > amount * MIN_FEE_CAP_BP) return;
        bytes32 to = bytes32(uint256(uint160(links[0])));
        IERC20(usdc).approve(TOKEN_MESSENGER, amount);
        try ITokenMessengerV2(TOKEN_MESSENGER).depositForBurn(
            amount, linkDomains[0], to, usdc, to, fee, FINALITY_STANDARD
        ) {
            sentTo[0] += amount;
            emit Sent(0, amount, fee, FINALITY_STANDARD);
        } catch {
            IERC20(usdc).approve(TOKEN_MESSENGER, 0);
        }
    }

    /// `amount` of this leg's USDC to its hub, as `_sendAllToHub` sends all of it (amendment 2d §5.2: the
    /// AAVE leg keeps what still repays its debt). A copy, so that the Hyperliquid leg's exit module, which
    /// calls `_sendAllToHub`, keeps its bytecode.
    function _sendToHub(uint256 amount) internal {
        address usdc = _usdc();
        if (amount == 0) return;
        if (_isLocal(0)) {
            try this.exitTransfer(amount) {} catch {}
            return;
        }
        uint256 fee = _minFee(amount);
        if (fee * 10_000 > amount * MIN_FEE_CAP_BP) return;
        bytes32 to = bytes32(uint256(uint160(links[0])));
        IERC20(usdc).approve(TOKEN_MESSENGER, amount);
        try ITokenMessengerV2(TOKEN_MESSENGER).depositForBurn(
            amount, linkDomains[0], to, usdc, to, fee, FINALITY_STANDARD
        ) {
            sentTo[0] += amount;
            emit Sent(0, amount, fee, FINALITY_STANDARD);
        } catch {
            IERC20(usdc).approve(TOKEN_MESSENGER, 0);
        }
    }

    /// One Circle message to member `k` on another chain: `soft` tries it with NOTIFY_GAS and returns
    /// whether it went (Circle may be paused: decision 27), and REVERTS with less gas left than that try
    /// needs, so that a gas estimate can never buy a silently skipped message (§14 row 10).
    function _message(uint8 k, bytes memory body, uint32 finality, bool soft) internal returns (bool) {
        bytes32 to = bytes32(uint256(uint160(links[k])));
        if (!soft) {
            IMessageTransmitterV2(MESSAGE_TRANSMITTER).sendMessage(linkDomains[k], to, bytes32(0), finality, body);
            return true;
        }
        if (gasleft() < NOTIFY_GAS + 50_000) revert GasTooLow();
        try IMessageTransmitterV2(MESSAGE_TRANSMITTER).sendMessage{gas: NOTIFY_GAS}(
            linkDomains[k], to, bytes32(0), finality, body
        ) {
            return true;
        } catch {
            return false;
        }
    }

    // ── money between members and reports (§3.6, decisions 44 and 45) ─────────────────────────────────


    /// `receiveMint` (anyone, in every state): completes a Circle mint bound to this member
    /// (`destinationCaller`). It checks what Circle does not — the message addressed to this chain's
    /// TokenMessenger (only then does Circle check that its sender is the remote TokenMessenger and that
    /// it is a burn: a general message to any other recipient is attested too, and would mint nothing),
    /// this member as the caller and the mint's recipient, this chain as the destination — relays it
    /// (Circle checks the attestation and the nonce), checks that exactly the amount less Circle's fee
    /// arrived, then counts it: a burn by member `k` from its own domain adds to `receivedFrom[k]`
    /// (gross) and `feesFrom[k]`; any other burn is accepted uncounted. A leg runs it in its exit module
    /// (size), the hub inline.
    function _receiveMint(bytes calldata message, bytes calldata attestation) internal {
        if (message.length < HEADER + BURN_BODY) revert BadMessage();
        bytes32 self = bytes32(uint256(uint160(address(this))));
        if (
            uint32(bytes4(message[8:12])) != IMessageTransmitterV2(MESSAGE_TRANSMITTER).localDomain()
                || bytes32(message[76:108]) != bytes32(uint256(uint160(TOKEN_MESSENGER)))
                || bytes32(message[108:140]) != self || bytes32(message[HEADER + 36:HEADER + 68]) != self
        ) revert BadMessage();
        uint32 source = uint32(bytes4(message[4:8]));
        uint256 amount = uint256(bytes32(message[HEADER + 68:HEADER + 100]));
        bytes32 from = bytes32(message[HEADER + 100:HEADER + 132]);
        uint256 fee = uint256(bytes32(message[HEADER + 164:HEADER + 196]));
        address usdc = _usdc();
        uint256 before = IERC20(usdc).balanceOf(address(this));
        if (!IMessageTransmitterV2(MESSAGE_TRANSMITTER).receiveMessage(message, attestation)) revert BadMessage();
        if (fee > amount || IERC20(usdc).balanceOf(address(this)) - before != amount - fee) revert BadMessage();
        uint8 n = linkCount;
        for (uint8 k; k < n; ++k) {
            if (
                !_isLocal(k) && linkDomains[k] == source && bytes32(uint256(uint160(links[k]))) == from
            ) {
                receivedFrom[k] += amount;
                feesFrom[k] += fee;
                _onCredit(amount - fee);
                emit ReceivedFromLink(k, amount, fee);
                return;
            }
        }
        receivedFromOthers += amount - fee;
        emit ReceivedFromOther(address(uint160(uint256(from))), source, amount - fee);
    }


    /// `report` (anyone): this leg's holdings, counters, sequence number and observation time, to its hub
    /// (link 0): directly on the same chain, else by Circle at finalized. Reverts as Circle does. A leg
    /// runs it in its exit module (size). The payload (amendment 2b §3.4): `abi.encode(REPORT_MESSAGE, seq,
    /// observedAt, observationBlock, lastMoveBlock, Holding[], sentTo[4], receivedFrom[4], feesFrom[4])`,
    /// every figure read in this one block.
    function _report() internal {
        (Holding[] memory holdings, uint256 lastMove) = _holdings();
        uint64 seq = ++reportSeq;
        bytes memory body = abi.encode(
            REPORT_MESSAGE, seq, block.timestamp, block.number, lastMove, holdings, sentTo, receivedFrom, feesFrom
        );
        if (_isLocal(0)) ILinkV1(links[0]).receiveReport(body);
        else _message(0, body, FINALITY_STANDARD, false);
        emit ReportSent(seq);
    }

    /// `holdings()` (amendment 2b §3.4): the report's figures as a view, so a hub on this leg's chain
    /// records them in its snapshot without a message; with `opCount`, and whether every change of a
    /// holding goes through this leg's own (counted) calls (`tracked`: false for an account another key
    /// trades, the Hyperliquid leg's agent). A leg runs it in its exit module (size).
    function _legView()
        internal
        view
        returns (
            Holding[] memory h,
            uint256[4] memory sent,
            uint256[4] memory received,
            uint64 observationBlock,
            uint64 lastMoveBlock,
            uint64 ops,
            bool tracked
        )
    {
        uint256 lastMove;
        (h, lastMove) = _holdings();
        return (h, sentTo, receivedFrom, uint64(block.number), uint64(lastMove), opCount, _tracked());
    }

    /// A leg's holdings, and one word of its own: the block of its last move between HyperEVM and
    /// HyperCore (the Hyperliquid leg; 0 for a leg with none).
    function _holdings() internal view virtual returns (Holding[] memory, uint256);

    /// Whether every change of this leg's holdings goes through its own counted calls (amendment 2b §3.4).
    function _tracked() internal pure virtual returns (bool);

    /// A member move credited here (`receiveLocal`, a member's mint, net of Circle's fee): the hub books
    /// it (amendment 2b §3.3); a leg does nothing.
    function _onCredit(uint256) internal virtual {}

    /// The same-chain half of `_sendAllToHub`, a self-call so that its failure stays inside its `try`.
    function exitTransfer(uint256 amount) external {
        if (msg.sender != address(this) || !exiting) revert NotAllowed();
        _toLocal(0, amount);
    }
}
