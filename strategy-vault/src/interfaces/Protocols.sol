// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * The protocol interfaces the vault calls, inlined (the on-chain tier's rule): only the functions used.
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ── AAVE V3 (Arbitrum) ─────────────────────────────────────────────────────────────────────────────

/// `IPool.getReserveData`'s return (V3's `ReserveDataLegacy` layout); only `id` is read.
struct AaveReserveData {
    uint256 configuration;
    uint128 liquidityIndex;
    uint128 currentLiquidityRate;
    uint128 variableBorrowIndex;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40 lastUpdateTimestamp;
    uint16 id;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function repayWithATokens(address asset, uint256 amount, uint256 interestRateMode) external returns (uint256);
    function setUserEMode(uint8 categoryId) external;
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    /// The user's bitmap: bit 2·id borrowing, bit 2·id + 1 collateral, for the reserve of id `id`.
    function getUserConfiguration(address user) external view returns (uint256);
    function getReserveData(address asset) external view returns (AaveReserveData memory);
    /// What the reserve holds for withdrawals and borrows (AAVE 3.1+), the asset's units (amendment 2d).
    function getVirtualUnderlyingBalance(address asset) external view returns (uint128);
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

/// AAVE's price oracle: the price its health factor uses, in the base currency (USD, 8 decimals).
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// AAVE's RewardsController: claims to `msg.sender` (amendment 2c §3.3).
interface IRewardsController {
    function claimAllRewardsToSelf(address[] calldata assets)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

// ── Merkl (amendment 2c §3.3) ─────────────────────────────────────────────────────────────────────

/// Merkl's distributor: pays each user `amount − claimed[user][token]` (cumulative amounts), to the
/// user or the recipient only the user can set.
interface IMerklDistributor {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}

// ── Uniswap V3 pool (no router: the vault swaps on the pinned pool directly) ─────────────────────────

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    /// The pool's price now (amendment 2d: the exit's sales are held to a band around AAVE's oracle).
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

// ── The repay-with-collateral receiver (contracts/repay-with-collateral) ──────────────────────────────

interface IRepayWithCollateral {
    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function repayWithCollateral(
        address collateralAsset,
        address debtAsset,
        uint256 flashAmount,
        uint256 debtRepayAmount,
        uint256 maxCollateralIn,
        uint24 poolFee,
        Permit calldata permit
    ) external returns (uint256 debtRepaid, uint256 collateralSpent);
}

// ── Circle CCTP V2 ───────────────────────────────────────────────────────────────────────────────────

/// TokenMessengerV2 also has `getMinFeeAmount(uint256)`, called by selector so that a messenger
/// without it reads as a zero minimum (VaultBase._minFee).
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

interface IMessageTransmitterV2 {
    function localDomain() external view returns (uint32);
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes calldata messageBody
    ) external;
    /// Relays an attested message: mints a burn to its `mintRecipient`, or calls a message's handler.
    /// When the message names a `destinationCaller`, only that address may relay it.
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

// ── HyperCore (HyperEVM) ─────────────────────────────────────────────────────────────────────────────

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// Circle's CoreDepositWallet: `deposit(amount, 0)` credits the CALLER's HyperCore perp margin (§5).
interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
}
