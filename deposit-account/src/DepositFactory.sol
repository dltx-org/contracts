// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccount} from "./DepositAccount.sol";

/*
 * The deposit factory — docs/architecture/rework/specs/step-11e2-strategy-vault-design.md §8.1.
 *
 * Created through the deterministic deployer (0x4e59…956C) with the same salt and the same
 * constructor arguments on every chain; it makes `DepositAccount` as its first CREATE, so the factory,
 * the implementation and every user's account land at the same address everywhere.
 *
 * A user's account is an EIP-1167 clone at CREATE2 salt keccak256(abi.encode(user, owners)): the
 * user's uuid (left-padded to 32 bytes, as step 11e1's) and their FIRST owner set (decision 22).
 * ANYONE may deploy it, on any chain; it always starts with that owner set.
 *
 * The only constructor argument, so part of every address: the operator's offline RECOVERY key, which
 * may set the transfer key, the fee recipient and its own successor (two steps), and nothing else. No
 * vault factory is named here (amendment 1): each account trusts the factories its owner authorises.
 *
 * The TRANSFER KEY (step 11e1's relayer, a KMS key) is unset until recovery sets it on each chain,
 * then rotated by itself or recovery. It CHECKS IN daily; `stopped()` is true after 7 days without a
 * check-in, counted from this factory's deployment until the first one (decision 17). Then anyone
 * may run an account's withdrawal to its fixed address.
 */
contract DepositFactory {
    uint256 public constant STOP_AFTER = 7 days;

    address public immutable implementation;
    /// The platform's KMS key (step 11e1's relayer). Unset until recovery sets it.
    address public transferKey;
    /// The operator's offline key: the transfer key, the fee recipient, its own handover; nothing else.
    address public recovery;
    /// A recovery key proposed by recovery, effective when it accepts.
    address public pendingRecovery;
    /// Where an owner-signed withdrawal's fee goes (decision 19). Zero: no fee can be taken.
    address public feeRecipient;
    /// The transfer key's last check-in; this factory's deployment until the first.
    uint256 public lastCheckIn;

    event Deployed(bytes32 indexed user, address indexed account, bytes32 salt);
    event TransferKeySet(address indexed previous, address indexed next, address indexed by);
    event CheckedIn(address indexed key, uint256 at);
    event FeeRecipientSet(address indexed previous, address indexed next);
    event RecoveryProposed(address indexed current, address indexed proposed);
    event RecoverySet(address indexed previous, address indexed next);

    error NotAllowed();
    error ZeroAddress();
    error DeployFailed();

    constructor(address recovery_) {
        if (recovery_ == address(0)) revert ZeroAddress();
        implementation = address(new DepositAccount());
        recovery = recovery_;
        lastCheckIn = block.timestamp;
    }

    // ── the accounts ─────────────────────────────────────────────────────────────────────────

    /// The salt of a user's account: their uuid (left-padded) and their first owner set, in order.
    function saltOf(bytes32 user, Credential[] calldata owners) public pure returns (bytes32) {
        return keccak256(abi.encode(user, owners));
    }

    /// The user's account address for this first owner set, deployed or not.
    function addressOf(bytes32 user, Credential[] calldata owners) external view returns (address) {
        return _predict(saltOf(user, owners));
    }

    /// Anyone: deploys the user's account with its first owner set, or returns it if it exists.
    /// Refused if the set is not a well-shaped owner set (exactly one credential since amendment 2d's
    /// decision 76: a point on P-256 or a non-zero address). No code is checked here, so an account can always be deployed
    /// where money already waits at its address; EOA-only is enforced before an address is shown.
    function deploy(bytes32 user, Credential[] calldata owners) external returns (address account) {
        bytes32 salt = saltOf(user, owners);
        account = _predict(salt);
        if (account.code.length != 0) return account;
        address impl = implementation;
        address made;
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
            made := create2(0, 0x09, 0x37, salt)
        }
        if (made != account) revert DeployFailed();
        DepositAccount(made).initialize(owners);
        emit Deployed(user, account, salt);
    }

    function _predict(bytes32 salt) internal view returns (address predicted) {
        address impl = implementation;
        // EIP-1167 creation code, as OpenZeppelin's Clones (v5) lays it out
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), address())
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), impl)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            predicted := and(keccak256(add(ptr, 0x43), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
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

    /// The transfer key, daily, whatever the accounts need (decision 17).
    function checkIn() external {
        if (msg.sender != transferKey) revert NotAllowed(); // never the zero address: no sender is
        lastCheckIn = block.timestamp;
        emit CheckedIn(msg.sender, block.timestamp);
    }

    /// True once 7 days have passed without a check-in: anyone may then run an account's withdrawal
    /// to its withdrawal address.
    function stopped() external view returns (bool) {
        return block.timestamp >= lastCheckIn + STOP_AFTER;
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
