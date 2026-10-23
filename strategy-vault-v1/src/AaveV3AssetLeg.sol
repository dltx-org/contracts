// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {MemberBase} from "./MemberBase.sol";
import {AaveV3AssetLegState} from "./AaveV3AssetLegState.sol";
import {AaveV3AssetLegExit} from "./AaveV3AssetLegExit.sol";
import {AaveV3AssetLegRewards} from "./AaveV3AssetLegRewards.sol";
import {IRegistryV1} from "./Interfaces.sol";
import {IAavePool, IERC20} from "./interfaces/Protocols.sol";
import {Legs} from "./lib/VaultTypes.sol";
import {AssetLegParams, AssetProfile, MemberTypes, ParamsTypesV1} from "./Types.sol";

/*
 * The AAVE V3 ASSET LEG (asset-profiles-design.md §3.2; version 0's `LongVault` made generic and
 * owner-upgradeable): an AAVE V3 position, its profile's asset supplied and USDC borrowed, held by this
 * instance and operated by its execution group's key within limits that survive that key's compromise:
 * the health floor after every borrow, withdraw and e-mode change; every sale of collateral bounded per
 * call against the rate-adjusted reference (§3.5), charged to a 24-hour loss budget at AAVE's price
 * (except in exit) and, for the atomic repay, measured afterwards and never lowering the health factor;
 * money only to the strategy's other members, in exit only to its hub.
 *
 * ONE implementation for every asset (AP-1): the asset is the instance's stored profile. Two modules, each
 * its code hash checked here, run by DELEGATECALL in this leg's storage (dispatched by `_module`, Q9's
 * measurement): `AaveV3AssetLegExit` (the exit and its parts, `receiveMint`, `report`, `holdings`) and
 * `AaveV3AssetLegRewards` (amendment 2c's rewards path, the exit's reward parts, the key's `swap` and
 * `repayWithCollateral`, the profile check (AP-3) and the profile switch's `followSwitch`).
 */
