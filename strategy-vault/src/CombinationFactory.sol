// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {IDepositOwner, IVaultFunding, OwnerDomain} from "./interfaces/IDepositOwner.sol";
import {ILeg, IMember} from "./interfaces/ILeg.sol";
import {IMessageTransmitterV2} from "./interfaces/Protocols.sol";
import {PriceSourcePin, SequencerPin} from "./lib/PriceSource.sol";
import {Assets, LegConfig, Legs, StrategyConfig, VaultConfig} from "./lib/VaultTypes.sol";

interface IRegistryGroups {
    function GROUPS() external view returns (uint8);
    function stopped(uint8 group) external view returns (bool);
}

/*
 * A combination factory (step 11e2 amendment 2a, revision 1, §3.3, decisions 36 and 43): ONE pairing of
 * leg codes and the hub code, fixed at construction, deployed through the deterministic deployer with
 * the same arguments on every chain one of its members may live on, so it has one address there. The
 * owner trusts it with amendment 1's mechanism (per factory and the hub's deposit domain, 24 hours the
 * first time), unchanged: trusting it approves the whole money route at once, since a member's links can
 * only be the clones it makes.
 *
 * Its constructor names the chain's registry, the hub code (its code hash, the chains a hub may live on)
 * and each leg's pin (the leg code, its code hash, its CCTP domain, its role). Every one of those chains
 * must be a deposit chain, where the owner's deposit contract lives (a hub's funding, payouts and
 * withdrawal address; a leg's owner verifier). On each chain it checks the codes of that chain; the
 * other chains' copies check theirs. It has no owner, no setter, no beacon.
 *
 * It creates a strategy's members on this chain — the hub if its chain is this one, each leg whose chain
 * is — every one in one transaction, only for a configuration that matches its pins and that the owner
 * signed (`CreateVault`, decision 16; typed field by field since amendment 2d §4.2: each member's
 * parameters a nested struct of its member TYPE, whose name, fields and field count this factory pins, so
 * a wallet shows every parameter and the digest is computed from the configuration created), member `i`
 * at `salt = keccak256(pairId, i)` with `pairId =
 * keccak256(strategyId, owner, configHash)` (decision 26), the hub member 0; every link's address
 * computed, never passed in. Anyone may submit a creation: the owner's signature is the power.
 *
 * Amendment 2b §3.8: it also PINS the fee's price sources, one per (hub chain, asset) (a Chainlink feed,
 * or a rate × a USD price), and each L2 hub chain's sequencer uptime feed, checked on the chain they are
 * read on; a hub created here reads this chain's at its initialisation (`hubSetup`), with each leg pin's
 * `valueKind` (how the leg's value is known, checked against the leg code on its own chain).
 */
