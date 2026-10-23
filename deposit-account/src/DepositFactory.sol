// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {DepositAccount} from "./DepositAccount.sol";
import {DepositAccountRecord} from "./DepositAccountRecord.sol";
import {Credential} from "./DepositAccountState.sol";
import {DepositProxy, IProxyMaker} from "./DepositProxy.sol";
import {ProxyInitCode} from "./ProxyInitCode.sol";

/// What the listing reads from a proposed implementation and its module (owner-upgrades-design.md §3.2).
interface IDepositVersion {
    function factory() external view returns (address);
    function module() external view returns (address);
    function CODE_VERSION() external view returns (uint256);
}

/// A successor factory names the factory it continues (§A9).
interface IDepositFactorySuccessor {
    function predecessor() external view returns (address);
}

/*
 * The deposit factory — step-11e2-strategy-vault-design.md §8.1, owner-upgrades-design.md §3.2.
 *
 * Created through the deterministic deployer (0x4e59…956C) with the same salt and the same
 * constructor arguments on every chain. Its constructor creates version 1 of the deposit contract (the
 * GENESIS: its record module, then `DepositAccount`, by CREATE at nonces 1 and 2), so the factory, the
 * genesis and every user's account land at the same address everywhere.
 *
 * A user's account is a `DepositProxy` (ERC-1967) at CREATE2 salt keccak256(abi.encode(user, owners)):
 * the user's uuid (left-padded to 32 bytes, as step 11e1's) and their FIRST owner set (decision 22).
 * ANYONE may deploy it, on any chain; it always starts with that owner set and ON THE GENESIS (Q0),
 * whatever is listed since, so nobody chooses the code of an account its owner has not signed for. It
 * moves to a later listed version only by its owner's signed `ScheduleUpgrade` (the account's record
 * module).
 *
 * THE LIST of allowed versions is append only, written by the RECOVERY key alone behind a public
 * 7-day delay: propose, then accept, in version order (several proposals may run at once), each
 * proposal withdrawable before its acceptance. Nothing removes a version. Recovery cannot move an
 * account, deploy one on anything but the genesis, sign for an owner or move money.
 *
 * The only constructor argument, so part of every address: the operator's offline RECOVERY key, which
 * may set the transfer key, the fee recipient, its own successor (two steps) and list versions, and
 * nothing else. No vault factory is named here (amendment 1): each account trusts the factories its
 * owner authorises.
 *
 * The TRANSFER KEY (step 11e1's relayer, a KMS key) is unset until recovery sets it on each chain,
 * then rotated by itself or recovery. It CHECKS IN daily, PER VERSION (§A8); `stopped(version)` is true
 * after 7 days without that version's check-in, counted from its listing until the first one
 * (decision 17; the genesis from this factory's deployment). Then anyone may run the withdrawal of an
 * account on that version to its fixed address. The genesis is checked in for this factory's whole
 * life (§A8): every account starts on it.
 */
