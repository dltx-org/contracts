// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureCompat} from "./FixtureCompat.sol";
import {IHyperCoreLegV1} from "./IHyperCoreLegV1.sol";
import {HyperCoreLegState} from "../../src/HyperCoreLegState.sol";
import {MemberState} from "../../src/MemberState.sol";
import {Holding} from "../../src/lib/VaultTypes.sol";
import {MockTokenMessenger, MockTransmitter, walletCred} from "../mocks/Mocks.sol";

/// The external audit of 2026-10-26 (docs/architecture/rework/research/audit-2026-10-26.md) on the
/// Hyperliquid leg, HyperCore mocked: finding 1 (burners from exit entropy), finding 5 (a stranger's
/// mint forwarded to the hub as capital), low 8 (the HYPE reserve at the base fee), low 9 (a stranger's
/// wei on HyperEVM no longer holds the residue sweep).
contract AuditShortV1Test is FixtureCompat {
    IHyperCoreLegV1 vault;
    address hub;

    function setUp() public {
        _world();
        vault = IHyperCoreLegV1(payable(this.make())); // external: via-IR inlines `_create` too deep here
        hub = vault.links(0);
        _deliverReady(address(vault), ARB_DOMAIN, hub);
        _deliverReady(address(vault), ARB_DOMAIN, vault.links(1));
        core.setExists(address(vault), true);
    }

    function make() external returns (address) {
        return _create(_config());
    }

    function _beginExit() internal {
        uint256 deadline = block.timestamp + 1 hours;
        vault.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
    }

    function _step() internal returns (bytes[] memory) {
        HyperCoreLegState.ExitArgs memory a;
        uint256 from = writer.count();
        vm.prank(stranger);
        vault.exitStep(a);
        return _since(from);
    }

    /// A Circle burn of `amount` (fee `fee`) from `sender` on Arbitrum, minted to this leg.
    function _mintFrom(address sender, uint256 amount, uint256 fee, uint256 nonce) internal {
        vault.receiveMint(abi.encodePacked(_header(nonce), _burnBody(sender, amount, fee)), "");
    }

    function _header(uint256 nonce) internal view returns (bytes memory) {
        bytes32 messenger_ = bytes32(uint256(uint160(TOKEN_MESSENGER)));
        return abi.encodePacked(
            uint32(1), ARB_DOMAIN, HYPEREVM_DOMAIN, bytes32(nonce), messenger_, messenger_,
            bytes32(uint256(uint160(address(vault)))), uint32(1000), uint32(1000)
        );
    }

    function _burnBody(address sender, uint256 amount, uint256 fee) internal view returns (bytes memory) {
        return abi.encodePacked(
            uint32(1), bytes32(uint256(uint160(USDC))), bytes32(uint256(uint160(address(vault)))), amount,
            bytes32(uint256(uint160(sender))), fee, fee, uint256(0)
        );
    }

    function _reportedUsd() internal returns (int256) {
        vault.report();
        MockTransmitter.Sent memory m = transmitter.sent(transmitter.sentCount() - 1);
        (,,,,, Holding[] memory h,,,) = abi.decode(m.body, (bytes32, uint256, uint256, uint256, uint256, Holding[], uint256[4], uint256[4], uint256[4]));
        return h[0].quantity;
    }

    // ── finding 1 ────────────────────────────────────────────────────────────────────────────────────

    /// The exit's burner exists only once the exit runs (no address derivable ahead of time), and every
    /// re-approval names a fresh one: a stranger can't claim it on HyperCore first.
    function test_F1_theExitNamesAFreshBurnerAtEachReapproval() public {
        address old = address(uint160(uint256(keccak256(abi.encode("dltx.strategy-vault.burner", address(vault))))));
        _beginExit();
        address first = vault.agent();
        assertTrue(vault.burning());
        assertEq(vault.exitAgent(), first);
        assertTrue(first != old && first != address(0) && first != address(1), "not the derivable address");
        vm.roll(vm.getBlockNumber() + 20);
        bytes[] memory r = _step();
        address second = vault.agent();
        assertTrue(second != first, "a fresh burner");
        assertEq(vault.exitAgent(), second);
        assertTrue(_has(r, _agentBytes(second)));
    }

    /// The owner's own agent, applied in the exit, is re-approved as itself, never replaced by a burner.
    function test_F1_theOwnersAgentIsReapprovedAsItself() public {
        _beginExit();
        address mine = makeAddr("owner-agent");
        uint256 deadline = block.timestamp + 3 days;
        vault.ownerAction(3, mine, walletCred(wallet), deadline, _actionSig(address(vault), 3, mine, 0, deadline));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.applyOwnerAgent();
        assertFalse(vault.burning());
        vm.roll(vm.getBlockNumber() + 20);
        bytes[] memory r = _step();
        assertEq(vault.agent(), mine);
        assertTrue(_has(r, _agentBytes(mine)));
    }

    // ── finding 5 ────────────────────────────────────────────────────────────────────────────────────

    /// A stranger's burn to the leg goes on to the hub at once, as a burn any caller completes (so the
    /// hub counts it as capital), and is never in the leg's holdings: the fee can't read it as profit.
    function test_F5_aStrangersMintIsForwardedToTheHub() public {
        uint256 burns = messenger.burnCount();
        _mintFrom(stranger, 5_000e6, 0.5e6, 7);
        assertEq(vault.receivedFromOthers(), 5_000e6 - 0.5e6);
        assertEq(vault.othersPending(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(messenger.burnCount(), burns + 1);
        MockTokenMessenger.Burn memory b = messenger.burn(burns);
        assertEq(b.amount, 5_000e6 - 0.5e6);
        assertEq(b.mintRecipient, bytes32(uint256(uint160(hub))));
        assertEq(b.destinationCaller, bytes32(0), "anyone completes it: the hub books nothing, so it is capital");
        assertEq(vault.sentTo(0), 0, "not a member move");
        assertEq(_reportedUsd(), 0);
    }

    /// Circle paused: the money waits here, out of the holdings, unspendable by the key, and the next
    /// report forwards it.
    function test_F5_aForwardThatCannotGoWaitsUnspent() public {
        messenger.setPaused(true);
        _mintFrom(stranger, 100e6, 0, 8);
        assertEq(vault.othersPending(), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.toMargin(1);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        vault.send(0, 1, false, 0);
        messenger.setPaused(false);
        assertEq(_reportedUsd(), 0, "out of the holdings");
        assertEq(vault.othersPending(), 0, "the report forwarded it");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// In the exit too: the leg's own USDC goes to the hub as a member move, a stranger's apart.
    function test_F5_inTheExitAStrangersMoneyIsNeverAMemberMove() public {
        _beginExit();
        messenger.setPaused(true);
        _mintFrom(stranger, 100e6, 0, 9);
        usdc.mint(address(vault), 40e6); // the leg's own, back from HyperCore
        messenger.setPaused(false);
        vm.roll(vm.getBlockNumber() + 20);
        _step();
        assertEq(vault.othersPending(), 0);
        assertEq(vault.sentTo(0), 40e6, "only the leg's own counted");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// The Codex round's P1: what waited past Circle's per-message burn limit leaves in parts of 1 million
    /// USDC, each subtracted as it burns, never one burn Circle refuses for ever.
    function test_F5_aLargePendingLeavesInParts() public {
        messenger.setPaused(true);
        _mintFrom(stranger, 1_500_000e6, 0, 10);
        messenger.setPaused(false);
        uint256 burns = messenger.burnCount();
        vault.report();
        assertEq(vault.othersPending(), 500_000e6);
        assertEq(messenger.burn(burns).amount, 1_000_000e6);
        vault.report();
        assertEq(vault.othersPending(), 0);
        assertEq(messenger.burn(burns + 1).amount, 500_000e6);
    }

    // ── low 8 ────────────────────────────────────────────────────────────────────────────────────────

    /// The HYPE kept for the transfers' fee follows HyperEVM's base fee (0.0002 HYPE at 1 gwei or less).
    function test_L8_theHypeReserveFollowsTheBaseFee() public {
        core.setSpot(address(vault), HYPE, 990_000);
        core.setSpot(address(vault), 360, 300_000_000);
        _beginExit();
        (,, uint64[4] memory residue,) = vault.exitStatus();
        assertEq(residue[0], 990_000 - 20_000, "at 1 gwei or less: the least reserve");
        vm.fee(5 gwei);
        (,, residue,) = vault.exitStatus();
        assertEq(residue[0], 990_000 - 100_000, "200,000 gas at 5 gwei");
    }

    // ── low 9 ────────────────────────────────────────────────────────────────────────────────────────

    /// A stranger's wei on HyperEVM held the exit in CLOSING and the sweep with it; the sweep sends it to
    /// the hub first.
    function test_L9_aStrangersWeiNoLongerHoldsTheSweep() public {
        core.setSpot(address(vault), HYPE, 990_000);
        core.setSpot(address(vault), 360, 300_000_000);
        _beginExit();
        usdc.mint(address(vault), 1);
        (uint8 s,,,) = vault.exitStatus();
        assertEq(s, RECOVERED_WITH_RESIDUE, "a wei under the dust bound no longer holds it closing");
        vault.proposeSweep(wallet);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(stranger);
        vault.sweepResidue(HYPE, wallet);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// The Codex round's P2: under a positive Circle minimum fee one unit can't be burned (Circle's fee floors
    /// at one unit, and must stay under the amount); a burn that fails (the mock: paused) leaves it, and USDC
    /// under the 0.01 dust bound no longer holds the sweep. Above the bound it still does.
    function test_L9_anUnburnableUnitDoesNotHoldTheSweep() public {
        core.setSpot(address(vault), HYPE, 990_000);
        core.setSpot(address(vault), 360, 300_000_000);
        _beginExit();
        messenger.setPaused(true);
        usdc.mint(address(vault), 10_000); // 0.01 USDC: closing
        (uint8 s,,,) = vault.exitStatus();
        assertTrue(s != RECOVERED_WITH_RESIDUE, "0.01 USDC is not dust");
        usdc.burn(address(vault), 9_999);
        vault.proposeSweep(wallet);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(stranger);
        vault.sweepResidue(HYPE, wallet);
        assertEq(usdc.balanceOf(address(vault)), 1, "the unit stays, unburnable");
    }
}
