// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AaveV3AssetLegExit} from "../src/AaveV3AssetLegExit.sol";
import {IERC20} from "../src/interfaces/Protocols.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {MockToken} from "./MocksV1.sol";

interface IUniFactory {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

interface IUniPoolInit {
    function initialize(uint160 sqrtPriceX96) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface INpm {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata p) external returns (uint256, uint128, uint256, uint256);
}

/// The leg's own sale code with its state set by hand: the generic `_swap` (the key's, both directions)
/// and `_exitSale` (the band), on a real pool, and the leg's callback, word for word.
contract Token1Leg is AaveV3AssetLegExit {
    constructor() AaveV3AssetLegExit(Arbitrum.POOL, Arbitrum.USDC, Arbitrum.RECEIVER, Arbitrum.SEQUENCER) {}

    function set(address asset, address pool, uint24 fee, uint8 decimals, bool isToken0, uint16 bound) external {
        (_asset, _swapPool, _swapFee, _decimals, _isToken0, oracleBoundBp) = (asset, pool, fee, decimals, isToken0, bound);
    }

    function keySwap(bool assetToUsdc, uint256 amountIn) external returns (uint256) {
        return _swap(assetToUsdc, amountIn, 0, false);
    }

    function exitSale(uint256 amountIn) external returns (uint256) {
        return _exitSale(amountIn);
    }

    function bandLimit() external view returns (uint160 limit) {
        (limit,,) = _bandLimit();
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (_swapping != SWAP_POSITION || msg.sender != _swapPool) revert NotAllowed();
        (address t0, address t1) = _isToken0 ? (_asset, USDC) : (USDC, _asset);
        if (amount0Delta > 0) IERC20(t0).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(t1).transfer(msg.sender, uint256(amount1Delta));
    }
}

/*
 * asset-profiles-design.md §4.2 on an Arbitrum fork: an 18-decimal token deployed ABOVE USDC, so the pool's
 * token1, in a REAL Uniswap V3 pool (the canonical factory, a full-range position through the position
 * manager): the leg's `_swap` both ways (one `zeroForOne` for direction, the extreme limit and which amount
 * is paid, checked by Uniswap itself: a wrong limit for the direction reverts `SPL`), and its exit sale held
 * to the band (`_bandLimit` in the token1 form, `_beyond` both ways), refused once the pool sits beyond it.
 * AAVE's price for the token is mocked (AAVE does not list it). SKIPPED without ARBITRUM_RPC_URL.
 */
contract Token1PoolForkTest is Test {
    address constant UNI_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant TOKEN = 0xFfFFFFff00000000000000000000000000000001;
    uint256 constant PRICE = 2_000e8;

    bool forked;
    Token1Leg leg;
    address pool;

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, 517_200_797);
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        forked = true;
        vm.etch(TOKEN, address(new MockToken(18)).code);
        vm.store(TOKEN, bytes32(0), bytes32(uint256(18)));
        pool = IUniFactory(UNI_FACTORY).createPool(Arbitrum.USDC, TOKEN, 500);
        assertEq(IUniPoolInit(pool).token0(), Arbitrum.USDC);
        assertEq(IUniPoolInit(pool).token1(), TOKEN);
        leg = new Token1Leg();
        vm.mockCall(Arbitrum.ORACLE, abi.encodeWithSignature("getAssetPrice(address)", TOKEN), abi.encode(PRICE));
        leg.set(TOKEN, pool, 500, 18, false, 100);
        // at AAVE's price: 1 token (1e18) for 2,000 USDC (2e9), in the pool's token1-per-token0 form
        IUniPoolInit(pool).initialize(_atBand(0));
        // a full-range position: 1,000 tokens and 2,000,000 USDC
        deal(Arbitrum.USDC, address(this), 2_000_000e6);
        MockToken(TOKEN).mint(address(this), 1_000e18);
        IERC20(Arbitrum.USDC).approve(NPM, type(uint256).max);
        MockToken(TOKEN).approve(NPM, type(uint256).max);
        INpm(NPM).mint(
            INpm.MintParams(Arbitrum.USDC, TOKEN, 500, -887_270, 887_270, 2_000_000e6, 1_000e18, 0, 0, address(this), block.timestamp)
        );
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// The leg's limit at `bandBp` under AAVE's price (the exit's band with `oracleBoundBp` set high).
    function _atBand(uint256 bandBp) internal returns (uint160 l) {
        leg.set(TOKEN, pool, 500, 18, false, uint16(bandBp + 5)); // band = oracleBoundBp − the 5 bp fee
        l = leg.bandLimit();
        leg.set(TOKEN, pool, 500, 18, false, 100);
    }

    function _price() internal view returns (uint160 p) {
        (p,,,,,,) = IUniPoolInit(pool).slot0();
    }

    function test_fork_token1_keySwapBothWaysOnARealPool() public onFork {
        deal(Arbitrum.USDC, address(leg), 2_000e6);
        uint256 got = leg.keySwap(false, 2_000e6); // buy: USDC is token0, zeroForOne, the low extreme
        assertApproxEqRel(got, 1e18, 0.003e18, "about a token, less the fee and the impact");
        assertEq(MockToken(TOKEN).balanceOf(address(leg)), got);
        uint256 usdc = leg.keySwap(true, got); // sell: oneForZero, the high extreme
        assertApproxEqRel(usdc, 2_000e6, 0.003e18);
        assertEq(MockToken(TOKEN).balanceOf(address(leg)), 0);
    }

    function test_fork_token1_exitSaleHeldToTheBand() public onFork {
        // oracleBoundBp 100: the band is min(50, 100 − 5) = 50 bp under AAVE's price
        uint160 limit = leg.bandLimit();
        assertGt(limit, _price(), "a token1 sale pushes the price up: its limit sits above it");
        MockToken(TOKEN).mint(address(leg), 200e18);
        uint256 paid = leg.exitSale(200e18);
        assertLt(paid, 200e18, "a partial fill: the sale stopped at the band");
        assertEq(_price(), limit, "the pool stopped exactly at the limit");
        vm.expectRevert(bytes4(keccak256("PoolOffOracle()")));
        leg.exitSale(1e18);
    }
}
