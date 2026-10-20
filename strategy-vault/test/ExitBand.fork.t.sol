// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {LongVault} from "../src/LongVault.sol";
import {LongVaultExit} from "../src/LongVaultExit.sol";
import {LongVaultState} from "../src/LongVaultState.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {StrategyHubFee} from "../src/StrategyHubFee.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {FeePins} from "../src/lib/FeePins.sol";
import {
    Assets,
    HubParams,
    LegConfig,
    Legs,
    LongParams,
    OwnerMessages,
    ParamsTypes,
    ShortParams,
    StrategyConfig
} from "../src/lib/VaultTypes.sol";
import {MockOwner} from "./mocks/Mocks.sol";
import {IERC20x, IFiatToken, IPoolx} from "./LongVault.fork.t.sol";

interface IUniV3 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IAaveOracleX {
    function getAssetPrice(address) external view returns (uint256);
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IVirtual {
    function getVirtualUnderlyingBalance(address) external view returns (uint128);
}

/// Moves a Uniswap V3 pool to a price, as a sandwich's front and back run do: an exact-input swap of more
/// than enough, stopped at `target`.
contract PoolPusher {
    function push(address pool, bool zeroForOne, uint160 target) external {
        IUniV3(pool).swap(address(this), zeroForOne, type(int128).max, target, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20x(IUniV3(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20x(IUniV3(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }
}

/*
 * Amendment 2d on an Arbitrum fork (spec §11): the exit's sales held to a band around AAVE's oracle at the
 * margin (§3.2), parts 3 to 7 and 10 (§3.2, §5.2, §5.3), the hub's routing of its cash to the AAVE leg's
 * debt (§5.2) at C4's default sizing, the failure boundaries of the hub's step, the reward sale in exit.
 * The real AAVE V3 pool and oracle, the pinned Uniswap pools, the deployed receiver, Circle's USDC. A crash
 * is played by AAVE's oracle mocked down and the pool pushed. SKIPPED when ARBITRUM_RPC_URL is not set.
 */
contract ExitBandForkTest is Test {
    uint256 constant PINNED_BLOCK = 514_790_000; // 2026-10-14, as the leg's fork suite
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    bytes32 constant STRATEGY = keccak256("strategy-2d");
    bytes32 constant SWAPPED = keccak256("Swapped(bool,uint256,uint256,uint256)");
    bytes32 constant PART_FAILED = keccak256("ExitPartFailed(uint8,bytes)");
    bytes32 constant REWARD_SWAPPED = keccak256("RewardSwapped(uint256,uint256,uint256)");
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    bool forked;
    VaultRegistry registry;
    CombinationFactory factory;
    LongVault longCode;
    ShortVault shortCode;
    MockOwner owner;
    LongVault vault;
    StrategyHub hub;
    PoolPusher pusher;
    address recovery = makeAddr("recovery");
    address key = makeAddr("group-key");
    address stranger = makeAddr("stranger");
    address withdrawalTo = makeAddr("withdrawal-address");
    uint256 walletPk;
    address wallet;

    IERC20x weth = IERC20x(Arbitrum.WETH);
    IERC20x usdc = IERC20x(Arbitrum.USDC);
    IPoolx pool = IPoolx(Arbitrum.POOL);
    IUniV3 uni = IUniV3(Arbitrum.SWAP_POOL);

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, vm.envOr("ARBITRUM_FORK_BLOCK", PINNED_BLOCK));
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        forked = true;
        (wallet, walletPk) = makeAddrAndKey("owner-wallet");
        owner = new MockOwner();
        owner.setWallet(wallet, true);
        owner.setWithdrawalAddress(withdrawalTo);
        registry = new VaultRegistry(recovery);
        vm.prank(recovery);
        registry.setExecutionKey(1, key);
        LongVaultExit longExit = new LongVaultExit();
        longCode = new LongVault(address(longExit), address(longExit).codehash);
        ShortVaultExit shortExit = new ShortVaultExit();
        shortCode = new ShortVault(address(shortExit), address(shortExit).codehash);
        StrategyHubFee hubFee = new StrategyHubFee();
        StrategyHub hubCode = new StrategyHub(address(hubFee), address(hubFee).codehash);
        CombinationFactory.LegPin[] memory pins = new CombinationFactory.LegPin[](2);
        pins[0] = CombinationFactory.LegPin(
            address(longCode), address(longCode).codehash, 3, Legs.LONG, Legs.VALUE_READ,
            ParamsTypes.AAVE_V3_NAME, ParamsTypes.AAVE_V3_FIELDS, ParamsTypes.AAVE_V3_COUNT
        );
        pins[1] = CombinationFactory.LegPin(
            address(shortCode), address(shortCode).codehash, 19, Legs.SHORT, Legs.VALUE_READ,
            ParamsTypes.HYPERCORE_NAME, ParamsTypes.HYPERCORE_FIELDS, ParamsTypes.HYPERCORE_COUNT
        );
        uint32[] memory hubDomains = new uint32[](1);
        hubDomains[0] = 3;
        factory = new CombinationFactory(
            address(registry), address(hubCode), address(hubCode).codehash, ParamsTypes.HUB_NAME,
            ParamsTypes.HUB_FIELDS, ParamsTypes.HUB_COUNT, hubDomains, pins, FeePins.prices(), FeePins.sequencers()
        );
        vault = _create(STRATEGY, 300);
        hub = StrategyHub(vault.links(0));
        pusher = new PoolPusher();
        deal(Arbitrum.WETH, address(pusher), 100_000e18);
        deal(Arbitrum.USDC, address(pusher), 300_000_000e6);
        deal(ARB, address(pusher), 1_000_000_000e18);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    /// DLTX's defaults (`oracleBoundBp` 300, a 1.05 floor) or the bound `oracleBoundBp`.
    function _config(uint16 oracleBoundBp) internal view returns (StrategyConfig memory c) {
        c.factory = address(factory);
        c.group = 1;
        c.hubDomain = 3;
        c.hubParams = abi.encode(HubParams({fastFeeCapBp: 5, feeBudgetBp: 50, feeRateBp: 1500}));
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(
            address(longCode),
            3,
            Legs.LONG,
            abi.encode(
                LongParams({
                    pool: Arbitrum.POOL,
                    oracle: Arbitrum.ORACLE,
                    weth: Arbitrum.WETH,
                    usdc: Arbitrum.USDC,
                    swapPool: Arbitrum.SWAP_POOL,
                    receiver: Arbitrum.RECEIVER,
                    healthFloor: 1.05e18,
                    oracleBoundBp: oracleBoundBp,
                    dailyLossBp: 500,
                    fastFeeCapBp: 5
                })
            )
        );
        c.legs[1] = LegConfig(
            address(shortCode), 19, Legs.SHORT, abi.encode(ShortParams({perp: 1, asset: Assets.ETH, orderBoundBp: 500, fastFeeCapBp: 0, feeBudgetBp: 50}))
        );
    }

    function _create(bytes32 id, uint16 oracleBoundBp) internal returns (LongVault v) {
        StrategyConfig memory c = _config(oracleBoundBp);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(walletPk, factory.createDigest(id, address(owner), c, deadline));
        address[] memory made = factory.create(id, address(owner), c, deadline, abi.encodePacked(uint8(1), r, s, sv));
        v = LongVault(payable(made[1]));
        // the Hyperliquid leg's finalized READY, to both members here
        for (uint256 i; i < 2; ++i) {
            VaultBase m = VaultBase(made[i]);
            bytes32 hl = bytes32(uint256(uint160(m.links(1))));
            vm.prank(TRANSMITTER);
            m.handleReceiveFinalizedMessage(19, hl, 2000, abi.encode(keccak256("dltx.strategy-vault.ready.v1")));
        }
    }

    function _beginExit(VaultBase v, bytes32 id) internal {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(
            walletPk,
            keccak256(
                abi.encodePacked(
                    hex"1901", owner.domainSeparator(), keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, id, deadline))
                )
            )
        );
        v.beginExit(deadline, abi.encodePacked(uint8(1), r, s, sv));
    }

    function _usdc(address to, uint256 amount) internal {
        vm.prank(Arbitrum.A_USDC); // the aToken holds the reserve's USDC
        usdc.transfer(to, amount);
    }

    function _health(address a) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(a);
    }

    function _debt(address a) internal view returns (uint256) {
        return IERC20x(Arbitrum.VDEBT_USDC).balanceOf(a);
    }

    function _pw() internal view returns (uint256) {
        return IAaveOracleX(Arbitrum.ORACLE).getAssetPrice(Arbitrum.WETH);
    }

    function _pu() internal view returns (uint256) {
        return IAaveOracleX(Arbitrum.ORACLE).getAssetPrice(Arbitrum.USDC);
    }

    function _sqrt() internal view returns (uint160 p) {
        (p,,,,,,) = uni.slot0();
    }

    /// The pool price, as `sqrtPriceX96`, at AAVE's oracle less `bandBp` (an independent copy of the leg's).
    function _at(uint256 bandBp) internal view returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(_pw() * (10_000 - bandBp), 1 << 192, _pu() * 1e16)));
    }

    /// Pushes the WETH/USDC pool to `target` (down: selling WETH; up: buying it).
    function _poolTo(uint160 target) internal {
        pusher.push(address(uni), target < _sqrt(), target);
    }

    /// `bp` below AAVE's oracle (negative: above).
    function _poolAtOracleLess(int256 bp) internal {
        _poolTo(uint160(Math.sqrt(Math.mulDiv(_pw() * uint256(10_000 - bp), 1 << 192, _pu() * 1e16))));
    }

    /// An unlevered leg of `amount` WETH supplied, in exit.
    function _unlevered(LongVault v, uint256 amount, bytes32 id) internal {
        deal(Arbitrum.WETH, address(v), amount);
        vm.prank(key);
        v.supply(amount);
        _beginExit(v, id);
    }

    /// Every sale the leg logged in `logs`: (paid, out), WETH in, USDC out.
    function _sales(Vm.Log[] memory logs, address v) internal pure returns (uint256 paid, uint256 out, uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != v || logs[i].topics[0] != SWAPPED) continue;
            (bool wethToUsdc, uint256 p, uint256 o,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            if (!wethToUsdc) continue;
            paid += p;
            out += o;
            ++n;
        }
    }

    /// Whether part `part` failed in `logs` with exactly `err`.
    function _failed(Vm.Log[] memory logs, address v, uint8 part, bytes4 err) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != v || logs[i].topics[0] != PART_FAILED) continue;
            (uint8 p, bytes memory reason) = abi.decode(logs[i].data, (uint8, bytes));
            if (p == part && reason.length >= 4 && bytes4(reason) == err) return true;
        }
        return false;
    }

    /// Whether part `part` failed in `logs`, for any reason.
    function _anyFail(Vm.Log[] memory logs, address v, uint8 part) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != v || logs[i].topics[0] != PART_FAILED) continue;
            (uint8 p,) = abi.decode(logs[i].data, (uint8, bytes));
            if (p == part) return true;
        }
        return false;
    }

    /// `out` USDC for `paid` WETH is no worse than AAVE's oracle less `bp`.
    function _noWorseThan(uint256 paid, uint256 out, uint256 bp) internal view returns (bool) {
        return out * _pu() * 1e18 * 10_000 >= paid * _pw() * 1e6 * (10_000 - bp);
    }

    // ── the band (§3.2) ──────────────────────────────────────────────────────────────────────────────

    /// AAVE 3.1+: the reserve's virtual balance, read by parts 4, 5 and 10.
    function test_fork_2d_aaveHasTheVirtualBalance() public onFork {
        uint256 w = IVirtual(Arbitrum.POOL).getVirtualUnderlyingBalance(Arbitrum.WETH);
        uint256 u = IVirtual(Arbitrum.POOL).getVirtualUnderlyingBalance(Arbitrum.USDC);
        emit log_named_uint("WETH reserve available (WETH)", w / 1e18);
        emit log_named_uint("USDC reserve available (USDC)", u / 1e6);
        assertGt(w, 1_000e18);
        assertGt(u, 1_000_000e6);
    }

    /// The sandwich (§3.1, §11): the attacker pushes the pool, steps the exit, buys back, and repeats, on
    /// one leg and then on a batch. Past the band the leg sells nothing (`PoolOffOracle`); inside it every
    /// fill is at or above the limit, so each WETH sold returns at least the oracle less the band and the
    /// pool's fee, whatever the rounds. (Today's code, measured in §3.1 with QuoterV2, sold to the floor:
    /// about 2.2 % of a $1M exit.)
    function test_fork_2d_sandwich_boundedPerUnitSold() public onFork {
        LongVault other = _create(keccak256("strategy-2d-batch"), 300);
        _unlevered(vault, 300e18, STRATEGY);
        _unlevered(other, 300e18, keccak256("strategy-2d-batch"));
        uint160 start = _sqrt();
        uint160 limit = _at(50);
        // pushed past the band: nothing sold, on either leg
        _poolTo(_at(80));
        vm.recordLogs();
        vm.startPrank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        LongVaultExit(address(other)).exitStep(0, 0);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_failed(logs, address(vault), 6, LongVaultState.PoolOffOracle.selector), "PoolOffOracle");
        assertTrue(_failed(logs, address(other), 6, LongVaultState.PoolOffOracle.selector));
        assertApproxEqAbs(weth.balanceOf(address(vault)), 300e18, 2, "withdrawn, not sold");
        assertApproxEqAbs(weth.balanceOf(address(other)), 300e18, 2);
        // rounds of push to just inside the band, step both legs, buy back
        uint256 paid;
        uint256 out;
        for (uint256 round; round < 4; ++round) {
            _poolTo(_at(45));
            vm.recordLogs();
            vm.startPrank(stranger);
            LongVaultExit(address(vault)).exitStep(0, 0);
            LongVaultExit(address(other)).exitStep(0, 0);
            vm.stopPrank();
            Vm.Log[] memory got = vm.getRecordedLogs();
            (uint256 p, uint256 o,) = _sales(got, address(vault));
            (uint256 p2, uint256 o2,) = _sales(got, address(other));
            assertGe(_sqrt(), limit, "every fill at or above the limit");
            paid += p + p2;
            out += o + o2;
            _poolTo(start); // the back run
        }
        assertGt(paid, 0);
        assertTrue(_noWorseThan(paid, out, 55), "no worse than the oracle less 50 bp and the fee, per WETH sold");
        emit log_named_uint("WETH sold over the rounds", paid / 1e16);
        uint256 fair = paid * _pw() * 1e6 / 1e18 / _pu();
        emit log_named_uint("average below AAVE's oracle, bp x 100", fair > out ? (fair - out) * 1e6 / fair : 0);
    }

    /// Part 6 larger than the band holds: a partial fill to the limit, the floor on what was PAID, the
    /// rest sold by a later step once the pool is back.
    function test_fork_2d_part6_partialFill_restLater() public onFork {
        _unlevered(vault, 400e18, STRATEGY);
        uint160 start = _sqrt();
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        (uint256 paid, uint256 out,) = _sales(vm.getRecordedLogs(), address(vault));
        uint256 left = weth.balanceOf(address(vault));
        assertGt(left, 0, "a partial fill: the band held part of it");
        assertApproxEqAbs(paid + left, 400e18, 2);
        assertEq(_sqrt(), _at(50), "stopped at the limit");
        assertTrue(_noWorseThan(paid, out, 55));
        emit log_named_uint("sold in one step at the band (WETH)", paid / 1e18);
        // the pool restored by arbitrage: the next step sells more, until none is left
        for (uint256 i; i < 6 && weth.balanceOf(address(vault)) > 0; ++i) {
            _poolTo(start);
            vm.prank(stranger);
            LongVaultExit(address(vault)).exitStep(0, 0);
        }
        assertEq(weth.balanceOf(address(vault)), 0);
        assertGt(usdc.balanceOf(address(hub)), 0, "the USDC to the hub");
    }

    /// The band clamp: an owner who signed `oracleBoundBp` 30 sells inside a 25 bp band, and a partial
    /// fill never reverts `SwapShort` against the floor at 30.
    function test_fork_2d_bandClamp_signedBound30() public onFork {
        bytes32 id = keccak256("strategy-2d-30");
        LongVault tight = _create(id, 30);
        _unlevered(tight, 400e18, id);
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(tight)).exitStep(0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 paid, uint256 out,) = _sales(logs, address(tight));
        assertFalse(_failed(logs, address(tight), 6, LongVaultState.SwapShort.selector));
        assertGt(paid, 0);
        assertGt(weth.balanceOf(address(tight)), 0, "partial");
        assertEq(_sqrt(), _at(25), "the band narrowed to 25 bp");
        assertTrue(_noWorseThan(paid, out, 30));
    }

    // ── part 3: the atomic repay checked by the pool's price before and after (§3.2) ─────────────────────

    /// A deep levered position: 600 WETH, about half its value borrowed and taken out.
    function _deep(LongVault v) internal {
        deal(Arbitrum.WETH, address(v), 600e18);
        vm.startPrank(key);
        v.supply(600e18);
        uint256 borrow = 600 * _pw() / 1e2 / 2; // half the collateral's value, in USDC units (pw 8 dp)
        v.borrow(borrow);
        vm.stopPrank();
        vm.prank(address(v));
        usdc.transfer(stranger, borrow);
    }

    function test_fork_2d_part3_bandCrossed_revertsWhole_withinItRepays() public onFork {
        _deep(vault);
        _beginExit(vault, STRATEGY);
        uint256 debt = _debt(address(vault));
        uint256 coll = IERC20x(Arbitrum.A_WETH).balanceOf(address(vault));
        // the whole debt at once is far more than the band holds: part 3 refused whole, nothing moved (part
        // 4 held to nothing: no WETH available to it)
        vm.mockCall(
            Arbitrum.POOL, abi.encodeCall(IVirtual.getVirtualUnderlyingBalance, (Arbitrum.WETH)), abi.encode(uint128(0))
        );
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        vm.clearMockedCalls();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_failed(logs, address(vault), 3, LongVaultState.BandCrossed.selector), "BandCrossed");
        assertEq(_debt(address(vault)), debt, "nothing repaid");
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), coll, "nothing moved");
        // a chunk the band holds goes through
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(50_000e6, 0);
        assertLt(_debt(address(vault)), debt - 49_000e6);
        assertGe(_sqrt(), _at(50));
        // the pool already off the oracle: PoolOffOracle, before the receiver is called
        _poolTo(_at(60));
        debt = _debt(address(vault));
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(10_000e6, 0);
        logs = vm.getRecordedLogs();
        assertTrue(_failed(logs, address(vault), 3, LongVaultState.PoolOffOracle.selector));
        assertTrue(_failed(logs, address(vault), 4, LongVaultState.PoolOffOracle.selector));
    }

    // ── part 4: capped at AAVE's headroom and its liquidity, the unsold WETH supplied back (§3.2) ────────

    /// `exitStep(0, 0)` with no flash liquidity (the escape hatch's call) frees debt every step until the
    /// debt is gone: each withdrawal within AAVE's headroom, each sale within the band.
    function test_fork_2d_part4_headroom_progressesEveryStep() public onFork {
        deal(Arbitrum.WETH, address(vault), 10e18);
        vm.startPrank(key);
        vault.supply(10e18);
        uint256 borrow = 10 * _pw() * 672 / 1e2 / 1_000; // 67.2 % of the value: health factor 1.25
        vault.borrow(borrow);
        vm.stopPrank();
        vm.prank(address(vault));
        usdc.transfer(stranger, borrow);
        vm.mockCallRevert(Arbitrum.RECEIVER, bytes(""), bytes("no flash liquidity"));
        _beginExit(vault, STRATEGY);
        uint256 debt = _debt(address(vault));
        uint256 steps;
        while (_debt(address(vault)) > 0 && steps < 30) {
            uint256 hf = _health(address(vault));
            vm.prank(stranger);
            LongVaultExit(address(vault)).exitStep(0, 0);
            uint256 now_ = _debt(address(vault));
            assertLt(now_, debt, "every step frees some debt");
            if (now_ > 0) assertGe(_health(address(vault)), hf, "never a lower health factor");
            debt = now_;
            ++steps;
        }
        emit log_named_uint("steps to repay a 1.25 health factor's debt by sales alone", steps);
        assertEq(_debt(address(vault)), 0);
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0);
    }

    /// Part 4 with lower-threshold collateral supplied on the leg's behalf by anyone (USDC, 78 % against
    /// WETH's 84 %): the cap stays within what AAVE lets go, so the fallback still progresses (Codex's
    /// code review: a cap from the account's average threshold withdrew more than AAVE allows, and the
    /// part reverted every step).
    function test_fork_2d_part4_mixedCollateral_stillProgresses() public onFork {
        uint256 value = 4 * _pw() / 1e2; // 4 WETH, in USDC units
        deal(Arbitrum.WETH, address(vault), 4e18);
        vm.prank(key);
        vault.supply(4e18);
        _usdc(stranger, value);
        vm.startPrank(stranger);
        usdc.approve(Arbitrum.POOL, value);
        pool.supply(Arbitrum.USDC, value, address(vault), 0); // anyone may: collateral on the leg's behalf
        vm.stopPrank();
        (uint256 c,,, uint256 lt,,) = pool.getUserAccountData(address(vault));
        uint256 borrow = c * lt / 10_000 * 100 / 125 / 100; // a health factor of 1.25, in USDC units (base 8 dp)
        vm.prank(key);
        vault.borrow(borrow);
        vm.prank(address(vault));
        usdc.transfer(stranger, borrow);
        emit log_named_uint("the account's average liquidation threshold (bp)", lt);
        vm.mockCallRevert(Arbitrum.RECEIVER, bytes(""), bytes("no flash liquidity"));
        vm.mockCallRevert(Arbitrum.POOL, abi.encodeWithSelector(bytes4(keccak256("repayWithATokens(address,uint256,uint256)"))), bytes("held"));
        _beginExit(vault, STRATEGY);
        uint256 debt = _debt(address(vault));
        uint256 hf = _health(address(vault));
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertFalse(_anyFail(vm.getRecordedLogs(), address(vault), 4), "part 4 within AAVE's limit");
        assertLt(_debt(address(vault)), debt, "debt freed");
        assertGe(_health(address(vault)), hf);
    }

    /// Part 4 capped at the reserve's WETH (0.1 WETH available, debt left): it repays from what it can
    /// withdraw.
    function test_fork_2d_part4_cappedAtTheReserve() public onFork {
        deal(Arbitrum.WETH, address(vault), 3e18);
        vm.startPrank(key);
        vault.supply(3e18);
        vault.borrow(3_000e6);
        vm.stopPrank();
        vm.prank(address(vault));
        usdc.transfer(stranger, 3_000e6);
        vm.mockCallRevert(Arbitrum.RECEIVER, bytes(""), bytes("no flash liquidity"));
        vm.mockCall(
            Arbitrum.POOL,
            abi.encodeCall(IVirtual.getVirtualUnderlyingBalance, (Arbitrum.WETH)),
            abi.encode(uint128(0.1e18))
        );
        _beginExit(vault, STRATEGY);
        uint256 coll = IERC20x(Arbitrum.A_WETH).balanceOf(address(vault));
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertApproxEqAbs(coll - IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0.1e18, 2, "0.1 WETH out");
        uint256 repaid = 3_000e6 - _debt(address(vault));
        assertApproxEqRel(repaid, 0.1e18 * _pw() / _pu() / 1e12, 0.01e18, "repaid with its sale");
        // none available: part 4 does nothing, and fails nothing
        vm.mockCall(
            Arbitrum.POOL, abi.encodeCall(IVirtual.getVirtualUnderlyingBalance, (Arbitrum.WETH)), abi.encode(uint128(0))
        );
        uint256 debt = _debt(address(vault));
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertFalse(_anyFail(vm.getRecordedLogs(), address(vault), 4), "nothing to do is no failure");
        assertGe(_debt(address(vault)), debt);
    }

    /// The fallback's sale partly filled by the band: the unsold WETH is supplied back, the health factor
    /// not lower; a supply refused (a cap) reverts the part whole.
    function test_fork_2d_part4_suppliesBackTheUnsold() public onFork {
        _deep(vault);
        vm.mockCallRevert(Arbitrum.RECEIVER, bytes(""), bytes("no flash liquidity"));
        _beginExit(vault, STRATEGY);
        _poolTo(_at(40)); // the band holds only about 10 bp of depth
        uint256 coll = IERC20x(Arbitrum.A_WETH).balanceOf(address(vault));
        uint256 debt = _debt(address(vault));
        uint256 hf = _health(address(vault));
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        (uint256 paid,,) = _sales(vm.getRecordedLogs(), address(vault));
        assertGt(paid, 0);
        assertEq(weth.balanceOf(address(vault)), 0, "nothing idle: the unsold WETH back in AAVE");
        assertApproxEqAbs(coll - IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), paid, 10, "only the sold WETH left");
        assertLt(_debt(address(vault)), debt);
        assertGe(_health(address(vault)), hf);
        // the supply refused: the whole part rolls back
        _poolTo(_at(40));
        coll = IERC20x(Arbitrum.A_WETH).balanceOf(address(vault));
        debt = _debt(address(vault));
        vm.mockCallRevert(Arbitrum.POOL, abi.encodeWithSelector(IPoolx.supply.selector), bytes("supply cap"));
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertTrue(_anyFail(vm.getRecordedLogs(), address(vault), 4));
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), coll, "nothing withdrawn");
        assertEq(_debt(address(vault)), debt, "nothing repaid");
    }

    // ── parts 5 and 10 (§5.3) ────────────────────────────────────────────────────────────────────────

    /// A paused USDC reserve no longer holds the WETH back: a debt-free leg with aWETH and a donated aUSDC
    /// withdraws its WETH (part 5) while its aUSDC waits (part 10).
    function test_fork_2d_part5_part10_apart() public onFork {
        deal(Arbitrum.WETH, address(vault), 1e18);
        vm.prank(key);
        vault.supply(1e18);
        _usdc(stranger, 500e6);
        vm.startPrank(stranger);
        usdc.approve(Arbitrum.POOL, 500e6);
        pool.supply(Arbitrum.USDC, 500e6, address(vault), 0);
        vm.stopPrank();
        vm.mockCallRevert(
            Arbitrum.POOL,
            abi.encodeCall(IPoolx.withdraw, (Arbitrum.USDC, type(uint256).max, address(vault))),
            bytes("reserve paused")
        );
        _beginExit(vault, STRATEGY);
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertTrue(_anyFail(vm.getRecordedLogs(), address(vault), 10), "the aUSDC's part failed alone");
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0, "the WETH withdrawn");
        assertGt(IERC20x(Arbitrum.A_USDC).balanceOf(address(vault)), 499e6, "the aUSDC waits");
        assertGt(usdc.balanceOf(address(hub)), 0, "the WETH sold and sent");
        vm.clearMockedCalls();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.A_USDC).balanceOf(address(vault)), 0);
    }

    /// The WETH reserve borrowed to the limit: part 5 withdraws what is there, then the rest once
    /// liquidity returns.
    function test_fork_2d_part5_partialWithdrawal() public onFork {
        deal(Arbitrum.WETH, address(vault), 5e18);
        vm.prank(key);
        vault.supply(5e18);
        vm.mockCall(
            Arbitrum.POOL, abi.encodeCall(IVirtual.getVirtualUnderlyingBalance, (Arbitrum.WETH)), abi.encode(uint128(2e18))
        );
        _beginExit(vault, STRATEGY);
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertApproxEqAbs(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 3e18, 2, "2 of 5 withdrawn");
        vm.clearMockedCalls();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0, "the rest once liquidity returned");
    }

    // ── the routing (§5.2) ───────────────────────────────────────────────────────────────────────────

    /// C4's default sizing (per ETH: collateral 1, debt 67.2 % of its value, the short's margin 22.4 %;
    /// health factor 1.25), a crash of 10 % with the pool 2 % below AAVE's oracle: the short's cash (its
    /// margin and its gain) minted to the hub repays a third of the debt before any sale; the health
    /// factor goes from about 1.13 to about 2.17 (§5.2's table); the rest once the pool returns.
    function test_fork_2d_routing_defaultSizing_crash() public onFork {
        uint256 p0 = _pw();
        deal(Arbitrum.WETH, address(vault), 10e18);
        vm.startPrank(key);
        vault.supply(10e18);
        uint256 value = 10 * p0 / 1e2; // USDC units
        vault.borrow(value * 672 / 1_000);
        vm.stopPrank();
        vm.prank(address(vault));
        usdc.transfer(stranger, value * 672 / 1_000);
        assertApproxEqRel(_health(address(vault)), 1.25e18, 0.01e18);
        // the crash: AAVE's oracle 10 % down, the pool 2 % below it
        vm.mockCall(Arbitrum.ORACLE, abi.encodeCall(IAaveOracleX.getAssetPrice, (Arbitrum.WETH)), abi.encode(p0 * 9 / 10));
        _poolAtOracleLess(200);
        assertApproxEqRel(_health(address(vault)), 1.125e18, 0.01e18);
        // the short closed: its margin and its gain minted to the hub (§5.2: 22.4 % + 10 % of the value)
        _usdc(address(hub), value * 324 / 1_000);
        _beginExit(vault, STRATEGY);
        vm.prank(stranger);
        hub.exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), 0, "nothing to the owner while the debt is uncovered");
        assertEq(hub.sentTo(0), value * 324 / 1_000, "all of it to the leg");
        assertEq(vault.receivedFrom(0), value * 324 / 1_000);
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_failed(logs, address(vault), 3, LongVaultState.PoolOffOracle.selector), "no sale off the oracle");
        assertTrue(_failed(logs, address(vault), 4, LongVaultState.PoolOffOracle.selector));
        uint256 hf = _health(address(vault));
        emit log_named_uint("health factor after the routing (1e18)", hf);
        assertApproxEqRel(hf, 2.17e18, 0.02e18, "about 2.17: half the price away from liquidation");
        assertEq(usdc.balanceOf(address(vault)), 0);
        // a second hub step sends nothing: the leg's uncovered debt is its USDC-less debt, the hub has none
        vm.prank(stranger);
        hub.exitStep();
        assertEq(hub.sentTo(0), value * 324 / 1_000);
        // the pool back at the oracle: the rest unwinds, the owner is paid
        _poolTo(_at(0));
        for (uint256 i; i < 4 && (_debt(address(vault)) > 0 || weth.balanceOf(address(vault)) > 0); ++i) {
            vm.prank(stranger);
            LongVaultExit(address(vault)).exitStep(0, 0);
            _poolTo(_at(0));
        }
        assertEq(_debt(address(vault)), 0);
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        vm.prank(stranger);
        hub.exitStep();
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0);
        // 90 % of the value, less 67.2 % of debt, plus the 32.4 % routed: about 55 %, less the sales' costs
        assertGt(usdc.balanceOf(withdrawalTo), value * 545 / 1_000, "the strategy's value, paid");
    }

    /// Part 7 keeps USDC up to the debt (§5.2): with AAVE's USDC reserve refusing repayments (part 1
    /// failing), the hub routes once, the leg keeps it, `exitDebt()` reads zero, and the next hub step
    /// pays the owner the rest: no bounce. Repayments back, part 1 repays (a day's interest inside the
    /// headroom) and part 7 sends the remainder.
    function test_fork_2d_part7_keepsUpToTheDebt_noBounce() public onFork {
        deal(Arbitrum.WETH, address(vault), 3e18);
        vm.startPrank(key);
        vault.supply(3e18);
        vault.borrow(2_000e6);
        vm.stopPrank();
        vm.prank(address(vault));
        usdc.transfer(stranger, 2_000e6);
        _usdc(address(hub), 5_000e6);
        vm.mockCallRevert(Arbitrum.POOL, abi.encodeWithSelector(bytes4(keccak256("repay(address,uint256,uint256,address)"))), bytes("paused"));
        vm.mockCallRevert(Arbitrum.RECEIVER, bytes(""), bytes("paused"));
        vm.mockCallRevert(Arbitrum.POOL, abi.encodeWithSelector(IPoolx.withdraw.selector), bytes("paused"));
        _beginExit(vault, STRATEGY);
        uint256 owed = vault.exitDebt();
        uint256 debt = _debt(address(vault));
        assertEq(owed, debt + debt * 10 / 10_000 + 1e6, "the uncovered debt with its headroom");
        vm.prank(stranger);
        hub.exitStep();
        assertEq(usdc.balanceOf(address(vault)), owed);
        assertEq(usdc.balanceOf(withdrawalTo), 5_000e6 - owed);
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertEq(usdc.balanceOf(address(vault)), owed, "kept: it still repays the debt");
        assertEq(vault.exitDebt(), 0, "covered");
        vm.prank(stranger);
        hub.exitStep();
        assertEq(hub.sentTo(0), owed, "nothing routed twice");
        assertEq(usdc.balanceOf(withdrawalTo), 5_000e6 - owed);
        // a day later, repayments back
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.clearMockedCalls();
        assertGt(_debt(address(vault)), debt, "interest accrued");
        assertLe(_debt(address(vault)), owed, "inside the headroom");
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        assertEq(_debt(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0, "the remainder to the hub");
        vm.prank(stranger);
        hub.exitStep();
        assertGt(usdc.balanceOf(withdrawalTo), 5_000e6 - owed + 3 * _pw() / 1e2 * 98 / 100);
    }

    /// The failure boundaries (Codex round 2): a withdrawal address USDC refuses — the route stands, the
    /// payout and its fee accounting roll back, logged; a leg USDC refuses — the route rolls back, logged,
    /// the owner is paid; `exitDebt()` reverting — no route, the owner paid as before 2d.
    function test_fork_2d_failureBoundaries() public onFork {
        deal(Arbitrum.WETH, address(vault), 3e18);
        vm.startPrank(key);
        vault.supply(3e18);
        vault.borrow(1_000e6);
        vm.stopPrank();
        vm.prank(address(vault));
        usdc.transfer(stranger, 1_000e6);
        _usdc(address(hub), 5_000e6);
        IFiatToken fiat = IFiatToken(Arbitrum.USDC);
        vm.prank(fiat.blacklister());
        fiat.blacklist(withdrawalTo);
        vm.mockCallRevert(Arbitrum.POOL, abi.encodeWithSelector(bytes4(keccak256("repay(address,uint256,uint256,address)"))), bytes("paused"));
        _beginExit(vault, STRATEGY);
        uint256 owed = vault.exitDebt();
        vm.recordLogs();
        vm.prank(stranger);
        hub.exitStep();
        assertTrue(_emitted(vm.getRecordedLogs(), address(hub), keccak256("ExitSettleFailed(bytes)")));
        assertEq(usdc.balanceOf(address(vault)), owed, "the route stands");
        assertEq(hub.exitPaid(), 0);
        assertEq(hub.exitFeePaid(), 0);
        assertEq(usdc.balanceOf(address(hub)), 5_000e6 - owed, "the rest waits for a payable address");
        // a second strategy: its leg blacklisted
        bytes32 id = keccak256("strategy-2d-blk");
        LongVault other = _create(id, 300);
        StrategyHub otherHub = StrategyHub(other.links(0));
        owner.setWithdrawalAddress(makeAddr("payable"));
        deal(Arbitrum.WETH, address(other), 3e18);
        vm.startPrank(key);
        other.supply(3e18);
        other.borrow(1_000e6);
        vm.stopPrank();
        vm.prank(address(other));
        usdc.transfer(stranger, 1_000e6);
        _usdc(address(otherHub), 5_000e6);
        vm.prank(fiat.blacklister());
        fiat.blacklist(address(other));
        _beginExit(other, id);
        vm.recordLogs();
        vm.prank(stranger);
        otherHub.exitStep();
        assertTrue(_emitted(vm.getRecordedLogs(), address(otherHub), keccak256("ExitRouteFailed(uint8,bytes)")));
        assertEq(otherHub.sentTo(0), 0);
        assertEq(usdc.balanceOf(makeAddr("payable")), 5_000e6, "the owner paid");
        // a third: `exitDebt()` reverting reads as nothing owed
        bytes32 id3 = keccak256("strategy-2d-rev");
        LongVault third = _create(id3, 300);
        StrategyHub thirdHub = StrategyHub(third.links(0));
        deal(Arbitrum.WETH, address(third), 3e18);
        vm.startPrank(key);
        third.supply(3e18);
        third.borrow(1_000e6);
        vm.stopPrank();
        vm.prank(address(third));
        usdc.transfer(stranger, 1_000e6);
        _usdc(address(thirdHub), 2_000e6);
        _beginExit(third, id3);
        assertGt(LongVault(payable(address(third))).exitDebt(), 0);
        vm.mockCallRevert(address(third), abi.encodeWithSignature("exitDebt()"), bytes("no"));
        vm.prank(stranger);
        thirdHub.exitStep();
        assertEq(thirdHub.sentTo(0), 0);
        assertEq(usdc.balanceOf(makeAddr("payable")), 7_000e6);
    }

    function _emitted(Vm.Log[] memory logs, address from, bytes32 topic) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == from && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    /// 2b's exit fee with the routing equals the fee without it (the cash routed is not realised until it
    /// comes back as the leg's USDC), and nothing is charged before the debt is repaid.
    function test_fork_2d_exitFee_sameWithAndWithoutRouting() public onFork {
        bytes32 idA = keccak256("strategy-2d-feeA");
        bytes32 idB = keccak256("strategy-2d-feeB");
        LongVault a = _create(idA, 300);
        LongVault b = _create(idB, 300);
        uint256 feeA = _feeRun(a, idA, false);
        uint256 feeB = _feeRun(b, idB, true);
        emit log_named_uint("exit fee with routing (USDC units)", feeA);
        emit log_named_uint("exit fee without routing (USDC units)", feeB);
        assertGt(feeA, 0);
        assertApproxEqAbs(feeA, feeB, 1e6, "within a dollar: the sales' slippage alone differs");
    }

    /// 6,000 USDC of capital in the hub, 5,000 sent to the leg and levered there, 600 of profit arriving
    /// on the leg; the exit with or without the routing (`exitDebt()` mocked away).
    function _feeRun(LongVault v, bytes32 id, bool noRouting) internal returns (uint256) {
        StrategyHub h = StrategyHub(v.links(0));
        _usdc(address(h), 6_000e6);
        vm.startPrank(key);
        h.send(0, 5_000e6, false, 0); // link 0 of the hub: its AAVE leg
        v.swap(false, 5_000e6, 0);
        v.supply(weth.balanceOf(address(v)));
        v.borrow(3_000e6);
        v.swap(false, 3_000e6, 0);
        v.supply(weth.balanceOf(address(v)));
        vm.stopPrank();
        _usdc(address(v), 600e6); // earned on the leg: profit once it is paid out
        _beginExit(v, id);
        if (noRouting) vm.mockCallRevert(address(v), abi.encodeWithSignature("exitDebt()"), bytes("no"));
        vm.prank(stranger);
        h.exitStep();
        if (!noRouting) {
            assertEq(h.exitFeePaid() + h.exitFeeForgiven(), 0, "nothing charged before the debt is repaid");
            assertEq(h.sentTo(0), 5_000e6 + 1_000e6, "the hub's cash to the debt");
        }
        for (uint256 i; i < 4 && _debt(address(v)) + weth.balanceOf(address(v)) + IERC20x(Arbitrum.A_WETH).balanceOf(address(v)) > 0; ++i) {
            vm.prank(stranger);
            LongVaultExit(address(v)).exitStep(0, 0);
        }
        vm.prank(stranger);
        LongVaultExit(address(v)).exitStep(0, 0);
        vm.prank(stranger);
        h.exitStep();
        vm.clearMockedCalls();
        assertEq(_debt(address(v)), 0);
        assertEq(usdc.balanceOf(address(h)), 0);
        return h.exitFeePaid() + h.exitFeeForgiven(); // no fee address in this registry: forgiven, as due
    }

    // ── the reward sale in exit (decision 67) ───────────────────────────────────────────────────────────

    /// With the reward pool pushed near the limit, the exit's reward sale fills in part at the limit
    /// (ARB/USDC less 50 bp), the floor on what was paid; the rest stays for a later step.
    function test_fork_2d_rewardSale_partialAtTheLimit() public onFork {
        address v = address(vault);
        deal(ARB, v, 2_000_000e18);
        _beginExit(vault, STRATEGY);
        (, int256 answer,,,) = IFeed(Arbitrum.REWARD_FEED).latestRoundData();
        uint256 pArb = uint256(answer);
        uint160 limit = uint160(Math.sqrt(Math.mulDiv(pArb * (10_000 - 50), 1 << 192, _pu() * 1e16)));
        // the pool pushed to 10 bp above the limit (ARB is token0 there too)
        uint160 near = uint160(Math.sqrt(Math.mulDiv(pArb * (10_000 - 40), 1 << 192, _pu() * 1e16)));
        (uint160 now_,,,,,,) = IUniV3(Arbitrum.REWARD_POOL).slot0();
        pusher.push(Arbitrum.REWARD_POOL, near < now_, near);
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(v).exitStep(0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid;
        uint256 out;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == v && logs[i].topics[0] == REWARD_SWAPPED) {
                (paid, out,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        (uint160 after_,,,,,,) = IUniV3(Arbitrum.REWARD_POOL).slot0();
        assertGt(paid, 0);
        assertLt(paid, 2_000_000e18, "a partial fill");
        assertEq(IERC20x(ARB).balanceOf(v), 2_000_000e18 - paid);
        assertGe(after_, limit, "every fill at or above the limit");
        assertGe(out * _pu() * 1e18 * 10_000, paid * pArb * 1e6 * (10_000 - 100), "the floor on what was paid");
        // pushed past the limit: nothing sold, PoolOffOracle
        pusher.push(Arbitrum.REWARD_POOL, true, uint160(Math.sqrt(Math.mulDiv(pArb * (10_000 - 80), 1 << 192, _pu() * 1e16))));
        vm.recordLogs();
        vm.prank(stranger);
        LongVaultExit(v).exitStep(0, 0);
        assertTrue(_failed(vm.getRecordedLogs(), v, 8, LongVaultState.PoolOffOracle.selector));
    }

    // ── gas (§5.2's constants) ─────────────────────────────────────────────────────────────────────────

    /// The hub's step: a route and a payout, a payout alone; the leg's step at C4's default unwind.
    function test_fork_2d_hubStep_gasMeasured() public onFork {
        deal(Arbitrum.WETH, address(vault), 3e18);
        vm.startPrank(key);
        vault.supply(3e18);
        vault.borrow(1_000e6);
        vm.stopPrank();
        vm.prank(address(vault));
        usdc.transfer(stranger, 1_000e6);
        _usdc(address(hub), 5_000e6);
        _beginExit(vault, STRATEGY);
        uint256 g = gasleft();
        vm.prank(stranger);
        hub.exitStep();
        emit log_named_uint("hub exitStep: a route and a payout", g - gasleft());
        assertGt(hub.sentTo(0), 0);
        _usdc(address(hub), 1_000e6);
        g = gasleft();
        vm.prank(stranger);
        hub.exitStep();
        emit log_named_uint("hub exitStep: no route (debt covered), a payout", g - gasleft());
        g = gasleft();
        vm.prank(stranger);
        LongVaultExit(address(vault)).exitStep(0, 0);
        emit log_named_uint("leg exitStep: repay from the routed USDC, withdraw, sell, send", g - gasleft());
        assertEq(_debt(address(vault)), 0);
    }
}
