// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {walletCred} from "../mocks/Mocks.sol";

import {ShortVaultCompatTest} from "./ShortVaultCompat.t.sol";
import {IHyperCoreLegV1} from "./IHyperCoreLegV1.sol";
import {HyperCoreLegState} from "../../src/HyperCoreLegState.sol";
import {MemberState} from "../../src/MemberState.sol";
import {StrategySpec} from "../../src/Types.sol";
import {OwnerMessages, ShortParams} from "../../src/lib/VaultTypes.sol";
import {HyperCore} from "../../src/lib/HyperCore.sol";

/// The combined security review of 2026-10-18, the Hyperliquid leg's findings: each test PASSES while its
/// gap stands (it asserts the bad outcome); a fix flips it.
/// PARITY (asset-profiles-design.md §10 slice 1): version 0's `test/CombinedReviewShort.t.sol` on version 1's
/// Hyperliquid leg, through `FixtureCompat`.
contract CombinedReviewShortCompatTest is ShortVaultCompatTest {
    function _dex1() internal pure returns (HyperCoreLegState.ExitArgs memory a) {
        a.dexes = new HyperCoreLegState.DexHint[](1);
        a.dexes[0] = HyperCoreLegState.DexHint(1, 0);
    }

    /// CR-D1, fixed: a stranger's 1-wei spot credit between windows no longer holds the first-fee
    /// fallback off: a read that has not fallen keeps the allowance back, and that send lands.
    function test_CR_D1_strangerDust_fallbackStillFires() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setSpot(v, 0, FIRST_SPOT);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        _step();
        assertEq(writer.dropped(), 1);
        core.setSpot(v, 0, core.spot(v, 0) + 1);
        uint64 read = core.spot(v, 0);
        _pace();
        bytes[] memory r = _step();
        uint64 want = read - 105_000_000;
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, want - want % 100)), "the allowance kept back");
        assertEq(writer.landed(), 1, "and it lands");
    }

    /// CR-D2a, fixed: at HYPE 600 the purchase is the fewest steps worth $10 (two, $12.12), not one ($6.06).
    function test_CR_D2a_hypePurchaseClearsHyperliquidsMinimum() public {
        address v = address(vault);
        core.setOracle(HYPE_PERP, 6_000_000, 2);
        core.setSpot(v, 0, 5_000_000_000);
        _beginExit();
        bytes[] memory r = _step();
        assertTrue(_has(r, _order(10_107, true, 60_600_000_000, 2_000_000, false)), "0.02 HYPE at 606.00");
    }

    /// CR-D2b, fixed: at HYPE 1,200 a purchase is still placed (one step, $12.12).
    function test_CR_D2b_hypeAbove1089_stillBought() public {
        address v = address(vault);
        core.setOracle(HYPE_PERP, 12_000_000, 2);
        core.setSpot(v, 0, 5_000_000_000);
        _beginExit();
        bytes[] memory r = _step();
        assertEq(_countId(r, 1), 1, "the purchase is placed");
    }

    /// CR-D2c, fixed: with less spot USDC than a purchase costs, the exit says HYPE is needed.
    function test_CR_D2c_tooLittleForAPurchase_saysSo() public {
        address v = address(vault);
        core.setOracle(HYPE_PERP, 6_000_000, 2);
        core.setSpot(v, 0, 1_100_000_000); // 11 USDC: under the 12.12 a purchase costs at 606
        _beginExit();
        _step();
        (,, uint256 flags) = _state();
        assertEq(flags & F_NEEDS_HYPE, F_NEEDS_HYPE, "a caller is told to bring HYPE");
    }

    /// CR-D3, fixed: the burner drops a pending owner agent.
    function test_CR_D3_burnerDropsThePendingOwnerAgent() public {
        address thief = makeAddr("thief-agent");
        uint256 d = block.timestamp + 3 days;
        vault.ownerAction(OwnerMessages.REPLACE_AGENT, thief, walletCred(wallet), d, _actionSig(address(vault), OwnerMessages.REPLACE_AGENT, thief, 0, d));
        address b = vault.burner();
        vault.ownerAction(OwnerMessages.REPLACE_AGENT, b, walletCred(wallet), d, _actionSig(address(vault), OwnerMessages.REPLACE_AGENT, b, 1, d));
        assertEq(vault.agent(), b);
        assertEq(vault.ownerAgent(), address(0), "dropped with the burner");
    }

    /// CR-D6, fixed: a stranger's dust under 0.01 USDC on spot triggers no transfer.
    function test_CR_D6_strangerDust_sendsNothing() public {
        address v = address(vault);
        core.setSpot(v, HYPE, 990_000);
        _beginExit();
        for (uint256 i; i < 10; ++i) {
            core.setSpot(v, 0, uint64(100 * (1 + i % 2)));
            _pace();
            bytes[] memory r = _step();
            assertEq(_countId(r, 13), 0, "no paced transfer for dust");
            core.setSpot(v, 0, 0);
        }
    }

    /// CR-D5: a watched DEX that becomes unreadable adds no reserve (stated as a residual, decision 7);
    /// its other half is fixed by the floor of the partner's audit M4: once the first send is seen on
    /// HyperEVM, a later arrival on spot leaves.
    function test_CR_D5_unreadableDex_noReserve_laterArrivalsLeave() public {
        address v = address(vault);
        core.setMargin(1, v, 60_000_000, 20_000_000, 550_000_000);
        core.setSpot(v, 0, 20_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        _stepWith(_dex1());
        core.setDexRefused(1, true);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _pace();
        _step();
        assertEq(vault.floor(), 105_000_000, "R = 0 for the unreadable DEX");
        core.setSpot(v, 0, 105_000_000 + 1_000_000_000); // the send executed, and a later arrival
        usdc.mint(v, 198_950_000); // the send's USDC on HyperEVM
        _pace();
        bytes[] memory r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 1_000_000_000)), "the later arrival leaves");
        (uint8 s,, uint256 flags) = _state();
        assertEq(s, CLOSING);
        assertEq(flags & F_BUDGET, F_BUDGET);
    }

    /// CR-X1 (Codex), fixed: a perp whose position can't be read no longer stops the exit; the gate
    /// still holds every move while DEX 0 shows notional, and the money leaves once it shows none.
    function test_CR_X1_unknownPerp_exitGoesOn() public {
        // version 1 refuses an unknown perp at creation (AP-3, AP-4): a perp delisted LATER is the case left,
        // played by the strategy's own perp's position read reverting
        IHyperCoreLegV1 bad = vault;
        vm.mockCallRevert(HyperCore.PX_POSITION, abi.encode(address(bad), uint16(ETH)), "");
        core.setSpot(address(bad), 0, 5_000_000_000);
        core.setSpot(address(bad), HYPE, 1_000_000);
        uint256 deadline = block.timestamp + 1 hours;
        bad.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        HyperCoreLegState.ExitArgs memory none;
        uint256 from = writer.count();
        vm.prank(stranger);
        IHyperCoreLegV1(payable(address(bad))).exitStep(none);
        assertGt(_countId(_since(from), 13), 0, "the spot USDC leaves");
    }

    /// CR-X2 (Codex), fixed: in unified mode the floor is fixed two pacing windows after the first
    /// margin try, and the unrelated money leaves.
    function test_CR_X2_unifiedMarginHeld_budgetFixedAfterTwoWindows() public {
        address v = address(vault);
        writer.setUnified(true);
        core.setMargin(1, v, 60_000_000, 20_000_000, 550_000_000); // a HIP-3 position, R = 60.5
        core.setSpot(v, 0, 20_000_000_000); // 200 USDC on spot
        core.setSpot(v, HYPE, 1_000_000);
        core.setWithdrawable(v, 10_000_000); // DEX 0's margin, which unified mode never moves
        _beginExit();
        _stepWith(_dex1());
        vm.warp(vm.getBlockTimestamp() + 7 days); // DEX 1 drops out of the gate
        uint256 sends;
        for (uint256 i; i < 4; ++i) {
            vm.roll(vm.getBlockNumber() + 20);
            sends += _countId(_step(), 13);
        }
        assertTrue(vault.floorSet(), "the floor is fixed");
        assertGt(sends, 0, "the unrelated money leaves");
    }

    /// RR-1 (the fixes' re-review): a precompile that fails may burn all the gas it is given; the exit's
    /// reads are capped, so the step still has its gas and goes on.
    function test_RR1_aGasBurningPositionRead_exitGoesOn() public {
        // as above: the strategy's own perp, its read failing after creation
        IHyperCoreLegV1 bad = vault;
        core.setSpot(address(bad), 0, 5_000_000_000);
        core.setSpot(address(bad), HYPE, 1_000_000);
        uint256 deadline = block.timestamp + 1 hours;
        bad.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        vm.etch(HyperCore.PX_POSITION, hex"fe"); // INVALID: burns everything it is given
        HyperCoreLegState.ExitArgs memory none;
        uint256 from = writer.count();
        vm.prank(stranger);
        IHyperCoreLegV1(payable(address(bad))).exitStep{gas: 10_000_000}(none);
        assertGt(_countId(_since(from), 13), 0, "the spot USDC leaves");
    }

    /// RR-3: the first margin try is forgotten once the margin is on spot, so a later margin is tried
    /// afresh before the budget is fixed without it.
    function test_RR3_marginTriedAt_resetOnceOnSpot() public {
        address v = address(vault);
        core.setSpot(v, HYPE, 1_000_000);
        core.setWithdrawable(v, 10_000_000);
        _beginExit();
        _step();
        assertGt(vault.marginTriedAt(), 0);
        core.setWithdrawable(v, 0);
        _pace();
        _step();
        assertEq(vault.marginTriedAt(), 0, "reset once DEX 0's margin is on spot");
    }

    /// RR-4: a read between the allowance and the allowance + the dust bound goes whole, so the exit
    /// never parks there (a landed first send, then 1.05 USDC arriving).
    function test_RR4_underAllowancePlusDust_sentWhole() public {
        address v = address(vault);
        core.setSpot(v, HYPE, 1_000_000);
        core.setSpot(v, 0, 105_000_000);
        _beginExit();
        _step(); // a first send, which lands (the fee not played)
        core.setSpot(v, 0, 105_000_000); // the same read arrives again
        _pace();
        bytes[] memory r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 105_000_000)), "sent whole");
    }
}
