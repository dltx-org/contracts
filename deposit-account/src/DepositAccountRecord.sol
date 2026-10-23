// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccountState, IDepositFactory, IMessageTransmitterV2} from "./DepositAccountState.sol";

/*
 * The deposit contract's record module — owner-upgrades-design.md §3.3, §3.4, §3.5.
 *
 * Version 1 of `DepositAccount` delegates here every selector it does not have, so these functions run
 * in the account's storage (`DepositAccountState`, the one layout both share). It holds THE OWNER
 * RECORD: the record changes and their cancellations, the record's copies, and the account's UPGRADE:
 *   - at the home (Arbitrum), the owner signs `ScheduleUpgrade` for a version its factory lists above
 *     this one; anyone applies it 24 hours later unless any credential in effect cancelled it first;
 *     one upgrade pending at most, never replaced (Q13);
 *   - the copies never take an owner's upgrade: they follow the implementation the home applied, by
 *     the home's own Circle message, forward only, if their own chain's factory lists it.
 *
 * It refuses a direct call (`delegated`): only an account runs it. The two functions that write the
 * ERC-1967 slot also refuse unless the running account is initialised, a test of state (§3.3,
 * `onlyProxy`): neither the implementation nor this module ever holds a credential.
 */
contract DepositAccountRecord is DepositAccountState {
    /// This module's own address: its functions refuse to run in its own storage.
    address private immutable _self;

    constructor(address factory_) DepositAccountState(factory_) {
        _self = address(this);
    }

    modifier delegated() {
        if (address(this) == _self) revert NotAllowed();
        _;
    }

    // ── record changes: the home only (§7.3, §7.4) ───────────────────────────────────────────

    /// Signed by a current credential; effective after 24 hours unless cancelled by any current
    /// credential (decision 31), so a stolen credential can't add its accomplices at once. A pending
    /// addition counts toward the four.
    function addCredential(Credential calldata c, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        delegated
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
    function cancelAddition(Credential calldata c, uint256 due, uint256 deadline, bytes calldata signature)
        external
        delegated
    {
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
    /// credential always remains, counting every removal already pending. A pending upgrade the
    /// credential being removed scheduled will not apply (`applyUpgrade`).
    function proposeRemoval(Credential calldata c, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        delegated
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
    function cancelRemoval(Credential calldata c, uint256 due, uint256 deadline, bytes calldata signature)
        external
        delegated
    {
        bytes32 signer =
            _cancel(keccak256(abi.encode(CANCEL_REMOVAL_TYPEHASH, c.kind, c.x, c.y, due, deadline)), deadline, signature);
        bytes32 id = credentialId(c);
        if (due == 0 || _removalDue[id] != due) revert NothingPending();
        if (signer == id && _standingFor(id) != 1) revert SelfCancel();
        delete _removalDue[id];
        delete _removalBy[id];
        emit RemovalCancelled(id, due);
    }

    /// The FIRST address (none ever in effect: `_recordChange` has settled any earlier one, due at its own
    /// block) takes effect at once (deposit-first-deposit-design.md, D1, amending decision 32). Every later
    /// one is effective after 24 hours unless cancelled (decision 15): a compromised
    /// web2 can't make an attacker's address live at once through a passkey's blind signature. A new
    /// proposal replaces a pending one and restarts its 24 hours.
    function setWithdrawalAddress(address next, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        delegated
    {
        _recordChange(keccak256(abi.encode(SET_WITHDRAWAL_ADDRESS_TYPEHASH, next, nonce, deadline)), nonce, deadline, signature);
        if (next == address(0)) revert ZeroAddress();
        uint256 due = _withdrawal == address(0) ? block.timestamp : block.timestamp + DELAY;
        _pendingWithdrawal = next;
        _pendingWithdrawalDue = uint64(due);
        emit WithdrawalAddressProposed(next, due);
    }

    /// Any current credential, before the change takes effect. No nonce: it names the change.
    function cancelWithdrawalAddress(address next, uint256 due, uint256 deadline, bytes calldata signature)
        external
        delegated
    {
        _cancel(keccak256(abi.encode(CANCEL_WITHDRAWAL_ADDRESS_TYPEHASH, next, due, deadline)), deadline, signature);
        if (due == 0 || _pendingWithdrawalDue != due || _pendingWithdrawal != next) revert NothingPending();
        _pendingWithdrawal = address(0);
        _pendingWithdrawalDue = 0;
        emit WithdrawalAddressCancelled(next, due);
    }

    // ── the upgrade at the home (owner-upgrades-design.md §3.4) ─────────────────────────────────

    /// A record change: the owner moves this account to `impl`, a version its factory lists above this
    /// one (forward only, Q3), after 24 hours. Refused while an upgrade is pending (no replacement: the
    /// owner cancels and signs again) and from a credential whose removal is pending.
    function scheduleUpgrade(address impl, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        delegated
    {
        bytes32 signer =
            _recordChange(keccak256(abi.encode(SCHEDULE_UPGRADE_TYPEHASH, impl, nonce, deadline)), nonce, deadline, signature);
        if (_removalDue[signer] != 0) revert RemovalPending();
        if (_upgradeDue != 0) revert AlreadyPending();
        uint256 v = IDepositFactory(factory).versionOf(impl);
        if (v <= CODE_VERSION()) revert BadImplementation();
        uint256 due = block.timestamp + DELAY;
        (_upgradeTo, _upgradeDue, _upgradeBy) = (impl, uint64(due), signer);
        emit UpgradeScheduled(impl, v, due);
    }

    /// Any credential in effect, the scheduler included, until the upgrade is APPLIED, not only until it
    /// is due (Q9). No nonce: it names the upgrade and its due time.
    function cancelUpgrade(address impl, uint256 due, uint256 deadline, bytes calldata signature) external delegated {
        _cancel(keccak256(abi.encode(CANCEL_UPGRADE_TYPEHASH, impl, due, deadline)), deadline, signature);
        if (due == 0 || _upgradeDue != due || _upgradeTo != impl) revert NothingPending();
        _clearUpgrade();
        emit UpgradeCancelled(impl, due);
    }

    /// Anyone, at the home, once the pending upgrade is due. Never under the money functions' lock (a
    /// token or recipient callback must not switch the code under a withdrawal). First every change
    /// already due lands under the code that accepted it; then the schedule dies with its signer: it is
    /// cleared, not applied, unless the credential that scheduled it is still in effect with no
    /// removal pending; then the slot moves. No migration call (Q4, I8).
    function applyUpgrade() external delegated {
        if (_creds.length == 0) revert NotInitialised(); // onlyProxy, by state
        if (!isHome()) revert NotHome();
        if (_entered) revert Reentered();
        uint256 due = _upgradeDue;
        if (due == 0) revert NothingPending();
        if (block.timestamp < due) revert NotDue();
        _settle();
        address impl = _upgradeTo;
        bytes32 by = _upgradeBy;
        _clearUpgrade();
        if (!_inEffect(by) || _removalDue[by] != 0) {
            emit UpgradeCancelled(impl, due);
            return;
        }
        _writeImplementation(impl);
    }

    /// Anyone, at the home, as often as needed: sends the implementation this account runs now to this
    /// same address on `domain`, with the time, through Circle's MessageTransmitterV2 (no burn, no fee,
    /// finalized, any relayer). The copy follows it if its chain lists it and it is higher (§3.5).
    function publishUpgrade(uint32 domain) external delegated {
        if (_creds.length == 0) revert NotInitialised();
        if (!isHome()) revert NotHome();
        if (domain == HOME_DOMAIN) revert BadDomain();
        address impl = _implementation();
        IMessageTransmitterV2(MESSAGE_TRANSMITTER).sendMessage(
            domain,
            bytes32(uint256(uint160(address(this)))),
            bytes32(0),
            FINALIZED,
            abi.encode(UPGRADE_TAG, impl, uint64(block.timestamp))
        );
        emit UpgradePublished(domain, impl);
    }

    // ── the record's copies (§7.3) ───────────────────────────────────────────────────────────

    /// Anyone, at the home: sends the whole record in effect and its version to this same address on
    /// `domain`, through Circle's MessageTransmitterV2 (no burn, no fee, finalized, any relayer).
    function publish(uint32 domain) external delegated {
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

    /// Circle's V2 handler, at a copy: the home's own message, finalized. A record: the first one is
    /// taken at any version if the home published it at or after this copy's deployment; afterwards a
    /// strictly higher version, or the same version published later, which renews the copy
    /// (RECORD_TTL); anything else from the home is ignored (and the message consumed), never reverted.
    /// An authorisation: `_receiveAuthorisation`. An upgrade: `_receiveUpgrade`.
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external delegated returns (bool) {
        if (msg.sender != MESSAGE_TRANSMITTER) revert NotTransmitter();
        if (_creds.length == 0) revert NotInitialised(); // the implementation, never an account
        if (isHome()) revert NotCopy();
        if (sourceDomain != HOME_DOMAIN || sender != bytes32(uint256(uint160(address(this))))) revert NotHomeMessage();
        if (finalityThresholdExecuted < FINALIZED) revert NotFinalized();
        if (messageBody.length < 32) revert BadMessage();
        bytes32 head = bytes32(messageBody[:32]);
        if (head == AUTH_TAG) return _receiveAuthorisation(messageBody);
        if (head == UPGRADE_TAG) return _receiveUpgrade(messageBody);
        (bytes32 tag, uint64 v, uint64 publishedAt, address w, Credential[] memory creds) =
            abi.decode(messageBody, (bytes32, uint64, uint64, address, Credential[]));
        if (tag != RECORD_TAG) revert BadMessage();
        if (_synced) {
            // afterwards, a strictly higher version, or the same one published later (a renewal)
            if (v < _version || publishedAt <= recordPublishedAt) {
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
        recordPublishedAt = publishedAt;
        _synced = true;
        emit RecordApplied(v);
        return true;
    }

    /// A record is accepted finalized only.
    function handleReceiveUnfinalizedMessage(uint32, bytes32, uint32, bytes calldata) external pure returns (bool) {
        revert NotFinalized();
    }

    // ── internals ────────────────────────────────────────────────────────────────────────────

    /// The home's applied implementation, at a copy (§3.5): reverts while this chain's factory does not
    /// list it (the message stays relayable until it does); ignored (consumed) if published before this
    /// copy was deployed, before the last upgrade it applied (two messages of the same second both
    /// count: a replay is refused as not higher), more than UPGRADE_TTL ago, or not higher than this
    /// version (never backwards); else every due change settles and the slot moves.
    /// No 24 hours here: they were served at the home. Never under the money functions' lock.
    function _receiveUpgrade(bytes calldata body) internal returns (bool) {
        if (_entered) revert Reentered();
        (, address impl, uint64 publishedAt) = abi.decode(body, (bytes32, address, uint64));
        uint256 v = IDepositFactory(factory).versionOf(impl);
        if (v == 0) revert BadImplementation();
        if (
            publishedAt < _deployedAt || publishedAt < _upgradePublishedAt
                || block.timestamp > uint256(publishedAt) + UPGRADE_TTL || v <= CODE_VERSION()
        ) {
            emit UpgradeIgnored(impl, publishedAt);
            return true;
        }
        _settle();
        _upgradePublishedAt = publishedAt;
        _writeImplementation(impl);
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

    function _clearUpgrade() internal {
        (_upgradeTo, _upgradeDue, _upgradeBy) = (address(0), 0, bytes32(0));
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
}
