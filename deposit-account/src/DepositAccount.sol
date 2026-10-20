// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";

/*
 * The user's deposit contract — docs/architecture/rework/specs/step-11e2-strategy-vault-design.md
 * §7 (the owner) and §8.2 (the deposit contract).
 *
 * One per user, an EIP-1167 clone made by `DepositFactory` at the same address on every chain, its
 * salt hashing the user's id and their FIRST OWNER SET (decision 22): whoever deploys it, it starts
 * with the user's own credentials.
 *
 * THE OWNER is a set of at most four credentials, each a plain address (an EOA, verified by ECDSA
 * recovery only: no EIP-1271, decision 29) or a passkey's P-256 public key (verified as a WebAuthn
 * assertion by OpenZeppelin's WebAuthn, the challenge being the EIP-712 digest). Owner messages are
 * EIP-712 in the domain "DLTX Owner", version "1", this contract's address and NO chain id (§7.2):
 *   - record changes (credentials, the withdrawal address) are accepted at the HOME only, the copy
 *     on Arbitrum (chain 42161), with the signing credential's own record nonce and an expiry; every other
 *     chain's copy learns the record by the home's own Circle message (`publish`, §7.3);
 *   - local actions (a signed withdrawal, revoking or allowing the transfer key, authorising a
 *     strategy) name the chain id and carry the signing credential's own local nonce on this chain
 *     and an expiry;
 *   - cancelling a pending change carries no nonce: it names the change and its due time, so a
 *     replay can only cancel again, and nobody can starve it by consuming nonces (README, Decisions).
 *
 * MONEY leaves only to the owner's withdrawal address, to a DEPLOYED vault of THIS owner registered by a
 * vault factory the owner trusts on this chain (within the USDC allowance the owner signed for that
 * factory, strategy and configuration), to the platform's fee address for a fee the owner signed, into
 * the pinned USDT→USDC pool, or by a CCTP burn to this same address on another deposit chain.
 * A vault factory becomes trusted by the owner's signature alone, 24 hours after the first
 * authorisation naming it (amendment 1, decision 35); a copy learns the trust and the allowance from
 * the home's own message. No open-ended call, no delegatecall, no selfdestruct.
 *
 * Compiled for `cancun`: OpenZeppelin 5.6.1's WebAuthn slices bytes with MCOPY (README, Decisions).
 */

/// One owner credential. A wallet: kind 1, `x` the address left-padded, `y` zero. A passkey: kind 2,
/// `x` and `y` the P-256 public key's coordinates.
struct Credential {
    uint8 kind;
    bytes32 x;
    bytes32 y;
}

/// What the account reads from its factory.
interface IDepositFactory {
    function transferKey() external view returns (address);
    function feeRecipient() external view returns (address);
    function stopped() external view returns (bool);
}

/// What every vault factory implements (slice 2's `authorisedFor`, unchanged by amendment 1): the
/// deposit account that owns `vault`, its strategy id and the configuration hash the owner signed for
/// it; zeros for an address it did not create.
interface IVaultFactory {
    function authorisedFor(address vault) external view returns (address owner, bytes32 strategyId, bytes32 configHash);
}

/// Circle's CCTP V2 MessageTransmitterV2 (sendMessage, selector 0x14b157ab, read on Arbitrum and
/// HyperEVM 2026-10-14).
interface IMessageTransmitterV2 {
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes calldata messageBody
    ) external;
}

/// Circle's CCTP V2 TokenMessengerV2 (depositForBurn, selector 0x8e0250ee).
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// Uniswap V3's pool, swapped directly (no router: the pool is the only contract trusted).
interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// An owner-signed funding authorisation (decision 16, amendment 1): `allowance` of USDC on the chain of
/// `domain` (a deposit chain), for the vault of `vaultFactory` with `strategyId` and `configHash`.
struct StrategyGrant {
    address vaultFactory;
    uint32 domain;
    bytes32 strategyId;
    bytes32 configHash;
    uint256 allowance;
    uint256 nonce;
    uint256 deadline;
}

/// An owner-signed withdrawal (decision 19): every field is signed. `to` and `feeRecipient` must be the
/// withdrawal address and the factory's fee recipient in effect when it executes.
struct Withdrawal {
    address token;
    uint256 amount;
    address to;
    uint256 maxFee;
    address feeRecipient;
    uint256 nonce;
    uint256 deadline;
}

