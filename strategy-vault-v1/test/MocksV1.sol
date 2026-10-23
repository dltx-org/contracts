// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {AaveReserveData} from "../src/interfaces/Protocols.sol";
import {Hub} from "../src/Hub.sol";
import {AaveV3AssetLeg} from "../src/AaveV3AssetLeg.sol";
import {HyperCoreLeg} from "../src/HyperCoreLeg.sol";

/*
 * Version 1's unit-test doubles. Test-only; nothing here is deployed.
 */

/// An ERC-20 with decimals, for an asset profile's token and aToken.
contract MockToken {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/*
 * AAVE V3 and Uniswap V3 as the asset leg's implementation and its profile check read them, in one
 * contract: the pool (`getReserveData`, `getUserAccountData`, `getUserConfiguration`), its addresses
 * provider and price oracle (`getAssetPrice`, `getSourceOfAsset`), the repay-with-collateral receiver
 * (`POOL`, `ROUTER`), the router (`factory`) and the Uniswap V3 factory (`getPool`). No market call.
 */
contract MockAaveWorld {
    mapping(address => AaveReserveData) internal _reserves;
    mapping(address => uint256) public price;
    mapping(address => address) public source;
    mapping(bytes32 => address) internal _pools;
    uint256 public health = 2e18;

    // AAVE's reserve configuration: LTV 73 %, active, plus virtual accounting (bit 252)
    uint256 public constant GOOD_CONFIG = 7300 | (1 << 56) | (1 << 252);

    function setReserve(address asset, address aToken, address vDebt, uint256 configuration, uint16 id) external {
        AaveReserveData storage r = _reserves[asset];
        r.aTokenAddress = aToken;
        r.variableDebtTokenAddress = vDebt;
        r.configuration = configuration;
        r.id = id;
    }

    function setConfiguration(address asset, uint256 configuration) external {
        _reserves[asset].configuration = configuration;
    }

    function setPrice(address asset, uint256 p, address src) external {
        price[asset] = p;
        source[asset] = src;
    }

    function setPool(address a, address b, uint24 fee, address pool) external {
        _pools[keccak256(abi.encode(a, b, fee))] = pool;
        _pools[keccak256(abi.encode(b, a, fee))] = pool;
    }

    function setHealth(uint256 h) external {
        health = h;
    }

    // the pool
    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(this);
    }

    function getReserveData(address asset) external view returns (AaveReserveData memory) {
        return _reserves[asset];
    }

    function getUserAccountData(address)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (0, 0, 0, 0, 0, health);
    }

    function getUserConfiguration(address) external pure returns (uint256) {
        return 0;
    }

    // the addresses provider and the oracle
    function getPriceOracle() external view returns (address) {
        return address(this);
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return price[asset];
    }

    function getSourceOfAsset(address asset) external view returns (address) {
        return source[asset];
    }

    // the receiver, its router, the Uniswap factory
    function POOL() external view returns (address) {
        return address(this);
    }

    function ROUTER() external view returns (address) {
        return address(this);
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return _pools[keccak256(abi.encode(a, b, fee))];
    }
}

/// A Uniswap V3 pool's `slot0`, settable (the leg's band reads it).
contract MockSlot0 {
    uint160 public sqrtPriceX96;

    function setPrice(uint160 p) external {
        sqrtPriceX96 = p;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}

// ── version-2 implementations: the same code under the next number (an upgrade's target) ─────────────

/// A later version's implementations name their listing registry (§A9), which a proposal requires.
contract HubV2 is Hub {
    address public immutable listingRegistry;

    constructor(address f, bytes32 fh, address u, bytes32 uh, address r, address s) Hub(f, fh, u, uh, s) {
        listingRegistry = r;
    }

    function CODE_VERSION() public pure override returns (uint32) {
        return 2;
    }
}

contract AaveV3AssetLegV2 is AaveV3AssetLeg {
    constructor(
        address e,
        bytes32 eh,
        address rw,
        bytes32 rwh,
        address u,
        bytes32 uh,
        address r,
        address pool,
        address usdc,
        address receiver,
        address sequencer
    ) AaveV3AssetLeg(e, eh, rw, rwh, u, uh, pool, usdc, receiver, sequencer) {
        listingRegistry = r;
    }

    address public immutable listingRegistry;

    function CODE_VERSION() public pure override returns (uint32) {
        return 2;
    }
}

contract HyperCoreLegV2 is HyperCoreLeg {
    constructor(address e, bytes32 eh, address b, bytes32 bh, address u, bytes32 uh, address r)
        HyperCoreLeg(e, eh, b, bh, u, uh)
    {
        listingRegistry = r;
    }

    address public immutable listingRegistry;

    function CODE_VERSION() public pure override returns (uint32) {
        return 2;
    }
}
