// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {LongVaultState} from "./LongVaultState.sol";
import {
    IAavePool, IERC20, IMerklDistributor, IRewardsController, IUniswapV3Pool
} from "./interfaces/Protocols.sol";
import {PriceSource} from "./lib/PriceSource.sol";
import {Holding} from "./lib/VaultTypes.sol";

/*
 * The AAVE leg's EXIT MODULE (step 11e2 amendment 2a §3.8): `exitStep` and its parts, run only by
 * DELEGATECALL from a leg (`LongVault`'s fallback), in the leg's storage; called directly, or through a
 * leg code never initialized, they refuse (`delegated`). The leg's own `uniswapV3SwapCallback` answers
 * the pool during the exit's sales: the pool calls the leg's address, whose code is the leg's.
 */
contract LongVaultExit is LongVaultState {
    /// Amendment 2c §3.7: each reward part's gas, its revert data kept, the probe's reads, and what the
    /// position's parts need left when the reward parts run: about twice the fork's measures
    /// (`test_fork_2c_exit_gasMeasured`, 2026-10-17: a reward sale with aArbARB withdrawn 564k, a levered
    /// unwind's parts 1.34M).
    uint256 internal constant REWARD_PART_GAS = 1_200_000;
    uint256 internal constant REWARD_PROBE_GAS = 30_000;
    uint256 internal constant REWARD_REVERT_BYTES = 256;
    uint256 internal constant EXIT_RESERVE_GAS = 2_700_000;

    // ── the exit (§8.4): anyone, until done ──────────────────────────────────────────────────────────

    /// Unwinds and pays out, each part on its own so that one that fails (a paused reserve, no flash
    /// liquidity, a pool off the oracle) doesn't block the rest; a failure is logged. While there is
    /// debt: repay from the vault's own USDC (what its hub routed here included, amendment 2d §5.2), then
    /// from its aUSDC, then with collateral through the receiver (`debtChunk` at a time, 0 = all) or,
    /// when that fails, by the non-flash fallback (withdraw what AAVE lets go, sell, repay). Once the debt
    /// is zero: withdraw what AAVE can pay, the aWETH (part 5) and the aUSDC (part 10) apart. Then sell
    /// the WETH held (`wethChunk` at a time, 0 = all) and send the USDC held, less what still repays the
    /// debt, to the hub, which pays the owner's withdrawal address. Every sale is held to the oracle
    /// bound on its average and, at the margin, to the exit's band (amendment 2d §3.2): a direct sale
    /// fills in part and leaves the rest for a later step; the daily budget does not apply.
    function exitStep(uint256 debtChunk, uint256 wethChunk) external delegated nonReentrant inExit counted {
        // amendment 2c §3.7: the reward first, so its USDC repays debt in this step; never a silent skip
        if (_rewardWork()) {
            if (gasleft() < 2 * REWARD_PART_GAS + EXIT_RESERVE_GAS) revert GasTooLow();
            _rewardPart(9); // aArbARB's collateral off, committed on its own
            _rewardPart(8); // sell the reward held
        }
        _part(1, debtChunk); // the vault's own USDC
        _part(2, debtChunk); // its aUSDC
        if (!_part(3, debtChunk)) _part(4, debtChunk); // with collateral, else the non-flash fallback
        _part(5, 0); // withdraw the aWETH once the debt is zero, as far as AAVE can pay
        _part(10, 0); // the aUSDC, apart: a paused USDC reserve never holds the WETH back (amendment 2d §5.3)
        _part(6, wethChunk); // sell the WETH held, within the band
        _part(7, 0); // the USDC held to the hub (its own part: nothing there can block the unwinding)
    }

    function _part(uint8 part, uint256 arg) internal returns (bool ok) {
        try this.exitPart(part, arg) {
            return true;
        } catch (bytes memory reason) {
            emit ExitPartFailed(part, reason);
        }
    }

    /// A reward part: its own gas cap, at most `REWARD_REVERT_BYTES` of its revert data copied (a reward
    /// dependency can neither starve the position's parts nor flood this frame).
    function _rewardPart(uint8 part) internal {
        bytes memory data = abi.encodeCall(this.exitPart, (part, 0));
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

    /// One part of `exitStep`, called by the vault itself only (so it can fail on its own).
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
            uint256 held = IERC20(A_WETH).balanceOf(address(this));
            if (coll > held) coll = held;
            if (part == 3) {
                // the receiver's swap can't take a limit: the pool read before it and after it (§3.2)
                (uint160 limit,,) = _bandLimit();
                if (_sqrtPrice(SWAP_POOL) <= limit) revert PoolOffOracle();
                _repayWithCollateral(chunk, coll, false);
                if (_sqrtPrice(SWAP_POOL) < limit) revert BandCrossed();
            } else {
                _repayBySale(_releasable(coll));
            }
        } else if (part == 5 || part == 10) {
            if (debt > 0) return;
            _withdrawAvailable(part == 5 ? WETH : USDC, part == 5 ? A_WETH : A_USDC);
        } else if (part == 6) {
            uint256 weth = IERC20(WETH).balanceOf(address(this));
            if (weth > 0) _exitSale(arg == 0 || arg > weth ? weth : arg);
        } else if (part == 8) {
            if (_rewardHeld() >= REWARD_DUST) _swapReward(type(uint256).max, 0);
        } else if (part == 9) {
            _collateralOff();
        } else {
            // revision 1: the hub pays the owner's withdrawal address. Amendment 2d §5.2: while a debt
            // stands the leg keeps USDC up to it and `exitDebt()`'s headroom (part 1 repays it once the
            // reserve takes it), so what its hub routed here never bounces back
            uint256 keep = debt > 0 ? _withHeadroom(debt) : 0;
            uint256 usdc = IERC20(USDC).balanceOf(address(this));
            _sendToHub(usdc > keep ? usdc - keep : 0);
        }
    }

    /// Amendment 2d §3.2: part 4's withdrawal capped at what AAVE lets go — the liquidation-weighted
    /// collateral above the debt, less 1 %, in WETH at the oracle, as if WETH counted in full (its own
    /// threshold is lower, so this is never more than AAVE allows, whatever other collateral anyone
    /// supplied on the leg's behalf and whatever its e-mode: Codex's code review) — and at what the
    /// reserve holds.
    function _releasable(uint256 coll) internal view returns (uint256) {
        (uint256 collateral, uint256 debtBase,, uint256 lt,,) = IAavePool(POOL).getUserAccountData(address(this));
        if (lt > 0) {
            uint256 weighted = collateral * lt / 10_000;
            uint256 free = weighted > debtBase ? (weighted - debtBase) * 99 / 100 * 1e18 / _price(WETH) : 0;
            if (coll > free) coll = free;
        }
        uint256 avail = IAavePool(POOL).getVirtualUnderlyingBalance(WETH);
        return coll < avail ? coll : avail;
    }

    /// Withdraws the aToken's balance as far as the reserve holds it (decision 71), all of it when it can.
    function _withdrawAvailable(address asset, address aToken) internal {
        uint256 bal = IERC20(aToken).balanceOf(address(this));
        if (bal == 0) return;
        uint256 avail = IAavePool(POOL).getVirtualUnderlyingBalance(asset);
        if (avail == 0) return;
        IAavePool(POOL).withdraw(asset, bal <= avail ? type(uint256).max : avail, address(this));
    }

    /// The fallback when the flash loan isn't available: withdraw `collateral` WETH (capped by
    /// `_releasable`, so every step frees some debt), sell what the band lets go, supply back the rest,
    /// repay; the health factor afterwards may not be lower than before. A supply refused (a cap)
    /// reverts the part whole.
    function _repayBySale(uint256 collateral) internal {
        if (collateral == 0) return;
        uint256 hfBefore = _health();
        uint256 got = IAavePool(POOL).withdraw(WETH, collateral, address(this));
        uint256 paid = _exitSale(got);
        if (got > paid) {
            IERC20(WETH).approve(POOL, got - paid);
            IAavePool(POOL).supply(WETH, got - paid, address(this), 0);
        }
        _repay(type(uint256).max);
        if (_health() < hfBefore) revert HealthFell();
    }

    /// Amendment 2d §3.2: an exit sale of WETH, at pool prices no worse than the band's limit (a partial
    /// fill accepted: the rest waits for a later step), its average no worse than the oracle less
    /// `oracleBoundBp` on what was PAID. Refused while the pool is already at or below the limit.
    function _exitSale(uint256 amountIn) internal returns (uint256 paid) {
        (uint160 limit, uint256 pw, uint256 pu) = _bandLimit();
        if (_sqrtPrice(SWAP_POOL) <= limit) revert PoolOffOracle();
        uint256 out;
        (paid, out) = _poolSwap(true, amountIn, limit);
        uint256 valueIn = paid * pw / 1e18;
        if (out < paid * pw * 1e6 * (10_000 - oracleBoundBp) / (pu * 1e18 * 10_000)) revert SwapShort();
        uint256 valueOut = out * pu / 1e6;
        emit Swapped(true, paid, out, valueIn > valueOut ? valueIn - valueOut : 0);
    }


    // ── amendment 2c: the rewards path ─────────────────────────────────────────────────────────────────

    /// The execution key outside the exit; anyone in it (§3.6).
    modifier rewardCaller() {
        if (!exiting) _checkExecution();
        _;
    }

    /// AAVE's incentives on the leg's own tokens, to the leg (§3.3).
    function claimRewards() external delegated nonReentrant rewardCaller counted {
        uint256 before = _rewardHeld();
        address[] memory assets = new address[](4);
        assets[0] = A_WETH;
        assets[1] = A_USDC;
        assets[2] = VDEBT_USDC;
        assets[3] = A_REWARD;
        IRewardsController(REWARDS_CONTROLLER).claimAllRewardsToSelf(assets);
        emit RewardClaimed(1, _gained(before));
    }

    /// Merkl's cumulative `amounts` of `tokens` with their `proofs`, the leg the user and the recipient
    /// (§3.3): any token, since a campaign's wrapper can't be known in advance.
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

    /// Sells `amountIn` of the pinned reward (`type(uint256).max`: all it holds, aArbARB withdrawn) for
    /// USDC on the pinned pool, at no less than the feed's value less 1 % (§3.5).
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

    /// Turns aArbARB's collateral off when AAVE has it on (§3.4), on its own so that no failed sale undoes it.
    function rewardCollateralOff() external delegated nonReentrant rewardCaller counted {
        _collateralOff();
    }

    /// The rewards path's pins, for the engine and the review (§3.8).
    function rewardPins()
        external
        pure
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
        // amendment 2d §3.2, decision 67: in exit, a marginal limit at the feed's ARB price in USDC less
        // min(EXIT_BAND_BP, REWARD_BOUND_BP − the pool's fee), a partial fill accepted; outside the exit
        // the key's sale is unchanged
        uint160 limit = MIN_SQRT_RATIO_PLUS_ONE;
        if (exiting) {
            uint256 band = REWARD_BOUND_BP - REWARD_FEE_BP;
            limit = _limitAt(p, pu, band < EXIT_BAND_BP ? band : EXIT_BAND_BP);
            if (_sqrtPrice(REWARD_POOL) <= limit) revert PoolOffOracle();
        }
        _swapping = SWAP_REWARD;
        (int256 a0, int256 a1) = IUniswapV3Pool(REWARD_POOL).swap(address(this), true, int256(amountIn), limit, "");
        _swapping = 0;
        uint256 paid = uint256(a0);
        out = uint256(-a1);
        // the floor and the caller's minimum on what was paid in exit (a partial fill), on amountIn outside
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

    /// aArbARB to ARB; the health factor never lower (with aArbARB not collateral it can't move).
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

    /// The feed's latest price (8 decimals, AAVE's base), fresh within `REWARD_MAX_AGE`, the sequencer up.
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

    /// Whether the exit has reward work (§3.7), every read bounded: aArbARB's collateral flag (AAVE's
    /// pool), the two balances by capped staticcalls; a failed probe counts as nothing to do.
    function _rewardWork() internal view returns (bool) {
        if (_probeCollateral()) return true;
        // each clamped to the dust, so a token answering an absurd balance can't overflow the sum
        uint256 a = _probeBalance(REWARD);
        uint256 b = _probeBalance(A_REWARD);
        return (a < REWARD_DUST ? a : REWARD_DUST) + (b < REWARD_DUST ? b : REWARD_DUST) >= REWARD_DUST;
    }

    /// aArbARB's collateral flag, every read capped and failure-tolerant (Codex's code review: a pool whose
    /// `getReserveData` stops decoding must not block the exit); a failed read counts as off. The sale's
    /// own check (`_rewardCollateralOn`) stays strict, inside its isolated part.
    function _probeCollateral() internal view returns (bool on) {
        bytes memory data = abi.encodeCall(IAavePool.getReserveData, (REWARD));
        uint256 gasCap = REWARD_PROBE_GAS * 2;
        address pool = POOL;
        uint256 id;
        bool ok;
        assembly ("memory-safe") {
            // the reserve's id is the 8th word of the legacy layout
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

    // ── the leg's rarely called functions, here for size (amendment 2a §3.8) ─────────────────────────────

    /// Anyone, in every state: completes a Circle mint bound to this leg and counts it (§3.6).
    function receiveMint(bytes calldata message, bytes calldata attestation) external delegated nonReentrant {
        _receiveMint(message, attestation);
    }

    /// Anyone: this leg's report to its hub (§3.6, decision 45).
    function report() external delegated nonReentrant {
        _report();
    }

    /// The report's figures as a view, for a hub beside it (amendment 2b §3.4).
    function holdings()
        external
        view
        delegated
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool)
    {
        return _legView();
    }
}
