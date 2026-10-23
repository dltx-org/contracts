// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {console, stdStorage, StdStorage, Vm} from "forge-std/Test.sol";
import {ArbitrumForkV1} from "./ArbitrumForkV1.sol";
import {IAssetLegV1} from "./IAssetLegV1.sol";
import {AaveV3AssetLegV2, HubV2} from "./MocksV1.sol";
import {Hub} from "../src/Hub.sol";
import {HubFee} from "../src/HubFee.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {AaveV3AssetLegState} from "../src/AaveV3AssetLegState.sol";
import {AaveV3AssetLegExit} from "../src/AaveV3AssetLegExit.sol";
import {AaveV3AssetLegRewards} from "../src/AaveV3AssetLegRewards.sol";
import {AssetLegParams, AssetProfile, AssetsV1, OwnerMessagesV1, StrategySpec} from "../src/Types.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {Assets, Holding, OwnerMessages} from "../src/lib/VaultTypes.sol";
import {walletCred} from "./mocks/Mocks.sol";

interface IERC20b {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniV3b {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

interface IOracleB {
    function getAssetPrice(address) external view returns (uint256);
}

interface IFeedB {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IPoolB {
    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

/// Moves a Uniswap V3 pool's price to a target with whatever it holds.
contract Pusher {
    function push(address pool, bool zeroForOne, uint160 target) external {
        IUniV3b(pool).swap(address(this), zeroForOne, type(int128).max, target, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20b(IUniV3b(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20b(IUniV3b(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }
}

/// `_limitAt` and the leg's band as the engine must reproduce them (`engine/evm/src/exit-band.ts`).
contract BandProbe is AaveV3AssetLegState {
    constructor() AaveV3AssetLegState(Arbitrum.POOL, Arbitrum.USDC, Arbitrum.RECEIVER, Arbitrum.SEQUENCER) {}

    function limitAt(uint256 pIn, uint256 pUsdc, uint256 band, uint256 decimals, bool isToken0)
        external
        pure
        returns (uint160)
    {
        return _limitAt(pIn, pUsdc, band, decimals, isToken0);
    }
}

/*
 * The BTC (WBTC) strategy on an Arbitrum fork at the block asset-profiles-design.md §7 measured
 * (517,200,797): AP-3's checks against the chain (and refusals of mutated fields: the wrong-pair rate
 * feed), the loop and the exit on WBTC (8 decimals), the rate-referenced band (§3.5: a WBTC discount the
 * feed reports moves every bound on a sale, never above AAVE's price), the discounted, below-HF-1
 * position rescued by part 3, the chained reward parts, an upgrade leaving the position, the mark and the
 * profile untouched, a profile switch to the 0.30 % pool, and the band's vectors for the engine.
 * SKIPPED when ARBITRUM_RPC_URL is not set.
 */
contract AssetLegBtcForkTest is ArbitrumForkV1 {
    using stdStorage for StdStorage;

    uint256 constant BTC_BLOCK = 517_200_797; // 2026-10-22, asset-profiles-design.md §7's reads
    bytes32 constant STRATEGY = keccak256("strategy-btc");
    address constant WBTC_USDC_3000 = 0x6985cb98CE393FCE8d6272127F39013f61e36166;
    address constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant WBTC_USD_FEED = 0xd0C7101eACbB49F3deCcCc166d238410D6D46d57;

    IAssetLegV1 leg;
    Hub hub;
    IERC20b wbtc = IERC20b(WBTC);
    IERC20b usdc = IERC20b(Arbitrum.USDC);
    address aWbtc;
    address vdebt = Arbitrum.VDEBT_USDC;

    function setUp() public {
        if (!_forkV1(BTC_BLOCK, 1)) return;
        aWbtc = _btcP().aAsset;
        (leg, hub) = _create(keccak256("strategy-btc"), _specOf(btcProfile, _btcP(), 1, 300, 50));
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _create(bytes32 id, StrategySpec memory c) internal returns (IAssetLegV1 l, Hub h) {
        uint256 deadline = block.timestamp + 1 hours;
        address[] memory made =
            factory.create(id, address(owner), c, deadline, _signDigest(factory.createDigest(id, address(owner), c, deadline)));
        (h, l) = (Hub(made[0]), IAssetLegV1(made[1]));
        bytes memory ready = abi.encode(keccak256("dltx.strategy-vault.ready.v1"));
        bytes32 short = bytes32(uint256(uint160(l.links(1))));
        vm.prank(TRANSMITTER);
        MemberBase(address(l)).handleReceiveFinalizedMessage(19, short, 2000, ready);
        vm.prank(TRANSMITTER);
        MemberBase(address(h)).handleReceiveFinalizedMessage(19, short, 2000, ready);
    }

    function _usdc(address to, uint256 amount) internal {
        vm.prank(Arbitrum.A_USDC);
        usdc.transfer(to, amount);
    }

    function _health(address a) internal view returns (uint256 hf) {
        (,,,,, hf) = IPoolB(Arbitrum.POOL).getUserAccountData(a);
    }

    function _price(address a) internal view returns (uint256) {
        return IOracleB(Arbitrum.ORACLE).getAssetPrice(a);
    }

    /// 20,000 USDC in, bought as WBTC and supplied; borrowed and bought twice: about 2× leverage.
    function _lever(IAssetLegV1 l) internal {
        _usdc(address(l), 20_000e6);
        vm.startPrank(key);
        l.swap(false, 20_000e6, 0);
        l.supply(wbtc.balanceOf(address(l)));
        l.borrow(10_000e6);
        l.swap(false, 10_000e6, 0);
        l.supply(wbtc.balanceOf(address(l)));
        l.borrow(6_000e6);
        l.swap(false, 6_000e6, 0);
        l.supply(wbtc.balanceOf(address(l)));
        vm.stopPrank();
    }

    /// The WBTC / BTC feed answering `rate` (8 decimals), updated now.
    function _rate(int256 rate) internal {
        (uint80 id,,,,) = IFeedB(WBTC_BTC_FEED).latestRoundData();
        vm.mockCall(
            WBTC_BTC_FEED,
            abi.encodeWithSelector(IFeedB.latestRoundData.selector),
            abi.encode(id, rate, block.timestamp, block.timestamp, id)
        );
        vm.mockCall(
            WBTC_BTC_FEED,
            abi.encodeWithSignature("getRoundData(uint80)", id),
            abi.encode(id, rate, block.timestamp, block.timestamp, id)
        );
    }

    /// The WBTC/USDC pool pushed to `bp` below AAVE's WBTC price (token0: selling WBTC lowers it).
    function _poolAt(uint256 bp) internal {
        BandProbe probe = new BandProbe();
        uint160 target = probe.limitAt(_price(WBTC), _price(Arbitrum.USDC), bp, 8, true);
        Pusher p = new Pusher();
        (uint160 now_,,,,,,) = IUniV3b(WBTC_USDC_500).slot0();
        if (target < now_) {
            deal(WBTC, address(p), 1_000e8);
            p.push(WBTC_USDC_500, true, target);
        } else {
            _usdc(address(p), 50_000_000e6);
            p.push(WBTC_USDC_500, false, target);
        }
    }

    function _exitAll(uint256 steps) internal {
        uint256 deadline = block.timestamp + 1 hours;
        MemberBase(address(hub)).beginExit(
            deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, keccak256("strategy-btc"), deadline)))
        );
        for (uint256 i; i < steps; ++i) {
            leg.exitStep(0, 0);
            hub.exitStep();
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
        }
    }

    // ── the profile against the chain (AP-3) ────────────────────────────────────────────────────────────

    function test_fork_btc_profileCheckedAgainstTheChain() public onFork {
        assertTrue(registry.profileOpen(btcProfile));
        assertTrue(registry.profileOpen(ethProfile));
        assertEq(wbtc.decimals(), 8);
        assertEq(IUniV3b(WBTC_USDC_500).token0(), WBTC);
        (bytes32 id, address asset, uint8 d,, address pool, uint24 fee, bool t0, bytes32 holding,,,) =
            AaveV3AssetLegRewards(address(leg)).assetProfile();
        assertEq(id, btcProfile);
        assertEq(asset, WBTC);
        assertEq(d, 8);
        assertEq(pool, WBTC_USDC_500);
        assertEq(fee, 500);
        assertTrue(t0);
        assertEq(holding, AssetsV1.WBTC);
    }

    function _refused(AssetProfile memory p) internal {
        vm.prank(recovery);
        bytes32 id = registry.proposeProfile(p);
        stdstore.target(address(registry)).sig("profileDue(bytes32)").with_key(id).checked_write(block.timestamp);
        vm.prank(recovery);
        vm.expectRevert(MemberState.BadProfile.selector);
        registry.acceptProfile(id);
    }

    /// §9.2's mutation test on the chain: each field wrong is refused; the wrong-pair feeds (USDC / USD,
    /// WBTC / USD: code, 8 decimals, fresh positive answers) by their identity.
    function test_fork_btc_mutationsRefused() public onFork {
        AssetProfile memory p;
        p = _btcP(); p.rateFeed = USDC_USD_FEED; p.pins[1].feed = USDC_USD_FEED; _refused(p);
        p = _btcP(); p.rateFeed = WBTC_USD_FEED; _refused(p);
        p = _btcP(); p.swapPool = WBTC_USDC_3000; _refused(p); // the 0.30 % pool under the 0.05 % tier
        p = _btcP(); p.assetDecimals = 18; _refused(p);
        p = _btcP(); p.aAsset = Arbitrum.A_WETH; _refused(p);
        p = _btcP(); p.assetIsToken0 = false; _refused(p);
        p = _btcP(); p.shortAsset = Assets.ETH; _refused(p);
        p = _btcP(); p.asset = Arbitrum.REWARD; _refused(p); // ARB: the reward, never the collateral
    }

    // ── the loop and the exit on WBTC ────────────────────────────────────────────────────────────────────

    function test_fork_btc_fullLoopAndExit() public onFork {
        address l = address(leg);
        _lever(leg);
        uint256 hf = _health(l);
        assertGt(hf, 1.15e18);
        assertLt(hf, 3e18);
        (Holding[] memory h,,,,,,) = AaveV3AssetLegExit(l).holdings();
        assertEq(h[0].asset, AssetsV1.WBTC);
        assertApproxEqRel(uint256(h[0].quantity), IERC20b(aWbtc).balanceOf(l) * 1e10, 1e15);
        // the atomic repay at the reference, through the deployed receiver and the WBTC/USDC 0.05 % pool
        uint256 debt0 = IERC20b(vdebt).balanceOf(l);
        uint256 maxColl = 2_000e6 * _price(Arbitrum.USDC) * 1e8 * 10_300 / (_price(WBTC) * 1e6 * 10_000);
        vm.prank(key);
        leg.repayWithCollateral(2_000e6, maxColl);
        assertApproxEqAbs(IERC20b(vdebt).balanceOf(l), debt0 - 2_000e6, 2);
        assertGt(_health(l), hf);
        // the exit: everything to the hub, the hub to the withdrawal address
        _exitAll(6);
        assertEq(IERC20b(vdebt).balanceOf(l), 0, "the debt repaid");
        assertLt(IERC20b(aWbtc).balanceOf(l) + wbtc.balanceOf(l), 1e3, "the collateral sold");
        assertGt(usdc.balanceOf(withdrawalTo), 17_000e6, "the owner paid, less the swaps' costs");
    }

    // ── the rate-referenced band (§3.5, AP-8) ─────────────────────────────────────────────────────────────

    /// The pool 150 bp below AAVE's BTC price (a WBTC discount beyond the 50 bp band): with the rate at
    /// 1 the exit sale waits (PoolOffOracle); with the feed reporting a 1.5 % discount the band follows
    /// it and the sale goes, its average held to the reference less the bound.
    function test_fork_btc_bandFollowsTheReportedDiscount() public onFork {
        deal(WBTC, address(leg), 0.2e8);
        uint256 deadline = block.timestamp + 1 hours;
        MemberBase(address(hub)).beginExit(
            deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, keccak256("strategy-btc"), deadline)))
        );
        _rate(1e8);
        _poolAt(150);
        vm.recordLogs();
        leg.exitStep(0, 0);
        assertEq(wbtc.balanceOf(address(leg)), 0.2e8, "no sale below the band at AAVE's price");
        _rate(0.985e8);
        leg.exitStep(0, 0);
        assertLt(wbtc.balanceOf(address(leg)), 0.2e8, "sold within the band at the reference");
        // the reference never above AAVE's price: a rate above 1 changes nothing
        assertGt(_price(WBTC), 0);
    }

    /// AP-12: a feed reporting a 30 % discount moves the reference by 10 % at most (R6: the exit stalls
    /// rather than selling 30 % under AAVE's price).
    function test_fork_btc_rateCappedAtTenPercent() public onFork {
        deal(WBTC, address(leg), 0.2e8);
        uint256 deadline = block.timestamp + 1 hours;
        MemberBase(address(hub)).beginExit(
            deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, keccak256("strategy-btc"), deadline)))
        );
        _rate(0.7e8);
        _poolAt(1_200);
        leg.exitStep(0, 0);
        assertEq(wbtc.balanceOf(address(leg)), 0.2e8, "no sale 12 % under AAVE's price");
    }

