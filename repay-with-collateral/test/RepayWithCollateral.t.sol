// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console} from "forge-std/Test.sol";
import {IERC20, IPool, ISwapRouter02, RepayWithCollateral} from "../src/RepayWithCollateral.sol";

/*
 * Fork tests against the real pools — docs/architecture/repay-with-collateral-design.md §7.
 *
 * Positions are built fresh on the fork from a test key (so the permit can be signed), sized the
 * way today's incidents sat: borrowed to the LTV ceiling, then the pool's oracle is mocked a few
 * percent lower to put the health factor where cb67d44c (1.0098) and 7cfbc206 (1.030) were, or
 * under 1.0. Only the oracle is mocked; the swap runs on the real Uniswap V3 pool at the real price.
 */

interface IPoolExt is IPool {
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
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function ADDRESSES_PROVIDER() external view returns (address);
    function getConfiguration(address asset) external view returns (IPool.ReserveConfigurationMap memory);
    function setConfiguration(address asset, IPool.ReserveConfigurationMap calldata configuration) external;
}

interface IAddressesProvider {
    function getPriceOracle() external view returns (address);
    function getPoolConfigurator() external view returns (address);
}

interface IPriceOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IATokenPermit {
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IQuoterV2 {
    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

abstract contract RepayWithCollateralForkTest is Test {
    // ── the venue ────────────────────────────────────────────────────────────────────────────────
    string internal rpcAlias;
    address internal POOL_ADDR;
    address internal WETH;
    address internal USDC;
    address internal constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // SwapRouter02, both chains
    address internal constant QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e; // QuoterV2, both chains
    uint24 internal constant FEE = 500; // ETH/USDC 0.05%

    // ── the fixture ──────────────────────────────────────────────────────────────────────────────
    uint256 internal constant USER_PK = 0xA11CE;
    address internal user;
    IPoolExt internal pool;
    RepayWithCollateral internal rwc;
    address internal oracle;
    address internal aWeth;
    address internal vUsdc;
    uint256 internal realWethPrice; // oracle, base currency (8 decimals)

    uint256 internal constant SLIPPAGE_BPS = 50;
    uint256 internal constant FROZEN_BIT = 57; // ReserveConfiguration: FROZEN_MASK bit

    function setUp() public virtual {
        vm.createSelectFork(vm.rpcUrl(rpcAlias));
        pool = IPoolExt(POOL_ADDR);
        rwc = new RepayWithCollateral(IPool(POOL_ADDR), ISwapRouter02(ROUTER));
        user = vm.addr(USER_PK);
        oracle = IAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle();
        IPool.ReserveData memory w = pool.getReserveData(WETH);
        aWeth = w.aTokenAddress;
        vUsdc = pool.getReserveData(USDC).variableDebtTokenAddress;
        realWethPrice = IPriceOracle(oracle).getAssetPrice(WETH);
        vm.label(address(rwc), "RepayWithCollateral");
        vm.label(user, "user");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────

    /// Mock the pool oracle's WETH price to `bps/10_000` of the real one (the only mock used).
    function mockWethPriceBps(uint256 bps) internal {
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IPriceOracle.getAssetPrice.selector, WETH),
            abi.encode((realWethPrice * bps) / 10_000)
        );
    }

    /// The oracle factor (bps of the real price) that puts a position borrowed at the LTV ceiling at
    /// `hfBps` (1e4 = 1.0): HF at the ceiling is LT/LTV — 1.05 on AAVE, 1.012 on Spark — so the knock
    /// a venue needs differs, and a flat percentage is wrong on one of them.
    function priceBpsForHf(uint256 hfBps) internal view returns (uint256) {
        (,,, uint256 lt, uint256 ltv,) = pool.getUserAccountData(user);
        return (hfBps * ltv) / lt;
    }

    /// Supply `wethAmount` and borrow to the LTV ceiling at the CURRENT oracle price.
    function openAtLtvCeiling(uint256 wethAmount) internal {
        deal(WETH, user, wethAmount);
        vm.startPrank(user);
        IERC20(WETH).approve(POOL_ADDR, type(uint256).max);
        pool.supply(WETH, wethAmount, user, 0);
        (,, uint256 availableBase,,,) = pool.getUserAccountData(user);
        // base currency has 8 decimals, USDC 6 → divide by 100; keep a hair under the ceiling.
        uint256 borrowUsdc = (availableBase / 100) - 1;
        pool.borrow(USDC, borrowUsdc, 2, 0, user);
        vm.stopPrank();
    }

    function healthFactor(address who) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(who);
    }

