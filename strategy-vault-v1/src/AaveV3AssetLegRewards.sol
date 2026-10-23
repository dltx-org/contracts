// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {AaveV3AssetLegState, IReceiverPins} from "./AaveV3AssetLegState.sol";
import {IRegistryV1} from "./Interfaces.sol";
import {
    AaveReserveData, IAavePool, IERC20, IMerklDistributor, IRewardsController, IUniswapV3Pool
} from "./interfaces/Protocols.sol";
import {PriceSource} from "./lib/PriceSource.sol";
import {Assets} from "./lib/VaultTypes.sol";
import {AssetProfile, Profiles} from "./Types.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

interface IDescription {
    function description() external view returns (string memory);
}

interface IAaveSources {
    function getSourceOfAsset(address asset) external view returns (address);
}

interface IUniswapV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IRouterFactory {
    function factory() external view returns (address);
}

/*
 * The AAVE V3 asset leg's REWARDS MODULE (asset-profiles-design.md §3.2): run only by DELEGATECALL from an
 * instance, in its storage. It carries what the leg and its exit module have no room for:
 * - amendment 2c's rewards path (ARB, Arbitrum's pins), unchanged, and the exit's reward parts 8 and 9 as
 *   `rewardPart` (the leg's own call only, under the exit's lock: no lock of its own);
 * - the execution key's two sales of collateral, `swap` (either direction, either token order) and
 *   `repayWithCollateral`;
 * - the profile's check on this chain (AP-3), for the registry's acceptance and each instance's
 *   initialisation, and the profile switch's `followSwitch` (§3.7).
 */
