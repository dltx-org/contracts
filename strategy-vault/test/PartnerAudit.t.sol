// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {walletCred} from "./mocks/Mocks.sol";
import {ShortVaultTest} from "./ShortVault.t.sol";
import {ShortVaultState} from "../src/ShortVaultState.sol";
import {VaultState} from "../src/VaultBase.sol";
import {OwnerMessages} from "../src/lib/VaultTypes.sol";

/// The operator's partner's audit of c64337f (2026-10-20), the Hyperliquid leg's findings. Each test is the
/// partner's reproduction, adapted to assert the FIXED behaviour (docs/architecture/rework/research/
/// contracts-security-review.md §7).
contract PartnerAuditShortTest is ShortVaultTest {
    address thief;
    uint256 thiefPk;

    function _thiefSig(uint8 action, address agent, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        return _sign(
            thiefPk,
            address(owner),
            keccak256(
                abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, address(vault), block.chainid, action, agent, nonce, deadline)
            )
        );
    }

    function _dex1() internal pure returns (ShortVaultState.ExitArgs memory a) {
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(1, 0);
    }

    /// M2: a stolen credential proposes its own agent, and is removed before the 24 hours: the proposal
    /// can no longer be applied, by anyone. Applied while its credential stands, it goes.
    function test_audit_pendingOwnerAgentSurvivesCredentialRemoval() public {
        (thief, thiefPk) = makeAddrAndKey("stolen-credential");
        owner.setWallet(thief, true);
        address thiefAgent = makeAddr("thief-agent");
        uint256 deadline = block.timestamp + 3 days;
        vault.ownerAction(
            OwnerMessages.REPLACE_AGENT, thiefAgent, walletCred(thief), deadline, _thiefSig(3, thiefAgent, 0, deadline)
        );
        assertEq(vault.ownerAgent(), thiefAgent);
        owner.setWallet(thief, false); // the owner removes the stolen credential
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        uint256 from = writer.count();
        vm.prank(stranger);
        vm.expectRevert(VaultState.NotAllowed.selector);
        vault.applyOwnerAgent();
        assertTrue(vault.agent() != thiefAgent, "the thief's agent is never applied");
        assertEq(writer.count(), from, "no CoreWriter action");
        // the honest credential's own choice still applies, and replaces the dead proposal
        address mine = makeAddr("owner-agent");
        vault.ownerAction(3, mine, walletCred(wallet), deadline, _actionSig(address(vault), 3, mine, 0, deadline));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(stranger);
        vault.applyOwnerAgent();
        assertEq(vault.agent(), mine);
    }

    /// M2: an unsynced copy (never reached, or expired: M1) applies no owner agent either.
    function test_audit_ownerAgentWaitsForASyncedCopy() public {
        address mine = makeAddr("owner-agent");
        uint256 deadline = block.timestamp + 3 days;
        vault.ownerAction(3, mine, walletCred(wallet), deadline, _actionSig(address(vault), 3, mine, 0, deadline));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        owner.setSynced(false);
        vm.expectRevert(VaultState.NotAllowed.selector);
        vault.applyOwnerAgent();
        owner.setSynced(true);
        vault.applyOwnerAgent();
        assertEq(vault.agent(), mine);
    }

    /// M4: 200 USDC on spot, a watched DEX that became unreadable (R = 0): the floor is the fee allowance
    /// and 198.95 leave in one send, which the writer records and never executes. Nothing counts it as
    /// spent: it is RESERVED, so no second send can follow it while it may still execute (three pacing
    /// windows: none, the 200 still there); then the owner's signed RELEASE_RESERVATION (the partner's
    /// "explicit owner recovery path") frees it, and the next step sends again.
    function test_audit_unexecutedTransferConsumesEntireExitBudget() public {
        address v = address(vault);
        core.setMargin(1, v, 60_000_000, 20_000_000, 550_000_000);
        core.setSpot(v, 0, 20_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        _stepWith(_dex1());
        core.setDexRefused(1, true);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _pace();
        bytes[] memory r = _step();
        assertEq(vault.floor(), 105_000_000);
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 19_895_000_000)), "198.95 sent");
        assertEq(vault.reserved(), 19_895_000_000, "reserved, not spent");
        for (uint256 i; i < 3; ++i) {
            _pace();
            r = _step();
            assertEq(_countId(r, 13), 0, "no second send while the first may still execute");
        }
        assertEq(core.spot(v, 0), 20_000_000_000, "the 200 USDC still on spot");
        // a stranger can't release it: the owner's signature
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _actionSig(v, OwnerMessages.RELEASE_RESERVATION, address(0), 0, deadline);
        vm.prank(stranger);
        vault.ownerAction(OwnerMessages.RELEASE_RESERVATION, address(0), walletCred(wallet), deadline, sig);
        assertEq(vault.reserved(), 0);
        _pace();
        r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 19_895_000_000)), "sent again after the release");
    }

    /// M4: the same send, executed: its USDC seen on HyperEVM releases the reservation by itself (no time,
    /// no owner); a Circle mint from a member arriving meanwhile is not taken for it.
    function test_audit_anExecutedSendIsReleasedByItsArrival() public {
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
        assertEq(vault.reserved(), 19_895_000_000);
        // a hub mint of 500 USDC lands (499.95 after Circle's fee): it is not taken for the send
        bytes memory m = abi.encodePacked(
            abi.encodePacked(uint32(1), ARB_DOMAIN, HYPEREVM_DOMAIN, bytes32(uint256(1)), bytes32(uint256(uint160(TOKEN_MESSENGER))), bytes32(uint256(uint160(TOKEN_MESSENGER))), bytes32(uint256(uint160(v))), uint32(1000), uint32(1000)),
            abi.encodePacked(uint32(1), bytes32(uint256(uint160(USDC))), bytes32(uint256(uint160(v))), uint256(500e6), bytes32(uint256(uint160(hub))), uint256(0.05e6), uint256(0.05e6), uint256(0))
        );
        ex.receiveMint(m, "");
        _pace();
        _step();
        assertEq(vault.reserved(), 19_895_000_000, "a member's mint releases nothing");
        // the send executes; 30 USDC more reach spot
        core.setSpot(v, 0, 105_000_000 + 3_000_000_000);
        usdc.mint(v, 198_950_000);
        _pace();
        bytes[] memory r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 3_000_000_000)), "the arrival leaves");
        assertEq(vault.reserved(), 3_000_000_000);
    }

    /// M4 (the review's underflow check): mints that left for HyperCore before the exit (uncounted by
    /// `sentTo`) never make the budget mode's comparison revert; the exit steps and the send is reserved.
    function test_audit_premExitMintsLeftForCore_exitStillSteps() public {
        address v = address(vault);
        bytes memory m = abi.encodePacked(
            abi.encodePacked(uint32(1), ARB_DOMAIN, HYPEREVM_DOMAIN, bytes32(uint256(2)), bytes32(uint256(uint160(TOKEN_MESSENGER))), bytes32(uint256(uint160(TOKEN_MESSENGER))), bytes32(uint256(uint160(v))), uint32(1000), uint32(1000)),
            abi.encodePacked(uint32(1), bytes32(uint256(uint160(USDC))), bytes32(uint256(uint160(v))), uint256(500e6), bytes32(uint256(uint160(hub))), uint256(0), uint256(0), uint256(0))
        );
        ex.receiveMint(m, "");
        vm.prank(key);
        vault.toMargin(500e6); // gone to HyperCore, in no sentTo
        core.setMargin(1, v, 60_000_000, 20_000_000, 550_000_000);
        core.setSpot(v, 0, 20_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        _stepWith(_dex1());
        core.setDexRefused(1, true);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _pace();
        _step();
        assertEq(vault.reserved(), 19_895_000_000);
        _pace();
        bytes[] memory r = _step(); // the comparison with arrivals below the mints: no revert
        assertEq(_countId(r, 13), 0);
    }
}
