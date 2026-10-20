// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultState} from "./VaultBase.sol";
import {IAaveOracle, IAavePool, IERC20, IRepayWithCollateral, IUniswapV3Pool} from "./interfaces/Protocols.sol";
import {Arbitrum} from "./lib/Pinned.sol";
import {Assets, Holding} from "./lib/VaultTypes.sol";

/*
 * The AAVE leg's STORAGE, constants and shared internals (step 11e2 amendment 2a §3.8): inherited by the
 * leg (`LongVault is VaultBase, LongVaultState`) and by its exit module (`LongVaultExit is
 * LongVaultState`), which runs by DELEGATECALL in the leg's storage. `VaultBase` declares no storage and
 * neither do the two contracts, so both layouts are `VaultState`'s then this one's; `test.mjs`
 * compares them slot for slot (`forge inspect … storageLayout`) before any test.
 */
abstract contract LongVaultState is VaultState {
    // ── pinned on Arbitrum (lib/Pinned.sol) ──────────────────────────────────────────────────────────
    address internal constant POOL = Arbitrum.POOL;
    address internal constant ORACLE = Arbitrum.ORACLE;
    address internal constant WETH = Arbitrum.WETH;
    address internal constant USDC = Arbitrum.USDC;
    address internal constant SWAP_POOL = Arbitrum.SWAP_POOL;
    address internal constant RECEIVER = Arbitrum.RECEIVER;
    address internal constant A_WETH = Arbitrum.A_WETH;
    address internal constant A_USDC = Arbitrum.A_USDC;
    address internal constant VDEBT_USDC = Arbitrum.VDEBT_USDC;
    uint24 internal constant SWAP_FEE = 500;
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
    uint256 internal constant VARIABLE = 2;

    // ── amendment 2c: the rewards path (spec §3.2), pinned in the code ───────────────────────────────
    address internal constant REWARDS_CONTROLLER = Arbitrum.REWARDS_CONTROLLER;
    address internal constant MERKL_DISTRIBUTOR = Arbitrum.MERKL_DISTRIBUTOR;
    address internal constant REWARD = Arbitrum.REWARD;
    address internal constant A_REWARD = Arbitrum.A_REWARD;
    address internal constant REWARD_POOL = Arbitrum.REWARD_POOL;
    address internal constant REWARD_FEED = Arbitrum.REWARD_FEED;
    address internal constant SEQUENCER = Arbitrum.SEQUENCER;
    /// The feed's 24-hour heartbeat plus an hour.
    uint256 internal constant REWARD_MAX_AGE = 25 hours;
    /// Every reward sale returns at least the feed's value less 1 % (decision 58).
    uint256 internal constant REWARD_BOUND_BP = 100;
    /// Below it the exit sells no reward (0.01 ARB).
    uint256 internal constant REWARD_DUST = 1e16;
    /// `_swapping`'s two values: the WETH/USDC pool's sale, the reward pool's.
    uint256 internal constant SWAP_POSITION = 1;
    uint256 internal constant SWAP_REWARD = 2;

    // ── amendment 2d §3.2: the exit's sales, held to a band around AAVE's oracle, at the margin ─────────
    /// Every fill of an exit sale is at a pool price no worse than the oracle less this (decision 66).
    uint256 internal constant EXIT_BAND_BP = 50;
    /// The WETH/USDC pool's fee: the band is narrowed by it under a signed `oracleBoundBp`, so that the
    /// band's last fill, fee included, is never below the average floor.
    uint256 internal constant SWAP_FEE_BP = 5;
    /// The reward pool's fee (0.30 %), kept inside 2c's 1 % floor the same way (decision 67).
    uint256 internal constant REWARD_FEE_BP = 30;

    // Sanity bounds on what an owner may sign (the owner's signature is the authority within them). The
    // bounds' floor covers a repay with collateral: the pool's 0.05% fee, AAVE's flash premium and the
    // gap between the pool and the oracle.
    uint16 internal constant MIN_BOUND_BP = 30;
    uint64 internal constant MIN_HEALTH_FLOOR = 1.05e18;
    uint64 internal constant MAX_HEALTH_FLOOR = 3e18;
    uint16 internal constant MAX_ORACLE_BOUND_BP = 500;
    uint16 internal constant MAX_DAILY_LOSS_BP = 500;
    uint16 internal constant MAX_FAST_FEE_CAP_BP = 50;

    // ── fixed at creation ────────────────────────────────────────────────────────────────────────────
    uint64 public healthFloor;
    uint16 public oracleBoundBp;
    uint16 public dailyLossBp;
    uint16 public fastFeeCapBp;

    // ── the loss counter (USD, AAVE's base: 8 decimals): two day buckets, both counted ────────────────
    uint64 public lossDay; // the current bucket: block.timestamp / 1 day
    uint96 public lossToday;
    uint96 public lossYesterday;
    uint256 internal _swapping;

    event Swapped(bool wethToUsdc, uint256 amountIn, uint256 amountOut, uint256 lossUsd);
    event RepaidWithCollateral(uint256 debtRepaid, uint256 collateralOut, uint256 lossUsd);
    event ExitPartFailed(uint8 part, bytes reason);
    /// The pinned reward (ARB and aArbARB together) a claim of this leg's delivered: 1 AAVE, 2 Merkl.
    event RewardClaimed(uint8 source, uint256 gained);
    event RewardSwapped(uint256 rewardIn, uint256 usdcOut, uint256 lossUsd);

    error BadAsset();
    error BelowHealthFloor();
    error HealthFell();
    error AboveBound();
    error OverBudget();
    error SwapShort();
    error BadParams();
    error RewardCollateralOn();
    error StalePrice();
    /// Amendment 2d: the pool is already below the band's limit (nothing to sell this step: wait for
    /// arbitrage), or the receiver's swap ended below it (this chunk is too big for the band: halve it).
    error PoolOffOracle();
    error BandCrossed();

    // ── internals ────────────────────────────────────────────────────────────────────────────────────

    /// The report's holdings (§3.6, decision 45): the collateral as `+ETH` (aWETH and idle WETH), the
    /// USDC as `USD` (idle USDC and aUSDC, less the variable debt), 18 decimals.
    function _holdings() internal view override returns (Holding[] memory h, uint256 extra) {
        h = new Holding[](2);
        h[0] = Holding(Assets.ETH, int256(IERC20(A_WETH).balanceOf(address(this)) + IERC20(WETH).balanceOf(address(this))));
        int256 usd = int256(IERC20(USDC).balanceOf(address(this)) + IERC20(A_USDC).balanceOf(address(this)))
            - int256(IERC20(VDEBT_USDC).balanceOf(address(this)));
        h[1] = Holding(Assets.USD, usd * 1e12);
        extra = 0;
    }

    function _usdc() internal pure override returns (address) {
        return USDC;
    }

    /// Every change of the AAVE position goes through this leg's own counted calls; what doesn't (a
    /// liquidation) the hub's re-read catches (amendment 2b §3.4).
    function _tracked() internal pure override returns (bool) {
        return true;
    }

    function _asset(address asset) internal pure {
        if (asset != WETH && asset != USDC) revert BadAsset();
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

    function _price(address asset) internal view returns (uint256) {
        return IAaveOracle(ORACLE).getAssetPrice(asset);
    }

    /// The most aWETH that may pay `debt` USDC: the debt at the oracle plus the bound (which covers the
    /// pool's fee and AAVE's flash-loan premium, paid by the receiver from the collateral).
    function _collateralBound(uint256 debt) internal view returns (uint256) {
        return debt * _price(USDC) * 1e12 * (10_000 + oracleBoundBp) / (_price(WETH) * 10_000);
    }

    /// The debt and the interest that may accrue on it before the leg's next step: 10 bp and 1 USDC.
    function _withHeadroom(uint256 debt) internal pure returns (uint256) {
        return debt + debt * 10 / 10_000 + 1e6;
    }

    /// The position's equity in USD (8 decimals): AAVE's collateral less its debt, plus the idle tokens.
    function _equity() internal view returns (uint256) {
        (uint256 collateral, uint256 debt,,,,) = IAavePool(POOL).getUserAccountData(address(this));
        uint256 idle = IERC20(WETH).balanceOf(address(this)) * _price(WETH) / 1e18
            + IERC20(USDC).balanceOf(address(this)) * _price(USDC) / 1e6;
        return collateral + idle > debt ? collateral + idle - debt : 0;
    }

    /// Adds `loss` to the counter; the budget is `dailyLossBp` of the equity read before the sale.
    function _charge(uint256 loss, uint256 equityBefore) internal {
        _count(loss);
        if ((uint256(lossToday) + lossYesterday) * 10_000 > equityBefore * dailyLossBp) revert OverBudget();
    }

    /// Adds `loss` to the counter without the budget's check (amendment 2c decision 63: a reward sale is
    /// counted, never refused); the day buckets roll as `_charge`'s.
    function _count(uint256 loss) internal {
        uint256 day = block.timestamp / 1 days;
        if (day != lossDay) {
            lossYesterday = day == uint256(lossDay) + 1 ? lossToday : 0;
            lossToday = 0;
            lossDay = uint64(day);
        }
        lossToday = uint96(lossToday + loss);
    }

    /// Prices (AAVE's oracle, 8 decimals) and token scales of a sale's two sides.
    struct Sides {
        uint256 pIn;
        uint256 pOut;
        uint256 sIn;
        uint256 sOut;
    }

    function _sides(bool wethToUsdc) internal view returns (Sides memory s) {
        uint256 pw = _price(WETH);
        uint256 pu = _price(USDC);
        s = wethToUsdc ? Sides(pw, pu, 1e18, 1e6) : Sides(pu, pw, 1e6, 1e18);
    }

    function _swap(bool wethToUsdc, uint256 amountIn, uint256 minOut, bool charge) internal returns (uint256 out) {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert ZeroAmount();
        Sides memory s = _sides(wethToUsdc);
        uint256 floor = amountIn * s.pIn * s.sOut * (10_000 - oracleBoundBp) / (s.pOut * s.sIn * 10_000);
        if (minOut < floor) minOut = floor;
        uint256 equity = charge ? _equity() : 0;
        uint256 paid;
        (paid, out) = _poolSwap(wethToUsdc, amountIn, wethToUsdc ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE);
        if (out < minOut) revert SwapShort();
        uint256 valueIn = paid * s.pIn / s.sIn;
        uint256 valueOut = out * s.pOut / s.sOut;
        uint256 loss = valueIn > valueOut ? valueIn - valueOut : 0;
        if (charge) _charge(loss, equity);
        emit Swapped(wethToUsdc, paid, out, loss);
    }

    /// An exact-input swap on the pinned pool to `limit` (the key's sales: the pool's extreme, limited by
    /// the caller's minimum alone; the exit's: the band, a partial fill accepted).
    function _poolSwap(bool wethToUsdc, uint256 amountIn, uint160 limit) internal returns (uint256 paid, uint256 out) {
        _swapping = SWAP_POSITION;
        (int256 a0, int256 a1) =
            IUniswapV3Pool(SWAP_POOL).swap(address(this), wethToUsdc, int256(amountIn), limit, "");
        _swapping = 0;
        (int256 p, int256 g) = wethToUsdc ? (a0, a1) : (a1, a0);
        paid = uint256(p);
        out = uint256(-g);
    }

    /// The atomic repay, held to the swap's limits (decision 25): `maxCollateral` within the bound of
    /// the debt at the oracle; what actually moved measured afterwards, its shortfall within the bound
    /// and (outside the exit) charged to the budget; the health factor never lower than before.
    function _repayWithCollateral(uint256 debt, uint256 maxCollateral, bool charge) internal {
        if (debt == 0) revert ZeroAmount();
        if (maxCollateral > _collateralBound(debt)) revert AboveBound();
        uint256 hfBefore = _health();
        uint256 equity = charge ? _equity() : 0;
        uint256[4] memory before = _snapshot();

        IERC20(A_WETH).approve(RECEIVER, maxCollateral);
        IRepayWithCollateral(RECEIVER).repayWithCollateral(
            WETH, USDC, debt, debt, maxCollateral, SWAP_FEE, IRepayWithCollateral.Permit(0, 0, 0, 0, 0)
        );
        IERC20(A_WETH).approve(RECEIVER, 0);

        uint256[4] memory afterwards = _snapshot();
        // collateral out: the aWETH that left, less any WETH handed back (a refused re-supply)
        uint256 collateralOut = (before[0] - afterwards[0]) - (afterwards[2] - before[2]);
        // debt in: the debt repaid, plus any USDC handed back (the flash loan's surplus)
        uint256 debtIn = (before[1] - afterwards[1]) + (afterwards[3] - before[3]);
        uint256 valueOut = collateralOut * _price(WETH) / 1e18;
        uint256 valueIn = debtIn * _price(USDC) / 1e6;
        uint256 loss = valueOut > valueIn ? valueOut - valueIn : 0;
        if (loss * 10_000 > valueOut * oracleBoundBp) revert AboveBound();
        if (charge) _charge(loss, equity);
        if (_health() < hfBefore) revert HealthFell();
        emit RepaidWithCollateral(before[1] - afterwards[1], collateralOut, loss);
    }

    /// Amendment 2d §3.2: the pool price, as Uniswap's `sqrtPriceX96`, at `pIn` (AAVE's base, 8 decimals)
    /// in USDC at AAVE's oracle, less `bandBp`: a pool whose token0 has 18 decimals (WETH, ARB) and token1
    /// is USDC (6), so the price in raw units is `pIn / (pUSDC · 10^12)`.
    function _limitAt(uint256 pIn, uint256 pUsdc, uint256 bandBp) internal pure returns (uint160) {
        return uint160(Math.sqrt(pIn * (10_000 - bandBp) * (1 << 192) / (pUsdc * 1e16)));
    }

    /// The WETH sales' limit in exit: the oracle less `min(EXIT_BAND_BP, oracleBoundBp − SWAP_FEE_BP)`;
    /// with the two oracle prices it was computed from.
    function _bandLimit() internal view returns (uint160 limit, uint256 pw, uint256 pu) {
        uint256 band = oracleBoundBp - SWAP_FEE_BP;
        pw = _price(WETH);
        pu = _price(USDC);
        limit = _limitAt(pw, pu, band < EXIT_BAND_BP ? band : EXIT_BAND_BP);
    }

    /// The pinned pool's price now.
    function _sqrtPrice(address pool) internal view returns (uint160 p) {
        (p,,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function _snapshot() internal view returns (uint256[4] memory s) {
        s[0] = IERC20(A_WETH).balanceOf(address(this));
        s[1] = IERC20(VDEBT_USDC).balanceOf(address(this));
        s[2] = IERC20(WETH).balanceOf(address(this));
        s[3] = IERC20(USDC).balanceOf(address(this));
    }
}
