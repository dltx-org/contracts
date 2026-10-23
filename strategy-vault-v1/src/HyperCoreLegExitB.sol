// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {HyperCoreLegState} from "./HyperCoreLegState.sol";
import {IDepositOwner, OwnerDomain} from "./interfaces/IDepositOwner.sol";
import {IERC20} from "./interfaces/Protocols.sol";
import {HyperCore} from "./lib/HyperCore.sol";
import {Holding, OwnerMessages} from "./lib/VaultTypes.sol";
import {AssetProfile, Profiles} from "./Types.sol";

/*
 * The Hyperliquid leg's EXIT MODULE, part B (version 0's `ShortVaultExit`, split for EIP-170:
 * asset-profiles-design.md §3.2): the owner's signed exit order, the residue sweep, `exitStatus`, the
 * profile's check on HyperEVM (AP-3), `receiveMint`, `report` and `holdings`, run only by DELEGATECALL
 * from an instance (`checkProfile` aside: a view the registry asks the implementation), in its storage.
 */
contract HyperCoreLegExitB is HyperCoreLegState {
    // ── the profile (AP-3) ────────────────────────────────────────────────────────────────────────────

    /// The short's part of a profile, checked on HyperEVM: a DEX 0 perp whose `perpAssetInfo` coin and
    /// szDecimals are the profile's, the underlying that coin, and the short's id derived from it, never
    /// chosen (`keccak256("dltx.asset." ‖ coin)`), so an ETH perp can never report as BTC.
    function checkProfile(AssetProfile calldata p) external view {
        if (p.perp >= SPOT_ASSET_OFFSET || p.perpCoin == bytes32(0)) revert BadProfile();
        (bool ok, bytes memory out) = HyperCore.PX_PERP_ASSET_INFO.staticcall(abi.encode(p.perp));
        if (!ok || out.length == 0) revert BadProfile();
        HyperCore.PerpAssetInfo memory info = abi.decode(out, (HyperCore.PerpAssetInfo));
        (bytes32 coin, bool fits) = Profiles.word(info.coin);
        if (
            !fits || coin != p.perpCoin || info.szDecimals != p.szDecimals || p.underlying != p.perpCoin
                || p.shortAsset != Profiles.assetOf(p.perpCoin)
        ) revert BadProfile();
    }

    /// The owner's signed order (decision 30), in exit: where no independent price exists (a HIP-3
    /// position, a spot token with no oracle) or the market won't fill within the oracle bound (an
    /// illiquid DEX 0 position). IOC at the owner's limit, which the on-chain best bid or offer ± the
    /// bound may only tighten; reduce-only on a perp. `asset` is Hyperliquid's: a DEX 0 perp (< 10,000),
    /// a spot market (10,000 + its index) or a HIP-3 perp (100,000 + 10,000 × DEX + index), whose DEX
    /// then joins the watched list; `szDecimals` is the asset's (no precompile serves a HIP-3 one).
    function ownerOrder(
        uint32 asset,
        bool isBuy,
        uint64 size,
        uint64 limitPx,
        uint8 szDecimals,
        bytes32 credential,
        uint256 deadline,
        bytes calldata signature
    ) external delegated nonReentrant inExit counted {
        bool spot = asset >= SPOT_ASSET_OFFSET && asset < HIP3_ASSET_OFFSET;
        // a spot order SELLS only: a buy could spend the vault's USDC on a token whose only ask is a
        // thief's; a perp order is reduce-only
        if (
            (asset >= HIP3_ASSET_OFFSET && asset < HIP3_ASSET_OFFSET + 10_000) || szDecimals > (spot ? 8 : 6)
                || (spot && isBuy)
        ) revert BadAsset();
        _checkOwnerAs(
            credential,
            keccak256(
                abi.encode(
                    OwnerMessages.OWNER_ORDER_TYPEHASH,
                    address(this),
                    block.chainid,
                    asset,
                    isBuy,
                    size,
                    limitPx,
                    szDecimals,
                    ownerNonceOf[credential],
                    deadline
                )
            ),
            deadline,
            signature
        );
        if (asset >= HIP3_ASSET_OFFSET) _watch((asset - HIP3_ASSET_OFFSET) / 10_000, true);
        (uint64 bid, uint64 ask) = HyperCore.bbo(asset);
        // the book's price in 1e8: perps carry 6 − szDecimals decimals, spot 8 − szDecimals
        uint256 scale = 10 ** (spot ? szDecimals : 2 + szDecimals);
        uint256 maxDecimals = (spot ? 8 : 6) - szDecimals;
        uint64 px = limitPx;
        if (isBuy && ask > 0) {
            uint64 t = HyperCore.boundedPx(ask * scale, orderBoundBp, true, maxDecimals);
            if (t < px) px = t;
        } else if (!isBuy && bid > 0) {
            uint64 t = HyperCore.boundedPx(bid * scale, orderBoundBp, false, maxDecimals);
            if (t > px) px = t;
        }
        HyperCore.orderIoc(asset, isBuy, px, size, !spot);
    }

    /// Starts the 24 hours an owner wallet credential must stand before the residue may be swept to it
    /// (§8.4). The deposit account does not record when a credential joined its copy, so the vault
    /// observes it itself: from the first call here naming `to` while `to` is a wallet credential in
    /// this chain's copy. Anyone, in exit; a later call for the same address changes nothing.
    function proposeSweep(address to) external delegated inExit {
        if (!_isOwnerWallet(to)) revert NotOwnerWallet();
        if (sweepSince[to] == 0) sweepSince[to] = uint64(block.timestamp);
    }

    /// The residue sweep (§8.4): not a withdrawal authority. Only in "recovered with residue", never
    /// USDC, at most the residue listed for `token`, only to an owner wallet credential that has stood
    /// 24 hours in this chain's copy of the record (seen by `proposeSweep`) and still stands. Anyone.
    function sweepResidue(uint64 token, address to) external delegated nonReentrant inExit counted {
        (uint8 state, uint64[PINNED] memory residue,) = _status();
        if (state != RECOVERED_WITH_RESIDUE) revert NotResidue();
        uint256 i = _pinnedIndex(token);
        if (i == type(uint256).max || residue[i] == 0) revert BadAsset();
        uint256 since = sweepSince[to];
        if (since == 0 || block.timestamp < since + WALLET_STANDING || !_isOwnerWallet(to)) revert NotOwnerWallet();
        if (!_due(K_SWEEP, token, 0)) revert TooEarly();
        HyperCore.spotSend(to, token, residue[i]);
    }

    function _isOwnerWallet(address to) internal view returns (bool) {
        return to != address(0) && IDepositOwner(owner).isCredential(OwnerDomain.wallet(to));
    }

    /// The exit's status from reads only (§8.4): `state` (NOT_IN_EXIT, CLOSING, RECOVERED,
    /// RECOVERED_WITH_RESIDUE), the watched HIP-3 DEXes (DEX 0 is always watched), the residue per
    /// pinned token (HYPE, USDE, USDT0, USDH; HYPE above its fee reserve), and the `F_*` flags.
    function exitStatus()
        external
        view
        delegated
        returns (uint8 state, uint32[] memory dexes, uint64[4] memory residue, uint256 flags)
    {
        dexes = _dexes;
        if (exiting) (state, residue, flags) = _status();
        if (!_ownerSynced()) flags |= F_OWNER_UNSYNCED;
    }

    /// closing / recovered / recovered with residue, the residue per pinned token, and the flags.
    function _status() internal view returns (uint8 state, uint64[PINNED] memory residue, uint256 flags) {
        State memory s = _read();
        bool closing = !s.gate || s.budgetMode || s.wd > 0 || s.value0 > DUST_VALUE || s.spotUsdcTotal >= DUST_USDC
            || IERC20(USDC).balanceOf(address(this)) > 0;
        for (uint256 i; i < _dexes.length; ++i) {
            if (s.ok[i] && s.ms[i].accountValue > DUST_VALUE) closing = true;
        }
        bool any;
        for (uint256 i; i < PINNED; ++i) {
            (uint64 token,) = _pinned(i);
            uint64 bal = i == 0 ? s.spotHype : HyperCore.spotAvailable(address(this), token);
            uint64 held = i == 0 ? (bal > HYPE_FEE_RESERVE ? bal - HYPE_FEE_RESERVE : 0) : bal;
            uint256 px = i == 0 ? s.hypePx : 1e8;
            uint256 value = uint256(held) * px / 1e8; // Core wei of USDC (both 8 dp)
            uint256 saleValue = uint256(held / STEP_WEI) * HyperCore.boundedPx(px, orderBoundBp, false, 6) / 100;
            if (saleValue >= SALE_MIN_USDC) closing = true;
            if (value >= DUST_USDC) {
                residue[i] = held;
                any = true;
            }
        }
        if (toldPending != 0) flags |= F_PARTNER_PENDING;
        if (s.budgetMode) flags |= F_BUDGET;
        if (s.waitingOwner) flags |= F_WAITING_OWNER;
        if (s.gate && s.spotHype < HYPE_FEE_RESERVE && s.spotUsdc >= DUST_USDC) {
            // no purchase can happen: three made, none placeable, the spot or the budget too small (CR-D2)
            (,, uint64 cost) = _purchase(s.hypePx);
            if (
                purchases >= MAX_PURCHASES || cost == 0 || cost > s.spotUsdc
                    || (s.budgetMode && floorSet && s.spotUsdc < floor + reserved + cost)
            ) flags |= F_NEEDS_HYPE;
        }
        if (s.gate && s.wd == 0 && s.value0 > DUST_VALUE) flags |= F_MARGIN_HELD;
        state = closing ? CLOSING : (any ? RECOVERED_WITH_RESIDUE : RECOVERED);
    }

    /// The owner's copy here answers `synced()`; anything else (an old account, a revert) reads as not.
    function _ownerSynced() internal view returns (bool) {
        (bool ok, bytes memory out) = owner.staticcall(abi.encodeCall(IDepositOwner.synced, ()));
        return ok && out.length >= 32 && abi.decode(out, (bool));
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

    /// The report's figures as a view (amendment 2b §3.4); `tracked` false: the agent trades the account
    /// unseen by this contract, so a hub on HyperEVM can't prove the position steady (`UntrackedLeg`).
    function holdings()
        external
        view
        delegated
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool)
    {
        return _legView();
    }
}
