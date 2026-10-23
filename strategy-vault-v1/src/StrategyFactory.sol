// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {IDepositOwner, IVaultFunding, OwnerDomain} from "./interfaces/IDepositOwner.sol";
import {IMessageTransmitterV2} from "./interfaces/Protocols.sol";
import {Legs, VaultConfig} from "./lib/VaultTypes.sol";
import {IOwnerRemovals, IProxyMaker, IRegistryV1} from "./Interfaces.sol";
import {ProxyInitCode} from "./ProxyInitCode.sol";
import {LegSpec, MemberTypes, StrategySpec} from "./Types.sol";

/// What the factory asks a version-1 implementation at a creation.
interface IMemberV1 {
    function validateParams(address registry, bytes calldata params) external view;
    function paramsType() external pure returns (string memory);
    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind);
    function initialize(
        address owner,
        address registry,
        address[] calldata links,
        uint32[] calldata domains,
        uint8 group,
        bytes32 strategyId,
        bytes32 configHash,
        bytes calldata params
    ) external;
}

/*
 * The COMBINATION FACTORY, version 1 (version 0's `CombinationFactory` on the owner-upgradeable frame:
 * owner-upgrades-design.md §C1, §C6; asset-profiles-design.md AP-2, AP-4, §3.8): ONE factory for every
 * version and every asset profile, deployed through the deterministic deployer with the same arguments
 * on every chain a member lives on, so it has one address there; the deposit contract trusts it at once
 * (`PINNED_VAULT_FACTORY`). It has no owner and no setter.
 *
 * WHAT IT PINS: the registry, the TOPOLOGY (the hub's chains, each leg's member type, chain, role and
 * value kind) and each member type's PARAMETER TYPE (name, fields, count: the owner's typed `CreateVault`
 * is composed from them at construction). The CODE is not pinned: the owner's `CreateVault` names a
 * version's MANIFEST, and this chain's registry resolves each local member's implementation from it. A
 * version whose members change their parameter types or the topology needs a new factory (and a deposit
 * version re-pinning it); a new version, a new asset profile or a profile switch needs none.
 *
 * Each member is the shared ERC-1967 PROXY (`ProxyInitCode`, one init code for the deposit contract and
 * every member), at `CREATE2(this, keccak256(pairId, i), keccak256(proxy init code))`: its address never
 * depends on any code. Before each CREATE2 the factory stages the member's implementation in a plain
 * storage slot, which the proxy's constructor reads (`proxyImplementation()`), and clears it right after
 * (the build targets `paris`: no transient storage).
 *
 * A creation is refused unless the manifest is listed on this chain at a version not stopped for the
 * group, every member names the same asset profile (AP-4: the first word of every member's parameters),
 * each local implementation declares its pinned parameter type and role, validates its parameters (its
 * profile open on this chain, every shown field equal to it), and the owner signed `CreateVault` over
 * exactly this configuration. Anyone may submit it: the owner's signature is the power.
 */
