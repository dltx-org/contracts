// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {IImplementation, IRegistryV1} from "./Interfaces.sol";
import {AssetProfile, Manifests, Profiles, VersionMember} from "./Types.sol";

interface ILocalDomain {
    function localDomain() external view returns (uint32);
}

/*
 * The REGISTRY, version 1 (version 0's `VaultRegistry` plus owner-upgrades-design.md §A3, §A8, §A9, §C2
 * and asset-profiles-design.md AP-2, AP-3, Q16): one per chain, created through the deterministic
 * deployer with the same arguments everywhere, so it has one address on every chain. It is immutable;
 * the recovery key is its only authority and can never move a strategy:
 *
 * - THE EXECUTION GROUPS (unchanged): each group's key, set by recovery; DLTX's fee address, two steps.
 * - THE VERSIONS, append only: a version is a number, its MANIFEST (the keccak of every member type's
 *   (type, domain, implementation, code hash), across every chain: the same bytes everywhere) and, on
 *   this chain, the implementations of the member types that live here. Recovery proposes, the proposal
 *   is public for 7 days, recovery accepts in version order (withdrawable before). Nothing is removed.
 *   Followers' chains accept first, the hub's (Arbitrum) last. An owner signs a manifest, never a number:
 *   this chain installs only the code its own entry for that manifest names.
 * - THE GENESIS (the operator's decision of 2026-10-23): the FIRST version and its asset profiles are
 *   constructor data, listed and open at once, with no 7-day delay: the registry's address (the same
 *   arguments on every chain) is the hash of them, so the deposit contract's pinned factory, which names
 *   this registry, commits to that version and those profiles. Their implementations name no registry
 *   (they are deployed first; a registry naming them in its own address could not be named back), and
 *   are checked here as a proposal's are, but for that name. Every later version and profile takes the
 *   public 7 days, and its implementations name this registry (§A9).
 * - PER-VERSION CHECK-INS (§A8): `checkIn(group, version)` by the group's key; `stopped(group, version)`
 *   once 7 days pass with none. Accepting a version seeds its clock for every group, so a version is
 *   never stopped on arrival; a group's first key starts its clock, as in version 0.
 * - THE ASSET PROFILES, a separate append-only list (Q16): recovery proposes a profile's full data, 7
 *   public days, recovery accepts: then every fact that lives on this chain is checked (AP-3) by the
 *   latest version's implementation of each member type here (`checkProfile`), which knows this chain's
 *   protocols. A profile is never edited (its id is its data's hash); recovery may close it to new
 *   strategies, which no strategy that stored it ever reads.
 */