contract AaveV3AssetLeg is MemberBase, AaveV3AssetLegState {
    address public immutable exitModule;
    address public immutable rewardsModule;

    constructor(
        address exitModule_,
        bytes32 exitModuleCodeHash,
        address rewardsModule_,
        bytes32 rewardsModuleCodeHash,
        address upgradeModule_,
        bytes32 upgradeModuleCodeHash,
        address pool,
        address usdc,
        address receiver,
        address sequencer
    )
        MemberBase(upgradeModule_, upgradeModuleCodeHash)
        AaveV3AssetLegState(pool, usdc, receiver, sequencer)
    {
        _checkModule(exitModule_, exitModuleCodeHash);
        _checkModule(rewardsModule_, rewardsModuleCodeHash);
        exitModule = exitModule_;
        rewardsModule = rewardsModule_;
    }

    function MEMBER_TYPE() public pure override returns (uint8) {
        return MemberTypes.AAVE_V3_ASSET;
    }

    function _module(bytes4 s) internal view override returns (address) {
        if (
            s == AaveV3AssetLegExit.exitStep.selector || s == AaveV3AssetLegExit.exitPart.selector
                || s == AaveV3AssetLegExit.receiveMint.selector || s == AaveV3AssetLegExit.report.selector
                || s == AaveV3AssetLegExit.holdings.selector
        ) return exitModule;
        if (
            s == AaveV3AssetLegRewards.claimRewards.selector || s == AaveV3AssetLegRewards.claimMerkl.selector
                || s == AaveV3AssetLegRewards.swapReward.selector
                || s == AaveV3AssetLegRewards.rewardCollateralOff.selector
                || s == AaveV3AssetLegRewards.rewardPins.selector || s == AaveV3AssetLegRewards.rewardPart.selector
                || s == AaveV3AssetLegRewards.swap.selector || s == AaveV3AssetLegRewards.repayWithCollateral.selector
                || s == AaveV3AssetLegRewards.checkProfile.selector || s == AaveV3AssetLegRewards.checkAtCreation.selector
                || s == AaveV3AssetLegRewards.followSwitch.selector
                || s == AaveV3AssetLegRewards.assetProfile.selector
        ) return rewardsModule;
        return address(0);
    }

    // ── the leg standard (amendment 2a §3.5) ─────────────────────────────────────────────────────────

    /// The leg type, for every asset: the asset is read from the instance (`assetProfile()`).
    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind) {
        return (keccak256("dltx.leg.aave-v3-asset"), Legs.ROLE_LONG, Legs.VALUE_READ);
    }

    function paramsType() external pure returns (string memory) {
        return ParamsTypesV1.AAVE_V3_ASSET;
    }

    /// §3.3: a profile this chain's registry holds open to new strategies, every field the owner sees equal
    /// to its entry's, and today's bounds with the profile's `minBoundBp`; anything else reverts.
    function validateParams(address r, bytes calldata params) external view {
        _validate(abi.decode(params, (AssetLegParams)), IRegistryV1(r));
    }

    function _validate(AssetLegParams memory p, IRegistryV1 r) internal view returns (AssetProfile memory a) {
        a = r.profileOf(p.profile);
        if (
            !r.profileOpen(p.profile) || p.asset != a.asset || p.swapPool != a.swapPool || p.swapFee != a.swapFee
                || p.rateFeed != a.rateFeed || p.healthFloor < MIN_HEALTH_FLOOR || p.healthFloor > MAX_HEALTH_FLOOR
                || p.oracleBoundBp < a.minBoundBp || p.oracleBoundBp <= a.swapFee / 100
                || p.oracleBoundBp > MAX_ORACLE_BOUND_BP || p.dailyLossBp > MAX_DAILY_LOSS_BP
                || p.fastFeeCapBp > MAX_FAST_FEE_CAP_BP
        ) revert BadParams();
    }

    /// The owner's bounds and the profile, its reserve's state checked again (AP-3) by the rewards module.
    function _initParams(bytes calldata params) internal override {
        AssetLegParams memory p = abi.decode(params, (AssetLegParams));
        AssetProfile memory a = _validate(p, IRegistryV1(registry));
        AaveV3AssetLegRewards(address(this)).checkAtCreation(a);
        healthFloor = p.healthFloor;
        oracleBoundBp = p.oracleBoundBp;
        dailyLossBp = p.dailyLossBp;
        fastFeeCapBp = p.fastFeeCapBp;
        profile = p.profile;
        _asset = a.asset;
        _swapFee = a.swapFee;
        _decimals = a.assetDecimals;
        _isToken0 = a.assetIsToken0;
        _minBoundBp = a.minBoundBp;
        _rateMaxAge = a.rateMaxAge;
        _aAsset = a.aAsset;
        _swapPool = a.swapPool;
        _rateFeed = a.rateFeed;
        _holdingAsset = a.holdingAsset;
    }

    function _onExit() internal override {}

    // ── the execution key (§8.4) ─────────────────────────────────────────────────────────────────────

    /// The profile's asset only: the strategy's collateral.
    function supply(uint256 amount) external onlyExecution whenNotPaused nonReentrant counted {
        address a = _asset;
        IERC20(a).approve(POOL, amount);
        IAavePool(POOL).supply(a, amount, address(this), 0);
    }

    function repay(uint256 amount) external onlyExecution nonReentrant counted {
        _repay(amount);
    }

    function borrow(uint256 amount) external onlyExecution whenNotPaused nonReentrant counted {
        IAavePool(POOL).borrow(USDC, amount, VARIABLE, 0, address(this));
        _checkFloor();
    }

    /// The asset or USDC, above the floor.
    function withdraw(address a, uint256 amount) external onlyExecution nonReentrant counted {
        if (a != _asset && a != USDC) revert BadAsset();
        IAavePool(POOL).withdraw(a, amount, address(this));
        _checkFloor();
    }

    function setEMode(uint8 category) external onlyExecution nonReentrant counted {
        IAavePool(POOL).setUserEMode(category);
        _checkFloor();
    }

    /// Amendment 2d §5.2 (unchanged but for the asset): what this leg owes and can't repay from its own
    /// USDC and aUSDC, plus the headroom, in exit; zero while insolvent at AAVE's price (CR-C2, RR-2). In
    /// the leg itself: the hub reads it with a capped staticcall.
    function exitDebt() external view returns (uint256) {
        uint256 debt = IERC20(VDEBT_USDC).balanceOf(address(this));
        uint256 held = IERC20(USDC).balanceOf(address(this)) + IERC20(A_USDC).balanceOf(address(this));
        if (!exiting || debt <= held) return 0;
        if (IERC20(_aAsset).balanceOf(address(this)) * _price(_asset) / _unit() < debt * 100) return 0;
        return _withHeadroom(debt) - held;
    }

    /// A reserve other than the asset switched off as the leg's collateral (CR-C1): the key outside the
    /// exit (above the floor after it), anyone in it.
    function collateralOff(address a) external nonReentrant counted {
        if (!exiting) _checkExecution();
        if (a == _asset) revert BadAsset();
        IAavePool(POOL).setUserUseReserveAsCollateral(a, false);
        if (!exiting) _checkFloor();
    }

    /// USDC to member `k` once it is ready; Circle's fee charged to the 24-hour loss budget.
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external onlyExecution nonReentrant {
        uint256 equity = _equity();
        uint256 fee = _send(k, amount, fast, maxFee, fastFeeCapBp);
        if (fee > 0) _charge(fee * _price(USDC) / 1e6, equity);
    }

    function lossInWindow() public view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        if (day == lossDay) return uint256(lossToday) + lossYesterday;
        if (day == uint256(lossDay) + 1) return lossToday;
        return 0;
    }

    /// The pinned pools' callback, during this leg's own swap only: the profile's pool pays its token0
    /// and token1 as owed (the asset and USDC, in the pool's order); the reward pool, ARB only (2c §3.5).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        uint256 mode = _swapping;
        if (mode == SWAP_POSITION && msg.sender == _swapPool) {
            (address t0, address t1) = _isToken0 ? (_asset, USDC) : (USDC, _asset);
            if (amount0Delta > 0) IERC20(t0).transfer(msg.sender, uint256(amount0Delta));
            if (amount1Delta > 0) IERC20(t1).transfer(msg.sender, uint256(amount1Delta));
        } else if (mode == SWAP_REWARD && msg.sender == REWARD_POOL) {
            if (amount0Delta > 0) IERC20(REWARD).transfer(REWARD_POOL, uint256(amount0Delta));
        } else {
            revert NotAllowed();
        }
    }
}
