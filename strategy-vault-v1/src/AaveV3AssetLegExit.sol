// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {AaveV3AssetLegState} from "./AaveV3AssetLegState.sol";
import {IAavePool, IERC20} from "./interfaces/Protocols.sol";
import {Holding} from "./lib/VaultTypes.sol";

/// The rewards module's exit part, reached through the leg (`AaveV3AssetLegRewards.rewardPart`).
interface IRewardPart {
    function rewardPart(uint8 part) external;
}

/*
 * The AAVE V3 asset leg's EXIT MODULE (version 0's `LongVaultExit`, generic: asset-profiles-design.md
 * §3.2): `exitStep` and its parts, `receiveMint`, `report` and `holdings`, run only by DELEGATECALL from
 * an instance (`delegated`), in its storage. The reward parts 8 and 9 live in the rewards module: the
 * exit holds the money lock, so it reaches them by `rewardPart` (self-only, no lock of its own) through
 * the leg, each under its gas cap with its revert data bounded, never silently skipped.
 */
contract AaveV3AssetLegExit is AaveV3AssetLegState {
    uint256 internal constant REWARD_PART_GAS = 1_200_000;
    uint256 internal constant REWARD_PROBE_GAS = 30_000;
    uint256 internal constant REWARD_REVERT_BYTES = 256;
    uint256 internal constant EXIT_RESERVE_GAS = 2_700_000;

    constructor(address pool, address usdc, address receiver, address sequencer)
        AaveV3AssetLegState(pool, usdc, receiver, sequencer)
    {}

    // ── the exit (§8.4): anyone, until done ──────────────────────────────────────────────────────────

    /// Version 0's exit, the asset the profile's (`assetChunk` at a time, 0 = all): the reward first,
    /// then repay from USDC, aUSDC, with collateral through the receiver (part 3, else the non-flash
    /// fallback, part 4), withdraw (parts 5 and 10), sell the asset within the band (part 6), the USDC
    /// to the hub less what still repays the debt (part 7).
    function exitStep(uint256 debtChunk, uint256 assetChunk) external delegated nonReentrant inExit counted {
        if (_rewardWork()) {
            if (gasleft() < 2 * REWARD_PART_GAS + EXIT_RESERVE_GAS) revert GasTooLow();
            _rewardPart(9);
            _rewardPart(8);
        }
        _part(1, debtChunk);
        _part(2, debtChunk);
        if (!_part(3, debtChunk)) _part(4, debtChunk);
        _part(5, 0);
        _part(10, 0);
        _part(6, assetChunk);
        _part(7, 0);
    }

    function _part(uint8 part, uint256 arg) internal returns (bool ok) {
        try this.exitPart(part, arg) {
            return true;
        } catch (bytes memory reason) {
            emit ExitPartFailed(part, reason);
        }
    }

    /// A reward part, in the rewards module through the leg: its own gas cap, at most
    /// `REWARD_REVERT_BYTES` of its revert data copied.
    function _rewardPart(uint8 part) internal {
        bytes memory data = abi.encodeCall(IRewardPart.rewardPart, (part));
        bool ok;
        bytes memory reason;
        uint256 gasCap = REWARD_PART_GAS;
        uint256 maxCopy = REWARD_REVERT_BYTES;
        assembly ("memory-safe") {
            ok := call(gasCap, address(), 0, add(data, 0x20), mload(data), 0, 0)
            if iszero(ok) {
                let n := returndatasize()
                if gt(n, maxCopy) { n := maxCopy }
                reason := mload(0x40)
                mstore(reason, n)
                returndatacopy(add(reason, 0x20), 0, n)
                mstore(0x40, add(add(reason, 0x20), and(add(n, 31), not(31))))
            }
        }
        if (!ok) emit ExitPartFailed(part, reason);
    }

    /// One part of `exitStep`, called by the leg itself only (so it can fail on its own).
    function exitPart(uint8 part, uint256 arg) external delegated {
        if (msg.sender != address(this)) revert NotAllowed();
        uint256 debt = IERC20(VDEBT_USDC).balanceOf(address(this));
        if (part == 1) {
            if (debt > 0 && IERC20(USDC).balanceOf(address(this)) > 0) _repay(type(uint256).max);
        } else if (part == 2) {
            if (debt > 0 && IERC20(A_USDC).balanceOf(address(this)) > 0) {
                IAavePool(POOL).repayWithATokens(USDC, type(uint256).max, VARIABLE);
            }
        } else if (part == 3 || part == 4) {
            if (debt == 0) return;
            uint256 chunk = arg == 0 || arg > debt ? debt : arg;
            uint256 coll = _collateralBound(chunk);
            uint256 held = IERC20(_aAsset).balanceOf(address(this));
            if (coll > held) coll = held;
            if (part == 3) {
                // the receiver's swap can't take a limit: the pool read before it and after it (§3.2)
                (uint160 limit,,) = _bandLimit();
                if (_beyond(_sqrtPrice(_swapPool), limit, false)) revert PoolOffOracle();
                _repayWithCollateral(chunk, coll, false);
                if (_beyond(_sqrtPrice(_swapPool), limit, true)) revert BandCrossed();
            } else {
                _repayBySale(_releasable(coll));
            }
        } else if (part == 5 || part == 10) {
            if (debt > 0) return;
            _withdrawAvailable(part == 5 ? _asset : USDC, part == 5 ? _aAsset : A_USDC);
        } else if (part == 6) {
            uint256 held = IERC20(_asset).balanceOf(address(this));
            if (held > 0) _exitSale(arg == 0 || arg > held ? held : arg);
        } else if (part == 7) {
            uint256 keep = debt > 0 ? _withHeadroom(debt) : 0;
            uint256 usdc = IERC20(USDC).balanceOf(address(this));
            _sendToHub(usdc > keep ? usdc - keep : 0);
        } else {
            revert Unsupported();
        }
    }

    /// Part 4's withdrawal capped at what AAVE lets go (the liquidation-weighted collateral above the debt,
    /// less 1 %, at AAVE's price, as if the asset counted in full) and at what the reserve holds.
    function _releasable(uint256 coll) internal view returns (uint256) {
        (uint256 collateral, uint256 debtBase,, uint256 lt,,) = IAavePool(POOL).getUserAccountData(address(this));
        if (lt > 0) {
            uint256 weighted = collateral * lt / 10_000;
            uint256 free = weighted > debtBase ? (weighted - debtBase) * 99 / 100 * _unit() / _price(_asset) : 0;
            if (coll > free) coll = free;
        }
        uint256 avail = IAavePool(POOL).getVirtualUnderlyingBalance(_asset);
        return coll < avail ? coll : avail;
    }

    function _withdrawAvailable(address a, address aToken) internal {
        uint256 bal = IERC20(aToken).balanceOf(address(this));
        if (bal == 0) return;
        uint256 avail = IAavePool(POOL).getVirtualUnderlyingBalance(a);
        if (avail == 0) return;
        IAavePool(POOL).withdraw(a, bal <= avail ? type(uint256).max : avail, address(this));
    }

    /// The non-flash fallback: withdraw, sell what the band lets go, supply back the rest, repay; the
    /// health factor afterwards never lower.
    function _repayBySale(uint256 collateral) internal {
        if (collateral == 0) return;
        uint256 hfBefore = _health();
        address a = _asset;
        uint256 got = IAavePool(POOL).withdraw(a, collateral, address(this));
        uint256 paid = _exitSale(got);
        if (got > paid) {
            IERC20(a).approve(POOL, got - paid);
            IAavePool(POOL).supply(a, got - paid, address(this), 0);
        }
        _repay(type(uint256).max);
        if (_health() < hfBefore) revert HealthFell();
    }

    /// An exit sale of the asset, at pool prices no worse than the band's limit (a partial fill accepted),
    /// its average no worse than the REFERENCE less `oracleBoundBp` on what was paid; refused while the
    /// pool is already at or beyond the limit. The event's loss is against AAVE's price.
    function _exitSale(uint256 amountIn) internal returns (uint256 paid) {
        (uint160 limit, uint256 pr, uint256 pu) = _bandLimit();
        if (_beyond(_sqrtPrice(_swapPool), limit, false)) revert PoolOffOracle();
        uint256 out;
        (paid, out) = _poolSwap(_isToken0, amountIn, limit);
        uint256 unit = _unit();
        if (out < paid * pr * 1e6 * (10_000 - oracleBoundBp) / (pu * unit * 10_000)) revert SwapShort();
        uint256 valueIn = paid * _price(_asset) / unit;
        uint256 valueOut = out * pu / 1e6;
        emit Swapped(true, paid, out, valueIn > valueOut ? valueIn - valueOut : 0);
    }

    // ── the exit's reward admission (amendment 2c §3.7), every read bounded ─────────────────────────────

    function _rewardWork() internal view returns (bool) {
        if (_probeCollateral()) return true;
        uint256 a = _probeBalance(REWARD);
        uint256 b = _probeBalance(A_REWARD);
        return (a < REWARD_DUST ? a : REWARD_DUST) + (b < REWARD_DUST ? b : REWARD_DUST) >= REWARD_DUST;
    }

    function _probeCollateral() internal view returns (bool on) {
        bytes memory data = abi.encodeCall(IAavePool.getReserveData, (REWARD));
        uint256 gasCap = REWARD_PROBE_GAS * 2;
        address pool = POOL;
        uint256 id;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gasCap, pool, add(data, 0x20), mload(data), 0, 0)
            if and(ok, iszero(lt(returndatasize(), 0x100))) {
                returndatacopy(0, 0xe0, 0x20)
                id := mload(0)
            }
        }
        if (!ok || id > 127) return false;
        data = abi.encodeCall(IAavePool.getUserConfiguration, (address(this)));
        uint256 cfg;
        assembly ("memory-safe") {
            ok := staticcall(gasCap, pool, add(data, 0x20), mload(data), 0, 0)
            if and(ok, iszero(lt(returndatasize(), 0x20))) {
                returndatacopy(0, 0, 0x20)
                cfg := mload(0)
            }
        }
        return ok && (cfg >> (id * 2)) & 2 != 0;
    }

    function _probeBalance(address token) internal view returns (uint256 b) {
        bytes memory data = abi.encodeCall(IERC20.balanceOf, (address(this)));
        uint256 gasCap = REWARD_PROBE_GAS;
        assembly ("memory-safe") {
            let ok := staticcall(gasCap, token, add(data, 0x20), mload(data), 0, 0)
            if and(ok, iszero(lt(returndatasize(), 32))) {
                returndatacopy(0, 0, 32)
                b := mload(0)
            }
        }
    }

    // ── the leg's rarely called functions, here for size ──────────────────────────────────────────────

    function receiveMint(bytes calldata message, bytes calldata attestation) external delegated nonReentrant {
        _receiveMint(message, attestation);
    }

    function report() external delegated nonReentrant {
        _report();
    }

    function holdings()
        external
        view
        delegated
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool)
    {
        return _legView();
    }
}
