// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {VaultBase} from "./VaultBase.sol";
import {LongVaultState} from "./LongVaultState.sol";
import {LongVaultExit} from "./LongVaultExit.sol";
import {IAavePool, IERC20} from "./interfaces/Protocols.sol";
import {Assets, Holding, Legs, LongParams, ParamsTypes} from "./lib/VaultTypes.sol";

/*
 * The AAVE leg on Arbitrum (spec §8.3, §8.4; amendment 2a, revision 1, §3.7: a leg like any other): an
 * AAVE V3 position, WETH supplied and USDC borrowed, held by this contract and operated by its execution group's
 * key within limits that survive that key's compromise (decision 9, decision 25):
 * - a health floor after every borrow, withdraw and e-mode change;
 * - every sale of collateral — `swap`, the atomic repay through the receiver, and the exit's own sales —
 *   bounded per call against AAVE's oracle, charged to a 24-hour loss budget (except in exit), and,
 *   for the atomic repay, measured afterwards and never lowering the health factor;
 * - money leaves only to the strategy's other members (once ready); in exit, only to its hub, which
 *   pays the owner (revision 1: a leg never pays the owner and never reads a withdrawal address).
 *
 * Its exit (`exitStep` and its parts), `receiveMint` and `report` live in a fixed module, `LongVaultExit`
 * (amendment 2a §3.8: inline, the leg misses invariant 13's room), dispatched by `VaultBase`'s fallback in
 * this leg's storage.
 */
