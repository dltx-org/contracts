// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";

/*
 * What the user's deposit contract and its record module share — owner-upgrades-design.md §3.3.
 *
 * The account is a fixed ERC-1967 proxy (`DepositProxy`) running `DepositAccount`, which delegates the
 * owner record (its changes, its copies, the upgrade) to its module `DepositAccountRecord`. Both
 * contracts inherit this one: the constants, the events and errors, the helpers both use, and THE
 * STORAGE, one sequential layout from slot 0 (§A6, Q7: no ERC-7201 hash slot). Every later version
 * extends it, append only: no reorder, no type change, no reuse (I7). test.mjs checks the two
 * contracts' layouts are equal and that version 1's pinned layout file is a prefix of each.
 */

/// One owner credential. A wallet: kind 1, `x` the address left-padded, `y` zero. A passkey: kind 2,
/// `x` and `y` the P-256 public key's coordinates.
struct Credential {
    uint8 kind;
    bytes32 x;
    bytes32 y;
}

/// What the account reads from its factory (owner-upgrades-design.md §3.2, §A8).
interface IDepositFactory {
    function transferKey() external view returns (address);
    function feeRecipient() external view returns (address);
    /// True once `version`'s check-ins have stopped for 7 days: that version's escape hatch.
    function stopped(uint256 version) external view returns (bool);
    /// The listed version of an implementation, 0 for an unlisted address.
    function versionOf(address implementation) external view returns (uint256);
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

abstract contract DepositAccountState {
    // ── constants ────────────────────────────────────────────────────────────────────────────


    uint8 internal constant WALLET = 1;
    uint8 internal constant PASSKEY = 2;
    uint256 internal constant MAX_CREDENTIALS = 4;
    /// The flat fee of an exit the OWNER makes (its wallet credential's own `withdraw`, its signed
    /// `withdrawSigned`), to the factory's fee recipient, in the chain's USDC or its pinned USDT (both
    /// 6 decimals): 1 USD, never more, never settable (deposit-first-deposit-design.md, amendment E,
    /// replacing amendment 2d's 50 USDC cap). Any other token and the native coin pay none. When it is
    /// due, an amount at or below it is refused (`AmountNotAboveFee`). Not due with no fee recipient;
    /// skipped, all of it to the owner, when its transfer fails: a fee never blocks a withdrawal.
    uint256 public constant EXIT_FEE = 1e6;
    /// A credential's addition or removal, a later withdrawal-address change, a vault factory's first
    /// trust (but the pinned one's) and an upgrade take effect after this (§7.4, decision 15,
    /// owner-upgrades-design.md §3.4). The FIRST withdrawal address does not wait
    /// (deposit-first-deposit-design.md, D1).
    uint256 public constant DELAY = 24 hours;

    /// Arbitrum One: the home of the owner's record (decision 21), CCTP domain 3.
    uint256 internal constant HOME_CHAIN_ID = 42161;
    uint32 internal constant HOME_DOMAIN = 3;
    /// CCTP's finalized threshold: a record is sent and accepted at it only.
    uint32 internal constant FINALIZED = 2000;

    /// Circle's CCTP V2 contracts, the same address on every chain (§6; step 11e1's chain files).
    address internal constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    /// The conversion's bound against 1 USD per USDT (decision 30), in basis points: the minimum out
    /// of a swap is never below amount × (1 − 0.2%), 998 USDC per 1,000 USDT (the operator's decision,
    /// 2026-10-14; the pools quoted 998.95 on Ethereum and 998.97 on Arbitrum that day). USDT deposits
    /// are locked in the product for now; this stays so they can reopen on these same contracts.
    uint256 internal constant CONVERSION_BOUND_BP = 20;

    /// The most a CCTP burn may pay Circle, in basis points of the amount: the messenger's own minimum
    /// fee (`getMinFeeAmount`, which its controller may raise; HyperEVM's has one, 0 on 2026-10-14) is
    /// paid up to this, and a burn whose minimum is above it is refused (the USDC stays here).
    uint256 internal constant BURN_FEE_CAP_BP = 10;

    /// A copy trusts its record for this long after the home published it (the partner's audit M1): past
    /// it the copy reads as unsynced (no owner signature, no withdrawal) until the home's record, even
    /// unchanged, arrives again. It bounds how long a credential removed or an address replaced at the
    /// home stays usable on a chain the change has not reached.
    uint256 public constant RECORD_TTL = 30 days;
    /// A copy follows an upgrade message for this long after the home published it
    /// (owner-upgrades-design.md §3.5, Codex round 1): a message kept longer is ignored, and the home's
    /// current version published again.
    uint256 public constant UPGRADE_TTL = 3 days;

    /// Uniswap V3's price limits (TickMath), so an exact-input swap is limited by `minOut` alone.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// ERC-1967's implementation slot, bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1):
    /// written by the proxy's constructor and by the upgrade path of the record module only.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

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
    bytes32 public constant SCHEDULE_UPGRADE_TYPEHASH =
        keccak256("ScheduleUpgrade(address implementation,uint256 nonce,uint256 deadline)");
    // cancellations: at the home only, no nonce (the change and its due time name them)
    bytes32 public constant CANCEL_REMOVAL_TYPEHASH =
        keccak256("CancelRemoval(uint8 kind,bytes32 x,bytes32 y,uint256 due,uint256 deadline)");
    bytes32 public constant CANCEL_ADDITION_TYPEHASH =
        keccak256("CancelAddition(uint8 kind,bytes32 x,bytes32 y,uint256 due,uint256 deadline)");
    bytes32 public constant CANCEL_WITHDRAWAL_ADDRESS_TYPEHASH =
        keccak256("CancelWithdrawalAddress(address withdrawalAddress,uint256 due,uint256 deadline)");
    bytes32 public constant CANCEL_UPGRADE_TYPEHASH =
        keccak256("CancelUpgrade(address implementation,uint256 due,uint256 deadline)");
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

    /// Tags the record message's body, so no other message can ever be read as one. The three tags'
    /// formats are frozen for every version (owner-upgrades-design.md §3.6 rule 1).
    bytes32 public constant RECORD_TAG = keccak256("dltx.owner-record.v1");
    /// Tags an authorisation dispatched by the home to a copy (amendment 1, §2.4).
    bytes32 public constant AUTH_TAG = keccak256("dltx.owner-authorisation.v1");
    /// Tags the home's applied implementation sent to a copy (owner-upgrades-design.md §3.5).
    bytes32 public constant UPGRADE_TAG = keccak256("dltx.owner-upgrade.v1");

    /// The deposit factory whose list this code is looked up in, whose check-ins it reads and which
    /// initialises it: set in the constructor, read by a proxy from the implementation's code.
    address public immutable factory;

    // ── state (each account's own; append only, owner-upgrades-design.md I7) ─────────────────────

    bool internal _initialised;
    /// Re-entrancy lock for the money functions; the upgrade's two slot writers refuse while it is held.
    bool internal _entered;
    /// A copy has received the home's record at least once. Until then it trusts no credential: the
    /// genesis set may have changed at the home (README, Decisions). The home is always in sync.
    bool internal _synced;
    /// Whether the owner has revoked the transfer key here (a local action, per chain).
    bool public transferRevoked;
    /// The record's version: 0 is the genesis set (part of the address); +1 on each effective change.
    uint64 internal _version;
    /// When the account was deployed on this chain: a copy takes as its FIRST record only one the home
    /// published at or after this (README, Decisions), and follows no upgrade published before it.
    uint64 internal _deployedAt;
    /// When a pending withdrawal-address change takes effect (0: none).
    uint64 internal _pendingWithdrawalDue;
    /// When the home published the record a copy holds (0 on the home and on an unsynced copy).
    uint64 public recordPublishedAt;
    /// The UTC day of this chain's burn-fee budget, its cap (10 bp of the highest USDC balance seen at a
    /// fee-paying burn that day) and the fees paid (the partner's audit M3).
    uint256 internal _burnDay;
    uint256 internal _burnCap;
    uint256 internal _burnPaid;
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
    /// domain)): at the home, 24 hours after the first authorisation naming that pair (at once for the
    /// pinned factory on domain 3 or 19), cancellable until then, permanent once in effect; on a copy (its own domain), in effect when the home's
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
    /// The one pending upgrade (owner-upgrades-design.md §3.4, Q13: never replaced): its target, when
    /// it may be applied (0: none) and the credential that scheduled it. Home only.
    address internal _upgradeTo;
    uint64 internal _upgradeDue;
    bytes32 internal _upgradeBy;
    /// When the home published the last upgrade this copy applied (0: none yet). Copies only.
    uint64 internal _upgradePublishedAt;

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
    event UpgradeScheduled(address indexed implementation, uint256 version, uint256 due);
    event UpgradeCancelled(address indexed implementation, uint256 due);
    /// ERC-1967's event, emitted from the account's address when its code moves.
    event Upgraded(address indexed implementation);
    event UpgradePublished(uint32 indexed domain, address indexed implementation);
    event UpgradeIgnored(address indexed implementation, uint64 publishedAt);

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
    error AmountNotAboveFee();
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
    error BadModule();
    error BadImplementation();
    error RemovalPending();
    error NotDue();

    constructor(address factory_) {
        factory = factory_;
        _initialised = true; // the implementation and the module are never an account
    }

    // ── views both contracts need ────────────────────────────────────────────────────────────

    /// This code's version in its factory's list (owner-upgrades-design.md §3.2): the next number at
    /// its listing, a literal of each version (a later version, its main contract and its module alike,
    /// returns its own). Not the owner record's `version()`, which an upgrade does not touch.
    function CODE_VERSION() public pure virtual returns (uint256) {
        return 1;
    }

    /// The home holds the owner's record; every other chain's account is a copy of it.
    function isHome() public view returns (bool) {
        return block.chainid == HOME_CHAIN_ID;
    }

    /// The home always; a copy while the home's record it received was published within RECORD_TTL. An
    /// unsynced copy (never reached, or expired) accepts no owner signature, no local action and no
    /// withdrawal, and names no withdrawal address.
    function synced() public view returns (bool) {
        return isHome() || (_synced && block.timestamp <= uint256(recordPublishedAt) + RECORD_TTL);
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

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, address(this)));
    }

    /// The EIP-712 digest of a struct in this account's "DLTX Owner" domain: what a credential signs.
    function hashTypedData(bytes32 structHash) public view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
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
        if (id == 43114) return (0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, 1);
        if (id == 10) return (0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, 2);
        if (id == 42161) return (0xaf88d065e77c8cC2239327C5EDb3A432268e5831, 3);
        if (id == 8453) return (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 6);
        if (id == 137) return (0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359, 7);
        if (id == 999) return (0xb88339CB7199b77E23DB6E890353E22632Ba630f, 19);
    }

    // ── internals ────────────────────────────────────────────────────────────────────────────

    /// The code this account runs: the ERC-1967 slot (zero in the implementation and the module).
    function _implementation() internal view returns (address impl) {
        assembly ("memory-safe") {
            impl := sload(IMPLEMENTATION_SLOT)
        }
    }

    /// Writes the ERC-1967 slot and emits ERC-1967's event. Called by the record module's two slot
    /// writers only (`applyUpgrade`, a copy's upgrade message), from an initialised account.
    function _writeImplementation(address impl) internal {
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION_SLOT, impl)
        }
        emit Upgraded(impl);
    }

    /// The deposit chains a burn may mint on and an authorisation may name, where this address is the
    /// same user's account: Ethereum 0, Avalanche 1, OP Mainnet 2, Arbitrum 3, Base 6, Polygon 7,
    /// HyperEVM 19. Never a non-EVM domain, where the address would mean nothing.
    function _depositDomain(uint32 d) internal pure returns (bool) {
        return d <= 3 || d == 6 || d == 7 || d == 19;
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
}