contract StrategyFactory is IVaultFunding, IProxyMaker {
    address internal constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    struct LegPinV1 {
        uint8 memberType;
        uint32 domain;
        uint8 role;
        uint8 valueKind; // Legs.VALUE_*
        string typeName;
        string typeFields;
        uint8 fieldCount;
    }

    bytes internal constant CREATE_HEAD =
        "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,bytes32 manifest,";
    bytes internal constant CREATE_TAIL = ",uint256 deadline)";

    struct Member {
        address owner;
        bytes32 strategyId;
        bytes32 configHash;
        uint8 index;
    }

    address public immutable registry;
    bytes32 public immutable createVaultTypehash;
    /// The shared proxy's init-code hash, in every member's address.
    bytes32 public constant PROXY_INIT_CODE_HASH = ProxyInitCode.HASH;
    uint32[] internal _hubDomains;
    LegPinV1[] internal _legs;
    mapping(address => Member) internal _members;
    bytes32[] internal _typeHashes; // member order: 0 the hub
    uint8[] internal _fieldCounts;
    string public createVaultType;
    /// The implementation of the member being created, for its proxy's constructor; zero otherwise.
    address internal _staged;

    event MemberCreated(
        address indexed member,
        address indexed owner,
        bytes32 indexed strategyId,
        bytes32 configHash,
        uint8 index,
        uint256 version,
        address implementation
    );

    error ZeroAddress();
    error BadPins();
    error BadConfig();
    error WrongChain();
    error Expired();
    error BadSignature();
    error DeployFailed();
    error BadOwner();

    constructor(
        address registry_,
        string memory hubTypeName,
        string memory hubTypeFields,
        uint8 hubFieldCount,
        uint32[] memory hubDomains_,
        LegPinV1[] memory legs_
    ) {
        if (registry_ == address(0)) revert ZeroAddress();
        uint256 h = hubDomains_.length;
        uint256 n = legs_.length;
        if (h == 0 || h > 6 || n < 2 || n > Legs.MAX_LEGS) revert BadPins();
        for (uint256 i; i < h; ++i) {
            uint32 d = hubDomains_[i];
            if (!_depositDomain(d)) revert BadPins();
            for (uint256 j; j < i; ++j) {
                if (hubDomains_[j] == d) revert BadPins();
            }
            _hubDomains.push(d);
        }
        for (uint256 i; i < n; ++i) {
            LegPinV1 memory p = legs_[i];
            if (
                p.memberType == 0 || p.memberType == MemberTypes.HUB || (p.role != Legs.LONG && p.role != Legs.SHORT)
                    || !_depositDomain(p.domain) || (p.valueKind != Legs.VALUE_READ && p.valueKind != Legs.VALUE_REPORTED)
            ) revert BadPins();
            _legs.push(p);
        }
        string memory createType = _composeTypes(hubTypeName, hubTypeFields, hubFieldCount, legs_);
        createVaultType = createType;
        createVaultTypehash = keccak256(bytes(createType));
        registry = registry_;
    }

    // ── creation (§C6) ───────────────────────────────────────────────────────────────────────────────

    /// Creates every member of `cfg` on this chain for `owner` (the user's deposit contract), on the version
    /// `cfg.manifest` names, if the owner signed `CreateVault` over exactly this configuration. Returns them
    /// in member order (the hub first, if it is here).
    function create(bytes32 strategyId, address owner, StrategySpec calldata cfg, uint256 deadline, bytes calldata signature)
        external
        returns (address[] memory made)
    {
        if (block.timestamp > deadline) revert Expired();
        IRegistryV1 r = IRegistryV1(registry);
        uint256 version = r.versionOf(cfg.manifest);
        uint256 n = _legs.length;
        if (
            cfg.factory != address(this) || cfg.legs.length != n || !_hubDomainAllowed(cfg.hubDomain) || version == 0
                || cfg.group >= r.GROUPS() || r.stopped(cfg.group, version) || cfg.hubParams.length < 32
        ) revert BadConfig();
        uint32 here = IMessageTransmitterV2(MESSAGE_TRANSMITTER).localDomain();
        bytes32 profile = bytes32(cfg.hubParams[0:32]);
        address[] memory impls = new address[](n + 1);
        uint256 local;
        if (cfg.hubDomain == here) {
            impls[0] = _local(r, version, MemberTypes.HUB, 0, cfg.hubParams);
            ++local;
        }
        for (uint256 i; i < n; ++i) {
            LegSpec calldata l = cfg.legs[i];
            LegPinV1 storage p = _legs[i];
            if (
                l.memberType != p.memberType || l.domain != p.domain || l.role != p.role || l.params.length < 32
                    || bytes32(l.params[0:32]) != profile
            ) revert BadConfig(); // AP-4: every member names the same profile
            if (l.domain == here) {
                address impl = _local(r, version, p.memberType, i + 1, l.params);
                (, uint8 roles, uint8 valueKind) = IMemberV1(impl).legInfo();
                if (roles & (1 << (p.role - 1)) == 0 || valueKind != p.valueKind) revert BadConfig();
                impls[i + 1] = impl;
                ++local;
            }
        }
        if (local == 0) revert WrongChain();
        bytes32 configHash = keccak256(abi.encode(cfg));
        if (owner.code.length == 0 || !IDepositOwner(owner).checkOwnerSignature(createDigest(strategyId, owner, cfg, deadline), signature)) {
            revert BadSignature();
        }
        // a strategy whose owner cannot answer `removalPendingOf` could never be upgraded nor switched
        // (the hub asks it at every schedule and apply: owner-upgrades-design.md §C4)
        (bool answers, bytes memory out) = owner.staticcall(abi.encodeCall(IOwnerRemovals.removalPendingOf, (bytes32(0))));
        if (!answers || out.length < 32) revert BadOwner();
        bytes32 pair = VaultConfig.pairId(strategyId, owner, configHash);
        (address[] memory at, uint32[] memory domains) = _members_(pair, cfg);
        made = new address[](local);
        uint256 m;
        for (uint256 i; i <= n; ++i) {
            if (domains[i] != here) continue;
            address member = _proxy(impls[i], VaultConfig.legSalt(pair, i));
            _members[member] = Member(owner, strategyId, configHash, uint8(i));
            (address[] memory links, uint32[] memory linkDomains) = _linksOf(i, at, domains);
            IMemberV1(member).initialize(
                owner, registry, links, linkDomains, cfg.group, strategyId, configHash,
                i == 0 ? cfg.hubParams : cfg.legs[i - 1].params
            );
            emit MemberCreated(member, owner, strategyId, configHash, uint8(i), version, impls[i]);
            made[m++] = member;
        }
    }

    /// The local member `i`'s implementation for `version`: listed here, declaring its pinned parameter
    /// type, its parameters valid.
    function _local(IRegistryV1 r, uint256 version, uint8 memberType, uint256 i, bytes calldata params)
        internal
        view
        returns (address impl)
    {
        impl = r.implementation(version, memberType);
        if (impl == address(0) || keccak256(bytes(IMemberV1(impl).paramsType())) != _typeHashes[i]) revert BadConfig();
        IMemberV1(impl).validateParams(address(r), params);
    }

    /// The proxy's constructor asks this, once: the implementation staged for the member being created.
    function proxyImplementation() external view returns (address) {
        return _staged;
    }

    // ── views ──────────────────────────────────────────────────────────────────────────────────────────

    /// The owner's `CreateVault` digest for `cfg`: `hashStruct(CreateVault(factory, strategyId, group,
    /// hubDomain, manifest, hub, leg1, …, deadline))`, each member's struct `keccak256(typeHash ‖ params)`.
    function createDigest(bytes32 strategyId, address owner, StrategySpec calldata cfg, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        uint256 n = cfg.legs.length;
        if (n != _legs.length) revert BadConfig();
        bytes memory enc = abi.encode(
            createVaultTypehash,
            cfg.factory,
            strategyId,
            cfg.group,
            cfg.hubDomain,
            cfg.manifest,
            _paramsHash(0, cfg.hubParams)
        );
        for (uint256 i; i < n; ++i) {
            enc = bytes.concat(enc, _paramsHash(i + 1, cfg.legs[i].params));
        }
        return OwnerDomain.digest(owner, keccak256(bytes.concat(enc, bytes32(deadline))));
    }

    /// A strategy's HUB this factory created: its owner, strategy id and configuration hash; zeros for any
    /// other address (amendment 1 §2.3: money enters at the hub only).
    function authorisedFor(address vault) external view returns (address owner, bytes32 strategyId, bytes32 configHash) {
        Member storage l = _members[vault];
        if (l.index != 0) return (address(0), bytes32(0), bytes32(0));
        return (l.owner, l.strategyId, l.configHash);
    }

    function memberOf(address member)
        external
        view
        returns (address owner, bytes32 strategyId, bytes32 configHash, uint8 index)
    {
        Member storage l = _members[member];
        return (l.owner, l.strategyId, l.configHash, l.index);
    }

    /// Every member's address (the hub first), deployed or not, on every chain: no code in it.
    function memberAddresses(bytes32 strategyId, address owner, StrategySpec calldata cfg)
        external
        view
        returns (address[] memory members, bytes32 configHash)
    {
        configHash = keccak256(abi.encode(cfg));
        (members,) = _members_(VaultConfig.pairId(strategyId, owner, configHash), cfg);
    }

    /// The member at `salt` (`VaultConfig.legSalt(pairId, i)`): `CREATE2(this, salt, the proxy's hash)`.
    function memberAt(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, PROXY_INIT_CODE_HASH)))));
    }

    function hubDomains() external view returns (uint32[] memory) {
        return _hubDomains;
    }

    /// What a hub created here reads at its initialisation: each leg pin's value kind, in leg order.
    function hubSetup() external view returns (uint8[] memory valueKinds) {
        valueKinds = new uint8[](_legs.length);
        for (uint256 i; i < _legs.length; ++i) {
            valueKinds[i] = _legs[i].valueKind;
        }
    }

    function legCount() external view returns (uint256) {
        return _legs.length;
    }

    function leg(uint256 i) external view returns (LegPinV1 memory) {
        return _legs[i];
    }

    // ── internals ──────────────────────────────────────────────────────────────────────────────────────

    function _paramsHash(uint256 i, bytes calldata params) internal view returns (bytes32) {
        if (params.length != uint256(_fieldCounts[i]) * 32) revert BadConfig();
        return keccak256(bytes.concat(_typeHashes[i], params));
    }

    /// Version 0's composition: the primary type (the hub as `hub`, leg `i` as `leg<i+1>`), then each member
    /// type once, sorted by name.
    function _composeTypes(string memory hubName, string memory hubFields, uint8 hubCount, LegPinV1[] memory legs_)
        internal
        returns (string memory)
    {
        uint256 n = legs_.length;
        string[] memory names = new string[](n + 1);
        string[] memory fields = new string[](n + 1);
        names[0] = hubName;
        fields[0] = hubFields;
        bytes memory primary = abi.encodePacked(CREATE_HEAD, hubName, " hub");
        for (uint256 i; i <= n; ++i) {
            if (i > 0) {
                names[i] = legs_[i - 1].typeName;
                fields[i] = legs_[i - 1].typeFields;
                primary = abi.encodePacked(primary, ",", names[i], " leg", bytes1(uint8(48 + i)));
            }
            uint8 count = i == 0 ? hubCount : legs_[i - 1].fieldCount;
            if (bytes(names[i]).length == 0 || keccak256(bytes(names[i])) == keccak256("CreateVault")) revert BadPins();
            if (count == 0 || count != _fieldsIn(bytes(fields[i]))) revert BadPins();
            _typeHashes.push(keccak256(abi.encodePacked(names[i], "(", fields[i], ")")));
            _fieldCounts.push(count);
        }
        primary = abi.encodePacked(primary, CREATE_TAIL);
        bool[] memory done = new bool[](n + 1);
        for (uint256 i; i <= n; ++i) {
            for (uint256 j; j <= n; ++j) {
                if (keccak256(bytes(names[i])) == keccak256(bytes(names[j])) && j != i) {
                    if (keccak256(bytes(fields[i])) != keccak256(bytes(fields[j]))) revert BadPins();
                    if (j > i) done[j] = true;
                }
            }
        }
        for (;;) {
            uint256 next = type(uint256).max;
            for (uint256 i; i <= n; ++i) {
                if (!done[i] && (next == type(uint256).max || _before(bytes(names[i]), bytes(names[next])))) next = i;
            }
            if (next == type(uint256).max) break;
            done[next] = true;
            primary = abi.encodePacked(primary, names[next], "(", fields[next], ")");
        }
        return string(primary);
    }

    function _fieldsIn(bytes memory f) internal pure returns (uint256 c) {
        if (f.length == 0) return 0;
        c = 1;
        for (uint256 i; i < f.length; ++i) {
            if (f[i] == ",") ++c;
        }
    }

    function _before(bytes memory a, bytes memory b) internal pure returns (bool) {
        uint256 m = a.length < b.length ? a.length : b.length;
        for (uint256 i; i < m; ++i) {
            if (a[i] != b[i]) return a[i] < b[i];
        }
        return a.length < b.length;
    }

    /// The deposit contract's chains: Ethereum 0, Avalanche 1, OP Mainnet 2, Arbitrum 3, Base 6,
    /// Polygon 7, HyperEVM 19.
    function _depositDomain(uint32 d) internal pure returns (bool) {
        return d <= 3 || d == 6 || d == 7 || d == 19;
    }

    function _hubDomainAllowed(uint32 d) internal view returns (bool) {
        uint256 h = _hubDomains.length;
        for (uint256 i; i < h; ++i) {
            if (_hubDomains[i] == d) return true;
        }
        return false;
    }

    function _members_(bytes32 pair, StrategySpec calldata cfg)
        internal
        view
        returns (address[] memory at, uint32[] memory domains)
    {
        uint256 n = cfg.legs.length + 1;
        at = new address[](n);
        domains = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            domains[i] = i == 0 ? cfg.hubDomain : cfg.legs[i - 1].domain;
            at[i] = memberAt(VaultConfig.legSalt(pair, i));
        }
    }

    function _linksOf(uint256 i, address[] memory at, uint32[] memory domains)
        internal
        pure
        returns (address[] memory links, uint32[] memory linkDomains)
    {
        uint256 n = at.length - 1;
        links = new address[](n);
        linkDomains = new uint32[](n);
        uint256 k;
        for (uint256 j; j < at.length; ++j) {
            if (j == i) continue;
            links[k] = at[j];
            linkDomains[k] = domains[j];
            ++k;
        }
    }

    /// The shared proxy at `salt`, its implementation staged for its constructor and cleared after.
    function _proxy(address impl, bytes32 salt) internal returns (address made) {
        _staged = impl;
        bytes memory init = ProxyInitCode.INIT_CODE;
        assembly ("memory-safe") {
            made := create2(0, add(init, 0x20), mload(init), salt)
        }
        _staged = address(0);
        if (made == address(0)) revert DeployFailed();
    }
}
