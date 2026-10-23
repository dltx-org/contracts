// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixtureV1} from "./FixtureV1.sol";
import {MockAaveWorld, MockToken} from "./MocksV1.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {AaveV3AssetLegState} from "../src/AaveV3AssetLegState.sol";
import {AaveV3AssetLegExit} from "../src/AaveV3AssetLegExit.sol";
import {AaveV3AssetLegRewards} from "../src/AaveV3AssetLegRewards.sol";
import {AssetProfile, StrategySpec} from "../src/Types.sol";
import {Holding} from "../src/lib/VaultTypes.sol";

/// `_limitAt` and `_reference`, exposed (the leg's state with the unit world's AAVE).
contract BandHarness is AaveV3AssetLegState {
    constructor(address aave, address usdc, address seq) AaveV3AssetLegState(aave, usdc, aave, seq) {}

    function limitAt(uint256 pIn, uint256 pUsdc, uint256 band, uint256 decimals, bool isToken0)
        external
        pure
        returns (uint160)
    {
        return _limitAt(pIn, pUsdc, band, decimals, isToken0);
    }
}

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// A Uniswap V3 pool at a fixed price that fills in full, with Uniswap's price-limit checks by direction.
contract MockSwapPool {
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96;
    uint256 public outPer0; // token1 out per token0 in, 1e18
    uint256 public outPer1; // token0 out per token1 in, 1e18
    bool public lastZeroForOne;
    uint160 public lastLimit;

    constructor(address t0, address t1) {
        (token0, token1) = (t0, t1);
    }

    function set(uint160 p, uint256 r0, uint256 r1) external {
        (sqrtPriceX96, outPer0, outPer1) = (p, r0, r1);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256 a0, int256 a1)
    {
        require(
            zeroForOne ? limit < sqrtPriceX96 && limit > MIN_SQRT : limit > sqrtPriceX96 && limit < MAX_SQRT, "SPL"
        );
        (lastZeroForOne, lastLimit) = (zeroForOne, limit);
        uint256 amountIn = uint256(amountSpecified);
        uint256 out = amountIn * (zeroForOne ? outPer0 : outPer1) / 1e18;
        (address tin, address tout) = zeroForOne ? (token0, token1) : (token1, token0);
        MockToken(tout).transfer(recipient, out);
        (a0, a1) = zeroForOne ? (int256(amountIn), -int256(out)) : (-int256(out), int256(amountIn));
        uint256 before = MockToken(tin).balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
        require(MockToken(tin).balanceOf(address(this)) >= before + amountIn, "IIA");
    }
}

/*
 * The token order and decimals the version-0 leg never met (asset-profiles-design.md §3.2, §4.2): the
 * band's limit in both orders (the token0 form equal to version 0's 18-decimal formula; the token1 form
 * its inverse, with no overflow at 18 decimals), and on an 18-decimal mock token deployed ABOVE USDC
 * (token1): the key's `swap` in both directions (one `zeroForOne` deciding the direction, the extreme
 * limit and which amount is paid) and an exit sale held to the band.
 */