contract DepositFactory is IProxyMaker {
    uint256 public constant STOP_AFTER = 7 days;
    /// A proposed version is accepted no sooner than this after its proposal (§3.2, Q6).
    uint256 public constant LISTING_DELAY = 7 days;
    /// The most factories a listed version's own factory may descend from this one by (§A9).
    uint256 public constant MAX_SUCCESSIONS = 8;
    /// This factory continues no other (§A9): its list starts at version 1, the genesis.
    address public constant predecessor = address(0);

    /// Version 1, created by the constructor: the code every account deploys on.
    address public immutable genesis;
    /// The platform's KMS key (step 11e1's relayer). Unset until recovery sets it.
    address public transferKey;
    /// The operator's offline key: the transfer key, the fee recipient, its own handover, the listing;
    /// nothing else.
    address public recovery;
    /// A recovery key proposed by recovery, effective when it accepts.
    address public pendingRecovery;
    /// Where an owner-signed withdrawal's fee goes (decision 19). Zero: no fee can be taken.
    address public feeRecipient;
    /// Each version's last check-in: its listing until the first (the genesis: this deployment).
    mapping(uint256 version => uint256 at) public lastCheckIn;
    /// The listed version of an implementation (1 for the genesis), 0 for an unlisted address.
    mapping(address implementation => uint256 version) public versionOf;
    /// A pending listing: when recovery may accept it (0: none) and the code hash it was proposed with.
    mapping(address implementation => Proposal) public proposals;

    struct Proposal {
        uint64 due;
        bytes32 codeHash;
    }

    /// The listed implementations, version n at index n − 1.
    address[] internal _list;

    event Deployed(bytes32 indexed user, address indexed account, bytes32 salt);
    event TransferKeySet(address indexed previous, address indexed next, address indexed by);
    event CheckedIn(address indexed key, uint256 indexed version, uint256 at);
    event FeeRecipientSet(address indexed previous, address indexed next);
    event RecoveryProposed(address indexed current, address indexed proposed);
    event RecoverySet(address indexed previous, address indexed next);
    event ImplementationProposed(address indexed implementation, uint256 codeVersion, bytes32 codeHash, uint256 due);
    event ImplementationWithdrawn(address indexed implementation);
    event ImplementationListed(address indexed implementation, uint256 indexed version);

    error NotAllowed();
    error ZeroAddress();
    error DeployFailed();
    error BadImplementation();
    error AlreadyListed();
    error AlreadyPending();
    error NothingPending();
    error NotDue();
    error BadVersion();

    constructor(address recovery_) {
        if (recovery_ == address(0)) revert ZeroAddress();
        address m = address(new DepositAccountRecord(address(this)));
        address g = address(new DepositAccount(address(this), m, m.codehash));
        genesis = g;
        _list.push(g);
        versionOf[g] = 1;
        recovery = recovery_;
        lastCheckIn[1] = block.timestamp;
        emit ImplementationListed(g, 1);
    }

    // ── the accounts ─────────────────────────────────────────────────────────────────────────

    /// The salt of a user's account: their uuid (left-padded) and their first owner set, in order.
    function saltOf(bytes32 user, Credential[] calldata owners) public pure returns (bytes32) {
        return keccak256(abi.encode(user, owners));
    }

    /// The user's account address for this first owner set, deployed or not: CREATE2 of the proxy's
    /// init code, whatever versions are listed.
    function addressOf(bytes32 user, Credential[] calldata owners) external view returns (address) {
        return _predict(saltOf(user, owners));
    }

    /// What a proxy this factory creates runs first: the genesis, always (Q0).
    function proxyImplementation() external view returns (address) {
        return genesis;
    }

    /// Anyone: deploys the user's account with its first owner set, on the genesis, or returns it if it
    /// exists. Refused if the set is not a well-shaped owner set (exactly one credential since
    /// amendment 2d's decision 76: a point on P-256 or a non-zero address). No code is checked here, so
    /// an account can always be deployed where money already waits at its address; EOA-only is
    /// enforced before an address is shown.
    function deploy(bytes32 user, Credential[] calldata owners) external returns (address account) {
        bytes32 salt = saltOf(user, owners);
        account = _predict(salt);
        if (account.code.length != 0) return account;
        if (address(new DepositProxy{salt: salt}()) != account) revert DeployFailed();
        DepositAccount(account).initialize(owners);
        emit Deployed(user, account, salt);
    }

    function _predict(bytes32 salt) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, ProxyInitCode.HASH)))));
    }

    // ── the list of versions (§3.2) ──────────────────────────────────────────────────────────

    /// The highest listed version (the genesis is 1).
    function versions() public view returns (uint256) {
        return _list.length;
    }

    /// The implementation of listed version `n` (1-based); reverts for an unlisted number.
    function implementationAt(uint256 n) external view returns (address) {
        if (n == 0 || n > _list.length) revert BadVersion();
        return _list[n - 1];
    }

    /// The last listed version: what the web may offer once DLTX released it (§4.3), never what
    /// `deploy` uses.
    function latest() external view returns (address) {
        return _list[_list.length - 1];
    }

    /// Recovery: proposes `impl` as a later version, accepted no sooner than 7 days from now. It must
    /// have code, be neither listed nor already proposed, name this factory (or a successor descending
    /// from it, each naming the one before as its predecessor, §A9) as its own, as its module must
    /// too, and carry a CODE_VERSION above every listed version, its module's the same (an account's
    /// forward-only rule reads it).
    function proposeImplementation(address impl) external {
        if (msg.sender != recovery) revert NotAllowed();
        if (impl.code.length == 0) revert BadImplementation();
        if (versionOf[impl] != 0) revert AlreadyListed();
        if (proposals[impl].due != 0) revert AlreadyPending();
        // its factory is this one or descends from it (§A9), by at most MAX_SUCCESSIONS predecessors: a
        // copy deployed here after several successions can then follow its home to any later version
        // (Codex, slice 1), once recovery lists that version here too
        address own = IDepositVersion(impl).factory();
        address at = own;
        for (uint256 i; at != address(this); ++i) {
            if (i == MAX_SUCCESSIONS || at.code.length == 0) revert BadImplementation();
            at = IDepositFactorySuccessor(at).predecessor();
        }
        address m = IDepositVersion(impl).module();
        if (IDepositVersion(m).factory() != own) revert BadImplementation();
        uint256 codeVersion = IDepositVersion(impl).CODE_VERSION();
        // the module's forward-only checks read its own literal: it must be the version's
        if (codeVersion <= _list.length || IDepositVersion(m).CODE_VERSION() != codeVersion) revert BadVersion();
        uint256 due = block.timestamp + LISTING_DELAY;
        proposals[impl] = Proposal(uint64(due), impl.codehash);
        emit ImplementationProposed(impl, codeVersion, impl.codehash, due);
    }

    /// Recovery withdraws a pending proposal (a defect found in the 7 days).
    function withdrawImplementation(address impl) external {
        if (msg.sender != recovery) revert NotAllowed();
        if (proposals[impl].due == 0) revert NothingPending();
        delete proposals[impl];
        emit ImplementationWithdrawn(impl);
    }

    /// Recovery, at or after a proposal's due time, its code hash unchanged, in version order (its
    /// CODE_VERSION the next number): appends it, and starts its check-in clock now (§A3), so it is not
    /// stopped on arrival.
    function acceptImplementation(address impl) external {
        if (msg.sender != recovery) revert NotAllowed();
        Proposal memory p = proposals[impl];
        if (p.due == 0) revert NothingPending();
        if (block.timestamp < p.due) revert NotDue();
        if (impl.codehash != p.codeHash) revert BadImplementation();
        uint256 v = _list.length + 1;
        if (IDepositVersion(impl).CODE_VERSION() != v) revert BadVersion();
        delete proposals[impl];
        _list.push(impl);
        versionOf[impl] = v;
        lastCheckIn[v] = block.timestamp;
        emit ImplementationListed(impl, v);
    }

    // ── the transfer key and the escape hatch ────────────────────────────────────────────────

    /// Recovery (the first setting on a chain, or a lost or stolen key), or the key itself (a planned
    /// rotation). Setting a key is not a check-in.
    function setTransferKey(address next) external {
        if (msg.sender != transferKey && msg.sender != recovery) revert NotAllowed();
        if (next == address(0)) revert ZeroAddress();
        emit TransferKeySet(transferKey, next, msg.sender);
        transferKey = next;
    }

    /// The transfer key, daily, for each version DLTX still supports (decision 17, §A8): one version's
    /// support ends alone, by leaving it out.
    function checkIn(uint256[] calldata versions_) external {
        if (msg.sender != transferKey) revert NotAllowed(); // never the zero address: no sender is
        for (uint256 i; i < versions_.length; ++i) {
            uint256 v = versions_[i];
            if (v == 0 || v > _list.length) revert BadVersion();
            lastCheckIn[v] = block.timestamp;
            emit CheckedIn(msg.sender, v, block.timestamp);
        }
    }

    /// True once 7 days have passed without a check-in of `version` (always for an unlisted number):
    /// anyone may then run the withdrawal of an account on it to its withdrawal address.
    function stopped(uint256 version) external view returns (bool) {
        return block.timestamp >= lastCheckIn[version] + STOP_AFTER;
    }

    /// Recovery only. It receives only fees the owner signed for (decision 19); zero stops all fees.
    function setFeeRecipient(address next) external {
        if (msg.sender != recovery) revert NotAllowed();
        emit FeeRecipientSet(feeRecipient, next);
        feeRecipient = next;
    }

    // ── recovery's handover ──────────────────────────────────────────────────────────────────

    /// Recovery proposes its successor; zero withdraws a proposal.
    function proposeRecovery(address next) external {
        if (msg.sender != recovery) revert NotAllowed();
        pendingRecovery = next;
        emit RecoveryProposed(recovery, next);
    }

    /// The proposed key accepts, proving it can sign.
    function acceptRecovery() external {
        if (msg.sender != pendingRecovery) revert NotAllowed(); // unset is zero, and no sender is
        emit RecoverySet(recovery, msg.sender);
        recovery = msg.sender;
        pendingRecovery = address(0);
    }
}
