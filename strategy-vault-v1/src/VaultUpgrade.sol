// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {ILinkV1, MemberState} from "./MemberState.sol";
import {IRegistryV1} from "./Interfaces.sol";
import {Holding} from "./lib/VaultTypes.sol";
import {MemberTypes, OwnerMessagesV1} from "./Types.sol";

/*
 * THE UPGRADE PATH (owner-upgrades-design.md §A2, §A4, §C3, §C4): one module per chain, shared by every
 * member type (the hub, the AAVE asset leg, the Hyperliquid leg), compiled against `MemberState` alone, so
 * its layout is a PREFIX of each member's (`test.mjs`). It runs only by DELEGATECALL from an initialised
 * instance (`delegated`): in its own storage, or an implementation's, `factory` is the sentinel.
 *
 * The HUB is the strategy's home. The owner signs `UpgradeStrategy(hub, chainId, manifest, nonce,
 * deadline)` (one credential, its vault nonce spent): 24 hours later anyone applies it at the hub, whose
 * slot moves to the version's hub implementation; the hub then tells every leg, the one beside it by a
 * direct `followUpgrade`, the one on another chain by Circle (`.upgrade.v1`, finalized). A leg never takes
 * an owner's signature for an upgrade: it resolves the manifest on ITS OWN chain's registry (the same
 * number can never mean other code there: a manifest unlisted there reverts, so the message waits) and
 * follows forward only. Anyone may republish the hub's current manifest (`publishUpgrade`), so a leg left
 * behind always catches up. An upgrade moves nothing (no money, no position, no fee event: V3, AP-11) and
 * is allowed during an exit (Q12). The one cancel (`CancelPendingAction`, nonce-free, any credential in
 * effect, until applied) names exactly the action it cancels, a profile switch included.
 */
