// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/// The AAVE V3 asset leg as one interface: the member, its exit and rewards modules and the upgrade module
/// (generated from their ABIs with `cast interface`), for tests that call an instance by its address.
interface IAssetLegV1 {
    struct AssetProfile {
        address asset;
        uint8 assetDecimals;
        address aAsset;
        address swapPool;
        uint24 swapFee;
        bool assetIsToken0;
        bytes32 holdingAsset;
        uint16 minBoundBp;
        address rateFeed;
        bytes32 rateDescription;
        uint32 rateMaxAge;
        uint32 perp;
        bytes32 perpCoin;
        uint8 szDecimals;
        bytes32 underlying;
        bytes32 shortAsset;
        PricePin[2] pins;
    }

    struct Holding {
        bytes32 asset;
        int256 quantity;
    }

    struct PricePin {
        bytes32 asset;
        uint8 kind;
        address feed;
        address baseFeed;
        uint32 maxAge;
    }

    error AboveBound();
    error AlreadyInitialized();
    error AlreadyPending();
    error BadAsset();
    error BadLinks();
    error BadMessage();
    error BadModule();
    error BadParams();
    error BadProfile();
    error BadSignature();
    error BandCrossed();
    error BelowHealthFloor();
    error Exiting();
    error Expired();
    error FeeAboveCap();
    error GasTooLow();
    error GroupNotStopped();
    error HealthFell();
    error IsPaused();
    error NotAllowed();
    error NotDue();
    error NotExecution();
    error NotExiting();
    error NotListed();
    error NotPending();
    error NotReady();
    error OverBudget();
    error OverFeeBudget();
    error PoolOffOracle();
    error Reentrancy();
    error RemovalPending();
    error RewardCollateralOn();
    error StalePrice();
    error SwapShort();
    error Unsupported();
    error ZeroAmount();

    event ActionCancelled(uint8 indexed kind, bytes32 target, uint64 due);
    event ActionCleared(uint8 indexed kind, bytes32 target, uint8 why);
    event ActionScheduled(uint8 indexed kind, bytes32 target, uint64 due, bytes32 by);
    event ExecutionRevoked(bool revoked);
    event ExitBegun(uint8 by);
    event ExitPartFailed(uint8 part, bytes reason);
    event Initialized(address indexed owner, uint8 group, bytes32 strategyId, bytes32 configHash);
    event LinkReady(uint8 indexed link);
    event LinkTold(uint8 indexed link);
    event LinkToldPending(uint8 indexed link);
    event Paused(bool paused);
    event ProfileFollowed(bytes32 indexed fromProfile, bytes32 indexed toProfile);
    event ReadyPending(uint8 indexed link);
    event ReadySent(uint8 indexed link);
    event ReceivedFromLink(uint8 indexed link, uint256 amount, uint256 fee);
    event ReceivedFromOther(address indexed sender, uint32 sourceDomain, uint256 amount);
    event RepaidWithCollateral(uint256 debtRepaid, uint256 collateralOut, uint256 lossUsd);
    event ReportSent(uint64 seq);
    event RewardClaimed(uint8 source, uint256 gained);
    event RewardSwapped(uint256 rewardIn, uint256 usdcOut, uint256 lossUsd);
    event Sent(uint8 indexed link, uint256 amount, uint256 maxFee, uint32 minFinalityThreshold);
    event Swapped(bool assetToUsdc, uint256 amountIn, uint256 amountOut, uint256 lossUsd);
    event UpgradePending(uint8 indexed link);
    event UpgradeSent(uint8 indexed link, bytes32 manifest, uint256 publishedAt);
    event Upgraded(address indexed implementation);

