// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureCompat} from "./FixtureCompat.sol";
import {IAssetLegV1} from "../IAssetLegV1.sol";
import {Hub} from "../../src/Hub.sol";
import {HubFee} from "../../src/HubFee.sol";
import {MemberBase} from "../../src/MemberBase.sol";
import {MemberState} from "../../src/MemberState.sol";
import {StrategySpec} from "../../src/Types.sol";
import {Arbitrum} from "../../src/lib/Pinned.sol";
import {Assets, Holding, OwnerMessages} from "../../src/lib/VaultTypes.sol";
import {MockERC20, MockTokenMessenger, MockTransmitter, walletCred} from "../mocks/Mocks.sol";

/// The hub (amendment 2a, revision 1, §3.7, decisions 43–46): the strategy's account on Arbitrum, beside the
/// AAVE leg, the Hyperliquid leg on HyperEVM. Funded by the owner's deposit contract alone; sends the legs
/// their money within its daily fee budget; pays the owner; stores each leg's latest report; in exit, pays
/// the withdrawal address whatever it holds, as often as called. The unit world plays Arbitrum here, its
/// USDC a test double at the real address, so the hub and the AAVE leg share it.
/// PARITY (asset-profiles-design.md §10 slice 1): version 0's `test/Hub.t.sol` on version 1's hub,
/// through `FixtureCompat`.
contract StrategyHubCompatTest is FixtureCompat {
    Hub hub;
    IAssetLegV1 aave; // link 0: beside it
    address hl; // link 1: on HyperEVM
    MockERC20 arbUsdc;

    function setUp() public {
        _world();
        vm.chainId(42161);
        vm.etch(Arbitrum.USDC, type(MockERC20).runtimeCode);
        arbUsdc = MockERC20(Arbitrum.USDC);
        transmitter.setLocalDomain(ARB_DOMAIN);
        _arbitrumLong(Arbitrum.USDC);
        StrategySpec memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        address[] memory made =
            factory.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline));
        hub = Hub(made[0]);
        aave = IAssetLegV1((made[1]));
        hl = hub.links(1);
    }

    function _b(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _beginExit() internal {
        uint256 deadline = block.timestamp + 1 hours;
        hub.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
    }

    function _report(uint256 seq, uint256 observedAt) internal pure returns (bytes memory) {
        Holding[] memory h = new Holding[](2);
        h[0] = Holding(Assets.USD, int256(1_000e18));
        h[1] = Holding(Assets.ETH, -0.4e18);
        uint256[4] memory zero;
        return abi.encode(
            keccak256("dltx.strategy-vault.report.v1"), seq, observedAt, uint256(100), uint256(77), h, zero, zero, zero
        );
    }

    // ── funding and links ───────────────────────────────────────────────────────────────────────────

    function test_wiring_theOnlyMemberADepositAccountFunds() public view {
        assertEq(hub.linkCount(), 2);
        assertEq(hub.links(0), address(aave));
        assertEq(hub.linkDomains(1), HYPEREVM_DOMAIN);
        assertTrue(hub.ready(0), "the AAVE leg beside it: ready by its code");
        assertFalse(hub.ready(1));
        (address o,,) = factory.authorisedFor(address(hub));
        assertEq(o, address(owner));
        (o,,) = factory.authorisedFor(address(aave));
        assertEq(o, address(0));
        assertEq(hub.feeModule(), address(hubFee), "its fee module (amendment 2b)");
    }

    /// The hub holds no market position and makes no market call: nothing falls through its fallback.
    function test_noMarketCall() public {
        (bool ok, bytes memory ret) = address(hub).call(abi.encodeWithSignature("supply(uint256)", 1));
        assertFalse(ok);
        assertEq(bytes4(ret), MemberState.Unsupported.selector);
        (ok, ret) = address(hub).call(abi.encodeWithSignature("report()"));
        assertFalse(ok);
        assertEq(bytes4(ret), MemberState.Unsupported.selector);
    }

    // ── the execution key: send and payout ──────────────────────────────────────────────────────────

    function test_send_toTheLegBeside_andAcrossChains_countedPerPair() public {
        arbUsdc.mint(address(hub), 1_000e6);
        vm.prank(key);
        hub.send(0, 600e6, false, 0);
        assertEq(arbUsdc.balanceOf(address(aave)), 600e6, "a transfer, no Circle");
        assertEq(hub.sentTo(0), 600e6);
        assertEq(aave.receivedFrom(0), 600e6);
        // across chains, once the Hyperliquid leg's READY arrived; the mint bound to it
        vm.prank(key);
        vm.expectRevert(MemberState.NotReady.selector);
        hub.send(1, 100e6, false, 0);
        _deliverReady(address(hub), HYPEREVM_DOMAIN, hl);
        vm.prank(key);
        hub.send(1, 100e6, true, 0.05e6);
        MockTokenMessenger.Burn memory b = messenger.burn(0);
        assertEq(b.burnToken, Arbitrum.USDC);
        assertEq(b.destinationDomain, HYPEREVM_DOMAIN);
        assertEq(b.mintRecipient, _b(hl));
        assertEq(b.destinationCaller, _b(hl));
        assertEq(b.maxFee, 0.05e6);
        assertEq(hub.sentTo(1), 100e6);
        // the AAVE leg's money back to the hub, beside it (its `send` reads AAVE: the fork suite's), pulled
        vm.startPrank(address(aave));
        arbUsdc.approve(address(hub), 200e6);
        hub.receiveLocal(200e6);
        vm.stopPrank();
        assertEq(hub.receivedFrom(0), 200e6);
        assertEq(arbUsdc.balanceOf(address(hub)), 500e6);
        vm.prank(key);
        vm.expectRevert(MemberState.FeeAboveCap.selector);
        hub.send(1, 100e6, true, 0.05e6 + 1); // 5 bp
    }

    /// Invariant 6: Circle's fees within 50 bp of the hub's USDC per 24 hours.
    function test_send_feeBudget() public {
        _deliverReady(address(hub), HYPEREVM_DOMAIN, hl);
        vm.startPrank(key);
        for (uint256 i; i < 10; ++i) {
            arbUsdc.mint(address(hub), 1_000e6);
            hub.send(1, 1_000e6, true, 0.5e6); // 5 in all: 50 bp of 1,000, exactly
        }
        arbUsdc.mint(address(hub), 1_000e6);
        vm.expectRevert(MemberState.OverFeeBudget.selector);
        hub.send(1, 1_000e6, true, 0.5e6);
        hub.send(1, 1_000e6, false, 0); // standard: Circle's minimum only, none here
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        arbUsdc.mint(address(hub), 1_000e6);
        vm.prank(key);
        hub.send(1, 1_000e6, true, 0.5e6);
    }

    function test_payout_toTheOwner_byTheKeyAlone() public {
        arbUsdc.mint(address(hub), 100e6);
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        HubFee(address(hub)).payout(1, new uint80[](0));
        vm.prank(key);
        HubFee(address(hub)).payout(40e6, new uint80[](0));
        assertEq(arbUsdc.balanceOf(address(owner)), 40e6, "to the deposit account");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _actionSig(address(hub), OwnerMessages.REVOKE_EXECUTION, address(0), 0, deadline);
        hub.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, sig);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HubFee(address(hub)).payout(1, new uint80[](0));
        _beginExit();
        vm.prank(key);
        vm.expectRevert(MemberState.Exiting.selector);
        HubFee(address(hub)).payout(1, new uint80[](0));
    }

    // ── the exit ────────────────────────────────────────────────────────────────────────────────────

    /// The hub's owner enters: the AAVE leg beside it directly, the Hyperliquid leg by Circle.
    function test_exit_tellsBothLegs() public {
        uint256 sent = transmitter.sentCount();
        _beginExit();
        assertTrue(aave.exiting());
        assertEq(transmitter.sentCount(), sent + 1);
        MockTransmitter.Sent memory m = transmitter.sent(sent);
        assertEq(m.recipient, _b(hl));
        assertEq(m.body, abi.encode(hub.EXIT_MESSAGE()));
        assertEq(hub.toldPending(), 0);
    }

    /// Pay-as-you-go: anyone, as often as needed; what arrives later is paid by a later call; held while
    /// no withdrawal address is set.
    function test_exit_paysTheWithdrawalAddress_asItArrives() public {
        arbUsdc.mint(address(hub), 30e6);
        vm.expectRevert(MemberState.NotExiting.selector);
        hub.exitStep();
        owner.setWithdrawalAddress(address(0));
        _beginExit();
        vm.startPrank(stranger);
        hub.exitStep();
        assertEq(arbUsdc.balanceOf(address(hub)), 30e6, "held: no address");
        owner.setWithdrawalAddress(withdrawalTo);
        hub.exitStep();
        assertEq(arbUsdc.balanceOf(withdrawalTo), 30e6);
        hub.exitStep(); // nothing: harmless
        arbUsdc.mint(address(hub), 12e6); // the Hyperliquid leg's money, minted later
        hub.exitStep();
        vm.stopPrank();
        assertEq(arbUsdc.balanceOf(withdrawalTo), 42e6);
        assertEq(arbUsdc.balanceOf(address(owner)), 0, "never the deposit account");
    }

    // ── reports (§3.6, decision 45) ─────────────────────────────────────────────────────────────────

    function test_report_highestSequenceKept_observedAndReceivedApart() public {
        (uint64 seq,,,) = hub.reportOf(1);
        assertEq(seq, 0);
        uint256 t = vm.getBlockTimestamp();
        transmitter.deliver(address(hub), HYPEREVM_DOMAIN, _b(hl), _report(2, t - 300));
        bytes memory body;
        uint64 observedAt;
        uint64 receivedAt;
        (seq, observedAt, receivedAt, body) = hub.reportOf(1);
        assertEq(seq, 2);
        assertEq(observedAt, t - 300, "the leg's own clock");
        assertEq(receivedAt, t, "the arrival, kept apart");
        assertEq(body, _report(2, t - 300));
        // Circle delivers out of order: an older report arriving late changes nothing
        vm.warp(t + 60);
        transmitter.deliver(address(hub), HYPEREVM_DOMAIN, _b(hl), _report(1, t - 600));
        (seq, observedAt, receivedAt,) = hub.reportOf(1);
        assertEq(seq, 2);
        assertEq(receivedAt, t);
        transmitter.deliver(address(hub), HYPEREVM_DOMAIN, _b(hl), _report(3, t + 30));
        (seq, observedAt, receivedAt,) = hub.reportOf(1);
        assertEq(seq, 3);
        assertEq(observedAt, t + 30);
        assertEq(receivedAt, t + 60);
        // the leg beside it hands its report directly
        vm.prank(address(aave));
        hub.receiveReport(_report(1, t));
        (seq,,,) = hub.reportOf(0);
        assertEq(seq, 1);
        (seq,,,) = hub.reportOf(1);
        assertEq(seq, 3, "each leg its own");
    }

    function test_report_refusals() public {
        bytes memory body = _report(1, block.timestamp);
        // finalized only
        vm.prank(TRANSMITTER);
        vm.expectRevert(MemberState.BadMessage.selector);
        hub.handleReceiveUnfinalizedMessage(HYPEREVM_DOMAIN, _b(hl), 1000, body);
        vm.prank(TRANSMITTER);
        vm.expectRevert(MemberState.BadMessage.selector);
        hub.handleReceiveFinalizedMessage(HYPEREVM_DOMAIN, _b(hl), 1000, body);
        // from no member; from a member by the wrong way
        vm.expectRevert(MemberState.BadMessage.selector);
        transmitter.deliver(address(hub), HYPEREVM_DOMAIN, _b(stranger), body);
        vm.prank(stranger);
        vm.expectRevert(MemberState.BadMessage.selector);
        hub.receiveReport(body);
        vm.prank(hl); // a leg on another chain reports through Circle
        vm.expectRevert(MemberState.BadMessage.selector);
        hub.receiveReport(body);
        vm.expectRevert(MemberState.BadMessage.selector);
        transmitter.deliver(address(hub), ARB_DOMAIN, _b(address(aave)), body); // the local leg never messages
        // malformed: too short, a sequence number past 64 bits
        bytes32 tag = keccak256("dltx.strategy-vault.report.v1");
        bytes memory short_ = abi.encode(tag, uint256(1));
        vm.expectRevert(MemberState.BadMessage.selector);
        transmitter.deliver(address(hub), HYPEREVM_DOMAIN, _b(hl), short_);
        bytes memory huge = abi.encode(tag, uint256(type(uint64).max) + 1, block.timestamp);
        vm.expectRevert(MemberState.BadMessage.selector);
        transmitter.deliver(address(hub), HYPEREVM_DOMAIN, _b(hl), huge);
        vm.prank(address(aave));
        vm.expectRevert(MemberState.BadMessage.selector);
        hub.receiveReport(abi.encode(keccak256("other"), uint256(1), block.timestamp));
        (uint64 seq,,,) = hub.reportOf(1);
        assertEq(seq, 0);
    }

    /// Reports keep arriving in exit: the valuation's input, whatever the state.
    function test_report_inExit() public {
        _beginExit();
        transmitter.deliver(address(hub), HYPEREVM_DOMAIN, _b(hl), _report(1, block.timestamp));
        (uint64 seq,,,) = hub.reportOf(1);
        assertEq(seq, 1);
    }

    function test_hubCode_neverInitializable_andItsParams() public {
        vm.expectRevert(MemberState.AlreadyInitialized.selector);
        hub.initialize(stranger, stranger, new address[](1), new uint32[](1), 0, bytes32(0), bytes32(0), "");
        assertEq(hub.fastFeeCapBp(), 5);
        assertEq(hub.feeBudgetBp(), 50);
        assertEq(MemberBase(address(hubCode)).factory(), address(1));
    }
}