contract Token1V1Test is FixtureV1 {
    BandHarness band;
    MockToken mock; // 18 decimals, its address above USDC's: the pool's token1
    MockToken aMock;
    MockSwapPool pool;
    address hub;
    address long;
    bytes32 profile;
    uint256 constant PRICE = 2_000e8;

    function setUp() public {
        _arbitrum();
        band = new BandHarness(address(aave), ARB_USDC, address(seqFeed));
        address at = address(0xFfFFFFff00000000000000000000000000000001);
        vm.etch(at, address(new MockToken(18)).code);
        vm.store(at, bytes32(0), bytes32(uint256(18))); // decimals
        mock = MockToken(at);
        aMock = new MockToken(18);
        assertGt(uint160(address(mock)), uint160(ARB_USDC));
        pool = new MockSwapPool(ARB_USDC, address(mock));
        aave.setReserve(address(mock), address(aMock), address(0), aave.GOOD_CONFIG(), 7);
        aave.setPrice(address(mock), PRICE, address(0xD0C));
        aave.setPool(address(mock), ARB_USDC, 500, address(pool));
        // at AAVE's price exactly: 1 token (1e18) = 2,000 USDC (2e9)
        uint160 atOracle = band.limitAt(PRICE, 1e8, 0, 18, false);
        pool.set(atOracle, 5e26, 2e9); // token0 (USDC) in → 5e8 token-wei per unit; token1 in → 2e-9 USDC per wei
        AssetProfile memory p = _btc();
        p.asset = address(mock);
        p.assetDecimals = 18;
        p.aAsset = address(aMock);
        p.swapPool = address(pool);
        p.assetIsToken0 = false;
        p.rateFeed = address(0);
        p.rateDescription = bytes32(0);
        p.rateMaxAge = 0;
        profile = _accept(p);
        StrategySpec memory c = _spec(
            manifest1, abi.encode(_hubParams(profile)), abi.encode(_longParams(p, profile)), abi.encode(_shortParams(p, profile))
        );
        address[] memory made = _create(c);
        (hub, long) = (made[0], made[1]);
        mock.mint(address(pool), 1_000e18);
        usdc.mint(address(pool), 10_000_000e6);
    }

    // ── the limit's arithmetic ─────────────────────────────────────────────────────────────────────────

    function test_limitAt_token0IsVersion0sFormulaRoundedUp() public view {
        uint256[3] memory prices = [uint256(2_405e8), 1e8, 18_196_000];
        for (uint256 i; i < prices.length; ++i) {
            uint256 v0 = Math.sqrt(prices[i] * (10_000 - 50) * (1 << 192) / (1e8 * 1e16));
            uint256 v1 = band.limitAt(prices[i], 1e8, 50, 18, true);
            assertTrue(v1 == v0 || v1 == v0 + 1);
        }
    }

    function test_limitAt_token1IsTheInverse() public view {
        uint256 x = band.limitAt(PRICE, 1e8, 50, 18, true);
        uint256 y = band.limitAt(PRICE, 1e8, 50, 18, false);
        assertEq(y, Math.mulDiv(1 << 96, 1 << 96, x)); // rounded down
        // a sale of token1 pushes its price up: the band's limit sits above the oracle's price
        assertGt(y, band.limitAt(PRICE, 1e8, 0, 18, false));
        assertLt(x, band.limitAt(PRICE, 1e8, 0, 18, true));
    }

    function testFuzz_limitAt_noOverflow(uint256 pIn, uint256 bandBp, uint8 decimals, bool token0) public view {
        pIn = bound(pIn, 1, 1e20); // 8 decimals: up to a trillion dollars a unit
        bandBp = bound(bandBp, 0, 500);
        uint256 d = bound(decimals, 6, 18);
        uint160 l = band.limitAt(pIn, 1e8, bandBp, d, token0);
        assertGt(l, 0);
    }

    /// WBTC (8 decimals, token0): about 820 USDC units per satoshi at $82,000 (§4.2).
    function test_limitAt_wbtcIsInRange() public view {
        uint256 l = band.limitAt(82_000e8, 1e8, 0, 8, true);
        uint256 rawPrice = Math.mulDiv(l, l, 1 << 192);
        assertEq(rawPrice, 820); // rounded up: never below the exact price
    }

    // ── the token1 asset's sales ─────────────────────────────────────────────────────────────────────

    function test_swap_bothDirectionsOnAToken1Asset() public {
        // buy the asset with USDC: USDC is token0, so zeroForOne, the low extreme
        usdc.mint(long, 2_000e6);
        vm.prank(key);
        AaveV3AssetLegRewards(long).swap(false, 2_000e6, 0);
        assertTrue(pool.lastZeroForOne());
        assertEq(pool.lastLimit(), 4295128740);
        assertEq(mock.balanceOf(long), 1e18);
        // sell it back: oneForZero, the high extreme
        vm.prank(key);
        AaveV3AssetLegRewards(long).swap(true, 1e18, 0);
        assertFalse(pool.lastZeroForOne());
        assertEq(pool.lastLimit(), 1461446703485210103287273052203988822378723970341);
        assertEq(mock.balanceOf(long), 0);
        assertEq(usdc.balanceOf(long), 2_000e6);
    }

    function test_swap_floorRefusesAShortSale() public {
        mock.mint(long, 1e18);
        pool.set(pool.sqrtPriceX96(), 5e26, 1.97e9); // 1.5 % under AAVE: below the signed 1 % bound
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.SwapShort.selector);
        AaveV3AssetLegRewards(long).swap(true, 1e18, 0);
    }

    function test_exitSale_token1HeldToTheBand() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        MemberBase(hub).beginExit(deadline, _beginExitSig(deadline));
        mock.mint(long, 1e18);
        // the pool 60 bp below the oracle (in the asset's price): beyond the 50 bp band, nothing sells
        uint160 off = band.limitAt(PRICE, 1e8, 60, 18, false);
        pool.set(off, 5e26, 1.988e9);
        vm.expectEmit(true, true, true, false, long);
        emit AaveV3AssetLegState.ExitPartFailed(6, abi.encodeWithSelector(AaveV3AssetLegState.PoolOffOracle.selector));
        AaveV3AssetLegExit(long).exitStep(0, 0);
        assertEq(mock.balanceOf(long), 1e18);
        // at the oracle: the sale goes, oneForZero, its limit the band's (above the price)
        pool.set(band.limitAt(PRICE, 1e8, 0, 18, false), 5e26, 2e9);
        AaveV3AssetLegExit(long).exitStep(0, 0);
        assertEq(mock.balanceOf(long), 0);
        assertFalse(pool.lastZeroForOne());
        assertEq(pool.lastLimit(), band.limitAt(PRICE, 1e8, 50, 18, false));
        assertEq(usdc.balanceOf(hub), 2_000e6); // part 7: to the hub beside it
    }

    function test_holdings_scaleTo18Decimals() public {
        mock.mint(long, 3e18);
        (Holding[] memory h,,,,,,) = AaveV3AssetLegExit(long).holdings();
        assertEq(h[0].quantity, 3e18);
    }
}