contract VaultUpgrade is MemberState {
    /// A follower ignores an upgrade message published longer ago than this (§A4).
    uint256 internal constant FOLLOW_MAX_AGE = 3 days;

    event UpgradeSent(uint8 indexed link, bytes32 manifest, uint256 publishedAt);
    event UpgradePending(uint8 indexed link);

    modifier hubOnly() {
        if (memberType != MemberTypes.HUB) revert Unsupported();
        _;
    }

    // ── at the hub ───────────────────────────────────────────────────────────────────────────────────

    /// The owner's `UpgradeStrategy`, by `credential` (its signer): the manifest must be listed on this
    /// chain's registry at a version above the hub's; refused while any action is pending, from a
    /// credential whose removal is pending, and under the money lock.
    function scheduleUpgrade(bytes32 manifest, bytes32 credential, uint256 deadline, bytes calldata signature)
        external
        delegated
        hubOnly
        nonReentrant
    {
        _checkOwnerAs(
            credential,
            keccak256(
                abi.encode(
                    OwnerMessagesV1.UPGRADE_STRATEGY_TYPEHASH,
                    address(this),
                    block.chainid,
                    manifest,
                    ownerNonceOf[credential],
                    deadline
                )
            ),
            deadline,
            signature
        );
        uint256 v = IRegistryV1(registry).versionOf(manifest);
        if (v <= codeVersion || IRegistryV1(registry).implementation(v, MemberTypes.HUB) == address(0)) {
            revert NotListed();
        }
        _schedule(OwnerMessagesV1.KIND_UPGRADE, manifest, credential);
    }

    /// The owner's `CancelPendingAction(hub, chainId, kind, target, due, deadline)`: any credential in
    /// effect, no nonce, until applied; it cancels only the action it names.
    function cancelPendingAction(uint8 kind, bytes32 target, uint256 due, uint256 deadline, bytes calldata signature)
        external
        delegated
        hubOnly
        nonReentrant
    {
        _checkOwner(
            keccak256(
                abi.encode(
                    OwnerMessagesV1.CANCEL_PENDING_ACTION_TYPEHASH,
                    address(this),
                    block.chainid,
                    kind,
                    target,
                    due,
                    deadline
                )
            ),
            deadline,
            signature
        );
        PendingAction memory p = _pending;
        if (p.kind == 0 || p.kind != kind || p.target != target || p.due != due) revert NotPending();
        delete _pending;
        emit ActionCancelled(kind, target, uint64(due));
    }

    /// Anyone, once due, outside the money lock: the hub moves to the version's hub implementation, then
    /// tells every leg. A schedule whose credential no longer stands is cleared instead.
    function applyUpgrade() external delegated hubOnly nonReentrant {
        (bool ok, bytes32 manifest) = _takeDue(OwnerMessagesV1.KIND_UPGRADE);
        if (!ok) return;
        uint256 v = IRegistryV1(registry).versionOf(manifest);
        _setImplementation(IRegistryV1(registry).implementation(v, MemberTypes.HUB), v);
        lastPublishedAt = uint64(block.timestamp);
        uint8 n = linkCount;
        for (uint8 k; k < n; ++k) {
            _tellUpgrade(k, manifest, true);
        }
    }

    /// Anyone, at any time: the hub's CURRENT manifest to leg `k` with a fresh `publishedAt` (a leg created
    /// after its hub moved, or whose message expired or met a version its chain had not yet listed).
    /// Reverts as Circle (or the leg) does.
    function publishUpgrade(uint8 k) external delegated hubOnly nonReentrant {
        if (k >= linkCount) revert NotAllowed();
        _tellUpgrade(k, IRegistryV1(registry).manifestOf(codeVersion), false);
    }

    function _tellUpgrade(uint8 k, bytes32 manifest, bool soft) internal {
        if (_isLocal(k)) {
            address leg = links[k];
            if (leg.code.length == 0) {
                if (soft) {
                    emit UpgradePending(k);
                    return;
                }
                revert NotReady();
            }
            ILinkV1(leg).followUpgrade(manifest);
            emit UpgradeSent(k, manifest, block.timestamp);
            return;
        }
        if (_message(k, abi.encode(UPGRADE_MESSAGE, manifest, block.timestamp), FINALITY_STANDARD, soft)) {
            emit UpgradeSent(k, manifest, block.timestamp);
        } else {
            emit UpgradePending(k);
        }
    }

    /// The pending action: its kind (0 none, 1 an upgrade, 2 a profile switch), due time, scheduling
    /// credential and target.
    function pendingAction() external view delegated returns (uint8 kind, uint64 due, bytes32 by, bytes32 target) {
        PendingAction memory p = _pending;
        return (p.kind, p.due, p.by, p.target);
    }

    // ── at a leg ─────────────────────────────────────────────────────────────────────────────────────

    /// The hub beside this leg (its link 0, on this chain), in the transaction that moved it; refused
    /// under this leg's own money lock.
    function followUpgrade(bytes32 manifest) external delegated nonReentrant {
        if (memberType == MemberTypes.HUB || msg.sender != links[0] || !_isLocal(0)) revert NotAllowed();
        _follow(manifest, block.timestamp);
    }

    /// The hub's `.upgrade.v1` message, delegated by `MemberBase._receive` (the fallback routes it too, but
    /// only Circle's transmitter passes, and it calls a member's handlers only): ignored when published
    /// before this leg's creation, not after its last applied upgrade, or more than 3 days ago.
    function followMessage(bytes32 manifest, uint256 publishedAt) external delegated nonReentrant {
        if (msg.sender != MESSAGE_TRANSMITTER) revert NotAllowed();
        if (
            publishedAt < createdAt || publishedAt <= lastPublishedAt || publishedAt + FOLLOW_MAX_AGE < block.timestamp
        ) return;
        _follow(manifest, publishedAt);
    }

    /// Resolves `manifest` on this chain's registry: unlisted reverts (the message waits, relayable); a
    /// version not above this one's is ignored; else the slot moves to this member type's implementation.
    function _follow(bytes32 manifest, uint256 publishedAt) internal {
        uint256 v = IRegistryV1(registry).versionOf(manifest);
        if (v == 0) revert NotListed();
        if (v <= codeVersion) return;
        address impl = IRegistryV1(registry).implementation(v, memberType);
        if (impl == address(0)) revert NotListed();
        _setImplementation(impl, v);
        lastPublishedAt = uint64(publishedAt);
    }

    // ── what MemberState asks of a contract with its layout (unused here) ────────────────────────────

    function _usdc() internal pure override returns (address) {
        revert Unsupported();
    }

    function _holdings() internal pure override returns (Holding[] memory, uint256) {
        revert Unsupported();
    }

    function _tracked() internal pure override returns (bool) {
        return true;
    }
}