contract CombinationFactory is IVaultFunding {
    address internal constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    struct LegPin {
        address code;
        bytes32 codeHash;
        uint32 domain;
        uint8 role;
        uint8 valueKind; // Legs.VALUE_*, as the leg code's `legInfo` declares it (amendment 2b)
        // amendment 2d §4.2: the leg type's parameters as an EIP-712 struct, as its `paramsType()` declares
        // them (`typeName(typeFields)`), every field static: `params` is exactly `fieldCount` words
        string typeName;
        string typeFields;
        uint8 fieldCount;
    }

    /// `CreateVault`'s own fields before the hub's struct, and after the legs' (amendment 2d §4.2).
    bytes internal constant CREATE_HEAD = "CreateVault(address factory,bytes32 strategyId,uint8 group,uint32 hubDomain,";
    bytes internal constant CREATE_TAIL = ",uint256 deadline)";

    /// The most price sources a hub chain may pin (amendment 2b).
    uint256 internal constant MAX_PRICES = 8;

    struct Member {
        address owner;
        bytes32 strategyId;
        bytes32 configHash;
        uint8 index;
    }

    address public immutable registry;
    address public immutable hubCode;
    bytes32 public immutable hubCodeHash;
    /// Amendment 2d §4.2: `keccak256` of `createVaultType()`, the owner's `CreateVault` type.
    bytes32 public immutable createVaultTypehash;
    uint32[] internal _hubDomains;
    LegPin[] internal _legs;
    PriceSourcePin[] internal _prices;
    SequencerPin[] internal _sequencers;
    mapping(address => Member) internal _members;
    /// Amendment 2d §4.2: each member type's type hash and field count, in member order (0 the hub).
    bytes32[] internal _typeHashes;
    uint8[] internal _fieldCounts;
    /// The whole EIP-712 type of `CreateVault`: the primary type, then each member type once, by name.
    string public createVaultType;

    event MemberCreated(
        address indexed member, address indexed owner, bytes32 indexed strategyId, bytes32 configHash, uint8 index
    );

    error ZeroAddress();
    error BadPins();
    error BadConfig();
    error WrongChain();
    error Expired();
    error BadSignature();
    error DeployFailed();

    constructor(
        address registry_,
        address hubCode_,
        bytes32 hubCodeHash_,
        string memory hubTypeName,
        string memory hubTypeFields,
        uint8 hubFieldCount,
        uint32[] memory hubDomains_,
        LegPin[] memory legs_,
        PriceSourcePin[] memory prices_,
        SequencerPin[] memory sequencers_
    ) {
        if (registry_ == address(0) || hubCode_ == address(0)) revert ZeroAddress();
        uint256 h = hubDomains_.length;
        uint256 n = legs_.length;
        if (hubCodeHash_ == bytes32(0) || h == 0 || h > 6 || n < 2 || n > Legs.MAX_LEGS) revert BadPins();
        uint32 here = IMessageTransmitterV2(MESSAGE_TRANSMITTER).localDomain();
        for (uint256 i; i < h; ++i) {
            uint32 d = hubDomains_[i];
            if (!_depositDomain(d)) revert BadPins();
            for (uint256 j; j < i; ++j) {
                if (hubDomains_[j] == d) revert BadPins();
            }
            if (d == here) {
                if (hubCode_.codehash != hubCodeHash_) revert BadPins();
                _checkType(hubCode_, hubTypeName, hubTypeFields);
            }
            _hubDomains.push(d);
        }
        for (uint256 i; i < n; ++i) {
            LegPin memory p = legs_[i];
            if (
                p.code == address(0) || p.codeHash == bytes32(0) || (p.role != Legs.LONG && p.role != Legs.SHORT)
                    || !_depositDomain(p.domain) || (p.valueKind != Legs.VALUE_READ && p.valueKind != Legs.VALUE_REPORTED)
            ) revert BadPins();
            if (p.domain == here) {
                if (p.code.codehash != p.codeHash) revert BadPins();
                (, uint8 roles, uint8 valueKind) = ILeg(p.code).legInfo();
                if (roles & (1 << (p.role - 1)) == 0 || valueKind != p.valueKind) revert BadPins();
                _checkType(p.code, p.typeName, p.typeFields);
            }
            _legs.push(p);
        }
        string memory createType = _composeTypes(hubTypeName, hubTypeFields, hubFieldCount, legs_);
        createVaultType = createType;
        createVaultTypehash = keccak256(bytes(createType));
        for (uint256 i; i < prices_.length; ++i) {
            PriceSourcePin memory p = prices_[i];
            bool composite = p.kind == 2;
            if (
                !_hubDomainAllowed(p.hubDomain) || p.asset == bytes32(0) || p.asset == Assets.USD || p.feed == address(0)
                    || p.maxAge == 0 || (p.kind != 1 && !composite) || composite != (p.baseFeed != address(0))
            ) revert BadPins();
            uint256 same;
            for (uint256 j; j < i; ++j) {
                if (prices_[j].hubDomain != p.hubDomain) continue;
                if (prices_[j].asset == p.asset) revert BadPins();
                ++same;
            }
            if (same >= MAX_PRICES) revert BadPins();
            if (p.hubDomain == here && (p.feed.code.length == 0 || (composite && p.baseFeed.code.length == 0))) {
                revert BadPins();
            }
            _prices.push(p);
        }
        for (uint256 i; i < sequencers_.length; ++i) {
            SequencerPin memory q = sequencers_[i];
            if (!_hubDomainAllowed(q.hubDomain) || q.feed == address(0)) revert BadPins();
            for (uint256 j; j < i; ++j) {
                if (sequencers_[j].hubDomain == q.hubDomain) revert BadPins();
            }
            if (q.hubDomain == here && q.feed.code.length == 0) revert BadPins();
            _sequencers.push(q);
        }
        // a rollup hub chain values only while its sequencer is up (amendment 2b §3.8): its pin is required
        for (uint256 i; i < h; ++i) {
            uint32 d = hubDomains_[i];
            if (!_rollup(d)) continue;
            bool pinned;
            for (uint256 j; j < sequencers_.length; ++j) {
                if (sequencers_[j].hubDomain == d) pinned = true;
            }
            if (!pinned) revert BadPins();
        }
        registry = registry_;
        hubCode = hubCode_;
        hubCodeHash = hubCodeHash_;
    }

    // ── creation (§3.3; decisions 16, 26, 43) ────────────────────────────────────────────────────────────

    /// Creates every member of `cfg` on this chain for `owner` (the user's deposit contract, the same
    /// address on every chain), if the owner signed `CreateVault` over exactly this configuration
    /// (`createDigest`). Returns them in member order (the hub first, if it is here).
    function create(
        bytes32 strategyId,
        address owner,
        StrategyConfig calldata cfg,
        uint256 deadline,
        bytes calldata signature
    ) external returns (address[] memory made) {
        if (block.timestamp > deadline) revert Expired();
        uint256 n = _legs.length;
        if (
            cfg.factory != address(this) || cfg.legs.length != n || !_hubDomainAllowed(cfg.hubDomain)
                || cfg.group >= IRegistryGroups(registry).GROUPS() || IRegistryGroups(registry).stopped(cfg.group)
        ) revert BadConfig(); // a stopped group (no key set on this chain, or 7 days silent) is refused: anyone
        // could put the new strategy in exit at once (the combined review's CR-E3)
        uint32 here = IMessageTransmitterV2(MESSAGE_TRANSMITTER).localDomain();
        uint256 local;
        if (cfg.hubDomain == here) {
            IMember(hubCode).validateParams(cfg.hubParams);
            ++local;
        }
        for (uint256 i; i < n; ++i) {
            LegConfig calldata l = cfg.legs[i];
            LegPin storage p = _legs[i];
            if (l.code != p.code || l.domain != p.domain || l.role != p.role) revert BadConfig();
            if (l.domain == here) {
                ILeg(l.code).validateParams(l.params);
                ++local;
            }
        }
        if (local == 0) revert WrongChain();
        bytes32 configHash = keccak256(abi.encode(cfg));
        bytes32 digest = createDigest(strategyId, owner, cfg, deadline);
        if (owner.code.length == 0 || !IDepositOwner(owner).checkOwnerSignature(digest, signature)) {
            revert BadSignature();
        }
        bytes32 pair = VaultConfig.pairId(strategyId, owner, configHash);
        (address[] memory at, uint32[] memory domains, address[] memory codes) = _members_(pair, cfg);
        made = new address[](local);
        uint256 m;
        for (uint256 i; i <= n; ++i) {
            if (domains[i] != here) continue;
            address member = _clone(codes[i], VaultConfig.legSalt(pair, i));
            _members[member] = Member(owner, strategyId, configHash, uint8(i));
            (address[] memory links, uint32[] memory linkDomains) = _linksOf(i, at, domains);
            IMember(member).initialize(
                owner,
                registry,
                links,
                linkDomains,
                cfg.group,
                strategyId,
                configHash,
                i == 0 ? cfg.hubParams : cfg.legs[i - 1].params
            );
            emit MemberCreated(member, owner, strategyId, configHash, uint8(i));
            made[m++] = member;
        }
    }

    // ── views ──────────────────────────────────────────────────────────────────────────────────────────

    /// The digest the owner signs for `cfg` (amendment 2d §4.2), under the owner's domain: `hashStruct` of
    /// `CreateVault(factory, strategyId, group, hubDomain, hub, leg1, …, deadline)`, each member's struct
    /// hashed as `keccak256(typeHash ‖ params)` from its all-static parameters. Reverts (`BadConfig`) when a
    /// member's `params` are not exactly its pinned field count in words, or the legs not the pinned count.
    function createDigest(bytes32 strategyId, address owner, StrategyConfig calldata cfg, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        uint256 n = cfg.legs.length;
        if (n != _legs.length) revert BadConfig();
        bytes memory enc = abi.encode(
            createVaultTypehash, cfg.factory, strategyId, cfg.group, cfg.hubDomain, _paramsHash(0, cfg.hubParams)
        );
        for (uint256 i; i < n; ++i) {
            enc = bytes.concat(enc, _paramsHash(i + 1, cfg.legs[i].params));
        }
        return OwnerDomain.digest(owner, keccak256(bytes.concat(enc, bytes32(deadline))));
    }

    /// What a deposit account's `fund` asks (amendment 1 §2.3): the owner, strategy id and configuration
    /// hash of a strategy's HUB this factory created; zeros for anything else, a leg included, so money
    /// enters a strategy at its hub only (invariant 3).
    function authorisedFor(address vault) external view returns (address owner, bytes32 strategyId, bytes32 configHash) {
        Member storage l = _members[vault];
        if (l.index != 0) return (address(0), bytes32(0), bytes32(0));
        return (l.owner, l.strategyId, l.configHash);
    }

    /// Any member this factory created: its owner, strategy id, configuration hash and index (0 the hub);
    /// zeros otherwise.
    function memberOf(address member)
        external
        view
        returns (address owner, bytes32 strategyId, bytes32 configHash, uint8 index)
    {
        Member storage l = _members[member];
        return (l.owner, l.strategyId, l.configHash, l.index);
    }

    /// Every member's address (the hub first), deployed or not, on every chain (this factory's address is
    /// the same there).
    function memberAddresses(bytes32 strategyId, address owner, StrategyConfig calldata cfg)
        external
        view
        returns (address[] memory members, bytes32 configHash)
    {
        configHash = keccak256(abi.encode(cfg));
        (members,,) = _members_(VaultConfig.pairId(strategyId, owner, configHash), cfg);
    }

    function hubDomains() external view returns (uint32[] memory) {
        return _hubDomains;
    }

    /// What a hub created on this chain reads at its initialisation (amendment 2b §3.8): this chain's
    /// price sources, its sequencer feed (zero: none, Ethereum), and each leg pin's `valueKind` in leg
    /// order.
    function hubSetup()
        external
        view
        returns (PriceSourcePin[] memory prices, address sequencer, uint8[] memory valueKinds)
    {
        uint32 here = IMessageTransmitterV2(MESSAGE_TRANSMITTER).localDomain();
        uint256 n;
        for (uint256 i; i < _prices.length; ++i) {
            if (_prices[i].hubDomain == here) ++n;
        }
        prices = new PriceSourcePin[](n);
        n = 0;
        for (uint256 i; i < _prices.length; ++i) {
            if (_prices[i].hubDomain == here) prices[n++] = _prices[i];
        }
        for (uint256 i; i < _sequencers.length; ++i) {
            if (_sequencers[i].hubDomain == here) sequencer = _sequencers[i].feed;
        }
        valueKinds = new uint8[](_legs.length);
        for (uint256 i; i < _legs.length; ++i) {
            valueKinds[i] = _legs[i].valueKind;
        }
    }

    /// Every price source and sequencer feed pinned, on every hub chain.
    function pricePins() external view returns (PriceSourcePin[] memory, SequencerPin[] memory) {
        return (_prices, _sequencers);
    }

    function legCount() external view returns (uint256) {
        return _legs.length;
    }

    function leg(uint256 i) external view returns (LegPin memory) {
        return _legs[i];
    }

    /// An EIP-1167 clone's CREATE2 address (OpenZeppelin Clones v5 layout, as step 11e1's factory).
    function predictClone(address deployer, address impl, bytes32 salt) public pure returns (address predicted) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), deployer)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), impl)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            predicted := and(keccak256(add(ptr, 0x43), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    // ── internals ──────────────────────────────────────────────────────────────────────────────────────

    /// Member `i`'s struct hash in `CreateVault`: its type hash then its parameters, exactly its pinned
    /// field count of words (so no trailing word can change `configHash` without changing the message).
    function _paramsHash(uint256 i, bytes calldata params) internal view returns (bytes32) {
        if (params.length != uint256(_fieldCounts[i]) * 32) revert BadConfig();
        return keccak256(bytes.concat(_typeHashes[i], params));
    }

    /// A local member code's own declaration (`paramsType()`) against its pin.
    function _checkType(address code, string memory name, string memory fields) internal view {
        if (keccak256(bytes(IMember(code).paramsType())) != keccak256(abi.encodePacked(name, "(", fields, ")"))) {
            revert BadPins();
        }
    }

    /// Records each member type's hash and field count, and composes `CreateVault`'s EIP-712 type: the
    /// primary type (the hub as `hub`, leg `i` as `leg<i+1>`), then each member type once, sorted by
    /// name. A pin with no name, no fields, a field count other than its fields', a name reused for other
    /// fields, or `CreateVault`'s own name is refused.
    function _composeTypes(string memory hubName, string memory hubFields, uint8 hubCount, LegPin[] memory legs_)
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
        // each member type once (a type used twice must be the same), in name order: EIP-712's encodeType
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

    /// The number of fields in a type's field list: its commas plus one; zero for an empty list.
    function _fieldsIn(bytes memory f) internal pure returns (uint256 c) {
        if (f.length == 0) return 0;
        c = 1;
        for (uint256 i; i < f.length; ++i) {
            if (f[i] == ",") ++c;
        }
    }

    /// Whether `a` sorts before `b`, byte by byte (EIP-712 sorts the referenced types by name).
    function _before(bytes memory a, bytes memory b) internal pure returns (bool) {
        uint256 m = a.length < b.length ? a.length : b.length;
        for (uint256 i; i < m; ++i) {
            if (a[i] != b[i]) return a[i] < b[i];
        }
        return a.length < b.length;
    }

    /// The deposit contract's chains (`DepositAccount._depositDomain`): Ethereum 0, Avalanche 1,
    /// OP Mainnet 2, Arbitrum 3, Base 6, Polygon 7, HyperEVM 19.
    function _depositDomain(uint32 d) internal pure returns (bool) {
        return d <= 3 || d == 6 || d == 7 || d == 19;
    }

    /// The deposit chains whose sequencer Chainlink watches (an uptime feed): OP Mainnet 2, Arbitrum 3,
    /// Base 6. Ethereum (0) and Avalanche's C-Chain (1) have none to watch; Polygon PoS (7) and HyperEVM
    /// (19) have no such feed.
    function _rollup(uint32 d) internal pure returns (bool) {
        return d == 2 || d == 3 || d == 6;
    }

    function _hubDomainAllowed(uint32 d) internal view returns (bool) {
        uint256 h = _hubDomains.length;
        for (uint256 i; i < h; ++i) {
            if (_hubDomains[i] == d) return true;
        }
        return false;
    }

    /// Every member's address, chain and code, in member order (0 the hub).
    function _members_(bytes32 pair, StrategyConfig calldata cfg)
        internal
        view
        returns (address[] memory at, uint32[] memory domains, address[] memory codes)
    {
        uint256 n = cfg.legs.length + 1;
        at = new address[](n);
        domains = new uint32[](n);
        codes = new address[](n);
        for (uint256 i; i < n; ++i) {
            (codes[i], domains[i]) = i == 0 ? (hubCode, cfg.hubDomain) : (cfg.legs[i - 1].code, cfg.legs[i - 1].domain);
            at[i] = predictClone(address(this), codes[i], VaultConfig.legSalt(pair, i));
        }
    }

    /// Every member but `i`, in member order: a leg's link 0 is its hub.
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

    function _clone(address impl, bytes32 salt) internal returns (address made) {
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
            made := create2(0, 0x09, 0x37, salt)
        }
        if (made == address(0)) revert DeployFailed();
    }
}