contract StrategyRegistry is IRegistryV1 {
    uint8 public constant GROUPS = 16;
    uint256 public constant STOP_AFTER = 7 days;
    uint256 public constant LISTING_DELAY = 7 days;
    /// §A9: the longest predecessor chain a listed implementation's registry may descend by.
    uint256 public constant MAX_SUCCESSIONS = 8;
    address internal constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    // profile states
    uint8 public constant PROFILE_NONE = 0;
    uint8 public constant PROFILE_PROPOSED = 1;
    uint8 public constant PROFILE_OPEN = 2;
    uint8 public constant PROFILE_CLOSED = 3;

    /// §A9: the registry this one succeeds (zero for the first), and its first version number.
    address public immutable predecessor;
    uint256 public immutable firstVersion;

    address public recovery;
    address public pendingRecovery;
    mapping(uint8 => address) public executionKey;
    mapping(uint8 => uint256) public firstKeyAt;
    address public feeAddress;
    address public pendingFeeAddress;

    // ── versions ─────────────────────────────────────────────────────────────────────────────────────
    struct Proposal {
        uint64 due;
        bytes32 manifest;
        uint8[] memberTypes; // the types that live on this chain
        address[] implementations;
        bytes32[] codeHashes;
    }

    uint256 public latestVersion; // 0 until the first is accepted
    mapping(uint256 => Proposal) internal _proposals;
    mapping(uint256 => bytes32) public manifestOf;
    mapping(bytes32 => uint256) public versionOf;
    mapping(uint256 => mapping(uint8 => address)) internal _implementation;
    mapping(uint256 => uint8[]) internal _localTypes;
    mapping(uint256 => uint256) public acceptedAt;
    mapping(uint256 => mapping(uint8 => uint256)) public lastCheckIn; // version → group → time

    // ── profiles ─────────────────────────────────────────────────────────────────────────────────────
    mapping(bytes32 => AssetProfile) internal _profiles;
    mapping(bytes32 => uint8) public profileState;
    mapping(bytes32 => uint64) public profileDue;
    bytes32[] internal _profileIds; // accepted, in order

    event ExecutionKeySet(uint8 indexed group, address indexed previous, address indexed next);
    event CheckIn(uint8 indexed group, uint256 indexed version, uint256 at);
    event RecoveryProposed(address indexed current, address indexed proposed);
    event RecoverySet(address indexed previous, address indexed next);
    event FeeAddressProposed(address indexed current, address indexed proposed);
    event FeeAddressSet(address indexed previous, address indexed next);
    event VersionProposed(uint256 indexed version, bytes32 manifest, VersionMember[] members, uint256 due);
    event VersionWithdrawn(uint256 indexed version);
    event VersionAccepted(uint256 indexed version, bytes32 manifest);
    event ProfileProposed(bytes32 indexed id, AssetProfile profile, uint256 due);
    event ProfileWithdrawn(bytes32 indexed id);
    event ProfileAccepted(bytes32 indexed id);
    event ProfileClosed(bytes32 indexed id);

    error NotAllowed();
    error ZeroAddress();
    error BadGroup();
    error BadVersion();
    error AlreadyPending();
    error NotDue();
    error CodeChanged();
    error BadProfile();

    /// `genesis`: version `firstVersion_`'s members on every chain, strictly by member type (empty: none,
    /// every version proposed; the first registry's only); `profiles`: the asset profiles open from the
    /// start (none without a genesis), each checked by the genesis's local implementations (AP-3). Both
    /// listed at once.
    constructor(
        address recovery_,
        address predecessor_,
        uint256 firstVersion_,
        VersionMember[] memory genesis,
        AssetProfile[] memory profiles
    ) {
        if (recovery_ == address(0)) revert ZeroAddress();
        if (firstVersion_ == 0 || (predecessor_ == address(0)) != (firstVersion_ == 1)) revert BadVersion();
        recovery = recovery_;
        predecessor = predecessor_;
        firstVersion = firstVersion_;
        if (genesis.length == 0) {
            if (profiles.length != 0) revert BadProfile();
            return;
        }
        // a successor's versions are listed in its predecessors too (§A9), which a genesis could never be
        if (predecessor_ != address(0)) revert BadVersion();
        Proposal storage p = _proposals[firstVersion_];
        bytes32 manifest = _stage(p, firstVersion_, genesis, false);
        p.manifest = manifest;
        emit VersionProposed(firstVersion_, manifest, genesis, block.timestamp);
        _list(firstVersion_, p);
        for (uint256 i; i < profiles.length; ++i) {
            bytes32 id = Profiles.id(profiles[i]);
            if (profileState[id] != PROFILE_NONE) revert AlreadyPending();
            _profiles[id] = profiles[i];
            emit ProfileProposed(id, profiles[i], block.timestamp);
            _open(id, profiles[i]);
        }
    }

    modifier onlyRecovery() {
        if (msg.sender != recovery) revert NotAllowed();
        _;
    }

    // ── the execution groups (version 0's, unchanged but for per-version check-ins) ──────────────────

    function setExecutionKey(uint8 group, address key) external onlyRecovery {
        if (group >= GROUPS) revert BadGroup();
        if (key == address(0)) revert ZeroAddress();
        emit ExecutionKeySet(group, executionKey[group], key);
        if (executionKey[group] == address(0)) firstKeyAt[group] = block.timestamp;
        executionKey[group] = key;
    }

    /// The group's key, daily, for each version it still supports (§A8).
    function checkIn(uint8 group, uint256[] calldata versions) external {
        if (group >= GROUPS || msg.sender != executionKey[group]) revert NotAllowed();
        for (uint256 i; i < versions.length; ++i) {
            uint256 v = versions[i];
            if (acceptedAt[v] == 0) revert BadVersion();
            lastCheckIn[v][group] = block.timestamp;
            emit CheckIn(group, v, block.timestamp);
        }
    }

    /// 7 days without a check-in of `version` by `group` (counted from the latest of its last check-in,
    /// the version's acceptance and the group's first key), no key ever set, or a version not accepted
    /// here: anyone may begin the exit of that group's members on that version.
    function stopped(uint8 group, uint256 version) external view returns (bool) {
        uint256 from = acceptedAt[version];
        if (from == 0 || executionKey[group] == address(0)) return true;
        uint256 last = lastCheckIn[version][group];
        if (last > from) from = last;
        if (firstKeyAt[group] > from) from = firstKeyAt[group];
        return block.timestamp >= from + STOP_AFTER;
    }

    function proposeRecovery(address next) external onlyRecovery {
        pendingRecovery = next;
        emit RecoveryProposed(recovery, next);
    }

    function acceptRecovery() external {
        if (msg.sender != pendingRecovery) revert NotAllowed();
        emit RecoverySet(recovery, msg.sender);
        recovery = msg.sender;
        pendingRecovery = address(0);
    }

    function proposeFeeAddress(address next) external onlyRecovery {
        pendingFeeAddress = next;
        emit FeeAddressProposed(feeAddress, next);
    }

    function acceptFeeAddress() external {
        if (msg.sender != pendingFeeAddress) revert NotAllowed();
        emit FeeAddressSet(feeAddress, msg.sender);
        feeAddress = msg.sender;
        pendingFeeAddress = address(0);
    }

    // ── the versions (§A3, §C2) ──────────────────────────────────────────────────────────────────────

    /// Recovery proposes `version` with EVERY member type of it on every chain (`members`, strictly by
    /// member type); the manifest is computed here. Each member type living on this chain must name an
    /// implementation with that code hash, its `CODE_VERSION` this number, its `MEMBER_TYPE` its own, and
    /// this registry (or a successor naming this one) as its listing registry. Proposals may run at once.
    function proposeVersion(uint256 version, VersionMember[] calldata members) external onlyRecovery {
        if (version < firstVersion || version <= latestVersion || _proposals[version].due != 0) {
            revert BadVersion();
        }
        Proposal storage p = _proposals[version];
        bytes32 manifest = _stage(p, version, members, true);
        uint64 due = uint64(block.timestamp + LISTING_DELAY);
        p.due = due;
        p.manifest = manifest;
        emit VersionProposed(version, manifest, members, due);
    }

    /// Writes `members`' local entries into `p` once each is checked; returns the manifest. `listing`: the
    /// implementations name this registry (§A9), as every proposed version's must; the genesis's cannot.
    function _stage(Proposal storage p, uint256 version, VersionMember[] memory members, bool listing)
        internal
        returns (bytes32 manifest)
    {
        uint32 here = ILocalDomain(MESSAGE_TRANSMITTER).localDomain();
        uint256 n = members.length;
        if (n == 0) revert BadVersion();
        for (uint256 i; i < n; ++i) {
            VersionMember memory m = members[i];
            if (m.memberType == 0 || (i > 0 && m.memberType <= members[i - 1].memberType)) revert BadVersion();
            if (m.implementation == address(0) || m.codeHash == bytes32(0)) revert BadVersion();
            if (m.domain != here) continue;
            address impl = m.implementation;
            if (impl.codehash != m.codeHash) revert CodeChanged();
            IImplementation c = IImplementation(impl);
            if (
                c.CODE_VERSION() != version || c.MEMBER_TYPE() != m.memberType
                    || (listing && !_listsHere(c.listingRegistry()))
            ) {
                revert BadVersion();
            }
            p.memberTypes.push(m.memberType);
            p.implementations.push(impl);
            p.codeHashes.push(m.codeHash);
        }
        if (p.memberTypes.length == 0) revert BadVersion(); // no member type lives on this chain
        manifest = Manifests.hash(members);
        if (versionOf[manifest] != 0) revert BadVersion();
    }

    function withdrawVersion(uint256 version) external onlyRecovery {
        if (_proposals[version].due == 0) revert BadVersion();
        delete _proposals[version];
        emit VersionWithdrawn(version);
    }

    /// Recovery, once due, in version order, every code hash unchanged: lists it and seeds its check-ins.
    function acceptVersion(uint256 version) external onlyRecovery {
        Proposal storage p = _proposals[version];
        if (p.due == 0) revert BadVersion();
        if (block.timestamp < p.due) revert NotDue();
        if (version != (latestVersion == 0 ? firstVersion : latestVersion + 1)) revert BadVersion();
        _list(version, p);
    }

    function _list(uint256 version, Proposal storage p) internal {
        if (versionOf[p.manifest] != 0) revert BadVersion();
        uint256 n = p.memberTypes.length;
        // every member type the previous version had here is in this one (§C2): a follower of a type left
        // out could never resolve its implementation, and a hub's apply would revert at its long
        uint8[] storage before = _localTypes[latestVersion];
        for (uint256 i; i < before.length; ++i) {
            bool found;
            for (uint256 j; j < n; ++j) {
                if (p.memberTypes[j] == before[i]) found = true;
            }
            if (!found) revert BadVersion();
        }
        for (uint256 i; i < n; ++i) {
            if (p.implementations[i].codehash != p.codeHashes[i]) revert CodeChanged();
            _implementation[version][p.memberTypes[i]] = p.implementations[i];
        }
        _localTypes[version] = p.memberTypes;
        manifestOf[version] = p.manifest;
        versionOf[p.manifest] = version;
        acceptedAt[version] = block.timestamp;
        latestVersion = version;
        emit VersionAccepted(version, p.manifest);
        delete _proposals[version];
    }

    function implementation(uint256 version, uint8 memberType) external view returns (address) {
        return _implementation[version][memberType];
    }

    /// The member types of `version` that live on this chain.
    function localTypes(uint256 version) external view returns (uint8[] memory) {
        return _localTypes[version];
    }

    function proposal(uint256 version)
        external
        view
        returns (uint64 due, bytes32 manifest, uint8[] memory memberTypes, address[] memory implementations)
    {
        Proposal storage p = _proposals[version];
        return (p.due, p.manifest, p.memberTypes, p.implementations);
    }

    /// §A9: an implementation listed here names this registry, or one descending from it by its
    /// predecessor chain (each registry naming the one before), at most MAX_SUCCESSIONS steps back to this
    /// one: a loop, a longer chain or one ending elsewhere is refused. A follower made through this
    /// registry before several successions can then follow its hub to any later version, once recovery
    /// lists that version here too (Codex on the integration, 2026-10-23).
    function _listsHere(address r) internal view returns (bool) {
        for (uint256 i; r != address(this); ++i) {
            if (i == MAX_SUCCESSIONS || r.code.length == 0) return false;
            (bool ok, bytes memory out) = r.staticcall(abi.encodeWithSignature("predecessor()"));
            if (!ok || out.length < 32) return false;
            r = abi.decode(out, (address));
        }
        return true;
    }

    // ── the asset profiles (AP-2, AP-3, Q16) ─────────────────────────────────────────────────────────

    /// Recovery proposes a profile's full data; public for 7 days. Its id is the data's hash.
    function proposeProfile(AssetProfile calldata p) external onlyRecovery returns (bytes32 id) {
        id = Profiles.id(p);
        if (profileState[id] != PROFILE_NONE) revert AlreadyPending();
        _profiles[id] = p;
        profileState[id] = PROFILE_PROPOSED;
        uint64 due = uint64(block.timestamp + LISTING_DELAY);
        profileDue[id] = due;
        emit ProfileProposed(id, p, due);
    }

    function withdrawProfile(bytes32 id) external onlyRecovery {
        if (profileState[id] != PROFILE_PROPOSED) revert BadProfile();
        delete _profiles[id];
        delete profileState[id];
        delete profileDue[id];
        emit ProfileWithdrawn(id);
    }

    /// Recovery, once due: every fact of the profile that lives on this chain is checked by the latest
    /// version's implementation of each member type here (AP-3); then it is open to new strategies.
    function acceptProfile(bytes32 id) external onlyRecovery {
        if (profileState[id] != PROFILE_PROPOSED) revert BadProfile();
        if (block.timestamp < profileDue[id]) revert NotDue();
        _open(id, _profiles[id]);
    }

    /// AP-3 by the latest version's local implementations, then open to new strategies.
    function _open(bytes32 id, AssetProfile memory p) internal {
        uint256 v = latestVersion;
        if (v == 0) revert BadVersion();
        uint8[] storage types = _localTypes[v];
        for (uint256 i; i < types.length; ++i) {
            IImplementation(_implementation[v][types[i]]).checkProfile(p);
        }
        profileState[id] = PROFILE_OPEN;
        _profileIds.push(id);
        emit ProfileAccepted(id);
    }

    /// Recovery closes a profile to new strategies (and profile switches to it); every strategy that
    /// stored it keeps its copy.
    function closeProfile(bytes32 id) external onlyRecovery {
        if (profileState[id] != PROFILE_OPEN) revert BadProfile();
        profileState[id] = PROFILE_CLOSED;
        emit ProfileClosed(id);
    }

    function profileOpen(bytes32 id) external view returns (bool) {
        return profileState[id] == PROFILE_OPEN;
    }

    /// A profile's data (proposed, open or closed); zeros for an unknown id.
    function profileOf(bytes32 id) external view returns (AssetProfile memory) {
        return _profiles[id];
    }

    /// Every accepted profile's id, in order of acceptance.
    function profileIds() external view returns (bytes32[] memory) {
        return _profileIds;
    }
}
