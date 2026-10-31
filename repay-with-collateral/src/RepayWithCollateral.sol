// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
 * Atomic repay-with-collateral for an Aave V3 lending position — the receiver behind
 * docs/architecture/repay-with-collateral-design.md.
 *
 * One transaction, from the position's own wallet: flash-loan the debt asset, repay the wallet's
 * variable debt, pull the wallet's aTokens (by permit), withdraw exactly those, buy back exactly the
 * loan plus premium on Uniswap V3 with a hard input bound, re-supply what the swap did not spend (or
 * hand it back when the pool refuses a supply), and return the loan. Either all of it happens or
 * none of it does, so the position is never between states and no health-factor floor is needed for
 * a shrink. Repaying FIRST is what lets the aToken pull pass the pool's own health check afterwards.
 *
 * It moves only what the call itself brought: every figure is a DELTA against the balances the
 * receiver held when the call began (the 2026-10-26 audit's finding 2, "aTokens parked in the
 * flash-loan receiver"). The aTokens withdrawn are exactly the ones this call pulled from its
 * caller; the debt asset counted towards the loan is the flash loan, not a donation; the collateral
 * swapped, supplied back or returned is exactly what that withdrawal produced. A balance the call did
 * not create — sent here by mistake or to grief — is never touched: it stays on this contract, where
 * it changes nothing for any later call. It is not handed to the caller (a gift to the caller would
 * break the strategy leg's own measure) and not swept anywhere (an ownerless contract has no
 * destination that would not be a new privileged address); whoever sends tokens here gives them up.
 *
 * Immutable, ownerless: no admin, no upgrade; the only power it has is over the position of the wallet
 * that calls it. SparkLend is an Aave V3.0.x fork with the same pool interface, so one deployment per
 * (pool, router) covers both venues.
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// The five pool functions used, on the ABI both AAVE V3 (3.0 through 3.4: `getReserveData` keeps the
/// fifteen-field legacy tuple) and SparkLend (3.0.x) expose.
interface IPool {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration;
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

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function getReserveData(address asset) external view returns (ReserveData memory);
}

interface IFlashLoanSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

/// Uniswap V3 SwapRouter02 — no deadline in the params, unlike the original SwapRouter.
interface ISwapRouter02 {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

contract RepayWithCollateral is IFlashLoanSimpleReceiver {
    IPool public immutable POOL;
    ISwapRouter02 public immutable ROUTER;

    /// Aave's variable interest-rate mode — the only mode the engine borrows in.
    uint256 public constant VARIABLE_RATE_MODE = 2;
    /// `debtRepayAmount` sentinel: repay the live variable debt read in-transaction, bounded by the
    /// flash amount. Aave refuses `type(uint256).max` itself when repaying on behalf of another
    /// address, which is why the live figure is read and passed explicitly.
    uint256 public constant REPAY_ALL = type(uint256).max;

    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// What the callback needs, captured in `repayWithCollateral` from msg.sender and this contract's
    /// own balances — never read from anything a third party could supply.
    struct Call {
        address user;
        address collateralAsset;
        uint256 debtRepayAmount;
        uint256 maxCollateralIn;
        uint24 poolFee;
        Permit permit;
        /// The debt asset this contract held before the flash loan: not the call's, never counted.
        uint256 parkedDebt;
    }

    /// The callback's figures, kept in one memory struct so the callback's frame stays shallow.
    struct Result {
        uint256 repaid;
        uint256 withdrawn;
        uint256 spent;
        uint256 resupplied;
        uint256 returned;
    }

    /// What actually happened — the engine's only reliable source for what it records (a receipt
    /// carries logs, not return values).
    event RepaidWithCollateral(
        address indexed user,
        address indexed collateralAsset,
        address indexed debtAsset,
        uint256 flashAmount,
        uint256 premium,
        uint256 debtRepaid,
        uint256 collateralPulled,
        uint256 collateralSpent,
        uint256 collateralResupplied,
        uint256 collateralReturned
    );

    error Reentrancy();
    error NotPool();
    error NotInitiator();
    error RepayExceedsFlash();
    error NothingToRepay();

    // Transient: a reentrancy lock around the outer call, and the callback's results for the
    // outer call to return. Nothing persists past the transaction.
    uint256 private transient _locked;
    uint256 private transient _debtRepaid;
    uint256 private transient _collateralSpent;

    constructor(IPool pool, ISwapRouter02 router) {
        POOL = pool;
        ROUTER = router;
    }

    /// Repays msg.sender's variable debt in `debtAsset` with msg.sender's own `collateralAsset`
    /// collateral, atomically.
    /// @param flashAmount what is flash-loaned; for a full close the engine's debt read plus a buffer.
    /// @param debtRepayAmount what is repaid, or `REPAY_ALL` for the live debt (bounded by `flashAmount`).
    /// @param maxCollateralIn the most aTokens pulled, and the swap's `amountInMaximum`.
    /// @param poolFee the Uniswap V3 fee tier of the collateral/debt pool.
    /// @param permit an EIP-2612 permit on the aToken, value `maxCollateralIn`, spender this contract;
    ///        tolerated to fail when an allowance already covers the pull.
    function repayWithCollateral(
        address collateralAsset,
        address debtAsset,
        uint256 flashAmount,
        uint256 debtRepayAmount,
        uint256 maxCollateralIn,
        uint24 poolFee,
        Permit calldata permit
    ) external returns (uint256 debtRepaid, uint256 collateralSpent) {
        if (_locked == 1) revert Reentrancy();
        _locked = 1;
        if (flashAmount == 0 || debtRepayAmount == 0) revert NothingToRepay();

        bytes memory params = abi.encode(
            Call({
                user: msg.sender,
                collateralAsset: collateralAsset,
                debtRepayAmount: debtRepayAmount,
                maxCollateralIn: maxCollateralIn,
                poolFee: poolFee,
                permit: permit,
                parkedDebt: IERC20(debtAsset).balanceOf(address(this))
            })
        );
        POOL.flashLoanSimple(address(this), debtAsset, flashAmount, params, 0);

        // Nothing of this call is left behind: the pool has pulled the loan and the swap's leftovers
        // went back to the user inside the callback. Whatever this contract still holds was here
        // before the call and stays — never handed to the caller, never a revert.
        debtRepaid = _debtRepaid;
        collateralSpent = _collateralSpent;
        _locked = 0;
    }

    /// The pool's flash-loan callback — the pool's alone, for a loan this contract started.
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (msg.sender != address(POOL)) revert NotPool();
        if (initiator != address(this)) revert NotInitiator();
        Call memory c = abi.decode(params, (Call));
        Result memory r;

        r.repaid = _repay(asset, amount, c);
        r.withdrawn = _pullAndWithdraw(c);
        r.spent = _buyBack(asset, amount + premium, c.parkedDebt, c.collateralAsset, c.poolFee, r.withdrawn);
        (r.resupplied, r.returned) = _settleLeftover(c.collateralAsset, c.user, r.withdrawn - r.spent);
        _returnLoan(asset, amount + premium, c.parkedDebt, c.user);

        _debtRepaid = r.repaid;
        _collateralSpent = r.spent;
        emit RepaidWithCollateral(
            c.user,
            c.collateralAsset,
            asset,
            amount,
            premium,
            r.repaid,
            c.maxCollateralIn,
            r.spent,
            r.resupplied,
            r.returned
        );
        return true;
    }

    /// 5. Let the pool take the loan back; anything of this call's over it (rounding) is the user's.
    function _returnLoan(address asset, uint256 owed, uint256 parkedDebt, address user) internal {
        IERC20(asset).approve(address(POOL), owed);
        uint256 own = IERC20(asset).balanceOf(address(this)) - parkedDebt;
        if (own > owed) IERC20(asset).transfer(user, own - owed);
    }

    /// 1. Repay, with an explicit amount — the live debt in full-close mode.
    function _repay(address asset, uint256 amount, Call memory c) internal returns (uint256 repaid) {
        uint256 toRepay = c.debtRepayAmount;
        if (toRepay == REPAY_ALL) {
            address variableDebtToken = POOL.getReserveData(asset).variableDebtTokenAddress;
            uint256 live = IERC20(variableDebtToken).balanceOf(c.user);
            toRepay = live < amount ? live : amount;
            if (toRepay == 0) revert NothingToRepay();
        }
        if (toRepay > amount) revert RepayExceedsFlash();
        IERC20(asset).approve(address(POOL), toRepay);
        repaid = POOL.repay(asset, toRepay, VARIABLE_RATE_MODE, c.user);
    }

    /// 2. Pull the user's aTokens and withdraw exactly those. The pull runs the pool's health check
    ///    on the user, which the repay just improved.
    function _pullAndWithdraw(Call memory c) internal returns (uint256 withdrawn) {
        address aToken = POOL.getReserveData(c.collateralAsset).aTokenAddress;
        _permitIfNeeded(aToken, c);
        uint256 parked = IERC20(aToken).balanceOf(address(this));
        IERC20(aToken).transferFrom(c.user, address(this), c.maxCollateralIn);
        // What the pull ADDED, measured, not `maxCollateralIn`: a rebasing transfer can land a wei
        // short, and `withdraw` reverts on a wei more than the balance. With nothing parked it is the
        // whole balance, the same withdrawal as `max`; with aTokens parked here they stay, so a parked
        // balance is never withdrawn (it may exceed the reserve's free liquidity) nor given away.
        uint256 pulled = IERC20(aToken).balanceOf(address(this)) - parked;
        withdrawn = POOL.withdraw(c.collateralAsset, pulled, address(this));
    }

    /// 3. Buy back exactly what the pool will take, less the flash loan the repay left unspent. A
    ///    balance of the debt asset parked here before the call is not the call's and pays nothing.
    function _buyBack(
        address asset,
        uint256 owed,
        uint256 parkedDebt,
        address collateralAsset,
        uint24 poolFee,
        uint256 withdrawn
    ) internal returns (uint256 spent) {
        uint256 held = IERC20(asset).balanceOf(address(this)) - parkedDebt;
        uint256 needed = owed > held ? owed - held : 0;
        if (needed == 0) return 0;
        IERC20(collateralAsset).approve(address(ROUTER), withdrawn);
        spent = ROUTER.exactOutputSingle(
            ISwapRouter02.ExactOutputSingleParams({
                tokenIn: collateralAsset,
                tokenOut: asset,
                fee: poolFee,
                recipient: address(this),
                amountOut: needed,
                amountInMaximum: withdrawn,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(collateralAsset).approve(address(ROUTER), 0);
    }

    /// 4. The unspent collateral goes back into the position — or to the wallet when the pool
    ///    refuses a supply (a frozen reserve, a supply cap): a rescue never fails on its leftovers.
    ///    `leftover` is this call's own (withdrawn − spent); raw collateral parked here stays.
    function _settleLeftover(address collateralAsset, address user, uint256 leftover)
        internal
        returns (uint256 resupplied, uint256 returned)
    {
        if (leftover == 0) return (0, 0);
        IERC20(collateralAsset).approve(address(POOL), leftover);
        try POOL.supply(collateralAsset, leftover, user, 0) {
            resupplied = leftover;
        } catch {
            IERC20(collateralAsset).approve(address(POOL), 0);
            IERC20(collateralAsset).transfer(user, leftover);
            returned = leftover;
        }
    }

    function _permitIfNeeded(address aToken, Call memory c) internal {
        if (IERC20(aToken).allowance(c.user, address(this)) >= c.maxCollateralIn) return;
        // A permit that fails (already used, expired, wrong nonce) is tolerated here: the
        // transferFrom that follows is the real check, and it reverts without an allowance.
        try IERC20Permit(aToken)
            .permit(c.user, address(this), c.permit.value, c.permit.deadline, c.permit.v, c.permit.r, c.permit.s) {}
            catch {}
    }
}