    function debtOf(address who) internal view returns (uint256) {
        return IERC20(vUsdc).balanceOf(who);
    }

    function quoteIn(uint256 usdcOut) internal returns (uint256 wethIn) {
        (wethIn,,,) = IQuoterV2(QUOTER).quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({tokenIn: WETH, tokenOut: USDC, amount: usdcOut, fee: FEE, sqrtPriceLimitX96: 0})
        );
    }

    function premiumOn(uint256 flashAmount) internal view returns (uint256) {
        // FLASHLOAN_PREMIUM_TOTAL() in bps — 5 on AAVE, 0 on Spark
        (bool ok, bytes memory data) = POOL_ADDR.staticcall(abi.encodeWithSignature("FLASHLOAN_PREMIUM_TOTAL()"));
        require(ok, "premium read");
        uint256 bps = abi.decode(data, (uint128));
        return (flashAmount * bps) / 10_000;
    }

    /// The port's sizing (§4.1): quote the worst-case output, add slippage, cap at the aToken balance.
    function sizePull(uint256 flashAmount) internal returns (uint256 maxIn) {
        uint256 out = flashAmount + premiumOn(flashAmount);
        maxIn = (quoteIn(out) * (10_000 + SLIPPAGE_BPS)) / 10_000;
        uint256 bal = IERC20(aWeth).balanceOf(user);
        if (maxIn > bal) maxIn = bal;
    }

    function signPermit(uint256 value, uint256 deadline) internal view returns (RepayWithCollateral.Permit memory p) {
        bytes32 typehash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        uint256 nonce = IATokenPermit(aWeth).nonces(user);
        bytes32 structHash = keccak256(abi.encode(typehash, user, address(rwc), value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IATokenPermit(aWeth).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, digest);
        p = RepayWithCollateral.Permit({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    /// One call as the user, the port's way: size, permit, call.
    function repay(uint256 flashAmount, uint256 debtRepayAmount) internal returns (uint256 repaid, uint256 spent) {
        uint256 maxIn = sizePull(flashAmount);
        RepayWithCollateral.Permit memory p = signPermit(maxIn, block.timestamp + 600);
        vm.prank(user);
        (repaid, spent) = rwc.repayWithCollateral(WETH, USDC, flashAmount, debtRepayAmount, maxIn, FEE, p);
    }

    function assertNoResidue() internal view {
        assertEq(IERC20(WETH).balanceOf(address(rwc)), 0, "WETH left in the contract");
        assertEq(IERC20(USDC).balanceOf(address(rwc)), 0, "USDC left in the contract");
        assertEq(IERC20(aWeth).balanceOf(address(rwc)), 0, "aWETH left in the contract");
    }

    // ── §7: the incidents, replayed ───────────────────────────────────────────────────────────────

    /// cb67d44c's shape: under the 5% withdraw floor, no USDC, a partial repay — the case the loop
    /// could not do at all.
    function test_partialRepayUnderTheFloor() public {
        openAtLtvCeiling(1 ether);
        mockWethPriceBps(priceBpsForHf(10_100)); // HF 1.01 — cb67d44c's 1.0098, under the 5% floor
        uint256 hfBefore = healthFactor(user);
        assertLt(hfBefore, 1.0526e18, "fixture must sit under the 5% floor");
        assertGt(hfBefore, 1e18, "and above liquidation");
        uint256 debtBefore = debtOf(user);
        uint256 r = debtBefore / 10;

        (uint256 repaid, uint256 spent) = repay(r, r);

        assertApproxEqAbs(repaid, r, 1, "repaid the requested amount");
        assertApproxEqAbs(debtOf(user), debtBefore - r, 2, "debt down by R");
        assertGt(healthFactor(user), hfBefore, "health factor up");
        assertGt(spent, 0, "collateral was sold");
        assertNoResidue();
    }

    /// 7cfbc206's close: the whole debt in one transaction, included half an hour after the read.
    function test_fullCloseAfterDelayedInclusion() public {
        openAtLtvCeiling(2 ether);
        uint256 debtRead = debtOf(user);
        uint256 flashAmount = (debtRead * 10_020) / 10_000 + 1; // 20 bps, rounded up
        vm.warp(block.timestamp + 30 minutes); // interest accrues between the read and the inclusion
        uint256 live = debtOf(user);
        assertGt(live, debtRead, "interest accrued");
        assertLt(live, flashAmount, "the buffer still covers it");

        (uint256 repaid,) = repay(flashAmount, rwc.REPAY_ALL());

        assertEq(repaid, live, "the live debt, not the stale read, was repaid");
        assertEq(debtOf(user), 0, "debt is exactly zero");
        assertNoResidue();
        // the position is now debt-free: withdrawAll would succeed (the close's next phase)
        vm.prank(user);
        pool.withdraw(WETH, type(uint256).max, user);
        assertEq(IERC20(aWeth).balanceOf(user), 0);
    }

    /// A buffer too small leaves a residue the close's next pass repays — never a revert. The
    /// shortfall is modelled directly (a flash amount under the live debt) rather than by warping
    /// days ahead: Spark's ETH oracle is a median of several feeds with a staleness check, and a
    /// long warp on a fork leaves it with no fresh feed at all.
    function test_fullCloseWithTooSmallBufferLeavesResidue() public {
        openAtLtvCeiling(1 ether);
        uint256 live = debtOf(user);
        uint256 flashAmount = live - 500_000; // $0.50 short of the live debt

        (uint256 repaid,) = repay(flashAmount, rwc.REPAY_ALL());

        assertEq(repaid, flashAmount, "bounded by the flash amount");
        // to a unit of USDC: Aave's scaled-debt burn rounds
        assertApproxEqAbs(debtOf(user), live - flashAmount, 1, "the residue is what the buffer missed");
        assertNoResidue();
    }

    /// A $0.01 residue against $0.50 of collateral closes with the pull capped at what the wallet owns.
    function test_dustClose() public {
        uint256 halfDollarOfWeth = (0.5e8 * 1e18) / realWethPrice;
        deal(WETH, user, halfDollarOfWeth);
        vm.startPrank(user);
        IERC20(WETH).approve(POOL_ADDR, type(uint256).max);
        pool.supply(WETH, halfDollarOfWeth, user, 0);
        pool.borrow(USDC, 10_000, 2, 0, user); // $0.01
        vm.stopPrank();
        uint256 flashAmount = (10_000 * 10_020) / 10_000 + 1;

        (uint256 repaid, uint256 spent) = repay(flashAmount, rwc.REPAY_ALL());

        assertEq(repaid, debtOf(user) + repaid, "all of it");
        assertEq(debtOf(user), 0);
        assertLt(spent, halfDollarOfWeth / 10, "a cent of collateral, not the half dollar");
        assertNoResidue();
    }

    /// A frozen reserve takes repays and withdrawals but refuses supplies: the leftover goes home.
    function test_frozenReserveReturnsTheLeftover() public {
        openAtLtvCeiling(1 ether);
        mockWethPriceBps(priceBpsForHf(10_300)); // 7cfbc206's 1.030
        uint256 r = debtOf(user) / 10;
        // freeze WETH through the pool's own setter, as the configurator would
        IPool.ReserveConfigurationMap memory cfg = pool.getConfiguration(WETH);
        cfg.data |= (1 << FROZEN_BIT);
        address configurator = IAddressesProvider(pool.ADDRESSES_PROVIDER()).getPoolConfigurator();
        vm.prank(configurator);
        pool.setConfiguration(WETH, cfg);
        uint256 wethBefore = IERC20(WETH).balanceOf(user);

        vm.recordLogs();
        (uint256 repaid, uint256 spent) = repay(r, r);

        assertApproxEqAbs(repaid, r, 1);
        assertGt(IERC20(WETH).balanceOf(user), wethBefore, "the leftover came back as WETH");
        assertNoResidue();
        // the event says so: resupplied 0, returned > 0
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "RepaidWithCollateral(address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            (,,,, uint256 cSpent, uint256 resupplied, uint256 returned) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(cSpent, spent);
            assertEq(resupplied, 0);
            assertGt(returned, 0);
            seen = true;
        }
        assertTrue(seen, "the result event was emitted");
    }

    /// Under 1.0: a repay above R_min rescues the position; one under it reverts on the pull.
    function test_belowOneRescueMinimum() public {
        openAtLtvCeiling(1 ether);
        mockWethPriceBps(priceBpsForHf(9_900)); // HF 0.99 on either venue
        uint256 hf = healthFactor(user);
        assertLt(hf, 1e18, "fixture is under 1.0");
        (uint256 cBase, uint256 dBase,, uint256 lt,,) = pool.getUserAccountData(user);
        // R_min = (D − C·LT) / (1 − (1+s)·LT), s = 3.66% (§4.3), in base units then USDC units
        uint256 cLt = (cBase * lt) / 10_000;
        uint256 denomBps = 10_000 - (10_366 * lt) / 10_000;
        uint256 rMinUsdc = (((dBase - cLt) * 10_000) / denomBps) / 100;

        // under the minimum: the aToken pull fails the pool's health check and the whole call reverts
        uint256 tooSmall = rMinUsdc / 2;
        uint256 maxIn = sizePull(tooSmall);
        RepayWithCollateral.Permit memory p = signPermit(maxIn, block.timestamp + 600);
        vm.prank(user);
        vm.expectRevert();
        rwc.repayWithCollateral(WETH, USDC, tooSmall, tooSmall, maxIn, FEE, p);

        // above it: rescued
        uint256 enough = (rMinUsdc * 3) / 2;
        (uint256 repaid,) = repay(enough, enough);
        assertApproxEqAbs(repaid, enough, 1);
        assertGt(healthFactor(user), hf, "health factor up");
        assertNoResidue();
    }

    /// The guard's boundary: oracle 3% above the DEX, HF a hair over 1.0 — the pull still passes.
    function test_boundaryQuoteAtTheGuard() public {
        // Borrow against an inflated price, then judge the position with the oracle 3% over the DEX:
        // HF = (10_300 / borrowBps) × LT / LTV, so borrowBps = 10_300 × LT / (LTV × 1.001) lands it at
        // 1.001 on either venue (1.08 × real on AAVE, 1.04 × real on Spark).
        mockWethPriceBps(10_300);
        openAtLtvCeiling(1 ether); // a first open just to read LT/LTV for the sizing below
        uint256 borrowBps = (10_300 * 10_000) / priceBpsForHf(10_010);
        // re-open at the inflated price: repay what was borrowed and withdraw, then borrow again
        vm.startPrank(user);
        IERC20(USDC).approve(POOL_ADDR, type(uint256).max);
        deal(USDC, user, debtOf(user) * 2);
        pool.repay(USDC, type(uint256).max, 2, user);
        pool.withdraw(WETH, type(uint256).max, user);
        vm.stopPrank();
        mockWethPriceBps(borrowBps);
        openAtLtvCeiling(1 ether);
        mockWethPriceBps(10_300);
        uint256 hf = healthFactor(user);
        assertGt(hf, 1e18);
        assertLt(hf, 1.02e18, "a hair over 1.0");
        uint256 r = debtOf(user) / 20;

        (uint256 repaid,) = repay(r, r);

        assertApproxEqAbs(repaid, r, 1);
        assertGt(healthFactor(user), hf);
        assertNoResidue();
    }

    // ── §3.2: the contract's own invariants ──────────────────────────────────────────────────────

    function test_thirdPartyCannotTouchTheUsersPosition() public {
        openAtLtvCeiling(1 ether);
        uint256 aBefore = IERC20(aWeth).balanceOf(user);
        uint256 debtBefore = debtOf(user);
        address attacker = makeAddr("attacker");
        uint256 r = debtBefore / 10;
        uint256 maxIn = sizePull(r);
        RepayWithCollateral.Permit memory p = signPermit(maxIn, block.timestamp + 600); // the USER's permit
        // the user has even granted an allowance — still nothing the attacker can use
        vm.prank(user);
        IERC20(aWeth).approve(address(rwc), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert(); // the attacker has no debt to repay, and no aTokens to pull
        rwc.repayWithCollateral(WETH, USDC, r, r, maxIn, FEE, p);

        assertEq(IERC20(aWeth).balanceOf(user), aBefore, "the user's aTokens are untouched");
        assertEq(debtOf(user), debtBefore);
    }

    function test_callbackIsThePoolsAlone() public {
        bytes memory params = "";
        vm.expectRevert(RepayWithCollateral.NotPool.selector);
        rwc.executeOperation(USDC, 1, 0, address(rwc), params);

        vm.prank(POOL_ADDR);
        vm.expectRevert(RepayWithCollateral.NotInitiator.selector);
        rwc.executeOperation(USDC, 1, 0, makeAddr("someone"), params);
    }

    /// 💣 A stray balance must never brick the receiver: it goes to the caller, the operation runs.
    function test_strayBalancesDoNotBrickTheReceiver() public {
        openAtLtvCeiling(1 ether);
        mockWethPriceBps(priceBpsForHf(10_300));
        uint256 r = debtOf(user) / 10;
        // a griefer donates a wei of WETH and a cent of USDC to the contract
        address griefer = makeAddr("griefer");
        deal(WETH, griefer, 1);
        deal(USDC, griefer, 10_000);
        vm.startPrank(griefer);
        IERC20(WETH).transfer(address(rwc), 1);
        IERC20(USDC).transfer(address(rwc), 10_000);
        vm.stopPrank();
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        uint256 debtBefore = debtOf(user);

        (uint256 repaid,) = repay(r, r);

        assertApproxEqAbs(repaid, r, 1, "the operation ran as if nothing had been donated");
        assertApproxEqAbs(debtOf(user), debtBefore - r, 2);
        assertNoResidue();
        assertEq(IERC20(WETH).balanceOf(user), wethBefore + 1, "the stray wei went to the caller");
        // the stray cent of USDC was in the contract when the callback counted what it held, so it
        // paid a cent of the loan instead of a cent of collateral: the user's USDC is unchanged
        assertEq(IERC20(USDC).balanceOf(user), usdcBefore, "the stray cent paid down the loan");
    }

    function test_nothingToRepayReverts() public {
        RepayWithCollateral.Permit memory p;
        vm.prank(user);
        vm.expectRevert(RepayWithCollateral.NothingToRepay.selector);
        rwc.repayWithCollateral(WETH, USDC, 0, 0, 0, FEE, p);
    }

    function test_insufficientMaxInReverts() public {
        openAtLtvCeiling(1 ether);
        uint256 r = debtOf(user) / 10;
        uint256 tooLittle = quoteIn(r + premiumOn(r)) / 2;
        RepayWithCollateral.Permit memory p = signPermit(tooLittle, block.timestamp + 600);
        vm.prank(user);
        vm.expectRevert(); // the router cannot fill within amountInMaximum
        rwc.repayWithCollateral(WETH, USDC, r, r, tooLittle, FEE, p);
    }
}

contract AaveV3ArbitrumTest is RepayWithCollateralForkTest {
    function setUp() public override {
        rpcAlias = "arbitrum";
        POOL_ADDR = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        super.setUp();
    }
}

contract SparkEthereumTest is RepayWithCollateralForkTest {
    function setUp() public override {
        rpcAlias = "mainnet";
        POOL_ADDR = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
        WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        super.setUp();
    }
}
