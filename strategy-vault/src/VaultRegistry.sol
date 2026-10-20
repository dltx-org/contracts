// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * The registry (step 11e2 amendment 2a §3.4): one per chain, created through the deterministic deployer
 * with the operator's RECOVERY key as its only constructor argument, so it lands at the same address on
 * every chain. Every combination factory on the chain names it, and every leg reads its group's key and
 * the group's check-in from it (decision 37): one key and one daily check-in per group per chain,
 * whatever the combination.
 *
 * Amendment 2b §3.9 adds DLTX's FEE ADDRESS on this chain: the one destination of a hub's performance fee,
 * read by the hub at the moment of payment. Changed only by recovery in two steps (recovery proposes, the
 * new address accepts, as recovery's own handover), so a typo can't send fees to an address nobody
 * controls. Until one is accepted it is zero: a hub defers its charges and an exit forgives its due.
 *
 * It holds nothing else: no partner, no code, no owner record, no other destination.
 */
contract VaultRegistry {
    /// Groups available (amendment 2a §11.4): unused groups cost nothing; isolation is by group.
    uint8 public constant GROUPS = 16;
    uint256 public constant STOP_AFTER = 7 days;

    address public recovery;
    address public pendingRecovery;
    mapping(uint8 => address) public executionKey;
    mapping(uint8 => uint256) public lastCheckIn;
    /// DLTX's fee address on this chain (amendment 2b §3.9); zero until one accepts.
    address public feeAddress;
    address public pendingFeeAddress;

    event ExecutionKeySet(uint8 indexed group, address indexed previous, address indexed next);
    event CheckIn(uint8 indexed group, uint256 at);
    event RecoveryProposed(address indexed current, address indexed proposed);
    event RecoverySet(address indexed previous, address indexed next);
    event FeeAddressProposed(address indexed current, address indexed proposed);
    event FeeAddressSet(address indexed previous, address indexed next);

    error NotAllowed();
    error ZeroAddress();
    error BadGroup();

    constructor(address recovery_) {
        if (recovery_ == address(0)) revert ZeroAddress();
        recovery = recovery_;
    }

    /// Recovery sets or replaces one group's key; that group's legs follow at once. The group's FIRST
    /// key starts its check-in clock; a replacement is not itself a check-in, but recovery can name a key
    /// it holds, which then checks in (the combined review's CR-F1: the hatch is for a DLTX that has gone).
    function setExecutionKey(uint8 group, address key) external {
        if (msg.sender != recovery) revert NotAllowed();
        if (group >= GROUPS) revert BadGroup();
        if (key == address(0)) revert ZeroAddress();
        emit ExecutionKeySet(group, executionKey[group], key);
        if (executionKey[group] == address(0)) lastCheckIn[group] = block.timestamp;
        executionKey[group] = key;
    }

    /// The group's key, daily, whatever its strategies need.
    function checkIn(uint8 group) external {
        if (group >= GROUPS || msg.sender != executionKey[group]) revert NotAllowed();
        lastCheckIn[group] = block.timestamp;
        emit CheckIn(group, block.timestamp);
    }

    /// 7 days without a check-in (or no key ever set): anyone may run the exit of the group's legs.
    function stopped(uint8 group) external view returns (bool) {
        return block.timestamp >= lastCheckIn[group] + STOP_AFTER;
    }

    function proposeRecovery(address next) external {
        if (msg.sender != recovery) revert NotAllowed();
        pendingRecovery = next;
        emit RecoveryProposed(recovery, next);
    }

    function acceptRecovery() external {
        if (msg.sender != pendingRecovery) revert NotAllowed();
        emit RecoverySet(recovery, msg.sender);
        recovery = msg.sender;
        pendingRecovery = address(0);
    }

    /// Recovery proposes the chain's next fee address; zero withdraws a pending proposal.
    function proposeFeeAddress(address next) external {
        if (msg.sender != recovery) revert NotAllowed();
        pendingFeeAddress = next;
        emit FeeAddressProposed(feeAddress, next);
    }

    /// The proposed address itself accepts, proving it is controlled.
    function acceptFeeAddress() external {
        if (msg.sender != pendingFeeAddress) revert NotAllowed();
        emit FeeAddressSet(feeAddress, msg.sender);
        feeAddress = msg.sender;
        pendingFeeAddress = address(0);
    }
}
