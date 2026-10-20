// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {ICoreWriter} from "../interfaces/Protocols.sol";

/*
 * HyperCore from HyperEVM: the read precompiles and CoreWriter's actions, with the encodings the mainnet
 * probe proved (spikes/hl-vault-probe, S0–S12; spec §5) and the precompile layouts read by `eth_call`.
 *
 * Units (measured 2026-10-14):
 * - perp sizes (`position.szi`) in 10^-szDecimals; perp prices (oracle, bbo) in 10^-(6 - szDecimals);
 * - spot prices (bbo) in 10^-(8 - szDecimals of the base); spot balances in the token's wei (8 decimals
 *   for USDC and HYPE);
 * - margin figures (withdrawable, margin summary) in USD × 1e6; CoreWriter 7's `ntl` likewise;
 * - an order's price and size in 1e8 × the human value.
 */
library HyperCore {
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    address internal constant PX_POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant PX_SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant PX_WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant PX_MARK = 0x0000000000000000000000000000000000000806;
    address internal constant PX_ORACLE = 0x0000000000000000000000000000000000000807;
    address internal constant PX_PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address internal constant PX_BBO = 0x000000000000000000000000000000000000080e;
    address internal constant PX_MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;
    address internal constant PX_CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;

    /// The spot "DEX" in `sendAsset`.
    uint32 internal constant SPOT_DEX = type(uint32).max;
    uint8 internal constant TIF_IOC = 3;

    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct SpotBalance {
        uint64 total; // in unified mode: the AVAILABLE amount (total - hold), hold 0 (§5)
        uint64 hold;
        uint64 entryNtl;
    }

    struct MarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    error PrecompileFailed(address precompile);

    /// The gas a non-reverting read may spend (a precompile read costs about 2,000 + 65 per byte, under
    /// 20,000): a precompile that fails may burn all it is given, and an uncapped call would leave the
    /// rest of the step 1/64 of its gas (the combined review's RR-1).
    uint256 internal constant READ_GAS = 100_000;

    // ── reads ────────────────────────────────────────────────────────────────────────────────────────

    function _read(address precompile, bytes memory input) private view returns (bytes memory out) {
        bool ok;
        (ok, out) = precompile.staticcall(input);
        if (!ok || out.length == 0) revert PrecompileFailed(precompile);
    }

    function position(address user, uint32 perp) internal view returns (Position memory) {
        return abi.decode(_read(PX_POSITION, abi.encode(user, uint16(perp))), (Position));
    }

    /// `position`, never reverting: false when the precompile fails (an unknown or delisted perp), so an
    /// exit can go on under its gate (the combined review's CR-X1).
    function tryPosition(address user, uint32 perp) internal view returns (bool ok, Position memory p) {
        bytes memory out;
        (ok, out) = PX_POSITION.staticcall{gas: READ_GAS}(abi.encode(user, uint16(perp)));
        if (!ok || out.length < 160) return (false, p);
        p = abi.decode(out, (Position));
    }

    function spotBalance(address user, uint64 token) internal view returns (SpotBalance memory) {
        return abi.decode(_read(PX_SPOT_BALANCE, abi.encode(user, token)), (SpotBalance));
    }

    /// What can move or be sold: total − hold.
    function spotAvailable(address user, uint64 token) internal view returns (uint64) {
        SpotBalance memory b = spotBalance(user, token);
        return b.total - b.hold;
    }

    function withdrawable(address user) internal view returns (uint64) {
        return abi.decode(_read(PX_WITHDRAWABLE, abi.encode(user)), (uint64));
    }

    /// A DEX 0 perp's mark price, the price `accountValue` holds its positions at (the fee-value probe,
    /// mainnet 2026-10-16: `rawUsd + szi × markPx == accountValue` to 1e-6 USD in both account modes).
    function markPx(uint32 perp) internal view returns (uint64) {
        return abi.decode(_read(PX_MARK, abi.encode(perp)), (uint64));
    }

    function oraclePx(uint32 perp) internal view returns (uint64) {
        return abi.decode(_read(PX_ORACLE, abi.encode(perp)), (uint64));
    }

    function perpSzDecimals(uint32 perp) internal view returns (uint8) {
        return abi.decode(_read(PX_PERP_ASSET_INFO, abi.encode(perp)), (PerpAssetInfo)).szDecimals;
    }

    /// The best bid and offer, or (0, 0) when the precompile refuses: the book only ever tightens a
    /// bound (decision 30), so a missing book leaves the bound as it is.
    function bbo(uint32 asset) internal view returns (uint64 bid, uint64 ask) {
        (bool ok, bytes memory out) = PX_BBO.staticcall{gas: READ_GAS}(abi.encode(asset));
        if (!ok || out.length < 64) return (0, 0);
        (bid, ask) = abi.decode(out, (uint64, uint64));
    }

    /// One perp DEX's summary for `user`; `ok` false when the precompile refuses the DEX.
    function marginSummary(uint32 dex, address user) internal view returns (bool ok, MarginSummary memory m) {
        bytes memory out;
        (ok, out) = PX_MARGIN_SUMMARY.staticcall{gas: READ_GAS}(abi.encode(dex, user));
        if (!ok || out.length < 128) return (false, m);
        m = abi.decode(out, (MarginSummary));
    }

    function coreUserExists(address user) internal view returns (bool) {
        return abi.decode(_read(PX_CORE_USER_EXISTS, abi.encode(user)), (bool));
    }

    // ── CoreWriter: version byte 1, a 3-byte action id, then the ABI-encoded fields ────────────────────

    function _send(uint24 id, bytes memory fields) private {
        ICoreWriter(CORE_WRITER).sendRawAction(abi.encodePacked(uint8(1), id, fields));
    }

    /// Action 1: an IOC limit order, no client id.
    function orderIoc(uint32 asset, bool isBuy, uint64 px, uint64 sz, bool reduceOnly) internal {
        _send(1, abi.encode(asset, isBuy, px, sz, reduceOnly, TIF_IOC, uint128(0)));
    }

    function spotSend(address to, uint64 token, uint64 amountWei) internal {
        _send(6, abi.encode(to, token, amountWei));
    }

    function usdClassTransfer(uint64 ntl, bool toPerp) internal {
        _send(7, abi.encode(ntl, toPerp));
    }

    function addApiWallet(address agent, string memory name) internal {
        _send(9, abi.encode(agent, name));
    }

    function cancelByOid(uint32 asset, uint64 oid) internal {
        _send(10, abi.encode(asset, oid));
    }

    function cancelByCloid(uint32 asset, uint128 cloid) internal {
        _send(11, abi.encode(asset, cloid));
    }

    /// Action 13: `sendAsset` (destination, sub-account none, source DEX, destination DEX, token, wei).
    function sendAsset(address to, uint32 srcDex, uint32 dstDex, uint64 token, uint64 amountWei) internal {
        _send(13, abi.encode(to, address(0), srcDex, dstDex, token, amountWei));
    }

    // ── prices ───────────────────────────────────────────────────────────────────────────────────────

    /// `px1e8` (1e8 × the human price) moved by `bp` against the trade (a buy pays more, a sale gets
    /// less), then rounded to a price Hyperliquid accepts — at most 5 significant figures (an integer
    /// price always) and at most `maxDecimals` decimals — in the direction that keeps the bound:
    /// down for a buy's ceiling, up for a sale's floor. An invalid price would be dropped silently (§5).
    function boundedPx(uint256 px1e8, uint256 bp, bool isBuy, uint256 maxDecimals) internal pure returns (uint64) {
        uint256 raw = isBuy ? px1e8 * (10_000 + bp) / 10_000 : px1e8 * (10_000 - bp) / 10_000;
        return roundPx(raw, maxDecimals, !isBuy);
    }

    function roundPx(uint256 px1e8, uint256 maxDecimals, bool up) internal pure returns (uint64) {
        uint256 step = 10 ** (8 - maxDecimals);
        uint256 digits;
        for (uint256 v = px1e8; v != 0; v /= 10) digits++;
        if (digits > 5) {
            uint256 sig = 10 ** (digits - 5);
            if (sig > 1e8) sig = 1e8; // an integer price is always accepted
            if (sig > step) step = sig;
        }
        uint256 r = px1e8 / step * step;
        if (up && r < px1e8) r += step;
        return uint64(r); // a zero price is refused by Hyperliquid: never a looser bound

    }
}
