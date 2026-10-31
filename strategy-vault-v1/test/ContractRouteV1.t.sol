// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureV1} from "./FixtureV1.sol";
import {CoreState, MockCoreDepositWallet, MockCoreWriter, MockERC20, walletCred} from "./mocks/Mocks.sol";
import {HyperCoreLeg} from "../src/HyperCoreLeg.sol";
import {HyperCoreLegExit} from "../src/HyperCoreLegExit.sol";
import {HyperCoreLegExitB} from "../src/HyperCoreLegExitB.sol";
import {HyperCoreLegRoute} from "../src/HyperCoreLegRoute.sol";
import {HyperCoreLegState} from "../src/HyperCoreLegState.sol";
import {HyperCore} from "../src/lib/HyperCore.sol";
import {RouteMath} from "../src/lib/RouteMath.sol";
import {MemberState} from "../src/MemberState.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {HyperCoreParams, OwnerMessagesV1, Routes, Sides, StrategySpec} from "../src/Types.sol";
import {OwnerMessages} from "../src/lib/VaultTypes.sol";

/*
 * The Hyperliquid contract route (hyperliquid-contract-route-design.md): orders sent by the strategy's own
 * leg through CoreWriter. This file holds the mock's own test; the route's tests join it task by task.
 */
contract ContractRouteV1Test is FixtureV1 {
    function setUp() public {
        _hyperEvm();
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    /// The contract-route fixture's two bands, distinct so a test sees which one an order used
    uint16 constant GROW_BP = 20;
    uint16 constant REDUCE_BP = 15;

    /// A BTC strategy on the contract route (BTC's perp at its real 40x): the short, 10x, a 20 bp growth
    /// band and a 15 bp reduce band inside a 50 bp order bound, no builder fee. Returns the short leg.
    function _contractShort() internal returns (address) {
        core.setMaxLeverage(0, 40);
        StrategySpec memory c = _btcSpec();
        c.legs[1].params = abi.encode(_routeParams());
        return _create(c)[0];
    }

    function _routeParams() internal view returns (HyperCoreParams memory s) {
        s = _shortParams(_btc(), btcProfile);
        s.orderBoundBp = 50;
        s.route = Routes.CONTRACT;
        s.side = Sides.SHORT;
        s.maxLeverageX100 = 1000;
        s.growBoundBp = GROW_BP;
        s.reduceBoundBp = REDUCE_BP;
        s.builder = address(0);
        s.builderFeeX10 = 0;
        s.referralSetup = false;
    }

    /// The implementation, as the factory asks it (its fallback dispatches to module B).
    function _valid(HyperCoreParams memory s) internal view {
        HyperCoreLegExitB(address(shortImpl)).validateParams(address(registry), abi.encode(s));
    }

    function _refused(HyperCoreParams memory s) internal {
        vm.expectRevert(HyperCoreLegState.BadParams.selector);
        HyperCoreLegExitB(address(shortImpl)).validateParams(address(registry), abi.encode(s));
    }

    /// A BTC strategy on the agent route with its first agent applied. Returns the short leg.
    function _agentShort() internal returns (HyperCoreLeg l) {
        return _agentShortAs(STRATEGY);
    }

    /// `_agentShort` under another strategy id: a second strategy in the same test.
    function _agentShortAs(bytes32 id) internal returns (HyperCoreLeg l) {
        core.setMaxLeverage(0, 40);
        l = HyperCoreLeg(payable(_createAs(id, _btcSpec())[0]));
        core.setExists(address(l), true);
        vm.prank(key);
        l.proposeAgent(address(0xA6E));
        vm.prank(key);
        HyperCoreLegExit(address(l)).applyAgent();
        assertEq(l.agent(), address(0xA6E));
    }

    /// The owner's `VaultAction`, signed by the wallet credential at its nonce, submitted by a stranger.
    function _act(HyperCoreLeg l, uint8 action, address agent) internal {
        bytes32 cred = walletCred(wallet);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(
            walletPk,
            keccak256(
                abi.encode(
                    OwnerMessages.VAULT_ACTION_TYPEHASH, address(l), block.chainid, action, agent, l.ownerNonceOf(cred), deadline
                )
            )
        );
        vm.prank(stranger);
        l.ownerAction(action, agent, cred, deadline, sig);
    }

    /// The leg's `burnerAt` (internal): slot 90, offset 18 (layouts/HyperCoreLeg.txt).
    function _burnerAt(address l) internal view returns (uint64) {
        return uint64(uint256(vm.load(l, bytes32(uint256(90)))) >> 144);
    }

    /// The last CoreWriter action: its id and the agent it names (action 9's first field).
    function _lastAction() internal view returns (uint24 id, address named) {
        MockCoreWriter w = MockCoreWriter(CORE_WRITER);
        bytes memory d = w.action(w.count() - 1).data;
        id = uint24(uint8(d[1])) << 16 | uint24(uint8(d[2])) << 8 | uint24(uint8(d[3]));
        assembly ("memory-safe") {
            named := mload(add(d, 36))
        }
    }

    // ── the route's owner actions (spec §4.6, §5.3) ──────────────────────────────────────────────────

    function test_route_contractRefusesServerAgents() public {
        HyperCoreLeg l = HyperCoreLeg(payable(_contractShort()));
        core.setExists(address(l), true);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        l.proposeAgent(address(0xA6E));
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegExit(address(l)).applyAgent();
    }

    /// A proposal DLTX made on the agent route is dropped by the switch, and could not apply after it.
    function test_route_useContractVoidsAServerProposal() public {
        HyperCoreLeg l = _agentShort();
        vm.prank(key);
        l.proposeAgent(address(0xB0B));
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertEq(l.pendingAgent(), address(0));
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegExit(address(l)).applyAgent();
    }

    function test_route_useContractCutsAtOnce() public {
        HyperCoreLeg l = _agentShort();
        vm.prank(key);
        l.proposeAgent(address(0xB0B));
        _act(l, OwnerMessages.REPLACE_AGENT, address(0xC0C));
        assertEq(l.ownerAgent(), address(0xC0C));
        uint256 before = MockCoreWriter(CORE_WRITER).count();
        vm.warp(vm.getBlockTimestamp() + 7);
        vm.expectEmit(address(l));
        emit HyperCoreLegState.RouteChanged(Routes.CONTRACT);
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertEq(l.route(), Routes.CONTRACT);
        assertTrue(l.quarantine());
        assertEq(l.pendingAgent(), address(0));
        assertEq(l.ownerAgent(), address(0));
        assertTrue(l.burning());
        assertEq(_burnerAt(address(l)), vm.getBlockTimestamp());
        assertEq(MockCoreWriter(CORE_WRITER).count(), before + 1);
        (uint24 id, address named) = _lastAction();
        assertEq(id, 9);
        assertEq(named, l.agent());
        assertTrue(named != address(0xA6E) && named != address(0) && named != address(1));
    }

    function test_route_useContractClearsAPendingSwitchBack() public {
        HyperCoreLeg l = HyperCoreLeg(payable(_contractShort()));
        _act(l, OwnerMessages.REPLACE_AGENT, address(0xC0C));
        assertEq(l.ownerAgent(), address(0xC0C));
        vm.expectEmit(address(l));
        emit HyperCoreLegState.AgentCancelled();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertEq(l.ownerAgent(), address(0));
        assertEq(l.route(), Routes.CONTRACT);
        assertFalse(l.quarantine()); // born on the contract route: never had an agent
        _endRefused(l, address(0), MemberState.Unsupported.selector); // so no quarantine to end
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vm.expectRevert(HyperCoreLegState.NoAgent.selector);
        HyperCoreLegExit(address(l)).applyOwnerAgent();
    }

    function test_route_backToAgentAfter24h() public {
        HyperCoreLeg l = _agentShort();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertTrue(l.quarantine());
        _act(l, OwnerMessages.REPLACE_AGENT, address(0xC0C));
        assertEq(l.route(), Routes.CONTRACT); // pending: the route moves only when it applies
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert(HyperCoreLegState.TooEarly.selector);
        HyperCoreLegExit(address(l)).applyOwnerAgent();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(address(l));
        emit HyperCoreLegState.RouteChanged(Routes.AGENT);
        vm.prank(stranger);
        HyperCoreLegExit(address(l)).applyOwnerAgent();
        assertEq(l.route(), Routes.AGENT);
        assertFalse(l.quarantine());
        assertEq(l.agent(), address(0xC0C));
        assertFalse(l.burning());
        // DLTX proposes again on the agent route
        vm.prank(key);
        l.proposeAgent(address(0xB0B));
        assertEq(l.pendingAgent(), address(0xB0B));
    }

    function test_route_ownerBurnerRetryResetsTheClock() public {
        HyperCoreLeg l = _agentShort();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        address first = l.agent();
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 30 minutes);
        _act(l, OwnerMessages.REPLACE_AGENT, address(1));
        address second = l.agent();
        assertTrue(second != first && second != address(1) && second != address(0));
        (uint24 id, address named) = _lastAction();
        assertEq(id, 9);
        assertEq(named, second);
        assertEq(_burnerAt(address(l)), t0 + 30 minutes);
        assertEq(l.route(), Routes.CONTRACT);
        assertTrue(l.quarantine());
        // the hour runs from the retry: an hour after the first burner is too early
        _flat(l);
        vm.warp(t0 + 1 hours);
        _endRefused(l, second, HyperCoreLegState.TooEarly.selector);
        vm.warp(t0 + 90 minutes);
        _act(l, OwnerMessages.END_QUARANTINE, second);
        assertFalse(l.quarantine());
    }

    /// BTC: 1 BTC short (szd 5) at a mark of 82,058.1 (10^-1), DEX 0 holding only it.
    function _flat(HyperCoreLeg l) internal {
        core.setPosition(address(l), 0, -100_000);
        core.setMark(0, 820_581);
        core.setMargin(0, address(l), 10_000e6, 8_205e6, 100_000 * 820_581);
    }

    function _endRefused(HyperCoreLeg l, address named, bytes4 err) internal {
        bytes32 cred = walletCred(wallet);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(
            walletPk,
            keccak256(
                abi.encode(
                    OwnerMessages.VAULT_ACTION_TYPEHASH,
                    address(l),
                    block.chainid,
                    OwnerMessages.END_QUARANTINE,
                    named,
                    l.ownerNonceOf(cred),
                    deadline
                )
            )
        );
        vm.expectRevert(err);
        l.ownerAction(OwnerMessages.END_QUARANTINE, named, cred, deadline, sig);
    }

    function test_route_endQuarantine() public {
        HyperCoreLeg l = _agentShort();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        address burner = l.agent();
        uint256 t0 = vm.getBlockTimestamp();
        _flat(l);
        // (b) an hour after the burner went in
        vm.warp(t0 + 1 hours - 1);
        _endRefused(l, burner, HyperCoreLegState.TooEarly.selector);
        vm.warp(t0 + 1 hours);
        // (a) the signature names the current burner: not the old agent, not the sentinel, not zero
        _endRefused(l, address(0xA6E), MemberState.NotAllowed.selector);
        _endRefused(l, address(1), MemberState.NotAllowed.selector);
        _endRefused(l, address(0), MemberState.NotAllowed.selector);
        // (c) the perp not isolated
        core.setIsolated(address(l), 0, true);
        _endRefused(l, burner, MemberState.NotAllowed.selector);
        core.setIsolated(address(l), 0, false);
        // (c) DEX 0's notional is the perp's within one size step (the mark): another position shows
        uint64 own = 100_000 * 820_581;
        core.setMargin(0, address(l), 10_000e6, 8_205e6, own + 820_582);
        _endRefused(l, burner, MemberState.NotAllowed.selector);
        core.setMargin(0, address(l), 10_000e6, 8_205e6, own - 820_582);
        _endRefused(l, burner, MemberState.NotAllowed.selector);
        // DEX 0 unreadable
        core.setDexRefused(0, true);
        _endRefused(l, burner, MemberState.NotAllowed.selector);
        core.setDexRefused(0, false);
        // within one step either way: ends
        core.setMargin(0, address(l), 10_000e6, 8_205e6, own - 820_581);
        uint256 snap = vm.snapshotState();
        _act(l, OwnerMessages.END_QUARANTINE, burner);
        assertFalse(l.quarantine());
        vm.revertToState(snap);
        core.setMargin(0, address(l), 10_000e6, 8_205e6, own + 820_581);
        vm.expectEmit(address(l));
        emit HyperCoreLegState.QuarantineEnded();
        _act(l, OwnerMessages.END_QUARANTINE, burner);
        assertFalse(l.quarantine());
        assertEq(l.route(), Routes.CONTRACT);
        assertEq(l.agent(), burner);
        // once ended, a second one has nothing to end
        _endRefused(l, burner, MemberState.Unsupported.selector);
        // the route module's check runs only as the leg's own call: a direct one is refused
        vm.revertToState(snap);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(l)).routeOwnerAction(OwnerMessages.END_QUARANTINE, burner);
        assertTrue(l.quarantine());
    }

    function test_route_endQuarantineFlat() public {
        HyperCoreLeg l = _agentShort();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        address burner = l.agent();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _act(l, OwnerMessages.END_QUARANTINE, burner); // no position, DEX 0 empty
        assertFalse(l.quarantine());
    }

    function test_route_endQuarantineRefusedOnAgentRoute() public {
        HyperCoreLeg l = _agentShort();
        _flat(l);
        _endRefused(l, l.agent(), MemberState.Unsupported.selector);
    }

    // ── the signed parameters (spec §4.1, §13.2) ───────────────────────────────────────────────────

    function test_params_bounds() public {
        core.setMaxLeverage(0, 40); // BTC: mmr 1.25 %, so a reduction's compounded cost is at most 62.5 bp
        HyperCoreParams memory s = _routeParams();
        _valid(s);
        s.builder = address(0xB1);
        s.builderFeeX10 = 20;
        s.referralSetup = true;
        _valid(s);
        s = _routeParams();
        s.route = Routes.AGENT;
        _valid(s);
        s.side = Sides.LONG; // refused until a pair uses it (`test_params_longSideRefused`)
        _refused(s);
        // the route and the side: one of the two
        s = _routeParams(); s.route = 0; _refused(s);
        s = _routeParams(); s.route = 3; _refused(s);
        s = _routeParams(); s.side = 0; _refused(s);
        s = _routeParams(); s.side = 3; _refused(s);
        // the cap: 1x to 20x, and to the perp's max
        s = _routeParams(); s.maxLeverageX100 = 100; _valid(s);
        s = _routeParams(); s.maxLeverageX100 = 99; _refused(s);
        s = _routeParams(); s.maxLeverageX100 = 2_000; _valid(s);
        s = _routeParams(); s.maxLeverageX100 = 2_001; _refused(s);
        core.setMaxLeverage(0, 10);
        s = _routeParams(); s.maxLeverageX100 = 1_000; _valid(s);
        s = _routeParams(); s.maxLeverageX100 = 1_001; _refused(s);
        core.setMaxLeverage(0, 40);
        // the growth band: 10 bp to the order bound (50)
        s = _routeParams(); s.growBoundBp = 10; _valid(s);
        s = _routeParams(); s.growBoundBp = 9; _refused(s);
        s = _routeParams(); s.growBoundBp = 50; _valid(s);
        s = _routeParams(); s.growBoundBp = 51; _refused(s);
        // the reduction band: 10 bp to the order bound (51 is under BTC's ceiling, so the bound refuses it)
        s = _routeParams(); s.reduceBoundBp = 10; _valid(s);
        s = _routeParams(); s.reduceBoundBp = 9; _refused(s);
        s = _routeParams(); s.reduceBoundBp = 50; _valid(s);
        s = _routeParams(); s.reduceBoundBp = 51; _refused(s);
        // and its compounded cost (1 + r)(1 + 5 bp) - 1 at most mmr / 2 = 62.5 bp: 57 passes, 58 does not
        s = _routeParams(); s.orderBoundBp = 100; s.reduceBoundBp = 57; _valid(s);
        s = _routeParams(); s.orderBoundBp = 100; s.reduceBoundBp = 58; _refused(s);
        // the ceiling is the PERP's maintenance rate, not the signed cap: at 25x max (ETH's) it is 100 bp,
        // so 94 (99.05 bp compounded) passes and 95 (100.05 bp) does not
        core.setMaxLeverage(0, 25);
        s = _routeParams(); s.orderBoundBp = 100; s.reduceBoundBp = 94; _valid(s);
        s = _routeParams(); s.orderBoundBp = 100; s.reduceBoundBp = 95; _refused(s);
        core.setMaxLeverage(0, 40);
        // the builder fee: at most 2 bp
        s = _routeParams(); s.builderFeeX10 = 21; _refused(s);
    }

    function test_params_storedAtCreation() public {
        HyperCoreLegState l = HyperCoreLegState(payable(_contractShort()));
        assertEq(l.route(), Routes.CONTRACT);
        assertEq(l.side(), Sides.SHORT);
        assertEq(l.maxLeverageX100(), 1000);
        assertEq(l.growBoundBp(), GROW_BP);
        assertEq(l.reduceBoundBp(), REDUCE_BP);
        assertEq(l.orderBoundBp(), 50);
        assertEq(l.builder(), address(0));
        assertEq(l.builderFeeX10(), 0);
        assertFalse(l.quarantine());
        assertEq(l.pendingBuilder(), address(0));
        assertFalse(l.referralSetup());
        assertFalse(l.setupDone());
        assertEq(l.setupUntil(), 0);
        assertFalse(l.setupConfirmed());
    }

    function test_params_builderStoredAsSigned() public {
        core.setMaxLeverage(0, 40);
        StrategySpec memory c = _btcSpec();
        HyperCoreParams memory s = _shortParams(_btc(), btcProfile);
        s.builder = address(0xB1);
        s.builderFeeX10 = 20;
        c.legs[1].params = abi.encode(s);
        HyperCoreLegState l = HyperCoreLegState(payable(_create(c)[0]));
        assertEq(l.route(), Routes.AGENT);
        assertEq(l.builder(), address(0xB1));
        assertEq(l.builderFeeX10(), 20);
        assertFalse(l.referralSetup()); // signed only on the contract route (`test_params_referralSetupOnlyOnContractRoute`)
    }

    function test_mock_answersL1BlockAndMaxLeverage() public {
        core.setL1Block(42);
        core.setMaxLeverage(0, 40);
        (bool ok, bytes memory out) = address(uint160(0x809)).staticcall("");
        assertTrue(ok);
        assertEq(abi.decode(out, (uint64)), 42);
        (ok, out) = address(uint160(0x80a)).staticcall(abi.encode(uint32(0)));
        assertTrue(ok);
        CoreState.PerpAssetInfo memory info = abi.decode(out, (CoreState.PerpAssetInfo));
        assertEq(info.maxLeverage, 40);
    }

    function test_mock_lastOrderDecodesTheLastAction1() public {
        bytes memory a = abi.encodePacked(
            uint8(1), bytes3(uint24(1)), abi.encode(uint32(110000), true, uint64(5), uint64(6), false, uint8(3), uint128(9))
        );
        bytes memory b = abi.encodePacked(uint8(1), bytes3(uint24(7)), abi.encode(uint64(1), true));
        vm.startPrank(address(0xBEEF));
        (bool ok,) = CORE_WRITER.call(abi.encodeWithSignature("sendRawAction(bytes)", a));
        assertTrue(ok);
        (ok,) = CORE_WRITER.call(abi.encodeWithSignature("sendRawAction(bytes)", b));
        assertTrue(ok);
        vm.stopPrank();
        (bool ok2, bytes memory out) = CORE_WRITER.staticcall(abi.encodeWithSignature("lastOrder()"));
        assertTrue(ok2);
        (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif, uint128 cloid) =
            abi.decode(out, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertEq(asset, 110000);
        assertTrue(isBuy);
        assertEq(px, 5);
        assertEq(sz, 6);
        assertFalse(ro);
        assertEq(tif, 3);
        assertEq(cloid, 9);
    }

    // ── the contract route's order (spec §4.3, §4.5) ─────────────────────────────────────────────────

    uint64 constant PX = 1_000_000; // BTC at $100,000 (10^-1 USD, szd 5)
    int64 constant EQUITY = 10_000e6; // $10,000: at 10x, a cap of $100,000
    uint64 constant STEP = 1_000; // one BTC size step (1e-5) in an order's 1e-8

    /// A BTC contract-route short, flat, mark = oracle = $100,000, $10,000 of account value, HyperCore at
    /// block 1,000 (its clock is never 0: a 0 is a failed read).
    function _routeLeg() internal returns (HyperCoreLeg l) {
        l = HyperCoreLeg(payable(_contractShort()));
        core.setL1Block(1_000);
        core.setOracle(0, PX, 5);
        core.setMark(0, PX);
        core.setMargin(0, address(l), EQUITY, 0, 0);
    }

    /// A position of `szi` steps on the perp, DEX 0's notional at the mark.
    function _position(HyperCoreLeg l, int64 szi, int64 equity) internal {
        core.setPosition(address(l), 0, szi);
        uint64 abs = uint64(szi < 0 ? -szi : szi);
        core.setMargin(0, address(l), equity, 0, abs * core.mark(0));
    }

    function _order(HyperCoreLeg l, bool isBuy, uint64 steps, bool reduceOnly) internal {
        vm.prank(key);
        HyperCoreLegRoute(address(l)).order(isBuy, steps * STEP, reduceOnly, 0);
    }

    function _refusedOrder(HyperCoreLeg l, bool isBuy, uint64 steps, bool reduceOnly, bytes4 err) internal {
        vm.prank(key);
        vm.expectRevert(err);
        HyperCoreLegRoute(address(l)).order(isBuy, steps * STEP, reduceOnly, 0);
    }

    /// A growth sale in a later HyperCore block (Task 4's window: one unsettled risk-raising action).
    function _grow(HyperCoreLeg l, uint64 steps) internal {
        core.setL1Block(core.l1Block() + 1_000);
        _order(l, false, steps, false);
    }

    function _sent() internal view returns (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif, uint128 cloid) {
        return MockCoreWriter(CORE_WRITER).lastOrder();
    }

    function test_order_marketIsAlwaysThePerp() public {
        HyperCoreLeg l = _routeLeg();
        core.setOracle(1, 243_140, 4); // another perp, never named
        _grow(l, 1_000);
        (uint32 asset,,,,,,) = _sent();
        assertEq(asset, l.perp());
        assertEq(asset, 0);
        _position(l, -1_000, EQUITY);
        _order(l, true, 1_000, true);
        (asset,,,,,,) = _sent();
        assertEq(asset, 0);
    }

    function test_order_iocWithCloid() public {
        HyperCoreLeg l = _routeLeg();
        uint64 limit = RouteMath.limitFor(PX, PX, GROW_BP, false, 5); // growth: the growth band
        assertEq(limit, HyperCore.boundedPx(uint256(PX) * 1e7, GROW_BP, false, 1));
        assertLt(limit, HyperCore.boundedPx(uint256(PX) * 1e7, REDUCE_BP, false, 1));
        uint128 cloid = 0x1234_5678_9abc_def0_1122_3344_5566_7788;
        vm.expectEmit(address(l));
        emit HyperCoreLegState.RouteOrder(cloid, false, 1_000 * STEP, limit, false);
        vm.prank(key);
        HyperCoreLegRoute(address(l)).order(false, 1_000 * STEP, false, cloid);
        (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif, uint128 sentCloid) = _sent();
        assertEq(asset, 0);
        assertFalse(isBuy);
        assertEq(px, limit);
        assertEq(sz, 1_000 * STEP);
        assertFalse(ro);
        assertEq(tif, 3);
        assertEq(sentCloid, cloid);
    }

    function test_order_onlyTheKeyAndWholeSteps() public {
        HyperCoreLeg l = _routeLeg();
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        HyperCoreLegRoute(address(l)).order(false, 1_000 * STEP, false, 0);
        vm.prank(key);
        vm.expectRevert(RouteMath.BadSize.selector);
        HyperCoreLegRoute(address(l)).order(false, 1_000 * STEP + 1, false, 0);
        vm.prank(key);
        vm.expectRevert(RouteMath.BadSize.selector);
        HyperCoreLegRoute(address(l)).order(false, 0, false, 0);
        // no mark read: nothing is sent
        core.setMark(0, 0);
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(HyperCore.PrecompileFailed.selector, address(0x806)));
        HyperCoreLegRoute(address(l)).order(false, 1_000 * STEP, false, 0);
        core.setMark(0, PX);
        // the module itself, called directly, runs nothing
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        shortRoute.order(false, 1_000 * STEP, false, 0);
    }

    function test_order_reductionRules() public {
        HyperCoreLeg l = _routeLeg();
        _position(l, -10_000, EQUITY); // 0.1 BTC short
        // a short closes by buying
        _refusedOrder(l, false, 1_000, true, HyperCoreLegState.NotGrowth.selector);
        // never more than the position
        _refusedOrder(l, true, 10_001, true, HyperCoreLegState.OrderTooLarge.selector);
        // flat: nothing to reduce
        _position(l, 0, EQUITY);
        _refusedOrder(l, false, 1, true, HyperCoreLegState.OrderTooLarge.selector);
        _refusedOrder(l, true, 1, true, HyperCoreLegState.NotGrowth.selector);
        // the mark 1 % above the oracle: the buy's ceiling comes from the oracle, within 15 bp of both
        uint64 mark = PX * 101 / 100;
        core.setMark(0, mark);
        _position(l, -10_000, EQUITY);
        _order(l, true, 10_000, true);
        (, bool isBuy, uint64 px, uint64 sz,, uint8 tif,) = _sent();
        assertTrue(isBuy);
        assertEq(sz, 10_000 * STEP);
        assertEq(tif, 3);
        assertEq(px, HyperCore.boundedPx(uint256(PX) * 1e7, REDUCE_BP, true, 1)); // the reduce band, not growth's
        assertLt(px, HyperCore.boundedPx(uint256(PX) * 1e7, GROW_BP, true, 1));
        assertLe(px, uint256(PX) * 1e7 * (10_000 + REDUCE_BP) / 10_000);
        assertLe(px, uint256(mark) * 1e7 * (10_000 + REDUCE_BP) / 10_000);
        // a long closes by selling, its floor from the higher price (the mark)
        _position(l, 10_000, EQUITY);
        _order(l, false, 4_000, true);
        (, isBuy, px,,,,) = _sent();
        assertFalse(isBuy);
        assertEq(px, HyperCore.boundedPx(uint256(mark) * 1e7, REDUCE_BP, false, 1));
        assertGt(px, HyperCore.boundedPx(uint256(mark) * 1e7, GROW_BP, false, 1));
        assertGe(px, uint256(mark) * 1e7 * (10_000 - REDUCE_BP) / 10_000);
        assertGe(px, uint256(PX) * 1e7 * (10_000 - REDUCE_BP) / 10_000);
    }

    /// Quarantined (a switched strategy): no growth; reductions still go.
    function test_order_quarantineRefusesGrowthOnly() public {
        HyperCoreLeg q = _agentShort();
        _act(q, OwnerMessages.USE_CONTRACT, address(0));
        assertTrue(q.quarantine());
        core.setMargin(0, address(q), EQUITY, 0, 0);
        core.setMark(0, PX);
        core.setOracle(0, PX, 5);
        _refusedOrder(q, false, 1_000, false, HyperCoreLegState.Quarantined.selector);
        _position(q, -1_000, EQUITY);
        _order(q, true, 1_000, true);
        (,,,, bool ro,,) = _sent();
        assertTrue(ro);
    }

    function test_order_growthRules() public {
        HyperCoreLeg l = _routeLeg();
        // isolated
        core.setIsolated(address(l), 0, true);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Isolated.selector);
        core.setIsolated(address(l), 0, false);
        // the wrong side: a short never grows by buying
        _refusedOrder(l, true, 1_000, false, HyperCoreLegState.NotGrowth.selector);
        // crossing zero: a long position on a short strategy
        _position(l, 500, EQUITY);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.NotGrowth.selector);
        _position(l, 0, EQUITY);
        // under Hyperliquid's $10: 10 steps at the growth band's sale price, 998,000, is $9.98 (at the
        // reduce band's 998,500 it would be $9.985: either way under)
        assertEq(RouteMath.pxOf(RouteMath.limitFor(PX, PX, GROW_BP, false, 5), 5, false), 998_000);
        _refusedOrder(l, false, 10, false, HyperCoreLegState.BelowMinimum.selector);
        _grow(l, 11);
        // a quarter of the cap ($25,000 of $100,000) at most
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 25_001, false, HyperCoreLegState.OrderTooLarge.selector);
        _grow(l, 25_000);
        // the mark more than 20 bp from the oracle (of the mark), either way
        core.setMark(0, 1_002_100);
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.MarkOracleGap.selector);
        core.setMark(0, 1_002_000);
        _grow(l, 1_000);
        core.setMark(0, 998_000);
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.MarkOracleGap.selector);
        core.setMark(0, 998_100);
        _grow(l, 1_000);
    }

    /// The cap at the mark AND at the oracle (spec §4.3 step 5): `ntlPos + n ≤ L × (accountValue − w)`, and
    /// `|szi| × O + steps × O ≤ L × (E_O − w_O)` with `E_O = accountValue + szi × (O − M)`.
    function test_order_capAtMarkAndOracle() public {
        HyperCoreLeg l = _routeLeg();
        uint64 st = 8_000; // 0.08 BTC
        // Codex round 2: the mark 1 % above the oracle. At the oracle the order passes; at the mark it
        // would leave the account at 10.4x under a 10x cap
        uint64 o = PX;
        uint64 m = PX * 101 / 100;
        core.setMark(0, m);
        _position(l, -95_000, EQUITY);
        uint64 px = RouteMath.pxOf(RouteMath.limitFor(o, m, GROW_BP, false, 5), 5, false);
        int256 eO = int256(EQUITY) + int256(-95_000) * (int256(uint256(o)) - int256(uint256(m)));
        assertLe(100 * (95_000 * uint256(o) + st * uint256(o)), 1_000 * uint256(eO - int256(RouteMath.worstFill(st, o, px, false))));
        assertGt(100 * (95_000 * uint256(m) + st * uint256(m)), 1_000 * (uint256(uint64(EQUITY)) - RouteMath.worstFill(st, m, px, false)));
        _refusedOrder(l, false, st, false, HyperCoreLegState.CapExceeded.selector);

        // the oracle 1 % above the mark: at the mark it passes, at the oracle (the equity re-valued) not
        o = PX * 101 / 100;
        m = PX;
        core.setOracle(0, o, 5);
        core.setMark(0, m);
        _position(l, -90_000, EQUITY);
        px = RouteMath.pxOf(RouteMath.limitFor(o, m, GROW_BP, false, 5), 5, false);
        eO = int256(EQUITY) + int256(-90_000) * (int256(uint256(o)) - int256(uint256(m)));
        assertLe(100 * (90_000 * uint256(m) + st * uint256(m)), 1_000 * (uint256(uint64(EQUITY)) - RouteMath.worstFill(st, m, px, false)));
        assertGt(100 * (90_000 * uint256(o) + st * uint256(o)), 1_000 * uint256(eO - int256(RouteMath.worstFill(st, o, px, false))));
        _refusedOrder(l, false, st, false, HyperCoreLegState.CapExceeded.selector);

        // no equity left after the worst fill
        core.setOracle(0, PX, 5);
        core.setMark(0, PX);
        _position(l, 0, 1);
        _refusedOrder(l, false, 11, false, HyperCoreLegState.CapExceeded.selector);
    }

    /// The bucket (spec §4.5): one cap, full on the first growth, refilled over 24 hours.
    function test_order_budget() public {
        HyperCoreLeg l = _routeLeg();
        // the first growth finds it full: four quarters of the $100,000 cap
        for (uint256 i; i < 4; ++i) {
            _grow(l, 25_000);
        }
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 11, false, HyperCoreLegState.GrowthBudget.selector);
        // +12 h: half of it back
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _grow(l, 25_000);
        _grow(l, 25_000);
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 11, false, HyperCoreLegState.GrowthBudget.selector);
        // +2 days: never more than one cap
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        for (uint256 i; i < 4; ++i) {
            _grow(l, 25_000);
        }
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 11, false, HyperCoreLegState.GrowthBudget.selector);
        // the bucket's size follows the account: half the equity, half the cap
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        core.setMargin(0, address(l), EQUITY / 2, 0, 0);
        _grow(l, 12_500);
        _grow(l, 12_500);
        _grow(l, 12_500);
        _grow(l, 12_500);
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 11, false, HyperCoreLegState.GrowthBudget.selector);
    }

    function test_order_reductionNeverWaitsOnBudgetOrWindow() public {
        HyperCoreLeg l = _routeLeg();
        for (uint256 i; i < 4; ++i) {
            _grow(l, 25_000);
        }
        // in the SAME HyperCore block as the last growth (unsettled), the bucket empty: the reduction goes
        uint64 lastGrowth = core.l1Block();
        _position(l, -100_000, EQUITY);
        _order(l, true, 100_000, true);
        assertEq(core.l1Block(), lastGrowth);
        (, bool isBuy,, uint64 sz, bool ro,,) = _sent();
        assertTrue(isBuy);
        assertTrue(ro);
        assertEq(sz, 100_000 * STEP);
        // ... and the bucket was empty: in a later block, with no time passed and the buyback filled (flat,
        // so the cap is not what refuses), growth is refused by it
        _position(l, 0, EQUITY);
        core.setL1Block(lastGrowth + 1_000);
        _refusedOrder(l, false, 11, false, HyperCoreLegState.GrowthBudget.selector);
    }

    /// Review focus 3, the spec's §4.3 proof as arithmetic over what `order` sent: equity one unit over
    /// maintenance (BTC at 40x: mmr = 1/80), half the position bought back at the band's edge plus the fee,
    /// leaves the account above maintenance, its leverage lower.
    function test_order_reductionAtSolvencyEdgeStaysAboveMaintenance() public {
        HyperCoreLeg l = _routeLeg();
        uint64[2] memory oracles = [PX, PX * 1005 / 1000]; // the oracle at the mark, then 0.5 % above it
        for (uint256 i; i < 2; ++i) {
            core.setOracle(0, oracles[i], 5);
            uint256 n = 100_000 * uint256(PX); // 1 BTC short at the mark
            int64 e = int64(uint64(n / 80)) + 1;
            _position(l, -100_000, e);
            _order(l, true, 50_000, true);
            (,, uint64 limit,,,,) = _sent();
            assertEq(limit, HyperCore.boundedPx(uint256(PX) * 1e7, REDUCE_BP, true, 1)); // the reduce band of the mark
            assertLe(limit, uint256(PX) * 1e7 * (10_000 + REDUCE_BP) / 10_000);
            uint64 px = RouteMath.pxOf(limit, 5, true);
            uint256 loss = RouteMath.worstFill(50_000, PX, px, true);
            uint256 e1 = uint256(uint64(e)) - loss;
            uint256 n1 = 50_000 * uint256(PX);
            assertGe(e1 * 80, n1, "above maintenance");
            assertLe(n1 * uint256(uint64(e)), n * e1, "leverage not raised");
        }
    }

    /// Review focus 2: a book pushed 1 % up, the oracle unchanged. Growth waits; a protective buy is capped
    /// at the oracle's band, never the pushed mark's.
    function test_order_pushedMark() public {
        HyperCoreLeg l = _routeLeg();
        core.setMark(0, PX * 101 / 100);
        core.setL1Block(core.l1Block() + 1_000);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.MarkOracleGap.selector);
        _position(l, -10_000, EQUITY);
        _order(l, true, 10_000, true);
        (,, uint64 px,,,,) = _sent();
        assertEq(px, HyperCore.boundedPx(uint256(PX) * 1e7, REDUCE_BP, true, 1)); // oracle × (1 + b_r)
        assertLt(px, HyperCore.boundedPx(uint256(PX * 101 / 100) * 1e7, REDUCE_BP, true, 1));
    }

    // ── one unsettled risk-raising action at a time (spec §4.4) ───────────────────────────────────────

    function _fromMargin(HyperCoreLeg l) internal {
        vm.prank(key);
        l.fromMargin(100e6);
    }

    function _refusedFromMargin(HyperCoreLeg l) internal {
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.Unsettled.selector);
        l.fromMargin(100e6);
    }

    /// Review focus 1 (Codex round 1): two risk-raising actions in one HyperCore block would each pass the
    /// cap against the same reading. Growth then `fromMargin`, `fromMargin` then growth, growth then growth,
    /// and `prime` with either: the second is refused.
    function test_window_twoInOneBlock() public {
        HyperCoreLeg l = _routeLeg();
        // growth → fromMargin
        _grow(l, 1_000);
        _refusedFromMargin(l);
        // ... and growth → growth
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Unsettled.selector);
        // fromMargin → growth
        core.setL1Block(core.l1Block() + 1_000);
        _fromMargin(l);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Unsettled.selector);
        // ... and fromMargin → prime
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.Unsettled.selector);
        l.prime();
        // prime → growth, prime → fromMargin
        core.setL1Block(core.l1Block() + 1_000);
        vm.prank(key);
        l.prime();
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Unsettled.selector);
        _refusedFromMargin(l);
    }

    /// The window runs on HyperCore's block number, never HyperEVM's: a stalled HyperCore holds it.
    function test_window_runsOnHyperCoresClock() public {
        HyperCoreLeg l = _routeLeg();
        _grow(l, 1_000);
        uint64 t0 = core.l1Block();
        // 1,000 HyperEVM blocks and a day, HyperCore stalled: still unsettled
        vm.roll(block.number + 1_000);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Unsettled.selector);
        _refusedFromMargin(l);
        // 499 HyperCore blocks: still
        core.setL1Block(t0 + 499);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Unsettled.selector);
        // 500: it passes, and takes the window again from there
        core.setL1Block(t0 + 500);
        _order(l, false, 1_000, false);
        _refusedFromMargin(l);
        core.setL1Block(t0 + 1_000);
        _fromMargin(l);
    }

    /// Reductions and `toMargin` lower the leverage: never held, even in the block of an unsettled action.
    function test_window_reductionsAndToMarginNeverHeld() public {
        HyperCoreLeg l = _routeLeg();
        _grow(l, 1_000);
        _position(l, -1_000, EQUITY);
        _order(l, true, 1_000, true);
        (,,,, bool ro,,) = _sent();
        assertTrue(ro);
        MockERC20(HYPER_USDC).mint(address(l), 50e6);
        vm.prank(key);
        l.toMargin(50e6);
        assertEq(MockCoreDepositWallet(CDW).lastAmount(), 50e6);
        // ... and a reduction after a fromMargin, in its block
        core.setL1Block(core.l1Block() + 1_000);
        _fromMargin(l);
        _order(l, true, 1_000, true);
        (,,,, ro,,) = _sent();
        assertTrue(ro);
        // the window they left alone is the fromMargin's: growth still waits
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Unsettled.selector);
    }

    /// The agent route is unchanged: its `fromMargin` and `prime` never wait on the window.
    function test_window_agentRouteUnchanged() public {
        HyperCoreLeg l = _agentShort();
        core.setL1Block(7);
        vm.startPrank(key);
        l.fromMargin(100e6);
        l.fromMargin(100e6);
        l.prime();
        l.prime();
        vm.stopPrank();
    }

    /// The clock is HyperCore's or nothing: a 0x809 that reads 0 (a 0 would leave the window open for
    /// good) or fails refuses every risk-raising action, never passes it.
    function test_window_zeroOrFailedClockRefuses() public {
        HyperCoreLeg l = _routeLeg();
        bytes memory failed = abi.encodeWithSelector(HyperCore.PrecompileFailed.selector, HyperCore.PX_L1_BLOCK);
        core.setL1Block(0);
        _clockRefuses(l, failed);
        // a read that fails
        core.setL1Block(1_000);
        vm.mockCallRevert(HyperCore.PX_L1_BLOCK, "", "precompile error");
        _clockRefuses(l, failed);
        // ... or answers nothing
        vm.clearMockedCalls();
        vm.etch(HyperCore.PX_L1_BLOCK, "");
        _clockRefuses(l, failed);
    }

    function _clockRefuses(HyperCoreLeg l, bytes memory err) internal {
        vm.startPrank(key);
        vm.expectRevert(err);
        HyperCoreLegRoute(address(l)).order(false, 1_000 * STEP, false, 0);
        vm.expectRevert(err);
        l.fromMargin(100e6);
        vm.expectRevert(err);
        l.prime();
        vm.stopPrank();
    }

    // ── `fromMargin` and `prime` on the contract route (spec §4.2, §4.4) ─────────────────────────────

    address constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;

    /// CoreWriter action `i`: its id and its fields.
    function _action(uint256 i) internal view returns (uint24 id, bytes memory body) {
        bytes memory d = MockCoreWriter(CORE_WRITER).action(i).data;
        id = uint24(uint8(d[1])) << 16 | uint24(uint8(d[2])) << 8 | uint24(uint8(d[3]));
        body = new bytes(d.length - 4);
        for (uint256 j; j < body.length; ++j) {
            body[j] = d[j + 4];
        }
    }

    /// Action `i` is CoreWriter 7, perp → spot, of `ntl` (USDC, 6 dp).
    function _assertToSpot(uint256 i, uint64 ntl) internal view {
        (uint24 id, bytes memory body) = _action(i);
        assertEq(id, 7);
        (uint64 amount, bool toPerp) = abi.decode(body, (uint64, bool));
        assertEq(amount, ntl);
        assertFalse(toPerp);
    }

    /// Action `i` is CoreWriter 13, spot USDC → the leg on HyperEVM, of `wei_` (Core wei, 8 dp).
    function _assertToEvm(uint256 i, uint64 wei_) internal view {
        (uint24 id, bytes memory body) = _action(i);
        assertEq(id, 13);
        (address to,, uint32 src, uint32 dst, uint64 token, uint64 amount) =
            abi.decode(body, (address, address, uint32, uint32, uint64, uint64));
        assertEq(to, USDC_SYSTEM);
        assertEq(src, type(uint32).max);
        assertEq(dst, type(uint32).max);
        assertEq(token, 0);
        assertEq(amount, wei_);
    }

    function _count() internal view returns (uint256) {
        return MockCoreWriter(CORE_WRITER).count();
    }

    function _release(HyperCoreLeg l, uint64 amount) internal {
        vm.prank(key);
        l.fromMargin(amount);
    }

    function _releaseRefused(HyperCoreLeg l, uint64 amount, bytes4 err) internal {
        vm.prank(key);
        vm.expectRevert(err);
        l.fromMargin(amount);
    }

    /// Codex round 14 (spec §4.4): an attacker who is the book depresses the mark $4 under the oracle on a
    /// 1 BTC short. At the mark the short gains $4 of equity and sheds $4 of notional, so a $19.90 release
    /// fits there exactly; at the oracle (`E_O = accountValue + szi × (O − M)`) only $15.50 does.
    function test_fromMargin_capAtMarkAndOracle() public {
        HyperCoreLeg l = _routeLeg();
        uint64 m = PX - 40; // $99,996
        core.setMark(0, m);
        core.setPosition(address(l), 0, -100_000); // 1 BTC
        core.setMargin(0, address(l), 10_019_500_000, 0, 100_000 * m);
        // at the mark: 10 × ($10,019.50 − $19.90) = $99,996 = ntlPos, the cap exactly
        assertEq(10 * (10_019_500_000 - 19_900_000), 100_000 * uint256(m));
        // at the oracle: 10 × ($10,015.50 − $19.90) = $99,956 < 1 BTC × $100,000
        _releaseRefused(l, 19_900_000, HyperCoreLegState.CapExceeded.selector);
        _releaseRefused(l, 15_500_001, HyperCoreLegState.CapExceeded.selector);
        uint256 n = _count();
        _release(l, 15_500_000); // the oracle's room, exactly
        assertEq(_count(), n + 2);
        _assertToSpot(n, 15_500_000);
        _assertToEvm(n + 1, 15_500_000 * 100);

        // the other way: the mark $4 above the oracle, the short at its cap there. The oracle has $4.40
        // of room; the mark none, and refuses a single micro-dollar
        core.setL1Block(core.l1Block() + 1_000);
        m = PX + 40;
        core.setMark(0, m);
        core.setMargin(0, address(l), 10_000_400_000, 0, 100_000 * m);
        _releaseRefused(l, 1, HyperCoreLegState.CapExceeded.selector);

        // flat, every dollar of margin can leave (0 ≤ L × 0), never one more
        core.setMark(0, PX);
        _position(l, 0, EQUITY);
        _releaseRefused(l, uint64(EQUITY) + 1, HyperCoreLegState.CapExceeded.selector);
        _release(l, uint64(EQUITY));
    }

    /// Codex round 16: CoreWriter 7 landed, 13 dropped (no HYPE): the money waits on spot. The retry
    /// takes from margin only what spot lacks (`debit`), checks the cap on that, and 13 sends it all.
    function test_fromMargin_debitsOnlyWhatIsMissing() public {
        HyperCoreLeg l = _routeLeg();
        // 1 BTC short at $100,000 with $70 of room under the 10x cap
        _position(l, -100_000, 10_070e6);
        // $40 on spot, $10 of it on hold: $30 available (8 dp, a remainder under a cent's 1e-6 ignored)
        core.setSpot(address(l), 0, 40e8 + 99);
        core.setHold(address(l), 0, 10e8);
        _releaseRefused(l, 100e6 + 1, HyperCoreLegState.CapExceeded.selector); // $70.000001 from margin
        uint256 n = _count();
        _release(l, 100e6);
        assertEq(_count(), n + 2);
        _assertToSpot(n, 70e6);
        _assertToEvm(n + 1, 100e8);
    }

    /// Review focus 4 (Codex round 17): after a rally above the cap, money stranded on spot still comes
    /// back. `debit = 0` sends only CoreWriter 13: no cap, no window (it neither waits nor holds it). In
    /// quarantine it is refused all the same.
    function test_fromMargin_spotOnlyRetryAboveCap() public {
        HyperCoreLeg l = _routeLeg();
        uint64 t0 = core.l1Block();
        _release(l, 100e6); // the window, from t0
        // 7 landed, 13 dropped: $100 on spot; then BTC doubles, the short at 20x on a 10x cap
        core.setSpot(address(l), 0, 100e8);
        core.setOracle(0, 2 * PX, 5);
        core.setMark(0, 2 * PX);
        _position(l, -100_000, EQUITY);
        // inside the window: no wait
        core.setL1Block(t0 + 300);
        uint256 n = _count();
        _release(l, 100e6);
        assertEq(_count(), n + 1);
        _assertToEvm(n, 100e8);
        // ... and it took no window: a debit at t0 + 500 passes (flat again), held from t0 alone
        core.setSpot(address(l), 0, 0);
        _position(l, 0, EQUITY);
        core.setL1Block(t0 + 499);
        _releaseRefused(l, 100e6, HyperCoreLegState.Unsettled.selector);
        core.setL1Block(t0 + 500);
        _release(l, 100e6);

        // quarantine refuses it, spot-only or not
        HyperCoreLeg q = _agentShortAs(keccak256("quarantined"));
        _act(q, OwnerMessages.USE_CONTRACT, address(0));
        assertTrue(q.quarantine());
        core.setSpot(address(q), 0, 100e8);
        _releaseRefused(q, 100e6, HyperCoreLegState.Quarantined.selector);
        core.setSpot(address(q), 0, 0);
        _releaseRefused(q, 100e6, HyperCoreLegState.Quarantined.selector);
    }

    /// `prime` (spec §4.2): only while DEX 0 is flat (`ntlPos == 0`, a position on any perp counts), never
    /// in quarantine, and a risk-raising action.
    function test_prime_onlyFlatNeverQuarantined() public {
        HyperCoreLeg l = _routeLeg();
        // a position on another DEX 0 perp: the strategy's own is flat
        core.setMargin(0, address(l), EQUITY, 0, 1);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.NotFlat.selector);
        l.prime();
        core.setMargin(0, address(l), EQUITY, 0, 0);
        uint256 n = _count();
        vm.prank(key);
        l.prime();
        assertEq(_count(), n + 2);
        _assertToSpot(n, 1_200_000);
        _assertToEvm(n + 1, 5_000_000);
        // it took the window
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.Unsettled.selector);
        l.prime();
        _refusedFromMargin(l);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.Unsettled.selector);

        // quarantine: refused, flat or not
        HyperCoreLeg q = _agentShortAs(keccak256("quarantined"));
        _act(q, OwnerMessages.USE_CONTRACT, address(0));
        assertTrue(q.quarantine());
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.Quarantined.selector);
        q.prime();
    }

    /// The agent route is unchanged: the whole amount from margin, spot ignored, no cap, no clock.
    function test_fromMargin_agentRouteUnchanged() public {
        HyperCoreLeg l = _agentShort();
        core.setSpot(address(l), 0, 50e8);
        core.setOracle(0, PX, 5);
        core.setMark(0, PX);
        _position(l, -100_000, 1_000e6); // 100x
        uint256 n = _count();
        vm.startPrank(key);
        l.fromMargin(100e6);
        l.fromMargin(100e6);
        l.prime();
        vm.stopPrank();
        assertEq(_count(), n + 6);
        _assertToSpot(n, 100e6);
        _assertToEvm(n + 1, 100e8);
        _assertToSpot(n + 4, 1_200_000);
        _assertToEvm(n + 5, 5_000_000);
    }

    /// Decision 33: on the agent route the key's own order stays reduce-only, its client id sent.
    function test_order_agentRouteStaysReduceOnly() public {
        HyperCoreLeg l = _agentShort();
        core.setMark(0, core.oracle(0));
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(l)).order(false, 1_000 * STEP, false, 5);
        vm.prank(key);
        HyperCoreLegRoute(address(l)).order(true, 1_000 * STEP, true, 5);
        (uint32 asset, bool isBuy, uint64 px,, bool ro, uint8 tif, uint128 cloid) = _sent();
        assertEq(asset, 0);
        assertTrue(isBuy);
        assertTrue(ro);
        assertEq(tif, 3);
        assertEq(cloid, 5);
        // the oracle's band (mark = oracle), at BTC's ceiling under the 100 bp order bound (spec §6)
        assertEq(px, HyperCore.boundedPx(uint256(core.oracle(0)) * 1e7, 57, true, 1));
    }
    // ── leftovers of an old agent: cancelResting and closeStray (spec §4.2, §5.3) ───────────────────────

    function _cancels() internal pure returns (HyperCoreLegState.Cancel[] memory cs) {
        cs = new HyperCoreLegState.Cancel[](2);
        cs[0] = HyperCoreLegState.Cancel({asset: 0, byCloid: false, id: 77});
        cs[1] = HyperCoreLegState.Cancel({asset: 10_107, byCloid: true, id: 0xC10D});
    }

    /// Anyone cancels, any asset, by oid (CoreWriter 10) or cloid (11), never counted (a cancel moves no
    /// holding, and a stranger must not bump `opCount` under a hub's snapshot); on the agent route never.
    function test_cancelResting_anyoneOnContractRoute() public {
        HyperCoreLeg l = _routeLeg();
        uint256 n = _count();
        uint256 ops = l.opCount();
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).cancelResting(_cancels());
        assertEq(_count(), n + 2);
        assertEq(l.opCount(), ops, "opCount unchanged");
        (uint24 id, bytes memory body) = _action(n);
        assertEq(id, 10);
        (uint32 asset, uint64 oid) = abi.decode(body, (uint32, uint64));
        assertEq(asset, 0);
        assertEq(oid, 77);
        (id, body) = _action(n + 1);
        assertEq(id, 11);
        (uint32 asset2, uint128 cloid) = abi.decode(body, (uint32, uint128));
        assertEq(asset2, 10_107);
        assertEq(cloid, 0xC10D);

        HyperCoreLeg a = _agentShortAs(keccak256("agent route"));
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(a)).cancelResting(_cancels());
    }

    /// In the exit the agent may be the owner's own: a stranger cancels nothing (exitStep does it).
    function test_cancelResting_refusedInExit() public {
        HyperCoreLeg l = _routeLeg();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        l.beginExit(deadline, _beginExitSig(deadline));
        assertTrue(l.exiting());
        uint256 n = _count();
        vm.prank(stranger);
        vm.expectRevert(MemberState.Exiting.selector);
        HyperCoreLegRoute(address(l)).cancelResting(_cancels());
        assertEq(_count(), n);
    }

    uint64 constant STRAY_MARK = 1_000_000; // BTC's mark, $100,000 (10^-1 USD, szd 5)
    uint64 constant STRAY_ORACLE = 1_020_000; // BTC's oracle, $102,000: a 2 % gap

    /// A BTC stray (40x) on perp 1 of `l`: `szi` steps, mark $100,000, oracle $102,000, the strategy flat
    /// and DEX 0's equity `equity`.
    function _stray(HyperCoreLeg l, int64 szi, int64 equity) internal {
        core.setMaxLeverage(1, 40);
        core.setOracle(1, STRAY_ORACLE, 5);
        core.setMark(1, STRAY_MARK);
        core.setPosition(address(l), 1, szi);
        uint64 abs = uint64(szi < 0 ? -szi : szi);
        core.setMargin(0, address(l), equity, 0, abs * STRAY_MARK);
    }

    function _closeStray(HyperCoreLeg l, uint32 p) internal {
        vm.prank(key);
        HyperCoreLegRoute(address(l)).closeStray(p);
    }

    /// A contract-route strategy whose own perp is at 25x (ETH's, ceiling 94 bp) with a 90 bp reduce band:
    /// wider than a BTC stray's own ceiling (57 bp at 40x).
    function _wideReduceLeg() internal returns (HyperCoreLeg l) {
        core.setMaxLeverage(0, 25);
        HyperCoreParams memory s = _routeParams();
        s.orderBoundBp = 100;
        s.reduceBoundBp = 90;
        StrategySpec memory c = _btcSpec();
        c.legs[1].params = abi.encode(s);
        l = HyperCoreLeg(payable(_createAs(keccak256("wide reduce band"), c)[0]));
        core.setL1Block(1_000);
        core.setOracle(0, PX, 5);
        core.setMark(0, PX);
    }

    /// Codex round 6: a BTC stray at a 2 % mark–oracle gap. The close is reduce-only IOC for the whole
    /// position, on the stray's own perp, its limit within the band of BOTH of the stray's prices (never
    /// the oracle's 2 % away); with the strategy's band wider than BTC's ceiling, capped at that ceiling
    /// (57 bp at 40x); and a partial fill at the edge keeps the account above BTC's maintenance (1/80).
    function test_closeStray_ownMarkAndOwnCeiling() public {
        // the strategy's 15 bp band, under BTC's ceiling: a buy's ceiling from the mark, a sale's floor
        // from the oracle, each within 15 bp of both
        HyperCoreLeg l = _routeLeg();
        _stray(l, -100_000, EQUITY);
        _closeStray(l, 1);
        (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif, uint128 cloid) = _sent();
        assertEq(asset, 1);
        assertTrue(isBuy);
        assertEq(sz, 100_000 * STEP);
        assertTrue(ro);
        assertEq(tif, 3);
        assertEq(cloid, 0);
        assertEq(px, HyperCore.boundedPx(uint256(STRAY_MARK) * 1e7, REDUCE_BP, true, 1));
        assertLe(px, uint256(STRAY_MARK) * 1e7 * (10_000 + REDUCE_BP) / 10_000);
        assertLe(px, uint256(STRAY_ORACLE) * 1e7 * (10_000 + REDUCE_BP) / 10_000);
        vm.roll(block.number + 20);
        _stray(l, 100_000, EQUITY);
        _closeStray(l, 1);
        (, isBuy, px,,,,) = _sent();
        assertFalse(isBuy);
        assertEq(px, HyperCore.boundedPx(uint256(STRAY_ORACLE) * 1e7, REDUCE_BP, false, 1));
        assertGe(px, uint256(STRAY_MARK) * 1e7 * (10_000 - REDUCE_BP) / 10_000);
        assertGe(px, uint256(STRAY_ORACLE) * 1e7 * (10_000 - REDUCE_BP) / 10_000);

        // the strategy's 90 bp band, over BTC's ceiling: capped at 57 bp, from BTC's own mark
        HyperCoreLeg w = _wideReduceLeg();
        uint256 n = 100_000 * uint256(STRAY_MARK); // 1 BTC short at the mark
        int64 e = int64(uint64(n / 80)) + 1; // one unit over BTC's maintenance
        _stray(w, -100_000, e);
        _closeStray(w, 1);
        (asset, isBuy, px,,,,) = _sent();
        assertEq(asset, 1);
        assertTrue(isBuy);
        assertEq(px, HyperCore.boundedPx(uint256(STRAY_MARK) * 1e7, 57, true, 1));
        assertLt(px, HyperCore.boundedPx(uint256(STRAY_MARK) * 1e7, 90, true, 1));
        assertLe(px, uint256(STRAY_MARK) * 1e7 * (10_000 + 57) / 10_000);
        assertLe(px, uint256(STRAY_ORACLE) * 1e7 * (10_000 + 57) / 10_000);
        // half filled at that edge, the fee counted: above maintenance, the leverage not raised
        uint64 fill = RouteMath.pxOf(px, 5, true);
        uint256 e1 = uint256(uint64(e)) - RouteMath.worstFill(50_000, STRAY_MARK, fill, true);
        uint256 n1 = 50_000 * uint256(STRAY_MARK);
        assertGe(e1 * 80, n1, "above maintenance");
        assertLe(n1 * uint256(uint64(e)), n * e1, "leverage not raised");
    }

    function test_closeStray_refusesTheStrategyPerpAndSpot() public {
        HyperCoreLeg l = _routeLeg();
        _position(l, -100_000, EQUITY);
        vm.startPrank(key);
        vm.expectRevert(HyperCoreLegState.BadAsset.selector);
        HyperCoreLegRoute(address(l)).closeStray(0); // the strategy's own perp: `order`'s
        vm.expectRevert(HyperCoreLegState.BadAsset.selector);
        HyperCoreLegRoute(address(l)).closeStray(10_000); // spot
        vm.expectRevert(HyperCoreLegState.BadAsset.selector);
        HyperCoreLegRoute(address(l)).closeStray(110_000); // HIP-3
        vm.stopPrank();
    }

    /// The key only, on the contract route only, something to close, paced 20 blocks.
    function test_closeStray_keyRouteAndPacing() public {
        HyperCoreLeg l = _routeLeg();
        _stray(l, 0, EQUITY);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector); // flat: nothing to close
        HyperCoreLegRoute(address(l)).closeStray(1);
        _stray(l, -100_000, EQUITY);
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        HyperCoreLegRoute(address(l)).closeStray(1);
        uint256 n = _count();
        _closeStray(l, 1);
        assertEq(_count(), n + 1);
        vm.roll(block.number + 19);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.TooEarly.selector);
        HyperCoreLegRoute(address(l)).closeStray(1);
        vm.roll(block.number + 1);
        _closeStray(l, 1);
        assertEq(_count(), n + 2);

        HyperCoreLeg a = _agentShortAs(keccak256("agent route"));
        _stray(a, -100_000, EQUITY);
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(a)).closeStray(1);
    }

    // ── the exit's automatic closes, and the agent route's reduce-only order (spec §6, the exit row) ──

    uint64 constant ETH_ORACLE = 243_140; // ETH's oracle, $2,431.40 (10^-2 USD, szd 4)
    uint64 constant ETH_MARK = 245_571; // ETH's mark, 1 % over its oracle

    /// The owner signed a 300 bp `orderBoundBp` (Codex round 11) on a contract-route BTC strategy (40x,
    /// ceiling 57 bp); ETH (25x, ceiling 94 bp) on perp 1, its mark 1 % over its oracle. In exit.
    function _wideBoundExitLeg() internal returns (HyperCoreLeg l) {
        core.setMaxLeverage(0, 40);
        HyperCoreParams memory s = _routeParams();
        s.orderBoundBp = 300;
        StrategySpec memory c = _btcSpec();
        c.legs[1].params = abi.encode(s);
        l = HyperCoreLeg(payable(_create(c)[0]));
        assertEq(l.orderBoundBp(), 300);
        core.setL1Block(1_000);
        core.setOracle(0, PX, 5);
        core.setMark(0, PX);
        core.setMaxLeverage(1, 25);
        core.setOracle(1, ETH_ORACLE, 4);
        core.setMark(1, ETH_MARK);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        l.beginExit(deadline, _beginExitSig(deadline));
    }

    /// A stranger's `exitStep`, naming perp 1 besides the strategy's own.
    function _exitStep(HyperCoreLeg l) internal {
        HyperCoreLegState.ExitArgs memory a;
        a.perps = new uint32[](1);
        a.perps[0] = 1;
        vm.prank(stranger);
        HyperCoreLegExit(address(l)).exitStep(a);
    }

    /// Codex round 11: a signed 300 bp `orderBoundBp`, $100,000 of ETH, $2,100 of equity, a 20 % fill at
    /// +3 % liquidates the account with no market move. Each automatic close is banded from the STRICTER of
    /// its perp's oracle and mark, at `min(orderBoundBp, that perp's own maintenance ceiling)` read in the
    /// call: BTC's 57 bp, ETH's 94 bp, never the signed 300. A 20 % fill at that edge, the fee counted,
    /// keeps the account above ETH's maintenance (1/50).
    function test_exit_closeCappedByCeilingAndStrictest() public {
        HyperCoreLeg l = _wideBoundExitLeg();
        // the strategy's own perp, BTC: 57 bp (perp 1 flat: nothing sent for it)
        _position(l, -100_000, EQUITY);
        uint256 n0 = _count();
        _exitStep(l);
        (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif, uint128 cloid) = _sent();
        assertEq(asset, 0);
        assertTrue(isBuy);
        assertEq(sz, 100_000 * STEP);
        assertTrue(ro);
        assertEq(tif, 3);
        assertEq(cloid, 0);
        assertEq(px, HyperCore.boundedPx(uint256(PX) * 1e7, 57, true, 1));
        assertLt(px, HyperCore.boundedPx(uint256(PX) * 1e7, 300, true, 1));

        // ETH, its mark 1 % over its oracle: a buy's ceiling from the oracle, a sale's floor from the mark,
        // each at 94 bp and so within 94 bp of both prices
        core.setPosition(address(l), 0, 0);
        core.setPosition(address(l), 1, -411_285);
        vm.roll(vm.getBlockNumber() + 20);
        _exitStep(l);
        (asset, isBuy, px, sz,,,) = _sent();
        assertEq(asset, 1);
        assertTrue(isBuy);
        assertEq(sz, 411_285 * 1e4);
        assertEq(px, HyperCore.boundedPx(uint256(ETH_ORACLE) * 1e6, 94, true, 2));
        assertLe(px, uint256(ETH_ORACLE) * 1e6 * (10_000 + 94) / 10_000);
        assertLe(px, uint256(ETH_MARK) * 1e6 * (10_000 + 94) / 10_000);
        core.setPosition(address(l), 1, 411_285);
        vm.roll(vm.getBlockNumber() + 20);
        _exitStep(l);
        (asset, isBuy, px,,,,) = _sent();
        assertEq(asset, 1);
        assertFalse(isBuy);
        assertEq(px, HyperCore.boundedPx(uint256(ETH_MARK) * 1e6, 94, false, 2));
        assertGe(px, uint256(ETH_MARK) * 1e6 * (10_000 - 94) / 10_000);
        assertGe(px, uint256(ETH_ORACLE) * 1e6 * (10_000 - 94) / 10_000);

        // the round-11 account: $100,000 of ETH short at mark = oracle, $2,100 of equity (maintenance $2,000)
        core.setMark(1, ETH_ORACLE);
        uint64 st = 411_285;
        uint256 n = uint256(st) * ETH_ORACLE; // $99,999.83
        uint256 e = 2_100e6;
        assertGe(e * 50, n, "above maintenance before");
        core.setPosition(address(l), 1, -int64(st));
        core.setMargin(0, address(l), int64(uint64(e)), 0, uint64(n));
        vm.roll(vm.getBlockNumber() + 20);
        _exitStep(l);
        (asset, isBuy, px,,,,) = _sent();
        assertEq(asset, 1);
        assertEq(px, HyperCore.boundedPx(uint256(ETH_ORACLE) * 1e6, 94, true, 2));
        // a 20 % fill at that edge, the fee counted: above maintenance
        uint64 f = st / 5;
        uint256 n1 = n - uint256(f) * ETH_ORACLE;
        uint256 e1 = e - RouteMath.worstFill(f, ETH_ORACLE, RouteMath.pxOf(px, 4, true), true);
        assertGe(e1 * 50, n1, "above maintenance");
        // where the signed 300 bp would have taken it under
        uint64 wide = HyperCore.boundedPx(uint256(ETH_ORACLE) * 1e6, 300, true, 2);
        uint256 eWide = e - RouteMath.worstFill(f, ETH_ORACLE, RouteMath.pxOf(wide, 4, true), true);
        assertLt(eWide * 50, n1, "300 bp: under maintenance");
        uint256 orders;
        for (uint256 j = n0; j < _count(); ++j) {
            (uint24 id,) = _action(j);
            if (id == 1) orders++;
        }
        assertEq(orders, 4, "one close per step");
    }

    /// The agent route's reduce-only `order` is priced by the same rule: the stricter of oracle and mark,
    /// at `min(orderBoundBp, the perp's ceiling)` (BTC's 57 bp under the fixture's 100).
    function test_order_agentRouteCappedByCeilingAndStrictest() public {
        HyperCoreLeg l = _agentShort();
        assertEq(l.orderBoundBp(), 100);
        uint64 o = core.oracle(0);
        core.setMark(0, o * 101 / 100); // the mark 1 % over the oracle
        vm.prank(key);
        HyperCoreLegRoute(address(l)).order(true, 1_000 * STEP, true, 5);
        (,, uint64 px,,,,) = _sent();
        assertEq(px, HyperCore.boundedPx(uint256(o) * 1e7, 57, true, 1)); // a buy: from the lower, the oracle
        vm.prank(key);
        HyperCoreLegRoute(address(l)).order(false, 1_000 * STEP, true, 6);
        (,, px,,,,) = _sent();
        assertEq(px, HyperCore.boundedPx(uint256(o * 101 / 100) * 1e7, 57, false, 1)); // a sale: the higher, the mark
        // an unpriced perp: nothing sent
        core.setMark(0, 0);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.BadAsset.selector);
        HyperCoreLegRoute(address(l)).order(true, 1_000 * STEP, true, 7);
    }

    /// CR-X1 kept: a perp whose position reads but whose oracle, mark or `perpAssetInfo` can't be read (or
    /// reads 0) is not closed, and the step does not revert: the close counts as still open, so nothing
    /// leaves the margin (the gate) though DEX 0's summary reads no notional.
    function test_exit_closeSkipsAnUnpricedPerp() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 6; ++i) {
            vm.revertToState(snap); // a fresh exit per case
            HyperCoreLeg l = _wideBoundExitLeg();
            core.setPosition(address(l), 1, -10_000);
            core.setMargin(0, address(l), EQUITY, 0, 0); // no notional: only the close holds the gate
            core.setWithdrawable(address(l), 100e6);
            if (i == 0) vm.mockCallRevert(HyperCore.PX_MARK, abi.encode(uint32(1)), "");
            if (i == 1) vm.mockCallRevert(HyperCore.PX_ORACLE, abi.encode(uint32(1)), "");
            if (i == 2) vm.mockCallRevert(HyperCore.PX_PERP_ASSET_INFO, abi.encode(uint32(1)), "");
            if (i == 3) core.setMark(1, 0);
            if (i == 4) core.setOracle(1, 0, 4);
            if (i == 5) core.setPosition(address(l), 1, 0); // the control: flat, so the margin moves
            uint256 from = _count();
            _exitStep(l);
            uint256 orders;
            uint256 moves;
            for (uint256 j = from; j < _count(); ++j) {
                (uint24 id,) = _action(j);
                if (id == 1) orders++;
                if (id == 7) moves++;
            }
            assertEq(orders, 0, "no close sent");
            assertEq(moves, i == 5 ? 1 : 0, "the gate holds while the close is open");
            vm.clearMockedCalls();
        }
    }

    // ── the leg's dispatch (the route module by default) ────────────────────────────────────────────────

    /// Exit modules A and B are named selector by selector, VaultUpgrade's are routed before them; any
    /// other selector goes to the route module, whose fallback refuses what it doesn't hold.
    function test_dispatch_routeModuleIsTheDefault() public {
        HyperCoreLeg l = _routeLeg();
        // an unknown selector on the leg: still `Unsupported`, now from the route module's fallback
        (bool ok, bytes memory ret) = address(l).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(MemberState.Unsupported.selector));
        // the route module called directly: an unknown selector refused by its fallback, its functions by
        // `delegated`
        (ok, ret) = address(shortRoute).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(MemberState.Unsupported.selector));
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        shortRoute.order(false, STEP, true, 0);
        vm.expectRevert(MemberState.NotAllowed.selector);
        shortRoute.cancelResting(_cancels());
        // the route's functions dispatch from the leg
        uint256 n = _count();
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).cancelResting(_cancels());
        assertEq(_count(), n + 2);
        // exit modules' and VaultUpgrade's selectors still reach their own modules, not the route's
        (uint8 state,,,) = HyperCoreLegExitB(address(l)).exitStatus();
        assertEq(state, 0);
        assertTrue(HyperCoreLegExit(address(l)).readsClean());
        (uint8 kind,,,) = VaultUpgrade(address(l)).pendingAction();
        assertEq(kind, 0);
    }

    // ── the builder fee (spec §13.2) ──────────────────────────────────────────────────────────────────

    address constant B1 = address(0xB1);
    address constant B2 = address(0xB2);

    /// A BTC strategy on `route_` whose builder is B1 at `fee` (tenths of a bp). Returns the short leg.
    function _builderShort(uint8 route_, uint16 fee) internal returns (HyperCoreLeg l) {
        return _builderShortAs(STRATEGY, route_, fee);
    }

    function _builderShortAs(bytes32 id, uint8 route_, uint16 fee) internal returns (HyperCoreLeg l) {
        core.setMaxLeverage(0, 40);
        StrategySpec memory c = _btcSpec();
        HyperCoreParams memory s = route_ == Routes.CONTRACT ? _routeParams() : _shortParams(_btc(), btcProfile);
        s.builder = B1;
        s.builderFeeX10 = fee;
        c.legs[1].params = abi.encode(s);
        l = HyperCoreLeg(payable(_createAs(id, c)[0]));
        core.setExists(address(l), true);
    }

    /// The owner's `BuilderFee(b, fee)`, signed by `pk`'s wallet credential at its nonce now.
    function _feeSig(HyperCoreLeg l, uint256 pk, address b, uint16 fee)
        internal
        view
        returns (bytes32 cred, uint256 deadline, bytes memory sig)
    {
        cred = walletCred(vm.addr(pk));
        deadline = vm.getBlockTimestamp() + 1 hours;
        sig = _sign(
            pk,
            keccak256(
                abi.encode(
                    OwnerMessagesV1.BUILDER_FEE_TYPEHASH, address(l), block.chainid, b, fee, l.ownerNonceOf(cred), deadline
                )
            )
        );
    }

    /// `_feeSig` submitted by a stranger to `setBuilderFee`.
    function _setFee(HyperCoreLeg l, uint256 pk, address b, uint16 fee) internal {
        (bytes32 cred, uint256 deadline, bytes memory sig) = _feeSig(l, pk, b, fee);
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).setBuilderFee(b, fee, cred, deadline, sig);
    }

    /// `cancelBuilderFee`: the owner's `BuilderFee` naming what stands (the stored builder and rate).
    function _cancelFee(HyperCoreLeg l, uint256 pk) internal {
        (bytes32 cred, uint256 deadline, bytes memory sig) = _feeSig(l, pk, l.builder(), l.builderFeeX10());
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).cancelBuilderFee(cred, deadline, sig);
    }

    function _approve(HyperCoreLeg l) internal {
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).approveBuilder();
    }

    function _apply(HyperCoreLeg l) internal {
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).applyBuilderFee();
    }

    function _applyRefused(HyperCoreLeg l, bytes4 err) internal {
        vm.prank(stranger);
        vm.expectRevert(err);
        HyperCoreLegRoute(address(l)).applyBuilderFee();
    }

    /// Action `i` is CoreWriter 12, `b` approved at `rate`.
    function _assertApproval(uint256 i, address b, uint64 rate) internal view {
        (uint24 id, bytes memory body) = _action(i);
        assertEq(id, 12, "CoreWriter 12");
        (uint64 r, address named) = abi.decode(body, (uint64, address));
        assertEq(r, rate, "the rate");
        assertEq(named, b, "the builder");
    }

    /// CoreWriter 12s sent from action `from` on, and how many of them were nonzero.
    function _approvals(uint256 from) internal view returns (uint256 all, uint256 nonzero) {
        for (uint256 j = from; j < _count(); ++j) {
            (uint24 id, bytes memory body) = _action(j);
            if (id != 12) continue;
            all++;
            (uint64 r,) = abi.decode(body, (uint64, address));
            if (r != 0) nonzero++;
        }
    }

    function _assertPending(HyperCoreLeg l, address b, uint16 fee, uint64 at) internal view {
        assertEq(l.pendingBuilder(), b, "pending builder");
        assertEq(l.pendingBuilderFeeX10(), fee, "pending rate");
        assertEq(l.pendingBuilderAt(), at, "pending since");
    }

    /// 0 = nothing sent: creation sends no CoreWriter 12 and `approveBuilder()` at 0 does nothing; at a
    /// signed rate above 0, creation still sends none, and `approveBuilder()` sends exactly the signed pair.
    function test_builder_zeroSendsNothing() public {
        HyperCoreLeg l = _builderShort(Routes.AGENT, 0);
        (uint256 all,) = _approvals(0);
        assertEq(all, 0, "no 12 at creation");
        uint256 n = _count();
        _approve(l);
        assertEq(_count(), n, "approveBuilder at 0 is a no-op");

        HyperCoreLeg f = _builderShortAs(keccak256("fee"), Routes.AGENT, 20);
        (all,) = _approvals(n);
        assertEq(all, 0, "no 12 at creation, even above 0");
        n = _count();
        _approve(f);
        assertEq(_count(), n + 1);
        _assertApproval(n, B1, 20);
    }

    /// Lowering stores and sends at once; raising, or naming another builder, waits 24 hours, cancellable
    /// by any credential and void once its signer is removed; a builder change revokes the old one first.
    function test_builder_lowerAtOnce_raiseAfter24h() public {
        HyperCoreLeg l = _builderShort(Routes.AGENT, 10);
        _approve(l);

        // lower: at once, the new approval sent
        uint256 n = _count();
        _setFee(l, walletPk, B1, 5);
        assertEq(l.builderFeeX10(), 5);
        assertEq(_count(), n + 1);
        _assertApproval(n, B1, 5);
        _assertPending(l, address(0), 0, 0);

        // raise: pending, nothing sent, not before 24 h
        uint64 t0 = uint64(vm.getBlockTimestamp());
        n = _count();
        _setFee(l, walletPk, B1, 8);
        assertEq(l.builderFeeX10(), 5, "a raise waits");
        assertEq(_count(), n, "nothing sent");
        _assertPending(l, B1, 8, t0);
        vm.warp(t0 + 24 hours - 1);
        _applyRefused(l, HyperCoreLegState.TooEarly.selector);

        // cancelled by another credential: nothing left to apply
        _cancelFee(l, wallet2Pk);
        _assertPending(l, address(0), 0, 0);
        vm.warp(t0 + 48 hours);
        _applyRefused(l, MemberState.NotAllowed.selector);
        assertEq(l.builderFeeX10(), 5);

        // signed again: applied by anyone after 24 h, the approval sent
        uint64 t1 = uint64(vm.getBlockTimestamp());
        _setFee(l, walletPk, B1, 8);
        vm.warp(t1 + 24 hours);
        n = _count();
        _apply(l);
        assertEq(l.builderFeeX10(), 8);
        assertEq(_count(), n + 1);
        _assertApproval(n, B1, 8);
        _assertPending(l, address(0), 0, 0);

        // another builder, even at a lower rate, waits; applied, the old one is revoked first
        uint64 t2 = uint64(vm.getBlockTimestamp());
        _setFee(l, walletPk, B2, 3);
        assertEq(l.builder(), B1);
        _assertPending(l, B2, 3, t2);
        vm.warp(t2 + 24 hours);
        n = _count();
        _apply(l);
        assertEq(l.builder(), B2);
        assertEq(l.builderFeeX10(), 3);
        assertEq(_count(), n + 2);
        _assertApproval(n, B1, 0);
        _assertApproval(n + 1, B2, 3);

        // a raise whose signer is removed before it applies is void (M2)
        uint64 t3 = uint64(vm.getBlockTimestamp());
        _setFee(l, wallet2Pk, B2, 9);
        owner.setWallet(wallet2, false);
        vm.warp(t3 + 24 hours);
        _applyRefused(l, MemberState.NotAllowed.selector);
        assertEq(l.builderFeeX10(), 3);

        // an owner's lowering replaces whatever was pending
        _setFee(l, walletPk, B2, 2);
        assertEq(l.builderFeeX10(), 2);
        _assertPending(l, address(0), 0, 0);
    }

    /// Review Focus 5: a lowering signed before the exit and submitted in it. `_onExit` revoked the
    /// approval, set the rate to 0 and dropped the pending raise; the withheld message, now above the
    /// stored 0, is refused (nothing waits in the exit, nothing nonzero is sent); a 0 still applies.
    function test_builder_withheldLoweringAfterExit() public {
        HyperCoreLeg l = _builderShort(Routes.AGENT, 2);
        _approve(l);
        (bytes32 cred, uint256 deadline, bytes memory lowering) = _feeSig(l, walletPk, B1, 1);
        _setFee(l, wallet2Pk, B1, 3); // a raise pending
        _assertPending(l, B1, 3, uint64(vm.getBlockTimestamp()));

        uint256 n = _count();
        l.beginExit(deadline, _beginExitSig(deadline));
        assertTrue(l.exiting());
        assertEq(l.builderFeeX10(), 0, "the exit sets the rate to 0");
        _assertPending(l, address(0), 0, 0);
        _assertApproval(n, B1, 0); // the revocation, before the exit's burner
        (uint256 all, uint256 nonzero) = _approvals(n);
        assertEq(all, 1);
        assertEq(nonzero, 0);

        n = _count();
        vm.prank(stranger);
        vm.expectRevert(MemberState.Exiting.selector);
        HyperCoreLegRoute(address(l)).setBuilderFee(B1, 1, cred, deadline, lowering);
        assertEq(l.builderFeeX10(), 0);
        _assertPending(l, address(0), 0, 0);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _applyRefused(l, MemberState.Exiting.selector);
        _approve(l); // at 0: nothing
        (all, nonzero) = _approvals(n);
        assertEq(nonzero, 0, "nothing nonzero in the exit");
        assertEq(all, 0);

        // 0 is a revocation, allowed in every state
        _setFee(l, walletPk, B1, 0);
        assertEq(_count(), n + 1);
        _assertApproval(n, B1, 0);
    }

    /// On the contract route the fields may be signed but never approved: `approveBuilder()` reverts above
    /// 0, a lowering or a matured raise stores without a nonzero send. `USE_CONTRACT` revokes (12 at 0) and
    /// keeps the signed rate, for a switch back.
    function test_builder_contractRouteNeverApproves() public {
        HyperCoreLeg c = _builderShort(Routes.CONTRACT, 2);
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(c)).approveBuilder();
        uint256 n = _count();
        _setFee(c, walletPk, B1, 1);
        assertEq(c.builderFeeX10(), 1);
        assertEq(_count(), n, "a lowering stores, sends nothing");
        _setFee(c, walletPk, B1, 4);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _apply(c);
        assertEq(c.builderFeeX10(), 4);
        assertEq(_count(), n, "a raise applies, sends nothing");

        HyperCoreLeg a = _builderShortAs(keccak256("agent route"), Routes.AGENT, 2);
        _approve(a);
        n = _count();
        _act(a, OwnerMessages.USE_CONTRACT, address(0));
        assertEq(a.route(), Routes.CONTRACT);
        _assertApproval(n, B1, 0);
        (uint256 all, uint256 nonzero) = _approvals(n);
        assertEq(all, 1);
        assertEq(nonzero, 0);
        assertEq(a.builderFeeX10(), 2, "the signed rate stays");
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(a)).approveBuilder();
    }

    /// At most `MAX_BUILDER_FEE_X10` = 20 (2 bp), on the owner's message as at creation.
    function test_builder_capIs20() public {
        HyperCoreLeg l = _builderShort(Routes.AGENT, 0);
        (bytes32 cred, uint256 deadline, bytes memory sig) = _feeSig(l, walletPk, B1, 21);
        vm.prank(stranger);
        vm.expectRevert(HyperCoreLegState.BadParams.selector);
        HyperCoreLegRoute(address(l)).setBuilderFee(B1, 21, cred, deadline, sig);
        _setFee(l, walletPk, B1, 20);
        _assertPending(l, B1, 20, uint64(vm.getBlockTimestamp()));
    }

    /// The owner's message only: a signature over another rate, or reused, is refused.
    function test_builder_onlyTheOwnersMessage() public {
        HyperCoreLeg l = _builderShort(Routes.AGENT, 10);
        (bytes32 cred, uint256 deadline, bytes memory sig) = _feeSig(l, walletPk, B1, 5);
        vm.prank(key);
        vm.expectRevert(MemberState.BadSignature.selector);
        HyperCoreLegRoute(address(l)).setBuilderFee(B1, 4, cred, deadline, sig);
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).setBuilderFee(B1, 5, cred, deadline, sig);
        vm.prank(stranger);
        vm.expectRevert(MemberState.BadSignature.selector);
        HyperCoreLegRoute(address(l)).setBuilderFee(B1, 5, cred, deadline, sig); // its nonce is spent
    }

    /// `HyperCore._send2` widens each field to its word: the raw CoreWriter bytes of 7, 10, 11 and 12 are
    /// exactly `abi.encode` of their typed fields, as before the shared encoder.
    function test_coreWriter_twoWordActionsByteIdentical() public {
        HyperCoreLeg l = _builderShort(Routes.AGENT, 7);
        MockCoreWriter w = MockCoreWriter(CORE_WRITER);
        uint256 n = _count();
        _approve(l);
        assertEq(w.action(n).data, abi.encodePacked(uint8(1), bytes3(uint24(12)), abi.encode(uint64(7), B1)));
        vm.prank(key);
        l.cancel(5, false, 77);
        assertEq(w.action(n + 1).data, abi.encodePacked(uint8(1), bytes3(uint24(10)), abi.encode(uint32(5), uint64(77))));
        vm.prank(key);
        l.cancel(10_107, true, 0xC10D);
        assertEq(
            w.action(n + 2).data, abi.encodePacked(uint8(1), bytes3(uint24(11)), abi.encode(uint32(10_107), uint128(0xC10D)))
        );
        vm.prank(key);
        l.fromMargin(3e6);
        assertEq(w.action(n + 3).data, abi.encodePacked(uint8(1), bytes3(uint24(7)), abi.encode(uint64(3e6), false)));
    }

    // ── the referral setup agent (spec §16, Amendment A) ───────────────────────────────────────────────

    address constant SETUP = address(0x5E7);

    /// A BTC contract-route short whose owner signed `referralSetup`: a fresh account, flat, $5 of account
    /// value and 5 USDC of spot (both at the bound), HyperCore priced and at block 1,000.
    function _setupLeg() internal returns (HyperCoreLeg l) {
        return _setupLegAs(STRATEGY);
    }

    function _setupLegAs(bytes32 id) internal returns (HyperCoreLeg l) {
        core.setMaxLeverage(0, 40);
        StrategySpec memory c = _btcSpec();
        HyperCoreParams memory s = _routeParams();
        s.referralSetup = true;
        c.legs[1].params = abi.encode(s);
        l = HyperCoreLeg(payable(_createAs(id, c)[0]));
        core.setExists(address(l), true);
        core.setL1Block(1_000);
        core.setOracle(0, PX, 5);
        core.setMark(0, PX);
        core.setMargin(0, address(l), 5e6, 0, 0);
        core.setSpot(address(l), 0, 5e8);
    }

    function _beginExitSigAs(bytes32 id, uint256 deadline) internal view returns (bytes memory) {
        return _sign(walletPk, keccak256(abi.encode(OwnerMessages.BEGIN_EXIT_TYPEHASH, id, deadline)));
    }

    function _setup(HyperCoreLeg l, address a) internal {
        vm.prank(key);
        HyperCoreLegRoute(address(l)).setupAgent(a);
    }

    function _setupRefused(HyperCoreLeg l, address a, bytes4 err) internal {
        vm.prank(key);
        vm.expectRevert(err);
        HyperCoreLegRoute(address(l)).setupAgent(a);
    }

    function _endSetup(HyperCoreLeg l, address by) internal {
        vm.prank(by);
        HyperCoreLegRoute(address(l)).endSetup();
    }

    function _endSetupRefused(HyperCoreLeg l, address by, bytes4 err) internal {
        vm.prank(by);
        vm.expectRevert(err);
        HyperCoreLegRoute(address(l)).endSetup();
    }

    /// The agent is a fresh burner, just approved: not `before`, not the setup agent, not a sentinel.
    function _assertFreshBurner(HyperCoreLeg l, address before) internal view {
        address b = l.agent();
        assertTrue(b != before && b != SETUP && b != address(0) && b != address(1), "a fresh burner");
        assertTrue(l.burning());
        (uint24 id, address named) = _lastAction();
        assertEq(id, 9);
        assertEq(named, b);
    }

    function _toMargin(HyperCoreLeg l, uint256 amount) internal {
        MockERC20(HYPER_USDC).mint(address(l), amount);
        vm.prank(key);
        l.toMargin(amount);
    }

    function _toMarginRefused(HyperCoreLeg l, uint256 amount) internal {
        MockERC20(HYPER_USDC).mint(address(l), amount);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.SetupRefused.selector);
        l.toMargin(amount);
    }

    /// The owner's `CONFIRM_SETUP` naming the current agent (the burner the owner saw approved).
    function _confirm(HyperCoreLeg l) internal {
        _act(l, OwnerMessages.CONFIRM_SETUP, l.agent());
    }

    function _confirmRefused(HyperCoreLeg l, address named, bytes4 err) internal {
        bytes32 cred = walletCred(wallet);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(
            walletPk,
            keccak256(
                abi.encode(
                    OwnerMessages.VAULT_ACTION_TYPEHASH,
                    address(l),
                    block.chainid,
                    OwnerMessages.CONFIRM_SETUP,
                    named,
                    l.ownerNonceOf(cred),
                    deadline
                )
            )
        );
        vm.expectRevert(err);
        l.ownerAction(OwnerMessages.CONFIRM_SETUP, named, cred, deadline, sig);
    }

    function test_setup_refusedUnlessSignedOnceFlatAndSmall() public {
        // not signed
        HyperCoreLeg u = _routeLeg();
        core.setMargin(0, address(u), 5e6, 0, 0);
        _setupRefused(u, SETUP, HyperCoreLegState.SetupRefused.selector);
        // the agent route, signed
        HyperCoreLeg g = _agentShortAs(keccak256("agent route"));
        vm.store(address(g), bytes32(uint256(95)), bytes32(uint256(1))); // referralSetup (slot 95, offset 0)
        assertTrue(g.referralSetup());
        core.setMargin(0, address(g), 5e6, 0, 0);
        _setupRefused(g, SETUP, HyperCoreLegState.SetupRefused.selector);

        HyperCoreLeg l = _setupLegAs(keccak256("setup"));
        // only the key
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotExecution.selector);
        HyperCoreLegRoute(address(l)).setupAgent(SETUP);
        // never zero, never the burner's sentinel
        _setupRefused(l, address(0), HyperCoreLegState.SetupRefused.selector);
        _setupRefused(l, address(1), HyperCoreLegState.SetupRefused.selector);
        // not flat: any notional on DEX 0
        core.setMargin(0, address(l), 5e6, 0, 1);
        _setupRefused(l, SETUP, HyperCoreLegState.SetupRefused.selector);
        // over $5 of account value
        core.setMargin(0, address(l), 5e6 + 1, 0, 0);
        _setupRefused(l, SETUP, HyperCoreLegState.SetupRefused.selector);
        // over 5 USDC of spot
        core.setMargin(0, address(l), 5e6, 0, 0);
        core.setSpot(address(l), 0, 5e8 + 1);
        _setupRefused(l, SETUP, HyperCoreLegState.SetupRefused.selector);
        // DEX 0 unreadable
        core.setSpot(address(l), 0, 5e8);
        core.setDexRefused(0, true);
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(HyperCore.PrecompileFailed.selector, HyperCore.PX_MARGIN_SUMMARY));
        HyperCoreLegRoute(address(l)).setupAgent(SETUP);
        core.setDexRefused(0, false);
        // at the bounds: allowed, once
        _setup(l, SETUP);
        assertTrue(l.setupDone());
        _setupRefused(l, address(0x5E8), HyperCoreLegState.SetupRefused.selector);
        // ... and never again after it ended
        _endSetup(l, key);
        vm.roll(vm.getBlockNumber() + 100);
        _setupRefused(l, address(0x5E8), HyperCoreLegState.SetupRefused.selector);
        // in the exit, no setup: the key is out
        HyperCoreLeg x = _setupLegAs(keccak256("exit"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        x.beginExit(deadline, _beginExitSigAs(keccak256("exit"), deadline));
        _setupRefused(x, SETUP, MemberState.Exiting.selector);
    }

    function test_setup_approvesThenBlocksMoneyIn() public {
        HyperCoreLeg l = _setupLeg();
        uint256 t0 = vm.getBlockTimestamp();
        uint256 n = _count();
        vm.expectEmit(address(l));
        emit HyperCoreLegState.AgentSet(SETUP);
        vm.expectEmit(address(l));
        emit HyperCoreLegState.SetupAgent(SETUP, t0 + 1 hours);
        _setup(l, SETUP);
        // one action: CoreWriter 9, the setup agent under the agent's name
        assertEq(_count(), n + 1);
        (uint24 id, address named) = _lastAction();
        assertEq(id, 9);
        assertEq(named, SETUP);
        assertEq(l.agent(), SETUP);
        assertFalse(l.burning());
        assertTrue(l.setupDone());
        assertTrue(l.setupOpen());
        assertEq(l.setupUntil(), t0 + 1 hours);
        // while it stands: no money joins the account, no growth, even past the hour
        core.setMargin(0, address(l), EQUITY, 0, 0); // room for growth, were it allowed
        MockERC20(HYPER_USDC).mint(address(l), 50e6);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.SetupRefused.selector);
        l.toMargin(50e6);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.SetupRefused.selector);
        vm.warp(t0 + 2 hours);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.SetupRefused.selector);
        l.toMargin(50e6);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.SetupRefused.selector);
        // a reduction is never refused: protection can always shrink the hedge
        _position(l, -1_000, EQUITY);
        _order(l, true, 1_000, true);
        (,,,, bool ro,,) = _sent();
        assertTrue(ro);
    }

    function test_setup_endByKeyOrAnyoneAfterAnHour() public {
        HyperCoreLeg l = _setupLeg();
        uint256 t0 = vm.getBlockTimestamp();
        _setup(l, SETUP);
        // the key, at once
        uint256 snap = vm.snapshotState();
        vm.expectEmit(address(l));
        emit HyperCoreLegState.SetupEnded();
        _endSetup(l, key);
        _assertFreshBurner(l, SETUP);
        assertFalse(l.setupOpen());
        assertEq(l.setupUntil(), t0 + 1 hours); // kept: a stranger's retry waits for it
        _confirm(l); // the owner's reading (spec §16): money only after it
        _toMargin(l, 50e6);
        assertEq(MockCoreDepositWallet(CDW).lastAmount(), 50e6);
        core.setMargin(0, address(l), EQUITY, 0, 0);
        _grow(l, 1_000);
        (,,,, bool ro,,) = _sent();
        assertFalse(ro);
        vm.revertToState(snap);
        // a stranger: not before the hour
        _endSetupRefused(l, stranger, MemberState.NotExecution.selector);
        vm.warp(t0 + 1 hours - 1);
        _endSetupRefused(l, stranger, MemberState.NotExecution.selector);
        assertTrue(l.setupOpen());
        // ... and from the hour on
        vm.warp(t0 + 1 hours);
        vm.expectEmit(address(l));
        emit HyperCoreLegState.SetupEnded();
        _endSetup(l, stranger);
        _assertFreshBurner(l, SETUP);
        assertFalse(l.setupOpen());
        _confirm(l);
        _toMargin(l, 50e6);
        assertEq(MockCoreDepositWallet(CDW).lastAmount(), 50e6);
        // nothing to end before a setup ran
        HyperCoreLeg f = _setupLegAs(keccak256("fresh"));
        _endSetupRefused(f, key, HyperCoreLegState.SetupRefused.selector);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _endSetupRefused(f, stranger, HyperCoreLegState.SetupRefused.selector);
    }

    function test_setup_endIsRepeatableAndPaced() public {
        HyperCoreLeg l = _setupLeg();
        uint256 t0 = vm.getBlockTimestamp();
        _setup(l, SETUP);
        _endSetup(l, key);
        address first = l.agent();
        uint256 b0 = vm.getBlockNumber();
        // the key's retry: paced 20 blocks
        _endSetupRefused(l, key, HyperCoreLegState.TooEarly.selector);
        vm.roll(b0 + 19);
        _endSetupRefused(l, key, HyperCoreLegState.TooEarly.selector);
        vm.roll(b0 + 20);
        vm.expectEmit(address(l));
        emit HyperCoreLegState.SetupEnded();
        _endSetup(l, key);
        _assertFreshBurner(l, first);
        address second = l.agent();
        // after the end a retry is the key's alone, even past the hour: a stranger's would rotate the burner
        // the owner's `CONFIRM_SETUP` must name, and starve it
        vm.roll(b0 + 40);
        _endSetupRefused(l, stranger, MemberState.NotExecution.selector);
        vm.warp(t0 + 1 hours);
        _endSetupRefused(l, stranger, MemberState.NotExecution.selector);
        assertEq(l.agent(), second);
        _endSetup(l, key);
        _assertFreshBurner(l, second);
        address third = l.agent();
        _endSetupRefused(l, key, HyperCoreLegState.TooEarly.selector);
        vm.roll(b0 + 59);
        _endSetupRefused(l, key, HyperCoreLegState.TooEarly.selector);
        vm.roll(b0 + 60);
        _endSetup(l, key);
        _assertFreshBurner(l, third);
        assertFalse(l.setupOpen());
        assertEq(l.route(), Routes.CONTRACT);
        assertFalse(l.quarantine());
    }

    /// The owner's burner and the exit replace the setup agent as `endSetup` does, and end its standing; a
    /// later `endSetup` only approves another burner (outside the exit, where it is refused).
    function test_setup_ownerBurnerAndExitEndIt() public {
        HyperCoreLeg l = _setupLeg();
        _setup(l, SETUP);
        uint256 snap = vm.snapshotState();
        // REPLACE_AGENT(burner), the owner who doesn't wait on DLTX
        _act(l, OwnerMessages.REPLACE_AGENT, address(1));
        _assertFreshBurner(l, SETUP);
        assertFalse(l.setupOpen());
        assertFalse(l.quarantine());
        _toMarginRefused(l, 50e6); // ended, not confirmed
        _confirm(l);
        _toMargin(l, 50e6);
        address owners = l.agent();
        _endSetup(l, key); // harmless: another burner, the confirm stands
        _assertFreshBurner(l, owners);
        assertFalse(l.setupOpen());
        assertTrue(l.setupConfirmed());
        vm.revertToState(snap);
        // USE_CONTRACT on the contract route: the owner's "cut it now" cuts a standing setup agent too
        // (`test_setup_useContractCutsTheSetupAgent`)
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        _assertFreshBurner(l, SETUP);
        assertFalse(l.setupOpen());
        vm.revertToState(snap);
        // the exit: a burner at once, the standing ended; endSetup refused there
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        l.beginExit(deadline, _beginExitSig(deadline));
        _assertFreshBurner(l, SETUP);
        assertEq(l.exitAgent(), l.agent());
        assertFalse(l.setupOpen());
        address exitBurner = l.agent();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 100);
        _endSetupRefused(l, key, MemberState.Exiting.selector);
        _endSetupRefused(l, stranger, MemberState.Exiting.selector);
        assertEq(l.agent(), exitBurner);
    }

    /// Off the contract route, or in quarantine, no setup and no `endSetup`: a stranger's retry must never
    /// replace an agent the owner chose, nor move the burner an `END_QUARANTINE` names.
    function test_setup_onlyOnTheContractRouteOutOfQuarantine() public {
        HyperCoreLeg l = _setupLeg();
        _setup(l, SETUP);
        // the owner's switch back to the agent route, after 24 hours, ends the standing
        _act(l, OwnerMessages.REPLACE_AGENT, address(0xC0C));
        assertTrue(l.setupOpen());
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        HyperCoreLegExit(address(l)).applyOwnerAgent();
        assertEq(l.route(), Routes.AGENT);
        assertEq(l.agent(), address(0xC0C));
        assertFalse(l.setupOpen());
        // on the agent route no confirm (the claim is the contract route's): money joins, the confirm is refused
        _toMargin(l, 50e6);
        _confirmRefused(l, address(0xC0C), HyperCoreLegState.SetupRefused.selector);
        vm.roll(vm.getBlockNumber() + 100);
        _endSetupRefused(l, stranger, HyperCoreLegState.SetupRefused.selector);
        _endSetupRefused(l, key, HyperCoreLegState.SetupRefused.selector);
        assertEq(l.agent(), address(0xC0C));
        // back to the contract route: in quarantine, neither runs
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertTrue(l.quarantine());
        address burner = l.agent();
        vm.roll(vm.getBlockNumber() + 100);
        _endSetupRefused(l, stranger, HyperCoreLegState.Quarantined.selector);
        _endSetupRefused(l, key, HyperCoreLegState.Quarantined.selector);
        assertEq(l.agent(), burner);
        // ... and back on the contract route, the unconfirmed setup holds money again until the owner's confirm
        _toMarginRefused(l, 50e6);
        _confirm(l);
        assertTrue(l.quarantine()); // the confirm is not END_QUARANTINE's
        _toMargin(l, 50e6);
        // a signed, never-run setup on a switched strategy: refused in quarantine
        HyperCoreLeg g = _agentShortAs(keccak256("switched"));
        vm.store(address(g), bytes32(uint256(95)), bytes32(uint256(1))); // referralSetup
        _act(g, OwnerMessages.USE_CONTRACT, address(0));
        assertTrue(g.quarantine());
        core.setMargin(0, address(g), 5e6, 0, 0);
        _setupRefused(g, SETUP, HyperCoreLegState.SetupRefused.selector);
    }

    // ── the owner confirms the setup before any money (spec §16, the operator's option C) ─────────────

    /// After the setup ends, `toMargin` and growth wait for the owner's `CONFIRM_SETUP`, however long and
    /// however many burners later; a reduction never waits. The confirm, once, releases both.
    function test_confirm_moneyHeldUntilOwnerConfirms() public {
        HyperCoreLeg l = _setupLeg();
        _setup(l, SETUP);
        _endSetup(l, key);
        assertFalse(l.setupOpen());
        assertFalse(l.setupConfirmed());
        core.setMargin(0, address(l), EQUITY, 0, 0); // room for growth, were it allowed
        _toMarginRefused(l, 50e6);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.SetupRefused.selector);
        // hours later, after the key's retry: still held
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 100);
        _endSetup(l, key);
        _toMarginRefused(l, 50e6);
        _refusedOrder(l, false, 1_000, false, HyperCoreLegState.SetupRefused.selector);
        // a reduction is never refused
        _position(l, -1_000, EQUITY);
        _order(l, true, 1_000, true);
        (,,,, bool ro,,) = _sent();
        assertTrue(ro);
        // the owner's confirm, naming the burner now approved, the account reading clean
        address burner = l.agent();
        vm.expectEmit(address(l));
        emit HyperCoreLegState.SetupConfirmed();
        _confirm(l);
        assertTrue(l.setupConfirmed());
        assertTrue(l.setupDone());
        assertEq(l.agent(), burner);
        assertEq(l.route(), Routes.CONTRACT);
        // money and growth now go
        _toMargin(l, 50e6);
        assertEq(MockCoreDepositWallet(CDW).lastAmount(), 50e6);
        _grow(l, 1_000);
        (,,,, ro,,) = _sent();
        assertFalse(ro);
    }

    function test_confirm_refusals() public {
        // the setup never ran (signed, not run)
        HyperCoreLeg f = _setupLegAs(keccak256("fresh"));
        _confirmRefused(f, f.agent(), HyperCoreLegState.SetupRefused.selector);
        _confirmRefused(f, address(0), HyperCoreLegState.SetupRefused.selector);
        // not signed at all
        HyperCoreLeg u = _routeLeg();
        _confirmRefused(u, u.agent(), HyperCoreLegState.SetupRefused.selector);

        HyperCoreLeg l = _setupLegAs(keccak256("confirm"));
        _setup(l, SETUP);
        // the setup agent still stands, even past its hour
        _confirmRefused(l, SETUP, HyperCoreLegState.SetupRefused.selector);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _confirmRefused(l, SETUP, HyperCoreLegState.SetupRefused.selector);
        _endSetup(l, key);
        address first = l.agent();
        // the `agent` field names the current burner: not the setup agent, not zero, not the sentinel
        _confirmRefused(l, SETUP, MemberState.NotAllowed.selector);
        _confirmRefused(l, address(0), MemberState.NotAllowed.selector);
        _confirmRefused(l, address(1), MemberState.NotAllowed.selector);
        // ... nor an older burner, once a retry replaced it
        vm.roll(vm.getBlockNumber() + 20);
        _endSetup(l, key);
        address burner = l.agent();
        assertTrue(burner != first);
        _confirmRefused(l, first, MemberState.NotAllowed.selector);
        // the leg's own reads: the perp isolated
        uint64 own = 1_000 * PX;
        core.setPosition(address(l), 0, -1_000);
        core.setMargin(0, address(l), EQUITY, 0, own);
        core.setIsolated(address(l), 0, true);
        _confirmRefused(l, burner, MemberState.NotAllowed.selector);
        core.setIsolated(address(l), 0, false);
        // ... a stray DEX 0 position (notional beyond the perp's by more than a step)
        core.setMargin(0, address(l), EQUITY, 0, own + PX + 1);
        _confirmRefused(l, burner, MemberState.NotAllowed.selector);
        // ... DEX 0 unreadable
        core.setMargin(0, address(l), EQUITY, 0, own);
        core.setDexRefused(0, true);
        _confirmRefused(l, burner, MemberState.NotAllowed.selector);
        core.setDexRefused(0, false);
        // the route module's check runs only as the leg's own call, after the owner's signature: never
        // called directly, by the key or anyone, even naming the burner
        vm.prank(key);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(l)).routeOwnerAction(OwnerMessages.CONFIRM_SETUP, burner);
        vm.prank(stranger);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegRoute(address(l)).routeOwnerAction(OwnerMessages.CONFIRM_SETUP, burner);
        // clean: confirmed, once
        _act(l, OwnerMessages.CONFIRM_SETUP, burner);
        assertTrue(l.setupConfirmed());
        _confirmRefused(l, burner, HyperCoreLegState.SetupRefused.selector);
        // on the agent route: the owner's switch back, after a setup that ran
        HyperCoreLeg g = _setupLegAs(keccak256("switched back"));
        _setup(g, SETUP);
        _act(g, OwnerMessages.REPLACE_AGENT, address(0xC0C));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        HyperCoreLegExit(address(g)).applyOwnerAgent();
        assertEq(g.route(), Routes.AGENT);
        assertTrue(g.setupDone());
        assertFalse(g.setupOpen());
        _confirmRefused(g, address(0xC0C), HyperCoreLegState.SetupRefused.selector);
        assertFalse(g.setupConfirmed());
    }

    /// No setup, no confirm: with `referralSetup` false, or signed but never run, money and growth go as
    /// before; once money of size has joined, the setup can't run any more.
    function test_confirm_noSetupNoConfirmNeeded() public {
        HyperCoreLeg u = _routeLeg();
        _toMargin(u, 50e6);
        assertEq(MockCoreDepositWallet(CDW).lastAmount(), 50e6);
        _grow(u, 1_000);
        (,,,, bool ro,,) = _sent();
        assertFalse(ro);
        // signed, never run
        HyperCoreLeg l = _setupLegAs(keccak256("never run"));
        _toMargin(l, 60e6);
        assertEq(MockCoreDepositWallet(CDW).lastAmount(), 60e6);
        core.setMargin(0, address(l), EQUITY, 0, 0); // the deposit landed
        _grow(l, 1_000);
        (,,,, ro,,) = _sent();
        assertFalse(ro);
        assertFalse(l.setupConfirmed());
        // over $5 now: the setup is refused for good
        core.setPosition(address(l), 0, 0);
        core.setMargin(0, address(l), EQUITY, 0, 0);
        _setupRefused(l, SETUP, HyperCoreLegState.SetupRefused.selector);
        core.setMargin(0, address(l), 5e6, 0, 0);
        core.setSpot(address(l), 0, 60e8); // or landed on spot
        _setupRefused(l, SETUP, HyperCoreLegState.SetupRefused.selector);
        assertFalse(l.setupDone());
    }

    /// No HYPE joins the account while the setup agent stands (it could trade it); once it ended, the key
    /// tops up again (HYPE pays the sends, spec §5), and in the exit anyone does.
    function test_setup_topUpHypeRefusedWhileOpen() public {
        HyperCoreLeg l = _setupLeg();
        vm.deal(address(l), 1 ether);
        _setup(l, SETUP);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.SetupRefused.selector);
        l.topUpHype(1e17);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.SetupRefused.selector);
        l.topUpHype(1e17);
        uint256 snap = vm.snapshotState();
        // ended, not confirmed: still refused (a spot TWAP the setup agent left could trade it); the
        // confirm itself sends nothing, so it needs no HYPE
        _endSetup(l, key);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.SetupRefused.selector);
        l.topUpHype(1e17);
        _confirm(l);
        vm.prank(key);
        l.topUpHype(1e17);
        assertEq(address(l).balance, 9e17);
        vm.revertToState(snap);
        // the exit ends the setup agent's standing and the hold: anyone tops up, the setup unconfirmed
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        l.beginExit(deadline, _beginExitSig(deadline));
        assertFalse(l.setupConfirmed());
        vm.prank(stranger);
        l.topUpHype(1e17);
        assertEq(address(l).balance, 9e17);
    }

    /// A stranger may end only a STANDING setup (after the hour); once it ended, nobody but the key (or
    /// the owner's `REPLACE_AGENT(BURNER)`) names another burner, so no one can starve the owner's confirm,
    /// even with the key revoked.
    function test_confirm_noStrangerCanStarveIt() public {
        HyperCoreLeg l = _setupLeg();
        uint256 t0 = vm.getBlockTimestamp();
        _setup(l, SETUP);
        _endSetup(l, key);
        address burner = l.agent();
        // the owner revokes the key; past the hour, many blocks later, a stranger still can't rotate the burner
        _act(l, OwnerMessages.REVOKE_EXECUTION, address(0));
        vm.warp(t0 + 3 hours);
        for (uint256 i; i < 3; ++i) {
            vm.roll(vm.getBlockNumber() + 25);
            _endSetupRefused(l, stranger, MemberState.NotAllowed.selector); // the key's check: revoked first
            _endSetupRefused(l, key, MemberState.NotAllowed.selector);
        }
        assertEq(l.agent(), burner);
        // the owner's confirm, naming the burner they read on Hyperliquid's API, lands
        vm.expectEmit(address(l));
        emit HyperCoreLegState.SetupConfirmed();
        _act(l, OwnerMessages.CONFIRM_SETUP, burner);
        assertTrue(l.setupConfirmed());
    }

    /// A stranger's `endSetup` after the end reverts, at any time; before the end, after the hour, it ends
    /// the standing setup (`test_setup_endByKeyOrAnyoneAfterAnHour`).
    function test_setup_strangerCantRetryAfterTheEnd() public {
        HyperCoreLeg l = _setupLeg();
        uint256 t0 = vm.getBlockTimestamp();
        _setup(l, SETUP);
        vm.warp(t0 + 1 hours);
        _endSetup(l, stranger); // the standing setup, after the hour: anyone
        address burner = l.agent();
        vm.roll(vm.getBlockNumber() + 25);
        _endSetupRefused(l, stranger, MemberState.NotExecution.selector);
        vm.warp(t0 + 30 days);
        vm.roll(vm.getBlockNumber() + 1_000);
        _endSetupRefused(l, stranger, MemberState.NotExecution.selector);
        assertEq(l.agent(), burner);
        _endSetup(l, key); // the key's retry still runs
        _assertFreshBurner(l, burner);
    }

    /// The setup runs only on an account HyperCore knows: an approval on a missing account is dropped,
    /// and the one-time setup would be spent for nothing.
    function test_setup_requiresCoreAccount() public {
        HyperCoreLeg l = _setupLeg();
        core.setExists(address(l), false);
        _setupRefused(l, SETUP, HyperCoreLegState.NoCoreAccount.selector);
        assertFalse(l.setupDone());
        core.setExists(address(l), true);
        _setup(l, SETUP);
        assertTrue(l.setupOpen());
    }

    /// `referralSetup` is signed only on the contract route: on the agent route the engine's agent sets the
    /// referrer itself (spec §16), and a signed flag there would hold money behind a confirm it refuses.
    function test_params_referralSetupOnlyOnContractRoute() public {
        core.setMaxLeverage(0, 40);
        HyperCoreParams memory s = _routeParams();
        s.referralSetup = true;
        _valid(s);
        s.route = Routes.AGENT;
        _refused(s);
        s.referralSetup = false;
        _valid(s);
    }

    // ── the final review's fixes (2026-10-28) ────────────────────────────────────────────────────────

    /// The leg's `setupIn` (internal): slot 95, offset 12 (layouts/HyperCoreLeg.txt).
    function _setupIn(address l) internal view returns (uint64) {
        return uint64(uint256(vm.load(l, bytes32(uint256(95)))) >> 96);
    }

    /// C1: a Circle deposit sent in the setup's own HyperEVM block is not yet in HyperCore's reads (the
    /// mock's CoreDepositWallet never credits them, as HyperCore before it applies the deposit): the leg
    /// counts every `toMargin` before the setup ran, and refuses the setup past $5 of it.
    function test_setup_inFlightDepositRefusesTheSetup() public {
        HyperCoreLeg l = _setupLeg();
        uint256 blockNo = vm.getBlockNumber();
        _toMargin(l, 1_000_000e6);
        assertEq(MockCoreDepositWallet(CDW).lastAmount(), 1_000_000e6);
        // the same block: HyperCore still reads the $5 account, the leg does not
        _setupRefused(l, address(0xBAD), HyperCoreLegState.SetupRefused.selector);
        assertEq(vm.getBlockNumber(), blockNo, "one block");
        assertFalse(l.setupDone());
        assertFalse(l.setupOpen());
        // ... nor later, the deposit landed or not: the count stays
        vm.roll(vm.getBlockNumber() + 100);
        _setupRefused(l, address(0xBAD), HyperCoreLegState.SetupRefused.selector);
        // a dollar over $5, in two deposits, is refused too
        HyperCoreLeg m = _setupLegAs(keccak256("two deposits"));
        _toMargin(m, 3e6);
        _toMargin(m, 2e6 + 1);
        assertEq(_setupIn(address(m)), 5e6 + 1);
        _setupRefused(m, SETUP, HyperCoreLegState.SetupRefused.selector);
    }

    /// The setup's in-flight count is CHECKED: near 2^64 a further deposit reverts rather than wrapping the
    /// count back under $5 (which would reopen the referral setup's in-flight bypass).
    function test_setup_inFlightCountDoesNotWrap() public {
        HyperCoreLeg l = _setupLeg();
        uint256 w = uint256(vm.load(address(l), bytes32(uint256(95))));
        uint256 mask = uint256(type(uint64).max) << 96;
        vm.store(address(l), bytes32(uint256(95)), bytes32((w & ~mask) | (uint256(type(uint64).max - 1e6) << 96)));
        assertEq(_setupIn(address(l)), type(uint64).max - 1e6);
        MockERC20(HYPER_USDC).mint(address(l), 2e6);
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // checked arithmetic
        l.toMargin(2e6);
        assertEq(_setupIn(address(l)), type(uint64).max - 1e6, "unchanged");
    }

    /// C1: the honest $5 creation deposit, in one or several sends, still lets the setup run; after it,
    /// nothing more is counted.
    function test_setup_creationDepositStillAllowsIt() public {
        HyperCoreLeg l = _setupLeg();
        _toMargin(l, 3e6);
        _toMargin(l, 2e6);
        assertEq(_setupIn(address(l)), 5e6);
        _setup(l, SETUP);
        assertTrue(l.setupOpen());
        _endSetup(l, key);
        _confirm(l);
        _toMargin(l, 50e6);
        assertEq(_setupIn(address(l)), 5e6, "counted only before the setup ran");
    }

    /// M1: on the contract route `USE_CONTRACT` is the owner's "cut it now": with the setup agent standing it
    /// names a fresh burner at once (ending the standing), and drops the pending choices as before; with no
    /// setup agent standing it names no agent.
    function test_setup_useContractCutsTheSetupAgent() public {
        HyperCoreLeg l = _setupLeg();
        _setup(l, SETUP);
        _act(l, OwnerMessages.REPLACE_AGENT, address(0xC0C)); // a pending switch back
        assertEq(l.ownerAgent(), address(0xC0C));
        uint256 n = _count();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertEq(_count(), n + 1, "one action: the burner");
        _assertFreshBurner(l, SETUP);
        assertFalse(l.setupOpen());
        assertEq(l.ownerAgent(), address(0), "the pending choice dropped");
        assertEq(l.route(), Routes.CONTRACT);
        assertFalse(l.quarantine());
        // the hold stands until the owner's confirm
        _toMarginRefused(l, 50e6);
        _confirm(l);
        _toMargin(l, 50e6);
        // again, with nothing standing: no agent named
        address burner = l.agent();
        n = _count();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertEq(_count(), n);
        assertEq(l.agent(), burner);
    }

    /// The partner's audit M2 on the contract route's only way back to an agent: the owner's switch back
    /// (`REPLACE_AGENT(agent)`), signed by a credential removed before it applies, is void; the route, the
    /// burner and the quarantine's state stay.
    function test_route_switchBackVoidedWhenItsSignerIsRemoved() public {
        HyperCoreLeg l = HyperCoreLeg(payable(_contractShort()));
        bytes32 cred = walletCred(wallet2);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(
            wallet2Pk,
            keccak256(
                abi.encode(
                    OwnerMessages.VAULT_ACTION_TYPEHASH, address(l), block.chainid, OwnerMessages.REPLACE_AGENT,
                    address(0xA77), l.ownerNonceOf(cred), deadline
                )
            )
        );
        l.ownerAction(OwnerMessages.REPLACE_AGENT, address(0xA77), cred, deadline, sig);
        assertEq(l.ownerAgent(), address(0xA77));
        address before = l.agent();
        owner.setWallet(wallet2, false);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(MemberState.NotAllowed.selector);
        HyperCoreLegExit(address(l)).applyOwnerAgent();
        assertEq(l.route(), Routes.CONTRACT);
        assertEq(l.agent(), before);
        // the same switch back by a credential that still stands applies
        _act(l, OwnerMessages.REPLACE_AGENT, address(0xA77));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        HyperCoreLegExit(address(l)).applyOwnerAgent();
        assertEq(l.route(), Routes.AGENT);
        assertEq(l.agent(), address(0xA77));
    }

    /// I2: a stranger's cancels are at most 50 a call and NOT paced: a shared pace would let anyone (a
    /// compromised server too) starve the owner's quarantine cancels. The key's own `cancel` is not paced.
    function test_cancelResting_cappedNotPaced() public {
        HyperCoreLeg l = _routeLeg();
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).cancelResting(_cancels());
        uint256 n = _count();
        // again in the same block, by anyone: sent
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).cancelResting(_cancels());
        assertEq(_count(), n + _cancels().length);
        vm.prank(key);
        HyperCoreLegRoute(address(l)).cancelResting(_cancels());
        assertEq(_count(), n + 2 * _cancels().length);
        n = _count();
        vm.prank(key);
        l.cancel(0, false, 78);
        assertEq(_count(), n + 1);
        // at most 50 cancels a call
        HyperCoreLegState.Cancel[] memory many = new HyperCoreLegState.Cancel[](51);
        vm.prank(stranger);
        vm.expectRevert(HyperCoreLegState.BadParams.selector);
        HyperCoreLegRoute(address(l)).cancelResting(many);
        HyperCoreLegState.Cancel[] memory fifty = new HyperCoreLegState.Cancel[](50);
        vm.prank(stranger);
        HyperCoreLegRoute(address(l)).cancelResting(fifty);
        assertEq(_count(), n + 1 + 50);
    }

    /// I2: anyone's `approveBuilder` is paced 20 blocks; at 0 it sends nothing, so it isn't.
    function test_builder_approvePaced() public {
        HyperCoreLeg l = _builderShort(Routes.AGENT, 10);
        _approve(l);
        uint256 n = _count();
        vm.roll(vm.getBlockNumber() + 19);
        vm.prank(stranger);
        vm.expectRevert(HyperCoreLegState.TooEarly.selector);
        HyperCoreLegRoute(address(l)).approveBuilder();
        assertEq(_count(), n);
        vm.roll(vm.getBlockNumber() + 1);
        _approve(l);
        assertEq(_count(), n + 1);
        _assertApproval(n, address(0xB1), 10);
        // at 0: nothing sent, nothing paced
        HyperCoreLeg z = _builderShortAs(keccak256("zero"), Routes.AGENT, 0);
        n = _count();
        _approve(z);
        _approve(z);
        assertEq(_count(), n);
    }

    // ── before broadcast (the final review's hardenings) ────────────────────────────────────────────

    /// The long side is refused on both routes until a pair uses it: its growth is untested.
    function test_params_longSideRefused() public {
        core.setMaxLeverage(0, 40);
        HyperCoreParams memory s = _routeParams();
        s.side = Sides.LONG;
        _refused(s);
        s.route = Routes.AGENT;
        _refused(s);
        s.side = Sides.SHORT;
        _valid(s);
    }

    /// A builder fee names a builder: 0 with a rate above 0 is refused at creation and in the owner's
    /// `BuilderFee`; 0 at 0 (no builder) stays valid.
    function test_builder_zeroAddressNeedsZeroRate() public {
        core.setMaxLeverage(0, 40);
        HyperCoreParams memory s = _routeParams();
        s.builder = address(0);
        s.builderFeeX10 = 1;
        _refused(s);
        s.builderFeeX10 = 0;
        _valid(s);
        // the owner's message: a raise naming no builder is refused, a cancel to 0 is not
        HyperCoreLeg l = _builderShort(Routes.AGENT, 10);
        (bytes32 cred, uint256 deadline, bytes memory sig) = _feeSig(l, walletPk, address(0), 5);
        vm.prank(stranger);
        vm.expectRevert(HyperCoreLegState.BadParams.selector);
        HyperCoreLegRoute(address(l)).setBuilderFee(address(0), 5, cred, deadline, sig);
        _setFee(l, walletPk, address(0), 0);
        assertEq(l.pendingBuilder(), address(0));
    }

    /// `perpAssetInfo`'s answer is a tuple with a string: its first word is the offset 0x20. An answer
    /// that doesn't start so is not read by position: the perp counts as unpriced (no order, `BadAsset`).
    function test_hardening_tryPerpInfoChecksTheOffset() public {
        HyperCoreLeg l = _agentShort();
        core.setMark(0, core.oracle(0));
        bytes memory good = abi.encode(CoreState.PerpAssetInfo("BTC", 0, core.szDecimals(0), 40, false));
        bytes memory bad = abi.encode(CoreState.PerpAssetInfo("BTC", 0, core.szDecimals(0), 40, false));
        assembly ("memory-safe") {
            mstore(add(bad, 32), 0x40)
        }
        vm.mockCall(address(0x80a), abi.encode(uint32(0)), good);
        vm.prank(key);
        HyperCoreLegRoute(address(l)).order(true, 1_000 * STEP, true, 5);
        vm.mockCall(address(0x80a), abi.encode(uint32(0)), bad);
        vm.prank(key);
        vm.expectRevert(HyperCoreLegState.BadAsset.selector);
        HyperCoreLegRoute(address(l)).order(true, 1_000 * STEP, true, 6);
        vm.clearMockedCalls();
    }

    /// `spotAvailable` saturates: a hold read above the total is nothing available, not a revert, on the
    /// contract route's `fromMargin` (the whole amount then comes from margin, under the cap).
    function test_hardening_spotAvailableSaturates() public {
        HyperCoreLeg l = _routeLeg();
        core.setSpot(address(l), 0, 10e8);
        core.setHold(address(l), 0, 20e8);
        uint256 n = _count();
        _release(l, 100e6);
        assertEq(_count(), n + 2);
        _assertToSpot(n, 100e6);
        _assertToEvm(n + 1, 100e8);
    }
}
