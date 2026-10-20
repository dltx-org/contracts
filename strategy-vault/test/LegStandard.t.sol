// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {walletCred} from "./mocks/Mocks.sol";

import {Fixture} from "./utils/Fixture.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {ILeg} from "../src/interfaces/ILeg.sol";
import {LegConfig, Legs, OwnerMessages, ParamsTypes, StrategyConfig} from "../src/lib/VaultTypes.sol";
import {TestLeg, TestLegExit} from "./mocks/TestLeg.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";

/*
 * THE MEMBER STANDARD'S SHARED SUITE (amendment 2a, revision 1, §3.5, §9): written once, run against every
 * member type — the hub, the AAVE leg, the Hyperliquid leg, the test-only leg — through a one-function
 * adapter (`_member`: a fresh member, created by a combination factory, with at least one link on another
 * chain). What every member must keep, whatever it is: one-time initialisation, its self-description (a
 * leg's), the owner's actions (replay, another member's, expiry), revoke, pause's scope, the three entries
 * into the exit and its one-way state. Each type's own functions are its suite (`StrategyHub.t.sol`,
 * `ShortVault.t.sol`, the fork suites); between members, `Links.t.sol`; sizes, `test.mjs`.
 */
abstract contract LegStandardSuite is Fixture {
    VaultBase leg;
    uint8 remote; // a link on another chain

    function _member() internal virtual returns (VaultBase);

    function setUp() public virtual {
        _world();
        leg = _member();
        while (leg.localLinks() & (1 << remote) != 0) ++remote;
        assertTrue(remote < leg.linkCount(), "every adapter's member has a link elsewhere");
    }

    function _action(uint8 action, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        return _actionSig(address(leg), action, address(0), nonce, deadline);
    }

    function _index() internal view returns (uint8 index) {
        (,,, index) = CombinationFactory(leg.factory()).memberOf(address(leg));
    }

    function test_std_initializedOnce_byItsFactory() public {
        (address o, bytes32 id,,) = CombinationFactory(leg.factory()).memberOf(address(leg));
        assertEq(o, address(owner), "its factory made it, for this owner");
        assertEq(id, STRATEGY);
        assertEq(leg.owner(), address(owner));
        assertEq(leg.strategyId(), STRATEGY);
        vm.expectRevert(VaultState.AlreadyInitialized.selector);
        leg.initialize(stranger, stranger, new address[](1), new uint32[](1), 0, bytes32(0), bytes32(0), "");
    }

    function test_std_describesItself_asItsFactoryPinnedIt() public view {
        uint8 index = _index();
        if (index != 0) {
            (bytes32 legType, uint8 roles, uint8 valueKind) = ILeg(address(leg)).legInfo();
            assertTrue(legType != bytes32(0));
            uint8 role = CombinationFactory(leg.factory()).leg(index - 1).role;
            assertTrue(roles & (1 << (role - 1)) != 0, "the role its factory pinned");
            assertEq(valueKind, Legs.VALUE_READ);
        }
        assertTrue(leg.linkCount() >= 2);
        assertFalse(leg.ready(remote), "a link on another chain waits for its READY");
    }

    function test_std_ownerAction_nonce_otherMember_expiry() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory revoke0 = _action(OwnerMessages.REVOKE_EXECUTION, 0, deadline);
        leg.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, revoke0);
        assertTrue(leg.executionRevoked());
        vm.expectRevert(VaultState.BadSignature.selector);
        leg.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, revoke0); // its nonce is spent
        // signed for another member (another address)
        bytes memory foreign = _actionSig(stranger, OwnerMessages.ALLOW_EXECUTION, address(0), 1, deadline);
        vm.expectRevert(VaultState.BadSignature.selector);
        leg.ownerAction(OwnerMessages.ALLOW_EXECUTION, address(0), walletCred(wallet), deadline, foreign);
        vm.warp(deadline + 1);
        bytes memory late = _action(OwnerMessages.ALLOW_EXECUTION, 1, deadline);
        vm.expectRevert(VaultState.Expired.selector);
        leg.ownerAction(OwnerMessages.ALLOW_EXECUTION, address(0), walletCred(wallet), deadline, late);
    }

    function test_std_revokeStopsTheKey_allowRestoresIt() public {
        uint256 deadline = block.timestamp + 1 hours;
        leg.ownerAction(OwnerMessages.REVOKE_EXECUTION, address(0), walletCred(wallet), deadline, _action(1, 0, deadline));
        vm.prank(key);
        vm.expectRevert(VaultState.NotAllowed.selector);
        leg.pause(true);
        leg.ownerAction(OwnerMessages.ALLOW_EXECUTION, address(0), walletCred(wallet), deadline, _action(2, 1, deadline));
        vm.prank(key);
        leg.pause(true);
        assertTrue(leg.paused());
        vm.prank(stranger);
        vm.expectRevert(VaultState.NotExecution.selector);
        leg.pause(false);
    }

    /// Pause blocks opening only: the exit still begins, and then the key is out.
    function test_std_pauseNeverBlocksTheExit() public {
        vm.prank(key);
        leg.pause(true);
        uint256 deadline = block.timestamp + 1 hours;
        leg.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        assertTrue(leg.exiting());
        vm.prank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        leg.pause(false);
    }

    function test_std_entry_byTheOwner_oneWay_replayHarmless() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _beginExitSig(STRATEGY, deadline);
        bytes memory other = _beginExitSig(bytes32(uint256(1)), deadline); // another strategy's
        vm.expectRevert(VaultState.BadSignature.selector);
        leg.beginExit(deadline, other);
        leg.beginExit(deadline, sig);
        uint64 at = leg.exitStartedAt();
        vm.warp(block.timestamp + 1);
        leg.beginExit(deadline, sig);
        assertEq(leg.exitStartedAt(), at, "entering twice changes nothing");
    }

    function test_std_entry_byAnyone_afterSevenDaysWithoutCheckIn() public {
        vm.expectRevert(VaultState.GroupNotStopped.selector);
        leg.beginExitStopped();
        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        leg.beginExitStopped();
        assertTrue(leg.exiting());
    }

    /// Told by a member, it tells nobody (invariant 5).
    function test_std_entry_byItsLinksMessage_tellsNobody() public {
        address link = leg.links(remote);
        uint32 domain = leg.linkDomains(remote);
        uint256 sent = transmitter.sentCount();
        transmitter.deliver(address(leg), domain, bytes32(uint256(uint160(link))), abi.encode(leg.EXIT_MESSAGE()));
        assertTrue(leg.exiting());
        assertEq(leg.toldPending(), 0);
        assertEq(transmitter.sentCount(), sent, "a member told sends no EXIT");
    }

    /// Invariant 1 with amendment 2b: DLTX's fee address is a destination of the HUB only, the one its own
    /// chain's registry names at the moment of payment. A leg's money moves never reach it.
    function test_std_destinations_theFeeAddressFromTheHubOnly() public {
        address feeTo = makeAddr("fee-address");
        vm.prank(recovery);
        registry.proposeFeeAddress(feeTo);
        vm.prank(feeTo);
        registry.acceptFeeAddress();
        uint256 deadline = block.timestamp + 1 hours;
        leg.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        _exitMoves();
        assertEq(usdc.balanceOf(feeTo), _index() == 0 ? 15e6 : 0, "the hub's exit fee, from the hub alone");
    }

    /// The member type's exit moves with $100 of profit, where the unit world can run them (the AAVE leg's
    /// need AAVE: its fork suite).
    function _exitMoves() internal virtual {}

    /// A REPORT reaches only a hub; a member's own counters start at zero.
    function test_std_reportOnlyToAHub_countersStartAtZero() public {
        bytes32 link = bytes32(uint256(uint160(leg.links(remote))));
        uint32 domain = leg.linkDomains(remote);
        bytes memory body = abi.encode(leg.REPORT_MESSAGE(), uint256(1), block.timestamp);
        if (_index() != 0) {
            vm.expectRevert(VaultState.BadMessage.selector);
            transmitter.deliver(address(leg), domain, link, body);
        }
        for (uint256 k; k < 4; ++k) {
            assertEq(leg.sentTo(k), 0);
            assertEq(leg.receivedFrom(k), 0);
        }
    }
}