contract AaveV3AssetLegRewards is AaveV3AssetLegState {
    // AAVE's reserve configuration bits (ReserveConfiguration)
    uint256 internal constant LTV_MASK = 0xFFFF;
    uint256 internal constant ACTIVE_BIT = 56;
    uint256 internal constant FROZEN_BIT = 57;
    uint256 internal constant PAUSED_BIT = 60;
    uint256 internal constant DEBT_CEILING_START = 212;
    uint256 internal constant DEBT_CEILING_MASK = (1 << 40) - 1;
    uint256 internal constant VIRTUAL_ACC_BIT = 252;

    constructor(address pool, address usdc, address receiver, address sequencer)
        AaveV3AssetLegState(pool, usdc, receiver, sequencer)
    {}

    // ── the execution key's sales (§8.4) ─────────────────────────────────────────────────────────────

    /// The asset ↔ USDC on the profile's pool, paid to the leg; `minOut` raised to the bound against the
    /// reference, the shortfall against AAVE's price charged to the 24-hour budget.
    function swap(bool assetToUsdc, uint256 amountIn, uint256 minOut)
        external
        delegated
        onlyExecution
        nonReentrant
        counted
        returns (uint256)
    {
        return _swap(assetToUsdc, amountIn, minOut, true);
    }

    /// Repays `debt` USDC with at most `maxCollateral` of the aToken through the pinned receiver, atomically.
    function repayWithCollateral(uint256 debt, uint256 maxCollateral)
        external
        delegated
        onlyExecution
        nonReentrant
        counted
    {
        _repayWithCollateral(debt, maxCollateral, true);
    }

    // ── the profile (AP-3, §3.7) ──────────────────────────────────────────────────────────────────────

    /// The leg's part of a profile, checked on this chain (AP-3): reverts `BadProfile` unless the token's
    /// decimals are the profile's (6 to 18), its aToken AAVE's, its pool the receiver's router's factory's
    /// for (token, USDC, fee), its order the profile's; the reserve active, not frozen, not paused, a base
    /// LTV above zero, no debt ceiling and virtual accounting; AAVE's oracle a source and a positive price;
    /// the token neither USDC, nor the reward, nor its own aToken; the bound's floor above the pool's fee;
    /// the holding a non-USD id; the rate feed, when set, whose `description()` is the profile's, with
    /// decimals and a fresh positive answer; the short's id derived from the perp's coin, the underlying
    /// equal to it.
    function checkProfile(AssetProfile calldata p) external view {
        _checkProfile(p, true);
    }

    /// AP-3 at an instance's initialisation: the same facts again, the reserve's state included, but not
    /// the rate feed's liveness (a creation never waits for a feed: a stale rate reads as AAVE's price).
    function checkAtCreation(AssetProfile calldata p) external view delegated {
        _checkProfile(p, false);
    }

    function _checkProfile(AssetProfile memory p, bool live) internal view {
        address a = p.asset;
        if (
            a == address(0) || a == USDC || a == REWARD || a == p.aAsset || p.aAsset == A_REWARD
                || p.assetDecimals < 6 || p.assetDecimals > 18 || IDecimals(a).decimals() != p.assetDecimals
                || p.assetIsToken0 != (a < USDC) || p.swapFee == 0 || p.minBoundBp <= p.swapFee / 100
                || p.minBoundBp > MAX_ORACLE_BOUND_BP || p.holdingAsset == bytes32(0) || p.holdingAsset == Assets.USD
                || p.underlying != p.perpCoin || p.perpCoin == bytes32(0) || p.shortAsset != Profiles.assetOf(p.perpCoin)
        ) revert BadProfile();
        AaveReserveData memory r = IAavePool(POOL).getReserveData(a);
        uint256 c = r.configuration;
        if (
            r.aTokenAddress != p.aAsset || c & LTV_MASK == 0 || (c >> ACTIVE_BIT) & 1 == 0 || (c >> FROZEN_BIT) & 1 == 1
                || (c >> PAUSED_BIT) & 1 == 1 || (c >> DEBT_CEILING_START) & DEBT_CEILING_MASK != 0
                || (c >> VIRTUAL_ACC_BIT) & 1 == 0
        ) revert BadProfile();
        if (IAaveSources(ORACLE).getSourceOfAsset(a) == address(0) || _price(a) == 0) revert BadProfile();
        address factory_ = IRouterFactory(IReceiverPins(RECEIVER).ROUTER()).factory();
        if (p.swapPool == address(0) || IUniswapV3Factory(factory_).getPool(a, USDC, p.swapFee) != p.swapPool) {
            revert BadProfile();
        }
        if (p.rateFeed == address(0)) {
            if (p.rateDescription != bytes32(0) || p.rateMaxAge != 0) revert BadProfile();
        } else {
            (bytes32 d, bool fits) = Profiles.word(IDescription(p.rateFeed).description());
            bool ok = true;
            if (live) (ok,,) = PriceSource.latestAt(p.rateFeed, block.timestamp, p.rateMaxAge);
            if (!fits || d != p.rateDescription || d == bytes32(0) || p.rateMaxAge == 0 || !ok) revert BadProfile();
        }
    }

    /// The hub beside this leg applies the owner's profile switch (§3.7): another profile open here (its
    /// facts checked at its acceptance, AP-3), the same token, aToken, decimals and holding, the leg's
    /// signed bound at least its floor and above its pool's fee, its facts on this chain checked again by
    /// THIS version's code (AP-3, the rate feed's liveness aside: a switch never waits for a feed); outside
    /// the exit and the leg's own lock. Counted, so a fee snapshot taken before it is refused.
    function followSwitch(bytes32 toProfile) external delegated nonReentrant counted {
        if (exiting || msg.sender != links[0] || !_isLocal(0)) revert NotAllowed();
        IRegistryV1 r = IRegistryV1(registry);
        AssetProfile memory b = r.profileOf(toProfile);
        uint16 bound = oracleBoundBp;
        if (
            !r.profileOpen(toProfile) || b.asset != _asset || b.aAsset != _aAsset || b.assetDecimals != _decimals
                || b.holdingAsset != _holdingAsset || bound < b.minBoundBp || bound <= b.swapFee / 100
        ) revert BadProfile();
        // its facts on this chain again (the registry checked them with the then-latest version's code)
        _checkProfile(b, false);
        emit ProfileFollowed(profile, toProfile);
        profile = toProfile;
        _swapFee = b.swapFee;
        _isToken0 = b.assetIsToken0;
        _minBoundBp = b.minBoundBp;
        _rateMaxAge = b.rateMaxAge;
        _swapPool = b.swapPool;
        _rateFeed = b.rateFeed;
    }

    /// The instance's stored profile (AP-1: the asset is read here, never from the code).
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
        )
    {
        return (
            profile, _asset, _decimals, _aAsset, _swapPool, _swapFee, _isToken0, _holdingAsset, _minBoundBp,
            _rateFeed, _rateMaxAge
        );
    }

    // ── amendment 2c: the rewards path ─────────────────────────────────────────────────────────────────

    modifier rewardCaller() {
        if (!exiting) _checkExecution();
        _;
    }

    /// The exit's reward parts (2c §3.7), the leg's own call only, under `exitStep`'s lock: 9 turns aArbARB's
    /// collateral off, 8 sells the reward held.
    function rewardPart(uint8 part) external delegated inExit {
        if (msg.sender != address(this)) revert NotAllowed();
        if (part == 8) {
            if (_rewardHeld() >= REWARD_DUST) _swapReward(type(uint256).max, 0);
        } else if (part == 9) {
            _collateralOff();
        } else {
            revert Unsupported();
        }
    }

    function claimRewards() external delegated nonReentrant rewardCaller counted {
        uint256 before = _rewardHeld();
        address[] memory assets = new address[](4);
        assets[0] = _aAsset;
        assets[1] = A_USDC;
        assets[2] = VDEBT_USDC;
        assets[3] = A_REWARD;
        IRewardsController(REWARDS_CONTROLLER).claimAllRewardsToSelf(assets);
        emit RewardClaimed(1, _gained(before));
    }

    function claimMerkl(address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs)
        external
        delegated
        nonReentrant
        rewardCaller
        counted
    {
        uint256 before = _rewardHeld();
        address[] memory users = new address[](tokens.length);
        for (uint256 i; i < users.length; ++i) {
            users[i] = address(this);
        }
        IMerklDistributor(MERKL_DISTRIBUTOR).claim(users, tokens, amounts, proofs);
        emit RewardClaimed(2, _gained(before));
    }

    function swapReward(uint256 amountIn, uint256 minOut)
        external
        delegated
        nonReentrant
        rewardCaller
        counted
        returns (uint256)
    {
        return _swapReward(amountIn, minOut);
    }

    function rewardCollateralOff() external delegated nonReentrant rewardCaller counted {
        _collateralOff();
    }

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
        )
    {
        return ([REWARDS_CONTROLLER, MERKL_DISTRIBUTOR], REWARD, A_REWARD, REWARD_POOL, REWARD_FEED, REWARD_MAX_AGE, REWARD_BOUND_BP);
    }

    function _swapReward(uint256 amountIn, uint256 minOut) internal returns (uint256 out) {
        if (_rewardCollateralOn()) revert RewardCollateralOn();
        if (amountIn == type(uint256).max) {
            if (IERC20(A_REWARD).balanceOf(address(this)) > 0) _withdrawReward(type(uint256).max);
            amountIn = IERC20(REWARD).balanceOf(address(this));
        } else {
            uint256 held = IERC20(REWARD).balanceOf(address(this));
            if (held < amountIn) _withdrawReward(amountIn - held);
        }
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert ZeroAmount();
        uint256 p = _rewardPrice();
        uint256 pu = _price(USDC);
        // decision 67: in exit, ARB (token0, 18 decimals) at the feed's price less min(EXIT_BAND_BP,
        // REWARD_BOUND_BP − the pool's fee); the same pure `_limitAt` as the asset's
        uint160 limit = MIN_SQRT_RATIO_PLUS_ONE;
        if (exiting) {
            uint256 band = REWARD_BOUND_BP - REWARD_FEE_BP;
            limit = _limitAt(p, pu, band < EXIT_BAND_BP ? band : EXIT_BAND_BP, 18, true);
            if (_sqrtPrice(REWARD_POOL) <= limit) revert PoolOffOracle();
        }
        _swapping = SWAP_REWARD;
        (int256 a0, int256 a1) = IUniswapV3Pool(REWARD_POOL).swap(address(this), true, int256(amountIn), limit, "");
        _swapping = 0;
        uint256 paid = uint256(a0);
        out = uint256(-a1);
        uint256 base = amountIn;
        if (exiting) {
            base = paid;
            minOut = minOut * paid / amountIn;
        }
        uint256 floor = base * p * 1e6 * (10_000 - REWARD_BOUND_BP) / (pu * 1e18 * 10_000);
        if (out < (minOut < floor ? floor : minOut)) revert SwapShort();
        uint256 valueIn = paid * p / 1e18;
        uint256 valueOut = out * pu / 1e6;
        uint256 loss = valueIn > valueOut ? valueIn - valueOut : 0;
        if (!exiting) _count(loss);
        emit RewardSwapped(paid, out, loss);
    }

    function _withdrawReward(uint256 amount) internal {
        uint256 hfBefore = _health();
        IAavePool(POOL).withdraw(REWARD, amount, address(this));
        if (_health() < hfBefore) revert HealthFell();
    }

    function _collateralOff() internal {
        if (!_rewardCollateralOn()) return;
        IAavePool(POOL).setUserUseReserveAsCollateral(REWARD, false);
        if (!exiting) _checkFloor();
    }

    function _rewardCollateralOn() internal view returns (bool) {
        uint256 id = IAavePool(POOL).getReserveData(REWARD).id;
        return (IAavePool(POOL).getUserConfiguration(address(this)) >> (id * 2)) & 2 != 0;
    }

    function _rewardPrice() internal view returns (uint256) {
        (bool ok, uint256 p,) = PriceSource.latestAt(REWARD_FEED, block.timestamp, REWARD_MAX_AGE);
        if (!ok) revert StalePrice();
        (ok,) = PriceSource.sequencerUp(SEQUENCER, block.timestamp);
        if (!ok) revert StalePrice();
        return p / 1e10;
    }

    function _rewardHeld() internal view returns (uint256) {
        return IERC20(REWARD).balanceOf(address(this)) + IERC20(A_REWARD).balanceOf(address(this));
    }

    function _gained(uint256 before) internal view returns (uint256) {
        uint256 held = _rewardHeld();
        return held > before ? held - before : 0;
    }
}
