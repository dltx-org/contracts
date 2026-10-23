// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {ArbitrumForkV1} from "./ArbitrumForkV1.sol";
import {IAssetLegV1} from "./IAssetLegV1.sol";
import {Hub} from "../src/Hub.sol";
import {HubFee} from "../src/HubFee.sol";
import {HubState} from "../src/HubState.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {MemberState} from "../src/MemberState.sol";
import {AaveV3AssetLegState} from "../src/AaveV3AssetLegState.sol";
import {AaveV3AssetLegExit} from "../src/AaveV3AssetLegExit.sol";
import {StrategySpec} from "../src/Types.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";
import {FeePins} from "../src/lib/FeePins.sol";
import {FeeMath} from "../src/lib/FeeMath.sol";
import {Assets, Holding, Legs, OwnerMessages, VaultConfig} from "../src/lib/VaultTypes.sol";
import {MockOwner, walletCred} from "./mocks/Mocks.sol";

interface IERC20x {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IPoolx {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);
    function getUserConfiguration(address user) external view returns (uint256);
}

interface IUniPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

interface IChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IOracle {
    function getAssetPrice(address) external view returns (uint256);
}

interface ITransmitter {
    function localDomain() external view returns (uint32);
    function pauser() external view returns (address);
    function pause() external;
    function unpause() external;
}

interface ITransmitterAdmin {
    function attesterManager() external view returns (address);
    function enableAttester(address attester) external;
    function setSignatureThreshold(uint256 newSignatureThreshold) external;
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

/// An attacker's message handler: accepts anything Circle hands it.
contract FakeHandler {
    function handleReceiveFinalizedMessage(uint32, bytes32, uint32, bytes calldata) external pure returns (bool) {
        return true;
    }
}

interface IRewardsCtl {
    function getEmissionManager() external view returns (address);
    function getTransferStrategy(address reward) external view returns (address);
    function setDistributionEnd(address asset, address reward, uint32 newDistributionEnd) external;
    function setEmissionPerSecond(address asset, address[] calldata rewards, uint88[] calldata newEmissionsPerSecond)
        external;
}

interface IPullStrategy {
    function getRewardsVault() external view returns (address);
}

interface IMerkl {
    struct MerkleTree {
        bytes32 merkleRoot;
        bytes32 ipfsHash;
    }

    function updateTree(MerkleTree calldata tree) external;
    function getMerkleRoot() external view returns (bytes32);
    function accessControlManager() external view returns (address);
}

interface IMerklClaim {
    function claim(address[] calldata, address[] calldata, uint256[] calldata, bytes32[][] calldata) external;
}

interface IAToken {
    function getIncentivesController() external view returns (address);
}

/// Burns every unit of gas it is given: a reward dependency gone wrong (amendment 2c §3.7).
contract GasBurner {
    fallback() external {
        while (true) {}
    }
}

/// Merkl's PullTokenWrapper as AAVE's campaigns used it (amendment 2c §3.4): when the distributor pays
/// it, it pulls the campaign holder's aArbARB to the recipient; nothing of the wrapper stays.
contract MockPullTokenWrapper {
    address immutable token;
    address immutable holder;
    address immutable distributor;

    constructor(address token_, address holder_, address distributor_) {
        token = token_;
        holder = holder_;
        distributor = distributor_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(msg.sender == distributor, "distributor");
        (bool ok,) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, amount));
        require(ok, "pull");
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

interface IReceiver {
    function POOL() external view returns (address);
}

/*
 * PARITY (asset-profiles-design.md §10 slice 1): version 0's AAVE leg fork suite (`test/IAssetLegV1.fork.t.sol`)
 * run on version 1's generic AAVE V3 asset leg with the ETH profile (WETH, the 0.05 % pool, no rate feed),
 * behind the shared proxy, made by the version-1 factory from the registry's version 1. Every test is
 * version 0's, its assertions unchanged; what changed is the world (`ArbitrumForkV1`) and the names (the
 * leg's modules reached by its address through `IAssetLegV1`). An ETH build that is never deployed as
 * such: ETH on version 1 is this same code with the ETH profile. SKIPPED when ARBITRUM_RPC_URL is not set.
 */
contract AssetLegEthForkTest is ArbitrumForkV1 {
    uint256 constant PINNED_BLOCK = 514_790_000; // 2026-10-14, version 0's
    bytes32 constant STRATEGY = keccak256("strategy-1");

    IAssetLegV1 vault; // the AAVE leg
    Hub hub; // its hub, beside it

    IERC20x weth = IERC20x(Arbitrum.WETH);
    IERC20x usdc = IERC20x(Arbitrum.USDC);
    IPoolx pool = IPoolx(Arbitrum.POOL);

    function setUp() public {
        if (!_forkV1(PINNED_BLOCK, 1)) return;
        vault = _createVault(STRATEGY, _config(50));
        hub = Hub(vault.links(0));
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    function _config(uint16 dailyLossBp) internal view returns (StrategySpec memory) {
        return _specOf(ethProfile, _ethP(), 1, 100, dailyLossBp);
    }

    /// Circle relays the Hyperliquid leg's finalized READY (from HyperEVM) to `v`, the AAVE leg's link 1:
    /// its transmitter impersonated.
    function _hlReady(address a, uint8 k) internal {
        MemberBase v = MemberBase(a);
        bytes32 hl = bytes32(uint256(uint160(v.links(k))));
        vm.prank(TRANSMITTER);
        v.handleReceiveFinalizedMessage(19, hl, 2000, abi.encode(keccak256("dltx.strategy-vault.ready.v1")));
        assertTrue(v.ready(k));
    }

    function _createVault(bytes32 id, StrategySpec memory c) internal returns (IAssetLegV1) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig =
            _signDigest(factory.createDigest(id, address(owner), c, deadline));
        address[] memory made = factory.create(id, address(owner), c, deadline, sig);
        IAssetLegV1 v = IAssetLegV1((made[1]));
        assertTrue(v.ready(0), "its hub, beside it");
        _hlReady(address(v), 1);
        _hlReady(made[0], 1);
        return v;
    }

    /// The key takes `amount` out of the leg to the owner's deposit account: to the hub, then paid out.
    function _takeOut(IAssetLegV1 v, uint256 amount) internal {
        vm.startPrank(key);
        v.send(0, amount, false, 0);
        HubFee(v.links(0)).payout(amount, new uint80[](0));
        vm.stopPrank();
    }

    function _usdc(address to, uint256 amount) internal {
        vm.prank(Arbitrum.A_USDC); // the aToken holds the reserve's USDC
        usdc.transfer(to, amount);
    }

    function _health(address a) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(a);
    }

    /// The loop through the vault: 5,000 USDC in; ~3,000 bought as WETH and supplied; borrow and buy
    /// more WETH twice, to about 2× leverage.
    function _lever(IAssetLegV1 v) internal {
        _usdc(address(v), 5_000e6);
        vm.startPrank(key);
        v.swap(false, 5_000e6, 0);
        v.supply(weth.balanceOf(address(v)));
        v.borrow(2_500e6);
        v.swap(false, 2_500e6, 0);
        v.supply(weth.balanceOf(address(v)));
        v.borrow(1_500e6);
        v.swap(false, 1_500e6, 0);
        v.supply(weth.balanceOf(address(v)));
        vm.stopPrank();
    }

    /// A levered position built without a sale, so nothing is charged to the budget yet.
    function _leverWithoutSwaps(IAssetLegV1 v) internal {
        deal(Arbitrum.WETH, address(v), 3e18);
        vm.startPrank(key);
        v.supply(3e18);
        v.borrow(3_000e6);
        vm.stopPrank();
    }

    // ── the pins ─────────────────────────────────────────────────────────────────────────────────────

    function test_fork_pinnedAddresses() public onFork {
        assertEq(ITransmitter(TRANSMITTER).localDomain(), 3);
        assertEq(pool.getReserveData(Arbitrum.WETH).aTokenAddress, Arbitrum.A_WETH);
        assertEq(pool.getReserveData(Arbitrum.USDC).aTokenAddress, Arbitrum.A_USDC);
        assertEq(pool.getReserveData(Arbitrum.USDC).variableDebtTokenAddress, Arbitrum.VDEBT_USDC);
        assertEq(IUniPool(Arbitrum.SWAP_POOL).token0(), Arbitrum.WETH);
        assertEq(IUniPool(Arbitrum.SWAP_POOL).token1(), Arbitrum.USDC);
        assertEq(IUniPool(Arbitrum.SWAP_POOL).fee(), 500);
        assertEq(IReceiver(Arbitrum.RECEIVER).POOL(), Arbitrum.POOL);
        assertGt(TOKEN_MESSENGER.code.length, 0);
    }

    // ── the full loop (§13) ──────────────────────────────────────────────────────────────────────────

