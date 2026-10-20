// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Fixture} from "./utils/Fixture.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";
import {ShortVaultState} from "../src/ShortVaultState.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {Assets, Holding, OwnerMessages, ShortParams, StrategyConfig, VaultConfig} from "../src/lib/VaultTypes.sol";
import {MockTokenMessenger, MockTransmitter, walletCred} from "./mocks/Mocks.sol";

/// The Hyperliquid leg with HyperCore mocked: the execution key's functions, the owner's actions, the
/// exit's entry, and the exit's state-driven table (§8.4, §13).
contract ShortVaultTest is Fixture {
    ShortVault vault;
    ShortVaultExit ex; // the same address: the exit module's functions, dispatched by the leg's fallback
    address hub; // link 0
    address sister; // link 1: the AAVE leg
    uint256 sent0; // Circle messages sent by the creation (the READY to the hub and to the AAVE leg)

    function setUp() public {
        _world();
        vault = ShortVault(payable(_create(_config())));
        ex = ShortVaultExit(address(vault));
        hub = vault.links(0);
        sister = vault.links(1);
        sent0 = transmitter.sentCount();
        _deliverReady(address(vault), ARB_DOMAIN, hub); // both have announced themselves
        _deliverReady(address(vault), ARB_DOMAIN, sister);
        core.setExists(address(vault), true);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    function _beginExit() internal {
        uint256 deadline = block.timestamp + 1 hours;
        vault.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
    }

    function _noArgs() internal pure returns (ShortVaultState.ExitArgs memory a) {}

    function _watched() internal view returns (uint32[] memory dexes) {
        (, dexes,,) = ex.exitStatus();
    }

    function _step() internal returns (bytes[] memory) {
        return _stepWith(_noArgs());
    }

    function _stepWith(ShortVaultState.ExitArgs memory a) internal returns (bytes[] memory) {
        uint256 from = writer.count();
        vm.prank(stranger);
        ex.exitStep(a);
        return _since(from);
    }

    function _pace() internal {
        vm.roll(vm.getBlockNumber() + 20);
    }

    function _state() internal view returns (uint8 state, uint64[4] memory residue, uint256 flags) {
        (state,, residue, flags) = ex.exitStatus();
    }

    // the S12 figures, as the contract must compute them
    uint64 constant CLOSE_SHORT_PX = 245_570_000_000; // 2,431.40 × 1.01 = 2,455.714 → 5 significant figures, down
    uint64 constant HYPE_BUY_PX = 8_106_600_000; // 80.2635 × 1.01 = 81.066135 → 81.066
    uint64 constant HYPE_BUY_SZ = 13_000_000; // floor(11 / 81.066 / 0.01) steps = 0.13 HYPE
    uint64 constant HYPE_SELL_PX = 7_946_100_000; // 80.2635 × 0.99 = 79.460865 → up: 79.461

    // ── wiring ───────────────────────────────────────────────────────────────────────────────────────

    function test_wiring() public view {
        assertEq(vault.owner(), address(owner));
        assertEq(vault.factory(), address(factory));
        assertEq(vault.linkDomains(0), ARB_DOMAIN);
        assertEq(vault.perp(), ETH);
        assertEq(vault.orderBoundBp(), 100);
        address[] memory at = _legs(_config());
        assertEq(at[2], address(vault));
        assertEq(hub, at[0]);
        assertEq(sister, at[1]);
        assertEq(vault.linkCount(), 2);
        assertEq(vault.asset(), Assets.ETH);
        assertEq(vault.feeBudgetBp(), 50);
        assertEq(vault.registry(), address(registry));
    }

    function test_initializeOnce() public {
        vm.expectRevert(VaultState.AlreadyInitialized.selector);
        vault.initialize(stranger, stranger, new address[](1), new uint32[](1), 0, bytes32(0), bytes32(0), "");
        vm.expectRevert(VaultState.AlreadyInitialized.selector);
        shortCode.initialize(stranger, stranger, new address[](1), new uint32[](1), 0, bytes32(0), bytes32(0), "");
    }

    // ── the execution key's functions and their bytes ────────────────────────────────────────────────

    function test_onlyTheGroupKey() public {
        vm.startPrank(stranger);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.toMargin(1);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.fromMargin(1);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.send(0, 1, false, 0);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.proposeAgent(stranger);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.order(true, 1, false);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.pause(true);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.topUpHype(0);
        vm.stopPrank();
    }

    function test_toMargin_circleDepositToItsOwnPerpMargin() public {
        usdc.mint(address(vault), 25e6);
        vm.prank(key);
        vault.toMargin(25e6);
        assertEq(usdc.balanceOf(CDW), 25e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_fromMargin_bytes() public {
        uint256 from = writer.count();
        vm.prank(key);
        vault.fromMargin(4_000_000);
        bytes[] memory a = _since(from);
        assertEq(a.length, 2);
        // hand-written: action 7, ntl 4_000_000, toPerp false
        assertEq(
            a[0],
            bytes.concat(
                hex"01000007",
                hex"00000000000000000000000000000000000000000000000000000000003d0900",
                hex"0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
        assertEq(a[1], _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 400_000_000));
    }

    function test_order_boundedByTheOracle_bytes() public {
        uint256 from = writer.count();
        vm.prank(key);
        vault.order(true, 450_000, true);
        // hand-written: asset 1, buy, 2,455.70 (0x392d1cd480), 0.0045 (0x6ddd0), reduce-only, IOC, no cloid
        bytes memory want = bytes.concat(
            hex"01000001",
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            hex"000000000000000000000000000000000000000000000000000000392d1cd480",
            hex"000000000000000000000000000000000000000000000000000000000006ddd0",
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            hex"0000000000000000000000000000000000000000000000000000000000000003",
            hex"0000000000000000000000000000000000000000000000000000000000000000"
        );
        assertEq(uint256(CLOSE_SHORT_PX), 0x392d1cd480);
        assertEq(_since(from)[0], want);
    }

    /// Decision 33: the key's own orders are reduce-only; growing the hedge goes through the agent.
    function test_order_reduceOnlyOnly() public {
        vm.prank(key);
        vm.expectRevert(VaultState.NotAllowed.selector);
        vault.order(false, 450_000, false);
    }

    function test_pause_neverBlocksMoneyOut() public {
        vm.prank(key);
        vault.pause(true);
        vm.startPrank(key);
        vault.order(false, 450_000, true); // reduce-only still goes
        vault.fromMargin(1_000_000); // margin out never blocked
        usdc.mint(address(vault), 1e6);
        vault.send(0, 1e6, false, 0); // nor money to the hub
        vm.stopPrank();
    }

    function test_cancel_bytes() public {
        uint256 from = writer.count();
        vm.startPrank(key);
        vault.cancel(ETH, false, 77);
        vault.cancel(ETH, true, 0xbeef);
        vm.stopPrank();
        bytes[] memory a = _since(from);
        assertEq(a[0], _core(10, abi.encode(ETH, uint64(77))));
        assertEq(a[1], _core(11, abi.encode(ETH, uint128(0xbeef))));
    }

    function test_topUpHype_sendsToTheSystemAddress() public {
        vm.deal(key, 1 ether);
        vm.prank(key);
        vault.topUpHype{value: 0.01 ether}(0.01 ether);
        assertEq(HYPE_SYSTEM.balance, 0.01 ether);
    }

    function test_receive_onlyFromHyperCore() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
        vm.deal(HYPE_SYSTEM, 1 ether);
        vm.prank(HYPE_SYSTEM);
        (ok,) = address(vault).call{value: 1}("");
        assertTrue(ok);
    }

    /// Invariant 2: no money to a member before its finalized READY; the creation sent the leg's own to
    /// both.
    function test_send_waitsForEachMembersReady() public {
        ShortParams memory sp = _shortParams();
        sp.perp = 2;
        StrategyConfig memory c = _configWith(_longParams(), sp);
        uint256 before = transmitter.sentCount();
        ShortVault fresh = ShortVault(payable(_create(c)));
        assertEq(transmitter.sentCount(), before + 2);
        for (uint256 k; k < 2; ++k) {
            MockTransmitter.Sent memory m = transmitter.sent(before + k);
            assertEq(m.destinationDomain, ARB_DOMAIN);
            assertEq(m.recipient, bytes32(uint256(uint160(fresh.links(k)))));
            assertEq(m.minFinalityThreshold, 2000);
            assertEq(m.body, abi.encode(fresh.READY_MESSAGE()));
        }
        usdc.mint(address(fresh), 20e6);
        vm.prank(key);
        vm.expectRevert(VaultState.NotReady.selector);
        fresh.send(0, 10e6, false, 0);
        _deliverReady(address(fresh), ARB_DOMAIN, fresh.links(0));
        vm.prank(key);
        fresh.send(0, 10e6, false, 0);
        assertEq(messenger.burn(0).mintRecipient, bytes32(uint256(uint160(fresh.links(0)))));
        vm.prank(key);
        vm.expectRevert(VaultState.NotReady.selector);
        fresh.send(1, 10e6, false, 0); // the AAVE leg's READY not here yet
        _deliverReady(address(fresh), ARB_DOMAIN, fresh.links(1));
        vm.prank(key);
        fresh.send(1, 10e6, false, 0);
        assertEq(messenger.burn(1).mintRecipient, bytes32(uint256(uint160(fresh.links(1)))));
    }

    function test_send_boundToTheMember_feeCapped() public {
        usdc.mint(address(vault), 1_000e6);
        vm.prank(key);
        vm.expectRevert(VaultState.FeeAboveCap.selector);
        vault.send(0, 1_000e6, true, 0.51e6); // cap 5 bp = 0.5 USDC
        vm.prank(key);
        vault.send(0, 1_000e6, true, 0.5e6);
        MockTokenMessenger.Burn memory b = messenger.burn(0);
        assertEq(b.amount, 1_000e6);
        assertEq(b.destinationDomain, ARB_DOMAIN);
        assertEq(b.mintRecipient, bytes32(uint256(uint160(hub))));
        assertEq(b.maxFee, 0.5e6);
        assertEq(b.minFinalityThreshold, 1000);
        assertEq(b.destinationCaller, bytes32(uint256(uint160(hub))), "only the hub completes the mint");
        assertEq(vault.sentTo(0), 1_000e6);
        // standard: no fee but Circle's minimum, whatever `maxFee` says; to the AAVE leg directly
        usdc.mint(address(vault), 1_000e6);
        vm.prank(key);
        vault.send(1, 1_000e6, false, 0.5e6);
        b = messenger.burn(1);
        assertEq(b.maxFee, 0);
        assertEq(b.minFinalityThreshold, 2000);
        assertEq(b.mintRecipient, bytes32(uint256(uint160(sister))));
        assertEq(b.destinationCaller, bytes32(uint256(uint160(sister))));
        assertEq(vault.sentTo(1), 1_000e6);
    }

    /// Invariant 6: Circle's fees within 50 bp a day of the account's value (perp account value, spot
    /// USDC, HyperEVM USDC).
    function test_send_feeBudget_ofTheAccountsValue() public {
        core.setMargin(0, address(vault), 1_000e6, 0, 0); // 1,000 of account value on HyperCore
        usdc.mint(address(vault), 1_000e6);
        vm.startPrank(key);
        vault.send(0, 1_000e6, true, 0.5e6); // 0.5 of a 10 budget (50 bp of 2,000)
        usdc.mint(address(vault), 1_000e6);
        for (uint256 i; i < 17; ++i) vault.send(0, 50e6, true, 0.025e6); // 0.425 more: 0.925
        vm.stopPrank();
        // the budget of a smaller account: its HyperCore value gone
        core.setMargin(0, address(vault), 0, 0, 0);
        vm.prank(key);
        vm.expectRevert(VaultState.OverFeeBudget.selector);
        vault.send(0, 50e6, true, 0.025e6); // 0.95 against 50 bp of 150
    }

    /// Circle's minimum fee (its controller may raise it): every burn pays it, standard or fast, and
    /// none pays it above 10 bp; the exit's bridge waits rather than paying more.
    function test_send_paysCirclesMinimumFee_cappedAt10bp() public {
        usdc.mint(address(vault), 3_000e6);
        messenger.setMinFeeBp(1); // 1 bp
        vm.startPrank(key);
        vault.send(0, 1_000e6, false, 0);
        assertEq(messenger.burn(0).maxFee, 0.1e6);
        assertEq(messenger.burn(0).minFinalityThreshold, 2000);
        vault.send(0, 1_000e6, true, 0.05e6); // a fast fee below the minimum is raised to it
        assertEq(messenger.burn(1).maxFee, 0.1e6);
        messenger.setMinFeeBp(11);
        vm.expectRevert(VaultState.FeeAboveCap.selector);
        vault.send(0, 1_000e6, false, 0);
        vm.stopPrank();
        _beginExit();
        ex.bridgeOut();
        assertEq(messenger.burnCount(), 2, "the exit's bridge waits above the cap");
        messenger.setMinFeeBp(10);
        ex.bridgeOut();
        assertEq(messenger.burn(2).maxFee, 1e6);
        assertEq(messenger.burn(2).amount, 1_000e6);
    }

    // ── reports (§3.6, decision 45) ──────────────────────────────────────────────────────────────────

    function _lastReport() internal view returns (Holding[] memory h, uint256[4] memory received, uint256[4] memory fees) {
        MockTransmitter.Sent memory m = transmitter.sent(transmitter.sentCount() - 1);
        assertEq(m.recipient, bytes32(uint256(uint160(hub))), "to its hub");
        assertEq(m.minFinalityThreshold, 2000);
        (,,,,, h,, received, fees) = abi.decode(m.body, (bytes32, uint256, uint256, uint256, uint256, Holding[], uint256[4], uint256[4], uint256[4]));
    }

    /// The hub's money on its way: in flight (the hub's `sentTo`, nothing here), minted on HyperEVM (in
    /// this leg's USD and `receivedFrom`), deposited into HyperCore (in its perp cash): its USD the same
    /// once it landed, whichever side of the deposit.
    function test_report_aMintThenADeposit_theTotalHolds() public {
        vm.prank(stranger);
        ex.report();
        (Holding[] memory h, uint256[4] memory received,) = _lastReport();
        assertEq(h[0].asset, Assets.USD);
        assertEq(h[0].quantity, 0);
        assertEq(received[0], 0, "in flight: the hub's sentTo alone counts it");
        bytes memory m = abi.encodePacked(
            abi.encodePacked(uint32(1), ARB_DOMAIN, HYPEREVM_DOMAIN, bytes32(uint256(1)), bytes32(uint256(uint160(TOKEN_MESSENGER))), bytes32(uint256(uint160(TOKEN_MESSENGER))), bytes32(uint256(uint160(address(vault)))), uint32(1000), uint32(1000)),
            abi.encodePacked(uint32(1), bytes32(uint256(uint160(USDC))), bytes32(uint256(uint160(address(vault)))), uint256(500e6), bytes32(uint256(uint160(hub))), uint256(0.05e6), uint256(0.05e6), uint256(0))
        );
        ex.receiveMint(m, "");
        ex.report();
        uint256[4] memory fees;
        (h, received, fees) = _lastReport();
        assertEq(h[0].quantity, int256(500e6 - 0.05e6) * 1e12);
        assertEq(received[0], 500e6);
        assertEq(fees[0], 0.05e6);
        vm.prank(key);
        vault.toMargin(500e6 - 0.05e6);
        core.setMargin(0, address(vault), int64(int256(500e6 - 0.05e6)), 0, 0); // HyperCore credited it
        ex.report();
        (h,,) = _lastReport();
        assertEq(h[0].quantity, int256(500e6 - 0.05e6) * 1e12, "the same total");
        assertEq(h[1].asset, Assets.ETH);
        core.setPosition(address(vault), uint16(ETH), -4_500);
        ex.report();
        (h,,) = _lastReport();
        assertEq(h[1].quantity, -0.45e18);
    }

    /// Amendment 2b (the security review's finding 3, then the review of 2026-10-16): `rawUsd` holds the
    /// proceeds of every DEX 0 position and only the strategy's perp is reported, so the report's cash is
    /// `accountValue − szi × markPx`: the perp's cash, plus every other DEX 0 position at its mark. A side
    /// short the agent opens adds nothing (its proceeds and its liability together); its loss counts.
    function test_report_anotherDex0Position_valuedAtItsMark() public {
        core.setPosition(address(vault), uint16(ETH), -4_500); // 0.45 ETH
        core.setMark(ETH, 243_140); // 2,431.40: the short's $1,094.13 at its mark
        // $1,000 of value: rawUsd = 1,000 + the short's proceeds
        core.setMarginRaw(0, address(vault), 1_000e6, 100e6, 1_094_130_000, 2_094_130_000);
        vm.prank(stranger);
        ex.report();
        (Holding[] memory h,,) = _lastReport();
        assertEq(h[0].quantity, 2_094_130_000e12, "rawUsd exactly, by the probe's identity");
        // a $100k side short, marks at entry: its proceeds in rawUsd, the account worth the same
        core.setMarginRaw(0, address(vault), 1_000e6, 4_100e6, 101_094_130_000, 102_094_130_000);
        ex.report();
        (h,,) = _lastReport();
        assertEq(h[0].quantity, 2_094_130_000e12, "the side short adds nothing");
        // the side short loses $50
        core.setMarginRaw(0, address(vault), 950e6, 4_100e6, 101_144_130_000, 102_094_130_000);
        ex.report();
        (h,,) = _lastReport();
        assertEq(h[0].quantity, 2_044_130_000e12, "its loss counts");
        (Holding[] memory v,,,,,,) = ex.holdings();
        assertEq(v[0].quantity, h[0].quantity, "holdings() the same");
    }

    // ── the agent (§8.5) ─────────────────────────────────────────────────────────────────────────────

    function test_firstAgentAtOnce_thenDelayed() public {
        address a1 = makeAddr("agent-1");
        address a2 = makeAddr("agent-2");
        vm.startPrank(key);
        vault.proposeAgent(a1);
        uint256 from = writer.count();
        vault.applyAgent();
        assertEq(_since(from)[0], _agentBytes(a1));
        assertEq(vault.agent(), a1);
        vault.proposeAgent(a2);
        vm.expectRevert(ShortVaultState.TooEarly.selector);
        vault.applyAgent();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.applyAgent();
        vm.stopPrank();
        assertEq(vault.agent(), a2);
    }

    function test_applyAgent_needsTheCoreAccount() public {
        core.setExists(address(vault), false);
        vm.startPrank(key);
        vault.proposeAgent(makeAddr("agent"));
        vm.expectRevert(ShortVaultState.NoCoreAccount.selector);
        vault.applyAgent();
        vm.stopPrank();
    }

    function test_ownerCancelsAPendingAgent() public {
        vm.startPrank(key);
        vault.proposeAgent(makeAddr("agent-1"));
        vault.applyAgent();
        vault.proposeAgent(makeAddr("agent-2"));
        vm.stopPrank();
        uint256 deadline = block.timestamp + 1 hours;
        vault.ownerAction(OwnerMessages.CANCEL_AGENT, address(0), walletCred(wallet), deadline, _actionSig(address(vault), OwnerMessages.CANCEL_AGENT, address(0), 0, deadline));
        assertEq(vault.pendingAgent(), address(0));
        assertEq(vault.ownerNonceOf(walletCred(wallet)), 1, "the signer's own nonce spent");
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(key);
        vm.expectRevert(ShortVaultState.NoAgent.selector);
        vault.applyAgent();
    }

    /// Decision 34: the owner's replacement by the burner is at once (it cuts trading off)...
    function test_ownerReplacesWithTheBurner_atOnce() public {
        address b = vault.burner();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _actionSig(address(vault), OwnerMessages.REPLACE_AGENT, b, 0, deadline);
        uint256 from = writer.count();
        vm.prank(stranger); // anyone submits; the signature is the power
        vault.ownerAction(OwnerMessages.REPLACE_AGENT, b, walletCred(wallet), deadline, sig);
        assertEq(_since(from)[0], _agentBytes(b));
        assertEq(vault.agent(), b);
        // the same signature again: its nonce is spent
        vm.expectRevert(VaultState.BadSignature.selector);
        vault.ownerAction(OwnerMessages.REPLACE_AGENT, b, walletCred(wallet), deadline, sig);
    }

    /// ...any other agent takes effect after 24 hours, cancellable by any owner credential.
    function test_ownerReplacesWithAnotherAgent_after24h_cancellable() public {
        address mine = makeAddr("owner-agent");
        uint256 deadline = block.timestamp + 3 days;
        uint256 from = writer.count();
        vault.ownerAction(3, mine, walletCred(wallet), deadline, _actionSig(address(vault), 3, mine, 0, deadline));
        assertEq(writer.count(), from, "nothing sent yet");
        assertEq(vault.ownerAgent(), mine);
        vm.expectRevert(ShortVaultState.TooEarly.selector);
        vault.applyOwnerAgent();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(stranger);
        vault.applyOwnerAgent();
        assertEq(vault.agent(), mine);
        assertEq(_since(from)[0], _agentBytes(mine));
        // a second choice, cancelled within its 24 hours
        address next = makeAddr("owner-agent-2");
        vault.ownerAction(3, next, walletCred(wallet), deadline, _actionSig(address(vault), 3, next, 1, deadline));
        vault.ownerAction(4, address(0), walletCred(wallet), deadline, _actionSig(address(vault), 4, address(0), 2, deadline));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(ShortVaultState.NoAgent.selector);
        vault.applyOwnerAgent();
        assertEq(vault.agent(), mine);
    }

    /// In exit too: the burner stands until the owner's own agent has waited its 24 hours.
    function test_ownerAgentInExit_after24h() public {
        _beginExit();
        address mine = makeAddr("owner-agent");
        uint256 deadline = block.timestamp + 3 days;
        vault.ownerAction(3, mine, walletCred(wallet), deadline, _actionSig(address(vault), 3, mine, 0, deadline));
        assertEq(vault.agent(), vault.burner());
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.applyOwnerAgent();
        assertEq(vault.agent(), mine);
        assertEq(vault.exitAgent(), mine, "the exit re-sends the owner's agent from now on");
    }

    function test_revokeExecution_dropsDltxsPendingAgent() public {
        vm.prank(key);
        vault.proposeAgent(makeAddr("agent-1"));
        uint256 deadline = block.timestamp + 1 hours;
        vault.ownerAction(1, address(0), walletCred(wallet), deadline, _actionSig(address(vault), 1, address(0), 0, deadline));
        assertEq(vault.pendingAgent(), address(0));
    }

    function test_ownerAction_refusals() public {
        uint256 deadline = block.timestamp + 1 hours;
        // a stranger's key
        (, uint256 otherPk) = makeAddrAndKey("not-the-owner");
        bytes memory bad = _sign(
            otherPk,
            address(owner),
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, address(vault), block.chainid, uint8(1), address(0), uint256(0), deadline))
        );
        vm.expectRevert(VaultState.BadSignature.selector);
        vault.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, bad);
        // expired
        bytes memory sig = _actionSig(address(vault), OwnerMessages.REVOKE_EXECUTION, address(0), 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(VaultState.Expired.selector);
        vault.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, sig);
    }

    function test_revokeExecution_thenAllow() public {
        uint256 deadline = block.timestamp + 1 hours;
        vault.ownerAction(1, address(0), walletCred(wallet), deadline, _actionSig(address(vault), 1, address(0), 0, deadline));
        vm.prank(key);
        vm.expectRevert(VaultState.NotAllowed.selector);
        vault.fromMargin(1);
        vault.ownerAction(2, address(0), walletCred(wallet), deadline, _actionSig(address(vault), 2, address(0), 1, deadline));
        vm.prank(key);
        vault.fromMargin(1);
    }

    // ── entering the exit (§8.4, decisions 20, 23, 27) ──────────────────────────────────────────────

    function test_beginExit_blocksDltx_cancelsThePendingAgent_replacesIt_tellsEveryMember() public {
        vm.startPrank(key);
        vault.proposeAgent(makeAddr("agent-1"));
        vault.applyAgent();
        vault.proposeAgent(makeAddr("agent-2"));
        vm.stopPrank();
        uint256 from = writer.count();
        _beginExit();
        assertTrue(vault.exiting());
        assertEq(vault.pendingAgent(), address(0));
        address burner = vault.exitAgent();
        assertEq(vault.agent(), burner);
        assertEq(_since(from)[0], _agentBytes(burner));
        // the hub and the AAVE leg told, at once
        assertFalse((vault.toldPending() != 0));
        assertEq(transmitter.sentCount(), sent0 + 2);
        for (uint256 k; k < 2; ++k) {
            MockTransmitter.Sent memory m = transmitter.sent(sent0 + k);
            assertEq(m.destinationDomain, ARB_DOMAIN);
            assertEq(m.recipient, bytes32(uint256(uint160(vault.links(k)))));
            assertEq(m.destinationCaller, bytes32(0));
            assertEq(m.body, abi.encode(vault.EXIT_MESSAGE()));
        }
        // DLTX is blocked
        vm.startPrank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        vault.fromMargin(1);
        vm.expectRevert(VaultState.Exiting.selector);
        vault.proposeAgent(stranger);
        vm.expectRevert(VaultState.Exiting.selector);
        vault.applyAgent();
        vm.expectRevert(VaultState.Exiting.selector);
        vault.send(0, 1, false, 0);
        vm.stopPrank();
    }

    function test_beginExit_replayIsHarmless_andSurvivesNonceChanges() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory exitSig = _beginExitSig(STRATEGY, deadline);
        // an unrelated local action moves the nonce first
        vault.ownerAction(1, address(0), walletCred(wallet), deadline, _actionSig(address(vault), 1, address(0), 0, deadline));
        vault.beginExit(deadline, exitSig);
        vault.beginExit(deadline, exitSig); // a replay does nothing
        assertEq(transmitter.sentCount(), sent0 + 2);
    }

    function test_beginExit_refusals() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory other = _beginExitSig(bytes32(uint256(1)), deadline); // another strategy's
        vm.expectRevert(VaultState.BadSignature.selector);
        vault.beginExit(deadline, other);
        vm.expectRevert(VaultState.GroupNotStopped.selector);
        vault.beginExitStopped();
    }

    function test_strangerBeginsTheExitAfter7DaysWithoutCheckIn() public {
        vm.warp(vm.getBlockTimestamp() + 6 days);
        vm.prank(key);
        registry.checkIn(0);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(VaultState.GroupNotStopped.selector);
        vault.beginExitStopped();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        vault.beginExitStopped();
        assertTrue(vault.exiting());
    }

    function test_circlePaused_exitStillCommits_thenNotifyEachMember() public {
        transmitter.setPaused(true);
        _beginExit();
        assertTrue(vault.exiting());
        assertTrue((vault.toldPending() != 0));
        assertEq(vault.agent(), vault.exitAgent()); // the agent replaced locally all the same
        (,, uint256 flags) = _state();
        assertEq(flags & F_PARTNER_PENDING, F_PARTNER_PENDING);
        assertEq(vault.toldPending(), 3);
        vm.expectRevert(bytes("Pausable: paused"));
        vault.notifyLink(0);
        transmitter.setPaused(false);
        vm.prank(stranger);
        vault.notifyLink(0);
        assertEq(vault.toldPending(), 2);
        (,, flags) = _state();
        assertEq(flags & F_PARTNER_PENDING, F_PARTNER_PENDING, "a member still untold");
        vault.notifyLink(1);
        assertFalse((vault.toldPending() != 0));
        (,, flags) = _state();
        assertEq(flags & F_PARTNER_PENDING, 0);
        assertEq(transmitter.sentCount(), sent0 + 2);
        vm.expectRevert(VaultState.NotAllowed.selector);
        vault.notifyLink(0);
    }

    /// A member's message (the AAVE leg's, here) enters the exit; told, the leg tells nobody.
    function test_membersMessage_entersExit_tellsNobody() public {
        bytes memory body = abi.encode(vault.EXIT_MESSAGE());
        bytes32 from = bytes32(uint256(uint160(sister)));
        // not from the transmitter
        vm.expectRevert(VaultState.BadMessage.selector);
        vault.handleReceiveFinalizedMessage(ARB_DOMAIN, from, 2000, body);
        // another sender, another domain, another body
        vm.expectRevert(VaultState.BadMessage.selector);
        transmitter.deliver(address(vault), ARB_DOMAIN, bytes32(uint256(uint160(stranger))), body);
        vm.expectRevert(VaultState.BadMessage.selector);
        transmitter.deliver(address(vault), 0, from, body);
        vm.expectRevert(VaultState.BadMessage.selector);
        transmitter.deliver(address(vault), ARB_DOMAIN, from, abi.encode(keccak256("other")));
        assertTrue(transmitter.deliver(address(vault), ARB_DOMAIN, from, body));
        assertTrue(vault.exiting());
        assertFalse((vault.toldPending() != 0));
        assertEq(transmitter.sentCount(), sent0 + 0); // the member that entered tells the others itself
    }

    function test_topUpHype_anyoneInExit() public {
        _beginExit();
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vault.topUpHype{value: 0.05 ether}(0.05 ether);
        assertEq(HYPE_SYSTEM.balance, 0.05 ether);
    }

    // ── the exit's table ─────────────────────────────────────────────────────────────────────────────

    /// The S12 round in standard mode, from ZERO HYPE: a short open on DEX 0, a resting order, all the
    /// USDC in perp margin; nobody brings HYPE. Every send is checked, and the gate holds until flat.
    function test_exit_fromZeroHype_standardMode() public {
        address v = address(vault);
        core.setPosition(v, uint16(ETH), -45); // short 0.0045 ETH
        core.setMargin(0, v, 14_980_000, 1_100_000, 10_940_000);
        core.setWithdrawable(v, 13_000_000);
        _beginExit();

        // round 0: the cancel and the close only; the margin waits behind the gate
        ShortVaultState.ExitArgs memory a;
        a.cancels = new ShortVaultState.Cancel[](1);
        a.cancels[0] = ShortVaultState.Cancel(ETH, true, 0x1234);
        bytes[] memory r0 = _stepWith(a);
        assertTrue(_has(r0, _core(11, abi.encode(ETH, uint128(0x1234)))), "cancel");
        assertTrue(_has(r0, _order(ETH, true, CLOSE_SHORT_PX, 450_000, true)), "close at the oracle bound");
        assertEq(_countId(r0, 7) + _countId(r0, 13), 0, "nothing moved while a position is open");
        (uint8 st,,) = _state();
        assertEq(st, CLOSING);

        // the close is still pending: the next call (within the pacing) sends no second close
        bytes[] memory r0b = _step();
        assertEq(_countId(r0b, 1), 0);

        // the close executed: flat; margin → spot for the withdrawable read
        core.setPosition(v, uint16(ETH), 0);
        core.setMargin(0, v, 14_970_000, 0, 0);
        core.setWithdrawable(v, 14_970_000);
        _pace();
        bytes[] memory r1 = _step();
        assertTrue(_has(r1, _core(7, abi.encode(uint64(14_970_000), false))), "margin to spot");
        assertEq(_countId(r1, 13), 0);

        // margin landed on spot; no HYPE: buy 11 USDC of it at the HYPE perp's oracle + 1%
        core.setMargin(0, v, 0, 0, 0);
        core.setWithdrawable(v, 0);
        core.setSpot(v, 0, 1_497_000_000);
        _pace();
        bytes[] memory r2 = _step();
        assertTrue(_has(r2, _order(10_107, true, HYPE_BUY_PX, HYPE_BUY_SZ, false)), "HYPE purchase");
        assertEq(_countId(r2, 13), 0, "no transfer without HYPE for its fee");
        assertEq(vault.purchases(), 1);

        // the purchase filled: 0.13 HYPE, 10.43 USDC spent; now USDC to HyperEVM, and no HYPE sale
        // (0.13 HYPE above the fee is worth under 10 USDC)
        core.setSpot(v, HYPE, 13_000_000);
        core.setSpot(v, 0, 1_497_000_000 - 1_043_000_000);
        _pace();
        bytes[] memory r3 = _step();
        assertTrue(_has(r3, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 454_000_000)), "spot to HyperEVM");
        assertEq(_countId(r3, 1), 0, "no sale under 10 USDC");

        // the USDC arrived on HyperEVM (less the transfer's HYPE fee): sent to the hub, the mint bound to it
        core.setSpot(v, 0, 0);
        core.setSpot(v, HYPE, 13_000_000 - 10_000);
        usdc.mint(v, 4_540_000);
        _pace();
        _step();
        assertEq(usdc.balanceOf(v), 0);
        MockTokenMessenger.Burn memory b = messenger.burn(0);
        assertEq(b.amount, 4_540_000);
        assertEq(b.mintRecipient, bytes32(uint256(uint160(hub))));
        assertEq(b.destinationCaller, bytes32(uint256(uint160(hub))));
        assertEq(vault.sentTo(0), 4_540_000);
        assertEq(b.maxFee, 0);
        assertEq(b.minFinalityThreshold, 2000);

        // recovered with residue: the HYPE bought, above the fee reserve, listed
        (uint8 s, uint64[4] memory residue,) = _state();
        assertEq(s, RECOVERED_WITH_RESIDUE);
        assertEq(residue[0], 13_000_000 - 10_000 - 20_000);
    }

    /// The gate: a close delayed, refused or partly filled leaves notional, so no margin leaves even
    /// though margin reads withdrawable (Codex's sixth pass).
    function test_exit_gateHoldsOnAPartialClose() public {
        address v = address(vault);
        core.setPosition(v, uint16(ETH), -45);
        core.setMargin(0, v, 14_980_000, 1_100_000, 10_940_000);
        core.setWithdrawable(v, 13_000_000);
        core.setSpot(v, 0, 5_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        _step();
        // partly filled: 0.0020 left
        core.setPosition(v, uint16(ETH), -20);
        core.setMargin(0, v, 14_970_000, 500_000, 4_860_000);
        _pace();
        bytes[] memory r = _step();
        assertTrue(_has(r, _order(ETH, true, CLOSE_SHORT_PX, 200_000, true)), "the rest closed at its current size");
        assertEq(_countId(r, 7), 0, "no margin moves");
        assertEq(_countId(r, 13), 0, "no spot USDC leaves");
        assertEq(vault.purchases(), 0);
    }

    /// Late execution: a purchase sent, not seen; the next window sends another; both execute late.
    /// The purchases stay within 3 and the HYPE is sold back; the money still all leaves.
    function test_exit_latePurchases_boundedAndSoldBack() public {
        address v = address(vault);
        core.setSpot(v, 0, 5_000_000_000); // 50 USDC on spot, flat, no HYPE
        _beginExit();
        bytes[] memory r1 = _step();
        assertEq(_countId(r1, 1), 1);
        _pace();
        bytes[] memory r2 = _step();
        assertEq(_countId(r2, 1), 1, "sent again: nothing proves the first dropped");
        _pace();
        _step();
        _pace();
        bytes[] memory r4 = _step();
        assertEq(_countId(r4, 1), 0, "never a fourth purchase");
        assertEq(vault.purchases(), 3);
        // all three execute late: 0.39 HYPE, 31.29 USDC spent
        core.setSpot(v, HYPE, 39_000_000);
        core.setSpot(v, 0, 5_000_000_000 - 3 * 1_043_000_000);
        _pace();
        bytes[] memory r5 = _step();
        // the USDC leaves, and the HYPE above the reserve (0.3898 → 0.38, 30.19 USDC at 79.461) is sold
        assertTrue(_has(r5, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 5_000_000_000 - 3 * 1_043_000_000)));
        assertTrue(_has(r5, _order(10_107, false, HYPE_SELL_PX, 38_000_000, false)), "sold back at the oracle bound");
    }

    /// Late execution of a transfer: the next window sends the read again, less the first-transfer fee's
    /// allowance (an unchanged read may be a drop, §5); if both execute, whichever runs second exceeds
    /// the balance and Hyperliquid refuses it. What the allowance kept back then goes whole.
    function test_exit_lateTransfer_sentAgainForTheRead() public {
        address v = address(vault);
        core.setSpot(v, 0, 2_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        bytes[] memory r1 = _step();
        assertTrue(_has(r1, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 2_000_000_000)));
        bytes[] memory r1b = _step();
        assertEq(_countId(r1b, 13), 0, "paced");
        _pace();
        bytes[] memory r2 = _step();
        assertTrue(_has(r2, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 2_000_000_000 - 105_000_000)));
        // the second executed first (the fee had been paid): the allowance is left, the first refused
        core.setSpot(v, 0, 105_000_000);
        _pace();
        bytes[] memory r3 = _step();
        assertTrue(_has(r3, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 105_000_000)), "the rest, whole");
    }

    /// Unified mode (§5): the spot precompile shows only what is available; the account value per DEX
    /// keeps the exit "closing" while margin is held, and says why.
    function test_exit_unifiedMode_spotReadAloneProvesNothing() public {
        address v = address(vault);
        core.setSpot(v, 0, 0); // available: 0
        core.setSpot(v, HYPE, 1_000_000);
        core.setMargin(0, v, 3_793_000, 0, 0); // flat, 3.79 USD held (an unnamed resting order)
        core.setWithdrawable(v, 0);
        _beginExit();
        (uint8 s,, uint256 flags) = _state();
        assertEq(s, CLOSING);
        assertEq(flags & F_MARGIN_HELD, F_MARGIN_HELD);
        // naming the order cancels it; its margin turns available and leaves
        ShortVaultState.ExitArgs memory a;
        a.cancels = new ShortVaultState.Cancel[](1);
        a.cancels[0] = ShortVaultState.Cancel(ETH, false, 99);
        bytes[] memory r = _stepWith(a);
        assertTrue(_has(r, _core(10, abi.encode(ETH, uint64(99)))));
        core.setMargin(0, v, 0, 0, 0);
        core.setSpot(v, 0, 379_300_000);
        _pace();
        r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 379_300_000)));
    }

    /// No HYPE and under 11 USDC: the exit can't buy; it says so, and anyone's `topUpHype` unblocks it.
    function test_exit_needsHype_sayingSo() public {
        address v = address(vault);
        core.setSpot(v, 0, 500_000_000);
        _beginExit();
        bytes[] memory r = _step();
        assertEq(_countId(r, 1) + _countId(r, 13), 0, "nothing it can do");
        (,, uint256 flags) = _state();
        assertEq(flags & F_NEEDS_HYPE, F_NEEDS_HYPE);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vault.topUpHype{value: 0.01 ether}(0.01 ether);
        core.setSpot(v, HYPE, 1_000_000);
        _pace();
        r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 500_000_000)));
    }

    /// HYPE's bound is the HYPE perp's validator oracle, never the spot book (decision 30).
    function test_exit_hypeBoundFromThePerpOracle_notTheBook() public {
        address v = address(vault);
        core.setSpot(v, 0, 5_000_000_000);
        core.setBbo(10_107, 1, 99_000_000_000); // a book pulled to nonsense
        _beginExit();
        bytes[] memory r = _step();
        assertTrue(_has(r, _order(10_107, true, HYPE_BUY_PX, HYPE_BUY_SZ, false)));
    }

    /// A stablecoin is sold at 1 USD less the bound; past it (a depeg) the IOC can't fill, and it waits.
    function test_exit_stablecoinAtOneUsdLessTheBound() public {
        address v = address(vault);
        core.setSpot(v, 360, 2_500_000_000); // 25 USDH
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        bytes[] memory r = _step();
        assertTrue(_has(r, _order(10_230, false, 99_000_000, 2_500_000_000, false)), "USDH at 0.99 USDC");
        (uint8 s,,) = _state();
        assertEq(s, CLOSING, "a sellable balance keeps the exit closing");
    }

    // ── HIP-3 (decision 30) ──────────────────────────────────────────────────────────────────────────

    uint32 constant SP500 = 110_052; // xyz:SP500, DEX 1, szDecimals 3

    function _hip3Sig(uint32 asset, bool isBuy, uint64 size, uint64 limit, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            walletPk,
            address(owner),
            keccak256(
                abi.encode(
                    OwnerMessages.OWNER_ORDER_TYPEHASH,
                    address(vault),
                    block.chainid,
                    asset,
                    isBuy,
                    size,
                    limit,
                    uint8(3),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _ownerClose(uint64 limit, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _hip3Sig(SP500, false, 142_000, limit, nonce, deadline);
        ex.ownerOrder(SP500, false, 142_000, limit, 3, walletCred(wallet), deadline, sig);
    }

    function _withDex1Position() internal returns (address v) {
        v = address(vault);
        core.setMargin(0, v, 0, 0, 0);
        core.setMargin(1, v, 2_000_000, 1_100_000, 11_000_000); // a long on DEX 1
        core.setSpot(v, 0, 3_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        core.setBbo(SP500, 7_731_000, 7_734_500); // 7,731.0 / 7,734.5
        _beginExit();
    }

    function test_hip3_namedDexHoldsTheGate_strangerCantClose() public {
        address v = _withDex1Position();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(1, 0);
        bytes[] memory r = _stepWith(a);
        assertEq(_watched().length, 1);
        assertEq(_countId(r, 13), 0, "nothing leaves while DEX 1 shows notional");
        (uint8 s,, uint256 flags) = _state();
        assertEq(s, CLOSING);
        assertEq(flags & F_WAITING_OWNER, F_WAITING_OWNER);
        // a stranger's close: not the owner's signature
        (, uint256 otherPk) = makeAddrAndKey("attacker");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory bad = _sign(
            otherPk,
            address(owner),
            keccak256(abi.encode(OwnerMessages.OWNER_ORDER_TYPEHASH, v, block.chainid, SP500, false, uint64(142_000), uint64(1), uint8(3), uint256(0), deadline))
        );
        vm.prank(stranger);
        vm.expectRevert(VaultState.BadSignature.selector);
        ex.ownerOrder(SP500, false, 142_000, 1, 3, walletCred(wallet), deadline, bad);
    }

    function test_hip3_ownersClose_bookOnlyTightens_thenCollateralBackBySendAsset() public {
        address v = _withDex1Position();
        uint256 deadline = block.timestamp + 1 hours;
        // the owner's limit 7,500.0; the book's bid 7,731.0 less 1% = 7,653.69 → 7,653.7: tighter, used
        uint64 ownerLimit = 750_000_000_000;
        uint256 from = writer.count();
        _ownerClose(ownerLimit, 0);
        assertEq(_since(from)[0], _order(SP500, false, 765_370_000_000, 142_000, true));
        assertEq(_watched()[0], 1, "the owner's close watches its DEX");
        // an attacker pulls the bid to 5,000: the owner's limit stands, never looser
        core.setBbo(SP500, 5_000_000, 7_734_500);
        from = writer.count();
        _ownerClose(ownerLimit, 1);
        assertEq(_since(from)[0], _order(SP500, false, ownerLimit, 142_000, true));
        // flat: DEX 1's collateral comes back to spot by sendAsset (source DEX 1), then everything leaves
        core.setMargin(1, v, 1_990_000, 0, 0);
        _pace();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(1, 0);
        bytes[] memory r = _stepWith(a);
        assertTrue(_has(r, _sendAsset(v, 1, SPOT, 0, 199_000_000)), "DEX 1 to spot");
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 3_000_000_000)));
        core.setMargin(1, v, 0, 0, 0);
        core.setSpot(v, 0, 0);
        core.setSpot(v, HYPE, 990_000);
        usdc.mint(v, 31_990_000);
        _pace();
        _step();
        (uint8 s,,) = _state();
        assertEq(s, RECOVERED_WITH_RESIDUE); // 0.0097 HYPE above the reserve: S12's residue
    }

    function test_hip3_unnamedDex_listsOnlyDex0_laterNamingResumes() public {
        address v = _withDex1Position();
        (, uint32[] memory dexes,,) = ex.exitStatus();
        assertEq(dexes.length, 0, "only DEX 0 is watched until someone names DEX 1");
        // unnamed: DEX 0 flat, so the spot USDC leaves (the gate reads the watched DEXes only)
        bytes[] memory r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 3_000_000_000)));
        // named later: it joins, and holds the gate for what is left
        core.setSpot(v, 0, 1_000_000_000);
        _pace();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(1, 0);
        r = _stepWith(a);
        assertEq(_countId(r, 13), 0);
        (, dexes,,) = ex.exitStatus();
        assertEq(dexes[0], 1);
    }

    function test_hip3_aDexWithNothingThereCantJoin() public {
        _beginExit();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(5, 0);
        _stepWith(a);
        assertEq(_watched().length, 0);
    }

    /// No signed close: after 7 days DEX 1 drops out of the gate. The rest leaves within the budget
    /// B = available − R, fixed once; a delayed transfer, then an unrelated credit and a late CCTP
    /// arrival release nothing: no send beyond B.
    function test_hip3_dropOut_budgetFixedOnce_neverRefilled() public {
        address v = address(vault);
        // above 10× leverage: 10% of notional (55 USD) exceeds the margin used (20)
        core.setMargin(1, v, 60_000_000, 20_000_000, 550_000_000);
        core.setMargin(0, v, 0, 0, 0);
        core.setSpot(v, 0, 20_000_000_000); // 200 USDC
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(1, 0);
        bytes[] memory r = _stepWith(a);
        assertEq(_countId(r, 13), 0, "DEX 1 holds the gate for 7 days");

        vm.warp(vm.getBlockTimestamp() + 7 days);
        _pace();
        r = _step();
        // R = 1.1 × max(20, 55) = 60.5 USDC; B = 200 − 60.5 − 1.05 (the fee allowance) = 138.45
        assertTrue(vault.budgetSet());
        assertEq(vault.budget(), 13_845_000_000);
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 13_845_000_000)), "only B leaves");
        (,, uint256 flags) = _state();
        assertEq(flags & F_BUDGET, F_BUDGET);

        // the transfer is delayed past the pacing; an unrelated 50 USDC credit lands on HyperEVM, and a
        // late CCTP arrival too: nothing is released
        usdc.mint(v, 50e6);
        usdc.mint(v, 7e6);
        _pace();
        r = _step();
        assertEq(_countId(r, 13), 0, "the budget is spent: no second send");
        // then the delayed transfer executes; more USDC reaches spot (DEX 0's last margin): still nothing
        core.setSpot(v, 0, 20_000_000_000 - 13_845_000_000 + 1_000_000_000);
        _pace();
        r = _step();
        assertEq(_countId(r, 13), 0);
        assertEq(vault.spent(), 13_845_000_000);
        // the owner's close flattens DEX 1: the budget ends and the rest leaves
        core.setMargin(1, v, 59_000_000, 0, 0);
        _pace();
        r = _stepWith(a);
        assertTrue(_has(r, _sendAsset(v, 1, SPOT, 0, 5_900_000_000)), "DEX 1's collateral back");
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 7_155_000_000)), "the rest, unbudgeted");
    }

    function test_hip3_dropOut_purchaseCountedInTheBudget() public {
        address v = address(vault);
        core.setMargin(1, v, 60_000_000, 20_000_000, 550_000_000);
        core.setSpot(v, 0, 7_500_000_000); // 75 USDC: B = 75 − 60.5 − 1.05 = 13.45
        _beginExit();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(1, 0);
        _stepWith(a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _pace();
        bytes[] memory r = _step();
        assertEq(vault.budget(), 1_345_000_000);
        assertTrue(_has(r, _order(10_107, true, HYPE_BUY_PX, HYPE_BUY_SZ, false)));
        assertEq(vault.spent(), 1_053_858_000, "the purchase counted at its limit");
        core.setSpot(v, HYPE, 13_000_000);
        core.setSpot(v, 0, 7_500_000_000 - 1_043_000_000);
        _pace();
        r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 291_142_000)), "what's left of B");
    }

    // ── the first-transfer fee (§5, §15: option (c)) ─────────────────────────────────────────────────
    // The mock CoreWriter plays HyperCore's fee here: an account's first outgoing USDC transfer pays it
    // in USDC on top of the amount, and an action that can't pay it is dropped silently.

    uint64 constant FIRST_FEE = 100_511_200; // 1.005112 USDC, the first-fee run's F2
    uint64 constant FIRST_SPOT = 500_008_200; // 5.000082 USDC: the probe's spot when F1 was dropped

    /// The stall the exit had: its whole-balance send, the account's first, is dropped, and the same
    /// send repeated is dropped every time (F1.1, F1.2): spot never moves, nothing reaches HyperEVM.
    function test_firstFee_wholeBalanceSend_droppedEveryTime() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setSpot(v, 0, FIRST_SPOT);
        core.setSpot(v, HYPE, 20_000);
        _beginExit();
        bytes[] memory r = _step();
        bytes memory whole = _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, FIRST_SPOT);
        assertTrue(_has(r, whole), "the whole balance read");
        assertEq(writer.dropped(), 1);
        for (uint256 i; i < 5; ++i) {
            vm.prank(v);
            writer.sendRawAction(whole); // what a call without the fallback sent, every pacing window
        }
        assertEq(writer.dropped(), 6);
        assertEq(writer.landed(), 0);
        assertEq(core.spot(v, 0), FIRST_SPOT, "spot never moves");
        (uint8 s,,) = _state();
        assertEq(s, CLOSING);
    }

    /// Option (c): the next send, after a read unchanged since the dropped one, leaves the allowance; it
    /// lands and pays the fee (F2); the leftover then reads as a new balance and goes whole, its fee paid
    /// (F4); the exit recovers. A sweep after it pays no fee: once per account (F3).
    function test_firstFee_fallbackLands_thenTheLeftoverWhole() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setSpot(v, 0, FIRST_SPOT);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        _step();
        assertEq(writer.dropped(), 1);

        _pace();
        bytes[] memory r = _step();
        uint64 fallbackAmount = FIRST_SPOT - 105_000_000; // 3.950082
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, fallbackAmount)), "the read less the allowance");
        assertEq(writer.landed(), 1);
        assertTrue(writer.feePaid(v));
        uint64 leftover = 105_000_000 - FIRST_FEE; // 0.044888
        assertEq(core.spot(v, 0), leftover);

        _pace();
        r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, leftover)), "the leftover, whole");
        assertEq(writer.landed(), 2);
        assertEq(writer.dropped(), 1, "only the first was dropped");
        assertEq(core.spot(v, 0), 0);

        // both arrive on HyperEVM and go to the hub
        usdc.mint(v, (uint256(fallbackAmount) + leftover) / 100);
        _pace();
        _step();
        assertEq(usdc.balanceOf(v), 0);
        assertEq(vault.sentTo(0), (uint256(fallbackAmount) + leftover) / 100);
        (uint8 s, uint64[4] memory residue,) = _state();
        assertEq(s, RECOVERED_WITH_RESIDUE);
        assertEq(residue[0], 1_000_000 - 20_000);

        // the residue sweep: the fee is paid, so it lands with no USDC on spot
        ex.proposeSweep(wallet);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        ex.sweepResidue(HYPE, wallet);
        assertEq(writer.landed(), 3);
        assertEq(core.spot(v, HYPE), 20_000);
    }

    /// Budget mode: B leaves the allowance on spot above R, so a first transfer's fee is paid from it,
    /// never from the reserve the dropped-out position keeps; `spent` counts what was sent, the fee aside.
    function test_firstFee_budgetMode_feePaidAboveTheReserve() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setMargin(1, v, 60_000_000, 20_000_000, 550_000_000); // R = 60.5 USDC
        core.setSpot(v, 0, 20_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](1);
        a.dexes[0] = ShortVaultState.DexHint(1, 0);
        _stepWith(a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _pace();
        bytes[] memory r = _step();
        assertEq(vault.budget(), 13_845_000_000, "200 - 60.5 - 1.05");
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 13_845_000_000)));
        assertEq(writer.landed(), 1, "B lands though it is the first transfer");
        assertEq(vault.spent(), 13_845_000_000);
        uint64 left = core.spot(v, 0);
        assertEq(left, 6_050_000_000 + 105_000_000 - FIRST_FEE);
        assertGe(left, 6_050_000_000, "R intact");
        // the read moved, but the budget is spent: nothing more leaves while DEX 1 holds its position
        _pace();
        r = _step();
        assertEq(_countId(r, 13), 0);
        assertEq(vault.spent(), 13_845_000_000);
    }

    /// The fee already paid (custody creation's small move, option (a)): every send is the whole read,
    /// and it lands; the allowance never comes into play.
    function test_firstFee_alreadyPaid_wholeSendsLand() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        writer.setFeePaid(v, true);
        core.setSpot(v, 0, FIRST_SPOT);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        bytes[] memory r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, FIRST_SPOT)));
        assertEq(core.spot(v, 0), 0);
        // DEX 0's last margin reaches spot later: whole again
        core.setSpot(v, 0, 300_000_000);
        _pace();
        r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 300_000_000)));
        assertEq(writer.landed(), 2);
        assertEq(writer.dropped(), 0);
        assertEq(core.spot(v, 0), 0);
    }

    /// The residual (§5): an account that never paid its fee and holds under the allowance can't send
    /// it; and a sweep with no USDC on spot to pay the fee is dropped. Neither happens once creation's
    /// move (a) or any exit send has paid it.
    function test_firstFee_neverPaid_underTheAllowance_staysOnSpot() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setSpot(v, 0, 80_000_000); // 0.80 USDC
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        _step();
        assertEq(writer.dropped(), 1);
        _pace();
        bytes[] memory r = _step();
        // under the allowance + the dust bound the read goes whole (RR-4): dropped again on an account
        // that never paid its fee, the money waits; on one that did, it lands
        assertEq(_countId(r, 13), 1, "the whole read, under the allowance + dust");
        assertEq(writer.dropped(), 2);
        (uint8 s,,) = _state();
        assertEq(s, CLOSING);

        // the sweep of an account with no USDC: dropped silently, every time
        core.setSpot(v, 0, 0);
        ex.proposeSweep(wallet);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        ex.sweepResidue(HYPE, wallet);
        assertEq(writer.dropped(), 3);
        assertEq(core.spot(v, HYPE), 1_000_000);
    }

    /// Outside the exit, the same fee: on a fresh Circle-funded account `fromMargin` moves its amount to
    /// spot and sends that same amount, so the fee never fits and the send is dropped; the amount waits.
    function test_firstFee_fromMargin_droppedOnAFreshAccount() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setWithdrawable(v, 25_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        vm.prank(key);
        vault.fromMargin(4_000_000);
        assertEq(writer.dropped(), 1);
        assertEq(core.withdrawableOf(v), 21_000_000, "the margin moved");
        assertEq(core.spot(v, 0), 400_000_000, "its send didn't: 4 USDC on spot");
        assertFalse(writer.feePaid(v));
    }

    /// `prime` (custody creation, once, HYPE on spot): 1.2 USDC of margin to spot, 0.05 USDC to HyperEVM;
    /// it lands and pays the fee, and every `fromMargin` after it lands whole.
    function test_prime_paysTheFee_thenFromMarginLandsWhole() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setWithdrawable(v, 25_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        uint256 from = writer.count();
        vm.prank(key);
        vault.prime();
        bytes[] memory a = _since(from);
        assertEq(a.length, 2);
        assertEq(a[0], _core(7, abi.encode(uint64(1_200_000), false)));
        assertEq(a[1], _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 5_000_000));
        assertEq(writer.landed(), 1);
        assertTrue(writer.feePaid(v));
        assertEq(core.withdrawableOf(v), 23_800_000, "perp: 1.2 USDC down");
        assertEq(core.spot(v, 0), 120_000_000 - 5_000_000 - FIRST_FEE, "spot: 1.2 - 0.05 - the fee");
        assertEq(vault.lastCoreMove(), block.number);

        vm.prank(key);
        vault.fromMargin(4_000_000);
        assertEq(writer.landed(), 2);
        assertEq(writer.dropped(), 0);
        assertEq(core.spot(v, 0), 120_000_000 - 5_000_000 - FIRST_FEE, "the 4 USDC left whole");
    }

    /// Twice: the second pays no fee; every cent stays the account's (margin, spot, or sent to itself).
    function test_prime_twice_harmless() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        core.setWithdrawable(v, 25_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        vm.startPrank(key);
        vault.prime();
        vault.prime();
        vm.stopPrank();
        assertEq(writer.landed(), 2);
        assertEq(core.withdrawableOf(v), 22_600_000);
        assertEq(core.spot(v, 0), 240_000_000 - 10_000_000 - FIRST_FEE);
        // 25 USDC = the margin + spot + 0.10 sent to HyperEVM + the one fee
        assertEq(uint256(core.withdrawableOf(v)) * 100 + core.spot(v, 0) + 10_000_000 + FIRST_FEE, 2_500_000_000);
    }

    /// Unified mode: perp → spot does nothing, spot is the whole balance, and it pays.
    function test_prime_unifiedMode_spotPays() public {
        address v = address(vault);
        writer.playFirstFee(FIRST_FEE);
        writer.setUnified(true);
        core.setSpot(v, 0, 1_000_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        vm.prank(key);
        vault.prime();
        assertEq(writer.landed(), 1);
        assertEq(core.spot(v, 0), 1_000_000_000 - 5_000_000 - FIRST_FEE);
    }

    /// The execution key's, outside the exit (the margin it moves is the position's protection).
    function test_prime_onlyTheKey_notInExit() public {
        vm.prank(stranger);
        vm.expectRevert(VaultState.NotExecution.selector);
        vault.prime();
        _beginExit();
        vm.prank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        vault.prime();
    }

    // ── the residue sweep (§8.4) ─────────────────────────────────────────────────────────────────────

    function _toResidue() internal returns (address v) {
        v = address(vault);
        core.setSpot(v, HYPE, 990_000); // 0.0097 above the 0.0002 reserve
        core.setSpot(v, 360, 300_000_000); // 3 USDH: unsellable under $10
        _beginExit();
    }

    function test_sweep_toAWalletStanding24h_atMostTheResidue() public {
        address v = _toResidue();
        (uint8 s, uint64[4] memory residue,) = _state();
        assertEq(s, RECOVERED_WITH_RESIDUE);
        assertEq(residue[0], 970_000);
        assertEq(residue[3], 300_000_000);
        ex.proposeSweep(wallet);
        vm.expectRevert(ShortVaultState.NotOwnerWallet.selector);
        ex.sweepResidue(HYPE, wallet); // younger than 24 hours here
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        uint256 from = writer.count();
        vm.prank(stranger);
        ex.sweepResidue(HYPE, wallet);
        assertEq(_since(from)[0], _core(6, abi.encode(wallet, HYPE, uint64(970_000))), "HYPE above the reserve");
        ex.sweepResidue(360, wallet);
        assertEq(writer.action(writer.count() - 1).data, _core(6, abi.encode(wallet, uint64(360), uint64(300_000_000))));
        // paced: not twice at once
        vm.expectRevert(ShortVaultState.TooEarly.selector);
        ex.sweepResidue(HYPE, wallet);
        v;
    }

    function test_sweep_refusals() public {
        address v = address(vault);
        // outside the residue state: a sellable balance makes it "closing"
        core.setSpot(v, HYPE, 990_000);
        core.setSpot(v, 0, 500_000_000);
        _beginExit();
        ex.proposeSweep(wallet);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(ShortVaultState.NotResidue.selector);
        ex.sweepResidue(HYPE, wallet);
        core.setSpot(v, 0, 0);
        // never USDC; never a token without residue
        vm.expectRevert(ShortVaultState.BadAsset.selector);
        ex.sweepResidue(0, wallet);
        vm.expectRevert(ShortVaultState.BadAsset.selector);
        ex.sweepResidue(268, wallet);
        // not the withdrawal address (not a wallet credential), not a stranger
        vm.expectRevert(ShortVaultState.NotOwnerWallet.selector);
        ex.proposeSweep(withdrawalTo);
        vm.expectRevert(ShortVaultState.NotOwnerWallet.selector);
        ex.sweepResidue(HYPE, withdrawalTo);
        vm.expectRevert(ShortVaultState.NotOwnerWallet.selector);
        ex.sweepResidue(HYPE, stranger);
        // a wallet removed from the copy after its proposal
        owner.setWallet(wallet, false);
        vm.expectRevert(ShortVaultState.NotOwnerWallet.selector);
        ex.sweepResidue(HYPE, wallet);
    }

    function test_sweep_onlyInExit() public {
        vm.expectRevert(VaultState.NotExiting.selector);
        ex.sweepResidue(HYPE, wallet);
        vm.expectRevert(VaultState.NotExiting.selector);
        ex.exitStep(_noArgs());
    }

    // ── the owner's signed spot sale ─────────────────────────────────────────────────────────────────

    /// The owner's signed order on a spot market (a token with no oracle): IOC at the owner's limit,
    /// tightened by the book, never reduce-only (spot has no position).
    function test_ownerOrder_spot() public {
        _beginExit();
        core.setBbo(10_200, 1_900_000, 1_910_000); // spot raw: 8 − szDecimals(2) decimals → 1.90 / 1.91
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h = keccak256(
            abi.encode(OwnerMessages.OWNER_ORDER_TYPEHASH, address(vault), block.chainid, uint32(10_200), false, uint64(5e8), uint64(1e8), uint8(2), uint256(0), deadline)
        );
        uint256 from = writer.count();
        ex.ownerOrder(10_200, false, 5e8, 1e8, 2, walletCred(wallet), deadline, _sign(walletPk, address(owner), h));
        // the owner's floor 1.00; the bid 1.90 less 1% = 1.881: tighter, used
        assertEq(_since(from)[0], _order(10_200, false, 188_100_000, 5e8, false));
    }

    /// Minor 6: an illiquid DEX 0 position the oracle-bounded close can't fill: the owner's signed
    /// close (reduce-only), so it can't hold the gate forever.
    function test_ownerOrder_dex0() public {
        core.setPosition(address(vault), uint16(ETH), -45);
        _beginExit();
        core.setBboRefused(ETH, true);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h = keccak256(
            abi.encode(OwnerMessages.OWNER_ORDER_TYPEHASH, address(vault), block.chainid, ETH, true, uint64(450_000), uint64(260_000_000_000), uint8(4), uint256(0), deadline)
        );
        uint256 from = writer.count();
        ex.ownerOrder(ETH, true, 450_000, 260_000_000_000, 4, walletCred(wallet), deadline, _sign(walletPk, address(owner), h));
        assertEq(_since(from)[0], _order(ETH, true, 260_000_000_000, 450_000, true));
        assertEq(_watched().length, 0, "DEX 0 is watched always, never listed");
    }

    /// The re-review's finding: a spot owner order SELLS only. A buy could spend the vault's USDC on a
    /// token whose only ask is a thief's, with one stolen credential.
    function test_ownerOrder_spotBuyRefused() public {
        _beginExit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h = keccak256(
            abi.encode(OwnerMessages.OWNER_ORDER_TYPEHASH, address(vault), block.chainid, uint32(10_200), true, uint64(5e8), uint64(9e8), uint8(2), uint256(0), deadline)
        );
        bytes memory sig = _sign(walletPk, address(owner), h);
        vm.expectRevert(ShortVaultState.BadAsset.selector);
        ex.ownerOrder(10_200, true, 5e8, 9e8, 2, walletCred(wallet), deadline, sig);
    }

    /// The re-review: a full list of DEXes that hold only dust makes room for a real one.
    function test_watch_dustEntriesGiveTheirPlace() public {
        address v = address(vault);
        _beginExit();
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](16);
        for (uint32 d = 1; d <= 16; ++d) {
            core.setMargin(d, v, 5_000_000, 0, 0);
            a.dexes[d - 1] = ShortVaultState.DexHint(d, 0);
        }
        _stepWith(a);
        assertEq(_watched().length, 16);
        for (uint32 d = 1; d <= 16; ++d) {
            core.setMargin(d, v, 5_000, 0, 0); // 0.005 USD: dust
        }
        core.setMargin(40, v, 0, 1_000_000, 10_000_000); // a real position
        ShortVaultState.ExitArgs memory b;
        b.dexes = new ShortVaultState.DexHint[](1);
        b.dexes[0] = ShortVaultState.DexHint(40, 0);
        _pace();
        _stepWith(b);
        assertGt(vault.dexSince(40), 0, "joins in a dust entry's place");
        assertEq(vault.dexSince(1), 0);
    }

    /// The re-review: the residue (and the sweep's amount) is what is available, total − hold.
    function test_residue_isTheAvailableAmount() public {
        address v = address(vault);
        core.setSpot(v, 360, 300_000_000);
        core.setHold(v, 360, 100_000_000);
        _beginExit();
        (uint8 st, uint64[4] memory residue,) = _state();
        assertEq(st, RECOVERED_WITH_RESIDUE);
        assertEq(residue[3], 200_000_000);
        ex.proposeSweep(wallet);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        uint256 from = writer.count();
        ex.sweepResidue(360, wallet);
        assertEq(_since(from)[0], _core(6, abi.encode(wallet, uint64(360), uint64(200_000_000))));
    }

    function test_ownerOrder_refusesAnAssetIdThatIsNone() public {
        _beginExit();
        vm.expectRevert(ShortVaultState.BadAsset.selector);
        ex.ownerOrder(105_000, true, 1, 1, 2, walletCred(wallet), block.timestamp, ""); // between spot and DEX 1
    }

    /// Minor 10: the HyperEVM bridge-out needs no HyperCore read.
    function test_bridgeOut_withoutHyperCoreReads() public {
        _beginExit();
        core.setDexRefused(0, true); // DEX 0's read refused: exitStep can't run
        vm.expectRevert();
        ex.exitStep(_noArgs());
        usdc.mint(address(vault), 7e6);
        vm.prank(stranger);
        ex.bridgeOut();
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// Minor 11: in standard mode a resting spot order holds part of the balance; only total − hold moves.
    function test_exit_movesOnlyWhatIsAvailable() public {
        address v = address(vault);
        core.setSpot(v, 0, 2_000_000_000);
        core.setHold(v, 0, 500_000_000);
        core.setSpot(v, HYPE, 1_000_000);
        _beginExit();
        bytes[] memory r = _step();
        assertTrue(_has(r, _sendAsset(USDC_SYSTEM, SPOT, SPOT, 0, 1_500_000_000)));
        // the held USDC keeps the exit closing
        core.setSpot(v, 0, 500_000_000);
        (uint8 st,,) = _state();
        assertEq(st, CLOSING);
    }

    /// Minor 12: three purchases spent and still no HYPE: the status says someone must bring it.
    function test_exit_needsHype_afterThreePurchases() public {
        address v = address(vault);
        core.setSpot(v, 0, 5_000_000_000);
        _beginExit();
        _step();
        _pace();
        _step();
        _pace();
        _step();
        assertEq(vault.purchases(), 3);
        (,, uint256 flags) = _state();
        assertEq(flags & F_NEEDS_HYPE, F_NEEDS_HYPE);
    }

    /// Minor 14: the owner's close watches only a DEX the precompile reads; a full list makes room
    /// only from entries that read empty.
    function test_watch_readableOnly_andEmptyEntriesGiveTheirPlace() public {
        address v = address(vault);
        _beginExit();
        core.setDexRefused(7, true);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h = keccak256(
            abi.encode(OwnerMessages.OWNER_ORDER_TYPEHASH, v, block.chainid, uint32(170_001), false, uint64(1), uint64(1), uint8(2), uint256(0), deadline)
        );
        ex.ownerOrder(170_001, false, 1, 1, 2, walletCred(wallet), deadline, _sign(walletPk, address(owner), h));
        assertEq(_watched().length, 0, "an unreadable DEX is not watched");
        // fill the list: 16 DEXes holding 5 USD each
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](17);
        for (uint32 d = 1; d <= 17; ++d) {
            if (d != 7) core.setMargin(d, v, 5_000_000, 0, 0);
            a.dexes[d - 1] = ShortVaultState.DexHint(d == 7 ? 20 : d, 0);
        }
        core.setMargin(20, v, 5_000_000, 0, 0);
        _stepWith(a);
        assertEq(_watched().length, 16);
        // a 17th with value can't join while all 16 hold something...
        core.setMargin(30, v, 5_000_000, 0, 0);
        ShortVaultState.ExitArgs memory b;
        b.dexes = new ShortVaultState.DexHint[](1);
        b.dexes[0] = ShortVaultState.DexHint(30, 0);
        _stepWith(b);
        assertEq(vault.dexSince(30), 0);
        // ...and joins in the place of one that now reads empty
        core.setMargin(3, v, 0, 0, 0);
        _stepWith(b);
        assertGt(vault.dexSince(30), 0);
        assertEq(vault.dexSince(3), 0);
        assertEq(_watched().length, 16);
    }

    // ── an unsynced copy of the owner's record (slice 1a) ────────────────────────────────────────────

    /// HyperEVM's copy starts unsynced: no owner signature counts there yet, and the status says so;
    /// the stopped group's hatch and a member's message still begin the exit.
    function test_unsyncedOwnerCopy_noSignatureYet_hatchAndMemberStillWork() public {
        owner.setSynced(false);
        (,,, uint256 flags) = ex.exitStatus();
        assertEq(flags & F_OWNER_UNSYNCED, F_OWNER_UNSYNCED);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _beginExitSig(STRATEGY, deadline);
        vm.expectRevert(VaultState.BadSignature.selector);
        vault.beginExit(deadline, sig);
        // the hub's message
        assertTrue(transmitter.deliver(address(vault), ARB_DOMAIN, bytes32(uint256(uint160(hub))), abi.encode(vault.EXIT_MESSAGE())));
        assertTrue(vault.exiting());
        (,,, flags) = ex.exitStatus();
        assertEq(flags & F_OWNER_UNSYNCED, F_OWNER_UNSYNCED);
        // the sweep needs a wallet in a synced copy
        vm.expectRevert(ShortVaultState.NotOwnerWallet.selector);
        ex.proposeSweep(wallet);
        owner.setSynced(true);
        (,,, flags) = ex.exitStatus();
        assertEq(flags & F_OWNER_UNSYNCED, 0);
    }

    function test_unsyncedOwnerCopy_hatchStillBeginsTheExit() public {
        owner.setSynced(false);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(stranger);
        vault.beginExitStopped();
        assertTrue(vault.exiting());
    }
}
