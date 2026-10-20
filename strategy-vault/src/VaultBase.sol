// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {IDepositOwner, OwnerDomain} from "./interfaces/IDepositOwner.sol";
import {IERC20, IMessageTransmitterV2, ITokenMessengerV2} from "./interfaces/Protocols.sol";
import {Holding, Legs, OwnerMessages} from "./lib/VaultTypes.sol";

/// What a member asks its registry: the group's current key and whether the group stopped checking in.
interface IRegistryView {
    function executionKey(uint8 group) external view returns (address);
    function stopped(uint8 group) external view returns (bool);
}

/// What a member calls on another member of the same chain.
interface ILink {
    function legExit() external;
    function receiveLocal(uint256 amount) external;
    function receiveReport(bytes calldata body) external;
}

/*
 * A member's STORAGE, events, errors and the internals its exit module may need (step 11e2 amendment
 * 2a, revision 1, §3.5–§3.8): the base of `VaultBase`, and alone the base of an exit module, which runs
 * by DELEGATECALL in a member's storage and so must share its layout without carrying the member's
 * external functions. `VaultBase` declares no storage of its own.
 *
 * A strategy's members are its hub (index 0) and 2 to 4 legs. Every member knows every other: a leg's
 * link 0 is its hub, then its sister legs; a hub's links are its legs.
 */
abstract contract VaultState {
    // ── Circle CCTP V2, the same addresses on every chain a member lives on (§6) ──────────────────────
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint32 internal constant FINALITY_FAST = 1000; // "confirmed": the fast transfer, with a fee
    uint32 internal constant FINALITY_STANDARD = 2000; // "finalized": no fee
    /// The messages between members: a tag first, from a member's address and domain only.
    bytes32 public constant EXIT_MESSAGE = keccak256("dltx.strategy-vault.exit.v1");
    bytes32 public constant READY_MESSAGE = keccak256("dltx.strategy-vault.ready.v1");
    bytes32 public constant REPORT_MESSAGE = keccak256("dltx.strategy-vault.report.v1");
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
        if (msg.sender != IRegistryView(registry).executionKey(group)) revert NotExecution();
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
        ILink(links[k]).receiveLocal(amount);
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
        if (_isLocal(0)) ILink(links[0]).receiveReport(body);
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

/*
 * What every member shares (step 11e2 amendment 2a, revision 1, §3.5, §3.6; the vault spec's §8.3,
 * §8.4): the fixed links (every other member), the owner's signed actions, the execution key's gate
 * (read from the chain's registry), pause, readiness, money between members counted per pair, reports,
 * and the exit state's entry — by the owner's signature, by anyone once the group stopped, or by a
 * member's message — with the others told by the member that entered by itself, so that entering never
 * depends on Circle (decision 27).
 *
 * A member is an EIP-1167 clone: its links live in storage, written once by `initialize` from its
 * combination factory in the transaction that creates it. No setter exists for any of them. After that
 * the member never asks its factory anything (invariant 9).
 */
abstract contract VaultBase is VaultState {
    /// The member type's exit module (§3.8), or none (`address(0)`): deployed before the member code, its
    /// code hash checked here, never changeable. Only the selectors `_exitSelector` names are run there,
    /// by DELEGATECALL, in this member's storage.
    address public immutable exitModule;

    error BadModule();

    constructor(address exitModule_, bytes32 exitModuleCodeHash) {
        if (exitModule_ != address(0) || exitModuleCodeHash != bytes32(0)) {
            if (
                exitModuleCodeHash == bytes32(0) || exitModuleCodeHash == keccak256("")
                    || exitModule_.codehash != exitModuleCodeHash
            ) revert BadModule();
        }
        exitModule = exitModule_;
    }

    /// The exit module's functions, and nothing else, run in this member's storage.
    fallback() external {
        address m = exitModule;
        if (m == address(0) || !_exitSelector(msg.sig)) revert Unsupported();
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            let ok := delegatecall(gas(), m, p, calldatasize(), 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }

    function _exitSelector(bytes4 selector) internal pure virtual returns (bool);

    // ── creation ─────────────────────────────────────────────────────────────────────────────────────

    /// The combination factory, once, in the transaction that creates the clone (`IMember.initialize`).
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
            _agentAction(action, agent);
        }
    }

    function _agentAction(uint8, address) internal virtual {
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
        if (!IRegistryView(registry).stopped(group)) revert GroupNotStopped();
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
            ILink(link).legExit();
            return true;
        }
        return _message(k, abi.encode(EXIT_MESSAGE), FINALITY_FAST, soft);
    }

    /// Role-specific effects of entering (the Hyperliquid leg replaces its agent).
    function _onExit() internal virtual;
}