    function test_fork_fullLoop_throughTheVault() public onFork {
        address v = address(vault);
        _lever(vault);
        uint256 hf = _health(v);
        assertGt(hf, 1.15e18);
        assertLt(hf, 3e18);
        // de-lever a step with collateral, atomically, through the deployed receiver
        uint256 debt0 = IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v);
        uint256 maxColl = 1_000e6 * IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.USDC) * 1e12 * 10_100
            / (IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.WETH) * 10_000);
        vm.prank(key);
        vault.repayWithCollateral(1_000e6, maxColl);
        assertApproxEqAbs(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), debt0 - 1_000e6, 2);
        assertGt(_health(v), hf, "a fair repay with collateral raises health");
        assertGt(vault.lossInWindow(), 0, "its shortfall charged to the budget");
        // repay from the vault's own USDC, withdraw some collateral, send half to the Hyperliquid leg,
        // the rest to the hub, which pays the owner
        _usdc(v, 600e6);
        vm.startPrank(key);
        vault.repay(400e6);
        vault.withdraw(Arbitrum.WETH, 0.05e18);
        vault.swap(true, 0.05e18, 0);
        uint256 cash = usdc.balanceOf(v);
        vault.send(1, cash / 2, false, 0);
        uint256 rest = usdc.balanceOf(v);
        vault.send(0, rest, false, 0);
        HubFee(address(hub)).payout(rest, new uint80[](0));
        vm.stopPrank();
        assertEq(usdc.balanceOf(v), 0);
        assertEq(vault.sentTo(1), cash / 2);
        assertEq(vault.sentTo(0), rest);
        assertEq(hub.receivedFrom(0), rest, "counted at the hub, per pair");
        assertEq(usdc.balanceOf(address(owner)), rest, "payout to the deposit account");
    }

    /// The log shape the ledger reads (slice 3's re-review P2): the receiver takes the vault's aWETH by
    /// `transferFrom`, so the vault's collateral leaves by the aToken's `BalanceTransfer`, never by a
    /// pool `Withdraw` of the vault; its debt by a `Repay` of the vault after the debt token's `Burn`.
    function test_fork_repayWithCollateral_logShape() public onFork {
        address v = address(vault);
        _lever(vault);
        vm.warp(block.timestamp + 1 days); // interest accrued: the transfer materialises it
        uint256 maxColl = 1_000e6 * IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.USDC) * 1e12 * 10_100
            / (IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.WETH) * 10_000);
        vm.recordLogs();
        vm.prank(key);
        vault.repayWithCollateral(1_000e6, maxColl);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 balanceTransfer = keccak256("BalanceTransfer(address,address,uint256,uint256)");
        bytes32 withdrawTopic = keccak256("Withdraw(address,address,address,uint256)");
        bytes32 repayTopic = keccak256("Repay(address,address,address,uint256,bool)");
        bytes32 mintTopic = keccak256("Mint(address,address,uint256,uint256,uint256)");
        bytes32 burnTopic = keccak256("Burn(address,address,uint256,uint256,uint256)");
        bytes32 vaultTopic = bytes32(uint256(uint160(v)));
        uint256 none = type(uint256).max;
        uint256 transferAt = none;
        uint256 repayAt = none;
        uint256 debtBurnAt = none;
        uint256 aMintAt = none;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter == Arbitrum.A_WETH && l.topics[0] == balanceTransfer && l.topics[1] == vaultTopic) {
                assertEq(address(uint160(uint256(l.topics[2]))), Arbitrum.RECEIVER, "to the receiver");
                transferAt = i;
            }
            // the interest the transfer materialises: the vault's last aWETH Mint before it
            if (
                transferAt == none && l.emitter == Arbitrum.A_WETH && l.topics[0] == mintTopic
                    && l.topics[2] == vaultTopic
            ) aMintAt = i;
            if (l.emitter == Arbitrum.POOL && l.topics[0] == withdrawTopic) {
                assertTrue(l.topics[2] != vaultTopic, "no Withdraw of the vault's");
            }
            if (l.emitter == Arbitrum.POOL && l.topics[0] == repayTopic && l.topics[2] == vaultTopic) repayAt = i;
            if (l.emitter == Arbitrum.VDEBT_USDC && l.topics[0] == burnTopic && l.topics[1] == vaultTopic) {
                debtBurnAt = i;
            }
        }
        emit log_named_uint("debt Burn at", debtBurnAt);
        emit log_named_uint("Repay at", repayAt);
        emit log_named_uint("aWETH Mint at", aMintAt);
        emit log_named_uint("BalanceTransfer at", transferAt);
        assertTrue(transferAt != none, "the aWETH leaves by BalanceTransfer");
        assertTrue(repayAt != none, "a Repay of the vault");
        assertTrue(debtBurnAt < repayAt, "the debt token's Burn before the pool's Repay");
        assertTrue(aMintAt < transferAt, "the accrued interest minted just before the transfer");
        assertTrue(repayAt < transferAt, "the debt repaid before the collateral is taken");
    }

    /// A burn to a member is bound to it: Circle's `MessageSent` names it as the mint's recipient and its
    /// only caller (decision 44).
    function test_fork_send_fastFeeCapped_boundToTheMember() public onFork {
        _usdc(address(vault), 1_000e6);
        vm.prank(key);
        vm.expectRevert(MemberState.FeeAboveCap.selector);
        vault.send(1, 1_000e6, true, 0.51e6); // 5 bp cap = 0.5 USDC
        vm.recordLogs();
        vm.prank(key);
        vault.send(1, 1_000e6, true, 0.14e6); // ~1.4 bp, Circle's measured fast fee
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertGt(vault.lossInWindow(), 0, "the fast fee charged to the budget");
        bytes memory message = _messageSent(vm.getRecordedLogs());
        bytes32 hl = bytes32(uint256(uint160(vault.links(1))));
        assertEq(uint32(bytes4(_slice(message, 8, 4))), 19, "to HyperEVM");
        assertEq(bytes32(_slice(message, 108, 32)), hl, "only the Hyperliquid leg completes the mint");
        assertEq(bytes32(_slice(message, 148 + 36, 32)), hl, "minted to it");
        assertEq(bytes32(_slice(message, 148 + 100, 32)), bytes32(uint256(uint160(address(vault)))), "burned by the AAVE leg");
        assertEq(uint32(bytes4(_slice(message, 140, 4))), 1000, "fast");
    }

    function _messageSent(Vm.Log[] memory logs) internal pure returns (bytes memory message) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == TRANSMITTER && logs[i].topics[0] == keccak256("MessageSent(bytes)")) {
                message = abi.decode(logs[i].data, (bytes));
            }
        }
    }

    /// Minor 8: a fast transfer's fee counts against the 24-hour loss budget.
    function test_fork_bridge_fastFeeOverTheBudget() public onFork {
        IAssetLegV1 tight = _createVault(keccak256("tight"), _config(1)); // 0.01% of equity
        _usdc(address(tight), 1_000e6);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.OverBudget.selector);
        tight.send(1, 1_000e6, true, 0.14e6);
        vm.prank(key);
        tight.send(1, 1_000e6, false, 0); // standard: no fee, no charge
    }

    /// The re-review: a standard burn's Circle minimum fee is charged too (a key can't loop burns into
    /// Circle's fees if its controller raises the minimum).
    function test_fork_bridge_standardMinimumFeeCharged() public onFork {
        // Arbitrum's messenger at the pinned block has no minimum-fee controller (getMinFeeAmount reads
        // as 0): the minimum is mocked at 2 bp, over this vault's 1 bp budget
        vm.mockCall(TOKEN_MESSENGER, abi.encodeWithSignature("getMinFeeAmount(uint256)"), abi.encode(uint256(0.2e6)));
        IAssetLegV1 tight = _createVault(keccak256("tight"), _config(1)); // 0.01% of equity
        _usdc(address(tight), 1_000e6);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.OverBudget.selector);
        tight.send(1, 1_000e6, false, 0);
        _usdc(address(vault), 1_000e6);
        vm.prank(key);
        vault.send(1, 1_000e6, false, 0);
        assertGt(vault.lossInWindow(), 0);
    }

    // ── the limits (decision 9, 25) ──────────────────────────────────────────────────────────────────

    function test_fork_healthFloor_refusesBorrowAndWithdraw() public onFork {
        _lever(vault);
        // within AAVE's own limits (its LTV, its health factor of 1), below the vault's 1.15
        (uint256 c, uint256 d, uint256 available, uint256 lt,,) = pool.getUserAccountData(address(vault));
        uint256 pu = IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.USDC);
        uint256 pw = IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.WETH);
        vm.startPrank(key);
        vm.expectRevert(AaveV3AssetLegState.BelowHealthFloor.selector);
        vault.borrow(available * 95 / 100 * 1e6 / pu);
        // collateral down to a health factor of 1.08: C' = 1.08 × D / LT
        uint256 keep = 108 * d * 10_000 / (100 * lt);
        vm.expectRevert(AaveV3AssetLegState.BelowHealthFloor.selector);
        vault.withdraw(Arbitrum.WETH, (c - keep) * 1e18 / pw);
        vm.stopPrank();
    }

    function test_fork_onlyTheGroupKey_revokedRefused() public onFork {
        _usdc(address(vault), 100e6);
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        vault.send(0, 1, false, 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, address(vault), block.chainid, uint8(1), address(0), uint256(0), deadline))
        );
        vault.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, sig);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.send(0, 1, false, 0);
        // the long half has no agent
        sig = _sign(
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, address(vault), block.chainid, uint8(3), stranger, uint256(1), deadline))
        );
        vm.expectRevert(MemberState.Unsupported.selector);
        vault.ownerAction(OwnerMessages.REPLACE_AGENT, stranger, walletCred(wallet), deadline, sig);
    }

    function test_fork_swap_oracleBound() public onFork {
        // 3,000 WETH into a pool holding ~$14M of USDC: far past 1% of price impact
        deal(Arbitrum.WETH, address(vault), 3_000e18);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.SwapShort.selector);
        vault.swap(true, 3_000e18, 0);
        // a caller's minimum above the pool's price, likewise
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.SwapShort.selector);
        vault.swap(true, 1e18, 100_000e6);
    }

    /// The oracle mocked 0.9% above the pool: each sale of WETH loses ~0.95% of its value (inside the
    /// 1% bound); the budget is 0.5% of equity per 24 hours.
    function test_fork_swap_dailyBudget() public onFork {
        uint256 px = IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.WETH);
        vm.mockCall(Arbitrum.ORACLE, abi.encodeCall(IOracle.getAssetPrice, (Arbitrum.WETH)), abi.encode(px * 10_090 / 10_000));
        deal(Arbitrum.WETH, address(vault), 10e18);
        uint256 t0 = vm.getBlockTimestamp(); // via-IR may keep `block.timestamp` across a warp
        vm.startPrank(key);
        vm.expectRevert(AaveV3AssetLegState.OverBudget.selector);
        vault.swap(true, 6e18, 0); // ~0.57% of equity
        vault.swap(true, 2e18, 0); // ~0.19%
        vault.swap(true, 2e18, 0); // ~0.38% in all
        vm.expectRevert(AaveV3AssetLegState.OverBudget.selector);
        vault.swap(true, 2e18, 0); // would pass 0.5%
        // two day buckets, both counted: tomorrow still remembers today
        vm.warp(t0 + 1 days);
        vm.expectRevert(AaveV3AssetLegState.OverBudget.selector);
        vault.swap(true, 2e18, 0);
        vm.warp(t0 + 2 days);
        vault.swap(true, 2e18, 0); // today's losses have aged out
        vm.stopPrank();
    }

    function _rwcBound(uint256 debt) internal view returns (uint256) {
        uint256 pw = IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.WETH);
        uint256 pu = IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.USDC);
        return debt * pu * 1e12 * 10_100 / (pw * 10_000);
    }

    function test_fork_repayWithCollateral_refusedPastTheBound() public onFork {
        _lever(vault);
        uint256 bound = _rwcBound(1_000e6);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.AboveBound.selector);
        vault.repayWithCollateral(1_000e6, bound + 1e12);
    }

    /// The oracle mocked 0.5% above the pool: the collateral sold is worth ~0.6% more than the debt
    /// repaid (inside the 1% bound), and this vault's budget is 0.01% of its equity.
    function test_fork_repayWithCollateral_refusedPastTheBudget() public onFork {
        IAssetLegV1 tight = _createVault(keccak256("tight"), _config(1));
        _leverWithoutSwaps(tight);
        uint256 px = IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.WETH);
        vm.mockCall(Arbitrum.ORACLE, abi.encodeCall(IOracle.getAssetPrice, (Arbitrum.WETH)), abi.encode(px * 10_050 / 10_000));
        uint256 bound = _rwcBound(1_000e6);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.OverBudget.selector);
        tight.repayWithCollateral(1_000e6, bound);
        // the same call on a vault with room in its budget goes through
        IAssetLegV1 roomy = _createVault(keccak256("roomy"), _config(100));
        _leverWithoutSwaps(roomy);
        vm.prank(key);
        roomy.repayWithCollateral(1_000e6, bound);
        assertGt(roomy.lossInWindow(), 0);
    }

    /// The account read mocked (before, equity, after): a health factor lower afterwards is refused.
    function test_fork_repayWithCollateral_refusedWhenHealthFalls() public onFork {
        _leverWithoutSwaps(vault);
        uint256 bound = _rwcBound(1_000e6);
        (uint256 c, uint256 d, uint256 ab, uint256 lt, uint256 ltv,) = pool.getUserAccountData(address(vault));
        bytes[] memory answers = new bytes[](3);
        answers[0] = abi.encode(c, d, ab, lt, ltv, uint256(2e18));
        answers[1] = abi.encode(c, d, ab, lt, ltv, uint256(2e18));
        answers[2] = abi.encode(c, d, ab, lt, ltv, uint256(1.9e18));
        vm.mockCalls(Arbitrum.POOL, abi.encodeCall(IPoolx.getUserAccountData, (address(vault))), answers);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.HealthFell.selector);
        vault.repayWithCollateral(1_000e6, bound);
    }

    // ── the exit (§8.4) ──────────────────────────────────────────────────────────────────────────────

    function test_fork_exit_byTheOwner_fromALeveredPosition_toTheWithdrawalAddress() public onFork {
        _lever(vault);
        uint256 deadline = block.timestamp + 1 hours;
        vault.beginExit(deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, deadline))));
        assertTrue(vault.exiting());
        assertTrue(hub.exiting(), "the hub, told directly");
        assertFalse((vault.toldPending() != 0), "Circle's sendMessage went");
        vm.prank(key);
        vm.expectRevert(MemberState.Exiting.selector);
        vault.send(0, 1, false, 0);
        vm.startPrank(stranger);
        IAssetLegV1(address(vault)).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault)), 0);
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        // 5,000 USDC went in; the round trip costs fees and spreads, a few tens of dollars
        uint256 atHub = usdc.balanceOf(address(hub));
        assertGt(atHub, 4_900e6, "everything to the hub beside it");
        assertEq(hub.receivedFrom(0), atHub);
        hub.exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), atHub);
        assertEq(usdc.balanceOf(address(owner)), 0, "the exit pays the withdrawal address, not the account");
        vm.stopPrank();
        // what the Hyperliquid leg sends in later goes the same way
        _usdc(address(vault), 123e6);
        IAssetLegV1(address(vault)).exitStep(0, 0);
        hub.exitStep();
        assertGt(usdc.balanceOf(withdrawalTo), 5_000e6);
    }

    function test_fork_exit_byAStranger_after7DaysWithoutCheckIn() public onFork {
        _lever(vault);
        vm.expectRevert(MemberState.GroupNotStopped.selector);
        vault.beginExitStopped();
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.startPrank(stranger);
        vault.beginExitStopped();
        IAssetLegV1(address(vault)).exitStep(1_000e6, 0); // in chunks, as a stranger may
        IAssetLegV1(address(vault)).exitStep(0, 0);
        hub.exitStep();
        vm.stopPrank();
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault)), 0);
        assertGt(usdc.balanceOf(withdrawalTo), 4_800e6);
    }

    /// Told by the Hyperliquid leg's message, the AAVE leg tells nobody: that leg tells the hub itself.
    function test_fork_exit_fromAMembersMessage() public onFork {
        bytes memory body = abi.encode(vault.EXIT_MESSAGE());
        bytes32 from = bytes32(uint256(uint160(vault.links(1))));
        vm.prank(stranger);
        vm.expectRevert(MemberState.BadMessage.selector);
        vault.handleReceiveFinalizedMessage(19, from, 2000, body);
        vm.prank(TRANSMITTER);
        vault.handleReceiveFinalizedMessage(19, from, 2000, body);
        assertTrue(vault.exiting());
        assertFalse(hub.exiting());
        vm.prank(TRANSMITTER);
        hub.handleReceiveFinalizedMessage(19, from, 2000, body);
        assertTrue(hub.exiting());
    }

    /// Circle paused (its pauser impersonated): the exit commits locally, the partner pending.
    function test_fork_circlePaused_exitCommits_notifyLater() public onFork {
        address pauser = ITransmitter(TRANSMITTER).pauser();
        vm.prank(pauser);
        ITransmitter(TRANSMITTER).pause();
        uint256 deadline = block.timestamp + 1 hours;
        vault.beginExit(deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, STRATEGY, deadline))));
        assertTrue(vault.exiting());
        assertTrue(hub.exiting(), "the hub beside it needs no Circle");
        assertEq(vault.toldPending(), 2, "the Hyperliquid leg pending");
        vm.expectRevert();
        vault.notifyLink(1);
        vm.prank(pauser);
        ITransmitter(TRANSMITTER).unpause();
        vm.prank(stranger);
        vault.notifyLink(1);
        assertFalse((vault.toldPending() != 0));
    }

    /// Two strategies of the same owner: two hubs and two Hyperliquid legs, each member wired to its own.
    function test_fork_twoStrategies_twoMeshes() public onFork {
        IAssetLegV1 other = _createVault(keccak256("strategy-2"), _config(50));
        assertTrue(other.links(0) != vault.links(0));
        assertTrue(other.links(1) != vault.links(1));
        (address[] memory at,) = factory.memberAddresses(keccak256("strategy-2"), address(owner), _config(50));
        assertEq(address(other), at[1]);
        assertEq(other.links(0), at[0]);
        assertEq(other.links(1), at[2]);
        _usdc(address(vault), 10e6);
        _usdc(address(other), 10e6);
        vm.startPrank(key);
        vault.send(1, 10e6, false, 0);
        other.send(1, 10e6, false, 0);
        vm.stopPrank();
    }

    // ── the exit's unwinding (the review's fourth finding and minor 10) ─────────────────────────────

    /// Anyone may supply on the vault's behalf: USDC collateral the key never supplied.
    function _supplyUsdcFor(address v, uint256 amount) internal {
        _usdc(stranger, amount);
        vm.startPrank(stranger);
        usdc.approve(Arbitrum.POOL, amount);
        pool.supply(Arbitrum.USDC, amount, v, 0);
        vm.stopPrank();
    }

    function _beginExit(IAssetLegV1 v, bytes32 id) internal {
        uint256 deadline = block.timestamp + 1 hours;
        v.beginExit(deadline, _sign(keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, id, deadline))));
    }

    function test_fork_exit_usdcCollateral() public onFork {
        _supplyUsdcFor(address(vault), 10_000e6);
        vm.prank(key);
        vault.borrow(5_000e6);
        _takeOut(vault, 5_000e6); // the borrowed USDC leaves; the debt stays against USDC collateral
        _beginExit(vault, STRATEGY);
        IAssetLegV1(address(vault)).exitStep(0, 0);
        hub.exitStep();
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault)), 0, "repaid with its aUSDC");
        assertEq(IERC20x(Arbitrum.A_USDC).balanceOf(address(vault)), 0);
        assertApproxEqAbs(usdc.balanceOf(withdrawalTo), 5_000e6, 2e6);
    }

    function test_fork_exit_mixedCollateral() public onFork {
        _leverWithoutSwaps(vault); // 3 WETH supplied, 3,000 USDC borrowed
        _supplyUsdcFor(address(vault), 2_000e6);
        _takeOut(vault, 3_000e6);
        _beginExit(vault, STRATEGY);
        IAssetLegV1(address(vault)).exitStep(0, 0);
        hub.exitStep();
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault)), 0);
        assertEq(IERC20x(Arbitrum.A_USDC).balanceOf(address(vault)), 0);
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertGt(usdc.balanceOf(withdrawalTo), 2_000e6 * 3); // 3 WETH less 1,000 USDC of debt
    }

    /// The flash loan unavailable (the receiver refuses): the non-flash fallback withdraws, sells within
    /// the bound and repays, never lowering the health factor.
    function test_fork_exit_withoutTheFlashLoan() public onFork {
        _leverWithoutSwaps(vault);
        _takeOut(vault, 3_000e6);
        vm.mockCallRevert(Arbitrum.RECEIVER, bytes(""), bytes("no flash liquidity"));
        _beginExit(vault, STRATEGY);
        uint256 hf = _health(address(vault));
        IAssetLegV1(address(vault)).exitStep(1_000e6, 0);
        // the sale of the collateral bound (the debt at the oracle + 1%) repaid a little over 1,000
        uint256 left = IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault));
        assertLe(left, 2_000e6);
        assertGe(left, 1_980e6);
        assertGe(_health(address(vault)), hf);
        IAssetLegV1(address(vault)).exitStep(0, 0);
        hub.exitStep();
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault)), 0);
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0);
        assertGt(usdc.balanceOf(withdrawalTo), 3_000e6);
    }

    /// The re-review: a withdrawal address USDC refuses (blacklisted) fails the hub's payment alone; the
    /// leg's unwinding still runs, and the USDC waits in the hub. Amendment 2d §5.2: the payout is its own
    /// self-call, so the hub's step no longer reverts: it logs `ExitSettleFailed` and keeps the USDC.
    function test_fork_exit_blacklistedWithdrawalAddress_stillUnwinds() public onFork {
        _lever(vault);
        IFiatToken fiat = IFiatToken(Arbitrum.USDC);
        vm.prank(fiat.blacklister());
        fiat.blacklist(withdrawalTo);
        _beginExit(vault, STRATEGY);
        IAssetLegV1(address(vault)).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault)), 0);
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0);
        assertGt(usdc.balanceOf(address(hub)), 4_900e6);
        vm.expectEmit(false, false, false, false, address(hub));
        emit Hub.ExitSettleFailed("");
        hub.exitStep();
        assertGt(usdc.balanceOf(address(hub)), 4_900e6, "the USDC waits for a payable address");
        assertEq(hub.exitPaid(), 0);
    }

    /// One part failing (the WETH reserve refusing withdrawals) doesn't hold the USDC already there.
    function test_fork_exit_paysWhatItHolds_whenAPartFails() public onFork {
        deal(Arbitrum.WETH, address(vault), 1e18);
        vm.prank(key);
        vault.supply(1e18);
        _usdc(address(vault), 100e6);
        vm.mockCallRevert(
            Arbitrum.POOL,
            abi.encodeCall(IPoolx.withdraw, (Arbitrum.WETH, type(uint256).max, address(vault))),
            bytes("reserve paused")
        );
        _beginExit(vault, STRATEGY);
        IAssetLegV1(address(vault)).exitStep(0, 0);
        hub.exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), 100e6);
        assertGt(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)), 0, "the WETH waits for its reserve");
    }

    // ── readiness and mints through Circle's real transmitter (amendment 2a §3.6, §9) ─────────────────────

    function _attest(bytes memory message, uint256 attesterPk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterPk, keccak256(message));
        return abi.encodePacked(r, s, v);
    }

    /// A finalized V2 message from `from` on HyperEVM, signed by an attester this test enables (the
    /// attester manager impersonated): the layout MessageTransmitterV2 parses.
    function _circleReady(address from, address to, bytes32 nonce, uint256 attesterPk)
        internal
        pure
        returns (bytes memory message, bytes memory attestation)
    {
        message = abi.encodePacked(
            uint32(1), // version
            uint32(19), // source: HyperEVM
            uint32(3), // destination: Arbitrum
            nonce,
            bytes32(uint256(uint160(from))),
            bytes32(uint256(uint160(to))),
            bytes32(0), // anyone may relay
            uint32(2000),
            uint32(2000),
            abi.encode(keccak256("dltx.strategy-vault.ready.v1"))
        );
        attestation = _attest(message, attesterPk);
    }

    function _enableAttester() internal returns (uint256 pk) {
        address attester;
        (attester, pk) = makeAddrAndKey("test-attester");
        ITransmitterAdmin t = ITransmitterAdmin(TRANSMITTER);
        vm.startPrank(t.attesterManager());
        t.enableAttester(attester);
        t.setSignatureThreshold(1);
        vm.stopPrank();
    }

    /// The Hyperliquid leg's READY reaches an AAVE leg not created yet: Circle can't deliver it (no
    /// handler there); the same message, relayed after it exists, is delivered, and the leg may then send.
    function test_ready_relayedByCircle_onceTheMemberExists() public onFork {
        uint256 pk = _enableAttester();
        StrategySpec memory c = _config(50);
        bytes32 id = keccak256("strategy-ready");
        (address[] memory at,) = factory.memberAddresses(id, address(owner), c);
        (bytes memory message, bytes memory attestation) = _circleReady(at[2], at[1], keccak256("nonce-1"), pk);
        vm.expectRevert();
        ITransmitterAdmin(TRANSMITTER).receiveMessage(message, attestation);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig =
            _signDigest(factory.createDigest(id, address(owner), c, deadline));
        IAssetLegV1 leg = IAssetLegV1((factory.create(id, address(owner), c, deadline, sig)[1]));
        assertEq(address(leg), at[1]);
        assertFalse(leg.ready(1));
        _usdc(address(leg), 100e6);
        vm.prank(key);
        vm.expectRevert(MemberState.NotReady.selector);
        leg.send(1, 100e6, false, 0);
        vm.prank(stranger);
        assertTrue(ITransmitterAdmin(TRANSMITTER).receiveMessage(message, attestation));
        assertTrue(leg.ready(1));
        vm.prank(key);
        leg.send(1, 100e6, false, 0);
        assertEq(usdc.balanceOf(address(leg)), 0);
    }

    /// Each member's own READY at creation went through Circle's real `sendMessage`, finalized, to the
    /// Hyperliquid leg: the hub's, then the AAVE leg's.
    function test_ready_sentAtCreation_throughCircle() public onFork {
        vm.recordLogs();
        IAssetLegV1 v = _createVault(keccak256("strategy-logs"), _config(50));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sent;
        bytes[] memory messages = new bytes[](2);
        uint256 m;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("ReadySent(uint8)")) sent++;
            if (logs[i].emitter == TRANSMITTER && logs[i].topics[0] == keccak256("MessageSent(bytes)")) {
                messages[m++] = abi.decode(logs[i].data, (bytes));
            }
        }
        assertEq(sent, 2, "ReadySent from the hub and the AAVE leg");
        assertEq(m, 2);
        address[2] memory from = [v.links(0), address(v)];
        for (uint256 i; i < 2; ++i) {
            bytes memory message = messages[i];
            // MessageTransmitterV2's layout: version 4 | source 4 | destination 4 | nonce 32 | sender 32 |
            // recipient 32 | destination caller 32 | min finality 4 | finality executed 4 | body
            assertEq(uint32(bytes4(_slice(message, 4, 4))), 3, "from Arbitrum");
            assertEq(uint32(bytes4(_slice(message, 8, 4))), 19, "to HyperEVM");
            assertEq(bytes32(_slice(message, 44, 32)), bytes32(uint256(uint160(from[i]))));
            assertEq(bytes32(_slice(message, 76, 32)), bytes32(uint256(uint160(v.links(1)))), "to the Hyperliquid leg");
            assertEq(bytes32(_slice(message, 108, 32)), bytes32(0), "anyone may relay it");
            assertEq(uint32(bytes4(_slice(message, 140, 4))), 2000, "finalized");
            assertEq(_slice(message, 148, message.length - 148), abi.encode(v.READY_MESSAGE()));
        }
    }

    /// A CCTP V2 burn from HyperEVM's TokenMessenger: `from` burned `amount` of HyperEVM's USDC, the mint
    /// bound to `to` (its recipient and only caller).
    function _burnFromHyperEvm(address from, address to, uint256 amount, uint256 fee, uint32 finality, bytes32 nonce)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 messenger = bytes32(uint256(uint160(TOKEN_MESSENGER))); // the same address on both chains
        bytes32 bound = bytes32(uint256(uint160(to)));
        return abi.encodePacked(
            abi.encodePacked(uint32(1), uint32(19), uint32(3), nonce, messenger, messenger, bound, finality, finality),
            abi.encodePacked(
                uint32(1),
                bytes32(uint256(uint160(0xb88339CB7199b77E23DB6E890353E22632Ba630f))), // HyperEVM's USDC
                bound,
                amount,
                bytes32(uint256(uint160(from))),
                fee, // maxFee
                fee, // feeExecuted
                uint256(0) // no expiration
            )
        );
    }

    /// Decision 44 on Circle's real contracts: the Hyperliquid leg's burn to the hub is completed only by
    /// the hub (`receiveMint`, anyone may call it), and counted there gross with Circle's fee apart; a
    /// stranger relaying the message to Circle directly is refused, and a replay is refused by its nonce.
    function test_fork_receiveMint_boundBurnFromTheHyperliquidLeg() public onFork {
        uint256 pk = _enableAttester();
        address hl = hub.links(1);
        bytes memory message = _burnFromHyperEvm(hl, address(hub), 250e6, 0.03e6, 1000, keccak256("burn-1"));
        bytes memory attestation = _attest(message, pk);
        vm.prank(stranger);
        vm.expectRevert(bytes("Invalid caller for message"));
        ITransmitterAdmin(TRANSMITTER).receiveMessage(message, attestation);
        vm.prank(stranger);
        hub.receiveMint(message, attestation);
        assertEq(usdc.balanceOf(address(hub)), 250e6 - 0.03e6);
        assertEq(hub.receivedFrom(1), 250e6, "gross");
        assertEq(hub.feesFrom(1), 0.03e6);
        vm.expectRevert();
        hub.receiveMint(message, attestation);
        // finalized, no fee; to the AAVE leg, which completes it through its module, in exit too
        _beginExit(vault, STRATEGY);
        message = _burnFromHyperEvm(hl, address(vault), 40e6, 0, 2000, keccak256("burn-2"));
        IAssetLegV1(address(vault)).receiveMint(message, _attest(message, pk));
        assertEq(vault.receivedFrom(1), 40e6);
        assertEq(usdc.balanceOf(address(vault)), 40e6);
        // a burn by someone else, bound to the hub: minted, uncounted
        message = _burnFromHyperEvm(stranger, address(hub), 5e6, 0, 2000, keccak256("burn-3"));
        hub.receiveMint(message, _attest(message, pk));
        assertEq(hub.receivedFromOthers(), 5e6);
        assertEq(hub.receivedFrom(1), 250e6);
    }

    /// The security review's C-1 on Circle's real transmitter: a GENERAL message laid out as a burn from
    /// the Hyperliquid leg, bound to the hub, but addressed to a handler of the attacker's (Circle attests
    /// any message and checks a burn's sender only for its own TokenMessenger), would set the hub's
    /// counters to anything and overflow them for every real mint after. The hub refuses it.
    function test_fork_receiveMint_refusesAForgedGeneralMessage() public onFork {
        uint256 pk = _enableAttester();
        FakeHandler fake = new FakeHandler();
        bytes memory message = _burnFromHyperEvm(hub.links(1), address(hub), type(uint256).max - 1e6, 0, 2000, keccak256("forged"));
        bytes32 to = bytes32(uint256(uint160(address(fake))));
        assembly ("memory-safe") {
            mstore(add(message, add(32, 76)), to) // the header's recipient
        }
        bytes memory attestation = _attest(message, pk);
        vm.prank(stranger);
        vm.expectRevert(MemberState.BadMessage.selector);
        hub.receiveMint(message, attestation);
        assertEq(hub.receivedFrom(1), 0);
        // the genuine burn after it still lands and counts
        message = _burnFromHyperEvm(hub.links(1), address(hub), 9e6, 0, 2000, keccak256("genuine"));
        hub.receiveMint(message, _attest(message, pk));
        assertEq(hub.receivedFrom(1), 9e6);
    }

    /// The AAVE leg's report reaches its hub directly: its holdings read from AAVE, its counters, a
    /// sequence number the hub keeps the highest of.
    function test_fork_report_toTheHubBeside_it() public onFork {
        _lever(vault);
        _usdc(address(vault), 77e6);
        vm.prank(key);
        vault.send(0, 7e6, false, 0);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(stranger);
        IAssetLegV1(address(vault)).report();
        (uint64 seq, uint64 observedAt, uint64 receivedAt, bytes memory body) = hub.reportOf(0);
        assertEq(seq, 1);
        assertEq(observedAt, block.timestamp);
        assertEq(receivedAt, block.timestamp);
        (,,,,, Holding[] memory h, uint256[4] memory sentTo,,) = abi.decode(body, (bytes32, uint256, uint256, uint256, uint256, Holding[], uint256[4], uint256[4], uint256[4]));
        assertEq(h.length, 2);
        assertEq(h[0].asset, Assets.ETH);
        assertEq(
            h[0].quantity,
            int256(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)) + weth.balanceOf(address(vault)))
        );
        assertEq(h[1].asset, Assets.USD);
        int256 usd = int256(usdc.balanceOf(address(vault)) + IERC20x(Arbitrum.A_USDC).balanceOf(address(vault)))
            - int256(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(address(vault)));
        assertEq(h[1].quantity, usd * 1e12);
        assertLt(h[1].quantity, 0, "levered: the debt outweighs the USDC");
        assertEq(sentTo[0], 7e6);
        IAssetLegV1(address(vault)).report();
        (seq,,,) = hub.reportOf(0);
        assertEq(seq, 2);
    }

    // ── amendment 2b: the fee's value on Arbitrum's real AAVE, Chainlink and Circle ─────────────────────

    /// The Hyperliquid leg's report reaching the hub, Circle's transmitter impersonated: its holdings and
    /// its counters toward the hub (link 0 of the leg), observed now.
    uint256 hlSeq;

    function _hlReport(int256 usd18, int256 eth18, uint256 sentToHub, uint256 fromHub) internal {
        Holding[] memory h = new Holding[](2);
        h[0] = Holding(Assets.USD, usd18);
        h[1] = Holding(Assets.ETH, eth18);
        uint256[4] memory sent;
        uint256[4] memory received;
        uint256[4] memory fees;
        (sent[0], received[0]) = (sentToHub, fromHub);
        bytes memory body = abi.encode(
            keccak256("dltx.strategy-vault.report.v1"), ++hlSeq, vm.getBlockTimestamp(), uint256(1_000), uint256(0), h, sent, received, fees
        );
        bytes32 hl = bytes32(uint256(uint160(hub.links(1))));
        vm.prank(TRANSMITTER);
        hub.handleReceiveFinalizedMessage(19, hl, 2000, body);
    }

    /// A snapshot of the AAVE leg now, then the Hyperliquid leg's report 90 s later.
    function _feeInstant(int256 hlUsd18, int256 hlEth18, uint256 sentToHub, uint256 fromHub) internal {
        vm.prank(key);
        HubFee(address(hub)).snapshot();
        vm.warp(vm.getBlockTimestamp() + 90);
        _hlReport(hlUsd18, hlEth18, sentToHub, fromHub);
    }

    function _latestRound() internal view returns (uint80[] memory r, uint256 price18) {
        (uint80 id, int256 answer,,,) = IChainlinkFeed(FeePins.ETH_USD).latestRoundData();
        r = new uint80[](1);
        r[0] = id;
        price18 = uint256(answer) * 1e10;
    }

    /// The hub's snapshot records the AAVE leg's live holdings (aWETH and WETH as ETH; USDC and aUSDC
    /// less the variable debt as USD, each token's `balanceOf` as AAVE accounts it): valued at AAVE's own
    /// oracle they are its `getUserAccountData` to 1e-8 USD (the fork probe's agreement).
    function test_fork_fee_snapshotOfTheAaveLeg_agreesWithAave() public onFork {
        _lever(vault);
        vm.prank(key);
        HubFee(address(hub)).snapshot();
        (Holding[] memory h,,,,, uint64 ops, bool tracked) = abi.decode(
            hub.snapshotOf(0), (Holding[], uint256[4], uint256[4], uint64, uint64, uint64, bool)
        );
        assertTrue(tracked);
        assertEq(ops, vault.opCount());
        assertEq(ops, 8, "the loop's eight market calls");
        IOracle oracle = IOracle(Arbitrum.ORACLE);
        // AAVE's base currency: USD, 8 decimals
        int256 eth8 = h[0].quantity * int256(oracle.getAssetPrice(Arbitrum.WETH)) / 1e18;
        int256 usd8 = h[1].quantity / 1e12 * int256(oracle.getAssetPrice(Arbitrum.USDC)) / 1e6;
        (uint256 collateral, uint256 debt,,,,) = pool.getUserAccountData(address(vault));
        assertApproxEqAbs(eth8 + usd8, int256(collateral) - int256(debt), 2, "to 1e-8 USD (a unit each side)");
    }

    /// The value on today's pins: the AAVE leg by the snapshot, the Hyperliquid leg's report, ETH at
    /// Chainlink's real round in effect; the two legs' ETH cancels at one price and the value is their
    /// USD; the sequencer is up. `crystallize` charges nothing on the day of creation.
    function test_fork_fee_value_atChainlinksRound_ethCancels() public onFork {
        _lever(vault);
        (Holding[] memory h,,,,,,) = AaveV3AssetLegExit(address(vault)).holdings();
        int256 aaveUsd18 = h[1].quantity;
        int256 eth = h[0].quantity;
        _feeInstant(4_000e18, -eth, 0, 0); // the short: −ETH, $4,000 of cash
        (uint80[] memory r, uint256 p) = _latestRound();
        (bool ok, int256 v, bytes32 why) = HubFee(address(hub)).value(r);
        assertTrue(ok, string(abi.encodePacked(why)));
        int256 expected = FeeMath.floorDiv(
            FeeMath.mulPrice(eth, p) + aaveUsd18 + 4_000e18 + FeeMath.mulPrice(-eth, p), 1e12
        );
        assertEq(v, expected, "the hub's value is the mirror's");
        assertApproxEqAbs(v, (aaveUsd18 + 4_000e18) / 1e12, 1, "the ETH cancels: what is left is the cash");
        vm.prank(key);
        vm.expectRevert(HubState.TooSoon.selector);
        HubFee(address(hub)).crystallize(r);
    }

    /// The probe's F08 on Circle's real transmitter: a $2 burn from the Hyperliquid leg to the hub, its
    /// mint relayed before or after a report saw the burn: the value moves only by Circle's fee, whatever
    /// the order (the pair term negative when the hub's figures are the newer).
    function test_fork_fee_pairInFlight_throughReceiveMint_bothOrders() public onFork {
        uint256 pk = _enableAttester();
        (uint80[] memory r,) = _latestRound();
        int256 hlUsd = 31_402_812e12;
        // the report saw the burn (sentTo 2), the mint not relayed yet
        _feeInstant(hlUsd - 2e18, 0, 2e6, 0);
        (, int256 inFlight,) = HubFee(address(hub)).value(r);
        // the mint relayed: the hub holds it net of Circle's fee
        bytes memory message = _burnFromHyperEvm(hub.links(1), address(hub), 2e6, 280, 1000, keccak256("f08"));
        hub.receiveMint(message, _attest(message, pk));
        (, int256 minted,) = HubFee(address(hub)).value(r);
        assertEq(minted, inFlight - 280, "only Circle's fee");
        // the other order: a second $2 burn whose mint lands BEFORE the leg's report saw it
        message = _burnFromHyperEvm(hub.links(1), address(hub), 2e6, 280, 1000, keccak256("f08-b"));
        hub.receiveMint(message, _attest(message, pk));
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        _feeInstant(hlUsd - 2e18, 0, 2e6, 0); // the leg's figures still from before the second burn
        (, int256 early,) = HubFee(address(hub)).value(r);
        assertEq(early, minted - 280, "the negative term cancels the double count");
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        _feeInstant(hlUsd - 4e18, 0, 4e6, 0);
        (, int256 seen,) = HubFee(address(hub)).value(r);
        assertEq(seen, early, "equal once the report saw it");
        assertEq(seen, 31_402_812 - 560, "the probe's value, less Circle's two fees");
    }

    // ── amendment 2c: rewards on the lending leg ─────────────────────────────────────────────────────

    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address constant A_ARB = 0x6533afac2E7BCCB20dca161449A13A32D391fb00;

    /// aArbARB reaches `to` as Merkl's PullTokenWrapper delivers it (§3.4): a campaign holder's aArbARB
    /// pulled by a third party (`transferFrom(holder, to)`, the wrapper's own call), AAVE's transfer path.
    function _aArbArrives(address to, uint256 amount) internal {
        address holder = makeAddr("campaign-holder");
        address wrapper = makeAddr("pull-token-wrapper");
        deal(ARB, holder, amount);
        vm.startPrank(holder);
        IERC20x(ARB).approve(Arbitrum.POOL, amount);
        pool.supply(ARB, amount, holder, 0);
        IERC20x(A_ARB).approve(wrapper, type(uint256).max);
        vm.stopPrank();
        uint256 held = IERC20x(A_ARB).balanceOf(holder);
        vm.prank(wrapper);
        (bool ok,) = A_ARB.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, held));
        require(ok, "transferFrom");
    }

    function _collateralOn(address user, address asset) internal view returns (bool) {
        uint256 id = pool.getReserveData(asset).id;
        return (pool.getUserConfiguration(user) >> (id * 2)) & 2 != 0;
    }

    /// R1 (§3.4, the build's gate): an LTV-0 aToken arriving by transfer is not enabled as collateral,
    /// and the leg's WETH stays withdrawable, in e-mode 0 (production's: no category pairs WETH with
    /// native USDC on Arbitrum).
    function test_fork_R1_rewardATokenArriving_isNotCollateral() public onFork {
        address v = address(vault);
        _leverWithoutSwaps(vault);
        assertTrue(_collateralOn(v, Arbitrum.WETH));
        assertEq(pool.getReserveData(ARB).aTokenAddress, A_ARB, "the pinned aToken is ARB's");
        _aArbArrives(v, 1_000e18);
        assertApproxEqAbs(IERC20x(A_ARB).balanceOf(v), 1_000e18, 2);
        assertFalse(_collateralOn(v, ARB), "R1: aArbARB arrives disabled as collateral");
        uint256 hf = _health(v);
        vm.prank(key);
        vault.withdraw(Arbitrum.WETH, 0.1e18);
        assertLt(_health(v), hf, "the WETH withdrawal went through");
        // and on a leg with nothing yet (the first balance of any reserve)
        IAssetLegV1 fresh = _createVault(keccak256("strategy-r1"), _config(50));
        _aArbArrives(address(fresh), 10e18);
        assertFalse(_collateralOn(address(fresh), ARB), "R1: nor on an empty leg");
    }

    address constant MERKL_GOVERNOR = 0x3350bef226F7BdCA874C5561320aB7EF9DC89E70;

    function _arb(address to, uint256 amount) internal {
        deal(ARB, to, IERC20x(ARB).balanceOf(to) + amount);
    }

    /// A two-leaf Merkl tree set by Merkl's governor and past its dispute period: `amountArb` of ARB and
    /// `amountWrapped` of a PullTokenWrapper delivering aArbARB, both cumulative for `user`. Returns the
    /// wrapper and each leaf's one-hash proof.
    function _merklTree(address user, uint256 amountArb, uint256 amountWrapped)
        internal
        returns (address wrapper, bytes32[] memory proofArb, bytes32[] memory proofWrapped)
    {
        address holder = makeAddr("drip-holder");
        _aArbArrives(holder, amountWrapped + 1e18);
        wrapper = address(new MockPullTokenWrapper(A_ARB, holder, Arbitrum.MERKL_DISTRIBUTOR));
        vm.prank(holder);
        IERC20x(A_ARB).approve(wrapper, type(uint256).max);
        _arb(Arbitrum.MERKL_DISTRIBUTOR, amountArb);
        bytes32 la = keccak256(abi.encode(user, ARB, amountArb));
        bytes32 lw = keccak256(abi.encode(user, wrapper, amountWrapped));
        bytes32 root = la < lw ? keccak256(abi.encode(la, lw)) : keccak256(abi.encode(lw, la));
        vm.prank(MERKL_GOVERNOR);
        IMerkl(Arbitrum.MERKL_DISTRIBUTOR).updateTree(IMerkl.MerkleTree(root, bytes32(0)));
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        assertEq(IMerkl(Arbitrum.MERKL_DISTRIBUTOR).getMerkleRoot(), root, "past the dispute period");
        proofArb = new bytes32[](1);
        proofArb[0] = lw;
        proofWrapped = new bytes32[](1);
        proofWrapped[0] = la;
    }

    function _claimMerkl(address caller, IAssetLegV1 v, uint256 amountArb, uint256 amountWrapped) internal {
        (address wrapper, bytes32[] memory pa, bytes32[] memory pw) = _merklTree(address(v), amountArb, amountWrapped);
        address[] memory tokens = new address[](2);
        tokens[0] = ARB;
        tokens[1] = wrapper;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountArb;
        amounts[1] = amountWrapped;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = pa;
        proofs[1] = pw;
        vm.prank(caller);
        IAssetLegV1(address(v)).claimMerkl(tokens, amounts, proofs);
    }

    function _held(address v) internal view returns (uint256) {
        return IERC20x(ARB).balanceOf(v) + IERC20x(A_ARB).balanceOf(v);
    }

    function _arbValueInUsdc(uint256 arbAmount) internal view returns (uint256) {
        (, int256 p,,,) = IChainlinkFeed(Arbitrum.REWARD_FEED).latestRoundData();
        return arbAmount * uint256(p) * 1e6 / (IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.USDC) * 1e18);
    }

    function test_fork_2c_pins() public onFork {
        assertEq(IAToken(Arbitrum.A_WETH).getIncentivesController(), Arbitrum.REWARDS_CONTROLLER);
        assertEq(IAToken(Arbitrum.A_USDC).getIncentivesController(), Arbitrum.REWARDS_CONTROLLER);
        assertEq(IAToken(Arbitrum.VDEBT_USDC).getIncentivesController(), Arbitrum.REWARDS_CONTROLLER);
        assertEq(pool.getReserveData(Arbitrum.REWARD).aTokenAddress, Arbitrum.A_REWARD);
        assertEq(IUniPool(Arbitrum.REWARD_POOL).token0(), Arbitrum.REWARD);
        assertEq(IUniPool(Arbitrum.REWARD_POOL).token1(), Arbitrum.USDC);
        assertEq(IUniPool(Arbitrum.REWARD_POOL).fee(), 3000);
        (, int256 p,,,) = IChainlinkFeed(Arbitrum.REWARD_FEED).latestRoundData();
        assertGt(p, 0);
        assertEq(Arbitrum.SEQUENCER, FeePins.SEQUENCER);
        assertTrue(IMerkl(Arbitrum.MERKL_DISTRIBUTOR).getMerkleRoot() != bytes32(0));
        (address[2] memory sources, address reward,, address rpool, address feed, uint256 maxAge, uint256 boundBp) =
            IAssetLegV1(address(vault)).rewardPins();
        assertEq(sources[0], Arbitrum.REWARDS_CONTROLLER);
        assertEq(sources[1], Arbitrum.MERKL_DISTRIBUTOR);
        assertEq(reward, ARB);
        assertEq(rpool, Arbitrum.REWARD_POOL);
        assertEq(feed, Arbitrum.REWARD_FEED);
        assertEq(maxAge, 25 hours);
        assertEq(boundBp, 100);
    }

    /// Merkl's real distributor: ARB plainly, and aArbARB through a wrapper (§3.3, §3.4); the leg the only
    /// recipient, `RewardClaimed` the balance change, `opCount` counted, aArbARB not collateral.
    function test_fork_2c_claimMerkl_plainAndWrapped() public onFork {
        address v = address(vault);
        _leverWithoutSwaps(vault);
        uint64 ops = vault.opCount();
        vm.recordLogs();
        _claimMerkl(key, vault, 300e18, 200e18);
        assertEq(IERC20x(ARB).balanceOf(v), 300e18);
        assertApproxEqAbs(IERC20x(A_ARB).balanceOf(v), 200e18, 2);
        assertEq(vault.opCount(), ops + 1);
        assertFalse(_collateralOn(v, ARB));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == v && logs[i].topics[0] == AaveV3AssetLegState.RewardClaimed.selector) {
                (uint8 source, uint256 gained) = abi.decode(logs[i].data, (uint8, uint256));
                assertEq(source, 2);
                assertApproxEqAbs(gained, 500e18, 2);
                seen = true;
            }
        }
        assertTrue(seen, "RewardClaimed");
    }

    /// AAVE's RewardsController: an ARB emission on aUSDC re-opened by the emission manager, claimed to the leg.
    function test_fork_2c_claimRewards_aave() public onFork {
        address v = address(vault);
        IRewardsCtl rc = IRewardsCtl(Arbitrum.REWARDS_CONTROLLER);
        _supplyUsdcFor(v, 10_000e6);
        vm.startPrank(rc.getEmissionManager());
        rc.setDistributionEnd(Arbitrum.A_USDC, ARB, uint32(block.timestamp + 30 days));
        address[] memory rewards = new address[](1);
        rewards[0] = ARB;
        uint88[] memory eps = new uint88[](1);
        eps[0] = 1e16;
        rc.setEmissionPerSecond(Arbitrum.A_USDC, rewards, eps);
        vm.stopPrank();
        address rewardsVault = IPullStrategy(rc.getTransferStrategy(ARB)).getRewardsVault();
        _arb(rewardsVault, 1_000_000e18);
        vm.prank(rewardsVault);
        IERC20x(ARB).approve(rc.getTransferStrategy(ARB), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint64 ops = vault.opCount();
        vm.prank(key);
        IAssetLegV1(v).claimRewards();
        assertGt(IERC20x(ARB).balanceOf(v), 0, "the leg's share of a day's emission");
        assertEq(vault.opCount(), ops + 1);
        // nothing configured: a claim of nothing
        vm.prank(key);
        IAssetLegV1(v).claimRewards();
    }

    /// The sale (§3.5): from ARB and from aArbARB, at no less than the feed less 1 %, the shortfall counted.
    function test_fork_2c_swapReward_fromArbAndAArb() public onFork {
        address v = address(vault);
        _leverWithoutSwaps(vault);
        _arb(v, 1_000e18);
        _aArbArrives(v, 2_000e18);
        uint256 held = _held(v);
        uint256 fair = _arbValueInUsdc(held);
        uint256 usdc0 = usdc.balanceOf(v);
        uint256 hf = _health(v);
        uint64 ops = vault.opCount();
        uint256 g = gasleft();
        vm.prank(key);
        uint256 out = IAssetLegV1(v).swapReward(type(uint256).max, 0);
        emit log_named_uint("swapReward, aArbARB withdrawn and ARB sold, gas", g - gasleft());
        assertEq(_held(v), 0, "everything held, aArbARB withdrawn");
        assertEq(usdc.balanceOf(v) - usdc0, out);
        assertGe(out, fair * 99 / 100, "at least the feed less 1 %");
        assertGe(_health(v), hf, "the withdrawal of aArbARB moves no health");
        assertGt(vault.lossInWindow(), 0, "the shortfall counted in the budget");
        assertEq(vault.opCount(), ops + 1);
        // a part: aArbARB first withdrawn only for what plain ARB lacks
        _arb(v, 10e18);
        _aArbArrives(v, 10e18);
        vm.prank(key);
        IAssetLegV1(v).swapReward(15e18, 0);
        assertEq(IERC20x(ARB).balanceOf(v), 0);
        assertApproxEqAbs(IERC20x(A_ARB).balanceOf(v), 5e18, 2);
    }

    /// Decision 63: a leg with no equity still sells its reward; the budget counts, never refuses.
    function test_fork_2c_swapReward_counted_neverRefused() public onFork {
        IAssetLegV1 fresh = _createVault(keccak256("strategy-2c-empty"), _config(1));
        _arb(address(fresh), 500e18);
        vm.prank(key);
        IAssetLegV1(address(fresh)).swapReward(type(uint256).max, 0);
        assertGt(fresh.lossInWindow(), 0);
        assertGt(usdc.balanceOf(address(fresh)), 0);
    }

    function test_fork_2c_swapReward_refusals() public onFork {
        address v = address(vault);
        _arb(v, 1_000e18);
        // a price the pool can't meet: the feed answering twice the market
        (uint80 id, int256 p, uint256 st, uint256 up, uint80 ans) = IChainlinkFeed(Arbitrum.REWARD_FEED).latestRoundData();
        vm.mockCall(
            Arbitrum.REWARD_FEED,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(id, p * 2, st, up, ans)
        );
        vm.mockCall(
            Arbitrum.REWARD_FEED, abi.encodeWithSignature("getRoundData(uint80)", id), abi.encode(id, p * 2, st, up, ans)
        );
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.SwapShort.selector);
        IAssetLegV1(v).swapReward(type(uint256).max, 0);
        vm.clearMockedCalls();
        // the caller's own minimum stands above the floor
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.SwapShort.selector);
        IAssetLegV1(v).swapReward(1_000e18, type(uint128).max);
        // the sequencer down
        vm.mockCall(
            Arbitrum.SEQUENCER,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp - 2 hours, block.timestamp - 2 hours, uint80(1))
        );
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.StalePrice.selector);
        IAssetLegV1(v).swapReward(type(uint256).max, 0);
        vm.clearMockedCalls();
        // a feed older than 25 hours
        vm.warp(up + 25 hours + 1);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.StalePrice.selector);
        IAssetLegV1(v).swapReward(type(uint256).max, 0);
    }

    function test_fork_2c_whoMayCall() public onFork {
        address v = address(vault);
        _arb(v, 100e18);
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        IAssetLegV1(v).swapReward(type(uint256).max, 0);
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        IAssetLegV1(v).claimRewards();
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        IAssetLegV1(v).rewardCollateralOff();
        // paused changes nothing
        vm.prank(key);
        vault.pause(true);
        vm.prank(key);
        IAssetLegV1(v).swapReward(50e18, 0);
        // DLTX revoked: refused outside the exit
        uint256 deadline = block.timestamp + 1 hours;
        vault.ownerAction(
            OwnerMessages.REVOKE_EXECUTION,
            address(0),
            walletCred(wallet),
            deadline,
            _sign(
                keccak256(
                    abi.encode(
                        OwnerMessages.VAULT_ACTION_TYPEHASH, v, block.chainid, OwnerMessages.REVOKE_EXECUTION, address(0), vault.ownerNonceOf(walletCred(wallet)), deadline
                    )
                )
            )
        );
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        IAssetLegV1(v).swapReward(type(uint256).max, 0);
        // in exit: anyone
        _beginExit(vault, STRATEGY);
        vm.prank(stranger);
        IAssetLegV1(v).swapReward(type(uint256).max, 0);
        assertEq(_held(v), 0);
    }

    function test_fork_2c_callbacks_eachPoolItsOwnBranch() public onFork {
        _arb(address(vault), 100e18);
        deal(Arbitrum.WETH, address(vault), 1e18);
        vm.prank(Arbitrum.REWARD_POOL);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.uniswapV3SwapCallback(1e18, 0, "");
        vm.prank(Arbitrum.SWAP_POOL);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.uniswapV3SwapCallback(1e18, 0, "");
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.uniswapV3SwapCallback(1e18, 0, "");
    }

    /// AAVE's own bitmap of `user`, written in the pool's storage (aArbARB can't be enabled through the
    /// pool: an LTV-0 reserve is refused as collateral). The mapping's slot is found by matching a live
    /// account's bitmap.
    function _setCollateral(address user, address asset, bool on) internal {
        uint256 cfg = pool.getUserConfiguration(user);
        require(cfg != 0, "a live account");
        uint256 slot = type(uint256).max;
        for (uint256 i; i < 300; ++i) {
            if (uint256(vm.load(Arbitrum.POOL, keccak256(abi.encode(user, i)))) == cfg) {
                slot = i;
                break;
            }
        }
        require(slot != type(uint256).max, "the users' configuration slot");
        uint256 bit = 2 << (pool.getReserveData(asset).id * 2);
        cfg = on ? cfg | bit : cfg & ~bit;
        vm.store(Arbitrum.POOL, keccak256(abi.encode(user, slot)), bytes32(cfg));
        assertEq(_collateralOn(user, asset), on);
    }

    /// aArbARB really on as collateral (§3.4): the sale refused; the WETH withdrawal AAVE then blocks;
    /// in an exit with debt, no flash liquidity and a stale reward feed, part 9 turns it off for good and
    /// the non-flash fallback unwinds.
    function test_fork_2c_collateralOn_exitTurnsItOff_andUnwinds() public onFork {
        address v = address(vault);
        _leverWithoutSwaps(vault);
        _aArbArrives(v, 1_000e18);
        _setCollateral(v, ARB, true);
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.RewardCollateralOn.selector);
        IAssetLegV1(v).swapReward(type(uint256).max, 0);
        vm.prank(key);
        (bool withdrew,) = v.call(abi.encodeCall(IAssetLegV1.withdraw, (Arbitrum.WETH, 0.1e18)));
        emit log_named_string("WETH withdrawal with LTV-0 collateral on", withdrew ? "allowed" : "refused by AAVE");
        _beginExit(vault, STRATEGY);
        vm.warp(vm.getBlockTimestamp() + 26 hours); // the reward's feed stale: part 8 fails
        vm.mockCallRevert(Arbitrum.RECEIVER, bytes(""), "no flash liquidity"); // part 3 fails
        vm.prank(stranger);
        IAssetLegV1(v).exitStep(0, 0);
        assertFalse(_collateralOn(v, ARB), "part 9 committed although part 8 failed");
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0, "the non-flash fallback unwound the debt");
        assertGt(IERC20x(A_ARB).balanceOf(v), 0, "the reward kept for a later sale");
    }

    /// Outside the exit the switch-off is refused below the health floor; in the exit, anyone may.
    function test_fork_2c_collateralOff_heldToTheFloorOutsideTheExit() public onFork {
        address v = address(vault);
        _leverWithoutSwaps(vault); // 3 WETH supplied, 3,000 USDC borrowed
        (,,, uint256 lt,,) = pool.getUserAccountData(v);
        _aArbArrives(v, 20_000e18);
        _setCollateral(v, ARB, true);
        // WETH priced so that, without aArbARB, the health factor is 1.10: under the 1.15 floor, above 1
        uint256 pw = 1.10e8 * 3_000 * IOracle(Arbitrum.ORACLE).getAssetPrice(Arbitrum.USDC) * 10_000 / (3 * lt * 1e8);
        vm.mockCall(Arbitrum.ORACLE, abi.encodeWithSelector(IOracle.getAssetPrice.selector, Arbitrum.WETH), abi.encode(pw));
        assertGt(_health(v), 1.15e18, "above the floor while aArbARB counts");
        vm.prank(key);
        vm.expectRevert(AaveV3AssetLegState.BelowHealthFloor.selector);
        IAssetLegV1(v).rewardCollateralOff();
        _beginExit(vault, STRATEGY);
        vm.prank(stranger);
        IAssetLegV1(v).rewardCollateralOff();
        assertFalse(_collateralOn(v, ARB));
    }

    /// The callback inside each swap mode (`_swapping`, slot 29, written directly): each pool only in its
    /// own mode, the reward pool paid ARB alone.
    /// `_swapping` sits at slot 34 in version 1's layout (29 in version 0's): the upgrade state comes first.
    function test_fork_2c_callbacks_activeModes() public onFork {
        address v = address(vault);
        _arb(v, 10e18);
        deal(Arbitrum.WETH, v, 1e18);
        _usdc(v, 100e6);
        vm.store(v, bytes32(uint256(34)), bytes32(uint256(2)));
        vm.prank(Arbitrum.SWAP_POOL);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.uniswapV3SwapCallback(1e18, 1e6, "");
        uint256 usdc0 = usdc.balanceOf(v);
        vm.prank(Arbitrum.REWARD_POOL);
        vault.uniswapV3SwapCallback(1e18, 5e6, "");
        assertEq(IERC20x(ARB).balanceOf(v), 9e18, "ARB paid");
        assertEq(usdc.balanceOf(v), usdc0, "never USDC");
        assertEq(weth.balanceOf(v), 1e18, "never WETH");
        vm.store(v, bytes32(uint256(34)), bytes32(uint256(1)));
        vm.prank(Arbitrum.REWARD_POOL);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.uniswapV3SwapCallback(1e18, 0, "");
        vm.prank(Arbitrum.SWAP_POOL);
        vault.uniswapV3SwapCallback(0.1e18, 1e6, "");
        assertEq(weth.balanceOf(v), 0.9e18);
        assertEq(usdc.balanceOf(v), usdc0 - 1e6);
        assertEq(IERC20x(ARB).balanceOf(v), 9e18, "never ARB");
        vm.store(v, bytes32(uint256(34)), bytes32(0));
    }

    /// The probe isolated (Codex's code review): ARB answering an absurd balance beside aArbARB, or AAVE's
    /// `getReserveData(ARB)` reverting, never stops the position's parts.
    function test_fork_2c_exit_probeFailures_neverBlock() public onFork {
        address v = address(vault);
        _lever(vault);
        _aArbArrives(v, 10e18);
        _beginExit(vault, STRATEGY);
        vm.mockCall(ARB, abi.encodeWithSelector(IERC20x.balanceOf.selector, v), abi.encode(type(uint256).max));
        vm.mockCallRevert(Arbitrum.POOL, abi.encodeWithSelector(IPoolx.getReserveData.selector, ARB), "upgraded");
        vm.prank(stranger);
        IAssetLegV1(v).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0, "the position unwound");
    }

    /// The reward sale burning its whole cap (its pool replaced by a gas burner), with the gas at entry
    /// just above the admission's: the position's parts still complete (§3.7).
    function test_fork_2c_exit_rewardPartsExhausted_positionCompletes() public onFork {
        address v = address(vault);
        _lever(vault);
        _arb(v, 1_000e18);
        _beginExit(vault, STRATEGY);
        vm.etch(Arbitrum.REWARD_POOL, address(new GasBurner()).code);
        vm.prank(stranger);
        IAssetLegV1(v).exitStep{gas: 5_400_000}(0, 0); // the admission's 5.1M, plus the fallback's 1/64 and the call's overhead
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0, "the position unwound");
        assertEq(IERC20x(ARB).balanceOf(v), 1_000e18, "the reward kept");
    }

    /// The exit (§3.7): the reward sold first, its USDC with the rest to the hub; a failed sale logged and
    /// the position's parts unchanged; too little gas refused, never a silent skip.
    function test_fork_2c_exit_sellsTheRewardFirst() public onFork {
        address v = address(vault);
        _lever(vault);
        _arb(v, 1_000e18);
        _aArbArrives(v, 1_000e18);
        uint256 fair = _arbValueInUsdc(_held(v));
        _beginExit(vault, STRATEGY);
        vm.prank(stranger);
        vm.expectRevert(MemberState.GasTooLow.selector);
        IAssetLegV1(v).exitStep{gas: 2_000_000}(0, 0);
        uint256 g = gasleft();
        vm.prank(stranger);
        IAssetLegV1(v).exitStep(0, 0);
        emit log_named_uint("exitStep with reward work, gas", g - gasleft());
        assertEq(_held(v), 0, "the reward sold");
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0);
        assertGt(usdc.balanceOf(address(hub)), 4_900e6 + fair * 99 / 100, "the reward's USDC with the rest");
    }

    function test_fork_2c_exit_failedSale_positionPartsRun() public onFork {
        address v = address(vault);
        _lever(vault);
        _arb(v, 1_000e18);
        _beginExit(vault, STRATEGY);
        vm.warp(vm.getBlockTimestamp() + 26 hours); // the feed stale for the sale
        vm.recordLogs();
        vm.prank(stranger);
        IAssetLegV1(v).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0, "the position unwound");
        assertEq(IERC20x(ARB).balanceOf(v), 1_000e18, "the reward kept");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool failed8;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == v && logs[i].topics[0] == AaveV3AssetLegState.ExitPartFailed.selector) {
                (uint8 part, bytes memory reason) = abi.decode(logs[i].data, (uint8, bytes));
                if (part == 8) {
                    failed8 = true;
                    assertEq(bytes4(reason), AaveV3AssetLegState.StalePrice.selector);
                }
            }
        }
        assertTrue(failed8);
    }

    /// A broken reward token (its balanceOf reverting): the probe counts no reward work, the position's
    /// parts run.
    function test_fork_2c_exit_brokenRewardToken_probeIsolated() public onFork {
        address v = address(vault);
        _lever(vault);
        _arb(v, 1_000e18); // reward work, until the token breaks
        _beginExit(vault, STRATEGY);
        vm.mockCallRevert(ARB, abi.encodeWithSelector(IERC20x.balanceOf.selector, v), new bytes(100_000));
        vm.prank(stranger);
        IAssetLegV1(v).exitStep{gas: 2_000_000}(0, 0); // under the reward reserve: no GasTooLow
        vm.clearMockedCalls();
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0, "the position unwound");
        assertEq(IERC20x(ARB).balanceOf(v), 1_000e18, "the reward untouched");
    }

    /// A reward pool reverting with 100 KB of data: part 8 logs 256 bytes of it, the position's parts run.
    function test_fork_2c_exit_revertBomb_bounded() public onFork {
        address v = address(vault);
        _lever(vault);
        _arb(v, 1_000e18);
        _beginExit(vault, STRATEGY);
        vm.mockCallRevert(Arbitrum.REWARD_POOL, abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"), new bytes(100_000));
        vm.recordLogs();
        vm.prank(stranger);
        IAssetLegV1(v).exitStep(0, 0);
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0, "the position unwound");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == v && logs[i].topics[0] == AaveV3AssetLegState.ExitPartFailed.selector) {
                (uint8 part, bytes memory reason) = abi.decode(logs[i].data, (uint8, bytes));
                if (part == 8) {
                    seen = true;
                    assertEq(reason.length, 256, "the revert data bounded");
                }
            }
        }
        assertTrue(seen);
    }

    /// Merkl's governor claims for the leg at the distributor (§3.3): the reward reaches the leg, no
    /// `RewardClaimed`, `opCount` unchanged; the books read Merkl's own `Claimed` (§6).
    function test_fork_2c_thirdPartyClaim_reachesTheLeg() public onFork {
        address v = address(vault);
        (, bytes32[] memory pa,) = _merklTree(v, 300e18, 1e18);
        uint64 ops = vault.opCount();
        address[] memory users = new address[](1);
        users[0] = v;
        address[] memory tokens = new address[](1);
        tokens[0] = ARB;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 300e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = pa;
        vm.prank(MERKL_GOVERNOR);
        IMerklClaim(Arbitrum.MERKL_DISTRIBUTOR).claim(users, tokens, amounts, proofs);
        assertEq(IERC20x(ARB).balanceOf(v), 300e18, "to the leg, never elsewhere");
        assertEq(vault.opCount(), ops);
    }

    /// 2b §3.4 with 2c: a reward sale between the hub's snapshot and its charge is an operation, refused
    /// `PositionMoved` (the harvest claims and sells before its snapshot, §4).
    function test_fork_2c_saleAfterSnapshot_refusedPositionMoved() public onFork {
        _lever(vault);
        _arb(address(vault), 500e18);
        (Holding[] memory h,,,,,,) = AaveV3AssetLegExit(address(vault)).holdings();
        _feeInstant(4_000e18, -h[0].quantity, 0, 0);
        (uint80[] memory r,) = _latestRound();
        (bool ok,,) = HubFee(address(hub)).value(r);
        assertTrue(ok);
        vm.prank(key);
        IAssetLegV1(address(vault)).swapReward(type(uint256).max, 0);
        bytes32 why;
        (ok,, why) = HubFee(address(hub)).value(r);
        assertFalse(ok);
        assertEq(bytes4(why), HubState.PositionMoved.selector);
    }

    /// Measures (§3.7's constants): an exit step's position parts alone, and the reward parts' cost.
    function test_fork_2c_exit_gasMeasured() public onFork {
        address v = address(vault);
        _lever(vault);
        _beginExit(vault, STRATEGY);
        uint256 g = gasleft();
        vm.prank(stranger);
        IAssetLegV1(v).exitStep(0, 0);
        emit log_named_uint("exitStep, position parts only (a levered unwind)", g - gasleft());
        assertEq(IERC20x(Arbitrum.VDEBT_USDC).balanceOf(v), 0, "measured on a complete unwind");
        IAssetLegV1 other = _createVault(keccak256("strategy-2c-gas"), _config(50));
        _arb(address(other), 1_000e18);
        _aArbArrives(address(other), 1_000e18);
        _beginExit(other, keccak256("strategy-2c-gas"));
        g = gasleft();
        vm.prank(stranger);
        IAssetLegV1(address(other)).exitStep(0, 0);
        emit log_named_uint("exitStep, reward parts with nothing else (ARB + aArbARB sold)", g - gasleft());
        assertEq(_held(address(other)), 0, "measured on a complete sale");
    }

    function _slice(bytes memory b, uint256 from, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = b[from + i];
    }
}
