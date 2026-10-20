// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Fixture} from "./utils/Fixture.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";

/// The registry (amendment 2a §3.4, decision 37): keys per group by recovery only, check-ins, the stopped
/// clock, recovery's handover; every leg follows its group's key at once.
contract VaultRegistryTest is Fixture {
    function setUp() public {
        _world();
    }

    function test_executionKeys_perGroup_byRecoveryOnly() public {
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.setExecutionKey(1, stranger);
        vm.prank(key); // not even a group key
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.setExecutionKey(0, stranger);
        vm.startPrank(recovery);
        vm.expectRevert(VaultRegistry.BadGroup.selector);
        registry.setExecutionKey(16, stranger);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        registry.setExecutionKey(1, address(0));
        address k1 = makeAddr("group1-key");
        registry.setExecutionKey(1, k1);
        address k15 = makeAddr("group15-key");
        registry.setExecutionKey(15, k15);
        vm.stopPrank();
        assertEq(registry.GROUPS(), 16);
        assertEq(registry.executionKey(1), k1);
        assertEq(registry.executionKey(15), k15);
        assertEq(registry.executionKey(0), key, "replacing one group leaves the others");
    }

    function test_checkIn_andStopped() public {
        assertTrue(registry.stopped(2), "a group never set is stopped");
        assertFalse(registry.stopped(0));
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.checkIn(0);
        vm.prank(key);
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.checkIn(16);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        assertFalse(registry.stopped(0));
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(registry.stopped(0));
        // recovery replacing the key does not reopen the clock
        vm.prank(recovery);
        registry.setExecutionKey(0, makeAddr("replacement"));
        assertTrue(registry.stopped(0));
        vm.prank(makeAddr("replacement"));
        registry.checkIn(0);
        assertFalse(registry.stopped(0));
    }

    function test_recoveryHandover() public {
        address next = makeAddr("next-recovery");
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.proposeRecovery(next);
        vm.prank(recovery);
        registry.proposeRecovery(next);
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.acceptRecovery();
        vm.prank(next);
        registry.acceptRecovery();
        assertEq(registry.recovery(), next);
        assertEq(registry.pendingRecovery(), address(0));
    }

    function test_constructor_needsRecovery() public {
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        new VaultRegistry(address(0));
    }

    /// A replaced group key loses its legs at once; the new key operates them. The leg asks the
    /// registry it was given, never its factory (invariant 9).
    function test_replacedKey_legsFollowAtOnce() public {
        address v = _create(_config());
        assertEq(VaultBase(v).registry(), address(registry));
        address next = makeAddr("next-key");
        vm.prank(recovery);
        registry.setExecutionKey(0, next);
        vm.prank(key);
        vm.expectRevert(VaultState.NotExecution.selector);
        VaultBase(v).pause(true);
        vm.prank(next);
        VaultBase(v).pause(true);
    }

    // ── amendment 2b §3.9: DLTX's fee address ──────────────────────────────────────────────────────────

    event FeeAddressProposed(address indexed current, address indexed proposed);
    event FeeAddressSet(address indexed previous, address indexed next);

    function test_feeAddress_startsUnset() public view {
        assertEq(registry.feeAddress(), address(0), "no fee before an address accepts");
        assertEq(registry.pendingFeeAddress(), address(0));
    }

    function test_feeAddress_proposedByRecoveryOnly() public {
        address treasury = makeAddr("dltx-treasury");
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.proposeFeeAddress(treasury);
        vm.prank(key); // a group's key is not recovery
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury); // nor the address itself
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.proposeFeeAddress(treasury);
        vm.expectEmit(address(registry));
        emit FeeAddressProposed(address(0), treasury);
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        assertEq(registry.pendingFeeAddress(), treasury);
        assertEq(registry.feeAddress(), address(0), "a proposal is not an address");
    }

    function test_feeAddress_acceptedByTheProposedAddressOnly() public {
        address treasury = makeAddr("dltx-treasury");
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(recovery); // recovery can't accept for it
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.acceptFeeAddress();
        vm.prank(stranger);
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.acceptFeeAddress();
        vm.expectEmit(address(registry));
        emit FeeAddressSet(address(0), treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
        assertEq(registry.feeAddress(), treasury);
        assertEq(registry.pendingFeeAddress(), address(0));
        vm.prank(treasury); // accepted once
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.acceptFeeAddress();
    }

    /// A replacement takes the same two steps; the current address stays until the next accepts, and a
    /// proposal of zero withdraws a pending one.
    function test_feeAddress_replacement_andWithdrawal() public {
        address first = makeAddr("first-treasury");
        address next = makeAddr("next-treasury");
        vm.prank(recovery);
        registry.proposeFeeAddress(first);
        vm.prank(first);
        registry.acceptFeeAddress();
        vm.expectEmit(address(registry));
        emit FeeAddressProposed(first, next);
        vm.prank(recovery);
        registry.proposeFeeAddress(next);
        assertEq(registry.feeAddress(), first, "unchanged until the next accepts");
        vm.prank(recovery);
        registry.proposeFeeAddress(address(0));
        vm.prank(next);
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.acceptFeeAddress();
        assertEq(registry.feeAddress(), first);
        vm.prank(recovery);
        registry.proposeFeeAddress(next);
        vm.expectEmit(address(registry));
        emit FeeAddressSet(first, next);
        vm.prank(next);
        registry.acceptFeeAddress();
        assertEq(registry.feeAddress(), next);
    }

    /// After recovery's own handover, only the new recovery proposes.
    function test_feeAddress_followsRecoveryHandover() public {
        address nextRecovery = makeAddr("next-recovery");
        vm.prank(recovery);
        registry.proposeRecovery(nextRecovery);
        vm.prank(nextRecovery);
        registry.acceptRecovery();
        vm.prank(recovery);
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.proposeFeeAddress(stranger);
        vm.prank(nextRecovery);
        registry.proposeFeeAddress(stranger);
        assertEq(registry.pendingFeeAddress(), stranger);
    }

    /// The fee address touches nothing else: keys, check-ins and the hatch are unchanged by it.
    function test_feeAddress_independentOfKeysAndCheckIns() public {
        address treasury = makeAddr("dltx-treasury");
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
        assertEq(registry.executionKey(0), key);
        assertEq(registry.recovery(), recovery);
        vm.prank(treasury);
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.checkIn(0);
        vm.prank(treasury);
        vm.expectRevert(VaultRegistry.NotAllowed.selector);
        registry.setExecutionKey(0, treasury);
    }
}
