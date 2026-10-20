// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {LinksTest} from "./Links.t.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {TestLegExit} from "./mocks/TestLeg.sol";

/// The combined security review of 2026-10-18 (docs/architecture/rework/research/contracts-security-review.md):
/// each finding's test, written to PASS while its gap stands (it asserts the bad outcome). A fix flips it.
contract CombinedReviewTest is LinksTest {
    address treasury = makeAddr("dltx-treasury");

    function _feeAddress() internal {
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
    }

    /// CR-B1, fixed: a withdrawal address that is one of the strategy's own legs holds the exit's payment
    /// at the hub, so the same cash is never realised twice and no capital is charged.
    function test_CR_B1_withdrawalAddressIsALeg_paymentHeld() public {
        _feeAddress();
        (address[] memory made,) = _make(_factory(HYPEREVM_DOMAIN, _d(HYPEREVM_DOMAIN, HYPEREVM_DOMAIN)));
        StrategyHub hub = StrategyHub(made[0]);
        address leg = made[2];
        usdc.mint(address(hub), 1_000e6); // capital
        owner.setWithdrawalAddress(leg);
        uint256 deadline = block.timestamp + 1 hours;
        hub.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        vm.startPrank(stranger);
        hub.exitStep();
        TestLegExit(leg).exitStep();
        hub.exitStep();
        vm.stopPrank();
        assertEq(usdc.balanceOf(treasury), 0, "no fee on capital");
        assertEq(usdc.balanceOf(address(hub)), 1_000e6, "held at the hub");
        owner.setWithdrawalAddress(makeAddr("the owner's own address"));
        vm.prank(stranger);
        hub.exitStep();
        assertEq(usdc.balanceOf(makeAddr("the owner's own address")), 1_000e6, "paid once a real address is set");
    }
}
