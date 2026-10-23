// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {HyperCoreLegState} from "../../src/HyperCoreLegState.sol";
import {AssetProfile} from "../../src/Types.sol";
import {Holding} from "../../src/lib/VaultTypes.sol";

/// The Hyperliquid leg, version 1, as one interface: the member, its two exit modules and the upgrade
/// module (generated from their ABIs with `cast interface`, version 1's own struct types), for version 0's
/// suites ported onto it.
interface IHyperCoreLegV1 {



    error AlreadyInitialized();
    error AlreadyPending();
    error BadAsset();
    error BadLinks();
    error BadMessage();
    error BadModule();
    error BadParams();
    error BadProfile();
    error BadSignature();
    error Exiting();
    error Expired();
    error FeeAboveCap();
    error GasTooLow();
    error GroupNotStopped();
    error IsPaused();
    error NoAgent();
    error NoCoreAccount();
    error NotAllowed();
    error NotDue();
    error NotExecution();
    error NotExiting();
    error NotListed();
    error NotOwnerWallet();
    error NotPending();
    error NotReady();
    error NotResidue();
    error OverFeeBudget();
    error PrecompileFailed(address precompile);
    error Reentrancy();
    error RemovalPending();
    error TooEarly();
    error Unsupported();
    error ZeroAmount();

    event ActionCancelled(uint8 indexed kind, bytes32 target, uint64 due);
    event ActionCleared(uint8 indexed kind, bytes32 target, uint8 why);
    event ActionScheduled(uint8 indexed kind, bytes32 target, uint64 due, bytes32 by);
    event AgentCancelled();
    event AgentProposed(address indexed agent, uint256 effectiveAt);
    event AgentSet(address indexed agent);
    event DexWatched(uint32 indexed dex);
    event ExecutionRevoked(bool revoked);
    event ExitBegun(uint8 by);
    event Initialized(address indexed owner, uint8 group, bytes32 strategyId, bytes32 configHash);
    event LinkReady(uint8 indexed link);
    event LinkTold(uint8 indexed link);
    event LinkToldPending(uint8 indexed link);
    event Paused(bool paused);
    event ReadyPending(uint8 indexed link);
    event ReadySent(uint8 indexed link);
    event ReceivedFromLink(uint8 indexed link, uint256 amount, uint256 fee);
    event ReceivedFromOther(address indexed sender, uint32 sourceDomain, uint256 amount);
    event ReportSent(uint64 seq);
    event Sent(uint8 indexed link, uint256 amount, uint256 maxFee, uint32 minFinalityThreshold);
    event UpgradePending(uint8 indexed link);
    event UpgradeSent(uint8 indexed link, bytes32 manifest, uint256 publishedAt);
    event Upgraded(address indexed implementation);

    receive() external payable;