contract DepositAccount {
    // ── constants ────────────────────────────────────────────────────────────────────────────

    uint8 public constant WALLET = 1;
    uint8 public constant PASSKEY = 2;
    uint256 public constant MAX_CREDENTIALS = 4;
    /// The most a signed withdrawal pays its submitter's fee recipient, in the chain's USDC or its
    /// pinned USDT (both 6 decimals): 50 USDC, whatever the owner signed as `maxFee` (amendment 2d,
    /// decision 73). Any other token pays no fee.
    uint256 public constant MAX_SIGNED_FEE = 50e6;
    /// A credential's removal and a later withdrawal-address change take effect after this (§7.4, decision 15).
    uint256 public constant DELAY = 24 hours;

    /// Arbitrum One: the home of the owner's record (decision 21), CCTP domain 3.
    uint256 public constant HOME_CHAIN_ID = 42161;
    uint32 public constant HOME_DOMAIN = 3;
    /// CCTP's finalized threshold: a record is sent and accepted at it only.
    uint32 public constant FINALIZED = 2000;

    /// Circle's CCTP V2 contracts, the same address on every chain (§6; step 11e1's chain files).
    address public constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    /// The conversion's bound against 1 USD per USDT (decision 30), in basis points: the minimum out
    /// of a swap is never below amount × (1 − 0.2%), 998 USDC per 1,000 USDT (the operator's decision,
    /// 2026-10-14; the pools quoted 998.95 on Ethereum and 998.97 on Arbitrum that day). USDT deposits
    /// are locked in the product for now; this stays so they can reopen on these same contracts.
    uint256 public constant CONVERSION_BOUND_BP = 20;

    /// The most a CCTP burn may pay Circle, in basis points of the amount: the messenger's own minimum
    /// fee (`getMinFeeAmount`, which its controller may raise; HyperEVM's has one, 0 on 2026-10-14) is
    /// paid up to this, and a burn whose minimum is above it is refused (the USDC stays here).
    uint256 public constant BURN_FEE_CAP_BP = 10;

    /// Uniswap V3's price limits (TickMath), so an exact-input swap is limited by `minOut` alone.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("DLTX Owner");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    // record changes: at the home only, the signer's record nonce
    bytes32 public constant ADD_CREDENTIAL_TYPEHASH =
        keccak256("AddCredential(uint8 kind,bytes32 x,bytes32 y,uint256 nonce,uint256 deadline)");
    bytes32 public constant REMOVE_CREDENTIAL_TYPEHASH =
        keccak256("RemoveCredential(uint8 kind,bytes32 x,bytes32 y,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_WITHDRAWAL_ADDRESS_TYPEHASH =
        keccak256("SetWithdrawalAddress(address withdrawalAddress,uint256 nonce,uint256 deadline)");
    // cancellations: at the home only, no nonce (the change and its due time name them)
    bytes32 public constant CANCEL_REMOVAL_TYPEHASH =
        keccak256("CancelRemoval(uint8 kind,bytes32 x,bytes32 y,uint256 due,uint256 deadline)");
    bytes32 public constant CANCEL_ADDITION_TYPEHASH =
        keccak256("CancelAddition(uint8 kind,bytes32 x,bytes32 y,uint256 due,uint256 deadline)");
    bytes32 public constant CANCEL_WITHDRAWAL_ADDRESS_TYPEHASH =
        keccak256("CancelWithdrawalAddress(address withdrawalAddress,uint256 due,uint256 deadline)");
    // local actions: the chain named, the signer's local nonce on this chain
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(
        "Withdraw(uint256 chainId,address token,uint256 amount,address to,uint256 maxFee,address feeRecipient,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant REVOKE_TRANSFER_TYPEHASH =
        keccak256("RevokeTransfer(uint256 chainId,uint256 nonce,uint256 deadline)");
    bytes32 public constant ALLOW_TRANSFER_TYPEHASH =
        keccak256("AllowTransfer(uint256 chainId,uint256 nonce,uint256 deadline)");
    bytes32 public constant AUTHORISE_STRATEGY_TYPEHASH = keccak256(
        "AuthoriseStrategy(uint256 chainId,address vaultFactory,uint32 domain,bytes32 strategyId,bytes32 configHash,uint256 allowance,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant CANCEL_TRUST_TYPEHASH =
        keccak256("CancelTrust(address vaultFactory,uint32 domain,uint256 due,uint256 deadline)");
    /// The most one authorisation may grant: a copy's sum of them can then never overflow (and saturates
    /// anyway), so no authorisation message can revert forever.
    uint256 public constant MAX_GRANT = type(uint128).max;

    /// Tags the record message's body, so no other message can ever be read as one.
    bytes32 public constant RECORD_TAG = keccak256("dltx.owner-record.v1");
    /// Tags an authorisation dispatched by the home to a copy (amendment 1, §2.4).
    bytes32 public constant AUTH_TAG = keccak256("dltx.owner-authorisation.v1");

    /// Set in the implementation's constructor; a clone reads it from the implementation's code.
    address public immutable factory;

    // ── state (each clone's own) ─────────────────────────────────────────────────────────────

    bool internal _initialised;
    /// Re-entrancy lock for the money functions.
    bool internal _entered;
    /// A copy has received the home's record at least once. Until then it trusts no credential: the
    /// genesis set may have changed at the home (README, Decisions). The home is always in sync.
    bool internal _synced;
    /// Whether the owner has revoked the transfer key here (a local action, per chain).
    bool public transferRevoked;
    /// The record's version: 0 is the genesis set (part of the address); +1 on each effective change.
    uint64 internal _version;
    /// When the account was deployed on this chain: a copy takes as its FIRST record only one the home
    /// published at or after this (README, Decisions).
    uint64 internal _deployedAt;
    /// When a pending withdrawal-address change takes effect (0: none).
    uint64 internal _pendingWithdrawalDue;
    address internal _withdrawal;
    address internal _pendingWithdrawal;
    /// The USDT a swap in flight may pay its pool (0 outside a conversion's swap).
    uint256 internal _swapIn;
    Credential[] internal _creds;
    /// A credential's pending removal: when it takes effect (0: none). Home only.
    mapping(bytes32 credentialId => uint256 due) internal _removalDue;
    /// Who proposed a pending removal: its own proposals never open the self-cancel exception.
    mapping(bytes32 credentialId => bytes32 proposer) internal _removalBy;
    /// Each credential's own record-change and local-action sequences (one credential can't void
    /// another's pending signatures).
    mapping(bytes32 credentialId => uint256 next) internal _recordNonce;
    mapping(bytes32 credentialId => uint256 next) internal _localNonce;
    /// A credential's pending addition: when it takes effect (0: in effect). Home only (decision 31).
    mapping(bytes32 credentialId => uint256 due) internal _addDue;
    /// What the transfer key may still pay ONE vault in this chain's USDC (decision 16, amendment 1),
    /// keyed by keccak256(abi.encode(vaultFactory, strategyId, configHash)).
    mapping(bytes32 vaultKey => uint256 remaining) public allowance;
    /// A vault factory's trust FOR ONE DEPOSIT DOMAIN, keyed by keccak256(abi.encode(vaultFactory,
    /// domain)): at the home, 24 hours after the first authorisation naming that pair, cancellable until
    /// then, permanent once in effect; on a copy (its own domain), in effect when the home's
    /// authorisation arrives. `epoch` counts the pair's proposals: a grant binds to the epoch it was
    /// made under, so a cancelled trust's grants never revive, even re-proposed in the same second.
    struct Trust {
        uint64 due;
        uint64 epoch;
    }

    mapping(bytes32 trustKey => Trust) internal _trust;
    /// The home's authorisations, by the id it generates (a counter per account).
    mapping(uint256 id => Grant) internal _grants;
    uint256 public authorisationCount;
    /// A copy's applied authorisations: each id once, however often it is dispatched.
    mapping(uint256 id => bool) public authorisationApplied;

    /// An authorisation the home accepted. `trustEpoch` is the (factory, domain) trust it was granted
    /// under: it applies, or is dispatched, only while that same trust is the one in effect (a cancelled
    /// trust voids its grants for good).
    struct Grant {
        address vaultFactory;
        uint32 domain;
        bool applied;
        bytes32 strategyId;
        bytes32 configHash;
        uint256 allowance;
        uint64 trustEpoch;
    }

    // ── events ───────────────────────────────────────────────────────────────────────────────

    event Initialised(Credential[] owners);
    event AdditionProposed(bytes32 indexed id, uint8 kind, bytes32 x, bytes32 y, uint256 due);
    event AdditionCancelled(bytes32 indexed id, uint256 due);
    event CredentialAdded(bytes32 indexed id, uint64 version);
    event RemovalProposed(bytes32 indexed id, uint256 due);
    event RemovalCancelled(bytes32 indexed id, uint256 due);
    event CredentialRemoved(bytes32 indexed id, uint64 version);
    event WithdrawalAddressProposed(address indexed next, uint256 due);
    event WithdrawalAddressCancelled(address indexed next, uint256 due);
    event WithdrawalAddressSet(address indexed previous, address indexed next, uint64 version);
    event Published(uint32 indexed domain, uint64 version);
    event RecordApplied(uint64 version);
    event RecordIgnored(uint64 received, uint64 current);
    event TransferRevoked(bool revoked);
    event StrategyAuthorised(
        uint256 indexed id,
        address indexed vaultFactory,
        uint32 domain,
        bytes32 strategyId,
        bytes32 configHash,
        uint256 allowance,
        uint256 trustDue,
        uint256 trustEpoch
    );
    event TrustProposed(address indexed vaultFactory, uint32 indexed domain, uint256 due, uint256 epoch);
    event TrustCancelled(address indexed vaultFactory, uint32 indexed domain, uint256 due);
    event AuthorisationApplied(uint256 indexed id, bytes32 indexed vaultKey, uint256 added, uint256 remaining);
    event AuthorisationDispatched(uint256 indexed id, uint32 indexed domain);
    event AuthorisationIgnored(uint256 indexed id);
    event Withdrawn(address indexed token, address indexed to, uint256 amount, uint256 fee, address by);
    event Funded(address indexed vault, address indexed vaultFactory, bytes32 indexed strategyId, uint256 amount);
    event Swapped(uint256 usdtIn, uint256 usdcOut);
    event Burned(uint32 indexed domain, uint256 amount, uint256 maxFee);

    // ── errors ───────────────────────────────────────────────────────────────────────────────

    error NotFactory();
    error AlreadyInitialised();
    error NotInitialised();
    error BadOwnerSet();
    error BadCredential();
    error NotAllowed();
    error NotHome();
    error NotCopy();
    error BadSignature();
    error BadNonce();
    error Expired();
    error AlreadyMember();
    error NotMember();
    error TooManyCredentials();
    error LastCredential();
    error AlreadyPending();
    error NothingPending();
    error SelfRemoval();
    error SelfCancel();
    error ZeroAddress();
    error NoWithdrawalAddress();
    error FeeAboveMax();
    error NoFeeRecipient();
    error NotOwnVault();
    error NotTrusted();
    error NoGrant();
    error AlreadyApplied();
    error AllowanceExceeded();
    error ConversionUnavailable();
    error BadDomain();
    error BadAmount();
    error BurnFeeTooHigh();
    error BelowMinimum();
    error TransferFailed();
    error Reentered();
    error NotTransmitter();
    error NotHomeMessage();
    error NotFinalized();
    error BadMessage();
    error NotSynced();
    error NotWithdrawalAddress();
    error NotFeeRecipient();

    constructor() {
        factory = msg.sender;
        _initialised = true; // the implementation itself is never an account
    }

    modifier nonReentrant() {
        if (_entered) revert Reentered();
        _entered = true;
        _;
        _entered = false;
    }

    /// Factory only, once, in the transaction that deploys the clone: the genesis owner set, exactly
    /// one credential (amendment 2d, decision 76): a co-owner can't hide in the address, and any
    /// further credential is an addition with its 24 hours.
    function initialize(Credential[] calldata owners) external {
        if (msg.sender != factory) revert NotFactory();
        if (_initialised) revert AlreadyInitialised();
        if (owners.length != 1) revert BadOwnerSet();
        // the shape only: an account must be deployable wherever money already waits at its
        // address, whatever code a wallet has on that chain; EOA-only is enforced before an
        // address is ever shown (README, Decisions)
        if (!_validCredential(owners[0], false)) revert BadCredential();
        _creds.push(owners[0]);
        _initialised = true;
        _deployedAt = uint64(block.timestamp);
        emit Initialised(owners);
    }

    // ── views ────────────────────────────────────────────────────────────────────────────────

    /// The home holds the owner's record; every other chain's account is a copy of it.
    function isHome() public view returns (bool) {
        return block.chainid == HOME_CHAIN_ID;
    }

    /// The home always; a copy once it has received the home's record. An unsynced copy accepts no
    /// owner signature and no local action.
    function synced() public view returns (bool) {
        return _synced || isHome();
    }

    /// The next record-change nonce of credential `c` (home only).
    function recordNonceOf(Credential calldata c) external view returns (uint256) {
        return _recordNonce[credentialId(c)];
    }

    /// The next local-action nonce of credential `c` on this chain.
    function localNonceOf(Credential calldata c) external view returns (uint256) {
        return _localNonce[credentialId(c)];
    }

    /// What the transfer key may still pay the vault of `vaultFactory` with `strategyId` and
    /// `configHash`, in this chain's USDC.
    function allowanceOf(address vaultFactory, bytes32 strategyId, bytes32 configHash) external view returns (uint256) {
        return allowance[vaultKey(vaultFactory, strategyId, configHash)];
    }

    function vaultKey(address vaultFactory, bytes32 strategyId, bytes32 configHash) public pure returns (bytes32) {
        return keccak256(abi.encode(vaultFactory, strategyId, configHash));
    }

    function trustKey(address vaultFactory, uint32 domain) public pure returns (bytes32) {
        return keccak256(abi.encode(vaultFactory, domain));
    }

    /// Whether this account trusts `vaultFactory` for `domain` now (at a copy, its own domain).
    function isTrusted(address vaultFactory, uint32 domain) public view returns (bool) {
        return _due(_trust[trustKey(vaultFactory, domain)].due);
    }

    /// When `vaultFactory`'s trust for `domain` took or takes effect here (0: untrusted, or cancelled),
    /// and how many times that pair's trust was proposed.
    function trustOf(address vaultFactory, uint32 domain) external view returns (uint256 due, uint256 epoch) {
        Trust storage t = _trust[trustKey(vaultFactory, domain)];
        return (t.due, t.epoch);
    }

    /// The home's authorisation `id` (zeros if none).
    function grant(uint256 id) external view returns (Grant memory) {
        return _grants[id];
    }

    function credentialId(Credential memory c) public pure returns (bytes32) {
        return keccak256(abi.encode(c.kind, c.x, c.y));
    }

    /// The credentials in effect now: an addition past its 24 hours is in, a removal past its 24 hours
    /// is out, settled or not. On an unsynced copy, the genesis set it holds but trusts not.
    function credentials() public view returns (Credential[] memory out) {
        uint256 n = _creds.length;
        out = new Credential[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (_inEffect(credentialId(_creds[i]))) out[k++] = _creds[i];
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    /// The withdrawal address in effect now (zero until the owner sets one).
    function withdrawalAddress() public view returns (address) {
        return _due(_pendingWithdrawalDue) ? _pendingWithdrawal : _withdrawal;
    }

    /// A withdrawal-address change still waiting for its 24 hours (zeros if none).
    function pendingWithdrawalAddress() external view returns (address next, uint256 due) {
        if (_pendingWithdrawalDue != 0 && !_due(_pendingWithdrawalDue)) return (_pendingWithdrawal, _pendingWithdrawalDue);
    }

    /// When a credential's pending removal takes effect (0: none, or already in effect).
    function removalDue(Credential calldata c) external view returns (uint256 due) {
        due = _removalDue[credentialId(c)];
        if (_due(due)) due = 0;
    }

    /// When a credential's pending addition takes effect (0: none, or already in effect).
    function additionDue(Credential calldata c) external view returns (uint256 due) {
        bytes32 id = credentialId(c);
        if (_indexOf(id) == type(uint256).max) return 0;
        due = _addDue[id];
        if (_due(due)) due = 0;
    }

    /// The record's version in effect now; a copy is complete when it equals the home's.
    function version() external view returns (uint64 v) {
        v = _version;
        if (_due(_pendingWithdrawalDue)) ++v;
        for (uint256 i; i < _creds.length; ++i) {
            bytes32 id = credentialId(_creds[i]);
            if (_due(_removalDue[id])) ++v;
            if (_due(_addDue[id])) ++v;
        }
    }

    function isCredential(Credential calldata c) external view returns (bool) {
        return _isCredential(credentialId(c));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, address(this)));
    }

    /// The EIP-712 digest of a struct in this account's "DLTX Owner" domain: what a credential signs.
    function hashTypedData(bytes32 structHash) public view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// Whether a credential in effect on this chain signed `digest` (for the vaults and the vault
    /// factory, which verify the owner's other messages, `BeginExit` among them, through here).
    /// `signature` is 0x01 ‖ r ‖ s ‖ v for a wallet, or 0x02 ‖ x ‖ y ‖ the ABI-encoded WebAuthn
    /// assertion (r, s, challengeIndex, typeIndex, authenticatorData, clientDataJSON) for a passkey.
    function checkOwnerSignature(bytes32 digest, bytes calldata signature) external view returns (bool) {
        return _signer(digest, signature) != bytes32(0);
    }

    // ── record changes: the home only (§7.3, §7.4) ───────────────────────────────────────────

    /// Signed by a current credential; effective after 24 hours unless cancelled by any current
    /// credential (decision 31), so a stolen credential can't add its accomplices at once. A pending
    /// addition counts toward the four.
    function addCredential(Credential calldata c, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        _recordChange(keccak256(abi.encode(ADD_CREDENTIAL_TYPEHASH, c.kind, c.x, c.y, nonce, deadline)), nonce, deadline, signature);
        if (!_validCredential(c, true)) revert BadCredential();
        bytes32 id = credentialId(c);
        if (_indexOf(id) != type(uint256).max) revert AlreadyMember();
        if (_creds.length >= MAX_CREDENTIALS) revert TooManyCredentials();
        _creds.push(c);
        uint256 due = block.timestamp + DELAY;
        _addDue[id] = due;
        emit AdditionProposed(id, c.kind, c.x, c.y, due);
    }

    /// Any current credential, before the addition takes effect. No nonce: it names the addition.
    function cancelAddition(Credential calldata c, uint256 due, uint256 deadline, bytes calldata signature) external {
        _cancel(keccak256(abi.encode(CANCEL_ADDITION_TYPEHASH, c.kind, c.x, c.y, due, deadline)), deadline, signature);
        bytes32 id = credentialId(c);
        uint256 i = _indexOf(id);
        if (due == 0 || i == type(uint256).max || _addDue[id] != due) revert NothingPending();
        delete _addDue[id];
        _creds[i] = _creds[_creds.length - 1];
        _creds.pop();
        emit AdditionCancelled(id, due);
    }

    /// Signed by ANOTHER credential in effect; effective after 24 hours unless cancelled. At least one
    /// credential always remains, counting every removal already pending.
    function proposeRemoval(Credential calldata c, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        bytes32 signer = _recordChange(
            keccak256(abi.encode(REMOVE_CREDENTIAL_TYPEHASH, c.kind, c.x, c.y, nonce, deadline)), nonce, deadline, signature
        );
        bytes32 id = credentialId(c);
        if (!_inEffect(id)) revert NotMember(); // a pending addition is cancelled, not removed
        if (signer == id) revert SelfRemoval();
        if (_removalDue[id] != 0) revert AlreadyPending();
        if (_standing() < 2) revert LastCredential();
        uint256 due = block.timestamp + DELAY;
        _removalDue[id] = due;
        _removalBy[id] = signer;
        emit RemovalProposed(id, due);
    }

    /// Any current credential, before the removal takes effect, but NOT the credential being removed
    /// (decision 31): with two or more others standing, the owner's honest credentials decide. The
    /// one exception is a removal that would leave a single credential standing (removals pending
    /// counted, EXCEPT those the canceller itself proposed: its own proposals can't make the
    /// exception): there the target may cancel its own, so a thief who proposes first can't win the
    /// account from the owner's last other credential, and the two stand off. No nonce: it names the
    /// removal.
    function cancelRemoval(Credential calldata c, uint256 due, uint256 deadline, bytes calldata signature) external {
        bytes32 signer =
            _cancel(keccak256(abi.encode(CANCEL_REMOVAL_TYPEHASH, c.kind, c.x, c.y, due, deadline)), deadline, signature);
        bytes32 id = credentialId(c);
        if (due == 0 || _removalDue[id] != due) revert NothingPending();
        if (signer == id && _standingFor(id) != 1) revert SelfCancel();
        delete _removalDue[id];
        delete _removalBy[id];
        emit RemovalCancelled(id, due);
    }

    /// Effective after 24 hours unless cancelled, the first time too (decisions 15, 32): a compromised
    /// web2 can't make an attacker's address live at once through a passkey's blind signature. A new
    /// proposal replaces a pending one and restarts its 24 hours.
    function setWithdrawalAddress(address next, uint256 nonce, uint256 deadline, bytes calldata signature) external {
        _recordChange(keccak256(abi.encode(SET_WITHDRAWAL_ADDRESS_TYPEHASH, next, nonce, deadline)), nonce, deadline, signature);
        if (next == address(0)) revert ZeroAddress();
        uint256 due = block.timestamp + DELAY;
        _pendingWithdrawal = next;
        _pendingWithdrawalDue = uint64(due);
        emit WithdrawalAddressProposed(next, due);
    }

    /// Any current credential, before the change takes effect. No nonce: it names the change.
    function cancelWithdrawalAddress(address next, uint256 due, uint256 deadline, bytes calldata signature) external {
        _cancel(keccak256(abi.encode(CANCEL_WITHDRAWAL_ADDRESS_TYPEHASH, next, due, deadline)), deadline, signature);
        if (due == 0 || _pendingWithdrawalDue != due || _pendingWithdrawal != next) revert NothingPending();
        _pendingWithdrawal = address(0);
        _pendingWithdrawalDue = 0;
        emit WithdrawalAddressCancelled(next, due);
    }

    // ── the record's copies (§7.3) ───────────────────────────────────────────────────────────

    /// Anyone, at the home: sends the whole record in effect and its version to this same address on
    /// `domain`, through Circle's MessageTransmitterV2 (no burn, no fee, finalized, any relayer).
    function publish(uint32 domain) external {
        if (_creds.length == 0) revert NotInitialised(); // the implementation, never an account
        if (!isHome()) revert NotHome();
        if (domain == HOME_DOMAIN) revert BadDomain();
        _settle();
        bytes32 self = bytes32(uint256(uint160(address(this))));
        IMessageTransmitterV2(MESSAGE_TRANSMITTER).sendMessage(
            domain,
            self,
            bytes32(0),
            FINALIZED,
            abi.encode(RECORD_TAG, _version, uint64(block.timestamp), _withdrawal, credentials())
        );
        emit Published(domain, _version);
    }

    /// Circle's V2 handler, at a copy: the home's own record, finalized. The first one is taken at any
    /// version if the home published it at or after this copy's deployment; afterwards only a strictly
    /// higher version. Anything else from the home is ignored (and the message consumed), never
    /// reverted.
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool) {
        if (msg.sender != MESSAGE_TRANSMITTER) revert NotTransmitter();
        if (_creds.length == 0) revert NotInitialised(); // the implementation, never an account
        if (isHome()) revert NotCopy();
        if (sourceDomain != HOME_DOMAIN || sender != bytes32(uint256(uint160(address(this))))) revert NotHomeMessage();
        if (finalityThresholdExecuted < FINALIZED) revert NotFinalized();
        if (messageBody.length < 32) revert BadMessage();
        if (bytes32(messageBody[:32]) == AUTH_TAG) return _receiveAuthorisation(messageBody);
        (bytes32 tag, uint64 v, uint64 publishedAt, address w, Credential[] memory creds) =
            abi.decode(messageBody, (bytes32, uint64, uint64, address, Credential[]));
        if (tag != RECORD_TAG) revert BadMessage();
        if (_synced) {
            // afterwards, only a strictly higher version
            if (v <= _version) {
                emit RecordIgnored(v, _version);
                return true;
            }
        } else if (publishedAt < _deployedAt) {
            // the first record, at any version, but only one published since this copy exists: a
            // message sent before (perhaps by a credential since removed) is ignored, and re-sent
            emit RecordIgnored(v, _version);
            return true;
        }
        if (creds.length == 0 || creds.length > MAX_CREDENTIALS) revert BadMessage();
        delete _creds;
        for (uint256 i; i < creds.length; ++i) {
            // the shape only: whether a wallet has code is the home's check, at the home
            if (!_validCredential(creds[i], false)) revert BadMessage();
            _creds.push(creds[i]);
        }
        _withdrawal = w;
        _version = v;
        _synced = true;
        emit RecordApplied(v);
        return true;
    }

    /// An authorisation from the home (amendment 1, §2.4), at a synced copy only (its withdrawal address
    /// and credentials come from the record; an unsynced copy reverts, so the message stays relayable):
    /// each id once, adding its allowance and trusting its factory on this chain.
    function _receiveAuthorisation(bytes calldata body) internal returns (bool) {
        if (!_synced) revert NotSynced();
        (, uint256 id, address vaultFactory, bytes32 strategyId, bytes32 configHash, uint256 amount) =
            abi.decode(body, (bytes32, uint256, address, bytes32, bytes32, uint256));
        if (authorisationApplied[id]) {
            emit AuthorisationIgnored(id);
            return true;
        }
        (address usdc, uint32 local) = cctpUsdc();
        if (vaultFactory == address(0) || configHash == bytes32(0) || usdc == address(0)) revert BadMessage();
        authorisationApplied[id] = true;
        Trust storage t = _trust[trustKey(vaultFactory, local)];
        if (t.due == 0) {
            t.due = uint64(block.timestamp);
            t.epoch += 1;
        }
        bytes32 key = vaultKey(vaultFactory, strategyId, configHash);
        uint256 held = allowance[key];
        uint256 remaining = amount > type(uint256).max - held ? type(uint256).max : held + amount; // saturates
        allowance[key] = remaining;
        emit AuthorisationApplied(id, key, amount, remaining);
        return true;
    }

    /// A record is accepted finalized only.
    function handleReceiveUnfinalizedMessage(uint32, bytes32, uint32, bytes calldata) external pure returns (bool) {
        revert NotFinalized();
    }

    // ── local owner actions (§7.2: the chain named, the signer's nonce here) ──────────────────

    function revokeTransfer(uint256 nonce, uint256 deadline, bytes calldata signature) external {
        _localAction(keccak256(abi.encode(REVOKE_TRANSFER_TYPEHASH, block.chainid, nonce, deadline)), nonce, deadline, signature);
        transferRevoked = true;
        emit TransferRevoked(true);
    }

    function allowTransfer(uint256 nonce, uint256 deadline, bytes calldata signature) external {
        _localAction(keccak256(abi.encode(ALLOW_TRANSFER_TYPEHASH, block.chainid, nonce, deadline)), nonce, deadline, signature);
        transferRevoked = false;
        emit TransferRevoked(false);
    }

    /// At the home only (amendment 1, §2.1): the owner's authorisation of `g.allowance` USDC, on the
    /// deposit chain of `g.domain`, for the one vault of `g.vaultFactory` with `g.strategyId` and
    /// `g.configHash`. It gets an id (a counter per account), the same in every dispatch. A factory not
    /// yet trusted FOR THAT DOMAIN becomes trusted for it 24 hours after the first authorisation naming
    /// the pair, cancellable until then (`cancelTrust`); later ones wait for that same trust. One grant
    /// is at most MAX_GRANT. For domain 3 the allowance is added
    /// here once the trust is in effect (at once, or by `applyAuthorisation`); for another domain it is
    /// only recorded, for `dispatchAuthorisation`.
    function authoriseStrategy(StrategyGrant calldata g, bytes calldata signature) external returns (uint256 id) {
        if (!isHome()) revert NotHome();
        _localAction(
            keccak256(
                abi.encode(
                    AUTHORISE_STRATEGY_TYPEHASH,
                    block.chainid,
                    g.vaultFactory,
                    g.domain,
                    g.strategyId,
                    g.configHash,
                    g.allowance,
                    g.nonce,
                    g.deadline
                )
            ),
            g.nonce,
            g.deadline,
            signature
        );
        if (g.vaultFactory == address(0) || g.configHash == bytes32(0) || g.allowance == 0 || g.allowance > MAX_GRANT) {
            revert BadAmount();
        }
        if (!_depositDomain(g.domain)) revert BadDomain();
        Trust storage t = _trust[trustKey(g.vaultFactory, g.domain)];
        if (t.due == 0) {
            t.due = uint64(block.timestamp + DELAY);
            t.epoch += 1;
            emit TrustProposed(g.vaultFactory, g.domain, t.due, t.epoch);
        }
        id = ++authorisationCount;
        _grants[id] = Grant(g.vaultFactory, g.domain, false, g.strategyId, g.configHash, g.allowance, t.epoch);
        emit StrategyAuthorised(id, g.vaultFactory, g.domain, g.strategyId, g.configHash, g.allowance, t.due, t.epoch);
        if (g.domain == HOME_DOMAIN && _due(t.due)) _apply(id);
    }

    /// Anyone, at the home: adds a domain-3 authorisation made while its factory's trust was pending,
    /// once that same trust is in effect.
    function applyAuthorisation(uint256 id) external {
        if (!isHome()) revert NotHome();
        Grant storage g = _grants[id];
        if (g.vaultFactory == address(0)) revert NoGrant();
        if (g.domain != HOME_DOMAIN) revert BadDomain();
        if (g.applied) revert AlreadyApplied();
        if (!_trustedUnder(g)) revert NotTrusted();
        _apply(id);
    }

    /// Anyone, at the home, as often as needed (a message lost or expired): sends authorisation `id`
    /// for another deposit chain to this same address there, once its factory's trust is in effect.
    /// The copy applies each id once.
    function dispatchAuthorisation(uint256 id) external {
        if (!isHome()) revert NotHome();
        Grant storage g = _grants[id];
        if (g.vaultFactory == address(0)) revert NoGrant();
        if (g.domain == HOME_DOMAIN) revert BadDomain();
        if (!_trustedUnder(g)) revert NotTrusted();
        IMessageTransmitterV2(MESSAGE_TRANSMITTER).sendMessage(
            g.domain,
            bytes32(uint256(uint160(address(this)))),
            bytes32(0),
            FINALIZED,
            abi.encode(AUTH_TAG, id, g.vaultFactory, g.strategyId, g.configHash, g.allowance)
        );
        emit AuthorisationDispatched(id, g.domain);
    }

    /// Any credential in effect, before a (factory, domain) pending trust takes effect: it voids every
    /// authorisation granted under it, for good (their epoch never comes back). No nonce: it names the
    /// trust and its due time.
    function cancelTrust(address vaultFactory, uint32 domain, uint256 due, uint256 deadline, bytes calldata signature)
        external
    {
        _cancel(keccak256(abi.encode(CANCEL_TRUST_TYPEHASH, vaultFactory, domain, due, deadline)), deadline, signature);
        Trust storage t = _trust[trustKey(vaultFactory, domain)];
        if (due == 0 || t.due != due || block.timestamp >= due) revert NothingPending();
        t.due = 0;
        emit TrustCancelled(vaultFactory, domain, due);
    }

    // ── money (§8.2) ─────────────────────────────────────────────────────────────────────────

    /// Pays `amount` of `token` (zero: the native coin) to the withdrawal address, with no fee. By a
    /// wallet credential itself, by the transfer key unless revoked, and by ANYONE once the transfer
    /// key has not checked in for 7 days (the escape hatch, decision 17).
    function withdraw(address token, uint256 amount) external nonReentrant {
        _settle();
        IDepositFactory f = IDepositFactory(factory);
        bool allowed = _isCredential(_walletId(msg.sender)) || (msg.sender == f.transferKey() && !transferRevoked)
            || f.stopped();
        if (!allowed) revert NotAllowed();
        address to = _withdrawal;
        if (to == address(0)) revert NoWithdrawalAddress();
        _send(token, to, amount);
        emit Withdrawn(token, to, amount, 0, msg.sender);
    }

    /// The owner's signed withdrawal, submitted by anyone: `w.amount` leaves, `fee` of it (at most the
    /// signed `w.maxFee` and the compiled cap, `_feeCap`) to the factory's fee recipient and the rest to
    /// the withdrawal address (decision 19). Both destinations are signed and must still be the ones in
    /// effect: a signature played after the withdrawal address or the fee recipient changed reverts.
    /// Consumed once.
    function withdrawSigned(Withdrawal calldata w, uint256 fee, bytes calldata signature) external nonReentrant {
        _localAction(
            keccak256(
                abi.encode(
                    WITHDRAW_TYPEHASH,
                    block.chainid,
                    w.token,
                    w.amount,
                    w.to,
                    w.maxFee,
                    w.feeRecipient,
                    w.nonce,
                    w.deadline
                )
            ),
            w.nonce,
            w.deadline,
            signature
        );
        if (fee > w.maxFee || fee > w.amount || fee > _feeCap(w.token)) revert FeeAboveMax();
        address to = _withdrawal;
        if (to == address(0)) revert NoWithdrawalAddress();
        if (w.to != to) revert NotWithdrawalAddress();
        address recipient = IDepositFactory(factory).feeRecipient();
        if (w.feeRecipient != recipient) revert NotFeeRecipient();
        if (fee != 0) {
            if (recipient == address(0)) revert NoFeeRecipient();
            _send(w.token, recipient, fee);
        }
        _send(w.token, to, w.amount - fee);
        emit Withdrawn(w.token, to, w.amount - fee, fee, msg.sender);
    }

    /// Transfer key only (amendment 1, §2.3): pays `amount` of this chain's USDC to `vault`, a deployed
    /// vault that `vaultFactory` (trusted by this account on this chain) registered to THIS account,
    /// within the allowance the owner authorised for that factory, strategy and configuration, and
    /// only once a withdrawal address is in effect (§8.2).
    function fund(address vaultFactory, address vault, uint256 amount) external nonReentrant {
        _settle();
        _transferKeyOnly();
        if (_withdrawal == address(0)) revert NoWithdrawalAddress();
        (address usdc, uint32 local) = cctpUsdc();
        if (usdc == address(0)) revert ConversionUnavailable();
        if (!isTrusted(vaultFactory, local)) revert NotTrusted();
        if (vault.code.length == 0) revert NotOwnVault();
        (address owner, bytes32 strategyId, bytes32 configHash) = IVaultFactory(vaultFactory).authorisedFor(vault);
        if (owner != address(this) || configHash == bytes32(0)) revert NotOwnVault();
        bytes32 key = vaultKey(vaultFactory, strategyId, configHash);
        uint256 left = allowance[key];
        if (amount > left) revert AllowanceExceeded();
        allowance[key] = left - amount;
        _send(usdc, vault, amount);
        emit Funded(vault, vaultFactory, strategyId, amount);
    }

    /// Transfer key only: USDT → USDC in this chain's pinned 0.01% pool, paid to this account. The
    /// minimum out is raised to amount × (1 − CONVERSION_BOUND_BP) (decision 30: 1 USD per USDT).
    function convertSwap(uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        _transferKeyOnly();
        (address pool, address usdt, address usdc) = conversionPool();
        if (pool == address(0)) revert ConversionUnavailable();
        uint256 floor = amountIn * (10_000 - CONVERSION_BOUND_BP) / 10_000;
        if (floor == 0 || amountIn > uint256(type(int256).max)) revert BadAmount();
        if (minOut < floor) minOut = floor;
        bool zeroForOne = usdt < usdc; // the pool's token0 is the lower address
        uint256 before = _balanceOf(usdc);
        _swapIn = amountIn;
        IUniswapV3Pool(pool).swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, ""
        );
        _swapIn = 0;
        out = _balanceOf(usdc) - before;
        if (out < minOut) revert BelowMinimum();
        emit Swapped(amountIn, out);
    }

    /// The pinned pool's callback, during `convertSwap` only: pays it the USDT it is owed, never more
    /// than the swap's amount in.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        (address pool, address usdt, address usdc) = conversionPool();
        uint256 limit = _swapIn;
        if (msg.sender != pool || pool == address(0) || limit == 0) revert NotAllowed();
        int256 owed = usdt < usdc ? amount0Delta : amount1Delta;
        if (owed <= 0 || uint256(owed) > limit) revert BadAmount();
        _swapIn = 0; // one payment per swap
        _send(usdt, pool, uint256(owed));
    }

    /// Transfer key only: burns `amount` of this chain's USDC by CCTP V2 (standard transfer), minted to
    /// THIS same address on another deposit chain; anyone may relay the mint. Its `maxFee` is the
    /// messenger's minimum fee for the amount, read now (0 where the messenger has none), and never
    /// above BURN_FEE_CAP_BP of the amount.
    function convertBurn(uint256 amount, uint32 destinationDomain) external nonReentrant {
        _transferKeyOnly();
        (address usdc, uint32 local) = cctpUsdc();
        if (usdc == address(0)) revert ConversionUnavailable();
        if (destinationDomain == local || !_depositDomain(destinationDomain)) revert BadDomain();
        if (amount == 0) revert BadAmount();
        uint256 maxFee = burnMinFee(amount);
        if (maxFee * 10_000 > amount * BURN_FEE_CAP_BP) revert BurnFeeTooHigh();
        _approve(usdc, TOKEN_MESSENGER, amount);
        ITokenMessengerV2(TOKEN_MESSENGER).depositForBurn(
            amount, destinationDomain, bytes32(uint256(uint160(address(this)))), usdc, bytes32(0), maxFee, FINALIZED
        );
        _approve(usdc, TOKEN_MESSENGER, 0);
        emit Burned(destinationDomain, amount, maxFee);
    }

    /// The messenger's minimum fee for burning `amount` (`getMinFeeAmount`, selector 0x516990e3, on
    /// HyperEVM's TokenMessengerV2 since 2026), or 0 where it has no such function (Arbitrum's, read
    /// 2026-10-14) or answers nothing readable.
    function burnMinFee(uint256 amount) public view returns (uint256) {
        (bool ok, bytes memory ret) = TOKEN_MESSENGER.staticcall(abi.encodeWithSelector(0x516990e3, amount));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// This chain's pinned USDT → USDC conversion (step 11e1's chain files; zeros where none).
    function conversionPool() public view returns (address pool, address usdt, address usdc) {
        uint256 id = block.chainid;
        if (id == 1) {
            return (
                0x3416cF6C708Da44DB2624D63ea0AAef7113527C6,
                0xdAC17F958D2ee523a2206206994597C13D831ec7,
                0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
            );
        }
        if (id == 42161) {
            return (
                0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6,
                0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
                0xaf88d065e77c8cC2239327C5EDb3A432268e5831
            );
        }
        if (id == 137) {
            return (
                0x31083a78E11B18e450fd139F9ABEa98CD53181B7,
                0xc2132D05D31c914a87C6611C10748AEb04B58e8F,
                0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
            );
        }
    }

    /// This chain's Circle USDC and CCTP domain (zeros where the account burns nothing).
    function cctpUsdc() public view returns (address usdc, uint32 domain) {
        uint256 id = block.chainid;
        if (id == 1) return (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0);
        if (id == 10) return (0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, 2);
        if (id == 42161) return (0xaf88d065e77c8cC2239327C5EDb3A432268e5831, 3);
        if (id == 8453) return (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 6);
        if (id == 137) return (0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359, 7);
        if (id == 999) return (0xb88339CB7199b77E23DB6E890353E22632Ba630f, 19);
    }

    // ── internals ────────────────────────────────────────────────────────────────────────────

    /// The deposit chains a burn may mint on and an authorisation may name, where this address is the
    /// same user's account: Ethereum 0, OP Mainnet 2, Arbitrum 3, Base 6, Polygon 7, HyperEVM 19.
    /// Never a non-EVM domain, where the address would mean nothing.
    function _depositDomain(uint32 d) internal pure returns (bool) {
        return d == 0 || d == 2 || d == 3 || d == 6 || d == 7 || d == 19;
    }

    /// The most a signed withdrawal of `token` may pay as its fee (decision 73): `MAX_SIGNED_FEE` for
    /// this chain's USDC and its pinned USDT, zero for any other token. Never the zero address (the
    /// native coin), which is what `conversionPool()` names as USDT on a chain without one.
    function _feeCap(address token) internal view returns (uint256) {
        if (token == address(0)) return 0;
        (address usdc,) = cctpUsdc();
        (, address usdt,) = conversionPool();
        return token == usdc || token == usdt ? MAX_SIGNED_FEE : 0;
    }

    /// A grant's (factory, domain) is trusted, under the very trust (epoch) the grant was made under.
    function _trustedUnder(Grant storage g) internal view returns (bool) {
        Trust storage t = _trust[trustKey(g.vaultFactory, g.domain)];
        return t.due != 0 && t.epoch == g.trustEpoch && block.timestamp >= t.due;
    }

    function _apply(uint256 id) internal {
        Grant storage g = _grants[id];
        g.applied = true;
        bytes32 key = vaultKey(g.vaultFactory, g.strategyId, g.configHash);
        uint256 remaining = allowance[key] + g.allowance;
        allowance[key] = remaining;
        emit AuthorisationApplied(id, key, g.allowance, remaining);
    }

    function _due(uint256 due) internal view returns (bool) {
        return due != 0 && block.timestamp >= due;
    }

    /// Applies the pending changes whose 24 hours have passed, each one a new version.
    function _settle() internal {
        uint256 wdue = _pendingWithdrawalDue;
        if (_due(wdue)) {
            address previous = _withdrawal;
            _withdrawal = _pendingWithdrawal;
            _pendingWithdrawal = address(0);
            _pendingWithdrawalDue = 0;
            emit WithdrawalAddressSet(previous, _withdrawal, ++_version);
        }
        uint256 i = _creds.length;
        while (i > 0) {
            --i;
            bytes32 id = credentialId(_creds[i]);
            if (_due(_addDue[id])) {
                delete _addDue[id];
                emit CredentialAdded(id, ++_version);
            }
            if (_due(_removalDue[id])) {
                delete _removalDue[id];
                delete _removalBy[id];
                _creds[i] = _creds[_creds.length - 1];
                _creds.pop();
                emit CredentialRemoved(id, ++_version);
            }
        }
    }

    function _indexOf(bytes32 id) internal view returns (uint256) {
        for (uint256 i; i < _creds.length; ++i) {
            if (credentialId(_creds[i]) == id) return i;
        }
        return type(uint256).max;
    }

    /// A member whose addition (if any) has taken effect and whose removal (if any) has not.
    function _inEffect(bytes32 id) internal view returns (bool) {
        if (_indexOf(id) == type(uint256).max) return false;
        uint256 added = _addDue[id];
        return (added == 0 || _due(added)) && !_due(_removalDue[id]);
    }

    /// Whom the account trusts now: nobody on a copy that hasn't received the home's record yet.
    function _isCredential(bytes32 id) internal view returns (bool) {
        return synced() && _inEffect(id);
    }

    /// For `canceller`'s self-cancel: the OTHER credentials in effect with no removal pending, a
    /// removal `canceller` proposed itself counting as none.
    function _standingFor(bytes32 canceller) internal view returns (uint256 n) {
        for (uint256 i; i < _creds.length; ++i) {
            bytes32 id = credentialId(_creds[i]);
            if (id == canceller || !_inEffect(id)) continue;
            if (_removalDue[id] == 0 || _removalBy[id] == canceller) ++n;
        }
    }

    /// The credentials in effect with no removal pending.
    function _standing() internal view returns (uint256 n) {
        for (uint256 i; i < _creds.length; ++i) {
            bytes32 id = credentialId(_creds[i]);
            if (_inEffect(id) && _removalDue[id] == 0) ++n;
        }
    }

    function _walletId(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(WALLET, bytes32(uint256(uint160(a))), bytes32(0)));
    }

    /// A wallet: a non-zero address, `y` zero, and (where `checkCode`) no contract code but an EIP-7702
    /// delegation's. A passkey: a point on P-256.
    function _validCredential(Credential memory c, bool checkCode) internal view returns (bool) {
        if (c.kind == WALLET) {
            if (c.y != bytes32(0) || uint256(c.x) >> 160 != 0 || c.x == bytes32(0)) return false;
            if (!checkCode) return true;
            address a = address(uint160(uint256(c.x)));
            uint256 size = a.code.length;
            if (size == 0) return true;
            // an EIP-7702 delegated EOA still signs with its key: 0xef0100 ‖ the delegate
            return size == 23 && bytes3(a.code) == 0xef0100;
        }
        if (c.kind == PASSKEY) return P256.isValidPublicKey(c.x, c.y);
        return false;
    }

    /// The id of the credential in effect that signed `digest`, or zero. Never reverts on a malformed
    /// signature.
    function _signer(bytes32 digest, bytes calldata sig) internal view returns (bytes32 id) {
        if (sig.length == 0) return bytes32(0);
        uint8 kind = uint8(sig[0]);
        if (kind == WALLET) {
            if (sig.length != 66) return bytes32(0);
            (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, sig[1:]);
            if (err != ECDSA.RecoverError.NoError || rec == address(0)) return bytes32(0);
            id = _walletId(rec);
        } else if (kind == PASSKEY) {
            if (sig.length < 65) return bytes32(0);
            bytes32 x = bytes32(sig[1:33]);
            bytes32 y = bytes32(sig[33:65]);
            (bool ok, WebAuthn.WebAuthnAuth calldata auth) = WebAuthn.tryDecodeAuth(sig[65:]);
            if (!ok) return bytes32(0);
            // user presence AND user verification (Face ID, Touch ID, Windows Hello, a PIN)
            if (!WebAuthn.verify(abi.encodePacked(digest), auth, x, y, true)) return bytes32(0);
            id = keccak256(abi.encode(PASSKEY, x, y));
        } else {
            return bytes32(0);
        }
        if (!_isCredential(id)) return bytes32(0);
    }

    function _check(bytes32 structHash, uint256 deadline, bytes calldata signature) internal view returns (bytes32 signer) {
        if (block.timestamp > deadline) revert Expired();
        signer = _signer(hashTypedData(structHash), signature);
        if (signer == bytes32(0)) revert BadSignature();
    }

    function _recordChange(bytes32 structHash, uint256 nonce, uint256 deadline, bytes calldata signature)
        internal
        returns (bytes32 signer)
    {
        if (!isHome()) revert NotHome();
        _settle();
        signer = _check(structHash, deadline, signature);
        if (nonce != _recordNonce[signer]) revert BadNonce();
        _recordNonce[signer] = nonce + 1;
    }

    function _cancel(bytes32 structHash, uint256 deadline, bytes calldata signature) internal returns (bytes32) {
        if (!isHome()) revert NotHome();
        _settle();
        return _check(structHash, deadline, signature);
    }

    function _localAction(bytes32 structHash, uint256 nonce, uint256 deadline, bytes calldata signature) internal {
        if (!synced()) revert NotSynced();
        _settle();
        bytes32 signer = _check(structHash, deadline, signature);
        if (nonce != _localNonce[signer]) revert BadNonce();
        _localNonce[signer] = nonce + 1;
    }

    function _transferKeyOnly() internal view {
        if (msg.sender != IDepositFactory(factory).transferKey() || transferRevoked) revert NotAllowed();
    }

    function _balanceOf(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || ret.length < 32) revert TransferFailed();
        return abi.decode(ret, (uint256));
    }

    /// A token transfer that accepts USDT's missing return value; the native coin for token zero.
    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            if (!sent) revert TransferFailed();
            return;
        }
        _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    function _approve(address token, address spender, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(0x095ea7b3, spender, amount));
    }

    function _call(address token, bytes memory data) internal {
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && (ret.length < 32 || !abi.decode(ret, (bool))))) revert TransferFailed();
    }
}