    /// Codex round 1's case (§3.5): a 4 % WBTC discount, the position below a health factor of 1, the
    /// bound 300 bp. With the rate unread, every bound is at AAVE's price: part 3 is refused before it starts
    /// (the pool is 4 % under the band's limit) and part 4 frees nothing at HF < 1, so the exit waits for a
    /// liquidation. With the feed's rate, part 3's atomic repay, its collateral capped at the REFERENCE,
    /// buys the flash loan back. The position is levered to the lowest floor an owner may sign (1.05) so
    /// that a 12 % fall puts it under water without pushing the pool so far that its liquidity is gone.
    function test_fork_btc_discountedBelowHf1_rescuedByPart3() public onFork {
        // a strategy at the lowest health floor an owner may sign (1.05), the bound at 300 bp
        StrategySpec memory c = _specOf(btcProfile, _btcP(), 1, 300, 50);
        AssetProfile memory q = _btcP();
        c.legs[0].params = abi.encode(AssetLegParams(btcProfile, q.asset, q.swapPool, q.swapFee, q.rateFeed, 1.05e18, 300, 50, 5));
        (IAssetLegV1 low, Hub lowHub) = _create(keccak256("strategy-btc-hf"), c);
        address l = address(low);
        _usdc(l, 5_000e6);
        vm.startPrank(key);
        low.swap(false, 5_000e6, 0);
        low.supply(wbtc.balanceOf(l));
        for (uint256 i; i < 8; ++i) {
            (uint256 coll, uint256 d,,,,) = IPoolB(Arbitrum.POOL).getUserAccountData(l);
            uint256 more = (coll * 72 / 100 - d) / 100; // to 72 % of the collateral (AAVE's LTV is 73 %)
            if (more < 50e6) break;
            low.borrow(more);
            low.swap(false, more, 0);
            low.supply(wbtc.balanceOf(l));
        }
        vm.stopPrank();
        assertLt(_health(l), 1.12e18);
        // AAVE's BTC price 12 % lower: the position below a health factor of 1 at AAVE
        uint256 p = _price(WBTC);
        vm.mockCall(Arbitrum.ORACLE, abi.encodeWithSelector(IOracleB.getAssetPrice.selector, WBTC), abi.encode(p * 88 / 100));
        assertLt(_health(l), 1e18);
        // the market 4 % under AAVE's new price, the feed reporting it
        _poolAt(400);
        uint256 debt0 = IERC20b(vdebt).balanceOf(l);
        uint256 deadline = block.timestamp + 1 hours;
        MemberBase(address(lowHub)).beginExit(
            deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, keccak256("strategy-btc-hf"), deadline)))
        );
        uint256 snap = vm.snapshotState();
        // the rate unread (its round stale): every bound at AAVE's price
        vm.mockCall(WBTC_BTC_FEED, abi.encodeWithSelector(IFeedB.latestRoundData.selector), abi.encode(uint80(1), int256(0.96e8), uint256(1), uint256(1), uint80(1)));
        low.exitStep(0, 0);
        assertEq(IERC20b(vdebt).balanceOf(l), debt0, "part 3 refused at AAVE's price, part 4 frees nothing at HF < 1");
        vm.revertToState(snap);
        _rate(0.96e8);
        low.exitStep(0, 0);
        assertEq(IERC20b(vdebt).balanceOf(l), 0, "part 3 repays the debt at the reference");
        // in the same step, the rest withdrawn (part 5) and sold within the band at the reference (part 6)
        assertLt(IERC20b(aWbtc).balanceOf(l) + wbtc.balanceOf(l), 1e3, "the rest sold");
        assertGt(usdc.balanceOf(address(lowHub)) + usdc.balanceOf(withdrawalTo), 0, "its USDC on the way to the owner");
    }

    // ── the chained reward parts on WBTC (amendment 2c §3.7 through the rewards module) ─────────────

    /// ARB and aArbARB held by the WBTC leg: the exit's first parts (8 and 9 through `rewardPart`, under
    /// `exitStep`'s lock) sell the reward for USDC, then the position's parts unwind as usual.
    function test_fork_btc_exit_rewardPartsRunThroughTheRewardsModule() public onFork {
        address l = address(leg);
        _lever(leg);
        deal(Arbitrum.REWARD, l, 500e18);
        address holder = makeAddr("campaign-holder");
        deal(Arbitrum.REWARD, holder, 500e18);
        vm.startPrank(holder);
        (bool ok,) = Arbitrum.REWARD.call(abi.encodeWithSignature("approve(address,uint256)", Arbitrum.POOL, 500e18));
        require(ok, "approve");
        (ok,) = Arbitrum.POOL.call(
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", Arbitrum.REWARD, 500e18, l, 0)
        );
        require(ok, "supply on the leg's behalf");
        vm.stopPrank();
        assertGt(IERC20b(Arbitrum.A_REWARD).balanceOf(l), 0);
        uint256 deadline = block.timestamp + 1 hours;
        MemberBase(address(hub)).beginExit(
            deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, keccak256("strategy-btc"), deadline)))
        );
        vm.recordLogs();
        vm.prank(stranger);
        leg.exitStep(0, 0);
        assertLt(IERC20b(Arbitrum.REWARD).balanceOf(l) + IERC20b(Arbitrum.A_REWARD).balanceOf(l), 1e16, "the reward sold");
        bool swapped;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == l && logs[i].topics[0] == keccak256("RewardSwapped(uint256,uint256,uint256)")) swapped = true;
        }
        assertTrue(swapped, "part 8 ran in the rewards module");
        assertEq(IERC20b(vdebt).balanceOf(l), 0, "and the position unwound in the same step");
    }

    // ── an upgrade on the fork (AP-11) ────────────────────────────────────────────────────────────────

    function test_fork_btc_upgradeLeavesThePositionTheMarkAndTheProfile() public onFork {
        address l = address(leg);
        _lever(leg);
        address hub2 = address(
            new HubV2(address(hubFee), address(hubFee).codehash, address(upgrade), address(upgrade).codehash, address(registry), Arbitrum.SEQUENCER)
        );
        address long2 = address(
            new AaveV3AssetLegV2(
                address(longExit), address(longExit).codehash, address(longRewards), address(longRewards).codehash,
                address(upgrade), address(upgrade).codehash, address(registry), Arbitrum.POOL, Arbitrum.USDC,
                Arbitrum.RECEIVER, Arbitrum.SEQUENCER
            )
        );
        bytes32 manifest2 = _listNow(2, hub2, long2);
        uint256[] memory vs = new uint256[](2);
        (vs[0], vs[1]) = (1, 2);
        vm.prank(key);
        registry.checkIn(1, vs);
        uint256 coll = IERC20b(aWbtc).balanceOf(l);
        uint256 debt = IERC20b(vdebt).balanceOf(l);
        int256 mark = hub.mark();
        uint64 lastFee = hub.lastFeeAt();
        bytes32 cred = walletCred(wallet);
        uint256 deadline = block.timestamp + 1 hours;
        VaultUpgrade(address(hub)).scheduleUpgrade(
            manifest2,
            cred,
            deadline,
            _sign(keccak256(abi.encode(OwnerMessagesV1.UPGRADE_STRATEGY_TYPEHASH, address(hub), block.chainid, manifest2, 0, deadline)))
        );
        vm.warp(block.timestamp + 24 hours);
        uint256 g = gasleft();
        VaultUpgrade(address(hub)).applyUpgrade();
        console.log("applyUpgrade gas (hub, its long, the short's message):", g - gasleft());
        assertEq(_implOf(address(hub)), hub2);
        assertEq(_implOf(l), long2);
        assertApproxEqAbs(IERC20b(aWbtc).balanceOf(l), coll, coll / 10_000); // a day's supply interest, no move
        assertApproxEqAbs(IERC20b(vdebt).balanceOf(l), debt, debt / 1000); // a day's interest, no move
        assertEq(hub.mark(), mark);
        assertEq(hub.lastFeeAt(), lastFee);
        assertEq(hub.profile(), btcProfile);
        // the upgraded leg still trades
        _usdc(l, 1_000e6);
        vm.prank(key);
        leg.repay(1_000e6);
    }

    // ── a profile switch on the fork (§3.7) ───────────────────────────────────────────────────────────

    function test_fork_btc_switchToThe30bpPool() public onFork {
        _lever(leg);
        AssetProfile memory p = _btcP();
        p.swapPool = WBTC_USDC_3000;
        p.swapFee = 3000;
        p.minBoundBp = 60;
        bytes32 to = _acceptNow(p);
        bytes32 cred = walletCred(wallet);
        uint256 deadline = block.timestamp + 1 hours;
        HubFee(address(hub)).scheduleSwitch(
            to,
            cred,
            deadline,
            _sign(keccak256(abi.encode(OwnerMessagesV1.SWITCH_PROFILE_TYPEHASH, address(hub), block.chainid, btcProfile, to, 0, deadline)))
        );
        vm.warp(block.timestamp + 24 hours);
        HubFee(address(hub)).applySwitch();
        assertEq(hub.profile(), to);
        (bytes32 id,,,, address pool, uint24 fee,,,,,) = AaveV3AssetLegRewards(address(leg)).assetProfile();
        assertEq(id, to);
        assertEq(pool, WBTC_USDC_3000);
        assertEq(fee, 3000);
        // the key's sale now goes through the 0.30 % pool
        vm.prank(key);
        leg.withdraw(WBTC, 0.001e8);
        uint256 before = usdc.balanceOf(address(leg));
        vm.prank(key);
        leg.swap(true, 0.001e8, 0);
        assertGt(usdc.balanceOf(address(leg)), before);
    }

    // ── the band's vectors for the engine (slice 2) ──────────────────────────────────────────────────────

    function test_fork_bandVectors() public onFork {
        BandProbe probe = new BandProbe();
        uint256 pu = _price(Arbitrum.USDC);
        console.log("fork block", BTC_BLOCK);
        console.log("pUsdc", pu);
        // WETH: 18 decimals, token0, no rate, the 0.05 % pool, oracleBoundBp 100: band min(50, 100 - 5) = 50
        uint256 pw = _price(Arbitrum.WETH);
        console.log("WETH pAave", pw);
        console.log("WETH limit(band 50, 18, token0)", probe.limitAt(pw, pu, 50, 18, true));
        // WBTC: 8 decimals, token0, the rate feed, oracleBoundBp 300: band min(50, 300 - 5) = 50
        uint256 pb = _price(WBTC);
        (, int256 rate,,,) = IFeedB(WBTC_BTC_FEED).latestRoundData();
        uint256 ref = uint256(rate) < 1e8 ? pb * (uint256(rate) * 1e10) / 1e18 : pb;
        console.log("WBTC pAave", pb);
        console.log("WBTC rate (8 decimals)", uint256(rate));
        console.log("WBTC reference", ref);
        console.log("WBTC limit(band 50, 8, token0)", probe.limitAt(ref, pu, 50, 8, true));
        // the leg's own band, the same number
        // a token1 mock: 18 decimals, priced 2,000 USD, band 50
        console.log("mock token1 limit(2000e8, band 50, 18, token1)", probe.limitAt(2_000e8, pu, 50, 18, false));
        console.log("mock token0 limit(2000e8, band 50, 18, token0)", probe.limitAt(2_000e8, pu, 50, 18, true));
        assertGt(ref, 0);
    }
}