    function CODE_VERSION() external pure returns (uint32);
    function EXIT_MESSAGE() external view returns (bytes32);
    function MEMBER_TYPE() external pure returns (uint8);
    function READY_MESSAGE() external view returns (bytes32);
    function REPORT_MESSAGE() external view returns (bytes32);
    function UPGRADE_MESSAGE() external view returns (bytes32);
    function announceReady(uint8 k) external;
    function applyUpgrade() external;
    function assetProfile()
        external
        view
        returns (
            bytes32 id,
            address asset,
            uint8 decimals,
            address aAsset,
            address swapPool,
            uint24 swapFee,
            bool assetIsToken0,
            bytes32 holdingAsset,
            uint16 minBoundBp,
            address rateFeed,
            uint32 rateMaxAge
        );
    function beginExit(uint256 deadline, bytes memory signature) external;
    function beginExitStopped() external;
    function borrow(uint256 amount) external;
    function cancelPendingAction(uint8 kind, bytes32 target, uint256 due, uint256 deadline, bytes memory signature)
        external;
    function checkProfile(AssetProfile memory p) external view;
    function claimMerkl(address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) external;
    function claimRewards() external;
    function codeVersion() external view returns (uint32);
    function collateralOff(address a) external;
    function configHash() external view returns (bytes32);
    function createdAt() external view returns (uint64);
    function dailyLossBp() external view returns (uint16);
    function executionRevoked() external view returns (bool);
    function exitDebt() external view returns (uint256);
    function exitModule() external view returns (address);
    function exitPart(uint8 part, uint256 arg) external;
    function exitStartedAt() external view returns (uint64);
    function exitStep(uint256 debtChunk, uint256 assetChunk) external;
    function exitTransfer(uint256 amount) external;
    function exiting() external view returns (bool);
    function factory() external view returns (address);
    function fastFeeCapBp() external view returns (uint16);
    function feeDay() external view returns (uint64);
    function feeToday() external view returns (uint96);
    function feeYesterday() external view returns (uint96);
    function feesFrom(uint256) external view returns (uint256);
    function followMessage(bytes32 manifest, uint256 publishedAt) external;
    function followSwitch(bytes32 toProfile) external;
    function followUpgrade(bytes32 manifest) external;
    function group() external view returns (uint8);
    function handleReceiveFinalizedMessage(uint32 sourceDomain, bytes32 sender, uint32 finality, bytes memory body)
        external
        returns (bool);
    function handleReceiveUnfinalizedMessage(uint32 sourceDomain, bytes32 sender, uint32, bytes memory body)
        external
        returns (bool);
    function healthFloor() external view returns (uint64);
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
    function lastPublishedAt() external view returns (uint64);
    function legExit() external;
    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind);
    function linkCount() external view returns (uint8);
    function linkDomains(uint256) external view returns (uint32);
    function links(uint256) external view returns (address);
    function listingRegistry() external view returns (address);
    function localLinks() external view returns (uint8);
    function lossDay() external view returns (uint64);
    function lossInWindow() external view returns (uint256);
    function lossToday() external view returns (uint96);
    function lossYesterday() external view returns (uint96);
    function memberType() external view returns (uint8);
    function notifyLink(uint8 k) external;
    function opCount() external view returns (uint64);
    function oracleBoundBp() external view returns (uint16);
    function owner() external view returns (address);
    function ownerAction(uint8 action, address agent, bytes32 credential, uint256 deadline, bytes memory signature)
        external;
    function ownerNonceOf(bytes32) external view returns (uint256);
    function paramsType() external pure returns (string memory);
    function pause(bool on) external;
    function paused() external view returns (bool);
    function pendingAction() external view returns (uint8 kind, uint64 due, bytes32 by, bytes32 target);
    function profile() external view returns (bytes32);
    function publishUpgrade(uint8 k) external;
    function ready(uint8 k) external view returns (bool);
    function readyLinks() external view returns (uint8);
    function receiveLocal(uint256 amount) external;
    function receiveMint(bytes memory message, bytes memory attestation) external;
    function receivedFrom(uint256) external view returns (uint256);
    function receivedFromOthers() external view returns (uint256);
    function registry() external view returns (address);
    function repay(uint256 amount) external;
    function repayWithCollateral(uint256 debt, uint256 maxCollateral) external;
    function report() external;
    function reportSeq() external view returns (uint64);
    function rewardCollateralOff() external;
    function rewardPart(uint8 part) external;
    function rewardPins()
        external
        view
        returns (
            address[2] memory sources,
            address reward,
            address aReward,
            address pool,
            address feed,
            uint256 maxAge,
            uint256 boundBp
        );
    function rewardsModule() external view returns (address);
    function scheduleUpgrade(bytes32 manifest, bytes32 credential, uint256 deadline, bytes memory signature) external;
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external;
    function sentTo(uint256) external view returns (uint256);
    function setEMode(uint8 category) external;
    function strategyId() external view returns (bytes32);
    function supply(uint256 amount) external;
    function swap(bool assetToUsdc, uint256 amountIn, uint256 minOut) external returns (uint256);
    function swapReward(uint256 amountIn, uint256 minOut) external returns (uint256);
    function toldPending() external view returns (uint8);
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory) external;
    function upgradeModule() external view returns (address);
    function validateParams(bytes memory params) external view;
    function withdraw(address a, uint256 amount) external;
}
