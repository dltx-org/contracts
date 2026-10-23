// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MemberState} from "./MemberState.sol";
import {IAaveOracle, IAavePool, IERC20, IRepayWithCollateral, IUniswapV3Pool} from "./interfaces/Protocols.sol";
import {Arbitrum} from "./lib/Pinned.sol";
import {PriceSource} from "./lib/PriceSource.sol";
import {Assets, Holding} from "./lib/VaultTypes.sol";

/// AAVE's pool's addresses provider and its oracle, read once by an implementation's constructor (Q11).
interface IAaveAddresses {
    function ADDRESSES_PROVIDER() external view returns (address);
    function getPriceOracle() external view returns (address);
}

/// The repay-with-collateral receiver's own pins (`contracts/repay-with-collateral`).
interface IReceiverPins {
    function POOL() external view returns (address);
    function ROUTER() external view returns (address);
}

/*
 * The AAVE V3 ASSET LEG's STORAGE, constants and shared internals (asset-profiles-design.md §3.2; version
 * 0's `LongVaultState` made generic): inherited by the leg (`AaveV3AssetLeg is MemberBase,
 * AaveV3AssetLegState`) and by its two modules (`AaveV3AssetLegExit`, `AaveV3AssetLegRewards`), which run
 * by DELEGATECALL in the leg's storage. The layout is `MemberState`'s then this one's, append only;
 * `test.mjs` compares the three slot for slot.
 *
 * THE ASSET IS NOT IN THE CODE (AP-1): each instance stores its asset profile (the token, its aToken and
 * decimals, the pool and its fee tier and token order, the holding's id, the bound's floor, the rate
 * feed), written at initialisation from the owner's signed parameters and the registry's entry, changed
 * only by the owner's profile switch (§3.7). THE CHAIN'S FACTS ARE CONSTRUCTOR DATA (Q11): AAVE's pool,
 * USDC, the receiver and the sequencer feed; AAVE's oracle, aUSDC and the USDC debt token are derived
 * from the pool, and the receiver must name the same pool. The rewards path (amendment 2c) stays
 * Arbitrum's ARB pins, compiled (`lib/Pinned.sol`).
 */