    function CLOSING() external view returns (uint8);
    function CODE_VERSION() external pure returns (uint32);
    function CORE_DEPOSIT_WALLET() external view returns (address);
    function EXIT_MESSAGE() external view returns (bytes32);
    function HYPE_SYSTEM() external view returns (address);
    function MEMBER_TYPE() external pure returns (uint8);
    function NOT_IN_EXIT() external view returns (uint8);
    function READY_MESSAGE() external view returns (bytes32);
    function RECOVERED() external view returns (uint8);
    function RECOVERED_WITH_RESIDUE() external view returns (uint8);
    function REPORT_MESSAGE() external view returns (bytes32);
    function UPGRADE_MESSAGE() external view returns (bytes32);
    function USDC() external view returns (address);
    function USDC_SYSTEM() external view returns (address);
    function agent() external view returns (address);
    function agentEverSet() external view returns (bool);
    function announceReady(uint8 k) external;
    function applyAgent() external;
    function applyOwnerAgent() external;
    function applyUpgrade() external;
    function asset() external view returns (bytes32);
    function beginExit(uint256 deadline, bytes memory signature) external;
    function beginExitStopped() external;
    function bridgeOut() external;
    function burner() external view returns (address);
    function cancel(uint32 asset, bool byCloid, uint128 id) external;
    function cancelPendingAction(uint8 kind, bytes32 target, uint256 due, uint256 deadline, bytes memory signature)
        external;
    function checkProfile(AssetProfile memory p) external view;
    function codeVersion() external view returns (uint32);
    function configHash() external view returns (bytes32);
    function createdAt() external view returns (uint64);
    function dexSince(uint32) external view returns (uint64);
    function executionRevoked() external view returns (bool);
    function exitAgent() external view returns (address);
    function exitModule() external view returns (address);
    function exitModuleB() external view returns (address);
    function exitStartedAt() external view returns (uint64);
    function exitStatus()
        external
        view
        returns (uint8 state, uint32[] memory dexes, uint64[4] memory residue, uint256 flags);
    function exitStep(HyperCoreLegState.ExitArgs memory a) external;
    function exitTransfer(uint256 amount) external;
    function exiting() external view returns (bool);
    function factory() external view returns (address);
    function fastFeeCapBp() external view returns (uint16);
    function feeBudgetBp() external view returns (uint16);
    function feeDay() external view returns (uint64);
    function feeToday() external view returns (uint96);
    function feeYesterday() external view returns (uint96);
    function feesFrom(uint256) external view returns (uint256);
    function floor() external view returns (uint256);
    function floorSet() external view returns (bool);
    function followMessage(bytes32 manifest, uint256 publishedAt) external;
    function followUpgrade(bytes32 manifest) external;
    function fromMargin(uint64 amount) external;
    function group() external view returns (uint8);
    function handleReceiveFinalizedMessage(uint32 sourceDomain, bytes32 sender, uint32 finality, bytes memory body)
        external
        returns (bool);
    function handleReceiveUnfinalizedMessage(uint32 sourceDomain, bytes32 sender, uint32, bytes memory body)
        external
        returns (bool);
    function holdings()
        external
        view
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool);
    function initialize(
        address owner_,
        address registry_,
        address[] memory links_,
        uint32[] memory domains_,
        uint8 group_,
        bytes32 strategyId_,
        bytes32 configHash_,
        bytes memory params
    ) external;
    function lastCoreMove() external view returns (uint64);
    function lastPublishedAt() external view returns (uint64);
    function lastSent(bytes32) external view returns (uint256);
    function legExit() external;
    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind);
    function linkCount() external view returns (uint8);
    function linkDomains(uint256) external view returns (uint32);
    function links(uint256) external view returns (address);
    function listingRegistry() external view returns (address);
    function localLinks() external view returns (uint8);
    function marginTriedAt() external view returns (uint64);
    function memberType() external view returns (uint8);
    function notifyLink(uint8 k) external;
    function opCount() external view returns (uint64);
    function order(bool isBuy, uint64 sz, bool reduceOnly) external;
    function orderBoundBp() external view returns (uint16);
    function owner() external view returns (address);
    function ownerAction(uint8 action, address agent, bytes32 credential, uint256 deadline, bytes memory signature)
        external;
    function ownerAgent() external view returns (address);
    function ownerAgentAt() external view returns (uint64);
    function ownerNonceOf(bytes32) external view returns (uint256);
    function ownerOrder(
        uint32 asset,
        bool isBuy,
        uint64 size,
        uint64 limitPx,
        uint8 szDecimals,
        bytes32 credential,
        uint256 deadline,
        bytes memory signature
    ) external;
    function paramsType() external pure returns (string memory);
    function pause(bool on) external;
    function paused() external view returns (bool);
    function pendingAction() external view returns (uint8 kind, uint64 due, bytes32 by, bytes32 target);
    function pendingAgent() external view returns (address);
    function pendingAgentAt() external view returns (uint64);
    function perp() external view returns (uint32);
    function prime() external;
    function profile() external view returns (bytes32);
    function proposeAgent(address next) external;
    function proposeSweep(address to) external;
    function publishUpgrade(uint8 k) external;
    function purchases() external view returns (uint8);
    function ready(uint8 k) external view returns (bool);
    function readyLinks() external view returns (uint8);
    function receiveLocal(uint256 amount) external;
    function receiveMint(bytes memory message, bytes memory attestation) external;
    function receivedFrom(uint256) external view returns (uint256);
    function receivedFromOthers() external view returns (uint256);
    function registry() external view returns (address);
    function report() external;
    function reportSeq() external view returns (uint64);
    function reserved() external view returns (uint64);
    function scheduleUpgrade(bytes32 manifest, bytes32 credential, uint256 deadline, bytes memory signature) external;
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external;
    function sentTo(uint256) external view returns (uint256);
    function strategyId() external view returns (bytes32);
    function sweepResidue(uint64 token, address to) external;
    function sweepSince(address) external view returns (uint64);
    function toMargin(uint256 amount) external;
    function toldPending() external view returns (uint8);
    function topUpHype(uint256 amount) external payable;
    function upgradeModule() external view returns (address);
    function validateParams(bytes memory params) external view;
}
