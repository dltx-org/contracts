// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {ExitBandEthForkTest, IAaveOracleX} from "./ExitBandEth.fork.t.sol";
import {IERC20x} from "./AssetLegEth.fork.t.sol";
import {IAssetLegV1} from "./IAssetLegV1.sol";
import {Arbitrum} from "../src/lib/Pinned.sol";

interface IPoolProviderX {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAddrProviderX {
    function getACLAdmin() external view returns (address);
    function getACLManager() external view returns (address);
    function getPoolConfigurator() external view returns (address);
}

interface IConfiguratorX {
    function configureReserveAsCollateral(address, uint256, uint256, uint256) external;
}

/// PARITY (asset-profiles-design.md §10 slice 1): version 0's `test/CombinedReviewLong.fork.t.sol` on
/// version 1's generic asset leg with the ETH profile, its assertions unchanged.
/// The combined security review of 2026-10-18, the AAVE leg's findings on the Arbitrum fork: each test
/// PASSES while its gap stands (it asserts the bad outcome); a fix flips it.
contract CombinedReviewLongEthForkTest is ExitBandEthForkTest {

    /// AAVE governance offboarding a reserve as collateral (LTV 0), as it did for ARB on this market.
    function _ltvZero(address asset) internal {
        IAddrProviderX p = IAddrProviderX(IPoolProviderX(Arbitrum.POOL).ADDRESSES_PROVIDER());
        // the test stands in for AAVE's governance: its ACL answers yes for this contract
        vm.mockCall(p.getACLManager(), abi.encodeWithSignature("isPoolAdmin(address)", address(this)), abi.encode(true));
        vm.mockCall(p.getACLManager(), abi.encodeWithSignature("isRiskAdmin(address)", address(this)), abi.encode(true));
        uint256 cfg = pool.getReserveData(asset).configuration;
        IConfiguratorX(p.getPoolConfigurator()).configureReserveAsCollateral(
            asset, 0, (cfg >> 16) & 0xFFFF, (cfg >> 32) & 0xFFFF
        );
    }

    /// CR-C1, fixed: a stranger's dust of a collateral reserve, later set to LTV 0, froze the leg's WETH
    /// while it borrows; `collateralOff` switches it off (anyone in exit), and the exit unwinds again.
    function test_CR_C1_zeroLtvDonation_switchedOff_exitUnwinds() public onFork {
        _deep(vault);
        deal(WBTC, stranger, 1_000);
        vm.startPrank(stranger);
        IERC20x(WBTC).approve(Arbitrum.POOL, 1_000);
        pool.supply(WBTC, 1_000, address(vault), 0);
        vm.stopPrank();
        uint256 bit = 2 << (uint256(pool.getReserveData(WBTC).id) * 2);
        assertTrue(pool.getUserConfiguration(address(vault)) & bit != 0, "AAVE enabled it on arrival");
        _ltvZero(WBTC);
        vm.prank(stranger);
        vm.expectRevert();
        vault.collateralOff(WBTC); // outside the exit: the key's alone
        vm.prank(key);
        vault.collateralOff(WBTC);
        assertTrue(pool.getUserConfiguration(address(vault)) & bit == 0, "switched off");
        vm.prank(key);
        vault.withdraw(Arbitrum.WETH, 0.1e18); // the key's WETH withdrawal works again
        // in exit, anyone: a second donation, switched off by a stranger, then the exit unwinds
        vm.startPrank(stranger);
        IERC20x(WBTC).approve(Arbitrum.POOL, 1_000);
        deal(WBTC, stranger, 1_000);
        pool.supply(WBTC, 1_000, address(vault), 0);
        vm.stopPrank();
        _beginExit(vault, STRATEGY);
        vm.prank(stranger);
        vault.collateralOff(WBTC);
        uint256 debt = _debt(address(vault));
        for (uint256 i; i < 3; ++i) {
            vm.prank(stranger);
            IAssetLegV1(address(vault)).exitStep(0, 0);
        }
        assertLt(_debt(address(vault)), debt, "the exit frees debt again");
    }

    /// CR-C2, fixed: in exit the hub routes nothing into a long insolvent at AAVE's oracle (collateral
    /// below debt); the short's cash goes to the owner.
    function test_CR_C2_insolventLong_routedNothing_ownerPaid() public onFork {
        uint256 p0 = _pw();
        deal(Arbitrum.WETH, address(vault), 10e18);
        vm.startPrank(key);
        vault.supply(10e18);
        uint256 value = 10 * p0 / 1e2; // USDC units (pw 8 dp)
        vault.borrow(value * 672 / 1_000);
        vm.stopPrank();
        vm.prank(address(vault));
        usdc.transfer(stranger, value * 672 / 1_000);
        vm.mockCall(Arbitrum.ORACLE, abi.encodeCall(IAaveOracleX.getAssetPrice, (Arbitrum.WETH)), abi.encode(p0 * 6 / 10));
        (uint256 c, uint256 d,,,,) = pool.getUserAccountData(address(vault));
        assertLt(c, d, "insolvent at AAVE's oracle");
        uint256 cash = value * 624 / 1_000;
        _usdc(address(hub), cash);
        _beginExit(vault, STRATEGY);
        assertEq(vault.exitDebt(), 0, "no debt stated while insolvent");
        vm.prank(stranger);
        hub.exitStep();
        assertEq(hub.sentTo(0), 0, "nothing routed into the insolvent position");
        assertGt(usdc.balanceOf(withdrawalTo), 0, "the owner paid");
    }

    /// CR-C3: a reward token that is not the pinned ARB stays on the leg after its exit, with no way out.
    function test_CR_C3_unpinnedRewardStrandedAfterExit() public onFork {
        address LINK = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
        _unlevered(vault, 1e18, STRATEGY);
        deal(LINK, address(vault), 50e18);
        _beginExit(vault, STRATEGY);
        for (uint256 i; i < 3; ++i) {
            vm.prank(stranger);
            IAssetLegV1(address(vault)).exitStep(0, 0);
        }
        vm.prank(stranger);
        hub.exitStep();
        assertEq(IERC20x(Arbitrum.A_WETH).balanceOf(address(vault)) + weth.balanceOf(address(vault)), 0, "unwound");
        assertEq(IERC20x(LINK).balanceOf(address(vault)), 50e18, "stays, with no path out");
    }

    /// RR-2 (the fixes' re-review): a stranger's dust in many reserves, each enabled as the leg's collateral
    /// on arrival, must not push `exitDebt` past the hub's 300,000-gas read: it reads two bounded calls,
    /// never AAVE's loop over every reserve, so the hub still routes the debt.
    function test_RR2_dustInManyReserves_exitDebtStillRead() public onFork {
        _deep(vault);
        address[6] memory rs = [
            WBTC,
            0xf97f4df75117a78c1A5a0DBb814Af92458539FB4, // LINK
            0x5979D7b546E38E414F7E9822514be443A4800529, // wstETH
            0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8, // rETH
            0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe, // weETH
            0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 // USDT
        ];
        for (uint256 i; i < rs.length; ++i) {
            deal(rs[i], stranger, 1e6);
            vm.startPrank(stranger);
            IERC20x(rs[i]).approve(Arbitrum.POOL, type(uint256).max);
            try pool.supply(rs[i], 1e6, address(vault), 0) {} catch {}
            vm.stopPrank();
        }
        _beginExit(vault, STRATEGY);
        (bool ok, bytes memory out) =
            address(vault).staticcall{gas: 300_000}(abi.encodeCall(IAssetLegV1.exitDebt, ()));
        assertTrue(ok, "exitDebt read within the hub's cap");
        assertGt(abi.decode(out, (uint256)), 0, "the debt stated");
    }
}