contract LongVault is VaultBase, LongVaultState {
    constructor(address exitModule_, bytes32 exitModuleCodeHash) VaultBase(exitModule_, exitModuleCodeHash) {}

    /// The exit module's functions: the exit's five, and amendment 2c's rewards path.
    function _exitSelector(bytes4 s) internal pure override returns (bool) {
        return s == LongVaultExit.exitStep.selector || s == LongVaultExit.exitPart.selector
            || s == LongVaultExit.receiveMint.selector || s == LongVaultExit.report.selector
            || s == LongVaultExit.holdings.selector || s == LongVaultExit.claimRewards.selector
            || s == LongVaultExit.claimMerkl.selector || s == LongVaultExit.swapReward.selector
            || s == LongVaultExit.rewardCollateralOff.selector || s == LongVaultExit.rewardPins.selector;
    }

    // ── the leg standard (amendment 2a §3.5) ─────────────────────────────────────────────────────────

    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind) {
        return (keccak256("dltx.leg.aave-v3-arbitrum.v1"), Legs.ROLE_LONG, Legs.VALUE_READ);
    }

    /// `LongParams` as the owner signs it (amendment 2d §4.2).
    function paramsType() external pure returns (string memory) {
        return ParamsTypes.AAVE_V3;
    }


    /// The pinned protocols (lib/Pinned.sol) and sane bounds; anything else reverts.
    function validateParams(bytes calldata params) external pure {
        LongParams memory p = abi.decode(params, (LongParams));
        if (
            p.pool != POOL || p.oracle != ORACLE || p.weth != WETH || p.usdc != USDC || p.swapPool != SWAP_POOL
                || p.receiver != RECEIVER || p.healthFloor < MIN_HEALTH_FLOOR || p.healthFloor > MAX_HEALTH_FLOOR
                || p.oracleBoundBp < MIN_BOUND_BP || p.oracleBoundBp > MAX_ORACLE_BOUND_BP
                || p.dailyLossBp > MAX_DAILY_LOSS_BP || p.fastFeeCapBp > MAX_FAST_FEE_CAP_BP
        ) revert BadParams();
    }

    function _initParams(bytes calldata params) internal override {
        LongParams memory p = abi.decode(params, (LongParams));
        healthFloor = p.healthFloor;
        oracleBoundBp = p.oracleBoundBp;
        dailyLossBp = p.dailyLossBp;
        fastFeeCapBp = p.fastFeeCapBp;
    }

    function _onExit() internal override {}

    // ── the execution key (§8.4) ─────────────────────────────────────────────────────────────────────

    /// WETH only: the strategy's collateral. USDC is never supplied by DLTX (it would be collateral
    /// the exit must unwind; anything supplied on the vault's behalf by others the exit still handles).
    function supply(uint256 amount) external onlyExecution whenNotPaused nonReentrant counted {
        IERC20(WETH).approve(POOL, amount);
        IAavePool(POOL).supply(WETH, amount, address(this), 0);
    }

    /// USDC debt, from the vault's own USDC; `type(uint256).max` repays what it can.
    function repay(uint256 amount) external onlyExecution nonReentrant counted {
        _repay(amount);
    }

    function borrow(uint256 amount) external onlyExecution whenNotPaused nonReentrant counted {
        IAavePool(POOL).borrow(USDC, amount, VARIABLE, 0, address(this));
        _checkFloor();
    }

    function withdraw(address asset, uint256 amount) external onlyExecution nonReentrant counted {
        _asset(asset);
        IAavePool(POOL).withdraw(asset, amount, address(this));
        _checkFloor();
    }

    function setEMode(uint8 category) external onlyExecution nonReentrant counted {
        IAavePool(POOL).setUserEMode(category);
        _checkFloor();
    }

    /// Amendment 2d §5.2: the USDC this leg owes and can't repay from its own USDC and aUSDC, plus 10 bp
    /// and 1 USDC of headroom for the interest that accrues before its next step; zero outside the exit.
    /// The leg type's explicit statement, read by a hub beside it in exit (2a invariant 4 as amended): the
    /// hub sends a leg at most this, before paying the owner. Zero while the position is insolvent at AAVE's
    /// oracle (collateral below debt): that debt is AAVE's liquidators' to write off, never the owner's
    /// cash to repay (the combined review's CR-C2). In the leg itself, not its exit module (EIP-170).
    function exitDebt() external view returns (uint256) {
        uint256 debt = IERC20(VDEBT_USDC).balanceOf(address(this));
        uint256 held = IERC20(USDC).balanceOf(address(this)) + IERC20(A_USDC).balanceOf(address(this));
        if (!exiting || debt <= held) return 0;
        // insolvent: its WETH at AAVE's oracle worth less than its debt (USDC at $1, 8 decimals), by bounded
        // reads, never AAVE's loop over every reserve, which a stranger's dust could push past the hub's
        // capped read (RR-2)
        if (IERC20(A_WETH).balanceOf(address(this)) * _price(WETH) / 1e18 < debt * 100) return 0;
        return _withHeadroom(debt) - held;
    }

    /// A reserve other than WETH switched off as the leg's collateral. AAVE enables one supplied on the
    /// leg's behalf by anyone; set to LTV 0 later, it would refuse every WETH withdrawal while the leg
    /// borrows, the exit's included (the combined review's CR-C1). The key outside the exit (above the
    /// floor after it), anyone in it; AAVE itself refuses a switch-off below a health factor of 1.
    function collateralOff(address asset) external nonReentrant counted {
        if (!exiting) _checkExecution();
        if (asset == WETH) revert BadAsset();
        IAavePool(POOL).setUserUseReserveAsCollateral(asset, false);
        if (!exiting) _checkFloor();
    }

    /// WETH ↔ USDC on the pinned pool, paid to the vault; `minOut` raised to the oracle bound and the
    /// shortfall against the oracle charged to the 24-hour budget.
    function swap(bool wethToUsdc, uint256 amountIn, uint256 minOut)
        external
        onlyExecution
        nonReentrant
        counted
        returns (uint256)
    {
        return _swap(wethToUsdc, amountIn, minOut, true);
    }

    /// Repays `debt` USDC with at most `maxCollateral` aWETH through the pinned receiver, atomically.
    function repayWithCollateral(uint256 debt, uint256 maxCollateral) external onlyExecution nonReentrant counted {
        _repayWithCollateral(debt, maxCollateral, true);
    }

    /// USDC to member `k` of the strategy (its hub or a sister leg), once it is ready (§3.6): CCTP across
    /// chains (standard pays Circle's minimum fee; fast pays up to `maxFee`, at most `fastFeeCapBp` of
    /// `amount`), `receiveLocal` on this chain. Either fee is charged to the 24-hour loss budget, so a key
    /// can't loop burns into Circle's fees. The leg never pays the owner: the hub does (decision 46).
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external onlyExecution nonReentrant {
        uint256 equity = _equity();
        uint256 fee = _send(k, amount, fast, maxFee, fastFeeCapBp);
        if (fee > 0) _charge(fee * _price(USDC) / 1e6, equity);
    }

    /// The losses counted now: today's bucket and yesterday's, both in full. Any 24 hours fall within
    /// two consecutive day buckets, so no 24 hours can lose more than the budget.
    function lossInWindow() public view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        if (day == lossDay) return uint256(lossToday) + lossYesterday;
        if (day == uint256(lossDay) + 1) return lossToday;
        return 0;
    }

    /// The pinned pools' callback, during this vault's own swap only: the WETH/USDC pool in a sale of the
    /// position, the reward pool (paid ARB only, its token0) in a reward sale (amendment 2c §3.5).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        uint256 mode = _swapping;
        if (mode == SWAP_POSITION && msg.sender == SWAP_POOL) {
            if (amount0Delta > 0) IERC20(WETH).transfer(SWAP_POOL, uint256(amount0Delta));
            if (amount1Delta > 0) IERC20(USDC).transfer(SWAP_POOL, uint256(amount1Delta));
        } else if (mode == SWAP_REWARD && msg.sender == REWARD_POOL) {
            if (amount0Delta > 0) IERC20(REWARD).transfer(REWARD_POOL, uint256(amount0Delta));
        } else {
            revert NotAllowed();
        }
    }

}