abstract contract AaveV3AssetLegState is MemberState {
    // ── the chain's facts (Q11), immutables of every implementation and module ──────────────────────────
    address internal immutable POOL;
    address internal immutable ORACLE;
    address internal immutable USDC;
    address internal immutable RECEIVER;
    address internal immutable A_USDC;
    address internal immutable VDEBT_USDC;
    address internal immutable SEQUENCER;

    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
    uint256 internal constant VARIABLE = 2;

    // ── amendment 2c: the rewards path (spec §3.2), Arbitrum's, compiled ─────────────────────────────
    address internal constant REWARDS_CONTROLLER = Arbitrum.REWARDS_CONTROLLER;
    address internal constant MERKL_DISTRIBUTOR = Arbitrum.MERKL_DISTRIBUTOR;
    address internal constant REWARD = Arbitrum.REWARD;
    address internal constant A_REWARD = Arbitrum.A_REWARD;
    address internal constant REWARD_POOL = Arbitrum.REWARD_POOL;
    address internal constant REWARD_FEED = Arbitrum.REWARD_FEED;
    uint256 internal constant REWARD_MAX_AGE = 25 hours;
    uint256 internal constant REWARD_BOUND_BP = 100;
    uint256 internal constant REWARD_DUST = 1e16;
    uint256 internal constant SWAP_POSITION = 1;
    uint256 internal constant SWAP_REWARD = 2;

    // ── amendment 2d §3.2: the exit's sales, held to a band around the reference, at the margin ────────
    /// One compiled band for every asset (Q2).
    uint256 internal constant EXIT_BAND_BP = 50;
    uint256 internal constant REWARD_FEE_BP = 30;
    /// AP-12: the rate-adjusted reference never goes below AAVE's price less this (a deeper discount, real
    /// or a compromised feed's, stalls the exit instead of selling into it: R6).
    uint256 internal constant MAX_RATE_DISCOUNT_BP = 1_000;

    uint64 internal constant MIN_HEALTH_FLOOR = 1.05e18;
    uint64 internal constant MAX_HEALTH_FLOOR = 3e18;
    uint16 internal constant MAX_ORACLE_BOUND_BP = 500;
    uint16 internal constant MAX_DAILY_LOSS_BP = 500;
    uint16 internal constant MAX_FAST_FEE_CAP_BP = 50;

    // ── fixed at creation (version 0's order) ────────────────────────────────────────────────────────
    uint64 public healthFloor;
    uint16 public oracleBoundBp;
    uint16 public dailyLossBp;
    uint16 public fastFeeCapBp;

    // ── the loss counter (USD, AAVE's base: 8 decimals): two day buckets, both counted ────────────────
    uint64 public lossDay;
    uint96 public lossToday;
    uint96 public lossYesterday;
    uint256 internal _swapping;

    // ── the asset profile (§3.1, §3.2): the owner's choice at creation, or a profile switch ──────────────
    bytes32 public profile;
    address internal _asset;
    uint24 internal _swapFee;
    uint8 internal _decimals;
    bool internal _isToken0; // the asset is the pool's token0 (asset < USDC)
    uint16 internal _minBoundBp;
    uint32 internal _rateMaxAge;
    address internal _aAsset;
    address internal _swapPool;
    address internal _rateFeed;
    bytes32 internal _holdingAsset;

    event Swapped(bool assetToUsdc, uint256 amountIn, uint256 amountOut, uint256 lossUsd);
    event RepaidWithCollateral(uint256 debtRepaid, uint256 collateralOut, uint256 lossUsd);
    event ExitPartFailed(uint8 part, bytes reason);
    event RewardClaimed(uint8 source, uint256 gained);
    event RewardSwapped(uint256 rewardIn, uint256 usdcOut, uint256 lossUsd);
    event ProfileFollowed(bytes32 indexed fromProfile, bytes32 indexed toProfile);

    error BadAsset();
    error BelowHealthFloor();
    error HealthFell();
    error AboveBound();
    error OverBudget();
    error SwapShort();
    error BadParams();
    error RewardCollateralOn();
    error StalePrice();
    error PoolOffOracle();
    error BandCrossed();

    constructor(address pool, address usdc, address receiver, address sequencer) {
        POOL = pool;
        USDC = usdc;
        RECEIVER = receiver;
        SEQUENCER = sequencer;
        ORACLE = IAaveAddresses(IAaveAddresses(pool).ADDRESSES_PROVIDER()).getPriceOracle();
        A_USDC = IAavePool(pool).getReserveData(usdc).aTokenAddress;
        VDEBT_USDC = IAavePool(pool).getReserveData(usdc).variableDebtTokenAddress;
        if (
            ORACLE == address(0) || A_USDC == address(0) || VDEBT_USDC == address(0)
                || IReceiverPins(receiver).POOL() != pool
        ) revert BadParams();
    }

    // ── internals ────────────────────────────────────────────────────────────────────────────────────

    /// One whole unit of the asset in its own decimals.
    function _unit() internal view returns (uint256) {
        return 10 ** uint256(_decimals);
    }

    /// The report's holdings (§3.6): the collateral as the profile's holding asset (the aToken and the idle
    /// token, scaled to 18 decimals), the USDC as `USD` (idle and aUSDC, less the variable debt).
    function _holdings() internal view override returns (Holding[] memory h, uint256 extra) {
        h = new Holding[](2);
        uint256 held = IERC20(_aAsset).balanceOf(address(this)) + IERC20(_asset).balanceOf(address(this));
        h[0] = Holding(_holdingAsset, int256(held * 10 ** (18 - uint256(_decimals))));
        int256 usd = int256(IERC20(USDC).balanceOf(address(this)) + IERC20(A_USDC).balanceOf(address(this)))
            - int256(IERC20(VDEBT_USDC).balanceOf(address(this)));
        h[1] = Holding(Assets.USD, usd * 1e12);
        extra = 0;
    }

    function _usdc() internal view override returns (address) {
        return USDC;
    }

    function _tracked() internal pure override returns (bool) {
        return true;
    }

    function _repay(uint256 amount) internal {
        uint256 held = IERC20(USDC).balanceOf(address(this));
        if (amount > held) amount = held;
        if (amount == 0) revert ZeroAmount();
        IERC20(USDC).approve(POOL, amount);
        IAavePool(POOL).repay(USDC, amount, VARIABLE, address(this));
        IERC20(USDC).approve(POOL, 0);
    }

    function _health() internal view returns (uint256 hf) {
        (,,,,, hf) = IAavePool(POOL).getUserAccountData(address(this));
    }

    function _checkFloor() internal view {
        if (_health() < healthFloor) revert BelowHealthFloor();
    }

    function _price(address a) internal view returns (uint256) {
        return IAaveOracle(ORACLE).getAssetPrice(a);
    }

    /// AP-8, §3.5: the reference of every bound on a sale: AAVE's price × min(1, the rate), the rate the
    /// profile's feed's latest answer when it is set, fresh and the sequencer up (else AAVE's alone: a
    /// stall, never a worse price), never below AAVE's price less `MAX_RATE_DISCOUNT_BP` (AP-12). AAVE's
    /// price alone stays the health checks' and the loss counter's.
    function _reference(uint256 aave) internal view returns (uint256) {
        address feed = _rateFeed;
        if (feed == address(0)) return aave;
        (bool ok, uint256 rate,) = PriceSource.latestAt(feed, block.timestamp, _rateMaxAge);
        if (!ok) return aave;
        (ok,) = PriceSource.sequencerUp(SEQUENCER, block.timestamp);
        if (!ok || rate >= 1e18) return aave;
        uint256 least = 1e18 - 1e18 * MAX_RATE_DISCOUNT_BP / 10_000;
        return aave * (rate < least ? least : rate) / 1e18;
    }

    /// The asset's AAVE price, its reference, and USDC's (AAVE's base, 8 decimals).
    function _prices() internal view returns (uint256 pa, uint256 pr, uint256 pu) {
        pa = _price(_asset);
        pr = _reference(pa);
        pu = _price(USDC);
    }

    /// The most aToken that may pay `debt` USDC: the debt at the REFERENCE plus the bound (§3.5: at a
    /// discount, AAVE's price would cap the receiver below what buys the flash loan back).
    function _collateralBound(uint256 debt) internal view returns (uint256) {
        (, uint256 pr, uint256 pu) = _prices();
        return debt * pu * _unit() * (10_000 + oracleBoundBp) / (pr * 1e6 * 10_000);
    }

    function _withHeadroom(uint256 debt) internal pure returns (uint256) {
        return debt + debt * 10 / 10_000 + 1e6;
    }

    /// The position's equity in USD (8 decimals), at AAVE's prices.
    function _equity() internal view returns (uint256) {
        (uint256 collateral, uint256 debt,,,,) = IAavePool(POOL).getUserAccountData(address(this));
        uint256 idle = IERC20(_asset).balanceOf(address(this)) * _price(_asset) / _unit()
            + IERC20(USDC).balanceOf(address(this)) * _price(USDC) / 1e6;
        return collateral + idle > debt ? collateral + idle - debt : 0;
    }

    function _charge(uint256 loss, uint256 equityBefore) internal {
        _count(loss);
        if ((uint256(lossToday) + lossYesterday) * 10_000 > equityBefore * dailyLossBp) revert OverBudget();
    }

    function _count(uint256 loss) internal {
        uint256 day = block.timestamp / 1 days;
        if (day != lossDay) {
            lossYesterday = day == uint256(lossDay) + 1 ? lossToday : 0;
            lossToday = 0;
            lossDay = uint64(day);
        }
        lossToday = uint96(lossToday + loss);
    }

    /// The key's sale on the pinned pool, either way (§3.2): `minOut` raised to the bound against the
    /// REFERENCE, the shortfall against AAVE's prices charged to the 24-hour budget when `charge`.
    function _swap(bool assetToUsdc, uint256 amountIn, uint256 minOut, bool charge) internal returns (uint256 out) {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert ZeroAmount();
        (uint256 pa, uint256 pr, uint256 pu) = _prices();
        uint256 unit = _unit();
        uint256 floor = assetToUsdc
            ? amountIn * pr * 1e6 * (10_000 - oracleBoundBp) / (pu * unit * 10_000)
            : amountIn * pu * unit * (10_000 - oracleBoundBp) / (pr * 1e6 * 10_000);
        if (minOut < floor) minOut = floor;
        uint256 equity = charge ? _equity() : 0;
        bool zeroForOne = assetToUsdc == _isToken0;
        uint256 paid;
        (paid, out) = _poolSwap(zeroForOne, amountIn, zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE);
        if (out < minOut) revert SwapShort();
        (uint256 valueIn, uint256 valueOut) =
            assetToUsdc ? (paid * pa / unit, out * pu / 1e6) : (paid * pu / 1e6, out * pa / unit);
        uint256 loss = valueIn > valueOut ? valueIn - valueOut : 0;
        if (charge) _charge(loss, equity);
        emit Swapped(assetToUsdc, paid, out, loss);
    }

    /// An exact-input swap on the pinned pool, `zeroForOne` deciding the direction, to `limit`.
    function _poolSwap(bool zeroForOne, uint256 amountIn, uint160 limit) internal returns (uint256 paid, uint256 out) {
        _swapping = SWAP_POSITION;
        (int256 a0, int256 a1) = IUniswapV3Pool(_swapPool).swap(address(this), zeroForOne, int256(amountIn), limit, "");
        _swapping = 0;
        (int256 p, int256 g) = zeroForOne ? (a0, a1) : (a1, a0);
        paid = uint256(p);
        out = uint256(-g);
    }

    /// The atomic repay (decision 25): `maxCollateral` within the bound of the debt at the reference; what
    /// moved measured afterwards, its shortfall against the REFERENCE within the bound and (outside the
    /// exit) its shortfall against AAVE's price charged to the budget; the health factor never lower.
    function _repayWithCollateral(uint256 debt, uint256 maxCollateral, bool charge) internal {
        if (debt == 0) revert ZeroAmount();
        if (maxCollateral > _collateralBound(debt)) revert AboveBound();
        uint256 hfBefore = _health();
        uint256 equity = charge ? _equity() : 0;
        uint256[4] memory before = _snapshot();

        IERC20(_aAsset).approve(RECEIVER, maxCollateral);
        IRepayWithCollateral(RECEIVER).repayWithCollateral(
            _asset, USDC, debt, debt, maxCollateral, _swapFee, IRepayWithCollateral.Permit(0, 0, 0, 0, 0)
        );
        IERC20(_aAsset).approve(RECEIVER, 0);

        uint256[4] memory afterwards = _snapshot();
        uint256 collateralOut = (before[0] - afterwards[0]) - (afterwards[2] - before[2]);
        uint256 debtIn = (before[1] - afterwards[1]) + (afterwards[3] - before[3]);
        (uint256 pa, uint256 pr, uint256 pu) = _prices();
        uint256 unit = _unit();
        uint256 valueIn = debtIn * pu / 1e6;
        uint256 refOut = collateralOut * pr / unit;
        if (refOut > valueIn && (refOut - valueIn) * 10_000 > refOut * oracleBoundBp) revert AboveBound();
        uint256 valueOut = collateralOut * pa / unit;
        uint256 loss = valueOut > valueIn ? valueOut - valueIn : 0;
        if (charge) _charge(loss, equity);
        if (_health() < hfBefore) revert HealthFell();
        emit RepaidWithCollateral(before[1] - afterwards[1], collateralOut, loss);
    }

    /*
     * §3.2: the pool's price limit, as Uniswap's `sqrtPriceX96`, for a sale of a token worth `pIn` (8
     * decimals) at `pUsdc`, less `bandBp`; PURE, every input an argument (the ARB reward sale calls it
     * too). The raw price is P = pIn · 10^6 / (pUsdc · 10^decimals) USDC units per token unit:
     * - the token is token0: the limit is sqrt(P · (1 − band)) · 2^96, rounded UP; the sale is zeroForOne
     *   and is refused while slot0 ≤ limit (after the receiver's swap: slot0 < limit);
     * - the token is token1: the pool's price is 1/P, the limit 2^192 / x with x the token0 form, rounded
     *   DOWN; the sale is oneForZero and is refused while slot0 ≥ limit (after: slot0 > limit).
     * Both by `Math.mulDiv`: the direct token1 formula would reach about 6·10^81 at 18 decimals.
     */
    function _limitAt(uint256 pIn, uint256 pUsdc, uint256 bandBp, uint256 decimals, bool isToken0)
        internal
        pure
        returns (uint160)
    {
        uint256 x = Math.sqrt(
            Math.mulDiv(pIn * (10_000 - bandBp) * 1e6, 1 << 192, pUsdc * 10_000 * 10 ** decimals, Math.Rounding.Ceil),
            Math.Rounding.Ceil
        );
        return uint160(isToken0 ? x : Math.mulDiv(1 << 96, 1 << 96, x));
    }

    /// Whether the pool's price `p` is already beyond the band's `limit` for a sale of the asset: at or
    /// past it before a sale (`strict` false), past it after one (`strict` true).
    function _beyond(uint160 p, uint160 limit, bool strict) internal view returns (bool) {
        if (_isToken0) return strict ? p < limit : p <= limit;
        return strict ? p > limit : p >= limit;
    }

    /// The asset's sales' limit in exit: the reference less `min(EXIT_BAND_BP, oracleBoundBp − the pool's
    /// fee)`; with the reference and USDC's price it was computed from.
    function _bandLimit() internal view returns (uint160 limit, uint256 pr, uint256 pu) {
        uint256 band = oracleBoundBp - _swapFee / 100;
        (, pr, pu) = _prices();
        limit = _limitAt(pr, pu, band < EXIT_BAND_BP ? band : EXIT_BAND_BP, _decimals, _isToken0);
    }

    function _sqrtPrice(address pool) internal view returns (uint160 p) {
        (p,,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function _snapshot() internal view returns (uint256[4] memory s) {
        s[0] = IERC20(_aAsset).balanceOf(address(this));
        s[1] = IERC20(VDEBT_USDC).balanceOf(address(this));
        s[2] = IERC20(_asset).balanceOf(address(this));
        s[3] = IERC20(USDC).balanceOf(address(this));
    }
}