/// The hub on Arbitrum: the AAVE leg beside it, the Hyperliquid leg on HyperEVM.
contract LegStandardHubTest is LegStandardSuite {
    function _member() internal override returns (VaultBase) {
        transmitter.setLocalDomain(ARB_DOMAIN);
        return VaultBase(_create(_config()));
    }

    /// $100 of profit reaches the hub from the AAVE leg beside it (a member move), then anyone steps.
    function _exitMoves() internal override {
        address aave = leg.links(0);
        usdc.mint(aave, 100e6);
        vm.startPrank(aave);
        usdc.approve(address(leg), 100e6);
        StrategyHub(address(leg)).receiveLocal(100e6);
        vm.stopPrank();
        vm.prank(stranger);
        StrategyHub(address(leg)).exitStep();
    }
}

/// The Hyperliquid leg on HyperEVM, its hub and sister leg on Arbitrum.
contract LegStandardShortTest is LegStandardSuite {
    function _member() internal override returns (VaultBase) {
        return VaultBase(_create(_config()));
    }

    function _exitMoves() internal override {
        usdc.mint(address(leg), 100e6);
        ShortVaultExit(address(leg)).bridgeOut();
    }
}

/// The AAVE leg on Arbitrum, beside its hub.
contract LegStandardLongTest is LegStandardSuite {
    function _member() internal override returns (VaultBase) {
        transmitter.setLocalDomain(ARB_DOMAIN);
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        return VaultBase(factory.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline))[1]);
    }
}

/// The test-only leg type, on HyperEVM beside its hub, its sister on Arbitrum.
contract LegStandardTestLegTest is LegStandardSuite {
    function _member() internal override returns (VaultBase) {
        TestLegExit tExit = new TestLegExit();
        TestLeg code = new TestLeg(address(tExit), address(tExit).codehash);
        CombinationFactory.LegPin[] memory p = new CombinationFactory.LegPin[](2);
        p[0] = CombinationFactory.LegPin(address(code), address(code).codehash, HYPEREVM_DOMAIN, Legs.LONG, Legs.VALUE_READ, "TestLeg", "uint256 seven", 1);
        p[1] = CombinationFactory.LegPin(address(code), address(code).codehash, ARB_DOMAIN, Legs.SHORT, Legs.VALUE_READ, "TestLeg", "uint256 seven", 1);
        uint32[] memory hubs = new uint32[](1);
        hubs[0] = HYPEREVM_DOMAIN;
        CombinationFactory f = _factoryWith(hubs, p);
        StrategyConfig memory c;
        c.factory = address(f);
        c.hubDomain = HYPEREVM_DOMAIN;
        c.hubParams = abi.encode(_hubParams());
        c.legs = new LegConfig[](2);
        c.legs[0] = LegConfig(address(code), HYPEREVM_DOMAIN, Legs.LONG, abi.encode(uint256(7)));
        c.legs[1] = LegConfig(address(code), ARB_DOMAIN, Legs.SHORT, abi.encode(uint256(7)));
        uint256 deadline = block.timestamp + 1 days;
        return VaultBase(f.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline))[1]);
    }

    function _exitMoves() internal override {
        usdc.mint(address(leg), 100e6);
        TestLegExit(address(leg)).exitStep();
    }
}
